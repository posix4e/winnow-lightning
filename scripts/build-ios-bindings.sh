#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/bootstrap.sh"
cd "$ROOT/.deps/ldk-node"

FEATURES="uniffi,chain-esplora,storage-sqlite,lightning/post-quantum,lightning-invoice/post-quantum,lightning-net-tokio/post-quantum"
BINDINGS="bindings/swift"
export IPHONEOS_DEPLOYMENT_TARGET=17.0

cargo build --lib --no-default-features --features "$FEATURES"
cargo build --profile release-smaller --target aarch64-apple-ios-sim --no-default-features --features "$FEATURES"
if [[ "${1:-all}" != "simulator" ]]; then
  cargo build --profile release-smaller --target aarch64-apple-ios --no-default-features --features "$FEATURES"
fi

cargo run --manifest-path bindings/uniffi-bindgen/Cargo.toml -- \
  generate bindings/ldk_node.udl --lib-file target/debug/libldk_node.a \
  --language swift -o "$BINDINGS"

sed -i '' '4s/^/import SystemConfiguration\n/' "$BINDINGS/LDKNode.swift"
mv "$BINDINGS/LDKNode.swift" "$BINDINGS/Sources/LDKNode/LDKNode.swift"

FRAMEWORK="$BINDINGS/LDKNodeFFI.xcframework"
SIM="$FRAMEWORK/ios-arm64_x86_64-simulator/LDKNodeFFI.framework"
DEVICE="$FRAMEWORK/ios-arm64/LDKNodeFFI.framework"
cp "$BINDINGS/LDKNodeFFI.h" "$SIM/Headers/LDKNodeFFI.h"
cp target/aarch64-apple-ios-sim/release-smaller/libldk_node.a "$SIM/LDKNodeFFI"
if [[ -f target/aarch64-apple-ios/release-smaller/libldk_node.a ]]; then
  cp "$BINDINGS/LDKNodeFFI.h" "$DEVICE/Headers/LDKNodeFFI.h"
  cp target/aarch64-apple-ios/release-smaller/libldk_node.a "$DEVICE/LDKNodeFFI"
fi

python3 - "$FRAMEWORK" <<'PY'
import plistlib
import sys
from pathlib import Path

framework = Path(sys.argv[1])
info = framework / "Info.plist"
with info.open("rb") as file:
    data = plistlib.load(file)
data["AvailableLibraries"] = [
    item for item in data["AvailableLibraries"]
    if item["SupportedPlatform"] == "ios" and
       (framework / item["LibraryIdentifier"] / "LDKNodeFFI.framework" / "LDKNodeFFI").exists()
]
for item in data["AvailableLibraries"]:
    if item.get("SupportedPlatformVariant") == "simulator":
        item["SupportedArchitectures"] = ["arm64"]
    item["MinimumOSVersion"] = "17.0"
with info.open("wb") as file:
    plistlib.dump(data, file)
for item in data["AvailableLibraries"]:
    child = framework / item["LibraryIdentifier"] / "LDKNodeFFI.framework" / "Info.plist"
    with child.open("rb") as file:
        child_data = plistlib.load(file)
    child_data["MinimumOSVersion"] = "17.0"
    with child.open("wb") as file:
        plistlib.dump(child_data, file)
PY

echo "Swift PQLN bindings ready at $FRAMEWORK"
