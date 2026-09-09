%%% @doc Lightweight integration checks for protocol / catalog / pending.
-module(alIntegration_tests).

-include_lib("eunit/include/eunit.hrl").

tool_name_snake_camel_test() ->
    ?assertEqual({ok, searchCode}, alToolCatalog:resolveToolName(<<"search_code">>)),
    ?assertEqual({ok, searchCode}, alToolCatalog:resolveToolName(<<"searchCode">>)),
    ?assertEqual({ok, applyPatch}, alToolCatalog:resolveToolName(<<"apply_patch">>)),
    ?assertEqual(error, alToolCatalog:resolveToolName(<<"notARealToolXYZ">>)).

pending_atomic_approve_test() ->
    alPending:ensureStarted(),
    TaskId = <<"integ-approve-once">>,
    {ok, _} = alPending:put(TaskId, <<"sid">>, readFile, #{path => <<"x.erl">>},
                            #{mode => ask, confirmed => false}),
    %% First claim wins; second must miss.
    R1 = alPending:approve(TaskId),
    R2 = alPending:approve(TaskId),
    ?assertNotEqual({error, notFound}, R1),
    ?assertEqual({error, notFound}, R2).

checkpoint_api_exports_test() ->
    Exports = ali:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{listCheckpoints, 0}, {resumeCheckpoint, 1},
                   {resumeCheckpoint, 2}, {deleteCheckpoint, 1}]].

metrics_percentile_test() ->
    ok = alConfig:load(),
    alMetrics:reset(),
    lists:foreach(fun(N) ->
        alMetrics:recordAsk(#{status => ok, durationMs => N})
    end, lists:seq(1, 100)),
    Snap = alMetrics:snapshot(),
    Lat = maps:get(askLatency, Snap),
    ?assert(maps:get(p95, Lat) >= maps:get(p50, Lat)),
    ?assert(maps:get(p99, Lat) >= maps:get(p95, Lat)).

event_protocol_types_test() ->
    %% Ensure catalog still has verification tool after refactor.
    alToolCatalog:cacheClear(),
    Spec = alToolCatalog:toolSpec(runTestsForPatch),
    ?assertEqual(runTestsForPatch, maps:get(name, Spec)),
    ?assertNotEqual(<<"Unknown tool">>, maps:get(description, Spec)).
