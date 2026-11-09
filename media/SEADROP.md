# SeaDrop funding release

The current governed release uses monthly NFT holder votes, isolated below-quorum fallback payments and terminal refunds. See the [governance guide](GOVERNANCE.md) for the current lifecycle and Base Sepolia deployment. The earlier direct-mint and continuous SeaDrop policies remain local regression targets only. See [production configuration](PRODUCTION.md).

The funding adapter inherits the upstream `ERC721SeaDrop` from `lib/seadrop`. Its constructor passes the name, symbol and one allowed SeaDrop address to that base, sets the fixed supply, and assigns the specified initial owner. Subsequent ownership transfers use SeaDrop’s two-step handover. The collection’s `SEA_DROP()` getter identifies its fixed mint engine.

The upstream creator payout setter is available to the owner. A mint reverts if the payout address is different from the collection after the NFT receiver callback. Restore the collection address on SeaDrop to resume minting. Direct mint selectors revert through the collection fallback. SeaDrop’s burn entry point applies the funding contract’s refund rules.

The renderer uses the upstream ETHFS file and bytecode slice types and reader from `lib/ethfs`. It validates pointer bytecode, file shape, slice bounds, content size and content hash. Initialize submodules recursively before building. The pinned SeaDrop revision requires Solidity 0.8.38. Run `forge clean` if rebuilding artifacts from the previous compiler or optimizer configuration.


The deployment command selects `IndustrialImaginationGovernedFunding` by default. It extends `IndustrialImaginationSeaDropFunding`, which directly inherits upstream `ERC721SeaDrop` and the shared `FundingCore` ledger. The direct-mint Solady collection is a separate legacy regression target.

## Economics

GROSS_MINT_PRICE is the amount supporters pay per token. SEADROP_FEE_BPS is fixed at deployment. MINT_PRICE, inherited by the funding views, is the net funding principal per token:

`MINT_PRICE = floor(GROSS_MINT_PRICE × (10000 − SEADROP_FEE_BPS) / 10000)`

Upfront and locked shares are computed from that net principal. SeaDrop computes fees on the entire transaction and rounds the fee down. The difference between the actual received payment and quantity × MINT_PRICE goes to roundingSurplus and is paid with the upfront allocation at finalize. This difference is at most one wei per token. No remainder remains stranded after all owner claims and refunds.

For example, three tokens at 100003 wei and a 333-bps fee pay 9990 wei to the fee recipient. The funding contract receives 290019 wei. Each token has a 96672-wei funding principal, split into 29001 wei upfront and 67671 wei locked. The remaining 3 wei joins the upfront payout. A midpoint burn returns 33836 wei, and the vested part goes to the owner.

Minting and payment form a pending settlement. During the mint callback, supply and wallet counts update before safe-mint receiver callbacks. Finalization is blocked until the subsequent exact SeaDrop payout arrives. Underpayment or a reverting receiver reverts the complete mint transaction. Direct ETH and direct funding-contract mint calls are rejected by the adapter.

## Fixed sale settings

The contract pins one SeaDrop implementation, one fee recipient, and the collection itself as payout recipient. The price, fee rate, supply limit, lifetime wallet cap, and mint duration are fixed. enableMint starts the window and registers payout and fee routing. enablePublicMint opens the public drop within that same window. Anyone can finalize after sellout or after expiry. Token approvals and transfers revert. The legacy adapter permits burns after finalization; the current governed collection permits refunds only after holder escape or timed wind-down.

The sale is public-only. Call `SeaDrop.mintPublic` with the collection address, configured fee recipient, recipient and quantity, sending `quantity × GROSS_MINT_PRICE`. A payer different from the recipient needs owner authorization through `updatePayer`. Lifetime recipient wallet limits and cumulative minted supply are enforced; burning frees neither. There is no allowlist builder, setup function, proof tool or enabled allowlist root. Upstream allowlist configuration remains explicitly disabled.

Public-stage updates must match the fixed terms. Other SeaDrop configuration functions that could change the economic terms, install arbitrary allowlist roots, add another SeaDrop, or enable signed/token-gated stages reject calls. The upstream nonvirtual payout setter remains owner-callable: redirecting it prevents further mints; it cannot redirect a successful mint away from the funding ledger. Restore the collection payout to resume. Drop URI and sponsored payers have explicit owner-only setters. This is a constrained custom SeaDrop collection. The deployment event identifies the collection for OpenSea Studio indexing. Confirm the Studio listing and marketplace rendering on the live release.

## Deployment and rehearsal

Build with the pinned Foundry configuration, run npm test, then run:

```sh
node tools/card/seadrop-fork.mjs
```

This starts and closes an ephemeral loopback Anvil fork. Public RPC calls read state. Transactions execute only against the local fork. The script uploads artwork locally through the real ETHFS registry and tests the real SeaDrop public mint path, a sponsored payer, fee receipt, refunds, claims, metadata and owner renderer updates after burns. The report is media/evidence/seadrop-fork.json.

For an explicitly authorized public testnet deployment, the release command requires all sale parameters from the release guide plus:

```sh
export SEADROP_ADDRESS=0x00005EA00Ac477B1030CE78506496e8C2dE24bf5
export SEADROP_FEE_BPS=250
export FEE_RECIPIENT=<approved-fee-recipient-address>
```

The fee value above is an example, not a default. Use the fee recipient and rate agreed for the intended mint route. Run upload, preflight, and deploy for chain 84532 as described in RELEASE.md. The script writes a chain-specific release record. It also records the SeaDrop runtime hash and net principal. Public Base mainnet publishing stays disabled in this tooling.

## Validation

The local suite includes arbitrary prices, fee rates, quantities, single/batch mints and burn-order accounting checks. Tests also cover callback attempts to finalize before settlement, receipt mismatch rollback, disabled allowlist rejection, sponsored recipient limits and soulbound behavior. See the fork report for actual registry and SeaDrop code used.


## One-command public test release with a preview NFT

Run `bash tools/card/deploy-testnet.sh` from the contracts directory. The wrapper installs locked dependencies and prompts for the deployer private key with terminal echo disabled. Fund that wallet with Base Sepolia ETH first.

Release settings are fixed at 2,500 tokens and 0.008 ETH gross per token. Other testnet defaults are 3 per wallet, a 24-hour mint window, 180-day streaming, 30% upfront, and a 250-bps test fee. The deploying wallet is the owner, fee recipient and recipient of the single preview NFT. This fee recipient is for inspecting the test release and is not an OpenSea fee agreement. Environment variables can override the other testnet defaults. Supply, price and holder governance are pinned; conflicting overrides fail before transactions. The automatic setup requires OWNER to match the deployer.

The command builds and tests, checks chain ID 84532, uploads missing assets, deploys, enables minting and public minting, and purchases one NFT through SeaDrop. It saves `media/dist/84532-holder-vote-seadrop-release.json` with collection/renderer addresses, deployment transaction hashes, token ID, mint transaction hash and explorer/marketplace links. It saves the returned metadata alongside the release record. An existing matching release is reused, and a previously minted token is detected on retry to avoid minting another preview.

The command leaves the test collection available for inspection and further minting. Marketplace indexing and rendering must be checked after the public mint completes.

## Reviewed builds and retry safety

The release tooling pins separate canonical SeaDrop runtime hashes for Base and Base Sepolia and checks them before uploads. Those hashes differ; do not substitute one for the other. `foundry.lock` pins the installed `math77/seadrop` fork. Local source tests and canonical-network fork tests are distinct evidence.

Release records contain creation-bytecode fingerprints and deployed runtime hashes. The testnet wrapper refuses an old, missing-fingerprint or mismatched release. Archive the previous release JSON under a different filename before deliberately deploying a new collection. Existing contracts cannot acquire these fixes. The wrapper reads ERC721A's token ID from the collection's own Transfer event.

The November 8 review and remaining risks are recorded in [SECURITY-REVIEW.md](evidence/SECURITY-REVIEW.md). According to the guidance the OpenSea team provided to the collection owner, the collection should auto-index as a Studio mint when its deployment emits `SeaDropTokenDeployed()`. The governed collection emits that event through the inherited `ERC721SeaDrop` constructor. A local regression test checks the event signature and collection address. Confirm the resulting Studio listing and marketplace rendering after public deployment.

## Validated public-stage updates

`updatePublicDrop(seaDropImpl, publicDrop)` accepts the upstream owner-or-self authorization, including calls through `multiConfigure`. Call `enableMint()` first to establish the fixed sale window and register payout routing. The update must target the authorized SeaDrop engine and match all six settings exactly: gross price, start time, end time, lifetime wallet cap, fee basis points and restricted fee recipients (`true`). A successful update enables the local public-mint flag and forwards the configuration to SeaDrop. `enablePublicMint()` remains an alternative that supplies these settings automatically.

The update cannot schedule a different window, change economic terms, disable recipient restrictions or reopen an expired/finalized sale. Read the exact timestamps from `mintStartTime()` and `MINT_PERIOD`; a separately chosen Studio schedule will be rejected. This supports compatible Studio requests, not arbitrary Studio edits. Live UI integration and the actual fee-recipient configuration still need verification on the deployed collection.
