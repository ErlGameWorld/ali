---
name: dialyzer-triage
triggers: ["dialyzer", "类型分析", "type analysis", "success typing", "warning triage", "类型警告", "PLT"]
tools: [runDialyzer, getSymbolSource, applyPatch, searchText]
---

## 技能：Dialyzer 类型分析分诊

当用户要求跑 dialyzer 或处理类型警告时，按以下流程。

### 工作流

1. **跑 dialyzer**：用 `runDialyzer`（底层 `rebar3 dialyzer`；若存在也可参考 `priv/scripts/dialyzer.escript`）。
2. **收集警告**：按类别分组（见下方分类）。
3. **逐条分诊**：
   - 读相关源码 `getSymbolSource`
   - 判断是真 bug / 误报 / 类型 spec 不准
4. **修复**：
   - 真 bug → `applyPatch` 修复逻辑
   - spec 不准 → `applyPatch` 修正 `-spec`
   - 误报 → 加 `-dialyzer({nowarn_function, F/A})` 或细化 spec
5. **复跑**：确认警告清零或只剩已知误报。

### 警告分类与处理

| 警告类型 | 含义 | 处理优先级 |
|---------|------|-----------|
| `Function X has no local return` | 函数永远不返回（如 `erlang:error/1` 后） | 检查是否漏写正常返回路径 |
| `The call X will never return` | 类型推断认为调用必失败 | 检查 spec 与实际调用 |
| `Contract Y cannot be right` | `-spec` 与实现不符 | 修正 spec |
| `Overloaded contract Y has overlapping domains` | 重载 spec 有歧义 | 合并或细化 spec |
| `Function Y only terminates with exception` | 必抛异常无正常返回 | 加正常返回或标 `no_return` |
| `The variable X can never match` | 模式匹配永远失败 | 删除死代码 |
| `Unmatched return` | 返回值被忽略 | 检查是否需要处理 `{error,_}` |

### 修复原则

1. **优先修真 bug**：`no local return` / `never return` 常暗示逻辑缺陷。
2. **spec 准确性**：`-spec` 是文档也是契约，不准的 spec 会产生连锁误报。
3. **最小化 `nowarn`**：只在确认误报时用，且注释说明原因。
4. **PLT 维护**：首次跑前先 `dialyzer --build_plt --apps erts kernel stdlib mnesia`。

### 检查清单

- [ ] 已按类别分组警告
- [ ] 真 bug 已修复
- [ ] 不准的 spec 已修正
- [ ] 误报已标注 `nowarn` 并注释原因
- [ ] 复跑后警告数下降或清零
