#!/usr/bin/env sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
CORE_DIR="$ROOT/c_src/aliCore"

echo "Building aliCore (release) ..."
cd "$CORE_DIR"
cargo build --release
cd "$ROOT"
sh "$ROOT/priv/scripts/copy_core.sh"
