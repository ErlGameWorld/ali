---
name: hot-code-reload
triggers: ["热加载", "hot reload", "code:load", "compileLoad", "热更新", "hotReload"]
tools: [verifyCompile, hotReload, moduleExports, getSymbolSource, rollbackPatch, applyPatch]
---

## 技能：安全热加载流程

当用户要求热加载代码时，**优先用 `hotReload` 工具**（内置 soft_purge / load_file / export diff / smoke），不要用裸 `runMfa` 调 `code:purge` / `code:load_file`。

### 工作流

1. **预检**：`moduleExports` 确认目标模块；必要时 `getSymbolSource` 核对关键函数。
2. **编译**：`verifyCompile`（或 `applyPatch` 后再编译）。失败则停止，不要 load 旧 beam。
3. **热加载**：`hotReload`，参数 `{"module":"..."}`。
   - 默认 `soft_purge`；若返回 `softPurgeDenied`，说明旧代码仍被进程占用——先评估，再决定是否 `force=true`（硬 purge，可能杀进程）。
   - 查看返回的 `exportDiff` / `warnings`（回调签名变更需特别提示）。
4. **验证**：工具已默认 smoke `module_info`；需要时可传 `smoke: "ping/0"`（仅 arity 0 导出）。
5. **回滚**：若验证失败，用 `rollbackPatch` 恢复源码后再 `verifyCompile` + `hotReload`。
6. **报告**：`模块 → beam 路径 → md5 → exportDiff → smoke → warnings`。

### 注意

- 永远不要在 `code:purge` 后跳过 `load_file`；`hotReload` 已保证顺序。
- `gen_server` 的 `handle_call/cast/info` 签名变更时，提示「运行中进程状态可能不兼容」。
- supervisor `init` 改动需重启 supervisor，单纯热加载无效。
