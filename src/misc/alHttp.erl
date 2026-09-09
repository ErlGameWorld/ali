%%%-------------------------------------------------------------------
%% @doc 基于 eWCli 的 HTTP 客户端封装。
%%
%% 同步请求统一返回 `{ok, Status, Headers, Body}'（Body 恒为 binary），
%% 兼容原 hackney 调用形态与 `httpRequestFun` mock。
%% @end
%%%-------------------------------------------------------------------
-module(alHttp).

-include_lib("eWCli/include/wcCli.hrl").

-export([
    ensureStarted/0,
    request/5,
    get/3,
    post/4,
    requestCapped/5,
    findHeader/2,
    truncateUtf8/2,
    uppercaseMethod/1
]).

%%--------------------------------------------------------------------
%% @doc 确保 eWCli 应用已启动（仅应在 ali_app:start 时调用一次）。
%%--------------------------------------------------------------------
-spec ensureStarted() -> ok.
ensureStarted() ->
    _ = application:ensure_all_started(eWCli),
    ok.

%%--------------------------------------------------------------------
%% @doc 同步 HTTP 请求。
%% Opts 可为 map（eWCli 原生）或 proplist（兼容旧 hackney 选项名）。
%% 调用前须已启动 eWCli（见 ali_app / ensureStarted/0）。
%% @end
%%--------------------------------------------------------------------
-spec request(atom() | binary(), binary() | string(), list(), iodata(), map() | list()) ->
    {ok, pos_integer(), list(), binary()} | {error, term()}.
request(Method, Url, Headers, Body, Opts) ->
    OptsMap = normalizeOpts(Opts),
    MethodBin = uppercaseMethod(Method),
    try eWCli:request(MethodBin, Url, Headers, Body, OptsMap) of
        {ok, #wcResp{status = Status, headers = RespHeaders, body = RespBody}} ->
            {ok, Status, RespHeaders, bodyOrEmpty(RespBody)};
        {error, Reason} ->
            {error, Reason}
    catch
        exit:Reason -> {error, {httpExit, Reason}};
        error:Reason -> {error, {httpError, Reason}};
        throw:Reason -> {error, {httpError, Reason}}
    end.

-spec get(binary() | string(), list(), map() | list()) ->
    {ok, pos_integer(), list(), binary()} | {error, term()}.
get(Url, Headers, Opts) ->
    request(get, Url, Headers, <<>>, Opts).

-spec post(binary() | string(), list(), iodata(), map() | list()) ->
    {ok, pos_integer(), list(), binary()} | {error, term()}.
post(Url, Headers, Body, Opts) ->
    request(post, Url, Headers, Body, Opts).

%%--------------------------------------------------------------------
%% @doc 请求并在 MaxBytes 处截断正文（用于 fetchUrl 等）。
%% 返回 `{ok, Status, Headers, Body, Truncated}'。
%% 手动跟随重定向场景请设 `maxRedirects => 0`。
%% @end
%%--------------------------------------------------------------------
-spec requestCapped(atom() | binary(), binary() | string(), list(), iodata(), map()) ->
    {ok, pos_integer(), list(), binary(), boolean()} | {error, term()}.
requestCapped(Method, Url, Headers, Body, Opts0) when is_map(Opts0) ->
    MaxBytes = maps:get(maxBytes, Opts0, 51200),
    Opts1 = normalizeOpts(maps:without([maxBytes], Opts0)),
    Key = {alHttpCap, make_ref()},
    put(Key, #{status => undefined, headers => [], acc => [], size => 0, trunc => false}),
    Handler = fun(Ev) -> cappedHandler(Key, MaxBytes, Ev) end,
    StreamOpts = Opts1#{
        format => raw,
        withBody => false,
        maxBody => infinity,
        handler => Handler
    },
    Result = try eWCli:stream(uppercaseMethod(Method), Url, Headers, Body, StreamOpts)
             catch
                 exit:R -> {error, {httpExit, R}};
                 error:R -> {error, {httpError, R}};
                 throw:R -> {error, {httpError, R}}
             end,
    St = erase(Key),
    case {Result, St} of
        {ok, #{status := Status, headers := Hs}} when is_integer(Status) ->
            Acc = maps:get(acc, St, []),
            Trunc = maps:get(trunc, St, false),
            Raw = iolist_to_binary(lists:reverse(Acc)),
            Body1 = truncateUtf8(Raw, MaxBytes),
            {ok, Status, Hs, Body1, Trunc orelse byte_size(Raw) > MaxBytes};
        {{error, cancelled}, #{status := Status, headers := Hs}} when is_integer(Status) ->
            Acc = maps:get(acc, St, []),
            Raw = iolist_to_binary(lists:reverse(Acc)),
            {ok, Status, Hs, truncateUtf8(Raw, MaxBytes), true};
        {{error, Reason}, _} ->
            {error, Reason};
        {Other, _} ->
            {error, Other}
    end.

%%--------------------------------------------------------------------
%% @doc 大小写不敏感查找响应头。
%%--------------------------------------------------------------------
-spec findHeader(binary(), list()) -> {ok, binary()} | error.
findHeader(Name, Headers) when is_binary(Name), is_list(Headers) ->
    Target = string:lowercase(Name),
    findHeader1(Target, Headers);
findHeader(_, _) ->
    error.

findHeader1(_Target, []) ->
    error;
findHeader1(Target, [{K, V} | Rest]) ->
    Key = case K of
        B when is_binary(B) -> string:lowercase(B);
        L when is_list(L) -> string:lowercase(unicode:characters_to_binary(L));
        A when is_atom(A) -> string:lowercase(atom_to_binary(A, utf8));
        _ -> <<>>
    end,
    case Key =:= Target of
        true -> {ok, toBin(V)};
        false -> findHeader1(Target, Rest)
    end.

%%--------------------------------------------------------------------
%% @doc UTF-8 安全截断。
%%--------------------------------------------------------------------
-spec truncateUtf8(binary(), non_neg_integer()) -> binary().
truncateUtf8(Bin, Max) when is_binary(Bin), byte_size(Bin) =< Max ->
    Bin;
truncateUtf8(Bin, Max) when is_binary(Bin) ->
    binary:part(Bin, 0, truncateUtf8Len(Bin, min(Max, byte_size(Bin))));
truncateUtf8(_Bin, _Max) ->
    <<>>.

%%%===================================================================
%%% Internal
%%%===================================================================

cappedHandler(Key, _MaxBytes, {headers, Status, Hs, _Ver, _Reason}) ->
    St = get(Key),
    put(Key, St#{status => Status, headers => Hs}),
    continue;
cappedHandler(Key, MaxBytes, {chunk, Bin}) when is_binary(Bin) ->
    St = get(Key),
    Acc0 = maps:get(acc, St, []),
    Size0 = maps:get(size, St, 0),
    Size1 = Size0 + byte_size(Bin),
    case Size1 >= MaxBytes of
        true ->
            Need = max(0, MaxBytes - Size0),
            Piece = case Need > 0 of
                true -> binary:part(Bin, 0, min(Need, byte_size(Bin)));
                false -> <<>>
            end,
            Acc1 = case Piece of <<>> -> Acc0; _ -> [Piece | Acc0] end,
            put(Key, St#{acc => Acc1, size => Size0 + byte_size(Piece), trunc => true}),
            stop;
        false ->
            put(Key, St#{acc => [Bin | Acc0], size => Size1}),
            continue
    end;
cappedHandler(_Key, _MaxBytes, done) ->
    continue;
cappedHandler(_Key, _MaxBytes, {trailers, _}) ->
    continue;
cappedHandler(_Key, _MaxBytes, _) ->
    continue.

%% 兼容 hackney proplist / 旧键名 → eWCli map 键
normalizeOpts(Opts) when is_map(Opts) ->
    Base = maps:fold(fun(K, V, Acc) ->
        Acc#{canonKey(K) => canonVal(K, V)}
    end, #{}, Opts),
    applyFollowRedirect(Base);
normalizeOpts(Opts) when is_list(Opts) ->
    Base = lists:foldl(fun
        ({K, V}, Acc) -> Acc#{canonKey(K) => canonVal(K, V)};
        (_, Acc) -> Acc
    end, #{}, Opts),
    applyFollowRedirect(Base);
normalizeOpts(_) ->
    #{}.

applyFollowRedirect(Opts) ->
    case maps:take(followRedirect, Opts) of
        {false, Rest} -> Rest#{maxRedirects => 0};
        {true, Rest} ->
            case maps:is_key(maxRedirects, Rest) of
                true -> Rest;
                false -> Rest#{maxRedirects => 5}
            end;
        error ->
            Opts
    end.

canonKey(recv_timeout) -> recvTimeout;
canonKey(connect_timeout) -> connectTimeout;
canonKey(follow_redirect) -> followRedirect;
canonKey(with_body) -> withBody;
canonKey(max_body) -> maxBody;
canonKey(ssl_options) -> sslOpts;
canonKey(pool) -> usePool;
canonKey(K) when is_atom(K) -> K;
canonKey(K) when is_binary(K) ->
    try binary_to_existing_atom(K, utf8) catch _:_ -> K end;
canonKey(K) -> K.

canonVal(follow_redirect, false) -> false;
canonVal(follow_redirect, true) -> true;
canonVal(followRedirect, false) -> false;
canonVal(followRedirect, true) -> true;
canonVal(pool, false) -> false;
canonVal(pool, true) -> true;
canonVal(usePool, false) -> false;
canonVal(usePool, true) -> true;
canonVal(_K, V) -> V.

bodyOrEmpty(undefined) -> <<>>;
bodyOrEmpty(Bin) when is_binary(Bin) -> Bin;
bodyOrEmpty(Io) -> iolist_to_binary(Io).

%% HTTP 方法名必须大写（llama.cpp 等服务对方法名大小写敏感）。
-spec uppercaseMethod(atom() | binary() | string()) -> binary().
uppercaseMethod(M) when is_atom(M) -> string:uppercase(atom_to_binary(M, utf8));
uppercaseMethod(M) when is_binary(M) -> string:uppercase(M);
uppercaseMethod(M) when is_list(M) -> string:uppercase(unicode:characters_to_binary(M)).

toBin(B) when is_binary(B) -> B;
toBin(L) when is_list(L) -> unicode:characters_to_binary(L);
toBin(A) when is_atom(A) -> atom_to_binary(A, utf8);
toBin(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).

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
