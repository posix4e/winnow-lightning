# Swift Lightning implementation and release gates

This expands draft PR #3 from Winnow baseline
`a1cc6fbaf6f0d3d68c675e1a78e8d5b8311767f7`. Keep one Swift engine and Winnow's
transaction model, funding wallet, fee policy, verified chain/filter scan and
broadcast path. P256K and CryptoKit supply existing cryptography. Rust reference
peers run on the test host only; the application must contain no Rust, LDK,
PQLN or Kyoto runtime.

## Acceptance contract

The shareable object is the **recipient's reusable receive offer**, shared with
Apple's Share sheet or exact Copy/Paste. A sender-created bearer claim is not
part of this milestone. Test the upstream Lightning async protocol, including
its limitations, rather than substituting the older custom claim protocol.

Use these independent references without changing their protocol code:

- Core Lightning v26.06.8, commit
  `6f741afc395c66d200429ea477d29df4d974748d`.
- LDK commit `0a2b003e7e1602df8933b15b7563ba8b6e198391`, with a host harness for
  network connections, persistence, process control and static invoice serving.
- BOLT vectors at `1aadb719b4007c4cea0ba6e36b08c4fb53788dee` and Bitcoin Core
  regtest consensus checks.

Interoperability evidence is not blanket standards certification. Do not
advertise unsupported features or skip tests when a peer lacks a required
capability.

## Required engine work

- BOLT 1/2 negotiation for private static-remotekey non-anchor channels.
- Commitment/revocation transitions, HTLC settlement, reestablishment,
  cooperative close and force-close recovery.
- BOLT 12 offers and static invoices, blinded paths, onion messages and the
  pinned LDK hold/release async flow. Start with a configured single-path
  regtest topology.
- A single protected versioned journal for channels, monitors, stable payment
  IDs and protocol outbox. Persistence precedes wire publication. An uncertain
  storage write stops financial actions. Verified chain catch-up precedes resume.
- Winnow funding reservations must survive restart and cannot be reused by
  ordinary sends, replaced after publication, or canceled after submission.
- Typed engine events drive preparing, awaiting recipient, settled, failed and
  recovering UI. Only verified settlement produces success.

## Required app and test work

- Integrate funding/payment review, receive offers, sharing, history and
  recovery into the existing research app, preserving spending authentication.
- Use a new Swift storage namespace. Preserve legacy PQLN data without opening
  it with the new engine or overwriting it.
- Stock CLN ordinary lifecycle; Swift-to-LDK and LDK-to-Swift async payments.
- Crash boundaries, failed persistence, duplicate payment requests/messages,
  reordering, release-before-hold, expired offers/paths, provider restart,
  recipient never returning, timeout, force close and reorg.
- App-host tests for canceled authentication, duplicate taps, fee/amount review,
  malformed offers, exact share bytes, lifecycle and restored history.
- Recorded iPhone lifecycle: funding, channel, payments, actual process
  termination/restart, reconciliation and close with returned funds.
- Recorded async journey: recipient shares then terminates; sender pays then
  terminates after durable hold; recipient relaunches and settles while sender
  remains stopped; sender relaunches and records settlement exactly once.
- Separate recipient/sender namespaces and process logs prove non-overlap.
  Independent peers verify hashes, amounts, fees and balances.
- Retain the ordinary recorded on-chain signet journey. Open the Apple Share
  sheet and test Copy/Paste; do not send third-party messenger messages.

## CI and release

Extend the existing CI workflow with a Swift Lightning lane beside ordinary
checks. Start fresh reference fixtures, build app/test bundles once, reuse
them for journeys, and retain videos, screenshots, xcresults, redacted logs and
a source/peer manifest. Require iPhone journeys on PRs; check iPad, large text,
and physical-device authentication/sharing before TestFlight.

Keep the PR draft until these gates pass. Release the exact green commit to the
existing `com.btcswift.lightning` TestFlight app through the existing signing,
export/compliance and release gates. Verify processing and tester availability.
This remains a regtest research beta, not unattended mainnet protection.

## Evidence tracking

`ci-lightning-peer` now checks stock CLN channel opening, payments in both
directions, stable payment IDs, actual Swift process termination/restart,
reestablishment, cooperative close and an independently signed force close.
Bitcoin Core validates commitment, HTLC, delayed, immediate and penalty spends,
including penalties after a peer's second-stage transaction wins the first race.

`ChainRecoveryTests` covers verified scanner sharing, journal cursor replay,
funding reorgs, maturity recalculation, stale-backup protection and failed writes.
`ci-lightning-offers` checks BOLT12 offers, requests and static-invoice signatures
in both directions against the pinned LDK public APIs. Published BOLT12 encoding
and signature vectors are also required.

`ci-lightning-async` now runs both Swift-to-LDK and LDK-to-Swift over real TCP,
with separate sender, recipient and two provider processes. The recipient is
killed after its reusable offer is acknowledged by the static-invoice server;
the sender is killed after the held HTLC is committed; the recipient settles
while the sender remains stopped; the sender then restores and reconciles.
Both directions also pass with both providers killed and restored during the
offline interval. Receipts compare hashes/preimages, committed HTLC values and
forwarding fees, and record process order plus source/reference identities.
LDK can insert dummy hops: distinguish the actual incoming channel amount from
the post-dummy-hop amount in its claim event, while checking the exact total debit.

The shared journal payload is schema 2; pre-release schema 1 is refused rather
than silently discarding channel state. The app integration must use its own new
Swift namespace and preserve the prior PQLN application's files. Optional onion
messages are discarded according to BOLT4 without interrupting channel messages;
a persistence failure still stops every publication path. Receive preimages are
persisted with the fulfill intent for on-chain recovery after a crash.

The full adversarial matrix, app integration/journeys and TestFlight release
remain open gates. These host fixtures alone do not establish release readiness.
