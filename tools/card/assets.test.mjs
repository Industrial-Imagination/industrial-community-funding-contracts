import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { gunzipSync } from "node:zlib";
import { keccak256 } from "ethers";
import { rows } from "../../media/card.mjs";
const original =
  "4E 65 77 20 66 72 6F 6E 74 69 65 72 73 20 6F 66 20 63 72 65 61 74 69 76 69 74 79 20 6C 69 65 20 62 65 66 6F 72 65 20 75 73 2C 20 61 6E 64 20 77 65 20 68 61 76 65 20 64 65 63 69 64 65 64 20 74 6F 20 66 75 6E 64 20 74 68 65 6D 20 62 65 63 61 75 73 65 20 77 65 20 68 61 76 65 20 76 69 73 69 6F 6E 2C 20 77 65 20 61 72 65 20 62 6F 6C 64 2C 20 61 6E 64 20 77 65 20 61 72 65 20 64 72 69 76 65 6E 2E";
test("reverse reproduces the supplied 131 bytes in seven rows", () => {
  assert.deepEqual(
    rows.map((r) => r.length),
    [19, 19, 19, 19, 19, 19, 17],
  );
  assert.equal(rows.flat().join(" "), original);
});
test("packaged module contains its artwork, font and licenses", () => {
  const assets = JSON.parse(fs.readFileSync("media/dist/assets.json"));
  const card = fs.readFileSync("media/dist/runtime.txt");
  assert.equal(keccak256(card), assets[1].hash);
  assert(assets.reduce((sum, a) => sum + a.size, 0) < 512 * 1024);
  const source = gunzipSync(Buffer.from(card.toString(), "base64")).toString();
  for (const text of [
    "data:font/woff2;base64,",
    "data:image/png;base64,",
    "2017 IBM Corp.",
    "three.js authors",
  ])
    assert(source.includes(text));
  assert(!source.includes("__LOGO__") && !source.includes("__FONT__"));
});
