%%% @doc EUnit tests for alDbAdapter.
-module(alDbAdapter_tests).

-include_lib("eunit/include/eunit.hrl").

-define(setup, begin ok = alConfig:load() end).

critical_exports_test() ->
    Exports = alDbAdapter:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{query, 1}, {status, 0}, {ensureStarted, 0}]].

statusReturnsMap_test() ->
    ?setup,
    Status = alDbAdapter:status(),
    ?assert(is_map(Status)).

ensureStartedIsIdempotent_test() ->
    ?setup,
    %% ensureStarted may return {ok, Pid} or ok; both are acceptable
    R1 = alDbAdapter:ensureStarted(),
    ?assert(R1 =:= ok orelse is_tuple(R1)),
    R2 = alDbAdapter:ensureStarted(),
    ?assert(R2 =:= ok orelse is_tuple(R2)).
