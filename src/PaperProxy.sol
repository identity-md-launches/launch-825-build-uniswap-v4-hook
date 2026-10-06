// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {HookFlags} from "./HookFlags.sol";

/// @notice Upgrade owner is fixed in creation code, independent of the launch wallet.
contract PaperProxy is TransparentUpgradeableProxy {
    address private constant ADMIN_OWNER = 0xb59eac9882Ba98f4170d99D5F402C3EDb6D50D75;

    constructor(address implementation, bytes memory initialization)
        TransparentUpgradeableProxy(implementation, ADMIN_OWNER, initialization)
    {
        require(HookFlags.matches(address(this), HookFlags.ALL), "Incorrect hook flags");
        require(
            initialization.length == 100
                && bytes4(initialization) == bytes4(keccak256("initialize(address,address,uint256)")),
            "Initialization required"
        );
    }
}
