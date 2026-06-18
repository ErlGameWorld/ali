# Erlang Agent 开发计划书

> **当前状态（2026-06）**：项目已整合为 **ali** OTP 应用，对外 API 为 `ali` 模块。本文档保留产品定位与实现历程，最新使用说明见 [README.md](README.md)、[API.md](API.md)。

## 1. 项目定位

当前 **ali** 是一个运行在 Erlang 节点内的 OTP 应用，包含：

- `llmCli` — 大模型 HTTP 客户端
- **Agent Runtime** — 对话、工具调用、权限、审计
- **Developer Assistant** — 项目问答、运行时诊断、代码修改

**对外唯一入口**：`ali` 模块（[`src/ali.erl`](../../src/ali.erl)）

## 2. 核心使用场景

### 2.1 项目问答

用户可以直接询问当前项目相关问题，例如：

- “这个项目有哪些模块？”
- “`llmCli:chat/3` 是怎么组装请求的？”
- “现在支持哪些 LLM provider？”
- “我要加一个兼容 OpenAI 的国产模型接口，应该改哪里？”

Agent 需要读取项目文件、构建上下文，并给出基于真实代码的回答。

### 2.2 Erlang 节点运行时分析

Agent 运行在 Erlang 节点中，可以查看节点状态，例如：

- 当前加载了哪些模块。
- 当前应用、监督树、进程和注册进程状态。
- 某个模块是否已加载，导出了哪些函数。
- 某个进程的 `process_info/1`、消息队列长度、当前函数等信息。

这类能力应该优先做成只读工具，避免一开始就引入高风险操作。

### 2.3 对话式函数执行

用户可以通过自然语言要求 Agent 执行 Erlang 函数，例如：

- “帮我运行 `llmCli:estimateTokens(<<"hello">>)` 看看结果。”
- “调用 `application:loaded_applications()`。”
- “帮我用当前配置发一个测试请求。”

Agent 需要把意图转换成受控函数调用，而不是直接无限制执行任意字符串。建议先支持白名单模块和函数，再逐步扩展。

### 2.4 Shell / REPL 交互

Agent 可以提供类似开发助手的交互式能力：

- 在 Erlang shell 中通过对话触发函数调用。
- 输出执行结果、错误栈和建议。
- 支持多轮上下文，例如上一步返回的模块名、进程 ID、配置项可以在下一步继续使用。

这部分可以先实现 Erlang shell 内的 `agent:ask/1`、`agent:run/1`，之后再考虑独立 CLI。

### 2.5 代码分析和修改

Agent 可以读取项目源码、分析问题，并在用户确认后修改代码，例如：

- 新增 provider。
- 修复函数签名或类型问题。
- 生成测试模块。
- 重构某个模块。

代码修改能力必须有明确边界：先生成计划和 diff，再执行写入。对于删除文件、覆盖文件、执行危险命令，应要求显式确认。

### 2.6 通用问答

除了项目内问题，Agent 也可以回答 Erlang、OTP、LLM API、架构设计、调试思路等通用问题。但回答时应区分“基于项目代码的事实”和“通用建议”。

## 3. 需求拆分

### 3.1 功能需求

| 编号 | 需求 | 优先级 | 说明 |
| --- | --- | --- | --- |
| F1 | 对话状态管理 | P0 | 支持多轮对话、系统提示词、历史裁剪 |
| F2 | 工具调用协议 | P0 | 让模型能请求调用本地工具，Agent 负责执行 |
| F3 | 项目文件读取 | P0 | 读取 Erlang 项目文件、README、配置文件 |
| F4 | 项目索引 | P0 | 建立模块、函数、导出函数、文件路径索引 |
| F5 | 运行时只读诊断 | P0 | 查看应用、模块、进程、节点基础状态 |
| F6 | 受控函数执行 | P1 | 白名单方式调用 Erlang 函数并返回结果 |
| F7 | 代码修改 | P1 | 读-计划-确认-写入的修改流程 |
| F8 | 流式交互 | P1 | 对话时支持模型流式输出 |
| F9 | Shell 集成 | P1 | 提供 `agent:ask/1`、`agent:run/1` 等入口 |
| F10 | 测试生成与执行 | P2 | 生成 EUnit/Common Test，并可执行验证 |
| F11 | 长任务管理 | P2 | 后台任务、任务状态、取消、日志 |
| F12 | 多节点支持 | P3 | 查询远程节点状态或跨节点执行只读诊断 |

### 3.2 非功能需求

- 安全：默认只读，写文件、执行函数、Shell 命令、网络请求都要分级授权。
- 可审计：每次工具调用记录输入、输出、耗时、是否修改状态。
- 可配置：provider、model、base_url、权限策略、项目根目录、索引范围都可以配置。
- 可测试：Agent Runtime、工具调度和关键工具要能单元测试。
- 可扩展：新增工具不应修改核心循环，只需要注册工具定义和执行函数。
- Erlang 风格：优先使用 OTP 进程、监督树、ETS、应用配置，而不是堆叠临时进程。

## 4. 建议总体架构

### 4.1 模块划分

建议逐步拆出以下模块：

| 模块 | 职责 |
| --- | --- |
| `llm_client` 或保留 `llmCli` | 纯 LLM API 客户端，负责 HTTP、provider、消息格式 |
| `llm_agent` | Agent 对外入口，提供 `ask/1`、`ask/2`、`run/1` |
| `llm_agent_server` | `gen_server`，维护会话、模型配置、任务状态 |
| `llm_agent_loop` | Agent 主循环，处理模型响应、工具调用、最终回答 |
| `llm_agent_tools` | 工具注册表，提供工具 schema、权限级别和执行入口 |
| `llm_agent_tool_project` | 项目文件读取、搜索、模块/函数索引 |
| `llm_agent_tool_runtime` | Erlang 节点、应用、进程、模块只读诊断 |
| `llm_agent_tool_eval` | 受控函数调用 |
| `llm_agent_tool_edit` | 文件修改、patch、备份、diff |
| `llm_agent_policy` | 权限策略、确认机制、危险操作判定 |
| `llm_agent_context` | 上下文构建、历史裁剪、项目摘要 |
| `llm_agent_audit` | 工具调用日志和任务记录 |

早期可以先用较少模块实现，等接口稳定后再拆细。

### 4.2 Agent 调用流程

标准流程建议如下：

1. 用户调用 `llm_agent:ask(Prompt)`。
2. `llm_agent_server` 读取当前会话和配置。
3. `llm_agent_context` 组装系统提示词、历史消息、项目摘要、可用工具列表。
4. `llmCli` 调用模型。
5. 如果模型返回普通回答，直接返回给用户。
6. 如果模型请求工具调用，`llm_agent_loop` 校验工具权限并执行。
7. 工具结果追加到上下文，再次调用模型。
8. 循环直到得到最终回答、达到最大步数或触发权限阻断。

### 4.3 工具调用模型

目前 `llmCli` 只处理普通聊天消息，后续需要扩展工具调用能力。可以先设计内部工具协议，不急着绑定某一个 provider 的 tool calling 格式。

内部工具调用建议表示为：

```erlang
#{tool => <<"read_file">>,
  args => #{path => <<"src/llmCli.erl">>},
  id => <<"call_001">>}.
```

工具返回建议表示为：

```erlang
#{id => <<"call_001">>,
  ok => true,
  result => #{content => <<"file content...">>}}.
```

后续再实现 OpenAI、Anthropic、自定义 provider 的工具调用格式适配。

## 5. 权限与安全设计

### 5.1 权限等级

建议把工具分为四级：

| 等级 | 类型 | 示例 | 默认策略 |
| --- | --- | --- | --- |
| `read` | 只读 | 读文件、列模块、查看进程信息 | 默认允许 |
| `execute_safe` | 低风险执行 | 调用白名单纯函数、估算 token | 可配置允许 |
| `execute_risky` | 可能改变状态 | 调用业务函数、发送 HTTP 请求、修改应用环境 | 需要确认 |
| `write` | 写入或破坏性操作 | 写文件、删除文件、覆盖配置 | 必须确认 |

### 5.2 函数执行约束

受控函数执行不要直接 `erl_eval` 任意用户输入。建议第一版只支持：

- `{Module, Function, Args}` 结构化调用。
- 模块必须在白名单内。
- 函数必须在白名单内，或通过策略允许。
- 参数只允许安全 Erlang term，不执行字符串表达式。
- 设置超时和最大输出长度。
- 捕获异常并返回 `{error, Class, Reason, Stacktrace}` 摘要。

### 5.3 文件修改约束

代码修改建议遵循：

- 修改前必须读取最新文件内容。
- 先返回修改计划和预期 diff。
- 写入前可以配置为需要用户确认。
- 默认禁止修改 `.git/`、密钥文件、构建产物和超出项目根目录的路径。
- 每次写入记录 audit log。

## 6. 数据和状态设计

### 6.1 会话状态

会话可以包含：

```erlang
#{id => SessionId,
  messages => Messages,
  created_at => CreatedAt,
  updated_at => UpdatedAt,
  project_root => ProjectRoot,
  model => Model,
  options => Options,
  metadata => #{}}.
```

短期可以存在 `gen_server` state 里；后续如果需要持久化，可以落到文件或 DETS。

### 6.2 项目索引

项目索引可以包含：

- 文件列表。
- Erlang 模块名到文件路径。
- `-export` 函数列表。
- `-spec` 信息。
- README、rebar.config、app.src 摘要。
- 最近访问或最近修改文件。

第一版可以每次按需读取；第二版再引入 ETS 缓存和增量刷新。

## 7. 分阶段开发计划

### 阶段 0：整理现有客户端

目标：把当前 LLM 客户端稳定下来，作为 Agent 的底座。

任务：

- 修正 README 与实际导出 API 的差异。
- 为 `llmCli:chat/2,3`、配置加载、消息构建补充基础测试。
- 明确 provider 请求/响应差异，避免 Agent 层依赖 provider 细节。
- 评估是否将 `llmCli.erl` 拆为 `llm_client`、`llm_provider_openai` 等模块。

交付物：

- 可编译、可测试的 LLM 客户端。
- 基础测试用例。
- 客户端 API 文档。

### 阶段 1：最小可用 Agent

目标：实现一个可以在 Erlang shell 中对话的只读 Agent。

任务：

- 新增 `llm_agent` 对外模块。
- 新增 `llm_agent_server`，用 `gen_server` 管理会话。
- 实现 `llm_agent:ask/1` 和 `llm_agent:ask/2`。
- 复用 `llmCli` 发送模型请求。
- 增加系统提示词，明确 Agent 是 Erlang 项目助手。
- 支持历史消息和简单上下文裁剪。

验收示例：

```erlang
llm_agent:start().
llm_agent:ask("这个项目是做什么的？").
llm_agent:ask("解释一下 llmCli:chat/3 的流程").
```

### 阶段 2：项目读取与代码问答

目标：让 Agent 可以基于真实项目文件回答问题。

任务：

- 实现 `read_file`、`list_files`、`search_text` 工具。
- 实现 Erlang 模块索引：文件、模块名、导出函数。
- Agent 循环支持模型请求工具、执行工具、把结果喂回模型。
- 增加最大工具调用步数，避免无限循环。
- 对读取路径做项目根目录限制。

验收示例：

```erlang
llm_agent:ask("列出这个项目的 Erlang 模块和它们的职责").
llm_agent:ask("llmCli:loadConfigFromFile/1 有什么风险？").
```

### 阶段 3：运行时诊断工具

目标：让 Agent 具备 Erlang 节点内省能力。

任务：

- 实现 `loaded_applications`、`loaded_modules`、`module_exports` 工具。
- 实现 `process_list`、`process_info`、`registered_processes` 工具。
- 对输出做摘要和长度限制。
- 对敏感信息做过滤，例如配置中的 API key。

验收示例：

```erlang
llm_agent:ask("当前节点运行了哪些 application？").
llm_agent:ask("查看 llmCli 模块导出了哪些函数").
```

### 阶段 4：受控函数执行

目标：支持通过对话执行安全函数。

任务：

- 实现 `call_function` 工具，输入为 `{Module, Function, Args}`。
- 建立默认白名单，例如 `llmCli:estimateTokens/1`、`application:loaded_applications/0`。
- 增加超时、异常捕获、输出截断。
- 引入 `llm_agent_policy`，集中判断是否允许执行。

验收示例：

```erlang
llm_agent:run({llmCli, estimateTokens, [<<"hello world">>]}).
llm_agent:ask("帮我调用 estimateTokens 估算这段文本 token 数").
```

### 阶段 5：代码修改能力

目标：让 Agent 可以按计划修改项目代码。

任务：

- 实现 `write_file`、`patch_file` 工具。
- 修改前自动读取文件并生成修改计划。
- 对写操作加入确认流程。
- 支持生成变更摘要。
- 为修改工具增加测试，覆盖路径逃逸、超出项目根目录、只读模式等场景。

验收示例：

```erlang
llm_agent:ask("帮我给 llmCli 增加一个 getModelConfig/0 函数，先给计划").
llm_agent:approve(TaskId).
```

### 阶段 6：开发体验增强

目标：让 Agent 更像一个可长期使用的 Erlang 开发助手。

任务：

- 支持流式输出。
- 支持任务 ID、后台任务和取消。
- 支持审计日志查询。
- 支持会话保存和恢复。
- 支持配置文件，例如 `agent.config.json` 或 Erlang sys config。
- 增加常用命令封装：`agent:status/0`、`agent:tools/0`、`agent:sessions/0`。

## 8. 第一批建议实现任务

建议下一步不要直接做“自动修改代码”，而是先做只读 Agent 主干：

1. 新建 `llm_agent.erl`，提供 `start/0`、`stop/0`、`ask/1`、`ask/2`。
2. 新建 `llm_agent_server.erl`，用 `gen_server` 保存会话和配置。
3. 新建 `llm_agent_context.erl`，负责系统提示词和历史消息组装。
4. 新建 `llm_agent_tools.erl`，先注册空工具或只读工具。
5. 新建 `llm_agent_tool_project.erl`，实现 `list_files` 和 `read_file`。
6. 修改 `llmCli.app.src`，把新模块纳入应用结构。
7. 增加最小 README 示例，展示 `llm_agent:ask/1`。

这一批完成后，项目就从“LLM 客户端”变成了“可对话的 Erlang 项目助手雏形”。

## 9. 关键技术风险

- Provider 工具调用格式不统一：需要内部工具协议隔离 provider 差异。
- 上下文过长：需要项目摘要、按需读取、历史裁剪和输出截断。
- 任意函数执行风险高：必须从白名单和权限策略开始。
- 文件修改风险高：必须限制项目根目录，并采用确认流程。
- Erlang shell 交互体验：同步调用容易阻塞，需要超时和后台任务设计。
- 代码索引准确性：简单文本解析可以先用，后续可能需要更严谨的 Erlang 语法解析。

## 10. 建议的近期决策

在开始编码前，需要先确认几件事：

- Agent 第一版是否只服务当前项目，还是要作为通用 Erlang 库提供给其他项目。
- 是否保留模块名 `llmCli`，还是逐步迁移到更 Erlang 风格的 `llm_cli` 命名。
- 第一版模型工具调用是先使用 provider 原生 tool calling，还是先用文本协议模拟。
- 写文件和函数执行是否默认必须人工确认。
- 是否需要支持 Windows 和 Linux 路径差异。

## 11. 推荐路线

推荐路线是：

先完成“只读项目问答 Agent”，再加“运行时诊断”，然后才加“受控函数执行”和“代码修改”。

原因是项目问答和运行时诊断能最快体现 Agent 价值，而且风险低；函数执行和代码修改虽然强大，但必须建立在工具协议、权限策略、审计日志和上下文管理都稳定的基础上。

## 12. 实现进度（2026-06）

| 阶段 | 状态 | 说明 |
| --- | --- | --- |
| 0 整理 LLM 客户端 | 完成 | hackney 4.x、DeepSeek、config.cfg 加载 |
| 1 最小可用 Agent | 完成 | `ali`、`alServer`、`alLoop` |
| 2 项目读取与问答 | 完成 | 递归 `listFiles`/`searchText`、`projectIndex` |
| 3 运行时诊断 | 完成 | 含 `remoteNodeInfo` 多节点 RPC |
| 4 受控函数执行 | 完成 | `callFunction` 白名单 |
| 5 代码修改 | 完成 | `writeFile`/`patchFile` + `approve/1` |
| 6 体验增强 | 完成 | `askStream`、`askAsync`、会话持久化、审计日志 |

### 已实现模块

- `alSession` — 会话保存至 `.al/sessions/*.json`
- `alTask` — 后台任务与取消
- `llmCli:chatCompletion/3` — OpenAI/DeepSeek 原生 tool calling
- `alTools:openAiTools/0` — 工具 schema 导出

### 验收命令

```bash
rebar3 compile
rebar3 eunit
rebar3 shell
ali:ask("你好").
```

### 后续可选增强

- EUnit/Common Test 自动生成与执行（F10）
- 更严谨的 Erlang 语法解析索引
- Anthropic 原生 tool calling
- 独立 CLI 入口
