//! # aliCore — Erlang AI 助手的 Rust 数据面
//!
//! 由 Erlang `aliCoreClient` 以 **Port** 方式拉起：`aliCore --port`。
//! 进程通过 stdin/stdout 交换 `{packet, 4}` 长度前缀 JSON（见 [`port`] 模块）。
//!
//! ## 主要能力
//! | 能力 | 实现要点 |
//! |------|----------|
//! | 代码索引 | WalkDir + 忽略规则；`.erl`/`.hrl` 用 tree-sitter 抽函数；其它后缀按行分块 |
//! | 全文检索 | Tantivy BM25 |
//! | 向量检索 | 可选 Embedding API + 本地 `embeddings.json` 或 Qdrant |
//! | 调用图 | 轻量边索引（MFA 键多边映射），支持 callers/callees 与按文件增量更新 |
//! | 本地 DB | 嵌入式 SQLite（`.ali/db/ali.db`） |
//! | 语义记忆 | memory_upsert / memory_search / memory_delete |
//!
//! ## 关键环境变量（由 Erlang `alConfig:core_port_env/0` 注入）
//! - `ALI_ROOT`：项目根
//! - `ALI_INDEX_DIR`：Tantivy 目录
//! - `ALI_DB_PATH` / `ALI_DB_SCHEMA`
//! - `ALI_INDEX_EXTENSIONS` / `ALI_INDEX_IGNORE`
//! - `ALI_INDEX_THREADS`：索引解析并行度（默认 = 逻辑核数）
//! - `ALI_INDEX_FILE_TIMEOUT_SECS`：单文件解析超时秒数（默认 30，`0`=不限制）
//! - `ALI_EMBEDDING_*` / `ALI_RERANK_*` / `ALI_QDRANT_URL`
//!
//! ## 模块划分
//! - [`port`]：Port 帧协议与路由
//! - [`ignore`]：忽略规则与扩展名白名单
//! - [`db`]：SQLite
//! - [`embedding`]：向量 API 与本地存储
//! - [`rerank`]：二次排序
//! - [`qdrant_store`]：Qdrant 客户端
//!
//! 本文件（`main`）承载：应用状态、索引构建、搜索、符号/调用图、记忆与入口。

use std::{
    cell::RefCell,
    collections::BTreeMap,
    collections::{HashMap, HashSet},
    path::{Path, PathBuf},
    sync::atomic::{AtomicUsize, Ordering},
    sync::{Arc, Condvar, Mutex, OnceLock},
    time::{Duration, Instant},
};

/// 非 Erlang 源文件（如 `.rs`、`.cfg`）按固定行数切块，避免单文档过大。
const TEXT_CHUNK_LINES: usize = 40;

mod data_flow;
mod db;
mod embedding;
mod hnsw_index;
mod ignore;
mod port;
mod qdrant_store;
mod rerank;

use db::{DbQueryRequest, DbQueryResponse, DbStatusResponse, LocalDb};
use embedding::{
    clear_query_embed_cache, embed_chunks_incremental, embedding_model_changed,
    load_store, persist_store, request_embedding_cached, top_memory_hits, top_vector_hits,
    top_vector_hits_for_files, EmbeddingConfig, EmbeddingStore,
};
use ignore::IndexExtensions;
use qdrant_store::QdrantStore;

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use tantivy::{
    doc,
    collector::TopDocs,
    query::QueryParser,
    schema::{Field, Schema, Value, STORED, TEXT, STRING},
    Term,
    Index, IndexReader,
};
use tokio::sync::RwLock;
use tokio_util::sync::CancellationToken;
use tree_sitter::{Query, QueryCursor, StreamingIterator};
use tracing::info;
use walkdir::WalkDir;
use rayon::prelude::*;

/// Qdrant 连续失败熔断：达到阈值后冷却期内直接走本地 fallback。
struct QdrantCircuit {
    consecutive_failures: u32,
    open_until: Option<Instant>,
}

impl QdrantCircuit {
    fn allow(&self) -> bool {
        match self.open_until {
            Some(until) if Instant::now() < until => false,
            _ => true,
        }
    }

    fn on_ok(&mut self) {
        self.consecutive_failures = 0;
        self.open_until = None;
    }

    fn on_err(&mut self) {
        self.consecutive_failures = self.consecutive_failures.saturating_add(1);
        if self.consecutive_failures >= 3 {
            self.open_until = Some(Instant::now() + Duration::from_secs(30));
            self.consecutive_failures = 0;
            tracing::warn!("qdrant circuit open for 30s after consecutive failures");
        }
    }
}

/// 进程级共享状态（Port 请求并发读、索引时写）。
///
/// 使用 `Arc<RwLock<Arc<_>>>`：读路径只 clone Arc 快照后立刻放锁，
/// 避免搜索/分析期间深拷贝整份索引或跨 await 持锁。
#[derive(Clone)]
struct AppState {
    /// Tantivy 全文索引；`None` 表示尚未索引
    index: Arc<RwLock<Option<Arc<SearchIndex>>>>,
    /// 本地向量缓存（无 Qdrant 时使用）
    embeddings: Arc<RwLock<Arc<EmbeddingStore>>>,
    /// 可选 Qdrant HTTP/gRPC 基址
    qdrant_url: Option<String>,
    /// 嵌入式 SQLite
    db: Arc<LocalDb>,
    /// 索引元数据（文件数、chunk 数、上次索引时间等）
    index_meta: Arc<RwLock<IndexMeta>>,
    /// 排队中的索引根路径（避免 already_indexing 静默丢请求）
    pending_index: Arc<tokio::sync::Mutex<std::collections::VecDeque<String>>>,
    /// 共享 HTTP 客户端（连接池复用，避免每次请求新建 TCP/TLS）
    http_client: reqwest::Client,
    /// 共享 Qdrant 客户端（懒初始化，连接复用避免每次请求重建 gRPC 通道）
    qdrant: Arc<RwLock<Option<QdrantStore>>>,
    /// 进程优雅关闭（SIGTERM/SIGINT）；取消后索引在安全点退出
    shutdown: CancellationToken,
    /// 当前索引任务的取消令牌（`/index/cancel` 或 shutdown 子令牌）
    index_cancel: Arc<tokio::sync::Mutex<CancellationToken>>,
    /// Qdrant 熔断状态
    qdrant_circuit: Arc<Mutex<QdrantCircuit>>,
}

#[derive(Clone, Default, Serialize)]
struct IndexMeta {
    indexing: bool,
    last_index_at: u64,
    last_index_root: String,
    /// 当前扫盘已访问的文件条目数（含跳过），便于诊断「卡住」
    #[serde(default)]
    walk_seen: usize,
    files: usize,
    symbols: usize,
    erl_files: usize,
    hrl_files: usize,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    by_extension: BTreeMap<String, usize>,
    /// idle | walk | parse | build | embed
    #[serde(default, skip_serializing_if = "String::is_empty")]
    phase: String,
    /// 解析队列总长（parse 阶段）
    #[serde(default)]
    pending_total: usize,
    /// 已完成解析数（parse 阶段）
    #[serde(default)]
    parsed_done: usize,
    /// 最近完成/正在啃的文件（诊断超大文件）
    #[serde(default, skip_serializing_if = "String::is_empty")]
    last_file: String,
    /// 解析过慢/过大的文件（便于决定是否加入 indexIgnore）
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    slow_files: Vec<SlowFileInfo>,
    /// 当前仍在解析且已超过阈值的文件（可能卡住）
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    busy_files: Vec<SlowFileInfo>,
    /// 因超时被跳过的文件
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    timed_out_files: Vec<SlowFileInfo>,
    /// 最近一次索引失败原因（成功时清空）
    #[serde(default, skip_serializing_if = "String::is_empty")]
    last_error: String,
}

#[derive(Clone, Debug, Default, Serialize)]
struct SlowFileInfo {
    file: String,
    size_bytes: u64,
    /// 已耗时或总耗时（秒，保留 1 位小数用字符串避免浮点 JSON 噪声也可；用 f64 更直观）
    secs: f64,
}

/// 全文索引 + 文档/调用图内存视图。
///
/// 保留 `Clone` 主要为 `Arc::make_mut` 的稀有元数据刷新路径；
/// 热路径应通过 `Arc<SearchIndex>` 共享，避免深拷贝。
#[derive(Clone)]
pub(crate) struct SearchIndex {
    pub(crate) index: Index,
    pub(crate) reader: IndexReader,
    pub(crate) fields: SearchFields,
    pub(crate) documents: Vec<CodeDocument>,
    pub(crate) call_graph_index: CallGraphIndex,
    /// 数据源调用点索引（ets/mnesia/sql 反查）
    pub(crate) data_source_index: data_flow::DataSourceIndex,
    /// file → documents 下标
    pub(crate) by_file: HashMap<String, usize>,
    /// chunk_id → (doc_idx, chunk_idx)
    pub(crate) by_chunk: HashMap<String, (usize, usize)>,
    /// module → documents 下标
    pub(crate) by_module: HashMap<String, usize>,
    /// (function, arity) → 含该函数的 documents 下标（无模块名查询免全表扫描，P1-2）
    pub(crate) by_function: HashMap<(String, usize), Vec<usize>>,
    /// module → 调用边去重后的依赖模块列表（免每次 O(总边数) 扫描，P1-2）
    pub(crate) module_deps_map: HashMap<String, Vec<String>>,
}

#[derive(Clone, Copy)]
struct SearchFields {
    file: Field,
    module: Field,
    body: Field,
}

/// 调用边提取逻辑版本；升级 tree-sitter 查询后递增，迫使旧缓存重解析。
const CALL_EXTRACT_VERSION: u32 = 2;

#[derive(Debug, Deserialize)]
struct IndexRequest {
    path: String,
    /// true 时忽略 state.json 缓存，全量重解析（aliCore 升级后应用）。
    #[serde(default)]
    force_reparse: bool,
}

#[derive(Debug, Deserialize)]
struct SearchRequest {
    query: String,
    limit: Option<usize>,
    module: Option<String>,
    function: Option<String>,
    arity: Option<usize>,
    mode: Option<String>,
}

#[derive(Debug, Deserialize)]
struct GraphQuery {
    module: Option<String>,
    function: String,
    arity: usize,
}

#[derive(Debug, Serialize)]
struct GraphEdgesResponse {
    edges: Vec<CallEdge>,
}

#[derive(Debug, Deserialize)]
struct SymbolRequest {
    module: Option<String>,
    function: String,
    arity: usize,
}

#[derive(Debug, Deserialize)]
struct ModuleRequest {
    module: String,
}

#[derive(Debug, Deserialize)]
struct ModulesListRequest {
    /// 模块名 / 文件路径子串过滤（大小写不敏感）
    #[serde(default)]
    q: Option<String>,
    #[serde(default = "default_modules_limit")]
    limit: usize,
    #[serde(default)]
    offset: usize,
}

fn default_modules_limit() -> usize {
    100
}

#[derive(Debug, Serialize)]
struct ModuleListItem {
    module: String,
    file: String,
    functions: usize,
    exports: usize,
    calls: usize,
    /// `to_module != from_module` 的调用边数（验证远程 MFA 提取是否正常）
    remote_calls: usize,
}

#[derive(Debug, Serialize)]
struct ModulesListResponse {
    total: usize,
    offset: usize,
    limit: usize,
    modules: Vec<ModuleListItem>,
    /// 全索引远程调用边总数（便于一眼看出远程提取是否异常偏低）
    remote_calls_total: usize,
    call_edges_total: usize,
}

#[derive(Debug, Serialize)]
struct HealthResponse {
    status: &'static str,
    engine: &'static str,
    qdrant_configured: bool,
    embedding_configured: bool,
    index_ready: bool,
    index_files: usize,
    index_symbols: usize,
    embedding_vectors: usize,
    memory_vectors: usize,
    /// 记忆向量计数来源：`"qdrant"` 或 `"local"`，便于区分 0 是"真的没有"还是"没读到"。
    memory_vectors_source: &'static str,
    last_index_at: u64,
    indexing: bool,
}

#[derive(Debug, Serialize)]
struct IndexStatusResponse {
    ready: bool,
    indexing: bool,
    last_index_at: u64,
    last_index_root: String,
    /// 扫盘进度（含已跳过）；indexing=true 且 walk_seen 长期不动 → 可能卡在 IO
    #[serde(default)]
    walk_seen: usize,
    files: usize,
    symbols: usize,
    erl_files: usize,
    hrl_files: usize,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    by_extension: BTreeMap<String, usize>,
    configured_extensions: Vec<String>,
    /// 扩展名 → chunker 模式（treeSitter / treeSitterHrl / lineBased）。
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    chunker_coverage: BTreeMap<String, Vec<String>>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    phase: String,
    #[serde(default)]
    pending_total: usize,
    #[serde(default)]
    parsed_done: usize,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    last_file: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    slow_files: Vec<SlowFileInfo>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    busy_files: Vec<SlowFileInfo>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    timed_out_files: Vec<SlowFileInfo>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    last_error: String,
    /// 当前 aliCore 调用边提取版本；索引内文档版本低于此值时需 force reparse。
    call_extract_version: u32,
    /// 内存索引中 call_extract_version 过低的文档数（>0 表示 callers 可能仍是旧数据）。
    #[serde(default)]
    stale_call_extract_docs: usize,
}

#[derive(Debug, Serialize)]
struct IndexResponse {
    root: String,
    files: usize,
    symbols: usize,
    updated_files: usize,
    skipped_files: usize,
    removed_files: usize,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    warnings: Vec<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    by_extension: BTreeMap<String, usize>,
}

#[derive(Debug, Serialize)]
struct SearchResponse {
    query: String,
    hits: Vec<SearchHit>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    warnings: Vec<String>,
}

#[derive(Debug, Serialize)]
struct SymbolResponse {
    symbol: Option<FunctionSymbol>,
}

#[derive(Debug, Serialize)]
struct ModuleSymbolsResponse {
    module: String,
    document: Option<ModuleSymbols>,
}

/// Port `/module_deps`：返回某模块通过调用边依赖的其它模块列表（去重）。
#[derive(Debug, Serialize)]
struct ModuleDepsResponse {
    module: String,
    deps: Vec<String>,
}

#[derive(Debug, Serialize)]
struct CallGraphResponse {
    calls: Vec<CallEdge>,
}

#[derive(Debug, Serialize)]
struct EmbeddingSchemaResponse {
    collection: &'static str,
    vector_name: &'static str,
    vector_size: Option<usize>,
    payload_fields: Vec<&'static str>,
    chunks: Vec<FunctionChunk>,
}

#[derive(Debug, Deserialize)]
struct MemoryUpsertRequest {
    id: i64,
    content: String,
}

#[derive(Debug, Serialize)]
struct MemoryUpsertResponse {
    ok: bool,
    id: i64,
    reason: Option<String>,
}

#[derive(Debug, Deserialize)]
struct MemorySearchRequest {
    query: String,
    limit: Option<usize>,
}

#[derive(Debug, Serialize)]
struct MemorySearchResponse {
    hits: Vec<MemoryHit>,
}

#[derive(Debug, Serialize)]
struct MemoryHit {
    id: i64,
    score: f32,
}

#[derive(Debug, Deserialize)]
struct MemoryDeleteRequest {
    id: i64,
}

#[derive(Debug, Serialize)]
struct MemoryDeleteResponse {
    ok: bool,
    id: i64,
    reason: Option<String>,
}

#[derive(Debug, Deserialize)]
struct UnifiedSearchRequest {
    query: String,
    limit: Option<usize>,
}

#[derive(Debug, Serialize)]
struct UnifiedSearchResponse {
    query: String,
    code_hits: Vec<SearchHit>,
    memory_hits: Vec<MemoryHit>,
}

#[derive(Debug, Serialize, Clone)]
pub struct SearchHit {
    file: String,
    module: Option<String>,
    score: f32,
    functions: Vec<FunctionSymbol>,
    exports: Vec<FaSymbol>,
    records: Vec<NamedSymbol>,
    macros: Vec<NamedSymbol>,
    snippets: Vec<Snippet>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub(crate) struct CodeDocument {
    pub(crate) file: String,
    pub(crate) module: Option<String>,
    /// 运行时/落盘均不序列化正文：persist 零拷贝，启动后靠 effective_body 按需读盘。
    #[serde(default, skip_serializing)]
    pub(crate) body: String,
    pub(crate) functions: Vec<FunctionSymbol>,
    pub(crate) exports: Vec<FaSymbol>,
    pub(crate) specs: Vec<FaSymbol>,
    pub(crate) callbacks: Vec<FaSymbol>,
    pub(crate) records: Vec<NamedSymbol>,
    pub(crate) macros: Vec<NamedSymbol>,
    pub(crate) calls: Vec<CallEdge>,
    pub(crate) chunks: Vec<FunctionChunk>,
    /// `-behaviour(Behaviour).` 声明列表（如 gen_server/supervisor）。
    #[serde(default)]
    pub(crate) behaviours: Vec<String>,
    /// 测试用例关联（仅 `_tests.erl` / `_test.erl` 文件提取）。
    #[serde(default)]
    pub(crate) test_cases: Vec<TestCase>,
    /// 技术债标记（`%% TODO` / `%% FIXME` / `%% HACK` / `%% XXX`）。
    #[serde(default)]
    pub(crate) tech_debt: Vec<TechDebtMark>,
    /// 解析期提取的数据源调用点；`None` 表示尚未扫描（旧 state.json），
    /// `Some`（可为 empty）表示已扫描，索引重建时可免读盘。
    #[serde(default)]
    pub(crate) data_sources: Option<Vec<data_flow::DataSourceCall>>,
    #[serde(default)]
    pub(crate) file_hash: String,
    #[serde(default)]
    pub(crate) file_mtime: u64,
    /// 文件字节大小，与 `file_mtime` 一起做增量索引的快速预筛。
    #[serde(default)]
    pub(crate) file_size: u64,
    /// 调用边提取版本；低于 `CALL_EXTRACT_VERSION` 时强制重解析该文件。
    #[serde(default)]
    pub(crate) call_extract_version: u32,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub(crate) struct FunctionSymbol {
    pub(crate) name: String,
    pub(crate) arity: usize,
    pub(crate) line: usize,
    pub(crate) start_line: usize,
    pub(crate) end_line: usize,
    pub(crate) clauses: Vec<ClauseRange>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub(crate) struct ClauseRange {
    pub(crate) start_line: usize,
    pub(crate) end_line: usize,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
struct FaSymbol {
    name: String,
    arity: usize,
    line: usize,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
struct NamedSymbol {
    name: String,
    line: usize,
}

/// 测试用例与被测函数的关联（EUnit `foo_test` / `foo_test_` → `foo/N`）。
#[derive(Debug, Serialize, Deserialize, Clone)]
struct TestCase {
    test_function: String,
    test_arity: usize,
    target_function: String,
    target_arity: usize,
    line: usize,
}

/// 技术债标记：从 `%% TODO` / `%% FIXME` 等注释中提取。
#[derive(Debug, Serialize, Deserialize, Clone)]
struct TechDebtMark {
    /// 标记类型小写形式：todo / fixme / hack / xxx。
    kind: String,
    line: usize,
    text: String,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub(crate) struct CallEdge {
    pub(crate) from_module: Option<String>,
    pub(crate) from_function: Option<String>,
    #[serde(default)]
    pub(crate) from_arity: usize,
    pub(crate) to_module: Option<String>,
    pub(crate) to_function: String,
    pub(crate) arity: usize,
    pub(crate) line: usize,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct CallGraphIndex {
    /// 全部调用边（含墓碑）；下标即边 id。
    edges: Vec<CallEdge>,
    /// 边是否存活：按文件增量更新时旧边置 false，查询时跳过。
    live: Vec<bool>,
    /// callee 键 `module:fun/arity` → 边 id 列表
    by_callee: HashMap<String, Vec<u32>>,
    /// caller 键 `module:fun/arity` → 边 id 列表
    by_caller: HashMap<String, Vec<u32>>,
    /// 文件 → 边 id 列表（增量维护用）
    by_file_edges: HashMap<String, Vec<u32>>,
    /// 墓碑计数；占比过高时压缩重建，避免无限膨胀。
    dead: usize,
}

impl CallGraphIndex {
    /// 从所有文档的 `calls` 边构建调用边索引。
    ///
    /// 轻量实现（原 petgraph `DiGraph<String, u32>` 的替代）：每条边只做
    /// 2 次键格式化 + 3 次 HashMap push，不再为每个节点克隆 2-3 份 String，
    /// 大仓全量重建成本约降一个数量级（原 P0-1）。
    fn from_documents(documents: &[CodeDocument]) -> Self {
        let mut idx = Self::default();
        let total: usize = documents.iter().map(|doc| doc.calls.len()).sum();
        idx.edges.reserve(total);
        idx.live.reserve(total);
        for doc in documents {
            idx.insert_file_edges(&doc.file, &doc.calls);
        }
        idx
    }

    /// 追加某文件的调用边。
    fn insert_file_edges(&mut self, file: &str, calls: &[CallEdge]) {
        if calls.is_empty() {
            return;
        }
        let mut ids = Vec::with_capacity(calls.len());
        for edge in calls {
            let id = self.edges.len() as u32;
            self.edges.push(edge.clone());
            self.live.push(true);
            let from_key = node_key(
                edge.from_module.as_deref(),
                edge.from_function.as_deref().unwrap_or("_"),
                edge.from_arity,
            );
            let to_key = node_key(edge.to_module.as_deref(), &edge.to_function, edge.arity);
            self.by_caller.entry(from_key).or_default().push(id);
            self.by_callee.entry(to_key).or_default().push(id);
            ids.push(id);
        }
        self.by_file_edges.insert(file.to_string(), ids);
    }

    /// 墓碑化某文件的全部旧边。
    fn remove_file_edges(&mut self, file: &str) {
        let Some(ids) = self.by_file_edges.remove(file) else {
            return;
        };
        for id in ids {
            if let Some(slot) = self.live.get_mut(id as usize) {
                if *slot {
                    *slot = false;
                    self.dead += 1;
                }
            }
        }
    }

    /// 增量更新：某文件内容变化时，只替换该文件的边，不再全量重建。
    /// 墓碑占比过高时压缩（重建边表与索引映射）。
    #[allow(dead_code)]
    fn update_file_edges(&mut self, file: &str, calls: &[CallEdge]) {
        self.remove_file_edges(file);
        self.insert_file_edges(file, calls);
        if self.dead > 1024 && self.dead * 2 > self.edges.len() {
            self.compact();
        }
    }

    /// 压缩：丢弃墓碑边，按 old→new id 映射重建全部键索引与文件映射。
    fn compact(&mut self) {
        let mut old_to_new = vec![u32::MAX; self.edges.len()];
        let mut edges = Vec::with_capacity(self.edges.len() - self.dead);
        let mut by_callee: HashMap<String, Vec<u32>> = HashMap::new();
        let mut by_caller: HashMap<String, Vec<u32>> = HashMap::new();
        for (old_id, edge) in self.edges.iter().enumerate() {
            if !self.live[old_id] {
                continue;
            }
            let id = edges.len() as u32;
            old_to_new[old_id] = id;
            let from_key = node_key(
                edge.from_module.as_deref(),
                edge.from_function.as_deref().unwrap_or("_"),
                edge.from_arity,
            );
            let to_key = node_key(edge.to_module.as_deref(), &edge.to_function, edge.arity);
            by_caller.entry(from_key).or_default().push(id);
            by_callee.entry(to_key).or_default().push(id);
            edges.push(edge.clone());
        }
        let mut by_file_edges: HashMap<String, Vec<u32>> =
            HashMap::with_capacity(self.by_file_edges.len());
        for (file, ids) in &self.by_file_edges {
            let kept: Vec<u32> = ids
                .iter()
                .filter_map(|old| {
                    let new_id = old_to_new[*old as usize];
                    (new_id != u32::MAX).then_some(new_id)
                })
                .collect();
            if !kept.is_empty() {
                by_file_edges.insert(file.clone(), kept);
            }
        }
        self.edges = edges;
        self.live = vec![true; self.edges.len()];
        self.by_callee = by_callee;
        self.by_caller = by_caller;
        self.by_file_edges = by_file_edges;
        self.dead = 0;
    }

    /// 返回图中全部存活调用边。
    fn all_edges(&self) -> Vec<CallEdge> {
        self.edges
            .iter()
            .enumerate()
            .filter(|(id, _)| self.live[*id])
            .map(|(_, edge)| edge.clone())
            .collect()
    }

    /// 查询谁调用了 `module:function/arity`（callers）。
    pub(crate) fn callers(&self, module: Option<&str>, function: &str, arity: usize) -> Vec<CallEdge> {
        let key = node_key(module, function, arity);
        self.collect_live(self.by_callee.get(&key))
    }

    /// 查询 `module:function/arity` 调用了谁（callees）。
    fn callees(&self, module: Option<&str>, function: &str, arity: usize) -> Vec<CallEdge> {
        let key = node_key(module, function, arity);
        self.collect_live(self.by_caller.get(&key))
    }

    fn collect_live(&self, ids: Option<&Vec<u32>>) -> Vec<CallEdge> {
        let Some(ids) = ids else {
            return Vec::new();
        };
        ids.iter()
            .filter(|id| self.live[**id as usize])
            .map(|id| self.edges[*id as usize].clone())
            .collect()
    }
}

/// 调用图节点唯一键：`module:fun/arity`；无模块时用 `_` 占位。
fn node_key(module: Option<&str>, function: &str, arity: usize) -> String {
    match module {
        Some(m) if !m.is_empty() => format!("{}:{}/{}", m, function, arity),
        _ => format!("_:{}/{}", function, arity),
    }
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct FunctionChunk {
    id: String,
    file: String,
    module: Option<String>,
    function: String,
    arity: usize,
    start_line: usize,
    end_line: usize,
    hash: String,
}

#[derive(Debug, Serialize, Clone)]
struct ModuleSymbols {
    file: String,
    module: Option<String>,
    functions: Vec<FunctionSymbol>,
    exports: Vec<FaSymbol>,
    specs: Vec<FaSymbol>,
    callbacks: Vec<FaSymbol>,
    records: Vec<NamedSymbol>,
    macros: Vec<NamedSymbol>,
    calls: Vec<CallEdge>,
    chunks: Vec<FunctionChunk>,
    #[serde(default)]
    behaviours: Vec<String>,
    #[serde(default)]
    test_cases: Vec<TestCase>,
    #[serde(default)]
    tech_debt: Vec<TechDebtMark>,
}

#[derive(Debug, Serialize, Clone)]
struct Snippet {
    line: usize,
    text: String,
}

/// 入口：初始化日志与 Tokio runtime，加载状态后进入 Port 阻塞循环。
///
/// 仅支持 `--port` 模式（HTTP 服务已移除，由 Erlang eWSrv 对外提供 Web）。
///
/// 优雅关闭：
/// - Port 模式下，Erlang 关闭 Port 时 stdin EOF，循环正常退出
/// - 进程收到 SIGINT/SIGTERM 时（如开发期手动运行），tokio::signal 捕获后
///   触发 shutdown，让 `run_blocking` 在当前请求完成后退出
fn main() -> Result<()> {
    // Erlang 只传 `--ali-*=` args；此处写入进程内 env，供现有读配置代码使用。
    apply_ali_cli_overrides();

    // 默认只打 error，避免 tantivy INFO 刷屏抢 Erlang shell；
    // 排查时由 `--ali-rust-log=`（core.debugLog）或手动 export RUST_LOG。
    let level = match std::env::var("RUST_LOG") {
        Ok(v) => match v.to_ascii_lowercase().as_str() {
            "" | "error" | "off" | "false" => tracing::Level::ERROR,
            "warn" | "warning" => tracing::Level::WARN,
            "debug" | "trace" => tracing::Level::DEBUG,
            _ => tracing::Level::INFO,
        },
        Err(_) => tracing::Level::ERROR,
    };
    tracing_subscriber::fmt()
        .with_max_level(level)
        .with_ansi(false)
        .with_writer(std::io::stderr)
        .init();

    // 多 inflight 依赖多线程 runtime；ALI_CORE_WORKER_THREADS 可覆盖默认值。
    // 未设置时默认 cores/2（至少 2），避免与 rayon 索引线程过度订阅。
    let mut builder = tokio::runtime::Builder::new_multi_thread();
    builder.enable_all();
    if let Ok(n) = std::env::var("ALI_CORE_WORKER_THREADS") {
        if let Ok(n) = n.parse::<usize>() {
            if n > 0 {
                builder.worker_threads(n);
            }
        }
    } else {
        let cores = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(4);
        builder.worker_threads((cores / 2).max(2));
    }
    let rt = builder.build().context("failed to create tokio runtime")?;
    let state = rt.block_on(bootstrap_state(&rt))?;

    // 信号：取消令牌并等待索引到安全点，再退出（避免打断 Tantivy commit）。
    let shutdown_state = state.clone();
    rt.spawn(async move {
        use tokio::signal;
        #[cfg(unix)]
        {
            let _ = signal::unix::signal(signal::unix::SignalKind::terminate())
                .expect("install SIGTERM handler")
                .recv()
                .await;
        }
        #[cfg(not(unix))]
        {
            let _ = signal::ctrl_c().await;
        }
        info!("aliCore received shutdown signal; cancelling in-flight index");
        shutdown_state.shutdown.cancel();
        shutdown_state.index_cancel.lock().await.cancel();
        // 最多等 120s 让当前索引在安全点结束（与 port EOF 排空一致）。
        let deadline = Instant::now() + Duration::from_secs(120);
        while Instant::now() < deadline {
            if !shutdown_state.index_meta.read().await.indexing {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        if shutdown_state.index_meta.read().await.indexing {
            tracing::warn!("shutdown: index still running after wait; exiting anyway");
        } else {
            info!("aliCore shutdown: index idle, exiting");
        }
        std::process::exit(0);
    });

    info!(
        "aliCore running in Erlang port mode root={} ignore={}",
        std::env::var("ALI_ROOT").unwrap_or_else(|_| ".".into()),
        std::env::var("ALI_INDEX_IGNORE").unwrap_or_else(|_| "(fallback)".into())
    );
    port::run_blocking(state, &rt)
}

/// 解析 `--ali-foo-bar=value` → 进程内环境变量（覆盖已有值）。
/// 一般映射为 `ALI_FOO_BAR`；`--ali-rust-log=` 特例写入 `RUST_LOG`。
/// Erlang 侧契约只认 args，不注入 env。
fn apply_ali_cli_overrides() {
    for arg in std::env::args().skip(1) {
        let Some(rest) = arg.strip_prefix("--ali-") else {
            continue;
        };
        let Some((key, value)) = rest.split_once('=') else {
            continue;
        };
        if key.is_empty() {
            continue;
        }
        let env_key = if key == "rust-log" {
            "RUST_LOG".to_string()
        } else {
            format!(
                "ALI_{}",
                key.replace('-', "_").to_ascii_uppercase()
            )
        };
        // SAFETY: 仅在进程启动最早阶段、多线程 runtime 创建前调用。
        unsafe { std::env::set_var(env_key, value) };
    }
}

/// 启动时打开 SQLite、组装 [`AppState`]，并把索引/向量库加载挪到后台 warm-up。
///
/// P0-5 修复：原实现在此同步完成「读 state.json → 全量 JSON 反序列化 → 打开
/// Tantivy → 全量建调用图/DataSourceIndex」，大项目可达分钟级，而 Port 尚未开始
/// 读 stdin——Erlang 侧启动探测（3×300ms）会误判 core 启动失败。现在 bootstrap
/// 只做毫秒级初始化，Port 循环立即就绪；索引加载在后台进行，期间 `/health` 报
/// `indexing=true`，搜索类请求返回 "index is empty" 提示先触发 /index。
async fn bootstrap_state(rt: &tokio::runtime::Runtime) -> Result<AppState> {
    let qdrant_url = std::env::var("ALI_QDRANT_URL").ok();
    let db = Arc::new(LocalDb::open().context("failed to open embedded database")?);
    let http_client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(60))
        .build()
        .context("failed to build shared http client")?;
    let state = AppState {
        index: Arc::new(RwLock::new(None)),
        embeddings: Arc::new(RwLock::new(Arc::new(EmbeddingStore::default()))),
        qdrant_url,
        db,
        index_meta: Arc::new(RwLock::new(IndexMeta::default())),
        pending_index: Arc::new(tokio::sync::Mutex::new(std::collections::VecDeque::new())),
        http_client,
        qdrant: Arc::new(RwLock::new(None)),
        shutdown: CancellationToken::new(),
        index_cancel: Arc::new(tokio::sync::Mutex::new(CancellationToken::new())),
        qdrant_circuit: Arc::new(Mutex::new(QdrantCircuit {
            consecutive_failures: 0,
            open_until: None,
        })),
    };

    // 后台 warm-up：加载持久化索引与向量库。
    // 注意：不要占用 meta.indexing——否则与真实 /index 抢标志，warm-up 结束时
    // finish_index_session 会把正在跑的索引误标成 indexing=false。
    let warm = state.clone();
    rt.spawn(async move {
        {
            let mut meta = warm.index_meta.write().await;
            if meta.phase.is_empty() {
                meta.phase = "warmup".into();
            }
            // walk_seen 置 1：避免 Erlang ensureIndex 的 stuck 判定在空库启动时误杀。
            if meta.walk_seen == 0 {
                meta.walk_seen = 1;
            }
        }
        let loaded = tokio::task::spawn_blocking(|| {
            let index = load_persisted_index();
            let store = load_store();
            (index, store)
        })
        .await;
        match loaded {
            Ok((index_result, store_result)) => {
                if let Ok(Some(search_index)) = index_result {
                    let files = search_index.documents.len();
                    let symbols = search_index
                        .documents
                        .iter()
                        .map(|doc| doc.functions.len())
                        .sum();
                    let by_extension = extension_counts_from_documents(&search_index.documents);
                    *warm.index.write().await = Some(Arc::new(search_index));
                    {
                        let mut meta = warm.index_meta.write().await;
                        meta.files = files;
                        meta.symbols = symbols;
                        meta.by_extension = by_extension.clone();
                        meta.erl_files = count_extension(&by_extension, "erl");
                        meta.hrl_files = count_extension(&by_extension, "hrl");
                    }
                    info!("warm-up loaded persisted index with {files} files");
                } else if let Err(err) = index_result {
                    tracing::warn!("warm-up load index skipped: {err:#}");
                }
                if let Ok(store) = store_result {
                    if !store.vectors.is_empty() {
                        *warm.embeddings.write().await = Arc::new(store);
                        info!("warm-up loaded persisted embeddings");
                    }
                }
            }
            Err(join_err) => {
                tracing::warn!("warm-up load join error: {join_err}");
            }
        }
        {
            let mut meta = warm.index_meta.write().await;
            if meta.phase == "warmup" {
                meta.phase.clear();
            }
        }
    });

    Ok(state)
}

/// Port `/db/status`：返回嵌入式 SQLite 路径与启用状态。
async fn db_status(state: &AppState) -> DbStatusResponse {
    state.db.status()
}

/// 获取或懒初始化 Qdrant 客户端。
///
/// 首次调用时按 `state.qdrant_url` 建立连接并缓存到 `state.qdrant`；
/// 后续调用直接复用已有连接，避免每次请求重建 gRPC 通道。
/// 连接在写锁外完成，仅插入时短持写锁，避免连接延迟阻塞其它读者。
/// 熔断开启或连接失败时返回 `None`，调用方按本地 fallback 处理。
async fn qdrant_client(state: &AppState) -> Option<QdrantStore> {
    let url = state.qdrant_url.as_deref()?;
    {
        let circuit = embedding::lock_or_recover(&state.qdrant_circuit);
        if !circuit.allow() {
            return None;
        }
    }
    {
        let guard = state.qdrant.read().await;
        if let Some(client) = guard.as_ref() {
            return Some(client.clone());
        }
    }
    // 连接放在写锁外；await 期间其它任务可能已完成初始化。
    let connected = match QdrantStore::connect(url).await {
        Ok(client) => {
            embedding::lock_or_recover(&state.qdrant_circuit).on_ok();
            client
        }
        Err(err) => {
            tracing::warn!("qdrant connect skipped: {err}");
            embedding::lock_or_recover(&state.qdrant_circuit).on_err();
            return None;
        }
    };
    let mut guard = state.qdrant.write().await;
    if let Some(client) = guard.as_ref() {
        return Some(client.clone());
    }
    *guard = Some(connected.clone());
    Some(connected)
}

async fn qdrant_note_ok(state: &AppState) {
    embedding::lock_or_recover(&state.qdrant_circuit).on_ok();
}

async fn qdrant_note_err(state: &AppState) {
    embedding::lock_or_recover(&state.qdrant_circuit).on_err();
    *state.qdrant.write().await = None;
}

/// 异步路径上把 embeddings 落盘放到 blocking 池，避免同步 IO 饿死 tokio worker。
async fn persist_store_async(store: Arc<EmbeddingStore>) -> Result<()> {
    tokio::task::spawn_blocking(move || persist_store(&store))
        .await
        .map_err(|e| anyhow!("persist_store join error: {e}"))?
}

/// Port `/index/cancel`：取消当前索引任务（安全点退出，不硬杀 commit）。
async fn cancel_index(state: &AppState) -> serde_json::Value {
    state.index_cancel.lock().await.cancel();
    let indexing = state.index_meta.read().await.indexing;
    serde_json::json!({ "ok": true, "indexing": indexing })
}

/// Port `/db/query`：执行参数化 SQL（read/write 模式由请求体指定）。
async fn db_query(state: &AppState, req: DbQueryRequest) -> Result<DbQueryResponse> {
    state.db.query(&req)
}

/// Port `/health`：汇总索引、向量、Qdrant、Embedding 等就绪信息。
async fn health(state: &AppState) -> HealthResponse {
    // 先在持锁作用域内取完所有本地计数，随后释放锁再做可能较慢的 Qdrant 网络调用，
    // 避免读锁跨网络 I/O 阻塞索引写入。
    let (index_ready, index_files, index_symbols, embedding_vectors, local_memory_vectors) = {
        let index_guard = state.index.read().await;
        let embeddings = state.embeddings.read().await;
        let index_files = index_guard.as_ref().map(|index| index.documents.len()).unwrap_or(0);
        let index_symbols = index_guard
            .as_ref()
            .map(|index| index.documents.iter().map(|doc| doc.functions.len()).sum())
            .unwrap_or(0);
        let embedding_vectors = embeddings
            .vectors
            .keys()
            .filter(|key| !key.starts_with("memory:"))
            .count();
        let local_memory_vectors = embeddings
            .vectors
            .keys()
            .filter(|key| key.starts_with("memory:"))
            .count();
        (index_guard.is_some(), index_files, index_symbols, embedding_vectors, local_memory_vectors)
    };
    let (last_index_at, indexing) = {
        let meta = state.index_meta.read().await;
        (meta.last_index_at, meta.indexing)
    };
    // Qdrant 模式下记忆存在 Qdrant，本地库通常为 0；尽力从 Qdrant 取真实计数，
    // 取不到（连接失败等）时回退本地计数并标注来源。
    let (memory_vectors, memory_vectors_source) = if state.qdrant_url.is_some() {
        match qdrant_client(state).await {
            Some(qdrant) => match qdrant.count_memories().await {
                Ok(count) => {
                    qdrant_note_ok(state).await;
                    (count, "qdrant")
                }
                Err(err) => {
                    info!("qdrant memory count failed, reporting local: {err}");
                    qdrant_note_err(state).await;
                    (local_memory_vectors, "local")
                }
            },
            None => (local_memory_vectors, "local"),
        }
    } else {
        (local_memory_vectors, "local")
    };
    HealthResponse {
        status: "ok",
        engine: "aliCore",
        qdrant_configured: state.qdrant_url.is_some(),
        embedding_configured: EmbeddingConfig::from_env().is_some(),
        index_ready,
        index_files,
        index_symbols,
        embedding_vectors,
        memory_vectors,
        memory_vectors_source,
        last_index_at,
        indexing,
    }
}

/// Port `/index/status`：返回索引是否就绪、文件统计及配置的后缀列表。
async fn index_status(state: &AppState) -> IndexStatusResponse {
    let meta = state.index_meta.read().await.clone();
    let ready = state.index.read().await.is_some();
    let stale_call_extract_docs = state
        .index
        .read()
        .await
        .as_ref()
        .map(|idx| {
            idx.documents
                .iter()
                .filter(|d| d.call_extract_version < CALL_EXTRACT_VERSION)
                .count()
        })
        .unwrap_or(0);
    let exts = ignore::IndexExtensions::from_env();
    IndexStatusResponse {
        ready,
        indexing: meta.indexing,
        last_index_at: meta.last_index_at,
        last_index_root: meta.last_index_root,
        walk_seen: meta.walk_seen,
        files: meta.files,
        symbols: meta.symbols,
        erl_files: meta.erl_files,
        hrl_files: meta.hrl_files,
        by_extension: meta.by_extension,
        configured_extensions: exts.as_vec(),
        chunker_coverage: exts
            .chunker_coverage()
            .into_iter()
            .map(|(k, v)| (k.to_string(), v))
            .collect(),
        phase: meta.phase,
        pending_total: meta.pending_total,
        parsed_done: meta.parsed_done,
        last_file: meta.last_file,
        slow_files: meta.slow_files,
        busy_files: meta.busy_files,
        timed_out_files: meta.timed_out_files,
        last_error: meta.last_error,
        call_extract_version: CALL_EXTRACT_VERSION,
        stale_call_extract_docs,
    }
}

/// 索引入口：可同步或异步（`ALI_INDEX_ASYNC`）。异步时立即返回 job 已启动。
/// 若已有索引在跑，将路径入队，完成后自动续跑（不再 already_indexing 丢请求）。
async fn index_project(state: &AppState, req: IndexRequest) -> Result<IndexResponse> {
    {
        let mut meta = state.index_meta.write().await;
        if meta.indexing {
            drop(meta);
            let mut q = state.pending_index.lock().await;
            if !q.iter().any(|p| p == &req.path) {
                q.push_back(req.path.clone());
            }
            let queued = q.len();
            drop(q);
            return Ok(IndexResponse {
                root: req.path,
                files: state.index_meta.read().await.files,
                symbols: state.index_meta.read().await.symbols,
                updated_files: 0,
                skipped_files: 0,
                removed_files: 0,
                warnings: vec![format!("index_queued:{queued}")],
                by_extension: state.index_meta.read().await.by_extension.clone(),
            });
        }
        if index_async_enabled() {
            meta.indexing = true;
            meta.last_index_root = req.path.clone();
            meta.walk_seen = 0;
            drop(meta);
            let state2 = state.clone();
            let path = req.path.clone();
            tokio::spawn(async move {
                // indexing 在整段（首 job + drain）期间保持 true，结束后再清除。
                let result = run_index_job(&state2, IndexRequest { path, force_reparse: false }).await;
                if let Err(err) = &result {
                    let msg = format!("{err:#}");
                    tracing::warn!("background index failed: {msg}");
                    eprintln!("[aliCore] INDEX_FAILED: {msg}");
                    let mut meta = state2.index_meta.write().await;
                    meta.phase = "failed".into();
                    meta.last_error = msg;
                }
                finish_index_session(&state2).await;
            });
            return Ok(IndexResponse {
                root: req.path,
                files: 0,
                symbols: 0,
                updated_files: 0,
                skipped_files: 0,
                removed_files: 0,
                warnings: vec!["index_started_in_background".to_string()],
                by_extension: BTreeMap::new(),
            });
        }
    }

    // 同步路径：整段索引期间持有 indexing，避免与异步请求并发。
    {
        let mut meta = state.index_meta.write().await;
        meta.indexing = true;
        meta.last_index_root = req.path.clone();
        meta.walk_seen = 0;
    }
    let result = run_index_job(state, req).await;
    if let Err(err) = &result {
        let msg = format!("{err:#}");
        tracing::warn!("sync index failed: {msg}");
        eprintln!("[aliCore] INDEX_FAILED: {msg}");
        let mut meta = state.index_meta.write().await;
        meta.phase = "failed".into();
        meta.last_error = msg;
    }
    finish_index_session(state).await;
    result
}

/// 排空 pending 队列后再清除 indexing；drain 期间新入队的项会再走一轮，避免竞态丢任务。
async fn finish_index_session(state: &AppState) {
    loop {
        drain_pending_index(state).await;
        let mut meta = state.index_meta.write().await;
        let q = state.pending_index.lock().await;
        if q.is_empty() {
            meta.indexing = false;
            return;
        }
        // else loop — drain 期间又有新项入队
    }
}

/// 消费排队中的索引根路径（串行）。
async fn drain_pending_index(state: &AppState) {
    loop {
        let next = {
            let mut q = state.pending_index.lock().await;
            q.pop_front()
        };
        let Some(path) = next else {
            break;
        };
        if let Err(err) = run_index_job(state, IndexRequest { path: path.clone(), force_reparse: false }).await {
            let msg = format!("{err:#}");
            tracing::warn!("queued index failed for {path}: {msg}");
            eprintln!("[aliCore] INDEX_FAILED: {msg}");
            let mut meta = state.index_meta.write().await;
            meta.phase = "failed".into();
            meta.last_error = msg;
        }
    }
}

/// 包装索引任务：执行 `index_project_impl`，通过 `JoinHandle` 捕获 panic。
///
/// 注意：`indexing` 标志由调用方（`index_project` / `drain_pending_index`）统一持有，
/// 本函数不再在结束时清除，避免 drain 循环两次 job 之间的窗口被新请求插入并发索引。
async fn run_index_job(state: &AppState, req: IndexRequest) -> Result<IndexResponse> {
    let state_for_job = state.clone();
    let handle = tokio::spawn(async move { index_project_impl(&state_for_job, req).await });
    match handle.await {
        Ok(result) => result,
        Err(join_err) => Err(anyhow!("index job panicked: {join_err}")),
    }
}

/// 是否后台异步索引；`ALI_INDEX_ASYNC=false` 时同步执行。
fn index_async_enabled() -> bool {
    std::env::var("ALI_INDEX_ASYNC")
        .map(|value| value != "false" && value != "0")
        .unwrap_or(true)
}

/// hybrid 模式下是否在 BM25 候选文件内做局部向量扫描（无 Qdrant 时默认开启）。
fn hybrid_candidate_scan_enabled() -> bool {
    std::env::var("ALI_HYBRID_CANDIDATE_SCAN")
        .map(|value| value != "false" && value != "0")
        .unwrap_or(true)
}

/// 真正执行索引：扫盘 → 解析分块 → 写 Tantivy → 可选 embed / Qdrant upsert。
async fn index_project_impl(state: &AppState, req: IndexRequest) -> Result<IndexResponse> {
    let cancel = {
        let mut slot = state.index_cancel.lock().await;
        let token = state.shutdown.child_token();
        *slot = token.clone();
        token
    };
    let root = PathBuf::from(&req.path);
    tracing::info!("index start root={}", root.display());
    // 重建索引可能导致 chunk_id 映射变化；为避免查询向量与旧 chunk 错配，清空查询缓存。
    clear_query_embed_cache();
    // state.json 读盘放 blocking，避免阻塞 tokio worker。
    let existing = if req.force_reparse {
        tracing::info!("index force_reparse: ignoring persisted state.json cache");
        eprintln!("[aliCore] INDEX force_reparse=true — 全量重解析（升级调用边提取后必须跑一次）");
        Vec::new()
    } else {
        tokio::task::spawn_blocking(load_persisted_documents)
            .await
            .map_err(|e| anyhow!("load persisted documents join error: {e}"))?
    };
    if cancel.is_cancelled() {
        return Err(anyhow!("index cancelled"));
    }
    let old_hashes: HashMap<String, String> = existing
        .iter()
        .map(|d| (d.file.clone(), d.file_hash.clone()))
        .collect();
    let root_for_walk = root.clone();
    let progress = state.index_meta.clone();
    let cancel_walk = cancel.clone();
    // 扫盘是同步 CPU/IO 密集工作，必须 spawn_blocking，否则会饿死 tokio worker。
    let (documents, stats) = tokio::task::spawn_blocking(move || {
        incremental_documents_with_progress_cancel(
            &root_for_walk,
            existing,
            progress,
            Some(cancel_walk),
        )
    })
    .await
    .map_err(|e| anyhow!("index walk join error: {e}"))??;
    if cancel.is_cancelled() {
        return Err(anyhow!("index cancelled"));
    }
    let symbols = documents.iter().map(|doc| doc.functions.len()).sum();
    let mut warnings = Vec::new();
    let needs_reindex = stats.needs_reindex();

    {
        let mut meta = state.index_meta.write().await;
        meta.phase = "build".into();
        meta.last_error.clear();
    }
    tracing::info!(
        "index build start root={} docs={} needs_reindex={} updated={} removed={}",
        root.display(),
        documents.len(),
        needs_reindex,
        stats.updated,
        stats.removed
    );
    eprintln!(
        "[aliCore] INDEX_BUILD start docs={} needs_reindex={}",
        documents.len(),
        needs_reindex
    );

    // 无文件变更且内存中已有索引时，跳过 open_index（会全量重建 CallGraph/DataSource，
    // 大仓二次索引的主要 CPU 假慢来源之一）。
    let keep_existing_index = !needs_reindex && state.index.read().await.is_some();
    // Arc：build 与后续 embed 共享同一份 documents，避免再深拷贝（含正文）进 blocking。
    let documents = Arc::new(documents);
    let old_hashes = Arc::new(old_hashes);
    if !keep_existing_index {
        // Windows：内存里的 IndexReader/mmap 会锁住 index_dir，导致 rename 提升
        // staging→live 报「拒绝访问 (os error 5)」。凡会动目录的路径都先丢旧句柄
        // （含 needs_reindex，以及 open 失败回退 build）。
        *state.index.write().await = None;
        // 给并发搜索持有的 Arc 克隆一点时间释放 mmap；promote 另有重试+copy。
        tokio::time::sleep(Duration::from_millis(200)).await;
        let docs_for_blocking = Arc::clone(&documents);
        let hashes_for_blocking = Arc::clone(&old_hashes);
        let search_index = tokio::task::spawn_blocking(move || {
            if needs_reindex {
                build_index(&docs_for_blocking, Some(&hashes_for_blocking))
            } else {
                match open_index(&docs_for_blocking)? {
                    Some(idx) => Ok(idx),
                    None => build_index(&docs_for_blocking, Some(&hashes_for_blocking)).map_err(
                        |err| anyhow!("failed to open or rebuild index: {err}"),
                    ),
                }
            }
        })
        .await
        .map_err(|e| anyhow!("index build join error: {e}"))??;
        if cancel.is_cancelled() {
            return Err(anyhow!("index cancelled after tantivy build"));
        }
        *state.index.write().await = Some(Arc::new(search_index));
    } else {
        // 仅 data_sources 元数据补齐：刷新内存中的 DataSourceIndex，不动 Tantivy。
        if stats.meta_updated > 0 {
            // P0-7 修复：原 Arc::make_mut 在并发搜索持有快照时会深拷贝整份
            // SearchIndex（含全部 documents + 调用图），表现为索引收尾"卡死"。
            // 改为短窗口轮询 Arc::get_mut 原地更新；仅在极端长尾（>2s 仍有读者）
            // 时退化为整体替换，保证正确性。
            let mut ds = Some(data_flow::DataSourceIndex::from_documents(&documents));
            let mut refreshed = false;
            for _ in 0..20 {
                {
                    let mut guard = state.index.write().await;
                    if let Some(slot) = guard.as_mut() {
                        if let Some(inner) = Arc::get_mut(slot) {
                            inner.data_source_index = ds.take().expect("ds taken once");
                            refreshed = true;
                        }
                    }
                }
                if refreshed {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            if !refreshed {
                let mut guard = state.index.write().await;
                if let (Some(slot), Some(ds)) = (guard.as_mut(), ds.take()) {
                    let mut cloned = (**slot).clone();
                    cloned.data_source_index = ds;
                    *slot = Arc::new(cloned);
                    tracing::warn!("data_source_index refresh fell back to full index clone (readers held snapshot > 2s)");
                }
            }
            tracing::info!(
                "index refreshed data_source_index after meta backfill (files={})",
                stats.meta_updated
            );
        } else {
            tracing::info!(
                "index skip tantivy/callgraph rebuild (no file changes, in-memory index present)"
            );
        }
    }

    // 无变更时跳过整份 state.json 重写；data_sources 补齐仍需落盘。
    if stats.needs_persist() {
        let docs_for_persist = Arc::clone(&documents);
        tokio::task::spawn_blocking(move || persist_state(&docs_for_persist))
            .await
            .map_err(|e| anyhow!("persist state join error: {e}"))??;
    }

    if cancel.is_cancelled() {
        return Err(anyhow!("index cancelled before embedding"));
    }

    if let Some(config) = EmbeddingConfig::from_env() {
        // P0-2 修复：原实现无条件 `(*store).clone()` 整份向量库（大项目数百 MB），
        // 即使本轮没有任何 chunk 需要 embed。先做零拷贝探测：只有确有工作时才克隆。
        let (needs_embed_work, probe_model_changed) = {
            let existing_store = state.embeddings.read().await;
            let model_changed = embedding_model_changed(&existing_store, &config);
            let needs = model_changed
                || stats.removed > 0
                || embedding_work_needed(&existing_store, &documents);
            (needs, model_changed)
        };

        if !needs_embed_work {
            tracing::info!("index skip embedding (no changed/missing chunks)");
        } else {
        // 关键：先短持读锁做零拷贝探测，算出本轮需要 embed 的 chunk 与需清理的
        // 陈旧向量；只有确认确有写入时才克隆工作副本。绝不可跨 embed HTTP await
        // 持 embeddings 读锁（否则写路径与其它读者会被拖住数十分钟，表现为「索引卡住」）。
        let (chunks, chunk_bodies, stale_chunk_ids) = {
            let existing_store = state.embeddings.read().await;
            let (chunks, chunk_bodies) =
                chunks_needing_embed(&documents, &existing_store, probe_model_changed);
            let stale = stale_code_vector_ids(&existing_store, &documents);
            (chunks, chunk_bodies, stale)
        };
        let embed_noop = chunks.is_empty() && stale_chunk_ids.is_empty() && !probe_model_changed;

        if embed_noop {
            tracing::info!("index skip embedding (no changed/missing chunks)");
        } else {
            // P2：HTTP embed 期间不克隆整库向量表（峰值翻倍）。
            // 工作副本只带 chunk_hashes/model，新向量写入侧车 map；HTTP 结束后再
            // 短时 clone+merge 发布，避免跨网络 await 持有双份稠密向量。
            let (mut work, previous_hashes, base_arc) = {
                let existing_store = Arc::clone(&*state.embeddings.read().await);
                let previous_hashes = if probe_model_changed {
                    HashMap::new()
                } else {
                    existing_store.chunk_hashes.clone()
                };
                let mut work = EmbeddingStore::default();
                work.model = existing_store.model.clone();
                work.chunk_hashes = existing_store.chunk_hashes.clone();
                (work, previous_hashes, existing_store)
            };

            match embed_chunks_incremental(
                &state.http_client,
                &config,
                &chunks,
                &chunk_bodies,
                &mut work,
                Some(&cancel),
            )
            .await
            {
                Ok((embedded_count, embed_warnings)) => {
                    warnings.extend(embed_warnings);
                    let mut store = (*base_arc).clone();
                    let removed_chunk_ids = purge_stale_code_vectors(&mut store, &documents);
                    if probe_model_changed {
                        // 模型切换后旧代码向量失效；保留 memory:*，用 work 覆盖代码侧。
                        store.vectors.retain(|k, _| k.starts_with("memory:"));
                        store.vectors.extend(work.vectors);
                        store.chunk_hashes = work.chunk_hashes;
                        store.model = work.model;
                    } else {
                        store.vectors.extend(work.vectors);
                        for (id, hash) in work.chunk_hashes {
                            store.chunk_hashes.insert(id, hash);
                        }
                        if work.model.is_some() {
                            store.model = work.model;
                        }
                    }
                    store.touch_vectors();
                    let store_arc = Arc::new(store);
                    if let Err(err) = persist_store_async(Arc::clone(&store_arc)).await {
                        warnings.push(format!("embedding persist skipped: {:#}", err));
                    }
                    if let Some(qdrant) = qdrant_client(state).await {
                        if !removed_chunk_ids.is_empty() {
                            match qdrant.delete_chunks(&removed_chunk_ids).await {
                                Ok(count) => {
                                    qdrant_note_ok(state).await;
                                    info!("deleted {count} stale vectors from qdrant");
                                }
                                Err(err) => {
                                    qdrant_note_err(state).await;
                                    warnings.push(format!("qdrant delete skipped: {:#}", err))
                                }
                            }
                        }
                        if !chunks.is_empty() {
                            match qdrant
                                .upsert_changed_chunks(
                                    &chunks,
                                    &store_arc.vectors,
                                    &previous_hashes,
                                )
                                .await
                            {
                                Ok(count) => {
                                    qdrant_note_ok(state).await;
                                    info!("upserted {count} changed vectors to qdrant");
                                }
                                Err(err) => {
                                    qdrant_note_err(state).await;
                                    warnings.push(format!("qdrant upsert skipped: {:#}", err))
                                }
                            }
                        }
                    }
                    *state.embeddings.write().await = store_arc;
                    info!("embedded {embedded_count} new/changed function chunks");
                }
                Err(err) => warnings.push(format!("embedding skipped: {:#}", err)),
            }
        }
        }
    } else if stats.removed > 0 {
        // P0-2：同样先探测是否存在待清理的失效向量，有工作才克隆整库。
        let has_stale = {
            let store = state.embeddings.read().await;
            has_stale_code_vectors(&store, &documents)
        };
        if has_stale {
        let existing_store = Arc::clone(&*state.embeddings.read().await);
        let mut store = (*existing_store).clone();
        let removed_chunk_ids = purge_stale_code_vectors(&mut store, &documents);
        if !removed_chunk_ids.is_empty() {
            if let Some(qdrant) = qdrant_client(state).await {
                match qdrant.delete_chunks(&removed_chunk_ids).await {
                    Ok(_) => qdrant_note_ok(state).await,
                    Err(err) => {
                        qdrant_note_err(state).await;
                        warnings.push(format!("qdrant delete skipped: {:#}", err));
                    }
                }
            }
        }
        let store_arc = Arc::new(store);
        if let Err(err) = persist_store_async(Arc::clone(&store_arc)).await {
            warnings.push(format!("embedding purge persist skipped: {:#}", err));
        }
        *state.embeddings.write().await = store_arc;
        }
    }

    let by_extension = extension_counts_from_documents(&documents);
    {
        let mut meta = state.index_meta.write().await;
        meta.last_index_at = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_secs())
            .unwrap_or(0);
        meta.last_index_root = req.path.clone();
        meta.files = documents.len();
        meta.symbols = symbols;
        meta.by_extension = by_extension.clone();
        meta.erl_files = count_extension(&by_extension, "erl");
        meta.hrl_files = count_extension(&by_extension, "hrl");
        meta.phase = "ready".into();
        meta.last_error.clear();
    }
    eprintln!(
        "[aliCore] INDEX_READY files={} symbols={}",
        documents.len(),
        symbols
    );
    Ok(IndexResponse {
        root: req.path,
        files: documents.len(),
        symbols,
        updated_files: stats.updated,
        skipped_files: stats.skipped,
        removed_files: stats.removed,
        warnings,
        by_extension,
    })
}

/// Port `/search`：对代码索引执行 BM25 / 向量 / 混合检索。
async fn search_code(state: &AppState, req: SearchRequest) -> Result<SearchResponse> {
    // Arc 快照后立刻释放 RwLock，避免 embedding/rerank HTTP await 期间持锁。
    let index = state
        .index
        .read()
        .await
        .as_ref()
        .cloned()
        .ok_or_else(|| anyhow!("index is empty; call /index first"))?;
    let embeddings = Arc::clone(&*state.embeddings.read().await);
    let mut warnings = Vec::new();
    let hits = perform_search(state, index, &req, embeddings, &mut warnings).await?;
    Ok(SearchResponse {
        query: req.query,
        hits,
        warnings,
    })
}

/// Port `/search/unified`：同时检索代码命中与语义记忆命中。
async fn search_unified(state: &AppState, req: UnifiedSearchRequest) -> Result<UnifiedSearchResponse> {
    let limit = req.limit;
    let index_opt = state.index.read().await.as_ref().cloned();
    let embeddings = Arc::clone(&*state.embeddings.read().await);
    let code_hits = if let Some(index) = index_opt {
        let search_req = SearchRequest {
            query: req.query.clone(),
            limit,
            module: None,
            function: None,
            arity: None,
            mode: None,
        };
        let mut warnings = Vec::new();
        perform_search(state, index, &search_req, embeddings, &mut warnings).await?
    } else {
        Vec::new()
    };
    let memory_hits = memory_search(
        state,
        MemorySearchRequest {
            query: req.query.clone(),
            limit,
        },
    )
    .await?
    .hits;
    Ok(UnifiedSearchResponse {
        query: req.query,
        code_hits,
        memory_hits,
    })
}

/// 按 `req.mode`（bm25 / vector / hybrid）执行检索，可选再走 rerank。
async fn perform_search(
    state: &AppState,
    index: Arc<SearchIndex>,
    req: &SearchRequest,
    embeddings: Arc<EmbeddingStore>,
    warnings: &mut Vec<String>,
) -> Result<Vec<SearchHit>> {
    let filter = SearchFilter {
        module: req.module.clone(),
        function: req.function.clone(),
        arity: req.arity,
    };
    let limit = req.limit.unwrap_or(10).max(1).min(200);
    let qdrant_url = state.qdrant_url.as_deref();
    // 默认模式判定不仅看是否已有向量，还要看 embedding 是否可用（key/端点已配置）；
    // 否则只配 DeepSeek（无 embedding 端点）时默认 hybrid 会每次搜索整体失败（C-S4）。
    let has_vector_backend = !embeddings.vectors.is_empty() || qdrant_url.is_some();
    let embedding_available = EmbeddingConfig::from_env().is_some();
    let default_mode = if has_vector_backend && embedding_available {
        "hybrid"
    } else {
        "bm25"
    };
    let mode = req.mode.as_deref().unwrap_or(default_mode);

    let mut hits = match mode {
        "vector" if has_vector_backend => {
            let config = EmbeddingConfig::from_env().context("embedding api not configured")?;
            let query_vector = request_embedding_cached(&state.http_client, &config, &req.query).await?;
            vector_hits(state, Arc::clone(&index), Arc::clone(&embeddings), &query_vector, &req.query, limit).await?
        }
        "hybrid" if has_vector_backend => {
            // BM25 为 CPU 密集；放 blocking 线程池，避免饿死 tokio worker。
            let query = req.query.clone();
            let index_bm25 = Arc::clone(&index);
            let bm25_limit = limit * 4;
            let bm25 = tokio::task::spawn_blocking(move || index_bm25.bm25_search(&query, bm25_limit))
                .await
                .map_err(|e| anyhow!("bm25 join error: {e}"))??;
            match embed_query_for_hybrid(state, &req.query).await {
                Ok(query_vector) => {
                    let vector = if hybrid_candidate_scan_enabled() && qdrant_url.is_none() {
                        let files: Vec<String> = bm25.iter().map(|hit| hit.file.clone()).collect();
                        // P1-2：BM25 空时候选扫描会得到空向量路；回退全量向量检索。
                        if files.is_empty() {
                            vector_hits(
                                state,
                                Arc::clone(&index),
                                Arc::clone(&embeddings),
                                &query_vector,
                                &req.query,
                                limit * 2,
                            )
                            .await?
                        } else {
                            let emb = Arc::clone(&embeddings);
                            let idx = Arc::clone(&index);
                            let qv = query_vector.clone();
                            let q = req.query.clone();
                            let scan_limit = limit * 2;
                            tokio::task::spawn_blocking(move || {
                                let top = top_vector_hits_for_files(&emb, &qv, &files, scan_limit);
                                top.into_iter()
                                    .filter_map(|(chunk_id, score)| {
                                        idx.hit_from_chunk(&chunk_id, score, &q)
                                    })
                                    .collect::<Vec<_>>()
                            })
                            .await
                            .map_err(|e| anyhow!("hybrid candidate scan join error: {e}"))?
                        }
                    } else {
                        vector_hits(
                            state,
                            Arc::clone(&index),
                            Arc::clone(&embeddings),
                            &query_vector,
                            &req.query,
                            limit * 2,
                        )
                        .await?
                    };
                    merge_hybrid(bm25, vector, limit)
                }
                Err(err) => {
                    let msg = format!("hybrid embedding failed, degraded to bm25: {:#}", err);
                    info!("{msg}");
                    warnings.push(msg);
                    let mut degraded = bm25;
                    degraded.truncate(limit);
                    degraded
                }
            }
        }
        _ => {
            let query = req.query.clone();
            let index_bm25 = Arc::clone(&index);
            tokio::task::spawn_blocking(move || index_bm25.bm25_search(&query, limit))
                .await
                .map_err(|e| anyhow!("bm25 join error: {e}"))??
        }
    };

    hits.retain(|hit| index.matches_filter(hit, &filter));
    hits.truncate(limit);
    let backup = hits.clone();
    let hits = match rerank::rerank_hits(&state.http_client, &req.query, hits).await {
        Ok(reranked) => reranked,
        Err(err) => {
            info!("rerank skipped: {:#}", err);
            backup
        }
    };
    Ok(hits)
}

/// 为 hybrid 分支获取查询向量：配置缺失或 API 调用失败都返回 Err，供上层降级。
async fn embed_query_for_hybrid(state: &AppState, query: &str) -> Result<Vec<f32>> {
    let config = EmbeddingConfig::from_env().context("embedding api not configured")?;
    request_embedding_cached(&state.http_client, &config, query).await
}

/// 向量检索：优先 Qdrant，失败或为空时回退本地 `embeddings.json`。
async fn vector_hits(
    state: &AppState,
    index: Arc<SearchIndex>,
    embeddings: Arc<EmbeddingStore>,
    query_vector: &[f32],
    query: &str,
    limit: usize,
) -> Result<Vec<SearchHit>> {
    if let Some(qdrant) = qdrant_client(state).await {
        match qdrant.search(query_vector, limit).await {
            Ok(top) => {
                qdrant_note_ok(state).await;
                let hits = top
                    .into_iter()
                    .filter_map(|(chunk_id, score)| index.hit_from_chunk(&chunk_id, score, query))
                    .collect::<Vec<_>>();
                if !hits.is_empty() {
                    return Ok(hits);
                }
            }
            Err(err) => {
                tracing::warn!("qdrant search failed: {err:#}");
                qdrant_note_err(state).await;
            }
        }
    }
    let qv = query_vector.to_vec();
    let q = query.to_string();
    tokio::task::spawn_blocking(move || index.hits_from_embeddings(&qv, &embeddings, &q, limit))
        .await
        .map_err(|e| anyhow!("local vector search join error: {e}"))
}

/// Port `/symbol`：按模块/函数名/元组查找单个函数符号定义。
async fn get_symbol(state: &AppState, req: SymbolRequest) -> Result<SymbolResponse> {
    let index = state
        .index
        .read()
        .await
        .as_ref()
        .cloned()
        .ok_or_else(|| anyhow!("index is empty; call /index first"))?;
    Ok(SymbolResponse {
        symbol: index.get_symbol(req.module.as_deref(), &req.function, req.arity),
    })
}

/// Port `/module_symbols`：返回某 Erlang 模块的全部符号与 chunk 元数据。
async fn module_symbols(state: &AppState, req: ModuleRequest) -> Result<ModuleSymbolsResponse> {
    let index = state
        .index
        .read()
        .await
        .as_ref()
        .cloned()
        .ok_or_else(|| anyhow!("index is empty; call /index first"))?;
    Ok(ModuleSymbolsResponse {
        module: req.module.clone(),
        document: index.module_symbols(&req.module),
    })
}

/// Port `/modules`：列出已索引模块摘要（Web 面板校验用）。
async fn list_modules(state: &AppState, req: ModulesListRequest) -> Result<ModulesListResponse> {
    let index = state
        .index
        .read()
        .await
        .as_ref()
        .cloned()
        .ok_or_else(|| anyhow!("index is empty; call /index first"))?;
    Ok(index.list_modules(req.q.as_deref(), req.offset, req.limit.max(1).min(2000)))
}

/// Port `/module_deps`：返回某模块的模块级依赖列表（去重，不含自身）。
async fn module_deps(state: &AppState, req: ModuleRequest) -> Result<ModuleDepsResponse> {
    let index = state
        .index
        .read()
        .await
        .as_ref()
        .cloned()
        .ok_or_else(|| anyhow!("index is empty; call /index first"))?;
    Ok(ModuleDepsResponse {
        module: req.module.clone(),
        deps: index.module_deps(&req.module),
    })
}

/// Port `/call_graph`：导出全项目调用边列表。
async fn call_graph(state: &AppState) -> Result<CallGraphResponse> {
    let index = state
        .index
        .read()
        .await
        .as_ref()
        .cloned()
        .ok_or_else(|| anyhow!("index is empty; call /index first"))?;
    Ok(CallGraphResponse {
        calls: index.call_graph(),
    })
}

/// Port `/callers`：查询指定函数的调用者（谁调用了它）。
async fn get_callers(state: &AppState, req: GraphQuery) -> Result<GraphEdgesResponse> {
    let index = state
        .index
        .read()
        .await
        .as_ref()
        .cloned()
        .ok_or_else(|| anyhow!("index is empty; call /index first"))?;
    Ok(GraphEdgesResponse {
        edges: index.callers(req.module.as_deref(), &req.function, req.arity),
    })
}

/// Port `/callees`：查询指定函数调用了哪些目标。
async fn get_callees(state: &AppState, req: GraphQuery) -> Result<GraphEdgesResponse> {
    let index = state
        .index
        .read()
        .await
        .as_ref()
        .cloned()
        .ok_or_else(|| anyhow!("index is empty; call /index first"))?;
    Ok(GraphEdgesResponse {
        edges: index.callees(req.module.as_deref(), &req.function, req.arity),
    })
}

/// Port `/data_sources`：导出全项目数据源调用点（ets/mnesia/sql）。
#[derive(Debug, Serialize)]
struct DataSourcesResponse {
    sources: Vec<data_flow::DataSourceCall>,
}

async fn data_sources(state: &AppState) -> Result<DataSourcesResponse> {
    let index = state
        .index
        .read()
        .await
        .as_ref()
        .cloned()
        .ok_or_else(|| anyhow!("index is empty; call /index first"))?;
    Ok(DataSourcesResponse {
        sources: index.data_source_index.all().to_vec(),
    })
}

/// Port `/data_source_callers`：按表名反查哪些函数读这个表。
#[derive(Debug, Deserialize)]
struct DataSourceCallersRequest {
    table: String,
}

#[derive(Debug, Serialize)]
struct DataSourceCallersResponse {
    table: String,
    callers: Vec<data_flow::DataSourceCall>,
}

async fn data_source_callers(
    state: &AppState,
    req: DataSourceCallersRequest,
) -> Result<DataSourceCallersResponse> {
    let index = state
        .index
        .read()
        .await
        .as_ref()
        .cloned()
        .ok_or_else(|| anyhow!("index is empty; call /index first"))?;
    Ok(DataSourceCallersResponse {
        table: req.table.clone(),
        callers: index.data_source_index.callers_of_table(&req.table),
    })
}

/// Port `/param_sources`：对指定函数做过程内 use-def chain 分析。
#[derive(Debug, Deserialize)]
struct ParamSourcesRequest {
    module: Option<String>,
    function: String,
    arity: usize,
}

async fn param_sources(state: &AppState, req: ParamSourcesRequest) -> Result<data_flow::ParamSourceResult> {
    let index = state
        .index
        .read()
        .await
        .as_ref()
        .cloned()
        .ok_or_else(|| anyhow!("index is empty; call /index first"))?;
    // 锁已释放；effective_body 可能读盘，不得再持 RwLock。
    let Some(doc) = index.doc_by_module(req.module.as_deref()) else {
        return Err(anyhow!("module not found"));
    };
    let Some(fun) = find_function_symbol(&doc.functions, &req.function, req.arity) else {
        return Err(anyhow!("function not found"));
    };
    let body = effective_body_cached(doc);
    let body_str: &str = body.as_ref();
    Ok(data_flow::analyze_param_sources(body_str, doc.module.as_deref(), fun)?)
}

/// Port `/trace_data_flow`：跨过程递归追溯参数依赖 DAG。
#[derive(Debug, Deserialize)]
struct TraceDataFlowRequest {
    module: Option<String>,
    function: String,
    arity: usize,
    /// 追踪第几个参数（1-based）
    param_index: usize,
    #[serde(default = "default_trace_depth")]
    max_depth: usize,
    #[serde(default = "default_trace_max_nodes")]
    max_nodes: usize,
}

fn default_trace_depth() -> usize { 4 }
fn default_trace_max_nodes() -> usize { 30 }

async fn trace_data_flow_handler(
    state: &AppState,
    req: TraceDataFlowRequest,
) -> Result<data_flow::DataFlowTrace> {
    let index = state
        .index
        .read()
        .await
        .as_ref()
        .cloned()
        .ok_or_else(|| anyhow!("index is empty; call /index first"))?;
    // R4：钳制 BFS 深度/节点上限，防止 usize::MAX 让 data_flow 的队列/节点无限增长 OOM。
    let (max_depth, max_nodes) = clamp_trace_limits(req.max_depth, req.max_nodes);
    let params = data_flow::TraceParams {
        module: req.module,
        function: req.function,
        arity: req.arity,
        param_index: req.param_index,
        max_depth,
        max_nodes,
    };
    Ok(data_flow::trace_data_flow(&index, params))
}

/// 钳制 `/trace_data_flow` 的 BFS 深度/节点上限。
fn clamp_trace_limits(max_depth: usize, max_nodes: usize) -> (usize, usize) {
    (max_depth.clamp(1, 8), max_nodes.clamp(1, 500))
}

/// 按 module 名查文档（内部辅助；优先走 by_module 查找表）。
fn find_doc_by_module<'a>(
    documents: &'a [CodeDocument],
    module: Option<&str>,
) -> Option<&'a CodeDocument> {
    let m = module?;
    documents.iter().find(|d| d.module.as_deref() == Some(m))
}

fn find_function_symbol<'a>(
    functions: &'a [FunctionSymbol],
    name: &str,
    arity: usize,
) -> Option<&'a FunctionSymbol> {
    functions.iter().find(|f| f.name == name && f.arity == arity)
}

/// Port `/embedding_schema`：描述向量 collection 结构与当前全部 chunk 列表。
async fn embedding_schema(state: &AppState) -> Result<EmbeddingSchemaResponse> {
    let index = state.index.read().await.as_ref().cloned();
    let chunks = index
        .as_ref()
        .map(|idx| idx.documents.iter().flat_map(|doc| doc.chunks.clone()).collect())
        .unwrap_or_default();
    let vector_size = state
        .embeddings
        .read()
        .await
        .vectors
        .values()
        .next()
        .map(|vector| vector.len());
    Ok(EmbeddingSchemaResponse {
        collection: "ali_function_chunks",
        vector_name: "code_embedding",
        vector_size,
        payload_fields: vec![
            "chunk_id",
            "file",
            "module",
            "function",
            "arity",
            "start_line",
            "end_line",
            "hash",
        ],
        chunks,
    })
}

/// Port `/memory/upsert`：写入语义记忆向量（优先 Qdrant，失败则本地 fallback）。
async fn memory_upsert(state: &AppState, req: MemoryUpsertRequest) -> MemoryUpsertResponse {
    let Some(config) = EmbeddingConfig::from_env() else {
        return MemoryUpsertResponse {
            ok: false,
            id: req.id,
            reason: Some("embedding_not_configured".to_string()),
        };
    };
    let vector = match request_embedding_cached(&state.http_client, &config, &req.content).await {
        Ok(mut v) => {
            crate::embedding::l2_normalize(&mut v);
            v
        }
        Err(err) => {
            info!("memory upsert embedding failed: {err}");
            return MemoryUpsertResponse {
                ok: false,
                id: req.id,
                reason: Some(err.to_string()),
            };
        }
    };

    // 优先 Qdrant
    if let Some(qdrant) = qdrant_client(state).await {
        let q_ok = qdrant.ensure_memory_collection(vector.len() as u64).await.is_ok()
            && qdrant
                .upsert_memory(req.id, &req.content, &vector, None, None)
                .await
                .is_ok();
        if q_ok {
            qdrant_note_ok(state).await;
            return MemoryUpsertResponse {
                ok: true,
                id: req.id,
                reason: None,
            };
        }
        qdrant_note_err(state).await;
        info!("qdrant memory upsert failed, falling back to local store");
    }

    // fallback 本地：Arc::make_mut 写时复制，refcount=1 时原地改。
    let key = memory_key(req.id);
    let to_persist = {
        let mut guard = state.embeddings.write().await;
        let store = Arc::make_mut(&mut *guard);
        store.vectors.insert(key.clone(), vector);
        store.chunk_hashes.remove(&key);
        store.touch_vectors();
        Arc::clone(&*guard)
    };
    if let Err(err) = persist_store_async(to_persist).await {
        info!("memory persist skipped: {err}");
    }
    MemoryUpsertResponse {
        ok: true,
        id: req.id,
        reason: Some("local_fallback".to_string()),
    }
}

/// Port `/memory/search`：按查询文本做记忆向量检索。
async fn memory_search(state: &AppState, req: MemorySearchRequest) -> Result<MemorySearchResponse> {
    let Some(config) = EmbeddingConfig::from_env() else {
        return Ok(MemorySearchResponse { hits: Vec::new() });
    };
    let query_vector = request_embedding_cached(&state.http_client, &config, &req.query).await?;
    let limit = req.limit.unwrap_or(10).max(1).min(200);

    // 优先 Qdrant
    if let Some(qdrant) = qdrant_client(state).await {
        match qdrant.search_memories(&query_vector, limit).await {
            Ok(qdrant_hits) => {
                qdrant_note_ok(state).await;
                let hits: Vec<MemoryHit> = qdrant_hits
                    .into_iter()
                    .map(|h| MemoryHit {
                        id: h.id,
                        score: h.score,
                    })
                    .collect();
                if !hits.is_empty() {
                    return Ok(MemorySearchResponse { hits });
                }
            }
            Err(err) => {
                tracing::warn!("qdrant memory search failed: {err:#}");
                qdrant_note_err(state).await;
            }
        }
    }

    // fallback 本地：Arc 快照后放锁再扫描。
    // P1-4 修复：暴力余弦 / HNSW 惰性重建是 CPU 密集操作，必须进 blocking 池，
    // 否则大向量库下会卡住 tokio worker，连累全部并发请求（含 /index/status 心跳）。
    let store = Arc::clone(&*state.embeddings.read().await);
    let hits = tokio::task::spawn_blocking(move || top_memory_hits(&store, &query_vector, limit))
        .await
        .map_err(|e| anyhow!("memory search join error: {e}"))?;
    Ok(MemorySearchResponse {
        hits: hits
            .into_iter()
            .map(|(id, score)| MemoryHit { id, score })
            .collect(),
    })
}

/// Port `/memory/delete`：删除指定 id 的记忆（Qdrant + 本地 store）。
async fn memory_delete(state: &AppState, req: MemoryDeleteRequest) -> MemoryDeleteResponse {
    // `delete_points` 是幂等的、不返回是否命中；Qdrant 删除成功即视为命中，
    // 避免 Qdrant 模式下本地 store 无该 key 时误报 not_found。
    let mut qdrant_ok = false;
    if let Some(qdrant) = qdrant_client(state).await {
        match qdrant.delete_memory(req.id).await {
            Ok(()) => {
                qdrant_ok = true;
                qdrant_note_ok(state).await;
            }
            Err(err) => {
                info!("qdrant memory delete failed: {err}");
                qdrant_note_err(state).await;
            }
        }
    }

    let key = memory_key(req.id);
    let (removed, to_persist) = {
        let mut guard = state.embeddings.write().await;
        let store = Arc::make_mut(&mut *guard);
        let removed = store.vectors.remove(&key).is_some();
        if removed {
            store.chunk_hashes.remove(&key);
            store.touch_vectors();
        }
        (removed, if removed { Some(Arc::clone(&*guard)) } else { None })
    };
    if let Some(store) = to_persist {
        if let Err(err) = persist_store_async(store).await {
            info!("memory delete persist skipped: {err}");
        }
    }

    let (ok, reason) = memory_delete_result(removed, qdrant_ok);
    MemoryDeleteResponse {
        ok,
        id: req.id,
        reason,
    }
}

/// 计算 `/memory/delete` 的响应判定：本地移除成功或 Qdrant 删除成功均视为命中。
fn memory_delete_result(removed: bool, qdrant_ok: bool) -> (bool, Option<String>) {
    if removed || qdrant_ok {
        (true, None)
    } else {
        (false, Some("not_found".to_string()))
    }
}

/// 本地记忆向量的 store 键：`memory:{id}`。
fn memory_key(id: i64) -> String {
    format!("memory:{}", id)
}

/// 增量索引入口：使用环境变量中的扩展名白名单（仅单测）。
#[cfg(test)]
fn incremental_documents(root: &Path, existing: Vec<CodeDocument>) -> Result<(Vec<CodeDocument>, IncrementalStats)> {
    incremental_documents_with(root, existing, &ignore::IndexExtensions::from_env())
}

/// 带进度回写的扫盘（供 spawn_blocking 使用）；可选取消令牌。
fn incremental_documents_with_progress_cancel(
    root: &Path,
    existing: Vec<CodeDocument>,
    progress: Arc<tokio::sync::RwLock<IndexMeta>>,
    cancel: Option<CancellationToken>,
) -> Result<(Vec<CodeDocument>, IncrementalStats)> {
    incremental_documents_with_progress_ext(
        root,
        existing,
        &ignore::IndexExtensions::from_env(),
        Some(progress),
        cancel,
    )
}

/// 遍历项目目录，对比文件哈希决定跳过/更新/删除，返回合并后的文档列表（仅单测）。
#[cfg(test)]
fn incremental_documents_with(
    root: &Path,
    existing: Vec<CodeDocument>,
    extensions: &ignore::IndexExtensions,
) -> Result<(Vec<CodeDocument>, IncrementalStats)> {
    incremental_documents_with_progress_ext(root, existing, extensions, None, None)
}

fn incremental_documents_with_progress_ext(
    root: &Path,
    existing: Vec<CodeDocument>,
    extensions: &ignore::IndexExtensions,
    progress: Option<Arc<tokio::sync::RwLock<IndexMeta>>>,
    cancel: Option<CancellationToken>,
) -> Result<(Vec<CodeDocument>, IncrementalStats)> {
    // 根路径只 canonicalize 一次：既稳定 file key，又避免每文件 canonicalize 的 Windows 开销。
    let root = root
        .canonicalize()
        .unwrap_or_else(|_| root.to_path_buf());
    let existing_map: HashMap<String, CodeDocument> =
        existing.into_iter().map(|doc| (doc.file.clone(), doc)).collect();
    let mut merged = Vec::new();
    let mut stats = IncrementalStats::default();
    let mut seen = std::collections::HashSet::new();
    let ignore = ignore::IgnoreMatcher::load(&root);
    let mut walk_seen: usize = 0;
    let mut last_log = std::time::Instant::now();
    let mut pending: Vec<PendingIndexFile> = Vec::new();
    let mut seen_by_extension: BTreeMap<String, usize> = BTreeMap::new();

    if let Some(p) = progress.as_ref() {
        if let Ok(mut meta) = p.try_write() {
            meta.phase = "walk".into();
            meta.pending_total = 0;
            meta.parsed_done = 0;
            meta.last_file.clear();
            meta.slow_files.clear();
            meta.busy_files.clear();
            meta.timed_out_files.clear();
        }
    }

    // 关键：在进入忽略目录前剪枝，否则大仓会把 .git/_build/node_modules 全扫一遍。
    let walker = WalkDir::new(&root).into_iter().filter_entry(|entry| {
        if entry.depth() == 0 {
            return true;
        }
        let path = entry.path();
        if path.is_dir() && ignore.is_ignored(&root, path) {
            return false;
        }
        true
    });

    // 阶段 1：串行扫盘 + mtime/size 快路；需读盘/解析的文件先入队。
    // P0-6：mtime 用纳秒；「年轻文件」（2 秒内改动）不做快路，强制走 hash 对比，
    // 避免同秒同尺寸改写被误判未变（racy-clean）。
    let now_nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    for entry in walker.filter_map(Result::ok) {
        if cancel.as_ref().is_some_and(|t| t.is_cancelled()) {
            return Err(anyhow!("index cancelled during walk"));
        }
        let path = entry.path();
        // P2-1：file_type/metadata 用 walkdir 遍历结果（Windows 下免二次 stat）。
        if !entry.file_type().is_file() || !extensions.is_indexable(path) {
            continue;
        }
        if ignore.is_ignored(&root, path) {
            continue;
        }
        walk_seen += 1;
        let file = normalize_path_key(&root, path);
        let ext = ignore::file_extension(path);
        *seen_by_extension.entry(ext.clone()).or_default() += 1;
        seen.insert(file.clone());

        if walk_seen % 50 == 0 {
            update_index_progress(
                progress.as_ref(),
                walk_seen,
                merged.len() + pending.len(),
                &seen_by_extension,
                "walk",
                0,
                0,
                "",
            );
        }
        if last_log.elapsed() >= std::time::Duration::from_secs(5) {
            tracing::info!(
                "index walk root={} seen={} cached={} pending={}",
                root.display(),
                walk_seen,
                merged.len(),
                pending.len()
            );
            last_log = std::time::Instant::now();
        }

        let (file_mtime, file_size) = entry
            .metadata()
            .map(|meta| mtime_size_from_meta(&meta))
            .unwrap_or((0, 0));
        if let Some(cached) = existing_map.get(&file) {
            // 年轻文件（mtime 距现在 < 2s 或取不到 mtime）跳过 mtime 快路，
            // 落入 pending 走 hash 精确对比（P0-6）。
            let too_young =
                file_mtime == 0 || now_nanos.saturating_sub(file_mtime) < 2_000_000_000;
            // data_sources == None：旧 state，强制走读盘路径补齐，仅升级后多一轮。
            if !too_young
                && file_size != 0
                && cached.file_size == file_size
                && cached.file_mtime == file_mtime
                && !cached.file_hash.is_empty()
                && cached.data_sources.is_some()
                && cached.call_extract_version >= CALL_EXTRACT_VERSION
            {
                merged.push(cached.clone());
                stats.skipped += 1;
                *stats.by_extension.entry(ext).or_default() += 1;
                continue;
            }
        }

        pending.push(PendingIndexFile {
            abs_path: path.to_path_buf(),
            file: file.clone(),
            ext,
            file_mtime,
            file_size,
            cached: existing_map.get(&file).cloned(),
        });
    }

    // 小文件先解析：files 进度更平滑；超大文件留到后面并打慢日志。
    pending.sort_by_key(|p| p.file_size);

    let pending_total = pending.len();
    update_index_progress(
        progress.as_ref(),
        walk_seen,
        merged.len() + pending_total,
        &seen_by_extension,
        "parse",
        pending_total,
        0,
        "",
    );

    if cancel.as_ref().is_some_and(|t| t.is_cancelled()) {
        return Err(anyhow!("index cancelled before parse"));
    }

    // 阶段 2：并行读盘 / 哈希 / tree-sitter 解析。
    let threads = index_threads();
    tracing::info!(
        "index parse start root={} pending={} threads={}",
        root.display(),
        pending_total,
        threads
    );
    let parsed_done = AtomicUsize::new(0);
    let tracker = Arc::new(ParseProgressTracker::new());
    let pool = rayon::ThreadPoolBuilder::new()
        .num_threads(threads)
        .thread_name(|i| format!("ali-index-{i}"))
        .build()
        .context("failed to build index thread pool")?;
    let cached_count = merged.len();
    let tracker_for_pool = Arc::clone(&tracker);
    let parse_results: Vec<Result<ParseFileOutcome>> = pool.install(|| {
        pending
            .into_par_iter()
            .map(|item| {
                let file_label = item.file.clone();
                let outcome = process_pending_index_file(item, extensions, &tracker_for_pool);
                let n = parsed_done.fetch_add(1, Ordering::Relaxed) + 1;
                // 更密的进度刷新（try_write，抢不到就跳过，避免锁风暴）。
                if n % 25 == 0 || n == pending_total {
                    if let Some(p) = progress.as_ref() {
                        if let Ok(mut meta) = p.try_write() {
                            meta.phase = "parse".into();
                            meta.walk_seen = walk_seen;
                            meta.files = cached_count + n;
                            meta.pending_total = pending_total;
                            meta.parsed_done = n;
                            meta.erl_files = *seen_by_extension.get("erl").unwrap_or(&0);
                            meta.hrl_files = *seen_by_extension.get("hrl").unwrap_or(&0);
                            meta.by_extension = seen_by_extension.clone();
                            meta.last_file = file_label;
                            meta.slow_files = tracker_for_pool.slow_snapshot();
                            meta.busy_files = tracker_for_pool.busy_snapshot();
                            meta.timed_out_files = tracker_for_pool.timed_out_snapshot();
                        }
                    }
                }
                outcome
            })
            .collect()
    });

    for result in parse_results {
        match result? {
            ParseFileOutcome::Skipped {
                doc,
                ext,
                meta_updated,
            } => {
                merged.push(doc);
                stats.skipped += 1;
                if meta_updated {
                    stats.meta_updated += 1;
                }
                *stats.by_extension.entry(ext).or_default() += 1;
            }
            ParseFileOutcome::Updated { doc, ext } => {
                merged.push(doc);
                stats.updated += 1;
                *stats.by_extension.entry(ext).or_default() += 1;
            }
            ParseFileOutcome::UnreadableKeepCached { doc } => {
                if let Some(doc) = doc {
                    merged.push(doc);
                }
            }
            ParseFileOutcome::TimedOut { keep_cached } => {
                stats.timed_out += 1;
                if let Some(doc) = keep_cached {
                    let ext = ignore::file_extension(Path::new(&doc.file));
                    merged.push(doc);
                    *stats.by_extension.entry(ext).or_default() += 1;
                }
            }
        }
    }

    let slow_files = tracker.slow_snapshot();
    let timed_out_files = tracker.timed_out_snapshot();
    if !timed_out_files.is_empty() {
        eprintln!(
            "[aliCore] TIMEOUT_SKIP summary: {} files exceeded limit (skipped):",
            timed_out_files.len()
        );
        for (i, s) in timed_out_files.iter().take(20).enumerate() {
            eprintln!(
                "  {}. {}  size={}B  limit≈{:.0}s",
                i + 1,
                s.file,
                s.size_bytes,
                s.secs
            );
        }
        eprintln!(
            "[aliCore] tip: 把路径片段加到 aliCfg.cfg → core.indexIgnore；超时秒数见 core.indexFileTimeoutSecs"
        );
    }
    if !slow_files.is_empty() {
        eprintln!(
            "[aliCore] SLOW_INDEX summary: {} slow files (top by secs):",
            slow_files.len()
        );
        for (i, s) in slow_files.iter().take(20).enumerate() {
            eprintln!(
                "  {}. {}  size={}B  secs={:.1}",
                i + 1,
                s.file,
                s.size_bytes,
                s.secs
            );
        }
        eprintln!(
            "[aliCore] tip: 把路径片段加到 aliCfg.cfg → core.indexIgnore，例如 pb,*_pb.erl,foo_mod"
        );
    }

    // 解析结束进入 build 前的进度已在 walk 函数内写过 phase=build；
    // 真正的 build 进度由 index_project_impl 再确认一次。
    if let Some(p) = progress.as_ref() {
        let mut meta = p.blocking_write();
        meta.walk_seen = walk_seen;
        meta.files = merged.len();
        meta.pending_total = pending_total;
        meta.parsed_done = pending_total;
        meta.erl_files = *stats.by_extension.get("erl").unwrap_or(&0);
        meta.hrl_files = *stats.by_extension.get("hrl").unwrap_or(&0);
        meta.by_extension = stats.by_extension.clone();
        meta.last_file.clear();
        meta.slow_files = slow_files;
        meta.busy_files.clear();
        meta.timed_out_files = timed_out_files;
        meta.phase = "parse_done".into();
    }
    tracing::info!(
        "index parse done root={} seen={} updated={} skipped={} timed_out={} threads={}",
        root.display(),
        walk_seen,
        stats.updated,
        stats.skipped,
        stats.timed_out,
        threads
    );

    stats.removed = 0;
    // P2-9：file key 与 root 都已规范化（统一斜杠/去 verbatim 前缀），
    // 直接做字符串前缀比较，不再对每个落选文件 canonicalize（Windows 上次级 syscall）。
    let root_abs = root.canonicalize().unwrap_or_else(|_| root.to_path_buf());
    let root_key = normalize_abs_key(&root_abs);
    for (file, doc) in &existing_map {
        if seen.contains(file) {
            continue;
        }
        if file_key_under_root(file, &root_key) {
            stats.removed += 1;
        } else {
            merged.push(doc.clone());
        }
    }

    merged.sort_by(|left, right| left.file.cmp(&right.file));
    Ok((merged, stats))
}

struct PendingIndexFile {
    abs_path: PathBuf,
    file: String,
    ext: String,
    file_mtime: u64,
    file_size: u64,
    cached: Option<CodeDocument>,
}

enum ParseFileOutcome {
    Skipped {
        doc: CodeDocument,
        ext: String,
        /// 补齐了旧 state 缺失的 data_sources，需 persist 但不改 Tantivy
        meta_updated: bool,
    },
    Updated {
        doc: CodeDocument,
        ext: String,
    },
    UnreadableKeepCached { doc: Option<CodeDocument> },
    /// 解析超时：跳过本文件；若有旧缓存则保留旧文档，避免索引倒退。
    TimedOut {
        keep_cached: Option<CodeDocument>,
    },
}

/// 并行解析时追踪「正在啃」、慢文件与超时跳过。
struct ParseProgressTracker {
    in_flight: Mutex<HashMap<String, (u64, Instant)>>,
    slow: Mutex<Vec<SlowFileInfo>>,
    timed_out: Mutex<Vec<SlowFileInfo>>,
    /// 本次索引会话内已超时/跳过的文件路径（去重，避免重复解析同一文件）。
    timed_out_paths: Mutex<HashSet<String>>,
    /// 跨会话持久化跳过：路径 → size/mtime（文件未变则继续跳过）。
    persistent_skip: Mutex<HashMap<String, ParseSkipEntry>>,
}

impl ParseProgressTracker {
    fn new() -> Self {
        Self {
            in_flight: Mutex::new(HashMap::new()),
            slow: Mutex::new(Vec::new()),
            timed_out: Mutex::new(Vec::new()),
            timed_out_paths: Mutex::new(HashSet::new()),
            persistent_skip: Mutex::new(load_parse_skip_map()),
        }
    }

    fn begin(&self, file: &str, size_bytes: u64) {
        if let Ok(mut map) = self.in_flight.lock() {
            map.insert(file.to_string(), (size_bytes, Instant::now()));
        }
    }

    fn was_timed_out(&self, file: &str) -> bool {
        self.timed_out_paths
            .lock()
            .map(|set| set.contains(file))
            .unwrap_or(false)
    }

    /// 持久化跳过命中：同路径且 size/mtime 未变。
    fn should_persist_skip(&self, file: &str, size_bytes: u64, mtime_ns: u64) -> bool {
        self.persistent_skip
            .lock()
            .map(|map| {
                map.get(file)
                    .map(|e| e.size_bytes == size_bytes && e.mtime_ns == mtime_ns)
                    .unwrap_or(false)
            })
            .unwrap_or(false)
    }

    fn mark_timed_out(&self, file: &str) -> bool {
        self.timed_out_paths
            .lock()
            .map(|mut set| set.insert(file.to_string()))
            .unwrap_or(false)
    }

    fn remember_persist_skip(&self, file: &str, size_bytes: u64, mtime_ns: u64) {
        if let Ok(mut map) = self.persistent_skip.lock() {
            map.insert(
                file.to_string(),
                ParseSkipEntry {
                    size_bytes,
                    mtime_ns,
                },
            );
            save_parse_skip_map(&map);
        }
    }

    fn clear_persist_skip(&self, file: &str) {
        if let Ok(mut map) = self.persistent_skip.lock() {
            if map.remove(file).is_some() {
                save_parse_skip_map(&map);
            }
        }
    }

    fn push_sorted(list: &mut Vec<SlowFileInfo>, info: SlowFileInfo, cap: usize) {
        list.push(info);
        list.sort_by(|a, b| {
            b.secs
                .partial_cmp(&a.secs)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        if list.len() > cap {
            list.truncate(cap);
        }
    }

    fn end_ok(&self, file: &str, size_bytes: u64, secs: f64) -> Option<SlowFileInfo> {
        if let Ok(mut map) = self.in_flight.lock() {
            map.remove(file);
        }
        // ≥10s：记入 slow 列表并立刻打到 stderr（Erlang shell 常能看见）。
        if secs < 10.0 {
            return None;
        }
        let info = SlowFileInfo {
            file: file.to_string(),
            size_bytes,
            secs: (secs * 10.0).round() / 10.0,
        };
        eprintln!(
            "[aliCore] SLOW_INDEX file={} size={}B secs={:.1}  (可考虑加入 core.indexIgnore)",
            info.file, info.size_bytes, info.secs
        );
        if let Ok(mut slow) = self.slow.lock() {
            Self::push_sorted(&mut slow, info.clone(), 40);
        }
        Some(info)
    }

    fn end_timeout(&self, file: &str, size_bytes: u64, timeout_secs: u64) -> SlowFileInfo {
        if let Ok(mut map) = self.in_flight.lock() {
            map.remove(file);
        }
        let info = SlowFileInfo {
            file: file.to_string(),
            size_bytes,
            secs: timeout_secs as f64,
        };
        eprintln!(
            "[aliCore] TIMEOUT_SKIP file={} size={}B limit={}s  (已跳过；建议加入 core.indexIgnore)",
            info.file, info.size_bytes, timeout_secs
        );
        if let Ok(mut list) = self.timed_out.lock() {
            Self::push_sorted(&mut list, info.clone(), 40);
        }
        info
    }

    fn end_skip(&self, file: &str) {
        if let Ok(mut map) = self.in_flight.lock() {
            map.remove(file);
        }
    }

    fn busy_snapshot(&self) -> Vec<SlowFileInfo> {
        let now = Instant::now();
        let Ok(map) = self.in_flight.lock() else {
            return Vec::new();
        };
        let mut out: Vec<SlowFileInfo> = map
            .iter()
            .filter_map(|(file, (size_bytes, started))| {
                let secs = now.duration_since(*started).as_secs_f64();
                if secs < 10.0 {
                    return None;
                }
                Some(SlowFileInfo {
                    file: file.clone(),
                    size_bytes: *size_bytes,
                    secs: (secs * 10.0).round() / 10.0,
                })
            })
            .collect();
        out.sort_by(|a, b| {
            b.secs
                .partial_cmp(&a.secs)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        out
    }

    fn slow_snapshot(&self) -> Vec<SlowFileInfo> {
        self.slow.lock().map(|s| s.clone()).unwrap_or_default()
    }

    fn timed_out_snapshot(&self) -> Vec<SlowFileInfo> {
        self.timed_out.lock().map(|s| s.clone()).unwrap_or_default()
    }
}

fn process_pending_index_file(
    item: PendingIndexFile,
    extensions: &ignore::IndexExtensions,
    tracker: &ParseProgressTracker,
) -> Result<ParseFileOutcome> {
    // 同一索引会话内该路径已超时跳过：沿用旧结果，避免重复 spawn 解析线程。
    if tracker.was_timed_out(&item.file) {
        return Ok(ParseFileOutcome::TimedOut {
            keep_cached: item.cached,
        });
    }
    // 跨会话持久化跳过：文件 size/mtime 未变则不再解析（性能审核 P3）。
    if tracker.should_persist_skip(&item.file, item.file_size, item.file_mtime) {
        tracker.mark_timed_out(&item.file);
        return Ok(ParseFileOutcome::TimedOut {
            keep_cached: item.cached,
        });
    }
    // 文件已变：清掉旧跳过记录，允许重新解析。
    tracker.clear_persist_skip(&item.file);
    tracker.begin(&item.file, item.file_size);
    let started = Instant::now();
    let body = match std::fs::read_to_string(&item.abs_path) {
        Ok(body) => body,
        Err(err) => {
            tracker.end_skip(&item.file);
            tracing::warn!("skip unreadable file {}: {}", item.abs_path.display(), err);
            return Ok(ParseFileOutcome::UnreadableKeepCached { doc: item.cached });
        }
    };
    let file_hash = stable_hash(&body);

    if let Some(cached) = item.cached.as_ref() {
        if cached.file_hash == file_hash && cached.call_extract_version >= CALL_EXTRACT_VERSION {
            tracker.end_skip(&item.file);
            let mut restored = cached.clone();
            if restored.body.is_empty() {
                restored.body = body.clone();
            }
            let meta_updated = restored.data_sources.is_none();
            if meta_updated {
                restored.data_sources = Some(data_flow::extract_data_source_calls(
                    &restored.body,
                    restored.module.as_deref(),
                    &restored.functions,
                ));
            }
            restored.file_mtime = item.file_mtime;
            restored.file_size = item.file_size;
            return Ok(ParseFileOutcome::Skipped {
                doc: restored,
                ext: item.ext,
                meta_updated,
            });
        }
    }

    let timeout_secs = index_file_timeout_secs();
    let doc = match parse_source_document_timed(
        &item,
        &body,
        file_hash,
        extensions,
        timeout_secs,
    ) {
        ParseTimed::Done(Ok(doc)) => doc,
        ParseTimed::Done(Err(err)) => {
            tracker.end_skip(&item.file);
            return Err(err);
        }
        ParseTimed::TimedOut => {
            let _info = tracker.end_timeout(&item.file, item.file_size, timeout_secs);
            tracker.mark_timed_out(&item.file);
            tracker.remember_persist_skip(&item.file, item.file_size, item.file_mtime);
            return Ok(ParseFileOutcome::TimedOut {
                keep_cached: item.cached,
            });
        }
    };
    let secs = started.elapsed().as_secs_f64();
    let _ = tracker.end_ok(&item.file, item.file_size, secs);
    Ok(ParseFileOutcome::Updated {
        doc,
        ext: item.ext,
    })
}

enum ParseTimed {
    Done(Result<CodeDocument>),
    TimedOut,
}

/// 简单计数信号量：限制同时进行的解析线程数，避免大量超时文件 detach 后线程堆积。
///
/// 许可是「借出」给解析线程的：线程结束时归还（含 detach 后仍在跑的超时线程），
/// 因此超时文件虽然仍会跑完单文件，但并发的后台解析线程数量被硬性封顶。
struct ParseSemaphore {
    permits: Mutex<usize>,
    cond: Condvar,
}

impl ParseSemaphore {
    fn new(permits: usize) -> Self {
        Self {
            permits: Mutex::new(permits.max(1)),
            cond: Condvar::new(),
        }
    }

    fn acquire(&self) -> ParsePermit<'_> {
        let mut guard = embedding::lock_or_recover(&self.permits);
        while *guard == 0 {
            guard = self
                .cond
                .wait(guard)
                .unwrap_or_else(|poisoned| poisoned.into_inner());
        }
        *guard -= 1;
        ParsePermit { sem: self }
    }
}

struct ParsePermit<'a> {
    sem: &'a ParseSemaphore,
}

impl Drop for ParsePermit<'_> {
    fn drop(&mut self) {
        let mut guard = embedding::lock_or_recover(&self.sem.permits);
        *guard += 1;
        self.sem.cond.notify_one();
    }
}

/// 进程级解析线程并发上限（与索引解析并行度一致）。
static PARSE_SEM: OnceLock<ParseSemaphore> = OnceLock::new();

fn parse_semaphore() -> &'static ParseSemaphore {
    PARSE_SEM.get_or_init(|| ParseSemaphore::new(index_threads()))
}

/// 在独立线程中解析；超时则放弃 JoinHandle（线程 detach），调用方跳过该文件。
fn parse_source_document_timed(
    item: &PendingIndexFile,
    body: &str,
    file_hash: String,
    extensions: &ignore::IndexExtensions,
    timeout_secs: u64,
) -> ParseTimed {
    if timeout_secs == 0 {
        return ParseTimed::Done(parse_source_document(
            &item.abs_path,
            &item.file,
            body,
            file_hash,
            item.file_mtime,
            item.file_size,
            extensions,
        ));
    }

    let abs_path = item.abs_path.clone();
    let file = item.file.clone();
    let body = body.to_string();
    let file_mtime = item.file_mtime;
    let file_size = item.file_size;
    let extensions = extensions.clone();
    // 先取并发许可再 spawn：detach 的超时线程会一直持有许可直到跑完，
    // 从源头封顶同时存在的解析线程数（许可在 spawn 失败时随闭包 drop 归还）。
    let permit = parse_semaphore().acquire();
    let (tx, rx) = std::sync::mpsc::sync_channel(1);
    let handle = match std::thread::Builder::new()
        .name(format!("ali-ix-{}", short_thread_label(&file)))
        .spawn(move || {
            let _permit = permit;
            let result = parse_source_document(
                &abs_path,
                &file,
                &body,
                file_hash,
                file_mtime,
                file_size,
                &extensions,
            );
            let _ = tx.send(result);
        }) {
        Ok(h) => h,
        Err(err) => {
            return ParseTimed::Done(Err(anyhow!("failed to spawn parse thread: {err}")));
        }
    };

    match rx.recv_timeout(Duration::from_secs(timeout_secs)) {
        Ok(result) => {
            let _ = handle.join();
            ParseTimed::Done(result)
        }
        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
            // Drop JoinHandle → detach；后台线程可能仍在跑，但索引主流程继续。
            drop(handle);
            ParseTimed::TimedOut
        }
        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
            let _ = handle.join();
            ParseTimed::Done(Err(anyhow!("parse thread exited without result")))
        }
    }
}

fn short_thread_label(file: &str) -> String {
    let name = file.rsplit(['/', '\\']).next().unwrap_or(file);
    name.chars().take(24).collect()
}

/// 单文件解析超时（秒）。`0` = 不限制。默认 30。
/// 由 `--ali-index-file-timeout-secs=` / `ALI_INDEX_FILE_TIMEOUT_SECS` 注入。
fn index_file_timeout_secs() -> u64 {
    std::env::var("ALI_INDEX_FILE_TIMEOUT_SECS")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(30)
}

fn update_index_progress(
    progress: Option<&Arc<tokio::sync::RwLock<IndexMeta>>>,
    walk_seen: usize,
    files: usize,
    by_extension: &BTreeMap<String, usize>,
    phase: &str,
    pending_total: usize,
    parsed_done: usize,
    last_file: &str,
) {
    if let Some(p) = progress {
        let mut meta = p.blocking_write();
        meta.walk_seen = walk_seen;
        meta.files = files;
        meta.erl_files = *by_extension.get("erl").unwrap_or(&0);
        meta.hrl_files = *by_extension.get("hrl").unwrap_or(&0);
        meta.by_extension = by_extension.clone();
        meta.phase = phase.to_string();
        meta.pending_total = pending_total;
        meta.parsed_done = parsed_done;
        if !last_file.is_empty() {
            meta.last_file = last_file.to_string();
        }
    }
}

/// 索引解析并行度。`--ali-index-threads=` / `ALI_INDEX_THREADS`；未设则用逻辑核数（至少 1）。
fn index_threads() -> usize {
    if let Ok(v) = std::env::var("ALI_INDEX_THREADS") {
        if let Ok(n) = v.trim().parse::<usize>() {
            if n > 0 {
                return n;
            }
        }
    }
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4)
}

#[derive(Debug, Default)]
struct IncrementalStats {
    updated: usize,
    skipped: usize,
    removed: usize,
    timed_out: usize,
    /// 仅元数据补齐（如 data_sources），需 persist / 刷新 DataSourceIndex，不重建 Tantivy
    meta_updated: usize,
    by_extension: BTreeMap<String, usize>,
}

impl IncrementalStats {
    /// 有文件更新或删除时需要重建 Tantivy 索引。
    fn needs_reindex(&self) -> bool {
        self.updated > 0 || self.removed > 0
    }

    fn needs_persist(&self) -> bool {
        self.needs_reindex() || self.meta_updated > 0
    }
}

/// 从文件元数据取修改时间（纳秒级 UNIX 时间戳，P0-6）与字节大小；取不到时回退为 0。
///
/// 纳秒存 u64 可表达到 2554 年。注意：旧 state.json 中存的是秒级时间戳，
/// 升级后首轮索引 mtime 必不匹配 → 走 hash 精确对比（hash 一致仍记 skipped），
/// 仅此一轮全量读盘，之后恢复正常快路。
fn mtime_size_from_meta(meta: &std::fs::Metadata) -> (u64, u64) {
    let mtime = meta
        .modified()
        .ok()
        .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or(0);
    (mtime, meta.len())
}

/// 按后缀选择解析器：`.erl` 函数级、`.hrl` 记录/宏、其它按行分块。
fn parse_source_document(
    path: &Path,
    file: &str,
    body: &str,
    file_hash: String,
    file_mtime: u64,
    file_size: u64,
    extensions: &IndexExtensions,
) -> Result<CodeDocument> {
    match extensions.chunker_for(path) {
        ignore::ChunkerMode::TreeSitter => {
            parse_document(file, body, file_hash, file_mtime, file_size)
        }
        ignore::ChunkerMode::TreeSitterHrl => {
            parse_hrl_document(file, body, file_hash, file_mtime, file_size)
        }
        ignore::ChunkerMode::LineBased => {
            parse_text_document(file, body, file_hash, file_mtime, file_size)
        }
    }
}

/// 将非 Erlang 源文件按固定行数切分为文本 chunk（无函数符号）。
fn parse_text_document(file: &str, body: &str, file_hash: String, file_mtime: u64, file_size: u64) -> Result<CodeDocument> {
    let file = file.to_string();
    let chunks = text_chunks(&file, None, body, TEXT_CHUNK_LINES);
    Ok(CodeDocument {
        file,
        module: None,
        functions: Vec::new(),
        exports: Vec::new(),
        specs: Vec::new(),
        callbacks: Vec::new(),
        records: Vec::new(),
        macros: Vec::new(),
        calls: Vec::new(),
        chunks,
        body: body.to_string(),
        behaviours: Vec::new(),
        test_cases: Vec::new(),
        tech_debt: Vec::new(),
        data_sources: Some(Vec::new()),
        file_hash,
        file_mtime,
        file_size,
        call_extract_version: CALL_EXTRACT_VERSION,
    })
}

/// 将源码按 `lines_per_chunk` 行切分，生成带行号范围的 `FunctionChunk`。
///
/// 相邻 chunk 保留约 25% 行重叠，避免函数/语句被切块边界一刀两断，
/// 从而降低向量检索因跨块而漏召回的概率（文本/行分块专用）。
fn text_chunks(
    file: &str,
    module: Option<&str>,
    body: &str,
    lines_per_chunk: usize,
) -> Vec<FunctionChunk> {
    let lines: Vec<&str> = body.lines().collect();
    if lines.is_empty() {
        return Vec::new();
    }

    let module_owned = module.map(|m| m.to_string());
    let overlap = lines_per_chunk / 4;
    let step = lines_per_chunk.saturating_sub(overlap).max(1);
    let mut chunks = Vec::new();
    let mut start = 0usize;
    let mut chunk_idx = 0usize;
    loop {
        let end = (start + lines_per_chunk).min(lines.len());
        let chunk_body = lines[start..end].join("\n");
        chunks.push(FunctionChunk {
            id: format!("{file}:#text:{chunk_idx}"),
            file: file.to_string(),
            module: module_owned.clone(),
            function: format!("_chunk_{chunk_idx}"),
            arity: 0,
            start_line: start + 1,
            end_line: end,
            hash: stable_hash(&chunk_body),
        });
        chunk_idx += 1;
        if end >= lines.len() {
            break;
        }
        start += step;
    }
    chunks
}

/// 语义分块：按函数边界切分 Erlang 源码。
///
/// - 每个函数的 `start_line..end_line` 闭区间作为一个 chunk；
/// - 函数之间的间隙（注释/属性）作为独立 gap chunk；
/// - 超过 80 行的大函数按 40 行子分块（10 行 overlap），避免单 chunk 过大；
/// - 无函数时回退到 `text_chunks`，保证非典型 .erl 仍可被索引。
const SEMANTIC_CHUNK_THRESHOLD: usize = 80;
const SEMANTIC_SUBCHUNK_LINES: usize = 40;
const SEMANTIC_SUBCHUNK_OVERLAP: usize = 10;

fn semantic_chunks(
    file: &str,
    module: Option<&str>,
    body: &str,
    functions: &[FunctionSymbol],
) -> Vec<FunctionChunk> {
    if functions.is_empty() {
        return text_chunks(file, module, body, TEXT_CHUNK_LINES);
    }
    let total_lines = body.lines().count();
    if total_lines == 0 {
        return Vec::new();
    }

    let module_owned = module.map(|m| m.to_string());
    let mut sorted_fns: Vec<&FunctionSymbol> = functions.iter().collect();
    sorted_fns.sort_by_key(|f| f.start_line);

    let mut chunks = Vec::new();
    let mut cursor = 1usize;
    let mut gap_idx = 0usize;

    for fun in &sorted_fns {
        let fn_start = fun.start_line.max(1);
        let fn_end = fun.end_line.min(total_lines);
        if fn_end < fn_start {
            continue;
        }

        // 函数前间隙（注释/属性/空行）作为独立 gap chunk
        if fn_start > cursor {
            let gap_start = cursor;
            let gap_end = (fn_start - 1).min(total_lines);
            if gap_end >= gap_start {
                let chunk_body = lines_range(body, gap_start, gap_end);
                chunks.push(FunctionChunk {
                    id: format!("{file}:#gap:{gap_idx}"),
                    file: file.to_string(),
                    module: module_owned.clone(),
                    function: format!("_gap_{gap_idx}"),
                    arity: 0,
                    start_line: gap_start,
                    end_line: gap_end,
                    hash: stable_hash(&chunk_body),
                });
                gap_idx += 1;
            }
        }

        let fn_lines = fn_end - fn_start + 1;
        if fn_lines > SEMANTIC_CHUNK_THRESHOLD {
            // 大函数子分块：40 行一块，10 行 overlap
            let step = SEMANTIC_SUBCHUNK_LINES
                .saturating_sub(SEMANTIC_SUBCHUNK_OVERLAP)
                .max(1);
            let mut sub_idx = 0usize;
            let mut start = fn_start;
            loop {
                let end = (start + SEMANTIC_SUBCHUNK_LINES - 1).min(fn_end);
                let chunk_body = lines_range(body, start, end);
                chunks.push(FunctionChunk {
                    id: format!("{file}:{}/{}#{sub_idx}", fun.name, fun.arity),
                    file: file.to_string(),
                    module: module_owned.clone(),
                    function: fun.name.clone(),
                    arity: fun.arity,
                    start_line: start,
                    end_line: end,
                    hash: stable_hash(&chunk_body),
                });
                sub_idx += 1;
                if end >= fn_end {
                    break;
                }
                start += step;
            }
        } else {
            let chunk_body = lines_range(body, fn_start, fn_end);
            chunks.push(FunctionChunk {
                id: format!("{file}:{}/{}", fun.name, fun.arity),
                file: file.to_string(),
                module: module_owned.clone(),
                function: fun.name.clone(),
                arity: fun.arity,
                start_line: fn_start,
                end_line: fn_end,
                hash: stable_hash(&chunk_body),
            });
        }

        cursor = fn_end + 1;
    }

    // 末尾间隙（最后函数之后的注释/属性）
    if total_lines >= cursor {
        let chunk_body = lines_range(body, cursor, total_lines);
        chunks.push(FunctionChunk {
            id: format!("{file}:#gap:{gap_idx}"),
            file: file.to_string(),
            module: module_owned,
            function: format!("_gap_{gap_idx}"),
            arity: 0,
            start_line: cursor,
            end_line: total_lines,
            hash: stable_hash(&chunk_body),
        });
    }

    chunks
}

/// 统计各后缀文件数量，用于索引状态报告。
fn extension_counts_from_documents(documents: &[CodeDocument]) -> BTreeMap<String, usize> {
    let mut counts = BTreeMap::new();
    for doc in documents {
        let ext = Path::new(&doc.file)
            .extension()
            .and_then(|value| value.to_str())
            .map(|value| value.to_ascii_lowercase())
            .unwrap_or_else(|| "unknown".to_string());
        *counts.entry(ext).or_default() += 1;
    }
    counts
}

/// 从扩展名计数表中取某一后缀的数量，缺省为 0。
fn count_extension(counts: &BTreeMap<String, usize>, ext: &str) -> usize {
    counts.get(ext).copied().unwrap_or(0)
}

/// 解析 `.hrl` 头文件：提取 record/macro/export 等，无函数与调用边。
fn parse_hrl_document(file: &str, body: &str, file_hash: String, file_mtime: u64, file_size: u64) -> Result<CodeDocument> {
    let parsed = parse_erlang(body)?;
    let file = file.to_string();
    let tech_debt = extract_tech_debt(body);
    Ok(CodeDocument {
        file,
        module: parsed.module,
        functions: Vec::new(),
        exports: parsed.exports,
        specs: parsed.specs,
        callbacks: parsed.callbacks,
        records: parsed.records,
        macros: parsed.macros,
        calls: Vec::new(),
        chunks: Vec::new(),
        body: body.to_string(),
        behaviours: parsed.behaviours.clone(),
        test_cases: Vec::new(),
        tech_debt,
        data_sources: Some(Vec::new()),
        file_hash,
        file_mtime,
        file_size,
        call_extract_version: CALL_EXTRACT_VERSION,
    })
}

/// 解析 `.erl` 模块：函数、chunk、调用图边及各类符号。
fn parse_document(file: &str, body: &str, file_hash: String, file_mtime: u64, file_size: u64) -> Result<CodeDocument> {
    let parsed = parse_erlang(body)?;
    let module = parsed.module;
    let functions = parsed.functions;
    let file = file.to_string();
    let chunks = semantic_chunks(&file, module.as_deref(), body, &functions);
    let calls = attach_call_sources(module.clone(), parsed.calls, &functions);
    let test_cases = extract_test_cases(&functions, &file);
    let tech_debt = extract_tech_debt(body);
    let data_sources = Some(data_flow::extract_data_source_calls(body, module.as_deref(), &functions));
    Ok(CodeDocument {
        file,
        module,
        functions,
        exports: parsed.exports,
        specs: parsed.specs,
        callbacks: parsed.callbacks,
        records: parsed.records,
        macros: parsed.macros,
        calls,
        chunks,
        body: body.to_string(),
        behaviours: parsed.behaviours.clone(),
        test_cases,
        tech_debt,
        data_sources,
        file_hash,
        file_mtime,
        file_size,
        call_extract_version: CALL_EXTRACT_VERSION,
    })
}

/// 从 `state.json` 加载已持久化的文档列表（启动增量索引用）。
fn load_persisted_documents() -> Vec<CodeDocument> {
    let path = state_path();
    if !path.exists() {
        return Vec::new();
    }
    let raw = std::fs::read_to_string(path).unwrap_or_default();
    if raw.is_empty() {
        return Vec::new();
    }
    match serde_json::from_str::<Vec<CodeDocument>>(&raw) {
        Ok(docs) => docs
            .into_iter()
            .map(|mut d| {
                // 与 normalize_abs_key 一致：仅 Windows 小写，避免 Linux/macOS
                // 每次增量索引因大小写不一致整库重建、delete_term 失效。
                d.file = normalize_file_key(&d.file);
                d
            })
            .collect(),
        Err(e) => {
            tracing::warn!("state.json corrupted, starting fresh: {e}");
            Vec::new()
        }
    }
}

/// 持久化 file key 规范化：斜杠统一、去掉 Windows verbatim 前缀；Windows 再小写。
fn normalize_file_key(file: &str) -> String {
    let mut s = file.replace('\\', "/");
    for prefix in ["//?/", "//./", "/?/"] {
        if let Some(rest) = s.strip_prefix(prefix) {
            s = rest.to_string();
            break;
        }
    }
    #[cfg(windows)]
    {
        s = s.to_ascii_lowercase();
    }
    s
}

/// 在默认 Tantivy 目录上构建全文索引。
///
/// `old_hashes`：增量对比用的旧 file→hash；`None` 时回退读 state.json（测试兼容）。
fn build_index(
    documents: &[CodeDocument],
    old_hashes: Option<&HashMap<String, String>>,
) -> Result<SearchIndex> {
    build_index_at(documents, &index_dir(), old_hashes)
}

/// Build or incrementally update a Tantivy index using a dual-buffer directory
/// swap (`index_dir` <-> `index_dir.next`) so readers keep a consistent view.
fn build_index_at(
    documents: &[CodeDocument],
    index_dir: &Path,
    old_hashes: Option<&HashMap<String, String>>,
) -> Result<SearchIndex> {
    // Prefer true incremental update against the live index.
    if index_dir.exists() {
        if let Ok(Some(updated)) = incremental_update_index(documents, index_dir, old_hashes) {
            return Ok(updated);
        }
    }

    // 全量重建：一次性 hydrate 空 body，避免 searchable_body 循环里 N 次 open。
    let mut owned: Vec<CodeDocument> = documents.to_vec();
    for doc in &mut owned {
        if doc.body.is_empty() {
            doc.body = std::fs::read_to_string(resolve_doc_file(&doc.file)).unwrap_or_default();
        }
    }

    let staging = index_dir.with_extension("next");
    if staging.exists() {
        std::fs::remove_dir_all(&staging).ok();
    }
    std::fs::create_dir_all(&staging)?;

    let call_graph_index = CallGraphIndex::from_documents(&owned);
    // Scope drops Index/Writer before rename — required on Windows.
    {
        let mut schema_builder = Schema::builder();
        // file uses STRING for exact-term delete; body is indexed but not STORED
        // to avoid a third full-text copy alongside state.json / memory docs.
        let file = schema_builder.add_text_field("file", STRING | STORED);
        let module = schema_builder.add_text_field("module", TEXT | STORED);
        let body = schema_builder.add_text_field("body", TEXT);
        let schema = schema_builder.build();
        let index = Index::create_in_dir(&staging, schema)?;
        // P2-2：全量重建显式多线程 + 64MB heap（可用环境变量覆盖）。
        let mut writer = tantivy_writer(&index, 64_000_000)?;
        for doc in &owned {
            writer.add_document(doc!(
                file => doc.file.clone(),
                module => doc.module.clone().unwrap_or_default(),
                body => searchable_body(doc),
            ))?;
        }
        writer.commit()?;
    }

    promote_tantivy_dir(&staging, index_dir)?;

    let index = Index::open_in_dir(index_dir)?;
    let reader = index.reader()?;
    let schema = index.schema();
    let file = schema.get_field("file").context("missing file field")?;
    let module = schema.get_field("module").context("missing module field")?;
    let body = schema.get_field("body").context("missing body field")?;
    let data_source_index = data_flow::DataSourceIndex::from_documents(&owned);
    Ok(SearchIndex {
        index,
        reader,
        fields: SearchFields { file, module, body },
        documents: slim_documents_for_runtime(owned),
        call_graph_index,
        data_source_index,
        by_file: HashMap::new(),
        by_chunk: HashMap::new(),
        by_module: HashMap::new(),
        by_function: HashMap::new(),
        module_deps_map: HashMap::new(),
    }
    .with_lookups())
}

/// 将 staging Tantivy 目录提升为正式 index_dir。
/// Windows 上 rename 常因 AV/残留句柄报 os error 5，故带重试，并在失败时 copy 回退。
fn promote_tantivy_dir(staging: &Path, index_dir: &Path) -> Result<()> {
    let prev = index_dir.with_extension("prev");
    let _ = remove_dir_all_retry(&prev, 8);

    if index_dir.exists() {
        if let Err(err) = rename_retry(index_dir, &prev, 8) {
            tracing::warn!(
                "rename live→prev failed ({err}); trying remove_dir_all on {}",
                index_dir.display()
            );
            remove_dir_all_retry(index_dir, 10).with_context(|| {
                format!(
                    "cannot free live index dir {} (close other aliCore / exclude from AV)",
                    index_dir.display()
                )
            })?;
        }
    }

    match rename_retry(staging, index_dir, 10) {
        Ok(()) => {
            let _ = remove_dir_all_retry(&prev, 4);
            Ok(())
        }
        Err(err) => {
            tracing::warn!(
                "rename staging→live failed ({err:#}); falling back to copy into {}",
                index_dir.display()
            );
            eprintln!(
                "[aliCore] INDEX_PROMOTE rename failed ({err}); using copy fallback"
            );
            if index_dir.exists() {
                remove_dir_all_retry(index_dir, 10)?;
            }
            copy_dir_recursive(staging, index_dir).with_context(|| {
                format!(
                    "failed to promote staging index to {} (rename+copy both failed)",
                    index_dir.display()
                )
            })?;
            let _ = remove_dir_all_retry(staging, 4);
            let _ = remove_dir_all_retry(&prev, 4);
            Ok(())
        }
    }
}

fn is_transient_fs_error(err: &std::io::Error) -> bool {
    matches!(
        err.kind(),
        std::io::ErrorKind::PermissionDenied
            | std::io::ErrorKind::TimedOut
            | std::io::ErrorKind::WouldBlock
            | std::io::ErrorKind::Interrupted
    ) || err.raw_os_error() == Some(5)  // ERROR_ACCESS_DENIED
        || err.raw_os_error() == Some(32) // ERROR_SHARING_VIOLATION
        || err.raw_os_error() == Some(33) // ERROR_LOCK_VIOLATION
}

fn rename_retry(from: &Path, to: &Path, attempts: u32) -> std::io::Result<()> {
    let mut last = None;
    for i in 0..attempts {
        match std::fs::rename(from, to) {
            Ok(()) => return Ok(()),
            Err(err) if is_transient_fs_error(&err) && i + 1 < attempts => {
                last = Some(err);
                std::thread::sleep(Duration::from_millis(40 * (i as u64 + 1)));
            }
            Err(err) => return Err(err),
        }
    }
    Err(last.unwrap_or_else(|| std::io::Error::other("rename_retry exhausted")))
}

fn remove_dir_all_retry(path: &Path, attempts: u32) -> std::io::Result<()> {
    if !path.exists() {
        return Ok(());
    }
    let mut last = None;
    for i in 0..attempts {
        match std::fs::remove_dir_all(path) {
            Ok(()) => return Ok(()),
            Err(err) if is_transient_fs_error(&err) && i + 1 < attempts => {
                last = Some(err);
                std::thread::sleep(Duration::from_millis(50 * (i as u64 + 1)));
            }
            Err(err) => return Err(err),
        }
    }
    Err(last.unwrap_or_else(|| std::io::Error::other("remove_dir_all_retry exhausted")))
}

fn copy_dir_recursive(src: &Path, dst: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(dst)?;
    for entry in std::fs::read_dir(src)? {
        let entry = entry?;
        let ty = entry.file_type()?;
        let from = entry.path();
        let to = dst.join(entry.file_name());
        if ty.is_dir() {
            copy_dir_recursive(&from, &to)?;
        } else {
            // Windows AV 可能短时锁新文件：单文件复制也带轻量重试。
            let mut last = None;
            for i in 0..6u32 {
                match std::fs::copy(&from, &to) {
                    Ok(_) => {
                        last = None;
                        break;
                    }
                    Err(err) if is_transient_fs_error(&err) && i < 5 => {
                        last = Some(err);
                        std::thread::sleep(Duration::from_millis(30 * (i as u64 + 1)));
                    }
                    Err(err) => return Err(err),
                }
            }
            if let Some(err) = last {
                return Err(err);
            }
        }
    }
    Ok(())
}

/// Delete-by-file + re-add changed documents without a full directory rebuild.
fn incremental_update_index(
    documents: &[CodeDocument],
    index_dir: &Path,
    old_hashes: Option<&HashMap<String, String>>,
) -> Result<Option<SearchIndex>> {
    let index = match Index::open_in_dir(index_dir) {
        Ok(idx) => idx,
        Err(_) => return Ok(None),
    };
    let schema = index.schema();
    let file_field = match schema.get_field("file") {
        Ok(f) => f,
        Err(_) => return Ok(None),
    };
    let module_field = match schema.get_field("module") {
        Ok(f) => f,
        Err(_) => return Ok(None),
    };
    let body_field = match schema.get_field("body") {
        Ok(f) => f,
        Err(_) => return Ok(None),
    };

    // 优先用调用方传入的旧 hash，避免再读一整份 state.json。
    let owned_fallback;
    let existing_map: &HashMap<String, String> = match old_hashes {
        Some(map) => map,
        None => {
            owned_fallback = load_persisted_documents()
                .into_iter()
                .map(|d| (d.file.clone(), d.file_hash.clone()))
                .collect();
            &owned_fallback
        }
    };

    // P0-7：state.json 丢失/空而 Tantivy 仍有文档时，增量只会 add 不会 delete → 文档翻倍。
    // 强制退回全量重建。
    if existing_map.is_empty() {
        if let Ok(reader) = index.reader() {
            if reader.searcher().num_docs() > 0 {
                tracing::warn!(
                    "state hashes empty but tantivy has {} docs; forcing full rebuild",
                    reader.searcher().num_docs()
                );
                return Ok(None);
            }
        }
    }

    let new_map: HashMap<&str, &CodeDocument> =
        documents.iter().map(|d| (d.file.as_str(), d)).collect();

    let mut writer = tantivy_writer(&index, 16_000_000)?;
    let mut changed = 0usize;

    // Remove files that disappeared or changed.
    for (old_file, old_hash) in existing_map {
        let needs_delete = match new_map.get(old_file.as_str()) {
            None => true,
            Some(doc) => doc.file_hash != *old_hash,
        };
        if needs_delete {
            writer.delete_term(Term::from_field_text(file_field, old_file));
            changed += 1;
        }
    }

    // Add new / updated files.
    for doc in documents {
        let is_new_or_changed = match existing_map.get(&doc.file) {
            None => true,
            Some(old_hash) => *old_hash != doc.file_hash,
        };
        if is_new_or_changed {
            writer.add_document(doc!(
                file_field => doc.file.clone(),
                module_field => doc.module.clone().unwrap_or_default(),
                body_field => searchable_body(doc),
            ))?;
            changed += 1;
        }
    }

    if changed == 0 {
        let reader = index.reader()?;
        let data_source_index = data_flow::DataSourceIndex::from_documents(documents);
        return Ok(Some(
            SearchIndex {
                index,
                reader,
                fields: SearchFields {
                    file: file_field,
                    module: module_field,
                    body: body_field,
                },
                documents: slim_documents_from_slice(documents),
                call_graph_index: CallGraphIndex::from_documents(documents),
                data_source_index,
                by_file: HashMap::new(),
                by_chunk: HashMap::new(),
                by_module: HashMap::new(),
                by_function: HashMap::new(),
                module_deps_map: HashMap::new(),
            }
            .with_lookups(),
        ));
    }

    writer.commit()?;
    let reader = index.reader()?;
    let data_source_index = data_flow::DataSourceIndex::from_documents(documents);
    Ok(Some(
        SearchIndex {
            index,
            reader,
            fields: SearchFields {
                file: file_field,
                module: module_field,
                body: body_field,
            },
            documents: slim_documents_from_slice(documents),
            call_graph_index: CallGraphIndex::from_documents(documents),
            data_source_index,
            by_file: HashMap::new(),
            by_chunk: HashMap::new(),
            by_module: HashMap::new(),
            by_function: HashMap::new(),
            module_deps_map: HashMap::new(),
        }
        .with_lookups(),
    ))
}

/// 创建 Tantivy writer：显式指定写线程数与 heap（P2-2）。
///
/// 大仓全量重建时单线程 writer 是吞吐瓶颈；线程数默认 逻辑核/4（1..=4），
/// heap 由调用方给默认值，均可用环境变量覆盖：
/// `ALI_TANTIVY_WRITER_THREADS` / `ALI_TANTIVY_WRITER_HEAP`。
fn tantivy_writer(index: &Index, default_heap: usize) -> Result<tantivy::IndexWriter> {
    let threads = std::env::var("ALI_TANTIVY_WRITER_THREADS")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .filter(|n| *n > 0)
        .unwrap_or_else(|| {
            std::thread::available_parallelism()
                .map(|n| (n.get() / 4).clamp(1, 4))
                .unwrap_or(2)
        });
    // tantivy 要求每线程 arena ≥ ~15MB（否则 InvalidArgument）：heap 随线程数兜底放大。
    let heap = std::env::var("ALI_TANTIVY_WRITER_HEAP")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .filter(|n| *n >= 8_000_000)
        .unwrap_or(default_heap)
        .max(threads * 16_000_000);
    Ok(index.writer_with_num_threads(threads, heap)?)
}

/// Normalize to absolute, forward-slash path keys so multiple codeRoots
/// (project + OTP lib + shared deps) can share one index without colliding
/// on relative names like `src/foo.erl`.
///
/// 不在每个文件上 `canonicalize()`：Windows 上极慢，且会引入 `\\?\` 前缀，
/// 写成 `//?/f:/...` 污染 state.json。根目录在扫盘入口 canonicalize 一次即可。
fn normalize_path_key(root: &Path, path: &Path) -> String {
    let abs = if path.is_absolute() {
        path.to_path_buf()
    } else if root.is_absolute() {
        root.join(path)
    } else {
        std::env::current_dir()
            .map(|cwd| cwd.join(root).join(path))
            .unwrap_or_else(|_| root.join(path))
    };
    normalize_abs_key(&abs)
}

fn normalize_abs_key(abs: &Path) -> String {
    let mut s = abs.to_string_lossy().replace('\\', "/");
    // Windows canonicalize() 的 verbatim 前缀：\\?\C:\... → //?/c:/...
    for prefix in ["//?/", "//./", "/?/"] {
        if let Some(rest) = s.strip_prefix(prefix) {
            s = rest.to_string();
            break;
        }
    }
    if let Some(rest) = s.strip_prefix("./") {
        s = rest.to_string();
    }
    // Windows paths are case-insensitive; keep keys stable across drives.
    #[cfg(windows)]
    {
        s = s.to_ascii_lowercase();
    }
    s
}

/// Resolve an indexed file key to a filesystem path.
/// Absolute keys (multi-root) are used as-is; legacy relative keys join `ALI_ROOT`.
fn resolve_doc_file(file_key: &str) -> PathBuf {
    let path = PathBuf::from(file_key);
    if path.is_absolute() {
        return path;
    }
    let root = std::env::var("ALI_ROOT").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(root).join(path)
}

/// 规范化后的 file key 是否位于规范化后的 root key 之下（纯字符串比较，零 syscall）。
fn file_key_under_root(file_key: &str, root_key: &str) -> bool {
    file_key.len() > root_key.len()
        && file_key.starts_with(root_key)
        && file_key.as_bytes()[root_key.len()] == b'/'
}

/// Tantivy 索引目录（`ALI_INDEX_DIR`，默认 `.ali/index/tantivy`）。
fn index_dir() -> PathBuf {
    std::env::var("ALI_INDEX_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(".ali/index/tantivy"))
}

/// 文档元数据 JSON 路径（与 Tantivy 目录同级的 `state.json`）。
fn state_path() -> PathBuf {
    index_dir().parent().map(|p| p.join("state.json")).unwrap_or_else(|| PathBuf::from(".ali/index/state.json"))
}

/// 解析超时持久化跳过清单（路径 → size/mtime），避免跨会话重复啃超大文件。
fn parse_skip_path() -> PathBuf {
    index_dir()
        .parent()
        .map(|p| p.join("parse_skip.json"))
        .unwrap_or_else(|| PathBuf::from(".ali/index/parse_skip.json"))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ParseSkipEntry {
    size_bytes: u64,
    mtime_ns: u64,
}

fn load_parse_skip_map() -> HashMap<String, ParseSkipEntry> {
    let path = parse_skip_path();
    match std::fs::read_to_string(&path) {
        Ok(text) => serde_json::from_str(&text).unwrap_or_default(),
        Err(_) => HashMap::new(),
    }
}

fn save_parse_skip_map(map: &HashMap<String, ParseSkipEntry>) {
    let path = parse_skip_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(text) = serde_json::to_string_pretty(map) {
        let _ = std::fs::write(path, text);
    }
}

/// Persist document metadata without full source bodies (bodies are re-read
/// from disk on demand). Stream to disk — no intermediate giant String / clone.
/// 状态落盘临时文件序号：保证同一进程内每次落盘的临时文件名唯一，避免并发写竞态。
static STATE_TMP_SEQ: AtomicUsize = AtomicUsize::new(0);

fn persist_state(documents: &[CodeDocument]) -> Result<()> {
    let path = state_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    // 原子写：先写唯一临时文件再 rename（body 已 skip_serializing，无需 clone 清 body）。
    let seq = STATE_TMP_SEQ.fetch_add(1, Ordering::Relaxed);
    let temp = path.with_extension(format!("json.tmp.{}.{}", std::process::id(), seq));
    {
        let file = std::fs::File::create(&temp)?;
        let writer = std::io::BufWriter::new(file);
        serde_json::to_writer(writer, documents)?;
    }
    if let Err(rename_error) = std::fs::rename(&temp, &path) {
        if path.exists() {
            std::fs::remove_file(&path)?;
            std::fs::rename(&temp, &path)?;
        } else {
            return Err(rename_error.into());
        }
    }
    Ok(())
}

/// 启动时加载持久化索引：读 state.json，打开或重建 Tantivy。
/// 故意不把全文 restore 进内存——snippet/符号源码按需读盘（省内存）。
fn load_persisted_index() -> Result<Option<SearchIndex>> {
    let path = state_path();
    if !path.exists() {
        return Ok(None);
    }
    let documents: Vec<CodeDocument> =
        serde_json::from_str(&std::fs::read_to_string(&path)?).context("failed to decode state.json")?;
    if documents.is_empty() {
        return Ok(None);
    }
    let index_dir = index_dir();
    if index_dir.exists() {
        match open_index(&documents)? {
            Some(idx) => Ok(Some(idx)),
            None => {
                tracing::warn!("persisted tantivy unusable; rebuilding from state.json");
                build_index(&documents, None).map(Some)
            }
        }
    } else {
        build_index(&documents, None).map(Some)
    }
}

/// 打开已有 Tantivy 目录并绑定内存中的文档与调用图。
/// 打开失败返回 `Ok(None)`，由调用方走全量重建（P0-8）。
fn open_index(documents: &[CodeDocument]) -> Result<Option<SearchIndex>> {
    let index_dir = index_dir();
    let index = match Index::open_in_dir(&index_dir) {
        Ok(idx) => idx,
        Err(err) => {
            tracing::warn!("failed to open tantivy index (will rebuild): {err:#}");
            return Ok(None);
        }
    };
    let schema = index.schema();
    let file = match schema.get_field("file") {
        Ok(f) => f,
        Err(_) => {
            tracing::warn!("tantivy missing file field; will rebuild");
            return Ok(None);
        }
    };
    let module = match schema.get_field("module") {
        Ok(f) => f,
        Err(_) => {
            tracing::warn!("tantivy missing module field; will rebuild");
            return Ok(None);
        }
    };
    let body = match schema.get_field("body") {
        Ok(f) => f,
        Err(_) => {
            tracing::warn!("tantivy missing body field; will rebuild");
            return Ok(None);
        }
    };
    let reader = match index.reader() {
        Ok(r) => r,
        Err(err) => {
            tracing::warn!("tantivy reader failed (will rebuild): {err:#}");
            return Ok(None);
        }
    };
    let call_graph_index = CallGraphIndex::from_documents(documents);
    let data_source_index = data_flow::DataSourceIndex::from_documents(documents);
    Ok(Some(
        SearchIndex {
            index,
            reader,
            fields: SearchFields { file, module, body },
            documents: slim_documents_from_slice(documents),
            call_graph_index,
            data_source_index,
            by_file: HashMap::new(),
            by_chunk: HashMap::new(),
            by_module: HashMap::new(),
            by_function: HashMap::new(),
            module_deps_map: HashMap::new(),
        }
        .with_lookups(),
    ))
}

/// 运行时文档瘦身：从切片克隆元数据并丢掉正文（避免先 to_vec 再 clear 的双倍峰值）。
fn slim_documents_from_slice(documents: &[CodeDocument]) -> Vec<CodeDocument> {
    documents
        .iter()
        .map(|d| {
            let mut copy = d.clone();
            copy.body.clear();
            copy
        })
        .collect()
}

/// 运行时文档瘦身：丢掉全文（Tantivy + 按需读盘已覆盖），保留符号/调用元数据。
fn slim_documents_for_runtime(mut documents: Vec<CodeDocument>) -> Vec<CodeDocument> {
    for doc in &mut documents {
        doc.body.clear();
    }
    documents
}

/// 按需从磁盘读取文档正文（索引 key 为绝对路径；旧相对 key 仍拼 ALI_ROOT）。
#[allow(dead_code)]
fn restore_bodies_from_disk(documents: &mut [CodeDocument]) {
    for doc in documents.iter_mut() {
        if !doc.body.is_empty() {
            continue;
        }
        let candidate = resolve_doc_file(&doc.file);
        if let Ok(body) = std::fs::read_to_string(&candidate) {
            doc.body = body;
        }
    }
}

/// 返回文档正文：内存中已有则直接用，否则按绝对/相对路径从磁盘按需补读。
///
/// mtime+size 预筛跳过的未变文件在内存中 body 为空；生成命中片段时用本函数惰性补读，
/// 避免 snippets 恒空，同时不为未变文件在索引阶段付出全量读盘成本。
pub(crate) fn effective_body(doc: &CodeDocument) -> std::borrow::Cow<'_, str> {
    if !doc.body.is_empty() {
        return std::borrow::Cow::Borrowed(&doc.body);
    }
    match std::fs::read_to_string(resolve_doc_file(&doc.file)) {
        Ok(body) => std::borrow::Cow::Owned(body),
        Err(_) => std::borrow::Cow::Borrowed(""),
    }
}

/// 正文磁盘读缓存（P1-3）。
///
/// 搜索命中 / 数据流追踪 / embed 拼正文都会对「未变更文件」反复 `read_to_string`，
/// 大项目下一次 hybrid 查询即可触发几十次整文件读盘。这里按 file 缓存 `Arc<str>`，
/// 以文档索引时的 `file_mtime` 校验有效性（文件被改且重新索引后 mtime 变化即失效），
/// 总字节数封顶（默认 64MB，`ALI_BODY_CACHE_MB` 可调），FIFO 淘汰。
struct BodyCache {
    map: HashMap<String, (u64, Arc<str>)>,
    order: std::collections::VecDeque<String>,
    total_bytes: usize,
    cap_bytes: usize,
}

impl BodyCache {
    fn new(cap_bytes: usize) -> Self {
        Self {
            map: HashMap::new(),
            order: std::collections::VecDeque::new(),
            total_bytes: 0,
            cap_bytes,
        }
    }

    fn get(&self, file: &str, mtime: u64) -> Option<Arc<str>> {
        match self.map.get(file) {
            Some((cached_mtime, body)) if *cached_mtime == mtime => Some(Arc::clone(body)),
            _ => None,
        }
    }

    fn put(&mut self, file: &str, mtime: u64, body: Arc<str>) {
        let bytes = body.len();
        if bytes > self.cap_bytes {
            return; // 单文件超上限：不缓存，直接返回
        }
        if let Some(old) = self.map.get(file) {
            self.total_bytes = self.total_bytes.saturating_sub(old.1.len());
        }
        while self.total_bytes + bytes > self.cap_bytes {
            let Some(oldest) = self.order.pop_front() else {
                break;
            };
            if let Some((_, old_body)) = self.map.remove(&oldest) {
                self.total_bytes = self.total_bytes.saturating_sub(old_body.len());
            }
        }
        self.order.push_back(file.to_string());
        self.total_bytes += bytes;
        self.map.insert(file.to_string(), (mtime, body));
    }
}

static BODY_CACHE: Mutex<Option<BodyCache>> = Mutex::new(None);

fn body_cache_cap_bytes() -> usize {
    std::env::var("ALI_BODY_CACHE_MB")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(64)
        .clamp(1, 1024)
        * 1024
        * 1024
}

/// 热路径正文获取：内存命中直接借用；磁盘读走 [`BODY_CACHE`] 缓存（mtime 校验）。
///
/// 返回 `Arc<str>` 以零拷贝共享缓存内容；调用方用 `&str` 方式使用即可。
pub(crate) fn effective_body_cached(doc: &CodeDocument) -> Arc<str> {
    if !doc.body.is_empty() {
        return Arc::from(doc.body.as_str());
    }
    {
        let mut guard = embedding::lock_or_recover(&BODY_CACHE);
        let cache = guard.get_or_insert_with(|| BodyCache::new(body_cache_cap_bytes()));
        if let Some(body) = cache.get(&doc.file, doc.file_mtime) {
            return body;
        }
    }
    let body: Arc<str> = std::fs::read_to_string(resolve_doc_file(&doc.file))
        .unwrap_or_default()
        .into();
    let mut guard = embedding::lock_or_recover(&BODY_CACHE);
    let cache = guard.get_or_insert_with(|| BodyCache::new(body_cache_cap_bytes()));
    cache.put(&doc.file, doc.file_mtime, Arc::clone(&body));
    body
}

/// 仅收集需要重新 embed 的 chunk，并只对这些文件读盘拼正文。
///
/// `force_all`（模型切换）时仍会覆盖全部 chunk，但按文件去重读盘一次。
fn chunks_needing_embed(
    documents: &[CodeDocument],
    store: &EmbeddingStore,
    force_all: bool,
) -> (Vec<FunctionChunk>, HashMap<String, String>) {
    let mut chunks = Vec::new();
    let mut bodies = HashMap::new();
    for doc in documents {
        let pending: Vec<&FunctionChunk> = doc
            .chunks
            .iter()
            .filter(|chunk| {
                if force_all {
                    return true;
                }
                let hash_ok = store
                    .chunk_hashes
                    .get(&chunk.id)
                    .map(|hash| hash == &chunk.hash)
                    .unwrap_or(false);
                !(hash_ok && store.vectors.contains_key(&chunk.id))
            })
            .collect();
        if pending.is_empty() {
            continue;
        }
        let body = effective_body_cached(doc);
        for chunk in pending {
            bodies.insert(
                chunk.id.clone(),
                lines_range(body.as_ref(), chunk.start_line, chunk.end_line),
            );
            chunks.push(chunk.clone());
        }
    }
    (chunks, bodies)
}

#[derive(Clone, Default)]
struct SearchFilter {
    module: Option<String>,
    function: Option<String>,
    arity: Option<usize>,
}

impl SearchIndex {
    /// 从 documents 构建 O(1) 查找表。
    fn build_lookups(
        documents: &[CodeDocument],
    ) -> (
        HashMap<String, usize>,
        HashMap<String, (usize, usize)>,
        HashMap<String, usize>,
        HashMap<(String, usize), Vec<usize>>,
        HashMap<String, Vec<String>>,
    ) {
        let mut by_file = HashMap::with_capacity(documents.len());
        let mut by_chunk = HashMap::new();
        let mut by_module = HashMap::new();
        let mut by_function: HashMap<(String, usize), Vec<usize>> = HashMap::new();
        let mut deps_sets: HashMap<String, std::collections::HashSet<String>> = HashMap::new();
        for (doc_idx, doc) in documents.iter().enumerate() {
            by_file.insert(doc.file.clone(), doc_idx);
            if let Some(ref m) = doc.module {
                by_module.insert(m.clone(), doc_idx);
            }
            for fun in &doc.functions {
                by_function
                    .entry((fun.name.clone(), fun.arity))
                    .or_default()
                    .push(doc_idx);
            }
            if let Some(ref from_mod) = doc.module {
                let entry = deps_sets.entry(from_mod.clone()).or_default();
                for edge in &doc.calls {
                    if let Some(ref to_mod) = edge.to_module {
                        if to_mod != from_mod {
                            entry.insert(to_mod.clone());
                        }
                    }
                }
            }
            for (chunk_idx, chunk) in doc.chunks.iter().enumerate() {
                by_chunk.insert(chunk.id.clone(), (doc_idx, chunk_idx));
            }
        }
        let module_deps_map = deps_sets
            .into_iter()
            .map(|(m, set)| (m, set.into_iter().collect()))
            .collect();
        (by_file, by_chunk, by_module, by_function, module_deps_map)
    }

    /// 填充全部查找表；每个 SearchIndex 构造点都应调用。
    fn with_lookups(mut self) -> Self {
        let (by_file, by_chunk, by_module, by_function, module_deps_map) =
            Self::build_lookups(&self.documents);
        self.by_file = by_file;
        self.by_chunk = by_chunk;
        self.by_module = by_module;
        self.by_function = by_function;
        self.module_deps_map = module_deps_map;
        self
    }

    /// 按 module 名查文档（优先查找表）。
    pub(crate) fn doc_by_module(&self, module: Option<&str>) -> Option<&CodeDocument> {
        let m = module?;
        if let Some(&idx) = self.by_module.get(m) {
            return self.documents.get(idx);
        }
        find_doc_by_module(&self.documents, module)
    }

    /// Tantivy BM25 全文检索，在 file/module/body 字段上查询。
    fn bm25_search(&self, query: &str, limit: usize) -> Result<Vec<SearchHit>> {
        let searcher = self.reader.searcher();
        // P2-3：file 是 STRING（raw、不分词），进 QueryParser 只能精确命中完整路径，
        // 反而稀释打分；文件路径文本已拼入 body 首行（searchable_body），按文件名
        // 检索经 body 分词命中即可。
        let parser = QueryParser::for_index(&self.index, vec![self.fields.module, self.fields.body]);
        // `module:function`、`gen_server:call`、`foo/2` 等含字段/特殊语法字符的高频
        // Erlang 查询用严格 parse 会整体报错（C-S6）。改用 lenient 解析；若仍有解析
        // 错误，则把特殊字符替换为空格后按词做布尔 OR，保证查询不整体失败。
        let (parsed, errors) = parser.parse_query_lenient(query);
        let parsed = if errors.is_empty() {
            parsed
        } else {
            let sanitized = sanitize_query_terms(query);
            let (fallback, _) = parser.parse_query_lenient(&sanitized);
            fallback
        };
        let top_docs = searcher.search(&parsed, &TopDocs::with_limit(limit.max(1)).order_by_score())?;

        let mut hits = Vec::new();
        for (score, address) in top_docs {
            if let Some(hit) = self.hit_from_address(score, address, query)? {
                hits.push(hit);
            }
        }
        Ok(hits)
    }

    /// 用本地 embedding store 做向量 Top-K，再映射为 `SearchHit`。
    fn hits_from_embeddings(
        &self,
        query_vector: &[f32],
        embeddings: &EmbeddingStore,
        query: &str,
        limit: usize,
    ) -> Vec<SearchHit> {
        let top = top_vector_hits(embeddings, query_vector, limit);
        top.into_iter()
            .filter_map(|(chunk_id, score)| self.hit_from_chunk(&chunk_id, score, query))
            .collect()
    }

    /// 从 Tantivy 文档地址反查文件并组装命中结果（含代码片段）。
    fn hit_from_address(&self, score: f32, address: tantivy::DocAddress, query: &str) -> Result<Option<SearchHit>> {
        let searcher = self.reader.searcher();
        let retrieved: tantivy::TantivyDocument = searcher.doc(address)?;
        let file = retrieved
            .get_first(self.fields.file)
            .and_then(|value| value.as_str())
            .unwrap_or_default()
            .to_string();
        let doc = if let Some(&idx) = self.by_file.get(&file) {
            self.documents.get(idx)
        } else {
            self.documents.iter().find(|doc| doc.file == file)
        };
        Ok(doc.map(|doc| SearchHit {
            file: doc.file.clone(),
            module: doc.module.clone(),
            score,
            functions: doc.functions.clone(),
            exports: doc.exports.clone(),
            records: doc.records.clone(),
            macros: doc.macros.clone(),
            snippets: snippets(&effective_body_cached(doc), query),
        }))
    }

    /// 按 chunk_id 定位函数块并生成向量检索命中（精确到函数行范围）。
    fn hit_from_chunk(&self, chunk_id: &str, score: f32, query: &str) -> Option<SearchHit> {
        if let Some(&(doc_idx, chunk_idx)) = self.by_chunk.get(chunk_id) {
            let doc = self.documents.get(doc_idx)?;
            let chunk = doc.chunks.get(chunk_idx)?;
            return Some(Self::hit_from_doc_chunk(doc, chunk, score, query));
        }
        self.documents.iter().find_map(|doc| {
            doc.chunks
                .iter()
                .find(|chunk| chunk.id == chunk_id)
                .map(|chunk| Self::hit_from_doc_chunk(doc, chunk, score, query))
        })
    }

    fn hit_from_doc_chunk(doc: &CodeDocument, chunk: &FunctionChunk, score: f32, query: &str) -> SearchHit {
        let functions = doc
            .functions
            .iter()
            .filter(|fun| fun.name == chunk.function && fun.arity == chunk.arity)
            .cloned()
            .collect();
        let full_body = effective_body_cached(doc);
        let body = lines_range(&full_body, chunk.start_line, chunk.end_line);
        // body 是从 chunk.start_line 起截取的片段，snippets 返回的行号相对片段；
        // 加上偏移换算为文件内绝对行号（M14）。
        let offset = chunk.start_line.saturating_sub(1);
        let mut snips = snippets(&body, query);
        for snip in &mut snips {
            snip.line += offset;
        }
        SearchHit {
            file: doc.file.clone(),
            module: doc.module.clone(),
            score,
            functions,
            exports: doc.exports.clone(),
            records: doc.records.clone(),
            macros: doc.macros.clone(),
            snippets: snips,
        }
    }

    /// 按 module/function/arity 过滤检索结果。
    fn matches_filter(&self, hit: &SearchHit, filter: &SearchFilter) -> bool {
        if let Some(module) = &filter.module {
            if hit.module.as_deref() != Some(module.as_str()) {
                return false;
            }
        }
        if let Some(function) = &filter.function {
            let has_fn = hit.functions.iter().any(|fun| fun.name == *function);
            if !has_fn {
                return false;
            }
        }
        if let Some(arity) = filter.arity {
            let has_arity = hit.functions.iter().any(|fun| fun.arity == arity);
            if !has_arity {
                return false;
            }
        }
        true
    }

    /// 在索引文档中查找匹配的 `FunctionSymbol`。
    fn get_symbol(&self, module: Option<&str>, function: &str, arity: usize) -> Option<FunctionSymbol> {
        if let Some(m) = module {
            let doc = self.doc_by_module(Some(m))?;
            return doc
                .functions
                .iter()
                .find(|fun| fun.name == function && fun.arity == arity)
                .cloned();
        }
        // P1-2：走 (name, arity) 反查表，避免无模块名时全表扫描所有函数。
        let doc_idxs = self.by_function.get(&(function.to_string(), arity))?;
        doc_idxs
            .iter()
            .filter_map(|idx| self.documents.get(*idx))
            .flat_map(|doc| doc.functions.iter())
            .find(|fun| fun.name == function && fun.arity == arity)
            .cloned()
    }

    /// 返回指定模块的完整符号表与 chunk 列表。
    fn module_symbols(&self, module: &str) -> Option<ModuleSymbols> {
        self.doc_by_module(Some(module)).map(|doc| ModuleSymbols {
            file: doc.file.clone(),
            module: doc.module.clone(),
            functions: doc.functions.clone(),
            exports: doc.exports.clone(),
            specs: doc.specs.clone(),
            callbacks: doc.callbacks.clone(),
            records: doc.records.clone(),
            macros: doc.macros.clone(),
            calls: doc.calls.clone(),
            chunks: doc.chunks.clone(),
            behaviours: doc.behaviours.clone(),
            test_cases: doc.test_cases.clone(),
            tech_debt: doc.tech_debt.clone(),
        })
    }

    /// 列出已索引模块摘要，支持按模块名/路径过滤。
    fn list_modules(&self, q: Option<&str>, offset: usize, limit: usize) -> ModulesListResponse {
        let needle = q
            .map(|s| s.trim().to_ascii_lowercase())
            .filter(|s| !s.is_empty());
        let mut items: Vec<ModuleListItem> = Vec::new();
        let mut remote_calls_total = 0usize;
        let mut call_edges_total = 0usize;
        for doc in &self.documents {
            let Some(module) = doc.module.as_deref() else {
                continue;
            };
            let remote = doc
                .calls
                .iter()
                .filter(|c| {
                    match (&c.to_module, &c.from_module) {
                        (Some(to), Some(from)) => to != from,
                        (Some(_), None) => true,
                        _ => false,
                    }
                })
                .count();
            remote_calls_total += remote;
            call_edges_total += doc.calls.len();
            if let Some(ref n) = needle {
                let mod_l = module.to_ascii_lowercase();
                let file_l = doc.file.to_ascii_lowercase();
                if !mod_l.contains(n) && !file_l.contains(n) {
                    continue;
                }
            }
            items.push(ModuleListItem {
                module: module.to_string(),
                file: doc.file.clone(),
                functions: doc.functions.len(),
                exports: doc.exports.len(),
                calls: doc.calls.len(),
                remote_calls: remote,
            });
        }
        items.sort_by(|a, b| a.module.cmp(&b.module));
        let total = items.len();
        let modules = items.into_iter().skip(offset).take(limit).collect();
        ModulesListResponse {
            total,
            offset,
            limit,
            modules,
            remote_calls_total,
            call_edges_total,
        }
    }

    /// 返回指定模块通过调用边依赖的其它模块（去重，不含自身）。
    /// 走构建期预算的 module_deps_map（O(1) 查表），不再每次扫描全项目调用边（P1-2）。
    fn module_deps(&self, module: &str) -> Vec<String> {
        self.module_deps_map.get(module).cloned().unwrap_or_default()
    }

    /// 导出全图调用边（委托 `CallGraphIndex`）。
    fn call_graph(&self) -> Vec<CallEdge> {
        self.call_graph_index.all_edges()
    }

    /// 查询调用者（委托 `CallGraphIndex::callers`）。
    fn callers(&self, module: Option<&str>, function: &str, arity: usize) -> Vec<CallEdge> {
        self.call_graph_index.callers(module, function, arity)
    }

    /// 查询被调用者（委托 `CallGraphIndex::callees`）。
    fn callees(&self, module: Option<&str>, function: &str, arity: usize) -> Vec<CallEdge> {
        self.call_graph_index.callees(module, function, arity)
    }
}

/// 把查询里的 tantivy 特殊语法字符替换为空格，得到纯词序列（用于 BM25 降级检索）。
fn sanitize_query_terms(query: &str) -> String {
    let cleaned: String = query
        .chars()
        .map(|ch| if ch.is_alphanumeric() || ch == '_' { ch } else { ' ' })
        .collect();
    cleaned.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// 合并 BM25 与向量结果：先各自 min-max 归一化到 [0,1]，再按权重加权，
/// 按文件去重后截断。避免 BM25 原始分（常 0..15+）压倒余弦相似度（0..1）。
fn merge_hybrid(mut bm25: Vec<SearchHit>, mut vector: Vec<SearchHit>, limit: usize) -> Vec<SearchHit> {
    let (bm25_w, vector_w) = hybrid_weights();
    normalize_hit_scores(&mut bm25);
    normalize_hit_scores(&mut vector);
    for hit in &mut bm25 {
        hit.score *= bm25_w;
    }
    for hit in &mut vector {
        hit.score *= vector_w;
    }
    bm25.append(&mut vector);
    bm25.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
    // 按文件全局去重（保留分数最高的那条）：dedup_by 只对相邻元素生效，排序后
    // 同一文件可能不相邻，必须用 HashSet 记录已见文件（M10）。
    let mut seen = std::collections::HashSet::new();
    bm25.retain(|hit| seen.insert(hit.file.clone()));
    bm25.truncate(limit.max(1));
    bm25
}

/// 将一组 hit 的 score 做 min-max 归一化到 [0,1]。全相等时置为 1.0。
fn normalize_hit_scores(hits: &mut [SearchHit]) {
    if hits.is_empty() {
        return;
    }
    let mut min_s = f32::INFINITY;
    let mut max_s = f32::NEG_INFINITY;
    for hit in hits.iter() {
        if hit.score.is_finite() {
            min_s = min_s.min(hit.score);
            max_s = max_s.max(hit.score);
        }
    }
    if !min_s.is_finite() || !max_s.is_finite() {
        return;
    }
    let span = max_s - min_s;
    if span <= f32::EPSILON {
        for hit in hits.iter_mut() {
            hit.score = 1.0;
        }
        return;
    }
    for hit in hits.iter_mut() {
        if hit.score.is_finite() {
            hit.score = (hit.score - min_s) / span;
        } else {
            hit.score = 0.0;
        }
    }
}

/// 读取混合搜索权重配置：
/// - `ALI_HYBRID_BM25_WEIGHT`（默认 0.6）
/// - `ALI_HYBRID_VECTOR_WEIGHT`（默认 0.4）
///
/// 两者需均为正数；任一非法时回退到默认值，避免误配置导致打分失效。
fn hybrid_weights() -> (f32, f32) {
    let bm25_w = std::env::var("ALI_HYBRID_BM25_WEIGHT")
        .ok()
        .and_then(|v| v.parse::<f32>().ok())
        .filter(|x| *x > 0.0)
        .unwrap_or(0.6);
    let vector_w = std::env::var("ALI_HYBRID_VECTOR_WEIGHT")
        .ok()
        .and_then(|v| v.parse::<f32>().ok())
        .filter(|x| *x > 0.0)
        .unwrap_or(0.4);
    (bm25_w, vector_w)
}

/// 拼接写入 Tantivy 的可搜索文本（路径、模块、符号名、正文）。
fn searchable_body(doc: &CodeDocument) -> String {
    let functions = doc
        .functions
        .iter()
        .map(|fun| format!("{}/{}", fun.name, fun.arity))
        .collect::<Vec<_>>()
        .join(" ");
    format!(
        "{}\n{}\n{}\n{}\n{}\n{}\n{}",
        doc.file,
        doc.module.clone().unwrap_or_default(),
        functions,
        doc.exports.iter().map(|item| format!("{}/{}", item.name, item.arity)).collect::<Vec<_>>().join(" "),
        doc.records.iter().map(|item| item.name.clone()).collect::<Vec<_>>().join(" "),
        doc.macros.iter().map(|item| item.name.clone()).collect::<Vec<_>>().join(" "),
        effective_body(doc)
    )
}

struct ParsedErlang {
    module: Option<String>,
    functions: Vec<FunctionSymbol>,
    exports: Vec<FaSymbol>,
    specs: Vec<FaSymbol>,
    callbacks: Vec<FaSymbol>,
    records: Vec<NamedSymbol>,
    macros: Vec<NamedSymbol>,
    calls: Vec<RawCall>,
    behaviours: Vec<String>,
}

#[derive(Clone)]
struct RawCall {
    to_module: Option<String>,
    to_function: String,
    arity: usize,
    line: usize,
}

/// 编译一次、全局复用的 tree-sitter query 集合（Query 编译本身很贵）。
struct ErlangQuerySet {
    language: tree_sitter::Language,
    module: Query,
    functions: Query,
    exports: Query,
    specs: Query,
    callbacks: Query,
    records: Query,
    macros: Query,
    calls: Query,
    behaviour: Query,
}

fn erlang_queries() -> &'static ErlangQuerySet {
    static QUERIES: OnceLock<ErlangQuerySet> = OnceLock::new();
    QUERIES.get_or_init(|| {
        let language: tree_sitter::Language = tree_sitter_erlang::LANGUAGE.into();
        let q = |lang: &tree_sitter::Language, source: &str| {
            Query::new(lang, source).unwrap_or_else(|err| {
                panic!("failed to compile Erlang tree-sitter query: {err}; source={source}")
            })
        };
        ErlangQuerySet {
            language: language.clone(),
            module: q(&language, r#"(module_attribute name: (_) @name) @item"#),
            functions: q(
                &language,
                r#"
                (function_clause
                  name: (atom) @function.name
                  args: (expr_args) @function.args) @function.clause
                "#,
            ),
            exports: q(
                &language,
                r#"(export_attribute funs: (fa fun: (_) @name arity: (arity) @arity) @item)"#,
            ),
            specs: q(
                &language,
                r#"(spec fun: (_) @name sigs: (type_sig args: (expr_args) @args) @item)"#,
            ),
            callbacks: q(
                &language,
                r#"(callback fun: (_) @name sigs: (type_sig args: (expr_args) @args) @item)"#,
            ),
            records: q(&language, r#"(record_decl name: (_) @name) @item"#),
            macros: q(
                &language,
                r#"(pp_define lhs: (macro_lhs name: (_) @name) @item)"#,
            ),
            calls: q(
                &language,
                r#"
                (call
                  expr: (atom) @function
                  args: (expr_args) @args) @call
                (remote
                  module: (remote_module module: (atom) @module)
                  fun: (call
                    expr: (atom) @function
                    args: (expr_args) @args)) @call
                "#,
            ),
            behaviour: q(&language, r#"(behaviour_attribute name: (_) @name) @item"#),
        }
    })
}

thread_local! {
    /// Parser 非 Sync：每条索引线程各持一份，避免反复 Parser::new。
    static ERLANG_PARSER: RefCell<Option<tree_sitter::Parser>> = const { RefCell::new(None) };
}

fn with_erlang_parser<R>(f: impl FnOnce(&mut tree_sitter::Parser) -> R) -> R {
    ERLANG_PARSER.with(|cell| {
        let mut slot = cell.borrow_mut();
        if slot.is_none() {
            let mut parser = tree_sitter::Parser::new();
            let language = erlang_queries().language.clone();
            parser
                .set_language(&language)
                .expect("failed to load tree-sitter-erlang grammar");
            *slot = Some(parser);
        }
        f(slot.as_mut().expect("erlang parser"))
    })
}

/// 用 tree-sitter-erlang 解析源码，提取模块、函数、export、调用等结构。
fn parse_erlang(body: &str) -> Result<ParsedErlang> {
    let qs = erlang_queries();
    let tree = with_erlang_parser(|parser| {
        parser
            .parse(body, None)
            .ok_or_else(|| anyhow!("failed to parse Erlang source"))
    })?;
    let root = tree.root_node();
    let module = extract_module_from_query(&qs.module, root, body)?;
    let functions = extract_functions_from_query(&qs.functions, root, body)?;
    Ok(ParsedErlang {
        module,
        exports: extract_fa_from_query(&qs.exports, root, body)?,
        specs: extract_fa_from_query(&qs.specs, root, body)?,
        callbacks: extract_fa_from_query(&qs.callbacks, root, body)?,
        records: extract_named_from_query(&qs.records, root, body)?,
        macros: extract_named_from_query(&qs.macros, root, body)?,
        calls: extract_calls_from_query(&qs.calls, root, body)?,
        functions,
        behaviours: extract_behaviours_cached(&qs.behaviour, root, body),
    })
}

/// 提取 `-behaviour(Name).` 声明：优先用 tree-sitter query；失败则回退正则。
fn extract_behaviours_cached(
    query: &Query,
    root: tree_sitter::Node<'_>,
    body: &str,
) -> Vec<String> {
    if let Ok(items) = extract_named_from_query(query, root, body) {
        let names: Vec<String> = items.into_iter().map(|n| n.name.clone()).collect();
        if !names.is_empty() {
            return names;
        }
    }
    let mut out = Vec::new();
    for line in body.lines() {
        let trimmed = line.trim();
        let rest = match trimmed
            .strip_prefix("-behaviour(")
            .or_else(|| trimmed.strip_prefix("-behavior("))
        {
            Some(r) => r,
            None => continue,
        };
        if let Some(end) = rest.find(')') {
            let name = rest[..end].trim().trim_end_matches('.').trim();
            if !name.is_empty() {
                out.push(name.to_string());
            }
        }
    }
    out
}

/// 提取测试用例与被测函数的关联。
///
/// 仅对 `_tests.erl` / `_test.erl` 文件生效（EUnit 约定）。识别两种测试函数名：
/// - `foo_test`：简单测试，目标函数为 `foo`；
/// - `foo_test_`：生成器测试，目标函数同样为 `foo`。
///
/// `target_arity` 默认为 0，因为测试函数名不携带被测函数的元数信息。
fn extract_test_cases(functions: &[FunctionSymbol], file: &str) -> Vec<TestCase> {
    let lower = file.to_ascii_lowercase();
    let is_test_file = lower.ends_with("_tests.erl") || lower.ends_with("_test.erl");
    if !is_test_file {
        return Vec::new();
    }

    let mut cases = Vec::new();
    for fun in functions {
        // 先匹配生成器 `_test_`（trailing underscore），再匹配简单 `_test`，
        // 避免 `foo_test_` 被 `strip_suffix("_test")` 截成 `foo_`。
        let target = fun
            .name
            .strip_suffix("_test_")
            .or_else(|| fun.name.strip_suffix("_test"))
            .map(|s| s.to_string());

        if let Some(target_function) = target {
            if target_function.is_empty() {
                continue;
            }
            cases.push(TestCase {
                test_function: fun.name.clone(),
                test_arity: fun.arity,
                target_function,
                target_arity: 0,
                line: fun.line,
            });
        }
    }
    cases
}

/// 提取 `%% TODO` / `%% FIXME` / `%% HACK` / `%% XXX` 技术债标记。
///
/// 逐行扫描 Erlang 行注释（`%%`），大小写不敏感匹配标记前缀；
/// 标记类型以小写形式存入 `kind`，行内剩余文本（trim 后）存入 `text`。
fn extract_tech_debt(body: &str) -> Vec<TechDebtMark> {
    const MARKERS: &[(&str, &str)] = &[
        ("TODO", "todo"),
        ("FIXME", "fixme"),
        ("HACK", "hack"),
        ("XXX", "xxx"),
    ];
    let mut marks = Vec::new();
    for (idx, line) in body.lines().enumerate() {
        let trimmed = line.trim_start();
        let rest = match trimmed.strip_prefix("%%") {
            Some(r) => r,
            None => continue,
        };
        let after_ws = rest.trim_start();
        let upper = after_ws.to_ascii_uppercase();
        for &(marker, kind) in MARKERS {
            if upper.starts_with(marker) {
                let text = after_ws[marker.len()..].trim().to_string();
                marks.push(TechDebtMark {
                    kind: kind.to_string(),
                    line: idx + 1,
                    text,
                });
                break;
            }
        }
    }
    marks
}

/// 用 tree-sitter query 提取 `-module(Name)` 属性。
fn extract_module_from_query(
    query: &Query,
    root: tree_sitter::Node<'_>,
    body: &str,
) -> Result<Option<String>> {
    let items = extract_named_from_query(query, root, body)?;
    Ok(items.first().map(|item| item.name.clone()))
}

/// 提取函数定义：名称、元组、行号范围及子句（clause）列表。
fn extract_functions_from_query(
    query: &Query,
    root: tree_sitter::Node<'_>,
    body: &str,
) -> Result<Vec<FunctionSymbol>> {
    let capture_names = query.capture_names();
    let mut cursor = QueryCursor::new();
    let mut matches = cursor.matches(query, root, body.as_bytes());
    let mut symbols: BTreeMap<(String, usize), (String, usize, usize, Vec<ClauseRange>)> = BTreeMap::new();

    while let Some(query_match) = matches.next() {
        let mut name = None;
        let mut args = None;
        let mut clause = None;

        for capture in query_match.captures {
            match capture_names[capture.index as usize].as_ref() {
                "function.name" => {
                    name = Some(capture.node.utf8_text(body.as_bytes())?.to_string());
                }
                "function.args" => {
                    args = Some(capture.node);
                }
                "function.clause" => {
                    clause = Some(capture.node);
                }
                _ => {}
            }
        }

        if let (Some(name), Some(args), Some(clause)) = (name, args, clause) {
            let arity = arity_from_args(args);
            let range = node_range(clause);
            let entry = symbols
                .entry((name.clone(), arity))
                .or_insert_with(|| (name, arity, range.start_line, Vec::new()));
            entry.2 = entry.2.min(range.start_line);
            entry.3.push(range);
        }
    }

    Ok(symbols
        .into_values()
        .map(|(name, arity, line, mut clauses)| {
            clauses.sort_by_key(|range| range.start_line);
            let start_line = clauses.first().map(|range| range.start_line).unwrap_or(line);
            let end_line = clauses.last().map(|range| range.end_line).unwrap_or(line);
            FunctionSymbol {
                name,
                arity,
                line,
                start_line,
                end_line,
                clauses,
            }
        })
        .collect())
}

/// 通用 FA（函数/元组）符号提取：export、spec、callback 等共用。
fn extract_fa_from_query(
    query: &Query,
    root: tree_sitter::Node<'_>,
    body: &str,
) -> Result<Vec<FaSymbol>> {
    let capture_names = query.capture_names();
    let mut cursor = QueryCursor::new();
    let mut matches = cursor.matches(query, root, body.as_bytes());
    let mut items = Vec::new();

    while let Some(query_match) = matches.next() {
        let mut name = None;
        let mut arity = None;
        let mut args = None;
        let mut item = None;

        for capture in query_match.captures {
            match capture_names[capture.index as usize].as_ref() {
                "name" => name = Some(capture.node.utf8_text(body.as_bytes())?.to_string()),
                "arity" => arity = capture.node.utf8_text(body.as_bytes())?.parse::<usize>().ok(),
                "args" => args = Some(arity_from_args(capture.node)),
                "item" => item = Some(capture.node),
                _ => {}
            }
        }

        if let (Some(name), Some(item)) = (name, item) {
            items.push(FaSymbol {
                name,
                arity: arity.or(args).unwrap_or(0),
                line: item.start_position().row + 1,
            });
        }
    }

    Ok(items)
}

/// 提取仅含名称的符号：record、macro 等。
fn extract_named_from_query(
    query: &Query,
    root: tree_sitter::Node<'_>,
    body: &str,
) -> Result<Vec<NamedSymbol>> {
    let capture_names = query.capture_names();
    let mut cursor = QueryCursor::new();
    let mut matches = cursor.matches(query, root, body.as_bytes());
    let mut items = Vec::new();

    while let Some(query_match) = matches.next() {
        let mut name = None;
        let mut item = None;

        for capture in query_match.captures {
            match capture_names[capture.index as usize].as_ref() {
                "name" => name = Some(capture.node.utf8_text(body.as_bytes())?.to_string()),
                "item" => item = Some(capture.node),
                _ => {}
            }
        }

        if let (Some(name), Some(item)) = (name, item) {
            items.push(NamedSymbol {
                name,
                line: item.start_position().row + 1,
            });
        }
    }

    Ok(items)
}

/// 提取本地调用、`M:F(...)` 远程调用，以及 apply/spawn/fun 常见形态。
fn extract_calls_from_query(
    query: &Query,
    root: tree_sitter::Node<'_>,
    body: &str,
) -> Result<Vec<RawCall>> {
    let capture_names = query.capture_names();
    let mut cursor = QueryCursor::new();
    let mut matches = cursor.matches(query, root, body.as_bytes());
    let mut calls = Vec::new();

    while let Some(query_match) = matches.next() {
        let mut to_module = None;
        let mut to_function = None;
        let mut arity = None;
        let mut call = None;

        for capture in query_match.captures {
            match capture_names[capture.index as usize].as_ref() {
                "module" => to_module = Some(capture.node.utf8_text(body.as_bytes())?.to_string()),
                "function" => to_function = Some(capture.node.utf8_text(body.as_bytes())?.to_string()),
                "args" => arity = Some(arity_from_args(capture.node)),
                "call" => call = Some(capture.node),
                _ => {}
            }
        }

        if let (Some(to_function), Some(call)) = (to_function, call) {
            // tree-sitter-erlang 把 `M:F(Args)` 解析为
            // `(remote module: … fun: (call expr: (atom) args: …))`，
            // 内层 call 也会命中本地模式；无 module 且父节点是 remote 时跳过，避免丢模块名。
            if to_module.is_none()
                && call
                    .parent()
                    .map(|p| p.kind() == "remote")
                    .unwrap_or(false)
            {
                continue;
            }
            let mut call = RawCall {
                to_module,
                to_function: to_function.clone(),
                arity: arity.unwrap_or(0),
                line: call.start_position().row + 1,
            };
            enrich_otp_call_patterns(&mut call, body);
            calls.push(call);
        }
    }

    calls.extend(extract_fun_refs_from_source(body));
    Ok(calls)
}

fn extract_fun_refs_from_source(body: &str) -> Vec<RawCall> {
    let mut out = Vec::new();
    for (idx, line) in body.lines().enumerate() {
        // Match: fun foo/2  or fun ?MODULE:bar/1 (local name only for now)
        let bytes = line.as_bytes();
        let mut search_from = 0usize;
        while let Some(rel) = line[search_from..].find("fun ") {
            let start = search_from + rel + 4;
            let rest = &line[start..];
            let name_end = rest
                .find(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
                .unwrap_or(rest.len());
            if name_end == 0 {
                search_from = start;
                continue;
            }
            let name = &rest[..name_end];
            let after = &rest[name_end..];
            if let Some(stripped) = after.strip_prefix('/') {
                let arity_end = stripped
                    .find(|c: char| !c.is_ascii_digit())
                    .unwrap_or(stripped.len());
                if arity_end > 0 {
                    if let Ok(arity) = stripped[..arity_end].parse::<usize>() {
                        out.push(RawCall {
                            to_module: None,
                            to_function: name.to_string(),
                            arity,
                            line: idx + 1,
                        });
                    }
                }
            }
            search_from = start + name_end;
            if search_from >= bytes.len() {
                break;
            }
        }
    }
    out
}

/// Best-effort enrichment for apply/spawn/spawn_link when args are literal atoms.
fn enrich_otp_call_patterns(call: &mut RawCall, body: &str) {
    let name = call.to_function.as_str();
    if !matches!(name, "apply" | "spawn" | "spawn_link" | "spawn_monitor") {
        return;
    }
    // Look at the source line for `apply(Mod, Fun, [...])` / `spawn(Mod, Fun, [...])`.
    let line = body.lines().nth(call.line.saturating_sub(1)).unwrap_or("");
    if let Some((mod_name, fun_name, arity)) = parse_mfa_call_line(line, name) {
        call.to_module = Some(mod_name);
        call.to_function = fun_name;
        call.arity = arity;
    }
}

fn parse_mfa_call_line(line: &str, callee: &str) -> Option<(String, String, usize)> {
    let trimmed = line.trim();
    let prefix = format!("{callee}(");
    let start = trimmed.find(&prefix)? + prefix.len();
    let rest = &trimmed[start..];
    // Expect: Module, Function, [Args...]
    let parts: Vec<&str> = rest.splitn(3, ',').collect();
    if parts.len() < 3 {
        return None;
    }
    let mod_name = parts[0].trim().trim_matches(|c: char| !c.is_ascii_alphanumeric() && c != '_');
    let fun_name = parts[1].trim().trim_matches(|c: char| !c.is_ascii_alphanumeric() && c != '_');
    if mod_name.is_empty() || fun_name.is_empty() {
        return None;
    }
    let args_part = parts[2];
    let arity = count_list_arity(args_part);
    Some((mod_name.to_string(), fun_name.to_string(), arity))
}

/// Count top-level elements inside the first `[...]` list (handles nesting).
fn count_list_arity(args_part: &str) -> usize {
    let open = match args_part.find('[') {
        Some(i) => i,
        None => return 0,
    };
    let bytes = args_part.as_bytes();
    let mut depth = 0i32;
    let mut count = 0usize;
    let mut in_elem = false;
    for &b in &bytes[open..] {
        match b {
            b'[' => {
                depth += 1;
                if depth == 1 {
                    in_elem = false;
                }
            }
            b']' => {
                if depth == 1 && in_elem {
                    count += 1;
                    in_elem = false;
                }
                depth -= 1;
                if depth <= 0 {
                    break;
                }
            }
            b',' if depth == 1 => {
                if in_elem {
                    count += 1;
                }
                in_elem = false;
            }
            b' ' | b'\t' | b'\n' | b'\r' => {}
            _ if depth >= 1 => {
                in_elem = true;
            }
            _ => {}
        }
    }
    count
}

/// 为每条原始调用边填充 `from_module` / `from_function`（按行号归属函数）。
/// 本地调用（无 to_module）归属当前模块，避免 `_:fun/arity` 跨模块歧义。
fn attach_call_sources(module: Option<String>, calls: Vec<RawCall>, functions: &[FunctionSymbol]) -> Vec<CallEdge> {
    calls
        .into_iter()
        .map(|call| {
            let owner = functions
                .iter()
                .find(|fun| call.line >= fun.start_line && call.line <= fun.end_line);
            let from_function = owner.map(|fun| fun.name.clone());
            let from_arity = owner.map(|fun| fun.arity).unwrap_or(0);
            let to_module = call.to_module.clone().or_else(|| module.clone());
            CallEdge {
                from_module: module.clone(),
                from_function,
                from_arity,
                to_module,
                to_function: call.to_function,
                arity: call.arity,
                line: call.line,
            }
        })
        .collect()
}

/// 为每个函数生成可向量化索引的 chunk（id、行范围、内容哈希）。
///
/// 生产路径已改用 `semantic_chunks`（含函数边界+间隙+大函数子分块）；
/// 此函数保留供测试直接构造 chunk，不参与 release 构建调用图。
#[allow(dead_code)]
fn function_chunks(file: &str, module: Option<String>, body: &str, functions: &[FunctionSymbol]) -> Vec<FunctionChunk> {
    functions
        .iter()
        .map(|fun| {
            let code = lines_range(body, fun.start_line, fun.end_line);
            let hash = stable_hash(&code);
            FunctionChunk {
                id: format!("{}:{}:{}/{}", file, module.clone().unwrap_or_default(), fun.name, fun.arity),
                file: file.to_string(),
                module: module.clone(),
                function: fun.name.clone(),
                arity: fun.arity,
                start_line: fun.start_line,
                end_line: fun.end_line,
                hash,
            }
        })
        .collect()
}

/// 提取源码中 `[start_line, end_line]` 闭区间内的行文本。
fn lines_range(body: &str, start_line: usize, end_line: usize) -> String {
    body.lines()
        .enumerate()
        .filter(|(idx, _)| {
            let line = idx + 1;
            line >= start_line && line <= end_line
        })
        .map(|(_, line)| line)
        .collect::<Vec<_>>()
        .join("\n")
}

/// Stable FNV-1a 64-bit hash (cross-platform / cross-Rust-version).
fn stable_hash(value: &str) -> String {
    format!("{:016x}", fnv1a64(value.as_bytes()))
}

/// 判断 `chunk_id` 是否归属于 `file`（任务 #3）。
///
/// chunk_id 格式为 `{file}:{func}/{arity}` / `{file}:#gap:{idx}` / `{file}:#text:{idx}`，
/// 即 file 之后必跟 `:`。仅用 `starts_with(file)` 会误匹配同族路径
/// （如 file=`src/foo.erl` 命中 chunk_id=`src/foo.erl.bak:bar/1`），因此额外校验
/// 分隔符。`file` 自身不含 `:` 时（Windows 盘符 `C:` 除外，盘符后通常跟 `\`）此校验安全。
pub(crate) fn chunk_matches_file(chunk_id: &str, file: &str) -> bool {
    chunk_id.starts_with(file) && chunk_id.as_bytes().get(file.len()) == Some(&b':')
}

fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf29ce484222325;
    for b in bytes {
        hash ^= u64::from(*b);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

/// 将 tree-sitter 节点转为 1-based 行号范围。
fn node_range(node: tree_sitter::Node<'_>) -> ClauseRange {
    ClauseRange {
        start_line: node.start_position().row + 1,
        end_line: node.end_position().row + 1,
    }
}

/// 从 `expr_args` 节点统计参数个数作为函数元组。
fn arity_from_args(args: tree_sitter::Node<'_>) -> usize {
    let mut cursor = args.walk();
    args.children_by_field_name("args", &mut cursor).count()
}

/// 零拷贝探测：本轮是否存在需要 embed / 清理的 chunk（P0-2）。
///
/// 只读 `chunk_hashes` / `vectors` 的键与哈希，不克隆任何向量；
/// 只有返回 true 时调用方才克隆工作副本。
fn embedding_work_needed(store: &EmbeddingStore, documents: &[CodeDocument]) -> bool {
    for doc in documents {
        for chunk in &doc.chunks {
            let hash_ok = store
                .chunk_hashes
                .get(&chunk.id)
                .map(|hash| hash == &chunk.hash)
                .unwrap_or(false);
            if !(hash_ok && store.vectors.contains_key(&chunk.id)) {
                return true;
            }
        }
    }
    has_stale_code_vectors(store, documents)
}

/// 零拷贝探测：store 中是否存留已不在文档集合内的代码向量（memory:* 除外）。
fn has_stale_code_vectors(store: &EmbeddingStore, documents: &[CodeDocument]) -> bool {
    if store.vectors.is_empty() {
        return false;
    }
    let live: std::collections::HashSet<&str> = documents
        .iter()
        .flat_map(|doc| doc.chunks.iter().map(|chunk| chunk.id.as_str()))
        .collect();
    for key in store.vectors.keys() {
        let k: &str = key.as_str();
        if !k.starts_with("memory:") && !live.contains(k) {
            return true;
        }
    }
    false
}

/// 只读列出待清理的陈旧代码向量 id（不修改 store），供「确有写入才克隆」的零拷贝探测。
fn stale_code_vector_ids(store: &EmbeddingStore, documents: &[CodeDocument]) -> Vec<String> {
    let live: std::collections::HashSet<&str> = documents
        .iter()
        .flat_map(|doc| doc.chunks.iter().map(|chunk| chunk.id.as_str()))
        .collect();
    let mut stale = Vec::new();
    for key in store.vectors.keys() {
        let k: &str = key.as_str();
        if !k.starts_with("memory:") && !live.contains(k) {
            stale.push(key.clone());
        }
    }
    stale
}

/// 删除索引中已不存在的代码 chunk 向量，保留 `memory:*` 键。
fn purge_stale_code_vectors(store: &mut EmbeddingStore, documents: &[CodeDocument]) -> Vec<String> {
    use std::collections::HashSet;
    // P2-15：借用 &str 建集，不为每个 chunk id 克隆 String。
    let live: HashSet<&str> = documents
        .iter()
        .flat_map(|doc| doc.chunks.iter().map(|chunk| chunk.id.as_str()))
        .collect();
    let mut removed: Vec<String> = Vec::new();
    for key in store.vectors.keys() {
        let k: &str = key.as_str();
        if !k.starts_with("memory:") && !live.contains(k) {
            removed.push(key.clone());
        }
    }
    store
        .vectors
        .retain(|key, _| key.starts_with("memory:") || live.contains(key.as_str()));
    store
        .chunk_hashes
        .retain(|key, _| key.starts_with("memory:") || live.contains(key.as_str()));
    if !removed.is_empty() {
        store.touch_vectors();
    }
    removed
}

/// 从命中正文中抽取最多 5 行代码片段，优先包含查询关键词的行。
fn snippets(body: &str, query: &str) -> Vec<Snippet> {
    if query.trim().is_empty() {
        return body
            .lines()
            .enumerate()
            .filter(|(_, line)| !line.trim().is_empty())
            .take(5)
            .map(|(idx, line)| Snippet {
                line: idx + 1,
                text: line.trim().chars().take(240).collect(),
            })
            .collect();
    }

    let tokens = query
        .split(|ch: char| !ch.is_alphanumeric() && ch != '_' && ch != ':' && ch != '/')
        .filter(|token| !token.is_empty())
        .map(|token| token.to_lowercase())
        .collect::<Vec<_>>();

    body.lines()
        .enumerate()
        .filter(|(_, line)| {
            let lower = line.to_lowercase();
            tokens.iter().any(|token| lower.contains(token))
        })
        .take(5)
        .map(|(idx, line)| Snippet {
            line: idx + 1,
            text: line.trim().chars().take(240).collect(),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_functions_with_tree_sitter_query() {
        let source = r#"
-module(sample).

start() ->
    ok.

handle_call({get, Key}, _From, State) when is_atom(Key) ->
    {reply, ok, State};
handle_call(_Req, _From, State) ->
    {reply, error, State}.

multi_line(
    First,
    Second
) ->
    {First, Second}.
"#;

        let functions = parse_erlang(source).expect("source should parse").functions;
        let pairs = functions
            .iter()
            .map(|fun| (fun.name.as_str(), fun.arity))
            .collect::<Vec<_>>();

        assert!(pairs.contains(&("start", 0)));
        assert!(pairs.contains(&("handle_call", 3)));
        assert!(pairs.contains(&("multi_line", 2)));
        assert_eq!(pairs.iter().filter(|pair| **pair == ("handle_call", 3)).count(), 1);
    }

    #[test]
    fn indexes_and_searches_symbols() {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let index_path = std::env::temp_dir().join(format!("ali_tantivy_unit_{nanos}"));
        let _ = std::fs::remove_dir_all(&index_path);
        let source = r#"
-module(sample_index).
-export([start/0]).
-record(state, {value}).
-define(DEFAULT_VALUE, 1).

start() ->
    gen_server:call(worker, ping).
"#;
        let parsed = parse_erlang(source).expect("source should parse");
        let functions = parsed.functions;
        let file = "sample_index.erl".to_string();
        let module = parsed.module;
        let chunks = function_chunks(&file, module.clone(), source, &functions);
        let calls = attach_call_sources(module.clone(), parsed.calls, &functions);
        let index = build_index_at(
            &[CodeDocument {
            file,
            module,
            body: source.to_string(),
            functions,
            exports: parsed.exports,
            specs: parsed.specs,
            callbacks: parsed.callbacks,
            records: parsed.records,
            macros: parsed.macros,
            calls,
            chunks,
            behaviours: parsed.behaviours.clone(),
            test_cases: Vec::new(),
            tech_debt: Vec::new(),
            data_sources: Some(Vec::new()),
            file_hash: stable_hash(source),
            file_mtime: 0,
            file_size: 0,
            call_extract_version: CALL_EXTRACT_VERSION,
            }],
            &index_path,
            None,
        )
        .expect("index should build");

        let hits = index
            .bm25_search("start", 5)
            .expect("search should work");
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].module.as_deref(), Some("sample_index"));
        assert_eq!(hits[0].exports[0].name, "start");
        assert_eq!(hits[0].records[0].name, "state");
        assert_eq!(hits[0].macros[0].name, "DEFAULT_VALUE");
        std::fs::remove_dir_all(index_path).ok();
    }

    #[test]
    fn snippets_use_query_tokens() {
        let body = "start() -> ok.\nhandle_call(X) -> ok.";
        let hits = snippets(body, "handle_call");
        assert!(!hits.is_empty());
        assert!(hits.iter().any(|s| s.text.contains("handle_call")));
    }

    #[test]
    fn incremental_index_skips_unchanged_files() {
        let dir = std::env::temp_dir().join(format!("ali_inc_{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let file = dir.join("sample.erl");
        std::fs::write(&file, "-module(sample).\nstart() -> ok.\n").expect("write sample");

        let (docs1, stats1) = incremental_documents(&dir, Vec::new()).expect("first index");
        assert_eq!(docs1.len(), 1);
        assert_eq!(stats1.updated, 1);
        assert_eq!(stats1.skipped, 0);

        let (docs2, stats2) = incremental_documents(&dir, docs1).expect("second index");
        assert_eq!(docs2.len(), 1);
        assert_eq!(stats2.updated, 0);
        assert_eq!(stats2.skipped, 1);
        assert!(!stats2.needs_reindex());

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn purge_stale_code_vectors_keeps_memory() {
        let mut store = EmbeddingStore::default();
        store.vectors.insert("memory:42".to_string(), vec![1.0, 0.0]);
        store.vectors.insert("stale-chunk".to_string(), vec![0.5, 0.5]);
        store
            .chunk_hashes
            .insert("stale-chunk".to_string(), "old".to_string());

        store.vectors.insert("live-chunk".to_string(), vec![1.0, 0.0]);
        store
            .chunk_hashes
            .insert("live-chunk".to_string(), "h".to_string());

        let documents = vec![CodeDocument {
            file: "live.erl".to_string(),
            module: Some("live".to_string()),
            body: String::new(),
            functions: Vec::new(),
            exports: Vec::new(),
            specs: Vec::new(),
            callbacks: Vec::new(),
            records: Vec::new(),
            macros: Vec::new(),
            calls: Vec::new(),
            chunks: vec![FunctionChunk {
                id: "live-chunk".to_string(),
                file: "live.erl".to_string(),
                module: Some("live".to_string()),
                function: "start".to_string(),
                arity: 0,
                start_line: 1,
                end_line: 1,
                hash: "h".to_string(),
            }],
            behaviours: Vec::new(),
            test_cases: Vec::new(),
            tech_debt: Vec::new(),
            data_sources: Some(Vec::new()),
            file_hash: String::new(),
            file_mtime: 0,
            file_size: 0,
            call_extract_version: CALL_EXTRACT_VERSION,
        }];

        purge_stale_code_vectors(&mut store, &documents);
        assert!(store.vectors.contains_key("memory:42"));
        assert!(!store.vectors.contains_key("stale-chunk"));
        assert!(store.vectors.contains_key("live-chunk"));
    }

    #[test]
    fn chunks_needing_embed_skips_cached_and_reads_only_pending() {
        let mut store = EmbeddingStore::default();
        store.vectors.insert("a".to_string(), vec![0.1]);
        store.chunk_hashes.insert("a".to_string(), "ha".to_string());

        let documents = vec![
            CodeDocument {
                file: "cached.erl".to_string(),
                module: Some("cached".to_string()),
                body: String::new(),
                functions: Vec::new(),
                exports: Vec::new(),
                specs: Vec::new(),
                callbacks: Vec::new(),
                records: Vec::new(),
                macros: Vec::new(),
                calls: Vec::new(),
                chunks: vec![FunctionChunk {
                    id: "a".to_string(),
                    file: "cached.erl".to_string(),
                    module: Some("cached".to_string()),
                    function: "ok".to_string(),
                    arity: 0,
                    start_line: 1,
                    end_line: 1,
                    hash: "ha".to_string(),
                }],
                behaviours: Vec::new(),
                test_cases: Vec::new(),
                tech_debt: Vec::new(),
                data_sources: Some(Vec::new()),
                file_hash: String::new(),
                file_mtime: 0,
                file_size: 0,
                call_extract_version: CALL_EXTRACT_VERSION,
            },
            CodeDocument {
                file: "new.erl".to_string(),
                module: Some("new".to_string()),
                body: "start() -> ok.\n".to_string(),
                functions: Vec::new(),
                exports: Vec::new(),
                specs: Vec::new(),
                callbacks: Vec::new(),
                records: Vec::new(),
                macros: Vec::new(),
                calls: Vec::new(),
                chunks: vec![FunctionChunk {
                    id: "b".to_string(),
                    file: "new.erl".to_string(),
                    module: Some("new".to_string()),
                    function: "start".to_string(),
                    arity: 0,
                    start_line: 1,
                    end_line: 1,
                    hash: "hb".to_string(),
                }],
                behaviours: Vec::new(),
                test_cases: Vec::new(),
                tech_debt: Vec::new(),
                data_sources: Some(Vec::new()),
                file_hash: String::new(),
                file_mtime: 0,
                file_size: 0,
                call_extract_version: CALL_EXTRACT_VERSION,
            },
        ];

        let (chunks, bodies) = chunks_needing_embed(&documents, &store, false);
        assert_eq!(chunks.len(), 1);
        assert_eq!(chunks[0].id, "b");
        assert!(bodies.contains_key("b"));
        assert!(!bodies.contains_key("a"));

        let (all_chunks, _) = chunks_needing_embed(&documents, &store, true);
        assert_eq!(all_chunks.len(), 2);
    }

    #[test]
    fn top_memory_hits_filters_and_ranks() {
        let mut store = EmbeddingStore::default();
        store.vectors.insert("memory:1".to_string(), vec![1.0, 0.0]);
        store.vectors.insert("memory:2".to_string(), vec![0.0, 1.0]);
        store
            .vectors
            .insert("src/foo.erl:foo:bar/0".to_string(), vec![1.0, 1.0]);
        let query = vec![1.0, 0.0];
        let hits = top_memory_hits(&store, &query, 10);
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].0, 1);
        assert!(hits[0].1 > 0.99);
        assert_eq!(hits[1].0, 2);
        assert!(hits[1].1 < 0.01);
    }

    #[test]
    fn trace_limits_are_clamped() {
        assert_eq!(clamp_trace_limits(0, 0), (1, 1));
        assert_eq!(clamp_trace_limits(usize::MAX, usize::MAX), (8, 500));
        assert_eq!(clamp_trace_limits(3, 42), (3, 42));
    }

    #[test]
    fn local_calls_get_current_module() {
        let source = r#"
-module(demo).
-export([a/0, b/0]).
a() -> b().
b() -> ok.
"#;
        let parsed = parse_erlang(source).expect("parse");
        let module = parsed.module.clone();
        let calls = attach_call_sources(module.clone(), parsed.calls, &parsed.functions);
        let local = calls
            .iter()
            .find(|c| c.to_function == "b")
            .expect("local call to b");
        assert_eq!(local.to_module.as_deref(), Some("demo"));
        assert_eq!(local.from_function.as_deref(), Some("a"));
    }

    #[test]
    fn apply_line_enriched_to_mfa() {
        let mut call = RawCall {
            to_module: None,
            to_function: "apply".to_string(),
            arity: 3,
            line: 1,
        };
        enrich_otp_call_patterns(&mut call, "    apply(lists, reverse, [[1,2]]),");
        assert_eq!(call.to_module.as_deref(), Some("lists"));
        assert_eq!(call.to_function, "reverse");
        assert_eq!(call.arity, 1);
    }

    #[test]
    fn fun_ref_extracted_from_source() {
        let refs = extract_fun_refs_from_source("    F = fun handle_call/3,\n");
        assert_eq!(refs.len(), 1);
        assert_eq!(refs[0].to_function, "handle_call");
        assert_eq!(refs[0].arity, 3);
    }

    #[test]
    fn call_graph_traversal() {
        let mk_call = |from_mod: Option<&str>, from_fn: &str, to_mod: Option<&str>, to_fn: &str, arity: usize| {
            CallEdge {
                from_module: from_mod.map(str::to_string),
                from_function: Some(from_fn.to_string()),
                from_arity: arity,
                to_module: to_mod.map(str::to_string),
                to_function: to_fn.to_string(),
                arity,
                line: 1,
            }
        };
        let docs = vec![
            CodeDocument {
                file: "a.erl".into(), module: Some("a".into()), body: String::new(),
                functions: vec![], exports: vec![], specs: vec![], callbacks: vec![],
                records: vec![], macros: vec![],
                chunks: vec![], behaviours: vec![], test_cases: vec![], tech_debt: vec![], data_sources: Some(vec![]), file_hash: String::new(), file_mtime: 0, file_size: 0, call_extract_version: CALL_EXTRACT_VERSION,
                calls: vec![mk_call(Some("a"), "start", Some("b"), "run", 0)],
            },
            CodeDocument {
                file: "b.erl".into(), module: Some("b".into()), body: String::new(),
                functions: vec![], exports: vec![], specs: vec![], callbacks: vec![],
                records: vec![], macros: vec![],
                chunks: vec![], behaviours: vec![], test_cases: vec![], tech_debt: vec![], data_sources: Some(vec![]), file_hash: String::new(), file_mtime: 0, file_size: 0, call_extract_version: CALL_EXTRACT_VERSION,
                calls: vec![mk_call(Some("b"), "run", Some("a"), "cycle", 0)],
            },
            CodeDocument {
                file: "c.erl".into(), module: Some("c".into()), body: String::new(),
                functions: vec![], exports: vec![], specs: vec![], callbacks: vec![],
                records: vec![], macros: vec![],
                chunks: vec![], behaviours: vec![], test_cases: vec![], tech_debt: vec![], data_sources: Some(vec![]), file_hash: String::new(), file_mtime: 0, file_size: 0, call_extract_version: CALL_EXTRACT_VERSION,
                calls: vec![mk_call(Some("c"), "orphan", None, "nonexistent", 0)],
            },
        ];
        let idx = CallGraphIndex::from_documents(&docs);

        let callers = idx.callers(Some("b"), "run", 0);
        assert!(callers.iter().any(|e| e.from_module.as_deref() == Some("a")
            && e.from_function.as_deref() == Some("start")),
            "callers of b:run/0 should include a:start/0, got {:?}", callers);

        let callees = idx.callees(Some("a"), "start", 0);
        assert!(callees.iter().any(|e| e.to_module.as_deref() == Some("b")
            && e.to_function == "run"),
            "callees of a:start/0 should include b:run/0, got {:?}", callees);

        let b_callees = idx.callees(Some("b"), "run", 0);
        assert!(b_callees.iter().any(|e| e.to_module.as_deref() == Some("a")
            && e.to_function == "cycle"),
            "b:run/0 should call a:cycle/0 (cycle), got {:?}", b_callees);

        let orphan_callers = idx.callers(Some("c"), "orphan", 0);
        assert!(orphan_callers.is_empty(),
            "orphan c:orphan/0 should have no callers, got {:?}", orphan_callers);

        let all = idx.all_edges();
        assert_eq!(all.len(), 3, "should have 3 edges, got {}", all.len());
    }

    #[test]
    fn indexes_hrl_records_and_macros() {
        let dir = std::env::temp_dir().join(format!("ali_hrl_{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        std::fs::write(
            dir.join("types.hrl"),
            "-record(state, {value}).\n-define(DEFAULT, 1).\n",
        )
        .expect("write hrl");

        let (docs, stats) = incremental_documents(&dir, Vec::new()).expect("index hrl");
        assert_eq!(docs.len(), 1);
        assert_eq!(stats.updated, 1);
        assert_eq!(stats.by_extension.get("hrl").copied(), Some(1));
        assert_eq!(docs[0].records[0].name, "state");
        assert_eq!(docs[0].macros[0].name, "DEFAULT");
        assert!(docs[0].functions.is_empty());

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn remote_module_call_keeps_to_module() {
        let source = r#"
-module(town_db).
-export([reset/1]).
reset(Src) ->
    town_lib:broadcast(Src, Info),
    lists:reverse([1,2]),
    ok.
"#;
        let parsed = parse_erlang(source).expect("parse");
        let calls = attach_call_sources(parsed.module.clone(), parsed.calls, &parsed.functions);
        let broadcast = calls
            .iter()
            .find(|c| c.to_function == "broadcast")
            .expect("broadcast call");
        assert_eq!(broadcast.to_module.as_deref(), Some("town_lib"));
        assert_eq!(broadcast.arity, 2);
        assert_eq!(broadcast.from_function.as_deref(), Some("reset"));
        let reverse = calls
            .iter()
            .find(|c| c.to_function == "reverse")
            .expect("reverse call");
        assert_eq!(reverse.to_module.as_deref(), Some("lists"));
        // 不应再把 remote 内层 call 记成「当前模块的本地 broadcast」
        assert!(
            !calls.iter().any(|c| {
                c.to_function == "broadcast" && c.to_module.as_deref() == Some("town_db")
            }),
            "local false-positive broadcast edges: {:?}",
            calls
        );
    }

    #[test]
    fn indexes_configured_text_extensions() {
        let dir = std::env::temp_dir().join(format!("ali_ext_{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        std::fs::write(dir.join("app.cfg"), "[{core, #{enabled => true}}].\n").expect("write cfg");
        std::fs::write(dir.join("native.c"), "int main(void) { return 0; }\n").expect("write c");

        let prev = std::env::var("ALI_INDEX_EXTENSIONS").ok();
        let extensions = ignore::IndexExtensions::with_list("cfg,c");

        let (docs, stats) = incremental_documents_with(&dir, Vec::new(), &extensions).expect("index extensions");
        assert_eq!(docs.len(), 2);
        assert_eq!(stats.by_extension.get("cfg").copied(), Some(1));
        assert_eq!(stats.by_extension.get("c").copied(), Some(1));
        assert!(docs.iter().any(|doc| doc.file.ends_with("app.cfg")));
        assert!(docs.iter().any(|doc| doc.chunks.len() >= 1));

        let _ = prev;
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn memory_delete_result_treats_qdrant_success_as_ok() {
        assert_eq!(memory_delete_result(false, true), (true, None));
        assert_eq!(memory_delete_result(true, false), (true, None));
        assert_eq!(memory_delete_result(true, true), (true, None));
        assert_eq!(
            memory_delete_result(false, false),
            (false, Some("not_found".to_string()))
        );
    }

    #[test]
    fn parse_semaphore_limits_concurrency() {
        let sem = Arc::new(ParseSemaphore::new(2));
        let active = Arc::new(AtomicUsize::new(0));
        let peak = Arc::new(AtomicUsize::new(0));
        let barrier = Arc::new(std::sync::Barrier::new(6));
        let mut handles = Vec::new();
        for _ in 0..6 {
            let sem = Arc::clone(&sem);
            let active = Arc::clone(&active);
            let peak = Arc::clone(&peak);
            let barrier = Arc::clone(&barrier);
            handles.push(std::thread::spawn(move || {
                barrier.wait();
                let _permit = sem.acquire();
                let now = active.fetch_add(1, Ordering::SeqCst) + 1;
                peak.fetch_max(now, Ordering::SeqCst);
                std::thread::sleep(Duration::from_millis(20));
                active.fetch_sub(1, Ordering::SeqCst);
            }));
        }
        for handle in handles {
            handle.join().expect("thread join");
        }
        assert!(peak.load(Ordering::SeqCst) <= 2);
    }

    #[test]
    fn tracker_dedups_timed_out_paths() {
        let tracker = ParseProgressTracker::new();
        assert!(!tracker.was_timed_out("a.erl"));
        assert!(tracker.mark_timed_out("a.erl"));
        assert!(tracker.was_timed_out("a.erl"));
        assert!(!tracker.mark_timed_out("a.erl"));
        assert!(!tracker.was_timed_out("b.erl"));
    }

    #[test]
    fn tracker_persist_skip_matches_size_mtime() {
        let tracker = ParseProgressTracker::new();
        tracker.remember_persist_skip("big.erl", 100, 42);
        assert!(tracker.should_persist_skip("big.erl", 100, 42));
        assert!(!tracker.should_persist_skip("big.erl", 101, 42));
        assert!(!tracker.should_persist_skip("big.erl", 100, 43));
        tracker.clear_persist_skip("big.erl");
        assert!(!tracker.should_persist_skip("big.erl", 100, 42));
    }
}
