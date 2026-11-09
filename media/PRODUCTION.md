# Production collection

The only public release target is `IndustrialImaginationGovernedFunding`, the SeaDrop collection with NFT holder voting. `FundingCouncil` is the historical Solidity name of the holder-voting helper, not an appointed council.

| Setting | Approved value |
|---|---|
| Supply cap | 2,500 NFTs |
| Gross mint price | 0.008 ETH, or 8,000,000,000,000,000 wei |
| Maximum gross proceeds | 20 ETH |
| Mint route | SeaDrop public mint only |
| Payment authorization | Monthly NFT holder reviews and the documented below-quorum fallback |

`tools/card/release-checks.mjs` is the shared release configuration. The testnet wrapper and direct public upload/deployment commands reject conflicting supply, price or profile settings before paid transactions. The constructor stores supply and price immutably. Constructors remain parameterized so small local fixtures and rounding fuzz tests can exercise edge cases. Bypassing the release tools and deploying by hand requires supplying the approved values yourself.

There are no allowlist setup functions or proof generator in the SeaDrop path. The inherited SeaDrop interface retains `updateAllowList`, which always reverts. Its registered Merkle root stays zero. Signed and token-gated stages are also disabled. `enableMint()` registers payout routing; `enablePublicMint()` opens the public stage within that fixed window.

Fee rate and recipient, wallet cap, mint duration, streaming duration, upfront basis points, owner and backup wallet remain separate operational settings. This cleanup does not change the payout, voting, refund, recovery or renderer rules. The Base Sepolia wrapper retains its clearly marked test defaults for these other settings; they are not production fee terms. Confirm them before a mainnet release. Public Base mainnet writes remain disabled.

## Workflow

Run from `contracts/`.

```sh
npm ci
npm run build
forge fmt --check
forge build --sizes
npm test
npm run test:governed:fork
```

The fork command uses a disposable local Anvil instance and does not broadcast. For a later Base Sepolia deployment, follow [the deployment guide](RELEASE.md), including backup-wallet consent and preflight. `npm run deploy:testnet` uses the approved supply and price and purchases one 0.008 ETH preview NFT. Fund the deploying wallet for that mint plus deployment gas.

## Retained regression fixtures and evidence

`IndustrialImaginationSeaDropFunding` remains the production inheritance layer and a continuous-policy test fixture when deployed alone. `IndustrialImaginationFunding` is the old direct-mint fixture used by renderer tests and the local media inspection command. Neither is a public release option. The legacy profile is permitted only on local chains or a verified loopback Anvil fork. Their tests intentionally use tiny supplies and unusual wei prices to detect rounding errors. The direct-mint fixture retains its original allowlist solely for legacy coverage.

The `media/evidence/` reports and existing `media/dist/` release records describe earlier runs. They are historical evidence, not current deployment instructions or new verification. Old deployments cannot acquire these changes. The wrapper rejects incompatible saved releases instead of silently reusing them.

## Validated public-stage updates

`updatePublicDrop(seaDropImpl, publicDrop)` accepts the upstream owner-or-self authorization, including calls through `multiConfigure`. Call `enableMint()` first to establish the fixed sale window and register payout routing. The update must target the authorized SeaDrop engine and match all six settings exactly: gross price, start time, end time, lifetime wallet cap, fee basis points and restricted fee recipients (`true`). A successful update enables the local public-mint flag and forwards the configuration to SeaDrop. `enablePublicMint()` remains an alternative that supplies these settings automatically.

The update cannot schedule a different window, change economic terms, disable recipient restrictions or reopen an expired/finalized sale. Read the exact timestamps from `mintStartTime()` and `MINT_PERIOD`; a separately chosen Studio schedule will be rejected. This supports compatible Studio requests, not arbitrary Studio edits. Live UI integration and the actual fee-recipient configuration still need verification on the deployed collection.
