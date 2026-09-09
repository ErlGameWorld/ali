---
name: supervision-review
triggers: ["监督树", "supervisor", "重启策略", "restart strategy", "child_spec", "shutdown", "one_for_one", "one_for_all", "rest_for_one", "simple_one_for_one"]
tools: [supervisorTree, appTopology, getSymbolSource, moduleExports, readFile, searchCode]
---

## 技能：监督树审查

当用户要求审查 supervisor 设计或排查重启问题时，按以下清单逐项检查。

### 工作流

1. **拉取监督树**：`supervisorTree`（当前节点 ali 侧树）；业务树用 `searchCode`/`readFile` 读目标 `*_sup.erl`。
2. **应用拓扑**：`appTopology` 看应用依赖。
3. **读 supervisor 源码**：`getSymbolSource` / `readFile` 看 `init/1` 的 `SupFlags` 与 `ChildSpecs`。
4. **逐项审查**（见下方清单）。
5. **给结论**：风险点 + 修复建议 + 优先级。

### 审查清单

#### SupFlags

- [ ] `strategy` 是否匹配业务语义：
  - `one_for_one`：子进程独立（默认推荐）
  - `one_for_all`：子进程强耦合（少用）
  - `rest_for_one`：后续依赖前者（管道式）
  - `simple_one_for_one`：动态大量同类（池化）
- [ ] `intensity` / `period` 合理：默认 `10/60` 适合多数场景；高频重启场景需调高
- [ ] `intensity` 过高（如 `1000/60`）→ 等于禁用保护，需说明理由

#### ChildSpec

- [ ] 每个 `id` 唯一
- [ ] `start` 的 `{M,F,A}` 与实际导出匹配
- [ ] `restart` 策略合理：
  - `permanent`：必须常驻（supervisor 核心）
  - `temporary`：失败不重启（一次性任务）
  - `transient`：正常退出不重启，异常才重启（任务型）
- [ ] `shutdown` 合理：
  - `worker`：`5000`（ms）或 `brutal_kill`
  - `supervisor`：`infinity`（必须等子树优雅退出）
  - 太短（如 `100`）→ 子进程来不及清理
- [ ] `type` 正确（`worker` / `supervisor`）
- [ ] `modules` 正确（通常 `[M]`；`dynamic` 仅用于动态回调）

#### 结构

- [ ] 树深度合理（建议 ≤ 4 层）
- [ ] 无循环依赖（A 的 supervisor 是 A 的子进程）
- [ ] `simple_one_for_one` 的子进程不会因 supervisor 重启而全灭
- [ ] 顶层 supervisor 的 `restart` 为 `permanent`

### 常见问题

| 问题 | 风险 | 修复 |
|------|------|------|
| `shutdown` 太短 | 子进程来不及释放资源 | worker ≥ 5000，supervisor = infinity |
| `intensity` 过高 | 故障进程无限重启拖垮系统 | 降到 10/60 或加熔断 |
| `one_for_all` 滥用 | 一个子进程挂导致全树重启 | 改 `one_for_one` |
| `simple_one_for_one` 无上限 | 进程泄漏 | 加 `max_children` |
| 子 supervisor 用 `transient` | 升级时可能不重启 | 改 `permanent` |
