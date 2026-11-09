import { test } from "node:test";
import assert from "node:assert/strict";
import { Interface, ZeroAddress } from "ethers";
import {
  buildHashes,
  releaseSettings,
  PRODUCTION_SALE,
  assertReleaseBuild,
  mintedTokenId,
  assertSeaDropRuntime,
  SEA_DROP_RUNTIME_HASHES,
} from "./release-checks.mjs";

const collection = "0x0000000000000000000000000000000000000001";
const recipient = "0x0000000000000000000000000000000000000002";
const other = "0x0000000000000000000000000000000000000003";
const abi = new Interface([
  "event Transfer(address indexed from,address indexed to,uint256 indexed tokenId)",
]);
const mint = (address, from = ZeroAddress) => ({
  address,
  ...abi.encodeEventLog(abi.getEvent("Transfer"), [from, recipient, 17]),
});

test("ERC721A preview mint reads tokenId and ignores other contracts' events", () => {
  assert.equal(
    mintedTokenId(
      { logs: [mint(other), mint(collection)] },
      collection,
      recipient,
      abi,
    ),
    "17",
  );
  assert.throws(() =>
    mintedTokenId(
      { logs: [mint(other), mint(collection, other)] },
      collection,
      recipient,
      abi,
    ),
  );
});

test("release retries reject missing or changed compiler fingerprints", () => {
  const artifact = { bytecode: { object: "0x6000" } };
  const expected = buildHashes(artifact, artifact);
  assertReleaseBuild({ buildHashes: expected }, expected);
  assert.throws(() => assertReleaseBuild({}, expected));
  assert.throws(() =>
    assertReleaseBuild(
      { buildHashes: expected },
      buildHashes({ bytecode: { object: "0x6001" } }, artifact),
    ),
  );
});

test("SeaDrop dependency pins are chain-specific and fail closed", () => {
  assertSeaDropRuntime(84532, SEA_DROP_RUNTIME_HASHES[84532]);
  assertSeaDropRuntime(8453, SEA_DROP_RUNTIME_HASHES[8453]);
  assert.throws(() =>
    assertSeaDropRuntime(8453, SEA_DROP_RUNTIME_HASHES[84532]),
  );
  assert.throws(() => assertSeaDropRuntime(1, SEA_DROP_RUNTIME_HASHES[8453]));
});

test("public releases pin holder governance, 2500 supply and 0.008 ETH before writes", () => {
  assert.deepEqual(releaseSettings({}), PRODUCTION_SALE);
  assert.equal(releaseSettings({ OWNER: recipient }).OWNER, recipient);
  assert.deepEqual(releaseSettings(PRODUCTION_SALE), PRODUCTION_SALE);
  for (const override of [
    { FUNDING_PROFILE: "legacy" },
    { MAX_SUPPLY: "10" },
    { MINT_PRICE_WEI: "100000000000000" },
  ])
    assert.throws(() => releaseSettings(override));
  assert.equal(
    BigInt(PRODUCTION_SALE.MAX_SUPPLY) * BigInt(PRODUCTION_SALE.MINT_PRICE_WEI),
    20n * 10n ** 18n,
  );
});
