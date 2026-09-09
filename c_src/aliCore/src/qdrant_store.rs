//! Qdrant 向量库客户端封装。
//!
//! # 两个 collection
//! - `ali_function_chunks`：代码 chunk 向量（索引阶段 upsert，搜索阶段 query）
//! - `ali_memories`：长期记忆向量（`memory_upsert` / `memory_search`）
//!
//! # 连接
//! URL 来自环境变量 `ALI_QDRANT_URL`（由 Erlang `alConfig:core_port_env/0` 注入）。
//! 未配置时走本地 `embeddings.json`，本模块不会被调用。
//!
//! # 生命周期
//! Qdrant 进程可由 Erlang `aliQdrant` 用 Port 托管，或连接外部实例。
//!
//! # 韧性
//! 连接与请求均设超时；读路径带有限次退避重试。熔断由调用方 `qdrant_client` 维护。

use std::collections::HashMap;
use std::future::Future;
use std::time::Duration;

use anyhow::{Context, Result};
use qdrant_client::qdrant::{
    vectors_config::Config as VectorsConfigKind, CountPointsBuilder, CreateCollectionBuilder,
    DeletePointsBuilder, Distance, PointStruct, PointsIdsList, QueryPointsBuilder,
    UpsertPointsBuilder, VectorParamsBuilder,
};
use qdrant_client::{Payload, Qdrant};
use serde_json::json;
use tracing::info;

use crate::FunctionChunk;

/// 代码函数/文本 chunk 的 collection 名。
pub const COLLECTION: &str = "ali_function_chunks";
/// 语义记忆的 collection 名。
pub const MEMORY_COLLECTION: &str = "ali_memories";

const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);

/// 对单个 Qdrant 实例的薄封装。
///
/// `Clone` 派生允许从共享缓存中复用已建立的 gRPC 通道，
/// 避免每次请求重建连接。
#[derive(Clone)]
pub struct QdrantStore {
    client: Qdrant,
}

impl QdrantStore {
    /// 连接 `url`（如 `http://127.0.0.1:6334`，gRPC 端口由 qdrant-client 使用）。
    pub async fn connect(url: &str) -> Result<Self> {
        let client = Qdrant::from_url(url)
            .timeout(REQUEST_TIMEOUT)
            .connect_timeout(CONNECT_TIMEOUT)
            .build()
            .context("failed to connect qdrant")?;
        // 主动探活：强制在连接超时内完成首次 RPC，避免懒连接拖到搜索路径。
        let probe = client.list_collections();
        with_timeout(probe)
            .await
            .context("qdrant connect probe failed")?;
        Ok(Self { client })
    }

    /// 确保代码 chunk collection 存在且维度匹配；维度不一致则报错（需手工清库）。
    pub async fn ensure_collection(&self, vector_size: u64) -> Result<()> {
        if with_timeout(self.client.collection_exists(COLLECTION))
            .await
            .context("failed to check qdrant collection")?
        {
            let info = with_timeout(self.client.collection_info(COLLECTION))
                .await
                .context("failed to read qdrant collection info")?;
            let existing = info
                .result
                .as_ref()
                .and_then(|details| details.config.as_ref())
                .and_then(|config| config.params.as_ref())
                .and_then(|params| params.vectors_config.as_ref())
                .and_then(|vectors| vectors.config.as_ref())
                .and_then(|config| match config {
                    VectorsConfigKind::Params(params) => Some(params.size),
                    VectorsConfigKind::ParamsMap(map) => map.map.values().next().map(|params| params.size),
                });
            if let Some(existing_size) = existing {
                anyhow::ensure!(
                    existing_size == vector_size,
                    "qdrant collection {COLLECTION} dimension mismatch: expected {vector_size}, got {existing_size}"
                );
            }
            return Ok(());
        }

        with_timeout(
            self.client.create_collection(
                CreateCollectionBuilder::new(COLLECTION).vectors_config(VectorParamsBuilder::new(
                    vector_size,
                    Distance::Cosine,
                )),
            ),
        )
        .await
        .context("failed to create qdrant collection")?;
        info!("created qdrant collection {COLLECTION} with dim {vector_size}");
        Ok(())
    }

    /// 按 chunk_id 删除 Qdrant 中的代码向量点；空列表直接返回 0。
    pub async fn delete_chunks(&self, chunk_ids: &[String]) -> Result<usize> {
        if chunk_ids.is_empty() {
            return Ok(0);
        }
        let ids: Vec<_> = chunk_ids
            .iter()
            .map(|chunk_id| stable_point_id(chunk_id).into())
            .collect();
        with_timeout(
            self.client.delete_points(
                DeletePointsBuilder::new(COLLECTION)
                    .points(PointsIdsList { ids })
                    .wait(true),
            ),
        )
        .await
        .context("failed to delete qdrant points")?;
        Ok(chunk_ids.len())
    }

    /// 批量 upsert 代码 chunk 向量及 payload（文件、模块、函数、行号等）。
    pub async fn upsert_chunks(
        &self,
        chunks: &[FunctionChunk],
        vectors: &HashMap<String, Vec<f32>>,
    ) -> Result<usize> {
        if vectors.is_empty() {
            return Ok(0);
        }

        let vector_size = vectors
            .values()
            .next()
            .map(|vector| vector.len() as u64)
            .unwrap_or(0);
        if vector_size == 0 {
            return Ok(0);
        }

        self.ensure_collection(vector_size).await?;

        let mut points = Vec::new();
        for chunk in chunks {
            let Some(vector) = vectors.get(&chunk.id) else {
                continue;
            };
            let payload: Payload = json!({
                "chunk_id": chunk.id,
                "file": chunk.file,
                "module": chunk.module,
                "function": chunk.function,
                "arity": chunk.arity,
                "start_line": chunk.start_line,
                "end_line": chunk.end_line,
                "hash": chunk.hash,
            })
            .try_into()
            .context("failed to build qdrant payload")?;
            points.push(PointStruct::new(stable_point_id(&chunk.id), vector.clone(), payload));
        }

        if points.is_empty() {
            return Ok(0);
        }

        // P2-5：返回实际 push 的点数，而非传入 vectors 的全量大小。
        let pushed = points.len();
        with_timeout(
            self.client
                .upsert_points_chunked(UpsertPointsBuilder::new(COLLECTION, points).wait(true), 64),
        )
        .await
        .context("failed to upsert qdrant points")?;
        Ok(pushed)
    }

    /// 仅 upsert 内容哈希发生变化的 chunk，减少无效写入。
    pub async fn upsert_changed_chunks(
        &self,
        chunks: &[FunctionChunk],
        vectors: &HashMap<String, Vec<f32>>,
        previous_hashes: &HashMap<String, String>,
    ) -> Result<usize> {
        let changed: Vec<FunctionChunk> = chunks
            .iter()
            .filter(|chunk| {
                vectors.contains_key(&chunk.id)
                    && previous_hashes.get(&chunk.id) != Some(&chunk.hash)
            })
            .cloned()
            .collect();
        if changed.is_empty() {
            return Ok(0);
        }
        let changed_vectors: HashMap<String, Vec<f32>> = changed
            .iter()
            .filter_map(|chunk| vectors.get(&chunk.id).map(|vector| (chunk.id.clone(), vector.clone())))
            .collect();
        self.upsert_chunks(&changed, &changed_vectors).await
    }

    /// 在代码 collection 中做向量近邻搜索，返回 `(chunk_id, score)`。
    pub async fn search(&self, query_vector: &[f32], limit: usize) -> Result<Vec<(String, f32)>> {
        let response = with_retry(|| {
            with_timeout(
                self.client.query(
                    QueryPointsBuilder::new(COLLECTION)
                        .query(query_vector.to_vec())
                        .limit(limit.max(1) as u64)
                        .with_payload(true),
                ),
            )
        })
        .await
        .context("failed to query qdrant")?;

        let mut hits = Vec::new();
        for point in response.result {
            let chunk_id = point
                .payload
                .get("chunk_id")
                .and_then(|value| value.as_str().map(|s| s.clone()))
                .unwrap_or_else(|| format!("{:?}", point.id));
            hits.push((chunk_id, point.score));
        }
        Ok(hits)
    }

    /// 确保语义记忆 collection 存在；已存在则跳过。
    pub async fn ensure_memory_collection(&self, vector_size: u64) -> Result<()> {
        if with_timeout(self.client.collection_exists(MEMORY_COLLECTION))
            .await
            .context("failed to check qdrant memory collection")?
        {
            return Ok(());
        }
        with_timeout(
            self.client.create_collection(
                CreateCollectionBuilder::new(MEMORY_COLLECTION).vectors_config(
                    VectorParamsBuilder::new(vector_size, Distance::Cosine),
                ),
            ),
        )
        .await
        .context("failed to create qdrant memory collection")?;
        info!("created qdrant collection {MEMORY_COLLECTION} with dim {vector_size}");
        Ok(())
    }

    /// 写入或更新一条语义记忆（id、content、向量及可选 session/kind）。
    pub async fn upsert_memory(
        &self,
        id: i64,
        content: &str,
        vector: &[f32],
        session_id: Option<i64>,
        kind: Option<&str>,
    ) -> Result<()> {
        let payload: Payload = json!({
            "id": id,
            "content": content,
            "session_id": session_id,
            "kind": kind,
            "updated_at": std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs(),
        })
        .try_into()
        .context("failed to build memory payload")?;
        let point_id = stable_point_id(&id.to_string());
        with_timeout(
            self.client.upsert_points(
                UpsertPointsBuilder::new(MEMORY_COLLECTION, vec![
                    PointStruct::new(point_id, vector.to_vec(), payload),
                ])
                .wait(true),
            ),
        )
        .await
        .context("failed to upsert memory point")?;
        Ok(())
    }

    /// 按记忆 id 删除 Qdrant 中的对应点。
    pub async fn delete_memory(&self, id: i64) -> Result<()> {
        let point_id = stable_point_id(&id.to_string());
        with_timeout(
            self.client.delete_points(
                DeletePointsBuilder::new(MEMORY_COLLECTION)
                    .points(PointsIdsList {
                        ids: vec![point_id.into()],
                    })
                    .wait(true),
            ),
        )
        .await
        .context("failed to delete memory point")?;
        Ok(())
    }

    /// 统计记忆 collection 中的向量点数；collection 不存在时返回 0。
    ///
    /// 供 `/health` 在 Qdrant 模式下汇报真实记忆数量，而非恒为本地库的 0。
    pub async fn count_memories(&self) -> Result<usize> {
        if !with_timeout(self.client.collection_exists(MEMORY_COLLECTION))
            .await
            .context("failed to check qdrant memory collection")?
        {
            return Ok(0);
        }
        let response = with_retry(|| {
            with_timeout(
                self.client
                    .count(CountPointsBuilder::new(MEMORY_COLLECTION).exact(false)),
            )
        })
        .await
        .context("failed to count qdrant memory points")?;
        Ok(response.result.map(|result| result.count as usize).unwrap_or(0))
    }

    /// 在记忆 collection 中做向量检索，返回带 payload 的命中列表。
    pub async fn search_memories(
        &self,
        query_vector: &[f32],
        limit: usize,
    ) -> Result<Vec<MemoryQdrantHit>> {
        let response = with_retry(|| {
            with_timeout(
                self.client.query(
                    QueryPointsBuilder::new(MEMORY_COLLECTION)
                        .query(query_vector.to_vec())
                        .limit(limit.max(1) as u64)
                        .with_payload(true),
                ),
            )
        })
        .await
        .context("failed to query qdrant memory")?;

        response
            .result
            .into_iter()
            .map(|point| {
                let id = point
                    .payload
                    .get("id")
                    .and_then(|v| v.kind.as_ref())
                    .and_then(|k| match k {
                        qdrant_client::qdrant::value::Kind::IntegerValue(i) => Some(*i),
                        _ => None,
                    })
                    .unwrap_or(0);
                let content = point
                    .payload
                    .get("content")
                    .and_then(|v| v.as_str().map(|s| s.to_string()))
                    .unwrap_or_default();
                let session_id = point
                    .payload
                    .get("session_id")
                    .and_then(|v| v.kind.as_ref())
                    .and_then(|k| match k {
                        qdrant_client::qdrant::value::Kind::IntegerValue(i) => Some(*i),
                        _ => None,
                    });
                let kind = point
                    .payload
                    .get("kind")
                    .and_then(|v| v.as_str().map(|s| s.to_string()));
                Ok(MemoryQdrantHit {
                    id,
                    content,
                    session_id,
                    kind,
                    score: point.score,
                })
            })
            .collect()
    }
}

async fn with_timeout<T, E>(
    fut: impl Future<Output = std::result::Result<T, E>>,
) -> Result<T>
where
    E: Into<anyhow::Error>,
{
    match tokio::time::timeout(REQUEST_TIMEOUT, fut).await {
        Ok(Ok(v)) => Ok(v),
        Ok(Err(err)) => Err(err.into()),
        Err(_) => Err(anyhow::anyhow!("qdrant request timed out after {REQUEST_TIMEOUT:?}")),
    }
}

/// 读路径最多 2 次重试（共 3 次尝试），指数退避 50ms / 100ms。
async fn with_retry<T, Fut, F>(mut make: F) -> Result<T>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<T>>,
{
    let mut attempt = 0u32;
    loop {
        match make().await {
            Ok(v) => return Ok(v),
            Err(err) if attempt < 2 => {
                attempt += 1;
                let delay = Duration::from_millis(50u64 << (attempt - 1));
                tracing::warn!("qdrant retry {attempt}/2 after {delay:?}: {err:#}");
                tokio::time::sleep(delay).await;
            }
            Err(err) => return Err(err),
        }
    }
}

/// Stable FNV-1a point id (must not use DefaultHasher — not cross-version stable).
fn stable_point_id(chunk_id: &str) -> u64 {
    let mut hash: u64 = 0xcbf29ce484222325;
    for b in chunk_id.as_bytes() {
        hash ^= u64::from(*b);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

/// Qdrant 记忆检索单条结果（含内容与元数据）。
#[derive(Debug, Clone, serde::Serialize)]
pub struct MemoryQdrantHit {
    pub id: i64,
    pub content: String,
    pub session_id: Option<i64>,
    pub kind: Option<String>,
    pub score: f32,
}
