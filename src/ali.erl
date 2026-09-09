%%%-------------------------------------------------------------------
%% @doc 面向 Erlang 运行时感知的 AI 助手公共 API。
%% @end
%%%-------------------------------------------------------------------

-module(ali).

-export([
    addPaths/1,
    start/0,
    start/1,
    stop/0,
    prepare/0,
    prepare/1,
    ready/0,
    httpStatus/0,
    httpRestart/0,
    ask/1,
    ask/2,
    chat/0,
    chat/1,
    askStream/1, askStream/2,
    askAsync/1,
    askAsync/2,
    agent/1,
    agent/2,
    approve/1,
    dismiss/1,
    pendingTask/1,
    pendingList/0,
    listCheckpoints/0,
    resumeCheckpoint/1,
    resumeCheckpoint/2,
    deleteCheckpoint/1,
    createSession/1,
    getSession/1,
    clearSession/0,
    clearSession/1,
    saveSession/0,
    saveSession/1,
    loadSession/1,
    savedSessions/0,
    sessionMessages/1,
    cancelAsk/0,
    cancelAsk/1,
    taskStatus/1,
    cancelTask/1,
    tasks/0,
    serverStatus/0,
    serverSessions/0,
    getConfig/0,
    setConfig/2,
    getMode/0,
    setMode/1,
    getWorkingContext/0,
    addContext/2,
    clearContext/0,
    health/0,
    plan/2,
    mcpConnect/1,
    mcpDisconnect/1,
    mcpListTools/1,
    index/0,
    index/1,
    indexRoots/0,
    indexRoots/1,
    ensureIndex/0,
    restartCore/0,
    search/1,
    search/2,
    getSymbol/3,
    moduleSymbols/1,
    resolveModule/1,
    gotoDef/3,
    findRefs/3,
    callGraph/0,
    getCallers/3,
    getCallees/3,
    embeddingSchema/0,
    runtime/0,
    coreHealth/0,
    coreStatus/0,
    qdrantStatus/0,
    processes/1,
    etsTables/1,
    tools/0,
    toolSpec/1,
    listTransactions/0,
    listRecentSimulations/1,
    recent/2,
    searchTags/1,
    callTool/2,
    validatePatch/1,
    dryRunPatch/1,
    applyPatch/1,
    applyPatchBatch/1,
    rollbackPatch/0,
    dbQuery/1,
    dbStatus/0,
    remember/3,
    remember/4,
    userProfile/0,
    userProfile/1,
    recall/1,
    recall/2,
    recallSemantic/1,
    recallSemantic/2,
    forget/1,
    rebuildMemoryIndex/0,
    rebuildMemoryIndex/1,
    distill/1,
    distill/2,
    simulate/1,
    supervisorTree/0,
    metrics/0,
    auditLog/0,
    auditLog/1
]).

-define(DefaultSearchLimit, 8).
-define(DefaultPrepareWaitMs, 120000).

%%%===================================================================
%%% Embed lifecycle（嵌入其它 Erlang 项目）
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 把 release 目录下 `lib/*/ebin` 加入 code path（不启动 boot 脚本）。
%% 典型用法：先 `rebar3 as prod release`，把 `_build/prod/rel/ali`
%% 拷到独立目录，再在宿主项目里调用本函数。
%%
%% @param RootDir release 根目录（含 `lib/`）
%% @return {ok, [EbinPath]} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec addPaths(file:name_all()) -> {ok, [string()]} | {error, term()}.
addPaths(RootDir0) ->
    RootDir = toList(RootDir0),
    Pattern = filename:join([RootDir, "lib", "*", "ebin"]),
    Paths = [filename:absname(P) || P <- filelib:wildcard(Pattern)],
    case Paths of
        [] ->
            {error, {noEbinDirs, Pattern}};
        _ ->
            case code:add_paths(Paths) of
                ok ->
                    logger:info("ali:addPaths loaded ~p ebin dirs from ~s", [length(Paths), RootDir]),
                    {ok, Paths};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 启动 ali 应用（从 cwd / ALI_CFG / 默认路径加载配置）。
%% 等价于 {@link start/1} 传入 `#{}`。
%%
%% @return {ok, StartedApps} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec start() -> {ok, [atom()]} | {error, term()}.
start() ->
    start(#{}).

%%--------------------------------------------------------------------
%% @doc
%% 启动 ali（嵌入宿主项目用）。
%%
%% Opts：
%% - `release` | `root` — release 根目录，启动前自动 {@link addPaths/1}
%% - `cfg` — `aliCfg.cfg` 路径（也可用环境变量 `ALI_CFG`）
%% - `prepare` — `true`（默认）启动后调用 {@link prepare/1}；`false` 跳过
%% - `waitIndex` — `true` 时阻塞直到索引就绪或超时（默认 `false`，仅触发后台索引）
%% - `waitMs` — 等待索引超时毫秒（默认 120000）
%%
%% 流程：addPaths → 设置 cfg → ensure_all_started(ali) → prepare。
%% 应用启动时若 `core.indexBackground=true` 会异步建索引；
%% `waitIndex=true` 可改成等索引完成。
%%
%% @param Opts 选项 map
%% @return {ok, StartedApps} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec start(map()) -> {ok, [atom()]} | {error, term()}.
start(Opts) when is_map(Opts) ->
    case maybeAddReleasePaths(Opts) of
        ok ->
            case maybeSetCfg(Opts) of
                ok ->
                    case application:ensure_all_started(ali) of
                        {ok, Started} ->
                            case maybePrepareAfterStart(Opts) of
                                ok -> {ok, Started};
                                {error, _} = Err -> Err
                            end;
                        {error, {already_started, ali}} ->
                            case maybePrepareAfterStart(Opts) of
                                ok -> {ok, [ali]};
                                {error, _} = Err -> Err
                            end;
                        {error, _} = Err ->
                            Err
                    end;
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

%%--------------------------------------------------------------------
%% @doc
%% 停止 ali 应用（关闭 supervisor、aliCore/qdrant port）。
%% 不停止宿主节点，也不移除 code path。
%% Windows 上 terminate 会按 OS PID 强制结束残留的 exe。
%%
%% @return ok | {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec stop() -> ok | {error, term()}.
stop() ->
    CorePid = try alCoreClient:childOsPid() catch _:_ -> undefined end,
    QdrantPid = try alQdrant:childOsPid() catch _:_ -> undefined end,
    Result = case application:stop(ali) of
        ok -> ok;
        {error, {not_started, ali}} -> ok;
        {error, _} = Err -> Err
    end,
    %% 兜底：若 terminate 后仍有残留，再杀一次记住的 PID
    _ = [alOsProc:forceKill(P) || P <- [CorePid, QdrantPid], is_integer(P)],
    Result.

%%--------------------------------------------------------------------
%% @doc
%% 准备运行环境：确保 core 可用，并（按配置）触发/等待代码索引。
%% 等价于 {@link prepare/1} 传入 `#{}`。
%%
%% @return ok | {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec prepare() -> ok | {error, term()}.
prepare() ->
    prepare(#{}).

%%--------------------------------------------------------------------
%% @doc
%% 准备运行环境。
%%
%% Opts：
%% - `index` — `true`（默认）对 {@link alConfig:codeRoots/0} 建索引；
%%   `false` 跳过；`wait` 同步建索引并等到完成
%% - `waitMs` — 等待超时（仅 `index := wait` 或与 start 的 waitIndex 联用）
%%
%% @param Opts 选项 map
%% @return ok | {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec prepare(map()) -> ok | {error, term()}.
prepare(Opts) when is_map(Opts) ->
    %% 状态已在 ali_app:start 打过一次，这里 quiet，避免重复刷屏
    _ = alCoreClient:ensureAvailable(#{quiet => true}),
    _ = alDbAdapter:ensureStarted(),
    case maps:get(index, Opts, true) of
        false ->
            ok;
        ensure ->
            case alCoreClient:ensureIndex() of
                {ok, Res} ->
                    logIndexKickoff(Res),
                    ok;
                {error, _} = Err ->
                    Err
            end;
        wait ->
            case indexRoots() of
                {ok, _} ->
                    waitIndexReady(maps:get(waitMs, Opts, ?DefaultPrepareWaitMs));
                {error, _} = Err ->
                    Err
            end;
        true ->
            Roots = alConfig:codeRoots(),
            _ = alCoreClient:indexAsyncRoots(Roots),
            logIndexKickoff(#{action => started, roots => Roots}),
            ok
    end.

logIndexKickoff(#{action := skip, status := St}) ->
    Files = maps:get(files, St, maps:get(<<"files">>, St, 0)),
    io:format("索引已存在 files=~p，跳过重复全量索引~n", [Files]),
    ok;
logIndexKickoff(#{action := in_progress, roots := Roots, status := St}) ->
    Walk = maps:get(walk_seen, St, maps:get(<<"walk_seen">>, St, 0)),
    Root = maps:get(last_index_root, St, maps:get(<<"last_index_root">>, St, <<>>)),
    io:format("索引进行中 walk_seen=~p root=~ts~ncodeRoots:~n", [Walk, Root]),
    lists:foreach(fun(R) -> io:format("  - ~ts~n", [R]) end, Roots),
    ok;
logIndexKickoff(#{roots := Roots} = Res) ->
    Action = maps:get(action, Res, started),
    io:format("后台索引 ~p，codeRoots=~n", [Action]),
    lists:foreach(fun(R) -> io:format("  - ~ts~n", [R]) end, Roots),
    case Roots of
        [Only] ->
            case string:find(unicode:characters_to_list(Only), "boot") of
                nomatch -> ok;
                _ ->
                    io:format("提示: 当前索引根含 boot/；若要搜整仓请在 aliCfg.cfg 设置~n"
                              "  agent.projectRoot => \"g:/sg/develop\"~n"
                              "  或 codeRoots => [\"g:/sg/develop\"]~n")
            end;
        _ ->
            ok
    end,
    ok;
logIndexKickoff(_) ->
    ok.

%%--------------------------------------------------------------------
%% @doc
%% 返回嵌入就绪状态：配置、core、索引、db、web。
%% `ready := true` 表示至少配置已加载且应用已启动；
%% `indexReady` 表示索引可用（core 或 fallback）。
%%
%% @return map()
%% @end
%%--------------------------------------------------------------------
-spec ready() -> map().
ready() ->
    AppStarted = lists:keymember(ali, 1, application:which_applications()),
    CoreAvail = try alCoreClient:available() catch _:_ -> false end,
    Index = try indexReadyInfo() catch _:_ -> #{ready => false, reason => unavailable} end,
    Db = try dbStatus() catch _:_ -> #{error => unavailable} end,
    Http = try alHttpGateway:status() catch _:_ -> #{error => unavailable} end,
    #{
        ready => AppStarted,
        app => AppStarted,
        root => try alConfig:root() catch _:_ -> undefined end,
        projectRoot => try alConfig:projectRoot() catch _:_ -> undefined end,
        codeRoots => try alConfig:codeRoots() catch _:_ -> [] end,
        dataDir => try alConfig:dataDir() catch _:_ -> undefined end,
        privDir => try alConfig:privDir() catch _:_ -> undefined end,
        coreAvailable => CoreAvail,
        index => Index,
        indexReady => maps:get(ready, Index, false),
        db => Db,
        http => Http
    }.

maybeAddReleasePaths(Opts) ->
    case maps:get(release, Opts, maps:get(root, Opts, undefined)) of
        undefined -> ok;
        Dir ->
            case addPaths(Dir) of
                {ok, _} -> ok;
                {error, _} = Err -> Err
            end
    end.

maybeSetCfg(Opts) ->
    case maps:get(cfg, Opts, undefined) of
        undefined ->
            ok;
        Path0 ->
            Path = toList(Path0),
            case filelib:is_regular(Path) of
                true ->
                    _ = application:load(ali),
                    ok = application:set_env(ali, cfg, filename:absname(Path)),
                    ok;
                false ->
                    {error, {cfgNotFound, Path}}
            end
    end.

maybePrepareAfterStart(Opts) ->
    case maps:get(prepare, Opts, true) of
        false ->
            _ = maybeEnsureHttp(),
            ok;
        true ->
            PrepOpts = case maps:get(waitIndex, Opts, false) of
                true ->
                    #{index => wait, waitMs => maps:get(waitMs, Opts, ?DefaultPrepareWaitMs)};
                false ->
                    %% 启动时 ali_app 可能已触发后台索引；若 files 仍为 0 则再补一次。
                    #{index => ensure}
            end,
            case prepare(PrepOpts) of
                ok ->
                    _ = maybeEnsureHttp(),
                    ok;
                {error, _} = Err ->
                    Err
            end
    end.

%% 配置启用 Web 时确保端口在听（already_started / 上次 bind 失败均可恢复）。
maybeEnsureHttp() ->
    try
        case alHttpGateway:enabled() of
            true -> alHttpGateway:ensureListening();
            false -> #{ok => false, reason => disabled}
        end
    catch
        _:_ -> #{ok => false, reason => unavailable}
    end.

%%--------------------------------------------------------------------
%% @doc 查看 HTTP/Web 监听状态。
%% @end
%%--------------------------------------------------------------------
-spec httpStatus() -> map().
httpStatus() ->
    try alHttpGateway:status() catch _:_ -> #{error => unavailable} end.

%%--------------------------------------------------------------------
%% @doc 重启 HTTP 网关并重新绑定端口（端口被旧进程占用时可先杀旧 erl）。
%% @end
%%--------------------------------------------------------------------
-spec httpRestart() -> map().
httpRestart() ->
    try alHttpGateway:restart() catch C:R -> #{ok => false, reason => {C, R}} end.

waitIndexReady(WaitMs) when is_integer(WaitMs), WaitMs >= 0 ->
    Deadline = erlang:monotonic_time(millisecond) + WaitMs,
    waitIndexReadyLoop(Deadline).

waitIndexReadyLoop(Deadline) ->
    case indexReadyInfo() of
        #{ready := true} ->
            ok;
        _ ->
            Now = erlang:monotonic_time(millisecond),
            case Now >= Deadline of
                true ->
                    {error, {indexTimeout, indexReadyInfo()}};
                false ->
                    timer:sleep(500),
                    waitIndexReadyLoop(Deadline)
            end
    end.

indexReadyInfo() ->
    case alCoreClient:indexStatus() of
        {ok, #{data := Data}} when is_map(Data) ->
            Data#{ready => maps:get(ready, Data, false)};
        {ok, Data} when is_map(Data) ->
            Data#{ready => maps:get(ready, Data, maps:get(<<"ready">>, Data, false))};
        {error, Reason} ->
            #{ready => false, reason => Reason}
    end.

toList(V) when is_list(V) -> V;
toList(V) when is_binary(V) -> unicode:characters_to_list(V);
toList(V) when is_atom(V) -> atom_to_list(V);
toList(V) -> lists:flatten(io_lib:format("~p", [V])).

%%--------------------------------------------------------------------
%% @doc
%% 向 AI 助手提问（使用默认选项）
%%
%% @param Question 用户的提问内容
%% @return AI 助手的回答结果
%% @end
%%--------------------------------------------------------------------
ask(Question) ->
    ask(Question, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 向 AI 助手提问（带选项）
%%
%% @param Question 用户的提问内容
%% @param Opts 选项映射，可包含 sessionId、autoSession 等
%% @return AI 助手的回答结果
%% @end
%%--------------------------------------------------------------------
ask(Question, Opts) ->
    alServer:ask(Question, ensureSessionOpts(Opts)).

%%--------------------------------------------------------------------
%% @doc
%% 启动交互式聊天会话（使用默认选项）
%%
%% @return 聊天会话的最终结果
%% @end
%%--------------------------------------------------------------------
chat() ->
    alChat:chat().

%%--------------------------------------------------------------------
%% @doc
%% 启动交互式聊天会话（带选项）
%%
%% @param Opts 聊天选项
%% @return 聊天会话的最终结果
%% @end
%%--------------------------------------------------------------------
chat(Opts) ->
    alChat:chat(Opts).

%%--------------------------------------------------------------------
%% @doc
%% 以流式方式向 AI 提问（使用默认选项）
%%
%% @param Question 用户的提问内容
%% @return 流式输出的结果
%% @end
%%--------------------------------------------------------------------
askStream(Question) ->
    askStream(Question, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 以流式方式向 AI 提问（带选项），结果会按块逐步返回
%%
%% @param Question 用户的提问内容
%% @param Opts 选项映射
%% @return 流式输出的结果
%% @end
%%--------------------------------------------------------------------
askStream(Question, Opts) ->
    alServer:askStream(Question, ensureSessionOpts(Opts)).

%%--------------------------------------------------------------------
%% @doc
%% 异步向 AI 提问（使用默认选项），立即返回任务引用
%%
%% @param Question 用户的提问内容
%% @return 异步任务句柄或任务 ID
%% @end
%%--------------------------------------------------------------------
askAsync(Question) ->
    askAsync(Question, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 异步向 AI 提问（带选项），立即返回任务引用，结果通过后续查询获取
%%
%% @param Question 用户的提问内容
%% @param Opts 选项映射
%% @return 异步任务句柄或任务 ID
%% @end
%%--------------------------------------------------------------------
askAsync(Question, Opts) ->
    alServer:askAsync(Question, ensureSessionOpts(Opts)).

%%--------------------------------------------------------------------
%% @doc
%% 批准待执行的敏感任务，使其继续执行
%%
%% @param TaskId 待批准任务的 ID
%% @return 批准操作的结果
%% @end
%%--------------------------------------------------------------------
approve(TaskId) ->
    alServer:approve(TaskId).

%%--------------------------------------------------------------------
%% @doc
%% 忽略（驳回）待执行的敏感任务
%%
%% @param TaskId 待忽略任务的 ID
%% @return 忽略操作的结果
%% @end
%%--------------------------------------------------------------------
dismiss(TaskId) ->
    alServer:dismiss(TaskId).

%%--------------------------------------------------------------------
%% @doc
%% 查询指定待处理任务的详情
%%
%% @param TaskId 任务 ID
%% @return 任务详情
%% @end
%%--------------------------------------------------------------------
pendingTask(TaskId) ->
    alServer:pendingTask(TaskId).

%%--------------------------------------------------------------------
%% @doc
%% 列出所有待处理任务
%%
%% @return 待处理任务列表
%% @end
%%--------------------------------------------------------------------
pendingList() ->
    alServer:pendingList().

%%--------------------------------------------------------------------
%% @doc List unfinished agent checkpoints (task ids).
%% @end
%%--------------------------------------------------------------------
listCheckpoints() ->
    alCheckpoint:list().

%%--------------------------------------------------------------------
%% @doc Resume an agent run from a saved checkpoint.
%% @end
%%--------------------------------------------------------------------
resumeCheckpoint(TaskId) ->
    resumeCheckpoint(TaskId, undefined).

resumeCheckpoint(TaskId, ApprovedContent) ->
    alToolRouter:resumeFromCheckpoint(checkpointId(TaskId), ApprovedContent).

%%--------------------------------------------------------------------
%% @doc Delete a saved checkpoint.
%% @end
%%--------------------------------------------------------------------
deleteCheckpoint(TaskId) ->
    alCheckpoint:delete(checkpointId(TaskId)).

checkpointId(Id) when is_binary(Id) -> Id;
checkpointId(Id) when is_list(Id) -> unicode:characters_to_binary(Id);
checkpointId(Id) when is_integer(Id) -> integer_to_binary(Id);
checkpointId(Id) when is_atom(Id) -> atom_to_binary(Id, utf8).

%%--------------------------------------------------------------------
%% @doc
%% 选项预处理：若已显式指定 sessionId，则原样返回选项
%%
%% @param Opts 已包含 sessionId 的选项映射
%% @return 原样返回的选项映射
%% @end
%%--------------------------------------------------------------------
ensureSessionOpts(#{sessionId := _} = Opts) ->
    Opts;
%%--------------------------------------------------------------------
%% @doc
%% 选项预处理：若未指定 sessionId 且 autoSession 为 true，
%% 则自动创建一个新会话并写入 sessionId
%%
%% @param Opts 原始选项映射
%% @return 处理后的选项映射（可能包含新建的 sessionId）
%% @end
%%--------------------------------------------------------------------
ensureSessionOpts(Opts) ->
    case maps:get(autoSession, Opts, false) of
        true ->
            {ok, SessionId} = alSessionMgr:createSession(maps:get(user, Opts, default)),
            Opts#{sessionId => SessionId};
        false ->
            Opts
    end.

%%--------------------------------------------------------------------
%% @doc
%% 为指定用户创建新的会话
%%
%% @param User 用户标识
%% @return {ok, SessionId} 或错误
%% @end
%%--------------------------------------------------------------------
createSession(User) ->
    alSessionMgr:createSession(User).

%%--------------------------------------------------------------------
%% @doc
%% 获取指定会话的上下文信息
%%
%% @param SessionId 会话 ID
%% @return 会话上下文
%% @end
%%--------------------------------------------------------------------
getSession(SessionId) ->
    alSessionMgr:getContext(SessionId).

%%--------------------------------------------------------------------
%% @doc
%% 清空当前默认会话
%%
%% @return 清空操作的结果
%% @end
%%--------------------------------------------------------------------
clearSession() ->
    alServer:clearSession().

%%--------------------------------------------------------------------
%% @doc
%% 清空指定会话
%%
%% @param SessionId 会话 ID
%% @return 清空操作的结果
%% @end
%%--------------------------------------------------------------------
clearSession(SessionId) ->
    alServer:clearSession(SessionId).

%%--------------------------------------------------------------------
%% @doc
%% 保存当前默认会话到持久化存储
%%
%% @return 保存操作的结果
%% @end
%%--------------------------------------------------------------------
saveSession() ->
    alServer:saveSession().

%%--------------------------------------------------------------------
%% @doc
%% 保存指定会话到持久化存储
%%
%% @param SessionId 会话 ID
%% @return 保存操作的结果
%% @end
%%--------------------------------------------------------------------
saveSession(SessionId) ->
    alServer:saveSession(SessionId).

%%--------------------------------------------------------------------
%% @doc
%% 加载之前保存的会话
%%
%% @param SessionId 会话 ID
%% @return 加载操作的结果
%% @end
%%--------------------------------------------------------------------
loadSession(SessionId) ->
    alServer:loadSession(SessionId).

%%--------------------------------------------------------------------
%% @doc
%% 列出所有已保存的会话
%%
%% @return 已保存会话列表
%% @end
%%--------------------------------------------------------------------
savedSessions() ->
    alServer:savedSessions().

%%--------------------------------------------------------------------
%% @doc
%% 获取指定会话的消息列表
%%
%% @param SessionId 会话 ID
%% @return 消息列表
%% @end
%%--------------------------------------------------------------------
sessionMessages(SessionId) ->
    alServer:sessionMessages(SessionId).

%%--------------------------------------------------------------------
%% @doc
%% 取消当前默认会话中正在进行的提问任务
%%
%% @return 取消操作的结果
%% @end
%%--------------------------------------------------------------------
cancelAsk() ->
    alServer:cancelAsk().

%%--------------------------------------------------------------------
%% @doc
%% 取消指定会话中正在进行的提问任务
%%
%% @param SessionId 会话 ID
%% @return 取消操作的结果
%% @end
%%--------------------------------------------------------------------
cancelAsk(SessionId) ->
    alServer:cancelAsk(SessionId).

%%--------------------------------------------------------------------
%% @doc
%% 查询指定异步任务的状态
%%
%% @param TaskId 任务 ID
%% @return 任务状态信息
%% @end
%%--------------------------------------------------------------------
taskStatus(TaskId) ->
    alServer:taskStatus(TaskId).

%%--------------------------------------------------------------------
%% @doc
%% 取消指定的异步任务
%%
%% @param TaskId 任务 ID
%% @return 取消操作的结果
%% @end
%%--------------------------------------------------------------------
cancelTask(TaskId) ->
    alServer:cancelTask(TaskId).

%%--------------------------------------------------------------------
%% @doc
%% 列出所有已知任务
%%
%% @return 任务列表
%% @end
%%--------------------------------------------------------------------
tasks() ->
    alServer:tasks().

%%--------------------------------------------------------------------
%% @doc
%% 获取 alServer 当前的运行状态
%%
%% @return 服务器状态信息
%% @end
%%--------------------------------------------------------------------
serverStatus() ->
    alServer:status().

%%--------------------------------------------------------------------
%% @doc
%% 获取 alServer 当前管理的所有会话
%%
%% @return 会话列表
%% @end
%%--------------------------------------------------------------------
serverSessions() ->
    alServer:sessions().

%%--------------------------------------------------------------------
%% @doc
%% 获取当前配置信息
%%
%% @return 配置映射
%% @end
%%--------------------------------------------------------------------
getConfig() ->
    alServer:getConfig().

%%--------------------------------------------------------------------
%% @doc
%% 修改指定配置项的值
%%
%% @param Key 配置项键
%% @param Value 新值
%% @return 设置操作的结果
%% @end
%%--------------------------------------------------------------------
setConfig(Key, Value) ->
    alServer:setConfig(Key, Value).

%%--------------------------------------------------------------------
%% @doc
%% 获取当前运行模式（如 plan/act 模式）
%%
%% @return 当前模式
%% @end
%%--------------------------------------------------------------------
getMode() ->
    alServer:getMode().

%%--------------------------------------------------------------------
%% @doc
%% 设置运行模式
%%
%% @param Mode 模式名称
%% @return 设置操作的结果
%% @end
%%--------------------------------------------------------------------
setMode(Mode) ->
    alServer:setMode(Mode).

%%--------------------------------------------------------------------
%% @doc
%% 获取当前的工作上下文（working context）
%%
%% @return 工作上下文内容
%% @end
%%--------------------------------------------------------------------
getWorkingContext() ->
    alServer:getWorkingContext().

%%--------------------------------------------------------------------
%% @doc
%% 向工作上下文中追加内容
%%
%% @param Type 上下文条目类型
%% @param Value 上下文条目内容
%% @return 追加操作的结果
%% @end
%%--------------------------------------------------------------------
addContext(Type, Value) ->
    alServer:addContext(Type, Value).

%%--------------------------------------------------------------------
%% @doc
%% 清空当前工作上下文
%%
%% @return 清空操作的结果
%% @end
%%--------------------------------------------------------------------
clearContext() ->
    alServer:clearContext().

%%--------------------------------------------------------------------
%% @doc
%% 获取系统整体健康状态，聚合核心、数据库、指标和服务器状态
%%
%% @return 包含 core、db、metrics、server 字段的映射
%% @end
%%--------------------------------------------------------------------
health() ->
    #{
        core => coreHealth(),
        db => dbStatus(),
        metrics => metrics(),
        server => serverStatus()
    }.

%%--------------------------------------------------------------------
%% @doc
%% 为指定会话设置执行计划步骤
%%
%% @param SessionId 会话 ID
%% @param Steps 计划步骤列表
%% @return 设置操作的结果
%% @end
%%--------------------------------------------------------------------
plan(SessionId, Steps) ->
    alToolsExt:planSet(SessionId, Steps).

%%--------------------------------------------------------------------
%% @doc
%% 连接到指定的 MCP（Model Context Protocol）服务器
%%
%% @param Spec MCP 服务器连接规格
%% @return 连接操作的结果
%% @end
%%--------------------------------------------------------------------
mcpConnect(Spec) ->
    alMcpClient:connect(Spec).

%%--------------------------------------------------------------------
%% @doc
%% 断开与指定 MCP 服务器的连接
%%
%% @param Name MCP 服务器名称
%% @return 断开操作的结果
%% @end
%%--------------------------------------------------------------------
mcpDisconnect(Name) ->
    alMcpClient:disconnect(Name).

%%--------------------------------------------------------------------
%% @doc
%% 列出指定 MCP 服务器提供的工具
%%
%% @param Name MCP 服务器名称
%% @return 工具列表
%% @end
%%--------------------------------------------------------------------
mcpListTools(Name) ->
    alMcpClient:listTools(Name).

%%--------------------------------------------------------------------
%% @doc
%% 以 Agent 模式运行（使用默认选项）
%%
%% @param Question 用户的提问或任务描述
%% @return Agent 执行结果
%% @end
%%--------------------------------------------------------------------
agent(Question) ->
    agent(Question, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 以 Agent 模式运行（带选项），允许 Agent 自主调用工具完成任务
%%
%% @param Question 用户的提问或任务描述
%% @param Opts 选项映射
%% @return Agent 执行结果
%% @end
%%--------------------------------------------------------------------
agent(Question, Opts) ->
    alAgent:run(Question, ensureSessionOpts(Opts)).

%%--------------------------------------------------------------------
%% @doc
%% 索引配置中的全部代码根目录（{@link alConfig:codeRoots/0}）。
%%
%% @return 各根目录索引结果的汇总 map
%% @end
%%--------------------------------------------------------------------
index() ->
    indexRoots().

%%--------------------------------------------------------------------
%% @doc
%% 若索引为空则触发 codeRoots 异步索引（不重启 core）。
%% @end
%%--------------------------------------------------------------------
ensureIndex() ->
    alCoreClient:ensureIndex().

%%--------------------------------------------------------------------
%% @doc
%% 重启 aliCore 子进程并重新 ensureIndex（用于清除僵死 indexing）。
%% @end
%%--------------------------------------------------------------------
restartCore() ->
    case alCoreClient:restart() of
        ok ->
            alCoreClient:ensureIndex();
        {error, _} = Err ->
            Err
    end.

%%--------------------------------------------------------------------
%% @doc
%% 对指定路径下的代码进行索引
%%
%% @param Path 待索引的文件或目录路径
%% @return 索引操作的结果
%% @end
%%--------------------------------------------------------------------
index(Path) ->
    alToolRouter:callTool(indexCode, #{path => Path}).

%%--------------------------------------------------------------------
%% @doc
%% 依次索引 {@link alConfig:codeRoots/0} 中的全部目录（含 projectRoot
%% 与额外 codeRoots）。多根必须串行，避免互相覆盖索引状态。
%%
%% @return {ok, #{roots := [...], results := [...]}}
%% @end
%%--------------------------------------------------------------------
indexRoots() ->
    indexRoots(#{}).

indexRoots(Opts) when is_map(Opts) ->
    Roots = alConfig:codeRoots(),
    Results = lists:map(
        fun(Root) ->
            Args = maps:merge(#{path => Root}, maps:with([force_reparse, <<"force_reparse">>], Opts)),
            {Root, alToolRouter:callTool(indexCode, Args)}
        end,
        Roots
    ),
    {ok, #{roots => Roots, results => Results}}.

%%--------------------------------------------------------------------
%% @doc
%% 代码搜索（使用默认结果数量上限）
%%
%% @param Query 查询字符串
%% @return 搜索结果列表
%% @end
%%--------------------------------------------------------------------
search(Query) ->
    search(Query, ?DefaultSearchLimit).

%%--------------------------------------------------------------------
%% @doc
%% 代码搜索（指定结果数量上限）
%%
%% @param Query 查询字符串
%% @param Limit 返回结果的最大数量
%% @return 搜索结果列表
%% @end
%%--------------------------------------------------------------------
search(Query, Limit) ->
    alToolRouter:callTool(searchCode, #{query => Query, limit => Limit}).

%%--------------------------------------------------------------------
%% @doc
%% 获取指定模块函数的符号信息
%%
%% @param Module 模块名
%% @param Function 函数名
%% @param Arity 参数个数
%% @return 符号信息
%% @end
%%--------------------------------------------------------------------
getSymbol(Module, Function, Arity) ->
    alToolRouter:callTool(getSymbol, #{module => Module, function => Function, arity => Arity}).

%%--------------------------------------------------------------------
%% @doc
%% 列出指定模块中的所有符号
%%
%% @param Module 模块名
%% @return 符号列表
%% @end
%%--------------------------------------------------------------------
moduleSymbols(Module) ->
    alToolRouter:callTool(moduleSymbols, #{module => Module}).

%%--------------------------------------------------------------------
%% @doc 按模块名解析索引中的源文件路径。
%%--------------------------------------------------------------------
resolveModule(Module) ->
    alToolRouter:callTool(resolveModule, #{module => Module}).

%%--------------------------------------------------------------------
%% @doc 跳转到 Mod:Fun/Arity 定义（file + line 范围）。
%%--------------------------------------------------------------------
gotoDef(Module, Function, Arity) ->
    alToolRouter:callTool(gotoDef, #{module => Module, function => Function, arity => Arity}).

%%--------------------------------------------------------------------
%% @doc 查找 Mod:Fun/Arity 的引用（调用点，含 caller 文件路径）。
%%--------------------------------------------------------------------
findRefs(Module, Function, Arity) ->
    alToolRouter:callTool(findRefs, #{module => Module, function => Function, arity => Arity}).

%%--------------------------------------------------------------------
%% @doc
%% 获取整个项目的调用图
%%
%% @return 调用图数据
%% @end
%%--------------------------------------------------------------------
callGraph() ->
    alToolRouter:callTool(callGraph, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 获取指定模块函数的所有调用方
%%
%% @param Module 模块名
%% @param Function 函数名
%% @param Arity 参数个数
%% @return 调用方列表
%% @end
%%--------------------------------------------------------------------
getCallers(Module, Function, Arity) ->
    alToolRouter:callTool(getCallers, #{module => Module, function => Function, arity => Arity}).

%%--------------------------------------------------------------------
%% @doc
%% 获取指定模块函数的所有被调用方
%%
%% @param Module 模块名
%% @param Function 函数名
%% @param Arity 参数个数
%% @return 被调用方列表
%% @end
%%--------------------------------------------------------------------
getCallees(Module, Function, Arity) ->
    alToolRouter:callTool(getCallees, #{module => Module, function => Function, arity => Arity}).

%%--------------------------------------------------------------------
%% @doc
%% 获取当前向量嵌入（embedding）的 schema 信息
%%
%% @return embedding schema
%% @end
%%--------------------------------------------------------------------
embeddingSchema() ->
    alToolRouter:callTool(embeddingSchema, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 获取当前 Erlang 运行时信息
%%
%% @return 运行时信息
%% @end
%%--------------------------------------------------------------------
runtime() ->
    alToolRouter:callTool(getRuntime, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 查询核心服务的健康状态
%%
%% @return 核心健康信息
%% @end
%%--------------------------------------------------------------------
coreHealth() ->
    alToolRouter:callTool(coreHealth, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 查询核心服务的详细状态
%%
%% @return 核心状态信息
%% @end
%%--------------------------------------------------------------------
coreStatus() ->
    alToolRouter:callTool(coreStatus, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 查询 Qdrant 向量数据库的连接与运行状态
%%
%% @return Qdrant 状态信息
%% @end
%%--------------------------------------------------------------------
qdrantStatus() ->
    alQdrant:status().

%%--------------------------------------------------------------------
%% @doc
%% 获取当前 Erlang 节点的进程列表（限制返回数量）
%%
%% @param Limit 返回进程的最大数量
%% @return 进程信息列表
%% @end
%%--------------------------------------------------------------------
processes(Limit) ->
    alToolRouter:callTool(getProcesses, #{limit => Limit}).

%%--------------------------------------------------------------------
%% @doc
%% 获取当前 Erlang 节点的 ETS 表列表（限制返回数量）
%%
%% @param Limit 返回 ETS 表的最大数量
%% @return ETS 表信息列表
%% @end
%%--------------------------------------------------------------------
etsTables(Limit) ->
    alToolRouter:callTool(getEts, #{limit => Limit}).

%%--------------------------------------------------------------------
%% @doc
%% 列出所有已注册的工具
%%
%% @return 工具列表
%% @end
%%--------------------------------------------------------------------
tools() ->
    alToolCatalog:allTools().

%%--------------------------------------------------------------------
%% @doc
%% 获取指定工具的规格说明（spec）
%%
%% @param Tool 工具名称
%% @return 工具规格
%% @end
%%--------------------------------------------------------------------
toolSpec(Tool) ->
    alToolCatalog:toolSpec(Tool).

%%--------------------------------------------------------------------
%% @doc
%% 列出所有补丁事务记录
%%
%% @return {ok, Transactions}
%% @end
%%--------------------------------------------------------------------
listTransactions() ->
    {ok, alPatchManager:listTransactions()}.

%%--------------------------------------------------------------------
%% @doc
%% 列出最近执行过的模拟记录
%%
%% @param Limit 返回记录的最大数量
%% @return 模拟记录列表
%% @end
%%--------------------------------------------------------------------
listRecentSimulations(Limit) ->
    alSimulator:listRecent(Limit).

%%--------------------------------------------------------------------
%% @doc
%% 获取指定会话最近的记忆条目
%%
%% @param SessionId 会话 ID
%% @param Limit 返回条目的最大数量
%% @return 记忆条目列表
%% @end
%%--------------------------------------------------------------------
recent(SessionId, Limit) ->
    alMemory:recent(SessionId, Limit).

%%--------------------------------------------------------------------
%% @doc
%% 按标签搜索记忆条目
%%
%% @param Tag 标签
%% @return 匹配的记忆条目列表
%% @end
%%--------------------------------------------------------------------
searchTags(Tag) ->
    alMemory:searchTags(Tag).

%%--------------------------------------------------------------------
%% @doc
%% 通用工具调用入口，按工具名和参数调用对应工具
%%
%% @param Tool 工具名称
%% @param Args 调用参数映射
%% @return 工具执行结果
%% @end
%%--------------------------------------------------------------------
callTool(Tool, Args) ->
    alToolRouter:callTool(Tool, Args).

%%--------------------------------------------------------------------
%% @doc
%% 校验补丁内容是否合法，不实际应用
%%
%% @param Patch 补丁内容
%% @return 校验结果
%% @end
%%--------------------------------------------------------------------
validatePatch(Patch) ->
    alToolRouter:callTool(validatePatch, Patch).

%%--------------------------------------------------------------------
%% @doc
%% 试运行（dry run）补丁，模拟应用过程但不实际修改文件
%%
%% @param Patch 补丁内容
%% @return 试运行结果
%% @end
%%--------------------------------------------------------------------
dryRunPatch(Patch) ->
    alToolRouter:callTool(dryRunPatch, Patch).

%%--------------------------------------------------------------------
%% @doc
%% 应用补丁到实际文件系统
%%
%% @param Patch 补丁内容
%% @return 应用结果
%% @end
%%--------------------------------------------------------------------
applyPatch(Patch) ->
    alToolRouter:callTool(applyPatch, Patch).

%%--------------------------------------------------------------------
%% @doc
%% 批量应用多个补丁
%%
%% @param Patches 补丁列表
%% @return 批量应用结果
%% @end
%%--------------------------------------------------------------------
applyPatchBatch(Patches) ->
    alToolRouter:callTool(applyPatchBatch, #{patches => Patches}).

%%--------------------------------------------------------------------
%% @doc
%% 回滚最近一次应用的补丁
%%
%% @return 回滚操作的结果
%% @end
%%--------------------------------------------------------------------
rollbackPatch() ->
    alToolRouter:callTool(rollbackPatch, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 执行数据库查询
%%
%% @param Args 查询参数
%% @return 查询结果
%% @end
%%--------------------------------------------------------------------
dbQuery(Args) ->
    alToolRouter:callTool(dbQuery, Args).

%%--------------------------------------------------------------------
%% @doc
%% 查询数据库适配器的状态
%%
%% @return 数据库状态信息
%% @end
%%--------------------------------------------------------------------
dbStatus() ->
    alDbAdapter:status().

%%--------------------------------------------------------------------
%% @doc
%% 将一条记忆存储到指定会话（使用默认选项）
%%
%% @param SessionId 会话 ID
%% @param Kind 记忆类型
%% @param Content 记忆内容
%% @return 存储操作的结果
%% @end
%%--------------------------------------------------------------------
remember(SessionId, Kind, Content) ->
    alMemory:remember(SessionId, Kind, Content).

%%--------------------------------------------------------------------
%% @doc
%% 将一条记忆存储到指定会话（带选项，可设置标签、TTL 等）
%%
%% @param SessionId 会话 ID
%% @param Kind 记忆类型
%% @param Content 记忆内容
%% @param Opts 选项映射
%% @return 存储操作的结果
%% @end
%%--------------------------------------------------------------------
remember(SessionId, Kind, Content, Opts) ->
    alMemory:remember(SessionId, Kind, Content, Opts).

%%--------------------------------------------------------------------
%% @doc 读取 user scope 记忆（偏好/画像）。
%% @end
%%--------------------------------------------------------------------
userProfile() ->
    alMemory:userProfile().

userProfile(Limit) ->
    alMemory:userProfile(Limit).

%%--------------------------------------------------------------------
%% @doc
%% 按关键词召回相关记忆（使用默认数量上限）
%%
%% @param Query 查询字符串
%% @return 记忆条目列表
%% @end
%%--------------------------------------------------------------------
recall(Query) ->
    alMemory:recall(Query).

%%--------------------------------------------------------------------
%% @doc
%% 按关键词召回相关记忆（指定数量上限）
%%
%% @param Query 查询字符串
%% @param Limit 返回条目的最大数量
%% @return 记忆条目列表
%% @end
%%--------------------------------------------------------------------
recall(Query, Limit) ->
    alMemory:recall(Query, Limit).

%%--------------------------------------------------------------------
%% @doc
%% 基于语义检索召回相关记忆（使用默认数量上限）
%%
%% @param Query 语义查询字符串
%% @return 记忆条目列表
%% @end
%%--------------------------------------------------------------------
recallSemantic(Query) ->
    alMemory:recallSemantic(Query).

%%--------------------------------------------------------------------
%% @doc
%% 基于语义检索召回相关记忆（指定数量上限）
%%
%% @param Query 语义查询字符串
%% @param Limit 返回条目的最大数量
%% @return 记忆条目列表
%% @end
%%--------------------------------------------------------------------
recallSemantic(Query, Limit) ->
    alMemory:recallSemantic(Query, Limit).

%%--------------------------------------------------------------------
%% @doc Delete one memory from SQLite and drop its vector cache entry.
%% @end
%%--------------------------------------------------------------------
forget(Id) ->
    alMemory:forget(Id).

%%--------------------------------------------------------------------
%% @doc Rebuild vector memory index from SQLite (source of truth).
%% @end
%%--------------------------------------------------------------------
rebuildMemoryIndex() ->
    alMemory:rebuildIndex().

rebuildMemoryIndex(Opts) ->
    alMemory:rebuildIndex(Opts).

%%--------------------------------------------------------------------
%% @doc
%% 对指定目标进行知识蒸馏（使用默认选项）
%%
%% @param Target 蒸馏目标
%% @return 蒸馏结果
%% @end
%%--------------------------------------------------------------------
distill(Target) ->
    alMemory:distill(Target).

%%--------------------------------------------------------------------
%% @doc
%% 对指定目标进行知识蒸馏（带选项）
%%
%% @param Target 蒸馏目标
%% @param Opts 选项映射
%% @return 蒸馏结果
%% @end
%%--------------------------------------------------------------------
distill(Target, Opts) ->
    alMemory:distill(Target, Opts).

%%--------------------------------------------------------------------
%% @doc
%% 在沙箱中运行指定的模拟场景
%%
%% @param Scenario 模拟场景描述
%% @return 模拟运行结果
%% @end
%%--------------------------------------------------------------------
simulate(Scenario) ->
    alSimulator:run(Scenario).

%%--------------------------------------------------------------------
%% @doc
%% 获取当前 Erlang 节点的监督树结构
%%
%% @return 监督树信息
%% @end
%%--------------------------------------------------------------------
supervisorTree() ->
    alToolRouter:callTool(supervisorTree, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 获取系统当前的指标快照
%%
%% @return 指标映射
%% @end
%%--------------------------------------------------------------------
metrics() ->
    alMetrics:snapshot().

%%--------------------------------------------------------------------
%% @doc
%% 列出最近的审计日志条目（使用默认数量）
%%
%% @return 审计日志列表
%% @end
%%--------------------------------------------------------------------
auditLog() ->
    alAudit:list().

%%--------------------------------------------------------------------
%% @doc
%% 列出最近的审计日志条目（指定数量上限）
%%
%% @param Limit 返回条目的最大数量
%% @return 审计日志列表
%% @end
%%--------------------------------------------------------------------
auditLog(Limit) ->
    alAudit:list(Limit).
