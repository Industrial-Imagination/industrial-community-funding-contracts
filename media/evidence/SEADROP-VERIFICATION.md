# SeaDrop integration verification

The subsequent governed release is covered by [the governance verification](GOVERNANCE-VERIFICATION.md).


Verified on November 4, 2026 with Foundry 1.8.1, solc 0.8.28 via IR, optimizer 200 runs, and Node 23.8.0.

## Results

- Fifteen Foundry tests passed across the original funding suite and the SeaDrop adapter suite. Two accounting fuzz tests ran 256 cases each.
- Two asset checks passed. The original 131-byte reverse message, library, player and preview hashes are preserved.
- The dedicated SeaDrop adapter runtime is 19,633 bytes, below EIP-170's 24,576-byte limit. The renderer is 6,158 bytes.
- The real Base Sepolia SeaDrop, 0x00005EA00Ac477B1030CE78506496e8C2dE24bf5, was exercised on an ephemeral Anvil fork at block 54,426,060. Its runtime hash is recorded in seadrop-fork.json.
- All state changes and transaction signing occurred against loopback Anvil. Public RPC calls read source-chain state.

## Protocol lifecycle

The test deployed ETHFS assets, the card renderer, and IndustrialImaginationSeaDropFunding using the release tool. It registered the collection with SeaDrop, computed a three-address allowlist root onchain, and built matching proofs with the release proof utility. A zero-price alteration failed verification. A funded allowlist mint succeeded. A third-party public payer failed until explicitly authorized, then minted two additional tokens for the same recipient. The lifetime recipient cap and cumulative supply cap were enforced.

The three mints cost 300009 wei gross. The configured 333-bps fee paid 9990 wei to the fee recipient. The collection received 290019 wei. Each token's conservative net principal was 96672 wei, divided into 29001 wei upfront and 67671 wei locked. Three rounding wei were included in the upfront payout. Pending settlement cleared after receipt.

An independent account finalized the sold-out collection. A midpoint burn returned 33836 wei. The owner then claimed through vesting completion, the remaining tokens burned with zero refunds, and the collection ended with zero ETH. Owner payouts plus holder refunds equaled actual net proceeds exactly.

The real minted token's metadata read cost 37,222,021 gas. The decoded HTML matched the previously verified card player byte-for-byte. Metadata for the burned token reverted. Freezing prevented renderer replacement. Browser screenshots, recording and offline playback evidence remain applicable to those identical player bytes.

## Adversarial local coverage

Tests reject unauthorized mint calls, direct mint bypasses, arbitrary ETH, altered critical SeaDrop configuration, underpayment and unbacked allowlist leaves. Underpayment rolls back token counts, fee transfers and settlement state. Receiver and fee-recipient callbacks cannot finalize before the payout arrives. Fuzzing exercises arbitrary fee rates, prices, mint quantities, single versus batch transactions, and exact net accounting through burns.

## Release boundaries

The sale has one fixed gross price and fee rate. The onchain allowlist builder supports up to 1024 wallets, configured in batches of at most 128. Arbitrary Merkle roots, signed mint stages and token-gated stages are intentionally disabled to preserve funded mint terms. Hosted OpenSea onboarding and actual-device checks are pending live-release work.

See [the raw fork report](seadrop-fork.json) and [the SeaDrop guide](../SEADROP.md).
