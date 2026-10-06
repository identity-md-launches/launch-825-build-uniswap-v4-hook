// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./HookFixture.sol";
import {PaperHook} from "../src/PaperHook.sol";
import {PaperDeployment} from "../src/PaperDeployment.sol";
import {HostilePaper} from "./mocks/HostilePaper.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";

contract AdversarialTest is HookFixture {
    function test_everyCallbackRefusesNonManager() public {
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(LOWER, UPPER, 1 ether, 0);
        SwapParams memory sw = SwapParams(true, -1 ether, Q96 / 2);
        BalanceDelta zero = BalanceDeltaLibrary.ZERO_DELTA;
        bytes[] memory calls = new bytes[](10);
        calls[0] = abi.encodeCall(IHooks.beforeInitialize, (address(this), key, Q96));
        calls[1] = abi.encodeCall(IHooks.afterInitialize, (address(this), key, Q96, 0));
        calls[2] = abi.encodeCall(IHooks.beforeAddLiquidity, (address(this), key, lp, ""));
        calls[3] = abi.encodeCall(IHooks.afterAddLiquidity, (address(this), key, lp, zero, zero, ""));
        calls[4] = abi.encodeCall(IHooks.beforeRemoveLiquidity, (address(this), key, lp, ""));
        calls[5] = abi.encodeCall(IHooks.afterRemoveLiquidity, (address(this), key, lp, zero, zero, ""));
        calls[6] = abi.encodeCall(IHooks.beforeSwap, (address(this), key, sw, ""));
        calls[7] = abi.encodeCall(IHooks.afterSwap, (address(this), key, sw, zero, ""));
        calls[8] = abi.encodeCall(IHooks.beforeDonate, (address(this), key, 1, 1, ""));
        calls[9] = abi.encodeCall(IHooks.afterDonate, (address(this), key, 1, 1, ""));
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory result) = address(hook).call(calls[i]);
            assertFalse(ok);
            assertEq(result, abi.encodeWithSelector(PaperHook.Unauthorized.selector));
        }
    }

    function test_permissionsDeclareAllFourteenBits() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.afterInitialize && p.beforeAddLiquidity && p.afterAddLiquidity);
        assertTrue(p.beforeRemoveLiquidity && p.afterRemoveLiquidity && p.beforeSwap && p.afterSwap);
        assertTrue(p.beforeDonate && p.afterDonate && p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertTrue(p.afterAddLiquidityReturnDelta && p.afterRemoveLiquidityReturnDelta);
    }

    function test_liquidityAndDonationNoOpsDoNotChargeFees() public {
        router.donate(key, 10 ether, 10 ether);
        router.liquidity(key, ModifyLiquidityParams(LOWER, UPPER, -LIQUIDITY, 0));
        assertEq(imd.balanceOf(ORDERS), 0);
        assertEq(imd.balanceOf(DEV), 0);
        _checkSettled();
    }

    function test_wrongPoolRejectedAndNoRebinding() public {
        PoolKey memory wrong = key;
        wrong.fee = 500;
        vm.prank(address(manager));
        vm.expectRevert(PaperHook.WrongPool.selector);
        hook.beforeDonate(address(this), wrong, 0, 0, "");
        vm.prank(address(manager));
        vm.expectRevert(PaperHook.Unauthorized.selector);
        hook.beforeInitialize(address(this), key, Q96);
    }

    function test_badFeeDeploymentRollsBackProxyAndPool() public {
        PaperDeployment.Config memory config = _config(Q96);
        config.lpFee = 0;
        bytes32 hash = keccak256(deployer.proxyInitCode(address(implementation), config));
        (bytes32 salt, address predicted) = deployer.mine(address(deployer), hash, 100_000, 200_000);
        vm.expectRevert();
        deployer.deployHook(salt, address(implementation), config);
        assertEq(predicted.code.length, 0);
        assertEq(PoolId.unwrap(hook.poolKey().toId()), PoolId.unwrap(key.toId()));
    }

    function test_minedDeploymentCannotBeFrontRunByChangingPrice() public {
        PaperDeployment.Config memory config = _config(Q96);
        config.sqrtPriceX96 = Q96 * 2;
        vm.prank(address(123));
        vm.expectRevert("Only configured hook owner");
        deployer.deployHook(bytes32(0), address(implementation), config);
    }

    function test_minerHashIncludesProxyInitialization() public view {
        PaperDeployment.Config memory a = _config(Q96);
        PaperDeployment.Config memory b = _config(Q96);
        b.imdUsdWad = 2 ether;
        assertTrue(
            keccak256(deployer.proxyInitCode(address(implementation), a))
                != keccak256(deployer.proxyInitCode(address(implementation), b))
        );
    }

    function test_postAndBurnBlockTokenReentrancy() public {
        HostilePaper template = new HostilePaper();
        vm.etch(address(paper), address(template).code);
        HostilePaper hostile = HostilePaper(address(paper));
        hostile.configure(address(hook), abi.encodeCall(PaperHook.burn, (1, 1)), false, false);
        hook.postDraft(0);
        assertFalse(hostile.reentrySucceeded());
        assertEq(hostile.reentryError(), PaperHook.ReentrantCall.selector);
        hostile.configure(address(hook), abi.encodeWithSignature("postDraft(bytes32)", bytes32(0)), false, false);
        hook.burn(1, 1 ether);
        assertFalse(hostile.reentrySucceeded());
        assertEq(hostile.reentryError(), PaperHook.ReentrantCall.selector);
        assertEq(hook.draftCount(), 1);
        assertEq(paper.balanceOf(DEAD), 2 ether);
    }

    function test_feePaymentBlocksTokenReentrancy() public {
        HostilePaper template = new HostilePaper();
        vm.etch(IMD, address(template).code);
        HostilePaper hostile = HostilePaper(IMD);
        hostile.configure(address(hook), abi.encodeWithSignature("postDraft(bytes32)", bytes32(0)), false, false);
        _swap(true, true, 100 ether);
        assertFalse(hostile.reentrySucceeded());
        assertEq(hostile.reentryError(), PaperHook.ReentrantCall.selector);
        assertEq(hook.draftCount(), 0);
        assertEq(imd.balanceOf(ORDERS), 0.5 ether);
        assertEq(imd.balanceOf(DEV), 1.5 ether);
        _checkSettled();
    }

    function test_allAllowedLpFeesInitialize() public {
        uint24[3] memory fees = [uint24(500), uint24(3000), uint24(10000)];
        for (uint256 i; i < fees.length; ++i) {
            PaperDeployment.Config memory config = _config(Q96);
            config.lpFee = fees[i];
            bytes32 hash = keccak256(deployer.proxyInitCode(address(implementation), config));
            (bytes32 salt,) = deployer.mine(address(deployer), hash, 100_000 + i * 200_000, 200_000);
            PaperHook deployed = deployer.deployHook(salt, address(implementation), config);
            assertEq(deployed.poolKey().fee, fees[i]);
        }
    }

    function test_shortTransferAndFalseReturnCannotCreateVotes() public {
        HostilePaper template = new HostilePaper();
        vm.etch(address(paper), address(template).code);
        HostilePaper hostile = HostilePaper(address(paper));
        hostile.configure(address(hook), "", true, false);
        vm.expectRevert(PaperHook.InexactTransfer.selector);
        hook.postDraft(0);
        assertEq(hook.draftCount(), 0);
        assertEq(paper.balanceOf(DEAD), 0);
        hostile.configure(address(hook), "", false, true);
        vm.expectRevert();
        hook.postDraft(0);
        assertEq(hook.draftCount(), 0);
        assertEq(paper.balanceOf(DEAD), 0);
    }
}
