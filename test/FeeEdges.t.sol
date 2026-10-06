// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./HookFixture.sol";
import {PaperSwapRouter} from "src/PaperSwapRouter.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Partial PAPER sells must refund prepaid input and price slippage on the net IMD received.
contract FeeEdgesTest is HookFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address private constant RECIPIENT = address(0xBEEF);
    PaperSwapRouter private prepaid;

    struct Balances {
        uint256 payerPaper;
        uint256 managerPaper;
        uint256 managerImd;
        uint256 recipientImd;
        uint256 ordersImd;
        uint256 devImd;
    }

    function setUp() public virtual override {
        super.setUp();
        prepaid = new PaperSwapRouter(hook);
    }

    function _partialSell(uint256 amount, int24 ticks) private view returns (SwapParams memory) {
        bool zeroForOne = Currency.unwrap(key.currency0) == address(paper);
        return SwapParams(zeroForOne, -int256(amount), TickMath.getSqrtPriceAtTick(zeroForOne ? -ticks : ticks));
    }

    function _balances() private view returns (Balances memory) {
        return Balances(
            paper.balanceOf(address(this)),
            paper.balanceOf(address(manager)),
            imd.balanceOf(address(manager)),
            imd.balanceOf(RECIPIENT),
            imd.balanceOf(ORDERS),
            imd.balanceOf(DEV)
        );
    }

    function _snapshot() private view returns (bytes32) {
        IPoolManager pm = manager;
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = pm.getSlot0(key.toId());
        (uint256 growth0, uint256 growth1) = pm.getFeeGrowthGlobals(key.toId());
        bytes32 poolState = keccak256(abi.encode(price, tick, protocolFee, lpFee, growth0, growth1));
        bytes32 custody = keccak256(
            abi.encode(
                paper.balanceOf(address(prepaid)),
                imd.balanceOf(address(prepaid)),
                paper.balanceOf(address(hook)),
                imd.balanceOf(address(hook)),
                paper.totalSupply(),
                imd.totalSupply()
            )
        );
        return keccak256(abi.encode(_balances(), poolState, custody, paper.allowance(address(this), address(prepaid))));
    }

    function _checkPrepaidSettled() private view {
        _checkSettled();
        IPoolManager pm = manager;
        assertEq(pm.currencyDelta(address(prepaid), key.currency0), 0);
        assertEq(pm.currencyDelta(address(prepaid), key.currency1), 0);
        assertEq(paper.balanceOf(address(prepaid)), 0);
        assertEq(imd.balanceOf(address(prepaid)), 0);
    }

    function _verifyPartial(SwapParams memory params, uint256 budget, uint256 minimum)
        private
        returns (uint256 received)
    {
        Balances memory beforeBalances = _balances();
        paper.approve(address(prepaid), budget);
        BalanceDelta delta = prepaid.swap(params, budget, minimum, RECIPIENT, block.timestamp);
        uint256 spent = uint256(-int256(_paperDelta(delta)));
        received = uint256(int256(_imdDelta(delta)));
        uint256 grossImd = beforeBalances.managerImd - imd.balanceOf(address(manager));
        uint256 paidOrders = imd.balanceOf(ORDERS) - beforeBalances.ordersImd;
        uint256 paidDev = imd.balanceOf(DEV) - beforeBalances.devImd;

        assertGt(spent, 0);
        assertLt(spent, uint256(-params.amountSpecified), "price limit must stop the requested sell early");
        assertLt(spent, budget);
        assertEq(beforeBalances.payerPaper - paper.balanceOf(address(this)), spent, "unused budget must refund payer");
        assertEq(paper.balanceOf(address(manager)) - beforeBalances.managerPaper, spent);
        assertEq(paper.allowance(address(this), address(prepaid)), 0, "finite allowance covers the full prepaid budget");
        assertEq(imd.balanceOf(RECIPIENT) - beforeBalances.recipientImd, received);
        assertEq(paidOrders + paidDev, grossImd / 50, "fee uses the filled IMD leg");
        assertEq(received + paidOrders + paidDev, grossImd);
        assertEq(paidOrders, (grossImd / 50) / 4);
        assertEq(paidDev, grossImd / 50 - paidOrders);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(price, params.sqrtPriceLimitX96);
        _checkPrepaidSettled();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_partialSellRefundsUnusedBudget(uint96 rawAmount, uint8 rawTicks) public {
        uint256 amount = bound(uint256(rawAmount), 1e21, 1e23);
        int24 ticks = int24(int256(bound(uint256(rawTicks), 1, 10)));
        _verifyPartial(_partialSell(amount, ticks), amount * 2, 1);
    }

    function test_partialSellMinimumBoundaryRollsBackAndAllowsRetry() public {
        SwapParams memory params = _partialSell(1e22, 1);
        uint256 budget = 2e22;
        uint256 checkpoint = vm.snapshotState();
        uint256 received = _verifyPartial(params, budget, 1);
        assertTrue(vm.revertToState(checkpoint));

        paper.approve(address(prepaid), budget);
        bytes32 beforeState = _snapshot();
        vm.expectRevert(PaperSwapRouter.Slippage.selector);
        prepaid.swap(params, budget, received + 1, RECIPIENT, block.timestamp);
        assertEq(_snapshot(), beforeState, "one-unit minimum miss must undo refund, fee, allowance and pool updates");
        _checkPrepaidSettled();

        assertEq(_verifyPartial(params, budget, received), received, "exact net-output minimum must succeed");
    }
}

/// forge-config: default.fuzz.runs = 1000
contract FeeEdgesReverseOrderTest is FeeEdgesTest {
    function _tokenAddress() internal pure override returns (address) {
        return address(type(uint160).max - 10);
    }
}
