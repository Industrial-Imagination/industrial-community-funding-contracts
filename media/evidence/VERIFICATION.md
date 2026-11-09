# Platinum funding card verification

Current funding governance verification is in [the monthly council report](GOVERNANCE-VERIFICATION.md).


The subsequent SeaDrop adapter and its net-proceeds lifecycle are verified separately in [the SeaDrop verification report](SEADROP-VERIFICATION.md). The card player bytes are identical.

Verified locally on November 4, 2026 using Foundry 1.8.1, solc 0.8.28 with the IR pipeline and 200 optimizer runs, Node 23.8.0, and headless Chrome 156.0.8078.80 on macOS. The collection and renderer were deployed to ephemeral Anvil. All public network access was read-only.

| Measurement | Final build |
|---|---:|
| Funding contract runtime | 14,642 bytes |
| Renderer runtime | 6,158 bytes |
| ETHFS library / player / WebP | 225,020 / 64,416 / 17,770 bytes |
| Complete token URI / decoded HTML | 462,981 / 314,731 bytes |
| Estimated gas for collection tokenURI(1) | 37,221,516 |
| Desktop mean / p95 frame interval at 900 × 900 | 16.68 / 16.90 ms |
| Recording | 900 × 900 VP9 WebM, 23.998 seconds |

**Contract and asset checks.** Formatting and production size checks passed. Nine Foundry tests passed, including 256 fuzz cases covering refund rounding, burn order, and conservation of the mint proceeds. The suite also exercises midstream owner claims, renderer replacement and permanent freezing, invalid descriptors, corrupt content, byte and slice limits, JSON escaping, and burned token rejection. Two Node checks compare the seven engraved rows to the original 131 bytes and verify the packaged font, logo, license notices, and hashes. Rebuilding produced identical player, template and manifest bytes.

**Mint and playback.** A local release stored the ETHFS files, minted three tokens and returned the complete player from token 1. Its decoded HTML matched the inspection build byte-for-byte. The collection then finalized, burned token 2 and froze metadata. Chrome ran the actual animation URI in an opaque sandbox with HTTP requests blocked. The recording and final screenshots show the engraved front, legible reverse and thin beveled edge. The browser test exercised desktop drag, mobile-sized touch, keyboard pause/reset, idle resumption, reduced motion, a simulated visibility change, resizing, and the poster fallback after WebGL context loss. No HTTP requests were observed. Five independently decoded video samples cover the two face views and both edge passes. Frame intervals measure the tested browser's animation cadence, not GPU execution time.

**Base preflight and fork rehearsal.** The library descriptor and all chunk bytes matched the pinned hash on Base at block 53,505,077 and Base Sepolia at block 54,388,160. The card runtime and poster need uploading on each public chain. A private fork of that Sepolia block successfully uploaded both files through the registry, verified their hashes, and deployed the renderer and funding contract. Those fork addresses exist only in the rehearsal. Public deployment, physical-device testing and marketplace playback remain separate release steps.

Evidence: [local deployment](anvil.json), [browser and video checks](browser.json), [Sepolia fork rehearsal](sepolia-fork.json), [front](front.png), [reverse](back.png), [edge](edge.png), [oblique](grazing.png), [mobile](mobile.png), [full turn](rotation.webm). Build and release instructions are in [the release guide](../RELEASE.md).
