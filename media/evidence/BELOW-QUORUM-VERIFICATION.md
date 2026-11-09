# Below-quorum fallback update

The approved change replaces the zero-vote-only fallback with a below-quorum fallback. A review with turnout below the rounded-up 10% quorum becomes eligible seven days after review opening, regardless of whether its participating votes favor or oppose payment. Voting still closes after 72 hours. Quorate majority rejections and quorate ties remain blocked.

Fallback pays only that cycle's installment, never prior rejected or unresolved installments. Repeated claims cannot advance the cumulative payment checkpoint or pay twice. Later explicit approval catches up earlier installments while deducting fallback amounts already paid. Below-quorum ballots do not qualify as rejected cycles for escape and do not reset the majority-decision inactivity clock. Upfront economics and owner exclusion are unchanged.

For ABI compatibility, `Outcome.Silence`, `SILENCE_DELAY`, and `silencePaid` retain their names and values but now refer to the expanded fallback. Zero eligible supply retains the zero-vote fallback.

Validation: 67 Solidity tests pass, including five fuzz tests with 2,048 cases each (10,240 cases). Five JavaScript checks and formatting pass. Regressions cover below-quorum approval and opposition, the exact seven-day boundary, quorate tie/rejection blocking, repeated/default claims, catch-up conservation and escape ineligibility. Prior canonical fork and Anvil reports describe the preceding build; no new public transactions or network-fork rehearsals were performed for this update.

The governed runtime remains 23,989 bytes (587 bytes below EIP-170). Its creation bytecode is 40,295 bytes before constructor arguments. FundingCouncil runtime is 6,321 bytes. Both remain within deployment limits under the pinned compiler settings.

This changes non-upgradeable contracts and therefore requires a new deployment. The deployment wrapper's build fingerprint check rejects reuse of the preceding release.
