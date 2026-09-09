---
name: mnesia-ets-schema
triggers: ["mnesia", "ets", "表设计", "table schema", "表迁移", "mnesia 迁移", "ets 索引", "fragment"]
tools: [runMfa, getEts, etsLookup, writeFile, getSymbolSource]
---

## 技能：Mnesia/ETS 表设计

当用户要求设计表、迁移表结构或排查表性能时，按以下流程。

### 工作流

1. **明确需求**：读写比例、数据量级、一致性要求、持久化需求。
2. **选型**：ETS vs Mnesia（见下方决策表）。
3. **设计 schema**：keypos、索引、存储类型。
4. **生成代码**：`writeFile` 写建表/迁移模块。
5. **验证**：`getEts` / `etsLookup` 确认表创建成功；必要时用 `runMfa` 执行建表/查询。

### ETS vs Mnesia 决策

| 维度 | ETS | Mnesia |
|------|-----|--------|
| 分布式 | 单节点 | 多节点复制 |
| 事务 | 无（或 `ets:select` 原子） | 有（`mnesia:transaction`） |
| 持久化 | `ram_copies` / `disk_copies` | `ram_copies` / `disc_copies` / `disc_only_copies` |
| 查询 | `match` / `select` | QLC / `match` / `select` |
| 性能 | 高（单节点） | 中（复制开销） |
| 适用 | 缓存、会话、索引 | 分布式状态、需事务 |

### ETS 表设计

```erlang
%% 建表
ets:new(my_table, [
    set,                    %% set | ordered_set | bag | duplicate_bag
    public,                 %% public | protected | private
    named_table,
    {keypos, 2},            %% 默认 #1
    {read_concurrency, true},   %% 读多写少时开启
    {write_concurrency, true},  %% 写并发时开启
    {heir, HeirPid}         %% 可选：表主挂了继承
]).

%% 索引（ETS 无原生索引，用 bag 表或手动维护）
%% 大表分片：ets:new(my_table_frag, [set, public, {keypos, 2}])
```

### Mnesia 表设计

```erlang
%% 建表
mnesia:create_table(my_table, [
    {attributes, record_info(fields, my_record)},
    {type, set},                    %% set | ordered_set | bag
    {ram_copies, [node()]},         %% 或 disc_copies / disc_only_copies
    {index, [field2]},              %% 二级索引
    {frag_properties, [             %% 分片（大数据量）
        {n_fragments, 4},
        {n_disc_copies, 1}
    ]}
]).

%% 迁移：改 record 结构
mnesia:transform_table(my_table, fun(Old) ->
    %% Old = {my_record, K, F1, F2}
    %% New = {my_record, K, F1, F2, F3_default}
    setelement(size(Old) + 1, Old, default_value)
end, record_info(fields, my_record), my_record).
```

### 常见问题

| 问题 | 根因 | 修复 |
|------|------|------|
| ETS 表主挂了表消失 | 未设 `{heir, _}` | 设 heir 或用 supervisor 持有 |
| Mnesia 写慢 | 事务粒度太大 | 批量 `dirty_write` 或 `async_dirty` |
| Mnesia 脑裂 | 网络分区 | 配 `auto_failover` 或手动处理 |
| ETS 内存暴涨 | 只写不删 | 加 TTL 清理或 `ets:select_delete` |
| Mnesia 表锁竞争 | `{sticky, true}` 缺失 | 写多的表设 sticky |

### 检查清单

- [ ] 已明确读写比例与数据量
- [ ] 选型合理（ETS vs Mnesia）
- [ ] keypos 正确
- [ ] 二级索引按查询模式设计
- [ ] 持久化策略匹配业务
- [ ] 大表已考虑分片
