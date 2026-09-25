# Releasing the Swift regtest research app

Use `WinnowLightning` / `ResearchRelease` for the existing
`com.btcswift.lightning` app (App Store Connect app `6815392502`). It uses the
`Winnow-Lightning-SwiftV2` storage namespace, device-only keys and no iCloud
entitlement. Keep the older application's files intact. Never import a legacy
PQLN journal into this engine.

## Evidence before distribution

The required `CI` workflow must pass for the exact clean source commit. It
includes the ordinary Winnow checks and signet journey, independent pinned CLN
and LDK peers, recipient-never-returns recovery, and the recorded Swift app
journey. The latter captures actual SIGKILLs, independent provider receipts,
funding, exact Apple Share/Copy bytes, offline settlement, restored history and
cooperative close returning funds to the Winnow wallet.

Run the same recorded journey on iPad and with accessibility text before release.
Use `SIMULATOR_ID`, `DERIVED_DATA` and `scripts/ci-lightning-ui`; each run needs a
fresh results directory. `--skip-build` reuses the already built test bundles.
Set the simulator's text size with `xcrun simctl ui <id> content_size
accessibility-extra-extra-extra-large`, record its value, and restore it afterward.
Keep the screenshots, video, xcresult, manifest and independent receipts.

On a physical device, verify successful and canceled device-owner authentication
for funding, payment and close; no mutation or publication after cancellation;
exact Share/Copy bytes; and journal/key protection while the device is locked.
`LightningAppTests` checks the stored Keychain attributes and the journal's
complete file-protection class. A simulator that cannot record the protection
class explicitly skips that assertion and cannot satisfy the physical gate.
Retain the device model/OS, source commit, observations and test results. Do not
mark these checks passed from simulated authentication.

## Encryption determination

ResearchRelease defaults `ITSAppUsesNonExemptEncryption` to YES until reviewed.
This is a conservative build default, not a legal classification. Review the
actual linked code: Lightning Noise/onion transport and storage encryption use
CryptoKit and P256K/libsecp256k1, including implementations outside the OS. A
rewrite in Swift does not itself establish an exemption. The ordinary target
also links LightningCore and needs its declaration reviewed before distributing
this change under that bundle.

[Apple's encryption guidance](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)
requires the determination to include linked libraries. Retain either a reasoned
exemption determination or the approved App Store Connect declaration belonging
to this app. Review applicable reporting and destination requirements as part
of that determination. This script does not change country availability or
create declarations from assumptions about particular countries.

## Exact-source release command

Create an evidence JSON outside the checkout. Every artifact path is relative
to that file, contained in its directory, and SHA-256 verified. For example
(the placeholders and pending values deliberately do not pass):

```json
{
  "source": "<40-character tested commit>",
  "bundle": "com.btcswift.lightning",
  "physical_device": false,
  "checks": {
    "owner_authentication": "pending",
    "cancelled_authentication": "pending",
    "file_protection": "pending",
    "exact_share": "pending",
    "ipad": "pending",
    "large_text": "pending"
  },
  "artifacts": [{"path": "review.md", "sha256": "<artifact SHA-256>"}],
  "encryption": {
    "mode": "declaration",
    "declaration_id": "<approved ASC declaration ID>",
    "reviewed_by": "<responsible reviewer>",
    "rationale": "<determination for this source and distribution>",
    "artifact": "review.md"
  }
}
```

For a reviewed exemption, use `mode: exempt` and omit `declaration_id`. The
release script sets and verifies the archive's encryption value accordingly.
For non-exempt encryption it verifies Apple's APPROVED state and app ownership,
then links and reads back the declaration on the exact processed build.

Set `ASC_KEY_ID`, `ASC_ISSUER_ID`, and optionally `ASC_KEY_PATH` using existing
release credentials. Do not commit or include private keys in evidence. Choose a
new version/build after inspecting the existing app. Use an output directory
outside the checkout:

```sh
scripts/release-lightning --commit <exact-green-SHA> \
  --version <version> --build <build> \
  --evidence /path/to/review/evidence.json --output /path/to/new-release
```

Without `--upload`, this signs, archives, exports and inspects the distribution
package. Add `--upload` to perform the already authorized internal rollout.
It verifies bundle/team/version/build, ARM64, no iCloud or Debug hooks, dependency
policy and supply-chain metadata; uploads the inspected package; waits for VALID
processing; updates What to Test; and verifies membership and tester availability
in the existing `PQLNRegtestInternal` group. It never creates a replacement app or
public beta group. A release is complete only when `release.json` records the
processed build and `uploaded: true` after the final readbacks.
