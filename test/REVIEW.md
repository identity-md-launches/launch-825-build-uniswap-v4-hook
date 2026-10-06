# Contributor test review

This contribution extends the accepted tests without changing contracts or configuration. All integrations run offline against the vendored, real Uniswap v4 PoolManager and mined transparent proxies. IMD is represented by a local ERC-20 at the specified address. No fork or live IMD behavior verification is claimed.

## Added coverage

- `FailureAtomicity.t.sol`: settlement failures after fee payment in all four swap modes; exact revert selectors; rollback of balances, pool price, allowance, and token callback state; recovery after failure; invalid split integers and recipients; wrong-pool rejection in every bound callback; signed amount limits. Both currency orderings run each case.
- `VotingProperties.t.sol`: independently checked quote rounding inequalities; exact attribution and counting of draft/burn events across users and repeated text hashes; exact-allowance protection after a price change; voting after liquidity removal; maximum burn failure and recovery; independent hook/upgrade ownership; actual fresh-V2 payments in both directions.
- `StatefulReview.t.sol`: three funded users interleave all four swap modes, recipient/share changes (including coincident recipients and zero shares), USD setting changes, posts, votes against earlier drafts, rejected calls, and repeated V1/V2 upgrades. Ghost accounting compares every recipient's payments with the physical IMD leg, every burned token with the dead balance, and tracked holdings with both total supplies. It also checks all occupied hook namespace slots across upgrades, continued pool binding, zero hook balances/claims, and fully settled manager deltas.
- Revision additions to `Upgrade.t.sol`: 1,000 mutations across the complete V1/V2 runtime outside the manager immutable must fail both initial deployment and upgrade before delegation. Separate tests reject dirty address padding in the normalized immutable and appended runtime bytes, and confirm the old implementation and application state remain intact.
- Revision additions to `Router.t.sol`: a short transfer from the router to the manager, a refused refund, and a refused output after the refund each roll back balances, allowance, supply, fees and pool price. A successful retry checks that failed calls do not poison the router guard or callback state. Both currency orderings run each case.
- `RouterStateful.t.sol`: three users exercise the production prepaying router across all four swap modes, surplus budgets, output recipients distinct from the payer, failed minimum-output checks, residual deposits, split changes, and V1/V2 upgrades. Independent account ledgers check each user's input, output and refund; fees use gross IMD movement; unsolicited deposits must remain untouched. Both token orderings check supply conservation and settlement after every sequence.

Contributor fuzz properties use 1,000 runs. Each contributor invariant runs 256 sequences of 64 calls with unexpected reverts treated as failures. These settings are in both concrete test contracts, including the reverse-order variants, because inherited inline configuration does not automatically apply. Setup exercises each handler action before random calls to avoid vacuous invariants. The original accepted unit and invariant coverage remains in place.

## Findings requiring resolution

The machine-readable report is `.imd-findings.json` at repository root, as requested by the assignment. It retains the unresolved admission conflict with a self-contained Foundry proof, written under `test/scratch/` and observed failing with `forge test --match-path` on this revision. Its source is embedded in the report and excluded from the passing suite. No failing assertion was changed to bless the observed behavior.

| Prior severity | Finding | Revision status |
| --- | --- | --- |
| High | Unrestricted transparent upgrades bypassed the permanent fee cap. | Resolved for the delivered proxy: immutable runtime hashes admit only canonical V1/V2 using the original manager. Mutation tests reject altered code at constructor and upgrade boundaries. Canonical upgrades preserve state and continue charging 2%. |
| Medium | Fresh paper-only liquidity could not fund the first buy with settlement after swap. | Addressed through `PaperSwapRouter`: existing first-buy tests pay both wallets from prepaid input on a manager starting with zero IMD, for exact-input and exact-output buys in both currency orderings. The new invariants cover its custody and refunds. Ordinary routers that settle afterwards still require manager backing; launch integration must use pre-settlement. |
| Info | The required proxy conflicts with the pinned immutable-runtime admission rule. | Unresolved. The pinned PUSH-aware scanner still finds executable `DELEGATECALL` in the actual mined proxy. |

No new high or medium implementation defect was reproduced in this targeted revision. The backing-revert regression remains evidence of atomic refusal; the production-router first-buy tests separately establish trading with token-only liquidity. The immutable whitelist deliberately limits this address to V1/V2, even though all fourteen callback flags are present. Later implementations beyond those two cannot be installed. Resolve the admission conflict and confirm this restricted upgrade policy at review.

Spot-price manipulation and owner-maintained USD pricing remain outside what passing local tests can guarantee. Spot pricing and the owner-set USD fallback are explicit requirements, so this contribution does not reinterpret them as oracle guarantees. The revised proxy refuses arbitrary future implementation code instead of relying on fee getters or the upgrade owner's restraint.

## Reproduction

Final local verification: `forge build` succeeded with existing lint warnings. `forge test` passed 159 tests across 18 suites, with zero failures or skips. The two new router invariants executed 32,768 random handler calls with zero unexpected reverts, in addition to the retained invariants. The runtime-whitelist property ran 1,000 inputs. Artifact and cache paths were directed to `test/scratch/` using `--out test/scratch/out --cache-path test/scratch/cache`; no compiler or test settings were overridden. The intentionally failing admission proof is separate from this passing suite.

Run `forge build` and `forge test` for the submitted suite. To reproduce a finding, save its `proof` field to a `.t.sol` file under `test/scratch/` and run `forge test --match-path` on that file. Remove that temporary failing test before rerunning the passing suite. The verifier deletes scratch automatically.

No dependencies were installed. No network access, environment mutation cheatcodes, FFI, or skipped tests are required. A mainnet fork rehearsal against verified IMD and PoolManager deployments is still owed before release.
