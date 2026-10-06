// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PaperHook} from "./PaperHook.sol";

/// @notice Rehearsal only. Existing proxy splits survive an upgrade unchanged.
contract PaperHookV2 is PaperHook {
    constructor(IPoolManager manager) PaperHook(manager) {}

    function _defaultSplit() internal pure override returns (uint256, uint256) {
        return (150, 50);
    }
}
