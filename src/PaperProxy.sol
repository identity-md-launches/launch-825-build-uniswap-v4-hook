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
    bytes32 private constant V1_RUNTIME_HASH = 0x786797241d90a3aa6c31ea4123256416054bd67326ffd3761fbfac7318d8a1f9;
    bytes32 private constant V2_RUNTIME_HASH = 0x0d435a182959bb223dbd9a229823bcbe984ddb86b3b1dd3c40518654a4d43520;
    uint256 private constant MANAGER_OFFSET = 2110;
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
