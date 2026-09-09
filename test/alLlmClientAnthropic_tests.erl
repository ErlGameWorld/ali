%%% @doc EUnit tests for the Anthropic Messages API adapter in
%%% {@link alLlmClient}.
-module(alLlmClientAnthropic_tests).

-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% Provider routing & URL building
%%%===================================================================

llmConfigProviderDefault_test() ->
    Original = alConfig:get(llm, undefined),
    alConfig:patch([{llm, #{}}]),
    try
        Config = alLlmClient:llmConfig(#{}),
        %% llmConfig 不默认 openai，避免凭空指向 api.openai.com
        ?assertEqual(undefined, maps:get(provider, Config))
    after
        alConfig:patch([{llm, Original}])
    end.

llmConfigProviderFromOpts_test() ->
    Config = alLlmClient:llmConfig(#{provider => anthropic}),
    ?assertEqual(anthropic, maps:get(provider, Config)).

llmConfigAnthropicDefaults_test() ->
    %% Defaults only apply when neither Opts nor the env config supply a
    %% value. Other test modules load the real config (which sets baseUrl),
    %% so clear the llm env for the duration of this assertion and restore
    %% it afterward.
    Original = alConfig:get(llm, undefined),
    alConfig:patch([{llm, #{}}]),
    try
        Config = alLlmClient:llmConfig(#{provider => anthropic, apiKey => <<"sk-ant">>}),
        ?assertEqual(anthropic, maps:get(provider, Config)),
        ?assertEqual(<<"https://api.anthropic.com/v1">>,
            unicode:characters_to_binary(maps:get(baseUrl, Config))),
        ?assertEqual(<<"claude-3-5-sonnet-20241022">>,
            unicode:characters_to_binary(maps:get(model, Config)))
    after
        alConfig:patch([{llm, Original}])
    end.

providerFromOpts_test() ->
    Original = alConfig:get(llm, undefined),
    alConfig:patch([{llm, #{}}]),
    try
        ?assertEqual(openai, alLlmClient:providerFromOpts(#{})),
        ?assertEqual(anthropic, alLlmClient:providerFromOpts(#{provider => anthropic}))
    after
        alConfig:patch([{llm, Original}])
    end.

buildChatUrlAnthropicAppendsMessages_test() ->
    ?assertEqual(<<"https://api.anthropic.com/v1/messages">>,
        alLlmClient:buildChatUrl(<<"https://api.anthropic.com/v1">>, anthropic)).

buildChatUrlOpenaiAppendsCompletions_test() ->
    ?assertEqual(<<"https://api.deepseek.com/chat/completions">>,
        alLlmClient:buildChatUrl(<<"https://api.deepseek.com">>, openai)).

buildChatUrlAvoidsDuplicatingEndpoint_test() ->
    %% Legacy DeepSeek default already contains /chat/completions —
    %% should not append it a second time.
    ?assertEqual(<<"https://api.deepseek.com/chat/completions">>,
        alLlmClient:buildChatUrl(<<"https://api.deepseek.com/chat/completions">>, openai)).

%%%===================================================================
%%% Headers
%%%===================================================================

anthropicHeaders_test() ->
    Hdrs = alLlmClient:anthropicHeaders(<<"sk-ant-xxx">>),
    ?assert(lists:member({<<"x-api-key">>, <<"sk-ant-xxx">>}, Hdrs)),
    ?assert(lists:keymember(<<"anthropic-version">>, 1, Hdrs)),
    ?assert(lists:member({<<"content-type">>, <<"application/json">>}, Hdrs)),
    %% Must NOT include an OpenAI-style Authorization Bearer header.
    ?assertNot(lists:keymember(<<"authorization">>, 1, Hdrs)).

%%%===================================================================
%%% Request body
%%%===================================================================

anthropicRequestBodyBasic_test() ->
    Body = alLlmClient:anthropicRequestBody(
        <<"claude-3-5-sonnet-20241022">>,
        [#{role => user, content => <<"hi">>}],
        [],
        #{}),
    Decoded = alJson:decode(Body),
    ?assertEqual(<<"claude-3-5-sonnet-20241022">>, maps:get(<<"model">>, Decoded)),
    ?assertEqual(4096, maps:get(<<"max_tokens">>, Decoded)),
    Msgs = maps:get(<<"messages">>, Decoded),
    ?assertEqual(1, length(Msgs)),
    [First] = Msgs,
    ?assertEqual(<<"user">>, maps:get(<<"role">>, First)),
    ?assertEqual(<<"hi">>, maps:get(<<"content">>, First)),
    %% No system field when no system message present.
    ?assertNot(maps:is_key(<<"system">>, Decoded)).

anthropicRequestBodyExtractsSystem_test() ->
    Body = alLlmClient:anthropicRequestBody(
        <<"claude-3-5-sonnet-20241022">>,
        [
            #{role => system, content => <<"You are helpful.">>},
            #{role => user, content => <<"hi">>}
        ],
        [],
        #{}),
    Decoded = alJson:decode(Body),
    ?assertEqual(<<"You are helpful.">>, maps:get(<<"system">>, Decoded)),
    Msgs = maps:get(<<"messages">>, Decoded),
    ?assertEqual(1, length(Msgs)),
    [User] = Msgs,
    ?assertEqual(<<"user">>, maps:get(<<"role">>, User)).

anthropicRequestBodyMergesMultipleSystem_test() ->
    Body = alLlmClient:anthropicRequestBody(
        <<"claude">>,
        [
            #{role => system, content => <<"rule1">>},
            #{role => system, content => <<"rule2">>},
            #{role => user, content => <<"hi">>}
        ],
        [],
        #{}),
    Decoded = alJson:decode(Body),
    System = maps:get(<<"system">>, Decoded),
    ?assertEqual(<<"rule1\n\nrule2">>, System).

anthropicRequestBodyWithTools_test() ->
    Tools = [
        #{type => <<"function">>, function => #{
            name => <<"search_code">>,
            description => <<"Search code">>,
            parameters => #{type => object, properties => #{}}
        }}
    ],
    Body = alLlmClient:anthropicRequestBody(
        <<"claude">>,
        [#{role => user, content => <<"hi">>}],
        Tools,
        #{}),
    Decoded = alJson:decode(Body),
    AnthropicTools = maps:get(<<"tools">>, Decoded),
    ?assertEqual(1, length(AnthropicTools)),
    [Tool] = AnthropicTools,
    ?assertEqual(<<"search_code">>, maps:get(<<"name">>, Tool)),
    ?assertEqual(<<"Search code">>, maps:get(<<"description">>, Tool)),
    ?assert(maps:is_key(<<"input_schema">>, Tool)),
    ?assertEqual(#{<<"type">> => <<"auto">>}, maps:get(<<"tool_choice">>, Decoded)).

anthropicRequestBodyTemperatureTopP_test() ->
    Body = alLlmClient:anthropicRequestBody(
        <<"claude">>,
        [#{role => user, content => <<"hi">>}],
        [],
        #{temperature => 0.7, top_p => 0.9}),
    Decoded = alJson:decode(Body),
    ?assertEqual(0.7, maps:get(<<"temperature">>, Decoded)),
    ?assertEqual(0.9, maps:get(<<"top_p">>, Decoded)).

anthropicRequestBodyMaxTokensOverride_test() ->
    Body = alLlmClient:anthropicRequestBody(
        <<"claude">>,
        [#{role => user, content => <<"hi">>}],
        [],
        #{anthropicMaxTokens => 1024}),
    Decoded = alJson:decode(Body),
    ?assertEqual(1024, maps:get(<<"max_tokens">>, Decoded)).

anthropicRequestBodyAssistantWithToolCalls_test() ->
    %% Assistant message with tool_calls must convert to content blocks
    %% (text part + tool_use part).
    Messages = [
        #{role => user, content => <<"do thing">>},
        #{role => assistant, content => <<"calling tool">>,
          tool_calls => [#{id => <<"call_1">>,
                           type => <<"function">>,
                           function => #{name => <<"search_code">>,
                                         arguments => <<"\"query\"">>}}]},
        #{role => tool, tool_call_id => <<"call_1">>, content => <<"result">>}
    ],
    Body = alLlmClient:anthropicRequestBody(
        <<"claude">>,
        Messages,
        [],
        #{}),
    Decoded = alJson:decode(Body),
    Msgs = maps:get(<<"messages">>, Decoded),
    %% Original 3 messages collapse to: user, assistant(tool_use), user(tool_result).
    ?assertEqual(3, length(Msgs)),
    [User1, Assistant, User2] = Msgs,
    ?assertEqual(<<"user">>, maps:get(<<"role">>, User1)),
    ?assertEqual(<<"assistant">>, maps:get(<<"role">>, Assistant)),
    AssistantContent = maps:get(<<"content">>, Assistant),
    ?assert(is_list(AssistantContent)),
    ToolUseBlocks = [B || B <- AssistantContent, maps:get(<<"type">>, B, <<>>) =:= <<"tool_use">>],
    ?assertEqual(1, length(ToolUseBlocks)),
    [ToolUse] = ToolUseBlocks,
    ?assertEqual(<<"call_1">>, maps:get(<<"id">>, ToolUse)),
    ?assertEqual(<<"search_code">>, maps:get(<<"name">>, ToolUse)),
    %% The trailing tool result becomes a user message with tool_result block.
    ?assertEqual(<<"user">>, maps:get(<<"role">>, User2)),
    User2Content = maps:get(<<"content">>, User2),
    ToolResultBlocks = [B || B <- User2Content, maps:get(<<"type">>, B, <<>>) =:= <<"tool_result">>],
    ?assertEqual(1, length(ToolResultBlocks)).

%%%===================================================================
%%% Response parsing
%%%===================================================================

parseAnthropicResponseTextOnly_test() ->
    Body = alJson:encode(#{
        <<"id">> => <<"msg_1">>,
        <<"type">> => <<"message">>,
        <<"role">> => <<"assistant">>,
        <<"model">> => <<"claude-3-5-sonnet-20241022">>,
        <<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"hello world">>}],
        <<"stop_reason">> => <<"end_turn">>,
        <<"usage">> => #{<<"input_tokens">> => 10, <<"output_tokens">> => 5}
    }),
    {ok, Result} = alLlmClient:parseAnthropicResponse(Body),
    ?assertEqual(anthropic, maps:get(provider, Result)),
    ?assertEqual(<<"hello world">>, maps:get(content, Result)),
    ?assertEqual([], maps:get(tool_calls, Result)),
    ?assertEqual(<<"claude-3-5-sonnet-20241022">>, maps:get(model, Result)),
    ?assertEqual(<<"stop">>, maps:get(finish_reason, Result)),
    Usage = maps:get(usage, Result),
    ?assertEqual(10, maps:get(input_tokens, Usage)),
    ?assertEqual(5, maps:get(output_tokens, Usage)),
    ?assertEqual(15, maps:get(total_tokens, Usage)).

parseAnthropicResponseWithToolUse_test() ->
    Body = alJson:encode(#{
        <<"id">> => <<"msg_2">>,
        <<"type">> => <<"message">>,
        <<"role">> => <<"assistant">>,
        <<"model">> => <<"claude-3-5-sonnet-20241022">>,
        <<"content">> => [
            #{<<"type">> => <<"text">>, <<"text">> => <<"Let me search.">>},
            #{<<"type">> => <<"tool_use">>,
              <<"id">> => <<"toolu_1">>,
              <<"name">> => <<"search_code">>,
              <<"input">> => #{<<"query">> => <<"foo">>}}
        ],
        <<"stop_reason">> => <<"tool_use">>,
        <<"usage">> => #{<<"input_tokens">> => 20, <<"output_tokens">> => 8}
    }),
    {ok, Result} = alLlmClient:parseAnthropicResponse(Body),
    ?assertEqual(<<"Let me search.">>, maps:get(content, Result)),
    ToolCalls = maps:get(tool_calls, Result),
    ?assertEqual(1, length(ToolCalls)),
    [Call] = ToolCalls,
    ?assertEqual(<<"toolu_1">>, maps:get(id, Call)),
    ?assertEqual(<<"function">>, maps:get(type, Call)),
    Function = maps:get(function, Call),
    ?assertEqual(<<"search_code">>, maps:get(name, Function)),
    ArgsBin = maps:get(arguments, Function),
    ArgsMap = alJson:decode(ArgsBin),
    ?assertEqual(<<"foo">>, maps:get(<<"query">>, ArgsMap)),
    ?assertEqual(<<"tool_calls">>, maps:get(finish_reason, Result)).

parseAnthropicResponseMalformedJson_test() ->
    Body = <<"not json at all">>,
    {ok, Result} = alLlmClient:parseAnthropicResponse(Body),
    ?assertEqual(anthropic, maps:get(provider, Result)),
    ?assertEqual(Body, maps:get(content, Result)).

parseAnthropicResponseMissingFields_test() ->
    %% Minimal body with no content/usage — must still return a valid map.
    Body = alJson:encode(#{<<"id">> => <<"msg_x">>}),
    {ok, Result} = alLlmClient:parseAnthropicResponse(Body),
    ?assertEqual(anthropic, maps:get(provider, Result)),
    ?assertEqual(<<>>, maps:get(content, Result)),
    ?assertEqual([], maps:get(tool_calls, Result)).

parseAnthropicResponseFinishReasonMapping_test() ->
    Body = alJson:encode(#{
        <<"content">> => [],
        <<"stop_reason">> => <<"max_tokens">>
    }),
    {ok, Result} = alLlmClient:parseAnthropicResponse(Body),
    ?assertEqual(<<"length">>, maps:get(finish_reason, Result)).

%%%===================================================================
%%% Tool choice
%%%===================================================================

anthropicRequestBodyToolChoiceNamed_test() ->
    Tools = [
        #{type => <<"function">>, function => #{
            name => <<"search_code">>,
            description => <<"Search code">>,
            parameters => #{type => object}
        }}
    ],
    Body = alLlmClient:anthropicRequestBody(
        <<"claude">>,
        [#{role => user, content => <<"hi">>}],
        Tools,
        #{tool_choice => {tool, <<"search_code">>}}),
    Decoded = alJson:decode(Body),
    ?assertEqual(#{<<"type">> => <<"tool">>, <<"name">> => <<"search_code">>},
        maps:get(<<"tool_choice">>, Decoded)).
