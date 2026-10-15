// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {ProtocolFeeLibrary} from "v4-core/libraries/ProtocolFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";

/// @dev Accountable async-redeem vault share (ERC-20, ERC-7540 redeem). sharePrice() is assets per share scaled by
/// precision(): assets = shares x sharePrice / precision, in base units.
interface IAccountableShare {
    function asset() external view returns (address);
    function strategy() external view returns (address);
    function precision() external view returns (uint256);
    function sharePrice() external view returns (uint256);
    function transferableShares() external view returns (bool);
}

/// @dev Accountable loan strategy. LoanState: 0 Initialized, 1 TermsSet, 2 OngoingLocked, 3 OngoingDynamic,
/// 4 Rejected, 5 Repaid, 6 InDefault, 7 InDefaultClaims. paused() is OpenZeppelin PausableUpgradeable's.
interface IAccountableStrategy {
    function loanState() external view returns (uint8);
    function paused() external view returns (bool);
}

/// @dev MetaMorpho (ERC-4626) vault the bid is funded from.
interface IERC4626Vault {
    function asset() external view returns (address);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
}

/// @dev Uniswap's V4FeeAdapter, the PoolManager's protocolFeeController where Uniswap governance has set one, names
/// the protocol fee recipient.
interface IProtocolFeeAdapter {
    function TOKEN_JAR() external view returns (address);
}

interface IERC20Min {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title AHyperQuoteHook
/// @notice Uniswap v4 hook that bids for one Accountable vault share (aHYPER) against its asset (USDC) in a single
/// canonical pool. The bid is the share's live on-chain sharePrice() minus a maker-set discount, and every USDC paid is
/// withdrawn just in time from the maker's ERC-4626 (MetaMorpho) vault position, so the bid capital keeps earning until
/// the instant of a fill. The hook never sells the share.
/// @dev Routers always pass empty hookData. Ownerless, not upgradeable; every address is fixed at construction.
/// beforeSwap consumes the whole specified amount of every swap it accepts and rejects the other direction, so the AMM
/// never swaps and any liquidity added to the pool is never traded. The seller's share is not yet in the PoolManager
/// when beforeSwap runs (routers settle after the swap), so the hook takes it as an ERC6909 claim; claims are owed to
/// MAKER and anyone can sweep them there. Fills stop on their own when the quote expires, when `remaining` runs out,
/// while the strategy is paused or the share is not transferable, and whenever the strategy's loanState() is not
/// ongoing. The state flips on acceptDefault or full repayment; a default initiated by defaultLoan() is not visible
/// on-chain for at least a day, so the maker's bot must act on it. The maker's only approval is VAULT shares to
/// this contract, which bounds the USDC the hook can ever pay.
/// Custom accounting does not bypass the v4 protocol fee: every fill charges the swapper the pool's protocol fee for
/// the swap direction, as Uniswap governance sets it in the PoolManager, in ASSET, and pays it to the protocol fee
/// controller's TokenJar (Uniswap's aggregator-hook convention). Swappers are protected by an immutable band on the
/// maker's discount: the bid never pays less than sharePrice x (1 - MAX_BID_DISCOUNT_BPS / 10,000). A discount change
/// inside the band takes effect at once, so the band bounds the worst fill; it does not stop the maker repricing a
/// pending swap whose slippage limit is tighter than the band.
contract AHyperQuoteHook is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;
    using ProtocolFeeLibrary for uint24;

    error NotPoolManager();
    error NotMaker();
    error WrongPool();
    error AskNotOffered();
    error QuoteExpired();
    error LoanNotOngoing(uint8 state);
    error StrategyPaused();
    error SharesNotTransferable();
    error RemainingChanged(uint128 actual);
    error UnknownCurrency();
    error PriceAboveCeiling();
    error ZeroPrice();
    error ZeroAmount();
    error AmountExceedsRemaining();
    error TransferFailed();
    error BadConfig();
    error DiscountAboveMax();

    /// @param validUntil Last timestamp at which the bid fills; zero disables it.
    /// @param discountBps Bid = sharePrice x (1 - discountBps / 10,000).
    /// @param remaining Share base units the hook still buys; zero disables the bid.
    struct Params {
        uint40 validUntil;
        uint16 discountBps;
        uint128 remaining;
    }

    event ParamsSet(Params params);
    /// @param sender The router that called the PoolManager.
    /// @param sharesIn What the swapper sold.
    /// @param assetsOut What the swapper received.
    /// @param protocolFee The ASSET paid to the TokenJar out of the fill: the maker paid assetsOut + protocolFee.
    /// @param sharePrice The share's sharePrice() the fill was priced at.
    event Filled(address sender, uint256 sharesIn, uint256 assetsOut, uint256 protocolFee, uint256 sharePrice);
    /// @dev Same shape as Uniswap's aggregator hooks' ProtocolFees event.
    event ProtocolFeesCollected(address indexed recipient, Currency indexed currency, uint256 amount);
    event Swept(address indexed currency, uint256 amount);
    /// @dev OpenZeppelin uniswap-hooks IHookEvents.HookSwap: amounts from the swapper's side, positive for input and
    /// negative for output; no hook LP fee.
    event HookSwap(
        bytes32 indexed poolId,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint128 hookLPfeeAmount0,
        uint128 hookLPfeeAmount1
    );

    uint256 private constant BPS = 10_000;
    uint256 private constant PIPS = 1_000_000;
    uint8 private constant ONGOING_LOCKED = 2;
    uint8 private constant ONGOING_DYNAMIC = 3;
    int24 public constant TICK_SPACING = 1;
    /// @dev Uniswap's V4FeeAdapter answers TOKEN_JAR() (an immutable) in about 400 gas.
    uint256 private constant TOKEN_JAR_GAS = 50_000;

    IPoolManager public immutable POOL_MANAGER;
    IERC4626Vault public immutable VAULT;
    IAccountableShare public immutable SHARE;
    IAccountableStrategy public immutable STRATEGY;
    address public immutable ASSET;
    address public immutable MAKER;
    /// @notice The bid never exceeds sharePrice x MAX_BID_BPS / 10,000 (protects the maker).
    uint256 public immutable MAX_BID_BPS;
    /// @notice The bid never falls below sharePrice x (1 - MAX_BID_DISCOUNT_BPS / 10,000) (protects the swapper).
    uint256 public immutable MAX_BID_DISCOUNT_BPS;
    /// @notice SHARE.precision(), the scale of sharePrice().
    uint256 public immutable PRECISION;
    /// @notice The canonical pool: {SHARE, ASSET} sorted, static zero LP fee, TICK_SPACING, this hook.
    PoolId public immutable POOL_ID;
    bool public immutable SHARE_IS_CURRENCY0;
    uint256 private immutable SHARE_ID;
    uint256 private immutable ASSET_ID;

    Params public params;

    constructor(
        address poolManager,
        address vault,
        address share,
        address maker,
        uint256 maxBidBps,
        uint256 maxBidDiscountBps
    ) {
        // The discount band must be non-empty: some d satisfies BPS - maxBidBps <= d <= maxBidDiscountBps < BPS.
        if (
            poolManager == address(0) || vault == address(0) || share == address(0) || maker == address(0)
                || maxBidBps == 0 || maxBidBps > BPS || maxBidDiscountBps >= BPS || BPS - maxBidBps > maxBidDiscountBps
        ) revert BadConfig();
        address asset = IERC4626Vault(vault).asset();
        // The vault must pay out the very asset the share is denominated in.
        if (asset == address(0) || asset == share || IAccountableShare(share).asset() != asset) revert BadConfig();
        address strategy = IAccountableShare(share).strategy();
        uint256 precision = IAccountableShare(share).precision();
        if (strategy == address(0) || precision == 0) revert BadConfig();

        POOL_MANAGER = IPoolManager(poolManager);
        VAULT = IERC4626Vault(vault);
        SHARE = IAccountableShare(share);
        STRATEGY = IAccountableStrategy(strategy);
        ASSET = asset;
        MAKER = maker;
        MAX_BID_BPS = maxBidBps;
        MAX_BID_DISCOUNT_BPS = maxBidDiscountBps;
        PRECISION = precision;
        SHARE_ID = uint256(uint160(share));
        ASSET_ID = uint256(uint160(asset));

        bool shareIs0 = share < asset;
        SHARE_IS_CURRENCY0 = shareIs0;
        (address c0, address c1) = shareIs0 ? (share, asset) : (asset, share);
        POOL_ID = PoolKey({
                currency0: Currency.wrap(c0),
                currency1: Currency.wrap(c1),
                fee: 0,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(address(this))
            }).toId();

        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        _;
    }

    // ------------------------------------------------------------------ maker

    /// @notice Replaces the bid. `validUntil = 0` or `remaining = 0` is the kill switch and skips every check, so the
    /// maker can always stop the bid, even while the share or its strategy reverts. Opening or changing a live bid
    /// requires `expectedRemaining` to equal the stored `remaining` (so a fill that lands between the maker reading the
    /// bid and this call is never bought again), the strategy to be unpaused with its loan ongoing, the share to be
    /// transferable, sharePrice() above zero, and 10,000 - MAX_BID_BPS <= discountBps <= MAX_BID_DISCOUNT_BPS.
    function setParams(Params calldata p, uint128 expectedRemaining) external {
        if (msg.sender != MAKER) revert NotMaker();
        if (p.validUntil != 0 && p.remaining != 0) {
            uint128 current = params.remaining;
            if (current != expectedRemaining) revert RemainingChanged(current);
            _requireTradable();
            if (SHARE.sharePrice() == 0) revert ZeroPrice();
            if (p.discountBps >= BPS) revert ZeroPrice();
            if (BPS - p.discountBps > MAX_BID_BPS) revert PriceAboveCeiling();
            if (p.discountBps > MAX_BID_DISCOUNT_BPS) revert DiscountAboveMax();
        }
        params = p;
        emit ParamsSet(p);
    }

    // ------------------------------------------------------------------ sweep

    /// @notice Moves everything the hook holds to MAKER: its ERC6909 claims on SHARE and ASSET, then its ERC-20
    /// balances of both (anything sent to the hook directly). Permissionless; the destination is fixed. Returns the
    /// amounts moved, SHARE then ASSET. Reverts if either currency cannot move; `sweep(currency)` then moves the other.
    function sweep() external returns (uint256 shareAmount, uint256 assetAmount) {
        shareAmount = _sweep(address(SHARE));
        assetAmount = _sweep(ASSET);
    }

    /// @notice `sweep` for one currency, SHARE or ASSET, so a currency that cannot move (a paused strategy blocks
    /// SHARE transfers; a blacklist could block ASSET) never strands the other.
    function sweep(address currency) external returns (uint256 amount) {
        if (currency != address(SHARE) && currency != ASSET) revert UnknownCurrency();
        amount = _sweep(currency);
    }

    function _sweep(address currency) private returns (uint256 amount) {
        uint256 claim = POOL_MANAGER.balanceOf(address(this), uint256(uint160(currency)));
        if (claim != 0) POOL_MANAGER.unlock(abi.encode(currency, claim));
        amount = claim + _transferBalance(currency);
        if (amount != 0) emit Swept(currency, amount);
    }

    /// @dev The PoolManager only calls back the account that unlocked it, and `_sweep` is this contract's only unlock.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (address currency, uint256 claim) = abi.decode(data, (address, uint256));
        POOL_MANAGER.burn(address(this), uint256(uint160(currency)), claim);
        POOL_MANAGER.take(Currency.wrap(currency), MAKER, claim);
        return "";
    }

    function _transferBalance(address token) private returns (uint256 amount) {
        amount = IERC20Min(token).balanceOf(address(this));
        if (amount == 0) return 0;
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20Min.transfer, (MAKER, amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    // ------------------------------------------------------------------ hooks

    /// @notice Accepts only the canonical pool; the PoolManager itself refuses a second initialisation. Any
    /// sqrtPriceX96 is fine: every accepted swap reaches Pool.swap with amountSpecified 0, which returns before
    /// checking the price limit or moving the price.
    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(POOL_ID)) revert WrongPool();
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Fills a swap that sells SHARE for ASSET entirely at the bid, less the pool's protocol fee, and returns a
    /// delta that leaves the AMM nothing to swap. A swap that buys SHARE reverts.
    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata sp, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        if (PoolId.unwrap(id) != PoolId.unwrap(POOL_ID)) revert WrongPool();
        // Selling SHARE moves it from its own side of the pool to ASSET's.
        if (sp.zeroForOne != SHARE_IS_CURRENCY0) revert AskNotOffered();

        (uint256 amountIn, uint256 amountOut) = _fill(sender, id, sp);
        return (IHooks.beforeSwap.selector, _delta(id, sender, sp, amountIn, amountOut), 0);
    }

    /// @dev Prices and spends the fill, clears the hook's PoolManager deltas for the maker legs, pays the protocol fee
    /// and emits Filled. Returns the swapper's amounts.
    function _fill(address sender, PoolId id, IPoolManager.SwapParams calldata sp)
        private
        returns (uint256 amountIn, uint256 amountOut)
    {
        bool exactInput = sp.amountSpecified < 0;
        uint256 specified = exactInput ? uint256(-sp.amountSpecified) : uint256(sp.amountSpecified);
        ProtocolFee memory pf = _protocolFee(id, sp.zeroForOne);
        (uint256 sharesIn, uint256 assetAmount, uint256 fee, uint256 price) = _consume(exactInput, specified, pf.pips);
        _settle(sharesIn, assetAmount);
        if (fee != 0) {
            POOL_MANAGER.take(Currency.wrap(ASSET), pf.recipient, fee);
            emit ProtocolFeesCollected(pf.recipient, Currency.wrap(ASSET), fee);
        }
        (amountIn, amountOut) = (sharesIn, assetAmount - fee);
        emit Filled(sender, amountIn, amountOut, fee, price);
    }

    /// @dev Specified is the input for exact-in and the output for exact-out. A positive hook delta is owed to the
    /// hook, a negative one is owed by it; the swapper's side is the negation.
    function _delta(PoolId id, address sender, IPoolManager.SwapParams calldata sp, uint256 amountIn, uint256 amountOut)
        private
        returns (BeforeSwapDelta)
    {
        int128 inDelta = amountIn.toInt128();
        int128 outDelta = amountOut.toInt128();
        if (sp.zeroForOne) emit HookSwap(PoolId.unwrap(id), sender, inDelta, -outDelta, 0, 0);
        else emit HookSwap(PoolId.unwrap(id), sender, -outDelta, inDelta, 0, 0);
        return sp.amountSpecified < 0 ? toBeforeSwapDelta(inDelta, -outDelta) : toBeforeSwapDelta(-outDelta, inDelta);
    }

    // ------------------------------------------------------------------ protocol fee

    /// @param pips The pool's protocol fee for the swap direction, in hundredths of a bip (at most 1,000).
    /// @param recipient The TokenJar it is paid to.
    struct ProtocolFee {
        uint256 pips;
        address recipient;
    }

    /// @dev Reads the pool's protocol fee for the swap direction from the PoolManager, where Uniswap governance sets it
    /// through the protocolFeeController, and resolves the TokenJar from that controller. With no fee, or no
    /// resolvable TokenJar (no code, a failed or out-of-gas call, under 32 bytes back, a word that is not a non-zero
    /// address), nothing is charged (Uniswap's aggregator hooks do the same).
    function _protocolFee(PoolId id, bool zeroForOne) private view returns (ProtocolFee memory pf) {
        (,, uint24 raw,) = POOL_MANAGER.getSlot0(id);
        uint256 pips = zeroForOne ? raw.getZeroForOneFee() : raw.getOneForZeroFee();
        if (pips == 0) return pf;
        address controller = POOL_MANAGER.protocolFeeController();
        if (controller.code.length == 0) return pf;
        // A bounded call that copies at most one word back, so no controller blocks fills by burning gas, returning
        // a huge payload or returning a word that is not an address.
        bytes4 selector = IProtocolFeeAdapter.TOKEN_JAR.selector;
        bool ok;
        uint256 word;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            ok := staticcall(TOKEN_JAR_GAS, controller, ptr, 4, ptr, 32)
            if lt(returndatasize(), 32) { ok := 0 }
            word := mload(ptr)
        }
        if (!ok || word >> 160 != 0 || word == 0) return pf;
        pf = ProtocolFee({pips: pips, recipient: address(uint160(word))});
    }

    // ------------------------------------------------------------------ pricing

    /// @dev Checks the quote and the strategy, prices the fill at the live sharePrice() and spends it from `remaining`
    /// (counted in SHARE in). Returns the maker's legs (SHARE in, ASSET paid out of VAULT) and the protocol fee, which
    /// sits between the maker's ASSET leg and the swapper's. The bid in ASSET base units per SHARE base unit is
    /// price x (10,000 - d) / (PRECISION x 10,000); f is the fee in pips, rounded up:
    /// - Exact-in (SHARE in): asset = floor(in x num / den), fee = ceil(asset x f / 1e6), the swapper receives
    ///   asset - fee.
    /// - Exact-out (ASSET out): fee = ceil(out x f / (1e6 - f)), asset = out + fee,
    ///   in = ceil(asset x den / num).
    /// Rounding favours the maker. The maker legs are then checked against the ceiling:
    /// asset x PRECISION x 10,000 <= in x price x MAX_BID_BPS, i.e. asset <= floor(in x price x MAX_BID_BPS / den).
    function _consume(bool exactInput, uint256 specified, uint256 feePips)
        private
        returns (uint256 amountIn, uint256 assetAmount, uint256 fee, uint256 price)
    {
        Params memory p = params;
        if (block.timestamp > p.validUntil) revert QuoteExpired();
        if (p.remaining == 0) revert AmountExceedsRemaining();
        _requireTradable();
        price = SHARE.sharePrice();
        if (price == 0) revert ZeroPrice();

        uint256 num = price * (BPS - p.discountBps);
        uint256 den = PRECISION * BPS;
        if (exactInput) {
            amountIn = specified;
            if (amountIn > p.remaining) revert AmountExceedsRemaining();
            assetAmount = FullMath.mulDiv(amountIn, num, den);
            fee = FullMath.mulDivRoundingUp(assetAmount, feePips, PIPS);
            if (assetAmount <= fee) revert ZeroAmount();
        } else {
            if (specified == 0) revert ZeroAmount();
            fee = FullMath.mulDivRoundingUp(specified, feePips, PIPS - feePips);
            assetAmount = specified + fee;
            amountIn = FullMath.mulDivRoundingUp(assetAmount, den, num);
            if (amountIn > p.remaining) revert AmountExceedsRemaining();
        }
        if (assetAmount > FullMath.mulDiv(amountIn, price * MAX_BID_BPS, den)) revert PriceAboveCeiling();
        params.remaining = uint128(p.remaining - amountIn);
    }

    function _requireTradable() private view {
        if (STRATEGY.paused()) revert StrategyPaused();
        if (!SHARE.transferableShares()) revert SharesNotTransferable();
        uint8 state = STRATEGY.loanState();
        if (state != ONGOING_LOCKED && state != ONGOING_DYNAMIC) revert LoanNotOngoing(state);
    }

    // ------------------------------------------------------------------ settlement

    /// @dev Clears the hook's PoolManager deltas for a fill's maker legs: +amountIn SHARE as a claim, -assetAmount ASSET
    /// withdrawn from the maker's VAULT position straight into the PoolManager, protocol fee included (VAULT pulls it
    /// from its markets and reverts the whole swap if they lack the liquidity; `_fill` then takes the fee out to the
    /// TokenJar). The sync/settle pair here overwrites any sync the caller left pending,
    /// so a caller that syncs and transfers its input before calling swap and settles afterwards reverts with
    /// CurrencyNotSettled; routers that sync, pay and settle atomically (UniversalRouter V4Router) are unaffected.
    function _settle(uint256 amountIn, uint256 assetAmount) private {
        // The seller's share reaches the PoolManager only when the router settles after this swap, so it cannot be
        // taken yet; the claim is backed by that settlement and is swept to MAKER later.
        POOL_MANAGER.mint(address(this), SHARE_ID, amountIn);
        POOL_MANAGER.sync(Currency.wrap(ASSET));
        VAULT.withdraw(assetAmount, address(POOL_MANAGER), MAKER);
        POOL_MANAGER.settle();
    }
}
