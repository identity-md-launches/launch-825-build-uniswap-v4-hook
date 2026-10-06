// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PaperHook} from "./PaperHook.sol";

/// @notice Single-pool router that settles the caller's input before the hook pays its fees.
contract PaperSwapRouter is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable manager;
    PoolKey private key;
    bytes32 private callbackHash;

    error InvalidConfiguration();
    error InvalidSwap();
    error Expired();
    error UnauthorizedCallback();
    error InexactTransfer();
    error Slippage();

    constructor(PaperHook hook) {
        manager = hook.poolManager();
        key = hook.poolKey();
        if (
            address(manager).code.length == 0 || address(key.hooks) != address(hook)
                || Currency.unwrap(key.currency0).code.length == 0 || Currency.unwrap(key.currency1).code.length == 0
        ) revert InvalidConfiguration();
    }

    /// @param maxInput Upfront input budget including the hook fee; unused input returns to the caller.
    /// @param minOutput Minimum net output after all fees, delivered to recipient.
    function swap(SwapParams calldata params, uint256 maxInput, uint256 minOutput, address recipient, uint256 deadline)
        external
        nonReentrant
        returns (BalanceDelta delta)
    {
        if (block.timestamp > deadline) revert Expired();
        if (
            maxInput == 0 || maxInput > uint256(uint128(type(int128).max)) || params.amountSpecified == 0
                || params.amountSpecified > type(int128).max || params.amountSpecified < -int256(type(int128).max)
                || recipient == address(0) || recipient == address(this) || recipient == address(manager)
        ) revert InvalidSwap();
        IERC20 input = IERC20(Currency.unwrap(params.zeroForOne ? key.currency0 : key.currency1));
        uint256 beforeBalance = input.balanceOf(address(this));
        // Only the direct caller can fund a swap. Callback data never authorizes transferFrom.
        input.safeTransferFrom(msg.sender, address(this), maxInput);
        if (input.balanceOf(address(this)) - beforeBalance != maxInput) revert InexactTransfer();

        bytes memory data = abi.encode(params, maxInput, minOutput, recipient, msg.sender);
        callbackHash = keccak256(data);
        delta = abi.decode(manager.unlock(data), (BalanceDelta));
        if (callbackHash != bytes32(0)) revert UnauthorizedCallback();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager) || callbackHash == bytes32(0) || keccak256(data) != callbackHash) {
            revert UnauthorizedCallback();
        }
        callbackHash = bytes32(0);
        (SwapParams memory params, uint256 budget, uint256 minimum, address recipient, address payer) =
            abi.decode(data, (SwapParams, uint256, uint256, address, address));
        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        Currency output = params.zeroForOne ? key.currency1 : key.currency0;
        manager.sync(input);
        IERC20(Currency.unwrap(input)).safeTransfer(address(manager), budget);
        if (manager.settle() != budget) revert InexactTransfer();

        BalanceDelta delta = manager.swap(key, params, "");
        int128 inputDelta = params.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = params.zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta >= 0 || outputDelta <= 0) revert Slippage();
        uint256 spent = uint256(-int256(inputDelta));
        uint256 received = uint256(int256(outputDelta));
        if (
            spent > budget || received < minimum
                || (params.amountSpecified > 0 && received != uint256(params.amountSpecified))
        ) revert Slippage();
        if (budget > spent) manager.take(input, payer, budget - spent);
        manager.take(output, recipient, received);
        return abi.encode(delta);
    }
}
