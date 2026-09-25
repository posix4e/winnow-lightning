# Winnow Lightning research extension

This branch starts from the full Winnow application at upstream
`a1cc6fbaf6f0d3d68c675e1a78e8d5b8311767f7`. The optional Lightning package uses
low-level PQLN revision `1d7dda453dd385f3ede84c39eed5d20afe34e02a`.
The original on-chain application and root Swift package remain independently
buildable. The earlier standalone prototype is not a dependency.

## Ownership

Winnow owns ordinary addresses, coin selection, PSBT construction, wallet-input
signing, change, fee policy, Bitcoin peers, headers, compact filters, reorgs and
transaction relay. Funding reservations save exact signed bytes, inputs and
change indices before channel submission. They survive restart and exclude
conflicting ordinary sends and RBF. A funding request does not authorize relay;
the channel protocol must separately request broadcast.

PQLN owns channel negotiation, commitments, HTLCs, revocations, channel signers,
Lightning wire encryption, invoices and synchronous monitor persistence. It may
use `rust-bitcoin` types internally. Serialized consensus bytes are the boundary:
Swift does not reconstruct signed commitment or sweep transactions. There is no
LDK Node, BDK, Kyoto, second Bitcoin wallet or second Bitcoin networking stack.

Private, single-funded, non-anchor channels are supported on regtest only, with
a maximum of eight channels. Unsupported inbound channel types are rejected.
Private peer payments use explicitly pinned ML-KEM and ML-DSA keys. Invoice
verification rejects missing or mismatched trust anchors; PQ payment onions are
required. Bitcoin on-chain transactions retain their normal Bitcoin signatures.
Public gossip/routing, BOLT 12 refund payments, splicing and anchor fee-bumping
are outside this research implementation. Private multi-hop routing through
explicitly configured lab peers supports the message-payment experiment.

## Funded message payments

A sender can commit a regtest HTLC, export one durable bearer claim through the
system Share sheet, Copy or a file, and stop its app before redemption. The
recipient redeems through a different provider on the four-node S—A—B—R route.
Winnow continues to own wallet funding, Bitcoin P2P, compact-filter validation,
reorg handling and broadcasts. The native module owns protocol persistence,
HTLC state, quote authentication and exact-once invoice binding.

See [CLAIMS.md](CLAIMS.md) for encoding, timing, authentication and recovery, and
[LAB.md](LAB.md) for the user-operated LAN fixture and beta installation steps.
This is a private, versioned claim extension; it is not a standard BOLT12 refund.
Pinned PQ signatures are required; the unsupported classical refund path returns
an explicit capability error. Claims are copyable and the sender can retain a
copy. Only actual channel settlement produces a payment receipt.

The app rejects other Bitcoin networks, shows review before committing, and
authenticates sharing. It keeps new regtest Keychain/defaults/files separate from
older app data. Release updates `com.btcswift.lightning`; Debug uses the research
bundle. `scripts/lightning-testflight` archives only a clean commit with a green
CI run, verifies identity and release exclusions, and distributes only to the
existing internal group. It performs no App Store submission.
The encryption declaration and initial destination limits are documented in
[EXPORT-COMPLIANCE.md](EXPORT-COMPLIANCE.md). Distribution requires the operator
to confirm the countries of every current tester; it does not infer location.

## Execution and recovery

Each native engine runs on one worker with an 8 MiB stack; the PQ implementation
exceeded a Swift executor thread's stack in an early integration test. Rust
never calls back into a Swift actor. Synchronous monitor storage completes in
the native core, and the manager is checkpointed before outgoing bytes leave it.
One process holds an exclusive lock on each engine directory. Storage failure
stops the engine until it is reopened.

ABI 1 uses bounded JSON and hex consensus bytes. Hash strings are in Bitcoin
display order; amount and fee fields name their units. `sat/kw = ceil(sat/vB *
250)`, subject to the core's floor. Seeds cross as 32 binary bytes rather than
JSON. The worker's initialization copy is zeroized. Swift owns each returned
buffer exactly once. `LightningTCP` uses per-connection sequence numbers to
preserve outgoing byte order across actor continuations, bounded queues and
one outstanding receive per peer.

`LightningChainDriver` runs through Winnow's existing `FilterSync`. Watches are
durable and revisioned; the scanner refreshes them between verified heights and
delivers complete matched blocks, including descendants. Each engine tracks its
own coverage. New watches and startup replay from genesis on regtest through the
same scanner, without a second filter archive. Peer traffic and broadcast
acknowledgment wait until catch-up finishes.

Saved channel monitors can lag the manager because PQLN periodically persists
chain progress. They catch up independently before being attached to the live
monitor set. Saved chain locators are checked against Winnow's canonical
headers. An interrupted rollback is reconciled when the common ancestor is
present in the saved locator; a deeper unresolved startup fork fails closed.

Cooperative close selects a Winnow destination. Mature channel-specific outputs
are signed by the native channel signer and swept into a fresh Winnow address.
Sweep bytes, destination and broadcast request are persisted together. Replays
retain the same transaction. The broadcaster preserves packages; the app refuses
to split an unsupported multi-transaction package into independent broadcasts.

## Research app

`project-lightning.yml` builds the existing Swift app with an additive Lightning
screen under Settings. Debug uses `com.btcswift.lightning.research`; Release uses
the existing `com.btcswift.lightning` app identity. A separate research Keychain
service and storage directory preserve older wallet data. It is locked to regtest and does not
request iCloud entitlements or enable ordinary automatic cloud recovery.

Unlock uses Winnow's existing device-owner authentication. Seed version 1 is
HKDF-SHA256 over the BIP32 master private key followed by its chain code, with
salt `winnow/lightning/seed/v1`, network raw value as info, and 32 output bytes.
A reference vector pins this derivation. This recovers the node identity only;
it cannot recover channel state.

Funding shows amount and fee before signing and uses the existing `.spending`
gate. Fee estimates come from Winnow's `FeePolicy` and refresh after wallet sync.
Lightning payments and channel closure require device authentication. Backgrounding,
reconnecting or locking ends the native session and its sockets. Foregrounding
requires explicitly unlocking Lightning again. Monitoring operates only while
the app is open; there is no watchtower or background monitoring service.

Once Lightning storage exists, this research build blocks seed-only export,
wallet replacement and deletion. Funding reservations and channel records are
retained conservatively even after settlement. Automated reservation retirement,
safe cleanup after an interrupted funding negotiation, complete channel backup
and offline recovery remain work before this can be a normal wallet. There is
no mainnet support. Internal TestFlight distribution is gated by the complete CI
run and Apple's actual processing and tester-availability state.

## Build and validation

Prerequisites: Xcode, Swift 6, Cargo, XcodeGen and Rust targets
`aarch64-apple-darwin`, `aarch64-apple-ios`, `aarch64-apple-ios-sim`.
The generated native artifact supports Apple Silicon macOS and arm64 iOS/device
simulator. Generated projects and binaries are ignored.

```sh
bash scripts/build-lightning.sh --all
cargo test --manifest-path Native/LightningBridge/Cargo.toml --locked
swift test --package-path Lightning
swift test
xcodegen generate --spec project-lightning.yml
xcodebuild -project WinnowLightningResearch.xcodeproj \
  -scheme WinnowLightningResearch -destination 'generic/platform=iOS Simulator' \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build
```

`--mac-only` creates a smaller XCFramework for local Swift tests. The Xcode flag
above permits the pinned secp256k1 package's shared-source copy build plugin;
it can also be approved in Xcode. The ordinary project remains `project.yml`.

Enable the independent Bitcoin Core journey with:

```sh
WINNOW_BITCOIN_DIR=/path/to/bitcoin/bin swift test --package-path Lightning
```

The disposable node must support regtest, BIP157 filters and
`gettxspendingprevout` (validated with Bitcoin Core 31.1). RPC only prepares the
chain, mines and checks independent outcomes. Winnow obtains coins through its
P2P scanner, signs and relays the channel funding, and monitors confirmation and
reorgs through compact filters. The journey pays, restarts both engines, pays
again, handles a fork, then tests cooperative close and force-close/sweep back
into Winnow. Competing force-close commitments are checked against Core's actual
mempool spender rather than requiring both conflicts to be accepted. A separate
case covers interrupted startup rollback and refusal of a fork beyond saved
ancestry. Another test runs the PQ handshake and channel messages over real
Swift TCP sockets.

Native tests cover storage identity/locking, PQ funding negotiation, fail-closed
journal persistence and fee units. Wallet and scanner tests cover reservations,
conflicting spends/RBF, dynamic watches, ordered filters, failed consumer work
and historical catch-up. This is research validation, not a security audit or
evidence of safe unattended use with real funds.


## Recorded simulator journey

The existing `CI` workflow runs a separate `lightning` job on Apple silicon,
concurrently with ordinary Winnow validation. Both jobs must pass the final
validation gate. Lightning has its own simulator, disposable regtest chain,
and `lightning-tests-<run>-<attempt>` artifact. It does not require deployment
or signing secrets. Website deployment remains enabled upstream; research
forks opt in with `WINNOW_DEPLOY_SITE=true` and their own credentials. The ordinary
signet journey and its website media remain in their existing job.

CI also runs on pushes to `codex/winnow-lightning` while the replacement is under
review and the repository's default branch still contains the earlier prototype.
Push and pull-request runs for that source branch share a concurrency group.

`Lightning/UITests` drives the actual research app: create and fund a Winnow
wallet, review and sign channel funding, confirm the channel, pay an invoice,
terminate and reopen the app, verify persisted payment history, pay again, and
cooperatively close back into Winnow. A second PQLN peer runs in the test runner
using Swift TCP and Winnow's P2P scanner/relay. Bitcoin Core checks the actual
funding and closing transactions; both invoices must be claimed by the peer.
No channel or payment state is injected into the app.

The job reuses `scripts/ci-ui-journey`: one continuous H.264 `journey.mp4`, nine
checkpoint PNGs, `NodeUI.xcresult`, UI log, wallet event journal and node log.
The movie illustrates the flow; assertions and the result bundle establish
success. Complete channel backup, unattended monitoring and force-close UX
remain outside this UI journey; force-close/sweep and reorgs have library tests.

To record locally after building the native bridge:

```sh
xcodegen generate --spec project-lightning.yml
WINNOW_BITCOIN_DIR=/path/to/bitcoin/bin \
  scripts/ci-lightning-journey /tmp/winnow-lightning-new-run
```

Use a fresh results directory. `SIMULATOR_ID` and `DERIVED_DATA` can select an
existing simulator/build; add `--skip-build` after `build-for-testing` to reuse
it. The wrapper stops only its own Bitcoin fixture. UI-test configuration is
passed through a copied `.xctestrun`, so no host-home configuration file is
required. E2E mode uses Winnow's existing disposable storage and Keychain
namespace, including when the research app has another wallet saved.
