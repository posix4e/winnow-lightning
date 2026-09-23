# Integration path

This repository is testing a light-client chain source alongside PQLN's invoice verification before joining them into a node. The join must preserve LDK's channel safety behavior, including watching every registered output, replaying reorganizations, broadcasting time-sensitive transactions, and persisting channel monitor state before acknowledging updates.

## Intended boundary

1. Use the pinned PQLN fork as the Lightning protocol engine. Keep post-quantum transport on its dedicated port and require a previously trusted ML-DSA key for PQLN invoice acceptance. Expose an explicit fail-closed policy for payments that cannot use a fully post-quantum route.
2. Turn the direct-peer filter watcher into an LDK chain adapter. LDK's `Filter` registrations must become watched scripts and outpoints. For each verified block, feed the header and relevant transactions to the `ChannelManager` and every `ChannelMonitor` in the order LDK expects. On a reorganization, disconnect the old branch before connecting the new one. The current JSON journal is evidence for the research tool; it is **not** LDK's channel persistence.
3. Add a local on-chain wallet for channel funding and sweeps, P2P transaction broadcast, fee estimates, crash-safe LDK persistence, and a live channel watch mechanism when the phone is offline. Only then attempt a channel/payment regtest journey.
4. Keep the first combined build on regtest and signet. Review upstream protocol identifiers, key pinning, interoperability, size limits, and the research fork's production-hardening gap before considering any mainnet use.

LDK documents [BIP157/158 as a valid block source](https://lightningdevkit.org/blockchain_data/) and requires a nonempty `Filter` implementation for that mode ([node setup guide](https://lightningdevkit.org/building-a-node-with-ldk/setting-up-a-channel-manager)). The current PQLN sample does not provide this adapter.

## Security boundary

PQLN protects Lightning's **off-chain** communication when both sides use its mechanisms and the payee/node keys have a trustworthy anchor. It does not make Bitcoin channel outputs post-quantum safe. The PQLN authors' own [threat model](https://github.com/ahmet-kurt/pq-rust-lightning#threat-model) leaves channel-fund theft through on-chain keys outside its scope. Key pinning on first sight is also vulnerable if the first contact occurs after a quantum-capable attacker exists ([authors' discussion](https://delvingbitcoin.org/t/pqln-post-quantum-security-for-the-bitcoin-lightning-networks-off-chain-surfaces/2893)).

An offline phone cannot react to a revoked commitment or a time-sensitive sweep by itself. A payment-capable mobile design therefore needs an explicit monitoring and recovery plan before holding funds. This repository has no keys or channels yet.
