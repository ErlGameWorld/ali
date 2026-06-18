%%%-------------------------------------------------------------------
%%% @doc 异步任务进度追踪（ETS 存储）。
%%%
%%% 用于 {@link askAsync/1} 及 Web API 轮询：记录工具调用步骤、
%%% LLM 请求阶段、最终回答或错误。事件按时间顺序编号，支持增量拉取。
%%%
%%% 数据存于公共 ETS 表 `alProgress`，单任务最多保留 {@code MAX_EVENTS} 条事件。
%%% @end
%%%-------------------------------------------------------------------
-module(alProgress).

-export([
    start/1,
    emit/2,
    snapshot/1,
    snapshot/2,
    finish/2,
    drop/1
]).

-define(TABLE, alProgress).
%% 单任务事件上限，防止长时间运行任务占用过多内存
-define(MAX_EVENTS, 500).

%% @doc 开始追踪一个运行实例。
%% @param RunId 任务/运行 ID（与 askAsync 返回的 TaskId 对应）
-spec start(term()) -> ok.
start(RunId) ->
    ensure_table(),
    Now = erlang:system_time(millisecond),
    First = #{
        type => started,
        message => <<"任务已开始"/utf8>>,
        ts => Now,
        index => 0
    },
    Run = #{
        id => to_binary(RunId),
        status => running,
        events => [First],
        nextIndex => 1,
        startedAt => Now
    },
    ets:insert(?TABLE, {to_binary(RunId), Run}),
    ok.

%% @doc 追加一条进度事件（仅 running 状态有效）。
%%
%% Event map 建议包含 `type`（如 step、tool、answer）、`message` 等字段；
%% 本模块自动补充 `ts`（毫秒时间戳）和 `index`（递增序号）。
-spec emit(term(), map()) -> ok.
emit(RunId, Event) when is_map(Event) ->
    ensure_table(),
    BinId = to_binary(RunId),
    case ets:lookup(?TABLE, BinId) of
        [{_, #{status := running} = Run}] ->
            NextIndex = maps:get(nextIndex, Run, 0),
            Ev = Event#{
                ts => erlang:system_time(millisecond),
                index => NextIndex
            },
            %% 头插 O(1)，读取时 reverse；限制事件上限避免内存膨胀
            Events0 = maps:get(events, Run, []),
            Events1 = [Ev | Events0],
            Events = case length(Events1) > ?MAX_EVENTS of
                true -> lists:sublist(Events1, ?MAX_EVENTS);
                false -> Events1
            end,
            ets:insert(?TABLE, {BinId, Run#{events => Events, nextIndex => NextIndex + 1}}),
            ok;
        _ ->
            ok
    end.

%% @doc 获取任务进度快照（全部事件）。
-spec snapshot(term()) -> map().
snapshot(RunId) ->
    snapshot(RunId, 0).

%% @doc 获取任务进度快照，从指定事件序号起增量返回。
%%
%% @param Since 起始 index（0 表示从头）；用于 Web 轮询避免重复传输
%% @returns `#{status, events, eventCount, result, startedAt, finishedAt}`
-spec snapshot(term(), non_neg_integer()) -> map().
snapshot(RunId, Since) when is_integer(Since), Since >= 0 ->
    ensure_table(),
    case ets:lookup(?TABLE, to_binary(RunId)) of
        [{_, Run}] ->
            %% events 以头插存储，读取时 reverse 恢复时间顺序
            EventsRev = maps:get(events, Run, []),
            Events = lists:reverse(EventsRev),
            Slice = lists:sublist(Events, Since + 1, length(Events) - Since),
            #{
                status => maps:get(status, Run, running),
                events => Slice,
                eventCount => length(Events),
                result => maps:get(result, Run, undefined),
                startedAt => maps:get(startedAt, Run, undefined),
                finishedAt => maps:get(finishedAt, Run, undefined)
            };
        [] ->
            #{status => not_found, events => [], eventCount => 0}
    end.

%% @doc 标记任务结束（成功或失败）。
-spec finish(term(), {ok, term()} | {error, term()} | term()) -> ok.
finish(RunId, {ok, Answer}) ->
    finish_run(RunId, completed, {ok, Answer});
finish(RunId, {error, Reason}) ->
    finish_run(RunId, failed, {error, Reason});
finish(RunId, Other) ->
    finish_run(RunId, failed, Other).

finish_run(RunId, Status, Result) ->
    ensure_table(),
    BinId = to_binary(RunId),
    Now = erlang:system_time(millisecond),
    case ets:lookup(?TABLE, BinId) of
        [{_, Run}] ->
            ets:insert(?TABLE, {BinId, Run#{
                status => Status,
                result => Result,
                finishedAt => Now
            }}),
            ok;
        [] ->
            ok
    end.

%% @doc 删除任务进度记录，释放 ETS 条目。
-spec drop(term()) -> ok.
drop(RunId) ->
    ensure_table(),
    ets:delete(?TABLE, to_binary(RunId)),
    ok.

ensure_table() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, public, set]);
        _ ->
            ok
    end.

to_binary(X) when is_binary(X) -> X;
to_binary(X) when is_list(X) -> unicode:characters_to_binary(X);
to_binary(X) when is_atom(X) -> atom_to_binary(X, utf8);
to_binary(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).