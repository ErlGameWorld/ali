-module(alAskDiag_tests).

-include_lib("eunit/include/eunit.hrl").

sanitize_short_binary_unchanged_test() ->
    ?assertEqual(<<"hi">>, alAskDiag:sanitize(<<"hi">>)).

sanitize_long_binary_truncated_test() ->
    Big = binary:copy(<<"a">>, 1000),
    Out = alAskDiag:sanitize(Big),
    ?assert(is_binary(Out)),
    ?assert(byte_size(Out) < 300),
    ?assertMatch(<<"a", _/binary>>, Out).

sanitize_nested_tool_content_test() ->
    Big = binary:copy(<<"x">>, 5000),
    Reason = {llmFailed, callerDown, [{results, [#{content => Big, name => lastCommit}]}]},
    Out = alAskDiag:sanitize(Reason),
    Flat = iolist_to_binary(io_lib:format("~p", [Out])),
    ?assert(byte_size(Flat) < 800),
    ?assertEqual(nomatch, binary:match(Flat, binary:copy(<<"x">>, 400))).
