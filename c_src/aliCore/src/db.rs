//! 嵌入式 SQLite 访问层（rusqlite，bundled）。
//!
//! # 路径
//! - 库文件：`ALI_DB_PATH`，默认 `{ALI_ROOT}/.ali/db/ali.db`
//! - Schema：`ALI_DB_SCHEMA`，默认 `{ALI_ROOT}/priv/db/schema.sql`
//!
//! # 模式
//! - `read`：只允许 SELECT / WITH / PRAGMA 等只读语句
//! - `write`：允许写操作（由 Erlang 策略层控制是否开放）
//!
//! 连接用 `Mutex` 保护，Port 请求串行进入时足够；避免多线程同时写同一连接。

use std::path::PathBuf;
use std::sync::Mutex;

use anyhow::{Context, Result};
use rusqlite::{Connection, Row, ToSql};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// 进程内唯一的 SQLite 连接包装。
pub struct LocalDb {
    conn: Mutex<Connection>,
    path: PathBuf,
}

/// Port `/db/query` 请求体。
#[derive(Debug, Deserialize)]
pub struct DbQueryRequest {
    pub sql: String,
    /// 位置参数，按顺序绑定到 `?`
    #[serde(default)]
    pub params: Vec<Value>,
    /// `"read"` 或 `"write"`
    #[serde(default = "default_mode")]
    pub mode: String,
}

/// 默认 SQL 模式为只读 `read`。
fn default_mode() -> String {
    "read".to_string()
}

#[derive(Debug, Serialize)]
pub struct DbQueryResponse {
    pub backend: &'static str,
    pub engine: &'static str,
    pub rows: Vec<Value>,
    pub changes: i64,
    #[serde(default)]
    pub last_insert_rowid: i64,
}

#[derive(Debug, Serialize)]
pub struct DbStatusResponse {
    pub backend: &'static str,
    pub engine: &'static str,
    pub deployment: &'static str,
    pub path: String,
    pub enabled: bool,
}

impl LocalDb {
    /// 打开（或创建）数据库文件，并执行 schema.sql（若存在）。
    pub fn open() -> Result<Self> {
        let path = db_path();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut conn = Connection::open(&path).context("open sqlite db")?;
        // P2-8：busy_timeout 避免 WAL checkpoint / 外部只读连接持锁时立即 SQLITE_BUSY。
        conn.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;",
        )?;
        migrate(&mut conn)?;
        Ok(Self {
            conn: Mutex::new(conn),
            path,
        })
    }

    /// 返回库路径与启用状态，供 `/db/status` 与健康检查使用。
    pub fn status(&self) -> DbStatusResponse {
        DbStatusResponse {
            backend: "local",
            engine: "sqlite",
            deployment: "embedded",
            path: self.path.to_string_lossy().to_string(),
            enabled: true,
        }
    }

    /// 执行参数化 SQL；`mode=read` 时用 `Statement::readonly()` 校验只读，拒绝写语句。
    pub fn query(&self, req: &DbQueryRequest) -> Result<DbQueryResponse> {
        validate_mode(&req.mode)?;
        let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
        if req.mode == "read" {
            let mut stmt = conn.prepare(&req.sql)?;
            // 用 SQLite 编译期判定的只读标志兜底：`WITH ... INSERT`、多语句、被误判为
            // SELECT 的写语句等前缀匹配漏网之鱼在这里被拦截（M1）。
            if !stmt.readonly() {
                anyhow::bail!("read mode only allows read-only statements");
            }
            let column_count = stmt.column_count();
            let column_names = (0..column_count)
                .map(|idx| stmt.column_name(idx).unwrap_or("").to_string())
                .collect::<Vec<_>>();
            let sql_params = json_params(&req.params);
            let param_refs: Vec<&dyn ToSql> = sql_params.iter().map(|v| v as &dyn ToSql).collect();
            let rows = stmt
                .query_map(param_refs.as_slice(), |row| {
                    Ok(row_to_json(row, &column_names))
                })?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(DbQueryResponse {
                backend: "local",
                engine: "sqlite",
                rows,
                changes: 0,
                last_insert_rowid: 0,
            })
        } else {
            reject_ddl(&req.sql)?;
            let sql_params = json_params(&req.params);
            let param_refs: Vec<&dyn ToSql> = sql_params.iter().map(|v| v as &dyn ToSql).collect();
            let changes = conn.execute(&req.sql, param_refs.as_slice())?;
            let last_insert_rowid = conn.last_insert_rowid();
            Ok(DbQueryResponse {
                backend: "local",
                engine: "sqlite",
                rows: Vec::new(),
                changes: changes as i64,
                last_insert_rowid,
            })
        }
    }
}

/// 解析数据库文件路径（`ALI_DB_PATH` 或默认 `.ali/db/ali.db`）。
fn db_path() -> PathBuf {
    std::env::var("ALI_DB_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|_| resolve_project_path(".ali/db/ali.db"))
}

/// 解析 schema 文件路径（`ALI_DB_SCHEMA` 或默认 `priv/db/schema.sql`）。
fn schema_path() -> PathBuf {
    std::env::var("ALI_DB_SCHEMA")
        .map(PathBuf::from)
        .unwrap_or_else(|_| resolve_project_path("priv/db/schema.sql"))
}

/// 按当前工作目录或 `c_src/aliCore` 相对路径定位项目内文件。
fn resolve_project_path(relative: &str) -> PathBuf {
    let direct = PathBuf::from(relative);
    if direct.exists() {
        return direct;
    }
    let from_core = PathBuf::from("../..").join(relative);
    if from_core.exists() {
        return from_core;
    }
    direct
}

/// 执行 `schema.sql` 建表，并做增量列迁移（如 `critique_logs.round`）。
fn migrate(conn: &mut Connection) -> Result<()> {
    // 先自愈上次迁移中断（DROP 后未 RENAME）留下的孤儿表，再执行 schema，
    // 否则 schema.sql 的 `CREATE TABLE IF NOT EXISTS session_artifacts` 会重建空主表，
    // 把孤儿表里的数据永久困在 session_artifacts__text 里。
    recover_orphaned_session_artifacts(conn)?;
    let path = schema_path();
    let schema = std::fs::read_to_string(&path)
        .with_context(|| format!("read schema {}", path.display()))?;
    conn.execute_batch(&schema)?;
    add_column_if_missing(conn, "critique_logs", "round", "INTEGER DEFAULT 1")?;
    // 用户反馈回流（critic 阈值自校准）：accepted / regenerated / rejected
    add_column_if_missing(conn, "critique_logs", "outcome", "TEXT")?;
    // 历史库把 session_id 建成了 INTEGER PRIMARY KEY，而运行时会话 ID 是
    // "server-default" 这类文本，插入会触发 SQLITE_MISMATCH(20)。
    migrate_session_artifacts_to_text_pk(conn)?;
    Ok(())
}

/// 若上次 `migrate_session_artifacts_to_text_pk` 在 DROP→RENAME 之间中断，库中会留下
/// `session_artifacts__text` 而无主表。此时把孤儿表直接 rename 回主表恢复数据。
fn recover_orphaned_session_artifacts(conn: &Connection) -> Result<()> {
    if !table_exists(conn, "session_artifacts__text")? {
        return Ok(());
    }
    if !table_exists(conn, "session_artifacts")? {
        conn.execute_batch("ALTER TABLE session_artifacts__text RENAME TO session_artifacts;")?;
    }
    Ok(())
}

/// 判断表是否存在（`sqlite_master` 查询）。
fn table_exists(conn: &Connection, table: &str) -> Result<bool> {
    let mut stmt = conn.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1")?;
    Ok(stmt.exists([table])?)
}

/// 若 `session_artifacts.session_id` 仍是 INTEGER，重建为 TEXT PRIMARY KEY。
fn migrate_session_artifacts_to_text_pk(conn: &mut Connection) -> Result<()> {
    {
        let mut stmt = conn.prepare("PRAGMA table_info(session_artifacts)")?;
        let cols: Vec<(String, String)> = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(1)?, // name
                    row.get::<_, String>(2)?, // type
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        if cols.is_empty() {
            return Ok(());
        }
        let Some((_, ty)) = cols.iter().find(|(name, _)| name == "session_id") else {
            return Ok(());
        };
        if !ty.to_ascii_uppercase().contains("INT") {
            return Ok(());
        }
    }

    // R6：整段迁移放进事务，CREATE→INSERT→DROP→RENAME 任一失败都整体回滚，
    // 避免中途失败把主表 DROP 掉后数据丢失。
    let tx = conn.transaction()?;
    tx.execute_batch(
        "
        CREATE TABLE IF NOT EXISTS session_artifacts__text (
            session_id TEXT PRIMARY KEY,
            summary TEXT,
            tool_trace TEXT,
            critiques TEXT,
            token_usage TEXT,
            plan TEXT,
            updated_at INTEGER NOT NULL
        );
        INSERT OR IGNORE INTO session_artifacts__text
            (session_id, summary, tool_trace, critiques, token_usage, plan, updated_at)
        SELECT CAST(session_id AS TEXT), summary, tool_trace, critiques, token_usage, plan, updated_at
        FROM session_artifacts;
        DROP TABLE session_artifacts;
        ALTER TABLE session_artifacts__text RENAME TO session_artifacts;
        ",
    )?;
    tx.commit()?;
    Ok(())
}

/// 幂等添加列：列已存在时忽略 duplicate column 错误。
fn add_column_if_missing(conn: &Connection, table: &str, column: &str, decl: &str) -> Result<()> {
    let sql = format!("ALTER TABLE {table} ADD COLUMN {column} {decl}");
    match conn.execute(&sql, []) {
        Ok(_) => Ok(()),
        Err(err) => {
            let msg = err.to_string();
            if msg.contains("duplicate column") || msg.contains("already exists") {
                Ok(())
            } else {
                Err(anyhow::anyhow!(err))
            }
        }
    }
}

/// 校验 mode 白名单：仅允许 `read` / `write`，其余一律拒绝（M1）。
fn validate_mode(mode: &str) -> Result<()> {
    match mode {
        "read" | "write" => Ok(()),
        other => anyhow::bail!("unsupported mode: {other} (only read/write allowed)"),
    }
}

/// write 模式下禁止 DROP/ALTER/CREATE/VACUUM 等 DDL（read 模式已由 `Statement::readonly()` 兜底）。
///
/// R7：按空白/标点分词后逐词匹配关键字，而不是用 `contains("drop ")` 子串匹配，
/// 避免换行/制表/注释等绕过。
fn reject_ddl(sql: &str) -> Result<()> {
    let lower = sql.to_ascii_lowercase();
    for word in lower.split(|c: char| !(c.is_ascii_alphanumeric() || c == '_')) {
        match word {
            "drop" | "alter" | "truncate" | "attach" | "detach" | "create" | "vacuum"
            | "reindex" => anyhow::bail!("DDL not allowed"),
            _ => {}
        }
    }
    Ok(())
}

/// 将 JSON 参数数组转为 rusqlite 绑定值列表。
fn json_params(values: &[Value]) -> Vec<rusqlite::types::Value> {
    values.iter().map(json_to_sql).collect()
}

/// 单个 JSON 值映射为 SQLite 类型（Null/Bool/Number/String）。
fn json_to_sql(value: &Value) -> rusqlite::types::Value {
    match value {
        Value::Null => rusqlite::types::Value::Null,
        Value::Bool(v) => rusqlite::types::Value::Integer(if *v { 1 } else { 0 }),
        Value::Number(n) if n.is_i64() => rusqlite::types::Value::Integer(n.as_i64().unwrap_or(0)),
        Value::Number(n) if n.is_f64() => rusqlite::types::Value::Real(n.as_f64().unwrap_or(0.0)),
        Value::Number(n) => rusqlite::types::Value::Text(n.to_string()),
        Value::String(s) => rusqlite::types::Value::Text(s.clone()),
        other => rusqlite::types::Value::Text(other.to_string()),
    }
}

/// 将查询结果行转为 JSON 对象（列名 → 值）；BLOB 以 base64 编码。
fn row_to_json(row: &Row<'_>, columns: &[String]) -> Value {
    let mut map = serde_json::Map::new();
    for (idx, name) in columns.iter().enumerate() {
        let value = match row.get_ref(idx) {
            Ok(rusqlite::types::ValueRef::Null) => Value::Null,
            Ok(rusqlite::types::ValueRef::Integer(v)) => json!(v),
            Ok(rusqlite::types::ValueRef::Real(v)) => json!(v),
            Ok(rusqlite::types::ValueRef::Text(v)) => {
                Value::String(String::from_utf8_lossy(v).to_string())
            }
            Ok(rusqlite::types::ValueRef::Blob(v)) => {
                Value::String(base64_encode(v))
            }
            Err(_) => Value::Null,
        };
        map.insert(name.clone(), value);
    }
    Value::Object(map)
}

/// 简易 base64 编码（无外部依赖），用于 BLOB 字段序列化。
fn base64_encode(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = chunk.get(1).copied().unwrap_or(0) as u32;
        let b2 = chunk.get(2).copied().unwrap_or(0) as u32;
        let triple = (b0 << 16) | (b1 << 8) | b2;
        out.push(TABLE[((triple >> 18) & 63) as usize] as char);
        out.push(TABLE[((triple >> 12) & 63) as usize] as char);
        out.push(if chunk.len() > 1 {
            TABLE[((triple >> 6) & 63) as usize] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            TABLE[(triple & 63) as usize] as char
        } else {
            '='
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn open_temp_db() -> LocalDb {
        let dir = std::env::temp_dir().join(format!(
            "ali_db_test_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let db_file = dir.join("ali.db");
        let schema = resolve_project_path("priv/db/schema.sql");
        unsafe {
            std::env::set_var("ALI_DB_PATH", &db_file);
            std::env::set_var("ALI_DB_SCHEMA", &schema);
        }
        LocalDb::open().expect("db open")
    }

    #[test]
    fn opens_and_migrates_temp_db() {
        let db = open_temp_db();
        let resp = db
            .query(&DbQueryRequest {
                sql: "INSERT INTO memories (session_id, kind, content, tags, metadata, created_at) VALUES (?, ?, ?, ?, ?, ?)".into(),
                params: vec![
                    json!(1),
                    json!("note"),
                    json!("hello"),
                    json!("[]"),
                    json!("{}"),
                    json!(123),
                ],
                mode: "write".into(),
            })
            .expect("insert");
        assert_eq!(resp.changes, 1);
        assert!(resp.last_insert_rowid > 0);
    }

    #[test]
    fn insert_accepts_text_session_id_and_float_score() {
        let db = open_temp_db();
        let mem = db.query(&DbQueryRequest {
            sql: "INSERT INTO memories (session_id, kind, content, tags, metadata, created_at) VALUES (?, ?, ?, ?, ?, ?)".into(),
            params: vec![
                json!("server-default"),
                json!("agentTurn"),
                json!("{\"question\":\"hi\"}"),
                json!("[\"agent\",\"critique\"]"),
                json!("{\"source\":\"alAgent\"}"),
                json!(1753088444),
            ],
            mode: "write".into(),
        });
        assert!(mem.is_ok(), "memories insert failed: {:?}", mem.err());

        let critique = db.query(&DbQueryRequest {
            sql: "INSERT INTO critique_logs (session_id, question, answer, verdict, score, feedback, round, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)".into(),
            params: vec![
                json!("server-default"),
                json!("你好"),
                json!("hello answer"),
                json!("pass"),
                json!(0.85),
                json!("ok"),
                json!(1),
                json!(1753088444),
            ],
            mode: "write".into(),
        });
        assert!(critique.is_ok(), "critique insert failed: {:?}", critique.err());
    }

    #[test]
    fn session_artifacts_accepts_text_session_id() {
        let db = open_temp_db();
        let resp = db.query(&DbQueryRequest {
            sql: "INSERT OR REPLACE INTO session_artifacts \
                  (session_id, summary, tool_trace, critiques, token_usage, plan, updated_at) \
                  VALUES (?, ?, ?, ?, ?, ?, ?)"
                .into(),
            params: vec![
                json!("server-default"),
                json!("{}"),
                json!("[]"),
                json!("[]"),
                json!("{}"),
                json!("{}"),
                json!(1753088444),
            ],
            mode: "write".into(),
        });
        assert!(
            resp.is_ok(),
            "session_artifacts text session_id failed: {:?}",
            resp.err()
        );
    }

    #[test]
    fn migrates_legacy_integer_session_artifacts_pk() {
        let dir = std::env::temp_dir().join(format!(
            "ali_db_mig_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let db_file = dir.join("ali.db");
        {
            let conn = Connection::open(&db_file).unwrap();
            conn.execute_batch(
                "CREATE TABLE session_artifacts (
                    session_id INTEGER PRIMARY KEY,
                    summary TEXT,
                    tool_trace TEXT,
                    critiques TEXT,
                    token_usage TEXT,
                    plan TEXT,
                    updated_at INTEGER NOT NULL
                );",
            )
            .unwrap();
        }
        let schema = resolve_project_path("priv/db/schema.sql");
        unsafe {
            std::env::set_var("ALI_DB_PATH", &db_file);
            std::env::set_var("ALI_DB_SCHEMA", &schema);
        }
        let db = LocalDb::open().expect("migrate open");
        let resp = db
            .query(&DbQueryRequest {
                sql: "INSERT OR REPLACE INTO session_artifacts \
                      (session_id, summary, tool_trace, critiques, token_usage, plan, updated_at) \
                      VALUES (?, ?, ?, ?, ?, ?, ?)"
                    .into(),
                params: vec![
                    json!("server-default"),
                    json!("{}"),
                    json!("[]"),
                    json!("[]"),
                    json!("{}"),
                    json!("{}"),
                    json!(1),
                ],
                mode: "write".into(),
            })
            .expect("text session_id after migration");
        assert_eq!(resp.changes, 1);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn insert_rejects_or_accepts_charlist_array_params() {
        let db = open_temp_db();
        // Simulate old Erlang bug: charlist sent as JSON array of codepoints.
        let pattern: Vec<Value> = "%hi%".chars().map(|c| json!(c as u32)).collect();
        let like = db.query(&DbQueryRequest {
            sql: "SELECT id FROM memories WHERE content LIKE ? ESCAPE '\\' LIMIT ?".into(),
            params: vec![Value::Array(pattern), json!(8)],
            mode: "read".into(),
        });
        assert!(like.is_ok(), "like with array param failed: {:?}", like.err());
    }

    #[test]
    fn reject_ddl_blocks_newline_tab_and_create() {
        // 换行/制表绕过原来的 `contains("drop ")` 子串匹配。
        assert!(reject_ddl("drop\ntable memories").is_err());
        assert!(reject_ddl("ALTER\ttable memories").is_err());
        assert!(reject_ddl("CREATE TABLE x(a INTEGER)").is_err());
        assert!(reject_ddl("VACUUM").is_err());
        assert!(reject_ddl("-- drop table memories").is_err());
        assert!(reject_ddl("SELECT * FROM memories").is_ok());
        assert!(reject_ddl("INSERT INTO memories (content) VALUES (?)").is_ok());
    }

    #[test]
    fn recovers_orphaned_session_artifacts_text_table() {
        let dir = std::env::temp_dir().join(format!(
            "ali_db_orphan_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let db_file = dir.join("ali.db");
        {
            // 模拟上次迁移在 DROP 主表后、RENAME 前中断：只剩 __text 孤儿表。
            let conn = Connection::open(&db_file).unwrap();
            conn.execute_batch(
                "CREATE TABLE session_artifacts__text (
                    session_id TEXT PRIMARY KEY,
                    summary TEXT,
                    tool_trace TEXT,
                    critiques TEXT,
                    token_usage TEXT,
                    plan TEXT,
                    updated_at INTEGER NOT NULL
                );
                INSERT INTO session_artifacts__text
                    (session_id, summary, tool_trace, critiques, token_usage, plan, updated_at)
                    VALUES ('s1', '{}', '[]', '[]', '{}', '{}', 1);",
            )
            .unwrap();
        }
        let schema = resolve_project_path("priv/db/schema.sql");
        unsafe {
            std::env::set_var("ALI_DB_PATH", &db_file);
            std::env::set_var("ALI_DB_SCHEMA", &schema);
        }
        let _db = LocalDb::open().expect("open should recover orphan table");
        let conn = Connection::open(&db_file).unwrap();
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM session_artifacts", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 1);
        let orphan: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'session_artifacts__text'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(orphan, 0);
        let _ = std::fs::remove_dir_all(dir);
    }
}
