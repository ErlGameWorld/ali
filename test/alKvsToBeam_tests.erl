%%% @doc EUnit tests for alKvsToBeam.
-module(alKvsToBeam_tests).

-include_lib("eunit/include/eunit.hrl").

critical_exports_test() ->
    Exports = alKvsToBeam:module_info(exports),
    [?assert(lists:member({F, A}, Exports)) || {F, A} <- [{load, 2}, {load, 3}]].

loadCompilesKVsToModule_test() ->
    KVs = [{testKvKey, <<"hello">>}, {testKvNum, 42}],
    Module = alKvsToBeam_test_module,
    ok = alKvsToBeam:load(Module, KVs),
    ?assertEqual(<<"hello">>, Module:getV(testKvKey)),
    ?assertEqual(42, Module:getV(testKvNum)),
    ?assertEqual(undefined, Module:getV(nonExistent)),
    code:purge(Module),
    code:delete(Module).

loadWithDefault_test() ->
    Module = alKvsToBeam_test_def,
    ok = alKvsToBeam:load(Module, [{a, 1}], []),
    ?assertEqual(1, Module:getV(a)),
    code:purge(Module),
    code:delete(Module).
