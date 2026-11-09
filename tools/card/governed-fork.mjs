// Transactions execute only on the ephemeral loopback Anvil fork.
import { spawn } from "node:child_process";
import { once } from "node:events";
import net from "node:net";
import fs from "node:fs";
import assert from "node:assert/strict";
import { Contract, JsonRpcProvider, ZeroAddress, keccak256 } from "ethers";
const portServer = net.createServer();
portServer.listen(0, "127.0.0.1");
await once(portServer, "listening");
const port = portServer.address().port;
portServer.close();
await once(portServer, "close");
const rpc = "http://127.0.0.1:" + port;
const source = process.env.FORK_RPC_URL || "https://sepolia.base.org";
const anvil = spawn(
  "anvil",
  [
    "--host",
    "127.0.0.1",
    "--port",
    String(port),
    "--chain-id",
    "84532",
    "--fork-url",
    source,
    "--silent",
  ],
  { stdio: ["ignore", "ignore", "inherit"] },
);
const provider = new JsonRpcProvider(rpc, 84532, {
  cacheTimeout: -1,
  batchMaxCount: 1,
});
provider.pollingInterval = 100;
try {
  let ready = false;
  for (let i = 0; i < 200; i++) {
    try {
      await provider.getBlockNumber();
      ready = true;
      break;
    } catch {}
    await new Promise((r) => setTimeout(r, 100));
  }
  assert(ready, "Fork did not start");
  const forkBlock = await provider.getBlockNumber();
  const owner = await provider.getSigner(0),
    holder = await provider.getSigner(1),
    payer = await provider.getSigner(2),
    fee = await provider.getSigner(3);
  const env = {
    ...process.env,
    RPC_URL: rpc,
    FORK_SIMULATION: "1",
    FUNDING_PROFILE: "governed",
    DEPLOYER_KEY: "",
    MAX_SUPPLY: "3",
    MAX_PER_WALLET: "3",
    MINT_PRICE_WEI: "100003",
    MINT_PERIOD: "1000",
    VESTING_PERIOD: "15552000",
    INITIAL_PAYOUT_BPS: "3000",
    OWNER: await owner.getAddress(),
    SEADROP_ADDRESS: "0x00005EA00Ac477B1030CE78506496e8C2dE24bf5",
    SEADROP_FEE_BPS: "333",
    FEE_RECIPIENT: await fee.getAddress(),
  };
  async function command(action) {
    const process = spawn(
      globalThis.process.execPath,
      ["tools/card/chain.mjs", action, "84532"],
      { env },
    );
    let output = "",
      error = "";
    process.stdout.on("data", (d) => (output += d));
    process.stderr.on("data", (d) => (error += d));
    const [code] = await once(process, "exit");
    assert.equal(code, 0, error);
    return JSON.parse(output.trim().split("\n").at(-1));
  }
  await command("upload");
  const release = await command("deploy");
  const artifact = JSON.parse(
    fs.readFileSync(
      "out/IndustrialImaginationGovernedFunding.sol/IndustrialImaginationGovernedFunding.json",
    ),
  );
  const funding = new Contract(release.funding, artifact.abi, owner);
  const councilArtifact = JSON.parse(
    fs.readFileSync("out/FundingCouncil.sol/FundingCouncil.json"),
  );
  const council = new Contract(
    await funding.council(),
    councilArtifact.abi,
    owner,
  );
  const drop = new Contract(
    env.SEADROP_ADDRESS,
    ["function mintPublic(address,address,address,uint256) payable"],
    holder,
  );
  await (await funding.enableMint()).wait();
  await (await funding.enablePublicMint()).wait();
  await (
    await drop.mintPublic(funding.target, env.FEE_RECIPIENT, ZeroAddress, 3, {
      value: 300009,
    })
  ).wait();
  await assert.rejects(funding.startPeriod.staticCall());
  const uri = await funding.tokenURI(1, { gasLimit: 50000000 });
  const metadata = JSON.parse(Buffer.from(uri.split(",")[1], "base64"));
  const html = Buffer.from(
    decodeURIComponent(
      metadata.animation_url.slice(metadata.animation_url.indexOf(",") + 1),
    ),
  );
  assert.deepEqual(html, fs.readFileSync("media/dist/inspect.html"));
  const metadataGas = await funding.tokenURI.estimateGas(1);
  assert(metadataGas < 50000000n);
  await (await funding.connect(payer).finalize()).wait();
  const net = await funding.totalNetReceived(),
    upfront = await funding.ownerPaidAmount();
  assert.equal(
    upfront,
    3n * (await funding.INITIAL_PAYOUT_PER_TOKEN()) +
      (await funding.roundingSurplus()),
  );
  assert.equal(await funding.vestingStartTime(), 0n);
  assert.equal(await funding.vestingEndTime(), 0n);
  await (await funding.startPeriod()).wait();
  const start = await council.periodStart(),
    day = 86400n;
  await assert.rejects(funding.connect(holder).burn.staticCall(1));
  async function warp(t) {
    await provider.send("evm_setNextBlockTimestamp", [Number(t)]);
    await provider.send("evm_mine", []);
  }
  async function review(cycle, approve) {
    await warp(start + BigInt(cycle) * 30n * day);
    await (await council.connect(holder).voteReview(cycle, [1, 2], approve)).wait();
    await warp(await council.reviewDeadline(cycle));
  }
  await review(1, true);
  await (await funding.claimOwnerShare()).wait();
  const paid = await funding.ownerPaidAmount(),
    locked = await funding.LOCKED_PER_TOKEN();
  assert.equal(paid - upfront, 3n * (locked / 6n));
  await review(2, false);
  await warp(start + 67n * day);
  assert.equal(await funding.pendingOwnerShare(), 0n);
  await (await funding.claimOwnerShare()).wait();
  assert.equal(await funding.ownerPaidAmount(), paid);
  await review(3, false);
  assert.equal(await council.escapeActivated(), false);
  await (await council.connect(holder).openEscapeVote(3, 1)).wait();
  await (await council.connect(holder).voteEscape(1, [1, 2], true)).wait();
  assert.equal(await council.escapeActivated(), false);
  const pool = await provider.getBalance(funding.target);
  const ballot = await council.escapeBallots(1);
  await warp(ballot.startedAt + 3n * day);
  await (await council.connect(payer).executeEscape(1)).wait();
  assert.equal(await council.escapeActivated(), true);
  assert.equal(await funding.escapePoolAtActivation(), pool);
  await assert.rejects(funding.claimOwnerShare.staticCall());
  let refunds = 0n;
  for (const tokenId of [1, 2, 3]) {
    const receipt = await (await funding.connect(holder).burn(tokenId)).wait();
    const event = receipt.logs
      .map((l) => {
        try {
          return funding.interface.parseLog(l);
        } catch {
          return null;
        }
      })
      .find((e) => e?.name === "Burned");
    refunds += event.args.refund;
  }
  assert.equal(refunds, pool);
  assert.equal(paid + refunds, net);
  assert.equal(await provider.getBalance(funding.target), 0n);
  assert.equal(await funding.activeSupply(), 0n);
  await (await funding.setMetadataRenderer(release.renderer)).wait();
  await assert.rejects(funding.tokenURI(1));
  const report = {
    forkBlock,
    publicTransactions: false,
    release,
    council: await funding.council(),
    periodStart: start,
    netReceived: net,
    upfront,
    firstCyclePayment: paid - upfront,
    escapePool: pool,
    refunds,
    metadataGas,
    htmlHash: keccak256(html),
    finalBalance: 0,
    checks: [
      "real SeaDrop funded mint",
      "upfront without review",
      "manual stream start after finalization",
      "30-day approval and capped claim",
      "explicit rejection blocks fallback",
      "two consecutive rejections",
      "separate majority escape vote",
      "owner claims stopped",
      "all remaining ETH refunded",
      "NFTs burned",
      "exact conservation",
      "same embedded card player",
    ],
  };
  fs.writeFileSync(
    "media/evidence/holder-vote-fork.json",
    JSON.stringify(
      report,
      (_, v) => (typeof v === "bigint" ? v.toString() : v),
      2,
    ) + "\n",
  );
  console.log(
    "Governed SeaDrop fork passed",
    JSON.stringify({
      net: String(net),
      paid: String(paid),
      refunded: String(refunds),
      metadataGas: String(metadataGas),
    }),
  );
} finally {
  await provider.destroy();
  anvil.kill();
}
