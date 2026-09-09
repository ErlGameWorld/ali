# End-to-end smoke: compile, boot ali, check processes + DeepSeek LLM config.
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $Root

Write-Host "==> rebar3 compile"
rebar3 compile
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$Ebin = Join-Path $Root "_build\default\lib\ali\ebin"
Write-Host "==> compile smoke_boot"
erlc -o $Ebin -I (Join-Path $Root "include") (Join-Path $Root "priv\scripts\smoke_boot.erl")
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$PathLine = (rebar3 path | Select-Object -Last 1).ToString().Trim()
$Paths = $PathLine.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)
$PaArgs = @()
foreach ($p in $Paths) { $PaArgs += @("-pa", $p) }

Write-Host "==> boot smoke"
& erl -noshell @PaArgs -eval "smoke_boot:main()."
exit $LASTEXITCODE
