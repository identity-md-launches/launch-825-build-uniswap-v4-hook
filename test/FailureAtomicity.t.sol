// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./HookFixture.sol";
import {PaperHook} from "src/PaperHook.sol";
import {HostilePaper} from "./mocks/HostilePaper.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// forge-config: default.fuzz.runs = 1000
contract FailureAtomicityTest is HookFixture {
    using StateLibrary for IPoolManager;

    // Include both currencies and both fee wallets: a late settlement failure must undo
    // payments already made in beforeSwap or afterSwap, as well as the pool's price.
    function _snapshot() private view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) =
            IPoolManager(address(manager)).getSlot0(key.toId());
        address[6] memory accounts = [address(this), address(manager), address(router), address(hook), ORDERS, DEV];
        bytes memory state = abi.encode(price, tick, protocolFee, lpFee, hook.draftCount());
        for (uint256 i; i < accounts.length; ++i) {
            state = abi.encode(state, paper.balanceOf(accounts[i]), imd.balanceOf(accounts[i]));
        }
        return keccak256(state);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_failedSettlementRollsBackEverySwapMode(bool buy, bool exactInput, uint96 raw) public {
        uint256 amount = bound(uint256(raw), 1e12, 1e20);
        if (buy) imd.approve(address(router), 0);
        else paper.approve(address(router), 0);
        bytes32 beforeState = _snapshot();
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        _swap(buy, exactInput, amount);
        assertEq(_snapshot(), beforeState, "failed settlement retained payments or pool changes");
        _checkSettled();
        // A reverted guard or unlock must not poison a subsequent valid swap.
        if (buy) imd.approve(address(router), type(uint256).max);
        else paper.approve(address(router), type(uint256).max);
        _swap(buy, exactInput, amount);
        _checkSettled();
    }

    function test_falseReturnSettlementRestoresTokenCallbackState() public {
        HostilePaper template = new HostilePaper();
        vm.etch(IMD, address(template).code);
        HostilePaper hostile = HostilePaper(IMD);
        // The token moves funds, then reenters with an invalid post. The hook guard
        // refuses reentry; settlement's false transferFrom response then rolls back it all.
        hostile.configure(address(hook), abi.encodeWithSignature("postDraft(bytes32)", bytes32(0)), false, true);
        bytes32 beforeState = _snapshot();
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD));
        _swap(true, true, 100 ether);
        assertEq(_snapshot(), beforeState);
        assertTrue(hostile.armed(), "token callback state must also roll back");
        _checkSettled();
    }

    function test_failedBurnCannotConsumeAllowanceOrCreateVotesAndRecovers() public {
        uint256 id = hook.postDraft(0);
        HostilePaper template = new HostilePaper();
        vm.etch(address(paper), address(template).code);
        HostilePaper hostile = HostilePaper(address(paper));
        paper.approve(address(hook), 10 ether);
        uint256 beforeBalance = paper.balanceOf(address(this));
        uint256 beforeSupply = paper.totalSupply();
        hostile.configure(address(hook), "", true, false);
        vm.expectRevert(PaperHook.InexactTransfer.selector);
        hook.burn(id, 10 ether);
        assertEq(paper.balanceOf(address(this)), beforeBalance);
        assertEq(paper.balanceOf(DEAD), 1 ether);
        assertEq(paper.allowance(address(this), address(hook)), 10 ether);
        assertEq(paper.totalSupply(), beforeSupply);
        assertEq(hook.draftCount(), 1);
        hostile.configure(address(hook), "", false, true);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(paper)));
        hook.burn(id, 10 ether);
        assertEq(paper.balanceOf(DEAD), 1 ether);
        hostile.configure(address(hook), "", false, false);
        hook.burn(id, 10 ether);
        assertEq(paper.balanceOf(DEAD), 11 ether);
        assertEq(paper.allowance(address(this), address(hook)), 0);
        _checkSettled();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_invalidSplitNeverMutatesState(uint256 ordersBps, uint256 devBps) public {
        // Deliberately retain maximum uint256 inputs; do not allow overflow in the oracle.
        if (ordersBps <= 200 && devBps <= 200 && ordersBps + devBps == 200) devBps += 1;
        hook.setSplit(address(0xA11CE), 81, address(0xB0B), 119);
        vm.expectRevert(PaperHook.InvalidConfiguration.selector);
        hook.setSplit(ORDERS, ordersBps, DEV, devBps);
        (address a, uint256 ab, address b, uint256 bb) = hook.split();
        assertEq(a, address(0xA11CE));
        assertEq(ab, 81);
        assertEq(b, address(0xB0B));
        assertEq(bb, 119);
        assertEq(hook.feeBps(), 200);
    }

    function test_invalidRecipientInEitherPositionEvenWithZeroShare() public {
        address[3] memory invalid = [address(0), address(hook), address(manager)];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(PaperHook.InvalidConfiguration.selector);
            hook.setSplit(invalid[i], 0, DEV, 200);
            vm.expectRevert(PaperHook.InvalidConfiguration.selector);
            hook.setSplit(ORDERS, 200, invalid[i], 0);
        }
        _swap(true, true, 100 ether);
        assertEq(imd.balanceOf(ORDERS), 0.5 ether);
        assertEq(imd.balanceOf(DEV), 1.5 ether);
    }

    function test_everyBoundCallbackRejectsAnotherPoolFromTheRealManager() public {
        PoolKey memory wrong = key;
        wrong.tickSpacing += 1;
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(LOWER, UPPER, 1, 0);
        SwapParams memory sw = SwapParams(true, -100, Q96 / 2);
        BalanceDelta zero = BalanceDeltaLibrary.ZERO_DELTA;
        bytes[] memory calls = new bytes[](9);
        calls[0] = abi.encodeCall(IHooks.afterInitialize, (address(this), wrong, Q96, 0));
        calls[1] = abi.encodeCall(IHooks.beforeAddLiquidity, (address(this), wrong, lp, ""));
        calls[2] = abi.encodeCall(IHooks.afterAddLiquidity, (address(this), wrong, lp, zero, zero, ""));
        calls[3] = abi.encodeCall(IHooks.beforeRemoveLiquidity, (address(this), wrong, lp, ""));
        calls[4] = abi.encodeCall(IHooks.afterRemoveLiquidity, (address(this), wrong, lp, zero, zero, ""));
        calls[5] = abi.encodeCall(IHooks.beforeSwap, (address(this), wrong, sw, ""));
        calls[6] = abi.encodeCall(IHooks.afterSwap, (address(this), wrong, sw, zero, ""));
        calls[7] = abi.encodeCall(IHooks.beforeDonate, (address(this), wrong, 1, 1, ""));
        calls[8] = abi.encodeCall(IHooks.afterDonate, (address(this), wrong, 1, 1, ""));
        bytes32 beforeState = _snapshot();
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(address(manager));
            (bool ok, bytes memory reason) = address(hook).call(calls[i]);
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(PaperHook.WrongPool.selector));
        }
        assertEq(_snapshot(), beforeState);
    }

    function test_oversizedAmountsFailBeforeAnyPayment() public {
        int256[3] memory amounts = [type(int256).min, int256(type(int128).max) + 1, -int256(type(int128).max) - 1];
        bool imdIs0 = Currency.unwrap(key.currency0) == IMD;
        bytes32 beforeState = _snapshot();
        for (uint256 i; i < amounts.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    address(hook),
                    IHooks.beforeSwap.selector,
                    abi.encodeWithSelector(PaperHook.AmountTooLarge.selector),
                    abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                )
            );
            router.swap(key, SwapParams(imdIs0, amounts[i], imdIs0 ? Q96 / 2 : Q96 * 2));
            assertEq(_snapshot(), beforeState);
        }
        _checkSettled();
    }
}

/// forge-config: default.fuzz.runs = 1000
contract FailureAtomicityReverseOrderTest is FailureAtomicityTest {
    function _tokenAddress() internal pure override returns (address) {
        return address(type(uint160).max - 10);
    }
}
