%%% @doc EUnit tests for DeepSeek V4 DSML tool-call recovery.
-module(alDsmlTools_tests).

-include_lib("eunit/include/eunit.hrl").

%% Official-ish V4 markup (ASCII pipes for test portability).
sample_dsml() ->
    <<"你说得对，让我重查。\n"
      "<|DSML|tool_calls>\n"
      "<|DSML|invoke name=\"readFile\">\n"
      "<|DSML|parameter name=\"path\" string=\"true\">plugin/game/src/x.erl</|DSML|parameter>\n"
      "<|DSML|parameter name=\"offset\" string=\"false\">915</|DSML|parameter>\n"
      "<|DSML|parameter name=\"maxBytes\" string=\"false\">3000</|DSML|parameter>\n"
      "</|DSML|invoke>\n"
      "<|DSML|invoke name=\"searchText\">\n"
      "<|DSML|parameter name=\"path\" string=\"true\">plugin/game/src</|DSML|parameter>\n"
      "<|DSML|parameter name=\"query\" string=\"true\">INSTRUCT_TRANSFER</|DSML|parameter>\n"
      "<|DSML|parameter name=\"limit\" string=\"false\">20</|DSML|parameter>\n"
      "</|DSML|invoke>\n"
      "</|DSML|tool_calls>"/utf8>>.

%% Doubled-pipe variant as seen in leaked UI text.
sample_doubled() ->
    <<"<｜｜DSML｜｜tool_calls>\n"
      "<｜｜DSML｜｜invoke name=\"readFile\">\n"
      "<｜｜DSML｜｜parameter name=\"path\" string=\"true\">a.erl</｜｜DSML｜｜parameter>\n"
      "</｜｜DSML｜｜invoke>\n"
      "</｜｜DSML｜｜tool_calls>"/utf8>>.

has_markers_test() ->
    ?assert(alDsmlTools:hasDsmlMarkers(sample_dsml())),
    ?assertNot(alDsmlTools:hasDsmlMarkers(<<"normal answer">>)).

recover_two_calls_test() ->
    {Clean, Calls} = alDsmlTools:recoverFromContent(sample_dsml()),
    ?assertEqual(2, length(Calls)),
    [C1, C2] = Calls,
    ?assertEqual(<<"readFile">>, maps:get(name, maps:get(function, C1))),
    ?assertEqual(<<"searchText">>, maps:get(name, maps:get(function, C2))),
    Args1 = alJson:decode(maps:get(arguments, maps:get(function, C1))),
    ?assertEqual(<<"plugin/game/src/x.erl">>, maps:get(<<"path">>, Args1)),
    ?assertEqual(915, maps:get(<<"offset">>, Args1)),
    ?assertEqual(3000, maps:get(<<"maxBytes">>, Args1)),
    %% DSML stripped from visible content
    ?assertEqual(nomatch, binary:match(Clean, <<"DSML">>)),
    ?assert(binary:match(Clean, <<"重查"/utf8>>) =/= nomatch).

recover_doubled_pipes_test() ->
    {Clean, Calls} = alDsmlTools:recoverFromContent(sample_doubled()),
    ?assertEqual(1, length(Calls)),
    ?assertEqual(<<"readFile">>, maps:get(name, maps:get(function, hd(Calls)))),
    ?assertEqual(nomatch, binary:match(Clean, <<"DSML">>)).

no_dsml_passthrough_test() ->
    Bin = <<"just text">>,
    ?assertEqual({Bin, []}, alDsmlTools:recoverFromContent(Bin)).

parse_chat_recovers_dsml_test() ->
    Content = sample_dsml(),
    Body = iolist_to_binary([
        <<"{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":">> ,
        alJson:encode(Content),
        <<",\"tool_calls\":null}}]}">>
    ]),
    {ok, Result} = alLlmClient:parseChatResponse(Body),
    Calls = maps:get(tool_calls, Result),
    ?assertEqual(2, length(Calls)),
    Clean = maps:get(content, Result),
    ?assertEqual(nomatch, binary:match(Clean, <<"tool_calls">>)).
