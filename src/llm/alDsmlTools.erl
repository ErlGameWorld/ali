%%%-------------------------------------------------------------------
%%% @doc DeepSeek V4 DSML 工具调用恢复。
%%%
%%% DeepSeek-V4 可能把 tool_calls 以 DSML 标记写在 message content 里，
%%% 而非（或额外于）OpenAI 风格 `tool_calls`。网关未转换时会漏进 UI 且
%%% 工具永不执行。本模块把这些块解析为正常 tool_calls。
%%%
%%% 支持形态（分隔符可为全角 U+FF5C、ASCII `|` 或加倍）：
%%% ```
%%% <｜DSML｜tool_calls>
%%%   <｜DSML｜invoke name="readFile">
%%%     <｜DSML｜parameter name="path" string="true">a.erl</｜DSML｜parameter>
%%%     <｜DSML｜parameter name="offset" string="false">915</｜DSML｜parameter>
%%%   </｜DSML｜invoke>
%%% </｜DSML｜tool_calls>
%%% ```
%%% invoke 内也可为 JSON 对象（无 parameter 标签）。
%%% @end
%%%-------------------------------------------------------------------
-module(alDsmlTools).

-export([recoverFromContent/1, hasDsmlMarkers/1]).

-ifdef(TEST).
-export([parseInvokes/1, parseParameters/1, stripDsmlBlocks/1]).
-endif.

%%--------------------------------------------------------------------
%% @doc
%% 若 Content 含 DSML 工具标记，返回剥离后的正文 + OpenAI 形 tool_calls；
%% 否则原样返回 content 与空列表。
%%
%% @param Content 助手消息 content（binary/list/map 等）
%% @return {CleanContent, ToolCalls}
%% @end
%%--------------------------------------------------------------------
-spec recoverFromContent(term()) -> {term(), [map()]}.
recoverFromContent(Content) when is_binary(Content) ->
    case hasDsmlMarkers(Content) of
        false ->
            {Content, []};
        true ->
            case parseInvokes(Content) of
                [] ->
                    {Content, []};
                Calls ->
                    {stripDsmlBlocks(Content), Calls}
            end
    end;
recoverFromContent(null) ->
    {null, []};
recoverFromContent(undefined) ->
    {undefined, []};
recoverFromContent(Other) when is_list(Other) ->
    recoverFromContent(unicode:characters_to_binary(Other));
recoverFromContent(Other) ->
    {Other, []}.

%%--------------------------------------------------------------------
%% @doc 快速哨兵：明显不含 DSML 时跳过正则（避免无谓开销）。
%% @end
%%--------------------------------------------------------------------
-spec hasDsmlMarkers(term()) -> boolean().
hasDsmlMarkers(Bin) when is_binary(Bin) ->
    binary:match(Bin, <<"DSML">>) =/= nomatch
        andalso (binary:match(Bin, <<"invoke">>) =/= nomatch
                 orelse binary:match(Bin, <<"tool_calls">>) =/= nomatch
                 orelse binary:match(Bin, <<"tool_call">>) =/= nomatch);
hasDsmlMarkers(_) ->
    false.

%%%===================================================================
%%% 内部解析
%%%===================================================================

%% 正则提取所有 `<DSML...invoke name="...">...</invoke>` 块。
parseInvokes(Content) ->
    {ok, Re} = re:compile(
        <<"<[^<>]*DSML[^<>]*invoke\\s+name=\"([^\"]+)\"[^<>]*>(.*?)</[^<>]*DSML[^<>]*invoke>">>,
        [dotall, unicode, caseless]),
    case re:run(Content, Re, [{capture, all_but_first, binary}, global]) of
        {match, Matches} ->
            lists:filtermap(fun([Name, Body]) ->
                case buildToolCall(Name, Body) of
                    undefined -> false;
                    Call -> {true, Call}
                end
            end, Matches);
        nomatch ->
            []
    end.

%% 单条 invoke → OpenAI function tool_call map。
buildToolCall(Name0, Body) ->
    Name = string:trim(Name0),
    case Name of
        <<>> ->
            undefined;
        _ ->
            ArgsMap = case parseParameters(Body) of
                Empty when Empty =:= #{} ->
                    parseJsonBody(Body);
                Map ->
                    Map
            end,
            ArgsBin = try alJson:encode(ArgsMap)
                      catch _:_ -> <<"{}">> end,
            #{
                id => generateId(),
                type => <<"function">>,
                function => #{
                    name => Name,
                    arguments => ArgsBin
                }
            }
    end.

%% 从 invoke 体内解析 `<DSML...parameter name="..." string="...">` 参数。
parseParameters(Body) when is_binary(Body) ->
    {ok, Re} = re:compile(
        <<"<[^<>]*DSML[^<>]*parameter\\s+name=\"([^\"]+)\"(?:\\s+string=\"(true|false)\")?[^<>]*>(.*?)</[^<>]*DSML[^<>]*parameter>">>,
        [dotall, unicode, caseless]),
    case re:run(Body, Re, [{capture, all_but_first, binary}, global]) of
        {match, Matches} ->
            maps:from_list([
                {Name, decodeParam(Val, IsString)}
             || [Name, IsString, Val] <- padParamMatch(Matches)
            ]);
        nomatch ->
            #{}
    end;
parseParameters(_) ->
    #{}.

%% re 捕获组可能 2 或 3 个（string= 属性可选）。
padParamMatch(Matches) ->
    [case M of
         [Name, Val] -> [Name, <<"true">>, Val];
         [Name, IsString, Val] -> [Name, IsString, Val];
         Other -> Other
     end || M <- Matches].

%% 按 string= 属性决定参数解码方式。
decodeParam(Val0, IsString) ->
    Val = string:trim(Val0),
    case IsString of
        <<"false">> ->
            decodeJsonish(Val);
        _ ->
            Val
    end.

%% 尝试 JSON / 整数 / 浮点 / 布尔，失败则保留原文。
decodeJsonish(Val) ->
    try alJson:decode(Val) of
        Decoded -> Decoded
    catch
        _:_ ->
            try binary_to_integer(Val) of
                I -> I
            catch
                _:_ ->
                    try binary_to_float(Val) of
                        F -> F
                    catch
                        _:_ ->
                            case string:lowercase(Val) of
                                <<"true">> -> true;
                                <<"false">> -> false;
                                _ -> Val
                            end
                    end
            end
    end.

%% invoke 体内无 parameter 标签时，尝试提取首个平衡 JSON 对象。
parseJsonBody(Body) ->
    Trimmed = string:trim(Body),
    case binary:match(Trimmed, <<"{">>) of
        nomatch ->
            #{};
        {Start, _} ->
            case extractBalancedObject(Trimmed, Start) of
                undefined ->
                    #{};
                JsonBin ->
                    try alJson:decode(JsonBin) of
                        Map when is_map(Map) -> Map;
                        _ -> #{}
                    catch
                        _:_ -> #{}
                    end
            end
    end.

%% 从 Start 位置起扫描匹配花括号的 JSON 对象子串。
extractBalancedObject(Bin, Start) ->
    extractBalancedObject(Bin, Start, Start, 0, false).

extractBalancedObject(Bin, Start, Pos, Depth, InStr) when Pos < byte_size(Bin) ->
    <<_:Pos/binary, C, _/binary>> = Bin,
    case {InStr, C} of
        {true, $\\} when Pos + 1 < byte_size(Bin) ->
            extractBalancedObject(Bin, Start, Pos + 2, Depth, true);
        {true, $"} ->
            extractBalancedObject(Bin, Start, Pos + 1, Depth, false);
        {true, _} ->
            extractBalancedObject(Bin, Start, Pos + 1, Depth, true);
        {false, $"} ->
            extractBalancedObject(Bin, Start, Pos + 1, Depth, true);
        {false, ${} ->
            extractBalancedObject(Bin, Start, Pos + 1, Depth + 1, false);
        {false, $}} when Depth =:= 1 ->
            binary:part(Bin, Start, Pos - Start + 1);
        {false, $}} when Depth > 1 ->
            extractBalancedObject(Bin, Start, Pos + 1, Depth - 1, false);
        {false, _} ->
            extractBalancedObject(Bin, Start, Pos + 1, Depth, false)
    end;
extractBalancedObject(_, _, _, _, _) ->
    undefined.

%% 从可见正文中移除 DSML tool_calls / invoke 块。
stripDsmlBlocks(Content) ->
    {ok, ReBlock} = re:compile(
        <<"<[^<>]*DSML[^<>]*tool_calls[^<>]*>.*?</[^<>]*DSML[^<>]*tool_calls[^<>]*>">>,
        [dotall, unicode, caseless]),
    Step1 = case re:replace(Content, ReBlock, <<>>, [global, {return, binary}]) of
        B when is_binary(B) -> B;
        _ -> Content
    end,
    {ok, ReInvoke} = re:compile(
        <<"<[^<>]*DSML[^<>]*invoke\\s+name=\"[^\"]+\"[^<>]*>.*?</[^<>]*DSML[^<>]*invoke>">>,
        [dotall, unicode, caseless]),
    Step2 = case re:replace(Step1, ReInvoke, <<>>, [global, {return, binary}]) of
        B2 when is_binary(B2) -> B2;
        _ -> Step1
    end,
    string:trim(Step2).

%% 生成占位 tool_call id（部分 provider 省略 id）。
generateId() ->
    Rand = integer_to_binary(erlang:unique_integer([positive, monotonic]), 16),
    <<"dsml_", Rand/binary>>.
