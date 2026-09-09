%%%-------------------------------------------------------------------
%% @doc 只读浏览 `.ali/db/ali.db` 白名单表，供 Web「数据」面板使用。
%% @end
%%%-------------------------------------------------------------------

-module(alDbBrowse).

-export([
    tables/0,
    list/2,
    tableMeta/1
]).

-define(Tables, [
    memories,
    critique_logs,
    sessions,
    session_messages,
    session_artifacts,
    pending_approvals,
    module_summaries,
    simulation_runs,
    metric_snapshots,
    audit_archive
]).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc 返回白名单表及行数、中文说明。
%% @end
%%--------------------------------------------------------------------
-spec tables() -> {ok, [map()]} | {error, term()}.
tables() ->
    try
        Items = lists:map(fun(Name) ->
            Meta = tableMeta(Name),
            Count = case countRows(Name) of
                {ok, N} -> N;
                _ -> 0
            end,
            Meta#{name => atom_to_binary(Name, utf8), count => Count}
        end, ?Tables),
        {ok, Items}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

%%--------------------------------------------------------------------
%% @doc 列出某表白名单行。Opts：limit / offset / q（模糊搜文本列）。
%% @end
%%--------------------------------------------------------------------
-spec list(atom() | binary() | string(), map()) -> {ok, map()} | {error, term()}.
list(Table0, Opts) when is_map(Opts) ->
    case normalizeTable(Table0) of
        {error, _} = E ->
            E;
        {ok, Table} ->
            Limit = clamp(maps:get(limit, Opts, maps:get(<<"limit">>, Opts, 50)), 1, 200),
            Offset = clamp(maps:get(offset, Opts, maps:get(<<"offset">>, Opts, 0)), 0, 100000),
            Q = trimBin(maps:get(q, Opts, maps:get(<<"q">>, Opts, <<>>))),
            Meta = tableMeta(Table),
            case fetchRows(Table, Q, Limit, Offset) of
                {ok, Rows} ->
                    {ok, Meta#{
                        name => atom_to_binary(Table, utf8),
                        count => case countRows(Table) of {ok, N} -> N; _ -> length(Rows) end,
                        limit => Limit,
                        offset => Offset,
                        items => [normalizeRow(R) || R <- Rows]
                    }};
                {error, _} = E ->
                    E
            end
    end.

%%--------------------------------------------------------------------
%% @doc 表元信息：标题与用途说明。
%% @end
%%--------------------------------------------------------------------
-spec tableMeta(atom()) -> map().
tableMeta(memories) ->
    #{
        title => <<"记忆/经验"/utf8>>,
        why => <<"自动蒸馏事实、经验教训（kind=lesson）、对话整理等，写入 .ali/db；召回时注入上下文"/utf8>>
    };
tableMeta(critique_logs) ->
    #{
        title => <<"评审日志"/utf8>>,
        why => <<"Critic 对每轮答案的 verdict/score/feedback，便于审计与复盘"/utf8>>
    };
tableMeta(sessions) ->
    #{
        title => <<"会话"/utf8>>,
        why => <<"会话元数据，重启后可恢复会话列表"/utf8>>
    };
tableMeta(session_messages) ->
    #{
        title => <<"会话消息"/utf8>>,
        why => <<"持久化对话正文，刷新/重启后还能继续聊"/utf8>>
    };
tableMeta(session_artifacts) ->
    #{
        title => <<"会话产物"/utf8>>,
        why => <<"summary / toolTrace / plan / critiques / tokenUsage"/utf8>>
    };
tableMeta(pending_approvals) ->
    #{
        title => <<"待审批"/utf8>>,
        why => <<"写文件/危险工具等待批准的记录与 diff"/utf8>>
    };
tableMeta(module_summaries) ->
    #{
        title => <<"模块摘要"/utf8>>,
        why => <<"LLM 生成的模块级摘要缓存，加速大型项目问答"/utf8>>
    };
tableMeta(simulation_runs) ->
    #{
        title => <<"模拟运行"/utf8>>,
        why => <<"runtime probe / 模拟推演的输入输出与状态"/utf8>>
    };
tableMeta(metric_snapshots) ->
    #{
        title => <<"指标快照"/utf8>>,
        why => <<"按小时归档的 ask/ok/error 等指标"/utf8>>
    };
tableMeta(audit_archive) ->
    #{
        title => <<"审计归档"/utf8>>,
        why => <<"审计日志按小时聚合落库"/utf8>>
    };
tableMeta(_) ->
    #{title => <<"未知表"/utf8>>, why => <<>>}.

%%%===================================================================
%%% Internal
%%%===================================================================

normalizeTable(T) when is_atom(T) ->
    case lists:member(T, ?Tables) of
        true -> {ok, T};
        false -> {error, unknown_table}
    end;
normalizeTable(T) when is_binary(T) ->
    try binary_to_existing_atom(T, utf8) of
        A -> normalizeTable(A)
    catch
        _:_ -> {error, unknown_table}
    end;
normalizeTable(T) when is_list(T) ->
    normalizeTable(unicode:characters_to_binary(T));
normalizeTable(_) ->
    {error, unknown_table}.

countRows(Table) ->
    Sql = "SELECT COUNT(*) AS c FROM " ++ atom_to_list(Table),
    case alLocalDb:query(Sql, []) of
        {ok, [Row | _]} ->
            C = maps:get(c, Row, maps:get(<<"c">>, Row,
                    maps:get(<<"COUNT(*)">>, Row, maps:get('COUNT(*)', Row, 0)))),
            {ok, toInt(C)};
        {ok, []} ->
            {ok, 0};
        {error, _} = E ->
            E
    end.

fetchRows(Table, <<>>, Limit, Offset) ->
    Sql = "SELECT * FROM " ++ atom_to_list(Table)
        ++ " ORDER BY " ++ orderCol(Table) ++ " DESC LIMIT ? OFFSET ?",
    alLocalDb:query(Sql, [Limit, Offset]);
fetchRows(Table, Q, Limit, Offset) ->
    Cols = searchCols(Table),
    case Cols of
        [] ->
            fetchRows(Table, <<>>, Limit, Offset);
        _ ->
            Like = list_to_binary([$% | escapeLike(unicode:characters_to_list(Q)) ++ [$%]]),
            Conds = string:join([C ++ " LIKE ? ESCAPE '\\'" || C <- Cols], " OR "),
            Params = lists:duplicate(length(Cols), Like) ++ [Limit, Offset],
            Sql = "SELECT * FROM " ++ atom_to_list(Table)
                ++ " WHERE (" ++ Conds ++ ") ORDER BY " ++ orderCol(Table)
                ++ " DESC LIMIT ? OFFSET ?",
            alLocalDb:query(Sql, Params)
    end.

%% LIKE 通配符转义（与 alMemory 一致）
escapeLike(Str) when is_list(Str) ->
    lists:flatmap(fun(C) ->
        case C of
            $% -> [$\\, $%];
            $_ -> [$\\, $_];
            $\\ -> [$\\, $\\];
            _ -> [C]
        end
    end, Str).

orderCol(memories) -> "created_at";
orderCol(critique_logs) -> "created_at";
orderCol(sessions) -> "updated_at";
orderCol(session_messages) -> "created_at";
orderCol(session_artifacts) -> "updated_at";
orderCol(pending_approvals) -> "created_at";
orderCol(module_summaries) -> "updated_at";
orderCol(simulation_runs) -> "created_at";
orderCol(metric_snapshots) -> "hour";
orderCol(audit_archive) -> "hour";
orderCol(_) -> "rowid".

searchCols(memories) -> ["content", "tags", "kind", "session_id"];
searchCols(critique_logs) -> ["question", "answer", "verdict", "feedback", "session_id"];
searchCols(sessions) -> ["id", "user"];
searchCols(session_messages) -> ["message", "session_id"];
searchCols(session_artifacts) -> ["summary", "session_id", "plan"];
searchCols(pending_approvals) -> ["tool", "args", "diff", "session_id", "status"];
searchCols(module_summaries) -> ["module", "summary", "file", "functions"];
searchCols(simulation_runs) -> ["scenario_type", "input", "output", "status"];
searchCols(metric_snapshots) -> ["hour"];
searchCols(audit_archive) -> ["hour", "entries_json"];
searchCols(_) -> [].

normalizeRow(Row) when is_map(Row) ->
    maps:map(fun(_K, V) ->
        case V of
            B when is_binary(B) ->
                case maybeDecodeJson(B) of
                    {ok, Decoded} -> Decoded;
                    error -> B
                end;
            Other -> Other
        end
    end, Row);
normalizeRow(Row) ->
    Row.

maybeDecodeJson(<<"{", _/binary>> = B) -> tryDecode(B);
maybeDecodeJson(<<"[", _/binary>> = B) -> tryDecode(B);
maybeDecodeJson(_) -> error.

tryDecode(B) ->
    try
        {ok, alJson:decode(B)}
    catch
        _:_ -> error
    end.

clamp(N, Min, Max) when is_integer(N) -> max(Min, min(Max, N));
clamp(B, Min, Max) when is_binary(B) ->
    try clamp(binary_to_integer(B), Min, Max) catch _:_ -> Min end;
clamp(_, Min, _) -> Min.

trimBin(B) when is_binary(B) -> string:trim(B);
trimBin(L) when is_list(L) -> string:trim(unicode:characters_to_binary(L));
trimBin(_) -> <<>>.

toInt(N) when is_integer(N) -> N;
toInt(B) when is_binary(B) ->
    try binary_to_integer(B) catch _:_ -> 0 end;
toInt(F) when is_float(F) -> trunc(F);
toInt(_) -> 0.
