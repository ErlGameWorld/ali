%%%-------------------------------------------------------------------
%% @doc 异步任务进度跟踪（ETS 支撑）。
%%
%% 为 {@link alTask} 与 Web 轮询记录工具调用步骤、LLM 阶段与最终
%% 答案/错误。事件可按索引增量拉取。单次 run 最多保留
%% {@code ?MaxEvents} 条事件。
%%
%% 并发说明：早期实现把「整个 run（含 events 列表）」存成单行，`emit'
%% 需读-改-写该行，多个进程并发向同一 run 追加事件时会相互覆盖、丢事件。
%% 现改为「独立行 + 原子计数器」模型（A-M4）：
%% <ul>
%%   <li>`{RunId, idx}' 行用 {@link ets:update_counter/4} 原子分配事件序号，
%%       杜绝序号竞争；</li>
%%   <li>每个事件写入独立行 `{RunId, ev, Index}'，互不覆盖；</li>
%%   <li>`{RunId, meta}' 行仅保存运行级状态（status/result/时间戳），
%%       仅在 start/finish 时写入（低频，无热点竞争）。</li>
%% </ul>
%% @end
%%%-------------------------------------------------------------------

-module(alProgress).

-export([
    start/1,
    emit/2,
    snapshot/1,
    snapshot/2,
    finish/2,
    drop/1,
    ensureStarted/0,
    cleanupRun/1,
    subscribe/1,
    unsubscribe/1,
    appendPartial/2,
    getPartial/1
]).

-define(TABLE, alProgress).
-define(MaxEvents, 500).

%%--------------------------------------------------------------------
%% @doc
%% 启动一次异步任务的进度追踪，初始化运行记录并写入第一条 started 事件。
%%
%% @param RunId 运行标识
%% @return ok
%% @end
%%--------------------------------------------------------------------
-spec start(term()) -> ok.
start(RunId) ->
    ensureStarted(),
    Bin = toBinary(RunId),
    Now = erlang:system_time(millisecond),
    %% 清理可能残留的同 id 旧行（重启/复用同一 RunId 时）。
    dropRows(Bin),
    First = #{
        type => started,
        message => <<"task started">>,
        ts => Now,
        index => 0
    },
    ets:insert(?TABLE, {{Bin, ev, 0}, First}),
    %% idx 计数器指向「下一个待分配序号」；started 已占用 0。
    ets:insert(?TABLE, {{Bin, idx}, 1}),
    ets:insert(?TABLE, {{Bin, meta}, #{status => running, startedAt => Now}}),
    ets:insert(?TABLE, {{Bin, partial}, <<>>}),
    notifySubs(Bin, First),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% 向正在运行的 RunId 追加一条进度事件；超出上限时丢弃最旧事件以保持长度。
%%
%% 仅当运行状态为 running 时才写入；非运行状态静默忽略。序号通过
%% update_counter 原子分配，事件写入独立行，避免并发读-改-写竞态。
%% @param RunId 运行标识
%% @param Event 事件映射（会自动补 ts 和 index）
%% @return ok
%% @end
%%--------------------------------------------------------------------
-spec emit(term(), map()) -> ok.
emit(RunId, Event) when is_map(Event) ->
    ensureStarted(),
    Bin = toBinary(RunId),
    case ets:lookup(?TABLE, {Bin, meta}) of
        [{_, #{status := running}}] ->
            Index = ets:update_counter(?TABLE, {Bin, idx}, {2, 1}, {{Bin, idx}, 1}) - 1,
            Ev = Event#{
                ts => erlang:system_time(millisecond),
                index => Index
            },
            ets:insert(?TABLE, {{Bin, ev, Index}, Ev}),
            %% 环形裁剪：仅保留最近 ?MaxEvents 条，删除滑出窗口的最旧事件。
            case Index >= ?MaxEvents of
                true -> ets:delete(?TABLE, {Bin, ev, Index - ?MaxEvents});
                false -> ok
            end,
            %% 终答类事件同步写入 partial，便于 cancel 时落盘。
            maybeCapturePartial(Bin, Ev),
            notifySubs(Bin, Ev),
            ok;
        _ ->
            ok
    end.

%%--------------------------------------------------------------------
%% @doc
%% 返回 RunId 的完整进度快照（从第 0 条开始）。
%%
%% @param RunId 运行标识
%% @return 快照映射
%% @end
%%--------------------------------------------------------------------
-spec snapshot(term()) -> map().
snapshot(RunId) ->
    snapshot(RunId, 0).

%%--------------------------------------------------------------------
%% @doc
%% 返回 RunId 自指定索引以来的增量进度快照，便于 Web 端增量轮询。
%%
%% Since 为「当前保留事件窗口内的位置游标」（与 eventCount 同一量纲），
%% 与流式转发的 `Since := eventCount' 语义保持一致。
%% @param RunId 运行标识
%% @param Since 起始位置（包含）
%% @return 快照映射；不存在时返回 #{status => notFound, ...}
%% @end
%%--------------------------------------------------------------------
-spec snapshot(term(), non_neg_integer()) -> map().
snapshot(RunId, Since) when is_integer(Since), Since >= 0 ->
    ensureStarted(),
    Bin = toBinary(RunId),
    case ets:lookup(?TABLE, {Bin, meta}) of
        [{_, Meta}] ->
            %% eventCount / Since 使用绝对事件序号（下一待分配 idx），
            %% 环缓冲满窗后仍可增量轮询；勿用 min(N,Max) 当游标。
            NextIndex = counter(Bin),
            LowIndex = max(0, NextIndex - ?MaxEvents),
            From = max(LowIndex, Since),
            Events = collectEvents(Bin, From, NextIndex - 1),
            #{
                status => maps:get(status, Meta, running),
                events => Events,
                eventCount => NextIndex,
                result => maps:get(result, Meta, undefined),
                startedAt => maps:get(startedAt, Meta, undefined),
                finishedAt => maps:get(finishedAt, Meta, undefined)
            };
        [] ->
            #{status => notFound, events => [], eventCount => 0}
    end.

%% 读取 idx 计数器（下一个待分配序号）；无记录视为 0。
counter(Bin) ->
    case ets:lookup(?TABLE, {Bin, idx}) of
        [{_, N}] when is_integer(N) -> N;
        _ -> 0
    end.

%% 按序号区间 [From, To] 顺序收集事件行，缺失序号自动跳过。
collectEvents(_Bin, From, To) when From > To ->
    [];
collectEvents(Bin, From, To) ->
    [E || I <- lists:seq(From, To), {_, E} <- ets:lookup(?TABLE, {Bin, ev, I})].

%%--------------------------------------------------------------------
%% @doc
%% 结束一次运行，根据结果类型标记为 completed 或 failed 并写入最终结果。
%%
%% @param RunId 运行标识
%% @param Result {ok, Answer} | {error, Reason} | 其他（视为失败）
%% @return ok
%% @end
%%--------------------------------------------------------------------
-spec finish(term(), {ok, term()} | {error, term()} | term()) -> ok.
finish(RunId, {ok, Answer}) ->
    finishRun(RunId, completed, {ok, Answer});
finish(RunId, {error, Reason}) ->
    finishRun(RunId, failed, {error, Reason});
finish(RunId, Other) ->
    finishRun(RunId, failed, Other).

%%--------------------------------------------------------------------
%% @doc
%% 丢弃指定运行的所有进度记录，从 ETS 表中删除。
%%
%% @param RunId 运行标识
%% @return ok
%% @end
%%--------------------------------------------------------------------
-spec drop(term()) -> ok.
drop(RunId) ->
    ensureStarted(),
    dropRows(toBinary(RunId)),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% 确保 ETS 表已创建（幂等），表不存在时新建一个公开的命名表。
%%
%% @return ok
%% @end
%%--------------------------------------------------------------------
-spec ensureStarted() -> ok.
ensureStarted() ->
    case ets:info(?TABLE) of
        undefined ->
            try ets:new(?TABLE, [
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

%% 内部实现：将运行记录置为完成状态并写入结果与结束时间戳。
finishRun(RunId, Status, Result) ->
    ensureStarted(),
    Bin = toBinary(RunId),
    Now = erlang:system_time(millisecond),
    case ets:lookup(?TABLE, {Bin, meta}) of
        [{_, #{status := running} = Meta}] ->
            NewMeta = Meta#{
                status => Status,
                result => Result,
                finishedAt => Now
            },
            ets:insert(?TABLE, {{Bin, meta}, NewMeta}),
            notifySubs(Bin, #{type => finished, status => Status, ts => Now}),
            timer:apply_after(300000, ?MODULE, cleanupRun, [Bin]),
            ok;
        _ ->
            ok
    end.

%%--------------------------------------------------------------------
%% @doc
%% 订阅指定 RunId 的进度事件。订阅者会收到
%% `{eProgressEvent, RunIdBin, EventMap}'。finish/drop 后自动失效。
%% @end
%%--------------------------------------------------------------------
-spec subscribe(term()) -> ok.
subscribe(RunId) ->
    ensureStarted(),
    Bin = toBinary(RunId),
    Pid = self(),
    Subs = case ets:lookup(?TABLE, {Bin, subs}) of
        [{_, List}] when is_list(List) -> lists:usort([Pid | List]);
        _ -> [Pid]
    end,
    ets:insert(?TABLE, {{Bin, subs}, Subs}),
    ok.

%%--------------------------------------------------------------------
%% @doc 取消当前进程对 RunId 的订阅。
%% @end
%%--------------------------------------------------------------------
-spec unsubscribe(term()) -> ok.
unsubscribe(RunId) ->
    ensureStarted(),
    Bin = toBinary(RunId),
    Pid = self(),
    case ets:lookup(?TABLE, {Bin, subs}) of
        [{_, List}] when is_list(List) ->
            case lists:delete(Pid, List) of
                [] -> ets:delete(?TABLE, {Bin, subs});
                Rest -> ets:insert(?TABLE, {{Bin, subs}, Rest})
            end;
        _ ->
            ok
    end,
    ok.

%%--------------------------------------------------------------------
%% @doc
%% 追加流式 partial 文本（token 增量）。cancel 时可 {@link getPartial/1} 取回。
%% @end
%%--------------------------------------------------------------------
-spec appendPartial(term(), binary() | string()) -> ok.
appendPartial(RunId, Chunk) ->
    ensureStarted(),
    Bin = toBinary(RunId),
    Text = toBinary(Chunk),
    case Text of
        <<>> -> ok;
        _ ->
            withPartialLock(Bin, fun() ->
                case ets:lookup(?TABLE, {Bin, partial}) of
                    [{_, Acc}] when is_binary(Acc) ->
                        ets:insert(?TABLE, {{Bin, partial}, <<Acc/binary, Text/binary>>});
                    _ ->
                        ets:insert(?TABLE, {{Bin, partial}, Text})
                end,
                ok
            end)
    end.

%%--------------------------------------------------------------------
%% @doc 读取已累积的 partial 文本（无则 `<<>>`）。
%% @end
%%--------------------------------------------------------------------
-spec getPartial(term()) -> binary().
getPartial(RunId) ->
    ensureStarted(),
    Bin = toBinary(RunId),
    case ets:lookup(?TABLE, {Bin, partial}) of
        [{_, Acc}] when is_binary(Acc) -> Acc;
        _ -> <<>>
    end.

%% 终答/思考类事件写入 partial（取最长文本，避免被短摘要覆盖）。
maybeCapturePartial(Bin, Ev) when is_map(Ev) ->
    Text = firstBin([
        maps:get(text, Ev, undefined),
        maps:get(message, Ev, undefined),
        maps:get(answer, Ev, undefined),
        maps:get(<<"text">>, Ev, undefined),
        maps:get(<<"message">>, Ev, undefined)
    ]),
    Type = maps:get(type, Ev, undefined),
    case {Type, Text} of
        {_, <<>>} -> ok;
        {thought, _} -> ok;  %% 思考过程不覆盖终答 partial
        {step, _} -> ok;
        {Type, T} when Type =:= answer; Type =:= completed; Type =:= token ->
            withPartialLock(Bin, fun() ->
                case ets:lookup(?TABLE, {Bin, partial}) of
                    [{_, Acc}] when is_binary(Acc), byte_size(T) >= byte_size(Acc) ->
                        ets:insert(?TABLE, {{Bin, partial}, T});
                    [{_, Acc}] when is_binary(Acc), Acc =/= <<>> ->
                        ok;
                    _ ->
                        ets:insert(?TABLE, {{Bin, partial}, T})
                end
            end);
        _ ->
            %% 其它带长文本的事件：仅在当前 partial 为空时写入
            withPartialLock(Bin, fun() ->
                case ets:lookup(?TABLE, {Bin, partial}) of
                    [{_, <<>>}] -> ets:insert(?TABLE, {{Bin, partial}, Text});
                    [{_, Acc}] when is_binary(Acc), Acc =/= <<>> -> ok;
                    _ -> ets:insert(?TABLE, {{Bin, partial}, Text})
                end
            end)
    end;
maybeCapturePartial(_, _) ->
    ok.

firstBin([]) -> <<>>;
firstBin([B | _]) when is_binary(B), B =/= <<>> -> B;
firstBin([L | Rest]) when is_list(L) ->
    try toBinary(L) of
        <<>> -> firstBin(Rest);
        B -> B
    catch _:_ -> firstBin(Rest)
    end;
firstBin([_ | Rest]) ->
    firstBin(Rest).

notifySubs(Bin, Ev) ->
    case ets:lookup(?TABLE, {Bin, subs}) of
        [{_, Pids}] when is_list(Pids) ->
            %% 通知的同时过滤已死订阅者，避免死 pid 累积。
            Alive = [Pid || Pid <- Pids, is_process_alive(Pid)],
            case Alive of
                [] ->
                    ets:delete(?TABLE, {Bin, subs});
                _ ->
                    case Alive =:= Pids of
                        true -> ok;
                        false -> ets:insert(?TABLE, {{Bin, subs}, Alive})
                    end,
                    lists:foreach(fun(Pid) -> Pid ! {eProgressEvent, Bin, Ev} end, Alive)
            end;
        _ ->
            ok
    end.

%% 清理指定运行记录（延迟 5 分钟后调用）
cleanupRun(RunId) ->
    dropRows(toBinary(RunId)),
    ok.

%% 删除某 RunId 的全部行（meta / idx / partial / subs 二元组键，以及 ev 三元组键）。
dropRows(Bin) ->
    ets:match_delete(?TABLE, {{Bin, '_'}, '_'}),
    ets:match_delete(?TABLE, {{Bin, ev, '_'}, '_'}),
    ok.

%% 对 partial 行的读改写加进程内自旋锁：partial 会被多个进程并发追加/覆盖，
%% 读-改-写不原子会丢增量。insert_new 抢锁，try/after 保证异常时也释放；
%% 持有者被 kill 时经 monitor 回收残留锁，避免死等。
withPartialLock(Bin, Fun) ->
    LockKey = {Bin, partialLock},
    case ets:insert_new(?TABLE, {LockKey, self()}) of
        true ->
            try Fun()
            after
                ets:delete(?TABLE, LockKey)
            end;
        false ->
            case ets:lookup(?TABLE, LockKey) of
                [{_, Holder}] when is_pid(Holder) ->
                    Ref = erlang:monitor(process, Holder),
                    receive
                        {'DOWN', Ref, process, Holder, _Reason} ->
                            ets:delete(?TABLE, LockKey),
                            withPartialLock(Bin, Fun)
                    after 50 ->
                            erlang:demonitor(Ref, [flush]),
                            withPartialLock(Bin, Fun)
                    end;
                _ ->
                    ets:delete(?TABLE, LockKey),
                    withPartialLock(Bin, Fun)
            end
    end.

%% 将多种类型的值统一转换为二进制。
toBinary(X) when is_binary(X) -> X;
toBinary(X) when is_list(X) -> unicode:characters_to_binary(X);
toBinary(X) when is_atom(X) -> atom_to_binary(X, utf8);
toBinary(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).
