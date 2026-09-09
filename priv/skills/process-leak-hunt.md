---
name: process-leak-hunt
triggers: ["进程泄漏", "内存泄漏", "消息队列堆积", "process leak", "memory leak", "message queue", "内存涨", "进程数涨"]
tools: [getRuntime, getProcesses, getEts, processInfo, supervisorTree, runMfa, searchCode]
---

## 技能：进程/内存/消息队列泄漏排查

当用户报告「内存持续增长」「进程数涨」「消息堆积」时，按以下流程定位。

### 工作流

1. **快照现状**：`getRuntime` + `getProcesses`（按 memory / reductions / message_queue_len）。
2. **分类定位**：
   - **进程数泄漏** → 同一 `current_function` 大量重复 → 排查 spawn 源头
   - **内存泄漏** → 单进程 memory 巨大 → 排查 binary/ETS
   - **消息堆积** → `message_queue_len` 大 → 消费者阻塞/退出
3. **查 ETS**：`getEts` 看 size/memory 异常增长。
4. **必要时** `runMfa` 调业务诊断接口（只读）；给结论：类型 + 源头 + 建议。

### 诊断决策树

```
getProcesses(sortBy=memory)
  ├─ 单进程 heap 巨大 → processInfo → 查 binary/ETS 引用
  ├─ 多进程 heap 中等但数量多 → 查 initial_call 重复 → spawn 源头
  └─ 总内存正常但持续涨 → 多次采样对比

getProcesses(sortBy=messageQueueLen)
  ├─ 单进程队列大 → 消费者阻塞 → processInfo 查 current_function
  └─ 多进程队列大 → 全局瓶颈（如 ETS/IO）

getEts
  ├─ 某表 size 持续涨 → 查写入点是否有清理
  └─ 某表 memory 异常大 → 查是否存了大 binary
```

### 常见泄漏模式

| 现象 | 根因 | 修复 |
|------|------|------|
| 进程数持续涨 | `spawn` 未受 supervisor 管控 / `exit` 路径缺失 | 改用 supervisor + `simple_one_for_one` |
| 单进程 heap 涨 | 持有大 binary / list 不释放 | `erlang:garbage_collect/1` + 检查引用 |
| ETS size 涨 | 只写不删 | 加 TTL 清理 / `ets:select_delete` |
| 消息队列涨 | 消费者 `receive` 被阻塞 / `gen_server` handle 太慢 | 拆分 handler / 加 timeout |

### 检查清单

- [ ] 已用 `getProcesses` 拿到 Top N 快照
- [ ] 已对异常进程 `processInfo` 深入
- [ ] 已检查 ETS 表规模（`getEts`）
- [ ] 已区分「泄漏」vs「正常高峰」（多次采样对比）
- [ ] 已给出根因 + 修复建议
