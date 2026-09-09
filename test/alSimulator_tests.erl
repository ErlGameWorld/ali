%%% @doc EUnit tests for alSimulator.
-module(alSimulator_tests).

-include_lib("eunit/include/eunit.hrl").

critical_exports_test() ->
    Exports = alSimulator:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{run, 1}, {listRecent, 1}]].

%% A10 回归：mfa 场景缺 module/function 字段时返回 error，不崩溃。
run_missing_mfa_fields_returns_error_test() ->
    ?assertMatch({error, _}, alSimulator:run(#{type => mfa})).
