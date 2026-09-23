# Integration path

The payment-capable regtest node uses PQLN's LDK fork through a patched LDK Node and an Esplora chain source. The direct-peer `ChainWatch` still runs independently. Joining it to the node must preserve LDK's channel safety behavior, including watching every registered output, replaying reorganizations, broadcasting time-sensitive transactions, and persisting channel monitor state before acknowledging updates.

## Intended boundary

1. The pinned PQLN fork is the Lightning protocol engine. The LDK Node patch uses the hybrid PQ transport for inbound and outbound TCP connections, and requires PQ inbound and outbound payment onions. The CLI checks invoices against an independently trusted ML-DSA key before requesting payment. It does not use a classical fallback.
2. LDK Node currently provides the on-chain wallet, funding and sweep machinery, Esplora sync, fee estimates, and channel monitor persistence. It is a light client because it does not run Bitcoin Core locally, but it trusts an Esplora server for chain data. The same process must stay online while it holds a channel; no watchtower is configured.
3. Turn the direct-peer filter watcher into an LDK chain adapter. LDK's `Filter` registrations must become watched scripts and outpoints. For each verified block, feed the header and relevant transactions to the `ChannelManager` and every `ChannelMonitor` in the order LDK expects. On a reorganization, disconnect the old branch before connecting the new one. The current JSON journal is evidence for the research tool; it is **not** LDK's channel persistence.
4. The two-node regtest journey has been run manually: fund, connect over PQ transport, open an announced channel, confirm it, pay a PQ invoice, restart both nodes, and pay again. Both payments succeeded. A reproducible automated Lightning smoke and reorganization recovery check are still needed. The current automated smoke covers funding/spend detection by `ChainWatch` only.
5. Review upstream protocol identifiers, key pinning, interoperability, size limits, offline monitoring, and the research fork's production-hardening gap before considering any mainnet use.

LDK documents [BIP157/158 as a valid block source](https://lightningdevkit.org/blockchain_data/) and requires a nonempty `Filter` implementation for that mode ([node setup guide](https://lightningdevkit.org/building-a-node-with-ldk/setting-up-a-channel-manager)). The current PQLN sample does not provide this adapter.

## Security boundary

PQLN protects Lightning's **off-chain** communication when both sides use its mechanisms and the payee/node keys have a trustworthy anchor. It does not make Bitcoin channel outputs post-quantum safe. The PQLN authors' own [threat model](https://github.com/ahmet-kurt/pq-rust-lightning#threat-model) leaves channel-fund theft through on-chain keys outside its scope. Key pinning on first sight is also vulnerable if the first contact occurs after a quantum-capable attacker exists ([authors' discussion](https://delvingbitcoin.org/t/pqln-post-quantum-security-for-the-bitcoin-lightning-networks-off-chain-surfaces/2893)).

An offline phone cannot react to a revoked commitment or a time-sensitive sweep by itself. A payment-capable mobile design therefore needs an explicit monitoring and recovery plan before holding real funds. This repository can create regtest keys and channels, but does not provide that offline monitoring plan.
