%%% @doc EUnit tests for ali_app structure.
-module(alApp_tests).

-include_lib("eunit/include/eunit.hrl").

critical_exports_test() ->
    Exports = ali_app:module_info(exports),
    [?assert(lists:member({F, A}, Exports)) || {F, A} <- [{start, 2}, {stop, 1}]].

stopReturnsOk_test() ->
    ?assertEqual(ok, ali_app:stop(testState)).
