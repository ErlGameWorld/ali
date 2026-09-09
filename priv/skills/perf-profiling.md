---
name: perf-profiling
triggers: ["性能分析", "profiling", "eprof", "fprof", "recon", "热点", "hotspot", "性能瓶颈", "CPU 高", "慢"]
tools: [runMfa, getProcesses, getRuntime, processInfo]
---

## 技能：性能热点定位

当用户报告「慢」「CPU 高」「响应延迟」时，按以下流程定位热点。

### 工作流

1. **现状快照**：`getProcesses(sortBy=reductions)` 找 CPU 消耗最大的进程；`getRuntime` 看调度器利用率。
2. **选择工具**：
   - **`eprof`**：快速找哪个函数最耗时（适合短时定位）
   - **`fprof`**：全量调用图 + 累计耗时（适合深度分析）
   - **`recon`**（如可用）：轻量级，`recon:proc_count/2` / `recon:info/1`
3. **采样**：对目标进程/模块跑 5-30 秒采样（可用 `runMfa` 驱动 eprof/fprof API）。
4. **分析结果**：按 `acc` / `own` 时间排序找 Top 函数；必要时 `processInfo` 深入单进程。
5. **给结论**：热点函数 + 优化建议。

### eprof 工作流

```erlang
%% 1. 启动 eprof
eprof:start().

%% 2. 跟踪目标进程（或一组）
eprof:profile([PidOrRegName]).

%% 3. 跑 5-30 秒后停止
timer:sleep(10000),
eprof:stop_profiling().

%% 4. 看结果（按 own time 排序）
eprof:analyze(total).  %% 或 procs 看每进程
```

### fprof 工作流

```erlang
%% 1. 采样（会写临时文件）
fprof:apply(M, F, A).

%% 2. 分析
fprof:profile().

%% 3. 输出（按 acc 排序）
fprof:analyse([{dest, "fprof.analysis"}, {sort, acc}]).
```

### 常见热点模式

| 现象 | 可能根因 | 优化方向 |
|------|---------|---------|
| `lists:reverse/1` 占比高 | 频繁 list 构建 | 考虑用 iolist 或 binary |
| `ets:lookup/2` 占比高 | 频繁查表 | 加缓存或 `{set, keypos}` |
| `binary:match/2` 占比高 | 频繁字符串扫描 | 编译正则或改用 binary pattern |
| `gen_server:call/3` 占比高 | 同步调用堆积 | 改 `cast` 或加并发 |
| `code:ensure_loaded/1` | 每次调用都查模块 | 模块加载前置 |
| GC 占比高 | 频繁创建大 term | `erlang:hibernate/3` 或调 `fullsweep_after` |

### 检查清单

- [ ] 已用 `getProcesses` 定位目标进程
- [ ] 已选择合适的 profiling 工具
- [ ] 采样时长合理（5-30 秒）
- [ ] 已按耗时排序找 Top 3 函数
- [ ] 已给出优化建议（含预期收益）
