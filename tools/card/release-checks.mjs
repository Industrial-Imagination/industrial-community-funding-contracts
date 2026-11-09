// Pure release checks shared by deployment and offline regression tests.
import assert from "node:assert/strict";
import { getAddress, keccak256, ZeroAddress } from "ethers";

export const SEA_DROP_ADDRESS = "0x00005EA00Ac477B1030CE78506496e8C2dE24bf5";
// Read from the canonical address on 2026-11-08. Network-specific immutable data
// means identical protocol logic need not have an identical runtime hash.
export const SEA_DROP_RUNTIME_HASHES = Object.freeze({
  84532: "0x7ebd6750c54fd6e4667af4d3310cf02bc420606f6e3eaed9654127047f5166c0", // block 56151877
  8453: "0x2151e8d092f04e5cf00576bf5e6b92a0fc15b0013dc8c08b68934048d39ac1fc", // block 54809346
});

/** A canonical address alone is insufficient: reject missing or unexpected bytecode. */
export function assertSeaDropRuntime(chainId, codeHash) {
  assert(SEA_DROP_RUNTIME_HASHES[chainId], "Unreviewed SeaDrop network");
  assert.equal(
    codeHash,
    SEA_DROP_RUNTIME_HASHES[chainId],
    "SeaDrop runtime differs from the reviewed network pin",
  );
}

/** Identify the exact compiler output, including constructor code and embedded helpers. */
export function buildHashes(collection, renderer) {
  return {
    collection: keccak256(collection.bytecode.object),
    renderer: keccak256(renderer.bytecode.object),
  };
}

/** Refuse to resume an older build after a fix; existing deployments cannot be patched. */
export function assertReleaseBuild(release, expected) {
  assert.deepEqual(
    release.buildHashes,
    expected,
    "Existing release is a different or unrecorded build. Archive its release JSON and deploy a new collection; do not reuse it for these fixes.",
  );
}

/** Select only this collection's mint event, using the ERC721A Transfer ABI. */
export function mintedTokenId(receipt, collection, recipient, abi) {
  for (const log of receipt.logs) {
    if (getAddress(log.address) !== getAddress(collection)) continue;
    let event;
    try {
      event = abi.parseLog(log);
    } catch {
      continue;
    }
    if (
      event?.name === "Transfer" &&
      event.args.from === ZeroAddress &&
      getAddress(event.args.to) === getAddress(recipient)
    )
      return event.args[2].toString(); // tokenId in ERC721A; positional also supports Solady's id.
  }
  throw Error("Mint receipt has no matching collection NFT transfer");
}

/** Approved release economics. Small accounting fixtures are confined to local simulations. */
export const PRODUCTION_SALE = Object.freeze({
  FUNDING_PROFILE: "governed",
  MAX_SUPPLY: "2500",
  MINT_PRICE_WEI: "8000000000000000",
});

/** Reject stale shell overrides before any paid upload or deployment. Other terms stay explicit. */
export function releaseSettings(env) {
  for (const [key, value] of Object.entries(PRODUCTION_SALE)) {
    assert(
      env[key] === undefined || env[key] === value,
      `${key} must be ${value} for the approved public-only holder-governed release`,
    );
  }
  return { ...env, ...PRODUCTION_SALE };
}
