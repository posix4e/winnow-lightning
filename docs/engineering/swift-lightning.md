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

The Rust host harness, Cargo lockfiles and reference builder live in
[lightning-reference](https://github.com/posix4e/lightning-reference).
`scripts/ci-lightning-references` fetches the exact repository commit recorded
in that script and rejects a mismatched or modified checkout before executing
its builder. `reference-manifest.json` records the external harness revision
alongside the upstream peer revisions. Swift fixtures and Winnow-specific
scenario drivers stay here; all existing interoperability gates still run.

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
a source/peer manifest. Require iPhone journeys on PRs; check iPad and large text
before TestFlight. Physical-device authentication, sharing and lock protection
may be checked after installation through internal TestFlight, with the pending
checks recorded explicitly rather than reported as passed.

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

The foreground `LightningPeerSession` now drives both the app and independent
host fixtures. Request and held-notification onions retry their original bytes
at a bounded interval until an authenticated response, settlement or expiry.
Tests cover lost delivery across restart, duplicate invoices/notifications,
registration acknowledgement ordering, expired paths, and every ordering of
the commitment acknowledgements and release path before notification.

`ci-lightning-timeout` kills the recipient permanently and then both providers.
After a sender restart, complete Core-validated blocks drive the Swift monitor
through automatic commitment publication, HTLC timeout and delayed recovery.
Core validates all four recovery transactions and the exact returned balance;
the payment becomes failed only after sufficient confirmations. A local run
returned 997,440 of 1,000,000 sats, with 2,560 sats of independently calculated
transaction fees. Chain tests also revert confirmed payment outcomes to
recovering after a reorg while retaining learned preimages.

The `WinnowLightning` research scheme now integrates the same engine with the
wallet's funding reservations, fee policy, verified scanner and broadcaster.
The recorded app journey checks exact Apple Share/Copy bytes, canceled funding
review, actual host SIGKILLs, offline settlement, one restored payment entry,
and cooperative close returning the independently calculated wallet balance.
Its manifest identifies the clean source, executable, device/runtime, text
size, video hash and independent receipt. Run it on iPhone, iPad and at maximum
accessibility text size; the existing CI requires the iPhone journey alongside
the ordinary signet recording.

Research storage and device-only keys use a separate namespace. Deletion and
replacement of its wallet are refused to preserve channel recovery keys;
ordinary wallet behavior is unchanged. The welcome screen explains that this
research wallet has no iCloud backup and that its channel journal must stay on
the device. Payment review keeps amount, fee and expiry above an expandable
exact receive offer.

Exact-source green CI and reviewed export compliance remain required before
internal tester distribution. Physical-device authentication/file protection may
remain explicitly pending for testing through TestFlight. Upload-only mode
omits the encryption declaration keys to trigger Apple’s questionnaire while
review is pending and stops before assigning testers. The signed archive,
export, upload, processing and existing internal-group readback are implemented
in `scripts/release-lightning`; see `lightning-release.md`. A successful host or
simulator run does not establish TestFlight availability.
