# MCP / IDE 集成

ali 通过 **MCP (Model Context Protocol)** 和 **HTTP Gateway** 对外暴露统一 Tool 协议。

## 统一调用格式

工具名支持 camelCase 与 snake_case：

```json
{"tool": "searchCode", "args": {"query": "gen_server", "limit": 5}}
```

```json
{"tool": "search_code", "args": {"query": "gen_server", "limit": 5}}
```

## Cursor MCP 配置

项目包含 [`.cursor/mcp.json`](../../.cursor/mcp.json)。在 Cursor 设置中启用 MCP 后，ali 工具会出现在 Agent 工具列表。

手动启动（stdio）：

```powershell
.\priv\scripts\mcp.ps1
```

```bash
chmod +x priv/scripts/mcp.sh
./priv/scripts/mcp.sh
```

### MCP 能力

`initialize` 返回的 `capabilities` 声明三类子协议：

```json
{"capabilities": {"tools": {}, "resources": {}, "prompts": {}}}
```

#### Tools 子协议

- `tools/list` → `alToolCatalog:mcpTools/0`
- `tools/call` → `{name, arguments}`；失败时 `isError=true`
- `ping` → 空结果（保活）

#### Resources 子协议

- `resources/list` / `resources/read`：`ali://config`、`ali://schema/sql`、`ali://tools`

#### Prompts 子协议

- `prompts/list` / `prompts/get`：`explain_module` / `trace_callers` / `find_bottleneck` / `review_patch` / `draft_refactor`

## HTTP Gateway

默认端口 **8787**（`config/aliCfg.cfg` 中 `web.port` / `gateway.port`；`config/sys.config` 仅作 rebar/shell 占位）。

```bash
curl -X POST http://127.0.0.1:8787/tool \
  -H "content-type: application/json" \
  -d '{"tool":"searchCode","args":{"query":"gen_server","limit":5}}'
```

流式问答（走完整 Agent 工具循环）：

```bash
curl -N -X POST http://127.0.0.1:8787/api/ask/stream \
  -H "content-type: application/json" \
  -d '{"prompt":"解释 ali_sup","sessionId":"web"}'
```

Checkpoint：

```bash
curl http://127.0.0.1:8787/api/checkpoints
curl -X POST http://127.0.0.1:8787/api/checkpoints/resume \
  -H "content-type: application/json" \
  -d '{"taskId":"<id>"}'
```
