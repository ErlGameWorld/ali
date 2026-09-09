%%%-------------------------------------------------------------------
%% @doc 每会话结构化任务计划（ETS 支撑）。
%%
%% 每会话持有有序步骤列表与状态机
%% （`pending` | `inProgress` | `done` | `skipped`）。支持 agent
%% 先规划再执行多步任务，进度可追踪。
%% @end
%%%-------------------------------------------------------------------

-module(alPlan).

-export([
    setPlan/2,
    getPlan/1,
    updateStep/3,
    clear/1,
    withSummary/1,
    ensureStarted/0
]).

-define(Table, alPlan).

%%--------------------------------------------------------------------
%% @doc
%% 为指定会话设置任务计划，将步骤列表归一化后存入 ETS 表。
%%
%% @param SessionId 会话标识
%% @param Steps 步骤列表，元素可以是二进制字符串或映射
%% @return 归一化后的计划映射（含 steps 和 updatedAt 字段）
%% @end
%%--------------------------------------------------------------------
-spec setPlan(term(), [binary() | map()]) -> map().
setPlan(SessionId, Steps) ->
    ensureStarted(),
    Normalized = normalizeSteps(Steps),
    Plan = #{steps => Normalized, updatedAt => nowMs()},
    ets:insert(?Table, {toKey(SessionId), Plan}),
    Plan.

%%--------------------------------------------------------------------
%% @doc
%% 获取指定会话的任务计划，若不存在则返回空计划。
%%
%% @param SessionId 会话标识
%% @return 计划映射；不存在时返回 #{steps => [], updatedAt => 0}
%% @end
%%--------------------------------------------------------------------
-spec getPlan(term()) -> map().
getPlan(SessionId) ->
    ensureStarted(),
    case ets:lookup(?Table, toKey(SessionId)) of
        [{_, Plan}] -> Plan;
        [] -> #{steps => [], updatedAt => 0}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 更新指定会话中某个步骤的状态或备注，并刷新更新时间。
%%
%% @param SessionId 会话标识
%% @param Id 步骤序号
%% @param Updates 待更新字段的映射（可包含 status、note）
%% @return {ok, NewPlan} 更新成功；{error, stepNotFound} 步骤不存在
%% @end
%%--------------------------------------------------------------------
-spec updateStep(term(), integer(), map()) -> {ok, map()} | {error, term()}.
updateStep(SessionId, Id, Updates) ->
    ensureStarted(),
    Key = toKey(SessionId),
    withPlanLock(Key, fun() ->
        case ets:lookup(?Table, Key) of
            [{_, Plan}] ->
                Steps = maps:get(steps, Plan, []),
                case lists:any(fun(#{id := SId}) -> SId =:= Id end, Steps) of
                    false ->
                        {error, stepNotFound};
                    true ->
                        NewSteps = [maybeUpdateStep(S, Id, Updates) || S <- Steps],
                        NewPlan = Plan#{steps => NewSteps, updatedAt => nowMs()},
                        ets:insert(?Table, {Key, NewPlan}),
                        {ok, NewPlan}
                end;
            [] ->
                {error, stepNotFound}
        end
    end).

%%--------------------------------------------------------------------
%% @doc
%% 清除指定会话的任务计划，从 ETS 表中删除对应条目。
%%
%% @param SessionId 会话标识
%% @return ok
%% @end
%%--------------------------------------------------------------------
-spec clear(term()) -> ok.
clear(SessionId) ->
    ensureStarted(),
    ets:delete(?Table, toKey(SessionId)),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% 为计划计算并追加摘要信息（已完成步骤数 / 总步骤数）。
%%
%% @param Plan 计划映射，需包含 steps 字段
%% @return 追加了 summary 字段的计划映射；若无 steps 字段则原样返回
%% @end
%%--------------------------------------------------------------------
-spec withSummary(map()) -> map().
withSummary(#{steps := Steps} = Plan) ->
    Done = length([1 || #{status := done} <- Steps]),
    Total = length(Steps),
    Plan#{summary => #{done => Done, total => Total}};
withSummary(Plan) ->
    Plan.

%%--------------------------------------------------------------------
%% @doc
%% 确保 ETS 表已创建（幂等），表不存在时新建一个公开的命名表。
%%
%% @return ok
%% @end
%%--------------------------------------------------------------------
-spec ensureStarted() -> ok.
ensureStarted() ->
    case ets:info(?Table) of
        undefined ->
            try ets:new(?Table, [
                named_table, public, set,
                {read_concurrency, true},
                {write_concurrency, true}
            ]) of
                _ -> ok
            catch
                _:_ -> ok
            end;
        _ ->
            ok
    end.

%%%===================================================================
%%% Internal
%%%===================================================================

%% 将步骤列表归一化，为每个步骤分配自增序号（从 1 开始）。
normalizeSteps(Steps) ->
    {Normalized, _} = lists:mapfoldl(fun(S, N) ->
        {normalizeStep(S, N), N + 1}
    end, 1, Steps),
    Normalized.

%% 归一化单个步骤：字符串类型转为基础步骤映射；映射类型则补全缺失字段。
normalizeStep(Title, N) when is_binary(Title); is_list(Title) ->
    #{id => N, title => toBinary(Title), status => pending, note => <<>>};
normalizeStep(Map, N) when is_map(Map) ->
    #{
        id => N,
        title => toBinary(maps:get(title, Map, <<"(untitled)">>)),
        status => normalizeStatus(maps:get(status, Map, pending)),
        note => toBinary(maps:get(note, Map, <<>>))
    }.

%% 当步骤序号匹配目标 Id 时，按 Updates 合并更新 status 与 note；否则原样返回。
maybeUpdateStep(#{id := Id} = Step, Id, Updates) ->
    Status = case maps:get(status, Updates, undefined) of
        undefined -> maps:get(status, Step);
        S -> normalizeStatus(S)
    end,
    Note = case maps:get(note, Updates, undefined) of
        undefined -> maps:get(note, Step);
        Nt -> toBinary(Nt)
    end,
    Step#{status => Status, note => Note};
maybeUpdateStep(Step, _Id, _Updates) ->
    Step.

%% 将各种形式的 status 表达（原子/字符串/二进制）归一化为内部原子，未知值归为 pending。
normalizeStatus(S) when is_atom(S) -> normalizeStatus(atom_to_binary(S, utf8));
normalizeStatus(S) when is_list(S) -> normalizeStatus(unicode:characters_to_binary(S));
normalizeStatus(<<"pending">>) -> pending;
normalizeStatus(<<"in_progress">>) -> inProgress;
normalizeStatus(<<"inprogress">>) -> inProgress;
normalizeStatus(<<"inProgress">>) -> inProgress;
normalizeStatus(<<"done">>) -> done;
normalizeStatus(<<"completed">>) -> done;
normalizeStatus(<<"skipped">>) -> skipped;
normalizeStatus(<<"failed">>) -> failed;
normalizeStatus(_) -> pending.

%% 将任意会话标识转换为二进制键，用于 ETS 索引；复杂项使用 phash2 兜底。
toKey(X) when is_binary(X) -> X;
toKey(X) when is_list(X) -> unicode:characters_to_binary(X);
toKey(X) when is_atom(X) -> atom_to_binary(X, utf8);
toKey(X) -> integer_to_binary(erlang:phash2(X)).

%% 将多种类型的值统一转换为二进制。
toBinary(B) when is_binary(B) -> B;
toBinary(L) when is_list(L) -> unicode:characters_to_binary(L);
toBinary(A) when is_atom(A) -> atom_to_binary(A, utf8);
toBinary(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).

%% 返回当前系统时间的毫秒时间戳。
nowMs() -> erlang:system_time(millisecond).

%% 对计划行的读改写加进程内自旋锁：updateStep 读-改-写整行，并发更新不同步骤
%% 会相互覆盖。insert_new 抢锁，try/after 保证异常时也释放；持有者被 kill 时
%% 经 monitor 回收残留锁，避免死等。
withPlanLock(Key, Fun) ->
    LockKey = {Key, planLock},
    case ets:insert_new(?Table, {LockKey, self()}) of
        true ->
            try Fun()
            after
                ets:delete(?Table, LockKey)
            end;
        false ->
            case ets:lookup(?Table, LockKey) of
                [{_, Holder}] when is_pid(Holder) ->
                    Ref = erlang:monitor(process, Holder),
                    receive
                        {'DOWN', Ref, process, Holder, _Reason} ->
                            ets:delete(?Table, LockKey),
                            withPlanLock(Key, Fun)
                    after 50 ->
                            erlang:demonitor(Ref, [flush]),
                            withPlanLock(Key, Fun)
                    end;
                _ ->
                    ets:delete(?Table, LockKey),
                    withPlanLock(Key, Fun)
            end
    end.
