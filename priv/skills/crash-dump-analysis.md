---
name: crash-dump-analysis
triggers: ["erl_crash.dump", "crash dump", "崩溃转储", "OOM", "out of memory", "进程暴涨", "死锁"]
tools: [readFile, runMfa, getProcesses, processInfo, getRuntime]
---

## 技能：Erlang 崩溃转储分析

当用户提到 `erl_crash.dump` 或线上崩溃时，按以下流程定位根因。

### 工作流

1. **定位 dump 文件**：默认 `erl_crash.dump` 在工作目录；用 `readFile` 读取头部（前 200 行）。
2. **解析关键字段**：
   - `slogan:` — 崩溃原因（OOM / `no_more_memory` / `overloaded` / `send` 超时）
   - `num_processes:` / `num_atoms:` / `num_ets:` — 是否异常暴涨
   - `memory:` 段 — 各区内存分布
3. **按 slogan 分类**：
   - `no_more_memory` → 查最大进程 + ETS 表
   - `overloaded` → 查消息队列堆积
   - `send` → 查死锁 / 环形依赖
4. **深入进程段**：找 `stack` 最深 / `message_queue_len` 最大 / `heap_size` 最大的进程；若节点仍存活，可辅以 `getProcesses` / `processInfo` / `getRuntime`。
5. **给出结论**：根因 + 证据 + 修复建议。

### 关键字段速查

```
slogan: <崩溃原因>
num_processes: <进程数>
num_atoms: <原子数>
num_ets: <ETS 表数>

=memory
total: <字节>
processes: <字节>
atom: <字节>
binary: <字节>
ets: <字节>

=proc:<pid>
State: <状态>
Message queue length: <队列长度>
Heap size: <字>
Stack+heap: <字>
 reductions: <归约数>
Current stack trace:
  <MFA 列表>
```

### 常见根因模式

| slogan | 典型根因 | 排查方向 |
|--------|---------|---------|
| `no_more_memory` | 二进制/ETS 堆积 | 找 `heap_size` 最大进程 + `binary` 内存 |
| `overloaded` | 消息队列暴涨 | 找 `message_queue_len` 最大进程 |
| `send` 超时 | 死锁/环形等待 | 查 `Current stack trace` 中的 `gen:call` |
| `init terminating` | 启动失败 | 查 `init` 段 + `crash` 原因 |

### 检查清单

- [ ] 已读取 slogan 并分类
- [ ] 已检查 `num_processes` / `num_atoms` 是否异常
- [ ] 已定位 Top 3 进程（按 heap / queue / reductions）
- [ ] 已给出根因假设 + 证据
- [ ] 已给出修复建议（限流/拆分/加 supervisor 等）
