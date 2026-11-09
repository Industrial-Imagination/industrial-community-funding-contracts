// Rehearse the intended Base Sepolia configuration on an ephemeral loopback fork.
// No private key is used or forwarded; all state-changing calls target the child Anvil.
import { spawn } from "node:child_process";
import { once } from "node:events";
import net from "node:net";
import fs from "node:fs";
import assert from "node:assert/strict";
import {
  Contract,
  JsonRpcProvider,
  ZeroAddress,
  toBeHex,
  getAddress,
} from "ethers";
const keys = [
  "OWNER",
  "MAX_SUPPLY",
  "MAX_PER_WALLET",
  "MINT_PRICE_WEI",
  "MINT_PERIOD",
  "VESTING_PERIOD",
  "INITIAL_PAYOUT_BPS",
  "SEADROP_ADDRESS",
  "SEADROP_FEE_BPS",
  "FEE_RECIPIENT",
  "BACKUP_WALLET",
];
const settings = Object.fromEntries(
  keys.map((k) => {
    assert(process.env[k], `${k} required`);
    return [k, process.env[k]];
  }),
);
assert.notEqual(getAddress(settings.OWNER), getAddress(settings.BACKUP_WALLET));
const remote = new JsonRpcProvider(
  process.env.RPC_URL || "https://sepolia.base.org",
  undefined,
  { batchMaxCount: 1 },
);
assert.equal(
  Number((await remote.getNetwork()).chainId),
  84532,
  "Expected Base Sepolia source",
);
const block = await remote.getBlockNumber();
await remote.destroy();
const socket = net.createServer();
socket.listen(0, "127.0.0.1");
await once(socket, "listening");
const port = socket.address().port;
socket.close();
await once(socket, "close");
const rpc = `http://127.0.0.1:${port}`;
const anvil = spawn(
  "anvil",
  [
    "--host",
    "127.0.0.1",
    "--port",
    String(port),
    "--fork-url",
    process.env.RPC_URL || "https://sepolia.base.org",
    "--fork-block-number",
    String(block),
    "--chain-id",
    "84532",
    "--silent",
  ],
  { stdio: ["ignore", "ignore", "pipe"] },
);
let startupError = "";
anvil.stderr.on("data", (d) => (startupError += d));
const provider = new JsonRpcProvider(rpc, 84532, {
  staticNetwork: true,
  batchMaxCount: 1,
  cacheTimeout: -1,
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
    if (anvil.exitCode !== null) break;
    await new Promise((r) => setTimeout(r, 100));
  }
  assert(ready, `Local fork failed to start: ${startupError}`);
  assert(
    (await provider.send("web3_clientVersion", []))
      .toLowerCase()
      .includes("anvil"),
  );
  const env = {
    ...process.env,
    ...settings,
    RPC_URL: rpc,
    FORK_SIMULATION: "1",
    FUNDING_PROFILE: "governed",
    DEPLOYER_KEY: "",
  };
  async function command(action) {
    const child = spawn(
      process.execPath,
      ["tools/card/chain.mjs", action, "84532"],
      { env },
    );
    let out = "",
      err = "";
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    const [code] = await once(child, "exit");
    assert.equal(code, 0, err);
    return JSON.parse(out.trim().split("\n").at(-1));
  }
  await command("upload");
  const release = await command("deploy");
  async function impersonate(address) {
    await provider.send("anvil_impersonateAccount", [address]);
    await provider.send("anvil_setBalance", [address, toBeHex(10n ** 30n)]);
    return provider.getSigner(address);
  }
  const owner = await impersonate(settings.OWNER),
    backup = await impersonate(settings.BACKUP_WALLET);
  const artifact = JSON.parse(
    fs.readFileSync(
      "out/IndustrialImaginationGovernedFunding.sol/IndustrialImaginationGovernedFunding.json",
    ),
  );
  const funding = new Contract(release.funding, artifact.abi, owner);
  const recovery = new Contract(
    await funding.recovery(),
    JSON.parse(
      fs.readFileSync("out/FundingRecovery.sol/FundingRecovery.json"),
    ).abi,
    owner,
  );
  await (await recovery.nominateBackup(settings.BACKUP_WALLET)).wait();
  await (await recovery.connect(backup).acceptBackup()).wait();
  assert.equal(
    getAddress(await recovery.backup()),
    getAddress(settings.BACKUP_WALLET),
  );
  await (await funding.enableMint()).wait();
  await (await funding.enablePublicMint()).wait();
  const buyer = await provider.getSigner(8);
  const price = BigInt(settings.MINT_PRICE_WEI),
    fee = BigInt(settings.SEADROP_FEE_BPS);
  await provider.send("anvil_setBalance", [
    await buyer.getAddress(),
    toBeHex(price * 4n + 10n ** 20n),
  ]);
  const drop = new Contract(
    settings.SEADROP_ADDRESS,
    ["function mintPublic(address,address,address,uint256) payable"],
    buyer,
  );
  const quantities = [1n];
  if (
    BigInt(settings.MAX_SUPPLY) >= 3n &&
    BigInt(settings.MAX_PER_WALLET) >= 3n
  )
    quantities.push(2n);
  let total = 0n;
  for (const q of quantities) {
    const gross = price * q,
      expected = gross - (gross * fee) / 10000n;
    const before = await provider.getBalance(funding.target);
    await (
      await drop.mintPublic(
        funding.target,
        settings.FEE_RECIPIENT,
        ZeroAddress,
        q,
        { value: gross },
      )
    ).wait();
    assert.equal(
      (await provider.getBalance(funding.target)) - before,
      expected,
    );
    assert.equal(await funding.pendingNetProceeds(), 0n);
    total += expected;
  }
  assert.equal(await funding.totalNetReceived(), total);
  const report = {
    chainId: 84532,
    sourceBlock: block,
    publicTransactions: false,
    settings,
    quantities: quantities.map(String),
    netReceived: String(total),
    release,
  };
  fs.writeFileSync(
    "media/evidence/mint-preflight.json",
    JSON.stringify(report, null, 2) + "\n",
  );
  console.log(
    "Mint preflight passed: fee recipient accepted payment and exact net proceeds settled on the local fork.",
  );
} finally {
  await provider.destroy();
  anvil.kill();
}
