> Subsequent change: backup recovery and local-fork mint preflight are now implemented. See [RECOVERY-VERIFICATION.md](RECOVERY-VERIFICATION.md). Earlier build measurements and remaining-risk descriptions below are historical.

> Subsequent approved rule change: below-quorum turnout now permits the seven-day isolated installment fallback. The original review below describes the earlier zero-vote-only rule. See [the update verification](BELOW-QUORUM-VERIFICATION.md) for the changed policy and current checks.

# Contract and SeaDrop security review — November 8, 2026

## Result and scope

Reviewed all nine first-party Solidity files, the empty script scaffold, the deployment/allowlist tooling, CI, generated playback packaging, and the relevant inherited SeaDrop, ERC721A, ownership, transfer and ETHFS paths. Fixed one reproduced payment-checkpoint bug, hardened arithmetic bounds, fixed preview-mint receipt parsing, and added release/dependency verification. No unauthorized fund-withdrawal exploit was demonstrated in this review. That is a testing result, not a guarantee of safety or an independent external audit.

The approved upfront percentage and ordinary mint economics are unchanged. The only accepted-constructor-input change rejects impractically large values that could otherwise overflow later. Existing deployed contracts are non-upgradeable and do not receive these fixes. A new deployment is required.

The initial 43 tests passed despite the checkpoint bug. The final suite has 66 passing Solidity tests, including five fuzz tests at 2,048 runs each (10,240 cases), and five passing JavaScript checks. Nineteen adversarial tests also pass against each canonical deployment on local Base and Base Sepolia forks. A complete Anvil/ETHFS/SeaDrop lifecycle rehearsal passed. No public-network transactions were sent.

Evidence and source hashes: [review-results.json](security-review-2026-11-08/review-results.json). Raw logs are in [security-review-2026-11-08](security-review-2026-11-08/).

## Reference documents and method

- Supplied [SeaDrop overview](/Users/matheus/Downloads/seadrop.md): constructor inheritance, authorized SeaDrop address, and custom-collection integration guidance. Cross-checked with [OpenSea's published overview](https://docs.opensea.io/docs/seadrop).
- Supplied [Solidity reference](/Users/matheus/Downloads/docs-soliditylang-org-en-v0.8.38.pdf): chapter 3.24, printed pages 275–282 / PDF pages 279–286, covering reentrancy, gas limits, ETH handling, authorization, checked arithmetic, modularity and fail-safes. Also reviewed chapter 3.25's compiler-bug list, ABI encoding, and the applicable call/inheritance behavior. The supplied PDF labels itself `0.8.38-develop`; the compiler actually used is stable `0.8.38+commit.1835d247`.
- Installed SeaDrop is the `math77/seadrop` fork at `d098c56402af44c850cfb93b06441a835f232936`, not an unmodified assertion about every current OpenSea repository file. Reviewed the imported implementation and tested canonical deployed bytecode independently.
- ETHFS is pinned at `31e9951be70eee9de985bfdc9fa5d1848bf8f2c2`; Solady at `acd959aa4bd04720d640bf4e6a5c71037510cc4b`; forge-std at `f3dae6e6ee381f25eb6a246f7da9b85c91a68219`.

Method: clean compilation and import resolution; manual state-transition and authorization review; algebraic bounds and conservation checks; targeted failing regression; adversarial callbacks; independent installment-ledger fuzzing; Forge static lint with finding-by-finding triage; canonical-network local forks; end-to-end local transactions and actual metadata reconstruction. This is not a line-by-line independent audit of every unused vendored contract, a symbolic-execution campaign, or an unbounded stateful invariant proof.

## Findings and fixes

### F-01 — Medium: repeated silence claims skipped unpaid principal

**Location:** `FundingCouncil._payment()` / `authorizeClaim()`.

A previously paid silent cycle returned a zero payment marked as a cumulative approval. `authorizeClaim()` could then advance `paidThroughCycle`, although holders had not approved catching up earlier installments.

Reproduction:

1. Reject cycle 1.
2. Leave cycle 2 completely silent and claim its isolated installment after day 67.
3. Claim cycle 2 again. It sends no ETH, but the old implementation advances the cumulative checkpoint to 2.
4. Approve cycle 3. The old implementation subtracts cumulative principal through cycle 2, including the unpaid first installment.

This underpays the owner and can leave mint principal held after the final normal claim. It does not let the caller steal another holder's funds.

**Fix:** A repeated or already-covered silence payment remains labeled as isolated, so it cannot advance the cumulative approval checkpoint. The silence prefix sum receives no additional amount. Both explicit-cycle and default repeated claims are covered.

**Proof:** [original failing regression](security-review-2026-11-08/silence-bug-reproduction.log), `testRepeatedSilenceClaimDoesNotAdvanceCumulativeCheckpoint`, and `testFuzzInstallmentModel`. The independent model tracks individual paid installments, without using the implementation's checkpoints or Fenwick tree. Each fuzz run makes 35 claim attempts across seven cycles with approvals, rejections, silence, repeats and out-of-order claims, then completes wind-down and refunds.

### F-02 — Medium, configuration-dependent: oversized arithmetic inputs could prevent progress

**Location:** `FundingCore` constructor and time-based accounting.

Checked Solidity arithmetic reverts on overflow; it does not make an overflowing payment available. Previously unrestricted durations and direct-mint prices/supply could be accepted even when subsequent timestamp or multiplication operations could not be completed. These values require deployment misconfiguration; an arbitrary holder cannot change immutable economics after deployment.

**Fix:** Bound supply to uint64, principal price to uint80, and both durations to uint48. Existing zero-value and percentage constraints remain. SeaDrop additionally bounds gross price, wallet cap, and the actual mint deadline before narrowing casts.

Bounds now establish:

- principal × supply fits within 144 bits;
- principal × duration fits within 128 bits;
- per-token percentage calculations fit within 94 bits;
- review counts and the silence prefix-sum index remain bounded;
- scheduled durations plus ordinary chain timestamps are far below uint256 limits.

Tests reject oversized configurations before funds enter, and exercise the maximum supported price and duration through the final approved payment. Practical deployment values should be much smaller than these representation bounds.

### F-03 — Low / defensive: wind-down reserve multiplication

**Location:** `IndustrialImaginationGovernedFunding.windDown()`.

`pool * 500 / 10000` could overflow for a sufficiently large synthetic balance. Real ETH supply is far below that threshold, so this was not a demonstrated economically feasible attack.

**Fix:** Use `pool / (BPS / WIND_DOWN_OWNER_BPS)`, exactly `floor(pool / 20)` with the fixed 5% constants. This preserves every rounding result and avoids the overflowing intermediate product. A test covers a synthetic uint256-max balance.

### F-04 — Low: preview mint succeeded but receipt parsing could crash

**Location:** `tools/card/testnet.mjs`.

The wrapper still accessed Solady's `Transfer.id`; ERC721A names that field `tokenId`. The transaction could succeed while the script failed before saving the preview record.

**Fix:** Shared receipt parsing reads the third event argument and requires the log's emitting address to match this collection, the sender to be zero, and the recipient to match. This also prevents unrelated Transfer-shaped logs from being mistaken for the preview mint. Offline tests use ERC721A's event ABI.

### F-05 — Medium, release-process: retries could silently reuse an older build

**Location:** testnet release reuse and `chain.mjs` deployment records.

Previously, checking economic getters and the collection type did not establish that a saved deployment contained the latest fixes.

**Fix:** Record collection/renderer creation-bytecode fingerprints and deployed runtime hashes. Before uploads or mint setup, the testnet wrapper rejects missing or changed fingerprints and mismatching onchain runtime hashes. It performs a clean build so the renderer and the runtime hash embedded in the funding constructor come from a consistent compiler output.

Old release files deliberately fail this check. Archive the previous release JSON under another filename before intentionally deploying a replacement. The script does not delete it or upgrade a live contract.

### F-06 — Low, dependency verification: address and code presence were insufficient

**Location:** `foundry.lock`, deployment preflight, ETHFS descriptor checks.

Added the missing SeaDrop source revision to the lockfile. Deployment preflight now verifies a network-specific canonical SeaDrop runtime hash before obtaining a signer or uploading assets. Offchain ETHFS validation also requires canonical descriptor encoding, matching the Solidity reader's structural restrictions.

The contract constructor still checks code existence rather than hardcoding network hashes. Manual deployments outside the reviewed tooling must independently validate the supplied mint engine. A malicious engine could violate the trusted mint/payout protocol.

### F-07 — Informational: unused transfer machinery and outdated descriptions

Soulbound transfer entry points now reject directly, while the internal mint/burn hook remains as a second restriction. This preserves the intended transfer prohibition and removes unused ERC721A transfer bookkeeping from the runtime. All transfer overloads, approvals, minting and burns are tested.

Expanded settlement comments, documented the historical `FundingCouncil` name, corrected stale direct-mint/council/SeaDrop descriptions, marked prior guardian verification as historical, removed the payable fallback warning without adding a payment path, and renamed the event argument `at` to avoid a future-keyword warning. The event signature is unchanged. The Fenwick tree was retained because it makes late payment deductions logarithmic rather than requiring an ever-growing scan; its accounting role is now explicitly tested.

## Funds and authorization trace

| Path | Checks and effects reviewed | Conclusion |
|---|---|---|
| Direct `mint` / `allowlistMint` | Window, positive quantity, exact payment, lifetime quota, total supply, Merkle proof; ledger updated before NFT issuance | Legacy path conserves principal; burns do not free mint quota |
| SeaDrop `mintPublic` / `mintAllowList` | Exact gross payment, fixed-price leaves, restricted fee recipient, payer authorization, shared lifetime counts | Canonical protocol tests pass; forged free/zero-fee leaves fail |
| `mintSeaDrop` / `_mintTokens` | Only fixed engine, no pending batch, live sale, bounded quantity; expected net and funding counts set before receiver callback | Callback cannot finalize an unpaid batch or bypass quotas |
| `receive()` | Only fixed engine, outstanding nonzero settlement, exact amount; clears pending state and accounts for surplus without external calls | No 2,300-gas assumption; SeaDrop forwards call gas. Failed settlement reverts the whole mint |
| `finalize` / `_finalize` / `closeMint` | Sale ended, sold out, or authorized early close; no unsettled batch; finalized state and upfront ledger updated before transfer | Upfront paid once; rejecting owner cannot block force-send; sale stays closed |
| `startPeriod` / council start | Finalization required, owner-only, one start, before backstop, no terminal exit | Electorate and time schedule become fixed |
| `voteReview` / `_cast` / `outcome` | Owned eligible NFTs, no duplicates, open window, rounded-up quorum, strict majority after close | Owner snapshot excluded; partial turnout/ties do not become silence |
| `_payment` / `_cumulativePayment` / silence tree | Explicit approvals cumulative; silence isolated; prior payments deducted exactly once | F-01 fixed; bitmap-model fuzz comparisons pass |
| `_claim` / `authorizeClaim` | Only owner through collection; exact paired council; no exit/backstop; authorization consumed before ETH transfer | No payment outside an approved or fully silent entitlement |
| Legacy `_settleOwnerShare` / `_burnForRefund` | Same cumulative per-token vesting formula for claims and refunds; active-supply accounting precedes transfer | Random timing and burn-order conservation passes |
| `openEscapeVote` / `voteEscape` / `executeEscape` | Two consecutive majority rejections, no superseding approval, eligible holder, separate closed quorate ballot | Silence cannot activate escape; successful escape permanently stops ordinary payments |
| `activateEscape` | Only paired council, terminal flag already set, shared reentrancy guard | Holder pool snapshot matches actual retained balance |
| `windDown` / `authorizeWindDown` | Inactivity or public deadline, early escape priority, terminal state recorded once | Exactly 5% reserved; late donations do not create a second owner levy |
| `claimWindDownShare` | Pays recorded beneficiary, clears reserve before transfer | Anyone may trigger payment but cannot redirect it; ownership changes preserve entitlement |
| Governed burn / `_refundPool` | Exit active, caller owns NFT, reserve excluded, burn/count effects before payout | Final holder receives division dust; duplicate and callback burns cannot drain others |
| `_sendETH` | Solady bounded call followed by temporary force-send on rejection | Rejecting holders/beneficiaries do not block other entitlements; no arbitrary public send/sweep function |
| Ownership / metadata administration | Two-step ownership on SeaDrop; renunciation disabled; exact renderer runtime and permanent token-metadata freeze | Future owner payments follow legitimate ownership; token freeze is not a freeze of every inherited metadata setter |

The conservation identity tested is:

`net received + unsolicited ETH = owner paid + holder refunds + current contract balance`

The reserved owner share is part of current balance until claimed, not an additional source of money. Ordinary installments use principal, not raw contract balance. During exit, actual live balance supplies the holder pool after subtracting any reserve.

## SeaDrop integration conclusions

The collection directly inherits upstream `ERC721SeaDrop`, passes name/symbol and one allowed engine in its constructor, sets upstream max supply, and retains ERC721A safe minting, sequential IDs, mint statistics and ERC165 support. Public and allowlist stages use identical funding economics. Disabling token transfers and operator approvals does not disable mint receiver checks. The upstream public burn reaches the overridden refund hook.

The upstream nonvirtual payout setter remains owner-callable. The adapter checks payout after the NFT receiver callback: redirecting it there causes the mint to revert atomically. SeaDrop snapshots the payout address before paying its fee recipient; a fee callback that changes payout cannot redirect the current payment, and subsequent mints fail until routing is restored. Both callback cases are tested against the deployed engines.

A rejecting fee recipient can stop mints because canonical SeaDrop requires its fee transfer to succeed. Reversion rolls back NFTs, fees, funding state and value. This is a recipient-availability risk, not retained partial payment.

Twenty-five sequential single-token mints were exercised at an unchanged block number and timestamp, with exact balances and zero pending settlement after every mint. This verifies ordering and settlement behavior, not Base's maximum throughput, congestion, wallet UX, or provider rate limits.

Canonical address on both networks: `0x00005EA00Ac477B1030CE78506496e8C2dE24bf5`.

| Network | Pinned read/test block | Runtime bytes | Runtime keccak256 |
|---|---:|---:|---|
| Base | 54,809,346 | 21,081 | `0x2151e8d092f04e5cf00576bf5e6b92a0fc15b0013dc8c08b68934048d39ac1fc` |
| Base Sepolia | 56,151,877 | 21,081 | `0x7ebd6750c54fd6e4667af4d3310cf02bc420606f6e3eaed9654127047f5166c0` |

The hashes differ and are deliberately pinned separately. Canonical-fork tests use `FOUNDRY_ISOLATE=false` so transaction fee debits do not contaminate principal-only balance assertions. Initial isolated fork runs exposed fixture assumptions about transaction costs; Sepolia also had an existing fee-wallet balance, so rollback tests now compare balance changes. These were test-fixture corrections, not production accounting changes. The separate Anvil rehearsal exercises actual local transactions with fees.

**OpenSea hosted-drop acceptance is still unverified.** The supplied OpenSea overview advises custom collections to preserve mint functionality. This collection intentionally adds fixed funding settlement constraints, restricted configuration and soulbound behavior. Successful canonical SeaDrop calls do not prove that OpenSea's hosted onboarding, storefront or marketplace UI supports all those restrictions. Confirm that separately before announcing a hosted mint.

## Metadata, bytecode and static review

`CardFiles` checks STOP prefixes, canonical tuple/array offsets, 1–32 slices per descriptor, slice boundaries, exact combined length, individual size bounds, content hashes and aggregate renderer input at most 512 KiB. The upstream reader is invoked only after validation. Corrupt hashes, bad prefixes, invalid offsets, trailing descriptor bytes, oversized payloads and changed file bytes are tested. JSON names escape quotes, backslashes, control bytes and Unicode. Nonexistent/burned token URIs revert. Renderer selection rejects arbitrary implementations and cannot change after freeze.

Hashes establish content identity, not JavaScript semantics. The shipped build pins the decoded Three.js revision/hash and embeds runtime/font/logo data. The Anvil token URI returned HTML identical to the built player and its preview. Artwork bytes were not changed, and browser performance, mobile rendering and live marketplace rendering were not rebenchmarked for this contract-focused review.

All first-party imports and syntax compile under the pinned toolchain. The PDF's listed Yul stale-bookkeeping bug is marked fixed in 0.8.38; that stable compiler is used. Dependency warnings about virtual modifiers and future identifiers remain in vendored code and were not silently suppressed or edited.

Forge lint was reviewed, not reported as warning-free. [Raw findings](security-review-2026-11-08/security-lint.log) include:

- timestamp comparisons: intentional scheduling, with exact mint/review/backstop boundary tests;
- casts: bounded by constructor and mint-start checks;
- external-call/reentrancy reports: traced to known paired contracts and guarded payout paths, with adversarial callback tests;
- ETH destinations: selected from checked token ownership, owner entitlement or recorded reserve beneficiary;
- packed encoding: concatenation of metadata strings, not authentication hashes; Merkle node pairs have fixed 32-byte widths;
- zero-initialized locals, constant booleans, naming and modifier ordering: Solidity-defined values and read-only ownership checks, not identified money bugs;
- loops: bounded allowlists/descriptors, caller-chosen voting batches, logarithmic payment-index traversal;
- event warnings: existing mint/review/payment events plus state getters; a complete standalone event-sourced accounting index is not supplied.

No first-party `tx.origin` authorization, user-directed `delegatecall`, arbitrary execution proxy, randomness-based money decisions, or unchecked financial arithmetic was found. Solady's intentional force-send uses a temporary contract's SELFDESTRUCT; tests cover rejecting recipients under the configured EVM. Compiler/platform changes still require reassessment.

## Measured verification

Toolchain: Foundry 1.8.1, Solidity `0.8.38+commit.1835d247`, via IR, optimizer runs 1, Prague EVM, Node 23.8.0. CI now pins Foundry, runs 2,048-case fuzz tests, invokes security lint and includes the deployment-helper regressions.

| Check | Result |
|---|---|
| Clean build/import resolution and format check | Passed |
| Solidity suite | 66 passed, 0 failed; 10,240 local fuzz cases |
| JavaScript asset/release checks | 5 passed |
| Asset reproducibility | Identical generated template, runtime, manifest and preview |
| Canonical Base fork | 19 passed, including 256 installment-model cases |
| Canonical Base Sepolia fork | 19 passed, including 256 installment-model cases |
| Anvil/ETHFS/SeaDrop lifecycle | Passed at Sepolia source block 56,210,180 |
| Actual metadata read | 37,206,020 gas, below 50 million |
| Public-network transactions | None |

Anvil accounting: 300009 wei gross; 290019 wei net; 87006 wei upfront; 33834 wei first-cycle payment; 169179 wei holder refunds after two rejections and a successful escape ballot; zero final balance. Thus 120840 wei owner payments plus 169179 wei refunds equals 290019 wei net exactly. [Full rehearsal record](security-review-2026-11-08/anvil-rehearsal.json).

| Contract | Runtime bytes | Creation bytecode bytes |
|---|---:|---:|
| IndustrialImaginationGovernedFunding | 23,989 | 40,260 |
| IndustrialImaginationSeaDropFunding | 21,552 | 31,311 |
| IndustrialImaginationFunding | 8,467 | 16,251 |
| FundingCouncil | 6,286 | 6,375 |
| FundingCardRenderer | 6,062 | 7,730 |
| FundingAllowlist | 844 | 870 |

Runtime is below EIP-170's 24,576-byte limit. The governed contract has **587 bytes of headroom**, compared with 61 bytes before this review. Creation sizes shown exclude ABI constructor arguments; the tested deployment, with its actual arguments, also passed EIP-3860's 49,152-byte limit. Very large collection name/symbol strings still consume constructor argument space and metadata gas; do not treat arbitrary input strings as covered by the measured deployment.

## Remaining trust and operational risks

1. **NFT-weighted governance is not identity-weighted.** Excluding the owner snapshot address does not exclude other founder-controlled wallets, coordinated holders or Sybil purchases. A quorate majority is a majority of votes cast, not a majority of all NFTs. Do not advertise stronger governance guarantees.
2. **Any nonzero turnout blocks silence fallback.** Sub-quorum or tied ballots release nothing. Later approval can catch up; timed wind-down remains the terminal recovery route. This is the accepted rule, not a newly introduced permission.
3. **Owner and fee-recipient configuration matter.** Ownership transfers redirect future owner payments; loss of the owner key stops owner actions. Public backstop refunds remain available, but the current holder-vote version has no owner backup-wallet recovery. A rejecting fee recipient stops mint availability.
4. **Escape execution priority (addressed after this review).** A successful escape now locks in at ballot close and takes priority over claims and wind-down. Public wind-down waits for an eligible ballot already open at the deadline, and new ballots cannot open at or after that deadline. See the [current governance rules](../GOVERNANCE.md#exit-and-refunds).
5. **Unsolicited balances (addressed for governed exits after this review).** Once an exit has executed and zero funding NFTs remain, excess ETH can be sent to the current owner through a permissionless sweep. Any wind-down reserve is deducted and remains payable to its recorded beneficiary. See the [current governance rules](../GOVERNANCE.md#exit-and-refunds).
6. **Metadata stays owner-updatable (policy changed after this review).** The current build lets the owner replace the renderer at any time. Each renderer still uses fixed assets and must match the expected implementation. Collection and drop metadata settings remain owner-administered through the existing interfaces.
7. **Deployment headroom remains small.** Keep the exact build/size checks mandatory. Changing compiler settings, dependencies, features or very large constructor strings needs fresh verification.
8. **OpenSea Studio indexing signal verified locally after this review.** The inherited SeaDrop constructor emits the deployment event that the OpenSea team identified to the collection owner as the signal for Studio mint indexing. Confirm the listing and marketplace rendering on the live release. See the [SeaDrop notes](../SEADROP.md).

No remaining demonstrated critical/high-severity fund-theft finding was identified in the reviewed first-party paths. The assumptions above and the limitations of this review remain material before handling real funds.

## Reproducing the checks

From `contracts/`:

```sh
forge fmt --check
forge clean
forge build --sizes
forge test --fuzz-runs 2048 -vv
node --test tools/card/*.test.mjs
forge lint src
FOUNDRY_ISOLATE=false TEST_CANONICAL_SEADROP=true forge test --match-contract SecurityTest --fork-url https://mainnet.base.org --fork-block-number 54809346 -vv
FOUNDRY_ISOLATE=false TEST_CANONICAL_SEADROP=true forge test --match-contract SecurityTest --fork-url https://sepolia.base.org --fork-block-number 56151877 -vv
npm run test:governed:fork
```

Use an archival RPC if a public endpoint stops serving the recorded historical blocks. `forge test` and the Anvil rehearsal do not broadcast to the public networks. The separate `npm run deploy:testnet` command does broadcast and was not run during this review.
