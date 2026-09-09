---
name: release-upgrade
triggers: ["appup", "relup", "热升级", "release upgrade", "热更新发布", "appup 脚本"]
tools: [readFile, writeFile, runMfa, getSymbolSource, moduleExports, verifyCompile]
---

## 技能：发布热升级（appup/relup）

当用户要求生成 `.appup` 或规划热升级步骤时，按以下流程。

### 工作流

1. **对比版本**：读新旧模块源码，列出变更（新增/删除/修改的函数、回调、record）。
2. **分类变更**：
   - **兼容变更**：新增导出函数、新增可选回调 → 直接 `load`
   - **破坏性变更**：删除导出、改 record 结构、改回调签名 → 需 `code_change`
   - **状态变更**：`#state{}` 字段增删 → 需 `code_change` 迁移
3. **生成 appup**：按下方模板写 `ebin/M.appup`。
4. **验证**：`verifyCompile` 新版本，确认 `code_change` 逻辑正确；可用 `runMfa` 抽查。
5. **生成 relup**（多版本路径）：手动或用 `systools:make_relup/3`。

### appup 模板

```erlang
%% ebin/myapp.appup
{"新版本号", [
    %% 升级路径：从旧版 → 新版
    {<<旧版本号>>, [
        %% 先加载依赖模块
        {load_module, myapp_server, brutal_purge, soft_purge, []},
        %% 需 code_change 的模块
        {update, myapp_server, {advanced, [{extra, upgrade_data}]}},
        %% 新增模块
        {add_module, myapp_new_mod},
        %% 删除模块
        {delete_module, myapp_old_mod}
    ]}
], [
    %% 降级路径：新版 → 旧版（逆序）
    {<<旧版本号>>, [
        {delete_module, myapp_new_mod},
        {update, myapp_server, {advanced, [{extra, downgrade_data}]}},
        {load_module, myapp_server, brutal_purge, soft_purge, []}
    ]}
]}.
```

### 变更分类速查

| 变更类型 | appup 指令 | code_change 需要 |
|---------|-----------|-----------------|
| 新增导出函数 | `{load_module, M, brutal_purge, soft_purge, []}` | 否 |
| 删除导出函数 | `{load_module, M, brutal_purge, soft_purge, []}` | 视调用方而定 |
| record 字段增删 | `{update, M, {advanced, Extra}}` | 是 |
| 回调签名变更 | `{update, M, {advanced, Extra}}` | 是 |
| 新增模块 | `{add_module, M}` | 否 |
| 删除模块 | `{delete_module, M}` | 否 |
| supervisor child_spec 变更 | `{update, Sup, supervisor}` | 否 |

### 检查清单

- [ ] 已列出所有模块变更
- [ ] 破坏性变更已标注 `code_change` 需求
- [ ] appup 含升级 + 降级双向路径
- [ ] `code_change/3` 已处理状态迁移
- [ ] 已用 `verifyCompile` 验证新版本可加载
- [ ] 降级路径已测试（至少 dry-run）
