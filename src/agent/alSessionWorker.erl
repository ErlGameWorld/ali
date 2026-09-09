%%%-------------------------------------------------------------------
%% @doc 每会话一个 worker gen_server。
%%
%% 每个会话由独立 gen_server 持有 pending ask 与任务索引。会话隔离：
%% 单个 worker 崩溃不影响其他。{@link alSessionMgr} 仍是持久化层；
%% 本模块是带优雅取消的异步 ask 执行层。
%%
%% 设计要点：
%% <ul>
%%   <li>每会话串行单个 ask：进行中再发起返回 `{error, sessionBusy}'。</li>
%%   <li>精确取消：`cancelByTaskId/2' 经 `taskRefIndex' 按 taskId 定位，
%%       不打扰其他 ask。</li>
%%   <li>terminate 时记忆蒸馏在分离进程中跑，worker 可立即退出。</li>
%% </ul>
%% @end
%%%-------------------------------------------------------------------

-module(alSessionWorker).

-behaviour(gen_server).

-export([
    start_link/2,
    stop/1,
    ask/4,
    approve/3,
    approve/4,
    cancelByTaskId/2,
    cancelAsk/2,
    pendingList/1,
    snapshot/1,
    setLlmOverride/2,
    setMode/2,
    getMode/1,
    sessionMessages/1,
    clearSession/1
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
    sessionId :: term(),
    pendingAsks = #{} :: #{reference() => pendingAsk()},
    taskRefIndex = #{} :: #{binary() => reference()},
    llmOverride = undefined :: map() | undefined,
    mode = ask :: ask | edit | exec | plan,
    createdAt :: integer(),
    updatedAt :: integer()
}).

-type pendingAsk() :: {From :: term(), SessionId :: term(),
                       StartMs :: integer(), MonRef :: reference(),
                       WorkerPid :: pid(), ProgressId :: term(),
                       TimerRef :: reference() | undefined}.

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 启动 session worker 进程，绑定指定 SessionId，并以 InitOpts 进行初始化。
%%
%% @param SessionId 会话 ID
%% @param InitOpts 初始化选项（可含 mode、llmOverride）
%% @return {ok, Pid} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec start_link(term(), map()) -> {ok, pid()} | {error, term()}.
start_link(SessionId, InitOpts) ->
    gen_server:start_link(?MODULE, {SessionId, InitOpts}, []).

%%--------------------------------------------------------------------
%% @doc
%% 停止指定的 session worker 进程。
%%
%% @param Pid worker 进程
%% @return ok
%% @end
%%--------------------------------------------------------------------
-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid).

%%--------------------------------------------------------------------
%% @doc
%% 异步提问（cast）。From 为调用方 gen_server:call 的 From 标签，
%% worker 完成后通过 gen_server:reply/2 回复。
%%
%% @param Pid worker 进程
%% @param From 调用者标签
%% @param Prompt 用户输入
%% @param Opts 选项 map
%% @return ok
%% @end
%%--------------------------------------------------------------------
%% Async ask (cast). From is the caller's gen_server:call From tag;
%% the worker replies via gen_server:reply/2 when done.
-spec ask(pid(), term(), binary(), map()) -> ok.
ask(Pid, From, Prompt, Opts) ->
    gen_server:cast(Pid, {eAsk, From, Prompt, Opts}).

%% Approval is serialized with every other mutating operation for this
%% session. From is the original alServer call tag and is replied to here.
approve(Pid, From, TaskId) ->
    approve(Pid, From, TaskId, #{}).

approve(Pid, From, TaskId, ExtraOpts) when is_pid(Pid), is_map(ExtraOpts) ->
    gen_server:cast(Pid, {eApprove, From, TaskId, ExtraOpts}).

%%--------------------------------------------------------------------
%% @doc
%% 按 taskId 精确取消进行中的问答，不影响其他问答。
%%
%% @param Pid worker 进程
%% @param TaskId 任务 ID
%% @return ok | {error, notFound}
%% @end
%%--------------------------------------------------------------------
-spec cancelByTaskId(pid(), binary()) -> ok | {error, notFound}.
cancelByTaskId(Pid, TaskId) ->
    gen_server:call(Pid, {eCancelByTaskId, TaskId}).

%%--------------------------------------------------------------------
%% @doc
%% 取消该会话中所有进行中的问答，返回被取消的数量。
%%
%% @param Pid worker 进程
%% @param all 固定原子 all
%% @return #{ok => true, cancelled => Count}
%% @end
%%--------------------------------------------------------------------
-spec cancelAsk(pid(), all) -> map().
cancelAsk(Pid, all) ->
    gen_server:call(Pid, {eCancelAsk, all}).

%%--------------------------------------------------------------------
%% @doc
%% 列出该会话中所有进行中问答的简要信息。
%%
%% @param Pid worker 进程
%% @return [PendingMap]
%% @end
%%--------------------------------------------------------------------
-spec pendingList(pid()) -> [map()].
pendingList(Pid) ->
    gen_server:call(Pid, pendingList).

%%--------------------------------------------------------------------
%% @doc
%% 获取该会话 worker 的快照（id、待处理数、时间戳、是否有 LLM 覆盖、模式）。
%%
%% @param Pid worker 进程
%% @return 快照 map
%% @end
%%--------------------------------------------------------------------
-spec snapshot(pid()) -> map().
snapshot(Pid) ->
    gen_server:call(Pid, snapshot).

%%--------------------------------------------------------------------
%% @doc
%% 设置会话级 LLM 覆盖配置；传入 undefined 表示清除覆盖。
%%
%% @param Pid worker 进程
%% @param Override LLM 配置 map | undefined
%% @return ok
%% @end
%%--------------------------------------------------------------------
-spec setLlmOverride(pid(), map() | undefined) -> ok.
setLlmOverride(Pid, Override) ->
    gen_server:cast(Pid, {eSetLlmOverride, Override}),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% 切换会话运行模式（ask | edit | exec）。模式会通过 Opts 传递给
%% {@link alAgent:run/2}，由 {@link alPolicy} 应用对应工具白名单。
%%
%% @param Pid worker 进程
%% @param Mode ask | edit | exec
%% @return ok
%% @end
%%--------------------------------------------------------------------
%% @doc Switch the session's operating mode (ask | edit | exec). The
%% mode is forwarded to {@link alAgent:run/2} via Opts so the agent
%% can apply the matching tool whitelist via {@link alPolicy}.
-spec setMode(pid(), ask | edit | exec | plan) -> ok.
setMode(Pid, Mode) when Mode =:= ask; Mode =:= edit; Mode =:= exec; Mode =:= plan ->
    gen_server:cast(Pid, {eSetMode, Mode}),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% 查询该会话的当前运行模式。
%%
%% @param Pid worker 进程
%% @return {ok, Mode} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec getMode(pid()) -> {ok, ask | edit | exec | plan} | {error, term()}.
getMode(Pid) ->
    gen_server:call(Pid, getMode).

%%--------------------------------------------------------------------
%% @doc
%% 获取该会话的历史消息列表（从 sessionMgr 读取）。
%%
%% @param Pid worker 进程
%% @return {ok, [Msg]} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec sessionMessages(pid()) -> {ok, [map()]} | {error, term()}.
sessionMessages(Pid) ->
    gen_server:call(Pid, sessionMessages).

%%--------------------------------------------------------------------
%% @doc
%% 清空会话：取消所有进行中问答并清除 sessionMgr 中的历史消息。
%%
%% @param Pid worker 进程
%% @return CancelledCount 被取消的问答数
%% @end
%%--------------------------------------------------------------------
-spec clearSession(pid()) -> ok.
clearSession(Pid) ->
    gen_server:call(Pid, clearSession).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% gen_server 初始化：记录创建时间、确保 metrics/progress 已启动、
%% 从 InitOpts 读取 llmOverride 与 mode 构造初始 state。
%%
%% @end
%%--------------------------------------------------------------------
init({SessionId, InitOpts}) ->
    Now = erlang:system_time(millisecond),
    _ = alMetrics:ensureStarted(),
    _ = alProgress:ensureStarted(),
    Override = maps:get(llmOverride, InitOpts, undefined),
    Mode = normalizeMode(maps:get(mode, InitOpts, ask)),
    {ok, #state{
        sessionId = SessionId,
        llmOverride = Override,
        mode = Mode,
        createdAt = Now,
        updatedAt = Now
    }}.

%%--------------------------------------------------------------------
%% @doc
%% 归一化运行模式：支持原子与二进制；非法值回退为 ask。
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
normalizeMode(_) -> ask.

%%--------------------------------------------------------------------
%% @doc
%% 处理 cancelByTaskId 请求：通过 taskRefIndex 定位 Ref 与 pending 条目，
%% 取消该问答并清理索引。
%%
%% @end
%%--------------------------------------------------------------------
handle_call({eCancelByTaskId, TaskId}, _From, State) ->
    BinTaskId = toBinary(TaskId),
    case maps:get(BinTaskId, State#state.taskRefIndex, undefined) of
        undefined ->
            {reply, {error, notFound}, State};
        Ref ->
            case maps:get(Ref, State#state.pendingAsks, undefined) of
                undefined ->
                    {reply, {error, notFound}, State};
                Entry ->
                    cancelPendingAsk(Entry),
                    NewPending = maps:remove(Ref, State#state.pendingAsks),
                    NewIndex = maps:remove(BinTaskId, State#state.taskRefIndex),
                    {reply, ok, State#state{pendingAsks = NewPending, taskRefIndex = NewIndex,
                                             updatedAt = erlang:system_time(millisecond)}}
            end
    end;

%%--------------------------------------------------------------------
%% @doc
%% 处理 cancelAsk(all) 请求：遍历所有 pending 条目逐一取消，返回取消数量，
%% 并清空 taskRefIndex。
%%
%% @end
%%--------------------------------------------------------------------
handle_call({eCancelAsk, all}, _From, State) ->
    {Count, NewPending} = maps:fold(fun(_Ref, Entry, {N, Acc}) ->
        cancelPendingAsk(Entry),
        {N + 1, Acc}
    end, {0, #{}}, State#state.pendingAsks),
    {reply, #{ok => true, cancelled => Count}, State#state{pendingAsks = NewPending,
                                                            taskRefIndex = #{},
                                                            updatedAt = erlang:system_time(millisecond)}};

%%--------------------------------------------------------------------
%% @doc
%% 处理 pendingList 请求：将所有 pending 条目转为简要 map 列表返回。
%%
%% @end
%%--------------------------------------------------------------------
handle_call(pendingList, _From, State) ->
    Reply = [pendingToMap(Ref, Entry) || {Ref, Entry} <- maps:to_list(State#state.pendingAsks)],
    {reply, Reply, State};

%%--------------------------------------------------------------------
%% @doc
%% 处理 snapshot 请求：返回会话 id、pending 数量、时间戳、是否有 LLM 覆盖、模式等快照。
%%
%% @end
%%--------------------------------------------------------------------
handle_call(snapshot, _From, State) ->
    Snap = #{
        id => State#state.sessionId,
        pendingAskCount => maps:size(State#state.pendingAsks),
        createdAt => State#state.createdAt,
        updatedAt => State#state.updatedAt,
        hasLlmOverride => State#state.llmOverride =/= undefined,
        mode => State#state.mode
    },
    {reply, Snap, State};

%% 处理 getMode 请求：返回当前模式。
handle_call(getMode, _From, State) ->
    {reply, {ok, State#state.mode}, State};

%%--------------------------------------------------------------------
%% @doc
%% 处理 sessionMessages 请求：从 sessionMgr 读取该会话的上下文与消息。
%% 异常时返回 sessionMgrUnavailable。
%%
%% @end
%%--------------------------------------------------------------------
handle_call(sessionMessages, _From, State) ->
    Reply = case State#state.sessionId of
        undefined -> {error, noSession};
        Sid ->
            try alSessionMgr:getContext(Sid)
            catch _:_ -> {error, sessionMgrUnavailable} end
    end,
    {reply, Reply, State};

%%--------------------------------------------------------------------
%% @doc
%% 处理 clearSession 请求：取消所有 pending 问答、清除 sessionMgr 历史消息，
%% 重置 pendingAsks 与 taskRefIndex。
%%
%% @end
%%--------------------------------------------------------------------
handle_call(clearSession, _From, State) ->
    Cancelled = maps:fold(fun(_Ref, Entry, Acc) ->
        cancelPendingAsk(Entry),
        Acc + 1
    end, 0, State#state.pendingAsks),
    case State#state.sessionId of
        undefined -> ok;
        Sid ->
            try alSessionMgr:clearMessages(Sid)
            catch _:_ -> ok end
    end,
    {reply, Cancelled, State#state{pendingAsks = #{}, taskRefIndex = #{},
                                   updatedAt = erlang:system_time(millisecond)}};

%% 兜底处理未知 call 请求，返回 unknownRequest。
handle_call(_Request, _From, State) ->
    {reply, {error, unknownRequest}, State}.

%%--------------------------------------------------------------------
%% @doc
%% 处理 ask cast：转入 doAsk 执行实际的提问调度逻辑。
%%
%% @end
%%--------------------------------------------------------------------
handle_cast({eAsk, From, Prompt, Opts}, State) ->
    doAsk(Prompt, Opts, From, State);

handle_cast({eApprove, From, TaskId}, State) ->
    doApprove(From, TaskId, #{}, State);
handle_cast({eApprove, From, TaskId, ExtraOpts}, State) when is_map(ExtraOpts) ->
    doApprove(From, TaskId, ExtraOpts, State);

%%--------------------------------------------------------------------
%% @doc
%% 处理 setLlmOverride cast：更新 LLM 覆盖与 updatedAt。
%%
%% @end
%%--------------------------------------------------------------------
handle_cast({eSetLlmOverride, Override}, State) ->
    {noreply, State#state{llmOverride = Override,
                          updatedAt = erlang:system_time(millisecond)}};

%%--------------------------------------------------------------------
%% @doc
%% 处理 setMode cast：校验模式合法性后更新状态中的 mode 与 updatedAt。
%%
%% @end
%%--------------------------------------------------------------------
handle_cast({eSetMode, Mode}, State)
  when Mode =:= ask; Mode =:= edit; Mode =:= exec; Mode =:= plan ->
    {noreply, State#state{mode = Mode,
                          updatedAt = erlang:system_time(millisecond)}};

%% 兜底处理未知 cast，保持状态不变。
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @doc
%% 处理 eAskResult 消息：spawn 的 worker 完成后回传结果。
%% 解除 monitor、记录指标、回复调用方、清理索引，并将精简结果写入 progress。
%%
%% @end
%%--------------------------------------------------------------------
handle_info({eAskResult, Ref, RunResult, ProgressId}, State) ->
    case maps:take(Ref, State#state.pendingAsks) of
        {{From, _Sid, StartMs, MonRef, _WorkerPid, _ProgressId, TimerRef}, NewPending} ->
            cancelTimer(TimerRef),
            erlang:demonitor(MonRef, [flush]),
            recordAskMetrics(RunResult, StartMs),
            Reply = handleAskResult(RunResult, ProgressId),
            maybeReply(From, Reply),
            IndexAfter = removeTaskIndex(State#state.taskRefIndex, ProgressId),
            %% Keep progress ETS small — full agent result includes runtime probe.
            alProgress:finish(ProgressId, slimProgressResult(RunResult)),
            {noreply, State#state{pendingAsks = NewPending, taskRefIndex = IndexAfter,
                                  updatedAt = erlang:system_time(millisecond)}};
        error ->
            {noreply, State}
    end;

%%--------------------------------------------------------------------
%% @doc
%% 处理 worker 进程 DOWN 消息：定位对应 pending、向调用方回复崩溃错误、
%% 记录指标并通知 progress 失败。
%%
%% @end
%%--------------------------------------------------------------------
handle_info({'DOWN', MonRef, process, _Pid, Reason}, State) ->
    case findPendingByMonitor(MonRef, State#state.pendingAsks) of
        {ok, Ref, {From, _Sid, StartMs, _MonRef, _WorkerPid, ProgressId, TimerRef}} ->
            cancelTimer(TimerRef),
            NewPending = maps:remove(Ref, State#state.pendingAsks),
            alAskDiag:report(exit, Reason, [], #{where => workerDown, progressId => ProgressId}),
            ErrMsg = iolist_to_binary([
                <<"agent worker crashed: ">>,
                io_lib:format("~p", [Reason])
            ]),
            recordAskMetrics({error, workerCrash}, StartMs),
            maybeReply(From, {error, ErrMsg}),
            alProgress:finish(ProgressId, {error, workerCrash}),
            NewIndex = removeTaskIndexByRef(Ref, State#state.taskRefIndex),
            {noreply, State#state{pendingAsks = NewPending, taskRefIndex = NewIndex,
                                  updatedAt = erlang:system_time(millisecond)}};
        notFound ->
            {noreply, State}
    end;

%%--------------------------------------------------------------------
%% @doc
%% 处理 agent 执行超时：kill worker 进程、向调用方回复 timeout、
%% 清理 pending 条目和 progress。
%%
%% @end
%%--------------------------------------------------------------------
handle_info({eAskTimeout, Ref}, State) ->
    case maps:take(Ref, State#state.pendingAsks) of
        {{From, _Sid, StartMs, MonRef, WorkerPid, ProgressId, _TimerRef}, NewPending} ->
            erlang:demonitor(MonRef, [flush]),
            case is_pid(WorkerPid) of
                true -> exit(WorkerPid, kill);
                false -> ok
            end,
            recordAskMetrics({error, timeout}, StartMs),
            maybeReply(From, {error, agentTimeout}),
            alProgress:finish(ProgressId, {error, agentTimeout}),
            logger:warning("alSessionWorker agent timeout after ~pms", [agentTimeoutMs()]),
            {noreply, State#state{pendingAsks = NewPending,
                                  taskRefIndex = removeTaskIndex(State#state.taskRefIndex, ProgressId),
                                  updatedAt = erlang:system_time(millisecond)}};
        error ->
            {noreply, State}
    end;

%% 兜底处理未知 info 消息，保持状态不变。
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @doc
%% gen_server 终止回调：在 detached 进程中触发自动记忆蒸馏（若启用）。
%%
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, State) ->
    maybeAutoDistill(State),
    ok.

%% 热代码升级回调，直接保留原状态。
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal: ask execution
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 执行提问调度：若已有活跃问答，则先取消所有进行中的问答再启动新的
%% （后到优先，cancel-and-restart 语义）；否则直接转入 doAsk1 启动。
%%
%% @end
%%--------------------------------------------------------------------
doAsk(Prompt, Opts, From, State) ->
    SessionId = State#state.sessionId,
    case hasActiveAsk(State#state.pendingAsks) of
        true ->
            %% Cancel existing asks and start the new one.
            {_Count, NewPending} = maps:fold(fun(_Ref, Entry, {N, Acc}) ->
                cancelPendingAsk(Entry),
                {N + 1, Acc}
            end, {0, #{}}, State#state.pendingAsks),
            doAsk1(Prompt, Opts, From, SessionId,
                   State#state{pendingAsks = NewPending,
                               taskRefIndex = #{}});
        false ->
            doAsk1(Prompt, Opts, From, SessionId, State)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 实际启动一次问答：分配 ProgressId、emit 进度、构造最终选项、
%% spawn_monitor 执行 alAgent:run，并将 pending 条目登记入 state。
%%
%% @end
%%--------------------------------------------------------------------
doAsk1(Prompt, Opts, From, SessionId, State) ->
    TaskId = maps:get(taskId, Opts, undefined),
    %% 优先复用调用方传入的 progressId（如流式/异步路径已分配），
    %% 其次退回 taskId，最后才生成新的唯一 id，避免进度事件串号。
    ProgressId = case maps:get(progressId, Opts, undefined) of
        undefined when TaskId =:= undefined ->
            erlang:unique_integer([positive, monotonic]);
        undefined -> TaskId;
        Pid -> Pid
    end,
    alProgress:start(ProgressId),
    alProgress:emit(ProgressId, #{type => step, phase => prepare,
                                     message => <<"正在准备会话与系统提示…"/utf8>>}),
    Server = self(),
    Ref = make_ref(),
    AskOpts = Opts#{sessionId => SessionId},
    AskOpts1 = case maps:is_key(mode, AskOpts) of
        true -> AskOpts;
        false -> AskOpts#{mode => State#state.mode}
    end,
    FinalOpts0 = resolveLlmOverride(AskOpts1, State#state.llmOverride),
    FinalOpts = FinalOpts0#{
        progressId => ProgressId,
        taskId => toBinary(ProgressId)
    },
    %% 包装 streamCaller：转发 token 的同时累积 partial，供 soft cancel 落盘。
    FinalOpts1 = wrapStreamCaller(FinalOpts, ProgressId),
    %% 注意：真正的 context 构建在 alAgent:run 内；此处仅表示 worker 已启动。
    alProgress:emit(ProgressId, #{type => step, phase => ready,
                                     message => <<"工作进程已启动；正在构建上下文并调用模型…"/utf8>>}),
    {WorkerPid, MonRef} = spawn_monitor(fun() ->
        RunResult =
            try alAgent:run(Prompt, FinalOpts1) of
                R -> R
            catch
                Class:Reason:Stack ->
                    alAskDiag:report(Class, Reason, Stack,
                                     #{where => alAgentRun, sessionId => SessionId}),
                    {error, {agentCrash, Class, Reason, lists:sublist(Stack, 12)}}
            end,
        Server ! {eAskResult, Ref, RunResult, ProgressId}
    end),
    StartMs = erlang:monotonic_time(millisecond),
    AgentTimeoutMs = agentTimeoutMs(),
    TimerRef = case AgentTimeoutMs > 0 of
        true -> erlang:send_after(AgentTimeoutMs, self(), {eAskTimeout, Ref});
        false -> undefined
    end,
    Entry = {From, SessionId, StartMs, MonRef, WorkerPid, ProgressId, TimerRef},
    NewPending = maps:put(Ref, Entry, State#state.pendingAsks),
    %% taskRefIndex 统一用 toBinary(ProgressId) 作键：与 removeTaskIndex/
    %% cancelByTaskId 的查找键一致（FinalOpts.taskId 也等于 toBinary(ProgressId)，
    %% 故外部按 taskId 取消时同样命中）。避免 caller-provided taskId 与
    %% ProgressId 不一致时索引泄漏。
    NewIndex = maps:put(toBinary(ProgressId), Ref, State#state.taskRefIndex),
    {noreply, State#state{pendingAsks = NewPending, taskRefIndex = NewIndex,
                          updatedAt = erlang:system_time(millisecond)}}.

%%--------------------------------------------------------------------
%% @doc
%% 审批后异步执行：先在 alPending 内原子认领（claimApprove，快操作），
%% 认领成功后用 spawn_monitor 在独立进程中运行工具/续跑 agent，避免
%% 同步执行长耗时的 executeApproved 阻塞整个 session worker（进而拖住
%% 通过 worker 路由的其它审批/取消/快照请求）。
%%
%% 复用 doAsk 的 pendingAsks/DOWN/超时框架：执行进程完成后发送
%% eAskResult 由既有 handle_info 统一回复调用方并清理；若执行进程崩溃
%% 则由 DOWN 分支回复错误。
%%
%% @end
%%--------------------------------------------------------------------
doApprove(From, TaskId, ExtraOpts, State) when is_map(ExtraOpts) ->
    Now = erlang:system_time(millisecond),
    case claimApproveSafe(TaskId) of
        {error, _} = Err ->
            maybeReply(From, Err),
            {noreply, State#state{updatedAt = Now}};
        {ok, Spec} ->
            Opts0 = maps:get(opts, Spec, #{}),
            Opts = maps:merge(Opts0, ExtraOpts),
            Spec1 = Spec#{opts => Opts},
            BinTaskId = toBinary(maps:get(taskId, Spec1, TaskId)),
            ProgressId = maps:get(progressId, Opts, BinTaskId),
            Server = self(),
            Ref = make_ref(),
            {WorkerPid, MonRef} = spawn_monitor(fun() ->
                RunResult = try alPending:executeApproved(Spec1)
                            catch Class:Reason ->
                                {error, {approvalFailed, Class, Reason}}
                            end,
                Server ! {eAskResult, Ref, RunResult, ProgressId}
            end),
            StartMs = erlang:monotonic_time(millisecond),
            AgentTimeoutMs = agentTimeoutMs(),
            TimerRef = case AgentTimeoutMs > 0 of
                true -> erlang:send_after(AgentTimeoutMs, self(), {eAskTimeout, Ref});
                false -> undefined
            end,
            Entry = {From, State#state.sessionId, StartMs, MonRef, WorkerPid, ProgressId, TimerRef},
            NewPending = maps:put(Ref, Entry, State#state.pendingAsks),
            %% 与 doAsk1 一致：taskRefIndex 用 toBinary(ProgressId) 作键，
            %% 保证 removeTaskIndex/cancelByTaskId 能命中。
            NewIndex = maps:put(toBinary(ProgressId), Ref, State#state.taskRefIndex),
            {noreply, State#state{pendingAsks = NewPending, taskRefIndex = NewIndex,
                                  updatedAt = Now}}
    end.

%% 安全认领：claimApprove 走 alPending gen_server，任何异常降级为 error。
claimApproveSafe(TaskId) ->
    try alPending:claimApprove(TaskId)
    catch Class:Reason -> {error, {approvalFailed, Class, Reason}}
    end.

%%%===================================================================
%%% Internal: result handling
%%%===================================================================

%% 直接返回 RunResult（扩展钩子：未来可在此推送异步进度/事件）。
handleAskResult(RunResult, TaskId) ->
    logger:debug("alSessionWorker ask result task=~p", [TaskId]),
    RunResult.

%%--------------------------------------------------------------------
%% @doc
%% 精简 agent 结果用于 progress ETS：仅保留 answer / sessionId / critiqueRounds，
%% 避免存入体积较大的 runtime probe 等字段。
%%
%% @end
%%--------------------------------------------------------------------
slimProgressResult({ok, Map}) when is_map(Map) ->
    {ok, maps:with([answer, sessionId, critiqueRounds, suspended, pendingTaskId], Map)};
slimProgressResult({error, _} = Err) ->
    Err;
slimProgressResult(Other) ->
    Other.

%%%===================================================================
%%% Internal: cancel
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 取消单个 pending 问答：先尽量落盘已生成 partial，再 kill worker，
%% 并向调用方回复 `{error, {cancelled, Partial}}'（无内容时仍为 cancelled）。
%%
%% @end
%%--------------------------------------------------------------------
cancelPendingAsk({From, Sid, _Start, MonRef, WorkerPid, ProgressId, TimerRef}) ->
    cancelTimer(TimerRef),
    erlang:demonitor(MonRef, [flush]),
    %% 软信号：给 worker 极短机会自己收尾（多数路径仍会被随后 kill）。
    case is_pid(WorkerPid) of
        true ->
            try WorkerPid ! eSoftCancel catch _:_ -> ok end,
            ok;
        false -> ok
    end,
    Partial = collectPartialAnswer(ProgressId),
    persistPartialMessage(Sid, Partial),
    case Partial of
        <<>> -> ok;
        Text ->
            try alProgress:emit(ProgressId, #{
                type => answer,
                text => Text,
                partial => true,
                cancelled => true,
                message => <<"已停止：已保留已生成内容"/utf8>>
            }) catch _:_ -> ok end
    end,
    case is_pid(WorkerPid) of
        true -> exit(WorkerPid, kill);
        false -> ok
    end,
    FinishReason = case Partial of
        <<>> -> cancelled;
        P -> {cancelled, P}
    end,
    try alProgress:finish(ProgressId, {error, FinishReason}) catch _:_ -> ok end,
    maybeReply(From, {error, FinishReason}),
    ok.

%% 从 progress partial 缓冲 + 事件中拼出最长可用文本。
collectPartialAnswer(ProgressId) ->
    Acc0 = try alProgress:getPartial(ProgressId) catch _:_ -> <<>> end,
    Acc1 = case Acc0 of
        <<>> ->
            try
                Snap = alProgress:snapshot(ProgressId),
                extractPartialFromEvents(maps:get(events, Snap, []))
            catch _:_ -> <<>>
            end;
        B -> B
    end,
    safeTrimPartial(Acc1).

%% string:trim/1 要求合法 UTF-8；流式模型前缀可能含 Latin-1「·」(16#B7) 等字节。
safeTrimPartial(B) when is_binary(B) ->
    try string:trim(B)
    catch
        error:badarg -> trimAsciiEdges(B);
        _:_ -> B
    end;
safeTrimPartial(Other) ->
    safeTrimPartial(toBinary(Other)).

trimAsciiEdges(Bin) when is_binary(Bin) ->
    trimAsciiTrailing(trimAsciiLeading(Bin)).

trimAsciiLeading(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
    trimAsciiLeading(Rest);
trimAsciiLeading(B) ->
    B.

trimAsciiTrailing(<<>>) -> <<>>;
trimAsciiTrailing(B) ->
    Sz = byte_size(B),
    case binary:last(B) of
        C when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
            trimAsciiTrailing(binary:part(B, 0, Sz - 1));
        _ ->
            B
    end.

extractPartialFromEvents(Events) when is_list(Events) ->
    lists:foldl(fun(Ev, Acc) ->
        case Ev of
            #{type := answer, text := T} when is_binary(T), byte_size(T) >= byte_size(Acc) -> T;
            #{type := token, text := T} when is_binary(T) -> <<Acc/binary, T/binary>>;
            #{type := completed, message := T} when is_binary(T), byte_size(T) > byte_size(Acc) -> T;
            _ -> Acc
        end
    end, <<>>, Events);
extractPartialFromEvents(_) ->
    <<>>.

persistPartialMessage(_Sid, <<>>) -> ok;
persistPartialMessage(undefined, _) -> ok;
persistPartialMessage(Sid, Text) ->
    Msg = #{
        role => assistant,
        content => Text,
        status => stopped,
        partial => true
    },
    try alSessionMgr:appendMessage(Sid, Msg) of
        _ -> ok
    catch
        _:_ -> ok
    end.

%% 包装 streamCaller：边转发边累积 partial。
wrapStreamCaller(Opts, ProgressId) when is_map(Opts) ->
    case maps:get(streamCaller, Opts, undefined) of
        Pid when is_pid(Pid) ->
            Proxy = spawn(fun() -> streamPartialProxy(Pid, ProgressId) end),
            Opts#{streamCaller => Proxy};
        _ ->
            Opts
    end.

%% 中间轮 LLM（含 tool_calls）也会发 eStreamDone；不能退出，否则下一轮
%% streamCaller 已死 → cancel watch 报 callerDown。整轮结束靠 eStreamAnswer /
%% eStreamError / eStop。中间 eStreamDone 只更新 partial，不向外转发（避免
%% SSE 外层误当整轮结束关连接）。
streamPartialProxy(Caller, ProgressId) ->
    receive
        eStop ->
            ok;
        {eStreamChunk, Chunk} = Msg ->
            try alProgress:appendPartial(ProgressId, Chunk) catch _:_ -> ok end,
            try Caller ! Msg catch _:_ -> ok end,
            streamPartialProxy(Caller, ProgressId);
        {eStreamDone, Final} ->
            case is_binary(Final) andalso Final =/= <<>> of
                true ->
                    Cur = try alProgress:getPartial(ProgressId) catch _:_ -> <<>> end,
                    case byte_size(Final) >= byte_size(Cur) of
                        true -> ensurePartialOverwrite(ProgressId, Final);
                        false -> ok
                    end;
                false ->
                    ok
            end,
            streamPartialProxy(Caller, ProgressId);
        {eStreamAnswer, _} = Msg ->
            try Caller ! Msg catch _:_ -> ok end,
            ok;
        {eStreamError, _} = Msg ->
            try Caller ! Msg catch _:_ -> ok end,
            ok;
        Msg ->
            try Caller ! Msg catch _:_ -> ok end,
            streamPartialProxy(Caller, ProgressId)
    after 1800000 ->
        ok
    end.

ensurePartialOverwrite(ProgressId, Text) ->
    try
        %% appendPartial 只能追加；覆盖走 emit answer + 内部 maybeCapturePartial。
        alProgress:emit(ProgressId, #{type => answer, text => Text})
    catch
        _:_ -> ok
    end.

%% 取消 agent 超时定时器（若存在）。
cancelTimer(undefined) -> ok;
cancelTimer(TimerRef) -> erlang:cancel_timer(TimerRef, [{async, true}, {info, false}]).

%% 从配置读取 agent 执行超时（毫秒），默认 1800000 (30 分钟)，0 表示不限制。
agentTimeoutMs() ->
    AgentCfg = alConfig:getAgentCfg(),
    maps:get(agentTimeoutMs, AgentCfg, 1800000).

%%%===================================================================
%%% Internal: helpers
%%%===================================================================

%% 判断当前是否存在活跃问答。
hasActiveAsk(PendingAsks) ->
    map_size(PendingAsks) > 0.

%%--------------------------------------------------------------------
%% @doc
%% 通过 monitor 引用在 pendingAsks 中反查对应条目。
%%
%% @end
%%--------------------------------------------------------------------
findPendingByMonitor(MonRef, PendingAsks) ->
    Iter = maps:iterator(PendingAsks),
    findIter(maps:next(Iter), MonRef).

%% 迭代辅助：匹配到对应 MonRef 即返回 {ok, Ref, Value}，否则继续。
findIter(none, _MonRef) -> notFound;
findIter({Ref, {_From, _Sid, _StartMs, MonRef, _W, _ProgressId, _TimerRef} = Value, _Iter}, MonRef) ->
    {ok, Ref, Value};
findIter({_K, _V, Iter}, MonRef) ->
    findIter(maps:next(Iter), MonRef).

%%--------------------------------------------------------------------
%% @doc
%% 安全回复调用方：From 可能是 gen_server:call 标签 {Pid, Tag} 或异步 {Pid, Ref}，
%% 裸引用视为非法并仅记录日志，绝不抛出异常。
%%
%% @end
%%--------------------------------------------------------------------
%% From is either a gen_server:call tag `{Pid, Tag}' or `{Pid, Ref}'
%% from Web/async callers. Bare references are invalid and must not crash us.
maybeReply(undefined, _Reply) ->
    ok;
maybeReply({Pid, _Tag} = From, Reply) when is_pid(Pid) ->
    try gen_server:reply(From, Reply) of
        _ -> ok
    catch
        Class:Reason ->
            logger:warning("alSessionWorker reply failed: ~p:~p", [Class, Reason]),
            ok
    end;
maybeReply(From, _Reply) ->
    logger:warning("alSessionWorker invalid reply target: ~p", [From]),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% 从 taskRefIndex 中移除 ProgressId 对应的索引项（若存在）。
%%
%% @end
%%--------------------------------------------------------------------
removeTaskIndex(Index, ProgressId) ->
    BinId = toBinary(ProgressId),
    case maps:is_key(BinId, Index) of
        true -> maps:remove(BinId, Index);
        false -> Index
    end.

%% 按 Ref 反查并删除 taskRefIndex 中的条目（DOWN 时 ProgressId 可能不是 taskId）。
removeTaskIndexByRef(Ref, Index) ->
    maps:filter(fun(_K, V) -> V =/= Ref end, Index).

%%--------------------------------------------------------------------
%% @doc
%% 记录一次 ask 的指标：计算耗时并按结果状态（ok/error）写入 metrics。
%%
%% @end
%%--------------------------------------------------------------------
recordAskMetrics(RunResult, StartMs) ->
    Duration = erlang:monotonic_time(millisecond) - StartMs,
    Status = case RunResult of
        {ok, _} -> ok;
        _ -> error
    end,
    alMetrics:recordAsk(#{durationMs => Duration, status => Status}).

%%--------------------------------------------------------------------
%% @doc
%% 将 pending 条目转为简要 map：包含 ref、开始时间、已耗时。
%%
%% @end
%%--------------------------------------------------------------------
pendingToMap(Ref, {_From, _Sid, StartMs, _MonRef, _WorkerPid, _ProgressId, _TimerRef}) ->
    #{
        ref => Ref,
        startedAt => StartMs,
        elapsedMs => erlang:monotonic_time(millisecond) - StartMs
    }.

%%--------------------------------------------------------------------
%% @doc
%% 终止时按配置触发自动记忆蒸馏：在 detached 进程中读取会话消息，
%% 消息数 >= 4 时调用 alMemory:distill。失败仅记录日志，不影响 worker 退出。
%%
%% @end
%%--------------------------------------------------------------------
maybeAutoDistill(#state{sessionId = SessionId}) ->
    Agent = alConfig:get(agent, #{}),
    ShouldDistill = maps:get(autoDistillMemories, Agent, true),
    case ShouldDistill of
        true ->
            spawn(fun() ->
                try
                    {ok, Session} = alSessionMgr:getContext(SessionId),
                    Messages = maps:get(messages, Session, []),
                    case length(Messages) >= 4 of
                        true ->
                            _ = alMemory:distill(SessionId, #{messages => Messages}),
                            ok;
                        false ->
                            ok
                    end
                catch
                    Class:Reason ->
                        logger:warning("session_worker auto-distill failed: ~p:~p",
                                       [Class, Reason])
                end
            end);
        false ->
            ok
    end.

%% 单次 ask 携带的 llmOverride 与会话 setLlm 合并；请求字段覆盖会话字段。
resolveLlmOverride(AskOpts, undefined) ->
    AskOpts;
resolveLlmOverride(AskOpts, SessionOverride) ->
    case maps:get(llmOverride, AskOpts, undefined) of
        undefined ->
            AskOpts#{llmOverride => SessionOverride};
        ReqOverride when is_map(ReqOverride) ->
            AskOpts#{llmOverride => maps:merge(SessionOverride, ReqOverride)}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 将输入转为 binary：支持 binary / list / atom / integer 类型。
%%
%% @end
%%--------------------------------------------------------------------
toBinary(X) when is_binary(X) -> X;
toBinary(X) when is_list(X) -> unicode:characters_to_binary(X);
toBinary(X) when is_atom(X) -> atom_to_binary(X, utf8);
toBinary(X) when is_integer(X) -> integer_to_binary(X).
