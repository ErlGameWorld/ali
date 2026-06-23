%%%-------------------------------------------------------------------
%%% @doc 任务规划编排（Plan → Execute → Verify）。
%%%
%%% 为每个会话维护一份结构化任务清单（有序步骤 + 状态），让 Agent
%%% 在处理复杂多步请求时先规划、再逐步执行并标记进度，提升长任务的
%%% 连贯性与可追溯性。提供核心 API 与可被模型调用的工具函数。
%%%
%%% 步骤状态：`pending` | `in_progress` | `done` | `skipped`。
%%% @end
%%%-------------------------------------------------------------------
-module(alPlan).

%% 核心 API
-export([
    setPlan/2,
    getPlan/1,
    updateStep/3,
    clear/1
]).

%% 工具函数（供 Agent 调用，签名为 fun(Args, Config)）
-export([
    planSet/2,
    planUpdate/2,
    planGet/2
]).

-define(TABLE, alPlan).

%%%===================================================================
%%% 核心 API
%%%===================================================================

%% @doc 设置（覆盖）会话的任务清单。Steps 为标题列表或步骤 map 列表。
-spec setPlan(binary(), [binary() | map()]) -> map().
setPlan(SessionId, Steps) ->
    ensureTable(),
    Normalized = normalizeSteps(Steps),
    Plan = #{steps => Normalized, updatedAt => now_ms()},
    ets:insert(?TABLE, {SessionId, Plan}),
    Plan.

%% @doc 获取会话当前任务清单；不存在时返回空清单。
-spec getPlan(binary()) -> map().
getPlan(SessionId) ->
    ensureTable(),
    case ets:lookup(?TABLE, SessionId) of
        [{_, Plan}] -> Plan;
        [] -> #{steps => [], updatedAt => 0}
    end.

%% @doc 更新指定步骤的状态/备注。
-spec updateStep(binary(), integer(), map()) -> {ok, map()} | {error, term()}.
updateStep(SessionId, Id, Updates) ->
    ensureTable(),
    Plan = getPlan(SessionId),
    Steps = maps:get(steps, Plan, []),
    case lists:keyfind(Id, 2, [{step, maps:get(id, S), S} || S <- Steps]) of
        false ->
            {error, stepNotFound};
        _ ->
            NewSteps = [maybeUpdate(S, Id, Updates) || S <- Steps],
            NewPlan = Plan#{steps => NewSteps, updatedAt => now_ms()},
            ets:insert(?TABLE, {SessionId, NewPlan}),
            {ok, NewPlan}
    end.

%% @doc 清空会话任务清单。
-spec clear(binary()) -> ok.
clear(SessionId) ->
    ensureTable(),
    ets:delete(?TABLE, SessionId),
    ok.

%%%===================================================================
%%% 工具函数（Agent 调用）
%%%===================================================================

%% @doc 工具：创建/覆盖任务清单。Args.steps 为标题或步骤 map 列表。
-spec planSet(map(), map()) -> {ok, map()} | {error, term()}.
planSet(Args, Config) ->
    case maps:get(steps, Args, undefined) of
        undefined -> {error, missingSteps};
        Steps when is_list(Steps) ->
            Plan = setPlan(sessionId(Config), Steps),
            {ok, withSummary(Plan)};
        _ -> {error, invalidSteps}
    end.

%% @doc 工具：更新某步骤的 status / note。Args 需含 `id`。
-spec planUpdate(map(), map()) -> {ok, map()} | {error, term()}.
planUpdate(Args, Config) ->
    case maps:get(id, Args, undefined) of
        undefined ->
            {error, missingId};
        Id0 ->
            Id = toInt(Id0),
            Updates = maps:with([status, note], normalizeUpdateKeys(Args)),
            case updateStep(sessionId(Config), Id, Updates) of
                {ok, Plan} -> {ok, withSummary(Plan)};
                Err -> Err
            end
    end.

%% @doc 工具：返回当前任务清单。
-spec planGet(map(), map()) -> {ok, map()}.
planGet(_Args, Config) ->
    {ok, withSummary(getPlan(sessionId(Config)))}.

%%%===================================================================
%%% 内部
%%%===================================================================

%% 将标题/步骤列表规范化为带 id 与状态的步骤 map 列表。
normalizeSteps(Steps) ->
    {Normalized, _} = lists:mapfoldl(fun(S, N) ->
        {normalizeStep(S, N), N + 1}
    end, 1, Steps),
    Normalized.

normalizeStep(Title, N) when is_binary(Title); is_list(Title) ->
    #{id => N, title => toBin(Title), status => pending, note => <<>>};
normalizeStep(Map, N) when is_map(Map) ->
    #{
        id => N,
        title => toBin(maps:get(title, Map, <<"(untitled)"/utf8>>)),
        status => normalizeStatus(maps:get(status, Map, pending)),
        note => toBin(maps:get(note, Map, <<>>))
    }.

%% 命中目标 id 时应用更新。
maybeUpdate(#{id := Id} = Step, Id, Updates) ->
    Status = case maps:get(status, Updates, undefined) of
        undefined -> maps:get(status, Step);
        S -> normalizeStatus(S)
    end,
    Note = case maps:get(note, Updates, undefined) of
        undefined -> maps:get(note, Step);
        Nt -> toBin(Nt)
    end,
    Step#{status => Status, note => Note};
maybeUpdate(Step, _Id, _Updates) ->
    Step.

%% 归一化状态原子。
normalizeStatus(S) when is_atom(S) -> normalizeStatus(atom_to_binary(S, utf8));
normalizeStatus(S) when is_list(S) -> normalizeStatus(llmJson:text(S));
normalizeStatus(<<"pending"/utf8>>) -> pending;
normalizeStatus(<<"in_progress"/utf8>>) -> in_progress;
normalizeStatus(<<"inprogress"/utf8>>) -> in_progress;
normalizeStatus(<<"done"/utf8>>) -> done;
normalizeStatus(<<"completed"/utf8>>) -> done;
normalizeStatus(<<"skipped"/utf8>>) -> skipped;
normalizeStatus(_) -> pending.

%% 附加进度摘要字段。
withSummary(#{steps := Steps} = Plan) ->
    Done = length([1 || #{status := done} <- Steps]),
    Total = length(Steps),
    Plan#{summary => #{done => Done, total => Total}}.

%% 将 Args 中的字符串 key 统一为原子 status/note（容错 LLM 传入）。
normalizeUpdateKeys(Args) ->
    maps:fold(fun(K, V, Acc) ->
        Key = case K of
            <<"status"/utf8>> -> status;
            <<"note"/utf8>> -> note;
            Other -> Other
        end,
        Acc#{Key => V}
    end, #{}, Args).

%% 从 Config 取 sessionId（由 alTools 注入）。
sessionId(Config) ->
    case maps:get(sessionId, Config, undefined) of
        undefined -> <<"default"/utf8>>;
        Sid when is_binary(Sid) -> Sid;
        Sid -> toBin(Sid)
    end.

ensureTable() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, public, set]);
        _ ->
            ok
    end,
    ok.

now_ms() -> erlang:system_time(millisecond).

toInt(I) when is_integer(I) -> I;
toInt(B) when is_binary(B) -> binary_to_integer(B);
toInt(L) when is_list(L) -> list_to_integer(L).

toBin(B) when is_binary(B) -> B;
toBin(L) when is_list(L) -> unicode:characters_to_binary(L);
toBin(A) when is_atom(A) -> atom_to_binary(A, utf8);
toBin(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).
