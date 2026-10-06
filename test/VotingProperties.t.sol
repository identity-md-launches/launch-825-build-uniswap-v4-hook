// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./HookFixture.sol";
import {Vm} from "forge-std/Vm.sol";
import {PaperHook} from "src/PaperHook.sol";
import {PaperHookV2} from "src/PaperHookV2.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// forge-config: default.fuzz.runs = 1000
contract VotingPropertiesTest is HookFixture {
    event DraftPosted(uint256 indexed draftId, address indexed author, bytes32 textHash, uint256 burned);
    event Burned(uint256 indexed draftId, address indexed voter, uint256 amount);

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_quoteIsSmallestSufficientWholeTokenAmount(uint64 rawUsd, uint96 rawImdUsd) public {
        uint256 usd = bound(uint256(rawUsd), 0, 1e12);
        uint256 imdUsd = bound(uint256(rawImdUsd), 1, 1e24);
        hook.setPostFeeUsd(usd);
        hook.setImdUsd(imdUsd);
        uint256 quote = hook.postFeeTokens();
        // At raw price 1:1 and equal decimals, compare dollar value without division.
        // Checking inequalities independently catches wrong rounding direction and scaling.
        uint256 cost = usd * 1e36;
        assertGe(quote * imdUsd, cost);
        if (quote != 0) assertLt((quote - 1) * imdUsd, cost);
        else assertEq(usd, 0);
    }

    function test_eventsAttributeEveryVoteExactlyOnceAcrossAuthorsAndRepeatedHashes() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        paper.transfer(alice, 5 ether);
        paper.transfer(bob, 5 ether);
        bytes32 textHash = keccak256("Same text, independent drafts");
        vm.startPrank(alice);
        paper.approve(address(hook), 5 ether);
        vm.recordLogs();
        assertEq(hook.postDraft(textHash), 1);
        vm.stopPrank();
        vm.startPrank(bob);
        paper.approve(address(hook), 5 ether);
        assertEq(hook.postDraft(textHash), 2);
        hook.burn(1, 2 ether);
        hook.burn(1, 0);
        vm.stopPrank();
        vm.prank(alice);
        hook.burn(2, 3 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 posts;
        uint256 burns;
        uint256 eventVotes;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook)) continue;
            uint256 id = uint256(logs[i].topics[1]);
            address voter = address(uint160(uint256(logs[i].topics[2])));
            if (logs[i].topics[0] == keccak256("DraftPosted(uint256,address,bytes32,uint256)")) {
                (bytes32 text, uint256 amount) = abi.decode(logs[i].data, (bytes32, uint256));
                assertEq(id, posts + 1);
                assertEq(voter, posts == 0 ? alice : bob);
                assertEq(text, textHash);
                assertEq(amount, 1 ether);
                ++posts;
                eventVotes += amount;
            } else {
                assertEq(logs[i].topics[0], keccak256("Burned(uint256,address,uint256)"));
                assertEq(id, burns < 2 ? 1 : 2);
                assertEq(voter, burns < 2 ? bob : alice);
                uint256 amount = abi.decode(logs[i].data, (uint256));
                assertEq(amount, burns == 0 ? 2 ether : burns == 1 ? 0 : 3 ether);
                ++burns;
                eventVotes += amount;
            }
        }
        assertEq(posts, 2);
        assertEq(burns, 3);
        assertEq(eventVotes, paper.balanceOf(DEAD));
        assertEq(eventVotes, 7 ether);
        assertEq(paper.balanceOf(alice), 1 ether);
        assertEq(paper.balanceOf(bob), 2 ether);
        assertEq(hook.draftCount(), 2);
    }

    function test_exactApprovalProtectsPostWhenPoolPriceChanges() public {
        uint256 initialQuote = hook.postFeeTokens();
        paper.approve(address(hook), initialQuote);
        _swap(false, true, 100 ether);
        uint256 changedQuote = hook.postFeeTokens();
        assertGt(changedQuote, initialQuote);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(hook), initialQuote, changedQuote
            )
        );
        hook.postDraft(0);
        assertEq(hook.draftCount(), 0);
        assertEq(paper.balanceOf(DEAD), 0);
        assertEq(paper.allowance(address(this), address(hook)), initialQuote);
        paper.approve(address(hook), changedQuote);
        assertEq(hook.postDraft(0), 1);
        assertEq(paper.balanceOf(DEAD), changedQuote);
        assertEq(paper.allowance(address(this), address(hook)), 0);
    }

    function test_existingDraftRemainsVotableWhenLiquidityIsRemoved() public {
        uint256 id = hook.postDraft(0);
        router.liquidity(key, ModifyLiquidityParams(LOWER, UPPER, -LIQUIDITY, 0));
        vm.expectRevert(PaperHook.PoolUnavailable.selector);
        hook.postDraft(0);
        vm.expectEmit(true, true, false, true, address(hook));
        emit Burned(id, address(this), 9 ether);
        hook.burn(id, 9 ether);
        assertEq(hook.draftCount(), 1);
        assertEq(paper.balanceOf(DEAD), 10 ether);
        _checkSettled();
    }

    function test_maximumBurnFailsWithoutChangingExistingDraft() public {
        hook.postDraft(0);
        uint256 beforeBalance = paper.balanceOf(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), beforeBalance, type(uint256).max
            )
        );
        hook.burn(1, type(uint256).max);
        assertEq(hook.draftCount(), 1);
        assertEq(paper.balanceOf(DEAD), 1 ether);
        assertEq(paper.balanceOf(address(this)), beforeBalance);
        hook.burn(1, 1);
        assertEq(paper.balanceOf(DEAD), 1 ether + 1);
    }

    function test_transferringHookOwnershipDoesNotTransferUpgradeAuthority() public {
        address newOwner = address(0xA11CE);
        hook.transferOwnership(newOwner);
        vm.expectRevert(PaperHook.Unauthorized.selector);
        hook.setSplit(ORDERS, 200, DEV, 0);
        vm.prank(DEV);
        vm.expectRevert(PaperHook.Unauthorized.selector);
        hook.setPostFeeUsd(2);
        vm.prank(newOwner);
        hook.setSplit(ORDERS, 200, DEV, 0);
        bytes32 adminSlot = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        ProxyAdmin admin = ProxyAdmin(address(uint160(uint256(vm.load(address(hook), adminSlot)))));
        PaperHookV2 v2 = new PaperHookV2(manager);
        assertEq(admin.owner(), DEV);
        vm.prank(DEV);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(hook)), address(v2), "");
        assertEq(hook.owner(), newOwner);
        _swap(true, true, 100 ether);
        assertEq(imd.balanceOf(ORDERS), 2 ether);
        assertEq(imd.balanceOf(DEV), 0);
        _checkSettled();
    }

    function test_freshV2ReversedDefaultsActuallyPayBothDirections() public {
        PaperHookV2 v2 = new PaperHookV2(manager);
        hook = _deploy(address(v2), Q96);
        key = hook.poolKey();
        router.liquidity(key, ModifyLiquidityParams(LOWER, UPPER, LIQUIDITY, 0));
        _swap(true, true, 100 ether);
        assertEq(imd.balanceOf(ORDERS), 1.5 ether);
        assertEq(imd.balanceOf(DEV), 0.5 ether);
        uint256 managerBefore = imd.balanceOf(address(manager));
        _swap(false, true, 100 ether);
        uint256 gross = managerBefore - imd.balanceOf(address(manager));
        uint256 fee = gross / 50;
        assertEq(imd.balanceOf(ORDERS) - 1.5 ether, fee * 3 / 4);
        assertEq(imd.balanceOf(DEV) - 0.5 ether, fee - fee * 3 / 4);
        _checkSettled();
    }
}

/// forge-config: default.fuzz.runs = 1000
contract VotingPropertiesReverseOrderTest is VotingPropertiesTest {
    function _tokenAddress() internal pure override returns (address) {
        return address(type(uint160).max - 10);
    }
}
