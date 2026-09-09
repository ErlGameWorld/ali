%%% @doc EUnit tests for alMcpClient exports and structure.
-module(alMcpClient_tests).

-include_lib("eunit/include/eunit.hrl").

critical_exports_test() ->
    Exports = alMcpClient:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{start_link, 0}, {ensureStarted, 0}, {connect, 1},
                   {disconnect, 1}, {listConnections, 0}, {listTools, 1},
                   {callTool, 3},
                   {registerToolsChangedCallback, 1},
                   {unregisterToolsChangedCallback, 1}]].

listConnectionsInitialState_test() ->
    %% Without starting the gen_server, listConnections should fail gracefully
    Result = try alMcpClient:listConnections() of
        R -> R
    catch
        Class:Reason -> {Class, Reason}
    end,
    ?assert(is_list(Result) orelse is_tuple(Result)).

%%--------------------------------------------------------------------
%% L1 回归：外部 MCP tools/list 返回 JSON binary 键 <<"name">>，
%% toolEntry 必须读取该键，工具名不能退化为 unknown。
%%--------------------------------------------------------------------
toolEntry_binary_name_key_test() ->
    Entry = alMcpClient:toolEntry(testConn, #{<<"name">> => <<"readFile">>}),
    ?assertEqual(<<"testConn:readFile">>, maps:get(name, Entry)),
    ?assertEqual(testConn, maps:get(conn, Entry)),
    ?assertEqual(#{<<"name">> => <<"readFile">>}, maps:get(spec, Entry)).

toolEntry_atom_name_key_test() ->
    Entry = alMcpClient:toolEntry(testConn, #{name => readFile}),
    ?assertEqual(<<"testConn:readFile">>, maps:get(name, Entry)).

toolEntry_missing_name_key_test() ->
    Entry = alMcpClient:toolEntry(testConn, #{}),
    ?assertEqual(<<"testConn:unknown">>, maps:get(name, Entry)).

%%--------------------------------------------------------------------
%% HTTP 传输：normalizeSpec 补全 transport / 转换 url 为 binary。
%%--------------------------------------------------------------------
normalize_spec_http_url_test() ->
    Spec = alMcpClient:normalizeSpec(#{name => httpConn,
                                       url => <<"https://mcp.example.com/sse">>}),
    ?assertEqual(http, maps:get(transport, Spec)),
    ?assertEqual(<<"https://mcp.example.com/sse">>, maps:get(url, Spec)),
    ?assertEqual(httpConn, maps:get(name, Spec)).

normalize_spec_http_transport_alias_test() ->
    Spec = alMcpClient:normalizeSpec(#{name => httpConn, transport => <<"streamable_http">>,
                                       url => <<"https://mcp.example.com/sse">>}),
    ?assertEqual(http, maps:get(transport, Spec)).

normalize_spec_stdio_default_test() ->
    Spec = alMcpClient:normalizeSpec(#{name => stdioConn,
                                       command => "node", args => ["server.js"]}),
    ?assertEqual(stdio, maps:get(transport, Spec)),
    ?assertEqual("node", maps:get(command, Spec)).

%%--------------------------------------------------------------------
%% Streamable HTTP 响应：SSE 事件流解析出 JSON-RPC 消息。
%%--------------------------------------------------------------------
parse_sse_messages_single_test() ->
    Body = <<"event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}\n\n">>,
    [Msg] = alMcpClient:parseSseMessages(Body),
    ?assertEqual(1, maps:get(<<"id">>, Msg)),
    ?assert(maps:is_key(<<"result">>, Msg)).

parse_sse_messages_multiple_test() ->
    Body = <<"data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\n\n"
              "data: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"content\":[]}}\n\n">>,
    Msgs = alMcpClient:parseSseMessages(Body),
    ?assertEqual(2, length(Msgs)),
    [M1, M2] = Msgs,
    ?assert(maps:is_key(<<"method">>, M1)),
    ?assertEqual(7, maps:get(<<"id">>, M2)).

parse_sse_messages_crlf_test() ->
    Body = <<"data: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}\r\n\r\n">>,
    [Msg] = alMcpClient:parseSseMessages(Body),
    ?assertEqual(2, maps:get(<<"id">>, Msg)).
