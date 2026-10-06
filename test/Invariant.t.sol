// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./HookFixture.sol";
import {Test} from "forge-std/Test.sol";
import {PaperHook} from "../src/PaperHook.sol";
import {Paper} from "../src/Paper.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PoolRouter} from "./mocks/PoolRouter.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";

contract HookHandler is Test {
    using BalanceDeltaLibrary for BalanceDelta;
    PaperHook public immutable hook;
    PoolRouter public immutable router;
    Paper public immutable paper;
    MockERC20 public immutable imd;
    PoolKey internal key;
    uint256 public expectedFees;
    uint256 public expectedBurn;

    constructor(PaperHook h, PoolRouter r, Paper p, MockERC20 i) {
        hook = h;
        router = r;
        paper = p;
        imd = i;
        key = h.poolKey();
        p.approve(address(r), type(uint256).max);
        p.approve(address(h), type(uint256).max);
        i.approve(address(r), type(uint256).max);
    }

    function swap(bool buy, bool exactInput, uint96 rawAmount) external {
        uint256 amount = bound(uint256(rawAmount), 1e12, 1e20);
        bool zeroForOne = buy == (Currency.unwrap(key.currency0) == address(imd));
        uint160 limit = zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341;
        uint256 beforeFees = imd.balanceOf(hook.ORDERS()) + imd.balanceOf(hook.DEV());
        BalanceDelta delta =
            router.swap(key, SwapParams(zeroForOne, exactInput ? -int256(amount) : int256(amount), limit));
        uint256 fee = imd.balanceOf(hook.ORDERS()) + imd.balanceOf(hook.DEV()) - beforeFees;
        int128 leg = Currency.unwrap(key.currency0) == address(imd) ? delta.amount0() : delta.amount1();
        uint256 gross = buy ? uint256(-int256(leg)) : uint256(int256(leg)) + fee;
        assertEq(fee, gross / 50);
        expectedFees += gross / 50;
    }

    function split(uint8 rawBps) external {
        uint256 ordersBps = bound(uint256(rawBps), 0, 200);
        hook.setSplit(hook.ORDERS(), ordersBps, hook.DEV(), 200 - ordersBps);
    }

    function postAndBurn(uint96 rawAmount) external {
        uint256 quoted = hook.postFeeTokens();
        uint256 id = hook.postDraft(keccak256(abi.encode(rawAmount)));
        uint256 amount = bound(uint256(rawAmount), 0, 1e20);
        hook.burn(id, amount);
        expectedBurn += quoted + amount;
    }
}

contract HookInvariantTest is HookFixture {
    HookHandler private handler;

    function setUp() public override {
        super.setUp();
        handler = new HookHandler(hook, router, paper, imd);
        hook.transferOwnership(address(handler));
        paper.transfer(address(handler), 1e25);
        imd.transfer(address(handler), 1e25);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = HookHandler.swap.selector;
        selectors[1] = HookHandler.split.selector;
        selectors[2] = HookHandler.postAndBurn.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_feeConservationAndNoHookBalances() public view {
        assertEq(hook.feeBps(), 200);
        (, uint256 ordersBps,, uint256 devBps) = hook.split();
        assertEq(ordersBps + devBps, 200);
        assertEq(imd.balanceOf(ORDERS) + imd.balanceOf(DEV), handler.expectedFees());
        assertEq(paper.balanceOf(DEAD), handler.expectedBurn());
        assertEq(paper.totalSupply(), 1e27);
        _checkSettled();
    }
}
