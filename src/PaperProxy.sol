// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {HookFlags} from "./HookFlags.sol";

/// @notice The fixed upgrade owner can select only the reviewed implementations; their 2% fee cannot be replaced.
contract PaperProxy is TransparentUpgradeableProxy {
    address private constant ADMIN_OWNER = 0xb59eac9882Ba98f4170d99D5F402C3EDb6D50D75;

    // These are the complete pinned-solc runtime hashes after zeroing the sole deploymentManager immutable.
    // Canonical V1/V2 deployment and upgrade tests fail if their code or the compiler settings change.
    // No owner can change the hashes, immutable offset, or deployment manager for an existing proxy.
    bytes32 private constant V1_RUNTIME_HASH = 0x95289d3166cb8a8454664900441f7c2a30d029051c0607ed7001b3e3492ab169;
    bytes32 private constant V2_RUNTIME_HASH = 0x180ed849a05ea535d8a0ccb749d7dac9b9f01109ed8dab4d8ecf4d36fbe46415;
    uint256 private constant MANAGER_OFFSET = 2140;
    address private immutable approvedManager;

    error UnsupportedImplementation();
    error ImplementationManagerMismatch();

    constructor(address implementation, bytes memory initialization)
        TransparentUpgradeableProxy(_approvedInitialImplementation(implementation), ADMIN_OWNER, initialization)
    {
        approvedManager = _implementationManager(implementation);
        require(HookFlags.matches(address(this), HookFlags.ALL), "Incorrect hook flags");
        require(
            initialization.length == 100
                && bytes4(initialization) == bytes4(keccak256("initialize(address,address,uint256)")),
            "Initialization required"
        );
    }

    function _approvedInitialImplementation(address implementation) private view returns (address) {
        // Validate BEFORE the base constructor's initialization delegatecall, not after potentially hostile code ran.
        address manager = _implementationManager(implementation);
        if (manager.code.length == 0) revert ImplementationManagerMismatch();
        return implementation;
    }

    function _implementationManager(address implementation) private view returns (address manager) {
        bytes memory code = implementation.code;
        if (code.length < MANAGER_OFFSET + 32) revert UnsupportedImplementation();
        bytes32 managerWord;
        assembly ("memory-safe") {
            let immutablePosition := add(add(code, 32), MANAGER_OFFSET)
            managerWord := mload(immutablePosition)
            mstore(immutablePosition, 0)
        }
        bytes32 normalizedHash = keccak256(code);
        if (normalizedHash != V1_RUNTIME_HASH && normalizedHash != V2_RUNTIME_HASH) {
            revert UnsupportedImplementation();
        }
        manager = address(uint160(uint256(managerWord)));
        if (managerWord != bytes32(uint256(uint160(manager)))) revert ImplementationManagerMismatch();
    }

    function _fallback() internal override {
        if (msg.sender == _proxyAdmin() && msg.sig == ITransparentUpgradeableProxy.upgradeToAndCall.selector) {
            (address replacement,) = abi.decode(msg.data[4:], (address, bytes));
            if (_implementationManager(replacement) != approvedManager) revert ImplementationManagerMismatch();
        }
        super._fallback();
    }
}
