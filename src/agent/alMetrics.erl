%%%-------------------------------------------------------------------
%% @doc 运行时指标：计数器与延迟百分位。
%%%-------------------------------------------------------------------

-module(alMetrics).

-export([bump/2, recordAsk/1, recordTool/1, snapshot/0,
         reset/0, ensureStarted/0, correlationId/0, correlationId/1,
         prometheusText/0, toolStats/0, toolWarnings/0]).

-define(GlobalTable, alMetrics).
-define(ToolTable, ali_tool_metrics).
-define(LatencyTable, ali_metrics_latency).
-define(MaxSamples, 512).
%% Latency 桶上界（毫秒）：log 间距覆盖 1ms..10s，末位为 overflow bucket。
-define(LatencyBucketBounds, [1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000]).
-define(LatencyBucketCount, 13).  %% length(?LatencyBucketBounds) + 1 (overflow)
-define(GlobalKeys, [askCount, okCount, errorCount,
                      totalDurationMs, totalToolCalls]).

ensureStarted() ->
    ensureTable(?GlobalTable, fun initGlobal/0),
    ensureTable(?ToolTable, fun() -> ok end),
    ensureTable(?LatencyTable, fun() -> ok end),
    ok.

ensureTable(Name, InitFun) ->
    case ets:whereis(Name) of
        undefined ->
            try ets:new(Name, [named_table, public, set,
                               {read_concurrency, true},
                               {write_concurrency, true}]) of
                _ -> InitFun()
            catch _:_ -> ok end;
        _ ->
            ok
    end.

initGlobal() ->
    [ets:insert(?GlobalTable, {K, 0}) || K <- ?GlobalKeys],
    ok.

bump(Key, Incr) when is_atom(Key) ->
    ensureStarted(),
    try ets:update_counter(?GlobalTable, Key, Incr) catch _:_ -> ok end,
    ok;
bump({Tool0, Field}, Incr) when is_atom(Field) ->
    ensureStarted(),
    Tool = normalizeToolKey(Tool0),
    ets:update_counter(?ToolTable, {Tool, Field}, Incr, {{Tool, Field}, 0}),
    ok;
bump(_Key, _Incr) ->
    %% Never crash the agent over metrics shape mismatches.
    ok.

%% LLM may invent tool names → binary。只转已存在的 atom，绝不 binary_to_atom
%% 创建永久 atom（原子表耗尽 DoS）；失败时保留 binary 原样返回——
%% ETS 键不限类型，{binary, Field} 可正常做 update_counter 与聚合。
normalizeToolKey(T) when is_atom(T) -> T;
normalizeToolKey(T) when is_binary(T) ->
    try binary_to_existing_atom(T, utf8) catch _:_ -> T end;
normalizeToolKey(T) when is_list(T) ->
    normalizeToolKey(unicode:characters_to_binary(T));
normalizeToolKey(_) ->
    unknown_tool.

recordAsk(#{status := Status, durationMs := Duration}) ->
    ensureStarted(),
    bump(askCount, 1),
    case Status of
        ok -> bump(okCount, 1);
        _ -> bump(errorCount, 1)
    end,
    bump(totalDurationMs, Duration),
    recordLatency(ask, Duration),
    ok;
recordAsk(#{status := Status}) ->
    ensureStarted(),
    bump(askCount, 1),
    case Status of
        ok -> bump(okCount, 1);
        _ -> bump(errorCount, 1)
    end,
    ok;
recordAsk(#{ok := Ok, durationMs := Duration}) ->
    Status = case Ok of true -> ok; _ -> error end,
    recordAsk(#{status => Status, durationMs => Duration});
recordAsk(#{ok := Ok}) ->
    Status = case Ok of true -> ok; _ -> error end,
    recordAsk(#{status => Status}).

recordTool(#{tool := Tool0, status := Status, durationMs := Duration}) ->
    ensureStarted(),
    Tool = normalizeToolKey(Tool0),
    bump({Tool, calls}, 1),
    case Status of
        ok -> bump({Tool, okCount}, 1);
        _ -> bump({Tool, errorCount}, 1)
    end,
    bump({Tool, totalDurationMs}, Duration),
    bump(totalToolCalls, 1),
    recordLatency({tool, Tool}, Duration),
    recordLatency(tool, Duration),
    ok;
recordTool(#{tool := Tool0, status := Status}) ->
    ensureStarted(),
    Tool = normalizeToolKey(Tool0),
    bump({Tool, calls}, 1),
    case Status of
        ok -> bump({Tool, okCount}, 1);
        _ -> bump({Tool, errorCount}, 1)
    end,
    bump(totalToolCalls, 1),
    ok;
recordTool(_) ->
    ok.

recordLatency(Key, Duration) when is_integer(Duration), Duration >= 0 ->
    ensureStarted(),
    %% 用原子 update_counter 写分桶，避免 read-modify-write 列表在高并发下丢样本。
    Bucket = latencyBucket(Duration),
    CounterKey = {Key, bucket, Bucket},
    try
        ets:update_counter(?LatencyTable, CounterKey, 1, {CounterKey, 0}),
        ets:update_counter(?LatencyTable, {Key, count}, 1, {{Key, count}, 0}),
        ets:update_counter(?LatencyTable, {Key, sum}, Duration, {{Key, sum}, 0})
    catch
        _:_ -> ok
    end,
    ok;
recordLatency(_, _) ->
    ok.

%% Duration(ms) → 桶下标 0..?LatencyBucketCount-1（末桶为 overflow）。
latencyBucket(Duration) ->
    latencyBucket(Duration, ?LatencyBucketBounds, 0).

latencyBucket(_Duration, [], Idx) ->
    Idx;
latencyBucket(Duration, [Bound | Rest], Idx) ->
    case Duration =< Bound of
        true -> Idx;
        false -> latencyBucket(Duration, Rest, Idx + 1)
    end.

%% 从分桶计数近似还原样本列表（每桶取上界代表值），供 percentile 计算。
%% 精度有损但并发安全；桶边界覆盖 1ms..10s。
bucketSamples(Key) ->
    Bounds = ?LatencyBucketBounds ++ [15000],  %% overflow 代表值
    lists:append([
        begin
            CKey = {Key, bucket, I},
            Count = case ets:lookup(?LatencyTable, CKey) of
                [{_, N}] when is_integer(N), N > 0 -> N;
                _ -> 0
            end,
            Rep = lists:nth(I + 1, Bounds),
            lists:duplicate(min(Count, ?MaxSamples), Rep)
        end
     || I <- lists:seq(0, ?LatencyBucketCount - 1)]).

percentile([], _Pct) -> 0;
percentile(Samples, Pct) ->
    Sorted = lists:sort(Samples),
    N = length(Sorted),
    Idx = max(1, min(N, ceil(N * Pct / 100))),
    lists:nth(Idx, Sorted).

latencySnapshot(Key) ->
    Samples = bucketSamples(Key),
    case Samples of
        [] ->
            #{count => 0, p50 => 0, p95 => 0, p99 => 0};
        _ ->
            Count = case ets:lookup(?LatencyTable, {Key, count}) of
                [{_, N}] when is_integer(N) -> N;
                _ -> length(Samples)
            end,
            #{
                count => Count,
                p50 => percentile(Samples, 50),
                p95 => percentile(Samples, 95),
                p99 => percentile(Samples, 99)
            }
    end.

snapshot() ->
    ensureStarted(),
    AskCount = readGlobal(askCount),
    OkCount = readGlobal(okCount),
    ErrorCount = readGlobal(errorCount),
    TotalDuration = readGlobal(totalDurationMs),
    TotalToolCalls = readGlobal(totalToolCalls),
    AvgDuration = case AskCount > 0 of
        true -> TotalDuration div AskCount;
        false -> 0
    end,
    #{
        askCount => AskCount,
        okCount => OkCount,
        errorCount => ErrorCount,
        totalDurationMs => TotalDuration,
        avgDurationMs => AvgDuration,
        totalToolCalls => TotalToolCalls,
        askLatency => latencySnapshot(ask),
        toolLatency => latencySnapshot(tool),
        tools => toolSnapshot(),
        correlationId => correlationId()
    }.

readGlobal(Key) ->
    case ets:lookup(?GlobalTable, Key) of
        [{_, Value}] -> Value;
        _ -> 0
    end.

toolSnapshot() ->
    ensureStarted(),
    All = ets:tab2list(?ToolTable),
    lists:foldl(fun groupToolMetrics/2, #{}, All).

groupToolMetrics({{Tool, Field}, Value}, Acc) ->
    Inner = maps:get(Tool, Acc, #{}),
    Acc#{Tool => Inner#{Field => Value}}.

reset() ->
    ensureStarted(),
    [ets:insert(?GlobalTable, {K, 0}) || K <- ?GlobalKeys],
    ets:delete_all_objects(?ToolTable),
    ets:delete_all_objects(?LatencyTable),
    ok.

%% Correlation id for the current process (HTTP/WS/agent workers).
correlationId() ->
    case erlang:get(aliCorrelationId) of
        undefined ->
            Id = integer_to_binary(erlang:unique_integer([positive, monotonic])),
            erlang:put(aliCorrelationId, Id),
            Id;
        Id -> Id
    end.

correlationId(Id) when is_binary(Id) ->
    erlang:put(aliCorrelationId, Id),
    Id;
correlationId(Id) ->
    correlationId(iolist_to_binary(io_lib:format("~p", [Id]))).

%%--------------------------------------------------------------------
%% @doc
%% 导出 Prometheus text exposition 格式（counter/gauge）。
%% 不含外部依赖，便于 `/api/metrics/prometheus` 抓取。
%% @end
%%--------------------------------------------------------------------
-spec prometheusText() -> binary().
prometheusText() ->
    Snap = snapshot(),
    Lines = [
        <<"# HELP ali_asks_total Total ask requests\n">>,
        <<"# TYPE ali_asks_total counter\n">>,
        iolist_to_binary(io_lib:format("ali_asks_total ~w\n", [maps:get(askCount, Snap, 0)])),
        <<"# HELP ali_asks_ok_total Successful asks\n">>,
        <<"# TYPE ali_asks_ok_total counter\n">>,
        iolist_to_binary(io_lib:format("ali_asks_ok_total ~w\n", [maps:get(okCount, Snap, 0)])),
        <<"# HELP ali_asks_error_total Failed asks\n">>,
        <<"# TYPE ali_asks_error_total counter\n">>,
        iolist_to_binary(io_lib:format("ali_asks_error_total ~w\n", [maps:get(errorCount, Snap, 0)])),
        <<"# HELP ali_ask_duration_ms_total Sum of ask durations\n">>,
        <<"# TYPE ali_ask_duration_ms_total counter\n">>,
        iolist_to_binary(io_lib:format("ali_ask_duration_ms_total ~w\n", [maps:get(totalDurationMs, Snap, 0)])),
        <<"# HELP ali_ask_duration_ms_avg Average ask duration\n">>,
        <<"# TYPE ali_ask_duration_ms_avg gauge\n">>,
        iolist_to_binary(io_lib:format("ali_ask_duration_ms_avg ~w\n", [maps:get(avgDurationMs, Snap, 0)])),
        <<"# HELP ali_tool_calls_total Total tool invocations\n">>,
        <<"# TYPE ali_tool_calls_total counter\n">>,
        iolist_to_binary(io_lib:format("ali_tool_calls_total ~w\n", [maps:get(totalToolCalls, Snap, 0)]))
        | toolPromLines(maps:get(tools, Snap, #{}))
    ],
    iolist_to_binary(Lines).

toolPromLines(Tools) when is_map(Tools) ->
    maps:fold(fun(Tool, Inner, Acc) when is_map(Inner) ->
        Name = sanitizePromLabel(Tool),
        Ok = maps:get(ok, Inner, maps:get(okCount, Inner, 0)),
        Err = maps:get(error, Inner, maps:get(errorCount, Inner, 0)),
        [
            iolist_to_binary(io_lib:format(
                "ali_tool_ok_total{tool=\"~s\"} ~w\n", [Name, Ok])),
            iolist_to_binary(io_lib:format(
                "ali_tool_error_total{tool=\"~s\"} ~w\n", [Name, Err]))
            | Acc
        ];
    (_Tool, _Inner, Acc) ->
        Acc
    end, [], Tools);
toolPromLines(_) ->
    [].

sanitizePromLabel(A) when is_atom(A) -> atom_to_list(A);
sanitizePromLabel(B) when is_binary(B) -> binary_to_list(B);
sanitizePromLabel(L) when is_list(L) -> L;
sanitizePromLabel(Other) -> lists:flatten(io_lib:format("~p", [Other])).

%%--------------------------------------------------------------------
%% @doc
%% 返回每个工具的统计：调用次数、成功次数、失败次数、成功率。
%% 用于工具成功率反馈到系统提示。
%%
%% @return #{Tool => #{calls, okCount, errorCount, successRate}}
%% @end
%%--------------------------------------------------------------------
-spec toolStats() -> #{atom() => map()}.
toolStats() ->
    ensureStarted(),
    All = ets:tab2list(?ToolTable),
    Raw = lists:foldl(fun groupToolMetrics/2, #{}, All),
    maps:map(fun(_Tool, Inner) ->
        Calls = maps:get(calls, Inner, 0),
        Ok = maps:get(okCount, Inner, 0),
        Err = maps:get(errorCount, Inner, 0),
        Rate = case Calls > 0 of
            true -> Ok / Calls;
            false -> 1.0
        end,
        #{calls => Calls, okCount => Ok, errorCount => Err, successRate => Rate}
    end, Raw).

%%--------------------------------------------------------------------
%% @doc
%% 返回高失败率工具的警告列表：成功率 < 70% 且调用 >= 5 次的工具。
%% 用于在系统提示中警告 LLM 谨慎使用这些工具。
%%
%% @return [binary()] 警告文本列表（可能为空）
%% @end
%%--------------------------------------------------------------------
-spec toolWarnings() -> [binary()].
toolWarnings() ->
    Stats = toolStats(),
    maps:fold(fun(Tool, #{calls := Calls, successRate := Rate}, Acc) ->
        case Calls >= 5 andalso Rate < 0.7 of
            true ->
                Pct = round(Rate * 100),
                ToolBin = toolKeyToBin(Tool),
                Warning = iolist_to_binary([
                    ToolBin, <<" 成功率 "/utf8>>, integer_to_binary(Pct),
                    <<"%（"/utf8>>, integer_to_binary(Calls), <<" 次调用）。"
                    "请考虑换用其它工具，或仔细核对参数。"/utf8>>
                ]),
                [Warning | Acc];
            false ->
                Acc
        end
    end, [], Stats).

toolKeyToBin(T) when is_atom(T) -> atom_to_binary(T, utf8);
toolKeyToBin(T) when is_binary(T) -> T;
toolKeyToBin(T) -> iolist_to_binary(io_lib:format("~p", [T])).
