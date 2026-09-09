---
name: project-digest
triggers: ["知识库", "项目摘要", "project digest", "/digest", "digest", "动作词典", "模块地图", "saveKnowledge", "saveAction", "主题知识", "agent.json"]
tools: [projectDigest, digestStatus, searchKnowledge, saveKnowledge, saveAction, lookupAction, indexCode, searchCode, traceDataQuery]
---

## 技能：项目知识库（Project Digest）

大型目标项目应先构建分层知识库，再做深度问答 / NL 查改。
**业务专有名词不要写进助手源码**——由本流水线维护在 `.ali/knowledge/`。

### 自动化流水线

```text
/index 或 indexCode 或 fileWatch
        │
        ▼
  索引就绪 (ready)
        │  agent.digestAfterIndex=true（默认）
        ▼
  projectDigest:build
        ├─ map / api / data / modules
        ├─ actions.json（种子 + 手工优先合并；剔除 stale auto）
        ├─ agent.json（从表名/动作短语软合并 liveData*Keywords）
        └─ seedExperience → alExperience lesson（预学习；同主题变了则纠错废旧立新）
        │
        ▼
  增量 vcsIndex / indexCode
        ├─ reconcileAfterCodeChange：删除模块相关 lesson 废止
        └─ digest 重建 → 增/替种子经验
        │
        ▼
  问答检索：searchKnowledge / lookupAction / experience 召回
        │
        ▼
  核实后纠错 / 对话沉淀：
        ├─ /save-knowledge 或 saveKnowledge → summaries/
        ├─ /save-action 或 saveAction → actions.json（manual）
        ├─ 失败/用户纠正 → lesson；成功轮启发式 extractFromTurn
        └─ autoDistillMemories → 长期记忆事实
```

### 何时构建

1. **首次启动自动**：`digestOnStartup=true` 且尚无 knowledge → 等索引后自动建（见技能 `build-project-knowledge`）
2. **索引后自动**：`digestAfterIndex=true`（`/index`、Web 重解析、`indexCode`）
3. **手动**：`/digest` · `/digest rebuild` · Web「重建知识库」· `POST /api/digest/build`
4. 开启 `core.fileWatchEnabled` 时，文件变更也会触发 digest 刷新

详细建库流程以技能 **build-project-knowledge** 为准；本技能偏重「用库 / 纠错」。

### 产出位置

`.ali/knowledge/`：

| 文件 | 来源 | 说明 |
|------|------|------|
| `map.json` / `api.json` / `data.json` | 自动 | 模块图、导出、表↔MFA |
| `actions.json` | 自动种子 + 手工 | NL→MFA；`saveAction` 标 manual |
| `modules/*.json` | 自动 | 模块短摘要 |
| `summaries/*.md` | 对话沉淀 | `saveKnowledge` |
| `agent.json` | 自动软合并 + 可手改 | 活数据关键词；**永不**写回助手源码 |

### 使用

- 问答时优先看 `retrieved_context.knowledge` / `suggestedActions`
- 业务短语用 `lookupAction`；没有命中再 `searchKnowledge` / `traceDataQuery`
- 种子不准：`/save-action 查订单状态 order_db:lookup/1`
- 结论沉淀：`/save-knowledge order-status …`
- 示例模板：`priv/examples/knowledge/agent.json.example`（按目标域改词，勿照搬）

### 配置

- `agent.digestAfterIndex`（默认 `true`）：索引成功后异步刷新 knowledge
- `projectDigest` 参数：`updateAgentHints` / `pruneStaleActions` / `seedExperience`（默认均 true）
- `agent.autoExtractTurnKnowledge`（默认 `true`）：每轮成功问答提取 MFA/结论 → lesson
- `agent.autoDistillMemories`（建议 `true`）：每轮异步提炼事实到长期记忆
- `agent.experienceEnabled` / `autoRecordLessons`：经验层总开关与失败自动记

### 禁止

- 不要把整仓灌成一篇长文塞进 prompt
- 不要仅凭 digest 猜测就 `runMfa` 写数据；先验证 MFA
- 不要把未验证猜测写入 `saveKnowledge`
- 不要把某项目业务词写死进通用助手代码 / skill triggers
