%%%-------------------------------------------------------------------
%%% @doc OTP 27 json 模块的封装层。
%%%
%%% 在编码前对 Erlang 术语做 sanitize，将无法 JSON 化的类型
%%%（pid、tuple、MFA 等）转为可读字符串，避免编码失败。
%%% @end
%%%-------------------------------------------------------------------
-module(llmJson).

-export([encode/1, decode/1, sanitize/1]).

%% @doc 将术语编码为 JSON 二进制；失败时返回含 preview 的错误对象。
-spec encode(term()) -> binary().
encode(Term) ->
    Safe = sanitize(Term),
    try
        iolist_to_binary(json:encode(Safe))
    catch
        _:_ ->
            Fallback = #{
                error => <<"json_encode_failed"/utf8>>,
                preview => toPreview(Term)
            },
            iolist_to_binary(json:encode(Fallback))
    end.

%% @doc 将 JSON 二进制或 iolist 解码为 Erlang 术语。
-spec decode(binary() | iolist()) -> term().
decode(Bin) when is_binary(Bin) ->
    json:decode(Bin);
decode(IOList) when is_list(IOList) ->
    json:decode(iolist_to_binary(IOList)).

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
    Term;
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

%% 将无法编码的术语格式化为 ~p 预览字符串。
toPreview(Term) ->
    iolist_to_binary(io_lib:format("~p", [Term])).

%% 将 MFA 元组格式化为 "Mod:Fun/Arity" 字符串。
formatMfa(Mod, Fun, Arity) ->
    iolist_to_binary(io_lib:format("~s:~s/~w", [
        atom_to_list(Mod), atom_to_list(Fun), Arity
    ])).