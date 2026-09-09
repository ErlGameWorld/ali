%%% @doc EUnit tests for alMemory pure helpers.
-module(alMemory_tests).

-include_lib("eunit/include/eunit.hrl").

%% P2-8 记忆实体图：extractEntities/1 + entitiesOf/1 + expandByEntities/3

extract_entities_module_mfa_file_test() ->
    Content = <<"alToolRouter:runWithTools/2 调用失败时检查 alLlmClient，"
                "补丁在 src/tools/alToolRouter.erl"/utf8>>,
    Entities = alMemory:extractEntities(Content),
    ?assert(lists:member(<<"alToolRouter">>, Entities)),
    ?assert(lists:member(<<"alToolRouter:runWithTools/2">>, Entities)),
    ?assert(lists:member(<<"alLlmClient">>, Entities)),
    ?assert(lists:member(<<"src/tools/alToolRouter.erl">>, Entities)).

extract_entities_dedup_and_cap_test() ->
    %% 重复实体去重；总量限流（≤8）
    Content = <<"alFoo alFoo alBar alBaz alQux alQuux alCorge alGrault alGarply alWaldo">>,
    Entities = alMemory:extractEntities(Content),
    ?assertEqual(8, length(Entities)),
    ?assertEqual(Entities, lists:usort(Entities)).

extract_entities_empty_and_plain_test() ->
    ?assertEqual([], alMemory:extractEntities(<<>>)),
    ?assertEqual([], alMemory:extractEntities(<<"just some words">>)),
    %% 太短的匹配（<3 字节）被过滤
    ?assertEqual([], alMemory:extractEntities(<<"a:b">>)).

entities_of_prefers_stored_test() ->
    Row = #{content => <<"alFoo mention">>,
            metadata => #{entities => [<<"alStored">>, <<"alSaved">>]}},
    Set = alMemory:entitiesOf(Row),
    ?assert(sets:is_element(<<"alStored">>, Set)),
    ?assert(sets:is_element(<<"alSaved">>, Set)),
    ?assertNot(sets:is_element(<<"alFoo">>, Set)).

entities_of_falls_back_to_content_test() ->
    %% 历史数据无 metadata.entities：现场从内容提取
    Row = #{content => <<"alFoo and alBar discussed">>},
    Set = alMemory:entitiesOf(Row),
    ?assert(sets:is_element(<<"alFoo">>, Set)),
    ?assert(sets:is_element(<<"alBar">>, Set)).

entities_of_binary_keys_test() ->
    %% Rust 原始行用 binary 键
    Row = #{<<"content">> => <<"alFoo mentioned">>,
            <<"metadata">> => #{<<"entities">> => [<<"alX">>]}},
    Set = alMemory:entitiesOf(Row),
    ?assert(sets:is_element(<<"alX">>, Set)).

entities_of_non_map_test() ->
    ?assertEqual(0, sets:size(alMemory:entitiesOf(undefined))).

expand_by_entities_adds_related_test() ->
    %% 命中 alFoo 相关记忆 → 池中共享 alFoo 实体的记忆被补充
    Hit = #{id => 1, content => <<"alFoo bug fix"/utf8>>, created_at => 100},
    Related = #{id => 2, content => <<"alFoo 使用注意事项"/utf8>>, created_at => 200},
    Unrelated = #{id => 3, content => <<"completely different topic">>, created_at => 300},
    Result = alMemory:expandByEntities([Hit], [Related, Unrelated], 2),
    ?assertEqual(2, length(Result)),
    Expanded = lists:last(Result),
    ?assertEqual(2, maps:get(id, Expanded)),
    ?assertEqual(true, maps:get(entityExpanded, Expanded)),
    ?assertEqual(1, maps:get(sharedEntities, Expanded)).

expand_by_entities_excludes_duplicates_test() ->
    %% 与命中行同 content / 同 id 的池条目不重复扩展
    Hit = #{id => 1, content => <<"alFoo bug">>, created_at => 100},
    DupContent = #{id => 99, content => <<"alFoo bug">>, created_at => 200},
    DupId = #{id => 1, content => <<"alFoo other">>, created_at => 300},
    Result = alMemory:expandByEntities([Hit], [DupContent, DupId], 2),
    ?assertEqual([Hit], Result).

expand_by_entities_budget_test() ->
    Hit = #{id => 1, content => <<"alFoo bug">>, created_at => 100},
    Pool = [#{id => N, content => <<"alFoo note "/utf8, (integer_to_binary(N))/binary>>,
              created_at => 1000 + N} || N <- lists:seq(2, 6)],
    Result = alMemory:expandByEntities([Hit], Pool, 2),
    ?assertEqual(3, length(Result)),
    ?assertEqual(2, length([R || R <- Result, maps:get(entityExpanded, R, false)])).

expand_by_entities_no_overlap_test() ->
    %% 无共享实体：不扩展
    Hit = #{id => 1, content => <<"alFoo bug">>, created_at => 100},
    Pool = [#{id => 2, content => <<"something else entirely">>, created_at => 200}],
    ?assertEqual([Hit], alMemory:expandByEntities([Hit], Pool, 2)).

expand_by_entities_prefers_recent_test() ->
    %% 共享实体数相同时，新记忆排前（时间衰减加权）
    Hit = #{id => 1, content => <<"alFoo bug">>, created_at => erlang:system_time(second)},
    Old = #{id => 2, content => <<"alFoo old note">>,
            created_at => erlang:system_time(second) - 86400 * 365},
    New = #{id => 3, content => <<"alFoo new note">>,
            created_at => erlang:system_time(second)},
    [_, First | _] = alMemory:expandByEntities([Hit], [Old, New], 1),
    ?assertEqual(3, maps:get(id, First)).

expand_by_entities_zero_budget_test() ->
    Hit = #{id => 1, content => <<"alFoo">>},
    ?assertEqual([Hit], alMemory:expandByEntities([Hit], [Hit], 0)),
    ?assertEqual([], alMemory:expandByEntities(undefined, [], 1)).

%% normalizeRow/1 — decodes tags/metadata JSON

normalize_row_adds_defaults_test() ->
    Row = alMemory:normalizeRow(#{}),
    ?assertMatch(#{tags := [], metadata := #{}}, Row).

normalize_row_decodes_json_test() ->
    Row = alMemory:normalizeRow(#{tags => <<"[\"note\",\"bug\"]">>, metadata => <<"{\"k\":\"v\"}">>}),
    ?assertEqual([<<"note">>, <<"bug">>], maps:get(tags, Row)),
    ?assertEqual(#{<<"k">> => <<"v">>}, maps:get(metadata, Row)).

normalize_row_preserves_other_fields_test() ->
    Row = alMemory:normalizeRow(#{id => 1, content => <<"hi">>, tags => <<"[]">>}),
    ?assertEqual(1, maps:get(id, Row)),
    ?assertEqual(<<"hi">>, maps:get(content, Row)),
    ?assertEqual([], maps:get(tags, Row)).

normalize_row_passthrough_non_map_test() ->
    ?assertEqual(other, alMemory:normalizeRow(other)).

normalize_row_invalid_json_keeps_binary_test() ->
    Row = alMemory:normalizeRow(#{tags => <<"not json">>}),
    ?assertEqual(<<"not json">>, maps:get(tags, Row)).

%% decodeJson/1

decode_json_valid_list_test() ->
    ?assertEqual([1, 2], alMemory:decodeJson(<<"[1,2]">>)).

decode_json_valid_map_test() ->
    ?assertEqual(#{<<"a">> => 1}, alMemory:decodeJson(<<"{\"a\":1}">>)).

decode_json_invalid_returns_binary_test() ->
    ?assertEqual(<<"not json">>, alMemory:decodeJson(<<"not json">>)).

decode_json_non_binary_passthrough_test() ->
    ?assertEqual(other, alMemory:decodeJson(other)).

%% toBinary/1

to_binary_binary_test() ->
    ?assertEqual(<<"x">>, alMemory:toBinary(<<"x">>)).

to_binary_atom_test() ->
    ?assertEqual(<<"note">>, alMemory:toBinary(note)).

to_binary_list_test() ->
    ?assertEqual(<<"hi">>, alMemory:toBinary("hi")).

to_binary_map_test() ->
    Bin = alMemory:toBinary(#{a => 1}),
    ?assert(is_binary(Bin)),
    ?assertEqual(#{<<"a">> => 1}, alJson:decode(Bin)).

%% timeDecay/2 — 时间衰减因子

time_decay_now_is_max_test() ->
    Now = erlang:system_time(second),
    Decay = alMemory:timeDecay(Now, Now),
    %% 刚创建的记忆衰减因子应接近 1.0
    ?assert(Decay > 0.99).

time_decay_30days_test() ->
    Now = erlang:system_time(second),
    ThirtyDaysAgo = Now - 30 * 86400,
    Decay = alMemory:timeDecay(ThirtyDaysAgo, Now),
    %% 30 天半衰期：衰减因子应在 0.5 + 0.5*0.368 ≈ 0.68 附近
    ?assert(Decay > 0.60 andalso Decay < 0.75).

time_decay_90days_test() ->
    Now = erlang:system_time(second),
    NinetyDaysAgo = Now - 90 * 86400,
    Decay = alMemory:timeDecay(NinetyDaysAgo, Now),
    %% 90 天：衰减因子应更低但仍 > 0.5
    ?assert(Decay > 0.50 andalso Decay < 0.60).

time_decay_future_clamped_test() ->
    Now = erlang:system_time(second),
    Future = Now + 86400,
    %% 创建时间在未来时回退到 0.5（不应出现，但需安全处理）
    ?assertEqual(0.5, alMemory:timeDecay(Future, Now)).

to_binary_other_test() ->
    ?assertEqual(<<"42">>, alMemory:toBinary(42)).

%% toList/1

to_list_binary_test() ->
    ?assertEqual("hi", alMemory:toList(<<"hi">>)).

to_list_atom_test() ->
    ?assertEqual("hello", alMemory:toList(hello)).

to_list_list_test() ->
    ?assertEqual("hi", alMemory:toList("hi")).

%% rebuildIndex / forget — pure arg validation without DB when possible

forget_invalid_id_test() ->
    ?assertEqual({error, invalid_id}, alMemory:forget(not_an_id)).

%% 2a：rowField 双键读取 —— 修复 fetchMemoriesByIds 的 created_at/session_id 语义键问题

row_field_prefers_binary_created_at_test() ->
    %% 文件后端行使用 binary 键 <<"created_at">>
    Row = #{<<"created_at">> => 1000, createdAt => 9999},
    ?assertEqual(1000, alMemory:rowField(Row, <<"created_at">>, createdAt, undefined)).

row_field_falls_back_to_atom_created_at_test() ->
    %% Rust Core 归一化行使用 atom 键 createdAt
    ?assertEqual(1000, alMemory:rowField(#{createdAt => 1000}, <<"created_at">>, createdAt, undefined)).

row_field_missing_returns_default_test() ->
    ?assertEqual(undefined, alMemory:rowField(#{}, <<"created_at">>, createdAt, undefined)).

binary_created_at_row_decay_test() ->
    %% 模拟文件后端返回的含 <<"created_at">> 键的行：时间衰减权重计算生效
    Now = erlang:system_time(second),
    Row = #{<<"created_at">> => Now},
    CreatedAt = alMemory:rowField(Row, <<"created_at">>, createdAt, Now),
    ?assertEqual(Now, CreatedAt),
    Decay = alMemory:timeDecay(CreatedAt, Now),
    ?assert(Decay > 0.99).

%% 2b：文件后端忽略 LIMIT/OFFSET 重复返回全表时，rebuildIndex 必须终止

rebuild_index_terminates_on_repeat_batch_test() ->
    ensure_local_db(),
    Ids = [insertMemoryRow(I) || I <- lists:seq(1, 3)],
    try
        %% batch=2 而文件后端每次返回全部 3 行：若无重复批次终止逻辑会无限递归（测试超时）
        Result = alMemory:rebuildIndex(#{batch => 2}),
        ?assertMatch({ok, #{indexed := _, failed := _, skipped := _}}, Result)
    after
        [alLocalDb:execute("DELETE FROM memories WHERE id = ?", [Id]) || Id <- Ids]
    end.

insertMemoryRow(I) ->
    Content = <<"rebuild batch ", (integer_to_binary(I))/binary>>,
    {ok, Id} = alLocalDb:insert(
        "INSERT INTO memories (session_id, kind, content, tags, metadata, created_at) VALUES (?, ?, ?, ?, ?, ?)",
        [1, <<"note">>, Content, <<"[]">>, <<"{}">>, erlang:system_time(second)]),
    Id.

ensure_local_db() ->
    case whereis(alLocalDb) of
        undefined ->
            ok = alConfig:load(),
            {ok, Pid} = alLocalDb:start_link(),
            unlink(Pid),
            ok;
        _Pid ->
            ok
    end.

%% 2c：conversationSummary 对缺 role/content 的消息不崩溃，使用默认值

conversation_summary_missing_fields_test() ->
    Messages = [
        #{role => user, content => <<"hi">>},
        #{content => <<"no role">>},
        #{role => assistant},
        #{role => assistant, content => <<"yo">>}
    ],
    ?assertEqual(
        <<"user: hi\nuser: no role\nassistant: \nassistant: yo\n">>,
        alMemory:conversationSummary(Messages)
    ).

conversation_summary_non_map_skipped_test() ->
    ?assertEqual(
        <<"user: ok\n">>,
        alMemory:conversationSummary([not_a_map, #{role => user, content => <<"ok">>}])
    ).

%% JSON / 本地历史消息：binary key + agent 角色应能正确进入摘要
conversation_summary_binary_keys_test() ->
    Messages = [
        #{<<"role">> => <<"user">>, <<"content">> => <<"偏好深色主题"/utf8>>},
        #{<<"role">> => <<"agent">>, <<"content">> => <<"已记下"/utf8>>},
        #{role => agent, content => <<"atom agent"/utf8>>}
    ],
    ?assertEqual(
        <<"user: 偏好深色主题\nassistant: 已记下\nassistant: atom agent\n"/utf8>>,
        alMemory:conversationSummary(Messages)
    ).

%%%===================================================================
%%% importance 重要性评分维度
%%%===================================================================

clamp_importance_clamps_to_range_test() ->
    ?assertEqual(1.0, alMemory:clampImportance(1.5)),
    ?assertEqual(0.0, alMemory:clampImportance(-1)),
    ?assertEqual(1.0, alMemory:clampImportance(1)),
    ?assertEqual(0.8, alMemory:clampImportance(0.8)),
    ?assertEqual(0.5, alMemory:clampImportance(not_a_number)).

importance_of_default_test() ->
    ?assertEqual(0.5, alMemory:importanceOf(#{})).
importance_of_atom_key_test() ->
    ?assertEqual(0.9, alMemory:importanceOf(#{importance => 0.9})).
importance_of_binary_key_test() ->
    ?assertEqual(1.0, alMemory:importanceOf(#{<<"importance">> => 1.0})).

final_score_neutral_importance_test() ->
    Now = erlang:system_time(second),
    Score = alMemory:finalScore(1.0, #{<<"created_at">> => Now, importance => 0.5}, Now),
    ?assert(Score > 0.99).

final_score_importance_orders_test() ->
    Now = erlang:system_time(second),
    High = alMemory:finalScore(1.0, #{<<"created_at">> => Now, importance => 1.0}, Now),
    Low = alMemory:finalScore(1.0, #{<<"created_at">> => Now, importance => 0.0}, Now),
    ?assert(High > Low).

normalize_row_extracts_importance_test() ->
    Row = alMemory:normalizeRow(#{metadata => <<"{\"importance\":0.9,\"scope\":\"user\"}">>}),
    ?assertEqual(0.9, maps:get(importance, Row)),
    ?assertEqual(user, maps:get(scope, Row)).

normalize_row_importance_default_test() ->
    ?assertEqual(0.5, maps:get(importance, alMemory:normalizeRow(#{metadata => <<"{}">>}))).
