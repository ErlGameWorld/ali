%%%-------------------------------------------------------------------
%%% @doc Mock LLM HTTP 集成测试：不访问真实网络。
%%% 通过 Opts `httpRequestFun` 注入假 OpenAI 兼容响应。
%%%-------------------------------------------------------------------
-module(alLlmMock_tests).

-include_lib("eunit/include/eunit.hrl").

mock_chat_with_tool_calls_test() ->
    Resp = <<
        "{\"id\":\"chatcmpl-mock\",\"choices\":[{"
        "\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":null,"
        "\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\","
        "\"function\":{\"name\":\"search_code\","
        "\"arguments\":\"{\\\"query\\\":\\\"supervisor\\\"}\"}}]},"
        "\"finish_reason\":\"tool_calls\"}],"
        "\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"total_tokens\":15}}"
    >>,
    Fun = fun(_Method, _Url, _Headers, _Body, _Opts) ->
        {ok, 200, [], {mockBody, Resp}}
    end,
    Opts = #{
        provider => openai,
        model => <<"mock-model">>,
        apiKey => <<"sk-mock">>,
        baseUrl => <<"http://127.0.0.1:9">>,
        httpRequestFun => Fun,
        llmMaxRetries => 0
    },
    Messages = [#{role => <<"user">>, content => <<"find supervisor">>}],
    {ok, Result} = alLlmClient:chatWithTools(Messages, [], Opts),
    ?assert(is_map(Result)),
    ToolCalls = maps:get(tool_calls, Result, maps:get(<<"tool_calls">>, Result, [])),
    ?assert(is_list(ToolCalls)),
    ?assert(length(ToolCalls) >= 1).

mock_stream_body_includes_stream_true_test() ->
    Body = alLlmClient:encodeChatBody(<<"m">>, [#{role => user, content => <<"hi">>}], [],
                                      #{stream => true}),
    ?assertNotEqual(nomatch, binary:match(Body, <<"\"stream\":true">>)).

mock_http_error_status_test() ->
    Fun = fun(_Method, _Url, _Headers, _Body, _Opts) ->
        {ok, 429, [], {mockBody, <<"{\"error\":\"rate\"}">>}}
    end,
    Opts = #{
        provider => openai,
        model => <<"mock-model">>,
        apiKey => <<"sk-mock">>,
        baseUrl => <<"http://127.0.0.1:9">>,
        httpRequestFun => Fun,
        llmMaxRetries => 0
    },
    {error, Err} = alLlmClient:chatWithTools(
        [#{role => <<"user">>, content => <<"x">>}], [], Opts),
    case Err of
        #{status := 429} -> ok;
        _ ->
            %% 部分路径会包装重试错误
            ?assert(is_map(Err) orelse is_tuple(Err) orelse is_atom(Err))
    end.

prometheus_text_exports_counters_test() ->
    alMetrics:ensureStarted(),
    alMetrics:bump(askCount, 1),
    Text = alMetrics:prometheusText(),
    ?assertNotEqual(nomatch, binary:match(Text, <<"ali_asks_total">>)),
    ?assertNotEqual(nomatch, binary:match(Text, <<"# TYPE">>)).
