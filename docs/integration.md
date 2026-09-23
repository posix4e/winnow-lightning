# Integration path

The payment-capable regtest node uses PQLN's LDK fork through a patched LDK Node and a direct Bitcoin P2P chain source. The independent `ChainWatch` still serves as a compact-filter research tool. The node's peer adapter fetches every regtest block and passes it to the existing wallet, channel manager, channel monitors, and sweeper through LDK's block listener. It uses LDK's chain poller to disconnect old blocks and connect the winning branch after a reorganization.

## Intended boundary

1. The pinned PQLN fork is the Lightning protocol engine. The LDK Node patch uses the hybrid PQ transport for inbound and outbound TCP connections, and requires PQ inbound and outbound payment onions. The CLI checks invoices against an independently trusted ML-DSA key before requesting payment. It does not use a classical fallback.
2. LDK Node provides the on-chain wallet, funding and sweep machinery, channel monitor persistence, and fixed regtest fee estimates. Kyoto fetches headers and blocks from a selected Bitcoin P2P peer and relays transactions to it. No Esplora, Electrum, or Bitcoin Core RPC endpoint is configured in the Lightning client. Bitcoin Core is only a test fixture for mining blocks.
3. The peer adapter currently reads **full blocks** from genesis on regtest. This avoids missed wallet or channel matches while LDK's `Filter` registrations are not yet connected to a compact-filter watch set. The node stores only wallet and channel state, but the initial scan can use substantial bandwidth. Filter-based skipping, stronger peer diversity, mempool observation, and measured reorganization recovery are future work. The independent `ChainWatch` JSON journal is **not** LDK's channel persistence.
4. The two-node regtest journey has been run manually without Esplora: fund, connect over PQ transport, open an announced channel, confirm it, pay a PQ invoice, restart both nodes, and pay again. Both payments succeeded. A reproducible automated Lightning smoke and reorganization recovery check are still needed. The current automated smoke covers funding/spend detection by `ChainWatch` only.
5. Review upstream protocol identifiers, key pinning, interoperability, size limits, offline monitoring, and the research fork's production-hardening gap before considering any mainnet use.

LDK documents [BIP157/158 as a valid block source](https://lightningdevkit.org/blockchain_data/). The current adapter takes the conservative full-block path while the registered script and outpoint watch set is unfinished.

## Security boundary

PQLN protects Lightning's **off-chain** communication when both sides use its mechanisms and the payee/node keys have a trustworthy anchor. It does not make Bitcoin channel outputs post-quantum safe. The PQLN authors' own [threat model](https://github.com/ahmet-kurt/pq-rust-lightning#threat-model) leaves channel-fund theft through on-chain keys outside its scope. Key pinning on first sight is also vulnerable if the first contact occurs after a quantum-capable attacker exists ([authors' discussion](https://delvingbitcoin.org/t/pqln-post-quantum-security-for-the-bitcoin-lightning-networks-off-chain-surfaces/2893)).

An offline phone cannot react to a revoked commitment or a time-sensitive sweep by itself. A payment-capable mobile design therefore needs an explicit monitoring and recovery plan before holding real funds. This repository can create regtest keys and channels, but does not provide that offline monitoring plan.
