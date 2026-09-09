%%%-------------------------------------------------------------------
%% @doc WebSocket 命令分发、心跳与流式转发。
%%
%% 由 {@link alWebHandler}:handleWs/3 调用，按 JSON 命令（`type` 字段）分发。
%% HTTP REST 路由不变；WS 是流式与推送的补充通道。
%%
%% 命令：
%%   * `status`       — 应用状态快照
%%   * `health`       — core + gateway 健康检查
%%   * `tools`        — 列出全部工具
%%   * `metrics`      — 运行时指标快照
%%   * `audit`        — 最近审计日志
%%   * `pending`      — 当前会话待审批项
%%   * `cancelAsk`    — 按 taskId（或 `all`）取消进行中的 ask
%%   * `setLlm`       — 覆盖会话的 LLM model/key
%%   * `mode`         — 设置策略模式（ask | edit | exec）
%%   * `ask`          — 启动流式 ask；派生 worker 将
%%                      `{eStreamChunk, ...}` 事件回写到 WS socket
%% @end
%%%-------------------------------------------------------------------

-module(alWs).

-include_lib("eWSrv/include/eWSrv.hrl").

-export([
    dispatch/3,
    initState/0,
    ownsTask/2,
    ownsPending/2,
    ownsCheckpoint/2,
    startHeartbeat/1,
    stopHeartbeat/0,
    stopSendGate/0,
    sendFrame/2,
    encodeMsg/1,
    touchLastActivity/0,
    ensureSendGate/1,
    outViaGate/2,
    sanitizeLlmOverride/1
]).

-define(HeartbeatIntervalMs, 30000).
%% 连续两次心跳（含等待）未见客户端任何响应即视为死连接，主动关闭。
-define(StaleTimeoutMs, 75000).
-define(WebSessionId, <<"web">>).

%% 进程字典键：上次收到客户端任意帧（含 pong）的时间（毫秒）。
-define(LastActivityKey, wsLastActivity).
-define(SendGateKey, wsSendGate).

%%%===================================================================
%%% WebSocket state
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 初始化 WebSocket 连接状态：每连接独立 session（避免多标签串扰），
%% 获取 session worker、读取当前模式。
%%
%% @return 初始状态 map
%% @end
%%--------------------------------------------------------------------
-spec initState() -> map().
initState() ->
    Sid = iolist_to_binary([
        <<"web-">>,
        integer_to_binary(erlang:unique_integer([positive, monotonic]))
    ]),
    _ = safeEnsureSession(Sid),
    Worker = safeSessionWorker(Sid),
    #{
        sessionId => Sid,
        sessionWorker => Worker,
        mode => safeGetMode(),
        llmOverride => undefined
    }.

%%--------------------------------------------------------------------
%% @doc
%% 安全调用 alSessionMgr:ensureSession 登记会话；异常时记录日志并返回错误元组。
%%
%% @end
%%--------------------------------------------------------------------
safeEnsureSession(Sid) ->
    try alSessionMgr:ensureSession(Sid, web) of
        Ok -> Ok
    catch
        Class:Reason ->
            logger:warning("alWs ensureSession failed: ~p:~p", [Class, Reason]),
            {error, {Class, Reason}}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 安全获取指定会话的 worker pid；失败或不存在时返回 undefined。
%%
%% @end
%%--------------------------------------------------------------------
safeSessionWorker(Sid) ->
    try alServer:ensureSessionWorker(Sid) of
        {ok, Pid} -> Pid;
        _ -> undefined
    catch
        _:_ -> undefined
    end.

%%--------------------------------------------------------------------
%% @doc
%% 校验缓存的 sessionWorker：pid 已死则清理缓存并按 sessionId 重建，
%% 避免向死进程发消息导致连接进程崩溃。
%%
%% @return `{Worker, NewState}'
%% @end
%%--------------------------------------------------------------------
resolveSessionWorker(WebState) ->
    case maps:get(sessionWorker, WebState, undefined) of
        Pid when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true ->
                    {Pid, WebState};
                false ->
                    Sid = maps:get(sessionId, WebState, ?WebSessionId),
                    Rebuilt = safeSessionWorker(Sid),
                    {Rebuilt, WebState#{sessionWorker => Rebuilt}}
            end;
        undefined ->
            {undefined, WebState}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 安全读取当前运行模式；异常时回退为 ask。
%%
%% @end
%%--------------------------------------------------------------------
safeGetMode() ->
    try alServer:getMode() of
        Mode -> Mode
    catch
        _:_ -> ask
    end.

%%%===================================================================
%%% Dispatch
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% WebSocket 命令分发入口：根据消息中的 type 字段直接派发给 dispatchCommand；
%% 缺少 type 字段时返回 missingType 错误。
%%
%% @param Cmd 解析后的命令 map
%% @param WebState 当前 WS 状态
%% @param Socket 底层 socket
%% @return {reply, Binary, NewState} | {ok, NewState} | {close, NewState}
%% @end
%%--------------------------------------------------------------------
-spec dispatch(map(), map(), term()) -> {reply, binary(), map()} | {ok, map()} | {close, map()}.
dispatch(#{<<"type">> := Type} = Cmd, WebState, Socket) ->
    dispatchCommand(Type, Cmd, WebState, Socket);
dispatch(_, WebState, _Socket) ->
    {reply, encodeMsg(#{type => error, error => missingType}), WebState}.


%%--------------------------------------------------------------------
%% @doc
%% 处理 status 命令：返回应用运行指标快照。
%%
%% @end
%%--------------------------------------------------------------------
dispatchCommand(<<"status">>, _Cmd, WebState, _Socket) ->
    Snap = alMetrics:snapshot(),
    {reply, encodeMsg(#{type => status, status => Snap}), WebState};

%%--------------------------------------------------------------------
%% @doc
%% 处理 health 命令：探测 core 与 gateway 健康状态。
%%
%% @end
%%--------------------------------------------------------------------
dispatchCommand(<<"health">>, _Cmd, WebState, _Socket) ->
    CoreStatus = case alCoreClient:health() of
        {ok, _} -> up;
        _ -> down
    end,
    {reply, encodeMsg(#{type => health, core => CoreStatus, gateway => up}), WebState};

%%--------------------------------------------------------------------
%% @doc
%% 处理 tools 命令：返回工具目录中所有工具。
%%
%% @end
%%--------------------------------------------------------------------
dispatchCommand(<<"tools">>, _Cmd, WebState, _Socket) ->
    Tools = alToolCatalog:allTools(),
    {reply, encodeMsg(#{type => tools, tools => Tools}), WebState};

%%--------------------------------------------------------------------
%% @doc
%% 处理 metrics 命令：返回经 web_handler 加工后的运行指标。
%%
%% @end
%%--------------------------------------------------------------------
dispatchCommand(<<"metrics">>, _Cmd, WebState, _Socket) ->
    Snap = alWebHandler:metricsForApi(alMetrics:snapshot()),
    {reply, encodeMsg(#{type => metrics, metrics => Snap}), WebState};

%%--------------------------------------------------------------------
%% @doc
%% 处理 audit 命令：返回最近 limit 条审计日志（默认 20）。
%%
%% @end
%%--------------------------------------------------------------------
dispatchCommand(<<"audit">>, Cmd, WebState, _Socket) ->
    Limit = maps:get(<<"limit">>, Cmd, 20),
    Entries = alAudit:list(Limit),
    {reply, encodeMsg(#{type => audit, entries => Entries}), WebState};

%%--------------------------------------------------------------------
%% @doc
%% 处理 pending 命令：
%% - 带 taskId → 查 alPending 单条（含 buildDiff 产出的 diff，供审批预览）
%% - 无 taskId → 返回当前会话 worker 的 pending ask 列表
%%
%% @end
%%--------------------------------------------------------------------
dispatchCommand(<<"pending">>, Cmd, WebState, _Socket) ->
    case maps:get(<<"taskId">>, Cmd, undefined) of
        undefined ->
            {Worker, NewState} = resolveSessionWorker(WebState),
            Pending = case Worker of
                undefined -> [];
                Pid when is_pid(Pid) -> alSessionWorker:pendingList(Pid)
            end,
            {reply, encodeMsg(#{type => pending, pending => Pending}), NewState};
        TaskId ->
            case alServer:pendingTask(TaskId) of
                {ok, Entry} ->
                    {reply, encodeMsg(#{type => pending, ok => true, pending => Entry}), WebState};
                {error, Reason} ->
                    {reply, encodeMsg(#{type => pending, ok => false, error => Reason}), WebState}
            end
    end;

%%--------------------------------------------------------------------
%% @doc
%% 处理 cancelAsk 命令：按 taskId 取消指定问答；taskId 为 all / 缺省时取消全部
%% （与 HTTP POST /api/ask/cancel 对齐，避免网页「中止」因缺 taskId 失效）；
%% 无 worker 时返回 noSession。
%%
%% @end
%%--------------------------------------------------------------------
dispatchCommand(<<"cancelAsk">>, Cmd, WebState, _Socket) ->
    %% 取消操作经本连接的 sessionWorker 执行，天然限定在当前会话内
    %% （cancelByTaskId/cancelAsk 都只作用于该 worker 的进行中问答），
    %% 不存在跨会话越权（任务 3 W6）。
    {Worker, NewState} = resolveSessionWorker(WebState),
    Result = case {Worker, maps:get(<<"taskId">>, Cmd, undefined)} of
        {undefined, _} ->
            #{ok => false, error => noSession};
        {Pid, <<"all">>} when is_pid(Pid) ->
            alSessionWorker:cancelAsk(Pid, all);
        {Pid, all} when is_pid(Pid) ->
            alSessionWorker:cancelAsk(Pid, all);
        {Pid, undefined} when is_pid(Pid) ->
            %% 缺省 = 取消本会话全部进行中问答（网页停止按钮常不带 taskId）
            alSessionWorker:cancelAsk(Pid, all);
        {Pid, TaskId} when is_pid(Pid) ->
            alSessionWorker:cancelByTaskId(Pid, TaskId)
    end,
    {reply, encodeMsg(#{type => cancelAsk, result => Result}), NewState};

%%--------------------------------------------------------------------
%% @doc
%% 处理 setLlm 命令：根据 enabled 与 llm 字段构造 Override（disabled 或空 map 视为 undefined），
%% 通过 session worker 应用覆盖，并更新 WebState。
%%
%% @end
%%--------------------------------------------------------------------
%% @doc
%% 处理 noteOutcome 命令：用户对答案的反馈回流（accepted / regenerated / rejected）。
%% 写入该会话最近一条 critique 的 outcome 列，供 critic 阈值自校准统计。
%%
%% @end
%%--------------------------------------------------------------------
dispatchCommand(<<"noteOutcome">>, Cmd, WebState, _Socket) ->
    Outcome = maps:get(<<"outcome">>, Cmd, undefined),
    SessionId = maps:get(sessionId, WebState, undefined),
    ok = alCritic:noteOutcome(SessionId, Outcome),
    {reply, encodeMsg(#{type => noteOutcome, outcome => Outcome}), WebState};

dispatchCommand(<<"setLlm">>, Cmd, WebState, _Socket) ->
    Llm0 = maps:get(<<"llm">>, Cmd, #{}),
    Override = case maps:get(<<"enabled">>, Cmd, true) of
        false -> undefined;
        _ ->
            sanitizeLlmOverride(Llm0)
    end,
    Worker = maps:get(sessionWorker, WebState, undefined),
    case Worker of
        Pid when is_pid(Pid) ->
            ok = alSessionWorker:setLlmOverride(Pid, Override);
        _ ->
            ok
    end,
    NewState = WebState#{llmOverride => Override},
    HasClientKey = is_map(Override) andalso maps:is_key(apiKey, Override),
    Resp = #{
        type => setLlm,
        enabled => Override =/= undefined,
        hasApiKey => HasClientKey,
        provider => case Override of
            #{provider := P} -> P;
            _ -> null
        end,
        model => case Override of
            #{model := M} -> M;
            _ -> null
        end
    },
    {reply, encodeMsg(Resp), NewState};

%%--------------------------------------------------------------------
%% @doc
%% 处理 mode 命令：全局设置模式并同步到当前会话 worker，更新 WebState。
%%
%% @end
%%--------------------------------------------------------------------
dispatchCommand(<<"mode">>, Cmd, WebState, _Socket) ->
    Mode0 = maps:get(<<"mode">>, Cmd, ask),
    case applyMode(Mode0) of
        ok ->
            Normalized = normalizeModeAtom(Mode0),
            Worker = maps:get(sessionWorker, WebState, undefined),
            case Worker of
                Pid when is_pid(Pid) ->
                    try alSessionWorker:setMode(Pid, Normalized)
                    catch _:_ -> ok end;
                _ -> ok
            end,
            NewState = WebState#{mode => Normalized},
            {reply, encodeMsg(#{type => mode, mode => Normalized}), NewState};
        {error, invalidMode} ->
            %% 非法模式：回复 error 帧且不修改 WebState.mode（任务 2 W2）。
            {reply, encodeMsg(#{type => mode, ok => false, error => invalidMode}), WebState}
    end;

%% 处理 tasks 命令：返回所有异步任务列表。
dispatchCommand(<<"tasks">>, _Cmd, WebState, _Socket) ->
    {reply, encodeMsg(#{type => tasks, tasks => alTask:list()}), WebState};

%%--------------------------------------------------------------------
%% @doc
%% 处理 plan 命令：返回指定会话的计划（带 summary），经 web_handler 加工后回传。
%%
%% @end
%%--------------------------------------------------------------------
dispatchCommand(<<"plan">>, Cmd, WebState, _Socket) ->
    Sid = maps:get(<<"sessionId">>, Cmd, maps:get(sessionId, WebState, ?WebSessionId)),
    Plan = alPlan:getPlan(Sid),
    {reply, encodeMsg(#{type => plan, plan => alWebHandler:planForApi(alPlan:withSummary(Plan))}), WebState};

%% 处理 tokenStats 命令：返回 token 统计。
dispatchCommand(<<"tokenStats">>, _Cmd, WebState, _Socket) ->
    {reply, encodeMsg(#{type => tokenStats, stats => alTokenStats:stats()}), WebState};

%% 处理 resetTokenStats 命令：重置 token 统计。
dispatchCommand(<<"resetTokenStats">>, _Cmd, WebState, _Socket) ->
    alTokenStats:reset(),
    {reply, encodeMsg(#{type => resetTokenStats, ok => true}), WebState};

%%--------------------------------------------------------------------
%% @doc
%% 处理 saveSession 命令：持久化指定会话到磁盘。
%%
%% @end
%%--------------------------------------------------------------------
dispatchCommand(<<"saveSession">>, Cmd, WebState, _Socket) ->
    Sid = maps:get(<<"sessionId">>, Cmd, maps:get(sessionId, WebState, ?WebSessionId)),
    Result = alSessionMgr:saveSession(Sid),
    {reply, encodeMsg(#{type => saveSession, result => Result}), WebState};

%%--------------------------------------------------------------------
%% @doc
%% 处理 deleteSession 命令：删除指定会话的磁盘文件。
%%
%% @end
%%--------------------------------------------------------------------
dispatchCommand(<<"deleteSession">>, Cmd, WebState, _Socket) ->
    Sid = maps:get(<<"sessionId">>, Cmd, maps:get(sessionId, WebState, ?WebSessionId)),
    Dir = alSessionMgr:sessionsDir(),
    Path = alSessionMgr:sessionFilePath(Sid),
    Result = case alWebSec:isPathWithin(Dir, Path) of
        true -> file:delete(Path);
        false -> {error, forbidden}
    end,
    {reply, encodeMsg(#{type => deleteSession, result => Result}), WebState};

%%--------------------------------------------------------------------
%% @doc
%% 处理 cancelTask 命令：按 taskId 取消异步任务；缺 taskId 返回 missingTaskId。
%%
%% @end
%%--------------------------------------------------------------------
dispatchCommand(<<"cancelTask">>, Cmd, WebState, _Socket) ->
    TaskId = maps:get(<<"taskId">>, Cmd, undefined),
    SessionId = requestSessionId(Cmd),
    Result = case TaskId of
        undefined -> {error, missingTaskId};
        _ ->
            case ownsTask(SessionId, TaskId) of
                true -> alServer:cancelTask(TaskId);
                false -> #{ok => false, error => notOwned};
                unknown -> alServer:cancelTask(TaskId)
            end
    end,
    {reply, encodeMsg(#{type => cancelTask, result => Result}), WebState};

%%--------------------------------------------------------------------
%% @doc
%% 处理 approve 命令：异步批准并流式推送 token/progress（与 ask 对齐）。
%% @end
%%--------------------------------------------------------------------
dispatchCommand(<<"approve">>, Cmd, WebState, Socket) ->
    TaskId = maps:get(<<"taskId">>, Cmd, undefined),
    SessionId = requestSessionId(Cmd),
    case TaskId of
        undefined ->
            {reply, encodeMsg(#{type => error, error => missingTaskId}), WebState};
        _ ->
            case ownsPending(SessionId, TaskId) of
                false ->
                    {reply, encodeMsg(#{type => approve, ok => false, error => notOwned,
                                        taskId => TaskId}), WebState};
                _ ->
                    startStreamingApprove(Socket, SessionId, TaskId),
                    {reply, encodeMsg(#{type => ack, kind => approve, taskId => TaskId}), WebState}
            end
    end;

%%--------------------------------------------------------------------
%% @doc
%% 处理 dismiss 命令：驳回待确认任务。
%%
%% @end
%%--------------------------------------------------------------------
dispatchCommand(<<"dismiss">>, Cmd, WebState, _Socket) ->
    TaskId = maps:get(<<"taskId">>, Cmd, undefined),
    SessionId = requestSessionId(Cmd),
    Result = case TaskId of
        undefined -> {error, missingTaskId};
        _ ->
            case ownsPending(SessionId, TaskId) of
                true -> alServer:dismiss(TaskId);
                false -> #{ok => false, error => notOwned};
                unknown -> alServer:dismiss(TaskId)
            end
    end,
    {reply, encodeMsg(#{type => dismiss, result => Result}), WebState};

%%--------------------------------------------------------------------
%% @doc
%% 处理 checkpoints 命令：列出全部可恢复的 checkpoint（重启后用于发现
%% 中断/挂起的任务）。
%%
%% @end
%%--------------------------------------------------------------------
dispatchCommand(<<"checkpoints">>, _Cmd, WebState, _Socket) ->
    Checkpoints = try alCheckpoint:list() catch _:_ -> [] end,
    {reply, encodeMsg(#{type => checkpoints, checkpoints => Checkpoints}), WebState};

%%--------------------------------------------------------------------
%% @doc
%% 处理 resume 命令：从 checkpoint 异步恢复并流式推送。
%% @end
%%--------------------------------------------------------------------
dispatchCommand(<<"resume">>, Cmd, WebState, Socket) ->
    TaskId = maps:get(<<"taskId">>, Cmd, undefined),
    SessionId = requestSessionId(Cmd),
    case TaskId of
        undefined ->
            {reply, encodeMsg(#{type => error, error => missingTaskId}), WebState};
        _ ->
            case ownsCheckpoint(SessionId, TaskId) of
                false ->
                    {reply, encodeMsg(#{type => resume, ok => false, error => notOwned,
                                        taskId => TaskId}), WebState};
                _ ->
                    startStreamingResume(Socket, SessionId, TaskId),
                    {reply, encodeMsg(#{type => ack, kind => resume, taskId => TaskId}), WebState}
            end
    end;

%%--------------------------------------------------------------------
%% @doc
%% 处理 ask 命令：启动流式提问。生成 TaskId、合并附件选项、启动 streaming worker，
%% 立即回复 ack；结果通过后续 answer / progress / done 帧推送。
%%
%% @end
%%--------------------------------------------------------------------
dispatchCommand(<<"ask">>, Cmd, WebState, Socket) ->
    Prompt = maps:get(<<"prompt">>, Cmd, maps:get(<<"question">>, Cmd, undefined)),
    SessionId = maps:get(<<"sessionId">>, Cmd, <<"web">>),
    case Prompt of
        undefined ->
            {reply, encodeMsg(#{type => error, error => missingPrompt}), WebState};
        _ ->
            TaskId = integer_to_binary(erlang:unique_integer([positive, monotonic])),
            Opts0 = #{sessionId => SessionId, taskId => TaskId},
            Opts1 = case alAttachments:optsFromBody(Cmd) of
                {ok, AttachOpts} -> alAttachments:mergeOpts(Opts0, AttachOpts);
                {error, _} -> Opts0
            end,
            Opts = mergeAskLlmOpts(Opts1, Cmd, WebState),
            startStreamingAsk(Socket, Prompt, Opts, WebState),
            {reply, encodeMsg(#{type => ack, kind => ask, taskId => TaskId}), WebState}
    end;

%% 处理 streamChat 命令：直接调用 LLM stream，转发 token 真流式（无工具路由）。
dispatchCommand(<<"streamChat">>, Cmd, WebState, Socket0) ->
    Prompt = maps:get(<<"prompt">>, Cmd, undefined),
    case Prompt of
        undefined ->
            {reply, encodeMsg(#{type => error, error => missingPrompt}), WebState};
        _ ->
            TaskId = integer_to_binary(erlang:unique_integer([positive, monotonic])),
            %% 用 dispatch 传入的 Socket 参数而非进程字典 get(wsSocket)，
            %% 避免依赖调用进程的进程字典状态（1d）。
            Socket = resolveSocket(Socket0),
            Gate = ensureSendGate(Socket),
            spawn(fun() -> startStreamChat(Gate, Prompt, Cmd, TaskId) end),
            {reply, encodeMsg(#{type => ack, kind => streamChat, taskId => TaskId}), WebState}
    end;

%% 处理 ping 命令：返回 pong。
dispatchCommand(<<"ping">>, _Cmd, WebState, _Socket) ->
    {reply, encodeMsg(#{type => pong}), WebState};

%% 处理 close 命令：请求关闭连接。
dispatchCommand(<<"close">>, _Cmd, WebState, _Socket) ->
    {close, WebState};

%% 兜底处理未知命令：返回 unknownCommand 错误并附带原命令名。
dispatchCommand(Type, _Cmd, WebState, _Socket) ->
    {reply, encodeMsg(#{type => error, error => unknownCommand, command => Type}), WebState}.

%%%===================================================================
%%% Streaming ask
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 启动流式提问：spawn 一个 progress 转发进程与一个 ask 执行进程。
%% ask 进程通过 session_worker 或 alServer:ask 执行，结果以单帧 answer 回传
%% （当前 alAgent 非流式；后续可升级为真正的 token 流）。
%% 完成或异常后发送 done 帧。
%%
%% @end
%%--------------------------------------------------------------------
%% Spawn a worker that runs alAgent:run/2 and forwards chunks to the WS socket.
%% For simplicity (current alAgent is synchronous), we spawn the ask and
%% forward the final result as a single chunk. When LLM streaming is wired
%% through alAgent, this can be upgraded to true streaming.
startStreamingAsk(Socket0, Prompt, Opts, WebState) ->
    SessionId = maps:get(sessionId, Opts, ?WebSessionId),
    Worker = maps:get(sessionWorker, WebState, undefined),
    TaskId = maps:get(taskId, Opts, undefined),
    ProgressId = TaskId,
    Socket = resolveSocket(Socket0),
    Gate = ensureSendGate(Socket),
    ConnPid = self(),
    TokenFwd = spawn(fun() -> tokenForwardLoop(Gate, TaskId) end),
    FinalOpts = Opts#{
        sessionId => SessionId,
        persistMemory => true,
        mode => maps:get(mode, WebState, ask),
        progressId => ProgressId,
        taskId => TaskId,
        streamCaller => TokenFwd
    },
    Monitor = spawn(fun() -> progressForwardLoop(Gate, ProgressId, 0, ConnPid) end),
    spawn(fun() ->
        ConnRef = erlang:monitor(process, ConnPid),
        try
            Result = case Worker of
                Pid when is_pid(Pid) ->
                    Tag = make_ref(),
                    alSessionWorker:ask(Pid, {self(), Tag}, Prompt, FinalOpts),
                    receive
                        {Tag, Reply} -> Reply;
                        {'DOWN', ConnRef, process, _, _} ->
                            %% WS 断连：精确取消本任务，不等待结果（任务 1 W1）。
                            try alSessionWorker:cancelByTaskId(Pid, TaskId)
                            catch _:_ -> ok end,
                            connDown
                    after 1800000 -> {error, timeout}
                    end;
                _ ->
                    alServer:ask(Prompt, FinalOpts)
            end,
            case Result of
                connDown -> ok;
                _ ->
                    case is_process_alive(ConnPid) of
                        false -> ok;
                        true ->
                            case Result of
                                {ok, Res} ->
                                    try sendAnswerFrame(Gate, TaskId, Res)
                                    catch SendC:SendR:SendSt ->
                                        alAskDiag:report(SendC, SendR, SendSt,
                                                         #{where => sendAnswerFrame, taskId => TaskId}),
                                        sendErrorFrames(Gate, TaskId,
                                                        alAskDiag:formatDetail(SendC, SendR, SendSt))
                                    end;
                                {error, Reason} ->
                                    alAskDiag:report(error, Reason, [],
                                                     #{where => askResult, taskId => TaskId}),
                                    Detail = case Reason of
                                        {agentCrash, CrashC, CrashR, CrashSt} ->
                                            alAskDiag:formatDetail(CrashC, CrashR, CrashSt);
                                        _ ->
                                            alChat:formatChatError(Reason)
                                    end,
                                    sendErrorFrames(Gate, TaskId, Detail)
                            end
                    end
            end
        catch ExClass:ExReason:Stack ->
            alAskDiag:report(ExClass, ExReason, Stack,
                             #{where => askWorker, taskId => TaskId}),
            CatchErr = alAskDiag:formatDetail(ExClass, ExReason, Stack),
            sendErrorFrames(Gate, TaskId, CatchErr)
        after
            erlang:demonitor(ConnRef, [flush]),
            TokenFwd ! eStop,
            Monitor ! eStop,
            out(Gate, encodeMsg(#{type => done, taskId => TaskId}))
        end
    end),
    ok.

%% 审批续跑：重挂 streamCaller + progress，结束后推 answer/done。
startStreamingApprove(Socket0, SessionId, TaskId) ->
    ConnPid = self(),
    Socket = resolveSocket(Socket0),
    Gate = ensureSendGate(Socket),
    TokenFwd = spawn(fun() -> tokenForwardLoop(Gate, TaskId) end),
    Monitor = spawn(fun() -> progressForwardLoop(Gate, TaskId, 0, ConnPid) end),
    Extra = #{
        streamCaller => TokenFwd,
        progressId => TaskId,
        taskId => TaskId,
        sessionId => SessionId
    },
    spawn(fun() ->
        ConnRef = erlang:monitor(process, ConnPid),
        try
            case runWithConnGuard(ConnRef, SessionId, TaskId,
                                  fun() -> alServer:approve(TaskId, Extra) end) of
                connDown ->
                    ok;
                {result, Res} ->
                    case is_process_alive(ConnPid) of
                        false -> ok;
                        true -> forwardApproveResult(Gate, TaskId, Res)
                    end;
                {crash, C, R, St} ->
                    case is_process_alive(ConnPid) of
                        false -> ok;
                        true -> forwardApproveCrash(Gate, TaskId, C, R, St)
                    end
            end
        after
            erlang:demonitor(ConnRef, [flush]),
            TokenFwd ! eStop,
            Monitor ! eStop,
            out(Gate, encodeMsg(#{type => done, taskId => TaskId}))
        end
    end),
    ok.

%% checkpoint 恢复：同样重挂流式通道。
startStreamingResume(Socket0, SessionId, TaskId) ->
    ConnPid = self(),
    Socket = resolveSocket(Socket0),
    Gate = ensureSendGate(Socket),
    TokenFwd = spawn(fun() -> tokenForwardLoop(Gate, TaskId) end),
    Monitor = spawn(fun() -> progressForwardLoop(Gate, TaskId, 0, ConnPid) end),
    Extra = #{
        streamCaller => TokenFwd,
        progressId => TaskId,
        taskId => TaskId,
        sessionId => SessionId
    },
    spawn(fun() ->
        ConnRef = erlang:monitor(process, ConnPid),
        try
            case runWithConnGuard(ConnRef, SessionId, TaskId,
                                  fun() -> alToolRouter:resumeFromCheckpoint(TaskId, undefined, Extra) end) of
                connDown ->
                    ok;
                {result, Res} ->
                    case is_process_alive(ConnPid) of
                        false -> ok;
                        true -> forwardResumeResult(Gate, TaskId, Res)
                    end;
                {crash, C, R, St} ->
                    case is_process_alive(ConnPid) of
                        false -> ok;
                        true ->
                            CatchErr = alAskDiag:formatDetail(C, R, St),
                            sendErrorFrames(Gate, TaskId, CatchErr),
                            out(Gate, encodeMsg(#{
                                type => resume, ok => false, taskId => TaskId,
                                error => CatchErr
                            }))
                    end
            end
        after
            erlang:demonitor(ConnRef, [flush]),
            TokenFwd ! eStop,
            Monitor ! eStop,
            out(Gate, encodeMsg(#{type => done, taskId => TaskId}))
        end
    end),
    ok.

%% 在独立执行进程里跑 Fun，同时 monitor 连接进程（任务 4 W7）：
%% - ConnPid 先断连 → kill 执行进程 + cancelByTaskId（与 W1 对齐）并返回 connDown
%% - Fun 先返回 → 返回 {result, Value}
%% - Fun 抛异常 → 返回 {crash, Class, Reason, Stack}
runWithConnGuard(ConnRef, SessionId, TaskId, Fun) ->
    Self = self(),
    Executor = spawn(fun() ->
        Res = try {result, Fun()}
              catch C:R:St -> {crash, C, R, St}
              end,
        Self ! {execDone, Res}
    end),
    ExecRef = erlang:monitor(process, Executor),
    receive
        {execDone, Res} ->
            erlang:demonitor(ExecRef, [flush]),
            Res;
        {'DOWN', ExecRef, process, _, Reason} ->
            {crash, error, {executorDown, Reason}, []};
        {'DOWN', ConnRef, process, _, _} ->
            erlang:demonitor(ExecRef, [flush]),
            exit(Executor, kill),
            cancelTaskOnConnDown(SessionId, TaskId),
            connDown
    end.

%% WS 断连时精确取消任务（approve/resume 与 ask 对齐）。
cancelTaskOnConnDown(SessionId, TaskId) ->
    try alServer:cancelAskByTaskId(SessionId, TaskId)
    catch _:_ ->
        try alServer:cancelTask(TaskId) catch _:_ -> ok end
    end.

%% 审批结果转发：成功/失败分别推 answer + approve 帧。
forwardApproveResult(Gate, TaskId, Res) ->
    case Res of
        {ok, R} ->
            sendAnswerFrame(Gate, TaskId, R),
            out(Gate, encodeMsg(#{
                type => approve, ok => true, taskId => TaskId,
                result => R,
                answer => alWebHandler:approveAnswerText(R)
            }));
        {error, Reason} ->
            ErrText = alChat:formatChatError(Reason),
            sendErrorFrames(Gate, TaskId, ErrText),
            out(Gate, encodeMsg(#{
                type => approve, ok => false, taskId => TaskId,
                error => Reason
            }))
    end.

%% 审批执行进程崩溃：推送错误帧。
forwardApproveCrash(Gate, TaskId, C, R, St) ->
    CatchErr = alAskDiag:formatDetail(C, R, St),
    sendErrorFrames(Gate, TaskId, CatchErr),
    out(Gate, encodeMsg(#{type => approve, ok => false,
                          taskId => TaskId, error => CatchErr})).

%% checkpoint 恢复结果转发。
forwardResumeResult(Gate, TaskId, Res) ->
    case Res of
        {ok, R} ->
            sendAnswerFrame(Gate, TaskId, R),
            out(Gate, encodeMsg(#{
                type => resume, ok => true, taskId => TaskId,
                result => R
            }));
        {error, {C1, R1, St1}} ->
            CatchErr = alAskDiag:formatDetail(C1, R1, St1),
            sendErrorFrames(Gate, TaskId, CatchErr),
            out(Gate, encodeMsg(#{
                type => resume, ok => false, taskId => TaskId,
                error => CatchErr
            }));
        {error, Reason} ->
            ErrText = alChat:formatChatError(Reason),
            sendErrorFrames(Gate, TaskId, ErrText),
            out(Gate, encodeMsg(#{
                type => resume, ok => false, taskId => TaskId,
                error => Reason
            }));
        Other ->
            out(Gate, encodeMsg(#{
                type => resume, ok => true, taskId => TaskId,
                result => Other
            }))
    end.

%% 把 LLM token 增量经 SendGate 推到 WS。
tokenForwardLoop(Gate, TaskId) ->
    tokenForwardLoop(Gate, TaskId, false).

tokenForwardLoop(Gate, TaskId, SawToolDelta) ->
    receive
        eStop ->
            drainTokenFwd(Gate, TaskId);
        {eStreamChunk, Chunk} when is_binary(Chunk), Chunk =/= <<>> ->
            out(Gate, encodeMsg(#{type => token, taskId => TaskId, text => Chunk})),
            tokenForwardLoop(Gate, TaskId, SawToolDelta);
        {eStreamChunk, Chunk} when is_list(Chunk) ->
            Bin = unicode:characters_to_binary(Chunk),
            out(Gate, encodeMsg(#{type => token, taskId => TaskId, text => Bin})),
            tokenForwardLoop(Gate, TaskId, SawToolDelta);
        {eStreamReasoning, Chunk} when is_binary(Chunk), Chunk =/= <<>> ->
            out(Gate, encodeMsg(#{
                type => token, taskId => TaskId, text => Chunk, kind => reasoning
            })),
            tokenForwardLoop(Gate, TaskId, SawToolDelta);
        {eStreamReasoning, Chunk} when is_list(Chunk) ->
            Bin = unicode:characters_to_binary(Chunk),
            out(Gate, encodeMsg(#{
                type => token, taskId => TaskId, text => Bin, kind => reasoning
            })),
            tokenForwardLoop(Gate, TaskId, SawToolDelta);
        {eStreamToolDelta, Delta} ->
            case SawToolDelta of
                true -> ok;
                false ->
                    Msg = toolDeltaHint(Delta),
                    out(Gate, encodeMsg(#{
                        type => progress, taskId => TaskId,
                        event => #{type => step, phase => toolCall, message => Msg}
                    }))
            end,
            tokenForwardLoop(Gate, TaskId, true);
        {eStreamDone, _} ->
            tokenForwardLoop(Gate, TaskId, SawToolDelta);
        {eStreamError, _} ->
            tokenForwardLoop(Gate, TaskId, SawToolDelta);
        _ ->
            tokenForwardLoop(Gate, TaskId, SawToolDelta)
    after 1800000 ->
        ok
    end.

toolDeltaHint(Deltas) when is_list(Deltas) ->
    Names = [N || D <- Deltas, N <- [toolDeltaName(D)], N =/= <<>>],
    case Names of
        [N | _] -> <<"正在生成工具调用 "/utf8, N/binary, "…"/utf8>>;
        _ -> <<"正在生成工具调用…"/utf8>>
    end;
toolDeltaHint(Delta) ->
    case toolDeltaName(Delta) of
        <<>> -> <<"正在生成工具调用…"/utf8>>;
        N -> <<"正在生成工具调用 "/utf8, N/binary, "…"/utf8>>
    end.

toolDeltaName(Delta) when is_map(Delta) ->
    Fun = maps:get(<<"function">>, Delta, maps:get(function, Delta, #{})),
    case Fun of
        M when is_map(M) ->
            toBinary(maps:get(<<"name">>, M, maps:get(name, M, <<>>)));
        _ -> <<>>
    end;
toolDeltaName(_) ->
    <<>>.

%% eStop 后排空邮箱里残留的 chunk，避免尾包丢失导致前端「回答为空」。
drainTokenFwd(Gate, TaskId) ->
    receive
        {eStreamChunk, Chunk} when is_binary(Chunk), Chunk =/= <<>> ->
            out(Gate, encodeMsg(#{type => token, taskId => TaskId, text => Chunk})),
            drainTokenFwd(Gate, TaskId);
        {eStreamChunk, Chunk} when is_list(Chunk) ->
            Bin = unicode:characters_to_binary(Chunk),
            out(Gate, encodeMsg(#{type => token, taskId => TaskId, text => Bin})),
            drainTokenFwd(Gate, TaskId);
        {eStreamReasoning, Chunk} when is_binary(Chunk), Chunk =/= <<>> ->
            out(Gate, encodeMsg(#{
                type => token, taskId => TaskId, text => Chunk, kind => reasoning
            })),
            drainTokenFwd(Gate, TaskId);
        {eStreamReasoning, Chunk} when is_list(Chunk) ->
            Bin = unicode:characters_to_binary(Chunk),
            out(Gate, encodeMsg(#{
                type => token, taskId => TaskId, text => Bin, kind => reasoning
            })),
            drainTokenFwd(Gate, TaskId);
        _ ->
            drainTokenFwd(Gate, TaskId)
    after 0 ->
        ok
    end.
%%--------------------------------------------------------------------
%% @doc
%% 真 token 流式聊天：直接调用 alLlmClient:stream/4，将每个 token chunk
%% 作为 `token' 帧推送到 WebSocket。适用于无工具路由的简单对话。
%%
%% @param Socket WebSocket socket
%% @param Prompt 用户提示
%% @param Cmd    原始命令 map（可含 systemPrompt）
%% @param TaskId 任务 ID
%% @end
%%--------------------------------------------------------------------
startStreamChat(Gate, Prompt, Cmd, TaskId) ->
    AgentCfg = alConfig:getAgentCfg(),
    LlmOpts = maps:get(llm, AgentCfg, #{}),
    SystemPrompt = maps:get(<<"systemPrompt">>, Cmd, undefined),
    Messages = case SystemPrompt of
        undefined -> [];
        SP -> [#{role => system, content => SP}]
    end ++ [#{role => user, content => Prompt}],
    Caller = self(),
    case alLlmClient:stream(Messages, [], LlmOpts, Caller) of
        {ok, StreamPid} ->
            erlang:monitor(process, StreamPid),
            streamChatLoop(Gate, TaskId, <<>>, StreamPid, Messages, LlmOpts);
        {error, Reason} ->
            %% 流式启动失败：回退非流式 chatWithTools（其内部沿模型链升级），
            %% 成功则把答案作为单帧 token + answer 推送，避免用户直接看到报错。
            logger:warning("alWs streamChat failed (~p), fallback to chatWithTools", [Reason]),
            case alLlmClient:chatWithTools(Messages, [], LlmOpts) of
                {ok, Reply} ->
                    Content = case maps:get(content, Reply, undefined) of
                        Bin when is_binary(Bin) -> Bin;
                        _ -> <<>>
                    end,
                    out(Gate, encodeMsg(#{type => token, taskId => TaskId, text => Content})),
                    out(Gate, encodeMsg(#{type => answer, taskId => TaskId, text => Content})),
                    out(Gate, encodeMsg(#{type => done, taskId => TaskId}));
                _ ->
                    out(Gate, encodeMsg(#{type => error, taskId => TaskId,
                                                  error => toBinary(io_lib:format("~p", [Reason]))})),
                    out(Gate, encodeMsg(#{type => done, taskId => TaskId}))
            end
    end.

%% 接收 LLM stream 事件并转发为 WebSocket token 帧。
%% Messages/LlmOpts 仅供中途失败回退非流式重试用。
streamChatLoop(Gate, TaskId, Acc, StreamPid, Messages, LlmOpts) ->
    receive
        {eStreamChunk, Chunk} ->
            out(Gate, encodeMsg(#{type => token, taskId => TaskId, text => Chunk})),
            streamChatLoop(Gate, TaskId, <<Acc/binary, Chunk/binary>>, StreamPid, Messages, LlmOpts);
        {eStreamReasoning, Chunk} ->
            out(Gate, encodeMsg(#{
                type => token, taskId => TaskId, text => Chunk, kind => reasoning
            })),
            streamChatLoop(Gate, TaskId, Acc, StreamPid, Messages, LlmOpts);
        {eStreamDone, Content} ->
            FinalContent = case Content of
                <<>> -> Acc;
                _ -> Content
            end,
            out(Gate, encodeMsg(#{type => answer, taskId => TaskId, text => FinalContent})),
            out(Gate, encodeMsg(#{type => done, taskId => TaskId}));
        {eStreamError, Reason} ->
            %% 中途失败：回退非流式（内部沿模型链升级）。已推过的 token 不重推，
            %% 仅以 answer 帧给最终内容（前端以 answer 为准替换显示）。
            logger:warning("alWs streamChat mid-stream error (~p), fallback", [Reason]),
            case alLlmClient:chatWithTools(Messages, [], LlmOpts) of
                {ok, #{content := Bin} = _Reply} when is_binary(Bin), Bin =/= <<>> ->
                    out(Gate, encodeMsg(#{type => answer, taskId => TaskId, text => Bin})),
                    out(Gate, encodeMsg(#{type => done, taskId => TaskId}));
                _ ->
                    out(Gate, encodeMsg(#{type => error, taskId => TaskId,
                                                  error => toBinary(io_lib:format("~p", [Reason]))})),
                    out(Gate, encodeMsg(#{type => done, taskId => TaskId}))
            end;
        {eStreamToolCalls, _Deltas} ->
            streamChatLoop(Gate, TaskId, Acc, StreamPid, Messages, LlmOpts);
        {'DOWN', _Ref, process, StreamPid, Reason} ->
            out(Gate, encodeMsg(#{type => error, taskId => TaskId,
                                          error => toBinary(io_lib:format("stream process died: ~p", [Reason]))})),
            out(Gate, encodeMsg(#{type => done, taskId => TaskId}))
    after 120000 ->
        out(Gate, encodeMsg(#{type => error, taskId => TaskId, error => timeout})),
        out(Gate, encodeMsg(#{type => done, taskId => TaskId}))
    end.

%%--------------------------------------------------------------------
%% @doc
%% 进度转发循环：每 150ms 拉取新增 progress 事件经 SendGate 转发。
%% @end
%%--------------------------------------------------------------------
progressForwardLoop(Gate, TaskId, Since, ConnPid) ->
    receive
        eStop -> ok
    after 150 ->
        case is_process_alive(ConnPid) of
            false -> ok;
            _ ->
                Snap = alProgress:snapshot(TaskId, Since),
                Events = maps:get(events, Snap, []),
                lists:foreach(fun(Ev) ->
                    try
                        out(Gate, encodeMsg(#{type => progress, taskId => TaskId, event => Ev}))
                    catch
                        _:_ -> ok
                    end
                end, Events),
                Count = maps:get(eventCount, Snap, Since),
                case maps:get(status, Snap, running) of
                    running -> progressForwardLoop(Gate, TaskId, Count, ConnPid);
                    _ -> ok
                end
        end
    end.

extractAnswerText(Res) ->
    try
        alChat:safeDisplayAnswer(case Res of
            #{answer := Answer} -> Answer;
            _ when is_map(Res) -> maps:get(answer, Res, Res);
            Other -> Other
        end)
    catch
        _:_ -> <<"（回答解析失败）"/utf8>>
    end.

sendAnswerFrame(Gate, TaskId, Res) ->
    AnswerText = extractAnswerText(Res),
    out(Gate, encodeMsg(#{
        type => answer,
        taskId => TaskId,
        text => AnswerText,
        result => slimResult(Res, AnswerText)
    })).

sendErrorFrames(Gate, TaskId, ErrText0) ->
    ErrText = case ErrText0 of
        B when is_binary(B) -> B;
        _ -> toBinary(ErrText0)
    end,
    out(Gate, encodeMsg(#{type => error, taskId => TaskId, error => ErrText})),
    out(Gate, encodeMsg(#{type => answer, taskId => TaskId, text => ErrText})).

%%--------------------------------------------------------------------
%% @doc
%% 精简结果用于回传：answer 已是可显示 binary，避免嵌套 map/pid 等进 JSON。
%% @end
%%--------------------------------------------------------------------
slimResult(Map, AnswerText) when is_map(Map) ->
    #{
        answer => AnswerText,
        sessionId => sanitizeSessionId(maps:get(sessionId, Map, undefined)),
        critiqueRounds => maps:get(critiqueRounds, Map, 0)
    };
slimResult(_Other, AnswerText) ->
    #{answer => AnswerText}.

sanitizeSessionId(Id) when is_binary(Id); is_atom(Id); is_integer(Id) -> Id;
sanitizeSessionId(undefined) -> null;
sanitizeSessionId(Other) -> toBinary(Other).

%%%===================================================================
%%% Heartbeat
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 启动心跳进程：spawn 一个监控连接进程的循环，每 ?HeartbeatIntervalMs 发送 ping；
%% 心跳进程 pid 存入进程字典 wsHeartbeat。同时初始化 lastActivity 时间戳，
%% 供 stale 检测判断客户端是否仍然存活。
%%
%% @param Socket 底层 socket
%% @return ok
%% @end
%%--------------------------------------------------------------------
-spec startHeartbeat(term()) -> ok.
startHeartbeat(Socket0) ->
    ConnPid = self(),
    Socket = resolveSocket(Socket0),
    Gate = ensureSendGate(Socket),
    touchLastActivity(),
    Pid = spawn(fun() ->
        Ref = erlang:monitor(process, ConnPid),
        heartbeatLoop(Socket, Ref, ConnPid, Gate)
    end),
    put(wsHeartbeat, Pid),
    ok.

%% 在连接进程字典里刷新最近活动时间。心跳进程通过查询此值判断客户端是否存活。
touchLastActivity() ->
    put(?LastActivityKey, erlang:system_time(millisecond)).

%%--------------------------------------------------------------------
%% @doc
%% 停止心跳进程：从进程字典取出 pid，发送 eStop 后等待 DOWN；
%% 1 秒内未退出则强制 kill。
%%
%% @return ok
%% @end
%%--------------------------------------------------------------------
-spec stopHeartbeat() -> ok.
stopHeartbeat() ->
    case erase(wsHeartbeat) of
        undefined -> ok;
        Pid ->
            Ref = erlang:monitor(process, Pid),
            Pid ! eStop,
            receive
                {'DOWN', Ref, process, _, _} -> ok
            after 1000 ->
                exit(Pid, kill),
                ok
            end
    end.

%% @doc 停止连接级 SendGate（terminate 时调用，避免孤儿写死 socket）。
-spec stopSendGate() -> ok.
stopSendGate() ->
    case erase(?SendGateKey) of
        Pid when is_pid(Pid) ->
            Pid ! eStop,
            ok;
        _ ->
            ok
    end.

%%--------------------------------------------------------------------
%% @doc
%% 心跳循环：连接进程 DOWN 或收到 eStop 时退出；超时则发送 ping 帧后
%% 检查最近活动时间。若客户端超过 ?StaleTimeoutMs 未回应任何帧
%% （含浏览器自动回的 pong），则判定连接已死，主动 close socket 让
%% eWSrv 清理并触发客户端重连。
%%
%% @end
%%--------------------------------------------------------------------
heartbeatLoop(Socket, Ref, ConnPid, Gate) ->
    receive
        {'DOWN', Ref, process, _, _} ->
            ok;
        eStop ->
            ok
    after ?HeartbeatIntervalMs ->
        out(Gate, ?WsOpPing, <<>>),
        case isConnectionStale(ConnPid) of
            true ->
                logger:info("[ws] closing stale connection: no client activity for ~p ms",
                            [?StaleTimeoutMs]),
                closeSocket(Socket);
            false ->
                heartbeatLoop(Socket, Ref, ConnPid, Gate)
        end
    end.

%% 判断连接是否过期：lastActivity 距今超过阈值即视为死连接。
%% 通过 ConnPid 获取连接进程字典中的 lastActivity，避免心跳进程自己持有状态。
isConnectionStale(ConnPid) ->
    try
        Last = case process_info(ConnPid, dictionary) of
            {dictionary, Dict} ->
                proplists:get_value(?LastActivityKey, Dict);
            _ ->
                undefined
        end,
        case Last of
            undefined -> false;
            Ts when is_integer(Ts) ->
                erlang:system_time(millisecond) - Ts > ?StaleTimeoutMs
        end
    catch _:_ ->
        false
    end.

%% 主动关闭 socket：调用 wsNet:close 触发 eWSrv 连接清理。
%% 异常吞掉，避免心跳进程因 socket 已关闭而崩溃。
closeSocket(Socket) ->
    try
        case code:ensure_loaded(wsNet) of
            {module, wsNet} ->
                try wsNet:close(Socket) catch _:_ -> ok end;
            _ ->
                %% 没有 wsNet:close/1 时退化为 gen_tcp:close/1，
                %% 对 inet socket 同样能触发 eWSrv 的连接清理。
                try gen_tcp:close(Socket) catch _:_ -> ok end
        end
    catch _:_ -> ok end,
    ok.

%%%===================================================================
%%% Frame helpers
%%%===================================================================

%% @doc 确保本连接有发送闸门进程（持有 Socket，串行 wsNet:send）。
-spec ensureSendGate(term()) -> pid() | undefined.
ensureSendGate(Socket0) ->
    Socket = resolveSocket(Socket0),
    case Socket of
        undefined ->
            logger:warning("[ws] ensureSendGate: no socket"),
            undefined;
        _ ->
            case get(?SendGateKey) of
                Pid when is_pid(Pid) ->
                    case is_process_alive(Pid) of
                        true -> Pid;
                        false -> startSendGate(Socket)
                    end;
                _ ->
                    startSendGate(Socket)
            end
    end.

startSendGate(Socket) ->
    ConnPid = self(),
    Pid = spawn(fun() ->
        Mon = erlang:monitor(process, ConnPid),
        sendGateLoop(Socket, Mon)
    end),
    put(?SendGateKey, Pid),
    Pid.

sendGateLoop(Socket, Mon) ->
    receive
        {'DOWN', Mon, process, _, _} ->
            ok;
        eStop ->
            ok;
        {send, Opcode, Payload} when is_integer(Opcode), is_binary(Payload) ->
            sendFrame(Socket, Opcode, Payload),
            sendGateLoop(Socket, Mon);
        {send, Payload} when is_binary(Payload) ->
            sendFrame(Socket, ?WsOpText, Payload),
            sendGateLoop(Socket, Mon);
        _ ->
            sendGateLoop(Socket, Mon)
    end.

resolveSocket(Socket) when Socket =/= undefined, Socket =/= null ->
    Socket;
resolveSocket(_) ->
    get(wsSocket).

%% @doc 连接进程内便捷出口：优先 SendGate，否则直接写 socket。
-spec outViaGate(integer(), binary()) -> ok.
outViaGate(Opcode, Payload) ->
    Bin = payloadToBin(Payload),
    case get(?SendGateKey) of
        Gate when is_pid(Gate) -> out(Gate, Opcode, Bin);
        _ ->
            case get(wsSocket) of
                undefined -> ok;
                Socket -> sendFrame(Socket, Opcode, Bin)
            end
    end.

%% 旁路进程 → SendGate：串行化发送。
out(Gate, Payload) when is_pid(Gate), is_binary(Payload) ->
    out(Gate, ?WsOpText, Payload);
out(undefined, _Payload) ->
    ok;
out(Gate, Payload) ->
    out(Gate, ?WsOpText, payloadToBin(Payload)).

out(undefined, _Opcode, _Payload) ->
    ok;
out(Gate, Opcode, Payload) when is_pid(Gate) ->
    Bin = payloadToBin(Payload),
    case is_process_alive(Gate) of
        true -> Gate ! {send, Opcode, Bin}, ok;
        false -> ok
    end.

payloadToBin(B) when is_binary(B) -> B;
payloadToBin(L) when is_list(L) ->
    case unicode:characters_to_binary(L) of
        U when is_binary(U) -> U;
        _ -> toBinary(L)
    end;
payloadToBin(Other) ->
    toBinary(Other).

%%--------------------------------------------------------------------
%% @doc
%% 发送文本帧或 ping 帧的便捷入口。
%% @end
%%--------------------------------------------------------------------
-spec sendFrame(term(), binary()) -> ok.
sendFrame(Socket, Payload) when is_binary(Payload) ->
    sendFrame(Socket, ?WsOpText, Payload);
sendFrame(Socket, ping) ->
    sendFrame(Socket, ?WsOpPing, <<>>).

%%--------------------------------------------------------------------
%% @doc
%% 底层帧发送：仅应在 SendGate / 连接进程内调用。
%% @end
%%--------------------------------------------------------------------
sendFrame(Socket, Opcode, Payload) ->
    Bin = payloadToBin(Payload),
    Frame = encodeWsFrame(Opcode, Bin),
    try wsNet:send(Socket, Frame) catch _:_ -> ok end,
    ok.

%%--------------------------------------------------------------------
%% @doc
%% WebSocket 帧编码器（服务端→客户端，无需客户端掩码）：
%% 按 Payload 长度选择 7/16/64 位长度字段。
%%
%% @end
%%--------------------------------------------------------------------
%% WebSocket text/binary frame encoder (client-mask not required for server-to-client).
encodeWsFrame(Opcode, Payload) ->
    PayloadLen = byte_size(Payload),
    if
        PayloadLen < 126 ->
            <<1:1, 0:3, Opcode:4, 0:1, PayloadLen:7, Payload/binary>>;
        PayloadLen =< 16#FFFF ->
            <<1:1, 0:3, Opcode:4, 0:1, 126:7, PayloadLen:16, Payload/binary>>;
        true ->
            <<1:1, 0:3, Opcode:4, 0:1, 127:7, PayloadLen:64, Payload/binary>>
    end.

%%--------------------------------------------------------------------
%% @doc
%% 将 map 编码为 JSON binary（委托 alJson:encode）。
%%
%% @end
%%--------------------------------------------------------------------
-spec encodeMsg(map()) -> binary().
encodeMsg(Map) ->
    %% encodeSafe：永不因 jiffy badarg 拖垮 ask worker
    alJson:encodeSafe(Map).

%%--------------------------------------------------------------------
%% @doc
%% 将任意输入转为 binary：支持 binary / list / atom 及其它 term（~p 格式化）。
%% list 走 unicode，避免中文 char list 触发 list_to_binary badarg。
%% @end
%%--------------------------------------------------------------------
toBinary(V) when is_binary(V) -> V;
toBinary(V) when is_list(V) ->
    case unicode:characters_to_binary(V) of
        B when is_binary(B) -> B;
        _ -> unicode:characters_to_binary(io_lib:format("~p", [V]))
    end;
toBinary(V) when is_atom(V) -> atom_to_binary(V, utf8);
toBinary(V) -> iolist_to_binary(io_lib:format("~p", [V])).

%%--------------------------------------------------------------------
%% @doc
%% 归一化模式原子：支持原子与二进制；非法值回退为 ask。
%%
%% @end
%%--------------------------------------------------------------------
normalizeModeAtom(Mode) when Mode =:= ask; Mode =:= edit; Mode =:= exec; Mode =:= plan -> Mode;
normalizeModeAtom(<<"ask">>) -> ask;
normalizeModeAtom(<<"edit">>) -> edit;
normalizeModeAtom(<<"exec">>) -> exec;
normalizeModeAtom(<<"plan">>) -> plan;
normalizeModeAtom(_) -> ask.

%% 应用全局模式设置：alServer 明确返回 {error, invalidMode} 时透传，
%% 其余（含 alServer 未启动等异常）视为成功，保持旧有吞异常语义。
applyMode(Mode) ->
    try alServer:setMode(Mode) of
        {error, invalidMode} = E -> E;
        _ -> ok
    catch
        _:_ -> ok
    end.

%%--------------------------------------------------------------------
%% @doc
%% 从请求命令中提取客户端声明的会话 ID；缺省回退为 <<"web">>，
%% 与 ask 命令确定任务 sessionId 的默认值保持一致。
%% @end
%%--------------------------------------------------------------------
requestSessionId(Cmd) ->
    maps:get(<<"sessionId">>, Cmd, ?WebSessionId).

%%--------------------------------------------------------------------
%% @doc
%% 归属校验（任务 3 W6）：TaskId 对应的异步任务是否属于 SessionId。
%% 返回 true（属于）/ false（不属于）/ unknown（无法判定：任务不存在或
%% 记录缺少 sessionId 字段，交由调用方降级处理）。
%% @end
%%--------------------------------------------------------------------
ownsTask(SessionId, TaskId) ->
    try alTask:status(TaskId) of
        {ok, Task} -> compareSessionId(SessionId, maps:find(sessionId, Task));
        {error, _} -> unknown
    catch
        _:_ -> unknown
    end.

%%--------------------------------------------------------------------
%% @doc
%% 归属校验：TaskId 对应的 pending 条目是否属于 SessionId。
%% @end
%%--------------------------------------------------------------------
ownsPending(SessionId, TaskId) ->
    try alPending:get(TaskId) of
        {ok, Entry} -> compareSessionId(SessionId, maps:find(sessionId, Entry));
        {error, _} -> unknown
    catch
        _:_ -> unknown
    end.

%%--------------------------------------------------------------------
%% @doc
%% 归属校验：TaskId 对应的 checkpoint 是否属于 SessionId。
%% checkpoint 无顶层 sessionId，仅能从续跑上下文 opts 中取；取不到时
%% 返回 unknown（调用方降级放行），此处标注 TODO 以说明限制。
%% @end
%%--------------------------------------------------------------------
ownsCheckpoint(SessionId, TaskId) ->
    try alCheckpoint:load(TaskId) of
        {ok, Continuation} ->
            Opts = maps:get(opts, Continuation, #{}),
            %% TODO: checkpoint 未在顶层持久化 sessionId，仅依赖 opts 中的
            %% sessionId 做归属判定；opts 缺失时无法校验，降级为 unknown。
            compareSessionId(SessionId, maps:find(sessionId, Opts));
        {error, _} -> unknown
    catch
        _:_ -> unknown
    end.

%% 归一化比较两个 sessionId；记录缺少 sessionId 字段时返回 unknown。
compareSessionId(SessionId, {ok, SessionId}) -> true;
compareSessionId(_SessionId, {ok, _Other}) -> false;
compareSessionId(_SessionId, error) -> unknown.

%%--------------------------------------------------------------------
%% @doc
%% 净化客户端提交的 LLM 覆盖字段。
%% 接受：provider / model / apiKey（仅存会话内存，不回写 cfg、不回传）。
%% 拒绝：baseUrl 等其它字段——防止客户端注入 baseUrl，把请求导向攻击者
%% URL 并带上服务端真实 Key（SSRF / Key 外泄）。
%% 输出统一为 atom 键，便于 maps:merge 覆盖 alConfig 的 llm map。
%%
%% @param Llm 客户端提交的 llm map（binary 键）
%% @return 过滤后的 map | undefined（无有效字段时）
%% @end
%%--------------------------------------------------------------------
sanitizeLlmOverride(Llm) when is_map(Llm) ->
    Acc0 = #{},
    Acc1 = case maps:get(<<"provider">>, Llm, maps:get(provider, Llm, undefined)) of
        undefined -> Acc0;
        <<>> -> Acc0;
        P ->
            case toProviderAtom(P) of
                undefined -> Acc0;
                Atom -> Acc0#{provider => Atom}
            end
    end,
    Acc2 = case maps:get(<<"model">>, Llm, maps:get(model, Llm, undefined)) of
        M when is_binary(M), M =/= <<>> -> Acc1#{model => M};
        M when is_list(M), M =/= [] -> Acc1#{model => unicode:characters_to_binary(M)};
        M when is_atom(M), M =/= undefined -> Acc1#{model => atom_to_binary(M, utf8)};
        _ -> Acc1
    end,
    Acc3 = case maps:get(<<"apiKey">>, Llm, maps:get(apiKey, Llm, undefined)) of
        K when is_binary(K), K =/= <<>> -> Acc2#{apiKey => K};
        K when is_list(K), K =/= [] -> Acc2#{apiKey => unicode:characters_to_binary(K)};
        _ -> Acc2
    end,
    case maps:size(Acc3) of
        0 -> undefined;
        _ -> Acc3
    end;
sanitizeLlmOverride(_) ->
    undefined.

%% 合并 WS ask 请求体与会话级 llmOverride；请求字段优先（含 apiKey）。
mergeAskLlmOpts(Opts, Cmd, WebState) ->
    ReqOverride = case maps:get(<<"llm">>, Cmd, undefined) of
        Llm when is_map(Llm) -> sanitizeLlmOverride(Llm);
        _ -> undefined
    end,
    SessOverride = maps:get(llmOverride, WebState, undefined),
    case mergeLlmOverrides(SessOverride, ReqOverride) of
        undefined -> Opts;
        Merged -> Opts#{llmOverride => Merged}
    end.

mergeLlmOverrides(undefined, undefined) ->
    undefined;
mergeLlmOverrides(S, undefined) ->
    S;
mergeLlmOverrides(undefined, R) ->
    R;
mergeLlmOverrides(S, R) when is_map(S), is_map(R) ->
    maps:merge(S, R).

%% 将客户端 provider 转为 atom；未知/过长则拒绝，避免污染 atom 表。
toProviderAtom(P) when is_atom(P) -> P;
toProviderAtom(P) when is_binary(P), byte_size(P) > 0, byte_size(P) =< 64 ->
    try binary_to_existing_atom(P, utf8) of
        Atom -> Atom
    catch
        error:badarg ->
            %% 下拉列表里的厂商可能尚未成为 existing atom；白名单放行
            case lists:member(P, knownProviderBins()) of
                true -> binary_to_atom(P, utf8);
                false -> undefined
            end
    end;
toProviderAtom(P) when is_list(P) ->
    toProviderAtom(unicode:characters_to_binary(P));
toProviderAtom(_) ->
    undefined.

knownProviderBins() ->
    [<<"deepseek">>, <<"openai">>, <<"anthropic">>, <<"qwen">>, <<"dashscope">>,
     <<"glm">>, <<"zhipu">>, <<"ernie">>, <<"qianfan">>, <<"doubao">>,
     <<"kimi">>, <<"moonshot">>, <<"openrouter">>, <<"siliconflow">>, <<"oneapi">>,
     <<"ollama">>, <<"llamaCpp">>, <<"llamacpp">>, <<"vllm">>, <<"lmstudio">>,
     <<"gemini">>, <<"google">>].
