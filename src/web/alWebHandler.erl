%%%-------------------------------------------------------------------
%% @doc eWSrv 回调模块 — WebUI 页面 + REST API 路由。
%%
%% 提供单页 WebUI（index.html + 静态资源）、REST API（/api/*）、
%% WebSocket 命令（{@link alWs}）以及 MCP 工具端点
%% （/health, /tools, /tool, /v1/tools/call）。
%%
%% 安全：CORS 白名单、按 IP 限流、安全头、常数时间 token 鉴权、
%% loopback 写保护。
%% @end
%%%-------------------------------------------------------------------

-module(alWebHandler).

-include_lib("eWSrv/include/eWSrv.hrl").
-include("ali_attachment.hrl").

-export([init/1, handle/3, handleWs/3, terminate/2, handleInfo/2]).
%% Test exports — pure helpers
-export([publicWebConfig/0, escapeJsonForHtml/1,
         safePrivPath/2, contentType/1, isWebsocketUpgrade/1,
         metricsForApi/1, planForApi/1, approveAnswerText/1,
         checkpointInfo/1, truncateBin/2, isLikelyLocalClient/1,
         sseEvent/2, sseData/1]).

-define(JsonHeader, [{<<"Content-Type">>, <<"application/json; charset=utf-8">>}]).

%%--------------------------------------------------------------------
%% @doc
%% eWSrv 回调：处理器初始化，返回空的内部状态。
%%
%% @param Args 初始化参数（未使用）
%% @return {ok, #{}}
%% @end
%%--------------------------------------------------------------------
init(_Args) ->
    {ok, #{}}.

%%--------------------------------------------------------------------
%% @doc
%% eWSrv 回调：请求结束时清理资源——停止 WebSocket 心跳进程并清除
%% 进程字典中的 CORS 头缓存。
%%
%% @param Reason 终止原因
%% @param State  当前处理器状态
%% @return ok
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    alWs:stopHeartbeat(),
    alWs:stopSendGate(),
    erase(corsHeaders),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% eWSrv info 回调：兼容旧 `{wsOut, ...}` 投递；优先走 SendGate。
%% @end
%%--------------------------------------------------------------------
handleInfo({wsOut, Opcode, Payload}, WebState) ->
    alWs:outViaGate(Opcode, Payload),
    {noreply, WebState};
handleInfo({wsOut, Payload}, WebState) when is_binary(Payload) ->
    alWs:outViaGate(?WsOpText, Payload),
    {noreply, WebState};
handleInfo(_Msg, WebState) ->
    {noreply, WebState}.

%%--------------------------------------------------------------------
%% @doc
%% 主请求入口。规范化方法名、提取客户端 IP、缓存 CORS 头，
%% 并根据方法/路径走预检、WebSocket 升级、限流、鉴权或路由分发。
%% 任何崩溃都会被捕获并返回 500 JSON 错误。
%%
%% @param Method0 HTTP 方法（atom/binary/list）
%% @param Path    请求路径（binary）
%% @param WsReq   eWSrv 请求记录
%% @return eWSrv 三元组 {Code, Headers, Body} 或 {wsUpgrade, Headers}
%% @end
%%--------------------------------------------------------------------
handle(Method0, Path, WsReq) ->
    Method = normalizeMethod(Method0),
    Ip = peerIp(WsReq),
    put(corsHeaders, alWebSec:corsHeaders(originHeader(WsReq))),
    try
        case Method of
            'OPTIONS' ->
                preflightResponse();
            'GET' when Path =:= <<"/ws">> ->
                case isWebsocketUpgrade(WsReq) of
                    true -> guardedWsUpgrade(WsReq, Ip);
                    false -> guardedDispatch(Method, Path, WsReq, Ip)
                end;
            _ ->
                guardedDispatch(Method, Path, WsReq, Ip)
        end
    catch
        CrashClass:CrashReason:Stack ->
            %% 仅在服务端日志保留 Class:Reason:Stack；对外只返回通用错误码，
            %% 不回传内部异常细节，避免信息泄露。
            logger:error("alWebHandler ~p ~s crashed: ~p:~p~n~p",
                         [Method, Path, CrashClass, CrashReason, Stack]),
            jsonResponse(500, #{error => internalError})
    end.

%%--------------------------------------------------------------------
%% @doc
%% 统一的 HTTP 请求门禁流水线（限流 → 鉴权 → CSRF/Origin → 路由）。
%% 与 WebSocket 升级共用同一套 {@link authorize/4} 鉴权函数。
%%
%% @param Method HTTP 方法
%% @param Path   请求路径
%% @param WsReq  eWSrv 请求记录
%% @param Ip     客户端 IP
%% @return eWSrv 三元组
%% @end
%%--------------------------------------------------------------------
guardedDispatch(Method, Path, WsReq, Ip) ->
    case alWebSec:checkRate(Ip) of
        {error, rateLimited} ->
            jsonResponse(429, #{error => rateLimited});
        ok ->
            case authorize(Method, Path, WsReq, Ip) of
                ok ->
                    case alWebSec:checkCsrf(Method, Path, originHeader(WsReq), Ip,
                                             hostHeader(WsReq)) of
                        ok -> dispatch(Method, Path, WsReq);
                        {error, csrfDenied} ->
                            logDenied(Method, Path, Ip),
                            jsonResponse(403, #{error => csrfDenied})
                    end;
                {error, Reason} ->
                    logDenied(Method, Path, Ip),
                    jsonResponse(401, #{error => Reason})
            end
    end.

%%%===================================================================
%%% WebSocket upgrade
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 判断当前请求是否为 WebSocket 升级请求（检查 Upgrade 头是否
%% 为 "websocket"，大小写不敏感）。
%%
%% @param WsReq eWSrv 请求记录
%% @return boolean()
%% @end
%%--------------------------------------------------------------------
isWebsocketUpgrade(WsReq) ->
    case lookupHeader(<<"upgrade">>, WsReq#wsReq.headers) of
        {ok, Value} ->
            case string:lowercase(toBinary(Value)) of
                <<"websocket">> -> true;
                _ -> false
            end;
        notFound ->
            false
    end.

%%--------------------------------------------------------------------
%% @doc
%% 执行 WebSocket 升级。先鉴权，再委托 wsWebSocket:tryWsUpgrade
%% 生成 101 响应头；同时缓存 socket 句柄并启动心跳。
%% 注意：返回的 `{wsUpgrade, Headers}` 中的 Headers 是 HTTP 响应头，
%% 而非应用层的 WebState map。
%%
%% @param WsReq eWSrv 请求记录
%% @return {wsUpgrade, Headers} 或 JSON 错误响应
%% @end
%%--------------------------------------------------------------------
%% eWSrv expects `{wsUpgrade, Headers}` where Headers is an HTTP header
%% list for the 101 response — NOT the application WebState map.
%%
%% WebSocket 升级与普通 HTTP 请求共用同一套门禁：限流 → 统一鉴权
%% （loopback/token 门禁，token 支持 Bearer 头或 query 参数）→ Origin
%% 白名单校验（防 CSWSH）。任一环节失败都不进行协议升级。
guardedWsUpgrade(WsReq, Ip) ->
    case alWebSec:checkRate(Ip) of
        {error, rateLimited} ->
            jsonResponse(429, #{error => rateLimited});
        ok ->
            case authorize('GET', <<"/ws">>, WsReq, Ip) of
                ok ->
                    case checkWsOrigin(WsReq) of
                        ok ->
                            doWsUpgrade(WsReq);
                        {error, OriginReason} ->
                            logDenied('GET', <<"/ws">>, Ip),
                            jsonResponse(403, #{error => OriginReason})
                    end;
                {error, Reason} ->
                    logDenied('GET', <<"/ws">>, Ip),
                    jsonResponse(401, #{error => Reason})
            end
    end.

%% 执行实际的 WebSocket 协议升级并启动心跳。
doWsUpgrade(WsReq) ->
    case wsWebSocket:tryWsUpgrade(WsReq) of
        {ok, WsHeaders} ->
            Socket = WsReq#wsReq.socket,
            put(wsSocket, Socket),
            %% 连接级发送闸门：旁路进程经此串行写 socket，避免并发 einval，
            %% 也不依赖 handleInfo/进程字典投递（热加载后易静默丢帧）。
            _ = alWs:ensureSendGate(Socket),
            alWs:startHeartbeat(Socket),
            {wsUpgrade, WsHeaders};
        {error, Reason} ->
            jsonResponse(400, #{error => Reason})
    end.

%%--------------------------------------------------------------------
%% @doc
%% 校验 WebSocket 升级请求的 Origin 头是否被允许（防跨站 WS 劫持）。
%% 默认仅允许同源 localhost/127.0.0.1:PORT；配置 allowOrigin 时以其为准。
%%
%% @param WsReq eWSrv 请求记录
%% @return ok | {error, originDenied}
%% @end
%%--------------------------------------------------------------------
checkWsOrigin(WsReq) ->
    Origin = originHeader(WsReq),
    Port = alHttpGateway:port(),
    Allowed = alWebSec:webOpt(allowOrigin, <<>>),
    case alWebSec:wsOriginAllowed(Origin, Port, Allowed, hostHeader(WsReq)) of
        true -> ok;
        false -> {error, originDenied}
    end.

%%%===================================================================
%%% WebSocket frame callback
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% WebSocket 文本帧回调。解码 JSON 命令并派发给 alWs:dispatch，
%% 根据返回值回复文本帧、保持连接或关闭连接。解析或派发异常会
%% 转换为 error 类型的文本帧回传给客户端。
%%
%% @param WsOpText 帧操作码（文本）
%% @param Payload  帧负载（JSON 文本）
%% @param WebState0 当前 WebSocket 应用状态
%% @return {ok, ?WsOpText, Bin, NewState} | {ok, NewState} | {close, NewState}
%% @end
%%--------------------------------------------------------------------
handleWs(?WsOpText, Payload, WebState0) ->
    alWs:touchLastActivity(),
    WebState = ensureWsState(WebState0),
    Cmd = try alJson:decode(Payload)
           catch _:_ -> #{<<"type">> => <<"error">>, error => invalidJson}
           end,
    try alWs:dispatch(Cmd, WebState, get(wsSocket)) of
        {reply, Bin, NewState} ->
            %% 经 SendGate 串行写出，避免与心跳/token 并发写 socket → einval
            alWs:outViaGate(?WsOpText, Bin),
            {ok, NewState};
        {ok, NewState} -> {ok, NewState};
        {close, NewState} -> {close, NewState}
    catch
        Class:Reason ->
            %% 内部异常仅记录服务端日志，对客户端只回通用错误码。
            logger:warning("[ws] dispatch ~p:~p", [Class, Reason]),
            Err = alJson:encode(#{type => error, error => internalError}),
            alWs:outViaGate(?WsOpText, Err),
            {ok, WebState}
    end;

%%--------------------------------------------------------------------
%% @doc
%% WebSocket Ping 帧回调——经 SendGate 回 Pong。
%%
%% @param WsOpPing 帧操作码（Ping）
%% @param Payload  Pong 负载
%% @param WebState 当前 WebSocket 应用状态
%% @return {ok, WebState}
%% @end
%%--------------------------------------------------------------------
handleWs(?WsOpPing, Payload, WebState) ->
    alWs:touchLastActivity(),
    alWs:outViaGate(?WsOpPong, Payload),
    {ok, WebState};

%%--------------------------------------------------------------------
%% @doc
%% WebSocket Pong 帧回调——刷新客户端活动时间，供心跳 stale 检测使用。
%%
%% @param WsOpPong 帧操作码（Pong）
%% @param _Payload  Pong 负载（未使用）
%% @param WebState  当前 WebSocket 应用状态
%% @return {ok, WebState}
%% @end
%%--------------------------------------------------------------------
handleWs(?WsOpPong, _Payload, WebState) ->
    alWs:touchLastActivity(),
    {ok, WebState};

%%--------------------------------------------------------------------
%% @doc
%% WebSocket Close 帧回调——停止心跳并关闭连接。
%%
%% @param WsOpClose 帧操作码（Close）
%% @param Payload   关闭原因（未使用）
%% @param WebState  当前 WebSocket 应用状态
%% @return {close, WebState}
%% @end
%%--------------------------------------------------------------------
handleWs(?WsOpClose, _Payload, WebState) ->
    alWs:stopHeartbeat(),
    {close, WebState};

%%--------------------------------------------------------------------
%% @doc
%% 其他类型 WebSocket 帧的兜底处理——忽略并保持连接。
%%
%% @param _Opcode  帧操作码
%% @param _Payload 帧负载
%% @param WebState 当前 WebSocket 应用状态
%% @return {ok, WebState}
%% @end
%%--------------------------------------------------------------------
handleWs(_Opcode, _Payload, WebState) ->
    alWs:touchLastActivity(),
    {ok, WebState}.

%%--------------------------------------------------------------------
%% @doc
%% CORS 预检响应：返回 204 No Content，附带缓存的 CORS 头与安全头。
%%
%% @return eWSrv 三元组 {204, Headers, <<>>}
%% @end
%%--------------------------------------------------------------------
preflightResponse() ->
    {204, corsHeadersCached() ++ alWebSec:securityHeaders(), <<>>}.

%%%===================================================================
%%% Routing
%%%===================================================================

%% 路由：GET / —— 返回 WebUI 首页 index.html
dispatch('GET', <<"/">>, _WsReq) ->
    serveIndex();

%% 路由：GET /static/<rest> —— 返回 priv/web/static 下的静态资源
dispatch('GET', <<"/static/", Rest/binary>>, _WsReq) ->
    servePriv(<<"web/static/", Rest/binary>>);

%% 路由：GET /api/health —— 健康检查（core 服务+网关状态）
dispatch('GET', <<"/api/health">>, _WsReq) ->
    Status = case alCoreClient:health() of
        {ok, _} -> ok;
        _ -> degraded
    end,
    jsonResponse(200, #{status => Status, gateway => up});

%% 路由：GET /api/tools —— 列出所有可用工具及 MCP 工具规格
dispatch('GET', <<"/api/tools">>, _WsReq) ->
    jsonResponse(200, #{tools => alToolCatalog:allTools(), specs => alToolCatalog:mcpTools()});

%% 路由：GET /api/status —— 网关状态详情（core、port、mode、version）
dispatch('GET', <<"/api/status">>, _WsReq) ->
    CoreStatus = case alCoreClient:health() of
        {ok, _} -> up;
        _ -> down
    end,
    jsonResponse(200, #{
        core => CoreStatus,
        gateway => up,
        port => alHttpGateway:port(),
        mode => maps:get(mode, alConfig:getAgentCfg(), ask),
        version => list_to_binary(?MODULE_STRING)
    });

%% 路由：POST /api/ask —— 同步问答请求
dispatch('POST', <<"/api/ask">>, WsReq) ->
    handleAsk(WsReq#wsReq.body);

%% 路由：GET /api/ask/stream —— SSE 流式问答请求
dispatch('GET', <<"/api/ask/stream">>, WsReq) ->
    handleAskStreamReq(WsReq);

%% 路由：GET /api/sessions —— 列出活跃会话与已保存会话
dispatch('GET', <<"/api/sessions">>, _WsReq) ->
    jsonResponse(200, #{
        active => safeServerCall(fun alServer:sessions/0, []),
        saved => safeServerCall(fun alSessionMgr:listSavedSessions/0, [])
    });

%% 路由：POST /api/sessions/load —— 加载指定会话并返回其消息列表
%% 优先磁盘 JSON（saveSession 产物）；没有文件则从 DB/内存读取，
%% 保证刷新网页后默认 web 会话仍能恢复问答历史。
dispatch('POST', <<"/api/sessions/load">>, WsReq) ->
    handleJsonBody(WsReq#wsReq.body, fun(#{<<"sessionId">> := Sid}) ->
        SidParsed = parseSessionId(Sid),
        Id = case alServer:loadSession(SidParsed) of
            {ok, LoadedId} ->
                LoadedId;
            {error, _} ->
                _ = alSessionMgr:ensureSession(SidParsed, <<"web">>),
                SidParsed
        end,
        #{
            status => ok,
            sessionId => Id,
            messages => sessionMessagesForApi(Id),
            toolTrace => sessionToolTraceForApi(Id)
        }
    end);

%% 路由：POST /api/sessions/save —— 保存指定会话到磁盘
dispatch('POST', <<"/api/sessions/save">>, WsReq) ->
    handleJsonBody(WsReq#wsReq.body, fun(Body) ->
        Sid = maps:get(<<"sessionId">>, Body, <<"web">>),
        case alServer:saveSession(parseSessionId(Sid)) of
            {ok, Path} -> #{status => ok, path => Path};
            {error, Reason} -> #{status => error, reason => Reason}
        end
    end);

%% 路由：POST /api/sessions/delete —— 删除指定会话文件
dispatch('POST', <<"/api/sessions/delete">>, WsReq) ->
    handleJsonBody(WsReq#wsReq.body, fun(#{<<"sessionId">> := Sid}) ->
        case safeSessionFilePath(parseSessionId(Sid)) of
            {ok, Path} ->
                case file:delete(Path) of
                    ok -> #{status => ok};
                    {error, Reason} -> #{status => error, reason => Reason}
                end;
            {error, forbidden} ->
                #{status => error, reason => forbidden}
        end
    end);

%% 路由：GET /api/tasks —— 列出所有任务
dispatch('GET', <<"/api/tasks">>, _WsReq) ->
    jsonResponse(200, #{tasks => alTask:list()});

%% 路由：POST /api/tasks/cancel —— 取消指定任务（需 sessionId 归属校验，W6）
dispatch('POST', <<"/api/tasks/cancel">>, WsReq) ->
    handleJsonBody(WsReq#wsReq.body, fun(Body) ->
        TaskId = maps:get(<<"taskId">>, Body, undefined),
        Sid = parseSessionId(maps:get(<<"sessionId">>, Body, <<"web">>)),
        case TaskId of
            undefined -> #{status => error, reason => missingTaskId};
            _ ->
                case alWs:ownsTask(Sid, TaskId) of
                    false -> #{status => error, reason => notOwned};
                    _ -> #{status => alServer:cancelTask(TaskId)}
                end
        end
    end);

%% 路由：GET /api/plan —— 返回指定会话的执行计划（含摘要）
dispatch('GET', <<"/api/plan">>, WsReq) ->
    Sid = queryParam(WsReq, <<"sessionId">>, <<"web">>),
    Plan = alPlan:getPlan(parseSessionId(Sid)),
    Summary = alPlan:withSummary(Plan),
    jsonResponse(200, planForApi(Summary));

%% 路由：GET /api/metrics —— 返回运行时指标快照（JSON）
dispatch('GET', <<"/api/metrics">>, _WsReq) ->
    Snap = alMetrics:snapshot(),
    jsonResponse(200, metricsForApi(Snap));
%% 路由：GET /api/metrics/prometheus —— Prometheus text exposition
dispatch('GET', <<"/api/metrics/prometheus">>, _WsReq) ->
    Body = alMetrics:prometheusText(),
    Headers = [{<<"content-type">>, <<"text/plain; version=0.0.4; charset=utf-8">>}
               | alWebSec:securityHeaders()],
    {200, Headers ++ corsHeadersCached(), Body};

%% 路由：GET /api/audit —— 返回最近 N 条审计日志（默认 20）
dispatch('GET', <<"/api/audit">>, WsReq) ->
    Limit = queryParamInt(WsReq, <<"limit">>, 20),
    jsonResponse(200, #{entries => alAudit:list(Limit)});

%% 路由：GET /api/context/last-compaction —— 最近一次 history compaction 统计
dispatch('GET', <<"/api/context/last-compaction">>, _WsReq) ->
    jsonResponse(200, #{last => alContext:lastCompaction()});

%% 路由：GET /api/mfa/whitelist —— 列出当前 MFA 白名单
dispatch('GET', <<"/api/mfa/whitelist">>, _WsReq) ->
    jsonResponse(200, alRuntimeProbe:listWhitelist());

%% 路由：POST /api/mfa/whitelist/add —— 添加 MFA 白名单
dispatch('POST', <<"/api/mfa/whitelist/add">>, WsReq) ->
    handleJsonBody(WsReq#wsReq.body, fun(Body) ->
        ok = alRuntimeProbe:addWhitelist(Body),
        #{status => ok, whitelist => alRuntimeProbe:listWhitelist()}
    end);

%% 路由：POST /api/mfa/whitelist/remove —— 移除 MFA 白名单
dispatch('POST', <<"/api/mfa/whitelist/remove">>, WsReq) ->
    handleJsonBody(WsReq#wsReq.body, fun(Body) ->
        ok = alRuntimeProbe:removeWhitelist(Body),
        #{status => ok, whitelist => alRuntimeProbe:listWhitelist()}
    end);

%% 路由：POST /api/mfa/whitelist/reload —— 重新加载（清运行时层）
dispatch('POST', <<"/api/mfa/whitelist/reload">>, _WsReq) ->
    ok = alRuntimeProbe:reloadWhitelist(),
    #{status => ok, whitelist => alRuntimeProbe:listWhitelist()};

%% 路由：GET /api/archive/snapshots —— 最近 N 小时指标归档
dispatch('GET', <<"/api/archive/snapshots">>, WsReq) ->
    Limit = queryParamInt(WsReq, <<"limit">>, 24),
    jsonResponse(200, #{snapshots => alArchive:listSnapshots(Limit)});

%% 路由：GET /api/archive/audit —— 最近 N 小时审计归档
dispatch('GET', <<"/api/archive/audit">>, WsReq) ->
    Limit = queryParamInt(WsReq, <<"limit">>, 24),
    jsonResponse(200, #{archives => alArchive:listAudit(Limit)});

%% 路由：POST /api/archive/run —— 立即归档当前小时
dispatch('POST', <<"/api/archive/run">>, _WsReq) ->
    {ok, Result} = alArchive:archiveNow(),
    jsonResponse(200, Result);

%% 路由：GET /api/db —— 列出 ali.db 白名单表及行数
dispatch('GET', <<"/api/db">>, _WsReq) ->
    case alDbBrowse:tables() of
        {ok, Items} ->
            jsonResponse(200, #{
                status => ok,
                path => toBinary(filename:join(alConfig:dataDir(), "db/ali.db")),
                tables => [encodeApiMessage(I) || I <- Items]
            });
        {error, Reason} ->
            jsonResponse(500, #{status => error, reason => Reason})
    end;

%% 路由：GET /api/db/rows —— 浏览某表行
dispatch('GET', <<"/api/db/rows">>, WsReq) ->
    Table = queryParam(WsReq, <<"table">>, <<"memories">>),
    Limit = queryParamInt(WsReq, <<"limit">>, 50),
    Offset = queryParamInt(WsReq, <<"offset">>, 0),
    Q = queryParam(WsReq, <<"q">>, <<>>),
    case alDbBrowse:list(Table, #{limit => Limit, offset => Offset, q => Q}) of
        {ok, Result} ->
            jsonResponse(200, maps:merge(#{status => ok}, encodeApiMessage(Result)));
        {error, unknown_table} ->
            jsonResponse(400, #{status => error, reason => unknown_table});
        {error, Reason} ->
            jsonResponse(500, #{status => error, reason => Reason})
    end;

%% 路由：GET /api/memory —— 浏览长期记忆（蒸馏 / 对话整理）
dispatch('GET', <<"/api/memory">>, WsReq) ->
    Limit = queryParamInt(WsReq, <<"limit">>, 50),
    Kind = queryParam(WsReq, <<"kind">>, undefined),
    Tag = queryParam(WsReq, <<"tag">>, undefined),
    Q = queryParam(WsReq, <<"q">>, <<>>),
    Sid = queryParam(WsReq, <<"sessionId">>, undefined),
    Opts0 = #{limit => Limit},
    Opts1 = case Kind of undefined -> Opts0; <<>> -> Opts0; K -> Opts0#{kind => K} end,
    Opts2 = case Tag of undefined -> Opts1; <<>> -> Opts1; T -> Opts1#{tag => T} end,
    Opts3 = case Q of <<>> -> Opts2; _ -> Opts2#{q => Q} end,
    Opts = case Sid of undefined -> Opts3; <<>> -> Opts3; S -> Opts3#{sessionId => parseSessionId(S)} end,
    case alMemory:list(Opts) of
        {ok, Rows} ->
            jsonResponse(200, #{
                status => ok,
                count => length(Rows),
                items => [encodeApiMessage(R) || R <- Rows]
            });
        {error, Reason} ->
            jsonResponse(500, #{status => error, reason => Reason})
    end;

%% 路由：POST /api/memory/forget —— 删除一条长期记忆
dispatch('POST', <<"/api/memory/forget">>, WsReq) ->
    handleJsonBody(WsReq#wsReq.body, fun(Body) ->
        Id = maps:get(<<"id">>, Body, maps:get(id, Body, undefined)),
        case alMemory:forget(Id) of
            {ok, DeletedId} -> #{status => ok, id => DeletedId};
            {error, notFound} -> #{status => error, reason => notFound};
            {error, Reason} -> #{status => error, reason => Reason}
        end
    end);

%% 路由：POST /api/memory/distill —— 从会话中蒸馏持久事实
dispatch('POST', <<"/api/memory/distill">>, WsReq) ->
    handleJsonBody(WsReq#wsReq.body, fun(Body) ->
        Sid0 = maps:get(<<"sessionId">>, Body, undefined),
        Sid = case Sid0 of
            undefined -> <<"web">>;
            _ ->
                case parseSessionId(Sid0) of
                    undefined -> <<"web">>;
                    Parsed -> Parsed
                end
        end,
        Msgs = maps:get(<<"messages">>, Body, undefined),
        Opts = case Msgs of
            undefined -> #{};
            List when is_list(List) -> #{messages => List};
            _ -> #{}
        end,
        case alMemory:distill(Sid, Opts) of
            {ok, Items} -> #{status => ok, saved => length(Items), items => Items};
            {error, Reason} -> #{status => error, reason => Reason}
        end
    end);

%% 路由：GET /api/index/git —— 列出 git 变更并触发增量索引
dispatch('GET', <<"/api/index/git">>, WsReq) ->
    Root = queryParam(WsReq, <<"root">>, undefined),
    case resolveAllowedRoot(Root) of
        {error, forbidden} -> jsonResponse(403, #{error => forbidden});
        R0 ->
            case alGitIndex:incrementalIndex(R0) of
                {ok, M} -> jsonResponse(200, M);
                {error, R} -> jsonResponse(500, #{error => R})
            end
    end;

%% 路由：GET /api/spec/usage —— 反向查询引用了某类型的 -spec
dispatch('GET', <<"/api/spec/usage">>, WsReq) ->
    Type = queryParam(WsReq, <<"type">>, undefined),
    Root = queryParam(WsReq, <<"root">>, undefined),
    Limit = case queryParam(WsReq, <<"limit">>, undefined) of
        undefined -> 200;
        L -> binary_to_integer(L)
    end,
    case {Type, resolveAllowedRoot(Root)} of
        {undefined, _} -> jsonResponse(400, #{error => missingType});
        {_, {error, forbidden}} -> jsonResponse(403, #{error => forbidden});
        {_, R0} ->
            {ok, Usages} = alSpecIndex:findTypeUsages(Type, R0, Limit),
            jsonResponse(200, #{type => Type, count => length(Usages), usages => Usages})
    end;

%% 路由：GET /api/spec/search —— 正则搜索所有 -spec
dispatch('GET', <<"/api/spec/search">>, WsReq) ->
    Pattern = queryParam(WsReq, <<"pattern">>, undefined),
    Root = queryParam(WsReq, <<"root">>, undefined),
    Limit = case queryParam(WsReq, <<"limit">>, undefined) of
        undefined -> 200;
        L -> binary_to_integer(L)
    end,
    case {Pattern, resolveAllowedRoot(Root)} of
        {undefined, _} -> jsonResponse(400, #{error => missingPattern});
        {_, {error, forbidden}} -> jsonResponse(403, #{error => forbidden});
        {_, R0} ->
            {ok, Hits} = alSpecIndex:searchSpecs(Pattern, R0, Limit),
            jsonResponse(200, #{pattern => Pattern, count => length(Hits), hits => Hits})
    end;

%% 路由：GET /api/backups —— 按路径或会话 ID 列出备份
dispatch('GET', <<"/api/backups">>, WsReq) ->
    case {queryParam(WsReq, <<"path">>, undefined),
          queryParam(WsReq, <<"sessionId">>, undefined)} of
        {undefined, undefined} ->
            jsonResponse(400, #{error => missingPathOrSessionId});
        {Path, undefined} when Path =/= undefined ->
            jsonResponse(200, #{backups => alBackup:listBackups(unicode:characters_to_list(Path))});
        {_, SessionId} when SessionId =/= undefined ->
            jsonResponse(200, #{backups => alBackup:listSessionBackups(SessionId)})
    end;

%% 路由：POST /api/backups/restore —— 从备份路径恢复（路径须落在备份目录内）
dispatch('POST', <<"/api/backups/restore">>, WsReq) ->
    handleJsonBody(WsReq#wsReq.body, fun(#{<<"backupPath">> := BackupPath}) ->
        case alWebSec:isPathWithin(alBackup:backupDir(), toBinary(BackupPath)) of
            false ->
                #{status => error, reason => forbidden};
            true ->
                case alBackup:restore(BackupPath) of
                    ok -> #{status => ok};
                    {error, Reason} -> #{status => error, reason => Reason}
                end
        end
    end);

%% 路由：POST /api/backups/restore-session —— 按会话 ID 恢复备份
dispatch('POST', <<"/api/backups/restore-session">>, WsReq) ->
    handleJsonBody(WsReq#wsReq.body, fun(#{<<"sessionId">> := SessionId}) ->
        case alBackup:restoreSession(SessionId) of
            {ok, Result} -> #{status => ok, result => Result};
            {error, Reason} -> #{status => error, reason => Reason}
        end
    end);

%% 路由：GET /api/tokenStats —— 返回 token 使用统计
dispatch('GET', <<"/api/tokenStats">>, _WsReq) ->
    jsonResponse(200, alTokenStats:stats());

%% 路由：POST /api/tokenStats/reset —— 重置 token 统计
dispatch('POST', <<"/api/tokenStats/reset">>, _WsReq) ->
    alTokenStats:reset(),
    jsonResponse(200, #{status => ok});

%% 路由：POST /api/mode —— 设置运行模式（ask/agent 等）
dispatch('POST', <<"/api/mode">>, WsReq) ->
    handleJsonBody(WsReq#wsReq.body, fun(#{<<"mode">> := Mode}) ->
        alServer:setMode(Mode),
        #{status => ok, mode => Mode}
    end);

%% 路由：POST /api/clear —— 清空指定会话
dispatch('POST', <<"/api/clear">>, WsReq) ->
    handleJsonBody(WsReq#wsReq.body, fun(Body) ->
        Sid = maps:get(<<"sessionId">>, Body, <<"web">>),
        #{status => alServer:clearSession(parseSessionId(Sid))}
    end);

%% 路由：POST /api/index/refresh —— 刷新全部代码根目录索引
dispatch('POST', <<"/api/index/refresh">>, WsReq) ->
    Force = case queryParam(WsReq, <<"force">>, <<"false">>) of
        <<"true">> -> true;
        <<"1">> -> true;
        _ -> false
    end,
    case ali:indexRoots(#{force_reparse => Force}) of
        {ok, Result} ->
            _ = alProjectDigest:maybeBuildAfterIndex(),
            jsonResponse(200, #{status => ok, result => Result, forceReparse => Force});
        {error, Reason} -> jsonResponse(200, #{status => error, reason => Reason})
    end;

%% 路由：GET /api/digest/status —— 项目知识库状态
dispatch('GET', <<"/api/digest/status">>, _WsReq) ->
    jsonResponse(200, maps:merge(#{status => ok}, alProjectDigest:status()));

%% 路由：GET /api/digest/search —— 跨层搜索 knowledge
dispatch('GET', <<"/api/digest/search">>, WsReq) ->
    Q = queryParam(WsReq, <<"q">>, queryParam(WsReq, <<"query">>, <<>>)),
    Limit = queryParamInt(WsReq, <<"limit">>, 30),
    case alProjectDigest:search(Q, Limit) of
        {ok, Hits} -> jsonResponse(200, #{status => ok, query => Q, total => length(Hits), hits => Hits});
        {error, Reason} -> jsonResponse(200, #{status => error, reason => Reason})
    end;

%% 路由：GET /api/digest/browse —— 按层浏览 knowledge
dispatch('GET', <<"/api/digest/browse">>, WsReq) ->
    Layer = queryParam(WsReq, <<"layer">>, <<"overview">>),
    Q = queryParam(WsReq, <<"q">>, <<>>),
    Limit = queryParamInt(WsReq, <<"limit">>, 80),
    Offset = queryParamInt(WsReq, <<"offset">>, 0),
    case alProjectDigest:browse(#{layer => Layer, q => Q, limit => Limit, offset => Offset}) of
        {ok, Data} -> jsonResponse(200, maps:merge(#{status => ok}, Data));
        {error, Reason} -> jsonResponse(200, #{status => error, reason => Reason})
    end;

%% 路由：GET /api/digest/summary —— 读取一条主题摘要
dispatch('GET', <<"/api/digest/summary">>, WsReq) ->
    Topic = queryParam(WsReq, <<"topic">>, <<>>),
    case alProjectDigest:getSummary(Topic) of
        {ok, Data} -> jsonResponse(200, maps:merge(#{status => ok}, Data));
        {error, notFound} -> jsonResponse(404, #{status => error, reason => notFound});
        {error, Reason} -> jsonResponse(200, #{status => error, reason => Reason})
    end;

%% 路由：POST /api/digest/build —— 构建/刷新项目知识库
dispatch('POST', <<"/api/digest/build">>, WsReq) ->
    handleJsonBody(WsReq#wsReq.body, fun(Body) ->
        Opts0 = #{},
        Opts1 = case maps:get(<<"maxModules">>, Body, undefined) of
            N when is_integer(N), N > 0 -> Opts0#{maxModules => N};
            <<"unlimited">> -> Opts0#{maxModules => unlimited};
            <<"all">> -> Opts0#{maxModules => unlimited};
            _ -> Opts0
        end,
        Opts2 = case maps:get(<<"maxSummaryWarm">>, Body, undefined) of
            W when is_integer(W), W > 0 -> Opts1#{maxSummaryWarm => W};
            _ -> Opts1
        end,
        case alProjectDigest:rebuild(Opts2) of
            {ok, Meta} ->
                #{status => ok, meta => Meta, path => alProjectDigest:knowledgeDir()};
            {error, Reason} ->
                #{status => error, reason => Reason}
        end
    end);

%% 路由：GET /api/core/status —— aliCore 健康 + 索引状态 + DB（面板校验用）
dispatch('GET', <<"/api/core/status">>, _WsReq) ->
    jsonResponse(200, coreInspectStatus());

%% 路由：GET /api/core/modules —— 已索引模块列表
dispatch('GET', <<"/api/core/modules">>, WsReq) ->
    Q = queryParam(WsReq, <<"q">>, <<>>),
    Limit = queryParamInt(WsReq, <<"limit">>, 100),
    Offset = queryParamInt(WsReq, <<"offset">>, 0),
    Opts = #{q => Q, limit => Limit, offset => Offset},
    case alCoreClient:listModules(Opts) of
        {ok, Data} -> jsonResponse(200, #{status => ok, data => unwrapCoreInspect(Data)});
        {error, Reason} -> jsonResponse(200, #{status => error, reason => Reason})
    end;

%% 路由：POST /api/core/search —— BM25 代码搜索
dispatch('POST', <<"/api/core/search">>, WsReq) ->
    handleJsonBody(WsReq#wsReq.body, fun(Body) ->
        Query = maps:get(<<"query">>, Body, maps:get(<<"q">>, Body, <<>>)),
        Limit = coreBodyInt(Body, <<"limit">>, 20),
        case alCoreClient:search(Query, Limit) of
            {ok, Data} -> #{status => ok, data => unwrapCoreInspect(Data)};
            {error, Reason} -> #{status => error, reason => Reason}
        end
    end);

%% 路由：POST /api/core/module —— 模块符号（calls 默认截断便于面板）
dispatch('POST', <<"/api/core/module">>, WsReq) ->
    handleJsonBody(WsReq#wsReq.body, fun(Body) ->
        Module = maps:get(<<"module">>, Body, undefined),
        MaxCalls = coreBodyInt(Body, <<"maxCalls">>, 80),
        case Module of
            undefined -> #{status => error, reason => missingModule};
            _ ->
                case alCoreClient:moduleSymbols(Module) of
                    {ok, Data} ->
                        Doc0 = unwrapCoreInspect(Data),
                        #{status => ok, data => truncateModuleSymbols(Doc0, MaxCalls)};
                    {error, Reason} ->
                        #{status => error, reason => Reason}
                end
        end
    end);

%% 路由：POST /api/core/callers —— 谁调用了 MFA（含 Mermaid）
%% Body 可带 direction=callers|callees|both（both=双向调用链）
dispatch('POST', <<"/api/core/callers">>, WsReq) ->
    handleJsonBody(WsReq#wsReq.body, fun(Body) ->
        coreGraphQuery(callers, Body)
    end);

%% 路由：POST /api/core/callees —— MFA 调用了谁（含 Mermaid）
dispatch('POST', <<"/api/core/callees">>, WsReq) ->
    handleJsonBody(WsReq#wsReq.body, fun(Body) ->
        coreGraphQuery(callees, Body)
    end);

%% 路由：POST /api/approve —— 批准挂起任务（需 sessionId 归属校验，W6）
dispatch('POST', <<"/api/approve">>, WsReq) ->
    handleJsonBody(WsReq#wsReq.body, fun(Body) ->
        TaskId = maps:get(<<"taskId">>, Body, undefined),
        Sid = parseSessionId(maps:get(<<"sessionId">>, Body, <<"web">>)),
        case TaskId of
            undefined -> #{status => error, reason => missingTaskId};
            _ ->
                case alWs:ownsPending(Sid, TaskId) of
                    false -> #{status => error, reason => notOwned};
                    _ ->
                        case alServer:approve(TaskId) of
                            {ok, Result} -> approveResponse(Result);
                            {error, Reason} -> #{status => error, reason => Reason}
                        end
                end
        end
    end);

%% 路由：POST /api/dismiss —— 忽略/驳回挂起任务（需 sessionId 归属校验，W6）
dispatch('POST', <<"/api/dismiss">>, WsReq) ->
    handleJsonBody(WsReq#wsReq.body, fun(Body) ->
        TaskId = maps:get(<<"taskId">>, Body, undefined),
        Sid = parseSessionId(maps:get(<<"sessionId">>, Body, <<"web">>)),
        case TaskId of
            undefined -> #{status => error, reason => missingTaskId};
            _ ->
                case alWs:ownsPending(Sid, TaskId) of
                    false -> #{status => error, reason => notOwned};
                    _ ->
                        case alServer:dismiss(TaskId) of
                            ok -> #{status => ok};
                            {error, Reason} -> #{status => error, reason => Reason}
                        end
                end
        end
    end);

%% 路由：POST /api/ask/cancel —— 取消指定会话问答；可选 taskId（缺省/all=整会话）
%% sessionId 为归属凭据；带具体 taskId 时再校验任务归属（W6）。
dispatch('POST', <<"/api/ask/cancel">>, WsReq) ->
    handleJsonBody(WsReq#wsReq.body, fun(Body) ->
        Sid = parseSessionId(maps:get(<<"sessionId">>, Body, <<"web">>)),
        case maps:get(<<"taskId">>, Body, undefined) of
            undefined -> #{status => alServer:cancelAsk(Sid)};
            <<"all">> -> #{status => alServer:cancelAsk(Sid)};
            all -> #{status => alServer:cancelAsk(Sid)};
            TaskId ->
                case alWs:ownsTask(Sid, TaskId) of
                    false -> #{status => error, reason => notOwned};
                    _ -> #{status => alServer:cancelAskByTaskId(Sid, TaskId)}
                end
        end
    end);

%% 路由：POST /api/ask/stream —— SSE 流式问答请求（POST 版）
dispatch('POST', <<"/api/ask/stream">>, WsReq) ->
    handleAskStreamReq(WsReq);

%% 路由：GET /api/llm/providers —— 返回支持的 LLM 提供商列表
dispatch('GET', <<"/api/llm/providers">>, _WsReq) ->
    jsonResponse(200, #{providers => alLlmCatalog:providers_for_web()});

%% 路由：GET /api/files —— 列出项目文件；或 content=true 时读取单文件。
%% query: path、recursive；content=true 时另支持 maxBytes（默认/上限 5MiB）
dispatch('GET', <<"/api/files">>, WsReq) ->
    case queryParam(WsReq, <<"content">>, <<"false">>) of
        <<"true">> ->
            fileContentResponse(WsReq);
        _ ->
            Path = queryParam(WsReq, <<"path">>, <<".">>),
            case alWebSec:isDeniedFileApiPath(Path) of
                true ->
                    jsonResponse(403, #{status => error, reason => pathNotAllowed,
                                        error => pathNotAllowed});
                false ->
                    Recursive = queryParam(WsReq, <<"recursive">>, <<"false">>) =:= <<"true">>,
                    case alToolsExt:listFiles(#{path => Path, recursive => Recursive, maxEntries => 5000}) of
                        {ok, Map} ->
                            %% 始终带上解析后的 projectRoot，便于 Web 与配置对齐展示
                            RootBin = unicode:characters_to_binary(alConfig:projectRoot()),
                            jsonResponse(200, Map#{status => ok, projectRoot => RootBin});
                        {error, Reason} -> jsonResponse(400, #{status => error, reason => Reason})
                    end
            end
    end;

%% 路由：GET /api/file —— 读取单个文件内容（与 /api/files?content=true 等价）
dispatch('GET', <<"/api/file">>, WsReq) ->
    fileContentResponse(WsReq);

%% 路由：GET /api/files/content —— 同上（兼容别名）
dispatch('GET', <<"/api/files/content">>, WsReq) ->
    fileContentResponse(WsReq);

%% 路由：PUT /api/file —— 覆盖写入单个文件内容（文件查看器内联编辑）。
%% 写入受 allowedRoots（src/config/priv）约束，与 patch/writeFile 共用同一策略。
dispatch('PUT', <<"/api/file">>, WsReq) ->
    handleJsonBody(WsReq#wsReq.body, fun(Body) ->
        Path = maps:get(<<"path">>, Body, <<>>),
        Content = maps:get(<<"content">>, Body, <<>>),
        case Path of
            <<>> ->
                #{status => error, reason => missingPath, error => missingPath};
            _ ->
                case alWebSec:isDeniedFileApiPath(Path) of
                    true ->
                        #{status => error, reason => pathNotAllowed, error => pathNotAllowed};
                    false ->
                        case alToolsExt:writeFile(#{path => Path, content => Content}) of
                            {ok, #{bytes := Bytes}} ->
                                #{status => ok, path => Path, bytes => Bytes};
                            {error, Reason} ->
                                #{status => error, reason => Reason, error => Reason}
                        end
                end
        end
    end);

%% 路由：GET /api/pending —— 列出全部待确认任务（重启恢复后可发现）
dispatch('GET', <<"/api/pending">>, _WsReq) ->
    jsonResponse(200, #{status => ok, pending => alServer:pendingList()});

%% 路由：GET /api/pending/<taskId> —— 查询挂起任务状态
dispatch('GET', <<"/api/pending/", TaskId/binary>>, _WsReq) ->
    case alServer:pendingTask(TaskId) of
        {ok, Entry} -> jsonResponse(200, #{status => ok, pending => Entry});
        {error, Reason} -> jsonResponse(404, #{status => error, reason => Reason})
    end;

%% Checkpoint resume / list / delete
dispatch('GET', <<"/api/checkpoints">>, _WsReq) ->
    jsonResponse(200, #{status => ok, checkpoints => [checkpointInfo(T) || T <- alCheckpoint:list()]});
dispatch('POST', <<"/api/checkpoints/resume">>, WsReq) ->
    %% W6：要求 body.sessionId，并校验 checkpoint 归属（与 WS resume 对齐）。
    handleJsonBody(WsReq#wsReq.body, fun(Body) ->
        TaskId = maps:get(<<"taskId">>, Body, undefined),
        Sid = parseSessionId(maps:get(<<"sessionId">>, Body, <<"web">>)),
        case TaskId of
            undefined -> #{status => error, reason => missingTaskId};
            _ ->
                case alWs:ownsCheckpoint(Sid, TaskId) of
                    false -> #{status => error, reason => notOwned};
                    _ ->
                        case ali:resumeCheckpoint(TaskId) of
                            {ok, Result} -> #{status => ok, result => Result};
                            {error, Reason} -> #{status => error, reason => Reason};
                            Other -> #{status => ok, result => Other}
                        end
                end
        end
    end);
dispatch('POST', <<"/api/checkpoints/delete">>, WsReq) ->
    handleJsonBody(WsReq#wsReq.body, fun(#{<<"taskId">> := TaskId}) ->
        case ali:deleteCheckpoint(TaskId) of
            ok -> #{status => ok};
            {error, Reason} -> #{status => error, reason => Reason}
        end
    end);

%% MCP + legacy gateway tool endpoints

%% 路由：GET /health —— MCP/网关健康检查
dispatch('GET', <<"/health">>, _WsReq) ->
    Status = case alCoreClient:health() of
        {ok, _} -> ok;
        _ -> degraded
    end,
    jsonResponse(200, #{status => Status, gateway => up});

%% 路由：GET /tools —— 列出工具（binary 形式）及 MCP 规格
dispatch('GET', <<"/tools">>, _WsReq) ->
    Tools = [atom_to_binary(T, utf8) || T <- alToolCatalog:allTools()],
    jsonResponse(200, #{tools => Tools, specs => alToolCatalog:mcpTools()});

%% 路由：POST /tool —— 统一格式调用工具 {tool, args}
dispatch('POST', <<"/tool">>, WsReq) ->
    handleMcpToolBody(WsReq#wsReq.body);

%% 路由：POST /v1/tools/call —— MCP 标准 tool/call 入口，先转统一格式再调用
dispatch('POST', <<"/v1/tools/call">>, WsReq) ->
    handleMcpToolBody(mcpToolCallToUnified(WsReq#wsReq.body));

%% 路由：兜底——所有未匹配请求返回 404
dispatch(_Method, _Path, _WsReq) ->
    jsonResponse(404, #{error => notFound}).

%%%===================================================================
%%% MCP tool handlers
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 处理 MCP 工具调用请求体。解析 JSON，提取 `tool`/`args` 字段，
%% 将工具名尝试转换为 existing atom，规范化参数后调用
%% alToolCatalog:invoke。任何 JSON 错误返回 400。
%%
%% @param Body 请求体二进制
%% @return eWSrv 三元组
%% @end
%%--------------------------------------------------------------------
handleMcpToolBody(Body) ->
    try alJson:decode(Body) of
        #{<<"tool">> := ToolBin, <<"args">> := Args} ->
            case alToolCatalog:resolveToolName(ToolBin) of
                {ok, Tool} ->
                    Normalized = normalizeMcpArgs(Args),
                    case alToolCatalog:invoke(Tool, Normalized) of
                        {ok, Value} ->
                            jsonResponse(200, #{status => ok, result => Value});
                        {error, Reason} ->
                            jsonResponse(200, #{status => error, reason => Reason})
                    end;
                error ->
                    jsonResponse(200, #{status => error, reason => {unknownTool, ToolBin}})
            end;
        Other when is_map(Other) ->
            jsonResponse(400, #{error => missingToolOrArgs});
        _ ->
            jsonResponse(400, #{error => invalidJson})
    catch
        _:_ ->
            jsonResponse(400, #{error => invalidJson})
    end.

%%--------------------------------------------------------------------
%% @doc
%% 将 MCP 标准请求 `{name, arguments}` 转换为统一格式 `{tool, args}`。
%% 若已是统一格式则原样返回；解析失败时返回原 body。
%%
%% @param Body 原始请求体
%% @return 转换后的请求体二进制
%% @end
%%--------------------------------------------------------------------
mcpToolCallToUnified(Body) ->
    try alJson:decode(Body) of
        #{<<"name">> := Name, <<"arguments">> := Args} ->
            alJson:encode(#{<<"tool">> => Name, <<"args">> => Args});
        #{<<"tool">> := _, <<"args">> := _} = Map ->
            alJson:encode(Map);
        _ ->
            Body
    catch
        _:_ ->
            Body
    end.

%% 递归规范化 MCP 参数 map：将键转 existing atom，值递归处理
normalizeMcpArgs(Map) when is_map(Map) ->
    maps:from_list([{normalizeMcpKey(K), normalizeMcpValue(V)} || {K, V} <- maps:to_list(Map)]);
%% 非 map 值原样返回
normalizeMcpArgs(V) ->
    V.

%% 将二进制键转为 existing atom（若不存在则保留二进制）
normalizeMcpKey(K) when is_binary(K) ->
    try binary_to_existing_atom(K, utf8) catch _:_ -> K end;
%% 非二进制键原样返回
normalizeMcpKey(K) -> K.

%% 嵌套 map 递归规范化
normalizeMcpValue(V) when is_map(V) -> normalizeMcpArgs(V);
%% 列表元素递归规范化
normalizeMcpValue(V) when is_list(V) -> [normalizeMcpValue(I) || I <- V];
%% 其他类型原样返回
normalizeMcpValue(V) -> V.

%%%===================================================================
%%% /api/ask handler
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 处理 /api/ask 同步问答请求。解析 JSON，提取 prompt/question 与
%% sessionId，合并附件相关选项后调用 runAsk。无效 JSON 或缺少
%% prompt 返回 400。
%%
%% @param Body 请求体二进制
%% @return eWSrv 三元组
%% @end
%%--------------------------------------------------------------------
handleAsk(Body) ->
    try alJson:decode(Body) of
        Decoded when is_map(Decoded) ->
            case promptFromMap(Decoded) of
                undefined ->
                    jsonResponse(400, #{error => missingQuestion});
                Question ->
                    Opts0 = #{sessionId => sessionFromMap(Decoded), persistMemory => true},
                    case alAttachments:optsFromBody(Decoded) of
                        {ok, AttachOpts} ->
                            Opts = alAttachments:mergeOpts(Opts0, AttachOpts),
                            runAsk(Question, Opts);
                        {error, Reason} ->
                            jsonResponse(400, #{error => Reason})
                    end
            end;
        _ ->
            jsonResponse(400, #{error => invalidJson})
    catch _:_ ->
        jsonResponse(400, #{error => invalidJson})
    end.

%%--------------------------------------------------------------------
%% @doc
%% 处理 /api/ask/stream SSE 流式问答请求（兼容 GET EventSource 与
%% POST fetch）。使用 eWSrv chunked transfer 逐 token 转发 LLM stream
%% 事件，实现真正的 SSE 流式推送。
%%
%% @param WsReq eWSrv 请求记录
%% @return eWSrv chunk 三元组 {chunk, Headers, Initial}
%% @end
%%--------------------------------------------------------------------
handleAskStreamReq(WsReq) ->
    case askStreamParams(WsReq) of
        {ok, Question, Opts} ->
            runAskSse(Question, Opts);
        {error, Reason} ->
            jsonResponse(400, #{error => Reason})
    end.

%%--------------------------------------------------------------------
%% @doc
%% 从请求中提取流式问答参数：GET 从查询参数取 prompt/question 与
%% sessionId；其他方法从请求体解析。
%%
%% @param WsReq eWSrv 请求记录
%% @return {ok, Prompt, Opts} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
askStreamParams(WsReq) ->
    case normalizeMethod(WsReq#wsReq.method) of
        'GET' ->
            Prompt = queryParam(WsReq, <<"prompt">>, queryParam(WsReq, <<"question">>, undefined)),
            Sid = queryParam(WsReq, <<"sessionId">>, queryParam(WsReq, <<"sessionId">>, <<"web">>)),
            case Prompt of
                undefined -> {error, missingQuestion};
                <<>> -> {error, missingQuestion};
                _ -> {ok, Prompt, #{sessionId => Sid, persistMemory => true}}
            end;
        _ ->
            askStreamParamsBody(WsReq#wsReq.body)
    end.

%% 空请求体直接返回 missingQuestion
askStreamParamsBody(Body) when Body =:= undefined; Body =:= <<>>; Body =:= "" ->
    {error, missingQuestion};
%% 解析 JSON 请求体，提取 prompt 与 sessionId，并合并附件选项
askStreamParamsBody(Body) ->
    try alJson:decode(Body) of
        Decoded when is_map(Decoded) ->
            case promptFromMap(Decoded) of
                undefined ->
                    {error, missingQuestion};
                Question ->
                    Opts0 = #{sessionId => sessionFromMap(Decoded), persistMemory => true},
                    Opts1 = case maps:get(<<"llm">>, Decoded, undefined) of
                        Llm when is_map(Llm) ->
                            case alWs:sanitizeLlmOverride(Llm) of
                                undefined -> Opts0;
                                Override -> Opts0#{llmOverride => Override}
                            end;
                        _ -> Opts0
                    end,
                    case alAttachments:optsFromBody(Decoded) of
                        {ok, AttachOpts} ->
                            {ok, Question, alAttachments:mergeOpts(Opts1, AttachOpts)};
                        {error, Reason} ->
                            {error, Reason}
                    end
            end;
        _ ->
            {error, invalidJson}
    catch
        _:_ ->
            {error, invalidJson}
    end.

%% atom 方法名原样返回
normalizeMethod(Method) when is_atom(Method) ->
    Method;
%% 二进制方法名大写后映射为 atom，未识别时默认 POST
normalizeMethod(Method) when is_binary(Method) ->
    case string:uppercase(Method) of
        <<"GET">> -> 'GET';
        <<"POST">> -> 'POST';
        <<"PUT">> -> 'PUT';
        <<"DELETE">> -> 'DELETE';
        <<"OPTIONS">> -> 'OPTIONS';
        <<"HEAD">> -> 'HEAD';
        <<"PATCH">> -> 'PATCH';
        _ -> 'POST'
    end;
%% 列表方法名先转二进制再递归处理
normalizeMethod(Method) when is_list(Method) ->
    normalizeMethod(unicode:characters_to_binary(Method));
%% 其他类型默认 POST
normalizeMethod(_) ->
    'POST'.

%% 从 map 中提取 prompt，回退到 question
promptFromMap(Map) ->
    case maps:get(<<"prompt">>, Map, undefined) of
        undefined -> maps:get(<<"question">>, Map, undefined);
        Prompt -> Prompt
    end.

%% 从 map 中提取 sessionId，回退到 session_id，最终回退 <<"web">>
sessionFromMap(Map) ->
    case maps:get(<<"sessionId">>, Map, undefined) of
        undefined -> maps:get(<<"session_id">>, Map, <<"web">>);
        Sid -> Sid
    end.

%%--------------------------------------------------------------------
%% @doc
%% 执行真流式 SSE 问答。生成唯一 TaskId，确保会话存在，spawn worker
%% 调用 alServer:askStream/2 并将 {eStreamChunk,...} 事件逐条转发为
%% eWSrv chunk 消息。返回 {chunk, Headers, Initial} 触发 eWSrv chunkLoop。
%%
%% @param Question 用户问题
%% @param Opts     调用选项
%% @return eWSrv chunk 三元组 {chunk, Headers, <<>>}
%% @end
%%--------------------------------------------------------------------
runAskSse(Question, Opts) ->
    Sid = maps:get(sessionId, Opts, <<"web">>),
    safeEnsureSession(Sid),
    Mode = safeGetMode(),
    TaskId = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    FinalOpts = Opts#{
        persistMemory => true,
        mode => Mode,
        progressId => TaskId,
        taskId => TaskId
    },
    HandlerPid = self(),
    spawn(fun() -> sseStreamWorker(HandlerPid, Question, FinalOpts, Sid, TaskId) end),
    {chunk, sseHeaders(), <<>>}.

%%--------------------------------------------------------------------
%% @doc
%% SSE 流式 worker：调用 alServer:askStream/2 启动 LLM stream，
%% 成功后进入接收循环将 chunk 逐条转发给 eWSrv handler 进程；
%% 失败时发送错误 SSE 帧并关闭。
%%
%% @param HandlerPid eWSrv handler 进程（运行 chunkLoop）
%% @param Question   用户问题
%% @param Opts       调用选项
%% @param SessionId  会话 ID（用于断连时精确取消本会话任务）
%% @param TaskId     任务 ID（用于断连时精确取消本任务）
%% @end
%%--------------------------------------------------------------------
sseStreamWorker(HandlerPid, Question, Opts, SessionId, TaskId) ->
    MonRef = erlang:monitor(process, HandlerPid),
    Result = try alServer:askStream(Question, Opts)
             catch
                 Class:Reason -> {error, {Class, Reason}}
             end,
    case Result of
        {ok, streaming} ->
            sseStreamLoop(HandlerPid, MonRef, SessionId, TaskId);
        {error, Err} ->
            erlang:demonitor(MonRef, [flush]),
            Msg = iolist_to_binary(io_lib:format("错误: ~p", [Err])),
            HandlerPid ! {chunk, sseData(Msg)},
            HandlerPid ! {chunk, sseEvent(<<"done">>, <<"{}">>)},
            HandlerPid ! {chunk, close}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 接收 LLM stream 事件并转发为 eWSrv chunk 消息：
%%   {eStreamChunk, Chunk}  → {chunk, sseData(Chunk)}
%%   {eStreamDone, _}       → {chunk, sseEvent(done)} + {chunk, close}
%%   {eStreamError, Reason} → {chunk, sseData(错误)} + close
%% 空闲 120s 自动关闭。
%%
%% @param HandlerPid eWSrv handler 进程
%% @param SessionId  会话 ID
%% @param TaskId     任务 ID
%% @end
%%--------------------------------------------------------------------
sseStreamLoop(HandlerPid, MonRef, SessionId, TaskId) ->
    sseStreamLoop(HandlerPid, MonRef, SessionId, TaskId, false).

sseStreamLoop(HandlerPid, MonRef, SessionId, TaskId, SawToolDelta) ->
    receive
        {eStreamChunk, Chunk} ->
            HandlerPid ! {chunk, sseData(Chunk)},
            sseStreamLoop(HandlerPid, MonRef, SessionId, TaskId, SawToolDelta);
        {eStreamReasoning, Chunk} ->
            %% SSE：reasoning 用专用 event，前端可忽略或显示在思考框
            HandlerPid ! {chunk, sseEvent(<<"reasoning">>, toBinary(Chunk))},
            sseStreamLoop(HandlerPid, MonRef, SessionId, TaskId, SawToolDelta);
        {eStreamProgress, Ev} ->
            HandlerPid ! {chunk, sseEvent(<<"progress">>, alJson:encode(Ev))},
            sseStreamLoop(HandlerPid, MonRef, SessionId, TaskId, SawToolDelta);
        {eStreamToolDelta, _} ->
            case SawToolDelta of
                true -> ok;
                false ->
                    HandlerPid ! {chunk, sseEvent(<<"progress">>, alJson:encode(#{
                        type => step, phase => toolCall,
                        message => <<"正在生成工具调用…"/utf8>>
                    }))}
            end,
            sseStreamLoop(HandlerPid, MonRef, SessionId, TaskId, true);
        {eStreamAnswer, _} ->
            %% 整轮 ask 结束（alServer 在最终结果时发送）；中间轮只有 eStreamDone。
            erlang:demonitor(MonRef, [flush]),
            HandlerPid ! {chunk, sseEvent(<<"done">>, <<"{}">>)},
            HandlerPid ! {chunk, close};
        {eStreamDone, Content} ->
            %% 中间轮流结束也会发 eStreamDone（tool_calls）；不能关 SSE。
            case Content of
                <<>> -> ok;
                _ when is_binary(Content), Content =/= <<>> ->
                    HandlerPid ! {chunk, sseData(Content)};
                _ -> ok
            end,
            sseStreamLoop(HandlerPid, MonRef, SessionId, TaskId, SawToolDelta);
        {eStreamError, Reason} ->
            erlang:demonitor(MonRef, [flush]),
            Msg = iolist_to_binary(io_lib:format("错误: ~p", [Reason])),
            HandlerPid ! {chunk, sseData(Msg)},
            HandlerPid ! {chunk, sseEvent(<<"done">>, <<"{}">>)},
            HandlerPid ! {chunk, close};
        {'DOWN', MonRef, _, _, _} ->
            %% 客户端断连：只取消本会话的本任务，绝不全局取消所有会话。
            case TaskId of
                undefined -> alServer:cancelAsk(SessionId);
                _ -> alServer:cancelAskByTaskId(SessionId, TaskId)
            end,
            ok
    after 1800000 ->
        erlang:demonitor(MonRef, [flush]),
        HandlerPid ! {chunk, sseEvent(<<"done">>, <<"{}">>)},
        HandlerPid ! {chunk, close}
    end.

%% 安全地确保会话存在，失败仅记录日志不抛出
safeEnsureSession(Sid) ->
    try alSessionMgr:ensureSession(Sid, web) of
        _ -> ok
    catch
        Class:Reason ->
            logger:warning("ensureSession failed: ~p:~p", [Class, Reason]),
            ok
    end.

%% 安全地获取当前模式，失败时回退到 ask
safeGetMode() ->
    try alServer:getMode() of
        Mode -> Mode
    catch
        _:_ -> ask
    end.

%% SSE 响应头：text/event-stream + no-cache + 禁用 nginx 缓冲 + CORS/安全头
sseHeaders() ->
    [
        {<<"Content-Type">>, <<"text/event-stream; charset=utf-8">>},
        {<<"Cache-Control">>, <<"no-cache">>},
        {<<"X-Accel-Buffering">>, <<"no">>}
    ] ++ corsHeadersCached() ++ alWebSec:securityHeaders().

%% 将数据按 SSE 格式编码为多行 `data: ...\n`，最后空行结束
sseData(Data) ->
    Lines = binary:split(toBinary(Data), <<"\n">>, [global]),
    iolist_to_binary([[<<"data: ">>, Line, <<"\n">>] || Line <- Lines] ++ [<<"\n">>]).

%% 构造一个带事件类型的 SSE 帧。
%% 数据部分复用 sseData/1 的逐行 `data: ` 前缀转义：reasoning 等文本中的
%% 换行会被拆成独立 data 行，无法注入伪造的 event:/data: 帧。
%% 事件类型白名单；非白名单类型统一降级为普通 data 帧。
sseEvent(Type, Data) ->
    TypeBin = toBinary(Type),
    case lists:member(TypeBin, [<<"reasoning">>, <<"token">>, <<"done">>, <<"error">>,
                                <<"started">>, <<"completed">>, <<"toolStarted">>,
                                <<"toolFinished">>, <<"approvalRequired">>]) of
        true -> iolist_to_binary([<<"event: ">>, TypeBin, <<"\n">>, sseData(Data)]);
        false -> sseData(Data)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 执行同步问答。确保会话存在，注入模式与持久化选项，
%% 调用 alServer:ask 并将结果以 JSON 返回。
%%
%% @param Question 用户问题
%% @param Opts     调用选项
%% @return eWSrv 三元组
%% @end
%%--------------------------------------------------------------------
runAsk(Question, Opts) ->
    Sid = maps:get(sessionId, Opts, <<"web">>),
    _ = alSessionMgr:ensureSession(Sid, web),
    Opts1 = Opts#{persistMemory => true, mode => alServer:getMode()},
    case alServer:ask(Question, Opts1) of
        {ok, Result} ->
            jsonResponse(200, #{status => ok, result => Result});
        {error, Reason} ->
            jsonResponse(200, #{status => error, reason => Reason})
    end.

%%--------------------------------------------------------------------
%% @doc
%% 通用 JSON 请求体处理：解码后将 map 交给回调函数 Fun，并将 Fun 的
%% 返回值（map）作为 200 JSON 响应；解码失败返回 400。
%%
%% @param Body 请求体二进制
%% @param Fun  接收 map 返回 map 的回调
%% @return eWSrv 三元组
%% @end
%%--------------------------------------------------------------------
handleJsonBody(Body, Fun) ->
    try alJson:decode(Body) of
        Map when is_map(Map) ->
            jsonResponse(200, Fun(Map));
        _ ->
            jsonResponse(400, #{error => invalidJson})
    catch
        _:_ ->
            jsonResponse(400, #{error => invalidJson})
    end.

%% 取查询参数，未找到返回 Default（结果统一转 binary）
queryParam(WsReq, Key, Default) ->
    case queryArg(WsReq, Key) of
        undefined -> Default;
        V -> toBinary(V)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 从 eWSrv 请求的 args 中取查询参数（同时支持 binary 和 list 形式的键）。
%%
%% @param WsReq eWSrv 请求记录
%% @param Key   参数键
%% @return Value | undefined
%% @end
%%--------------------------------------------------------------------
queryArg(WsReq, Key) ->
    KeyBin = toBinary(Key),
    KeyList = binary_to_list(KeyBin),
    case WsReq#wsReq.args of
        Qs when is_list(Qs) ->
            case proplists:get_value(KeyBin, Qs) of
                undefined -> proplists:get_value(KeyList, Qs);
                V -> V
            end;
        _ ->
            undefined
    end.

%%--------------------------------------------------------------------
%% @doc
%% 取整型查询参数，解析失败时返回 Default。
%%
%% @param WsReq   eWSrv 请求记录
%% @param Key     参数键
%% @param Default 默认值
%% @return integer()
%% @end
%%--------------------------------------------------------------------
queryParamInt(WsReq, Key, Default) ->
    case queryParam(WsReq, Key, integer_to_binary(Default)) of
        Bin when is_binary(Bin) ->
            try binary_to_integer(Bin) of
                N -> N
            catch
                _:_ -> Default
            end;
        _ ->
            Default
    end.

%% 整型会话 ID 原样返回
parseSessionId(Sid) when is_integer(Sid) -> Sid;
%% 二进制尝试转整型，失败保留原值
parseSessionId(Sid) when is_binary(Sid) ->
    try binary_to_integer(Sid) of
        N -> N
    catch
        _:_ -> Sid
    end;
%% 列表先转二进制再递归
parseSessionId(Sid) when is_list(Sid) ->
    parseSessionId(list_to_binary(Sid));
%% 其他类型原样返回
parseSessionId(Sid) ->
    Sid.

%%--------------------------------------------------------------------
%% @doc
%% 计算会话快照文件路径并做根目录前缀校验，防止路径穿越。
%% 即便 sessionFilePath 自身已做净化，这里再做一次边界校验作为纵深防御：
%% 最终路径必须落在会话目录之内，否则返回 forbidden。
%%
%% @param Sid 会话 ID
%% @return {ok, Path} | {error, forbidden}
%% @end
%%--------------------------------------------------------------------
safeSessionFilePath(Sid) ->
    Dir = alSessionMgr:sessionsDir(),
    Path = alSessionMgr:sessionFilePath(Sid),
    case alWebSec:isPathWithin(Dir, Path) of
        true -> {ok, Path};
        false -> {error, forbidden}
    end.

%%%===================================================================
%%% Static file serving
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 提供 WebUI 首页 index.html。读取后通过替换或追加
%% `<!--ALI_WEB_CONFIG-->` 标记注入运行时配置 script 标签。
%%
%% @return eWSrv 三元组
%% @end
%%--------------------------------------------------------------------
serveIndex() ->
    Path = filename:join([code:priv_dir(ali), "web", "index.html"]),
    case file:read_file(Path) of
        {ok, Html} ->
            Marker = <<"<!--ALI_WEB_CONFIG-->">>,
            ConfigTag = webConfigScriptTag(),
            Body = case binary:match(Html, Marker) of
                {Pos, Len} ->
                    <<Before:Pos/binary, _:Len/binary, After/binary>> = Html,
                    <<Before/binary, ConfigTag/binary, After/binary>>;
                nomatch ->
                    <<Html/binary, ConfigTag/binary>>
            end,
            {200, [{<<"Content-Type">>, <<"text/html; charset=utf-8">>}], Body};
        {error, _} ->
            jsonResponse(404, #{error => fileNotFound})
    end.

%%--------------------------------------------------------------------
%% @doc
%% 生成包含 publicWebConfig 的 JSON 配置 script 标签。
%% JSON 中 `</` 会被转义为 `<\/` 以避免 HTML 解析歧义。
%%
%% @return binary()
%% @end
%%--------------------------------------------------------------------
webConfigScriptTag() ->
    Json = alJson:encode(publicWebConfig()),
    SafeJson = escapeJsonForHtml(Json),
    iolist_to_binary([
        <<"<script type=\"application/json\" id=\"ali-config\">">>,
        SafeJson,
        <<"</script>">>
    ]).

%%--------------------------------------------------------------------
%% @doc
%% 构造可下发给前端的安全配置 map：网关端口/启用状态/是否鉴权、
%% LLM 提供商与默认模型、策略模式、MCP 工具规格。
%%
%% @return map()
%% @end
%%--------------------------------------------------------------------
publicWebConfig() ->
    LlmConfig = alConfig:get(llm, #{}),
    Limits = alConfig:get(limits, #{}),
    AuthToken = configuredToken(),
    WebEnabled = alWebSec:webOpt(enabled, true),
    ChainInfo = alLlmRouter:chainPublicInfo(),
    LocalEntry = maps:get(local, ChainInfo, null),
    %% 视觉能力按「当前会实际用到的链项」判断：优先本地，否则展示身份（云端）。
    VisionEntry = case LocalEntry of
        null ->
            case alLlmRouter:firstNonLocalEntry() of
                {ok, Cloud} -> Cloud;
                none ->
                    case alLlmRouter:modelChain() of
                        [H | _] -> H;
                        [] -> undefined
                    end
            end;
        #{id := Id} ->
            case [E || E <- alLlmRouter:modelChain(), maps:get(id, E, undefined) =:= Id] of
                [E | _] -> E;
                [] -> undefined
            end;
        _ ->
            undefined
    end,
    Provider = case LocalEntry of
        null ->
            maps:get(provider, alLlmRouter:chainDisplayIdentity(), deepseek);
        #{provider := P} -> P;
        _ -> deepseek
    end,
    Model = case LocalEntry of
        null ->
            toBinary(maps:get(model, alLlmRouter:chainDisplayIdentity(), <<>>));
        #{model := M} -> toBinary(M);
        _ -> <<>>
    end,
    VisionOpts = case VisionEntry of
        VE when is_map(VE) -> alLlmRouter:mergeEntryOpts(VE, LlmConfig);
        _ -> LlmConfig
    end,
    Mode = safeGetMode(),
    #{
        web => #{
            port => alHttpGateway:port(),
            enabled => WebEnabled,
            authEnabled => AuthToken =/= undefined andalso AuthToken =/= <<>>
        },
        llm => #{
            provider => Provider,
            model => Model,
            vision => alLlmClient:supportsVision(Provider, Model, VisionOpts),
            chain => ChainInfo
        },
        agent => #{mode => Mode},
        policy => #{mode => Mode},
        attachmentLimits => #{
            maxImages => maps:get(webMaxImages, Limits, 24),
            maxFiles => maps:get(webMaxFiles, Limits, 12),
            maxImageBytes => maps:get(webMaxImageBytes, Limits, 4194304),
            maxFileBytes => maps:get(webMaxFileBytes, Limits, 524288),
            maxDocuments => maps:get(webMaxDocuments, Limits, 4),
            maxDocumentBytes => maps:get(webMaxDocumentBytes, Limits, 10485760),
            imageMimeTypes => ?ImageMimeTypes,
            documentMimeTypes => ?DocMimeTypes,
            documentFileExtensions => [list_to_binary(E) || E <- ?DocFileExtensions],
            textFileExtensions => [list_to_binary(E) || E <- ?TextFileExtensions]
        },
        mcp => alToolCatalog:mcpTools()
    }.

%%--------------------------------------------------------------------
%% @doc
%% 转义 JSON 中所有 `</` 为 `<\/`，避免嵌入 HTML 时被解析器误判
%% 为标签结束。
%%
%% @param Json 二进制 JSON 文本
%% @return 转义后的二进制
%% @end
%%--------------------------------------------------------------------
escapeJsonForHtml(Json) ->
    binary:replace(Json, <<"</">>, <<"<\\/">>, [global]).

%%--------------------------------------------------------------------
%% @doc
%% 提供 priv 目录下的静态文件。先通过 safePrivPath 防止路径遍历，
%% 再读取文件并以扩展名推导的 Content-Type 返回。
%%
%% @param RelPath 相对 priv 的路径
%% @return eWSrv 三元组
%% @end
%%--------------------------------------------------------------------
servePriv(RelPath) ->
    PrivRoot = code:priv_dir(ali),
    case safePrivPath(PrivRoot, RelPath) of
        {ok, FullPath} ->
            case file:read_file(FullPath) of
                {ok, Data} ->
                    CT = contentType(RelPath),
                    Headers0 = [{<<"Content-Type">>, CT}],
                    Headers = case RelPath of
                        <<"web/static/", _/binary>> ->
                            [{<<"Cache-Control">>, <<"no-cache, must-revalidate">>} | Headers0];
                        _ ->
                            Headers0
                    end,
                    {200, Headers, Data};
                {error, _} ->
                    jsonResponse(404, #{error => fileNotFound})
            end;
        {error, forbidden} ->
            jsonResponse(403, #{error => forbidden})
    end.

%%--------------------------------------------------------------------
%% @doc
%% 安全校验：将 RelPath 拼接到 PrivRoot 后判断是否存在 `..` 段，
%% 且最终路径必须以 PrivRoot 为前缀。否则返回 forbidden。
%%
%% @param PrivRoot priv 根目录
%% @param RelPath 相对路径
%% @return {ok, FullPath} | {error, forbidden}
%% @end
%%--------------------------------------------------------------------
safePrivPath(PrivRoot, RelPath) ->
    Root = filename:absname(toCharlist(PrivRoot)),
    Full = filename:absname(filename:join(Root, toCharlist(RelPath))),
    RootParts = filename:split(Root),
    FullParts = filename:split(Full),
    HasTraversal = lists:member("..", FullParts),
    StartsWithRoot = length(FullParts) >= length(RootParts)
        andalso lists:sublist(FullParts, length(RootParts)) =:= RootParts,
    case not HasTraversal andalso StartsWithRoot of
        true -> {ok, Full};
        false -> {error, forbidden}
    end.

%% 二进制转字符列表
toCharlist(V) when is_binary(V) -> binary_to_list(V);
%% 列表原样返回
toCharlist(V) when is_list(V) -> V.

%%--------------------------------------------------------------------
%% @doc
%% 按文件扩展名返回 Content-Type，未识别时返回 application/octet-stream。
%%
%% @param Path 文件路径
%% @return binary()
%% @end
%%--------------------------------------------------------------------
contentType(Path) ->
    case filename:extension(binary_to_list(Path)) of
        ".css" -> <<"text/css; charset=utf-8">>;
        ".js" -> <<"application/javascript; charset=utf-8">>;
        ".html" -> <<"text/html; charset=utf-8">>;
        ".svg" -> <<"image/svg+xml">>;
        ".png" -> <<"image/png">>;
        ".json" -> <<"application/json; charset=utf-8">>;
        _ -> <<"application/octet-stream">>
    end.

%%%===================================================================
%%% Authorization
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 鉴权逻辑。若未配置 token：受保护路径仅允许 loopback IP 或显式开启
%% allowRemoteWrites 时通过。若配置了 token：受保护路径要求 Bearer
%% token 通过恒定时间比较。
%%
%% @param Method HTTP 方法
%% @param Path   请求路径
%% @param WsReq  eWSrv 请求记录
%% @param Ip     客户端 IP
%% @return ok | {error, unauthorized}
%% @end
%%--------------------------------------------------------------------
authorize(Method, Path, WsReq, Ip) ->
    Protected = alWebSec:isProtectedPath(Method, Path),
    case configuredToken() of
        <<>> ->
            case Protected of
                false -> ok;
                true ->
                    %% 无 token：仅 loopback / allowRemoteWrites。
                    %% Windows+eNet 上 peername 常失败（IP=unknown），此时用 Host/Origin
                    %% 是否本机作为兜底，否则本地 WebUI 的 /ws 会 401 整站假死。
                    %% 兜底仅在服务本身绑定回环时生效，避免公网绑定 + peername 失败
                    %% 时被伪造 Host 头绕过鉴权。
                    Allow = alWebSec:webOpt(allowRemoteWrites, false)
                            orelse alWebSec:isLoopback(Ip)
                            orelse (Ip =:= undefined
                                    andalso alWebSec:isLoopbackBound()
                                    andalso isLikelyLocalClient(WsReq)),
                    case Allow of
                        true ->
                            case Ip =:= undefined of
                                true ->
                                    logger:warning(
                                        "[web] peer IP unknown; allowing via local Host/Origin");
                                false -> ok
                            end,
                            ok;
                        false -> {error, unauthorized}
                    end
            end;
        Expected ->
            case Protected of
                false -> ok;
                true ->
                    case requestToken(WsReq) of
                        {ok, Provided} ->
                            case alWebSec:constantEq(toBinary(Provided), Expected) of
                                true -> ok;
                                false -> {error, unauthorized}
                            end;
                        _ ->
                            {error, unauthorized}
                    end
            end
    end.

%% @doc Host/Origin 是否像本机浏览器（peername 失败时的鉴权兜底）。
%% 解析 hostname（去 scheme/端口），精确匹配 localhost / 127.0.0.1 / ::1，
%% 禁止 evil-localhost.com 等子串误伤。
-spec isLikelyLocalClient(term()) -> boolean().
isLikelyLocalClient(WsReq) ->
    isExactLocalHost(originHeader(WsReq)) orelse isExactLocalHost(hostHeader(WsReq))
        orelse isExactLocalHost(WsReq#wsReq.host).

%%--------------------------------------------------------------------
%% @doc
%% 将客户端提供的 root 参数解析为允许的绝对路径。
%% 允许范围：项目根与配置的 codeRoots；越界返回 `{error, forbidden}'，
%% 防止通过 root 参数读取/索引服务器任意目录。
%%
%% @param RootBin 客户端 root 参数（binary 或 undefined）
%% @return 绝对路径 string | `{error, forbidden}'
%% @end
%%--------------------------------------------------------------------
resolveAllowedRoot(undefined) ->
    resolveAllowedRoot1(os:getenv("ALI_PROJECT_ROOT", "."));
resolveAllowedRoot(RootBin) ->
    resolveAllowedRoot1(unicode:characters_to_list(RootBin)).

resolveAllowedRoot1(Root) ->
    AbsRoot = filename:absname(Root),
    Allowed = [alConfig:projectRoot() | alConfig:codeRoots()],
    case lists:any(fun(AR) -> alWebSec:isPathWithin(AR, AbsRoot) end, Allowed) of
        true -> AbsRoot;
        false -> {error, forbidden}
    end.

isExactLocalHost(undefined) -> false;
isExactLocalHost(Bin) when is_binary(Bin) ->
    Host = extractHostname(Bin),
    lists:member(Host, [<<"localhost">>, <<"127.0.0.1">>, <<"::1">>, <<"[::1]">>]);
isExactLocalHost(List) when is_list(List) ->
    isExactLocalHost(unicode:characters_to_binary(List));
isExactLocalHost(_) -> false.

%% 从 URL 或 Host 头提取 hostname（小写，无端口）。
extractHostname(Bin) when is_binary(Bin) ->
    L0 = string:lowercase(string:trim(Bin)),
    L1 = case L0 of
        <<"http://", R/binary>> -> R;
        <<"https://", R/binary>> -> R;
        <<"ws://", R/binary>> -> R;
        <<"wss://", R/binary>> -> R;
        _ -> L0
    end,
    HostPort = case binary:split(L1, <<"/">>) of
        [H | _] -> H;
        _ -> L1
    end,
    stripHostPort(HostPort).

stripHostPort(<<"[", Rest/binary>>) ->
    case binary:split(Rest, <<"]">>) of
        [Inside, _] -> Inside;  %% ::1
        _ -> <<"[", Rest/binary>>
    end;
stripHostPort(HostPort) ->
    %% IPv4 / hostname:port — 只在存在单个 : 且右侧为数字时剥端口
    case binary:split(HostPort, <<":">>) of
        [H, Port] ->
            case re:run(Port, <<"^[0-9]+$">>) of
                {match, _} -> H;
                nomatch -> HostPort
            end;
        [H] -> H;
        _ -> HostPort
    end.

%%--------------------------------------------------------------------
%% @doc
%% 统一 token 提取（HTTP 与 WS 升级共用）：优先 Authorization Bearer 头
%% （推荐，token 不出现在 URL），回退到查询参数 `token`（用于无法设置
%% 请求头的场景，如浏览器 EventSource / WebSocket）。
%%
%% @param WsReq eWSrv 请求记录
%% @return {ok, Token} | {error, noToken}
%% @end
%%--------------------------------------------------------------------
requestToken(WsReq) ->
    case headerBearer(WsReq#wsReq.headers) of
        {ok, Token} -> {ok, Token};
        _ ->
            case queryArg(WsReq, <<"token">>) of
                undefined -> {error, noToken};
                V -> {ok, toBinary(V)}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 获取已配置的鉴权 token：优先 gateway.authToken，其次 web.apiToken，
%% 都未配置时返回 `<<>>` 表示未启用鉴权。
%%
%% @return token 二进制 | <<>>
%% @end
%%--------------------------------------------------------------------
configuredToken() ->
    Gateway = alConfig:get(gateway, #{}),
    case maps:get(authToken, Gateway, undefined) of
        T when T =/= undefined, T =/= <<>>, T =/= "" ->
            toBinary(T);
        _ ->
            case alWebSec:webOpt(apiToken, undefined) of
                W when W =/= undefined, W =/= <<>>, W =/= "" -> toBinary(W);
                _ -> <<>>
            end
    end.

%%%===================================================================
%%% Request helpers
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 获取客户端 IP：优先 wsNet:peername，再回退 inet/ssl。
%% eNet 自定义 port 在 Windows 上偶发 peername 失败 → undefined。
%% @end
%%--------------------------------------------------------------------
peerIp(WsReq) ->
    Socket = WsReq#wsReq.socket,
    case peernameSafe(Socket) of
        {ok, Ip} -> Ip;
        error -> undefined
    end.

peernameSafe(Socket) ->
    try wsNet:peername(Socket) of
        {ok, {Ip, _Port}} when is_tuple(Ip) -> {ok, Ip};
        {ok, Ip} when is_tuple(Ip) -> {ok, Ip};
        _ -> peernameFallback(Socket)
    catch
        _:_ -> peernameFallback(Socket)
    end.

peernameFallback(Socket) ->
    case socketPeer(inet, Socket) of
        {ok, _} = Ok -> Ok;
        error -> socketPeer(ssl, Socket)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 通过给定 socket 模块（inet/ssl）获取对端地址，异常时返回 error。
%% @end
%%--------------------------------------------------------------------
socketPeer(Mod, Socket) ->
    try Mod:peername(Socket) of
        {ok, {Ip, _Port}} -> {ok, Ip};
        _ -> error
    catch _:_ -> error end.

%%--------------------------------------------------------------------
%% @doc
%% 提取 Origin 头并转 binary，不存在时返回 undefined。
%% @end
%%--------------------------------------------------------------------
originHeader(WsReq) ->
    case lookupHeader(<<"origin">>, WsReq#wsReq.headers) of
        {ok, Value} -> toBinary(Value);
        notFound -> undefined
    end.

hostHeader(WsReq) ->
    case lookupHeader(<<"host">>, WsReq#wsReq.headers) of
        {ok, Value} -> toBinary(Value);
        notFound -> undefined
    end.

%%--------------------------------------------------------------------
%% @doc
%% 从 Authorization 头提取 Bearer token（大小写不敏感）。
%%
%% @param Headers 请求头列表
%% @return {ok, Token} | {error, noBearer | noAuthHeader}
%% @end
%%--------------------------------------------------------------------
headerBearer(Headers) ->
    case lookupHeader(<<"authorization">>, Headers) of
        {ok, Value} ->
            V = toBinary(Value),
            case V of
                <<"Bearer ", Token/binary>> -> {ok, Token};
                <<"bearer ", Token/binary>> -> {ok, Token};
                _ -> {error, noBearer}
            end;
        notFound ->
            {error, noAuthHeader}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 大小写不敏感地查找请求头。Headers 中的键可为 binary/list/atom。
%%
%% @param Name    头部名（binary）
%% @param Headers 请求头列表
%% @return {ok, Value} | notFound
%% @end
%%--------------------------------------------------------------------
lookupHeader(Name, Headers) ->
    NameLower = string:lowercase(Name),
    lists:foldl(fun
        ({K, V}, notFound) ->
            KBin = headerKeyToBinary(K),
            case string:lowercase(KBin) of
                NameLower -> {ok, V};
                _ -> notFound
            end;
        (_, Acc) -> Acc
    end, notFound, Headers).

%% 二进制键原样返回
headerKeyToBinary(K) when is_binary(K) -> K;
%% 列表键转二进制
headerKeyToBinary(K) when is_list(K) -> list_to_binary(K);
%% atom 键转二进制
headerKeyToBinary(K) when is_atom(K) -> atom_to_binary(K, utf8).

%%--------------------------------------------------------------------
%% @doc
%% 汇总单个 checkpoint 的摘要信息：任务 id、pending 工具名与参数摘要、
%% 保存时间。读取失败时仅返回 taskId，便于前端仍能展示/删除。
%%
%% @param TaskId 任务 ID
%% @return map（可直接 JSON 编码）
%% @end
%%--------------------------------------------------------------------
checkpointInfo(TaskId) ->
    Base = #{taskId => toBinary(TaskId)},
    try alCheckpoint:load(TaskId) of
        {ok, Cont} ->
            SavedAt = maps:get(<<"savedAt">>, Cont, maps:get(savedAt, Cont, undefined)),
            Base1 = case SavedAt of
                undefined -> Base;
                _ -> Base#{savedAt => SavedAt}
            end,
            case maps:get(pendingCall, Cont, undefined) of
                #{function := #{name := Name, arguments := Args}} ->
                    Base1#{
                        tool => toBinary(Name),
                        args => argSummary(Args)
                    };
                _ ->
                    Base1
            end;
        _ ->
            Base
    catch
        _:_ -> Base
    end.

%% 将 pending 调用的参数转成简短字符串列表（供前端展示摘要）。
argSummary(Args) when is_list(Args) ->
    Parts = lists:filtermap(fun shortArg/1, Args),
    case length(Parts) > 6 of
        true -> lists:sublist(Parts, 6) ++ [<<"...">>];
        false -> Parts
    end;
argSummary(_) ->
    [].

shortArg(A) when is_binary(A) ->
    {true, truncateBin(A, 60)};
shortArg(A) when is_atom(A) ->
    {true, toBinary(A)};
shortArg(A) when is_integer(A) ->
    {true, integer_to_binary(A)};
shortArg(A) when is_float(A) ->
    {true, float_to_binary(A)};
shortArg(_) ->
    false.

truncateBin(Bin, Max) when byte_size(Bin) =< Max ->
    Bin;
truncateBin(Bin, Max) ->
    %% 按字符截断，避免切断多字节 UTF-8 序列导致 JSON 编码失败
    case unicode:characters_to_list(Bin, utf8) of
        List when is_list(List) ->
            unicode:characters_to_binary(lists:sublist(List, Max));
        _ ->
            binary:part(Bin, 0, Max)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 将任意值转换为 UTF-8 binary。支持 binary/list/atom/integer，
%% 其他类型格式化为字符串。
%%
%% @param V 输入值
%% @return binary()
%% @end
%%--------------------------------------------------------------------
toBinary(V) when is_binary(V) -> V;
toBinary(V) when is_list(V) -> unicode:characters_to_binary(V);
toBinary(V) when is_atom(V) -> atom_to_binary(V, utf8);
toBinary(V) when is_integer(V) -> integer_to_binary(V);
toBinary(V) -> unicode:characters_to_binary(io_lib:format("~p", [V])).

%% 将文件内容规范为可进 JSON 的 UTF-8 文本；明显二进制则拒绝。
safeUtf8Text(Bin) when is_binary(Bin) ->
    Sample = case byte_size(Bin) > 8192 of
        true -> binary:part(Bin, 0, 8192);
        false -> Bin
    end,
    NulCount = length(binary:matches(Sample, <<0>>)),
    case NulCount > 8 of
        true ->
            {error, notText};
        false ->
            case unicode:characters_to_binary(Bin, utf8, utf8) of
                Out when is_binary(Out) ->
                    {ok, Out};
                {error, Good, _Rest} when is_binary(Good) ->
                    {ok, <<Good/binary, "\n…(non-UTF8 bytes omitted)…"/utf8>>};
                {incomplete, Good, _Rest} when is_binary(Good) ->
                    {ok, <<Good/binary, "\n…(truncated)…"/utf8>>};
                _ ->
                    {error, notText}
            end
    end;
safeUtf8Text(List) when is_list(List) ->
    safeUtf8Text(unicode:characters_to_binary(List));
safeUtf8Text(_) ->
    {error, notText}.

%% 文件内容 API：默认/上限 5MiB。
-define(FILE_CONTENT_MAX_BYTES, 5242880).

fileContentResponse(WsReq) ->
    Path = queryParam(WsReq, <<"path">>, <<>>),
    MaxBytes0 = queryParamInt(WsReq, <<"maxBytes">>, ?FILE_CONTENT_MAX_BYTES),
    MaxBytes = max(1024, min(MaxBytes0, ?FILE_CONTENT_MAX_BYTES)),
    case Path of
        <<>> ->
            jsonResponse(400, #{status => error, reason => missingPath, error => missingPath});
        _ ->
            case alWebSec:isDeniedFileApiPath(Path) of
                true ->
                    jsonResponse(403, #{status => error, reason => pathNotAllowed,
                                        error => pathNotAllowed});
                false ->
                    case alToolsExt:readFile(#{path => Path, maxBytes => MaxBytes}) of
                        {ok, Map} ->
                            Content0 = maps:get(content, Map, <<>>),
                            case safeUtf8Text(Content0) of
                                {ok, Text} ->
                                    jsonResponse(200, #{
                                        status => ok,
                                        path => Path,
                                        content => Text,
                                        binary => false,
                                        truncated => maps:get(truncated, Map, false),
                                        totalBytes => maps:get(totalBytes, Map, byte_size(Content0))
                                    });
                                {error, notText} ->
                                    jsonResponse(200, #{
                                        status => ok,
                                        path => Path,
                                        content => <<>>,
                                        binary => true,
                                        reason => notText,
                                        truncated => maps:get(truncated, Map, false),
                                        totalBytes => maps:get(totalBytes, Map, byte_size(Content0))
                                    })
                            end;
                        {error, Reason} ->
                            jsonResponse(400, #{status => error, reason => Reason, error => Reason})
                    end
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 懒初始化 WebSocket 应用状态。已含 sessionId 的状态直接复用，
%% 否则调用 alWs:initState 构造。这样 init/1 在普通 HTTP 请求时
%% 仍然很轻量。
%%
%% @param State 当前状态
%% @return map()
%% @end
%%--------------------------------------------------------------------
%% Lazy WebSocket app state (init/1 stays cheap for plain HTTP).
ensureWsState(#{sessionId := _} = State) ->
    State;
ensureWsState(_) ->
    alWs:initState().

%%--------------------------------------------------------------------
%% @doc
%% 安全地调用 0 元函数。当 core gen_server 重启时（noproc/timeout/undef）
%% 返回 Default 而不让 HTTP 处理器崩溃。
%%
%% @param Fun     0 元函数
%% @param Default 异常时的默认返回值
%% @return Result | Default
%% @end
%%--------------------------------------------------------------------
%% Avoid crashing HTTP handlers when core genservers are restarting.
safeServerCall(Fun, Default) when is_function(Fun, 0) ->
    try Fun() of
        Result -> Result
    catch
        exit:{noproc, _} -> Default;
        exit:{timeout, _} -> Default;
        error:undef -> Default;
        Class:Reason ->
            logger:warning("safeServerCall ~p:~p", [Class, Reason]),
            Default
    end.

%%%===================================================================
%%% Response helpers
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 构造 JSON 响应：编码 map 为 JSON，附加 JSON 头、缓存的 CORS 头
%% 和安全头。
%%
%% @param Code HTTP 状态码
%% @param Map  响应体 map
%% @return eWSrv 三元组 {Code, Headers, Body}
%% @end
%%--------------------------------------------------------------------
jsonResponse(Code, Map) ->
    Body = alJson:encode(Map),
    Headers = ?JsonHeader ++ corsHeadersCached() ++ alWebSec:securityHeaders(),
    {Code, Headers, Body}.

%% 从进程字典读取已缓存的 CORS 头；未设置时返回空列表
corsHeadersCached() ->
    case get(corsHeaders) of
        undefined -> [];
        H when is_list(H) -> H
    end.

%%--------------------------------------------------------------------
%% @doc
%% 记录鉴权失败日志（HTTP 方法、路径、来源 IP）。
%%
%% @param Method HTTP 方法
%% @param Path   请求路径
%% @param Ip     客户端 IP
%% @return ok
%% @end
%%--------------------------------------------------------------------
logDenied(Method, Path, Ip) ->
    logger:warning("[web] 401 ~s ~s from ~s",
                   [Method, Path, alWebSec:formatIp(Ip)]).

%%--------------------------------------------------------------------
%% @doc
%% 取指定会话的消息列表并按 API 格式编码。失败或无消息时返回空列表。
%%
%% @param SessionId 会话 ID
%% @return [map()]
%% @end
%%--------------------------------------------------------------------
sessionMessagesForApi(SessionId) ->
    case alServer:sessionMessages(SessionId) of
        {ok, #{messages := Messages}} when is_list(Messages) ->
            [encodeApiMessage(M) || M <- Messages];
        {ok, Session} when is_map(Session) ->
            Msgs = maps:get(messages, Session, maps:get(<<"messages">>, Session, [])),
            case is_list(Msgs) of
                true -> [encodeApiMessage(M) || M <- Msgs];
                false -> []
            end;
        _ ->
            []
    end.

%% 供前端重建 callGraph / moduleDeps 等侧栏图：返回会话 toolTrace（已截断）。
sessionToolTraceForApi(SessionId) ->
    Trace = case alSessionMgr:getSessionFull(SessionId) of
        {ok, Session} when is_map(Session) ->
            maps:get(toolTrace, Session, maps:get(<<"toolTrace">>, Session, []));
        _ ->
            []
    end,
    case is_list(Trace) of
        true -> [encodeApiMessage(E) || E <- lists:sublist(Trace, 80)];
        false -> []
    end.

%%--------------------------------------------------------------------
%% @doc
%% 将消息 map 的所有键/值递归转为 API 友好格式（atom 键转 binary，
%% atom 值转 binary，list 值若是可打印 Unicode 则转 binary，否则递归）。
%%
%% @param M 消息 map
%% @return map()
%% @end
%%--------------------------------------------------------------------
encodeApiMessage(M) when is_map(M) ->
    maps:fold(fun(K, V, Acc) ->
        maps:put(apiKey(K), apiValue(V), Acc)
    end, #{}, M);
%% 非 map 值包装为未知角色的消息
encodeApiMessage(V) ->
    #{content => apiValue(V), role => <<"unknown">>}.

%% atom 键转 binary，其他原样返回
apiKey(K) when is_atom(K) -> atom_to_binary(K, utf8);
apiKey(K) -> K.

%% atom 值转 binary
apiValue(V) when is_atom(V) -> atom_to_binary(V, utf8);
%% map 值递归编码
apiValue(V) when is_map(V) -> encodeApiMessage(V);
%% 列表值：可打印 Unicode 转二进制，否则逐项递归
apiValue(V) when is_list(V) ->
    case io_lib:printable_unicode_list(V) of
        true -> unicode:characters_to_binary(V);
        false -> [apiValue(I) || I <- V]
    end;
%% 其他值原样返回
apiValue(V) -> V.

%%--------------------------------------------------------------------
%% @doc
%% 将 approve 调用的结果归一化为 API 响应：包含 status、result、
%% answer 文本与 resumed 标志。多种结果形态递归归一。
%%
%% @param AgentResult approve 的原始结果
%% @return map()
%% @end
%%--------------------------------------------------------------------
approveResponse(#{answer := Answer} = AgentResult) ->
    #{
        status => ok,
        result => AgentResult,
        answer => approveAnswerText(Answer),
        resumed => maps:get(resumed, AgentResult, false)
    };
%% 包装层 {status, ok, result}——递归处理内层
approveResponse(#{status := ok, result := Result}) ->
    approveResponse(Result);
%% 普通 map 结果——尝试提取 answer 文本
approveResponse(Result) when is_map(Result) ->
    #{
        status => ok,
        result => Result,
        answer => approveAnswerText(Result)
    };
%% 其他类型——直接包装返回
approveResponse(Other) ->
    #{status => ok, result => Other}.

%%--------------------------------------------------------------------
%% @doc
%% 从 approve 结果中提取可展示文本：二进制原样返回，map 优先取 content
%% 或递归 result，其他 map 序列化为 JSON，剩余类型格式化为字符串。
%%
%% @param Answer 输入结果
%% @return binary()
%% @end
%%--------------------------------------------------------------------
approveAnswerText(Answer) when is_binary(Answer) -> Answer;
approveAnswerText(#{content := Content}) when is_binary(Content) -> Content;
approveAnswerText(#{result := Result}) -> approveAnswerText(Result);
approveAnswerText(Answer) when is_map(Answer) ->
    unicode:characters_to_binary(alJson:encode(Answer));
approveAnswerText(Answer) ->
    unicode:characters_to_binary(io_lib:format("~p", [Answer])).

%%--------------------------------------------------------------------
%% @doc
%% metrics 快照转换为 API 友好格式：atom 键改驼峰后 alJson:encode
%% 会自动将 atom 序列化为同名 binary，此函数已退化为恒等。
%%
%% @param Snap metrics 快照 map
%% @return map()
%% @end
%%--------------------------------------------------------------------
metricsForApi(Snap) when is_map(Snap) -> Snap.

%%--------------------------------------------------------------------
%% @doc
%% 将执行计划 map 转换为 API 格式：原计划、按 API 格式编码的步骤列表、
%% 摘要。
%%
%% @param Plan 计划 map
%% @return map()
%% @end
%%--------------------------------------------------------------------
planForApi(Plan) when is_map(Plan) ->
    Steps = maps:get(steps, Plan, []),
    #{
        plan => Plan,
        steps => [planStepForApi(S) || S <- Steps],
        summary => maps:get(summary, Plan, #{})
    }.

%%--------------------------------------------------------------------
%% @doc
%% 将单个计划步骤 map 转换为 API 格式：补全 id/title/status 字段
%% （status 为 atom 时转 binary），并保留原有字段。
%%
%% @param Step 步骤 map
%% @return map()
%% @end
%%--------------------------------------------------------------------
planStepForApi(Step) when is_map(Step) ->
    maps:merge(#{
        <<"id">> => maps:get(id, Step, 0),
        <<"title">> => maps:get(title, Step, <<>>),
        <<"status">> => atom_to_binary(maps:get(status, Step, pending), utf8)
    }, Step).

%%--------------------------------------------------------------------
%% aliCore 面板校验辅助
%%--------------------------------------------------------------------
coreInspectStatus() ->
    Available = alCoreClient:available(),
    Health = case Available of
        true ->
            case alCoreClient:health() of
                {ok, H} -> unwrapCoreInspect(H);
                {error, HR} -> #{error => HR}
            end;
        false ->
            #{error => coreUnavailable}
    end,
    Index = case Available of
        true ->
            case alCoreClient:indexStatus() of
                {ok, I} -> unwrapCoreInspect(I);
                {error, IR} -> #{error => IR}
            end;
        false ->
            #{}
    end,
    Db = case Available of
        true ->
            case alCoreClient:dbStatus() of
                {ok, D} -> unwrapCoreInspect(D);
                {error, DR} -> #{error => DR}
            end;
        false ->
            #{}
    end,
    #{
        status => ok,
        available => Available,
        health => Health,
        index => Index,
        db => Db,
        hint => <<"面板「Core」可查模块列表/搜索/符号/callers；remote_calls 过低通常表示远程 MFA 提取异常"/utf8>>
    }.

unwrapCoreInspect({ok, Map}) -> unwrapCoreInspect(Map);
unwrapCoreInspect(Map) when is_map(Map) -> alCoreClient:unwrapMap(Map);
unwrapCoreInspect(Other) -> Other.

coreBodyInt(Body, Key, Default) when is_map(Body) ->
    case maps:get(Key, Body, Default) of
        N when is_integer(N) -> N;
        B when is_binary(B) ->
            try binary_to_integer(B) catch _:_ -> Default end;
        L when is_list(L) ->
            try list_to_integer(L) catch _:_ -> Default end;
        _ -> Default
    end.

coreGraphQuery(DefaultDir, Body) when is_map(Body) ->
    Module = maps:get(<<"module">>, Body, undefined),
    Function = maps:get(<<"function">>, Body, undefined),
    Arity = coreBodyInt(Body, <<"arity">>, undefined),
    MaxEdges = min(120, max(10, coreBodyInt(Body, <<"maxEdges">>, 80))),
    Dir = coreGraphDirection(Body, DefaultDir),
    case {Function, Arity} of
        {undefined, _} -> #{status => error, reason => missingFunction};
        {_, undefined} -> #{status => error, reason => missingArity};
        _ ->
            case coreFetchGraphEdges(Dir, Module, Function, Arity) of
                {ok, EdgePack} ->
                    CallerEdges = maps:get(callerEdges, EdgePack, []),
                    CalleeEdges = maps:get(calleeEdges, EdgePack, []),
                    AllEdges = maps:get(edges, EdgePack, []),
                    ShownCallers = lists:sublist(CallerEdges, MaxEdges),
                    ShownCallees = lists:sublist(CalleeEdges, MaxEdges),
                    Shown = case Dir of
                        both -> ShownCallers ++ ShownCallees;
                        callers -> lists:sublist(AllEdges, MaxEdges);
                        callees -> lists:sublist(AllEdges, MaxEdges)
                    end,
                    TotalCount = case Dir of
                        both -> length(CallerEdges) + length(CalleeEdges);
                        _ -> length(AllEdges)
                    end,
                    Mfa = coreMfaBin(Module, Function, Arity),
                    Briefs = try alDocGen:briefDocsFromEdges(Shown)
                             catch _:_ -> #{}
                             end,
                    MermaidCap = case Dir of
                        both -> min(240, MaxEdges * 2);
                        _ -> MaxEdges
                    end,
                    ByMod = case Dir of
                        both ->
                            #{
                                callers => coreEdgesByModule(callers, ShownCallers),
                                callees => coreEdgesByModule(callees, ShownCallees)
                            };
                        _ ->
                            coreEdgesByModule(Dir, Shown)
                    end,
                    #{
                        status => ok,
                        data => #{
                            mfa => Mfa,
                            direction => Dir,
                            edges => Shown,
                            callerEdges => ShownCallers,
                            calleeEdges => ShownCallees,
                            edgeCount => TotalCount,
                            mermaidEdgeCount => length(Shown),
                            truncated => TotalCount > length(Shown),
                            mermaid => alDocGen:mermaidCallEdges(Shown, MermaidCap, Briefs),
                            briefs => Briefs,
                            byModule => ByMod
                        }
                    };
                {error, Reason} ->
                    #{status => error, reason => Reason}
            end
    end.

coreGraphDirection(Body, DefaultDir) when is_map(Body) ->
    case maps:get(<<"direction">>, Body, undefined) of
        <<"both">> -> both;
        <<"callers">> -> callers;
        <<"callees">> -> callees;
        both -> both;
        callers -> callers;
        callees -> callees;
        _ -> DefaultDir
    end.

coreFetchGraphEdges(both, Module, Function, Arity) ->
    case {alCoreClient:getCallers(Module, Function, Arity),
          alCoreClient:getCallees(Module, Function, Arity)} of
        {{ok, CData}, {ok, EData}} ->
            Callers = coreUnwrapEdgeList(CData),
            Callees = coreUnwrapEdgeList(EData),
            {ok, #{
                callerEdges => Callers,
                calleeEdges => Callees,
                edges => Callers ++ Callees
            }};
        {{error, Reason}, _} ->
            {error, Reason};
        {_, {error, Reason}} ->
            {error, Reason}
    end;
coreFetchGraphEdges(callers, Module, Function, Arity) ->
    case alCoreClient:getCallers(Module, Function, Arity) of
        {ok, Data} ->
            Edges = coreUnwrapEdgeList(Data),
            {ok, #{callerEdges => Edges, calleeEdges => [], edges => Edges}};
        {error, Reason} ->
            {error, Reason}
    end;
coreFetchGraphEdges(callees, Module, Function, Arity) ->
    case alCoreClient:getCallees(Module, Function, Arity) of
        {ok, Data} ->
            Edges = coreUnwrapEdgeList(Data),
            {ok, #{callerEdges => [], calleeEdges => Edges, edges => Edges}};
        {error, Reason} ->
            {error, Reason}
    end.

coreUnwrapEdgeList(Data) ->
    Edges0 = unwrapCoreInspect(Data),
    Edges = case Edges0 of
        #{edges := E} when is_list(E) -> E;
        #{<<"edges">> := E2} when is_list(E2) -> E2;
        L when is_list(L) -> L;
        _ -> []
    end,
    case is_list(Edges) of true -> Edges; false -> [] end.

coreMfaBin(Module, Function, Arity) ->
    M = case Module of
        undefined -> <<"?">>;
        null -> <<"?">>;
        <<>> -> <<"?">>;
        _ -> coreToBin(Module)
    end,
    A = case Arity of
        N when is_integer(N) -> integer_to_binary(N);
        _ -> <<"?">>
    end,
    <<M/binary, ":", (coreToBin(Function))/binary, "/", A/binary>>.

coreToBin(B) when is_binary(B) -> B;
coreToBin(A) when is_atom(A) -> atom_to_binary(A, utf8);
coreToBin(L) when is_list(L) -> unicode:characters_to_binary(L);
coreToBin(I) when is_integer(I) -> integer_to_binary(I);
coreToBin(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).

%% 按对端模块聚合，便于面板摘要（callers→from_module；callees→to_module）。
coreEdgesByModule(Direction, Edges) when is_list(Edges) ->
    Key = case Direction of
        callers -> from_module;
        _ -> to_module
    end,
    FunKey = case Direction of
        callers -> from_function;
        _ -> to_function
    end,
    ArityKey = case Direction of
        callers -> from_arity;
        _ -> arity
    end,
    Groups = lists:foldl(fun(E, Acc) when is_map(E) ->
        Mod0 = maps:get(Key, E, maps:get(atom_to_binary(Key, utf8), E, <<"?">>)),
        Mod = coreToBin(Mod0),
        Fun0 = maps:get(FunKey, E, maps:get(atom_to_binary(FunKey, utf8), E, <<"?">>)),
        Ar0 = maps:get(ArityKey, E, maps:get(atom_to_binary(ArityKey, utf8), E, 0)),
        Line = maps:get(line, E, maps:get(<<"line">>, E, 0)),
        Site = iolist_to_binary(io_lib:format("~s/~p@~p", [coreToBin(Fun0), Ar0, Line])),
        Sites0 = maps:get(Mod, Acc, []),
        Acc#{Mod => [Site | Sites0]}
    end, #{}, Edges),
    lists:sort(fun(A, B) -> maps:get(n, A, 0) >= maps:get(n, B, 0) end, [
        #{mod => Mod, n => length(Sites), sites => lists:reverse(Sites)}
     || {Mod, Sites} <- maps:to_list(Groups)]);
coreEdgesByModule(_, _) ->
    [].

truncateModuleSymbols(Data, MaxCalls) when is_map(Data) ->
    Doc = case maps:get(document, Data, maps:get(<<"document">>, Data, undefined)) of
        D when is_map(D) -> D;
        _ -> Data
    end,
    Calls0 = maps:get(calls, Doc, maps:get(<<"calls">>, Doc, [])),
    Calls = case is_list(Calls0) of true -> Calls0; false -> [] end,
    Remote = length([C || C <- Calls,
        begin
            To = maps:get(to_module, C, maps:get(<<"to_module">>, C, undefined)),
            From = maps:get(from_module, C, maps:get(<<"from_module">>, C, undefined)),
            To =/= undefined andalso From =/= undefined andalso To =/= From
        end]),
    Doc1 = Doc#{
        calls => lists:sublist(Calls, MaxCalls),
        callCount => length(Calls),
        remoteCallCount => Remote,
        callsTruncated => length(Calls) > MaxCalls
    },
    case maps:is_key(document, Data) orelse maps:is_key(<<"document">>, Data) of
        true -> Data#{document => Doc1, module => maps:get(module, Data, maps:get(<<"module">>, Data, undefined))};
        false -> Doc1
    end;
truncateModuleSymbols(Other, _) ->
    Other.
