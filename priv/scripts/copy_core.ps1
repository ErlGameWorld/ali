# Copy aliCore release binary into priv/ and rebar _build priv (no-op if not built yet)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Src = Join-Path $Root "c_src\aliCore\target\release\aliCore.exe"
$Targets = @(
    (Join-Path $Root "priv\aliCore.exe"),
    (Join-Path $Root "_build\default\lib\ali\priv\aliCore.exe"),
    (Join-Path $Root "_build\test\lib\ali\priv\aliCore.exe")
)

if (-not (Test-Path $Src)) {
    Write-Host "Skip copy_core: $Src not found (run cargo build --release first)"
    exit 0
}

$SrcLen = (Get-Item $Src).Length
$Copied = 0
$Skipped = 0

foreach ($Dst in $Targets) {
    $DstDir = Split-Path -Parent $Dst
    $DirExists = $false
    try {
        $DirExists = Test-Path -LiteralPath $DstDir -ErrorAction Stop
    } catch {
        # Network share / ACL may deny Test-Path even when the path is usable
        $DirExists = $false
    }
    if (-not $DirExists) {
        # _build may not exist yet; priv always should
        if ($Dst -like "*_build*") {
            Write-Host "Skip copy_core: $DstDir not present yet (rebar3 compile will sync priv/)"
            continue
        }
        try {
            New-Item -ItemType Directory -Force -Path $DstDir | Out-Null
        } catch {
            Write-Host "Skip copy_core: cannot create $DstDir — $($_.Exception.Message)"
            continue
        }
    }
    try {
        # Write to .new then replace — reduces partial-lock races
        $Tmp = "$Dst.new"
        Copy-Item $Src $Tmp -Force -ErrorAction Stop
        Move-Item $Tmp $Dst -Force -ErrorAction Stop
        Write-Host "Copied aliCore.exe -> $Dst ($SrcLen bytes)"
        $Copied++
    } catch {
        Remove-Item "$Dst.new" -Force -ErrorAction SilentlyContinue
        Write-Host "WARN: cannot update $Dst — file in use. Stop aliCore/erl then re-run: priv\scripts\copy_core.ps1"
        Write-Host "      $($_.Exception.Message)"
        $Skipped++
    }
}

if ($Skipped -gt 0) {
    Write-Host ""
    Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    Write-Host " WARN: $Skipped aliCore target(s) still OLD (file locked)."
    Write-Host " Runtime will NOT include Rust fixes until you:"
    Write-Host "   1) Stop erl / aliCore"
    Write-Host "   2) priv\scripts\copy_core.ps1"
    Write-Host "   3) Restart (priv\scripts\start.ps1)"
    Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    Write-Host ""
}
