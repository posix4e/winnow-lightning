# Winnow Lightning research

A separate research fork of [Winnow](https://github.com/winnowwallet/winnow)'s light-client approach for **post-quantum Lightning**. It reuses Winnow's `WalletCore` at a pinned revision, has its own Git history, and does not change the Winnow app. The current prototype has four parts:

| Part | What works now |
| --- | --- |
| `iOS` | A regtest-only iPhone app using the same patched LDK Node and PQLN payment engine. It starts a local Lightning node, shows a funding address and balances, pins a PQ peer, opens private or announced channels, creates invoices, and verifies a pinned ML-DSA signature before paying. |
| `pq-light-client` | A regtest-only LDK Node wallet and channel manager backed by Esplora. It uses the PQLN fork for PQ peer transport, channels, invoice creation, and fail-closed payment routing. An interactive CLI can fund its wallet, connect to a PQ peer, open a channel, create an invoice, and send a payment after checking a separately trusted ML-DSA key. |
| `ChainWatch` | Reads Bitcoin headers and BIP157/158 compact filters directly from peers on regtest or signet. Watches a prospective channel funding script and, when given its outpoint, detects a later spend. Persists observations and rolls them back on a reorganization. |
| `pq-invoice-verify` | Checks a BOLT 11 invoice's classical signature and PQLN ML-DSA signature against an independently trusted payee key. Missing, unanchored, invalid, or expired invoices fail closed. |

`pq-light-client` is a **research regtest client**, not a production wallet. It does not require a local Bitcoin full node, but its Esplora source is a trusted server dependency. The separate direct-peer `ChainWatch` is not yet the node's chain source. A two-node regtest run completed PQ transport, channel funding, a hybrid ML-KEM payment, receipt, and a second payment after restart. See [Integration path](docs/integration.md).

## Why this shape

[PQLN](https://arxiv.org/abs/2609.13781) is a promising research extension to Lightning's off-chain gossip, transport, invoices, offers, and payment onions. Its [authors' implementation](https://github.com/ahmet-kurt/pq-rust-lightning) explicitly leaves funding, commitment, and penalty transactions under Bitcoin's current signatures. Its [sample node](https://github.com/ahmet-kurt/pq-ldk-sample) uses Bitcoin Core RPC, so it is a protocol reference rather than the light-client foundation here. The authors also say their fork is a research artifact and that its protocol identifiers still need BOLT assignment ([design discussion](https://delvingbitcoin.org/t/pqln-post-quantum-security-for-the-bitcoin-lightning-networks-off-chain-surfaces/2893)).

`ChainWatch` reuses Winnow's Bitcoin P2P library at a pinned revision. This is a source dependency in this repository; no source files or settings are added to Winnow. Its regtest smoke test runs a temporary Bitcoin Core **peer** as the fixture, but the watcher communicates with that peer over the Bitcoin P2P port, never RPC. The payment-capable node currently talks to Esplora instead.

## Build and check

Requires Swift 6, Rust 1.85+, Git, and a C compiler. The regtest smoke also needs Bitcoin Core 31.1, Python 3, and `jq`.

```sh
./scripts/bootstrap.sh
./scripts/check.sh
```

`bootstrap.sh` checks out the exact upstream revisions listed in [Dependencies](#dependencies) under ignored `.deps/` and applies the reviewed LDK Node compatibility patch. `check.sh` builds and tests the Rust and Swift components, then funds and spends a test output on a disposable regtest node. It removes that node when finished. The funding/spend smoke verifies `ChainWatch`, not a Lightning payment.

## Try the regtest Lightning light client

Provide a regtest [Esplora-compatible server](https://github.com/Blockstream/esplora/blob/master/API.md) and a compatible PQLN peer. The client saves its mnemonic and node state under `state/`; keep that directory private and use only disposable regtest funds. The [two-node regtest walkthrough](docs/regtest-journey.md) gives a complete local setup.

```sh
cargo run --manifest-path crates/pq-light-client/Cargo.toml -- \
  state/alice http://127.0.0.1:8094/regtest/api 127.0.0.1:9736
```

At the prompt:

```text
address
identity
sync
balance
connect PEER_NODE_ID 127.0.0.1:9737 PEER_ML_KEM_KEY_HEX_FILE
open-public PEER_NODE_ID 100000
channels
invoice 1000 Research payment
pay INVOICE_FILE TRUSTED_PAYEE_ML_DSA_KEY_HEX_FILE
```

Fund the printed on-chain address and run `sync` before opening a channel. Each node writes `node-id.txt`, `pq-kem-key.hex`, and `pq-node-key.hex` into its state directory so another local regtest node can pin its public keys. For any remote peer, verify those keys through an authenticated channel outside this client. `connect` saves the peer for restart; `open` creates a private channel, while `open-public` creates an announced channel when a listening address is configured. PQ payments require every hop's ML-KEM key to be available in authenticated PQLN gossip, so a newly opened private channel alone may not provide a payable PQ route. Payment failure is expected in that case; the client never falls back to a classical onion. Keep the client online while a channel holds funds.

## Build the iPhone research app

Requires Xcode 27, XcodeGen, Rust's `aarch64-apple-ios` and `aarch64-apple-ios-sim` targets, and an Apple signing team for device builds. The generated Swift bindings and native libraries are kept under ignored `.deps/` so this public repository does not commit large binary artifacts.

```sh
./scripts/build-ios-bindings.sh
xcodegen generate --spec iOS/project.yml --project iOS
xcodebuild -project iOS/WinnowLightning.xcodeproj \
  -scheme WinnowLightning -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

For a phone build, use Xcode's automatic signing with the separate `com.btcswift.lightning` app identifier. On the Setup tab, enter a **regtest** Esplora URL reachable by the phone; `localhost` on a phone is the phone itself. In Peer, paste the counterparty's node ID, address, ML-KEM public key, and ML-DSA public key after comparing the keys through an independent trusted channel. A locally reachable listen address is set by default. To announce a channel for PQ routing, enter the phone's reachable LAN address as the announcement address before starting the node, then choose the announced channel option. The app saves the 64-byte node seed in this device's Keychain and channel state in its app storage. It pins saved peer keys before reconnecting after a restart. The phone must remain foregrounded while testing. A seed alone cannot restore channel state, and this build has no watchtower or background service. Use disposable regtest coins only.

The iOS bundle identifier and signing team live only in this repository's `iOS/project.yml`; the original Winnow iPhone app is unaffected. Apple's export-compliance review must be answered accurately for the bundled PQLN cryptography before any TestFlight group receives a build.
See the [iOS research app privacy note](docs/ios-privacy.md) for what stays on the device and what a tester's selected server can observe.

## Use the chain watcher

For a local regtest peer serving compact filters, pass the funding output's scriptPubKey in hex. The optional outpoint narrows the match to one channel and enables spend detection:

```sh
cd ChainWatch
swift run chain-watch \
  --network regtest \
  --peer 127.0.0.1:18444 \
  --state ../state/regtest-example \
  --start-height 100 \
  --watch-script 0020YOUR_32_BYTE_SCRIPT_HASH \
  --funding-outpoint YOUR_TXID:0
```

Use `--network signet` for public signet and omit `--peer` to use Winnow's peer discovery. Add `--follow` to keep scanning. The watcher prints newly observed events and saves them in `events.json` inside the state directory. Use a separate state directory per network, funding script, and outpoint. With just a script, it detects matching outputs; an exact outpoint is needed to identify a channel spend. This is a read-only observation tool, not a channel monitor.

## Check a PQLN invoice

Put the BOLT 11 invoice in `invoice.txt` and the payee's independently trusted ML-DSA public key, as hex, in `payee-key.hex`. A key copied **from the invoice itself** does not establish the payee's identity. In PQLN, a key pinned from authenticated earlier gossip or checked out of band is the intended anchor.

```sh
cargo run --manifest-path crates/pq-invoice-verify/Cargo.toml -- \
  invoice.txt payee-key.hex
```

The verifier returns success only for a valid, unexpired invoice with a PQLN signature bound to that key. It does not pay the invoice.

## Dependencies

| Source | Pinned revision | Purpose |
| --- | --- | --- |
| [PQLN rust-lightning fork](https://github.com/ahmet-kurt/pq-rust-lightning) | `1d7dda453dd385f3ede84c39eed5d20afe34e02a` | ML-DSA invoice verification and reference protocol code |
| [Winnow](https://github.com/winnowwallet/winnow) | `a1cc6fbaf6f0d3d68c675e1a78e8d5b8311767f7` | Bitcoin P2P headers and compact-filter client |
| [LDK Node](https://github.com/lightningdevkit/ldk-node) | `b812128c51c0171f510d81847b3ed18f0c34a294` | Regtest wallet, channel manager, Esplora sync, and persistence; adapted by [`patches/ldk-node-pqln.patch`](patches/ldk-node-pqln.patch) |

The upstream projects remain in ignored `.deps/` and are not vendored into this repo. The LDK Node checkout receives a local patch after checkout; the upstream repository is unchanged. Each Rust crate has its own `Cargo.lock`.
