%%%-------------------------------------------------------------------
%%% @doc LLM 客户端核心模块。
%%%
%%% 封装对 OpenAI、DeepSeek、Anthropic 及自定义兼容 API 的 HTTP 调用，
%%% 提供同步/流式聊天、工具调用补全、会话管理、重试、批量与异步请求，
%%% 以及 Token 用量估算与统计。
%%%
%%% 配置通过 {@link application} 环境（ali 应用）读写，亦可由
%%% {@link alConfig} 从 aliCfg.cfg 加载。
%%% @end
%%%-------------------------------------------------------------------
-module(llmCli).
-export([
    start/0,
    stop/0,
    chat/2,
    chat/3,
    chatStream/2,
    chatStream/3,
    setConfig/2,
    getConfig/1,
    getConfig/2,
    chatWithRetry/3,
    chatWithRetry/4,
    batchChat/2,
    batchChat/3,
    asyncChat/3,
    asyncChat/4,
    loadConfig/0,
    loadConfigFromFile/1,
    createSession/0,
    addToSession/2,
    chatWithSession/2,
    chatWithSession/3,
    clearSession/1,
    estimateTokens/1,
    tokenStats/0,
    resetTokenStats/0,
    formatError/1,
    isSuccess/1,
    isError/1,
    getErrorReason/1,
    createMessage/2,
    systemMessage/1,
    userMessage/1,
    userMessage/2,
    buildUserContent/2,
    estimateContentTokens/1,
    isContentParts/1,
    assistantMessage/1,
    toolMessage/2,
    assistantToolCallsMessage/1,
    chatCompletion/2,
    chatCompletion/3,
    chatStreamTo/4,
    mergeStreamToolCallDelta/2,
    finalizeStreamToolCalls/1,
    embeddings/2,
    embeddings/3,
    defaultEmbeddingModel/0,
    defaultEmbeddingModel/1,
    parseEmbeddingsResponse/2,
    coalesceSystemMessages/1,
    buildRequestBody/5,
    supportsVision/2
]).

-type provider() :: openai | anthropic | deepseek | custom
                  | qwen | kimi | zhipu | ernie | doubao | openrouter | atom().
-type model() :: binary() | string().
-type message() :: #{
    role := system | user | assistant | tool,
    content => binary() | string() | null | [map()],
    tool_call_id => binary() | string(),
    tool_calls => [map()]
}.
-type option() :: {temperature, number()} |
                   {max_tokens, non_neg_integer()} |
                   {top_p, number()} |
                   {stream, boolean()} |
                   {tools, [map()]} |
                   {tool_choice, binary() | atom()}.
-type configKey() :: api_key | base_url | provider.
-type session() :: #{messages => [message()], created_at => integer()}.

%%%===================================================================
%%% 应用生命周期
%%%===================================================================

%% @doc 启动 ali 应用（确保所有依赖已就绪）。
-spec start() -> ok | {error, term()}.
start() ->
    application:ensure_all_started(ali).

%% @doc 停止 ali 应用。
-spec stop() -> ok | {error, term()}.
stop() ->
    application:stop(ali).

%%%===================================================================
%%% 配置管理
%%%===================================================================

%% @doc 写入运行时 LLM 配置覆盖项（优先于 aliCfg.cfg）。
-spec setConfig(configKey(), term()) -> ok.
setConfig(Key, Value) ->
    application:set_env(ali, Key, Value).

%% @doc 读取配置项；未设置时返回 undefined。
-spec getConfig(configKey()) -> {ok, term()} | undefined.
getConfig(Key) ->
    case application:get_env(ali, Key) of
        {ok, Value} -> {ok, Value};
        undefined ->
            case aliCfg:getV(Key) of
                undefined -> undefined;
                V -> {ok, V}
            end
    end.

%% @doc 一次性读取本次请求所需的常用配置（provider/api_key/base_url）。
-spec requestConfig() -> #{provider => provider(), api_key => binary(), base_url => binary()}.
requestConfig() ->
    Resolved = alConfig:resolvedLlm(),
    Provider = override(provider, maps:get(provider, Resolved)),
    ApiKey = toBinary(override(api_key, maps:get(api_key, Resolved))),
    BaseUrl = toBinary(override(base_url, maps:get(base_url, Resolved))),
    #{provider => Provider, api_key => ApiKey, base_url => BaseUrl}.

override(Key, Default) ->
    case application:get_env(ali, Key) of
        {ok, V} -> V;
        undefined -> Default
    end.

%%%===================================================================
%%% 同步聊天
%%%===================================================================

%% @doc 发送聊天请求（默认选项），返回助手回复文本。
-spec chat(model(), [message()]) -> {ok, binary()} | {error, term()}.
chat(Model, Messages) ->
    chat(Model, Messages, []).

%% @doc 发送聊天请求（可指定 temperature、max_tokens、tools 等选项）。
-spec chat(model(), [message()], [option()]) -> {ok, binary()} | {error, term()}.
chat(Model, Messages, Options) ->
    #{provider := Provider, api_key := ApiKey, base_url := BaseUrl} = requestConfig(),
    case ApiKey of
        "" -> {error, missing_api_key};
        <<>> -> {error, missing_api_key};
        _ ->
            RequestBody = buildRequestBody(Model, Messages, Options, false, Provider),
            Url = buildChatUrl(BaseUrl, Provider),
            case makeRequest(post, Url, ApiKey, RequestBody, Provider) of
                {ok, ResponseBody} ->
                    Response = parseChatResponse(ResponseBody, Provider),
                    case Response of
                        {ok, Bin} -> trackTokens(Model, RequestBody, Bin);
                        _ -> ok
                    end,
                    Response;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

%%%===================================================================
%%% 流式聊天
%%%===================================================================

%% @doc 流式聊天（默认选项）；分块通过 `{stream_chunk, Chunk}' 发往调用进程。
-spec chatStream(model(), [message()]) -> ok | {error, term()}.
chatStream(Model, Messages) ->
    chatStream(Model, Messages, []).

%% @doc 流式聊天（带选项）。
-spec chatStream(model(), [message()], [option()]) -> ok | {error, term()}.
chatStream(Model, Messages, Options) ->
    #{provider := Provider, api_key := ApiKey, base_url := BaseUrl} = requestConfig(),
    case ApiKey of
        "" -> {error, missing_api_key};
        <<>> -> {error, missing_api_key};
        _ ->
            RequestBody = buildRequestBody(Model, Messages, Options, true, Provider),
            Url = buildChatUrl(BaseUrl, Provider),
            streamRequest(post, Url, ApiKey, RequestBody, Provider)
    end.

%%%===================================================================
%%% 聊天补全（含 tool_calls）
%%%===================================================================

%% @doc 聊天补全（默认选项）；返回结构化结果（answer 或 tool_calls）。
-spec chatCompletion(model(), [message()]) -> {ok, map()} | {error, term()}.
chatCompletion(Model, Messages) ->
    chatCompletion(Model, Messages, []).

%% @doc 聊天补全（带选项）。
-spec chatCompletion(model(), [message()], [option()]) -> {ok, map()} | {error, term()}.
chatCompletion(Model, Messages, Options) ->
    #{provider := Provider, api_key := ApiKey, base_url := BaseUrl} = requestConfig(),
    case ApiKey of
        "" -> {error, missing_api_key};
        <<>> -> {error, missing_api_key};
        _ ->
            RequestBody = buildRequestBody(Model, Messages, Options, false, Provider),
            Url = buildChatUrl(BaseUrl, Provider),
            case makeRequest(post, Url, ApiKey, RequestBody, Provider) of
                {ok, ResponseBody} ->
                    Parsed = parseCompletion(ResponseBody, Provider),
                    case Parsed of
                        {ok, #{type := answer, content := Content}} ->
                            trackTokens(Model, RequestBody, Content);
                        _ -> ok
                    end,
                    Parsed;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

%% @doc 流式聊天并将分块发往指定进程（而非 self()）。
-spec chatStreamTo(model(), [message()], [option()], pid()) -> ok | {error, term()}.
chatStreamTo(Model, Messages, Options, TargetPid) ->
    #{provider := Provider, api_key := ApiKey, base_url := BaseUrl} = requestConfig(),
    case ApiKey of
        "" -> {error, missing_api_key};
        <<>> -> {error, missing_api_key};
        _ ->
            RequestBody = buildRequestBody(Model, Messages, Options, true, Provider),
            Url = buildChatUrl(BaseUrl, Provider),
            streamRequestTo(post, Url, ApiKey, RequestBody, Provider, TargetPid)
    end.

%%%===================================================================
%%% 向量嵌入（Embeddings）
%%%===================================================================

%% @doc 获取文本（或文本列表）的向量嵌入，使用配置的默认 embedding 模型。
%% 单条文本返回 `{ok, Vector}'，多条文本返回 `{ok, [Vector]}'。
-spec embeddings(binary() | string() | [binary() | string()], map()) ->
    {ok, [number()]} | {ok, [[number()]]} | {error, term()}.
embeddings(Input, Opts) ->
    Model = case maps:get(model, Opts, undefined) of
        undefined -> defaultEmbeddingModel();
        M -> M
    end,
    embeddings(Model, Input, Opts).

%% @doc 获取向量嵌入，指定模型。
%% Anthropic 无独立 embeddings API，返回 `{error, unsupported}'。
-spec embeddings(model(), binary() | string() | [binary() | string()], map()) ->
    {ok, [number()]} | {ok, [[number()]]} | {error, term()}.
embeddings(Model, Input, Opts) ->
    #{provider := Provider, api_key := ApiKey, base_url := BaseUrl} = requestConfig(),
    case {Provider, ApiKey} of
        {anthropic, _} ->
            {error, unsupported};
        {_, ""} ->
            {error, missing_api_key};
        {_, <<>>} ->
            {error, missing_api_key};
        {_, _} ->
            Url = buildEmbeddingsUrl(BaseUrl, Provider),
            Body = buildEmbeddingsBody(Model, Input, Opts, Provider),
            case makeRequest(post, Url, ApiKey, Body, Provider) of
                {ok, ResponseBody} ->
                    parseEmbeddingsResponse(ResponseBody, is_list(Input));
                {error, Reason} ->
                    {error, Reason}
            end
    end.

%% @doc 当前 provider 的默认 embedding 模型。
-spec defaultEmbeddingModel() -> binary().
defaultEmbeddingModel() ->
    Provider = getConfig(provider, openai),
    defaultEmbeddingModel(Provider).

%% @doc 按 provider 返回默认 embedding 模型。
-spec defaultEmbeddingModel(provider()) -> binary().
defaultEmbeddingModel(openai) -> <<"text-embedding-3-small"/utf8>>;
defaultEmbeddingModel(deepseek) -> <<"deepseek-embedding"/utf8>>;
defaultEmbeddingModel(qwen) -> <<"text-embedding-v3"/utf8>>;
defaultEmbeddingModel(zhipu) -> <<"embedding-3"/utf8>>;
defaultEmbeddingModel(ernie) -> <<"embedding-v1"/utf8>>;
defaultEmbeddingModel(doubao) -> <<"doubao-embedding-text-240715"/utf8>>;
defaultEmbeddingModel(openrouter) -> <<"openai/text-embedding-3-small"/utf8>>;
defaultEmbeddingModel(kimi) -> <<"text-embedding-3-small"/utf8>>;
defaultEmbeddingModel(_) -> <<"text-embedding-3-small"/utf8>>.

%% 拼接 embeddings 接口 URL（OpenAI 兼容 provider 均为 /embeddings）。
-spec buildEmbeddingsUrl(binary(), provider()) -> binary().
buildEmbeddingsUrl(BaseUrl, _Provider) ->
    <<(toBinary(BaseUrl))/binary, "/embeddings"/utf8>>.

%% 构建 embeddings 请求体。
buildEmbeddingsBody(Model, Input, Opts, _Provider) when is_list(Input), not is_binary(Input) ->
    Base = #{
        <<"model"/utf8>> => toBinary(Model),
        <<"input"/utf8>> => [toBinary(I) || I <- Input]
    },
    maybeEncodingFormat(Base, Opts);
buildEmbeddingsBody(Model, Input, Opts, _Provider) ->
    Base = #{
        <<"model"/utf8>> => toBinary(Model),
        <<"input"/utf8>> => toBinary(Input)
    },
    maybeEncodingFormat(Base, Opts).

%% 仅在非默认 float 时附加 encoding_format 字段。
maybeEncodingFormat(Base, Opts) ->
    case maps:get(encodingFormat, Opts, <<"float"/utf8>>) of
        <<"float"/utf8>> -> Base;
        F -> Base#{<<"encoding_format"/utf8>> => F}
    end.

%% 解析 embeddings 响应：单条返回向量，多条返回向量列表。
parseEmbeddingsResponse(ResponseBody, IsList) ->
    case ResponseBody of
        #{<<"data"/utf8>> := [#{<<"embedding"/utf8>> := _Vec} | _] = Items} when IsList ->
            {ok, [maps:get(<<"embedding"/utf8>>, I) || I <- Items]};
        #{<<"data"/utf8>> := [#{<<"embedding"/utf8>> := Vec} | _]} ->
            {ok, Vec};
        _ ->
            {error, invalid_response}
    end.

%% @doc 读取配置项；未设置时返回 Default。
-spec getConfig(configKey(), term()) -> term().
getConfig(Key, Default) ->
    case getConfig(Key) of
        {ok, Value} -> Value;
        undefined -> Default
    end.

%%%===================================================================
%%% URL 与请求体构建
%%%===================================================================

%% @doc 按提供商返回默认 API 基础 URL。
-spec defaultUrl(provider()) -> binary().
defaultUrl(openai) ->
    <<"https://api.openai.com/v1"/utf8>>;
defaultUrl(deepseek) ->
    <<"https://api.deepseek.com"/utf8>>;
defaultUrl(anthropic) ->
    <<"https://api.anthropic.com/v1"/utf8>>;
defaultUrl(custom) ->
    <<>>;
defaultUrl(_Provider) ->
    %% 其它 OpenAI 兼容 provider 由配置/预设提供 base_url
    <<>>.

%% @doc 拼接聊天接口完整 URL（Anthropic 使用 /messages，其余为 /chat/completions）。
-spec buildChatUrl(binary(), provider()) -> binary().
buildChatUrl(BaseUrl, Provider) ->
    BinUrl = toBinary(BaseUrl),
    Endpoint = case Provider of
        anthropic -> <<"/messages"/utf8>>;
        _ -> <<"/chat/completions"/utf8>>
    end,
    <<BinUrl/binary, Endpoint/binary>>.

-define(MAX_API_CONTENT_BYTES, 16000).

%% @doc 构建 JSON 请求体（model、messages、stream 及可选参数）。
-spec buildRequestBody(model(), [message()], [option()], boolean(), provider()) -> map().
buildRequestBody(Model, Messages, Options, Stream, anthropic) ->
    buildAnthropicRequestBody(Model, Messages, Options, Stream);
buildRequestBody(Model, Messages, Options, Stream, Provider) ->
    Coalesced = coalesceSystemMessages(Messages),
    Sanitized = sanitizeMessagesForVision(Coalesced, Provider, Model),
    OptionsMap = normalizeRequestOptions(Options),
    Core = #{
        <<"model"/utf8>> => toBinary(Model),
        <<"messages"/utf8>> => [formatMessage(M) || M <- Sanitized],
        <<"stream"/utf8>> => Stream
    },
    maps:merge(OptionsMap, Core).

%% @doc 当前 provider + model 是否支持 image_url / file 等多模态 content parts。
%% 可通过应用配置 `{visionEnabled, true | false}` 强制覆盖。
-spec supportsVision(provider(), model()) -> boolean().
supportsVision(Provider, Model) ->
    case getConfig(visionEnabled, undefined) of
        undefined ->
            supportsVisionDefault(Provider, Model);
        Enabled when is_boolean(Enabled) ->
            Enabled
    end.

supportsVisionDefault(anthropic, _Model) ->
    true;
supportsVisionDefault(deepseek, _Model) ->
    false;
supportsVisionDefault(openai, Model) ->
    openaiVisionModel(Model);
supportsVisionDefault(custom, Model) ->
    openaiVisionModel(Model);
supportsVisionDefault(_Provider, _Model) ->
    false.

openaiVisionModel(Model) ->
    M = string:lowercase(binary_to_list(toBinary(Model))),
    VisionPrefixes = [
        "gpt-4o", "gpt-4.1", "gpt-4-turbo", "gpt-4-vision",
        "chatgpt-4o", "o1", "o3", "o4"
    ],
    lists:any(
        fun(Prefix) ->
            case string:prefix(M, Prefix) of
                nomatch -> false;
                _ -> true
            end
        end,
        VisionPrefixes
    ).

sanitizeMessagesForVision(Messages, Provider, Model) ->
    case supportsVision(Provider, Model) of
        true ->
            Messages;
        false ->
            [downgradeMultimodalMessage(M) || M <- Messages]
    end.

downgradeMultimodalMessage(#{role := user, content := Content} = Msg) when is_list(Content) ->
    case isContentParts(Content) of
        true ->
            Msg#{content := [downgradeMultimodalPart(P) || P <- Content]};
        false ->
            Msg
    end;
downgradeMultimodalMessage(Msg) ->
    Msg.

downgradeMultimodalPart(#{<<"type"/utf8>> := <<"image_url"/utf8>>}) ->
    #{
        <<"type"/utf8>> => <<"text"/utf8>>,
        <<"text"/utf8>> =>
            <<"[用户上传了图片，但当前模型不支持图像识别，无法查看图片内容。"
              "请建议用户切换到支持视觉的模型（如 gpt-4o）。]"/utf8>>
    };
downgradeMultimodalPart(#{<<"type"/utf8>> := <<"file"/utf8>>}) ->
    #{
        <<"type"/utf8>> => <<"text"/utf8>>,
        <<"text"/utf8>> =>
            <<"[用户上传了文档附件，但当前模型不支持此格式，无法读取文档内容。"
              "请建议用户切换到支持多模态的模型（如 gpt-4o）。]"/utf8>>
    };
downgradeMultimodalPart(Part) ->
    Part.

%% Anthropic Messages API 请求体（system 独立字段，tools 格式不同）。
buildAnthropicRequestBody(Model, Messages, Options, Stream) ->
    OptionsMap = maps:from_list(Options),
    MaxTokens = maps:get(max_tokens, OptionsMap, 4096),
    {System, ConvMessages} = splitSystemMessages(Messages),
    AnthropicMsgs = convertMessagesForAnthropic(ConvMessages),
    Base = #{
        <<"model"/utf8>> => toBinary(Model),
        <<"max_tokens"/utf8>> => MaxTokens,
        <<"messages"/utf8>> => AnthropicMsgs,
        <<"stream"/utf8>> => Stream
    },
    Base1 = case System of
        <<>> -> Base;
        S -> maps:put(<<"system"/utf8>>, S, Base)
    end,
    Base2 = mergeAnthropicOptions(Base1, OptionsMap),
    case maps:get(tools, OptionsMap, undefined) of
        undefined ->
            Base2;
        Tools ->
            Base2#{
                <<"tools"/utf8>> => convertOpenAiToolsToAnthropic(Tools),
                <<"tool_choice"/utf8>> => anthropicToolChoice(maps:get(tool_choice, OptionsMap, auto))
            }
    end.

%% 合并 Anthropic 支持的采样参数。
mergeAnthropicOptions(Base, OptionsMap) ->
    maps:fold(fun
        (temperature, V, Acc) when is_number(V) ->
            maps:put(<<"temperature"/utf8>>, V, Acc);
        (top_p, V, Acc) when is_number(V) ->
            maps:put(<<"top_p"/utf8>>, V, Acc);
        (_, _, Acc) ->
            Acc
    end, Base, OptionsMap).

anthropicToolChoice(auto) ->
    #{<<"type"/utf8>> => <<"auto"/utf8>>};
anthropicToolChoice(<<"auto"/utf8>>) ->
    #{<<"type"/utf8>> => <<"auto"/utf8>>};
anthropicToolChoice({tool, Name}) ->
    #{<<"type"/utf8>> => <<"tool"/utf8>>, <<"name"/utf8>> => toBinary(Name)};
anthropicToolChoice(Name) when is_binary(Name); is_list(Name) ->
    #{<<"type"/utf8>> => <<"tool"/utf8>>, <<"name"/utf8>> => toBinary(Name)};
anthropicToolChoice(_) ->
    #{<<"type"/utf8>> => <<"auto"/utf8>>}.

%% 提取 system 消息合并为单个 system 字段。
splitSystemMessages(Messages) ->
    splitSystemMessages(Messages, [], []).

splitSystemMessages([], Systems, Rest) ->
    SystemBin = iolist_to_binary(lists:reverse(Systems)),
    {unicode:characters_to_binary(SystemBin), lists:reverse(Rest)};
splitSystemMessages([#{role := system, content := C} | T], Sys, Rest) ->
    Part = toBinary(C),
    NewSys = case Sys of
        [] -> [Part];
        _ -> [Part, <<"\n\n"/utf8>> | Sys]
    end,
    splitSystemMessages(T, NewSys, Rest);
splitSystemMessages([M | T], Sys, Rest) ->
    splitSystemMessages(T, Sys, [M | Rest]).

%% 将内部消息列表转为 Anthropic messages 格式。
convertMessagesForAnthropic(Messages) ->
    convertMessagesForAnthropic(Messages, []).

convertMessagesForAnthropic([], Acc) ->
    lists:reverse(Acc);
convertMessagesForAnthropic([#{role := tool} | _] = Msgs, Acc) ->
    {Blocks, Rest} = collectAnthropicToolResults(Msgs, []),
    UserMsg = #{<<"role"/utf8>> => <<"user"/utf8>>, <<"content"/utf8>> => Blocks},
    convertMessagesForAnthropic(Rest, [UserMsg | Acc]);
convertMessagesForAnthropic([#{role := assistant, tool_calls := Calls} = Msg | Rest], Acc) ->
    AnthropicMsg = assistantToAnthropic(Msg, Calls),
    convertMessagesForAnthropic(Rest, [AnthropicMsg | Acc]);
convertMessagesForAnthropic([#{role := assistant} = Msg | Rest], Acc) ->
    Content = maps:get(content, Msg, <<>>),
    AnthropicMsg = #{
        <<"role"/utf8>> => <<"assistant"/utf8>>,
        <<"content"/utf8>> => toBinary(Content)
    },
    convertMessagesForAnthropic(Rest, [AnthropicMsg | Acc]);
convertMessagesForAnthropic([#{role := user, content := Content} | Rest], Acc) ->
    Msg = #{
        <<"role"/utf8>> => <<"user"/utf8>>,
        <<"content"/utf8>> => userContentForAnthropic(Content)
    },
    convertMessagesForAnthropic(Rest, [Msg | Acc]);
convertMessagesForAnthropic([_ | Rest], Acc) ->
    convertMessagesForAnthropic(Rest, Acc).

collectAnthropicToolResults([#{role := tool, tool_call_id := Id, content := Content} | Rest], Acc) ->
    Block = #{
        <<"type"/utf8>> => <<"tool_result"/utf8>>,
        <<"tool_use_id"/utf8>> => toBinary(Id),
        <<"content"/utf8>> => toBinary(Content)
    },
    collectAnthropicToolResults(Rest, [Block | Acc]);
collectAnthropicToolResults(Rest, Acc) ->
    {lists:reverse(Acc), Rest}.

assistantToAnthropic(Msg, Calls) ->
    Content = maps:get(content, Msg, null),
    TextParts = case Content of
        null -> [];
        <<>> -> [];
        C -> [#{<<"type"/utf8>> => <<"text"/utf8>>, <<"text"/utf8>> => toBinary(C)}]
    end,
    ToolParts = [openAiCallToAnthropicToolUse(C) || C <- Calls],
    #{
        <<"role"/utf8>> => <<"assistant"/utf8>>,
        <<"content"/utf8>> => TextParts ++ ToolParts
    }.

openAiCallToAnthropicToolUse(#{<<"id"/utf8>> := Id, <<"function"/utf8>> := FunMap}) ->
    Name = maps:get(<<"name"/utf8>>, FunMap, <<>>),
    ArgsBin = maps:get(<<"arguments"/utf8>>, FunMap, <<"{}"/utf8>>),
    Input = try llmJson:decode(ArgsBin) catch _:_ -> #{} end,
    #{
        <<"type"/utf8>> => <<"tool_use"/utf8>>,
        <<"id"/utf8>> => Id,
        <<"name"/utf8>> => Name,
        <<"input"/utf8>> => Input
    }.

convertOpenAiToolsToAnthropic(Tools) when is_list(Tools) ->
    [convertOpenAiToolToAnthropic(T) || T <- Tools].

convertOpenAiToolToAnthropic(#{<<"function"/utf8>> := Fun}) ->
    #{
        <<"name"/utf8>> => maps:get(<<"name"/utf8>>, Fun, <<>>),
        <<"description"/utf8>> => maps:get(<<"description"/utf8>>, Fun, <<>>),
        <<"input_schema"/utf8>> => maps:get(<<"parameters"/utf8>>, Fun, #{<<"type"/utf8>> => <<"object"/utf8>>})
    };
convertOpenAiToolToAnthropic(Other) ->
    Other.

%% 按提供商构建 HTTP 请求头。
buildRequestHeaders(anthropic, ApiKey) ->
    [
        {<<"Content-Type"/utf8>>, <<"application/json"/utf8>>},
        {<<"x-api-key"/utf8>>, toBinary(ApiKey)},
        {<<"anthropic-version"/utf8>>, <<"2023-06-01"/utf8>>}
    ];
buildRequestHeaders(_Provider, ApiKey) ->
    [
        {<<"Content-Type"/utf8>>, <<"application/json"/utf8>>},
        {<<"Authorization"/utf8>>, <<"Bearer ", (toBinary(ApiKey))/binary>>}
    ].

%% @doc 将内部 message 映射转为 API 所需的 JSON 结构。
-spec formatMessage(message()) -> map().
formatMessage(#{role := assistant, tool_calls := Calls} = Msg) ->
    Content = maps:get(content, Msg, null),
    #{
        <<"role"/utf8>> => <<"assistant"/utf8>>,
        <<"content"/utf8>> => capApiContent(formatContent(Content)),
        <<"tool_calls"/utf8>> => sanitizeToolCalls(Calls)
    };
formatMessage(#{role := tool, tool_call_id := Id, content := Content}) ->
    #{
        <<"role"/utf8>> => <<"tool"/utf8>>,
        <<"tool_call_id"/utf8>> => toBinary(Id),
        <<"content"/utf8>> => capApiContent(toBinary(Content))
    };
formatMessage(#{role := Role, content := Content}) ->
    #{
        <<"role"/utf8>> => atomToBinary(Role),
        <<"content"/utf8>> => capApiContent(formatContent(Content))
    }.

sanitizeToolCalls(Calls) when is_list(Calls) ->
    [sanitizeToolCall(C) || C <- Calls];
sanitizeToolCalls(Calls) ->
    Calls.

sanitizeToolCall(#{<<"function"/utf8>> := Fun} = Call) ->
    Args = maps:get(<<"arguments"/utf8>>, Fun, <<>>),
    Fun1 = maps:put(<<"arguments"/utf8>>, capApiContent(toBinary(Args)), Fun),
    maps:put(<<"function"/utf8>>, Fun1, Call);
sanitizeToolCall(Call) ->
    Call.

capApiContent(null) ->
    null;
capApiContent(Bin) when is_binary(Bin) ->
    capBinary(Bin, ?MAX_API_CONTENT_BYTES);
capApiContent(Parts) when is_list(Parts) ->
    case isContentParts(Parts) of
        true ->
            [capContentPart(P) || P <- Parts];
        false ->
            capBinary(toBinary(Parts), ?MAX_API_CONTENT_BYTES)
    end;
capApiContent(Other) ->
    capBinary(toBinary(Other), ?MAX_API_CONTENT_BYTES).

capContentPart(#{<<"type"/utf8>> := <<"text"/utf8>>, <<"text"/utf8>> := Text} = Part) ->
    Part#{<<"text"/utf8>> => capBinary(toBinary(Text), ?MAX_API_CONTENT_BYTES)};
capContentPart(Part) ->
    Part.

capBinary(Bin, Max) when byte_size(Bin) =< Max ->
    Bin;
capBinary(Bin, Max) ->
    Base = binary:part(Bin, 0, Max),
    Safe = llmJson:sanitize_binary(Base),
    <<Safe/binary, <<"\n...[content truncated for API]"/utf8>>/binary>>.

%% 将 content 字段格式化为 API 可接受的值（null 或二进制）。
formatContent(null) -> null;
formatContent(Content) when is_list(Content) ->
    case isContentParts(Content) of
        true -> Content;
        false -> toBinary(Content)
    end;
formatContent(Content) -> toBinary(Content).

%% 将 API 返回的 content 规范化为二进制文本（支持多段 content parts）。
normalizeApiContent(null) -> <<>>;
normalizeApiContent(<<>>) -> <<>>;
normalizeApiContent(Bin) when is_binary(Bin) -> Bin;
normalizeApiContent(List) when is_list(List) ->
    case isContentParts(List) of
        true -> extractTextParts(List);
        false ->
            try
                unicode:characters_to_binary(List)
            catch
                _:_ -> unicode:characters_to_binary(io_lib:format("~p", [List]))
            end
    end;
normalizeApiContent(Other) ->
    unicode:characters_to_binary(io_lib:format("~p", [Other])).

%% 判断 content 是否为 OpenAI 多段 parts 格式。
isContentParts([#{<<"type"/utf8>> := _} | _]) -> true;
isContentParts([#{type := _} | _]) -> true;
isContentParts(_) -> false.

%% 从 content parts 列表中提取并拼接文本段。
extractTextParts(Parts) ->
    Texts = [
        toBinary(Text) ||
        P <- Parts,
        Text <- [contentPartText(P)],
        Text =/= null, Text =/= <<>>
    ],
    iolist_to_binary(Texts).

%% 从单个 content part 中提取 text 字段。
contentPartText(#{<<"type"/utf8>> := <<"text"/utf8>>, <<"text"/utf8>> := Text}) -> Text;
contentPartText(#{type := text, text := Text}) -> Text;
contentPartText(#{<<"text"/utf8>> := Text}) -> Text;
contentPartText(_) -> <<>>.

%%%===================================================================
%%% HTTP 请求（同步与流式）
%%%===================================================================

-define(HTTP_CONNECT_TIMEOUT, 30000).
-define(HTTP_RECV_TIMEOUT, 600000).
-define(STREAM_IDLE_TIMEOUT, 600000).

httpOpts() ->
    [{recv_timeout, ?HTTP_RECV_TIMEOUT}, {connect_timeout, ?HTTP_CONNECT_TIMEOUT}].

%% @doc 发送同步 POST 请求并解析 JSON 响应体。
-spec makeRequest(atom(), binary(), binary() | string(), map(), provider()) ->
    {ok, map()} | {error, term()}.
makeRequest(Method, Url, ApiKey, Body, Provider) ->
    Headers = buildRequestHeaders(Provider, ApiKey),
    case encodeRequestBody(Body) of
        {error, Reason} ->
            {error, Reason};
        {ok, JsonBody} ->
            case hackney:request(Method, Url, Headers, JsonBody, httpOpts()) of
                {ok, 200, _, ResponseBody} ->
                    try
                        {ok, llmJson:decode(ResponseBody)}
                    catch
                        _:_ ->
                            {error, invalidJson}
                    end;
                {ok, StatusCode, _, ErrorBody} ->
                    {error, {http_error, StatusCode, decodeErrorBody(ErrorBody)}};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

encodeRequestBody(Body) ->
    llmJson:encodeStrict(Body).

%% @doc 流式请求入口；分块发往 self()。
-spec streamRequest(atom(), binary(), binary() | string(), map(), provider()) -> ok | {error, term()}.
streamRequest(Method, Url, ApiKey, Body, Provider) ->
    streamRequestTo(Method, Url, ApiKey, Body, Provider, self()).

%% 流式请求核心：hackney 异步模式，将响应块转发至 TargetPid。
-spec streamRequestTo(atom(), binary(), binary() | string(), map(), provider(), pid()) ->
    ok | {error, term()}.
streamRequestTo(Method, Url, ApiKey, Body, Provider, TargetPid) ->
    Headers = buildRequestHeaders(Provider, ApiKey),
    case encodeRequestBody(Body) of
        {error, Reason} ->
            {error, Reason};
        {ok, JsonBody} ->
            case hackney:request(Method, Url, Headers, JsonBody,
                                 [{protocols, [http1]}, {async, once}, {stream_to, TargetPid} | httpOpts()]) of
                {ok, ClientRef} ->
                    streamLoopTo(ClientRef, Provider, TargetPid);
                {error, Reason} ->
                    {error, Reason}
            end
    end.

%% 流式响应接收循环：解析 SSE 数据块并转发，含超时保护。
streamLoopTo(ClientRef, Provider, TargetPid) ->
    receive
        {hackney_response, ClientRef, {error, Reason}} ->
            quiet_close(ClientRef),
            TargetPid ! {al, streamError, Reason},
            {error, Reason};
        {hackney_response, ClientRef, {status, StatusCode, _}} when StatusCode >= 400 ->
            hackney:stream_next(ClientRef),
            streamErrorBodyTo(ClientRef, TargetPid, StatusCode, <<>>);
        {hackney_response, ClientRef, {status, _StatusCode, _Reason}} ->
            hackney:stream_next(ClientRef),
            streamLoopTo(ClientRef, Provider, TargetPid);
        {hackney_response, ClientRef, {headers, _Headers}} ->
            hackney:stream_next(ClientRef),
            streamLoopTo(ClientRef, Provider, TargetPid);
        {hackney_response, ClientRef, done} ->
            quiet_close(ClientRef),
            sendStreamDone(TargetPid),
            ok;
        {hackney_response, ClientRef, <<>>} ->
            quiet_close(ClientRef),
            sendStreamDone(TargetPid),
            ok;
        {hackney_response, ClientRef, Data} ->
            case parseStreamChunkEvents(Data, Provider) of
                {ok, Events} ->
                    lists:foreach(fun(Ev) -> dispatchStreamEvent(TargetPid, Ev) end, Events),
                    hackney:stream_next(ClientRef),
                    streamLoopTo(ClientRef, Provider, TargetPid);
                {done, Events} ->
                    lists:foreach(fun(Ev) -> dispatchStreamEvent(TargetPid, Ev) end, Events),
                    quiet_close(ClientRef),
                    sendStreamDone(TargetPid),
                    ok;
                ignore ->
                    hackney:stream_next(ClientRef),
                    streamLoopTo(ClientRef, Provider, TargetPid)
            end
    after ?STREAM_IDLE_TIMEOUT ->
        %% 流式响应超时：连接 stall，通知调用方并清理
        quiet_close(ClientRef),
        TargetPid ! {al, streamError, stream_timeout},
        TargetPid ! {al, streamDone, done},
        {error, stream_timeout}
    end.

streamErrorBodyTo(ClientRef, TargetPid, StatusCode, Acc) ->
    receive
        {hackney_response, ClientRef, done} ->
            quiet_close(ClientRef),
            Err = {http_error, StatusCode, decodeErrorBody(Acc)},
            TargetPid ! {al, streamError, Err},
            {error, Err};
        {hackney_response, ClientRef, <<>>} ->
            quiet_close(ClientRef),
            Err = {http_error, StatusCode, decodeErrorBody(Acc)},
            TargetPid ! {al, streamError, Err},
            {error, Err};
        {hackney_response, ClientRef, Data} when is_binary(Data) ->
            hackney:stream_next(ClientRef),
            streamErrorBodyTo(ClientRef, TargetPid, StatusCode, <<Acc/binary, Data/binary>>);
        {hackney_response, ClientRef, {error, Reason}} ->
            quiet_close(ClientRef),
            Err = {http_error, StatusCode, decodeErrorBody(Acc)},
            TargetPid ! {al, streamError, Err},
            {error, Reason}
    after ?STREAM_IDLE_TIMEOUT ->
        quiet_close(ClientRef),
        Err = {http_error, StatusCode, decodeErrorBody(Acc)},
        TargetPid ! {al, streamError, Err},
        {error, Err}
    end.

decodeErrorBody(<<>>) ->
    #{};
decodeErrorBody(Bin) ->
    try llmJson:decode(Bin) catch _:_ -> #{<<"raw"/utf8>> => Bin} end.

%% 合并开头连续的 system 消息（多数 OpenAI 兼容 API 只接受一条）。
-spec coalesceSystemMessages([message()]) -> [message()].
coalesceSystemMessages(Messages) ->
    case takeLeadingSystems(Messages, []) of
        {[], Rest} ->
            Rest;
        {Systems, Rest} ->
            [mergeSystemMessages(Systems) | Rest]
    end.

takeLeadingSystems([#{role := system} = M | T], Acc) ->
    takeLeadingSystems(T, [M | Acc]);
takeLeadingSystems(Rest, Acc) ->
    {lists:reverse(Acc), Rest}.

mergeSystemMessages(Systems) ->
    Parts = [systemMessageText(M) || M <- Systems],
    NonEmpty = [P || P <- Parts, P =/= <<>>],
    Content = case NonEmpty of
        [] -> <<>>;
        _ -> iolist_to_binary(lists:join(<<"\n\n"/utf8>>, NonEmpty))
    end,
    #{role => system, content => Content}.

systemMessageText(#{content := Content}) ->
    toBinary(Content);
systemMessageText(_) ->
    <<>>.

normalizeRequestOptions(Options) when is_map(Options) ->
    maps:fold(fun(K, V, Acc) ->
        maps:put(normalizeOptionKey(K), V, Acc)
    end, #{}, Options);
normalizeRequestOptions(Options) when is_list(Options) ->
    normalizeRequestOptions(maps:from_list(Options)).

normalizeOptionKey(K) when is_binary(K) -> K;
normalizeOptionKey(tools) -> <<"tools"/utf8>>;
normalizeOptionKey(tool_choice) -> <<"tool_choice"/utf8>>;
normalizeOptionKey(temperature) -> <<"temperature"/utf8>>;
normalizeOptionKey(max_tokens) -> <<"max_tokens"/utf8>>;
normalizeOptionKey(top_p) -> <<"top_p"/utf8>>;
normalizeOptionKey(K) when is_atom(K) -> atom_to_binary(K, utf8);
normalizeOptionKey(K) -> toBinary(K).

%% 向目标进程发送流式文本块（兼容两种消息格式）。
sendStreamChunk(Pid, Chunk) ->
    Pid ! {stream_chunk, Chunk},
    Pid ! {al, stream, Chunk}.

sendStreamToolDelta(Pid, Delta) when is_list(Delta) ->
    Pid ! {stream_tool_delta, Delta}.

dispatchStreamEvent(Pid, {text, Chunk}) ->
    sendStreamChunk(Pid, Chunk);
dispatchStreamEvent(Pid, {tool_delta, Delta}) ->
    sendStreamToolDelta(Pid, Delta);
dispatchStreamEvent(_Pid, done) ->
    ok.

%% 静默关闭 hackney 连接（清理路径，失败忽略）。
quiet_close(Ref) ->
    try hackney:close(Ref) catch _:_ -> ok end.

%% 通知目标进程流式传输结束。
sendStreamDone(Pid) ->
    Pid ! {stream_chunk, done},
    Pid ! {al, streamDone, done}.

%%%===================================================================
%%% 流式响应解析
%%%===================================================================

%% @doc 解析 SSE 数据块为事件列表（文本增量、tool delta、[DONE]）。
-spec parseStreamChunkEvents(binary(), provider()) ->
    {ok, [term()]} | {done, [term()]} | ignore.
parseStreamChunkEvents(Data, Provider) when is_binary(Data) ->
    Lines = binary:split(Data, <<"\n"/utf8>>, [global, trim_all]),
    parseStreamEventLines(Lines, Provider, []).

parseStreamEventLines([], _Provider, Events) ->
    case Events of
        [] -> ignore;
        _ -> {ok, lists:reverse(Events)}
    end;
parseStreamEventLines([Line | Rest], Provider, Events) ->
    Trimmed = binary:replace(Line, <<"\r"/utf8>>, <<>>, [global]),
    case Trimmed of
        <<"data: [DONE]"/utf8>> ->
            {done, lists:reverse(Events)};
        <<"data: ", JsonData/binary>> ->
            case parseStreamJsonEvents(JsonData, Provider) of
                ignore ->
                    parseStreamEventLines(Rest, Provider, Events);
                NewEvents ->
                    parseStreamEventLines(Rest, Provider, NewEvents ++ Events)
            end;
        _ ->
            parseStreamEventLines(Rest, Provider, Events)
    end.

parseStreamJsonEvents(JsonData, Provider) ->
    try
        Decoded = llmJson:decode(JsonData),
        extractStreamEvents(Decoded, Provider)
    catch
        _:_ -> ignore
    end.

extractStreamEvents(Decoded, Provider) ->
    case extractStreamContent(Decoded, Provider) of
        {ok, Content} ->
            [{text, Content}];
        {tool_delta, Delta} ->
            [{tool_delta, Delta}];
        ignore ->
            case extractStreamToolDelta(Decoded, Provider) of
                {tool_delta, Delta} -> [{tool_delta, Delta}];
                ignore -> ignore
            end
    end.

extractStreamToolDelta(#{<<"choices"/utf8>> := [#{<<"delta"/utf8>> := Delta}]}, Provider)
        when Provider =/= anthropic ->
    case maps:get(<<"tool_calls"/utf8>>, Delta, undefined) of
        Calls when is_list(Calls), Calls =/= [] -> {tool_delta, Calls};
        _ -> ignore
    end;
extractStreamToolDelta(_, _) ->
    ignore.

%% @doc 合并流式 tool_call delta（按 index 累积）。
-spec mergeStreamToolCallDelta(map(), [map()]) -> map().
mergeStreamToolCallDelta(Acc, Deltas) ->
    lists:foldl(fun mergeOneToolDelta/2, Acc, Deltas).

mergeOneToolDelta(#{<<"index"/utf8>> := Idx} = Delta, Acc) ->
    Existing = maps:get(Idx, Acc, #{}),
    Merged = mergeToolCallFields(Existing, Delta),
    Acc#{Idx => Merged};
mergeOneToolDelta(_Delta, Acc) ->
    Acc.

mergeToolCallFields(Existing, Delta) ->
    maps:fold(fun(K, V, Acc) ->
        case maps:get(K, Acc, undefined) of
            undefined ->
                Acc#{K => V};
            Old when K =:= <<"function"/utf8>> ->
                Acc#{K => mergeFunctionField(Old, V)};
            Old when is_binary(Old), is_binary(V) ->
                Acc#{K => <<Old/binary, V/binary>>};
            _ ->
                Acc#{K => V}
        end
    end, Existing, Delta).

mergeFunctionField(Old, New) when is_map(Old), is_map(New) ->
    maps:fold(fun(K, V, Acc) ->
        case maps:get(K, Acc, undefined) of
            undefined -> Acc#{K => V};
            Bin when is_binary(Bin), is_binary(V) -> Acc#{K => <<Bin/binary, V/binary>>};
            _ -> Acc#{K => V}
        end
    end, Old, New);
mergeFunctionField(_Old, New) ->
    New.

%% @doc 将累积的 tool_call map 转为 API 格式的列表。
-spec finalizeStreamToolCalls(map()) -> [map()].
finalizeStreamToolCalls(Acc) when map_size(Acc) =:= 0 ->
    [];
finalizeStreamToolCalls(Acc) ->
    Orded = lists:sort(fun({I, _}, {J, _}) -> I =< J end, maps:to_list(Acc)),
    [Call || {_Idx, Call} <- Orded].

%% @doc 从流式 JSON 的 delta 字段提取文本增量。
-spec extractStreamContent(map(), provider()) -> {ok, binary()} | {tool_delta, [map()]} | ignore.
extractStreamContent(#{<<"choices"/utf8>> := [#{<<"delta"/utf8>> := Delta}]}, Provider)
        when Provider =/= anthropic ->
    case maps:get(<<"tool_calls"/utf8>>, Delta, undefined) of
        Calls when is_list(Calls), Calls =/= [] ->
            {tool_delta, Calls};
        _ ->
            case maps:get(<<"content"/utf8>>, Delta, undefined) of
                Content when is_binary(Content), Content =/= <<>> -> {ok, Content};
                _ -> ignore
            end
    end;
extractStreamContent(#{<<"delta"/utf8>> := Delta}, anthropic) ->
    case maps:get(<<"text"/utf8>>, Delta, undefined) of
        undefined -> ignore;
        Content -> {ok, Content}
    end;
extractStreamContent(_, _) ->
    ignore.

%%%===================================================================
%%% 响应解析
%%%===================================================================

%% @doc 解析非流式聊天响应，提取助手回复文本。
-spec parseChatResponse(map(), provider()) -> {ok, binary()} | {error, term()}.
parseChatResponse(Response, Provider)
        when Provider =/= anthropic ->
    case Response of
        #{<<"choices"/utf8>> := [#{<<"message"/utf8>> := Message} | _]} ->
            {ok, normalizeApiContent(maps:get(<<"content"/utf8>>, Message, <<>>))};
        #{<<"error"/utf8>> := Error} ->
            {error, Error};
        _ ->
            {error, invalid_response}
    end;
parseChatResponse(Response, anthropic) ->
    case Response of
        #{<<"content"/utf8>> := Blocks} when is_list(Blocks) ->
            {Texts, _} = splitAnthropicBlocks(Blocks),
            {ok, iolist_to_binary(Texts)};
        #{<<"error"/utf8>> := Error} ->
            {error, Error};
        _ ->
            {error, invalid_response}
    end.

%% 解析补全响应：区分普通回答与 tool_calls。
-spec parseCompletion(map(), provider()) -> {ok, map()} | {error, term()}.
parseCompletion(Response, Provider)
        when Provider =/= anthropic ->
    case Response of
        #{<<"choices"/utf8>> := [#{<<"message"/utf8>> := Message} | _]} ->
            case maps:get(<<"tool_calls"/utf8>>, Message, undefined) of
                Calls when is_list(Calls), Calls =/= [] ->
                    {ok, #{
                        type => tool_calls,
                        tool_calls => Calls,
                        message => Message,
                        content => maps:get(<<"content"/utf8>>, Message, null)
                    }};
                _ ->
                    {ok, #{
                        type => answer,
                        content => normalizeApiContent(maps:get(<<"content"/utf8>>, Message, <<>>))
                    }}
            end;
        #{<<"error"/utf8>> := Error} ->
            {error, Error};
        _ ->
            {error, invalid_response}
    end;
parseCompletion(Response, anthropic) ->
    case Response of
        #{<<"content"/utf8>> := Blocks} when is_list(Blocks) ->
            {TextParts, ToolUses} = splitAnthropicBlocks(Blocks),
            case ToolUses of
                [] ->
                    {ok, #{
                        type => answer,
                        content => iolist_to_binary(TextParts)
                    }};
                Uses ->
                    Calls = [anthropicToolUseToOpenAiCall(U) || U <- Uses],
                    ApiMsg = anthropicBlocksToAssistantMessage(Blocks),
                    {ok, #{
                        type => tool_calls,
                        tool_calls => Calls,
                        message => ApiMsg,
                        content => null
                    }}
            end;
        #{<<"error"/utf8>> := Error} ->
            {error, Error};
        _ ->
            {error, invalid_response}
    end.

%% 拆分 Anthropic content blocks 为文本与 tool_use 列表。
splitAnthropicBlocks(Blocks) ->
    lists:foldl(fun(Block, {Texts, Tools}) ->
        case Block of
            #{<<"type"/utf8>> := <<"text"/utf8>>, <<"text"/utf8>> := Text} ->
                {Texts ++ [Text], Tools};
            #{<<"type"/utf8>> := <<"tool_use"/utf8>>} = Use ->
                {Texts, Tools ++ [Use]};
            _ ->
                {Texts, Tools}
        end
    end, {[], []}, Blocks).

%% Anthropic tool_use 转为 OpenAI 风格 tool_call（供 alLoop 使用）。
anthropicToolUseToOpenAiCall(#{<<"id"/utf8>> := Id, <<"name"/utf8>> := Name, <<"input"/utf8>> := Input}) ->
    #{
        <<"id"/utf8>> => Id,
        <<"type"/utf8>> => <<"function"/utf8>>,
        <<"function"/utf8>> => #{
            <<"name"/utf8>> => Name,
            <<"arguments"/utf8>> => llmJson:encode(Input)
        }
    }.

%% Anthropic blocks 转为 OpenAI assistant message（含 tool_calls）。
anthropicBlocksToAssistantMessage(Blocks) ->
    {Texts, ToolUses} = splitAnthropicBlocks(Blocks),
    Calls = [anthropicToolUseToOpenAiCall(U) || U <- ToolUses],
    Content = case Texts of
        [] -> null;
        _ -> iolist_to_binary(Texts)
    end,
    case Calls of
        [] ->
            #{<<"role"/utf8>> => <<"assistant"/utf8>>, <<"content"/utf8>> => Content};
        _ ->
            #{
                <<"role"/utf8>> => <<"assistant"/utf8>>,
                <<"content"/utf8>> => Content,
                <<"tool_calls"/utf8>> => Calls
            }
    end.

%%%===================================================================
%%% 类型转换工具
%%%===================================================================

%% @doc 将多种 Erlang 类型统一转为 binary。
-spec toBinary(binary() | string() | atom() | integer() | float()) -> binary().
toBinary(B) when is_binary(B) -> B;
toBinary(L) when is_list(L) -> listToBinary(L);
toBinary(A) when is_atom(A) -> atomToBinary(A);
toBinary(I) when is_integer(I) -> integerToBinary(I);
toBinary(F) when is_float(F) -> floatToBinary(F, [{decimals, 10}]).

%% 字符串列表转 UTF-8 二进制。
-spec listToBinary(string()) -> binary().
listToBinary(L) -> unicode:characters_to_binary(L).

%% 原子转二进制。
-spec atomToBinary(atom()) -> binary().
atomToBinary(A) -> atom_to_binary(A, utf8).

%% 整数转二进制。
-spec integerToBinary(integer()) -> binary().
integerToBinary(I) -> integer_to_binary(I).

%% 浮点数转二进制。
-spec floatToBinary(float(), list()) -> binary().
floatToBinary(F, Opts) -> float_to_binary(F, Opts).

%%%===================================================================
%%% 消息构造辅助
%%%===================================================================

%% @doc 创建指定角色的聊天消息。
-spec createMessage(atom(), binary() | string() | [map()]) -> message().
createMessage(Role, Content) when is_list(Content) ->
    case isContentParts(Content) of
        true ->
            #{role => Role, content => Content};
        false ->
            #{role => Role, content => listToBinary(Content)}
    end;
createMessage(Role, Content) ->
    #{role => Role, content => Content}.

%% @doc 创建 system 角色消息。
-spec systemMessage(binary() | string()) -> message().
systemMessage(Content) ->
    createMessage(system, Content).

%% @doc 创建 user 角色消息（纯文本）。
-spec userMessage(binary() | string()) -> message().
userMessage(Content) ->
    createMessage(user, Content).

%% @doc 创建 user 角色消息（可含图片与文本文件附件）。
%% Attachments 为 `#{images => [...], files => [...]}`。
-spec userMessage(binary() | string(), map()) -> message().
userMessage(Content, Attachments) when is_map(Attachments) ->
    createMessage(user, buildUserContent(Content, Attachments)).

%% @doc 构建 user 消息的 content（binary 或 OpenAI content parts 列表）。
-spec buildUserContent(binary(), map()) -> binary() | [map()].
buildUserContent(Prompt, Attachments) when is_map(Attachments) ->
    Images = maps:get(images, Attachments, []),
    Files = maps:get(files, Attachments, []),
    Documents = maps:get(documents, Attachments, []),
    case Images =:= [] andalso Files =:= [] andalso Documents =:= [] of
        true ->
            Prompt;
        false ->
            buildUserContentParts(Prompt, Images, Files, Documents)
    end.

buildUserContentParts(Prompt, Images, Files, Documents) ->
    TextParts = case Prompt of
        <<>> -> [];
        _ -> [#{<<"type"/utf8>> => <<"text"/utf8>>, <<"text"/utf8>> => Prompt}]
    end,
    FileParts = [fileAttachmentPart(F) || F <- Files],
    DocParts = [documentAttachmentPart(D) || D <- Documents],
    ImageParts = [imageAttachmentPart(I) || I <- Images],
    TextParts ++ FileParts ++ DocParts ++ ImageParts.

fileAttachmentPart(#{<<"name"/utf8>> := Name, <<"data"/utf8>> := Data}) ->
    Header = iolist_to_binary([<<"[附件: "/utf8>>, Name, <<"]\n```\n"/utf8>>]),
    Footer = <<"\n```"/utf8>>,
    #{
        <<"type"/utf8>> => <<"text"/utf8>>,
        <<"text"/utf8>> => <<Header/binary, Data/binary, Footer/binary>>
    };
fileAttachmentPart(#{name := Name, data := Data}) ->
    fileAttachmentPart(#{
        <<"name"/utf8>> => toBinary(Name),
        <<"data"/utf8>> => toBinary(Data)
    }).

documentAttachmentPart(#{<<"name"/utf8>> := Name, <<"mediaType"/utf8>> := MT, <<"data"/utf8>> := Data}) ->
    B64 = stripBase64Data(Data),
    FileData = iolist_to_binary([<<"data:"/utf8>>, MT, <<";base64,"/utf8>>, B64]),
    #{
        <<"type"/utf8>> => <<"file"/utf8>>,
        <<"file"/utf8>> => #{
            <<"filename"/utf8>> => Name,
            <<"file_data"/utf8>> => FileData
        }
    };
documentAttachmentPart(#{name := Name, mediaType := MT, data := Data}) ->
    documentAttachmentPart(#{
        <<"name"/utf8>> => toBinary(Name),
        <<"mediaType"/utf8>> => toBinary(MT),
        <<"data"/utf8>> => toBinary(Data)
    }).

imageAttachmentPart(#{<<"mediaType"/utf8>> := MT, <<"data"/utf8>> := Data}) ->
    B64 = stripBase64Data(Data),
    Url = iolist_to_binary([<<"data:"/utf8>>, MT, <<";base64,"/utf8>>, B64]),
    #{
        <<"type"/utf8>> => <<"image_url"/utf8>>,
        <<"image_url"/utf8>> => #{
            <<"url"/utf8>> => Url,
            <<"detail"/utf8>> => <<"auto"/utf8>>
        }
    };
imageAttachmentPart(#{mediaType := MT, data := Data}) ->
    imageAttachmentPart(#{
        <<"mediaType"/utf8>> => toBinary(MT),
        <<"data"/utf8>> => toBinary(Data)
    }).

stripBase64Data(Bin) when is_binary(Bin) ->
    case binary:split(Bin, <<";base64,">>) of
        [_Prefix, Data] -> Data;
        _ -> Bin
    end;
stripBase64Data(Bin) when is_list(Bin) ->
    stripBase64Data(list_to_binary(Bin));
stripBase64Data(_) ->
    <<>>.

userContentForAnthropic(Bin) when is_binary(Bin) ->
    Bin;
userContentForAnthropic(Parts) when is_list(Parts) ->
    case isContentParts(Parts) of
        true -> [convertUserPartForAnthropic(P) || P <- Parts];
        false -> toBinary(Parts)
    end;
userContentForAnthropic(Other) ->
    toBinary(Other).

convertUserPartForAnthropic(#{<<"type"/utf8>> := <<"text"/utf8>>, <<"text"/utf8>> := Text}) ->
    #{<<"type"/utf8>> => <<"text"/utf8>>, <<"text"/utf8>> => Text};
convertUserPartForAnthropic(#{<<"type"/utf8>> := <<"file"/utf8>>, <<"file"/utf8>> := File}) ->
    Filename = maps:get(<<"filename"/utf8>>, File, <<"file"/utf8>>),
    FileData = maps:get(<<"file_data"/utf8>>, File, <<>>),
    case parseDataUrl(FileData) of
        {ok, MT, B64} ->
            #{
                <<"type"/utf8>> => <<"document"/utf8>>,
                <<"source"/utf8>> => #{
                    <<"type"/utf8>> => <<"base64"/utf8>>,
                    <<"media_type"/utf8>> => MT,
                    <<"data"/utf8>> => B64
                }
            };
        error ->
            #{
                <<"type"/utf8>> => <<"text"/utf8>>,
                <<"text"/utf8>> => iolist_to_binary([<<"[附件: "/utf8>>, Filename, <<"]"/utf8>>])
            }
    end;
convertUserPartForAnthropic(#{<<"type"/utf8>> := <<"image_url"/utf8>>, <<"image_url"/utf8>> := Img}) ->
    Url = maps:get(<<"url"/utf8>>, Img, <<>>),
    case parseDataUrl(Url) of
        {ok, MT, B64} ->
            #{
                <<"type"/utf8>> => <<"image"/utf8>>,
                <<"source"/utf8>> => #{
                    <<"type"/utf8>> => <<"base64"/utf8>>,
                    <<"media_type"/utf8>> => MT,
                    <<"data"/utf8>> => B64
                }
            };
        error ->
            #{<<"type"/utf8>> => <<"text"/utf8>>, <<"text"/utf8>> => Url}
    end;
convertUserPartForAnthropic(Part) ->
    #{<<"type"/utf8>> => <<"text"/utf8>>, <<"text"/utf8>> => toBinary(Part)}.

parseDataUrl(<<"data:", Rest/binary>>) ->
    case binary:split(Rest, <<";base64,">>) of
        [MT, Data] -> {ok, MT, Data};
        _ -> error
    end;
parseDataUrl(_) ->
    error.

%% @doc 估算 message content 的 token 数（含多模态 parts）。
-spec estimateContentTokens(term()) -> non_neg_integer().
estimateContentTokens(Content) when is_binary(Content) ->
    estimateTokens(Content);
estimateContentTokens(Parts) when is_list(Parts) ->
    case isContentParts(Parts) of
        true ->
            lists:sum([partTokenEstimate(P) || P <- Parts]);
        false ->
            estimateTokens(toBinary(Parts))
    end;
estimateContentTokens(null) ->
    0;
estimateContentTokens(Other) ->
    estimateTokens(toBinary(Other)).

partTokenEstimate(#{<<"type"/utf8>> := <<"image_url"/utf8>>}) ->
    765;
partTokenEstimate(#{<<"type"/utf8>> := <<"file"/utf8>>}) ->
    2000;
partTokenEstimate(#{<<"type"/utf8>> := <<"text"/utf8>>, <<"text"/utf8>> := Text}) ->
    estimateTokens(Text);
partTokenEstimate(_) ->
    1.

%% @doc 创建 assistant 角色消息。
-spec assistantMessage(binary() | string()) -> message().
assistantMessage(Content) ->
    createMessage(assistant, Content).

%% @doc 创建 tool 角色消息（工具执行结果回传）。
-spec toolMessage(binary() | string(), binary() | string()) -> message().
toolMessage(ToolCallId, Content) ->
    #{
        role => tool,
        tool_call_id => toBinary(ToolCallId),
        content => toBinary(Content)
    }.

%% @doc 创建含 tool_calls 的 assistant 消息（无文本内容）。
-spec assistantToolCallsMessage([map()]) -> message().
assistantToolCallsMessage(ToolCalls) ->
    #{
        role => assistant,
        content => null,
        tool_calls => ToolCalls
    }.

%%%===================================================================
%%% 重试、批量与异步
%%%===================================================================

%% @doc 带指数退避重试的聊天（默认选项）；遇 429/5xx 自动重试。
-spec chatWithRetry(model(), [message()], non_neg_integer()) -> {ok, binary()} | {error, term()}.
chatWithRetry(Model, Messages, MaxRetries) ->
    chatWithRetry(Model, Messages, MaxRetries, []).

%% @doc 带重试的聊天（可指定选项）。
-spec chatWithRetry(model(), [message()], non_neg_integer(), [option()]) -> {ok, binary()} | {error, term()}.
chatWithRetry(_Model, _Messages, MaxRetries, _Options) when MaxRetries < 0 ->
    {error, max_retries_exceeded};
chatWithRetry(Model, Messages, MaxRetries, Options) ->
    chatWithRetry(Model, Messages, MaxRetries, Options, 0).

%% 重试内部实现：MaxRetries 为剩余次数，Attempt 用于退避计算。
chatWithRetry(Model, Messages, 0, Options, _Attempt) ->
    chat(Model, Messages, Options);
chatWithRetry(_Model, _Messages, MaxRetries, _Options, _Attempt) when MaxRetries < 0 ->
    {error, max_retries_exceeded};
chatWithRetry(Model, Messages, MaxRetries, Options, Attempt) ->
    case chat(Model, Messages, Options) of
        {ok, Response} ->
            {ok, Response};
        {error, {http_error, Code, _}} when Code == 429; Code >= 500, Code =< 599 ->
            %% 指数退避 + jitter: 1s * 2^attempt，上限 60s
            BaseMs = min(1000 * trunc(math:pow(2, Attempt)), 60000),
            JitterMs = rand:uniform(trunc(BaseMs * 0.3)),
            SleepMs = BaseMs + JitterMs,
            timer:sleep(SleepMs),
            chatWithRetry(Model, Messages, MaxRetries - 1, Options, Attempt + 1);
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc 对多组消息依次发起聊天请求（默认选项）。
-spec batchChat(model(), [[message()]]) -> [{ok, binary()} | {error, term()}].
batchChat(Model, MessageList) ->
    batchChat(Model, MessageList, []).

%% @doc 批量聊天（可指定选项）。
-spec batchChat(model(), [[message()]], [option()]) -> [{ok, binary()} | {error, term()}].
batchChat(Model, MessageList, Options) ->
    lists:map(fun(Messages) ->
        case chat(Model, Messages, Options) of
            {ok, Response} -> {ok, Response};
            {error, Reason} -> {error, Reason}
        end
    end, MessageList).

%% @doc 异步聊天；完成后向 CallbackPid 发送 `{chat_result, Result}'。
-spec asyncChat(model(), [message()], pid()) -> pid().
asyncChat(Model, Messages, CallbackPid) ->
    asyncChat(Model, Messages, [], CallbackPid).

%% @doc 异步聊天（可指定选项）；返回工作进程 pid。
-spec asyncChat(model(), [message()], [option()], pid()) -> pid().
asyncChat(Model, Messages, Options, CallbackPid) ->
    spawn(fun() ->
        Result = chat(Model, Messages, Options),
        CallbackPid ! {chat_result, Result}
    end).

%%%===================================================================
%%% 配置加载
%%%===================================================================

%% @doc 从默认路径加载 aliCfg.cfg。
-spec loadConfig() -> ok | {error, term()}.
loadConfig() ->
    alConfig:load().

%% @doc 从指定路径加载配置文件。
-spec loadConfigFromFile(string()) -> ok | {error, term()}.
loadConfigFromFile(FilePath) ->
    alConfig:load(FilePath).

%%%===================================================================
%%% 会话管理
%%%===================================================================

%% @doc 创建空会话（含消息列表与创建时间戳）。
-spec createSession() -> session().
createSession() ->
    #{
        messages => [],
        created_at => erlang:system_time(millisecond)
    }.

%% @doc 向会话追加一条消息。
-spec addToSession(session(), message()) -> session().
addToSession(Session, Message) ->
    CurrentMessages = maps:get(messages, Session, []),
    Session#{messages => CurrentMessages ++ [Message]}.

%% @doc 使用会话历史发起聊天（默认选项），并自动追加助手回复。
-spec chatWithSession(session(), model()) -> {ok, binary(), session()} | {error, term()}.
chatWithSession(Session, Model) ->
    chatWithSession(Session, Model, []).

%% @doc 使用会话历史发起聊天（可指定选项）。
-spec chatWithSession(session(), model(), [option()]) -> {ok, binary(), session()} | {error, term()}.
chatWithSession(Session, Model, Options) ->
    Messages = maps:get(messages, Session, []),
    case chat(Model, Messages, Options) of
        {ok, Response} ->
            UpdatedSession = addToSession(Session, assistantMessage(Response)),
            {ok, Response, UpdatedSession};
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc 清空会话中的消息历史。
-spec clearSession(session()) -> session().
clearSession(Session) ->
    Session#{messages => []}.

%%%===================================================================
%%% Token 估算与统计
%%%===================================================================

%% @doc 估算文本 Token 数（CJK 感知）。
%% ASCII 约 4 字符/token；中日韩等宽字符约 1.5 字符/token，
%% 比单纯按字节/4 更贴近真实分词，提升预算裁剪与费用估算精度。
-spec estimateTokens(binary() | string()) -> non_neg_integer().
estimateTokens(Text) when is_binary(Text) ->
    case unicode:characters_to_list(Text) of
        L when is_list(L) -> estimateFromChars(L);
        _ -> round(byte_size(Text) / 4)
    end;
estimateTokens(Text) when is_list(Text) ->
    try estimateFromChars(Text) catch _:_ -> round(length(Text) / 4) end;
estimateTokens(_) ->
    0.

%% 按 ASCII / 宽字符分别计权估算 token 数。
estimateFromChars(Chars) ->
    {Ascii, Wide} = lists:foldl(fun
        (C, {A, W}) when is_integer(C), C =< 127 -> {A + 1, W};
        (C, {A, W}) when is_integer(C) -> {A, W + 1};
        (_, Acc) -> Acc
    end, {0, 0}, Chars),
    round(Ascii / 4 + Wide / 1.5).

-define(TOKEN_STATS_TABLE, llmCliTokenStats).

%% @doc 返回累计 Token 统计（按模型分组及总计，含估算费用 USD）。
-spec tokenStats() -> map().
tokenStats() ->
    ensure_token_stats_table(),
    case ets:tab2list(?TOKEN_STATS_TABLE) of
        [] -> default_stats();
        List ->
            TotalIn = sum_field(List, inputTokens),
            TotalOut = sum_field(List, outputTokens),
            TotalCalls = sum_field(List, calls),
            ByModel = maps:from_list([
                {Model, withCost(Model, Stats)} || {Model, Stats} <- List
            ]),
            TotalCost = lists:sum([
                modelCost(Model, maps:get(inputTokens, S, 0), maps:get(outputTokens, S, 0))
                || {Model, S} <- List
            ]),
            #{
                inputTokens => TotalIn,
                outputTokens => TotalOut,
                totalTokens => TotalIn + TotalOut,
                apiCalls => TotalCalls,
                estimatedCostUsd => roundCost(TotalCost),
                byModel => ByModel
            }
    end.

%% 为单模型统计追加估算费用字段。
withCost(Model, Stats) ->
    In = maps:get(inputTokens, Stats, 0),
    Out = maps:get(outputTokens, Stats, 0),
    Stats#{estimatedCostUsd => roundCost(modelCost(Model, In, Out))}.

%% @doc 常见模型每百万 token 价格（美元）：`{输入价, 输出价}'。
%% 未列出的模型按 0 计（不计费），价格随官方调整可在此更新。
-spec modelPricing() -> #{binary() => {number(), number()}}.
modelPricing() ->
    #{
        <<"gpt-4o"/utf8>> => {2.5, 10.0},
        <<"gpt-4o-mini"/utf8>> => {0.15, 0.6},
        <<"gpt-4.1"/utf8>> => {2.0, 8.0},
        <<"gpt-4.1-mini"/utf8>> => {0.4, 1.6},
        <<"gpt-4.1-nano"/utf8>> => {0.1, 0.4},
        <<"o3-mini"/utf8>> => {1.1, 4.4},
        <<"deepseek-chat"/utf8>> => {0.27, 1.1},
        <<"deepseek-reasoner"/utf8>> => {0.55, 2.19},
        <<"deepseek-v4-flash"/utf8>> => {0.1, 0.3},
        <<"claude-3-5-sonnet-20241022"/utf8>> => {3.0, 15.0},
        <<"claude-3-5-haiku-20241022"/utf8>> => {0.8, 4.0}
    }.

%% 查询模型价格；未知模型返回 {0, 0}（不计费）。
priceFor(Model) ->
    maps:get(toBinary(Model), modelPricing(), {0.0, 0.0}).

%% 按价格表计算单模型估算费用（USD）。
modelCost(Model, InputTokens, OutputTokens) ->
    {PriceIn, PriceOut} = priceFor(Model),
    (InputTokens * PriceIn + OutputTokens * PriceOut) / 1000000.

%% 费用保留 6 位小数。
roundCost(Cost) ->
    erlang:round(Cost * 1000000) / 1000000.

%% @doc 重置所有 Token 统计数据。
-spec resetTokenStats() -> ok.
resetTokenStats() ->
    ensure_token_stats_table(),
    ets:delete_all_objects(?TOKEN_STATS_TABLE),
    ok.

%% 确保 ETS 统计表存在。
ensure_token_stats_table() ->
    case ets:info(?TOKEN_STATS_TABLE) of
        undefined ->
            ets:new(?TOKEN_STATS_TABLE, [named_table, public, set]);
        _ -> ok
    end.

%% 记录单次 API 调用的输入/输出 Token 估算。
trackTokens(Model, InputText, OutputText) ->
    ensure_token_stats_table(),
    ModelKey = toBinary(Model),
    InEst = estimateTokens(InputText),
    OutEst = estimateTokens(OutputText),
    Existing = case ets:lookup(?TOKEN_STATS_TABLE, ModelKey) of
        [{_, Stats}] -> Stats;
        [] -> #{inputTokens => 0, outputTokens => 0, calls => 0}
    end,
    NewStats = Existing#{
        inputTokens => maps:get(inputTokens, Existing, 0) + InEst,
        outputTokens => maps:get(outputTokens, Existing, 0) + OutEst,
        calls => maps:get(calls, Existing, 0) + 1
    },
    ets:insert(?TOKEN_STATS_TABLE, {ModelKey, NewStats}).

%% 对统计列表中某字段求和。
sum_field(List, Key) ->
    lists:sum([maps:get(Key, S, 0) || {_, S} <- List]).

%% 空统计的默认值。
default_stats() ->
    #{inputTokens => 0, outputTokens => 0, totalTokens => 0, apiCalls => 0,
      estimatedCostUsd => 0.0, byModel => #{}}.

%%%===================================================================
%%% 结果处理工具
%%%===================================================================

%% @doc 将错误元组格式化为可读字符串。
-spec formatError({error, term()}) -> string().
formatError({error, {http_error, StatusCode, ErrorBody}}) ->
    ErrorMsg = extractHttpErrorMessage(ErrorBody),
    io_lib:format("HTTP error ~p: ~s", [StatusCode, ErrorMsg]);
formatError({error, {http_error, StatusCode}}) ->
    io_lib:format("HTTP error ~p", [StatusCode]);
formatError({error, json_encode_failed}) ->
    "Request JSON encode failed (invalid UTF-8 or oversized content)";
formatError({error, invalid_response}) ->
    "Invalid response format";
formatError({error, max_retries_exceeded}) ->
    "Maximum retries exceeded";
formatError({error, Reason}) ->
    io_lib:format("Error: ~p", [Reason]).

extractHttpErrorMessage(#{<<"message"/utf8>> := Msg}) ->
    Msg;
extractHttpErrorMessage(#{<<"error"/utf8>> := #{<<"message"/utf8>> := Msg}}) ->
    Msg;
extractHttpErrorMessage(#{<<"error"/utf8>> := Msg}) when is_binary(Msg) ->
    Msg;
extractHttpErrorMessage(#{<<"raw"/utf8>> := Raw}) ->
    Raw;
extractHttpErrorMessage(Body) when is_binary(Body) ->
    Body;
extractHttpErrorMessage(_) ->
    <<"Unknown error"/utf8>>.

%% @doc 判断结果是否为 `{ok, _}'。
-spec isSuccess({ok, term()} | {error, term()}) -> boolean().
isSuccess({ok, _}) ->
    true;
isSuccess(_) ->
    false.

%% @doc 判断结果是否为 `{error, _}'。
-spec isError({ok, term()} | {error, term()}) -> boolean().
isError({error, _}) ->
    true;
isError(_) ->
    false.

%% @doc 从结果中提取错误原因；成功时返回 undefined。
-spec getErrorReason({ok, term()} | {error, term()}) -> term() | undefined.
getErrorReason({error, Reason}) ->
    Reason;
getErrorReason(_) ->
    undefined.