# Holder reviews, payments and refunds

The governed collection holds the ETH and soulbound NFTs. Its dedicated `FundingCouncil` contract records holder votes, authorizes payments, and controls terminal exits.

## Mint and voting snapshot

Supporters mint through SeaDrop. Anyone can finalize after sellout or expiry. The owner can also call `closeMint()` to permanently close public minting and finalize early. Finalization pays the configured upfront share of net proceeds, including fee-rounding surplus.

The owner calls `startPeriod()` once after finalization and before the 180-day unstarted backstop. This fixes the electorate and accrual schedule. Each NFT has one vote per ballot. The owner wallet at period start and its NFTs are excluded from the snapshot. Later ownership changes of the funding contract do not alter that snapshot. Disclose any other project-controlled wallets separately. Voting NFTs are soulbound and cannot burn until an exit ends voting.

## Monthly payments

Reviews open at the end of each 30-day cycle and remain open for 72 hours. The final partial cycle, if any, is reviewed at the next 30-day boundary. Holders submit their token IDs with `voteReview(cycle, tokenIds, approve)`. Each listed NFT must belong to the caller and may vote once per review.

| Result at review close | Payment rule |
|---|---|
| At least 10% turnout, rounded up, and more yes votes than no votes | Authorizes cumulative payments through that cycle, including earlier rejected, unresolved or unclaimed installments. |
| Quorum and more no votes than yes votes | Rejects that review. Funds remain held until a later explicit approval or an exit. |
| Quorum reached with a tie | Unresolved. This review authorizes no payment. |
| Below quorum, including zero votes | The owner can claim only this installment seven days after the review opened. The first fallback is on day 37. |

Results cannot authorize payment while votes are still open. A fallback installment never catches up an earlier cycle. Cumulative approvals deduct installments already paid under silence. `claimOwnerShare()` first settles any outstanding cumulative approval and otherwise checks the latest matured silence installment. Use `claimOwnerShareForCycle(cycle)` to select an older below-quorum review or a specific approval.

## Exit and refunds

Two consecutive quorate majority rejections let an eligible holder open a separate 72-hour escape ballot with `openEscapeVote(secondRejectedCycle, tokenId)`. The same turnout and strict majority apply. A qualifying review approval through the rejected pair can supersede the ballot if that review closes by the time the escape ballot closes. An isolated fallback payment does not clear eligibility. A successful escape locks in at close, blocking owner claims and wind-down until anyone executes it with `executeEscape(round)`. Subsequent review approvals cannot overturn that result. Owner claims remain available while the ballot is open, subject to the usual claim rules and public deadline.

The owner can wind down after 90 days without an explicit majority review decision, counted from mint finalization or the latest qualifying review close. An eligible holder escape takes priority over this early route. At the public backstop, anyone can call `windDown()`. It opens 180 days after finalization if the period never starts, or 90 days after the final scheduled review closes. For a 180-day stream, the latter is day 273 after period start. Ordinary claims stop at the public deadline. If an eligible escape ballot is already open, public wind-down waits for that ballot to close. If it fails, wind-down becomes available immediately. Holders can retry an unsuccessful ballot while the rejected pair remains eligible and the public deadline has not arrived. An unstarted period can no longer start once that deadline arrives.

| Exit | Split of remaining ETH |
|---|---|
| Holder escape | Entire balance to holders |
| Owner or public wind-down | 5% reserved for the owner at activation, rounded down to wei, with the balance for holders |

An exit ends voting and ordinary payments. Holders use `burn(tokenId)` to claim their share of the live holder pool. The final burn receives any division remainder. Anyone can pay the separate owner reserve to its recorded beneficiary using `claimWindDownShare()`. That claim can happen before or after holder refunds.

Once an exit has executed and zero funding NFTs remain, anyone can call `sweepExcessETH()` to send excess ETH to the current owner. The sweep deducts any unclaimed wind-down reserve from the available balance. Swept amounts are recorded in `ExcessETHSwept` events and kept separate from `ownerPaidAmount`, which tracks payouts under the funding rules.

## Contract calls and deployment

| Action | Contract and function |
|---|---|
| Find the holder voting contract | Funding `council()` |
| Inspect the electorate | Council `eligibleSupply()`, `excludedOwner()`, `quorum()` |
| Inspect review timing, tallies and outcome | Council `reviewStart(cycle)`, `reviewDeadline(cycle)`, `reviews(cycle)`, `outcome(cycle)` |
| Check whether an NFT has voted | Council `hasVotedReview(cycle, tokenId)`, `hasVotedEscape(round, tokenId)` |
| Vote on escape | Council `voteEscape(round, tokenIds, activate)` |
| Inspect payment authorization | Council `approvedThroughCycle()`, `paidThroughCycle()`, `silencePaid(cycle)`, and funding `pendingOwnerShare()` |
| Send excess ETH after exit and the final burn | Funding `sweepExcessETH()` |
| Inspect wind-down timing and holder refund | Council `publicWindDownAt()`, and funding `getRemainingLockedEth(tokenId)` |

The holder vote release requires a new deployment. Run `npm run deploy:testnet` from this directory to deploy on Base Sepolia and mint the preview NFT. The script saves `media/dist/84532-holder-vote-seadrop-release.json` separately from the previous guardian release. The default preview NFT is minted to the deployer, which is also the funding owner. Use a separate holder wallet to mint an eligible voting NFT before finalizing a voting rehearsal.

Run `npm test` for local tests and `npm run test:governed:fork` for the SeaDrop rehearsal on an ephemeral Base Sepolia fork.

The historical ABI names `Outcome.Silence`, `SILENCE_DELAY` and `silencePaid` now cover below-quorum fallback, including ballots with votes against payment. It remains an isolated installment, cannot qualify as a rejection for escape, and does not reset the majority-decision inactivity clock. Zero eligible supply retains the zero-vote fallback.

## Seven-day backup recovery

The governed collection creates a dedicated `FundingRecovery` helper, available through `recovery()`. It never holds funding proceeds.

Before minting starts, the owner calls `nominateBackup(wallet)` on the helper. The distinct backup wallet must call `acceptBackup()` itself. Before minting, a new nomination replaces the previous backup; nominating zero clears it. Both nomination and acceptance close permanently when minting starts.

The accepted backup calls `requestRecovery()`. After seven full days it can call `executeRecovery()`. The current owner may call `cancelRecovery()` at any point before execution, including after the deadline. A cancelled request can be retried only with a new seven-day delay. Watch `RecoveryRequested` events; the contract does not send notifications itself.

Every completed ownership transfer invalidates the prior backup, nomination and request, even if ownership later returns to the original wallet. Recovery also clears any pending ordinary ownership handover. Recovery is therefore single-use once minting starts: no replacement backup may be registered afterward. An ordinary transfer proposed but not yet accepted does not itself disable recovery.

Recovery changes ownership only. It does not move NFTs or funds, bypass holder review, alter the excluded voting-owner snapshot, reset the public backstop, or redirect a wind-down reserve already assigned to its original beneficiary. Future permitted owner payments go to the new owner.

This protects against losing the owner key. Someone controlling that key can cancel recovery. Someone controlling the backup can take ownership if the owner does not cancel within the delay; once the deadline passes, cancellation and execution race in transaction order.

## Approved sale

The production release uses this holder-governed collection with 2,500 NFTs priced at 0.008 ETH each and public minting only. See [production configuration](PRODUCTION.md) for release pins and test-only fixtures.
