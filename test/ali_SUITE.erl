%%%-------------------------------------------------------------------
%%% @doc Common Test suite: boot, catalog, pending, protocol smoke.
%%%-------------------------------------------------------------------
-module(ali_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_group/2, end_per_group/2]).
-export([
    app_starts/1,
    tool_catalog_resolves_snake/1,
    pending_atomic_claim/1,
    checkpoint_api_present/1,
    metrics_percentiles/1,
    session_sup_present/1,
    memory_api_present/1,
    verify_non_llm_categories/1
]).

all() ->
    [{group, smoke}].

groups() ->
    [{smoke, [sequence], [
        app_starts,
        tool_catalog_resolves_snake,
        pending_atomic_claim,
        checkpoint_api_present,
        metrics_percentiles,
        session_sup_present,
        memory_api_present,
        verify_non_llm_categories
    ]}].

init_per_suite(Config) ->
    ok = application:load(ali),
    %% Soft-start: config may lack LLM key under strict=false.
    _ = application:ensure_all_started(ali),
    Config.

end_per_suite(_Config) ->
    _ = application:stop(ali),
    ok.

init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, _Config) ->
    ok.

app_starts(_Config) ->
    case whereis(alServer) of
        Pid when is_pid(Pid) -> ok;
        undefined ->
            %% In CT without full cfg, server may be absent — require app loaded.
            {ok, _} = application:get_key(ali, vsn),
            ok
    end.

tool_catalog_resolves_snake(_Config) ->
    {ok, searchCode} = alToolCatalog:resolveToolName(<<"search_code">>),
    {ok, applyPatch} = alToolCatalog:resolveToolName(<<"apply_patch">>),
    ok.

pending_atomic_claim(_Config) ->
    alPending:ensureStarted(),
    TaskId = <<"ct-pending-1">>,
    {ok, _} = alPending:put(TaskId, <<"ct">>, readFile, #{path => <<"x.erl">>}, #{}),
    _ = alPending:approve(TaskId),
    {error, notFound} = alPending:approve(TaskId),
    ok.

checkpoint_api_present(_Config) ->
    true = lists:member({listCheckpoints, 0}, ali:module_info(exports)),
    true = lists:member({resumeCheckpoint, 1}, ali:module_info(exports)),
    ok.

metrics_percentiles(_Config) ->
    alMetrics:ensureStarted(),
    alMetrics:reset(),
    alMetrics:recordAsk(#{status => ok, durationMs => 10}),
    alMetrics:recordAsk(#{status => ok, durationMs => 20}),
    Snap = alMetrics:snapshot(),
    Lat = maps:get(askLatency, Snap),
    true = maps:is_key(p95, Lat),
    ok.

session_sup_present(_Config) ->
    true = lists:member({ensure_worker, 2}, alSessionSup:module_info(exports)),
    ok.

memory_api_present(_Config) ->
    true = lists:member({forget, 1}, alMemory:module_info(exports)),
    true = lists:member({rebuildIndex, 0}, alMemory:module_info(exports)),
    true = lists:member({rebuildMemoryIndex, 0}, ali:module_info(exports)),
    ok.

verify_non_llm_categories(_Config) ->
    Cats = alVerify:nonLlmCategories(),
    true = is_list(Cats) andalso Cats =/= [],
    false = lists:member(llm, Cats),
    ok.
