// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./HookFixture.sol";
import {PaperHook} from "../src/PaperHook.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolRouter} from "./mocks/PoolRouter.sol";

contract FeesTest is HookFixture {
    using StateLibrary for IPoolManager;

    function _verifySwap(bool buy, bool exactInput, uint256 amount) internal {
        uint256 ordersBefore = imd.balanceOf(ORDERS);
        uint256 devBefore = imd.balanceOf(DEV);
        uint256 traderBefore = imd.balanceOf(address(this));
        uint256 managerBefore = imd.balanceOf(address(manager));
        BalanceDelta delta = _swap(buy, exactInput, amount);
        int128 leg = _imdDelta(delta);
        uint256 fee = imd.balanceOf(ORDERS) - ordersBefore + imd.balanceOf(DEV) - devBefore;
        uint256 gross = buy ? uint256(-int256(leg)) : uint256(int256(leg)) + fee;
        assertGt(fee, 0);
        assertEq(fee, gross * 200 / 10_000);
        assertEq(imd.balanceOf(ORDERS) - ordersBefore, fee * 50 / 200);
        assertEq(imd.balanceOf(DEV) - devBefore, fee - fee * 50 / 200);
        if (buy) {
            assertEq(traderBefore - imd.balanceOf(address(this)), gross);
            assertEq(imd.balanceOf(address(manager)) - managerBefore, gross - fee);
            assertGt(_paperDelta(delta), 0);
        } else {
            assertEq(imd.balanceOf(address(this)) - traderBefore, gross - fee);
            assertEq(managerBefore - imd.balanceOf(address(manager)), gross);
            assertLt(_paperDelta(delta), 0);
        }
        if (exactInput) assertEq(buy ? -int256(leg) : -int256(_paperDelta(delta)), int256(amount));
        else assertEq(buy ? int256(_paperDelta(delta)) : int256(leg), int256(amount));
        _checkSettled();
    }

    function test_buyExactInput() public {
        _verifySwap(true, true, 100 ether);
    }

    function test_sellExactInput() public {
        _verifySwap(false, true, 100 ether);
    }

    function test_buyExactOutput() public {
        _verifySwap(true, false, 100 ether);
    }

    function test_sellExactOutput() public {
        _verifySwap(false, false, 100 ether);
    }

    function testFuzz_allSwapModes(uint96 rawAmount, bool buy, bool exactInput) public {
        uint256 amount = bound(uint256(rawAmount), 1e12, 1e20);
        _verifySwap(buy, exactInput, amount);
    }

    function test_splitChangePayments() public {
        address a = address(123);
        address b = address(456);
        hook.setSplit(a, 125, b, 75);
        _swap(true, true, 100 ether);
        assertEq(imd.balanceOf(a), 1.25 ether);
        assertEq(imd.balanceOf(b), 0.75 ether);
        assertEq(imd.balanceOf(ORDERS), 0);
        assertEq(imd.balanceOf(DEV), 0);
        assertEq(hook.feeBps(), 200);
        _checkSettled();
    }

    function testFuzz_splitConservation(uint8 bps, uint96 rawAmount) public {
        uint256 ordersBps = bound(uint256(bps), 0, 200);
        uint256 amount = bound(uint256(rawAmount), 100, 1e20);
        hook.setSplit(ORDERS, ordersBps, DEV, 200 - ordersBps);
        _swap(true, true, amount);
        uint256 fee = amount / 50;
        assertEq(imd.balanceOf(ORDERS), fee * ordersBps / 200);
        assertEq(imd.balanceOf(DEV), fee - fee * ordersBps / 200);
        _checkSettled();
    }

    function test_splitInvalidAndUnauthorized() public {
        vm.prank(address(123));
        vm.expectRevert(PaperHook.Unauthorized.selector);
        hook.setSplit(ORDERS, 50, DEV, 150);
        vm.expectRevert(PaperHook.InvalidConfiguration.selector);
        hook.setSplit(ORDERS, 51, DEV, 150);
        vm.expectRevert(PaperHook.InvalidConfiguration.selector);
        hook.setSplit(address(0), 50, DEV, 150);
        vm.expectRevert(PaperHook.InvalidConfiguration.selector);
        hook.setSplit(address(hook), 50, DEV, 150);
        vm.expectRevert(PaperHook.InvalidConfiguration.selector);
        hook.setSplit(address(manager), 50, DEV, 150);
        vm.expectRevert(PaperHook.InvalidConfiguration.selector);
        hook.setSplit(ORDERS, type(uint256).max, DEV, 0);
        assertEq(hook.feeBps(), 200);
    }

    function test_zeroSplitAndSameRecipient() public {
        hook.setSplit(ORDERS, 0, DEV, 200);
        _swap(true, true, 100 ether);
        assertEq(imd.balanceOf(ORDERS), 0);
        assertEq(imd.balanceOf(DEV), 2 ether);
        hook.setSplit(ORDERS, 200, ORDERS, 0);
        _swap(true, true, 100 ether);
        assertEq(imd.balanceOf(ORDERS), 2 ether);
        _checkSettled();
    }

    function test_dustFeeRoundsDown() public {
        _swap(true, true, 49);
        assertEq(imd.balanceOf(ORDERS), 0);
        assertEq(imd.balanceOf(DEV), 0);
        _checkSettled();
    }

    function test_partialImdSpecifiedRevertsAndRollsBackFee() public {
        bool zeroForOne = Currency.unwrap(key.currency0) == IMD;
        uint160 limit = TickMath.getSqrtPriceAtTick(zeroForOne ? int24(-1) : int24(1));
        uint256 beforeBalance = imd.balanceOf(address(this));
        vm.expectRevert();
        router.swap(key, SwapParams(zeroForOne, -int256(1e22), limit));
        assertEq(imd.balanceOf(ORDERS), 0);
        assertEq(imd.balanceOf(DEV), 0);
        assertEq(imd.balanceOf(address(this)), beforeBalance);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(price, Q96);
        _checkSettled();
    }

    function test_partialPaperSpecifiedChargesActualImd() public {
        bool zeroForOne = Currency.unwrap(key.currency0) == address(paper);
        uint160 limit = TickMath.getSqrtPriceAtTick(zeroForOne ? int24(-1) : int24(1));
        BalanceDelta delta = router.swap(key, SwapParams(zeroForOne, -int256(1e22), limit));
        uint256 fee = imd.balanceOf(ORDERS) + imd.balanceOf(DEV);
        assertEq(fee, (uint256(int256(_imdDelta(delta))) + fee) / 50);
        assertLt(uint256(-int256(_paperDelta(delta))), 1e22);
        _checkSettled();
    }

    function test_insufficientBackingRevertsAtomically() public {
        uint256 beforeBalance = imd.balanceOf(address(this));
        deal(IMD, address(manager), 0);
        vm.expectRevert();
        _swap(true, true, 100 ether);
        assertEq(imd.balanceOf(address(this)), beforeBalance);
        assertEq(imd.balanceOf(ORDERS), 0);
        assertEq(imd.balanceOf(DEV), 0);
        _checkSettled();
    }

    function test_freshTokenOnlyPoolNeedsPrepaidImdFee() public {
        manager = new PoolManager(address(this));
        router = new PoolRouter(manager);
        PaperHook logic = new PaperHook(manager);
        hook = _deploy(address(logic), Q96);
        key = hook.poolKey();
        paper.approve(address(router), type(uint256).max);
        imd.approve(address(router), type(uint256).max);
        bool paperIs0 = Currency.unwrap(key.currency0) == address(paper);
        router.liquidity(
            key,
            ModifyLiquidityParams(paperIs0 ? int24(60) : int24(-120), paperIs0 ? int24(120) : int24(-60), LIQUIDITY, 0)
        );
        assertGt(paper.balanceOf(address(manager)), 0);
        assertEq(imd.balanceOf(address(manager)), 0);
        vm.expectRevert();
        _swap(true, true, 100 ether);
        assertEq(imd.balanceOf(ORDERS), 0);
        assertEq(imd.balanceOf(DEV), 0);
        // A router can instead pre-settle its input before swapping. Here the launch custodian backs the fee.
        imd.transfer(address(manager), 2 ether);
        BalanceDelta delta = _swap(true, true, 100 ether);
        assertGt(_paperDelta(delta), 0);
        assertEq(imd.balanceOf(ORDERS), 0.5 ether);
        assertEq(imd.balanceOf(DEV), 1.5 ether);
        _checkSettled();
    }

    function test_badAmountAndZeroSwap() public {
        vm.prank(address(manager));
        vm.expectRevert(PaperHook.AmountTooLarge.selector);
        hook.beforeSwap(address(router), key, SwapParams(true, type(int256).min, Q96 / 2), "");
        vm.expectRevert();
        _swap(true, true, 0);
    }
}

/// @notice Run every fee case again with IMD as currency0.
contract FeesReverseOrderTest is FeesTest {
    function _tokenAddress() internal pure override returns (address) {
        return address(type(uint160).max - 10);
    }
}
