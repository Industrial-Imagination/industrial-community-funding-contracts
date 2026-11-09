# Industrial Imagination Funding

The current collection is `IndustrialImaginationGovernedFunding`: soulbound NFTs minted through SeaDrop, an upfront payment from net proceeds, and subsequent installments authorized by NFT holders. Artwork and playback are onchain through ETHFS.

The approved release is **2,500 NFTs at 0.008 ETH each**, public mint only, for a maximum **20 ETH gross**. Release tooling pins these terms and holder governance. Fees, upfront allocation, durations and wallet cap remain separate settings; net proceeds depend on the configured SeaDrop fee. See [production configuration](media/PRODUCTION.md).

See the [governance rules](media/GOVERNANCE.md), [SeaDrop integration](media/SEADROP.md), [deployment guide](media/RELEASE.md), and [November 8 security review](media/evidence/SECURITY-REVIEW.md). These contracts are non-upgradeable. Changes require a new deployment; earlier public test collections retain their original rules.

## Money and lifecycle

1. The owner starts a fixed mint window. Public mints use the fixed price, fee rate, lifetime wallet cap and supply cap. The owner can permanently close the sale early; anyone can finalize after expiry or sellout.
2. SeaDrop deducts its configured fee and sends the exact net proceeds to the collection. No upfront money leaves during minting.
3. Finalization pays the upfront allocation once. The owner then calls `startPeriod()` to begin the installment/review schedule.
4. Each 30-day cycle has a 72-hour holder review. Each eligible NFT has one vote. Turnout must reach 10% of eligible supply, rounded up; a strict majority of votes cast decides approval or rejection. The owner wallet at period start is excluded.
5. Approval authorizes cumulative installments through that cycle. Quorate rejection and quorate ties release nothing. Below-quorum turnout, including zero votes, permits only that cycle's installment seven days after review opening. Repeated or out-of-order claims cannot count an installment twice or forgive earlier unpaid installments.
6. Two consecutive majority rejections allow a separate escape ballot. Successful escape stops ordinary payments and opens the remaining balance to holder refunds. Timed owner/public wind-down also opens refunds, reserving 5% of the remaining balance for the activation-time owner.
7. A holder burns each owned NFT to claim its share of the remaining holder pool. The last burn receives division dust. Owner reserve claims and holder refunds are independent.

Holders cannot burn for money during ordinary streaming in this version. The public backstop is 180 days after finalization if the period never starts, or 90 days after the final scheduled review closes. Owner inactivity, rejection priority and partial-cycle timing are detailed in the governance guide.

## Accounting in wei

For gross price `G`, fee basis points `F`, upfront basis points `U`, and transaction quantity `q`:

| Amount | Calculation |
|---|---|
| SeaDrop fee | `floor(q × G × F / 10000)` |
| Actual net received | `q × G − fee` |
| Net principal per token `P` | `floor(G × (10000 − F) / 10000)` |
| Upfront per token `A` | `floor(P × U / 10000)` |
| Locked per token `L` | `P − A` |
| Transaction rounding surplus | `actual net − q × P`, between zero and `q` wei inclusive |
| Finalization payment | `totalMinted × A + all transaction rounding surplus` |
| Cumulative principal through a cycle | `floor(L × min(cycle × 30 days, duration) / duration)` |
| Silent installment | `cumulative(cycle) − cumulative(cycle − 1)` |
| Wind-down reserve | `floor(remaining balance / 20)` |
| Holder refund after exit | `floor((live balance − unclaimed reserve) / activeSupply)` |

An explicit approval subtracts both previously settled cumulative principal and isolated silence payments within its range. Net receipts equal owner payments plus holder refunds plus remaining balance, excluding unsolicited ETH. Unsolicited ETH joins the governed exit pool and does not increase mint principal or ordinary installment entitlements.

Example: three NFTs at 100003 wei with a 333-bps fee receive 290019 wei net. Principal is 96672 wei per token. At 30% upfront, each contributes 29001 wei upfront and 67671 wei locked; 3 wei of transaction rounding surplus joins the upfront payment. Thus finalization pays 87006 wei and retains 203013 wei.

## Contracts and trust boundaries

| Contract | Responsibility |
|---|---|
| `FundingCore` | Shared funding ledger, upfront settlement, fixed economics, renderer selection, default continuous-vesting hooks |
| `IndustrialImaginationFunding` | Legacy direct-mint Solady collection; continuous owner claims and unvested refunds after finalization |
| `IndustrialImaginationSeaDropFunding` | Upstream ERC721SeaDrop/ERC721A adapter; fixed mint terms and exact pending settlement; legacy continuous refund policy |
| `IndustrialImaginationGovernedFunding` | Production collection; holder-approved installments, escape/wind-down, reserved owner share and terminal refunds |
| `FundingRecovery` | Pre-mint backup consent and cancellable seven-day owner recovery, without custody of funds |
| `FundingCouncil` | Dedicated, immutable-bound holder ballot and payment-authorization contract; the name is historical |
| `FundingCardRenderer` | Constructor-only ETHFS assets, data-URI JSON, SVG/WebP preview and HTML animation |
| `CardFiles` | Bounded descriptor/slice validation and hash verification before upstream ETHFS reads |
| `PlayerTemplate` | Generated playback template; edit `media/player.html` and rebuild instead |

The selected renderer must match this build's exact runtime and each instance has fixed assets. The owner can select another validated instance at any time with `setMetadataRenderer(address)`. Existing tokens then use the newly selected artwork and metadata.

SeaDrop uses its upstream two-step ownership transfer. Renouncing ownership, changing supply, transferring NFTs and granting approvals are disabled. Allowlist, signed and token-gated mint stages are disabled. The upstream payout setter cannot be overridden; redirecting payout blocks subsequent mints rather than sending successful mint proceeds away from the fund.

The constructor requires nonzero supply, price and periods; wallet cap at most supply; upfront and fee rates below 10000; and nonzero owner/fee recipient. Supply is at most uint64, price at most uint80, and durations at most uint48. SeaDrop additionally caps the wallet limit at uint16 and validates the uint48 mint deadline. These limits keep intermediate arithmetic bounded; choose sensible economic values far below the representation limits.

## Verification and deployment

Run from this directory:

```sh
npm ci
npm run build
forge fmt --check
forge clean
forge build --sizes
forge test --fuzz-runs 2048 -vv
node --test tools/card/*.test.mjs
```

The pinned toolchain is Solidity 0.8.38, via IR, optimizer runs 100, Prague EVM, and Foundry 1.8.1. Initialize dependency submodules recursively. The installed SeaDrop dependency is the pinned `math77/seadrop` fork; testing its source is separate from testing the canonical deployed contracts. Both network runtime hashes are checked by deployment preflight.

For local canonical-network tests and an Anvil/ETHFS rehearsal, follow the deployment guide. `npm run deploy:testnet` is the later public Base Sepolia command and mints one preview NFT. Public Base mainnet deployment is disabled in these scripts. The testnet wrapper rejects stale release fingerprints instead of silently reusing old contracts.

## Remaining trust and operational limits

- Holder voting is NFT-weighted, not identity-weighted. An owner can control other wallets; excluding one owner address does not prevent Sybil voting. Below-quorum opposition does not block the seven-day installment fallback.
- A configured fee recipient that rejects ETH can block minting. It cannot retain fees from a reverted mint. Confirm fee terms and recipient compatibility before starting.
- Ownership controls future owner payouts. Losing the owner key does not prevent public backstop refunds, and the optional pre-mint backup designation provides a cancellable seven-day ownership recovery. See the governance guide for its single-use and compromise limitations.
- Forced ETH joins the refund pool while funding NFTs remain. Once a governed exit has executed and the active supply reaches zero, anyone can sweep excess ETH to the current owner. The recorded wind-down reserve stays payable separately. Legacy variants can retain unsolicited ETH.
- Review the selected asset manifest before publishing a renderer. The inherited SeaDrop deployment event is the expected OpenSea Studio indexing signal. Confirm the Studio listing and marketplace rendering on the live release.
- Contract runtime size is close to EIP-170. Keep the size check mandatory for every change. Passing this review is not a formal proof or an independent external audit.

MIT. Funding logic derives from TokenWorks' FundingWorks. Dependencies retain their own licenses; the artwork runtime embeds its source notices.
