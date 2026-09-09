%%% @doc EUnit tests for alWebConnSup structure.
-module(alWebConnSup_tests).

-include_lib("eunit/include/eunit.hrl").

critical_exports_test() ->
    Exports = alWebConnSup:module_info(exports),
    [?assert(lists:member({F, A}, Exports)) || {F, A} <- [{start_link, 0}, {init, 1}]].

initReturnsSimpleOneForOne_test() ->
    {ok, {Flags, ChildSpecs}} = alWebConnSup:init([]),
    Strategy = case Flags of
        #{strategy := S} -> S;
        {S, _, _} -> S
    end,
    ?assertEqual(simple_one_for_one, Strategy),
    ?assert(is_list(ChildSpecs) andalso length(ChildSpecs) >= 1).
