%%% @doc EUnit tests for alQueryDecompose pure helpers.
-module(alQueryDecompose_tests).

-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% 关键导出存在性
%%--------------------------------------------------------------------
critical_exports_test() ->
    Exports = alQueryDecompose:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{decompose, 1}, {decompose, 2}, {clearCache, 0},
                   {needsDecompose, 1}, {dedupHits, 1}]].

%%--------------------------------------------------------------------
%% needsDecompose/1 — 启发式判断是否需要分解
%%--------------------------------------------------------------------
needs_decompose_short_simple_test() ->
    %% 短问题无连接词 → false
    ?assertNot(alQueryDecompose:needsDecompose(<<"hello">>)),
    ?assertNot(alQueryDecompose:needsDecompose(<<"start_link 在哪"/utf8>>)).

needs_decompose_with_connector_test() ->
    %% 含连接词 → true（即使短）
    ?assert(alQueryDecompose:needsDecompose(<<"对比 A 和 B"/utf8>>)),
    ?assert(alQueryDecompose:needsDecompose(<<"A vs B">>)),
    ?assert(alQueryDecompose:needsDecompose(<<"X 和 Y 的区别"/utf8>>)).

needs_decompose_long_test() ->
    %% 长问题但无连接/对比词 → 不分解（避免中文短句/长说明无谓调 LLM）
    Long = <<"how does the caching mechanism work in this module please explain">>,
    ?assertNot(alQueryDecompose:needsDecompose(Long)),
    %% 玩家查询类中文长句无对比词 → 不分解
    PlayerQ = <<"我知道一个玩家账号名字为 YY1 你帮我查询一下这个玩家的主城坐标在哪里"/utf8>>,
    ?assertNot(alQueryDecompose:needsDecompose(PlayerQ)).

needs_decompose_non_binary_test() ->
    ?assertNot(alQueryDecompose:needsDecompose(<<"">>)),
    ?assertNot(alQueryDecompose:needsDecompose(not_a_binary)).

%%--------------------------------------------------------------------
%% hasConnector/1 — 连接词检测（大小写不敏感）
%%--------------------------------------------------------------------
has_connector_chinese_test() ->
    ?assert(alQueryDecompose:hasConnector(<<"对比 A 和 B"/utf8>>)),
    ?assert(alQueryDecompose:hasConnector(<<"X 以及 Y"/utf8>>)),
    ?assert(alQueryDecompose:hasConnector(<<"为什么崩溃"/utf8>>)).

has_connector_english_test() ->
    ?assert(alQueryDecompose:hasConnector(<<"A vs B">>)),
    ?assert(alQueryDecompose:hasConnector(<<"compare A and B">>)),
    ?assert(alQueryDecompose:hasConnector(<<"A versus B">>)).

has_connector_case_insensitive_test() ->
    %% VS / Vs / vs 都应匹配
    ?assert(alQueryDecompose:hasConnector(<<"A VS B">>)),
    ?assert(alQueryDecompose:hasConnector(<<"A Vs B">>)).

has_connector_none_test() ->
    ?assertNot(alQueryDecompose:hasConnector(<<"simple question">>)),
    ?assertNot(alQueryDecompose:hasConnector(<<"start_link">>)).

%%--------------------------------------------------------------------
%% parseSubQueries/1 — 解析嵌套 JSON 数组
%%--------------------------------------------------------------------
parse_sub_queries_nested_array_test() ->
    Content = <<"[[\"cache\",\"ets\"],[\"session\",\"persist\"]]" >>,
    Result = alQueryDecompose:parseSubQueries(Content),
    ?assertEqual([[<<"cache">>, <<"ets">>], [<<"session">>, <<"persist">>]], Result).

parse_sub_queries_empty_array_test() ->
    ?assertEqual([], alQueryDecompose:parseSubQueries(<<"[]">>)).

parse_sub_queries_with_codefence_test() ->
    Content = <<"Here is the result:\n```json\n[[\"a\",\"b\"]]\n```\n">>,
    Result = alQueryDecompose:parseSubQueries(Content),
    ?assertEqual([[<<"a">>, <<"b">>]], Result).

parse_sub_queries_invalid_test() ->
    ?assertEqual([], alQueryDecompose:parseSubQueries(<<"not json">>)),
    ?assertEqual([], alQueryDecompose:parseSubQueries(<<>>)),
    ?assertEqual([], alQueryDecompose:parseSubQueries(not_a_binary)).

parse_sub_queries_flat_array_tolerated_test() ->
    %% 扁平数组（误返回）也应被容忍：每个字符串视为单关键词组
    Result = alQueryDecompose:parseSubQueries(<<"[\"foo\", \"bar\"]">>),
    ?assertEqual([[<<"foo">>], [<<"bar">>]], Result).

%%--------------------------------------------------------------------
%% dedupHits/1 — 合并去重多路命中
%%--------------------------------------------------------------------
dedup_hits_empty_test() ->
    ?assertEqual([], alQueryDecompose:dedupHits([])).

dedup_hits_no_duplicates_test() ->
    Hits = [#{file => <<"a.erl">>, module => m1, score => 0.5},
            #{file => <<"b.erl">>, module => m2, score => 0.7}],
    Result = alQueryDecompose:dedupHits(Hits),
    ?assertEqual(2, length(Result)).

dedup_hits_merges_same_file_module_test() ->
    Hit1 = #{file => <<"a.erl">>, module => m1, score => 0.5,
             functions => [#{name => f1, arity => 1}]},
    Hit2 = #{file => <<"a.erl">>, module => m1, score => 0.9,
             functions => [#{name => f2, arity => 2}]},
    Result = alQueryDecompose:dedupHits([Hit1, Hit2]),
    ?assertEqual(1, length(Result)),
    [Merged] = Result,
    ?assertEqual(0.9, maps:get(score, Merged)),
    %% functions 应合并去重
    Funs = maps:get(functions, Merged),
    ?assertEqual(2, length(Funs)).

dedup_hits_keeps_max_score_test() ->
    Hit1 = #{file => <<"a.erl">>, module => m1, score => 0.3},
    Hit2 = #{file => <<"a.erl">>, module => m1, score => 0.8},
    Hit3 = #{file => <<"a.erl">>, module => m1, score => 0.5},
    [Merged] = alQueryDecompose:dedupHits([Hit1, Hit2, Hit3]),
    ?assertEqual(0.8, maps:get(score, Merged)).

dedup_hits_non_list_test() ->
    ?assertEqual([], alQueryDecompose:dedupHits(not_a_list)).

%%--------------------------------------------------------------------
%% mergeHit/2 — 单个命中合并
%%--------------------------------------------------------------------
merge_hit_new_key_test() ->
    Hit = #{file => <<"a.erl">>, module => m1, score => 0.5},
    Acc = alQueryDecompose:mergeHit(Hit, #{}),
    ?assertMatch(#{{<<"a.erl">>, m1} := _}, Acc).

merge_hit_existing_key_test() ->
    Hit1 = #{file => <<"a.erl">>, module => m1, score => 0.5},
    Hit2 = #{file => <<"a.erl">>, module => m1, score => 0.9},
    Acc1 = alQueryDecompose:mergeHit(Hit1, #{}),
    Acc2 = alQueryDecompose:mergeHit(Hit2, Acc1),
    Merged = maps:get({<<"a.erl">>, m1}, Acc2),
    ?assertEqual(0.9, maps:get(score, Merged)).

merge_hit_different_keys_test() ->
    Hit1 = #{file => <<"a.erl">>, module => m1, score => 0.5},
    Hit2 = #{file => <<"b.erl">>, module => m2, score => 0.7},
    Acc = alQueryDecompose:mergeHit(Hit2, alQueryDecompose:mergeHit(Hit1, #{})),
    ?assertEqual(2, maps:size(Acc)).

%%--------------------------------------------------------------------
%% 缓存键语义：不同查询文本应作为独立键存储（键即查询文本 binary）
%%--------------------------------------------------------------------
cache_key_distinct_queries_test() ->
    _ = alQueryDecompose:storeCache(<<"对比 A 和 B"/utf8>>, [[<<"a">>]]),
    _ = alQueryDecompose:storeCache(<<"对比 C 和 D"/utf8>>, [[<<"c">>]]),
    %% 键为查询文本 binary 本身，无 phash2 中间层
    ?assertMatch([{<<"对比 A 和 B"/utf8>>, [[<<"a">>]], _}],
                 ets:lookup(alQueryDecomposeCache, <<"对比 A 和 B"/utf8>>)),
    ?assertMatch([{<<"对比 C 和 D"/utf8>>, [[<<"c">>]], _}],
                 ets:lookup(alQueryDecomposeCache, <<"对比 C 和 D"/utf8>>)),
    ?assertEqual(2, ets:info(alQueryDecomposeCache, size)),
    %% 同查询再次写入覆盖旧值，键不变（不新增条目）
    _ = alQueryDecompose:storeCache(<<"对比 A 和 B"/utf8>>, [[<<"a2">>]]),
    ?assertEqual(2, ets:info(alQueryDecomposeCache, size)),
    ?assertMatch([{<<"对比 A 和 B"/utf8>>, [[<<"a2">>]], _}],
                 ets:lookup(alQueryDecomposeCache, <<"对比 A 和 B"/utf8>>)).
