//! 搜索结果二次排序（Rerank）。
//!
//! 在 BM25 / 向量召回得到候选列表后，调用兼容 Cohere `/v1/rerank` 协议的
//! HTTP API，按与查询的相关性重排。
//!
//! # 配置
//! - `ALI_RERANK_API_KEY`（必须由 Erlang 配置显式注入；不回退 LLM key）
//! - `ALI_RERANK_BASE_URL`（必须显式配置，无默认 OpenAI）
//! - `ALI_RERANK_MODEL`
//!
//! 未配置时 `rerank_hits` 原样返回输入，不影响主流程。
//! DeepSeek 对话 API **不提供** rerank。

use anyhow::{Context, Result};
use reqwest::Client;
use serde::{Deserialize, Serialize};

use crate::SearchHit;

/// 单个候选送入 rerank API 的文档最大字符数，避免超长片段撑爆请求。
const MAX_RERANK_DOC_CHARS: usize = 2000;

/// 把命中构造成携带**实际代码内容**的 rerank 文档。
///
/// 仅用 `file + module` 时，rerank 模型看不到代码语义、几乎无法有效重排；这里额外拼接
/// 函数签名与命中代码片段（snippets），必要时截断，让相关性打分基于真实内容。
fn rerank_document(hit: &SearchHit) -> String {
    let mut doc = String::new();
    doc.push_str(&hit.file);
    if let Some(module) = hit.module.as_deref() {
        if !module.is_empty() {
            doc.push(' ');
            doc.push_str(module);
        }
    }
    let functions = hit
        .functions
        .iter()
        .map(|fun| format!("{}/{}", fun.name, fun.arity))
        .collect::<Vec<_>>()
        .join(" ");
    if !functions.is_empty() {
        doc.push('\n');
        doc.push_str(&functions);
    }
    for snippet in &hit.snippets {
        doc.push('\n');
        doc.push_str(snippet.text.trim());
    }
    if doc.chars().count() > MAX_RERANK_DOC_CHARS {
        doc = doc.chars().take(MAX_RERANK_DOC_CHARS).collect();
    }
    doc
}

#[derive(Debug, Deserialize)]
struct RerankResponse {
    results: Vec<RerankItem>,
}

#[derive(Debug, Deserialize)]
struct RerankItem {
    /// 对应输入 documents 数组的下标
    index: usize,
    relevance_score: f32,
}

/// Rerank HTTP 配置。
pub struct RerankConfig {
    pub api_key: String,
    pub base_url: String,
    pub model: String,
}

impl RerankConfig {
    /// 完全走配置：必须同时有 key、base_url、model。
    /// 不回退 LLM key，不默认 OpenAI/Cohere URL/模型名。
    pub fn from_env() -> Option<Self> {
        let api_key = match std::env::var("ALI_RERANK_API_KEY") {
            Ok(k) if !k.trim().is_empty() => k,
            _ => return None,
        };
        let base_url = match std::env::var("ALI_RERANK_BASE_URL") {
            Ok(u) if !u.trim().is_empty() => u,
            _ => return None,
        };
        let model = match std::env::var("ALI_RERANK_MODEL") {
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

/// 对候选 `hits` 按与 `query` 的相关性重排；无配置时直接返回原列表。
///
/// 复用调用方传入的共享 `client`（带全局超时），避免每次新建无超时 Client 可能
/// 因慢/挂起的 rerank 端点拖死整个 Core（M6）。
pub async fn rerank_hits(client: &Client, query: &str, hits: Vec<SearchHit>) -> Result<Vec<SearchHit>> {
    let Some(config) = RerankConfig::from_env() else {
        return Ok(hits);
    };
    if hits.len() <= 1 {
        return Ok(hits);
    }

    let documents = hits.iter().map(rerank_document).collect::<Vec<_>>();

    #[derive(Serialize)]
    struct Request<'a> {
        model: &'a str,
        query: &'a str,
        documents: &'a [String],
        top_n: usize,
    }

    let response = client
        .post(&config.base_url)
        .bearer_auth(&config.api_key)
        .json(&Request {
            model: &config.model,
            query,
            documents: &documents,
            top_n: hits.len(),
        })
        .send()
        .await?
        .error_for_status()?
        .json::<RerankResponse>()
        .await
        .context("failed to decode rerank response")?;

    let mut reranked = Vec::new();
    let mut covered = vec![false; hits.len()];
    for item in response.results {
        if let Some(hit) = hits.get(item.index).cloned() {
            covered[item.index] = true;
            reranked.push(SearchHit {
                score: item.relevance_score,
                ..hit
            });
        }
    }
    Ok(fill_rerank_misses(&hits, reranked, &covered))
}

/// R9：合并 rerank 结果与原命中。rerank 未覆盖的原始命中按原分数补回，
/// 保证返回结果与输入等长，不静默丢弃缺失命中。
fn fill_rerank_misses(
    hits: &[SearchHit],
    reranked: Vec<SearchHit>,
    covered: &[bool],
) -> Vec<SearchHit> {
    if reranked.is_empty() {
        return hits.to_vec();
    }
    let mut merged = reranked;
    if merged.len() < hits.len() {
        for (index, hit) in hits.iter().enumerate() {
            if !covered.get(index).copied().unwrap_or(false) {
                merged.push(hit.clone());
            }
        }
    }
    merged
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mk_hit(file: &str, score: f32) -> SearchHit {
        SearchHit {
            file: file.to_string(),
            module: None,
            score,
            functions: Vec::new(),
            exports: Vec::new(),
            records: Vec::new(),
            macros: Vec::new(),
            snippets: Vec::new(),
        }
    }

    #[test]
    fn rerank_misses_are_filled_to_same_length() {
        let hits = vec![
            mk_hit("a.erl", 0.9),
            mk_hit("b.erl", 0.8),
            mk_hit("c.erl", 0.7),
        ];
        // rerank 只返回 index 0，其余 2 个应被补回并保持原分数。
        let covered = vec![true, false, false];
        let reranked = vec![SearchHit {
            score: 0.99,
            ..mk_hit("a.erl", 0.9)
        }];
        let merged = fill_rerank_misses(&hits, reranked, &covered);
        assert_eq!(merged.len(), 3);
        assert_eq!(merged[0].file, "a.erl");
        assert_eq!(merged[0].score, 0.99);
        assert_eq!(merged[1].file, "b.erl");
        assert_eq!(merged[1].score, 0.8);
        assert_eq!(merged[2].file, "c.erl");
        assert_eq!(merged[2].score, 0.7);
    }

    #[test]
    fn rerank_empty_result_keeps_original_hits() {
        let hits = vec![mk_hit("a.erl", 0.9), mk_hit("b.erl", 0.8)];
        let merged = fill_rerank_misses(&hits, Vec::new(), &[false, false]);
        assert_eq!(merged.len(), 2);
        assert_eq!(merged[0].file, "a.erl");
        assert_eq!(merged[1].file, "b.erl");
    }
}
