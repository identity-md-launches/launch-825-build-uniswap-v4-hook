// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {Paper} from "../src/Paper.sol";
import {PaperHook} from "../src/PaperHook.sol";
import {PaperDeployment} from "../src/PaperDeployment.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PoolRouter} from "./mocks/PoolRouter.sol";

abstract contract HookFixture is Test {
    using BalanceDeltaLibrary for BalanceDelta;
    using TransientStateLibrary for IPoolManager;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant DEV = 0xb59eac9882Ba98f4170d99D5F402C3EDb6D50D75;
    address internal constant ORDERS = 0x721F8232e19c92516eB753FEF53d8A33a3637989;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint160 internal constant Q96 = 79228162514264337593543950336;
    int24 internal constant LOWER = -887220;
    int24 internal constant UPPER = 887220;
    int256 internal constant LIQUIDITY = 1e24;
    Paper internal paper;
    MockERC20 internal imd;
    PoolManager internal manager;
    PoolRouter internal router;
    PaperHook internal implementation;
    PaperHook internal hook;
    PaperDeployment internal deployer;
    PoolKey internal key;
    uint256 private saltStart;

    function _tokenAddress() internal pure virtual returns (address) {
        return address(0x100000);
    }

    function setUp() public virtual {
        deployCodeTo("Paper.sol:Paper", _tokenAddress());
        paper = Paper(_tokenAddress());
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("IMD", "IMD", 1e30), IMD);
        imd = MockERC20(IMD);
        manager = new PoolManager(address(this));
        router = new PoolRouter(manager);
        deployer = new PaperDeployment();
        implementation = new PaperHook(manager);
        hook = _deploy(address(implementation), Q96);
        key = hook.poolKey();
        paper.approve(address(router), type(uint256).max);
        imd.approve(address(router), type(uint256).max);
        paper.approve(address(hook), type(uint256).max);
        router.liquidity(key, ModifyLiquidityParams(LOWER, UPPER, LIQUIDITY, 0));
    }

    function _config(uint160 price) internal view returns (PaperDeployment.Config memory) {
        return PaperDeployment.Config(manager, address(paper), address(this), 1 ether, price, 3000, 60);
    }

    function _deploy(address logic, uint160 price) internal returns (PaperHook deployed) {
        PaperDeployment.Config memory config = _config(price);
        bytes32 hash = keccak256(deployer.proxyInitCode(logic, config));
        (bytes32 salt,) = deployer.mine(address(deployer), hash, saltStart, 200_000);
        saltStart = uint256(salt) + 1;
        deployed = deployer.deployHook(salt, logic, config);
    }

    function _swap(bool buy, bool exactInput, uint256 amount) internal returns (BalanceDelta) {
        bool imdIs0 = Currency.unwrap(key.currency0) == IMD;
        bool zeroForOne = buy == imdIs0;
        uint160 limit = zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341;
        return router.swap(key, SwapParams(zeroForOne, exactInput ? -int256(amount) : int256(amount), limit));
    }

    function _imdDelta(BalanceDelta delta) internal view returns (int128) {
        return Currency.unwrap(key.currency0) == IMD ? delta.amount0() : delta.amount1();
    }

    function _paperDelta(BalanceDelta delta) internal view returns (int128) {
        return Currency.unwrap(key.currency0) == address(paper) ? delta.amount0() : delta.amount1();
    }

    function _checkSettled() internal view {
        IPoolManager pm = manager;
        assertEq(pm.currencyDelta(address(hook), Currency.wrap(IMD)), 0);
        assertEq(pm.currencyDelta(address(hook), Currency.wrap(address(paper))), 0);
        assertEq(pm.currencyDelta(address(router), key.currency0), 0);
        assertEq(pm.currencyDelta(address(router), key.currency1), 0);
        assertEq(pm.getNonzeroDeltaCount(), 0);
        assertFalse(pm.isUnlocked());
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(paper.balanceOf(address(hook)), 0);
    }
}
