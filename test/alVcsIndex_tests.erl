%%% @doc EUnit tests for alVcsIndex (统一抽象层) 和 alSvnIndex 纯辅助函数。
-module(alVcsIndex_tests).

-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% alVcsIndex 关键导出存在性
%%--------------------------------------------------------------------
vcsIndex_exports_test() ->
    Exports = alVcsIndex:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{vcsType, 0}, {diagnose, 0}, {isVcsRepo, 1},
                   {incrementalIndex, 0}, {incrementalIndex, 1},
                   {recentCommits, 0}, {recentCommits, 1}, {listCommits, 1},
                   {searchCommits, 1}, {commitFiles, 1}, {commitDiff, 1},
                   {recentFiles, 0}, {recentFiles, 1}, {recentFiles, 2},
                   {clearRecentCache, 0}, {clearTypeCache, 0}, {normalizePath, 1}]].

%%--------------------------------------------------------------------
%% diagnose 返回结构化 map（含 hint）
%%--------------------------------------------------------------------
vcsIndex_diagnose_shape_test() ->
    alVcsIndex:clearTypeCache(),
    D = alVcsIndex:diagnose(),
    ?assert(is_map(D)),
    ?assert(maps:is_key(type, D)),
    ?assert(maps:is_key(root, D)),
    ?assert(maps:is_key(hint, D)),
    ?assert(maps:is_key(ok, D)).

%%--------------------------------------------------------------------
%% alVcsIndex normalizePath 委托正确
%%--------------------------------------------------------------------
vcsIndex_normalizePath_delegates_test() ->
    %% 应与 alGitIndex:normalizePath 行为一致
    ?assertEqual("src/x.erl", alVcsIndex:normalizePath("src\\x.erl")),
    ?assertEqual("foo", alVcsIndex:normalizePath("./foo")).

%%--------------------------------------------------------------------
%% alVcsIndex clearTypeCache 不崩溃
%%--------------------------------------------------------------------
vcsIndex_clearTypeCache_test() ->
    ?assertEqual(ok, alVcsIndex:clearTypeCache()).

%%--------------------------------------------------------------------
%% alVcsIndex clearRecentCache 不崩溃
%%--------------------------------------------------------------------
vcsIndex_clearRecentCache_test() ->
    ?assertEqual(ok, alVcsIndex:clearRecentCache()).

%%--------------------------------------------------------------------
%% alSvnIndex 关键导出存在性
%%--------------------------------------------------------------------
svnIndex_exports_test() ->
    Exports = alSvnIndex:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{isSvnRepo, 1}, {probeRepo, 1}, {recentCommits, 0}, {recentCommits, 1},
                   {listCommits, 1}, {searchCommits, 1},
                   {commitFiles, 1}, {commitDiff, 1}, {recentFiles, 0},
                   {recentFiles, 1}, {recentFiles, 2},
                   {parseSvnLog, 1}, {parseSvnLogVerbose, 1}, {parseRevision, 1},
                   {formatDateForSvn, 1}, {buildLogArgs, 1}]].

svn_buildLogArgs_search_test() ->
    Args = alSvnIndex:buildLogArgs(#{limit => 8, grep => "timeout", days => 3}),
    ?assert(lists:member("-l", Args)),
    ?assert(lists:member("8", Args)),
    ?assert(lists:any(fun(A) -> is_list(A) andalso string:prefix(A, "--search=") =/= nomatch end, Args)).

%%--------------------------------------------------------------------
%% alSvnIndex parseRevision — revision 引用规范化
%%--------------------------------------------------------------------
svn_parseRevision_r_prefix_test() ->
    ?assertEqual("123", alSvnIndex:parseRevision(<<"r123">>)),
    ?assertEqual("123", alSvnIndex:parseRevision("r123")).

svn_parseRevision_plain_test() ->
    ?assertEqual("123", alSvnIndex:parseRevision("123")),
    ?assertEqual("123", alSvnIndex:parseRevision(<<"123">>)).

svn_parseRevision_integer_test() ->
    ?assertEqual("123", alSvnIndex:parseRevision(123)).

svn_parseRevision_fallback_test() ->
    ?assertEqual("HEAD", alSvnIndex:parseRevision(undefined)),
    ?assertEqual("HEAD", alSvnIndex:parseRevision([])).

%%--------------------------------------------------------------------
%% alSvnIndex formatDateForSvn — 日期格式
%%--------------------------------------------------------------------
svn_formatDateForSvn_test() ->
    Result = alSvnIndex:formatDateForSvn(7),
    %% 应形如 {YYYY-MM-DD}
    ?assertMatch([${ | _], Result),
    ?assert(nomatch =/= string:find(Result, "-")).

%%--------------------------------------------------------------------
%% alSvnIndex parseSvnLog — 解析 svn log 输出
%%--------------------------------------------------------------------
svn_parseSvnLog_single_test() ->
    Out = "------------------------------------------------------------------------\n"
          "r123 | alice | 2026-07-23 10:00:00 +0800 (Wed, 23 Jul 2026) | 1 line\n"
          "fix timeout bug\n"
          "------------------------------------------------------------------------",
    [Commit] = alSvnIndex:parseSvnLog(Out),
    ?assertEqual(<<"r123">>, maps:get(revision, Commit)),
    ?assertEqual(<<"alice">>, maps:get(author, Commit)),
    ?assertEqual(<<"fix timeout bug">>, maps:get(subject, Commit)).

svn_parseSvnLog_multiple_test() ->
    Out = "------------------------------------------------------------------------\n"
          "r124 | bob | 2026-07-24 11:00:00 +0800 | 1 line\n"
          "second commit\n"
          "------------------------------------------------------------------------\n"
          "------------------------------------------------------------------------\n"
          "r123 | alice | 2026-07-23 10:00:00 +0800 | 1 line\n"
          "first commit\n"
          "------------------------------------------------------------------------",
    Commits = alSvnIndex:parseSvnLog(Out),
    ?assertEqual(2, length(Commits)).

svn_parseSvnLog_empty_test() ->
    ?assertEqual([], alSvnIndex:parseSvnLog("")).

%%--------------------------------------------------------------------
%% alSvnIndex parseSvnLogVerbose — 带 Changed paths 的解析
%%--------------------------------------------------------------------
svn_parseSvnLogVerbose_test() ->
    Out = "------------------------------------------------------------------------\n"
          "r123 | alice | 2026-07-23 10:00:00 +0800 | 1 line\n"
          "Changed paths:\n"
          "   M /trunk/src/agent/alAgent.erl\n"
          "   A /trunk/src/tools/alChangeImpact.erl\n"
          "add impact analysis\n"
          "------------------------------------------------------------------------",
    [Commit] = alSvnIndex:parseSvnLogVerbose(Out),
    ?assertEqual(<<"r123">>, maps:get(revision, Commit)),
    Files = maps:get(files, Commit),
    ?assertEqual(2, length(Files)),
    ?assertEqual(<<"add impact analysis">>, maps:get(subject, Commit)).

svn_parseSvnLogVerbose_strips_trunk_prefix_test() ->
    Out = "------------------------------------------------------------------------\n"
          "r1 | dev | 2026-01-01 | 1 line\n"
          "Changed paths:\n"
          "   M /trunk/src/foo.erl\n"
          "msg\n"
          "------------------------------------------------------------------------",
    [Commit] = alSvnIndex:parseSvnLogVerbose(Out),
    [Path] = maps:get(files, Commit),
    %% trunk/ 前缀应被去除
    ?assertEqual("src/foo.erl", Path).

%%--------------------------------------------------------------------
%% alSvnIndex parseSvnStatusLine
%%--------------------------------------------------------------------
svn_parseSvnStatusLine_test() ->
    ?assertEqual({"M", "src/a.erl"}, alSvnIndex:parseSvnStatusLine("M       src/a.erl")),
    ?assertEqual({"?", "new.erl"}, alSvnIndex:parseSvnStatusLine("?       new.erl")),
    {StatA, PathA} = alSvnIndex:parseSvnStatusLine("A  +    x.erl"),
    ?assertEqual("x.erl", PathA),
    ?assertEqual($A, hd(StatA)),
    ?assertEqual(undefined, alSvnIndex:parseSvnStatusLine("")),
    ?assertEqual(undefined, alSvnIndex:parseSvnStatusLine("Performing status on external item at...")).

svn_exports_incremental_test() ->
    Exports = alSvnIndex:module_info(exports),
    ?assert(lists:member({incrementalIndex, 1}, Exports)),
    ?assert(lists:member({svnStatusMap, 1}, Exports)),
    ?assert(lists:member({svnChangedFiles, 1}, Exports)).
