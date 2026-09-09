%%% @doc EUnit tests for alWebSec pure helpers and rate limiting.
-module(alWebSec_tests).

-include_lib("eunit/include/eunit.hrl").

-define(setup, begin ok = alConfig:load() end).

%%%===================================================================
%%% constant_eq/2
%%%===================================================================

constant_eq_equal_test() ->
    ?assert(alWebSec:constantEq(<<"abc123">>, <<"abc123">>)).

constant_eq_same_length_different_test() ->
    ?assertNot(alWebSec:constantEq(<<"abc123">>, <<"abc124">>)).

constant_eq_different_length_test() ->
    ?assertNot(alWebSec:constantEq(<<"abc">>, <<"abcd">>)).

constant_eq_non_binary_test() ->
    ?assertNot(alWebSec:constantEq(abc, abc)),
    ?assertNot(alWebSec:constantEq(<<"a">>, a)).

%% 长度不同时仍需正确判否（且实现不因长度提前返回泄露长度）。
constant_eq_length_safe_test() ->
    ?assert(alWebSec:constantEq(<<"">>, <<"">>)),
    ?assertNot(alWebSec:constantEq(<<"short">>, <<"a-much-longer-token">>)),
    ?assert(alWebSec:constantEq(<<"a-much-longer-token">>, <<"a-much-longer-token">>)).

%%%===================================================================
%%% ws_origin_allowed/3
%%%===================================================================

%% 无 Origin（非浏览器客户端）放行。
ws_origin_undefined_test() ->
    ?assert(alWebSec:wsOriginAllowed(undefined, 8787, <<>>)).

%% 默认仅同源 localhost/127.0.0.1:PORT 放行，跨站拒绝。
ws_origin_default_local_test() ->
    ?assert(alWebSec:wsOriginAllowed(<<"http://localhost:8787">>, 8787, <<>>)),
    ?assert(alWebSec:wsOriginAllowed(<<"http://127.0.0.1:8787">>, 8787, <<>>)),
    ?assertNot(alWebSec:wsOriginAllowed(<<"http://evil.com">>, 8787, <<>>)),
    ?assertNot(alWebSec:wsOriginAllowed(<<"http://localhost:9999">>, 8787, <<>>)).

%% LAN 用 IP 打开页面：Origin 与 Host 同源应放行。
ws_origin_same_host_lan_test() ->
    Origin = <<"http://192.168.0.88:8787">>,
    Host = <<"192.168.0.88:8787">>,
    ?assert(alWebSec:isSameOrigin(Origin, Host)),
    ?assert(alWebSec:wsOriginAllowed(Origin, 8787, <<>>, Host)),
    ?assertNot(alWebSec:wsOriginAllowed(Origin, 8787, <<>>, <<"192.168.0.1:8787">>)),
    ?assertNot(alWebSec:wsOriginAllowed(<<"http://evil.com">>, 8787, <<>>, Host)).

%% 配置了 allowOrigin 白名单时以其为准。
ws_origin_configured_test() ->
    ?assert(alWebSec:wsOriginAllowed(<<"http://app.example.com">>, 8787,
                                     [<<"http://app.example.com">>])).

csrf_same_origin_allows_remote_write_test() ->
    ?setup,
    %% 与运行时 cfg 的 allowOrigin=* 隔离：本测只验证 Host 同源门禁。
    OldFlat = alConfig:get(webAllowOrigin, undefined),
    OldWeb = alConfig:get(web, #{}),
    ok = alConfig:patch([
        {webAllowOrigin, <<>>},
        {web, maps:put(allowOrigin, <<>>, OldWeb)}
    ]),
    try
        Origin = <<"http://192.168.0.88:8787">>,
        Host = <<"192.168.0.88:8787">>,
        Remote = {192, 168, 0, 99},
        ?assertEqual(ok, alWebSec:checkCsrf('POST', <<"/api/ask/stream">>, Origin, Remote, Host)),
        ?assertEqual({error, csrfDenied},
                     alWebSec:checkCsrf('POST', <<"/api/ask/stream">>, Origin, Remote,
                                        <<"192.168.0.1:8787">>))
    after
        ok = alConfig:patch([
            {webAllowOrigin, OldFlat},
            {web, OldWeb}
        ])
    end.
%%%===================================================================
%%% is_path_within/2
%%%===================================================================

is_path_within_ok_test() ->
    ?assert(alWebSec:isPathWithin("/data/sessions", "/data/sessions/1.json")),
    ?assert(alWebSec:isPathWithin("/data/sessions", "/data/sessions")).

is_path_within_traversal_test() ->
    ?assertNot(alWebSec:isPathWithin("/data/sessions", "/data/sessions/../../etc/passwd")),
    ?assertNot(alWebSec:isPathWithin("/data/sessions", "/etc/passwd")).

is_denied_file_api_path_test() ->
    ?assert(alWebSec:isDeniedFileApiPath(".git/config")),
    ?assert(alWebSec:isDeniedFileApiPath("src/../.ali/state.json")),
    ?assert(alWebSec:isDeniedFileApiPath("config/secret.cfg")),
    ?assert(alWebSec:isDeniedFileApiPath("priv/.env")),
    ?assert(alWebSec:isDeniedFileApiPath("keys/server.key")),
    ?assertNot(alWebSec:isDeniedFileApiPath("src/foo.erl")),
    ?assertNot(alWebSec:isDeniedFileApiPath(".")).

%%%===================================================================
%%% cors_headers/1,2
%%%===================================================================

cors_headers_empty_config_test() ->
    ?assertEqual([], alWebSec:corsHeaders(<<"http://localhost">>, <<>>)),
    ?assertEqual([], alWebSec:corsHeaders(<<"http://localhost">>, undefined)).

cors_headers_wildcard_test() ->
    Headers = alWebSec:corsHeaders(<<"http://localhost">>, <<"*">>),
    {_, Value} = lists:keyfind(<<"Access-Control-Allow-Origin">>, 1, Headers),
    ?assertEqual(<<"*">>, Value).

cors_headers_whitelist_match_test() ->
    Headers = alWebSec:corsHeaders(<<"http://app.example.com">>,
                                       [<<"http://app.example.com">>]),
    {_, Value} = lists:keyfind(<<"Access-Control-Allow-Origin">>, 1, Headers),
    ?assertEqual(<<"http://app.example.com">>, Value).

cors_headers_whitelist_no_match_test() ->
    ?assertEqual([], alWebSec:corsHeaders(<<"http://evil.com">>,
                                              [<<"http://app.example.com">>])).

%%%===================================================================
%%% security_headers/0
%%%===================================================================

security_headers_has_csp_test() ->
    Headers = alWebSec:securityHeaders(),
    ?assert(length(Headers) >= 4),
    ?assert(lists:keymember(<<"X-Content-Type-Options">>, 1, Headers)),
    ?assert(lists:keymember(<<"X-Frame-Options">>, 1, Headers)),
    ?assert(lists:keymember(<<"Referrer-Policy">>, 1, Headers)),
    ?assert(lists:keymember(<<"Content-Security-Policy">>, 1, Headers)).

%%%===================================================================
%%% is_write/1
%%%===================================================================

is_write_post_put_test() ->
    ?assert(alWebSec:isWrite('POST')),
    ?assert(alWebSec:isWrite('PUT')),
    ?assert(alWebSec:isWrite('DELETE')),
    ?assert(alWebSec:isWrite('PATCH')).

is_write_get_false_test() ->
    ?assertNot(alWebSec:isWrite('GET')),
    ?assertNot(alWebSec:isWrite('HEAD')).

is_write_binary_test() ->
    ?assert(alWebSec:isWrite(<<"POST">>)),
    ?assert(alWebSec:isWrite(<<"post">>)),
    ?assertNot(alWebSec:isWrite(<<"GET">>)).

%%%===================================================================
%%% is_side_effect_path/1
%%%===================================================================

is_side_effect_path_tool_test() ->
    ?assert(alWebSec:isSideEffectPath(<<"/tool">>)),
    ?assert(alWebSec:isSideEffectPath(<<"/v1/tools/call">>)).

is_side_effect_path_health_false_test() ->
    ?assertNot(alWebSec:isSideEffectPath(<<"/health">>)),
    ?assertNot(alWebSec:isSideEffectPath(<<"/tools">>)).

%%%===================================================================
%%% is_protected_path/2
%%%===================================================================

is_protected_path_post_tool_test() ->
    ?assert(alWebSec:isProtectedPath('POST', <<"/tool">>)),
    ?assert(alWebSec:isProtectedPath('POST', <<"/v1/tools/call">>)).

%% 默认拒绝式授权：公开路径仅 `/`、`/static/*`、`/api/health`（及 OPTIONS）。
is_public_path_test() ->
    ?assert(alWebSec:isPublicPath('GET', <<"/">>)),
    ?assert(alWebSec:isPublicPath('GET', <<"/static/app.js">>)),
    ?assert(alWebSec:isPublicPath('GET', <<"/api/health">>)),
    ?assert(alWebSec:isPublicPath('OPTIONS', <<"/api/ask">>)).

%% 默认拒绝：公开路径以外全部受保护（含旧黑名单未覆盖的读接口）。
is_protected_path_default_deny_test() ->
    ?assertNot(alWebSec:isProtectedPath('GET', <<"/">>)),
    ?assertNot(alWebSec:isProtectedPath('GET', <<"/static/app.js">>)),
    ?assertNot(alWebSec:isProtectedPath('GET', <<"/api/health">>)),
    ?assert(alWebSec:isProtectedPath('GET', <<"/health">>)),
    ?assert(alWebSec:isProtectedPath('GET', <<"/tools">>)),
    ?assert(alWebSec:isProtectedPath('GET', <<"/api/status">>)),
    ?assert(alWebSec:isProtectedPath('GET', <<"/api/spec/search">>)),
    ?assert(alWebSec:isProtectedPath('GET', <<"/ws">>)).

%%%===================================================================
%%% is_loopback/1
%%%===================================================================

is_loopback_ipv4_test() ->
    ?assert(alWebSec:isLoopback({127, 0, 0, 1})),
    ?assert(alWebSec:isLoopback({127, 1, 2, 3})).

is_loopback_ipv6_test() ->
    ?assert(alWebSec:isLoopback({0, 0, 0, 0, 0, 0, 0, 1})).

is_loopback_non_loopback_test() ->
    ?assertNot(alWebSec:isLoopback({192, 168, 1, 1})),
    ?assertNot(alWebSec:isLoopback({10, 0, 0, 1})).

is_loopback_undefined_test() ->
    ?assertNot(alWebSec:isLoopback(undefined)).

%%%===================================================================
%%% format_ip/1
%%%===================================================================

format_ip_ipv4_test() ->
    ?assertEqual(<<"127.0.0.1">>, alWebSec:formatIp({127, 0, 0, 1})).

format_ip_undefined_test() ->
    ?assertEqual(<<"unknown">>, alWebSec:formatIp(undefined)).

%%%===================================================================
%%% check_rate/1
%%%===================================================================

check_rate_undefined_ip_test() ->
    ?setup,
    ?assertEqual(ok, alWebSec:checkRate(undefined)).

check_rate_limit_disabled_test() ->
    ?setup,
    alWebSec:resetRate(),
    alConfig:patch([{webRateLimit, 0}]),
    ?assertEqual(ok, alWebSec:checkRate({127, 0, 0, 1})),
    alConfig:patch([{webRateLimit, 0}]).

check_rate_within_limit_test() ->
    ?setup,
    alWebSec:resetRate(),
    alConfig:patch([{webRateLimit, 3}, {webRateWindowMs, 60000}]),
    ?assertEqual(ok, alWebSec:checkRate({127, 0, 0, 1})),
    ?assertEqual(ok, alWebSec:checkRate({127, 0, 0, 1})),
    ?assertEqual(ok, alWebSec:checkRate({127, 0, 0, 1})),
    alConfig:patch([{webRateLimit, 0}]).

check_rate_over_limit_test() ->
    ?setup,
    alWebSec:resetRate(),
    alConfig:patch([{webRateLimit, 2}, {webRateWindowMs, 60000}]),
    ?assertEqual(ok, alWebSec:checkRate({127, 0, 0, 1})),
    ?assertEqual(ok, alWebSec:checkRate({127, 0, 0, 1})),
    ?assertEqual({error, rateLimited}, alWebSec:checkRate({127, 0, 0, 1})),
    alConfig:patch([{webRateLimit, 0}]).
