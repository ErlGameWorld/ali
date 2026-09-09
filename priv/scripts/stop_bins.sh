#!/usr/bin/env sh
# Stop runtime binaries so rebar3 clean can delete _build/priv copies.
pkill -f '[a]liCore' 2>/dev/null || true
pkill -f '[q]drant' 2>/dev/null || true
exit 0
