// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookFixture} from "./HookFixture.sol";
import {PaperHook} from "src/PaperHook.sol";
import {PaperHookV2} from "src/PaperHookV2.sol";
import {PaperSwapRouter} from "src/PaperSwapRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @notice Exercise the production router's temporary custody, refunds, and rollback across users.
contract PrepaidRouterHandler is Test {
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    PaperHook public immutable hook;
    PaperSwapRouter public immutable router;
    IERC20 public immutable paper;
    IERC20 public immutable imd;
    address public immutable v1;
    address public immutable v2;
    address[3] public actors = [address(0xA210), address(0xA211), address(0xA212)];
    mapping(address => uint256) public expectedPaper;
    mapping(address => uint256) public expectedImd;
    uint256 public paperDeposits;
    uint256 public imdDeposits;
    uint256 public ordersPaid;
    uint256 public devPaid;
    uint256 public swaps;
    uint256 public refusals;
    uint256 public upgrades;
    PoolKey private key;

    constructor(PaperHook h, PaperSwapRouter r, address logic1, address logic2) {
        hook = h;
        router = r;
        paper = IERC20(h.token());
        imd = IERC20(h.IMD());
        key = h.poolKey();
        v1 = logic1;
        v2 = logic2;
        for (uint256 i; i < actors.length; ++i) {
            expectedPaper[actors[i]] = 1e24;
            expectedImd[actors[i]] = 1e24;
        }
    }

    function _params(bool buy, bool exactInput, uint256 amount) private view returns (SwapParams memory) {
        bool zeroForOne = buy == (Currency.unwrap(key.currency0) == address(imd));
        return SwapParams(
            zeroForOne,
            exactInput ? -int256(amount) : int256(amount),
            zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341
        );
    }

    function trade(uint8 payerSeed, uint8 recipientSeed, bool buy, bool exactInput, uint96 raw) external {
        address payer = actors[payerSeed % 3];
        address recipient = actors[recipientSeed % 3];
        uint256 amount = bound(uint256(raw), 1e12, 1e20);
        // Overpay exact-input swaps too: the fee must use the trade amount, not this budget.
        uint256 budget = 2 * amount + 1e12;
        IERC20 input = buy ? imd : paper;
        uint256 managerBefore = imd.balanceOf(address(router.manager()));
        (, uint256 ordersBps,,) = hook.split();
        vm.startPrank(payer);
        input.approve(address(router), budget);
        BalanceDelta delta = router.swap(_params(buy, exactInput, amount), budget, 1, recipient, block.timestamp);
        vm.stopPrank();
        uint256 spent =
            uint256(-int256(_params(buy, exactInput, amount).zeroForOne ? delta.amount0() : delta.amount1()));
        uint256 received =
            uint256(int256(_params(buy, exactInput, amount).zeroForOne ? delta.amount1() : delta.amount0()));
        assertLt(spent, budget, "unused budget must be refunded");
        assertEq(input.allowance(payer, address(router)), 0, "only the approved budget may be pulled");
        if (exactInput) assertEq(spent, amount);
        else assertEq(received, amount);

        if (buy) {
            expectedImd[payer] -= spent;
            expectedPaper[recipient] += received;
        } else {
            expectedPaper[payer] -= spent;
            expectedImd[recipient] += received;
        }
        // Sell fee basis is independently measured from the manager's physical IMD outflow.
        uint256 gross = buy ? spent : managerBefore - imd.balanceOf(address(router.manager()));
        uint256 fee = gross / 50;
        uint256 orders = fee * ordersBps / 200;
        ordersPaid += orders;
        devPaid += fee - orders;
        ++swaps;
    }

    function depositResidual(uint8 actorSeed, bool isImd, uint96 raw) external {
        address actor = actors[actorSeed % 3];
        uint256 amount = bound(uint256(raw), 0, 1e19);
        vm.prank(actor);
        assertTrue((isImd ? imd : paper).transfer(address(router), amount));
        if (isImd) {
            expectedImd[actor] -= amount;
            imdDeposits += amount;
        } else {
            expectedPaper[actor] -= amount;
            paperDeposits += amount;
        }
    }

    function _snapshot(address payer, IERC20 input) private view returns (bytes32) {
        bytes memory balances;
        for (uint256 i; i < actors.length; ++i) {
            balances = abi.encode(balances, paper.balanceOf(actors[i]), imd.balanceOf(actors[i]));
        }
        balances =
            abi.encode(balances, paper.balanceOf(address(router.manager())), imd.balanceOf(address(router.manager())));
        balances = abi.encode(balances, paper.balanceOf(address(router)), imd.balanceOf(address(router)));
        balances = abi.encode(balances, imd.balanceOf(hook.ORDERS()), imd.balanceOf(hook.DEV()));
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = router.manager().getSlot0(key.toId());
        return keccak256(abi.encode(balances, price, tick, protocolFee, lpFee, input.allowance(payer, address(router))));
    }

    function rejectedSlippage(uint8 actorSeed, bool buy, bool exactInput, uint96 raw) external {
        address payer = actors[actorSeed % 3];
        uint256 amount = bound(uint256(raw), 1e12, 1e20);
        uint256 budget = 2 * amount + 1e12;
        IERC20 input = buy ? imd : paper;
        vm.prank(payer);
        input.approve(address(router), budget);
        bytes32 beforeState = _snapshot(payer, input);
        vm.prank(payer);
        vm.expectRevert(PaperSwapRouter.Slippage.selector);
        router.swap(_params(buy, exactInput, amount), budget, type(uint256).max, payer, block.timestamp);
        assertEq(
            _snapshot(payer, input), beforeState, "failed swap must undo prepayment, fees, pool movement and allowance"
        );
        ++refusals;
    }

    function changeSplit(uint8 seed) external {
        uint256 bps = bound(uint256(seed), 0, 200);
        hook.setSplit(hook.ORDERS(), bps, hook.DEV(), 200 - bps);
    }

    function upgrade(bool useV2) external {
        bytes32 slot = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        ProxyAdmin admin = ProxyAdmin(address(uint160(uint256(vm.load(address(hook), slot)))));
        vm.prank(hook.DEV());
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(hook)), useV2 ? v2 : v1, "");
        ++upgrades;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract RouterStatefulTest is HookFixture {
    using TransientStateLibrary for IPoolManager;
    PrepaidRouterHandler private handler;
    PaperSwapRouter private prepaid;

    function setUp() public override {
        super.setUp();
        prepaid = new PaperSwapRouter(hook);
        handler = new PrepaidRouterHandler(hook, prepaid, address(implementation), address(new PaperHookV2(manager)));
        hook.transferOwnership(address(handler));
        for (uint256 i; i < 3; ++i) {
            paper.transfer(handler.actors(i), 1e24);
            imd.transfer(handler.actors(i), 1e24);
        }
        handler.depositResidual(0, true, 7 ether);
        handler.depositResidual(1, false, 11 ether);
        handler.changeSplit(73);
        handler.trade(0, 1, true, true, 100 ether);
        handler.trade(1, 2, true, false, 100 ether);
        handler.trade(2, 0, false, true, 100 ether);
        handler.trade(0, 0, false, false, 100 ether);
        handler.rejectedSlippage(0, true, true, 100 ether);
        handler.upgrade(true);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = PrepaidRouterHandler.trade.selector;
        selectors[1] = PrepaidRouterHandler.depositResidual.selector;
        selectors[2] = PrepaidRouterHandler.rejectedSlippage.selector;
        selectors[3] = PrepaidRouterHandler.changeSplit.selector;
        selectors[4] = PrepaidRouterHandler.upgrade.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_routerPreservesEachUsersFundsAndOnlyRetainsUnsolicitedDeposits() public view {
        assertEq(paper.balanceOf(address(prepaid)), handler.paperDeposits());
        assertEq(imd.balanceOf(address(prepaid)), handler.imdDeposits());
        assertEq(imd.balanceOf(ORDERS), handler.ordersPaid());
        assertEq(imd.balanceOf(DEV), handler.devPaid());
        uint256 paperAccounted =
            paper.balanceOf(address(this)) + paper.balanceOf(address(manager)) + handler.paperDeposits();
        uint256 imdAccounted = imd.balanceOf(address(this)) + imd.balanceOf(address(manager)) + handler.imdDeposits()
            + handler.ordersPaid() + handler.devPaid();
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            assertEq(paper.balanceOf(actor), handler.expectedPaper(actor), "paper debits, output or refund mismatch");
            assertEq(imd.balanceOf(actor), handler.expectedImd(actor), "IMD debits, output or refund mismatch");
            paperAccounted += paper.balanceOf(actor);
            imdAccounted += imd.balanceOf(actor);
        }
        assertEq(paperAccounted, paper.totalSupply());
        assertEq(imdAccounted, imd.totalSupply());
        assertEq(hook.feeBps(), 200);
        (, uint256 ordersBps,, uint256 devBps) = hook.split();
        assertEq(ordersBps + devBps, 200);
        IPoolManager pm = manager;
        assertEq(pm.currencyDelta(address(prepaid), key.currency0), 0);
        assertEq(pm.currencyDelta(address(prepaid), key.currency1), 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(IMD))), 0);
        assertEq(manager.balanceOf(address(prepaid), uint256(uint160(IMD))), 0);
        assertGe(handler.swaps(), 4);
        assertGe(handler.refusals(), 1);
        assertGe(handler.upgrades(), 1);
        _checkSettled();
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract RouterStatefulReverseOrderTest is RouterStatefulTest {
    function _tokenAddress() internal pure override returns (address) {
        return address(type(uint160).max - 10);
    }
}
