# 配置说明

ali 使用 Erlang term 格式的 `config.cfg`，通过 `file:consult/1` 读取，应用启动时自动加载到 **`ali` 应用环境**。

示例：[`config/config.example.cfg`](../../config/aliCfg.example.cfg)

## 加载顺序

1. `rebar3 shell` → `ali_app` → `alConfig:load/0`
2. 默认 `config/config.cfg`，不存在则回退 `config/config.example.cfg`（兼容根目录遗留路径）
3. 环境变量 `LLM_*` 覆盖文件值
4. 运行时 `ali:setConfig/2`、`ali:setLlmConfig/2`

## LLM 连接

| 键          | 说明                                                |
|------------|---------------------------------------------------|
| `provider` | `openai` \| `deepseek` \| `anthropic` \| `custom` |
| `api_key`  | API 密钥                                            |
| `base_url` | API 地址（可省略）                                       |
| `model`    | 默认模型                                              |

| provider       | 默认 base_url                                       | 默认 model                   |
|----------------|---------------------------------------------------|----------------------------|
| openai         | https://api.openai.com/v1                         | gpt-4o-mini                |
| deepseek       | https://api.deepseek.com                          | deepseek-v4-flash          |
| anthropic      | https://api.anthropic.com/v1                      | claude-3-5-sonnet-20241022 |
| qwen（通义千问）     | https://dashscope.aliyuncs.com/compatible-mode/v1 | qwen-plus                  |
| kimi（Moonshot） | https://api.moonshot.cn/v1                        | moonshot-v1-8k             |
| zhipu（智谱 GLM）  | https://open.bigmodel.cn/api/paas/v4              | glm-4-flash                |
| ernie（百度文心）    | https://qianfan.baidubce.com/v2                   | ernie-4.0-8k               |
| doubao（字节豆包）   | https://ark.cn-beijing.volces.com/api/v3          | doubao-pro-32k             |
| openrouter     | https://openrouter.ai/api/v1                      | openai/gpt-4o-mini         |

> 除 `anthropic` 走 Messages API 外，其余均按 OpenAI 兼容协议处理；国产模型填好 `provider` + `api_key` 即可使用（
`base_url`/`model` 留空将用上表预设）。

## Agent 配置

| 键                   | 默认      | 说明                                                                  |
|---------------------|---------|---------------------------------------------------------------------|
| `projectRoot`       | `"."`   | 项目根（工具读写范围）                                                         |
| `maxSteps`          | 25      | 推理最大步数                                                              |
| `maxMessages`       | 40      | 会话历史上限（条数）                                                          |
| `maxTokens`         | 未设置     | 会话 token 预算（估算裁剪，与 maxMessages 叠加）                                  |
| `modelOptions`      | []      | 如 `{temperature, 0.2}`                                              |
| `mode`              | ask     | ask \| edit \| exec                                                 |
| `policy`            | 见下      | 工具权限                                                                |
| `backupBeforeEdit`  | true    | 写前备份                                                                |
| `execBlacklist`     | 内置 + 配置 | `callFunction` 禁止的 `{Mod, Fun, Arity}` 列表                           |
| `useNativeTools`    | true    | OpenAI 原生 tool calling                                              |
| `llmMaxRetries`     | 2       | LLM 请求瞬时失败（429/5xx/超时/连接断开）的最大重试次数（指数退避 + jitter）                   |
| `indexExclude`      | `[]`    | 递归遍历/索引额外排除的目录名（叠加内置 `_build`/`.git`/`.al`/`node_modules`/`deps` 等） |
| `systemPromptExtra` | `""`    | 追加到系统提示词末尾的自定义内容（项目约定、回答风格等）                                        |
| `historyCompaction` | true    | 历史超出 `maxMessages` 时，将被裁剪的旧消息压缩为摘要 system 消息（而非直接丢弃）                |

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

| 键                      | 默认    | 说明                                                          |
|------------------------|-------|-------------------------------------------------------------|
| `webPort`              | 8088  | 端口                                                          |
| `webEnabled`           | false | 启动时自动开 Web                                                  |
| `webApiToken`          | ""    | 非空时需 `Authorization: Bearer <token>` 或 `?token=...`（常数时间比较） |
| `webAllowOrigin`       | ""    | CORS 放行来源：`"*"`、单来源或来源列表；默认不放行跨源                            |
| `webRateLimit`         | 240   | 每来源 IP 在窗口内最大请求数（0 关闭）                                      |
| `webRateWindowMs`      | 60000 | 速率窗口长度（毫秒）                                                  |
| `webAllowRemoteWrites` | false | 未配置 token 时是否允许远程写（默认仅本地回环可写）                               |

> 安全说明：未配置 `webApiToken` 时，读请求放行、写请求（POST/PUT/DELETE 及 WebSocket 升级）仅允许本地回环；配置 token
> 后所有受保护端点都需携带 token。响应附带 `X-Content-Type-Options`/`X-Frame-Options`/`Referrer-Policy` 安全头，写请求记录来源
> IP。

## MCP（Model Context Protocol）

`mcpServers` 为 Server 列表，连接后自动发现并注册工具/资源/提示。

| 字段                         | 说明                                       |
|----------------------------|------------------------------------------|
| `name`                     | Server 标识（atom）                          |
| `transport`                | `stdio`（默认）或 `http`（Streamable HTTP/SSE） |
| `command` / `args` / `env` | stdio：可执行文件、参数、环境变量                      |
| `url` / `headers`          | http：端点 URL 与额外请求头                       |
| `level`                    | 注册工具的权限级别（默认 `executeRisky`）             |

```erlang
{mcpServers, [
    #{name => filesystem, command => "npx",
      args => ["-y", "@modelcontextprotocol/server-filesystem", "."],
      env => [], level => executeRisky},
    #{name => remote, transport => http,
      url => "https://example.com/mcp",
      headers => [{"Authorization", "Bearer xxx"}], level => executeRisky}
]}.
```

## 环境变量

| 变量                           | 覆盖             |
|------------------------------|----------------|
| `LLM_CONFIG_FILE`            | 配置文件路径         |
| `LLM_API_KEY`                | api_key        |
| `LLM_PROVIDER`               | provider       |
| `LLM_BASE_URL`               | base_url       |
| `LLM_MODEL`                  | model          |
| `LLM_AGENT_MODEL`            | Agent model    |
| `LLM_AGENT_PROJECT_ROOT`     | projectRoot    |
| `LLM_AGENT_USE_NATIVE_TOOLS` | useNativeTools |
