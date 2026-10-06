// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./HookFixture.sol";
import {PaperHook} from "../src/PaperHook.sol";
import {PaperSwapRouter} from "../src/PaperSwapRouter.sol";
import {PoolRouter} from "./mocks/PoolRouter.sol";
import {HostilePaper} from "./mocks/HostilePaper.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract VotingProtectionTest is HookFixture {
    using StateLibrary for IPoolManager;

    event DraftPosted(uint256 indexed draftId, address indexed author, bytes32 textHash, uint256 burned);

    function _paperOnlyPool() internal {
        manager = new PoolManager(address(this));
        router = new PoolRouter(manager);
        hook = _deploy(address(new PaperHook(manager)), Q96);
        key = hook.poolKey();
        paper.approve(address(router), type(uint256).max);
        imd.approve(address(router), type(uint256).max);
        paper.approve(address(hook), type(uint256).max);
        bool paperIs0 = Currency.unwrap(key.currency0) == address(paper);
        router.liquidity(
            key,
            ModifyLiquidityParams(
                paperIs0 ? int24(60) : int24(-887220), paperIs0 ? int24(887220) : int24(-60), LIQUIDITY, 0
            )
        );
        assertEq(imd.balanceOf(address(manager)), 0);
        assertEq(IPoolManager(address(manager)).getLiquidity(key.toId()), 0);
    }

    function _buyWithPrepayment(uint256 amount) internal {
        PaperSwapRouter prepaid = new PaperSwapRouter(hook);
        imd.approve(address(prepaid), amount);
        bool zeroForOne = Currency.unwrap(key.currency0) == IMD;
        uint160 limit = zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341;
        prepaid.swap(SwapParams(zeroForOne, -int256(amount), limit), amount, 1, address(this), block.timestamp);
    }

    function test_paperOnlyLaunchSupportsQuoteAndPost() public {
        _paperOnlyPool();
        assertGt(paper.balanceOf(address(manager)), 0);
        assertEq(hook.postFeeTokens(), 1 ether);
        assertEq(hook.postDraft(keccak256("Launch draft")), 1);
        assertEq(hook.postDraft(keccak256("Capped launch draft"), 1 ether), 2);
        assertEq(paper.balanceOf(DEAD), 2 ether);
        _checkSettled();
    }

    function test_emptyRangeSwapCannotOverwriteLaunchQuote() public {
        _paperOnlyPool();
        // There is no IMD liquidity on the sell side. The price moves without exchanging tokens.
        _swap(false, true, 1 ether);
        (uint160 displaced,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertTrue(displaced != Q96);
        assertEq(IPoolManager(address(manager)).getLiquidity(key.toId()), 0);
        assertEq(hook.postFeeTokens(), 1 ether);
        assertEq(hook.postDraft(0, 1 ether), 1);
        assertEq(paper.balanceOf(DEAD), 1 ether);
        _checkSettled();
    }

    function test_roundTripCannotDisablePostingOrOverwriteLastActiveQuote() public {
        _paperOnlyPool();
        _buyWithPrepayment(100 ether);
        uint256 firstQuote = hook.postFeeTokens();
        _buyWithPrepayment(10 ether);
        uint256 lastQuote = hook.postFeeTokens();
        assertLt(lastQuote, firstQuote);
        assertGt(IPoolManager(address(manager)).getLiquidity(key.toId()), 0);

        // Drain the launch position, then cross the empty region to the extreme price limit.
        _swap(false, true, 1e24);
        assertEq(IPoolManager(address(manager)).getLiquidity(key.toId()), 0);
        assertEq(hook.postFeeTokens(), lastQuote);
        assertEq(hook.postDraft(0, lastQuote), 1);
        assertEq(paper.balanceOf(DEAD), lastQuote);
        _checkSettled();
    }

    function test_removingAllLiquidityKeepsLastActiveQuote() public {
        _swap(true, true, 100 ether);
        uint256 lastQuote = hook.postFeeTokens();
        router.liquidity(key, ModifyLiquidityParams(LOWER, UPPER, -LIQUIDITY, 0));
        assertEq(IPoolManager(address(manager)).getLiquidity(key.toId()), 0);
        assertEq(hook.postFeeTokens(), lastQuote);
        assertEq(hook.postDraft(0, lastQuote), 1);
        assertEq(paper.balanceOf(DEAD), lastQuote);
        _checkSettled();
    }

    function test_capAtQuoteSucceedsAndEmitsActualVotes() public {
        bytes32 textHash = keccak256("Capped draft");
        vm.expectEmit(true, true, false, true, address(hook));
        emit DraftPosted(1, address(this), textHash, 1 ether);
        assertEq(hook.postDraft(textHash, 1 ether), 1);
        assertEq(paper.balanceOf(DEAD), 1 ether);
        assertEq(hook.draftCount(), 1);
        _checkSettled();
    }

    function test_largerCapBurnsOnlyExecutionQuote() public {
        uint256 beforeBalance = paper.balanceOf(address(this));
        assertEq(hook.postDraft(0, 2 ether), 1);
        assertEq(paper.balanceOf(address(this)), beforeBalance - 1 ether);
        assertEq(paper.balanceOf(DEAD), 1 ether);
    }

    function test_zeroCapAllowsOnlyFreePost() public {
        vm.expectRevert(abi.encodeWithSelector(PaperHook.PostFeeExceedsLimit.selector, 1 ether, 0));
        hook.postDraft(0, 0);
        assertEq(hook.draftCount(), 0);
        assertEq(paper.balanceOf(DEAD), 0);
        hook.setPostFeeUsd(0);
        assertEq(hook.postDraft(0, 0), 1);
        assertEq(paper.balanceOf(DEAD), 0);
    }

    function test_adminPriceChangeCannotExceedCallerCap() public {
        uint256 displayedQuote = hook.postFeeTokens();
        uint256 beforeBalance = paper.balanceOf(address(this));
        hook.setImdUsd(0.5 ether);
        assertEq(paper.allowance(address(this), address(hook)), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(PaperHook.PostFeeExceedsLimit.selector, 2 ether, displayedQuote));
        hook.postDraft(0, displayedQuote);
        assertEq(paper.balanceOf(address(this)), beforeBalance);
        assertEq(paper.balanceOf(DEAD), 0);
        assertEq(hook.draftCount(), 0);
    }

    function test_displacementCannotOverburnCappedPostWithUnlimitedAllowance() public {
        _paperOnlyPool();
        _buyWithPrepayment(100 ether);
        uint256 displayedQuote = hook.postFeeTokens();
        address victim = address(0xBEEF);
        paper.transfer(victim, 2_000_000 ether);
        vm.prank(victim);
        paper.approve(address(hook), type(uint256).max);

        // A dust position makes a manipulated far-away price have nonzero active liquidity.
        bool paperIs0 = Currency.unwrap(key.currency0) == address(paper);
        router.liquidity(
            key,
            ModifyLiquidityParams(
                paperIs0 ? int24(-138180) : int24(138120), paperIs0 ? int24(-138120) : int24(138180), 1e6, 0
            )
        );
        router.swap(
            key,
            SwapParams(paperIs0, -int256(1e24), TickMath.getSqrtPriceAtTick(paperIs0 ? int24(-138150) : int24(138150)))
        );
        uint256 displacedQuote = hook.postFeeTokens();
        assertGt(displacedQuote, displayedQuote * 900_000);
        assertGt(IPoolManager(address(manager)).getLiquidity(key.toId()), 0);
        vm.recordLogs();
        vm.prank(victim);
        vm.expectRevert(abi.encodeWithSelector(PaperHook.PostFeeExceedsLimit.selector, displacedQuote, displayedQuote));
        hook.postDraft(keccak256("Pending draft"), displayedQuote);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(paper.balanceOf(victim), 2_000_000 ether);
        assertEq(paper.balanceOf(DEAD), 0);
        assertEq(hook.draftCount(), 0);
        assertEq(paper.allowance(victim, address(hook)), type(uint256).max);
        _checkSettled();
    }

    function test_cappedPostRejectsReentrantPost() public {
        HostilePaper template = new HostilePaper();
        vm.etch(address(paper), address(template).code);
        HostilePaper hostile = HostilePaper(address(paper));
        hostile.configure(
            address(hook), abi.encodeWithSignature("postDraft(bytes32,uint256)", bytes32(0), 1 ether), false, false
        );
        hook.postDraft(0, 1 ether);
        assertFalse(hostile.reentrySucceeded());
        assertEq(hostile.reentryError(), PaperHook.ReentrantCall.selector);
        assertEq(hook.draftCount(), 1);
        assertEq(paper.balanceOf(DEAD), 1 ether);
    }
}

contract VotingProtectionReverseOrderTest is VotingProtectionTest {
    function _tokenAddress() internal pure override returns (address) {
        return address(type(uint160).max - 10);
    }
}
