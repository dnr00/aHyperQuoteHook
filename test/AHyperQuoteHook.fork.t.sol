// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {AHyperQuoteHook} from "../src/AHyperQuoteHook.sol";
import {
    ExactInputSingleParams,
    ExactOutputSingleParams,
    QuoteExactSingleParams,
    IUniversalRouter,
    IPermit2,
    IV4Quoter
} from "./utils/RouterTypes.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function allowance(address, address) external view returns (uint256);
}

interface IMetaMorphoLike is IERC20Like {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function submitCap(MarketParams memory marketParams, uint256 newSupplyCap) external;
    function acceptCap(MarketParams memory marketParams) external;
    function setSupplyQueue(bytes32[] calldata newSupplyQueue) external;
    function updateWithdrawQueue(uint256[] calldata indexes) external;
    function withdrawQueueLength() external view returns (uint256);
    function reallocate(MarketAllocation[] calldata allocations) external;
    function timelock() external view returns (uint256);
}

struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

struct MarketAllocation {
    MarketParams marketParams;
    uint256 assets;
}

interface IMorphoLike {
    function market(bytes32 id) external view returns (uint128, uint128, uint128, uint128, uint128, uint128);
    function accrueInterest(MarketParams memory marketParams) external;
    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes memory data)
        external;
    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256);
}

interface IShareLike is IERC20Like {
    function sharePrice() external view returns (uint256);
}

interface IAHyperLike {
    function maxRedeem(address controller) external view returns (uint256);
    function maxDeposit(address receiver) external view returns (uint256);
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);
}

interface IStrategyAdmin {
    function investmentManager() external view returns (address);
    function pause() external;
    function paused() external view returns (bool);
    function setSharesTransferable(bool transferable) external;
    function transferableShares() external view returns (bool);
}

interface IPoolManagerOwned {
    function owner() external view returns (address);
    function setProtocolFeeController(address controller) external;
}

/// @dev Monad-fork fixture at block 113,335,000 (timestamp 1,791,983,316). State at the block, read by eth_call:
/// - aHYPER `0x7Cd2…5e59` (6 decimals, precision 1e36): sharePrice 1,082,724,080,175,656,923,778,690,918,203,191,386,
///   strategy `0xd094…1ef3` loanState 3 (OngoingDynamic); aHYPER sorts above USDC, so it is currency1;
/// - Hyperithm USDC Apex `0xA866…4c79` (MetaMorpho v1.1): one market (the idle USDC market) in both queues, 1.94 USDC
///   of assets, timelock 259,200 s, owner `0xee7e…18c8`;
/// - Morpho aHYPER/USDC market `0x9e84…a626` (LLTV 77%): 40,530,189.158863 supplied, 33,481,985.246426 borrowed;
/// - the PoolManager has no protocol fee controller.
/// A third party initialises the canonical pool at 1:1. The maker deposits 6,000,000 USDC into Apex, approves its
/// shares to the hook and posts a bid of sharePrice - 25 bps for up to 1,000,000 aHYPER. Expected amounts were computed
/// outside Solidity with exact integer arithmetic from the formulas in the design, then floored or ceiled in the
/// maker's favour.
abstract contract AHyperHookForkBase is Test {
    using PoolIdLibrary for PoolKey;

    uint256 constant BLOCK = 113_335_000;
    uint256 constant BLOCK_TIME = 1_791_983_316;
    address constant POOL_MANAGER = 0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e;
    address constant UNIVERSAL_ROUTER = 0x0D97Dc33264bfC1c226207428A79b26757fb9dc3;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant V4_QUOTER = 0xa222Dd357A9076d1091Ed6Aa2e16C9742dD26891;
    address constant MORPHO = 0xD5D960E8C380B724a48AC59E2DfF1b2CB4a1eAee;
    address constant APEX = 0xA8665084D8CD6276c00CA97Cbc0BF4BC9ae94c79;
    address constant APEX_OWNER = 0xEe7E9bb21D5589BF657b94083dB2fA349a3918C8;
    address constant AHYPER = 0x7Cd231120a60F500887444a9bAF5e1BD753A5e59;
    address constant STRATEGY = 0xD0943c76ee287793559c1dF82E5B2B858Dd01Ef3;
    address constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    bytes32 constant AHYPER_MARKET = 0x9e8441e7af65860feac831ebc117473e3033321abf528ebc8fbde1eeaaa3a626;

    uint256 constant SHARE_PRICE = 1_082_724_080_175_656_923_778_690_918_203_191_386;
    uint256 constant MAX_BID_BPS = 9_990;
    uint16 constant DISCOUNT = 25;
    uint128 constant REMAINING = 1_000_000e6;
    uint256 constant MAKER_DEPOSIT = 6_000_000e6;
    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    /// @dev beforeInitialize | beforeSwap | beforeSwapReturnDelta.
    uint160 constant HOOK_FLAGS = 0x2088;
    /// @dev 1,234.567890 aHYPER: odd digits so every rounding shows.
    uint256 constant X = 1_234_567_890;
    /// @dev floor(X x SHARE_PRICE x 9,975 / (1e36 x 10,000)).
    uint256 constant X_OUT_25 = 1_333_354_642;
    /// @dev floor(X x SHARE_PRICE x 9,990 / (1e36 x 10,000)).
    uint256 constant X_OUT_10 = 1_335_359_686;
    /// @dev ceil(1,000 USDC x 1e36 x 10,000 / (SHARE_PRICE x 9,975)).
    uint256 constant IN_FOR_1000_25 = 925_911_120;
    /// @dev ceil(1,000 USDC x 1e36 x 10,000 / (SHARE_PRICE x 9,990)).
    uint256 constant IN_FOR_1000_10 = 924_520_864;

    bytes32 constant MORPHO_WITHDRAW_TOPIC = keccak256("Withdraw(bytes32,address,address,address,uint256,uint256)");

    IPoolManager pm = IPoolManager(POOL_MANAGER);
    IMetaMorphoLike apex = IMetaMorphoLike(APEX);
    AHyperQuoteHook hook;
    PoolKey key;
    uint256 makerPk = 0xA11CE;
    address maker;
    address seller = makeAddr("seller");
    uint40 validUntil;

    function setUp() public virtual {
        _fork();
        _deployHook();
        vm.prank(makeAddr("initializer"));
        pm.initialize(key, _initPrice());
        _fundMaker();
        _post(DISCOUNT, REMAINING);
        deal(AHYPER, seller, 2_000_000e6);
        _approveViaPermit2(seller, AHYPER);
        deal(USDC, seller, 1_000_000e6);
        _approveViaPermit2(seller, USDC);
    }

    function _initPrice() internal view virtual returns (uint160) {
        return SQRT_PRICE_1_1;
    }

    function _fork() internal {
        vm.createSelectFork("monad", BLOCK);
        assertEq(block.timestamp, BLOCK_TIME, "precondition: block time");
        assertEq(IShareLike(AHYPER).sharePrice(), SHARE_PRICE, "precondition: share price");
        maker = vm.addr(makerPk);
        validUntil = uint40(block.timestamp + 30 days);
    }

    function _deployHook() internal {
        address hookAddr = address(uint160((uint256(keccak256("AHyperQuoteHook")) & ~uint256(0x3FFF)) | HOOK_FLAGS));
        assertEq(hookAddr.code.length, 0, "hook address is empty on Monad");
        deployCodeTo(
            "AHyperQuoteHook.sol:AHyperQuoteHook", abi.encode(POOL_MANAGER, APEX, AHYPER, maker, MAX_BID_BPS), hookAddr
        );
        hook = AHyperQuoteHook(hookAddr);
        key = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(AHYPER),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(hookAddr)
        });
    }

    function _fundMaker() internal {
        deal(USDC, maker, MAKER_DEPOSIT);
        vm.startPrank(maker);
        IERC20Like(USDC).approve(APEX, MAKER_DEPOSIT);
        apex.deposit(MAKER_DEPOSIT, maker);
        apex.approve(address(hook), type(uint256).max);
        vm.stopPrank();
        assertEq(IERC20Like(USDC).balanceOf(maker), 0, "precondition: maker holds no idle USDC");
    }

    /// @dev Posts with the stored remaining as the expected value, as a bot that just read the bid would.
    function _post(uint16 discountBps, uint128 remaining) internal {
        uint128 current = _remaining();
        vm.prank(maker);
        hook.setParams(
            AHyperQuoteHook.Params({validUntil: validUntil, discountBps: discountBps, remaining: remaining}), current
        );
    }

    // ------------------------------------------------------------------ router

    function _approveViaPermit2(address owner, address asset) internal {
        vm.startPrank(owner);
        IERC20Like(asset).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(asset, UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    /// @dev V4_SWAP (0x10) with SWAP_EXACT_IN_SINGLE (0x06) or SWAP_EXACT_OUT_SINGLE (0x08), then SETTLE_ALL (0x0c) and
    /// TAKE_ALL (0x0f): the plan Uniswap's routing builds, in which the swapper pays only after the swap. `sell` sells
    /// aHYPER for USDC (the bid); otherwise the swap buys aHYPER. `limit` is the minimum out for exact-in and the
    /// maximum in for exact-out.
    function _swap(bool sell, bool exactIn, uint256 amount, uint256 limit) internal returns (uint256 gasUsed) {
        // aHYPER is currency1, so selling it is oneForZero.
        bool zeroForOne = !sell;
        (address cin, address cout) = sell ? (AHYPER, USDC) : (USDC, AHYPER);
        bytes[] memory params = new bytes[](3);
        bytes memory actions;
        if (exactIn) {
            params[0] = abi.encode(
                ExactInputSingleParams({
                    poolKey: key,
                    zeroForOne: zeroForOne,
                    amountIn: uint128(amount),
                    amountOutMinimum: uint128(limit),
                    hookData: ""
                })
            );
            params[1] = abi.encode(Currency.wrap(cin), amount);
            params[2] = abi.encode(Currency.wrap(cout), limit);
            actions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));
        } else {
            params[0] = abi.encode(
                ExactOutputSingleParams({
                    poolKey: key,
                    zeroForOne: zeroForOne,
                    amountOut: uint128(amount),
                    amountInMaximum: uint128(limit),
                    hookData: ""
                })
            );
            params[1] = abi.encode(Currency.wrap(cin), limit);
            params[2] = abi.encode(Currency.wrap(cout), amount);
            actions = abi.encodePacked(uint8(0x08), uint8(0x0c), uint8(0x0f));
        }
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        vm.prank(seller);
        uint256 g = gasleft();
        IUniversalRouter(UNIVERSAL_ROUTER).execute(abi.encodePacked(uint8(0x10)), inputs, block.timestamp);
        gasUsed = g - gasleft();
    }

    /// @dev Sells aHYPER and returns what the seller actually paid and received, from its balances.
    function _sell(bool exactIn, uint256 amount, uint256 limit) internal returns (uint256 paid, uint256 received) {
        uint256 inBefore = IERC20Like(AHYPER).balanceOf(seller);
        uint256 outBefore = IERC20Like(USDC).balanceOf(seller);
        _swap(true, exactIn, amount, limit);
        paid = inBefore - IERC20Like(AHYPER).balanceOf(seller);
        received = IERC20Like(USDC).balanceOf(seller) - outBefore;
    }

    /// @dev The PoolManager wraps a hook revert in ERC-7751 WrappedError and the router's V4_SWAP bubbles it as is.
    function _expectSwapRevert(bytes memory hookError) internal {
        vm.expectRevert(_wrapped(IHooks.beforeSwap.selector, hookError));
    }

    function _wrapped(bytes4 hookSelector, bytes memory hookError) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            hookSelector,
            hookError,
            abi.encodePacked(Hooks.HookCallFailed.selector)
        );
    }

    // ------------------------------------------------------------------ state readers

    function _claim(address currency) internal view returns (uint256) {
        return pm.balanceOf(address(hook), uint256(uint160(currency)));
    }

    function _remaining() internal view returns (uint128 r) {
        (,, r) = hook.params();
    }

    function _assertHookHoldsNoErc20() internal view {
        assertEq(IERC20Like(USDC).balanceOf(address(hook)), 0, "hook USDC");
        assertEq(IERC20Like(AHYPER).balanceOf(address(hook)), 0, "hook aHYPER");
        assertEq(apex.balanceOf(address(hook)), 0, "hook Apex shares");
    }

    /// @dev One fill: the seller paid `sharesIn` and got `usdcOut`; `remaining` fell by `sharesIn`, the hook's aHYPER
    /// claim rose by it, the maker's Apex position paid exactly `usdcOut` (its idle USDC stays 0) and the hook holds no
    /// ERC-20.
    function _sellAndCheck(bool exactIn, uint256 amount, uint256 expectedIn, uint256 expectedOut) internal {
        uint128 remainingBefore = _remaining();
        uint256 claimBefore = _claim(AHYPER);
        uint256 makerSharesBefore = apex.balanceOf(maker);
        uint256 sharesForOut = apex.previewWithdraw(expectedOut);
        (uint256 paid, uint256 received) = _sell(exactIn, amount, exactIn ? expectedOut : expectedIn);
        assertEq(paid, expectedIn, "aHYPER paid");
        assertEq(received, expectedOut, "USDC received");
        assertEq(_remaining(), remainingBefore - expectedIn, "remaining -= aHYPER in");
        assertEq(_claim(AHYPER), claimBefore + expectedIn, "aHYPER claim += aHYPER in");
        assertEq(_claim(USDC), 0, "no USDC claim");
        assertEq(makerSharesBefore - apex.balanceOf(maker), sharesForOut, "Apex shares burned for exactly the fill");
        assertEq(IERC20Like(USDC).balanceOf(maker), 0, "maker idle USDC stays 0");
        _assertHookHoldsNoErc20();
    }
}

contract AHyperQuoteHookForkTest is AHyperHookForkBase, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    // ------------------------------------------------------------------ config

    function test_config() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS, "exactly three flags");
        assertEq(address(hook.POOL_MANAGER()), POOL_MANAGER);
        assertEq(address(hook.VAULT()), APEX);
        assertEq(address(hook.SHARE()), AHYPER);
        assertEq(address(hook.STRATEGY()), STRATEGY);
        assertEq(hook.ASSET(), USDC);
        assertEq(hook.MAKER(), maker);
        assertEq(hook.MAX_BID_BPS(), MAX_BID_BPS);
        assertEq(hook.PRECISION(), 1e36);
        assertFalse(hook.SHARE_IS_CURRENCY0(), "aHYPER sorts above USDC");
        assertEq(PoolId.unwrap(hook.POOL_ID()), PoolId.unwrap(key.toId()), "canonical pool key");
        (uint40 v, uint16 d, uint128 r) = hook.params();
        assertEq(v, validUntil);
        assertEq(d, DISCOUNT);
        assertEq(r, REMAINING);
    }

    /// @dev Every config check runs before the permission check, so a plain deployment at an arbitrary address reaches it.
    function test_constructor_rejectsBadConfig() public {
        _expectBadConfig(address(0), APEX, AHYPER, maker, MAX_BID_BPS);
        _expectBadConfig(POOL_MANAGER, APEX, address(0), maker, MAX_BID_BPS);
        _expectBadConfig(POOL_MANAGER, APEX, AHYPER, address(0), MAX_BID_BPS);
        _expectBadConfig(POOL_MANAGER, APEX, AHYPER, maker, 0);
        _expectBadConfig(POOL_MANAGER, APEX, AHYPER, maker, 10_001);
        // Hyperithm AUSD Degen pays AUSD, not the USDC aHYPER is denominated in.
        _expectBadConfig(POOL_MANAGER, 0x94D7162c82F2007d65f12fbD78854f2CcF7B29f6, AHYPER, maker, MAX_BID_BPS);
        // A valid config at an address without the hook's flags.
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, next));
        new AHyperQuoteHook(POOL_MANAGER, APEX, AHYPER, maker, MAX_BID_BPS);
    }

    function _expectBadConfig(address pm_, address vault, address share, address maker_, uint256 maxBidBps) private {
        vm.expectRevert(AHyperQuoteHook.BadConfig.selector);
        new AHyperQuoteHook(pm_, vault, share, maker_, maxBidBps);
    }

    // ------------------------------------------------------------------ fills

    function test_bid_exactIn() public {
        _sellAndCheck(true, X, X, X_OUT_25);
    }

    function test_bid_exactOut() public {
        _sellAndCheck(false, 1_000e6, IN_FOR_1000_25, 1_000e6);
    }

    /// @dev At the ceiling itself (discount 10 bps = 1 - MAX_BID_BPS) both directions still fill.
    function test_bid_atCeiling_bothDirections() public {
        _post(10, REMAINING);
        _sellAndCheck(true, X, X, X_OUT_10);
        _sellAndCheck(false, 1_000e6, IN_FOR_1000_10, 1_000e6);
    }

    function test_bid_sequentialFills_accumulateClaims() public {
        _sellAndCheck(true, X, X, X_OUT_25);
        _sellAndCheck(false, 1_000e6, IN_FOR_1000_25, 1_000e6);
        _sellAndCheck(true, X, X, X_OUT_25);
        assertEq(_claim(AHYPER), 2 * X + IN_FOR_1000_25);
    }

    /// @dev The price follows sharePrice(), which accrues every second: a day later the same sale pays more, and
    /// exactly sharePrice x (1 - d) of that moment, independent of when the bid was posted.
    function test_bid_tracksLiveSharePrice() public {
        vm.warp(block.timestamp + 1 days);
        uint256 price = IShareLike(AHYPER).sharePrice();
        assertGt(price, SHARE_PRICE, "share price accrued");
        uint256 expected = X * price * (10_000 - DISCOUNT) / (1e36 * 10_000);
        assertGt(expected, X_OUT_25);
        (, uint256 received) = _sell(true, X, 0);
        assertEq(received, expected);
    }

    function test_bid_emitsFilledAndHookSwap() public {
        vm.recordLogs();
        _sell(true, X, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool filled;
        bool hookSwap;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics[0] == AHyperQuoteHook.Filled.selector) {
                (address sender, uint256 sharesIn, uint256 assetsOut, uint256 price) =
                    abi.decode(logs[i].data, (address, uint256, uint256, uint256));
                assertEq(sender, UNIVERSAL_ROUTER);
                assertEq(sharesIn, X);
                assertEq(assetsOut, X_OUT_25);
                assertEq(price, SHARE_PRICE);
                filled = true;
            } else if (logs[i].topics[0] == AHyperQuoteHook.HookSwap.selector) {
                assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()));
                (int128 a0, int128 a1,,) = abi.decode(logs[i].data, (int128, int128, uint128, uint128));
                assertEq(a0, -int128(int256(X_OUT_25)), "USDC out of the pool");
                assertEq(a1, int128(int256(X)), "aHYPER into the pool");
                hookSwap = true;
            }
        }
        assertTrue(filled && hookSwap);
    }

    // ------------------------------------------------------------------ guards

    function test_buyingAHyper_reverts_bothModes() public {
        _expectSwapRevert(abi.encodeWithSelector(AHyperQuoteHook.AskNotOffered.selector));
        _swap(false, true, 1_000e6, 0);
        _expectSwapRevert(abi.encodeWithSelector(AHyperQuoteHook.AskNotOffered.selector));
        _swap(false, false, X, type(uint128).max);
    }

    function test_expired_reverts() public {
        vm.warp(uint256(validUntil) + 1);
        _expectSwapRevert(abi.encodeWithSelector(AHyperQuoteHook.QuoteExpired.selector));
        _swap(true, true, X, 0);
    }

    function test_atValidUntil_fills() public {
        vm.warp(validUntil);
        _sell(true, X, 0);
    }

    function test_exceedsRemaining_reverts_bothModes() public {
        _post(DISCOUNT, uint128(X - 1));
        _expectSwapRevert(abi.encodeWithSelector(AHyperQuoteHook.AmountExceedsRemaining.selector));
        _swap(true, true, X, 0);
        _post(DISCOUNT, uint128(IN_FOR_1000_25 - 1));
        _expectSwapRevert(abi.encodeWithSelector(AHyperQuoteHook.AmountExceedsRemaining.selector));
        _swap(true, false, 1_000e6, type(uint128).max);
    }

    function test_remainingExactlyConsumed_thenStops() public {
        _post(DISCOUNT, uint128(X));
        _sellAndCheck(true, X, X, X_OUT_25);
        assertEq(_remaining(), 0);
        _expectSwapRevert(abi.encodeWithSelector(AHyperQuoteHook.AmountExceedsRemaining.selector));
        _swap(true, true, 1, 0);
    }

    /// @dev At a 10% discount one aHYPER base unit is worth 0.97 USDC base units, which floors to zero.
    function test_dustThatPaysZero_reverts() public {
        _post(1_000, REMAINING);
        _expectSwapRevert(abi.encodeWithSelector(AHyperQuoteHook.ZeroAmount.selector));
        _swap(true, true, 1, 0);
    }

    function test_killSwitch_validUntilZero_and_remainingZero() public {
        vm.startPrank(maker);
        hook.setParams(AHyperQuoteHook.Params({validUntil: 0, discountBps: DISCOUNT, remaining: REMAINING}), 0);
        vm.stopPrank();
        _expectSwapRevert(abi.encodeWithSelector(AHyperQuoteHook.QuoteExpired.selector));
        _swap(true, true, X, 0);

        vm.prank(maker);
        hook.setParams(AHyperQuoteHook.Params({validUntil: validUntil, discountBps: DISCOUNT, remaining: 0}), 0);
        _expectSwapRevert(abi.encodeWithSelector(AHyperQuoteHook.AmountExceedsRemaining.selector));
        _swap(true, true, X, 0);
    }

    /// @dev Every non-ongoing state stops fills and refuses to open a bid; both ongoing states fill.
    function test_loanNotOngoing_stopsFillsAndOpening() public {
        uint8[6] memory stopped = [uint8(0), 1, 4, 5, 6, 7];
        for (uint256 i; i < stopped.length; ++i) {
            vm.mockCall(STRATEGY, abi.encodeWithSignature("loanState()"), abi.encode(stopped[i]));
            _expectSwapRevert(abi.encodeWithSelector(AHyperQuoteHook.LoanNotOngoing.selector, stopped[i]));
            _swap(true, true, X, 0);
            vm.prank(maker);
            vm.expectRevert(abi.encodeWithSelector(AHyperQuoteHook.LoanNotOngoing.selector, stopped[i]));
            hook.setParams(
                AHyperQuoteHook.Params({validUntil: validUntil, discountBps: DISCOUNT, remaining: 1}), REMAINING
            );
        }
        vm.mockCall(STRATEGY, abi.encodeWithSignature("loanState()"), abi.encode(uint8(2)));
        _sell(true, X, 0);
        vm.mockCall(STRATEGY, abi.encodeWithSignature("loanState()"), abi.encode(uint8(3)));
        _sell(true, X, 0);
    }

    /// @dev The kill switch touches neither the strategy nor the share, so it works while both revert.
    function test_killSwitch_worksWhileStrategyAndShareRevert() public {
        vm.mockCallRevert(STRATEGY, abi.encodeWithSignature("loanState()"), "broken");
        vm.mockCallRevert(AHYPER, abi.encodeWithSignature("sharePrice()"), "broken");
        vm.prank(maker);
        hook.setParams(AHyperQuoteHook.Params({validUntil: 0, discountBps: 0, remaining: 0}), 0);
        (uint40 v,, uint128 r) = hook.params();
        assertEq(v, 0);
        assertEq(r, 0);
    }

    /// @dev A killed bid reverts on its own state before calling the strategy or the share, so it stays a clean
    /// revert while either is broken.
    function test_killedBid_revertsBeforeTouchingStrategy() public {
        vm.prank(maker);
        hook.setParams(AHyperQuoteHook.Params({validUntil: validUntil, discountBps: DISCOUNT, remaining: 0}), 0);
        vm.mockCallRevert(STRATEGY, abi.encodeWithSignature("loanState()"), "broken");
        vm.mockCallRevert(AHYPER, abi.encodeWithSignature("sharePrice()"), "broken");
        _expectSwapRevert(abi.encodeWithSelector(AHyperQuoteHook.AmountExceedsRemaining.selector));
        _swap(true, true, X, 0);
        vm.warp(uint256(validUntil) + 1);
        _expectSwapRevert(abi.encodeWithSelector(AHyperQuoteHook.QuoteExpired.selector));
        _swap(true, true, X, 0);
    }

    /// @dev Only the canonical pool can be initialised, so no other pool can reach beforeSwap; the check behind that
    /// is exercised by calling the hook as the PoolManager with another key.
    function test_beforeSwap_otherKey_reverts() public {
        PoolKey memory other = key;
        other.fee = 3000;
        vm.prank(POOL_MANAGER);
        vm.expectRevert(AHyperQuoteHook.WrongPool.selector);
        hook.beforeSwap(
            seller, other, IPoolManager.SwapParams({zeroForOne: false, amountSpecified: -1e6, sqrtPriceLimitX96: 0}), ""
        );
    }

    /// @dev setParams never stores a discount below 1 - MAX_BID_BPS; written straight into storage (slot 0: validUntil
    /// bits 0-39, discountBps 40-55, remaining 56-183), the fill-level ceiling still refuses it.
    function test_fillCeiling_holdsEvenIfStoredDiscountBreaksIt() public {
        uint256 packed = uint256(validUntil) | (uint256(9) << 40) | (uint256(REMAINING) << 56);
        vm.store(address(hook), bytes32(0), bytes32(packed));
        (uint40 v, uint16 d, uint128 r) = hook.params();
        assertEq(v, validUntil);
        assertEq(d, 9);
        assertEq(r, REMAINING);
        _expectSwapRevert(abi.encodeWithSelector(AHyperQuoteHook.PriceAboveCeiling.selector));
        _swap(true, true, X, 0);
        _expectSwapRevert(abi.encodeWithSelector(AHyperQuoteHook.PriceAboveCeiling.selector));
        _swap(true, false, 1_000e6, type(uint128).max);
    }

    /// @dev sharePrice() reads the strategy's own books, not balances. At the block aHYPER is at its deposit cap
    /// (maxDeposit 0) and a redemption queues instead of paying out, so the only share-supply action available in the
    /// same transaction as a fill is a redeem request; a 1,000,000 aHYPER request (real shares, taken from Morpho's
    /// collateral balance) settles accrued interest, which moves the price by about 1e-14, and leaves the fill unchanged.
    function test_sameTxRedeemRequest_doesNotMovePrice() public {
        address whale = makeAddr("whale");
        assertEq(IAHyperLike(AHYPER).maxDeposit(whale), 0, "precondition: deposits are capped");
        vm.prank(MORPHO);
        IERC20Like(AHYPER).transfer(whale, 1_000_000e6);
        vm.prank(whale);
        IAHyperLike(AHYPER).requestRedeem(1_000_000e6, whale, whale);
        assertEq(IAHyperLike(AHYPER).maxRedeem(whale), 0, "precondition: the request queued");
        assertApproxEqRel(IShareLike(AHYPER).sharePrice(), SHARE_PRICE, 1e6, "price moves by at most 1e-12");
        _sellAndCheck(true, X, X, X_OUT_25);
    }

    function test_zeroSharePrice_reverts() public {
        vm.mockCall(AHYPER, abi.encodeWithSignature("sharePrice()"), abi.encode(uint256(0)));
        _expectSwapRevert(abi.encodeWithSelector(AHyperQuoteHook.ZeroPrice.selector));
        _swap(true, true, X, 0);
        vm.prank(maker);
        vm.expectRevert(AHyperQuoteHook.ZeroPrice.selector);
        hook.setParams(AHyperQuoteHook.Params({validUntil: validUntil, discountBps: DISCOUNT, remaining: 1}), REMAINING);
    }

    function test_setParams_bounds() public {
        vm.startPrank(maker);
        vm.expectRevert(AHyperQuoteHook.PriceAboveCeiling.selector);
        hook.setParams(AHyperQuoteHook.Params({validUntil: validUntil, discountBps: 9, remaining: 1}), REMAINING);
        vm.expectRevert(AHyperQuoteHook.ZeroPrice.selector);
        hook.setParams(AHyperQuoteHook.Params({validUntil: validUntil, discountBps: 10_000, remaining: 1}), REMAINING);
        // Closed bids are not checked.
        hook.setParams(AHyperQuoteHook.Params({validUntil: validUntil, discountBps: 0, remaining: 0}), REMAINING);
        hook.setParams(AHyperQuoteHook.Params({validUntil: 0, discountBps: 60_000, remaining: 1}), 0);
        vm.stopPrank();
    }

    function test_setParams_onlyMaker() public {
        vm.expectRevert(AHyperQuoteHook.NotMaker.selector);
        hook.setParams(AHyperQuoteHook.Params({validUntil: 0, discountBps: 0, remaining: 0}), 0);
    }

    function test_hookCallbacks_onlyPoolManager() public {
        vm.expectRevert(AHyperQuoteHook.NotPoolManager.selector);
        hook.beforeSwap(
            address(this),
            key,
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: -1, sqrtPriceLimitX96: 0}),
            ""
        );
        vm.expectRevert(AHyperQuoteHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);
        vm.expectRevert(AHyperQuoteHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(AHYPER, uint256(1)));
    }

    function test_otherPool_cannotInitialise() public {
        PoolKey memory other = key;
        other.fee = 3000;
        other.tickSpacing = 60;
        vm.expectRevert(
            _wrapped(IHooks.beforeInitialize.selector, abi.encodeWithSelector(AHyperQuoteHook.WrongPool.selector))
        );
        pm.initialize(other, SQRT_PRICE_1_1);
    }

    // ------------------------------------------------------------------ funding

    /// @dev The maker's approval bounds what the hook can pay.
    function test_shareAllowance_boundsFunding() public {
        uint256 enough = apex.previewWithdraw(X_OUT_25);
        vm.prank(maker);
        apex.approve(address(hook), enough - 1);
        vm.expectRevert();
        _swap(true, true, X, 0);
        vm.prank(maker);
        apex.approve(address(hook), enough);
        _sellAndCheck(true, X, X, X_OUT_25);
        assertEq(apex.allowance(maker, address(hook)), 0, "allowance spent exactly");
    }

    function test_makerPosition_boundsFunding() public {
        _post(DISCOUNT, type(uint128).max);
        // The position is worth previewRedeem(shares); one USDC base unit more cannot be paid.
        uint256 worth = apex.previewRedeem(apex.balanceOf(maker));
        assertApproxEqAbs(worth, MAKER_DEPOSIT, 1, "position = deposit");
        deal(AHYPER, seller, 10_000_000e6);
        vm.expectRevert();
        _swap(true, false, worth + 1, type(uint128).max);
        (, uint256 received) = _sell(false, worth, type(uint128).max);
        assertEq(received, worth);
        assertLt(apex.previewRedeem(apex.balanceOf(maker)), 1, "position spent");
    }

    /// @dev With Apex lending into a borrowed market (the aHYPER/USDC market, enabled here by the owner through the
    /// 3-day cap timelock), a fill withdraws from that market up to its free liquidity, and a fill above what the vault
    /// can withdraw reverts as a whole: the seller keeps the aHYPER and the maker keeps the position.
    function test_borrowedMarket_fundsUpToLiquidity_thenRevertsWhole() public {
        MarketParams memory mp = MarketParams({
            loanToken: USDC,
            collateralToken: AHYPER,
            oracle: 0x4af4f38164cD7F28653A66aa2255B249a23cFBec,
            irm: 0x09475a3D6eA8c314c592b1a3799bDE044E2F400F,
            lltv: 770000000000000000
        });
        MarketParams memory idle =
            MarketParams({loanToken: USDC, collateralToken: address(0), oracle: address(0), irm: address(0), lltv: 0});
        vm.startPrank(APEX_OWNER);
        apex.submitCap(mp, type(uint184).max);
        vm.warp(block.timestamp + apex.timelock());
        apex.acceptCap(mp);
        bytes32[] memory sq = new bytes32[](1);
        sq[0] = AHYPER_MARKET;
        apex.setSupplyQueue(sq);
        // Withdraw queue is now [idle, aHYPER]; put the aHYPER market first.
        uint256[] memory order = new uint256[](2);
        order[0] = 1;
        order[1] = 0;
        apex.updateWithdrawQueue(order);
        MarketAllocation[] memory alloc = new MarketAllocation[](2);
        alloc[0] = MarketAllocation({marketParams: idle, assets: 0});
        alloc[1] = MarketAllocation({marketParams: mp, assets: type(uint256).max});
        apex.reallocate(alloc);
        vm.stopPrank();
        _post(DISCOUNT, type(uint128).max);

        // A borrower takes the market down to 1,000,000 USDC of free liquidity, below the maker's position.
        IMorphoLike(MORPHO).accrueInterest(mp);
        (uint128 supplied,, uint128 borrowed,,,) = IMorphoLike(MORPHO).market(AHYPER_MARKET);
        address borrower = makeAddr("borrower");
        deal(AHYPER, borrower, 40_000_000e6);
        vm.startPrank(borrower);
        IERC20Like(AHYPER).approve(MORPHO, type(uint256).max);
        IMorphoLike(MORPHO).supplyCollateral(mp, 40_000_000e6, borrower, "");
        IMorphoLike(MORPHO).borrow(mp, uint256(supplied) - borrowed - 1_000_000e6, 0, borrower, borrower);
        vm.stopPrank();
        (supplied,, borrowed,,,) = IMorphoLike(MORPHO).market(AHYPER_MARKET);
        uint256 free = uint256(supplied) - borrowed;
        assertEq(free, 1_000_000e6);
        assertLt(free, MAKER_DEPOSIT, "precondition: the market cannot return the whole position");
        deal(AHYPER, seller, 20_000_000e6);

        uint256 sellerShares = IERC20Like(AHYPER).balanceOf(seller);
        uint256 makerPosition = apex.balanceOf(maker);
        vm.expectRevert();
        _swap(true, false, free + 1, type(uint128).max);
        assertEq(IERC20Like(AHYPER).balanceOf(seller), sellerShares, "seller kept aHYPER");
        assertEq(apex.balanceOf(maker), makerPosition, "maker kept the position");

        vm.recordLogs();
        (, uint256 received) = _sell(false, free, type(uint128).max);
        assertEq(received, free, "filled exactly the free liquidity");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool withdrewFromMarket;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == MORPHO && logs[i].topics[0] == MORPHO_WITHDRAW_TOPIC
                    && logs[i].topics[1] == AHYPER_MARKET
            ) {
                withdrewFromMarket = true;
            }
        }
        assertTrue(withdrewFromMarket, "withdrawn from the borrowed market");
        assertEq(IERC20Like(USDC).balanceOf(maker), 0, "maker idle USDC stays 0");
    }

    // ------------------------------------------------------------------ strategy pause and remaining race

    function _pauseStrategy() internal {
        vm.prank(IStrategyAdmin(STRATEGY).investmentManager());
        IStrategyAdmin(STRATEGY).pause();
        assertTrue(IStrategyAdmin(STRATEGY).paused(), "precondition: strategy paused");
    }

    /// @dev A paused strategy blocks aHYPER ERC-20 transfers, so a router sale reverts anyway; a sale paid with aHYPER
    /// already in the PoolManager would not, and the hook refuses it. Opening a bid is refused too; the kill switch
    /// still works.
    function test_strategyPaused_stopsFillsAndOpening() public {
        deal(AHYPER, address(this), X);
        pm.unlock(abi.encode(uint256(2)));
        _pauseStrategy();
        vm.expectRevert();
        _swap(true, true, X, 0);
        _expectSwapRevert(abi.encodeWithSelector(AHyperQuoteHook.StrategyPaused.selector));
        pm.unlock(abi.encode(uint256(3)));
        assertEq(_claim(AHYPER), 0, "nothing bought");

        vm.startPrank(maker);
        vm.expectRevert(AHyperQuoteHook.StrategyPaused.selector);
        hook.setParams(AHyperQuoteHook.Params({validUntil: validUntil, discountBps: DISCOUNT, remaining: 1}), REMAINING);
        hook.setParams(AHyperQuoteHook.Params({validUntil: 0, discountBps: 0, remaining: 0}), 0);
        vm.stopPrank();
    }

    /// @dev The strategy's manager can switch aHYPER transfers off. Router sales then revert anyway; a sale paid with
    /// aHYPER already in the PoolManager would not, and the hook refuses it. Opening a bid is refused too; the kill
    /// switch and sweep(USDC) still work.
    function test_sharesNotTransferable_stopsFillsAndOpening() public {
        deal(AHYPER, address(this), X);
        pm.unlock(abi.encode(uint256(2)));
        deal(USDC, address(this), 2e6);
        pm.unlock(abi.encode(uint256(1)));
        vm.prank(IStrategyAdmin(STRATEGY).investmentManager());
        IStrategyAdmin(STRATEGY).setSharesTransferable(false);
        assertFalse(IStrategyAdmin(AHYPER).transferableShares(), "precondition: transfers off");

        vm.expectRevert();
        _swap(true, true, X, 0);
        _expectSwapRevert(abi.encodeWithSelector(AHyperQuoteHook.SharesNotTransferable.selector));
        pm.unlock(abi.encode(uint256(3)));
        assertEq(_claim(AHYPER), 0, "nothing bought");

        vm.startPrank(maker);
        vm.expectRevert(AHyperQuoteHook.SharesNotTransferable.selector);
        hook.setParams(AHyperQuoteHook.Params({validUntil: validUntil, discountBps: DISCOUNT, remaining: 1}), REMAINING);
        hook.setParams(AHyperQuoteHook.Params({validUntil: 0, discountBps: 0, remaining: 0}), 0);
        vm.stopPrank();
        assertEq(hook.sweep(USDC), 2e6, "USDC still sweeps");
    }

    /// @dev Unpaused, the same PoolManager-paid sale fills at the bid: the pause check is what stopped it above.
    function test_poolManagerPaidSale_fillsWhenUnpaused() public {
        deal(AHYPER, address(this), X);
        pm.unlock(abi.encode(uint256(2)));
        pm.unlock(abi.encode(uint256(3)));
        assertEq(IERC20Like(USDC).balanceOf(address(this)), X_OUT_25, "sold at the bid");
        assertEq(_claim(AHYPER), X);
    }

    /// @dev A fill that lands between the maker reading the bid and re-posting it makes the re-post revert, so the
    /// maker never buys that fill's amount twice; the kill switch ignores the expected value.
    function test_setParams_staleExpectedRemaining_reverts() public {
        _sell(true, X, 0);
        AHyperQuoteHook.Params memory p =
            AHyperQuoteHook.Params({validUntil: validUntil, discountBps: 30, remaining: REMAINING});
        vm.startPrank(maker);
        vm.expectRevert(abi.encodeWithSelector(AHyperQuoteHook.RemainingChanged.selector, REMAINING - uint128(X)));
        hook.setParams(p, REMAINING);
        hook.setParams(p, REMAINING - uint128(X));
        (, uint16 d, uint128 r) = hook.params();
        assertEq(d, 30);
        assertEq(r, REMAINING);
        hook.setParams(AHyperQuoteHook.Params({validUntil: 0, discountBps: 0, remaining: 0}), 12_345);
        vm.stopPrank();
        assertEq(_remaining(), 0);
    }

    /// @dev While the strategy is paused aHYPER cannot move, so sweep() reverts; sweep(USDC) still moves the USDC.
    function test_sweepPerCurrency_whileStrategyPaused() public {
        _sell(true, X, 0);
        deal(USDC, address(this), 2e6);
        pm.unlock(abi.encode(uint256(1)));
        _pauseStrategy();
        vm.expectRevert();
        hook.sweep();
        vm.expectRevert();
        hook.sweep(AHYPER);
        uint256 makerUsdc = IERC20Like(USDC).balanceOf(maker);
        assertEq(hook.sweep(USDC), 2e6);
        assertEq(IERC20Like(USDC).balanceOf(maker) - makerUsdc, 2e6, "USDC reached the maker");
        assertEq(_claim(AHYPER), X, "aHYPER claim waits for the unpause");
        vm.expectRevert(AHyperQuoteHook.UnknownCurrency.selector);
        hook.sweep(APEX);
    }

    // ------------------------------------------------------------------ sweep

    function test_sweep_movesClaimsAndStrays_toMaker() public {
        _sell(true, X, 0);
        // Anyone may send the hook tokens or claims; all of it is the maker's.
        deal(USDC, address(this), 7e6);
        IERC20Like(USDC).transfer(address(hook), 5e6);
        deal(AHYPER, address(this), 3e6);
        IERC20Like(AHYPER).transfer(address(hook), 3e6);
        pm.unlock(abi.encode(uint8(1)));

        uint256 makerShares = IERC20Like(AHYPER).balanceOf(maker);
        uint256 makerUsdc = IERC20Like(USDC).balanceOf(maker);
        vm.prank(makeAddr("anyone"));
        (uint256 s, uint256 a) = hook.sweep();
        assertEq(s, X + 3e6);
        assertEq(a, 2e6 + 5e6);
        assertEq(IERC20Like(AHYPER).balanceOf(maker) - makerShares, X + 3e6, "maker got aHYPER");
        assertEq(IERC20Like(USDC).balanceOf(maker) - makerUsdc, 7e6, "maker got USDC");
        assertEq(_claim(AHYPER) + _claim(USDC), 0, "no claims left");
        _assertHookHoldsNoErc20();

        (s, a) = hook.sweep();
        assertEq(s + a, 0, "second sweep moves nothing");
    }

    // ------------------------------------------------------------------ protocol fee

    function test_maxProtocolFee_takesNothing() public {
        address controller = makeAddr("controller");
        vm.prank(IPoolManagerOwned(POOL_MANAGER).owner());
        IPoolManagerOwned(POOL_MANAGER).setProtocolFeeController(controller);
        vm.prank(controller);
        pm.setProtocolFee(key, 1000 | (1000 << 12));
        uint256 feesUsdc = pm.protocolFeesAccrued(Currency.wrap(USDC));
        uint256 feesShare = pm.protocolFeesAccrued(Currency.wrap(AHYPER));

        _sellAndCheck(true, X, X, X_OUT_25);
        _sellAndCheck(false, 1_000e6, IN_FOR_1000_25, 1_000e6);
        assertEq(pm.protocolFeesAccrued(Currency.wrap(USDC)), feesUsdc, "USDC protocol fees unchanged");
        assertEq(pm.protocolFeesAccrued(Currency.wrap(AHYPER)), feesShare, "aHYPER protocol fees unchanged");
    }

    // ------------------------------------------------------------------ liquidity

    /// @dev Adds a position around the 1:1 price, sells both ways at the no-liquidity amounts and checks a buy still
    /// reverts, then removes it: price, liquidity and fee growth never move and the position earns nothing.
    function test_liquidityAllowed_neverTraded() public {
        deal(AHYPER, address(this), 1_000e6);
        deal(USDC, address(this), 1_000e6);
        int256 liquidity = 1e9;
        PoolId id = key.toId();
        (BalanceDelta added, BalanceDelta addFees) =
            abi.decode(pm.unlock(abi.encode(liquidity)), (BalanceDelta, BalanceDelta));
        assertLt(added.amount0(), 0);
        assertLt(added.amount1(), 0);
        assertEq(BalanceDelta.unwrap(addFees), 0);

        (uint160 sqrtBefore, int24 tickBefore,,) = StateLibrary.getSlot0(pm, id);
        (uint256 fg0Before, uint256 fg1Before) = StateLibrary.getFeeGrowthGlobals(pm, id);
        _sellAndCheck(true, X, X, X_OUT_25);
        _sellAndCheck(false, 1_000e6, IN_FOR_1000_25, 1_000e6);
        _expectSwapRevert(abi.encodeWithSelector(AHyperQuoteHook.AskNotOffered.selector));
        _swap(false, true, 1e6, 0);
        (uint160 sqrtAfter, int24 tickAfter,,) = StateLibrary.getSlot0(pm, id);
        (uint256 fg0After, uint256 fg1After) = StateLibrary.getFeeGrowthGlobals(pm, id);
        assertEq(sqrtAfter, sqrtBefore, "price unmoved");
        assertEq(tickAfter, tickBefore);
        assertEq(fg0After, fg0Before, "no fee growth 0");
        assertEq(fg1After, fg1Before, "no fee growth 1");
        assertEq(StateLibrary.getLiquidity(pm, id), uint128(uint256(liquidity)), "liquidity unchanged");

        (BalanceDelta removed, BalanceDelta removeFees) =
            abi.decode(pm.unlock(abi.encode(-liquidity)), (BalanceDelta, BalanceDelta));
        assertEq(BalanceDelta.unwrap(removeFees), 0, "position earned no fees");
        assertApproxEqAbs(int256(removed.amount0()), -int256(added.amount0()), 1, "principal 0 returned");
        assertApproxEqAbs(int256(removed.amount1()), -int256(added.amount1()), 1, "principal 1 returned");
    }

    /// @dev Unlock payloads: an int256 modifies a [-10, 10] position and settles it; uint 1 donates a 2 USDC ERC6909
    /// claim to the hook (minted against USDC paid in); uint 2 parks X aHYPER in the PoolManager as this contract's
    /// claim; uint 3 sells X aHYPER exact-in straight through the PoolManager, paying with that claim.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        uint256 mode = data.length == 32 ? uint256(bytes32(data)) : 0;
        if (mode == 1) {
            pm.sync(Currency.wrap(USDC));
            IERC20Like(USDC).transfer(POOL_MANAGER, 2e6);
            pm.settle();
            pm.mint(address(hook), uint256(uint160(USDC)), 2e6);
            return "";
        }
        if (mode == 2) {
            pm.sync(Currency.wrap(AHYPER));
            IERC20Like(AHYPER).transfer(POOL_MANAGER, X);
            pm.settle();
            pm.mint(address(this), uint256(uint160(AHYPER)), X);
            return "";
        }
        if (mode == 3) {
            BalanceDelta d = pm.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: false, amountSpecified: -int256(X), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            pm.burn(address(this), uint256(uint160(AHYPER)), X);
            pm.take(Currency.wrap(USDC), address(this), uint128(d.amount0()));
            return "";
        }
        int256 liquidityDelta = abi.decode(data, (int256));
        (BalanceDelta callerDelta, BalanceDelta fees) = pm.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -10, tickUpper: 10, liquidityDelta: liquidityDelta, salt: 0
            }),
            ""
        );
        _settleOrTake(key.currency0, callerDelta.amount0());
        _settleOrTake(key.currency1, callerDelta.amount1());
        return abi.encode(callerDelta, fees);
    }

    function _settleOrTake(Currency currency, int128 amount) private {
        if (amount < 0) {
            pm.sync(currency);
            IERC20Like(Currency.unwrap(currency)).transfer(POOL_MANAGER, uint128(-amount));
            pm.settle();
        } else if (amount > 0) {
            pm.take(currency, address(this), uint128(amount));
        }
    }

    // ------------------------------------------------------------------ quoter

    /// @dev Uniswap's off-chain routing prices v4 pools through this quoter with empty hookData.
    function test_quoter_matchesSwap() public {
        (uint256 quotedOut,) = IV4Quoter(V4_QUOTER)
            .quoteExactInputSingle(
                QuoteExactSingleParams({poolKey: key, zeroForOne: false, exactAmount: uint128(X), hookData: ""})
            );
        (uint256 quotedIn,) = IV4Quoter(V4_QUOTER)
            .quoteExactOutputSingle(
                QuoteExactSingleParams({poolKey: key, zeroForOne: false, exactAmount: 1_000e6, hookData: ""})
            );
        assertEq(quotedOut, X_OUT_25, "exact-in quote");
        assertEq(quotedIn, IN_FOR_1000_25, "exact-out quote");
        assertEq(_remaining(), REMAINING, "quotes left no state");
        assertEq(_claim(AHYPER), 0);
        _sellAndCheck(true, X, X, quotedOut);
        _sellAndCheck(false, 1_000e6, quotedIn, 1_000e6);
    }

    // ------------------------------------------------------------------ gas

    function test_gas_bid() public {
        uint256 g = _swap(true, true, X, 0);
        console2.log("gas: router execute, bid exact-in", g);
        g = _swap(true, false, 1_000e6, type(uint128).max);
        console2.log("gas: router execute, bid exact-out", g);
        g = gasleft();
        hook.sweep();
        console2.log("gas: sweep", g - gasleft());
    }
}

/// @dev A third party may initialise the canonical pool at any price before the maker does; fills are unaffected
/// because every accepted swap reaches Pool.swap with amountSpecified 0.
abstract contract FrontRunInitCases is AHyperHookForkBase {
    function test_frontRunInit_fillsUnchanged() public {
        _sellAndCheck(true, X, X, X_OUT_25);
        _sellAndCheck(false, 1_000e6, IN_FOR_1000_25, 1_000e6);
    }
}

contract AHyperQuoteHookFrontRunMinPriceForkTest is FrontRunInitCases {
    function _initPrice() internal pure override returns (uint160) {
        return TickMath.MIN_SQRT_PRICE;
    }
}

contract AHyperQuoteHookFrontRunMaxPriceForkTest is FrontRunInitCases {
    function _initPrice() internal pure override returns (uint160) {
        return TickMath.MAX_SQRT_PRICE - 1;
    }
}
