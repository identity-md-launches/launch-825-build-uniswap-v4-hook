// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./HookFixture.sol";
import {PaperHook} from "../src/PaperHook.sol";
import {PaperHookV2} from "../src/PaperHookV2.sol";
import {PaperProxy} from "../src/PaperProxy.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract CounterfeitImplementation {
    function feeBps() external pure returns (uint256) {
        return 200;
    }

    function initialize(address, address, uint256) external pure {
        revert("Unreviewed initialization executed");
    }
}

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

    function test_upgradeRejectsCounterfeitFeeGetterBeforeInitialization() public {
        CounterfeitImplementation counterfeit = new CounterfeitImplementation();
        assertEq(counterfeit.feeBps(), 200);
        ProxyAdmin admin = _admin();
        vm.prank(DEV);
        vm.expectRevert(PaperProxy.UnsupportedImplementation.selector);
        admin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(hook)),
            address(counterfeit),
            abi.encodeCall(PaperHook.initialize, (address(paper), DEV, 1 ether))
        );
        assertEq(address(uint160(uint256(vm.load(address(hook), IMPL_SLOT)))), address(implementation));
        _swap(true, true, 100 ether);
        assertEq(imd.balanceOf(ORDERS) + imd.balanceOf(DEV), 2 ether);
    }

    function test_constructorRejectsCounterfeitBeforeInitialization() public {
        CounterfeitImplementation counterfeit = new CounterfeitImplementation();
        vm.expectRevert(PaperProxy.UnsupportedImplementation.selector);
        new PaperProxy(
            address(counterfeit), abi.encodeCall(PaperHook.initialize, (address(paper), address(this), 1 ether))
        );
    }

    function test_upgradeRejectsCanonicalImplementationForAnotherManager() public {
        PoolManager anotherManager = new PoolManager(address(this));
        PaperHookV2 replacement = new PaperHookV2(anotherManager);
        ProxyAdmin admin = _admin();
        vm.prank(DEV);
        vm.expectRevert(PaperProxy.ImplementationManagerMismatch.selector);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(hook)), address(replacement), "");
        assertEq(address(uint160(uint256(vm.load(address(hook), IMPL_SLOT)))), address(implementation));
    }

    function test_upgradeRejectsModifiedCanonicalRuntime() public {
        PaperHookV2 replacement = new PaperHookV2(manager);
        bytes memory alteredCode = address(replacement).code;
        // Change executable code while preserving the manager immutable and deployment address.
        alteredCode[0] = bytes1(uint8(alteredCode[0]) ^ 1);
        vm.etch(address(replacement), alteredCode);
        ProxyAdmin admin = _admin();
        vm.prank(DEV);
        vm.expectRevert(PaperProxy.UnsupportedImplementation.selector);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(hook)), address(replacement), "");
        assertEq(address(uint160(uint256(vm.load(address(hook), IMPL_SLOT)))), address(implementation));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_runtimeWhitelistRejectsChangesBeforeDelegation(uint16 offsetSeed, uint8 maskSeed, bool useV2)
        public
    {
        address candidate = useV2 ? address(new PaperHookV2(manager)) : address(new PaperHook(manager));
        bytes memory runtime = candidate.code;
        // The sole manager immutable occupies bytes [2110, 2142) in the pinned runtime.
        // Exercise the entire remaining code, including bytes after the immutable.
        uint256 offset = bound(uint256(offsetSeed), 0, runtime.length - 33);
        if (offset >= 2110) offset += 32;
        runtime[offset] ^= bytes1(uint8(bound(uint256(maskSeed), 1, 255)));
        vm.etch(candidate, runtime);

        // A payload that would otherwise change application state must never be delegated.
        bytes memory payload = abi.encodeCall(PaperHook.setPostFeeUsd, (99));
        ProxyAdmin admin = _admin();
        bytes32 adminBefore = vm.load(address(hook), ADMIN_SLOT);
        vm.prank(DEV);
        vm.expectRevert(PaperProxy.UnsupportedImplementation.selector);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(hook)), candidate, payload);
        assertEq(vm.load(address(hook), IMPL_SLOT), bytes32(uint256(uint160(address(implementation)))));
        assertEq(vm.load(address(hook), ADMIN_SLOT), adminBefore);
        assertEq(hook.postFeeUsd(), 1);

        vm.expectRevert(PaperProxy.UnsupportedImplementation.selector);
        new PaperProxy(candidate, abi.encodeCall(PaperHook.initialize, (address(paper), address(this), 1 ether)));
    }

    function test_managerNormalizationRejectsDirtyAddressPadding() public {
        PaperHookV2 candidate = new PaperHookV2(manager);
        bytes memory runtime = address(candidate).code;
        // Keep the actual manager address but set a discarded high bit in its 32-byte word.
        runtime[2110] = 0x01;
        vm.etch(address(candidate), runtime);
        ProxyAdmin admin = _admin();
        vm.prank(DEV);
        vm.expectRevert(PaperProxy.ImplementationManagerMismatch.selector);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(hook)), address(candidate), "");
        vm.expectRevert(PaperProxy.ImplementationManagerMismatch.selector);
        new PaperProxy(
            address(candidate), abi.encodeCall(PaperHook.initialize, (address(paper), address(this), 1 ether))
        );
        assertEq(vm.load(address(hook), IMPL_SLOT), bytes32(uint256(uint160(address(implementation)))));
        assertEq(address(hook.poolManager()), address(manager));
    }

    function test_whitelistRejectsAppendedRuntimeEvenWhenBehaviorIsUnchanged() public {
        PaperHookV2 candidate = new PaperHookV2(manager);
        vm.etch(address(candidate), abi.encodePacked(address(candidate).code, hex"00"));
        assertEq(candidate.feeBps(), 200);
        ProxyAdmin admin = _admin();
        vm.prank(DEV);
        vm.expectRevert(PaperProxy.UnsupportedImplementation.selector);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(hook)), address(candidate), "");
        assertEq(vm.load(address(hook), IMPL_SLOT), bytes32(uint256(uint160(address(implementation)))));
    }
}
