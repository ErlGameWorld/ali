//! Erlang Port 协议层（多 inflight 并发）。
//!
//! # 帧格式（与 Erlang `{packet, 4}` 一致）
//! ```text
//! +------------+------------------+
//! | 4 字节长度 | JSON body (UTF-8)|
//! | big-endian |                  |
//! +------------+------------------+
//! ```
//!
//! # 请求 JSON
//! ```json
//! { "seq": 42, "method": "post", "path": "/search", "body": { "query": "gen_server" } }
//! ```
//!
//! # 响应 JSON
//! ```json
//! { "seq": 42, "ok": true, "data": { ... } }
//! // 或
//! { "seq": 42, "ok": false, "error": { "kind": "core_error", "message": "..." } }
//! ```
//!
//! 读循环在阻塞线程持续读 stdin；每个请求 `tokio::spawn` 并发执行，
//! 完成时持 stdout 锁写回（允许乱序完成，靠 `seq` 匹配）。

use anyhow::{Context, Result};
use futures::FutureExt;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

use super::{
    call_graph, cancel_index, data_source_callers, data_sources, db_query, db_status, embedding_schema,
    get_callees, get_callers, get_symbol, health, index_project, index_status, list_modules,
    memory_delete, memory_search, memory_upsert, module_deps, module_symbols, param_sources,
    search_code, search_unified, trace_data_flow_handler, AppState, DataSourceCallersRequest,
    DbQueryRequest, GraphQuery, IndexRequest, MemoryDeleteRequest, MemorySearchRequest,
    MemoryUpsertRequest, ModuleRequest, ModulesListRequest, ParamSourcesRequest, SearchRequest,
    SymbolRequest, TraceDataFlowRequest, UnifiedSearchRequest,
};

/// 单条 Port 请求：模仿 HTTP method + path，便于 Erlang 侧统一路由风格。
#[derive(Debug, Deserialize)]
pub struct PortRequest {
    /// 请求序号：Erlang 多 inflight 匹配用；缺省为 0。
    #[serde(default)]
    pub seq: u64,
    /// HTTP 风格方法，大小写不敏感：`get` / `post`
    pub method: String,
    /// 路由路径，如 `/health`、`/search`
    pub path: String,
    /// 可选 JSON body（GET 通常为 null）
    #[serde(default)]
    pub body: Option<Value>,
}

/// 统一响应信封：成功时带 `data`，失败时带 `error`；始终回传 `seq`。
#[derive(Debug, Serialize)]
pub struct PortResponse {
    pub seq: u64,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<PortError>,
}

/// 错误详情，供 Erlang 日志与上层降级判断。
#[derive(Debug, Serialize)]
pub struct PortError {
    pub kind: String,
    pub message: String,
}

/// 按路径类别的并发上限（可用环境变量覆盖）。
#[derive(Debug, Clone)]
struct ConcurrencyLimits {
    index: usize,
    search: usize,
    db: usize,
    memory_read: usize,
    memory_write: usize,
    graph: usize,
    other: usize,
    total: usize,
}

impl ConcurrencyLimits {
    fn from_env() -> Self {
        Self {
            index: env_usize("ALI_CORE_LIMIT_INDEX", 1),
            search: env_usize("ALI_CORE_LIMIT_SEARCH", 8),
            db: env_usize("ALI_CORE_LIMIT_DB", 4),
            memory_read: env_usize("ALI_CORE_LIMIT_MEMORY", 8),
            memory_write: env_usize("ALI_CORE_LIMIT_MEMORY_WRITE", 2),
            graph: env_usize("ALI_CORE_LIMIT_GRAPH", 4),
            other: env_usize("ALI_CORE_LIMIT_OTHER", 8),
            total: env_usize("ALI_CORE_LIMIT_TOTAL", 24),
        }
    }
}

fn env_usize(key: &str, default: usize) -> usize {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .filter(|n| *n > 0)
        .unwrap_or(default)
}

#[derive(Clone)]
struct PathSemaphores {
    index: Arc<Semaphore>,
    search: Arc<Semaphore>,
    db: Arc<Semaphore>,
    memory_read: Arc<Semaphore>,
    memory_write: Arc<Semaphore>,
    graph: Arc<Semaphore>,
    other: Arc<Semaphore>,
    total: Arc<Semaphore>,
}

impl PathSemaphores {
    fn new(limits: &ConcurrencyLimits) -> Self {
        Self {
            index: Arc::new(Semaphore::new(limits.index)),
            search: Arc::new(Semaphore::new(limits.search)),
            db: Arc::new(Semaphore::new(limits.db)),
            memory_read: Arc::new(Semaphore::new(limits.memory_read)),
            memory_write: Arc::new(Semaphore::new(limits.memory_write)),
            graph: Arc::new(Semaphore::new(limits.graph)),
            other: Arc::new(Semaphore::new(limits.other)),
            total: Arc::new(Semaphore::new(limits.total)),
        }
    }

    fn class_sem(&self, path: &str) -> Arc<Semaphore> {
        match path_class(path) {
            PathClass::Index => self.index.clone(),
            PathClass::Search => self.search.clone(),
            PathClass::Db => self.db.clone(),
            PathClass::MemoryRead => self.memory_read.clone(),
            PathClass::MemoryWrite => self.memory_write.clone(),
            PathClass::Graph => self.graph.clone(),
            PathClass::Other => self.other.clone(),
        }
    }
}

#[derive(Debug, Clone, Copy)]
enum PathClass {
    Index,
    Search,
    Db,
    MemoryRead,
    MemoryWrite,
    Graph,
    Other,
}

fn path_class(path: &str) -> PathClass {
    match path {
        "/index" => PathClass::Index,
        "/index/cancel" => PathClass::Other,
        "/search" | "/search/unified" => PathClass::Search,
        p if p.starts_with("/db/") => PathClass::Db,
        "/memory/search" => PathClass::MemoryRead,
        "/memory/upsert" | "/memory/delete" => PathClass::MemoryWrite,
        "/callers" | "/callees" | "/call_graph" | "/data_sources" | "/data_source_callers"
        | "/param_sources" | "/trace_data_flow" | "/module_deps" | "/module_symbols" | "/modules"
        | "/symbol" | "/embedding_schema" => PathClass::Graph,
        _ => PathClass::Other,
    }
}

/// 阻塞式主循环：读 stdin 帧并并发派发；写回带 `seq` 的响应。
///
/// 读失败（Erlang 关闭 Port）时等待在途任务结束后退出。
pub fn run_blocking(state: AppState, rt: &tokio::runtime::Runtime) -> Result<()> {
    let limits = ConcurrencyLimits::from_env();
    tracing::info!(
        index = limits.index,
        search = limits.search,
        db = limits.db,
        memory_read = limits.memory_read,
        memory_write = limits.memory_write,
        graph = limits.graph,
        other = limits.other,
        total = limits.total,
        "aliCore port concurrency limits"
    );
    let semaphores = Arc::new(PathSemaphores::new(&limits));
    let stdout = Arc::new(Mutex::new(std::io::stdout()));
    let inflight = Arc::new(AtomicUsize::new(0));

    let mut stdin = std::io::stdin().lock();
    loop {
        let mut len_buf = [0u8; 4];
        match stdin.read_exact(&mut len_buf) {
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
            Err(e) => return Err(anyhow::Error::new(e).context("failed to read port request length")),
        }
        let len = u32::from_be_bytes(len_buf);
        if len == 0 {
            break;
        }
        const MAX_PORT_PACKET: u32 = 64 * 1024 * 1024;
        if len > MAX_PORT_PACKET {
            if let Err(e) = discard_bytes(&mut stdin, len as u64) {
                return Err(anyhow::Error::new(e).context("failed to discard oversized port frame"));
            }
            let response = with_seq(
                port_err(anyhow::anyhow!(
                    "port packet too large: {} bytes (max {})",
                    len,
                    MAX_PORT_PACKET
                )),
                0,
            );
            let mut out = stdout
                .lock()
                .unwrap_or_else(|p| p.into_inner());
            write_response(&mut *out, &response)?;
            continue;
        }

        let mut buf = vec![0u8; len as usize];
        stdin
            .read_exact(&mut buf)
            .context("failed to read port request body")?;

        match serde_json::from_slice::<PortRequest>(&buf) {
            Ok(request) => {
                let seq = request.seq;
                let state2 = state.clone();
                let sems = semaphores.clone();
                let stdout2 = stdout.clone();
                let inflight2 = inflight.clone();
                inflight.fetch_add(1, Ordering::SeqCst);
                rt.spawn(async move {
                    let response = response_from_unwind(
                        std::panic::AssertUnwindSafe(run_one(state2, sems, request))
                            .catch_unwind()
                            .await,
                    );
                    let response = with_seq(response, seq);
                    if let Ok(mut out) = stdout2.lock() {
                        if let Err(err) = write_response(&mut *out, &response) {
                            tracing::warn!("failed to write port response: {err:#}");
                        }
                    }
                    inflight2.fetch_sub(1, Ordering::SeqCst);
                });
            }
            Err(err) => {
                let seq = peek_seq(&buf).unwrap_or(0);
                let response = with_seq(
                    port_err(anyhow::Error::new(err).context("failed to decode port request")),
                    seq,
                );
                let mut out = stdout
                    .lock()
                    .unwrap_or_else(|p| p.into_inner());
                write_response(&mut *out, &response)?;
            }
        }
    }

    // stdin EOF：等待在途请求写完，避免截断响应。
    let deadline = std::time::Instant::now() + Duration::from_secs(120);
    while inflight.load(Ordering::SeqCst) > 0 {
        if std::time::Instant::now() > deadline {
            tracing::warn!(
                remaining = inflight.load(Ordering::SeqCst),
                "timed out waiting for in-flight port requests on shutdown"
            );
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }

    Ok(())
}

async fn run_one(state: AppState, sems: Arc<PathSemaphores>, request: PortRequest) -> PortResponse {
    let path = request.path.clone();
    let _total: OwnedSemaphorePermit = match sems.total.clone().acquire_owned().await {
        Ok(p) => p,
        Err(_) => return port_err(anyhow::anyhow!("concurrency semaphore closed")),
    };
    let _class: OwnedSemaphorePermit = match sems.class_sem(&path).acquire_owned().await {
        Ok(p) => p,
        Err(_) => return port_err(anyhow::anyhow!("class semaphore closed")),
    };
    dispatch(&state, request).await
}

/// 尽力从损坏 JSON 里抠出 seq，便于 Erlang 把错误回给正确等待者。
fn peek_seq(buf: &[u8]) -> Option<u64> {
    #[derive(Deserialize)]
    struct SeqOnly {
        #[serde(default)]
        seq: u64,
    }
    serde_json::from_slice::<SeqOnly>(buf)
        .ok()
        .map(|s| s.seq)
        .filter(|s| *s > 0)
}

fn with_seq(mut response: PortResponse, seq: u64) -> PortResponse {
    response.seq = seq;
    response
}

/// 从 reader 读满并丢弃 `n` 字节（用于排空超大帧体，保持帧同步）。
fn discard_bytes<R: Read>(reader: &mut R, mut n: u64) -> std::io::Result<()> {
    let mut scratch = [0u8; 64 * 1024];
    while n > 0 {
        let want = std::cmp::min(n, scratch.len() as u64) as usize;
        reader.read_exact(&mut scratch[..want])?;
        n -= want as u64;
    }
    Ok(())
}

/// 将响应编码为帧写回 stdout。仅 IO 错误（父进程关闭）向上传播导致退出。
fn write_response<W: Write>(stdout: &mut W, response: &PortResponse) -> Result<()> {
    let body = serde_json::to_vec(response).context("failed to encode port response")?;
    let len_bytes = (body.len() as u32).to_be_bytes();
    stdout
        .write_all(&len_bytes)
        .context("failed to write port response length")?;
    stdout
        .write_all(&body)
        .context("failed to write port response body")?;
    stdout.flush().context("failed to flush port stdout")?;
    Ok(())
}

/// 将 method+path 分发到 `main.rs` 中的业务处理函数。
async fn dispatch(state: &AppState, req: PortRequest) -> PortResponse {
    let method = req.method.to_ascii_lowercase();
    let path = req.path.as_str();

    match (method.as_str(), path) {
        ("get", "/health") => ok_value(health(state).await).await,
        ("get", "/index/status") => ok_value(index_status(state).await).await,
        ("post", "/index/cancel") => ok_value(cancel_index(state).await).await,
        ("get", "/call_graph") => result_value(call_graph(state).await).await,
        ("get", "/data_sources") => result_value(data_sources(state).await).await,
        ("get", "/embedding_schema") => result_value(embedding_schema(state).await).await,
        ("get", "/db/status") => ok_value(db_status(state).await).await,
        ("post", "/index") => match parse_body::<IndexRequest>(req.body) {
            Ok(body) => result_value(index_project(state, body).await).await,
            Err(err) => port_err(err),
        },
        ("post", "/search") => match parse_body::<SearchRequest>(req.body) {
            Ok(body) => result_value(search_code(state, body).await).await,
            Err(err) => port_err(err),
        },
        ("post", "/search/unified") => match parse_body::<UnifiedSearchRequest>(req.body) {
            Ok(body) => result_value(search_unified(state, body).await).await,
            Err(err) => port_err(err),
        },
        ("post", "/symbol") => match parse_body::<SymbolRequest>(req.body) {
            Ok(body) => result_value(get_symbol(state, body).await).await,
            Err(err) => port_err(err),
        },
        ("post", "/module_symbols") => match parse_body::<ModuleRequest>(req.body) {
            Ok(body) => result_value(module_symbols(state, body).await).await,
            Err(err) => port_err(err),
        },
        ("get", "/modules") => {
            result_value(list_modules(state, ModulesListRequest {
                q: None,
                limit: 200,
                offset: 0,
            }).await).await
        }
        ("post", "/modules") => match parse_body::<ModulesListRequest>(req.body) {
            Ok(body) => result_value(list_modules(state, body).await).await,
            Err(err) => port_err(err),
        },
        ("post", "/module_deps") => match parse_body::<ModuleRequest>(req.body) {
            Ok(body) => result_value(module_deps(state, body).await).await,
            Err(err) => port_err(err),
        },
        ("post", "/callers") => match parse_body::<GraphQuery>(req.body) {
            Ok(body) => result_value(get_callers(state, body).await).await,
            Err(err) => port_err(err),
        },
        ("post", "/callees") => match parse_body::<GraphQuery>(req.body) {
            Ok(body) => result_value(get_callees(state, body).await).await,
            Err(err) => port_err(err),
        },
        ("post", "/data_source_callers") => match parse_body::<DataSourceCallersRequest>(req.body) {
            Ok(body) => result_value(data_source_callers(state, body).await).await,
            Err(err) => port_err(err),
        },
        ("post", "/param_sources") => match parse_body::<ParamSourcesRequest>(req.body) {
            Ok(body) => result_value(param_sources(state, body).await).await,
            Err(err) => port_err(err),
        },
        ("post", "/trace_data_flow") => match parse_body::<TraceDataFlowRequest>(req.body) {
            Ok(body) => result_value(trace_data_flow_handler(state, body).await).await,
            Err(err) => port_err(err),
        },
        ("post", "/db/query") => match parse_body::<DbQueryRequest>(req.body) {
            Ok(body) => result_value(db_query(state, body).await).await,
            Err(err) => port_err(err),
        },
        ("post", "/memory/upsert") => match parse_body::<MemoryUpsertRequest>(req.body) {
            Ok(body) => ok_value(memory_upsert(state, body).await).await,
            Err(err) => port_err(err),
        },
        ("post", "/memory/search") => match parse_body::<MemorySearchRequest>(req.body) {
            Ok(body) => result_value(memory_search(state, body).await).await,
            Err(err) => port_err(err),
        },
        ("post", "/memory/delete") => match parse_body::<MemoryDeleteRequest>(req.body) {
            Ok(body) => ok_value(memory_delete(state, body).await).await,
            Err(err) => port_err(err),
        },
        _ => port_err(anyhow::anyhow!("unknown port request: {} {}", method, path)),
    }
}

/// 将 Port 请求中的 JSON body 反序列化为具体类型；缺失时按 `null` 处理。
fn parse_body<T: for<'de> Deserialize<'de>>(body: Option<Value>) -> Result<T> {
    let value = body.unwrap_or(Value::Null);
    serde_json::from_value(value).context("invalid request body")
}

/// 将成功结果序列化为 `{ ok: true, data: ... }`。
async fn ok_value<T: Serialize>(value: T) -> PortResponse {
    match serde_json::to_value(value) {
        Ok(data) => PortResponse {
            seq: 0,
            ok: true,
            data: Some(data),
            error: None,
        },
        Err(err) => port_err(err),
    }
}

/// 将 `Result` 转为 Port 响应：成功走 `ok_value`，失败走 `port_err`。
async fn result_value<T: Serialize>(result: Result<T>) -> PortResponse {
    match result {
        Ok(value) => ok_value(value).await,
        Err(err) => port_err(err),
    }
}

/// 构造 `{ ok: false, error: { kind: "core_error", message } }` 错误响应。
fn port_err(err: impl Into<anyhow::Error>) -> PortResponse {
    PortResponse {
        seq: 0,
        ok: false,
        data: None,
        error: Some(PortError {
            kind: "core_error".to_string(),
            // 用 `{:#}` 输出完整错误链（含底层 source），而非只保留最外层 context（M12）。
            message: format!("{:#}", err.into()),
        }),
    }
}

/// 构造 panic 恢复错误响应，kind 固定为 `core_panic`（区别于常规 `core_error`）。
fn port_panic() -> PortResponse {
    PortResponse {
        seq: 0,
        ok: false,
        data: None,
        error: Some(PortError {
            kind: "core_panic".to_string(),
            message: "core panicked while handling port request".to_string(),
        }),
    }
}

/// 将 `catch_unwind` 的结果映射为 Port 响应：panic 转 `core_panic` 错误，确保该 seq 仍写回。
fn response_from_unwind(result: std::thread::Result<PortResponse>) -> PortResponse {
    match result {
        Ok(response) => response,
        Err(_) => port_panic(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn panic_maps_to_core_panic_response() {
        let ok = response_from_unwind(Ok(PortResponse {
            seq: 7,
            ok: true,
            data: None,
            error: None,
        }));
        assert!(ok.ok);
        assert_eq!(ok.seq, 7);

        let err = response_from_unwind(Err(Box::new("boom") as Box<dyn std::any::Any + Send>));
        assert!(!err.ok);
        let error = err.error.expect("panic error present");
        assert_eq!(error.kind, "core_panic");
    }
}
