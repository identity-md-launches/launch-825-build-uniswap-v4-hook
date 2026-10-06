// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookFixture} from "./HookFixture.sol";
import {PoolRouter} from "./mocks/PoolRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Paper} from "src/Paper.sol";
import {PaperHook} from "src/PaperHook.sol";
import {PaperHookV2} from "src/PaperHookV2.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice Multiple users, rotating recipients, and upgrades share one real manager.
/// Ghost fees come from physical trader/manager balance changes, independently of return deltas.
contract ReviewHandler is Test {
    PaperHook public immutable hook;
    PoolRouter public immutable router;
    Paper public immutable paper;
    MockERC20 public immutable imd;
    ProxyAdmin public immutable admin;
    address public immutable v1;
    address public immutable v2;
    address public currentImplementation;
    address[3] public actors = [address(0xA110), address(0xA111), address(0xA112)];
    address[3] public recipients = [address(0xFEE0), address(0xFEE1), address(0xFEE2)];
    mapping(address => uint256) public expectedPayout;
    uint256 public expectedDead;
    uint256 public expectedDrafts;
    uint256 public expectedUsd = 1;
    uint256 public expectedImdUsd = 1 ether;
    uint256 public swaps;
    uint256 public upgrades;
    uint256 public rejectedCalls;
    PoolKey private key;

    constructor(PaperHook h, PoolRouter r, Paper p, MockERC20 i, address logic1, address logic2) {
        hook = h;
        router = r;
        paper = p;
        imd = i;
        v1 = logic1;
        v2 = logic2;
        currentImplementation = logic1;
        key = h.poolKey();
        bytes32 adminSlot = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        admin = ProxyAdmin(address(uint160(uint256(vm.load(address(h), adminSlot)))));
        for (uint256 n; n < actors.length; ++n) {
            vm.startPrank(actors[n]);
            p.approve(address(h), type(uint256).max);
            p.approve(address(r), type(uint256).max);
            i.approve(address(r), type(uint256).max);
            vm.stopPrank();
        }
    }

    function trade(uint8 actorSeed, bool buy, bool exactInput, uint96 raw) external {
        address actor = actors[actorSeed % actors.length];
        uint256 amount = bound(uint256(raw), 100, 1e20);
        bool zeroForOne = buy == (Currency.unwrap(key.currency0) == address(imd));
        uint160 limit = zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341;
        uint256 traderBefore = imd.balanceOf(actor);
        uint256 managerBefore = imd.balanceOf(address(router.manager()));
        (address orders, uint256 ordersBps, address dev,) = hook.split();
        vm.prank(actor);
        router.swap(key, SwapParams(zeroForOne, exactInput ? -int256(amount) : int256(amount), limit));
        uint256 gross =
            buy ? traderBefore - imd.balanceOf(actor) : managerBefore - imd.balanceOf(address(router.manager()));
        uint256 fee = gross / 50;
        uint256 ordersAmount = fee * ordersBps / 200;
        expectedPayout[orders] += ordersAmount;
        expectedPayout[dev] += fee - ordersAmount;
        ++swaps;
    }

    function changeSplit(uint8 ordersSeed, uint8 devSeed, uint8 bpsSeed) external {
        uint256 ordersBps = bound(uint256(bpsSeed), 0, 200);
        hook.setSplit(recipients[ordersSeed % 3], ordersBps, recipients[devSeed % 3], 200 - ordersBps);
    }

    function configure(uint8 usdSeed, uint96 imdUsdSeed) external {
        expectedUsd = bound(uint256(usdSeed), 0, 10);
        expectedImdUsd = bound(uint256(imdUsdSeed), 1e17, 10 ether);
        hook.setPostFeeUsd(expectedUsd);
        hook.setImdUsd(expectedImdUsd);
    }

    function post(uint8 actorSeed, bytes32 text) external {
        uint256 quote = hook.postFeeTokens();
        vm.prank(actors[actorSeed % 3]);
        assertEq(hook.postDraft(text), expectedDrafts + 1);
        ++expectedDrafts;
        expectedDead += quote;
    }

    function vote(uint8 actorSeed, uint256 draftSeed, uint96 raw) external {
        // setUp creates the first draft, so every generated vote exercises an existing ID.
        uint256 id = bound(draftSeed, 1, expectedDrafts);
        uint256 amount = bound(uint256(raw), 0, 1e20);
        vm.prank(actors[actorSeed % 3]);
        hook.burn(id, amount);
        expectedDead += amount;
    }

    function upgrade(bool useV2) external {
        bytes32 namespace = keccak256(abi.encode(uint256(keccak256("paper.storage.Hook")) - 1)) & ~bytes32(uint256(255));
        bytes32[] memory beforeSlots = new bytes32[](20);
        for (uint256 i; i < beforeSlots.length; ++i) {
            beforeSlots[i] = vm.load(address(hook), bytes32(uint256(namespace) + i));
        }
        currentImplementation = useV2 ? v2 : v1;
        vm.prank(hook.DEV());
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(hook)), currentImplementation, "");
        for (uint256 i; i < beforeSlots.length; ++i) {
            assertEq(vm.load(address(hook), bytes32(uint256(namespace) + i)), beforeSlots[i]);
        }
        ++upgrades;
    }

    function rejectedVote(uint8 actorSeed, uint256 amount) external {
        uint256 deadBefore = paper.balanceOf(hook.DEAD());
        address actor = actors[actorSeed % 3];
        uint256 balanceBefore = paper.balanceOf(actor);
        vm.prank(actor);
        vm.expectRevert(PaperHook.InvalidDraft.selector);
        hook.burn(expectedDrafts + 1, amount);
        assertEq(paper.balanceOf(actor), balanceBefore);
        assertEq(paper.balanceOf(hook.DEAD()), deadBefore);
        assertEq(hook.draftCount(), expectedDrafts);
        ++rejectedCalls;
    }

    function rejectedAdmin(uint8 actorSeed, uint256 usd) external {
        vm.prank(actors[actorSeed % 3]);
        vm.expectRevert(PaperHook.Unauthorized.selector);
        hook.setPostFeeUsd(usd);
        assertEq(hook.postFeeUsd(), expectedUsd);
        ++rejectedCalls;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract StatefulReviewTest is HookFixture {
    ReviewHandler private handler;

    function setUp() public override {
        super.setUp();
        PaperHookV2 v2 = new PaperHookV2(manager);
        handler = new ReviewHandler(hook, router, paper, imd, address(implementation), address(v2));
        hook.transferOwnership(address(handler));
        for (uint256 i; i < 3; ++i) {
            paper.transfer(handler.actors(i), 1e24);
            imd.transfer(handler.actors(i), 1e24);
        }
        handler.changeSplit(0, 1, 50);
        handler.post(0, keccak256("Initial draft"));
        // Seed every action, including all swap modes, so the invariant is not vacuous.
        handler.trade(0, true, true, 100 ether);
        handler.trade(1, true, false, 100 ether);
        handler.trade(2, false, true, 100 ether);
        handler.trade(0, false, false, 100 ether);
        handler.configure(2, 2 ether);
        handler.vote(1, 1, 1 ether);
        handler.upgrade(true);
        handler.rejectedVote(0, 1);
        handler.rejectedAdmin(1, 10);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = ReviewHandler.trade.selector;
        selectors[1] = ReviewHandler.changeSplit.selector;
        selectors[2] = ReviewHandler.configure.selector;
        selectors[3] = ReviewHandler.post.selector;
        selectors[4] = ReviewHandler.vote.selector;
        selectors[5] = ReviewHandler.upgrade.selector;
        selectors[6] = ReviewHandler.rejectedVote.selector;
        selectors[7] = ReviewHandler.rejectedAdmin.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_allFeesAndVotesAreBackedAndStateSurvivesUpgrades() public view {
        assertEq(hook.feeBps(), 200);
        (, uint256 ordersBps,, uint256 devBps) = hook.split();
        assertEq(ordersBps + devBps, 200);
        assertEq(hook.owner(), address(handler));
        assertEq(hook.postFeeUsd(), handler.expectedUsd());
        assertEq(hook.imdUsd(), handler.expectedImdUsd());
        assertEq(hook.draftCount(), handler.expectedDrafts());
        assertEq(paper.balanceOf(DEAD), handler.expectedDead());
        assertEq(hook.token(), address(paper));
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(keccak256(abi.encode(hook.poolKey())), keccak256(abi.encode(key)));
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        assertEq(address(uint160(uint256(vm.load(address(hook), implSlot)))), handler.currentImplementation());
        assertEq(handler.admin().owner(), DEV);
        uint256 paperAccounted =
            paper.balanceOf(address(this)) + paper.balanceOf(address(manager)) + paper.balanceOf(DEAD);
        uint256 imdAccounted = imd.balanceOf(address(this)) + imd.balanceOf(address(manager));
        for (uint256 i; i < 3; ++i) {
            address recipient = handler.recipients(i);
            assertEq(imd.balanceOf(recipient), handler.expectedPayout(recipient));
            paperAccounted += paper.balanceOf(handler.actors(i));
            imdAccounted += imd.balanceOf(handler.actors(i)) + imd.balanceOf(recipient);
        }
        assertEq(paperAccounted, paper.totalSupply());
        assertEq(imdAccounted, imd.totalSupply());
        assertEq(paper.totalSupply(), 1e27);
        assertEq(imd.balanceOf(ORDERS), 0);
        assertEq(imd.balanceOf(DEV), 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(IMD))), 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(paper)))), 0);
        assertEq(paper.balanceOf(address(router)), 0);
        assertEq(imd.balanceOf(address(router)), 0);
        assertGe(handler.swaps(), 4);
        assertGe(handler.upgrades(), 1);
        assertGe(handler.rejectedCalls(), 2);
        _checkSettled();
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract StatefulReviewReverseOrderTest is StatefulReviewTest {
    function _tokenAddress() internal pure override returns (address) {
        return address(type(uint160).max - 10);
    }
}
