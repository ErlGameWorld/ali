%%% @doc EUnit tests for alMetrics.
-module(alMetrics_tests).

-include_lib("eunit/include/eunit.hrl").

-define(setup, begin ok = alConfig:load(), alMetrics:reset() end).

%%%===================================================================
%%% bump/2
%%%===================================================================

bumpGlobalCounter_test() ->
    ?setup,
    alMetrics:bump(askCount, 1),
    alMetrics:bump(askCount, 1),
    Snap = alMetrics:snapshot(),
    ?assertEqual(2, maps:get(askCount, Snap)).

bumpToolCounter_test() ->
    ?setup,
    alMetrics:bump({searchCode, calls}, 1),
    alMetrics:bump({searchCode, okCount}, 1),
    Snap = alMetrics:snapshot(),
    Tools = maps:get(tools, Snap),
    ToolStats = maps:get(searchCode, Tools, #{}),
    ?assertEqual(1, maps:get(calls, ToolStats)),
    ?assertEqual(1, maps:get(okCount, ToolStats)).

%%%===================================================================
%%% recordAsk/1
%%%===================================================================

recordAskOk_test() ->
    ?setup,
    alMetrics:recordAsk(#{status => ok, durationMs => 100}),
    Snap = alMetrics:snapshot(),
    ?assertEqual(1, maps:get(askCount, Snap)),
    ?assertEqual(1, maps:get(okCount, Snap)),
    ?assertEqual(0, maps:get(errorCount, Snap)),
    ?assertEqual(100, maps:get(totalDurationMs, Snap)),
    ?assertEqual(100, maps:get(avgDurationMs, Snap)).

recordAskError_test() ->
    ?setup,
    alMetrics:recordAsk(#{status => error, durationMs => 50}),
    Snap = alMetrics:snapshot(),
    ?assertEqual(1, maps:get(askCount, Snap)),
    ?assertEqual(0, maps:get(okCount, Snap)),
    ?assertEqual(1, maps:get(errorCount, Snap)).

%%%===================================================================
%%% recordTool/1
%%%===================================================================

recordTool_test() ->
    ?setup,
    alMetrics:recordTool(#{tool => searchCode, status => ok, durationMs => 30}),
    Snap = alMetrics:snapshot(),
    ?assertEqual(1, maps:get(totalToolCalls, Snap)),
    Tools = maps:get(tools, Snap),
    ToolStats = maps:get(searchCode, Tools, #{}),
    ?assertEqual(1, maps:get(calls, ToolStats)),
    ?assertEqual(1, maps:get(okCount, ToolStats)),
    ?assertEqual(30, maps:get(totalDurationMs, ToolStats)).

%% LLM 发明未知工具名时 toolAtom 会留下 binary，metrics 不得 function_clause。
recordToolBinaryName_test() ->
    ?setup,
    ?assertEqual(ok, alMetrics:recordTool(#{
        tool => <<"symbolSearch">>,
        status => error,
        durationMs => 1
    })),
    Snap = alMetrics:snapshot(),
    ?assertEqual(1, maps:get(totalToolCalls, Snap)).

%%%===================================================================
%%% 8: 未知工具名不产生新 atom（原子表耗尽 DoS 防护）
%%%===================================================================

unknown_tool_name_does_not_create_atom_test() ->
    ?setup,
    %% 用随机二进制工具名：修复前 binary_to_atom 会创建永久 atom，
    %% 修复后保留 binary 原样（binary_to_existing_atom 失败即返回 binary）。
    ToolBin = <<"totally_unknown_tool_",
                (integer_to_binary(erlang:unique_integer([positive, monotonic])))/binary>>,
    ?assertEqual(ok, alMetrics:recordTool(#{
        tool => ToolBin, status => ok, durationMs => 1})),
    %% 该工具名从未被转为 atom：binary_to_existing_atom 必须失败
    ?assertError(badarg, binary_to_existing_atom(ToolBin, utf8)),
    %% binary 键可正常聚合到 tools 快照
    Snap = alMetrics:snapshot(),
    Tools = maps:get(tools, Snap),
    ToolStats = maps:get(ToolBin, Tools, #{}),
    ?assertEqual(1, maps:get(calls, ToolStats)),
    ?assertEqual(1, maps:get(okCount, ToolStats)).

%%%===================================================================
%%% snapshot/0
%%%===================================================================

snapshotEmpty_test() ->
    ?setup,
    Snap = alMetrics:snapshot(),
    ?assertEqual(0, maps:get(askCount, Snap)),
    ?assertEqual(0, maps:get(okCount, Snap)),
    ?assertEqual(0, maps:get(totalToolCalls, Snap)),
    ?assertEqual(0, maps:get(avgDurationMs, Snap)).

%%%===================================================================
%%% reset/0
%%%===================================================================

resetClearsCounters_test() ->
    ?setup,
    alMetrics:bump(askCount, 5),
    alMetrics:bump({searchCode, calls}, 3),
    alMetrics:reset(),
    Snap = alMetrics:snapshot(),
    ?assertEqual(0, maps:get(askCount, Snap)),
    ?assertEqual(0, maps:get(totalToolCalls, Snap)),
    ?assertEqual(#{}, maps:get(tools, Snap)).
