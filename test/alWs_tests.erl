%%%-------------------------------------------------------------------
%% @doc Tests for alWs command dispatch (pure helpers, no socket).
%% @end
%%%-------------------------------------------------------------------

-module(alWs_tests).

-include_lib("eunit/include/eunit.hrl").

encode_msg_returns_binary_test() ->
    Bin = alWs:encodeMsg(#{type => pong}),
    ?assert(is_binary(Bin)),
    Map = alJson:decode(Bin),
    ?assertEqual(<<"pong">>, maps:get(<<"type">>, Map)).

dispatch_status_replies_metrics_test() ->
    {reply, Bin, _} = alWs:dispatch(#{<<"type">> => <<"status">>}, #{}, undefined),
    Map = alJson:decode(Bin),
    ?assertEqual(<<"status">>, maps:get(<<"type">>, Map)),
    ?assert(maps:is_key(<<"status">>, Map)).

dispatch_health_replies_core_gateway_test() ->
    {reply, Bin, _} = alWs:dispatch(#{<<"type">> => <<"health">>}, #{}, undefined),
    Map = alJson:decode(Bin),
    ?assertEqual(<<"health">>, maps:get(<<"type">>, Map)),
    ?assert(maps:is_key(<<"core">>, Map)),
    ?assertEqual(<<"up">>, maps:get(<<"gateway">>, Map)).

dispatch_tools_replies_tools_list_test() ->
    {reply, Bin, _} = alWs:dispatch(#{<<"type">> => <<"tools">>}, #{}, undefined),
    Map = alJson:decode(Bin),
    ?assertEqual(<<"tools">>, maps:get(<<"type">>, Map)),
    ?assert(maps:is_key(<<"tools">>, Map)).

dispatch_metrics_replies_metrics_test() ->
    {reply, Bin, _} = alWs:dispatch(#{<<"type">> => <<"metrics">>}, #{}, undefined),
    Map = alJson:decode(Bin),
    ?assertEqual(<<"metrics">>, maps:get(<<"type">>, Map)),
    ?assert(maps:is_key(<<"metrics">>, Map)).

dispatch_audit_replies_entries_test() ->
    {reply, Bin, _} = alWs:dispatch(#{<<"type">> => <<"audit">>, <<"limit">> => 5}, #{}, undefined),
    Map = alJson:decode(Bin),
    ?assertEqual(<<"audit">>, maps:get(<<"type">>, Map)),
    ?assert(maps:is_key(<<"entries">>, Map)).

dispatch_ping_replies_pong_test() ->
    {reply, Bin, _} = alWs:dispatch(#{<<"type">> => <<"ping">>}, #{}, undefined),
    Map = alJson:decode(Bin),
    ?assertEqual(<<"pong">>, maps:get(<<"type">>, Map)).

dispatch_close_returns_close_test() ->
    Result = alWs:dispatch(#{<<"type">> => <<"close">>}, #{}, undefined),
    ?assertMatch({close, _}, Result).

dispatch_unknown_command_returns_error_test() ->
    {reply, Bin, _} = alWs:dispatch(#{<<"type">> => <<"nonsense">>}, #{}, undefined),
    Map = alJson:decode(Bin),
    ?assertEqual(<<"error">>, maps:get(<<"type">>, Map)),
    ?assertEqual(<<"unknownCommand">>, maps:get(<<"error">>, Map)),
    ?assertEqual(<<"nonsense">>, maps:get(<<"command">>, Map)).

dispatch_missing_type_returns_error_test() ->
    {reply, Bin, _} = alWs:dispatch(#{}, #{}, undefined),
    Map = alJson:decode(Bin),
    ?assertEqual(<<"error">>, maps:get(<<"type">>, Map)),
    ?assertEqual(<<"missingType">>, maps:get(<<"error">>, Map)).

dispatch_ask_missing_prompt_returns_error_test() ->
    {reply, Bin, _} = alWs:dispatch(#{<<"type">> => <<"ask">>}, #{}, undefined),
    Map = alJson:decode(Bin),
    ?assertEqual(<<"error">>, maps:get(<<"type">>, Map)),
    ?assertEqual(<<"missingPrompt">>, maps:get(<<"error">>, Map)).

dispatch_set_llm_updates_state_test() ->
    Cmd = #{<<"type">> => <<"setLlm">>, <<"enabled">> => true,
            <<"llm">> => #{<<"model">> => <<"gpt-4">>, <<"provider">> => <<"openai">>,
                           <<"apiKey">> => <<"sk-test">>}},
    {reply, Bin, NewState} = alWs:dispatch(Cmd, #{}, undefined),
    Map = alJson:decode(Bin),
    ?assertEqual(<<"setLlm">>, maps:get(<<"type">>, Map)),
    ?assertEqual(true, maps:get(<<"enabled">>, Map)),
    ?assertEqual(true, maps:get(<<"hasApiKey">>, Map)),
    Override = maps:get(llmOverride, NewState),
    ?assertEqual(openai, maps:get(provider, Override)),
    ?assertEqual(<<"gpt-4">>, maps:get(model, Override)),
    ?assertEqual(<<"sk-test">>, maps:get(apiKey, Override)),
    %% 响应不得回传 apiKey
    ?assertEqual(false, maps:is_key(<<"apiKey">>, Map)).

dispatch_set_llm_rejects_base_url_test() ->
    Cmd = #{<<"type">> => <<"setLlm">>, <<"enabled">> => true,
            <<"llm">> => #{<<"model">> => <<"m">>, <<"baseUrl">> => <<"http://evil">>}},
    {reply, _Bin, NewState} = alWs:dispatch(Cmd, #{}, undefined),
    Override = maps:get(llmOverride, NewState),
    ?assertEqual(<<"m">>, maps:get(model, Override)),
    ?assertEqual(false, maps:is_key(baseUrl, Override)).

dispatch_set_llm_disabled_clears_override_test() ->
    Cmd = #{<<"type">> => <<"setLlm">>, <<"enabled">> => false},
    {reply, _Bin, NewState} = alWs:dispatch(Cmd, #{}, undefined),
    ?assertEqual(undefined, maps:get(llmOverride, NewState)).

dispatch_mode_updates_state_test() ->
    Cmd = #{<<"type">> => <<"mode">>, <<"mode">> => edit},
    {reply, Bin, NewState} = alWs:dispatch(Cmd, #{}, undefined),
    Map = alJson:decode(Bin),
    ?assertEqual(<<"mode">>, maps:get(<<"type">>, Map)),
    ?assertEqual(<<"edit">>, maps:get(<<"mode">>, Map)),
    ?assertEqual(edit, maps:get(mode, NewState)).

dispatch_cancel_ask_no_session_returns_error_test() ->
    Cmd = #{<<"type">> => <<"cancelAsk">>, <<"taskId">> => <<"t1">>},
    {reply, Bin, _} = alWs:dispatch(Cmd, #{}, undefined),
    Map = alJson:decode(Bin),
    ?assertEqual(<<"cancelAsk">>, maps:get(<<"type">>, Map)),
    Result = maps:get(<<"result">>, Map),
    ?assertEqual(false, maps:get(<<"ok">>, Result)).

%%%===================================================================
%%% 1a: cancelAsk 三分支 —— all / missing taskId / 指定 taskId
%%%===================================================================

%% 模拟 alSessionWorker 的 gen_server 应答：兼容 `$gen_call' 协议。
fakeSessionWorker() ->
    spawn(fun() -> fakeWorkerLoop() end).

fakeWorkerLoop() ->
    receive
        {'$gen_call', From, {eCancelAsk, all}} ->
            gen_server:reply(From, #{ok => true, cancelled => 2}),
            fakeWorkerLoop();
        {'$gen_call', From, {eCancelByTaskId, _TaskId}} ->
            %% 与 alSessionWorker:handle_call 一致：成功返回 ok
            gen_server:reply(From, ok),
            fakeWorkerLoop();
        %% 兼容旧手写消息形状（若有）
        {From, {eCancelAsk, all}} when is_tuple(From) ->
            gen_server:reply(From, #{ok => true, cancelled => 2}),
            fakeWorkerLoop();
        {From, {eCancelByTaskId, _TaskId}} when is_tuple(From) ->
            gen_server:reply(From, ok),
            fakeWorkerLoop()
    end.

dispatch_cancel_ask_all_cancels_all_test() ->
    W = fakeSessionWorker(),
    try
        Cmd = #{<<"type">> => <<"cancelAsk">>, <<"taskId">> => <<"all">>},
        {reply, Bin, _} = alWs:dispatch(Cmd, #{sessionWorker => W}, undefined),
        Map = alJson:decode(Bin),
        Result = maps:get(<<"result">>, Map),
        ?assertEqual(<<"cancelAsk">>, maps:get(<<"type">>, Map)),
        ?assertEqual(true, maps:get(<<"ok">>, Result)),
        ?assertEqual(2, maps:get(<<"cancelled">>, Result))
    after
        exit(W, kill)
    end.

%% 缺省 taskId：与 HTTP 一致，取消本会话全部进行中问答。
dispatch_cancel_ask_missing_task_id_cancels_all_test() ->
    W = fakeSessionWorker(),
    try
        Cmd = #{<<"type">> => <<"cancelAsk">>},
        {reply, Bin, _} = alWs:dispatch(Cmd, #{sessionWorker => W}, undefined),
        Map = alJson:decode(Bin),
        ?assertEqual(<<"cancelAsk">>, maps:get(<<"type">>, Map)),
        Result = maps:get(<<"result">>, Map),
        ?assertEqual(true, maps:get(<<"ok">>, Result)),
        ?assertEqual(2, maps:get(<<"cancelled">>, Result))
    after
        exit(W, kill)
    end.

dispatch_cancel_ask_by_task_id_test() ->
    W = fakeSessionWorker(),
    try
        Cmd = #{<<"type">> => <<"cancelAsk">>, <<"taskId">> => <<"t-42">>},
        {reply, Bin, _} = alWs:dispatch(Cmd, #{sessionWorker => W}, undefined),
        Map = alJson:decode(Bin),
        Result = maps:get(<<"result">>, Map),
        %% JSON 往返后 atom ok 变为 binary
        ?assertEqual(<<"ok">>, Result)
    after
        exit(W, kill)
    end.

%%%===================================================================
%%% 2: mode 非法值不改状态（任务2 W2）
%%%===================================================================

%% 在测试中拉起 alServer 所需的轻量依赖链（与 alServer_tests 一致）。
startAlServer() ->
    ok = alConfig:load(),
    _ = case whereis(alSessionSup) of
            undefined -> alSessionSup:start_link();
            _ -> ok
        end,
    _ = case whereis(alSessionMgr) of
            undefined -> alSessionMgr:start_link();
            _ -> ok
        end,
    case whereis(alServer) of
        undefined -> {ok, _} = alServer:start_link();
        _ -> ok
    end.

dispatch_mode_invalid_does_not_change_state_test() ->
    startAlServer(),
    try
        Initial = #{mode => edit},
        Cmd = #{<<"type">> => <<"mode">>, <<"mode">> => <<"bogus">>},
        {reply, Bin, NewState} = alWs:dispatch(Cmd, Initial, undefined),
        Map = alJson:decode(Bin),
        ?assertEqual(<<"mode">>, maps:get(<<"type">>, Map)),
        ?assertEqual(false, maps:get(<<"ok">>, Map)),
        ?assertEqual(<<"invalidMode">>, maps:get(<<"error">>, Map)),
        ?assertEqual(edit, maps:get(mode, NewState))
    after
        alServer:stop()
    end.

%%%===================================================================
%%% 3: 非本会话 taskId 的取消/恢复返回 notOwned（任务3 W6）
%%%===================================================================

dispatch_cancel_task_not_owned_test() ->
    alTask:ensureStarted(),
    BinId = <<"w6-task-",
              (integer_to_binary(erlang:unique_integer([positive, monotonic])))/binary>>,
    ets:insert(alTasks, {BinId, #{
        id => BinId, status => running, prompt => <<"p">>,
        sessionId => <<"other-session">>, startedAt => 1, pid => self()}}),
    try
        Cmd = #{<<"type">> => <<"cancelTask">>, <<"taskId">> => BinId,
                <<"sessionId">> => <<"my-session">>},
        {reply, Bin, _} = alWs:dispatch(Cmd, #{}, undefined),
        Map = alJson:decode(Bin),
        ?assertEqual(<<"cancelTask">>, maps:get(<<"type">>, Map)),
        Result = maps:get(<<"result">>, Map),
        ?assertEqual(false, maps:get(<<"ok">>, Result)),
        ?assertEqual(<<"notOwned">>, maps:get(<<"error">>, Result))
    after
        ets:delete(alTasks, BinId)
    end.

dispatch_resume_not_owned_test() ->
    _ = alConfig:load(),
    TaskId = <<"w6-ckpt-",
               (integer_to_binary(erlang:unique_integer([positive, monotonic])))/binary>>,
    {ok, _Path} = alCheckpoint:save(TaskId, #{
        messages => [], opts => #{sessionId => <<"other-session">>}, step => 1}),
    try
        Cmd = #{<<"type">> => <<"resume">>, <<"taskId">> => TaskId,
                <<"sessionId">> => <<"my-session">>},
        {reply, Bin, _} = alWs:dispatch(Cmd, #{}, undefined),
        Map = alJson:decode(Bin),
        ?assertEqual(<<"resume">>, maps:get(<<"type">>, Map)),
        ?assertEqual(false, maps:get(<<"ok">>, Map)),
        ?assertEqual(<<"notOwned">>, maps:get(<<"error">>, Map)),
        ?assertEqual(TaskId, maps:get(<<"taskId">>, Map))
    after
        try alCheckpoint:delete(TaskId) catch _:_ -> ok end
    end.
