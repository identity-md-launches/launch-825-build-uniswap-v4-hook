// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./HookFixture.sol";
import {PaperHook} from "../src/PaperHook.sol";
import {PaperSwapRouter} from "../src/PaperSwapRouter.sol";
import {PoolRouter} from "./mocks/PoolRouter.sol";
import {HostilePaper} from "./mocks/HostilePaper.sol";
import {UnlockProbe} from "./mocks/UnlockProbe.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// forge-config: default.fuzz.runs = 1000
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

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_capBoundaryAfterTrading(bool buy, bool exactInput, uint96 raw, uint8 capSeed) public {
        _swap(buy, exactInput, bound(uint256(raw), 1e12, 1e20));
        uint256 quote = hook.postFeeTokens();
        uint256 cap =
            capSeed % 4 == 0 ? quote - 1 : capSeed % 4 == 1 ? quote : capSeed % 4 == 2 ? quote + 1 : type(uint256).max;
        paper.approve(address(hook), quote + 1 ether);
        uint256 balanceBefore = paper.balanceOf(address(this));
        if (cap < quote) {
            vm.recordLogs();
            vm.expectRevert(abi.encodeWithSelector(PaperHook.PostFeeExceedsLimit.selector, quote, cap));
            hook.postDraft(keccak256("Cap boundary"), cap);
            assertEq(vm.getRecordedLogs().length, 0);
            assertEq(hook.draftCount(), 0);
            assertEq(paper.balanceOf(DEAD), 0);
            assertEq(paper.balanceOf(address(this)), balanceBefore);
            assertEq(paper.allowance(address(this), address(hook)), quote + 1 ether);
            cap = quote;
        }
        vm.expectEmit(true, true, false, true, address(hook));
        emit DraftPosted(1, address(this), keccak256("Cap boundary"), quote);
        assertEq(hook.postDraft(keccak256("Cap boundary"), cap), 1);
        assertEq(paper.balanceOf(DEAD), quote);
        assertEq(paper.balanceOf(address(this)), balanceBefore - quote);
        assertEq(paper.allowance(address(this), address(hook)), 1 ether);
        assertEq(paper.totalSupply(), 1e27);
        _checkSettled();
    }

    function test_capCannotReplaceAllowanceAndFailureDoesNotConsumeDraftId() public {
        paper.approve(address(hook), 0);
        // An excessive quote is refused before attempting the transfer, even without approval.
        vm.expectRevert(abi.encodeWithSelector(PaperHook.PostFeeExceedsLimit.selector, 1 ether, 1 ether - 1));
        hook.postDraft(0, 1 ether - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(hook), 0, 1 ether)
        );
        hook.postDraft(0, type(uint256).max);
        assertEq(hook.draftCount(), 0);
        assertEq(paper.balanceOf(DEAD), 0);
        paper.approve(address(hook), 1 ether);
        assertEq(hook.postDraft(0, 1 ether), 1);
        assertEq(paper.allowance(address(this), address(hook)), 0);
    }

    function test_cappedPostTransferFailuresRollBackAndAllowRetry() public {
        HostilePaper template = new HostilePaper();
        vm.etch(address(paper), address(template).code);
        HostilePaper hostile = HostilePaper(address(paper));
        uint256 balanceBefore = paper.balanceOf(address(this));
        paper.approve(address(hook), 1 ether);
        for (uint256 i; i < 2; ++i) {
            hostile.configure(address(hook), "", i == 0, i == 1);
            vm.expectRevert(
                i == 0
                    ? abi.encodeWithSelector(PaperHook.InexactTransfer.selector)
                    : abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(paper))
            );
            hook.postDraft(0, 1 ether);
            assertEq(hook.draftCount(), 0);
            assertEq(paper.balanceOf(DEAD), 0);
            assertEq(paper.balanceOf(address(this)), balanceBefore);
            assertEq(paper.allowance(address(this), address(hook)), 1 ether);
            assertEq(paper.totalSupply(), 1e27);
        }
        hostile.configure(address(hook), "", false, false);
        assertEq(hook.postDraft(0, 1 ether), 1);
        assertEq(paper.balanceOf(DEAD), 1 ether);
        assertEq(paper.allowance(address(this), address(hook)), 0);
        _checkSettled();
    }

    function test_cappedPostCannotReadFallbackDuringUnlockEvenWhenFree() public {
        _paperOnlyPool();
        UnlockProbe probe = new UnlockProbe(manager);
        for (uint256 i; i < 2; ++i) {
            if (i == 1) hook.setPostFeeUsd(0);
            (bool ok, bytes memory reason) = probe.probeCall(
                hook, abi.encodeWithSignature("postDraft(bytes32,uint256)", bytes32(0), type(uint256).max)
            );
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(PaperHook.PoolUnavailable.selector));
            assertEq(hook.draftCount(), 0);
            assertEq(paper.balanceOf(DEAD), 0);
        }
        assertEq(hook.postDraft(0, 0), 1);
        _checkSettled();
    }

    function test_fallbackRepricesUsdAndEnforcesCapAfterEmptyRangeMovement() public {
        _paperOnlyPool();
        _swap(false, true, 1 ether);
        hook.setPostFeeUsd(3);
        hook.setImdUsd(2 ether);
        assertEq(hook.postFeeTokens(), 1.5 ether);
        vm.expectRevert(abi.encodeWithSelector(PaperHook.PostFeeExceedsLimit.selector, 1.5 ether, 1 ether));
        hook.postDraft(0, 1 ether);
        assertEq(hook.draftCount(), 0);
        assertEq(hook.postDraft(0, 1.5 ether), 1);
        assertEq(paper.balanceOf(DEAD), 1.5 ether);
        _checkSettled();
    }

    function test_failedSwapCannotOverwriteFallbackPrice() public {
        _swap(false, true, 100 ether);
        uint256 quote = hook.postFeeTokens();
        assertGt(quote, 1 ether);
        PaperSwapRouter prepaid = new PaperSwapRouter(hook);
        imd.approve(address(prepaid), 200 ether);
        bool zeroForOne = Currency.unwrap(key.currency0) == IMD;
        vm.expectRevert(PaperSwapRouter.Slippage.selector);
        prepaid.swap(
            SwapParams(zeroForOne, -100 ether, zeroForOne ? Q96 / 2 : Q96 * 2),
            200 ether,
            type(uint256).max,
            address(this),
            block.timestamp
        );
        // Reading while liquidity is active would hide an incorrectly persisted cached price.
        router.liquidity(key, ModifyLiquidityParams(LOWER, UPPER, -LIQUIDITY, 0));
        assertEq(IPoolManager(address(manager)).getLiquidity(key.toId()), 0);
        assertEq(hook.postFeeTokens(), quote);
        assertEq(hook.postDraft(0, quote), 1);
        assertEq(paper.balanceOf(DEAD), quote);
        assertEq(imd.balanceOf(address(prepaid)), 0);
        assertEq(paper.balanceOf(address(prepaid)), 0);
        _checkSettled();
    }

    function test_quoteReturnsToLivePriceWhenLiquidityResumes() public {
        _swap(true, true, 100 ether);
        uint256 cachedQuote = hook.postFeeTokens();
        router.liquidity(key, ModifyLiquidityParams(LOWER, UPPER, -LIQUIDITY, 0));
        bool paperIs0 = Currency.unwrap(key.currency0) == address(paper);
        uint160 displaced = TickMath.getSqrtPriceAtTick(paperIs0 ? int24(-1200) : int24(1200));
        router.swap(key, SwapParams(paperIs0, -1 ether, displaced));
        assertEq(hook.postFeeTokens(), cachedQuote);
        router.liquidity(key, ModifyLiquidityParams(LOWER, UPPER, LIQUIDITY, 0));
        assertGt(IPoolManager(address(manager)).getLiquidity(key.toId()), 0);
        uint256 liveQuote = hook.postFeeTokens();
        assertGt(liveQuote, 1.12 ether);
        vm.expectRevert(abi.encodeWithSelector(PaperHook.PostFeeExceedsLimit.selector, liveQuote, cachedQuote));
        hook.postDraft(0, cachedQuote);
        assertEq(hook.postDraft(0, liveQuote), 1);
        assertEq(paper.balanceOf(DEAD), liveQuote);
        _checkSettled();
    }

    function test_bothPostingOverloadsAndBurnShareReentrancyGuard() public {
        HostilePaper template = new HostilePaper();
        vm.etch(address(paper), address(template).code);
        HostilePaper hostile = HostilePaper(address(paper));
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSignature("postDraft(bytes32)", bytes32(0));
        calls[1] = abi.encodeCall(PaperHook.burn, (1, 0));
        calls[2] = abi.encodeWithSignature("postDraft(bytes32,uint256)", bytes32(0), 1 ether);
        for (uint256 i; i < calls.length; ++i) {
            hostile.configure(address(hook), calls[i], false, false);
            if (i < 2) assertEq(hook.postDraft(0, 1 ether), i + 1);
            else assertEq(hook.postDraft(0), i + 1);
            assertFalse(hostile.reentrySucceeded());
            assertEq(hostile.reentryError(), PaperHook.ReentrantCall.selector);
            assertEq(hook.draftCount(), i + 1);
            assertEq(paper.balanceOf(DEAD), (i + 1) * 1 ether);
        }
        _checkSettled();
    }
}

/// forge-config: default.fuzz.runs = 1000
contract VotingProtectionReverseOrderTest is VotingProtectionTest {
    function _tokenAddress() internal pure override returns (address) {
        return address(type(uint160).max - 10);
    }
}
