# ali

运行在 Erlang/OTP 节点内的 **AI 开发助手** OTP 应用。集成大模型 HTTP 客户端、Agent 工具调用、代码索引、Web
UI，用于项目问答、运行时诊断、受控函数执行与代码修改。

**对外唯一 API 入口：[`ali`](src/ali.erl)** — 无需直接调用内部模块。

## 功能概览

| 能力           | 说明                                                                                                       |
|--------------|----------------------------------------------------------------------------------------------------------|
| **Agent 问答** | 多轮对话、工具自动调用、流式/异步任务                                                                                      |
| **项目分析**     | 读文件、代码索引、AST 调用关系、依赖图（Erlang `.erl` + Elixir `.ex`/`.exs`）                                               |
| **语义检索**     | `searchCode` / `ali:searchCode/1` TF-IDF 代码 RAG，按意图定位函数                                                  |
| **任务规划**     | `planSet`/`planUpdate` 多步任务编排（Plan→Execute→Verify）                                                       |
| **运行时诊断**    | 进程、应用、监督树、节点信息、热点进程、调度器                                                                                  |
| **受控执行**     | 黑名单 `callFunction`、EUnit 运行                                                                              |
| **代码修改**     | `writeFile` / `patchFile` / `compileLoad` / `formatCode`（`.erl` 用 erl_tidy，`.ex` 用 mix format）           |
| **Git 集成**   | 只读 `gitStatus` / `gitDiff` / `gitLog` / `gitBranch`                                                      |
| **SVN 集成**   | 只读 `svnStatus` / `svnDiff` / `svnLog` / `svnInfo`                                                        |
| **多模型**      | OpenAI / Anthropic / DeepSeek 及国产 qwen·kimi·zhipu·ernie·doubao                                           |
| **可观测性**     | `ali:metrics/0` 运行指标、`ali:auditQuery/1` 审计检索                                                             |
| **插件化**      | `ali:registerTool/1` 运行时注册自定义工具                                                                          |
| **MCP**      | `ali:mcpConnect/1` 接入 Model Context Protocol Server（stdio / Streamable HTTP-SSE），自动发现工具/资源/提示            |
| **LLM 直连**   | `ali:llmChat/2` 等，绕过 Agent 直接调模型                                                                         |
| **Web UI**   | WebSocket 实时界面（默认端口 8088）：流式问答、可视化 diff 审批、任务/规划/指标面板，WS 不可用自动回退 SSE/REST；安全加固（token 鉴权、CORS 白名单、限速、安全头） |

## 部署到宿主节点

ali 设计为嵌入已有 Erlang 节点运行，而非自带 ERTS 的独立 release。将项目及其依赖打成可复制的 `lib/` 包，在目标节点通过
`code:add_pathz` 加载。

### 打包

```bash
rebar3 release
# 产物：_build/default/rel/ali/lib/
# 可选打 tar 包：rebar3 tar
```

`rebar.config` 中已设置 `{mode, minimal}`、`{include_erts, false}`、`{system_libs, false}`，打包结果**只含 ali 及第三方依赖
**（hackney、jiffy、eWSrv 等），**不含** kernel/stdlib/ssl/crypto 等 OTP 系统库，这些由目标节点已有的 Erlang 提供。

若之前打过旧包、`lib/` 里仍残留 OTP 目录，请先删除 `_build/default/rel` 再执行 `rebar3 release`（`rebar3 clean` 不会清理
release 目录）。

将 `_build/default/rel/ali/lib/` 整个目录复制到目标机，例如 `/opt/ali/lib/`。目标机需已安装兼容版本的 Erlang/OTP。

### 在宿主节点启动

使用 `ali_boot` 模块（随 ali 一同打包在 `lib/ali-*/ebin/` 中）：

```erlang
%% 加载 lib/*/ebin 到 code path
ok = ali_boot:add_paths("/opt/ali"),

%% 启动 ali（内部会 add_paths + ensure_all_started + ali:start）
{ok, _} = ali_boot:start("/opt/ali").
```

宿主节点也可自行实现，逻辑同样简单：

```erlang
add_all_paths(RootDir) ->
	Paths = filelib:wildcard(filename:join([RootDir, "lib", "*", "ebin"])),
	code:add_paths(Paths).
```

## 环境要求

- Erlang/OTP **27+**（内置 JSON）
- [hackney](https://github.com/benoitc/hackney) 4.3.0+
- [eWSrv](https://github.com/SisMaker/eWSrv)（Web UI，已列入 `rebar.config` deps）

## 快速开始

```bash
# 1. 准备配置
copy config\aliCfg.example.cfg aliCfg.cfg
# 或：copy config\aliCfg.example.cfg config\aliCfg.cfg
# 编辑 aliCfg.cfg，填入 api_key

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

配置文件为 Erlang term 格式的 `aliCfg.cfg`，查找顺序：`./aliCfg.cfg` → `./config/aliCfg.cfg`。

可复制 [`config/aliCfg.example.cfg`](config/aliCfg.example.cfg)；`ali_app` 启动时由 `alConfig:load/0` 编译为 `aliCfg` 模块，读取配置使用 `aliCfg:getV(Key)`。

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

| 模式     | 说明                               |
|--------|----------------------------------|
| `ask`  | 只读：分析、问答                         |
| `edit` | 可写文件（需 `allowWrite => true`）     |
| `exec` | 可执行函数（仅 `execBlacklist` 拦截）、编译加载 |

```erlang
ali:setMode(edit).
ali:setConfig(policy, alPolicy:defaultPolicy()#{allowWrite => true}).
{ok, _} = ali:approve(TaskId).     %% 确认待执行的写操作
```

### Web UI

```erlang
{ok, 8088} = ali:startWeb().       %% 或 aliCfg.cfg 中 webEnabled => true
%% 浏览器打开 http://127.0.0.1:8088/
ali:webStatus().
ali:stopWeb().
```

## 项目结构

```
ali/
├── src/
│   ├── ali.erl              # 对外 API（Facade）
│   ├── ali_boot.erl         # 宿主节点 code path 引导与启动
│   ├── ali_app.erl          # OTP 应用回调
│   ├── ali_sup.erl          # 监督者（alCodeIndexer + alServer）
│   ├── agent/               # Agent 运行时
│   │   ├── alServer.erl     # 会话/配置 gen_server
│   │   ├── alLoop.erl       # LLM ↔ 工具 推理循环
│   │   ├── alTools.erl      # 工具注册与调度
│   │   └── ...
│   ├── tools/               # 各工具实现（alTool*）
│   ├── analysis/            # 代码索引与 AST
│   ├── misc/                # alConfig、aliCfg、alKvsToBeam
│   ├── core/                # llmCli、llmJson
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

| 路径                | 内容         |
|-------------------|------------|
| `.al/sessions/`   | 持久化会话 JSON |
| `.al/backups/`    | 文件编辑前备份    |
| `.al/audit.jsonl` | 工具调用审计日志   |
| `index.dets`      | 代码索引缓存     |

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

| 文档                                                                         | 说明                   |
|----------------------------------------------------------------------------|----------------------|
| [priv/docs/README.md](priv/docs/README.md)                                 | 文档索引                 |
| [priv/docs/API.md](priv/docs/API.md)                                       | `ali` 模块完整 API       |
| [priv/docs/LLM.md](priv/docs/LLM.md)                                       | LLM 直连 API（`llmCli`） |
| [priv/docs/CONFIG.md](priv/docs/CONFIG.md)                                 | 配置项说明                |
| [priv/docs/ARCHITECTURE.md](priv/docs/ARCHITECTURE.md)                     | 模块架构与数据流             |
| [priv/docs/TOOLS.md](priv/docs/TOOLS.md)                                   | Agent 工具列表           |
| [priv/docs/AGENT_DEVELOPMENT_PLAN.md](priv/docs/AGENT_DEVELOPMENT_PLAN.md) | 设计与实现历程              |

## 许可证

MIT
