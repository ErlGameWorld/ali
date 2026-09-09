# Start ali MCP server on stdio (for Cursor / IDE)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Ebin = Join-Path $Root "_build\default\lib\ali\ebin"

if (-not (Test-Path $Ebin)) {
    Push-Location $Root
    rebar3 compile | Out-Null
    Pop-Location
}

$env:ALI_ROOT = $Root
$env:ALI_DB_PATH = Join-Path $Root "priv\db\ali.db"
$env:ALI_DB_SCHEMA = Join-Path $Root "priv\db\schema.sql"
$env:ALI_INDEX_DIR = Join-Path $Root "priv\index\tantivy"

& erl -noshell -pa $Ebin -config (Join-Path $Root "config\sys.config") -s alMcp stdio
