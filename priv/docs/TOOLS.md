# Agent 工具列表

工具由 `alTools` 注册，经 `alPolicy` 校验后分发到各 `alTool*` 模块执行。

权限级别：`read` | `executeSafe` | `executeRisky` | `write`

## 只读 — 项目文件

| 工具 | 说明 |
|------|------|
| `readFile` | 读取项目内文件 |
| `listFiles` | 列出目录文件（支持递归、glob） |
| `searchText` | 跨文件文本搜索 |
| `projectIndex` | 模块索引（传统扫描） |
| `codeIndex` | 刷新持久化代码索引 |
| `searchCodeIndex` | 在代码索引中搜索模块/函数名 |

## 只读 — 代码分析

| 工具 | 说明 |
|------|------|
| `getFunctionSource` | 获取函数源码（带行号） |
| `analyzeCalls` | 函数出站调用（AST/正则） |
| `findCallers` | 查找调用方 |
| `getBeamAbstract` | 已加载模块的 abstract 代码 |
| `analyzeBehaviours` | OTP behaviour 识别 |
| `moduleDependencies` | 模块 import 依赖 |
| `dependencyGraph` | 依赖图（含 Mermaid） |
| `analyzeCallGraph` | 模块调用图 |
| `codeQuality` | 静态质量检查 |

## 只读 — 运行时

| 工具 | 说明 |
|------|------|
| `getAppInfo` | OTP 应用元数据 |
| `getSupTree` | 监督树 |
| `etopSummary` | 进程内存 Top 摘要 |
| `loadedApplications` | 已加载应用 |
| `loadedModules` | 已加载模块 |
| `moduleExports` | 模块导出函数 |
| `registeredProcesses` | 注册进程名 |
| `processList` | 进程列表摘要 |
| `processInfo` | 单进程详情 |
| `nodeInfo` | 当前节点信息 |
| `agentConfig` | Agent 配置 |
| `runtimeSummary` | 运行时综合摘要 |
| `remoteNodeInfo` | 远程节点 RPC 摘要 |

## 安全执行

| 工具 | 说明 |
|------|------|
| `callFunction` | 调用 Erlang 函数（`execBlacklist` 拦截） |
| `runEunit` | 运行 EUnit（rebar3 eunit） |
| `runCommonTest` | 运行 Common Test（rebar3 ct） |
| `listTestModules` | 列出测试模块 |

## 写入 / 风险（通常需确认）

| 工具 | 级别 | 说明 |
|------|------|------|
| `writeFile` | write | 写文件 |
| `patchFile` | write | 文本替换 |
| `compileLoad` | executeRisky | 编译并热加载 |
| `rollbackFile` | write | 从备份恢复 |
| `generateEunit` | write | 生成冒烟测试 |
| `generateCommonTest` | write | 生成 Common Test 套件骨架 |

## 模式与策略

| 模式 | 允许 |
|------|------|
| `ask` | read、executeSafe |
| `edit` | read、executeSafe、write（需 allowWrite） |
| `exec` | 全部（仍受 policy 约束） |

写操作默认 `requireWriteConfirmation => true`，Agent 返回 `TaskId`，需：

```erlang
ali:approve(TaskId).
```

## OpenAI Schema

```erlang
alTools:openAiTools().   %% 内部使用
ali:tools().             %% 工具名列表
```
