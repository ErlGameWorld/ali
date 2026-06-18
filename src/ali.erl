%%%-------------------------------------------------------------------
%%% @doc
%%% ali OTP 应用的<b>唯一对外 API 入口</b>（Facade 模块）。
%%%
%%% 使用者只需调用本模块，无需直接接触内部模块（如 {@link alServer}、
%%% {@link llmCli} 等）。API 分为三类：
%%%
%%% <b>1. Agent API</b> — 智能体问答与工具调用，经 {@link alServer} 运行。
%%%    支持多轮会话、流式输出、异步任务、代码修改（edit 模式）等。
%%%
%%% <b>2. LLM API</b>（{@code llm*} 前缀）— 绕过 Agent，直接向大模型发 HTTP 请求。
%%%    适用于简单对话场景，不触发工具调用。
%%%
%%% <b>3. 配置 API</b> — 加载 {@code config.cfg}、查询 Provider 与 Agent 参数。
%%%
%%% <h3>快速开始</h3>
%%% <pre>
%%%   %% 启动（通常 rebar3 shell 已自动启动 ali 应用）
%%%   {ok, _} = ali:start().
%%%
%%%   %% 单次提问
%%%   {ok, Answer} = ali:ask("项目有哪些 Erlang 模块？").
%%%
%%%   %% 交互式多轮对话
%%%   ali:chat().
%%% </pre>
%%%
%%% <h3>会话选项</h3>
%%% {@code ask/2}、{@code askStream/2}、{@code askAsync/2} 的 {@code Opts} 支持：
%%% <ul>
%%%   <li>{@code #{sessionId => <<"dev"/utf8>>} — 指定会话 ID，默认 {@code <<"default"/utf8>>}}</li>
%%%   <li>{@code #{mode => ask | edit | exec}} — 覆盖当前运行模式</li>
%%% </ul>
%%%
%%% <h3>运行模式</h3>
%%% <ul>
%%%   <li>{@code ask} — 只读：分析代码、回答问题，禁止写文件</li>
%%%   <li>{@code edit} — 可修改代码（需策略 {@code allowWrite => true}）</li>
%%%   <li>{@code exec} — 可执行 Erlang 函数（仅 `execBlacklist` 拦截）</li>
%%% </ul>
%%% @end
%%%-------------------------------------------------------------------
-module(ali).

-export([
    start/0,
    start/1,
    stop/0,
    ask/1,
    ask/2,
    askStream/1,
    askStream/2,
    askAsync/1,
    askAsync/2,
    askPrint/1,
    askPrint/2,
    print/1,
    chat/0,
    chat/1,
    run/1,
    run/3,
    approve/1,
    status/0,
    tools/0,
    sessions/0,
    auditLog/0,
    auditLog/1,
    clearSession/0,
    clearSession/1,
    saveSession/0,
    saveSession/1,
    loadSession/1,
    deleteSavedSession/1,
    savedSessions/0,
    taskStatus/1,
    cancelTask/1,
    tasks/0,
    setConfig/2,
    getConfig/0,
    getMode/0,
    setMode/1,
    getWorkingContext/0,
    addContext/2,
    clearContext/0,
    refreshIndex/0,
    loadConfigFromEnv/0,
    startWeb/0,
    stopWeb/0,
    webStatus/0,
    tokenStats/0,
    resetTokenStats/0,
    backupCleanup/0,
    auditClear/0,
    health/0,
    llmChat/2, llmChat/3,
    llmChatStream/2, llmChatStream/3,
    setLlmConfig/2,
    getLlmConfig/1, getLlmConfig/2,
    llmLoadConfig/0, llmLoadConfig/1,
    llmLoadConfigFromEnv/0,
    llmTokenStats/0, llmResetTokenStats/0,
    getAgentConfig/0,
    formatAgentConfig/0,
    listProviders/0,
    getProvider/1
]).

%%%===================================================================
%%% 生命周期
%%%===================================================================

%% @doc 启动 Agent 运行时。
%%
%% 确保 {@code ali} 应用已启动，加载配置文件，并验证 {@link alServer} 进程存在。
%% 若通过 {@code rebar3 shell} 进入，应用通常已自动启动，本函数主要用于
%% 在 shell 中手动初始化或覆盖启动选项。
%%
%% @returns `{ok, Pid}' 其中 Pid 为 alServer 进程；`{error, agentNotStarted}' 若服务未就绪
-spec start() -> {ok, pid()} | {error, term()}.
start() ->
    start([]).

%% @doc 启动 Agent 并应用额外配置。
%%
%% `Opts` 可为 proplist 或 map，键值对会通过 {@link setConfig/2} 写入 Agent 配置。
%% 示例：`ali:start([{sessionId, <<"dev"/utf8>>}]}` 或 `ali:start(#{maxSteps => 40})`
%%
%% @param Opts 启动时覆盖的 Agent 配置项
%% @returns 同 {@link start/0}
-spec start([term()]) -> {ok, pid()} | {error, term()}.
start(Opts) ->
    application:ensure_all_started(ali),
    llmLoadConfig(),
    loadConfigFromEnv(),
    applyStartOpts(Opts),
    case whereis(alServer) of
        undefined -> {error, agentNotStarted};
        Pid -> {ok, Pid}
    end.

%% @doc 停止 Agent 服务进程（不停止整个 ali 应用）。
%%
%% 终止 {@link alServer} 子进程，但保留 {@link ali_sup} 监督树及其他子进程
%% （如 {@link alCodeIndexer}）。
-spec stop() -> ok.
stop() ->
    alServer:stop(),
    case whereis(ali_sup) of
        undefined -> ok;
        _Pid ->
            supervisor:terminate_child(ali_sup, alServer),
            ok
    end.

%%%===================================================================
%%% 问答（Agent）
%%%===================================================================

%% @doc 向 Agent 提问（默认会话、默认模式）。
%%
%% Agent 会自动调用工具（读文件、查索引等）并返回最终文本回答。
%%
%% @param Prompt 用户问题，支持 UTF-8 字符串或 binary
%% @returns `{ok, Answer}' 模型最终回复；`{error, Reason}' 失败原因
-spec ask(binary() | string()) -> {ok, binary()} | {error, term()}.
ask(Prompt) ->
    withServer(fun() -> alServer:ask(Prompt) end).

%% @doc 向 Agent 提问，可指定会话与模式等选项。
%%
%% 常用选项：
%% <ul>
%%%   <li>`sessionId` — 会话标识，多用户/多任务隔离</li>
%%%   <li>`mode` — `ask | edit | exec`，覆盖全局模式</li>
%%% </ul>
%%
%% @param Prompt 用户问题
%% @param Opts 选项 map 或 proplist
-spec ask(binary() | string(), map() | list()) -> {ok, binary()} | {error, term()}.
ask(Prompt, Opts) ->
    withServer(fun() -> alServer:ask(Prompt, Opts) end).

%% @doc 流式提问：在请求过程中向<b>调用进程</b>推送 chunk。
%%
%% 调用进程会收到消息：
%% <ul>
%%%   <li>`{ali, stream, Chunk}'` / `{stream_chunk, Chunk}'` — 文本片段</li>
%%%   <li>`{ali, streamDone, done}'` / `{stream_chunk, done}'` — 流结束</li>
%%% </ul>
%% 函数本身在流结束后返回完整回答。
-spec askStream(binary() | string()) -> {ok, binary()} | {error, term()}.
askStream(Prompt) ->
    withServer(fun() -> alServer:askStream(Prompt) end).

%% @doc 流式提问（带选项），选项同 {@link ask/2}。
-spec askStream(binary() | string(), map() | list()) -> {ok, binary()} | {error, term()}.
askStream(Prompt, Opts) ->
    withServer(fun() -> alServer:askStream(Prompt, Opts) end).

%% @doc 异步提问：立即返回任务 ID，后台执行 Agent 循环。
%%
%% 通过 {@link taskStatus/1} 轮询进度与结果；通过 {@link cancelTask/1} 取消。
%%
%% @returns `{ok, TaskId}' 任务标识（binary）
-spec askAsync(binary() | string()) -> {ok, binary()} | {error, term()}.
askAsync(Prompt) ->
    withServer(fun() -> alServer:askAsync(Prompt) end).

%% @doc 异步提问（带选项），选项同 {@link ask/2}。
-spec askAsync(binary() | string(), map() | list()) -> {ok, binary()} | {error, term()}.
askAsync(Prompt, Opts) ->
    withServer(fun() -> alServer:askAsync(Prompt, Opts) end).

%% @doc 提问并将回答打印到标准输出（UTF-8）。
-spec askPrint(binary() | string()) -> ok | {error, term()}.
askPrint(Prompt) ->
    askPrint(Prompt, #{}).

%% @doc 提问并打印（带选项），选项同 {@link ask/2}。
-spec askPrint(binary() | string(), map() | list()) -> ok | {error, term()}.
askPrint(Prompt, Opts) ->
    case ask(Prompt, Opts) of
        {ok, Answer} ->
            print(Answer),
            ok;
        {error, Reason} = Err ->
            io:format("~n[error: ~p]~n", [Reason]),
            Err
    end.

%% @doc 将 Agent 回复格式化打印到标准输出。
-spec print(binary() | iolist()) -> ok.
print(Answer) ->
    io:format("~nAgent> ~ts~n", [safeDisplayAnswer(Answer)]),
    ok.

%%%===================================================================
%%% 交互式终端
%%%===================================================================

%% @doc 进入交互式多轮对话（终端 REPL）。
%%
%% 支持斜杠命令：`/quit`、`/clear`、`/config`、`/mode`、`/web` 等。
%% 输入 `/help` 查看完整命令列表。
-spec chat() -> ok | {error, term()}.
chat() ->
    chat(#{}).

%% @doc 进入交互式对话，可指定默认 `sessionId` 等选项。
-spec chat(map() | list()) -> ok | {error, term()}.
chat(Opts) ->
    case ensureStarted() of
        {ok, _} ->
            printChatBanner(Opts),
            chatLoop(normalizeOpts(Opts));
        {error, Reason} ->
            {error, Reason}
    end.

%%%===================================================================
%%% 函数执行与写操作审批
%%%===================================================================

%% @doc 在 exec 模式下执行 Erlang 函数（元组形式，黑名单拦截）。
%%
%% @param `{Mod, Fun, Args}' 模块、函数名、参数列表
-spec run(tuple()) -> {ok, map()} | {error, term()}.
run({Mod, Fun, Args}) ->
    withServer(fun() -> alServer:run({Mod, Fun, Args}) end).

%% @doc 在 exec 模式下执行 Erlang 函数（黑名单拦截）。
-spec run(module(), atom(), list()) -> {ok, map()} | {error, term()}.
run(Mod, Fun, Args) ->
    withServer(fun() -> alServer:run({Mod, Fun, Args}) end).

%% @doc 确认并执行待审批的写操作任务。
%%
%% 当 Agent 在 edit 模式下计划修改文件时，可能返回 `TaskId` 等待人工确认。
%% 调用本函数后才会真正执行写入。
%%
%% @param TaskId 待审批任务 ID（binary 或字符串）
-spec approve(binary() | string()) -> {ok, map()} | {error, term()}.
approve(TaskId) ->
    withServer(fun() -> alServer:approve(TaskId) end).

%%%===================================================================
%%% 状态与工具
%%%===================================================================

%% @doc 获取 Agent 运行时状态快照。
%%
%% 返回 map，包含会话数、工具数、索引统计、当前模式等字段。
-spec status() -> map() | {error, term()}.
status() ->
    withServer(fun() -> alServer:status() end).

%% @doc 列出 Agent 可用的全部工具名称与描述。
-spec tools() -> [atom()].
tools() ->
    alTools:listTools().

%% @doc 获取内存中活跃会话的概要信息。
-spec sessions() -> map() | {error, term()}.
sessions() ->
    withServer(fun() -> alServer:sessions() end).

%% @doc 获取工具调用审计日志（最近全部条目）。
-spec auditLog() -> [map()].
auditLog() ->
    alAudit:list().

%% @doc 获取工具调用审计日志，限制条数。
%% @param Limit 最多返回的日志条数
-spec auditLog(non_neg_integer()) -> [map()].
auditLog(Limit) ->
    alAudit:list(Limit).

%%%===================================================================
%%% 会话持久化
%%%===================================================================

%% @doc 清空默认会话（`<<"default"/utf8>>`）的对话历史。
-spec clearSession() -> ok | {error, term()}.
clearSession() ->
    withServer(fun() -> alServer:clearSession() end).

%% @doc 清空指定会话的对话历史。
%% @param SessionId 会话标识
-spec clearSession(binary()) -> ok | {error, term()}.
clearSession(SessionId) ->
    withServer(fun() -> alServer:clearSession(SessionId) end).

%% @doc 将默认会话保存到磁盘（`.al/sessions/` 目录）。
-spec saveSession() -> ok | {error, term()}.
saveSession() ->
    withServer(fun() -> alServer:saveSession() end).

%% @doc 将指定会话保存到磁盘。
-spec saveSession(binary()) -> ok | {error, term()}.
saveSession(SessionId) ->
    withServer(fun() -> alServer:saveSession(SessionId) end).

%% @doc 从磁盘恢复已保存的会话到内存。
-spec loadSession(binary()) -> ok | {error, term()}.
loadSession(SessionId) ->
    withServer(fun() -> alServer:loadSession(SessionId) end).

%% @doc 删除磁盘上已保存的会话文件。
-spec deleteSavedSession(binary()) -> ok | {error, term()}.
deleteSavedSession(SessionId) ->
    withServer(fun() -> alServer:deleteSavedSession(SessionId) end).

%% @doc 列出所有已持久化到磁盘的会话 ID。
-spec savedSessions() -> [binary()] | {error, term()}.
savedSessions() ->
    withServer(fun() -> alServer:savedSessions() end).

%%%===================================================================
%%% 异步任务
%%%===================================================================

%% @doc 查询异步任务（{@link askAsync/1}）的状态与结果。
%%
%% @returns `{ok, #{status := running | completed | failed, ...}}' 或 `{error, notFound}'
-spec taskStatus(binary()) -> {ok, map()} | {error, notFound | term()}.
taskStatus(TaskId) ->
    withServer(fun() -> alServer:taskStatus(TaskId) end).

%% @doc 取消正在运行的异步任务。
-spec cancelTask(binary()) -> ok | {error, term()}.
cancelTask(TaskId) ->
    withServer(fun() -> alServer:cancelTask(TaskId) end).

%% @doc 列出当前所有异步任务及其状态。
-spec tasks() -> [map()] | {error, term()}.
tasks() ->
    withServer(fun() -> alServer:tasks() end).

%%%===================================================================
%%% Agent 配置与上下文
%%%===================================================================

%% @doc 设置 Agent 运行时配置项。
%%
%% 常用键：`model`、`maxSteps`、`maxMessages`、`projectRoot`、`policy`、`mode` 等。
%% 配置立即生效于后续 ask 请求。
%%
%% @param Key 配置键（atom）
%% @param Value 配置值
-spec setConfig(atom(), term()) -> ok | {error, term()}.
setConfig(Key, Value) ->
    withServer(fun() -> alServer:setConfig(Key, Value) end).

%% @doc 获取当前 Agent 完整配置 map。
-spec getConfig() -> map() | {error, term()}.
getConfig() ->
    withServer(fun() -> alServer:getConfig() end).

%% @doc 获取当前运行模式：`ask`、`edit` 或 `exec`。
-spec getMode() -> ask | edit | exec | {error, term()}.
getMode() ->
    withServer(fun() -> alServer:getMode() end).

%% @doc 切换运行模式。
-spec setMode(ask | edit | exec) -> ok | {error, term()}.
setMode(Mode) ->
    withServer(fun() -> alServer:setMode(Mode) end).

%% @doc 获取工作上下文（用户手动添加的模块/文件/进程列表）。
-spec getWorkingContext() -> map() | {error, term()}.
getWorkingContext() ->
    withServer(fun() -> alServer:getWorkingContext() end).

%% @doc 向工作上下文添加条目，供后续提问时注入系统提示。
%%
%% `Type` 通常为 `module`、`file` 或 `process`。
-spec addContext(atom() | binary(), term()) -> ok | {error, term()}.
addContext(Type, Value) ->
    withServer(fun() -> alServer:addContext(Type, Value) end).

%% @doc 清空工作上下文。
-spec clearContext() -> ok | {error, term()}.
clearContext() ->
    withServer(fun() -> alServer:clearContext() end).

%% @doc 刷新项目代码索引（扫描 .erl 文件、构建模块依赖图）。
%%
%% Agent 的工具（如 analyzeCalls）依赖此索引。
-spec refreshIndex() -> {ok, map()} | {error, term()}.
refreshIndex() ->
    withServer(fun() ->
        C = alServer:getConfig(),
        alCodeIndexer:refresh(C)
    end).

%% @doc 从环境变量加载 Agent 相关配置。
%%
%% 读取 `LLM_AGENT_MODEL`、`LLM_AGENT_PROJECT_ROOT`、`LLM_AGENT_USE_NATIVE_TOOLS`
%% 等环境变量，并合并 LLM 配置（`LLM_API_KEY` 等，见 {@link llmLoadConfigFromEnv/0}）。
-spec loadConfigFromEnv() -> ok.
loadConfigFromEnv() ->
    llmLoadConfigFromEnv(),
    case os:getenv("LLM_AGENT_MODEL") of
        false -> ok;
        Model -> maybeSetConfig(model, Model)
    end,
    case os:getenv("LLM_AGENT_PROJECT_ROOT") of
        false -> ok;
        Root -> maybeSetConfig(projectRoot, Root)
    end,
    case os:getenv("LLM_AGENT_USE_NATIVE_TOOLS") of
        false -> ok;
        "false" -> setConfig(useNativeTools, false);
        "0" -> setConfig(useNativeTools, false);
        _ -> setConfig(useNativeTools, true)
    end,
    ok.

%%%===================================================================
%%% Web UI
%%%===================================================================

%% @doc 启动 Web UI HTTP 服务。
%%
%% 端口由 `config.cfg` 中的 `webPort` 决定，默认 8088。
%% @returns `{ok, Port}' 监听端口
-spec startWeb() -> {ok, non_neg_integer()} | {error, term()}.
startWeb() ->
    application:ensure_all_started(ali),
    llmLoadConfig(),
    case alWebSrv:start_web() of
        {ok, Port} -> {ok, Port};
        {error, Reason} -> {error, Reason}
    end.

%% @doc 停止 Web UI HTTP 服务。
-spec stopWeb() -> ok | {error, term()}.
stopWeb() ->
    alWebSrv:stop().

%% @doc 查询 Web UI 运行状态。
%%
%% @returns `#{running => boolean(), port => integer() | undefined}`
-spec webStatus() -> map().
webStatus() ->
    #{
        running => alWebSrv:running(),
        port => alWebSrv:port()
    }.

%%%===================================================================
%%% 维护与监控
%%%===================================================================

%% @doc 获取 LLM Token 用量统计（累计 prompt/completion tokens）。
-spec tokenStats() -> map().
tokenStats() ->
    llmTokenStats().

%% @doc 重置 Token 用量统计计数器。
-spec resetTokenStats() -> ok.
resetTokenStats() ->
    llmResetTokenStats().

%% @doc 清理过期的文件编辑备份（`.al/backups/` 目录）。
-spec backupCleanup() -> ok.
backupCleanup() ->
    alBackup:cleanup().

%% @doc 清空工具调用审计日志。
-spec auditClear() -> ok.
auditClear() ->
    alAudit:clear().

%% @doc 健康检查，供 Web API `/api/health` 及监控使用。
%%
%% @returns `#{status => ok | degraded, server => boolean(), web => boolean(),
%%           node => binary(), configLoaded => boolean()}`
-spec health() -> map().
health() ->
    ServerOk = whereis(alServer) =/= undefined,
    #{
        status => case ServerOk of true -> ok; false -> degraded end,
        server => ServerOk,
        web => alWebSrv:running(),
        node => atom_to_binary(node(), utf8),
        configLoaded => (getLlmConfig(api_key, <<>>) =/= <<>>)
    }.

%%%===================================================================
%%% LLM 直连 API（委托 llmCli，不经 Agent）
%%%===================================================================

%% @doc 直接向大模型发送聊天请求（无工具调用）。
%% @param Model 模型名称，如 `<<"deepseek-v4-flash"/utf8>>`
%% @param Messages {@link llmCli} 格式的消息列表
-spec llmChat(term(), list()) -> {ok, binary()} | {error, term()}.
llmChat(Model, Messages) ->
    llmCli:chat(Model, Messages).

%% @doc 直接向大模型发送聊天请求（带温度、max_tokens 等选项）。
-spec llmChat(term(), list(), list()) -> {ok, binary()} | {error, term()}.
llmChat(Model, Messages, Options) ->
    llmCli:chat(Model, Messages, Options).

%% @doc 流式聊天：向调用进程推送 `{ali, stream, Chunk}` 消息。
-spec llmChatStream(term(), list()) -> ok | {error, term()}.
llmChatStream(Model, Messages) ->
    llmCli:chatStream(Model, Messages).

%% @doc 流式聊天（带选项）。
-spec llmChatStream(term(), list(), list()) -> ok | {error, term()}.
llmChatStream(Model, Messages, Options) ->
    llmCli:chatStream(Model, Messages, Options).

%% @doc 设置 LLM 连接配置（写入 ali 应用环境）。
%%
%% 常用键：`api_key`、`provider`（openai/deepseek/anthropic/custom）、`base_url`
-spec setLlmConfig(atom(), term()) -> ok.
setLlmConfig(Key, Value) ->
    llmCli:setConfig(Key, Value).

%% @doc 读取 LLM 连接配置。
-spec getLlmConfig(atom()) -> {ok, term()} | undefined.
getLlmConfig(Key) ->
    llmCli:getConfig(Key).

%% @doc 读取 LLM 连接配置，不存在时返回默认值。
-spec getLlmConfig(atom(), term()) -> term().
getLlmConfig(Key, Default) ->
    llmCli:getConfig(Key, Default).

%% @doc 从默认路径加载配置文件（`config.cfg`，不存在则尝试 `config.example.cfg`）。
-spec llmLoadConfig() -> ok | {error, term()}.
llmLoadConfig() ->
    llmCliConfig:load().

%% @doc 从指定路径加载配置文件。
%% @param FilePath 配置文件路径（.cfg 格式）
-spec llmLoadConfig(string()) -> ok | {error, term()}.
llmLoadConfig(FilePath) ->
    llmCliConfig:load(FilePath).

%% @doc 从环境变量加载 LLM 配置（`LLM_API_KEY`、`LLM_PROVIDER` 等）。
-spec llmLoadConfigFromEnv() -> ok.
llmLoadConfigFromEnv() ->
    llmCli:loadConfigFromEnv().

%% @doc 获取 LLM Token 统计（同 {@link tokenStats/0}，显式 LLM 命名）。
-spec llmTokenStats() -> map().
llmTokenStats() ->
    llmCli:tokenStats().

%% @doc 重置 LLM Token 统计。
-spec llmResetTokenStats() -> ok.
llmResetTokenStats() ->
    llmCli:resetTokenStats().

%%%===================================================================
%%% 配置查询 API（委托 llmCliConfig）
%%%===================================================================

%% @doc 获取 Agent 相关配置项 map（model、maxSteps、policy 等）。
-spec getAgentConfig() -> map().
getAgentConfig() ->
    llmCliConfig:getAgentConfig().

%% @doc 将 Agent 配置格式化为可读 UTF-8 文本（用于终端 `/config` 命令）。
-spec formatAgentConfig() -> binary().
formatAgentConfig() ->
    llmCliConfig:formatAgentConfig().

%% @doc 列出支持的 LLM 提供商名称：`openai`、`deepseek`、`anthropic`、`custom`。
-spec listProviders() -> [atom()].
listProviders() ->
    llmCliConfig:listProviders().

%% @doc 获取指定提供商的预设信息（baseUrl、defaultModel 等）。
-spec getProvider(term()) -> {ok, map()} | {error, unknownProvider}.
getProvider(Provider) ->
    llmCliConfig:getProvider(Provider).

%%%===================================================================
%%% 内部辅助（不对外导出）
%%%===================================================================

%% 确保 alServer 已启动，未启动则自动调用 start/0
ensureStarted() ->
    case whereis(alServer) of
        Pid when is_pid(Pid) ->
            {ok, Pid};
        undefined ->
            start()
    end.

%% 在确保服务就绪后执行回调；服务不可用时直接返回错误
withServer(Fun) ->
    case ensureStarted() of
        {ok, _} -> Fun();
        {error, Reason} -> {error, Reason}
    end.

%% 将启动选项写入 Agent 配置
applyStartOpts([]) -> ok;
applyStartOpts(Opts) when is_list(Opts) ->
    lists:foreach(fun({Key, Value}) ->
        setConfig(Key, Value)
    end, Opts);
applyStartOpts(Opts) when is_map(Opts) ->
    maps:foreach(fun(Key, Value) ->
        setConfig(Key, Value)
    end, Opts).

%% alServer 已启动时才写入配置（避免启动阶段竞态）
maybeSetConfig(Key, Value) ->
    case whereis(alServer) of
        undefined -> ok;
        _ -> setConfig(Key, unicode:characters_to_binary(Value))
    end.

%% 打印交互式对话欢迎横幅
printChatBanner(Opts) ->
    SessionId = maps:get(sessionId, normalizeOpts(Opts), <<"default"/utf8>>),
    io:format("~n=== ali 对话模式 ===~n"),
    io:format("会话: ~ts~n", [SessionId]),
    io:format("输入问题后回车；支持多轮上下文。~n"),
    io:format("命令: /quit  /clear  /config  /mode  /context  /web  /save [id]  /load <id>  /session <id>  /help~n~n").

%% 交互式对话主循环
chatLoop(Opts) ->
    case io:get_line(">>> ") of
        eof ->
            io:format("~n"),
            ok;
        {error, Reason} ->
            {error, Reason};
        Line ->
            Prompt = trimLine(Line),
            case handleChatCommand(Prompt, Opts) of
                stop ->
                    io:format("再见。~n"),
                    ok;
                {continue, NewOpts} ->
                    chatLoop(NewOpts);
                ask ->
                    chatTurn(Prompt, Opts),
                    chatLoop(Opts)
            end
    end.

%% 处理斜杠命令；返回 stop | {continue, Opts} | ask
%% Prompt 为 UTF-8 binary（见 {@link trimLine/1}）。
handleChatCommand(<<>>, Opts) ->
    {continue, Opts};
handleChatCommand(<<"/quit"/utf8>>, _Opts) ->
    stop;
handleChatCommand(<<"/exit"/utf8>>, _Opts) ->
    stop;
handleChatCommand(<<"/config"/utf8>>, Opts) ->
    printAgentConfig(),
    {continue, Opts};
handleChatCommand(<<"/mode"/utf8>>, Opts) ->
    io:format("当前模式: ~p~n", [getMode()]),
    {continue, Opts};
handleChatCommand(<<"/mode ", Rest/binary>>, Opts) ->
    Mode = binary_to_atom(string:trim(Rest), utf8),
    case setMode(Mode) of
        ok -> io:format("已切换到模式 ~p~n", [Mode]);
        {error, R} -> io:format("切换失败: ~p~n", [R])
    end,
    {continue, Opts};
handleChatCommand(<<"/context"/utf8>>, Opts) ->
    io:format("~p~n", [getWorkingContext()]),
    {continue, Opts};
handleChatCommand(<<"/context clear"/utf8>>, Opts) ->
    clearContext(),
    io:format("已清空工作上下文。~n"),
    {continue, Opts};
handleChatCommand(<<"/context add module ", Mod/binary>>, Opts) ->
    ModAtom = binary_to_atom(string:trim(Mod), utf8),
    addContext(module, ModAtom),
    io:format("已添加上下文模块 ~ts~n", [string:trim(Mod)]),
    {continue, Opts};
handleChatCommand(<<"/context add file ", Path/binary>>, Opts) ->
    PathBin = string:trim(Path),
    addContext(file, PathBin),
    io:format("已添加上下文文件 ~ts~n", [PathBin]),
    {continue, Opts};
handleChatCommand(<<"/index"/utf8>>, Opts) ->
    case refreshIndex() of
        {ok, S} -> io:format("索引已刷新: ~p~n", [S]);
        {error, R} -> io:format("索引失败: ~p~n", [R])
    end,
    {continue, Opts};
handleChatCommand(<<"/web"/utf8>>, Opts) ->
    case startWeb() of
        {ok, Port} ->
            io:format("Web UI 已启动: http://127.0.0.1:~p/~n", [Port]);
        {error, R} ->
            io:format("Web 启动失败: ~p~n", [R])
    end,
    {continue, Opts};
handleChatCommand(<<"/web stop"/utf8>>, Opts) ->
    stopWeb(),
    io:format("Web UI 已停止。~n"),
    {continue, Opts};
handleChatCommand(<<"/help"/utf8>>, Opts) ->
    io:format(
        "命令:~n"
        "  /quit /exit     退出~n"
        "  /clear          清空当前会话~n"
        "  /config         查看 Agent 配置（本地，秒回）~n"
        "  /mode [ask|edit|exec]  查看或切换模式~n"
        "  /context          查看工作上下文~n"
        "  /context clear    清空工作上下文~n"
        "  /context add module <Mod>  添加上下文模块~n"
        "  /index          刷新代码索引~n"
        "  /web            启动 Web UI（默认端口见 config webPort）~n"
        "  /web stop       停止 Web UI~n"
        "  /save [id]      保存会话~n"
        "  /load <id>      加载会话~n"
        "  /session <id>   切换会话~n"
        "  /status         查看状态~n~n"
    ),
    {continue, Opts};
handleChatCommand(<<"/clear"/utf8>>, Opts) ->
    clearSession(),
    io:format("已清空会话。~n"),
    {continue, Opts};
handleChatCommand(<<"/status"/utf8>>, Opts) ->
    io:format("~p~n", [status()]),
    {continue, Opts};
handleChatCommand(<<"/save"/utf8>>, Opts) ->
    case saveSession() of
        ok -> io:format("会话已保存。~n");
        {ok, ok} -> io:format("会话已保存。~n");
        {error, Reason} -> io:format("保存失败: ~p~n", [Reason])
    end,
    {continue, Opts};
handleChatCommand(<<"/save ", Rest/binary>>, Opts) ->
    Id = string:trim(Rest),
    case saveSession(Id) of
        ok -> io:format("会话 ~ts 已保存。~n", [Id]);
        {ok, ok} -> io:format("会话 ~ts 已保存。~n", [Id]);
        {error, Reason} -> io:format("保存失败: ~p~n", [Reason])
    end,
    {continue, Opts};
handleChatCommand(<<"/load ", Rest/binary>>, Opts) ->
    Id = string:trim(Rest),
    case loadSession(Id) of
        ok ->
            io:format("已加载会话 ~ts。~n", [Id]),
            {continue, Opts#{sessionId => Id}};
        {ok, ok} ->
            io:format("已加载会话 ~ts。~n", [Id]),
            {continue, Opts#{sessionId => Id}};
        {error, Reason} ->
            io:format("加载失败: ~p~n", [Reason]),
            {continue, Opts}
    end;
handleChatCommand(<<"/session ", Rest/binary>>, Opts) ->
    Id = string:trim(Rest),
    io:format("已切换到会话 ~ts。~n", [Id]),
    {continue, Opts#{sessionId => Id}};
handleChatCommand(<<"/load"/utf8>>, Opts) ->
    io:format("用法: /load <sessionId>~n"),
    {continue, Opts};
handleChatCommand(<<"/session"/utf8>>, Opts) ->
    io:format("用法: /session <sessionId>~n"),
    {continue, Opts};
handleChatCommand(Prompt, Opts) when is_binary(Prompt) ->
    case tryLocalAnswer(Prompt) of
        true -> {continue, Opts};
        false -> ask
    end;
handleChatCommand(Prompt, Opts) ->
    handleChatCommand(promptBinary(Prompt), Opts).

%% 本地快速回答（配置查询等），无需调用 LLM
tryLocalAnswer(Prompt) when is_binary(Prompt) ->
    S = string:trim(Prompt),
    case {matchAgentConfigQuery(S), matchLoadConfigQuery(S)} of
        {true, _} ->
            printAgentConfig(),
            true;
        {_, true} ->
            io:format("~n~p~n", [llmLoadConfig()]),
            true;
        _ ->
            false
    end;
tryLocalAnswer(Prompt) ->
    tryLocalAnswer(promptBinary(Prompt)).

matchAgentConfigQuery(S) when is_binary(S) ->
    Patterns = [
        <<"\\s*(查看|显示|获取|看看)?\\s*(agent|Agent)\\s*配置\\s*"/utf8>>,
        <<"(agent|Agent)\\s*(配置|config)"/utf8>>,
        <<"(配置|config)\\s*(agent|Agent)"/utf8>>
    ],
    lists:any(fun(Pat) ->
        case re:run(S, Pat, [unicode, caseless]) of
            {match, _} -> true;
            nomatch -> false
        end
    end, Patterns).

matchLoadConfigQuery(S) when is_binary(S) ->
    case re:run(S, <<"llmCliConfig\\s*:\\s*load"/utf8>>, [unicode, caseless]) of
        {match, _} -> true;
        nomatch -> false
    end.

printAgentConfig() ->
    io:format("~n--- Agent 配置 ---~n~ts~n---~n", [formatAgentConfig()]).

%% 安全展示模型回复，处理空回复与非 UTF-8 字符
safeDisplayAnswer(Answer) ->
    Bin = toBinary(Answer),
    case utf8Printable(Bin) of
        true ->
            case byte_size(Bin) of
                0 -> <<"（模型未返回文本，可能仅执行了工具；可用 /config 本地查看配置）"/utf8>>;
                _ -> Bin
            end;
        false ->
            <<"（回复含无法显示的字符，建议 /clear 清空会话后重试，或用 /config 查看配置）"/utf8>>
    end.

utf8Printable(Bin) when is_binary(Bin) ->
    try
        _ = unicode:characters_to_list(Bin, utf8),
        true
    catch
        _:_ -> false
    end;
utf8Printable(_) ->
    false.

%% 单轮对话（spawn 异步执行，终端显示等待动画，超时 10 分钟）
chatTurn(Prompt, Opts) when is_binary(Prompt) ->
    Parent = self(),
    Ref = make_ref(),
    ProgressId = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    alProgress:start(ProgressId),
    AskOpts = maps:merge(normalizeOpts(Opts), #{progressId => ProgressId}),
    spawn(fun() ->
        Result = withServer(fun() ->
            alServer:ask(Prompt, AskOpts)
        end),
        Parent ! {chatTurnDone, Ref, Result}
    end),
    io:format("~n思考中", []),
    case waitChatTurn(Ref, 0, ProgressId, 0) of
        {ok, Answer} ->
            io:format("~nAgent> ~ts~n", [safeDisplayAnswer(Answer)]);
        {error, Reason} ->
            io:format("~n[~ts]~n", [formatChatError(Reason)]);
        timeout ->
            io:format("~n[timeout: 请求超过 10 分钟，已取消]~n")
    end;
chatTurn(Prompt, Opts) ->
    chatTurn(promptBinary(Prompt), Opts).

waitChatTurn(_Ref, Seconds, ProgressId, _LastCount) when Seconds >= 600 ->
    alProgress:drop(ProgressId),
    timeout;
waitChatTurn(Ref, Seconds, ProgressId, LastCount) ->
    NewCount = printChatProgress(ProgressId, LastCount),
    receive
        {chatTurnDone, Ref, {ok, Answer}} ->
            alProgress:drop(ProgressId),
            {ok, Answer};
        {chatTurnDone, Ref, {error, Reason}} ->
            alProgress:drop(ProgressId),
            {error, Reason}
    after 300 ->
        io:format(".", []),
        waitChatTurn(Ref, Seconds + 1, ProgressId, NewCount)
    end.

printChatProgress(ProgressId, LastCount) ->
    #{events := Events, eventCount := Total} = alProgress:snapshot(ProgressId, LastCount),
    lists:foreach(fun(E) ->
        io:format("~n  ~ts", [formatProgressEvent(E)])
    end, Events),
    Total.

formatProgressEvent(#{type := started} = E) ->
    maps:get(message, E, <<"任务已开始"/utf8>>);
formatProgressEvent(#{type := step} = E) ->
    maps:get(message, E, <<"处理中"/utf8>>);
formatProgressEvent(#{type := tool, tool := Tool}) ->
    iolist_to_binary([<<"→ 调用 "/utf8>>, toolLabel(Tool)]);
formatProgressEvent(#{type := tool_done, tool := Tool, ok := true}) ->
    iolist_to_binary([<<"✓ "/utf8>>, toolLabel(Tool), <<" 完成"/utf8>>]);
formatProgressEvent(#{type := tool_done, tool := Tool, status := confirmationRequired}) ->
    iolist_to_binary([<<"⊙ "/utf8>>, toolLabel(Tool), <<" 需确认"/utf8>>]);
formatProgressEvent(#{type := tool_done, tool := Tool, error := Reason}) ->
    iolist_to_binary([<<"✗ "/utf8>>, toolLabel(Tool), <<" 失败: "/utf8>>, format_term(Reason)]);
formatProgressEvent(#{type := tool_done, tool := Tool}) ->
    iolist_to_binary([<<"✗ "/utf8>>, toolLabel(Tool), <<" 失败"/utf8>>]);
formatProgressEvent(#{type := error, reason := Reason}) ->
    iolist_to_binary([<<"! 错误: "/utf8>>, format_term(Reason)]);
formatProgressEvent(_) ->
    <<"…"/utf8>>.

format_term(Reason) when is_binary(Reason) -> Reason;
format_term(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).

toolLabel(T) when is_atom(T) -> atom_to_binary(T, utf8);
toolLabel(T) when is_binary(T) -> T;
toolLabel(T) ->
    unicode:characters_to_binary(io_lib:format("~p", [T])).

normalizeOpts(Opts) when is_map(Opts) ->
    Opts;
normalizeOpts(Opts) when is_list(Opts) ->
    maps:from_list(Opts).

%% 将 io:get_line 读入的行规范为 UTF-8 binary。
%% Windows 终端可能返回 Unicode 码点列表（如「你好」→ `[20320,22909]`），
%% 必须用 {@link unicode:characters_to_binary/1}，不能直接交给 `re:run/3`。
-spec trimLine(binary() | string() | [integer()]) -> binary().
trimLine(Line) when is_binary(Line) ->
    promptBinary(string:trim(Line, trailing, <<"\r\n"/utf8>>));
trimLine(Line) when is_list(Line) ->
    promptBinary(string:trim(Line, trailing, "\r\n"));
trimLine(Line) ->
    promptBinary(Line).

%% @doc Unicode chardata → UTF-8 binary（码点列表 / UTF-8 字节列表 / binary 均可）。
-spec promptBinary(term()) -> binary().
promptBinary(Bin) when is_binary(Bin) ->
    Bin;
promptBinary(List) when is_list(List) ->
    unicode:characters_to_binary(List);
promptBinary(Other) ->
    unicode:characters_to_binary(io_lib:format("~p", [Other])).

toBinary(X) ->
    promptBinary(X).

formatChatError(maxStepsExceeded) ->
    <<"步数用尽：可增加 config.cfg 中的 maxSteps，或 /clear 清空会话后重试"/utf8>>;
formatChatError(timeout) ->
    <<"请求超时：LLM API 或工具执行过久。请检查网络与 config.cfg 中的 api_key/base_url，或在配置中增大 execTimeout"/utf8>>;
formatChatError(stream_timeout) ->
    <<"流式响应超时：模型长时间未返回数据，请重试或改用同步问答"/utf8>>;
formatChatError(Reason) ->
    unicode:characters_to_binary(io_lib:format("error: ~p", [Reason])).