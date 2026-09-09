# Start Erlang shell (config: config/aliCfg.cfg)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $Root
try {
    rebar3 shell
} finally {
    Pop-Location
}
