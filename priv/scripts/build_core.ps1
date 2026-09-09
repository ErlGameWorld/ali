# Build aliCore (release) and copy into priv/
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$CoreDir = Join-Path $Root "c_src\aliCore"

Write-Host "Building aliCore (release) ..."
Push-Location $CoreDir
try {
    cargo build --release
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
} finally {
    Pop-Location
}

& (Join-Path $PSScriptRoot "copy_core.ps1")
