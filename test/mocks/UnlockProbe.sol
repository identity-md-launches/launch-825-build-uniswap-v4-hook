// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PaperHook} from "../../src/PaperHook.sol";

contract UnlockProbe is IUnlockCallback {
    IPoolManager private immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function probe(PaperHook hook, bool post) external returns (bool, bytes memory) {
        return abi.decode(manager.unlock(abi.encode(hook, post)), (bool, bytes));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "Only manager");
        (PaperHook hook, bool post) = abi.decode(data, (PaperHook, bool));
        bytes memory callData =
            post ? abi.encodeCall(PaperHook.postDraft, (bytes32(0))) : abi.encodeCall(PaperHook.postFeeTokens, ());
        (bool ok, bytes memory result) = address(hook).call(callData);
        return abi.encode(ok, result);
    }
}
