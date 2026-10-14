// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
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
/// on-chain for at least a day, so the maker's bot must act on its event. The maker's only approval is VAULT shares to
/// this contract, which bounds the USDC the hook can ever pay.
contract AHyperQuoteHook is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

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
    /// @param sharePrice The share's sharePrice() the fill was priced at.
    event Filled(address sender, uint256 sharesIn, uint256 assetsOut, uint256 sharePrice);
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
    uint8 private constant ONGOING_LOCKED = 2;
    uint8 private constant ONGOING_DYNAMIC = 3;
    int24 public constant TICK_SPACING = 1;

    IPoolManager public immutable POOL_MANAGER;
    IERC4626Vault public immutable VAULT;
    IAccountableShare public immutable SHARE;
    IAccountableStrategy public immutable STRATEGY;
    address public immutable ASSET;
    address public immutable MAKER;
    /// @notice The bid never exceeds sharePrice x MAX_BID_BPS / 10,000.
    uint256 public immutable MAX_BID_BPS;
    /// @notice SHARE.precision(), the scale of sharePrice().
    uint256 public immutable PRECISION;
    /// @notice The canonical pool: {SHARE, ASSET} sorted, static zero LP fee, TICK_SPACING, this hook.
    PoolId public immutable POOL_ID;
    bool public immutable SHARE_IS_CURRENCY0;
    uint256 private immutable SHARE_ID;
    uint256 private immutable ASSET_ID;

    Params public params;

    constructor(address poolManager, address vault, address share, address maker, uint256 maxBidBps) {
        if (
            poolManager == address(0) || vault == address(0) || share == address(0) || maker == address(0)
                || maxBidBps == 0 || maxBidBps > BPS
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
    /// transferable, sharePrice() above zero, discountBps < 10,000 and 10,000 - discountBps <= MAX_BID_BPS.
    function setParams(Params calldata p, uint128 expectedRemaining) external {
        if (msg.sender != MAKER) revert NotMaker();
        if (p.validUntil != 0 && p.remaining != 0) {
            uint128 current = params.remaining;
            if (current != expectedRemaining) revert RemainingChanged(current);
            _requireTradable();
            if (SHARE.sharePrice() == 0) revert ZeroPrice();
            if (p.discountBps >= BPS) revert ZeroPrice();
            if (BPS - p.discountBps > MAX_BID_BPS) revert PriceAboveCeiling();
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

    /// @notice Fills a swap that sells SHARE for ASSET entirely at the bid and returns a delta that leaves the AMM
    /// nothing to swap. A swap that buys SHARE reverts.
    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata sp, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        if (PoolId.unwrap(id) != PoolId.unwrap(POOL_ID)) revert WrongPool();
        // Selling SHARE moves it from its own side of the pool to ASSET's.
        if (sp.zeroForOne != SHARE_IS_CURRENCY0) revert AskNotOffered();

        bool exactInput = sp.amountSpecified < 0;
        uint256 specified = exactInput ? uint256(-sp.amountSpecified) : uint256(sp.amountSpecified);
        (uint256 amountIn, uint256 amountOut, uint256 price) = _consume(exactInput, specified);
        _settle(amountIn, amountOut);
        emit Filled(sender, amountIn, amountOut, price);

        // Specified is the input for exact-in and the output for exact-out. A positive hook delta is owed to the hook,
        // a negative one is owed by it; the swapper's side is the negation.
        int128 inDelta = amountIn.toInt128();
        int128 outDelta = amountOut.toInt128();
        if (sp.zeroForOne) emit HookSwap(PoolId.unwrap(id), sender, inDelta, -outDelta, 0, 0);
        else emit HookSwap(PoolId.unwrap(id), sender, -outDelta, inDelta, 0, 0);
        BeforeSwapDelta delta =
            exactInput ? toBeforeSwapDelta(inDelta, -outDelta) : toBeforeSwapDelta(-outDelta, inDelta);
        return (IHooks.beforeSwap.selector, delta, 0);
    }

    // ------------------------------------------------------------------ pricing

    /// @dev Checks the quote and the strategy, prices the fill at the live sharePrice() and spends it from `remaining`
    /// (counted in SHARE in). The bid in ASSET base units per SHARE base unit is
    /// price x (10,000 - d) / (PRECISION x 10,000).
    /// Exact-in (SHARE in): out = floor(in x price x (10,000 - d) / (PRECISION x 10,000)).
    /// Exact-out (ASSET out): in = ceil(out x PRECISION x 10,000 / (price x (10,000 - d))).
    /// Both round in the maker's favour. The realised amounts are then checked against the ceiling:
    /// out x PRECISION x 10,000 <= in x price x MAX_BID_BPS, i.e. out <= floor(in x price x MAX_BID_BPS / den).
    function _consume(bool exactInput, uint256 specified)
        private
        returns (uint256 amountIn, uint256 amountOut, uint256 price)
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
            amountOut = FullMath.mulDiv(amountIn, num, den);
        } else {
            amountOut = specified;
            amountIn = FullMath.mulDivRoundingUp(amountOut, den, num);
            if (amountIn > p.remaining) revert AmountExceedsRemaining();
        }
        if (amountOut == 0) revert ZeroAmount();
        if (amountOut > FullMath.mulDiv(amountIn, price * MAX_BID_BPS, den)) revert PriceAboveCeiling();
        params.remaining = uint128(p.remaining - amountIn);
    }

    function _requireTradable() private view {
        if (STRATEGY.paused()) revert StrategyPaused();
        if (!SHARE.transferableShares()) revert SharesNotTransferable();
        uint8 state = STRATEGY.loanState();
        if (state != ONGOING_LOCKED && state != ONGOING_DYNAMIC) revert LoanNotOngoing(state);
    }

    // ------------------------------------------------------------------ settlement

    /// @dev Clears the hook's PoolManager deltas for a fill: +amountIn SHARE as a claim, -amountOut ASSET withdrawn
    /// from the maker's VAULT position straight into the PoolManager (VAULT pulls it from its markets and reverts the
    /// whole swap if they lack the liquidity). The sync/settle pair here overwrites any sync the caller left pending,
    /// so a caller that syncs and transfers its input before calling swap and settles afterwards reverts with
    /// CurrencyNotSettled; routers that sync, pay and settle atomically (UniversalRouter V4Router) are unaffected.
    function _settle(uint256 amountIn, uint256 amountOut) private {
        // The seller's share reaches the PoolManager only when the router settles after this swap, so it cannot be
        // taken yet; the claim is backed by that settlement and is swept to MAKER later.
        POOL_MANAGER.mint(address(this), SHARE_ID, amountIn);
        POOL_MANAGER.sync(Currency.wrap(ASSET));
        VAULT.withdraw(amountOut, address(POOL_MANAGER), MAKER);
        POOL_MANAGER.settle();
    }
}
