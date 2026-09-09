# aliCore 全面审核报告：大型项目性能与可靠性

> 审核日期：2026-08-06
> 审核范围：`c_src/aliCore/src/*.rs`（main / port / ignore / db / embedding / hnsw_index / qdrant_store / rerank / data_flow，共约 8700 行）+ Erlang 对接层（`alCoreClient.erl`、`alOsProc.erl`、`alGitIndex.erl`、`alFileWatcher.erl`、`alProjectDigest.erl`）+ 配置（`config/aliCfg.cfg`）
> 审核视角：**百万行级 Erlang 大项目**（数万模块、数十万函数、百万级调用边）下，索引构建是否会卡死/失败、查询与内存是否可扩展、实现是否有更优方案。

---

## 0. 总体结论

aliCore 的工程质量整体较高：双缓冲 Tantivy 目录交换、Arc 快照读、CPU 密集任务进 `spawn_blocking`、Qdrant 熔断、embedding 增量与断点保留、HNSW panic 兜底、Mutex 毒化恢复等都已经做了，代码注释里能看到 P0-7/M12 等历史事故的修复痕迹。

但**按"大型项目"尺度衡量，当前实现存在若干会直接导致「建索引卡死 / 假死 / 失败」的结构性问题**，集中在四处：

1. **启动与每次增量索引都要全量重建调用图 / 数据源索引**（O(全项目)）；
2. **embedding 开启时，每次索引无条件深拷贝整个向量库、并以 JSON 文本全量落盘**（大项目 = 数百 MB 内存尖峰 + 秒级~分钟级 IO）；
3. **索引元数据 `state.json` 单文件全量重写**，且旧格式含全文 body（本仓库实测 4.4MB / 122 个 body 字段，与文档声明矛盾）；
4. **Erlang 侧单 gen_server 串行派发 + 索引排队无独立超时 + 后台索引无卡死巡检**，放大了 Rust 侧一切慢操作的体感。

以下按严重度分级列出全部发现，均附 `文件:行号`。

---

## 1. P0 —— 大项目下会导致「索引卡死/失败」级问题

### P0-1　每次文件变更都全量重建调用图与 DataSourceIndex

**位置**：`main.rs:2850`、`main.rs:2873`（`incremental_update_index`）、`main.rs:2688`（全量路径）

`CallGraphIndex::from_documents(&owned)` 与 `DataSourceIndex::from_documents` 的输入是**全部文档**，与本次变更了几个文件无关。大项目（百万级调用边）下：

- 每条边 2 次 `node_key` String 分配 + 2 次 HashMap 查找 + `add_edge`（`main.rs:492-508`）；
- fileWatcher 默认 30 秒扫一次（`alFileWatcher.erl:29`），任何变更 → `indexAsyncRoots` → Tantivy 增量很快，但调用图全量重建要数十秒甚至分钟级，**表现为"索引一直在跑"**。

代码注释（`main.rs:1153-1154`）自己承认这是"大仓二次索引的主要 CPU 假慢来源之一"，但目前的优化只在**零变更**时跳过；只要改了 1 个文件就全量重建。

**更好方案**：
- 调用图按文件做**增量维护**：`by_file` 已记录每文件的 edges，变更时仅删除旧文件的边、插入新文件的边（petgraph 边删除按 edge index 批量处理即可），无需全量重建；
- 或改用字符串驻留（`u32` intern id）+ `(u32, u32, u32)` 边表，全量重建成本先降一个数量级（见 P1-6）。

### P0-2　embedding 开启后，每次索引无条件深拷贝整个向量库

**位置**：`main.rs:1213-1223`

```rust
let (mut store, model_changed, previous_hashes) = {
    let existing_store = Arc::clone(&*state.embeddings.read().await);
    ...
    ((*existing_store).clone(), model_changed, previous_hashes)   // ← 全量深拷贝
};
```

只要 `EmbeddingConfig::from_env()` 为 `Some`，**每次索引（包括 fileWatcher 30 秒一次的无变更轮次）都把 `vectors: HashMap<String, Vec<f32>>` 整体 clone 一份**。5 万 chunk × 1536 维 f32 ≈ 300MB 向量数据，深拷贝 + 双倍驻留，直接制造内存尖峰与数秒级停顿；之后才判断 `embed_noop`（`main.rs:1230`）发现无事可做。无 embedding 但 `stats.removed > 0` 的分支同样克隆（`main.rs:1291-1292`）。

**更好方案**：先做 `chunks_needing_embed` 的"是否有活"探测（只需读 `chunk_hashes`，零拷贝），确认需要 embed 再克隆；或者干脆改 store 为不可变数据结构 + 差量合并（`Arc<EmbeddingStore>` + 本次新增向量的 delta map，最后一次性替换 Arc），彻底消除全量拷贝。

### P0-3　向量库以 JSON 文本全量物化落盘

**位置**：`embedding.rs:707-725`（`persist_store`）

`serde_json::to_string(store)` 先把**整个向量库序列化成一根 JSON 字符串**再写盘。f32 的 JSON 文本约 10-13 字节/维（对比二进制 4 字节），5 万 × 1536 维 ≈ **1GB 级字符串在内存物化**，再加写盘 IO。索引期间每轮 embed 完成都会触发一次（`main.rs:1248`）。

**更好方案**（按收益排序）：
1. 换二进制格式（`bincode` / 自研 header + `f32` 数组裸写），体积降到 ~1/3，序列化快 5-10 倍；
2. 至少改成 `serde_json::to_writer(BufWriter)` 流式写，避免整串物化；
3. 长期方案：向量存进已引入的 SQLite（blob 列）或强制大项目走 Qdrant（见 §4 路线图）。

### P0-4　`state.json` 单文件全量重写 + 旧格式含全文 body

**位置**：`main.rs:2955-2976`（`persist_state`）、`main.rs:2608-2632`（`load_persisted_documents`）

- 每次 `needs_persist()`（任一文件变更）都把**全部文档元数据**重写成一根 JSON。大项目该文件可达数百 MB，30 秒一轮的 fileWatcher 触发后就是稳定的全量重写 IO。
- **实测本仓库 `priv/index/state.json` 4.4MB、含 122 个 `"body"` 字段**（旧版本写入）。`body` 上的 `skip_serializing` 只影响写出；`load_persisted_documents` 反序列化时**仍会把旧 body 全部读进内存**（`main.rs:2617`），且这些带 body 的 cached doc 在 mtime 快路被 clone 进 merged（`main.rs:2056`）——升级后第一轮索引等于把整个语料正文驻留内存。`priv/docs/architecture.md:69` 声称"仅存元数据（不含正文）"，与实际文件不符。

**更好方案**：元数据迁入 SQLite（`db.rs` 已具备 rusqlite/bundled，边际成本低）：`files(file PK, hash, mtime, size, meta_json)` 按行 upsert，增量索引只写变更行；启动加载可分页/懒加载。迁移期一次性把旧 state.json 导入并删除。

### P0-5　启动阻塞加载：Port 就绪前完成全量 JSON 解析 + 全量建图

**位置**：`main.rs:701`（`bootstrap_state` 在 `run_blocking` 之前）、`main.rs:797-815`、`main.rs:2980-3060`

`load_persisted_index` 同步完成：读整份 state.json → 全量反序列化 → `open_index` → 全量建调用图/DataSourceIndex。**这一切发生在 Port 开始读 stdin 之前**。大项目下启动耗时可达分钟级，而 Erlang 侧启动探测只有 3 次 × 300ms 重试（`alCoreClient.erl:872-883`），极易误判 core 启动失败，之后请求走 portClosed → 2 秒重连循环——用户看到的就是"**索引一直不成功**"。

**更好方案**：bootstrap 先起 Port 循环并立即应答 `/health`（报 `warming_up`），索引加载挪到后台任务，`/search` 在加载完成前返回明确的 `index_loading` 错误而非挂起。

### P0-6　mtime 秒级精度 + size 相等即跳过的"竞态干净"误判

**位置**：`main.rs:2047-2060`（快路条件）、`main.rs:2302-2313`（mtime 取秒）

跳过重解析的条件是 `file_size` 相等且 `file_mtime`（**秒级**）相等。代码生成器、`rebar3 compile` 拷贝、脚本批量改写都可能在**同一秒内**产出同尺寸不同内容的文件 → 索引静默漏更新，之后调用图/检索都是旧数据。这是 git 著名的 racy-clean 问题。

**更好方案**：mtime 存纳秒（`duration_since(UNIX_EPOCH).as_nanos()` 已无精度问题）；或对 `mtime >= now-2s` 的"年轻文件"强制走 hash 对比（git 同款处理）。

### P0-7　`Arc::make_mut` 在并发搜索时深拷贝整个 SearchIndex

**位置**：`main.rs:1182-1190`（data_sources 补齐路径）

`Arc::make_mut(idx)` 在 refcount > 1 时**克隆整份 `SearchIndex`**——包括全部 documents、调用图、数据源索引。索引收尾时只要还有一个搜索持 Arc 快照（大项目下搜索本身就被读盘拖慢，见 P1-3，窗口不小），就会触发一次 GB 级深拷贝，表现为索引收尾阶段"卡死"。

**更好方案**：`data_source_index` 字段单独包一层 `Arc`（`Arc<DataSourceIndex>`），替换时只换内层 Arc，不动 SearchIndex 本体。

---

## 2. P1 —— 明显性能瓶颈（大项目可感，但不至于卡死）

### P1-1　忽略规则匹配器的热路径字符串分配

**位置**：`ignore.rs:182-199`（`pattern_matches`）、调用点 `main.rs:2006/2021`

每个 walk 条目 × 每个 pattern 做 3 次 `format!` 分配（`"{pat}/"`、`"/{pat}"`、`"/{pat}/"`）。默认配置 20+ 个 pattern，数万文件 = **百万级临时 String**，扫盘阶段被无谓拖慢。

**方案**：`IgnoreMatcher::load` 时把每个 pattern 预编译为 `{prefix*, *suffix, segment}` 枚举并缓存拼接好的串；或直接引入 `ignore` crate（与 ripgrep 同款 gitignore 语义，顺带解决 `.gitignore` 合并的正确性）。

### P1-2　`module_deps` / 无模块 `get_symbol` 为全表扫描

**位置**：`main.rs:3369-3385`、`main.rs:3341-3345`

- `module_deps` 每次调用遍历**所有文档的所有调用边**（O(百万边)/次），没有 module→edges 反查表；
- `get_symbol` 不带 module 时线性扫全部文档的全部函数（O(数十万函数)/次）。

**方案**：构建期加两张表——`module_deps_map: HashMap<String, Vec<String>>`（或按需惰性构建+缓存）、`by_function: HashMap<(String, usize), SmallVec<doc_idx>>`。两张表都是 O(1) 查询、构建一次 O(n)。

### P1-3　搜索命中路径每 hit 读盘 + 全符号表深拷贝

**位置**：`main.rs:3241-3264`（`hit_from_address`）、`main.rs:3100-3108`（`effective_body`）

hybrid 模式下 `bm25_limit = limit*4`（`main.rs:1429`），每个命中：① `effective_body` 同步 `fs::read_to_string` 读整个文件（未变更文件内存无 body）；② clone 该文件的 functions/exports/records/macros 全量符号。一次搜索 = 最多 80 次文件读 + 80 份符号表拷贝。`snippets` 再对全文逐行小写化扫描（`main.rs:4199-4210`）。

**方案**：① 加一个小容量正文 LRU（如 64 文件上限，`chunks_needing_embed` 与 `trace_data_flow` 同样受益）；② snippet 只取 chunk 行区间而非全文；③ `SearchHit` 中的符号列表改 `Arc<[T]>` 或按需字段，避免无脑 clone。

### P1-4　`memory_search` 在 async 上下文做全量向量扫描

**位置**：`main.rs:1896-1902`

`top_memory_hits`（暴力余弦或触发 HNSW 全量重建）直接在 async fn 里执行，**没有 `spawn_blocking`**——对比向量检索路径 `main.rs:1545` 是有的，明显不一致。记忆量大或触发 HNSW 重建时会卡住 tokio worker，连累所有并发请求（心跳、`/index/status` 轮询都被拖）。

**方案**：一行修复——包进 `tokio::task::spawn_blocking`。

### P1-5　hybrid 候选扫描的复杂度与召回缺陷

**位置**：`embedding.rs:412-431`（`brute_top_hits_for_files`）、`hnsw_index.rs:148-178`（`search_with_prefixes`）

- 暴力路径 O(向量数 × 候选文件数) 的前缀字符串比较：5 万向量 × 40 候选文件 = 200 万次 `starts_with`/查询；
- HNSW 路径只取 `limit*8` 条再按文件前缀过滤，候选文件若在全局 Top 之外则**召回不足 limit 条**，混合检索结果偏少。

**方案**：向量 store 增加 `file → Vec<chunk_id>` 反查（`by_chunk` 已有半成品），候选扫描直接按文件取向量子集做点积，O(候选 chunk 数)；HNSW 路径对过滤后不足 limit 的情况自动放大 fetch 重试一次。

### P1-6　调用图内存与构建成本：String 键 + petgraph

**位置**：`main.rs:483-518`

节点存 `String`、边存于 `DiGraph<String, u32>`，`node_lookup` 再存一份 String→NodeIndex：每个函数名至少 2-3 份拷贝。百万边规模下常驻内存数百 MB，且构建慢（P0-1 的底层原因）。

**方案**：字符串驻留（`lasso`/`string-interner`），节点/边全部改 u32 id；查询侧 callers/callees 用 CSR 邻接表（构建一次后查询 O(度)），比 petgraph 省一半内存且 cache-friendly。

### P1-7　Erlang 侧单点串行与大响应放大

**位置**：`alCoreClient.erl:966-976`（gen_server 内 `decodeJson`+`normalizeJson`）、`port.rs:196-253`（stdout 全局 Mutex）、`main.rs:1595-1606`（`/call_graph` 无分页全量导出）

- 所有 Port 请求经单个 gen_server 派发，大响应在回调里递归重建 map——`/call_graph` 对大项目返回百万条边（数百 MB JSON），先堵 Rust 的 stdout 全局锁（阻塞所有其它响应写回），再堵 Erlang 单 gen_server；
- Port 请求帧有 64MB 上限（`port.rs:211`），**响应帧无任何上限检查**，二者不对称。

**方案**：`/call_graph`、`/data_sources` 等全量导出接口加分页（cursor/limit）；响应写出前检查大小，超阈值返回 `too_large` 错误而非硬写；Erlang 侧大响应考虑 bypass gen_server（port 直收 + `alias` 回包）。

### P1-8　索引排队请求无独立超时 & 后台索引无卡死巡检

**位置**：`alCoreClient.erl:1145-1184`、`alCoreClient.erl:283-297`、`alChat.erl:556-602`

- 请求在队列里排队时**没有定时器**（timer 在 `startInflight` 才创建），index 桶上限=1，前一个索引跑多久，后面的调用方就等满 `CallTimeout`（indexTimeout 默认 600s + 5s）；
- `ensureIndex` 的 stuck 判定（indexing=true 且 files=0 且 walk=0）只在被调用时检查一次；后台路径（fileWatcher/indexAsync）卡住时**没有任何定时巡检**，只有 CLI 的 2s 轮询会发现；
- 重连固定 2s 无退避（`alCoreClient.erl:1004-1007`），`restart()` 一刀切杀全部 inflight（`alCoreClient.erl:235,826-855`）。

**方案**：入队即挂 per-request 定时器（排队超时也计费）；把 stuck 检测做成 `alCoreClient` 内的周期自检（如 60s 一次，`walk_seen` 连续 N 轮不动 → cancel → 重建）；重连加指数退避（2s→30s 封顶）。

---

## 3. P2 —— 正确性/健壮性/可维护性问题（小但值得修）

| # | 位置 | 问题 | 建议 |
|---|------|------|------|
| P2-1 | `main.rs:2047` | 扫盘时每个文件额外 `fs::metadata` 一次；`walkdir` 的 `DirEntry::metadata()` 在 Windows 上免费 | 用 entry 自带 metadata |
| P2-2 | `main.rs:2700,2806` | Tantivy writer 固定 16MB heap、未显式指定写线程数 | 大项目全量重建用 `writer_with_num_threads` + 按内存预算调 heap（64-128MB） |
| P2-3 | `main.rs:3203` | `file` 字段是 STRING（raw、不分词）却进了 `QueryParser` 字段列表，按文件名检索基本失效 | file 字段改 TEXT 或单独建 `filename` TEXT 字段 |
| P2-4 | `main.rs:1923-1926` | `memory_delete` 中 `chunk_hashes.remove(&key)` 重复执行两次 | 删一处 |
| P2-5 | `qdrant_store.rs:181` | `upsert_chunks` 返回 `vectors.len()` 而非实际 push 的 `points.len()`，计数虚高 | 返回 `points.len()` |
| P2-6 | `embedding.rs:102-104` | 空查询文本绕过缓存直连 embedding API | 空查询直接返回错误或缓存 |
| P2-7 | `main.rs:310-329`（embedding.rs） | embed 取消只在批开始前检查，`.collect()` 会等所有在途批次完成，取消延迟最长可达并发×批耗时 | `buffer_unordered` 改 `take_while` 或在流内检查 cancel |
| P2-8 | `db.rs:91-133` | 单连接 Mutex 串行化全部 SQL（read 也串行）；未设 `PRAGMA busy_timeout`；查询结果无行数上限 | read 路径开只读连接池（WAL 天然支持多读）；加 `busy_timeout=5000`；`rows` 加 LIMIT 兜底或截断告警 |
| P2-9 | `main.rs:2160-2171` | removed 判定时对每个未见到文件 `canonicalize`（`path_under_root` 内 `main.rs:2934`），Windows 上次级 syscall ×N | 用已规范化的 key 直接做前缀比较，canonicalize 只对 root 做一次（已做） |
| P2-10 | `alProjectDigest.erl:267-293` | Digest 构建对最多 400 个模块**串行** `moduleSymbols` port 往返（每次最坏 30s），fileWatcher 每次变更都触发（`alFileWatcher.erl:117-121`） | 批量接口 `/module_symbols_batch`（一次请求多模块），或 digest 改增量 |
| P2-11 | `alGitIndex.erl:147` | "增量索引"语义误导：Rust 侧仍是全仓 re-walk（靠 hash 跳过解析） | 文档写清，或传入 changed 文件列表走精确更新 |
| P2-12 | `config/aliCfg.cfg:113` | **明文 LLM apiKey 提交在仓库里**，与上方注释"切勿把明文 key 提交到仓库"自相矛盾 | 立即轮换该 key 并改 `${ENV:ALI_LLM_API_KEY}` 占位 |
| P2-13 | `data_flow.rs:78`（DataSourceIndex 构建） | `call.clone()` 使数据源调用点与 `doc.data_sources` 双份驻留内存 | entries 存 `(doc_idx, call_idx)` 轻量引用 |
| P2-14 | `data_flow.rs:809`（trace_data_flow） | 每个 caller `effective_body` 读盘一次 + `analyze_param_sources` 无缓存重复切行 | 与 P1-3 的正文 LRU 合并解决；param 分析结果按 `(m,f,a)` 缓存 |
| P2-15 | `main.rs:4154-4176` | `purge_stale_code_vectors` 每次索引全量克隆所有 chunk id 建 HashSet | 用 `&str` 引用建集（`HashSet<&str>`），零分配 |
| P2-16 | `main.rs:2653-2750` | 全量重建路径 `documents.to_vec()` + hydrate + `slim_documents_from_slice` 再克隆，峰值约 3× 语料 | hydrate 就地改 `Arc<Mutex<Vec>>` 或分块流式写入 Tantivy（tantivy 支持多线程 add_document） |

---

## 4. 「索引卡死 / 不成功」根因速查表

用户侧体感 → 最可能的根因：

| 体感 | 根因 | 条目 |
|------|------|------|
| 第一次启动/重启后长时间"索引不成功" | 启动阻塞加载 state.json + 全量建图，Port 未就绪被 Erlang 误判失败 | P0-5 |
| 改了一个文件后"索引一直跑不完" | 1 个文件变更触发全量调用图重建 | P0-1 |
| 开了 embedding 后索引越来越慢、内存爆 | 每轮全量克隆向量库 + JSON 物化落盘 | P0-2 / P0-3 |
| 索引进度 walk_seen 不动、像卡死 | 忽略匹配器分配风暴 + 串行 stat 拖慢扫盘；或大目录没进 ignore | P1-1 / P2-1 |
| 改了代码但搜索结果还是旧的 | mtime 秒级 + 同尺寸误判未变 | P0-6 |
| 索引收尾阶段突然卡顿数秒 | `Arc::make_mut` 撞上并发搜索，整索引深拷贝 | P0-7 |
| 索引请求 600s 超时返回失败 | 排队中的请求无独立超时，被前一个索引堵住 | P1-8 |
| 后台索引悄悄死了没人知道 | 无周期巡检，stuck 检测只在手动 ensureIndex 时做 | P1-8 |
| `/call_graph` 一调整个 core 无响应 | 全量导出 + stdout 全局锁 + Erlang 单 gen_server | P1-7 |
| embedding 模型切换后全量重 embed 中途失败 | 已有回滚保护（`embedding.rs:374-385`），但首批失败要等 2 次退避 | 已缓解 |

---

## 5. 改进路线图建议

**短期（1-2 天，纯代码小改）**
1. P0-2：embed 探测前置，无活不克隆向量库；
2. P1-4：`memory_search` 包 `spawn_blocking`；
3. P0-6：mtime 纳秒化 + 年轻文件强制 hash；
4. P1-1：忽略 pattern 预编译；
5. P0-7：`data_source_index` 独立 Arc；
6. P2-4 / P2-5 / P2-6 / P2-12 顺手修掉（P2-12 最优先：key 已泄露）。

**中期（约 1 周，结构性优化）**
7. P0-3 + P0-4：state.json 与 embeddings.json 统一迁入 SQLite（WAL、按行 upsert、向量 blob 存储）——一次性解决全量重写、JSON 物化、启动解析慢三个问题；
8. P0-1：调用图按文件增量维护 + 字符串驻留（P1-6 合并做）；
9. P0-5：bootstrap 异步化，Port 先就绪、索引后台 warm-up；
10. P1-2：`by_function` / `module_deps_map` 两张反查表；
11. P1-7：全量导出接口分页 + 响应大小上限；Erlang 排队超时与周期 stuck 巡检（P1-8）。

**长期（架构级，按需）**
12. 大项目强制 Qdrant 路径，本地 embeddings.json/HNSW 仅作小项目降级（本地 HNSW 全量重建 + 内存驻留天然不适合 10 万+ 向量）；
13. 索引器拆成「扫盘 → 解析 → 写索引」流水线（channel 连接），扫盘与解析重叠执行，消除阶段 1/阶段 2 之间的全量等待（`main.rs:2012-2113` 当前是先全扫完再统一解析）；
14. 多 codeRoots 共用一份全局索引时，按 root 分段持久化，单 root 变更不碰其它 root 的元数据。

---

## 6. 附：已做得好的地方（保持）

- Tantivy 双目录 staging/prev 交换与 Windows rename 兜底（`main.rs:2682-2729`）；
- `incremental_update_index` 的 delete+add 增量写与"state 空而 tantivy 非空强制全量"护栏（P0-7 修复痕迹，`main.rs:2789-2801`）；
- 读路径 Arc 快照后立刻放锁、HTTP await 不持锁（`main.rs:1211-1212` 注释与实现一致）；
- embedding 增量：批次乱序并发、按序落库、失败保留前缀、模型切换回滚（`embedding.rs:243-388`）；
- Qdrant 熔断 + 懒连接 + 探活（`main.rs:86-112, 837-869`）；
- HNSW `catch_unwind` 防 DistDot 断言杀进程、L2 归一化二次钳制（`hnsw_index.rs:55-64`、`embedding.rs:591-606`）；
- Port 帧 64MB 上限 + 超大帧排空保帧同步（`port.rs:211-229, 317-325`）。

---

*审核方法：Rust 侧 9 个源文件全部逐行通读；Erlang 侧 6 个对接模块全文审查；配置与持久化产物（`priv/index/state.json`）实测验证。所有结论均可在上述行号复核。*

---

## 7. 修复状态（2026-08-06 更新）

### 已修复（本轮代码已改，含 cargo 验证）

> 验证结果（2026-08-06）：`cargo check` 零错误零警告通过；**41/41 单元测试全部通过**（含重写后的 `call_graph_traversal`、`purge_stale_code_vectors_keeps_memory`、`incremental_index_skips_unchanged_files`、`indexes_and_searches_symbols` 及全部 ignore/db/hnsw 用例）。
> 注：验证在 `C:\...\Temp\aliCore-build` 副本中完成（本机 F: 盘 target 目录存在文件锁定/EDR 干扰）；**生产二进制尚未重编**——`priv/aliCore.exe` 有运行中的实例占用，需停节点后执行 `priv/scripts/build_core.ps1` 再启动。

| 条目 | 修复方式 |
|------|----------|
| P0-1 | 调用图从 petgraph（String 节点 × 2-3 份拷贝）重写为轻量边索引（MFA 键多边映射 + 按文件增量更新 `update_file_edges` + 墓碑压缩），全量重建成本降约一个数量级；petgraph 依赖已从 Cargo.toml 移除 |
| P0-2 | embed 前先做零拷贝探测（`embedding_work_needed` / `has_stale_code_vectors`），无工作不克隆向量库；无 embedding 的 purge 分支同样先探测 |
| P0-3 | `persist_store`/`load_store` 改流式 `to_writer`/`from_reader`，消除 GB 级整串物化（二进制/SQLite 迁移留作长期项） |
| P0-5 | bootstrap 异步化：Port 立即就绪，索引/向量库加载改后台 warm-up（`walk_seen=1` 防 Erlang stuck 误判），期间入队的 /index 由 `finish_index_session` 接续执行 |
| P0-6 | mtime 改纳秒（u64）；mtime 距今 <2s 的「年轻文件」不走 mtime 快路、强制 hash 对比（git racy-clean 同款处理）。旧秒级 state.json 升级后首轮走 hash 精确对比，仅一轮全量读盘 |
| P0-7 | `data_source_index` 刷新改 `Arc::get_mut` 轮询原地更新（2s 窗口），极端长尾才退化为整体替换，不再无脑 `make_mut` 深拷贝 |
| P1-1 | `pattern_matches` 零分配重写（`contains_segment` 字节边界比较），顺带修正中间含 `*` 模式的错误语义 |
| P1-2 | 新增 `by_function` / `module_deps_map` 反查表（构建期一次 O(n)），`get_symbol` 无模块查询与 `module_deps` 从全表扫描变 O(1)~O(命中数) |
| P1-3 | 新增正文磁盘读缓存 `effective_body_cached`（`Arc<str>` + mtime 校验 + 64MB FIFO，`ALI_BODY_CACHE_MB` 可调），搜索命中/embed 拼块/`trace_data_flow` 不再每命中读盘 |
| P1-4 | `memory_search` 本地向量扫描包 `spawn_blocking`，不再卡 tokio worker |
| P2-1 | 扫盘用 walkdir `entry.file_type()/entry.metadata()`，Windows 下免二次 stat |
| P2-2 | Tantivy writer 显式 `writer_with_num_threads`（全量 64MB heap/多线程，增量 16MB；`ALI_TANTIVY_WRITER_THREADS`/`ALI_TANTIVY_WRITER_HEAP` 可调） |
| P2-3 | BM25 QueryParser 去掉不分词的 STRING file 字段（路径文本已在 body 首行，检索能力不降） |
| P2-4 | `memory_delete` 重复的 `chunk_hashes.remove` 已删 |
| P2-5 | Qdrant `upsert_chunks` 返回实际 push 点数 |
| P2-6 | 空文本 embedding 直接报错，不再白打 API |
| P2-7 | embed 批次流改逐条消费 + cancel 即停，取消即时生效（在途 HTTP 随 drop 中断） |
| P2-8 | SQLite 增加 `PRAGMA busy_timeout=5000` |
| P2-9 | removed 判定改规范化 key 字符串前缀比较，去掉每文件 canonicalize |
| P2-14 | `trace_data_flow` 的 caller 正文读取改走 P1-3 缓存 |
| P2-15 | `purge_stale_code_vectors` 改 `HashSet<&str>` 零克隆 |

### 未修复 / 留待后续（按建议优先级）

| 条目 | 原因与建议 |
|------|-----------|
| P0-3/P0-4 完全版 | state.json / embeddings.json 迁 SQLite（按行 upsert、向量 blob）属结构性迁移，需配套迁移工具与回归测试，建议单独立项 |
| P0-1 完全版 | `update_file_edges` 增量接口已就位，但「变更文件集合」尚未从扫盘阶段透传到 SearchIndex 构建层；当前全量重建已大幅变快，接线留待下一轮 |
| P1-5 | 候选文件暴力前缀过滤（HNSW 覆盖 ≥128 向量场景，暴力路径仅小库触发，优先级低） |
| P1-7 | `/call_graph` 等全量导出分页 + 响应大小上限，需联动改 Erlang 协议层，建议与 P1-8 一起做 |
| P1-8 | Erlang 侧排队超时 / 周期 stuck 巡检 / 重连退避：需改 `alCoreClient.erl` gen_server 状态机并跑 EUnit 回归，本轮未动 |
| P2-10 | digest 批量接口 `/module_symbols_batch`：需 Rust+Erlang 双侧改动 |
| P2-11 | alGitIndex 语义文档化 |
| P2-12 | **明文 apiKey 需人工轮换**（key 已进 git 历史，改文件文本不能消除泄露；请轮换后改用 `${ENV:ALI_LLM_API_KEY}` 占位） |
| P2-13 | DataSourceIndex 双份内存改轻量引用（10-50MB 量级，收益有限） |
| P2-16 | 全量重建 3× 语料峰值（改流式 hydrate，收益中等） |
