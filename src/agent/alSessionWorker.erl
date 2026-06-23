%%%-------------------------------------------------------------------
%%% @doc Per-session 工作进程。
%%%
%%% 每个会话由独立的 gen_server 承载，持有该会话的消息历史、
%%% 挂起 ask 与挂起任务。{@link alServer} 作为注册表与路由层，
%%% 将 per-session 操作委托给本模块。
%%%
%%% 设计收益：
%%% <ul>
%%%   <li>会话隔离：单会话 worker 崩溃不影响其他会话</li>
%%%   <li>并发并行：不同会话的 ask 完全并行，不再串行经过单 gen_server</li>
%%%   <li>精准取消：`cancelTask' 可按 taskId 定位特定 ask 并取消，不误伤同会话其他任务</li>
%%% </ul>
%%%
%%% 全局状态（config / mode / workingContext）由 alServer 持有，
%%% 每次 ask/approve 时作为参数传入，worker 不缓存全局状态。
%%% @end
%%%-------------------------------------------------------------------
-module(alSessionWorker).

-behaviour(gen_server).

-export([
    start_link/2,
    stop/1,
    ask/7,
    askStream/8,
    run/5,
    approve/5,
    dismiss/5,
    pendingTask/2,
    pendingList/1,
    clearSession/1,
    saveSession/2,
    loadSession/2,
    sessionMessages/1,
    cancelAsk/2,
    cancelByTaskId/2,
    snapshot/1
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
    sessionId :: binary(),
    messages = [] :: [map()],
    pendingAsks = #{} :: #{reference() => pending_ask()},
    pendingTasks = #{} :: #{binary() => map()},
    taskRefIndex = #{} :: #{binary() => reference()},  %% taskId => Ref，用于精准取消
    createdAt :: integer(),
    updatedAt :: integer()
}).

-type pending_ask() :: {From :: term(), StartMs :: integer(),
                        MonRef :: reference(), WorkerPid :: pid(),
                        StreamPid :: pid() | undefined}.

-define(DEFAULT_MODEL, <<"gpt-4o-mini"/utf8>>).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link(binary(), map()) -> {ok, pid()} | {error, term()}.
start_link(SessionId, InitOpts) ->
    gen_server:start_link(?MODULE, {SessionId, InitOpts}, []).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid).

%% 异步 ask（cast）。From 为原始调用方的 gen_server:call From，
%% worker 完成后直接 gen_server:reply(From, Reply)，不阻塞 alServer。
-spec ask(pid(), term(), binary(), map(), map(), atom(), map()) -> ok.
ask(Pid, From, Prompt, Opts, Config, Mode, WorkingContext) ->
    gen_server:cast(Pid, {ask, From, Prompt, Opts, Config, Mode, WorkingContext}).

%% 异步流式 ask（cast）。
-spec askStream(pid(), term(), binary(), map(), pid(), map(), atom(), map()) -> ok.
askStream(Pid, From, Prompt, Opts, Caller, Config, Mode, WorkingContext) ->
    gen_server:cast(Pid, {askStream, From, Prompt, Opts, Caller, Config, Mode, WorkingContext}).

%% 直接执行 callFunction 工具。
-spec run(pid(), module(), atom(), list(), map()) -> {ok, map()} | {error, term()}.
run(Pid, Mod, Fun, Args, Config) ->
    gen_server:call(Pid, {run, Mod, Fun, Args, Config}, infinity).

-spec approve(pid(), binary(), map(), atom(), map()) -> {ok, map()} | {error, term()}.
approve(Pid, TaskId, Config, Mode, WorkingContext) ->
    gen_server:call(Pid, {approve, TaskId, Config, Mode, WorkingContext}, infinity).

-spec dismiss(pid(), binary(), map(), atom(), map()) -> {ok, map()} | {error, term()}.
dismiss(Pid, TaskId, Config, Mode, WorkingContext) ->
    gen_server:call(Pid, {dismiss, TaskId, Config, Mode, WorkingContext}, infinity).

-spec pendingTask(pid(), binary()) -> {ok, map()} | {error, notFound}.
pendingTask(Pid, TaskId) ->
    gen_server:call(Pid, {pendingTask, TaskId}).

-spec pendingList(pid()) -> [map()].
pendingList(Pid) ->
    gen_server:call(Pid, pendingList).

-spec clearSession(pid()) -> ok.
clearSession(Pid) ->
    gen_server:call(Pid, clearSession).

-spec saveSession(pid(), binary()) -> ok | {error, term()}.
saveSession(Pid, SessionId) ->
    gen_server:call(Pid, {saveSession, SessionId}).

-spec loadSession(pid(), binary()) -> ok | {error, term()}.
loadSession(Pid, SessionId) ->
    gen_server:call(Pid, {loadSession, SessionId}).

-spec sessionMessages(pid()) -> {ok, [map()]}.
sessionMessages(Pid) ->
    gen_server:call(Pid, sessionMessages).

-spec cancelAsk(pid(), all | binary()) -> map().
cancelAsk(Pid, Filter) ->
    gen_server:call(Pid, {cancelAsk, Filter}).

%% 按 taskId 精准取消对应的 ask（不误伤同会话其他任务）。
-spec cancelByTaskId(pid(), binary()) -> ok | {error, notFound}.
cancelByTaskId(Pid, TaskId) ->
    gen_server:call(Pid, {cancelByTaskId, TaskId}).

%% 返回会话快照（供 alServer:sessions/0 聚合）。
-spec snapshot(pid()) -> map().
snapshot(Pid) ->
    gen_server:call(Pid, snapshot).

%%%===================================================================
%%% gen_server 回调
%%%===================================================================

init({SessionId, InitOpts}) ->
    Now = erlang:system_time(millisecond),
    Messages = maps:get(messages, InitOpts, []),
    {ok, #state{
        sessionId = SessionId,
        messages = Messages,
        createdAt = Now,
        updatedAt = Now
    }}.

%% 直接执行工具
handle_call({run, Mod, Fun, Args, Config}, _From, State) ->
    Result = alTools:execute(
        callFunction,
        #{module => Mod, function => Fun, args => Args},
        Config,
        State#state.sessionId
    ),
    {reply, Result, State};
%% 批准挂起任务
handle_call({approve, TaskId, Config, Mode, WorkingContext}, _From, State) ->
    {Reply, NewState} = doApprove(TaskId, Config, Mode, WorkingContext, State),
    {reply, Reply, NewState};
%% 拒绝挂起任务
handle_call({dismiss, TaskId, Config, Mode, WorkingContext}, _From, State) ->
    {Reply, NewState} = doDismiss(TaskId, Config, Mode, WorkingContext, State),
    {reply, Reply, NewState};
%% 查询挂起任务预览
handle_call({pendingTask, TaskId}, _From, State) ->
    Reply = case maps:get(toBin(TaskId), State#state.pendingTasks, undefined) of
        undefined -> {error, notFound};
        Preview -> {ok, Preview}
    end,
    {reply, Reply, State};
handle_call(pendingList, _From, State) ->
    {reply, maps:values(State#state.pendingTasks), State};
%% 清空会话
handle_call(clearSession, _From, State) ->
    Now = erlang:system_time(millisecond),
    {reply, ok, State#state{messages = [], pendingAsks = #{}, pendingTasks = #{},
                            taskRefIndex = #{}, updatedAt = Now}};
%% 保存会话到磁盘
handle_call({saveSession, SessionId}, _From, State) ->
    Session = #{id => SessionId, messages => State#state.messages,
                createdAt => State#state.createdAt, updatedAt => State#state.updatedAt},
    Reply = case alSession:save(SessionId, Session) of
        ok -> ok;
        {error, Reason} -> {error, Reason}
    end,
    {reply, Reply, State};
%% 从磁盘加载会话
handle_call({loadSession, SessionId}, _From, State) ->
    case alSession:load(SessionId) of
        {ok, Session} ->
            Messages = alContext:sanitizeToolHistory(maps:get(messages, Session, [])),
            Now = erlang:system_time(millisecond),
            {ok, State#state{messages = Messages,
                             createdAt = maps:get(createdAt, Session, Now),
                             updatedAt = Now}};
        {error, Reason} ->
            {{error, Reason}, State}
    end;
%% 返回消息历史
handle_call(sessionMessages, _From, State) ->
    {reply, {ok, State#state.messages}, State};
%% 取消 ask（all 或本会话全部）
handle_call({cancelAsk, _Filter}, _From, State) ->
    {Reply, NewState} = doCancelAllAsks(State),
    {reply, Reply, NewState};
%% 按 taskId 精准取消
handle_call({cancelByTaskId, TaskId}, _From, State) ->
    BinTaskId = toBin(TaskId),
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
                    {reply, ok, State#state{pendingAsks = NewPending, taskRefIndex = NewIndex}}
            end
    end;
%% 返回会话快照
handle_call(snapshot, _From, State) ->
    Snap = #{
        id => State#state.sessionId,
        messageCount => length(State#state.messages),
        createdAt => State#state.createdAt,
        updatedAt => State#state.updatedAt,
        pendingTaskCount => maps:size(State#state.pendingTasks),
        pendingAskCount => maps:size(State#state.pendingAsks)
    },
    {reply, Snap, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknownRequest}, State}.

%% 同步 ask（cast，不阻塞 alServer）
handle_cast({ask, From, Prompt, Opts, Config, Mode, WorkingContext}, State) ->
    doAsk(Prompt, Opts, Config, Mode, WorkingContext, From, undefined, State);
%% 流式 ask（cast）
handle_cast({askStream, From, Prompt, Opts, Caller, Config, Mode, WorkingContext}, State) ->
    doAsk(Prompt, Opts, Config, Mode, WorkingContext, From, Caller, State);
handle_cast(_Msg, State) ->
    {noreply, State}.

%% ask worker 完成
handle_info({askResult, Ref, RunResult, _SessionId, TaskId}, State) ->
    case maps:take(Ref, State#state.pendingAsks) of
        {{From, _Sid, StartMs, MonRef, _WorkerPid, _StreamPid}, NewPending} ->
            erlang:demonitor(MonRef, [flush]),
            recordAskMetrics(RunResult, StartMs),
            {Reply, NewState} = handleAskResult(RunResult, State),
            maybeReply(From, Reply),
            NewIndex = case TaskId of
                undefined -> State#state.taskRefIndex;
                T -> maps:remove(T, State#state.taskRefIndex)
            end,
            {noreply, NewState#state{pendingAsks = NewPending, taskRefIndex = NewIndex}};
        error ->
            {noreply, State}
    end;
%% ask worker 崩溃
handle_info({'DOWN', MonRef, process, _Pid, Reason}, State) ->
    case findPendingByMonitor(MonRef, State#state.pendingAsks) of
        {ok, Ref, {From, _Sid, StartMs, _MonRef, _WorkerPid, StreamPid}} ->
            NewPending = maps:remove(Ref, State#state.pendingAsks),
            notifyStreamError(StreamPid, workerCrash),
            ErrMsg = iolist_to_binary([
                <<"Agent worker crashed: "/utf8>>,
                io_lib:format("~p", [Reason])
            ]),
            recordAskMetrics({error, workerCrash}, StartMs),
            maybeReply(From, {error, ErrMsg}),
            {noreply, State#state{pendingAsks = NewPending}};
        not_found ->
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% 内部：ask 执行
%%%===================================================================

doAsk(Prompt, Opts, Config, Mode, WorkingContext, From, StreamPid, State) ->
    SessionId = State#state.sessionId,
    case hasActiveAsk(State#state.pendingAsks) of
        true ->
            maybeReply(From, {error, sessionBusy}),
            notifyStreamError(StreamPid, sessionBusy),
            case is_pid(StreamPid) of
                true -> StreamPid ! {stream_chunk, done};
                false -> ok
            end,
            {noreply, State};
        false ->
            doAsk1(Prompt, Opts, Config, Mode, WorkingContext, From, StreamPid, SessionId, State)
    end.

doAsk1(Prompt, Opts, Config, Mode, WorkingContext, From, StreamPid, SessionId, State) ->
    AskConfig = applySessionTuning(
        maps:merge(
            Config#{mode => Mode, workingContext => WorkingContext},
            maps:with([progressId, taskId], Opts)
        ),
        SessionId
    ),
    emitProgress(AskConfig, #{type => step, phase => prepare,
                              message => <<"准备会话与系统提示..."/utf8>>}),
    History = State#state.messages,
    Messages = alContext:buildMessages(AskConfig, History, Prompt),
    emitProgress(AskConfig, #{type => step, phase => ready,
                              message => <<"上下文就绪，开始推理..."/utf8>>}),
    Model = maps:get(model, AskConfig, ?DEFAULT_MODEL),
    Server = self(),
    Ref = make_ref(),
    TaskId = maps:get(taskId, Opts, undefined),
    {WorkerPid, MonRef} = spawn_monitor(fun() ->
        RunResult = case StreamPid of
            undefined -> alLoop:run(Model, Messages, AskConfig, SessionId);
            Pid -> alLoop:runStream(Model, Messages, AskConfig, SessionId, Pid)
        end,
        Server ! {askResult, Ref, RunResult, SessionId, TaskId}
    end),
    StartMs = erlang:monotonic_time(millisecond),
    Entry = {From, SessionId, StartMs, MonRef, WorkerPid, StreamPid},
    NewPending = maps:put(Ref, Entry, State#state.pendingAsks),
    NewIndex = case TaskId of
        undefined -> State#state.taskRefIndex;
        T -> maps:put(T, Ref, State#state.taskRefIndex)
    end,
    {noreply, State#state{pendingAsks = NewPending, taskRefIndex = NewIndex}}.

%%%===================================================================
%%% 内部：结果处理
%%%===================================================================

handleAskResult(RunResult, State) ->
    case RunResult of
        {ok, Answer, UpdatedMessages} ->
            Now = erlang:system_time(millisecond),
            Conversation = safeConversation(UpdatedMessages),
            {{ok, Answer}, State#state{messages = Conversation, updatedAt = Now}};
        {pending, Pending, UpdatedMessages} ->
            TaskId = maps:get(taskId, Pending),
            Now = erlang:system_time(millisecond),
            Conversation = safeConversation(UpdatedMessages),
            NewPendingTasks = maps:put(TaskId, Pending, State#state.pendingTasks),
            Msg = iolist_to_binary([
                <<"Operation requires confirmation. TaskId: "/utf8>>,
                TaskId,
                <<". Call ali:approve(\""/utf8>>, TaskId, <<"\") to proceed."/utf8>>
            ]),
            {{ok, Msg}, State#state{messages = Conversation, pendingTasks = NewPendingTasks,
                                    updatedAt = Now}};
        {error, Reason} ->
            {{error, Reason}, State}
    end.

safeConversation(Messages) ->
    alContext:sanitizeToolHistory(alContext:conversationHistory(Messages)).

%%%===================================================================
%%% 内部：approve / dismiss
%%%===================================================================

doApprove(TaskId, Config, Mode, WorkingContext, State) ->
    withPendingTask(TaskId, State, fun(Pending, _BinId, S1) ->
        resumePendingTool(Pending, S1, approved, Config, Mode, WorkingContext)
    end).

doDismiss(TaskId, Config, Mode, WorkingContext, State) ->
    withPendingTask(TaskId, State, fun(Pending, _BinId, S1) ->
        resumePendingTool(Pending, S1, dismissed, Config, Mode, WorkingContext)
    end).

withPendingTask(TaskId, State, Fun) ->
    BinId = toBin(TaskId),
    case maps:get(BinId, State#state.pendingTasks, undefined) of
        undefined -> {{error, taskNotFound}, State};
        Pending -> Fun(Pending, BinId, State)
    end.

resumePendingTool(Pending, State, Action, Config, Mode, WorkingContext) ->
    Tool = maps:get(tool, Pending),
    Args = maps:get(args, Pending),
    SessionId = State#state.sessionId,
    ToolCallId = maps:get(toolCallId, Pending, undefined),
    Model = maps:get(model, Pending, maps:get(model, Config, ?DEFAULT_MODEL)),
    Steps = maps:get(remainingSteps, Pending, 10),
    AskConfig = applySessionTuning(
        Config#{mode => Mode, workingContext => WorkingContext, sessionId => SessionId},
        SessionId
    ),
    Messages = State#state.messages,
    {ToolResult, UpdatedMessages} = pendingToolUpdate(Action, Tool, Args, AskConfig, SessionId, Messages, ToolCallId),
    State1 = State#state{pendingTasks = maps:remove(maps:get(taskId, Pending), State#state.pendingTasks)},
    Now = erlang:system_time(millisecond),
    State2 = State1#state{messages = safeConversation(UpdatedMessages), updatedAt = Now},
    case maps:is_key(model, Pending) of
        true ->
            RunResult = alLoop:resume(Model, UpdatedMessages, AskConfig, SessionId, Steps),
            {Reply, State3} = handleAskResult(RunResult, State2),
            case Reply of
                {ok, Answer} -> {{ok, #{result => ToolResult, answer => Answer}}, State3};
                {error, Reason} -> {{ok, #{result => ToolResult, resumeError => Reason}}, State3}
            end;
        false ->
            {{ok, ToolResult}, State2}
    end.

pendingToolUpdate(approved, Tool, Args, AskConfig, SessionId, Messages, ToolCallId) ->
    case alTools:execute(Tool, Args, AskConfig, SessionId, #{confirmed => true}) of
        {ok, Result} ->
            Content = alLoop:toolResultContent(#{ok => true, result => Result}, AskConfig),
            {Result, patchToolMessage(Messages, ToolCallId, Content)};
        {error, Reason} ->
            Content = alLoop:toolResultContent(#{ok => false, error => Reason}, AskConfig),
            {#{error => Reason}, patchToolMessage(Messages, ToolCallId, Content)}
    end;
pendingToolUpdate(dismissed, _Tool, _Args, AskConfig, _SessionId, Messages, ToolCallId) ->
    Content = alLoop:toolResultContent(#{ok => false, status => rejected, reason => userDismissed}, AskConfig),
    {#{status => rejected}, patchToolMessage(Messages, ToolCallId, Content)}.

patchToolMessage(Messages, undefined, Content) ->
    patchLastToolMessage(Messages, Content);
patchToolMessage(Messages, ToolCallId, Content) ->
    lists:map(fun(M) -> patchOneToolMessage(M, ToolCallId, Content) end, Messages).

patchOneToolMessage(#{role := tool, tool_call_id := Id} = M, ToolCallId, Content)
        when Id =:= ToolCallId ->
    M#{content => Content};
patchOneToolMessage(M, _, _) ->
    M.

patchLastToolMessage(Messages, Content) ->
    case lists:reverse(Messages) of
        [#{role := tool} = Last | Rest] ->
            lists:reverse([Last#{content => Content} | Rest]);
        _ ->
            Messages
    end.

%%%===================================================================
%%% 内部：取消
%%%===================================================================

doCancelAllAsks(State) ->
    {Count, NewPending} = maps:fold(fun(_Ref, Entry, {N, Acc}) ->
        cancelPendingAsk(Entry),
        {N + 1, Acc}
    end, {0, #{}}, State#state.pendingAsks),
    {#{ok => true, cancelled => Count}, State#state{pendingAsks = NewPending, taskRefIndex = #{}}}.

cancelPendingAsk({From, _Sid, _Start, MonRef, WorkerPid, StreamPid}) ->
    erlang:demonitor(MonRef, [flush]),
    case is_pid(WorkerPid) of
        true -> exit(WorkerPid, kill);
        false -> ok
    end,
    notifyStreamError(StreamPid, cancelled),
    case is_pid(StreamPid) of
        true -> StreamPid ! {stream_chunk, done};
        false -> ok
    end,
    maybeReply(From, {error, <<"cancelled"/utf8>>}),
    ok.

%%%===================================================================
%%% 内部：工具函数
%%%===================================================================

hasActiveAsk(PendingAsks) ->
    map_size(PendingAsks) > 0.

findPendingByMonitor(MonRef, PendingAsks) ->
    Iter = maps:iterator(PendingAsks),
    findIter(maps:next(Iter), MonRef).

findIter(none, _MonRef) -> not_found;
findIter({Ref, {_From, _Sid, _StartMs, MonRef, _W, _S} = Value, _Iter}, MonRef) ->
    {ok, Ref, Value};
findIter({_K, _V, Iter}, MonRef) ->
    findIter(maps:next(Iter), MonRef).

maybeReply(undefined, _Reply) -> ok;
maybeReply(From, Reply) -> gen_server:reply(From, Reply).

notifyStreamError(Pid, Reason) when is_pid(Pid) ->
    Pid ! {al, streamError, Reason};
notifyStreamError(_Pid, _Reason) -> ok.

recordAskMetrics(RunResult, StartMs) ->
    Duration = erlang:monotonic_time(millisecond) - StartMs,
    {Ok, Msgs} = case RunResult of
        {ok, _Answer, Updated} -> {true, Updated};
        {pending, _Pending, Updated} -> {true, Updated};
        _ -> {false, []}
    end,
    ToolCalls = length([M || M <- Msgs, isToolMessage(M)]),
    alMetrics:recordAsk(#{durationMs => Duration, ok => Ok, toolCalls => ToolCalls}).

isToolMessage(#{role := tool}) -> true;
isToolMessage(_) -> false.

applySessionTuning(Config, SessionId) ->
    case SessionId of
        <<"web"/utf8>> ->
            Steps = maps:get(maxSteps, Config, 25),
            Config#{maxSteps => max(Steps, 40)};
        _ ->
            Config
    end.

emitProgress(Config, Event) ->
    case maps:get(progressId, Config, undefined) of
        undefined -> ok;
        Id -> alProgress:emit(Id, Event)
    end.

toBin(B) when is_binary(B) -> B;
toBin(L) when is_list(L) -> unicode:characters_to_binary(L);
toBin(A) when is_atom(A) -> atom_to_binary(A, utf8).
