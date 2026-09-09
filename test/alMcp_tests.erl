%%% @doc EUnit tests for alMcp exports and structure.
-module(alMcp_tests).

-include_lib("eunit/include/eunit.hrl").

critical_exports_test() ->
    Exports = alMcp:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{stdio, 0}, {main, 1}]].

%%--------------------------------------------------------------------
%% 6a：tools/call 的 arguments 非 map 时应回 -32602，不得 badmap 崩溃
%%--------------------------------------------------------------------
tools_call_non_map_arguments_test() ->
    Reply = alMcp:handleRequest(
        #{jsonrpc => <<"2.0">>, id => 1,
          method => <<"tools/call">>,
          params => #{<<"name">> => <<"readFile">>, <<"arguments">> => <<"not a map">>}},
        #{}),
    ?assertMatch({ok, #{id := 1, error := #{code := -32602}}}, Reply).

tools_call_arguments_defaults_to_map_test() ->
    %% 缺省 arguments 视为空 map（不触发 -32602，走正常调用路径）
    Reply = alMcp:handleRequest(
        #{jsonrpc => <<"2.0">>, id => 1,
          method => <<"tools/call">>,
          params => #{<<"name">> => <<"definitelyNotATool">>}},
        #{}),
    ?assertMatch({ok, #{id := 1, error := #{code := -32601}}}, Reply).

%%--------------------------------------------------------------------
%% 6c：resources/read 的 params 非 map 应回 -32602（参数非法），
%% 不再依赖 badmap 崩溃再转 -32603。
%%--------------------------------------------------------------------
handle_request_invalid_params_returns_32602_test() ->
    Reply = alMcp:safeHandleRequest(
        #{jsonrpc => <<"2.0">>, id => 7,
          method => <<"resources/read">>, params => not_a_map},
        #{initialized => true}),
    ?assertMatch({ok, #{id := 7, error := #{code := -32602}}}, Reply).

%%--------------------------------------------------------------------
%% 非 map 请求：handleRequest 安全返回 noreply（decode 后不会出现）；
%% -32603 兜底由 safeHandleRequest 的 try/catch 覆盖真实 handler 异常。
%%--------------------------------------------------------------------
handle_request_non_map_noreply_test() ->
    ?assertEqual(noreply, alMcp:safeHandleRequest(not_a_request_map, #{initialized => true})).

%%--------------------------------------------------------------------
%% L2 回归：Content-Length 帧头解析为纯函数，非整数/负数返回 error，
%% 供 readMessage 判定为 badFrame 而非裸匹配崩溃。
%%--------------------------------------------------------------------
parse_content_length_valid_test() ->
    ?assertEqual({ok, 42}, alMcp:parseContentLength("42")),
    ?assertEqual({ok, 0}, alMcp:parseContentLength("0")).

parse_content_length_invalid_test() ->
    ?assertEqual(error, alMcp:parseContentLength("abc")),
    ?assertEqual(error, alMcp:parseContentLength("")),
    ?assertEqual(error, alMcp:parseContentLength("-1")).

%% 本函数不做 trim（调用方 readMessage 已先 string:trim），
%% 带空白/换行的输入按非整数处理。
parse_content_length_untrimmed_rejected_test() ->
    ?assertEqual(error, alMcp:parseContentLength(" 7 ")),
    ?assertEqual(error, alMcp:parseContentLength("7\r")).
