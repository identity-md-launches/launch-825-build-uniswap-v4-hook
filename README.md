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
| `PaperProxy` | OpenZeppelin transparent proxy with an immutable V1/V2 runtime allowlist enforcing the permanent fee cap. Constructor takes implementation and initialization bytes. Its ProxyAdmin initial owner is the fixed dev address, with no owner argument. |
| `PaperDeployment` | Token allocation, complete proxy init-code hashing, salt mining, and atomic proxy/pool initialization. |
| `PaperSwapRouter` | Input pre-settlement, slippage limits, exact-output fulfillment, deadline, and input refunds for the initialized paper/IMD pool. Required for unbacked paper-only launches. |

The implementation initializes the proxy with `initialize(token, hookOwner, imdUsdWad)`. The application owner can change fee recipients, the split, post fee, IMD/USD value, and application ownership. Neither it nor the upgrade owner can raise the 200 bps total: the proxy accepts only the delivered V1/V2 runtime code with the original manager argument. The distinct ProxyAdmin owner starts at **0xb59eac9882Ba98f4170d99D5F402C3EDb6D50D75**, regardless of the launch wallet or application owner. OpenZeppelin ProxyAdmin permits its owner to transfer or renounce upgrade authority, which does not change the immutable implementation restrictions.

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

Both payments call `PoolManager.take` during the same swap. Positive hook return deltas exactly offset the hook's take debits. No fee balance or ERC-6909 claim accumulates in the hook. The manager must physically hold IMD when callbacks pay the fee. `PaperSwapRouter` supplies it from the trader's input before calling `swap`, so a fresh paper-only pool can execute its first buy with no donated backing. Tests cover first buys with exact input and exact output in both currency orderings. An arbitrary router that settles only after the swap still requires existing manager backing and reverts atomically without it. IMD is assumed to be a standard ERC-20 with exact transfers, stable decimals, no rebasing, and no transfer callback; confirm its production behavior before release.

Deploy `PaperSwapRouter(hook)` after pool initialization and use it for launch trading. It binds that hook's manager and pool key. The trader approves at most `maxInput` of the input token, then calls `swap(params, maxInput, minOutput, recipient, deadline)`. `maxInput` is the gross input budget including hook fees; `minOutput` is net output after fees. Set both from a reviewed quote and use a short deadline. The router pulls only from `msg.sender` into its own custody, then performs `sync -> transfer -> settle` before swapping. The authenticated, single-use unlock callback never calls `transferFrom`. Unspent input returns to the original caller and output goes to the chosen recipient. Exact-output requests must fill completely. All failures revert the pull, fees, price movement, and refunds together. Pre-existing router token balances are never swept into a refund. The router has no owner, arbitrary pool/target parameter, or withdrawal path; accidental transfers remain stranded.

## Drafts and voting

`postFeeUsd()` starts at **1**, in **whole USD units**. `setPostFeeUsd` is owner-only; zero allows free posts. Fractional USD post fees are not supported by this unit choice. `imdUsd()` is USD per whole IMD scaled by `1e18`; for example `2e18` means $2/IMD. No chain-readable IMD/USD source was supplied or agreed, so this release uses the requested owner-set fallback exclusively. Deployment must pass a reviewed, positive current value; tests use $1 only as a local fixture. The owner updates it using `setImdUsd` and events make changes observable. It has no automatic heartbeat or stale-value protection.

`postFeeTokens()` reads the bound pool's current `sqrtPriceX96` through `StateLibrary`, obtains required IMD minor units from the USD settings, then converts to paper minor units. It handles both currency orderings and queried IMD decimals up to 18; paper must have 18 decimals. Both conversion steps round upward. It rejects an unbound, uninitialized, or unlocked pool. When active liquidity is zero, it uses the launch price recorded in `beforeInitialize`, or the most recent post-swap price observed with nonzero active liquidity. This lets posting work before the first buy in a paper-only launch and after liquidity leaves the current range. Swaps through empty ranges cannot replace that saved price. The saved price is appended to the ERC-7201 state and survives the V2 upgrade. It may be stale; it is an availability fallback, not a price oracle with a freshness guarantee.

`postDraft(textHash)` takes the current quote directly from its caller to **0x000000000000000000000000000000000000dEaD**, allocates sequential IDs starting at 1, and emits `DraftPosted(draftId, author, textHash, burned)`. Failed transfers roll back the ID. `burn(draftId, amount)` transfers paper from its caller to the same dead address and emits `Burned(draftId, voter, amount)` for any existing ID, including old drafts, repeated votes, and zero amounts. SafeERC20, balance-difference validation, and a namespaced reentrancy guard protect these paths. Transfer-to-dead makes tokens inaccessible; it does not reduce ERC-20 `totalSupply`.

Use **`postDraft(bytes32 textHash, uint256 maxTokens)`** in new integrations. Set `maxTokens` to the displayed quote plus any explicitly accepted tolerance, in paper minor units. The overload reverts with `PostFeeExceedsLimit(required, maximum)` before allocating an ID or transferring tokens if the execution quote is higher. The cap works independently of the allowance shared with `burn`, including unlimited allowances; a larger cap still burns only the actual quote. A zero cap permits only a free post. The original one-argument selector is retained as the required compatibility wrapper and has **no price protection**. Existing integrations must migrate to the capped selector; merely deploying this revision does not protect a pending legacy call. Neither selector has a deadline.

An indexer counts the `DraftPosted.burned` amount as the author's votes exactly once, then adds every `Burned.amount` to that draft/voter. There is no duplicate `Burned` event for the posting fee. Indexers must handle reorgs and order events by block, transaction, and log index. Rounds, thresholds, quorum, winners, and text availability are entirely off-chain. The only draft storage is the monotonic count used for existence checks.

The requested spot price is manipulable. Blocking quotes while the manager is unlocked prevents quoting intermediate swap state, but an attacker can still move the pool price in a separate unlock or transaction and post at that price. A dust position at a distant tick also defeats any assumption that nonzero active liquidity implies a trustworthy price. Tests reproduce a change from about 0.994 paper to about 998,799 paper and verify the capped call rejects it without burning or creating votes. This contract does not promise manipulation-resistant dollar pricing. Vote weight is always the amount actually sent to dead. Use the capped selector even when an existing voting allowance is large, and approve only intended amounts where practical. Unlimited approvals remain especially unsafe with the legacy selector.

## Deployment and responsibilities

No transactions were broadcast. No mainnet fork or live token identity verification is claimed: the attempted public mainnet RPC read returned HTTP 403. Obtain and verify the chain's PoolManager from the launch infrastructure; there is no hardcoded PoolManager in contracts or deployment tooling. [docs/deployment-parameters.json](docs/deployment-parameters.json) lists the defaults and values the deployer must supply.

1. Deploy `PaperDeployment`. Its `deployToken()` constructs Paper with no constructor arguments, then transfers 800,000,000 paper (8000 bps) to the caller as liquidity custodian and 200,000,000 to the fixed dev wallet. If the network's own launch factory handles allocation, deploy `Paper` directly there instead; do not apply the split twice.
2. Deploy `PaperHook(IPoolManager)` using the verified target manager. The token must have code before proxy initialization.
3. Choose `Config`: actual manager, actual paper token, initial application owner, reviewed `imdUsdWad`, initial `sqrtPriceX96`, LP fee **3000**, tick spacing **60**. Policy fee tiers 500, 3000, and 10000 are accepted; spacing must be positive and within PoolManager bounds. Sort currencies by address. `sqrtPriceX96 = sqrt(currency1 minor units / currency0 minor units) * 2^96`; account for token decimals when translating a human price.
4. Call `proxyInitCode(implementation, config)` as a read, hash the complete result, and mine for the actual **PaperDeployment address**, not the implementation or a generic CREATE2 deployer. Use `mine(deployerAddress, hash, start, attempts)` as a read (maximum 200,000 attempts per range), or the local `MineSalt` script. Try another disjoint range if the first finds nothing. Changing token, owner, IMD/USD initialization, implementation, compiler/settings, or proxy creation code changes the hash and requires mining again.
5. The configured application owner calls `deployHook(salt, implementation, config)`. This caller restriction prevents a stranger from using the same mined proxy constructor with an altered pool price. Proxy creation, application initialization, and pool initialization occur in one transaction. Invalid flags, token, manager, pool parameters, initialization, or duplicate salts revert. The proxy's launcher is this helper; pool initialization is allowed from it or the application owner, then rebinding is prohibited.
6. The liquidity custodian uses a reviewed production PositionManager/router to seed the 80% allocation with approved ticks and slippage limits. Deploy `PaperSwapRouter(hook)` and configure the trading integration to use it, especially for paper-only liquidity; ordinary settle-after-swap routers need sufficient existing IMD backing. This helper allocates the token share and initializes the pool; it does **not** create LP positions or lock LP ownership. Choose position ranges, required IMD funding, minimum amounts, and LP custody at launch review. Verify the supplied token, pool price, pool ID, manager, proxy flags, all permissions, application owner, both splits, and ERC-1967 ProxyAdmin owner before opening trading.
7. The deployer verifies sources and bytecode. The application owner maintains IMD/USD and fee settings. The upgrade owner reviews each implementation and storage layout; the indexer operates voting rounds. Monitor upgrades, ProxyAdmin ownership, split changes, pricing changes, fee-payment failures, liquidity, and events.

Local mining uses no environment or network:

```sh
forge script script/MineSalt.s.sol:MineSalt --sig 'run(address,bytes32,uint256,uint256)' <helper-address> <complete-init-code-hash> 0 200000
```

For the rehearsal, deploy `PaperHookV2` with the same manager constructor argument. Read the proxy's ERC-1967 admin slot and confirm its `ProxyAdmin.owner()` is the fixed dev wallet. That owner calls `ProxyAdmin.upgradeAndCall(proxy, v2, "")`; never call `initialize` again. The existing configured split, owner, manager, pool, USD settings, and draft count stay intact. A fresh V2 proxy gets reversed defaults. V2 is not the launch implementation.

## Requirement conflicts that need review

The supplied `Hook.protected.t.sol` runtime scanner categorically rejects `DELEGATECALL`. Every functioning TransparentUpgradeableProxy delegates to its implementation, so the requested proxy necessarily fails that admission test. It is implemented as requested; the pinned file has not been edited or its prohibition evaded. The admission policy must explicitly permit the reviewed transparent proxy to admit this design. Launch remains blocked pending that decision.

The reviewed manifest proof was reproduced: a bare `PaperHook(manager)` cannot initialize a pool because its implementation initializer is deliberately disabled and its application storage is unset. **Do not name `PaperHook` as the deployed hook in a launch manifest.** The hook is the initialized `PaperProxy` created by `PaperDeployment.deployHook`; the helper is exercised directly by the tests. There is no `launch.json` in this revision's starting tree. The supplied proof's assumed manifest/deployer schema cannot represent this proxy deployment. Its generator must support the implementation, proxy initializer bytes, atomic pool initialization, and an explicit proxy admission exception before launch. `docs/deployment-parameters.json` describes the actual artifacts and is not a substitute for approval of that schema.

The permanent fee cap takes precedence over unrestricted future upgrades. The proxy now pins the normalized compiled runtime hashes of the delivered V1 and V2 and separately preserves the constructor's manager value. Validation runs before initial delegation and before each upgrade; merely reporting `feeBps() == 200` grants no authority. The allowlist is part of immutable proxy code and has no setter. The V1/V2 rehearsal remains supported, but introducing new behavior or activating additional callbacks requires a new deployment and review. All fourteen address flags remain set. This restriction resolves the demonstrated fee-cap bypass; it deliberately does not promise arbitrary future implementations at the same address.

To reproduce the allowlist, build with the pinned settings, read each implementation artifact's `deployedBytecode.object`, and hash its bytes with Keccak-256 with the compiler's immutable placeholders zeroed. Each `deployedBytecode.immutableReferences` currently identifies only `deploymentManager`, at byte offset 2140 with length 32. These values must match `PaperProxy`'s two hash constants and offset, regenerated for this pre-launch voting revision. Any future executable source/compiler change requires regenerating and reviewing these constants for a new deployment; it cannot change an existing proxy's permitted code. Canonical deployment and upgrade tests fail if the constants become stale. This build is not an upgrade path for a proxy already deployed with older immutable hashes.

The first-buy reviewer proof was reproduced, but its fixed router transfers input only after both fee callbacks have completed. It provides no hook allowance, hook data, or other IMD source while requiring immediate payment from a zero-IMD manager. That exact funding order cannot satisfy same-swap physical payouts. The delivered pre-settlement integration resolves launch availability; the unchanged settle-after proof is disputed on this specific premise, not represented as passing. Findings and responses are recorded in `.imd-responses.json`.

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
