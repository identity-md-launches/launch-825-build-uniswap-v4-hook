# paper / IMD

Foundry project for a fixed-supply `paper` token and an upgradeable Uniswap v4 hook on Ethereum mainnet. Solidity is pinned to **0.8.26**, the EVM target is Cancun, and `bytecode_hash = "none"`. All Solidity dependencies and their licenses are ordinary files under `lib/`; no network install, submodule, FFI, filesystem cheatcode, environment variable, RPC, or key is needed by the tests.

```sh
forge build
forge test
forge fmt --check
```

The tests deploy a real `PoolManager`, mine real CREATE2 proxies, and execute unlock/settlement. They cover both currency orderings, all four swap modes, split changes and rounding, partial fills, a fresh pool funded only with paper, voting, hostile token behavior, callback access, upgrades, and stateful accounting invariants. The separate adversarial review is in [docs/ADVERSARIAL_REVIEW.md](docs/ADVERSARIAL_REVIEW.md).

## Contracts and ownership

| Contract | Purpose |
| --- | --- |
| `Paper` | ERC-20 named and symbolized `paper`, 18 decimals, exactly 1 billion tokens minted to the constructor caller. No further mint, pause, tax, owner, or upgrade path. |
| `PaperHook` | V1 fee and voting implementation. Constructor receives the chain's `IPoolManager` and disables implementation initialization. |
| `PaperHookV2` | Upgrade rehearsal only; changes fresh-proxy split defaults to 150 orders / 50 dev bps. Upgrading an existing proxy preserves its split. |
| `PaperProxy` | OpenZeppelin transparent proxy; constructor takes implementation and initialization bytes. Its ProxyAdmin initial owner is the fixed dev address, with no owner argument. |
| `PaperDeployment` | Token allocation, complete proxy init-code hashing, salt mining, and atomic proxy/pool initialization. |

The implementation initializes the proxy with `initialize(token, hookOwner, imdUsdWad)`. The application owner can change fee recipients, the split, post fee, IMD/USD value, and application ownership. It cannot change the 200 bps total in either delivered implementation. The distinct ProxyAdmin owner starts at **0xb59eac9882Ba98f4170d99D5F402C3EDb6D50D75**, regardless of the launch wallet or application owner. OpenZeppelin ProxyAdmin permits its owner to transfer or renounce upgrade authority.

The proxy address must satisfy `uint160(address) & 0x3fff == 0x3fff`. All fourteen permissions are reported as enabled. Initialization binds one paper/IMD pool; every callback verifies the stored PoolManager and pool. Liquidity, donation, and after-initialization callbacks return their selectors and zero deltas without modifying economics. Swap callbacks never override the LP fee. Arbitrary `hookData` and the router's `sender` cannot redirect fees or claim votes, so no router identity allowlist is required.

All mutable application state uses ERC-7201 namespace `paper.storage.Hook`, rooted at `0x3631e9ad7e7d7912113dcd85659f8cbef9bcbc6833977635953a29fcfe6f3d00`. OpenZeppelin `Initializable` uses its separate ERC-7201 namespace. Only the transparent proxy uses the standard ERC-1967 implementation/admin slots. The initialized manager is stored in the namespace and remains unchanged through upgrades. Keep the struct order/types and initialization namespace unchanged; append new fields or use another namespace for new state.

## Swap fee definition

IMD is fixed to **0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7**. Every successful swap pays `floor(gross IMD leg * 200 / 10000)` in IMD. For a buy, gross means the trader's IMD debit including the hook fee. For a sell, gross means the pool's IMD output before the hook fee is deducted. This convention gives exactly 2% of the gross leg in every mode, subject to integer rounding, separately from the pool's LP fee.

| Swap | Fee callback | Arithmetic |
| --- | --- | --- |
| Exact-input IMD buy, gross budget `G` | `beforeSwap`, specified delta | Fee `floor(G / 50)`; AMM receives `G - fee`. |
| Exact-output IMD sell, net target `N` | `beforeSwap`, specified delta | Fee `floor(N / 49)`; AMM outputs `N + fee`; trader receives `N`. |
| Exact-input paper sell, gross IMD output `G` | `afterSwap`, unspecified delta | Fee `floor(G / 50)`; trader receives `G - fee`. |
| Exact-output paper buy, AMM IMD cost `C` | `afterSwap`, unspecified delta | Fee `floor(C / 49)`; trader pays `C + fee`. |

`beforeSwap` takes a positive specified delta only for IMD-specified swaps. `afterSwap` verifies their complete execution; a price-limit partial fill reverts with `PartialImdSwap`, rolling back fees and price changes. For paper-specified swaps, fees use the actual AMM delta, so partial fills remain possible. Normal router exact-output and minimum-output checks remain the router's responsibility. The test router is a settlement harness, not a production router.

Defaults: 50 bps to orders **0x721F8232e19c92516eB753FEF53d8A33a3637989**, 150 bps to dev **0xb59eac9882Ba98f4170d99D5F402C3EDb6D50D75**. `setSplit(ordersWallet, ordersBps, devWallet, devBps)` requires application ownership and a total of 200. Zero shares and identical external recipients are supported. Zero-address, proxy, and PoolManager recipients are rejected. Orders receives `floor(totalFee * ordersBps / 200)`; dev receives the remainder, conserving every minor unit. A tiny swap can round the total fee to zero.

Both payments call `PoolManager.take` during the same swap. Positive hook return deltas exactly offset the hook's take debits; the router settles the caller's final delta. No fee balance or ERC-6909 claim accumulates in the hook. The manager must already have enough physical IMD when callbacks pay the fee. Insufficient backing reverts atomically. A fresh pool seeded only with paper therefore needs IMD backing or a router that pre-settles IMD input before swapping. The tests demonstrate failure without backing and success after backing the fee. Seed both currencies for the default launch. IMD is assumed to be a standard ERC-20 with exact transfers, stable decimals, no rebasing, and no transfer callback; confirm its production behavior before release.

## Drafts and voting

`postFeeUsd()` starts at **1**, in **whole USD units**. `setPostFeeUsd` is owner-only; zero allows free posts. Fractional USD post fees are not supported by this unit choice. `imdUsd()` is USD per whole IMD scaled by `1e18`; for example `2e18` means $2/IMD. No chain-readable IMD/USD source was supplied or agreed, so this release uses the requested owner-set fallback exclusively. Deployment must pass a reviewed, positive current value; tests use $1 only as a local fixture. The owner updates it using `setImdUsd` and events make changes observable. It has no automatic heartbeat or stale-value protection.

`postFeeTokens()` reads the bound pool's current `sqrtPriceX96` through `StateLibrary`, obtains required IMD minor units from the USD settings, then converts to paper minor units. It handles both currency orderings and queried IMD decimals up to 18; paper must have 18 decimals. Both conversion steps round upward. It rejects an unbound, uninitialized, zero-active-liquidity, or unlocked pool.

`postDraft(textHash)` takes the current quote directly from its caller to **0x000000000000000000000000000000000000dEaD**, allocates sequential IDs starting at 1, and emits `DraftPosted(draftId, author, textHash, burned)`. Failed transfers roll back the ID. `burn(draftId, amount)` transfers paper from its caller to the same dead address and emits `Burned(draftId, voter, amount)` for any existing ID, including old drafts, repeated votes, and zero amounts. SafeERC20, balance-difference validation, and a namespaced reentrancy guard protect these paths. Transfer-to-dead makes tokens inaccessible; it does not reduce ERC-20 `totalSupply`.

An indexer counts the `DraftPosted.burned` amount as the author's votes exactly once, then adds every `Burned.amount` to that draft/voter. There is no duplicate `Burned` event for the posting fee. Indexers must handle reorgs and order events by block, transaction, and log index. Rounds, thresholds, quorum, winners, and text availability are entirely off-chain. The only draft storage is the monotonic count used for existence checks.

The requested spot price is manipulable. Blocking quotes while the manager is unlocked prevents quoting intermediate swap state, but an attacker can still move the pool price in a separate unlock or transaction and post at that price. This contract does not promise manipulation-resistant dollar pricing. Vote weight is always the amount actually sent to dead. Users should approve only the intended post/burn amount; a price or administrative change then makes an overly expensive post revert for insufficient allowance. An unlimited approval exposes the user's approved tokens to price changes and upgrade authority.

## Deployment and responsibilities

No transactions were broadcast. No mainnet fork or live token identity verification is claimed: the attempted public mainnet RPC read returned HTTP 403. Obtain and verify the chain's PoolManager from the launch infrastructure; there is no hardcoded PoolManager in contracts or deployment tooling. [docs/deployment-parameters.json](docs/deployment-parameters.json) lists the defaults and values the deployer must supply.

1. Deploy `PaperDeployment`. Its `deployToken()` constructs Paper with no constructor arguments, then transfers 800,000,000 paper (8000 bps) to the caller as liquidity custodian and 200,000,000 to the fixed dev wallet. If the network's own launch factory handles allocation, deploy `Paper` directly there instead; do not apply the split twice.
2. Deploy `PaperHook(IPoolManager)` using the verified target manager. The token must have code before proxy initialization.
3. Choose `Config`: actual manager, actual paper token, initial application owner, reviewed `imdUsdWad`, initial `sqrtPriceX96`, LP fee **3000**, tick spacing **60**. Policy fee tiers 500, 3000, and 10000 are accepted; spacing must be positive and within PoolManager bounds. Sort currencies by address. `sqrtPriceX96 = sqrt(currency1 minor units / currency0 minor units) * 2^96`; account for token decimals when translating a human price.
4. Call `proxyInitCode(implementation, config)` as a read, hash the complete result, and mine for the actual **PaperDeployment address**, not the implementation or a generic CREATE2 deployer. Use `mine(deployerAddress, hash, start, attempts)` as a read (maximum 200,000 attempts per range), or the local `MineSalt` script. Try another disjoint range if the first finds nothing. Changing token, owner, IMD/USD initialization, implementation, compiler/settings, or proxy creation code changes the hash and requires mining again.
5. The configured application owner calls `deployHook(salt, implementation, config)`. This caller restriction prevents a stranger from using the same mined proxy constructor with an altered pool price. Proxy creation, application initialization, and pool initialization occur in one transaction. Invalid flags, token, manager, pool parameters, initialization, or duplicate salts revert. The proxy's launcher is this helper; pool initialization is allowed from it or the application owner, then rebinding is prohibited.
6. The liquidity custodian uses a reviewed production PositionManager/router to seed the 80% allocation with sufficient IMD, approved ticks, and slippage limits. This helper allocates the token share and initializes the pool; it does **not** create LP positions or lock LP ownership. Choose position ranges, required IMD funding, minimum amounts, and LP custody at launch review. Verify the supplied token, pool price, pool ID, manager, proxy flags, all permissions, application owner, both splits, and ERC-1967 ProxyAdmin owner before opening trading.
7. The deployer verifies sources and bytecode. The application owner maintains IMD/USD and fee settings. The upgrade owner reviews each implementation and storage layout; the indexer operates voting rounds. Monitor upgrades, ProxyAdmin ownership, split changes, pricing changes, fee-payment failures, liquidity, and events.

Local mining uses no environment or network:

```sh
forge script script/MineSalt.s.sol:MineSalt --sig 'run(address,bytes32,uint256,uint256)' <helper-address> <complete-init-code-hash> 0 200000
```

For the rehearsal, deploy `PaperHookV2` with the same manager constructor argument. Read the proxy's ERC-1967 admin slot and confirm its `ProxyAdmin.owner()` is the fixed dev wallet. That owner calls `ProxyAdmin.upgradeAndCall(proxy, v2, "")`; never call `initialize` again. The existing configured split, owner, manager, pool, USD settings, and draft count stay intact. A fresh V2 proxy gets reversed defaults. V2 is not the launch implementation.

## Requirement conflicts that need review

The supplied `Hook.protected.t.sol` runtime scanner categorically rejects `DELEGATECALL`. Every functioning TransparentUpgradeableProxy delegates to its implementation, so the requested proxy necessarily fails that admission test. It is implemented as requested; the pinned file has not been edited or its prohibition evaded. The admission policy must explicitly permit the reviewed transparent proxy to admit this design.

The fee is constant in V1 and V2 and cannot be raised by `setSplit` or another application setting. However, unrestricted transparent upgrade authority can replace all implementation behavior, including fees. A permanent guarantee that *nothing*, including arbitrary future upgrades, can raise fees is incompatible with that authority. All fourteen bits likewise permit future implementations to return liquidity or swap deltas with new behavior. Preserving the 2% invariant across future upgrades is a trust and review responsibility of the fixed ProxyAdmin owner; these contracts cannot enforce it against malicious replacement code.

These conflicts, spot-price manipulation, launch funding, and live-address verification must be resolved or accepted at independent review. Local tests and the included self-review are not a separate contributor's production security audit.

## Hook configuration record

This is a direct implementation of the v4 IHooks interface with BaseHook-equivalent caller checks. It uses no share token, pause, LP fee override, or transient hook scratch state. FullMath supplies overflow-resistant arithmetic, a checked int128 conversion guards return deltas, and direct manager takes implement settlement.

```json
{
  "hook": "BaseHook",
  "name": "PaperHook",
  "pausable": false,
  "currencySettler": true,
  "safeCast": true,
  "transientStorage": false,
  "shares": { "options": false },
  "permissions": {
    "beforeInitialize": true,
    "afterInitialize": true,
    "beforeAddLiquidity": true,
    "afterAddLiquidity": true,
    "beforeRemoveLiquidity": true,
    "afterRemoveLiquidity": true,
    "beforeSwap": true,
    "afterSwap": true,
    "beforeDonate": true,
    "afterDonate": true,
    "beforeSwapReturnDelta": true,
    "afterSwapReturnDelta": true,
    "afterAddLiquidityReturnDelta": true,
    "afterRemoveLiquidityReturnDelta": true
  },
  "inputs": {},
  "access": "ownable",
  "info": { "license": "MIT" }
}
```

Pinned upstream versions are recorded in [docs/dependencies.json](docs/dependencies.json): [Uniswap v4-core](https://github.com/Uniswap/v4-core), [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts), [forge-std](https://github.com/foundry-rs/forge-std), and the v4-core-pinned Solmate ownership dependency. Project code is MIT; vendored files retain their own SPDX/license terms, including v4-core's BUSL and MIT files.
