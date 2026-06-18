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
%% @returns `[map()]`
-spec list(non_neg_integer()) -> [map()].
list(Limit) ->
    init(),
    All = ets:tab2list(?TABLE),
    Sorted = lists:sort(fun({_, A}, {_, B}) ->
        maps:get(at, A, 0) >= maps:get(at, B, 0)
    end, All),
    lists:sublist([Entry || {_, Entry} <- Sorted], Limit).

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