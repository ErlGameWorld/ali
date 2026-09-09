//! Micro-benchmarks for hot pure helpers (hash / path / cosine).
//! Algorithms mirror aliCore `stable_hash` / path keys / embedding cosine.
//!
//! 注意（任务 #22）：本 bench 是手写算法副本，与生产代码 main.rs/embedding.rs 的实现
//! 存在漂移风险（生产路径已优化：cosine_similarity 在已归一化向量上走点积短路、
//! path 规范化按平台条件小写）。要把 bench 接到真实生产代码需将 main.rs 拆为 lib.rs
//! 暴露纯函数 —— 该重构标注延期（见主任务清单 #22）。当前仅做相对趋势对比。
//!
//! Run: `cargo bench --bench core_micro --manifest-path c_src/aliCore/Cargo.toml`

use criterion::{black_box, criterion_group, criterion_main, Criterion};

fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf29ce484222325;
    for b in bytes {
        hash ^= u64::from(*b);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

fn normalize_path_key_rel(rel: &str) -> String {
    let mut s = rel.replace('\\', "/");
    if let Some(rest) = s.strip_prefix("./") {
        s = rest.to_string();
    }
    s.to_ascii_lowercase()
}

fn cosine_similarity(a: &[f32], b: &[f32]) -> f32 {
    let mut dot = 0.0f32;
    let mut na = 0.0f32;
    let mut nb = 0.0f32;
    for (x, y) in a.iter().zip(b.iter()) {
        dot += x * y;
        na += x * x;
        nb += y * y;
    }
    if na == 0.0 || nb == 0.0 {
        0.0
    } else {
        dot / (na.sqrt() * nb.sqrt())
    }
}

fn bench_fnv(c: &mut Criterion) {
    let payload = "src/agent/alServer.erl::ask/2".repeat(32);
    c.bench_function("fnv1a64_1kib", |b| {
        b.iter(|| fnv1a64(black_box(payload.as_bytes())))
    });
}

fn bench_path(c: &mut Criterion) {
    let samples = [
        r"src\agent\alServer.erl",
        "./src/tools/alToolRouter.erl",
        "SRC/Agent/AlConfig.erl",
    ];
    c.bench_function("normalize_path_key_rel", |b| {
        b.iter(|| {
            for s in &samples {
                black_box(normalize_path_key_rel(s));
            }
        })
    });
}

fn bench_cosine(c: &mut Criterion) {
    let a: Vec<f32> = (0..384).map(|i| (i as f32) * 0.01).collect();
    let b: Vec<f32> = (0..384).map(|i| ((i as f32) * 0.007).sin()).collect();
    c.bench_function("cosine_similarity_384", |bch| {
        bch.iter(|| cosine_similarity(black_box(&a), black_box(&b)))
    });
}

criterion_group!(benches, bench_fnv, bench_path, bench_cosine);
criterion_main!(benches);
