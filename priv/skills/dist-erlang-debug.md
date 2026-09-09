---
name: dist-erlang-debug
triggers: ["分布式", "distributed", "net_kernel", "epmd", "节点互联", "node connect", "分布式 erlang", "dist port"]
tools: [getRuntime, runMfa, getSymbolSource, searchText, processInfo]
---

## 技能：分布式 Erlang 调试

当用户遇到节点互联、`net_kernel`、`epmd` 问题时，按以下流程。

### 工作流

1. **节点信息**：`getRuntime` 获取当前节点运行时快照；用 `runMfa` 查 `node()` / `erlang:get_cookie/0` / dist 相关信息。
2. **连通性检查**：
   - `net_adm:ping/1` 测试目标节点
   - `erlang:nodes/0` 看已连接节点
   - `net_kernel:connect/1` 显式连接
3. **epmd 检查**：`runMfa` 跑 `erl_epmd:names/1` 看注册的节点。
4. **cookie 检查**：确认两端 cookie 一致（`erlang:get_cookie/0`）。
5. **防火墙/端口**：确认 dist 端口（默认动态，可固定 `inet_dist_listen_min/max`）。
6. **给结论**：故障点 + 修复建议。

### 常见故障

| 现象 | 可能原因 | 排查 |
|------|---------|------|
| `net_adm:ping` 返回 `pang` | cookie 不一致 / 防火墙 / epmd 未启动 | 查 cookie + `epmd -names` |
| 节点连接后立即断开 | TLS 配置不匹配 / 版本不兼容 | 查 `net_kernel` 日志 |
| `distributed_erlang` 启动失败 | 节点名格式错 / 端口被占 | 查 `-sname` vs `-name` |
| `global` 注册名冲突 | 两节点同名注册 | `global:registered_names/0` |
| 消息丢失 | 接收方 `receive` 不匹配 | `processInfo` 查队列 |

### 诊断命令速查

```erlang
%% 节点信息
node().                    %% 当前节点名
erlang:get_cookie().       %% 当前 cookie
nodes().                   %% 已连接节点
nodes(connected).          %% 已连接（含 hidden）

%% epmd
erl_epmd:names({127,0,0,1}).  %% 本地注册的节点

%% 连通性
net_adm:ping('node@host').    %% pong = 通, pang = 不通

%% 分布式监控
net_kernel:monitor_nodes(true).  %% 订阅 nodeup/nodedown
erlang:monitor_node(Node, true).

%% global
global:registered_names().
global:whereis_name(Name).
```

### 检查清单

- [ ] 已确认节点名格式（`sname` 短名 / `name` 长名）
- [ ] 已确认 cookie 一致
- [ ] 已确认 epmd 运行 + 端口可达
- [ ] 已确认防火墙放行 dist 端口
- [ ] 已用 `net_adm:ping` 验证连通性
