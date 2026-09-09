# 本地语义检索：Embedding 与 Rerank

## 为什么需要单独配置？

**DeepSeek（以及多数纯对话 LLM）只提供 `/v1/chat/completions`，不提供 embedding / rerank 接口。**

因此即使用 `llm.chain` 配好了 DeepSeek 做聊天，`{embedding, ...}` 与 `{rerank, ...}` **不能**指望 `apiKey => inherit` 自动生效——必须另配一个 **OpenAI 兼容的 HTTP 服务**（本地 llama.cpp 或硅基流动等）。

| 能力 | ali 里谁负责 | 不配 embedding 时 |
|------|--------------|-------------------|
| **BM25 / 关键词** | aliCore（Tantivy）+ `alMemory` SQL | ✅ 默认就有 |
| **向量 / 语义** | aliCore → `/v1/embeddings` | 降级为纯 BM25 |
| **Rerank 精排** | aliCore → `/v1/rerank`（Cohere 兼容） | 跳过，用 hybrid 原始分 |

代码搜索默认 **hybrid**（BM25 + 向量）；embedding 未配置或失败时 **自动降级 BM25**，不会拖垮主流程。

---

## 推荐模型（llama.cpp + GGUF）

同一 `.gguf` 文件 **Windows / Linux 通用**，只需各平台下载对应的 `llama-server` 可执行文件。

### Qwen3 系列（中文 + 多语，质量优先）

| 用途 | Hugging Face | 参数量 | 说明 |
|------|--------------|--------|------|
| Embedding | [Qwen/Qwen3-Embedding-4B-GGUF](https://huggingface.co/Qwen/Qwen3-Embedding-4B-GGUF) | 4B | 官方 GGUF；CPU 建议 `q4_K_M` / `q5_K_M` |
| Embedding（更强） | [Qwen/Qwen3-Embedding-8B-GGUF](https://huggingface.co/Qwen/Qwen3-Embedding-8B-GGUF) | 8B | 更准，内存/算力更高 |
| Reranker | [Voodisss/Qwen3-Reranker-4B-GGUF-llama_cpp](https://huggingface.co/Voodisss/Qwen3-Reranker-4B-GGUF-llama_cpp) | 4B | **须用官方脚本转换的 GGUF**，见下方警告 |
| Reranker（更轻） | [Voodisss/Qwen3-Reranker-0.6B-GGUF-llama_cpp](https://huggingface.co/Voodisss/Qwen3-Reranker-0.6B-GGUF-llama_cpp) | 0.6B | 低配 CPU 可选 |

> **Reranker 警告：** 部分社区转换的 Qwen3-Reranker GGUF 缺少 `cls.output.weight` 等张量，会出现 relevance 分数接近 `0` 或 `4e-23` 的假象。请使用上表 Voodisss 集合（官方 `convert_hf_to_gguf.py` 转换），或自行用 llama.cpp 主仓脚本转换。详见 [llama.cpp #16407](https://github.com/ggml-org/llama.cpp/issues/16407)。

### 轻量备选（纯 CPU、内存紧）

| 用途 | 模型 | 体积（Q4 量级） |
|------|------|-----------------|
| Embedding | [groonga/bge-m3-Q4_K_M-GGUF](https://huggingface.co/groonga/bge-m3-Q4_K_M-GGUF) | ~440 MB |
| Reranker | `bge-reranker-v2-m3` Q4 GGUF | ~420 MB |

---

## 获取 llama-server

Release：[ggml-org/llama.cpp/releases](https://github.com/ggml-org/llama.cpp/releases)

| 平台 | 包 |
|------|-----|
| Windows x64 CPU | `llama-bxxxx-bin-win-cpu-x64.zip` → `llama-server.exe` |
| Linux x64 CPU | `llama-bxxxx-bin-ubuntu-x64.tar.gz` → `llama-server` |

解压后 **只需 `llama-server`**；CUDA 版另需同版本 `cudart-*.zip` 中的 DLL。

---

## 部署方式

### 方案 A：单端口 Router（一个 llama-server，多个 GGUF）

适合：希望 embedding + rerank 共用一个端口；聊天模型可继续单独跑在 8080（如 Ornith + DeepSeek 链）。

1. 下载 Embedding / Reranker 的 GGUF 到同一目录，例如 `models/`。
2. 编写 `models.ini`（节名 = API 里的 `"model"` 字段）：

```ini
[*]
batch-size = 2048
ubatch-size = 512

[Qwen3-Embedding-4B]
model = /path/to/qwen3-embedding-4b-q4_k_m.gguf
embedding = true
pooling = last
ctx-size = 8192

[Qwen3-Reranker-4B]
model = /path/to/Qwen3-Reranker-4B-f16.gguf
reranking = true
pooling = rank
embedding = true
ctx-size = 8192
```

> Qwen3-Embedding 官方示例使用 `--pooling last`（见 [Qwen3-Embedding-4B-GGUF](https://huggingface.co/Qwen/Qwen3-Embedding-4B-GGUF)）。bge 系一般用 `mean`。

3. 启动：

```bash
# Linux
./llama-server --host 127.0.0.1 --port 8081 \
  --models-preset models.ini --models-max 2

# Windows
llama-server.exe --host 127.0.0.1 --port 8081 ^
  --models-preset models.ini --models-max 2
```

`--models-max 2` 允许 embedding + reranker 同时驻留（两个小模型约 1～2GB 量级，视量化而定）。内存紧张改为 `1`，按需换模型（有加载延迟）。

4. 冒烟测试：

```bash
curl http://127.0.0.1:8081/v1/embeddings -H "Content-Type: application/json" \
  -d '{"model":"Qwen3-Embedding-4B","input":["监督树 gen_server"]}'

curl http://127.0.0.1:8081/v1/rerank -H "Content-Type: application/json" \
  -d '{"model":"Qwen3-Reranker-4B","query":"supervision","documents":["gen_server behaviour","weather report"],"top_n":2}'
```

Rerank **必须**走 `/v1/rerank`，不要对 reranker 模型调 `/v1/embeddings`。

### 方案 B：两个独立进程（推荐 CPU + 大 chat 模型）

```text
8080  llama-server -m Ornith-9B.gguf          → llm.chain 聊天
8081  llama-server --models-preset models.ini  → embedding + rerank
```

聊天 9B 与小模型分离，避免 Router 与大模型抢内存。

### 方案 C：三条命令、三个端口（最简单理解）

```bash
llama-server -m chat.gguf --port 8080
llama-server -m qwen3-embed-q4.gguf --embeddings --pooling last --port 8081
llama-server -m Qwen3-Reranker-4B.gguf --embeddings --pooling rank --reranking --port 8082
```

ali 里把 `embedding.baseUrl` 指 8081，`rerank.baseUrl` 指 8082。

---

## 在 ali 中开启

编辑 `config/aliCfg.cfg`（可参考 `config/aliCfg.cfg.example`）：

```erlang
{embedding, #{
  enabled => true,
  %% DeepSeek 无 embedding；本地 llama 填非空占位即可
  apiKey => <<"local">>,
  baseUrl => "http://127.0.0.1:8081/v1/embeddings",
  model => "Qwen3-Embedding-4B"
}},
{rerank, #{
  enabled => true,
  apiKey => <<"local">>,
  baseUrl => "http://127.0.0.1:8081/v1/rerank",
  model => "Qwen3-Reranker-4B"
}},
{qdrant, #{
  enabled => false   %% 中小仓库可不启；向量默认存 .ali/index/embeddings.json
}},
```

**四项齐才启用：** `enabled => true` + 非空 `baseUrl` + 非空 `apiKey` + 非空 `model`。`apiKey => inherit` 仅在云端 embedding 与 llm 共用 key 时有效。

重启 ali 后：

1. 确认 core health 中 `embedding_configured => true`（Web `/api/health` 或 shell 日志）。
2. **重建代码索引**（否则旧 chunk 没有向量）：
   ```erlang
   ali:index(".").
   %% 或等待 indexBackground / digestAfterIndex 自动跑完
   ```
3. 长期记忆语义召回在 memory upsert 时自动 embed；也可 `ali:rebuildMemoryIndex/0`。

---

## 资源参考（Q4 量化、CPU）

| 模型 | 大致内存 | 何时占用 CPU |
|------|----------|--------------|
| Qwen3-Embedding-4B Q4 | ~2～3 GB | 索引 embed 批量 + 每次搜索 query embed |
| Qwen3-Embedding-8B Q4 | ~4～5 GB | 同上，更强 |
| Qwen3-Reranker-4B Q4 | ~2～3 GB | 仅搜索后对 Top 候选重排 |
| bge-m3 / bge-reranker-v2-m3 Q4 | 各 ~0.5 GB | 同上，更省 |

Reranker **不是常驻满负荷**；仓库不大时可先只开 embedding，rerank 后加。

---

## 延伸阅读

- [llama.cpp server 文档](https://github.com/ggml-org/llama.cpp/tree/master/tools/server)
- [Qwen3 Embedding 官方说明](https://huggingface.co/Qwen/Qwen3-Embedding-4B-GGUF)
- [Qwen3 Router 多模型 gist（含 models.ini 全字段）](https://gist.github.com/VooDisss/42bce4eb5c76d3c325633886c5e348ee)
- ali 配置示例：`config/aliCfg.cfg.example` 中 `{embedding,...}` / `{rerank,...}`
