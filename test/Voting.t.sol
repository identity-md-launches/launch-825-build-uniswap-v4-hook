// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./HookFixture.sol";
import {PaperHook} from "../src/PaperHook.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MockDecimalsERC20} from "./mocks/MockDecimalsERC20.sol";
import {UnlockProbe} from "./mocks/UnlockProbe.sol";

contract VotingTest is HookFixture {
    event DraftPosted(uint256 indexed draftId, address indexed author, bytes32 textHash, uint256 burned);
    event Burned(uint256 indexed draftId, address indexed voter, uint256 amount);

    function test_postBurnsAndEmitsAuthorsVotes() public {
        assertEq(hook.postFeeUsd(), 1);
        assertEq(hook.postFeeTokens(), 1 ether);
        bytes32 text = keccak256("Draft text");
        uint256 beforeBalance = paper.balanceOf(address(this));
        vm.expectEmit(true, true, false, true, address(hook));
        emit DraftPosted(1, address(this), text, 1 ether);
        assertEq(hook.postDraft(text), 1);
        assertEq(hook.draftCount(), 1);
        assertEq(paper.balanceOf(DEAD), 1 ether);
        assertEq(paper.balanceOf(address(this)), beforeBalance - 1 ether);
        assertEq(paper.totalSupply(), 1e27);
        assertEq(paper.balanceOf(address(hook)), 0);
    }

    function test_repeatBurnAnyExistingDraftAndZeroAmount() public {
        hook.postDraft(keccak256("First"));
        hook.postDraft(keccak256("Second"));
        address voter = address(123);
        paper.transfer(voter, 10 ether);
        vm.startPrank(voter);
        paper.approve(address(hook), 10 ether);
        vm.expectEmit(true, true, false, true, address(hook));
        emit Burned(1, voter, 3 ether);
        hook.burn(1, 3 ether);
        hook.burn(1, 2 ether);
        hook.burn(2, 5 ether);
        hook.burn(1, 0);
        vm.stopPrank();
        assertEq(paper.balanceOf(DEAD), 12 ether);
        assertEq(paper.balanceOf(voter), 0);
        assertEq(paper.balanceOf(address(hook)), 0);
    }

    function test_nonexistentDraftCannotBurn() public {
        vm.expectRevert(PaperHook.InvalidDraft.selector);
        hook.burn(1, 1 ether);
        hook.postDraft(0);
        vm.expectRevert(PaperHook.InvalidDraft.selector);
        hook.burn(0, 0);
        vm.expectRevert(PaperHook.InvalidDraft.selector);
        hook.burn(2, 1 ether);
        assertEq(paper.balanceOf(DEAD), 1 ether);
    }

    function test_postAllowanceFailureRollsBackId() public {
        paper.approve(address(hook), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(hook), 0, 1 ether)
        );
        hook.postDraft(0);
        assertEq(hook.draftCount(), 0);
        assertEq(paper.balanceOf(DEAD), 0);
        paper.approve(address(hook), 1 ether);
        assertEq(hook.postDraft(0), 1);
    }

    function test_insufficientBalanceAndBurnAllowance() public {
        uint256 id = hook.postDraft(0);
        paper.approve(address(hook), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(hook), 0, 1));
        hook.burn(id, 1);
        vm.startPrank(address(123));
        paper.approve(address(hook), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(123), 0, 1 ether)
        );
        hook.postDraft(0);
        vm.stopPrank();
        assertEq(hook.draftCount(), 1);
        assertEq(paper.balanceOf(DEAD), 1 ether);
    }

    function test_priceAndUsdSettingsChangeQuote() public {
        hook.setPostFeeUsd(3);
        assertEq(hook.postFeeTokens(), 3 ether);
        hook.setImdUsd(2 ether);
        assertEq(hook.postFeeTokens(), 1.5 ether);
        hook.setPostFeeUsd(0);
        assertEq(hook.postFeeTokens(), 0);
        assertEq(hook.postDraft(0), 1);
        assertEq(paper.balanceOf(DEAD), 0);
        vm.expectRevert(PaperHook.InvalidConfiguration.selector);
        hook.setImdUsd(0);
    }

    function test_settingsOwnerOnlyAndOwnershipTransfer() public {
        vm.startPrank(address(123));
        vm.expectRevert(PaperHook.Unauthorized.selector);
        hook.setPostFeeUsd(2);
        vm.expectRevert(PaperHook.Unauthorized.selector);
        hook.setImdUsd(2 ether);
        vm.expectRevert(PaperHook.Unauthorized.selector);
        hook.transferOwnership(address(123));
        vm.stopPrank();
        vm.expectRevert(PaperHook.InvalidConfiguration.selector);
        hook.transferOwnership(address(0));
        hook.transferOwnership(address(123));
        vm.expectRevert(PaperHook.Unauthorized.selector);
        hook.setPostFeeUsd(3);
        vm.prank(address(123));
        hook.setPostFeeUsd(3);
        assertEq(hook.postFeeUsd(), 3);
    }

    function test_quoteReadsPoolPriceBothCurrencyOrders() public {
        PaperHook other = _deploy(address(implementation), Q96 * 2);
        router.liquidity(other.poolKey(), ModifyLiquidityParams(LOWER, UPPER, LIQUIDITY, 0));
        uint256 expected = Currency.unwrap(key.currency0) == address(paper) ? 0.25 ether : 4 ether;
        assertEq(other.postFeeTokens(), expected);
        paper.approve(address(other), expected);
        other.postDraft(0);
        assertEq(paper.balanceOf(DEAD), expected);
        uint256 beforeQuote = hook.postFeeTokens();
        _swap(true, true, 1e20);
        assertLt(hook.postFeeTokens(), beforeQuote);
    }

    function test_quoteUsesLaunchPriceBeforeSeeding() public {
        PaperHook unseeded = _deploy(address(implementation), Q96);
        assertEq(unseeded.postFeeTokens(), 1 ether);
        paper.approve(address(unseeded), 1 ether);
        assertEq(unseeded.postDraft(0), 1);
        assertEq(paper.balanceOf(DEAD), 1 ether);
    }

    function test_roundingUpPreventsFreeDustPost() public {
        hook.setImdUsd(3 ether);
        assertEq(hook.postFeeTokens(), 333333333333333334);
        hook.setImdUsd(type(uint256).max);
        assertEq(hook.postFeeTokens(), 1);
    }

    function test_sixDecimalImdNormalization() public {
        MockDecimalsERC20 six = new MockDecimalsERC20(6);
        vm.etch(IMD, address(six).code);
        PaperHook normalized = _deploy(address(implementation), Q96);
        router.liquidity(normalized.poolKey(), ModifyLiquidityParams(LOWER, UPPER, LIQUIDITY, 0));
        // At raw ratio 1:1, one whole six-decimal IMD is worth 1e6 paper minor units.
        assertEq(normalized.postFeeTokens(), 1e6);
    }

    function test_quotesAndPostsRefuseUnlockedPool() public {
        UnlockProbe probe = new UnlockProbe(manager);
        (bool ok, bytes memory error) = probe.probe(hook, false);
        assertFalse(ok);
        assertEq(error, abi.encodeWithSelector(PaperHook.PoolUnavailable.selector));
        (ok, error) = probe.probe(hook, true);
        assertFalse(ok);
        assertEq(error, abi.encodeWithSelector(PaperHook.PoolUnavailable.selector));
        assertEq(hook.draftCount(), 0);
        _checkSettled();
    }

    function test_largeSqrtPriceDoesNotOverflow() public {
        uint160 price = uint160(1) << 130;
        PaperHook large = _deploy(address(implementation), price);
        router.liquidity(large.poolKey(), ModifyLiquidityParams(LOWER, UPPER, 10_000, 0));
        uint256 expected = Currency.unwrap(key.currency0) == address(paper) ? 1 : 1 ether * (uint256(1) << 68);
        assertEq(large.postFeeTokens(), expected);
    }

    function testFuzz_burnConservesTokens(uint96 rawAmount) public {
        uint256 id = hook.postDraft(0);
        uint256 amount = bound(uint256(rawAmount), 0, 1e25);
        uint256 beforeBalance = paper.balanceOf(address(this));
        hook.burn(id, amount);
        assertEq(paper.balanceOf(DEAD), 1 ether + amount);
        assertEq(paper.balanceOf(address(this)), beforeBalance - amount);
        assertEq(paper.totalSupply(), 1e27);
        _checkSettled();
    }
}

contract VotingReverseOrderTest is VotingTest {
    function _tokenAddress() internal pure override returns (address) {
        return address(type(uint160).max - 10);
    }
}
