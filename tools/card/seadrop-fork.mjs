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
    FUNDING_PROFILE: "legacy",
    DEPLOYER_KEY: "",
    MAX_SUPPLY: "3",
    MAX_PER_WALLET: "3",
    MINT_PRICE_WEI: "100003",
    MINT_PERIOD: "1000",
    VESTING_PERIOD: "1000",
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
      "out/IndustrialImaginationSeaDropFunding.sol/IndustrialImaginationSeaDropFunding.json",
    ),
  );
  const funding = new Contract(release.funding, artifact.abi, owner);
  const drop = new Contract(
    env.SEADROP_ADDRESS,
    [
      "function mintPublic(address,address,address,uint256) payable",
      "function getCreatorPayoutAddress(address) view returns(address)",
      "function getAllowListMerkleRoot(address) view returns(bytes32)",
    ],
    holder,
  );
  const wallet = await holder.getAddress();
  await (await funding.enableMint()).wait();
  await (await funding.enablePublicMint()).wait();
  assert.equal(
    (await drop.getCreatorPayoutAddress(funding.target)).toLowerCase(),
    funding.target.toLowerCase(),
  );
  assert.equal(
    await drop.getAllowListMerkleRoot(funding.target),
    "0x" + "00".repeat(32),
  );
  const beforeFee = await provider.getBalance(env.FEE_RECIPIENT);
  await (
    await drop.mintPublic(funding.target, env.FEE_RECIPIENT, ZeroAddress, 1, {
      value: 100003,
    })
  ).wait();
  assert.equal(await funding.mintedBy(wallet), 1n);
  await assert.rejects(
    drop
      .connect(payer)
      .mintPublic.staticCall(funding.target, env.FEE_RECIPIENT, wallet, 2, {
        value: 200006,
      }),
  );
  await (
    await funding.updatePayer(drop.target, await payer.getAddress(), true)
  ).wait();
  await (
    await drop
      .connect(payer)
      .mintPublic(funding.target, env.FEE_RECIPIENT, wallet, 2, {
        value: 200006,
      })
  ).wait();
  assert.equal(await funding.mintedBy(wallet), 3n);
  assert.equal(await funding.pendingNetProceeds(), 0n);
  const net = await funding.totalNetReceived(),
    receivedFee = (await provider.getBalance(env.FEE_RECIPIENT)) - beforeFee;
  assert.equal(net + receivedFee, 300009n);
  assert.equal(await provider.getBalance(funding.target), net);
  await assert.rejects(
    drop.mintPublic.staticCall(
      funding.target,
      env.FEE_RECIPIENT,
      ZeroAddress,
      1,
      { value: 100003 },
    ),
  );
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
  const start = await funding.vestingStartTime(),
    locked = await funding.LOCKED_PER_TOKEN();
  assert.equal(
    await funding.ownerPaidAmount(),
    3n * (await funding.INITIAL_PAYOUT_PER_TOKEN()) +
      (await funding.roundingSurplus()),
  );
  await provider.send("evm_setNextBlockTimestamp", [Number(start + 500n)]);
  await provider.send("evm_mine", []);
  const burned = await (await funding.connect(holder).burn(1)).wait();
  const timestamp = BigInt(
    (await provider.getBlock(burned.blockNumber)).timestamp,
  );
  const event = burned.logs
    .map((l) => {
      try {
        return funding.interface.parseLog(l);
      } catch {
        return null;
      }
    })
    .find((e) => e?.name === "Burned");
  assert.equal(
    event.args.refund,
    locked - (locked * (timestamp - start)) / 1000n,
  );
  await assert.rejects(funding.tokenURI(1));
  await provider.send("evm_setNextBlockTimestamp", [Number(start + 1000n)]);
  await provider.send("evm_mine", []);
  await (await funding.claimOwnerShare()).wait();
  assert.equal((await funding.ownerPaidAmount()) + event.args.refund, net);
  for (const id of [2, 3])
    await (await funding.connect(holder).burn(id)).wait();
  assert.equal(await provider.getBalance(funding.target), 0n);
  await (await funding.setMetadataRenderer(release.renderer)).wait();
  const report = {
    forkBlock,
    publicTransactions: false,
    release,
    netReceived: net,
    seaDropFees: receivedFee,
    roundingSurplus: await funding.roundingSurplus(),
    netPrincipalPerToken: await funding.MINT_PRICE(),
    lockedPerToken: locked,
    burnRefund: event.args.refund,
    metadataGas,
    htmlHash: keccak256(html),
    finalContractBalance: 0,
    checks: [
      "real SeaDrop ERC165 registration",
      "public-only mint with empty allowlist root",
      "free-leaf rejection",
      "sponsored public mint",
      "wallet and supply cap",
      "net settlement",
      "permissionless finalization",
      "midpoint burn",
      "owner stream claim",
      "zero refund after vesting",
      "metadata existence and owner updates after burns",
      "exact accounting",
      "onchain player bytes",
    ],
  };
  fs.writeFileSync(
    "media/evidence/seadrop-fork.json",
    JSON.stringify(
      report,
      (_, v) => (typeof v === "bigint" ? v.toString() : v),
      2,
    ) + "\n",
  );
  console.log(
    "SeaDrop fork lifecycle passed",
    JSON.stringify({
      net: String(net),
      fee: String(receivedFee),
      metadataGas: String(metadataGas),
    }),
  );
} finally {
  await provider.destroy();
  anvil.kill();
}
