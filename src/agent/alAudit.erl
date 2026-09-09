%%%-------------------------------------------------------------------
%% @doc 审计日志：ETS ordered_set + 异步 JSONL 追加。
%%
%% 内存环形缓冲（最多 500 条，FIFO 裁剪），落盘为
%% `audit-YYYYMMDD.jsonl`。写入前经 {@link alPolicy:sanitizeTerm/1}
%% 清洗 args/results。
%% @end
%%%-------------------------------------------------------------------

-module(alAudit).

-export([log/1, list/0, list/1, clear/0, ensureStarted/0]).
%% Test exports
-export([deepRedact/1]).

-define(Table, alAudit).
-define(MaxEntries, 500).

%%--------------------------------------------------------------------
%% @doc
%% 确保审计表 ?Table 已创建。表为 public、ordered_set 类型，
%% 同时开启读/写并发优化。已存在或创建失败均返回 ok（容忍并发
%% 创建竞争）。
%%
%% @return ok
%% @end
%%--------------------------------------------------------------------
ensureStarted() ->
    case ets:whereis(?Table) of
        undefined ->
            try ets:new(?Table, [named_table, public, ordered_set,
                                 {read_concurrency, true},
                                 {write_concurrency, true}]) of
                _ -> ok
            catch _:_ -> ok end;
        _ ->
            ok
    end.

%%%===================================================================
%%% Log
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 写入一条审计日志：
%%   1. 生成单调递增的 Id 与时间戳
%%   2. 调用 sanitizeEntry 清洗敏感字段
%%   3. 插入 ETS 并按容量裁剪
%%   4. 异步追加到当日 JSONL 文件（失败仅告警，不影响主流程）
%%
%% @param Entry 审计条目（map）
%% @return ok
%% @end
%%--------------------------------------------------------------------
log(Entry) when is_map(Entry) ->
    try
        ensureStarted(),
        Id = erlang:unique_integer([positive, monotonic]),
        Now = erlang:system_time(millisecond),
        Sanitized = sanitizeEntry(Entry),
        FullEntry = Sanitized#{id => Id, at => Now},
        ets:insert(?Table, {Id, FullEntry}),
        trim(),
        _ = appendJsonlSafe(FullEntry),
        ok
    catch
        C:R ->
            logger:warning("audit log failed: ~p:~p", [C, R]),
            ok
    end.

%% 安全包装：捕获 appendJsonl 的异常并告警，保证审计写入不会
%% 因磁盘 IO 异常而影响调用方。
appendJsonlSafe(Entry) ->
    try appendJsonl(Entry)
    catch C:R ->
        logger:warning("audit jsonl append failed: ~p:~p", [C, R]),
        ok
    end.

%% 调用 alPolicy:sanitizeTerm/1 清洗 Entry 中的 args 与 result
%% 字段，防止敏感信息落盘或入内存表。在 sanitizeTerm 基础上额外
%% 对字符串叶子节点做 content 级 redact（URL 凭据、key=、私钥块、
%% 长数字串）。
sanitizeEntry(Entry) ->
    SafeArgs = sanitizeTermDeep(maps:get(args, Entry, #{})),
    SafeResult = sanitizeTermDeep(maps:get(result, Entry, #{})),
    Entry#{args => SafeArgs, result => SafeResult}.

%%--------------------------------------------------------------------
%% @doc
%% 深度 sanitize：在 alPolicy:sanitizeTerm 基础上，对 map/list
%% 中的 string/binary 叶子节点做正则 redact。
%%--------------------------------------------------------------------
sanitizeTermDeep(Term) ->
    alPolicy:sanitizeTerm(deepRedact(Term)).

%%--------------------------------------------------------------------
%% @doc
%% 递归遍历 term，对 binary/list 中的可打印字符串做 redact：
%%   - URL 凭据：scheme://user:pass@host → scheme://<<REDACTED>>@host
%%   - 凭据 assignment：apiKey=xxx / token: xxx / password "xxx"
%%   - 私钥块：-----BEGIN ... PRIVATE KEY----- 整段替换
%%   - 长数字串（>12 位）保留前 4 + 后 4
%%--------------------------------------------------------------------
deepRedact(Bin) when is_binary(Bin) ->
    redactStringDeep(Bin);
deepRedact(L) when is_list(L) ->
    case io_lib:char_list(L) of
        %% A charlist may contain Unicode code points above 255.
        %% iolist_to_binary/1 only accepts bytes and crashes for paths
        %% such as "项目说明.md"; encode charlists as UTF-8 instead.
        true -> redactStringDeep(unicode:characters_to_binary(L));
        false -> [deepRedact(I) || I <- L]
    end;
deepRedact(M) when is_map(M) ->
    maps:from_list([{K, deepRedact(V)} || {K, V} <- maps:to_list(M)]);
deepRedact(T) when is_tuple(T) ->
    %% Never fold tuple_to_list through the charlist branch — integer
    %% tuples like timestamps become binaries and list_to_tuple/1 crashes.
    list_to_tuple([deepRedact(I) || I <- tuple_to_list(T)]);
deepRedact(Other) ->
    Other.

redactStringDeep(Bin) ->
    Bin1 = redactUrlCreds(Bin),
    Bin2 = redactKeyAssignments(Bin1),
    Bin3 = redactPrivateKey(Bin2),
    redactLongDigits(Bin3).

redactUrlCreds(Bin) ->
    Re = <<"([a-zA-Z][a-zA-Z0-9+.-]+://)([^/@\\s]+)@">>,
    re:replace(Bin, Re, <<"\\1<<REDACTED>>@">>, [global, {return, binary}]).

redactKeyAssignments(Bin) ->
    Keys = [<<"apiKey">>, <<"api_key">>, <<"token">>, <<"password">>, <<"secret">>,
            <<"accessToken">>, <<"access_token">>, <<"clientSecret">>, <<"client_secret">>,
            <<"privateKey">>, <<"private_key">>, <<"auth">>, <<"bearer">>],
    lists:foldl(fun(K, Acc) ->
        Re = <<"(?i)(", K/binary, ")\\s*[:=]\\s*([\"']?)([^\"'\\s,&]+)\\2">>,
        re:replace(Acc, Re, <<"\\1=\\2<<REDACTED>>\\2">>, [global, {return, binary}])
    end, Bin, Keys).

redactPrivateKey(Bin) ->
    Re = <<"(-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----)">>,
    re:replace(Bin, Re, <<"<<REDACTED-PRIVATE-KEY>>">>, [global, {return, binary}]).

%% 屏蔽长数字（前 4 + 后 4，中间 REDACTED）。
redactLongDigits(Bin) ->
    Re = <<"\\b(\\d{4})\\d{4,}(\\d{4})\\b">>,
    re:replace(Bin, Re, <<"\\1<<REDACTED-DIGITS>>\\2">>, [global, {return, binary}]).

%%--------------------------------------------------------------------
%% @doc
%% 内存环形缓冲裁剪：当 ETS 大小超过 ?MaxEntries（500）时，
%% 删除最早的 Excess 条记录（ordered_set 的 first 即最旧）。
%%
%% @return ok
%% @end
%%--------------------------------------------------------------------
trim() ->
    %% 并行 worker 场景：建表的 worker 退出会带走表（eunit 无 alEtsOwner 时），
    %% ets:info 对已消失的表返回 undefined——直接跳过裁剪，不让审计主流程炸。
    case ets:info(?Table, size) of
        Size when is_integer(Size), Size > ?MaxEntries ->
            trimOldest(Size - ?MaxEntries);
        _ ->
            ok
    end.

%% 递归删除最早 N 条记录：每次取 ordered_set 的 first 删除，
%% 直到计数归零或表空。
trimOldest(0) -> ok;
trimOldest(N) ->
    case ets:first(?Table) of
        '$end_of_table' -> ok;
        Key ->
            ets:delete(?Table, Key),
            trimOldest(N - 1)
    end.

%%%===================================================================
%%% List
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 列出最近的审计条目（默认上限 ?MaxEntries 条）。
%%
%% @return Entry 列表（按时间倒序）
%% @end
%%--------------------------------------------------------------------
list() ->
    list(?MaxEntries).

%%--------------------------------------------------------------------
%% @doc
%% 列出最近 Limit 条审计条目，按时间倒序返回。从 ordered_set 的
%% last（最新）开始向前遍历。
%%
%% @param Limit 最大返回条数（非负整数）
%% @return Entry 列表
%% @end
%%--------------------------------------------------------------------
list(Limit) when is_integer(Limit), Limit >= 0 ->
    ensureStarted(),
    collectLatest(Limit, ets:last(?Table), []).

%% 递归收集：已收集 Limit 条或表遍历完毕时终止。
%% 从 last 向前扫时用 prepend 得到旧→新；出口再 reverse 成新→旧（倒序）。
collectLatest(0, _Key, Acc) -> lists:reverse(Acc);
collectLatest(_N, '$end_of_table', Acc) -> lists:reverse(Acc);
collectLatest(N, Key, Acc) ->
    case ets:lookup(?Table, Key) of
        [{_, Entry} | _] ->
            Next = ets:prev(?Table, Key),
            collectLatest(N - 1, Next, [Entry | Acc]);
        [] ->
            lists:reverse(Acc)
    end.

%%%===================================================================
%%% Clear
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 清空内存中的所有审计条目（不影响已落盘的 JSONL 文件）。
%%
%% @return ok
%% @end
%%--------------------------------------------------------------------
clear() ->
    ensureStarted(),
    ets:delete_all_objects(?Table),
    ok.

%%%===================================================================
%%% JSONL persistence
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 把单条审计 Entry 以 JSONL 格式追加写入当日审计文件
%% （audit-YYYYMMDD.jsonl）。使用 [append, raw] 提升追加性能。
%%
%% @param Entry 审计条目
%% @return ok
%% @end
%%--------------------------------------------------------------------
appendJsonl(Entry) ->
    Path = auditLogPath(),
    Line = [alJson:encode(Entry), $\n],
    case file:write_file(Path, Line, [append, raw]) of
        ok ->
            ok;
        {error, Reason} ->
            logger:warning("audit jsonl append failed for ~p: ~p", [Path, Reason]),
            {error, Reason}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 计算当日审计文件路径：先确保目录存在，再按当前日期生成
%% 文件名 audit-YYYYMMDD.jsonl。
%%
%% @return 文件路径（string）
%% @end
%%--------------------------------------------------------------------
auditLogPath() ->
    Dir = auditDir(),
    ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
    Date = dateSuffix(erlang:system_time(millisecond)),
    filename:join(Dir, "audit-" ++ Date ++ ".jsonl").

%%--------------------------------------------------------------------
%% @doc
%% 读取审计目录配置：alConfig 中的 auditDir，未配置时默认 `<dataDir>/audit`。
%%
%% @return 目录路径（string）
%% @end
%%--------------------------------------------------------------------
auditDir() ->
    case alConfig:get(auditDir, undefined) of
        undefined -> alConfig:dataPath("audit");
        Dir ->
            case filename:pathtype(toList(Dir)) of
                relative -> alConfig:resolvePath(alConfig:root(), Dir);
                _ -> filename:absname(toList(Dir))
            end
    end.

toList(V) when is_list(V) -> V;
toList(V) when is_binary(V) -> unicode:characters_to_list(V);
toList(V) -> lists:flatten(io_lib:format("~p", [V])).

%%--------------------------------------------------------------------
%% @doc
%% 由毫秒时间戳生成 YYYYMMDD 日期后缀，用作审计文件名分段。
%%
%% @param Ms 毫秒时间戳
%% @return 8 位日期字符串（如 "20260705"）
%% @end
%%--------------------------------------------------------------------
dateSuffix(Ms) ->
    DateTime = calendar:system_time_to_universal_time(Ms, millisecond),
    {{Y, M, D}, _} = DateTime,
    lists:flatten(io_lib:format("~4..0B~2..0B~2..0B", [Y, M, D])).
