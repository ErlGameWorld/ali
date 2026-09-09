%%% @doc EUnit tests for HTTP gateway dispatch (no listen).
-module(alHttpGateway_tests).

-include_lib("eunit/include/eunit.hrl").

gateway_config_defaults_test() ->
    ok = alConfig:load(),
    ?assert(is_integer(alHttpGateway:port())).

%% web.enabled=true 时监听端口取 web.port（与 gateway.port 可不同）。
web_port_preferred_when_web_enabled_test() ->
    ok = alConfig:load(),
    ok = alConfig:patch([
        {web, #{enabled => true, port => 18088}},
        {gateway, #{enabled => true, port => 18787}}
    ]),
    ?assertEqual(true, alHttpGateway:enabled()),
    ?assertEqual(18088, alHttpGateway:port()).

gateway_port_when_web_disabled_test() ->
    ok = alConfig:load(),
    ok = alConfig:patch([
        {web, #{enabled => false, port => 18088}},
        {gateway, #{enabled => true, port => 18787}}
    ]),
    ?assertEqual(true, alHttpGateway:enabled()),
    ?assertEqual(18787, alHttpGateway:port()).

disabled_when_both_off_test() ->
    ok = alConfig:load(),
    ok = alConfig:patch([
        {web, #{enabled => false, port => 18088}},
        {gateway, #{enabled => false, port => 18787}}
    ]),
    ?assertEqual(false, alHttpGateway:enabled()).

render_health_test() ->
    application:ensure_all_started(eWSrv),
    ok = alConfig:load(),
    ?assert(is_integer(alHttpGateway:port())).
