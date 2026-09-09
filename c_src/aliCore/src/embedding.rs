//! 本地向量存储与远程 Embedding API。
//!
//! # 职责
//! - 调用 OpenAI 兼容的 `/v1/embeddings`（或其它兼容端点）
//! - 将 chunk_id → 向量 持久化到 `priv/index/embeddings.json`（相对 `ALI_ROOT`）
//! - 提供余弦相似度 Top-K 检索
//! - 查询文本 → 向量 的 LRU 缓存，避免对相同查询重复调用 API
//!
//! # 配置（环境变量）
//! - `ALI_EMBEDDING_API_KEY`（必须由 Erlang 配置显式注入；不回退 LLM key）
//! - `ALI_EMBEDDING_BASE_URL`（必须显式配置，无默认 OpenAI）
//! - `ALI_EMBEDDING_MODEL`（可选，默认 text-embedding-3-small）
//! - `ALI_QUERY_EMBED_CACHE_SIZE`（默认 256，设为 0 关闭缓存）
//!
//! 未配置 key 时，索引仍可走 BM25，向量能力关闭。
//! DeepSeek 对话 API **不提供** embedding，需另配服务。

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use anyhow::{Context, Result};
use futures::stream::{self, StreamExt};
use reqwest::{Client, StatusCode};
use serde::{Deserialize, Serialize};
use tokio_util::sync::CancellationToken;
use tracing::warn;

use crate::FunctionChunk;
use crate::hnsw_index::{self, AnnCache};

/// 恢复 Mutex poisoning：若锁已被毒化（持有者 panic），仍取出内部数据继续服务，
/// 避免一次 panic 让整个 Port 进程后续所有缓存读写都崩。这是项目硬约束
/// 「Rust Mutex usage must handle poisoning」的统一实现。
pub(crate) fn lock_or_recover<T>(lock: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    lock.lock().unwrap_or_else(|e| e.into_inner())
}

/// 单条 embedding 输入的最大字符数。超长文本按字符边界截断后再发 API，
/// 避免超过模型 token 上限导致整批请求 400 失败。
const MAX_EMBEDDING_CHARS: usize = 8000;

/// 进程级查询 embedding LRU 缓存。
///
/// 查询文本重复率高时（如多轮对话复用同一问题）可显著降低 API 调用次数。
/// 使用 `HashMap` 存储 + `VecDeque` 跟踪插入顺序实现 FIFO 淘汰；
/// 对查询缓存而言 FIFO 与 LRU 效果接近，实现简单且无需逐次更新链表。
struct QueryEmbedCache {
    map: HashMap<String, Vec<f32>>,
    order: VecDeque<String>,
    capacity: usize,
}

impl QueryEmbedCache {
    fn new(capacity: usize) -> Self {
        Self {
            map: HashMap::with_capacity(capacity.min(1024)),
            order: VecDeque::with_capacity(capacity.min(1024)),
            capacity,
        }
    }

    fn get(&self, key: &str) -> Option<&Vec<f32>> {
        self.map.get(key)
    }

    fn put(&mut self, key: String, value: Vec<f32>) {
        if self.capacity == 0 {
            return;
        }
        if self.map.contains_key(&key) {
            return;
        }
        if self.map.len() >= self.capacity {
            if let Some(evicted) = self.order.pop_front() {
                self.map.remove(&evicted);
            }
        }
        self.order.push_back(key.clone());
        self.map.insert(key, value);
    }
}

static QUERY_EMBED_CACHE: Mutex<Option<QueryEmbedCache>> = Mutex::new(None);

fn query_cache_capacity() -> usize {
    std::env::var("ALI_QUERY_EMBED_CACHE_SIZE")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(256)
}

/// 带缓存的查询 embedding：命中缓存则直接返回，否则调用 API 并写入缓存。
///
/// 缓存大小由 `ALI_QUERY_EMBED_CACHE_SIZE` 控制；设为 0 时缓存禁用，
/// 每次调用都会请求 API。
pub async fn request_embedding_cached(
    client: &Client,
    config: &EmbeddingConfig,
    text: &str,
) -> Result<Vec<f32>> {
    // P2-6：空文本直接报错，不再每次绕过缓存白打一次 API。
    if text.is_empty() {
        anyhow::bail!("empty embedding text");
    }
    {
        let mut guard = lock_or_recover(&QUERY_EMBED_CACHE);
        if guard.is_none() {
            *guard = Some(QueryEmbedCache::new(query_cache_capacity()));
        }
        // get 只读不修改；签名改为 &self 后可对 guard 不可变借用（任务 #14）
        if let Some(v) = guard.as_ref().and_then(|cache| cache.get(text)) {
            return Ok(v.clone());
        }
    }
    let vector = request_embedding(client, config, text).await?;
    let mut guard = lock_or_recover(&QUERY_EMBED_CACHE);
    if let Some(cache) = guard.as_mut() {
        cache.put(text.to_string(), vector.clone());
    }
    Ok(vector)
}

/// 清空查询 embedding 缓存（用于索引重建或测试场景）。
pub fn clear_query_embed_cache() {
    if let Some(cache) = lock_or_recover(&QUERY_EMBED_CACHE).as_mut() {
        cache.map.clear();
        cache.order.clear();
    }
}

/// 本地向量库：内存 HashMap + JSON 落盘 + 惰性 HNSW 索引。
///
/// `chunk_hashes` 用于增量索引：内容未变则跳过重新 embed。
/// `ann_cache` / `memory_ann_cache` 不落盘，向量变更后自动失效并惰性重建。
/// code 与 memory 分建两图，避免语义空间互相稀释（性能审核 P1 / Bug R2）。
#[derive(Serialize, Deserialize)]
pub struct EmbeddingStore {
    /// chunk_id → 稠密向量（已 L2 归一化）
    pub vectors: HashMap<String, Vec<f32>>,
    /// 生成这些向量时使用的模型名
    pub model: Option<String>,
    /// chunk_id → 内容哈希，用于判断是否需要重新 embed
    #[serde(default)]
    pub chunk_hashes: HashMap<String, String>,
    /// 代码 chunk 的惰性 HNSW 缓存（不含 `memory:` 键）
    #[serde(skip, default)]
    ann_cache: AnnCache,
    /// 记忆向量的惰性 HNSW 缓存（仅 `memory:` 键）
    #[serde(skip, default)]
    memory_ann_cache: AnnCache,
}

impl Clone for EmbeddingStore {
    fn clone(&self) -> Self {
        Self {
            vectors: self.vectors.clone(),
            model: self.model.clone(),
            chunk_hashes: self.chunk_hashes.clone(),
            ann_cache: AnnCache::default(),
            memory_ann_cache: AnnCache::default(),
        }
    }
}

impl Default for EmbeddingStore {
    fn default() -> Self {
        Self {
            vectors: HashMap::new(),
            model: None,
            chunk_hashes: HashMap::new(),
            ann_cache: AnnCache::default(),
            memory_ann_cache: AnnCache::default(),
        }
    }
}

impl EmbeddingStore {
    /// 向量表变更后调用，使 HNSW 缓存在下次检索时重建。
    pub fn touch_vectors(&mut self) {
        self.ann_cache.invalidate();
        self.memory_ann_cache.invalidate();
    }

    /// R8：首次成功写入向量后记录模型名，使后续模型切换检测生效。
    fn record_model_on_first_success(&mut self, model: &str, embedded: usize) {
        if self.model.is_none() && embedded > 0 {
            self.model = Some(model.to_string());
        }
    }
}

#[derive(Debug, Deserialize)]
struct EmbeddingResponse {
    data: Vec<EmbeddingData>,
}

#[derive(Debug, Deserialize)]
struct EmbeddingData {
    embedding: Vec<f32>,
    #[serde(default)]
    index: usize,
}

/// Embedding HTTP 客户端配置。
#[derive(Clone)]
pub struct EmbeddingConfig {
    pub api_key: String,
    pub base_url: String,
    pub model: String,
}

impl EmbeddingConfig {
    /// 完全走配置：必须同时有 key、base_url、model。
    /// 不回退 LLM key，不默认 OpenAI URL/模型名。
    pub fn from_env() -> Option<Self> {
        let api_key = match std::env::var("ALI_EMBEDDING_API_KEY") {
            Ok(k) if !k.trim().is_empty() => k,
            _ => return None,
        };
        let base_url = match std::env::var("ALI_EMBEDDING_BASE_URL") {
            Ok(u) if !u.trim().is_empty() => u,
            _ => return None,
        };
        let model = match std::env::var("ALI_EMBEDDING_MODEL") {
            Ok(m) if !m.trim().is_empty() => m,
            _ => return None,
        };
        Some(Self {
            api_key,
            base_url,
            model,
        })
    }
}

/// 判断本次 embedding 使用的模型是否与已存向量的模型不一致。
///
/// 不一致意味着旧向量维度/语义空间已失效，需要清空重 embed；`None`（首次）视为一致。
pub fn embedding_model_changed(existing: &EmbeddingStore, config: &EmbeddingConfig) -> bool {
    existing
        .model
        .as_deref()
        .map(|model| model != config.model)
        .unwrap_or(false)
}

/// 增量 embed：仅对哈希变化的 chunk 请求 API，原地合并进 `store`。
///
/// 复用调用方传入的 `client`，避免每个 chunk 重建 HTTP 连接（TCP/TLS 握手开销）。
///
/// 韧性保证：
/// - 模型切换（`store.model` 与 `config.model` 不一致）时清空旧向量，全部重 embed；
/// - 某个批次在有限次退避重试后仍失败时，**保留已完成批次**并中止，返回 `warnings`
///   而非丢弃全部进度，让调用方持久化部分结果、下次索引再补齐剩余 chunk。
///
/// 返回 `(已成功 embed 的 chunk 数, 警告列表)`。
pub async fn embed_chunks_incremental(
    client: &Client,
    config: &EmbeddingConfig,
    chunks: &[FunctionChunk],
    bodies: &HashMap<String, String>,
    store: &mut EmbeddingStore,
    cancel: Option<&CancellationToken>,
) -> Result<(usize, Vec<String>)> {
    let mut warnings = Vec::new();

    // 模型切换：旧向量失效，清空后全部重新 embed。
    // 注意：vectors.clear() 已使下方「hash 匹配且 vector 存在」的复用判断全部落空，
    // 因此不必同时清 chunk_hashes（任务 #15）。保留旧 chunk_hashes 的目的：
    // 若本次 embed 全部失败，可回滚 vectors.clear()/chunk_hashes，下次索引重新检测模型
    // 切换并重试；否则即使重试也会因 model 已被改写而走「无变更」路径，遗漏重 embed。
    let model_changed = embedding_model_changed(store, config);
    // 备份以便总失败时回滚（仅 model_changed 路径下需要）。
    let backup_vectors = if model_changed {
        // 仅在确实要破坏性修改前才克隆，避免无谓内存峰值。
        let snapshot = store.vectors.clone();
        warnings.push(format!(
            "embedding model changed ({} -> {}); clearing stale vectors and re-embedding all chunks",
            store.model.as_deref().unwrap_or("<none>"),
            config.model
        ));
        store.vectors.clear();
        store.touch_vectors();
        Some(snapshot)
    } else {
        None
    };
    let backup_chunk_hashes = store.chunk_hashes.clone();
    let backup_model = store.model.clone();
    // 暂不写 store.model：若全部 embed 失败需回滚此字段（任务 #15）。
    // 在循环中只有真正写入向量后才提交 model。
    if model_changed {
        store.model = Some(config.model.clone());
    }

    let mut pending = Vec::new();
    for chunk in chunks {
        // vectors 已被 clear（model_changed）时 contains_key 必为 false → 自然全量重 embed。
        if store
            .chunk_hashes
            .get(&chunk.id)
            .map(|hash| hash == &chunk.hash)
            .unwrap_or(false)
            && store.vectors.contains_key(&chunk.id)
        {
            continue;
        }

        let text = bodies
            .get(&chunk.id)
            .cloned()
            .unwrap_or_else(|| chunk.function.clone());
        pending.push((chunk.id.clone(), chunk.hash.clone(), text));
    }

    let batch_size = embedding_batch_size();
    let concurrency = embedding_concurrency();
    let batches: Vec<Vec<(String, String, String)>> = pending
        .chunks(batch_size)
        .map(|batch| batch.to_vec())
        .collect();

    // 并发请求各批；按批号排序后再写入 store，保证失败时已完成前缀可持久化。
    // P2-7：用 while-let 逐条消费并在取消时立即停止等待（原 `.collect()` 会把
    // 所有在途批次跑完才返回，取消延迟最长 = 并发数 × 单批耗时）。
    let mut stream = stream::iter(batches.into_iter().enumerate())
        .map(|(idx, batch)| {
            let client = client.clone();
            let config = config.clone();
            let cancel = cancel.cloned();
            async move {
                if cancel.as_ref().is_some_and(|t| t.is_cancelled()) {
                    return (idx, batch, Err(anyhow::anyhow!("index cancelled")));
                }
                let texts = batch
                    .iter()
                    .map(|(_, _, text)| text.clone())
                    .collect::<Vec<_>>();
                let result = request_embeddings(&client, &config, &texts).await;
                (idx, batch, result)
            }
        })
        .buffer_unordered(concurrency);
    let mut outcomes = Vec::new();
    while let Some(item) = stream.next().await {
        outcomes.push(item);
        if cancel.is_some_and(|t| t.is_cancelled()) {
            // drop(stream) 即中断在途 HTTP 请求，不再等待剩余批次。
            break;
        }
    }
    drop(stream);
    outcomes.sort_by_key(|(idx, _, _)| *idx);

    let mut embedded = 0usize;
    let mut aborted = false;
    for (_idx, batch, result) in outcomes {
        if cancel.is_some_and(|t| t.is_cancelled()) {
            warnings.push(format!(
                "embedding cancelled; kept {} completed vectors",
                embedded
            ));
            aborted = true;
            break;
        }
        match result {
            Ok(vectors) if vectors.len() == batch.len() => {
                for ((id, hash, _), mut vector) in batch.iter().zip(vectors) {
                    l2_normalize(&mut vector);
                    store.vectors.insert(id.clone(), vector);
                    store.chunk_hashes.insert(id.clone(), hash.clone());
                    embedded += 1;
                }
                store.touch_vectors();
            }
            Ok(vectors) => {
                warnings.push(format!(
                    "embedding batch size mismatch (requested {}, received {}); kept {} completed vectors",
                    batch.len(),
                    vectors.len(),
                    embedded
                ));
                aborted = true;
                break;
            }
            Err(err) => {
                warnings.push(format!(
                    "embedding batch failed after retries; kept {} completed vectors: {:#}",
                    embedded, err
                ));
                aborted = true;
                break;
            }
        }
    }

    // 总失败（一个向量都没写成功）且本由 model_changed 触发清空 → 回滚以保留可重试状态。
    if model_changed && embedded == 0 && aborted {
        if let Some(snapshot) = backup_vectors {
            store.vectors = snapshot;
        }
        store.chunk_hashes = backup_chunk_hashes;
        store.model = backup_model;
        store.touch_vectors();
        warnings.push(
            "model switch embed fully failed; rolled back vectors/chunk_hashes/model for next retry".to_string(),
        );
    }

    // R8：首次（model 为 None）成功写入至少一个向量后记录模型名，否则后续模型切换
    // 检测因 model 一直为 None 而失效。model_changed 破坏性路径已在前面显式写入。
    store.record_model_on_first_success(&config.model, embedded);

    Ok((embedded, warnings))
}

fn normalize_query(query_vector: &[f32]) -> Vec<f32> {
    let mut q = query_vector.to_vec();
    l2_normalize(&mut q);
    q
}

/// 暴力 Top-K（小数据集或 HNSW 回退）。
fn brute_top_hits(
    store: &EmbeddingStore,
    query: &[f32],
    limit: usize,
) -> Vec<(String, f32)> {
    let mut hits = store
        .vectors
        .iter()
        .filter(|(id, _)| !id.starts_with("memory:"))
        .map(|(id, vector)| (id.clone(), cosine_similarity(query, vector)))
        .collect::<Vec<_>>();
    hits.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    hits.truncate(limit.max(1));
    hits
}

fn brute_top_hits_for_files(
    store: &EmbeddingStore,
    query: &[f32],
    file_paths: &[String],
    limit: usize,
) -> Vec<(String, f32)> {
    let mut hits = store
        .vectors
        .iter()
        .filter(|(chunk_id, _)| {
            file_paths
                .iter()
                .any(|file| crate::chunk_matches_file(chunk_id, file))
        })
        .map(|(id, vector)| (id.clone(), cosine_similarity(query, vector)))
        .collect::<Vec<_>>();
    hits.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    hits.truncate(limit.max(1));
    hits
}

/// 向 Embedding API 发送单条文本，返回稠密向量。
pub async fn request_embedding(client: &Client, config: &EmbeddingConfig, text: &str) -> Result<Vec<f32>> {
    request_embeddings(client, config, &[text.to_string()])
        .await?
        .into_iter()
        .next()
        .ok_or_else(|| anyhow::anyhow!("embedding response missing data"))
}

/// 单次请求批量发送文本。服务端返回 `index` 时据此恢复输入顺序。
///
/// 超长输入按字符边界截断到 [`MAX_EMBEDDING_CHARS`]；对 429 / 5xx 及网络类错误
/// 做有限次指数退避重试（次数由 `ALI_EMBEDDING_MAX_RETRIES` 控制，默认 2）。
async fn request_embeddings(
    client: &Client,
    config: &EmbeddingConfig,
    texts: &[String],
) -> Result<Vec<Vec<f32>>> {
    #[derive(Serialize)]
    struct Request<'a> {
        model: &'a str,
        input: &'a [String],
    }

    let inputs: Vec<String> = texts.iter().map(|text| truncate_for_embedding(text)).collect();
    let max_attempts = embedding_max_retries() + 1;

    let mut attempt = 0;
    loop {
        attempt += 1;
        let result = client
            .post(&config.base_url)
            .bearer_auth(&config.api_key)
            .json(&Request {
                model: &config.model,
                input: &inputs,
            })
            .send()
            .await;

        match result {
            Ok(response) => {
                let status = response.status();
                if is_retryable_status(status) && attempt < max_attempts {
                    let delay = backoff_delay(attempt);
                    warn!(
                        "embedding request got status {status}; retry {attempt}/{} after {}ms",
                        max_attempts - 1,
                        delay.as_millis()
                    );
                    tokio::time::sleep(delay).await;
                    continue;
                }
                let response = response.error_for_status()?;
                let decoded = response
                    .json::<EmbeddingResponse>()
                    .await
                    .context("failed to decode embedding response")?;
                let mut data = decoded.data;
                data.sort_by_key(|item| item.index);
                return Ok(data.into_iter().map(|item| item.embedding).collect());
            }
            Err(err) => {
                // 连接/超时等瞬时网络错误也做有限次重试。
                let transient = err.is_timeout() || err.is_connect() || err.is_request();
                if transient && attempt < max_attempts {
                    let delay = backoff_delay(attempt);
                    warn!(
                        "embedding request error ({err}); retry {attempt}/{} after {}ms",
                        max_attempts - 1,
                        delay.as_millis()
                    );
                    tokio::time::sleep(delay).await;
                    continue;
                }
                return Err(anyhow::Error::new(err).context("embedding request failed"));
            }
        }
    }
}

/// 429（限流）与 5xx（服务端错误）视为可重试。
fn is_retryable_status(status: StatusCode) -> bool {
    status == StatusCode::TOO_MANY_REQUESTS || status.is_server_error()
}

/// 指数退避：第 n 次重试等待 `base * 2^(n-1)`（base 默认 500ms），封顶 8s。
fn backoff_delay(attempt: usize) -> Duration {
    let base_ms: u64 = std::env::var("ALI_EMBEDDING_RETRY_BASE_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(500)
        .clamp(50, 5_000);
    let factor = 1u64 << (attempt.saturating_sub(1)).min(5) as u32;
    Duration::from_millis((base_ms.saturating_mul(factor)).min(8_000))
}

/// 有限重试次数（不含首次尝试），默认 2，范围 0..=5。
fn embedding_max_retries() -> usize {
    std::env::var("ALI_EMBEDDING_MAX_RETRIES")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(2)
        .clamp(0, 5)
}

/// 按字符边界将文本截断到 [`MAX_EMBEDDING_CHARS`]，避免超长输入触发 API 上限错误。
fn truncate_for_embedding(text: &str) -> String {
    if text.chars().count() <= MAX_EMBEDDING_CHARS {
        return text.to_string();
    }
    text.chars().take(MAX_EMBEDDING_CHARS).collect()
}

/// 每个 HTTP 请求包含的文本数，默认 32，限制在 1..=256。
/// 并发 embedding 批次数（`ALI_EMBEDDING_CONCURRENCY`，默认 4，范围 1–16）。
fn embedding_concurrency() -> usize {
    std::env::var("ALI_EMBEDDING_CONCURRENCY")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(4)
        .clamp(1, 16)
}

fn embedding_batch_size() -> usize {
    std::env::var("ALI_EMBEDDING_BATCH_SIZE")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(32)
        .clamp(1, 256)
}

/// 余弦相似度；长度不一致时返回 0。
/// 若向量已 L2 归一化，退化为点积（更快）。
pub fn cosine_similarity(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() || a.is_empty() {
        return 0.0;
    }
    let dot: f32 = a.iter().zip(b.iter()).map(|(x, y)| x * y).sum();
    // 用平方范数判断是否已归一化，归一化向量上直接点积，省去两次无谓 sqrt。
    let sq_a: f32 = a.iter().map(|x| x * x).sum();
    let sq_b: f32 = b.iter().map(|x| x * x).sum();
    if sq_a == 0.0 || sq_b == 0.0 {
        0.0
    } else if (sq_a - 1.0).abs() < 1e-3 && (sq_b - 1.0).abs() < 1e-3 {
        dot
    } else {
        dot / (sq_a.sqrt() * sq_b.sqrt())
    }
}

/// 就地 L2 归一化，便于后续搜索用点积代替完整余弦。
///
/// 归一化后强制 Σvᵢ² ≤ 1.0：f32 舍入常使自比点积略大于 1，
/// 触发 anndists `DistDot` 的 `assert!(dot >= 0.)`（内部用 1-dot）panic，
/// 从而杀死整个 Port。
pub fn l2_normalize(v: &mut [f32]) {
    let norm: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm > 0.0 {
        for x in v.iter_mut() {
            *x /= norm;
        }
    }
    // 二次钳制：若平方和仍略超 1，再缩一点，保证 DistDot 断言安全。
    let sq: f32 = v.iter().map(|x| x * x).sum();
    if sq > 1.0 {
        let scale = 1.0 / sq.sqrt();
        for x in v.iter_mut() {
            *x *= scale;
        }
    }
}

/// 在全部本地向量中按余弦相似度取 Top-K，返回 `(chunk_id, score)`。
///
/// 向量数 ≥ `ALI_HNSW_MIN_VECTORS`（默认 128）时使用 HNSW 近似检索。
/// 仅对代码 chunk 建图（排除 `memory:`），避免记忆向量稀释代码召回。
pub fn top_vector_hits(
    store: &EmbeddingStore,
    query_vector: &[f32],
    limit: usize,
) -> Vec<(String, f32)> {
    if store.vectors.is_empty() {
        return Vec::new();
    }
    let q = normalize_query(query_vector);
    let code_count = store
        .vectors
        .keys()
        .filter(|k| !k.starts_with("memory:"))
        .count();
    if code_count == 0 {
        return Vec::new();
    }
    if hnsw_index::should_use_hnsw(code_count) {
        if let Some(index) =
            store
                .ann_cache
                .get_or_build_filtered(&store.vectors, |k| !k.starts_with("memory:"))
        {
            if q.len() == index.dimension() {
                let hits = index.search(&q, limit.max(1));
                if !hits.is_empty() {
                    return hits;
                }
            }
        }
    }
    brute_top_hits(store, &q, limit)
}

/// 仅在 BM25 候选文件对应的 chunk 上计算向量相似度。
pub fn top_vector_hits_for_files(
    store: &EmbeddingStore,
    query_vector: &[f32],
    file_paths: &[String],
    limit: usize,
) -> Vec<(String, f32)> {
    if file_paths.is_empty() || store.vectors.is_empty() {
        return Vec::new();
    }
    let q = normalize_query(query_vector);
    let limit = limit.max(1);
    let code_count = store
        .vectors
        .keys()
        .filter(|k| !k.starts_with("memory:"))
        .count();
    if hnsw_index::should_use_hnsw(code_count) {
        if let Some(index) =
            store
                .ann_cache
                .get_or_build_filtered(&store.vectors, |k| !k.starts_with("memory:"))
        {
            if q.len() == index.dimension() {
                let hits = index.search_with_prefixes(&q, file_paths, limit);
                if hits.len() >= limit {
                    return hits;
                }
                let fallback = brute_top_hits_for_files(store, &q, file_paths, limit);
                return merge_top_hits(&hits, fallback, limit);
            }
        }
    }
    brute_top_hits_for_files(store, &q, file_paths, limit)
}

/// 在本地 store 中检索记忆向量（仅 `memory:*` 键）。
/// 使用独立 memory HNSW 图；候选不足时仍暴力回补。
pub fn top_memory_hits(
    store: &EmbeddingStore,
    query_vector: &[f32],
    limit: usize,
) -> Vec<(i64, f32)> {
    let memory_count = store
        .vectors
        .keys()
        .filter(|k| k.starts_with("memory:"))
        .count();
    if memory_count == 0 {
        return Vec::new();
    }
    let q = normalize_query(query_vector);
    let limit = limit.max(1);
    if hnsw_index::should_use_hnsw(memory_count) {
        if let Some(index) = store
            .memory_ann_cache
            .get_or_build_filtered(&store.vectors, |k| k.starts_with("memory:"))
        {
            if q.len() == index.dimension() {
                let hits = index.search_memory(&q, limit);
                if hits.len() >= limit {
                    return hits;
                }
                let fallback = brute_memory_hits(store, &q, limit);
                return merge_top_hits(&hits, fallback, limit);
            }
        }
    }
    brute_memory_hits(store, &q, limit)
}

/// 暴力扫描 `memory:` 前缀向量并按相似度取 Top-K。
fn brute_memory_hits(store: &EmbeddingStore, query: &[f32], limit: usize) -> Vec<(i64, f32)> {
    let mut hits = store
        .vectors
        .iter()
        .filter_map(|(key, vector)| {
            let id_str = key.strip_prefix("memory:")?;
            let id: i64 = id_str.parse().ok()?;
            Some((id, cosine_similarity(query, vector)))
        })
        .collect::<Vec<_>>();
    hits.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    hits.truncate(limit.max(1));
    hits
}

/// 合并主结果与暴力回退结果：按 key 去重后按分数降序截断到 `limit`。
fn merge_top_hits<K>(primary: &[(K, f32)], fallback: Vec<(K, f32)>, limit: usize) -> Vec<(K, f32)>
where
    K: std::cmp::Eq + std::hash::Hash + Clone,
{
    let mut seen = std::collections::HashSet::with_capacity(primary.len() + fallback.len());
    let mut merged = primary.to_vec();
    for (key, _) in primary {
        seen.insert(key.clone());
    }
    for hit in fallback {
        if seen.insert(hit.0.clone()) {
            merged.push(hit);
        }
    }
    merged.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    merged.truncate(limit.max(1));
    merged
}

/// 本地向量库 JSON 文件路径（默认 `.ali/index/embeddings.json`）。
fn embeddings_path() -> std::path::PathBuf {
    std::env::var("ALI_INDEX_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| std::path::PathBuf::from(".ali/index/tantivy"))
        .parent()
        .map(|p| p.join("embeddings.json"))
        .unwrap_or_else(|| std::path::PathBuf::from(".ali/index/embeddings.json"))
}

/// 进程级持久化互斥锁：串行化「写临时文件 → rename」整段，避免
/// Port 请求路径（memory_upsert/delete）与后台索引 embedding 分支并发
/// 用同一临时文件截断对方，导致 embeddings.json 损坏。
static PERSIST_LOCK: Mutex<()> = Mutex::new(());

/// 临时文件序号：保证同一进程内每次落盘的临时文件名唯一。
static PERSIST_TMP_SEQ: AtomicU64 = AtomicU64::new(0);

/// 依据目标路径生成唯一临时文件路径（同目录、`json.tmp.{pid}.{seq}` 后缀）。
fn persist_temp_path(path: &Path) -> PathBuf {
    let seq = PERSIST_TMP_SEQ.fetch_add(1, Ordering::Relaxed);
    path.with_extension(format!("json.tmp.{}.{}", std::process::id(), seq))
}

/// 将向量库写入 `{ALI_INDEX_DIR 的父目录}/embeddings.json`（默认 `.ali/index/embeddings.json`）。
///
/// P0-3（部分）修复：原实现 `serde_json::to_string(store)` 先把整库物化成一根
/// JSON 字符串（大向量库可达 GB 级）再写盘；现改流式写出，峰值内存不再随库膨胀。
/// 长期方案仍是迁 SQLite/blob 或强制 Qdrant（见审核报告 §4）。
pub fn persist_store(store: &EmbeddingStore) -> Result<()> {
    persist_store_to(store, &embeddings_path())
}

/// 落盘核心：持进程级锁写唯一临时文件，再原子替换目标文件。
fn persist_store_to(store: &EmbeddingStore, path: &Path) -> Result<()> {
    let _guard = lock_or_recover(&PERSIST_LOCK);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let temp = persist_temp_path(path);
    {
        let file = std::fs::File::create(&temp)?;
        let writer = std::io::BufWriter::new(file);
        serde_json::to_writer(writer, store)?;
    }
    if let Err(rename_error) = std::fs::rename(&temp, path) {
        // Windows 不允许 rename 覆盖现有文件；保留旧文件直到新文件完整落盘。
        if path.exists() {
            std::fs::remove_file(path)?;
            std::fs::rename(&temp, path)?;
        } else {
            return Err(rename_error.into());
        }
    }
    Ok(())
}

/// 启动时加载本地向量库；文件不存在则返回空库。
pub fn load_store() -> Result<EmbeddingStore> {
    let path = embeddings_path();
    if !path.exists() {
        return Ok(EmbeddingStore::default());
    }
    // 流式解析，避免先读成整串再反序列化的双倍内存。
    let file = std::fs::File::open(&path)?;
    let reader = std::io::BufReader::new(file);
    let store = serde_json::from_reader(reader)?;
    Ok(store)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config_with_model(model: &str) -> EmbeddingConfig {
        EmbeddingConfig {
            api_key: "k".to_string(),
            base_url: "http://localhost/v1/embeddings".to_string(),
            model: model.to_string(),
        }
    }

    #[test]
    fn model_changed_detects_switch() {
        let mut store = EmbeddingStore::default();
        // 首次（无已存模型）不算切换。
        assert!(!embedding_model_changed(&store, &config_with_model("m1")));
        store.model = Some("m1".to_string());
        assert!(!embedding_model_changed(&store, &config_with_model("m1")));
        assert!(embedding_model_changed(&store, &config_with_model("m2")));
    }

    #[test]
    fn truncate_respects_char_boundary() {
        let short = "abc";
        assert_eq!(truncate_for_embedding(short), short);

        let long: String = "汉".repeat(MAX_EMBEDDING_CHARS + 500);
        let truncated = truncate_for_embedding(&long);
        assert_eq!(truncated.chars().count(), MAX_EMBEDDING_CHARS);
        // 未在多字节字符中间截断（可正常构造字符串即证明边界正确）。
        assert!(truncated.chars().all(|c| c == '汉'));
    }

    #[test]
    fn backoff_grows_and_is_capped() {
        let d1 = backoff_delay(1);
        let d2 = backoff_delay(2);
        assert!(d2 >= d1);
        assert!(backoff_delay(20).as_millis() <= 8_000);
    }

    #[test]
    fn persist_temp_names_are_unique() {
        let path = std::path::PathBuf::from("embeddings.json");
        let first = persist_temp_path(&path);
        let second = persist_temp_path(&path);
        assert_ne!(first, second);
    }

    #[test]
    fn persist_store_concurrent_does_not_corrupt() {
        use std::sync::{Arc, Barrier};

        let dir = std::env::temp_dir().join(format!("ali_emb_{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let path = dir.join("embeddings.json");

        let threads = 8;
        let barrier = Arc::new(Barrier::new(threads));
        let mut handles = Vec::new();
        for i in 0..threads {
            let path = path.clone();
            let barrier = Arc::clone(&barrier);
            handles.push(std::thread::spawn(move || {
                let mut store = EmbeddingStore::default();
                store
                    .vectors
                    .insert(format!("memory:{}", i), vec![i as f32, 1.0]);
                barrier.wait();
                persist_store_to(&store, &path).expect("persist should succeed");
            }));
        }
        for handle in handles {
            handle.join().expect("thread join");
        }

        let content = std::fs::read_to_string(&path).expect("persisted file exists");
        let parsed: EmbeddingStore =
            serde_json::from_str(&content).expect("persisted file must be valid JSON");
        // 每次落盘都是整库快照：串行化后最终文件应恰好包含一个向量（最后完成者），
        // 若临时文件互相截断，这里会解析失败或出现半个对象。
        assert_eq!(parsed.vectors.len(), 1);

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn merge_top_hits_dedupes_and_fills() {
        let primary = vec![(1, 0.9), (2, 0.8)];
        let fallback = vec![(2, 0.8), (3, 0.7), (4, 0.6)];
        let merged = merge_top_hits(&primary, fallback, 4);
        assert_eq!(merged.len(), 4);
        assert_eq!(merged[0].0, 1);
        assert_eq!(merged[1].0, 2);
        assert_eq!(merged.iter().filter(|(id, _)| *id == 2).count(), 1);
    }

    #[test]
    fn first_success_records_model() {
        let mut store = EmbeddingStore::default();
        store.record_model_on_first_success("m1", 0);
        assert_eq!(store.model, None);
        store.record_model_on_first_success("m1", 3);
        assert_eq!(store.model.as_deref(), Some("m1"));
        // 已记录后不再被覆盖。
        store.record_model_on_first_success("m2", 5);
        assert_eq!(store.model.as_deref(), Some("m1"));
    }

    #[test]
    fn top_memory_hits_supplements_when_hnsw_dilutes() {
        // 150 个 code 向量与查询完全相同（会占据 HNSW 近邻），150 个 memory 向量
        // 略差于查询。近似检索按 fetch=limit*8 取邻后过滤 `memory:` 前缀，命中远不足
        // limit，应触发暴力补齐，仍返回等长命中。
        let mut store = EmbeddingStore::default();
        for i in 0..150 {
            store.vectors.insert(format!("code:{i}"), vec![1.0, 0.0]);
            store
                .vectors
                .insert(format!("memory:{i}"), vec![0.999, 0.001]);
        }
        let query = vec![1.0, 0.0];
        let hits = top_memory_hits(&store, &query, 10);
        assert_eq!(hits.len(), 10);
        assert!(hits.iter().all(|(id, _)| (0..150).contains(id)));
        for window in hits.windows(2) {
            assert!(window[0].1 >= window[1].1);
        }
    }

    #[test]
    fn top_vector_hits_for_files_supplements_when_hnsw_dilutes() {
        let mut store = EmbeddingStore::default();
        for i in 0..150 {
            store
                .vectors
                .insert(format!("other/mod{i}.erl:m:f/0"), vec![1.0, 0.0]);
            store
                .vectors
                .insert(format!("src/foo.erl:foo:bar/{i}"), vec![0.999, 0.001]);
        }
        let query = vec![1.0, 0.0];
        let files = vec!["src/foo.erl".to_string()];
        let hits = top_vector_hits_for_files(&store, &query, &files, 10);
        assert_eq!(hits.len(), 10);
        assert!(hits.iter().all(|(id, _)| id.starts_with("src/foo.erl")));
    }
}
