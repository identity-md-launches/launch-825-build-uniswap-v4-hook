# Contributor test review

This contribution extends the accepted tests without changing contracts or configuration. All integrations run offline against the vendored, real Uniswap v4 PoolManager and mined transparent proxies. IMD is represented by a local ERC-20 at the specified address. No fork or live IMD behavior verification is claimed.

## Added coverage

- `FailureAtomicity.t.sol`: settlement failures after fee payment in all four swap modes; exact revert selectors; rollback of balances, pool price, allowance, and token callback state; recovery after failure; invalid split integers and recipients; wrong-pool rejection in every bound callback; signed amount limits. Both currency orderings run each case.
- `VotingProperties.t.sol`: independently checked quote rounding inequalities; exact attribution and counting of draft/burn events across users and repeated text hashes; exact-allowance protection after a price change; voting after liquidity removal; maximum burn failure and recovery; independent hook/upgrade ownership; actual fresh-V2 payments in both directions.
- `StatefulReview.t.sol`: three funded users interleave all four swap modes, recipient/share changes (including coincident recipients and zero shares), USD setting changes, posts, votes against earlier drafts, rejected calls, and repeated V1/V2 upgrades. Ghost accounting compares every recipient's payments with the physical IMD leg, every burned token with the dead balance, and tracked holdings with both total supplies. It also checks all occupied hook namespace slots across upgrades, continued pool binding, zero hook balances/claims, and fully settled manager deltas.

New fuzz properties use 1,000 runs. Each new invariant runs 256 sequences of 64 calls with unexpected reverts treated as failures. These settings are in both concrete test contracts, including the reverse-order variants, because inherited inline configuration does not automatically apply. Setup exercises each handler action before random calls to avoid vacuous invariants.

## Findings requiring resolution

The machine-readable report is `.imd-findings.json` at repository root, as requested by the assignment. It contains full self-contained Foundry proofs; each was written under `test/scratch/` and run with `forge test --match-path` before inclusion. They intentionally failed. No failing assertion was changed to bless the observed behavior.

| Severity | Finding | Concrete observed result |
| --- | --- | --- |
| High | Unrestricted transparent upgrades bypass the permanent fee cap. This requires the legitimate DEV upgrade authority, not an unauthorized caller. | A replacement retains the original state/getters but pays 10 IMD on a 100 IMD buy instead of 2 IMD. |
| Medium | Fresh paper-only liquidity cannot support the first buy using ordinary settlement after swap. | A funded 100 IMD buy reverts in `beforeSwap` with `InsufficientFeeBacking`; manager IMD balance is zero before input settlement. |
| Info | The required proxy conflicts with the pinned immutable-runtime admission rule. | The pinned PUSH-aware scanner finds executable `DELEGATECALL` in the actual mined proxy. |

These limitations were acknowledged in the implementation's documentation; the new proofs independently reproduce them. The existing backing-revert regression is evidence of atomic refusal, not evidence that token-only launch trading works. Resolve launch backing/pre-settlement while retaining same-swap payouts, and resolve the fee-cap and admission-policy conflicts explicitly.

Spot-price manipulation, owner-maintained USD pricing, and privileged future implementation changes remain outside what passing local tests can guarantee. Spot pricing and the owner-set USD fallback are explicit requirements, so this contribution does not reinterpret them as oracle guarantees. The invariants constrain the delivered V1/V2 behavior; they cannot constrain arbitrary future implementation code.

## Reproduction

Final local verification: `forge build` succeeded with existing source lint warnings. `forge test` passed 110 tests across 14 suites, with zero failures or skips. The two added invariants executed 32,768 random handler calls with zero unexpected reverts, in addition to the original invariant. The three intentionally failing finding proofs are separate from this passing suite.

Run `forge build` and `forge test` for the submitted suite. To reproduce a finding, save its `proof` field to a `.t.sol` file under `test/scratch/` and run `forge test --match-path` on that file. Remove that temporary failing test before rerunning the passing suite. The verifier deletes scratch automatically.

No dependencies were installed. No network access, environment mutation cheatcodes, FFI, or skipped tests are required. A mainnet fork rehearsal against verified IMD and PoolManager deployments is still owed before release.
