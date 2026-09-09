%%% @doc EUnit tests for alChangeImpact pure helpers.
-module(alChangeImpact_tests).

-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% 关键导出存在性
%%--------------------------------------------------------------------
critical_exports_test() ->
    Exports = alChangeImpact:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{analyze, 1}, {analyze, 2}, {review, 1}, {review, 2},
                   {recentCommits, 0},
                   {listCommits, 1}, {searchCommits, 1}, {commitDiff, 1},
                   {commitFiles, 1}, {dailyReview, 0}, {dailyReview, 1},
                   {reverseTraverse, 3}, {callerMfa, 1}, {edgeField, 2},
                   {summarize, 1}, {buildReviewPrompt, 2}, {buildStructuredReviewHints, 3},
                   {formatNaturalSummary, 1}, {applySummaryMode, 2},
                   {topTouchedModules, 2}, {buildDailyReviewHint, 3},
                   {changeTypeCounts, 1}, {lightCommitHints, 1}, {wrapCommitList, 3},
                   {moduleFromPath, 1}]].

%%--------------------------------------------------------------------
%% formatNaturalSummary / applySummaryMode
%%--------------------------------------------------------------------
format_natural_summary_zh_test() ->
    Nat = alChangeImpact:formatNaturalSummary(#{
        changeType => feat,
        touchedModules => [<<"alFoo">>, <<"alBar">>],
        affectedCallers => [#{mfa => <<"alX:y/1">>}],
        riskHints => [<<"注意热更"/utf8>>],
        suggestedTestAreas => [<<"eunit alFoo"/utf8>>],
        commit => #{subject => <<"add bar"/utf8>>}
    }),
    ?assert(is_binary(Nat)),
    ?assert(binary:match(Nat, <<"功能"/utf8>>) =/= nomatch),
    ?assert(binary:match(Nat, <<"alFoo">>) =/= nomatch),
    ?assert(binary:match(Nat, <<"alX:y/1">>) =/= nomatch).

apply_summary_mode_both_and_structured_test() ->
    Base = #{
        changeType => fix,
        touchedModules => [<<"m">>],
        affectedCallers => [],
        riskHints => [],
        suggestedTestAreas => []
    },
    Both = alChangeImpact:applySummaryMode(Base, both),
    ?assertEqual(both, maps:get(summaryMode, Both)),
    ?assert(is_binary(maps:get(naturalSummary, Both))),
    Struct = alChangeImpact:applySummaryMode(
                 Both#{naturalSummary => <<"x">>}, structured),
    ?assertEqual(structured, maps:get(summaryMode, Struct)),
    ?assertEqual(false, maps:is_key(naturalSummary, Struct)),
    NatOnly = alChangeImpact:applySummaryMode(Base, <<"natural">>),
    ?assertEqual(natural, maps:get(summaryMode, NatOnly)),
    ?assert(maps:is_key(naturalSummary, NatOnly)).

%%--------------------------------------------------------------------
%% moduleFromPath/1 — 从文件路径提取模块名
%%--------------------------------------------------------------------
moduleFromPath_erl_test() ->
    ?assertEqual(alAgent, alChangeImpact:moduleFromPath("src/agent/alAgent.erl")),
    ?assertEqual(alContextEngine, alChangeImpact:moduleFromPath(<<"src/agent/alContextEngine.erl">>)).

moduleFromPath_tests_module_skipped_test() ->
    %% 测试模块跳过
    ?assertEqual(undefined, alChangeImpact:moduleFromPath("test/alAgent_tests.erl")).

moduleFromPath_non_erl_test() ->
    ?assertEqual(undefined, alChangeImpact:moduleFromPath("src/main.rs")),
    ?assertEqual(undefined, alChangeImpact:moduleFromPath("README.md")).

%%--------------------------------------------------------------------
%% edgeField/2 — 多键防御性取值
%%--------------------------------------------------------------------
edgeField_atom_key_test() ->
    Edge = #{from_module => alAgent, from_function => run, from_arity => 2},
    ?assertEqual(alAgent, alChangeImpact:edgeField(Edge, [from_module, <<"from_module">>])).

edgeField_binary_key_test() ->
    Edge = #{<<"from_module">> => <<"alAgent">>, <<"from_function">> => <<"run">>},
    ?assertEqual(<<"alAgent">>, alChangeImpact:edgeField(Edge, [from_module, <<"from_module">>])).

edgeField_missing_key_test() ->
    Edge = #{other => 1},
    ?assertEqual(undefined, alChangeImpact:edgeField(Edge, [from_module, <<"from_module">>])).

edgeField_empty_keys_test() ->
    ?assertEqual(undefined, alChangeImpact:edgeField(#{a => 1}, [])).

%%--------------------------------------------------------------------
%% callerMfa/1 — 从 edge 提取调用方 MFA
%%--------------------------------------------------------------------
callerMfa_atom_keys_test() ->
    Edge = #{from_module => alAgent, from_function => run, from_arity => 2,
             to_module => alCore, to_function => call, arity => 1, line => 42},
    ?assertEqual({alAgent, run, 2}, alChangeImpact:callerMfa(Edge)).

callerMfa_binary_keys_test() ->
    Edge = #{<<"from_module">> => <<"alAgent">>, <<"from_function">> => <<"run">>,
             <<"from_arity">> => 2},
    %% binary -> existing atom
    ?assertEqual({alAgent, run, 2}, alChangeImpact:callerMfa(Edge)).

callerMfa_missing_fields_test() ->
    ?assertEqual({undefined, undefined, undefined}, alChangeImpact:callerMfa(#{other => 1})),
    ?assertEqual({undefined, undefined, undefined}, alChangeImpact:callerMfa(not_a_map)).

%%--------------------------------------------------------------------
%% reverseTraverse/3 — 反向遍历（core 不可用时 callers=[]）
%%--------------------------------------------------------------------
reverseTraverse_depth_zero_test() ->
    %% Depth=0 直接返回 depthLimited
    Result = alChangeImpact:reverseTraverse({alAgent, run, 2}, 0, sets:new()),
    ?assertEqual(true, maps:get(depthLimited, Result, false)),
    ?assertEqual([], maps:get(callers, Result, undefined)).

reverseTraverse_core_unavailable_test() ->
    %% core 不可用时 safeGetCallers 返回 []，callers 为空
    Result = alChangeImpact:reverseTraverse({alAgent, run, 2}, 3, sets:new()),
    ?assertEqual({alAgent, run, 2}, maps:get(mfa, Result)),
    ?assertEqual([], maps:get(callers, Result)).

reverseTraverse_cyclic_detection_test() ->
    %% 已在 Seen 集合里的 MFA 返回 cyclic
    Seen = sets:add_element({alAgent, run, 2}, sets:new()),
    Result = alChangeImpact:reverseTraverse({alAgent, run, 2}, 3, Seen),
    ?assertEqual(true, maps:get(cyclic, Result, false)).

%%--------------------------------------------------------------------
%% summarize/1 — 影响范围摘要
%%--------------------------------------------------------------------
summarize_empty_test() ->
    Result = alChangeImpact:summarize([]),
    ?assertEqual(0, maps:get(totalAffected, Result)),
    ?assertEqual([], maps:get(affectedFunctions, Result)).

summarize_non_list_test() ->
    Result = alChangeImpact:summarize(not_a_list),
    ?assertEqual(0, maps:get(totalAffected, Result)).

summarize_flat_impact_test() ->
    Impacts = [#{mfa => {alAgent, run, 2}, callers => []}],
    Result = alChangeImpact:summarize(Impacts),
    ?assertEqual(1, maps:get(totalAffected, Result)),
    [First | _] = maps:get(affectedFunctions, Result),
    ?assertMatch(<<"alAgent:run/2", _/binary>>, First).

summarize_nested_impact_test() ->
    Impacts = [
        #{mfa => {alAgent, run, 2}, callers => [
            #{mfa => {alServer, start, 0}, callers => []}
        ]}
    ],
    Result = alChangeImpact:summarize(Impacts),
    %% 2 个受影响函数：alAgent:run/2 (深度0) + alServer:start/0 (深度1)
    ?assertEqual(2, maps:get(totalAffected, Result)).

%%--------------------------------------------------------------------
%% buildReviewPrompt/2 — prompt 构造
%%--------------------------------------------------------------------
buildReviewPrompt_basic_test() ->
    CommitInfo = #{subject => <<"fix timeout bug">>,
                   files => [<<"src/agent/alAgent.erl">>],
                   patch => <<"diff --git a/src/agent/alAgent.erl\n@@ -10,3 +10,3 @@">>},
    Summary = #{affectedFunctions => [<<"alAgent:run/2 (直接修改)"/utf8>>]},
    Prompt = alChangeImpact:buildReviewPrompt(CommitInfo, Summary),
    %% 应包含提交主题、文件、patch、影响范围、审查问题
    ?assertMatch(<<_/binary>>, Prompt),
    ?assert(binary:match(Prompt, <<"fix timeout bug">>) =/= nomatch),
    ?assert(binary:match(Prompt, <<"src/agent/alAgent.erl">>) =/= nomatch),
    ?assert(binary:match(Prompt, <<"是否正确"/utf8>>) =/= nomatch).

buildReviewPrompt_with_hunks_and_detailed_test() ->
    CommitInfo = #{
        subject => <<"fix timeout bug">>,
        files => [<<"src/agent/alAgent.erl">>],
        patch => <<"diff --git a/src/agent/alAgent.erl\n@@ -10,3 +10,3 @@">>,
        patchHunks => [
            #{file => <<"src/agent/alAgent.erl">>,
              startLine => 10, endLine => 15,
              snippet => <<"10|foo()\n11|bar()">>}
        ]
    },
    Summary = #{
        affectedFunctions => [<<"alAgent:run/2 (直接修改)"/utf8>>],
        affectedFunctionsMfa => [{{alAgent, run, 2}, 0}],
        affectedFunctionsDetailed => [
            #{module => alAgent, function => run, arity => 2,
              file => <<"src/agent/alAgent.erl">>,
              sourcePreview => <<"run(A, B) -> ok.">>}
        ]
    },
    Prompt = alChangeImpact:buildReviewPrompt(CommitInfo, Summary),
    ?assert(binary:match(Prompt, <<"关键 patch 片段预览"/utf8>>) =/= nomatch),
    ?assert(binary:match(Prompt, <<"受影响函数源码预览"/utf8>>) =/= nomatch),
    ?assert(binary:match(Prompt, <<"run(A, B) -> ok.">>) =/= nomatch),
    ?assert(binary:match(Prompt, <<"结构化审查提示"/utf8>>) =/= nomatch),
    ?assert(binary:match(Prompt, <<"建议测试区域"/utf8>>) =/= nomatch).

buildStructuredReviewHints_test() ->
    CommitInfo = #{
        subject => <<"fix: agent timeout">>,
        files => [<<"src/agent/alAgent.erl">>, <<"test/alAgent_tests.erl">>]
    },
    Summary = #{
        totalAffected => 2,
        affectedFunctionsMfa => [
            {{alAgent, run, 2}, 0},
            {{alServer, start, 0}, 1}
        ]
    },
    Hints = alChangeImpact:buildStructuredReviewHints(
        CommitInfo, [alAgent], Summary),
    ?assertEqual(fix, maps:get(changeType, Hints)),
    ?assertMatch([<<"alAgent"/utf8>> | _], maps:get(touchedModules, Hints)),
    Callers = maps:get(affectedCallers, Hints),
    ?assertEqual(1, length(Callers)),
    ?assertEqual(1, maps:get(depth, hd(Callers))),
    Areas = maps:get(suggestedTestAreas, Hints),
    ?assert(lists:any(fun(A) -> binary:match(A, <<"eunit"/utf8>>) =/= nomatch end, Areas)),
    Risks = maps:get(riskHints, Hints),
    ?assert(is_list(Risks)).

topTouchedModules_test() ->
    Commits = [
        #{files => [<<"src/agent/alAgent.erl">>, <<"src/tools/alSearch.erl">>]},
        #{files => [<<"src/agent/alAgent.erl">>]}
    ],
    Top = alChangeImpact:topTouchedModules(Commits, 5),
    ?assertEqual(2, length(Top)),
    [First | _] = Top,
    ?assertEqual(<<"alAgent"/utf8>>, maps:get(module, First)),
    ?assertEqual(2, maps:get(hits, First)).

buildDailyReviewHint_test() ->
    Hint0 = alChangeImpact:buildDailyReviewHint(1, 0, []),
    ?assert(binary:match(Hint0, <<"无提交"/utf8>>) =/= nomatch),
    Hint1 = alChangeImpact:buildDailyReviewHint(7, 3,
        [#{module => <<"alAgent"/utf8>>, hits => 2}]),
    ?assert(binary:match(Hint1, <<"reviewChangeImpact"/utf8>>) =/= nomatch),
    ?assert(binary:match(Hint1, <<"alAgent"/utf8>>) =/= nomatch).

changeTypeCounts_test() ->
    Commits = [
        #{subject => <<"fix: a">>},
        #{subject => <<"feat: b">>},
        #{subject => <<"fix: c">>}
    ],
    Counts = alChangeImpact:changeTypeCounts(Commits),
    ?assertEqual(2, maps:get(fix, Counts)),
    ?assertEqual(1, maps:get(feat, Counts)).

lightCommitHints_test() ->
    Diff = #{
        subject => <<"fix: timeout">>,
        files => [<<"src/agent/alAgent.erl">>, <<"README.md">>]
    },
    Hints = alChangeImpact:lightCommitHints(Diff),
    ?assertEqual(fix, maps:get(changeType, Hints)),
    ?assertEqual([<<"alAgent"/utf8>>], maps:get(touchedModules, Hints)),
    Areas = maps:get(suggestedTestAreas, Hints),
    ?assert(lists:any(fun(A) -> binary:match(A, <<"eunit"/utf8>>) =/= nomatch end, Areas)),
    ?assert(binary:match(maps:get(reviewHint, Hints), <<"reviewChangeImpact"/utf8>>) =/= nomatch).

wrapCommitList_test() ->
    Commits = [
        #{subject => <<"fix: x">>,
          files => [<<"src/agent/alAgent.erl">>, <<"src/tools/alSearch.erl">>]},
        #{subject => <<"docs: y">>, files => [<<"README.md">>]}
    ],
    Wrapped = alChangeImpact:wrapCommitList(Commits, #{limit => 2, withFiles => true}, undefined),
    ?assertEqual(2, maps:get(count, Wrapped)),
    ?assert(is_map(maps:get(changeTypeCounts, Wrapped))),
    ?assertEqual(1, maps:get(fix, maps:get(changeTypeCounts, Wrapped))),
    Top = maps:get(topTouchedModules, Wrapped),
    ?assert(lists:any(fun(M) -> maps:get(module, M) =:= <<"alAgent"/utf8>> end, Top)),
    ?assert(binary:match(maps:get(reviewHint, Wrapped), <<"reviewChangeImpact"/utf8>>) =/= nomatch).

%%--------------------------------------------------------------------
%% classifyChangeType/1 — commit message 关键词分类
%%--------------------------------------------------------------------
classify_change_type_fix_test() ->
    ?assertEqual(fix, alChangeImpact:classifyChangeType(<<"fix: resolve timeout">>)),
    ?assertEqual(fix, alChangeImpact:classifyChangeType(<<"bugfix: crash on null">>)),
    ?assertEqual(fix, alChangeImpact:classifyChangeType(unicode:characters_to_binary("修复登录问题"))).

classify_change_type_feat_test() ->
    ?assertEqual(feat, alChangeImpact:classifyChangeType(<<"feat: add new tool">>)),
    ?assertEqual(feat, alChangeImpact:classifyChangeType(<<"feature: x">>)),
    ?assertEqual(feat, alChangeImpact:classifyChangeType(unicode:characters_to_binary("新增技能模块"))).

classify_change_type_refactor_test() ->
    ?assertEqual(refactor, alChangeImpact:classifyChangeType(<<"refactor: simplify loop">>)),
    ?assertEqual(refactor, alChangeImpact:classifyChangeType(unicode:characters_to_binary("重构上下文引擎"))).

classify_change_type_test_test() ->
    ?assertEqual(test, alChangeImpact:classifyChangeType(<<"test: add eunit for foo">>)),
    ?assertEqual(test, alChangeImpact:classifyChangeType(unicode:characters_to_binary("测试覆盖完善"))).

classify_change_type_docs_test() ->
    ?assertEqual(docs, alChangeImpact:classifyChangeType(<<"docs: update README">>)),
    ?assertEqual(docs, alChangeImpact:classifyChangeType(unicode:characters_to_binary("文档补充"))).

classify_change_type_perf_test() ->
    ?assertEqual(perf, alChangeImpact:classifyChangeType(<<"perf: optimize search">>)),
    ?assertEqual(perf, alChangeImpact:classifyChangeType(unicode:characters_to_binary("性能优化"))).

classify_change_type_chore_test() ->
    ?assertEqual(chore, alChangeImpact:classifyChangeType(<<"chore: bump deps">>)).

classify_change_type_other_test() ->
    ?assertEqual(other, alChangeImpact:classifyChangeType(<<"random update">>)),
    ?assertEqual(other, alChangeImpact:classifyChangeType(<<>>)).

classify_change_type_case_insensitive_test() ->
    ?assertEqual(fix, alChangeImpact:classifyChangeType(<<"FIX: critical bug">>)),
    ?assertEqual(feat, alChangeImpact:classifyChangeType(<<"FEAT: new module">>)).

classify_change_type_list_input_test() ->
    ?assertEqual(fix, alChangeImpact:classifyChangeType("fix something")).

classify_change_type_non_binary_test() ->
    ?assertEqual(other, alChangeImpact:classifyChangeType(12345)).

%%--------------------------------------------------------------------
%% commitTouchesFunction/3 — 提交是否触及函数
%%--------------------------------------------------------------------
commit_touches_function_no_hash_test() ->
    %% Commit 既无 hash 也无 revision，直接返回 false
    ?assertEqual(false, alChangeImpact:commitTouchesFunction(#{subject => <<"foo">>}, alAgent, undefined)).

commit_touches_function_empty_modules_test() ->
    %% alVcsIndex:commitFiles 在测试环境可能返回 error，此时 false
    Result = alChangeImpact:commitTouchesFunction(#{hash => <<"abc123">>}, someUnknownModule, undefined),
    ?assertEqual(false, Result).

commit_touches_function_svn_revision_test() ->
    %% SVN commit 用 revision 字段而非 hash，应被 commitRef 识别
    Result = alChangeImpact:commitTouchesFunction(#{revision => <<"r123">>}, someUnknownModule, undefined),
    ?assertEqual(false, Result).

%%--------------------------------------------------------------------
%% commitRef/1 — Git hash / SVN revision 兼容提取
%%--------------------------------------------------------------------
commitRef_git_hash_test() ->
    ?assertEqual(<<"abc123">>, alChangeImpact:commitRef(#{hash => <<"abc123">>})).

commitRef_svn_revision_test() ->
    ?assertEqual(<<"r123">>, alChangeImpact:commitRef(#{revision => <<"r123">>})).

commitRef_hash_preferred_over_revision_test() ->
    %% 同时存在时优先 hash（git 优先策略与 alVcsIndex 一致）
    ?assertEqual(<<"abc123">>,
                 alChangeImpact:commitRef(#{hash => <<"abc123">>, revision => <<"r999">>})).

commitRef_missing_both_test() ->
    ?assertEqual(undefined, alChangeImpact:commitRef(#{subject => <<"foo">>})).

commitRef_non_map_test() ->
    ?assertEqual(undefined, alChangeImpact:commitRef(not_a_map)).

%%--------------------------------------------------------------------
%% extractFunctionLineRange/2 — 函数行范围提取
%%--------------------------------------------------------------------
extract_function_line_range_unknown_module_test() ->
    %% 未索引的模块：返回 undefined（alCoreClient:moduleSymbols 失败）
    Result = alChangeImpact:extractFunctionLineRange(someNonexistentModule, {someFunction, 1}),
    ?assertEqual(undefined, Result).

extract_function_line_range_non_atom_module_test() ->
    ?assertEqual(undefined, alChangeImpact:extractFunctionLineRange(<<"notAtom">>, {foo, 1})).

buildReviewPrompt_empty_test() ->
    Prompt = alChangeImpact:buildReviewPrompt(#{}, #{}),
    ?assertMatch(<<_/binary>>, Prompt),
    ?assert(binary:match(Prompt, <<"请审查"/utf8>>) =/= nomatch).

%%--------------------------------------------------------------------
%% patch helper tests — git / svn file headers and hunk parsing
%%--------------------------------------------------------------------
parse_hunk_plus_range_git_test() ->
    ?assertEqual({10, 12},
                 alChangeImpact:parseHunkPlusRange(<<"@@ -8,2 +10,3 @@">>)),
    ?assertEqual({42, 42},
                 alChangeImpact:parseHunkPlusRange(<<"@@ -1 +42 @@">>)).

parse_hunk_plus_range_invalid_test() ->
    ?assertEqual(false, alChangeImpact:parseHunkPlusRange(<<"not a hunk">>)).

maybe_parse_diff_file_git_test() ->
    ?assertEqual({new_file, <<"src/agent/alAgent.erl">>},
                 alChangeImpact:maybeParseDiffFile(
                   <<"diff --git a/src/agent/alAgent.erl b/src/agent/alAgent.erl">>, undefined)),
    ?assertEqual({new_file, <<"src/agent/alAgent.erl">>},
                 alChangeImpact:maybeParseDiffFile(
                   <<"+++ b/src/agent/alAgent.erl">>, undefined)).

maybe_parse_diff_file_svn_test() ->
    ?assertEqual({new_file, <<"src/agent/alAgent.erl">>},
                 alChangeImpact:maybeParseDiffFile(
                   <<"Index: src/agent/alAgent.erl">>, undefined)),
    ?assertEqual({new_file, <<"src/agent/alAgent.erl">>},
                 alChangeImpact:maybeParseDiffFile(
                   <<"--- src/agent/alAgent.erl\t(revision 123)">>, undefined)),
    ?assertEqual({new_file, <<"src/agent/alAgent.erl">>},
                 alChangeImpact:maybeParseDiffFile(
                   <<"+++ src/agent/alAgent.erl\t(working copy)">>, undefined)).

trim_after_ws_and_strip_prefix_test() ->
    ?assertEqual(<<"src/agent/alAgent.erl">>,
                 alChangeImpact:trimAfterWs(<<"src/agent/alAgent.erl\t(revision 123)">>)),
    ?assertEqual(<<"src/agent/alAgent.erl">>,
                 alChangeImpact:stripABPrefix(<<"b/src/agent/alAgent.erl">>)),
    ?assertEqual(<<"src/agent/alAgent.erl">>,
                 alChangeImpact:stripABPrefix(<<"a/src/agent/alAgent.erl">>)).

%%--------------------------------------------------------------------
%% L3 回归：moduleSymbols 经 normalizeJson 可能保留 binary 键，
%% analyzeModule 的函数名/arity 提取必须双键读取。
%%--------------------------------------------------------------------
functionNameOf_reads_binary_key_test() ->
    ?assertEqual(ok, alChangeImpact:functionNameOf(#{<<"name">> => <<"ok">>})).

functionNameOf_reads_atom_key_test() ->
    ?assertEqual(ok, alChangeImpact:functionNameOf(#{name => ok})).

functionNameOf_missing_key_test() ->
    ?assertEqual(undefined, alChangeImpact:functionNameOf(#{other => 1})).

functionArityOf_reads_binary_key_test() ->
    ?assertEqual(2, alChangeImpact:functionArityOf(#{<<"arity">> => 2})),
    ?assertEqual(2, alChangeImpact:functionArityOf(#{<<"arity">> => <<"2">>})).

functionArityOf_reads_atom_key_test() ->
    ?assertEqual(2, alChangeImpact:functionArityOf(#{arity => 2})).

functionArityOf_missing_key_test() ->
    ?assertEqual(undefined, alChangeImpact:functionArityOf(#{other => 1})).
