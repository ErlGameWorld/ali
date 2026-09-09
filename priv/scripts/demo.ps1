# ali 端到端演示（Windows）— 走 Erlang HTTP Gateway（默认 8787）
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Base = "http://127.0.0.1:8787"

Write-Host "== 1. Health check =="
try {
    Invoke-RestMethod -Uri "$Base/health" -Method Get | ConvertTo-Json
} catch {
    Write-Host "ali 网关未启动。先用 priv/scripts/start.ps1 或 rebar3 shell 启动，再重试。"
    exit 1
}

Write-Host "`n== 2. 工具调用 searchCode =="
$body = @{ tool = "searchCode"; args = @{ query = "ask"; limit = 3 } } | ConvertTo-Json -Depth 6
Invoke-RestMethod -Uri "$Base/tool" -Method Post -ContentType "application/json" -Body $body | ConvertTo-Json -Depth 6

Write-Host "`n== 3. 流式问答 ask/stream =="
$q = @{ prompt = "解释 ali_sup 的监督树"; sessionId = "demo" } | ConvertTo-Json
try {
    $resp = Invoke-WebRequest -Uri "$Base/api/ask/stream" -Method Post -ContentType "application/json" -Body $q
    Write-Host "HTTP $($resp.StatusCode)"
    $resp.Content
} catch {
    Write-Host "流式端点调用失败（可能是未配置 LLM key）：$($_.Exception.Message)"
}

Write-Host "`nDemo complete. 更多端点见 priv/docs/mcp.md"
