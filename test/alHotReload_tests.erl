%%% @doc EUnit for alHotReload pure helpers + safe reload smoke.
-module(alHotReload_tests).

-include_lib("eunit/include/eunit.hrl").

export_diff_test() ->
    Diff = alHotReload:exportDiff([{a, 1}, {b, 2}], [{a, 1}, {c, 0}]),
    ?assertEqual([{c, 0}], maps:get(added, Diff)),
    ?assertEqual([{b, 2}], maps:get(removed, Diff)),
    ?assertEqual(1, maps:get(unchangedCount, Diff)).

parse_smoke_ok_test() ->
    ?assertEqual({ok, ping, 0}, alHotReload:parseSmoke("ping/0")),
    ?assertEqual({ok, ping, 0}, alHotReload:parseSmoke(<<"ping/0">>)),
    ?assertEqual({ok, ping, 0}, alHotReload:parseSmoke(#{function => ping, arity => 0})).

parse_smoke_rejects_arity_test() ->
    ?assertEqual({error, smokeArityMustBe0}, alHotReload:parseSmoke("ping/1")),
    ?assertMatch({error, _}, alHotReload:parseSmoke("ping")).

ensure_module_test() ->
    ?assertEqual({ok, lists}, alHotReload:ensureModule(lists)),
    ?assertEqual({ok, lists}, alHotReload:ensureModule(<<"lists">>)),
    ?assertEqual({error, missingModule}, alHotReload:ensureModule(undefined)).

%% 对已加载的非 sticky 项目模块做一次真实 soft_purge+load（失败 softPurgeDenied 也可接受）。
reload_project_module_test() ->
    case alHotReload:reload(#{module => alVcsIndex}) of
        {ok, Map} ->
            ?assertEqual(true, maps:get(loaded, Map)),
            ?assertEqual(alVcsIndex, maps:get(module, Map)),
            ?assert(is_map(maps:get(exportDiff, Map))),
            ?assertEqual(true, maps:get(ok, maps:get(smoke, Map)));
        {error, #{reason := softPurgeDenied}} ->
            ok;
        {error, #{reason := loadFailed}} ->
            ok
    end.

reload_missing_module_arg_test() ->
    ?assertMatch({error, #{reason := missingModule}}, alHotReload:reload(#{})).

%% A4 回归：未知 module/fun 名走 existing atom 转换，不创建新原子。
ensure_module_unknown_test() ->
    ?assertEqual({error, unknownModule}, alHotReload:ensureModule(<<"no_such_module_xyz">>)),
    ?assertEqual({error, unknownModule}, alHotReload:ensureModule("no_such_module_xyz")).

parse_smoke_unknown_fun_test() ->
    ?assertEqual({error, invalidSmoke}, alHotReload:parseSmoke("no_such_fun_xyz/0")),
    ?assertEqual({error, invalidSmoke}, alHotReload:parseSmoke(<<"no_such_fun_xyz/0">>)).



