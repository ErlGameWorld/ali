%%% @doc EUnit tests for alSpecIndex.
-module(alSpecIndex_tests).

-include_lib("eunit/include/eunit.hrl").

-define(setup, begin ok = alConfig:load() end).

critical_exports_test() ->
    Exports = alSpecIndex:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{findTypeUsages, 2},
                   {findTypeUsages, 3},
                   {searchSpecs, 2},
                   {searchSpecs, 3},
                   {parseSpec, 1},
                   {moduleSpecs, 1}]].

parseSpec_basic_test() ->
    %% Single clause
    {Heads, Ret} = alSpecIndex:parseSpec(
        "-spec foo(integer()) -> integer()."),
    ?assertEqual([{foo, 1}], Heads),
    ?assertEqual("integer()", Ret).

parseSpec_multi_test() ->
    %% Two clauses joined with semicolon
    {Heads, _Ret} = alSpecIndex:parseSpec(
        "-spec bar(X) -> X when X :: term(); (Y) -> Y."),
    ?assertEqual([{bar, 1}], Heads).

parseSpec_invalid_test() ->
    ?assertEqual(error, alSpecIndex:parseSpec("not a spec")).

parseSpec_with_comment_test() ->
    {Heads, Ret} = alSpecIndex:parseSpec(
        "-spec baz() -> ok. % this is a comment"),
    ?assertEqual([{baz, 0}], Heads),
    ?assertEqual("ok", Ret).

parseSpec_multi_fun_test() ->
    {Heads, _} = alSpecIndex:parseSpec(
        "-spec f(X) -> X; g(Y) -> Y."),
    ?assertEqual([{f, 1}, {g, 1}], lists:sort(Heads)).

findTypeUsages_self_test() ->
    ?setup,
    %% Project itself should have many -spec entries that mention
    %% functions/integers/strings — pick a common one.
    {ok, Results} = alSpecIndex:findTypeUsages(integer, "src", 500),
    ?assert(length(Results) >= 1),
    %% Each result must have the required keys
    Sample = hd(Results),
    ?assert(maps:is_key(module, Sample)),
    ?assert(maps:is_key(function, Sample)),
    ?assert(maps:is_key(arity, Sample)),
    ?assert(maps:is_key(file, Sample)),
    ?assert(maps:is_key(line, Sample)),
    ?assert(maps:is_key(snippet, Sample)).

findTypeUsages_with_limit_test() ->
    ?setup,
    {ok, R1} = alSpecIndex:findTypeUsages(integer, "src", 1),
    ?assert(length(R1) =< 1).

findTypeUsages_named_test() ->
    ?setup,
    %% 'file:filename()' is a common ali type; the search should
    %% not blow up on it.
    {ok, Results} = alSpecIndex:findTypeUsages(filename, "src", 50),
    ?assert(is_list(Results)).

findTypeUsages_nonexistent_test() ->
    ?setup,
    {ok, []} = alSpecIndex:findTypeUsages(
        "absolutelyNonexistentTypeXYZ123", "src", 50).

searchSpecs_basic_test() ->
    ?setup,
    {ok, Hits} = alSpecIndex:searchSpecs("ok$", "src", 200),
    ?assert(is_list(Hits)).

searchSpecs_invalid_type_test() ->
    %% ensure binary patterns are accepted
    {ok, _} = alSpecIndex:searchSpecs(<<"integer">>, "src", 10).

moduleSpecs_self_test() ->
    {ok, Specs} = alSpecIndex:moduleSpecs("src/tools/alSpecIndex.erl"),
    %% Our own module has many specs
    ?assert(length(Specs) >= 5),
    %% Each entry is {SpecText, LineNo}; SpecText must start with -spec
    [?assertEqual("-spec", string:substr(S, 1, 5)) || {S, _Line} <- Specs],
    [?assert(is_integer(Line) andalso Line >= 1) || {_S, Line} <- Specs].
