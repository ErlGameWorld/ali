//! 索引忽略规则与可索引扩展名。
//!
//! # `IgnoreMatcher`
//! 权威来源：Erlang 启动参数 `--ali-index-ignore=`（main 写入进程内 `ALI_INDEX_IGNORE`）
//!（来自 `aliCfg.cfg` → `core.indexIgnore`）。未设置时才用最小兜底，
//! 避免独立跑 aliCore 时扫进 `.git`。
//!
//! 可选：`ALI_INDEX_USE_GITIGNORE=1` 时额外合并项目根 `.gitignore`。
//!
//! # `IndexExtensions`
//! 控制哪些后缀进入索引。默认 `erl,hrl`；可通过 `ALI_INDEX_EXTENSIONS`
//! 扩展到 `cfg,c,h,rs` 等。`.erl`/`.hrl` 走 tree-sitter 函数级分块，
//! 其它扩展名走全文按行分块（见 `main.rs`）。

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

/// 未收到 Erlang 注入时的最小兜底（独立调试 aliCore 用）。
const FALLBACK_IGNORE: &[&str] = &[".git", ".svn", "_build", "target", ".ali"];

/// 未配置 `ALI_INDEX_EXTENSIONS` 时的默认后缀（不含点）。
const DEFAULT_EXTENSIONS: &[&str] = &["erl", "hrl"];

/// 路径忽略匹配器：对相对路径做简单 glob/前缀匹配。
pub struct IgnoreMatcher {
    patterns: Vec<String>,
}

impl IgnoreMatcher {
    /// 从进程环境读取忽略规则（由启动参数 `--ali-index-ignore=` 写入）。
    pub fn load(root: &Path) -> Self {
        let mut patterns = Vec::new();

        match std::env::var("ALI_INDEX_IGNORE") {
            Ok(extra) if !extra.trim().is_empty() => {
                for part in extra.split([',', ';']) {
                    let trimmed = part.trim();
                    if !trimmed.is_empty() {
                        patterns.push(trimmed.to_string());
                    }
                }
            }
            _ => {
                patterns.extend(FALLBACK_IGNORE.iter().map(|p| (*p).to_string()));
            }
        }

        if std::env::var("ALI_INDEX_USE_GITIGNORE")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
            .unwrap_or(false)
        {
            let gitignore = root.join(".gitignore");
            if let Ok(content) = std::fs::read_to_string(&gitignore) {
                for line in content.lines() {
                    let line = line.trim();
                    if line.is_empty() || line.starts_with('#') {
                        continue;
                    }
                    patterns.push(line.trim_start_matches('/').to_string());
                }
            }
        }

        Self { patterns }
    }

    /// `path` 是否应被跳过。路径必须位于 `root` 之下。
    pub fn is_ignored(&self, root: &Path, path: &Path) -> bool {
        let Ok(rel) = path.strip_prefix(root) else {
            return true;
        };
        let rel_str = rel.to_string_lossy().replace('\\', "/");
        self.patterns
            .iter()
            .any(|pat| pattern_matches(pat, &rel_str))
    }
}

/// 可索引文件扩展名集合（小写、无点，如 `"erl"`）。
#[derive(Clone, Debug)]
pub struct IndexExtensions {
    extensions: BTreeSet<String>,
}

impl IndexExtensions {
    /// 从 `ALI_INDEX_EXTENSIONS` 读取；未设置或为空则用默认。
    pub fn from_env() -> Self {
        std::env::var("ALI_INDEX_EXTENSIONS")
            .ok()
            .map(|value| Self::with_list(&value))
            .filter(|exts| !exts.extensions.is_empty())
            .unwrap_or_else(|| Self {
                extensions: default_extensions(),
            })
    }

    /// 解析逗号分隔列表，如 `"erl,hrl,cfg,rs"`。
    pub fn with_list(raw: &str) -> Self {
        Self {
            extensions: parse_extension_list(raw),
        }
    }

    /// 文件后缀是否在白名单中。
    pub fn is_indexable(&self, path: &Path) -> bool {
        path.extension()
            .and_then(|ext| ext.to_str())
            .map(normalize_extension)
            .map(|ext| self.extensions.contains(&ext))
            .unwrap_or(false)
    }

    /// 返回已配置扩展名列表（小写、无点），供 `/index/status` 展示。
    pub fn as_vec(&self) -> Vec<String> {
        self.extensions.iter().cloned().collect()
    }

    /// 推断给定文件路径应使用的分块模式。
    pub fn chunker_for(&self, path: &Path) -> ChunkerMode {
        let ext = file_extension(path);
        if !self.extensions.contains(&ext) {
            return ChunkerMode::LineBased;
        }
        chunker_for_ext(&ext)
    }

    /// 列出当前配置中每种 chunker 模式覆盖的扩展名。
    pub fn chunker_coverage(&self) -> BTreeMap<&'static str, Vec<String>> {
        let mut map: BTreeMap<&'static str, Vec<String>> = BTreeMap::new();
        for ext in &self.extensions {
            let mode = chunker_for_ext(ext);
            map.entry(mode.label()).or_default().push(ext.clone());
        }
        map
    }
}

/// chunker 模式标签。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChunkerMode {
    TreeSitter,
    TreeSitterHrl,
    LineBased,
}

impl ChunkerMode {
    pub fn label(self) -> &'static str {
        match self {
            ChunkerMode::TreeSitter => "treeSitter",
            ChunkerMode::TreeSitterHrl => "treeSitterHrl",
            ChunkerMode::LineBased => "lineBased",
        }
    }
}

fn chunker_for_ext(ext: &str) -> ChunkerMode {
    match ext {
        "erl" => ChunkerMode::TreeSitter,
        "hrl" => ChunkerMode::TreeSitterHrl,
        _ => ChunkerMode::LineBased,
    }
}

fn default_extensions() -> BTreeSet<String> {
    DEFAULT_EXTENSIONS.iter().map(|s| (*s).to_string()).collect()
}

fn parse_extension_list(raw: &str) -> BTreeSet<String> {
    raw.split([',', ';'])
        .map(normalize_extension)
        .filter(|s| !s.is_empty())
        .collect()
}

fn normalize_extension(raw: &str) -> String {
    raw.trim()
        .trim_start_matches('.')
        .to_ascii_lowercase()
}

/// 判断相对路径 `rel` 是否匹配忽略模式。
///
/// P1-1 修复：原实现每个 pattern 每次匹配做 3 次 `format!` 分配
/// （数万文件 × 数十 pattern = 百万级临时 String，拖慢扫盘）。
/// 现改为零分配的字节边界比较。
fn pattern_matches(pattern: &str, rel: &str) -> bool {
    let pat = pattern.trim_end_matches('/');
    if pat.is_empty() {
        return false;
    }
    if let Some(suffix) = pat.strip_prefix('*') {
        let suffix = suffix.trim_end_matches('*');
        if suffix.is_empty() {
            return true;
        }
        return rel.ends_with(suffix);
    }
    if let Some(prefix) = pat.strip_suffix('*') {
        // "prefix*"：整串前缀，或任一 '/' 边界之后的前缀。
        if rel.starts_with(prefix) {
            return true;
        }
        return rel.match_indices(prefix).any(|(i, _)| {
            i > 0 && rel.as_bytes()[i - 1] == b'/'
        });
    }
    if pat.contains('*') {
        // 中间的 '*'（如 "foo*bar"）：退化为前后缀双匹配（极少用到）。
        let mut parts = pat.splitn(2, '*');
        let head = parts.next().unwrap_or("");
        let tail = parts.next().unwrap_or("").trim_end_matches('*');
        return rel.starts_with(head) && rel.ends_with(tail);
    }
    contains_segment(rel, pat)
}

/// `rel` 中是否存在完整路径段等于 `pat`（或 pat 覆盖多个连续段）。
/// 等价于原 `rel == pat || starts_with("pat/") || ends_with("/pat") || contains("/pat/")`，
/// 但不做任何堆分配。
fn contains_segment(rel: &str, pat: &str) -> bool {
    rel.match_indices(pat).any(|(i, _)| {
        let before_ok = i == 0 || rel.as_bytes()[i - 1] == b'/';
        let after = i + pat.len();
        let after_ok = after == rel.len() || rel.as_bytes()[after] == b'/';
        before_ok && after_ok
    })
}

pub fn file_extension(path: &Path) -> String {
    path.extension()
        .and_then(|ext| ext.to_str())
        .map(normalize_extension)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_extension_list_with_dots_and_spaces() {
        let set = parse_extension_list(" .erl, hrl,.cfg,c, RS ");
        assert!(set.contains("erl"));
        assert!(set.contains("hrl"));
        assert!(set.contains("cfg"));
        assert!(set.contains("c"));
        assert!(set.contains("rs"));
    }

    #[test]
    fn indexable_respects_configured_extensions() {
        let exts = IndexExtensions {
            extensions: parse_extension_list("erl,cfg,rs"),
        };
        assert!(exts.is_indexable(Path::new("src/foo.erl")));
        assert!(exts.is_indexable(Path::new("config/app.cfg")));
        assert!(exts.is_indexable(Path::new("c_src/aliCore/src/main.rs")));
        assert!(!exts.is_indexable(Path::new("README.md")));
    }

    #[test]
    fn chunker_for_returns_tree_sitter_for_erl() {
        let exts = IndexExtensions::with_list("erl,hrl,cfg,rs");
        assert_eq!(exts.chunker_for(Path::new("src/foo.erl")), ChunkerMode::TreeSitter);
        assert_eq!(exts.chunker_for(Path::new("include/foo.hrl")), ChunkerMode::TreeSitterHrl);
        assert_eq!(exts.chunker_for(Path::new("c_src/main.rs")), ChunkerMode::LineBased);
        assert_eq!(exts.chunker_for(Path::new("config/app.cfg")), ChunkerMode::LineBased);
        assert_eq!(exts.chunker_for(Path::new("README.md")), ChunkerMode::LineBased);
    }

    #[test]
    fn chunker_coverage_groups_by_mode() {
        let exts = IndexExtensions::with_list("erl,hrl,cfg,rs");
        let cov = exts.chunker_coverage();
        assert!(cov.get("treeSitter").unwrap().contains(&"erl".to_string()));
        assert!(cov.get("treeSitterHrl").unwrap().contains(&"hrl".to_string()));
    }

    #[test]
    fn pattern_matches_path_segments() {
        assert!(pattern_matches(".svn", "foo/.svn/entries"));
        assert!(pattern_matches("_build", "_build/default/lib"));
        assert!(!pattern_matches(".svn", "src/foo.erl"));
    }

    #[test]
    fn pattern_matches_pb_generated() {
        assert!(pattern_matches(
            "*_pb.erl",
            "plugin/game_cfg/src/pb/common_pb.erl"
        ));
        assert!(pattern_matches("pb", "plugin/game_cfg/src/pb/common_pb.erl"));
        assert!(!pattern_matches("*_pb.erl", "src/common.erl"));
    }

    #[test]
    fn ignored_dir_matches_segment_name() {
        let matcher = IgnoreMatcher {
            patterns: vec!["_build".into(), ".git".into(), "node_modules".into()],
        };
        let root = Path::new("G:/proj");
        assert!(matcher.is_ignored(root, Path::new("G:/proj/_build")));
        assert!(matcher.is_ignored(root, Path::new("G:/proj/_build/default")));
        assert!(matcher.is_ignored(root, Path::new("G:/proj/.git")));
        assert!(!matcher.is_ignored(root, Path::new("G:/proj/src")));
    }
}
