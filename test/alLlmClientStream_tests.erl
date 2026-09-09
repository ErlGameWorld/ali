%%%-------------------------------------------------------------------
%% @doc Tests for alLlmClient stream parsing helpers.
%% @end
%%%-------------------------------------------------------------------

-module(alLlmClientStream_tests).

-include_lib("eunit/include/eunit.hrl").

parseStreamEventsTextChunk_test() ->
    Data = <<"data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n">>,
    Result = alLlmClient:parseStreamEvents(Data),
    ?assertEqual({ok, [{text, <<"Hello">>}]}, Result).

parseStreamEventsDoneMarker_test() ->
    Data = <<"data: [DONE]\n\n">>,
    Result = alLlmClient:parseStreamEvents(Data),
    ?assertEqual({done, []}, Result).

parseStreamEventsDoneAfterText_test() ->
    Data = <<"data: {\"choices\":[{\"delta\":{\"content\":\"world\"}}]}\n\ndata: [DONE]\n\n">>,
    Result = alLlmClient:parseStreamEvents(Data),
    ?assertEqual({done, [{text, <<"world">>}]}, Result).

parseStreamEventsEmptyIgnores_test() ->
    Result = alLlmClient:parseStreamEvents(<<":comment\n\n">>),
    ?assertEqual(ignore, Result).

parseStreamEventsToolDelta_test() ->
    Data = <<"data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"foo\"}}]}}]}\n\n">>,
    Result = alLlmClient:parseStreamEvents(Data),
    {ok, [Ev]} = Result,
    ?assertMatch({toolDelta, [_]}, Ev).

parseStreamEventsInvalidJsonIgnores_test() ->
    Data = <<"data: not valid json\n\n">>,
    Result = alLlmClient:parseStreamEvents(Data),
    ?assertEqual(ignore, Result).

parseStreamEventsEmptyContentIgnores_test() ->
    Data = <<"data: {\"choices\":[{\"delta\":{\"content\":\"\"}}]}\n\n">>,
    Result = alLlmClient:parseStreamEvents(Data),
    ?assertEqual(ignore, Result).

parseStreamEventsMultipleChunks_test() ->
    Data = <<"data: {\"choices\":[{\"delta\":{\"content\":\"A\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"B\"}}]}\n\n">>,
    Result = alLlmClient:parseStreamEvents(Data),
    ?assertEqual({ok, [{text, <<"A">>}, {text, <<"B">>}]}, Result).

parseStreamEventsHandlesCrlf_test() ->
    Data = <<"data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\r\n\r\n">>,
    Result = alLlmClient:parseStreamEvents(Data),
    ?assertEqual({ok, [{text, <<"hi">>}]}, Result).

parseStreamEventsReasoningContent_test() ->
    Data = <<"data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"think\"}}]}\n\n">>,
    Result = alLlmClient:parseStreamEvents(Data),
    ?assertEqual({ok, [{reasoning, <<"think">>}]}, Result).

parseStreamEventsReasoningAndContent_test() ->
    Data = <<"data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"r\",\"content\":\"c\"}}]}\n\n">>,
    Result = alLlmClient:parseStreamEvents(Data),
    %% parseStreamEventLines 对单行事件列表会 reverse 一次
    ?assertEqual({ok, [{reasoning, <<"r">>}, {text, <<"c">>}]}, Result).

%% stream/4 的 applyStreamEvents 必须吞掉 usage，否则本地模型最后一帧会 function_clause。
applyStreamEventsIgnoresUsage_test() ->
    Events = [{text, <<"A">>}, {usage, #{<<"prompt_tokens">> => 1}}, {text, <<"B">>}],
    Acc = alLlmClient:applyStreamEvents(Events, undefined, <<>>),
    ?assertEqual(<<"AB">>, Acc).

applyStreamEventsUnknownEvent_test() ->
    Acc = alLlmClient:applyStreamEvents([{unknown, x}, {text, <<"ok">>}], undefined, <<>>),
    ?assertEqual(<<"ok">>, Acc).
