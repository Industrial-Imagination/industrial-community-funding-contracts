# Production cleanup verification — 2026-11-09

Approved public release target is IndustrialImaginationGovernedFunding with 2,500 NFTs at 0.008 ETH gross each. The shared release settings reject conflicting supply, price and governance before public uploads or deployment. Constructor parameters remain configurable for local regression fixtures.

Removed the SeaDrop allowlist storage, helper deployment, setup/leaf/params functions, root construction and close-time cleanup. Removed FundingAllowlist.sol, its proof CLI and the empty Counter deployment scaffold. Upstream allowlist configuration still reverts. The mint callback requires the public stage to be enabled. Public sale finalization retains its existing error ordering and irreversible closure.

Updated the continuous-policy fork fixture to use public mints and assert a zero allowlist root. Older direct-mint and standalone continuous-policy targets remain regression fixtures; public release commands reject them. Historical deployments and reports remain unchanged.

## Checks

- `forge fmt --check` passed.
- `forge test --fuzz-runs 2048` passed all 111 test executions across five suites.
- `node --test tools/card/*.test.mjs` passed all six checks.
- `npm run build` completed, including generated player and asset checks.
- Modified deployment/fork scripts passed Node syntax checks.
- `forge build --sizes` passed with Solidity 0.8.38, via IR, Prague and the existing 100 optimizer runs. Governed runtime is 22,772 bytes, leaving 1,804 bytes under EIP-170. Initcode is 40,922 bytes.

New coverage checks disabled allowlist selectors and real SeaDrop allowlist mint rejection, release configuration mismatch rejection, public stage gating, and mint/finalization accounting at the approved supply and price. The economic test uses an illustrative 10% fee and 30% upfront; it does not set new production fee terms.

These checks execute locally against the installed SeaDrop source. Network fork rehearsals and marketplace indexing were not rerun for this cleanup. No public transactions were sent. Fee configuration, upfront terms, durations, wallet cap and owner/backup addresses still require their intended deployment settings.
