#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT_DIR/scripts/bootstrap.sh"
cargo test --manifest-path "$ROOT_DIR/crates/pq-invoice-verify/Cargo.toml"
swift test --package-path "$ROOT_DIR/ChainWatch"
"$ROOT_DIR/scripts/regtest-smoke.sh"
