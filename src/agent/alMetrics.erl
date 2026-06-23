%%%-------------------------------------------------------------------
%%% @doc Agent 运行指标聚合（可观测性）。
%%%
%%% 以 ETS 计数器累计 ask 次数、成功/失败、总耗时、工具调用次数，
%%% 供 `ali:metrics/0` 查询，用于评估 Agent 表现与排查回归。
%%% @end
%%%-------------------------------------------------------------------
-module(alMetrics).

-export([
    init/0,
    recordAsk/1,
    recordTool/1,
    snapshot/0,
    toolStats/1,
    toolStats/0,
    reset/0,
    emitTelemetry/3
]).

-define(TABLE, alMetrics).
-define(TOOL_TABLE, alToolMetrics).

%% @doc 初始化指标 ETS 表（幂等）。
-spec init() -> ok.
init() ->
    initTable(?TABLE, set),
    initTable(?TOOL_TABLE, set),
    ok.

initTable(Name, Type) ->
    case ets:info(Name) of
        undefined ->
            ets:new(Name, [named_table, public, Type]);
        _ ->
            ok
    end,
    ok.

%% @doc 记录一次 ask 的结果指标。
%% M 可含：`durationMs`、`ok`(boolean)、`toolCalls`(整数)。
-spec recordAsk(map()) -> ok.
recordAsk(M) ->
    init(),
    Dur = maps:get(durationMs, M, 0),
    Ok = maps:get(ok, M, true),
    Tools = maps:get(toolCalls, M, 0),
    bump(askCount, 1),
    bump(case Ok of true -> okCount; false -> errorCount end, 1),
    bump(totalDurationMs, Dur),
    bump(totalToolCalls, Tools),
    ok.

%% @doc 记录一次工具调用的指标。
%% M 可含：`tool`(atom, 工具名)、`durationMs`(整数, 耗时毫秒)、`ok`(boolean, 成功/失败)。
-spec recordTool(map()) -> ok.
recordTool(M) ->
    init(),
    Tool = maps:get(tool, M, unknown),
    Dur = maps:get(durationMs, M, 0),
    Ok = maps:get(ok, M, true),
    ets:update_counter(?TOOL_TABLE, {Tool, calls}, {2, 1}, {{Tool, calls}, 0}),
    ets:update_counter(?TOOL_TABLE, {Tool, totalDurationMs}, {2, Dur}, {{Tool, totalDurationMs}, 0}),
    case Ok of
        true ->
            ets:update_counter(?TOOL_TABLE, {Tool, okCount}, {2, 1}, {{Tool, okCount}, 0});
        false ->
            ets:update_counter(?TOOL_TABLE, {Tool, errorCount}, {2, 1}, {{Tool, errorCount}, 0})
    end,
    ok.

%% @doc 返回所有工具的分桶指标快照。
-spec toolStats() -> map().
toolStats() ->
    init(),
    All = ets:tab2list(?TOOL_TABLE),
    Grouped = lists:foldl(fun({{Tool, Field}, Val}, Acc) ->
        ToolMap = maps:get(Tool, Acc, #{}),
        maps:put(Tool, maps:put(Field, Val, ToolMap), Acc)
    end, #{}, All),
    maps:map(fun(_Tool, M) ->
        C = maps:get(calls, M, 0),
        T = maps:get(totalDurationMs, M, 0),
        M#{avgDurationMs => case C of 0 -> 0; _ -> T div C end}
    end, Grouped).

%% @doc 返回指定工具的分桶指标快照。
-spec toolStats(atom()) -> map().
toolStats(Tool) ->
    init(),
    #{
        calls => getToolCounter(Tool, calls),
        okCount => getToolCounter(Tool, okCount),
        errorCount => getToolCounter(Tool, errorCount),
        totalDurationMs => getToolCounter(Tool, totalDurationMs)
    }.

%% @doc 返回累计指标快照（含平均耗时）。
-spec snapshot() -> map().
snapshot() ->
    init(),
    Asks = get_counter(askCount),
    Total = get_counter(totalDurationMs),
    #{
        askCount => Asks,
        okCount => get_counter(okCount),
        errorCount => get_counter(errorCount),
        totalToolCalls => get_counter(totalToolCalls),
        totalDurationMs => Total,
        avgDurationMs => case Asks of 0 -> 0; _ -> Total div Asks end
    }.

%% @doc 重置全部指标。
-spec reset() -> ok.
reset() ->
    init(),
    ets:delete_all_objects(?TABLE),
    ets:delete_all_objects(?TOOL_TABLE),
    ok.

%% 原子化累加计数器（全局指标用）。
bump(Key, By) ->
    ets:update_counter(?TABLE, Key, {2, By}, {Key, 0}).

%% 读取计数器，缺省 0。
get_counter(Key) ->
    case ets:lookup(?TABLE, Key) of
        [{_, V}] -> V;
        [] -> 0
    end.

%% 读取工具级指标计数器。
getToolCounter(Tool, Field) ->
    case ets:lookup(?TOOL_TABLE, {Tool, Field}) of
        [{{Tool, Field}, V}] -> V;
        [] -> 0
    end.

%% @doc 安全触发 telemetry 事件（若 telemetry 库已加载）。
%% 用作 `telemetry:execute/3` 的包装，避免硬依赖 telemetry 库。
%% 事件命名约定：`[ali, <Component>, <Action>]`（如 `[ali, llm, request]`）。
-spec emitTelemetry([atom()], map(), map()) -> ok.
emitTelemetry(Event, Measurements, Metadata) ->
    case code:ensure_loaded(telemetry) of
        {module, telemetry} ->
            try telemetry:execute(Event, Measurements, Metadata)
            catch _:_ -> ok
            end;
        _ ->
            ok
    end,
    ok.
