# Non-LLM verify for Windows.
# From rebar3 shell after compile: alVerify:run(alVerify:nonLlmCategories()).
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..\..")

function Invoke-Step {
    param([string]$Name, [scriptblock]$Cmd)
    & $Cmd
    if ($LASTEXITCODE -ne 0) {
        Write-Error "$Name failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
}

Invoke-Step "rebar3 compile" { rebar3 compile }
Invoke-Step "rebar3 eunit alIntegration_tests" { rebar3 eunit --module=alIntegration_tests }
Invoke-Step "rebar3 eunit alBoot_tests" { rebar3 eunit --module=alBoot_tests }

New-Item -ItemType Directory -Force -Path logs\ct | Out-Null
try {
  rebar3 ct --suite=test/ali_SUITE
  if ($LASTEXITCODE -ne 0) {
    Write-Error "rebar3 ct failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
  }
} catch {
  Write-Error "rebar3 ct failed: $_"
  exit 1
}
Write-Host "OK: compile + integration eunit + CT"
