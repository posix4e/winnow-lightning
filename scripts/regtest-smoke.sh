#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$(mktemp -d)"
read -r RPC_PORT P2P_PORT < <(python3 - <<'PY'
import socket
ports = []
for _ in range(2):
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        ports.append(sock.getsockname()[1])
print(*ports)
PY
)

cleanup() {
  bitcoin-cli -datadir="$FIXTURE_DIR/node" -regtest -rpcport="$RPC_PORT" stop >/dev/null 2>&1 || true
  rm -rf "$FIXTURE_DIR"
}
trap cleanup EXIT

mkdir -p "$FIXTURE_DIR/node"
bitcoind -datadir="$FIXTURE_DIR/node" -regtest -server=1 -listen=1 \
  -bind=127.0.0.1 -rpcbind=127.0.0.1 -rpcallowip=127.0.0.1 \
  -rpcport="$RPC_PORT" -port="$P2P_PORT" -blockfilterindex=1 -peerblockfilters=1 \
  -txindex=1 -fallbackfee=0.0001 -daemon >/dev/null

btc() { bitcoin-cli -datadir="$FIXTURE_DIR/node" -regtest -rpcport="$RPC_PORT" "$@"; }
for _ in {1..50}; do
  if btc getblockchaininfo >/dev/null 2>&1; then break; fi
  sleep 0.2
done
btc createwallet smoke >/dev/null
mine_address="$(btc getnewaddress)"
btc generatetoaddress 101 "$mine_address" >/dev/null

channel_address="$(btc getnewaddress '' bech32)"
script_hex="$(btc getaddressinfo "$channel_address" | jq -r .scriptPubKey)"
funding_txid="$(btc sendtoaddress "$channel_address" 0.00100000)"
btc generatetoaddress 1 "$mine_address" >/dev/null
funding_vout="$(btc getrawtransaction "$funding_txid" true | jq -r --arg script "$script_hex" '.vout[] | select(.scriptPubKey.hex == $script) | .n')"
if [[ -z "$funding_vout" ]]; then echo "funding output missing" >&2; exit 1; fi

watch=("$ROOT_DIR/ChainWatch/.build/debug/chain-watch" --network regtest
       --state "$FIXTURE_DIR/client" --start-height 100 --peer "127.0.0.1:$P2P_PORT"
       --watch-script "$script_hex" --funding-outpoint "$funding_txid:$funding_vout")
"${watch[@]}"

spend_address="$(btc getnewaddress)"
raw="$(btc createrawtransaction "[{\"txid\":\"$funding_txid\",\"vout\":$funding_vout}]" "{\"$spend_address\":0.00099000}")"
signed="$(btc signrawtransactionwithwallet "$raw" | jq -r .hex)"
btc sendrawtransaction "$signed" >/dev/null
btc generatetoaddress 1 "$mine_address" >/dev/null
"${watch[@]}"

jq -e '[.events[].kind] | sort == ["fundingOutput", "fundingSpend"]' "$FIXTURE_DIR/client/events.json" >/dev/null
echo "regtest funding and spend detected through direct Bitcoin P2P compact filters"
