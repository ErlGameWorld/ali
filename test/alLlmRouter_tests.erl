%%% @doc EUnit tests for alLlmRouter — 本地+云端多模型优先级链路由器。
-module(alLlmRouter_tests).

-include_lib("eunit/include/eunit.hrl").

%% patch 链配置并执行 Fun，结束后恢复原配置。
withChainCfg(Entries, RoutingCfg, Fun) ->
    ok = alConfig:load(),
    Llm0 = alConfig:get(llm, #{}),
    Llm1 = Llm0#{chain => Entries},
    Llm = case RoutingCfg of
        undefined -> Llm1;
        _ -> Llm1#{routing => RoutingCfg}
    end,
    ok = alConfig:patch([{llm, Llm}]),
    try
        Fun()
    after
        ok = alConfig:load()
    end.

localEntry() ->
    #{id => local, provider => ollama,
      baseUrl => <<"http://127.0.0.1:11434/v1">>,
      model => <<"qwen3:14b">>, priority => 1, roles => [main, aux]}.

cloudEntry() ->
    #{id => cloud, provider => qwen,
      baseUrl => <<"https://dashscope.aliyuncs.com/compatible-mode/v1">>,
      model => <<"qwen3.8-max">>, apiKey => <<"sk-test">>,
      priority => 2, roles => [main, critic]}.

%%%===================================================================
%%% normalizeEntries / entryValid
%%%===================================================================

normalize_sorts_by_priority_test() ->
    Entries = alLlmRouter:normalizeEntries([cloudEntry(), localEntry()]),
    ?assertEqual(<<"local">>, maps:get(id, hd(Entries))),
    ?assertEqual(<<"cloud">>, maps:get(id, lists:last(Entries))).

normalize_drops_invalid_entries_test() ->
    Bad = [#{provider => qwen, model => <<"x">>},          %% 缺 baseUrl
           #{provider => qwen, baseUrl => <<"https://a">>}, %% 缺 model
           not_a_map],
    Entries = alLlmRouter:normalizeEntries(Bad),
    ?assertEqual([], Entries).

normalize_local_entry_gets_none_apiKey_test() ->
    [Entry] = alLlmRouter:normalizeEntries([localEntry()]),
    ?assertEqual(<<"none">>, maps:get(apiKey, Entry)),
    ?assertEqual(true, maps:get(local, Entry)).

normalize_local_detected_by_baseUrl_test() ->
    %% provider 未知名但 baseUrl 是 127.0.0.1 → 仍判为本地
    Entry0 = localEntry(),
    Entry = Entry0#{provider => unknownProv},
    [Normalized] = alLlmRouter:normalizeEntries([Entry]),
    ?assertEqual(true, maps:get(local, Normalized)).

normalize_cloud_entry_keeps_apiKey_test() ->
    [Entry] = alLlmRouter:normalizeEntries([cloudEntry()]),
    ?assertEqual(<<"sk-test">>, maps:get(apiKey, Entry)),
    ?assertEqual(false, maps:get(local, Entry)).

normalize_cloud_without_apiKey_dropped_test() ->
    Entry = maps:remove(apiKey, cloudEntry()),
    ?assertEqual([], alLlmRouter:normalizeEntries([Entry])).

normalize_default_roles_test() ->
    Entry0 = maps:remove(roles, localEntry()),
    [Entry] = alLlmRouter:normalizeEntries([Entry0]),
    ?assertEqual([main], maps:get(roles, Entry)).

normalize_string_roles_test() ->
    Entry0 = localEntry(),
    [Entry] = alLlmRouter:normalizeEntries([Entry0#{roles => <<"aux">>}]),
    ?assertEqual([aux], maps:get(roles, Entry)).

normalize_priority_defaults_to_order_test() ->
    %% 未配置 priority 时按配置顺序
    A = maps:remove(priority, localEntry()),
    B = maps:remove(priority, cloudEntry()),
    [First, Second] = alLlmRouter:normalizeEntries([A, B]),
    ?assertEqual(1, maps:get(priority, First)),
    ?assertEqual(2, maps:get(priority, Second)).

%%%===================================================================
%%% modelChain / chainEnabled / entryForRole / nextEntry
%%%===================================================================

chain_disabled_without_config_test() ->
    withChainCfg([], undefined, fun() ->
        ?assertEqual(false, alLlmRouter:chainEnabled()),
        ?assertEqual(undefined, alLlmRouter:entryForRole(main))
    end).

chain_enabled_with_config_test() ->
    withChainCfg([localEntry(), cloudEntry()], undefined, fun() ->
        ?assertEqual(true, alLlmRouter:chainEnabled()),
        Chain = alLlmRouter:modelChain(),
        ?assertEqual(2, length(Chain))
    end).

entryForRole_matches_role_test() ->
    withChainCfg([localEntry(), cloudEntry()], undefined, fun() ->
        {ok, Entry} = alLlmRouter:entryForRole(critic),
        ?assertEqual(<<"cloud">>, maps:get(id, Entry))
    end).

entryForRole_falls_back_to_head_test() ->
    %% 无任何项声明该角色 → 回退链首
    withChainCfg([localEntry(), cloudEntry()], undefined, fun() ->
        {ok, Entry} = alLlmRouter:entryForRole(aux),
        ?assertEqual(<<"local">>, maps:get(id, Entry))
    end).

nextEntry_returns_next_test() ->
    withChainCfg([localEntry(), cloudEntry()], undefined, fun() ->
        ?assertMatch({ok, #{id := <<"cloud">>}},
                     alLlmRouter:nextEntry(<<"local">>))
    end).

nextEntry_none_at_tail_test() ->
    withChainCfg([localEntry(), cloudEntry()], undefined, fun() ->
        ?assertEqual(none, alLlmRouter:nextEntry(<<"cloud">>))
    end).

nextEntry_atom_id_test() ->
    withChainCfg([localEntry(), cloudEntry()], undefined, fun() ->
        ?assertMatch({ok, #{id := <<"cloud">>}},
                     alLlmRouter:nextEntry(local))
    end).

firstNonLocalEntry_test() ->
    withChainCfg([localEntry(), cloudEntry()], undefined, fun() ->
        {ok, Entry} = alLlmRouter:firstNonLocalEntry(),
        ?assertEqual(<<"cloud">>, maps:get(id, Entry))
    end).

%%%===================================================================
%%% classifyTask
%%%===================================================================

classify_simple_test() ->
    ?assertEqual(simple,
        alLlmRouter:classifyTask([#{role => user, content => <<"hi">>}], [])).

classify_medium_with_tools_test() ->
    ?assertEqual(medium,
        alLlmRouter:classifyTask([#{role => user, content => <<"hi">>}],
                                 [#{name => <<"t">>}])).

classify_medium_by_length_test() ->
    Long = binary:copy(<<"a">>, 200),
    ?assertEqual(medium,
        alLlmRouter:classifyTask([#{role => user, content => Long}], [])).

classify_complex_by_keywords_test() ->
    ?assertEqual(complex,
        alLlmRouter:classifyTask(
            [#{role => user, content => <<"请帮我实现一个新功能"/utf8>>}], [])).

classify_complex_by_length_test() ->
    Long = binary:copy(<<"x">>, 500),
    ?assertEqual(complex,
        alLlmRouter:classifyTask([#{role => user, content => Long}], [])).

classify_empty_messages_test() ->
    ?assertEqual(medium, alLlmRouter:classifyTask([], [])).

%%%===================================================================
%%% suspiciousReason / refusalPatternHit
%%%===================================================================

suspicious_empty_answer_test() ->
    ?assertEqual({reason, emptyAnswer}, alLlmRouter:suspiciousReason(<<>>)),
    ?assertEqual({reason, emptyAnswer}, alLlmRouter:suspiciousReason(<<"  ">>)).

suspicious_refusal_short_test() ->
    ?assertEqual({reason, refusal},
        alLlmRouter:suspiciousReason(<<"抱歉，我无法回答这个问题。"/utf8>>)).

suspicious_ok_long_answer_test() ->
    %% 长答案即使含拒答模式也不可疑（可能只是正常提及）
    Long = binary:copy(<<"我很乐意回答。"/utf8>>, 60),
    ?assertEqual(ok, alLlmRouter:suspiciousReason(Long)).

suspicious_ok_normal_test() ->
    ?assertEqual(ok, alLlmRouter:suspiciousReason(<<"答案是这个。"/utf8>>)).

suspicious_map_answer_test() ->
    ?assertEqual({reason, emptyAnswer},
        alLlmRouter:suspiciousReason(#{content => <<>>})),
    ?assertEqual({reason, refusal},
        alLlmRouter:suspiciousReason(#{content => <<"我不知道。"/utf8>>})).

refusal_pattern_hit_test() ->
    ?assert(alLlmRouter:refusalPatternHit(<<"作为一个小模型，能力有限"/utf8>>)),
    ?assert(alLlmRouter:refusalPatternHit(<<"I don't know how to do it">>)),
    ?assertNot(alLlmRouter:refusalPatternHit(<<"答案是 42">>)).

%%%===================================================================
%%% modelFingerprint / isLocalProvider / isLocalBaseUrl
%%%===================================================================

model_fingerprint_test() ->
    ?assertEqual(<<"ollama:qwen3:14b">>,
        alLlmRouter:modelFingerprint(localEntry())),
    ?assertEqual(<<>>, alLlmRouter:modelFingerprint(not_a_map)).

is_local_provider_test() ->
    ?assert(alLlmRouter:isLocalProvider(ollama)),
    ?assert(alLlmRouter:isLocalProvider(<<"ollama">>)),
    ?assert(alLlmRouter:isLocalProvider(vllm)),
    ?assertNot(alLlmRouter:isLocalProvider(qwen)),
    ?assertNot(alLlmRouter:isLocalProvider(<<"qwen">>)),
    ?assertNot(alLlmRouter:isLocalProvider(123)).

is_local_base_url_test() ->
    ?assert(alLlmRouter:isLocalBaseUrl("http://localhost:8080/v1")),
    ?assert(alLlmRouter:isLocalBaseUrl(<<"http://127.0.0.1:11434/v1">>)),
    ?assert(alLlmRouter:isLocalBaseUrl(<<"http://192.168.1.5:8000">>)),
    ?assertNot(alLlmRouter:isLocalBaseUrl(<<"https://api.deepseek.com">>)).

%%%===================================================================
%%% questionSimilar / tokenize
%%%===================================================================

tokenize_latin_test() ->
    Tokens = alLlmRouter:tokenize(<<"Hello World 42">>, unused),
    ?assert(lists:member(<<"hello">>, Tokens)),
    ?assert(lists:member(<<"world">>, Tokens)),
    ?assert(lists:member(<<"42">>, Tokens)).

tokenize_cjk_bigrams_test() ->
    Tokens = alLlmRouter:tokenize(<<"错误日志"/utf8>>, unused),
    %% 4 个汉字 → 3 个 bigram
    ?assertEqual(3, length(Tokens)),
    ?assert(lists:member(<<"错误"/utf8>>, Tokens)).

question_similar_test() ->
    ?assert(alLlmRouter:questionSimilar(
        <<"how to fix error in module"/utf8>>,
        <<"How to FIX error in module?"/utf8>>)),
    ?assertNot(alLlmRouter:questionSimilar(
        <<"天气怎么样"/utf8>>,
        <<"如何部署服务"/utf8>>)).

%%%===================================================================
%%% routingRowMatches / bypassFromFingerprints
%%%===================================================================

routing_row_valid_test() ->
    Now = os:system_time(second),
    Row = #{metadata => #{routing => true,
                          modelFingerprint => <<"ollama:m">>,
                          symptom => <<"fix error in mod"/utf8>>},
            created_at => Now - 100},
    ?assertMatch({true, <<"ollama:m">>},
                 alLlmRouter:routingRowMatches(Row, Now, <<"fix error in mod">>)).

routing_row_expired_test() ->
    Now = os:system_time(second),
    Row = #{metadata => #{routing => true, modelFingerprint => <<"f">>},
            created_at => Now - 31 * 86400},
    ?assertEqual(false, alLlmRouter:routingRowMatches(Row, Now, <<>>)).

routing_row_no_routing_flag_test() ->
    Now = os:system_time(second),
    Row = #{metadata => #{modelFingerprint => <<"f">>},
            created_at => Now},
    ?assertEqual(false, alLlmRouter:routingRowMatches(Row, Now, <<>>)).

routing_row_dissimilar_question_test() ->
    Now = os:system_time(second),
    Row = #{metadata => #{routing => true, modelFingerprint => <<"f">>,
                          symptom => <<"deploy k8s cluster">>},
            created_at => Now},
    ?assertEqual(false,
        alLlmRouter:routingRowMatches(Row, Now, <<"今天午饭吃什么"/utf8>>)).

routing_row_binary_keys_test() ->
    %% 文件/DB 后端可能返回 binary 键
    Now = os:system_time(second),
    Meta = alJson:encode(#{routing => true, modelFingerprint => <<"fp">>,
                           symptom => <<"hello world foo">>}),
    Row = #{<<"metadata">> => Meta, <<"created_at">> => Now},
    ?assertMatch({true, <<"fp">>},
                 alLlmRouter:routingRowMatches(Row, Now, <<"hello world foo">>)).

bypass_returns_next_after_last_failed_test() ->
    [Local, Cloud] = alLlmRouter:normalizeEntries([localEntry(), cloudEntry()]),
    Fp = alLlmRouter:modelFingerprint(Local),
    %% 本地失败 → 起始模型为云端
    ?assertMatch({ok, #{id := <<"cloud">>}},
                 alLlmRouter:bypassFromFingerprints([Fp], [Local, Cloud])).

bypass_all_failed_test() ->
    [Local, Cloud] = alLlmRouter:normalizeEntries([localEntry(), cloudEntry()]),
    Fps = [alLlmRouter:modelFingerprint(Local),
           alLlmRouter:modelFingerprint(Cloud)],
    ?assertEqual(none, alLlmRouter:bypassFromFingerprints(Fps, [Local, Cloud])).

bypass_none_failed_test() ->
    [Local, Cloud] = alLlmRouter:normalizeEntries([localEntry(), cloudEntry()]),
    ?assertEqual(none, alLlmRouter:bypassFromFingerprints([], [Local, Cloud])).

%%%===================================================================
%%% mergeEntryOpts / resolveEntry
%%%===================================================================

merge_entry_opts_test() ->
    Local0 = localEntry(),
    [Local] = alLlmRouter:normalizeEntries([
        Local0#{maxRetries => 1, execTimeout => 60000}]),
    Opts = alLlmRouter:mergeEntryOpts(Local, #{foo => bar}),
    ?assertEqual(bar, maps:get(foo, Opts)),
    ?assertEqual(ollama, maps:get(provider, Opts)),
    ?assertEqual(<<"none">>, maps:get(apiKey, Opts)),
    ?assertEqual(1, maps:get(llmMaxRetries, Opts)),
    ?assertEqual(60000, maps:get(execTimeout, Opts)),
    ?assertEqual(60000, maps:get(llmTimeout, Opts)).

merge_entry_opts_without_overrides_test() ->
    [Cloud] = alLlmRouter:normalizeEntries([cloudEntry()]),
    Opts = alLlmRouter:mergeEntryOpts(Cloud, #{}),
    ?assertEqual(false, maps:is_key(llmMaxRetries, Opts)),
    ?assertEqual(false, maps:is_key(execTimeout, Opts)).

merge_entry_opts_extra_passthrough_test() ->
    %% 链项白名单额外字段（thinking 等）应透传并覆盖 Base 同名字段
    Entry0 = localEntry(),
    [Local] = alLlmRouter:normalizeEntries([
        Entry0#{thinking => disabled, temperature => 0.2}]),
    Opts = alLlmRouter:mergeEntryOpts(Local, #{thinking => enabled, foo => bar}),
    ?assertEqual(disabled, maps:get(thinking, Opts)),
    ?assertEqual(0.2, maps:get(temperature, Opts)),
    ?assertEqual(bar, maps:get(foo, Opts)).

merge_entry_opts_restrict_thinking_wins_test() ->
    %% 例外：调用方把 thinking 收紧为 disabled 时以调用方为准——
    %% 工具轮强制关思考不能被链项 extra（thinking=>enabled）覆盖回去。
    Entry0 = cloudEntry(),
    [Cloud] = alLlmRouter:normalizeEntries([
        Entry0#{thinking => enabled, temperature => 0.2}]),
    Opts = alLlmRouter:mergeEntryOpts(Cloud, #{thinking => disabled}),
    ?assertEqual(disabled, maps:get(thinking, Opts)),
    %% 非收紧字段仍按 extra 覆盖语义
    ?assertEqual(0.2, maps:get(temperature, Opts)).

merge_entry_opts_restrict_no_leak_test() ->
    %% 调用方未设 thinking 时不得凭空注入；extra 缺省时保留调用方值
    [Cloud] = alLlmRouter:normalizeEntries([cloudEntry()]),
    Opts1 = alLlmRouter:mergeEntryOpts(Cloud, #{foo => bar}),
    ?assertEqual(false, maps:is_key(thinking, Opts1)),
    Opts2 = alLlmRouter:mergeEntryOpts(Cloud, #{thinking => disabled}),
    ?assertEqual(disabled, maps:get(thinking, Opts2)).

normalize_extra_whitelist_test() ->
    %% 白名单字段保留，非白名单字段丢弃
    Entry0 = localEntry(),
    [Entry] = alLlmRouter:normalizeEntries([
        Entry0#{vision => auto, maxTokens => 4096, unknownField => keepMe}]),
    Extra = maps:get(extra, Entry, #{}),
    ?assertEqual(auto, maps:get(vision, Extra, undefined)),
    ?assertEqual(4096, maps:get(maxTokens, Extra, undefined)),
    ?assertEqual(false, maps:is_key(unknownField, Extra)).

question_from_messages_test() ->
    ?assertEqual(<<"最后一个问题"/utf8>>,
        alLlmRouter:questionFromMessages([
            #{role => user, content => <<"第一个问题"/utf8>>},
            #{role => assistant, content => <<"回答"/utf8>>},
            #{role => user, content => <<"最后一个问题"/utf8>>}
        ])),
    ?assertEqual(<<>>, alLlmRouter:questionFromMessages([])),
    ?assertEqual(<<>>,
        alLlmRouter:questionFromMessages([#{role => assistant, content => <<"x">>}])).

resolve_entry_disabled_without_chain_test() ->
    withChainCfg([], undefined, fun() ->
        ?assertEqual(disabled,
            alLlmRouter:resolveEntry([#{role => user, content => <<"hi">>}], [], #{}))
    end).

resolve_entry_pin_test() ->
    withChainCfg([localEntry(), cloudEntry()], undefined, fun() ->
        [Entry] = alLlmRouter:normalizeEntries([cloudEntry()]),
        ?assertEqual({ok, Entry},
            alLlmRouter:resolveEntry([], [], #{modelEntry => Entry}))
    end).

resolve_entry_llmPin_test() ->
    %% llmPin=true：强制走单模型路径（不做链路由）
    withChainCfg([localEntry(), cloudEntry()], undefined, fun() ->
        ?assertEqual(disabled,
            alLlmRouter:resolveEntry([], [], #{llmPin => true}))
    end).

resolve_entry_by_role_test() ->
    withChainCfg([localEntry(), cloudEntry()], undefined, fun() ->
        ?assertMatch({ok, #{id := <<"cloud">>}},
            alLlmRouter:resolveEntry([], [], #{llmRole => critic}))
    end).

resolve_entry_by_grade_test() ->
    withChainCfg([localEntry(), cloudEntry()], undefined, fun() ->
        %% simple → 链首（本地）
        ?assertMatch({ok, #{id := <<"local">>}},
            alLlmRouter:resolveEntry([#{role => user, content => <<"hi">>}], [], #{})),
        %% complex 也先从本地尝试（升级由质量兜底触发）
        ?assertMatch({ok, #{id := <<"local">>}},
            alLlmRouter:resolveEntry(
                [#{role => user, content => <<"帮我调试这个错误"/utf8>>}], [], #{}))
    end).

%%%===================================================================
%%% routeFor / 经验路由
%%%===================================================================

route_for_disabled_without_chain_test() ->
    withChainCfg([], undefined, fun() ->
        ?assertEqual(disabled, alLlmRouter:routeFor(<<"hi">>, false))
    end).

route_for_simple_starts_local_test() ->
    withChainCfg([localEntry(), cloudEntry()], undefined, fun() ->
        {ok, Entry, Info} = alLlmRouter:routeFor(<<"hi">>, false),
        ?assertEqual(<<"local">>, maps:get(id, Entry)),
        ?assertEqual(simple, maps:get(grade, Info))
    end).

route_for_complex_starts_local_test() ->
    withChainCfg([localEntry(), cloudEntry()], undefined, fun() ->
        {ok, Entry, Info} = alLlmRouter:routeFor(<<"请分析这个模块的重构方案"/utf8>>, false),
        ?assertEqual(<<"local">>, maps:get(id, Entry)),
        ?assertEqual(complex, maps:get(grade, Info))
    end).

apply_cloud_override_patches_cloud_only_test() ->
    withChainCfg([localEntry(), cloudEntry()], undefined, fun() ->
        [Local, Cloud] = alLlmRouter:modelChain(),
        Override = #{provider => deepseek, model => <<"deepseek-v4-pro">>,
                     apiKey => <<"sk-web">>},
        ?assertEqual(Local, alLlmRouter:applyCloudOverride(Local, Override)),
        Patched = alLlmRouter:applyCloudOverride(Cloud, Override),
        ?assertEqual(deepseek, maps:get(provider, Patched)),
        ?assertEqual(<<"deepseek-v4-pro">>, maps:get(model, Patched)),
        ?assertEqual(<<"sk-web">>, maps:get(apiKey, Patched))
    end).

apply_cloud_override_noop_without_chain_test() ->
    withChainCfg([], undefined, fun() ->
        Entry = #{id => <<"cloud">>, local => false, provider => qwen,
                  model => <<"m">>, apiKey => <<"k">>},
        Override = #{model => <<"other">>},
        ?assertEqual(Entry, alLlmRouter:applyCloudOverride(Entry, Override))
    end).

chain_public_info_test() ->
    withChainCfg([localEntry(), cloudEntry()], undefined, fun() ->
        Info = alLlmRouter:chainPublicInfo(),
        ?assertEqual(true, maps:get(enabled, Info)),
        ?assertMatch(#{provider := ollama}, maps:get(local, Info)),
        ?assertMatch(#{provider := qwen}, maps:get(cloud, Info))
    end).

%%%===================================================================
%%% criticThreshold / ttlSeconds
%%%===================================================================

critic_threshold_default_test() ->
    ok = alConfig:load(),
    ?assertEqual(0.5, alLlmRouter:criticThreshold()).

critic_threshold_configured_test() ->
    withChainCfg([localEntry()], #{criticThreshold => 0.8}, fun() ->
        ?assertEqual(0.8, alLlmRouter:criticThreshold())
    end).

ttl_seconds_default_test() ->
    ok = alConfig:load(),
    ?assertEqual(30 * 86400, alLlmRouter:ttlSeconds()).

ttl_seconds_configured_test() ->
    withChainCfg([localEntry()], #{ttlDays => 7}, fun() ->
        ?assertEqual(7 * 86400, alLlmRouter:ttlSeconds())
    end).

%%%===================================================================
%%% noteLocalFailure — 不崩即可（DB 不可用时静默）
%%%===================================================================

note_local_failure_no_crash_test() ->
    ok = alConfig:load(),
    ?assertEqual(ok,
        alLlmRouter:noteLocalFailure(<<"q">>, localEntry(), someReason)),
    ?assertEqual(ok,
        alLlmRouter:noteLocalFailure(<<>>, localEntry(), someReason)).
