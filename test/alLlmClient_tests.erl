%%% @doc EUnit tests for alLlmClient pure helpers.
-module(alLlmClient_tests).

-include_lib("eunit/include/eunit.hrl").

-define(setup, begin ok = alConfig:load() end).

%% parseChatResponse/1 — OpenAI-compatible response parsing

parseChatResponseValid_test() ->
    Body = <<"{\"model\":\"m\",\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"hello\"}}],\"usage\":{\"prompt_tokens\":1}}">>,
    {ok, Result} = alLlmClient:parseChatResponse(Body),
    ?assertMatch(#{provider := openaiCompatible, content := <<"hello">>,
                   tool_calls := [], message := #{role := <<"assistant">>}}, Result),
    ?assertEqual(<<"m">>, maps:get(model, Result)),
    ?assertMatch(#{<<"prompt_tokens">> := 1}, maps:get(usage, Result)).

parseChatResponseWithToolCalls_test() ->
    Body = <<"{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"search\",\"arguments\":\"{}\"}}]}}]}">>,
    {ok, Result} = alLlmClient:parseChatResponse(Body),
    ToolCalls = maps:get(tool_calls, Result),
    ?assertEqual(1, length(ToolCalls)),
    [#{id := <<"call_1">>, function := #{name := <<"search">>}}] = ToolCalls.

parseChatResponseWithReasoning_test() ->
    Body = <<"{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null,\"reasoning_content\":\"think\",\"tool_calls\":[{\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"x\",\"arguments\":\"{}\"}}]}}]}">>,
    {ok, Result} = alLlmClient:parseChatResponse(Body),
    ?assertEqual(<<"think">>, maps:get(reasoning_content, Result)),
    Msg = maps:get(message, Result),
    ?assertEqual(<<"think">>, maps:get(reasoning_content, Msg)).

encodeMessageKeepsReasoning_test() ->
    Messages = [
        #{role => user, content => <<"hi">>},
        #{role => assistant, content => null, reasoning_content => <<"r1">>,
          tool_calls => [#{id => <<"c1">>, function => #{name => <<"t">>, arguments => <<"{}">>}}]},
        #{role => tool, tool_call_id => <<"c1">>, content => <<"ok">>}
    ],
    Body = alLlmClient:encodeChatBody(<<"m">>, Messages, [], #{}),
    ?assertNotEqual(nomatch, binary:match(Body, <<"reasoning_content">>)),
    ?assertNotEqual(nomatch, binary:match(Body, <<"r1">>)).

encodeMessageInjectsEmptyReasoning_test() ->
    Messages = [
        #{role => assistant, content => null,
          tool_calls => [#{id => <<"c1">>, function => #{name => <<"t">>, arguments => <<"{}">>}}]},
        #{role => tool, tool_call_id => <<"c1">>, content => <<"ok">>}
    ],
    Body = alLlmClient:encodeChatBody(<<"m">>, Messages, [], #{}),
    ?assertNotEqual(nomatch, binary:match(Body, <<"reasoning_content">>)).

parseChatResponseNoChoices_test() ->
    Body = <<"{\"error\":\"rate_limited\"}">>,
    {ok, Result} = alLlmClient:parseChatResponse(Body),
    ?assertMatch(#{provider := openaiCompatible, content := Body, parseWarning := noChoices}, Result).

parseChatResponseMalformedJson_test() ->
    Body = <<"not json">>,
    {ok, Result} = alLlmClient:parseChatResponse(Body),
    ?assertMatch(#{provider := openaiCompatible, content := Body}, Result),
    ?assertEqual(Body, maps:get(raw, Result)).

%% extractMessage/1

extractMessageWithMessage_test() ->
    Decoded = #{<<"choices">> => [#{<<"message">> => #{<<"role">> => <<"assistant">>, <<"content">> => <<"hi">>}}]},
    ?assertMatch({ok, #{role := <<"assistant">>, content := <<"hi">>, tool_calls := []}},
                 alLlmClient:extractMessage(Decoded)).

extractMessageNoMessage_test() ->
    Decoded = #{<<"choices">> => [#{<<"other">> => 1}]},
    ?assertEqual({error, noMessage}, alLlmClient:extractMessage(Decoded)).

extractMessageNoChoices_test() ->
    ?assertEqual({error, noChoices}, alLlmClient:extractMessage(#{<<"foo">> => 1})).

%% firstDefined/1

firstDefinedSkipsFalsy_test() ->
    ?assertEqual(value, alLlmClient:firstDefined([undefined, "", false, value, later])).

firstDefinedFirstWins_test() ->
    ?assertEqual(first, alLlmClient:firstDefined([first, second])).

firstDefinedEmptyReturnsUndefined_test() ->
    ?assertEqual(undefined, alLlmClient:firstDefined([])).

firstDefinedAllFalsyReturnsUndefined_test() ->
    ?assertEqual(undefined, alLlmClient:firstDefined([undefined, false, ""])).

%% encodeChatBody/3

encodeChatBodyBasic_test() ->
    Body = alLlmClient:encodeChatBody("m", [#{role => user, content => <<"hi">>}], []),
    ?assert(is_binary(Body)),
    Decoded = alJson:decode(Body),
    ?assertEqual(<<"m">>, maps:get(<<"model">>, Decoded)),
    [Msg] = maps:get(<<"messages">>, Decoded),
    ?assertEqual(<<"user">>, maps:get(<<"role">>, Msg)),
    ?assertEqual(<<"hi">>, maps:get(<<"content">>, Msg)).

encodeChatBodyWithTools_test() ->
    Tool = #{type => <<"function">>, function => #{name => search, description => <<"search code">>, parameters => #{type => object}}},
    Body = alLlmClient:encodeChatBody("m", [#{role => user, content => <<"q">>}], [Tool]),
    Decoded = alJson:decode(Body),
    ?assert(maps:is_key(<<"tools">>, Decoded)),
    [EncodedTool] = maps:get(<<"tools">>, Decoded),
    ?assertEqual(<<"function">>, maps:get(<<"type">>, EncodedTool)).

encodeChatBodyNullContent_test() ->
    Body = alLlmClient:encodeChatBody("m", [#{role => assistant, content => null}], []),
    Decoded = alJson:decode(Body),
    [Msg] = maps:get(<<"messages">>, Decoded),
    ?assertEqual(null, maps:get(<<"content">>, Msg)).

encodeChatBodyEscapesQuotes_test() ->
    Body = alLlmClient:encodeChatBody("m", [#{role => user, content => <<"hello \"world\"">>}], []),
    Decoded = alJson:decode(Body),
    [Msg] = maps:get(<<"messages">>, Decoded),
    ?assertEqual(<<"hello \"world\"">>, maps:get(<<"content">>, Msg)).

%% 百炼 qwen：thinking=enabled → enable_thinking=true + stream
encodeChatBody_qwen_enable_thinking_stream_test() ->
    Body = alLlmClient:encodeChatBody(
        <<"qwen3.8-max">>,
        [#{role => user, content => <<"hi">>}],
        [],
        #{provider => qwen, thinking => enabled, stream => true}),
    Decoded = alJson:decode(Body),
    ?assertEqual(true, maps:get(<<"enable_thinking">>, Decoded)),
    ?assertEqual(true, maps:get(<<"stream">>, Decoded)),
    ?assertEqual(false, maps:is_key(<<"thinking">>, Decoded)).

%% DeepSeek：thinking=enabled → thinking.type=enabled（不是 enable_thinking）
encodeChatBody_deepseek_thinking_type_test() ->
    Body = alLlmClient:encodeChatBody(
        <<"deepseek-v4-flash">>,
        [#{role => user, content => <<"hi">>}],
        [],
        #{provider => deepseek, thinking => enabled}),
    Decoded = alJson:decode(Body),
    ?assertEqual(false, maps:is_key(<<"enable_thinking">>, Decoded)),
    Thinking = maps:get(<<"thinking">>, Decoded),
    ?assertEqual(<<"enabled">>, maps:get(<<"type">>, Thinking)).

%% Gemini OpenAI 兼容层不接受 thinking / enable_thinking，须省略。
encodeChatBody_gemini_omits_thinking_test() ->
    Body = alLlmClient:encodeChatBody(
        <<"gemini-3.8-flash">>,
        [#{role => user, content => <<"hi">>}],
        [],
        #{provider => gemini, thinking => disabled}),
    Decoded = alJson:decode(Body),
    ?assertEqual(false, maps:is_key(<<"thinking">>, Decoded)),
    ?assertEqual(false, maps:is_key(<<"enable_thinking">>, Decoded)).

%% 智谱 GLM：thinking=enabled → thinking 对象下发（cfg 意图真正生效）。
encodeChatBody_zhipu_thinking_enabled_test() ->
    Body = alLlmClient:encodeChatBody(
        <<"glm-5.3-flash">>,
        [#{role => user, content => <<"hi">>}],
        [],
        #{provider => zhipu, thinking => enabled}),
    Decoded = alJson:decode(Body),
    Thinking = maps:get(<<"thinking">>, Decoded),
    ?assertEqual(<<"enabled">>, maps:get(<<"type">>, Thinking)),
    ?assertEqual(false, maps:is_key(<<"budget">>, Thinking)).

%% 智谱 GLM：thinking=disabled → 不下发字段（glm-5.3-flash 等始终思考
%% 模型对 disabled 返回 400/1210，下发会打断整轮调用）。
encodeChatBody_zhipu_thinking_disabled_omitted_test() ->
    Body = alLlmClient:encodeChatBody(
        <<"glm-5.3-flash">>,
        [#{role => user, content => <<"hi">>}],
        [],
        #{provider => glm, thinking => disabled}),
    Decoded = alJson:decode(Body),
    ?assertEqual(false, maps:is_key(<<"thinking">>, Decoded)).

%% 智谱 GLM：thinkingBudget=low → thinking 带 budget（复审/浅思考提速）。
encodeChatBody_zhipu_thinking_budget_test() ->
    Body = alLlmClient:encodeChatBody(
        <<"glm-5.3-flash">>,
        [#{role => user, content => <<"hi">>}],
        [],
        #{provider => zhipu, thinking => enabled, thinkingBudget => low}),
    Decoded = alJson:decode(Body),
    Thinking = maps:get(<<"thinking">>, Decoded),
    ?assertEqual(<<"enabled">>, maps:get(<<"type">>, Thinking)),
    ?assertEqual(<<"low">>, maps:get(<<"budget">>, Thinking)).

%% budget 仅智谱系生效：DeepSeek 带 thinkingBudget 不得泄漏 budget 字段。
encodeChatBody_budget_ignored_for_deepseek_test() ->
    Body = alLlmClient:encodeChatBody(
        <<"deepseek-v4-flash">>,
        [#{role => user, content => <<"hi">>}],
        [],
        #{provider => deepseek, thinking => enabled, thinkingBudget => low}),
    Decoded = alJson:decode(Body),
    Thinking = maps:get(<<"thinking">>, Decoded),
    ?assertEqual(false, maps:is_key(<<"budget">>, Thinking)).

%% maxTokens（配置惯用别名）应映射为 OpenAI 的 max_tokens。
encodeChatBodyMaxTokensAlias_test() ->
    Body = alLlmClient:encodeChatBody(
        <<"m">>, [#{role => user, content => <<"hi">>}], [], #{maxTokens => 512}),
    Decoded = alJson:decode(Body),
    ?assertEqual(512, maps:get(<<"max_tokens">>, Decoded)).

%% OpenAI 原名 max_tokens 优先于别名。
encodeChatBodyMaxTokensSnakeCase_test() ->
    Body = alLlmClient:encodeChatBody(
        <<"m">>, [#{role => user, content => <<"hi">>}], [],
        #{maxTokens => 512, max_tokens => 256}),
    Decoded = alJson:decode(Body),
    ?assertEqual(256, maps:get(<<"max_tokens">>, Decoded)).

%% 未配置时默认 8192，防止本地模型陷入重复生成直至超时。
encodeChatBodyMaxTokensDefault_test() ->
    Body = alLlmClient:encodeChatBody(
        <<"m">>, [#{role => user, content => <<"hi">>}], [], #{}),
    Decoded = alJson:decode(Body),
    ?assertEqual(8192, maps:get(<<"max_tokens">>, Decoded)).

%% llmConfig/1

llmConfigDefaults_test() ->
    ?setup,
    Config = alLlmClient:llmConfig(#{}),
    ?assertMatch(#{baseUrl := _, model := _}, Config),
    Base = unicode:characters_to_binary(maps:get(baseUrl, Config)),
    Model = unicode:characters_to_binary(maps:get(model, Config)),
    %% Config may override provider defaults (host-only baseUrl + model name).
    ?assert(
        binary:match(Base, <<"deepseek.com">>) =/= nomatch
        orelse binary:match(Base, <<"dashscope.aliyuncs.com">>) =/= nomatch
        orelse binary:match(Base, <<"openai.com">>) =/= nomatch
        orelse binary:match(Base, <<"bigmodel.cn">>) =/= nomatch
        orelse binary:match(Base, <<"googleapis.com">>) =/= nomatch
        orelse binary:match(Base, <<"127.0.0.1">>) =/= nomatch
        orelse binary:match(Base, <<"localhost">>) =/= nomatch
    ),
    ?assert(byte_size(Model) > 0).

llmConfigOptsOverride_test() ->
    ?setup,
    Config = alLlmClient:llmConfig(#{apiKey => <<"sk-x">>, model => <<"gpt-4">>}),
    ?assertEqual(<<"sk-x">>, maps:get(apiKey, Config)),
    ?assertEqual(<<"gpt-4">>, unicode:characters_to_binary(maps:get(model, Config))).

%% contentToText/1

contentToTextBinary_test() ->
    ?assertEqual(<<"hi">>, alLlmClient:contentToText(<<"hi">>)).

contentToTextList_test() ->
    ?assertEqual(<<"list">>, alLlmClient:contentToText("list")).

contentToTextMap_test() ->
    Text = alLlmClient:contentToText(#{a => 1}),
    ?assert(is_binary(Text)).

%% jsonEscape/1

jsonEscapeBasic_test() ->
    ?assertEqual(<<"\\\"hi\\\"">>, alLlmClient:jsonEscape("\"hi\"")).

jsonEscapeNewline_test() ->
    ?assertEqual(<<"a\\nb">>, alLlmClient:jsonEscape("a\nb")).

jsonEscapeBackslash_test() ->
    ?assertEqual(<<"a\\\\b">>, alLlmClient:jsonEscape("a\\b")).

jsonEscapePassthrough_test() ->
    ?assertEqual(<<"plain">>, alLlmClient:jsonEscape("plain")).

%% shouldRetry/1

shouldRetry429_test() ->
    ?assert(alLlmClient:shouldRetry({error, #{status => 429}})).

shouldRetry500_test() ->
    ?assert(alLlmClient:shouldRetry({error, #{status => 500}})).

shouldRetry503_test() ->
    ?assert(alLlmClient:shouldRetry({error, #{status => 503}})).

shouldRetry400False_test() ->
    ?assertNot(alLlmClient:shouldRetry({error, #{status => 400}})).

shouldRetry404False_test() ->
    ?assertNot(alLlmClient:shouldRetry({error, #{status => 404}})).

shouldRetryNonErrorFalse_test() ->
    ?assertNot(alLlmClient:shouldRetry({ok, result})),
    ?assertNot(alLlmClient:shouldRetry({error, bad_request})).

shouldRetryClosed_test() ->
    ?assert(alLlmClient:shouldRetry({error, closed})),
    ?assert(alLlmClient:shouldRetry({error, {closed, normal}})),
    ?assert(alLlmClient:shouldRetry({error, timeout})),
    ?assert(alLlmClient:shouldRetry({error, econnreset})).

shouldRetryConnRefusedFalse_test() ->
    ?assertNot(alLlmClient:shouldRetry({error, econnrefused})),
    ?assertNot(alLlmClient:shouldRetry({error, {connectFailed, econnrefused}})),
    ?assertNot(alLlmClient:shouldRetry({error, callerDown})),
    ?assertNot(alLlmClient:shouldRetry({error, cancelled})).

%% 正文已开始后的流中断不应重试：重试会重复输出/重复计费。
shouldRetryStreamStartedFalse_test() ->
    ?assertNot(alLlmClient:shouldRetry({error, {streamStarted, streamTimeout}})),
    ?assertNot(alLlmClient:shouldRetry({error, {streamStarted, cancelled}})).

%% streamFallbackSafe/1
%% eWCli 规定 streamStarted 后不应再降级非流式；callerDown/cancelled 同样不应降级。
streamFallbackSafeBlocksStreamStarted_test() ->
    ?assertNot(alLlmClient:streamFallbackSafe({streamStarted, streamTimeout})),
    ?assertNot(alLlmClient:streamFallbackSafe({streamStarted, cancelled})),
    ?assertNot(alLlmClient:streamFallbackSafe(callerDown)),
    ?assertNot(alLlmClient:streamFallbackSafe(cancelled)).

streamFallbackSafeAllowsPreBodyErrors_test() ->
    ?assert(alLlmClient:streamFallbackSafe(streamTimeout)),
    ?assert(alLlmClient:streamFallbackSafe(timeout)),
    ?assert(alLlmClient:streamFallbackSafe(closed)),
    ?assert(alLlmClient:streamFallbackSafe(econnreset)),
    ?assert(alLlmClient:streamFallbackSafe(#{status => 503, body => <<>>})).

llmHttpTransportOpts_defaults_test() ->
    Opts = alLlmClient:llmHttpTransportOpts(#{}),
    ?assertEqual(true, maps:get(usePool, Opts)),
    ?assertEqual(true, maps:get(alpn, Opts)),
    ?assertEqual(tcp, maps:get(protocol, Opts)).

llmHttpTransportOpts_override_test() ->
    Opts = alLlmClient:llmHttpTransportOpts(#{httpUsePool => false, httpAlpn => false,
                                             httpProtocol => auto}),
    ?assertEqual(false, maps:get(usePool, Opts)),
    ?assertEqual(false, maps:get(alpn, Opts)),
    ?assertEqual(auto, maps:get(protocol, Opts)).

%% retryDelay/1

retryDelayPositive_test() ->
    Delay = alLlmClient:retryDelay(0),
    ?assert(is_integer(Delay)),
    ?assert(Delay > 0).

retryDelayIncreases_test() ->
    D0 = alLlmClient:retryDelay(0),
    D3 = alLlmClient:retryDelay(3),
    ?assert(D3 > D0).

retryDelayCappedAt60s_test() ->
    Delay = alLlmClient:retryDelay(10),
    ?assert(Delay =< 60000 + 18000).

%% capContent/1

capContentShortBinaryUnchanged_test() ->
    ?assertEqual(<<"hello">>, alLlmClient:capContent(<<"hello">>)).

capContentLongBinaryTruncated_test() ->
    Long = binary:copy(<<"x">>, 20000),
    Capped = alLlmClient:capContent(Long),
    ?assertEqual(16000 + length("\n...[content truncated for API]"), byte_size(Capped)),
    %% Verify truncation marker is present
    Suffix = binary:part(Capped, byte_size(Capped), -length("\n...[content truncated for API]")),
    ?assertEqual(<<"\n...[content truncated for API]">>, Suffix).

capContentNullReturnsNull_test() ->
    ?assertEqual(null, alLlmClient:capContent(null)).

capContentListInput_test() ->
    ?assertEqual(<<"hello">>, alLlmClient:capContent("hello")).

%% capBinary/1

capBinaryShortUnchanged_test() ->
    ?assertEqual(<<"short">>, alLlmClient:capBinary(<<"short">>)).

capBinaryExactLimitUnchanged_test() ->
    Bin = binary:copy(<<"a">>, 16000),
    ?assertEqual(Bin, alLlmClient:capBinary(Bin)).

capBinaryOverLimitTruncated_test() ->
    Bin = binary:copy(<<"b">>, 16001),
    Capped = alLlmClient:capBinary(Bin),
    ?assert(byte_size(Capped) > 16000),
    ?assert(byte_size(Capped) < 16100).

%% encodeChatBody with content capping

encodeChatBodyCapsLongContent_test() ->
    Long = binary:copy(<<"z">>, 20000),
    Body = alLlmClient:encodeChatBody("m", [#{role => user, content => Long}], []),
    Decoded = alJson:decode(Body),
    [Msg] = maps:get(<<"messages">>, Decoded),
    Content = maps:get(<<"content">>, Msg),
    ?assert(byte_size(Content) < 17000),
    %% Verify truncation marker
    ?assert(binary:match(Content, <<"[content truncated for API]">>) =/= nomatch).

%% OpenAI path tool_choice (was missing from encodeChatExtras)

encodeChatBodyToolChoiceAuto_test() ->
    Body = alLlmClient:encodeChatBody(<<"m">>,
        [#{role => user, content => <<"hi">>}],
        [#{<<"type">> => <<"function">>,
           <<"function">> => #{<<"name">> => <<"searchCode">>,
                               <<"parameters">> => #{<<"type">> => <<"object">>}}}],
        #{tool_choice => auto}),
    Decoded = alJson:decode(Body),
    ?assertEqual(<<"auto">>, maps:get(<<"tool_choice">>, Decoded)).

encodeChatBodyToolChoiceNamed_test() ->
    Body = alLlmClient:encodeChatBody(<<"m">>,
        [#{role => user, content => <<"hi">>}],
        [],
        #{tool_choice => {tool, <<"readFile">>}}),
    Decoded = alJson:decode(Body),
    Choice = maps:get(<<"tool_choice">>, Decoded),
    ?assertEqual(<<"function">>, maps:get(<<"type">>, Choice)),
    Fun = maps:get(<<"function">>, Choice),
    ?assertEqual(<<"readFile">>, maps:get(<<"name">>, Fun)).

encodeChatBodyOmitsToolChoiceByDefault_test() ->
    Body = alLlmClient:encodeChatBody(<<"m">>,
        [#{role => user, content => <<"hi">>}], []),
    Decoded = alJson:decode(Body),
    ?assertEqual(false, maps:is_key(<<"tool_choice">>, Decoded)).

%% C2 回归：缺 tool_call_id 的 tool 消息不应触发无限递归，且能降级返回。
convert_messages_for_anthropic_missing_tool_call_id_test() ->
    Msgs = [
        #{role => user, content => <<"hi">>},
        #{role => assistant, content => null,
          tool_calls => [#{id => <<"c1">>,
                           function => #{name => <<"t">>, arguments => <<"{}">>}}]},
        #{role => tool, content => <<"ok">>},  %% 缺 tool_call_id
        #{role => user, content => <<"after">>}
    ],
    Result = alLlmClient:convertMessagesForAnthropic(Msgs),
    ?assert(is_list(Result)),
    ?assertEqual(4, length(Result)),
    [User1, Assistant, ToolUser, User2] = Result,
    ?assertEqual(<<"user">>, maps:get(<<"role">>, User1)),
    AssistantBlocks = maps:get(<<"content">>, Assistant),
    ?assert(lists:any(fun(B) -> maps:get(<<"type">>, B, undefined) =:= <<"tool_use">> end,
                      AssistantBlocks)),
    %% tool 消息降级为 user 消息，内含 tool_result 块，tool_use_id 为空
    ?assertEqual(<<"user">>, maps:get(<<"role">>, ToolUser)),
    ToolBlocks = maps:get(<<"content">>, ToolUser),
    [ToolResult] = [B || B <- ToolBlocks, maps:get(<<"type">>, B) =:= <<"tool_result">>],
    ?assertEqual(<<>>, maps:get(<<"tool_use_id">>, ToolResult)),
    ?assertEqual(<<"ok">>, maps:get(<<"content">>, ToolResult)),
    ?assertEqual(<<"user">>, maps:get(<<"role">>, User2)).

%% 合法 tool_call_id（atom 键）路径行为保持不变。
convert_messages_for_anthropic_valid_tool_result_test() ->
    Msgs = [
        #{role => assistant,
          tool_calls => [#{id => <<"c9">>,
                           function => #{name => <<"t">>, arguments => <<"{}">>}}]},
        #{role => tool, tool_call_id => <<"c9">>, content => <<"done">>}
    ],
    Result = alLlmClient:convertMessagesForAnthropic(Msgs),
    ?assertEqual(2, length(Result)),
    [_Assistant, ToolUser] = Result,
    [ToolResult] = [B || B <- maps:get(<<"content">>, ToolUser),
                         maps:get(<<"type">>, B) =:= <<"tool_result">>],
    ?assertEqual(<<"c9">>, maps:get(<<"tool_use_id">>, ToolResult)),
    ?assertEqual(<<"done">>, maps:get(<<"content">>, ToolResult)).

%% vision：auto 会探测服务端；本机 URL 不再一律当真视觉
supportsVision_local_url_no_probe_test() ->
    Opts = #{vision => auto, visionProbe => false,
             baseUrl => <<"http://127.0.0.1:8080/v1">>},
    ?assertNot(alLlmClient:supportsVision(deepseek, <<"foo.gguf">>, Opts)),
    ?assert(alLlmClient:supportsVision(ornith, <<"E:/llm/Ornith.gguf">>, Opts)).

supportsVision_explicit_test() ->
    ?assert(alLlmClient:supportsVision(deepseek, <<"deepseek-chat">>,
        #{vision => true, baseUrl => <<"https://api.deepseek.com">>})),
    ?assertNot(alLlmClient:supportsVision(openai, <<"gpt-4o">>,
        #{vision => false})).

%% auto + 普通名：不识图；带 vision 关键字或显式配置才开
supportsVision_auto_by_model_name_test() ->
    Ds = #{vision => auto, visionProbe => false,
           baseUrl => <<"https://api.deepseek.com">>},
    ?assertNot(alLlmClient:supportsVision(deepseek, <<"deepseek-chat">>, Ds)),
    ?assertNot(alLlmClient:supportsVision(deepseek, <<"deepseek-v4-flash">>, Ds)),
    ?assert(alLlmClient:supportsVision(deepseek,
        <<"deepseek-v4-flash-vision-exp">>, Ds)),
    Zp = #{vision => auto, visionProbe => false,
           baseUrl => <<"https://open.bigmodel.cn/api/paas/v4">>},
    ?assertNot(alLlmClient:supportsVision(zhipu, <<"GLM-5.3-Flash">>, Zp)),
    ?assertNot(alLlmClient:supportsVision(zhipu, <<"embedding-3">>, Zp)).

supportsVision_anthropic_config_test() ->
    ?assert(alLlmClient:supportsVision(anthropic, <<"claude-3-5-sonnet">>,
        #{vision => true})),
    ?assertNot(alLlmClient:supportsVision(anthropic, <<"claude-3-5-sonnet">>,
        #{vision => false})).

supportsVision_chain_entry_override_test() ->
    ?assertNot(alLlmClient:supportsVision(zhipu, <<"GLM-5.3-Flash">>,
        #{vision => false, baseUrl => <<"https://open.bigmodel.cn/api/paas/v4">>})),
    ?assert(alLlmClient:supportsVision(zhipu, <<"GLM-5.3-Flash">>,
        #{vision => true, baseUrl => <<"https://open.bigmodel.cn/api/paas/v4">>})),
    ?assert(alLlmClient:supportsVision(deepseek, <<"deepseek-chat">>,
        #{vision => true, baseUrl => <<"https://api.deepseek.com">>})),
    ?assert(alLlmClient:supportsVision(deepseek, <<"deepseek-v4-flash">>,
        #{vision => true, baseUrl => <<"https://api.deepseek.com">>})).

parseVisionCaps_llama_props_test() ->
    ?assertEqual({ok, true}, alLlmClient:parseVisionCaps(
        #{<<"modalities">> => #{<<"vision">> => true, <<"audio">> => false}})),
    ?assertEqual({ok, false}, alLlmClient:parseVisionCaps(
        #{<<"modalities">> => #{<<"vision">> => false}})).

parseVisionCaps_models_multimodal_test() ->
    ?assertEqual({ok, true}, alLlmClient:parseVisionCaps(
        #{<<"models">> => [#{<<"capabilities">> => [<<"completion">>, <<"multimodal">>]}]})),
    ?assertEqual(unknown, alLlmClient:parseVisionCaps(
        #{<<"models">> => [#{<<"capabilities">> => [<<"completion">>]}]})).

supportsVision_probe_props_test() ->
    Fun = fun(get, Url, _H, _B, _O) ->
        case binary:match(Url, <<"/props">>) of
            nomatch -> {ok, 404, [], {mockBody, <<"{}">>}};
            _ -> {ok, 200, [], {mockBody, <<"{\"modalities\":{\"vision\":true}}">>}}
        end
    end,
    ?assert(alLlmClient:supportsVision(custom, <<"plain-text-model">>,
        #{vision => auto, baseUrl => <<"http://10.9.8.7:18080/v1">>,
          httpRequestFun => Fun})).
