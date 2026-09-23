# Two-node regtest journey

This exercises the payment-capable light client with disposable Bitcoin regtest funds. The client uses Esplora for chain data; Bitcoin Core runs only inside the test fixture. The example below uses Blockstream's [Esplora Docker image](https://github.com/Blockstream/esplora) for Apple Silicon. Use the corresponding image tag for another CPU architecture.

## Start the chain fixture

From the repository root:

```sh
./scripts/bootstrap.sh
docker run -d --rm --name winnow-lightning-esplora \
  -p 127.0.0.1:8094:80 \
  -e NO_PRECACHE=1 -e ENABLE_LIGHTMODE=1 \
  blockstream/esplora:latest-arm64 \
  bash -c '/srv/explorer/run.sh bitcoin-regtest explorer'
```

Wait until `curl http://127.0.0.1:8094/regtest/api/blocks/tip/height` returns a number. The fixture mines 100 blocks at startup. Then create a funding wallet in its Bitcoin Core instance:

```sh
docker exec winnow-lightning-esplora /srv/explorer/bitcoin/bin/bitcoin-cli \
  -regtest -datadir=/data/bitcoin createwallet winnow-test
```

## Start Alice and Bob

Run these in separate terminals:

```sh
cargo run --manifest-path crates/pq-light-client/Cargo.toml -- \
  state/regtest-alice http://127.0.0.1:8094/regtest/api 127.0.0.1:9736
```

```sh
cargo run --manifest-path crates/pq-light-client/Cargo.toml -- \
  state/regtest-bob http://127.0.0.1:8094/regtest/api 127.0.0.1:9737
```

The nodes write their public identity files under their state directories. Use `cat state/regtest-bob/node-id.txt` to get Bob's node ID. In Alice's prompt, run `address` and copy the printed address.

## Fund and open

In a third terminal, mine spendable fixture coins, then send 0.01 regtest BTC to Alice's address:

```sh
mining_address=$(docker exec winnow-lightning-esplora \
  /srv/explorer/bitcoin/bin/bitcoin-cli -regtest -datadir=/data/bitcoin \
  -rpcwallet=winnow-test getnewaddress)
docker exec winnow-lightning-esplora /srv/explorer/bitcoin/bin/bitcoin-cli \
  -regtest -datadir=/data/bitcoin -rpcwallet=winnow-test \
  generatetoaddress 101 "$mining_address" >/dev/null
docker exec winnow-lightning-esplora /srv/explorer/bitcoin/bin/bitcoin-cli \
  -regtest -datadir=/data/bitcoin -rpcwallet=winnow-test \
  sendtoaddress ALICE_ADDRESS 0.01
docker exec winnow-lightning-esplora /srv/explorer/bitcoin/bin/bitcoin-cli \
  -regtest -datadir=/data/bitcoin -rpcwallet=winnow-test \
  generatetoaddress 2 "$mining_address" >/dev/null
```

Replace `ALICE_ADDRESS` with Alice's printed address. In Alice's prompt, run `sync` and `balance`; the total on-chain balance should be 1,000,000 sats. Connect using Bob's independently checked node ID and ML-KEM key:

```text
connect BOB_NODE_ID 127.0.0.1:9737 state/regtest-bob/pq-kem-key.hex
open-public BOB_NODE_ID 100000
```

Replace `BOB_NODE_ID` with the contents of `state/regtest-bob/node-id.txt`. Alice and Bob should report `ChannelPending`. Mine seven blocks with the fixture command above, changing `2` to `7`. Run `sync` in both prompts. Both should report `ChannelReady`, and `channels` should show `is_usable: true`.

## Pay a PQLN invoice

In Bob's prompt:

```text
invoice-file 1000 state/regtest-bob/invoice.txt Test payment
```

The CLI runs from the repository root, so the path above is relative to that root. In Alice's prompt:

```text
pay state/regtest-bob/invoice.txt state/regtest-bob/pq-node-key.hex
```

Alice verifies the invoice against Bob's pinned ML-DSA key before sending. Expect `PaymentSuccessful` at Alice and `PaymentReceived` at Bob. Alice's `state/regtest-alice/node/ldk_node.log` should contain `PQ: built hybrid ML-KEM payment onion`.

Use `quit` in both prompts and restart the same commands. `channels` should still show a usable channel; create another invoice and pay it to check persistence and PQ reconnection. When finished, stop the fixture with `docker stop winnow-lightning-esplora`.

This walkthrough uses a public regtest channel so authenticated PQLN gossip can provide the ML-KEM route key. It has no offline watchtower and must not be used with real funds.

On September 23, 2026, this journey was run with two local nodes and the Blockstream Esplora regtest container: a 100,000 sat channel reached `ChannelReady`, a 1,000 msat invoice reached `PaymentSuccessful` and `PaymentReceived`, both nodes restarted with `is_usable: true`, and a 2,000 msat invoice was paid successfully. Alice's log recorded a hybrid ML-KEM onion over one hop. The automated `scripts/check.sh` still covers the independent filter watcher and unit tests; this two-node journey is manual.
