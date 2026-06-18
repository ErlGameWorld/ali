# ali 项目文档

本目录包含 ali OTP 应用的设计与使用文档。

## 文档索引

| 文档 | 受众 | 内容 |
|------|------|------|
| [API.md](API.md) | 使用者 | `ali` 模块全部对外 API |
| [LLM.md](LLM.md) | 使用者 | LLM 直连 API（`llmCli` / `ali:llm*`） |
| [CONFIG.md](CONFIG.md) | 运维/开发者 | `config.cfg` 与环境变量 |
| [ARCHITECTURE.md](ARCHITECTURE.md) | 开发者 | 模块划分、OTP 结构、数据流 |
| [TOOLS.md](TOOLS.md) | 使用者/Agent | 工具列表与权限级别 |
| [AGENT_DEVELOPMENT_PLAN.md](AGENT_DEVELOPMENT_PLAN.md) | 维护者 | 产品定位、阶段规划、实现进度 |

## 快速链接

- 项目 README：[../../README.md](../../README.md)
- 配置示例：[../../config/config.example.cfg](../../config/config.example.cfg)
- 对外 API 源码：[../../src/ali.erl](../../src/ali.erl)

## 使用约定

- **对外调用**：优先使用 `ali:*`；直连 LLM 见 [LLM.md](LLM.md)
- **配置**：写入 `config.cfg` 或通过 `ali:setConfig/2`、`ali:setLlmConfig/2` 运行时修改。
- **数据目录**：`.al/` 位于 `projectRoot` 下，可纳入 `.gitignore`。
