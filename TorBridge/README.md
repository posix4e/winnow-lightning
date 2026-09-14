# App-owned Tor bridge

The iOS app links this C ABI XCFramework. WalletCore and the census do not
acquire a Rust dependency. `scripts/build-tor-bridge` builds device arm64 and
simulator arm64/x86_64 from Cargo.lock with Rust 1.97.1; it never downloads a
prebuilt Tor binary. Arti and matching Tor crates are pinned to 0.46.0.

The bridge bootstraps before exposing a loopback-only SOCKS listener. Each
SOCKS stream gets an isolated Tor client. Only CONNECT is supported; I2P and
local destinations are rejected. The app owns lifecycle, cancellation and
routing policy, and stops the runtime when backgrounded.

## License evidence

`license-inventory.json` records packages selected by cargo-about 0.8.4 for
all supported iOS architectures. It includes build dependencies. Its Cargo.lock
hash must match. `license-sources/` contains the actual license texts under
content hashes, with immutable upstream sources recorded when a published
crate omitted its license file. The manifest records those exceptions,
including void 1.0.2's missing upstream copyright notice.

Run `scripts/render-tor-notices` to render the text and offline HTML shipped
in Settings. `--check` verifies the lockfile, every evidence hash and both
rendered outputs without using the network. Builds fail when these diverge.

When updating dependencies, regenerate the package selection with the pinned
cargo-about tool and `about.toml`, review its output, and update the inventory
and source texts. Do not accept synthesized placeholder copyright lines:
retrieve the license from the package's recorded upstream revision instead.
Preserve source URLs and revisions. Re-render and run the dependency checks.
`notices.hbs` is an extraction aid, not the shipping renderer.

Real network tests are opt-in: the native proxy example and the physical-device
LiveTorDeviceTests journey. Ordinary tests use injected drivers and local SOCKS
fixtures, so unavailable public nodes cannot make CI appear flaky.
