#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EBIN="$ROOT/_build/default/lib/ali/ebin"

if [ ! -d "$EBIN" ]; then
  (cd "$ROOT" && rebar3 compile)
fi

export ALI_ROOT="$ROOT"
export ALI_DB_PATH="$ROOT/priv/db/ali.db"
export ALI_DB_SCHEMA="$ROOT/priv/db/schema.sql"
export ALI_INDEX_DIR="$ROOT/priv/index/tantivy"

exec erl -noshell -pa "$EBIN" -config "$ROOT/config/sys.config" -s alMcp stdio
