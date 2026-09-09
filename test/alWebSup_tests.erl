%%% @doc EUnit tests for alWebSup and alWebConnSup.
-module(alWebSup_tests).

-include_lib("eunit/include/eunit.hrl").

%% alWebSup init/1 — verify child specs without starting children

alWebSup_init_returns_one_for_one_test() ->
    {ok, {SupFlags, _ChildSpecs}} = alWebSup:init([]),
    ?assertEqual(one_for_one, maps:get(strategy, SupFlags)),
    ?assertEqual(5, maps:get(intensity, SupFlags)),
    ?assertEqual(60, maps:get(period, SupFlags)).

alWebSup_init_has_two_children_test() ->
    {ok, {_SupFlags, ChildSpecs}} = alWebSup:init([]),
    ?assertEqual(2, length(ChildSpecs)).

alWebSup_init_has_conn_sup_test() ->
    {ok, {_SupFlags, ChildSpecs}} = alWebSup:init([]),
    Found = [C || C <- ChildSpecs, maps:get(id, C) =:= alWebConnSup],
    ?assertEqual(1, length(Found)),
    [Spec] = Found,
    ?assertEqual(supervisor, maps:get(type, Spec)),
    ?assertEqual(permanent, maps:get(restart, Spec)).

alWebSup_init_has_http_gateway_test() ->
    {ok, {_SupFlags, ChildSpecs}} = alWebSup:init([]),
    Found = [C || C <- ChildSpecs, maps:get(id, C) =:= alHttpGateway],
    ?assertEqual(1, length(Found)),
    [Spec] = Found,
    ?assertEqual(worker, maps:get(type, Spec)),
    ?assertEqual(permanent, maps:get(restart, Spec)).

%% alWebConnSup init/1 — verify simple_one_for_one

alWebConnSup_init_returns_simple_one_for_one_test() ->
    {ok, {SupFlags, _ChildSpecs}} = alWebConnSup:init([]),
    ?assertEqual(simple_one_for_one, maps:get(strategy, SupFlags)),
    ?assertEqual(100, maps:get(intensity, SupFlags)),
    ?assertEqual(3600, maps:get(period, SupFlags)).

alWebConnSup_init_has_wsHttp_template_test() ->
    {ok, {_SupFlags, ChildSpecs}} = alWebConnSup:init([]),
    ?assertEqual(1, length(ChildSpecs)),
    [Spec] = ChildSpecs,
    ?assertEqual(wsHttp, maps:get(id, Spec)),
    ?assertEqual(temporary, maps:get(restart, Spec)),
    ?assertEqual(brutal_kill, maps:get(shutdown, Spec)),
    ?assertEqual(worker, maps:get(type, Spec)).

%% alWebConnSup start_link — verify it starts and is alive

alWebConnSup_starts_test() ->
    {ok, Pid} = alWebConnSup:start_link(),
    ?assert(is_process_alive(Pid)),
    ?assertEqual(Pid, whereis(alWebConnSup)),
    unlink(Pid),
    exit(Pid, shutdown).
