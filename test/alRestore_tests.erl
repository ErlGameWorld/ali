%%% @doc EUnit tests for restart recovery: checkpoint → pending restore
%%% and checkpoint lifecycle cleanup on claim/dismiss.
-module(alRestore_tests).

-include_lib("eunit/include/eunit.hrl").

-define(setup, begin ok = alConfig:load() end).

%% 构造一个带 pendingCall 的合法 continuation（与 toolLoop 挂起时一致）。
makeContinuation(TaskId) ->
    #{
        messages => [#{role => user, content => <<"hi">>}],
        opts => #{sessionId => <<"web">>, taskId => TaskId},
        context => #{},
        step => 3,
        trace => [{step, 2}],
        maxSteps => 50,
        pendingCall => #{
            id => <<"call_abc">>,
            function => #{name => <<"runMfa">>,
                          arguments => <<"{\"call\":\"gm:get_gold(1)\"}">>}
        },
        question => <<"q">>
    }.

%% 重启恢复：pending 表丢失后，从 checkpoint 重建待审批条目。
restore_from_checkpoint_test() ->
    ?setup,
    alPending:ensureStarted(),
    TaskId = <<"restore-test-1">>,
    {ok, _} = alCheckpoint:save(TaskId, makeContinuation(TaskId)),
    ?assertEqual({error, notFound}, alPending:get(TaskId)),
    ok = alServer:restorePendingFromCheckpoints(),
    {ok, Entry} = alPending:get(TaskId),
    ?assertEqual(runMfa, maps:get(tool, Entry)),
    ?assertEqual(<<"web">>, maps:get(sessionId, Entry)),
    ?assert(maps:is_key(continuation, Entry)),
    %% 清理
    ok = alPending:dismiss(TaskId),
    ok = alCheckpoint:delete(TaskId).

%% 幂等：已存在的 pending 不被重复登记；重复扫描不产生重复条目。
restore_idempotent_test() ->
    ?setup,
    alPending:ensureStarted(),
    TaskId = <<"restore-test-2">>,
    {ok, _} = alCheckpoint:save(TaskId, makeContinuation(TaskId)),
    ok = alServer:restorePendingFromCheckpoints(),
    ok = alServer:restorePendingFromCheckpoints(),
    {ok, Entry} = alPending:get(TaskId),
    ?assertEqual(runMfa, maps:get(tool, Entry)),
    Count = length([E || E <- alPending:list(),
                         maps:get(id, E, undefined) =:= TaskId]),
    ?assertEqual(1, Count),
    ok = alPending:dismiss(TaskId),
    ok = alCheckpoint:delete(TaskId).

%% 已存在的 pending（如重启时从磁盘载入）不被 checkpoint 覆盖。
restore_skips_existing_pending_test() ->
    ?setup,
    alPending:ensureStarted(),
    TaskId = <<"restore-test-3">>,
    {ok, _} = alPending:put(TaskId, <<"sid">>, readFile, #{path => <<"a.erl">>}, #{}),
    {ok, _} = alCheckpoint:save(TaskId, makeContinuation(TaskId)),
    ok = alServer:restorePendingFromCheckpoints(),
    {ok, Entry} = alPending:get(TaskId),
    ?assertEqual(readFile, maps:get(tool, Entry)),
    ok = alPending:dismiss(TaskId),
    ok = alCheckpoint:delete(TaskId).

%% 无 pendingCall 的 checkpoint（中断的普通循环）不自动登记。
restore_skips_without_pending_call_test() ->
    ?setup,
    alPending:ensureStarted(),
    TaskId = <<"restore-test-4">>,
    Cont = maps:remove(pendingCall, makeContinuation(TaskId)),
    {ok, _} = alCheckpoint:save(TaskId, Cont),
    ok = alServer:restorePendingFromCheckpoints(),
    ?assertEqual({error, notFound}, alPending:get(TaskId)),
    ok = alCheckpoint:delete(TaskId).

%% claim 只原子占位，保留 checkpoint 以便执行失败后仍可 resume；
%% 成功 executeApproved / dismiss 才删 checkpoint。
claim_keeps_checkpoint_until_success_test() ->
    ?setup,
    alPending:ensureStarted(),
    TaskId = <<"restore-test-5">>,
    {ok, _} = alPending:put(TaskId, <<"sid">>, readFile, #{path => <<"a.erl">>}, #{}),
    {ok, _} = alCheckpoint:save(TaskId, makeContinuation(TaskId)),
    {ok, _Spec} = alPending:claimApprove(TaskId),
    ?assertMatch({ok, _}, alCheckpoint:load(TaskId)),
    ok = alCheckpoint:delete(TaskId),
    ?assertMatch({error, _}, alCheckpoint:load(TaskId)).

%% 驳回后 checkpoint 同步删除。
dismiss_deletes_checkpoint_test() ->
    ?setup,
    alPending:ensureStarted(),
    TaskId = <<"restore-test-6">>,
    {ok, _} = alPending:put(TaskId, <<"sid">>, readFile, #{path => <<"a.erl">>}, #{}),
    {ok, _} = alCheckpoint:save(TaskId, makeContinuation(TaskId)),
    ok = alPending:dismiss(TaskId),
    ?assertMatch({error, _}, alCheckpoint:load(TaskId)).
