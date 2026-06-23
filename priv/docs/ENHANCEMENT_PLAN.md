# ali 功能审核与完善优化开发计划书

> 编写日期：2026-06-19
> 审核对象：`ali` —— 运行在 Erlang/OTP 节点内的 AI 开发助手（OTP 应用）
> 文档目的：基于对现有代码的逐模块审核，盘点已实现能力、识别短板，给出一份可落地的「完善 / 优化 / 新增」功能开发计划，使项目从「可用」走向「强大、可靠、可商用」。

> **实施进度（2026-06-19，第一批，安全项暂缓）**：以下非安全优化已落地并通过全部 56 项 EUnit 测试：
> - ✅ P0-2 `alLoop` LLM 瞬时错误重试（429/5xx/超时/连接断开，指数退避 + jitter，配置 `llmMaxRetries`）
> - ✅ P0-3 文件遍历排除构建产物（`_build`/`.git`/`.al`/`node_modules`/`deps` 等 + 配置 `indexExclude`）
> - ✅ P0-4（部分）`patchFile` 多处匹配保护：`oldText` 须唯一匹配，否则 `ambiguousMatch`，支持 `replaceAll`
> - ✅ B1（P1-4 部分）模型计价表 + `tokenStats` 估算费用 `estimatedCostUsd`（按模型）
> - ✅ B2（P1-6 部分）系统提示词中文优先 + 可配置 `systemPromptExtra`
> - ✅ B3（P1-2 部分）`estimateTokens` CJK 感知，提升预算裁剪与费用估算精度
> - ✅ 附带修复：Windows 路径分隔符越界误判（嵌套路径 `writeFile`/`patchFile` 此前在 Windows 不可用）
>
> 安全项：P0-5 Web 加固已完成（第八批）；P0-1 按产品决策**保留黑名单**（收尾批扩充内置列表）。

> **实施进度（2026-06-20，第八批）**：完成 P0-5 Web 安全加固，全部通过 107 项 EUnit 测试，并经真实 HTTP 端到端验证（401/200/204 预检/CORS/安全头）：
> - ✅ 认证：修复令牌比较 bug（旧 `<<"",_>>` 子句吞掉所有 token），改用常数时间比较；新增「写类接口（POST/PUT/DELETE 及 `/ws` 升级）鉴权门控」——配置 token 时全部受保护端点需 token，未配置 token 时读放行、写仅限本地回环（`webAllowRemoteWrites` 可放开）。
> - ✅ CORS 白名单：`webAllowOrigin`（`*`/单来源/列表，默认不放行跨源），`OPTIONS` 预检返回 204。
> - ✅ 速率限制：`alWebSec` 基于来源 IP 的固定窗口计数（`webRateLimit`/`webRateWindowMs`，ETS 由 `alWebSrv` 持有），超限 429。
> - ✅ 安全头与审计：所有响应附带 `nosniff`/`DENY`/`no-referrer`；写请求记录来源 IP。
> - 附带修复：配置 `{webApiToken, ""}`（空串=空列表）经归一化会变成 `#{}`，旧逻辑误判为「已启用且不可匹配的令牌」导致全部 401；`configured_token/0` 现把空 map/列表/串统一视为「未配置」。
> - 新增模块 `alWebSec`（CORS/限速/常数时间比较/写与回环判定，纯函数为主，便于测试）；配置 `webAllowOrigin`/`webRateLimit`/`webRateWindowMs`/`webAllowRemoteWrites`。

> **实施进度（2026-06-19，第二批）**：新增以下能力，全部通过 71 项 EUnit 测试：
> - ✅ P1-1 历史压缩：`alContext:compactHistory/1`，旧消息压缩为中文摘要 system 消息（确定性、无额外 LLM 调用），配置 `historyCompaction`
> - ✅ P1-5 可观测性：`alMetrics`（ask 次数/成败/平均耗时/工具调用数）+ `alAudit:query/1`、`alAudit:stats/0`；facade `ali:metrics/0`、`ali:auditQuery/1`、`ali:auditStats/0`
> - ✅ P2-2 国产模型预设：qwen / kimi / zhipu / ernie / doubao / openrouter（重构 provider 判断为「非 anthropic 即 OpenAI 兼容」，新增即用）
> - ✅ P2-4 Git 只读工具：`alToolGit`（gitStatus/gitDiff/gitLog/gitBranch）
> - ✅ P2-5 运行时诊断增强：`topProcesses`（memory/reductions/message_queue_len 热点）、`schedulerInfo`
> - ✅ P3-2 插件化工具注册：`ali:registerTool/1`、`ali:unregisterTool/1`（运行时扩展，策略级别可指定）
> - ✅ P3-4 CI：新增 GitHub Actions（compile + eunit + xref + dialyzer，OTP 27/28 矩阵）
> - 备注：P2-1 Anthropic 原生 tool calling 经核查**已实现**（`buildAnthropicRequestBody` 等），审核结论修正。
>
> **实施进度（2026-06-19，第三批）**：补齐两大核心智能项，全部通过 79 项 EUnit 测试：
> - ✅ P1-2 语义检索 / 代码 RAG：新增 `alRag`，基于函数级索引切分代码块，标识符感知分词（camelCase/snake_case）+ TF-IDF 排序（确定性、离线、零成本），函数/模块名加权；工具 `searchCode`，门面 `ali:searchCode/1,2`、`ali:ragIndex/0`
> - ✅ P1-3 任务规划编排（Plan→Execute→Verify）：新增 `alPlan`，会话级结构化任务清单（步骤+状态+进度摘要）；工具 `planSet`/`planUpdate`/`planGet`，系统提示词引导模型对复杂任务先规划再执行；门面 `ali:plan/0,1`
> - 附带改进：`alTools` 执行时向工具 Config 注入 `sessionId`，使会话级工具（规划）正确作用域化
>
> **实施进度（2026-06-19，第四批）**：完成 P3-3 Web UI 升级，全部通过 81 项 EUnit 测试，并经真实 WebSocket 握手 + 帧收发端到端验证：
> - ✅ WebSocket：`alWebHer` 新增 `/ws` 升级端点与 `handleWs/3` 回调（基于 eWSrv 原生 WS）。控制面命令（status/tools/sessions/audit/metrics/tasks/plan/mode/approve/pending/previewPatch）走 WS 请求-响应；问答经 WS 主动推送 `token`/`progress`/`done`（捕获连接 socket，转发进程实时推帧）。
> - ✅ 可视化 diff：新增 `POST /api/preview/patch` 与 `GET /api/pending/:taskId`（暴露挂起任务预览含 diff），前端审批栏按 `+/-/@@` 着色展示统一 diff。
> - ✅ 任务/规划/指标面板：侧栏标签页实时展示后台任务、`alPlan` 规划进度、`alMetrics` 运行指标。
> - ✅ 前端：WS 优先、自动重连，WS 不可用时回退既有 SSE 流式 + REST（零破坏）；连接状态指示灯。
> - 后端新增：`alServer:pendingTask/1,pendingList/0`、`ali:pendingTask/1`。
>
> **实施进度（2026-06-19，第五批）**：完成 P3-1 MCP 客户端，全部通过 88 项 EUnit 测试，并经真实子进程（mock stdio server）握手 + tools/list + tools/call 端到端验证：
> - ✅ P3-1 MCP（Model Context Protocol）：新增 `alMcp`（gen_server，纳入监督树）。stdio + JSON-RPC 2.0 传输，`initialize` 握手后 `tools/list` 自动发现工具并注册进 `alTools`，模型调用经 `tools/call` 转发；工具名稳定化、参数键名按 schema 还原、权限沿用策略引擎、Server 退出自动注销。
> - 门面：`ali:mcpConnect/1`、`mcpConnectAll/0`、`mcpDisconnect/1`、`mcpServers/0`、`mcpTools/0`、`mcpCall/3`；配置 `mcpServers`。
> - 附带改进：`alTools:doExecute` 向工具 Config 注入 `toolName`，使共享分发模块的工具（MCP）能识别目标远程工具。
>
> **实施进度（2026-06-19，第六批）**：完成 P2-3 Elixir / 多 BEAM 语言支持，全部通过 92 项 EUnit 测试，并经真实 `.ex` 文件索引端到端验证（`Demo.Calc` 正确解析，`defp` 不计入导出，`language => elixir`）：
> - ✅ P2-3 Elixir 索引：新增 `alElixir` 词法解析器，提取 `defmodule`/`def`/`defp`/`defmacro` 函数（名称+arity+可见性+行号范围）、`@spec`、`use`/`@behaviour`、`import`/`alias`/`require` 依赖，产出与 Erlang 条目**同构**的 map，复用同一套索引、检索（`alRag`）、调用关系与图分析。
> - ✅ 扫描扩展：`alCodeIndexer` 现遍历 `src/`、`lib/`、`test/` 及根目录下的 `.erl`/`.ex`/`.exs`，按扩展名分派解析；条目新增 `language` 字段（erlang|elixir）。
> - ✅ 格式化：`formatCode` 对 `.ex`/`.exs` 调用 `mix format`（缺失时返回 `mixUnavailable`），`.erl` 仍走 `erl_tidy`。
>
> **实施进度（2026-06-19，第七批）**：完成 MCP 可选增强（Streamable HTTP/SSE 传输 + resources/prompts），全部通过 97 项 EUnit 测试，并经真实 gen_tcp mock HTTP/SSE Server 端到端验证（握手 + 能力发现 + tools/call + resources/read + prompts/get + 通用工具注册）：
> - ✅ Streamable HTTP/SSE 传输：`alMcp` 重构出传输抽象（stdio | http）。HTTP 经 `hackney` POST，响应支持 `application/json` 与 `text/event-stream`（SSE 解析），自动维护 `Mcp-Session-Id` 会话头；POST 失败/4xx 回收对应挂起请求。
> - ✅ resources/prompts：`initialize` 后按 Server `capabilities` 自动发现 `tools/list`、`resources/list`、`prompts/list`；新增 `resources/read`、`prompts/get`。当任一 Server 提供该能力时自动注册通用工具 `mcpListResources`/`mcpReadResource`/`mcpListPrompts`/`mcpGetPrompt`（断开后自动注销）。
> - 门面：`ali:mcpResources/0`、`mcpReadResource/2`、`mcpPrompts/0`、`mcpGetPrompt/3`、`mcpListResources/1`、`mcpListPrompts/1`；`mcpServers/0` 增加 transport/能力/资源/提示统计；配置 `mcpServers` 支持 `transport => http, url, headers`。
>
> **实施进度（2026-06-20，收尾批）**：按计划书全面落地后的收尾与再审核，107 项 EUnit 全绿：
> - ✅ `callFunction` **保留黑名单策略**（不做白名单）：扩充内置 `defaultBlacklist/0`（halt/stop/delete/purge/putenv/disconnect_node 等 20+ 高危 MFA），配置 `execBlacklist` 可追加。
> - ✅ 配置修复：`webApiToken` 空值在 `llmCliConfig` 加载时归一化为 `<<>>`，避免空串变 `#{}` 导致 Web 误锁。
> - 📋 计划书全文已同步为**最终审核结论**（见第 8 节）；具名里程碑除可选增强外均已闭合。
>
> **仍属可选增强（非阻塞）**：MCP 对外 Server / subscribe、Elixir 完整 AST、unified diff 补丁引擎、`.gitignore` 解析、`gitCommit` 写工具、telemetry 事件、核心循环 mock 测试、Hex 发布与 CHANGELOG。

> **实施进度（2026-06-20，第九批）**：完成 P1-2 向量语义检索（RAG hybrid search），全部通过 127 项 EUnit 测试：
> - ✅ P1-2 向量 embedding：`llmCli` 新增 `embeddings/2,3`（OpenAI 兼容 `/embeddings` 端点，批量处理 + ETS 缓存 + 按 provider 默认模型）；导出 `defaultEmbeddingModel/0,1`、`parseEmbeddingsResponse/2`。
> - ✅ 新增 `alEmbedding` 模块：ETS 向量存储（`?VECTORS`）+ 嵌入缓存（`?CACHE`）+ 余弦相似度（维度容错、零向量保护）+ 批量嵌入（缓存命中跳过、结果顺序对齐）+ 可注入 embedder（`setEmbedder/1`，便于测试与自定义后端）+ `isAvailable/0`（无 API key 或 anthropic 时返回 false）。
> - ✅ `alRag` 混合检索：`searchHybrid/3` 融合 TF-IDF（精确关键词）与向量余弦（语义召回），权重 0.4/0.6 可配；`mode/0` 按 `ragMode` 配置（auto/tfidf/hybrid）选择，auto 时 embedding 可用则 hybrid 否则 tfidf；`search/3` 在 hybrid 空结果时自动回退 tfidf；`index/1` 在 hybrid 模式下批量构建 chunk 向量；`stats/0` 含 mode 与 embedding 统计；`clear/0` 同步清空向量库。
> - ✅ 工具与门面：注册 `semanticSearch` 工具（`alToolAnalyze`，read 级，返回 mode 标识便于前端展示降级）；`ali:semanticSearch/1,2`、`ali:ragStats/0`、`ali:ragMode/0`。
> - ✅ 配置：`ragMode`（auto|tfidf|hybrid）、`embeddingModel`（覆盖 provider 默认）；`config.example.cfg` 补充示例与注释。
> - ✅ 测试：新增 9 项 EUnit（cosine 边界、store/search 召回、缓存命中、批量顺序、hybrid 端到端、mode 切换、默认模型、响应解析、semanticSearch 工具），全部使用 mock embedder，无真实 API 依赖。

---

## 1. 总体评价

`ali` 已经是一个**完成度相当高**的 AI 编程 Agent 框架，远超一般「LLM 客户端」范畴。其核心闭环（多轮对话 → 工具调用 → 代码修改 → 热加载 → 测试）已经打通，并且具备 OTP 工程化骨架、权限分级、审计、会话持久化、Web UI 与 CLI。

综合成熟度评估（满分 5，**2026-06-20 再审核**）：

| 维度 | 评分 | 说明 |
|------|------|------|
| 架构设计（OTP/监督树/Facade） | ★★★★★ | 分层清晰，`ali` 单一入口，MCP/索引/Web 均纳入监督树 |
| Agent 推理循环 | ★★★★☆ | 原生 tool_calls + 文本双模式，流式/异步，LLM 重试与步数熔断 |
| 工具丰富度 | ★★★★★ | 50+ 工具（含 MCP 动态注册），覆盖文件/分析/RAG/规划/Git/运行时/编辑/测试 |
| 安全与权限 | ★★★★☆ | 4 级策略 + 写确认 + 扩充黑名单 + Web 加固；`callFunction` 仍为黑名单模式（产品决策） |
| 可观测性 | ★★★★☆ | 审计查询/统计、`alMetrics`、token 费用估算、写请求 IP 日志 |
| 测试覆盖 | ★★★★☆ | 107 项 EUnit（工具/策略/RAG/MCP/Web 安全等）；核心 HTTP mock 与 alLoop 集成测试仍偏少 |
| 上下文工程 | ★★★★☆ | 历史压缩、词法 RAG、任务规划、中文提示词；向量语义召回待做 |
| 多 Provider 兼容 | ★★★★☆ | OpenAI/Anthropic/DeepSeek + 国产预设；差异边界需随厂商 API 演进维护 |
| 生态扩展性 | ★★★★☆ | MCP 双传输 + resources/prompts、插件化工具、Elixir 索引、WebSocket UI |

**一句话结论**：计划书中的具名里程碑（P0~P3）已基本闭合，项目已从「可用」进入「强大、可扩展、可运维」阶段；剩余为可选增强与工程化 polish。

---

## 2. 现状功能盘点（已实现）

### 2.1 LLM 客户端层（`core/`）
- `llmCli`：同步/流式/重试/批量/异步聊天，token 估算与统计，多 provider（`openai` / `deepseek` / `anthropic` / `custom`）。
- 原生 function calling（`chatCompletion/3`）+ 流式工具增量合并（`mergeStreamToolCallDelta`、`finalizeStreamToolCalls`）。
- `llmCliConfig`：`config.cfg` term 配置加载、provider 预设表、Agent 配置落地到应用环境。
- `llmJson`：JSON 编解码与 `sanitize`。

### 2.2 Agent 运行时（`agent/`）
- `alServer`：多会话 gen_server，ask/askStream/askAsync/run/approve，模式（ask/edit/exec）、工作上下文（modules/files/processes）。异步 worker 执行，不阻塞邮箱。
- `alLoop`：推理主循环，maxSteps 熔断 + 步数用尽兜底汇总（`finalizeOnMaxSteps` / `build_partial_summary`）。
- `alTools`：工具注册表 + OpenAI schema 导出 + 策略校验 + 审计 + 写操作预览/确认。
- `alPolicy`：4 级权限（read/executeSafe/executeRisky/write）× 模式矩阵 + 敏感信息脱敏。
- `alContext`：系统提示词、项目摘要（120s 缓存）、历史裁剪（条数 + token 双策略）、孤立 tool 消息清理。
- `alSession` / `alBackup` / `alAudit` / `alProgress` / `alTask`：会话持久化、编辑备份、审计 jsonl、进度快照、后台任务与取消。

### 2.3 工具实现（`tools/`）
- 项目：`readFile` / `listFiles` / `searchText` / `projectIndex`。
- 分析：`codeIndex` / `searchCodeIndex` / `getFunctionSource` / `analyzeCalls` / `findCallers` / `getBeamAbstract` / `analyzeBehaviours` / `moduleDependencies` / `dependencyGraph`（Mermaid）/ `analyzeCallGraph` / `codeQuality`。
- 运行时/OTP：`getAppInfo` / `getSupTree` / `etopSummary` / `loadedApplications` / `loadedModules` / `moduleExports` / `registeredProcesses` / `processList` / `processInfo` / `nodeInfo` / `agentConfig` / `runtimeSummary` / `remoteNodeInfo`。
- 执行：`callFunction`（黑名单拦截）。
- 编辑：`writeFile` / `patchFile` / `compileLoad` / `rollbackFile` / `formatCode`（erl_tidy）/ `listBackups`，均带 diff 预览与确认。
- 测试：`runEunit` / `generateEunit` / `listTestModules` / `runCommonTest` / `generateCommonTest`。

### 2.4 分析引擎（`analysis/`）
- `alCodeIndexer`：DETS 持久化代码索引（模块/导出/behaviour/函数），同步与异步刷新。
- `alAst`：基于 AST 的调用关系分析（带正则兜底）。

### 2.5 接入层
- `web/`：`alWebSrv` + `alWebHer`，REST + SSE 流式问答 + EventSource，Bearer/Token 认证，静态资源服务；前端 `priv/web`（index.html + app.js + style.css）。
- `ali_cli`：escript 命令行（ask/chat/approve/status/tools/tasks/config/refresh/sessions/web/health）。

---

## 3. 发现的问题与短板

> 按严重程度与影响面排序。括号内为相关模块。

### 3.1 安全（最高优先级）
1. **`callFunction` 黑名单模式**（`alToolEval`、`alPolicy`）— **已扩充内置高危列表**（halt/stop/delete 等），仍可通过 `execBlacklist` 扩展；未采用白名单（产品决策）。`exec` 模式下仍需谨慎。
2. **`compileLoad` 热加载任意代码**（`alToolEdit`）：需确认 + 备份；无编译沙箱（已知局限）。
3. **审计日志无防篡改**（`alAudit`）：jsonl 明文（已知局限）。
4. ~~**Web CORS 全开**~~ → ✅ 已改为 `webAllowOrigin` 白名单 + token/限速/安全头（第八批）。

### 3.2 可靠性 / 健壮性
5. ~~**`alLoop` 调用 LLM 不带重试**~~ → ✅ P0-2 已接入 `chatWithRetry`。
6. ~~**`listFiles` 遍历构建目录**~~ → ✅ P0-3 递归阶段排除 `_build`/`.git` 等。
7. **`patchFile` 全局替换风险** → 部分缓解（唯一匹配 + `replaceAll`）；完整 unified diff 引擎仍为可选增强。
8. ~~**历史超长只裁剪**~~ → ✅ P1-1 历史压缩（确定性摘要）。

### 3.3 智能化 / 上下文工程
9. ~~**语义检索**~~ → ✅ `alRag` 词法 TF-IDF + 向量 embedding 混合检索（hybrid）。
10. ~~**token 估算粗糙**~~ → ✅ CJK 感知估算 + 费用表。
11. ~~**无任务规划**~~ → ✅ `alPlan`（planSet/planUpdate/planGet）。
12. ~~**系统提示词英文**~~ → ✅ 中文优先 + `systemPromptExtra`。

### 3.4 Provider / 兼容性
13. **Anthropic tool calling** → 已实现（`buildAnthropicRequestBody` 等），需随 API 演进维护。
14. ~~**国产模型欠缺**~~ → ✅ qwen/kimi/zhipu/ernie/doubao/openrouter 预设。
15. ~~**仅 Erlang**~~ → ✅ Elixir `.ex/.exs` 索引 + `mix format`。

### 3.5 可观测性 / 运维
16. ~~**无指标**~~ → ✅ `alMetrics` + 审计 query/stats；telemetry 事件仍为可选。
17. ~~**无成本统计**~~ → ✅ `estimatedCostUsd`；会话级预算熔断为可选。
18. ~~**无 CI**~~ → ✅ GitHub Actions（compile/eunit/xref/dialyzer）。

### 3.6 测试
19. **核心循环集成测试偏少**：`alLoop`/`alServer` HTTP mock 路径可继续补充（非阻塞）。

### 3.7 扩展生态
20. ~~**无 MCP**~~ → ✅ `alMcp`（stdio + HTTP/SSE + resources/prompts）。
21. ~~**无插件注册**~~ → ✅ `ali:registerTool/1`。

---

## 4. 完善 / 优化 / 新增功能开发计划

> 优先级：**P0=安全/必修**，**P1=核心增强**，**P2=能力扩展**，**P3=生态/锦上添花**。
> 每项含：现状 → 目标 → 方案 → 验收。

### P0 —— 安全与可靠性加固（必须先做）

#### P0-1 `callFunction` 安全模型 — **按产品决策保留黑名单**（收尾批已扩充内置列表）
- 现状：黑名单模式；内置拦截 halt/stop/delete/purge/os:cmd/putenv 等 20+ 高危 MFA；`execBlacklist` 可追加。
- 未采用白名单/strict 模式（用户明确要求仅保留黑名单）。
- 验收：✅ EUnit 覆盖 `os:cmd`、`erlang:halt`、`file:delete`、`init:stop` 等被拒。

#### P0-2 `alLoop` 接入 LLM 重试与降级
- 方案：循环内 LLM 调用改用 `chatWithRetry`（指数退避，区分可重试错误：超时/5xx/429）；保留最大重试次数配置 `llmMaxRetries`。
- 验收：模拟瞬时网络错误时，整轮不中断、最终成功或给出明确失败原因。

#### P0-3 文件遍历排除规则（性能 + 安全）
- 方案：`alToolProject:collectFiles` 在递归阶段即跳过 `_build`、`.git`、`.rebar3`、`node_modules`、`.al` 等；复用/扩展配置 `indexExclude`，并支持 `.gitignore` 解析。
- 验收：大项目 `listFiles`/`searchText` 不再遍历构建产物；新增基准测试或断言不含 `_build` 路径。

#### P0-4 精确补丁引擎
- 方案：新增 `alToolEdit:patchFileExact`，支持「唯一匹配校验（出现多次则报错并提示加上下文）」、行号锚点、多 hunk、unified diff 应用；保留旧 `patchFile` 为兼容入口。
- 验收：多处匹配时返回 `{error, ambiguousMatch}`；unified diff 正确套用。

#### P0-5 Web 安全加固 ✅（已完成，见第八批）
- 方案：CORS 白名单化（可配置 `webAllowOrigin`）；为写类接口（approve/format/mode/index refresh）强制 token；增加简单速率限制；审计记录请求来源 IP。
- 验收：未授权写请求返回 401；CORS 仅放行白名单。

### P1 —— 核心能力增强

#### P1-1 历史压缩 / 滚动摘要（Context Compaction）
- 方案：当历史超过阈值时，调用 LLM 将早期消息压缩为「会话摘要」system 片段，替代直接丢弃；`alContext` 增加 `compactHistory/2`。
- 验收：长会话下关键事实（已读文件、已改内容、决策）不丢失。

#### P1-2 语义检索 / 代码 RAG ✅（已完成，见第九批）
- 方案：新增 `alEmbedding`（调用 embedding API）+ 向量存储（先用 ETS/DETS + 余弦相似度，量大后接 sqlite-vss/外部库）；新增工具 `semanticSearch`，与 `searchCodeIndex` 互补；索引时对函数/模块切块向量化。
- 验收：✅ 自然语言查询能召回相关函数；hybrid 模式融合 TF-IDF + 向量；无 API key 时自动降级 tfidf。

#### P1-3 任务规划编排（Plan → Execute → Verify）
- 方案：新增 `alPlanner`，对复杂请求先产出结构化计划（步骤/涉及文件/验收），逐步执行并在每步后自检（编译/测试）；失败自动回滚（已具备 `rollbackFile`）。新增 `agent mode: plan`。
- 验收：「给 X 模块加一个函数并补测试」能自动完成 计划→改码→编译→跑测试→报告。

#### P1-4 成本与配额治理
- 方案：`llmCli` token 统计增加按模型计价表→费用估算；`alServer` 增加每会话/全局 token 与费用预算，超限熔断；`status` 暴露成本。
- 验收：超预算时拒绝继续并提示；`status` 显示累计费用。

#### P1-5 可观测性（telemetry + 结构化日志）
- 方案：引入 `telemetry` 事件（llm.request、tool.exec、loop.step、ask.complete），耗时/成败/步数；可选 logger handler 输出结构化 JSON 日志；审计日志增加查询 API（按时间/工具/会话过滤）。
- 验收：可统计单次 ask 的步数、各工具耗时、失败率。

#### P1-6 提示词模板化 + 中文优先
- 方案：`alContext` 系统提示词抽象为可配置模板（`promptTemplate`），按任务类型（qa/edit/debug/plan）切换；默认遵循用户语言（中文优先）；面向用户的错误消息统一中文。
- 验收：可通过配置切换提示词；中文交互体验一致。

#### P1-7 核心循环与服务层测试补全
- 方案：用 meck/mock 隔离 `llmCli` HTTP，覆盖 `alLoop`（tool_calls 编排、maxSteps 兜底、流式合并）、`alServer`（ask/approve/会话更新）、`alWebHer`（路由/认证）。
- 验收：`rebar3 eunit` 覆盖率显著提升，核心路径有用例。

### P2 —— 能力扩展

#### P2-1 Anthropic 原生 tool calling 适配
- 方案：`llmCli` 针对 `anthropic` 实现独立的 tools/tool_use/tool_result 报文构建与解析；`alLoop` provider 分支适配。
- 验收：以 Claude 模型跑通完整工具调用闭环。

#### P2-2 国产模型预设与适配
- 方案：`llmCliConfig:providerTable` 增加 通义千问 / 文心 / Kimi / 智谱GLM / 豆包 等预设（base_url + 默认模型 + 兼容性标记）；处理非标准差异。
- 验收：填入对应 key 即可直接使用。

#### P2-3 Elixir / 多 BEAM 语言支持
- 方案：索引与分析扩展 `.ex/.exs`（基于 Code/分词或外部解析）；`formatCode` 支持 `mix format`；区分语言走不同分析引擎。
- 验收：Elixir 项目可问答与基础分析。

#### P2-4 Git 集成工具
- 方案：新增受控 git 工具（`gitStatus` / `gitDiff` / `gitLog` / `gitBlame`，只读为主；`gitCommit` 走 write 确认），便于「按改动审查/生成提交信息」。
- 验收：可让 Agent 总结当前 diff 并生成提交信息（需确认才提交）。

#### P2-5 诊断增强（崩溃/性能）
- 方案：新增 `crashDump` 摘要、`msgQueueHotspots`（消息队列堆积进程）、`reductionsTop`、`scheduler/利用率` 工具；为线上故障定位赋能。
- 验收：能一键给出「哪些进程在堆积/吃 CPU」。

### P3 —— 生态与体验

#### P3-1 MCP（Model Context Protocol）支持 ✅ 已完成（第五批）
- 方案：实现 MCP client，将外部 MCP server 暴露的工具/资源动态注册进 `alTools`；并可选实现 MCP server，把 `ali` 的工具开放给其他客户端（如 Cursor/Claude Desktop）。
- 实现：`alMcp`（gen_server）stdio + JSON-RPC 2.0 client；`initialize`→`tools/list` 自动发现注册→`tools/call` 转发；门面 `ali:mcp*`，配置 `mcpServers`。经 mock server 端到端验证。
- 验收：✅ 能挂载外部 MCP 工具并被 Agent 调用（端到端测试通过）。
- 后续可选：Streamable HTTP/SSE 传输、resources/prompts 能力、对外暴露 ali 自身工具为 MCP server。

#### P3-2 运行时插件化工具注册
- 方案：`alTools` 增加 `registerTool/1`（运行时注入工具定义 + 权限级别），无需改源码扩展；提供 behaviour `al_tool`。
- 验收：外部模块可注册自定义工具并被调度。

#### P3-3 Web UI 升级 ✅ 已完成（第四批）
- 方案：可视化 diff 审批界面、会话/任务管理面板、工具调用时间线、成本与 token 仪表盘、Markdown/代码高亮渲染；WebSocket 替代 SSE 轮询。
- 实现：`/ws` WebSocket 端点（`handleWs/3`，控制面请求-响应 + 问答 token/progress/done 推送）；审批栏着色 diff（`/api/preview/patch`、`/api/pending/:taskId`）；任务/规划/指标侧栏；WS 优先并回退 SSE/REST。经端到端握手与帧收发验证。
- 验收：✅ 审批写操作时能看到 diff 并一键确认。

#### P3-4 工程化与发布
- 方案：补 GitHub Actions（compile + eunit + dialyzer + xref）、`elvis` 代码风格、`rebar3 hex` 发布准备、版本化 `CHANGELOG`。
- 验收：PR 触发 CI 全绿；可发布到 Hex。

---

## 5. 实施路线图（建议里程碑）

| 里程碑 | 内容 | 目标产出 |
|--------|------|----------|
| **M1 安全加固**（P0-1~P0-5） | 执行白名单、循环重试、遍历排除、精确补丁、Web 安全 | 安全可信的默认配置，补齐对应测试 |
| **M2 可靠与智能**（P1-1~P1-7） | 历史压缩、RAG、任务规划、成本治理、可观测性、提示词模板、核心测试 | 真正「智能且可控」的 Agent |
| **M3 兼容扩展**（P2-1~P2-5） | Anthropic/国产模型、Elixir、Git、诊断增强 | 覆盖更多模型与语言场景 |
| **M4 生态体验**（P3-1~P3-4） | MCP、插件化、Web UI 升级、CI/发布 | 开放生态 + 商用级体验 |

---

## 6. 风险与建议

- **安全优先**：M1 的 `callFunction` 重构与 Web 加固应**最先落地**，当前默认配置在公网或多人环境下不应直接暴露。
- **向后兼容**：所有改动保持 `ali` Facade API 稳定；新增能力以新工具/新配置项引入，旧入口保留。
- **渐进式 RAG**：embedding 与向量库先用内置 ETS/DETS 方案验证价值，再决定是否引入外部依赖，避免过早增加部署复杂度。
- **每个里程碑配套测试**：尤其是核心循环、安全策略、补丁引擎，必须有回归用例。
- **保持 Erlang 风格**：新增模块继续遵循 OTP（gen_server/supervisor/ETS/application env），避免临时进程堆叠。

---

## 7. 立即可做的「Quick Wins」（低成本高收益）

1. 把 `callFunction` 的危险 MFA 列入黑名单并提升为需确认（半天）。
2. `alLoop` 复用 `chatWithRetry`（半天）。
3. `collectFiles` 排除 `_build`/`.git`/`.al`（半天）。
4. `patchFile` 增加「多处匹配即报错」保护（半天）。
5. Web CORS 改为可配置白名单（半天）。
6. 面向用户的错误消息中文化、提示词遵循用户语言（半天）。

完成情况（**全部已完成或按决策闭合**）：
- ✅ 第 1 项（扩充 `callFunction` 内置黑名单，保留黑名单策略）
- ✅ 第 2 项（`alLoop` 重试）
- ✅ 第 3 项（遍历排除 `_build`/`.git`/`.al`）
- ✅ 第 4 项（`patchFile` 多处匹配保护）
- ✅ 第 5 项（Web CORS 白名单 + 认证/限速/安全头，见第八批）
- ✅ 第 6 项（提示词中文优先）

---

## 8. 最终审核总结（2026-06-20）

### 8.1 已交付能力矩阵

| 批次 | 主题 | 关键模块/能力 |
|------|------|----------------|
| 一 | 可靠基础 | LLM 重试、遍历排除、patch 保护、CJK token、费用估算 |
| 二 | 运维扩展 | 历史压缩、metrics/audit 查询、国产模型、Git 工具、插件注册、CI |
| 三 | 智能核心 | `alRag` TF-IDF 检索、`alPlan` 任务规划 |
| 四 | Web 体验 | WebSocket、可视化 diff、任务/规划/指标面板 |
| 五~七 | 生态 | MCP stdio + HTTP/SSE、resources/prompts、Elixir 索引 |
| 八 | Web 安全 | `alWebSec`、CORS/限速/token/安全头 |
| 收尾 | 黑名单加固 | 扩充 `defaultBlacklist`、配置空 token 修复 |

### 8.2 可选增强路线图（按需迭代）

1. **RAG 向量召回** — `alRag` 接入 embedding API + 向量存储，提升自然语言找代码准确率。
2. **MCP Server 模式** — 将 `ali` 工具对外暴露，供 Cursor/Claude Desktop 等调用。
3. **补丁引擎进阶** — unified diff 多 hunk、行号锚点（当前已有唯一匹配保护）。
4. **工程化** — `CHANGELOG`、Hex 发布、`elvis`、alLoop/alServer mock 集成测试。
5. **Git 写操作** — `gitCommit`（需确认）与 diff 驱动的提交信息生成。

### 8.3 使用建议

- **本地开发**：`webApiToken` 留空即可（读开放、写限回环）；生产暴露 Web 时务必配置 token + `webAllowOrigin`。
- **exec 模式**：`callFunction` 仍具破坏力，仅在可信环境开启；用 `execBlacklist` 追加项目级禁止项。
- **MCP**：在 `mcpServers` 配置外部 Server，启动时 `mcpConnectAll/0` 自动挂载工具/资源/提示。

以上非安全项已作为第一批落地，并全部通过 EUnit 测试。
