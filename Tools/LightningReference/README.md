# Host reference implementations

The application does not depend on this directory. The root Swift package uses
WalletCore, its existing P256K dependency and CryptoKit.

`Cargo.lock` records the dependencies resolved for unmodified LDK commit
`0a2b003e7e1602df8933b15b7563ba8b6e198391`. `scripts/ci-lightning-references`
copies this lockfile into a disposable upstream checkout and uses `--locked`.
It changes no protocol source. The script builds stock Core Lightning v26.06.8
and runs both LDK async test configurations: std and its test-controlled clock.
The latter includes expiry/timeout tests intentionally ignored with std time.

Reference self-tests establish fixture behavior; they are not evidence that
Winnow implements async payments. `ci-lightning-peer` independently exercises
the Swift engine over BOLT 8 TCP against Core Lightning and checks final
transactions with Bitcoin Core.
