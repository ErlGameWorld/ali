%%%-------------------------------------------------------------------
%% @doc 将指标与审计条目按小时归档到 SQLite。
%%
%% 本模块管理两张表：
%%   - `metric_snapshots`（hour, askCount, okCount, errorCount,
%%     totalDurationMs, totalToolCalls, tools_json）
%%   - `audit_archive`（hour, count, entries_json）
%%
%% `archiveNow/0` 写入当前小时快照（经 `INSERT OR REPLACE` 幂等）。
%% `listSnapshots/N` 与 `listAudit/N` 查询历史。函数本身只做 DB 写；
%% 调度由调用方负责（如 cron 或 gen_server）。
%% @end
%%%-------------------------------------------------------------------

-module(alArchive).

-export([
    archiveNow/0,
    archiveMetrics/0,
    archiveAudit/0,
    listSnapshots/1,
    listAudit/1,
    ensureSchema/0
]).

%%--------------------------------------------------------------------
%% @doc
%% 一次性执行指标 + 审计归档（同一小时）。
%%
%% @return {ok, #{metrics => ok | error, audit => ok | error}}
%% @end
%%--------------------------------------------------------------------
-spec archiveNow() -> {ok, map()}.
archiveNow() ->
    ensureSchema(),
    M = archiveMetrics(),
    A = archiveAudit(),
    {ok, #{metrics => M, audit => A, hour => currentHour()}}.

%%--------------------------------------------------------------------
%% @doc
%% 把当前 alMetrics 快照写入 `metric_snapshots`（按小时覆盖）。
%%
%% @return ok | {error, term()}
%% @end
%%--------------------------------------------------------------------
-spec archiveMetrics() -> ok | {error, term()}.
archiveMetrics() ->
    case archiveBackendOk() of
        false ->
            {error, fileBackendUnsupported};
        true ->
            try
                ensureSchema(),
                Snap = alMetrics:snapshot(),
                Hour = currentHour(),
                ToolsJson = encodeTools(maps:get(tools, Snap, #{})),
                Sql = "INSERT OR REPLACE INTO metric_snapshots "
                      "(hour, ask_count, ok_count, error_count, total_duration_ms, "
                      " avg_duration_ms, total_tool_calls, tools_json, archived_at) "
                      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                Params = [
                    Hour,
                    maps:get(askCount, Snap, 0),
                    maps:get(okCount, Snap, 0),
                    maps:get(errorCount, Snap, 0),
                    maps:get(totalDurationMs, Snap, 0),
                    maps:get(avgDurationMs, Snap, 0),
                    maps:get(totalToolCalls, Snap, 0),
                    ToolsJson,
                    erlang:system_time(second)
                ],
                case alLocalDb:insert(Sql, Params) of
                    {ok, _} -> ok;
                    Other -> Other
                end
            catch C:R ->
                logger:warning("alArchive:archiveMetrics failed: ~p:~p", [C, R]),
                {error, {C, R}}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 把当前 alAudit 内存中的条目按小时聚合写入 `audit_archive`。
%% 记录总数与 entries_json（每条 entry 包含 action/target/status/caller）。
%%
%% @return ok | {error, term()}
%% @end
%%--------------------------------------------------------------------
-spec archiveAudit() -> ok | {error, term()}.
archiveAudit() ->
    case archiveBackendOk() of
        false ->
            {error, fileBackendUnsupported};
        true ->
            try
                ensureSchema(),
                Entries = alAudit:list(),
                Hour = currentHour(),
                Compact = [compactAuditEntry(E) || E <- Entries],
                Json = alJson:encode(Compact),
                Sql = "INSERT OR REPLACE INTO audit_archive "
                      "(hour, count, entries_json, archived_at) "
                      "VALUES (?, ?, ?, ?)",
                Params = [Hour, length(Compact), Json, erlang:system_time(second)],
                case alLocalDb:insert(Sql, Params) of
                    {ok, _} -> ok;
                    Other -> Other
                end
            catch C:R ->
                logger:warning("alArchive:archiveAudit failed: ~p:~p", [C, R]),
                {error, {C, R}}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 查询最近 N 小时的指标快照（按 hour 倒序）。
%%
%% @return map 列表
%% @end
%%--------------------------------------------------------------------
-spec listSnapshots(non_neg_integer()) -> [map()].
listSnapshots(0) -> [];
listSnapshots(N) when N > 0 ->
    Sql = "SELECT hour, ask_count, ok_count, error_count, total_duration_ms, "
          "avg_duration_ms, total_tool_calls, tools_json, archived_at "
          "FROM metric_snapshots ORDER BY hour DESC LIMIT ?",
    case alLocalDb:query(Sql, [N]) of
        {ok, Rows} -> [snapshotRowToMap(R) || R <- Rows];
        _ -> []
    end.

%%--------------------------------------------------------------------
%% @doc
%% 查询最近 N 小时的审计归档。
%%
%% @return map 列表
%% @end
%%--------------------------------------------------------------------
-spec listAudit(non_neg_integer()) -> [map()].
listAudit(0) -> [];
listAudit(N) when N > 0 ->
    Sql = "SELECT hour, count, entries_json, archived_at "
          "FROM audit_archive ORDER BY hour DESC LIMIT ?",
    case alLocalDb:query(Sql, [N]) of
        {ok, Rows} -> [auditRowToMap(R) || R <- Rows];
        _ -> []
    end.

%%--------------------------------------------------------------------
%% @doc
%% 归档表由 `priv/db/schema.sql` 在 aliCore 启动时创建（运行时 DDL 被 Rust Core 禁止）。
%% @end
%%--------------------------------------------------------------------
-spec ensureSchema() -> ok.
ensureSchema() ->
    ok.

%% 内部：返回形如 YYYYMMDDHH 的整点编号（local time）。
currentHour() ->
    {{Y, Mo, D}, {H, _Mi, _S}} = calendar:local_time(),
    Y * 1000000 + Mo * 10000 + D * 100 + H.

%% 内部：把 #{Tool => #{Field => Count}} 编码为 JSON。
encodeTools(Tools) ->
    alJson:encode(Tools).

%% 内部：把审计行字段转 map。查询后端返回的 row 可能是 list 或 map。
snapshotRowToMap(Row) when is_list(Row) ->
    [Hour, Ask, Ok, Err, Total, Avg, Tool, ToolsJson, Ts] = Row,
    #{
        hour => Hour,
        askCount => Ask,
        okCount => Ok,
        errorCount => Err,
        totalDurationMs => Total,
        avgDurationMs => Avg,
        totalToolCalls => Tool,
        tools => decodeJson(ToolsJson),
        archivedAt => Ts
    };
snapshotRowToMap(Row) when is_map(Row) ->
    #{
        hour => maps:get(hour, Row, 0),
        askCount => maps:get(ask_count, Row, 0),
        okCount => maps:get(ok_count, Row, 0),
        errorCount => maps:get(error_count, Row, 0),
        totalDurationMs => maps:get(total_duration_ms, Row, 0),
        avgDurationMs => maps:get(avg_duration_ms, Row, 0),
        totalToolCalls => maps:get(total_tool_calls, Row, 0),
        tools => decodeJson(maps:get(tools_json, Row, <<>>)),
        archivedAt => maps:get(archived_at, Row, 0)
    }.

auditRowToMap(Row) when is_list(Row) ->
    [Hour, Count, EntriesJson, Ts] = Row,
    #{
        hour => Hour,
        count => Count,
        entries => decodeJson(EntriesJson),
        archivedAt => Ts
    };
auditRowToMap(Row) when is_map(Row) ->
    #{
        hour => maps:get(hour, Row, 0),
        count => maps:get(count, Row, 0),
        entries => decodeJson(maps:get(entries_json, Row, <<>>)),
        archivedAt => maps:get(archived_at, Row, 0)
    }.

%% 内部：压缩单条审计 entry 到必要字段。
compactAuditEntry(Entry) when is_map(Entry) ->
    #{
        id => maps:get(id, Entry, undefined),
        at => maps:get(at, Entry, undefined),
        action => maps:get(action, Entry, undefined),
        target => maps:get(target, Entry, undefined),
        status => maps:get(status, Entry, undefined),
        caller => maps:get(caller, Entry, undefined)
    };
compactAuditEntry(Other) ->
    Other.

%% 文件 JSONL 回退无法正确映射归档表结构，避免污染 memories 等表。
archiveBackendOk() ->
    try
        case alLocalDb:status() of
            #{engine := rustCore} -> true;
            #{engine := file} -> false;
            _ -> false
        end
    catch _:_ ->
        false
    end.

%% 内部：把可能为 list / binary 的 JSON 解码为 Erlang term。
decodeJson(<<>>) -> [];
decodeJson(Bin) when is_binary(Bin) ->
    try alJson:decode(Bin) catch _:_ -> [] end;
decodeJson(List) when is_list(List) ->
    try alJson:decode(iolist_to_binary(List)) catch _:_ -> [] end;
decodeJson(_) -> [].
