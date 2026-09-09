---
name: runtime-inspect
triggers: ["运行时", "ets", "进程", "process", "pid", "state", "snapshot", "mailbox", "supervisor", "getRuntime"]
tools: [getRuntime, getEts, getProcesses, processInfo, etsLookup, supervisorTree, runMfa, searchCode, lookupAction, traceDataQuery]
---

## 技能：运行时状态检视

当用户询问「当前进程 / ETS / 节点快照 / 线上业务数据」时，按以下流程：

### 流程

1. **快照先行**
   - `getRuntime` / `getProcesses` / `getEts`
   - 深潜：`processInfo` / `etsLookup`
   - 监督树：`supervisorTree`（自动发现 `*_sup`）

2. **业务线上数据**
   - 先 `lookupAction` / `traceDataQuery` / `searchCode` 找真实 MFA
   - **单次查询**：`runMfa` + `sideEffect=read`
   - **单次修改**：`runMfa` + `sideEffect=write`；可选 `verifyRead` 做 before/after
   - **多步自然语言**（修建筑+加钱、组合改数据）：找齐 MFA 后用 `evalErl` 拼表达式/匿名 fun；不确定先 `dryRun=true`
   - **禁止**用 `dbQuery` 查目标项目业务数据（那是 ali 本地 SQLite）
   - 禁止臆造 MFA
   - 业务实体词来自 `.ali/knowledge/agent.json`（由 digest 维护），勿臆造项目专有名词清单

3. **关联代码** — 给出 `Mod:Fun/Arity` 与文件位置

### 注意

- `verifyRead` 可选；默认不强制
- 敏感字段脱敏；探测失败不要编造
