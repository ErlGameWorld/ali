%%%-------------------------------------------------------------------
%% @doc 外部 MCP 客户端（stdio 或 Streamable HTTP）。把远程工具注册进目录缓存。
%% @end
%%%-------------------------------------------------------------------

-module(alMcpClient).

-behaviour(gen_server).

-export([
    start_link/0,
    ensureStarted/0,
    connect/1,
    disconnect/1,
    listConnections/0,
    listTools/1,
    callTool/3,
    dynamicTools/0,
    isDynamicTool/1,
    registerToolsChangedCallback/1,
    unregisterToolsChangedCallback/1
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
%% 测试导出
-export([spawnMcpWorker/3, handshake/2, toolEntry/2, normalizeSpec/1, parseSseMessages/1]).

-define(SERVER, ?MODULE).
-define(DynamicToolsKey, {?MODULE, dynamicTools}).
-define(MaxFrameBytes, 16 * 1024 * 1024).
%% 握手等待超时（stdio/http 共用）与 HTTP 单次请求超时。
-define(McpConnectTimeoutMs, 15000).
-define(McpHttpTimeoutMs, 120000).

-record(conn, {
    name :: atom(),
    transport = stdio :: stdio | http,
    command :: string() | undefined,
    args = [] :: [string()],
    url :: binary() | undefined,
    headers = [] :: [{binary(), binary()}],
    pid :: pid() | undefined,
    tools = [] :: [map()],
    reconnectAttempt = 0 :: non_neg_integer()
}).

-record(state, {
    connections = #{} :: #{atom() => #conn{}},
    %% 异步工具调用：Ref => {From, TimerRef}，结果到达或超时时 reply，避免阻塞 gen_server。
    pending = #{} :: #{reference() => {gen_server:from(), reference() | undefined}},
    %% 待重连定时器：Name => TimerRef，避免重复调度。
    reconnectTimers = #{} :: #{atom() => reference()},
    %% tools/list 变更回调：fun((Name :: atom(), Tools :: [map()]) -> any())
    toolsChangedCallbacks = [] :: [fun((atom(), [map()]) -> term())]
}).

-define(ReconnectBaseMs, 1000).
-define(ReconnectMaxMs, 30000).
-define(ReconnectMaxAttempts, 8).
%% 空闲时每 30s ping；60s 无响应则判定连接死并触发重连。
-define(PingIntervalMs, 30000).
-define(PingTimeoutMs, 60000).

%%--------------------------------------------------------------------
%% @doc
%% gen_server 启动入口：以本地注册名 `?SERVER' 启动 MCP 客户端进程。
%%
%% @return `{ok, Pid}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% @doc
%% 确保客户端进程已启动；未运行时尝试启动，已运行则直接返回 ok。
%%
%% @return `ok' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
ensureStarted() ->
    case whereis(?SERVER) of
        undefined ->
            case start_link() of
                {ok, _} -> ok;
                {error, {already_started, _}} -> ok;
                {error, _} = E -> E
            end;
        _ ->
            ok
    end.

%%--------------------------------------------------------------------
%% @doc
%% 连接一个外部 MCP 服务器：规范化 spec 后同步调用 gen_server。
%%
%% @param Spec 连接规格 map，必须包含 name 字段
%% @return `ok' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
connect(#{name := _} = Spec) ->
    ensureStarted(),
    gen_server:call(?SERVER, {eConnect, normalizeSpec(Spec)}).

%%--------------------------------------------------------------------
%% @doc
%% 断开与指定名称的外部 MCP 服务器连接。
%%
%% @param Name 连接名称（atom/binary/list 均可）
%% @return `ok' | `{error, notFound}'
%% @end
%%--------------------------------------------------------------------
disconnect(Name) ->
    ensureStarted(),
    gen_server:call(?SERVER, {eDisconnect, toAtom(Name)}).

%%--------------------------------------------------------------------
%% @doc
%% 列出当前所有 MCP 连接的摘要信息。
%%
%% @return 连接摘要 map 列表
%% @end
%%--------------------------------------------------------------------
listConnections() ->
    ensureStarted(),
    gen_server:call(?SERVER, listConnections).

%%--------------------------------------------------------------------
%% @doc
%% 列出指定连接提供的工具列表。
%%
%% @param Name 连接名称
%% @return `{ok, [Tool]}' | `{error, notFound}'
%% @end
%%--------------------------------------------------------------------
listTools(Name) ->
    ensureStarted(),
    gen_server:call(?SERVER, {eListTools, toAtom(Name)}).

%%--------------------------------------------------------------------
%% @doc
%% 调用指定连接上的工具，超时 120 秒。
%%
%% @param ConnName 连接名称
%% @param ToolName 工具名称
%% @param Args 工具参数 map
%% @return `{ok, Result}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
callTool(ConnName, ToolName, Args) ->
    ensureStarted(),
    try gen_server:call(?SERVER, {eCallTool, toAtom(ConnName), ToolName, Args}, 120000) of
        Result -> Result
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:Reason -> {error, {callFailed, Reason}}
    end.

%%--------------------------------------------------------------------
%% @doc 读取 refreshDynamicTools 写入的外部 MCP 工具列表（`"conn:tool"`）。
%%--------------------------------------------------------------------
-spec dynamicTools() -> [map()].
dynamicTools() ->
    try persistent_term:get(?DynamicToolsKey, [])
    catch _:_ -> []
    end.

%%--------------------------------------------------------------------
%% @doc 判断工具名是否为已注册的外部 MCP 动态工具。
%%--------------------------------------------------------------------
-spec isDynamicTool(binary() | atom()) -> boolean().
isDynamicTool(Name) when is_atom(Name) ->
    isDynamicTool(atom_to_binary(Name, utf8));
isDynamicTool(Name) when is_binary(Name) ->
    lists:any(fun(#{name := N}) -> N =:= Name end, dynamicTools());
isDynamicTool(_) ->
    false.

%%--------------------------------------------------------------------
%% @doc
%% 注册 tools/list 变更回调。`Fun(Name, Tools)` 在连接工具列表刷新后调用
%% （含 list_changed 通知与重连后首次握手）。同 Fun 重复注册会被去重。
%% @end
%%--------------------------------------------------------------------
-spec registerToolsChangedCallback(fun((atom(), [map()]) -> term())) -> ok | {error, term()}.
registerToolsChangedCallback(Fun) when is_function(Fun, 2) ->
    ensureStarted(),
    gen_server:call(?SERVER, {eRegisterToolsCb, Fun});
registerToolsChangedCallback(_) ->
    {error, badFun}.

%%--------------------------------------------------------------------
%% @doc 取消已注册的 toolsChanged 回调（按 fun 相等比较）。
%% @end
%%--------------------------------------------------------------------
-spec unregisterToolsChangedCallback(fun((atom(), [map()]) -> term())) -> ok.
unregisterToolsChangedCallback(Fun) when is_function(Fun, 2) ->
    ensureStarted(),
    gen_server:call(?SERVER, {eUnregisterToolsCb, Fun});
unregisterToolsChangedCallback(_) ->
    ok.

%%--------------------------------------------------------------------
%% @doc
%% gen_server init 回调：初始化空状态。
%%
%% @return `{ok, #state{}}'
%% @end
%%--------------------------------------------------------------------
init([]) ->
    process_flag(trap_exit, true),
    {ok, #state{}}.

%%--------------------------------------------------------------------
%% @doc
%% gen_server handle_call 回调（多子句）：
%%  - `{eConnect, Spec}'：连接新 MCP 服务器，重名时返回 alreadyConnected
%%  - `{eDisconnect, Name}'：断开连接并刷新动态工具
%%  - `listConnections'：返回所有连接摘要
%%  - `{eListTools, Name}'：返回指定连接的工具列表
%%  - `{eCallTool, Name, ToolName, Args}'：通过 worker 进程调用工具
%%  - 其它：返回 badRequest
%%
%% @param Request 请求
%% @param From 调用方
%% @param State 当前状态
%% @return `{reply, Reply, NewState}'
%% @end
%%--------------------------------------------------------------------
handle_call({eConnect, Spec}, _From, State) ->
    Name = maps:get(name, Spec),
    case maps:is_key(Name, State#state.connections) of
        true ->
            {reply, {error, alreadyConnected}, State};
        false ->
            case connectSpec(Spec, State) of
                {ok, NewState} -> {reply, ok, NewState};
                {error, Reason} -> {reply, {error, Reason}, State}
            end
    end;
handle_call({eDisconnect, Name}, _From, State) ->
    State1 = cancelReconnectTimer(Name, State),
    case maps:take(Name, State1#state.connections) of
        {Conn, Rest} ->
            stopConn(Conn),
            refreshDynamicTools(Rest),
            {reply, ok, State1#state{connections = Rest}};
        error ->
            {reply, {error, notFound}, State1}
    end;
handle_call(listConnections, _From, State) ->
    List = [connSummary(C) || C <- maps:values(State#state.connections)],
    {reply, List, State};
handle_call({eListTools, Name}, _From, State) ->
    case maps:get(Name, State#state.connections, undefined) of
        undefined -> {reply, {error, notFound}, State};
        #conn{tools = Tools} -> {reply, {ok, Tools}, State}
    end;
handle_call({eCallTool, Name, ToolName, Args}, From, State) ->
    case maps:get(Name, State#state.connections, undefined) of
        #conn{pid = Pid} when is_pid(Pid) ->
            Ref = make_ref(),
            %% 超时后仍 reply，避免调用方永久挂起；慢工具不再阻塞其它 call。
            {ok, TRef} = timer:send_after(120000, self(), {eMcpCallTimeout, Ref}),
            Pid ! {eMcpCall, self(), Ref, ToolName, Args},
            Pending = maps:put(Ref, {From, TRef}, State#state.pending),
            {noreply, State#state{pending = Pending}};
        _ ->
            {reply, {error, notConnected}, State}
    end;
handle_call({eRegisterToolsCb, Fun}, _From, State) ->
    Cbs = lists:usort([Fun | State#state.toolsChangedCallbacks]),
    {reply, ok, State#state{toolsChangedCallbacks = Cbs}};
handle_call({eUnregisterToolsCb, Fun}, _From, State) ->
    Cbs = lists:delete(Fun, State#state.toolsChangedCallbacks),
    {reply, ok, State#state{toolsChangedCallbacks = Cbs}};
handle_call(_Req, _From, State) ->
    {reply, {error, badRequest}, State}.

%%--------------------------------------------------------------------
%% @doc
%% gen_server handle_cast 回调：忽略所有 cast 消息。
%%
%% @param _Msg 消息
%% @param State 当前状态
%% @return `{noreply, State}'
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @doc
%% gen_server handle_info 回调（多子句）：
%%  - eMcpResult：对挂起的 call 做 gen_server:reply
%%  - eMcpCallTimeout：超时 reply
%%  - worker 进程 DOWN/EXIT 时清理对应连接的 pid
%%  - 其它 info 忽略
%%
%% @param Info 消息
%% @param State 当前状态
%% @return `{noreply, NewState}'
%% @end
%%--------------------------------------------------------------------
handle_info({eMcpResult, Ref, Result}, State) ->
    case maps:take(Ref, State#state.pending) of
        {{From, TRef}, Rest} ->
            _ = timer:cancel(TRef),
            gen_server:reply(From, Result),
            {noreply, State#state{pending = Rest}};
        error ->
            logger:debug("alMcpClient orphan eMcpResult ref=~p result=~p", [Ref, Result]),
            {noreply, State}
    end;
handle_info({eMcpCallTimeout, Ref}, State) ->
    case maps:take(Ref, State#state.pending) of
        {{From, _TRef}, Rest} ->
            gen_server:reply(From, {error, timeout}),
            {noreply, State#state{pending = Rest}};
        error ->
            {noreply, State}
    end;
handle_info({'EXIT', Pid, Reason}, State) ->
    logger:warning("alMcpClient worker ~w exited: ~p", [Pid, Reason]),
    {noreply, maybeScheduleReconnect(Pid, State)};
handle_info({'DOWN', _, process, Pid, Reason}, State) ->
    logger:warning("alMcpClient monitored worker ~w down: ~p", [Pid, Reason]),
    {noreply, maybeScheduleReconnect(Pid, State)};
handle_info({eReconnect, Name, Attempt}, State) ->
    Timers = maps:remove(Name, State#state.reconnectTimers),
    State1 = State#state{reconnectTimers = Timers},
    case maps:get(Name, State1#state.connections, undefined) of
        #conn{pid = Pid} when is_pid(Pid) ->
            {noreply, State1};
        #conn{} = Conn ->
            case spawnConn(Conn) of
                {ok, NewPid, Tools} ->
                    NewConn = Conn#conn{
                        pid = NewPid,
                        tools = Tools,
                        reconnectAttempt = 0
                    },
                    Conns = maps:put(Name, NewConn, State1#state.connections),
                    refreshDynamicTools(Conns),
                    notifyConnectedTools(Name, Tools, State1),
                    logger:info("alMcpClient ~p reconnected", [Name]),
                    {noreply, State1#state{connections = Conns}};
                {error, Reason} ->
                    logger:warning("alMcpClient ~p reconnect failed: ~p", [Name, Reason]),
                    {noreply, scheduleReconnect(Name, Attempt, State1)}
            end;
        undefined ->
            {noreply, State1}
    end;
handle_info({eMcpNotify, Pid, Method}, State) ->
    case Method of
        <<"notifications/tools/list_changed">> ->
            {noreply, refreshToolsForPid(Pid, State)};
        <<"tools/list_changed">> ->
            {noreply, refreshToolsForPid(Pid, State)};
        _ ->
            {noreply, State}
    end;
handle_info({eMcpPingFailed, Pid, Reason}, State) ->
    logger:warning("alMcpClient ping failed pid=~p reason=~p", [Pid, Reason]),
    %% worker 会随后 EXIT/DOWN；此处仅提前清 pid 并调度重连。
    {noreply, maybeScheduleReconnect(Pid, State)};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @doc
%% gen_server terminate 回调：终止时停止所有 worker 连接。
%%
%% @param _Reason 终止原因
%% @param State 当前状态
%% @return `ok'
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, State) ->
    maps:foreach(fun(_N, Conn) -> stopConn(Conn) end, State#state.connections),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% gen_server code_change 回调：热升级时直接保留原状态。
%%
%% @param _OldVsn 旧版本
%% @param State 当前状态
%% @param _Extra 附加数据
%% @return `{ok, State}'
%% @end
%%--------------------------------------------------------------------
code_change(_Old, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% @doc
%% 按连接规格启动 worker 进程并注册到状态中，成功后刷新动态工具缓存。
%%
%% @param Spec 连接规格 map（stdio: name/command/args；http: name/url/headers）
%% @param State 当前状态
%% @return `{ok, NewState}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
connectSpec(Spec, State) ->
    Name = maps:get(name, Spec),
    %% 主动 connect 时取消挂起的自动重连。
    State1 = cancelReconnectTimer(Name, State),
    Conn0 = buildConn(Spec),
    case spawnConn(Conn0) of
        {ok, Pid, Tools} ->
            Conn = Conn0#conn{pid = Pid, tools = Tools, reconnectAttempt = 0},
            Conns = maps:put(Name, Conn, State1#state.connections),
            refreshDynamicTools(Conns),
            notifyConnectedTools(Name, Tools, State1),
            {ok, State1#state{connections = Conns}};
        {error, _} = E ->
            E
    end.

%% 从规范化 spec 构造连接 record（stdio/http 分支）。
buildConn(#{transport := http, url := Url} = Spec) ->
    #conn{name = maps:get(name, Spec), transport = http, url = Url,
          headers = maps:get(headers, Spec, defaultHttpHeaders())};
buildConn(#{command := Cmd} = Spec) ->
    #conn{name = maps:get(name, Spec), transport = stdio, command = Cmd,
          args = maps:get(args, Spec, [])}.

%% 按连接 record 启动对应传输的 worker。
spawnConn(#conn{transport = http, name = N, url = Url, headers = Hdrs}) ->
    spawnMcpHttpWorker(N, Url, Hdrs);
spawnConn(#conn{transport = stdio, name = N, command = Cmd, args = Args}) ->
    spawnMcpWorker(N, Cmd, Args).

%%--------------------------------------------------------------------
%% @doc
%% 启动一个 worker 进程执行外部 MCP 命令，等待握手结果（15 秒超时）。
%%
%% @param Name 连接名称
%% @param Cmd 可执行文件路径或命令名
%% @param Args 命令参数列表
%% @return `{ok, Pid, Tools}' | `{error, connectTimeout | Reason}'
%% @end
%%--------------------------------------------------------------------
spawnMcpWorker(Name, Cmd, Args) ->
    Parent = self(),
    Ref = make_ref(),
    Pid = spawn_link(fun() -> mcpWorkerLoop(Name, Cmd, Args, Parent, Ref) end),
    receive
        {eMcpReady, Ref, Tools} ->
            {ok, Pid, Tools};
        {eMcpFailed, Ref, Reason} ->
            {error, Reason};
        {'EXIT', Pid, Reason} ->
            %% worker 在握手前崩溃（如参数非法导致异常），如实上报而非超时
            {error, {workerExit, Reason}}
    after ?McpConnectTimeoutMs ->
        exit(Pid, kill),
        {error, connectTimeout}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 启动一个 HTTP/SSE MCP worker：握手（initialize→tools/list）成功后进入
%% 请求/响应循环。握手失败或崩溃时向父进程上报。
%%
%% @param Name 连接名称
%% @param Url  MCP Streamable HTTP 端点（binary）
%% @param Headers 额外请求头（用户提供的鉴权等）
%% @return `{ok, Pid, Tools}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
spawnMcpHttpWorker(Name, Url, Headers) ->
    Parent = self(),
    Ref = make_ref(),
    Pid = spawn_link(fun() ->
        case httpHandshake(Url, Headers, Name, ?McpHttpTimeoutMs) of
            {ok, Tools} ->
                Parent ! {eMcpReady, Ref, Tools},
                httpWorkerLoop(Url, Headers, 3, ?McpHttpTimeoutMs);
            {error, Reason} ->
                Parent ! {eMcpFailed, Ref, Reason}
        end
    end),
    receive
        {eMcpReady, Ref, Tools} ->
            {ok, Pid, Tools};
        {eMcpFailed, Ref, Reason} ->
            {error, Reason};
        {'EXIT', Pid, Reason} ->
            {error, {workerExit, Reason}}
    after ?McpConnectTimeoutMs ->
        exit(Pid, kill),
        {error, connectTimeout}
    end.

%%--------------------------------------------------------------------
%% @doc
%% HTTP worker 请求/响应循环：tools/call 与 tools/list 各自独立 POST，
%% 同步等待响应后回传，无持久连接与 ping。与 stdio worker 保持相同的
%% `{eMcpCall, ...}' / `{eMcpListTools, ...}' / `eStop' 消息协议。
%% @end
%%--------------------------------------------------------------------
httpWorkerLoop(Url, Headers, NextId, TimeoutMs) ->
    receive
        {eMcpCall, From, Ref, Tool, Args} ->
            Req = #{jsonrpc => <<"2.0">>, id => NextId, method => <<"tools/call">>,
                    params => #{name => Tool, arguments => Args}},
            Result = case httpCall(Url, Headers, Req, NextId, TimeoutMs) of
                {ok, R} -> {ok, R};
                {error, _} = E -> E
            end,
            From ! {eMcpResult, Ref, Result},
            httpWorkerLoop(Url, Headers, NextId + 1, TimeoutMs);
        {eMcpListTools, From, Ref} ->
            Req = #{jsonrpc => <<"2.0">>, id => NextId, method => <<"tools/list">>},
            Result = case httpCall(Url, Headers, Req, NextId, TimeoutMs) of
                {ok, #{<<"tools">> := Tools}} when is_list(Tools) -> {ok, Tools};
                {ok, _} -> {ok, []};
                {error, _} = E -> E
            end,
            From ! {eMcpListToolsResult, Ref, Result},
            httpWorkerLoop(Url, Headers, NextId + 1, TimeoutMs);
        eStop ->
            ok
    end.

%%--------------------------------------------------------------------
%% @doc
%% HTTP 握手：initialize → notifications/initialized → tools/list。
%% 返回服务器声明工具列表。
%% @end
%%--------------------------------------------------------------------
httpHandshake(Url, Headers, Name, TimeoutMs) ->
    InitReq = #{
        jsonrpc => <<"2.0">>,
        id => 1,
        method => <<"initialize">>,
        params => #{
            protocolVersion => <<"2024-11-05">>,
            capabilities => #{tools => #{listChanged => true}},
            clientInfo => #{name => <<"ali">>, version => <<"0.1.0">>}
        }
    },
    case httpCall(Url, Headers, InitReq, 1, TimeoutMs) of
        {ok, _InitResult} ->
            Notif = #{jsonrpc => <<"2.0">>, method => <<"notifications/initialized">>},
            _ = httpPost(Url, Headers, Notif, TimeoutMs),
            ToolsReq = #{jsonrpc => <<"2.0">>, id => 2, method => <<"tools/list">>},
            case httpCall(Url, Headers, ToolsReq, 2, TimeoutMs) of
                {ok, #{<<"tools">> := Tools}} when is_list(Tools) -> {ok, Tools};
                {ok, _} -> {ok, []};
                {error, Reason} ->
                    logger:warning("alMcpClient ~p tools/list failed: ~p", [Name, Reason]),
                    {error, Reason}
            end;
        {error, Reason} ->
            logger:warning("alMcpClient ~p initialize failed: ~p", [Name, Reason]),
            {error, Reason}
    end.

%% 发送一条 JSON-RPC 请求并从响应中挑出匹配 Id 的 result/error。
httpCall(Url, Headers, ReqMap, Id, TimeoutMs) ->
    case httpPost(Url, Headers, ReqMap, TimeoutMs) of
        {ok, Messages} -> pickResponse(Messages, Id);
        {error, _} = E -> E
    end.

%% 向 MCP 端点 POST 一条 JSON-RPC 消息，返回全部解码后的响应消息。
httpPost(Url, Headers0, Map, TimeoutMs) ->
    Body = alJson:encode(Map),
    Headers = httpHeaders(Headers0),
    Options = #{recvTimeout => TimeoutMs, connectTimeout => TimeoutMs},
    case alHttp:post(Url, Headers, Body, Options) of
        {ok, Status, RespHeaders, RespBody} when Status >= 200, Status < 300 ->
            decodeHttpMessages(RespHeaders, RespBody);
        {ok, Status, _RespHeaders, RespBody} ->
            {error, #{status => Status, body => truncBody(RespBody)}};
        {error, Reason} ->
            {error, Reason}
    end.

%% 合并默认头（Content-Type/Accept）与用户头；用户头可覆盖、可追加（如 Authorization）。
httpHeaders(UserHeaders) ->
    Defaults = defaultHttpHeaders(),
    UserNames = [lowerB(N) || {N, _} <- UserHeaders],
    Kept = [{N, V} || {N, V} <- Defaults, not lists:member(lowerB(N), UserNames)],
    Kept ++ UserHeaders.

defaultHttpHeaders() ->
    [{<<"content-type">>, <<"application/json">>},
     {<<"accept">>, <<"application/json, text/event-stream">>}].

%% 根据 Content-Type 解码响应体：SSE 走事件流解析，否则按 JSON 解码。
decodeHttpMessages(RespHeaders, RespBody) ->
    CT = headerValue(RespHeaders, <<"content-type">>),
    case isEventStream(CT) of
        true -> {ok, parseSseMessages(RespBody)};
        false -> decodeJsonBody(RespBody)
    end.

decodeJsonBody(<<>>) ->
    {ok, []};
decodeJsonBody(Body) ->
    try alJson:decode(Body) of
        M when is_map(M) -> {ok, [M]};
        _ -> {ok, []}
    catch
        _:_ -> {error, {invalidJson, truncBody(Body)}}
    end.

%% 从消息列表中挑选匹配 Id 的响应（含 result 或 error）。
pickResponse(Messages, Id) ->
    case lists:dropwhile(fun(M) -> not isResponseFor(M, Id) end, Messages) of
        [#{<<"result">> := R} | _] -> {ok, R};
        [#{<<"error">> := E} | _] -> {error, E};
        _ -> {error, noResponseForId}
    end.

isResponseFor(#{<<"id">> := Id, <<"result">> := _}, Id) -> true;
isResponseFor(#{<<"id">> := Id, <<"error">> := _}, Id) -> true;
isResponseFor(_, _) -> false.

%%--------------------------------------------------------------------
%% Streamable HTTP / SSE 解析辅助
%%--------------------------------------------------------------------
isEventStream(undefined) -> false;
isEventStream(CT) ->
    binary:match(lowerB(CT), <<"text/event-stream">>) =/= nomatch.

%% 解析 SSE 响应体，抽取每条事件的 JSON-RPC 消息（返回 map 列表）。
parseSseMessages(Bin0) ->
    Bin = binary:replace(Bin0, <<"\r\n">>, <<"\n">>, [global]),
    lists:flatmap(fun parseSseEvent/1, binary:split(Bin, <<"\n\n">>, [global])).

parseSseEvent(Chunk) ->
    Lines = binary:split(Chunk, <<"\n">>, [global]),
    Data = lists:filtermap(fun sseData/1, Lines),
    case Data of
        [] ->
            [];
        _ ->
            case safeDecode(joinBins(Data, <<"\n">>)) of
                {ok, M} -> [M];
                error -> []
            end
    end.

sseData(<<"data:", Rest/binary>>) -> {true, stripSpace(Rest)};
sseData(_) -> false.

stripSpace(<<" ", T/binary>>) -> T;
stripSpace(T) -> T.

safeDecode(Bin) ->
    try alJson:decode(Bin) of
        M when is_map(M) -> {ok, M}
    catch
        _:_ -> error
    end.

joinBins([H | T], Sep) ->
    lists:foldl(fun(B, Acc) -> <<Acc/binary, Sep/binary, B/binary>> end, H, T);
joinBins([], _) ->
    <<>>.

%% 大小写不敏感地读取响应头值；缺失返回 undefined。
headerValue(Headers, Name) ->
    Target = lowerB(toBin(Name)),
    findHeader(Headers, Target).

findHeader([], _) -> undefined;
findHeader([{N, V} | Rest], Target) ->
    case lowerB(toBin(N)) =:= Target of
        true -> toBin(V);
        false -> findHeader(Rest, Target)
    end;
findHeader([_ | Rest], Target) ->
    findHeader(Rest, Target).

lowerB(B) when is_binary(B) -> string:lowercase(B);
lowerB(L) when is_list(L) -> list_to_binary(string:lowercase(L)).

toBin(V) when is_binary(V) -> V;
toBin(V) when is_atom(V) -> atom_to_binary(V, utf8);
toBin(V) when is_list(V) ->
    case unicode:characters_to_binary(V) of
        B when is_binary(B) -> B;
        _ -> iolist_to_binary(io_lib:format("~p", [V]))
    end;
toBin(V) -> iolist_to_binary(io_lib:format("~p", [V])).

truncBody(B) when byte_size(B) =< 4096 -> B;
truncBody(B) -> <<(binary:part(B, 0, 4096))/binary, "..."/utf8>>.

%%--------------------------------------------------------------------
%% @doc
%% MCP worker 主循环：解析可执行文件 → 打开端口 → 握手 → 通知父进程 → 进入工作循环。
%%
%% 启动失败时向父进程发送 `{eMcpFailed, Ref, spawnFailed}'。
%%
%% @param Name 连接名称
%% @param Cmd 命令
%% @param Args 参数
%% @param Parent 父进程 PID
%% @param InitRef 握手引用
%% @end
%%--------------------------------------------------------------------
mcpWorkerLoop(Name, Cmd, Args, Parent, InitRef) ->
    Executable = case filelib:is_file(Cmd) of
        true -> Cmd;
        false ->
            case os:find_executable(Cmd) of
                false -> Cmd;
                Found -> Found
            end
    end,
    %% MCP uses Content-Length framing (like LSP), not {packet, 4}.
    %% 注意：不能写 {packet, 0}——OTP 的 packet 只接受 1/2/4，{packet, 0} 会使
    %% open_port 直接 badarg；不指定 packet 选项即为无帧处理，配合手动分帧。
    PortOpts = [binary, exit_status, hide, use_stdio],
    case open_port({spawn_executable, Executable}, [{args, Args} | PortOpts]) of
        Port when is_port(Port) ->
            case handshake(Port, Name) of
                {ok, Tools, Leftover} ->
                    Parent ! {eMcpReady, InitRef, Tools},
                    workerLoop(Port, Parent, 2, Leftover);
                {error, Reason} ->
                    Parent ! {eMcpFailed, InitRef, Reason}
            end;
        _ ->
            Parent ! {eMcpFailed, InitRef, spawnFailed}
    end.

%%--------------------------------------------------------------------
%% @doc
%% MCP 握手：initialize 请求 → initialized 通知 → tools/list 请求。
%% 返回服务器声明的工具列表。
%%
%% @param Port 已打开的 erlang 端口
%% @param Name 连接名称（用于错误日志）
%% @return `{ok, [Tool]}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
handshake(Port, Name) ->
    InitReq = #{
        jsonrpc => <<"2.0">>,
        id => 1,
        method => <<"initialize">>,
        params => #{
            protocolVersion => <<"2024-11-05">>,
            capabilities => #{
                tools => #{listChanged => true}
            },
            clientInfo => #{name => <<"ali">>, version => <<"0.1.0">>}
        }
    },
    ok = writeFramed(Port, InitReq),
    case readResponse(Port, 1, <<>>) of
        {ok, #{<<"result">> := _InitResult}, Buf1} ->
            Notif = #{jsonrpc => <<"2.0">>, method => <<"notifications/initialized">>},
            ok = writeFramed(Port, Notif),
            ToolsReq = #{jsonrpc => <<"2.0">>, id => 2, method => <<"tools/list">>},
            ok = writeFramed(Port, ToolsReq),
            case readResponse(Port, 2, Buf1) of
                {ok, #{<<"result">> := #{<<"tools">> := Tools}}, Rest} ->
                    {ok, Tools, Rest};
                {ok, #{<<"result">> := _}, Rest} ->
                    {ok, [], Rest};
                {ok, #{<<"error">> := E}, _Buf} ->
                    logger:warning("alMcpClient ~p tools/list error: ~p", [Name, E]),
                    {error, {rpcError, E}};
                {error, Reason} ->
                    logger:warning("alMcpClient ~p tools/list failed: ~p", [Name, Reason]),
                    {error, Reason}
            end;
        {ok, #{<<"error">> := E}, _Buf1} ->
            logger:warning("alMcpClient ~p initialize error: ~p", [Name, E]),
            {error, {rpcError, E}};
        {error, Reason} ->
            logger:warning("alMcpClient ~p initialize failed: ~p", [Name, Reason]),
            {error, Reason}
    end.

%%--------------------------------------------------------------------
%% @doc
%% worker 工作循环：接收 `{eMcpCall, From, Ref, Tool, Args}' 后通过端口
%% 转发 tools/call JSON-RPC 请求，读取响应并回传给调用方。
%%
%% @param Port 已打开的 erlang 端口
%% @param Parent 父进程 PID
%% @param NextId 下一个 JSON-RPC 请求 ID
%% @param Buf 未消费完的帧缓冲
%% @end
%%--------------------------------------------------------------------
workerLoop(Port, Parent, NextId, Buf) ->
    receive
        {eMcpCall, From, Ref, Tool, Args} ->
            Req = #{
                jsonrpc => <<"2.0">>,
                id => NextId,
                method => <<"tools/call">>,
                params => #{name => Tool, arguments => Args}
            },
            ok = writeFramed(Port, Req),
            {Result, Rest} = case readResponse(Port, NextId, Buf) of
                {ok, #{<<"result">> := R}, Rest0} -> {{ok, R}, Rest0};
                {ok, #{<<"error">> := E}, Rest0} -> {{error, E}, Rest0};
                {ok, Other, Rest0} -> {{ok, Other}, Rest0};
                {error, Reason} -> {{error, Reason}, <<>>}
            end,
            From ! {eMcpResult, Ref, Result},
            workerLoop(Port, Parent, NextId + 1, Rest);
        {eMcpListTools, From, Ref} ->
            Req = #{jsonrpc => <<"2.0">>, id => NextId, method => <<"tools/list">>},
            ok = writeFramed(Port, Req),
            {Result, Rest} = case readResponse(Port, NextId, Buf) of
                {ok, #{<<"result">> := #{<<"tools">> := Tools}}, Rest0} -> {{ok, Tools}, Rest0};
                {ok, #{<<"result">> := _}, Rest0} -> {{ok, []}, Rest0};
                {ok, #{<<"error">> := E}, Rest0} -> {{error, E}, Rest0};
                {error, Reason} -> {{error, Reason}, <<>>}
            end,
            From ! {eMcpListToolsResult, Ref, Result},
            workerLoop(Port, Parent, NextId + 1, Rest);
        {Port, {data, Data}} ->
            {Buf1, Notifs} = drainNotifications(<<Buf/binary, Data/binary>>),
            lists:foreach(fun(Method) ->
                Parent ! {eMcpNotify, self(), Method}
            end, Notifs),
            workerLoop(Port, Parent, NextId, Buf1);
        {Port, closed} ->
            ok;
        {Port, {exit_status, _}} ->
            ok;
        eStop ->
            try port_close(Port) catch _:_ -> ok end,
            ok
    after ?PingIntervalMs ->
        case doPing(Port, NextId, Buf) of
            {ok, Rest} ->
                workerLoop(Port, Parent, NextId + 1, Rest);
            {error, Reason} ->
                Parent ! {eMcpPingFailed, self(), Reason},
                try port_close(Port) catch _:_ -> ok end,
                exit({pingFailed, Reason})
        end
    end.

%% 空闲 keepalive：发 MCP ping，超时视为连接死。
doPing(Port, Id, Buf) ->
    Req = #{jsonrpc => <<"2.0">>, id => Id, method => <<"ping">>, params => #{}},
    try writeFramed(Port, Req) of
        ok ->
            case readResponseTimed(Port, Id, Buf, ?PingTimeoutMs) of
                {ok, _Msg, Rest} -> {ok, Rest};
                {error, Reason} -> {error, Reason}
            end
    catch
        _:Reason -> {error, Reason}
    end.

%% 与 readResponse/3 相同，但允许自定义超时（ping 用 60s）。
readResponseTimed(Port, Id, Buf, TimeoutMs) ->
    case parseFrame(Buf) of
        {ok, Body, Rest} ->
            Msg = alJson:decode(Body),
            case Msg of
                #{<<"id">> := Id} when is_map_key(<<"result">>, Msg)
                                       orelse is_map_key(<<"error">>, Msg) ->
                    {ok, Msg, Rest};
                #{<<"method">> := _} = N when not is_map_key(<<"id">>, N) ->
                    %% ping 期间收到通知：忽略后继续等响应（父进程靠 Port data 处理也可）
                    readResponseTimed(Port, Id, Rest, TimeoutMs);
                _ ->
                    readResponseTimed(Port, Id, Rest, TimeoutMs)
            end;
        need_more ->
            receive
                {Port, {data, Data}} ->
                    NewBuf = <<Buf/binary, Data/binary>>,
                    case byte_size(NewBuf) > ?MaxFrameBytes of
                        true -> {error, frameTooLarge};
                        false -> readResponseTimed(Port, Id, NewBuf, TimeoutMs)
                    end;
                {Port, closed} ->
                    {error, portClosed};
                {'EXIT', Port, _} ->
                    {error, portClosed};
                {Port, {exit_status, _}} ->
                    {error, portClosed}
            after TimeoutMs ->
                {error, pingTimeout}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% 从缓冲中抽出无 id 的 JSON-RPC 通知（如 tools/list_changed），返回剩余缓冲。
drainNotifications(Buf) ->
    drainNotifications(Buf, []).

drainNotifications(Buf, Acc) ->
    case parseFrame(Buf) of
        {ok, Body, Rest} ->
            case alJson:decode(Body) of
                #{<<"method">> := Method} = Msg when not is_map_key(<<"id">>, Msg) ->
                    drainNotifications(Rest, [Method | Acc]);
                _ ->
                    %% 非通知：保留原始帧缓冲，留给后续 readResponse。
                    {Buf, lists:reverse(Acc)}
            end;
        need_more ->
            {Buf, lists:reverse(Acc)};
        {error, _} ->
            {<<>>, lists:reverse(Acc)}
    end.

%%--------------------------------------------------------------------
%% 断线后指数退避重连；list_changed 时向 worker 拉新 tools 列表。
%%--------------------------------------------------------------------
maybeScheduleReconnect(Pid, State) ->
    case findConnByPid(Pid, State#state.connections) of
        {ok, Name, Conn} ->
            Cleared = Conn#conn{pid = undefined, tools = []},
            Conns = maps:put(Name, Cleared, State#state.connections),
            refreshDynamicTools(Conns),
            Attempt = Cleared#conn.reconnectAttempt,
            scheduleReconnect(Name, Attempt, State#state{connections = Conns});
        error ->
            State
    end.

findConnByPid(Pid, Conns) ->
    maps:fold(fun
        (Name, #conn{pid = P} = C, error) when P =:= Pid -> {ok, Name, C};
        (_, _, Acc) -> Acc
    end, error, Conns).

scheduleReconnect(Name, Attempt, State) when Attempt >= ?ReconnectMaxAttempts ->
    logger:warning("alMcpClient ~p reconnect gave up after ~p attempts",
                   [Name, Attempt]),
    case maps:get(Name, State#state.connections, undefined) of
        #conn{} = Conn ->
            Conns = maps:put(Name, Conn#conn{reconnectAttempt = Attempt},
                             State#state.connections),
            State#state{connections = Conns};
        _ ->
            State
    end;
scheduleReconnect(Name, Attempt, State) ->
    case maps:is_key(Name, State#state.reconnectTimers) of
        true ->
            State;
        false ->
            Delay = min(?ReconnectMaxMs, ?ReconnectBaseMs bsl min(Attempt, 5)),
            TRef = erlang:send_after(Delay, self(), {eReconnect, Name, Attempt + 1}),
            Conns = case maps:get(Name, State#state.connections, undefined) of
                #conn{} = Conn ->
                    maps:put(Name, Conn#conn{reconnectAttempt = Attempt + 1},
                             State#state.connections);
                _ ->
                    State#state.connections
            end,
            logger:info("alMcpClient ~p reconnect in ~pms (attempt ~p)",
                        [Name, Delay, Attempt + 1]),
            State#state{
                connections = Conns,
                reconnectTimers = maps:put(Name, TRef, State#state.reconnectTimers)
            }
    end.

cancelReconnectTimer(Name, State) ->
    case maps:take(Name, State#state.reconnectTimers) of
        {TRef, Rest} ->
            erlang:cancel_timer(TRef),
            State#state{reconnectTimers = Rest};
        error ->
            State
    end.

refreshToolsForPid(Pid, State) ->
    case findConnByPid(Pid, State#state.connections) of
        {ok, Name, #conn{pid = Pid} = Conn} ->
            Ref = make_ref(),
            Pid ! {eMcpListTools, self(), Ref},
            receive
                {eMcpListToolsResult, Ref, {ok, Tools}} ->
                    NewConn = Conn#conn{tools = Tools},
                    Conns = maps:put(Name, NewConn, State#state.connections),
                    refreshDynamicTools(Conns),
                    invokeToolsChanged(Name, Tools, State),
                    logger:info("alMcpClient ~p tools refreshed (~p)", [Name, length(Tools)]),
                    State#state{connections = Conns};
                {eMcpListToolsResult, Ref, {error, Reason}} ->
                    logger:warning("alMcpClient ~p tools refresh failed: ~p", [Name, Reason]),
                    State
            after 15000 ->
                logger:warning("alMcpClient ~p tools refresh timeout", [Name]),
                State
            end;
        _ ->
            State
    end.

%% 通知已注册回调；失败隔离，不拖垮 gen_server。
invokeToolsChanged(Name, Tools, State) ->
    lists:foreach(fun(Cb) ->
        try Cb(Name, Tools) catch Class:Reason ->
            logger:warning("alMcpClient toolsChanged cb failed: ~p:~p", [Class, Reason])
        end
    end, State#state.toolsChangedCallbacks).

%% connect/reconnect 成功后也通知回调（工具列表可能已变）。
notifyConnectedTools(Name, Tools, State) ->
    invokeToolsChanged(Name, Tools, State).

%%--------------------------------------------------------------------
%% @doc
%% 向端口写入一条 Content-Length 帧的 JSON-RPC 消息。
%%
%% @param Port 端口
%% @param Map  消息 map
%% @return `ok'
%% @end
%%--------------------------------------------------------------------
writeFramed(Port, Map) ->
    Body = alJson:encode(Map),
    Frame = iolist_to_binary([
        <<"Content-Length: ">>, integer_to_binary(byte_size(Body)),
        <<"\r\n\r\n">>, Body
    ]),
    port_command(Port, Frame),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% 从端口读取一条匹配指定 ID 的 JSON-RPC 响应，跳过通知消息。
%%
%% @param Port 端口
%% @param Id   期望的响应 ID
%% @param Buf  已缓冲的数据
%% @return `{ok, Msg, RestBuf}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
readResponse(Port, Id, Buf) ->
    case parseFrame(Buf) of
        {ok, Body, Rest} ->
            Msg = alJson:decode(Body),
            %% 注意：alJson:decode（jiffy [return_maps]）返回的 map 键是 binary，
            %% 因此这里必须用 <<"id">>/<<"result">>/<<"error">> 匹配，
            %% 否则响应永远匹配不上导致 60 秒超时。
            case Msg of
                #{<<"id">> := Id} when is_map_key(<<"result">>, Msg) orelse is_map_key(<<"error">>, Msg) ->
                    {ok, Msg, Rest};
                _ ->
                    %% notification or different id — skip and continue
                    readResponse(Port, Id, Rest)
            end;
        need_more ->
            receive
                {Port, {data, Data}} ->
                    NewBuf = <<Buf/binary, Data/binary>>,
                    case byte_size(NewBuf) > ?MaxFrameBytes of
                        true -> {error, frameTooLarge};
                        false -> readResponse(Port, Id, NewBuf)
                    end;
                {Port, closed} ->
                    {error, portClosed};
                {'EXIT', Port, _} ->
                    {error, portClosed};
                {Port, {exit_status, _}} ->
                    {error, portClosed}
            after 60000 ->
                {error, timeout}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 从缓冲区解析一条 Content-Length 帧。返回 `{ok, Body, Rest}' 或 `need_more'。
%%
%% @param Buf 已缓冲的二进制数据
%% @return `{ok, Body, Rest}' | `need_more' | `{error, badFrame | frameTooLarge}'
%% @end
%%--------------------------------------------------------------------
parseFrame(Buf) ->
    case binary:match(Buf, <<"\r\n\r\n">>) of
        nomatch ->
            case byte_size(Buf) > ?MaxFrameBytes of
                true -> {error, frameTooLarge};
                false -> need_more
            end;
        {Start, _} ->
            Header = binary_part(Buf, 0, Start),
            case parseContentLength(Header) of
                undefined -> {error, badFrame};
                Len when Len > ?MaxFrameBytes ->
                    {error, frameTooLarge};
                Len when Len < 0 ->
                    {error, badFrame};
                Len ->
                    BodyStart = Start + 4,
                    case byte_size(Buf) - BodyStart >= Len of
                        false -> need_more;
                        true ->
                            Body = binary_part(Buf, BodyStart, Len),
                            Rest = binary_part(Buf, BodyStart + Len, byte_size(Buf) - BodyStart - Len),
                            {ok, Body, Rest}
                    end
            end
    end.

%% 从头部提取 Content-Length 值（大小写不敏感）。
%% 注意：binary:match/3 的 [caseless] 选项在 OTP 26 上实测会 badarg，
%% 因此先把头部整体转小写再匹配小写标签，保持大小写不敏感且不崩溃。
parseContentLength(Header) ->
    Low = string:lowercase(Header),
    case binary:match(Low, <<"content-length:">>) of
        nomatch -> undefined;
        {Start, TagLen} ->
            V0 = binary_part(Low, Start + TagLen, byte_size(Low) - Start - TagLen),
            case binary:split(V0, <<"\r\n">>) of
                [Num | _] ->
                    try binary_to_integer(string:trim(Num)) catch _:_ -> undefined end;
                _ -> undefined
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 停止一个连接的 worker 进程（发送 eStop 消息）；非 pid 连接直接返回 ok。
%%
%% @param Conn 连接 record
%% @return `ok'
%% @end
%%--------------------------------------------------------------------
stopConn(#conn{pid = Pid}) when is_pid(Pid) ->
    Pid ! eStop,
    ok;
stopConn(_) ->
    ok.

%%--------------------------------------------------------------------
%% @doc
%% 刷新动态工具缓存：将所有连接的工具聚合为 `"<conn>:<tool>"' 形式存入 persistent_term。
%%
%% @param Conns 当前连接 map
%% @return `ok'
%% @end
%%--------------------------------------------------------------------
refreshDynamicTools(Conns) ->
    Tools = lists:flatmap(fun(#conn{name = N, tools = Ts}) ->
        [toolEntry(N, T) || T <- Ts]
    end, maps:values(Conns)),
    persistent_term:put(?DynamicToolsKey, Tools),
    ok.

%% 为单个工具构建 MCP 工具条目（含名称安全处理）。
%% tools/list 返回的 JSON 经 jiffy return_maps 解码，键为 binary（<<"name">>），
%% 故用双键读取，兼容 atom 键的本地缓存。
toolEntry(N, T) ->
    ToolName = case maps:get(name, T, maps:get(<<"name">>, T, undefined)) of
                   undefined -> <<"unknown">>;
                   N2 when is_binary(N2) -> N2;
                   N2 when is_atom(N2) -> atom_to_binary(N2, utf8);
                   N2 -> iolist_to_binary(io_lib:format("~p", [N2]))
               end,
    #{name => <<(atom_to_binary(N, utf8))/binary, ":", ToolName/binary>>,
      conn => N, spec => T}.

%%--------------------------------------------------------------------
%% @doc
%% 生成连接的摘要 map：包含名称、传输类型、命令/URL 与工具数量。
%%
%% @param Conn 连接 record
%% @return 摘要 map
%% @end
%%--------------------------------------------------------------------
connSummary(#conn{name = N, transport = T, command = C, args = A, url = U, tools = Tools}) ->
    #{
        name => N,
        transport => T,
        command => C,
        args => A,
        url => U,
        toolCount => length(Tools)
    }.

%%--------------------------------------------------------------------
%% @doc
%% 规范化连接规格：name 统一转 atom；补全 transport 默认（stdio）；
%% http 传输下把 url 统一转 binary。
%%
%% @param Spec 连接规格 map
%% @return 规范化后的 spec
%% @end
%%--------------------------------------------------------------------
normalizeSpec(#{name := Name} = Spec) ->
    Transport = case maps:get(transport, Spec, undefined) of
        undefined ->
            case maps:is_key(url, Spec) of true -> http; false -> stdio end;
        T ->
            normalizeTransport(T)
    end,
    Spec1 = Spec#{name => toAtom(Name), transport => Transport},
    case Transport of
        http ->
            Spec1#{url => toBin(maps:get(url, Spec))};
        _ ->
            Spec1
    end.

%% 传输标识归一化：atom/binary 的 http/streamable_http/sse 都归为 http，其余 stdio。
normalizeTransport(http) -> http;
normalizeTransport(<<"http">>) -> http;
normalizeTransport(streamable_http) -> http;
normalizeTransport(<<"streamable_http">>) -> http;
normalizeTransport(sse) -> http;
normalizeTransport(<<"sse">>) -> http;
normalizeTransport(_) -> stdio.

%%--------------------------------------------------------------------
%% @doc
%% 将值转换为 atom（多子句）：
%%  - atom 原样返回
%%  - binary 转为已存在 atom，找不到时保留 binary
%%  - list 转为已存在 atom，找不到时保留 list
%%
%% @param Value 任意值
%% @return atom | binary | list
%% @end
%%--------------------------------------------------------------------
toAtom(A) when is_atom(A) -> A;
toAtom(B) when is_binary(B) ->
    try binary_to_existing_atom(B, utf8) catch _:_ -> B end;
toAtom(L) when is_list(L) ->
    try list_to_existing_atom(L) catch _:_ -> L end.
