%%%-------------------------------------------------------------------
%%% @doc Jiffy JSON 封装层。
%%%
%%% 在编码前对 Erlang 术语做 sanitize，将无法 JSON 化的类型
%%%（pid、tuple、MFA 等）转为可读字符串，避免编码失败。
%%% @end
%%%-------------------------------------------------------------------
-module(llmJson).

-export([encode/1, encodeStrict/1, decode/1, sanitize/1, sanitize_binary/1, text/1]).

-define(DECODE_OPTS, [return_maps]).
-define(ENCODE_OPTS, [force_utf8]).

%% @doc 将术语编码为 JSON 二进制；失败时返回含 preview 的错误对象。
%% 仅用于日志/Web 等容错场景；发往 LLM API 请用 {@link encodeStrict/1}。
-spec encode(term()) -> binary().
encode(Term) ->
    case encodeStrict(Term) of
        {ok, Bin} ->
            Bin;
        {error, _} ->
            Fallback = #{
                error => <<"json_encode_failed"/utf8>>,
                preview => truncatePreview(Term)
            },
            encode_json(Fallback)
    end.

%% @doc 编码 JSON；失败时返回 `{error, json_encode_failed}'，不生成 fallback 体。
-spec encodeStrict(term()) -> {ok, binary()} | {error, json_encode_failed}.
encodeStrict(Term) ->
    Safe = sanitize(Term),
    try
        {ok, encode_json(Safe)}
    catch
        _:_ ->
            {error, json_encode_failed}
    end.

%% @doc 将 JSON 二进制或 iolist 解码为 Erlang 术语（对象解码为 map）。
-spec decode(binary() | iolist()) -> term().
decode(Bin) when is_binary(Bin) ->
    jiffy:decode(Bin, ?DECODE_OPTS);
decode(IOList) when is_list(IOList) ->
    jiffy:decode(iolist_to_binary(IOList), ?DECODE_OPTS).

encode_json(Term) ->
    iolist_to_binary(jiffy:encode(Term, ?ENCODE_OPTS)).

%% @doc 将任意文本值规范为合法 UTF-8 binary（API/LLM/JSON 共用入口）。
-spec text(term()) -> binary().
text(B) when is_binary(B) ->
    sanitize_binary(B);
text(L) when is_list(L) ->
    safe_list_to_utf8(L);
text(A) when is_atom(A) ->
    atom_to_binary(A, utf8);
text(I) when is_integer(I) ->
    integer_to_binary(I);
text(F) when is_float(F) ->
    float_to_binary(F, [{decimals, 10}]);
text(null) ->
    <<>>;
text(X) ->
    safe_list_to_utf8(io_lib:format("~p", [X])).

safe_list_to_utf8(L) ->
    try
        unicode:characters_to_binary(L)
    catch
        _:_ ->
            try sanitize_binary(list_to_binary(L))
            catch _:_ -> <<"(invalid text)"/utf8>>
            end
    end.

%% @doc 将 Erlang 术语递归转为 JSON 可编码结构。
-spec sanitize(term()) -> term().
sanitize(Term) when is_map(Term) ->
    maps:fold(fun(K, V, Acc) ->
        maps:put(sanitize_key(K), sanitize(V), Acc)
    end, #{}, Term);
sanitize(Term) when is_list(Term) ->
    case classify_list(Term) of
        string ->
            safe_utf8_binary(Term);
        array ->
            [sanitize(X) || X <- Term];
        opaque ->
            toPreview(Term)
    end;
sanitize({Mod, Fun, Arity})
        when is_atom(Mod), is_atom(Fun), is_integer(Arity) ->
    formatMfa(Mod, Fun, Arity);
sanitize({Name, Arity})
        when is_atom(Name), is_integer(Arity), Arity >= 0, Arity =< 1024 ->
    iolist_to_binary(io_lib:format("~s/~w", [atom_to_list(Name), Arity]));
sanitize(Term) when is_tuple(Term) ->
    toPreview(Term);
sanitize(Term) when is_pid(Term); is_port(Term); is_reference(Term) ->
    toPreview(Term);
sanitize(Term) when is_atom(Term) ->
    Term;
sanitize(Term) when is_binary(Term) ->
    text(Term);
sanitize(Term) when is_integer(Term); is_float(Term); is_boolean(Term) ->
    Term;
sanitize(null) ->
    null;
sanitize(Term) ->
    toPreview(Term).

%% 规范化 map 键（非 atom/binary/integer 时递归 sanitize）。
sanitize_key(K) when is_atom(K); is_binary(K); is_integer(K) ->
    K;
sanitize_key(K) ->
    sanitize(K).

%% 空列表默认为 JSON 数组。
classify_list([]) ->
    array;
classify_list([H | T]) ->
    classify_list(T, kind_of(H)).

%% 根据首元素类型判断列表是字符串、数组还是不透明类型。
classify_list([], Kind) ->
    Kind;
classify_list([H | T], Kind) ->
    case kind_of(H) =:= Kind of
        true -> classify_list(T, Kind);
        false -> opaque
    end.

%% 判断列表元素属于字符串码点、JSON 数组元素还是不透明类型。
kind_of(C) when is_integer(C) -> string;
kind_of(H) when is_tuple(H); is_map(H); is_list(H); is_binary(H);
                is_atom(H); is_boolean(H); H =:= null ->
    array;
kind_of(_) -> opaque.

%% 将 Unicode 字符串列表安全转为 UTF-8 二进制。
safe_utf8_binary(List) when is_list(List) ->
    try
        unicode:characters_to_binary(List)
    catch
        _:_ -> toPreview(List)
    end.

%% 将无法编码的术语格式化为 ~p 预览字符串（截断，避免 fallback 体过大）。
toPreview(Term) ->
    Bin = iolist_to_binary(io_lib:format("~p", [Term])),
    truncatePreview(Bin).

truncatePreview(Bin) when is_binary(Bin) ->
    Max = 512,
    case byte_size(Bin) =< Max of
        true -> Bin;
        false -> <<(binary:part(Bin, 0, Max))/binary, <<"..."/utf8>>/binary>>
    end;
truncatePreview(Term) ->
    truncatePreview(iolist_to_binary(io_lib:format("~p", [Term]))).

%% 去掉非法 UTF-8 字节，避免 jiffy:encode/2 抛错。
-spec sanitize_binary(binary()) -> binary().
sanitize_binary(Bin) when is_binary(Bin) ->
    case unicode:characters_to_binary(Bin, utf8) of
        Good when is_binary(Good) ->
            Good;
        _ ->
            scrub_invalid_utf8(Bin, <<>>)
    end.

scrub_invalid_utf8(<<>>, Acc) ->
    Acc;
scrub_invalid_utf8(<<C/utf8, Rest/binary>>, Acc) ->
    scrub_invalid_utf8(Rest, <<Acc/binary, C/utf8>>);
scrub_invalid_utf8(<<_, Rest/binary>>, Acc) ->
    scrub_invalid_utf8(Rest, Acc).

%% 将 MFA 元组格式化为 "Mod:Fun/Arity" 字符串。
formatMfa(Mod, Fun, Arity) ->
    iolist_to_binary(io_lib:format("~s:~s/~w", [
        atom_to_list(Mod), atom_to_list(Fun), Arity
    ])).
