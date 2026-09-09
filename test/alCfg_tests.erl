%%% @doc EUnit tests for alCfg.
-module(alCfg_tests).

-include_lib("eunit/include/eunit.hrl").

-define(setup, begin ok = alConfig:load() end).

critical_exports_test() ->
    Exports = alCfg:module_info(exports),
    ?assert(lists:member({getV, 1}, Exports)).

getVReturnsValueForKnownKey_test() ->
    ?setup,
    %% After alConfig:load(), alCfg is compiled with actual KVs.
    %% 'core' is a standard key in aliCfg.cfg.
    Result = alCfg:getV(core),
    ?assert(Result =/= undefined).

getVReturnsUndefinedForUnknownKey_test() ->
    ?setup,
    ?assertEqual(undefined, alCfg:getV(nonExistentKey12345)).
