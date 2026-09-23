# Winnow Lightning research

A separate, local research repository for a **light-client path to post-quantum Lightning**. It does not change the Winnow app or hold channel funds. The current prototype has two independently runnable parts:

| Part | What works now |
| --- | --- |
| `ChainWatch` | Reads Bitcoin headers and BIP157/158 compact filters directly from peers on regtest or signet. Watches a prospective channel funding script and, when given its outpoint, detects a later spend. Persists observations and rolls them back on a reorganization. |
| `pq-invoice-verify` | Checks a BOLT 11 invoice's classical signature and PQLN ML-DSA signature against an independently trusted payee key. Missing, unanchored, invalid, or expired invoices fail closed. |

**A spendable Lightning light client is the next step.** The two parts are not yet connected to an LDK `ChannelManager`, so this repository cannot open channels or send payments. See [Integration path](docs/integration.md).

## Why this shape

[PQLN](https://arxiv.org/abs/2609.13781) is a promising research extension to Lightning's off-chain gossip, transport, invoices, offers, and payment onions. Its [authors' implementation](https://github.com/ahmet-kurt/pq-rust-lightning) explicitly leaves funding, commitment, and penalty transactions under Bitcoin's current signatures. Its [sample node](https://github.com/ahmet-kurt/pq-ldk-sample) uses Bitcoin Core RPC, so it is a protocol reference rather than the light-client foundation here. The authors also say their fork is a research artifact and that its protocol identifiers still need BOLT assignment ([design discussion](https://delvingbitcoin.org/t/pqln-post-quantum-security-for-the-bitcoin-lightning-networks-off-chain-surfaces/2893)).

`ChainWatch` reuses Winnow's Bitcoin P2P library at a pinned revision. This is a source dependency in this repository; no source files or settings are added to Winnow. Its regtest smoke test runs a temporary Bitcoin Core **peer** as the fixture, but the client communicates with that peer over the Bitcoin P2P port, never RPC.

## Build and check

Requires Swift 6, Rust 1.75+, Git, and a C compiler. The regtest smoke also needs Bitcoin Core 31.1, Python 3, and `jq`.

```sh
./scripts/bootstrap.sh
./scripts/check.sh
```

`bootstrap.sh` checks out the exact upstream revisions listed in [Dependencies](#dependencies) under ignored `.deps/`. `check.sh` runs the Rust and Swift tests, then funds and spends a test output on a disposable regtest node. It removes that node when finished.

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

The upstream projects remain in `.deps/` and are not vendored or modified. `Cargo.lock` records the Rust dependency graph.
