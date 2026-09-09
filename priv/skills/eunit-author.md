---
name: eunit-author
triggers: ["写测试", "eunit", "test", "测试用例", "补测试"]
tools: [getSymbolSource, writeFile, applyPatch, runEunit]
---

## 技能：编写高质量 EUnit 测试

当用户要求为某模块补测试时，按以下流程：

### 工作流

1. **分析被测代码**：用 `getSymbolSource` 读取目标模块，识别：
   - 所有导出函数及其分支
   - 边界条件（空列表、0、负数、超大输入）
   - 错误路径（`{error, _}` 返回）
   - 并发场景（若涉及 gen_server / ETS）

2. **设计用例清单**：先列出计划编写的用例（正常/边界/错误/并发），让用户确认范围。

3. **编写测试**：
   - 文件放 `test/` 目录，命名 `<module>_test.erl`，`-module(<module>_test)`，`-include_lib("eunit/include/eunit.hrl")`。
   - 用 `writeFile` 新建测试文件；若是在已有文件上增量修改，用 `applyPatch`。
   - 用 `?assertEqual`、`?assertMatch`、`?assertError`、`?assertThrow` 系列。
   - 每个用例独立，不依赖执行顺序。
   - 有状态的模块用 `setup`/`cleanup` fixture。

4. **运行验证**：用 `runEunit` 跑测试，失败则：
   - 读失败原因，判断是测试错还是被测代码 bug。
   - 修复后重跑，最多 2 轮，仍失败则报告问题让用户决策。

5. **报告**：用例清单 + 运行结果（通过数/失败数）+ 覆盖的分支说明。

### 注意

- 不要为 trivial 的 getter/setter 写测试，优先覆盖有逻辑的函数。
- 不要 mock 到失去意义——优先测真实行为，必要时用 `meck` 但需说明。
- 并发测试用 `?assertMatch` + 超时，避免死锁。
