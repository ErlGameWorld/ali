# ali

## 项目蓝图

**ali** 是一个**嵌入目标 Erlang 节点**的智能开发助手：以 OTP 应用形式与业务系统同节点运行，理解项目源码与运行时状态，在 LLM 驱动下完成「问、搜、审、改、跑、查」全链路开发辅助。

### 我们要解决什么问题

大型 Erlang/OTP 项目（游戏服、电信、金融核心等）往往具备：

- 百万行源码、模块耦合深、调用链难追踪
- 运行时状态分散在进程、ETS、Mnesia、外部 DB 中
- 改一行代码需要同时理解编译期结构与运行期行为

传统 IDE 或通用 AI 助手难以**在同一上下文里**同时访问：源码索引、调用图、BEAM 抽象、节点内进程/表数据、以及业务 DB。ali 的目标是把这些都收敛到**一个可编排、可审计、可策略管控**的 Agent 体系中。

### 核心能力目标

| 能力域 | 目标描述 | 典型场景 |
|--------|----------|----------|
| **代码问答** | 基于项目上下文 + LLM，回答「这段逻辑做什么 / 为什么这样写 / 影响面在哪」 | 新人 onboarding、跨模块排障 |
| **代码搜索** | 符号搜索、全文搜索（ripgrep）、语义检索、调用图上下游 | 定位 handler、找相似实现 |
| **代码审核** | Critic 循环 + 结构化审查清单，输出可执行修改建议 | PR review、上线前风险扫描 |
| **代码修改** | 受策略保护的 patch：校验 → 干跑 → 备份 → 应用 → 回滚 | 自动修 bug、批量重构 |
| **代码运行** | 受策略约束的 MFA 执行（默认黑名单拦危险原语；生产可切白名单）、模拟场景、编译验证 | 验证修复、探测 API 行为 |
| **运行时洞察** | 进程、ETS、supervisor 树、节点快照 | 内存泄漏、监督树异常 |
| **数据访问** | 嵌入式 SQLite（ali 会话/记忆）；**业务/玩家数据经 runMfa 查改**；长期记忆召回 | 查配置/会话；GM 改玩家 |
| **接口探查** | 通过模块导出、BEAM 抽象、调用图获取数据结构内部形态 | 理解 record/map 在运行时的实际用法 |

### 设计原则

1. **同节点嵌入**：作为 OTP 应用启动，直接复用目标节点的 `code`、进程、ETS，无需额外 sidecar 进程组（数据面 Rust core 以 Port 子进程运行，仍属同一部署单元）。
2. **编排与数据面分离**：Erlang 负责 Agent 循环、会话、策略、工具路由；Rust `aliCore` 负责 Tree-sitter 解析、BM25/向量索引、调用图、重型检索。
3. **工具化 + 可组合**：所有能力通过统一工具注册表暴露，供 LLM、MCP、HTTP、Erlang API 调用。
4. **安全默认**：读/写/执行分级策略；写文件与写活数据需确认；`runMfa` 默认黑名单拦截危险原语，生产嵌入建议 `runMfaPolicy=whitelist`；外部网关可配置 Token 与限流。
5. **LLM 可替换**：通过 `config/aliCfg.cfg` 接入 DeepSeek、OpenAI 兼容、Anthropic 等主流模型；Embedding / Rerank / Qdrant 可选增强检索。

### 对外形态

- **Erlang API**：`ali:ask/2`、`ali:agent/2`、`ali:call_tool/2` — 节点内直接调用
- **CLI REPL**：`alChat` — 交互式问答与命令
- **HTTP + WebUI**：网关端口（默认 8787）— REST、WebSocket、静态控制台
- **MCP**：stdio 协议 — 供 Cursor 等 IDE 以工具形式接入

### 能力边界（非目标）

- 不替代 Dialyzer / CT / PropEr 等正式验证工具，而是辅助定位问题并生成补丁草案
- 不默认对生产节点开放无限制写操作与任意 MFA 执行
- 不绑定单一云厂商 LLM；模型与向量库均可配置或降级为本地 BM25

---

面向 Erlang 节点的运行时感知 AI 开发助手。

Erlang Orchestrator 通过 **Erlang Port** 管理 Rust Core（`aliCore --port`），并对外提供 **MCP** 与 **HTTP Gateway** 统一工具协议。

## 一键启动

```powershell
.\priv\scripts\start.ps1
```

```bash
chmod +x priv/scripts/start.sh priv/scripts/mcp.sh priv/scripts/copy_core.sh
./priv/scripts/start.sh
```

脚本会进入 `rebar3 shell`；`rebar3 compile` 的 pre_hook 会自动 `cargo build --release` 并拷贝 `aliCore` 到 `priv/`（自动拉起 core + HTTP 网关）。

## IDE / MCP 集成

```powershell
.\priv\scripts\mcp.ps1
```

Cursor 配置见 `.cursor/mcp.json` 与 [priv/docs/mcp.md](priv/docs/mcp.md)。

```bash
# Web UI / Gateway 默认端口 8787（web.port / gateway.port）
# 工具名可用 camelCase 或 snake_case
curl -X POST http://127.0.0.1:8787/tool \
  -H "content-type: application/json" \
  -d '{"tool":"searchCode","args":{"query":"gen_server","limit":5}}'
```

## 当前能力

- **代码索引与搜索**：Tantivy BM25 + 可选 embedding/Qdrant 混合检索 + rerank
- **Rust Core**：Tree-sitter、call graph（petgraph 图遍历）、嵌入式 SQLite、语义记忆向量（Qdrant 独立 collection）
- **运行时探针**：进程、ETS、supervisor 树、受策略约束的 MFA（默认黑名单）
- **Agent**：plan → tools → critic review_loop → 语义记忆召回
- **Patch**：validate / dry_run / apply / batch / rollback
- **活数据写闭环**：runMfa write + verifyRead（审批前快照 → 批准 → 写 → 回读）
- **对外协议**：MCP stdio（tools + resources + prompts）、`POST /tool` HTTP 网关、Erlang `ali:call_tool/2`
- **工具注册**：`alToolCatalog:allTools/0`（含搜索/补丁/计划/测试/checkpoint 等；写与高风险工具受策略约束）
- **流式 Agent**：WS / SSE / `ali:askStream` 共用 session worker + 工具循环，事件含 token / toolStarted / toolFinished / approvalRequired
- **Checkpoint**：`ali:listCheckpoints/0`、`ali:resumeCheckpoint/1` 与 `/api/checkpoints*`

## 配置

所有选项集中在 **`config/aliCfg.cfg`**（Erlang term 键值列表）。启动时 `alConfig:load/0` 经 `alKvsToBeam` 编译为 `alCfg` 模块，各模块通过 `alConfig:get/1` 或 `alCfg:getV/1` 读取。

**密钥（必读）**：

```powershell
# Windows PowerShell — 启动前设置，勿把真实 key 写进仓库
$env:ALI_LLM_API_KEY = "sk-..."
```

- `config/aliCfg.cfg` 中 `llm.apiKey => "${ENV:ALI_LLM_API_KEY}"`，由 `alConfig` 展开占位符。
- 可参考 `config/aliCfg.cfg.example` 复制本地配置。
- Web 默认只监听 `127.0.0.1`；对外暴露时改 `web.bindAddress` 并配置 `apiToken` + `allowOrigin`。

```erlang
%% config/aliCfg.cfg 示例片段
{core, #{enabled => true, mode => port, timeout => 30000}},
{web, #{enabled => true, port => 8787, bindAddress => "127.0.0.1"}},
{llm, #{apiKey => "${ENV:ALI_LLM_API_KEY}", model => "deepseek-v4-flash", provider => deepseek}}
```

指标抓取：`GET /api/metrics`（JSON）与 `GET /api/metrics/prometheus`（Prometheus text；需鉴权/loopback，与其它 `/api/*` 相同）。

LLM / Embedding / Qdrant / Rerank 等均在 cfg 中配置；`config/sys.config` 仅为 rebar shell/release 占位。

### 本地语义检索（Embedding / Rerank）

**DeepSeek 等对话模型不提供向量与重排接口**——只配 `llm.chain` 时，代码搜索仍可用 **BM25（内置、零配置）**，但**没有语义向量**，也**没有 Rerank 精排**。若希望接近 Cursor 的「关键词 + 向量 + 重排」体验，需另起 **llama.cpp `llama-server`**（或其它 OpenAI 兼容 `/v1/embeddings`、`/v1/rerank` 服务）。

| 层级 | 作用 | 默认 | 本地部署 |
|------|------|------|----------|
| BM25 / 关键词 | 字面匹配 | ✅ aliCore 内置 | 无需额外服务 |
| Embedding | 语义相似 | ❌ 需 `{embedding, enabled => true}` | llama-server + GGUF |
| Reranker | 对候选精排 | ❌ 需 `{rerank, enabled => true}` | 同上，专用 reranker GGUF |

**推荐 GGUF（中文 / 多语）：**

| 用途 | 模型 |
|------|------|
| 向量 | [Qwen3-Embedding-4B-GGUF](https://huggingface.co/Qwen/Qwen3-Embedding-4B-GGUF) 或 [Qwen3-Embedding-8B-GGUF](https://huggingface.co/Qwen/Qwen3-Embedding-8B-GGUF) |
| 重排 | [Qwen3-Reranker-4B-GGUF（llama.cpp 可用转换版）](https://huggingface.co/Voodisss/Qwen3-Reranker-4B-GGUF-llama_cpp) |
| 低配 CPU | bge-m3 + bge-reranker-v2-m3（见完整文档） |

**快速步骤：**

1. 从 [llama.cpp Releases](https://github.com/ggml-org/llama.cpp/releases) 取 `llama-server`（Win/Linux 各一份；**不是**一个 exe 跨平台）。
2. 下载上表 GGUF；Reranker **勿用**未含 `cls.output.weight` 的社区转换包（分数会变成 ~0）。
3. 启动 embedding + rerank（单端口 Router 示例）：

   ```bash
   llama-server --host 127.0.0.1 --port 8081 \
     --models-preset priv/examples/llama-models.ini.example --models-max 2
   ```

   聊天大模型（如本地 Ornith）建议 **单独端口 8080**，与 embed/rerank 分开，省内存。

4. `config/aliCfg.cfg` 中开启（`apiKey` 本地可填 `<<"local">>`，**不要**对 DeepSeek 用 `inherit` 指望自动生效）：

   ```erlang
   {embedding, #{enabled => true, apiKey => <<"local">>,
     baseUrl => "http://127.0.0.1:8081/v1/embeddings", model => "Qwen3-Embedding-4B"}},
   {rerank, #{enabled => true, apiKey => <<"local">>,
     baseUrl => "http://127.0.0.1:8081/v1/rerank", model => "Qwen3-Reranker-4B"}}
   ```

5. 重启 ali 后 **重建索引** `ali:index(".")`（或等 `indexBackground`），向量化才会写入 `.ali/index/`。

完整说明（models.ini、三端口方案、资源估算、故障排查）：**[priv/docs/local-semantic-search.md](priv/docs/local-semantic-search.md)**。

## 嵌入其它 Erlang 项目

典型流程（**不**跑 release 的 `bin/ali.cmd`，而是把 beams 挂进宿主节点）：

```bash
rebar3 as prod release
# 把 _build/prod/rel/ali 整目录拷到例如 D:/tools/ali_rel
```

宿主项目：

```erlang
%% 1) 加载 release 里所有 lib/*/ebin
{ok, _} = ali:addPaths("D:/tools/ali_rel"),
%% 或一步完成：
%% ali:start(#{release => "D:/tools/ali_rel", cfg => "config/aliCfg.cfg"}).

%% 2) 从 aliCfg.cfg.example 复制并改好宿主侧配置（projectRoot / codeRoots / llm）
%%    放到宿主 cwd 的 config/aliCfg.cfg，或传 cfg 选项 / 设 ALI_CFG

%% 3) 启动（会 ensure_all_started，并按 indexBackground 后台建索引）
{ok, _} = ali:start().
%% 若要等索引完成：
%% {ok, _} = ali:start(#{waitIndex => true, waitMs => 180000}).

%% 4) 查看就绪状态
ali:ready().
%% #{ready => true, coreAvailable => true, indexReady => true, ...}

%% 5) 使用
ali:ask(<<"这个模块做什么？"/utf8>>).

%% 6) 停止（只停 ali，不停宿主节点）
ok = ali:stop().
```

相关 API：`ali:addPaths/1`、`ali:start/0,1`、`ali:stop/0`、`ali:prepare/0,1`、`ali:ready/0`、`ali:indexRoots/0`。

## 编译与测试

```bash
rebar3 compile          # pre_hook: build_core（cargo release + copy）
rebar3 eunit
rebar3 ct --suite=test/ali_SUITE
rebar3 dialyzer         # 分析 ali（部分 hex 依赖 exclude）
rebar3 release              # 可复制到同机其它目录（需本机已装 OTP）
rebar3 as prod release        # 自包含（含 ERTS），可整目录拷到任意机器
powershell -File priv/scripts/package_release.ps1   # 打包到 _rel/ali

# Rust 微基准（本地，可选）
cargo bench --bench core_micro --manifest-path c_src/aliCore/Cargo.toml
```

无 LLM 的系统检查（`rebar3 shell` 内）：

```erlang
alVerify:run(alVerify:nonLlmCategories()).
```

或脚本：`priv/scripts/verify_non_llm.ps1` / `verify_non_llm.sh`。

单独只编 Rust（可选）：

```bash
cargo build --release --manifest-path c_src/aliCore/Cargo.toml
.\priv\scripts\copy_core.ps1   # 或 sh priv/scripts/copy_core.sh
```

## 使用示例

```erlang
ali:index("src").


ali:search("gen_server", 5).
ali:agent("解释 ali_sup 的监督策略").
ali:callTool(remember, #{sessionId => 1, kind => note, content => <<"test">>}).
ali:recallSemantic("监督策略").
ali:rebuildMemoryIndex().   %% SQLite → 向量缓存
ali:forget(42).             %% 删记忆行 + 清向量
```

## 架构

见 [priv/docs/architecture.md](priv/docs/architecture.md)。

从零学习、调试和改造本项目，请按 [项目学习与改造指南](priv/docs/project-learning-guide.md) 实操。
