# Agent 工具列表

工具由 `alTools` 注册，经 `alPolicy` 校验后分发到各 `alTool*` 模块执行。

权限级别：`read` | `executeSafe` | `executeRisky` | `write`

## 只读 — 项目文件

| 工具                | 说明                                                                     |
|-------------------|------------------------------------------------------------------------|
| `readFile`        | 读取项目内文件                                                                |
| `listFiles`       | 列出目录文件（支持递归、glob）                                                      |
| `searchText`      | 跨文件文本搜索                                                                |
| `projectIndex`    | 模块索引（传统扫描）                                                             |
| `codeIndex`       | 刷新持久化代码索引（Erlang `.erl` + Elixir `.ex`/`.exs`，含 `src/`、`lib/`、`test/`） |
| `searchCodeIndex` | 在代码索引中搜索模块/函数名                                                         |

## 只读 — 代码分析

| 工具                   | 说明                 |
|----------------------|--------------------|
| `getFunctionSource`  | 获取函数源码（带行号）        |
| `analyzeCalls`       | 函数出站调用（AST/正则）     |
| `findCallers`        | 查找调用方              |
| `getBeamAbstract`    | 已加载模块的 abstract 代码 |
| `analyzeBehaviours`  | OTP behaviour 识别   |
| `moduleDependencies` | 模块 import 依赖       |
| `dependencyGraph`    | 依赖图（含 Mermaid）     |
| `analyzeCallGraph`   | 模块调用图              |
| `codeQuality`        | 静态质量检查             |

## 只读 — 运行时

| 工具                    | 说明                                                     |
|-----------------------|--------------------------------------------------------|
| `getAppInfo`          | OTP 应用元数据                                              |
| `getSupTree`          | 监督树                                                    |
| `etopSummary`         | 进程内存 Top 摘要                                            |
| `loadedApplications`  | 已加载应用                                                  |
| `loadedModules`       | 已加载模块                                                  |
| `moduleExports`       | 模块导出函数                                                 |
| `registeredProcesses` | 注册进程名                                                  |
| `processList`         | 进程列表摘要                                                 |
| `processInfo`         | 单进程详情                                                  |
| `nodeInfo`            | 当前节点信息                                                 |
| `agentConfig`         | Agent 配置                                               |
| `runtimeSummary`      | 运行时综合摘要                                                |
| `remoteNodeInfo`      | 远程节点 RPC 摘要                                            |
| `topProcesses`        | 按 memory/reductions/message_queue_len 排序的 Top 进程（定位热点） |
| `schedulerInfo`       | 调度器、运行队列、归约数与内存概览                                      |

## 只读 — 代码检索 / 规划

| 工具           | 级别   | 说明                                           |
|--------------|------|----------------------------------------------|
| `searchCode` | read | 语义/关键词检索代码库，返回最相关函数片段（TF-IDF）                |
| `planSet`    | read | 为多步任务创建/覆盖步骤清单                               |
| `planUpdate` | read | 更新某步骤状态（pending/in_progress/done/skipped）与备注 |
| `planGet`    | read | 查看当前任务清单与进度                                  |

## 只读 — Git

| 工具          | 说明                        |
|-------------|---------------------------|
| `gitStatus` | 工作区状态（精简格式）               |
| `gitDiff`   | 改动 diff（可选 path / staged） |
| `gitLog`    | 最近提交日志                    |
| `gitBranch` | 分支与跟踪信息                   |

## 只读 — SVN

| 工具          | 说明                                            |
|-------------|-----------------------------------------------|
| `svnStatus` | 工作副本状态（可选 `showUpdates` 显示服务器修订）              |
| `svnDiff`   | 改动 diff（可选 `path` / `revision`，如 `BASE:HEAD`） |
| `svnLog`    | 最近提交日志（可选 `limit`）                            |
| `svnInfo`   | 工作副本信息（URL、当前修订、根路径）                          |

## 安全执行

| 工具                | 说明                                                  |
|-------------------|-----------------------------------------------------|
| `callFunction`    | 调用 Erlang 函数（内置高危 MFA 黑名单 + 可配置 `execBlacklist` 扩展） |
| `runEunit`        | 运行 EUnit（rebar3 eunit）                              |
| `runCommonTest`   | 运行 Common Test（rebar3 ct）                           |
| `listTestModules` | 列出测试模块                                              |

## 写入 / 风险（通常需确认）

| 工具                   | 级别           | 说明                                                                    |
|----------------------|--------------|-----------------------------------------------------------------------|
| `writeFile`          | write        | 写文件                                                                   |
| `patchFile`          | write        | 文本替换；`oldText` 须唯一匹配，否则报 `ambiguousMatch`，可传 `replaceAll=true` 强制全局替换 |
| `compileLoad`        | executeRisky | 编译并热加载                                                                |
| `formatCode`         | write        | 格式化源码：`.erl` 用 erl_tidy，`.ex`/`.exs` 用 `mix format`                   |
| `rollbackFile`       | write        | 从备份恢复                                                                 |
| `generateEunit`      | write        | 生成冒烟测试                                                                |
| `generateCommonTest` | write        | 生成 Common Test 套件骨架                                                   |

## 模式与策略

| 模式     | 允许                                   |
|--------|--------------------------------------|
| `ask`  | read、executeSafe                     |
| `edit` | read、executeSafe、write（需 allowWrite） |
| `exec` | 全部（仍受 policy 约束）                     |

写操作默认 `requireWriteConfirmation => true`，Agent 返回 `TaskId`，需：

```erlang
ali:approve(TaskId).
```

## OpenAI Schema

```erlang
alTools:openAiTools().   %% 内部使用
ali:tools().             %% 工具名列表
```

## 自定义工具（运行时注册）

无需修改源码即可扩展 Agent 能力：

```erlang
ali:registerTool(#{
    name => myTool,
    description => <<"做某事"/utf8>>,
    parameters => <<"{\"x\": \"...\"}"/utf8>>,   %% JSON schema 或简单示例
    module => myMod,
    function => myFun,                            %% 签名为 fun(Args :: map(), Config :: map())
    level => read                                 %% read | executeSafe | executeRisky | write
}).
ali:unregisterTool(myTool).
```

注册后的工具自动纳入工具列表、OpenAI schema 与策略校验；不可覆盖内置工具。

## MCP（Model Context Protocol）工具

接入外部 MCP Server（文件系统、GitHub、数据库、网页检索等现成生态），其工具会被**自动发现并注册**，模型可像内置工具一样调用，无需写
Erlang 代码。

```erlang
%% 连接单个 Server（stdio 传输）
{ok, ToolNames} = ali:mcpConnect(#{
    name => filesystem,
    command => "npx",
    args => ["-y", "@modelcontextprotocol/server-filesystem", "."],
    env => [],
    level => executeRisky          %% 注册工具的权限级别
}).

%% 连接远程 Server（Streamable HTTP/SSE 传输）
{ok, _} = ali:mcpConnect(#{
    name => remote,
    transport => http,
    url => "https://example.com/mcp",
    headers => [{"Authorization", "Bearer xxx"}],
    level => executeRisky
}).

ali:mcpConnectAll().               %% 连接 aliCfg.cfg 中 mcpServers 配置的全部 Server
ali:mcpServers().                  %% 已连接 Server 及状态（含 transport/能力/资源/提示数）
ali:mcpTools().                    %% 已发现的 MCP 工具名
ali:mcpCall(filesystem, <<"read_file">>, #{<<"path">> => <<"README.md">>}).  %% 直接调用
ali:mcpDisconnect(filesystem).     %% 断开并注销其工具

%% 资源（resources）与提示模板（prompts）
ali:mcpResources().                                  %% 聚合所有 Server 的资源清单
ali:mcpReadResource(filesystem, <<"file:///x">>).    %% 读取资源内容
ali:mcpPrompts().                                    %% 聚合所有 Server 的提示模板清单
ali:mcpGetPrompt(remote, <<"greet">>, #{}).          %% 获取提示模板（可带参数）
```

当任一已连接 Server 提供 resources/prompts 能力时，会自动注册以下**通用工具**供模型使用：

| 工具                 | 级别   | 说明                                                |
|--------------------|------|---------------------------------------------------|
| `mcpListResources` | read | 列出所有 MCP Server 的资源（server/uri/name）              |
| `mcpReadResource`  | read | 读取指定 Server 的资源内容（参数 `server`/`uri`）              |
| `mcpListPrompts`   | read | 列出所有 MCP Server 的提示模板                             |
| `mcpGetPrompt`     | read | 获取指定 Server 的提示模板（参数 `server`/`name`/`arguments`） |

实现说明：

- 传输：
    - **stdio** + JSON-RPC 2.0（换行分隔），子进程方式启动；
    - **Streamable HTTP/SSE**：向 `url` POST 请求，响应为 `application/json` 或 `text/event-stream`，自动维护
      `Mcp-Session-Id` 会话头。
- 能力发现：`initialize` 握手后按 Server `capabilities` 自动调用 `tools/list`、`resources/list`、`prompts/list`；工具调用走
  `tools/call`，资源读取走 `resources/read`，提示获取走 `prompts/get`。
- 工具名稳定化：注册名形如 `mcpFilesystemReadFile`（无下划线，避免与归一化冲突）；参数键名会按 schema 原始属性名还原后再发送给
  Server。
- 权限：MCP 工具沿用策略引擎，默认 `executeRisky`（非 exec 模式需确认），可在连接时指定 `level`；通用资源/提示工具为 `read`。
- 容错：Server 进程退出（stdio）或 HTTP 请求失败时自动注销其工具并回收挂起调用。
