# aliCore

Rust 数据面：代码索引、BM25/向量检索、调用图、嵌入式 SQLite、可选 Qdrant。

由 Erlang `aliCoreClient` 以 Port 拉起：

```text
aliCore --port
```

协议为 stdin/stdout `{packet, 4}` 长度前缀 JSON，详见 `src/port.rs`。

## 构建

`rebar3 compile` 会执行 `priv/scripts/build_core.*`（`cargo build --release` 并拷贝到 `priv/aliCore[.exe]`）。

单独构建：

```bash
cargo build --release --manifest-path c_src/aliCore/Cargo.toml
```

## 环境变量（示例见 `priv/aliCore.env.example`）

| 变量 | 含义 |
|------|------|
| `ALI_ROOT` | 项目根 |
| `ALI_INDEX_DIR` | Tantivy 目录，默认 `priv/index/tantivy` |
| `ALI_DB_PATH` | SQLite 路径 |
| `ALI_INDEX_EXTENSIONS` | 可索引后缀，如 `erl,hrl,cfg,rs` |
| `ALI_QDRANT_URL` | 可选向量库 |
| `ALI_EMBEDDING_*` / `ALI_RERANK_*` | 可选语义增强 |

运行时数据写在**项目根** `priv/`（`priv/index`、`priv/db`），不在本 crate 目录下。
