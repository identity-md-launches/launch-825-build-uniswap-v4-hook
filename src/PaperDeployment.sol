// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Paper} from "./Paper.sol";
import {PaperHook} from "./PaperHook.sol";
import {PaperProxy} from "./PaperProxy.sol";
import {HookFlags} from "./HookFlags.sol";

/// @notice Reviewable deployment helpers. No keys, environment, or broadcasts.
contract PaperDeployment {
    uint256 public constant POOL_BPS = 8000;
    address public constant REMAINDER_TO = 0xb59eac9882Ba98f4170d99D5F402C3EDb6D50D75;

    struct Config {
        IPoolManager manager;
        address token;
        address hookOwner;
        uint256 imdUsdWad;
        uint160 sqrtPriceX96;
        uint24 lpFee;
        int24 tickSpacing;
    }

    event TokenAllocated(
        address indexed token, address indexed liquidityCustodian, uint256 poolAmount, uint256 remainder
    );
    event HookDeployed(address indexed hook, address indexed implementation, bytes32 salt);

    /// @notice Caller must seed its 80% allocation; the helper does not invent a launch price or IMD funding.
    function deployToken() external returns (Paper token) {
        token = new Paper();
        uint256 poolAmount = token.totalSupply() * POOL_BPS / 10_000;
        uint256 remainder = token.totalSupply() - poolAmount;
        require(token.transfer(msg.sender, poolAmount), "Pool allocation failed");
        require(token.transfer(REMAINDER_TO, remainder), "Remainder transfer failed");
        emit TokenAllocated(address(token), msg.sender, poolAmount, remainder);
    }

    function proxyInitCode(address implementation, Config memory config) public pure returns (bytes memory) {
        bytes memory initialization =
            abi.encodeCall(PaperHook.initialize, (config.token, config.hookOwner, config.imdUsdWad));
        return abi.encodePacked(type(PaperProxy).creationCode, abi.encode(implementation, initialization));
    }

    function predict(address deployer, bytes32 salt, bytes32 initCodeHash) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    /// @notice Run as an eth_call before deployment. All proxy arguments participate in the hash.
    function mine(address deployer, bytes32 initCodeHash, uint256 start, uint256 attempts)
        external
        pure
        returns (bytes32 salt, address predicted)
    {
        require(attempts <= 200_000, "Search too large");
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            predicted = predict(deployer, salt, initCodeHash);
            if (HookFlags.matches(predicted, HookFlags.ALL)) return (salt, predicted);
        }
        revert("No salt in range");
    }

    /// @notice Creates and initializes the proxy and pool atomically; salt must be mined for this helper.
    function deployHook(bytes32 salt, address implementation, Config calldata config)
        external
        returns (PaperHook hook)
    {
        require(msg.sender == config.hookOwner, "Only configured hook owner");
        bytes memory initialization =
            abi.encodeCall(PaperHook.initialize, (config.token, config.hookOwner, config.imdUsdWad));
        hook = PaperHook(address(new PaperProxy{salt: salt}(implementation, initialization)));
        require(address(hook.poolManager()) == address(config.manager), "Manager mismatch");
        address imd = hook.IMD();
        (address a, address b) = config.token < imd ? (config.token, imd) : (imd, config.token);
        PoolKey memory key =
            PoolKey(Currency.wrap(a), Currency.wrap(b), config.lpFee, config.tickSpacing, IHooks(address(hook)));
        config.manager.initialize(key, config.sqrtPriceX96);
        emit HookDeployed(address(hook), implementation, salt);
    }
}
