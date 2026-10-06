// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./HookFixture.sol";
import {PaperHook} from "../src/PaperHook.sol";
import {PaperSwapRouter} from "../src/PaperSwapRouter.sol";
import {PoolRouter} from "./mocks/PoolRouter.sol";
import {HostilePaper} from "./mocks/HostilePaper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract RouterTest is HookFixture {
    using BalanceDeltaLibrary for BalanceDelta;
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;

    PaperSwapRouter internal swapRouter;
    address private constant RECIPIENT = address(0xBEEF);

    struct SwapSnapshot {
        IERC20 input;
        IERC20 output;
        uint256 inputBalance;
        uint256 outputBalance;
        uint256 orders;
        uint256 dev;
        uint256 budget;
    }

    function setUp() public virtual override {
        super.setUp();
        _createSwapRouter();
    }

    function _createSwapRouter() internal {
        swapRouter = new PaperSwapRouter(hook);
        paper.approve(address(swapRouter), type(uint256).max);
        imd.approve(address(swapRouter), type(uint256).max);
    }

    function _params(bool buy, bool exactInput, uint256 amount) internal view returns (SwapParams memory) {
        bool zeroForOne = buy == (Currency.unwrap(key.currency0) == IMD);
        return SwapParams(
            zeroForOne,
            exactInput ? -int256(amount) : int256(amount),
            zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341
        );
    }

    function _checkRouterSettled() internal view {
        _checkSettled();
        IPoolManager pm = manager;
        assertEq(pm.currencyDelta(address(swapRouter), key.currency0), 0);
        assertEq(pm.currencyDelta(address(swapRouter), key.currency1), 0);
        assertEq(imd.balanceOf(address(swapRouter)), 0);
        assertEq(paper.balanceOf(address(swapRouter)), 0);
    }

    function _verifySwap(bool buy, bool exactInput, uint256 amount) internal {
        SwapSnapshot memory s;
        s.input = buy ? IERC20(IMD) : IERC20(address(paper));
        s.output = buy ? IERC20(address(paper)) : IERC20(IMD);
        s.inputBalance = s.input.balanceOf(address(this));
        s.outputBalance = s.output.balanceOf(RECIPIENT);
        s.orders = imd.balanceOf(ORDERS);
        s.dev = imd.balanceOf(DEV);
        s.budget = exactInput ? amount : amount * 2;
        BalanceDelta delta =
            swapRouter.swap(_params(buy, exactInput, amount), s.budget, 1, RECIPIENT, type(uint256).max);
        uint256 spent = uint256(-int256(buy ? _imdDelta(delta) : _paperDelta(delta)));
        uint256 received = uint256(int256(buy ? _paperDelta(delta) : _imdDelta(delta)));
        assertEq(s.inputBalance - s.input.balanceOf(address(this)), spent);
        assertEq(s.output.balanceOf(RECIPIENT) - s.outputBalance, received);
        assertLe(spent, s.budget);
        if (exactInput) {
            assertEq(spent, amount);
        } else {
            assertEq(received, amount);
            assertLt(spent, s.budget);
        }
        uint256 orders = imd.balanceOf(ORDERS) - s.orders;
        uint256 dev = imd.balanceOf(DEV) - s.dev;
        uint256 fee = orders + dev;
        uint256 grossImd = buy ? spent : received + fee;
        assertEq(fee, grossImd * 200 / 10_000);
        assertEq(orders, fee * 50 / 200);
        assertEq(dev, fee - orders);
        _checkRouterSettled();
    }

    function test_buyExactInput() public {
        _verifySwap(true, true, 100 ether);
    }

    function test_buyExactOutputRefundsUnusedBudget() public {
        _verifySwap(true, false, 100 ether);
    }

    function test_sellExactInput() public {
        _verifySwap(false, true, 100 ether);
    }

    function test_sellExactOutputRefundsUnusedBudget() public {
        _verifySwap(false, false, 100 ether);
    }

    function testFuzz_allModesConserveFunds(uint96 rawAmount, bool buy, bool exactInput) public {
        _verifySwap(buy, exactInput, bound(uint256(rawAmount), 1e12, 1e20));
    }

    function _paperOnlyPool() internal {
        manager = new PoolManager(address(this));
        router = new PoolRouter(manager);
        hook = _deploy(address(new PaperHook(manager)), Q96);
        key = hook.poolKey();
        paper.approve(address(router), type(uint256).max);
        bool paperIs0 = Currency.unwrap(key.currency0) == address(paper);
        router.liquidity(
            key,
            ModifyLiquidityParams(paperIs0 ? int24(60) : int24(-120), paperIs0 ? int24(120) : int24(-60), LIQUIDITY, 0)
        );
        assertGt(paper.balanceOf(address(manager)), 0);
        assertEq(imd.balanceOf(address(manager)), 0);
        _createSwapRouter();
    }

    function test_firstBuyFromPaperOnlyPoolPaysBothWalletsWithoutBacking() public {
        _paperOnlyPool();
        _verifySwap(true, true, 100 ether);
        assertEq(imd.balanceOf(ORDERS), 0.5 ether);
        assertEq(imd.balanceOf(DEV), 1.5 ether);
        assertEq(imd.balanceOf(address(manager)), 98 ether);
    }

    function test_firstExactOutputBuyFromPaperOnlyPoolRefundsBudget() public {
        _paperOnlyPool();
        _verifySwap(true, false, 100 ether);
        assertGt(imd.balanceOf(ORDERS), 0);
        assertGt(imd.balanceOf(DEV), 0);
    }

    function test_excessiveMinOutputRollsBackPrepaymentAndFees() public {
        uint256 inputBefore = imd.balanceOf(address(this));
        uint256 managerBefore = imd.balanceOf(address(manager));
        vm.expectRevert(PaperSwapRouter.Slippage.selector);
        swapRouter.swap(_params(true, true, 100 ether), 100 ether, 200 ether, RECIPIENT, type(uint256).max);
        assertEq(imd.balanceOf(address(this)), inputBefore);
        assertEq(imd.balanceOf(address(manager)), managerBefore);
        assertEq(imd.balanceOf(ORDERS), 0);
        assertEq(imd.balanceOf(DEV), 0);
        assertEq(paper.balanceOf(RECIPIENT), 0);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(price, Q96);
        _checkRouterSettled();
    }

    function test_insufficientExactOutputBudgetRollsBack() public {
        uint256 inputBefore = imd.balanceOf(address(this));
        vm.expectRevert(PaperSwapRouter.Slippage.selector);
        swapRouter.swap(_params(true, false, 100 ether), 1 ether, 100 ether, RECIPIENT, type(uint256).max);
        assertEq(imd.balanceOf(address(this)), inputBefore);
        assertEq(imd.balanceOf(ORDERS), 0);
        assertEq(imd.balanceOf(DEV), 0);
        _checkRouterSettled();
    }

    function test_partialExactOutputRollsBackEvenWithLowMinimum() public {
        SwapParams memory params = _params(true, false, 1e22);
        params.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(params.zeroForOne ? int24(-1) : int24(1));
        uint256 inputBefore = imd.balanceOf(address(this));
        vm.expectRevert(PaperSwapRouter.Slippage.selector);
        swapRouter.swap(params, 2e22, 1, RECIPIENT, type(uint256).max);
        assertEq(imd.balanceOf(address(this)), inputBefore);
        assertEq(paper.balanceOf(RECIPIENT), 0);
        assertEq(imd.balanceOf(ORDERS), 0);
        assertEq(imd.balanceOf(DEV), 0);
        _checkRouterSettled();
    }

    function test_expiredDeadlineDoesNotPullFunds() public {
        uint256 inputBefore = imd.balanceOf(address(this));
        vm.warp(100);
        vm.expectRevert(PaperSwapRouter.Expired.selector);
        swapRouter.swap(_params(true, true, 100 ether), 100 ether, 1, RECIPIENT, 99);
        assertEq(imd.balanceOf(address(this)), inputBefore);
        _checkRouterSettled();
    }

    function test_zeroRecipientRefused() public {
        vm.expectRevert(PaperSwapRouter.InvalidSwap.selector);
        swapRouter.swap(_params(true, true, 100 ether), 100 ether, 1, address(0), type(uint256).max);
        _checkRouterSettled();
    }

    function test_callbackRequiresManagerAndActiveRequest() public {
        vm.expectRevert(PaperSwapRouter.UnauthorizedCallback.selector);
        swapRouter.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(PaperSwapRouter.UnauthorizedCallback.selector);
        swapRouter.unlockCallback("");
        _checkRouterSettled();
    }

    function test_attackerCannotSpendAnotherAccountsApproval() public {
        address attacker = address(0xA77AC);
        uint256 victimBefore = imd.balanceOf(address(this));
        assertEq(imd.allowance(address(this), address(swapRouter)), type(uint256).max);
        vm.prank(attacker);
        vm.expectRevert();
        swapRouter.swap(_params(true, true, 100 ether), 100 ether, 1, attacker, type(uint256).max);
        assertEq(imd.balanceOf(address(this)), victimBefore);
        assertEq(imd.balanceOf(attacker), 0);
        assertEq(paper.balanceOf(attacker), 0);
        _checkRouterSettled();
    }

    function test_inputTokenCannotReenterSwap() public {
        HostilePaper template = new HostilePaper();
        vm.etch(IMD, address(template).code);
        HostilePaper hostile = HostilePaper(IMD);
        hostile.configure(
            address(swapRouter),
            abi.encodeCall(
                PaperSwapRouter.swap, (_params(true, true, 1 ether), 1 ether, 1, RECIPIENT, type(uint256).max)
            ),
            false,
            false
        );
        _verifySwap(true, true, 100 ether);
        assertFalse(hostile.reentrySucceeded());
        assertEq(hostile.reentryError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    function test_shortInputTransferRollsBack() public {
        HostilePaper template = new HostilePaper();
        vm.etch(IMD, address(template).code);
        HostilePaper(IMD).configure(address(0), "", true, false);
        uint256 inputBefore = imd.balanceOf(address(this));
        vm.expectRevert(PaperSwapRouter.InexactTransfer.selector);
        swapRouter.swap(_params(true, true, 100 ether), 100 ether, 1, RECIPIENT, type(uint256).max);
        assertEq(imd.balanceOf(address(this)), inputBefore);
        _checkRouterSettled();
    }

    function test_unrelatedRouterDepositsAreNotRefundedToTrader() public {
        imd.transfer(address(swapRouter), 7 ether);
        paper.transfer(address(swapRouter), 11 ether);
        uint256 inputBefore = imd.balanceOf(address(this));
        BalanceDelta delta =
            swapRouter.swap(_params(true, false, 100 ether), 200 ether, 100 ether, RECIPIENT, type(uint256).max);
        assertEq(inputBefore - imd.balanceOf(address(this)), uint256(-int256(_imdDelta(delta))));
        assertEq(imd.balanceOf(address(swapRouter)), 7 ether);
        assertEq(paper.balanceOf(address(swapRouter)), 11 ether);
        assertEq(paper.balanceOf(RECIPIENT), 100 ether);
        _checkSettled();
    }
}

contract RouterReverseOrderTest is RouterTest {
    function _tokenAddress() internal pure override returns (address) {
        return address(type(uint160).max - 10);
    }
}
