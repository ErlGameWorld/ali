---
name: security-audit-erl
triggers: ["安全审计", "security audit", "安全审查", "危险调用", "注入", "反序列化", "代码注入", "apply", "rpc call"]
tools: [searchText, getSymbolSource, moduleExports]
---

## 技能：Erlang 安全审计

当用户要求安全审查时，按以下清单扫描危险模式。

### 工作流

1. **扫描危险 API**：`searchText` 搜索下方关键词。
2. **逐项审查**：`getSymbolSource` 读上下文判断是否可控。
3. **分级**：Critical / High / Medium / Low。
4. **给报告**：风险点 + 证据 + 修复建议。

### 危险模式清单

#### Critical（远程代码执行）

| 模式 | 风险 | 搜索关键词 |
|------|------|-----------|
| `apply(M, F, A)` 输入可控 | 任意函数调用 | `apply(` |
| `erlang:spawn(M, F, A)` 输入可控 | 任意进程 | `spawn(` |
| `rpc:call(Node, M, F, A)` 输入可控 | 远程执行 | `rpc:call` |
| `eval` / `erl_eval` | 代码注入 | `erl_eval:` |
| `file:script/1` 用户输入路径 | 任意脚本执行 | `file:script` |

#### High（注入/反序列化）

| 模式 | 风险 | 搜索关键词 |
|------|------|-----------|
| `binary_to_term(Bin, [safe])` 缺失 `safe` | 原子泄漏/代码注入 | `binary_to_term` |
| `os:cmd/1` 输入拼接 | 命令注入 | `os:cmd` |
| `httpc` URL 拼接用户输入 | SSRF | `httpc:request` |
| `file:read_file/1` 路径拼接 | 路径穿越 | `filename:join` |

#### Medium（信息泄漏/DoS）

| 模式 | 风险 | 搜索关键词 |
|------|------|-----------|
| `erlang:list_to_atom/1` 用户输入 | 原子表耗尽 | `list_to_atom` |
| `catch` 吞异常 | 隐藏错误 | `catch ` |
| 无限制 `ets:new` | 内存耗尽 | `ets:new` |
| 无 `timeout` 的 `gen_server:call` | DoS | `gen_server:call` |

#### Low（最佳实践）

| 模式 | 风险 |
|------|------|
| 硬编码 cookie / secret | 凭证泄漏 |
| `node()` 跨节点无认证 | 信任过度 |
| 日志含敏感信息 | 信息泄漏 |

### 修复原则

1. **`apply`/`spawn`/`rpc`**：输入必须白名单校验，禁止用户控制 M/F。
2. **`binary_to_term`**：始终加 `[safe]` 选项，禁止反序列化函数。
3. **`os:cmd`**：用 `erlang:open_port` + 参数列表，避免 shell 拼接。
4. **`list_to_atom`**：改用 `list_to_existing_atom` 或二进制 key。
5. **`gen_server:call`**：始终设 `timeout`，处理 `{error, timeout}`。

### 检查清单

- [ ] 已扫描所有 Critical 关键词
- [ ] 已扫描所有 High 关键词
- [ ] 每个命中点已审查输入来源
- [ ] 风险已分级
- [ ] 修复建议含具体代码示例
