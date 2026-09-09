#!/usr/bin/env bash
# Non-LLM system verify (requires compiled app + running shell context).
# Usage from rebar3 shell:
#   alVerify:run(alVerify:nonLlmCategories()).
set -euo pipefail
cd "$(dirname "$0")/../.."
rebar3 compile
rebar3 eunit --module=alIntegration_tests
rebar3 eunit --module=alBoot_tests
mkdir -p logs/ct
rebar3 ct --suite=test/ali_SUITE
echo "OK: compile + integration eunit + CT"
