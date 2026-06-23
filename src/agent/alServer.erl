%%%-------------------------------------------------------------------
%%% @doc Agent 核心协调层（薄 gen_server）。
%%%
%%% 作为注册表与路由层，维护全局配置（config / mode /
%%% workingContext）与会话→工作进程映射。所有 per-session 操作
%%% （ask / approve / clearSession 等）委托给 {@link alSessionWorker}。
%%%
%%% 架构收益：
%%% <ul>
%%%   <li>不同会话的 ask 完全并行（各自独立 worker 进程）</li>
%%%   <li>单会话 worker 崩溃不影响其他会话</li>
%%%   <li>`cancelTask' 按 taskId 精准取消，不误伤同会话其他任务</li>
%%% </ul>
%%%
%%% 注册名：`alServer'。对外请通过 {@link ali} 模块调用。
%%% @end
%%%-------------------------------------------------------------------
-module(alServer).

-behaviour(gen_server).

-export([
    startLink/0,
    startLink/1,
    stop/0,
    ask/1,
    ask/2,
    askStream/1,
    askStream/2,
    askAsync/1,
    askAsync/2,
    run/1,
    approve/1,
    dismiss/1,
    pendingTask/1,
    pendingList/0,
    status/0,
    tools/0,
    sessions/0,
    clearSession/0,
    clearSession/1,
    saveSession/0,
    saveSession/1,
    loadSession/1,
    deleteSavedSession/1,
    savedSessions/0,
    sessionMessages/1,
    cancelAsk/0,
    cancelAsk/1,
    taskStatus/1,
    cancelTask/1,
    tasks/0,
    getConfig/0,
    setConfig/2,
    getMode/0,
    setMode/1,
    getWorkingContext/0,
    addContext/2,
    clearContext/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
    runtimeOverrides = #{},
    sessions = #{},              %% SessionId => WorkerPid
    defaultSession = <<"default"/utf8>>,
    mode = ask,
    workingContext = #{modules => [], files => [], processes => []}
}).

-define(SERVER, alServer).
-define(DEFAULT_MODEL, <<"gpt-4o-mini"/utf8>>).

%%%===================================================================
%%% API
%%%===================================================================

startLink() -> startLink([]).

startLink(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).

stop() ->
    case whereis(?SERVER) of
        undefined -> ok;
        Pid -> gen_server:stop(Pid)
    end.

ask(Prompt) -> ask(Prompt, #{}).

ask(Prompt, Opts) when is_binary(Prompt); is_list(Prompt) ->
    gen_server:call(?SERVER, {ask, toBinary(Prompt), Opts}, infinity).

askStream(Prompt) -> askStream(Prompt, #{}).

askStream(Prompt, Opts) when is_binary(Prompt); is_list(Prompt) ->
    gen_server:call(?SERVER, {askStream, toBinary(Prompt), Opts, self()}, infinity).

askAsync(Prompt) -> askAsync(Prompt, #{}).

askAsync(Prompt, Opts) when is_binary(Prompt); is_list(Prompt) ->
    gen_server:call(?SERVER, {askAsync, toBinary(Prompt), Opts}).

run({Mod, Fun, Args}) ->
    gen_server:call(?SERVER, {run, Mod, Fun, Args}, infinity).

approve(TaskId) ->
    gen_server:call(?SERVER, {approve, TaskId}, infinity).

dismiss(TaskId) ->
    gen_server:call(?SERVER, {dismiss, TaskId}, infinity).

pendingTask(TaskId) ->
    gen_server:call(?SERVER, {pendingTask, TaskId}, infinity).

pendingList() ->
    gen_server:call(?SERVER, pendingList, infinity).

status() ->
    gen_server:call(?SERVER, status).

tools() -> alTools:listTools().

sessions() ->
    gen_server:call(?SERVER, sessions).

clearSession() ->
    gen_server:call(?SERVER, clearSession).

clearSession(SessionId) ->
    gen_server:call(?SERVER, {clearSession, SessionId}).

saveSession() ->
    gen_server:call(?SERVER, saveSession).

saveSession(SessionId) ->
    gen_server:call(?SERVER, {saveSession, SessionId}).

loadSession(SessionId) ->
    gen_server:call(?SERVER, {loadSession, SessionId}).

deleteSavedSession(SessionId) ->
    gen_server:call(?SERVER, {deleteSavedSession, SessionId}).

savedSessions() ->
    gen_server:call(?SERVER, savedSessions).

sessionMessages(SessionId) ->
    gen_server:call(?SERVER, {sessionMessages, SessionId}).

cancelAsk() ->
    gen_server:call(?SERVER, cancelAsk).

cancelAsk(SessionId) when is_binary(SessionId) ->
    gen_server:call(?SERVER, {cancelAsk, SessionId}).

taskStatus(TaskId) -> alTask:status(TaskId).

%% 精准取消：通过 worker 按 taskId 定位特定 ask，不误伤同会话其他任务。
cancelTask(TaskId) ->
    case alTask:status(TaskId) of
        {ok, #{sessionId := SessionId}} ->
            _ = gen_server:call(?SERVER, {cancelTask, SessionId, TaskId}),
            alTask:cancel(TaskId);
        {error, notFound} ->
            {error, notFound}
    end.

tasks() -> alTask:list().

getConfig() -> gen_server:call(?SERVER, getConfig).

setConfig(Key, Value) -> gen_server:call(?SERVER, {setConfig, Key, Value}).

getMode() -> gen_server:call(?SERVER, getMode).

setMode(Mode) -> gen_server:call(?SERVER, {setMode, Mode}).

getWorkingContext() -> gen_server:call(?SERVER, getWorkingContext).

addContext(Type, Value) -> gen_server:call(?SERVER, {addContext, Type, Value}).

clearContext() -> gen_server:call(?SERVER, clearContext).

%%%===================================================================
%%% gen_server 回调
%%%===================================================================

init(Opts) ->
    alAudit:init(),
    alTask:init(),
    alMetrics:init(),
    Overrides = maps:from_list(Opts),
    Config = effectiveConfig(Overrides, maps:get(mode, Overrides, ask)),
    DefaultSession = maps:get(defaultSession, Overrides, <<"default"/utf8>>),
    Mode = maps:get(mode, Overrides, maps:get(mode, Config, ask)),
    _ = try alCodeIndexer:refresh(Config) catch _:_ -> ok end,
    {ok, #state{
        runtimeOverrides = Overrides,
        defaultSession = DefaultSession,
        mode = Mode,
        workingContext = defaultWorkingContext()
    }}.

%% 同步 ask：cast 到 worker，worker 完成后直接 reply 调用者（不阻塞 alServer）
handle_call({ask, Prompt, Opts}, From, State) ->
    SessionId = maps:get(sessionId, Opts, State#state.defaultSession),
    {WorkerPid, NewState} = ensureWorker(SessionId, State),
    alSessionWorker:ask(WorkerPid, From, Prompt, Opts, effectiveConfig(State),
                        State#state.mode, State#state.workingContext),
    {noreply, NewState};

%% 流式 ask
handle_call({askStream, Prompt, Opts, Caller}, From, State) ->
    SessionId = maps:get(sessionId, Opts, State#state.defaultSession),
    {WorkerPid, NewState} = ensureWorker(SessionId, State),
    alSessionWorker:askStream(WorkerPid, From, Prompt, Opts, Caller, effectiveConfig(State),
                              State#state.mode, State#state.workingContext),
    {noreply, NewState};

%% 异步 ask：通过 alTask，runner 内部调用 alServer:ask 同步等待 worker 完成
handle_call({askAsync, Prompt, Opts}, _From, State) ->
    Server = self(),
    CleanOpts = maps:remove(server, Opts),
    {ok, TaskId} = alTask:spawnAsk(Prompt, CleanOpts, fun(P, O) ->
        Tid = maps:get(taskId, O),
        alProgress:emit(Tid, #{
            type => step, phase => queue,
            message => <<"等待 Agent 处理请求..."/utf8>>
        }),
        ProgressOpts = maps:put(progressId, Tid, maps:remove(taskId, O)),
        %% 通过 alServer:ask 路由到 worker，阻塞等待结果
        case gen_server:call(Server, {ask, P, ProgressOpts#{taskId => Tid}}, 600000) of
            {ok, Ans} ->
                alProgress:finish(Tid, {ok, Ans}),
                {{ok, Ans}, #{}};
            {error, Err} ->
                alProgress:finish(Tid, {error, Err}),
                {{error, Err}, #{}}
        end
    end),
    {reply, {ok, TaskId}, State};

%% 直接执行工具
handle_call({run, Mod, Fun, Args}, _From, State) ->
    SessionId = maps:get(sessionId, effectiveConfig(State), State#state.defaultSession),
    {WorkerPid, NewState} = ensureWorker(SessionId, State),
    Result = alSessionWorker:run(WorkerPid, Mod, Fun, Args, effectiveConfig(State)),
    {reply, Result, NewState};

%% 批准/拒绝
handle_call({approve, TaskId}, _From, State) ->
    {Reply, NewState} = delegatePending(TaskId, State, fun(Pid, Tid) ->
        alSessionWorker:approve(Pid, Tid, effectiveConfig(State), State#state.mode,
                                State#state.workingContext)
    end),
    {reply, Reply, NewState};
handle_call({dismiss, TaskId}, _From, State) ->
    {Reply, NewState} = delegatePending(TaskId, State, fun(Pid, Tid) ->
        alSessionWorker:dismiss(Pid, Tid, effectiveConfig(State), State#state.mode,
                                State#state.workingContext)
    end),
    {reply, Reply, NewState};

%% 挂起任务查询
handle_call({pendingTask, TaskId}, _From, State) ->
    Reply = lists:foldl(fun(Pid, Acc) ->
        case Acc of
            {ok, _} -> Acc;
            _ -> alSessionWorker:pendingTask(Pid, TaskId)
        end
    end, {error, notFound}, maps:values(State#state.sessions)),
    {reply, Reply, State};
handle_call(pendingList, _From, State) ->
    All = lists:flatmap(fun(Pid) -> alSessionWorker:pendingList(Pid) end,
                        maps:values(State#state.sessions)),
    {reply, All, State};

%% 精准取消特定 taskId
handle_call({cancelTask, SessionId, TaskId}, _From, State) ->
    case maps:get(toBinary(SessionId), State#state.sessions, undefined) of
        undefined -> {reply, {error, sessionNotFound}, State};
        Pid -> {reply, alSessionWorker:cancelByTaskId(Pid, TaskId), State}
    end;

%% 内部：给 askAsync runner 获取 worker pid
handle_call({getWorker, SessionId}, _From, State) ->
    {WorkerPid, NewState} = ensureWorker(SessionId, State),
    {reply, {ok, WorkerPid}, NewState};

handle_call(status, _From, State) ->
    {reply, buildStatus(State), State};
handle_call(sessions, _From, State) ->
    SessionList = maps:map(fun(_Id, Pid) ->
        alSessionWorker:snapshot(Pid)
    end, State#state.sessions),
    {reply, SessionList, State};
handle_call(clearSession, _From, State) ->
    delegateDefault(State, fun(Pid) -> alSessionWorker:clearSession(Pid) end);
handle_call({clearSession, SessionId}, _From, State) ->
    {WorkerPid, NewState} = ensureWorker(SessionId, State),
    Reply = alSessionWorker:clearSession(WorkerPid),
    {reply, Reply, NewState};
handle_call(saveSession, _From, State) ->
    Sid = State#state.defaultSession,
    case maps:get(Sid, State#state.sessions, undefined) of
        undefined -> {reply, {error, sessionNotFound}, State};
        Pid -> {reply, alSessionWorker:saveSession(Pid, Sid), State}
    end;
handle_call({saveSession, SessionId}, _From, State) ->
    case maps:get(toBinary(SessionId), State#state.sessions, undefined) of
        undefined -> {reply, {error, sessionNotFound}, State};
        Pid -> {reply, alSessionWorker:saveSession(Pid, toBinary(SessionId)), State}
    end;
handle_call({loadSession, SessionId}, _From, State) ->
    BinId = toBinary(SessionId),
    {WorkerPid, NewState} = ensureWorker(BinId, State),
    Reply = alSessionWorker:loadSession(WorkerPid, BinId),
    {reply, Reply, NewState#state{defaultSession = BinId}};
handle_call({deleteSavedSession, SessionId}, _From, State) ->
    {reply, alSession:delete(toBinary(SessionId)), State};
handle_call(savedSessions, _From, State) ->
    {reply, alSession:list(), State};
handle_call({sessionMessages, SessionId}, _From, State) ->
    case maps:get(toBinary(SessionId), State#state.sessions, undefined) of
        undefined -> {reply, {error, sessionNotFound}, State};
        Pid -> {reply, alSessionWorker:sessionMessages(Pid), State}
    end;
handle_call(cancelAsk, _From, State) ->
    Results = [alSessionWorker:cancelAsk(Pid, all) || Pid <- maps:values(State#state.sessions)],
    Total = lists:sum([maps:get(cancelled, R, 0) || R <- Results]),
    {reply, #{ok => true, cancelled => Total}, State};
handle_call({cancelAsk, SessionId}, _From, State) ->
    case maps:get(toBinary(SessionId), State#state.sessions, undefined) of
        undefined -> {reply, #{ok => true, cancelled => 0}, State};
        Pid -> {reply, alSessionWorker:cancelAsk(Pid, all), State}
    end;
handle_call(getConfig, _From, State) ->
    {reply, effectiveConfig(State), State};
handle_call({setConfig, Key, Value}, _From, State) ->
    NewOverrides = maps:put(Key, Value, State#state.runtimeOverrides),
    NewState = case Key of
        mode when Value =:= ask; Value =:= edit; Value =:= exec ->
            State#state{runtimeOverrides = NewOverrides, mode = Value};
        _ -> State#state{runtimeOverrides = NewOverrides}
    end,
    {reply, ok, NewState};
handle_call(getMode, _From, State) ->
    {reply, State#state.mode, State};
handle_call({setMode, Mode}, _From, State) ->
    Valid = case Mode of ask -> true; edit -> true; exec -> true; _ -> false end,
    case Valid of
        true ->
            NewOverrides = maps:put(mode, Mode, State#state.runtimeOverrides),
            {reply, ok, State#state{mode = Mode, runtimeOverrides = NewOverrides}};
        false -> {reply, {error, invalidMode}, State}
    end;
handle_call(getWorkingContext, _From, State) ->
    {reply, State#state.workingContext, State};
handle_call({addContext, Type, Value}, _From, State) ->
    Ctx = State#state.workingContext,
    Key = context_key(Type),
    List = maps:get(Key, Ctx, []),
    NewCtx = maps:put(Key, lists:usort([Value | List]), Ctx),
    {reply, ok, State#state{workingContext = NewCtx}};
handle_call(clearContext, _From, State) ->
    {reply, ok, State#state{workingContext = defaultWorkingContext()}};
handle_call(_Request, _From, State) ->
    {reply, {error, unknownRequest}, State}.

%% Web SSE/WS 流式问答：不阻塞 alServer，由 session worker 向 Caller 推送分块。
handle_cast({askStreamAsync, Prompt, Opts, Caller}, State) ->
    SessionId = maps:get(sessionId, Opts, State#state.defaultSession),
    {WorkerPid, NewState} = ensureWorker(SessionId, State),
    alSessionWorker:askStream(WorkerPid, undefined, Prompt, Opts, Caller,
                              effectiveConfig(State), State#state.mode, State#state.workingContext),
    {noreply, NewState};
handle_cast(refreshConfig, State) ->
    Config = effectiveConfig(State),
    _ = try alCodeIndexer:refresh(Config) catch _:_ -> ok end,
    {noreply, State};
handle_cast(_Msg, State) -> {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%===================================================================
%%% 内部
%%%===================================================================

%% 按需启动 session worker（若已存在则复用）
ensureWorker(SessionId, State) ->
    BinId = toBinary(SessionId),
    case maps:get(BinId, State#state.sessions, undefined) of
        Pid when is_pid(Pid) ->
            {Pid, State};
        undefined ->
            {ok, Pid} = alSessionWorker:start_link(BinId, #{}),
            NewSessions = maps:put(BinId, Pid, State#state.sessions),
            {Pid, State#state{sessions = NewSessions}}
    end.

%% 对默认会话执行操作
delegateDefault(State, Fun) ->
    case maps:get(State#state.defaultSession, State#state.sessions, undefined) of
        undefined -> {reply, ok, State};
        Pid -> {reply, Fun(Pid), State}
    end.

%% approve/dismiss 委托：在所有 worker 中查找持有该 task 的 worker
delegatePending(TaskId, State, Fun) ->
    BinId = toBinary(TaskId),
    FindResult = lists:foldl(fun(Pid, Acc) ->
        case Acc of
            found -> found;
            _ ->
                case alSessionWorker:pendingTask(Pid, BinId) of
                    {ok, _} -> {ok, Pid};
                    _ -> Acc
                end
        end
    end, not_found, maps:values(State#state.sessions)),
    case FindResult of
        {ok, Pid} ->
            Reply = Fun(Pid, BinId),
            {Reply, State};
        not_found ->
            {{error, taskNotFound}, State}
    end.

buildStatus(State) ->
    Config = effectiveConfig(State),
    Snapshots = [alSessionWorker:snapshot(Pid) || {_, Pid} <- maps:to_list(State#state.sessions)],
    PendingTaskCount = lists:sum([maps:get(pendingTaskCount, S, 0) || S <- Snapshots]),
    #{
        running => true,
        node => node(),
        sessionCount => maps:size(State#state.sessions),
        pendingTaskCount => PendingTaskCount,
        savedSessionCount => length(alSession:list()),
        asyncTaskCount => length(alTask:list()),
        projectRoot => maps:get(projectRoot, Config, undefined),
        model => maps:get(model, Config, undefined),
        useNativeTools => maps:get(useNativeTools, Config, true),
        toolCount => length(alTools:listTools()),
        mode => State#state.mode,
        indexStats => alCodeIndexer:getStats(),
        workingContext => State#state.workingContext
    }.

defaultConfig() ->
    Root = case alToolProject:findProjectRootFromModule() of
        R when is_list(R) -> llmJson:text(R);
        R when is_binary(R) -> R;
        _ ->
            case file:get_cwd() of
                {ok, Cwd} -> llmJson:text(Cwd);
                {error, _} -> <<"."/utf8>>
            end
    end,
    #{
        projectRoot => Root,
        model => ?DEFAULT_MODEL,
        maxSteps => 25,
        maxMessages => 40,
        useNativeTools => true,
        policy => alPolicy:defaultPolicy(),
        modelOptions => [{temperature, 0.2}],
        execTimeout => 60000,
        toolTimeout => alConfig:get(toolTimeout),
        maxToolContent => alConfig:get(maxToolContent),
        llmMaxRetries => 2,
        historyCompaction => true
    }.

defaultWorkingContext() ->
    #{modules => [], files => [], processes => []}.

context_key(module) -> modules;
context_key(file) -> files;
context_key(process) -> processes;
context_key(<<"module"/utf8>>) -> modules;
context_key(<<"file"/utf8>>) -> files;
context_key(<<"process"/utf8>>) -> processes;
context_key(T) when is_atom(T) -> T;
context_key(T) when is_binary(T) -> binary_to_atom(T, utf8).

toBinary(X) when is_binary(X) -> X;
toBinary(X) when is_list(X) -> unicode:characters_to_binary(X);
toBinary(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).

effectiveConfig(State) ->
    effectiveConfig(State#state.runtimeOverrides, State#state.mode).

effectiveConfig(Overrides, Mode) ->
    Base = maps:merge(defaultConfig(), alConfig:getAgentConfig()),
    maps:merge(Base, maps:merge(Overrides, #{mode => Mode})).
