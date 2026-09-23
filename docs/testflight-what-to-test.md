# What to Test — Winnow Lightning 0.1.0 (2)

This is a regtest-only PQLN light-client research build. It connects directly to a reachable regtest Bitcoin P2P peer that serves blocks and compact filters, plus a compatible PQLN peer. It does not connect to Bitcoin mainnet.

1. In Setup, enter two different regtest Bitcoin peers' P2P addresses, such as `192.168.1.8:18444` and `192.168.1.9:18444`, and start the node. Confirm that Wallet shows a regtest funding address.
2. Fund that address with disposable regtest coins and tap Sync wallet.
3. In Peer, compare the peer's node ID, ML-KEM key, and ML-DSA key through a separate trusted channel. Paste the peer address and keys, then connect.
4. Open a channel and watch its status change to Ready after regtest confirmation. For announced PQ routing, configure a reachable announcement address before starting the node.
5. Create a fixed-amount invoice on one device and pay it on another. The pay screen should reject a plain Lightning invoice or an invoice with a mismatched ML-DSA key. A valid pinned PQLN invoice should start a payment and produce a success or failure event.

Keep the app in the foreground during the test. It stops in the background and has no watchtower. Channel funds and Bitcoin on-chain signatures are not quantum safe.
