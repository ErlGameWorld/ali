%%%-------------------------------------------------------------------
%%% @doc 基于 jiffy 的 JSON 编解码边界层。
%%%
%%% encode 前对 Erlang 项做 sanitize，安全处理 pid/tuple/MFA/reference，
%%% 并修复 jiffy 无法编码的非法 UTF-8 字节。
%%%
%%% 三种编码模式：
%%% <ul>
%%%   <li>{@link encode/1} — sanitize + 编码，返回 binary()（向后兼容）</li>
%%%   <li>{@link encodeSafe/1} — 失败时返回含 error+preview 的兜底 JSON（日志/Web）</li>
%%%   <li>{@link encodeStrict/1} — 失败返回 `{ok, Bin} | {error, jsonEncodeFailed}'
%%%       （LLM API 请求，禁止兜底体污染请求）</li>
%%% </ul>
%%% @end
%%%-------------------------------------------------------------------

-module(alJson).

-export([
    encode/1, encodeSafe/1, encodeStrict/1,
    decode/1,
    sanitize/1, sanitizeBinary/1,
    text/1, proplistObject/1, array/1
]).

-define(DecodeOpts, [return_maps]).
-define(EncodeOpts, [force_utf8]).
-define(MaxDecodeBytes, 16 * 1024 * 1024).
-define(MaxSanitizeDepth, 64).

%%--------------------------------------------------------------------
%% @doc sanitize 后编码为 JSON binary；对 pid/tuple/MFA 输入安全。
%% @end
%%--------------------------------------------------------------------
-spec encode(term()) -> binary().
encode(Term) ->
    Safe = sanitize(Term),
    iolist_to_binary(jiffy:encode(Safe, ?EncodeOpts)).

%%--------------------------------------------------------------------
%% @doc sanitize 后编码；失败时返回含 error 与截断 preview 的兜底 JSON。
%% @end
%%--------------------------------------------------------------------
-spec encodeSafe(term()) -> binary().
encodeSafe(Term) ->
    case encodeStrict(Term) of
        {ok, Bin} ->
            Bin;
        {error, _} ->
            Fallback = #{
                error => <<"jsonEncodeFailed">>,
                preview => truncatePreview(Term)
            },
            try
                iolist_to_binary(jiffy:encode(Fallback, ?EncodeOpts))
            catch
                _:_ ->
                    <<"{\"error\":\"jsonEncodeFailed\"}">>
            end
    end.

%%--------------------------------------------------------------------
%% @doc 严格编码：失败返回 `{error, jsonEncodeFailed}'，用于 LLM API 请求。
%% @end
%%--------------------------------------------------------------------
-spec encodeStrict(term()) -> {ok, binary()} | {error, jsonEncodeFailed}.
encodeStrict(Term) ->
    Safe = sanitize(Term),
    try
        {ok, iolist_to_binary(jiffy:encode(Safe, ?EncodeOpts))}
    catch
        _:_ ->
            {error, jsonEncodeFailed}
    end.

%%--------------------------------------------------------------------
%% @doc 将 JSON binary 或 iolist 解码为 Erlang 项（对象返回 map）。
%% @end
%%--------------------------------------------------------------------
-spec decode(binary() | iolist()) -> term().
decode(Bin) when is_binary(Bin) ->
    case byte_size(Bin) > ?MaxDecodeBytes of
        true -> error({jsonTooLarge, byte_size(Bin)});
        false -> jiffy:decode(Bin, ?DecodeOpts)
    end;
decode(IOList) when is_list(IOList) ->
    decode(iolist_to_binary(IOList)).

%%--------------------------------------------------------------------
%% @doc jiffy ejson 对象：proplist 包在 1-tuple 里，编码结果与等价 map 一致。
%% @end
%%--------------------------------------------------------------------
-spec proplistObject([{term(), term()}]) -> {[{term(), term()}]}.
proplistObject(Proplist) when is_list(Proplist) ->
    {Proplist}.

%%--------------------------------------------------------------------
%% @doc 强制列表按 JSON 数组编码（避免 `[38]` 被收成 printable 字符串）。
%% @end
%%--------------------------------------------------------------------
-spec array([term()]) -> {json_array, [term()]}.
array(List) when is_list(List) ->
    {json_array, List}.

%%--------------------------------------------------------------------
%% @doc 将任意文本值规范化为合法 UTF-8 binary（API/LLM/JSON 共用入口）。
%% @end
%%--------------------------------------------------------------------
-spec text(term()) -> binary().
text(B) when is_binary(B) ->
    sanitizeBinary(B);
text(L) when is_list(L) ->
    safeListToUtf8(L);
text(A) when is_atom(A) ->
    atom_to_binary(A, utf8);
text(I) when is_integer(I) ->
    integer_to_binary(I);
text(F) when is_float(F) ->
    float_to_binary(F, [{decimals, 10}]);
text(null) ->
    <<>>;
text(X) ->
    safeListToUtf8(io_lib:format("~p", [X])).

%%--------------------------------------------------------------------
%% @doc
%% 将 Unicode 字符列表安全转换为 UTF-8 binary；转换失败时退化为 `"(invalid text)"'。
%%
%% @param L 字符列表
%% @return UTF-8 binary
%% @end
%%--------------------------------------------------------------------
safeListToUtf8(L) ->
    try
        unicode:characters_to_binary(L)
    catch
        _:_ ->
            try sanitizeBinary(list_to_binary(L))
            catch _:_ -> <<"(invalid text)">>
            end
    end.

%%--------------------------------------------------------------------
%% @doc 递归将 Erlang 项转为可 JSON 编码结构；非法 UTF-8 与不可编码项做预览化。
%% @end
%%--------------------------------------------------------------------
-spec sanitize(term()) -> term().
sanitize(Term) ->
    sanitize(Term, 0).

sanitize(_Term, Depth) when Depth > ?MaxSanitizeDepth ->
    <<"(max depth)">>;
sanitize(Term, Depth) when is_map(Term) ->
    maps:fold(fun(K, V, Acc) ->
        maps:put(sanitizeKey(K), sanitize(V, Depth + 1), Acc)
    end, #{}, Term);
%% Explicit JSON array marker from {@link array/1} — never collapse to string.
sanitize({json_array, List}, Depth) when is_list(List) ->
    [sanitize(X, Depth + 1) || X <- List];
sanitize(Term, Depth) when is_list(Term) ->
    case classifyList(Term) of
        string ->
            case safeUtf8Binary(Term) of
                Bin when is_binary(Bin) -> Bin;
                _ -> [sanitize(X, Depth + 1) || X <- Term]
            end;
        array ->
            [sanitize(X, Depth + 1) || X <- Term];
        opaque ->
            toPreview(Term)
    end;
sanitize({Mod, Fun, Arity}, _Depth)
    when is_atom(Mod), is_atom(Fun), is_integer(Arity) ->
    formatMfa(Mod, Fun, Arity);
sanitize({Name, Arity}, _Depth)
    when is_atom(Name), is_integer(Arity), Arity >= 0, Arity =< 1024 ->
    iolist_to_binary(io_lib:format("~s/~w", [atom_to_list(Name), Arity]));
sanitize(Term, _Depth) when is_tuple(Term) ->
    toPreview(Term);
sanitize(Term, _Depth) when is_pid(Term); is_port(Term); is_reference(Term) ->
    toPreview(Term);
sanitize(Term, _Depth) when is_atom(Term) ->
    Term;
sanitize(Term, _Depth) when is_binary(Term) ->
    text(Term);
sanitize(Term, _Depth) when is_integer(Term); is_float(Term); is_boolean(Term) ->
    Term;
sanitize(Term, _Depth) ->
    toPreview(Term).

%% 规范化 map 键：atom/binary/integer 键原样保留，其它键递归 sanitize。
sanitizeKey(K) when is_atom(K); is_binary(K); is_integer(K) ->
    K;
sanitizeKey(K) ->
    sanitize(K).

%%--------------------------------------------------------------------
%% @doc
%% 列表分类：可打印 Unicode 字符串为 string，否则若所有元素都是数组项为 array，否则为 opaque。
%%
%% @param List 待分类列表
%% @return `string' | `array' | `opaque'
%% @end
%%--------------------------------------------------------------------
classifyList([]) ->
    array;
classifyList(List) ->
    case io_lib:printable_unicode_list(List) of
        true ->
            string;
        false ->
            case lists:all(fun isArrayElem/1, List) of
                true -> array;
                false -> opaque
            end
    end.

%% 判断一个值是否可作为 JSON 数组元素（基本类型、容器类型或 opaque 类型）。
isArrayElem(X) when is_integer(X); is_float(X); is_binary(X); is_atom(X);
                      is_boolean(X); X =:= null; is_map(X); is_list(X);
                      is_tuple(X); is_pid(X); is_port(X); is_reference(X) ->
    true;
isArrayElem(_) ->
    false.

%%--------------------------------------------------------------------
%% @doc
%% 安全地将 Unicode 字符串列表转换为 UTF-8 binary；失败时返回原子 `error'。
%%
%% @param List 字符列表
%% @return `binary' | `error'
%% @end
%%--------------------------------------------------------------------
safeUtf8Binary(List) when is_list(List) ->
    case unicode:characters_to_binary(List) of
        Bin when is_binary(Bin) -> Bin;
        _ -> error
    end.

%%--------------------------------------------------------------------
%% @doc
%% 将不可编码项格式化为 `~p' 预览字符串并截断，避免兜底体过大。
%%
%% @param Term 任意项
%% @return 截断后的 UTF-8 binary
%% @end
%%--------------------------------------------------------------------
toPreview(Term) ->
    Bin = iolist_to_binary(io_lib:format("~p", [Term])),
    truncatePreview(Bin).

%%--------------------------------------------------------------------
%% @doc 将 binary 截断到最多 512 字节，超长部分以 "..." 标记。
%% @end
%%--------------------------------------------------------------------
-spec truncatePreview(term()) -> binary().
truncatePreview(Term) when is_binary(Term) ->
    truncatePreview(Term, 512);
truncatePreview(Term) ->
    truncatePreview(iolist_to_binary(io_lib:format("~p", [Term])), 512).

%% 截断 binary 到 Max 字节（按 UTF-8 码点边界），超长时追加 "..." 后缀。
truncatePreview(Bin, Max) when is_binary(Bin) ->
    case byte_size(Bin) =< Max of
        true -> Bin;
        false -> <<(truncateUtf8(Bin, Max))/binary, "...">>
    end.

%% 按 UTF-8 码点边界截断，避免切断多字节字符（如中文）产生非法 UTF-8。
truncateUtf8(Bin, Max) when is_binary(Bin), byte_size(Bin) =< Max ->
    Bin;
truncateUtf8(Bin, Max) when is_binary(Bin) ->
    binary:part(Bin, 0, truncateUtf8Len(Bin, min(Max, byte_size(Bin))));
truncateUtf8(_Bin, _Max) ->
    <<>>.

truncateUtf8Len(_Bin, Len) when Len =< 0 ->
    0;
truncateUtf8Len(Bin, Len) ->
    truncateUtf8Len(Bin, Len, 0).

truncateUtf8Len(_Bin, 0, _Back) ->
    0;
truncateUtf8Len(Bin, Len, Back) when Back < 3 ->
    <<_:Len/binary, Byte, _/binary>> = Bin,
    case (Byte band 16#C0) =:= 16#80 of
        true -> truncateUtf8Len(Bin, Len - 1, Back + 1);
        false -> Len
    end;
truncateUtf8Len(_Bin, Len, _Back) ->
    Len.

%%--------------------------------------------------------------------
%% @doc 剥离 binary 中非法 UTF-8 字节，避免 jiffy:encode/1 抛 badarg。
%% @end
%%--------------------------------------------------------------------
-spec sanitizeBinary(binary()) -> binary().
sanitizeBinary(Bin) when is_binary(Bin) ->
    case unicode:characters_to_binary(Bin, utf8) of
        Good when is_binary(Good) ->
            Good;
        _ ->
            scrubInvalidUtf8(Bin, <<>>)
    end.

%% 递归清理非法 UTF-8：合法 codepoint 保留，非法字节丢弃。
scrubInvalidUtf8(<<>>, Acc) ->
    Acc;
scrubInvalidUtf8(<<C/utf8, Rest/binary>>, Acc) ->
    scrubInvalidUtf8(Rest, <<Acc/binary, C/utf8>>);
scrubInvalidUtf8(<<_, Rest/binary>>, Acc) ->
    scrubInvalidUtf8(Rest, Acc).

%% 将 MFA 元组格式化为 "Mod:Fun/Arity" 字符串。
formatMfa(Mod, Fun, Arity) ->
    iolist_to_binary(io_lib:format("~s:~s/~w", [
        atom_to_list(Mod), atom_to_list(Fun), Arity
    ])).
