---
name: erlang-code-review
version: "1.1.0"
minAliVersion: "0.1.0"
triggers: ["代码审查", "code review", "审查", "review", "code quality"]
globs: ["**/*.erl", "**/*.hrl", "src/**/*.erl"]
tools: [reviewPackage, recentCommits, reviewChangeImpact, functionHistory, findCallers, getCallees, getSymbolSource, readFile, searchCode, moduleSymbols, validatePatch, dryRunPatch]
---

## 技能：Erlang 代码审查清单

当用户要求审查代码（review / 审查 / code review）时，按以下清单逐项检查：

### 工作流

1. **优先** `reviewPackage`：拿到结构化 findings（file/line/severity/rule）与 suggestedActions。
2. 若审提交：`recentCommits` / `reviewChangeImpact` / `functionHistory` 看影响面。
3. 用 `searchCode` / `moduleSymbols` / `getSymbolSource` / `readFile` 核对源码。
4. 用 `findCallers` / `getCallees` 核对调用关系。
5. 输出按 Blocker/Major/Minor 分级；若用户要修：`validatePatch` → `dryRunPatch` → `applyPatch`（需 edit 模式与确认）。

### 审查维度

#### 1. 结构（Structure）
- 模块职责是否单一（一个模块一件事）
- supervision tree 是否合理（重启策略、shutdown 值、child_spec）
- gen_server 是否被滥用（无状态逻辑不该用 gen_server）
- 公共 API 与内部实现是否分离（export 顺序、`%% API` 注释分隔）

#### 2. 正确性（Correctness）
- 模式匹配是否完备（有无遗漏分支导致 `function_clause`）
- 是否尾递归（`++` 在循环里累积是常见反模式）
- 错误处理：是否吞异常（`catch _`）、是否漏 `{error, _}` 分支
- 并发竞态：ETS 读写、共享状态、`receive` 无超时
- `timer:sleep` 轮询是否该用消息等待

#### 3. 风格（Style）
- 命名：原子/函数/变量是否表意，`snake_case` vs `camelCase` 一致性
- spec 是否齐全（尤其公共 API）
- 死代码：未使用的 export、未引用的 record 字段
- 注释是否解释「为什么」而非「做什么」

#### 4. 性能（Performance）
- N+1 查询模式（循环里调外部接口）
- 不必要的全表遍历（`lists:filter` + `lists:map` 可合并）
- ETS 竞争（高频写入用 `write_concurrency`）
- 二进制构造是否累积（`<<A/binary, B/binary>>` 在循环里低效）

### 输出格式

按严重程度分级，每条给出 `文件:行号` 与具体建议：

- **Blocker**：必须修才能合入
- **Major**：高优先
- **Minor**：可后续

不要编造未读到的代码；工具失败时明确说明。
