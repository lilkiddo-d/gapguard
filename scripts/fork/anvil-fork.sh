#!/usr/bin/env bash
# Starts a local anvil fork of Robinhood Chain mainnet as chain 31337.
# --auto-impersonate lets the deploy script, the keeper and the frontend dev wallet send transactions
# from any address WITHOUT private keys.
set -euo pipefail
RPC="${ROBINHOOD_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
exec anvil --fork-url "$RPC" --chain-id 31337 --auto-impersonate --host 127.0.0.1 --port "${ANVIL_PORT:-8545}" \n  --retries 30 --fork-retry-backoff 1500 --timeout 60000 --compute-units-per-second 50 "$@"
