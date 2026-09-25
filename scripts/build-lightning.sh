#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
native_dir="$repo_dir/Native/LightningBridge"
artifact_dir="$repo_dir/Lightning/Artifacts"
targets=(aarch64-apple-darwin)
case "${1:---all}" in
  --all) targets+=(aarch64-apple-ios aarch64-apple-ios-sim) ;;
  --mac-only) ;;
  *) echo 'Usage: build-lightning.sh [--all|--mac-only]' >&2; exit 2 ;;
esac
libraries=()
for target in "${targets[@]}"; do
  case "$target" in
    aarch64-apple-ios) sdk=iphoneos ;;
    aarch64-apple-ios-sim) sdk=iphonesimulator ;;
    *) sdk=macosx ;;
  esac
  MACOSX_DEPLOYMENT_TARGET=14.0 IPHONEOS_DEPLOYMENT_TARGET=17.0 \
    SDKROOT="$(xcrun --sdk "$sdk" --show-sdk-path)" \
    cargo build --manifest-path "$native_dir/Cargo.toml" --locked --target "$target"
  libraries+=(-library "$native_dir/target/$target/debug/libwinnow_lightning_bridge.a" -headers "$native_dir/include")
done
mkdir -p "$artifact_dir"
staging_dir="$(mktemp -d "$artifact_dir/.build.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
xcodebuild -create-xcframework "${libraries[@]}" -output "$staging_dir/CLightningBridge.xcframework"
rm -rf "$artifact_dir/CLightningBridge.xcframework"
mv "$staging_dir/CLightningBridge.xcframework" "$artifact_dir/CLightningBridge.xcframework"
