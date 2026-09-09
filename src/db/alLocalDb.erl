%%%-------------------------------------------------------------------
%% @doc 本地 DB 门面 —— Rust Core 内嵌 SQLite，否则回退到文件后端。
%% @end
%%%-------------------------------------------------------------------

-module(alLocalDb).

-behaviour(gen_server).

-export([start_link/0, query/2, execute/2, insert/2, status/0, stopIfOrphan/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
%% Test exports
-export([isSessionSql/1]).

-define(SERVER, ?MODULE).
-define(DefaultCallTimeoutMs, 120000).

%%--------------------------------------------------------------------
%% @doc
%% 启动本地 DB gen_server 并注册为本地名称 ?SERVER。
%%
%% @return {ok, Pid} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% @doc
%% 若 `alLocalDb' 已在跑但 `ali_sup' 尚未启动，则视其为 EUnit/手工拉起的孤儿进程并停止。
%% 供 {@link ali_app} 启动监督树前调用，避免 `already_started`。
%% @end
%%--------------------------------------------------------------------
-spec stopIfOrphan() -> ok.
stopIfOrphan() ->
    case {whereis(ali_sup), whereis(?SERVER)} of
        {undefined, Pid} when is_pid(Pid) ->
            try gen_server:stop(Pid, normal, 5000) of
                ok -> ok
            catch _:_ ->
                try exit(Pid, kill) catch _:_ -> ok end,
                ok
            end;
        _ ->
            ok
    end.

%%--------------------------------------------------------------------
%% @doc
%% 同步执行只读查询。默认 120s 超时；超时返回 `{error, #{reason => timeout}}`
%% 而非让调用方收到未捕获 exit。
%%
%% @param Sql SQL 文本
%% @param Params 绑定参数列表
%% @return 后端返回的查询结果 | {error, #{reason => timeout}}
%% @end
%%--------------------------------------------------------------------
query(Sql, Params) ->
    safeCall({eQuery, Sql, Params}).

%%--------------------------------------------------------------------
%% @doc
%% 同步执行写操作（UPDATE/DELETE 等）。
%%
%% @param Sql SQL 文本
%% @param Params 绑定参数列表
%% @return 后端返回的执行结果 | {error, #{reason => timeout}}
%% @end
%%--------------------------------------------------------------------
execute(Sql, Params) ->
    safeCall({eExecute, Sql, Params}).

%%--------------------------------------------------------------------
%% @doc
%% 同步执行 INSERT，并返回新插入行的 ID。
%%
%% @param Sql SQL 文本
%% @param Params 绑定参数列表
%% @return {ok, RowId} | 其他后端返回 | {error, #{reason => timeout}}
%% @end
%%--------------------------------------------------------------------
insert(Sql, Params) ->
    safeCall({eInsert, Sql, Params}).

%%--------------------------------------------------------------------
%% @doc
%% 查询当前后端状态（rustCore 或 file 回退）。
%%
%% @return 状态映射 | {error, #{reason => timeout}}
%% @end
%%--------------------------------------------------------------------
status() ->
    safeCall(status).

%% 有限超时 call；捕获 timeout exit，避免调用方崩溃。
safeCall(Req) ->
    Timeout = callTimeoutMs(),
    try
        gen_server:call(?SERVER, Req, Timeout)
    catch
        exit:{timeout, _} -> {error, #{reason => timeout}};
        exit:timeout -> {error, #{reason => timeout}}
    end.

callTimeoutMs() ->
    case application:get_env(ali, localDbCallTimeoutMs, ?DefaultCallTimeoutMs) of
        N when is_integer(N), N > 0 -> N;
        _ -> ?DefaultCallTimeoutMs
    end.

%%--------------------------------------------------------------------
%% @doc
%% gen_server 初始化：根据 Rust Core 可用性选择引擎。
%%
%% @return {ok, #{engine => rustCore | file}}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    Engine = case alCoreClient:available() of
        true -> rustCore;
        false -> file
    end,
    {ok, #{engine => Engine}}.

%%--------------------------------------------------------------------
%% @doc
%% gen_server 同步请求处理：分派 query/execute/insert/status。
%%
%% @param Request 请求元组或 status 原子
%% @param From 调用方引用
%% @param State 当前状态
%% @return {reply, Reply, State}
%% @end
%%--------------------------------------------------------------------
handle_call({eQuery, Sql, Params}, _From, State) ->
    {reply, safeRunQuery(Sql, Params, read), State};
handle_call({eExecute, Sql, Params}, _From, State) ->
    {reply, safeRunQuery(Sql, Params, write), State};
handle_call({eInsert, Sql, Params}, _From, State) ->
    {reply, safeRunQuery(Sql, Params, insert), State};
handle_call(status, _From, State) ->
    Status = case alCoreClient:available() of
        true ->
            case alCoreClient:dbStatus() of
                {ok, #{data := Data}} -> maps:merge(#{engine => rustCore}, Data);
                {ok, Data} when is_map(Data) -> maps:merge(#{engine => rustCore}, Data);
                _ -> maps:merge(alFileDb:status(), #{engine => file, fallback => true})
            end;
        false ->
            maps:merge(alFileDb:status(), #{engine => file, fallback => true})
    end,
    {reply, Status, State};
handle_call(_Request, _From, State) ->
    {reply, {error, badRequest}, State}.

%%--------------------------------------------------------------------
%% @doc
%% gen_server 异步消息处理：忽略所有 cast。
%%
%% @return {noreply, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @doc
%% gen_server info 消息处理：忽略所有非 cast 消息。
%%
%% @return {noreply, State}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @doc
%% gen_server 终止回调：无特殊清理动作。
%%
%% @return ok
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @doc
%% gen_server 热升级回调：直接保留当前状态。
%%
%% @return {ok, State}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% 根据 Rust Core 可用性选择走核心查询或文件查询。
%% 会话表（sessions / session_messages）始终走文件后端，避免被 Port 串行队列阻塞。
runQuery(Sql, Params, Mode) ->
    case isSessionSql(Sql) of
        true ->
            fileQuery(Sql, Params, Mode);
        false ->
            case alCoreClient:available() of
                true ->
                    coreQuery(Sql, Params, Mode);
                false ->
                    fileQuery(Sql, Params, Mode)
            end
    end.

%% 安全执行查询：捕获后端 function_clause / core 异常，返回统一错误，
%% 避免异常逃逸导致整个 gen_server 崩溃。
safeRunQuery(Sql, Params, Mode) ->
    try runQuery(Sql, Params, Mode)
    catch
        Class:Reason ->
            {error, #{reason => dbError, class => Class, detail => Reason}}
    end.

%% 判断 SQL 是否针对会话表（sessions / session_messages / session_artifacts）。
%% 这些表走文件后端，避免长搜索/索引操作阻塞会话持久化。
isSessionSql(Sql) when is_binary(Sql) ->
    case re:run(
        Sql,
        <<"(?:^|[^a-zA-Z0-9_])(session_messages|session_artifacts|sessions)(?:[^a-zA-Z0-9_]|$)">>,
        [caseless]
    ) of
        {match, _} -> true;
        nomatch -> false
    end;
isSessionSql(Sql) when is_list(Sql) ->
    try isSessionSql(unicode:characters_to_binary(Sql))
    catch _:_ -> false
    end;
isSessionSql(_) ->
    false.

%% 调用 Rust Core 执行查询；失败时记录日志并回退到文件后端。
coreQuery(Sql, Params, Mode) ->
    case alCoreClient:dbQuery(Sql, Params, coreMode(Mode)) of
        {ok, #{data := Data}} ->
            normalizeCoreResponse(Data, Mode);
        {error, Reason} ->
            logger:warning(
                "alLocalDb: core query failed (~p), sql=~s params=~p; falling back to file db",
                [Reason, Sql, Params]
            ),
            fileQuery(Sql, Params, Mode)
    end.

coreMode(insert) -> write;
coreMode(write) -> write;
coreMode(_) -> read.

%% 将 Rust Core 返回的原始数据按模式归一化为统一的 Erlang 端响应。
normalizeCoreResponse(#{rows := Rows}, read) ->
    {ok, [rowMapsToAtoms(Row) || Row <- Rows]};
normalizeCoreResponse(#{last_insert_rowid := RowId}, insert) when RowId =/= 0 ->
    {ok, RowId};
normalizeCoreResponse(#{changes := Changes}, _) ->
    {ok, Changes};
%% 兜底：核心返回不符合已知形状（如空 map、insert 但 rowid=0、缺字段）时，
%% 不再 function_clause 崩溃，而是记录日志并返回统一错误。
normalizeCoreResponse(Other, Mode) ->
    logger:warning(
        "alLocalDb: unexpected core response ~p (mode ~p)", [Other, Mode]),
    {error, {unexpectedCoreResponse, Mode}}.

%% 将行映射的所有键转换为已存在的原子键（无法转换则保留原值）。
rowMapsToAtoms(Row) when is_map(Row) ->
    maps:from_list([
        {normalizeKey(K), V} || {K, V} <- maps:to_list(Row)
    ]).

%% 将二进制/列表键转换为已存在的原子；不能转换时原样返回。
normalizeKey(K) when is_binary(K) ->
    try binary_to_existing_atom(K, utf8) catch _:_ -> K end;
normalizeKey(K) when is_atom(K) -> K;
normalizeKey(K) when is_list(K) ->
    try list_to_existing_atom(K) catch _:_ -> K end.

%% 调用文件后端执行对应模式的查询。
fileQuery(Sql, Params, insert) ->
    alFileDb:insert(Sql, Params);
fileQuery(Sql, Params, write) ->
    alFileDb:execute(Sql, Params);
fileQuery(Sql, Params, _) ->
    alFileDb:query(Sql, Params).
