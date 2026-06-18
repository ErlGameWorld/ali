# ali 模块 API 参考

`ali` 是 **唯一对外 API 入口**（Facade）。内部实现分散在 `alServer`、`llmCli` 等模块，使用者无需直接依赖它们。

源码：[`src/ali.erl`](../../src/ali.erl)

---

## 一、Agent API

### 生命周期

| 函数 | 说明 | 返回值 |
|------|------|--------|
| `start/0` | 确保 `ali` 应用已启动，加载配置，验证 `alServer` | `{ok, Pid}` \| `{error, agentNotStarted}` |
| `start/1` | 启动并应用额外配置（map 或 proplist） | 同上 |
| `stop/0` | 停止 `alServer` 子进程（不停止整个应用） | `ok` |
| `health/0` | 健康检查（server、web、configLoaded） | `#{status, server, web, node, configLoaded}` |

### 问答

| 函数 | 说明 |
|------|------|
| `ask/1`, `ask/2` | 向 Agent 提问；`Opts` 支持 `sessionId`、`mode` |
| `askStream/1`, `askStream/2` | 流式提问；调用进程收到 `{ali, stream, Chunk}`、`{stream_chunk, Chunk}` |
| `askAsync/1`, `askAsync/2` | 后台异步；返回 `{ok, TaskId}` |
| `askPrint/1`, `askPrint/2` | 提问并打印 UTF-8 回复 |
| `print/1` | 格式化打印 Agent 回复 |
| `chat/0`, `chat/1` | 终端交互式多轮对话（支持 `/help`、`/config` 等命令） |

**Opts 示例：**

```erlang
ali:ask("分析问题", #{
    sessionId => <<"dev">>,
    mode => ask
}).
```

### 函数执行与审批

| 函数 | 说明 |
|------|------|
| `run/1` | `run({Mod, Fun, Args})` — exec 模式执行（黑名单拦截） |
| `run/3` | `run(Mod, Fun, Args)` |
| `approve/1` | 确认待执行的写操作（edit 模式返回的 TaskId） |

### 状态与工具

| 函数 | 说明 |
|------|------|
| `status/0` | Agent 运行时快照 |
| `tools/0` | 可用工具名称列表 |
| `sessions/0` | 内存中活跃会话概要 |
| `auditLog/0`, `auditLog/1` | 工具调用审计日志 |
| `auditClear/0` | 清空审计日志 |
| `tokenStats/0`, `resetTokenStats/0` | Token 用量统计 |
| `backupCleanup/0` | 清理过期文件备份 |

### 会话管理

| 函数 | 说明 |
|------|------|
| `clearSession/0`, `clearSession/1` | 清空会话历史 |
| `saveSession/0`, `saveSession/1` | 持久化到 `.al/sessions/` |
| `loadSession/1` | 从磁盘恢复 |
| `deleteSavedSession/1` | 删除已保存会话 |
| `savedSessions/0` | 列出已保存会话 ID |

### 异步任务

| 函数 | 说明 |
|------|------|
| `taskStatus/1` | 查询 `askAsync` 任务状态与结果 |
| `cancelTask/1` | 取消运行中任务 |
| `tasks/0` | 列出所有异步任务 |

### Agent 配置与上下文

| 函数 | 说明 |
|------|------|
| `setConfig/2`, `getConfig/0` | Agent 配置 |
| `getMode/0`, `setMode/1` | 模式：`ask` \| `edit` \| `exec` |
| `getWorkingContext/0`, `addContext/2`, `clearContext/0` | 工作上下文 |
| `refreshIndex/0` | 刷新代码索引 |
| `loadConfigFromEnv/0` | 从环境变量加载 Agent 配置 |

### Web UI

| 函数 | 说明 |
|------|------|
| `startWeb/0` | 启动 HTTP 服务 |
| `stopWeb/0` | 停止 Web 服务 |
| `webStatus/0` | 运行状态与端口 |

---

## 二、LLM 直连 API（`llm*` 前缀）

> 详细说明见 [LLM.md](LLM.md)（`llmCli` 模块与消息格式、流式回调等）。

| 函数 | 说明 |
|------|------|
| `llmChat/2`, `llmChat/3` | 聊天请求 |
| `llmChatStream/2`, `llmChatStream/3` | 流式聊天 |
| `setLlmConfig/2`, `getLlmConfig/1,2` | LLM 连接配置 |
| `llmLoadConfig/0,1` | 加载配置文件 |
| `llmLoadConfigFromEnv/0` | 环境变量加载 |
| `llmTokenStats/0`, `llmResetTokenStats/0` | Token 统计 |

消息格式使用 `llmCli:userMessage/1` 等辅助函数。

---

## 三、配置查询 API

| 函数 | 说明 |
|------|------|
| `getAgentConfig/0` | Agent 配置 map |
| `formatAgentConfig/0` | 可读配置文本 |
| `listProviders/0` | 内置提供商列表 |
| `getProvider/1` | 提供商预设信息 |

---

## 四、流式消息协议

```erlang
{ali, stream, Chunk}
{ali, streamDone, done}
{ali, streamError, Reason}
{stream_chunk, Chunk}      %% 兼容别名
{stream_chunk, done}
```

---

## 五、终端对话命令（`ali:chat/0`）

| 命令 | 说明 |
|------|------|
| `/quit`, `/exit` | 退出 |
| `/clear` | 清空会话 |
| `/config` | 查看配置 |
| `/mode [ask\|edit\|exec]` | 切换模式 |
| `/context`, `/context clear`, `/context add ...` | 工作上下文 |
| `/index` | 刷新索引 |
| `/web`, `/web stop` | Web UI |
| `/save`, `/load`, `/session` | 会话持久化 |
| `/status`, `/help` | 状态与帮助 |
