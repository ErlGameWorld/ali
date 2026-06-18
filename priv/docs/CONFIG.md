# 配置说明

ali 使用 Erlang term 格式的 `config.cfg`，通过 `file:consult/1` 读取，应用启动时自动加载到 **`ali` 应用环境**。

示例：[`config/config.example.cfg`](../../config/config.example.cfg)

## 加载顺序

1. `rebar3 shell` → `ali_app` → `llmCliConfig:load/0`
2. 默认 `config/config.cfg`，不存在则回退 `config/config.example.cfg`（兼容根目录遗留路径）
3. 环境变量 `LLM_*` 覆盖文件值
4. 运行时 `ali:setConfig/2`、`ali:setLlmConfig/2`

## LLM 连接

| 键 | 说明 |
|----|------|
| `provider` | `openai` \| `deepseek` \| `anthropic` \| `custom` |
| `api_key` | API 密钥 |
| `base_url` | API 地址（可省略） |
| `model` | 默认模型 |

| provider | 默认 base_url | 默认 model |
|----------|---------------|------------|
| openai | https://api.openai.com/v1 | gpt-4o-mini |
| deepseek | https://api.deepseek.com | deepseek-v4-flash |
| anthropic | https://api.anthropic.com/v1 | claude-3-5-sonnet-20241022 |

## Agent 配置

| 键 | 默认 | 说明 |
|----|------|------|
| `projectRoot` | `"."` | 项目根（工具读写范围） |
| `maxSteps` | 25 | 推理最大步数 |
| `maxMessages` | 40 | 会话历史上限（条数） |
| `maxTokens` | 未设置 | 会话 token 预算（估算裁剪，与 maxMessages 叠加） |
| `modelOptions` | [] | 如 `{temperature, 0.2}` |
| `mode` | ask | ask \| edit \| exec |
| `policy` | 见下 | 工具权限 |
| `backupBeforeEdit` | true | 写前备份 |
| `execBlacklist` | 内置 + 配置 | `callFunction` 禁止的 `{Mod, Fun, Arity}` 列表 |
| `useNativeTools` | true | OpenAI 原生 tool calling |

### policy 默认值

```erlang
allowRead => true,
allowExecuteSafe => true,
allowExecuteRisky => false,
allowWrite => false,
requireWriteConfirmation => true,
requireRiskyConfirmation => true
```

## Web UI

| 键 | 默认 | 说明 |
|----|------|------|
| `webPort` | 8088 | 端口 |
| `webEnabled` | false | 启动时自动开 Web |
| `webApiToken` | "" | 非空时需 URL `?token=...` |

## 环境变量

| 变量 | 覆盖 |
|------|------|
| `LLM_CONFIG_FILE` | 配置文件路径 |
| `LLM_API_KEY` | api_key |
| `LLM_PROVIDER` | provider |
| `LLM_BASE_URL` | base_url |
| `LLM_MODEL` | model |
| `LLM_AGENT_MODEL` | Agent model |
| `LLM_AGENT_PROJECT_ROOT` | projectRoot |
| `LLM_AGENT_USE_NATIVE_TOOLS` | useNativeTools |
