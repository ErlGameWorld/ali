%%% @doc EUnit tests for alWebHandler pure helpers.
-module(alWebHandler_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("eWSrv/include/eWSrv.hrl").

-define(setup, begin ok = alConfig:load() end).

%%%===================================================================
%%% content_type/1
%%%===================================================================

content_type_css_test() ->
    ?assertEqual(<<"text/css; charset=utf-8">>,
                 alWebHandler:contentType(<<"style.css">>)).

content_type_js_test() ->
    ?assertEqual(<<"application/javascript; charset=utf-8">>,
                 alWebHandler:contentType(<<"app.js">>)).

content_type_html_test() ->
    ?assertEqual(<<"text/html; charset=utf-8">>,
                 alWebHandler:contentType(<<"index.html">>)).

content_type_unknown_test() ->
    ?assertEqual(<<"application/octet-stream">>,
                 alWebHandler:contentType(<<"data.bin">>)).

%%%===================================================================
%%% escape_json_for_html/1
%%%===================================================================

escape_json_no_closing_tag_test() ->
    Json = <<"</script>">>,
    ?assertEqual(<<"<\\/script>">>, alWebHandler:escapeJsonForHtml(Json)).

escape_json_multiple_test() ->
    Json = <<"</script></div>">>,
    ?assertEqual(<<"<\\/script><\\/div>">>, alWebHandler:escapeJsonForHtml(Json)).

escape_json_no_change_test() ->
    Json = <<"{\"key\":\"value\"}">>,
    ?assertEqual(Json, alWebHandler:escapeJsonForHtml(Json)).

%%%===================================================================
%%% safe_priv_path/2
%%%===================================================================

safe_priv_path_valid_test() ->
    Root = code:priv_dir(ali),
    {ok, Full} = alWebHandler:safePrivPath(Root, <<"web/index.html">>),
    ?assert(is_list(Full)).

safe_priv_path_traversal_test() ->
    Root = code:priv_dir(ali),
    ?assertEqual({error, forbidden},
                 alWebHandler:safePrivPath(Root, <<"../../etc/passwd">>)).

%%%===================================================================
%%% public_web_config/0
%%%===================================================================

public_web_config_structure_test() ->
    ?setup,
    Config = alWebHandler:publicWebConfig(),
    ?assertMatch(#{web := #{}, llm := #{}, policy := #{}, mcp := _}, Config),
    ?assertMatch(#{port := _, enabled := _, authEnabled := _}, maps:get(web, Config)),
    ?assertMatch(#{provider := _, model := _}, maps:get(llm, Config)).

public_web_config_auth_disabled_test() ->
    ?setup,
    Config = alWebHandler:publicWebConfig(),
    %% Default config has auth_token => undefined, so authEnabled should be false
    ?assertEqual(false, maps:get(authEnabled, maps:get(web, Config))).

%%%===================================================================
%%% checkpointInfo/1 + truncateBin/2
%%%===================================================================

checkpoint_info_missing_returns_base_test() ->
    %% 不存在的 checkpoint 至少返回 taskId
    Info = alWebHandler:checkpointInfo(<<"no-such-task">>),
    ?assertEqual(<<"no-such-task">>, maps:get(taskId, Info)).

checkpoint_info_with_pending_call_test() ->
    ?setup,
    TaskId = <<"ck-test-1">>,
    {ok, _} = alCheckpoint:save(TaskId, #{
        messages => [],
        opts => #{},
        step => 1,
        pendingCall => #{function => #{name => writeFile,
                                       arguments => [<<"src/foo.erl">>, <<"data">>]}}
    }),
    try
        Info = alWebHandler:checkpointInfo(TaskId),
        ?assertEqual(TaskId, maps:get(taskId, Info)),
        ?assertEqual(<<"writeFile">>, maps:get(tool, Info)),
        ?assertEqual([<<"src/foo.erl">>, <<"data">>], maps:get(args, Info)),
        ?assert(maps:is_key(savedAt, Info))
    after
        ok = alCheckpoint:delete(TaskId)
    end.

truncate_bin_short_test() ->
    ?assertEqual(<<"abc">>, alWebHandler:truncateBin(<<"abc">>, 60)).

truncate_bin_utf8_boundary_test() ->
    %% 长中文串按字符截断，不产生半个 UTF-8 字符
    Bin = unicode:characters_to_binary(lists:duplicate(40, "中")),
    Truncated = alWebHandler:truncateBin(Bin, 10),
    ?assertEqual(30, byte_size(Truncated)),
    ?assertEqual(10, length(unicode:characters_to_list(Truncated, utf8))).

%%%===================================================================
%%% isLikelyLocalClient/1 — peername 失败时的本机兜底
%%%===================================================================

fake_ws_req(Headers) ->
    fake_ws_req(Headers, <<>>).

fake_ws_req(Headers, Host) ->
    #wsReq{
        method = 'GET',
        path = <<"/ws">>,
        version = {1, 1},
        scheme = <<"http">>,
        host = Host,
        port = 8080,
        socket = undefined,
        args = [],
        headers = Headers,
        body = <<>>
    }.

likely_local_via_origin_test() ->
    Req = fake_ws_req([{<<"Origin">>, <<"http://127.0.0.1:8080">>}]),
    ?assert(alWebHandler:isLikelyLocalClient(Req)).

likely_local_via_host_test() ->
    Req = fake_ws_req([{<<"Host">>, <<"localhost:8080">>}]),
    ?assert(alWebHandler:isLikelyLocalClient(Req)).

likely_local_via_req_host_test() ->
    Req = fake_ws_req([], <<"localhost">>),
    ?assert(alWebHandler:isLikelyLocalClient(Req)).

likely_local_rejects_remote_test() ->
    Req = fake_ws_req([
        {<<"Origin">>, <<"http://evil.example">>},
        {<<"Host">>, <<"evil.example">>}
    ], <<"evil.example">>),
    ?assertNot(alWebHandler:isLikelyLocalClient(Req)).

likely_local_rejects_substring_spoof_test() ->
    %% Host 头含 localhost 子串不得放行；req.host 也不得误带本机名
    Req = fake_ws_req([
        {<<"Host">>, <<"evil-localhost.com">>},
        {<<"Origin">>, <<"http://notlocalhost.evil">>}
    ], <<"evil-localhost.com">>),
    ?assertNot(alWebHandler:isLikelyLocalClient(Req)).

likely_local_empty_headers_test() ->
    ?assertNot(alWebHandler:isLikelyLocalClient(fake_ws_req([]))).

%%%===================================================================
%%% sseEvent/2 + sseData/1 — 换行转义与事件类型白名单
%%%===================================================================

sse_event_escapes_newlines_test() ->
    %% reasoning 等自由文本中的换行必须拆成独立 data 行，
    %% 不能原样拼进 event: 帧造成伪帧注入。
    Frame = alWebHandler:sseEvent(<<"reasoning">>, <<"line1\nline2">>),
    ?assertEqual(<<"event: reasoning\ndata: line1\ndata: line2\n\n">>, Frame).

sse_event_whitelisted_type_test() ->
    ?assertEqual(<<"event: done\ndata: {}\n\n">>,
                 alWebHandler:sseEvent(<<"done">>, <<"{}">>)).

sse_event_unknown_type_degrades_to_data_test() ->
    %% progress 等非白名单事件类型统一降级为普通 data 帧（不带 event: 行）。
    ?assertEqual(<<"data: x\n\n">>, alWebHandler:sseEvent(<<"progress">>, <<"x">>)),
    ?assertEqual(<<"data: x\n\n">>, alWebHandler:sseEvent(<<"evil">>, <<"x">>)),
    ?assertEqual(<<"data: x\n\n">>, alWebHandler:sseEvent(fake_event, <<"x">>)).

sse_data_multiline_test() ->
    ?assertEqual(<<"data: a\ndata: b\ndata: c\n\n">>,
                 alWebHandler:sseData(<<"a\nb\nc">>)).
