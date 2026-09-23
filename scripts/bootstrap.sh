#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEP_DIR="$ROOT_DIR/.deps"
PQ_REV="1d7dda453dd385f3ede84c39eed5d20afe34e02a"
WINNOW_REV="a1cc6fbaf6f0d3d68c675e1a78e8d5b8311767f7"

checkout_at() {
  local name="$1" url="$2" revision="$3"
  local destination="$DEP_DIR/$name"
  if [[ ! -d "$destination/.git" ]]; then
    git clone --filter=blob:none --no-checkout "$url" "$destination"
  fi
  if [[ "$(git -C "$destination" rev-parse HEAD 2>/dev/null || true)" != "$revision" ]]; then
    git -C "$destination" fetch --depth=1 origin "$revision"
  fi
  git -C "$destination" checkout --detach "$revision"
  if [[ "$(git -C "$destination" rev-parse HEAD)" != "$revision" ]]; then
    echo "Failed to pin $name to $revision" >&2
    exit 1
  fi
  echo "$name: $revision"
}

mkdir -p "$DEP_DIR"
checkout_at pq-rust-lightning https://github.com/ahmet-kurt/pq-rust-lightning.git "$PQ_REV"
checkout_at winnow https://github.com/winnowwallet/winnow.git "$WINNOW_REV"
