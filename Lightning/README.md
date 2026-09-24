# Winnow Lightning

This extension starts at Winnow upstream `a1cc6fbaf6f0d3d68c675e1a78e8d5b8311767f7`.
The root package remains the ordinary Winnow application and wallet. This optional
package adds a narrow bridge to PQLN revision
`1d7dda453dd385f3ede84c39eed5d20afe34e02a`.

## Ownership and execution

Winnow builds and signs channel funding transactions using its existing coin
selection, PSBT, Taproot signer, change derivation, and wallet state. Funding
reservations retain the exact signed bytes, prevent conflicting sends and RBF,
and survive restart. Submission is recorded before bytes enter the channel
protocol. A native broadcast request is separate from a funding request.

The native library owns Lightning channel protocol state, channel signers,
monitor persistence, and PQ transport encryption. Swift supplies connection
bytes and drains outgoing packets. It also supplies chain data and performs
Bitcoin relay. The resolved graph contains the low-level `lightning` and
`lightning-persister` packages; it has no second general-purpose Bitcoin wallet
or Bitcoin networking implementation.

Each engine runs on one native worker with an 8 MiB stack. Calling the PQ signing
implementation directly from Swift's cooperative executor overflowed its stack
in the integration test. Calls are synchronous across the C boundary, and Rust
never calls back into a Swift actor. Monitor persistence completes synchronously
through PQLN's filesystem store. The manager is saved before outgoing peer bytes
are handed to Swift. Native persistence failure stops that engine. One process
holds an exclusive lock on each engine directory.

ABI 1 uses bounded UTF-8 JSON commands and serialized Bitcoin bytes encoded as
hex. Hash strings use Bitcoin display order. Amounts and fee rates name their
units: `sat_per_kw = ceil(sat_per_vbyte * 250)`, subject to the core's floor.
The caller frees every returned C buffer once. Seeds are passed as 32 binary
bytes, never JSON or log messages; the worker's initialization copy is zeroized.

## Building and testing

Prerequisites: Xcode with the SDK license accepted, Swift 6, Cargo, and Rust
targets `aarch64-apple-darwin`, `aarch64-apple-ios`, `aarch64-apple-ios-sim`.

From the repository root:

```sh
bash scripts/build-lightning.sh --all
swift test --package-path Lightning
cargo test --manifest-path Native/LightningBridge/Cargo.toml --locked
swift test
```

`--mac-only` builds a smaller XCFramework for local Swift tests. Generated
libraries and XCFrameworks are ignored; `Cargo.lock` pins transitive dependencies.
The build sets the deployment targets to macOS 14 and iOS 17.

`FundingBridgeTests` creates two actual native PQLN engines, exchanges hybrid
handshake and channel messages through the Swift ABI, and funds the requested
output using Winnow's signer. It verifies exact broadcast bytes and txid, input
reservation, and restart. The coins in that test are WalletCore fixtures; it
does not claim Bitcoin consensus acceptance or perform Bitcoin network relay.

## Current integration boundary

The native bridge is restricted to regtest and initially negotiates private
non-anchor channels. The ordinary app does not yet instantiate it. Payment,
close/sweep commands, and app key authorization and lifecycle integration remain
implementation work. Unhandled native
events remain in LDK for replay rather than being falsely acknowledged.

`FilterScanObserver` adds ordered per-height results and revisioned dynamic
watches to Winnow's existing scanner. It reuses the same peers, validated headers,
filter commitments, block retrieval, and rollback. Its consumer must track its
own durable scan position, detect a watch revision race, and request historical
catch-up when needed. Header sync alone does not establish Lightning scan
completion. `LightningChainDriver` implements this contract, including catch-up of independently
persisted channel monitors before peer reconnect. It checks saved chain locators
against Winnow's canonical headers and fails closed when a crash spans a fork
outside the retained locator's ancestry window. The initial regtest catch-up
rescans from genesis using the same scanner; it retains no second filter archive.

The opt-in `RegtestJourneyTests` uses a disposable Bitcoin Core node. Winnow
receives coins, signs channel funding, relays it over Bitcoin P2P, and confirms
both channel peers through compact filters. The test then restarts both engines,
reconciles independently persisted positions, reconnects, and handles a two-block
reorg. Core RPC is confined to test setup, mining and independent assertions:

```sh
WINNOW_BITCOIN_DIR=/path/to/bitcoin/bin swift test --package-path Lightning
```

An ordinary Winnow seed/iCloud backup does not recover live channel state.
Exports currently refuse wallets with funding reservations. Releasing submitted
reservations, retiring settled channels, resetting storage, and switching
networks require channel lifecycle reconciliation; disconnects and timeouts
cannot release funding inputs.
