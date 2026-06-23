# LLM 直连 API（llmCli）

不经 Agent 工具循环，直接向大模型提供商发送 HTTP 请求。适用于简单对话、自定义集成、或在不启动 `alServer` 时单独调用模型。

---

## 推荐使用方式

| 场景 | 推荐 API |
|------|----------|
| 应用对外、统一入口 | **`ali:llmChat/2,3`**、`ali:setLlmConfig/2` 等（见 [API.md](API.md)） |
| Agent 内部、扩展开发 | 直接调用 **`llmCli`** |
| 需要 tool_calls 结构化响应 | `llmCli:chatCompletion/3`（`alLoop` 内部使用） |

`ali` 的 `llm*` 函数是对 `llmCli` 的薄封装，配置均写入 **`ali` 应用环境**。

```erlang
%% 推荐：通过 ali Facade
ali:llmLoadConfig().
ali:llmChat(<<"deepseek-v4-flash">>, [llmCli:userMessage("你好")]).

%% 等价：直接调用 llmCli（内部模块）
llmCli:loadConfig().
llmCli:chat(<<"deepseek-v4-flash">>, [llmCli:userMessage("你好")]).
```

源码：[`src/core/llmCli.erl`](../../src/core/llmCli.erl)

配置加载详见 [CONFIG.md](CONFIG.md)。

---

## 应用生命周期

| 函数 | 说明 |
|------|------|
| `llmCli:start/0` | `application:ensure_all_started(ali)` |
| `llmCli:stop/0` | `application:stop(ali)` |

通常 `rebar3 shell` 已自动启动 `ali` 应用，无需手动调用。

---

## 配置

| 函数 | 说明 |
|------|------|
| `setConfig/2` | 写入 `api_key`、`provider`、`base_url` |
| `getConfig/1` | 读取配置，`{ok, Value}` 或 `undefined` |
| `getConfig/2` | 读取配置，带默认值 |
| `loadConfig/0` | 加载默认 `config.cfg` |
| `loadConfigFromFile/1` | 加载指定配置文件 |
| `loadConfigFromEnv/0` | 从 `LLM_PROVIDER`、`LLM_API_KEY`、`LLM_BASE_URL` 加载 |

### 支持的 provider

| provider | 说明 |
|----------|------|
| `openai` | OpenAI 兼容 API |
| `deepseek` | DeepSeek |
| `anthropic` | Anthropic Claude |
| `custom` | 自定义 `base_url` |

查询预设：`ali:listProviders/0`、`ali:getProvider/1`（或 `llmCliConfig:listProviders/0`）。

---

## 同步聊天

### `chat/2`, `chat/3`

发送消息列表，等待完整文本回复。

```erlang
Messages = [
    llmCli:systemMessage("你是 Erlang 专家"),
    llmCli:userMessage("什么是 gen_server？")
],

case llmCli:chat(<<"deepseek-v4-flash">>, Messages) of
    {ok, Reply} -> io:format("~ts~n", [Reply]);
    {error, missing_api_key} -> io:format("请配置 api_key~n");
    {error, Reason} -> io:format("错误: ~p~n", [Reason])
end.
```

### 请求选项（`chat/3` 第三个参数）

| 选项 | 类型 | 说明 |
|------|------|------|
| `{temperature, float()}` | 0–2 | 随机性 |
| `{max_tokens, integer()}` | ≥0 | 最大生成 token |
| `{top_p, float()}` | 0–1 | 核采样 |
| `{stream, boolean()}` | — | 是否流式（一般用 `chatStream`） |
| `{tools, [map()]}` | — | OpenAI function 定义列表 |
| `{tool_choice, binary() \| atom()}` | — | 如 `<<"auto">>` |

```erlang
Opts = [{temperature, 0.7}, {max_tokens, 500}],
llmCli:chat(<<"gpt-4o-mini">>, Messages, Opts).
```

---

## 流式聊天

### `chatStream/2`, `chatStream/3`

向**调用进程**发送分块消息，函数返回 `ok` 表示流已结束。

```erlang
spawn(fun() ->
    receive
        {stream_chunk, Chunk} when Chunk =/= done ->
            io:format("~ts", [Chunk]),
            loop();
        {stream_chunk, done} ->
            io:format("~n完成~n")
    end,
loop() -> receive ... end
end),

llmCli:chatStream(<<"deepseek-v4-flash">>, [
    llmCli:userMessage("讲一个关于机器人的短故事")
]).
```

### Agent 流式协议（`chatStreamTo/4`）

`alLoop` 使用 `chatStreamTo/4` 向指定进程发送，消息格式：

```erlang
{ali, stream, Chunk}
{ali, streamDone, done}
{ali, streamError, Reason}
{stream_chunk, Chunk}      %% 兼容别名
{stream_chunk, done}
```

`ali:askStream/1` 使用上述协议向调用进程推送。

---

## 聊天补全（含 tool_calls）

### `chatCompletion/2`, `chatCompletion/3`

返回结构化 map，供 Agent 推理循环使用（不仅返回纯文本）。

**文本回答：**

```erlang
{ok, #{type := answer, content := Bin}} = llmCli:chatCompletion(Model, Messages, Opts).
```

**工具调用：**

```erlang
{ok, #{type := tool_calls, calls := Calls, message := ApiMsg}} =
    llmCli:chatCompletion(Model, Messages, [{tools, Tools}, {tool_choice, <<"auto">>} | Opts]).
```

`Calls` 为 OpenAI 格式的 tool_call 列表；`ApiMsg` 为完整 assistant 消息，可追加到会话历史。

---

## 消息构建

| 函数 | 说明 |
|------|------|
| `systemMessage/1` | 系统提示 |
| `userMessage/1` | 用户消息 |
| `assistantMessage/1` | 助手回复 |
| `toolMessage/2` | 工具结果（Id + Content） |
| `assistantToolCallsMessage/1` | 含 tool_calls 的 assistant 消息 |
| `createMessage/2` | 通用 `{role, content}` 构造 |

### message() 类型

```erlang
-type message() :: #{
    role := system | user | assistant | tool,
    content => binary() | string() | null,
    tool_call_id => binary(),    %% role = tool 时
    tool_calls => [map()]        %% role = assistant 时
}.
```

### 多轮对话示例

```erlang
Messages = [
    llmCli:systemMessage("你是编程助手"),
    llmCli:userMessage("Erlang 是什么？"),
    llmCli:assistantMessage("Erlang 是面向并发与容错的函数式语言。"),
    llmCli:userMessage("它有哪些典型应用？")
],
llmCli:chat(<<"deepseek-v4-flash">>, Messages).
```

---

## 会话管理

轻量级内存会话（与 Agent 的 `alSession` 磁盘持久化不同）。

| 函数 | 说明 |
|------|------|
| `createSession/0` | 创建空会话 `#{messages => [], created_at => Ts}` |
| `addToSession/2` | 追加消息 |
| `chatWithSession/2,3` | 带历史聊天，自动追加 assistant 回复 |
| `clearSession/1` | 清空消息列表 |

```erlang
S0 = llmCli:createSession(),
S1 = llmCli:addToSession(S0, llmCli:userMessage("你好")),
{ok, Reply, S2} = llmCli:chatWithSession(S1, <<"deepseek-v4-flash">>),
io:format("~ts~n", [Reply]).
```

---

## 重试、批量与异步

| 函数 | 说明 |
|------|------|
| `chatWithRetry/3,4` | 失败重试（含 429 退避） |
| `batchChat/2,3` | 对多组 Messages 顺序调用 |
| `asyncChat/3,4` | spawn 异步聊天，结果 `{chat_result, Result}` 发往指定 pid |

```erlang
%% 最多重试 3 次
llmCli:chatWithRetry(<<"gpt-4o-mini">>, Messages, 3).

%% 异步
Parent = self(),
llmCli:asyncChat(<<"gpt-4o-mini">>, Messages, Parent),
receive {chat_result, {ok, R}} -> io:format("~ts~n", [R]) end.
```

---

## Token 估算与统计

| 函数 | 说明 |
|------|------|
| `estimateTokens/1` | 粗略估算（约 4 字符/token） |
| `tokenStats/0` | 累计用量 map（按模型 + total） |
| `resetTokenStats/0` | 重置统计 |

```erlang
llmCli:estimateTokens(<<"hello world">>).  %% => 整数
llmCli:tokenStats().
%% => #{total => #{prompt => N, completion => M}, models => #{...}}
```

通过 `ali`：`ali:tokenStats/0`、`ali:llmTokenStats/0`（等价）。

---

## 结果判断辅助

| 函数 | 说明 |
|------|------|
| `isSuccess/1` | `{ok, _}` → `true` |
| `isError/1` | `{error, _}` → `true` |
| `getErrorReason/1` | 提取 error term |
| `formatError/1` | 格式化为可读字符串 |

---

## 错误类型

| 错误 | 说明 |
|------|------|
| `{error, missing_api_key}` | 未配置 `api_key` |
| `{error, {http_error, StatusCode, Body}}` | HTTP 非 2xx |
| `{error, invalid_response}` | 响应 JSON 格式异常 |
| `{error, stream_timeout}` | 流式超时 |
| `{error, Reason}` | 网络或其他错误 |

### 处理示例

```erlang
case llmCli:chat(Model, Messages) of
    {ok, Response} ->
        {ok, Response};
    {error, {http_error, 401, _}} ->
        {error, auth_failed};
    {error, {http_error, 429, _}} ->
        timer:sleep(1000),
        llmCli:chat(Model, Messages);  %% 或使用 chatWithRetry
    {error, Reason} ->
        {error, Reason}
end.
```

---

## 与 Agent 的关系

```
用户代码
   │
   ├─ ali:ask/1          → alServer → alLoop → llmCli:chatCompletion/3 + alTools
   │
   └─ ali:llmChat/2      → llmCli:chat/2        （无工具，纯 LLM）
```

- **Agent 路径**：自动注入系统提示、工具 schema、多轮 tool 循环。
- **直连路径**：完全由调用方构造 `Messages` 和 `Options`，适合脚本、测试、简单问答。

---

## 相关文档

- [API.md](API.md) — `ali` Facade 中的 `llm*` 封装
- [CONFIG.md](CONFIG.md) — 配置文件与环境变量
- [ARCHITECTURE.md](ARCHITECTURE.md) — `llmCli` 在架构中的位置
- 示例代码：[`test/llmTest.erl`](../../test/llmTest.erl)（演示用，非生产 API）
