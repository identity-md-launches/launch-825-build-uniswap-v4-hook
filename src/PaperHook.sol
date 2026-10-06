// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {HookFlags} from "./HookFlags.sol";

contract PaperHook is Initializable, IHooks {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant ORDERS = 0x721F8232e19c92516eB753FEF53d8A33a3637989;
    address public constant DEV = 0xb59eac9882Ba98f4170d99D5F402C3EDb6D50D75;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant TOTAL_BPS = 200;
    uint256 private constant BPS = 10_000;

    /// @custom:storage-location erc7201:paper.storage.Hook
    struct HookStorage {
        IPoolManager manager;
        address token;
        address owner;
        address launcher;
        address ordersWallet;
        address devWallet;
        uint256 ordersBps;
        uint256 devBps;
        uint256 postFeeUsd;
        uint256 imdUsd;
        uint256 imdUnit;
        uint256 draftCount;
        PoolKey key;
        bool poolBound;
        bool entered;
        uint160 lastPricedSqrtPriceX96;
    }

    // keccak256(abi.encode(uint256(keccak256("paper.storage.Hook")) - 1)) & ~bytes32(uint256(255))
    bytes32 private constant STORAGE_SLOT = 0x3631e9ad7e7d7912113dcd85659f8cbef9bcbc6833977635953a29fcfe6f3d00;
    IPoolManager private immutable deploymentManager;

    error Unauthorized();
    error InvalidConfiguration();
    error WrongPool();
    error PoolUnavailable();
    error ReentrantCall();
    error InvalidDraft();
    error InexactTransfer();
    error AmountTooLarge();
    error PartialImdSwap();
    error InsufficientFeeBacking();
    error PostFeeExceedsLimit(uint256 required, uint256 maximum);

    event SplitChanged(address ordersWallet, uint256 ordersBps, address devWallet, uint256 devBps);
    event PostFeeUsdChanged(uint256 usd);
    event ImdUsdChanged(uint256 usdWad);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PoolBound(PoolId indexed poolId, address indexed token);
    event FeesPaid(uint256 imdFee, uint256 ordersAmount, uint256 devAmount);
    event DraftPosted(uint256 indexed draftId, address indexed author, bytes32 textHash, uint256 burned);
    event Burned(uint256 indexed draftId, address indexed voter, uint256 amount);

    constructor(IPoolManager manager) {
        if (address(manager).code.length == 0) revert InvalidConfiguration();
        deploymentManager = manager;
        _disableInitializers();
    }

    modifier onlyManager() {
        if (msg.sender != address(_state().manager)) revert Unauthorized();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != _state().owner) revert Unauthorized();
        _;
    }

    modifier nonReentrant() {
        HookStorage storage s = _state();
        if (s.entered) revert ReentrantCall();
        s.entered = true;
        _;
        s.entered = false;
    }

    /// @param usdWad USD per whole IMD, scaled by 1e18; owner maintains this fallback.
    function initialize(address token_, address owner_, uint256 usdWad) external initializer {
        if (
            !HookFlags.matches(address(this), HookFlags.ALL) || token_.code.length == 0 || token_ == IMD
                || owner_ == address(0) || usdWad == 0 || IMD.code.length == 0
        ) revert InvalidConfiguration();
        uint8 imdDecimals = IERC20Metadata(IMD).decimals();
        if (imdDecimals > 18 || IERC20Metadata(token_).decimals() != 18) revert InvalidConfiguration();
        HookStorage storage s = _state();
        s.manager = deploymentManager;
        s.token = token_;
        s.owner = owner_;
        s.launcher = msg.sender;
        s.ordersWallet = ORDERS;
        s.devWallet = DEV;
        (s.ordersBps, s.devBps) = _defaultSplit();
        s.postFeeUsd = 1;
        s.imdUsd = usdWad;
        s.imdUnit = 10 ** imdDecimals;
        emit OwnershipTransferred(address(0), owner_);
        emit SplitChanged(ORDERS, s.ordersBps, DEV, s.devBps);
        emit PostFeeUsdChanged(1);
        emit ImdUsdChanged(usdWad);
    }

    function _defaultSplit() internal pure virtual returns (uint256, uint256) {
        return (50, 150);
    }

    function getHookPermissions() external pure returns (Hooks.Permissions memory p) {
        p = Hooks.Permissions(true, true, true, true, true, true, true, true, true, true, true, true, true, true);
    }

    function feeBps() external pure returns (uint256) {
        return TOTAL_BPS;
    }

    function split() external view returns (address, uint256, address, uint256) {
        HookStorage storage s = _state();
        return (s.ordersWallet, s.ordersBps, s.devWallet, s.devBps);
    }

    function owner() external view returns (address) {
        return _state().owner;
    }

    function poolManager() external view returns (IPoolManager) {
        return _state().manager;
    }

    function token() external view returns (address) {
        return _state().token;
    }

    function poolKey() external view returns (PoolKey memory) {
        return _state().key;
    }

    function draftCount() external view returns (uint256) {
        return _state().draftCount;
    }

    function postFeeUsd() external view returns (uint256) {
        return _state().postFeeUsd;
    }

    function imdUsd() external view returns (uint256) {
        return _state().imdUsd;
    }

    function transferOwnership(address newOwner) external onlyOwner nonReentrant {
        if (newOwner == address(0)) revert InvalidConfiguration();
        HookStorage storage s = _state();
        emit OwnershipTransferred(s.owner, newOwner);
        s.owner = newOwner;
    }

    function setSplit(address ordersWallet, uint256 ordersBps, address devWallet, uint256 devBps)
        external
        onlyOwner
        nonReentrant
    {
        if (
            ordersWallet == address(0) || devWallet == address(0) || ordersWallet == address(this)
                || devWallet == address(this) || ordersWallet == address(_state().manager)
                || devWallet == address(_state().manager) || ordersBps > TOTAL_BPS || devBps > TOTAL_BPS
                || ordersBps + devBps != TOTAL_BPS
        ) revert InvalidConfiguration();
        HookStorage storage s = _state();
        s.ordersWallet = ordersWallet;
        s.devWallet = devWallet;
        s.ordersBps = ordersBps;
        s.devBps = devBps;
        emit SplitChanged(ordersWallet, ordersBps, devWallet, devBps);
    }

    /// @notice Whole USD units, initially 1. Zero allows free posts.
    function setPostFeeUsd(uint256 usd) external onlyOwner nonReentrant {
        _state().postFeeUsd = usd;
        emit PostFeeUsdChanged(usd);
    }

    function setImdUsd(uint256 usdWad) external onlyOwner nonReentrant {
        if (usdWad == 0) revert InvalidConfiguration();
        _state().imdUsd = usdWad;
        emit ImdUsdChanged(usdWad);
    }

    function postFeeTokens() public view returns (uint256) {
        HookStorage storage s = _state();
        if (!s.poolBound || s.manager.isUnlocked()) revert PoolUnavailable();
        (uint160 sqrtPrice,,,) = s.manager.getSlot0(s.key.toId());
        // Empty ranges can move slot0 without exchanging tokens. Use the launch price or the
        // last post-swap price observed with active liquidity instead of disabling posting.
        if (s.manager.getLiquidity(s.key.toId()) == 0) sqrtPrice = s.lastPricedSqrtPriceX96;
        if (sqrtPrice == 0) revert PoolUnavailable();
        uint256 imdAmount = FullMath.mulDivRoundingUp(s.postFeeUsd, s.imdUnit * 1e18, s.imdUsd);
        bool paperIs0 = Currency.unwrap(s.key.currency0) == s.token;
        if (sqrtPrice <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPrice) * sqrtPrice;
            return paperIs0
                ? FullMath.mulDivRoundingUp(imdAmount, 1 << 192, ratioX192)
                : FullMath.mulDivRoundingUp(imdAmount, ratioX192, 1 << 192);
        }
        uint256 ratioX128 = paperIs0
            ? FullMath.mulDiv(sqrtPrice, sqrtPrice, 1 << 64)
            : FullMath.mulDivRoundingUp(sqrtPrice, sqrtPrice, 1 << 64);
        return paperIs0
            ? FullMath.mulDivRoundingUp(imdAmount, 1 << 128, ratioX128)
            : FullMath.mulDivRoundingUp(imdAmount, ratioX128, 1 << 128);
    }

    /// @notice Legacy entry point without slippage protection. Prefer postDraft(textHash, maxTokens).
    function postDraft(bytes32 textHash) external nonReentrant returns (uint256 draftId) {
        return _postDraft(textHash, type(uint256).max);
    }

    /// @notice Burns the execution-time quote only if it is within the caller's approved price limit.
    /// @param maxTokens Maximum paper minor units to burn, independent of any ERC-20 allowance.
    function postDraft(bytes32 textHash, uint256 maxTokens) external nonReentrant returns (uint256 draftId) {
        return _postDraft(textHash, maxTokens);
    }

    function _postDraft(bytes32 textHash, uint256 maxTokens) private returns (uint256 draftId) {
        uint256 amount = postFeeTokens();
        if (amount > maxTokens) revert PostFeeExceedsLimit(amount, maxTokens);
        draftId = ++_state().draftCount;
        _burnFrom(msg.sender, amount);
        emit DraftPosted(draftId, msg.sender, textHash, amount);
    }

    function burn(uint256 draftId, uint256 amount) external nonReentrant {
        if (draftId == 0 || draftId > _state().draftCount) revert InvalidDraft();
        _burnFrom(msg.sender, amount);
        emit Burned(draftId, msg.sender, amount);
    }

    function _burnFrom(address from, uint256 amount) private {
        IERC20 paper = IERC20(_state().token);
        uint256 beforeBalance = paper.balanceOf(DEAD);
        paper.safeTransferFrom(from, DEAD, amount);
        if (paper.balanceOf(DEAD) - beforeBalance != amount) revert InexactTransfer();
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        onlyManager
        returns (bytes4)
    {
        HookStorage storage s = _state();
        if (s.poolBound || (sender != s.launcher && sender != s.owner)) revert Unauthorized();
        address a = Currency.unwrap(key.currency0);
        address b = Currency.unwrap(key.currency1);
        if (
            address(key.hooks) != address(this) || a >= b || !((a == IMD && b == s.token) || (a == s.token && b == IMD))
                || !(key.fee == 500 || key.fee == 3000 || key.fee == 10000) || key.tickSpacing <= 0
        ) revert WrongPool();
        s.key = key;
        s.poolBound = true;
        s.lastPricedSqrtPriceX96 = sqrtPriceX96;
        emit PoolBound(key.toId(), s.token);
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyManager
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        uint256 amount = _abs(params.amountSpecified);
        if (!_imdSpecified(key, params)) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        uint256 fee = FullMath.mulDiv(amount, TOTAL_BPS, params.amountSpecified < 0 ? BPS : BPS - TOTAL_BPS);
        _pay(fee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(_toInt128(fee), 0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyManager
        nonReentrant
        returns (bytes4, int128)
    {
        _checkPool(key);
        HookStorage storage s = _state();
        if (s.manager.getLiquidity(key.toId()) != 0) {
            (uint160 sqrtPrice,,,) = s.manager.getSlot0(key.toId());
            s.lastPricedSqrtPriceX96 = sqrtPrice;
        }
        int128 imdDelta = Currency.unwrap(key.currency0) == IMD ? delta.amount0() : delta.amount1();
        uint256 actual = _abs(int256(imdDelta));
        if (_imdSpecified(key, params)) {
            uint256 specified = _abs(params.amountSpecified);
            uint256 specifiedFee =
                FullMath.mulDiv(specified, TOTAL_BPS, params.amountSpecified < 0 ? BPS : BPS - TOTAL_BPS);
            // Pre-swap fees must never charge on an unfilled requested amount.
            uint256 expected = params.amountSpecified < 0 ? specified - specifiedFee : specified + specifiedFee;
            if (actual != expected) revert PartialImdSwap();
            return (IHooks.afterSwap.selector, 0);
        }
        // An IMD input includes the fee in its gross amount; IMD output is charged before deduction.
        uint256 fee = FullMath.mulDiv(actual, TOTAL_BPS, imdDelta < 0 ? BPS - TOTAL_BPS : BPS);
        _pay(fee);
        return (IHooks.afterSwap.selector, _toInt128(fee));
    }

    function _imdSpecified(PoolKey calldata key, SwapParams calldata params) private pure returns (bool) {
        bool imdIsInput = params.zeroForOne == (Currency.unwrap(key.currency0) == IMD);
        return (params.amountSpecified < 0) == imdIsInput;
    }

    function _pay(uint256 fee) private {
        if (fee == 0) return;
        _toInt128(fee);
        HookStorage storage s = _state();
        // Same-swap payment is mandatory: insufficient backing reverts atomically, never accumulates claims.
        if (IERC20(IMD).balanceOf(address(s.manager)) < fee) revert InsufficientFeeBacking();
        uint256 ordersAmount = FullMath.mulDiv(fee, s.ordersBps, TOTAL_BPS);
        uint256 devAmount = fee - ordersAmount;
        if (ordersAmount != 0) s.manager.take(Currency.wrap(IMD), s.ordersWallet, ordersAmount);
        if (devAmount != 0) s.manager.take(Currency.wrap(IMD), s.devWallet, devAmount);
        emit FeesPaid(fee, ordersAmount, devAmount);
    }

    function _abs(int256 value) private pure returns (uint256) {
        if (value == type(int256).min) revert AmountTooLarge();
        uint256 amount = uint256(value < 0 ? -value : value);
        if (amount > uint256(uint128(type(int128).max))) revert AmountTooLarge();
        return amount;
    }

    function _toInt128(uint256 value) private pure returns (int128) {
        if (value > uint256(uint128(type(int128).max))) revert AmountTooLarge();
        return int128(int256(value));
    }

    function _checkPool(PoolKey calldata key) private view {
        HookStorage storage s = _state();
        if (!s.poolBound || PoolId.unwrap(key.toId()) != PoolId.unwrap(s.key.toId())) revert WrongPool();
    }

    function _state() private pure returns (HookStorage storage s) {
        bytes32 slot = STORAGE_SLOT;
        assembly ("memory-safe") { s.slot := slot }
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24) external view onlyManager returns (bytes4) {
        _checkPool(key);
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyManager
        returns (bytes4)
    {
        _checkPool(key);
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyManager returns (bytes4, BalanceDelta) {
        _checkPool(key);
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyManager
        returns (bytes4)
    {
        _checkPool(key);
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyManager returns (bytes4, BalanceDelta) {
        _checkPool(key);
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeDonate(address, PoolKey calldata key, uint256, uint256, bytes calldata)
        external
        view
        onlyManager
        returns (bytes4)
    {
        _checkPool(key);
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata key, uint256, uint256, bytes calldata)
        external
        view
        onlyManager
        returns (bytes4)
    {
        _checkPool(key);
        return IHooks.afterDonate.selector;
    }
}
