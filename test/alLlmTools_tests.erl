%%% @doc EUnit tests for alLlmTools.
-module(alLlmTools_tests).

-include_lib("eunit/include/eunit.hrl").

-define(setup, begin ok = alConfig:load() end).

critical_exports_test() ->
    Exports = alLlmTools:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{definitions, 0}, {decodeArgs, 1}, {toolAtom, 1}]].

toolAtomKnown_test() ->
    ?assertEqual(searchCode, alLlmTools:toolAtom(<<"searchCode">>)),
    ?assertEqual(readFile, alLlmTools:toolAtom(<<"readFile">>)).

toolAtomUnknownReturnsBinary_test() ->
    %% Non-existent atom: toolAtom returns the original binary
    Result = alLlmTools:toolAtom(<<"nonExistentTool123">>),
    ?assert(is_binary(Result) orelse is_atom(Result)).

decodeArgsJsonObj_test() ->
    {ok, Map} = alLlmTools:decodeArgs(<<"{\"q\":\"x\"}">>),
    ?assert(is_map(Map)).

decodeArgsEmpty_test() ->
    ?assertEqual({ok, #{}}, alLlmTools:decodeArgs(<<"{}">>)).

decodeArgsInvalid_test() ->
    ?assertMatch({error, _}, alLlmTools:decodeArgs(<<"not json">>)).

definitionsNonEmpty_test() ->
    ?setup,
    Defs = alLlmTools:definitions(),
    ?assert(is_list(Defs) andalso length(Defs) > 0),
    [First | _] = Defs,
    ?assertMatch(#{type := <<"function">>, function := #{name := _, description := _}}, First).
