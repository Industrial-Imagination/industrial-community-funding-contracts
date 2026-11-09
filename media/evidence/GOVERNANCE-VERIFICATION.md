> Historical verification below includes superseded guardian mechanics. For the current holder-governed build and November 8 fixes, see [SECURITY-REVIEW.md](SECURITY-REVIEW.md).

# Governed funding verification

Verified locally on November 5, 2026 using Foundry 1.8.1, solc 0.8.28 via IR and optimizer 200 runs, and Node 23.8.0.

All 35 contract tests and both asset checks passed. Three accounting fuzz tests ran 256 cases each, totaling 768. The governed collection runtime is 21726 bytes and its automatically deployed council is 5545 bytes. Governed initcode is 36829 bytes. All remain within EIP-170 and EIP-3860 limits.

Governance tests cover owner-only manual start after finalization, upfront payment without review, both council sizes, majority thresholds, 72-hour deadlines, duplicate and unauthorized votes, day-37 silence, a single vote blocking fallback, rejection catch-up, cycle-capped payments, old silent-cycle claims, invalid guardian sets, replacement timing, stable escape electorates, nonconsecutive rejections, later approval resetting eligibility, distinct escape voting and expiry, no pre-escape refunds, owner-payment shutdown, approved-but-unclaimed refunds, extra ETH in the pool and exact refund dust accounting.

The real SeaDrop and ETHFS registry on Base Sepolia were exercised through a private fork. The fork report records the source block and bytecode hash. Minting raised 300009 wei gross and 290019 wei net. Finalization paid 87006 wei upfront. The owner started the stream, obtained majority approval for cycle 1 and claimed 33834 wei. Cycles 2 and 3 were explicitly rejected. A separate majority escape vote opened the 169179-wei remainder to holder burns. All three tokens burned, refunds matched that pool, and the final collection balance was zero. Total owner payouts plus refunds equaled actual net receipts.

The actual SeaDrop-minted NFT returned the exact previously verified HTML card player. Its metadata read used 37222109 gas, below the 50-million budget. This change did not require new card imagery or animation bytes.

No public transactions were sent during this verification. The deployed earlier testnet release retains its earlier mechanics. The new deployment command requires user-supplied guardian addresses and writes a separate governed release record.

See [raw fork results](governed-fork.json) and [the governance guide](../GOVERNANCE.md).


## Timed wind-down verification, November 7, 2026

Local Foundry verification covers owner wind-down after 90 days without a majority review decision, a 180-day public pre-start backstop, and the day-273 public deadline for the configured 180-day stream. Tests also cover partial final cycles, rejection priority, ordinary-claim and period-start deadline boundaries, repeated activation, retained full-pool council escape, and the activation-time beneficiary.

Reserve and refund accounting is exercised with 256 fuzz runs across burn order, claim timing and unsolicited ETH amounts. The owner reserve is excluded from all holder quotes and payments, and a reverting beneficiary receives its reserve through the existing force-send helper. The full contract suite has 53 passing tests. The governed collection runtime is 23,706 bytes, below the 24,576-byte EIP-170 limit. These checks describe local execution of the updated contracts. Existing public deployments require replacement to gain these rules.
