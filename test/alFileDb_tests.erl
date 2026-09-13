%%% @doc alFileDb 回退方案的 EUnit 测试。
-module(alFileDb_tests).

-include_lib("eunit/include/eunit.hrl").

critical_exports_test() ->
    Exports = alFileDb:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{query, 2}, {execute, 2}, {insert, 2}, {status, 0}]].

status_test() ->
    Status = alFileDb:status(),
    ?assertEqual(jsonl, maps:get(engine, Status)),
    ?assertEqual(true, maps:get(enabled, Status)).

memoriesQuery_test() ->
    ?assertMatch({ok, _}, alFileDb:query("SELECT * FROM memories LIMIT 1", [])).

unknownTableQuery_test() ->
    Result = alFileDb:query("SELECT * FROM nonexistentTableXYZ LIMIT 1", []),
    ?assertMatch({error, #{reason := unknownTable}}, Result).

invalidSqlQuery_test() ->
    Result = alFileDb:query("NOT VALID SQL @#$", []),
    ?assertMatch({error, #{reason := unknownTable}}, Result).

%% 会话表 CRUD 测试：确保 alFileDb 支持 sessions / session_messages，
%% 让 alLocalDb 能将会话持久化路由到文件后端，绕过 Rust Core Port 串行队列。

sessionInsertAndQuery_test() ->
    Sid = erlang:unique_integer([positive]),
    Msg1 = <<"{\"role\":\"user\",\"content\":\"hi\"}">>,
    Msg2 = <<"{\"role\":\"assistant\",\"content\":\"hello\"}">>,
    %% 清理可能残留的同 SID 数据
    alFileDb:execute("DELETE FROM session_messages WHERE session_id = ?", [Sid]),
    %% 插入两条消息
    ?assertMatch({ok, _}, alFileDb:insert(
        "INSERT INTO session_messages (session_id, seq, message, created_at) VALUES (?, ?, ?, ?)",
        [Sid, 1, Msg1, 1000])),
    ?assertMatch({ok, _}, alFileDb:insert(
        "INSERT INTO session_messages (session_id, seq, message, created_at) VALUES (?, ?, ?, ?)",
        [Sid, 2, Msg2, 1001])),
    %% 查询并验证顺序
    {ok, Rows} = alFileDb:query(
        "SELECT message FROM session_messages WHERE session_id = ? ORDER BY seq", [Sid]),
    ?assertEqual(2, length(Rows)),
    %% 清理
    alFileDb:execute("DELETE FROM session_messages WHERE session_id = ?", [Sid]),
    ok.

sessionUpsertAndUpdate_test() ->
    Sid = erlang:unique_integer([positive]),
    %% 清理
    alFileDb:execute("DELETE FROM sessions WHERE id = ?", [Sid]),
    %% 插入 session
    ?assertMatch({ok, _}, alFileDb:insert(
        "INSERT INTO sessions (id, user, created_at, updated_at) VALUES (?, ?, ?, ?)",
        [Sid, <<"tester">>, 1000, 1000])),
    %% 更新 updatedAt
    ?assertMatch({ok, _}, alFileDb:execute(
        "UPDATE sessions SET updated_at = ? WHERE id = ?", [2000, Sid])),
    %% 查询验证（rowToAtoms 转换后键为 atom）
    {ok, Rows} = alFileDb:query("SELECT * FROM sessions WHERE id = ?", [Sid]),
    ?assertEqual(1, length(Rows)),
    [Row] = Rows,
    ?assertEqual(2000, maps:get(updatedAt, Row, undefined)),
    %% 清理
    alFileDb:execute("DELETE FROM sessions WHERE id = ?", [Sid]),
    ok.

%% 回归：INSERT OR IGNORE ... updated_at 不得被误判为 UPDATE（substring "update"）。
session_insert_or_ignore_via_execute_test() ->
    Sid = iolist_to_binary([<<"sess_">>, integer_to_binary(erlang:unique_integer([positive]))]),
    alFileDb:execute("DELETE FROM sessions WHERE id = ?", [Sid]),
    Sql = "INSERT OR IGNORE INTO sessions (id, user, created_at, updated_at) VALUES (?, ?, ?, ?)",
    ?assertMatch({ok, _}, alFileDb:execute(Sql, [Sid, <<"web">>, 1000, 1000])),
    ?assertMatch({ok, 0}, alFileDb:execute(Sql, [Sid, <<"web">>, 1000, 1000])),
    ?assertMatch({ok, _}, alFileDb:execute(
        "UPDATE sessions SET updated_at = ?, user = ? WHERE id = ?",
        [2000, <<"web">>, Sid])),
    {ok, Rows} = alFileDb:query("SELECT * FROM sessions WHERE id = ?", [Sid]),
    ?assertEqual(1, length(Rows)),
    [Row] = Rows,
    ?assertEqual(2000, maps:get(updatedAt, Row, undefined)),
    ?assertEqual(<<"web">>, maps:get(user, Row, undefined)),
    alFileDb:execute("DELETE FROM sessions WHERE id = ?", [Sid]),
    ok.

%% 回归：session_artifacts upsert 必须走「按会话分片」写入，不得再
%% 整文件读取 + tmp 重写（旧实现是 agent 收尾超时崩溃的根因）。
%% 断言：多次 upsert 后查询只返回最新一行，且写入耗时不随文件增长。
sessionArtifactUpsertIsShardScoped_test() ->
    Sid = iolist_to_binary([<<"art_">>, integer_to_binary(erlang:unique_integer([positive]))]),
    Sql = "INSERT OR REPLACE INTO session_artifacts "
          "(session_id, summary, tool_trace, critiques, token_usage, plan, updated_at) "
          "VALUES (?, ?, ?, ?, ?, ?, ?)",
    try
        %% 连续写 20 次，模拟多轮问答收尾
        lists:foreach(fun(N) ->
            ?assertMatch({ok, _},
                alFileDb:execute(Sql, [Sid, <<"{\"n\":", (integer_to_binary(N))/binary, "}">>,
                                       <<"[]">>, <<"[]">>, <<"{}">>, <<"{}">>, N]))
        end, lists:seq(1, 20)),
        %% 读回：同一 sessionId 只有一行，且为最后一次写入
        {ok, Rows} = alFileDb:query(
            "SELECT summary FROM session_artifacts WHERE session_id = ?", [Sid]),
        ?assertEqual(1, length(Rows)),
        [Row] = Rows,
        Summary = maps:get(summary, Row, maps:get(<<"summary">>, Row, undefined)),
        ?assertEqual(<<"{\"n\":20}">>, Summary)
    after
        alFileDb:execute("DELETE FROM session_artifacts WHERE session_id = ?", [Sid])
    end.

%% 回归：删除 artifacts 后查询应为空（分片删除生效）。
sessionArtifactDelete_test() ->
    Sid = iolist_to_binary([<<"artdel_">>, integer_to_binary(erlang:unique_integer([positive]))]),
    Sql = "INSERT OR REPLACE INTO session_artifacts "
          "(session_id, summary, tool_trace, critiques, token_usage, plan, updated_at) "
          "VALUES (?, ?, ?, ?, ?, ?, ?)",
    ?assertMatch({ok, _},
        alFileDb:execute(Sql, [Sid, <<"{}">>, <<"[]">>, <<"[]">>, <<"{}">>, <<"{}">>, 1])),
    {ok, [_]} = alFileDb:query(
        "SELECT summary FROM session_artifacts WHERE session_id = ?", [Sid]),
    alFileDb:execute("DELETE FROM session_artifacts WHERE session_id = ?", [Sid]),
    {ok, Rows} = alFileDb:query(
        "SELECT summary FROM session_artifacts WHERE session_id = ?", [Sid]),
    ?assertEqual([], Rows).

%% 1a：filterMemoriesLike 支持 searchTags 风格的 2 元素参数 [Pattern, Limit]

filterMemoriesLikeTwoParams_test() ->
    Id1 = insertMemory(<<"common note">>),
    Id2 = insertMemory(<<"common tag">>),
    try
        %% searchTags 传入 [Pattern, Limit]（2 元素）：不再 function_clause，
        %% 且第二元素被解释为上限（Limit=1 时两条匹配只返回 1 条）。
        {ok, Rows} = alFileDb:query(
            "SELECT * FROM memories WHERE content LIKE ? ESCAPE '\\' OR tags LIKE ? ESCAPE '\\' "
            "ORDER BY created_at DESC LIMIT ?",
            ["%common%", 1]),
        ?assertEqual(1, length(Rows))
    after
        alFileDb:execute("DELETE FROM memories WHERE id = ?", [Id1]),
        alFileDb:execute("DELETE FROM memories WHERE id = ?", [Id2])
    end.

%% 1b：8 参数 INSERT 落入 critique_logs.jsonl（alCritic:persist/5 传参形状），
%% 且不再被误写进 memories.jsonl

critiqueLogsEightParams_test() ->
    Marker = iolist_to_binary([<<"e8-">>,
                               integer_to_binary(erlang:unique_integer([positive, monotonic])),
                               <<"-">>, integer_to_binary(erlang:system_time(nanosecond))]),
    {ok, Id} = alFileDb:insert(
        "INSERT INTO critique_logs (session_id, question, answer, verdict, score, feedback, round, created_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        [42, Marker, <<"ans">>, pass, 0.9, <<"ok">>, 3, 1234]),
    try
        {ok, Crows} = alFileDb:query("SELECT * FROM critique_logs LIMIT 1000", []),
        Matched = [R || R <- Crows, rowId(R) =:= Id],
        ?assertEqual(1, length(Matched)),
        [Row] = Matched,
        ?assertEqual(3, maps:get(<<"round">>, Row, undefined)),
        ?assertEqual(1234, maps:get(<<"createdAt">>, Row, undefined)),
        {ok, MRows} = alFileDb:query("SELECT * FROM memories LIMIT 1000", []),
        ?assertEqual([], [R || R <- MRows, rowId(R) =:= Id])
    after
        _ = alFileDb:execute("DELETE FROM critique_logs WHERE id = ?", [Id])
    end.

%% 1b：7 参数 INSERT 仍落入 critique_logs.jsonl

critiqueLogsSevenParamsStillCritique_test() ->
    Marker = iolist_to_binary([<<"e7-">>,
                               integer_to_binary(erlang:unique_integer([positive, monotonic])),
                               <<"-">>, integer_to_binary(erlang:system_time(nanosecond))]),
    {ok, Id} = alFileDb:insert(
        "INSERT INTO critique_logs (session_id, question, answer, verdict, score, feedback, created_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        [43, Marker, <<"ans">>, fail, 0.2, <<"bad">>, 1234]),
    try
        {ok, Crows} = alFileDb:query("SELECT * FROM critique_logs LIMIT 1000", []),
        ?assertEqual(1, length([R || R <- Crows, maps:get(<<"question">>, R, undefined) =:= Marker])),
        %% 未被误写进 memories.jsonl
        {ok, MRows} = alFileDb:query("SELECT * FROM memories LIMIT 1000", []),
        ?assertEqual([], [R || R <- MRows, maps:get(<<"question">>, R, undefined) =:= Marker])
    after
        _ = alFileDb:execute("DELETE FROM critique_logs WHERE id = ?", [Id])
    end.

%% 1d：DELETE FROM memories WHERE id = ? 生效（alMemory:forget 依赖此能力）

deleteMemoriesById_test() ->
    Id1 = insertMemory(<<"to delete">>),
    Id2 = insertMemory(<<"to keep">>),
    ?assertEqual({ok, 1}, alFileDb:execute("DELETE FROM memories WHERE id = ?", [Id1])),
    {ok, Rows} = alFileDb:query("SELECT * FROM memories LIMIT 1000", []),
    Ids = [rowId(R) || R <- Rows],
    ?assertNot(lists:member(Id1, Ids)),
    ?assert(lists:member(Id2, Ids)),
    %% 清理
    alFileDb:execute("DELETE FROM memories WHERE id = ?", [Id2]),
    ok.

%%--------------------------------------------------------------------
%% D3 回归：alMemory:list 的多条件组合过滤（WHERE ... AND ...）在文件
%% 后端走 where 模式，参数按 session/kind/tag/q/limit 顺序逐位消费，
%% 不再因 Params 长度 ≥4 落入 filterMemoriesLike 导致 function_clause。
%%--------------------------------------------------------------------

memoriesWhere_session_and_kind_test() ->
    Sid = erlang:unique_integer([positive]),
    Id1 = insertMemoryRow(Sid, <<"note">>, <<"zzw1">>, <<"[]">>),
    Id2 = insertMemoryRow(Sid, <<"fact">>, <<"zzw1">>, <<"[]">>),
    Id3 = insertMemoryRow(Sid + 1, <<"note">>, <<"zzw1">>, <<"[]">>),
    try
        {ok, Rows} = alFileDb:query(
            "SELECT id, session_id, kind, content, tags, metadata, created_at "
            "FROM memories WHERE session_id = ? AND kind = ? "
            "ORDER BY created_at DESC LIMIT ?",
            [Sid, <<"note">>, 10]),
        ?assertEqual([Id1], [rowId(R) || R <- Rows])
    after
        cleanupIds([Id1, Id2, Id3])
    end.

%% kind + q：q 子句含 `OR tags LIKE'，必须不误判为 tag 过滤；
%% 且 SELECT 列名含 session_id，必须不误判为 session 过滤。
memoriesWhere_kind_and_q_test() ->
    Sid = erlang:unique_integer([positive]),
    Token = iolist_to_binary([<<"zzw2-">>, integer_to_binary(Sid)]),
    Id1 = insertMemoryRow(Sid, <<"note">>, <<Token/binary, " hello">>, <<"[]">>),
    Id2 = insertMemoryRow(Sid, <<"fact">>, <<Token/binary, " hello">>, <<"[]">>),
    Like = iolist_to_binary([<<"%">>, Token, <<"%">>]),
    try
        {ok, Rows} = alFileDb:query(
            "SELECT id, session_id, kind, content, tags, metadata, created_at "
            "FROM memories WHERE kind = ? AND (content LIKE ? ESCAPE '\\' OR tags LIKE ? ESCAPE '\\') "
            "ORDER BY created_at DESC LIMIT ?",
            [<<"note">>, Like, Like, 10]),
        ?assertEqual([Id1], [rowId(R) || R <- Rows])
    after
        cleanupIds([Id1, Id2])
    end.

%% 全条件组合：session + kind + tag + q，验证参数位序与 Spec 完全对齐。
memoriesWhere_all_filters_test() ->
    Sid = erlang:unique_integer([positive]),
    Token = iolist_to_binary([<<"zzw3-">>, integer_to_binary(Sid)]),
    Id1 = insertMemoryRow(Sid, <<"note">>, <<Token/binary, " apple">>, <<"[\"distilled\"]">>),
    Id2 = insertMemoryRow(Sid, <<"note">>, <<Token/binary, " apple">>, <<"[]">>),
    Id3 = insertMemoryRow(Sid + 1, <<"note">>, <<Token/binary, " apple">>, <<"[\"distilled\"]">>),
    Like = iolist_to_binary([<<"%">>, Token, <<"%">>]),
    try
        {ok, Rows} = alFileDb:query(
            "SELECT id, session_id, kind, content, tags, metadata, created_at "
            "FROM memories WHERE session_id = ? AND kind = ? AND tags LIKE ? ESCAPE '\\' "
            "AND (content LIKE ? ESCAPE '\\' OR tags LIKE ? ESCAPE '\\') "
            "ORDER BY created_at DESC LIMIT ?",
            [Sid, <<"note">>, "%\"distilled\"%", Like, Like, 10]),
        ?assertEqual([Id1], [rowId(R) || R <- Rows])
    after
        cleanupIds([Id1, Id2, Id3])
    end.

%% 插入一条 memories 行，返回生成的 id。
insertMemory(Content) ->
    {ok, Id} = alFileDb:insert(
        "INSERT INTO memories (session_id, kind, content, tags, metadata, created_at) VALUES (?, ?, ?, ?, ?, ?)",
        [1, <<"note">>, Content, <<"[]">>, <<"{}">>, 1000]),
    Id.

%% 插入指定 session/kind/content/tags 的 memories 行，返回生成的 id。
insertMemoryRow(Sid, Kind, Content, Tags) ->
    {ok, Id} = alFileDb:insert(
        "INSERT INTO memories (session_id, kind, content, tags, metadata, created_at) VALUES (?, ?, ?, ?, ?, ?)",
        [Sid, Kind, Content, Tags, <<"{}">>, 1000]),
    Id.

%% 按 id 批量清理测试插入的 memories 行。
cleanupIds(Ids) ->
    lists:foreach(fun(Id) ->
        _ = alFileDb:execute("DELETE FROM memories WHERE id = ?", [Id])
    end, Ids),
    ok.

%% 提取行中的 id 字段（兼容二进制与原子两种键形式）。
rowId(Row) -> maps:get(<<"id">>, Row, maps:get(id, Row, undefined)).
