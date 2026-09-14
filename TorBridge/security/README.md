# Tor dependency review — 2026-09-13

Reviewed Cargo.lock SHA256:
`3b8ee6ea590a4c08ee242850e48d4a701df2eb1f2aaa9d48594a004c5dbc7744`.
The preserved cargo-audit 0.22.2 report identifies the RustSec database revision
and every finding. It reports one vulnerability and two maintenance notices;
this is not a zero-finding audit.

## RSA timing advisory

[RUSTSEC-2023-0071](https://rustsec.org/advisories/RUSTSEC-2023-0071.html)
affects rsa 0.9.10 and has no patched version. It concerns observable private-key
operations. The selected Arti client path verifies relay/directory public-key
signatures; Winnow neither runs a relay nor exposes RSA signing/decryption.
Wallet transaction keys never enter the Tor bridge.

The locked tor-llcrypto source's `pk/rsa.rs` documents that Tor clients do not
need RSA private keys. The bridge only calls TorClient::create_bootstrapped,
isolated_client and connect. Its resolved arti-client features are compression,
onion-service-client, rustls, static-sqlite and tokio (plus derived internal
features). tor-proto has hs-client and no relay feature. Rustls uses ring and
has no client-certificate configuration here. Review these paths again before
adding relay, onion-service hosting, key-management or client-authentication APIs.

This is a scoped non-reachability assessment for this client configuration, not
a claim that the rsa dependency is repaired or generally safe. Primary source:
[Arti revision a71097f, RSA implementation](https://gitlab.torproject.org/tpo/core/arti/-/blob/a71097fdf7b141b56d1eb3709628ee38d232c9d1/crates/tor-llcrypto/src/pk/rsa.rs).

## Maintenance notices

Bincode 2.0.1 (RUSTSEC-2025-0141) and paste 1.0.15 (RUSTSEC-2024-0436) are
unmaintained upstream dependencies. Neither advisory in this database revision
reports an exploitable defect. They remain update risks tracked here; future
advisories require fresh review. Replacing Arti's internal serialization or
macro dependencies locally would fork the pinned upstream implementation.

The build checks locked source and license evidence. Run cargo-audit against a
fresh RustSec database at release and preserve the complete result. Do not hide
new findings with broad ignores or present this report as independent review.
