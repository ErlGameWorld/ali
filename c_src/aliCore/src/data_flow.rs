//! 数据流分析：数据源调用点索引 + 过程内 use-def chain + 跨过程数据流追踪。
//!
//! ## 背景
//! 大型项目里"查服务器内某数据"通常需要一串函数调用链：
//! `入口 → 转换 → 业务 → 数据访问(ets/mnesia/sql)`。
//! 单纯的调用图 1-hop 扩展接不上多跳链路，且无法识别"数据从哪儿来"。
//!
//! ## 能力分层
//! - [`DataSourceCall`] / [`DataSourceIndex`]：静态扫描 `ets:lookup/mnesia:select/sql`
//!   等数据源调用点，建表名→caller MFA 反向索引。回答"哪些函数读 role_tab 表"。
//! - [`ParamSource`] / [`analyze_param_sources`]：过程内 use-def chain，回答
//!   "目标函数的第 i 个参数由谁产生"。
//! - [`DataFlowTrace`] / [`trace_data_flow`]：跨过程递归追溯参数依赖 DAG，
//!   回答"调用 targetFun 之前需要先调哪些转换函数"。
//!
//! ## 设计取舍
//! - 不依赖命名规范（`get*/query*` 等），纯靠数据流静态分析。
//! - 推不出时返回 `Unknown`，由上层 LLM 主动反问用户给提示。

use std::collections::HashMap;

use anyhow::Result;
use serde::{Deserialize, Serialize};

/// 数据源类型：标识一处 ets/mnesia/sql 等数据读取调用点。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DataSourceKind {
    /// `ets:lookup/lookup_element/match/match_object/select`
    Ets,
    /// `mnesia:read/select/match_object`
    Mnesia,
    /// `pg:squery/equery` / `mysql:query` / `epgsql:equery`
    Sql,
    /// `disk_log:chunk`
    DiskLog,
}

/// 一处数据源调用点（如某函数体内 `ets:lookup(role_tab, Key)`）。
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct DataSourceCall {
    /// 调用方模块（解析失败为 None）
    pub caller_module: Option<String>,
    /// 调用方函数名
    pub caller_function: String,
    /// 调用方元数
    pub caller_arity: usize,
    /// 数据源类型
    pub source_type: DataSourceKind,
    /// 表名（ets 表 atom / mnesia 表名 / SQL 表名）；不可静态确定时为空串
    pub table: String,
    /// 调用所在行号（1-based）
    pub line: usize,
    /// 返回值赋给的变量名（如 `Role = ets:lookup(...)` 中的 `Role`）；不可确定时为空串
    pub return_var: String,
}

/// 数据源索引：支持按表名反查。
#[derive(Debug, Default, Clone)]
pub struct DataSourceIndex {
    pub entries: Vec<DataSourceCall>,
    /// 表名 → entries 索引（小写归一化，便于 case-insensitive 查询）
    by_table: HashMap<String, Vec<usize>>,
}

impl DataSourceIndex {
    /// 从所有文档构建数据源索引。
    ///
    /// **禁止**在此路径调用 `effective_body`：索引重建时 documents 的 body 多为空
    ///（mtime 命中缓存），再读盘等于把整仓扫第二遍——没开 embedding 时大仓「假慢」的主因。
    /// 调用点应来自解析阶段写入的 `doc.data_sources`，或内存中仍有的 `doc.body`。
    pub fn from_documents(documents: &[crate::CodeDocument]) -> Self {
        let mut idx = Self::default();
        for doc in documents {
            match &doc.data_sources {
                Some(calls) => {
                    for call in calls {
                        idx.push(call.clone());
                    }
                }
                None if !doc.body.is_empty() => {
                    let module = doc.module.as_deref();
                    for call in extract_data_source_calls(&doc.body, module, &doc.functions) {
                        idx.push(call);
                    }
                }
                None => {
                    // 旧缓存 + body 已 slim：跳过读盘。该文件会在下次内容变更
                    // （或 mtime 未命中强制重读）时补齐 data_sources。
                }
            }
        }
        idx
    }

    fn push(&mut self, call: DataSourceCall) {
        let i = self.entries.len();
        if !call.table.is_empty() {
            self.by_table
                .entry(call.table.to_ascii_lowercase())
                .or_default()
                .push(i);
        }
        self.entries.push(call);
    }

    /// 按表名查：哪些函数读这个表？返回 entries 克隆。
    pub fn callers_of_table(&self, table: &str) -> Vec<DataSourceCall> {
        self.by_table
            .get(&table.to_ascii_lowercase())
            .map(|idxs| idxs.iter().filter_map(|&i| self.entries.get(i).cloned()).collect())
            .unwrap_or_default()
    }

    /// 全量数据源调用点（用于 `/data_sources` 端点导出）。
    pub fn all(&self) -> &[DataSourceCall] {
        &self.entries
    }
}

/// `module:function/arity` 规范化 key（与 main.rs::node_key 对齐）。
fn mfa_key(module: Option<&str>, function: &str, arity: usize) -> String {
    match module {
        Some(m) if !m.is_empty() => format!("{m}:{function}/{arity}"),
        _ => format!("{function}/{arity}"),
    }
}

/// 已识别的数据源函数白名单：`(module, function_prefix)` → kind。
/// prefix 匹配可覆盖 `lookup` / `lookup_element` 等同族函数。
const DATA_SOURCE_PATTERNS: &[(&str, &str, DataSourceKind)] = &[
    ("ets", "lookup", DataSourceKind::Ets),
    ("ets", "match", DataSourceKind::Ets),
    ("ets", "select", DataSourceKind::Ets),
    ("ets", "foldl", DataSourceKind::Ets),
    ("ets", "foldr", DataSourceKind::Ets),
    ("ets", "next", DataSourceKind::Ets),
    ("ets", "prev", DataSourceKind::Ets),
    ("ets", "first", DataSourceKind::Ets),
    ("ets", "last", DataSourceKind::Ets),
    ("ets", "info", DataSourceKind::Ets),
    ("mnesia", "read", DataSourceKind::Mnesia),
    ("mnesia", "select", DataSourceKind::Mnesia),
    ("mnesia", "match_object", DataSourceKind::Mnesia),
    ("mnesia", "wread", DataSourceKind::Mnesia),
    ("mnesia", "index_read", DataSourceKind::Mnesia),
    ("mnesia", "index_match_object", DataSourceKind::Mnesia),
    ("mnesia", "foldl", DataSourceKind::Mnesia),
    ("mnesia", "foldr", DataSourceKind::Mnesia),
    ("mnesia", "dirty_read", DataSourceKind::Mnesia),
    ("mnesia", "dirty_select", DataSourceKind::Mnesia),
    ("mnesia", "dirty_match_object", DataSourceKind::Mnesia),
    ("mnesia", "dirty_index_read", DataSourceKind::Mnesia),
    ("mnesia", "dirty_index_match_object", DataSourceKind::Mnesia),
    ("pg", "squery", DataSourceKind::Sql),
    ("pg", "equery", DataSourceKind::Sql),
    ("epgsql", "equery", DataSourceKind::Sql),
    ("epgsql", "squery", DataSourceKind::Sql),
    ("mysql", "query", DataSourceKind::Sql),
    ("mysql", "execute", DataSourceKind::Sql),
    ("disk_log", "chunk", DataSourceKind::DiskLog),
    ("disk_log", "info", DataSourceKind::DiskLog),
];

/// 判定一个 `module:function` 是否为数据源调用，返回类型。
fn classify_data_source(module: &str, function: &str) -> Option<DataSourceKind> {
    DATA_SOURCE_PATTERNS
        .iter()
        .find(|(m, f, _)| *m == module && function.starts_with(f))
        .map(|(_, _, kind)| *kind)
}

/// 从源码提取数据源调用点。
///
/// 实现策略：基于行级文本扫描 + 正则匹配，不依赖 tree-sitter grammar 版本。
///
/// 步骤：
/// 1. 按行扫描源码，用正则匹配 `M:F(...)` 形式的远程调用
/// 2. 过滤出 module 为 ets/mnesia/sql 等 + function 命中白名单的调用
/// 3. 提取第一个参数作为表名（仅当它是 atom 字面量或 `?MACRO` 时）
/// 4. 检查同一行前缀是否有 `Var = ` 形式，提取返回变量名
/// 5. 用 `functions` 的行号范围把调用点关联到 caller MFA
pub fn extract_data_source_calls(
    body: &str,
    module: Option<&str>,
    functions: &[crate::FunctionSymbol],
) -> Vec<DataSourceCall> {
    let mut out = Vec::new();
    for (idx, raw_line) in body.lines().enumerate() {
        let line_no = idx + 1;
        let trimmed = raw_line.trim();
        // 快速过滤：只处理含 `:` 且看起来像远程调用的行
        if trimmed.is_empty() || !trimmed.contains(':') {
            continue;
        }
        // 跳过注释行
        if trimmed.starts_with('%') {
            continue;
        }
        // 正则匹配 `Module:Function(` 形式
        let Some(call) = parse_remote_call_line(trimmed) else {
            continue;
        };
        let Some(kind) = classify_data_source(&call.module, &call.function) else {
            continue;
        };
        let table = extract_table_name_from_args(&call.args);
        let return_var = extract_return_var_from_line(trimmed);

        // 用行号关联 caller MFA
        let (caller_function, caller_arity) = match find_containing_function(functions, line_no) {
            Some(f) => (f.name.clone(), f.arity),
            None => (String::new(), 0),
        };

        out.push(DataSourceCall {
            caller_module: module.map(|s| s.to_string()),
            caller_function,
            caller_arity,
            source_type: kind,
            table,
            line: line_no,
            return_var,
        });
    }
    out
}

/// 解析单行中的第一个 `Module:Function(Args)` 调用。
struct ParsedRemoteCall {
    module: String,
    function: String,
    args: String,
}

fn parse_remote_call_line(line: &str) -> Option<ParsedRemoteCall> {
    // 简化匹配：找 `atom:atom(` 模式
    // atom 可含字母数字下划线 @
    let bytes = line.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        // 找潜在 module 起点：字母开头
        if !bytes[i].is_ascii_alphabetic() && bytes[i] != b'_' {
            i += 1;
            continue;
        }
        // 读 module atom（字母数字下划线 @）
        let start = i;
        while i < bytes.len()
            && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'_' || bytes[i] == b'@')
        {
            i += 1;
        }
        let module = &line[start..i];
        // 必须紧跟 ':'
        if i >= bytes.len() || bytes[i] != b':' {
            continue;
        }
        i += 1;
        // 读 function atom
        let fun_start = i;
        while i < bytes.len()
            && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'_' || bytes[i] == b'@')
        {
            i += 1;
        }
        let function = &line[fun_start..i];
        if function.is_empty() {
            continue;
        }
        // 必须紧跟 '('
        if i >= bytes.len() || bytes[i] != b'(' {
            continue;
        }
        // 找匹配的右括号
        let args_start = i + 1;
        let mut depth = 1;
        i += 1;
        while i < bytes.len() && depth > 0 {
            match bytes[i] {
                b'(' => depth += 1,
                b')' => depth -= 1,
                _ => {}
            }
            i += 1;
        }
        if depth != 0 {
            continue;
        }
        let args = &line[args_start..i - 1];
        return Some(ParsedRemoteCall {
            module: module.to_string(),
            function: function.to_string(),
            args: args.to_string(),
        });
    }
    None
}

/// 从参数字符串提取第一个参数作为表名。
/// 仅当第一个参数是 atom 字面量（如 `role_tab`）或宏（`?ROLE_TAB`）时返回；
/// 动态表名（变量/函数调用）返回空串。
fn extract_table_name_from_args(args: &str) -> String {
    let trimmed = args.trim_start();
    // 宏形式：?NAME
    if let Some(rest) = trimmed.strip_prefix('?') {
        let end = rest
            .find(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
            .unwrap_or(rest.len());
        if end > 0 {
            return format!("?{}", &rest[..end]);
        }
    }
    // atom 字面量：小写字母开头，后跟字母数字下划线 @
    let bytes = trimmed.as_bytes();
    if bytes.is_empty() || !bytes[0].is_ascii_lowercase() {
        return String::new();
    }
    let end = trimmed
        .find(|c: char| !(c.is_ascii_alphanumeric() || c == '_' || c == '@'))
        .unwrap_or(trimmed.len());
    // 必须紧跟逗号或空白+逗号或行尾，确保是第一个参数
    let after = trimmed[end..].trim_start();
    if after.is_empty() || after.starts_with(',') {
        return trimmed[..end].to_string();
    }
    String::new()
}

/// 从单行提取返回变量名：检查 `Var = ...` 形式的前缀。
fn extract_return_var_from_line(line: &str) -> String {
    let trimmed = line.trim_start();
    let bytes = trimmed.as_bytes();
    if bytes.is_empty() || !bytes[0].is_ascii_uppercase() && bytes[0] != b'_' {
        return String::new();
    }
    // 读 var 名（大写字母开头，字母数字下划线）
    let mut i = 0;
    while i < bytes.len() && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'_') {
        i += 1;
    }
    if i == 0 {
        return String::new();
    }
    let var = &trimmed[..i];
    // 必须紧跟 ` = `（注意 Erlang 的 = 操作符前后可能有空格）
    let rest = trimmed[i..].trim_start();
    if rest.starts_with('=') && !rest.starts_with("==") {
        let after_eq = &rest[1..];
        if after_eq.is_empty() || after_eq.starts_with(' ') || after_eq.starts_with('\t') {
            return var.to_string();
        }
    }
    String::new()
}

/// 用行号二分查找所属函数（与 attach_call_sources 一致）。
fn find_containing_function<'a>(
    functions: &'a [crate::FunctionSymbol],
    line: usize,
) -> Option<&'a crate::FunctionSymbol> {
    functions.iter().find(|f| line >= f.start_line && line <= f.end_line)
}

// ============================================================================
// P0-2: use-def chain（过程内数据流分析）
// ============================================================================

/// 参数/局部变量的来源分类。
#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ParamSource {
    /// 字面量/常量
    Literal { value: String, line: usize },
    /// 来自函数调用 `Var = producer(...)`，记录 producer MFA
    Call {
        module: Option<String>,
        function: String,
        arity: usize,
        line: usize,
    },
    /// 字段提取 `Var = maps:get(field, Map)` 或 `{ok, Var} = ...`
    FieldExtract { line: usize, source_text: String },
    /// 来自另一个变量 `Var = OtherVar`（罕见，多为模式匹配别名）
    VarChain { from_var: String, line: usize },
    /// 来自函数入参（caller 传入）
    Param { index: usize },
    /// 未知/无法静态确定（动态构造、复杂模式匹配等）
    Unknown,
}

/// 过程内 use-def chain 分析结果。
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ParamSourceResult {
    /// 目标函数 MFA key `module:function/arity`
    pub mfa: String,
    /// 函数入参的来源（通常为 Param{i}，因为入参就是参数本身）
    pub params: Vec<ParamSource>,
    /// 关键局部变量（被传给其他函数调用的变量）的来源链
    pub locals: Vec<NamedParamSource>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct NamedParamSource {
    pub var: String,
    pub source: ParamSource,
}

/// 对单个函数做过程内 use-def chain 分析。
///
/// 实现策略：基于行级文本扫描，不依赖 tree-sitter grammar 版本。
///
/// 步骤：
/// 1. 用行号范围定位函数体（start_line..end_line）
/// 2. 从函数头 `name(Args) ->` 提取参数名列表
/// 3. 扫描函数体内所有 `Var = Expr` 形式的赋值
/// 4. 对 Expr 分类：字面量 / 函数调用 / 字段提取 / 变量链 / 未知
///
/// 局限：
/// - 不处理多 clause 函数头模式匹配的参数解构（如 `foo({A, B}) -> ...`）
/// - 不处理 case/if 表达式内部的 match
/// - 不处理跨行表达式
/// - 这些复杂场景返回 Unknown，由上层 LLM 兜底
pub fn analyze_param_sources(
    body: &str,
    module: Option<&str>,
    function: &crate::FunctionSymbol,
) -> Result<ParamSourceResult> {
    let lines: Vec<&str> = body.lines().collect();
    // 定位函数头行（start_line 是 1-based，转为 0-based 索引）
    let head_idx = function.start_line.checked_sub(1).filter(|&i| i < lines.len());
    let param_names = match head_idx {
        Some(i) => extract_param_names_from_head(lines[i]),
        None => Vec::new(),
    };

    // 扫描函数体内所有 `Var = Expr` 形式的赋值
    let mut locals: Vec<NamedParamSource> = Vec::new();
    let start = function.start_line.saturating_sub(1);
    let end = function.end_line.min(lines.len());
    for i in start..end {
        let raw = lines[i];
        let line_no = i + 1;
        let trimmed = raw.trim();
        if trimmed.is_empty() || trimmed.starts_with('%') {
            continue;
        }
        // 尝试解析 `Var = Expr` 形式（仅简单 var LHS）
        let Some((var_name, rhs_text)) = parse_simple_assignment(trimmed) else {
            continue;
        };
        let source = classify_rhs_text(rhs_text, line_no, &param_names);
        locals.push(NamedParamSource {
            var: var_name,
            source,
        });
    }

    Ok(ParamSourceResult {
        mfa: mfa_key(module, &function.name, function.arity),
        params: (0..function.arity)
            .map(|i| ParamSource::Param { index: i })
            .collect(),
        locals,
    })
}

/// 从函数头行提取参数名：`name(Var1, Var2) ->` → ["Var1", "Var2"]
/// 仅识别简单 var 参数；复杂模式（`{A, B}` 或 `_`）放空字符串占位。
fn extract_param_names_from_head(head: &str) -> Vec<String> {
    let Some(open) = head.find('(') else {
        return Vec::new();
    };
    let Some(close) = find_matching_paren(head, open) else {
        return Vec::new();
    };
    let args_str = &head[open + 1..close];
    // 按逗号分割（顶层，不进入嵌套括号）
    let mut params = Vec::new();
    for part in split_top_level_commas(args_str) {
        let trimmed = part.trim();
        if trimmed.is_empty() {
            continue;
        }
        // 简单 var：大写字母或下划线开头
        let bytes = trimmed.as_bytes();
        if !bytes.is_empty() && (bytes[0].is_ascii_uppercase() || bytes[0] == b'_') {
            // 读 var 名
            let end = trimmed
                .find(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
                .unwrap_or(trimmed.len());
            params.push(trimmed[..end].to_string());
        } else {
            // 复杂模式，放空占位
            params.push(String::new());
        }
    }
    params
}

/// 在 `s[open] == '('` 的前提下，找匹配的右括号位置。
fn find_matching_paren(s: &str, open: usize) -> Option<usize> {
    let bytes = s.as_bytes();
    let mut depth = 1;
    let mut i = open + 1;
    while i < bytes.len() && depth > 0 {
        match bytes[i] {
            b'(' => depth += 1,
            b')' => depth -= 1,
            _ => {}
        }
        i += 1;
    }
    if depth == 0 {
        Some(i - 1)
    } else {
        None
    }
}

/// 按顶层逗号分割（不进入嵌套括号/花括号/方括号）。
fn split_top_level_commas(s: &str) -> Vec<&str> {
    let mut parts = Vec::new();
    let bytes = s.as_bytes();
    let mut depth = 0;
    let mut start = 0;
    for (i, &b) in bytes.iter().enumerate() {
        match b {
            b'(' | b'{' | b'[' | b'<' => depth += 1,
            b')' | b'}' | b']' | b'>' => depth -= 1,
            b',' if depth == 0 => {
                parts.push(&s[start..i]);
                start = i + 1;
            }
            _ => {}
        }
    }
    if start < s.len() {
        parts.push(&s[start..]);
    }
    parts
}

/// 解析 `Var = Expr` 形式（仅简单 var LHS，非模式匹配）。
/// 返回 (var_name, rhs_text)；不匹配返回 None。
fn parse_simple_assignment(line: &str) -> Option<(String, &str)> {
    let trimmed = line.trim_start();
    let bytes = trimmed.as_bytes();
    if bytes.is_empty() || (!bytes[0].is_ascii_uppercase() && bytes[0] != b'_') {
        return None;
    }
    // 读 var 名
    let mut i = 0;
    while i < bytes.len() && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'_') {
        i += 1;
    }
    if i == 0 {
        return None;
    }
    let var = &trimmed[..i];
    // 跳过空白
    let rest = trimmed[i..].trim_start();
    // 必须以 `=` 开头，但不是 `==`
    if !rest.starts_with('=') || rest.starts_with("==") {
        return None;
    }
    let after_eq = &rest[1..];
    // = 后必须跟空白或表达式
    let rhs = after_eq.trim_start();
    if rhs.is_empty() {
        return None;
    }
    // 排除 `<=`、`>=`、`=/=`、`=:=` 等比较运算符
    if rhs.starts_with('=') {
        return None;
    }
    Some((var.to_string(), rhs))
}

/// 对 RHS 文本分类。
fn classify_rhs_text(rhs: &str, line: usize, param_names: &[String]) -> ParamSource {
    let trimmed = rhs.trim();
    // 去掉末尾的 `.` 或 `,` 或 `;`
    let trimmed = trimmed.trim_end_matches(|c: char| c == '.' || c == ',' || c == ';');
    let trimmed = trimmed.trim();

    // 远程调用 M:F(...)
    if let Some(call) = parse_remote_call_line(trimmed) {
        let arity = count_args(&call.args);
        return ParamSource::Call {
            module: Some(call.module),
            function: call.function,
            arity,
            line,
        };
    }
    // 本地调用 F(...) —— 简化判断：以小写字母开头且紧跟 `(`
    if let Some(open) = trimmed.find('(') {
        let fun_part = &trimmed[..open];
        if !fun_part.is_empty()
            && fun_part
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_')
            && fun_part.as_bytes()[0].is_ascii_lowercase()
        {
            // 确认是 F(...) 形式
            if let Some(close) = find_matching_paren(trimmed, open) {
                let args = &trimmed[open + 1..close];
                let arity = count_args(args);
                return ParamSource::Call {
                    module: None,
                    function: fun_part.to_string(),
                    arity,
                    line,
                };
            }
        }
    }
    // 字面量：整数、浮点、atom、字符串、binary
    if is_literal(trimmed) {
        return ParamSource::Literal {
            value: trimmed.to_string(),
            line,
        };
    }
    // 变量：大写字母或下划线开头
    let bytes = trimmed.as_bytes();
    if !bytes.is_empty() && (bytes[0].is_ascii_uppercase() || bytes[0] == b'_') {
        // 读 var 名
        let end = trimmed
            .find(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
            .unwrap_or(trimmed.len());
        let var_name = trimmed[..end].to_string();
        if param_names.contains(&var_name) {
            return ParamSource::Param {
                index: param_names.iter().position(|p| p == &var_name).unwrap_or(0),
            };
        }
        return ParamSource::VarChain {
            from_var: var_name,
            line,
        };
    }
    // 复杂表达式（case/if/list comp/tuple/map/{ok, Var} = ...）
    ParamSource::FieldExtract {
        line,
        source_text: trimmed.to_string(),
    }
}

/// 判断字符串是否为 Erlang 字面量。
fn is_literal(s: &str) -> bool {
    if s.is_empty() {
        return false;
    }
    let bytes = s.as_bytes();
    // 整数/浮点
    if bytes[0].is_ascii_digit()
        || (bytes[0] == b'-' && bytes.len() > 1 && bytes[1].is_ascii_digit())
    {
        return s.bytes().all(|b| b.is_ascii_digit() || b == b'.' || b == b'-');
    }
    // atom（小写字母开头，含字母数字下划线 @）
    if bytes[0].is_ascii_lowercase() {
        return s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'@');
    }
    // 字符串
    if s.starts_with('"') && s.ends_with('"') && s.len() >= 2 {
        return true;
    }
    // binary
    if s.starts_with("<<") && s.ends_with(">>") {
        return true;
    }
    false
}

/// 数参数个数（按顶层逗号分割）。
fn count_args(args: &str) -> usize {
    if args.trim().is_empty() {
        return 0;
    }
    split_top_level_commas(args).len()
}

// ============================================================================
// P0-3: 跨过程数据流追踪
// ============================================================================

/// 数据流追踪节点：DAG 中的一个节点。
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct DataFlowNode {
    /// MFA key `module:function/arity`
    pub mfa: String,
    /// 角色：target（目标函数）/ producer（参数生产者）/ dataSource（数据源）
    pub role: String,
    /// 该节点为目标函数的第几个参数提供来源（producer 角色时填）
    pub param_index: Option<usize>,
    /// 来源详情（Call/FieldExtract/Unknown 等）
    pub source: Option<ParamSource>,
    /// 递归深度（0 = 目标函数本身）
    pub depth: usize,
}

/// 跨过程数据流追踪结果：DAG。
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct DataFlowTrace {
    /// 目标函数 MFA key
    pub root_mfa: String,
    /// 追踪的目标参数序号
    pub param_index: usize,
    /// DAG 节点列表
    pub nodes: Vec<DataFlowNode>,
    /// DAG 边（父节点索引 → 子节点索引）
    pub edges: Vec<(usize, usize)>,
    /// 是否因深度/节点上限被截断
    pub truncated: bool,
}

/// 跨过程数据流追踪参数。
pub struct TraceParams {
    pub module: Option<String>,
    pub function: String,
    pub arity: usize,
    /// 追踪第几个参数（1-based）
    pub param_index: usize,
    pub max_depth: usize,
    pub max_nodes: usize,
}

/// 跨过程递归追溯参数依赖 DAG。
///
/// 算法：
/// 1. 从目标函数 `{M, F, A}` 的第 `param_index` 个参数出发
/// 2. 反查 callers（用 CallGraphIndex::callers）
/// 3. 对每个 caller，分析其调用点 `target(Arg1, ..., ArgI, ...)` 中 ArgI 的来源
///    （用 analyze_param_sources 的 use-def chain）
/// 4. 若来源是 `Var = producer(...)`，把 producer 加入 DAG，递归追溯 producer 的参数
/// 5. 直到来源是 Param{index}（caller 的入参）、Literal、Unknown，或达到深度/节点上限
///
/// 输出 DAG：根为目标函数，叶为外部输入或不可解析的来源。
///
/// 注：调用方应先 clone `Arc<SearchIndex>` 再放锁；本函数内部可能读盘。
pub fn trace_data_flow(
    index: &crate::SearchIndex,
    params: TraceParams,
) -> DataFlowTrace {
    let root_key = mfa_key(params.module.as_deref(), &params.function, params.arity);
    let mut nodes: Vec<DataFlowNode> = vec![DataFlowNode {
        mfa: root_key.clone(),
        role: "target".to_string(),
        param_index: Some(params.param_index),
        source: None,
        depth: 0,
    }];
    let mut edges: Vec<(usize, usize)> = Vec::new();
    let mut truncated = false;
    let mut visited: std::collections::HashSet<String> = std::collections::HashSet::new();
    visited.insert(root_key.clone());

    // BFS 工作队列：(节点索引, 待追溯的 MFA, 参数序号, 深度)
    let mut queue: std::collections::VecDeque<(usize, String, usize, usize)> =
        std::collections::VecDeque::new();
    queue.push_back((0, root_key.clone(), params.param_index, 0));

    while let Some((node_idx, mfa_key_str, param_idx, depth)) = queue.pop_front() {
        if depth >= params.max_depth {
            truncated = true;
            continue;
        }
        if nodes.len() >= params.max_nodes {
            truncated = true;
            break;
        }

        // 解析 MFA key
        let (m, f, a) = match parse_mfa_key(&mfa_key_str) {
            Some(x) => x,
            None => continue,
        };

        // 反查 callers
        let callers = index.call_graph_index.callers(m, &f, a);
        if callers.is_empty() {
            // 没有调用方（可能是 API 入口），标记为外部输入
            continue;
        }

        for caller_edge in callers {
            let caller_mfa = mfa_key(
                caller_edge.from_module.as_deref(),
                caller_edge.from_function.as_deref().unwrap_or(""),
                caller_edge.from_arity,
            );

            // 找 caller 函数的源码
            let Some(caller_doc) = index.doc_by_module(caller_edge.from_module.as_deref())
            else {
                continue;
            };
            let Some(caller_fun) = caller_doc.functions.iter().find(|f| {
                f.name == caller_edge.from_function.as_deref().unwrap_or("") && f.arity == caller_edge.from_arity
            })
            else {
                continue;
            };

            // 分析 caller 的 use-def chain（P1-3：正文走 mtime 校验的磁盘读缓存，
            // 大调用图上不再每个 caller 读盘一次）
            let body = crate::effective_body_cached(caller_doc);
            let body_str: &str = body.as_ref();
            let param_sources = analyze_param_sources(
                body_str,
                caller_doc.module.as_deref(),
                caller_fun,
            )
            .ok();

            let Some(ParamSourceResult { locals, .. }) = param_sources else {
                continue;
            };

            // 找到调用 targetFun 的那一行附近，哪个变量被传入了第 param_idx 个参数位置
            let relevant = find_relevant_producer(&locals, caller_edge.line, param_idx, body_str);

            for producer in relevant {
                let producer_mfa = match &producer.source {
                    ParamSource::Call { module, function, arity, .. } => {
                        mfa_key(module.as_deref(), function, *arity)
                    }
                    ParamSource::Param { index } => {
                        // caller 的入参，递归追溯到 caller 的 caller。
                        // Param.index 为 0-based；对外/队列统一用 1-based。
                        if visited.contains(&caller_mfa) {
                            continue;
                        }
                        visited.insert(caller_mfa.clone());
                        let idx1 = *index + 1;
                        let new_idx = nodes.len();
                        nodes.push(DataFlowNode {
                            mfa: caller_mfa.clone(),
                            role: "paramSource".to_string(),
                            param_index: Some(idx1),
                            source: Some(producer.source.clone()),
                            depth: depth + 1,
                        });
                        edges.push((node_idx, new_idx));
                        queue.push_back((new_idx, caller_mfa.clone(), idx1, depth + 1));
                        continue;
                    }
                    ParamSource::Literal { .. } | ParamSource::FieldExtract { .. } |
                    ParamSource::VarChain { .. } | ParamSource::Unknown => {
                        if visited.contains(&caller_mfa) {
                            continue;
                        }
                        visited.insert(caller_mfa.clone());
                        let new_idx = nodes.len();
                        nodes.push(DataFlowNode {
                            mfa: caller_mfa.clone(),
                            role: "intermediate".to_string(),
                            param_index: None,
                            source: Some(producer.source.clone()),
                            depth: depth + 1,
                        });
                        edges.push((node_idx, new_idx));
                        continue;
                    }
                };

                if visited.contains(&producer_mfa) {
                    continue;
                }
                visited.insert(producer_mfa.clone());

                let new_idx = nodes.len();
                nodes.push(DataFlowNode {
                    mfa: producer_mfa.clone(),
                    role: "producer".to_string(),
                    param_index: Some(param_idx),
                    source: Some(producer.source.clone()),
                    depth: depth + 1,
                });
                edges.push((node_idx, new_idx));

                if nodes.len() >= params.max_nodes {
                    truncated = true;
                    break;
                }

                // Call 返回值依赖 producer 的哪些入参未知，不再硬编码 param_index=1
                // 深入（会生成错误 DAG）。仅记录 producer 节点；Param 分支已用真实 index 递归。
            }
        }
    }

    DataFlowTrace {
        root_mfa: root_key,
        param_index: params.param_index,
        nodes,
        edges,
        truncated,
    }
}

/// `module:function/arity` → `(module, function, arity)`，失败返回 None。
fn parse_mfa_key(key: &str) -> Option<(Option<&str>, &str, usize)> {
    let slash = key.rfind('/')?;
    let arity: usize = key[slash + 1..].parse().ok()?;
    let before = &key[..slash];
    let (module, function) = match before.rfind(':') {
        Some(colon) => (Some(&before[..colon]), &before[colon + 1..]),
        None => (None, before),
    };
    Some((module, function, arity))
}

/// 在 use-def chain 结果中，找出"传给目标参数位置"的生产者。
///
/// 精确版：解析调用点第 `param_idx` 个实参（1-based）的变量名，再按该变量名在
/// `locals` 中精确匹配 Call 类型来源——不再忽略参数序号乱猜。
/// 降级版：当调用点无法解析、实参不是简单变量、或精确匹配无果时，退回"最近 3 条
/// Call 赋值"启发式（行级扫描无法处理嵌套/跨行表达式，只能就近猜测）。
fn find_relevant_producer<'a>(
    locals: &'a [NamedParamSource],
    caller_line: usize,
    param_idx: usize,
    caller_body: &str,
) -> Vec<&'a NamedParamSource> {
    // 优先：按调用点实参变量名精确匹配，避免把其它参数的生产者误连进 DAG。
    if let Some(arg_var) = extract_arg_var_at(caller_body, caller_line, param_idx) {
        let exact: Vec<&NamedParamSource> = locals
            .iter()
            .filter(|n| n.var == arg_var && matches!(n.source, ParamSource::Call { .. }))
            .collect();
        if !exact.is_empty() {
            return exact;
        }
    }

    // 降级：解析不出实参名或精确匹配失败时，找调用行之前最近的 Call 类型变量定义。
    let mut candidates: Vec<&NamedParamSource> = locals
        .iter()
        .filter(|n| matches!(n.source, ParamSource::Call { .. }))
        .filter(|n| {
            let line = match &n.source {
                ParamSource::Call { line, .. } => *line,
                _ => usize::MAX,
            };
            line <= caller_line
        })
        .collect();
    // 按行号倒序，优先最近的
    candidates.sort_by(|a, b| {
        let la = match &a.source { ParamSource::Call { line, .. } => *line, _ => 0 };
        let lb = match &b.source { ParamSource::Call { line, .. } => *line, _ => 0 };
        lb.cmp(&la)
    });
    candidates.truncate(3);
    candidates
}

/// 解析 `body` 中第 `line`（1-based）行调用表达式的第 `param_idx`（1-based）个实参，
/// 若它是简单变量（大写/下划线开头）则返回其变量名；否则返回 None。
fn extract_arg_var_at(body: &str, line: usize, param_idx: usize) -> Option<String> {
    if param_idx == 0 {
        return None;
    }
    let raw = body.lines().nth(line.checked_sub(1)?)?;
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed.starts_with('%') {
        return None;
    }
    // 远程调用 `M:F(...)` 优先用专门的解析；本地调用退化为"行内第一个括号对"。
    let args = parse_remote_call_line(trimmed)
        .map(|call| call.args)
        .or_else(|| {
            let open = trimmed.find('(')?;
            let close = find_matching_paren(trimmed, open)?;
            Some(trimmed[open + 1..close].to_string())
        })?;
    let part = split_top_level_commas(&args).get(param_idx - 1)?.trim();
    simple_var_name(part)
}

/// 提取简单 Erlang 变量名（大写或下划线开头，后跟字母数字下划线）。
fn simple_var_name(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    if bytes.is_empty() || (!bytes[0].is_ascii_uppercase() && bytes[0] != b'_') {
        return None;
    }
    let end = text
        .find(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
        .unwrap_or(text.len());
    if end == 0 {
        return None;
    }
    Some(text[..end].to_string())
}

// ============================================================================
// 单元测试
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_function_symbol(name: &str, arity: usize, start: usize, end: usize) -> crate::FunctionSymbol {
        crate::FunctionSymbol {
            name: name.to_string(),
            arity,
            line: start,
            start_line: start,
            end_line: end,
            clauses: vec![crate::ClauseRange { start_line: start, end_line: end }],
        }
    }

    #[test]
    fn classify_known_data_sources() {
        assert_eq!(classify_data_source("ets", "lookup"), Some(DataSourceKind::Ets));
        assert_eq!(classify_data_source("ets", "lookup_element"), Some(DataSourceKind::Ets));
        assert_eq!(classify_data_source("mnesia", "dirty_read"), Some(DataSourceKind::Mnesia));
        assert_eq!(classify_data_source("pg", "equery"), Some(DataSourceKind::Sql));
        assert_eq!(classify_data_source("unknown", "lookup"), None);
        assert_eq!(classify_data_source("ets", "insert"), None);
    }

    #[test]
    fn extracts_ets_lookup_data_source() {
        let body = r#"
-module(foo).
-export([get_role/1]).
get_role(RoleUid) ->
    Role = ets:lookup(role_tab, RoleUid),
    Role.
"#;
        let functions = vec![sample_function_symbol("get_role", 1, 4, 6)];
        let calls = extract_data_source_calls(body, Some("foo"), &functions);
        assert_eq!(calls.len(), 1);
        let c = &calls[0];
        assert_eq!(c.caller_module.as_deref(), Some("foo"));
        assert_eq!(c.caller_function, "get_role");
        assert_eq!(c.caller_arity, 1);
        assert_eq!(c.source_type, DataSourceKind::Ets);
        assert_eq!(c.table, "role_tab");
        assert_eq!(c.return_var, "Role");
        assert_eq!(c.line, 5);
    }

    #[test]
    fn extracts_mnesia_dirty_read() {
        let body = r#"
-module(bar).
-export([load/1]).
load(Id) ->
    case mnesia:dirty_read(user_tab, Id) of
        [] -> none;
        [Row] -> Row
    end.
"#;
        let functions = vec![sample_function_symbol("load", 1, 4, 8)];
        let calls = extract_data_source_calls(body, Some("bar"), &functions);
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].source_type, DataSourceKind::Mnesia);
        assert_eq!(calls[0].table, "user_tab");
        // return_var 为空：调用不在简单 `Var = ...` 形式（在 case 表达式里）
        assert_eq!(calls[0].return_var, "");
    }

    #[test]
    fn skips_non_data_source_calls() {
        let body = r#"
-module(baz).
-export([f/1]).
f(X) ->
    Y = lists:reverse(X),
    Y.
"#;
        let functions = vec![sample_function_symbol("f", 1, 4, 6)];
        let calls = extract_data_source_calls(body, Some("baz"), &functions);
        assert_eq!(calls.len(), 0);
    }

    #[test]
    fn handles_dynamic_table_name() {
        let body = r#"
-module(qux).
-export([f/1]).
f(Tab) ->
    ets:lookup(Tab, key).
"#;
        let functions = vec![sample_function_symbol("f", 1, 4, 6)];
        let calls = extract_data_source_calls(body, Some("qux"), &functions);
        assert_eq!(calls.len(), 1);
        // 动态表名（变量）应返回空
        assert_eq!(calls[0].table, "");
    }

    #[test]
    fn mfa_key_formats_correctly() {
        assert_eq!(mfa_key(Some("foo"), "bar", 1), "foo:bar/1");
        assert_eq!(mfa_key(None, "bar", 2), "bar/2");
        assert_eq!(mfa_key(Some(""), "bar", 0), "bar/0");
    }

    #[test]
    fn parse_mfa_key_roundtrip() {
        let (m, f, a) = parse_mfa_key("foo:bar/2").unwrap();
        assert_eq!(m, Some("foo"));
        assert_eq!(f, "bar");
        assert_eq!(a, 2);

        let (m, f, a) = parse_mfa_key("bar/0").unwrap();
        assert_eq!(m, None);
        assert_eq!(f, "bar");
        assert_eq!(a, 0);

        assert!(parse_mfa_key("invalid").is_none());
    }

    #[test]
    fn data_source_index_callers_of_table() {
        let mut idx = DataSourceIndex::default();
        idx.push(DataSourceCall {
            caller_module: Some("foo".to_string()),
            caller_function: "get_role".to_string(),
            caller_arity: 1,
            source_type: DataSourceKind::Ets,
            table: "role_tab".to_string(),
            line: 5,
            return_var: "Role".to_string(),
        });
        idx.push(DataSourceCall {
            caller_module: Some("bar".to_string()),
            caller_function: "load".to_string(),
            caller_arity: 1,
            source_type: DataSourceKind::Mnesia,
            table: "ROLE_TAB".to_string(),
            line: 3,
            return_var: String::new(),
        });

        // case-insensitive 查表名
        let callers = idx.callers_of_table("role_tab");
        assert_eq!(callers.len(), 2);
        let callers_upper = idx.callers_of_table("ROLE_TAB");
        assert_eq!(callers_upper.len(), 2);
    }

    #[test]
    fn analyze_param_sources_identifies_call_producer() {
        let body = r#"
-module(foo).
-export([handle_query_pos/1]).
handle_query_pos(RoleUid) ->
    RealUid = uidConv:toRoleUid(RoleUid),
    Role = roleMgr:lookup(RealUid),
    {X, Y} = posConv:scene2world(Role),
    {X, Y}.
"#;
        let function = sample_function_symbol("handle_query_pos", 1, 4, 8);
        let result = analyze_param_sources(body, Some("foo"), &function).unwrap();
        assert_eq!(result.params.len(), 1);
        assert!(matches!(result.params[0], ParamSource::Param { index: 0 }));
        // 应识别出两个简单 var 赋值（{X, Y} = ... 是 tuple 模式，设计上不处理）
        assert_eq!(result.locals.len(), 2);
        // 第一个：RealUid = uidConv:toRoleUid(RoleUid)
        let real_uid = result.locals.iter().find(|n| n.var == "RealUid").unwrap();
        match &real_uid.source {
            ParamSource::Call { module, function, arity, .. } => {
                assert_eq!(module.as_deref(), Some("uidConv"));
                assert_eq!(function, "toRoleUid");
                assert_eq!(*arity, 1);
            }
            other => panic!("expected Call, got {other:?}"),
        }
        // 第二个：Role = roleMgr:lookup(RealUid)
        let role = result.locals.iter().find(|n| n.var == "Role").unwrap();
        match &role.source {
            ParamSource::Call { module, function, arity, .. } => {
                assert_eq!(module.as_deref(), Some("roleMgr"));
                assert_eq!(function, "lookup");
                assert_eq!(*arity, 1);
            }
            other => panic!("expected Call, got {other:?}"),
        }
    }

    #[test]
    fn analyze_param_sources_handles_literal_and_var_chain() {
        let body = r#"
-module(foo).
-export([f/1]).
f(X) ->
    A = 42,
    B = A,
    B.
"#;
        let function = sample_function_symbol("f", 1, 4, 7);
        let result = analyze_param_sources(body, Some("foo"), &function).unwrap();
        let a = result.locals.iter().find(|n| n.var == "A").unwrap();
        assert!(matches!(a.source, ParamSource::Literal { .. }));
        let b = result.locals.iter().find(|n| n.var == "B").unwrap();
        match &b.source {
            ParamSource::VarChain { from_var, .. } => assert_eq!(from_var, "A"),
            other => panic!("expected VarChain, got {other:?}"),
        }
    }

    #[test]
    fn analyze_param_sources_unknown_for_function_without_clause() {
        let body = r#"
-module(foo).
-ifdef(not_defined).
f(X) -> X.
-endif.
"#;
        let function = sample_function_symbol("f", 1, 4, 4);
        let result = analyze_param_sources(body, Some("foo"), &function).unwrap();
        // 找不到 clause 时仍返回入参
        assert_eq!(result.params.len(), 1);
        assert!(result.locals.is_empty());
    }

    #[test]
    fn find_relevant_producer_respects_param_index() {
        let mk_call = |var: &str, function: &str, line: usize| NamedParamSource {
            var: var.to_string(),
            source: ParamSource::Call {
                module: Some("m".to_string()),
                function: function.to_string(),
                arity: 1,
                line,
            },
        };
        let locals = vec![mk_call("A", "producerA", 5), mk_call("B", "producerB", 6)];
        // 调用点 target(A, B)：第 1 个实参 A 应只匹配 A 的生产者，而不是按行号
        // 返回 [B, A]（B 行号更近会被错误优先）。
        let body = "    target(A, B),\n";
        let relevant = find_relevant_producer(&locals, 1, 1, body);
        assert_eq!(relevant.len(), 1);
        assert_eq!(relevant[0].var, "A");

        let relevant = find_relevant_producer(&locals, 1, 2, body);
        assert_eq!(relevant.len(), 1);
        assert_eq!(relevant[0].var, "B");
    }
}
