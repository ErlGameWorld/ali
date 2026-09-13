%%%-------------------------------------------------------------------
%% @doc 长期记忆：SQLite 为权威数据源。
%%
%% 向量索引（Qdrant 或经 aliCore 的本地 embedding 存储）是可重建缓存。
%% 清空向量或迁移 embedding 模型后用 {@link rebuildIndex/0}。
%% 关键词 {@link recall/2} 从不依赖向量层。
%% @end
%%%-------------------------------------------------------------------

-module(alMemory).

-compile({no_auto_import, [get/1]}).

%% 实体图：每条记忆最多提取的实体数（模块/MFA/文件）。
-define(MaxEntitiesPerMemory, 8).

-export([
    remember/3, remember/4,
    recall/1, recall/2,
    recallSemantic/1, recallSemantic/2,
    recent/2, list/0, list/1, searchTags/1,
    distill/1, distill/2,
    relevantFor/1, relevantFor/2,
    forget/1,
    get/1,
    markSuperseded/2,
    patchMetadata/2,
    userProfile/0, userProfile/1,
    rebuildIndex/0, rebuildIndex/1
]).
%% Test exports — pure helpers
-export([normalizeRow/1, decodeJson/1, toBinary/1, toList/1, timeDecay/2, rowField/4,
         conversationSummary/1, normalizeScope/1, scopeOf/1, filterByScope/2,
         extractEntities/1, entitiesOf/1, expandByEntities/3,
         clampImportance/1, importanceOf/1, finalScore/3, isSuperseded/1,
         filterSuperseded/1]).
%%--------------------------------------------------------------------
%% @doc
%% 记忆写入的简化入口：使用空选项调用三参数版本。
%%
%% @param SessionId 会话 ID
%% @param Kind 记忆类型（如 note/preference/fact）
%% @param Content 记忆内容
%% @return {@link remember/4} 的返回值
%% @end
%%--------------------------------------------------------------------
remember(SessionId, Kind, Content) ->
    remember(SessionId, Kind, Content, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 将一条记忆写入本地 SQLite 数据库，并在 core 服务可用时异步建立索引。
%%
%% @param SessionId 会话 ID
%% @param Kind 记忆类型
%% @param Content 记忆内容
%% @param Opts 选项 map，支持 tags（标签列表）与 metadata（元数据 map）
%% @return `{ok, #{id => Id, sessionId => SessionId, kind => Kind}}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
remember(SessionId, Kind, Content, Opts) when is_map(Opts) ->
    Tags = maps:get(tags, Opts, []),
    Scope = normalizeScope(maps:get(scope, Opts,
                maps:get(<<"scope">>, Opts, project))),
    Metadata0 = maps:get(metadata, Opts, #{}),
    %% 实体图：写入时自动提取实体（模块/MFA/文件）存入 metadata.entities，
    %% 供召回时 1-hop 扩展。显式提供 entities 时尊重调用方。
    Metadata1 = case is_map(Metadata0)
                    andalso maps:is_key(entities, Metadata0) of
        true -> Metadata0;
        false ->
            Entities = extractEntities(Content),
            case is_map(Metadata0) of
                true when Entities =/= [] -> Metadata0#{entities => Entities};
                true -> Metadata0;
                false when Entities =/= [] -> #{entities => Entities};
                false -> #{}
            end
    end,
    Metadata = case is_map(Metadata1) of
        true -> Metadata1#{scope => Scope};
        false -> #{scope => Scope}
    end,
    Sql =
        "INSERT INTO memories (session_id, kind, content, tags, metadata, created_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
    Params = [
        SessionId,
        toBinary(Kind),
        toBinary(Content),
        alJson:encode(Tags),
        alJson:encode(Metadata),
        erlang:system_time(second)
    ],
    case alLocalDb:insert(Sql, Params) of
        {ok, Id} ->
            _ = maybeIndexMemory(Id, Content),
            {ok, #{id => Id, sessionId => SessionId, kind => Kind, scope => Scope}};
        Error ->
            Error
    end.

normalizeScope(user) -> user;
normalizeScope(project) -> project;
normalizeScope(session) -> session;
normalizeScope(<<"user">>) -> user;
normalizeScope(<<"project">>) -> project;
normalizeScope(<<"session">>) -> session;
normalizeScope("user") -> user;
normalizeScope("project") -> project;
normalizeScope("session") -> session;
normalizeScope(_) -> project.

%%--------------------------------------------------------------------
%% @doc
%% 关键词召回的简化入口：使用默认上限 20 调用 {@link recall/2}。
%%
%% @param Query 查询字符串
%% @return {@link recall/2} 的返回值
%% @end
%%--------------------------------------------------------------------
recall(Query) ->
    recall(Query, 20).

%%--------------------------------------------------------------------
%% @doc
%% 语义召回的简化入口：使用默认上限 10 调用 {@link recallSemantic/2}。
%%
%% @param Query 查询字符串
%% @return {@link recallSemantic/2} 的返回值
%% @end
%%--------------------------------------------------------------------
recallSemantic(Query) ->
    recallSemantic(Query, 10).

%%--------------------------------------------------------------------
%% @doc
%% 语义召回：当 core 服务可用时优先调用语义检索，否则降级为关键词召回。
%%
%% 命中时按返回的 ID 批量查询本地数据库，并附加 `semanticScore' 字段。
%%
%% @param Query 查询字符串
%% @param Limit 返回结果上限
%% @return `{ok, [Row]}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
recallSemantic(Query, Limit) ->
    case alCoreClient:memorySearch(Query, Limit) of
        {ok, #{data := #{hits := Hits}}} when Hits =/= [] ->
            Ids = [maps:get(id, H) || H <- Hits, is_integer(maps:get(id, H, undefined))],
            fetchMemoriesByIds(Ids, Hits);
        _ ->
            %% 语义检索无结果时降级为关键词召回
            recall(Query, Limit)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 根据语义检索返回的 ID 列表批量查询本地记忆，并将 score 注入到结果行。
%%
%% @param Ids 记忆 ID 列表
%% @param Hits core 服务返回的命中列表（包含 id 和 score）
%% @return `{ok, [Row]}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
fetchMemoriesByIds([], _Hits) ->
    {ok, []};
fetchMemoriesByIds(Ids, Hits) ->
    Placeholders = string:join(lists:duplicate(length(Ids), "?"), ", "),
    Sql = "SELECT id, session_id, kind, content, tags, metadata, created_at "
          "FROM memories WHERE id IN (" ++ Placeholders ++ ")",
    case alLocalDb:query(Sql, Ids) of
        {ok, Rows} ->
            ScoreById = maps:from_list([{maps:get(id, H), maps:get(score, H, 0.0)} || H <- Hits]),
            Now = erlang:system_time(second),
            Scored = [begin
                Row1 = normalizeRow(Row),
                SemScore = maps:get(rowField(Row, <<"id">>, id, undefined), ScoreById, 0.0),
                CreatedAt = rowField(Row1, <<"created_at">>, createdAt, Now),
                Decay = timeDecay(CreatedAt, Now),
                DecayedScore = finalScore(SemScore, Row1, Now),
                Row1#{semanticScore => SemScore,
                      decayFactor => Decay,
                      score => DecayedScore}
            end || Row <- Rows],
            %% 按衰减后分数降序排列，让近期且相关的记忆排在前面。
            Sorted = lists:sort(fun(A, B) ->
                maps:get(score, A, 0.0) >= maps:get(score, B, 0.0)
            end, Scored),
            {ok, filterSuperseded(Sorted)};
        Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% @doc
%% 时间衰减因子：基于记忆创建时间到当前的年龄计算。
%% 使用指数衰减，半衰期 30 天：新记忆因子 1.0，30 天前 0.68，90 天前 0.55。
%% 这让近期记忆获得更高权重，但不会完全压制旧记忆（保留长期知识）。
%%
%% @param CreatedAt 创建时间（Unix 秒）
%% @param Now 当前时间（Unix 秒）
%% @return 0.5..1.0 的浮点衰减因子
%% @end
%%--------------------------------------------------------------------
timeDecay(CreatedAt, Now) when is_integer(CreatedAt), is_integer(Now), Now >= CreatedAt ->
    AgeDays = (Now - CreatedAt) / 86400.0,
    HalfLifeDays = 30.0,
    0.5 + 0.5 * math:exp(-AgeDays / HalfLifeDays);
timeDecay(_, _) ->
    0.5.

%%--------------------------------------------------------------------
%% @doc
%% 从记忆内容提取实体（记忆实体图的节点）：
%% <ul>
%%   <li>MFA：`mod:fun/arity' 或 `mod:fun'（含定义/调用锚点）</li>
%%   <li>模块名：`al*' / `ali*' 前缀驼峰命名（本项目约定）</li>
%%   <li>文件路径：`*.erl' / `*.rs' / `*.cfg' / `*.sql'</li>
%% </ul>
%% 最多 {@link ?MaxEntitiesPerMemory} 个，按出现顺序去重。
%%
%% @param Content 记忆内容（binary/list）
%% @return 实体 binary 列表
%% @end
%%--------------------------------------------------------------------
extractEntities(Content) ->
    Bin = toBinary(Content),
    %% MFA 整体（mod:fun/arity 或 mod:fun）作为图节点，模块名单独入图。
    Mfas = matchEntities(Bin, <<"([a-z][a-zA-Z0-9_]*):([a-z][a-zA-Z0-9_]*)"
                                "(?:/[0-9]+)?">>),
    MfaMods = [hd(binary:split(Part, <<":">>)) || Part <- Mfas],
    Mods = matchEntities(Bin, <<"(?:al|ali)[A-Z][a-zA-Z0-9_]*">>),
    Files = matchEntities(Bin, <<"[a-zA-Z0-9_./\\-]+\\.(?:erl|hrl|rs|cfg|sql|toml)">>),
    lists:sublist(
        lists:usort([E || E <- Mfas ++ MfaMods ++ Mods ++ Files, byte_size(E) >= 4]),
        ?MaxEntitiesPerMemory).

matchEntities(Bin, Pattern) ->
    case re:run(Bin, Pattern, [global, {capture, first, binary}]) of
        {match, Captures} -> [C || [C] <- Captures, C =/= <<>>];
        nomatch -> []
    end.

%%--------------------------------------------------------------------
%% @doc
%% 读取记忆行的实体集合：优先 metadata.entities（写入时提取），
%% 缺失时对内容现场提取（兼容历史数据）。
%%
%% @param Row 记忆行（含 content/metadata）
%% @return 实体 binary 集合（sets）
%% @end
%%--------------------------------------------------------------------
entitiesOf(Row) when is_map(Row) ->
    Meta = maps:get(metadata, Row, maps:get(<<"metadata">>, Row, #{})),
    Stored = case is_map(Meta) of
        true ->
            lists:filtermap(fun
                (E) when is_binary(E), byte_size(E) >= 3 -> {true, E};
                (E) when is_list(E) -> {true, unicode:characters_to_binary(E)};
                (_) -> false
            end, lists:sublist(
                    lists:usort(toList(maps:get(entities, Meta,
                                                maps:get(<<"entities">>, Meta, [])))),
                    ?MaxEntitiesPerMemory));
        false ->
            []
    end,
    case Stored of
        [] ->
            sets:from_list(extractEntities(
                maps:get(content, Row, maps:get(<<"content">>, Row, <<>>))), [{version, 2}]);
        _ ->
            sets:from_list(Stored, [{version, 2}])
    end;
entitiesOf(_) ->
    sets:new([{version, 2}]).

%%--------------------------------------------------------------------
%% @doc
%% 实体图 1-hop 扩展（纯函数）：从候选池中选出与已命中行共享 ≥1 实体、
%% 且不在已命中集合中的记忆，按「共享实体数 × 时间衰减」降序补充最多
%% Budget 条。命中行的内容不重复扩展（同一 content 视为已命中）。
%%
%% @param Hits 语义召回命中的行列表
%% @param Pool 候选记忆池（近期记忆）
%% @param Budget 最多补充条数
%% @return `Hits ++ Expanded'（扩展行带 entityExpanded => true 标记）
%% @end
%%--------------------------------------------------------------------
expandByEntities(Hits, Pool, Budget) when is_list(Hits), is_list(Pool), Budget > 0 ->
    HitEntities = lists:foldl(fun(Row, Acc) ->
        sets:union(entitiesOf(Row), Acc)
    end, sets:new([{version, 2}]), Hits),
    HitContents = sets:from_list(
        [maps:get(content, R, maps:get(<<"content">>, R, <<>>)) || R <- Hits],
        [{version, 2}]),
    HitIds = sets:from_list(
        [maps:get(id, R, maps:get(<<"id">>, R, undefined)) || R <- Hits],
        [{version, 2}]),
    Now = erlang:system_time(second),
    Scored = lists:filtermap(fun(Row) ->
        Id = maps:get(id, Row, maps:get(<<"id">>, Row, undefined)),
        Content = maps:get(content, Row, maps:get(<<"content">>, Row, <<>>)),
        case sets:is_element(Content, HitContents)
             orelse sets:is_element(Id, HitIds) of
            true ->
                false;
            false ->
                Entities = entitiesOf(Row),
                Shared = sets:size(sets:intersection(HitEntities, Entities)),
                case Shared of
                    0 -> false;
                    _ ->
                        Created = rowField(Row, <<"created_at">>, created_at, Now),
                        Score = Shared * timeDecay(Created, Now),
                        {true, {Score, Shared, Row}}
                end
        end
    end, Pool),
    Sorted = lists:sort(fun({SA, _, _}, {SB, _, _}) -> SA >= SB end, Scored),
    Expanded = [Row#{entityExpanded => true, sharedEntities => Shared}
                || {_, Shared, Row} <- lists:sublist(Sorted, Budget)],
    Hits ++ Expanded;
expandByEntities(Hits, _Pool, _Budget) when is_list(Hits) ->
    Hits;
expandByEntities(_Hits, _, _) ->
    [].

%%--------------------------------------------------------------------
%% @doc
%% 双键读取行字段：先读 binary 键（JSONL 解码 / Rust 原始返回的形式），
%% 再读 atom 键（Rust Core 经 rowMapsToAtoms 归一化后的形式），
%% 两者都缺失时返回 Default。
%%
%% @param Row 行映射
%% @param BinaryKey binary 形式的键（如 `<<"created_at">>'）
%% @param AtomKey atom 形式的键（如 `createdAt'）
%% @param Default 缺失时的默认值
%% @return 字段值
%% @end
%%--------------------------------------------------------------------
rowField(Row, BinaryKey, AtomKey, Default) ->
    maps:get(BinaryKey, Row, maps:get(AtomKey, Row, Default)).

%%--------------------------------------------------------------------
%% @doc
%% 在 core 服务可用时异步向其提交记忆内容以建立向量索引。
%%
%% 失败被视为非致命错误：本地 SQLite 记忆仍可用。索引在独立进程中进行，
%% 不会阻塞调用方。
%%
%% @param Id 记忆 ID
%% @param Content 记忆内容
%% @return `ok'
%% @end
%%--------------------------------------------------------------------
maybeIndexMemory(Id, Content) ->
    _ = alAsync:run(memoryIndex, fun() ->
        case alCoreClient:memoryUpsert(Id, Content) of
            {ok, #{data := #{ok := true}}} ->
                ok;
            {ok, #{data := Data}} ->
                case maps:get(ok, Data, false) of
                    true -> ok;
                    false -> logger:debug("memory index skipped: ~p", [maps:get(reason, Data, unknown)])
                end;
            {error, #{kind := <<"core_error">>, message := Msg} = Reason} ->
                logger:debug("memory index skipped: ~ts (~p)", [Msg, Reason]);
            {error, Reason} ->
                logger:debug("memory index skipped: ~p", [Reason])
        end
    end),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% 关键词召回：使用 `LIKE %query%' 模式在 content 与 tags 列上模糊匹配，
%% 按创建时间倒序返回。
%%
%% @param Query 查询字符串
%% @param Limit 返回上限
%% @return `{ok, [Row]}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
recall(Query, Limit) when is_integer(Limit) ->
    recall(Query, #{limit => Limit});
recall(Query, Opts) when is_map(Opts) ->
    Limit = maps:get(limit, Opts, 20),
    Scope = maps:get(scope, Opts, undefined),
    Escaped = escapeLike(toList(Query)),
    Pattern = "%" ++ Escaped ++ "%",
    Sql =
        "SELECT id, session_id, kind, content, tags, metadata, created_at "
        "FROM memories WHERE content LIKE ? ESCAPE '\\' OR tags LIKE ? ESCAPE '\\' "
        "ORDER BY created_at DESC LIMIT ?",
    FetchLimit = case Scope of
        undefined -> Limit;
        _ -> max(Limit * 3, Limit)
    end,
    case alLocalDb:query(Sql, [Pattern, Pattern, FetchLimit]) of
        {ok, Rows} ->
            Norm = filterSuperseded([normalizeRow(Row) || Row <- Rows]),
            {ok, lists:sublist(filterByScope(Norm, Scope), Limit)};
        Error ->
            Error
    end.

%% 转义 LIKE 通配符 % 和 _ 以及转义符 \
escapeLike(Str) ->
    lists:flatmap(fun(C) ->
        case C of
            $% -> [$\\, $%];
            $_ -> [$\\, $_];
            $\\ -> [$\\, $\\];
            _ -> [C]
        end
    end, Str).

%%--------------------------------------------------------------------
%% @doc
%% 查询某个会话最近的若干条记忆，按创建时间倒序返回。
%%
%% @param SessionId 会话 ID
%% @param Limit 返回上限
%% @return `{ok, [Row]}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
recent(SessionId, Limit) ->
    Sql =
        "SELECT id, session_id, kind, content, tags, metadata, created_at "
        "FROM memories WHERE session_id = ? ORDER BY created_at DESC LIMIT ?",
    case alLocalDb:query(Sql, [SessionId, Limit]) of
        {ok, Rows} ->
            {ok, filterSuperseded([normalizeRow(Row) || Row <- Rows])};
        Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% @doc 列出最近记忆（默认 50 条）。
%% @end
%%--------------------------------------------------------------------
-spec list() -> {ok, [map()]} | {error, term()}.
list() ->
    list(#{}).

%%--------------------------------------------------------------------
%% @doc
%% 列出/筛选长期记忆。Opts：
%% - `limit`（默认 50，最大 200）
%% - `kind`：精确匹配 kind
%% - `tag`：tags JSON 中包含该标签（如 distilled）
%% - `q`：content / tags 关键词 LIKE
%% - `sessionId`：按会话过滤
%% @end
%%--------------------------------------------------------------------
-spec list(map()) -> {ok, [map()]} | {error, term()}.
list(Opts) when is_map(Opts) ->
    Limit0 = maps:get(limit, Opts, maps:get(<<"limit">>, Opts, 50)),
    Limit = max(1, min(toIntOr(Limit0, 50), 200)),
    Kind = emptyToUndef(maps:get(kind, Opts, maps:get(<<"kind">>, Opts, undefined))),
    Tag = emptyToUndef(maps:get(tag, Opts, maps:get(<<"tag">>, Opts, undefined))),
    Q = emptyToUndef(maps:get(q, Opts, maps:get(<<"q">>, Opts, undefined))),
    Sid = emptyToUndef(maps:get(sessionId, Opts, maps:get(<<"sessionId">>, Opts, undefined))),
    {Where, Params0} = listWhere(Kind, Tag, Q, Sid),
    Sql = "SELECT id, session_id, kind, content, tags, metadata, created_at "
          "FROM memories" ++ Where ++ " ORDER BY created_at DESC LIMIT ?",
    case alLocalDb:query(Sql, Params0 ++ [Limit]) of
        {ok, Rows} ->
            {ok, filterSuperseded([normalizeRow(Row) || Row <- Rows])};
        Error ->
            Error
    end.

listWhere(Kind, Tag, Q, Sid) ->
    Clauses0 = [],
    Params0 = [],
    {C1, P1} = case Sid of
        undefined -> {Clauses0, Params0};
        _ -> {["session_id = ?" | Clauses0], [Sid | Params0]}
    end,
    {C2, P2} = case Kind of
        undefined -> {C1, P1};
        _ -> {["kind = ?" | C1], [toBinary(Kind) | P1]}
    end,
    {C3, P3} = case Tag of
        undefined -> {C2, P2};
        _ ->
            Pat = "%\"" ++ escapeLike(toList(toBinary(Tag))) ++ "\"%",
            {["tags LIKE ? ESCAPE '\\'" | C2], [Pat | P2]}
    end,
    {C4, P4} = case Q of
        undefined -> {C3, P3};
        _ ->
            PatQ = "%" ++ escapeLike(toList(toBinary(Q))) ++ "%",
            {["(content LIKE ? ESCAPE '\\' OR tags LIKE ? ESCAPE '\\')" | C3],
             [PatQ, PatQ | P3]}
    end,
    case lists:reverse(C4) of
        [] -> {"", lists:reverse(P4)};
        Cs -> {" WHERE " ++ string:join(Cs, " AND "), lists:reverse(P4)}
    end.

emptyToUndef(<<>>) -> undefined;
emptyToUndef("") -> undefined;
emptyToUndef(undefined) -> undefined;
emptyToUndef(null) -> undefined;
emptyToUndef(<<"undefined">>) -> undefined;
emptyToUndef(V) -> V.

toIntOr(N, _) when is_integer(N), N > 0 -> N;
toIntOr(B, Default) when is_binary(B) ->
    try binary_to_integer(B) catch _:_ -> Default end;
toIntOr(L, Default) when is_list(L) ->
    try list_to_integer(L) catch _:_ -> Default end;
toIntOr(_, Default) -> Default.

%%--------------------------------------------------------------------
%% @doc
%% 按标签搜索记忆：在 tags 列中匹配形如 `"tag"' 的 JSON 字符串。
%%
%% @param Tag 标签（atom/binary/list 均可）
%% @return `{ok, [Row]}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
searchTags(Tag) ->
    list(#{tag => Tag, limit => 20}).

%%--------------------------------------------------------------------
%% @doc
%% 蒸馏入口（多子句）：
%%  - 传入消息列表时，直接基于该列表蒸馏
%%  - 传入 SessionId 时，从会话上下文加载消息后蒸馏
%%
%% @param Messages 消息列表，或 SessionId 会话 ID
%% @return {@link distill/2} 的返回值
%% @end
%%--------------------------------------------------------------------
distill(Messages) when is_list(Messages) ->
    distill(undefined, #{messages => Messages});
distill(SessionId) when is_integer(SessionId); is_binary(SessionId) ->
    distill(SessionId, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 从对话内容中蒸馏出持久化的事实条目并保存到记忆库。
%%
%% 流程：将消息打包成对话摘要 → 调用 LLM 提取事实 → 逐条保存。
%%
%% @param Input 会话 ID 或 `undefined'
%% @param Opts 选项 map，可包含 `messages' 直接传入消息
%% @return `{ok, [SavedItem]}' | `{ok, []}' 当无消息时
%% @end
%%--------------------------------------------------------------------
distill(Input, Opts) when is_map(Opts) ->
    Sid = sessionIdFrom(Input),
    Messages = case maps:get(messages, Opts, undefined) of
        undefined ->
            case Sid of
                undefined -> [];
                _ ->
                    case alSessionMgr:getContext(Sid) of
                        {ok, #{messages := Msgs}} -> Msgs;
                        _ -> []
                    end
            end;
        Msgs ->
            Msgs
    end,
    case Messages of
        [] ->
            {ok, []};
        _ ->
            Summary = conversationSummary(Messages),
            Items = extractMemoryItems(Summary, Opts),
            Saved = [maybeSaveDistilled(Sid, Item) || Item <- Items],
            {ok, lists:filtermap(fun
                ({ok, R}) -> {true, R};
                (_) -> false
            end, Saved)}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 相关性召回的简化入口：使用默认上限 8 调用 {@link relevantFor/2}。
%%
%% @param Query 查询字符串
%% @return {@link relevantFor/2} 的返回值
%% @end
%%--------------------------------------------------------------------
relevantFor(Query) ->
    relevantFor(Query, 8).

%%--------------------------------------------------------------------
%% @doc
%% 相关性召回：语义召回 + 内容去重 + MMR 多样性重排，
%% 再沿实体图做 1-hop 扩展（命中记忆的关联实体，补充向量分数
%% 不高但实体强相关的记忆，如同一模块的历史教训）。
%%
%% @param Query 查询字符串
%% @param Limit 返回上限
%% @return `{ok, [Row]}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
relevantFor(Query, Limit) ->
    %% 召回更多候选（2x），然后做内容去重 + MMR 多样性重排，取前 Limit 条。
    OverfetchLimit = min(Limit * 3, Limit + 8),
    case recallSemantic(Query, OverfetchLimit) of
        {ok, Rows} ->
            Deduped = dedupByContent(filterSuperseded(Rows)),
            Reranked = mmrRerank(Deduped, Limit),
            {ok, maybeExpandByEntities(Reranked, Limit)};
        Error ->
            Error
    end.

%% 实体图 1-hop 扩展：结果未满时从近期记忆中补共享实体的条目。
%% 失败静默降级（返回原列表）——扩展是增益路径，不是关键路径。
maybeExpandByEntities(Rows, Limit) when is_list(Rows), length(Rows) < Limit ->
    try
        Pool = recentMemoryPool(),
        expandByEntities(Rows, Pool, Limit - length(Rows))
    catch
        _:_ -> Rows
    end;
maybeExpandByEntities(Rows, _Limit) ->
    Rows.

%% 拉取近期记忆池（实体扩展候选）。记忆量级通常为千条以下，
%% 近期 300 条足以覆盖活跃上下文；超额时按 created_at 降序。
recentMemoryPool() ->
    Sql = "SELECT id, session_id, kind, content, tags, metadata, created_at "
          "FROM memories ORDER BY created_at DESC LIMIT 300",
    case alLocalDb:query(Sql, []) of
        {ok, Rows} when is_list(Rows) -> filterSuperseded([normalizeRow(R) || R <- Rows]);
        _ -> []
    end.

%%--------------------------------------------------------------------
%% @doc
%% 按内容文本去重：保留相同内容中分数最高的一条。
%% @end
%%--------------------------------------------------------------------
dedupByContent(Rows) ->
    Dict = lists:foldl(fun(Row, Acc) ->
        Content = toBinary(maps:get(content, Row, <<>>)),
        Score = maps:get(score, Row, 0.0),
        case maps:find(Content, Acc) of
            {ok, Existing} ->
                case maps:get(score, Existing, 0.0) >= Score of
                    true -> Acc;
                    false -> maps:put(Content, Row, Acc)
                end;
            _ ->
                maps:put(Content, Row, Acc)
        end
    end, #{}, Rows),
    maps:values(Dict).

%%--------------------------------------------------------------------
%% @doc
%% MMR（Maximal Marginal Relevance）简化重排：贪心选择分数最高且与
%% 已选条目内容差异最大的项。避免返回多条高度相似的记忆。
%%
%% @param Rows 已按分数降序排列的候选列表
%% @param Limit 最终返回数量
%% @return 重排后的前 Limit 条
%% @end
%%--------------------------------------------------------------------
mmrRerank(Rows, Limit) ->
    Sorted = lists:sort(fun(A, B) ->
        maps:get(score, A, 0.0) >= maps:get(score, B, 0.0)
    end, Rows),
    mmrSelect(Sorted, [], Limit).

mmrSelect([], Selected, _Limit) ->
    lists:reverse(Selected);
mmrSelect(_Candidates, Selected, Limit) when length(Selected) >= Limit ->
    lists:reverse(Selected);
mmrSelect(Candidates, Selected, Limit) ->
    case Selected of
        [] ->
            %% 第一条直接选分数最高的
            [Best | Rest] = Candidates,
            mmrSelect(Rest, [Best], Limit);
        _ ->
            %% 选 MMR 分数最高的：原始分数 - 与已选最大相似度（用内容重叠近似）
            {Best, Rest} = pickMmr(Candidates, Selected),
            mmrSelect(Rest, [Best], Limit)
    end.

%% 从候选中选 MMR 分数最高的项。
pickMmr([Candidate | Rest], Selected) ->
    pickMmr(Rest, Selected, Candidate, mmrScore(Candidate, Selected), [Candidate]).

pickMmr([], _Selected, Best, _BestScore, Acc) ->
    %% Acc 含 Best，Rest 必须去掉 Best，否则 mmrSelect 会反复选同一条（Limit 大时像死循环）
    {Best, lists:reverse(lists:delete(Best, Acc))};
pickMmr([Candidate | Rest], Selected, Best, BestScore, Acc) ->
    Score = mmrScore(Candidate, Selected),
    case Score > BestScore of
        true ->
            %% 新候选更好：把旧 Best 放回剩余列表
            pickMmr(Rest, Selected, Candidate, Score, [Best | Acc]);
        false ->
            pickMmr(Rest, Selected, Best, BestScore, [Candidate | Acc])
    end.

%% MMR 分数 = 原始分数 * 0.7 - 与已选最大相似度 * 0.3
%% 相似度用内容词重叠率近似（Jaccard 系数）。
mmrScore(Candidate, Selected) ->
    RawScore = maps:get(score, Candidate, 0.0),
    CandWords = wordSet(maps:get(content, Candidate, <<>>)),
    MaxSim = lists:foldl(fun(Sel, Max) ->
        SelWords = wordSet(maps:get(content, Sel, <<>>)),
        Sim = jaccard(CandWords, SelWords),
        max(Sim, Max)
    end, 0.0, Selected),
    RawScore * 0.7 - MaxSim * 0.3.

%% 将文本转为词集合（按空格分词，小写）。
wordSet(Text) ->
    Bin = toBinary(Text),
    Lower = string:lowercase(Bin),
    sets:from_list(binary:split(Lower, <<" ">>, [global, trim_all])).

%% Jaccard 相似度系数：交集大小 / 并集大小。
jaccard(SetA, SetB) ->
    Intersection = sets:size(sets:intersection(SetA, SetB)),
    Union = sets:size(sets:union(SetA, SetB)),
    case Union of
        0 -> 0.0;
        _ -> Intersection / Union
    end.

%%--------------------------------------------------------------------
%% @doc
%% 从 SQLite 删除一条记忆，并尽力同步删除向量索引中的对应条目。
%%
%% 直接以 DELETE 的 Changes > 0 判定存在性，消除原 SELECT-then-DELETE 的 TOCTOU
%% （SELECT 与 DELETE 之间被并发删除会误报 notFound，反之并发插入会漏删）。
%% 文件后端与 Rust Core 后端都返回 {ok, Changes}，统一按 Changes 判定。
%%
%% @param Id 记忆主键
%% @return `{ok, Id}' | `{error, notFound}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
forget(Id) when is_integer(Id) ->
    case alLocalDb:execute("DELETE FROM memories WHERE id = ?", [Id]) of
        {ok, Changes} when is_integer(Changes), Changes > 0 ->
            _ = maybeDeleteMemoryIndex(Id),
            {ok, Id};
        {ok, _} ->
            %% Changes = 0：行不存在（或已被并发删除），视为 notFound。
            {error, notFound};
        {error, _} = Error ->
            Error
    end;
forget(Id) ->
    case toInt(Id) of
        undefined -> {error, invalid_id};
        N -> forget(N)
    end.

%%--------------------------------------------------------------------
%% @doc 按主键读取一条记忆。
%% @end
%%--------------------------------------------------------------------
-spec get(integer() | binary() | string()) -> {ok, map()} | {error, term()}.
get(Id0) ->
    case toInt(Id0) of
        undefined ->
            {error, invalid_id};
        Id ->
            Sql = "SELECT id, session_id, kind, content, tags, metadata, created_at "
                  "FROM memories WHERE id = ? LIMIT 1",
            case alLocalDb:query(Sql, [Id]) of
                {ok, [Row | _]} -> {ok, normalizeRow(Row)};
                {ok, []} -> {error, notFound};
                Error -> Error
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 将旧记忆标记为已被 NewId 取代（软废止，保留审计）。
%% 召回侧应过滤 `superseded` 标签。
%% @end
%%--------------------------------------------------------------------
-spec markSuperseded(integer() | binary(), integer() | binary() | undefined) ->
          {ok, integer()} | {error, term()}.
markSuperseded(Id0, ById0) ->
    case get(Id0) of
        {error, _} = E ->
            E;
        {ok, Row} ->
            Id = maps:get(id, Row),
            ById = toInt(ById0),
            Tags0 = ensureListTags(maps:get(tags, Row, [])),
            Tags = lists:usort([<<"superseded">> | [toBinary(T) || T <- Tags0]]),
            Meta0 = case maps:get(metadata, Row, #{}) of
                M when is_map(M) -> M;
                _ -> #{}
            end,
            Meta = Meta0#{
                superseded => true,
                supersededBy => ById,
                supersededAt => erlang:system_time(second)
            },
            Sql = "UPDATE memories SET tags = ?, metadata = ? WHERE id = ?",
            case alLocalDb:execute(Sql, [alJson:encode(Tags), alJson:encode(Meta), Id]) of
                {ok, Changes} when is_integer(Changes), Changes > 0 ->
                    {ok, Id};
                {ok, _} ->
                    {error, notFound};
                {error, _} = Error ->
                    Error
            end
    end.

%%--------------------------------------------------------------------
%% @doc 合并更新记忆的 metadata 字段（读-改-写）。
%% @end
%%--------------------------------------------------------------------
-spec patchMetadata(integer() | binary(), map()) -> {ok, integer()} | {error, term()}.
patchMetadata(Id0, Patch) when is_map(Patch) ->
    case get(Id0) of
        {error, _} = E ->
            E;
        {ok, Row} ->
            Id = maps:get(id, Row),
            Meta0 = case maps:get(metadata, Row, #{}) of
                M when is_map(M) -> M;
                _ -> #{}
            end,
            Meta = maps:merge(Meta0, Patch),
            Sql = "UPDATE memories SET metadata = ? WHERE id = ?",
            case alLocalDb:execute(Sql, [alJson:encode(Meta), Id]) of
                {ok, Changes} when is_integer(Changes), Changes > 0 ->
                    {ok, Id};
                {ok, _} ->
                    {error, notFound};
                {error, _} = Error ->
                    Error
            end
    end;
patchMetadata(_, _) ->
    {error, badarg}.

ensureListTags(L) when is_list(L) -> L;
ensureListTags(B) when is_binary(B) ->
    case decodeJson(B) of
        L when is_list(L) -> L;
        _ -> []
    end;
ensureListTags(_) -> [].

%%--------------------------------------------------------------------
%% @doc
%% 从 SQLite 全量重建向量索引（SoT → cache）。
%% @end
%%--------------------------------------------------------------------
rebuildIndex() ->
    rebuildIndex(#{}).

%%--------------------------------------------------------------------
%% @doc
%% 从 SQLite 重建向量索引。
%%
%% Opts:
%% - `limit' — 最多重建条数（默认全部，内部按批拉取）
%% - `batch' — 每批大小（默认 100）
%%
%% @return `{ok, #{indexed => N, failed => M, skipped => K}}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
rebuildIndex(Opts) when is_map(Opts) ->
    Limit = maps:get(limit, Opts, undefined),
    Batch = max(1, maps:get(batch, Opts, 100)),
    %% 文件后端会忽略 SQL 的 LIMIT/OFFSET，需在此手动切片；
    %% Rust Core 已按 LIMIT/OFFSET 返回，不能再切。
    Fallback = alCoreClient:available() =:= false,
    rebuildIndexLoop(0, Batch, Limit, 0, 0, 0, [], Fallback).

%% 逐批拉取记忆并索引。文件后端忽略 LIMIT/OFFSET，故传入 Fallback 时
%% 手动按 Offset/Take 切片；PrevIds 作为额外兜底，当切片结果与上一批
%% 完全相同时视为已扫描完毕，避免异常数据下的无限循环。
rebuildIndexLoop(Offset, Batch, Limit, Indexed, Failed, Skipped, PrevIds, Fallback) ->
    Take = case Limit of
        undefined -> Batch;
        L when is_integer(L) ->
            Remaining = L - (Indexed + Failed + Skipped),
            case Remaining =< 0 of
                true -> 0;
                false -> min(Batch, Remaining)
            end;
        _ -> Batch
    end,
    case Take of
        0 ->
            {ok, #{indexed => Indexed, failed => Failed, skipped => Skipped}};
        _ ->
            Sql =
                "SELECT id, content FROM memories "
                "ORDER BY id ASC LIMIT ? OFFSET ?",
            case alLocalDb:query(Sql, [Take, Offset]) of
                {ok, []} ->
                    {ok, #{indexed => Indexed, failed => Failed, skipped => Skipped}};
                {ok, Rows} ->
                    Page = case Fallback of
                        true -> lists:sublist(Rows, Offset + 1, Take);
                        false -> Rows
                    end,
                    {I2, F2, S2} = lists:foldl(fun indexRow/2, {Indexed, Failed, Skipped}, Page),
                    Ids = [maps:get(id, Row, undefined) || Row <- Page],
                    case PrevIds =/= [] andalso Ids =:= PrevIds of
                        true ->
                            {ok, #{indexed => I2, failed => F2, skipped => S2}};
                        false ->
                            case length(Page) < Take of
                                true ->
                                    {ok, #{indexed => I2, failed => F2, skipped => S2}};
                                false ->
                                    rebuildIndexLoop(Offset + length(Page), Batch, Limit, I2, F2, S2, Ids, Fallback)
                            end
                    end;
                Error ->
                    Error
            end
    end.

indexRow(Row, {Indexed, Failed, Skipped}) ->
    Id = maps:get(id, Row, undefined),
    Content = maps:get(content, Row, <<>>),
    case Id of
        undefined ->
            {Indexed, Failed, Skipped + 1};
        _ ->
            case alCoreClient:memoryUpsert(Id, Content) of
                {ok, #{data := Data}} ->
                    case maps:get(ok, Data, false) of
                        true -> {Indexed + 1, Failed, Skipped};
                        false -> {Indexed, Failed + 1, Skipped}
                    end;
                {ok, _} ->
                    {Indexed + 1, Failed, Skipped};
                {error, _} ->
                    {Indexed, Failed + 1, Skipped}
            end
    end.

maybeDeleteMemoryIndex(Id) ->
    _ = alAsync:run(memoryIndexDelete, fun() ->
        case alCoreClient:memoryDelete(Id) of
            {ok, _} -> ok;
            {error, Reason} ->
                logger:debug("memory index delete skipped: ~p", [Reason])
        end
    end),
    ok.

toInt(N) when is_integer(N) -> N;
toInt(B) when is_binary(B) ->
    try binary_to_integer(B) catch _:_ -> undefined end;
toInt(L) when is_list(L) ->
    try list_to_integer(L) catch _:_ -> undefined end;
toInt(_) -> undefined.

%%--------------------------------------------------------------------
%% @doc
%% 将消息列表打包成 `role: content\n' 形式的对话摘要二进制。
%%
%% @param Messages 消息列表（每条可含 role 和 content；缺 role 默认 user、缺 content 默认空）
%% @return iolist 转换后的 binary
%% @end
%%--------------------------------------------------------------------
conversationSummary(Messages) ->
    Lines = [
        iolist_to_binary([roleLabel(Role), <<": ">>, contentText(Content), <<"\n">>])
        || Msg <- Messages, is_map(Msg),
           Role <- [msgRole(Msg)],
           Content <- [msgContent(Msg)]
    ],
    iolist_to_binary(Lines).

%% 兼容 atom / binary key，以及前端本地历史的 agent 角色。
msgRole(Msg) ->
    Role0 = maps:get(role, Msg, maps:get(<<"role">>, Msg, user)),
    case Role0 of
        agent -> assistant;
        <<"agent">> -> assistant;
        "agent" -> assistant;
        Other -> Other
    end.

msgContent(Msg) ->
    maps:get(content, Msg, maps:get(<<"content">>, Msg, <<>>)).

%% 将角色标识转换为 binary；atom 直接转，其它类型走通用 toBinary。
roleLabel(Role) when is_atom(Role) -> atom_to_binary(Role, utf8);
roleLabel(Role) -> toBinary(Role).

%% 将消息 content 字段统一转换为 binary，便于拼接到对话摘要中。
contentText(Content) when is_binary(Content) -> Content;
contentText(Content) when is_map(Content) ->
    toBinary(Content);
contentText(Content) ->
    toBinary(Content).

%%--------------------------------------------------------------------
%% @doc
%% 调用 LLM 从对话摘要中提取持久化事实条目。
%%
%% 提示词要求模型以 JSON 数组形式返回 `{kind, content, tags}'；
%% LLM 不可用时退化为启发式条目。
%%
%% @param Summary 对话摘要 binary
%% @param Opts 额外 LLM 选项（会与 agent 配置合并）
%% @return 事实条目 map 列表
%% @end
%%--------------------------------------------------------------------
extractMemoryItems(Summary, Opts) ->
    AgentCfg = alConfig:getAgentCfg(),
    LlmOpts = maps:get(llm, AgentCfg, #{}),
    ModelOverride = maps:get(memoryDistillModel, AgentCfg, undefined),
    LlmOpts1 = case ModelOverride of
        undefined -> LlmOpts;
        M -> maps:put(model, M, LlmOpts)
    end,
    %% Opts 可能含 messages（蒸馏入参），勿原样传给 LLM client；
    %% 蒸馏属廉价辅助任务：链路由时优先 aux 角色（本地模型）。
    LlmCallOpts = maps:put(llmRole, aux,
                           maps:without([messages, <<"messages">>], Opts)),
    Prompt = [
        #{role => system, content =>
            <<"从对话中提取可长期保留的事实，返回 JSON 数组。"
              "每项：{\"kind\":\"note|preference|fact\",\"content\":\"...\",\"tags\":[\"...\"]}。"
              "content 与用户语言一致（用户中文则用中文）。只返回 JSON。"/utf8>>},
        #{role => user, content => Summary}
    ],
    case alLlmClient:chat(Prompt, maps:merge(LlmOpts1, LlmCallOpts)) of
        {ok, #{content := Content}} ->
            parseDistillJson(Content);
        {ok, Reply} ->
            parseDistillJson(maps:get(content, Reply, <<>>));
        {error, _} ->
            heuristicItems(Summary)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 解析 LLM 返回的蒸馏 JSON。
%%
%% 支持裸 JSON、``` 代码块包裹的 JSON；解析失败时退化为启发式条目。
%%
%% @param Content LLM 返回内容
%% @return 事实条目 map 列表
%% @end
%%--------------------------------------------------------------------
parseDistillJson(Content) when is_binary(Content) ->
    Trim = string:trim(Content),
    Json = case string:prefix(Trim, "```") of
        nomatch -> Trim;
        _ ->
            case re:run(Trim, "```(?:json)?\\s*([\\s\\S]*?)```", [{capture, all_but_first, binary}]) of
                {match, [Inner]} -> Inner;
                _ -> Trim
            end
    end,
    try alJson:decode(Json) of
        List when is_list(List) -> List;
        Map when is_map(Map) -> [Map];
        _ -> heuristicItems(Content)
    catch
        _:_ -> heuristicItems(Content)
    end;
parseDistillJson(Content) ->
    heuristicItems(Content).

%%--------------------------------------------------------------------
%% @doc
%% 启发式蒸馏兜底：将摘要按行切分，长度大于 20 字节的行作为 note 条目。
%%
%% @param Summary 对话摘要 binary
%% @return 事实条目 map 列表（含 `distilled' 标签）
%% @end
%%--------------------------------------------------------------------
heuristicItems(Summary) ->
    Lines = binary:split(toBinary(Summary), <<"\n">>, [global, trim_all]),
    [#{kind => note, content => L, tags => [distilled]} || L <- Lines, byte_size(L) > 20].

%%--------------------------------------------------------------------
%% @doc
%% 将蒸馏出的条目保存到记忆库（多子句）：
%%  - 无 SessionId 时直接返回条目不保存
%%  - map 形式条目按其 kind/tags 保存（兼容 JSON 的 binary key）
%%  - binary 形式条目作为 note 保存
%%  - 其它形式直接返回不保存
%%
%% @param SessionId 会话 ID 或 `undefined'
%% @param Item 蒸馏条目
%% @return `{ok, Result}' 形式
%% @end
%%--------------------------------------------------------------------
maybeSaveDistilled(undefined, Item) ->
    %% Web 蒸馏若 sessionId 缺失，仍落到固定桶，避免「显示已保存却未入库」
    maybeSaveDistilled(<<"web">>, Item);
maybeSaveDistilled(SessionId, Item) when is_map(Item) ->
    case distillContent(Item) of
        undefined ->
            {error, empty_content};
        Content ->
            Kind = distillField(Item, kind, <<"kind">>, note),
            Tags = distillField(Item, tags, <<"tags">>, [distilled]),
            remember(SessionId, Kind, Content, #{tags => Tags})
    end;
maybeSaveDistilled(SessionId, Item) when is_binary(Item) ->
    remember(SessionId, note, Item, #{tags => [distilled]});
maybeSaveDistilled(_SessionId, _Item) ->
    {error, invalid_item}.

%% jiffy return_maps 产出 <<"content">> 键；启发式路径用 atom content。
distillContent(Item) ->
    case maps:get(content, Item, undefined) of
        undefined -> maps:get(<<"content">>, Item, undefined);
        Content -> Content
    end.

distillField(Item, AtomKey, BinKey, Default) ->
    case maps:get(AtomKey, Item, undefined) of
        undefined -> maps:get(BinKey, Item, Default);
        Value -> Value
    end.

%% 简单透传：`undefined' 保持不变，其它值原样返回。
sessionIdFrom(undefined) -> undefined;
sessionIdFrom(S) -> S.

%%--------------------------------------------------------------------
%% @doc
%% 读取 user scope 记忆（偏好/画像），供 `ali:userProfile/0` 使用。
%% @end
%%--------------------------------------------------------------------
-spec userProfile() -> {ok, [map()]} | {error, term()}.
userProfile() ->
    userProfile(40).

-spec userProfile(pos_integer()) -> {ok, [map()]} | {error, term()}.
userProfile(Limit) when is_integer(Limit), Limit > 0 ->
    Sql =
        "SELECT id, session_id, kind, content, tags, metadata, created_at "
        "FROM memories ORDER BY created_at DESC LIMIT ?",
    case alLocalDb:query(Sql, [max(Limit * 4, Limit)]) of
        {ok, Rows} ->
            Norm = [normalizeRow(R) || R <- Rows],
            Userish = [R || R <- Norm,
                            scopeOf(R) =:= user
                                orelse isUserKind(rowField(R, <<"kind">>, kind, <<>>))],
            {ok, lists:sublist(Userish, Limit)};
        Error ->
            Error
    end.

isUserKind(K) ->
    lists:member(toBinary(K), [<<"preference">>, <<"profile">>, <<"user">>,
                                <<"user_pref">>, <<"persona">>]).

%% 从行中取 scope（metadata.scope，缺省 project）。
scopeOf(Row) when is_map(Row) ->
    Meta = maps:get(metadata, Row, maps:get(<<"metadata">>, Row, #{})),
    case Meta of
        M when is_map(M) ->
            normalizeScope(maps:get(scope, M, maps:get(<<"scope">>, M, project)));
        _ ->
            project
    end;
scopeOf(_) ->
    project.

filterByScope(Rows, undefined) ->
    Rows;
filterByScope(Rows, Scope) ->
    Want = normalizeScope(Scope),
    [R || R <- Rows, scopeOf(R) =:= Want].

%%--------------------------------------------------------------------
%% @doc
%% 规范化数据库行：将 tags 和 metadata 字段从 JSON 字符串解码为 Erlang 项。
%%
%% @param Row 数据库行 map
%% @return 规范化后的 map；非 map 输入原样返回
%% @end
%%--------------------------------------------------------------------
normalizeRow(Row) when is_map(Row) ->
    Tags = maps:get(tags, Row, maps:get(<<"tags">>, Row, <<"[]">>)),
    Meta = maps:get(metadata, Row, maps:get(<<"metadata">>, Row, <<"{}">>)),
    DecodedMeta = decodeJson(Meta),
    {Scope, Importance} = case DecodedMeta of
        M when is_map(M) ->
            {normalizeScope(maps:get(scope, M, maps:get(<<"scope">>, M, project))),
             clampImportance(maps:get(importance, M,
                             maps:get(<<"importance">>, M, 0.5)))};
        _ ->
            {project, 0.5}
    end,
    Row#{
        tags => decodeJson(Tags),
        metadata => DecodedMeta,
        scope => Scope,
        importance => Importance
    };
normalizeRow(Row) ->
    Row.

%% @doc 将 importance 钳制到 [0.0, 1.0]；非法值默认 0.5。
clampImportance(V) when is_number(V) ->
    max(0.0, min(1.0, V + 0.0));
clampImportance(_) ->
    0.5.

%% @doc 从行 map 或 metadata 读取 importance（默认 0.5）。
importanceOf(Row) when is_map(Row) ->
    case maps:get(importance, Row, maps:get(<<"importance">>, Row, undefined)) of
        undefined ->
            Meta = maps:get(metadata, Row, maps:get(<<"metadata">>, Row, #{})),
            case is_map(Meta) of
                true ->
                    clampImportance(maps:get(importance, Meta,
                                    maps:get(<<"importance">>, Meta, 0.5)));
                false ->
                    0.5
            end;
        V ->
            clampImportance(V)
    end;
importanceOf(_) ->
    0.5.

%% @doc 综合语义分、时间衰减与 importance 的最终排序分。
finalScore(SemScore, Row, Now) when is_number(SemScore) ->
    CreatedAt = rowField(Row, <<"created_at">>, createdAt, Now),
    Decay = timeDecay(CreatedAt, Now),
    Imp = importanceOf(Row),
    SemScore * Decay * (0.5 + Imp);
finalScore(_, _, _) ->
    0.0.

%% @doc 记忆是否已被软废止（superseded 标签或 metadata 标记）。
isSuperseded(Row) when is_map(Row) ->
    Tags = ensureListTags(maps:get(tags, Row, [])),
    Meta = maps:get(metadata, Row, #{}),
    lists:member(superseded, Tags)
        orelse lists:member(<<"superseded">>, Tags)
        orelse (is_map(Meta) andalso (
            maps:get(superseded, Meta, false) =:= true
            orelse maps:get(<<"superseded">>, Meta, false) =:= true
        ));
isSuperseded(_) ->
    false.

filterSuperseded(Rows) when is_list(Rows) ->
    [R || R <- Rows, not isSuperseded(R)];
filterSuperseded(Other) ->
    Other.

%% 将 JSON 字符串解码为 Erlang 项；解码失败时返回原值。
decodeJson(Bin) when is_binary(Bin) ->
    try alJson:decode(Bin) catch _:_ -> Bin end;
decodeJson(Value) ->
    Value.

%%--------------------------------------------------------------------
%% @doc
%% 将任意值转换为 binary（多子句）：
%%  - binary 原样返回
%%  - atom 转换为 UTF-8 binary
%%  - list 转换为 UTF-8 binary
%%  - map 尝试作为消息编码为 JSON
%%  - 其它类型用 `~p' 格式化后转换
%%
%% @param Value 任意值
%% @return binary
%% @end
%%--------------------------------------------------------------------
toBinary(Value) when is_binary(Value) ->
    Value;
toBinary(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
toBinary(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
toBinary(Value) when is_map(Value) ->
    try erlang:iolist_to_binary(alJson:encode(alSessionMgr:encodeMessage(Value)))
    catch _:_ -> erlang:iolist_to_binary(io_lib:format("~p", [Value]))
    end;
toBinary(Value) ->
    unicode:characters_to_binary(io_lib:format("~p", [Value])).

%%--------------------------------------------------------------------
%% @doc
%% 将任意值转换为 list（多子句）：binary 转 UTF-8 list，list 原样返回，atom 转 list。
%%
%% @param Value 任意值
%% @return list
%% @end
%%--------------------------------------------------------------------
toList(Value) when is_binary(Value) ->
    unicode:characters_to_list(Value);
toList(Value) when is_list(Value) ->
    Value;
toList(Value) when is_atom(Value) ->
    atom_to_list(Value).
