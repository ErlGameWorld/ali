%%%-------------------------------------------------------------------
%%% @doc Web 安全加固辅助：CORS 白名单、速率限制、常数时间令牌比较、
%%% 写类请求/本地回环判定。
%%%
%%% 由 {@link alWebHer} 在请求入口处调用。除速率限制依赖 ETS 计数表外，
%%% 其余均为纯函数，便于单元测试。
%%%
%%% 相关配置（config.cfg / 应用环境 `ali`）：
%%% <ul>
%%%   <li>`webAllowOrigin' — CORS 放行来源：`<<>>'（默认，不放行跨源）、
%%%       `<<"*">>'、单个来源或来源列表。</li>
%%%   <li>`webRateLimit' — 每个来源 IP 在时间窗内的最大请求数（0 表示关闭）。</li>
%%%   <li>`webRateWindowMs' — 速率窗口长度（毫秒，默认 60000）。</li>
%%%   <li>`webAllowRemoteWrites' — 未配置 token 时是否允许非回环地址执行写操作
%%%       （默认 false：远程写需 token）。</li>
%%% </ul>
%%% @end
%%%-------------------------------------------------------------------
-module(alWebSec).

-export([
    corsHeaders/1,
    corsHeaders/2,
    resolveOrigin/2,
    securityHeaders/0,
    constantEq/2,
    isWrite/1,
    isSideEffectPath/1,
    isProtectedPath/2,
    isLoopback/1,
    checkRate/1,
    resetRate/0,
    ensureStarted/0,
    formatIp/1
]).

-define(RATE_TABLE, alWebRate).
-define(DEFAULT_RATE_LIMIT, 240).
-define(DEFAULT_RATE_WINDOW, 60000).

%%%===================================================================
%%% CORS
%%%===================================================================

%% @doc 依应用配置 `webAllowOrigin` 计算 CORS 响应头。
-spec corsHeaders(binary() | undefined) -> [{binary(), binary()}].
corsHeaders(Origin) ->
    corsHeaders(Origin, alConfig:val(webAllowOrigin)).

%% @doc 依给定白名单配置计算 CORS 响应头（纯函数）。
-spec corsHeaders(binary() | undefined, term()) -> [{binary(), binary()}].
corsHeaders(Origin, Config) ->
    case resolveOrigin(Origin, Config) of
        false -> [];
        {true, Value} ->
            [
                {<<"Access-Control-Allow-Origin"/utf8>>, Value},
                {<<"Vary"/utf8>>, <<"Origin"/utf8>>},
                {<<"Access-Control-Allow-Methods"/utf8>>, <<"GET, POST, OPTIONS"/utf8>>},
                {<<"Access-Control-Allow-Headers"/utf8>>, <<"Content-Type, Authorization"/utf8>>},
                {<<"Access-Control-Max-Age"/utf8>>, <<"600"/utf8>>}
            ]
    end.

%% @doc 判定来源是否放行：返回 `{true, 回填的 Origin 值}' 或 `false'。
-spec resolveOrigin(binary() | undefined, term()) -> {true, binary()} | false.
resolveOrigin(_Origin, Config) when Config =:= <<>>; Config =:= ""; Config =:= undefined ->
    false;
resolveOrigin(_Origin, <<"*"/utf8>>) -> {true, <<"*"/utf8>>};
resolveOrigin(_Origin, "*") -> {true, <<"*"/utf8>>};
resolveOrigin(Origin, Config) when is_binary(Config) ->
    matchOrigin(Origin, [Config]);
resolveOrigin(Origin, Config) when is_list(Config) ->
    Allowed = case isString(Config) of
        true -> [unicode:characters_to_binary(Config)];
        false -> [toBin(C) || C <- Config]
    end,
    matchOrigin(Origin, Allowed);
resolveOrigin(_Origin, _Config) ->
    false.

matchOrigin(undefined, _Allowed) -> false;
matchOrigin(Origin, Allowed) ->
    case lists:member(Origin, Allowed) of
        true -> {true, Origin};
        false -> false
    end.

isString([]) -> false;
isString(L) when is_list(L) -> lists:all(fun(C) -> is_integer(C) andalso C >= 0 end, L);
isString(_) -> false.

%% @doc 通用安全响应头（防嗅探、防点击劫持、限制 referrer）。
-spec securityHeaders() -> [{binary(), binary()}].
securityHeaders() ->
    [
        {<<"X-Content-Type-Options"/utf8>>, <<"nosniff"/utf8>>},
        {<<"X-Frame-Options"/utf8>>, <<"DENY"/utf8>>},
        {<<"Referrer-Policy"/utf8>>, <<"no-referrer"/utf8>>}
    ].

%%%===================================================================
%%% 令牌比较 / 请求分类
%%%===================================================================

%% @doc 常数时间二进制比较（避免基于耗时的令牌侧信道）。
-spec constantEq(binary(), binary()) -> boolean().
constantEq(A, B) when is_binary(A), is_binary(B), byte_size(A) =:= byte_size(B) ->
    Diff = lists:foldl(fun({X, Y}, Acc) -> Acc bor (X bxor Y) end, 0,
                       lists:zip(binary_to_list(A), binary_to_list(B))),
    Diff =:= 0;
constantEq(_, _) ->
    false.

%% @doc 判定 HTTP 方法是否为写/变更类。
-spec isWrite(atom() | binary()) -> boolean().
isWrite('POST') -> true;
isWrite('PUT') -> true;
isWrite('DELETE') -> true;
isWrite('PATCH') -> true;
isWrite(M) when is_binary(M) ->
    lists:member(string:uppercase(M), [<<"POST"/utf8>>, <<"PUT"/utf8>>, <<"DELETE"/utf8>>, <<"PATCH"/utf8>>]);
isWrite(_) -> false.

%% @doc 判定路径是否会触发 Agent 副作用（即使 HTTP 方法为 GET）。
-spec isSideEffectPath(binary()) -> boolean().
isSideEffectPath(<<"/api/ask/stream">>) -> true;
isSideEffectPath(<<"/api/ask/start">>) -> true;
isSideEffectPath(<<"/api/ask", _/binary>>) -> true;
isSideEffectPath(_) -> false.

%% @doc 判定请求是否需 token 或本地回环（无 token 配置时）。
-spec isProtectedPath(atom() | binary(), binary()) -> boolean().
isProtectedPath(Method, Path) ->
    isWrite(Method)
        orelse Path =:= <<"/ws"/utf8>>
        orelse isSideEffectPath(Path)
        orelse isSensitiveRead(Path).

isSensitiveRead(<<"/api/status">>) -> true;
isSensitiveRead(<<"/api/tools">>) -> true;
isSensitiveRead(<<"/api/metrics", _/binary>>) -> true;
isSensitiveRead(<<"/api/plan", _/binary>>) -> true;
isSensitiveRead(<<"/api/pending/", _/binary>>) -> true;
isSensitiveRead(<<"/api/sessions", _/binary>>) -> true;
isSensitiveRead(<<"/api/audit", _/binary>>) -> true;
isSensitiveRead(<<"/api/tasks", _/binary>>) -> true;
isSensitiveRead(<<"/api/tokenStats", _/binary>>) -> true;
isSensitiveRead(<<"/api/backups", _/binary>>) -> true;
isSensitiveRead(<<"/api/mode", _/binary>>) -> true;
isSensitiveRead(<<"/api/clear", _/binary>>) -> true;
isSensitiveRead(<<"/api/approve", _/binary>>) -> true;
isSensitiveRead(<<"/api/dismiss", _/binary>>) -> true;
isSensitiveRead(<<"/api/index", _/binary>>) -> true;
isSensitiveRead(<<"/api/eunit", _/binary>>) -> true;
isSensitiveRead(<<"/api/ct", _/binary>>) -> true;
isSensitiveRead(<<"/api/format", _/binary>>) -> true;
isSensitiveRead(<<"/api/preview", _/binary>>) -> true;
isSensitiveRead(_) -> false.

%% @doc 判定对端地址是否为本地回环（IPv4 127.0.0.0/8 或 IPv6 ::1）。
-spec isLoopback(tuple() | undefined) -> boolean().
isLoopback({127, _, _, _}) -> true;
isLoopback({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
isLoopback({0, 0, 0, 0, 0, 16#FFFF, AB, _}) when AB band 16#FF00 =:= 16#7F00 -> true; %% ::ffff:127.x.x.x
isLoopback(_) -> false.

%% @doc 将 IP 元组格式化为可读字符串。
-spec formatIp(tuple() | undefined) -> binary().
formatIp(undefined) -> <<"unknown"/utf8>>;
formatIp(Ip) when is_tuple(Ip) ->
    case inet:ntoa(Ip) of
        {error, _} -> <<"unknown"/utf8>>;
        Str -> unicode:characters_to_binary(Str)
    end;
formatIp(_) -> <<"unknown"/utf8>>.

%%%===================================================================
%%% 速率限制（ETS 滑动窗口）
%%%===================================================================

%% @doc 检查并累计某来源 IP 的请求计数；超限返回 `{error, rate_limited}'。
%% 使用滑动窗口算法：记录最近窗口内的请求时间戳列表，统计窗口内请求数。
%% 相比固定窗口，可避免窗口边界处的 2 倍突发流量。
%% 未知来源（undefined）或限速关闭（limit=0）时直接放行。
-spec checkRate(tuple() | undefined) -> ok | {error, rate_limited}.
checkRate(undefined) -> ok;
checkRate(Ip) ->
    Limit = alConfig:val(webRateLimit),
    case Limit of
        N when is_integer(N), N =< 0 -> ok;
        Limit2 when is_integer(Limit2) ->
            Window = alConfig:val(webRateWindowMs),
            ensureTable(),
            Now = erlang:system_time(millisecond),
            Cutoff = Now - Window,
            case ets:lookup(?RATE_TABLE, Ip) of
                [{Ip, Timestamps}] ->
                    %% 保留窗口内的时间戳，过滤过期的
                    Recent = [T || T <- Timestamps, T > Cutoff],
                    case length(Recent) >= Limit2 of
                        true ->
                            {error, rate_limited};
                        false ->
                            %% 添加当前时间戳，限制列表长度防止内存膨胀
                            NewList = [Now | Recent],
                            Trimmed = case length(NewList) > Limit2 * 2 of
                        true -> lists:sublist(NewList, Limit2 * 2);
                        false -> NewList
                    end,
                    ets:insert(?RATE_TABLE, {Ip, Trimmed}),
                    ok
                    end;
                _ ->
                    ets:insert(?RATE_TABLE, {Ip, [Now]}),
                    ok
            end;
        _ -> ok
    end.

%% @doc 清空速率计数（测试与运维用）。
-spec resetRate() -> ok.
resetRate() ->
    case ets:whereis(?RATE_TABLE) of
        undefined -> ok;
        _ -> ets:delete_all_objects(?RATE_TABLE), ok
    end.

%% @doc 创建速率计数表（由长生命周期进程调用，如 alWebSrv，避免随连接进程消亡）。
-spec ensureStarted() -> ok.
ensureStarted() -> ensureTable().

ensureTable() ->
    case ets:whereis(?RATE_TABLE) of
        undefined ->
            try ets:new(?RATE_TABLE, [named_table, public, set]) catch _:_ -> ok end,
            ok;
        _ -> ok
    end.

%%%===================================================================
%%% 辅助
%%%===================================================================

toBin(X) when is_binary(X) -> X;
toBin(X) when is_list(X) -> unicode:characters_to_binary(X);
toBin(X) when is_atom(X) -> atom_to_binary(X, utf8);
toBin(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).
