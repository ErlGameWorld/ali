%%% @doc EUnit tests for alSearch.
-module(alSearch_tests).

-include_lib("eunit/include/eunit.hrl").

-define(setup, begin ok = alConfig:load() end).

critical_exports_test() ->
    Exports = alSearch:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{search, 3}, {search, 4}, {search, 5}, {backend, 0}]].

backendReturnsAtom_test() ->
    ?setup,
    Backend = alSearch:backend(),
    ?assert(is_atom(Backend)).

%% 空查询不得触发 binary:match badarg（Erlang 回退路径曾崩 worker）。
emptyQuery_rejected_test() ->
    ?setup,
    Root = unicode:characters_to_binary(alConfig:projectRoot()),
    ?assertEqual({error, emptyQuery}, alSearch:search(Root, <<".">>, <<>>, 10)),
    ?assertEqual({error, emptyQuery}, alSearch:search(Root, <<".">>, <<"   ">>, 10)),
    ?assertEqual({error, emptyQuery}, alSearch:search(<<>>, <<".">>, 10)).

%% 单文件路径不得返回 notADirectory（模型常把 .erl 路径直接传给 searchText）
searchScopeFiles_regular_file_test() ->
    ?setup,
    Root = unicode:characters_to_binary(alConfig:projectRoot()),
    {ok, Files} = alSearch:searchScopeFiles(Root, <<"src/tools/alSearch.erl">>),
    ?assertEqual(1, length(Files)),
    ?assert(lists:any(
        fun(F) -> filename:basename(unicode:characters_to_list(F)) =:= "alSearch.erl" end,
        Files)).

search_single_file_path_test() ->
    ?setup,
    Root = unicode:characters_to_binary(alConfig:projectRoot()),
    {ok, Matches} = alSearch:search(Root, <<"src/tools/alSearch.erl">>, <<"searchScopeFiles">>, 5),
    ?assert(is_list(Matches)),
    ?assert(length(Matches) >= 1).
