# ali

运行在 Erlang/OTP 节点内的 **AI 开发助手** OTP 应用。集成大模型 HTTP 客户端、Agent 工具调用、代码索引、Web UI，用于项目问答、运行时诊断、受控函数执行与代码修改。

**对外唯一 API 入口：[`ali`](src/ali.erl)** — 无需直接调用内部模块。

## 功能概览

| 能力 | 说明 |
|------|------|
| **Agent 问答** | 多轮对话、工具自动调用、流式/异步任务 |
| **项目分析** | 读文件、代码索引、AST 调用关系、依赖图 |
| **运行时诊断** | 进程、应用、监督树、节点信息 |
| **受控执行** | 黑名单 `callFunction`、EUnit 运行 |
| **代码修改** | `writeFile` / `patchFile` / `compileLoad`（需策略与确认） |
| **LLM 直连** | `ali:llmChat/2` 等，绕过 Agent 直接调模型 |
| **Web UI** | 可选 HTTP 界面（默认端口 8088） |

## 环境要求

- Erlang/OTP **27+**（内置 JSON）
- [hackney](https://github.com/benoitc/hackney) 4.3.0+
- [eWSrv](https://github.com/SisMaker/eWSrv)（Web UI，已列入 `rebar.config` deps）

## 快速开始

```bash
# 1. 准备配置
copy config\config.example.cfg config\config.cfg
# 编辑 config\config.cfg，填入 api_key

# 2. 编译并进入 shell（自动启动 ali 应用）
rebar3 compile
rebar3 shell
```

```erlang
%% 3. Agent 交互
ali:chat().                              %% 终端多轮对话（推荐）
ali:askPrint("这个项目有哪些模块？").     %% 单次提问并打印

%% 4. 查看状态与工具
ali:status().
ali:tools().

%% 5. 直连 LLM（不经 Agent）
ali:llmLoadConfig().
ali:llmChat(<<"deepseek-v4-flash">>, [llmCli:userMessage("你好")]).
```

## 配置

在项目根目录 `config/` 下创建 `config.cfg`（可复制 [`config/config.example.cfg`](config/config.example.cfg)），应用启动时由 `ali_app` 自动加载。

```erlang
{provider, deepseek}.
{api_key, "your-api-key-here"}.
{model, "deepseek-v4-flash"}.
{projectRoot, "."}.
{maxSteps, 25}.
{mode, ask}.
{webPort, 8088}.
{webEnabled, false}.
```

环境变量可覆盖配置文件（优先级更高）：

| 变量 | 说明 |
|------|------|
| `LLM_CONFIG_FILE` | 配置文件路径 |
| `LLM_API_KEY` | API 密钥 |
| `LLM_PROVIDER` | 提供商 |
| `LLM_BASE_URL` | API 地址 |
| `LLM_MODEL` | 模型名 |
| `LLM_AGENT_MODEL` | Agent 专用模型 |
| `LLM_AGENT_PROJECT_ROOT` | 项目根目录 |

详细说明见 [priv/docs/LLM.md](priv/docs/LLM.md)、[priv/docs/CONFIG.md](priv/docs/CONFIG.md)。

## Agent API 速查

完整 API 见 [priv/docs/API.md](priv/docs/API.md)。

### 生命周期

```erlang
{ok, Pid} = ali:start().          %% 确保应用已启动并加载配置
ali:stop().                        %% 停止 alServer（不停止整个应用）
ali:health().                      %% 健康检查
```

### 问答

```erlang
{ok, Answer} = ali:ask("解释 alLoop 的工作流程").
{ok, Answer} = ali:ask(Prompt, #{sessionId => <<"dev">>, mode => ask}).
{ok, Answer} = ali:askStream(Prompt).   %% 流式：{ali, stream, Chunk}
{ok, TaskId} = ali:askAsync(Prompt).    %% 异步：ali:taskStatus(TaskId)
```

### 会话

```erlang
ali:saveSession(<<"dev">>).        %% 保存到 .al/sessions/
ali:loadSession(<<"dev">>).
ali:clearSession().
ali:savedSessions().
```

### 模式与策略

| 模式 | 说明 |
|------|------|
| `ask` | 只读：分析、问答 |
| `edit` | 可写文件（需 `allowWrite => true`） |
| `exec` | 可执行函数（仅 `execBlacklist` 拦截）、编译加载 |

```erlang
ali:setMode(edit).
ali:setConfig(policy, alPolicy:defaultPolicy()#{allowWrite => true}).
{ok, _} = ali:approve(TaskId).     %% 确认待执行的写操作
```

### Web UI

```erlang
{ok, 8088} = ali:startWeb().       %% 或 config.cfg 中 webEnabled => true
%% 浏览器打开 http://127.0.0.1:8088/
ali:webStatus().
ali:stopWeb().
```

## 项目结构

```
ali/
├── src/
│   ├── ali.erl              # 对外 API（Facade）
│   ├── ali_app.erl          # OTP 应用回调
│   ├── ali_sup.erl          # 监督者（alCodeIndexer + alServer）
│   ├── agent/               # Agent 运行时
│   │   ├── alServer.erl     # 会话/配置 gen_server
│   │   ├── alLoop.erl       # LLM ↔ 工具 推理循环
│   │   ├── alTools.erl      # 工具注册与调度
│   │   └── ...
│   ├── tools/               # 各工具实现（alTool*）
│   ├── analysis/            # 代码索引与 AST
│   ├── core/                # llmCli、llmCliConfig、llmJson
│   └── web/                 # alWebHer、alWebSrv
├── priv/
│   ├── docs/                # 项目文档
│   └── web/                 # Web UI 静态资源
├── config/config.example.cfg
├── test/
└── rebar.config
```

架构说明见 [priv/docs/ARCHITECTURE.md](priv/docs/ARCHITECTURE.md)。

## 数据目录

Agent 运行时数据保存在项目根目录 `.al/` 下：

| 路径 | 内容 |
|------|------|
| `.al/sessions/` | 持久化会话 JSON |
| `.al/backups/` | 文件编辑前备份 |
| `.al/audit.jsonl` | 工具调用审计日志 |
| `index.dets` | 代码索引缓存 |

## 测试

```bash
rebar3 eunit
```

- `test/alTests.erl` — Agent、工具、索引等
- `test/llmCliTests.erl` — LLM 客户端与配置

运行 `llmCliTests` 使用 `config/config.example.cfg`，无需额外准备。

### 命令行（escript）

```bash
rebar3 escriptize
_build/default/bin/ali ask "项目有哪些模块？"
_build/default/bin/ali chat
_build/default/bin/ali approve <taskId>
```

## 文档

| 文档 | 说明 |
|------|------|
| [priv/docs/README.md](priv/docs/README.md) | 文档索引 |
| [priv/docs/API.md](priv/docs/API.md) | `ali` 模块完整 API |
| [priv/docs/LLM.md](priv/docs/LLM.md) | LLM 直连 API（`llmCli`） |
| [priv/docs/CONFIG.md](priv/docs/CONFIG.md) | 配置项说明 |
| [priv/docs/ARCHITECTURE.md](priv/docs/ARCHITECTURE.md) | 模块架构与数据流 |
| [priv/docs/TOOLS.md](priv/docs/TOOLS.md) | Agent 工具列表 |
| [priv/docs/AGENT_DEVELOPMENT_PLAN.md](priv/docs/AGENT_DEVELOPMENT_PLAN.md) | 设计与实现历程 |

## 许可证

MIT
