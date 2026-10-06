// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./HookFixture.sol";
import {PaperHook} from "../src/PaperHook.sol";
import {PaperHookV2} from "../src/PaperHookV2.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract UpgradeTest is HookFixture {
    bytes32 private constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 private constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function _admin() private view returns (ProxyAdmin) {
        return ProxyAdmin(address(uint160(uint256(vm.load(address(hook), ADMIN_SLOT)))));
    }

    function test_proxyFlagsAndAdminOwnerAreFixed() public view {
        assertEq(uint160(address(hook)) & 0x3fff, 0x3fff);
        assertEq(_admin().owner(), DEV);
        assertEq(hook.owner(), address(this));
        assertTrue(hook.owner() != _admin().owner());
        assertEq(address(uint160(uint256(vm.load(address(hook), IMPL_SLOT)))), address(implementation));
        assertLe(address(hook).code.length, 24_576);
        assertLe(address(implementation).code.length, 24_576);
    }

    function test_upgradeKeepsAllStateAndTradingVotingWork() public {
        hook.setSplit(address(123), 80, address(456), 120);
        hook.setPostFeeUsd(3);
        hook.setImdUsd(2 ether);
        uint256 id = hook.postDraft(keccak256("Before upgrade"));
        hook.burn(id, 2 ether);
        bytes32 namespace = keccak256(abi.encode(uint256(keccak256("paper.storage.Hook")) - 1)) & ~bytes32(uint256(255));
        bytes32[] memory beforeSlots = new bytes32[](20);
        for (uint256 i; i < 20; ++i) {
            beforeSlots[i] = vm.load(address(hook), bytes32(uint256(namespace) + i));
        }
        PaperHookV2 v2 = new PaperHookV2(manager);
        ProxyAdmin admin = _admin();
        vm.prank(DEV);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(hook)), address(v2), "");
        for (uint256 i; i < 20; ++i) {
            assertEq(vm.load(address(hook), bytes32(uint256(namespace) + i)), beforeSlots[i]);
        }
        assertEq(hook.owner(), address(this));
        assertEq(hook.token(), address(paper));
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.postFeeUsd(), 3);
        assertEq(hook.imdUsd(), 2 ether);
        assertEq(hook.postFeeTokens(), 1.5 ether);
        assertEq(hook.draftCount(), 1);
        (address a, uint256 ab, address b, uint256 bb) = hook.split();
        assertEq(a, address(123));
        assertEq(ab, 80);
        assertEq(b, address(456));
        assertEq(bb, 120);
        _swap(true, true, 100 ether);
        assertEq(imd.balanceOf(a), 0.8 ether);
        assertEq(imd.balanceOf(b), 1.2 ether);
        _swap(false, true, 10 ether);
        hook.burn(id, 1 ether);
        assertEq(hook.postDraft(keccak256("After upgrade")), 2);
        assertEq(hook.feeBps(), 200);
        _checkSettled();
    }

    function test_v2ReversesDefaultsOnlyForFreshProxy() public {
        PaperHookV2 v2 = new PaperHookV2(manager);
        PaperHook fresh = _deploy(address(v2), Q96);
        (address a, uint256 ab, address b, uint256 bb) = fresh.split();
        assertEq(a, ORDERS);
        assertEq(ab, 150);
        assertEq(b, DEV);
        assertEq(bb, 50);
        assertEq(fresh.feeBps(), 200);
        assertEq(fresh.postFeeUsd(), 1);
    }

    function test_hookOwnerAndStrangerCannotUpgrade() public {
        PaperHookV2 v2 = new PaperHookV2(manager);
        ProxyAdmin admin = _admin();
        vm.expectRevert();
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(hook)), address(v2), "");
        vm.prank(address(123));
        vm.expectRevert();
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(hook)), address(v2), "");
        vm.prank(DEV);
        vm.expectRevert();
        ITransparentUpgradeableProxy(address(hook)).upgradeToAndCall(address(v2), "");
        assertEq(address(uint160(uint256(vm.load(address(hook), IMPL_SLOT)))), address(implementation));
    }

    function test_initializersCannotBeUsedAgainOrOnImplementations() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(paper), address(this), 1 ether);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        hook.initialize(address(paper), address(123), 2 ether);
        PaperHookV2 v2 = new PaperHookV2(manager);
        ProxyAdmin admin = _admin();
        vm.prank(DEV);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        admin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(hook)),
            address(v2),
            abi.encodeCall(PaperHook.initialize, (address(paper), address(123), 2 ether))
        );
        assertEq(address(uint160(uint256(vm.load(address(hook), IMPL_SLOT)))), address(implementation));
    }

    function test_proxyAdminCannotCallHookFunctions() public {
        vm.prank(address(_admin()));
        vm.expectRevert();
        hook.feeBps();
    }
}
