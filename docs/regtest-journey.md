# Two-node direct-peer regtest journey

This tests a PQLN payment using disposable regtest funds. The Lightning clients talk to Bitcoin Core only through Bitcoin P2P. Core's RPC interface is used by the fixture commands to mine blocks.

## Bitcoin peer

From the repository root, with Bitcoin Core installed:

```sh
./scripts/bootstrap.sh
mkdir -p state/bitcoin-regtest-fixture
FIXTURE="$PWD/state/bitcoin-regtest-fixture"
bitcoind -regtest -datadir="$FIXTURE" -daemon -server=1 \
  -blockfilterindex=1 -peerblockfilters=1 -txindex=1 -fallbackfee=0.00001
bitcoin-cli -regtest -datadir="$FIXTURE" createwallet winnow-test
MINING_ADDRESS=$(bitcoin-cli -regtest -datadir="$FIXTURE" -rpcwallet=winnow-test getnewaddress)
bitcoin-cli -regtest -datadir="$FIXTURE" -rpcwallet=winnow-test \
  generatetoaddress 110 "$MINING_ADDRESS" >/dev/null
```

Regtest P2P normally listens on port `18444`. For a phone, make this port reachable on the LAN and enter the peer's LAN address in the app. The phone does not need RPC access.

## Lightning nodes

Run Alice and Bob in separate terminals:

```sh
cargo run --manifest-path crates/pq-light-client/Cargo.toml -- \
  state/regtest-alice 127.0.0.1:18444 127.0.0.1:9736
```

```sh
cargo run --manifest-path crates/pq-light-client/Cargo.toml -- \
  state/regtest-bob 127.0.0.1:18444 127.0.0.1:9737
```

Alice's `address` command prints her funding address. Bob's public ID is in `state/regtest-bob/node-id.txt`. Wait for initial block synchronization, then fund Alice in a third terminal:

```sh
FIXTURE="$PWD/state/bitcoin-regtest-fixture"
MINING_ADDRESS=$(bitcoin-cli -regtest -datadir="$FIXTURE" -rpcwallet=winnow-test getnewaddress)
bitcoin-cli -regtest -datadir="$FIXTURE" -rpcwallet=winnow-test \
  sendtoaddress ALICE_ADDRESS 0.002
bitcoin-cli -regtest -datadir="$FIXTURE" -rpcwallet=winnow-test \
  generatetoaddress 1 "$MINING_ADDRESS" >/dev/null
```

Replace `ALICE_ADDRESS` with the printed address. Run `sync` and `balance` at Alice; the wallet should show 200,000 sats. Then connect to Bob and open a public channel:

```text
connect BOB_NODE_ID 127.0.0.1:9737 state/regtest-bob/pq-kem-key.hex
open-public BOB_NODE_ID 100000
```

Replace `BOB_NODE_ID` with the contents of Bob's `node-id.txt`. Check that the funding transaction appears in Bitcoin Core's mempool, then mine six blocks:

```sh
bitcoin-cli -regtest -datadir="$FIXTURE" getrawmempool
bitcoin-cli -regtest -datadir="$FIXTURE" -rpcwallet=winnow-test \
  generatetoaddress 6 "$MINING_ADDRESS" >/dev/null
```

Alice and Bob should both report `ChannelReady`; `channels` should show `is_usable: true`. At Bob, create an invoice:

```text
invoice-file 1000 state/regtest-bob/invoice.txt Test payment
```

At Alice, pay against Bob's independently trusted ML-DSA key:

```text
pay state/regtest-bob/invoice.txt state/regtest-bob/pq-node-key.hex
```

Expect `PaymentSuccessful` at Alice and `PaymentReceived` at Bob. Restart both clients with the same state directories and pay a second invoice to check persistence. Stop the fixture with `bitcoin-cli -regtest -datadir="$FIXTURE" stop`.

This public regtest channel lets authenticated PQLN gossip provide the ML-KEM route key. Keep the clients online while channel funds exist; there is no watchtower or background iPhone service. On September 23, 2026, this journey completed two payments, including one after restart, without Esplora. A one-block reorganization after channel funding disconnected the old block and connected the new branch; a third payment then succeeded. The automated `scripts/check.sh` still covers only the independent watcher and unit tests.
