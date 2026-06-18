%%%-------------------------------------------------------------------
%%% @doc Agent 推理循环：LLM 请求 ↔ 工具调用 交替执行。
%%%
%%% 核心流程：
%%% <ol>
%%%   <li>向模型发送消息（含工具 schema）</li>
%%%   <li>若模型返回 tool_calls，执行 {@link alTools} 并追加结果</li>
%%%   <li>重复直至模型给出文本回答或达到 maxSteps</li>
%%% </ol>
%%%
%%% 支持普通请求（{@link run/4}）与流式请求（{@link runStream/5}）。
%%% @end
%%%-------------------------------------------------------------------
-module(alLoop).

-export([
    run/4,
    runStream/5,
    parseToolCalls/1
]).

-define(DEFAULT_MAX_STEPS, 25).
-define(MAX_TOOL_CONTENT, 8000).

-type runResult() ::
    {ok, binary(), [map()]} |
    {pending, map(), [map()]} |
    {error, term()}.

%% @doc 执行 Agent 推理循环（阻塞直到完成或步数用尽）。
%%
%% @param Model 模型名称
%% @param Messages OpenAI 格式的消息列表
%% @param Config Agent 配置 map（含 maxSteps、policy 等）
%% @param SessionId 会话 ID（用于审计日志）
%% @returns `{ok, Answer, UpdatedMessages}' | `{pending, ...}' | `{error, Reason}'
-spec run(binary(), [map()], map(), binary()) -> runResult().
run(Model, Messages, Config, SessionId) ->
    MaxSteps = maps:get(maxSteps, Config, ?DEFAULT_MAX_STEPS),
    runLoop(Model, Messages, Config, SessionId, MaxSteps, undefined).

%% @doc 流式执行 Agent 推理循环，向 StreamPid 推送文本 chunk。
-spec runStream(binary(), [map()], map(), binary(), pid()) -> runResult().
runStream(Model, Messages, Config, SessionId, StreamPid) ->
    MaxSteps = maps:get(maxSteps, Config, ?DEFAULT_MAX_STEPS),
    runLoop(Model, Messages, Config, SessionId, MaxSteps, StreamPid).

%%%===================================================================
%%% 推理主循环（LLM ↔ 工具 交替）
%%%===================================================================

%% 单步循环：步数为 0 时汇总；否则请求 LLM 并处理 tool_calls
runLoop(Model, Messages, Config, _SessionId, 0, StreamPid) ->
    emit_progress(Config, #{
        type => step,
        phase => finalize,
        message => <<"步数即将用尽，正在汇总回答..."/utf8>>
    }),
    case finalizeOnMaxSteps(Model, Messages, Config, StreamPid) of
        {ok, Answer, Updated} ->
            emit_progress(Config, #{type => answer, text => Answer}),
            {ok, Answer, Updated};
        {error, _} ->
            Partial = build_partial_summary(Messages),
            emit_progress(Config, #{type => error, reason => maxStepsExceeded}),
            emitStreamAnswer(StreamPid, Partial),
            {error, {maxStepsExceeded, Partial}}
    end;
runLoop(Model, Messages, Config, SessionId, Steps, StreamPid) ->
    MaxSteps = maps:get(maxSteps, Config, ?DEFAULT_MAX_STEPS),
    emit_progress(Config, #{
        type => step,
        phase => llm,
        step => MaxSteps - Steps + 1,
        maxSteps => MaxSteps,
        message => <<"正在请求模型..."/utf8>>
    }),
    Options = buildModelOptions(Config),
    case StreamPid of
        undefined ->
            doChatRequestLoop(Model, Messages, Config, SessionId, Steps, Options, StreamPid);
        _ ->
            case doChatStreamLoop(Model, Messages, Config, StreamPid, Options) of
                {ok, {answer, Answer}, Updated} ->
                    finishStreamAnswer(Model, Messages, Answer, Updated, Config, SessionId, Steps, StreamPid, Options);
                {ok, {tool_calls, Calls}, Preamble, Messages} ->
                    Msg = #{
                        <<"content"/utf8>> => normalizeAnswer(Preamble),
                        <<"tool_calls"/utf8>> => Calls
                    },
                    handleNativeToolCalls(Calls, Msg, Messages, Model, Config, SessionId, Steps, StreamPid);
                {error, empty_stream} ->
                    doChatRequestLoop(Model, Messages, Config, SessionId, Steps, Options, StreamPid);
                {error, Reason} ->
                    emit_progress(Config, #{type => error, reason => Reason}),
                    {error, Reason}
            end
    end.

finishStreamAnswer(Model, Messages, Answer, Updated, Config, SessionId, Steps, StreamPid, _Options) ->
    case parseToolCalls(Answer) of
        [] ->
            emit_progress(Config, #{type => answer, text => Answer}),
            emitStreamDone(StreamPid),
            {ok, Answer, Updated};
        ToolCalls ->
            handleTextToolCalls(ToolCalls, Answer, Messages, Model, Config, SessionId, Steps, StreamPid)
    end.

doChatRequestLoop(Model, Messages, Config, SessionId, Steps, Options, StreamPid) ->
    case chatRequest(Model, Messages, Options, Config) of
        {ok, #{type := answer, content := Response}} ->
            Answer = normalizeAnswer(Response),
            Updated = Messages ++ [llmCli:assistantMessage(Answer)],
            emit_progress(Config, #{type => answer, text => Answer}),
            emitStreamAnswer(StreamPid, Answer),
            {ok, Answer, Updated};
        {ok, #{type := tool_calls, tool_calls := Calls, message := Msg}} ->
            handleNativeToolCalls(Calls, Msg, Messages, Model, Config, SessionId, Steps, StreamPid);
        {ok, Response} when is_binary(Response) ->
            case parseToolCalls(Response) of
                [] ->
                    Updated = Messages ++ [llmCli:assistantMessage(Response)],
                    emit_progress(Config, #{type => answer, text => Response}),
                    emitStreamAnswer(StreamPid, Response),
                    {ok, Response, Updated};
                ToolCalls ->
                    handleTextToolCalls(ToolCalls, Response, Messages, Model, Config, SessionId, Steps, StreamPid)
            end;
        {error, Reason} ->
            emit_progress(Config, #{type => error, reason => Reason}),
            {error, Reason}
    end.

doChatStreamLoop(Model, Messages, _Config, StreamPid, Options) ->
    Self = self(),
    case llmCli:chatStreamTo(Model, Messages, Options, Self) of
        ok ->
            collectStreamChunks(StreamPid, Messages, <<>>, #{});
        {error, Reason} ->
            {error, Reason}
    end.

collectStreamChunks(StreamPid, Messages, Acc, ToolAcc) ->
    receive
        {stream_chunk, Chunk} when is_binary(Chunk) ->
            emitStreamChunk(StreamPid, Chunk),
            collectStreamChunks(StreamPid, Messages, <<Acc/binary, Chunk/binary>>, ToolAcc);
        {stream_tool_delta, Delta} when is_list(Delta) ->
            collectStreamChunks(StreamPid, Messages, Acc, llmCli:mergeStreamToolCallDelta(ToolAcc, Delta));
        {stream_chunk, done} ->
            finalizeStreamCollection(StreamPid, Messages, Acc, ToolAcc);
        {al, streamDone, done} ->
            collectStreamChunks(StreamPid, Messages, Acc, ToolAcc);
        {al, streamError, Reason} ->
            {error, Reason};
        _Other ->
            collectStreamChunks(StreamPid, Messages, Acc, ToolAcc)
    after 600000 ->
        {error, stream_timeout}
    end.

finalizeStreamCollection(_StreamPid, Messages, Acc, ToolAcc) ->
    Calls = llmCli:finalizeStreamToolCalls(ToolAcc),
    case Calls of
        [] ->
            Answer = normalizeAnswer(Acc),
            case Answer of
                <<>> ->
                    {error, empty_stream};
                _ ->
                    Updated = Messages ++ [llmCli:assistantMessage(Answer)],
                    {ok, {answer, Answer}, Updated}
            end;
        _ ->
            {ok, {tool_calls, Calls}, Acc, Messages}
    end.

emitStreamAnswer(undefined, _Response) ->
    ok;
emitStreamAnswer(Pid, Response) ->
    emitStreamChunk(Pid, Response),
    emitStreamDone(Pid).

emitStreamChunk(undefined, _Response) ->
    ok;
emitStreamChunk(Pid, Response) ->
    Pid ! {al, stream, Response},
    Pid ! {stream_chunk, Response}.

emitStreamDone(undefined) ->
    ok;
emitStreamDone(Pid) ->
    Pid ! {al, streamDone, done},
    Pid ! {stream_chunk, done}.

normalizeAnswer(null) -> <<>>;
normalizeAnswer(<<""/utf8>>) -> <<>>;
normalizeAnswer(Response) when is_binary(Response) -> Response;
normalizeAnswer(Response) when is_list(Response) ->
    unicode:characters_to_binary(Response);
normalizeAnswer(Response) -> unicode:characters_to_binary(io_lib:format("~p", [Response])).

finalizeOnMaxSteps(Model, Messages, Config, StreamPid) ->
    Note = llmCli:userMessage(
        <<"已达到工具调用步数上限。请根据目前已获取的信息直接回答用户，不要再调用工具。"/utf8>>
    ),
    Options = maps:get(modelOptions, Config, [{temperature, 0.2}]),
    case llmCli:chat(Model, Messages ++ [Note], Options) of
        {ok, Answer} ->
            Bin = normalizeAnswer(Answer),
            Updated = Messages ++ [llmCli:assistantMessage(Bin)],
            emitStreamAnswer(StreamPid, Bin),
            {ok, Bin, Updated};
        {error, Reason} ->
            {error, Reason}
    end.

chatRequest(Model, Messages, Options, Config) ->
    case useNativeTools(Config) of
        true ->
            llmCli:chatCompletion(Model, Messages, Options);
        false ->
            llmCli:chat(Model, Messages, proplists:delete(tools, proplists:delete(tool_choice, Options)))
    end.

useNativeTools(Config) ->
    case maps:get(useNativeTools, Config, true) of
        false -> false;
        true ->
            Provider = llmCli:getConfig(provider, openai),
            Provider =:= openai orelse Provider =:= deepseek
                orelse Provider =:= anthropic orelse Provider =:= custom
    end.

buildModelOptions(Config) ->
    Base = maps:get(modelOptions, Config, [{temperature, 0.2}]),
    case useNativeTools(Config) of
        true ->
            [{tools, alTools:openAiTools()}, {tool_choice, <<"auto"/utf8>>} | Base];
        false ->
            Base
    end.

handleNativeToolCalls(Calls, Msg, Messages, Model, Config, SessionId, Steps, StreamPid) ->
    AssistantMsg = llmCli:assistantToolCallsMessage(Calls),
    {ToolMessages, Pending} = executeNativeToolCalls(Calls, Config, SessionId, StreamPid),
    NewMessages = Messages ++ [assistantMessageFromApi(Msg, AssistantMsg)] ++ ToolMessages,
    case Pending of
        undefined ->
            runLoop(Model, NewMessages, Config, SessionId, Steps - 1, StreamPid);
        PendingMap ->
            {pending, PendingMap, NewMessages}
    end.

assistantMessageFromApi(ApiMsg, Fallback) ->
    case ApiMsg of
        #{<<"tool_calls"/utf8>> := _} ->
            llmCli:assistantToolCallsMessage(maps:get(<<"tool_calls"/utf8>>, ApiMsg));
        _ ->
            Fallback
    end.

executeNativeToolCalls(Calls, Config, SessionId, StreamPid) ->
    lists:foldl(fun(Call, {Acc, Pend}) ->
        case Pend of
            undefined -> handleNativeCall(Call, Acc, Config, SessionId, StreamPid);
            _ -> {Acc, Pend}
        end
    end, {[], undefined}, Calls).

handleNativeCall(#{<<"id"/utf8>> := Id, <<"function"/utf8>> := FunMap}, Acc, Config, SessionId, _StreamPid) ->
    Name = maps:get(<<"name"/utf8>>, FunMap, <<>>),
    ArgsBin = maps:get(<<"arguments"/utf8>>, FunMap, <<"{}"/utf8>>),
    ToolAtom = toToolAtom(Name),
    Args = decodeArgs(ArgsBin),
    NormalizedArgs = normalizeArgs(Args),
    emit_progress(Config, #{
        type => tool,
        tool => ToolAtom,
        args => summarize_args(NormalizedArgs)
    }),
    Started = erlang:monotonic_time(millisecond),
    Result = alTools:execute(ToolAtom, NormalizedArgs, Config, SessionId),
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    case Result of
        {ok, ToolResult} ->
            emit_progress(Config, #{
                type => tool_done,
                tool => ToolAtom,
                ok => true,
                elapsedMs => Elapsed
            }),
            Content = encodeToolPayload(#{ok => true, result => ToolResult}),
            Msg = llmCli:toolMessage(Id, Content),
            {Acc ++ [Msg], undefined};
        {pending, Pending} ->
            emit_progress(Config, #{
                type => tool_done,
                tool => ToolAtom,
                ok => false,
                status => confirmationRequired,
                elapsedMs => Elapsed
            }),
            Msg = llmCli:toolMessage(Id, llmJson:encode(#{
                ok => false,
                status => confirmationRequired,
                preview => Pending
            })),
            {Acc ++ [Msg], Pending};
        {error, Reason} ->
            emit_progress(Config, #{
                type => tool_done,
                tool => ToolAtom,
                ok => false,
                error => Reason,
                elapsedMs => Elapsed
            }),
            Msg = llmCli:toolMessage(Id, llmJson:encode(#{ok => false, error => Reason})),
            {Acc ++ [Msg], undefined}
    end;
handleNativeCall(_Call, Acc, _Config, _SessionId, _StreamPid) ->
    {Acc, undefined}.

decodeArgs(Bin) ->
    try
        llmJson:decode(Bin)
    catch
        _:_ -> #{}
    end.

handleTextToolCalls(ToolCalls, Response, Messages, Model, Config, SessionId, Steps, StreamPid) ->
    AssistantMsg = llmCli:assistantMessage(Response),
    {ToolMessages, Pending} = executeTextToolCalls(ToolCalls, Config, SessionId),
    NewMessages = Messages ++ [AssistantMsg] ++ ToolMessages,
    case Pending of
        undefined ->
            runLoop(Model, NewMessages, Config, SessionId, Steps - 1, StreamPid);
        PendingMap ->
            {pending, PendingMap, NewMessages}
    end.

executeTextToolCalls(ToolCalls, Config, SessionId) ->
    lists:foldl(fun(ToolCall, {Acc, Pend}) ->
        case Pend of
            undefined ->
                #{id := Id, tool := Tool, args := Args} = ToolCall,
                ToolAtom = toToolAtom(Tool),
                NormalizedArgs = normalizeArgs(Args),
                emit_progress(Config, #{
                    type => tool,
                    tool => ToolAtom,
                    args => summarize_args(NormalizedArgs)
                }),
                Started = erlang:monotonic_time(millisecond),
                ExecResult = alTools:execute(ToolAtom, NormalizedArgs, Config, SessionId),
                Elapsed = erlang:monotonic_time(millisecond) - Started,
                case ExecResult of
                    {ok, Result} ->
                        emit_progress(Config, #{
                            type => tool_done,
                            tool => ToolAtom,
                            ok => true,
                            elapsedMs => Elapsed
                        }),
                        Msg = toolResultMessage(Id, ToolAtom, #{ok => true, result => Result}),
                        {Acc ++ [Msg], undefined};
                    {pending, Pending} ->
                        emit_progress(Config, #{
                            type => tool_done,
                            tool => ToolAtom,
                            ok => false,
                            status => confirmationRequired,
                            elapsedMs => Elapsed
                        }),
                        Msg = toolResultMessage(Id, ToolAtom, #{
                            ok => false,
                            status => confirmationRequired,
                            preview => Pending
                        }),
                        {Acc ++ [Msg], Pending};
                    {error, Reason} ->
                        emit_progress(Config, #{
                            type => tool_done,
                            tool => ToolAtom,
                            ok => false,
                            error => Reason,
                            elapsedMs => Elapsed
                        }),
                        Msg = toolResultMessage(Id, ToolAtom, #{ok => false, error => Reason}),
                        {Acc ++ [Msg], undefined}
                end;
            _ ->
                {Acc, Pend}
        end
    end, {[], undefined}, ToolCalls).

toolResultMessage(Id, _Tool, Payload) ->
    Content = iolist_to_binary([
        <<"<tool_result id=\""/utf8>>, toBinary(Id), <<"\">\n"/utf8>>,
        llmJson:encode(Payload),
        <<"\n</tool_result>"/utf8>>
    ]),
    llmCli:userMessage(Content).

%% @doc 从模型纯文本回复中解析工具调用（XML 标签或 JSON 块）。
%% 用于兼容不支持 native tool_calls 的模型。
-spec parseToolCalls(binary()) -> [map()].
parseToolCalls(Response) ->
    Segments = parseSegments(Response, []),
    case Segments of
        [] -> parseJsonToolCalls(Response);
        _ -> Segments
    end.

parseJsonToolCalls(Response) ->
    case re:run(Response, <<"(\\{[\\s\\S]*\"tool\"[\\s\\S]*\\})"/utf8>>, [{capture, all_but_first, binary}]) of
        {match, Matches} ->
            [Call || M <- Matches, {ok, Call} <- [decodeToolCall(M)]];
        nomatch ->
            []
    end.

parseSegments(Bin, Acc) ->
    case binary:match(Bin, <<"<tool_call>"/utf8>>) of
        nomatch ->
            lists:reverse(Acc);
        {Start, TagLen} ->
            AfterOpen = binary:part(Bin, Start + TagLen, byte_size(Bin) - Start - TagLen),
            case binary:match(AfterOpen, <<"</tool_call>"/utf8>>) of
                nomatch ->
                    lists:reverse(Acc);
                {End, CloseLen} ->
                    Body = binary:part(AfterOpen, 0, End),
                    Tail = binary:part(AfterOpen, End + CloseLen,
                                        byte_size(AfterOpen) - End - CloseLen),
                    NewAcc = case decodeToolCall(Body) of
                        {ok, Call} -> [Call | Acc];
                        failed -> Acc
                    end,
                    parseSegments(Tail, NewAcc)
            end
    end.

decodeToolCall(Bin) ->
    Trimmed = trimBinary(Bin),
    try
        Map = llmJson:decode(Trimmed),
        case mapGet(Map, <<"tool"/utf8>>) of
            undefined -> failed;
            Tool ->
                {ok, #{
                    id => case mapGet(Map, <<"id"/utf8>>) of
                        undefined -> uniqueId();
                        Id -> Id
                    end,
                    tool => Tool,
                    args => mapGetDefault(Map, <<"args"/utf8>>, #{})
                }}
        end
    catch
        _:_ -> failed
    end.

mapGet(Map, Key) ->
    case maps:get(Key, Map, undefined) of
        undefined ->
            maps:get(binary_to_atom(Key, utf8), Map, undefined);
        Value ->
            Value
    end.

mapGetDefault(Map, Key, Default) ->
    case mapGet(Map, Key) of
        undefined -> Default;
        Value -> Value
    end.

normalizeArgs(Args) when is_map(Args) ->
    maps:fold(fun(K, V, Acc) ->
        maps:put(normalizeKey(K), normalizeValue(V), Acc)
    end, #{}, Args);
normalizeArgs(Args) ->
    Args.

normalizeKey(K) when is_binary(K) -> binaryToAtomCamel(K);
normalizeKey(K) when is_atom(K) -> K;
normalizeKey(K) when is_list(K) -> binaryToAtomCamel(list_to_binary(K)).

normalizeValue(V) when is_map(V) -> normalizeArgs(V);
normalizeValue(V) when is_list(V) -> [normalizeValue(X) || X <- V];
normalizeValue(V) -> V.

binaryToAtomCamel(Bin) ->
    List = binary_to_list(Bin),
    AtomStr = case string:split(List, "_") of
        [Single] -> Single;
        Parts -> lists:foldl(fun joinCamel/2, "", Parts)
    end,
    list_to_atom(AtomStr).

joinCamel("", Part) -> Part;
joinCamel(Acc, Part) -> Acc ++ capitalize(Part).

capitalize([C | Rest]) when C >= $a, C =< $z ->
    [C - ($a - $A) | Rest];
capitalize(Str) -> Str.

toToolAtom(T) when is_atom(T) -> T;
toToolAtom(T) when is_binary(T) -> binaryToAtomCamel(T);
toToolAtom(T) when is_list(T) -> list_to_atom(T).

trimBinary(Bin) ->
    re:replace(Bin, <<"^\\s+|\\s+$"/utf8>>, <<>>, [global, {return, binary}]).

uniqueId() ->
    integer_to_binary(erlang:unique_integer([positive, monotonic])).

toBinary(X) when is_binary(X) -> X;
toBinary(X) when is_list(X) -> unicode:characters_to_binary(X);
toBinary(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).

encodeToolPayload(Payload) ->
    Safe = maps:map(fun
        (result, R) -> llmJson:sanitize(R);
        (_, V) -> V
    end, Payload),
    Enc = llmJson:encode(Safe),
    case byte_size(Enc) > ?MAX_TOOL_CONTENT of
        true ->
            llmJson:encode(#{
                ok => maps:get(ok, Safe, true),
                truncated => true,
                preview => binary:part(Enc, 0, ?MAX_TOOL_CONTENT)
            });
        false ->
            Enc
    end.

emit_progress(Config, Event) ->
    case maps:get(progressId, Config, undefined) of
        undefined -> ok;
        Id -> alProgress:emit(Id, Event)
    end.

summarize_args(Args) when is_map(Args) ->
    maps:fold(fun(K, V, Acc) ->
        maps:put(K, summarize_value(V), Acc)
    end, #{}, Args);
summarize_args(Other) ->
    summarize_value(Other).

summarize_value(V) when is_binary(V) ->
    case byte_size(V) > 120 of
        true -> <<(binary:part(V, 0, 120))/binary, "...">>;
        false -> V
    end;
summarize_value(V) when is_list(V) ->
    case length(V) > 8 of
        true -> {list, length(V)};
        false -> V
    end;
summarize_value(V) when is_map(V) ->
    summarize_args(V);
summarize_value(V) ->
    V.

build_partial_summary(Messages) ->
    Hint = <<"（已达工具调用步数上限，以下为根据已收集信息整理的初步回答）\n\n"/utf8>>,
    Body = iolist_to_binary(lists:flatmap(fun summarize_message/1, lists:sublist(Messages, max(1, length(Messages) - 12), 12))),
    case Body of
        <<>> ->
            <<Hint/binary, ("步数用尽且未能生成完整回答。建议 /clear 清空会话后，用更具体的问题重试（例如指定模块名 alWebSrv）。")/utf8>>;
        _ ->
            <<Hint/binary, Body/binary>>
    end.

summarize_message(#{role := tool, content := Content}) when is_binary(Content) ->
    [<<"- 工具结果: "/utf8>>, truncate_bin(Content, 500), <<"\n"/utf8>>];
summarize_message(#{role := assistant, content := Content}) when is_binary(Content); Content =:= null ->
    case Content of
        null -> [];
        _ -> [<<"- 助手: "/utf8>>, truncate_bin(Content, 300), <<"\n"/utf8>>]
    end;
summarize_message(_) ->
    [].

truncate_bin(Bin, Max) ->
    case byte_size(Bin) > Max of
        true -> <<(binary:part(Bin, 0, Max))/binary, "...">>;
        false -> Bin
    end.