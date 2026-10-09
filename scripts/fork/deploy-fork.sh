#!/usr/bin/env bash
# Full deployment against the local anvil fork (see anvil-fork.sh), then funds a dev wallet with USDG.
# Uses an unlocked (impersonated) sender: no private key is created, stored or printed.
set -euo pipefail
cd "$(dirname "$0")/../.."
SENDER="${FORK_DEPLOYER:-0x00000000000000000000000000000000DeaDBeef}"
DEV_WALLET="${FORK_DEV_WALLET:-0x000000000000000000000000000000000000dEaD}"
RPC="http://127.0.0.1:${ANVIL_PORT:-8545}"
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
# QQQ/USDG Uniswap v3 pool - a large USDG holder used only to fund test wallets on the fork
USDG_WHALE=0xD60A5d14dB690B7Afad71F76B108071D7175597d

cast rpc anvil_setBalance "$SENDER" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
cast rpc anvil_setBalance "$DEV_WALLET" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
cast rpc anvil_setBalance "$USDG_WHALE" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null

(cd contracts && GAPGUARD_KEEPER="${GAPGUARD_KEEPER:-$DEV_WALLET}" forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$RPC" --unlocked --sender "$SENDER" --broadcast --slow)

# fund the dev wallet with 100k USDG from the whale (impersonated)
cast send "$USDG" "transfer(address,uint256)" "$DEV_WALLET" 100000000000 --from "$USDG_WHALE" --unlocked --rpc-url "$RPC" >/dev/null
echo "Dev wallet $DEV_WALLET funded with 100,000 USDG on the fork"
