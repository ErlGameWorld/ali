//! 本地向量近似最近邻（HNSW）。
//!
//! 向量在写入 [`crate::embedding::EmbeddingStore`] 时已 L2 归一化，
//! 因此使用 `DistDot`（点积距离）代替完整余弦，搜索更快。
//!
//! 索引不落盘，在首次检索或向量变更后惰性重建。

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use hnsw_rs::prelude::*;

use crate::embedding::lock_or_recover;

/// 进程内缓存的 HNSW 图 + id 映射。
pub struct VectorAnnIndex {
    hnsw: Hnsw<'static, f32, DistDot>,
    /// HNSW 点 id (usize) → chunk / memory 键
    ids: Vec<String>,
    dimension: usize,
}

/// 与 [`EmbeddingStore`] 绑定的惰性 HNSW 缓存。
#[derive(Default)]
pub struct AnnCache {
    generation: u64,
    inner: Mutex<AnnCacheInner>,
}

#[derive(Default)]
struct AnnCacheInner {
    built_for_generation: u64,
    index: Option<Arc<VectorAnnIndex>>,
}

impl AnnCache {
    pub fn invalidate(&mut self) {
        self.generation = self.generation.wrapping_add(1);
    }

    #[allow(dead_code)]
    pub fn get_or_build(
        &self,
        vectors: &HashMap<String, Vec<f32>>,
    ) -> Option<Arc<VectorAnnIndex>> {
        self.get_or_build_filtered(vectors, |_| true)
    }

    /// 按 `keep` 过滤后建图；缓存命中时不分配过滤副本。
    pub fn get_or_build_filtered<F>(
        &self,
        vectors: &HashMap<String, Vec<f32>>,
        mut keep: F,
    ) -> Option<Arc<VectorAnnIndex>>
    where
        F: FnMut(&str) -> bool,
    {
        if vectors.is_empty() {
            return None;
        }
        let mut guard = lock_or_recover(&self.inner);
        if guard.built_for_generation == self.generation {
            if let Some(index) = guard.index.clone() {
                return Some(index);
            }
        }
        let filtered: HashMap<String, Vec<f32>> = vectors
            .iter()
            .filter(|(k, _)| keep(k.as_str()))
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        if filtered.is_empty() {
            return None;
        }
        // DistDot 断言失败会 unwind；catch 后返回 None，上层回退暴力扫描。
        let index = match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            VectorAnnIndex::build(&filtered)
        })) {
            Ok(Some(idx)) => Arc::new(idx),
            Ok(None) => return None,
            Err(_) => {
                tracing::warn!("HNSW build panicked (DistDot?); falling back to brute search");
                return None;
            }
        };
        guard.built_for_generation = self.generation;
        guard.index = Some(index.clone());
        Some(index)
    }
}

impl VectorAnnIndex {
    /// 从向量表全量构建 HNSW（增量删除在 hnsw_rs 中不便，采用重建）。
    pub fn build(vectors: &HashMap<String, Vec<f32>>) -> Option<Self> {
        if vectors.is_empty() {
            return None;
        }
        let dimension = vectors.values().next()?.len();
        if dimension == 0 {
            return None;
        }

        let mut ids = Vec::with_capacity(vectors.len());
        let mut data: Vec<(&[f32], usize)> = Vec::with_capacity(vectors.len());
        for (id, vector) in vectors {
            if vector.len() != dimension {
                continue;
            }
            let point_id = ids.len();
            ids.push(id.clone());
            data.push((vector.as_slice(), point_id));
        }
        if ids.is_empty() {
            return None;
        }

        let nb_elem = ids.len();
        let max_nb_connection = hnsw_m();
        let nb_layer = 16.min((nb_elem as f32).ln().max(1.0).trunc() as usize);
        let ef_c = hnsw_ef_construct();

        let hnsw = Hnsw::new(max_nb_connection, nb_elem, nb_layer, ef_c, DistDot {});
        if nb_elem >= 32 {
            hnsw.parallel_insert_slice(&data);
        } else {
            for (slice, point_id) in &data {
                hnsw.insert((*slice, *point_id));
            }
        }

        Some(Self {
            hnsw,
            ids,
            dimension,
        })
    }

    pub fn dimension(&self) -> usize {
        self.dimension
    }

    /// 全库 Top-K（相似度降序）。
    pub fn search(&self, query: &[f32], limit: usize) -> Vec<(String, f32)> {
        if query.len() != self.dimension || limit == 0 {
            return Vec::new();
        }
        let knbn = limit.max(1).min(self.ids.len());
        let ef = hnsw_ef_search().max(knbn);
        let neighbours = match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            self.hnsw.search(query, knbn, ef)
        })) {
            Ok(n) => n,
            Err(_) => {
                tracing::warn!("HNSW search panicked (DistDot?); returning empty for fallback");
                return Vec::new();
            }
        };
        neighbours
            .into_iter()
            .filter_map(|n| {
                self.ids
                    .get(n.d_id)
                    .map(|id| (id.clone(), dist_to_similarity(n.distance)))
            })
            .collect()
    }

    /// 仅在 `chunk_id` 以任一 `prefix` 开头时保留（hybrid 候选文件过滤）。
    pub fn search_with_prefixes(
        &self,
        query: &[f32],
        prefixes: &[String],
        limit: usize,
    ) -> Vec<(String, f32)> {
        if prefixes.is_empty() || limit == 0 {
            return Vec::new();
        }
        let fetch = (limit.saturating_mul(8)).max(limit).min(self.ids.len());
        let ef = hnsw_ef_search().max(fetch);
        let neighbours = match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            self.hnsw.search(query, fetch, ef)
        })) {
            Ok(n) => n,
            Err(_) => return Vec::new(),
        };
        let mut hits: Vec<(String, f32)> = neighbours
            .into_iter()
            .filter_map(|n| {
                let id = self.ids.get(n.d_id)?;
                prefixes
                    .iter()
                    .any(|p| crate::chunk_matches_file(id, p))
                    .then(|| (id.clone(), dist_to_similarity(n.distance)))
            })
            .collect();
        hits.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        hits.truncate(limit);
        hits
    }

    /// 仅 `memory:` 前缀键，返回解析后的记忆 id。
    pub fn search_memory(&self, query: &[f32], limit: usize) -> Vec<(i64, f32)> {
        if limit == 0 {
            return Vec::new();
        }
        let fetch = (limit.saturating_mul(8)).max(limit).min(self.ids.len());
        let ef = hnsw_ef_search().max(fetch);
        let neighbours = match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            self.hnsw.search(query, fetch, ef)
        })) {
            Ok(n) => n,
            Err(_) => return Vec::new(),
        };
        let mut hits: Vec<(i64, f32)> = neighbours
            .into_iter()
            .filter_map(|n| {
                let key = self.ids.get(n.d_id)?;
                let id_str = key.strip_prefix("memory:")?;
                let id: i64 = id_str.parse().ok()?;
                Some((id, dist_to_similarity(n.distance)))
            })
            .collect();
        hits.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        hits.truncate(limit);
        hits
    }
}

/// DistDot 返回 `1 - dot`（归一化向量下 dot 即余弦相似度）。
fn dist_to_similarity(dist: f32) -> f32 {
    1.0 - dist
}

fn hnsw_enabled() -> bool {
    match std::env::var("ALI_HNSW_ENABLED") {
        Ok(v) => !matches!(v.as_str(), "0" | "false" | "FALSE" | "no" | "NO"),
        Err(_) => true,
    }
}

fn hnsw_min_vectors() -> usize {
    std::env::var("ALI_HNSW_MIN_VECTORS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(128)
        .max(16)
}

fn hnsw_m() -> usize {
    std::env::var("ALI_HNSW_M")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(16)
        .clamp(4, 64)
}

fn hnsw_ef_construct() -> usize {
    std::env::var("ALI_HNSW_EF_CONSTRUCT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(200)
        .clamp(32, 800)
}

fn hnsw_ef_search() -> usize {
    std::env::var("ALI_HNSW_EF_SEARCH")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(64)
        .clamp(16, 512)
}

/// 是否应对当前规模启用 HNSW（否则走暴力点积）。
pub fn should_use_hnsw(vector_count: usize) -> bool {
    hnsw_enabled() && vector_count >= hnsw_min_vectors()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unit(v: &[f32]) -> Vec<f32> {
        let mut out = v.to_vec();
        let norm: f32 = out.iter().map(|x| x * x).sum::<f32>().sqrt();
        if norm > 0.0 {
            for x in &mut out {
                *x /= norm;
            }
        }
        out
    }

    #[test]
    fn hnsw_finds_nearest_neighbor() {
        let mut vectors = HashMap::new();
        vectors.insert("a".to_string(), unit(&[1.0, 0.0, 0.0]));
        vectors.insert("b".to_string(), unit(&[0.0, 1.0, 0.0]));
        vectors.insert("c".to_string(), unit(&[0.9, 0.1, 0.0]));
        let index = VectorAnnIndex::build(&vectors).expect("index");
        let q = unit(&[1.0, 0.0, 0.0]);
        let hits = index.search(&q, 2);
        assert!(!hits.is_empty());
        assert_eq!(hits[0].0, "a");
        assert!(hits[0].1 > 0.99);
    }

    #[test]
    fn hnsw_memory_prefix_filter() {
        let mut vectors = HashMap::new();
        vectors.insert("memory:1".to_string(), unit(&[1.0, 0.0]));
        vectors.insert("memory:2".to_string(), unit(&[0.0, 1.0]));
        vectors.insert("chunk:x".to_string(), unit(&[1.0, 0.0]));
        let index = VectorAnnIndex::build(&vectors).expect("index");
        let hits = index.search_memory(&unit(&[1.0, 0.0]), 1);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].0, 1);
        assert!(hits[0].1 > 0.99);
    }

    #[test]
    fn hnsw_memory_only_index_not_diluted_by_code() {
        // 大量 code 向量 + 少量 memory：独立 memory 图仍应命中 memory:1。
        let mut vectors = HashMap::new();
        for i in 0..64 {
            vectors.insert(format!("chunk:{i}"), unit(&[0.0, 1.0]));
        }
        vectors.insert("memory:1".to_string(), unit(&[1.0, 0.0]));
        vectors.insert("memory:2".to_string(), unit(&[0.0, 1.0]));
        let mem: HashMap<_, _> = vectors
            .iter()
            .filter(|(k, _)| k.starts_with("memory:"))
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        let index = VectorAnnIndex::build(&mem).expect("memory index");
        let hits = index.search_memory(&unit(&[1.0, 0.0]), 1);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].0, 1);
        assert!(hits[0].1 > 0.99);
    }
}
