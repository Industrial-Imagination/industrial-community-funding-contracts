# Backup recovery and mint preflight verification

Implemented a separate non-upgradeable FundingRecovery helper, bound to the governed collection. Before mint starts, the owner nominates a distinct backup and the backup accepts from its own wallet. The backup requests recovery, waits seven days and executes. The owner can cancel until execution, even after the deadline. Retrying requires a fresh seven-day wait.

Every completed ownership transfer increments a collection ownership epoch. This invalidates prior backup authority even when ownership later returns to the original wallet. Recovery clears the upstream pending ordinary ownership nominee, preventing a stale handover from taking over afterward. The backup is invalidated by successful recovery as well. After minting starts no new backup can be registered: this protection is single-use for that ownership tenure.

The helper has no payable entry points, fund custody, arbitrary execution, or ability to approve payments. Recovery does not alter holder voting, upfront economics, installment authorization, terminal exit state, the voting-owner snapshot, or an already recorded wind-down beneficiary. A malicious current owner key can cancel recovery; a malicious backup can take ownership if cancellation does not occur. Watch RecoveryRequested events externally.

## Checks

- Four new recovery tests cover consent, authorization, the exact deadline, cancellation after maturity, full-delay retry, normal handover invalidation including return to the original owner, stale ordinary nominee rejection, unchanged funds, unchanged voting snapshot, and inability to bypass monthly claims.
- Full Foundry run passed: 99 test executions (71 distinct tests; the recovery fixture inherits and repeats 28 governance tests). All fuzz functions ran 2,048 cases.
- Five JavaScript checks, Node syntax checks, and Solidity formatting passed.
- Governed runtime: 24,253 bytes; 323 bytes below EIP-170. Creation bytecode: 42,995 bytes before arguments. FundingRecovery runtime: 2,281 bytes.
- Positive mint preflight against a local Base Sepolia fork at source block 56,342,347 passed for quantities 1 and 2, gross price 100003 wei, 333-bps fee, and exact aggregate net receipt of 290019 wei. Backup nomination and acceptance were also rehearsed.
- Negative preflight used the ETHFS registry as a deliberately incompatible fee recipient, solely on a disposable fork. SeaDrop reverted with ETH_TRANSFER_FAILED during estimation. The preflight returned failure; no public write was performed.

See [raw test results](recovery/contract-tests.log), [size checks](recovery/build-sizes.log), [successful preflight](mint-preflight.json), and [rejection evidence](recovery/preflight-rejection.log). No public-network transactions were sent. Prior full-lifecycle fork reports describe earlier builds, not this recovery build.

## Deployment behavior

The testnet wrapper now requires BACKUP_WALLET, runs the local mint preflight before public uploads, and rejects a failed rehearsal. After public deployment it nominates the backup and intentionally stops before enabling mint. The backup must sign acceptBackup() on the printed helper address. Rerunning with the same settings resumes only after acceptance. No backup private key is requested by the wrapper.

Direct/manual deployments may omit backup designation; the Solidity mint entry point itself does not require it. The one-command wrapper requires acceptance to avoid accidentally opening its sale without the requested recovery protection.

Preflight uses the intended configuration and actual canonical SeaDrop and fee-recipient code at a recorded source block, but a newly deployed disposable collection address. It does not prove future recipient availability, collection-address-dependent policies, live OpenSea onboarding, or production gas/provider behavior. It currently supports Base Sepolia; public Base mainnet deployment remains disabled.

A new collection deployment is required; existing contracts cannot acquire these features. See the updated governance and release guides for wallet calls and operator steps.
