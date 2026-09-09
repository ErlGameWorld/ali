# Package ali release into _rel/ali (Windows)
# Usage: powershell -File priv/scripts/package_release.ps1
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Rel = Join-Path $Root "_rel\ali"

Write-Host "Building prod release ..."
Push-Location $Root
try {
    rebar3 as prod release
    if ($LASTEXITCODE -ne 0) {
        Write-Error "rebar3 as prod release failed"
        exit $LASTEXITCODE
    }
} finally {
    Pop-Location
}

$Built = Join-Path $Root "_build\prod\rel\ali"
if (-not (Test-Path $Built)) {
    Write-Error "Expected release dir not found: $Built"
    exit 1
}

# Copy to stable location (exclude rebar3-internal symlink/junk)
if (Test-Path $Rel) {
    Remove-Item -Recurse -Force $Rel
}
Copy-Item -Recurse $Built $Rel

Write-Host "OK: packaged release at $Rel"
Write-Host "启动：$Rel\bin\ali.cmd  (自包含；需本机已装 OTP)"
Write-Host "自包含（含 ERTS）：rebar3 as prod release，然后整目录拷贝 _build/prod/rel/ali"
