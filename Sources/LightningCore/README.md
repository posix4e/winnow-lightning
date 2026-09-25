# Swift Lightning core

An additive implementation on Winnow at `a1cc6fbaf6f0d3d68c675e1a78e8d5b8311767f7`,
using its existing `WalletCore.Transaction`, `Script`, serialization and hashes.
Curve operations use the unchanged P256K 0.23.2 dependency (C libsecp256k1);
ChaCha20-Poly1305 and HKDF use Apple's CryptoKit. There is no Rust, LDK, PQLN,
Kyoto, second wallet, scanner, or transaction representation in this target.

This draft now includes a durable Swift channel engine and independent-peer
tests. It is not yet connected to the app or a TestFlight build. The complete
accepted scope and remaining release gates are in
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
  validation. These are prerequisites for the pending BOLT 12 async work.
- Winnow-owned funding reservations and ordered verified-filter observers,
  selectively reused from the prior research work without its native bridge.

`Commitment` retains its validated parameters: recovery/signing cannot silently
substitute its capacity, fee rate or channel keys. The low-level transaction
builder follows BOLT 3's funder-fee exhaustion rule; a future channel policy must
reject unaffordable negotiated updates before signing. The builder does not
enforce reserve, expiry, confirmation or channel-state policy.

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
amounts, hashes and balances. These tests do not establish asynchronous-payment
interoperability or app behavior.

## Remaining engine and application work

Keep one Swift implementation and Winnow's existing ownership boundaries:

- Expand interrupted-exchange tests across every commitment/revocation boundary,
  concurrent updates, failed writes, exact replay and stale/rolled-back state.
- Winnow-owned funding reservations, fees, validated chain/reorg notifications,
  spend watches and broadcast. Current commitment selection and unattended
  resolution must precede real-fund use.
- BOLT 12 offers, blinded paths, static invoices and the pinned upstream async
  protocol, then recipient-shared reusable receive offers and Apple sharing.
- App integration, simulator journeys/video and a separately validated
  TestFlight build. Do not ship this library as a replacement for those flows.

Anchors, zero-fee commitments, splicing and post-quantum protocol extensions are
not implemented or advertised. Classical Lightning is this branch's target.
