%%%-------------------------------------------------------------------
%% @doc 数据库适配器 —— 内嵌 SQLite（本地），零外部部署。
%% SQL 采用 PostgreSQL 兼容写法；数据文件默认位于 `<dataDir>/db/ali.db`（`.ali/db/`）。
%% @end
%%%-------------------------------------------------------------------

-module(alDbAdapter).

-export([query/1, status/0, ensureStarted/0]).

%%--------------------------------------------------------------------
%% @doc
%% 执行 SQL 查询。支持三种入参形式：
%%   * map —— 含 sql/params/mode 等字段
%%   * list/binary —— 直接作为 SQL 文本（mode 默认为 read）
%%   * 其他 —— 返回 invalidQuery 错误
%% 当适配器被禁用时直接返回 dbAdapterDisabled 错误。
%%
%% @param Args map | iolist | binary
%% @return {ok, Result} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
query(Args) when is_map(Args) ->
    case enabled() of
        false ->
            {error, #{reason => dbAdapterDisabled}};
        true ->
            runQuery(Args)
    end;
query(Sql) when is_list(Sql); is_binary(Sql) ->
    query(#{sql => Sql});
query(Args) ->
    {error, #{reason => invalidQuery, args => Args}}.

%%--------------------------------------------------------------------
%% @doc
%% 返回数据库适配器当前的状态快照，包含是否启用、后端类型、
%% 引擎（sqlite）、部署方式（embedded）以及本地数据库状态。
%%
%% @return 状态 map
%% @end
%%--------------------------------------------------------------------
status() ->
    #{
        enabled => enabled(),
        backend => backend(),
        engine => sqlite,
        deployment => embedded,
        local => safeCall(fun alLocalDb:status/0)
    }.

%%--------------------------------------------------------------------
%% @doc
%% 确保数据库已启动：进程已在跑则直接返回 `{ok, Pid}'（幂等），
%% 否则 `start_link`。切勿在已由 {@link ali_sup} 托管时再强制 start_link。
%%
%% @return ok | {ok, pid()} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
ensureStarted() ->
    case enabled() of
        false ->
            ok;
        true ->
            case whereis(alLocalDb) of
                Pid when is_pid(Pid) ->
                    {ok, Pid};
                undefined ->
                    alLocalDb:start_link()
            end
    end.

%% 从配置读取适配器是否启用，默认为 true。
enabled() ->
    maps:get(enabled, adapterConfig(), true).

%% 从配置读取后端类型，默认为 local。
backend() ->
    maps:get(backend, adapterConfig(), local).

%%--------------------------------------------------------------------
%% @doc
%% 执行实际的查询：先校验 SQL（含模式与读写权限），再分发到
%% localQuery。
%%
%% @param Args 含 sql/params/mode 的 map
%% @return {ok, Result} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
runQuery(Args) ->
    Sql = maps:get(sql, Args, undefined),
    Params = maps:get(params, Args, []),
    Mode = maps:get(mode, Args, read),
    case validateSql(Sql, Mode) of
        {error, Reason} ->
            {error, Reason};
        ok ->
            localQuery(Sql, Params, Mode)
    end.

%% 根据 mode 分发到 alLocalDb 的不同接口：
%%   write  -> execute（写操作）
%%   insert -> insert（插入）
%%   其他   -> query（读操作）
localQuery(Sql, Params, write) ->
    alLocalDb:execute(Sql, Params);
localQuery(Sql, Params, insert) ->
    alLocalDb:insert(Sql, Params);
localQuery(Sql, Params, _Read) ->
    alLocalDb:query(Sql, Params).

%%--------------------------------------------------------------------
%% @doc
%% 校验 SQL 合法性与权限：
%%   * undefined —— missingSql
%%   * write 模式但 SQL 是只读 —— writeModeRequired
%%   * insert 模式 —— 直接通过
%%   * 其他 —— 若 SQL 含写操作但配置禁写则 readOnly
%%
%% @param Sql  SQL 文本
%% @param Mode read | write | insert
%% @return ok | {error, Reason}
%% @end
%%--------------------------------------------------------------------
validateSql(undefined, _) ->
    {error, #{reason => missingSql}};
validateSql(Sql, write) ->
    %% 写模式：必须确非只读语句，且需配置显式允许写（默认禁止）。
    case isSelectOnly(Sql) of
        true -> {error, #{reason => writeModeRequired, sql => Sql}};
        false ->
            case allowWrite() of
                true -> ok;
                false -> {error, #{reason => writeDisabled, sql => Sql}}
            end
    end;
validateSql(Sql, insert) ->
    %% insert 亦属写操作：受 allowWrite 门禁，且拒绝只读语句借道 insert。
    case allowWrite() of
        false -> {error, #{reason => writeDisabled, sql => Sql}};
        true ->
            case isSelectOnly(Sql) of
                true -> {error, #{reason => writeModeRequired, sql => Sql}};
                false -> ok
            end
    end;
validateSql(Sql, _) ->
    %% read 路径强制只读：非只读语句一律拒绝，不再受 allowWrite 影响。
    case isSelectOnly(Sql) of
        true -> ok;
        false -> {error, #{reason => readOnly, sql => Sql}}
    end.

%% 是否允许写操作，默认 false（安全起见需显式开启）。
allowWrite() ->
    maps:get(allowWrite, adapterConfig(), false) =:= true.

%%--------------------------------------------------------------------
%% @doc
%% 判断 SQL 是否为纯读语句。加固点：
%%   * 先剥离行注释（--）与块注释（/* */），防止注释绕过检测；
%%   * 拒绝多语句（去尾分号后仍含分号），防止 `SELECT 1; DROP TABLE`；
%%   * 必须以只读关键字（select/explain/pragma/with/values）开头；
%%   * 语句中不得出现任何写/DDL 关键字（按词边界匹配），从而拦截
%%     `WITH ... DELETE`、子查询夹带写操作等情形。
%%
%% @param Sql SQL 文本（list | binary）
%% @return boolean
%% @end
%%--------------------------------------------------------------------
isSelectOnly(Sql) ->
    Norm = normalizeSql(Sql),
    case Norm of
        <<>> -> false;
        _ ->
            isSingleStatement(Norm)
                andalso startsWithReadKeyword(Norm)
                andalso (not containsWriteKeyword(Norm))
    end.

%% 归一化 SQL：转 binary、小写、去注释、压缩空白并去首尾空白。
normalizeSql(Sql) ->
    Bin = unicode:characters_to_binary(toList(Sql)),
    Lower = string:lowercase(Bin),
    NoLine = re:replace(Lower, <<"--[^\\n]*">>, <<" ">>, [global, {return, binary}]),
    NoBlock = re:replace(NoLine, <<"/\\*.*?\\*/">>, <<" ">>, [global, dotall, {return, binary}]),
    Collapsed = re:replace(NoBlock, <<"\\s+">>, <<" ">>, [global, {return, binary}]),
    string:trim(Collapsed).

%% 单语句判定：去掉末尾分号后中间不应再有分号。
isSingleStatement(Bin) ->
    Trimmed = string:trim(string:trim(Bin, trailing, ";")),
    binary:match(Trimmed, <<";">>) =:= nomatch.

%% 是否以只读关键字开头。
%% PRAGMA 不能全放行：很多 PRAGMA 形式上像读但实际可写
%% （`PRAGMA journal_mode=WAL`、`PRAGMA foreign_keys=ON`、`PRAGMA wal_checkpoint` 等
%% 都会修改数据库状态或副作用）。当前 Erlang 端没有任何合法 PRAGMA 调用方，
%% 因此 read 路径完全拒绝 PRAGMA；Rust 端在 db.rs 中自行管理 PRAGMA，不经此校验。
startsWithReadKeyword(Bin) ->
    case Bin of
        <<"pragma", _/binary>> ->
            false;
        _ ->
            lists:any(
                fun(Prefix) -> string:prefix(Bin, Prefix) =/= nomatch end,
                [<<"select ">>, <<"select\t">>, <<"select(">>,
                 <<"explain">>, <<"with ">>, <<"values ">>]
            )
    end.

%% 是否含任一写/DDL 关键字（按词边界匹配，避免误伤列名如 updated_at）。
containsWriteKeyword(Bin) ->
    lists:any(
        fun(Kw) ->
            re:run(Bin, <<"\\b", Kw/binary, "\\b">>, [{capture, none}]) =:= match
        end,
        [<<"insert">>, <<"update">>, <<"delete">>, <<"drop">>,
         <<"alter">>, <<"create">>, <<"replace">>, <<"truncate">>,
         <<"merge">>, <<"grant">>, <<"revoke">>, <<"attach">>, <<"detach">>]
    ).

%% 从 alConfig 读取 db 段配置，默认空 map。
adapterConfig() ->
    alConfig:get(db, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 安全执行 Fun：捕获所有异常，失败时返回 unavailable，
%% 避免状态查询因底层异常而崩溃。
%%
%% @param Fun 待执行的零元函数
%% @return Fun 的返回值 | unavailable
%% @end
%%--------------------------------------------------------------------
safeCall(Fun) ->
    try Fun() of
        Value -> Value
    catch
        _:_ -> unavailable
    end.

%% 把 binary 转为 list（用于 SQL 文本统一处理）；list 原样返回。
toList(Value) when is_binary(Value) ->
    unicode:characters_to_list(Value);
toList(Value) when is_list(Value) ->
    Value.
