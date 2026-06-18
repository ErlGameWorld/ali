# 架构说明

## 总览

```
使用者 / Web UI
      │
      ▼
   ali (Facade)
      │
      ├── ali_app → llmCliConfig:load
      ├── ali_sup → alCodeIndexer, alServer
      ├── alServer → alLoop ↔ alTools → alTool*
      ├── llmCli (HTTP)
      └── alWebSrv → alWebHer
```

## OTP 结构

| 模块 | 职责 |
|------|------|
| `ali_app` | 应用回调：加载配置、启动监督者、可选 Web |
| `ali_sup` | 监督 `alCodeIndexer`、`alServer` |
| `alCodeIndexer` | 代码索引 gen_server |
| `alServer` | Agent 会话与配置 gen_server |
| `alWebSrv` | HTTP 服务（按需启动） |

## 目录与模块

```
src/
├── ali.erl, ali_app.erl, ali_sup.erl
├── agent/          # alServer, alLoop, alTools, alPolicy, ...
├── tools/          # alToolProject, alToolAnalyze, alToolEdit, ...
├── analysis/       # alCodeIndexer, alAst
├── core/           # llmCli, llmCliConfig, llmJson（见 LLM.md）
└── web/            # alWebHer, alWebSrv
```

## ask 数据流

1. `ali:ask` → `alServer`
2. `alContext:buildMessages` 组装消息
3. `alLoop:run` 循环：LLM → tool_calls → `alTools:execute`
4. 更新会话，返回 `{ok, Answer}`

## 本地数据（`.al/`）

| 路径 | 内容 |
|------|------|
| `sessions/` | 会话 JSON |
| `backups/` | 编辑备份 |
| `audit.jsonl` | 审计日志 |
| `index.dets` | 代码索引 |

## 相关文档

- [LLM.md](LLM.md) — `llmCli` 直连 API 详解
- [API.md](API.md) — `ali` Facade API

## 扩展新工具

1. 在 `alTool*.erl` 实现函数
2. 在 `alTools:allTools/0` 注册
3. 在 `alPolicy:level/1` 设权限级别
