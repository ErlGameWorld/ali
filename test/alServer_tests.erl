%%% @doc EUnit tests for alServer exports and structure.
-module(alServer_tests).

-include_lib("eunit/include/eunit.hrl").

-define(setup, begin ok = alConfig:load() end).

critical_exports_test() ->
    Exports = alServer:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{start_link, 0}, {stop, 0}, {ask, 1}, {ask, 2},
                   {askStream, 1}, {askStream, 2}, {askAsync, 1}, {askAsync, 2},
                   {approve, 1}, {dismiss, 1}, {status, 0}, {sessions, 0},
                   {getMode, 0}, {setMode, 1}, {tasks, 0}, {tools, 0}]].

toolsDelegatesToCatalog_test() ->
    ?setup,
    Tools = alServer:tools(),
    ?assert(is_list(Tools) andalso length(Tools) > 0).

%%%===================================================================
%%% 3a/3b: cancelAsk 全局取消（过滤死 Pid）+ cancelAskByTaskId 精确取消
%%%===================================================================

%% 在测试中拉起 alServer 所需的轻量依赖链（alSessionSup/alSessionMgr）。
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

cancelAskWithoutSessions_test() ->
    startAlServer(),
    try
        %% 无会话时全局取消不崩溃（3a 修复：只对存活 worker 发调用）
        ?assertMatch(#{ok := true, cancelled := 0}, alServer:cancelAsk())
    after
        alServer:stop()
    end.

cancelAskWithDeadWorkerDoesNotCrash_test() ->
    startAlServer(),
    try
        Sid = <<"cancel-dead-w-",
                (integer_to_binary(erlang:unique_integer([positive, monotonic])))/binary>>,
        {ok, W} = alServer:ensureSessionWorker(Sid),
        exit(W, kill),
        %% DOWN 清理与 call 的时序不定：无论 sessions 中是否残留死 Pid，
        %% 修复后 cancelAsk() 都必须不崩溃（修复前会对死 Pid 发 call → noproc）。
        ?assertMatch(#{ok := true, cancelled := _}, alServer:cancelAsk())
    after
        alServer:stop()
    end.

cancelAskByTaskIdNoSession_test() ->
    startAlServer(),
    try
        ?assertEqual(#{ok => false, error => noSession},
                     alServer:cancelAskByTaskId(<<"no-such-session-xyz">>, <<"t1">>))
    after
        alServer:stop()
    end.

cancelAskByTaskIdExistingWorkerRoutesToWorker_test() ->
    startAlServer(),
    try
        Sid = <<"cancel-by-id-session-",
                (integer_to_binary(erlang:unique_integer([positive, monotonic])))/binary>>,
        {ok, _W} = alServer:ensureSessionWorker(Sid),
        %% worker 存在：未知 taskId 走 alSessionWorker:cancelByTaskId 返回
        %% {error, notFound}（而非 noSession），证明精确取消被正确路由。
        ?assertMatch({error, notFound},
                     alServer:cancelAskByTaskId(Sid, <<"no-such-task-xyz">>))
    after
        alServer:stop()
    end.
