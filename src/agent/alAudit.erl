%%%-------------------------------------------------------------------
%%% @doc 工具调用审计日志模块。
%%%
%%% 使用 ETS 有序集合在内存中缓存最近的操作记录，同时以 JSONL
%%% 格式追加持久化到 `.al/audit.jsonl`。记录包含会话 ID、工具名、
%%% 经脱敏处理的参数与结果、时间戳等，供调试与合规追溯。
%%% 内存条目超过上限时自动裁剪最旧记录。
%%% @end
%%%-------------------------------------------------------------------
-module(alAudit).

-export([
    init/0,
    log/4,
    list/0,
    list/1,
    query/1,
    stats/0,
    clear/0,
    formatEntry/1
]).

-define(TABLE, alAudit).
%% 内存中最多保留的审计条目数
-define(MAX_ENTRIES, 500).

%% @doc 初始化审计 ETS 表（幂等）。
%% 若表已存在则跳过创建。
%% @returns `ok`
-spec init() -> ok.
init() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, public, ordered_set]);
        _ ->
            ok
    end,
    ok.

%% @doc 记录一次工具调用审计条目。
%% 参数与结果经 {@link alPolicy:sanitizeTerm/1} 脱敏后写入 ETS 并追加到磁盘。
%% @param SessionId 会话标识（binary）
%% @param Tool 工具原子名
%% @param Args 调用参数 map
%% @param Result 执行结果 map 或 term
%% @returns `ok`
-spec log(binary(), atom(), map(), map()) -> ok.
log(SessionId, Tool, Args, Result) ->
    init(),
    Id = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    Entry = #{
        id => Id,
        sessionId => SessionId,
        tool => Tool,
        args => alPolicy:sanitizeTerm(Args),
        result => alPolicy:sanitizeTerm(Result),
        at => erlang:system_time(millisecond)
    },
    ets:insert(?TABLE, {Id, Entry}),
    persist_entry(Entry),
    trim(),
    ok.

%% 将单条审计记录以 JSONL 行追加写入磁盘日志文件
persist_entry(Entry) ->
    Path = audit_log_path(),
    ok = filelib:ensure_dir(filename:join(filename:dirname(Path), "x")),
    Line = iolist_to_binary([llmJson:encode(Entry), <<"\n"/utf8>>]),
    %% 使用 raw + append 模式，借助 OS 层 O_APPEND 保证短行原子追加
    file:write_file(Path, Line, [append, raw]).

%% 当 ETS 条目数超过 MAX_ENTRIES 时，从最旧键开始删除多余记录
trim() ->
    Size = ets:info(?TABLE, size),
    case Size > ?MAX_ENTRIES of
        true ->
            ToDelete = Size - ?MAX_ENTRIES,
            First = ets:first(?TABLE),
            trimLoop(First, ToDelete);
        false ->
            ok
    end.

%% trim/0 的递归辅助：沿有序集键序删除 N 条最旧记录
trimLoop(_Key, 0) -> ok;
trimLoop('$end_of_table', _) -> ok;
trimLoop(Key, N) ->
    Next = ets:next(?TABLE, Key),
    ets:delete(?TABLE, Key),
    trimLoop(Next, N - 1).

%% @doc 返回最近 50 条审计记录（按时间降序）。
%% @returns `[map()]`
-spec list() -> [map()].
list() ->
    list(50).

%% @doc 返回最近 Limit 条审计记录（按 at 字段降序）。
%% @param Limit 最大返回条数
%% @returns `[map()]'
-spec list(non_neg_integer()) -> [map()].
list(Limit) ->
    init(),
    %% 利用 ordered_set 的键序（单调递增）从尾向前遍历，避免 ets:tab2list 全量复制。
    collectRecent(Limit, ets:last(?TABLE), []).

%% @doc 按条件检索审计记录。
%% Filters 可含：`tool`（atom）、`sessionId`（binary）、`since`（毫秒时间戳）、
%% `limit`（默认 100）。结果按时间降序。
-spec query(map()) -> [map()].
query(Filters) ->
    init(),
    Limit = maps:get(limit, Filters, 100),
    Tool = maps:get(tool, Filters, undefined),
    Session = maps:get(sessionId, Filters, undefined),
    Since = maps:get(since, Filters, undefined),
    %% 从 ordered_set 尾端向前遍历并过滤，命中 Limit 条即停，避免全表加载。
    collectFiltered(Limit, Tool, Session, Since, ets:last(?TABLE), []).

%% @doc 审计统计：总条目数、按工具分组的调用次数与失败次数。
-spec stats() -> map().
stats() ->
    init(),
    %% 用 ets:foldl 直接聚合，不构造完整列表。
    ByTool = ets:foldl(fun({_Key, E}, Acc) ->
        T = maps:get(tool, E, unknown),
        Prev = maps:get(T, Acc, #{calls => 0, errors => 0}),
        IsErr = maps:get(ok, maps:get(result, E, #{}), true) =:= false,
        Acc#{T => #{
            calls => maps:get(calls, Prev) + 1,
            errors => maps:get(errors, Prev) + case IsErr of true -> 1; false -> 0 end
        }}
    end, #{}, ?TABLE),
    #{total => ets:info(?TABLE, size), byTool => ByTool}.

%% 从 ordered_set 尾端向前收集最近 N 条记录（按插入时间降序）。
collectRecent(0, _, Acc) -> lists:reverse(Acc);
collectRecent(_, '$end_of_table', Acc) -> lists:reverse(Acc);
collectRecent(N, Key, Acc) ->
    case ets:lookup(?TABLE, Key) of
        [{Key, Entry}] ->
            collectRecent(N - 1, ets:prev(?TABLE, Key), [Entry | Acc]);
        [] ->
            collectRecent(N, ets:prev(?TABLE, Key), Acc)
    end.

%% 从 ordered_set 尾端向前过滤并收集最多 Limit 条记录。
collectFiltered(0, _, _, _, _, Acc) -> lists:reverse(Acc);
collectFiltered(_, _, _, _, '$end_of_table', Acc) -> lists:reverse(Acc);
collectFiltered(N, Tool, Session, Since, Key, Acc) ->
    case ets:lookup(?TABLE, Key) of
        [{Key, Entry}] ->
            case matchField(Tool, maps:get(tool, Entry, undefined))
                 andalso matchField(Session, maps:get(sessionId, Entry, undefined))
                 andalso matchSince(Since, maps:get(at, Entry, 0)) of
                true ->
                    collectFiltered(N - 1, Tool, Session, Since, ets:prev(?TABLE, Key), [Entry | Acc]);
                false ->
                    collectFiltered(N, Tool, Session, Since, ets:prev(?TABLE, Key), Acc)
            end;
        [] ->
            collectFiltered(N, Tool, Session, Since, ets:prev(?TABLE, Key), Acc)
    end.

%% 字段匹配：undefined 表示不过滤。
matchField(undefined, _) -> true;
matchField(Want, Have) -> Want =:= Have.

%% 时间下界匹配。
matchSince(undefined, _) -> true;
matchSince(Since, At) -> At >= Since.

%% @doc 清空内存中的全部审计条目（不删除磁盘 JSONL 文件）。
%% @returns `ok`
-spec clear() -> ok.
clear() ->
    init(),
    ets:delete_all_objects(?TABLE),
    ok.

%% @doc 将单条审计记录格式化为可读字符串，用于日志或 CLI 展示。
%% @param Entry 含 tool、at、sessionId 等字段的 map
%% @returns `{string()}` 形如 `[YYYY-MM-DD HH:MM:SS] tool=... session=...`
-spec formatEntry(map()) -> string().
formatEntry(#{tool := Tool, at := At} = Entry) ->
    io_lib:format("[~s] tool=~p session=~s",
                  [formatTime(At), Tool, maps:get(sessionId, Entry, <<>>)]).

%% 将毫秒时间戳格式化为 UTC 日期时间字符串
formatTime(Ms) ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:system_time_to_universal_time(Ms, millisecond),
    io_lib:format("~4..0w-~2..0w-~2..0w ~2..0w:~2..0w:~2..0w",
                  [Y, Mo, D, H, Mi, S]).

%% 返回项目根目录下 `.al/audit.jsonl` 的绝对路径
audit_log_path() ->
    Root = alToolProject:findProjectRootFromModule(),
    filename:join(Root, ".al/audit.jsonl").