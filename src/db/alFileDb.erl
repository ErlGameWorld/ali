%%%-------------------------------------------------------------------
%% @doc 当 Rust Core DB 不可用时的纯 Erlang 文件存储回退方案。
%%
%% 支持 memories / critique_logs / simulation_runs / sessions /
%% session_messages 五张表，以 JSONL 文件持久化。会话表始终走文件
%% 后端，避免被 Rust Core Port 串行队列阻塞。
%% @end
%%%-------------------------------------------------------------------

-module(alFileDb).

-include_lib("kernel/include/file.hrl").

-export([query/2, execute/2, insert/2, status/0]).
%% Test exports — 缓存内部辅助
-export([invalidateReadCache/0, readLines/1]).

%%--------------------------------------------------------------------
%% @doc
%% 对 JSONL 文件存储执行查询：根据 SQL 文本分类后读取并过滤对应表。
%%
%% @param Sql SQL 文本（仅根据关键字粗略识别）
%% @param Params 查询参数列表
%% @return {ok, Rows} | {error, ReasonMap}
%% @end
%%--------------------------------------------------------------------
query(Sql, Params) ->
    case classify(Sql) of
        {select, memories, like} ->
            {ok, filterMemoriesLike(readLines("memories.jsonl"), Params, like)};
        {select, memories, where} ->
            {ok, filterMemoriesWhere(readLines("memories.jsonl"), Params,
                                     memoriesWhereSpec(string:lowercase(string:trim(toList(Sql)))))};
        {select, memories, session} ->
            {ok, filterMemoriesSession(readLines("memories.jsonl"), Params)};
        {select, memories, _} ->
            {ok, readLines("memories.jsonl")};
        {select, critique_logs, _} ->
            {ok, readLines("critique_logs.jsonl")};
        {select, simulation_runs, _} ->
            {ok, readLines("simulation_runs.jsonl")};
        {select, session_messages, bySession} ->
            {ok, filterSessionMessages(readLines("session_messages.jsonl"), Params)};
        {select, session_artifacts, bySession} ->
            {ok, filterSessionArtifacts(readLines("session_artifacts.jsonl"), Params)};
        {select, sessions, byId} ->
            {ok, filterSessionById(readLines("sessions.jsonl"), Params)};
        {select, unknown, _} ->
            %% 未知表名 / 无效 SQL：返回 error 让上层能区分"空表"与"未知表"，
            %% 而非误以为查询成功但无数据。
            {error, #{reason => unknownTable, sql => Sql}};
        _ ->
            {error, #{reason => unsupportedQuery, sql => Sql}}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 执行写操作：INSERT 走 append；UPDATE sessions / DELETE session_messages
%% 也支持（会话表专用，文件后端按行重写实现）。
%%
%% @param Sql SQL 文本
%% @param Params 参数列表
%% @return {ok, Id} | {error, unsupportedQuery}
%% @end
%%--------------------------------------------------------------------
execute(Sql, Params) ->
    Lower = string:lowercase(string:trim(toList(Sql))),
    case identifySessionTable(Lower) of
        {sessions, update} ->
            {ok, updateSession(Params)};
        {sessions, delete} ->
            {ok, deleteSession(Params)};
        {sessions, insert} ->
            case hasOrIgnore(Lower) of
                true -> insertSessionOrIgnore(Params);
                false -> insert(Sql, Params)
            end;
        {session_messages, delete} ->
            {ok, deleteSessionMessages(Params)};
        {session_messages, insert} ->
            insert(Sql, Params);
        {session_artifacts, delete} ->
            {ok, deleteSessionArtifacts(Params)};
        {session_artifacts, insert} ->
            insertSessionArtifact(Params);
        _ ->
            case isMemoriesDelete(Lower, Params) of
                true ->
                    case deleteMemoryRows(Params) of
                        {error, _} = Err -> Err;
                        Removed -> {ok, Removed}
                    end;
                false ->
                    %% 用语句前缀判断，避免 INSERT ... updated_at 被误当成 UPDATE。
                    case isUpdateOrDeleteStmt(Lower) of
                        true -> {error, #{reason => unsupportedQuery, sql => Sql}};
                        false -> insert(Sql, Params)
                    end
            end
    end.

%% INSERT/UPDATE/DELETE 语句前缀判定（忽略列名里的 update/delete 子串）。
isUpdateOrDeleteStmt(Lower) ->
    string:prefix(Lower, "update") =/= nomatch
        orelse string:prefix(Lower, "delete") =/= nomatch.

hasOrIgnore(Lower) ->
    string:find(Lower, "or ignore") =/= nomatch.

%%--------------------------------------------------------------------
%% @doc
%% 向由 SQL 文本识别的表中追加一行，并返回新生成的单调自增 ID。
%%
%% @param Sql SQL 文本（用于识别目标表）
%% @param Params 插入参数列表
%% @return {ok, Id} | {error, #{reason => writeFailed, detail => Reason}}
%% @end
%%--------------------------------------------------------------------
insert(Sql, Params) ->
    Lower = string:lowercase(string:trim(toList(Sql))),
    case string:find(Lower, "metric_snapshots") =/= nomatch
         orelse string:find(Lower, "audit_archive") =/= nomatch of
        true ->
            {error, #{reason => unsupportedQuery, sql => Sql,
                      hint => <<"archive tables require rustCore SQLite">>}};
        false ->
            {File, Row} = case identifySessionTable(Lower) of
                {sessions, insert} ->
                    {"sessions.jsonl", sessionRowFromParams(Params)};
                {session_messages, insert} ->
                    {"session_messages.jsonl", sessionMessageRowFromParams(Params)};
                {session_artifacts, insert} ->
                    {"session_artifacts.jsonl", sessionArtifactRowFromParams(Params)};
                _ ->
                    Table = inferTable(Params),
                    %% JSONL 跨 BEAM 重启持久化；unique_integer 重启会重置，须叠系统时间
                    Id = persistentRowId(),
                    {Table, rowFromParams(Table, Id, Params)}
            end,
            case appendLine(File, Row) of
                ok ->
                    {ok, maps:get(id, Row, persistentRowId())};
                {error, _} = Error ->
                    Error
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 返回文件后端的状态信息（后端类型、引擎、存储路径等）。
%%
%% @return 状态映射
%% @end
%%--------------------------------------------------------------------
status() ->
    #{
        backend => file,
        engine => jsonl,
        path => storeDir(),
        enabled => true
    }.

%% 通过关键字识别 SQL 的表与查询模式（like/session/all/bySession/byId）。
%% 未知表名或无效 SQL 归类为 unknown，query/2 会对其返回空列表而非误读
%% simulation_runs 的残留数据。
classify(Sql) ->
    Lower = string:lowercase(string:trim(toList(Sql))),
    HasLike = string:find(Lower, "like") =/= nomatch,
    HasSessionId = string:find(Lower, "session_id") =/= nomatch,
    HasAnd = string:find(Lower, " and ") =/= nomatch,
    Table = condPick([
        {fun() -> string:find(Lower, "session_messages") =/= nomatch end, session_messages},
        {fun() -> string:find(Lower, "session_artifacts") =/= nomatch end, session_artifacts},
        {fun() -> string:find(Lower, "sessions") =/= nomatch end, sessions},
        {fun() -> string:find(Lower, "memories") =/= nomatch end, memories},
        {fun() -> string:find(Lower, "critique_logs") =/= nomatch end, critique_logs},
        {fun() -> string:find(Lower, "simulation_runs") =/= nomatch end, simulation_runs},
        {fun() -> true end, unknown}
    ]),
    Mode = case Table of
        session_messages -> bySession;
        session_artifacts -> bySession;
        sessions -> byId;
        memories when HasAnd -> where;   %% alMemory:list 的多条件组合过滤
        memories when HasLike -> like;   %% recall/searchTags：仅 content/tags LIKE
        memories when HasSessionId -> session;  %% recent：仅 session_id
        _ -> all
    end,
    {select, Table, Mode}.

%% 识别 memories SELECT 的过滤条件集合（用于组合过滤的参数按位解析）。
%% 返回 [session | kind | tag | like] 的有序列表，与 alMemory:listWhere/4
%% 生成的 WHERE 从左到右一致，供 applyMemoriesWhere 逐位消费参数。
%% 注意：
%% - session 用 `session_id =' 判定，避免误匹配 SELECT 列名中的 `session_id'；
%% - `tag' 与 `like' 用 `tags like'（tag 过滤，1 个参数）与 `content like'
%%   （q 过滤，2 个参数）区分；q 子句中含 `or tags like'，需排除其干扰。
memoriesWhereSpec(Lower) ->
    TagIdx = string:str(Lower, "tags like"),
    ContentIdx = string:str(Lower, "content like"),
    %% 独立 tag 过滤：`tags like` 出现在 `content like` 之前（q 子句里的
    %% `OR tags like` 在 content 之后，不得算作 tag 条件）。
    HasTag = TagIdx =/= 0 andalso (ContentIdx =:= 0 orelse TagIdx < ContentIdx),
    Spec = [
        {session, string:find(Lower, "session_id =") =/= nomatch
                  orelse string:find(Lower, "session_id=") =/= nomatch},
        {kind, string:find(Lower, "kind =") =/= nomatch
               orelse string:find(Lower, "kind=") =/= nomatch},
        {tag, HasTag},
        {like, ContentIdx =/= 0}
    ],
    [K || {K, true} <- Spec].

%% 识别会话相关 SQL 的表名与操作类型（insert/update/delete）。
identifySessionTable(Lower) ->
    IsArtifacts = string:find(Lower, "session_artifacts") =/= nomatch,
    IsSessionMessages = string:find(Lower, "session_messages") =/= nomatch,
    IsSessions = string:find(Lower, "sessions") =/= nomatch
        andalso not IsSessionMessages andalso not IsArtifacts,
    Op = condPick([
        {fun() -> string:find(Lower, "insert") =/= nomatch end, insert},
        {fun() -> string:find(Lower, "update") =/= nomatch end, update},
        {fun() -> string:find(Lower, "delete") =/= nomatch end, delete},
        {fun() -> true end, none}
    ]),
    case {IsArtifacts, IsSessionMessages, IsSessions} of
        {true, _, _} -> {session_artifacts, Op};
        {false, true, _} -> {session_messages, Op};
        {false, false, true} -> {sessions, Op};
        _ -> none
    end.

%% 条件选择器：按顺序求值 {Guard, Value}，返回第一个 Guard 为真的 Value。
condPick([{Guard, Value} | Rest]) ->
    case Guard() of
        true -> Value;
        false -> condPick(Rest)
    end;
condPick([]) -> undefined.

%% 在 memories 行中按 LIKE 模式匹配 content 或 tags，返回前 Limit 条。
%% 参数归一化：兼容 recall 的 [Pattern1, Pattern2, Limit] 与
%% searchTags 的 [Pattern1, Limit]（第二元素为整数时为上限；二进制则视为模式），
%% 以及 [Pattern1, Pattern2]（两个模式，默认上限 20）与 [Pattern1]（默认上限 20）。
filterMemoriesLike(Rows, [Pattern1, Limit], _) when is_integer(Limit) ->
    filterMemoriesLike(Rows, [Pattern1, undefined, Limit], like);
filterMemoriesLike(Rows, [Pattern1, Pattern2], _) ->
    filterMemoriesLike(Rows, [Pattern1, Pattern2, 20], like);
filterMemoriesLike(Rows, [Pattern1], _) ->
    filterMemoriesLike(Rows, [Pattern1, undefined, 20], like);
filterMemoriesLike(Rows, [Pattern1, _Pattern2, Limit], _) ->
    P1 = stripPattern(Pattern1),
    Filtered = [
        Row || Row <- Rows,
        string:find(string:lowercase(contentOf(Row)), string:lowercase(P1)) =/= nomatch
            orelse string:find(string:lowercase(tagsOf(Row)), string:lowercase(P1)) =/= nomatch
    ],
    lists:sublist(Filtered, 1, toInt(Limit)).

%% 组合过滤（kind/tag/session/q 任意组合）：与 {@link alMemory:listWhere/4}
%% 生成的 SQL/参数顺序对齐——Sid、Kind、Tag、Q（两条）、Limit。按 Spec 里
%% 各过滤条件在 SQL 中的从左到右顺序逐位消费参数，最后一位始终是 LIMIT。
filterMemoriesWhere(Rows, Params, Spec) when is_list(Params) ->
    {Filtered, Rest} = applyMemoriesWhere(Rows, Params, Spec),
    Limit = case Rest of
        [L | _] -> L;
        [] -> 20
    end,
    lists:sublist(Filtered, 1, toInt(Limit)).

applyMemoriesWhere(Rows, [P | Rest], [session | T]) ->
    applyMemoriesWhere([R || R <- Rows, sameValue(sessionIdOf(R), P)], Rest, T);
applyMemoriesWhere(Rows, [P | Rest], [kind | T]) ->
    applyMemoriesWhere([R || R <- Rows, sameValue(kindOf(R), P)], Rest, T);
applyMemoriesWhere(Rows, [P | Rest], [tag | T]) ->
    applyMemoriesWhere([R || R <- Rows, tagMatch(R, P)], Rest, T);
applyMemoriesWhere(Rows, [P1, P2 | Rest], [like | T]) ->
    applyMemoriesWhere([R || R <- Rows, likeMatch(R, P1, P2)], Rest, T);
applyMemoriesWhere(Rows, Rest, []) ->
    {Rows, Rest};
applyMemoriesWhere(Rows, Rest, _Spec) ->
    {Rows, Rest}.

%% 行内 sessionId 字段（binary/atom 双键）。
sessionIdOf(Row) -> maps:get(<<"sessionId">>, Row, maps:get(sessionId, Row, undefined)).
%% 行内 kind 字段（binary/atom 双键）。
kindOf(Row) -> maps:get(<<"kind">>, Row, maps:get(kind, Row, undefined)).
%% 兼容整数/二进制/atom/list 的值比较（非递归，避免异常输入死循环）。
sameValue(A, B) ->
    Aa = toComparable(A),
    Bb = toComparable(B),
    Aa =:= Bb orelse intBinEq(Aa, Bb).

intBinEq(A, B) when is_integer(A), is_binary(B) ->
    try A =:= binary_to_integer(B) catch _:_ -> false end;
intBinEq(A, B) when is_binary(A), is_integer(B) ->
    try B =:= binary_to_integer(A) catch _:_ -> false end;
intBinEq(_, _) ->
    false.

%% 行是否命中 content/tags 的 LIKE 模式（两个模式语义相同）。
likeMatch(Row, P1, P2) ->
    Content = string:lowercase(contentOf(Row)),
    Tags = string:lowercase(tagsOf(Row)),
    M1 = string:find(Content, string:lowercase(stripPattern(P1))) =/= nomatch
         orelse string:find(Tags, string:lowercase(stripPattern(P1))) =/= nomatch,
    M2 = string:find(Content, string:lowercase(stripPattern(P2))) =/= nomatch
         orelse string:find(Tags, string:lowercase(stripPattern(P2))) =/= nomatch,
    M1 orelse M2.

%% 行是否命中 tag JSON 子串匹配（形如 "tag"）。
tagMatch(Row, P) ->
    string:find(tagsOf(Row), stripPattern(P)) =/= nomatch.

%% 在 memories 行中按 sessionId 精确匹配，返回前 Limit 条。
filterMemoriesSession(Rows, [SessionId, Limit]) ->
    Sid = toComparable(SessionId),
    Filtered = [Row || Row <- Rows,
                       toComparable(maps:get(<<"sessionId">>, Row,
                                    maps:get(sessionId, Row, undefined))) =:= Sid],
    lists:sublist(Filtered, 1, toInt(Limit)).

toComparable(undefined) -> undefined;
toComparable(B) when is_binary(B) -> B;
toComparable(A) when is_atom(A) -> atom_to_binary(A, utf8);
toComparable(I) when is_integer(I) -> I;
toComparable(L) when is_list(L) ->
    try unicode:characters_to_binary(L) of
        Bin when is_binary(Bin) -> Bin;
        _ -> L
    catch
        _:_ -> L
    end;
toComparable(Other) -> Other.

%% 去除 LIKE 模式参数两端的 % 通配符。
stripPattern(P) ->
    string:trim(toList(P), both, "%").

%% 提取行中的 content 字段（兼容二进制与原子两种键形式）。
contentOf(Row) -> toList(maps:get(<<"content">>, Row, maps:get(content, Row, <<>>))).
%% 提取行中的 tags 字段（兼容二进制与原子两种键形式）。
tagsOf(Row) -> toList(maps:get(<<"tags">>, Row, maps:get(tags, Row, <<>>))).

%% 根据参数个数推断目标 JSONL 文件名。
%% 归档表（9/4 参数）在文件回退下无对应 schema，返回 unsupported 由调用方处理。
inferTable(Params) ->
    case length(Params) of
        9 -> "metric_snapshots.jsonl";
        8 -> "critique_logs.jsonl";
        7 -> "critique_logs.jsonl";
        5 -> "simulation_runs.jsonl";
        4 -> "audit_archive.jsonl";
        _ -> "memories.jsonl"
    end.

%% 根据目标表名和参数构造一条记录映射；不同表字段顺序不同。
rowFromParams("memories.jsonl", Id, [SessionId, Kind, Content, Tags, Metadata, CreatedAt]) ->
    #{id => Id, sessionId => SessionId, kind => Kind, content => Content,
      tags => Tags, metadata => Metadata, createdAt => CreatedAt};
rowFromParams("critique_logs.jsonl", Id, [SessionId, Question, Answer, Verdict, Score, Feedback, Round, CreatedAt]) ->
    #{id => Id, sessionId => SessionId, question => Question, answer => Answer,
      verdict => Verdict, score => Score, feedback => Feedback, round => Round, createdAt => CreatedAt};
rowFromParams("critique_logs.jsonl", Id, Params) when length(Params) =:= 7 ->
    maps:merge(#{id => Id}, maps:from_list(lists:zip(
        [sessionId, question, answer, verdict, score, feedback, createdAt], Params
    )));
rowFromParams("critique_logs.jsonl", Id, _Params) ->
    #{id => Id, error => badCritiqueParams};
rowFromParams("simulation_runs.jsonl", Id, [Type, Input, Output, Status, CreatedAt]) ->
    #{id => Id, scenarioType => Type, input => Input, output => Output,
      status => Status, createdAt => CreatedAt};
rowFromParams(_File, Id, Params) ->
    #{id => Id, params => Params}.

%% 读取指定 JSONL 文件全部行并解码为映射列表；文件不存在时返回空列表。
%% 结果按 mtime 缓存到 ETS：同一 mtime 下重复读跳过全量解析与 lowercase，
%% 对 filterMemoriesLike 等频繁读取场景显著降低 CPU。
readLines(File) ->
    Path = filename:join(storeDir(), File),
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, #file_info{mtime = Mtime}} ->
            case lookupReadCache(Path, Mtime) of
                {ok, Rows} ->
                    Rows;
                false ->
                    Rows = readLinesRaw(Path),
                    storeReadCache(Path, Mtime, Rows),
                    Rows
            end;
        {error, _} ->
            %% 文件不存在：缓存空结果，避免反复 file:read_file_info。
            case lookupReadCache(Path, undefined) of
                {ok, Rows} -> Rows;
                false ->
                    Rows = readLinesRaw(Path),
                    storeReadCache(Path, undefined, Rows),
                    Rows
            end
    end.

%% 实际读盘 + 解析；mtime 未命中或首次读取时调用。
readLinesRaw(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            Lines = binary:split(Bin, <<"\n">>, [global]),
            [decodeLine(Line) || Line <- Lines, byte_size(Line) > 0];
        {error, enoent} ->
            [];
        {error, _} ->
            []
    end.

%% 按绝对路径读取（走同一套 mtime 读缓存）；文件不存在返回 []。
readLinesAbs(Path) ->
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, #file_info{mtime = Mtime}} ->
            case lookupReadCache(Path, Mtime) of
                {ok, Rows} -> Rows;
                false ->
                    Rows = readLinesRaw(Path),
                    storeReadCache(Path, Mtime, Rows),
                    Rows
            end;
        {error, _} ->
            case lookupReadCache(Path, undefined) of
                {ok, Rows} -> Rows;
                false ->
                    Rows = readLinesRaw(Path),
                    storeReadCache(Path, undefined, Rows),
                    Rows
            end
    end.

%%%===================================================================
%%% ETS read cache (mtime invalidation)
%%%===================================================================

-define(ReadCacheTable, alFileDbReadCache).

ensureReadCacheTable() ->
    case ets:whereis(?ReadCacheTable) of
        undefined ->
            try
                ets:new(?ReadCacheTable, [named_table, set, public,
                                          {read_concurrency, true}]),
                ok
            catch
                _:_ -> ok
            end;
        _ ->
            ok
    end.

lookupReadCache(Path, Mtime) ->
    case ets:whereis(?ReadCacheTable) of
        undefined -> false;
        _ ->
            case ets:lookup(?ReadCacheTable, Path) of
                [{_, Mtime, Rows}] -> {ok, Rows};
                _ -> false
            end
    end.

storeReadCache(Path, Mtime, Rows) ->
    ensureReadCacheTable(),
    ets:insert(?ReadCacheTable, {Path, Mtime, Rows}),
    ok.

%% @doc 清空读缓存（写入新行后调用，或测试中强制刷新）。
-spec invalidateReadCache() -> ok.
invalidateReadCache() ->
    case ets:whereis(?ReadCacheTable) of
        undefined -> ok;
        _ -> ets:match_delete(?ReadCacheTable, '_'), ok
    end.

%% 将一行 JSON 编码后追加写入指定文件，必要时创建父目录。
%% 磁盘失败（目录创建失败 / 写入失败）时返回 {error, ReasonMap} 而非崩溃。
appendLine(File, Row) ->
    Path = filename:join(storeDir(), File),
    case filelib:ensure_dir(Path) of
        ok ->
            case file:write_file(Path, [alJson:encode(Row), <<"\n">>], [append]) of
                ok ->
                    invalidateReadCachePath(Path),
                    ok;
                {error, Reason} -> {error, #{reason => writeFailed, detail => Reason}}
            end;
        {error, Reason} ->
            {error, #{reason => writeFailed, detail => Reason}}
    end.

%% 失效某路径的读缓存（写入后调用，确保下次读重新解析）。
invalidateReadCachePath(Path) ->
    case ets:whereis(?ReadCacheTable) of
        undefined -> ok;
        _ -> ets:delete(?ReadCacheTable, Path), ok
    end.

%% 返回 JSONL 存储目录路径（位于 `<dataDir>/db/store` 下）。
storeDir() ->
    alConfig:dataPath("db/store").

%% 将多种类型的值转换为整数；解析失败时回退为 20。
toInt(Value) when is_integer(Value) -> Value;
toInt(Value) when is_binary(Value) ->
    try binary_to_integer(Value) catch _:_ -> 20 end;
toInt(Value) when is_list(Value) ->
    try list_to_integer(Value) catch _:_ -> 20 end;
toInt(_) -> 20.

%% 将二进制转换为列表；列表原样返回。
toList(Value) when is_list(Value) -> Value;
toList(Value) when is_binary(Value) -> unicode:characters_to_list(Value).

%% 解码单行 JSON；解析失败时记录警告并返回原始行映射。
decodeLine(Line) ->
    try alJson:decode(Line) of
        Map when is_map(Map) -> Map;
        _ -> #{raw => Line}
    catch
        _:_ ->
            logger:warning("alFileDb skipping malformed line: ~p", [Line]),
            #{raw => Line}
    end.

%%--------------------------------------------------------------------
%% 会话表（sessions / session_messages）专用辅助函数
%%--------------------------------------------------------------------

%% INSERT OR IGNORE：已存在同 id 则跳过，避免 sessions.jsonl 重复行。
insertSessionOrIgnore(Params) ->
    Row = sessionRowFromParams(Params),
    Id = maps:get(id, Row, undefined),
    case filterSessionById(readLines("sessions.jsonl"), [Id]) of
        [_ | _] ->
            {ok, 0};
        [] ->
            case appendLine("sessions.jsonl", Row) of
                ok -> {ok, maps:get(id, Row, Id)};
                {error, _} = Error -> Error
            end
    end.

%% 从 INSERT 参数构造 sessions 行：[Id, User, CreatedAt, UpdatedAt]
sessionRowFromParams([Id, User, CreatedAt, UpdatedAt]) ->
    #{id => Id, user => User, createdAt => CreatedAt, updatedAt => UpdatedAt};
sessionRowFromParams(Params) ->
    #{id => persistentRowId(), params => Params}.

%% 从 INSERT 参数构造 session_messages 行：[SessionId, Seq, Message, CreatedAt]
sessionMessageRowFromParams([SessionId, Seq, Message, CreatedAt]) ->
    #{id => persistentRowId(),
      sessionId => SessionId, seq => Seq, message => Message, createdAt => CreatedAt};
sessionMessageRowFromParams(Params) ->
    #{id => persistentRowId(), params => Params}.

%% 持久化行 ID：毫秒时间戳左移叠加进程内唯一整数，跨重启不与历史 JSONL 冲突。
persistentRowId() ->
    (erlang:system_time(millisecond) * 1000000)
        + (erlang:unique_integer([positive]) rem 1000000).

%% 从 INSERT 参数构造 session_artifacts 行。
%% Params: [SessionId, Summary, ToolTrace, Critiques, TokenUsage, Plan, UpdatedAt]
sessionArtifactRowFromParams([SessionId, Summary, ToolTrace, Critiques, TokenUsage, Plan, UpdatedAt]) ->
    #{sessionId => SessionId, summary => Summary, toolTrace => ToolTrace,
      critiques => Critiques, tokenUsage => TokenUsage, plan => Plan,
      updatedAt => UpdatedAt};
sessionArtifactRowFromParams(Params) ->
    #{sessionId => undefined, params => Params}.

%% 按 sessionId 过滤 session_artifacts，返回含 atom 键的行。
%% 优先读分片文件；分片不存在时回退旧单体文件（兼容历史数据）。
filterSessionArtifacts(Rows, [SessionId | _]) ->
    Sid = toComparable(SessionId),
    Rows1 = case {Rows, readSessionArtifactRows(SessionId)} of
        %% Rows 已由调用方传入（readLines("session_artifacts.jsonl")），
        %% 但分片命中时以分片为准。
        {_, ShardRows} when ShardRows =/= [] -> ShardRows;
        {LegacyRows, _} when is_list(LegacyRows), LegacyRows =/= [] -> LegacyRows;
        _ -> []
    end,
    [rowToAtoms(R) || R <- Rows1,
     toComparable(maps:get(<<"sessionId">>, R, maps:get(sessionId, R, undefined))) =:= Sid];
filterSessionArtifacts(_, _) ->
    [].

%% 删除 / 替换写入：INSERT OR REPLACE 语义。
%%
%% 关键优化：session_artifacts 每个 sessionId 只有一行，且写频率高
%% （每次问答收尾都会 setSummary → INSERT OR REPLACE）。旧实现是
%% 「读全文件 → 过滤 → tmp 重写 → append」，随会话数增长变成 O(n)，
%% 单次可能耗时数秒，是 agent 收尾超时崩溃的根因。
%%
%% 现改为「按 sessionId 分片」：每个会话一个独立文件
%% `session_artifacts/<sid>.jsonl`，写入直接覆盖该文件（O(1)），
%% 完全不再触碰其它会话的数据。读取时按 sid 定位分片，
%% 老的单体 `session_artifacts.jsonl` 仍兼容读取（渐进迁移）。
insertSessionArtifact(Params) ->
    Row = sessionArtifactRowFromParams(Params),
    case maps:get(sessionId, Row, undefined) of
        undefined ->
            {error, #{reason => missingSessionId}};
        Sid ->
            Path = sessionArtifactShardPath(Sid),
            case filelib:ensure_dir(Path) of
                ok ->
                    %% 单行覆盖写：无需读取、无需 rename。
                    case file:write_file(Path, [alJson:encode(Row), <<"\n">>]) of
                        ok ->
                            invalidateReadCachePath(Path),
                            {ok, Sid};
                        {error, Reason} ->
                            {error, #{reason => writeFailed, detail => Reason}}
                    end;
                {error, Reason} ->
                    {error, #{reason => writeFailed, detail => Reason}}
            end
    end.

%% 会话分片文件绝对路径：session_artifacts/<safe-sid>.jsonl
%% sid 进文件名前做安全化（仅保留字母数字与 -_），防止路径穿越。
sessionArtifactShardPath(SessionId) ->
    Safe = safeShardName(toBinarySafe(SessionId)),
    File = <<Safe/binary, ".jsonl">>,
    filename:join([storeDir(), "session_artifacts", File]).

safeShardName(Bin) when is_binary(Bin) ->
    case re:replace(Bin, <<"[^A-Za-z0-9_-]">>, <<"_">>, [global, {return, binary}]) of
        <<>> -> <<"_">>;
        Safe -> Safe
    end;
safeShardName(Other) ->
    safeShardName(toBinarySafe(Other)).

toBinarySafe(B) when is_binary(B) -> B;
toBinarySafe(A) when is_atom(A) -> atom_to_binary(A, utf8);
toBinarySafe(I) when is_integer(I) -> integer_to_binary(I);
toBinarySafe(L) when is_list(L) ->
    try unicode:characters_to_binary(L) of
        Bin when is_binary(Bin) -> Bin;
        _ -> iolist_to_binary(io_lib:format("~p", [L]))
    catch _:_ -> iolist_to_binary(io_lib:format("~p", [L])) end;
toBinarySafe(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

%% 删除 session_artifacts 中指定 sessionId 的行：分片直接删除，
%% 兼容清理旧单体文件中的历史行。
deleteSessionArtifacts([SessionId]) ->
    %% 1) 删除分片文件（新格式，O(1)）
    ShardPath = sessionArtifactShardPath(SessionId),
    ShardRemoved = case file:delete(ShardPath) of
        ok -> invalidateReadCachePath(ShardPath), 1;
        {error, _} -> 0
    end,
    %% 2) 兼容旧单体文件：若存在则按老逻辑过滤重写
    LegacyPath = filename:join(storeDir(), "session_artifacts.jsonl"),
    LegacyRemoved = case file:read_file_info(LegacyPath) of
        {ok, _} ->
            Rows = readLines("session_artifacts.jsonl"),
            Sid = toComparable(SessionId),
            Remaining = [R || R <- Rows,
                              toComparable(maps:get(<<"sessionId">>, R,
                                  maps:get(sessionId, R, undefined))) =/= Sid],
            case length(Rows) - length(Remaining) of
                0 -> 0;
                N -> _ = rewriteFile(LegacyPath, Remaining), N
            end;
        {error, _} ->
            0
    end,
    ShardRemoved + LegacyRemoved;
deleteSessionArtifacts(_) ->
    0.

%% 读取某会话的 artifacts：优先读分片文件，回退到旧单体文件。
readSessionArtifactRows(SessionId) ->
    ShardPath = sessionArtifactShardPath(SessionId),
    case readLinesAbs(ShardPath) of
        [_ | _] = Rows -> Rows;
        _ -> readLines("session_artifacts.jsonl")
    end.

%% 按 sessionId 过滤 session_messages 并按 seq 排序，返回含 atom 键的行映射。
%% JSONL 解码后键为 binary，读取时用 binary 键；返回时转为 atom 键以与
%% alLocalDb 的 Rust Core 路径（rowMapsToAtoms）保持一致。
filterSessionMessages(Rows, [SessionId | _]) ->
    Filtered = [R || R <- Rows, maps:get(<<"sessionId">>, R, undefined) =:= SessionId],
    Sorted = lists:sort(fun(A, B) -> maps:get(<<"seq">>, A, 0) =< maps:get(<<"seq">>, B, 0) end, Filtered),
    [#{message => maps:get(<<"message">>, R, <<>>)} || R <- Sorted];
filterSessionMessages(_, _) ->
    [].

%% 按 id 过滤 sessions 表，返回含 atom 键的行映射列表。
filterSessionById(Rows, [Id | _]) ->
    Want = toComparable(Id),
    [rowToAtoms(R) || R <- Rows,
     toComparable(maps:get(<<"id">>, R, maps:get(id, R, undefined))) =:= Want];
filterSessionById(_, _) ->
    [].

%% 将 JSONL 解码的 binary 键映射转为 atom 键映射（与 Rust Core 路径一致）。
rowToAtoms(R) when is_map(R) ->
    maps:from_list([
        {try binary_to_existing_atom(K, utf8) catch _:_ -> K end, V}
        || {K, V} <- maps:to_list(R), is_binary(K)
    ]);
rowToAtoms(R) ->
    R.

%% 更新 sessions：支持 [UpdatedAt, Id] 与 [UpdatedAt, User, Id]（persistSession）。
updateSession([UpdatedAt, Id]) ->
    updateSessionRows(Id, fun(R) -> R#{<<"updatedAt">> => UpdatedAt} end);
updateSession([UpdatedAt, User, Id]) ->
    updateSessionRows(Id, fun(R) ->
        R#{<<"updatedAt">> => UpdatedAt, <<"user">> => User}
    end);
updateSession(_) ->
    0.

updateSessionRows(Id, Fun) when is_function(Fun, 1) ->
    Path = filename:join(storeDir(), "sessions.jsonl"),
    Rows = readLines("sessions.jsonl"),
    Want = toComparable(Id),
    {Updated, N} = lists:mapfoldl(fun(R, Acc) ->
        case toComparable(maps:get(<<"id">>, R, maps:get(id, R, undefined))) =:= Want of
            true -> {Fun(R), Acc + 1};
            false -> {R, Acc}
        end
    end, 0, Rows),
    case N of
        0 -> 0;
        _ ->
            rewriteFile(Path, Updated),
            N
    end.

%% 删除 session_messages 中指定 sessionId 的所有行：读全部行 → 过滤 → 重写。
deleteSessionMessages([SessionId]) ->
    Path = filename:join(storeDir(), "session_messages.jsonl"),
    Rows = readLines("session_messages.jsonl"),
    Remaining = [R || R <- Rows, maps:get(<<"sessionId">>, R, undefined) =/= SessionId],
    Removed = length(Rows) - length(Remaining),
    rewriteFile(Path, Remaining),
    Removed;
deleteSessionMessages(_) ->
    0.

%% 删除 sessions 表中指定 id 的行：读全部行 → 过滤 → 重写。
deleteSession([Id]) ->
    Path = filename:join(storeDir(), "sessions.jsonl"),
    Rows = readLines("sessions.jsonl"),
    Want = toComparable(Id),
    Remaining = [R || R <- Rows,
                      toComparable(maps:get(<<"id">>, R, maps:get(id, R, undefined))) =/= Want],
    Removed = length(Rows) - length(Remaining),
    rewriteFile(Path, Remaining),
    Removed;
deleteSession(_) ->
    0.

%% 识别 memories 表的 DELETE：SQL 同时含 delete 与 memories，且单参数 id。
isMemoriesDelete(Lower, [Id]) ->
    string:find(Lower, "delete") =/= nomatch
        andalso string:find(Lower, "memories") =/= nomatch
        andalso (is_integer(Id) orelse is_binary(Id));
isMemoriesDelete(_, _) ->
    false.

%% 删除 memories 表中指定 id 的行：读全部行 → 过滤（id 兼容整数/二进制比较）→
%% 临时文件 + rename 原子重写。返回被删除的行数；写失败时返回 {error, writeFailed}
%% 让调用方感知，而不是静默报成功。
deleteMemoryRows([Id]) ->
    Path = filename:join(storeDir(), "memories.jsonl"),
    Rows = readLines("memories.jsonl"),
    Remaining = [R || R <- Rows, not sameId(memoryIdOf(R), Id)],
    Removed = length(Rows) - length(Remaining),
    case rewriteFileAtomic(Path, Remaining) of
        ok -> Removed;
        {error, _} -> {error, writeFailed}
    end;
deleteMemoryRows(_) ->
    0.

%% 提取行中的 id 字段（兼容二进制与原子两种键形式）。
memoryIdOf(Row) -> maps:get(<<"id">>, Row, maps:get(id, Row, undefined)).

%% 兼容比较两个 id：可能同为整数或同为二进制，也可能一整数一二进制。
sameId(A, B) when is_integer(A), is_integer(B) -> A =:= B;
sameId(A, B) when is_binary(A), is_binary(B) -> A =:= B;
sameId(A, B) when is_integer(A), is_binary(B) ->
    try A =:= binary_to_integer(B) catch _:_ -> false end;
sameId(A, B) when is_binary(A), is_integer(B) ->
    try B =:= binary_to_integer(A) catch _:_ -> false end;
sameId(_, _) -> false.

%% 将行列表重写为 JSONL：先写临时文件，再 rename 到目标路径实现原子替换。
%% Windows 下 file:rename 不覆盖已存在目标，rename 前先删除旧文件。
rewriteFileAtomic(Path, Rows) ->
    case filelib:ensure_dir(Path) of
        ok ->
            Tmp = Path ++ ".tmp",
            Content = [<< (alJson:encode(R))/binary, "\n">> || R <- Rows],
            case file:write_file(Tmp, Content) of
                ok ->
                    _ = file:delete(Path),
                    case file:rename(Tmp, Path) of
                        ok ->
                            invalidateReadCachePath(Path),
                            ok;
                        {error, Reason} ->
                            {error, #{reason => writeFailed, detail => Reason}}
                    end;
                {error, Reason} ->
                    {error, #{reason => writeFailed, detail => Reason}}
            end;
        {error, Reason} ->
            {error, #{reason => writeFailed, detail => Reason}}
    end.

%% 将行列表重写为 JSONL：复用 rewriteFileAtomic 的 tmp+rename 原子替换语义，
%% 写失败时返回 {error, _} 而非崩溃；调用方需校验返回值。
rewriteFile(Path, Rows) ->
    rewriteFileAtomic(Path, Rows).
