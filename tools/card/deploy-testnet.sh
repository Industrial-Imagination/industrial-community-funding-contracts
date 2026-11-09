#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
npm ci
if [[ -z "${DEPLOYER_KEY:-}" ]]; then
  read -r -s -p "Base Sepolia deployer private key (hidden): " DEPLOYER_KEY
  printf '\n'
  export DEPLOYER_KEY
fi
trap 'unset DEPLOYER_KEY' EXIT
node tools/card/testnet.mjs
