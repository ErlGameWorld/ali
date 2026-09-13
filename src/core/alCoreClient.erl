%%%-------------------------------------------------------------------
%% @doc Rust aliCore 服务的 Erlang port 客户端。
%%
%% 拉起 `aliCore --port'，通过 stdin/stdout 以长度前缀 JSON
%% 交换数据（{packet, 4}）。支持多 inflight：请求带递增 `seq`，
%% 响应按 `seq` 匹配；同类/全局有并发上限，超出进入等待队列。
%% @end
%%%-------------------------------------------------------------------

-module(alCoreClient).

-behaviour(gen_server).

-export([
    start_link/0,
    ensureAvailable/0,
    ensureAvailable/1,
    available/0,
    health/0,
    status/0,
    restart/0,
    index/1,
    index/2,
    indexAsync/1,
    indexAsync/2,
    indexAsyncRoots/1,
    indexAsyncRoots/2,
    ensureIndex/0,
    search/2,
    search/3,
    getSymbol/3,
    moduleSymbols/1,
    moduleDeps/1,
    listModules/0,
    listModules/1,
    callGraph/0,
    getCallers/3,
    getCallees/3,
    embeddingSchema/0,
    dbQuery/2,
    dbQuery/3,
    dbStatus/0,
    memoryUpsert/2,
    memorySearch/2,
    memoryDelete/1,
    indexStatus/0,
    searchUnified/2,
    dataSources/0,
    dataSourceCallers/1,
    paramSources/3,
    traceDataFlow/4,
    traceDataFlow/5,
    enabled/0,
    childOsPid/0,
    unwrap/1,
    unwrapMap/1
]).
%% 测试/诊断导出
-export([pathClass/1, concurrencyLimits/0, encodeRequest/4, decodePortResponse/1,
         paramsToJson/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(ReconnectMs, 2000).
-define(BacklogHighWatermark, 1000).
-define(DefaultMaxInflight, 24).
-define(DefaultLimits, #{
    index => 1,
    search => 8,
    db => 4,
    memory => 8,
    memoryWrite => 2,
    graph => 4,
    other => 8
}).
%%--------------------------------------------------------------------
%% @doc
%% 启动 alCoreClient gen_server，并注册为本地名称 ?SERVER
%%
%% @return gen_server:start_link/4 的结果
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% @doc
%% 检查并设置 aliCore 可用性：若未启用则标记为不可用；
%% 若已启用则调用 health 探测，根据结果更新环境变量
%%
%% @return ok 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
%%--------------------------------------------------------------------
%% @doc
%% 确保 aliCore 可用并（默认）打印一次启动状态。
%% 重复调用不会再刷屏；需要强制再打印时传 `#{forcePrint => true}`。
%% @end
%%--------------------------------------------------------------------
ensureAvailable() ->
    ensureAvailable(#{}).

-spec ensureAvailable(map()) -> ok | {error, term()}.
ensureAvailable(Opts) when is_map(Opts) ->
    case enabled() of
        false ->
            application:set_env(ali, coreAvailable, false),
            maybeShellStatus(Opts, <<"aliCore 未启用（core.enabled=false）"/utf8>>),
            ok;
        true ->
            case collectStartupSnapshot(3) of
                {ok, Snapshot} ->
                    application:set_env(ali, coreAvailable, true),
                    _ = try gen_server:cast(?SERVER, {eHealthSnapshot, Snapshot}) catch _:_ -> ok end,
                    case shouldPrintStatus(Opts) of
                        true ->
                            markStatusPrinted(),
                            logStartupSnapshot(Snapshot);
                        false ->
                            logger:debug("aliCore ensureAvailable (quiet) ready=~p",
                                         [maps:get(health, Snapshot, #{})])
                    end,
                    ok;
                {error, Reason} ->
                    application:set_env(ali, coreAvailable, false),
                    maybeShellStatus(Opts, formatUtf8(
                        "aliCore 不可用: ~p~n  binary=~ts~n  请确认已编译 priv 下的 aliCore 且 core.enabled=true",
                        [Reason, coreBinary()])),
                    logger:warning("aliCore enabled but unavailable: ~p", [Reason]),
                    {error, Reason}
            end
    end.

shouldPrintStatus(#{forcePrint := true}) -> true;
shouldPrintStatus(#{quiet := true}) -> false;
shouldPrintStatus(_) ->
    application:get_env(ali, coreStatusPrinted, false) =/= true.

markStatusPrinted() ->
    application:set_env(ali, coreStatusPrinted, true).

maybeShellStatus(Opts, Msg) ->
    case shouldPrintStatus(Opts) of
        true ->
            markStatusPrinted(),
            shellStatus(Msg);
        false ->
            logger:debug("~ts", [Msg])
    end.

%%--------------------------------------------------------------------
%% @doc
%% 判断 aliCore 是否当前可用：配置启用 且 环境变量标记可用
%%
%% @return boolean()
%% @end
%%--------------------------------------------------------------------
available() ->
    enabled() =:= true
        andalso application:get_env(ali, coreAvailable, false) =:= true
        andalso whereis(?SERVER) =/= undefined.

%%--------------------------------------------------------------------
%% @doc
%% 调用 aliCore 的 /health 接口探测健康状态
%%
%% @return {ok, _} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
health() ->
    request(get, "/health", undefined).

%%--------------------------------------------------------------------
%% @doc
%% 获取 aliCore 客户端整体状态：是否启用、模式、二进制路径与健康状态
%%
%% @return 状态映射
%% @end
%%--------------------------------------------------------------------
status() ->
    #{
        enabled => enabled(),
        mode => port,
        binary => coreBinary(),
        health => health(),
        limits => concurrencyLimits()
    }.

%%--------------------------------------------------------------------
%% @doc
%% 调用 aliCore 对指定路径进行索引（同步，使用 index 超时配置）
%%
%% @param Path 待索引的文件或目录路径
%% @return {ok, Result} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
index(Path) ->
    index(Path, #{}).

index(Path, Opts) when is_map(Opts) ->
    Body0 = #{path => Path},
    Body = case maps:get(force_reparse, Opts, maps:get(<<"force_reparse">>, Opts, false)) of
        true -> Body0#{force_reparse => true};
        <<"true">> -> Body0#{force_reparse => true};
        _ -> Body0
    end,
    request(post, "/index", Body, indexTimeout()).

%%--------------------------------------------------------------------
%% @doc
%% 异步对指定路径进行索引：在独立进程中执行 index，立即返回
%%
%% @param Path 待索引的文件或目录路径
%% @return {ok, indexing}
%% @end
%%--------------------------------------------------------------------
indexAsync(Path) ->
    indexAsync(Path, #{}).

indexAsync(Path, Opts) when is_map(Opts) ->
    _ = alAsync:run(coreIndex, fun() ->
        case index(Path, Opts) of
            {ok, _} -> ok;
            {error, Reason} -> logger:warning("aliCore async index failed: ~p", [Reason])
        end
    end),
    {ok, indexing}.

%%--------------------------------------------------------------------
%% @doc
%% 按顺序异步索引多个根目录（串行，避免并发写同一索引状态）。
%%
%% @param Roots 目录路径列表
%% @return {ok, indexing}
%% @end
%%--------------------------------------------------------------------
indexAsyncRoots(Roots) when is_list(Roots) ->
    indexAsyncRoots(Roots, #{}).

indexAsyncRoots(Roots, Opts) when is_list(Roots), is_map(Opts) ->
    _ = alAsync:run(coreIndexRoots, fun() ->
        lists:foreach(
            fun(Root) ->
                case index(Root, Opts) of
                    {ok, _} ->
                        logger:debug("aliCore indexed ~s", [Root]);
                    {error, Reason} ->
                        logger:warning("aliCore index failed for ~s: ~p", [Root, Reason])
                end
            end,
            Roots
        )
    end),
    {ok, indexing}.

%%--------------------------------------------------------------------
%% @doc
%% 强制重启 aliCore 子进程（清掉 Rust 侧僵死的 indexing 标志），
%% 然后若索引为空则重新触发 codeRoots 异步索引。
%% @end
%%--------------------------------------------------------------------
-spec restart() -> ok | {error, term()}.
restart() ->
    try gen_server:call(?SERVER, eRestartPort, 60000) of
        ok ->
            application:set_env(ali, coreAvailable, true),
            ok;
        {ok, _} ->
            application:set_env(ali, coreAvailable, true),
            ok;
        {error, _} = Err ->
            Err;
        Other ->
            {error, Other}
    catch
        _:Reason ->
            {error, Reason}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 若当前索引 files=0（或 core 报 indexing 僵死无进展），触发一次
%% codeRoots 异步全量索引。返回将要索引的根列表。
%% @end
%%--------------------------------------------------------------------
-spec ensureIndex() -> {ok, map()} | {error, term()}.
ensureIndex() ->
    case available() of
        false ->
            case ensureAvailable() of
                ok -> ensureIndexAfterAvailable();
                {error, _} = Err -> Err
            end;
        true ->
            ensureIndexAfterAvailable()
    end.

ensureIndexAfterAvailable() ->
    Roots = alConfig:codeRoots(),
    Status = try
        case unwrap(request(get, "/index/status", undefined)) of
            {ok, M} when is_map(M) -> M;
            _ -> #{}
        end
    catch _:_ -> #{}
    end,
    Files = maps:get(files, Status, maps:get(<<"files">>, Status, 0)),
    Indexing = maps:get(indexing, Status, maps:get(<<"indexing">>, Status, false)),
    LastRoot = maps:get(last_index_root, Status, maps:get(<<"last_index_root">>, Status, <<>>)),
    WalkSeen = maps:get(walk_seen, Status, maps:get(<<"walk_seen">>, Status, 0)),
    FilesN = case Files of I when is_integer(I) -> I; _ -> 0 end,
    WalkN = case WalkSeen of W when is_integer(W) -> W; _ -> 0 end,
    %% 已有文件 → 跳过；正在索引 → 跳过（避免重复入队）；僵死则 restart 后重建
    Stuck = Indexing =:= true andalso FilesN =:= 0 andalso WalkN =:= 0
        andalso (LastRoot =:= <<>> orelse LastRoot =:= ""),
    case {FilesN > 0, Indexing =:= true, Stuck, Roots} of
        {true, _, _, _} ->
            {ok, #{action => skip, roots => Roots, status => Status}};
        {false, true, false, _} ->
            {ok, #{action => in_progress, roots => Roots, status => Status}};
        {false, _, true, [_|_]} ->
            logger:warning("aliCore ensureIndex: stuck indexing, restarting core"),
            _ = restart(),
            timer:sleep(500),
            logger:info("aliCore ensureIndex: roots=~p", [Roots]),
            _ = indexAsyncRoots(Roots),
            {ok, #{action => restarted, roots => Roots, previous => Status}};
        {false, false, _, [_|_]} ->
            logger:info("aliCore ensureIndex: roots=~p status=~p", [Roots, Status]),
            _ = indexAsyncRoots(Roots),
            {ok, #{action => started, roots => Roots, previous => Status}};
        {false, _, _, []} ->
            {error, #{reason => noCodeRoots, status => Status}}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 调用 aliCore 进行代码搜索（无过滤条件）
%%
%% @param Query 查询字符串
%% @param Limit 返回结果的最大数量
%% @return {ok, Result} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
search(Query, Limit) ->
    search(Query, Limit, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 调用 aliCore 进行代码搜索（带过滤条件）
%%
%% @param Query 查询字符串
%% @param Limit 返回结果的最大数量
%% @param Filters 过滤条件映射
%% @return {ok, Result} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
search(Query, Limit, Filters) when is_map(Filters) ->
    Body = maps:merge(#{query => Query, limit => Limit}, Filters),
    request(post, "/search", Body).

%%--------------------------------------------------------------------
%% @doc
%% 获取指定模块函数的符号信息；Module 为 undefined 时不带 module 字段
%%
%% @param Module 模块名或 undefined
%% @param Function 函数名
%% @param Arity 参数个数
%% @return {ok, Result} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
getSymbol(Module, Function, Arity) ->
    Args0 = #{function => Function, arity => Arity},
    Args = case Module of
        undefined -> Args0;
        _ -> Args0#{module => Module}
    end,
    request(post, "/symbol", Args).

%%--------------------------------------------------------------------
%% @doc
%% 列出指定模块中的所有符号
%%
%% @param Module 模块名
%% @return {ok, Result} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
moduleSymbols(Module) ->
    request(post, "/module_symbols", #{module => Module}).

%%--------------------------------------------------------------------
%% @doc
%% 列出已索引模块摘要（可按模块名/路径过滤）。
%% Opts: `#{q => binary(), limit => integer(), offset => integer()}`。
%% @end
%%--------------------------------------------------------------------
listModules() ->
    listModules(#{}).

listModules(Opts) when is_map(Opts) ->
    Q = maps:get(<<"q">>, Opts, maps:get(q, Opts, undefined)),
    Limit = maps:get(<<"limit">>, Opts, maps:get(limit, Opts, 100)),
    Offset = maps:get(<<"offset">>, Opts, maps:get(offset, Opts, 0)),
    Body0 = #{limit => Limit, offset => Offset},
    Body = case Q of
        undefined -> Body0;
        null -> Body0;
        <<>> -> Body0;
        _ -> Body0#{q => Q}
    end,
    request(post, "/modules", Body).

%%--------------------------------------------------------------------
%% @doc 获取模块依赖图（该模块调用了哪些其他模块）
%%--------------------------------------------------------------------
moduleDeps(Module) ->
    request(post, "/module_deps", #{module => Module}).

%%--------------------------------------------------------------------
%% @doc
%% 获取整个项目的调用图
%%
%% @return {ok, Result} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
callGraph() ->
    request(get, "/call_graph", undefined).

%%--------------------------------------------------------------------
%% @doc
%% 获取指定模块函数的所有调用方
%%
%% @param Module 模块名或 undefined
%% @param Function 函数名
%% @param Arity 参数个数
%% @return {ok, Result} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
getCallers(Module, Function, Arity) ->
    graphRequest("/callers", Module, Function, Arity).

%%--------------------------------------------------------------------
%% @doc
%% 获取指定模块函数的所有被调用方
%%
%% @param Module 模块名或 undefined
%% @param Function 函数名
%% @param Arity 参数个数
%% @return {ok, Result} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
getCallees(Module, Function, Arity) ->
    graphRequest("/callees", Module, Function, Arity).

%%--------------------------------------------------------------------
%% @doc
%% 通用调用图请求内部封装：根据 Module 是否为 undefined 组装请求体
%%
%% @param Path 调用图接口路径
%% @param Module 模块名或 undefined
%% @param Function 函数名
%% @param Arity 参数个数
%% @return {ok, Result} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
graphRequest(Path, Module, Function, Arity) ->
    Body0 = #{function => Function, arity => Arity},
    Body = case Module of
        undefined -> Body0;
        _ -> Body0#{module => Module}
    end,
    request(post, Path, Body).

%%--------------------------------------------------------------------
%% @doc
%% 获取当前向量嵌入（embedding）的 schema 信息
%%
%% @return {ok, Result} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
embeddingSchema() ->
    request(get, "/embedding_schema", undefined).

%%--------------------------------------------------------------------
%% @doc
%% 执行数据库查询（默认 read 模式）
%%
%% @param Sql SQL 语句
%% @param Params 参数列表
%% @return {ok, Result} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
dbQuery(Sql, Params) ->
    dbQuery(Sql, Params, read).

%%--------------------------------------------------------------------
%% @doc
%% 执行数据库查询，可指定模式（read/write）
%%
%% @param Sql SQL 语句
%% @param Params 参数列表
%% @param Mode 查询模式
%% @return {ok, Result} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
dbQuery(Sql, Params, Mode) ->
    Body = #{
        sql => toBinary(Sql),
        params => paramsToJson(Params),
        mode => atom_to_binary(Mode, utf8)
    },
    request(post, "/db/query", Body).

%%--------------------------------------------------------------------
%% @doc
%% 查询数据库适配器的状态
%%
%% @return {ok, Result} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
dbStatus() ->
    request(get, "/db/status", undefined).

%%--------------------------------------------------------------------
%% @doc
%% 新增或更新一条记忆条目
%%
%% @param Id 记忆 ID
%% @param Content 记忆内容
%% @return {ok, Result} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
memoryUpsert(Id, Content) ->
    request(post, "/memory/upsert", #{
        id => memoryId(Id),
        content => memoryContent(Content)
    }).

%%--------------------------------------------------------------------
%% @doc
%% 按关键词搜索记忆条目
%%
%% @param Query 查询字符串
%% @param Limit 返回结果的最大数量
%% @return {ok, Result} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
memorySearch(Query, Limit) ->
    request(post, "/memory/search", #{
        query => toBinary(Query),
        limit => Limit
    }).

%%--------------------------------------------------------------------
%% @doc
%% 按 ID 删除一条记忆条目
%%
%% @param Id 记忆 ID
%% @return {ok, Result} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
memoryDelete(Id) ->
    request(post, "/memory/delete", #{id => memoryId(Id)}).

%%--------------------------------------------------------------------
%% @doc
%% 将不同形式的记忆 ID 转换为整数；非数字形式返回 0
%%
%% @param Id 整数、二进制、列表或其他
%% @return 整数 ID
%% @end
%%--------------------------------------------------------------------
memoryId(Id) when is_integer(Id) -> Id;
memoryId(Id) when is_binary(Id) ->
    try binary_to_integer(Id) catch _:_ -> 0 end;
memoryId(Id) when is_list(Id) ->
    try list_to_integer(Id) catch _:_ -> 0 end;
memoryId(_) -> 0.

%%--------------------------------------------------------------------
%% @doc
%% 将记忆内容转换为 Rust 端期望的字符串形式：
%% 二进制原样返回；可打印列表转二进制；其他列表 JSON 编码；
%% 原子转 UTF-8 二进制；其他项 JSON 编码
%% @param Content 原始记忆内容
%% @return 二进制字符串
%% @end
%%--------------------------------------------------------------------
%% Rust MemoryUpsertRequest.content is String — never send maps/terms raw.
memoryContent(Content) when is_binary(Content) -> Content;
memoryContent(Content) when is_list(Content) ->
    case io_lib:printable_unicode_list(Content) of
        true -> unicode:characters_to_binary(Content);
        false -> alJson:encode(Content)
    end;
memoryContent(Content) when is_atom(Content) -> atom_to_binary(Content, utf8);
memoryContent(Content) -> alJson:encode(Content).

%%--------------------------------------------------------------------
%% @doc
%% 查询当前索引状态
%%
%% @return {ok, Result} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
indexStatus() ->
    request(get, "/index/status", undefined).

%%--------------------------------------------------------------------
%% @doc
%% 调用 aliCore 的统一搜索接口
%%
%% @param Query 查询字符串
%% @param Limit 返回结果的最大数量
%% @return {ok, Result} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
searchUnified(Query, Limit) ->
    request(post, "/search/unified", #{query => Query, limit => Limit}).

%%--------------------------------------------------------------------
%% @doc
%% 导出全项目数据源调用点（ets/mnesia/sql）。
%%
%% 用于回答「项目里哪些函数读 role_tab 表」这类问题。
%% 不依赖命名规范，纯靠 Rust 端静态扫描 ets:lookup/mnesia:read/pg:equery 等调用点。
%%
%% @return {ok, #{data := #{sources := [DataSourceCall]}}} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
dataSources() ->
    request(get, "/data_sources", undefined).

%%--------------------------------------------------------------------
%% @doc
%% 按表名反查哪些函数读这个表（ets/mnesia/sql）。
%%
%% @param Table 表名（atom/binary/list，大小写不敏感）
%% @return {ok, #{data := #{table := _, callers := [DataSourceCall]}}} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
dataSourceCallers(Table) ->
    request(post, "/data_source_callers", #{table => toBinary(Table)}).

%%--------------------------------------------------------------------
%% @doc
%% 对指定函数做过程内 use-def chain 分析：返回入参 + 关键局部变量来源。
%%
%% 用于回答「调用 targetFun 之前需要先调哪些转换函数」这类问题。
%% 不依赖函数命名规范，纯靠数据流静态分析推断。
%%
%% @param Module 模块名或 undefined
%% @param Function 函数名
%% @param Arity 元数
%% @return {ok, #{data := ParamSourceResult}} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
paramSources(Module, Function, Arity) ->
    Body0 = #{function => Function, arity => Arity},
    Body = case Module of
        undefined -> Body0;
        _ -> Body0#{module => Module}
    end,
    request(post, "/param_sources", Body).

%%--------------------------------------------------------------------
%% @doc
%% 跨过程递归追溯参数依赖 DAG：从目标函数的第 ParamIndex 个参数出发，
%% 反查 callers 并分析其 use-def chain，构建数据来源 DAG。
%%
%% 用于回答「这个数据是怎么算出来的」「调用链上需要哪些转换函数」
%% 这类问题。不依赖命名规范，纯靠数据流静态分析。
%%
%% 推不出时返回 Unknown 节点，由上层 alContextEngine:traceDataQuery/2 主动反问用户。
%%
%% @param Module 模块名或 undefined
%% @param Function 函数名
%% @param Arity 元数
%% @param ParamIndex 追踪第几个参数（1-based）
%% @return {ok, #{data := DataFlowTrace}} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
traceDataFlow(Module, Function, Arity, ParamIndex) ->
    traceDataFlow(Module, Function, Arity, ParamIndex, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 跨过程数据流追踪（带可选参数：maxDepth、maxNodes）。
%%
%% @param Module 模块名或 undefined
%% @param Function 函数名
%% @param Arity 元数
%% @param ParamIndex 追踪第几个参数（1-based）
%% @param Opts 可选参数：#{maxDepth => pos_integer(), maxNodes => pos_integer()}
%% @return {ok, #{data := DataFlowTrace}} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
traceDataFlow(Module, Function, Arity, ParamIndex, Opts) when is_map(Opts) ->
    Body0 = #{function => Function, arity => Arity, param_index => ParamIndex},
    Body1 = case Module of
        undefined -> Body0;
        _ -> Body0#{module => Module}
    end,
    %% Rust serde 默认期望 snake_case 字段名；保留 max_depth/max_nodes 原子
    %% 与 Rust struct TraceDataFlowRequest 对齐（避免 camelCase 转换层）。
    OptsSnake = #{},
    OptsSnake1 = case maps:get(maxDepth, Opts, undefined) of
        undefined -> OptsSnake;
        V1 -> OptsSnake#{max_depth => V1}
    end,
    OptsSnake2 = case maps:get(maxNodes, Opts, undefined) of
        undefined -> OptsSnake1;
        V2 -> OptsSnake1#{max_nodes => V2}
    end,
    Body = maps:merge(Body1, OptsSnake2),
    request(post, "/trace_data_flow", Body).

%%--------------------------------------------------------------------
%% @doc
%% 将 SQL 参数归一化为 JSON 数组形式。
%% 必须用 {@link alJson:array/1} 包裹：否则 `[38]` 等可打印整数列表经
%% alJson:sanitize 会收成 `"&"`，Rust 端期望 sequence 时报
%% `invalid type: string, expected a sequence`。
%%
%% @param Params 参数列表或单个参数
%% @return JSON 兼容的参数列表（带 array 标记）
%% @end
%%--------------------------------------------------------------------
paramsToJson(Params) when is_list(Params) ->
    alJson:array([paramToJson(P) || P <- Params]);
paramsToJson(Param) ->
    alJson:array([paramToJson(Param)]).

%%--------------------------------------------------------------------
%% @doc
%% 将单个 SQL 参数转换为 JSON 兼容值：null/undefined 转 null，
%% 基本类型原样返回，原子转二进制，map 原样，其他转格式化字符串
%%
%% @param V 单个参数
%% @return JSON 兼容值
%% @end
%%--------------------------------------------------------------------
paramToJson(null) -> null;
paramToJson(undefined) -> null;
paramToJson(V) when is_integer(V); is_float(V); is_boolean(V); is_binary(V) -> V;
paramToJson(V) when is_list(V) ->
    case io_lib:printable_unicode_list(V) of
        true -> unicode:characters_to_binary(V);
        false -> [paramToJson(Item) || Item <- V]
    end;
paramToJson(V) when is_atom(V) -> atom_to_binary(V, utf8);
paramToJson(V) when is_map(V) -> V;
paramToJson(V) -> unicode:characters_to_binary(io_lib:format("~p", [V])).

%%--------------------------------------------------------------------
%% @doc
%% 判断 aliCore 是否在配置中启用
%%
%% @return boolean()
%% @end
%%--------------------------------------------------------------------
enabled() ->
    Core = coreConfig(),
    maps:get(enabled, Core, false).

%%--------------------------------------------------------------------
%% @doc 当前托管的 aliCore OS 进程 PID（停止前用于兜底杀进程）。
%% @end
%%--------------------------------------------------------------------
childOsPid() ->
    try gen_server:call(?SERVER, eChildOsPid, 2000) of
        Pid -> Pid
    catch
        _:_ -> undefined
    end.

%%--------------------------------------------------------------------
%% @doc
%% gen_server 初始化：捕获退出信号；未启用时返回空状态，
%% 启用时尝试打开 port，失败则记录告警并返回无 port 的空状态
%%
%% @param [] 启动参数
%% @return {ok, State}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    process_flag(trap_exit, true),
    case enabled() of
        false ->
            {ok, emptyState(false)};
        true ->
            case openCorePort() of
                {ok, Port} ->
                    application:set_env(ali, coreAvailable, true),
                    {ok, emptyState(true, Port)};
                {error, Reason} ->
                    logger:warning("aliCore port open failed: ~p", [Reason]),
                    application:set_env(ali, coreAvailable, false),
                    {ok, emptyState(true)}
            end
    end.

%% 构造无 port 的初始状态
emptyState(Enabled) ->
    emptyState(Enabled, undefined).

%% 构造初始状态：多 inflight map + 排队队列 + 分桶计数
emptyState(Enabled, Port) ->
    #{enabled => Enabled, port => Port, os_pid => alOsProc:osPid(Port),
      inflight => #{}, queue => queue:new(), nextSeq => 1,
      counts => emptyCounts(), limits => concurrencyLimits()}.

emptyCounts() ->
    #{index => 0, search => 0, db => 0, memory => 0,
      memoryWrite => 0, graph => 0, other => 0}.

%%--------------------------------------------------------------------
%% @doc 并发上限（来自 core 配置，带默认值）。
%% @end
%%--------------------------------------------------------------------
-spec concurrencyLimits() -> map().
concurrencyLimits() ->
    Core = coreConfig(),
    maps:merge(?DefaultLimits, #{
        max => maps:get(maxInflight, Core, ?DefaultMaxInflight),
        index => maps:get(limitIndex, Core, 1),
        search => maps:get(limitSearch, Core, 8),
        db => maps:get(limitDb, Core, 4),
        memory => maps:get(limitMemory, Core, 8),
        memoryWrite => maps:get(limitMemoryWrite, Core, 2),
        graph => maps:get(limitGraph, Core, 4),
        other => maps:get(limitOther, Core, 8),
        multi => maps:get(multiInflight, Core, true) =/= false
    }).

%%--------------------------------------------------------------------
%% @doc 路径 → 并发桶（与 Rust path_class 对齐）。
%% @end
%%--------------------------------------------------------------------
-spec pathClass(iodata()) -> atom().
pathClass(Path0) ->
    Path = unicode:characters_to_list(Path0),
    case Path of
        "/index" -> index;
        "/search" -> search;
        "/search/unified" -> search;
        "/memory/search" -> memory;
        "/memory/upsert" -> memoryWrite;
        "/memory/delete" -> memoryWrite;
        "/db/" ++ _ -> db;
        "/callers" -> graph;
        "/callees" -> graph;
        "/call_graph" -> graph;
        "/data_sources" -> graph;
        "/data_source_callers" -> graph;
        "/param_sources" -> graph;
        "/trace_data_flow" -> graph;
        "/module_deps" -> graph;
        "/module_symbols" -> graph;
        "/symbol" -> graph;
        "/embedding_schema" -> graph;
        _ -> other
    end.
%%--------------------------------------------------------------------
%% @doc
%% gen_server handle_call：port 未启动时直接返回 portClosed 错误；
%% 否则将请求入队并异步处理；其他未知请求返回 badRequest
%% @end
%%--------------------------------------------------------------------
handle_call({eRequest, _Method, _Path, _Body, _Timeout}, _From, State = #{port := undefined}) ->
    {reply, {error, #{engine => rustCore, kind => portClosed, reason => notStarted}}, State};
handle_call({eRequest, Method, Path, Body, TimeoutMs}, From, State) ->
    Req = {From, Method, Path, Body, TimeoutMs},
    {noreply, enqueueRequest(Req, State)};
handle_call(eChildOsPid, _From, State) ->
    Pid = case maps:get(port, State, undefined) of
        Port when is_port(Port) -> alOsProc:osPid(Port);
        _ -> maps:get(os_pid, State, undefined)
    end,
    {reply, Pid, State};
handle_call(eRestartPort, _From, State) ->
    %% 关掉旧 port（必要时杀 OS 进程），清 inflight/queue，再拉起新 core。
    Inflight = maps:get(inflight, State, #{}),
    Queue = maps:get(queue, State, queue:new()),
    Error = {error, #{engine => rustCore, kind => restarting}},
    maps:foreach(fun(_Seq, Meta) ->
        cancelTimer(maps:get(timer, Meta, undefined)),
        try gen_server:reply(maps:get(from, Meta), Error) catch _:_ -> ok end
    end, Inflight),
    lists:foreach(fun({From, _, _, _, _}) ->
        try gen_server:reply(From, Error) catch _:_ -> ok end
    end, queue:to_list(Queue)),
    State1 = closePort(State#{
        inflight => #{},
        queue => queue:new(),
        counts => emptyCounts()
    }),
    case openCorePort() of
        {ok, Port} ->
            application:set_env(ali, coreAvailable, true),
            %% 重启后允许再打印一次状态
            application:set_env(ali, coreStatusPrinted, false),
            State2 = State1#{port => Port, os_pid => alOsProc:osPid(Port),
                             limits => concurrencyLimits()},
            shellStatus(<<"aliCore 已重启（indexing 状态已重置）"/utf8>>),
            {reply, ok, dispatchNext(State2)};
        {error, Reason} ->
            application:set_env(ali, coreAvailable, false),
            {reply, {error, Reason}, State1#{port => undefined}}
    end;
handle_call(_Request, _From, State) ->
    %% e.g. supervisor:which_children/1 probes non-supervisor workers
    {reply, {error, badRequest}, State}.

%% gen_server handle_cast：缓存启动探测快照；忽略其它 cast
handle_cast({eHealthSnapshot, Snapshot}, State) when is_map(Snapshot) ->
    {noreply, State#{healthSnapshot => Snapshot}};
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @doc
%% 启动/重连后汇总探测：/health + /db/status，供日志与缓存。
%% 启动瞬间 port 可能尚未就绪，允许有限次重试。
%% @end
%%--------------------------------------------------------------------
collectStartupSnapshot(Retries) when is_integer(Retries), Retries =< 1 ->
    doCollectStartupSnapshot();
collectStartupSnapshot(Retries) when is_integer(Retries) ->
    case doCollectStartupSnapshot() of
        {ok, _} = Ok -> Ok;
        {error, _} = Err ->
            timer:sleep(300),
            case collectStartupSnapshot(Retries - 1) of
                {ok, _} = Ok2 -> Ok2;
                {error, _} -> Err
            end
    end.

doCollectStartupSnapshot() ->
    case health() of
        {ok, Health0} ->
            Health = normalizeMap(Health0),
            Db = case dbStatus() of
                {ok, Db0} -> normalizeMap(Db0);
                {error, DbErr} -> #{error => DbErr}
            end,
            {ok, #{
                at => erlang:system_time(second),
                binary => coreBinary(),
                health => Health,
                db => Db
            }};
        {error, _} = Err ->
            Err
    end.

%% 把启动探测结果打到 shell（io:format）+ logger，避免被 Booted 刷屏淹没。
logStartupSnapshot(#{health := Health, db := Db, binary := Bin}) ->
    IndexReady = mapGet(Health, [index_ready, indexReady, <<"index_ready">>], false),
    Indexing = mapGet(Health, [indexing, <<"indexing">>], false),
    Files = mapGet(Health, [index_files, indexFiles, <<"index_files">>], 0),
    Symbols = mapGet(Health, [index_symbols, indexSymbols, <<"index_symbols">>], 0),
    EmbedOn = mapGet(Health, [embedding_configured, embeddingConfigured, <<"embedding_configured">>], false),
    EmbedVec = mapGet(Health, [embedding_vectors, embeddingVectors, <<"embedding_vectors">>], 0),
    QdrantOn = mapGet(Health, [qdrant_configured, qdrantConfigured, <<"qdrant_configured">>], false),
    MemVec = mapGet(Health, [memory_vectors, memoryVectors, <<"memory_vectors">>], 0),
    MemSrc = mapGet(Health, [memory_vectors_source, memoryVectorsSource, <<"memory_vectors_source">>], local),
    DbPath = mapGet(Db, [path, <<"path">>], <<"-">>),
    DbEngine = mapGet(Db, [engine, <<"engine">>], <<"?">>),
    StatusLine = formatUtf8(
        "aliCore 状态~n"
        "  进程: OK  binary=~ts~n"
        "  数据库: ~ts (~ts)~n"
        "  索引: ready=~p indexing=~p files=~p symbols=~p~n"
        "  向量: embedding=~p(~p) qdrant=~p memory=~p(~ts)",
        [toBinary(Bin), toBinary(DbPath), toBinary(DbEngine),
         IndexReady, Indexing, Files, Symbols,
         EmbedOn, EmbedVec, QdrantOn, MemVec, toBinary(MemSrc)]
    ),
    shellStatus(StatusLine).

%% 中文 format 串会产出 >255 码点，必须走 unicode，不能用 iolist_to_binary。
formatUtf8(Fmt, Args) ->
    case unicode:characters_to_binary(io_lib:format(Fmt, Args)) of
        Bin when is_binary(Bin) -> Bin;
        {error, Good, _} -> unicode:characters_to_binary(Good);
        {incomplete, Good, _} -> unicode:characters_to_binary(Good);
        _ -> <<"aliCore status format error">>
    end.

shellStatus(Msg) when is_binary(Msg) ->
    io:format("~n~ts~n", [Msg]),
    logger:info("~ts", [Msg]),
    ok;
shellStatus(Msg) ->
    shellStatus(unicode:characters_to_binary(Msg)).

normalizeMap(Map) when is_map(Map) -> unwrapMap(Map);
normalizeMap(_) -> #{}.

mapGet(Map, Keys, Default) when is_map(Map), is_list(Keys) ->
    case firstPresent(Map, Keys) of
        {ok, V} -> V;
        miss -> Default
    end.

firstPresent(_Map, []) -> miss;
firstPresent(Map, [K | Rest]) ->
    case maps:find(K, Map) of
        {ok, V} -> {ok, V};
        error -> firstPresent(Map, Rest)
    end.

%%--------------------------------------------------------------------
%% @doc
%% gen_server handle_info：处理 port 数据响应、port 关闭/退出、
%% 重连定时器、请求超时等事件
%% @end
%%--------------------------------------------------------------------
handle_info({Port, {data, Data}}, State = #{port := Port}) ->
    {Seq, Reply} = decodePortResponse(Data),
    case resolveInflightSeq(Seq, State) of
        {ok, Seq1} ->
            {noreply, completeInflight(Seq1, Reply, State)};
        error ->
            logger:warning("aliCore response unmatched seq=~p inflight=~p raw=~ts",
                           [Seq, maps:size(maps:get(inflight, State, #{})),
                            previewBin(Data, 200)]),
            {noreply, State}
    end;
handle_info({Port, closed}, State = #{port := Port}) ->
    {noreply, handlePortFailure(portClosed, State)};
handle_info({'EXIT', Port, Reason}, State = #{port := Port}) ->
    logger:warning("aliCore port exited: ~p", [Reason]),
    {noreply, handlePortFailure({portExit, Reason}, State)};
handle_info({Port, {exit_status, Status}}, State = #{port := Port}) ->
    logger:warning("aliCore port exit_status=~p", [Status]),
    {noreply, handlePortFailure({exitStatus, Status}, State)};
handle_info(eReconnectPort, State = #{enabled := true, port := undefined}) ->
    case openCorePort() of
        {ok, Port} ->
            application:set_env(ali, coreAvailable, true),
            Parent = self(),
            _ = alAsync:run(coreStartupSnapshot, fun() ->
                case collectStartupSnapshot(3) of
                    {ok, Snapshot} ->
                        Parent ! {eHealthSnapshot, Snapshot};
                    {error, Reason} ->
                        shellStatus(formatUtf8("aliCore 启动探测失败: ~p~n", [Reason])),
                        logger:warning("aliCore 启动探测失败: ~p", [Reason])
                end
            end),
            logger:debug("aliCore port reconnected", []),
            %% 重连成功后派发已排队请求（断连期间堆积的调用）。
            State1 = State#{port => Port, os_pid => alOsProc:osPid(Port),
                            limits => concurrencyLimits()},
            {noreply, dispatchNext(State1)};
        {error, Reason} ->
            logger:debug("aliCore reconnect failed: ~p", [Reason]),
            {noreply, scheduleReconnect(State)}
    end;
handle_info({eHealthSnapshot, Snapshot}, State) when is_map(Snapshot) ->
    %% 重连探测：只缓存；避免与 ensureAvailable 重复刷屏
    case application:get_env(ali, coreStatusPrinted, false) of
        true ->
            ok;
        _ ->
            markStatusPrinted(),
            logStartupSnapshot(Snapshot)
    end,
    {noreply, State#{healthSnapshot => Snapshot}};
handle_info({timeout, _TimerRef, {eRequestTimeout, Seq}}, State) ->
    %% 单请求超时：只 fail 该 seq，不关 Port（有 seq 不会错配）。
    Inflight = maps:get(inflight, State, #{}),
    case maps:take(Seq, Inflight) of
        {Meta, Rest} ->
            cancelTimer(maps:get(timer, Meta, undefined)),
            try gen_server:reply(maps:get(from, Meta),
                                 {error, #{engine => rustCore, kind => timeout}})
            catch _:_ -> ok end,
            Class = maps:get(class, Meta, other),
            State1 = decCount(State#{inflight => Rest}, Class),
            {noreply, dispatchNext(State1)};
        error ->
            {noreply, State}
    end;
handle_info({timeout, _OtherRef, eRequestTimeout}, State) ->
    %% 旧格式定时器（不应再出现）
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.
%%--------------------------------------------------------------------
%% @doc
%% gen_server terminate：关闭 port（如果存在），吞掉关闭异常
%%
%% @param _Reason 终止原因
%% @param State 当前状态
%% @return ok
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, State) when is_map(State) ->
    Port = maps:get(port, State, undefined),
    OsPid = case Port of
        P when is_port(P) -> alOsProc:osPid(P);
        _ -> maps:get(os_pid, State, undefined)
    end,
    alOsProc:closeAndKill(Port, OsPid),
    ok;
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @doc
%% gen_server code_change：直接保留原状态
%%
%% @return {ok, State}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% @doc
%% 同步请求 aliCore（自动按方法/路径选择超时）
%%
%% @param Method HTTP 方法
%% @param Path 接口路径
%% @param Body 请求体（可为 undefined）
%% @return {ok, Result} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
request(Method, Path, Body) ->
    TimeoutMs = requestTimeout(Method, Path),
    request(Method, Path, Body, TimeoutMs).

%%--------------------------------------------------------------------
%% @doc
%% 同步请求 aliCore（显式指定超时），通过 gen_server:call 转发给服务进程，
%% 捕获各类异常并转换为统一错误格式
%%
%% @param Method HTTP 方法
%% @param Path 接口路径
%% @param Body 请求体
%% @param TimeoutMs 超时毫秒
%% @return {ok, Result} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
request(Method, Path, Body, TimeoutMs) ->
    CallTimeout = TimeoutMs + 5000,
    try gen_server:call(?SERVER, {eRequest, Method, Path, Body, TimeoutMs}, CallTimeout) of
        Reply -> Reply
    catch
        exit:{noproc, _} ->
            {error, #{engine => rustCore, kind => portClosed, reason => noproc}};
        exit:{timeout, _} ->
            {error, #{engine => rustCore, kind => timeout}};
        exit:Reason ->
            {error, #{engine => rustCore, kind => portClosed, reason => Reason}};
        error:Reason ->
            {error, #{engine => rustCore, kind => requestError, reason => Reason}}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 根据请求方法和路径选择超时：POST /index 使用 indexTimeout，
%% 其他使用默认 timeout
%%
%% @param Method HTTP 方法
%% @param Path 接口路径
%% @return 超时毫秒
%% @end
%%--------------------------------------------------------------------
requestTimeout(post, "/index") ->
    indexTimeout();
requestTimeout(_, _) ->
    timeout().

%%--------------------------------------------------------------------
%% @doc
%% 请求入队：未满并发上限且 port 可用时直接启动；否则排队。
%% 队列满则立即拒绝（coreBusy/backlog）。
%% @end
%%--------------------------------------------------------------------
enqueueRequest(Req, State) ->
    case maps:get(port, State, undefined) of
        Port when is_port(Port) ->
            {_From, _Method, Path, _Body, _TimeoutMs} = Req,
            Class = pathClass(Path),
            case canStart(Class, State) of
                true ->
                    startInflight(Req, State);
                false ->
                    enqueueWaiting(Req, State)
            end;
        _ ->
            enqueueWaiting(Req, State)
    end.

enqueueWaiting({From, _Method, _Path, _Body, _TimeoutMs} = Req, State) ->
    Queue = maps:get(queue, State, queue:new()),
    case queue:len(Queue) >= ?BacklogHighWatermark of
        true ->
            gen_server:reply(From, {error, #{
                engine => rustCore,
                kind => coreBusy,
                reason => backlog
            }}),
            State;
        false ->
            State#{queue => queue:in(Req, Queue)}
    end.

canStart(Class, State) ->
    Limits = maps:get(limits, State, concurrencyLimits()),
    case maps:get(multi, Limits, true) of
        false ->
            maps:size(maps:get(inflight, State, #{})) =:= 0;
        true ->
            InflightN = maps:size(maps:get(inflight, State, #{})),
            Max = maps:get(max, Limits, ?DefaultMaxInflight),
            Counts = maps:get(counts, State, emptyCounts()),
            ClassN = maps:get(Class, Counts, 0),
            ClassMax = maps:get(Class, Limits, maps:get(other, Limits, 8)),
            InflightN < Max andalso ClassN < ClassMax
    end.

%%--------------------------------------------------------------------
%% @doc
%% 启动一个 inflight：分配 seq、编码、port_command、登记定时器与分桶计数。
%% @end
%%--------------------------------------------------------------------
startInflight({From, Method, Path, Body, TimeoutMs}, State = #{port := Port}) ->
    Seq = maps:get(nextSeq, State, 1),
    Class = pathClass(Path),
    try encodeRequest(Method, Path, Body, Seq) of
        Req ->
            true = erlang:port_command(Port, Req),
            TimerRef = erlang:start_timer(TimeoutMs, self(), {eRequestTimeout, Seq}),
            Meta = #{from => From, timer => TimerRef, class => Class,
                     path => Path, startedAt => erlang:monotonic_time(millisecond)},
            Inflight = maps:get(inflight, State, #{}),
            State1 = incCount(State#{
                inflight => maps:put(Seq, Meta, Inflight),
                nextSeq => Seq + 1
            }, Class),
            State1
    catch
        ClassErr:Reason ->
            gen_server:reply(From, {error, #{
                engine => rustCore,
                kind => encodeError,
                reason => {ClassErr, Reason}
            }}),
            dispatchNext(State)
    end.

incCount(State, Class) ->
    Counts = maps:get(counts, State, emptyCounts()),
    N = maps:get(Class, Counts, 0),
    State#{counts => Counts#{Class => N + 1}}.

decCount(State, Class) ->
    Counts = maps:get(counts, State, emptyCounts()),
    N = maps:get(Class, Counts, 0),
    State#{counts => Counts#{Class => max(0, N - 1)}}.

%% 解析回包中的 seq：正整数直接用；0/缺失时仅当唯一 inflight 才兜底。
resolveInflightSeq(Seq, _State) when is_integer(Seq), Seq > 0 ->
    {ok, Seq};
resolveInflightSeq(Seq, State) when is_float(Seq) ->
    Trunc = trunc(Seq),
    case Trunc > 0 andalso Trunc == Seq of
        true -> {ok, Trunc};
        false -> resolveInflightSeq(undefined, State)
    end;
resolveInflightSeq(_, State) ->
    case maps:to_list(maps:get(inflight, State, #{})) of
        [{OnlySeq, _}] -> {ok, OnlySeq};
        _ -> error
    end.

completeInflight(Seq, Reply, State) when is_integer(Seq) ->
    Inflight = maps:get(inflight, State, #{}),
    case maps:take(Seq, Inflight) of
        {Meta, Rest} ->
            cancelTimer(maps:get(timer, Meta, undefined)),
            try gen_server:reply(maps:get(from, Meta), Reply) catch _:_ -> ok end,
            Class = maps:get(class, Meta, other),
            dispatchNext(decCount(State#{inflight => Rest}, Class));
        error ->
            %% 超时后迟到的响应：忽略，避免错配
            logger:debug("aliCore late/unknown seq=~p ignored", [Seq]),
            State
    end;
completeInflight(_, _Reply, State) ->
    State.
%%--------------------------------------------------------------------
%% @doc
%% 派发排队请求：按 FIFO 扫描，能启动的立刻 start，其余保持相对顺序。
%% @end
%%--------------------------------------------------------------------
dispatchNext(State) ->
    case maps:get(port, State, undefined) of
        Port when is_port(Port) ->
            Q = maps:get(queue, State, queue:new()),
            {Rest, State1} = flushQueue(queue:to_list(Q), [], State),
            State1#{queue => queue:from_list(lists:reverse(Rest))};
        _ ->
            State
    end.

flushQueue([], Acc, State) ->
    {Acc, State};
flushQueue([{_From, _Method, Path, _Body, _Timeout} = Req | Rest], Acc, State) ->
    Class = pathClass(Path),
    case canStart(Class, State) of
        true ->
            flushQueue(Rest, Acc, startInflight(Req, State));
        false ->
            flushQueue(Rest, [Req | Acc], State)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 处理 port 失败：标记不可用、回复全部 inflight 与排队请求错误、
%% 关闭 port 并安排重连。
%% @end
%%--------------------------------------------------------------------
handlePortFailure(Reason, State) ->
    application:set_env(ali, coreAvailable, false),
    Inflight = maps:get(inflight, State, #{}),
    Queue = maps:get(queue, State, queue:new()),
    Error = {error, #{engine => rustCore, kind => portClosed, reason => Reason}},
    maps:foreach(fun(_Seq, Meta) ->
        cancelTimer(maps:get(timer, Meta, undefined)),
        try gen_server:reply(maps:get(from, Meta), Error) catch _:_ -> ok end
    end, Inflight),
    lists:foreach(fun({From, _, _, _, _}) ->
        try gen_server:reply(From, Error) catch _:_ -> ok end
    end, queue:to_list(Queue)),
    scheduleReconnect(closePort(State#{
        inflight => #{},
        queue => queue:new(),
        counts => emptyCounts()
    })).

%% 安全取消定时器：吞掉异常，未定义定时器直接返回 ok
cancelTimer(undefined) ->
    ok;
cancelTimer(TimerRef) ->
    try erlang:cancel_timer(TimerRef) catch _:_ -> ok end,
    ok.

previewBin(Bin, N) when is_binary(Bin) ->
    case byte_size(Bin) > N of
        true -> binary:part(Bin, 0, N);
        false -> Bin
    end;
previewBin(Other, _) ->
    iolist_to_binary(io_lib:format("~p", [Other])).

%%--------------------------------------------------------------------
%% @doc
%% 将请求编码为 JSON 二进制：包含 seq、method、path，body 可选
%% @end
%%--------------------------------------------------------------------
encodeRequest(Method, Path, Body, Seq) ->
    MethodBin = atom_to_binary(Method, utf8),
    Payload0 = #{<<"method">> => MethodBin, <<"path">> => toBinary(Path),
                 <<"seq">> => Seq},
    Payload = case Body of
        undefined -> Payload0;
        _ -> Payload0#{<<"body">> => Body}
    end,
    alJson:encode(Payload).

%%--------------------------------------------------------------------
%% @doc
%% 解码 port 返回：`{Seq, {ok|error, Map}}`；无 seq 时返回裸 Reply（兼容）。
%% @end
%%--------------------------------------------------------------------
decodePortResponse(Data) ->
    case decodeJson(Data) of
        {ok, Map} when is_map(Map) ->
            Seq = maps:get(seq, Map, maps:get(<<"seq">>, Map, undefined)),
            Reply = case Map of
                #{ok := true, data := Decoded} ->
                    {ok, #{engine => rustCore, data => normalizeJson(Decoded)}};
                #{ok := false, error := Error} when is_map(Error) ->
                    {error, maps:merge(#{engine => rustCore, kind => portError}, Error)};
                #{<<"ok">> := true, <<"data">> := Decoded} ->
                    {ok, #{engine => rustCore, data => normalizeJson(Decoded)}};
                #{<<"ok">> := false, <<"error">> := Error} when is_map(Error) ->
                    {error, maps:merge(#{engine => rustCore, kind => portError}, Error)};
                Other ->
                    {error, #{engine => rustCore, kind => decodeError, raw => Other}}
            end,
            {Seq, Reply};
        {error, Reason} ->
            {undefined, {error, #{engine => rustCore, kind => decodeError,
                                  reason => Reason, raw => Data}}}
    end.%%--------------------------------------------------------------------
%% @doc
%% 剥掉 port 包装：`{ok, #{engine, data := Payload}}` → `{ok, Payload}`。
%% 工具层/分析层必须用此函数，否则顶层取 hits/deps/edges 会静默得到空。
%% @end
%%--------------------------------------------------------------------
-spec unwrap(term()) -> {ok, map()} | {error, term()} | term().
unwrap({ok, Map}) when is_map(Map) ->
    {ok, unwrapMap(Map)};
unwrap(Other) ->
    Other.

-spec unwrapMap(map()) -> map().
unwrapMap(#{data := Data}) when is_map(Data) -> Data;
unwrapMap(#{<<"data">> := Data}) when is_map(Data) -> Data;
unwrapMap(Map) when is_map(Map) -> Map;
unwrapMap(_) -> #{}.

%%--------------------------------------------------------------------
%% @doc
%% 解析 JSON 响应体并归一化；捕获异常时返回 {error, {Class, Reason}}
%%
%% @param RespBody 响应体二进制
%% @return {ok, Decoded} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
decodeJson(RespBody) ->
    try alJson:decode(RespBody) of
        Decoded -> {ok, normalizeJson(Decoded)}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 递归归一化 JSON 数据：map 的键转换为已存在的原子（无法转换则保留），
%% 列表逐项归一化，其他值原样返回
%%
%% @param Map|List|Value 输入值
%% @return 归一化后的值
%% @end
%%--------------------------------------------------------------------
normalizeJson(Map) when is_map(Map) ->
    maps:from_list([{normalizeKey(Key), normalizeJson(Value)} || {Key, Value} <- maps:to_list(Map)]);
normalizeJson(List) when is_list(List) ->
    [normalizeJson(Value) || Value <- List];
normalizeJson(Value) ->
    Value.

%% 将二进制键转换为已存在的原子；不存在时保留二进制
normalizeKey(Key) when is_binary(Key) ->
    try binary_to_existing_atom(Key, utf8) catch _:_ -> Key end;
normalizeKey(Key) ->
    Key.

%%--------------------------------------------------------------------
%% @doc
%% 关闭 port 并将 port 字段置为 undefined；非 port 时直接置 undefined
%%
%% @param State 当前状态
%% @return 更新后的状态
%% @end
%%--------------------------------------------------------------------
%%--------------------------------------------------------------------
%% @doc
%% 运行时关闭 port（超时/重连）：只 port_close，靠 stdin EOF 让子进程退出。
%% 禁止在此路径 forceKill——Linux 上 SIGTERM 会打断正在进行的索引/查询，
%% 并触发「aliCore received shutdown signal」后反复重连，导致问答假死。
%% 应用停止时的强杀见 terminate/2。
%%
%% @param State 当前状态
%% @return 更新后的状态
%% @end
%%--------------------------------------------------------------------
closePort(State = #{port := Port}) when is_port(Port) ->
    alOsProc:closePort(Port),
    State#{port => undefined, os_pid => undefined};
closePort(State) ->
    State#{port => undefined, os_pid => undefined}.

%%--------------------------------------------------------------------
%% @doc
%% 安排 port 重连：未启用时直接返回状态；
%% 启用时通过 send_after 安排一次 eReconnectPort 消息
%%
%% @param State 当前状态
%% @return 更新后的状态
%% @end
%%--------------------------------------------------------------------
scheduleReconnect(State = #{enabled := false}) ->
    State;
scheduleReconnect(State) ->
    erlang:send_after(?ReconnectMs, self(), eReconnectPort),
    State.

%%--------------------------------------------------------------------
%% @doc
%% 打开 aliCore port：检查二进制文件存在后以 {packet, 4} 模式启动 port
%%
%% @return {ok, Port} 或 {error, {binaryMissing, Bin}}
%% @end
%%--------------------------------------------------------------------
%%--------------------------------------------------------------------
%% @doc
%% 打开 aliCore port：检查二进制文件存在后以 {packet, 4} 模式启动。
%% 业务配置只通过 {@link portArgs/0} 传入；不注入 ALI_* 环境变量
%% （子进程继承 OS 环境即可，如 PATH）。
%% @end
%%--------------------------------------------------------------------
openCorePort() ->
    Bin = coreBinary(),
    case filelib:is_file(Bin) of
        true ->
            Port = open_port(
                {spawn_executable, Bin},
                [
                    {args, portArgs()},
                    stream,
                    {packet, 4},
                    binary,
                    use_stdio,
                    exit_status
                ]
            ),
            {ok, Port};
        false ->
            {error, {binaryMissing, Bin}}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 获取 port 启动参数：cfg → {@link alConfig:corePortArgs/0}
%% （`--port` + 需要的 `--ali-*=`，不需要的不传）。
%% @end
%%--------------------------------------------------------------------
portArgs() ->
    alConfig:corePortArgs().

%%--------------------------------------------------------------------
%% @doc
%% 获取 aliCore 二进制路径：优先使用配置中的 binary，
%% 否则回退到 defaultBinary()
%%
%% @return 二进制路径字符串
%% @end
%%--------------------------------------------------------------------
coreBinary() ->
    case maps:get(binary, coreConfig(), undefined) of
        Bin when is_list(Bin); is_binary(Bin) ->
            toList(Bin);
        _ ->
            defaultBinary()
    end.

%%--------------------------------------------------------------------
%% @doc
%% 经 code:priv_dir(ali) 定位 priv 根目录下的 aliCore 可执行文件。
%%
%% @return 二进制路径
%% @end
%%--------------------------------------------------------------------
defaultBinary() ->
    alConfig:resolvePrivBinary(binaryName()).

%%--------------------------------------------------------------------
%% @doc
%% 根据操作系统类型返回 aliCore 二进制文件名（Windows 带 .exe 后缀）
%%
%% @return 二进制文件名字符串
%% @end
%%--------------------------------------------------------------------
binaryName() ->
    case os:type() of
        {win32, _} -> "aliCore.exe";
        _ -> "aliCore"
    end.

%%--------------------------------------------------------------------
%% @doc
%% 获取默认请求超时（默认 30000 毫秒）
%%
%% @return 超时毫秒
%% @end
%%--------------------------------------------------------------------
timeout() ->
    maps:get(timeout, coreConfig(), 30000).

%%--------------------------------------------------------------------
%% @doc
%% 获取索引操作的超时（默认 600000 毫秒）
%%
%% @return 超时毫秒
%% @end
%%--------------------------------------------------------------------
indexTimeout() ->
    maps:get(indexTimeout, coreConfig(), 600000).

%%--------------------------------------------------------------------
%% @doc
%% 获取 aliCore 配置映射（默认空映射）
%%
%% @return 配置映射
%% @end
%%--------------------------------------------------------------------
coreConfig() ->
    alConfig:get(core, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 将值转换为列表：原子转列表、二进制转列表、列表原样返回
%%
%% @param Value 输入值
%% @return 列表
%% @end
%%--------------------------------------------------------------------
toList(Value) when is_atom(Value) ->
    atom_to_list(Value);
toList(Value) when is_binary(Value) ->
    unicode:characters_to_list(Value);
toList(Value) when is_list(Value) ->
    Value.

%%--------------------------------------------------------------------
%% @doc
%% 将值转换为二进制：二进制原样、原子转 UTF-8、列表转码、其他用 ~p 格式化
%%
%% @param Value 输入值
%% @return 二进制
%% @end
%%--------------------------------------------------------------------
toBinary(Value) when is_binary(Value) ->
    Value;
toBinary(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
toBinary(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
toBinary(Value) ->
    unicode:characters_to_binary(io_lib:format("~p", [Value])).
