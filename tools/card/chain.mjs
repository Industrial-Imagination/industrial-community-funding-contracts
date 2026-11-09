// All commands verify the target chain before obtaining a signer.
import {
  AbiCoder,
  Contract,
  ContractFactory,
  JsonRpcProvider,
  Wallet,
  ZeroAddress,
  concat,
  getBytes,
  getCreate2Address,
  hexlify,
  keccak256,
  toBeHex,
  encodeBytes32String,
  getAddress,
} from "ethers";
import fs from "node:fs";
import assert from "node:assert/strict";
import {
  buildHashes,
  releaseSettings,
  SEA_DROP_ADDRESS,
  assertSeaDropRuntime,
} from "./release-checks.mjs";
const [mode, idArg] = process.argv.slice(2);
assert(
  !process.env.FUNDING_PROFILE ||
    ["legacy", "governed"].includes(process.env.FUNDING_PROFILE),
  "Invalid FUNDING_PROFILE",
);
const id = Number(idArg),
  local = id === 31337;
assert(
  [31337, 84532, 8453].includes(id) &&
    ["preflight", "upload", "deploy", "local"].includes(mode),
);
assert(
  mode === "preflight" || id !== 8453,
  "Mainnet is read-only in this milestone",
);
assert(mode !== "local" || local);
// Legacy selection and alternate economics are test-only, never public release options.
if (
  !local &&
  !process.env.FORK_SIMULATION &&
  ["upload", "deploy"].includes(mode)
) {
  Object.assign(process.env, releaseSettings(process.env));
}

const rpc =
  process.env.RPC_URL ||
  (local
    ? "http://127.0.0.1:8545"
    : id === 8453
      ? "https://mainnet.base.org"
      : "https://sepolia.base.org");
const provider = new JsonRpcProvider(rpc, undefined, {
  cacheTimeout: -1,
  batchMaxCount: 1,
});
assert.equal(Number((await provider.getNetwork()).chainId), id);
// Verify the mint engine before obtaining a signer or paying for any asset uploads.
const checkedBlock = await provider.getBlockNumber();
const seaDropCodeHash = local
  ? null
  : keccak256(await provider.getCode(SEA_DROP_ADDRESS, checkedBlock));
if (!local) assertSeaDropRuntime(id, seaDropCodeHash);
if (process.env.FORK_SIMULATION) {
  assert(
    ["localhost", "127.0.0.1"].includes(new URL(rpc).hostname),
    "Simulation requires loopback RPC",
  );
  assert(
    (await provider.send("web3_clientVersion", []))
      .toLowerCase()
      .includes("anvil"),
    "Simulation requires Anvil",
  );
}
provider.pollingInterval = 100;
const registry = "0xFe1411d6864592549AdE050215482e4385dFa0FB";
const store = new Contract(
  registry,
  [
    "function files(string) view returns(address)",
    "function deployer() view returns(address)",
    "function createFileFromPointers(string,address[],bytes)",
  ],
  provider,
);
const assets = JSON.parse(fs.readFileSync("media/dist/assets.json"));
const paths = [
  "media/vendor/three-r162.txt",
  "media/dist/runtime.txt",
  "media/dist/front.webp",
];
const coder = AbiCoder.defaultAbiCoder(),
  fileType =
    "tuple(uint256 size,tuple(address pointer,uint32 start,uint32 end)[] slices)";
const signer =
  mode === "preflight"
    ? null
    : process.env.DEPLOYER_KEY
      ? new Wallet(process.env.DEPLOYER_KEY, provider)
      : await provider.getSigner();
function init(bytes) {
  return concat([
    "0x61",
    toBeHex(bytes.length + 1, 2),
    "0x80600a3d393df300",
    bytes,
  ]);
}
async function uploadData(bytes) {
  const code = init(bytes);
  if (local) {
    const receipt = await (await signer.sendTransaction({ data: code })).wait();
    return receipt.contractAddress;
  }
  const factory = await store.deployer(),
    salt = encodeBytes32String("EthFS"),
    pointer = getCreate2Address(factory, salt, keccak256(code));
  if ((await provider.getCode(pointer)) === "0x")
    await (
      await signer.sendTransaction({ to: factory, data: concat([salt, code]) })
    ).wait();
  assert.equal(await provider.getCode(pointer), concat(["0x00", bytes]));
  return pointer;
}
async function check(pointer, asset, blockTag) {
  const code = getBytes(await provider.getCode(pointer, blockTag));
  assert(code[0] === 0 && code.length <= 3201);
  const [file] = coder.decode([fileType], code.slice(1));
  assert.equal(
    hexlify(code.slice(1)),
    coder.encode([fileType], [file]),
    "Noncanonical ETHFS descriptor",
  );
  assert.equal(Number(file.size), asset.size);
  assert(file.slices.length > 0 && file.slices.length <= 32);
  const slices = await Promise.all(
    file.slices.map(async (s) => {
      const chunk = getBytes(await provider.getCode(s.pointer, blockTag));
      assert(
        chunk[0] === 0 &&
          s.start >= 1n &&
          s.end > s.start &&
          s.end <= chunk.length,
      );
      return chunk.slice(Number(s.start), Number(s.end));
    }),
  );
  const bytes = getBytes(concat(slices));
  assert.equal(bytes.length, asset.size);
  assert.equal(keccak256(bytes), asset.hash);
}
const block = await provider.getBlockNumber();
const resolved = [];
for (const [i, asset] of assets.entries()) {
  const bytes = fs.readFileSync(paths[i]);
  assert.equal(asset.hash, keccak256(bytes));
  assert.equal(asset.size, bytes.length);
  let pointer = local
    ? ZeroAddress
    : await store.files(asset.filename, { blockTag: block });
  if (pointer === ZeroAddress && ["upload", "local"].includes(mode)) {
    if (!local && i === 0)
      throw Error("Expected pinned Three.js registry entry");
    const slices = [];
    for (let j = 0; j < bytes.length; j += 24000) {
      const chunk = bytes.subarray(j, j + 24000);
      slices.push([await uploadData(chunk), 1, chunk.length + 1]);
    }
    if (local)
      pointer = await uploadData(
        getBytes(coder.encode([fileType], [[bytes.length, slices]])),
      );
    else {
      await (
        await store.connect(signer).createFileFromPointers(
          asset.filename,
          slices.map((s) => s[0]),
          hexlify(
            Buffer.from(
              JSON.stringify({ type: i === 2 ? "image/webp" : "text/plain" }),
            ),
          ),
        )
      ).wait();
      pointer = await store.files(asset.filename);
    }
  }
  if (pointer !== ZeroAddress)
    await check(pointer, asset, mode === "preflight" ? block : "latest");
  resolved.push({
    ...asset,
    pointer: pointer === ZeroAddress ? null : pointer,
    status: pointer === ZeroAddress ? "needs upload" : "verified",
  });
}
const record = {
  chainId: id,
  seaDropCheckedBlock: local ? null : checkedBlock,
  seaDropCodeHash,
  registry: local ? null : registry,
  block,
  assets: resolved,
};
if (!local && !process.env.FORK_SIMULATION)
  fs.writeFileSync(
    "media/dist/" + id + ".json",
    JSON.stringify(record, null, 2) + "\n",
  );
if (["deploy", "local"].includes(mode)) {
  assert(
    resolved.every((a) => a.pointer),
    "Upload missing files first",
  );
  function artifact(name) {
    return JSON.parse(
      fs.readFileSync("out/" + name + ".sol/" + name + ".json"),
    );
  }
  function factory(name) {
    const a = artifact(name);
    return new ContractFactory(a.abi, a.bytecode.object, signer);
  }
  function required(key) {
    assert(process.env[key], key + " required");
    return process.env[key];
  }
  const args =
    mode === "local"
      ? [3, 3, 100003, 100, 1000, 3000, await signer.getAddress()]
      : [
          "MAX_SUPPLY",
          "MAX_PER_WALLET",
          "MINT_PRICE_WEI",
          "MINT_PERIOD",
          "VESTING_PERIOD",
          "INITIAL_PAYOUT_BPS",
          "OWNER",
        ].map(required);
  const seaDropArgs =
    mode === "local"
      ? []
      : [
          required("SEADROP_ADDRESS"),
          required("SEADROP_FEE_BPS"),
          required("FEE_RECIPIENT"),
        ];
  if (seaDropArgs.length) {
    assert.equal(
      seaDropArgs[0].toLowerCase(),
      "0x00005ea00ac477b1030ce78506496e8c2de24bf5",
    );
    assert.notEqual(await provider.getCode(seaDropArgs[0]), "0x");
  }
  const governed = mode !== "local" && process.env.FUNDING_PROFILE !== "legacy";
  const renderer = await factory("FundingCardRenderer").deploy(
    ...resolved.map((a) => [a.pointer, a.hash]),
  );
  await renderer.waitForDeployment();
  const collectionType =
    mode === "local"
      ? "IndustrialImaginationFunding"
      : governed
        ? "IndustrialImaginationGovernedFunding"
        : "IndustrialImaginationSeaDropFunding";
  const funding = await factory(collectionType).deploy(
    ...args,
    renderer.target,
    "Industrial Imagination Funding",
    "IIF",
    ...seaDropArgs,
  );
  await funding.waitForDeployment();
  Object.assign(record, {
    collectionType,
    buildHashes: buildHashes(
      artifact(collectionType),
      artifact("FundingCardRenderer"),
    ),
    runtimeHashes: {
      collection: keccak256(await provider.getCode(funding.target)),
      renderer: keccak256(await provider.getCode(renderer.target)),
    },
    rendererTransaction: renderer.deploymentTransaction().hash,
    fundingTransaction: funding.deploymentTransaction().hash,
    fundingDeploymentBlock: (await funding.deploymentTransaction().wait())
      .blockNumber,
    renderer: renderer.target,
    funding: funding.target,
  });
  if (seaDropArgs.length)
    Object.assign(record, {
      seaDrop: seaDropArgs[0],
      seaDropCodeHash: keccak256(await provider.getCode(seaDropArgs[0])),
      feeRecipient: seaDropArgs[2],
      feeBps: Number(seaDropArgs[1]),
      grossPrice: String(args[2]),
      netPrincipalPerToken: String(await funding.MINT_PRICE()),
    });
  if (governed)
    Object.assign(record, {
      council: await funding.council(),
      governance: "holder-vote",
    });
  if (!local && !process.env.FORK_SIMULATION)
    fs.writeFileSync(
      "media/dist/" +
        id +
        (governed ? "-holder-vote-seadrop-release.json" : "-release.json"),
      JSON.stringify(record, null, 2) + "\n",
    );
  if (mode === "local") {
    await (await funding.enableMint()).wait();
    await (await funding.enablePublicMint()).wait();
    await (await funding.mint(3, { value: 300009 })).wait();
    const uri = await funding.tokenURI(1, { gasLimit: 50000000 });
    const decode = (u) => Buffer.from(u.split(",")[1], "base64");
    const json = JSON.parse(decode(uri));
    assert.equal(json.name, "Industrial Imagination Funding #1");
    assert(json.animation_url.startsWith("data:text/html;charset=utf-8,"));
    const html = Buffer.from(
      decodeURIComponent(
        json.animation_url.slice(json.animation_url.indexOf(",") + 1),
      ),
    );
    assert.deepEqual(html, fs.readFileSync("media/dist/inspect.html"));
    assert(
      decode(json.image)
        .toString()
        .includes(fs.readFileSync(paths[2]).toString("base64")),
    );
    fs.writeFileSync("media/dist/token.html", html);
    fs.writeFileSync("media/dist/animation.uri", json.animation_url);
    record.gas = Number(await funding.tokenURI.estimateGas(1));
    record.tokenURIBytes = uri.length;
    record.htmlBytes = html.length;
    console.log("measured gas", record.gas);
    assert(record.gas < 50000000);
    await (await funding.finalize()).wait();
    await (await funding.burn(2)).wait();
    await (await funding.setMetadataRenderer(renderer.target)).wait();
    fs.writeFileSync(
      "media/evidence/anvil.json",
      JSON.stringify(record, null, 2) + "\n",
    );
  }
}
console.log(JSON.stringify(record));
await provider.destroy();
