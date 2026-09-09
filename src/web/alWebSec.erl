%%%-------------------------------------------------------------------
%%% @doc Web 安全辅助：CORS 白名单、限流、常数时间 token 比较、
%%% 写操作 / loopback 分类。
%%%
%%% 由 alWebHandler 在请求入口调用。除限流（ETS 计数表）外均为纯函数。
%%% @end
%%%-------------------------------------------------------------------

-module(alWebSec).

-export([
    constantEq/2,
    corsHeaders/1,
    corsHeaders/2,
    resolveOrigin/2,
    securityHeaders/0,
    isWrite/1,
    isSideEffectPath/1,
    isPublicPath/2,
    isProtectedPath/2,
    isLoopback/1,
    wsOriginAllowed/3,
    wsOriginAllowed/4,
    isSameOrigin/2,
    isPathWithin/2,
    isDeniedFileApiPath/1,
    checkRate/1,
    checkCsrf/3,
    checkCsrf/4,
    checkCsrf/5,
    resetRate/0,
    ensureStarted/0,
    formatIp/1,
    webOpt/2,
    isLoopbackBound/0
]).

-define(RateTable, ali_web_rate).

%%%===================================================================
%%% CORS
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 生成 CORS 响应头：使用配置中的 `allowOrigin' 决定是否允许当前 Origin。
%%
%% @param Origin 请求来源（binary 或 `undefined'）
%% @return 响应头键值对列表（不允许时为空列表）
%% @end
%%--------------------------------------------------------------------
-spec corsHeaders(binary() | undefined) -> [{binary(), binary()}].
corsHeaders(Origin) ->
    corsHeaders(Origin, webOpt(allowOrigin, <<>>)).

%%--------------------------------------------------------------------
%% @doc
%% 生成 CORS 响应头的可配置版本：根据 {@link resolveOrigin/2} 判定是否允许。
%%
%% @param Origin 请求来源
%% @param Config 允许的 origin 配置（binary/list/通配符 `*'）
%% @return 响应头键值对列表（不允许时为空列表）
%% @end
%%--------------------------------------------------------------------
-spec corsHeaders(binary() | undefined, term()) -> [{binary(), binary()}].
corsHeaders(Origin, Config) ->
    case resolveOrigin(Origin, Config) of
        false -> [];
        {true, Value} ->
            [
                {<<"Access-Control-Allow-Origin">>, Value},
                {<<"Vary">>, <<"Origin">>},
                {<<"Access-Control-Allow-Methods">>, <<"GET, POST, OPTIONS">>},
                {<<"Access-Control-Allow-Headers">>, <<"Content-Type, Authorization">>},
                {<<"Access-Control-Max-Age">>, <<"600">>}
            ]
    end.

%%--------------------------------------------------------------------
%% @doc
%% 解析 Origin 是否被允许（多子句）：
%%  - 空配置返回 false
%%  - 通配符 `*' 返回 `{true, <<"*">>}'
%%  - binary 配置视为单个允许项
%%  - list 配置区分字符串与列表
%%  - 其它返回 false
%%
%% @param Origin 请求来源
%% @param Config 允许配置
%% @return `{true, Value}' | `false'
%% @end
%%--------------------------------------------------------------------
-spec resolveOrigin(binary() | undefined, term()) -> {true, binary()} | false.
resolveOrigin(_Origin, Config) when Config =:= <<>>; Config =:= ""; Config =:= undefined ->
    false;
resolveOrigin(_Origin, <<"*">>) -> {true, <<"*">>};
resolveOrigin(_Origin, "*") -> {true, <<"*">>};
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

%% 判断 Origin 是否在允许列表中；`undefined' 直接返回 false。
matchOrigin(undefined, _Allowed) -> false;
matchOrigin(Origin, Allowed) ->
    case lists:member(Origin, Allowed) of
        true -> {true, Origin};
        false -> false
    end.

%% 判断 list 是否为字符串（所有元素均为非负整数）；空列表视为非字符串。
isString([]) -> false;
isString(L) when is_list(L) -> lists:all(fun(C) -> is_integer(C) andalso C >= 0 end, L);
isString(_) -> false.

%%--------------------------------------------------------------------
%% @doc
%% 返回一组基础安全响应头（nosniff、DENY、no-referrer）。
%%
%% @return 响应头键值对列表
%% @end
%%--------------------------------------------------------------------
-spec securityHeaders() -> [{binary(), binary()}].
securityHeaders() ->
    [
        {<<"X-Content-Type-Options">>, <<"nosniff">>},
        {<<"X-Frame-Options">>, <<"DENY">>},
        {<<"Referrer-Policy">>, <<"no-referrer">>},
        %% 默认同源；Mermaid 仍允许 jsdelivr（若改本地托管可收紧为 'self'）。
        {<<"Content-Security-Policy">>,
         <<"default-src 'self'; script-src 'self'; "
           "style-src 'self' 'unsafe-inline'; img-src 'self' data:; "
           "connect-src 'self'; frame-ancestors 'none'; base-uri 'self'">>}
    ].

%%%===================================================================
%%% Token comparison / request classification
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 常数时间比较两个 binary，避免时序攻击泄露 token 信息（含长度）。
%%
%% 为避免"长度不同即刻返回"泄露预期 token 长度，这里先对两侧各求
%% SHA-256 摘要（固定 32 字节），再对等长摘要逐字节 XOR 归约比较。
%% 无论输入长度是否相同，比较耗时都恒定，且长度信息不通过时序泄露。
%%
%% @param A 待比较 binary
%% @param B 待比较 binary
%% @return `true' | `false'
%% @end
%%--------------------------------------------------------------------
-spec constantEq(binary(), binary()) -> boolean().
constantEq(A, B) when is_binary(A), is_binary(B) ->
    HA = crypto:hash(sha256, A),
    HB = crypto:hash(sha256, B),
    Diff = lists:foldl(fun({X, Y}, Acc) -> Acc bor (X bxor Y) end, 0,
                       lists:zip(binary_to_list(HA), binary_to_list(HB))),
    Diff =:= 0;
constantEq(_, _) ->
    false.

%%--------------------------------------------------------------------
%% @doc
%% 判断 HTTP 方法是否为写操作（POST/PUT/DELETE/PATCH）。
%%
%% @param Method 方法（atom 或 binary）
%% @return `true' | `false'
%% @end
%%--------------------------------------------------------------------
-spec isWrite(atom() | binary()) -> boolean().
isWrite('POST') -> true;
isWrite('PUT') -> true;
isWrite('DELETE') -> true;
isWrite('PATCH') -> true;
isWrite(M) when is_binary(M) ->
    lists:member(string:uppercase(M), [<<"POST">>, <<"PUT">>, <<"DELETE">>, <<"PATCH">>]);
isWrite(_) -> false.

%%--------------------------------------------------------------------
%% @doc
%% 判断路径是否为副作用路径（会改变状态或触发工具调用）。
%%
%% @param Path 请求路径 binary
%% @return `true' | `false'
%% @end
%%--------------------------------------------------------------------
-spec isSideEffectPath(binary()) -> boolean().
isSideEffectPath(<<"/api/ask/stream">>) -> true;
isSideEffectPath(<<"/api/ask/start">>) -> true;
isSideEffectPath(<<"/api/ask", _/binary>>) -> true;
%% 带副作用的 GET：git 增量索引会触发写入/索引
isSideEffectPath(<<"/api/index", _/binary>>) -> true;
isSideEffectPath(<<"/api/digest/build", _/binary>>) -> true;
isSideEffectPath(<<"/tool">>) -> true;
isSideEffectPath(<<"/v1/tools/call">>) -> true;
isSideEffectPath(_) -> false.

%%--------------------------------------------------------------------
%% @doc
%% 判断路径是否为公开路径（默认拒绝授权模型下的白名单）。
%%
%% 仅以下路径公开：OPTIONS 预检、首页 `/`、静态资源 `/static/*`、
%% 健康检查 `/api/health`。其余全部视为受保护。
%%
%% @param Method HTTP 方法
%% @param Path 请求路径 binary
%% @return `true' | `false'
%% @end
%%--------------------------------------------------------------------
-spec isPublicPath(atom() | binary(), binary()) -> boolean().
isPublicPath('OPTIONS', _Path) -> true;
isPublicPath(<<"OPTIONS">>, _Path) -> true;
isPublicPath('GET', <<"/">>) -> true;
isPublicPath('GET', <<"/static/", _/binary>>) -> true;
isPublicPath('GET', <<"/api/health">>) -> true;
isPublicPath(_Method, _Path) -> false.

%%--------------------------------------------------------------------
%% @doc
%% 判断请求是否需要鉴权保护：默认拒绝式——除少数公开路径外，
%% 所有请求（含全部 /api/*、/ws、工具端点）一律受保护。
%%
%% @param Method HTTP 方法
%% @param Path 请求路径
%% @return `true' | `false'
%% @end
%%--------------------------------------------------------------------
-spec isProtectedPath(atom() | binary(), binary()) -> boolean().
isProtectedPath(Method, Path) ->
    not isPublicPath(Method, Path).

%%--------------------------------------------------------------------
%% @doc
%% 判断 IP 是否为回环地址（IPv4 127.x.x.x 或 IPv6 ::1，含 IPv4 映射的 IPv6）。
%%
%% @param Ip IP 元组或 `undefined'
%% @return `true' | `false'
%% @end
%%--------------------------------------------------------------------
-spec isLoopback(tuple() | undefined) -> boolean().
isLoopback({127, _, _, _}) -> true;
isLoopback({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
isLoopback({0, 0, 0, 0, 0, 16#FFFF, AB, _}) when AB band 16#FF00 =:= 16#7F00 -> true;
isLoopback(_) -> false.

%%--------------------------------------------------------------------
%% @doc
%% 判断 Web 网关是否只监听回环地址（127.0.0.1 / localhost / ::1）。
%% 用于鉴权兜底：仅当服务本身只绑定回环时，才允许用 Host/Origin 头
%% 判断"本机客户端"（避免公网绑定 + peername 失败时被伪造 Host 头绕过）。
%%
%% @return `true' | `false'
%% @end
%%--------------------------------------------------------------------
-spec isLoopbackBound() -> boolean().
isLoopbackBound() ->
    Bind = webOpt(bindAddress, <<"127.0.0.1">>),
    B = case Bind of
        L when is_list(L) -> string:lowercase(L);
        A when is_atom(A) -> string:lowercase(atom_to_list(A));
        Bin when is_binary(Bin) -> string:lowercase(unicode:characters_to_list(Bin));
        _ -> ""
    end,
    lists:member(B, ["127.0.0.1", "localhost", "::1", "[::1]", "0:0:0:0:0:0:0:1"]).

%%--------------------------------------------------------------------
%% @doc
%% 校验 WebSocket 升级请求的 Origin 是否被允许（防跨站 WS 劫持 CSWSH）。
%%
%% 规则（默认拒绝式）：
%%  - Origin 缺失（非浏览器客户端，如 CLI/原生 WS）：放行——CSWSH 只针对
%%    会自动带 Origin 的浏览器场景。
%%  - 显式配置了 allowOrigin 白名单且匹配：放行。
%%  - 否则仅允许同源的 localhost / 127.0.0.1（http/https，带当前监听端口）。
%%
%% @param Origin 请求 Origin 头（binary 或 undefined）
%% @param Port   当前监听端口
%% @param Config allowOrigin 配置
%% @return `true' | `false'
%% @end
%%--------------------------------------------------------------------
-spec wsOriginAllowed(binary() | undefined, integer(), term()) -> boolean().
wsOriginAllowed(Origin, Port, Config) ->
    wsOriginAllowed(Origin, Port, Config, undefined).

%% 四参版：额外用 Host 头做同源判定（LAN IP/域名打开页面时 Origin≠localhost）。
-spec wsOriginAllowed(binary() | undefined, integer(), term(), binary() | undefined) -> boolean().
wsOriginAllowed(undefined, _Port, _Config, _Host) ->
    true;
wsOriginAllowed(Origin, Port, Config, Host) when is_binary(Origin) ->
    case resolveOrigin(Origin, Config) of
        {true, _} -> true;
        false ->
            lists:member(Origin, defaultLocalOrigins(Port))
                orelse isSameOrigin(Origin, Host)
    end;
wsOriginAllowed(_Origin, _Port, _Config, _Host) ->
    false.

%%--------------------------------------------------------------------
%% @doc
%% 判断浏览器 Origin 是否与请求 Host 同源（scheme 忽略，比 host:port）。
%% 用于内网用 IP/域名打开 WebUI：Origin=http://192.168.x.x:8787 且 Host 相同则放行。
%% @end
%%--------------------------------------------------------------------
-spec isSameOrigin(binary() | undefined, binary() | undefined) -> boolean().
isSameOrigin(undefined, _) -> false;
isSameOrigin(_, undefined) -> false;
isSameOrigin(Origin, Host) when is_binary(Origin), is_binary(Host) ->
    OriginHost = originHostPort(Origin),
    ReqHost = string:lowercase(string:trim(Host)),
    OriginHost =/= <<>> andalso OriginHost =:= ReqHost;
isSameOrigin(_, _) -> false.

%% 从 Origin URL 取出 host:port（小写）；缺省端口不补全，与 Host 头原样对齐。
originHostPort(Origin) when is_binary(Origin) ->
    L0 = string:lowercase(string:trim(Origin)),
    L1 = case L0 of
        <<"http://", R/binary>> -> R;
        <<"https://", R/binary>> -> R;
        <<"ws://", R/binary>> -> R;
        <<"wss://", R/binary>> -> R;
        _ -> L0
    end,
    case binary:split(L1, <<"/">>) of
        [H | _] -> string:trim(H);
        _ -> string:trim(L1)
    end.

%% 生成本机同源默认白名单：localhost / 127.0.0.1 的 http/https + 端口。
defaultLocalOrigins(Port) ->
    P = integer_to_binary(Port),
    [
        <<"http://localhost:", P/binary>>,
        <<"http://127.0.0.1:", P/binary>>,
        <<"https://localhost:", P/binary>>,
        <<"https://127.0.0.1:", P/binary>>
    ].

%%--------------------------------------------------------------------
%% @doc
%% 判断 Full 路径规范化后是否位于 Root 目录之内（含 Root 自身），
%% 用于防路径穿越：拒绝 `..` 逃逸与指向 Root 之外的绝对路径。
%%
%% @param Root 根目录（binary 或 string）
%% @param Full 目标路径（binary 或 string）
%% @return `true'（安全，在 Root 内）| `false'（越界，应拒绝）
%% @end
%%--------------------------------------------------------------------
-spec isPathWithin(binary() | string(), binary() | string()) -> boolean().
isPathWithin(Root, Full) ->
    RootAbs = filename:absname(toCharlistPath(Root)),
    FullAbs = filename:absname(toCharlistPath(Full)),
    RootParts = filename:split(RootAbs),
    FullParts = filename:split(FullAbs),
    NoTraversal = not lists:member("..", FullParts),
    WithinRoot = length(FullParts) >= length(RootParts)
        andalso lists:sublist(FullParts, length(RootParts)) =:= RootParts,
    NoTraversal andalso WithinRoot.

toCharlistPath(V) when is_binary(V) -> binary_to_list(V);
toCharlistPath(V) when is_list(V) -> V.

%%--------------------------------------------------------------------
%% @doc
%% Web 文件 API（/api/files、/api/file）路径拒绝策略：目录段命中
%% `.git` / `.ali` / `.svn` / `_build`（以及默认的 `config`）或敏感
%% basename（`*.env` / `*.key` / `*.pem` / credentials 等）时返回 true。
%% `web.allowConfigBrowse=true` 时可浏览 `config/`（仍拦密钥文件）。
%%
%% @param Path 客户端相对/绝对路径
%% @return true=应拒绝 | false=可通过（仍须走 projectRoot 校验）
%% @end
%%--------------------------------------------------------------------
-spec isDeniedFileApiPath(binary() | string()) -> boolean().
isDeniedFileApiPath(Path) ->
    Parts = [string:lowercase(P) || P <- filename:split(toCharlistPath(Path)),
                                    P =/= ".", P =/= ""],
    DeniedSegs0 = [".git", ".ali", ".svn", "_build"],
    DeniedSegs = case webOpt(allowConfigBrowse, false) of
        true -> DeniedSegs0;
        _ -> ["config" | DeniedSegs0]
    end,
    lists:any(fun(Seg) -> lists:member(Seg, DeniedSegs) end, Parts)
        orelse case Parts of
            [] -> false;
            _ -> isSensitiveApiBasename(lists:last(Parts))
        end.

isSensitiveApiBasename(Base) ->
    lists:member(Base, ["alicfg.cfg", ".env", "credentials.json",
                        "erl_crash.dump", "rebar3.crashdump"])
        orelse lists:suffix(".env", Base)
        orelse lists:suffix(".key", Base)
        orelse lists:suffix(".pem", Base)
        orelse lists:suffix(".secret", Base).

%%--------------------------------------------------------------------
%% @doc
%% 将 IP 元组格式化为 binary 字符串；`undefined' 或异常时返回 `<<"unknown">>'。
%%
%% @param Ip IP 元组或 `undefined'
%% @return IP 字符串 binary
%% @end
%%--------------------------------------------------------------------
-spec formatIp(tuple() | undefined) -> binary().
formatIp(undefined) -> <<"unknown">>;
formatIp(Ip) when is_tuple(Ip) ->
    case inet:ntoa(Ip) of
        {error, _} -> <<"unknown">>;
        Str -> unicode:characters_to_binary(Str)
    end;
formatIp(_) -> <<"unknown">>.

%%%===================================================================
%%% Rate limiting (ETS sliding window)
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 滑动窗口限流检查：在 `rateWindowMs' 时间窗内同一 IP 的请求数不得超过 `rateLimit'。
%%
%% 限流关闭（Limit <= 0）或 IP 为 `undefined' 时直接放行；
%% 超限时返回 `{error, rateLimited}'，否则记录当前时间戳并放行。
%%
%% @param Ip 客户端 IP 元组或 `undefined'
%% @return `ok' | `{error, rateLimited}'
%% @end
%%--------------------------------------------------------------------
-spec checkRate(tuple() | undefined) -> ok | {error, rateLimited}.
%% IP 未知（peername 失败）时不直接放行，而是并入一个共享桶统一限流，
%% 避免攻击者借"无法取到 IP"绕过限流。
checkRate(undefined) -> checkRate({unknown, peer});
checkRate(Ip) ->
    Limit = webOpt(rateLimit, 0),
    case Limit of
        N when is_integer(N), N =< 0 -> ok;
        Limit2 when is_integer(Limit2) ->
            Window = webOpt(rateWindowMs, 60000),
            ensureTable(),
            Now = erlang:system_time(millisecond),
            maybeAgeOut(Now, Window),
            %% 固定窗口 + ets:update_counter：原子 RMW，避免并发 lookup/insert 双放行
            WindowId = Now div max(Window, 1),
            Key = {Ip, WindowId},
            Count = ets:update_counter(?RateTable, Key, {2, 1}, {Key, 0}),
            case Count > Limit2 of
                true -> {error, rateLimited};
                false -> ok
            end;
        _ -> ok
    end.

%%--------------------------------------------------------------------
%% @doc
%% 清空限流计数表（用于测试或重置）。
%%
%% @return `ok'
%% @end
%%--------------------------------------------------------------------
-spec resetRate() -> ok.
resetRate() ->
    case ets:whereis(?RateTable) of
        undefined -> ok;
        _ -> ets:delete_all_objects(?RateTable), ok
    end.

%%--------------------------------------------------------------------
%% @doc
%% CSRF 检查：对写操作（POST/PUT/DELETE/PATCH）校验 Origin 头。
%% 当配置了 allowOrigin 白名单时，要求 Origin 匹配；
%% 未配置 allowOrigin 时仅允许回环地址发起写请求。
%%
%% @param Method HTTP 方法
%% @param Origin 请求 Origin 头（binary 或 undefined）
%% @param Ip      客户端 IP 元组
%% @return `ok' | `{error, csrfDenied}'
%% @end
%%--------------------------------------------------------------------
-spec checkCsrf(atom() | binary(), binary() | undefined, tuple() | undefined) -> ok | {error, csrfDenied}.
checkCsrf(Method, Origin, Ip) ->
    checkCsrf(Method, <<>>, Origin, Ip).

%%--------------------------------------------------------------------
%% @doc
%% CSRF 检查（带路径版）：对写操作以及带副作用的 GET（如 ask/stream、
%% index/git）校验 Origin 头。回环地址放行；否则要求 Origin 命中
%% allowOrigin 白名单。
%%
%% @param Method HTTP 方法
%% @param Path   请求路径（用于识别带副作用的 GET）
%% @param Origin 请求 Origin 头（binary 或 undefined）
%% @param Ip     客户端 IP 元组
%% @return `ok' | `{error, csrfDenied}'
%% @end
%%--------------------------------------------------------------------
-spec checkCsrf(atom() | binary(), binary(), binary() | undefined, tuple() | undefined) -> ok | {error, csrfDenied}.
checkCsrf(Method, Path, Origin, Ip) ->
    checkCsrf(Method, Path, Origin, Ip, undefined).

%% 五参版：带 Host，LAN 同源写请求可过 CSRF（不依赖 allowOrigin 白名单）。
-spec checkCsrf(atom() | binary(), binary(), binary() | undefined, tuple() | undefined,
                binary() | undefined) -> ok | {error, csrfDenied}.
checkCsrf(Method, Path, Origin, Ip, Host) ->
    NeedGuard = isWrite(Method) orelse isSideEffectPath(Path),
    case NeedGuard of
        false -> ok;
        true ->
            Allowed = webOpt(allowOrigin, <<>>),
            case resolveOrigin(Origin, Allowed) of
                {true, _} -> ok;
                false ->
                    case Origin of
                        undefined ->
                            %% 非浏览器客户端（curl / 本地工具 / MCP）：不携带 Origin。
                            %% 回环放行；非回环拒绝（远程写须配置 allowOrigin 白名单）。
                            case isLoopback(Ip) of
                                true -> ok;
                                false -> {error, csrfDenied}
                            end;
                        _ ->
                            %% 浏览器请求：即使回环也校验 Origin，堵住本地恶意网页
                            %% 对 127.0.0.1 的 CSRF 绕过（DNS rebinding / 直连回环）。
                            %% 放行条件：本机同源（localhost/127.0.0.1/[::1]）或
                            %% 与 Host 同源（内网 IP/域名打开 WebUI）。
                            case isLocalOrigin(Origin) orelse isSameOrigin(Origin, Host) of
                                true -> ok;
                                false -> {error, csrfDenied}
                            end
                    end
            end
    end.

%% 判断 Origin 是否指向本机（localhost / 127.0.0.1 / [::1]，允许带端口）。
isLocalOrigin(Origin) when is_binary(Origin) ->
    HP = string:lowercase(string:trim(originHostPort(Origin))),
    Prefixes = [<<"localhost">>, <<"127.0.0.1">>, <<"[::1]">>],
    lists:any(fun(P) ->
        HP =:= P orelse binary:match(HP, <<P/binary, ":">>) =/= nomatch
    end, Prefixes);
isLocalOrigin(_) -> false.

%%--------------------------------------------------------------------
%% @doc
%% 模块初始化入口：确保限流 ETS 表存在。
%%
%% @return `ok'
%% @end
%%--------------------------------------------------------------------
-spec ensureStarted() -> ok.
ensureStarted() -> ensureTable().

%%--------------------------------------------------------------------
%% @doc
%% 确保限流 ETS 表已创建；已存在则直接返回 ok，创建失败也容忍。
%%
%% @return `ok'
%% @end
%%--------------------------------------------------------------------
ensureTable() ->
    case ets:whereis(?RateTable) of
        undefined ->
            try ets:new(?RateTable, [named_table, public, set]) catch _:_ -> ok end,
            ok;
        _ -> ok
    end.

%%--------------------------------------------------------------------
%% @doc
%% 限流表老化清理：每隔一个窗口最多触发一次全表扫描，删除窗口外的
%% 时间戳，并回收已无近期访问的空桶，防止限流表随 IP 数量无限增长。
%%
%% @param Now    当前毫秒时间戳
%% @param Window 滑动窗口毫秒
%% @return `ok'
%% @end
%%--------------------------------------------------------------------
maybeAgeOut(Now, Window) ->
    Last = case ets:lookup(?RateTable, '$lastSweep') of
        [{'$lastSweep', T}] when is_integer(T) -> T;
        _ -> 0
    end,
    case Now - Last > Window of
        true ->
            ets:insert(?RateTable, {'$lastSweep', Now}),
            sweepStale(Now, Window);
        false ->
            ok
    end.

%% 删除过期固定窗口计数桶（保留当前与上一窗口）；顺带清掉旧时间戳列表格式。
sweepStale(Now, Window) ->
    KeepFrom = (Now div max(Window, 1)) - 1,
    ets:foldl(fun
        ({'$lastSweep', _}, Acc) -> Acc;
        ({{_Ip, WindowId} = K, Count}, Acc) when is_integer(WindowId), is_integer(Count) ->
            case WindowId < KeepFrom of
                true -> ets:delete(?RateTable, K);
                false -> ok
            end,
            Acc;
        ({K, TsList}, Acc) when is_list(TsList) ->
            ets:delete(?RateTable, K),
            Acc;
        (_, Acc) -> Acc
    end, ok, ?RateTable),
    ok.

%%%===================================================================
%%% Helpers
%%%===================================================================

%% @doc Read a web config option. Checks the flat top-level key first
%% (for runtime overrides via alConfig:patch), then falls back to the
%% nested `web` map in the config file.
%% 中文：读取 web 配置项，优先取扁平顶层键（支持运行时 patch 覆盖），再回退到嵌套 `web' map。
-spec webOpt(atom(), term()) -> term().
webOpt(Key, Default) ->
    FlatKey = list_to_atom("web" ++ capFirst(atom_to_list(Key))),
    case alConfig:get(FlatKey, undefined) of
        undefined ->
            WebMap = alConfig:get(web, #{}),
            maps:get(Key, WebMap, Default);
        V -> V
    end.

%% 将字符串首字母大写，用于拼接 webXxx 形式的扁平配置键。
capFirst([H | T]) when H >= $a, H =< $z -> [H - 32 | T];
capFirst(Other) -> Other.

%%--------------------------------------------------------------------
%% @doc
%% 将值转换为 binary（多子句）：binary 原样、list/atom 转换、其它用 `~p' 格式化后转换。
%%
%% @param X 任意值
%% @return binary
%% @end
%%--------------------------------------------------------------------
toBin(X) when is_binary(X) -> X;
toBin(X) when is_list(X) -> unicode:characters_to_binary(X);
toBin(X) when is_atom(X) -> atom_to_binary(X, utf8);
toBin(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).
