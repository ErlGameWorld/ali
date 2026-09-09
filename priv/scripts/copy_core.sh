#!/usr/bin/env sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/c_src/aliCore/target/release/aliCore"

if [ ! -f "$SRC" ]; then
  echo "Skip copy_core: $SRC not found (run cargo build --release first)"
  exit 0
fi

for DST in \
  "$ROOT/priv/aliCore" \
  "$ROOT/_build/default/lib/ali/priv/aliCore" \
  "$ROOT/_build/test/lib/ali/priv/aliCore"
do
  DST_DIR="$(dirname "$DST")"
  if [ ! -d "$DST_DIR" ]; then
    if echo "$DST" | grep -q "_build"; then
      echo "Skip copy_core: $DST_DIR not present yet"
      continue
    fi
    mkdir -p "$DST_DIR"
  fi
  cp -f "$SRC" "$DST"
  chmod +x "$DST" 2>/dev/null || true
  echo "Copied aliCore -> $DST"
done
