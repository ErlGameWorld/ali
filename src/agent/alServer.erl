%%%-------------------------------------------------------------------
%% @doc Agent 协调器：会话路由、模式、工作上下文与审批。
%% @end
%%%-------------------------------------------------------------------

-module(alServer).

-behaviour(gen_server).

-export([
    start_link/0,
    stop/0,
    ask/1, ask/2,
    askStream/1, askStream/2,
    askAsync/1, askAsync/2,
    approve/1,
    approve/2,
    dismiss/1,
    pendingTask/1,
    pendingList/0,
    status/0,
    sessions/0,
    clearSession/0, clearSession/1,
    saveSession/0, saveSession/1,
    loadSession/1,
    savedSessions/0,
    sessionMessages/1,
    cancelAsk/0, cancelAsk/1,
    cancelAskByTaskId/2,
    taskStatus/1,
    cancelTask/1,
    tasks/0,
    getConfig/0,
    setConfig/2,
    setSessionConfig/3,
    getSessionConfig/1,
    clearSessionConfig/2,
    getMode/0,
    setMode/1,
    getWorkingContext/0,
    addContext/2,
    clearContext/0,
    tools/0,
    ensureSessionWorker/1,
    restorePendingFromCheckpoints/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    runtimeOverrides = #{} :: map(),
    sessions = #{} :: #{term() => pid()},
    %% MonRef => SessionId：对每个 session worker 建立 monitor，
    %% worker DOWN 时据此清理 sessions 映射，避免残留死 Pid。
    monitors = #{} :: #{reference() => term()},
    defaultSession :: term() | undefined,
    mode = ask :: ask | edit | exec,
    workingContext = #{modules => [], files => [], processes => []} :: map(),
    sessionOverrides = #{} :: map()
}).

%% 默认（server）会话使用稳定 ID，避免 alServer 每次（重）启动都新建
%% 一个匿名会话，导致历史/上下文散落在无法再引用的孤儿会话中。
-define(DEFAULT_SESSION, <<"default">>).

-define(SERVER, ?MODULE).

%%--------------------------------------------------------------------
%% @doc
%% 启动 alServer gen_server 并注册为本地名 ?SERVER。
%%
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% @doc
%% 停止 alServer 进程；若进程不存在则直接返回 ok。
%%
%% @end
%%--------------------------------------------------------------------
stop() ->
    case whereis(?SERVER) of
        undefined -> ok;
        Pid -> gen_server:stop(Pid)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 同步向 Agent 提问（使用空选项）。
%%
%% @param Prompt 用户输入文本
%% @return {ok, Answer} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
ask(Prompt) -> ask(Prompt, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 同步向 Agent 提问，可携带选项（sessionId、mode、taskId 等）。
%% 调用会被阻塞直到 Agent 完成推理。
%%
%% @param Prompt 用户输入文本
%% @param Opts 选项 map
%% @return {ok, Answer} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
ask(Prompt, Opts) ->
    gen_server:call(?SERVER, {eAsk, toBinary(Prompt), Opts}, infinity).

%%--------------------------------------------------------------------
%% @doc
%% 流式提问（使用空选项），通过消息向调用进程推送流式 chunk。
%%
%% @param Prompt 用户输入文本
%% @return {ok, streaming} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
askStream(Prompt) -> askStream(Prompt, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 流式提问，Caller 用于接收 streamChunk 消息。
%%
%% @param Prompt 用户输入文本
%% @param Opts 选项 map
%% @param Caller 接收流式消息的进程
%% @return {ok, streaming} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
askStream(Prompt, Opts) ->
    gen_server:call(?SERVER, {eAskStream, toBinary(Prompt), Opts, self()}, infinity).

%%--------------------------------------------------------------------
%% @doc
%% 异步提问（使用空选项），立即返回 taskId，结果通过 task 系统查询。
%%
%% @param Prompt 用户输入文本
%% @return {ok, TaskId} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
askAsync(Prompt) -> askAsync(Prompt, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 异步提问，立即返回 TaskId，结果通过 taskStatus/1 或 tasks/0 查询。
%%
%% @param Prompt 用户输入文本
%% @param Opts 选项 map（需含 taskId）
%% @return {ok, TaskId} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
askAsync(Prompt, Opts) ->
    gen_server:call(?SERVER, {eAskAsync, toBinary(Prompt), Opts}).

%%--------------------------------------------------------------------
%% @doc
%% 批准待确认任务（如危险工具调用前需要审批）。
%%
%% @param TaskId 待批准任务 ID
%% @return {ok, Result} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
approve(TaskId) ->
    approve(TaskId, #{}).

%% ExtraOpts 可注入 streamCaller / progressId（WS 审批续跑流式）。
approve(TaskId, ExtraOpts) when is_map(ExtraOpts) ->
    gen_server:call(?SERVER, {eApprove, TaskId, ExtraOpts}, infinity).

%%--------------------------------------------------------------------
%% @doc
%% 驳回/忽略待确认任务。
%%
%% @param TaskId 待驳回任务 ID
%% @return ok | {error, Reason}
%% @end
%%--------------------------------------------------------------------
dismiss(TaskId) ->
    gen_server:call(?SERVER, {eDismiss, TaskId}).

%%--------------------------------------------------------------------
%% @doc
%% 查询单个待确认任务详情。
%%
%% @param TaskId 任务 ID
%% @return {ok, Task} | {error, notFound}
%% @end
%%--------------------------------------------------------------------
pendingTask(TaskId) ->
    gen_server:call(?SERVER, {ePendingTask, TaskId}).

%%--------------------------------------------------------------------
%% @doc
%% 列出所有待确认任务。
%%
%% @return [PendingTask]
%% @end
%%--------------------------------------------------------------------
pendingList() ->
    gen_server:call(?SERVER, pendingList).

%%--------------------------------------------------------------------
%% @doc
%% 获取 Agent 当前状态快照（模式、默认会话、会话数、工作上下文、配置）。
%%
%% @return 状态 map
%% @end
%%--------------------------------------------------------------------
status() ->
    gen_server:call(?SERVER, status).

%%--------------------------------------------------------------------
%% @doc
%% 列出所有会话 worker 的快照信息。
%%
%% @return #{SessionId => Snapshot}
%% @end
%%--------------------------------------------------------------------
sessions() ->
    gen_server:call(?SERVER, sessions).

%%--------------------------------------------------------------------
%% @doc
%% 清空默认会话的历史消息。
%%
%% @return ok | {error, Reason}
%% @end
%%--------------------------------------------------------------------
clearSession() ->
    gen_server:call(?SERVER, clearSession).

%%--------------------------------------------------------------------
%% @doc
%% 清空指定会话的历史消息。
%%
%% @param SessionId 会话 ID
%% @return ok | {error, Reason}
%% @end
%%--------------------------------------------------------------------
clearSession(SessionId) ->
    gen_server:call(?SERVER, {eClearSession, SessionId}).

%%--------------------------------------------------------------------
%% @doc
%% 持久化保存默认会话到磁盘。
%%
%% @return {ok, Path} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
saveSession() ->
    gen_server:call(?SERVER, saveSession).

%%--------------------------------------------------------------------
%% @doc
%% 持久化保存指定会话到磁盘。
%%
%% @param SessionId 会话 ID
%% @return {ok, Path} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
saveSession(SessionId) ->
    gen_server:call(?SERVER, {eSaveSession, SessionId}).

%%--------------------------------------------------------------------
%% @doc
%% 从磁盘加载历史会话，并将其设为默认会话。
%%
%% @param SessionId 会话 ID
%% @return {ok, LoadedId} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
loadSession(SessionId) ->
    gen_server:call(?SERVER, {eLoadSession, SessionId}).

%%--------------------------------------------------------------------
%% @doc
%% 列出所有已保存到磁盘的会话。
%%
%% @return [SavedSession]
%% @end
%%--------------------------------------------------------------------
savedSessions() ->
    gen_server:call(?SERVER, savedSessions).

%%--------------------------------------------------------------------
%% @doc
%% 获取指定会话的消息列表（优先从 worker 取，回退到 sessionMgr）。
%%
%% @param SessionId 会话 ID
%% @return {ok, [Msg]} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
sessionMessages(SessionId) ->
    gen_server:call(?SERVER, {eSessionMessages, SessionId}).

%%--------------------------------------------------------------------
%% @doc
%% 取消所有会话中正在进行的问答。
%%
%% @return #{ok => true, cancelled => Count}
%% @end
%%--------------------------------------------------------------------
cancelAsk() ->
    gen_server:call(?SERVER, cancelAsk).

%%--------------------------------------------------------------------
%% @doc
%% 取消指定会话中正在进行的问答。
%%
%% @param SessionId 会话 ID
%% @return #{ok => true, cancelled => Count}
%% @end
%%--------------------------------------------------------------------
cancelAsk(SessionId) ->
    gen_server:call(?SERVER, {eCancelAsk, SessionId}).

%%--------------------------------------------------------------------
%% @doc
%% 取消指定会话中指定 taskId 的问答（供 SSE 断连等场景精确取消）。
%%
%% @param SessionId 会话 ID
%% @param TaskId    任务 ID
%% @return ok | {error, notFound} | #{ok => false, error => noSession}
%% @end
%%--------------------------------------------------------------------
cancelAskByTaskId(SessionId, TaskId) ->
    gen_server:call(?SERVER, {eCancelAskByTaskId, SessionId, TaskId}).

%%--------------------------------------------------------------------
%% @doc
%% 查询异步任务状态。
%%
%% @param TaskId 任务 ID
%% @return {ok, Task} | {error, notFound}
%% @end
%%--------------------------------------------------------------------
taskStatus(TaskId) ->
    alTask:status(TaskId).

%%--------------------------------------------------------------------
%% @doc
%% 取消异步任务：先通知对应 session worker 取消，再调用 alTask:cancel。
%%
%% @param TaskId 任务 ID
%% @return ok | {error, notFound}
%% @end
%%--------------------------------------------------------------------
cancelTask(TaskId) ->
    case alTask:status(TaskId) of
        {ok, #{sessionId := SessionId}} ->
            _ = gen_server:call(?SERVER, {eCancelTask, SessionId, TaskId}),
            alTask:cancel(TaskId);
        {error, notFound} ->
            {error, notFound}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 列出所有异步任务。
%%
%% @return [Task]
%% @end
%%--------------------------------------------------------------------
tasks() ->
    alTask:list().

%%--------------------------------------------------------------------
%% @doc
%% 获取当前生效的 Agent 配置（合并配置文件与运行时覆盖）。
%%
%% @return 配置 map
%% @end
%%--------------------------------------------------------------------
getConfig() ->
    gen_server:call(?SERVER, getConfig).

%%--------------------------------------------------------------------
%% @doc
%% 设置运行时配置项（覆盖配置文件中的同名键），特殊处理 mode 键。
%%
%% @param Key 配置键
%% @param Value 配置值
%% @return ok
%% @end
%%--------------------------------------------------------------------
setConfig(Key, Value) ->
    gen_server:call(?SERVER, {eSetConfig, Key, Value}).

%%--------------------------------------------------------------------
%% @doc
%% 为指定会话设置覆盖配置项。
%%
%% @param SessionId 会话 ID
%% @param Key 配置键
%% @param Value 配置值
%% @return ok
%% @end
%%--------------------------------------------------------------------
setSessionConfig(SessionId, Key, Value) ->
    gen_server:call(?SERVER, {eSetSessionConfig, SessionId, Key, Value}).

%%--------------------------------------------------------------------
%% @doc
%% 获取指定会话的覆盖配置 map。
%%
%% @param SessionId 会话 ID
%% @return 配置 map
%% @end
%%--------------------------------------------------------------------
getSessionConfig(SessionId) ->
    gen_server:call(?SERVER, {eGetSessionConfig, SessionId}).

%%--------------------------------------------------------------------
%% @doc
%% 清除指定会话的某个覆盖配置项。
%%
%% @param SessionId 会话 ID
%% @param Key 配置键
%% @return ok
%% @end
%%--------------------------------------------------------------------
clearSessionConfig(SessionId, Key) ->
    gen_server:call(?SERVER, {eClearSessionConfig, SessionId, Key}).

%%--------------------------------------------------------------------
%% @doc
%% 获取当前运行模式（ask | edit | exec）。
%%
%% @return Mode
%% @end
%%--------------------------------------------------------------------
getMode() ->
    gen_server:call(?SERVER, getMode).

%%--------------------------------------------------------------------
%% @doc
%% 设置运行模式，并广播到所有已存在的会话 worker。
%%
%% @param Mode ask | edit | exec
%% @return ok | {error, invalidMode}
%% @end
%%--------------------------------------------------------------------
setMode(Mode) ->
    gen_server:call(?SERVER, {eSetMode, Mode}).

%%--------------------------------------------------------------------
%% @doc
%% 获取当前工作上下文（modules / files / processes）。
%%
%% @return 工作上下文 map
%% @end
%%--------------------------------------------------------------------
getWorkingContext() ->
    gen_server:call(?SERVER, getWorkingContext).

%%--------------------------------------------------------------------
%% @doc
%% 向工作上下文添加一项（去重后排序）。
%%
%% @param Type 类型（module / file / process 等）
%% @param Value 值
%% @return ok
%% @end
%%--------------------------------------------------------------------
addContext(Type, Value) ->
    gen_server:call(?SERVER, {eAddContext, Type, Value}).

%%--------------------------------------------------------------------
%% @doc
%% 清空工作上下文（保留空键）。
%%
%% @return ok
%% @end
%%--------------------------------------------------------------------
clearContext() ->
    gen_server:call(?SERVER, clearContext).

%%--------------------------------------------------------------------
%% @doc
%% 列出工具目录中所有可用工具。
%%
%% @return [Tool]
%% @end
%%--------------------------------------------------------------------
tools() ->
    alToolCatalog:allTools().

%%--------------------------------------------------------------------
%% @doc
%% 确保指定会话的 worker 已启动（用于 web 会话等场景）。
%%
%% @param SessionId 会话 ID
%% @return {ok, WorkerPid}
%% @end
%%--------------------------------------------------------------------
ensureSessionWorker(SessionId) ->
    gen_server:call(?SERVER, {eEnsureSessionWorker, SessionId}).

%%--------------------------------------------------------------------
%% @doc
%% gen_server 初始化：启动各依赖服务，创建默认 server 会话与 web 会话，
%% 从配置读取初始模式。
%%
%% @end
%%--------------------------------------------------------------------
init([]) ->
    process_flag(trap_exit, true),
    _ = alAudit:ensureStarted(),
    _ = alTask:ensureStarted(),
    _ = alMetrics:ensureStarted(),
    _ = alProgress:ensureStarted(),
    _ = alPending:ensureStarted(),
    _ = alMcpClient:ensureStarted(),
    %% 复用稳定的默认会话：存在则加载，不存在才创建。重启后接续同一会话。
    {ok, SessionId} = alSessionMgr:ensureSession(?DEFAULT_SESSION, server),
    {ok, _} = alSessionMgr:ensureSession(<<"web">>, web),
    Mode = maps:get(mode, alConfig:get(agent, #{}), ask),
    %% G4：启动时扫描未完成的 checkpoint / pending 审批，记录可恢复项数量，
    %% 供运维/UI 感知（不自动续跑，避免危险的自动执行）。
    logRecoverable(),
    %% G5：把仍有 pendingCall 的 checkpoint 补回 pending 表（覆盖 pending 文件
    %% 因 TTL 过期 / 崩溃窗口丢失的场景），重启后待审批任务不丢失、可继续审批。
    restorePendingFromCheckpoints(),
    {ok, #state{
        defaultSession = SessionId,
        mode = normalizeMode(Mode),
        sessions = #{}
    }}.

%% 统计并记录启动时的可恢复任务与待审批数量。
logRecoverable() ->
    #{recoverableTasks := Recoverable, pendingApprovals := Pending} = recoverableCounts(),
    case Recoverable > 0 orelse Pending > 0 of
        true ->
            logger:info("alServer: ~p recoverable checkpoint(s), ~p pending approval(s) "
                        "found at startup (use ali:listCheckpoints/0 and ali:pendingList/0)",
                        [Recoverable, Pending]);
        false ->
            ok
    end.

%% 计算可恢复任务数（checkpoint）与待审批数（pending），任一来源异常时降级为 0。
recoverableCounts() ->
    Recoverable = try length(alCheckpoint:list()) catch _:_ -> 0 end,
    Pending = try length(alPending:list()) catch _:_ -> 0 end,
    #{recoverableTasks => Recoverable, pendingApprovals => Pending}.

%%--------------------------------------------------------------------
%% @doc
%% 重启恢复：扫描 checkpoint 目录，凡仍带 pendingCall（等待审批）且
%% pending 表中已无对应条目（TTL 过期 / 崩溃窗口丢失）的任务，
%% 重新登记为 pending 并挂回续跑上下文。仅登记、不执行，用户审批后才续跑，
%% 避免重启后自动执行写工具。可重复调用，幂等。
%%
%% @return ok
%% @end
%%--------------------------------------------------------------------
restorePendingFromCheckpoints() ->
    Restored = lists:foldl(fun(TaskId, Acc) ->
        case restorePendingFromCheckpoint(TaskId) of
            ok -> Acc + 1;
            skip -> Acc
        end
    end, 0, safeCheckpointList()),
    case Restored of
        0 -> ok;
        N -> logger:info("alServer: restored ~p pending approval task(s) from checkpoints", [N])
    end.

%% checkpoint 列表异常时降级为空。
safeCheckpointList() ->
    try alCheckpoint:list() catch _:_ -> [] end.

%% 单个 checkpoint 的恢复尝试：成功返回 ok，跳过返回 skip。
restorePendingFromCheckpoint(TaskId) ->
    try alCheckpoint:load(TaskId) of
        {ok, #{pendingCall := #{function := #{name := Name, arguments := Args}} = _Call} = Cont} ->
            case alPending:get(toBinary(TaskId)) of
                {error, notFound} -> doRestorePending(TaskId, Name, Args, Cont);
                {error, expired} -> doRestorePending(TaskId, Name, Args, Cont);
                _ -> skip
            end;
        _ ->
            skip
    catch
        _:_ -> skip
    end.

%% 用 checkpoint 里的 pendingCall 重建 pending 条目并挂续接。
doRestorePending(TaskId, Name, Args, Cont) ->
    Tool = alLlmTools:toolAtom(Name),
    case {is_atom(Tool), alLlmTools:decodeArgs(Args)} of
        {true, {ok, Decoded}} ->
            Opts = maps:get(opts, Cont, #{}),
            SessionId = maps:get(sessionId, Opts, undefined),
            BinId = toBinary(TaskId),
            case alPending:put(BinId, SessionId, Tool, Decoded, Opts) of
                {ok, _} ->
                    case alPending:attachContinuation(BinId, Cont) of
                        ok -> ok;
                        _ -> skip
                    end;
                _ -> skip
            end;
        _ ->
            skip
    end.

%%--------------------------------------------------------------------
%% @doc
%% 处理同步 ask 请求：解析会话、确保 worker 存在、计算生效选项后转发给 worker。
%%
%% @param {eAsk, Prompt, Opts} 请求元组
%% @param From gen_server 调用者标签
%% @param State 当前状态
%% @return {noreply, NewState}
%% @end
%%--------------------------------------------------------------------
handle_call({eAsk, Prompt, Opts}, From, State) ->
    {SessionId, Opts1, State1} = resolveSession(Opts, State),
    case ensureWorker(SessionId, State1) of
        {error, workerStartFailed} ->
            {reply, {error, workerStartFailed}, State1};
        {Worker, State2} ->
            Effective = effectiveOpts(SessionId, Opts1, State2),
            alSessionWorker:ask(Worker, From, Prompt, Effective),
            {noreply, State2}
    end;

%%--------------------------------------------------------------------
%% @doc
%% 处理流式 ask 请求：在新进程中执行 runStream，向 Caller 推送 chunk，
%% 失败时通过 gen_server:reply 回复错误。
%%
%% @end
%%--------------------------------------------------------------------
%% Stream asks share the session worker + full agent/tool loop. Reply
%% immediately with `{ok, streaming}`; token/progress/answer events go to Caller.
handle_call({eAskStream, Prompt, Opts, Caller}, _From, State) ->
    {SessionId, Opts1, State1} = resolveSession(Opts, State),
    Effective0 = effectiveOpts(SessionId, Opts1, State1),
    TaskId = case maps:get(taskId, Effective0, undefined) of
        undefined -> integer_to_binary(erlang:unique_integer([positive, monotonic]));
        T -> toBinary(T)
    end,
    Effective = Effective0#{
        streamCaller => Caller,
        taskId => TaskId,
        progressId => maps:get(progressId, Effective0, TaskId)
    },
    case ensureWorker(SessionId, State1) of
        {error, workerStartFailed} ->
            {reply, {error, workerStartFailed}, State1};
        {Worker, State2} ->
            %% spawn_monitor 而非裸 spawn：helper 崩溃时 alServer 收到 DOWN（在
            %% handle_info 中被识别为非会话 monitor 而忽略），不会泄漏为未处理消息。
            spawn_monitor(fun() ->
                Tag = make_ref(),
                StreamFrom = {self(), Tag},
                ProgressPid = spawn(fun() -> forwardStreamProgress(Caller, TaskId) end),
                alSessionWorker:ask(Worker, StreamFrom, Prompt, Effective),
                receive
                    {Tag, Result} ->
                        ProgressPid ! eStop,
                        case Result of
                            {ok, Res} ->
                                Answer = maps:get(answer, Res, Res),
                                Text = case Answer of
                                    B when is_binary(B) -> B;
                                    M when is_map(M) ->
                                        maps:get(content, M, unicode:characters_to_binary(alJson:encode(M)));
                                    Other -> unicode:characters_to_binary(io_lib:format("~p", [Other]))
                                end,
                                Caller ! {eStreamDone, Text},
                                Caller ! {eStreamAnswer, Result};
                            {error, Reason} ->
                                Caller ! {eStreamError, Reason}
                        end
                after 1800000 ->
                    ProgressPid ! eStop,
                    Caller ! {eStreamError, agentTimeout}
                end
            end),
            {reply, {ok, streaming}, State2}
    end;

%%--------------------------------------------------------------------
%% @doc
%% 处理异步 ask 请求：构造 Runner 闭包并通过 alTask 启动后台任务，
%% 立即返回 TaskId。
%%
%% @end
%%--------------------------------------------------------------------
handle_call({eAskAsync, Prompt, Opts}, _From, State) ->
    Server = self(),
    {SessionId, Opts1, State1} = resolveSession(Opts, State),
    Runner = fun(P, O) ->
        Tid = maps:get(taskId, O),
        ProgressOpts = maps:put(progressId, Tid, maps:remove(taskId, O)),
        try gen_server:call(Server, {eAsk, P, ProgressOpts#{sessionId => SessionId}}, 1800000) of
            {ok, Ans} -> {{ok, Ans}, #{}};
            {error, Err} -> {{error, Err}, #{}}
        catch
            _:Reason -> {{error, #{reason => serverCallFailed, detail => Reason}}, #{}}
        end
    end,
    case alTask:spawnAsk(Prompt, Opts1#{sessionId => SessionId}, Runner) of
        {ok, TaskId} ->
            {reply, {ok, TaskId}, State1};
        {error, Reason} ->
            {reply, {error, Reason}, State1}
    end;

%% Route approval back through the owning session worker. This keeps the
%% global coordinator responsive while the approved tool and continuation run.
handle_call({eApprove, TaskId}, From, State) ->
    handle_call({eApprove, TaskId, #{}}, From, State);
handle_call({eApprove, TaskId, ExtraOpts}, From, State) when is_map(ExtraOpts) ->
    case alPending:get(TaskId) of
        {ok, Entry} ->
            SessionId = maps:get(sessionId, Entry, undefined),
            case ensureWorker(SessionId, State) of
                {error, workerStartFailed} ->
                    {reply, {error, workerStartFailed}, State};
                {Worker, State1} ->
                    alSessionWorker:approve(Worker, From, TaskId, ExtraOpts),
                    {noreply, State1}
            end;
        {error, _} = Error ->
            {reply, Error, State}
    end;

%% 处理 dismiss 请求，转发给 alPending。
handle_call({eDismiss, TaskId}, _From, State) ->
    {reply, alPending:dismiss(TaskId), State};

%% 处理 pendingTask 请求，转发给 alPending。
handle_call({ePendingTask, TaskId}, _From, State) ->
    {reply, alPending:get(TaskId), State};

%% 处理 pendingList 请求，转发给 alPending。
handle_call(pendingList, _From, State) ->
    {reply, alPending:list(), State};

%%--------------------------------------------------------------------
%% @doc
%% 处理 cancelTask 请求：通过会话 worker 按 taskId 取消指定任务。
%%
%% @end
%%--------------------------------------------------------------------
handle_call({eCancelTask, SessionId, TaskId}, _From, State) ->
    Reply = case workerFor(SessionId, State) of
        {ok, Pid} -> alSessionWorker:cancelByTaskId(Pid, TaskId);
        error -> {error, sessionNotFound}
    end,
    {reply, Reply, State};

%%--------------------------------------------------------------------
%% @doc
%% 处理 status 请求，返回模式、默认会话、会话数、工作上下文、生效配置等快照。
%%
%% @end
%%--------------------------------------------------------------------
handle_call(status, _From, State) ->
    #{recoverableTasks := Recoverable, pendingApprovals := Pending} = recoverableCounts(),
    {reply, #{
        mode => State#state.mode,
        defaultSession => State#state.defaultSession,
        sessionCount => maps:size(State#state.sessions),
        workingContext => State#state.workingContext,
        recoverableTasks => Recoverable,
        pendingApprovals => Pending,
        config => effectiveAgentCfg(State)
    }, State};

%%--------------------------------------------------------------------
%% @doc
%% 处理 sessions 请求，对每个会话 worker 调用 snapshot 并返回结果 map。
%%
%% @end
%%--------------------------------------------------------------------
handle_call(sessions, _From, State) ->
    %% 逐 worker 快照采用短超时 + catch：单个阻塞/慢 worker 不应把
    %% alServer 协调进程一起拖垮（默认 gen_server:call 超时会阻塞 5s）。
    Snap = maps:map(fun(_Id, Pid) -> safeSnapshot(Pid) end, State#state.sessions),
    {reply, Snap, State};

%% 处理 clearSession 请求（默认会话）：清空 worker 的会话历史。
handle_call(clearSession, _From, State) ->
    Sid = State#state.defaultSession,
    {Reply, NewState} = clearWorkerSession(Sid, State),
    {reply, Reply, NewState};

%% 处理 {eClearSession, SessionId} 请求：清空指定 worker 的会话历史。
handle_call({eClearSession, SessionId}, _From, State) ->
    {Reply, NewState} = clearWorkerSession(SessionId, State),
    {reply, Reply, NewState};

%% 处理 saveSession 请求（默认会话）：转发给 alSessionMgr 持久化。
handle_call(saveSession, _From, State) ->
    {reply, alSessionMgr:saveSession(State#state.defaultSession), State};

%% 处理 {eSaveSession, SessionId} 请求：转发给 alSessionMgr 持久化。
handle_call({eSaveSession, SessionId}, _From, State) ->
    {reply, alSessionMgr:saveSession(SessionId), State};

%%--------------------------------------------------------------------
%% @doc
%% 处理 loadSession 请求：从磁盘加载会话，并将其设为默认会话。
%%
%% @end
%%--------------------------------------------------------------------
handle_call({eLoadSession, SessionId}, _From, State) ->
    case alSessionMgr:loadSessionFile(SessionId) of
        {ok, Id} ->
            {reply, {ok, Id}, State#state{defaultSession = Id}};
        {error, _} = E ->
            {reply, E, State}
    end;

%% 处理 savedSessions 请求：列出磁盘上已保存的会话。
handle_call(savedSessions, _From, State) ->
    {reply, alSessionMgr:listSavedSessions(), State};

%%--------------------------------------------------------------------
%% @doc
%% 处理 sessionMessages 请求：优先从 worker 取消息，否则回退到 sessionMgr。
%%
%% @end
%%--------------------------------------------------------------------
handle_call({eSessionMessages, SessionId}, _From, State) ->
    case workerFor(SessionId, State) of
        {ok, Pid} -> {reply, alSessionWorker:sessionMessages(Pid), State};
        error -> {reply, alSessionMgr:getContext(SessionId), State}
    end;

%%--------------------------------------------------------------------
%% @doc
%% 处理 cancelAsk 请求（所有会话）：汇总各 worker 的取消数量。
%%
%% @end
%%--------------------------------------------------------------------
handle_call(cancelAsk, _From, State) ->
    %% 只对存活 worker 发 call；死 Pid（DOWN 尚未处理）跳过，避免 noproc 崩溃。
    Total = lists:sum([safeCancelAsk(Pid) || Pid <- maps:values(State#state.sessions)]),
    {reply, #{ok => true, cancelled => Total}, State};

%%--------------------------------------------------------------------
%% @doc
%% 处理 {eCancelAsk, SessionId} 请求：取消指定会话的所有进行中问答。
%%
%% @end
%%--------------------------------------------------------------------
handle_call({eCancelAsk, SessionId}, _From, State) ->
    Reply = case workerFor(SessionId, State) of
        {ok, Pid} -> alSessionWorker:cancelAsk(Pid, all);
        error -> #{ok => true, cancelled => 0}
    end,
    {reply, Reply, State};

%%--------------------------------------------------------------------
%% @doc
%% 处理 {eCancelAskByTaskId, SessionId, TaskId} 请求：按会话+taskId 精确取消，
%% 供 SSE 断连时只取消本任务（绝不全局取消）。
%%
%% @end
%%--------------------------------------------------------------------
handle_call({eCancelAskByTaskId, SessionId, TaskId}, _From, State) ->
    Reply = case workerFor(SessionId, State) of
        {ok, Pid} -> alSessionWorker:cancelByTaskId(Pid, TaskId);
        error -> #{ok => false, error => noSession}
    end,
    {reply, Reply, State};

%% 处理 getConfig 请求：返回生效配置。
handle_call(getConfig, _From, State) ->
    {reply, effectiveAgentCfg(State), State};

%%--------------------------------------------------------------------
%% @doc
%% 处理 {eSetConfig, Key, Value} 请求：写入运行时覆盖；若 Key 为 mode 则同步切换状态。
%%
%% @end
%%--------------------------------------------------------------------
handle_call({eSetConfig, Key, Value}, _From, State) ->
    Overrides = maps:put(Key, Value, State#state.runtimeOverrides),
    NewState = case Key of
        mode -> State#state{runtimeOverrides = Overrides, mode = normalizeMode(Value)};
        _ -> State#state{runtimeOverrides = Overrides}
    end,
    {reply, ok, NewState};

%% 处理 getMode 请求：返回当前模式。
handle_call(getMode, _From, State) ->
    {reply, State#state.mode, State};

%%--------------------------------------------------------------------
%% @doc
%% 处理 {eSetMode, Mode} 请求：校验模式合法性后写入覆盖并广播到所有 worker。
%%
%% @end
%%--------------------------------------------------------------------
handle_call({eSetMode, Mode}, _From, State) ->
    case normalizeMode(Mode) of
        badMode -> {reply, {error, invalidMode}, State};
        Valid ->
            Overrides = maps:put(mode, Valid, State#state.runtimeOverrides),
            lists:foreach(
                fun(Pid) -> alSessionWorker:setMode(Pid, Valid) end,
                maps:values(State#state.sessions)
            ),
            {reply, ok, State#state{mode = Valid, runtimeOverrides = Overrides}}
    end;

%%--------------------------------------------------------------------
%% @doc
%% 处理 {eSetSessionConfig, SessionId, Key, Value} 请求：更新会话级覆盖。
%%
%% @end
%%--------------------------------------------------------------------
handle_call({eSetSessionConfig, SessionId, Key, Value}, _From, State) ->
    Ov = maps:get(SessionId, State#state.sessionOverrides, #{}),
    {reply, ok, State#state{sessionOverrides = maps:put(SessionId, maps:put(Key, Value, Ov), State#state.sessionOverrides)}};

%% 处理 {eGetSessionConfig, SessionId} 请求：返回该会话的覆盖 map。
handle_call({eGetSessionConfig, SessionId}, _From, State) ->
    {reply, maps:get(SessionId, State#state.sessionOverrides, #{}), State};

%%--------------------------------------------------------------------
%% @doc
%% 处理 {eClearSessionConfig, SessionId, Key} 请求：清除会话级某个覆盖项；
%% 若该会话覆盖已空则整体移除。
%%
%% @end
%%--------------------------------------------------------------------
handle_call({eClearSessionConfig, SessionId, Key}, _From, State) ->
    Ov0 = maps:get(SessionId, State#state.sessionOverrides, #{}),
    Ov1 = maps:remove(Key, Ov0),
    SessOv = case map_size(Ov1) of
        0 -> maps:remove(SessionId, State#state.sessionOverrides);
        _ -> maps:put(SessionId, Ov1, State#state.sessionOverrides)
    end,
    {reply, ok, State#state{sessionOverrides = SessOv}};

%% 处理 getWorkingContext 请求：返回当前工作上下文。
handle_call(getWorkingContext, _From, State) ->
    {reply, State#state.workingContext, State};

%%--------------------------------------------------------------------
%% @doc
%% 处理 {eAddContext, Type, Value} 请求：将值加入对应上下文列表（去重排序）。
%%
%% @end
%%--------------------------------------------------------------------
handle_call({eAddContext, Type, Value}, _From, State) ->
    Key = contextKey(Type),
    List = maps:get(Key, State#state.workingContext, []),
    Ctx = maps:put(Key, lists:usort([Value | List]), State#state.workingContext),
    {reply, ok, State#state{workingContext = Ctx}};

%% 处理 clearContext 请求：重置工作上下文为空。
handle_call(clearContext, _From, State) ->
    {reply, ok, State#state{workingContext = #{modules => [], files => [], processes => []}}};

%%--------------------------------------------------------------------
%% @doc
%% 处理 {eEnsureSessionWorker, SessionId} 请求：在 sessionMgr 中登记 web 会话
%% 并确保对应 worker 已启动。
%%
%% @end
%%--------------------------------------------------------------------
handle_call({eEnsureSessionWorker, SessionId}, _From, State) ->
    _ = alSessionMgr:ensureSession(SessionId, web),
    case ensureWorker(SessionId, State) of
        {error, workerStartFailed} ->
            {reply, {error, workerStartFailed}, State};
        {Worker, State1} ->
            {reply, {ok, Worker}, State1}
    end;

%% 兜底处理未知 call 请求，返回 badRequest。
handle_call(_Req, _From, State) ->
    {reply, {error, badRequest}, State}.

%% 兜底处理未知 cast，保持状态不变。
handle_cast(_Msg, State) ->
    {noreply, State}.

%% 接收 alTask 完成通知：记录日志（结果已在 ETS 中，可通过 taskStatus 查询）。
handle_info({eAliTask, TaskId, Result}, State) ->
    case Result of
        {ok, _} -> logger:info("alServer async task ~s completed", [TaskId]);
        {error, cancelled} -> logger:info("alServer async task ~s cancelled", [TaskId]);
        {error, Reason} -> logger:warning("alServer async task ~s failed: ~p", [TaskId, Reason])
    end,
    {noreply, State};
%% session worker DOWN 时清理 sessions 映射，防止后续调用使用死 Pid。
%% session worker 由 alSessionSup 监管（与其链接），并不与 alServer 链接，
%% 因此这里用 monitor（而非 trap_exit）跟踪其生命周期。未登记在 monitors
%% 中的 DOWN（例如 eAskStream 的 helper 进程）直接忽略。
handle_info({'DOWN', MonRef, process, Pid, Reason}, State) ->
    case maps:take(MonRef, State#state.monitors) of
        {SessionId, Monitors1} ->
            Sessions1 = case maps:get(SessionId, State#state.sessions, undefined) of
                Pid -> maps:remove(SessionId, State#state.sessions);
                _ -> State#state.sessions
            end,
            logger:warning("alServer session worker ~w (~p) down: ~p",
                           [Pid, SessionId, Reason]),
            {noreply, State#state{sessions = Sessions1, monitors = Monitors1}};
        error ->
            {noreply, State}
    end;
%% 兜底处理未知 info 消息，保持状态不变。
handle_info(_Info, State) ->
    {noreply, State}.

%% gen_server 终止回调，当前无需清理。
terminate(_Reason, _State) ->
    ok.

%% 热代码升级回调，直接保留原状态。
code_change(_Old, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% @doc
%% 解析选项中的会话 ID：若未指定则使用默认会话，并回写 sessionId 到选项。
%%
%% @end
%%--------------------------------------------------------------------
resolveSession(Opts, State) ->
    SessionId = maps:get(sessionId, Opts, State#state.defaultSession),
    {SessionId, Opts#{sessionId => SessionId}, State}.

%%--------------------------------------------------------------------
%% @doc
%% 确保指定会话的 worker 已存在且存活；若已死亡或不存在则启动新 worker。
%%
%% @end
%%--------------------------------------------------------------------
ensureWorker(SessionId, State) ->
    case maps:get(SessionId, State#state.sessions, undefined) of
        Pid when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true -> {Pid, State};
                false -> startWorker(SessionId, State)
            end;
        _ ->
            startWorker(SessionId, State)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 启动新的 session worker 进程，传入当前模式，并将其登记到 sessions map。
%%
%% @end
%%--------------------------------------------------------------------
startWorker(SessionId, State) ->
    InitOpts = #{mode => State#state.mode},
    case alSessionSup:ensure_worker(SessionId, InitOpts) of
        {ok, Pid} ->
            MonRef = erlang:monitor(process, Pid),
            {Pid, State#state{
                sessions = maps:put(SessionId, Pid, State#state.sessions),
                monitors = maps:put(MonRef, SessionId, State#state.monitors)
            }};
        {error, Reason} ->
            logger:error("[alServer] startWorker failed for session ~p: ~p",
                         [SessionId, Reason]),
            {error, workerStartFailed}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 查找会话 worker：返回 {ok, Pid} 或 error。
%%
%% @end
%%--------------------------------------------------------------------
workerFor(SessionId, State) ->
    case maps:get(SessionId, State#state.sessions, undefined) of
        Pid when is_pid(Pid) ->
            %% 复用 ensureWorker 的存活性判断：DOWN 可能尚未处理完，
            %% sessions 中仍残留死 Pid，此处显式过滤避免向死进程发调用。
            case is_process_alive(Pid) of
                true -> {ok, Pid};
                false -> error
            end;
        _ -> error
    end.

%%--------------------------------------------------------------------
%% @doc
%% 安全获取单个 worker 快照：先判存活，再以短超时调用；任何异常
%% （超时/退出）都降级为占位快照，避免阻塞或崩溃 alServer。
%%
%% @end
%%--------------------------------------------------------------------
safeSnapshot(Pid) ->
    case is_pid(Pid) andalso is_process_alive(Pid) of
        true ->
            try gen_server:call(Pid, snapshot, 500)
            catch _:_ -> #{unavailable => true} end;
        false ->
            #{unavailable => true}
    end.

%% 安全取消：死 Pid / call 异常一律计 0，不让全局 cancelAsk 崩溃。
safeCancelAsk(Pid) ->
    case is_pid(Pid) andalso is_process_alive(Pid) of
        true ->
            try maps:get(cancelled, alSessionWorker:cancelAsk(Pid, all), 0)
            catch _:_ -> 0 end;
        false ->
            0
    end.

%%--------------------------------------------------------------------
%% @doc
%% 清空指定会话历史：若有 worker 则委托；否则直接清空 sessionMgr 中的消息。
%%
%% @end
%%--------------------------------------------------------------------
clearWorkerSession(SessionId, State) ->
    case workerFor(SessionId, State) of
        {ok, Pid} ->
            R = alSessionWorker:clearSession(Pid),
            {R, State};
        error ->
            _ = alSessionMgr:clearMessages(SessionId),
            {ok, State}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 计算传给 worker 的生效选项：合并 agent 配置、会话覆盖、模式、策略、工作上下文
%% 及 progressId（取 progressId 或 taskId）。
%%
%% @end
%%--------------------------------------------------------------------
effectiveOpts(SessionId, Opts0, State) ->
    AgentCfg = effectiveAgentCfg(State),
    SessOv = maps:get(SessionId, State#state.sessionOverrides, #{}),
    %% 信任边界：从请求 Opts 中剔除 mode / confirmed，防止 LLM 或外部调用者
    %% 借请求参数越权提权。mode 仅由会话覆盖与服务端状态决定；confirmed
    %% 只能由内部审批路径（alPending:claimApprove）注入。
    Opts = maps:without([mode, confirmed], Opts0),
    Mode = maps:get(mode, SessOv, State#state.mode),
    Opts#{
        sessionId => SessionId,
        mode => Mode,
        policy => maps:get(policy, AgentCfg, alPolicy:defaultPolicy()),
        agentCfg => AgentCfg,
        workingContext => State#state.workingContext,
        progressId => maps:get(progressId, Opts, maps:get(taskId, Opts, undefined))
    }.

%%--------------------------------------------------------------------
%% @doc
%% 计算生效的 Agent 配置：以配置文件为基础，叠加运行时覆盖。
%%
%% @end
%%--------------------------------------------------------------------
effectiveAgentCfg(State) ->
    Base = alConfig:getAgentCfg(),
    maps:merge(Base, State#state.runtimeOverrides).

%% Forward progress events as SSE-compatible stream messages until stopped.
%% Prefer push via alProgress:subscribe/1; fall back to short poll if idle.
forwardStreamProgress(Caller, TaskId) ->
    alProgress:subscribe(TaskId),
    Snap = alProgress:snapshot(TaskId, 0),
    lists:foreach(fun(Ev) ->
        Caller ! {eStreamProgress, Ev}
    end, maps:get(events, Snap, [])),
    Since0 = maps:get(eventCount, Snap, 0),
    forwardStreamProgressLoop(Caller, TaskId, Since0).

forwardStreamProgressLoop(Caller, TaskId, Since) ->
    receive
        eStop ->
            alProgress:unsubscribe(TaskId),
            ok;
        {eProgressEvent, _Bin, Ev} when is_map(Ev) ->
            case process_info(Caller) of
                undefined ->
                    alProgress:unsubscribe(TaskId),
                    ok;
                _ ->
                    Index = maps:get(index, Ev, Since),
                    case Index >= Since orelse maps:get(type, Ev, undefined) =:= finished of
                        true -> Caller ! {eStreamProgress, Ev};
                        false -> ok
                    end,
                    NewSince = case maps:get(index, Ev, undefined) of
                        I when is_integer(I) -> max(Since, I + 1);
                        _ -> Since
                    end,
                    case maps:get(type, Ev, undefined) of
                        finished ->
                            alProgress:unsubscribe(TaskId),
                            ok;
                        _ ->
                            case maps:get(status, alProgress:snapshot(TaskId, NewSince), running) of
                                running ->
                                    forwardStreamProgressLoop(Caller, TaskId, NewSince);
                                _ ->
                                    alProgress:unsubscribe(TaskId),
                                    ok
                            end
                    end
            end
    after 2000 ->
        %% 兜底：推送漏事件时短轮询补齐（远低于原先 100ms）。
        case process_info(Caller) of
            undefined ->
                alProgress:unsubscribe(TaskId),
                ok;
            _ ->
                Snap = alProgress:snapshot(TaskId, Since),
                lists:foreach(fun(Ev) ->
                    Caller ! {eStreamProgress, Ev}
                end, maps:get(events, Snap, [])),
                Count = maps:get(eventCount, Snap, Since),
                case maps:get(status, Snap, running) of
                    running -> forwardStreamProgressLoop(Caller, TaskId, Count);
                    _ ->
                        alProgress:unsubscribe(TaskId),
                        ok
                end
        end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 将上下文类型归一化为工作上下文中的键（modules / files / processes 或自定义原子）。
%%
%% @end
%%--------------------------------------------------------------------
contextKey(modules) -> modules;
contextKey(files) -> files;
contextKey(processes) -> processes;
contextKey(module) -> modules;
contextKey(file) -> files;
contextKey(process) -> processes;
contextKey(Other) when is_atom(Other) -> Other;
contextKey(Other) ->
    Bin = toBinary(Other),
    try binary_to_existing_atom(Bin, utf8) catch _:_ -> Other end.

%%--------------------------------------------------------------------
%% @doc
%% 归一化运行模式：支持原子与二进制形式；非法值返回 badMode。
%%
%% @end
%%--------------------------------------------------------------------
normalizeMode(Mode) when Mode =:= ask; Mode =:= edit; Mode =:= exec; Mode =:= plan -> Mode;
normalizeMode(<<"ask">>) -> ask;
normalizeMode(<<"edit">>) -> edit;
normalizeMode(<<"exec">>) -> exec;
normalizeMode(<<"plan">>) -> plan;
normalizeMode("ask") -> ask;
normalizeMode("edit") -> edit;
normalizeMode("exec") -> exec;
normalizeMode("plan") -> plan;
normalizeMode(_) -> badMode.

%%--------------------------------------------------------------------
%% @doc
%% 将输入转换为 binary：支持 binary / list / atom 三种类型。
%%
%% @end
%%--------------------------------------------------------------------
toBinary(B) when is_binary(B) -> B;
toBinary(L) when is_list(L) -> unicode:characters_to_binary(L);
toBinary(A) when is_atom(A) -> atom_to_binary(A, utf8).
