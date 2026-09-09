%%% @doc EUnit tests for alSemanticCache.
-module(alSemanticCache_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TestDataDir, ".eunit/semantic_cache_test").
-define(setup, begin
    ok = alConfig:load(),
    ok = alConfig:patch([{dataDir, ?TestDataDir}]),
    ok = alSemanticCache:reset()
end).
-define(cleanup, begin
    _ = file:del_dir_r(?TestDataDir),
    ok = alConfig:load()
end).
-define(LongAnswer,
    <<"这是一个用于测试语义缓存的足够长的答案文本，"
      "必须超过三十二字节才能被写入缓存。"/utf8>>).

%%%===================================================================
%%% 纯函数：normalizeQuestion / questionFingerprint
%%%===================================================================

normalize_question_token_set_test() ->
    ?assertEqual(
        lists:usort(alSemanticCache:normalizeQuestion(<<"怎么调用 alSearch？"/utf8>>)),
        lists:usort(alSemanticCache:normalizeQuestion(<<"alSearch，怎么调用"/utf8>>))).

normalize_question_filters_stopwords_and_noise_test() ->
    Tokens = alSemanticCache:normalizeQuestion(<<"How do you call the readFile tool?"/utf8>>),
    ?assertEqual([<<"call">>, <<"readfile">>, <<"tool">>],
                 lists:sort(Tokens)).

normalize_question_garbage_input_test() ->
    ?assertEqual([], alSemanticCache:normalizeQuestion(<<"!!！??"/utf8>>)),
    ?assertEqual([], alSemanticCache:normalizeQuestion(<<"?">>)),
    ?assertEqual([], alSemanticCache:normalizeQuestion(<<>>)).

fingerprint_stable_across_reorder_test() ->
    ?assertEqual(
        alSemanticCache:questionFingerprint(<<"怎么调用 alSearch？"/utf8>>),
        alSemanticCache:questionFingerprint(<<"alSearch，怎么调用"/utf8>>)),
    ?assertEqual(
        alSemanticCache:questionFingerprint("list modules and deps"),
        alSemanticCache:questionFingerprint(<<"deps and LIST modules!"/utf8>>)).

fingerprint_different_questions_differ_test() ->
    ?assertNotEqual(
        alSemanticCache:questionFingerprint(<<"如何索引代码"/utf8>>),
        alSemanticCache:questionFingerprint(<<"如何搜索代码"/utf8>>)),
    ?assertEqual(<<>>, alSemanticCache:questionFingerprint(<<"!!!"/utf8>>)).

%%%===================================================================
%%% 纯函数：isCacheableQuestion / filesFingerprint / entryValid
%%%===================================================================

cacheable_question_test() ->
    ?assert(alSemanticCache:isCacheableQuestion(<<"如何调用 alSearch？"/utf8>>)),
    ?assert(alSemanticCache:isCacheableQuestion(<<"list all modules">>)).

write_intent_not_cacheable_test() ->
    [?assertNot(alSemanticCache:isCacheableQuestion(Q))
     || Q <- [<<"修改 alAgent 的重试逻辑"/utf8>>, <<"删除这个函数"/utf8>>,
              <<"DROP TABLE users">>, <<"把超时改成 5 秒"/utf8>>,
              <<"新建一个 supervisor"/utf8>>, <<"DELETE FROM t"/utf8>>]].

files_fingerprint_test() ->
    ?assertEqual(<<>>, alSemanticCache:filesFingerprint([])),
    ?assertEqual(<<>>, alSemanticCache:filesFingerprint([<<>>, undefined])),
    ?assertEqual(<<>>, alSemanticCache:filesFingerprint(not_a_list)),
    %% 不存在的文件：missing 语义稳定，不同路径指纹不同
    Fp1 = alSemanticCache:filesFingerprint([<<"no/such/a.erl">>]),
    Fp2 = alSemanticCache:filesFingerprint([<<"no/such/b.erl">>]),
    ?assert(is_binary(Fp1) andalso byte_size(Fp1) =:= 12),
    ?assertNotEqual(Fp1, Fp2),
    %% 集合序不变（排序后哈希）
    ?assertEqual(alSemanticCache:filesFingerprint([<<"no/such/a.erl">>, <<"no/such/b.erl">>]),
                 alSemanticCache:filesFingerprint([<<"no/such/b.erl">>, <<"no/such/a.erl">>])),
    %% 真实文件：mtime 指纹（非 missing）；mtime 变则指纹变
    Anchor = writeAnchor(<<"v1">>),
    FpReal1 = alSemanticCache:filesFingerprint([Anchor]),
    ?assert(is_binary(FpReal1) andalso byte_size(FpReal1) =:= 12),
    ?assertNotEqual(FpReal1, alSemanticCache:filesFingerprint([<<"no/such/a.erl">>])),
    ok = file:change_time(Anchor, {{2099, 1, 1}, {0, 0, 0}}),
    ?assertNotEqual(FpReal1, alSemanticCache:filesFingerprint([Anchor])),
    ok = file:delete(Anchor).

entry_valid_test() ->
    Entry = #{files => [<<"a.erl">>], filesFp => <<"aaaaaaaaaaaa">>, createdAt => 1000},
    ?assert(alSemanticCache:entryValid(Entry, <<"aaaaaaaaaaaa">>, 1000 + 3600)),
    %% TTL 过期
    ?assertNot(alSemanticCache:entryValid(Entry, <<"aaaaaaaaaaaa">>, 1000 + 8 * 86400)),
    %% 指纹变化（文件被改）
    ?assertNot(alSemanticCache:entryValid(Entry, <<"bbbbbbbbbbbb">>, 1000 + 3600)),
    %% 空指纹（文件全没了）
    ?assertNot(alSemanticCache:entryValid(Entry, <<>>, 1000 + 3600)),
    %% 历史脏数据：files 为空
    ?assertNot(alSemanticCache:entryValid(#{files => [], filesFp => <<"x">>, createdAt => 1000},
                                          <<"x">>, 1000)),
    %% 非法条目
    ?assertNot(alSemanticCache:entryValid(not_a_map, <<"x">>, 0)).

%%%===================================================================
%%% lookup / put 集成
%%%===================================================================

put_then_lookup_hit_test() ->
    ?setup,
    try
        Anchor = writeAnchor(<<"v1">>),
        Q = <<"如何调用 alSearch 搜索"/utf8>>,
        ok = alSemanticCache:put(Q, ?LongAnswer, [Anchor]),
        ?assertMatch({ok, ?LongAnswer}, alSemanticCache:lookup(Q))
    after
        ?cleanup
    end.

lookup_hit_across_paraphrase_test() ->
    ?setup,
    try
        Anchor = writeAnchor(<<"v1">>),
        ok = alSemanticCache:put(<<"怎么调用 alSearch？"/utf8>>, ?LongAnswer, [Anchor]),
        %% 词序/标点/停用词变化仍命中
        ?assertMatch({ok, ?LongAnswer},
                     alSemanticCache:lookup(<<"alSearch，怎么调用？"/utf8>>)),
        %% 不同问题 miss
        ?assertEqual(miss, alSemanticCache:lookup(<<"如何编译项目"/utf8>>))
    after
        ?cleanup
    end.

lookup_invalidated_when_file_changes_test() ->
    ?setup,
    try
        Anchor = writeAnchor(<<"v1">>),
        Q = <<"如何调用 alSearch 搜索"/utf8>>,
        ok = alSemanticCache:put(Q, ?LongAnswer, [Anchor]),
        ?assertMatch({ok, _}, alSemanticCache:lookup(Q)),
        %% 改 mtime（确定性设置，不依赖秒级粒度）
        ok = file:change_time(Anchor, {{2099, 1, 1}, {0, 0, 0}}),
        ?assertEqual(miss, alSemanticCache:lookup(Q)),
        %% 失效即删除：重复 lookup 仍 miss 且不再命中旧条目
        ?assertEqual(miss, alSemanticCache:lookup(Q))
    after
        ?cleanup
    end.

put_refuses_unqualified_entries_test() ->
    ?setup,
    try
        Q = <<"如何调用 alSearch 搜索"/utf8>>,
        Anchor = writeAnchor(<<"v1">>),
        %% 无引用文件：不缓存
        ok = alSemanticCache:put(Q, ?LongAnswer, []),
        ?assertEqual(miss, alSemanticCache:lookup(Q)),
        %% 答案过短：不缓存
        ok = alSemanticCache:put(Q, <<"short">>, [Anchor]),
        ?assertEqual(miss, alSemanticCache:lookup(Q)),
        %% 写意图问题：不缓存
        ok = alSemanticCache:put(<<"修改超时配置"/utf8>>, ?LongAnswer, [Anchor]),
        ?assertEqual(miss, alSemanticCache:lookup(<<"修改超时配置"/utf8>>)),
        %% 非法形状：静默 ok
        ok = alSemanticCache:put(not_binary, ?LongAnswer, [Anchor])
    after
        ?cleanup
    end.

enabled_flag_gates_lookup_put_test() ->
    ?setup,
    try
        ?assert(alSemanticCache:enabled()),
        Anchor = writeAnchor(<<"v1">>),
        Q = <<"如何调用 alSearch 搜索"/utf8>>,
        Agent0 = alConfig:get(agent, #{}),
        ok = alConfig:patch([{agent, Agent0#{semanticCacheEnabled => false}}]),
        ?assertNot(alSemanticCache:enabled()),
        ?assertEqual(miss, alSemanticCache:lookup(Q)),
        ok = alSemanticCache:put(Q, ?LongAnswer, [Anchor]),
        ?assertEqual(miss, alSemanticCache:lookup(Q)),
        %% 开关恢复后可写入可命中
        ok = alConfig:patch([{agent, Agent0#{semanticCacheEnabled => true}}]),
        ok = alSemanticCache:put(Q, ?LongAnswer, [Anchor]),
        ?assertMatch({ok, ?LongAnswer}, alSemanticCache:lookup(Q))
    after
        ?cleanup
    end.

reset_clears_everything_test() ->
    ?setup,
    try
        Anchor = writeAnchor(<<"v1">>),
        Q = <<"如何调用 alSearch 搜索"/utf8>>,
        ok = alSemanticCache:put(Q, ?LongAnswer, [Anchor]),
        ?assertMatch({ok, _}, alSemanticCache:lookup(Q)),
        ok = alSemanticCache:reset(),
        ?assertEqual(miss, alSemanticCache:lookup(Q))
    after
        ?cleanup
    end.

%%%===================================================================
%%% 持久化：JSONL 落盘 + 懒加载重建
%%%===================================================================

persist_then_reload_after_table_loss_test() ->
    ?setup,
    try
        Anchor = writeAnchor(<<"v1">>),
        Q = <<"如何调用 alSearch 搜索"/utf8>>,
        ok = alSemanticCache:put(Q, ?LongAnswer, [Anchor]),
        ?assertMatch({ok, ?LongAnswer}, alSemanticCache:lookup(Q)),
        %% 模拟重启：ETS 表消失（owner 退出），下次 lookup 懒加载 JSONL 重建
        ets:delete(ali_semantic_cache),
        ?assertMatch({ok, ?LongAnswer}, alSemanticCache:lookup(Q))
    after
        ?cleanup
    end.

ensure_started_idempotent_test() ->
    ?setup,
    try
        ok = alSemanticCache:ensureStarted(),
        ok = alSemanticCache:ensureStarted(),
        ?assertNotEqual(undefined, ets:whereis(ali_semantic_cache))
    after
        ?cleanup
    end.

%%%===================================================================
%%% Helpers
%%%===================================================================

%% 在测试 dataDir 下建一个真实存在的锚点文件（mtime 校验需要文件存在）。
writeAnchor(Content) ->
    Path = filename:join(?TestDataDir, "anchor.erl"),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Content),
    unicode:characters_to_binary(Path).
