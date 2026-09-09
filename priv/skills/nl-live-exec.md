---
name: nl-live-exec
desc: 自然语言运营指令：检索 MFA，拼装表达式/匿名 fun，evalErl 执行
triggers: ["修建", "建造", "加钱", "给钱", "加资源", "给玩家", "帮我改", "帮我在", "运营", "GM", "加金币", "加经验", "拼装", "匿名函数", "evalErl", "执行字符串", "组合调用", "grant", "compose fun"]
tools: [searchCode, getSymbol, moduleExports, lookupAction, traceDataQuery, evalErl, runMfa]
---

## 技能：自然语言 → 本节点执行

用户用自然语言要求改活数据/完成业务（例如「在某个点修建某建筑并给加多少钱」）时，**不要只讲计划**，按下面做完。

### 分流

- 用户已经写出 `Mod:Fun(Args)`，且只需这一下 → `runMfa`
- 需要 **两个及以上** MFA，或要把检索到的接口拼成一段逻辑 → **`evalErl`**（不要连开一串 runMfa 凑合）

### 流程

1. **找接口**：`searchCode` / `lookupAction` / `getSymbol` / `moduleExports`。每个要调用的函数必须出现在本轮工具结果里（模块、函数、arity、参数含义）。没有命中就继续搜，禁止编造 MFA。
2. **拼装**：写成合法 Erlang
   - 表达式：`build:place(Pos, Type), wallet:add(Uid, Gold).`
   - 或匿名 fun：`fun() -> ok = build:place(Pos, Type), wallet:add(Uid, Gold) end.`
   - 参数用用户给的值；缺关键 id/坐标就先问，不要瞎填。
3. **校验**：对不熟的组合先 `evalErl` `dryRun=true`；lint/编译失败按返回改 `code`，再试。
4. **执行**：`dryRun=false` 跑通。向用户汇报：调用了哪些 MFA、返回值、是否达成需求。
5. **失败**：`notExported` / `mfaNotAllowed` 用工具返回的样本换真实 MFA，不要换着猜名字。

### 约束

- `evalErl` 里远程调用必须是字面量 `Mod:Fun(...)`，禁止 `apply` / `spawn` / `os:cmd`。
- 策略与 `runMfa` 相同（黑名单、须已导出）。
- 本工具改的是 **live 节点**，不是写源码；改代码仍走 patch 流程。
