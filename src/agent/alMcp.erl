%%%-------------------------------------------------------------------
%%% @doc MCP（Model Context Protocol）客户端。
%%%
%%% 与外部 MCP Server 通信（JSON-RPC 2.0），支持两种传输：
%%% <ul>
%%%   <li><b>stdio</b>：以子进程方式启动 Server，标准输入输出按行交换消息。</li>
%%%   <li><b>Streamable HTTP/SSE</b>：向单一 HTTP 端点 POST 请求，响应为
%%%       `application/json' 或 `text/event-stream'（SSE）；自动维护
%%%       `Mcp-Session-Id' 会话头。</li>
%%% </ul>
%%%
%%% 完成 `initialize' 握手后：根据 Server 能力（capabilities）自动发现
%%% <ul>
%%%   <li>`tools/list' → 注册为 {@link alTools} 运行时工具（模型可直接调用，
%%%       经 {@link callTool/2} 转发 `tools/call'）；</li>
%%%   <li>`resources/list' → 资源清单（可经 `resources/read' 读取）；</li>
%%%   <li>`prompts/list' → 提示模板（可经 `prompts/get' 获取）。</li>
%%% </ul>
%%% 当任一已连接 Server 提供 resources/prompts 能力时，会注册通用工具
%%% `mcpListResources'/`mcpReadResource'/`mcpListPrompts'/`mcpGetPrompt'，
%%% 让模型可发现并使用整个 MCP 生态的资源与提示。
%%%
%%% 配置示例（config.cfg）：
%%% ```
%%% {mcpServers, [
%%%   %% stdio 传输
%%%   #{name => filesystem, command => "npx",
%%%     args => ["-y", "@modelcontextprotocol/server-filesystem", "/data"],
%%%     env => [], level => executeRisky},
%%%   %% Streamable HTTP 传输
%%%   #{name => remote, transport => http,
%%%     url => "https://example.com/mcp",
%%%     headers => [{"Authorization", "Bearer xxx"}],
%%%     level => executeRisky}
%%% ]}.
%%% '''
%%% @end
%%%-------------------------------------------------------------------
-module(alMcp).

-behaviour(gen_server).

-export([
    start_link/0,
    connect/1,
    connectAll/0,
    disconnect/1,
    servers/0,
    tools/0,
    callRemote/3,
    callTool/2,
    resources/0,
    prompts/0,
    listResources/1,
    listPrompts/1,
    readResource/2,
    getPrompt/3
]).

%% 通用资源/提示工具的分发入口（注册到 alTools，module=alMcp）
-export([
    resourceListTool/2,
    resourceReadTool/2,
    promptListTool/2,
    promptGetTool/2
]).

%% 纯函数（导出供测试与复用）
-export([
    encodeRpc/3,
    encodeNotification/2,
    splitMessages/1,
    buildToolDef/3,
    camelKey/1,
    restoreArgs/2,
    parseSse/1,
    decodeHttpMessages/2
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(PROTOCOL_VERSION, <<"2024-11-05"/utf8>>).
-define(CALL_TIMEOUT, 60000).

-record(srv, {
    name :: atom(),
    transport = stdio :: stdio | http,
    port :: port() | undefined,           %% stdio
    url :: binary() | undefined,          %% http
    headers = [] :: [{binary(), binary()}], %% http 自定义头
    sessionId :: binary() | undefined,    %% http 会话
    buffer = <<>> :: binary(),
    nextId = 1 :: pos_integer(),
    pending = #{} :: map(),               %% Id => {Kind, From}
    connectFrom :: term(),
    level = executeRisky :: atom(),
    info = #{} :: map(),
    caps = #{} :: map(),                  %% Server capabilities
    toolAtoms = [] :: [atom()],
    resources = [] :: [map()],
    prompts = [] :: [map()]
}).

-record(state, {
    servers = #{} :: #{atom() => #srv{}},
    ports = #{} :: #{port() => atom()},
    tools = #{} :: #{atom() => {atom(), binary(), map()}}, %% ToolAtom => {Server, RemoteName, Props}
    genResources = false :: boolean(),    %% 是否已注册通用资源工具
    genPrompts = false :: boolean()
}).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc 连接一个 MCP Server 并发现其工具/资源/提示。Spec 见模块文档。
-spec connect(map()) -> {ok, [atom()]} | {error, term()}.
connect(Spec) when is_map(Spec) ->
    gen_server:call(?SERVER, {connect, Spec}, ?CALL_TIMEOUT).

%% @doc 连接 application env `mcpServers` 中配置的所有 Server。
-spec connectAll() -> [{atom(), {ok, [atom()]} | {error, term()}}].
connectAll() ->
    Specs = alConfig:val(mcpServers),
    [{maps:get(name, S, undefined), connect(S)} || S <- Specs, is_map(S)].

%% @doc 断开指定 Server 并注销其工具。
-spec disconnect(atom()) -> ok.
disconnect(Name) ->
    gen_server:call(?SERVER, {disconnect, Name}, ?CALL_TIMEOUT).

%% @doc 列出已连接的 Server 及其状态。
-spec servers() -> [map()].
servers() ->
    gen_server:call(?SERVER, servers).

%% @doc 列出所有已发现的 MCP 工具（atom 名称）。
-spec tools() -> [atom()].
tools() ->
    gen_server:call(?SERVER, tools).

%% @doc 直接调用某 Server 的远程工具（绕过工具注册表）。
-spec callRemote(atom(), binary() | string(), map()) -> {ok, map()} | {error, term()}.
callRemote(Server, RemoteName, Args) ->
    gen_server:call(?SERVER, {callRemote, Server, toBin(RemoteName), Args}, ?CALL_TIMEOUT).

%% @doc alTools 工具分发入口：依据 Config 中的 toolName 转发到对应 MCP Server。
-spec callTool(map(), map()) -> {ok, map()} | {error, term()}.
callTool(Args, Config) ->
    case maps:get(toolName, Config, undefined) of
        undefined -> {error, mcpMissingToolName};
        ToolAtom -> gen_server:call(?SERVER, {invoke, ToolAtom, Args}, ?CALL_TIMEOUT)
    end.

%% @doc 聚合所有 Server 的资源清单（含 server 标签）。
-spec resources() -> [map()].
resources() ->
    gen_server:call(?SERVER, resources).

%% @doc 聚合所有 Server 的提示模板清单（含 server 标签）。
-spec prompts() -> [map()].
prompts() ->
    gen_server:call(?SERVER, prompts).

%% @doc 列出指定 Server 的资源清单（来自发现缓存）。
-spec listResources(atom()) -> [map()].
listResources(Server) ->
    gen_server:call(?SERVER, {listResources, Server}).

%% @doc 列出指定 Server 的提示模板清单（来自发现缓存）。
-spec listPrompts(atom()) -> [map()].
listPrompts(Server) ->
    gen_server:call(?SERVER, {listPrompts, Server}).

%% @doc 读取某 Server 的资源内容（resources/read）。
-spec readResource(atom(), binary() | string()) -> {ok, map()} | {error, term()}.
readResource(Server, Uri) ->
    gen_server:call(?SERVER, {readResource, Server, toBin(Uri)}, ?CALL_TIMEOUT).

%% @doc 获取某 Server 的提示模板（prompts/get），Args 为模板参数 map。
-spec getPrompt(atom(), binary() | string(), map()) -> {ok, map()} | {error, term()}.
getPrompt(Server, Name, Args) ->
    gen_server:call(?SERVER, {getPrompt, Server, toBin(Name), Args}, ?CALL_TIMEOUT).

%%%===================================================================
%%% 通用资源/提示工具分发
%%%===================================================================

%% @doc 工具 `mcpListResources`：列出所有 MCP Server 的资源。
resourceListTool(_Args, _Config) ->
    {ok, #{resources => resources()}}.

%% @doc 工具 `mcpReadResource`：读取指定 Server 的资源内容。
resourceReadTool(Args, _Config) ->
    case {serverArg(Args), maps:get(uri, Args, undefined)} of
        {undefined, _} -> {error, mcpMissingServer};
        {_, undefined} -> {error, mcpMissingUri};
        {Server, Uri} -> readResource(Server, Uri)
    end.

%% @doc 工具 `mcpListPrompts`：列出所有 MCP Server 的提示模板。
promptListTool(_Args, _Config) ->
    {ok, #{prompts => prompts()}}.

%% @doc 工具 `mcpGetPrompt`：获取指定 Server 的提示模板（可带参数）。
promptGetTool(Args, _Config) ->
    case {serverArg(Args), maps:get(name, Args, undefined)} of
        {undefined, _} -> {error, mcpMissingServer};
        {_, undefined} -> {error, mcpMissingName};
        {Server, Name} ->
            PromptArgs = case maps:get(arguments, Args, #{}) of
                M when is_map(M) -> M;
                _ -> #{}
            end,
            getPrompt(Server, Name, PromptArgs)
    end.

%% 解析工具参数中的 server 名称为已连接 Server 的 atom
serverArg(Args) ->
    case maps:get(server, Args, undefined) of
        undefined -> undefined;
        V -> toAtomSafe(V)
    end.

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    process_flag(trap_exit, true),
    {ok, #state{}}.

handle_call({connect, Spec}, From, State) ->
    case doConnect(Spec, From, State) of
        {ok, NewState} -> {noreply, NewState};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;
handle_call({disconnect, Name}, _From, State) ->
    {reply, ok, removeServer(Name, State)};
handle_call(servers, _From, State) ->
    List = [serverInfo(S) || S <- maps:values(State#state.servers)],
    {reply, List, State};
handle_call(tools, _From, State) ->
    {reply, maps:keys(State#state.tools), State};
handle_call(resources, _From, State) ->
    {reply, aggregate(resources, State), State};
handle_call(prompts, _From, State) ->
    {reply, aggregate(prompts, State), State};
handle_call({listResources, Server}, _From, State) ->
    {reply, srvField(Server, #srv.resources, [], State), State};
handle_call({listPrompts, Server}, _From, State) ->
    {reply, srvField(Server, #srv.prompts, [], State), State};
handle_call({callRemote, Server, RemoteName, Args}, From, State) ->
    dispatchSend(sendCall(Server, RemoteName, Args, {call, undefined}, From, State), State);
handle_call({invoke, ToolAtom, Args}, From, State) ->
    case maps:get(ToolAtom, State#state.tools, undefined) of
        undefined ->
            {reply, {error, mcpToolNotFound}, State};
        {Server, RemoteName, Props} ->
            Restored = restoreArgs(Args, Props),
            dispatchSend(sendCall(Server, RemoteName, Restored, {call, ToolAtom}, From, State), State)
    end;
handle_call({readResource, Server, Uri}, From, State) ->
    Params = #{<<"uri"/utf8>> => Uri},
    dispatchSend(sendRpcTo(Server, <<"resources/read"/utf8>>, Params, {readResource, From}, State), State);
handle_call({getPrompt, Server, Name, Args}, From, State) ->
    Params = #{<<"name"/utf8>> => Name, <<"arguments"/utf8>> => argsToJson(Args)},
    dispatchSend(sendRpcTo(Server, <<"prompts/get"/utf8>>, Params, {getPrompt, From}, State), State);
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% stdio 端口数据：缓冲并按行解析 JSON-RPC 消息
handle_info({Port, {data, Bin}}, State) when is_port(Port) ->
    case maps:get(Port, State#state.ports, undefined) of
        undefined -> {noreply, State};
        Name -> {noreply, handlePortData(Name, Bin, State)}
    end;
handle_info({Port, {exit_status, _Code}}, State) when is_port(Port) ->
    {noreply, handlePortExit(Port, State)};
handle_info({'EXIT', Port, _Reason}, State) when is_port(Port) ->
    {noreply, handlePortExit(Port, State)};
%% HTTP 响应：来自 POST worker
handle_info({mcpHttp, Name, Id, Result}, State) ->
    {noreply, handleHttpResult(Name, Id, Result, State)};
handle_info({mcpPendingTimeout, Name, Id}, State) ->
    {noreply, failPending(Name, Id, mcpCallTimeout, State)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    maps:foreach(fun(_N, S) -> closePort(S#srv.port) end, State#state.servers),
    ok.

%% 将 send* 的返回值统一为 gen_server 回复（错误立即回，成功转 noreply）
dispatchSend({ok, NewState}, _OldState) -> {noreply, NewState};
dispatchSend({error, Reason}, OldState) -> {reply, {error, Reason}, OldState}.

%%%===================================================================
%%% 连接 / 握手
%%%===================================================================

doConnect(Spec, From, State) ->
    Name = maps:get(name, Spec, undefined),
    case Name of
        undefined -> {error, missingName};
        _ ->
            case transportOf(Spec) of
                http -> openHttpServer(Name, Spec, From, State);
                stdio -> openStdioServer(Name, Spec, From, State)
            end
    end.

%% 依据 Spec 推断传输类型：含 url（或 transport=http）走 HTTP，否则 stdio。
transportOf(Spec) ->
    case maps:get(transport, Spec, undefined) of
        http -> http;
        stdio -> stdio;
        _ ->
            case maps:get(url, Spec, undefined) of
                undefined -> stdio;
                _ -> http
            end
    end.

openStdioServer(Name, Spec, From, State) ->
    case maps:get(command, Spec, undefined) of
        undefined -> {error, missingCommand};
        Command ->
            case os:find_executable(toStr(Command)) of
                false -> {error, {executableNotFound, Command}};
                Exe -> openPort(Name, Exe, Spec, From, State)
            end
    end.

openPort(Name, Exe, Spec, From, State) ->
    Args = [toStr(A) || A <- maps:get(args, Spec, [])],
    Env = [{toStr(K), toStr(V)} || {K, V} <- maps:get(env, Spec, [])],
    Level = maps:get(level, Spec, executeRisky),
    PortOpts = [binary, exit_status, use_stdio, stream, {args, Args}, {env, Env}],
    PortOpts2 = case maps:get(cd, Spec, undefined) of
        undefined -> PortOpts;
        Dir -> [{cd, toStr(Dir)} | PortOpts]
    end,
    try open_port({spawn_executable, Exe}, PortOpts2) of
        Port ->
            Srv0 = #srv{name = Name, transport = stdio, port = Port,
                        level = Level, connectFrom = From, nextId = 1},
            Srv = sendRpc(Srv0, <<"initialize"/utf8>>, initParams(), {init, From}),
            NewState = State#state{
                servers = maps:put(Name, Srv, State#state.servers),
                ports = maps:put(Port, Name, State#state.ports)
            },
            {ok, NewState}
    catch
        _:Reason -> {error, {portOpenFailed, Reason}}
    end.

openHttpServer(Name, Spec, From, State) ->
    case maps:get(url, Spec, undefined) of
        undefined -> {error, missingUrl};
        Url ->
            _ = application:ensure_all_started(hackney),
            Level = maps:get(level, Spec, executeRisky),
            Headers = [{toBin(K), toBin(V)} || {K, V} <- maps:get(headers, Spec, [])],
            Srv0 = #srv{name = Name, transport = http, url = toBin(Url),
                        headers = Headers, level = Level, connectFrom = From, nextId = 1},
            Srv = sendRpc(Srv0, <<"initialize"/utf8>>, initParams(), {init, From}),
            NewState = State#state{servers = maps:put(Name, Srv, State#state.servers)},
            {ok, NewState}
    end.

initParams() ->
    #{
        <<"protocolVersion"/utf8>> => ?PROTOCOL_VERSION,
        <<"capabilities"/utf8>> => #{},
        <<"clientInfo"/utf8>> => #{<<"name"/utf8>> => <<"ali"/utf8>>,
                                   <<"version"/utf8>> => <<"0.1.0"/utf8>>}
    }.

%% 移除 Server：注销工具、关闭端口、清理 tools 表并刷新通用工具。
removeServer(Name, State) ->
    case maps:get(Name, State#state.servers, undefined) of
        undefined -> State;
        Srv ->
            unregisterAll(Srv#srv.toolAtoms),
            closePort(Srv#srv.port),
            Ports = case Srv#srv.port of
                undefined -> State#state.ports;
                P -> maps:remove(P, State#state.ports)
            end,
            Tools = maps:filter(fun(_K, {S, _, _}) -> S =/= Name end, State#state.tools),
            State1 = State#state{
                servers = maps:remove(Name, State#state.servers),
                ports = Ports,
                tools = Tools
            },
            refreshGenTools(State1)
    end.

%%%===================================================================
%%% stdio / HTTP 接收
%%%===================================================================

handlePortData(Name, Bin, State) ->
    case maps:get(Name, State#state.servers, undefined) of
        undefined -> State;
        Srv ->
            {Msgs, Rest} = splitMessages(<<(Srv#srv.buffer)/binary, Bin/binary>>),
            Srv1 = Srv#srv{buffer = Rest},
            State1 = setSrv(Name, Srv1, State),
            lists:foldl(fun(Msg, Acc) -> handleMessage(Name, Msg, Acc) end, State1, Msgs)
    end.

%% 处理一次 HTTP POST 的结果：更新会话、解析消息、必要时失败挂起请求。
handleHttpResult(Name, Id, {ok, Status, RespHeaders, RespBody}, State) ->
    State1 = maybeUpdateSession(Name, RespHeaders, State),
    Msgs = decodeHttpMessages(RespHeaders, RespBody),
    State2 = lists:foldl(fun(Msg, Acc) -> handleMessage(Name, Msg, Acc) end, State1, Msgs),
    maybeFailPending(Name, Id, Status, Msgs, State2);
handleHttpResult(Name, Id, {error, Reason}, State) ->
    failPending(Name, Id, {mcpHttpError, Reason}, State).

handleMessage(Name, Msg, State) ->
    case maps:get(Name, State#state.servers, undefined) of
        undefined -> State;
        Srv -> dispatchMessage(Name, Srv, Msg, State)
    end.

%% 带 id 的响应：匹配 pending
dispatchMessage(Name, Srv, #{<<"id"/utf8>> := Id} = Msg, State) ->
    case maps:take(Id, Srv#srv.pending) of
        {{Kind, From}, RestPending} ->
            Srv1 = Srv#srv{pending = RestPending},
            handleResponse(Kind, From, Msg, Name, Srv1, State);
        error ->
            State  %% 未知 id，忽略
    end;
%% 无 id：服务端通知/请求，暂忽略
dispatchMessage(_Name, _Srv, _Msg, State) ->
    State.

%% initialize 响应：记录能力 → initialized 通知 + 按能力发现 tools/resources/prompts
handleResponse(init, From, Msg, Name, Srv, State) ->
    Result = result(Msg),
    Caps = mapField(<<"capabilities"/utf8>>, Result, #{}),
    Info = mapField(<<"serverInfo"/utf8>>, Result, #{}),
    Srv1 = Srv#srv{info = Info, caps = Caps},
    Srv2 = sendNotif(Srv1, <<"notifications/initialized"/utf8>>, #{}),
    %% 发现请求（按能力）：tools/list 触发 connect 回复
    HasTools = maps:is_key(<<"tools"/utf8>>, Caps) orelse map_size(Caps) =:= 0,
    Srv3 = case HasTools of
        true -> sendRpc(Srv2, <<"tools/list"/utf8>>, #{}, {list, From});
        false -> gen_server:reply(From, {ok, []}), Srv2#srv{connectFrom = undefined}
    end,
    Srv4 = maybeDiscover(Srv3, Caps, <<"resources"/utf8>>, <<"resources/list"/utf8>>, resources),
    Srv5 = maybeDiscover(Srv4, Caps, <<"prompts"/utf8>>, <<"prompts/list"/utf8>>, prompts),
    State1 = setSrv(Name, Srv5, State),
    refreshGenTools(State1);
%% tools/list 响应：注册工具，回复 connect 调用方
handleResponse(list, From, Msg, Name, Srv, State) ->
    ToolsJson = listField(<<"tools"/utf8>>, result(Msg)),
    {ToolAtoms, ToolMap} = registerTools(Name, Srv#srv.level, ToolsJson),
    Srv1 = Srv#srv{toolAtoms = ToolAtoms, connectFrom = undefined},
    State1 = setSrv(Name, Srv1, State),
    State2 = State1#state{tools = maps:merge(State1#state.tools, ToolMap)},
    maybeReply(From, {ok, ToolAtoms}),
    State2;
%% resources/list 响应：缓存资源清单
handleResponse(resources, From, Msg, Name, Srv, State) ->
    Rs = listField(<<"resources"/utf8>>, result(Msg)),
    Srv1 = Srv#srv{resources = Rs},
    maybeReply(From, {ok, Rs}),
    setSrv(Name, Srv1, State);
%% prompts/list 响应：缓存提示模板清单
handleResponse(prompts, From, Msg, Name, Srv, State) ->
    Ps = listField(<<"prompts"/utf8>>, result(Msg)),
    Srv1 = Srv#srv{prompts = Ps},
    maybeReply(From, {ok, Ps}),
    setSrv(Name, Srv1, State);
%% tools/call 响应：回复调用方
handleResponse({call, _ToolAtom}, From, Msg, Name, Srv, State) ->
    maybeReply(From, callReply(Msg)),
    setSrv(Name, Srv, State);
%% resources/read 响应
handleResponse(readResource, From, Msg, Name, Srv, State) ->
    maybeReply(From, plainReply(Msg)),
    setSrv(Name, Srv, State);
%% prompts/get 响应
handleResponse(getPrompt, From, Msg, Name, Srv, State) ->
    maybeReply(From, plainReply(Msg)),
    setSrv(Name, Srv, State).

%% 若能力声明了某项，则发送对应发现请求（不阻塞 connect，From=undefined）
maybeDiscover(Srv, Caps, CapKey, Method, Kind) ->
    case maps:is_key(CapKey, Caps) of
        true -> sendRpc(Srv, Method, #{}, {Kind, undefined});
        false -> Srv
    end.

callReply(Msg) ->
    case maps:get(<<"error"/utf8>>, Msg, undefined) of
        undefined -> {ok, normalizeResult(result(Msg))};
        Err -> {error, Err}
    end.

plainReply(Msg) ->
    case maps:get(<<"error"/utf8>>, Msg, undefined) of
        undefined -> {ok, result(Msg)};
        Err -> {error, Err}
    end.

setSrv(Name, Srv, State) ->
    State#state{servers = maps:put(Name, Srv, State#state.servers)}.

%% 注册 tools/list 返回的所有工具到 alTools
registerTools(Name, Level, ToolsJson) ->
    lists:foldl(fun(ToolJson, {Atoms, Map}) ->
        case buildToolDef(Name, ToolJson, Level) of
            {ok, ToolAtom, Def, Props, RemoteName} ->
                _ = alTools:registerTool(Def),
                {[ToolAtom | Atoms], maps:put(ToolAtom, {Name, RemoteName, Props}, Map)};
            skip ->
                {Atoms, Map}
        end
    end, {[], #{}}, ToolsJson).

%% 发送 tools/call（传输无关）
sendCall(Server, RemoteName, Args, Kind, From, State) ->
    Params = #{<<"name"/utf8>> => RemoteName, <<"arguments"/utf8>> => argsToJson(Args)},
    sendRpcTo(Server, <<"tools/call"/utf8>>, Params, {Kind, From}, State).

%% 向已连接 Server 发送 JSON-RPC 请求，登记 pending；返回 {ok, State} | {error, _}
sendRpcTo(Server, Method, Params, PendVal, State) ->
    case maps:get(Server, State#state.servers, undefined) of
        undefined -> {error, mcpServerNotConnected};
        #srv{transport = stdio, port = undefined} -> {error, mcpServerNotConnected};
        Srv ->
            Srv1 = sendRpc(Srv, Method, Params, PendVal),
            {ok, setSrv(Server, Srv1, State)}
    end.

%% 在 srv 上发送一个请求（带 id），登记 pending，返回更新后的 srv。
sendRpc(Srv, Method, Params, PendVal) ->
    Id = Srv#srv.nextId,
    Payload = encodeRpc(Id, Method, Params),
    Srv1 = Srv#srv{nextId = Id + 1, pending = maps:put(Id, PendVal, Srv#srv.pending)},
    erlang:send_after(?CALL_TIMEOUT, self(), {mcpPendingTimeout, Srv#srv.name, Id}),
    transportSend(Srv1, Id, Payload),
    Srv1.

%% 在 srv 上发送通知（无 id，无 pending），返回 srv（不变）。
sendNotif(Srv, Method, Params) ->
    transportSend(Srv, undefined, encodeNotification(Method, Params)),
    Srv.

%% 传输层发送：stdio 写端口；http POST（异步 worker 回传结果）。
transportSend(#srv{transport = stdio, port = Port}, _Id, Payload) ->
    catchPort(Port, Payload);
transportSend(#srv{transport = http} = Srv, Id, Payload) ->
    httpPost(Srv, Id, Payload, self()).

catchPort(undefined, _Payload) -> ok;
catchPort(Port, Payload) ->
    quiet(fun() -> port_command(Port, Payload) end).

%% 异步 POST：在独立进程发起请求并把结果回传给 gen_server。
httpPost(Srv, Id, Payload, Parent) ->
    Name = Srv#srv.name,
    Url = Srv#srv.url,
    Headers = httpHeaders(Srv),
    spawn(fun() ->
        Result = hackney:request(post, Url, Headers, Payload,
                                 [{recv_timeout, ?CALL_TIMEOUT}, {connect_timeout, 15000}]),
        Parent ! {mcpHttp, Name, Id, Result}
    end),
    ok.

httpHeaders(Srv) ->
    Base = [{<<"content-type"/utf8>>, <<"application/json"/utf8>>},
            {<<"accept"/utf8>>, <<"application/json, text/event-stream"/utf8>>}],
    Session = case Srv#srv.sessionId of
        undefined -> [];
        Sid -> [{<<"mcp-session-id"/utf8>>, Sid}]
    end,
    Base ++ Session ++ Srv#srv.headers.

%% 从响应头提取并更新会话 id（若有）。
maybeUpdateSession(Name, Headers, State) ->
    case headerValue(<<"mcp-session-id"/utf8>>, Headers) of
        undefined -> State;
        Sid ->
            case maps:get(Name, State#state.servers, undefined) of
                undefined -> State;
                Srv -> setSrv(Name, Srv#srv{sessionId = Sid}, State)
            end
    end.

%% POST 返回错误状态且无可解析消息时，使对应挂起请求失败。
maybeFailPending(_Name, undefined, _Status, _Msgs, State) ->
    State;
maybeFailPending(Name, Id, Status, [], State) when is_integer(Status), Status >= 400 ->
    failPending(Name, Id, {mcpHttpStatus, Status}, State);
maybeFailPending(_Name, _Id, _Status, _Msgs, State) ->
    State.

%% 使某个挂起请求失败（回复调用方）；若是 init 则移除该 Server。
failPending(_Name, undefined, _Reason, State) ->
    State;
failPending(Name, Id, Reason, State) ->
    case maps:get(Name, State#state.servers, undefined) of
        undefined -> State;
        Srv ->
            case maps:take(Id, Srv#srv.pending) of
                {{Kind, From}, Rest} ->
                    maybeReply(From, {error, Reason}),
                    case Kind of
                        init -> removeServer(Name, State);
                        _ -> setSrv(Name, Srv#srv{pending = Rest}, State)
                    end;
                error -> State
            end
    end.

%% stdio 端口异常退出：清理 + 回复阻塞中的调用方
handlePortExit(Port, State) ->
    case maps:get(Port, State#state.ports, undefined) of
        undefined -> State;
        Name ->
            replyAllPending(Name, mcpServerExited, State),
            removeServer(Name, State)
    end.

replyAllPending(Name, Reason, State) ->
    case maps:get(Name, State#state.servers, undefined) of
        undefined -> ok;
        Srv ->
            maps:foreach(fun(_Id, {_Kind, From}) ->
                quiet(fun() -> maybeReply(From, {error, Reason}) end)
            end, Srv#srv.pending)
    end.

%%%===================================================================
%%% 通用工具注册（resources/prompts）
%%%===================================================================

%% 依据所有 Server 的能力，注册/注销通用资源与提示工具（幂等）。
refreshGenTools(State) ->
    Servers = maps:values(State#state.servers),
    HasR = lists:any(fun(S) -> maps:is_key(<<"resources"/utf8>>, S#srv.caps) end, Servers),
    HasP = lists:any(fun(S) -> maps:is_key(<<"prompts"/utf8>>, S#srv.caps) end, Servers),
    State1 = applyGen(resources, HasR, State),
    applyGen(prompts, HasP, State1).

applyGen(resources, true, #state{genResources = false} = S) ->
    _ = alTools:registerTool(resourceListDef()),
    _ = alTools:registerTool(resourceReadDef()),
    S#state{genResources = true};
applyGen(resources, false, #state{genResources = true} = S) ->
    quiet(fun() -> alTools:unregisterTool(mcpListResources) end),
    quiet(fun() -> alTools:unregisterTool(mcpReadResource) end),
    S#state{genResources = false};
applyGen(prompts, true, #state{genPrompts = false} = S) ->
    _ = alTools:registerTool(promptListDef()),
    _ = alTools:registerTool(promptGetDef()),
    S#state{genPrompts = true};
applyGen(prompts, false, #state{genPrompts = true} = S) ->
    quiet(fun() -> alTools:unregisterTool(mcpListPrompts) end),
    quiet(fun() -> alTools:unregisterTool(mcpGetPrompt) end),
    S#state{genPrompts = false};
applyGen(_Cap, _Has, S) ->
    S.

resourceListDef() ->
    #{name => mcpListResources,
      description => <<"[MCP] 列出所有已连接 MCP Server 的资源（server/uri/name）"/utf8>>,
      parameters => llmJson:encode(#{<<"type"/utf8>> => <<"object"/utf8>>,
                                     <<"properties"/utf8>> => #{}}),
      module => ?MODULE, function => resourceListTool, level => read}.

resourceReadDef() ->
    Schema = #{<<"type"/utf8>> => <<"object"/utf8>>,
        <<"properties"/utf8>> => #{
            <<"server"/utf8>> => #{<<"type"/utf8>> => <<"string"/utf8>>,
                                   <<"description"/utf8>> => <<"MCP Server 名称"/utf8>>},
            <<"uri"/utf8>> => #{<<"type"/utf8>> => <<"string"/utf8>>,
                                <<"description"/utf8>> => <<"资源 URI"/utf8>>}},
        <<"required"/utf8>> => [<<"server"/utf8>>, <<"uri"/utf8>>]},
    #{name => mcpReadResource,
      description => <<"[MCP] 读取指定 MCP Server 的资源内容"/utf8>>,
      parameters => llmJson:encode(Schema),
      module => ?MODULE, function => resourceReadTool, level => read}.

promptListDef() ->
    #{name => mcpListPrompts,
      description => <<"[MCP] 列出所有已连接 MCP Server 的提示模板（server/name/arguments）"/utf8>>,
      parameters => llmJson:encode(#{<<"type"/utf8>> => <<"object"/utf8>>,
                                     <<"properties"/utf8>> => #{}}),
      module => ?MODULE, function => promptListTool, level => read}.

promptGetDef() ->
    Schema = #{<<"type"/utf8>> => <<"object"/utf8>>,
        <<"properties"/utf8>> => #{
            <<"server"/utf8>> => #{<<"type"/utf8>> => <<"string"/utf8>>,
                                   <<"description"/utf8>> => <<"MCP Server 名称"/utf8>>},
            <<"name"/utf8>> => #{<<"type"/utf8>> => <<"string"/utf8>>,
                                 <<"description"/utf8>> => <<"提示模板名称"/utf8>>},
            <<"arguments"/utf8>> => #{<<"type"/utf8>> => <<"object"/utf8>>,
                                      <<"description"/utf8>> => <<"模板参数（可选）"/utf8>>}},
        <<"required"/utf8>> => [<<"server"/utf8>>, <<"name"/utf8>>]},
    #{name => mcpGetPrompt,
      description => <<"[MCP] 获取指定 MCP Server 的提示模板（可带参数）"/utf8>>,
      parameters => llmJson:encode(Schema),
      module => ?MODULE, function => promptGetTool, level => read}.

%%%===================================================================
%%% 信息聚合
%%%===================================================================

serverInfo(S) ->
    #{
        name => S#srv.name,
        transport => S#srv.transport,
        connected => isConnected(S),
        toolCount => length(S#srv.toolAtoms),
        resourceCount => length(S#srv.resources),
        promptCount => length(S#srv.prompts),
        capabilities => maps:keys(S#srv.caps),
        info => S#srv.info
    }.

isConnected(#srv{transport = stdio, port = Port}) -> Port =/= undefined;
isConnected(#srv{transport = http, url = Url}) -> Url =/= undefined.

%% 聚合所有 Server 的 resources/prompts 清单，附加 server 标签。
aggregate(Field, State) ->
    lists:flatmap(fun(S) ->
        Items = case Field of
            resources -> S#srv.resources;
            prompts -> S#srv.prompts
        end,
        [maps:put(server, S#srv.name, ensureMap(I)) || I <- Items]
    end, maps:values(State#state.servers)).

ensureMap(M) when is_map(M) -> M;
ensureMap(Other) -> #{value => Other}.

%% 读取某 Server 记录字段（Index 为 #srv 字段位），不存在时返回 Default。
srvField(Server, Index, Default, State) ->
    case maps:get(Server, State#state.servers, undefined) of
        undefined -> Default;
        Srv -> element(Index, Srv)
    end.

%%%===================================================================
%%% 纯函数（可测试）
%%%===================================================================

%% @doc 编码 JSON-RPC 2.0 请求为一行（带换行）。
-spec encodeRpc(integer(), binary(), map()) -> binary().
encodeRpc(Id, Method, Params) ->
    Msg = #{
        <<"jsonrpc"/utf8>> => <<"2.0"/utf8>>,
        <<"id"/utf8>> => Id,
        <<"method"/utf8>> => Method,
        <<"params"/utf8>> => Params
    },
    <<(llmJson:encode(Msg))/binary, "\n">>.

%% @doc 编码 JSON-RPC 2.0 通知（无 id）。
-spec encodeNotification(binary(), map()) -> binary().
encodeNotification(Method, Params) ->
    Msg = #{
        <<"jsonrpc"/utf8>> => <<"2.0"/utf8>>,
        <<"method"/utf8>> => Method,
        <<"params"/utf8>> => Params
    },
    <<(llmJson:encode(Msg))/binary, "\n">>.

%% @doc 从缓冲区按换行切分出完整 JSON 消息，返回 {解析出的消息列表, 剩余缓冲}。
-spec splitMessages(binary()) -> {[map()], binary()}.
splitMessages(Buffer) ->
    Parts = binary:split(Buffer, <<"\n">>, [global]),
    {Lines, Rest} = case lists:reverse(Parts) of
        [Last | RevInit] -> {lists:reverse(RevInit), Last};
        [] -> {[], <<>>}
    end,
    Msgs = lists:filtermap(fun(Line) ->
        case trim(Line) of
            <<>> -> false;
            Trimmed ->
                try {true, llmJson:decode(Trimmed)}
                catch _:_ -> false end
        end
    end, Lines),
    {Msgs, Rest}.

%% @doc 解析 HTTP 响应体为 JSON-RPC 消息列表（按 content-type 区分 SSE / JSON）。
-spec decodeHttpMessages([{binary() | string(), binary() | string()}], binary()) -> [map()].
decodeHttpMessages(Headers, Body) ->
    case headerValue(<<"content-type"/utf8>>, Headers) of
        undefined -> decodeJsonMessages(Body);
        CT ->
            case binary:match(string:lowercase(CT), <<"text/event-stream"/utf8>>) of
                nomatch -> decodeJsonMessages(Body);
                _ -> parseSse(Body)
            end
    end.

%% @doc 解析 SSE（Server-Sent Events）响应体，提取每个事件 data 中的 JSON 消息。
-spec parseSse(binary()) -> [map()].
parseSse(Body) ->
    Lines = binary:split(Body, <<"\n">>, [global]),
    {Events, Cur} = lists:foldl(fun(Line0, {Evs, Data}) ->
        Line = stripCR(Line0),
        case Line of
            <<>> ->
                case Data of
                    [] -> {Evs, []};
                    _ -> {Evs ++ [joinData(Data)], []}
                end;
            <<"data:", R/binary>> -> {Evs, Data ++ [stripLeadSpace(R)]};
            _ -> {Evs, Data}
        end
    end, {[], []}, Lines),
    AllEvents = case Cur of
        [] -> Events;
        _ -> Events ++ [joinData(Cur)]
    end,
    lists:filtermap(fun(D) ->
        case trim(D) of
            <<>> -> false;
            T -> try {true, llmJson:decode(T)} catch _:_ -> false end
        end
    end, AllEvents).

decodeJsonMessages(Body) ->
    case trim(Body) of
        <<>> -> [];
        T ->
            try
                case llmJson:decode(T) of
                    L when is_list(L) -> [M || M <- L, is_map(M)];
                    M when is_map(M) -> [M];
                    _ -> []
                end
            catch _:_ -> []
            end
    end.

joinData(List) -> iolist_to_binary(lists:join(<<"\n">>, List)).

stripCR(<<>>) -> <<>>;
stripCR(Bin) ->
    case binary:last(Bin) of
        $\r -> binary:part(Bin, 0, byte_size(Bin) - 1);
        _ -> Bin
    end.

stripLeadSpace(<<" ", R/binary>>) -> R;
stripLeadSpace(Bin) -> Bin.

%% @doc 将 MCP tool JSON 转为 alTools 注册定义。
%% 返回 {ok, ToolAtom, RegisterDef, OrigProps, RemoteName} 或 skip。
-spec buildToolDef(atom(), map(), atom()) ->
    {ok, atom(), map(), map(), binary()} | skip.
buildToolDef(ServerName, ToolJson, Level) ->
    case maps:get(<<"name"/utf8>>, ToolJson, undefined) of
        undefined -> skip;
        RemoteName ->
            Desc0 = maps:get(<<"description"/utf8>>, ToolJson, <<>>),
            Schema = maps:get(<<"inputSchema"/utf8>>, ToolJson, #{<<"type"/utf8>> => <<"object"/utf8>>}),
            Props = case Schema of
                #{<<"properties"/utf8>> := P} when is_map(P) -> P;
                _ -> #{}
            end,
            ToolAtom = toolAtom(ServerName, RemoteName),
            Desc = <<"[MCP:", (atomBin(ServerName))/binary, "] ", (toBin(Desc0))/binary>>,
            Def = #{
                name => ToolAtom,
                description => Desc,
                parameters => llmJson:encode(Schema),
                module => ?MODULE,
                function => callTool,
                level => Level
            },
            {ok, ToolAtom, Def, Props, toBin(RemoteName)}
    end.

%% @doc 复刻 alLoop 的键名 camelCase 规则（用于参数键名还原匹配）。
-spec camelKey(binary()) -> atom().
camelKey(Bin) when is_binary(Bin) ->
    %% 必须与 alLoop:binaryToAtomCamel/1 行为完全一致（含其单次 split 语义），
    %% 否则无法可靠地把归一化后的键名还原为 schema 原始属性名。
    List = binary_to_list(Bin),
    AtomStr = case string:split(List, "_") of
        [Single] -> Single;
        Parts -> lists:foldl(fun joinCamel/2, "", Parts)
    end,
    list_to_atom(AtomStr).

%% @doc 将（已被 alLoop 归一化为 camelCase atom 键的）参数还原为 MCP Server
%% 期望的原始属性名（基于 inputSchema 的 properties）。
-spec restoreArgs(map(), map()) -> map().
restoreArgs(Args, Props) when is_map(Args), is_map(Props) ->
    Known = maps:fold(fun(OrigName, _Spec, Acc) ->
        Key = camelKey(toBin(OrigName)),
        case findArg(Key, OrigName, Args) of
            {ok, V} -> maps:put(toBin(OrigName), V, Acc);
            error -> Acc
        end
    end, #{}, Props),
    KnownCamelKeys = [camelKey(toBin(K)) || K <- maps:keys(Props)],
    Extra = maps:fold(fun(K, V, Acc) ->
        case lists:member(toCamelAtom(K), KnownCamelKeys) of
            true -> Acc;
            false -> maps:put(toBin(K), V, Acc)
        end
    end, #{}, Args),
    maps:merge(Extra, Known);
restoreArgs(Args, _Props) ->
    Args.

%%%===================================================================
%%% 内部辅助
%%%===================================================================

result(Msg) -> mapField(<<"result"/utf8>>, Msg, #{}).

mapField(Key, Map, Default) ->
    case maps:get(Key, Map, Default) of
        V when is_map(V) -> V;
        _ -> Default
    end.

listField(Key, Map) ->
    case maps:get(Key, Map, []) of
        L when is_list(L) -> L;
        _ -> []
    end.

maybeReply(undefined, _Reply) -> ok;
maybeReply(From, Reply) -> gen_server:reply(From, Reply).

%% 大小写不敏感的响应头查找。
headerValue(Name, Headers) ->
    Lower = string:lowercase(toBin(Name)),
    case lists:search(fun({K, _V}) -> string:lowercase(toBin(K)) =:= Lower end, Headers) of
        {value, {_K, V}} -> toBin(V);
        false -> undefined
    end.

findArg(Key, OrigName, Args) ->
    case maps:get(Key, Args, '$none') of
        '$none' ->
            case maps:get(toBin(OrigName), Args, '$none') of
                '$none' ->
                    case maps:get(toAtomSafe(OrigName), Args, '$none') of
                        '$none' -> error;
                        V -> {ok, V}
                    end;
                V -> {ok, V}
            end;
        V -> {ok, V}
    end.

toCamelAtom(K) when is_atom(K) -> K;
toCamelAtom(K) when is_binary(K) -> camelKey(K);
toCamelAtom(K) when is_list(K) -> camelKey(llmJson:text(K)).

toAtomSafe(K) when is_atom(K) -> K;
toAtomSafe(K) when is_binary(K) ->
    try binary_to_existing_atom(K, utf8) catch _:_ -> K end;
toAtomSafe(K) when is_list(K) ->
    try list_to_existing_atom(K) catch _:_ -> llmJson:text(K) end.

%% 生成稳定工具 atom：基于 Server 名与远程工具名的哈希，避免无界 atom 创建
toolAtom(ServerName, RemoteName) ->
    Hash = erlang:phash2({ServerName, RemoteName}),
    Bin = iolist_to_binary(["mcp", atom_to_list(ServerName), integer_to_list(Hash)]),
    binary_to_atom(Bin, utf8).

joinCamel("", Part) -> Part;
joinCamel(Acc, Part) -> Acc ++ capitalize(Part).

capitalize([C | Rest]) when C >= $a, C =< $z -> [C - ($a - $A) | Rest];
capitalize(S) -> S.

argsToJson(Args) when is_map(Args) -> Args;
argsToJson(_) -> #{}.

%% 归一化 tools/call 结果（提取文本内容便于模型阅读，同时保留原始结构）
normalizeResult(Result) when is_map(Result) ->
    Text = extractText(maps:get(<<"content"/utf8>>, Result, [])),
    Base = #{
        content => Result,
        isError => maps:get(<<"isError"/utf8>>, Result, false)
    },
    case Text of
        <<>> -> Base;
        _ -> Base#{text => Text}
    end;
normalizeResult(Other) ->
    #{content => Other}.

extractText(Content) when is_list(Content) ->
    Texts = lists:filtermap(fun
        (#{<<"type"/utf8>> := <<"text"/utf8>>, <<"text"/utf8>> := T}) -> {true, toBin(T)};
        (_) -> false
    end, Content),
    case Texts of
        [] -> <<>>;
        _ -> iolist_to_binary(lists:join(<<"\n">>, Texts))
    end;
extractText(_) -> <<>>.

closePort(undefined) -> ok;
closePort(Port) when is_port(Port) ->
    quiet(fun() -> port_close(Port) end),
    ok;
closePort(_) -> ok.

unregisterAll(ToolAtoms) ->
    lists:foreach(fun(T) -> quiet(fun() -> alTools:unregisterTool(T) end) end, ToolAtoms).

quiet(F) ->
    try F() catch _:_ -> ok end.

trim(Bin) ->
    re:replace(Bin, <<"^\\s+|\\s+$"/utf8>>, <<>>, [global, {return, binary}]).

atomBin(A) when is_atom(A) -> atom_to_binary(A, utf8);
atomBin(B) when is_binary(B) -> B.

toBin(X) when is_binary(X) -> X;
toBin(X) when is_atom(X) -> atom_to_binary(X, utf8);
toBin(X) when is_list(X) -> unicode:characters_to_binary(X);
toBin(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).

toStr(X) when is_list(X) -> X;
toStr(X) when is_binary(X) -> binary_to_list(X);
toStr(X) when is_atom(X) -> atom_to_list(X);
toStr(X) -> lists:flatten(io_lib:format("~p", [X])).
