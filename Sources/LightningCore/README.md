# Swift Lightning core

An additive implementation on Winnow at `a1cc6fbaf6f0d3d68c675e1a78e8d5b8311767f7`,
using its existing `WalletCore.Transaction`, `Script`, serialization and hashes.
Curve operations use the unchanged P256K 0.23.2 dependency (C libsecp256k1);
ChaCha20-Poly1305 and HKDF use Apple's CryptoKit. There is no Rust, LDK, PQLN,
Kyoto, second wallet, scanner, or transaction representation in this target.

This draft includes a durable Swift channel engine, independent-peer tests and
a native SwiftUI research app. Simulator validation and the TestFlight release
gates are tracked separately; no TestFlight upload is implied by engine tests.
The complete accepted scope and remaining release gates are in
[the implementation plan](../../docs/engineering/swift-lightning.md).

## Implemented

- WalletCore BIP143 signature digests for all six standard sighash modes.
- BOLT 3 key/revocation derivation, commitment-secret generation and compact
  shachain validation. Failed insertions leave the in-memory chain unchanged.
- Static-remotekey, non-anchor funding, commitment and HTLC transactions,
  including dust trimming, fees, output sorting and obscured commitment numbers.
- Verified commitment and HTLC signature assembly, HTLC success/timeout,
  delayed withdrawals and revocation spends, all returning WalletCore transactions.
- BOLT 8 Noise XK authentication and encrypted frames, fragmentation, directional
  key rotation and permanent connection closure on authentication failure.
- BOLT 1/2 wire encoding, feature negotiation, private channel opening,
  commitment/HTLC signatures, revocations, direct payments, reestablishment and
  cooperative closing over an actor-owned TCP connection.
- An encrypted, exclusively locked durable journal containing channel keys,
  current monitors, updates, payment IDs/receipts and exact protocol outbox.
  Disk failures stop publication and further actions. Startup pauses until the
  verified chain adapter explicitly catches up. Proven stale state disables
  commitment publication; whole-backup rollback still needs recovery handling.
- BOLT 4 Sphinx construction/peeling, final TLV payloads and payment-secret
  validation; BOLT12 offers/static invoices, blinded paths and the pinned LDK
  hold/release async flow, including durable request retries.
- Winnow-owned funding reservations and ordered verified-filter observers,
  selectively reused from the prior research work without its native bridge.
- Taproot recovery destinations, negotiated anysegwit cooperative close, and
  dust limits from Winnow's existing coin-selection policy.
- Shared foreground peer sessions, verified-chain recovery, HTLC timeout and
  preimage resolution, reorg reconciliation, and recovery publication after restart.

`Commitment` retains its validated parameters: recovery/signing cannot silently
substitute its capacity, fee rate or channel keys. The low-level transaction
builder follows BOLT 3's funder-fee exhaustion rule. The channel engine applies
reserve, expiry, confirmation and channel-state policy before signing; the
low-level builder alone does not establish that a payment is safe.

Each handshake/transport has one owner (normally a connection actor). These
non-Sendable objects must not be shared concurrently. Complete handshake acts
are supplied by the caller; transport messages accept arbitrary fragmentation.
Preserve ciphertext and write order across short socket writes. Discard the
connection on failure; never persist or restore transport nonces. Clearing Data
references on closure is not a guarantee of memory zeroization.

## Evidence

```sh
swift test
swift test --filter LightningCoreTests
WINNOW_BITCOIN_DIR=/path/to/bitcoin/bin scripts/ci-lightning
```

The ordinary package suite includes the Lightning tests. Independent published
fixtures cover all 16 BOLT 3 Appendix C non-anchor commitment cases and their
second-stage transactions, key derivation, five secret-generation cases, nine
secret-storage cases, 15 BOLT 8 handshake cases, key rotation and nine BIP143
examples. Additional tests exercise substitution, malformed signatures, wrong
preimages, invalid sequencing, fragmentation and authentication failures.
See [vector provenance](../../Tests/LightningCoreTests/Vectors/README.md).

`ci-lightning` starts its own loopback-only regtest Core node with a fresh data
directory and public deterministic test keys. Core supplies test coins; the Swift
fixture constructs and signs all channel transactions. Core checks and mines
commitments, HTLC success/timeout, delayed withdrawals and three revocation
spends. It must reject early CLTV/CSV withdrawals and an altered commitment.
Missing Core binaries fail the check. Both hosted and TDX CI run it alongside
ordinary Winnow checks; production warning checks include LightningCore.

The `ci-lightning` checks are transaction-consensus checks, not Lightning-peer interoperability.
The fixture has both parties' test keys and does not simulate the security of
independent counterparties. No payment, funding, peer or recovery state machine
is inferred from an accepted transaction or matching vector.

`ci-lightning-peer` separately starts unmodified Core Lightning v26.06.8 and
uses the production Swift module over BOLT 8 TCP. It checks stock-generated
onions, channel opening, direct payments in both directions, duplicate payment
requests, actual Swift process termination, persistent receipts, reestablishment
and close. Bitcoin Core verifies/mines the independent parties' final signed
transaction. `--close force` and `--close cooperative` use fresh fixtures.
Receipts record source identity (including whether it is dirty), peer commit,
amounts, hashes and balances.

`ci-lightning-async` separately checks the pinned LDK async protocol against
Swift in both directions, including reusable BOLT12 offers, static invoices,
blinded payment/onion paths, committed held HTLCs and recipient-triggered
release. Sender and recipient are separate processes killed and restarted in
non-overlapping order. `--restart-providers` also kills both LDK providers while
the clients are offline. Receipts check actual channel amounts, forwarding fees,
payment hashes/preimages and process ordering. Rust runs only in the independent
host reference; these tests do not establish app behavior or release readiness.

`ci-lightning-timeout` verifies automatic commitment, HTLC timeout and delayed
recovery after the recipient and both providers disappear. Core validates the
transactions and returned balance. `ci-lightning-ui` builds the research app,
records actual process crashes and Apple Share/Copy, and checks the independent
provider receipts plus the app's restored payment history and wallet balance.
Its Debug authentication fixture is not physical-device authentication evidence.

## Research scope and release gates

This is a configured-route, foreground-only regtest beta. Keep the channel
journal on the device; seed recovery alone does not restore current channel
state. Device authentication, file protection, iPad/large text, final CI and an
exact-source signed TestFlight release have separate required gates in the
[release procedure](../../docs/engineering/lightning-release.md).

Anchors, zero-fee commitments, splicing and post-quantum protocol extensions are
not implemented or advertised. Unattended protection and general mainnet routing
are outside this research release.
