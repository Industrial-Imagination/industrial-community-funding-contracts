// Invoked by the terminal wrapper. All writes target Base Sepolia (84532).
import fs from "node:fs";
import { spawn } from "node:child_process";
import { once } from "node:events";
import assert from "node:assert/strict";
import {
  Contract,
  JsonRpcProvider,
  Wallet,
  ZeroAddress,
  getAddress,
  keccak256,
} from "ethers";
import {
  buildHashes,
  releaseSettings,
  assertReleaseBuild,
  mintedTokenId,
} from "./release-checks.mjs";
assert(process.env.DEPLOYER_KEY, "Run bash tools/card/deploy-testnet.sh");
assert(
  !process.env.FORK_SIMULATION,
  "Unset FORK_SIMULATION for public deployment",
);
const approvedEnv = releaseSettings(process.env);
const rpc = process.env.RPC_URL || "https://sepolia.base.org";
const provider = new JsonRpcProvider(rpc, undefined, {
  cacheTimeout: -1,
  batchMaxCount: 1,
});
provider.pollingInterval = 1500;
try {
  assert.equal(
    Number((await provider.getNetwork()).chainId),
    84532,
    "Expected Base Sepolia",
  );
  const signer = new Wallet(process.env.DEPLOYER_KEY, provider);
  const address = await signer.getAddress();
  const settings = {
    RPC_URL: rpc,
    MAX_SUPPLY: approvedEnv.MAX_SUPPLY,
    MAX_PER_WALLET: "3",
    MINT_PRICE_WEI: approvedEnv.MINT_PRICE_WEI,
    MINT_PERIOD: "86400",
    VESTING_PERIOD: "15552000",
    INITIAL_PAYOUT_BPS: "3000",
    SEADROP_ADDRESS: "0x00005EA00Ac477B1030CE78506496e8C2dE24bf5",
    SEADROP_FEE_BPS: "250",
    OWNER: address,
    FEE_RECIPIENT: address,
  };
  // Testnet operational defaults remain overridable; release supply, price and governance are pinned.
  const env = {
    ...settings,
    ...approvedEnv,
    RPC_URL: rpc,
    FUNDING_PROFILE: "governed",
  };
  assert(
    env.BACKUP_WALLET,
    "Set BACKUP_WALLET to a separate wallet before deployment",
  );
  assert.notEqual(
    getAddress(env.BACKUP_WALLET),
    address,
    "Backup must differ from owner",
  );
  assert.equal(
    getAddress(env.OWNER),
    address,
    "Automatic mint setup requires the deploying wallet as OWNER",
  );
  assert(
    (await provider.getBalance(address)) > BigInt(env.MINT_PRICE_WEI),
    "Fund the deployer with Base Sepolia ETH first",
  );
  console.log(
    "Base Sepolia test release",
    JSON.stringify(
      {
        ...settings,
        ...Object.fromEntries(Object.keys(settings).map((k) => [k, env[k]])),
      },
      null,
      2,
    ),
  );
  console.log("Deployer and NFT recipient:", address);
  async function run(command, args) {
    const child = spawn(command, args, { env, stdio: "inherit" });
    const [code] = await once(child, "exit");
    assert.equal(code, 0, command + " failed");
  }
  await run("npm", ["run", "build"]);
  // Rebuild renderer and its embedded runtime hash together; do not mix cached compiler outputs.
  await run("forge", ["clean"]);
  await run("forge", ["build", "--sizes"]);
  await run("npm", ["test"]);
  const releaseFile = "media/dist/84532-holder-vote-seadrop-release.json";
  const artifact = JSON.parse(
    fs.readFileSync(
      "out/IndustrialImaginationGovernedFunding.sol/IndustrialImaginationGovernedFunding.json",
    ),
  );
  const rendererArtifact = JSON.parse(
    fs.readFileSync("out/FundingCardRenderer.sol/FundingCardRenderer.json"),
  );
  // Check an existing build before any asset uploads or further paid transactions.
  if (fs.existsSync(releaseFile)) {
    const previous = JSON.parse(fs.readFileSync(releaseFile));
    assertReleaseBuild(previous, buildHashes(artifact, rendererArtifact));
    assert.equal(
      keccak256(await provider.getCode(previous.funding)),
      previous.runtimeHashes?.collection,
    );
    assert.equal(
      keccak256(await provider.getCode(previous.renderer)),
      previous.runtimeHashes?.renderer,
    );
  }
  await run(process.execPath, ["tools/card/chain.mjs", "preflight", "84532"]);
  await run(process.execPath, ["tools/card/mint-preflight.mjs"]);
  await run(process.execPath, ["tools/card/chain.mjs", "upload", "84532"]);
  await run(process.execPath, ["tools/card/chain.mjs", "preflight", "84532"]);
  if (!fs.existsSync(releaseFile))
    await run(process.execPath, ["tools/card/chain.mjs", "deploy", "84532"]);
  const release = JSON.parse(fs.readFileSync(releaseFile));
  assert.equal(release.chainId, 84532);
  assert.equal(release.collectionType, "IndustrialImaginationGovernedFunding");
  const funding = new Contract(release.funding, artifact.abi, signer);
  for (const [getter, key] of [
    ["owner", "OWNER"],
    ["FEE_RECIPIENT", "FEE_RECIPIENT"],
    ["SEA_DROP", "SEADROP_ADDRESS"],
  ])
    assert.equal(
      getAddress(await funding[getter]()),
      getAddress(env[key]),
      "Existing release differs in " + key,
    );
  for (const [getter, key] of [
    ["MAX_SUPPLY", "MAX_SUPPLY"],
    ["MAX_PER_WALLET", "MAX_PER_WALLET"],
    ["GROSS_MINT_PRICE", "MINT_PRICE_WEI"],
    ["MINT_PERIOD", "MINT_PERIOD"],
    ["VESTING_PERIOD", "VESTING_PERIOD"],
    ["INITIAL_PAYOUT_BPS", "INITIAL_PAYOUT_BPS"],
    ["SEADROP_FEE_BPS", "SEADROP_FEE_BPS"],
  ])
    assert.equal(
      await funding[getter](),
      BigInt(env[key]),
      "Existing release differs in " + key,
    );
  assert.equal(
    (await funding.metadataRenderer()).toLowerCase(),
    release.renderer.toLowerCase(),
  );
  assert.equal(release.governance, "holder-vote");
  assert.equal(
    getAddress(await funding.council()),
    getAddress(release.council),
  );
  const recovery = new Contract(
    await funding.recovery(),
    JSON.parse(
      fs.readFileSync("out/FundingRecovery.sol/FundingRecovery.json"),
    ).abi,
    signer,
  );
  if (getAddress(await recovery.backup()) !== getAddress(env.BACKUP_WALLET)) {
    assert(
      !(await funding.mintEnabled()),
      "Mint already started without the intended accepted backup",
    );
    if (getAddress(await recovery.nominee()) !== getAddress(env.BACKUP_WALLET))
      await (await recovery.nominateBackup(env.BACKUP_WALLET)).wait();
    console.log(
      `Backup wallet ${env.BACKUP_WALLET} must call acceptBackup() on ${recovery.target}. Rerun this command after acceptance; minting has not started.`,
    );
    throw Error("Waiting for backup-wallet acceptance before starting mint");
  }
  if (!(await funding.mintEnabled())) await (await funding.enableMint()).wait();
  if (!(await funding.publicMintEnabled()))
    await (await funding.enablePublicMint()).wait();
  let tokenId = release.previewMint?.tokenId;
  let transaction = release.previewMint?.transaction;
  if (!tokenId) {
    // Resume safely if a prior run mined the mint before writing its receipt file.
    if ((await funding.totalMinted()) > 0n) {
      assert.equal(
        await funding.ownerOf(1),
        address,
        "First token belongs to another wallet",
      );
      tokenId = "1";
      const events = await funding.queryFilter(
        funding.filters.Transfer(ZeroAddress, address, 1),
        release.fundingDeploymentBlock || 0,
      );
      transaction = events[0]?.transactionHash;
    } else {
      const drop = new Contract(
        env.SEADROP_ADDRESS,
        ["function mintPublic(address,address,address,uint256) payable"],
        signer,
      );
      const receipt = await (
        await drop.mintPublic(
          funding.target,
          env.FEE_RECIPIENT,
          ZeroAddress,
          1,
          { value: BigInt(env.MINT_PRICE_WEI) },
        )
      ).wait();
      tokenId = mintedTokenId(
        receipt,
        funding.target,
        address,
        funding.interface,
      );
      transaction = receipt.hash;
    }
  }
  assert.equal(await funding.ownerOf(tokenId), address);
  const uri = await funding.tokenURI(tokenId, { gasLimit: 50000000 });
  const metadata = JSON.parse(Buffer.from(uri.split(",")[1], "base64"));
  assert(metadata.animation_url.startsWith("data:text/html;"));
  release.previewMint = {
    tokenId,
    recipient: address,
    transaction,
    metadataName: metadata.name,
  };
  release.links = {
    contract: "https://sepolia.basescan.org/address/" + funding.target,
    transaction: "https://sepolia.basescan.org/tx/" + transaction,
    openSea:
      "https://testnets.opensea.io/assets/base-sepolia/" +
      funding.target +
      "/" +
      tokenId,
  };
  fs.writeFileSync(releaseFile, JSON.stringify(release, null, 2) + "\n");
  fs.writeFileSync(
    "media/dist/testnet-governed-token-metadata.json",
    JSON.stringify(metadata),
  );
  console.log("Deployment and one SeaDrop mint complete. Saved " + releaseFile);
  console.log(
    JSON.stringify(
      { collection: funding.target, ...release.previewMint, ...release.links },
      null,
      2,
    ),
  );
} finally {
  await provider.destroy();
}
