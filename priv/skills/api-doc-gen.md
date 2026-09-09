---
name: api-doc-gen
triggers: ["edoc", "文档生成", "doc gen", "api 文档", "spec 文档", "module doc", "函数文档"]
tools: [getSymbolSource, moduleExports, writeFile, applyPatch]
---

## 技能：API 文档生成

当用户要求从 `-spec` / edoc 生成或更新文档时，按以下流程。

### 工作流

1. **扫描模块**：`moduleExports` 获取所有导出函数。
2. **读 spec 与实现**：`getSymbolSource` 提取 `-spec` 与函数体。
3. **生成文档**：按 edoc 格式补全 `@doc` / `@spec` / `@param` / `@returns` / `@throws`。
4. **写回**：`applyPatch` 在函数上方插入 edoc 注释。
5. **可选**：`writeFile` 生成 Markdown 版 API 文档。

### edoc 注释规范

```erlang
%% @doc 简要描述（一行）。
%%
%% 详细描述（多行）。可含 Mermaid 图、代码示例。
%%
%% @param Key 参数说明
%% @param Opts 选项列表：
%%   <ul>
%%     <li>`async' - 异步执行</li>
%%     <li>`timeout' - 超时（ms）</li>
%%   </ul>
%% @returns `{ok, Result}' 成功；`{error, Reason}' 失败。
%% @throws `{badarg, Key}' 当 Key 不存在时。
%% @see another_function/2
%% @end
-spec my_function(Key :: atom(), Opts :: [atom()]) ->
    {ok, term()} | {error, term()}.
my_function(Key, Opts) ->
    ...
```

### Markdown API 文档模板

```markdown
# Module: myapp_server

简要描述模块职责。

## API

### my_function/2

```erlang
-spec my_function(Key :: atom(), Opts :: [atom()]) -> {ok, term()} | {error, term()}.
```

**描述**：简要说明。

**参数**：
- `Key` — 键
- `Opts` — 选项

**返回**：`{ok, Result}` | `{error, Reason}`

**示例**：
```erlang
{ok, Val} = myapp_server:my_function(foo, [async]).
```
```

### 检查清单

- [ ] 所有导出函数都有 `-spec`
- [ ] 所有导出函数都有 `@doc`
- [ ] `@param` 覆盖所有参数
- [ ] `@returns` 说明返回值结构
- [ ] 异常路径有 `@throws`
- [ ] 关联函数有 `@see` 交叉引用
