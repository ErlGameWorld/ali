---
name: protocol-message-trace
triggers: ["协议", "推送", "推给", "客户端", "protocol", "push", "client", "send", "packet", "消息", "下发"]
tools: [searchCode, findCallers, getCallees, getSymbolSource, readFile, gotoDef]
---

## 技能：协议消息追踪

当用户询问「这个协议什么时候推给客户端 / 谁触发了这个推送」时：

### 流程

1. **定位协议定义**
   - 从协议号或协议名搜索：`searchCode("协议号 0x123 / 协议名")`
   - 找到 encode/decode 函数，确定协议模块

2. **反向追踪发送点**
   - `findCallers` 找谁调了 `sendToClient` / `sendPacket`（以项目真实发送 API 为准）
   - 沿调用链向上 2-3 跳，找到业务触发点
   - 标记每跳的 `M:F/A` 和触发条件（可用 `getSymbolSource` / `gotoDef` 读源码）

3. **正向追踪触发场景**
   - 列出所有触发该协议的业务场景
   - 给出场景 → 条件 → 协议的完整链路

### 输出格式

```
## 协议 #0x123 (exampleAck)

### 定义
- src/proto/example_proto.erl:42 encodeExampleAck/1

### 发送点
- src/net/session.erl:88 sendToClient/2 ← 直接调用
  ↑ src/example/handler.erl:120 onDone/1 ← 业务完成后
  ↑ src/example/handler.erl:80 handleReq/2 ← 收到请求

### 触发场景
1. 业务完成（onDone/1）
2. 重连后状态同步（onReconnect/1）
```

### 注意

- 引用必须基于真实代码搜索结果，禁止编造调用链。
- 调用链最多 3 跳，避免上下文爆炸。
- 区分客户端→服务端（上行）与服务端→客户端（下行）方向。
