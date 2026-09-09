---
name: build-project-knowledge
triggers: ["建立知识库", "构建知识库", "重建知识库", "刷新知识库", "生成知识库", "build knowledge", "rebuild digest", "/digest", "projectDigest", "知识库怎么建", "首次索引", "digestOnStartup"]
tools: [indexCode, projectDigest, digestStatus, searchKnowledge, saveKnowledge, saveAction, lookupAction]
---

## 技能：从代码建立项目知识库

当用户要**首次建库 / 重建 / 刷新** `.ali/knowledge` 时按本流程执行。
目标：根据**当前工程源码、导出、表访问、注释/摘要**生成可检索知识，供后续问答与 NL→MFA 使用。
**不要把业务词写进助手源码**——一律落在目标项目的 knowledge 目录。

### 自动时机（无需用户催）

1. **首次启动**：`agent.digestOnStartup=true`（默认）且尚无 `meta.json` → 等索引就绪后自动 `projectDigest`
2. **索引完成后**：`agent.digestAfterIndex=true`（默认）→ `/index`、Web「重解析索引」、`indexCode` 成功后自动刷库
3. **文件监听**：`core.fileWatchEnabled=true` 时变更也会触发 digest

### 手动重建（指令 / 面板 / 工具）

| 入口 | 用法 |
|------|------|
| CLI | `/digest` 或 `/digest rebuild` |
| CLI 状态 | `/digest status` |
| Web 面板 | Core 状态页 →「重建知识库」 |
| HTTP | `POST /api/digest/build` · `GET /api/digest/status` |
| Agent 工具 | `projectDigest` · `digestStatus` |

推荐顺序：

1. `indexCode` 或确认索引已 ready（`indexStatus` / `/index status`）
2. `projectDigest`（或 `/digest`）
3. `digestStatus` 确认 `ready=true`
4. 抽查：`searchKnowledge` / `lookupAction`

### 产出（均在 `.ali/knowledge/`）

- `map.json` / `api.json` / `data.json` / `modules/*` — 从代码与符号索引生成
- `actions.json` — NL→MFA 种子；不准时用 `saveAction` 纠正（manual 优先）
- `agent.json` — 活数据关键词软合并（表名/动作短语）；可手改，不写回助手代码
- `summaries/*.md` — 对话核实后用 `saveKnowledge` 沉淀

### 配置开关

- `digestOnStartup`（默认 true）：缺库时启动自动建
- `digestRefreshOnStartup`（默认 false）：每次启动都强制刷新
- `digestAfterIndex`（默认 true）：索引成功后刷新
- `digestWaitIndexMs`：启动建库前等索引的上限（默认 600000）

### 回答用户时

- 说明会扫代码根（`agent.projectRoot` / `codeRoots`），不是空库瞎编
- 建完给出路径与 `moduleCount` / `actionCount` 等摘要
- 若索引未完成：先等索引，再 digest；不要只建空壳

### 禁止

- 禁止编造 MFA / 表名写入 actions
- 禁止把未核实猜测 `saveKnowledge`
- 禁止把某项目专有名词写进通用 skill / 源码硬编码
