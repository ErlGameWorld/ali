%%%-------------------------------------------------------------------
%%% @doc Web UI HTTP 请求处理器（eWSrv wsMod 回调）。
%%%
%%% 提供 REST API（/api/ask、/api/status 等）和静态页面服务。
%%% 所有 Agent 操作通过 {@link ali} 模块完成。
%%%
%%% 安全加固（见 {@link alWebSec}）：
%%% <ul>
%%%   <li>认证：配置 `webApiToken' 后，除静态资源/首页/健康检查外均需
%%%       `Authorization: Bearer <token>' 或 `?token=<token>'（常数时间比较）；
%%%       未配置 token 时读请求放行，写请求仅限本地回环（可由 `webAllowRemoteWrites' 放开）。</li>
%%%   <li>CORS：按 `webAllowOrigin' 白名单放行（默认不放行跨源），支持 OPTIONS 预检。</li>
%%%   <li>速率限制：按来源 IP 固定窗口计数（`webRateLimit'/`webRateWindowMs'）。</li>
%%%   <li>安全头：nosniff / DENY frame / no-referrer；写请求记录来源 IP。</li>
%%% </ul>
%%% @end
%%%-------------------------------------------------------------------
-module(alWebHer).

-export([init/1, handle/3, handleWs/3, terminate/2, authDecision/4]).

%% WebSocket 操作码（对应 eWSrv.hrl，本地定义以避免引入记录定义冲突）
-define(WS_TEXT, 16#1).
-define(WS_BINARY, 16#2).
-define(WS_CLOSE, 16#8).
-define(WS_PING, 16#9).
-define(WS_PONG, 16#A).

%% @doc eWSrv 初始化回调，无状态。
-spec init(any()) -> {ok, []}.
init(_Args) ->
    {ok, []}.

%% @doc 连接进程退出时清理进程字典（wsHttp behavior 回调）。
-spec terminate(term(), []) -> ok.
terminate(_Reason, _WebState) ->
    erase(corsHeaders),
    erase(wsSocket),
    ok.

%% @doc eWSrv 请求入口：认证校验后路由，异常统一返回 500 JSON。
-spec handle(atom(), binary(), term()) -> term().
handle(Method, Path, WsReq) ->
    Ip = peerIp(WsReq),
    %% 计算并缓存本请求的 CORS 头（同进程，供 jsonResponse/SSE 复用）
    put(corsHeaders, alWebSec:corsHeaders(originHeader(WsReq))),
    try
        case Method of
            'OPTIONS' ->
                %% CORS 预检：免认证，仅回 CORS + 安全头
                preflightResponse();
            _ ->
                case alWebSec:checkRate(Ip) of
                    {error, rate_limited} ->
                        jsonResponse(429, #{error => <<"rate_limited"/utf8>>});
                    ok ->
                        case checkAuth(Method, Path, WsReq, Ip) of
                            ok ->
                                logRequest(Method, Path, Ip),
                                route(Method, Path, WsReq);
                            {error, unauthorized} ->
                                logDenied(Method, Path, Ip),
                                jsonResponse(401, #{error => <<"unauthorized"/utf8>>})
                        end
                end
        end
    catch
        _Class:_Reason:_Stack ->
            jsonResponse(500, #{error => <<"internal_error"/utf8>>})
    end.

%%%===================================================================
%%% 路由表
%%%===================================================================

%% @doc 按 HTTP 方法与路径分发请求到对应处理函数。
route('GET', <<"/"/utf8>>, _WsReq) ->
    %% GET / — Web UI 首页（注入公开 config JSON）
    serveIndex();
route('GET', <<"/static/", Rest/binary>>, _WsReq) ->
    %% GET /static/* — 静态资源（CSS/JS/图片）
    servePriv(<<"web/static/", Rest/binary>>, contentType(Rest));
route('GET', <<"/api/health"/utf8>>, _WsReq) ->
    %% GET /api/health — 健康检查
    jsonResponse(200, ali:health());
route('GET', <<"/api/status"/utf8>>, _WsReq) ->
    %% GET /api/status — Agent 与 Web 服务状态
    Status = safeStatus(),
    jsonResponse(200, Status);
route('GET', <<"/api/tools"/utf8>>, _WsReq) ->
    %% GET /api/tools — 可用工具列表
    jsonResponse(200, #{tools => alTools:listTools()});
route('GET', <<"/ws"/utf8>>, WsReq) ->
    %% GET /ws — WebSocket 升级（控制面 + 流式问答）
    wsUpgrade(WsReq);
route('GET', <<"/api/metrics"/utf8>>, _WsReq) ->
    %% GET /api/metrics — Agent 运行指标
    ensureAgent(),
    jsonResponse(200, sanitizeMap(ali:metrics()));
route('POST', <<"/api/metrics/reset"/utf8>>, _WsReq) ->
    ok = ali:resetMetrics(),
    jsonResponse(200, #{ok => true});
route('GET', <<"/api/plan"/utf8>>, WsReq) ->
    %% GET /api/plan?sessionId=web — 任务规划清单
    Args = eWSrv:args(WsReq),
    Sid = proplists:get_value(<<"sessionId"/utf8>>, Args,
            proplists:get_value("sessionId", Args, <<"web"/utf8>>)),
    jsonResponse(200, sanitizeMap(ali:plan(toBinary(Sid))));
route('GET', <<"/api/pending/", TaskId/binary>>, _WsReq) ->
    %% GET /api/pending/:taskId — 挂起任务预览（含 diff）
    ensureAgent(),
    case ali:pendingTask(cleanTaskId(TaskId)) of
        {ok, Preview} -> jsonResponse(200, maps:merge(#{ok => true}, sanitizeMap(Preview)));
        {error, _} -> jsonResponse(404, #{ok => false, error => <<"pending_not_found"/utf8>>})
    end;
route('POST', <<"/api/preview/patch"/utf8>>, WsReq) ->
    %% POST /api/preview/patch — 文本替换 diff 预览（只读）
    handlePreviewPatch(WsReq);
route('GET', <<"/api/sessions"/utf8>>, _WsReq) ->
    %% GET /api/sessions — 已保存会话列表
    handleSessions();
route('POST', <<"/api/sessions/save"/utf8>>, WsReq) ->
    handleSessionSave(WsReq);
route('GET', <<"/api/sessions/messages"/utf8>>, WsReq) ->
    handleSessionMessages(WsReq);
route('POST', <<"/api/sessions/load"/utf8>>, WsReq) ->
    %% POST /api/sessions/load — 加载指定会话
    handleSessionLoad(WsReq);
route('POST', <<"/api/sessions/delete"/utf8>>, WsReq) ->
    %% POST /api/sessions/delete — 删除已保存会话
    handleSessionDelete(WsReq);
route('GET', <<"/api/audit"/utf8>>, _WsReq) ->
    %% GET /api/audit — 审计日志（最近 100 条）
    jsonResponse(200, #{entries => [sanitizeMap(E) || E <- ali:auditLog(100)]});
route('POST', <<"/api/audit/clear"/utf8>>, _WsReq) ->
    %% POST /api/audit/clear — 清空审计日志
    ok = ali:auditClear(),
    jsonResponse(200, #{ok => true});
route('GET', <<"/api/tokenStats"/utf8>>, _WsReq) ->
    %% GET /api/tokenStats — LLM Token 用量统计
    jsonResponse(200, sanitizeMap(ali:tokenStats()));
route('POST', <<"/api/tokenStats/reset"/utf8>>, _WsReq) ->
    %% POST /api/tokenStats/reset — 重置 Token 统计
    ok = ali:resetTokenStats(),
    jsonResponse(200, #{ok => true});
route('POST', <<"/api/ask"/utf8>>, WsReq) ->
    %% POST /api/ask — 同步问答
    handleAsk(WsReq);
route('POST', <<"/api/ask/start"/utf8>>, WsReq) ->
    %% POST /api/ask/start — 启动异步问答任务
    handleAskStart(WsReq);
route('GET', <<"/api/ask/status/", TaskId/binary>>, WsReq) ->
    %% GET /api/ask/status/:taskId — 查询异步任务进度
    handleAskStatus(TaskId, WsReq);
route('POST', <<"/api/ask/stream"/utf8>>, WsReq) ->
    %% POST /api/ask/stream — SSE 流式问答（JSON body）
    handleAskStream(WsReq);
route('GET', <<"/api/ask/stream"/utf8>>, WsReq) ->
    %% GET /api/ask/stream — SSE 流式问答（EventSource，query 传参）
    handleAskStreamGet(WsReq);
route('POST', <<"/api/clear"/utf8>>, WsReq) ->
    Body = decodeJson(eWSrv:body(WsReq)),
    SessionId = maps:get(<<"sessionId"/utf8>>, Body, undefined),
    _ = safeClear(SessionId),
    jsonResponse(200, #{ok => true, sessionId => SessionId});
route('POST', <<"/api/ask/cancel"/utf8>>, WsReq) ->
    handleAskCancel(WsReq);
route('POST', <<"/api/index/refresh"/utf8>>, _WsReq) ->
    %% POST /api/index/refresh — 刷新代码索引
    case safeRefreshIndex() of
        {ok, R} -> jsonResponse(200, maps:merge(#{ok => true}, R));
        {error, R} -> jsonResponse(500, #{ok => false, error => formatTerm(R)})
    end;
route('POST', <<"/api/mode"/utf8>>, WsReq) ->
    %% POST /api/mode — 切换 Agent 模式（ask/edit/exec）
    handleMode(WsReq);
route('POST', <<"/api/eunit/run"/utf8>>, WsReq) ->
    %% POST /api/eunit/run — 运行 EUnit 测试
    handleEunit(runEunit, WsReq);
route('POST', <<"/api/eunit/generate"/utf8>>, WsReq) ->
    %% POST /api/eunit/generate — 生成 EUnit 测试
    handleEunit(generateEunit, WsReq);
route('POST', <<"/api/ct/run"/utf8>>, WsReq) ->
    handleCt(runCommonTest, WsReq);
route('POST', <<"/api/ct/generate"/utf8>>, WsReq) ->
    handleCt(generateCommonTest, WsReq);
route('GET', <<"/api/tasks"/utf8>>, _WsReq) ->
    ensureAgent(),
    Tasks = [sanitizeMap(T) || T <- alTask:list()],
    jsonResponse(200, #{tasks => Tasks, count => length(Tasks)});
route('POST', <<"/api/tasks/cancel"/utf8>>, WsReq) ->
    Body = decodeJson(eWSrv:body(WsReq)),
    TaskId = maps:get(<<"taskId"/utf8>>, Body, undefined),
    case TaskId of
        undefined -> jsonResponse(400, #{error => <<"missing taskId"/utf8>>});
        _ ->
            case ali:cancelTask(TaskId) of
                ok -> jsonResponse(200, #{ok => true});
                {error, R} -> jsonResponse(500, #{ok => false, error => formatTerm(R)})
            end
    end;
route('POST', <<"/api/approve"/utf8>>, WsReq) ->
    handleApprove(WsReq);
route('POST', <<"/api/dismiss"/utf8>>, WsReq) ->
    handleDismiss(WsReq);
route('GET', <<"/api/backups"/utf8>>, WsReq) ->
    %% GET /api/backups?path=src/foo.erl — 列出文件备份（只读）
    handleListBackups(WsReq);
route('POST', <<"/api/format"/utf8>>, WsReq) ->
    %% POST /api/format — 格式化 .erl 文件（需 edit 模式）
    handleFormatCode(WsReq);
route(_Method, _Path, _WsReq) ->
    %% 未匹配路由 — 404
    jsonResponse(404, #{error => <<"not_found"/utf8>>}).

%%%===================================================================
%%% 认证
%%%===================================================================

%% @doc 校验访问权限：静态资源、首页、健康检查免认证；其余按令牌与
%% 「写类/本地回环」规则鉴权。WebSocket 升级视为写能力（可执行控制命令）。
checkAuth('GET', <<"/static/", _/binary>>, _WsReq, _Ip) -> ok;
checkAuth('GET', <<"/"/utf8>>, _WsReq, _Ip) -> ok;
checkAuth('GET', <<"/api/health"/utf8>>, _WsReq, _Ip) -> ok;
checkAuth(Method, Path, WsReq, Ip) ->
    Protected = alWebSec:isProtectedPath(Method, Path),
    Token = configuredToken(),
    Provided = webApiToken(WsReq),
    authDecision(Protected, Token, Provided, Ip).

%% @doc 鉴权决策（纯函数，便于测试）。
%% - 配置了 token：任何受保护请求都必须提供匹配的 token（常数时间比较）。
%% - 未配置 token：非受保护请求放行；受保护请求仅允许本地回环（或显式放开远程写）。
-spec authDecision(boolean(), binary(), binary() | undefined, tuple() | undefined) ->
    ok | {error, unauthorized}.
authDecision(_Protected, Token, Provided, _Ip) when Token =/= <<>> ->
    case Provided =/= undefined andalso alWebSec:constantEq(toBinary(Provided), Token) of
        true -> ok;
        false -> {error, unauthorized}
    end;
authDecision(false, <<>>, _Provided, _Ip) ->
    ok;
authDecision(true, <<>>, _Provided, Ip) ->
    case alConfig:val(webAllowRemoteWrites) orelse alWebSec:isLoopback(Ip) of
        true -> ok;
        false -> {error, unauthorized}
    end.

%% 读取配置的 API 令牌（归一化为二进制，未配置/空值视为 <<>>）。
%% 注：配置 `{webApiToken, ""}'（空串即空列表）经配置归一化会变成 `#{}',
%% 这里统一把空 map/空列表/空串都当作「未配置」，避免误判为已启用且不可匹配的令牌。
configuredToken() ->
    case alConfig:val(webApiToken) of
        undefined -> <<>>;
        <<>> -> <<>>;
        [] -> <<>>;
        Map when is_map(Map), map_size(Map) =:= 0 -> <<>>;
        V -> toBinary(V)
    end.

%% CORS 预检响应：204 + CORS + 安全头。
preflightResponse() ->
    {204, corsHeaders() ++ alWebSec:securityHeaders(), <<>>}.

%% 从请求 socket 解析对端 IP（gen_tcp 或 ssl），失败返回 undefined。
peerIp(WsReq) ->
    try eWSrv:socket(WsReq) of
        Socket -> socketPeer(Socket)
    catch _:_ -> undefined end.

socketPeer(Socket) ->
    case peernameSafe(inet, Socket) of
        {ok, Ip} -> Ip;
        error ->
            case peernameSafe(ssl, Socket) of
                {ok, Ip} -> Ip;
                error -> undefined
            end
    end.

peernameSafe(Mod, Socket) ->
    try Mod:peername(Socket) of
        {ok, {Ip, _Port}} -> {ok, Ip};
        _ -> error
    catch _:_ -> error end.

%% 提取请求 Origin 头（大小写不敏感）。
originHeader(WsReq) ->
    try eWSrv:headers(WsReq) of
        Headers -> headerCi(<<"origin"/utf8>>, Headers)
    catch _:_ -> undefined end.

%% 大小写不敏感的请求头查找（键可能是 atom/binary/string）。
headerCi(Name, Headers) ->
    Lower = string:lowercase(toBinary(Name)),
    case lists:search(fun({K, _V}) -> string:lowercase(toBinary(K)) =:= Lower end, Headers) of
        {value, {_K, V}} -> toBinary(V);
        false -> undefined
    end.

%% 记录写类请求来源（审计）。
logRequest(Method, Path, Ip) ->
    case alWebSec:isWrite(Method) orelse Path =:= <<"/ws"/utf8>> of
        true ->
            error_logger:info_msg("[web] ~s ~ts from ~ts~n",
                [Method, Path, alWebSec:formatIp(Ip)]);
        false -> ok
    end.

logDenied(Method, Path, Ip) ->
    error_logger:warning_msg("[web] 401 ~s ~ts from ~ts~n",
        [Method, Path, alWebSec:formatIp(Ip)]).

%% 从 Authorization Bearer 或 query token 获取 API 令牌。
webApiToken(WsReq) ->
    case bearerToken(WsReq) of
        undefined ->
            Args = eWSrv:args(WsReq),
            case proplists:get_value(<<"token"/utf8>>, Args) of
                undefined -> proplists:get_value("token", Args, undefined);
                V -> V
            end;
        Bearer ->
            Bearer
    end.

bearerToken(WsReq) ->
    Headers = eWSrv:headers(WsReq),
    Auth = proplists:get_value(<<"authorization"/utf8>>, Headers,
        proplists:get_value("authorization", Headers, <<>>)),
    case toBinary(Auth) of
        <<"Bearer ", Rest/binary>> -> Rest;
        <<"bearer ", Rest/binary>> -> Rest;
        _ -> undefined
    end.

%%%===================================================================
%%% API 处理函数
%%%===================================================================

promptAllowed(undefined, _AttachOpts) ->
    false;
promptAllowed(<<>>, AttachOpts) ->
    maps:get(images, AttachOpts, []) =/= [] orelse
        maps:get(files, AttachOpts, []) =/= [] orelse
        maps:get(documents, AttachOpts, []) =/= [];
promptAllowed(_Prompt, _AttachOpts) ->
    true.

effectivePrompt(Prompt) when Prompt =:= undefined; Prompt =:= <<>> ->
    <<"请分析以上附件。"/utf8>>;
effectivePrompt(Prompt) ->
    Prompt.

askOpts(SessionId, AttachOpts) ->
    maps:merge(#{sessionId => SessionId}, AttachOpts).

%% @doc 同步问答：解析 prompt，调用 ali:ask/2 返回完整回答。
handleAsk(WsReq) ->
    Body = eWSrv:body(WsReq),
    Decoded = decodeJson(Body),
    Prompt = maps:get(<<"prompt"/utf8>>, Decoded, undefined),
    SessionId = maps:get(<<"sessionId"/utf8>>, Decoded, <<"web"/utf8>>),
    case alAttachments:optsFromBody(Decoded) of
        {ok, AttachOpts} ->
            case promptAllowed(Prompt, AttachOpts) of
                false ->
                    jsonResponse(400, #{error => <<"missing prompt"/utf8>>});
                true ->
                    ensureAgent(),
                    Opts = askOpts(SessionId, AttachOpts),
                    case ali:ask(effectivePrompt(Prompt), Opts) of
                        {ok, Answer} ->
                            jsonResponse(200, #{
                                ok => true,
                                answer => Answer,
                                sessionId => SessionId
                            });
                        {error, Reason} ->
                            jsonResponse(500, #{ok => false, error => formatError(Reason)})
                    end
            end;
        {error, Reason} ->
            jsonResponse(400, #{error => Reason})
    end.

%% @doc 停止进行中的流式/同步 ask；可选 body.sessionId 仅取消该会话。
handleAskCancel(WsReq) ->
    Body = decodeJson(eWSrv:body(WsReq)),
    SessionId = maps:get(<<"sessionId"/utf8>>, Body, undefined),
    ensureAgent(),
    Result = case SessionId of
        undefined -> ali:cancelAsk();
        _ -> ali:cancelAsk(SessionId)
    end,
    case Result of
        {error, R} ->
            jsonResponse(500, #{ok => false, error => formatTerm(R)});
        Map when is_map(Map) ->
            jsonResponse(200, maps:merge(#{ok => true}, sanitizeMap(Map)))
    end.

%% @doc 异步问答：返回 taskId，客户端轮询 /api/ask/status。
handleAskStart(WsReq) ->
    Body = decodeJson(eWSrv:body(WsReq)),
    Prompt = maps:get(<<"prompt"/utf8>>, Body, undefined),
    SessionId = maps:get(<<"sessionId"/utf8>>, Body, <<"web"/utf8>>),
    case alAttachments:optsFromBody(Body) of
        {ok, AttachOpts} ->
            case promptAllowed(Prompt, AttachOpts) of
                false ->
                    jsonResponse(400, #{error => <<"missing prompt"/utf8>>});
                true ->
                    ensureAgent(),
                    Opts = askOpts(SessionId, AttachOpts),
                    case ali:askAsync(effectivePrompt(Prompt), Opts) of
                        {ok, TaskId} ->
                            jsonResponse(200, #{
                                ok => true,
                                taskId => TaskId,
                                sessionId => SessionId
                            });
                        {error, Reason} ->
                            jsonResponse(500, #{ok => false, error => formatError(Reason)})
                    end
            end;
        {error, Reason} ->
            jsonResponse(400, #{error => Reason})
    end.

%% @doc 查询异步任务状态与增量事件（支持 since 参数）。
handleAskStatus(TaskId, WsReq) ->
    CleanId = cleanTaskId(TaskId),
    Since = parseSince(WsReq),
    Snap = alProgress:snapshot(CleanId, Since),
    case maps:get(status, Snap, not_found) of
        not_found ->
            replyTaskFallback(CleanId);
        Status ->
            replyProgressSnapshot(Status, Snap)
    end.

%% @doc 将进度快照格式化为 JSON 响应。
replyProgressSnapshot(Status, Snap) ->
    Resp = #{
        ok => true,
        status => atom_to_binary(Status, utf8),
        events => [sanitizeMap(E) || E <- maps:get(events, Snap, [])],
        eventCount => maps:get(eventCount, Snap, 0)
    },
    Resp1 = case maps:get(result, Snap, undefined) of
        {ok, Answer} when Status =:= completed ->
            Resp#{answer => Answer};
        {error, Reason} when Status =:= failed ->
            Resp#{error => formatError(Reason)};
        _ ->
            Resp
    end,
    jsonResponse(200, Resp1).

%% @doc 进度表无记录时的回退查询（alTask 或空 running）。
replyTaskFallback(TaskId) ->
    case alProgress:snapshot(TaskId, 0) of
        #{status := running, eventCount := C} when C > 0 ->
            replyProgressSnapshot(running, alProgress:snapshot(TaskId, 0));
        #{status := completed} = Snap ->
            replyProgressSnapshot(completed, Snap);
        #{status := failed} = Snap ->
            replyProgressSnapshot(failed, Snap);
        _ ->
            fallbackTaskStatus(TaskId)
    end.

%% @doc 从 alTask 进程查询任务最终状态（兜底路径）。
fallbackTaskStatus(TaskId) ->
    case alTask:status(TaskId) of
        {ok, #{status := running}} ->
            jsonResponse(200, #{
                ok => true,
                status => <<"running"/utf8>>,
                events => [],
                eventCount => 0
            });
        {ok, #{status := completed, result := {ok, Answer}}} ->
            jsonResponse(200, #{
                ok => true,
                status => <<"completed"/utf8>>,
                answer => Answer,
                events => [],
                eventCount => 0
            });
        {ok, #{status := failed, result := {error, Reason}}} ->
            jsonResponse(200, #{
                ok => true,
                status => <<"failed"/utf8>>,
                error => formatError(Reason),
                events => [],
                eventCount => 0
            });
        _ ->
            jsonResponse(404, #{ok => false, error => <<"task_not_found"/utf8>>})
    end.

%% @doc 从请求 query 解析 since 事件偏移量。
parseSince(WsReq) ->
    Args = eWSrv:args(WsReq),
    parseSinceArgs(Args).

%% 从参数列表提取 since 值。
parseSinceArgs(Args) when is_list(Args) ->
    case proplists:get_value(<<"since"/utf8>>, Args) of
        undefined ->
            case proplists:get_value("since", Args) of
                undefined -> 0;
                V -> parseSinceValue(V)
            end;
        V ->
            parseSinceValue(V)
    end;
parseSinceArgs(_) ->
    0.

%% 将 since 值规范化为非负整数。
parseSinceValue(V) when is_integer(V) -> V;
parseSinceValue(V) when is_binary(V) -> parseInt(binary_to_list(V), 0);
parseSinceValue(V) when is_list(V) -> parseInt(V, 0);
parseSinceValue(_) -> 0.

%% @doc 去除 taskId 中附带的 query 字符串。
cleanTaskId(TaskId) when is_binary(TaskId) ->
    case binary:split(TaskId, <<"?"/utf8>>, []) of
        [Id | _] -> Id;
        _ -> TaskId
    end;
cleanTaskId(TaskId) ->
    cleanTaskId(toBinary(TaskId)).

%% 安全解析整数字符串，失败返回默认值。
parseInt(Str, Default) ->
    try list_to_integer(Str) of
        N when N >= 0 -> N;
        _ -> Default
    catch
        _:_ -> Default
    end.

%% @doc 切换 Agent 运行模式（ask / edit / exec）。
handleMode(WsReq) ->
    Body = decodeJson(eWSrv:body(WsReq)),
    Mode = maps:get(<<"mode"/utf8>>, Body, undefined),
    case Mode of
        <<"ask"/utf8>> -> setMode(ask);
        <<"edit"/utf8>> -> setMode(edit);
        <<"exec"/utf8>> -> setMode(exec);
        _ -> jsonResponse(400, #{error => <<"invalid mode"/utf8>>})
    end.

%% 设置模式并返回 JSON 确认。
setMode(Mode) ->
    case ali:setMode(Mode) of
        ok -> jsonResponse(200, #{ok => true, mode => atom_to_binary(Mode, utf8)});
        {error, R} -> jsonResponse(500, #{ok => false, error => formatTerm(R)})
    end.

%% @doc 运行或生成 EUnit / Common Test。
handleEunit(Fun, WsReq) ->
    runTestTool(Fun, WsReq).

handleCt(Fun, WsReq) ->
    runTestTool(Fun, WsReq).

runTestTool(Fun, WsReq) ->
    Body = decodeJson(eWSrv:body(WsReq)),
    Module = maps:get(<<"module"/utf8>>, Body, <<"all"/utf8>>),
    case buildTestToolArgs(Module) of
        {error, Reason} ->
            jsonResponse(400, #{ok => false, error => formatTerm(Reason)});
        {ok, Args} ->
            case executeAgentTool(Fun, Args) of
                {ok, R} ->
                    jsonResponse(200, maps:merge(#{ok => true}, sanitizeMap(R)));
                {pending, P} ->
                    jsonResponse(202, #{
                        ok => false,
                        pending => true,
                        taskId => maps:get(taskId, P),
                        preview => sanitizeMap(P)
                    });
                {error, denied} ->
                    jsonResponse(403, #{ok => false, error => <<"denied"/utf8>>});
                {error, R} ->
                    jsonResponse(500, #{ok => false, error => formatTerm(R)})
            end
    end.

buildTestToolArgs(<<"all"/utf8>>) ->
    {ok, #{}};
buildTestToolArgs(M) ->
    case existingModuleAtom(M) of
        {ok, ModAtom} -> {ok, #{module => ModAtom}};
        {error, Reason} -> {error, Reason}
    end.

%% @doc 批准待确认的 Agent 操作（如写文件）。
handleApprove(WsReq) ->
    Body = decodeJson(eWSrv:body(WsReq)),
    TaskId = maps:get(<<"taskId"/utf8>>, Body, undefined),
    case TaskId of
        undefined ->
            jsonResponse(400, #{error => <<"missing taskId"/utf8>>});
        _ ->
            case ali:approve(TaskId) of
                {ok, R} ->
                    jsonResponse(200, maps:merge(#{ok => true}, sanitizeMap(R)));
                {error, R} -> jsonResponse(500, #{ok => false, error => formatTerm(R)})
            end
    end.

handleDismiss(WsReq) ->
    Body = decodeJson(eWSrv:body(WsReq)),
    TaskId = maps:get(<<"taskId"/utf8>>, Body, undefined),
    case TaskId of
        undefined ->
            jsonResponse(400, #{error => <<"missing taskId"/utf8>>});
        _ ->
            case ali:dismiss(TaskId) of
                {ok, R} ->
                    jsonResponse(200, maps:merge(#{ok => true}, sanitizeMap(R)));
                {error, R} -> jsonResponse(500, #{ok => false, error => formatTerm(R)})
            end
    end.

%% @doc 列出指定文件的备份记录（只读，无需 edit 模式）。
handleListBackups(WsReq) ->
    Qs = eWSrv:args(WsReq),
    Path = proplists:get_value(<<"path"/utf8>>, Qs,
            proplists:get_value("path", Qs, undefined)),
    case Path of
        undefined ->
            jsonResponse(400, #{error => <<"missing path"/utf8>>});
        _ ->
            Args = #{path => Path},
            case alToolEdit:listBackups(Args, #{}) of
                {ok, R} -> jsonResponse(200, maps:merge(#{ok => true}, sanitizeMap(R)));
                {error, R} -> jsonResponse(500, #{ok => false, error => formatTerm(R)})
            end
    end.

%% @doc 格式化 .erl 文件（需 edit 模式，会原地覆盖并备份）。
handleFormatCode(WsReq) ->
    Body = decodeJson(eWSrv:body(WsReq)),
    Path = maps:get(<<"path"/utf8>>, Body, undefined),
    Backup = maps:get(<<"backup"/utf8>>, Body, true),
    case Path of
        undefined ->
            jsonResponse(400, #{error => <<"missing path"/utf8>>});
        _ ->
            Args = #{path => Path, backup => Backup},
            case executeAgentTool(formatCode, Args) of
                {ok, R} ->
                    jsonResponse(200, maps:merge(#{ok => true}, sanitizeMap(R)));
                {pending, P} ->
                    jsonResponse(202, #{
                        ok => false,
                        pending => true,
                        taskId => maps:get(taskId, P),
                        preview => sanitizeMap(P)
                    });
                {error, unsupportedFileType} ->
                    jsonResponse(400, #{ok => false, error => <<"unsupportedFileType"/utf8>>});
                {error, fileNotFound} ->
                    jsonResponse(404, #{ok => false, error => <<"fileNotFound"/utf8>>});
                {error, denied} ->
                    jsonResponse(403, #{ok => false, error => <<"denied"/utf8>>});
                {error, R} ->
                    jsonResponse(500, #{ok => false, error => formatTerm(R)})
            end
    end.

%% @doc 返回已保存会话列表与当前活跃会话数。
handleSessions() ->
    ensureAgent(),
    Saved = ali:savedSessions(),
    AgentStatus = safeStatus(),
    Current = maps:get(sessionCount, maps:get(agent, AgentStatus, #{}), 0),
    jsonResponse(200, #{
        saved => Saved,
        currentCount => Current
    }).

%% @doc 从磁盘加载指定 sessionId 的会话。
handleSessionLoad(WsReq) ->
    Body = decodeJson(eWSrv:body(WsReq)),
    SessionId = maps:get(<<"sessionId"/utf8>>, Body, undefined),
    case SessionId of
        undefined -> jsonResponse(400, #{error => <<"missing sessionId"/utf8>>});
        _ ->
            ensureAgent(),
            case ali:loadSession(SessionId) of
                ok ->
                    case ali:sessionMessages(SessionId) of
                        {ok, Msgs} ->
                            jsonResponse(200, #{
                                ok => true,
                                sessionId => SessionId,
                                messages => sanitizeSessionMessages(Msgs)
                            });
                        {error, R} ->
                            jsonResponse(500, #{ok => false, error => formatTerm(R)})
                    end;
                {error, R} -> jsonResponse(500, #{ok => false, error => formatTerm(R)})
            end
    end.

handleSessionSave(WsReq) ->
    Body = decodeJson(eWSrv:body(WsReq)),
    SessionId = maps:get(<<"sessionId"/utf8>>, Body, undefined),
    case SessionId of
        undefined -> jsonResponse(400, #{error => <<"missing sessionId"/utf8>>});
        _ ->
            ensureAgent(),
            case ali:saveSession(SessionId) of
                ok -> jsonResponse(200, #{ok => true, sessionId => SessionId});
                {error, R} -> jsonResponse(500, #{ok => false, error => formatTerm(R)})
            end
    end.

handleSessionMessages(WsReq) ->
    Args = eWSrv:args(WsReq),
    SessionId = proplists:get_value(<<"sessionId"/utf8>>, Args,
            proplists:get_value("sessionId", Args, <<"web"/utf8>>)),
    ensureAgent(),
    case ali:sessionMessages(SessionId) of
        {ok, Msgs} ->
            jsonResponse(200, #{
                ok => true,
                sessionId => toBinary(SessionId),
                messages => sanitizeSessionMessages(Msgs)
            });
        {error, sessionNotFound} ->
            jsonResponse(404, #{ok => false, error => <<"sessionNotFound"/utf8>>});
        {error, R} ->
            jsonResponse(500, #{ok => false, error => formatTerm(R)})
    end.

sanitizeSessionMessages(Msgs) when is_list(Msgs) ->
    [sanitizeSessionMessage(M) || M <- Msgs];
sanitizeSessionMessages(_) ->
    [].

sanitizeSessionMessage(#{role := Role, content := Content} = M) ->
    Base = #{
        <<"role"/utf8>> => atom_to_binary(Role, utf8),
        <<"content"/utf8>> => sanitizeMessageContent(Content)
    },
    case maps:get(tool_call_id, M, undefined) of
        undefined -> Base;
        Id -> maps:put(<<"tool_call_id"/utf8>>, sanitizeValue(Id), Base)
    end;
sanitizeSessionMessage(M) ->
    sanitizeMap(M).

sanitizeMessageContent(null) -> null;
sanitizeMessageContent(B) when is_binary(B) -> B;
sanitizeMessageContent(L) when is_list(L) -> sanitizeValue(L);
sanitizeMessageContent(V) -> sanitizeValue(V).

%% @doc 删除磁盘上已保存的会话文件。
handleSessionDelete(WsReq) ->
    Body = decodeJson(eWSrv:body(WsReq)),
    SessionId = maps:get(<<"sessionId"/utf8>>, Body, undefined),
    case SessionId of
        undefined -> jsonResponse(400, #{error => <<"missing sessionId"/utf8>>});
        _ ->
            ensureAgent(),
            case ali:deleteSavedSession(SessionId) of
                ok -> jsonResponse(200, #{ok => true, sessionId => SessionId});
                {error, R} -> jsonResponse(500, #{ok => false, error => formatTerm(R)})
            end
    end.

%% @doc GET 版 SSE 流式问答（EventSource，prompt 通过 query 传递）。
handleAskStreamGet(WsReq) ->
    Args = eWSrv:args(WsReq),
    Prompt = proplists:get_value(<<"prompt"/utf8>>, Args, proplists:get_value("prompt", Args, undefined)),
    SessionId = proplists:get_value(<<"sessionId"/utf8>>, Args, <<"web"/utf8>>),
    runSseChunked(Prompt, SessionId, #{}).

%% @doc POST 版 SSE 流式问答（JSON body 传 prompt）。
handleAskStream(WsReq) ->
    Body = decodeJson(eWSrv:body(WsReq)),
    Prompt = maps:get(<<"prompt"/utf8>>, Body, undefined),
    SessionId = maps:get(<<"sessionId"/utf8>>, Body, <<"web"/utf8>>),
    case alAttachments:optsFromBody(Body) of
        {ok, AttachOpts} ->
            case promptAllowed(Prompt, AttachOpts) of
                false ->
                    jsonResponse(400, #{error => <<"missing prompt"/utf8>>});
                true ->
                    runSseChunked(effectivePrompt(Prompt), SessionId, AttachOpts)
            end;
        {error, Reason} ->
            jsonResponse(400, #{error => Reason})
    end.

%% @doc 启动 SSE chunked 响应：spawn 转发 alServer 流式分块。
runSseChunked(undefined, _SessionId, _AttachOpts) ->
    jsonResponse(400, #{error => <<"missing prompt"/utf8>>});
runSseChunked(Prompt, SessionId, AttachOpts) ->
    ensureAgent(),
    HandlerPid = self(),
    ProgressId = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    alProgress:start(ProgressId),
    spawn(fun() ->
        case whereis(alServer) of
            undefined ->
                alProgress:drop(ProgressId),
                HandlerPid ! {chunk, close};
            Server ->
                Opts = (askOpts(SessionId, AttachOpts))#{
                    progressId => ProgressId
                },
                gen_server:cast(Server, {askStreamAsync, Prompt, Opts, self()}),
                Started = erlang:system_time(millisecond),
                forwardStreamChunks(HandlerPid, SessionId, ProgressId, 0, Started)
        end
    end),
    {chunk, [
        {<<"Content-Type"/utf8>>, <<"text/event-stream; charset=utf-8"/utf8>>},
        {<<"Cache-Control"/utf8>>, <<"no-cache"/utf8>>}
    ] ++ corsHeaders()}.

%% 从 alServer 接收流式分块并编码为 SSE 事件推送给客户端。
forwardStreamChunks(HandlerPid, SessionId, ProgressId, ProgressIdx, StartedMs) ->
    receive
        {stream_chunk, done} ->
            NewIdx = forwardProgressEvents(HandlerPid, ProgressId, ProgressIdx),
            alProgress:drop(ProgressId),
            _ = NewIdx,
            DoneEvent = iolist_to_binary([<<"event: done\ndata: {\"sessionId\":\""/utf8>>, SessionId, <<"\"}\n\n"/utf8>>]),
            HandlerPid ! {chunk, DoneEvent},
            HandlerPid ! {chunk, close};
        {stream_chunk, Chunk} when is_binary(Chunk) ->
            Event = iolist_to_binary([<<"data: "/utf8>>, escapeSseText(Chunk), <<"\n\n"/utf8>>]),
            HandlerPid ! {chunk, Event},
            forwardStreamChunks(HandlerPid, SessionId, ProgressId, ProgressIdx, StartedMs);
        {al, streamDone, done} ->
            forwardStreamChunks(HandlerPid, SessionId, ProgressId, ProgressIdx, StartedMs);
        {al, streamError, Reason} ->
            alProgress:drop(ProgressId),
            ErrJson = llmJson:encode(#{error => formatTerm(Reason)}),
            ErrEvent = iolist_to_binary([<<"event: error\ndata: "/utf8>>, ErrJson, <<"\n\n"/utf8>>]),
            HandlerPid ! {chunk, ErrEvent},
            HandlerPid ! {chunk, close};
        _Other ->
            forwardStreamChunks(HandlerPid, SessionId, ProgressId, ProgressIdx, StartedMs)
    after 300 ->
        NewIdx = forwardProgressEvents(HandlerPid, ProgressId, ProgressIdx),
        case erlang:system_time(millisecond) - StartedMs > 600000 of
            true ->
                alProgress:drop(ProgressId),
                HandlerPid ! {chunk, close};
            false ->
                forwardStreamChunks(HandlerPid, SessionId, ProgressId, NewIdx, StartedMs)
        end
    end.

forwardProgressEvents(HandlerPid, ProgressId, Since) ->
    #{events := Events, eventCount := Total} = alProgress:snapshot(ProgressId, Since),
    lists:foreach(fun(E) ->
        Json = llmJson:encode(sanitizeMap(E)),
        Event = iolist_to_binary([<<"event: progress\ndata: "/utf8>>, Json, <<"\n\n"/utf8>>]),
        HandlerPid ! {chunk, Event}
    end, Events),
    Total.

%% 转义 SSE data 字段中的换行符。
escapeSseText(Bin) when is_binary(Bin) ->
    binary:replace(Bin, <<"\n"/utf8>>, <<"\ndata: "/utf8>>, [global]);
escapeSseText(Other) ->
    escapeSseText(toBinary(Other)).

%% @doc 文本替换 diff 预览（只读，不修改磁盘）。
handlePreviewPatch(WsReq) ->
    Body = decodeJson(eWSrv:body(WsReq)),
    Path = maps:get(<<"path"/utf8>>, Body, undefined),
    OldText = maps:get(<<"oldText"/utf8>>, Body, undefined),
    NewText = maps:get(<<"newText"/utf8>>, Body, undefined),
    case Path of
        undefined ->
            jsonResponse(400, #{error => <<"missing path"/utf8>>});
        _ ->
            Args = #{path => Path, oldText => OldText, newText => NewText},
            case alToolEdit:previewPatch(Args, #{}) of
                {ok, R} -> jsonResponse(200, maps:merge(#{ok => true}, sanitizeMap(R)));
                {error, R} -> jsonResponse(500, #{ok => false, error => formatTerm(R)})
            end
    end.

%%%===================================================================
%%% WebSocket
%%%===================================================================

%% @doc 执行 WebSocket 升级握手；同时捕获 socket 供后续主动推送使用。
wsUpgrade(WsReq) ->
    case wsWebSocket:tryWsUpgrade(WsReq) of
        {ok, WsHeaders} ->
            %% handle/3 与 handleWs/3 运行于同一连接进程，借进程字典传递 socket
            put(wsSocket, eWSrv:socket(WsReq)),
            {wsUpgrade, WsHeaders};
        {error, Reason} ->
            jsonResponse(400, #{error => formatTerm(Reason)})
    end.

%% @doc eWSrv WebSocket 回调：处理文本命令、ping/pong 与关闭。
-spec handleWs(integer(), binary(), term()) -> term().
handleWs(?WS_TEXT, Payload, WebState) ->
    Cmd = decodeJson(Payload),
    try wsDispatch(Cmd, WebState) of
        {reply, Bin, NewState} -> {ok, ?WS_TEXT, Bin, NewState};
        {ok, NewState} -> {ok, NewState}
    catch
        Class:Reason ->
            error_logger:format("wsDispatch ~p:~p~n", [Class, Reason]),
            {ok, ?WS_TEXT, wsEncode(#{type => <<"error"/utf8>>,
                                       error => formatTerm({Class, Reason})}), WebState}
    end;
handleWs(?WS_PING, Payload, WebState) ->
    {ok, ?WS_PONG, Payload, WebState};
handleWs(?WS_CLOSE, _Payload, WebState) ->
    {close, WebState};
handleWs(_Opcode, _Payload, WebState) ->
    {ok, WebState}.

%% 分发 WS JSON 命令。返回 {reply, Bin, State} 或 {ok, State}。
wsDispatch(#{<<"type"/utf8>> := Type} = Cmd, WebState) ->
    wsCommand(Type, Cmd, WebState);
wsDispatch(_, WebState) ->
    {reply, wsEncode(#{type => <<"error"/utf8>>, error => <<"missing type"/utf8>>}), WebState}.

%% 各 WS 命令实现。
wsCommand(<<"ask"/utf8>>, Cmd, WebState) ->
    Prompt = maps:get(<<"prompt"/utf8>>, Cmd, undefined),
    SessionId = maps:get(<<"sessionId"/utf8>>, Cmd, <<"web"/utf8>>),
    case alAttachments:optsFromBody(Cmd) of
        {ok, AttachOpts} ->
            case promptAllowed(Prompt, AttachOpts) of
                false ->
                    {reply, wsErr(<<"missing prompt"/utf8>>), WebState};
                true ->
                    ensureAgent(),
                    Socket = get(wsSocket),
                    wsStartStream(Socket, effectivePrompt(Prompt), SessionId, AttachOpts),
                    {reply, wsEncode(#{type => <<"ack"/utf8>>, kind => <<"ask"/utf8>>}), WebState}
            end;
        {error, Reason} ->
            {reply, wsErr(Reason), WebState}
    end;
wsCommand(<<"status"/utf8>>, _Cmd, WebState) ->
    {reply, wsOk(<<"status"/utf8>>, safeStatus()), WebState};
wsCommand(<<"tools"/utf8>>, _Cmd, WebState) ->
    {reply, wsOk(<<"tools"/utf8>>, #{tools => alTools:listTools()}), WebState};
wsCommand(<<"metrics"/utf8>>, _Cmd, WebState) ->
    ensureAgent(),
    {reply, wsOk(<<"metrics"/utf8>>, ali:metrics()), WebState};
wsCommand(<<"plan"/utf8>>, Cmd, WebState) ->
    Sid = maps:get(<<"sessionId"/utf8>>, Cmd, <<"web"/utf8>>),
    ensureAgent(),
    {reply, wsOk(<<"plan"/utf8>>, ali:plan(toBinary(Sid))), WebState};
wsCommand(<<"tasks"/utf8>>, _Cmd, WebState) ->
    ensureAgent(),
    {reply, wsOk(<<"tasks"/utf8>>, #{tasks => [sanitizeMap(T) || T <- alTask:list()]}), WebState};
wsCommand(<<"cancelAsk"/utf8>>, Cmd, WebState) ->
    ensureAgent(),
    SessionId = maps:get(<<"sessionId"/utf8>>, Cmd, undefined),
    Result = case SessionId of
        undefined -> ali:cancelAsk();
        _ -> ali:cancelAsk(SessionId)
    end,
    case Result of
        {error, R} ->
            {reply, wsErr(formatTerm(R)), WebState};
        Map when is_map(Map) ->
            {reply, wsOk(<<"cancelAsk"/utf8>>, Map), WebState}
    end;
wsCommand(<<"cancelTask"/utf8>>, Cmd, WebState) ->
    ensureAgent(),
    TaskId = maps:get(<<"taskId"/utf8>>, Cmd, undefined),
    case TaskId of
        undefined ->
            {reply, wsErr(<<"missing taskId"/utf8>>), WebState};
        _ ->
            case ali:cancelTask(TaskId) of
                ok -> {reply, wsOk(<<"cancelTask"/utf8>>, #{taskId => TaskId}), WebState};
                {error, R} -> {reply, wsErr(formatTerm(R)), WebState}
            end
    end;
wsCommand(<<"audit"/utf8>>, _Cmd, WebState) ->
    {reply, wsOk(<<"audit"/utf8>>, #{entries => [sanitizeMap(E) || E <- ali:auditLog(100)]}), WebState};
wsCommand(<<"pending"/utf8>>, Cmd, WebState) ->
    ensureAgent(),
    TaskId = maps:get(<<"taskId"/utf8>>, Cmd, <<>>),
    case ali:pendingTask(TaskId) of
        {ok, Preview} -> {reply, wsOk(<<"pending"/utf8>>, Preview), WebState};
        {error, _} -> {reply, wsErr(<<"pending_not_found"/utf8>>), WebState}
    end;
wsCommand(<<"approve"/utf8>>, Cmd, WebState) ->
    TaskId = maps:get(<<"taskId"/utf8>>, Cmd, undefined),
    case TaskId of
        undefined -> {reply, wsErr(<<"missing taskId"/utf8>>), WebState};
        _ ->
            case ali:approve(TaskId) of
                {ok, R} -> {reply, wsOk(<<"approve"/utf8>>, sanitizeMap(R)), WebState};
                {error, R} -> {reply, wsErr(formatTerm(R)), WebState}
            end
    end;
wsCommand(<<"dismiss"/utf8>>, Cmd, WebState) ->
    TaskId = maps:get(<<"taskId"/utf8>>, Cmd, undefined),
    case TaskId of
        undefined -> {reply, wsErr(<<"missing taskId"/utf8>>), WebState};
        _ ->
            case ali:dismiss(TaskId) of
                {ok, R} -> {reply, wsOk(<<"dismiss"/utf8>>, sanitizeMap(R)), WebState};
                {error, R} -> {reply, wsErr(formatTerm(R)), WebState}
            end
    end;
wsCommand(<<"saveSession"/utf8>>, Cmd, WebState) ->
    SessionId = maps:get(<<"sessionId"/utf8>>, Cmd, undefined),
    case SessionId of
        undefined -> {reply, wsErr(<<"missing sessionId"/utf8>>), WebState};
        _ ->
            case ali:saveSession(SessionId) of
                ok -> {reply, wsOk(<<"saveSession"/utf8>>, #{sessionId => SessionId}), WebState};
                {error, R} -> {reply, wsErr(formatTerm(R)), WebState}
            end
    end;
wsCommand(<<"deleteSession"/utf8>>, Cmd, WebState) ->
    SessionId = maps:get(<<"sessionId"/utf8>>, Cmd, undefined),
    case SessionId of
        undefined -> {reply, wsErr(<<"missing sessionId"/utf8>>), WebState};
        _ ->
            case ali:deleteSavedSession(SessionId) of
                ok -> {reply, wsOk(<<"deleteSession"/utf8>>, #{sessionId => SessionId}), WebState};
                {error, R} -> {reply, wsErr(formatTerm(R)), WebState}
            end
    end;
wsCommand(<<"mode"/utf8>>, Cmd, WebState) ->
    Mode = maps:get(<<"mode"/utf8>>, Cmd, undefined),
    case lists:member(Mode, [<<"ask"/utf8>>, <<"edit"/utf8>>, <<"exec"/utf8>>]) of
        true ->
            _ = ali:setMode(existingModeAtom(Mode)),
            {reply, wsOk(<<"mode"/utf8>>, #{mode => Mode}), WebState};
        false ->
            {reply, wsErr(<<"invalid mode"/utf8>>), WebState}
    end;
wsCommand(<<"previewPatch"/utf8>>, Cmd, WebState) ->
    Args = #{
        path => maps:get(<<"path"/utf8>>, Cmd, undefined),
        oldText => maps:get(<<"oldText"/utf8>>, Cmd, undefined),
        newText => maps:get(<<"newText"/utf8>>, Cmd, undefined)
    },
    case alToolEdit:previewPatch(Args, #{}) of
        {ok, R} -> {reply, wsOk(<<"previewPatch"/utf8>>, R), WebState};
        {error, R} -> {reply, wsErr(formatTerm(R)), WebState}
    end;
wsCommand(Other, _Cmd, WebState) ->
    {reply, wsEncode(#{type => <<"error"/utf8>>,
                        error => <<"unknown command: "/utf8, Other/binary>>}), WebState}.

%% 启动 WS 流式问答转发进程，通过捕获的 socket 主动推送 token/progress/done。
wsStartStream(undefined, _Prompt, _SessionId, _AttachOpts) ->
    ok;
wsStartStream(Socket, Prompt, SessionId, AttachOpts) ->
    ProgressId = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    alProgress:start(ProgressId),
    spawn(fun() ->
        case whereis(alServer) of
            undefined ->
                alProgress:drop(ProgressId),
                wsSend(Socket, #{type => <<"done"/utf8>>, sessionId => SessionId});
            Server ->
                Opts = (askOpts(SessionId, AttachOpts))#{
                    progressId => ProgressId
                },
                gen_server:cast(Server, {askStreamAsync, Prompt, Opts, self()}),
                Started = erlang:system_time(millisecond),
                wsForward(Socket, SessionId, ProgressId, 0, Started)
        end
    end),
    ok.

%% 转发 alServer 流式分块与进度事件到 WebSocket。
wsForward(Socket, SessionId, ProgressId, Idx, Started) ->
    receive
        {stream_chunk, done} ->
            _ = wsForwardProgress(Socket, ProgressId, Idx),
            alProgress:drop(ProgressId),
            wsSend(Socket, #{type => <<"done"/utf8>>, sessionId => SessionId});
        {stream_chunk, Chunk} when is_binary(Chunk) ->
            wsSend(Socket, #{type => <<"token"/utf8>>, data => Chunk}),
            wsForward(Socket, SessionId, ProgressId, Idx, Started);
        {al, streamDone, done} ->
            wsForward(Socket, SessionId, ProgressId, Idx, Started);
        {al, streamError, Reason} ->
            alProgress:drop(ProgressId),
            wsSend(Socket, #{type => <<"error"/utf8>>, error => formatTerm(Reason)}),
            wsSend(Socket, #{type => <<"done"/utf8>>, sessionId => SessionId});
        _Other ->
            wsForward(Socket, SessionId, ProgressId, Idx, Started)
    after 300 ->
        NewIdx = wsForwardProgress(Socket, ProgressId, Idx),
        case erlang:system_time(millisecond) - Started > 600000 of
            true ->
                alProgress:drop(ProgressId),
                wsSend(Socket, #{type => <<"done"/utf8>>, sessionId => SessionId});
            false ->
                wsForward(Socket, SessionId, ProgressId, NewIdx, Started)
        end
    end.

%% 推送新增的进度事件。
wsForwardProgress(Socket, ProgressId, Since) ->
    #{events := Events, eventCount := Total} = alProgress:snapshot(ProgressId, Since),
    lists:foreach(fun(E) ->
        wsSend(Socket, #{type => <<"progress"/utf8>>, event => sanitizeMap(E)})
    end, Events),
    Total.

%% 编码并通过 WebSocket 文本帧发送一个事件 map。
wsSend(Socket, Map) ->
    try wsWebSocket:sendFrame(Socket, ?WS_TEXT, wsEncode(Map)) catch _:_ -> ok end,
    ok.

%% WS 成功响应封装。
wsOk(Type, Map) when is_map(Map) ->
    wsEncode(maps:merge(#{type => Type, ok => true}, Map));
wsOk(Type, Other) ->
    wsEncode(#{type => Type, ok => true, data => Other}).

%% WS 错误响应封装。
wsErr(Reason) ->
    wsEncode(#{type => <<"error"/utf8>>, ok => false, error => Reason}).

%% 统一 JSON 编码（含 sanitize）。
wsEncode(Map) ->
    llmJson:encode(sanitizeMap(Map)).

%%%===================================================================
%%% 静态资源与 JSON 辅助
%%%===================================================================

%% @doc 从 priv 目录读取并返回静态文件。
servePriv(RelPath, ContentType) ->
    PrivRoot = code:priv_dir(ali),
    case safePrivPath(PrivRoot, RelPath) of
        {ok, Path} ->
            case file:read_file(Path) of
                {ok, Data} ->
                    {ok, [{<<"Content-Type"/utf8>>, ContentType}], Data};
                {error, enoent} ->
                    jsonResponse(404, #{error => <<"file_not_found"/utf8>>});
                {error, Reason} ->
                    jsonResponse(500, #{error => formatTerm(Reason)})
            end;
        {error, forbidden} ->
            jsonResponse(403, #{error => <<"forbidden"/utf8>>})
    end.

safePrivPath(PrivRoot, RelPath) ->
    Root = filename:absname(PrivRoot),
    Full = filename:absname(filename:join(Root, binary_to_list(RelPath))),
    RootParts = filename:split(Root),
    FullParts = filename:split(Full),
    case length(FullParts) >= length(RootParts)
         andalso lists:sublist(FullParts, length(RootParts)) =:= RootParts of
        true -> {ok, Full};
        false -> {error, forbidden}
    end.

agentToolConfig() ->
    Config = case ali:getConfig() of
        C when is_map(C) -> C;
        _ -> #{}
    end,
    Mode = case ali:getMode() of
        M when is_atom(M) -> M;
        _ -> ask
    end,
    Config#{mode => Mode, sessionId => <<"web"/utf8>>}.

executeAgentTool(Tool, Args) ->
    Config = agentToolConfig(),
    SessionId = maps:get(sessionId, Config, <<"web"/utf8>>),
    alTools:execute(Tool, Args, Config, SessionId).

existingModuleAtom(M) when is_binary(M) ->
    try binary_to_existing_atom(M, utf8) of
        Atom -> {ok, Atom}
    catch
        _:_ -> {error, unknownModule}
    end.

existingModeAtom(<<"ask"/utf8>>) -> ask;
existingModeAtom(<<"edit"/utf8>>) -> edit;
existingModeAtom(<<"exec"/utf8>>) -> exec.

%% @doc 根据文件扩展名返回 Content-Type。
contentType(Path) ->
    case filename:extension(binary_to_list(Path)) of
        ".css" -> <<"text/css; charset=utf-8"/utf8>>;
        ".js" -> <<"application/javascript; charset=utf-8"/utf8>>;
        ".svg" -> <<"image/svg+xml"/utf8>>;
        ".png" -> <<"image/png"/utf8>>;
        _ -> <<"application/octet-stream"/utf8>>
    end.

%% @doc 构造 JSON HTTP 响应（含按请求计算的 CORS 头与安全头）。
jsonResponse(Code, Map) ->
    Body = llmJson:encode(sanitizeMap(Map)),
    Headers = [
        {<<"Content-Type"/utf8>>, <<"application/json; charset=utf-8"/utf8>>}
    ] ++ corsHeaders() ++ alWebSec:securityHeaders(),
    {Code, Headers, Body}.

%% 读取本请求缓存的 CORS 头（无则空）。
corsHeaders() ->
    case get(corsHeaders) of
        undefined -> [];
        H when is_list(H) -> H
    end.

%% @doc 解析请求体 JSON；空体或解析失败返回空 map。
decodeJson(Bin) when is_binary(Bin), byte_size(Bin) =:= 0 ->
    #{};
decodeJson(Bin) when is_binary(Bin) ->
    try
        llmJson:decode(Bin)
    catch
        _:_ -> #{}
    end;
decodeJson(_) ->
    #{}.

%% @doc 确保 alServer 已启动。
ensureAgent() ->
    case whereis(alServer) of
        undefined -> ali:start();
        _ -> ok
    end.

%% @doc 安全获取 Agent 状态（自动启动 Agent）。
safeStatus() ->
    ensureAgent(),
    #{
        agent => ali:status(),
        webPort => alWebSrv:port(),
        node => atom_to_binary(node(), utf8),
        attachmentLimits => alConfig:web(),
        config => alConfig:publicWebConfig()
    }.

%% @doc 从 priv 读取 index.html 并注入公开配置 JSON（GET /）。
serveIndex() ->
    Path = filename:join([code:priv_dir(ali), "web/index.html"]),
    case file:read_file(Path) of
        {ok, Html} ->
            Marker = <<"<!--ALI_WEB_CONFIG-->"/utf8>>,
            ConfigTag = webConfigScriptTag(),
            Body = case binary:match(Html, Marker) of
                {Pos, Len} ->
                    <<Before:Pos/binary, _:Len/binary, After/binary>> = Html,
                    <<Before/binary, ConfigTag/binary, After/binary>>;
                nomatch ->
                    <<Html/binary, ConfigTag/binary>>
            end,
            {ok, [{<<"Content-Type"/utf8>>, <<"text/html; charset=utf-8"/utf8>>}], Body};
        {error, enoent} ->
            jsonResponse(404, #{error => <<"file_not_found"/utf8>>});
        {error, Reason} ->
            jsonResponse(500, #{error => formatTerm(Reason)})
    end.

webConfigScriptTag() ->
    Json = llmJson:encode(sanitizeMap(alConfig:publicWebConfig())),
    SafeJson = escapeJsonForHtmlScript(Json),
    iolist_to_binary([
        <<"<script type=\"application/json\" id=\"ali-config\">"/utf8>>,
        SafeJson,
        <<"</script>\n"/utf8>>
    ]).

%% 防止配置字符串中出现 </script> 打断 HTML 解析。
escapeJsonForHtmlScript(Bin) when is_binary(Bin) ->
    binary:replace(Bin, <<"</"/utf8>>, <<"<\\/"/utf8>>, [global]).

%% @doc 安全清空当前会话。
safeClear(undefined) ->
    ensureAgent(),
    ali:clearSession();
safeClear(SessionId) ->
    ensureAgent(),
    ali:clearSession(SessionId).

%% @doc 安全刷新代码索引。
safeRefreshIndex() ->
    ensureAgent(),
    ali:refreshIndex().

%% @doc 递归清理 map/list 中的 atom 等不可 JSON 化类型。
sanitizeMap(Map) when is_map(Map) ->
    maps:map(fun(_, V) -> sanitizeValue(V) end, Map);
sanitizeMap(Other) ->
  Other.

%% 清理单个值的类型以便 JSON 编码。
sanitizeValue(V) when is_map(V) -> sanitizeMap(V);
sanitizeValue(V) when is_list(V) -> [sanitizeValue(X) || X <- V];
sanitizeValue(V) when is_atom(V) -> atom_to_binary(V, utf8);
sanitizeValue(V) when is_binary(V); is_integer(V); is_float(V); is_boolean(V) -> V;
sanitizeValue(V) -> formatTerm(V).

%% 将任意术语格式化为可读二进制字符串。
formatTerm(V) ->
    unicode:characters_to_binary(io_lib:format("~p", [V])).

%% @doc 将 Agent 错误转为用户友好的二进制消息。
formatError(maxStepsExceeded) ->
    <<"步数用尽：Web 会话已自动提升到 40 步。可清空会话后重试，或在 config.cfg 增加 maxSteps"/utf8>>;
formatError(V) when is_binary(V) -> V;
formatError(V) when is_atom(V) -> atom_to_binary(V, utf8);
formatError(V) -> formatTerm(V).

%% 多类型转 UTF-8 二进制。
toBinary(X) when is_binary(X) -> X;
toBinary(X) when is_list(X) -> unicode:characters_to_binary(X);
toBinary(X) when is_atom(X) -> atom_to_binary(X, utf8);
toBinary(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).