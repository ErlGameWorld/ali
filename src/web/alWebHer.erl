%%%-------------------------------------------------------------------
%%% @doc Web UI HTTP 请求处理器（eWSrv wsMod 回调）。
%%%
%%% 提供 REST API（/api/ask、/api/status 等）和静态页面服务。
%%% 所有 Agent 操作通过 {@link ali} 模块完成。
%%%
%%% 若配置了 `webApiToken`，除静态资源外需在 URL 携带 `?token=...`。
%%% @end
%%%-------------------------------------------------------------------
-module(alWebHer).

-export([init/1, handle/3]).

%% @doc eWSrv 初始化回调，无状态。
-spec init(any()) -> {ok, []}.
init(_Args) ->
    {ok, []}.

%% @doc eWSrv 请求入口：认证校验后路由，异常统一返回 500 JSON。
-spec handle(atom(), binary(), term()) -> term().
handle(Method, Path, WsReq) ->
    try
        case check_auth(Method, Path, WsReq) of
            ok -> route(Method, Path, WsReq);
            {error, unauthorized} -> json_response(401, #{error => <<"unauthorized"/utf8>>})
        end
    catch
        Class:Reason:Stack ->
            %% 堆栈仅记录到日志，不返回给客户端避免信息泄露
            error_logger:format("~p:~p ~p~n~p~n", [Class, Reason, ?MODULE, Stack]),
            Err = #{
                error => list_to_binary(io_lib:format("~p:~p", [Class, Reason]))
            },
            json_response(500, Err)
    end.

%%%===================================================================
%%% 路由表
%%%===================================================================

%% @doc 按 HTTP 方法与路径分发请求到对应处理函数。
route('GET', <<"/"/utf8>>, _WsReq) ->
    %% GET / — Web UI 首页
    serve_priv(<<"web/index.html"/utf8>>, <<"text/html; charset=utf-8"/utf8>>);
route('GET', <<"/static/", Rest/binary>>, _WsReq) ->
    %% GET /static/* — 静态资源（CSS/JS/图片）
    serve_priv(<<"web/static/", Rest/binary>>, content_type(Rest));
route('GET', <<"/api/health"/utf8>>, _WsReq) ->
    %% GET /api/health — 健康检查
    json_response(200, ali:health());
route('GET', <<"/api/status"/utf8>>, _WsReq) ->
    %% GET /api/status — Agent 与 Web 服务状态
    Status = safe_status(),
    json_response(200, Status);
route('GET', <<"/api/tools"/utf8>>, _WsReq) ->
    %% GET /api/tools — 可用工具列表
    json_response(200, #{tools => alTools:listTools()});
route('GET', <<"/api/sessions"/utf8>>, _WsReq) ->
    %% GET /api/sessions — 已保存会话列表
    handle_sessions();
route('POST', <<"/api/sessions/load"/utf8>>, WsReq) ->
    %% POST /api/sessions/load — 加载指定会话
    handle_session_load(WsReq);
route('POST', <<"/api/sessions/delete"/utf8>>, WsReq) ->
    %% POST /api/sessions/delete — 删除已保存会话
    handle_session_delete(WsReq);
route('GET', <<"/api/audit"/utf8>>, _WsReq) ->
    %% GET /api/audit — 审计日志（最近 100 条）
    json_response(200, #{entries => [sanitize_map(E) || E <- ali:auditLog(100)]});
route('POST', <<"/api/audit/clear"/utf8>>, _WsReq) ->
    %% POST /api/audit/clear — 清空审计日志
    ok = ali:auditClear(),
    json_response(200, #{ok => true});
route('GET', <<"/api/tokenStats"/utf8>>, _WsReq) ->
    %% GET /api/tokenStats — LLM Token 用量统计
    json_response(200, sanitize_map(ali:tokenStats()));
route('POST', <<"/api/tokenStats/reset"/utf8>>, _WsReq) ->
    %% POST /api/tokenStats/reset — 重置 Token 统计
    ok = ali:resetTokenStats(),
    json_response(200, #{ok => true});
route('POST', <<"/api/ask"/utf8>>, WsReq) ->
    %% POST /api/ask — 同步问答
    handle_ask(WsReq);
route('POST', <<"/api/ask/start"/utf8>>, WsReq) ->
    %% POST /api/ask/start — 启动异步问答任务
    handle_ask_start(WsReq);
route('GET', <<"/api/ask/status/", TaskId/binary>>, WsReq) ->
    %% GET /api/ask/status/:taskId — 查询异步任务进度
    handle_ask_status(TaskId, WsReq);
route('POST', <<"/api/ask/stream"/utf8>>, WsReq) ->
    %% POST /api/ask/stream — SSE 流式问答（JSON body）
    handle_ask_stream(WsReq);
route('GET', <<"/api/ask/stream"/utf8>>, WsReq) ->
    %% GET /api/ask/stream — SSE 流式问答（EventSource，query 传参）
    handle_ask_stream_get(WsReq);
route('POST', <<"/api/clear"/utf8>>, _WsReq) ->
    %% POST /api/clear — 清空当前 Agent 会话
    _ = safe_clear(),
    json_response(200, #{ok => true});
route('POST', <<"/api/index/refresh"/utf8>>, _WsReq) ->
    %% POST /api/index/refresh — 刷新代码索引
    case safe_refresh_index() of
        {ok, R} -> json_response(200, maps:merge(#{ok => true}, R));
        {error, R} -> json_response(500, #{ok => false, error => format_term(R)})
    end;
route('POST', <<"/api/mode"/utf8>>, WsReq) ->
    %% POST /api/mode — 切换 Agent 模式（ask/edit/exec）
    handle_mode(WsReq);
route('POST', <<"/api/eunit/run"/utf8>>, WsReq) ->
    %% POST /api/eunit/run — 运行 EUnit 测试
    handle_eunit(runEunit, WsReq);
route('POST', <<"/api/eunit/generate"/utf8>>, WsReq) ->
    %% POST /api/eunit/generate — 生成 EUnit 测试
    handle_eunit(generateEunit, WsReq);
route('POST', <<"/api/ct/run"/utf8>>, WsReq) ->
    handle_ct(runCommonTest, WsReq);
route('POST', <<"/api/ct/generate"/utf8>>, WsReq) ->
    handle_ct(generateCommonTest, WsReq);
route('GET', <<"/api/tasks"/utf8>>, _WsReq) ->
    ensure_agent(),
    Tasks = [sanitize_map(T) || T <- alTask:list()],
    json_response(200, #{tasks => Tasks, count => length(Tasks)});
route('POST', <<"/api/tasks/cancel"/utf8>>, WsReq) ->
    Body = decode_json(eWSrv:body(WsReq)),
    TaskId = maps:get(<<"taskId"/utf8>>, Body, undefined),
    case TaskId of
        undefined -> json_response(400, #{error => <<"missing taskId"/utf8>>});
        _ ->
            case ali:cancelTask(TaskId) of
                ok -> json_response(200, #{ok => true});
                {error, R} -> json_response(500, #{ok => false, error => format_term(R)})
            end
    end;
route('POST', <<"/api/approve"/utf8>>, WsReq) ->
    %% POST /api/approve — 批准待确认操作
    handle_approve(WsReq);
route('GET', <<"/api/backups"/utf8>>, WsReq) ->
    %% GET /api/backups?path=src/foo.erl — 列出文件备份（只读）
    handle_list_backups(WsReq);
route('POST', <<"/api/format"/utf8>>, WsReq) ->
    %% POST /api/format — 格式化 .erl 文件（需 edit 模式）
    handle_format_code(WsReq);
route(_Method, _Path, _WsReq) ->
    %% 未匹配路由 — 404
    json_response(404, #{error => <<"not_found"/utf8>>}).

%%%===================================================================
%%% 认证
%%%===================================================================

%% @doc 校验 webApiToken；静态资源与首页免认证。
check_auth('GET', <<"/static/", _/binary>>, _WsReq) -> ok;
check_auth('GET', <<"/"/utf8>>, _WsReq) -> ok;
check_auth(_Method, _Path, WsReq) ->
    case application:get_env(ali, webApiToken, <<>>) of
        <<>> -> ok;
        <<"", _/binary>> -> ok;
        Token ->
            Provided = web_api_token(WsReq),
            case Provided =/= undefined andalso to_binary(Provided) =:= Token of
                true -> ok;
                false -> {error, unauthorized}
            end
    end.

%% 从 Authorization Bearer 或 query token 获取 API 令牌。
web_api_token(WsReq) ->
    case bearer_token(WsReq) of
        undefined ->
            Args = eWSrv:args(WsReq),
            case proplists:get_value(<<"token"/utf8>>, Args) of
                undefined -> proplists:get_value("token", Args, undefined);
                V -> V
            end;
        Bearer ->
            Bearer
    end.

bearer_token(WsReq) ->
    Headers = eWSrv:headers(WsReq),
    Auth = proplists:get_value(<<"authorization"/utf8>>, Headers,
        proplists:get_value("authorization", Headers, <<>>)),
    case to_binary(Auth) of
        <<"Bearer ", Rest/binary>> -> Rest;
        <<"bearer ", Rest/binary>> -> Rest;
        _ -> undefined
    end.

%%%===================================================================
%%% API 处理函数
%%%===================================================================

%% @doc 同步问答：解析 prompt，调用 ali:ask/2 返回完整回答。
handle_ask(WsReq) ->
    Body = eWSrv:body(WsReq),
    Decoded = decode_json(Body),
    Prompt = maps:get(<<"prompt"/utf8>>, Decoded, undefined),
    SessionId = maps:get(<<"sessionId"/utf8>>, Decoded, <<"web"/utf8>>),
    case Prompt of
        undefined ->
            json_response(400, #{error => <<"missing prompt"/utf8>>});
        _ ->
            ensure_agent(),
            case ali:ask(Prompt, #{sessionId => SessionId}) of
                {ok, Answer} ->
                    json_response(200, #{
                        ok => true,
                        answer => Answer,
                        sessionId => SessionId
                    });
                {error, Reason} ->
                    json_response(500, #{ok => false, error => format_error(Reason)})
            end
    end.

%% @doc 异步问答：返回 taskId，客户端轮询 /api/ask/status。
handle_ask_start(WsReq) ->
    Body = decode_json(eWSrv:body(WsReq)),
    Prompt = maps:get(<<"prompt"/utf8>>, Body, undefined),
    SessionId = maps:get(<<"sessionId"/utf8>>, Body, <<"web"/utf8>>),
    case Prompt of
        undefined ->
            json_response(400, #{error => <<"missing prompt"/utf8>>});
        _ ->
            ensure_agent(),
            case ali:askAsync(Prompt, #{sessionId => SessionId}) of
                {ok, TaskId} ->
                    json_response(200, #{
                        ok => true,
                        taskId => TaskId,
                        sessionId => SessionId
                    });
                {error, Reason} ->
                    json_response(500, #{ok => false, error => format_error(Reason)})
            end
    end.

%% @doc 查询异步任务状态与增量事件（支持 since 参数）。
handle_ask_status(TaskId, WsReq) ->
    CleanId = clean_task_id(TaskId),
    Since = parse_since(WsReq),
    Snap = alProgress:snapshot(CleanId, Since),
    case maps:get(status, Snap, not_found) of
        not_found ->
            reply_task_fallback(CleanId);
        Status ->
            reply_progress_snapshot(Status, Snap)
    end.

%% @doc 将进度快照格式化为 JSON 响应。
reply_progress_snapshot(Status, Snap) ->
    Resp = #{
        ok => true,
        status => atom_to_binary(Status, utf8),
        events => [sanitize_map(E) || E <- maps:get(events, Snap, [])],
        eventCount => maps:get(eventCount, Snap, 0)
    },
    Resp1 = case maps:get(result, Snap, undefined) of
        {ok, Answer} when Status =:= completed ->
            Resp#{answer => Answer};
        {error, Reason} when Status =:= failed ->
            Resp#{error => format_error(Reason)};
        _ ->
            Resp
    end,
    json_response(200, Resp1).

%% @doc 进度表无记录时的回退查询（alTask 或空 running）。
reply_task_fallback(TaskId) ->
    case alProgress:snapshot(TaskId, 0) of
        #{status := running, eventCount := C} when C > 0 ->
            reply_progress_snapshot(running, alProgress:snapshot(TaskId, 0));
        #{status := completed} = Snap ->
            reply_progress_snapshot(completed, Snap);
        #{status := failed} = Snap ->
            reply_progress_snapshot(failed, Snap);
        _ ->
            fallback_task_status(TaskId)
    end.

%% @doc 从 alTask 进程查询任务最终状态（兜底路径）。
fallback_task_status(TaskId) ->
    case alTask:status(TaskId) of
        {ok, #{status := running}} ->
            json_response(200, #{
                ok => true,
                status => <<"running"/utf8>>,
                events => [],
                eventCount => 0
            });
        {ok, #{status := completed, result := {ok, Answer}}} ->
            json_response(200, #{
                ok => true,
                status => <<"completed"/utf8>>,
                answer => Answer,
                events => [],
                eventCount => 0
            });
        {ok, #{status := failed, result := {error, Reason}}} ->
            json_response(200, #{
                ok => true,
                status => <<"failed"/utf8>>,
                error => format_error(Reason),
                events => [],
                eventCount => 0
            });
        _ ->
            json_response(404, #{ok => false, error => <<"task_not_found"/utf8>>})
    end.

%% @doc 从请求 query 解析 since 事件偏移量。
parse_since(WsReq) ->
    Args = eWSrv:args(WsReq),
    parse_since_args(Args).

%% 从参数列表提取 since 值。
parse_since_args(Args) when is_list(Args) ->
    case proplists:get_value(<<"since"/utf8>>, Args) of
        undefined ->
            case proplists:get_value("since", Args) of
                undefined -> 0;
                V -> parse_since_value(V)
            end;
        V ->
            parse_since_value(V)
    end;
parse_since_args(_) ->
    0.

%% 将 since 值规范化为非负整数。
parse_since_value(V) when is_integer(V) -> V;
parse_since_value(V) when is_binary(V) -> parse_int(binary_to_list(V), 0);
parse_since_value(V) when is_list(V) -> parse_int(V, 0);
parse_since_value(_) -> 0.

%% @doc 去除 taskId 中附带的 query 字符串。
clean_task_id(TaskId) when is_binary(TaskId) ->
    case binary:split(TaskId, <<"?"/utf8>>, []) of
        [Id | _] -> Id;
        _ -> TaskId
    end;
clean_task_id(TaskId) ->
    clean_task_id(to_binary(TaskId)).

%% 安全解析整数字符串，失败返回默认值。
parse_int(Str, Default) ->
    try list_to_integer(Str) of
        N when N >= 0 -> N;
        _ -> Default
    catch
        _:_ -> Default
    end.

%% @doc 切换 Agent 运行模式（ask / edit / exec）。
handle_mode(WsReq) ->
    Body = decode_json(eWSrv:body(WsReq)),
    Mode = maps:get(<<"mode"/utf8>>, Body, undefined),
    case Mode of
        <<"ask"/utf8>> -> set_mode(ask);
        <<"edit"/utf8>> -> set_mode(edit);
        <<"exec"/utf8>> -> set_mode(exec);
        _ -> json_response(400, #{error => <<"invalid mode"/utf8>>})
    end.

%% 设置模式并返回 JSON 确认。
set_mode(Mode) ->
    case ali:setMode(Mode) of
        ok -> json_response(200, #{ok => true, mode => atom_to_binary(Mode, utf8)});
        {error, R} -> json_response(500, #{ok => false, error => format_term(R)})
    end.

%% @doc 运行或生成 EUnit / Common Test。
handle_eunit(Fun, WsReq) ->
    run_test_tool(Fun, WsReq).

handle_ct(Fun, WsReq) ->
    run_test_tool(Fun, WsReq).

run_test_tool(Fun, WsReq) ->
    Body = decode_json(eWSrv:body(WsReq)),
    Module = maps:get(<<"module"/utf8>>, Body, <<"all"/utf8>>),
    Config = case ali:getConfig() of
        C when is_map(C) -> C;
        _ -> #{}
    end,
    Args = case Module of
        <<"all"/utf8>> -> #{};
        M -> #{module => binary_to_atom(M, utf8)}
    end,
    case alToolTest:Fun(Args, Config) of
        {ok, R} -> json_response(200, maps:merge(#{ok => true}, sanitize_map(R)));
        {error, R} -> json_response(500, #{ok => false, error => format_term(R)})
    end.

%% @doc 批准待确认的 Agent 操作（如写文件）。
handle_approve(WsReq) ->
    Body = decode_json(eWSrv:body(WsReq)),
    TaskId = maps:get(<<"taskId"/utf8>>, Body, undefined),
    case TaskId of
        undefined ->
            json_response(400, #{error => <<"missing taskId"/utf8>>});
        _ ->
            case ali:approve(TaskId) of
                {ok, R} -> json_response(200, #{ok => true, result => sanitize_map(R)});
                {error, R} -> json_response(500, #{ok => false, error => format_term(R)})
            end
    end.

%% @doc 列出指定文件的备份记录（只读，无需 edit 模式）。
handle_list_backups(WsReq) ->
    Qs = eWSrv:parseQs(WsReq),
    Path = proplists:get_value(<<"path"/utf8>>, Qs, undefined),
    case Path of
        undefined ->
            json_response(400, #{error => <<"missing path"/utf8>>});
        _ ->
            Args = #{path => Path},
            case alToolEdit:listBackups(Args, #{}) of
                {ok, R} -> json_response(200, maps:merge(#{ok => true}, sanitize_map(R)));
                {error, R} -> json_response(500, #{ok => false, error => format_term(R)})
            end
    end.

%% @doc 格式化 .erl 文件（需 edit 模式，会原地覆盖并备份）。
handle_format_code(WsReq) ->
    Body = decode_json(eWSrv:body(WsReq)),
    Path = maps:get(<<"path"/utf8>>, Body, undefined),
    Backup = maps:get(<<"backup"/utf8>>, Body, true),
    case Path of
        undefined ->
            json_response(400, #{error => <<"missing path"/utf8>>});
        _ ->
            Args = #{path => Path, backup => Backup},
            case alToolEdit:formatCode(Args, #{}) of
                {ok, R} -> json_response(200, maps:merge(#{ok => true}, sanitize_map(R)));
                {error, notErlangFile} ->
                    json_response(400, #{ok => false, error => <<"notErlangFile"/utf8>>});
                {error, fileNotFound} ->
                    json_response(404, #{ok => false, error => <<"fileNotFound"/utf8>>});
                {error, R} ->
                    json_response(500, #{ok => false, error => format_term(R)})
            end
    end.

%% @doc 返回已保存会话列表与当前活跃会话数。
handle_sessions() ->
    ensure_agent(),
    Saved = ali:savedSessions(),
    AgentStatus = safe_status(),
    Current = maps:get(sessionCount, maps:get(agent, AgentStatus, #{}), 0),
    json_response(200, #{
        saved => Saved,
        currentCount => Current
    }).

%% @doc 从磁盘加载指定 sessionId 的会话。
handle_session_load(WsReq) ->
    Body = decode_json(eWSrv:body(WsReq)),
    SessionId = maps:get(<<"sessionId"/utf8>>, Body, undefined),
    case SessionId of
        undefined -> json_response(400, #{error => <<"missing sessionId"/utf8>>});
        _ ->
            ensure_agent(),
            case ali:loadSession(SessionId) of
                ok -> json_response(200, #{ok => true, sessionId => SessionId});
                {error, R} -> json_response(500, #{ok => false, error => format_term(R)})
            end
    end.

%% @doc 删除磁盘上已保存的会话文件。
handle_session_delete(WsReq) ->
    Body = decode_json(eWSrv:body(WsReq)),
    SessionId = maps:get(<<"sessionId"/utf8>>, Body, undefined),
    case SessionId of
        undefined -> json_response(400, #{error => <<"missing sessionId"/utf8>>});
        _ ->
            ensure_agent(),
            case ali:deleteSavedSession(SessionId) of
                ok -> json_response(200, #{ok => true, sessionId => SessionId});
                {error, R} -> json_response(500, #{ok => false, error => format_term(R)})
            end
    end.

%% @doc GET 版 SSE 流式问答（EventSource，prompt 通过 query 传递）。
handle_ask_stream_get(WsReq) ->
    Args = eWSrv:args(WsReq),
    Prompt = proplists:get_value(<<"prompt"/utf8>>, Args, proplists:get_value("prompt", Args, undefined)),
    SessionId = proplists:get_value(<<"sessionId"/utf8>>, Args, <<"web"/utf8>>),
    run_sse_chunked(Prompt, SessionId).

%% @doc POST 版 SSE 流式问答（JSON body 传 prompt）。
handle_ask_stream(WsReq) ->
    Body = decode_json(eWSrv:body(WsReq)),
    Prompt = maps:get(<<"prompt"/utf8>>, Body, undefined),
    SessionId = maps:get(<<"sessionId"/utf8>>, Body, <<"web"/utf8>>),
    run_sse_chunked(Prompt, SessionId).

%% @doc 启动 SSE chunked 响应：spawn 转发 alServer 流式分块。
run_sse_chunked(undefined, _SessionId) ->
    json_response(400, #{error => <<"missing prompt"/utf8>>});
run_sse_chunked(Prompt, SessionId) ->
    ensure_agent(),
    HandlerPid = self(),
    ProgressId = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    alProgress:start(ProgressId),
    spawn(fun() ->
        case whereis(alServer) of
            undefined ->
                alProgress:drop(ProgressId),
                HandlerPid ! {chunk, close};
            Server ->
                Opts = #{sessionId => SessionId, progressId => ProgressId},
                gen_server:cast(Server, {askStreamAsync, Prompt, Opts, self()}),
                Started = erlang:system_time(millisecond),
                forward_stream_chunks(HandlerPid, SessionId, ProgressId, 0, Started)
        end
    end),
    {chunk, [
        {<<"Content-Type"/utf8>>, <<"text/event-stream; charset=utf-8"/utf8>>},
        {<<"Cache-Control"/utf8>>, <<"no-cache"/utf8>>},
        {<<"Access-Control-Allow-Origin"/utf8>>, <<"*"/utf8>>}
    ]}.

%% 从 alServer 接收流式分块并编码为 SSE 事件推送给客户端。
forward_stream_chunks(HandlerPid, SessionId, ProgressId, ProgressIdx, StartedMs) ->
    receive
        {stream_chunk, done} ->
            NewIdx = forward_progress_events(HandlerPid, ProgressId, ProgressIdx),
            alProgress:drop(ProgressId),
            _ = NewIdx,
            DoneEvent = iolist_to_binary([<<"event: done\ndata: {\"sessionId\":\""/utf8>>, SessionId, <<"\"}\n\n"/utf8>>]),
            HandlerPid ! {chunk, DoneEvent},
            HandlerPid ! {chunk, close};
        {stream_chunk, Chunk} when is_binary(Chunk) ->
            Event = iolist_to_binary([<<"data: "/utf8>>, escape_sse_text(Chunk), <<"\n\n"/utf8>>]),
            HandlerPid ! {chunk, Event},
            forward_stream_chunks(HandlerPid, SessionId, ProgressId, ProgressIdx, StartedMs);
        {al, streamDone, done} ->
            forward_stream_chunks(HandlerPid, SessionId, ProgressId, ProgressIdx, StartedMs);
        _Other ->
            forward_stream_chunks(HandlerPid, SessionId, ProgressId, ProgressIdx, StartedMs)
    after 300 ->
        NewIdx = forward_progress_events(HandlerPid, ProgressId, ProgressIdx),
        case erlang:system_time(millisecond) - StartedMs > 600000 of
            true ->
                alProgress:drop(ProgressId),
                HandlerPid ! {chunk, close};
            false ->
                forward_stream_chunks(HandlerPid, SessionId, ProgressId, NewIdx, StartedMs)
        end
    end.

forward_progress_events(HandlerPid, ProgressId, Since) ->
    #{events := Events, eventCount := Total} = alProgress:snapshot(ProgressId, Since),
    lists:foreach(fun(E) ->
        Json = llmJson:encode(sanitize_map(E)),
        Event = iolist_to_binary([<<"event: progress\ndata: "/utf8>>, Json, <<"\n\n"/utf8>>]),
        HandlerPid ! {chunk, Event}
    end, Events),
    Total.

%% 转义 SSE data 字段中的换行符。
escape_sse_text(Bin) when is_binary(Bin) ->
    binary:replace(Bin, <<"\n"/utf8>>, <<"\ndata: "/utf8>>, [global]);
escape_sse_text(Other) ->
    escape_sse_text(to_binary(Other)).

%%%===================================================================
%%% 静态资源与 JSON 辅助
%%%===================================================================

%% @doc 从 priv 目录读取并返回静态文件。
serve_priv(RelPath, ContentType) ->
    Path = filename:join([code:priv_dir(ali), binary_to_list(RelPath)]),
    case file:read_file(Path) of
        {ok, Data} ->
            {ok, [{<<"Content-Type"/utf8>>, ContentType}], Data};
        {error, enoent} ->
            json_response(404, #{error => <<"file_not_found"/utf8>>});
        {error, Reason} ->
            json_response(500, #{error => format_term(Reason)})
    end.

%% @doc 根据文件扩展名返回 Content-Type。
content_type(Path) ->
    case filename:extension(binary_to_list(Path)) of
        ".css" -> <<"text/css; charset=utf-8"/utf8>>;
        ".js" -> <<"application/javascript; charset=utf-8"/utf8>>;
        ".svg" -> <<"image/svg+xml"/utf8>>;
        ".png" -> <<"image/png"/utf8>>;
        _ -> <<"application/octet-stream"/utf8>>
    end.

%% @doc 构造 JSON HTTP 响应（含 CORS 头）。
json_response(Code, Map) ->
    Body = llmJson:encode(sanitize_map(Map)),
    Headers = [
        {<<"Content-Type"/utf8>>, <<"application/json; charset=utf-8"/utf8>>},
        {<<"Access-Control-Allow-Origin"/utf8>>, <<"*"/utf8>>}
    ],
    {Code, Headers, Body}.

%% @doc 解析请求体 JSON；空体或解析失败返回空 map。
decode_json(Bin) when is_binary(Bin), byte_size(Bin) =:= 0 ->
    #{};
decode_json(Bin) when is_binary(Bin) ->
    try
        llmJson:decode(Bin)
    catch
        _:_ -> #{}
    end;
decode_json(_) ->
    #{}.

%% @doc 确保 alServer 已启动。
ensure_agent() ->
    case whereis(alServer) of
        undefined -> ali:start();
        _ -> ok
    end.

%% @doc 安全获取 Agent 状态（自动启动 Agent）。
safe_status() ->
    ensure_agent(),
    #{
        agent => ali:status(),
        webPort => alWebSrv:port(),
        node => atom_to_binary(node(), utf8)
    }.

%% @doc 安全清空当前会话。
safe_clear() ->
    ensure_agent(),
    ali:clearSession().

%% @doc 安全刷新代码索引。
safe_refresh_index() ->
    ensure_agent(),
    ali:refreshIndex().

%% @doc 递归清理 map/list 中的 atom 等不可 JSON 化类型。
sanitize_map(Map) when is_map(Map) ->
    maps:map(fun(_, V) -> sanitize_value(V) end, Map);
sanitize_map(Other) ->
  Other.

%% 清理单个值的类型以便 JSON 编码。
sanitize_value(V) when is_map(V) -> sanitize_map(V);
sanitize_value(V) when is_list(V) -> [sanitize_value(X) || X <- V];
sanitize_value(V) when is_atom(V) -> atom_to_binary(V, utf8);
sanitize_value(V) when is_binary(V); is_integer(V); is_float(V); is_boolean(V) -> V;
sanitize_value(V) -> format_term(V).

%% 将任意术语格式化为可读二进制字符串。
format_term(V) ->
    unicode:characters_to_binary(io_lib:format("~p", [V])).

%% @doc 将 Agent 错误转为用户友好的二进制消息。
format_error(maxStepsExceeded) ->
    <<"步数用尽：Web 会话已自动提升到 40 步。可清空会话后重试，或在 config.cfg 增加 maxSteps"/utf8>>;
format_error(V) when is_binary(V) -> V;
format_error(V) when is_atom(V) -> atom_to_binary(V, utf8);
format_error(V) -> format_term(V).

%% 多类型转 UTF-8 二进制。
to_binary(X) when is_binary(X) -> X;
to_binary(X) when is_list(X) -> unicode:characters_to_binary(X);
to_binary(X) when is_atom(X) -> atom_to_binary(X, utf8);
to_binary(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).