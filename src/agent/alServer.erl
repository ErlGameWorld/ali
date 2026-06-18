%%%-------------------------------------------------------------------
%%% @doc Agent 核心 gen_server。
%%%
%%% 管理多会话状态、配置、工作上下文，并将 ask/run 请求
%%% 委托给 {@link alLoop} 执行 LLM + 工具循环。
%%%
%%% 注册名：`alServer`。对外请通过 {@link ali} 模块调用，勿直接使用本模块。
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

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    config = defaultConfig(),
    sessions = #{},
    defaultSession = <<"default"/utf8>>,
    pendingTasks = #{},
    pendingAsks = #{},
    mode = ask,
    workingContext = #{modules => [], files => [], processes => []}
}).

-define(SERVER, alServer).

%% @doc 启动 Agent 服务（使用默认配置）。
-spec startLink() -> {ok, pid()} | {error, term()}.
startLink() ->
    startLink([]).

%% @doc 启动 Agent 服务，可传入初始选项覆盖默认配置。
%% @param Opts 配置项列表或 map，合并到默认配置
%% @returns `{ok, pid()}` 或 `{error, term()}`
-spec startLink(list() | map()) -> {ok, pid()} | {error, term()}.
startLink(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).

%% @doc 优雅停止 Agent gen_server。
-spec stop() -> ok.
stop() ->
    case whereis(?SERVER) of
        undefined -> ok;
        Pid -> gen_server:stop(Pid)
    end.

%% @doc 同步提问（使用默认会话与配置）。
%% @param Prompt 用户提示词（binary 或 string）
%% @returns `{ok, binary()}` 回答，或 `{error, term()}`
-spec ask(binary() | string()) -> {ok, binary()} | {error, term()}.
ask(Prompt) ->
    ask(Prompt, #{}).

%% @doc 同步提问，可指定会话 ID、模型等选项。
%% @param Prompt 用户提示词
%% @param Opts 选项 map，如 sessionId、model、progressId 等
%% @returns 同 ask/1
-spec ask(binary() | string(), map()) -> {ok, binary()} | {error, term()}.
ask(Prompt, Opts) when is_binary(Prompt); is_list(Prompt) ->
    gen_server:call(?SERVER, {ask, toBinary(Prompt), Opts}, infinity).

%% @doc 流式提问（使用默认选项），增量结果发送到调用进程。
%% @param Prompt 用户提示词
%% @returns 同 ask/1
-spec askStream(binary() | string()) -> {ok, binary()} | {error, term()}.
askStream(Prompt) ->
    askStream(Prompt, #{}).

%% @doc 流式提问，LLM 输出通过消息发送到调用进程。
%% @param Prompt 用户提示词
%% @param Opts 选项 map
%% @returns 同 ask/1
-spec askStream(binary() | string(), map()) -> {ok, binary()} | {error, term()}.
askStream(Prompt, Opts) when is_binary(Prompt); is_list(Prompt) ->
    gen_server:call(?SERVER, {askStream, toBinary(Prompt), Opts, self()}, infinity).

%% @doc 异步提问（使用默认选项），立即返回 TaskId。
%% @param Prompt 用户提示词
%% @returns `{ok, binary()}` TaskId
-spec askAsync(binary() | string()) -> {ok, binary()}.
askAsync(Prompt) ->
    askAsync(Prompt, #{}).

%% @doc 异步提问，通过 alTask 在后台执行，可用 taskStatus/1 查询结果。
%% @param Prompt 用户提示词
%% @param Opts 选项 map
%% @returns `{ok, binary()}` TaskId
-spec askAsync(binary() | string(), map()) -> {ok, binary()}.
askAsync(Prompt, Opts) when is_binary(Prompt); is_list(Prompt) ->
    gen_server:call(?SERVER, {askAsync, toBinary(Prompt), Opts}).

%% @doc 在当前会话中执行 Erlang 函数（callFunction 工具封装）。
%% @param {Mod, Fun, Args} 模块、函数名、参数列表
%% @returns 工具执行结果 `{ok, map()}` 或 `{error, term()}`
-spec run({module(), atom(), list()}) -> {ok, map()} | {error, term()}.
run({Mod, Fun, Args}) ->
    gen_server:call(?SERVER, {run, Mod, Fun, Args}, infinity).

%% @doc 批准待确认的高风险/写操作任务。
%% @param TaskId 待确认任务 ID（由 pending 响应中的 TaskId 提供）
%% @returns 工具执行结果
-spec approve(binary() | string()) -> {ok, map()} | {error, term()}.
approve(TaskId) ->
    gen_server:call(?SERVER, {approve, TaskId}, infinity).

%% @doc 返回 Agent 运行状态摘要（节点、会话数、模式、索引统计等）。
%% @returns `{map()}`
-spec status() -> map().
status() ->
    gen_server:call(?SERVER, status).

%% @doc 返回所有已注册工具的名称列表。
%% @returns `[atom()]`
-spec tools() -> [atom()].
tools() ->
    alTools:listTools().

%% @doc 返回内存中所有活跃会话的摘要信息。
%% @returns `{map()}` SessionId => #{id, messageCount, createdAt, updatedAt}
-spec sessions() -> map().
sessions() ->
    gen_server:call(?SERVER, sessions).

%% @doc 清空默认会话的消息历史。
%% @returns `ok`
-spec clearSession() -> ok.
clearSession() ->
    gen_server:call(?SERVER, clearSession).

%% @doc 清空指定会话的消息历史。
%% @param SessionId 会话标识
%% @returns `ok`
-spec clearSession(binary() | string()) -> ok.
clearSession(SessionId) ->
    gen_server:call(?SERVER, {clearSession, SessionId}).

%% @doc 将默认会话持久化到磁盘。
%% @returns `ok` 或 `{error, term()}`
-spec saveSession() -> ok | {error, term()}.
saveSession() ->
    gen_server:call(?SERVER, saveSession).

%% @doc 将指定会话持久化到磁盘。
%% @param SessionId 会话标识
%% @returns `ok` 或 `{error, term()}`
-spec saveSession(binary() | string()) -> ok | {error, term()}.
saveSession(SessionId) ->
    gen_server:call(?SERVER, {saveSession, SessionId}).

%% @doc 从磁盘加载会话并设为当前默认会话。
%% @param SessionId 会话标识
%% @returns `ok` 或 `{error, term()}`
-spec loadSession(binary() | string()) -> ok | {error, term()}.
loadSession(SessionId) ->
    gen_server:call(?SERVER, {loadSession, SessionId}).

%% @doc 删除磁盘上已保存的会话文件（不影响内存中的会话）。
%% @param SessionId 会话标识
%% @returns `ok` 或 `{error, term()}`
-spec deleteSavedSession(binary() | string()) -> ok | {error, term()}.
deleteSavedSession(SessionId) ->
    gen_server:call(?SERVER, {deleteSavedSession, SessionId}).

%% @doc 列举所有已保存到磁盘的会话 ID。
%% @returns `[binary()]`
-spec savedSessions() -> [binary()].
savedSessions() ->
    gen_server:call(?SERVER, savedSessions).

%% @doc 查询异步任务状态（委托 alTask:status/1）。
%% @param TaskId 任务标识
%% @returns `{ok, map()}` 或 `{error, notFound}`
-spec taskStatus(binary() | string()) -> {ok, map()} | {error, notFound}.
taskStatus(TaskId) ->
    alTask:status(TaskId).

%% @doc 取消正在运行的异步任务。
%% @param TaskId 任务标识
%% @returns `ok` 或 `{error, term()}`
-spec cancelTask(binary() | string()) -> ok | {error, term()}.
cancelTask(TaskId) ->
  alTask:cancel(TaskId).

%% @doc 返回所有异步任务列表。
%% @returns `[map()]`
-spec tasks() -> [map()].
tasks() ->
    alTask:list().

%% @doc 获取当前 Agent 配置 map。
%% @returns `{map()}`
-spec getConfig() -> map().
getConfig() ->
    gen_server:call(?SERVER, getConfig).

%% @doc 设置单个配置项。
%% @param Key 配置键（atom）
%% @param Value 配置值
%% @returns `ok`
-spec setConfig(atom(), term()) -> ok.
setConfig(Key, Value) ->
    gen_server:call(?SERVER, {setConfig, Key, Value}).

%% @doc 获取当前运行模式（ask / edit / exec）。
%% @returns `{atom()}`
-spec getMode() -> ask | edit | exec.
getMode() ->
    gen_server:call(?SERVER, getMode).

%% @doc 设置运行模式。
%% @param Mode ask | edit | exec
%% @returns `ok` 或 `{error, invalidMode}`
-spec setMode(ask | edit | exec) -> ok | {error, invalidMode}.
setMode(Mode) ->
    gen_server:call(?SERVER, {setMode, Mode}).

%% @doc 获取当前工作上下文（关注的模块、文件、进程列表）。
%% @returns `{map()}`
-spec getWorkingContext() -> map().
getWorkingContext() ->
    gen_server:call(?SERVER, getWorkingContext).

%% @doc 向工作上下文添加一项（module / file / process）。
%% @param Type 上下文类型
%% @param Value 要添加的值
%% @returns `ok`
-spec addContext(atom() | binary(), term()) -> ok.
addContext(Type, Value) ->
    gen_server:call(?SERVER, {addContext, Type, Value}).

%% @doc 清空工作上下文。
%% @returns `ok`
-spec clearContext() -> ok.
clearContext() ->
    gen_server:call(?SERVER, clearContext).

%% gen_server 初始化：创建审计/任务表、合并配置、预热代码索引
init(Opts) ->
    alAudit:init(),
    alTask:init(),
    Config = maps:merge(
        maps:merge(defaultConfig(), llmCliConfig:getAgentConfig()),
        maps:from_list(Opts)
    ),
    DefaultSession = maps:get(defaultSession, Config, <<"default"/utf8>>),
    Session = newSession(DefaultSession),
    _ = catch alCodeIndexer:refresh(Config),
    {ok, #state{
        config = Config,
        defaultSession = DefaultSession,
        sessions = maps:put(DefaultSession, Session, #{}),
        mode = maps:get(mode, Config, ask),
        workingContext = defaultWorkingContext()
    }}.

%% 同步 ask：异步 worker 执行 LLM 循环，通过 gen_server:reply 返回
handle_call({ask, Prompt, Opts}, From, State) ->
    doAskAsync(Prompt, Opts, State, From, undefined);
%% 流式 ask：增量输出发送到 Caller 进程
handle_call({askStream, Prompt, Opts, Caller}, From, State) ->
    doAskAsync(Prompt, Opts, State, From, Caller);
%% 异步 ask：spawn alTask worker，立即返回 TaskId
handle_call({askAsync, Prompt, Opts}, _From, State) ->
    Server = self(),
    CleanOpts = maps:remove(server, Opts),
    {ok, TaskId} = alTask:spawnAsk(Prompt, CleanOpts, fun(P, O) ->
        Tid = maps:get(taskId, O),
        alProgress:emit(Tid, #{
            type => step,
            phase => queue,
            message => <<"等待 Agent 处理请求..."/utf8>>
        }),
        ProgressOpts = maps:put(progressId, Tid, maps:remove(taskId, O)),
        %% 设置 10 分钟超时，防止 gen_server 故障时 worker 永久挂起
        case gen_server:call(Server, {ask, P, ProgressOpts}, 600000) of
            {ok, Ans} ->
                alProgress:finish(Tid, {ok, Ans}),
                {{ok, Ans}, #{}};
            {error, Err} ->
                alProgress:finish(Tid, {error, Err}),
                {{error, Err}, #{}}
        end
    end),
    {reply, {ok, TaskId}, State};
%% 直接执行 callFunction 工具
handle_call({run, Mod, Fun, Args}, _From, State) ->
    Config = State#state.config,
    SessionId = maps:get(sessionId, Config, State#state.defaultSession),
    Result = alTools:execute(
        callFunction,
        #{module => Mod, function => Fun, args => Args},
        Config,
        SessionId
    ),
    {reply, Result, State};
%% 用户确认后执行挂起的写/高风险操作
handle_call({approve, TaskId}, _From, State) ->
    {Reply, NewState} = doApprove(TaskId, State),
    {reply, Reply, NewState};
handle_call(status, _From, State) ->
    {reply, buildStatus(State), State};
handle_call(sessions, _From, State) ->
    SessionList = maps:map(fun(_Id, S) ->
        #{
            id => maps:get(id, S),
            messageCount => length(maps:get(messages, S, [])),
            createdAt => maps:get(createdAt, S),
            updatedAt => maps:get(updatedAt, S)
        }
    end, State#state.sessions),
    {reply, SessionList, State};
handle_call(clearSession, _From, State) ->
    Sid = State#state.defaultSession,
    {reply, ok, resetSession(Sid, State)};
handle_call({clearSession, SessionId}, _From, State) ->
    {reply, ok, resetSession(SessionId, State)};
handle_call(saveSession, _From, State) ->
    Sid = State#state.defaultSession,
    {Reply, NewState} = doSaveSession(Sid, State),
    {reply, Reply, NewState};
handle_call({saveSession, SessionId}, _From, State) ->
    {Reply, NewState} = doSaveSession(SessionId, State),
    {reply, Reply, NewState};
handle_call({loadSession, SessionId}, _From, State) ->
    {Reply, NewState} = doLoadSession(SessionId, State),
    {reply, Reply, NewState};
handle_call({deleteSavedSession, SessionId}, _From, State) ->
    {reply, alSession:delete(toBinary(SessionId)), State};
handle_call(savedSessions, _From, State) ->
    {reply, alSession:list(), State};
handle_call(getConfig, _From, State) ->
    {reply, State#state.config, State};
handle_call({setConfig, Key, Value}, _From, State) ->
    NewConfig = maps:put(Key, Value, State#state.config),
    {reply, ok, State#state{config = NewConfig}};
handle_call(getMode, _From, State) ->
    {reply, State#state.mode, State};
handle_call({setMode, Mode}, _From, State) ->
    Valid = case Mode of ask -> true; edit -> true; exec -> true; _ -> false end,
    case Valid of
        true -> {reply, ok, State#state{mode = Mode}};
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

handle_cast({askStreamAsync, Prompt, Opts, Caller}, State) ->
    doAskAsync(Prompt, Opts, State, undefined, Caller),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

%% alTask worker 完成通知（由 askAsync 路径产生，此处仅忽略）
handle_info({alTask, _TaskId, _Result}, State) ->
    {noreply, State};
%% ask worker 完成：更新会话并 reply 等待中的 gen_server:call
handle_info({askResult, Ref, RunResult, SessionId}, State) ->
    case maps:take(Ref, State#state.pendingAsks) of
        {{From, _Sid}, NewPending} ->
            {Reply, NewState} = handleAskResult(RunResult, SessionId, State),
            gen_server:reply(From, Reply),
            {noreply, NewState#state{pendingAsks = NewPending}};
        error ->
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% 异步执行 ask，不阻塞 gen_server 邮箱。
%% 启动 worker 进程执行 LLM 调用，通过 gen_server:reply 异步返回结果。
%% @param StreamPid undefined 为同步模式；Pid 为流式输出目标进程
doAskAsync(Prompt, Opts, State, From, StreamPid) ->
    Config = mergeAskConfig(State#state.config, Opts),
    SessionId = maps:get(sessionId, Opts, State#state.defaultSession),
    AskConfig = applySessionTuning(Config#{
        mode => State#state.mode,
        workingContext => State#state.workingContext
    }, SessionId),
    emit_progress(AskConfig, #{
        type => step,
        phase => prepare,
        message => <<"准备会话与系统提示..."/utf8>>
    }),
    {Session, State1} = ensureSession(SessionId, State),
    History = maps:get(messages, Session, []),
    Messages = alContext:buildMessages(AskConfig, History, Prompt),
    emit_progress(AskConfig, #{
        type => step,
        phase => ready,
        message => <<"上下文就绪，开始推理..."/utf8>>
    }),
    Model = maps:get(model, AskConfig, <<"gpt-4o-mini"/utf8>>),
    Server = self(),
    Ref = make_ref(),
    spawn(fun() ->
        RunResult = case StreamPid of
            undefined ->
                alLoop:run(Model, Messages, AskConfig, SessionId);
            Pid ->
                alLoop:runStream(Model, Messages, AskConfig, SessionId, Pid)
        end,
        Server ! {askResult, Ref, RunResult, SessionId}
    end),
    PendingAsks = maps:put(Ref, {From, SessionId}, State1#state.pendingAsks),
    {noreply, State1#state{pendingAsks = PendingAsks}}.

%% 处理 alLoop 返回结果：更新会话消息，或登记待确认任务
handleAskResult(RunResult, SessionId, State) ->
    Session = maps:get(SessionId, State#state.sessions, newSession(SessionId)),
    case RunResult of
        {ok, Answer, UpdatedMessages} ->
            Now = erlang:system_time(millisecond),
            Conversation = alContext:conversationHistory(UpdatedMessages),
            NewSession = Session#{
                messages => Conversation,
                updatedAt => Now
            },
            Sessions = maps:put(SessionId, NewSession, State#state.sessions),
            {{ok, Answer}, State#state{sessions = Sessions}};
        {pending, Pending, UpdatedMessages} ->
            TaskId = maps:get(taskId, Pending),
            Now = erlang:system_time(millisecond),
            Conversation = alContext:conversationHistory(UpdatedMessages),
            NewSession = Session#{
                messages => Conversation,
                updatedAt => Now
            },
            PendingTasks = maps:put(TaskId, Pending, State#state.pendingTasks),
            Sessions = maps:put(SessionId, NewSession, State#state.sessions),
            Msg = iolist_to_binary([
                <<"Operation requires confirmation. TaskId: "/utf8>>,
                TaskId,
                <<". Call ali:approve(\""/utf8>>, TaskId, <<"\") to proceed."/utf8>>
            ]),
            {{ok, Msg}, State#state{sessions = Sessions, pendingTasks = PendingTasks}};
        {error, Reason} ->
            {{error, Reason}, State}
    end.

%% 将内存会话写入磁盘
doSaveSession(SessionId, State) ->
    BinId = toBinary(SessionId),
    case maps:get(BinId, State#state.sessions, undefined) of
        undefined ->
            {{error, sessionNotFound}, State};
        Session ->
            case alSession:save(BinId, Session) of
                ok -> {{ok, ok}, State};
                {error, Reason} -> {{error, Reason}, State}
            end
    end.

%% 从磁盘加载会话到内存并设为默认会话
doLoadSession(SessionId, State) ->
    BinId = toBinary(SessionId),
    case alSession:load(BinId) of
        {ok, Session} ->
            Sessions = maps:put(BinId, Session, State#state.sessions),
            {{ok, ok}, State#state{sessions = Sessions, defaultSession = BinId}};
        {error, Reason} ->
            {{error, Reason}, State}
    end.

%% 执行用户已批准的挂起工具调用
doApprove(TaskId, State) ->
    BinId = toBinary(TaskId),
    case maps:get(BinId, State#state.pendingTasks, undefined) of
        undefined ->
            {{error, taskNotFound}, State};
        Pending ->
            Tool = maps:get(tool, Pending),
            Args = maps:get(args, Pending),
            SessionId = maps:get(sessionId, Pending),
            Config = State#state.config,
            Context = #{confirmed => true},
            case alTools:execute(Tool, Args, Config, SessionId, Context) of
                {ok, Result} ->
                    PendingTasks = maps:remove(BinId, State#state.pendingTasks),
                    {{ok, Result}, State#state{pendingTasks = PendingTasks}};
                {error, Reason} ->
                    {{error, Reason}, State}
            end
    end.

%% 确保会话存在于 state.sessions 中，不存在则创建
ensureSession(SessionId, State) ->
    case maps:get(SessionId, State#state.sessions, undefined) of
        undefined ->
            Session = newSession(SessionId),
            Sessions = maps:put(SessionId, Session, State#state.sessions),
            {Session, State#state{sessions = Sessions}};
        Session ->
            {Session, State}
    end.

%% 重置指定会话为空消息历史
resetSession(SessionId, State) ->
    Session = newSession(SessionId),
    Sessions = maps:put(SessionId, Session, State#state.sessions),
    State#state{sessions = Sessions}.

%% 创建新的空会话记录
newSession(SessionId) ->
    Now = erlang:system_time(millisecond),
    #{
        id => SessionId,
        messages => [],
        createdAt => Now,
        updatedAt => Now
    }.

%% 组装 status/0 返回的状态 map
buildStatus(State) ->
    #{
        running => true,
        node => node(),
        sessionCount => maps:size(State#state.sessions),
        pendingTaskCount => maps:size(State#state.pendingTasks),
        savedSessionCount => length(alSession:list()),
        asyncTaskCount => length(alTask:list()),
        projectRoot => maps:get(projectRoot, State#state.config, undefined),
        model => maps:get(model, State#state.config, undefined),
        useNativeTools => maps:get(useNativeTools, State#state.config, true),
        toolCount => length(alTools:listTools()),
        mode => State#state.mode,
        indexStats => alCodeIndexer:get_stats(),
        workingContext => State#state.workingContext
    }.

%% 构建默认 Agent 配置（项目根、模型、步数上限、策略等）
defaultConfig() ->
    Root = case alToolProject:findProjectRootFromModule() of
        R when is_list(R) -> list_to_binary(R);
        R when is_binary(R) -> R;
        _ ->
            case file:get_cwd() of
                {ok, Cwd} -> list_to_binary(Cwd);
                {error, _} -> <<"."/utf8>>
            end
    end,
    #{
        projectRoot => Root,
        model => <<"gpt-4o-mini"/utf8>>,
        maxSteps => 25,
        maxMessages => 40,
        useNativeTools => true,
        policy => alPolicy:defaultPolicy(),
        modelOptions => [{temperature, 0.2}],
        execTimeout => 60000
    }.

%% 将 ask 调用时的 Opts 合并到基础 Config
mergeAskConfig(Config, Opts) when is_map(Opts) ->
    maps:merge(Config, Opts);
mergeAskConfig(Config, Opts) when is_list(Opts) ->
    maps:merge(Config, maps:from_list(Opts)).

%% 按会话 ID 微调配置（如 web 会话提高 maxSteps）
applySessionTuning(Config, SessionId) ->
    case SessionId of
        <<"web"/utf8>> ->
            Steps = maps:get(maxSteps, Config, 25),
            Config#{maxSteps => max(Steps, 40)};
        _ ->
            Config
    end.

%% 若 Opts 含 progressId 则向 alProgress 发送进度事件
emit_progress(Config, Event) ->
    case maps:get(progressId, Config, undefined) of
        undefined -> ok;
        Id -> alProgress:emit(Id, Event)
    end.

%% 将 binary、list 或其他 term 统一转为 binary
toBinary(X) when is_binary(X) -> X;
toBinary(X) when is_list(X) -> unicode:characters_to_binary(X);
toBinary(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).

%% 返回空的工作上下文结构
defaultWorkingContext() ->
    #{modules => [], files => [], processes => []}.

%% 将 module/file/process 类型（atom 或 binary）映射为上下文 map 的键
context_key(module) -> modules;
context_key(file) -> files;
context_key(process) -> processes;
context_key(<<"module"/utf8>>) -> modules;
context_key(<<"file"/utf8>>) -> files;
context_key(<<"process"/utf8>>) -> processes;
context_key(T) when is_atom(T) -> T;
context_key(T) when is_binary(T) -> binary_to_atom(T, utf8).