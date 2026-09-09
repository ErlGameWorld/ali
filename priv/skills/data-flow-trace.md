---
name: data-flow-trace
triggers: ["查一下", "查询", "怎么查", "怎么得到", "数据从哪", "从哪来", "调用链", "前置函数", "需要先调", "参数来源", "data flow", "trace data", "ets 表", "mnesia", "查数据", "字段从哪"]
tools: [traceDataQuery, dataSources, dataSourceCallers, paramSources, traceDataFlow, searchCode, gotoDef, getSymbolSource, lookupAction]
---

## 技能：数据流 / 查询链追踪

当用户问「怎么查 X / 数据从哪来 / 调用链」时：

### 流程

1. 有 `retrieved_context.dataQuery` / `knowledge` 时优先用
2. 否则 `lookupAction` → `traceDataQuery`
3. 低置信度时请用户给 `@table:name` 或 `@mfa:Mod:Fun/Arity`
4. 用 `gotoDef` / `getSymbolSource` 核实关键 MFA，再回答

### 示例

```erlang
%% traceDataQuery 参数示例（中性）
#{question => <<"查一下订单状态"/utf8>>, maxDepth => 5, maxNodes => 50}
```

### 注意

- 禁止靠猜 `get*` / `query*` 拼调用链
- 业务专有名词以目标项目 knowledge / actions 为准
