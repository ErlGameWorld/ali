%%% @doc EUnit tests for ali_sup structure.
-module(alSup_tests).

-include_lib("eunit/include/eunit.hrl").

critical_exports_test() ->
    Exports = ali_sup:module_info(exports),
    [?assert(lists:member({F, A}, Exports)) || {F, A} <- [{start_link, 0}, {init, 1}]].

initReturnsSupervisor_test() ->
    {ok, {Flags, ChildSpecs}} = ali_sup:init([]),
    ?assert(is_map(Flags) orelse is_tuple(Flags)),
    ?assert(is_list(ChildSpecs)),
    Ids = [maps:get(id, C) || C <- ChildSpecs, is_map(C)],
    ?assert(lists:member(alSessionMgr, Ids) orelse lists:member(sessionMgr, Ids)).

childSpecsValid_test() ->
    {ok, {_Flags, ChildSpecs}} = ali_sup:init([]),
    lists:foreach(fun(C) ->
        ?assert(maps:is_key(id, C)),
        ?assert(maps:is_key(start, C))
    end, ChildSpecs).
