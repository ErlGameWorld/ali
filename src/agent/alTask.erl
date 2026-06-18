%%%-------------------------------------------------------------------
%%% @doc 异步任务管理模块。
%%%
%%% 在 ETS 表中跟踪后台 ask 任务的生命周期（running / completed /
%%% cancelled / failed），通过 spawn 执行 Runner 回调，并与
%%% {@link alProgress} 联动上报进度。支持查询状态、优雅取消
%%% （发送 shutdown 信号）及列举所有任务。
%%% @end
%%%-------------------------------------------------------------------
-module(alTask).

-export([
    init/0,
    spawnAsk/3,
    status/1,
    cancel/1,
    list/0
]).

-define(TABLE, alTasks).

-type task() :: #{
    id := binary(),
    status := running | completed | cancelled | failed,
    prompt := binary(),
    sessionId := binary(),
    result => term(),
    startedAt := integer(),
    finishedAt => integer()
}.

%% @doc 初始化任务 ETS 表（幂等）。
%% @returns `ok`
-spec init() -> ok.
init() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, public, set]);
        _ ->
            ok
    end,
    ok.

%% @doc 创建并启动一个异步 ask 任务。
%% 在独立进程中执行 Runner(Prompt, Opts)，结果通过 `{alTask, TaskId, Result}`
%% 消息通知调用方；同时启动 alProgress 进度跟踪。
%% @param Prompt 用户提示词（binary）
%% @param Opts 选项 map，可含 sessionId 等
%% @param Runner 回调 `fun((binary(), map()) -> {term(), map()})`，
%%        返回 `{{ok, Answer}, NewState}` 或 `{{error, Reason}, NewState}`
%% @returns `{ok, binary()}` 新任务的 TaskId
-spec spawnAsk(binary(), map(), fun((map()) -> {term(), map()})) -> {ok, binary()}.
spawnAsk(Prompt, Opts, Runner) ->
    init(),
    TaskId = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    Started = erlang:system_time(millisecond),
    Task = #{
        id => TaskId,
        status => running,
        prompt => Prompt,
        sessionId => maps:get(sessionId, Opts, <<"default"/utf8>>),
        startedAt => Started
    },
    ets:insert(?TABLE, {TaskId, Task}),
    alProgress:start(TaskId),
    Parent = self(),
    Pid = spawn(fun() ->
        process_flag(trap_exit, true),
        RunnerOpts = maps:put(taskId, TaskId, Opts),
        case Runner(Prompt, RunnerOpts) of
            {{ok, Answer}, NewState} ->
                case receive_shutdown(0) of
                    true ->
                        mark_cancelled(TaskId),
                        Parent ! {alTask, TaskId, {error, cancelled}};
                    false ->
                        Finished = erlang:system_time(millisecond),
                        update(TaskId, #{
                            status => completed,
                            result => {ok, Answer},
                            finishedAt => Finished,
                            state => NewState
                        }),
                        Parent ! {alTask, TaskId, {ok, Answer}}
                end;
            {{error, Reason}, NewState} ->
                case receive_shutdown(0) of
                    true ->
                        mark_cancelled(TaskId),
                        Parent ! {alTask, TaskId, {error, cancelled}};
                    false ->
                        Finished = erlang:system_time(millisecond),
                        update(TaskId, #{
                            status => failed,
                            result => {error, Reason},
                            finishedAt => Finished,
                            state => NewState
                        }),
                        Parent ! {alTask, TaskId, {error, Reason}}
                end
        end
    end),
    update(TaskId, #{pid => Pid}),
    {ok, TaskId}.

%% @doc 查询指定任务的当前状态与元数据。
%% @param TaskId 任务标识（binary 或 string）
%% @returns `{ok, task()}` 或 `{error, notFound}`
-spec status(binary()) -> {ok, task()} | {error, notFound}.
status(TaskId) ->
    init(),
    case ets:lookup(?TABLE, toBinary(TaskId)) of
        [{_, Task}] -> {ok, Task};
        [] -> {error, notFound}
    end.

%% @doc 取消正在运行的任务。
%% 向 worker 进程发送 shutdown 退出信号，允许其完成当前步骤后标记为 cancelled。
%% @param TaskId 任务标识（binary 或 string）
%% @returns `ok` | `{error, notRunning}` | `{error, notFound}`
-spec cancel(binary()) -> ok | {error, term()}.
cancel(TaskId) ->
    init(),
    BinId = toBinary(TaskId),
    case ets:lookup(?TABLE, BinId) of
        [{_, #{pid := Pid, status := running} = Task}] ->
            %% 发送 shutdown 信号，让 worker 有机会完成当前步骤后标记为 cancelled
            exit(Pid, shutdown),
            update(BinId, Task#{status => cancelled, finishedAt => erlang:system_time(millisecond)}),
            ok;
        [{_, #{status := Status}}] when Status =/= running ->
            {error, notRunning};
        [] ->
            {error, notFound}
    end.

%% @doc 返回 ETS 中所有任务的列表。
%% @returns `[task()]`
-spec list() -> [task()].
list() ->
    init(),
    [Task || {_, Task} <- ets:tab2list(?TABLE)].

%% 将 Patch map 合并到已有任务记录；任务不存在时静默忽略
update(TaskId, Patch) ->
    case ets:lookup(?TABLE, TaskId) of
        [{_, Task}] ->
            ets:insert(?TABLE, {TaskId, maps:merge(Task, Patch)});
        [] ->
            ok
    end.

%% 非阻塞检查是否收到 shutdown 退出信号；收到其他 EXIT 则继续等待
receive_shutdown(Timeout) ->
    receive
        {'EXIT', _, shutdown} -> true;
        {'EXIT', _, _} -> receive_shutdown(Timeout)
    after Timeout ->
        false
    end.

%% 将任务标记为 cancelled 并记录完成时间
mark_cancelled(TaskId) ->
    update(TaskId, #{
        status => cancelled,
        finishedAt => erlang:system_time(millisecond)
    }).

%% 将 binary 或 list 统一转为 binary
toBinary(X) when is_binary(X) -> X;
toBinary(X) when is_list(X) -> unicode:characters_to_binary(X).