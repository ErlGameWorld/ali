%%%-------------------------------------------------------------------
%% @doc OpenAI 兼容 LLM 客户端：聊天、流式、工具调用、多 provider 适配。
%%
%% 支持 OpenAI / Anthropic / 本地 llama.cpp 等兼容端点；含模型链路由、
%% 视觉探测、thinking 开关、重试与 SSE 流式解析。
%% @end
%%%-------------------------------------------------------------------

-module(alLlmClient).

-export([chat/2, chatWithTools/3, chatWithRetry/3, stream/4,
         streamChatWithTools/4, listProviders/0,
         embeddingConfig/1, rerankConfig/1]).
%% Test exports — pure helpers
-export([llmConfig/1, parseChatResponse/1, extractMessage/1,
         encodeChatBody/3, encodeChatBody/4,
         firstDefined/1, contentToText/1, jsonEscape/1,
         capContent/1, capBinary/1, shouldRetry/1, retryDelay/1,
         parseStreamEvents/1, applyStreamEvents/3,
         buildChatUrl/2, anthropicRequestBody/4, anthropicHeaders/1,
         parseAnthropicResponse/1, providerFromOpts/1,
         maybeFastModel/3, isSimpleTask/2, hasCodeKeywords/1,
         convertMessagesForAnthropic/1, supportsVision/3, parseVisionCaps/1,
         applyModelChain/3, llmHttpTransportOpts/1,
         streamFallbackSafe/1]).

-define(MaxContentBytes, 16000).
-define(StreamIdleTimeout, 1800000).

%%--------------------------------------------------------------------
%% @doc
%% 简单聊天：不带工具调用，转调 chatWithTools/3。
%%
%% @param Messages 消息列表
%% @param Opts     调用选项
%% @return {ok, Result} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
chat(Messages, Opts) ->
    chatWithTools(Messages, [], Opts).

%%--------------------------------------------------------------------
%% @doc
%% 带重试的聊天入口。当前实现直接转调 chatWithTools/3
%% （重试逻辑在内部 doChatWithRetry 中实现）。
%%
%% @param Messages 消息列表
%% @param Tools    工具规格列表
%% @param Opts     调用选项
%% @return {ok, Result} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
chatWithRetry(Messages, Tools, Opts) ->
    chatWithTools(Messages, Tools, Opts).

-spec stream([map()], [map()], map(), pid()) -> {ok, pid()} | {error, term()}.
%%--------------------------------------------------------------------
%% @doc
%% 启动流式聊天工作进程。新进程会通过 eWCli 发起 chat 请求，
%% 并将 SSE 解析后的块以 `{eStreamChunk, binary()}'、`{eStreamDone, binary()}'
%% 或 `{eStreamError, term()}' 消息回传给 CallerPid。
%%
%% @param Messages  消息列表
%% @param Tools     工具规格列表
%% @param Opts      调用选项
%% @param CallerPid 接收流式事件的进程
%% @return {ok, pid()} | {error, llmNotConfigured}
%% @end
%%--------------------------------------------------------------------
stream(Messages, Tools, Opts, CallerPid) ->
    Opts1 = applyModelChain(Opts, Messages, Tools),
    Config = llmConfig(Opts1),
    case Config of
        #{apiKey := ApiKey, baseUrl := BaseUrl, model := Model}
          when ApiKey =/= undefined, ApiKey =/= <<>>, ApiKey =/= "" ->
            Pid = spawn(fun() ->
                runStream(BaseUrl, ApiKey, Model, Messages, Tools, Opts1, CallerPid)
            end),
            {ok, Pid};
        _ ->
            {error, llmNotConfigured}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 带工具的流式聊天：向 CallerPid 转发 token 块，并汇总为 OpenAI 形
%% 回复（content + tool_calls）。事件含 eStreamChunk / eStreamReasoning /
%% eStreamToolDelta / eStreamDone / eStreamError。
%%
%% @param Messages  消息列表
%% @param Tools     工具规格
%% @param Opts      调用选项
%% @param CallerPid 接收流式事件的进程（可 undefined）
%% @return {ok, ReplyMap} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec streamChatWithTools([map()], [map()], map(), pid() | undefined) ->
    {ok, map()} | {error, term()}.
streamChatWithTools(Messages, Tools, Opts, CallerPid) ->
    Opts1 = applyModelChain(Opts, Messages, Tools),
    Config = llmConfig(Opts1),
    case Config of
        #{apiKey := ApiKey, baseUrl := BaseUrl, model := Model}
          when ApiKey =/= undefined, ApiKey =/= <<>>, ApiKey =/= "" ->
            Self = self(),
            %% 不监视 streamCaller：中间轮/代理退出不应取消 collect。
            %% 真正断连由 session cancelAsk 处理；结果仍回传 Self。
            {Collector, MonRef} = spawn_monitor(fun() ->
                AccPid = case is_pid(CallerPid) of true -> CallerPid; false -> Self end,
                doRunStreamCollect(BaseUrl, ApiKey, Model, Messages, Tools, Opts1, AccPid, Self)
            end),
            %% 单次 LLM 流式调用按“空闲”计时，而非从启动起的绝对计时。
            %% 每个 headers/chunk 都会刷新等待，避免持续生成时被误杀。
            LlmTimeout = case maps:get(llmTimeout, Opts1, undefined) of
                N when is_integer(N), N > 0 -> N;
                _ -> maps:get(execTimeout, Opts1, 1800000)
            end,
            waitStreamCollector(Collector, MonRef, LlmTimeout + 5000, false);
        _ ->
            {error, llmNotConfigured}
    end.

%% Stream and accumulate tool_call deltas into a final reply map.
%% 按 provider 分支构造请求（OpenAI /chat/completions 或 Anthropic
%% /messages），对不支持视觉的模型降级多模态消息，并在可重试错误上
%% 按指数退避重试。中间失败不向 ForwardPid 转发，仅最终放弃时转发
%% `eStreamError'。
doRunStreamCollect(BaseUrl0, ApiKey0, Model0, Messages, Tools, Opts, ForwardPid, ReplyTo) ->
    Provider = providerFromOpts(Opts),
    ApiKey = toBinary(ApiKey0),
    Model = toBinary(Model0),
    SafeMessages = sanitizeMessagesForVision(Messages, Provider, Model, Opts),
    MaxRetries = llmMaxRetries(Opts),
    Opts1 = Opts#{streamCollectorOwner => ReplyTo},
    Result = doStreamCollectAttempt(Provider, BaseUrl0, ApiKey, Model, SafeMessages,
                                    Tools, Opts1, ForwardPid, MaxRetries, 0),
    ReplyTo ! {eStreamCollectResult, self(), Result}.

waitStreamCollector(Collector, MonRef, IdleMs, Started) ->
    receive
        {eStreamCollectActivity, Collector, Kind} ->
            waitStreamCollector(Collector, MonRef, IdleMs,
                                Started orelse Kind =:= body);
        {eStreamCollectResult, Collector, Result} ->
            erlang:demonitor(MonRef, [flush]),
            Result;
        {'DOWN', MonRef, process, Collector, Reason} ->
            {error, {streamCollectorDown, Reason}}
    after IdleMs ->
        erlang:demonitor(MonRef, [flush]),
        exit(Collector, kill),
        receive
            {'DOWN', MonRef, process, Collector, _} -> ok
        after 0 -> ok
        end,
        case Started of
            true -> {error, {streamStarted, streamTimeout}};
            false -> {error, streamTimeout}
        end
    end.

doStreamCollectAttempt(Provider, BaseUrl0, ApiKey, Model, Messages, Tools, Opts,
                       ForwardPid, RetriesLeft, Attempt) ->
    {Url, Headers, Body} = buildStreamRequest(Provider, BaseUrl0, ApiKey, Model, Messages, Tools, Opts),
    Timeout = llmRecvTimeout(Opts),
    Connect = llmConnectTimeout(Opts),
    Result = try
        runStreamCollect(Url, Headers, Body, Timeout, Connect, ForwardPid, Provider, Opts)
    catch
        error:ReasonC -> {error, {httpError, ReasonC}};
        exit:ReasonX -> {error, {httpExit, ReasonX}};
        throw:ReasonT -> {error, {httpError, ReasonT}}
    end,
    case Result of
        {ok, _} ->
            Result;
        {error, FailReason} ->
            case RetriesLeft > 0 andalso streamRetryable(FailReason) of
                true ->
                    timer:sleep(retryDelay(Attempt)),
                    doStreamCollectAttempt(Provider, BaseUrl0, ApiKey, Model,
                                           Messages, Tools, Opts, ForwardPid,
                                           RetriesLeft - 1, Attempt + 1);
                false ->
                    maybeForward(ForwardPid, {eStreamError, FailReason}),
                    Result
            end
    end.

%% 用 eWCli postStream(raw) 拉流，过程字典累积 content/reasoning/tools。
%% Caller 断开时 cancel watch 投递 eStreamCancel，handler 返回 stop 以尽快释放连接。
runStreamCollect(Url, Headers, Body, Timeout, Connect, ForwardPid, Provider, Opts) ->
    Key = {streamCollect, make_ref()},
    put(Key, #{
        acc => <<>>,
        reasoning => <<>>,
        tools => #{},
        ssePar => wcSse:new(),
        provider => Provider,
        forward => ForwardPid,
        owner => maps:get(streamCollectorOwner, Opts, undefined),
        errStatus => undefined,
        errBody => <<>>
    }),
    StreamOpts = llmStreamHttpOpts(Timeout, Connect, fun(Ev) ->
        streamCollectHandler(Key, Ev)
    end, Opts),
    Outcome = eWCli:postStream(Url, Headers, Body, StreamOpts),
    St = erase(Key),
    finalizeStreamCollect(Outcome, St).

%% 若 mailbox 里有取消通知，写入 state 并返回 true。
takeStreamCancel(Key) ->
    receive
        {eStreamCancel, Reason} ->
            St = case get(Key) of
                M when is_map(M) -> M;
                _ -> #{}
            end,
            put(Key, St#{cancelReason => Reason}),
            true
    after 0 ->
        false
    end.

streamCollectHandler(Key, Ev) ->
    case takeStreamCancel(Key) of
        true -> stop;
        false -> streamCollectHandler1(Key, Ev)
    end.

streamCollectHandler1(Key, {headers, Status, _Hs, _Ver, _Reason}) when Status >= 400 ->
    St = get(Key),
    notifyStreamActivity(St, headers),
    put(Key, St#{errStatus => Status}),
    continue;
streamCollectHandler1(Key, {headers, _Status, _Hs, _Ver, _Reason}) ->
    notifyStreamActivity(get(Key), headers),
    continue;
streamCollectHandler1(Key, {chunk, Data}) when is_binary(Data) ->
    St = get(Key),
    notifyStreamActivity(St, body),
    case maps:get(errStatus, St, undefined) of
        undefined ->
            case maps:get(doneEarly, St, false) of
                true -> continue;
                false ->
                    %% 用 wcSse 解析 SSE，消除手工 leftover 管理
                    SsePar0 = maps:get(ssePar, St),
                    {SsePar1, SseEvts} = wcSse:feed(SsePar0, Data),
                    handleCollectSseEvents(Key, St#{ssePar => SsePar1}, SseEvts)
            end;
        _ ->
            ErrBody = maps:get(errBody, St, <<>>),
            put(Key, St#{errBody => <<ErrBody/binary, Data/binary>>}),
            continue
    end;
streamCollectHandler1(Key, done) ->
    %% body 结束：flush SSE 解析器残留
    St = get(Key),
    case maps:get(doneEarly, St, false) of
        true -> continue;
        false ->
            case maps:get(errStatus, St, undefined) of
                undefined ->
                    SsePar0 = maps:get(ssePar, St),
                    {SsePar1, SseEvts} = wcSse:flush(SsePar0),
                    handleCollectSseEvents(Key, St#{ssePar => SsePar1}, SseEvts);
                _ -> continue
            end
    end;
streamCollectHandler1(_Key, {trailers, _}) ->
    continue;
streamCollectHandler1(_Key, _) ->
    continue.

%% 逐个处理 wcSse 派发的 SSE 事件
handleCollectSseEvents(Key, St, []) ->
    put(Key, St),
    continue;
handleCollectSseEvents(Key, St, [done | _Rest]) ->
    %% OpenAI [DONE]
    put(Key, St#{doneEarly => true}),
    stop;
handleCollectSseEvents(Key, St, [SseEv | Rest]) ->
    JsonBin = sseEvtData(SseEv),
    Provider = maps:get(provider, St),
    ForwardPid = maps:get(forward, St),
    case sseJsonToEvents(Provider, JsonBin) of
        done ->
            %% Anthropic message_stop
            put(Key, St#{doneEarly => true}),
            stop;
        {events, Events} ->
            {NewAcc, NewReasoning, NewTools} =
                applyCollectEvents(Events, ForwardPid,
                                   maps:get(acc, St),
                                   maps:get(reasoning, St),
                                   maps:get(tools, St)),
            handleCollectSseEvents(Key, St#{acc => NewAcc, reasoning => NewReasoning,
                                             tools => NewTools}, Rest);
        ignore ->
            handleCollectSseEvents(Key, St, Rest)
    end.

%% 从 wcSse 事件中提取 data binary
sseEvtData({data, Bin}) -> Bin;
sseEvtData({event, _Type, Bin}) -> Bin;
sseEvtData(_) -> <<>>.

notifyStreamActivity(St, Kind) when is_map(St) ->
    case maps:get(owner, St, undefined) of
        Owner when is_pid(Owner) ->
            Owner ! {eStreamCollectActivity, self(), Kind};
        _ ->
            ok
    end;
notifyStreamActivity(_, _) ->
    ok.

finalizeStreamCollect(_Outcome, #{errStatus := Code} = St) when is_integer(Code) ->
    {error, #{status => Code, body => maps:get(errBody, St, <<>>)}};
finalizeStreamCollect(ok, St) when is_map(St) ->
    FinalContent = maps:get(acc, St, <<>>),
    FinalReasoning = maps:get(reasoning, St, <<>>),
    FinalTools = maps:get(tools, St, #{}),
    ForwardPid = maps:get(forward, St),
    maybeForward(ForwardPid, {eStreamDone, FinalContent}),
    {ok, finalizeStreamReply(FinalContent, FinalReasoning, FinalTools)};
finalizeStreamCollect({error, cancelled}, St) when is_map(St) ->
    finalizeStreamCollectCancel(cancelled, St);
finalizeStreamCollect({error, {streamStarted, cancelled}}, St) when is_map(St) ->
    finalizeStreamCollectCancel({streamStarted, cancelled}, St);
finalizeStreamCollect({error, Reason}, _) ->
    {error, Reason};
finalizeStreamCollect(Other, _) ->
    {error, Other}.

%% 流已收齐（doneEarly）时，即使随后收到 callerDown/cancel，仍按成功收尾。
%% 修复 finalizeStreamCollectCancel 默认 Reason 参数未使用的问题 — 用 DefaultReason
finalizeStreamCollectCancel(DefaultReason, St) when is_map(St) ->
    case maps:get(doneEarly, St, false) of
        true ->
            finalizeStreamCollect(ok, St);
        false ->
            case maps:get(cancelReason, St, undefined) of
                undefined -> {error, DefaultReason};
                Reason -> {error, Reason}
            end
    end.

%% 判断流式/同步错误是否可重试：429/5xx 或瞬时连接错误。
%% econnrefused / nxdomain / callerDown 不重试。
streamRetryable(#{status := Code}) when Code =:= 429; Code >= 500, Code =< 599 -> true;
streamRetryable(streamTimeout) -> true;
streamRetryable(timeout) -> true;
streamRetryable(closed) -> true;
streamRetryable({closed, _}) -> true;
streamRetryable(econnreset) -> true;
streamRetryable(socket_closed_remotely) -> true;
streamRetryable(econnrefused) -> false;
streamRetryable(nxdomain) -> false;
streamRetryable(callerDown) -> false;
streamRetryable(cancelled) -> false;
streamRetryable({connectFailed, econnrefused}) -> false;
streamRetryable({connectFailed, nxdomain}) -> false;
streamRetryable({connectFailed, timeout}) -> true;
streamRetryable({connectFailed, _}) -> true;
streamRetryable({httpExit, Reason}) -> streamRetryable(Reason);
streamRetryable({httpError, Reason}) -> streamRetryable(Reason);
%% 一旦 2xx body 已开始，重试会重复输出/重复计费，必须交给上层保留部分结果。
streamRetryable({streamStarted, _Reason}) -> false;
streamRetryable(_) -> false.

-spec streamFallbackSafe(term()) -> boolean().
streamFallbackSafe({streamStarted, _}) -> false;
streamFallbackSafe(callerDown) -> false;
streamFallbackSafe(cancelled) -> false;
streamFallbackSafe(_) -> true.

%% @doc 按 provider 构造流式请求的 {Url, Headers, Body}。
%% Anthropic 用 /messages + anthropicHeaders + anthropicRequestBody；
%% 其他 provider 用 OpenAI /chat/completions + Bearer + encodeChatBody。
%% 两者都设置 stream:true。
buildStreamRequest(anthropic, BaseUrl0, ApiKey, Model, Messages, Tools, Opts) ->
    Url = buildChatUrl(BaseUrl0, anthropic),
    Body = anthropicRequestBody(Model, Messages, Tools, Opts#{stream => true}),
    Headers = anthropicHeaders(ApiKey),
    {Url, Headers, Body};
buildStreamRequest(Provider, BaseUrl0, ApiKey, Model, Messages, Tools, Opts) ->
    Url = buildChatUrl(BaseUrl0, openai),
    %% 带上 provider，encodeChatExtras 才能选 enable_thinking vs thinking.type
    Body = encodeChatBody(Model, Messages, Tools, Opts#{stream => true, provider => Provider}),
    Headers = [
        {<<"authorization">>, <<"Bearer ", ApiKey/binary>>},
        {<<"content-type">>, <<"application/json">>}
    ],
    {Url, Headers, Body}.

applyCollectEvents(Events, ForwardPid, AccContent, AccReasoning, ToolAcc) ->
    lists:foldl(fun
        ({text, Chunk}, {Acc, Reasoning, Tools}) ->
            maybeForward(ForwardPid, {eStreamChunk, Chunk}),
            {<<Acc/binary, Chunk/binary>>, Reasoning, Tools};
        ({reasoning, Chunk}, {Acc, Reasoning, Tools}) ->
            maybeForward(ForwardPid, {eStreamReasoning, Chunk}),
            {Acc, <<Reasoning/binary, Chunk/binary>>, Tools};
        ({toolDelta, Delta}, {Acc, Reasoning, Tools}) ->
            maybeForward(ForwardPid, {eStreamToolDelta, Delta}),
            {Acc, Reasoning, mergeToolDeltas(Tools, Delta)};
        ({usage, Usage}, {Acc, Reasoning, Tools}) when is_map(Usage) ->
            maybeForward(ForwardPid, {eStreamUsage, Usage}),
            {Acc, Reasoning, Tools#{usage => Usage}};
        (_, Acc) ->
            Acc
    end, {AccContent, AccReasoning, ToolAcc}, Events).

mergeToolDeltas(Acc, Deltas) when is_list(Deltas) ->
    lists:foldl(fun mergeOneToolDelta/2, Acc, Deltas);
mergeToolDeltas(Acc, _) ->
    Acc.

mergeOneToolDelta(Delta, Acc) when is_map(Delta) ->
    Index = normalizeToolIndex(maps:get(<<"index">>, Delta, maps:get(index, Delta, 0))),
    Existing = maps:get(Index, Acc, #{
        id => <<>>,
        type => <<"function">>,
        function => #{name => <<>>, arguments => <<>>}
    }),
    Id0 = maps:get(id, Existing, <<>>),
    Id1 = case maps:get(<<"id">>, Delta, undefined) of
        undefined -> Id0;
        NewId when is_binary(NewId) -> NewId;
        _ -> Id0
    end,
    Fun0 = maps:get(function, Existing, #{name => <<>>, arguments => <<>>}),
    FunDelta = maps:get(<<"function">>, Delta, #{}),
    Name0 = maps:get(name, Fun0, <<>>),
    Name1 = case maps:get(<<"name">>, FunDelta, undefined) of
        undefined -> Name0;
        N when is_binary(N), N =/= <<>> -> N;
        _ -> Name0
    end,
    Args0 = maps:get(arguments, Fun0, <<>>),
    Args1 = case maps:get(<<"arguments">>, FunDelta, undefined) of
        undefined -> Args0;
        A when is_binary(A) -> <<Args0/binary, A/binary>>;
        _ -> Args0
    end,
    Acc#{Index => Existing#{
        id => Id1,
        function => #{name => Name1, arguments => Args1}
    }};
mergeOneToolDelta(_, Acc) ->
    Acc.

%% LLM 流式 delta 的 index 可能为 integer 或 binary，统一归一化为 integer，
%% 否则 ToolAcc 的键混合两种类型，lists:sort 会 badarg。
normalizeToolIndex(I) when is_integer(I) -> I;
normalizeToolIndex(B) when is_binary(B) ->
    try binary_to_integer(B) catch _:_ -> 0 end;
normalizeToolIndex(_) -> 0.

finalizeStreamReply(Content0, Reasoning0, ToolAcc) ->
    Usage = maps:get(usage, ToolAcc, undefined),
    ToolAcc1 = maps:remove(usage, ToolAcc),
    ToolCalls0 = [maps:get(I, ToolAcc1) || I <- lists:sort(maps:keys(ToolAcc1))],
    {Content, ToolCalls} = case ToolCalls0 of
        [] ->
            alDsmlTools:recoverFromContent(Content0);
        _ ->
            {Content0, ToolCalls0}
    end,
    Msg0 = #{role => assistant, content => Content, tool_calls => ToolCalls},
    Msg = case Reasoning0 of
        <<>> -> Msg0;
        R when is_binary(R) -> Msg0#{reasoning_content => R};
        _ -> Msg0
    end,
    Reply0 = #{
        content => Content,
        message => Msg,
        tool_calls => ToolCalls
    },
    Reply1 = case maps:get(reasoning_content, Msg, undefined) of
        undefined -> Reply0;
        RC -> Reply0#{reasoning_content => RC}
    end,
    case Usage of
        U when is_map(U) ->
            maybeTrackUsage(#{<<"usage">> => U}, undefined),
            Reply1#{usage => U};
        _ ->
            Reply1
    end.

maybeForward(Pid, Msg) when is_pid(Pid) ->
    case is_process_alive(Pid) of
        true -> Pid ! Msg;
        false -> ok
    end;
maybeForward(_, _) -> ok.

%%--------------------------------------------------------------------
%% @doc
%% 流式工作进程入口：包裹 doRunStream，捕获任何异常并转为
%% `{eStreamError, {Class, Reason}}' 消息回传。
%%
%% @param BaseUrl0   API base URL
%% @param ApiKey0    API key
%% @param Model0     模型名
%% @param Messages   消息列表
%% @param Tools      工具规格
%% @param Opts       调用选项
%% @param CallerPid  接收事件的进程
%% @end
%%--------------------------------------------------------------------
%%--------------------------------------------------------------------
%% @doc
%% 流式工作进程入口：Caller 断开时 cancel watch 尽快结束 HTTP 流。
%% @end
%%--------------------------------------------------------------------
runStream(BaseUrl0, ApiKey0, Model0, Messages, Tools, Opts, CallerPid) ->
    CancelWatch = startCancelWatch(self(), CallerPid),
    try
        doRunStream(BaseUrl0, ApiKey0, Model0, Messages, Tools, Opts, CallerPid)
    catch
        Class:Reason ->
            case is_process_alive(CallerPid) of
                true -> CallerPid ! {eStreamError, {Class, Reason}};
                false -> ok
            end
    after
        stopCancelWatch(CancelWatch)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 真正发起流式请求的实现：构造 OpenAI 兼容请求体，使用 eWCli
%% postStream(raw) 拉流，进入 streamLoop 等价的 handler 累积事件。
%%
%% @param BaseUrl0   API base URL
%% @param ApiKey0    API key
%% @param Model0     模型名
%% @param Messages   消息列表
%% @param Tools      工具规格
%% @param Opts       调用选项
%% @param CallerPid  接收事件的进程
%% @end
%%--------------------------------------------------------------------
doRunStream(BaseUrl0, ApiKey0, Model0, Messages, Tools, Opts, CallerPid) ->
    Provider = providerFromOpts(Opts),
    ApiKey = toBinary(ApiKey0),
    Model = toBinary(Model0),
    SafeMessages = sanitizeMessagesForVision(Messages, Provider, Model, Opts),
    MaxRetries = llmMaxRetries(Opts),
    doStreamAttempt(Provider, BaseUrl0, ApiKey, Model, SafeMessages, Tools, Opts,
                    CallerPid, MaxRetries, 0).

%% 单次流式尝试；可重试错误上按指数退避重试，最终失败才转发 eStreamError。
doStreamAttempt(Provider, BaseUrl0, ApiKey, Model, Messages, Tools, Opts,
                CallerPid, RetriesLeft, Attempt) ->
    {Url, Headers, Body} = buildStreamRequest(Provider, BaseUrl0, ApiKey, Model, Messages, Tools, Opts),
    Timeout = llmRecvTimeout(Opts),
    Connect = llmConnectTimeout(Opts),
    Result = try
        runStreamForward(Url, Headers, Body, Timeout, Connect, CallerPid, Provider, Opts)
    catch
        error:ReasonC -> {error, {httpError, ReasonC}};
        exit:ReasonX -> {error, {httpExit, ReasonX}};
        throw:ReasonT -> {error, {httpError, ReasonT}}
    end,
    case Result of
        {ok, done} ->
            ok;
        {error, ErrReason} ->
            case RetriesLeft > 0 andalso streamRetryable(ErrReason) of
                true ->
                    timer:sleep(retryDelay(Attempt)),
                    doStreamAttempt(Provider, BaseUrl0, ApiKey, Model, Messages, Tools,
                                    Opts, CallerPid, RetriesLeft - 1, Attempt + 1);
                false ->
                    case is_process_alive(CallerPid) of
                        true -> CallerPid ! {eStreamError, ErrReason};
                        false -> ok
                    end,
                    ok
            end
    end.

runStreamForward(Url, Headers, Body, Timeout, Connect, CallerPid, Provider, Opts) ->
    Key = {streamFwd, make_ref()},
    put(Key, #{
        acc => <<>>,
        ssePar => wcSse:new(),
        provider => Provider,
        caller => CallerPid,
        errStatus => undefined,
        errBody => <<>>
    }),
    StreamOpts = llmStreamHttpOpts(Timeout, Connect, fun(Ev) ->
        streamForwardHandler(Key, Ev)
    end, Opts),
    Outcome = eWCli:postStream(Url, Headers, Body, StreamOpts),
    St = erase(Key),
    finalizeStreamForward(Outcome, St).

streamForwardHandler(Key, Ev) ->
    case takeStreamCancel(Key) of
        true -> stop;
        false -> streamForwardHandler1(Key, Ev)
    end.

streamForwardHandler1(Key, {headers, Status, _Hs, _Ver, _Reason}) when Status >= 400 ->
    St = get(Key),
    put(Key, St#{errStatus => Status}),
    continue;
streamForwardHandler1(_Key, {headers, _Status, _Hs, _Ver, _Reason}) ->
    continue;
streamForwardHandler1(Key, {chunk, Data}) when is_binary(Data) ->
    St = get(Key),
    case maps:get(errStatus, St, undefined) of
        undefined ->
            case maps:get(doneEarly, St, false) of
                true -> continue;
                false ->
                    SsePar0 = maps:get(ssePar, St),
                    {SsePar1, SseEvts} = wcSse:feed(SsePar0, Data),
                    handleForwardSseEvents(Key, St#{ssePar => SsePar1}, SseEvts)
            end;
        _ ->
            ErrBody = maps:get(errBody, St, <<>>),
            put(Key, St#{errBody => <<ErrBody/binary, Data/binary>>}),
            continue
    end;
streamForwardHandler1(Key, done) ->
    St = get(Key),
    case maps:get(doneEarly, St, false) of
        true -> continue;
        false ->
            case maps:get(errStatus, St, undefined) of
                undefined ->
                    SsePar0 = maps:get(ssePar, St),
                    {SsePar1, SseEvts} = wcSse:flush(SsePar0),
                    handleForwardSseEvents(Key, St#{ssePar => SsePar1}, SseEvts);
                _ -> continue
            end
    end;
streamForwardHandler1(_Key, {trailers, _}) ->
    continue;
streamForwardHandler1(_Key, _) ->
    continue.

handleForwardSseEvents(Key, St, []) ->
    put(Key, St),
    continue;
handleForwardSseEvents(Key, St, [done | _Rest]) ->
    put(Key, St#{doneEarly => true}),
    stop;
handleForwardSseEvents(Key, St, [SseEv | Rest]) ->
    JsonBin = sseEvtData(SseEv),
    Provider = maps:get(provider, St),
    CallerPid = maps:get(caller, St),
    case sseJsonToEvents(Provider, JsonBin) of
        done ->
            put(Key, St#{doneEarly => true}),
            stop;
        {events, Events} ->
            NewAcc = applyStreamEvents(Events, CallerPid, maps:get(acc, St)),
            handleForwardSseEvents(Key, St#{acc => NewAcc}, Rest);
        ignore ->
            handleForwardSseEvents(Key, St, Rest)
    end.

finalizeStreamForward(_Outcome, #{errStatus := Code} = St) when is_integer(Code) ->
    {error, #{status => Code, body => maps:get(errBody, St, <<>>)}};
finalizeStreamForward(ok, St) when is_map(St) ->
    CallerPid = maps:get(caller, St),
    FinalAcc = maps:get(acc, St, <<>>),
    case is_process_alive(CallerPid) of
        true -> CallerPid ! {eStreamDone, FinalAcc};
        false -> ok
    end,
    {ok, done};
finalizeStreamForward({error, cancelled}, St) when is_map(St) ->
    finalizeStreamForwardCancel(cancelled, St);
finalizeStreamForward({error, {streamStarted, cancelled}}, St) when is_map(St) ->
    finalizeStreamForwardCancel({streamStarted, cancelled}, St);
finalizeStreamForward({error, Reason}, _) ->
    {error, Reason};
finalizeStreamForward(Other, _) ->
    {error, Other}.

finalizeStreamForwardCancel(DefaultReason, St) when is_map(St) ->
    case maps:get(doneEarly, St, false) of
        true ->
            finalizeStreamForward(ok, St);
        false ->
            case maps:get(cancelReason, St, undefined) of
                undefined -> {error, DefaultReason};
                Reason -> {error, Reason}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 将一组流事件应用到累积内容上：text 块追加到 Acc 并向 CallerPid
%% 发 `{eStreamChunk, Chunk}'；toolDelta 块发 `{eStreamToolDelta, Delta}'
%% 但不累积到 Acc。
%%
%% @param Events     流事件列表
%% @param CallerPid  接收事件的进程
%% @param AccContent 已累积的文本内容
%% @return 新的累积内容 binary()
%% @end
%%--------------------------------------------------------------------
applyStreamEvents(Events, CallerPid, AccContent) ->
    lists:foldl(fun
        ({text, Chunk}, Acc) ->
            maybeForward(CallerPid, {eStreamChunk, Chunk}),
            <<Acc/binary, Chunk/binary>>;
        ({toolDelta, Delta}, Acc) ->
            maybeForward(CallerPid, {eStreamToolDelta, Delta}),
            Acc;
        ({reasoning, Chunk}, Acc) ->
            maybeForward(CallerPid, {eStreamReasoning, Chunk}),
            Acc;
        ({usage, Usage}, Acc) when is_map(Usage) ->
            maybeForward(CallerPid, {eStreamUsage, Usage}),
            Acc;
        (_, Acc) ->
            Acc
    end, AccContent, Events).

%% eWCli 流式公共选项：连接池/ALPN 由 llm.http（及 Opts 覆盖）控制。
%% 保持 format => raw：handler 用 wcSse:feed/flush 手动解析 SSE，
%% 这样 error body（400+ JSON）也能正常收集。
llmStreamHttpOpts(Timeout, Connect, Handler, Opts) when is_function(Handler, 1) ->
    Transport = llmHttpTransportOpts(Opts),
    Transport#{
        format => raw,
        withBody => false,
        maxBody => infinity,
        connectTimeout => Connect,
        recvTimeout => infinity,
        firstByteTimeout => Timeout,
        chunkIdleTimeout => streamIdleTimeout(Timeout, Opts),
        handler => Handler
    }.

%% chunk 空闲超时：LLM 生成可能有长停顿（thinking、大函数体），
%% 默认用 ?StreamIdleTimeout（1800s = 30 分钟），而非 llmRecvTimeout（30s）。
%% 优先级：Opts.llmChunkIdleTimeout > Opts.chunkIdleTimeout > ?StreamIdleTimeout。
streamIdleTimeout(_Timeout, Opts) ->
    case maps:get(llmChunkIdleTimeout, Opts,
                  maps:get(chunkIdleTimeout, Opts, ?StreamIdleTimeout)) of
        N when is_integer(N), N > 0 -> N;
        infinity -> infinity;
        _ -> ?StreamIdleTimeout
    end.

%%--------------------------------------------------------------------
%% @doc Caller 断开监视：向 Target 投递 `{eStreamCancel, callerDown}'。
%% @end
%%--------------------------------------------------------------------
startCancelWatch(Target, Watch) when is_pid(Target), is_pid(Watch), Target =/= Watch ->
    spawn(fun() -> cancelWatchLoop(Target, Watch) end);
startCancelWatch(_, _) ->
    undefined.

stopCancelWatch(undefined) -> ok;
stopCancelWatch(WatchPid) when is_pid(WatchPid) ->
    WatchPid ! {eStopCancelWatch, self()},
    ok.

cancelWatchLoop(Target, Watch) ->
    Ref = erlang:monitor(process, Watch),
    receive
        {'DOWN', Ref, process, Watch, _} ->
            case is_process_alive(Target) of
                true -> Target ! {eStreamCancel, callerDown};
                false -> ok
            end;
        {eStopCancelWatch, _} ->
            erlang:demonitor(Ref, [flush]),
            ok
    end.

-type streamEvent() :: {text, binary()} | {toolDelta, [map()]} | {reasoning, binary()}.
-spec parseStreamEvents(binary()) -> {ok, [streamEvent()]} | {done, [streamEvent()]} | ignore.
%%--------------------------------------------------------------------
%% @doc
%% 将一段 SSE 缓冲区解析为流事件列表。按 `\n' 拆行后逐行处理
%% `data: ...' 与 `data: [DONE]'。无任何有效事件时返回 ignore。
%%
%% @param Data SSE 文本
%% @return {ok, Events} | {done, Events} | ignore
%% @end
%%--------------------------------------------------------------------
parseStreamEvents(Data) when is_binary(Data) ->
    Lines = binary:split(Data, <<"\n">>, [global, trim_all]),
    parseStreamEventLines(Lines, []).

%% 所有行处理完毕：无事件返回 ignore，否则返回 {ok, 反向后的列表}
parseStreamEventLines([], Events) ->
    case Events of
        [] -> ignore;
        _ -> {ok, lists:reverse(Events)}
    end;
%% 逐行处理：去除 CR 后判断 `data: [DONE]` 或 `data: <json>`
parseStreamEventLines([Line | Rest], Events) ->
    Trimmed = binary:replace(Line, <<"\r">>, <<>>, [global]),
    case Trimmed of
        <<"data: [DONE]">> ->
            {done, lists:reverse(Events)};
        <<"data: ", JsonData/binary>> ->
            case parseStreamJsonEvents(JsonData) of
                ignore -> parseStreamEventLines(Rest, Events);
                NewEvents -> parseStreamEventLines(Rest, NewEvents ++ Events)
            end;
        _ ->
            parseStreamEventLines(Rest, Events)
    end.

%% 解析单行 SSE 的 JSON 内容并提取流事件，解码失败返回 ignore
parseStreamJsonEvents(JsonData) ->
    try alJson:decode(JsonData) of
        Decoded -> extractStreamEvents(Decoded)
    catch
        _:_ -> ignore
    end.

%%--------------------------------------------------------------------
%% @doc
%% 从 OpenAI 兼容流式 chunk 中提取事件：优先识别 tool_calls 增量，
%% 其次识别 content 文本增量。无可识别内容时返回 ignore。
%%
%% @param Decoded 单个 chunk 的 JSON map
%% @return [{text, binary()}] | [{toolDelta, [map()]}] | ignore
%% @end
%%--------------------------------------------------------------------
extractStreamEvents(#{<<"choices">> := [#{<<"delta">> := Delta} | _]} = Decoded) ->
    Events0 = case maps:get(<<"tool_calls">>, Delta, undefined) of
        Calls when is_list(Calls), Calls =/= [] ->
            [{toolDelta, Calls}];
        _ ->
            case maps:get(<<"content">>, Delta, undefined) of
                Content when is_binary(Content), Content =/= <<>> -> [{text, Content}];
                _ -> []
            end
    end,
    Events1 = case reasoningDelta(Delta) of
        undefined -> Events0;
        R -> Events0 ++ [{reasoning, R}]
    end,
    Events2 = case maps:get(<<"usage">>, Decoded, undefined) of
        Usage when is_map(Usage) -> Events1 ++ [{usage, Usage}];
        _ -> Events1
    end,
    case Events2 of
        [] -> ignore;
        _ -> Events2
    end;
%% 最终 usage-only chunk（choices 空/null）
extractStreamEvents(#{<<"usage">> := Usage}) when is_map(Usage) ->
    [{usage, Usage}];
%% 其他形态——忽略
extractStreamEvents(_) ->
    ignore.

reasoningDelta(Delta) when is_map(Delta) ->
    case maps:get(<<"reasoning_content">>, Delta,
                  maps:get(<<"reasoning">>, Delta, undefined)) of
        R when is_binary(R), R =/= <<>> -> R;
        _ -> undefined
    end;
reasoningDelta(_) ->
    undefined.

%% 从 eWCli 已解析的 SSE data binary 提取业务事件（format => sse 路径）。
sseJsonToEvents(anthropic, JsonBin) ->
    sseJsonEvents(JsonBin, fun extractAnthropicStreamEvents/1);
sseJsonToEvents(_Provider, JsonBin) ->
    sseJsonEvents(JsonBin, fun extractStreamEvents/1).

%% 解码单行 JSON 并用给定提取器转事件；解码失败/无事件返回 ignore。
sseJsonEvents(Json, Extractor) ->
    try alJson:decode(Json) of
        Decoded ->
            case Extractor(Decoded) of
                ignore -> ignore;
                done -> done;
                Events when is_list(Events) -> {events, Events}
            end
    catch
        _:_ -> ignore
    end.

%%--------------------------------------------------------------------
%% @doc
%% 从 Anthropic 流式事件中提取内容/工具增量：
%%  - content_block_delta + text_delta      → `{text, Text}'
%%  - content_block_delta + input_json_delta → `{toolDelta, ...}'（arguments 增量）
%%  - content_block_start + tool_use         → `{toolDelta, ...}'（id + name）
%%  - message_stop                           → done
%% toolDelta 采用 OpenAI 兼容形态，复用 mergeToolDeltas 合并逻辑。
%%
%% @param Decoded 单个 SSE 事件 JSON map
%% @return [streamEvent()] | done | ignore
%% @end
%%--------------------------------------------------------------------
extractAnthropicStreamEvents(#{<<"type">> := <<"content_block_delta">>} = Ev) ->
    Index = maps:get(<<"index">>, Ev, 0),
    case maps:get(<<"delta">>, Ev, #{}) of
        #{<<"type">> := <<"text_delta">>, <<"text">> := Text}
          when is_binary(Text), Text =/= <<>> ->
            [{text, Text}];
        #{<<"type">> := <<"input_json_delta">>, <<"partial_json">> := Partial}
          when is_binary(Partial) ->
            [{toolDelta, [#{<<"index">> => Index,
                            <<"function">> => #{<<"arguments">> => Partial}}]}];
        _ ->
            ignore
    end;
extractAnthropicStreamEvents(#{<<"type">> := <<"content_block_start">>} = Ev) ->
    Index = maps:get(<<"index">>, Ev, 0),
    case maps:get(<<"content_block">>, Ev, #{}) of
        #{<<"type">> := <<"tool_use">>} = Block ->
            Id = maps:get(<<"id">>, Block, <<>>),
            Name = maps:get(<<"name">>, Block, <<>>),
            [{toolDelta, [#{<<"index">> => Index,
                            <<"id">> => Id,
                            <<"function">> => #{<<"name">> => Name, <<"arguments">> => <<>>}}]}];
        _ ->
            ignore
    end;
extractAnthropicStreamEvents(#{<<"type">> := <<"message_stop">>}) ->
    done;
extractAnthropicStreamEvents(_) ->
    ignore.

%%--------------------------------------------------------------------
%% @doc
%% 带工具的聊天主入口。读取配置，若 apiKey 未配置返回
%% llmNotConfigured；否则进入带重试的 doChatWithRetry。
%%
%% 配置了 `llm.models' 模型链时先经 alLlmRouter 解析起始链项
%% （Opts.modelEntry 已 pin 时直接使用），失败后沿链升级重试；
%% 未配置链时走原有单模型 + fastModel/fallback 路径（完全向后兼容）。
%%
%% @param Messages 消息列表
%% @param Tools    工具规格列表
%% @param Opts     调用选项
%% @return {ok, Result} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
chatWithTools(Messages, Tools, Opts) ->
    Opts1 = applyModelChain(Opts, Messages, Tools),
    Config0 = llmConfig(Opts1),
    %% 任务感知模型路由：无工具且问题简短时用 fastModel 降本提速。
    %% 链路由已做任务分级（simple/medium/complex），链 pin 时跳过。
    Config = case maps:get(modelEntry, Opts1, undefined) of
        undefined -> maybeFastModel(Config0, Messages, Tools);
        _ -> Config0
    end,
    case Config of
        #{apiKey := ApiKey, baseUrl := BaseUrl, model := Model} when ApiKey =/= undefined ->
            MaxRetries = llmMaxRetries(Opts1),
            Result = doChatWithRetry(BaseUrl, ApiKey, Model, Messages, Tools, Opts1, MaxRetries, 0),
            case Result of
                {error, _} ->
                    maybeChainFallback(Opts1, Messages, Tools, Result);
                Ok ->
                    Ok
            end;
        _ ->
            {error, llmNotConfigured}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 链分支接入：经 alLlmRouter 解析本次调用应使用的链项并合并进 Opts。
%% Opts.modelEntry 已 pin（会话路由/链升级）时直接复用；链未配置时
%% 原样返回（走单模型路径）。
%%
%% @param Opts     调用选项
%% @param Messages 消息列表
%% @param Tools    工具规格列表
%% @return 合并链项后的 Opts
%% @end
%%--------------------------------------------------------------------
-spec applyModelChain(map(), [map()], [map()]) -> map().
applyModelChain(Opts, Messages, Tools) when is_map(Opts) ->
    case alLlmRouter:resolveEntry(Messages, Tools, Opts) of
        {ok, Entry} ->
            logger:debug("alLlmClient chain route to ~s (~s)",
                         [maps:get(id, Entry, <<>>), maps:get(model, Entry, <<>>)]),
            alLlmRouter:mergeEntryOpts(Entry, Opts#{modelEntry => Entry});
        disabled ->
            Opts
    end.

%%--------------------------------------------------------------------
%% @doc
%% 失败分流：链 pin 时沿链升级（重试耗尽换下一个链项递归 chatWithTools，
%% 链尾返回原错误）；无链 pin 时走原有 fallbackModel/fallbackProvider 路径。
%%
%% @param Opts          调用选项（可能含 modelEntry）
%% @param Messages      消息列表
%% @param Tools         工具规格列表
%% @param PrimaryError  主模型错误结果
%% @return {ok, Result} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
maybeChainFallback(Opts, Messages, Tools, PrimaryError) ->
    case maps:get(modelEntry, Opts, undefined) of
        Entry when is_map(Entry) ->
            case alLlmRouter:nextEntry(maps:get(id, Entry, undefined)) of
                {ok, Next} ->
                    logger:warning("alLlmClient chain escalate ~s -> ~s after error",
                                   [maps:get(id, Entry, <<>>), maps:get(id, Next, <<>>)]),
                    %% 沉淀经验路由记忆：下次相似问题直接从更强模型开始
                    alLlmRouter:noteLocalFailure(
                        alLlmRouter:questionFromMessages(Messages), Entry, PrimaryError),
                    Next1 = alLlmRouter:applyCloudOverride(
                        Next, maps:get(llmOverride, Opts, undefined)),
                    Opts1 = alLlmRouter:mergeEntryOpts(Next1, Opts#{modelEntry => Next1}),
                    chatWithTools(Messages, Tools, Opts1);
                none ->
                    PrimaryError
            end;
        _ ->
            maybeFallback(llmConfig(Opts), Messages, Tools, Opts, PrimaryError)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 任务感知模型选择：当配置了 fastModel 且当前任务为简单任务时，
%% 切换到 fastModel 以降低延迟和成本。
%%
%% 简单任务判定：
%% - 无工具调用（Tools 为空）：纯对话不需要工具推理
%% - 最后一条用户消息短（< 120 字符）：简短问候/确认/单句问答
%% - 不含代码/调试相关关键词：非复杂分析任务
%%
%% @param Config  LLM 配置 map
%% @param Messages 消息列表
%% @param Tools    工具列表
%% @return 可能切换了 model 的 Config
%% @end
%%--------------------------------------------------------------------
maybeFastModel(#{fastModel := FastModel, model := Model} = Config, Messages, Tools)
    when FastModel =/= undefined, FastModel =/= Model ->
    case isSimpleTask(Messages, Tools) of
        true ->
            logger:debug("alLlmClient using fast model ~s for simple task", [FastModel]),
            Config#{model => FastModel};
        false ->
            Config
    end;
maybeFastModel(Config, _Messages, _Tools) ->
    Config.

%% 判断是否为简单任务：无工具 + 短消息 + 无代码关键词。
isSimpleTask(Messages, Tools) ->
    HasTools = is_list(Tools) andalso Tools =/= [],
    LastUserText = lastUserText(Messages),
    Short = byte_size(LastUserText) < 120,
    NoCodeKeywords = not hasCodeKeywords(LastUserText),
    (not HasTools) andalso Short andalso NoCodeKeywords.

%% 提取消息列表中最后一条 user 消息的文本内容。
lastUserText(Messages) when is_list(Messages) ->
    case lists:foldl(fun
        (#{role := user, content := Content}, _Acc) ->
            contentToText(Content);
        (_, Acc) ->
            Acc
    end, <<>>, Messages) of
        Text when is_binary(Text) -> Text;
        _ -> <<>>
    end;
lastUserText(_) ->
    <<>>.

%% 检测文本中是否包含代码/调试相关关键词（中英文）。
hasCodeKeywords(Text) ->
    Lower = string:lowercase(Text),
    Keywords = [<<"code">>, <<"function">>, <<"module">>, <<"error">>, <<"debug">>,
                <<"implement">>, <<"refactor">>, <<"patch">>, <<"search">>,
                <<"代码"/utf8>>, <<"函数"/utf8>>, <<"模块"/utf8>>, <<"错误"/utf8>>, <<"调试"/utf8>>,
                <<"实现"/utf8>>, <<"重构"/utf8>>, <<"搜索"/utf8>>, <<"分析"/utf8>>],
    lists:any(fun(K) -> binary:match(Lower, K) =/= nomatch end, Keywords).

%% 若配置了 fallbackModel，在主模型失败后切换到备用模型重试。
maybeFallback(#{fallbackModel := FbModel, apiKey := ApiKey, baseUrl := BaseUrl},
              Messages, Tools, Opts, _PrimaryError) when FbModel =/= undefined ->
    logger:warning("alLlmClient falling back to model ~s", [FbModel]),
    MaxRetries = llmMaxRetries(Opts),
    doChatWithRetry(BaseUrl, ApiKey, FbModel, Messages, Tools, Opts, MaxRetries, 0);
maybeFallback(#{fallbackProvider := FbProvider}, Messages, Tools, Opts, PrimaryError)
    when FbProvider =/= undefined ->
    fallbackToProvider(FbProvider, Messages, Tools, Opts, PrimaryError);
maybeFallback(_Config, _Messages, _Tools, _Opts, PrimaryError) ->
    PrimaryError.

%% 切换到备用 provider 重试：从 env 读取 fallback 的 apiKey/baseUrl/model
%% （缺省用该 provider 的默认值），并把 provider 注入 Opts 以让 postChat
%% 走正确的协议分支（OpenAI vs Anthropic）。无可用 apiKey 时保留原错误。
fallbackToProvider(FbProvider, Messages, Tools, Opts, PrimaryError) ->
    Env = alConfig:get(llm, #{}),
    Defaults = providerDefaults(FbProvider),
    ApiKey = firstDefined([
        maps:get(fallbackApiKey, Env, undefined),
        maps:get(apiKey, Env, undefined)
    ]),
    case ApiKey of
        undefined ->
            PrimaryError;
        _ ->
            BaseUrl = firstDefined([
                maps:get(fallbackBaseUrl, Env, undefined),
                maps:get(baseUrl, Defaults, undefined)
            ]),
            Model = firstDefined([
                maps:get(fallbackProviderModel, Env, undefined),
                maps:get(model, Defaults, undefined)
            ]),
            logger:warning("alLlmClient falling back to provider ~p", [FbProvider]),
            Opts1 = Opts#{provider => FbProvider},
            MaxRetries = llmMaxRetries(Opts1),
            case doChatWithRetry(BaseUrl, ApiKey, Model, Messages, Tools, Opts1, MaxRetries, 0) of
                {error, _} -> PrimaryError;
                Ok -> Ok
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 递归重试聊天请求。成功直接返回；遇到 429 或 5xx 时按指数退避
%% 等待 retryDelay(Attempt) 后递归（RetriesLeft-1, Attempt+1）；
%% 其他错误原样返回。
%%
%% @param BaseUrl     API base URL
%% @param ApiKey      API key
%% @param Model       模型名
%% @param Messages    消息列表
%% @param Tools       工具规格
%% @param Opts        调用选项
%% @param RetriesLeft 剩余重试次数
%% @param Attempt     当前重试序号（用于计算退避）
%% @end
%%--------------------------------------------------------------------
doChatWithRetry(BaseUrl, ApiKey, Model, Messages, Tools, Opts, RetriesLeft, Attempt) ->
    Result = postChat(BaseUrl, ApiKey, Model, Messages, Tools, Opts),
    case Result of
        {ok, _} = Ok ->
            Ok;
        {error, Reason} = Error ->
            case RetriesLeft > 0 andalso chatRetryable(Reason) of
                true ->
                    TimeoutMs = llmRecvTimeout(Opts),
                    logger:warning(
                        "alLlmClient chat retry reason=~p left=~p recvTimeoutMs=~p attempt=~p",
                        [alAskDiag:sanitize(Reason), RetriesLeft - 1, TimeoutMs, Attempt]),
                    timer:sleep(retryDelay(Attempt)),
                    doChatWithRetry(BaseUrl, ApiKey, Model, Messages, Tools, Opts,
                                       RetriesLeft - 1, Attempt + 1);
                false ->
                    Error
            end
    end.

%% 同步 chat 重试策略：429/5xx/连接抖动可重试。
%% 纯 timeout 不重试——本地慢模型整包生成超时后再打一轮只会双倍等待。
chatRetryable(timeout) -> false;
chatRetryable(Reason) -> streamRetryable(Reason).

%%--------------------------------------------------------------------
%% @doc
%% 判断一个错误结果是否应当重试：429/5xx 或连接类错误（closed/timeout 等）。
%%
%% @param Result 调用结果
%% @return boolean()
%% @end
%%--------------------------------------------------------------------
-spec shouldRetry(term()) -> boolean().
shouldRetry({error, Reason}) -> streamRetryable(Reason);
shouldRetry(_) -> false.

%%--------------------------------------------------------------------
%% @doc
%% 计算第 Attempt 次重试的退避时间：基础为 1000*2^Attempt（上限 60s），
%% 再加上不超过基础 30% 的随机抖动。
%%
%% @param Attempt 重试序号（从 0 开始）
%% @return 毫秒数
%% @end
%%--------------------------------------------------------------------
-spec retryDelay(non_neg_integer()) -> non_neg_integer().
retryDelay(Attempt) ->
    BaseMs = min(1000 * trunc(math:pow(2, Attempt)), 60000),
    JitterMs = rand:uniform(max(1, trunc(BaseMs * 0.3))),
    BaseMs + JitterMs.

%%--------------------------------------------------------------------
%% @doc
%% 解析 LLM 配置。优先级：Opts > aliCfg.cfg llm.* > providerDefaults(baseUrl 等)。
%% 模型名以配置 `llm.model` 为准，不在 DeepSeek 路径写死厂商型号。
%%
%% @param Opts 调用选项
%% @return 含 provider/apiKey/baseUrl/model 的 map
%% @end
%%--------------------------------------------------------------------
llmConfig(Opts) ->
    Env = alConfig:get(llm, #{}),
    ChainFallback = chainFallbackConfig(Env, Opts),
    Provider = firstDefined([
        maps:get(provider, Opts, undefined),
        maps:get(provider, Env, undefined),
        maps:get(provider, ChainFallback, undefined)
    ]),
    Defaults = case Provider of
        undefined -> #{};
        P -> providerDefaults(P)
    end,
    %% 本地推理服务（ollama / llama.cpp / vllm / lmstudio）不要求 apiKey：
    %% 缺省占位 <<"none">>，与模型链 normalizeEntry 的处理保持一致。
    ApiKey0 = firstDefined([
        maps:get(apiKey, Opts, undefined),
        maps:get(apiKey, Env, undefined),
        maps:get(apiKey, ChainFallback, undefined)
    ]),
    ApiKey = case ApiKey0 of
        undefined ->
            IsLocal = Provider =/= undefined
                andalso alLlmRouter:isLocalProvider(Provider),
            case IsLocal of
                true -> <<"none">>;
                false -> undefined
            end;
        Other ->
            Other
    end,
    #{
        provider => Provider,
        apiKey => ApiKey,
        baseUrl => firstDefined([
            maps:get(baseUrl, Opts, undefined),
            maps:get(baseUrl, Env, undefined),
            maps:get(baseUrl, ChainFallback, undefined),
            maps:get(baseUrl, Defaults, undefined)
        ]),
        model => firstDefined([
            maps:get(model, Opts, undefined),
            maps:get(model, Env, undefined),
            maps:get(model, ChainFallback, undefined),
            maps:get(model, Defaults, undefined)
        ]),
        fastModel => maps:get(fastModel, Env, undefined),
        fallbackModel => maps:get(fallbackModel, Env, undefined),
        fallbackProvider => maps:get(fallbackProvider, Env, undefined),
        vision => firstDefined([
            maps:get(vision, Opts, undefined),
            maps:get(vision, Env, undefined),
            auto
        ])
    }.

chainFallbackConfig(Env, Opts) ->
    Chain = maps:get(chain, Env, []),
    case maps:get(modelEntry, Opts, undefined) of
        Entry when is_map(Entry) ->
            Entry;
        _ ->
            case Chain of
                [E | _] when is_map(E) -> E;
                _ -> #{}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% Provider 默认值表：主要补 baseUrl。DeepSeek 的 model 不写死，读 cfg。
%%  - anthropic   → https://api.anthropic.com/v1
%%  - deepseek    → https://api.deepseek.com/chat/completions
%%  - openai      → https://api.openai.com/v1/chat/completions
%%  - qwen / glm / zhipu / ernie / doubao / kimi / openrouter / siliconflow / oneapi
%%
%% @param Provider provider atom
%% @return 含 baseUrl / 可选 model 的 map
%% @end
%%--------------------------------------------------------------------
%% Provider 默认值：仅补 baseUrl（以及 anthropic 的历史默认模型作兜底）。
%% 业务模型名以 aliCfg.cfg 的 llm.model / llm.models 为准，避免 API 改名后代码写死。
providerDefaults(anthropic) ->
    #{baseUrl => <<"https://api.anthropic.com/v1">>,
      model => <<"claude-3-5-sonnet-20241022">>};
providerDefaults(deepseek) ->
    #{baseUrl => <<"https://api.deepseek.com/chat/completions">>};
providerDefaults(openai) ->
    #{baseUrl => <<"https://api.openai.com/v1/chat/completions">>,
      model => <<"gpt-5.6-sol">>};
providerDefaults(qwen) ->
    #{baseUrl => <<"https://dashscope.aliyuncs.com/compatible-mode/v1">>,
      model => <<"qwen3.8-max">>};
providerDefaults(dashscope) ->
    providerDefaults(qwen);
providerDefaults(glm) ->
    #{baseUrl => <<"https://open.bigmodel.cn/api/paas/v4/chat/completions">>,
      model => <<"glm-5.2">>};
providerDefaults(zhipu) ->
    #{baseUrl => <<"https://open.bigmodel.cn/api/paas/v4/chat/completions">>,
      model => <<"glm-5.2">>};
providerDefaults(ernie) ->
    #{baseUrl => <<"https://qianfan.baidubce.com/v2/chat/completions">>,
      model => <<"ernie-4.0-8k">>};
providerDefaults(qianfan) ->
    #{baseUrl => <<"https://qianfan.baidubce.com/v2/chat/completions">>,
      model => <<"ernie-4.0-8k">>};
providerDefaults(doubao) ->
    #{baseUrl => <<"https://ark.cn-beijing.volces.com/api/v3/chat/completions">>,
      model => <<"doubao-1-5-pro-32k-250115">>};
providerDefaults(ark) ->
    #{baseUrl => <<"https://ark.cn-beijing.volces.com/api/v3/chat/completions">>,
      model => <<"doubao-1-5-pro-32k-250115">>};
providerDefaults(kimi) ->
    #{baseUrl => <<"https://api.moonshot.cn/v1/chat/completions">>,
      model => <<"moonshot-v1-32k">>};
providerDefaults(moonshot) ->
    #{baseUrl => <<"https://api.moonshot.cn/v1/chat/completions">>,
      model => <<"moonshot-v1-32k">>};
providerDefaults(openrouter) ->
    #{baseUrl => <<"https://openrouter.ai/api/v1/chat/completions">>,
      model => <<"openai/gpt-4o-mini">>};
providerDefaults(siliconflow) ->
    #{baseUrl => <<"https://api.siliconflow.cn/v1/chat/completions">>,
      model => <<"Qwen/Qwen2.5-7B-Instruct">>};
providerDefaults(oneapi) ->
    #{baseUrl => <<"http://localhost:3000/v1/chat/completions">>,
      model => <<"gpt-4o-mini">>};
%% 本地推理服务：OpenAI 兼容端点，apiKey 允许缺省（占位 none）。
%% baseUrl 均为本地地址，buildChatUrl 会自动追加 /chat/completions。
providerDefaults(ollama) ->
    #{baseUrl => <<"http://127.0.0.1:11434/v1">>};
providerDefaults(llamaCpp) ->
    #{baseUrl => <<"http://127.0.0.1:8080/v1">>};
providerDefaults(llamacpp) ->
    providerDefaults(llamaCpp);
providerDefaults(vllm) ->
    #{baseUrl => <<"http://127.0.0.1:8000/v1">>};
providerDefaults(lmstudio) ->
    #{baseUrl => <<"http://127.0.0.1:1234/v1">>};
providerDefaults(lmStudio) ->
    providerDefaults(lmstudio);
%% Google Gemini：官方 OpenAI 兼容端点（Bearer + /chat/completions）。
providerDefaults(gemini) ->
    #{baseUrl => <<"https://generativelanguage.googleapis.com/v1beta/openai">>,
      model => <<"gemini-3.8-flash">>};
providerDefaults(google) ->
    providerDefaults(gemini);
providerDefaults(_) ->
    #{}.

%% 列出所有已支持的 provider 名称（用于 CLI / 文档 / 健康检查）。
-spec listProviders() -> [atom()].
listProviders() ->
    [anthropic, openai, deepseek, qwen, dashscope, glm, zhipu, ernie, qianfan,
     doubao, ark, kimi, moonshot, openrouter, siliconflow, oneapi,
     ollama, llamaCpp, vllm, lmstudio, gemini, google].

%%--------------------------------------------------------------------
%% @doc
%% Embedding provider 默认值表：同 chat，但 endpoint 改成 `/embeddings'，
%% model 用各 provider 的 text-embedding 系列。`inherit' 表示复用
%% llm.apiKey；用户可显式覆盖 baseUrl/model。
%%
%% @param Provider provider atom
%% @return 含 baseUrl / model 的 map（缺省为空）
%% @end
%%--------------------------------------------------------------------
-spec embeddingDefaults(atom()) -> map().
embeddingDefaults(openai) ->
    #{baseUrl => <<"https://api.openai.com/v1/embeddings">>,
      model => <<"text-embedding-3-small">>};
embeddingDefaults(deepseek) ->
    %% DeepSeek 无 embedding 端点
    #{};
embeddingDefaults(qwen) ->
    #{baseUrl => <<"https://dashscope.aliyuncs.com/api/v1/services/embeddings/text-embedding/text-embedding">>,
      model => <<"text-embedding-v3">>};
embeddingDefaults(glm) ->
    #{baseUrl => <<"https://open.bigmodel.cn/api/paas/v4/embeddings">>,
      model => <<"embedding-2">>};
embeddingDefaults(zhipu) ->
    #{baseUrl => <<"https://open.bigmodel.cn/api/paas/v4/embeddings">>,
      model => <<"embedding-2">>};
embeddingDefaults(ernie) ->
    #{baseUrl => <<"https://aip.baidubce.com/rpc/2.0/ai_custom/v1/wenxinworkshop/embeddings">>,
      model => <<"embedding-v1">>};
embeddingDefaults(qianfan) ->
    #{baseUrl => <<"https://aip.baidubce.com/rpc/2.0/ai_custom/v1/wenxinworkshop/embeddings">>,
      model => <<"embedding-v1">>};
embeddingDefaults(doubao) ->
    #{baseUrl => <<"https://ark.cn-beijing.volces.com/api/v3/embeddings">>,
      model => <<"doubao-embedding-text-240715">>};
embeddingDefaults(ark) ->
    #{baseUrl => <<"https://ark.cn-beijing.volces.com/api/v3/embeddings">>,
      model => <<"doubao-embedding-text-240715">>};
embeddingDefaults(kimi) ->
    %% Moonshot 暂未对外开放 embeddings
    #{};
embeddingDefaults(moonshot) ->
    #{};
embeddingDefaults(openrouter) ->
    #{baseUrl => <<"https://openrouter.ai/api/v1/embeddings">>,
      model => <<"openai/text-embedding-3-small">>};
embeddingDefaults(siliconflow) ->
    #{baseUrl => <<"https://api.siliconflow.cn/v1/embeddings">>,
      model => <<"BAAI/bge-m3">>};
embeddingDefaults(oneapi) ->
    #{baseUrl => <<"http://localhost:3000/v1/embeddings">>,
      model => <<"text-embedding-3-small">>};
embeddingDefaults(_) ->
    #{}.

%%--------------------------------------------------------------------
%% @doc
%% Rerank provider 默认值表：仅支持暴露 rerank 端点的 provider；
%% DeepSeek / Moonshot / OpenAI / Anthropic 暂不支持，列空 map
%% 让用户显式 cfg。
%%
%% @param Provider provider atom
%% @return 含 baseUrl / model 的 map
%% @end
%%--------------------------------------------------------------------
-spec rerankDefaults(atom()) -> map().
rerankDefaults(qwen) ->
    #{baseUrl => <<"https://dashscope.aliyuncs.com/api/v1/services/rerank/text-rerank/text-rerank">>,
      model => <<"gte-rerank">>};
rerankDefaults(siliconflow) ->
    #{baseUrl => <<"https://api.siliconflow.cn/v1/rerank">>,
      model => <<"BAAI/bge-reranker-v2-m3">>};
rerankDefaults(glm) ->
    #{baseUrl => <<"https://open.bigmodel.cn/api/paas/v4/rerank">>,
      model => <<"rerank">>};
rerankDefaults(zhipu) ->
    #{baseUrl => <<"https://open.bigmodel.cn/api/paas/v4/rerank">>,
      model => <<"rerank">>};
rerankDefaults(oneapi) ->
    #{baseUrl => <<"http://localhost:3000/v1/rerank">>,
      model => <<"bge-reranker-v2-m3">>};
rerankDefaults(openrouter) ->
    #{baseUrl => <<"https://openrouter.ai/api/v1/rerank">>,
      model => <<"cohere/rerank-english-v3.0">>};
rerankDefaults(_) ->
    #{}.

%%--------------------------------------------------------------------
%% @doc
%% 解析 embedding 完整配置：合并 {embedding.{apiKey, baseUrl, model}} +
%% provider 默认。apiKey=inherit 时复用 llm.apiKey。
%%
%% @param Opts 调用选项
%% @return 含 provider/apiKey/baseUrl/model 的 map（可能缺字段表示未启用）
%% @end
%%--------------------------------------------------------------------
-spec embeddingConfig(map()) -> map().
embeddingConfig(Opts) ->
    Env = alConfig:get(embedding, #{}),
    Provider = firstDefined([
        maps:get(embeddingProvider, Opts, undefined),
        maps:get(provider, Env, undefined),
        maps:get(provider, alConfig:get(llm, #{}), undefined),
        openai
    ]),
    Defaults = embeddingDefaults(Provider),
    Llm = alConfig:get(llm, #{}),
    ApiKey = case firstDefined([maps:get(apiKey, Env, undefined)]) of
        inherit -> maps:get(apiKey, Llm, undefined);
        K -> K
    end,
    #{
        provider => Provider,
        apiKey => firstDefined([maps:get(apiKey, Opts, undefined), ApiKey]),
        baseUrl => firstDefined([
            maps:get(baseUrl, Opts, undefined),
            maps:get(baseUrl, Env, undefined),
            maps:get(baseUrl, Defaults, undefined)
        ]),
        model => firstDefined([
            maps:get(model, Opts, undefined),
            maps:get(model, Env, undefined),
            maps:get(model, Defaults, undefined)
        ])
    }.

%%--------------------------------------------------------------------
%% @doc
%% 解析 rerank 完整配置：合并 {rerank.{apiKey, baseUrl, model}} + provider
%% 默认 + inherit 复用 llm.apiKey。
%%
%% @param Opts 调用选项
%% @return 含 provider/apiKey/baseUrl/model 的 map
%% @end
%%--------------------------------------------------------------------
-spec rerankConfig(map()) -> map().
rerankConfig(Opts) ->
    Env = alConfig:get(rerank, #{}),
    Provider = firstDefined([
        maps:get(rerankProvider, Opts, undefined),
        maps:get(provider, Env, undefined),
        maps:get(provider, alConfig:get(llm, #{}), undefined),
        openai
    ]),
    Defaults = rerankDefaults(Provider),
    Llm = alConfig:get(llm, #{}),
    ApiKey = case firstDefined([maps:get(apiKey, Env, undefined)]) of
        inherit -> maps:get(apiKey, Llm, undefined);
        K -> K
    end,
    #{
        provider => Provider,
        apiKey => firstDefined([maps:get(apiKey, Opts, undefined), ApiKey]),
        baseUrl => firstDefined([
            maps:get(baseUrl, Opts, undefined),
            maps:get(baseUrl, Env, undefined),
            maps:get(baseUrl, Defaults, undefined)
        ]),
        model => firstDefined([
            maps:get(model, Opts, undefined),
            maps:get(model, Env, undefined),
            maps:get(model, Defaults, undefined)
        ])
    }.

-spec providerFromOpts(map()) -> atom().
%%--------------------------------------------------------------------
%% @doc
%% 从 Opts/env 解析 provider atom（测试用助手）。
%% llmConfig 故意不默认 openai；路由侧缺省时回退 openai-compatible。
%%
%% @param Opts 调用选项
%% @return atom()
%% @end
%%--------------------------------------------------------------------
providerFromOpts(Opts) ->
    case maps:get(provider, llmConfig(Opts), undefined) of
        undefined -> openai;
        P -> P
    end.

%%--------------------------------------------------------------------
%% @doc
%% 解析最大重试次数：优先 Opts.llmMaxRetries，其次 env.maxRetries，
%% 默认 3。
%%
%% @param Opts 调用选项
%% @return non_neg_integer()
%% @end
%%--------------------------------------------------------------------
llmMaxRetries(Opts) ->
    Env = alConfig:get(llm, #{}),
    firstDefined([
        maps:get(llmMaxRetries, Opts, undefined),
        maps:get(maxRetries, Env, undefined),
        3
    ]).

%%--------------------------------------------------------------------
%% @doc
%% 解析请求接收超时（毫秒）。
%% 优先级：Opts.llmRecvTimeout > Opts.execTimeout > modelEntry.execTimeout
%% > llm.recvTimeout > llm.execTimeout > chain 首项.execTimeout > 30000。
%% 注意：chain 项里的 execTimeout 不会自动出现在 llm 顶层，必须经
%% applyModelChain/mergeEntryOpts 或下面的 chain 兜底才能生效。
%% @end
%%--------------------------------------------------------------------
llmRecvTimeout(Opts) ->
    Env = alConfig:get(llm, #{}),
    Entry = case maps:get(modelEntry, Opts, undefined) of
        M when is_map(M) -> M;
        _ -> #{}
    end,
    ChainHead = case maps:get(chain, Env, []) of
        [H | _] when is_map(H) -> H;
        _ -> #{}
    end,
    firstDefined([
        maps:get(llmRecvTimeout, Opts, undefined),
        maps:get(execTimeout, Opts, undefined),
        maps:get(execTimeout, Entry, undefined),
        maps:get(recvTimeout, Env, undefined),
        maps:get(execTimeout, Env, undefined),
        maps:get(execTimeout, ChainHead, undefined),
        30000
    ]).

%% connect_timeout：避免 DNS/TLS 握手无限挂起。
%% 回环地址（本地 LLM）用短超时，连不上立刻升云，少打 CRASH REPORT。
llmConnectTimeout(Opts) ->
    Recv = llmRecvTimeout(Opts),
    Default = case isLoopbackBaseUrl(Opts) of
        true -> 1500;
        false -> min(10000, Recv)
    end,
    firstDefined([
        maps:get(llmConnectTimeout, Opts, undefined),
        maps:get(connectTimeout, Opts, undefined),
        Default
    ]).

isLoopbackBaseUrl(Opts) when is_map(Opts) ->
    isLoopbackUrl(maps:get(baseUrl, Opts,
        maps:get(<<"baseUrl">>, Opts, undefined)));
isLoopbackBaseUrl(_) ->
    false.

isLoopbackUrl(Url) when is_binary(Url) ->
    case re:run(Url,
                <<"^https?://(127\\.0\\.0\\.1|localhost|\\[::1\\])([:/]|$)">>,
                [caseless, {capture, none}]) of
        match -> true;
        nomatch -> false
    end;
isLoopbackUrl(Url) when is_list(Url) ->
    isLoopbackUrl(unicode:characters_to_binary(Url));
isLoopbackUrl(_) ->
    false.

%%--------------------------------------------------------------------
%% @doc
%% 根据 provider 分发到 anthropicPostChat 或 openaiPostChat。
%%
%% @param BaseUrl  API base URL
%% @param ApiKey   API key
%% @param Model    模型名
%% @param Messages 消息列表
%% @param Tools    工具规格
%% @param Opts     调用选项
%% @return {ok, Result} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
postChat(BaseUrl0, ApiKey0, Model0, Messages, Tools, Opts) ->
    Provider = providerFromOpts(Opts),
    case Provider of
        anthropic ->
            anthropicPostChat(BaseUrl0, ApiKey0, Model0, Messages, Tools, Opts);
        _ ->
            openaiPostChat(BaseUrl0, ApiKey0, Model0, Messages, Tools, Opts)
    end.

-spec buildChatUrl(binary(), atom()) -> binary().
%%--------------------------------------------------------------------
%% @doc
%% 按 provider 构造 chat 端点 URL。Anthropic 用 `/messages'，其他用
%% `/chat/completions'。若 baseUrl 已包含端点（旧版 DeepSeek 默认），
%% 则不再追加。
%%
%% @param BaseUrl  API base URL
%% @param Provider 提供商 atom
%% @return 完整端点 URL binary
%% @end
%%--------------------------------------------------------------------
buildChatUrl(BaseUrl, Provider) ->
    BinUrl = toBinary(BaseUrl),
    Endpoint = case Provider of
        anthropic -> <<"/messages">>;
        _ -> <<"/chat/completions">>
    end,
    %% If the caller already baked the endpoint into baseUrl (legacy
    %% DeepSeek default), avoid duplicating it.
    case binary:match(BinUrl, Endpoint) of
        nomatch -> <<BinUrl/binary, Endpoint/binary>>;
        _ -> BinUrl
    end.

%%--------------------------------------------------------------------
%% @doc
%% OpenAI 兼容 chat 请求实现。先对不支持视觉的模型降级多模态消息，
%% 构造请求体后用 eWCli/alHttp 同步发起请求；2xx 解析响应，其他状态码
%% 返回 `{error, #{status, body}}'。
%%
%% @param BaseUrl  API base URL
%% @param ApiKey   API key
%% @param Model    模型名
%% @param Messages 消息列表
%% @param Tools    工具规格
%% @param Opts     调用选项
%% @return {ok, Result} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
openaiPostChat(BaseUrl0, ApiKey0, Model0, Messages, Tools, Opts) ->
    Url = buildChatUrl(BaseUrl0, openai),
    ApiKey = toBinary(ApiKey0),
    Model = toBinary(Model0),
    Provider = providerFromOpts(Opts),
    SafeMessages = sanitizeMessagesForVision(Messages, Provider, Model, Opts),
    Body = encodeChatBody(Model, SafeMessages, Tools, Opts#{provider => Provider}),
    Headers = [
        {<<"authorization">>, <<"Bearer ", ApiKey/binary>>},
        {<<"content-type">>, <<"application/json">>}
    ],
    Timeout = llmRecvTimeout(Opts),
    Connect = llmConnectTimeout(Opts),
    case httpRequest(post, Url, Headers, Body,
                     [{recv_timeout, Timeout}, {connect_timeout, Connect}], Opts) of
        {ok, Code, _RespHeaders, RespBody} when Code >= 200, Code < 300 ->
            case responseBody(RespBody) of
                {ok, Bin} -> parseChatResponse(Bin);
                {error, _} -> {error, bodyFetchFailed}
            end;
        {ok, Code, _RespHeaders, RespBody} ->
            Bin = case responseBody(RespBody) of
                {ok, B} -> B;
                {error, _} -> <<>>
            end,
            {error, #{status => Code, body => Bin}};
        {error, Reason} ->
            {error, Reason}
    end.

%% 可注入的 HTTP 请求入口：Opts 含 `httpRequestFun` 时用于测试 mock，
%% 签名为 `(Method, Url, Headers, Body, Opts) -> {ok, Code, Headers, Body}'
%% （Body 为 binary 或 `{mockBody, Bin}`）。
%% 连接池/ALPN 默认开启，见 llmHttpTransportOpts/1。
httpRequest(Method, Url, Headers, Body, HttpOpts, Opts) ->
    case maps:get(httpRequestFun, Opts, undefined) of
        Fun when is_function(Fun, 5) ->
            Fun(Method, Url, Headers, Body, HttpOpts);
        _ ->
            %% 超时等来自 HttpOpts；池/ALPN 以 llmHttpTransportOpts 为准（后者覆盖）。
            OptsMap = maps:merge(alHttpOptsToMap(HttpOpts), llmHttpTransportOpts(Opts)),
            try alHttp:request(Method, Url, Headers, Body, OptsMap) of
                Result -> Result
            catch
                exit:Reason -> {error, {httpExit, Reason}};
                error:Reason -> {error, {httpError, Reason}}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% LLM HTTP 传输选项：连接池 + ALPN + 协议。
%% 优先级：Opts > llm.http.* > 默认 usePool=true, alpn=true, protocol=tcp。
%%
%% protocol 默认 tcp：禁用 Alt-Svc 自动升 HTTP/3。云厂商常下发 h3 Alt-Svc，
%% 但 QUIC/UDP 在不少网络不通，探测失败会刷 CRASH REPORT 并拖慢首包。
%% 需要 H3 时在 aliCfg.cfg 设 `http => #{protocol => auto}`。
%% @end
%%--------------------------------------------------------------------
-spec llmHttpTransportOpts(map()) -> map().
llmHttpTransportOpts(Opts) when is_map(Opts) ->
    Env = alConfig:get(llm, #{}),
    Http = case maps:get(http, Env, #{}) of
        M when is_map(M) -> M;
        _ -> #{}
    end,
    %% 注意：不可用 firstDefined（会跳过 false）。
    UsePool = pickBoolOpt([
        maps:find(httpUsePool, Opts),
        maps:find(usePool, Opts),
        maps:find(usePool, Http)
    ], true),
    Alpn = pickBoolOpt([
        maps:find(httpAlpn, Opts),
        maps:find(alpn, Opts),
        maps:find(alpn, Http)
    ], true),
    Protocol = firstDefined([
        maps:get(httpProtocol, Opts, undefined),
        maps:get(protocol, Opts, undefined),
        maps:get(protocol, Http, undefined),
        tcp
    ]),
    #{usePool => UsePool, alpn => Alpn, protocol => Protocol};
llmHttpTransportOpts(_) ->
    #{usePool => true, alpn => true, protocol => tcp}.

%% 取第一个已定义的布尔值；true/false 均有效（与 firstDefined 不同）。
pickBoolOpt([{ok, true} | _], _) -> true;
pickBoolOpt([{ok, false} | _], _) -> false;
pickBoolOpt([{ok, _} | Rest], Default) -> pickBoolOpt(Rest, Default);
pickBoolOpt([error | Rest], Default) -> pickBoolOpt(Rest, Default);
pickBoolOpt([], Default) -> Default.

alHttpOptsToMap(List) when is_list(List) ->
    lists:foldl(fun
        ({recv_timeout, V}, Acc) -> Acc#{recvTimeout => V};
        ({connect_timeout, V}, Acc) -> Acc#{connectTimeout => V};
        ({ssl_options, V}, Acc) -> Acc#{sslOpts => V};
        ({pool, false}, Acc) -> Acc#{usePool => false};
        ({pool, true}, Acc) -> Acc#{usePool => true};
        ({K, V}, Acc) when is_atom(K) -> Acc#{K => V};
        (_, Acc) -> Acc
    end, #{}, List);
alHttpOptsToMap(Map) when is_map(Map) ->
    Map;
alHttpOptsToMap(_) ->
    #{}.

%%--------------------------------------------------------------------
%% @doc
%% Anthropic Messages API chat 请求实现。先降级多模态消息，构造
%% Anthropic 请求体与请求头，发起请求；2xx 解析 Anthropic 响应，
%% 其他状态码返回错误。
%%
%% @param BaseUrl  API base URL
%% @param ApiKey   API key
%% @param Model    模型名
%% @param Messages 消息列表
%% @param Tools    工具规格
%% @param Opts     调用选项
%% @return {ok, Result} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
anthropicPostChat(BaseUrl0, ApiKey0, Model0, Messages, Tools, Opts) ->
    Url = buildChatUrl(BaseUrl0, anthropic),
    ApiKey = toBinary(ApiKey0),
    Model = toBinary(Model0),
    SafeMessages = sanitizeMessagesForVision(Messages, anthropic, Model, Opts),
    Body = anthropicRequestBody(Model, SafeMessages, Tools, Opts),
    Headers = anthropicHeaders(ApiKey),
    Timeout = llmRecvTimeout(Opts),
    Connect = llmConnectTimeout(Opts),
    case httpRequest(post, Url, Headers, Body,
                     [{recv_timeout, Timeout}, {connect_timeout, Connect}], Opts) of
        {ok, Code, _RespHeaders, RespBody} when Code >= 200, Code < 300 ->
            case responseBody(RespBody) of
                {ok, Bin} -> parseAnthropicResponse(Bin);
                {error, _} -> {error, bodyFetchFailed}
            end;
        {ok, Code, _RespHeaders, RespBody} ->
            Bin = case responseBody(RespBody) of
                {ok, B} -> B;
                {error, _} -> <<>>
            end,
            {error, #{status => Code, body => Bin}};
        {error, Reason} ->
            {error, Reason}
    end.

%% 取响应体。兼容 binary 与测试注入 `{mockBody, Bin}`。
responseBody({mockBody, Bin}) when is_binary(Bin) ->
    {ok, Bin};
responseBody(Body) when is_binary(Body) ->
    {ok, Body};
responseBody(_) ->
    {error, bodyFetchFailed}.

%%--------------------------------------------------------------------
%% @doc
%% 解析 OpenAI 兼容 chat 响应。提取消息/内容/工具调用/usage，
%% 调用 maybeTrackUsage 记录 token 用量，返回标准化 map。
%% 解析失败时把原始响应体作为 content 包进结果。
%%
%% @param RespBody 响应体二进制
%% @return {ok, map()}
%% @end
%%--------------------------------------------------------------------
parseChatResponse(RespBody) ->
    try alJson:decode(RespBody) of
        Decoded ->
            Message = extractMessage(Decoded),
            case Message of
                {ok, Msg} ->
                    maybeTrackUsage(Decoded, maps:get(<<"model">>, Decoded, undefined)),
                    Reply0 = #{
                        provider => openaiCompatible,
                        message => Msg,
                        content => maps:get(content, Msg, undefined),
                        tool_calls => maps:get(tool_calls, Msg, []),
                        model => maps:get(<<"model">>, Decoded, undefined),
                        usage => maps:get(<<"usage">>, Decoded, undefined),
                        raw => RespBody
                    },
                    {ok, case maps:get(reasoning_content, Msg, undefined) of
                        undefined -> Reply0;
                        RC -> Reply0#{reasoning_content => RC}
                    end};
                {error, Reason} ->
                    {ok, #{
                        provider => openaiCompatible,
                        content => RespBody,
                        raw => RespBody,
                        tool_calls => [],
                        parseWarning => Reason
                    }}
            end
    catch
        _:_ ->
            {ok, #{
                provider => openaiCompatible,
                content => RespBody,
                raw => RespBody,
                tool_calls => []
            }}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 从响应 map 中提取第一条 choice 的 message，并标准化。无 choices
%% 或 message 时返回对应错误。
%%
%% @param Decoded 响应 map
%% @return {ok, Msg} | {error, noMessage | noChoices}
%% @end
%%--------------------------------------------------------------------
extractMessage(#{<<"choices">> := [First | _]}) ->
    case maps:get(<<"message">>, First, undefined) of
        undefined ->
            {error, noMessage};
        Msg ->
            {ok, normalizeMessage(Msg)}
    end;
extractMessage(_) ->
    {error, noChoices}.

%%--------------------------------------------------------------------
%% @doc
%% 标准化 OpenAI 消息 map：补全 role（默认 assistant）、content（默认 null）、
%% tool_calls（经 normalizeToolCalls 处理）。
%%
%% @param Msg 原始消息 map
%% @return 标准化后的 map
%% @end
%%--------------------------------------------------------------------
normalizeMessage(Msg) ->
    Content0 = maps:get(<<"content">>, Msg, null),
    Structured = normalizeToolCalls(maps:get(<<"tool_calls">>, Msg, [])),
    {Content, ToolCalls} = case Structured of
        [] ->
            {C, Recovered} = alDsmlTools:recoverFromContent(Content0),
            {C, Recovered};
        _ ->
            {Content0, Structured}
    end,
    Base = #{
        role => maps:get(<<"role">>, Msg, <<"assistant">>),
        content => Content,
        tool_calls => ToolCalls
    },
    case extractReasoningContent(Msg) of
        undefined -> Base;
        RC -> Base#{reasoning_content => RC}
    end.

%% 抽取 thinking / reasoning 字段（DeepSeek 等兼容协议）。
extractReasoningContent(Msg) when is_map(Msg) ->
    case maps:get(<<"reasoning_content">>, Msg,
                  maps:get(reasoning_content, Msg, undefined)) of
        undefined ->
            case maps:get(<<"reasoning">>, Msg,
                          maps:get(reasoning, Msg, undefined)) of
                R when is_binary(R) -> R;
                R when is_list(R) -> unicode:characters_to_binary(R);
                _ -> undefined
            end;
        null -> <<>>;
        R when is_binary(R) -> R;
        R when is_list(R) -> unicode:characters_to_binary(R);
        _ -> undefined
    end;
extractReasoningContent(_) ->
    undefined.

%% 空列表原样返回
normalizeToolCalls([]) ->
    [];
%% 列表逐项标准化
normalizeToolCalls(Calls) when is_list(Calls) ->
    [normalizeToolCall(Call) || Call <- Calls];
%% 非列表一律视为空
normalizeToolCalls(_) ->
    [].

%%--------------------------------------------------------------------
%% @doc
%% 标准化单个 tool_call：提取 id/type/function.{name,arguments}，
%% 缺失字段补默认值（type 默认 function，arguments 默认 "{}"）。
%%
%% @param Call 原始 tool_call
%% @return 标准化后的 map
%% @end
%%--------------------------------------------------------------------
normalizeToolCall(Call) ->
    Function = maps:get(<<"function">>, Call, #{}),
    #{
        id => normalizeToolCallId(maps:get(<<"id">>, Call, undefined)),
        type => maps:get(<<"type">>, Call, <<"function">>),
        function => #{
            name => maps:get(<<"name">>, Function, undefined),
            arguments => maps:get(<<"arguments">>, Function, <<"{}">>)
        }
    }.

%% 缺失/空 id 时生成占位 id（部分 provider 省略 tool_call id，
%% 但后续 tool 消息需要 tool_call_id 才能对齐）。
normalizeToolCallId(Id) when is_binary(Id), Id =/= <<>> -> Id;
normalizeToolCallId(Id) when is_list(Id), Id =/= [] -> iolist_to_binary(Id);
normalizeToolCallId(_) -> generatePlaceholderId().

%% 生成形如 `call_<hex>' 的随机占位 id。
generatePlaceholderId() ->
    Rand = integer_to_binary(erlang:unique_integer([positive, monotonic]), 16),
    <<"call_", Rand/binary>>.

%%--------------------------------------------------------------------
%% @doc
%% 手工编码 OpenAI 兼容 chat 请求体（避免 alJson 对大对象的
%% 性能开销）。包含 model、messages、可选 tools 段。
%%
%% @param Model    模型名
%% @param Messages 消息列表
%% @param Tools    工具规格列表
%% @return 二进制 JSON 请求体
%% @end
%%--------------------------------------------------------------------
encodeChatBody(Model, Messages, Tools) ->
    encodeChatBody(Model, Messages, Tools, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 手工编码 OpenAI 兼容 chat 请求体（带可选参数）。除 model/messages/
%% tools 外，按需从 Opts 注入：
%%  - `stream => true'  → `"stream":true' + `"stream_options":{"include_usage":true}'
%%  - `temperature' / `top_p'（number）
%%  - `max_tokens'（正整数）
%%  - `response_format'（map / `json_object' / binary type 名）
%%
%% @param Model    模型名
%% @param Messages 消息列表
%% @param Tools    工具规格列表
%% @param Opts     调用选项
%% @return 二进制 JSON 请求体
%% @end
%%--------------------------------------------------------------------
encodeChatBody(Model, Messages, Tools, Opts) ->
    ToolsPart = case Tools of
        [] -> <<>>;
        _ ->
            EncodedTools = joinBin([encodeTool(Tool) || Tool <- Tools], <<",">>),
            <<",\"tools\":[", EncodedTools/binary, "]">>
    end,
    Prepared = prepareMessagesForChat(Messages),
    EncodedMsgs = joinBin([encodeMessage(Message) || Message <- Prepared], <<",">>),
    ModelBin = jsonString(Model),
    ExtraPart = encodeChatExtras(Opts),
    <<"{\"model\":", ModelBin/binary, ",\"messages\":[", EncodedMsgs/binary, "]",
      ToolsPart/binary, ExtraPart/binary, "}">>.

%% 构造 OpenAI body 的可选字段片段（stream / 采样 / response_format /
%% thinking / tool_choice）。tool_choice 缺省时不写入（与 Anthropic
%% 路径「有 tools 才强制 auto」不同：OpenAI 兼容端默认即为 auto）。
encodeChatExtras(Opts) ->
    StreamPart = case maps:get(stream, Opts, false) of
        true -> <<",\"stream\":true,\"stream_options\":{\"include_usage\":true}">>;
        _ -> <<>>
    end,
    Temp = numberField(<<"temperature">>, maps:get(temperature, Opts, undefined)),
    TopP = numberField(<<"top_p">>, maps:get(top_p, Opts, undefined)),
    %% 同时接受项目配置惯用的 maxTokens 与 OpenAI 原名 max_tokens。
    %% 默认上限防止本地模型陷入重复生成直至网络超时；本地运行时
    %% （ollama/llama.cpp）默认 num_predict=-1 不设限，这里给足余量。
    MaxTokens0 = firstDefined([
        maps:get(max_tokens, Opts, undefined),
        maps:get(maxTokens, Opts, undefined),
        maps:get(max_tokens, alConfig:get(llm, #{}), undefined),
        maps:get(maxTokens, alConfig:get(llm, #{}), undefined),
        8192
    ]),
    MaxTokens = positiveIntField(<<"max_tokens">>, MaxTokens0),
    RespFmt = responseFormatField(maps:get(response_format, Opts, undefined)),
    Thinking = begin
        ThinkingProvider = providerFromOpts(Opts),
        thinkingField(ThinkingProvider, resolveThinking(Opts),
                      resolveThinkingBudget(ThinkingProvider, Opts))
    end,
    Effort = reasoningEffortField(maps:get(reasoning_effort, Opts,
                 maps:get(reasoningEffort, Opts,
                 maps:get(reasoning_effort, alConfig:get(llm, #{}),
                 maps:get(reasoningEffort, alConfig:get(llm, #{}), undefined))))),
    ToolChoice = toolChoiceField(maps:get(tool_choice, Opts,
                     maps:get(toolChoice, Opts, undefined))),
    <<StreamPart/binary, Temp/binary, TopP/binary, MaxTokens/binary,
      RespFmt/binary, Thinking/binary, Effort/binary, ToolChoice/binary>>.

%% OpenAI 风格 tool_choice：auto | none | required | {tool,Name} | 函数名。
toolChoiceField(undefined) -> <<>>;
toolChoiceField(auto) -> <<",\"tool_choice\":\"auto\"">>;
toolChoiceField(none) -> <<",\"tool_choice\":\"none\"">>;
toolChoiceField(required) -> <<",\"tool_choice\":\"required\"">>;
toolChoiceField(<<"auto">>) -> toolChoiceField(auto);
toolChoiceField(<<"none">>) -> toolChoiceField(none);
toolChoiceField(<<"required">>) -> toolChoiceField(required);
toolChoiceField("auto") -> toolChoiceField(auto);
toolChoiceField("none") -> toolChoiceField(none);
toolChoiceField("required") -> toolChoiceField(required);
toolChoiceField({tool, Name}) ->
    NameBin = jsonString(toBinary(Name)),
    <<",\"tool_choice\":{\"type\":\"function\",\"function\":{\"name\":",
      NameBin/binary, "}}">>;
toolChoiceField(#{<<"type">> := <<"function">>, <<"function">> := #{<<"name">> := Name}}) ->
    toolChoiceField({tool, Name});
toolChoiceField(#{type := function, function := #{name := Name}}) ->
    toolChoiceField({tool, Name});
toolChoiceField(Name) when is_binary(Name); is_list(Name); is_atom(Name) ->
    toolChoiceField({tool, Name});
toolChoiceField(_) -> <<>>.

%% DeepSeek V4 等：thinking 默认开会导致极慢。优先 Opts，其次 llm.thinking。
resolveThinking(Opts) when is_map(Opts) ->
    case maps:get(thinking, Opts, undefined) of
        undefined -> maps:get(thinking, alConfig:get(llm, #{}), undefined);
        V -> V
    end;
resolveThinking(_) ->
    maps:get(thinking, alConfig:get(llm, #{}), undefined).

%% 百炼/通义用 enable_thinking；DeepSeek 与智谱 GLM（4.5+）用 thinking.type。
%% Gemini / OpenAI 等官方兼容层不认识这两个字段，切勿下发。
usesEnableThinking(qwen) -> true;
usesEnableThinking(dashscope) -> true;
usesEnableThinking(<<"qwen">>) -> true;
usesEnableThinking(<<"dashscope">>) -> true;
usesEnableThinking("qwen") -> true;
usesEnableThinking("dashscope") -> true;
usesEnableThinking(_) -> false.

usesThinkingType(deepseek) -> true;
usesThinkingType(<<"deepseek">>) -> true;
usesThinkingType("deepseek") -> true;
%% 智谱 GLM（open.bigmodel.cn）：thinking 对象为 {type, budget}。
%% 实测 glm-5.3-flash：type=enabled 接受；type=disabled 返回 1210
%% 「该模型始终思考，不支持关闭思考」——因此对该厂 disabled 一律
%% 不下发字段（保持服务端默认），只下发 enabled + 可选 budget。
usesThinkingType(glm) -> true;
usesThinkingType(zhipu) -> true;
usesThinkingType(<<"glm">>) -> true;
usesThinkingType(<<"zhipu">>) -> true;
usesThinkingType("glm") -> true;
usesThinkingType("zhipu") -> true;
usesThinkingType(_) -> false.

%% 编码思考开关：仅对支持的 provider 写入；其余省略。
%% 智谱 GLM：enabled → {"type":"enabled"}（可带 budget）；disabled →
%% 不下发（始终思考模型对 disabled 报 400，见 usesThinkingType/1 注释）。
%% thinkingBudget（low|high|max）仅 GLM 路径生效，其余 provider 忽略。
thinkingField(_Provider, undefined, _Budget) -> <<>>;
thinkingField(Provider, Mode, Budget) ->
    Norm = normalizeThinkingMode(Mode),
    case {usesEnableThinking(Provider), usesThinkingType(Provider), Norm} of
        {true, _, enabled} -> <<",\"enable_thinking\":true">>;
        {true, _, disabled} -> <<",\"enable_thinking\":false">>;
        {false, true, enabled} ->
            <<",\"thinking\":", (thinkingTypeObj(Provider, Budget))/binary>>;
        {false, true, disabled} ->
            case isZhipuFamily(Provider) of
                true -> <<>>;
                false -> <<",\"thinking\":{\"type\":\"disabled\"}">>
            end;
        _ -> <<>>
    end.

%% 智谱 GLM thinking 对象：enabled + 可选 budget（low/high/max）。
%% budget=none 表示显式不带 budget 字段（用服务端默认深度）。
thinkingTypeObj(_Provider, Budget) when Budget =:= low;
                                        Budget =:= high;
                                        Budget =:= max ->
    B = atom_to_binary(Budget, utf8),
    <<"{\"type\":\"enabled\",\"budget\":\"", B/binary, "\"}">>;
thinkingTypeObj(_Provider, _) ->
    <<"{\"type\":\"enabled\"}">>.

isZhipuFamily(Provider) ->
    lists:member(string:lowercase(toBinary(Provider)),
                 [<<"glm">>, <<"zhipu">>]).

%% 解析 thinkingBudget：仅智谱系返回 low|high|max，其他 provider 返回
%% undefined（budget 字段不认识，不下发）。none 表示显式不带 budget。
resolveThinkingBudget(Provider, Opts) when is_map(Opts) ->
    case isZhipuFamily(Provider) of
        false -> undefined;
        true ->
            Env = alConfig:get(llm, #{}),
            normalizeBudget(firstDefined([
                maps:get(thinkingBudget, Opts, undefined),
                maps:get(<<"thinkingBudget">>, Opts, undefined),
                maps:get(thinkingBudget, Env, undefined)
            ]))
    end;
resolveThinkingBudget(_, _) ->
    undefined.

normalizeBudget(low) -> low;
normalizeBudget(high) -> high;
normalizeBudget(max) -> max;
normalizeBudget(none) -> none;
normalizeBudget(<<"low">>) -> low;
normalizeBudget(<<"high">>) -> high;
normalizeBudget(<<"max">>) -> max;
normalizeBudget(<<"none">>) -> none;
normalizeBudget("low") -> low;
normalizeBudget("high") -> high;
normalizeBudget("max") -> max;
normalizeBudget("none") -> none;
normalizeBudget(_) -> undefined.

normalizeThinkingMode(enabled) -> enabled;
normalizeThinkingMode(disabled) -> disabled;
normalizeThinkingMode(true) -> enabled;
normalizeThinkingMode(false) -> disabled;
normalizeThinkingMode(<<"enabled">>) -> enabled;
normalizeThinkingMode(<<"disabled">>) -> disabled;
normalizeThinkingMode("enabled") -> enabled;
normalizeThinkingMode("disabled") -> disabled;
normalizeThinkingMode(#{type := Type}) -> normalizeThinkingMode(Type);
normalizeThinkingMode(#{<<"type">> := Type}) -> normalizeThinkingMode(Type);
normalizeThinkingMode(_) -> undefined.

reasoningEffortField(undefined) -> <<>>;
reasoningEffortField(high) -> <<",\"reasoning_effort\":\"high\"">>;
reasoningEffortField(max) -> <<",\"reasoning_effort\":\"max\"">>;
reasoningEffortField(<<"high">>) -> reasoningEffortField(high);
reasoningEffortField(<<"max">>) -> reasoningEffortField(max);
reasoningEffortField("high") -> reasoningEffortField(high);
reasoningEffortField("max") -> reasoningEffortField(max);
reasoningEffortField(_) -> <<>>.

%% 数值字段（temperature/top_p）：非数值忽略。
numberField(_Key, undefined) -> <<>>;
numberField(Key, V) when is_integer(V) ->
    <<",\"", Key/binary, "\":", (integer_to_binary(V))/binary>>;
numberField(Key, V) when is_float(V) ->
    <<",\"", Key/binary, "\":", (float_to_binary(V, [{decimals, 6}, compact]))/binary>>;
numberField(_Key, _) -> <<>>.

%% 正整数字段（max_tokens）：非正整数忽略。
positiveIntField(_Key, undefined) -> <<>>;
positiveIntField(Key, V) when is_integer(V), V > 0 ->
    <<",\"", Key/binary, "\":", (integer_to_binary(V))/binary>>;
positiveIntField(_Key, _) -> <<>>.

%% response_format：map 直接序列化；json_object/binary 归一为 {"type":...}。
responseFormatField(undefined) -> <<>>;
responseFormatField(Fmt) when is_map(Fmt) ->
    <<",\"response_format\":", (alJson:encode(Fmt))/binary>>;
responseFormatField(json_object) ->
    <<",\"response_format\":{\"type\":\"json_object\"}">>;
responseFormatField(Type) when is_binary(Type) ->
    <<",\"response_format\":{\"type\":", (jsonString(Type))/binary, "}">>;
responseFormatField(_) -> <<>>.

%%--------------------------------------------------------------------
%% @doc
%% 编码工具规格为 OpenAI function tool JSON。同时支持 atom 键
%% （function/parameters/description）与 binary 键的两种格式。
%%
%% @param Tool 工具规格 map
%% @return 二进制 JSON 片段
%% @end
%%--------------------------------------------------------------------
encodeTool(#{function := #{name := Name} = Function}) ->
    Params = maps:get(parameters, Function, maps:get(<<"parameters">>, Function, #{})),
    Desc = maps:get(description, Function, maps:get(<<"description">>, Function, <<>>)),
    NameBin = jsonString(Name),
    DescBin = jsonString(Desc),
    ParamsBin = jsonValue(Params),
    <<"{\"type\":\"function\",\"function\":{\"name\":", NameBin/binary,
      ",\"description\":", DescBin/binary,
      ",\"parameters\":", ParamsBin/binary, "}}">>;
%% 其他形态——直接 JSON 序列化整个 map
encodeTool(Tool) ->
    jsonValue(Tool).

%%--------------------------------------------------------------------
%% @doc
%% 编码单条消息为 JSON 对象（含 role、可选 name、可选 tool_call_id、
%% content、可选 tool_calls 段）。content 通过 encodeMessageContent
%% 处理以支持多模态。
%%
%% @param Message 消息 map
%% @return 二进制 JSON 片段
%% @end
%%--------------------------------------------------------------------
encodeMessage(#{role := Role, content := Content} = Message) ->
    ToolCalls = maps:get(tool_calls, Message, maps:get(<<"tool_calls">>, Message, [])),
    ToolCallId = maps:get(tool_call_id, Message, maps:get(<<"tool_call_id">>, Message, undefined)),
    NamePart = case maps:get(name, Message, maps:get(<<"name">>, Message, undefined)) of
        undefined -> <<>>;
        Name ->
            NameBin = jsonString(Name),
            <<",\"name\":", NameBin/binary>>
    end,
    ToolCallIdPart = case ToolCallId of
        undefined -> <<>>;
        Id ->
            IdBin = jsonString(Id),
            <<",\"tool_call_id\":", IdBin/binary>>
    end,
    ToolCallsPart = case ToolCalls of
        [] -> <<>>;
        Calls when is_list(Calls) ->
            Encoded = joinBin([encodeToolCall(Call) || Call <- Calls], <<",">>),
            <<",\"tool_calls\":[", Encoded/binary, "]">>
    end,
    ReasoningPart = case extractReasoningContent(Message) of
        undefined -> <<>>;
        RC ->
            RCBin = encodeMessageContent(RC),
            <<",\"reasoning_content\":", RCBin/binary>>
    end,
    ContentPart = encodeMessageContent(Content),
    RoleBin = jsonString(Role),
    <<"{\"role\":", RoleBin/binary,
      NamePart/binary,
      ToolCallIdPart/binary,
      ",\"content\":", ContentPart/binary,
      ReasoningPart/binary,
      ToolCallsPart/binary,
      "}">>;
%% 缺 content 时补 null，避免 pattern 匹配失败。
encodeMessage(#{role := _Role} = Message) ->
    encodeMessage(Message#{content => maps:get(content, Message, null)}).

%% Thinking 模式下若历史含带 tool_calls 的 assistant，必须回传 reasoning_content。
%% 对缺失字段补空串，避免新会话/旧 checkpoint 直接 400（空串未必能续推旧推理，但可避免协议报错）。
prepareMessagesForChat(Messages) when is_list(Messages) ->
    Needs = lists:any(fun hasAssistantToolCalls/1, Messages),
    case Needs of
        true -> [ensureAssistantReasoning(M) || M <- Messages];
        false -> Messages
    end;
prepareMessagesForChat(Other) ->
    Other.

hasAssistantToolCalls(#{role := Role, tool_calls := Calls})
  when (Role =:= assistant orelse Role =:= <<"assistant">>),
       is_list(Calls), Calls =/= [] ->
    true;
hasAssistantToolCalls(#{role := Role, <<"tool_calls">> := Calls})
  when (Role =:= assistant orelse Role =:= <<"assistant">>),
       is_list(Calls), Calls =/= [] ->
    true;
hasAssistantToolCalls(_) ->
    false.

ensureAssistantReasoning(Msg) ->
    case hasAssistantToolCalls(Msg) of
        false ->
            Msg;
        true ->
            case extractReasoningContent(Msg) of
                undefined -> Msg#{reasoning_content => <<>>};
                _ -> Msg
            end
    end.

%% null/undefined 编码为 JSON null
encodeMessageContent(null) -> <<"null">>;
encodeMessageContent(undefined) -> <<"null">>;
%% 列表内容：若是多模态 parts 则直接 JSON 序列化；否则作为文本
encodeMessageContent(Parts) when is_list(Parts) ->
    case alAttachments:isContentParts(Parts) of
        true -> alJson:encode(Parts);
        false -> jsonString(capContent(Parts))
    end;
%% 其他值作为文本（截断后转义）
encodeMessageContent(Value) ->
    jsonString(capContent(Value)).

%%--------------------------------------------------------------------
%% @doc
%% 编码单个 tool_call 为 OpenAI tool_calls 数组项 JSON 片段。
%%
%% @param Call tool_call map（含 id 与 function.{name,arguments}）
%% @return 二进制 JSON 片段
%% @end
%%--------------------------------------------------------------------
encodeToolCall(#{function := #{name := Name, arguments := Args}, id := Id}) ->
    IdBin = jsonString(Id),
    NameBin = jsonString(Name),
    ArgsBin = encodeToolArgs(Args),
    <<"{\"id\":", IdBin/binary,
      ",\"type\":\"function\",\"function\":{\"name\":", NameBin/binary,
      ",\"arguments\":", ArgsBin/binary, "}}">>.

%% arguments 字段必须是 JSON 字符串；LLM 返回 null/undefined 时降级为
%% 空参数对象 "{}"，避免生成语义非法的 "arguments":null。
encodeToolArgs(null) -> jsonString(<<"{}">>);
encodeToolArgs(undefined) -> jsonString(<<"{}">>);
encodeToolArgs(Args) -> jsonString(Args).

%% map 值交由 alJson 序列化
jsonValue(Map) when is_map(Map) ->
    alJson:encode(Map);
%% 其他值作为 JSON 字符串
jsonValue(Value) ->
    jsonString(Value).

%%--------------------------------------------------------------------
%% @doc
%% 将任意值编码为 UTF-8 binary 的 JSON 字符串（含双引号）。null 转
%% "null"，其他值先转 binary、sanitize、转义后包裹引号。
%% 注意：永不产生 unicode charlist 进入 iolist。
%%
%% @param Value 输入值
%% @return binary()
%% @end
%%--------------------------------------------------------------------
%% Always produce a UTF-8 binary JSON string — never unicode charlists in iolists.
jsonString(null) -> <<"null">>;
jsonString(Value) ->
    Bin0 = case Value of
        B when is_binary(B) -> B;
        _ -> contentToBinary(Value)
    end,
    Bin = alJson:sanitizeBinary(Bin0),
    Escaped = jsonEscapeBin(Bin),
    <<$", Escaped/binary, $">>.

%% 空列表返回空二进制
joinBin([], _Sep) -> <<>>;
%% 单元素直接转 binary 片段
joinBin([Item], _Sep) -> toBinPart(Item);
%% 多元素递归拼接（含分隔符）
joinBin([Item | Rest], Sep) ->
    <<(toBinPart(Item))/binary, Sep/binary, (joinBin(Rest, Sep))/binary>>.

%% 二进制原样返回
toBinPart(B) when is_binary(B) -> B;
%% 列表转 iolist_to_binary
toBinPart(L) when is_list(L) -> iolist_to_binary(L);
%% 其他类型走 contentToBinary
toBinPart(Other) -> contentToBinary(Other).

%%--------------------------------------------------------------------
%% @doc
%% 将任意值转 binary 后进行 JSON 字符串转义（公开测试入口）。
%%
%% @param Value 输入值
%% @return 转义后的二进制（不含引号）
%% @end
%%--------------------------------------------------------------------
jsonEscape(Value) ->
    jsonEscapeBin(contentToBinary(Value)).

%%--------------------------------------------------------------------
%% @doc
%% 对 UTF-8 binary 进行 JSON 字符串转义：先确保是合法 UTF-8，
%% 否则用 sanitizeBinary 修复；再逐码点转义控制字符与特殊符号。
%%
%% @param Bin 输入二进制
%% @return 转义后的二进制（不含引号）
%% @end
%%--------------------------------------------------------------------
jsonEscapeBin(Bin) when is_binary(Bin) ->
    case unicode:characters_to_binary(Bin) of
        Utf8 when is_binary(Utf8) ->
            escapeUtf8Bytes(Utf8, <<>>);
        _ ->
            escapeUtf8Bytes(alJson:sanitizeBinary(Bin), <<>>)
    end.

%% 递归结束：返回累积结果
escapeUtf8Bytes(<<>>, Acc) ->
    Acc;
%% 取一个 UTF-8 码点并转义后追加到 Acc
escapeUtf8Bytes(<<C/utf8, Rest/binary>>, Acc) ->
    escapeUtf8Bytes(Rest, <<Acc/binary, (escapeCodepoint(C))/binary>>);
%% 无效 UTF-8 单字节：编码为 \u00XX
escapeUtf8Bytes(<<B:8, Rest/binary>>, Acc) ->
    %% Invalid UTF-8 byte — emit as \u00XX
    Hex = iolist_to_binary(io_lib:format("\\u00~2.16.0b", [B])),
    escapeUtf8Bytes(Rest, <<Acc/binary, Hex/binary>>).

%% 双引号转义
escapeCodepoint($") -> <<"\\\"">>;
%% 反斜杠转义
escapeCodepoint($\\) -> <<"\\\\">>;
%% 换行转义
escapeCodepoint($\n) -> <<"\\n">>;
%% 回车转义
escapeCodepoint($\r) -> <<"\\r">>;
%% 制表符转义
escapeCodepoint($\t) -> <<"\\t">>;
%% 其他控制字符（<32）转义为 \uXXXX
escapeCodepoint(C) when C < 32 ->
    iolist_to_binary(io_lib:format("\\u~4.16.0b", [C]));
%% 普通字符原样保留
escapeCodepoint(C) ->
    <<C/utf8>>.

%%--------------------------------------------------------------------
%% @doc
%% 将任意内容转换为可读文本 binary：binary 原样返回，list 转 binary，
%% map 转 JSON，其他格式化为字符串。
%%
%% @param Value 输入值
%% @return binary()
%% @end
%%--------------------------------------------------------------------
contentToText(Value) when is_binary(Value) ->
    Value;
contentToText(Value) when is_list(Value) ->
    contentToBinary(Value);
contentToText(Value) when is_map(Value) ->
    alJson:encode(Value);
contentToText(Value) ->
    contentToBinary(Value).

%%--------------------------------------------------------------------
%% @doc
%% 内容长度截断：null/undefined 原样返回，其他值经 capBinary
%% 限制到 MaxContentBytes。
%%
%% @param Value 输入值
%% @return 截断后的 binary 或 null
%% @end
%%--------------------------------------------------------------------
-spec capContent(term()) -> binary().
capContent(null) -> null;
capContent(undefined) -> null;
capContent(Value) when is_binary(Value) -> capBinary(Value);
capContent(Value) -> capBinary(contentToBinary(Value)).

%%--------------------------------------------------------------------
%% @doc
%% 对 binary 进行长度截断。超过 MaxContentBytes 时取前 N 字节并
%% 追加截断提示，且经过 sanitizeBinary 确保合法 UTF-8。
%%
%% @param Bin 输入二进制
%% @return 截断后的二进制
%% @end
%%--------------------------------------------------------------------
-spec capBinary(binary()) -> binary().
capBinary(Bin) when byte_size(Bin) =< ?MaxContentBytes -> Bin;
capBinary(Bin) ->
    Base = binary:part(Bin, 0, ?MaxContentBytes),
    Safe = alJson:sanitizeBinary(Base),
    <<Safe/binary, "\n...[content truncated for API]">>.

%%--------------------------------------------------------------------
%% @doc
%% 通用值转 binary：binary 原样，list 转 unicode binary，map 转 JSON，
%% 其他类型格式化为字符串。
%%
%% @param Value 输入值
%% @return binary()
%% @end
%%--------------------------------------------------------------------
contentToBinary(Value) when is_binary(Value) -> Value;
contentToBinary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
contentToBinary(Value) when is_map(Value) -> alJson:encode(Value);
contentToBinary(Value) -> iolist_to_binary(io_lib:format("~p", [Value])).

%%--------------------------------------------------------------------
%% @doc
%% 从列表中取第一个"已定义"的值。false/undefined/""/脱敏占位 视为未定义
%% 而跳过；全部未定义时返回 undefined。
%%
%% @param List 候选值列表
%% @return 第一个有效值 | undefined
%% @end
%%--------------------------------------------------------------------
firstDefined([false | Rest]) ->
    firstDefined(Rest);
firstDefined([undefined | Rest]) ->
    firstDefined(Rest);
firstDefined(["" | Rest]) ->
    firstDefined(Rest);
firstDefined([<<"***REDACTED***">> | Rest]) ->
    %% checkpoint 落盘脱敏后的占位符，不能当真实 apiKey 用
    firstDefined(Rest);
firstDefined(["***REDACTED***" | Rest]) ->
    firstDefined(Rest);
firstDefined([Value | _Rest]) ->
    Value;
firstDefined([]) ->
    undefined.

%%--------------------------------------------------------------------
%% @doc
%% 通用值转 binary：binary 原样，list 转 list_to_binary，atom 转二进制。
%%
%% @param Value 输入值
%% @return binary()
%% @end
%%--------------------------------------------------------------------
toBinary(Value) when is_binary(Value) ->
    Value;
toBinary(Value) when is_list(Value) ->
    list_to_binary(Value);
toBinary(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
toBinary(Value) when is_map(Value) ->
    alJson:encode(Value);
toBinary(Value) ->
    alJson:encode(Value).

%%%===================================================================
%%% Anthropic Messages API adapters
%%%===================================================================

-define(AnthropicApiVersion, <<"2023-06-01">>).
-define(AnthropicDefaultMaxTokens, 4096).

-spec anthropicRequestBody(binary(), [map()], [map()], map()) -> binary().
%%--------------------------------------------------------------------
%% @doc
%% 构造 Anthropic Messages API 请求体。系统消息提取到顶层 `system'
%% 字段；`max_tokens' 必填（默认 4096）；OpenAI 风格的 tool_calls
%% 与 tool 结果会被转换为 Anthropic 的 content blocks。可选注入
%% temperature/top_p 与 tools/tool_choice。
%%
%% @param Model    模型名
%% @param Messages 消息列表
%% @param Tools    工具规格列表
%% @param Opts     调用选项
%% @return 二进制 JSON 请求体
%% @end
%%--------------------------------------------------------------------
anthropicRequestBody(Model, Messages, Tools, Opts) ->
    {System, Conv} = splitSystemMessages(Messages),
    AnthropicMsgs = convertMessagesForAnthropic(Conv),
    Base0 = #{
        <<"model">> => Model,
        <<"max_tokens">> => maps:get(anthropicMaxTokens, Opts, ?AnthropicDefaultMaxTokens),
        <<"messages">> => AnthropicMsgs
    },
    Base1 = case System of
        <<>> -> Base0;
        _ -> Base0#{<<"system">> => System}
    end,
    Base2 = case maps:get(temperature, Opts, undefined) of
        T when is_number(T) -> Base1#{<<"temperature">> => T};
        _ -> Base1
    end,
    Base3 = case maps:get(top_p, Opts, undefined) of
        P when is_number(P) -> Base2#{<<"top_p">> => P};
        _ -> Base2
    end,
    Base4 = case maps:get(stream, Opts, false) of
        true -> Base3#{<<"stream">> => true};
        _ -> Base3
    end,
    Final = case Tools of
        [] -> Base4;
        _ -> Base4#{
            <<"tools">> => [convertOpenaiToolToAnthropic(T) || T <- Tools],
            <<"tool_choice">> => anthropicToolChoice(maps:get(tool_choice, Opts, auto))
        }
    end,
    alJson:encode(Final).

-spec anthropicHeaders(binary()) -> [{binary(), binary()}].
%%--------------------------------------------------------------------
%% @doc
%% 构造 Anthropic Messages API 请求头：用 `x-api-key' 与
%% `anthropic-version' 替代 OpenAI 的 Bearer 鉴权。
%%
%% @param ApiKey API key 二进制
%% @return 头部列表
%% @end
%%--------------------------------------------------------------------
anthropicHeaders(ApiKey) ->
    [
        {<<"x-api-key">>, ApiKey},
        {<<"anthropic-version">>, ?AnthropicApiVersion},
        {<<"content-type">>, <<"application/json">>}
    ].

-spec parseAnthropicResponse(binary()) -> {ok, map()}.
%%--------------------------------------------------------------------
%% @doc
%% 解析 Anthropic Messages API 响应为与 parseChatResponse/1 相同的
%% 结构：`#{provider, message, content, tool_calls, model, usage,
%% finish_reason, raw}'。从 content blocks 中聚合文本与 tool_use 块，
%% 并记录 token 用量。
%%
%% @param RespBody 响应体二进制
%% @return {ok, map()}
%% @end
%%--------------------------------------------------------------------
parseAnthropicResponse(RespBody) ->
    try alJson:decode(RespBody) of
        Decoded ->
            ContentBlocks = maps:get(<<"content">>, Decoded, []),
            TextParts = [maps:get(<<"text">>, B, <<>>) || B <- ContentBlocks,
                                                           maps:get(<<"type">>, B, <<>>) =:= <<"text">>],
            ToolUses = [B || B <- ContentBlocks, maps:get(<<"type">>, B, <<>>) =:= <<"tool_use">>],
            Content = iolist_to_binary(TextParts),
            ToolCalls = [anthropicToolUseToOpenaiCall(B) || B <- ToolUses],
            Message = #{
                role => <<"assistant">>,
                content => Content,
                tool_calls => ToolCalls
            },
            StopReason = maps:get(<<"stop_reason">>, Decoded, undefined),
            FinishReason = anthropicFinishReason(StopReason),
            maybeTrackUsage(Decoded, maps:get(<<"model">>, Decoded, undefined)),
            {ok, #{
                provider => anthropic,
                message => Message,
                content => Content,
                tool_calls => ToolCalls,
                model => maps:get(<<"model">>, Decoded, undefined),
                usage => anthropicUsage(Decoded),
                finish_reason => FinishReason,
                raw => RespBody
            }}
    catch
        _:_ ->
            {ok, #{
                provider => anthropic,
                content => RespBody,
                raw => RespBody,
                tool_calls => []
            }}
    end.

%%%===================================================================
%%% Anthropic helpers
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 将消息列表拆分为系统消息（合并为单一 binary）与对话消息。
%% 系统消息按顺序用空行拼接。
%%
%% @param Messages 消息列表
%% @return {SystemBinary, ConversationMessages}
%% @end
%%--------------------------------------------------------------------
splitSystemMessages(Messages) ->
    splitSystemMessages(Messages, [], []).

%% 结束：将系统消息列表合并为 binary，对话消息 reverse 还原顺序
splitSystemMessages([], Systems, Rest) ->
    SystemBin = iolist_to_binary(lists:reverse(Systems)),
    {unicode:characters_to_binary(SystemBin), lists:reverse(Rest)};
%% 系统消息：内容转 binary 并用空行分隔累积
splitSystemMessages([#{role := system, content := C} | T], Sys, Rest) ->
    Part = toBinary(C),
    NewSys = case Sys of
        [] -> [Part];
        _ -> [Part, <<"\n\n">> | Sys]
    end,
    splitSystemMessages(T, NewSys, Rest);
%% 其他消息：累积到 Rest
splitSystemMessages([M | T], Sys, Rest) ->
    splitSystemMessages(T, Sys, [M | Rest]).

%%--------------------------------------------------------------------
%% @doc
%% 将 OpenAI 风格消息列表转换为 Anthropic Messages 风格：tool 角色
%% 合并为 user 消息的 tool_result 块；带 tool_calls 的 assistant
%% 转为含 text+tool_use 块；普通 assistant/user 转换 content 形态；
%% 未知角色消息直接丢弃。
%%
%% @param Messages 消息列表
%% @return Anthropic 风格消息列表
%% @end
%%--------------------------------------------------------------------
convertMessagesForAnthropic(Messages) ->
    convertMessagesForAnthropic(Messages, []).

%% 结束：反转累积结果
convertMessagesForAnthropic([], Acc) ->
    lists:reverse(Acc);
%% 连续的 tool 消息合并为一条 user 消息（含 tool_result 块）
convertMessagesForAnthropic([#{role := tool} | _] = Msgs, Acc) ->
    {Blocks, Rest} = collectAnthropicToolResults(Msgs, []),
    UserMsg = #{<<"role">> => <<"user">>, <<"content">> => Blocks},
    convertMessagesForAnthropic(Rest, [UserMsg | Acc]);
%% 带 tool_calls 的 assistant：转为 Anthropic 风格的 text+tool_use 块
convertMessagesForAnthropic([#{role := assistant, tool_calls := Calls} = Msg | Rest], Acc)
    when is_list(Calls), Calls =/= [] ->
    AnthropicMsg = assistantToAnthropic(Msg, Calls),
    convertMessagesForAnthropic(Rest, [AnthropicMsg | Acc]);
%% 普通 assistant：仅含文本 content
convertMessagesForAnthropic([#{role := assistant} = Msg | Rest], Acc) ->
    Content = maps:get(content, Msg, <<>>),
    AnthropicMsg = #{
        <<"role">> => <<"assistant">>,
        <<"content">> => toBinary(Content)
    },
    convertMessagesForAnthropic(Rest, [AnthropicMsg | Acc]);
%% user 消息：用 anthropicUserContent 转换多模态/文本
convertMessagesForAnthropic([#{role := user, content := Content} | Rest], Acc) ->
    Msg = #{
        <<"role">> => <<"user">>,
        <<"content">> => anthropicUserContent(Content)
    },
    convertMessagesForAnthropic(Rest, [Msg | Acc]);
%% 其他角色消息：忽略
convertMessagesForAnthropic([_ | Rest], Acc) ->
    convertMessagesForAnthropic(Rest, Acc).

%%--------------------------------------------------------------------
%% @doc
%% 累积连续的 tool 角色消息为 Anthropic tool_result 块列表，
%% 遇到非 tool 消息时返回 {Blocks, Rest}。
%%
%% @param Msgs 消息列表
%% @param Acc  累积的块列表
%% @return {Blocks, Rest}
%% @end
%%--------------------------------------------------------------------
collectAnthropicToolResults([#{role := tool, tool_call_id := Id, content := Content} | Rest], Acc) ->
    Block = #{
        <<"type">> => <<"tool_result">>,
        <<"tool_use_id">> => toBinary(Id),
        <<"content">> => toBinary(Content)
    },
    collectAnthropicToolResults(Rest, [Block | Acc]);
%% 缺 tool_call_id（或仅有 binary 键 <<"tool_call_id">>）的 tool 消息：
%% 降级为 tool_use_id = <<>>，并消费当前元素，保证 Rest 严格递减，消除无限递归。
collectAnthropicToolResults([#{role := tool} = Msg | Rest], Acc) ->
    Id = maps:get(tool_call_id, Msg, maps:get(<<"tool_call_id">>, Msg, undefined)),
    Content = maps:get(content, Msg, maps:get(<<"content">>, Msg, <<>>)),
    ToolUseId = case Id of
        undefined -> <<>>;
        _ -> toBinary(Id)
    end,
    Block = #{
        <<"type">> => <<"tool_result">>,
        <<"tool_use_id">> => ToolUseId,
        <<"content">> => toBinary(Content)
    },
    collectAnthropicToolResults(Rest, [Block | Acc]);
%% 非工具消息——终止累积
collectAnthropicToolResults(Rest, Acc) ->
    {lists:reverse(Acc), Rest}.

%%--------------------------------------------------------------------
%% @doc
%% 将带 tool_calls 的 assistant 消息转换为 Anthropic 风格：
%% 文本 content 转为 text 块，每个 tool_call 转为 tool_use 块，
%% 两段拼接为 content 列表。
%%
%% @param Msg   assistant 消息
%% @param Calls tool_calls 列表
%% @return Anthropic 风格消息 map
%% @end
%%--------------------------------------------------------------------
assistantToAnthropic(Msg, Calls) ->
    Content = maps:get(content, Msg, null),
    TextParts = case Content of
        null -> [];
        <<>> -> [];
        C -> [#{<<"type">> => <<"text">>, <<"text">> => toBinary(C)}]
    end,
    ToolParts = [openaiCallToAnthropicToolUse(C) || C <- Calls],
    #{
        <<"role">> => <<"assistant">>,
        <<"content">> => TextParts ++ ToolParts
    }.

%%--------------------------------------------------------------------
%% @doc
%% 将 OpenAI 风格 tool_call 转为 Anthropic tool_use 块。
%% arguments JSON 字符串解析为 map 后作为 input 字段。
%%
%% @param Call OpenAI tool_call map
%% @return Anthropic tool_use 块 map
%% @end
%%--------------------------------------------------------------------
openaiCallToAnthropicToolUse(#{function := #{name := Name, arguments := Args}, id := Id}) ->
    Input = case parseArgsJson(Args) of
        {ok, Map} when is_map(Map) -> Map;
        _ -> #{}
    end,
    #{
        <<"type">> => <<"tool_use">>,
        <<"id">> => toBinary(Id),
        <<"name">> => toBinary(Name),
        <<"input">> => Input
    }.

%%--------------------------------------------------------------------
%% @doc
%% 将工具参数解析为 map：binary 尝试 JSON 解析，map 原样返回，
%% 其他类型返回 {error, badArgs}。
%%
%% @param Args 参数（binary/map/其他）
%% @return {ok, Map} | {error, badJson | badArgs}
%% @end
%%--------------------------------------------------------------------
parseArgsJson(Args) when is_binary(Args) ->
    try alJson:decode(Args) of
        Map -> {ok, Map}
    catch _:_ -> {error, badJson}
    end;
parseArgsJson(Args) when is_map(Args) ->
    {ok, Args};
parseArgsJson(_) ->
    {error, badArgs}.

%%--------------------------------------------------------------------
%% @doc
%% 将 OpenAI 风格工具规格转换为 Anthropic 工具规格：function.name→name，
%% parameters→input_schema，description→description。同时支持 atom 与
%% binary 键的两种格式。
%%
%% @param Tool OpenAI 工具规格 map
%% @return Anthropic 工具规格 map
%% @end
%%--------------------------------------------------------------------
convertOpenaiToolToAnthropic(#{function := #{name := Name} = Function}) ->
    Params = maps:get(parameters, Function, maps:get(<<"parameters">>, Function, #{})),
    Desc = maps:get(description, Function, maps:get(<<"description">>, Function, <<>>)),
    #{
        <<"name">> => toBinary(Name),
        <<"description">> => toBinary(Desc),
        <<"input_schema">> => Params
    };
convertOpenaiToolToAnthropic(#{<<"function">> := #{<<"name">> := Name} = Function}) ->
    Params = maps:get(<<"parameters">>, Function, #{}),
    Desc = maps:get(<<"description">>, Function, <<>>),
    #{
        <<"name">> => Name,
        <<"description">> => Desc,
        <<"input_schema">> => Params
    }.

%%--------------------------------------------------------------------
%% @doc
%% 将 tool_choice 选项转换为 Anthropic 的 tool_choice map。
%% 支持 auto、{tool, Name}、字符串/列表名等形态，未知值默认 auto。
%%
%% @param Choice tool_choice 选项
%% @return Anthropic tool_choice map
%% @end
%%--------------------------------------------------------------------
anthropicToolChoice(auto) ->
    #{<<"type">> => <<"auto">>};
anthropicToolChoice(<<"auto">>) ->
    #{<<"type">> => <<"auto">>};
anthropicToolChoice({tool, Name}) ->
    #{<<"type">> => <<"tool">>, <<"name">> => toBinary(Name)};
anthropicToolChoice(Name) when is_binary(Name); is_list(Name) ->
    #{<<"type">> => <<"tool">>, <<"name">> => toBinary(Name)};
anthropicToolChoice(_) ->
    #{<<"type">> => <<"auto">>}.

%%--------------------------------------------------------------------
%% @doc
%% 将 Anthropic 的 tool_use 块反向转换为 OpenAI 风格 tool_call：
%% input 序列化为 JSON 字符串作为 arguments。
%%
%% @param Block Anthropic tool_use 块
%% @return OpenAI tool_call map
%% @end
%%--------------------------------------------------------------------
anthropicToolUseToOpenaiCall(#{<<"id">> := Id, <<"name">> := Name, <<"input">> := Input}) ->
    ArgsBin = alJson:encode(Input),
    #{
        id => Id,
        type => <<"function">>,
        function => #{name => Name, arguments => ArgsBin}
    }.

%%--------------------------------------------------------------------
%% @doc
%% 将 Anthropic 的 stop_reason 映射为 OpenAI 风格 finish_reason：
%% end_turn/stop_sequence→stop，max_tokens→length，tool_use→tool_calls，
%% 其他原样返回。
%%
%% @param Reason Anthropic stop_reason
%% @return OpenAI finish_reason binary
%% @end
%%--------------------------------------------------------------------
anthropicFinishReason(<<"end_turn">>) -> <<"stop">>;
anthropicFinishReason(<<"max_tokens">>) -> <<"length">>;
anthropicFinishReason(<<"stop_sequence">>) -> <<"stop">>;
anthropicFinishReason(<<"tool_use">>) -> <<"tool_calls">>;
anthropicFinishReason(Other) -> Other.

%%--------------------------------------------------------------------
%% @doc
%% 将 Anthropic usage 转换为 OpenAI 风格 usage map：补充 total_tokens、
%% prompt_tokens、completion_tokens 等同义字段。无 usage 时返回 undefined。
%%
%% @param Decoded 响应 map
%% @return map() | undefined
%% @end
%%--------------------------------------------------------------------
anthropicUsage(Decoded) ->
    case maps:get(<<"usage">>, Decoded, undefined) of
        undefined -> undefined;
        Usage ->
            In = maps:get(<<"input_tokens">>, Usage, 0),
            Out = maps:get(<<"output_tokens">>, Usage, 0),
            #{
                input_tokens => In,
                output_tokens => Out,
                total_tokens => In + Out,
                prompt_tokens => In,
                completion_tokens => Out
            }
    end.

%%--------------------------------------------------------------------
%% @doc
%% 按模型视觉能力清洗消息列表。若模型不支持视觉，则将多模态消息
%% 降级为纯文本；否则原样返回。
%%
%% @param Messages  消息列表
%% @param Provider  提供商
%% @param Model     模型名
%% @return 处理后的消息列表
%% @end
%%--------------------------------------------------------------------
sanitizeMessagesForVision(Messages, Provider, Model, Opts) ->
    case supportsVision(Provider, Model, Opts) of
        true ->
            Messages;
        false ->
            [downgradeMultimodalMessage(M) || M <- Messages]
    end.

%%--------------------------------------------------------------------
%% @doc
%% 判断当前请求是否应把图片发给模型。
%% 优先级：链项/配置 `vision => true|false|auto`（false 会真正关掉）。
%% auto：本地可探测 `/props`、`/v1/models`；探测不到再按模型名启发式。
%% 不按厂商写死；云端确定支持/不支持时请显式配 vision。
%% @end
%%--------------------------------------------------------------------
-spec supportsVision(atom(), term(), map()) -> boolean().
supportsVision(Provider, Model, Opts) when is_map(Opts) ->
    case visionFlag(Opts) of
        true -> true;
        false -> false;
        auto -> visionAuto(Provider, Model, Opts)
    end;
supportsVision(Provider, Model, _) ->
    visionAuto(Provider, Model, #{}).

visionFlag(Opts) ->
    Entry = case maps:get(modelEntry, Opts, undefined) of
        M when is_map(M) -> M;
        _ -> #{}
    end,
    %% 不可用 firstDefined：false 会被当成空跳过。
    Candidates = [
        maps:find(vision, Opts),
        maps:find(vision, Entry),
        maps:find(vision, maps:get(extra, Entry, #{})),
        maps:find(vision, try llmConfig(Opts) catch _:_ -> #{} end)
    ],
    case pickVisionFlag(Candidates) of
        true -> true;
        false -> false;
        _ -> auto
    end.

pickVisionFlag([{ok, true} | _]) -> true;
pickVisionFlag([{ok, enabled} | _]) -> true;
pickVisionFlag([{ok, <<"true">>} | _]) -> true;
pickVisionFlag([{ok, false} | _]) -> false;
pickVisionFlag([{ok, disabled} | _]) -> false;
pickVisionFlag([{ok, <<"false">>} | _]) -> false;
pickVisionFlag([{ok, auto} | _]) -> auto;
pickVisionFlag([{ok, <<"auto">>} | _]) -> auto;
pickVisionFlag([{ok, _} | Rest]) -> pickVisionFlag(Rest);
pickVisionFlag([error | Rest]) -> pickVisionFlag(Rest);
pickVisionFlag([]) -> auto.

visionAuto(Provider, Model, Opts) ->
    Cfg = try llmConfig(Opts) catch _:_ -> Opts end,
    BaseUrl = maps:get(baseUrl, Opts, maps:get(baseUrl, Cfg, undefined)),
    case visionProbeResult(BaseUrl, Opts) of
        {ok, Bool} -> Bool;
        unknown -> visionHeuristic(Provider, Model, BaseUrl)
    end.

%% 探测失败时的启发式（仅服务 auto）：按模型名，不按厂商。
visionHeuristic(_Provider, Model, _BaseUrl) ->
    openaiVisionModel(Model) orelse visionModelName(Model).

%% 明确的非视觉模型名（embedding/语音等）。
visionTextOnlyModel(Model) ->
    M = string:lowercase(binary_to_list(toBinary(Model))),
    lists:any(fun(Tok) -> string:find(M, Tok) =/= nomatch end,
              ["embedding", "rerank", "tts", "asr", "whisper", "speech",
               "realtime-preview"]).

isOfficialCloudHost(undefined) ->
    false;
isOfficialCloudHost(Url) ->
    U = string:lowercase(unicode:characters_to_list(toBinary(Url))),
    lists:any(fun(H) -> string:find(U, H) =/= nomatch end,
              ["api.deepseek.com", "api.openai.com", "api.anthropic.com",
               "dashscope.aliyuncs.com", "open.bigmodel.cn"]).

%% 模型名启发式：含 vision/vl 等即视为支持识图（含 deepseek-v4-*-vision*）。
visionModelName(Model) ->
    M = string:lowercase(binary_to_list(toBinary(Model))),
    not visionTextOnlyModel(Model)
        andalso lists:any(fun(Tok) -> string:find(M, Tok) =/= nomatch end,
              ["-vl", "vision", "llava", "minicpm-v", "qwen2-vl", "qwen2.5-vl",
               "internvl", "pixtral", "moondream", "ornith",
               "glm-4v", "glm-4.1v", "glm-4.5v", "cogvlm",
               "deepseek-vl", "deepseek_vl", "janus"]).

%%--------------------------------------------------------------------
%% 向本地 OpenAI 兼容服务探测视觉能力；结果缓存 5 分钟。
%% @end
%%--------------------------------------------------------------------
visionProbeResult(_BaseUrl, #{visionProbe := false}) ->
    unknown;
visionProbeResult(undefined, _Opts) ->
    unknown;
visionProbeResult(BaseUrl, Opts) ->
    case isOfficialCloudHost(BaseUrl) of
        true ->
            unknown;
        false ->
            Origin = llmOrigin(BaseUrl),
            Now = erlang:monotonic_time(millisecond),
            Key = {alLlmClient, visionCap, Origin},
            case persistent_term:get(Key, undefined) of
                {Ts, Result, Ttl} when is_integer(Ts), Now - Ts < Ttl ->
                    Result;
                _ ->
                    Result = doVisionProbe(Origin, Opts),
                    Ttl = case Result of
                        {ok, _} -> 300000;
                        unknown -> 10000
                    end,
                    try persistent_term:put(Key, {Now, Result, Ttl}) catch _:_ -> ok end,
                    Result
            end
    end.

doVisionProbe(Origin, Opts) ->
    Urls = [
        <<Origin/binary, "/props">>,
        <<Origin/binary, "/v1/models">>
    ],
    probeVisionUrls(Urls, Opts).

probeVisionUrls([], _Opts) ->
    unknown;
probeVisionUrls([Url | Rest], Opts) ->
    case fetchJsonMap(Url, Opts) of
        {ok, Map} ->
            case parseVisionCaps(Map) of
                {ok, _} = Ok -> Ok;
                unknown -> probeVisionUrls(Rest, Opts)
            end;
        _ ->
            probeVisionUrls(Rest, Opts)
    end.

fetchJsonMap(Url, Opts) ->
    Headers = [{<<"accept">>, <<"application/json">>}],
    HttpOpts = [{recv_timeout, 1500}, {connect_timeout, 800}],
    case httpRequest(get, Url, Headers, <<>>, HttpOpts, Opts) of
        {ok, Code, _Hdrs, Ref} when Code >= 200, Code < 300 ->
            case responseBody(Ref) of
                {ok, Body} ->
                    try alJson:decode(Body) of
                        Map when is_map(Map) -> {ok, Map};
                        _ -> {error, notMap}
                    catch
                        _:_ -> {error, badJson}
                    end;
                Err -> Err
            end;
        {ok, _Code, _Hdrs, _Ref} ->
            {error, http};
        {error, Reason} ->
            {error, Reason}
    end.

llmOrigin(Url) ->
    B0 = trimTrailingSlash(toBinary(Url)),
    B1 = trimTrailingSlash(stripSuffix(B0, <<"/chat/completions">>)),
    stripSuffix(B1, <<"/v1">>).

stripSuffix(Bin, Suf) ->
    N = byte_size(Suf),
    case byte_size(Bin) >= N andalso binary:part(Bin, byte_size(Bin) - N, N) =:= Suf of
        true -> binary:part(Bin, 0, byte_size(Bin) - N);
        false -> Bin
    end.

trimTrailingSlash(Bin) when byte_size(Bin) > 0 ->
    case binary:last(Bin) of
        $/ -> binary:part(Bin, 0, byte_size(Bin) - 1);
        _ -> Bin
    end;
trimTrailingSlash(Bin) ->
    Bin.

%%--------------------------------------------------------------------
%% @doc
%% 从 llama.cpp `/props` 或 `/v1/models` JSON 解析是否支持视觉。
%% `{ok, true|false}` 表示服务端明确声明；`unknown` 表示看不出来。
%% @end
%%--------------------------------------------------------------------
-spec parseVisionCaps(map() | binary()) -> {ok, boolean()} | unknown.
parseVisionCaps(Bin) when is_binary(Bin) ->
    try alJson:decode(Bin) of
        Map when is_map(Map) -> parseVisionCaps(Map);
        _ -> unknown
    catch
        _:_ -> unknown
    end;
parseVisionCaps(Map) when is_map(Map) ->
    case maps:get(<<"modalities">>, Map, maps:get(modalities, Map, undefined)) of
        Mods when is_map(Mods) ->
            V = maps:get(<<"vision">>, Mods, maps:get(vision, Mods, undefined)),
            case V of
                true -> {ok, true};
                false -> {ok, false};
                _ -> parseModelsVisionCaps(Map)
            end;
        _ ->
            parseModelsVisionCaps(Map)
    end;
parseVisionCaps(_) ->
    unknown.

parseModelsVisionCaps(Map) ->
    Models = case maps:get(<<"models">>, Map, undefined) of
        L when is_list(L), L =/= [] -> L;
        _ ->
            case maps:get(<<"data">>, Map, undefined) of
                D when is_list(D) -> D;
                _ -> []
            end
    end,
    case lists:any(fun modelHasVisionCap/1, Models) of
        true -> {ok, true};
        false -> unknown
    end.

modelHasVisionCap(M) when is_map(M) ->
    Caps = maps:get(<<"capabilities">>, M,
               maps:get(capabilities, M, [])),
    is_list(Caps) andalso lists:any(fun isVisionCapToken/1, Caps);
modelHasVisionCap(_) ->
    false.

isVisionCapToken(T) ->
    L = string:lowercase(unicode:characters_to_list(toBinary(T))),
    lists:member(L, ["vision", "multimodal", "image", "vl"]).
%%--------------------------------------------------------------------
%% @doc
%% 启发式判断 OpenAI 系模型是否支持视觉：模型名（小写）以
%% gpt-4o/gpt-4.1/gpt-4-turbo/gpt-4-vision/chatgpt-4o/o1/o3/o4
%% 之一开头则视为支持。
%%
%% @param Model 模型名
%% @return boolean()
%% @end
%%--------------------------------------------------------------------
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

%%--------------------------------------------------------------------
%% @doc
%% 对不支持视觉的模型，将用户消息中的多模态 content parts 逐项降级。
%% 仅处理 user 角色 + content 为多模态 parts 的消息，其他原样返回。
%%
%% @param Msg 消息 map
%% @return 处理后的消息 map
%% @end
%%--------------------------------------------------------------------
downgradeMultimodalMessage(#{role := user, content := Content} = Msg) when is_list(Content) ->
    case alAttachments:isContentParts(Content) of
        true ->
            Msg#{content := [downgradeMultimodalPart(P) || P <- Content]};
        false ->
            Msg
    end;
downgradeMultimodalMessage(Msg) ->
    Msg.

%%--------------------------------------------------------------------
%% @doc
%% 将单个多模态 part 降级为文本 part：image_url/file 转为提示文本，
%% 其他类型（含 text）原样返回。
%%
%% @param Part part map
%% @return 处理后的 part map
%% @end
%%--------------------------------------------------------------------
downgradeMultimodalPart(#{<<"type">> := <<"image_url">>}) ->
    #{
        <<"type">> => <<"text">>,
        <<"text">> =>
            <<"[用户上传了图片，但当前模型不支持图像识别。请切换到支持视觉的模型（如 gpt-4o）。]"/utf8>>
    };
downgradeMultimodalPart(#{<<"type">> := <<"file">>}) ->
    #{
        <<"type">> => <<"text">>,
        <<"text">> =>
            <<"[用户上传了文档附件（如 PDF），但当前模型不支持此格式。请切换到支持文档的模型。]"/utf8>>
    };
downgradeMultimodalPart(Part) ->
    Part.

%%--------------------------------------------------------------------
%% @doc
%% 将 user 消息的 content 转换为 Anthropic 兼容形态：
%% binary 原样返回；多模态 parts 列表逐项转换；其他形态转 binary。
%%
%% @param Content user 消息内容
%% @return Anthropic 兼容 content
%% @end
%%--------------------------------------------------------------------
anthropicUserContent(Bin) when is_binary(Bin) ->
    Bin;
anthropicUserContent(Parts) when is_list(Parts) ->
    case alAttachments:isContentParts(Parts) of
        true -> [convertUserPartForAnthropic(P) || P <- Parts];
        false -> toBinary(Parts)
    end;
anthropicUserContent(Other) ->
    toBinary(Other).

%%--------------------------------------------------------------------
%% @doc
%% 将用户消息的单个 part 转换为 Anthropic 兼容 part：
%% text 原样；file 转 document 块（解析 data URL 取 base64）；
%% image_url 转 image 块；其他类型转 text。
%%
%% @param Part part map
%% @return Anthropic 兼容 part map
%% @end
%%--------------------------------------------------------------------
convertUserPartForAnthropic(#{<<"type">> := <<"text">>, <<"text">> := Text}) ->
    #{<<"type">> => <<"text">>, <<"text">> => Text};
convertUserPartForAnthropic(#{<<"type">> := <<"file">>, <<"file">> := File}) ->
    Filename = maps:get(<<"filename">>, File, <<"file">>),
    FileData = maps:get(<<"file_data">>, File, <<>>),
    case parseDataUrl(FileData) of
        {ok, MT, B64} ->
            #{
                <<"type">> => <<"document">>,
                <<"source">> => #{
                    <<"type">> => <<"base64">>,
                    <<"media_type">> => MT,
                    <<"data">> => B64
                }
            };
        error ->
            #{
                <<"type">> => <<"text">>,
                <<"text">> => iolist_to_binary([<<"[附件: "/utf8>>, Filename, <<"]">>])
            }
    end;
convertUserPartForAnthropic(#{<<"type">> := <<"image_url">>, <<"image_url">> := Img}) ->
    Url = maps:get(<<"url">>, Img, <<>>),
    case parseDataUrl(Url) of
        {ok, MT, B64} ->
            #{
                <<"type">> => <<"image">>,
                <<"source">> => #{
                    <<"type">> => <<"base64">>,
                    <<"media_type">> => MT,
                    <<"data">> => B64
                }
            };
        error ->
            #{<<"type">> => <<"text">>, <<"text">> => Url}
    end;
convertUserPartForAnthropic(Part) ->
    #{<<"type">> => <<"text">>, <<"text">> => toBinary(Part)}.

%%--------------------------------------------------------------------
%% @doc
%% 解析 data URL（形如 `data:<mime>;base64,<data>'），
%% 成功返回 {ok, Mime, Base64Data}，否则返回 error。
%%
%% @param DataUrl data URL 二进制
%% @return {ok, Mime, B64} | error
%% @end
%%--------------------------------------------------------------------
parseDataUrl(<<"data:", Rest/binary>>) ->
    case binary:split(Rest, <<";base64,">>) of
        [MT, Data] -> {ok, MT, Data};
        _ -> error
    end;
parseDataUrl(_) ->
    error.

%%--------------------------------------------------------------------
%% @doc
%% 若响应含 usage 字段，调用 alTokenStats:trackUsage 记录 token
%% 用量（异常时静默忽略）。无 usage 时直接返回 ok。
%%
%% @param Decoded 响应 map
%% @param Model   模型名
%% @return ok
%% @end
%%--------------------------------------------------------------------
maybeTrackUsage(Decoded, Model) ->
    case maps:get(<<"usage">>, Decoded, undefined) of
        Usage when is_map(Usage) ->
            try alTokenStats:trackUsage(Model, Usage) catch _:_ -> ok end,
            ok;
        _ ->
            ok
    end.
