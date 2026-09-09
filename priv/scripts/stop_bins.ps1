# Stop runtime binaries so rebar3 clean can delete _build/priv copies.
$ErrorActionPreference = "SilentlyContinue"
foreach ($Name in @("aliCore", "ali_core", "qdrant")) {
    Get-Process -Name $Name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
exit 0
