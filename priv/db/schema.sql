-- ali 本地嵌入式数据库 schema（PostgreSQL 兼容 SQL 子集，SQLite 执行）
-- 注意：会话 ID 运行时是文本（如 "server-default" / "web"），相关列必须用 TEXT。

CREATE TABLE IF NOT EXISTS memories (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT,
    kind TEXT NOT NULL,
    content TEXT NOT NULL,
    tags TEXT,
    metadata TEXT,
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_memories_session ON memories(session_id);
CREATE INDEX IF NOT EXISTS idx_memories_kind ON memories(kind);
CREATE INDEX IF NOT EXISTS idx_memories_created ON memories(created_at);

CREATE TABLE IF NOT EXISTS critique_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT,
    question TEXT NOT NULL,
    answer TEXT NOT NULL,
    verdict TEXT NOT NULL,
    score REAL NOT NULL,
    feedback TEXT,
    round INTEGER DEFAULT 1,
    outcome TEXT,
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_critique_session ON critique_logs(session_id);

CREATE TABLE IF NOT EXISTS simulation_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    scenario_type TEXT NOT NULL,
    input TEXT NOT NULL,
    output TEXT,
    status TEXT NOT NULL,
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_simulation_type ON simulation_runs(scenario_type);

CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    user TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS session_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    seq INTEGER NOT NULL,
    message TEXT NOT NULL,
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_session_messages_session ON session_messages(session_id, seq);

-- Session artifacts (summary / toolTrace / critiques / tokenUsage / plan)
CREATE TABLE IF NOT EXISTS session_artifacts (
    session_id TEXT PRIMARY KEY,
    summary TEXT,
    tool_trace TEXT,
    critiques TEXT,
    token_usage TEXT,
    plan TEXT,
    updated_at INTEGER NOT NULL
);

-- Durable pending approvals (ETS remains hot cache)
CREATE TABLE IF NOT EXISTS pending_approvals (
    id TEXT PRIMARY KEY,
    session_id TEXT,
    tool TEXT NOT NULL,
    args TEXT,
    status TEXT NOT NULL DEFAULT 'pending',
    diff TEXT,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_pending_status ON pending_approvals(status, expires_at);

-- 模块摘要：LLM 生成的模块级摘要，按需缓存。
-- alModuleSummary 模块首次请求时用 moduleSymbols + LLM 生成，存此表 + ETS。
-- alContextEngine 命中模块后注入摘要，让 LLM "先看摘要再钻代码"，提升大型项目精度。
CREATE TABLE IF NOT EXISTS module_summaries (
    module TEXT PRIMARY KEY,
    summary TEXT NOT NULL,
    functions TEXT,
    file TEXT,
    line_count INTEGER,
    updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_module_summaries_updated ON module_summaries(updated_at);

-- Hourly metrics / audit archives (alArchive); created at core init, not runtime DDL.
CREATE TABLE IF NOT EXISTS metric_snapshots (
    hour INTEGER PRIMARY KEY,
    ask_count INTEGER NOT NULL DEFAULT 0,
    ok_count INTEGER NOT NULL DEFAULT 0,
    error_count INTEGER NOT NULL DEFAULT 0,
    total_duration_ms INTEGER NOT NULL DEFAULT 0,
    avg_duration_ms INTEGER NOT NULL DEFAULT 0,
    total_tool_calls INTEGER NOT NULL DEFAULT 0,
    tools_json BLOB,
    archived_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS audit_archive (
    hour INTEGER PRIMARY KEY,
    count INTEGER NOT NULL DEFAULT 0,
    entries_json BLOB,
    archived_at INTEGER NOT NULL
);
