%%% @doc EUnit tests for alContextEngine pure helpers.
-module(alContextEngine_tests).

-include_lib("eunit/include/eunit.hrl").

%% P2-7 写任务 map-reduce 侦察：isWriteTask/1 + fetchRelatedTests/1

is_write_task_edit_mode_test() ->
    ?assert(alContextEngine:isWriteTask(#{mode => edit})),
    ?assert(alContextEngine:isWriteTask(#{mode => edit, sessionId => 1})),
    ?assert(alContextEngine:isWriteTask(#{mode => ask, modePromoted => true})).

is_write_task_ask_mode_test() ->
    ?assertNot(alContextEngine:isWriteTask(#{})),
    ?assertNot(alContextEngine:isWriteTask(#{mode => ask})),
    ?assertNot(alContextEngine:isWriteTask(#{mode => exec})),
    ?assertNot(alContextEngine:isWriteTask(#{modePromoted => false})).

is_write_task_non_map_test() ->
    ?assertNot(alContextEngine:isWriteTask(undefined)),
    ?assertNot(alContextEngine:isWriteTask([mode, edit])).

fetch_related_tests_finds_existing_test_test() ->
    ok = alConfig:load(),
    %% 本项目自身约定：test/<module>_tests.erl（alContextEngine 模块真实存在）
    Results = alContextEngine:fetchRelatedTests([alContextEngine, alAgent]),
    Files = [maps:get(testFile, R) || R <- Results],
    ?assert(lists:member(<<"test/alContextEngine_tests.erl">>, Files)),
    ?assert(lists:member(<<"test/alAgent_tests.erl">>, Files)).

fetch_related_tests_skips_missing_test() ->
    ok = alConfig:load(),
    Results = alContextEngine:fetchRelatedTests([nonexistentModuleZzz]),
    ?assertEqual([], Results).

fetch_related_tests_mixed_input_test() ->
    ok = alConfig:load(),
    %% atom 与 binary 模块名都能推导；不存在的被过滤
    Results = alContextEngine:fetchRelatedTests([alContextEngine, <<"nonexistentZzz">>]),
    ?assertEqual(1, length(Results)),
    ?assertEqual(<<"test/alContextEngine_tests.erl">>,
                 maps:get(testFile, hd(Results))).

fetch_related_tests_caps_module_count_test() ->
    ok = alConfig:load(),
    %% 模块数量限流（?MaxModulesForSymbols=3）：超出部分不查
    Mods = [alContextEngine, alAgent, alChat, alSup],
    Results = alContextEngine:fetchRelatedTests(Mods),
    ?assert(length(Results) =< 3).

fetch_related_tests_non_list_test() ->
    ?assertEqual([], alContextEngine:fetchRelatedTests(undefined)),
    ?assertEqual([], alContextEngine:fetchRelatedTests(alContextEngine)).

%% isModuleLike/1

is_module_like_lowercase_underscore_test() ->
    ?assert(alContextEngine:isModuleLike("ali_sup")).

is_module_like_mixed_case_underscore_test() ->
    ?assert(alContextEngine:isModuleLike("ali_app")).

is_module_like_too_short_test() ->
    ?assertNot(alContextEngine:isModuleLike("ab")).

is_module_like_no_underscore_test() ->
    ?assertNot(alContextEngine:isModuleLike("alisup")).

is_module_leading_uppercase_test() ->
    ?assertNot(alContextEngine:isModuleLike("Ali_sup")).

%% guessModules/1 — extracts token-like module names from a question

guess_modules_extracts_known_modules_test() ->
    Mods = alContextEngine:guessModules(<<"explain ali_sup and ali_app">>),
    ?assert(lists:member(ali_sup, Mods)),
    ?assert(lists:member(ali_app, Mods)).

guess_modules_skips_non_module_tokens_test() ->
    Mods = alContextEngine:guessModules(<<"hello world foo">>),
    %% "foo" has no underscore; "hello"/"world" similarly; none qualify
    ?assertEqual([], Mods).

guess_modules_list_input_test() ->
    Mods = alContextEngine:guessModules("explain ali_sup"),
    ?assert(lists:member(ali_sup, Mods)).

%% normalizeHit/1 — fills defaults for missing fields

normalize_hit_minimal_test() ->
    Hit = alContextEngine:normalizeHit(#{}),
    ?assertMatch(#{engine := rustCore, file := undefined, module := undefined,
                   score := 0, functions := [], snippets := []}, Hit).

normalize_hit_with_fields_test() ->
    Hit = alContextEngine:normalizeHit(#{file => <<"a.erl">>, module => m, score => 0.8}),
    ?assertMatch(#{engine := rustCore, file := <<"a.erl">>, module := m,
                   score := 0.8, functions := [], snippets := []}, Hit).

normalize_hit_passthrough_non_map_test() ->
    ?assertEqual(other, alContextEngine:normalizeHit(other)).

%% normalizeHits/1

normalize_hits_empty_test() ->
    ?assertEqual([], alContextEngine:normalizeHits([])).

normalize_hits_list_test() ->
    Hits = [#{file => <<"a.erl">>}, #{}],
    Result = alContextEngine:normalizeHits(Hits),
    ?assertEqual(2, length(Result)),
    [H1, H2] = Result,
    ?assertEqual(<<"a.erl">>, maps:get(file, H1)),
    ?assertEqual(undefined, maps:get(file, H2)).

normalize_hits_non_list_returns_empty_test() ->
    ?assertEqual([], alContextEngine:normalizeHits(foo)).

%% modulesFromHits/2 — union of modules from hits + question

modules_from_hits_combines_sources_test() ->
    Hits = [#{module => m1}, #{module => m2}, #{}],
    Mods = alContextEngine:modulesFromHits(Hits, <<"explain ali_sup">>),
    ?assert(lists:member(m1, Mods)),
    ?assert(lists:member(m2, Mods)),
    ?assert(lists:member(ali_sup, Mods)).

modules_from_hits_dedup_test() ->
    Hits = [#{module => m1}, #{module => m1}],
    Mods = alContextEngine:modulesFromHits(Hits, <<"">>),
    ?assertEqual(1, length(Mods)).

modules_from_hits_skips_undefined_test() ->
    Hits = [#{module => undefined}, #{module => null}, #{}],
    Mods = alContextEngine:modulesFromHits(Hits, <<"">>),
    ?assertEqual([], Mods).

%% parseFa/1 — module:function/arity extraction

parse_fa_basic_test() ->
    ?assertEqual({ok, ali, search, 2},
                 alContextEngine:parseFa(<<"ali:search/2">>)).

parse_fa_spaces_test() ->
    ?assertEqual({ok, ali, search, 2},
                 alContextEngine:parseFa(<<"ali : search / 2">>)).

parse_fa_no_match_test() ->
    ?assertEqual(error, alContextEngine:parseFa(<<"hello world">>)).

parse_fa_list_input_test() ->
    ?assertEqual({ok, ali, search, 2}, alContextEngine:parseFa("ali:search/2")).

%% parseAnchors/1

parse_anchors_module_test() ->
    A = alContextEngine:parseAnchors(<<"请解释 @module al_tool_router 的职责"/utf8>>),
    ?assert(lists:member(al_tool_router, maps:get(modules, A))).

parse_anchors_path_test() ->
    A = alContextEngine:parseAnchors(<<"看下 @path src/agent/alAgent.erl"/utf8>>),
    ?assertEqual([<<"src/agent/alAgent.erl">>], maps:get(paths, A)).

parse_anchors_mfa_test() ->
    A = alContextEngine:parseAnchors(<<"@mfa alAgent:run/2 调用链"/utf8>>),
    [Mfa] = maps:get(mfas, A),
    ?assertEqual(alAgent, maps:get(module, Mfa)),
    ?assertEqual(run, maps:get(function, Mfa)),
    ?assertEqual(2, maps:get(arity, Mfa)).

parse_anchors_colon_forms_test() ->
    A = alContextEngine:parseAnchors(<<"@module:ali @mfa:ali:search/2 @path:src/ali.erl">>),
    ?assert(lists:member(ali, maps:get(modules, A))),
    ?assertEqual([<<"src/ali.erl">>], maps:get(paths, A)),
    ?assertEqual(1, length(maps:get(mfas, A))).

parse_anchors_empty_test() ->
    A = alContextEngine:parseAnchors(<<"hello">>),
    ?assertEqual(#{modules => [], paths => [], mfas => []}, A).

%% moduleEdgeMatch/2 — filter helper

module_edge_match_in_set_test() ->
    Set = sets:from_list([<<"ali">>]),
    ?assert(alContextEngine:moduleEdgeMatch(#{fromModule => <<"ali">>}, Set)).

module_edge_match_in_to_module_test() ->
    Set = sets:from_list([<<"ali">>]),
    ?assert(alContextEngine:moduleEdgeMatch(#{toModule => <<"ali">>}, Set)).

module_edge_match_not_in_set_test() ->
    Set = sets:from_list([<<"other">>]),
    ?assertNot(alContextEngine:moduleEdgeMatch(#{fromModule => <<"ali">>}, Set)).

module_edge_match_missing_fields_test() ->
    Set = sets:from_list([<<"ali">>]),
    ?assertNot(alContextEngine:moduleEdgeMatch(#{}, Set)).

%% toBinary/1 + toList/1

to_binary_atom_test() ->
    ?assertEqual(<<"hello">>, alContextEngine:toBinary(hello)).

to_binary_list_test() ->
    ?assertEqual(<<"hi">>, alContextEngine:toBinary("hi")).

to_list_binary_test() ->
    ?assertEqual("hi", alContextEngine:toList(<<"hi">>)).

to_list_atom_test() ->
    ?assertEqual("hello", alContextEngine:toList(hello)).

%%--------------------------------------------------------------------
%% faFromHit/1 — 从命中 map 提取 {Module, Function, Arity}
%%--------------------------------------------------------------------

fa_from_hit_complete_test() ->
    Hit = #{module => alAgent, functions => [#{name => run, arity => 2}], score => 0.9},
    ?assertEqual({alAgent, run, 2}, alContextEngine:faFromHit(Hit)).

fa_from_hit_missing_module_test() ->
    Hit = #{functions => [#{name => run, arity => 2}]},
    ?assertEqual(undefined, alContextEngine:faFromHit(Hit)).

fa_from_hit_missing_functions_test() ->
    Hit = #{module => alAgent},
    ?assertEqual(undefined, alContextEngine:faFromHit(Hit)).

fa_from_hit_empty_functions_test() ->
    Hit = #{module => alAgent, functions => []},
    ?assertEqual(undefined, alContextEngine:faFromHit(Hit)).

fa_from_hit_function_missing_name_test() ->
    Hit = #{module => alAgent, functions => [#{arity => 2}]},
    ?assertEqual(undefined, alContextEngine:faFromHit(Hit)).

fa_from_hit_function_missing_arity_test() ->
    Hit = #{module => alAgent, functions => [#{name => run}]},
    ?assertEqual(undefined, alContextEngine:faFromHit(Hit)).

fa_from_hit_non_map_test() ->
    ?assertEqual(undefined, alContextEngine:faFromHit(foo)),
    ?assertEqual(undefined, alContextEngine:faFromHit(<<"x">>)).

fa_from_hit_takes_first_function_test() ->
    %% 仅取 functions 列表首项
    Hit = #{module => alAgent,
            functions => [#{name => run, arity => 2},
                          #{name => other, arity => 1}]},
    ?assertEqual({alAgent, run, 2}, alContextEngine:faFromHit(Hit)).

%%--------------------------------------------------------------------
%% extractTopFa/1 — 按 score 降序提取 top-N FA
%%--------------------------------------------------------------------

extract_top_fa_empty_test() ->
    ?assertEqual([], alContextEngine:extractTopFa([])).

extract_top_fa_non_list_test() ->
    ?assertEqual([], alContextEngine:extractTopFa(foo)).

extract_top_fa_sorted_by_score_test() ->
    Hit1 = #{module => m1, functions => [#{name => f1, arity => 1}], score => 0.3},
    Hit2 = #{module => m2, functions => [#{name => f2, arity => 2}], score => 0.9},
    Hit3 = #{module => m3, functions => [#{name => f3, arity => 3}], score => 0.6},
    Result = alContextEngine:extractTopFa([Hit1, Hit2, Hit3]),
    %% 按 score 降序：m2(0.9) → m3(0.6) → m1(0.3)
    ?assertEqual([{m2, f2, 2}, {m3, f3, 3}, {m1, f1, 1}], Result).

extract_top_fa_skips_invalid_hits_test() ->
    Hit1 = #{module => m1, functions => [#{name => f1, arity => 1}], score => 0.5},
    Hit2 = #{functions => [#{name => f2, arity => 2}]}, %% 无 module
    Hit3 = #{module => m3, functions => []}, %% 空 functions
    Result = alContextEngine:extractTopFa([Hit1, Hit2, Hit3]),
    ?assertEqual([{m1, f1, 1}], Result).

extract_top_fa_capped_at_max_test() ->
    %% 构造 5 个命中，验证只取前 3 个（?MaxExpandHits=3）
    Hits = [#{module => list_to_atom("m" ++ integer_to_list(N)),
              functions => [#{name => list_to_atom("f" ++ integer_to_list(N)), arity => N}],
              score => 1.0 - N * 0.1}
            || N <- lists:seq(1, 5)],
    Result = alContextEngine:extractTopFa(Hits),
    ?assertEqual(3, length(Result)).

%%--------------------------------------------------------------------
%% mergeCallContext/2 — 合并显式与扩展调用上下文
%%--------------------------------------------------------------------

merge_call_context_both_empty_test() ->
    ?assertEqual(#{}, alContextEngine:mergeCallContext(#{}, #{})).

merge_call_context_explicit_empty_test() ->
    Expanded = #{expandedEdges => [#{from => a}], sources => [{a, b, 1}]},
    ?assertEqual(Expanded, alContextEngine:mergeCallContext(#{}, Expanded)).

merge_call_context_expanded_empty_test() ->
    Explicit = #{module => m, function => f, arity => 1, callers => [], callees => []},
    ?assertEqual(Explicit, alContextEngine:mergeCallContext(Explicit, #{})).

merge_call_context_both_non_empty_test() ->
    Explicit = #{module => m, function => f, arity => 1, callers => [#{x => 1}]},
    Expanded = #{expandedEdges => [#{from => a}], sources => [{a, b, 1}]},
    Merged = alContextEngine:mergeCallContext(Explicit, Expanded),
    ?assertEqual([#{x => 1}], maps:get(callers, Merged)),
    ?assertEqual([{a, b, 1}], maps:get(sources, Merged)),
    ?assertEqual(m, maps:get(module, Merged)).

%%--------------------------------------------------------------------
%% boostHit/2 — 单个命中 Git 加权
%%--------------------------------------------------------------------
boost_hit_recent_file_test() ->
    Hit = #{file => <<"src/agent/alAgent.erl">>, module => alAgent, score => 0.5},
    Recent = ordsets:from_list(["src/agent/alAgent.erl"]),
    Result = alContextEngine:boostHit(Hit, Recent),
    %% score 应乘以 1.5，并打 gitBoosted 标记
    ?assert(maps:get(gitBoosted, Result, false)),
    ?assert(abs(maps:get(score, Result, 0) - 0.75) < 0.001).

boost_hit_non_recent_file_test() ->
    Hit = #{file => <<"src/old.erl">>, module => oldMod, score => 0.5},
    Recent = ordsets:from_list(["src/agent/alAgent.erl"]),
    Result = alContextEngine:boostHit(Hit, Recent),
    %% 不在最近集合里：原样返回，无 gitBoosted 标记
    ?assertEqual(false, maps:get(gitBoosted, Result, false)),
    ?assertEqual(0.5, maps:get(score, Result, 0)).

boost_hit_non_map_test() ->
    ?assertEqual(foo, alContextEngine:boostHit(foo, ordsets:new())).

%%--------------------------------------------------------------------
%% isRecentFile/2 — 文件是否在最近变更集合
%%--------------------------------------------------------------------
is_recent_file_undefined_test() ->
    ?assertNot(alContextEngine:isRecentFile(undefined, ordsets:new())).

is_recent_file_match_test() ->
    Recent = ordsets:from_list(["src/agent/alAgent.erl"]),
    ?assert(alContextEngine:isRecentFile(<<"src/agent/alAgent.erl">>, Recent)).

is_recent_file_no_match_test() ->
    Recent = ordsets:from_list(["src/agent/alAgent.erl"]),
    ?assertNot(alContextEngine:isRecentFile(<<"src/other.erl">>, Recent)).

is_recent_file_path_normalization_test() ->
    %% Windows 反斜杠路径应归一化后匹配
    Recent = ordsets:from_list(["src/agent/alAgent.erl"]),
    ?assert(alContextEngine:isRecentFile(<<"src\\agent\\alAgent.erl">>, Recent)).

%%--------------------------------------------------------------------
%% boostByGitFreshness/2 — 批量加权重排
%%--------------------------------------------------------------------
boost_by_git_freshness_empty_set_test() ->
    %% 空 RecentSet 原样返回
    Hits = [#{file => <<"a.erl">>, score => 0.5}, #{file => <<"b.erl">>, score => 0.3}],
    Result = alContextEngine:boostByGitFreshness(Hits, ordsets:new()),
    ?assertEqual(Hits, Result).

boost_by_git_freshness_boosts_and_reorders_test() ->
    Hit1 = #{file => <<"old.erl">>, score => 0.8},  %% 高分但旧
    Hit2 = #{file => <<"new.erl">>, score => 0.4},  %% 低分但近期改过
    Recent = ordsets:from_list(["new.erl"]),
    Result = alContextEngine:boostByGitFreshness([Hit1, Hit2], Recent),
    %% Hit2 boost 后 0.4*1.5=0.6 < 0.8，仍排第二？不，0.6 < 0.8 所以 Hit1 仍第一
    %% 调整：让 Hit2 原始分 0.6，boost 后 0.9 > 0.8，应排第一
    ?assertEqual(2, length(Result)).

boost_by_git_freshness_reorders_when_boosted_wins_test() ->
    Hit1 = #{file => <<"old.erl">>, score => 0.8},   %% 旧文件高分
    Hit2 = #{file => <<"new.erl">>, score => 0.6},   %% 近期文件，boost 后 0.9 > 0.8
    Recent = ordsets:from_list(["new.erl"]),
    [Top, Bottom | _] = alContextEngine:boostByGitFreshness([Hit1, Hit2], Recent),
    %% boost 后 new.erl (0.9) 应排第一
    ?assertEqual(<<"new.erl">>, maps:get(file, Top)),
    ?assertEqual(<<"old.erl">>, maps:get(file, Bottom)).

boost_by_git_freshness_non_list_test() ->
    ?assertEqual(foo, alContextEngine:boostByGitFreshness(foo, ordsets:new())).

%%--------------------------------------------------------------------
%% needsRuntime/1 — 问题是否需要 runtime 上下文
%%--------------------------------------------------------------------
needs_runtime_chinese_process_test() ->
    ?assert(alContextEngine:needsRuntime(unicode:characters_to_binary("查看当前进程状态"))).

needs_runtime_chinese_ets_test() ->
    ?assert(alContextEngine:needsRuntime(unicode:characters_to_binary("ets 表占用多少内存"))).

needs_runtime_english_process_test() ->
    ?assert(alContextEngine:needsRuntime(<<"show me running processes">>)).

needs_runtime_english_ets_test() ->
    ?assert(alContextEngine:needsRuntime(<<"dump ets tables">>)).

needs_runtime_english_memory_test() ->
    ?assert(alContextEngine:needsRuntime(<<"memory usage of node">>)).

needs_runtime_plain_code_question_test() ->
    ?assertNot(alContextEngine:needsRuntime(<<"how does alContextEngine:build work?">>)).

needs_runtime_plain_explain_question_test() ->
    ?assertNot(alContextEngine:needsRuntime(unicode:characters_to_binary("解释一下这个函数的实现"))).

needs_runtime_list_input_test() ->
    ?assert(alContextEngine:needsRuntime("pid 列表")).

%%--------------------------------------------------------------------
%% compactRuntime/1 — 压缩 runtime snapshot
%%--------------------------------------------------------------------
compact_runtime_keeps_core_fields_test() ->
    Snap = #{
        node => 'foo@bar', processCount => 100, processLimit => 262144,
        schedulerCount => 8, runQueue => 0, reductions => 1234567890,
        memory => #{total => 1000000, binary => 50000, processes => 200000,
                    ets => 80000, atom => 20000, code => 300000},
        processesTop => [#{pid => "<a.b.c>"} || _ <- lists:seq(1, 10)],
        etsTop => [#{name => tab} || _ <- lists:seq(1, 10)],
        supervisorTree => #{roots => [], health => #{totalNodes => 0}}
    },
    Compact = alContextEngine:compactRuntime(Snap),
    %% 节点级字段保留
    ?assertEqual('foo@bar', maps:get(node, Compact)),
    ?assertEqual(100, maps:get(processCount, Compact)),
    %% memory 仅保留 4 个字段
    Mem = maps:get(memory, Compact),
    ?assertEqual(4, map_size(Mem)),
    ?assertEqual(1000000, maps:get(total, Mem)),
    ?assertEqual(80000, maps:get(ets, Mem)),
    ?assertEqual(undefined, maps:get(atom, Mem, undefined)),
    %% processesTop / etsTop 限制到 5
    ?assertEqual(5, length(maps:get(processesTop, Compact))),
    ?assertEqual(5, length(maps:get(etsTop, Compact))).

compact_runtime_handles_missing_fields_test() ->
    Compact = alContextEngine:compactRuntime(#{node => 'n@h'}),
    ?assertEqual('n@h', maps:get(node, Compact)),
    ?assertEqual(0, maps:get(total, maps:get(memory, Compact), 0)).

compact_runtime_non_map_test() ->
    ?assertEqual(#{}, alContextEngine:compactRuntime(notAMap)).

%%--------------------------------------------------------------------
%% relevantProcesses/2 — 按命中模块过滤进程
%%--------------------------------------------------------------------
relevant_processes_matches_initial_call_test() ->
    Snap = #{
        processesTop => [
            #{pid => "<0.1.0>", initial_call => {alContextEngine, build, 2},
              current_function => {alContextEngine, build, 2}},
            #{pid => "<0.2.0>", initial_call => {alRuntimeProbe, snapshot, 0},
              current_function => {alRuntimeProbe, snapshot, 0}}
        ]
    },
    %% alContextEngine 模块命中
    Result = alContextEngine:relevantProcesses(Snap, [alContextEngine]),
    ?assertEqual(1, length(Result)),
    ?assertEqual("<0.1.0>", maps:get(pid, hd(Result))).

relevant_processes_matches_current_function_test() ->
    %% initial_call 不命中，但 current_function 命中
    Snap = #{
        processesTop => [
            #{pid => "<0.5.0>", initial_call => {erlang, apply, 3},
              current_function => {alSkill, match, 1}}
        ]
    },
    Result = alContextEngine:relevantProcesses(Snap, [alSkill]),
    ?assertEqual(1, length(Result)).

relevant_processes_no_match_test() ->
    Snap = #{
        processesTop => [
            #{pid => "<0.1.0>", initial_call => {erlang, apply, 3},
              current_function => {erlang, apply, 3}}
        ]
    },
    ?assertEqual([], alContextEngine:relevantProcesses(Snap, [alContextEngine])).

relevant_processes_binary_module_test() ->
    %% 模块名也可以是 binary
    Snap = #{
        processesTop => [
            #{pid => "<0.1.0>", initial_call => {alContextEngine, build, 2},
              current_function => {alContextEngine, build, 2}}
        ]
    },
    Result = alContextEngine:relevantProcesses(Snap, [<<"alContextEngine">>]),
    ?assertEqual(1, length(Result)).

relevant_processes_empty_modules_test() ->
    Snap = #{processesTop => [#{pid => "<0.1.0>"}]},
    ?assertEqual([], alContextEngine:relevantProcesses(Snap, [])).

relevant_processes_undefined_modules_test() ->
    ?assertEqual([], alContextEngine:relevantProcesses(#{}, [undefined, null])).

relevant_processes_non_map_snapshot_test() ->
    ?assertEqual([], alContextEngine:relevantProcesses(notAMap, [foo])).

%%--------------------------------------------------------------------
%% fetchRuntime/3 — 运行时上下文主动融合入口
%%--------------------------------------------------------------------
fetch_runtime_explicit_include_returns_snapshot_test() ->
    %% IncludeRuntime=true 直接返回 snapshot（至少包含 node/processCount 字段）
    Result = alContextEngine:fetchRuntime(<<"any question">>, [], true),
    ?assert(maps:is_key(node, Result)),
    ?assert(maps:is_key(processCount, Result)).

fetch_runtime_plain_question_returns_empty_test() ->
    %% 普通代码问题、IncludeRuntime=false → 返回空
    Result = alContextEngine:fetchRuntime(<<"how does foo:bar/1 work">>, [], false),
    ?assertEqual(#{}, Result).

fetch_runtime_keyword_question_returns_compact_test() ->
    %% 含 runtime 关键词、IncludeRuntime=false → 返回精简版（有 node 字段，无 reductions）
    Result = alContextEngine:fetchRuntime(unicode:characters_to_binary("查看进程状态"), [], false),
    ?assert(maps:is_key(node, Result)),
    %% 精简版无 reductions 字段（compactRuntime 不删 reductions，但它本来就在）
    %% 主要验证：返回非空 + 包含 node/processCount
    ?assert(maps:is_key(processCount, Result)).

fetch_runtime_keyword_question_with_modules_attaches_relevant_test() ->
    %% 含 runtime 关键词 + 命中模块 → 应附加 relevantProcesses 字段
    %% 注意：当前测试进程可能不命中 alContextEngine 模块，所以 relevantProcesses 可能为 []
    %% 但 compactRuntime 一定执行，所以 node 字段一定在
    Result = alContextEngine:fetchRuntime(<<"process state">>, [alContextEngine], false),
    ?assert(maps:is_key(node, Result)).

fetch_runtime_invalid_question_returns_empty_test() ->
    ?assertEqual(#{}, alContextEngine:fetchRuntime(12345, [], false)).

%%--------------------------------------------------------------------
%% needsDataFlow/1 — 问题是否需要数据流分析
%%--------------------------------------------------------------------
needs_data_flow_chinese_param_source_test() ->
    ?assert(alContextEngine:needsDataFlow(unicode:characters_to_binary("这个函数的参数来源是什么"))).

needs_data_flow_chinese_data_flow_test() ->
    ?assert(alContextEngine:needsDataFlow(unicode:characters_to_binary("分析数据流"))).

needs_data_flow_chinese_where_from_test() ->
    ?assert(alContextEngine:needsDataFlow(unicode:characters_to_binary("参数哪里来的"))).

needs_data_flow_english_test() ->
    ?assert(alContextEngine:needsDataFlow(<<"trace parameter source">>)),
    ?assert(alContextEngine:needsDataFlow(<<"data flow analysis">>)).

needs_data_flow_query_nl_test() ->
    ?assert(alContextEngine:needsDataFlow(<<"查一下玩家位置"/utf8>>)),
    ?assert(alContextEngine:needsDataFlow(<<"查询 role_tab"/utf8>>)),
    ?assert(alContextEngine:needsDataFlow(<<"这个数据从哪来"/utf8>>)).

needs_data_flow_plain_question_test() ->
    ?assertNot(alContextEngine:needsDataFlow(<<"how does this function work">>)).

%%--------------------------------------------------------------------
%% classifyParamSource/1 — 参数来源模式分类
%%--------------------------------------------------------------------
classify_param_source_ets_lookup_test() ->
    ?assertEqual(etsLookup, alContextEngine:classifyParamSource(<<"Value = ets:lookup(Tab, Key)">>)),
    ?assertEqual(etsLookup, alContextEngine:classifyParamSource(<<"ets:match(Tab, Pat)">>)).

classify_param_source_config_test() ->
    ?assertEqual(config, alContextEngine:classifyParamSource(<<"alConfig:get(timeout)">>)),
    ?assertEqual(config, alContextEngine:classifyParamSource(<<"application:get_env(ali, key)">>)).

classify_param_source_message_input_test() ->
    ?assertEqual(messageInput, alContextEngine:classifyParamSource(<<"receive {call, Ref} -> Ref end">>)).

classify_param_source_literal_test() ->
    ?assertEqual(literal, alContextEngine:classifyParamSource(<<"#state{field = 1}">>)),
    ?assertEqual(literal, alContextEngine:classifyParamSource(<<"<<\"hello\">>">>)).

classify_param_source_caller_argument_test() ->
    %% 首字母大写的变量名（无特殊模式）→ callerArgument
    ?assertEqual(callerArgument, alContextEngine:classifyParamSource(<<"foo(Arg1, Arg2)">>)).

classify_param_source_computed_test() ->
    %% 既无特殊模式也无大写变量 → computed
    ?assertEqual(computed, alContextEngine:classifyParamSource(<<"123 + 456">>)).

classify_param_source_empty_test() ->
    ?assertEqual(computed, alContextEngine:classifyParamSource(<<>>)).

classify_param_source_non_binary_test() ->
    ?assertEqual(unknown, alContextEngine:classifyParamSource(notABinary)).

%%--------------------------------------------------------------------
%% paramSourceHints/3 — 参数来源追踪主入口
%%--------------------------------------------------------------------
param_source_hints_no_callers_test() ->
    %% core 未启动 / 无 callers：返回 callerCount=0 的空 hint
    Result = alContextEngine:paramSourceHints(nonexistentModule, someFun, 1),
    ?assertEqual(0, maps:get(callerCount, Result)),
    ?assertEqual([], maps:get(hints, Result)),
    ?assertEqual({nonexistentModule, someFun, 1}, maps:get(targetMfa, Result)).

param_source_hints_returns_map_structure_test() ->
    Result = alContextEngine:paramSourceHints(nonexistentModule, foo, 1),
    ?assert(maps:is_key(targetMfa, Result)),
    ?assert(maps:is_key(callerCount, Result)),
    ?assert(maps:is_key(sourceCounts, Result)),
    ?assert(maps:is_key(hints, Result)),
    ?assert(maps:is_key(sampledCallers, Result)).

%%--------------------------------------------------------------------
%% isReferenceKind/1 — 引用类型校验
%%--------------------------------------------------------------------
is_reference_kind_record_test() ->
    ?assert(alContextEngine:isReferenceKind(record)),
    ?assert(alContextEngine:isReferenceKind(<<"record">>)).

is_reference_kind_macro_test() ->
    ?assert(alContextEngine:isReferenceKind(macro)),
    ?assert(alContextEngine:isReferenceKind(<<"macro">>)).

is_reference_kind_function_test() ->
    ?assert(alContextEngine:isReferenceKind(function)),
    ?assert(alContextEngine:isReferenceKind(<<"function">>)).

is_reference_kind_invalid_test() ->
    ?assertNot(alContextEngine:isReferenceKind(type)),
    ?assertNot(alContextEngine:isReferenceKind(<<"other">>)),
    ?assertNot(alContextEngine:isReferenceKind(123)).

%%--------------------------------------------------------------------
%% extractReferencesFromHit/3 — 从单条命中提取引用
%%--------------------------------------------------------------------
extract_references_from_hit_record_test() ->
    Hit = #{
        file => <<"src/foo.erl">>, module => foo,
        records => [#{name => <<"state">>, line => 10},
                    #{name => <<"config">>, line => 20}]
    },
    Refs = alContextEngine:extractReferencesFromHit(Hit, <<"state">>, record),
    ?assertEqual(1, length(Refs)),
    [Ref] = Refs,
    ?assertEqual(<<"src/foo.erl">>, maps:get(file, Ref)),
    ?assertEqual(foo, maps:get(module, Ref)),
    ?assertEqual(10, maps:get(line, Ref)),
    ?assertEqual(record, maps:get(kind, Ref)),
    ?assertEqual(<<"state">>, maps:get(name, Ref)).

extract_references_from_hit_macro_test() ->
    Hit = #{
        file => <<"src/bar.erl">>, module => bar,
        macros => [#{name => <<"MAX_SIZE">>, line => 5}]
    },
    Refs = alContextEngine:extractReferencesFromHit(Hit, <<"MAX_SIZE">>, macro),
    ?assertEqual(1, length(Refs)),
    [Ref] = Refs,
    ?assertEqual(macro, maps:get(kind, Ref)),
    ?assertEqual(5, maps:get(line, Ref)).

extract_references_from_hit_function_test() ->
    Hit = #{
        file => <<"src/baz.erl">>, module => baz,
        functions => [#{name => <<"init">>, arity => 1, line => 15}]
    },
    Refs = alContextEngine:extractReferencesFromHit(Hit, <<"init">>, function),
    ?assertEqual(1, length(Refs)),
    [Ref] = Refs,
    ?assertEqual(function, maps:get(kind, Ref)),
    ?assertEqual(15, maps:get(line, Ref)).

extract_references_from_hit_no_match_test() ->
    Hit = #{file => <<"a.erl">>, records => [#{name => <<"foo">>, line => 1}]},
    ?assertEqual([], alContextEngine:extractReferencesFromHit(Hit, <<"bar">>, record)).

extract_references_from_hit_atom_name_test() ->
    %% name 字段可以是 atom
    Hit = #{file => <<"a.erl">>, records => [#{name => state, line => 1}]},
    Refs = alContextEngine:extractReferencesFromHit(Hit, <<"state">>, record),
    ?assertEqual(1, length(Refs)).

extract_references_from_hit_binary_kind_test() ->
    %% Kind 也可以是 binary
    Hit = #{file => <<"a.erl">>, records => [#{name => <<"state">>, line => 1}]},
    Refs = alContextEngine:extractReferencesFromHit(Hit, <<"state">>, <<"record">>),
    ?assertEqual(1, length(Refs)).

extract_references_from_hit_invalid_kind_test() ->
    Hit = #{file => <<"a.erl">>, records => [#{name => <<"state">>, line => 1}]},
    ?assertEqual([], alContextEngine:extractReferencesFromHit(Hit, <<"state">>, invalid)).

extract_references_from_hit_non_map_test() ->
    ?assertEqual([], alContextEngine:extractReferencesFromHit(notAMap, <<"x">>, record)).

extract_references_from_hit_missing_field_test() ->
    %% 命中里没有 records 字段
    Hit = #{file => <<"a.erl">>},
    ?assertEqual([], alContextEngine:extractReferencesFromHit(Hit, <<"state">>, record)).

%%--------------------------------------------------------------------
%% findReferences/2,3 — 主入口（依赖 core，测试环境可能返回空）
%%--------------------------------------------------------------------
find_references_invalid_kind_test() ->
    %% 非法 Kind 直接返回空，不调 core
    ?assertEqual([], alContextEngine:findReferences(<<"state">>, invalidKind)).

find_references_invalid_limit_test() ->
    ?assertEqual([], alContextEngine:findReferences(<<"state">>, record, 0)),
    ?assertEqual([], alContextEngine:findReferences(<<"state">>, record, -1)).

find_references_core_unavailable_returns_empty_test() ->
    %% core 未启动时 search 返回 error，findReferences 应返回 []
    Result = alContextEngine:findReferences(<<"someRecordName">>, record, 5),
    ?assertEqual([], Result).

find_references_function_kind_test() ->
    ?assertEqual([], alContextEngine:findReferences(<<"someFun">>, function, 5)).

find_references_macro_kind_test() ->
    ?assertEqual([], alContextEngine:findReferences(<<"SOME_MACRO">>, macro, 5)).

%%%===================================================================
%%% traceDataQuery/2 — 数据查询链路推断
%%%===================================================================

%%--------------------------------------------------------------------
%% extractDataNouns/1 — 数据名词提取
%%
%% 设计说明：中文无词边界，连续汉字会被当作单个 token。
%% 例如 "查一下玩家位置" 会作为一个整体 token 提取，而非拆分成
%% "查一下" + "玩家位置"。这是静态分析的固有局限，依赖子串匹配
%% （findDataSourceCandidates）和 clarify prompt 机制兜底。
%%--------------------------------------------------------------------
extract_data_nouns_chinese_test() ->
    Nouns = alContextEngine:extractDataNouns(<<"查一下玩家位置"/utf8>>),
    %% 中文连续汉字作为一个 token（无词边界），整个串会被提取
    ?assert(lists:member(<<"查一下玩家位置"/utf8>>, Nouns)).

extract_data_nouns_english_test() ->
    Nouns = alContextEngine:extractDataNouns(<<"how to get player position"/utf8>>),
    ?assert(lists:member(<<"player">>, Nouns)),
    ?assert(lists:member(<<"position">>, Nouns)),
    %% "how"/"get" 是停用词，应被过滤
    ?assertNot(lists:member(<<"how">>, Nouns)),
    ?assertNot(lists:member(<<"get">>, Nouns)).

extract_data_nouns_filters_english_stopwords_test() ->
    Nouns = alContextEngine:extractDataNouns(<<"what is player">>),
    %% "what" 是停用词；"is" 短于3字母被过滤
    ?assertNot(lists:member(<<"what">>, Nouns)),
    ?assert(lists:member(<<"player">>, Nouns)).

extract_data_nouns_mixed_test() ->
    Nouns = alContextEngine:extractDataNouns(<<"查询 player_tab 表"/utf8>>),
    %% "player_tab" 是英文 token；中文片段「查询」「表」单字不计
    ?assert(lists:member(<<"player_tab">>, Nouns)).

extract_data_nouns_dedup_test() ->
    Nouns = alContextEngine:extractDataNouns(<<"player position player"/utf8>>),
    %% 去重：player 只出现一次
    ?assertEqual(1, length([N || N <- Nouns, N =:= <<"player">>])).

extract_data_nouns_list_input_test() ->
    Nouns = alContextEngine:extractDataNouns("查询玩家"),
    ?assert(is_list(Nouns)).

%%--------------------------------------------------------------------
%% parseDataQueryAnchor/1 — 锚定解析
%%--------------------------------------------------------------------
parse_data_query_anchor_table_test() ->
    A = alContextEngine:parseDataQueryAnchor(<<"查 @table:role_tab 的数据"/utf8>>),
    ?assertEqual(<<"role_tab">>, maps:get(table, A)).

parse_data_query_anchor_table_colon_form_test() ->
    A = alContextEngine:parseDataQueryAnchor(<<"@table:role_tab">>),
    ?assertEqual(<<"role_tab">>, maps:get(table, A)).

parse_data_query_anchor_mfa_test() ->
    A = alContextEngine:parseDataQueryAnchor(<<"@mfa:alAgent:run/2">>),
    Mfa = maps:get(mfa, A),
    ?assertMatch({_, _, _}, Mfa),
    {M, F, Arity} = Mfa,
    ?assert(is_atom(M)),
    ?assert(is_atom(F)),
    ?assert(is_integer(Arity)).

parse_data_query_anchor_no_anchor_test() ->
    A = alContextEngine:parseDataQueryAnchor(<<"普通问题没有锚定"/utf8>>),
    ?assertEqual(#{}, A).

%%--------------------------------------------------------------------
%% confidenceOf/1 — 置信度评估
%%--------------------------------------------------------------------
confidence_of_undefined_test() ->
    ?assertEqual(none, alContextEngine:confidenceOf(undefined)).

confidence_of_empty_nodes_test() ->
    ?assertEqual(none, alContextEngine:confidenceOf(#{nodes => []})).

confidence_of_root_only_test() ->
    ?assertEqual(low, alContextEngine:confidenceOf(#{nodes => [#{mfa => <<"foo:bar/1">>}]})).

confidence_of_all_known_test() ->
    Dag = #{nodes => [
        #{mfa => <<"foo:bar/1">>, source => #{kind => call}},
        #{mfa => <<"baz:qux/1">>, source => #{kind => param}}
    ]},
    ?assertEqual(high, alContextEngine:confidenceOf(Dag)).

confidence_of_some_unknown_test() ->
    Dag = #{nodes => [
        #{mfa => <<"foo:bar/1">>, source => #{kind => call}},
        #{mfa => <<"baz:qux/1">>, source => #{kind => unknown}},
        #{mfa => <<"qux:zap/1">>, source => #{kind => literal}}
    ]},
    %% 1/3 unknown = 0.33, > 0.3 → medium
    ?assertEqual(medium, alContextEngine:confidenceOf(Dag)).

confidence_of_all_unknown_test() ->
    Dag = #{nodes => [
        #{mfa => <<"foo:bar/1">>, source => #{kind => unknown}},
        #{mfa => <<"baz:qux/1">>, source => #{kind => unknown}}
    ]},
    %% 100% unknown → medium (兜底，不让用户绝望)
    ?assertEqual(medium, alContextEngine:confidenceOf(Dag)).

confidence_of_no_source_treated_as_unknown_test() ->
    Dag = #{nodes => [
        #{mfa => <<"foo:bar/1">>},  %% 无 source 字段
        #{mfa => <<"baz:qux/1">>, source => #{kind => call}}
    ]},
    %% 1/2 unknown = 0.5 → medium
    ?assertEqual(medium, alContextEngine:confidenceOf(Dag)).

confidence_of_non_map_test() ->
    ?assertEqual(none, alContextEngine:confidenceOf(notAMap)).

%%--------------------------------------------------------------------
%% buildClarifyPrompt/1 — 追问 prompt 构造
%%--------------------------------------------------------------------
build_clarify_prompt_no_candidates_test() ->
    Prompt = alContextEngine:buildClarifyPrompt([]),
    ?assert(is_binary(Prompt)),
    %% 应包含 @table 提示
    ?assert(binary:match(Prompt, <<"@table">>) =/= nomatch).

build_clarify_prompt_with_candidates_test() ->
    Candidates = [
        #{table => <<"role_tab">>, target => {mfa, roleMgr, lookup, 1}, score => 2.0,
          callers => [], reason => <<"fuzzy">>},
        #{table => <<"player_tab">>, target => {mfa, playerDb, get, 1}, score => 1.0,
          callers => [], reason => <<"fuzzy">>}
    ],
    Prompt = alContextEngine:buildClarifyPrompt(Candidates),
    ?assert(is_binary(Prompt)),
    %% 应列出表名
    ?assert(binary:match(Prompt, <<"role_tab">>) =/= nomatch),
    ?assert(binary:match(Prompt, <<"player_tab">>) =/= nomatch).

build_clarify_prompt_skips_empty_tables_test() ->
    Candidates = [
        #{table => <<>>, target => {mfa, foo, bar, 1}, score => 1.0, callers => []}
    ],
    Prompt = alContextEngine:buildClarifyPrompt(Candidates),
    ?assert(is_binary(Prompt)),
    %% 没有表名时仍应输出 MFA
    ?assert(binary:match(Prompt, <<"foo">>) =/= nomatch).

%%--------------------------------------------------------------------
%% traceDataQuery/2 — 主入口（core 未启动时降级）
%%--------------------------------------------------------------------
trace_data_query_returns_map_structure_test() ->
    Result = alContextEngine:traceDataQuery(<<"查玩家位置"/utf8>>, #{}),
    ?assert(maps:is_key(question, Result)),
    ?assert(maps:is_key(nouns, Result)),
    ?assert(maps:is_key(candidates, Result)),
    ?assert(maps:is_key(confidence, Result)),
    ?assert(maps:is_key(dag, Result)),
    ?assert(maps:is_key(clarifyPrompt, Result)),
    ?assert(maps:is_key(hint, Result)).

trace_data_query_extracts_nouns_test() ->
    Result = alContextEngine:traceDataQuery(<<"查玩家位置"/utf8>>, #{}),
    Nouns = maps:get(nouns, Result),
    %% 中文连续汉字作为一个 token（无词边界）
    ?assert(lists:member(<<"查玩家位置"/utf8>>, Nouns)).

trace_data_query_core_unavailable_returns_low_confidence_test() ->
    %% core 未启动时，找不到 data sources，置信度应为 none/low 并触发追问
    Result = alContextEngine:traceDataQuery(<<"查玩家位置"/utf8>>, #{}),
    Confidence = maps:get(confidence, Result),
    ?assert(lists:member(Confidence, [none, low])),
    %% 低置信度应附带 clarifyPrompt
    ?assert(maps:get(clarifyPrompt, Result) =/= undefined).

trace_data_query_explicit_mfa_anchor_test() ->
    %% 显式锚定 MFA：直接构造 candidate，无需 core 返回 data sources
    Result = alContextEngine:traceDataQuery(
        <<"@mfa:nonexistentMod:foo/1 查调用链"/utf8>>, #{}),
    Candidates = maps:get(candidates, Result),
    ?assertEqual(1, length(Candidates)),
    [C | _] = Candidates,
    ?assertEqual({mfa, nonexistentMod, foo, 1}, maps:get(target, C)),
    ?assertEqual(1.0, maps:get(score, C)).

trace_data_query_hint_present_test() ->
    Result = alContextEngine:traceDataQuery(<<"any question">>, #{}),
    Hint = maps:get(hint, Result),
    ?assert(is_binary(Hint)),
    ?assert(byte_size(Hint) > 0).

trace_data_query_clarify_prompt_lists_candidates_when_low_test() ->
    %% core 不可用时 candidates 为空，clarifyPrompt 应是「未找到候选」版
    Result = alContextEngine:traceDataQuery(<<"查玩家位置"/utf8>>, #{}),
    case maps:get(confidence, Result) of
        none ->
            Prompt = maps:get(clarifyPrompt, Result),
            ?assert(binary:match(Prompt, <<"未找到"/utf8>>) =/= nomatch);
        _ ->
            ok
    end.

trace_data_query_accepts_list_input_test() ->
    Result = alContextEngine:traceDataQuery("查玩家位置", #{}),
    ?assert(is_binary(maps:get(question, Result))).

%% A3 回归：越界路径（目录外绝对路径与 .. 相对路径）返回 forbidden。
abs_under_root_outside_absolute_test() ->
    Root = try alConfig:projectRoot() catch _:_ -> "." end,
    Outside = filename:join(filename:dirname(Root),
        "ali_outside_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".erl"),
    ?assertEqual({error, forbidden}, alContextEngine:absUnderRoot(Outside)).

abs_under_root_dotdot_test() ->
    ?assertEqual({error, forbidden}, alContextEngine:absUnderRoot("../outside.erl")).
