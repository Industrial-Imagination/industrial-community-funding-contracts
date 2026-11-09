# Industrial Imagination platinum funding card

The current governed release uses monthly NFT holder votes, isolated below-quorum fallback payments and terminal refunds. See the [governance guide](GOVERNANCE.md) for the current lifecycle and Base Sepolia deployment. The earlier direct-mint and continuous SeaDrop policies are local regression targets only. Public release tooling pins holder governance, 2,500 supply and 0.008 ETH gross per NFT. See [production configuration](PRODUCTION.md).


Run commands from the Foundry repository (`contracts/`). Requires Node 23.8.0, Foundry, solc 0.8.38 and Chromium. The npm lockfile pins the media tools. On macOS the browser runner uses installed Chrome. On Linux use `npx playwright-core install --with-deps chromium`, or supply an absolute `CHROME_BIN`.

## Build and inspect

```sh
npm ci
npm run build
forge fmt --check
forge clean
forge build --sizes
npm test
npm run local
npm run browser
```

Open `media/dist/inspect.html` for the standalone preview, or `media/dist/token.html` for the exact player returned by the local mint. Drag horizontally to rotate or vertically to tilt. Arrow keys inspect, Space toggles pause, and Home resets. Reduced motion disables automatic turns. The 24-second cycle holds the front and back for two seconds each.

The build uses the project copy of the supplied logo, the Latin WOFF2 subset of IBM Plex Mono Medium, the pinned ETHFS Three.js module, and the committed 900-pixel WebP front view. Source notices ship in the runtime. `npm run preview` captures a new poster from the built scene and rebuilds the package. Refresh evidence with `npm run local && npm run browser` after artwork edits. The poster is a reviewed binary input to reproducible builds. Different GPU/browser versions can yield different raster pixels.

The local command launches a fresh loopback Anvil instance, writes STOP-prefixed chunks and ETHFS File descriptors, deploys the renderer and collection, mints three tokens, decodes a real token URI, checks its HTML and preview, finalizes, burns a token, checks that the owner can select a renderer after the burn, and closes Anvil. The local addresses in the evidence are ephemeral.

## Chain preflight

```sh
node tools/card/chain.mjs preflight 84532
node tools/card/chain.mjs preflight 8453
```

These calls first verify the network-specific canonical SeaDrop runtime hash, then read the FileStore at a recorded block, validate every slice and compare the reconstructed bytes against the local manifest. They save a report under `media/dist/<chainId>.json`. Runtime and preview filenames contain content hashes. Asset availability is reported by each current preflight. Missing descriptors stay null until uploaded. The decoded module SHA-256 is pinned in the build script.

## Rehearse Base Sepolia

Start a private Anvil fork backed by a Base Sepolia RPC, with chain ID 84532. In a separate shell point `RPC_URL` to the local fork, set `FORK_SIMULATION=1`, leave `DEPLOYER_KEY` unset, and set explicit sale parameters. For example, for a disposable local rehearsal:

```sh
anvil --fork-url https://sepolia.base.org --chain-id 84532 --port 8546
# Separate shell
export RPC_URL=http://127.0.0.1:8546 FORK_SIMULATION=1
unset DEPLOYER_KEY
export MAX_SUPPLY=3 MAX_PER_WALLET=3 MINT_PRICE_WEI=100003
export MINT_PERIOD=100 VESTING_PERIOD=1000 INITIAL_PAYOUT_BPS=3000
export SEADROP_ADDRESS=0x00005EA00Ac477B1030CE78506496e8C2dE24bf5
export SEADROP_FEE_BPS=333 FEE_RECIPIENT=0x0000000000000000000000000000000000000FEE
export OWNER=$(cast rpc --rpc-url "$RPC_URL" eth_accounts | jq -r '.[0]')
node tools/card/chain.mjs upload 84532
node tools/card/chain.mjs deploy 84532
```

Upload uses the registry's deterministic chunk deployer, checks existing chunk bytes, and registers the assembled pointers. A rerun reuses existing matching files and chunks. Deployment refuses incomplete or mismatched assets and prints renderer and funding addresses. Each invocation of `deploy` creates a fresh release. Save the addresses from its output.

The release command deploys the holder-governed SeaDrop collection by default. The local `npm run local` demonstration uses the original direct-mint base. Run `npm run test:governed:fork` for the production lifecycle rehearsal against canonical SeaDrop. `test:seadrop:fork` covers only the underlying continuous-policy adapter. See [SeaDrop release details](SEADROP.md).

## Later public test

For a separately authorized Sepolia release, use a Base Sepolia RPC, unset `FORK_SIMULATION`, and supply the deployer credential locally plus explicit `OWNER`, `MAX_PER_WALLET`, `MINT_PERIOD`, `VESTING_PERIOD`, and `INITIAL_PAYOUT_BPS`, plus `SEADROP_ADDRESS`, `SEADROP_FEE_BPS`, and `FEE_RECIPIENT` as described in the SeaDrop guide. Run preflight, upload, preflight again, then deploy. Only the 84532 command can publish to a public network. Supply and gross price default to the approved release pins; conflicting overrides or a legacy profile are rejected before upload/deployment.

From the owner account, enable minting and public minting. Mint through SeaDrop with the exact gross price from a test holder, read `tokenURI` through the target provider, inspect the decoded image and HTML in the intended viewers, and test drag/rotation on an actual device. Finalize after sellout or expiry. Call `startPeriod()` as the owner. Test a closed review approval and its cycle claim, then either a separate holder escape ballot following two rejections or a timed wind-down. Only after exit can holders burn for refunds; compare each with `getRemainingLockedEth`. Confirm the intended renderer through `metadataRenderer()`. The owner may replace it at any time with `setMetadataRenderer(address)`. A subsequent Base mainnet release retains the approved supply and price and needs its own review of the remaining funding parameters.

The renderer combines ETHFS files into Base64 JSON with an SVG/WebP image and a percent-encoded HTML data URI. The browser receives the complete library and runtime in that HTML. The same image provides the WebGL fallback. See `media/evidence/` for measurements, screenshots and recording.

## Security regression commands

```sh
forge clean
forge build --sizes
forge test --fuzz-runs 2048 -vv
node --test tools/card/*.test.mjs
FOUNDRY_ISOLATE=false TEST_CANONICAL_SEADROP=true forge test --match-contract SecurityTest --fork-url https://sepolia.base.org -vv
FOUNDRY_ISOLATE=false TEST_CANONICAL_SEADROP=true forge test --match-contract SecurityTest --fork-url https://mainnet.base.org -vv
npm run test:governed:fork
```

Fork accounting tests disable Foundry isolation so transaction fee charging does not contaminate exact wei comparisons; the Anvil rehearsal separately exercises actual local transactions. The `forge test --fork-url` commands read public state and execute transactions exclusively in the local test EVM. They do not broadcast. For repeatable historical runs, add the recorded `--fork-block-number` from the security report.

The one-command testnet wrapper rejects an existing release from a different build, including old records without compiler fingerprints. Archive that JSON explicitly to create a new release; the wrapper never upgrades an existing contract.

## Backup consent and mint preflight

Set `BACKUP_WALLET` to a separate wallet before running `npm run deploy:testnet`. Keep its key separate from the deployer key; the wrapper never requests it.

Before public uploads/deployment, the wrapper now starts an ephemeral Base Sepolia Anvil fork, deploys the intended build with the supplied economics and fee recipient, simulates backup consent, and mints through canonical SeaDrop. It checks the exact net receipt and empty pending-settlement balance. When supply and wallet limits permit, it tests both a single mint and a two-token batch. Failure stops the wrapper before public uploads. Evidence is saved to `media/evidence/mint-preflight.json`.

For the standalone read-only rehearsal, supply the same explicit economic settings, `OWNER`, `FEE_RECIPIENT`, `SEADROP_ADDRESS`, and `BACKUP_WALLET`, then run:

```sh
node tools/card/mint-preflight.mjs
```

No private key is needed for this command. The remote RPC is used only to read state; account impersonation and all writes are confined to the new loopback Anvil. The simulated collection has a disposable address, so address-dependent fee policies and future recipient behavior still need consideration. This command currently targets Base Sepolia; public Base deployment remains disabled.

After actual deployment, the wrapper nominates the backup and stops before minting. From the backup wallet, call `acceptBackup()` on the printed recovery-helper address, then rerun the same deployment command. The saved release is reused after build/configuration checks, and minting starts only after the intended backup has accepted. The intentional pause is required because the owner cannot consent on behalf of a separately controlled wallet.
