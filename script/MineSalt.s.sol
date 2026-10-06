// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {PaperDeployment} from "../src/PaperDeployment.sol";

/// @notice Local salt search. Supply the actual helper address and complete proxy init-code hash.
contract MineSalt is Script {
    function run(address deployer, bytes32 initCodeHash, uint256 start, uint256 attempts)
        external
        returns (bytes32 salt, address predicted)
    {
        PaperDeployment local = new PaperDeployment();
        return local.mine(deployer, initCodeHash, start, attempts);
    }
}
