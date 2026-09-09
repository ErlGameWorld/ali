%%%-------------------------------------------------------------------
%% @doc MCP 服务端（stdio 上的 JSON-RPC，Content-Length 分帧）。
%%
%% 独立启动：`erl -noshell -config config/sys.config -pa ... -s alMcp stdio`
%% @end
%%%-------------------------------------------------------------------

-module(alMcp).

-export([stdio/0, main/1]).
%% 测试导出
-export([handleRequest/2, safeHandleRequest/2, parseContentLength/1]).

-define(ProtocolVersion, <<"2024-11-05">>).
-define(MaxFrameBytes, 16 * 1024 * 1024).

%%--------------------------------------------------------------------
%% @doc
%% MCP 服务器 stdio 入口：完成应用初始化后进入 JSON-RPC 消息循环。
%%
%% @return `ok'（在 EOF 或读错误时退出）
%% @end
%%--------------------------------------------------------------------
stdio() ->
    _ = setup(),
    mcpLoop(#{initialized => false}).

%%--------------------------------------------------------------------
%% @doc
%% 命令行入口（escript 风格）：忽略参数并启动 stdio 服务。
%%
%% @param _Args 命令行参数（未使用）
%% @return {@link stdio/0} 的返回值
%% @end
%%--------------------------------------------------------------------
main(_Args) ->
    stdio().

%%--------------------------------------------------------------------
%% @doc
%% 应用启动初始化：确保 ali 应用全启动，并尝试连接 core 服务。
%%
%% @return `ok'
%% @end
%%--------------------------------------------------------------------
setup() ->
    application:ensure_all_started(ali),
    case alCoreClient:ensureAvailable() of
        ok -> ok;
        {error, Reason} ->
            logger:warning("alMcp: core unavailable, some tools will degrade: ~p", [Reason])
    end,
    ok.

%%--------------------------------------------------------------------
%% @doc
%% MCP 主消息循环：从 stdin 读取 JSON-RPC 消息并分发处理。
%%
%% 处理 `notifications/initialized' 后将 state 标记为已初始化；
%% 对其它请求调用 {@link handleRequest/2} 处理；EOF 或读错误时退出。
%%
%% @param State 服务端状态 map（包含 initialized 标志）
%% @return `ok'
%% @end
%%--------------------------------------------------------------------
mcpLoop(State) ->
    try mcpLoopInner(State)
    catch
        Class:Reason ->
            logger:error("alMcp loop crashed: ~p:~p", [Class, Reason]),
            ok
    end.

mcpLoopInner(State) ->
    case readMessage() of
        {ok, #{method := <<"notifications/initialized">>}} ->
            mcpLoopInner(State#{initialized => true});
        {ok, Request} ->
            Response = safeHandleRequest(Request, State),
            case Response of
                noreply -> mcpLoopInner(State);
                {ok, Reply} ->
                    writeMessage(Reply),
                    NewState = advanceState(State, Request),
                    mcpLoopInner(NewState)
            end;
        eof ->
            ok;
        {error, Reason} ->
            logger:error("alMcp read error: ~p", [Reason]),
            ok
    end.

%% 对 handleRequest 包 try/catch：异常时回 -32603 并继续主循环，
%% 避免单个坏请求击穿整个 MCP 会话。
safeHandleRequest(Request, State) ->
    try handleRequest(Request, State) of
        Result -> Result
    catch
        Class:Reason ->
            Id = requestId(Request),
            logger:error("alMcp handleRequest crashed: ~p:~p", [Class, Reason]),
            {ok, jsonrpcError(Id, -32603, <<"Internal error">>, toBinary({Class, Reason}))}
    end.

requestId(#{id := Id}) -> Id;
requestId(#{<<"id">> := Id}) -> Id;
requestId(_) -> null.

%%--------------------------------------------------------------------
%% @doc
%% 根据请求推进服务端状态（多子句）：
%%  - `initialize' 请求将状态标记为已初始化
%%  - 其它请求保持状态不变
%%
%% @param State 当前状态
%% @param Request 当前请求
%% @return 更新后的状态 map
%% @end
%%--------------------------------------------------------------------
advanceState(State, #{method := <<"initialize">>}) ->
    State#{initialized => true};
advanceState(State, _Request) ->
    State.

%%--------------------------------------------------------------------
%% @doc
%% JSON-RPC 请求分发器（多子句）：
%%  - `initialize'：返回协议版本与服务器能力
%%  - `tools/list'：返回工具目录
%%  - `tools/call'：调用指定工具并返回结果
%%  - `resources/list'：返回资源列表
%%  - `resources/read'：读取指定资源
%%  - `prompts/list'：返回提示列表
%%  - `prompts/get'：渲染指定提示
%%  - `ping'：返回空成功响应
%%  - 未知方法：返回 -32601 错误
%%  - 无 id 的请求：返回 noreply
%%
%% @param Request JSON-RPC 请求 map
%% @param State 当前状态
%% @return `{ok, Reply}' | `noreply'
%% @end
%%--------------------------------------------------------------------
handleRequest(Req0, State) when is_map(Req0) ->
    %% jiffy return_maps 键为 binary；统一顶层 JSON-RPC 键为 atom 再分派。
    handleRequestNormalized(normalizeRpcRequest(Req0), State);
handleRequest(_Request, _State) ->
    noreply.

handleRequestNormalized(#{method := <<"initialize">>, id := Id} = _Req, _State) ->
    Result = #{
        protocolVersion => ?ProtocolVersion,
        capabilities => #{tools => #{}, resources => #{}, prompts => #{}},
        serverInfo => #{name => <<"ali">>, version => <<"0.1.0">>}
    },
    {ok, jsonrpcResult(Id, Result)};
handleRequestNormalized(#{method := <<"tools/list">>, id := Id}, _State) ->
    {ok, jsonrpcResult(Id, #{tools => alToolCatalog:mcpTools()})};
handleRequestNormalized(#{method := <<"tools/call">>, id := Id, params := Params}, _State)
  when is_map(Params) ->
    case maps:get(<<"name">>, Params, maps:get(name, Params, undefined)) of
        undefined ->
            {ok, jsonrpcError(Id, -32602, <<"Invalid params">>, <<"missing tool name">>)};
        Name ->
            case maps:get(<<"arguments">>, Params, maps:get(arguments, Params, #{})) of
                Args0 when is_map(Args0) ->
                    Args = normalizeArgs(Args0),
                    doCallTool(Id, Name, Args, Params);
                _ ->
                    {ok, jsonrpcError(Id, -32602, <<"Invalid params">>,
                                      <<"arguments must be an object">>)}
            end
    end;
handleRequestNormalized(#{method := <<"tools/call">>, id := Id}, _State) ->
    {ok, jsonrpcError(Id, -32602, <<"Invalid params">>, <<"missing params">>)};
handleRequestNormalized(#{method := <<"resources/list">>, id := Id}, _State) ->
    {ok, jsonrpcResult(Id, #{resources => alToolCatalog:mcpResources()})};
handleRequestNormalized(#{method := <<"resources/read">>, id := Id, params := Params}, _State)
  when is_map(Params) ->
    Uri = maps:get(<<"uri">>, Params, maps:get(uri, Params, <<>>)),
    case alToolCatalog:mcpResourceRead(Uri) of
        {ok, Contents} ->
            {ok, jsonrpcResult(Id, #{contents => [Contents]})};
        {error, Reason} ->
            {ok, jsonrpcError(Id, -32602, <<"resource read failed">>, encodeResult(#{reason => Reason}))}
    end;
handleRequestNormalized(#{method := <<"resources/read">>, id := Id}, _State) ->
    {ok, jsonrpcError(Id, -32602, <<"Invalid params">>, <<"missing params">>)};
handleRequestNormalized(#{method := <<"prompts/list">>, id := Id}, _State) ->
    {ok, jsonrpcResult(Id, #{prompts => alToolCatalog:mcpPrompts()})};
handleRequestNormalized(#{method := <<"prompts/get">>, id := Id, params := Params}, _State) ->
    Name = maps:get(<<"name">>, Params, maps:get(name, Params, <<>>)),
    Args = maps:get(<<"arguments">>, Params, maps:get(arguments, Params, #{})),
    case alToolCatalog:mcpPromptGet(Name, Args) of
        {ok, Result} ->
            {ok, jsonrpcResult(Id, Result)};
        {error, Reason} ->
            {ok, jsonrpcError(Id, -32602, <<"prompt render failed">>, encodeResult(#{reason => Reason}))}
    end;
handleRequestNormalized(#{method := <<"ping">>, id := Id}, _State) ->
    {ok, jsonrpcResult(Id, #{})};
handleRequestNormalized(#{method := Method, id := Id}, _State) when is_binary(Method) ->
    {ok, jsonrpcError(Id, -32601, <<"Method not found">>, Method)};
handleRequestNormalized(#{id := Id}, _State) ->
    {ok, jsonrpcError(Id, -32600, <<"Invalid request">>, null)};
handleRequestNormalized(_Request, _State) ->
    noreply.

%% 顶层 JSON-RPC 键：binary → atom（兼容手写 atom 键测试）。
normalizeRpcRequest(Map) when is_map(Map) ->
    maps:from_list([{rpcTopKey(K), V} || {K, V} <- maps:to_list(Map)]);
normalizeRpcRequest(Other) ->
    Other.

rpcTopKey(<<"jsonrpc">>) -> jsonrpc;
rpcTopKey(<<"method">>) -> method;
rpcTopKey(<<"id">>) -> id;
rpcTopKey(<<"params">>) -> params;
rpcTopKey(<<"result">>) -> result;
rpcTopKey(<<"error">>) -> error;
rpcTopKey(K) when is_atom(K) -> K;
rpcTopKey(K) -> K.

%% tools/call 的实际执行：白名单校验 → 策略调用 → 结果编码。
doCallTool(Id, Name, Args, Params) ->
    Tool = case try binary_to_existing_atom(Name, utf8) catch _:_ -> error end of
        error -> Name;
        Atom -> Atom
    end,
    %% 白名单预校验：拒绝未在 alToolCatalog 中登记的工具名，
    %% 避免把任意输入直接传给 invoke 触发内部异常或 function_clause。
    case isKnownTool(Tool) of
        false ->
            {ok, jsonrpcError(Id, -32601, <<"Method not found">>,
                              <<"unknown tool: ", (toBinary(Name))/binary>>)};
        true ->
            Mode = mcpCallMode(Params, Args),
            Confirmed = maps:get(confirmed, Args, maps:get(<<"confirmed">>, Params, false)),
            CallOpts = #{mode => Mode, confirmed => Confirmed =:= true},
            CleanArgs = maps:without([mode, confirmed, policy], Args),
            case alToolCatalog:invoke(Tool, CleanArgs, CallOpts) of
                {ok, Value} ->
                    Content = [#{type => <<"text">>, text => encodeResult(#{status => ok, result => Value})}],
                    {ok, jsonrpcResult(Id, #{content => Content, isError => false})};
                {error, Reason} ->
                    Content = [#{type => <<"text">>, text => encodeResult(#{status => error, reason => Reason})}],
                    {ok, jsonrpcResult(Id, #{content => Content, isError => true})}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 递归规范化工具调用参数 map：将 binary 键转 atom（已存在时），递归处理嵌套 map/list。
%%
%% @param Map 输入 map 或其它值
%% @return 规范化后的 map（非 map 输入原样返回）
%% @end
%%--------------------------------------------------------------------
normalizeArgs(Map) when is_map(Map) ->
    maps:from_list([
        {normalizeKey(K), normalizeValue(V)} || {K, V} <- maps:to_list(Map)
    ]);
normalizeArgs(Other) ->
    Other.

%% 将 binary 键转为已存在的 atom，转换失败则保留原 binary；非 binary 原样返回。
normalizeKey(K) when is_binary(K) ->
    try binary_to_existing_atom(K, utf8) catch _:_ -> K end;
normalizeKey(K) -> K.

%% 递归规范化值：map 走 normalizeArgs，list 逐元素递归，其它原样返回。
normalizeValue(V) when is_map(V) -> normalizeArgs(V);
normalizeValue(V) when is_list(V) -> [normalizeValue(I) || I <- V];
normalizeValue(V) -> V.

%%--------------------------------------------------------------------
%% @doc
%% 判断 Tool 是否为 alToolCatalog 中已登记的工具。atom 直接查；
%% binary 尝试转 atom 再查；其它类型视为未知。
%%
%% @param Tool 工具名 atom 或 binary
%% @return boolean()
%% @end
%%--------------------------------------------------------------------

isKnownTool(Tool) when is_atom(Tool) ->
    lists:member(Tool, alToolCatalog:allTools());
isKnownTool(Tool) when is_binary(Tool) ->
    try binary_to_existing_atom(Tool, utf8) of
        Atom -> lists:member(Atom, alToolCatalog:allTools())
    catch
        _:_ -> false
    end;
isKnownTool(_) ->
    false.

%%--------------------------------------------------------------------
%% @doc
%% 将任意值转为 binary：binary 原样、atom 转 utf8 binary、list 走 unicode。
%%
%% @param V 任意值
%% @return binary()
%% @end
%%--------------------------------------------------------------------
toBinary(V) when is_binary(V) -> V;
toBinary(V) when is_atom(V) -> atom_to_binary(V, utf8);
toBinary(V) when is_list(V) ->
    case unicode:characters_to_binary(V) of
        B when is_binary(B) -> B;
        _ -> iolist_to_binary(io_lib:format("~p", [V]))
    end;
toBinary(V) -> iolist_to_binary(io_lib:format("~p", [V])).

%%--------------------------------------------------------------------
%% @doc
%% 构造 JSON-RPC 成功响应 map。
%%
%% @param Id 请求 ID
%% @param Result 结果数据
%% @return `#{jsonrpc, id, result}' map
%% @end
%%--------------------------------------------------------------------
jsonrpcResult(Id, Result) ->
    #{
        jsonrpc => <<"2.0">>,
        id => Id,
        result => Result
    }.

%%--------------------------------------------------------------------
%% @doc
%% 构造 JSON-RPC 错误响应 map。
%%
%% @param Id 请求 ID
%% @param Code 错误码（如 -32601 method not found）
%% @param Message 错误描述
%% @param Data 附加数据
%% @return `#{jsonrpc, id, error => #{code, message, data}}' map
%% @end
%%--------------------------------------------------------------------
jsonrpcError(Id, Code, Message, Data) ->
    #{
        jsonrpc => <<"2.0">>,
        id => Id,
        error => #{
            code => Code,
            message => Message,
            data => Data
        }
    }.

%%--------------------------------------------------------------------
%% @doc
%% 将工具调用结果编码为 JSON 文本；编码失败时退化为 `~p' 格式化字符串。
%%
%% @param Term 任意 Erlang 项
%% @return UTF-8 binary
%% @end
%%--------------------------------------------------------------------
encodeResult(Term) ->
    try alJson:encode(Term)
    catch _:_ ->
        unicode:characters_to_binary(io_lib:format("~p", [Term]))
    end.

%% tools/call 模式：params.mode / _meta.mode / arguments.mode / cfg mcp.defaultMode
mcpCallMode(Params, Args) when is_map(Params), is_map(Args) ->
    Candidates = [
        maps:get(mode, Args, undefined),
        maps:get(<<"mode">>, Params, undefined),
        begin
            Meta = maps:get(<<"_meta">>, Params, maps:get('_meta', Params, #{})),
            case is_map(Meta) of
                true -> maps:get(<<"mode">>, Meta, maps:get(mode, Meta, undefined));
                false -> undefined
            end
        end
    ],
    case firstMode(Candidates) of
        undefined ->
            case alConfig:get(mcp, #{}) of
                #{defaultMode := M} when M =:= ask; M =:= edit; M =:= exec -> M;
                _ -> ask
            end;
        Mode -> Mode
    end.

firstMode([]) -> undefined;
firstMode([undefined | Rest]) -> firstMode(Rest);
firstMode([ask | _]) -> ask;
firstMode([edit | _]) -> edit;
firstMode([exec | _]) -> exec;
firstMode([<<"ask">> | _]) -> ask;
firstMode([<<"edit">> | _]) -> edit;
firstMode([<<"exec">> | _]) -> exec;
firstMode([_ | Rest]) -> firstMode(Rest).

%%--------------------------------------------------------------------
%% @doc
%% 从 stdin 读取一条 MCP 消息（基于 Content-Length 帧格式）。
%%
%% 依次读取头部行、空行、指定长度的 body，再交由 {@link decodeBody/1} 解析。
%%
%% @return `{ok, Map}' | `eof' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
readMessage() ->
    case io:get_line(standard_input, "") of
        eof ->
            eof;
        {error, Reason} ->
            {error, Reason};
        "Content-Length: " ++ Rest ->
            [LenStr | _] = string:split(Rest, "\r\n", all),
            case parseContentLength(string:trim(LenStr)) of
                {ok, Len} when Len >= 0, Len =< ?MaxFrameBytes ->
                    case readMessageHeader() of
                        {ok, _Hdr} ->
                            case file:read(standard_input, Len) of
                                {ok, Body} -> decodeBody(Body);
                                {error, ReadReason} -> {error, {readBody, ReadReason}}
                            end;
                        eof ->
                            eof;
                        {error, HeaderReason} ->
                            {error, {readHeader, HeaderReason}}
                    end;
                _ ->
                    {error, badFrame}
            end;
        _ ->
            {error, badFrame}
    end.

%% 读取空行（header 结束标志），缺行时安全返回 eof/error，不裸匹配崩溃。
readMessageHeader() ->
    case file:read_line(standard_input) of
        {ok, _Hdr} -> {ok, _Hdr};
        eof -> eof;
        {error, Reason} -> {error, Reason}
    end.

%% 解析 Content-Length 头值；非整数输入返回 error。
parseContentLength(Str) ->
    try list_to_integer(Str) of
        N when N >= 0 -> {ok, N};
        _ -> error
    catch
        _:_ -> error
    end.

%%--------------------------------------------------------------------
%% @doc
%% 解析 JSON-RPC 请求 body；解析失败或非 map 时返回错误。
%%
%% @param Body JSON 二进制
%% @return `{ok, Map}' | `{error, invalidJson}'
%% @end
%%--------------------------------------------------------------------
decodeBody(Body) ->
    try alJson:decode(Body) of
        Map when is_map(Map) -> {ok, Map}
    catch
        _:_ -> {error, invalidJson}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 向 stdout 写入一条 MCP 响应消息（带 Content-Length 帧）。
%%
%% @param Map 响应 map
%% @return `ok'
%% @end
%%--------------------------------------------------------------------
writeMessage(Map) ->
    Body = alJson:encode(Map),
    io:format(standard_output, "Content-Length: ~p\r\n\r\n~s", [byte_size(Body), Body]),
    ok.
