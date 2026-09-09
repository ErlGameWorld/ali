%%%-------------------------------------------------------------------
%% @doc Tests for alTask.
%% @end
%%%-------------------------------------------------------------------

-module(alTask_tests).

-include_lib("eunit/include/eunit.hrl").

spawn_ask_completes_test() ->
    Self = self(),
    Runner = fun(_Prompt, _Opts) ->
        {{ok, <<"answer42">>}, #{}}
    end,
    {ok, TaskId} = alTask:spawnAsk(<<"prompt">>, #{sessionId => <<"s1">>}, Runner),
    receive
        {eAliTask, TaskId, Result} -> Self ! {got, Result}
    after 5000 -> ?assert(false)
    end,
    receive
        {got, R} -> ?assertEqual({ok, <<"answer42">>}, R)
    after 1000 -> ?assert(false)
    end,
    {ok, Task} = alTask:status(TaskId),
    ?assertEqual(completed, maps:get(status, Task)).

spawn_ask_fails_test() ->
    Runner = fun(_Prompt, _Opts) ->
        {{error, bad_prompt}, #{}}
    end,
    {ok, TaskId} = alTask:spawnAsk(<<"p">>, #{}, Runner),
    receive
        {eAliTask, TaskId, _Result} -> ok
    after 5000 -> ?assert(false)
    end,
    {ok, Task} = alTask:status(TaskId),
    ?assertEqual(failed, maps:get(status, Task)),
    ?assertEqual({error, bad_prompt}, maps:get(result, Task)).

cancel_running_task_test() ->
    %% Runner blocks forever until cancelled
    Runner = fun(_Prompt, _Opts) ->
        receive
            stop -> ok
        end,
        {{ok, <<"never">>}, #{}}
    end,
    {ok, TaskId} = alTask:spawnAsk(<<"p">>, #{}, Runner),
    timer:sleep(50),
    Result = alTask:cancel(TaskId),
    ?assertEqual(ok, Result),
    {ok, Task} = alTask:status(TaskId),
    ?assertEqual(cancelled, maps:get(status, Task)).

cancel_nonexistent_returns_error_test() ->
    ?assertEqual({error, notFound}, alTask:cancel(<<"no-such-task">>)).

status_nonexistent_returns_error_test() ->
    ?assertEqual({error, notFound}, alTask:status(<<"no-such-task">>)).

list_returns_all_tasks_test() ->
    %% Spawn a quick task and ensure list returns at least it
    Runner = fun(_, _) -> {{ok, <<"x">>}, #{}} end,
    {ok, TaskId} = alTask:spawnAsk(<<"p">>, #{sessionId => <<"list-test">>}, Runner),
    receive
        {eAliTask, TaskId, _} -> ok
    after 5000 -> ?assert(false)
    end,
    All = alTask:list(),
    ?assert(lists:any(fun(T) -> maps:get(id, T) =:= TaskId end, All)).

task_has_session_id_test() ->
    Runner = fun(_, _) -> {{ok, <<"y">>}, #{}} end,
    {ok, TaskId} = alTask:spawnAsk(<<"p">>, #{sessionId => <<"sess-xyz">>}, Runner),
    receive
        {eAliTask, TaskId, _} -> ok
    after 5000 -> ?assert(false)
    end,
    {ok, Task} = alTask:status(TaskId),
    ?assertEqual(<<"sess-xyz">>, maps:get(sessionId, Task)).

cancel_already_completed_returns_not_running_test() ->
    Runner = fun(_, _) -> {{ok, <<"z">>}, #{}} end,
    {ok, TaskId} = alTask:spawnAsk(<<"p">>, #{}, Runner),
    receive
        {eAliTask, TaskId, _} -> ok
    after 5000 -> ?assert(false)
    end,
    Result = alTask:cancel(TaskId),
    ?assertEqual({error, notRunning}, Result).

%%%===================================================================
%%% 7: cancel 窗口期与已终态不覆盖
%%%===================================================================

%% 直接操纵 ETS 构造窗口期条目（有 running 状态但无 pid 字段），
%% cancel 必须返回 {error, notStarted} 而非 case_clause/badmatch 崩溃。
cancel_window_no_pid_returns_not_started_test() ->
    alTask:ensureStarted(),
    BinId = <<"window-task-",
              (integer_to_binary(erlang:unique_integer([positive, monotonic])))/binary>>,
    ets:insert(alTasks, {BinId, #{
        id => BinId, status => running, prompt => <<"p">>,
        sessionId => <<"s">>, startedAt => 1}}),
    try
        ?assertEqual({error, notStarted}, alTask:cancel(BinId))
    after
        ets:delete(alTasks, BinId)
    end.

%% 已进入终态的任务（completed）被 cancel 时：返回 {error, notRunning}
%% 且状态/时间戳不被覆盖（"不覆盖" 语义）。
cancel_completed_does_not_overwrite_test() ->
    alTask:ensureStarted(),
    BinId = <<"done-task-",
              (integer_to_binary(erlang:unique_integer([positive, monotonic])))/binary>>,
    ets:insert(alTasks, {BinId, #{
        id => BinId, status => completed, prompt => <<"p">>,
        sessionId => <<"s">>, startedAt => 1, finishedAt => 777,
        result => {ok, <<"x">>}}}),
    try
        ?assertEqual({error, notRunning}, alTask:cancel(BinId)),
        {ok, Task} = alTask:status(BinId),
        ?assertEqual(completed, maps:get(status, Task)),
        ?assertEqual(777, maps:get(finishedAt, Task)),
        ?assertEqual({ok, <<"x">>}, maps:get(result, Task))
    after
        ets:delete(alTasks, BinId)
    end.

%%%===================================================================
%%% 任务6 W4: cancel 后进度记录必须被 finish，不得永久 running
%%%===================================================================

cancel_running_task_finishes_progress_test() ->
    Runner = fun(_Prompt, _Opts) ->
        receive stop -> ok end,
        {{ok, <<"never">>}, #{}}
    end,
    {ok, TaskId} = alTask:spawnAsk(<<"p">>, #{}, Runner),
    timer:sleep(50),
    ?assertEqual(ok, alTask:cancel(TaskId)),
    {ok, Task} = alTask:status(TaskId),
    ?assertEqual(cancelled, maps:get(status, Task)),
    Snap = alProgress:snapshot(TaskId),
    ?assertMatch(#{status := Status} when Status =/= running, Snap),
    ?assertEqual(failed, maps:get(status, Snap)),
    ?assertEqual({error, cancelled}, maps:get(result, Snap)).

%%%===================================================================
%%% 任务6 W5: spawnAsk 后立即 cancel 必须生效（先 spawn 后写条目 + 握手）
%%%===================================================================

spawn_ask_immediate_cancel_takes_effect_test() ->
    Runner = fun(_Prompt, _Opts) ->
        receive stop -> ok end,
        {{ok, <<"late">>}, #{}}
    end,
    {ok, TaskId} = alTask:spawnAsk(<<"p">>, #{}, Runner),
    %% 不 sleep：spawnAsk 返回时条目已含 pid，立即 cancel 应命中 kill 分支。
    ?assertEqual(ok, alTask:cancel(TaskId)),
    {ok, Task} = alTask:status(TaskId),
    ?assertEqual(cancelled, maps:get(status, Task)),
    Snap = alProgress:snapshot(TaskId),
    ?assertMatch(#{status := Status} when Status =/= running, Snap),
    %% 进程已被 kill，无僵尸 eAliTask 消息。
    receive
        {eAliTask, TaskId, _} -> ?assert(false)
    after 100 -> ok
    end.
