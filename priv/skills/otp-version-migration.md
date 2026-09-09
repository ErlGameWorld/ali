---
name: otp-version-migration
triggers: ["OTP 升级", "OTP 迁移", "版本迁移", "version migration", "OTP 27", "OTP 28", "erl_tidy 移除", "json 模块", "http 模块"]
tools: [searchText, applyPatch, runEunit, getSymbolSource, verifyCompile]
---

## 技能：OTP 跨版本迁移

当用户要求升级 OTP 版本时，按以下流程识别并修复 breaking changes。

### 工作流

1. **确认目标版本**：明确从 X 升到 Y。
2. **扫描 breaking changes**：`searchText` 搜索已知废弃/移除的 API。
3. **逐项修复**：`applyPatch` 替换为新 API（可用 `getSymbolSource` 读上下文）。
4. **测试**：`runEunit` 确认无回归；`verifyCompile` 确认无新警告。
5. **给结论**：迁移清单 + 风险点。

### 常见迁移项

#### OTP 26 → 27

| 废弃/移除 | 替代 | 搜索关键词 |
|----------|------|-----------|
| `erl_tidy` 模块 | 外部工具 `erlfmt` / `styler` | `erl_tidy:` |
| `erl_scan:tokens/3` 旧签名 | `erl_scan:tokens/4` | `erl_scan:tokens` |
| `http` 相关（非 `inets`） | `inets` / 第三方 | `http:` |

#### OTP 27 → 28

| 废弃/移除 | 替代 | 搜索关键词 |
|----------|------|-----------|
| 旧 `random` 模块残留 | `rand` | `random:` |
| `erlang:phash2` 旧用法 | 保持不变（兼容） | — |
| 内置 `json` 模块 | 直接用 `json:encode/1` | 第三方 `jiffy`/`jsx` 可替换 |

#### 通用迁移项

| 场景 | 检查 |
|------|------|
| `-ifdef(OTP_RELEASE)` | 升级后可能需调整版本判断 |
| `application:get_env` | 推荐改 `kernel` 配置或 `persistent_term` |
| `crypto` 算法 | 新版可能移除弱算法（MD4/DES） |
| `ssl` 选项 | 新版默认更严格（`verify` / `versions`） |

### 迁移检查清单

- [ ] 已确认源版本与目标版本
- [ ] 已搜索所有已知 breaking changes 关键词
- [ ] 每项废弃 API 已替换为替代方案
- [ ] `runEunit` 全绿
- [ ] `verifyCompile` 无新警告
- [ ] 已检查 `rebar.config` 的 `{minimum_otp_vsn, _}`
