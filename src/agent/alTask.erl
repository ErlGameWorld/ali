%%%-------------------------------------------------------------------
%% @doc 异步任务生命周期（ETS 支撑）。
%%
%% 通过派生 Runner 回调跟踪后台 ask（running / completed / cancelled / failed），
%% 并与 {@link alProgress} 集成。支持状态查询、优雅取消（shutdown 信号）与列表。
%% @end
%%%-------------------------------------------------------------------

-module(alTask).

-export([
    spawnAsk/3,
    status/1,
    cancel/1,
    list/0,
    ensureStarted/0,
    cleanupTask/1
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

-export_type([task/0]).

%%--------------------------------------------------------------------
%% @doc
%% 异步启动一个 ask 任务：在独立进程中执行 Runner 回调，并通过 ETS 跟踪状态。
%% 任务在后台运行，最终结果通过消息 {eAliTask, TaskId, Result} 回传给调用进程。
%% 会处理取消竞争：若任务在执行期间被取消，则按 cancelled 处理。
%%
%% @param Prompt 任务输入提示（binary 或可转 binary 的值）
%% @param Opts 选项 map，可包含 sessionId 等
%% @param Runner 实际执行任务的回调函数，签名为 fun(Prompt, Opts) -> {{ok, Ans}|{error, R}, NewState}
%% @return {ok, TaskId} 返回新建任务的二进制 ID
%% @end
%%--------------------------------------------------------------------
-spec spawnAsk(binary(), map(), fun((binary(), map()) -> {{ok, term()} | {error, term()}, map()})) -> {ok, binary()}.
spawnAsk(Prompt, Opts, Runner) ->
    ensureStarted(),
    TaskId = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    Started = erlang:system_time(millisecond),
    Parent = self(),
    Pid = spawn(fun() ->
        process_flag(trap_exit, true),
        %% 握手：等待父进程写入含 pid 的条目后再开始执行，避免快跑完成的
        %% Runner 在条目写入前就结束、随后又被覆盖为 running 的竞态（任务 6 W5）。
        receive
            {taskRegistered, TaskId} -> ok
        end,
        RunnerOpts = maps:put(taskId, TaskId, Opts),
        try Runner(Prompt, RunnerOpts) of
            {{ok, Answer}, NewState} ->
                case receiveShutdown(0) of
                    true ->
                        markCancelled(TaskId),
                        Parent ! {eAliTask, TaskId, {error, cancelled}};
                    false ->
                        case alreadyCancelled(TaskId) of
                            true ->
                                Parent ! {eAliTask, TaskId, {error, cancelled}};
                            false ->
                                Finished = erlang:system_time(millisecond),
                                update(TaskId, #{
                                    status => completed,
                                    result => {ok, Answer},
                                    finishedAt => Finished,
                                    state => NewState
                                }),
                                alProgress:finish(TaskId, {ok, Answer}),
                                Parent ! {eAliTask, TaskId, {ok, Answer}}
                        end
                end;
            {{error, Reason}, NewState} ->
                case receiveShutdown(0) of
                    true ->
                        markCancelled(TaskId),
                        Parent ! {eAliTask, TaskId, {error, cancelled}};
                    false ->
                        case alreadyCancelled(TaskId) of
                            true ->
                                Parent ! {eAliTask, TaskId, {error, cancelled}};
                            false ->
                                Finished = erlang:system_time(millisecond),
                                update(TaskId, #{
                                    status => failed,
                                    result => {error, Reason},
                                    finishedAt => Finished,
                                    state => NewState
                                }),
                                alProgress:finish(TaskId, {error, Reason}),
                                Parent ! {eAliTask, TaskId, {error, Reason}}
                        end
                end
        catch
            Class:Reason:StackTrace ->
                Finished = erlang:system_time(millisecond),
                update(TaskId, #{
                    status => failed,
                    result => {error, {Class, Reason, StackTrace}},
                    finishedAt => Finished
                }),
                alProgress:finish(TaskId, {error, {Class, Reason}}),
                Parent ! {eAliTask, TaskId, {error, {Class, Reason}}}
        end
    end),
    %% 先 spawn 拿到 pid 再一次写入含 pid 的条目，消除「无 pid 窗口」：
    %% cancel/1 不再命中无 pid 分支返回 notStarted（任务 6 W5）。
    Task = #{
        id => TaskId,
        status => running,
        prompt => toBinary(Prompt),
        sessionId => maps:get(sessionId, Opts, <<"default">>),
        startedAt => Started,
        pid => Pid
    },
    ets:insert(?TABLE, {TaskId, Task}),
    alProgress:start(TaskId),
    Pid ! {taskRegistered, TaskId},
    {ok, TaskId}.

%%--------------------------------------------------------------------
%% @doc
%% 查询指定任务的当前状态。
%%
%% @param TaskId 任务 ID（binary 或可转 binary 的值）
%% @return {ok, Task} 任务记录存在时返回任务 map；{error, notFound} 任务不存在
%% @end
%%--------------------------------------------------------------------
-spec status(binary()) -> {ok, task()} | {error, notFound}.
status(TaskId) ->
    ensureStarted(),
    case ets:lookup(?TABLE, toBinary(TaskId)) of
        [{_, Task}] -> {ok, Task};
        [] -> {error, notFound}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 取消一个正在运行的任务：向运行进程发送 kill 退出信号，并将状态标记为 cancelled。
%%
%% @param TaskId 任务 ID（binary 或可转 binary 的值）
%% @return ok 取消成功；{error, notRunning} 任务不在运行状态；{error, notFound} 任务不存在
%% @end
%%--------------------------------------------------------------------
-spec cancel(binary()) -> ok | {error, term()}.
cancel(TaskId) ->
    ensureStarted(),
    BinId = toBinary(TaskId),
    case ets:lookup(?TABLE, BinId) of
        [{_, #{pid := Pid, status := running}}] when is_pid(Pid) ->
            %% 先用 process_info + monitor 确认进程仍存活再 kill，
            %% 避免 PID 复用误杀无关进程（runner 已退出后其 PID 可能被
            %% BEAM 重新分配给其它进程）。kill 后仍以 status=running 为
            %% 条件写 cancelled，不覆盖 runner 抢先写入的终态。
            case erlang:process_info(Pid) of
                undefined ->
                    ok;
                _ ->
                    MonRef = erlang:monitor(process, Pid),
                    exit(Pid, kill),
                    receive
                        {'DOWN', MonRef, process, _, _} -> ok
                    after 0 -> ok
                    end,
                    erlang:demonitor(MonRef, [flush])
            end,
            case ets:lookup(?TABLE, BinId) of
                [{_, Task = #{status := running}}] ->
                    ets:update_element(?TABLE, BinId,
                                       {2, Task#{status => cancelled,
                                                 finishedAt => erlang:system_time(millisecond)}}),
                    %% 进度记录同步收尾，避免 cancel 后 alProgress 永久 running（任务 6 W4）。
                    alProgress:finish(BinId, {error, cancelled});
                _ -> ok
            end,
            ok;
        [{_, #{status := running}}] ->
            %% 防御性分支：spawnAsk 已改为「先 spawn 后一次写入含 pid 条目」，
            %% 正常情况下不会出现无 pid 的 running 条目；此处兜底补 finish，
            %% 避免进度记录永久 running（任务 6 W5）。
            alProgress:finish(BinId, {error, cancelled}),
            {error, notStarted};
        [{_, #{status := Status}}] when Status =/= running ->
            {error, notRunning};
        [] ->
            {error, notFound}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 列出 ETS 中所有已记录的任务。
%%
%% @return [task()] 返回所有任务 map 的列表
%% @end
%%--------------------------------------------------------------------
-spec list() -> [task()].
list() ->
    ensureStarted(),
    [Task || {_, Task} <- ets:tab2list(?TABLE)].

%%--------------------------------------------------------------------
%% @doc
%% 确保任务 ETS 表已创建（幂等）。表为命名表、public、set，开启读并发优化。
%%
%% @return ok 始终返回 ok，即使创建失败（被其它进程抢先创建）也吞掉异常
%% @end
%%--------------------------------------------------------------------
-spec ensureStarted() -> ok.
ensureStarted() ->
    case ets:info(?TABLE) of
        undefined ->
            try ets:new(?TABLE, [named_table, public, set, {read_concurrency, true}]) of
                _ -> ok
            catch
                _:_ -> ok
            end;
        _ ->
            ok
    end.

%% 用 Patch map 增量更新指定任务的字段（基于 maps:merge）；任务不存在时无操作。
%% 任务进入终态后安排延迟清理，防止 ETS 无限增长。
update(TaskId, Patch) ->
    case ets:lookup(?TABLE, TaskId) of
        [{_, Task}] ->
            Merged = maps:merge(Task, Patch),
            ets:insert(?TABLE, {TaskId, Merged}),
            case maps:get(status, Merged, running) of
                running -> ok;
                _ -> scheduleCleanup(TaskId)
            end;
        [] ->
            ok
    end.

%% 安排 5 分钟后清理已完成的任务条目
scheduleCleanup(TaskId) ->
    timer:apply_after(300000, ?MODULE, cleanupTask, [TaskId]),
    ok.

%% 清理指定任务条目（仅当处于终态时删除）
cleanupTask(TaskId) ->
    case ets:lookup(?TABLE, TaskId) of
        [{_, #{status := Status}}] when Status =/= running ->
            ets:delete(?TABLE, TaskId);
        _ -> ok
    end.

%% 在给定超时内非阻塞地接收 shutdown 退出信号；收到 shutdown 返回 true，否则 false。
%% 其它 EXIT 信号会被递归丢弃，避免被无关链接进程干扰。
receiveShutdown(Timeout) ->
    receive
        {'EXIT', _, shutdown} -> true;
        {'EXIT', _, _} -> receiveShutdown(Timeout)
    after Timeout ->
        false
    end.

%% @doc Check if cancel/1 has already set the status to `cancelled'.
%% Used by the runner to avoid overwriting a cancel that won the race.
%% 检查任务是否已被 cancel/1 标记为 cancelled，供 runner 避免覆盖获胜的取消操作。
alreadyCancelled(TaskId) ->
    BinId = toBinary(TaskId),
    case ets:lookup(?TABLE, BinId) of
        [{_, #{status := cancelled}}] -> true;
        _ -> false
    end.

%% 将任务标记为 cancelled 并记录结束时间，同时通知 alProgress 任务结束（取消原因）。
markCancelled(TaskId) ->
    BinId = toBinary(TaskId),
    case ets:lookup(?TABLE, BinId) of
        [{_, Task}] ->
            CancelledTask = Task#{status => cancelled,
                                  finishedAt => erlang:system_time(millisecond)},
            ets:insert(?TABLE, {BinId, CancelledTask});
        [] -> ok
    end,
    alProgress:finish(TaskId, {error, cancelled}).

%% 将 binary / list / atom 统一转换为 binary。
toBinary(X) when is_binary(X) -> X;
toBinary(X) when is_list(X) -> unicode:characters_to_binary(X);
toBinary(X) when is_atom(X) -> atom_to_binary(X, utf8).
