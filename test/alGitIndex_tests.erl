%%% @doc EUnit tests for alGitIndex pure helpers + VCS list/search arg building.
-module(alGitIndex_tests).

-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% 关键导出存在性
%%--------------------------------------------------------------------
critical_exports_test() ->
    Exports = alGitIndex:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{isGitRepo, 1}, {probeRepo, 1}, {gitChangedFiles, 1}, {gitStatusMap, 1},
                   {incrementalIndex, 1}, {recentFiles, 0}, {listCommits, 1},
                   {searchCommits, 1}, {commitFiles, 1}, {commitDiff, 1},
                   {clearRecentCache, 0}, {normalizePath, 1}, {buildLogArgs, 1},
                   {statusMatches, 2}, {vcsFileFilter, 1}, {filesModifiedSince, 2}]].

%%--------------------------------------------------------------------
%% normalizePath/1 — 路径归一化
%%--------------------------------------------------------------------
normalizePath_backslash_to_forward_test() ->
    ?assertEqual("src/agent/alAgent.erl",
                 alGitIndex:normalizePath("src\\agent\\alAgent.erl")).

normalizePath_strips_dot_slash_test() ->
    ?assertEqual("foo/bar.erl",
                 alGitIndex:normalizePath("./foo/bar.erl")).

normalizePath_trims_whitespace_test() ->
    ?assertEqual("foo.erl",
                 alGitIndex:normalizePath("  foo.erl  ")).

normalizePath_binary_input_test() ->
    ?assertEqual("src/x.erl",
                 alGitIndex:normalizePath(<<"src/x.erl">>)).

normalizePath_already_normalized_test() ->
    ?assertEqual("src/agent/alAgent.erl",
                 alGitIndex:normalizePath("src/agent/alAgent.erl")).

normalizePath_atom_input_test() ->
    ?assertEqual("foo", alGitIndex:normalizePath(foo)).

%%--------------------------------------------------------------------
%% clearRecentCache/0 — 不崩溃
%%--------------------------------------------------------------------
clearRecentCache_no_crash_test() ->
    ?assertEqual(ok, alGitIndex:clearRecentCache()).

%%--------------------------------------------------------------------
%% buildLogArgs / parse helpers
%%--------------------------------------------------------------------
buildLogArgs_includes_grep_and_since_test() ->
    Args = alGitIndex:buildLogArgs(#{limit => 5, days => 2, grep => "fix login"}),
    ?assert(lists:member("-n", Args)),
    ?assert(lists:member("5", Args)),
    ?assert(lists:any(fun(A) -> is_list(A) andalso string:prefix(A, "--since=") =/= nomatch end, Args)),
    ?assert(lists:any(fun(A) -> is_list(A) andalso string:prefix(A, "--grep=") =/= nomatch end, Args)),
    ?assert(lists:member("-i", Args)).

buildLogArgs_path_and_author_test() ->
    Args = alGitIndex:buildLogArgs(#{limit => 3, author => "alice", path => "src/"}),
    ?assert(lists:member("--author=alice", Args)),
    ?assert(lists:member("--", Args)),
    ?assert(lists:member("src/", Args)).

buildLogArgs_withFiles_test() ->
    Args = alGitIndex:buildLogArgs(#{limit => 2, withFiles => true}),
    ?assert(lists:member("--name-only", Args)).

parseCommitLines_basic_test() ->
    Line = "abc\x1falice\x1f2026-01-01\x1ffix login",
    [C] = alGitIndex:parseCommitLines(Line ++ "\n"),
    ?assertEqual(<<"abc">>, maps:get(hash, C)),
    ?assertEqual(<<"alice">>, maps:get(author, C)),
    ?assertEqual(<<"fix login">>, maps:get(subject, C)).

%% 中文 subject 含 >255 码点，trimBin 必须走 unicode 而非 iolist_to_binary。
parseCommitLines_unicode_subject_test() ->
    Line = "deadbeef\x1fdev\x1f2026-08-01\x1fft: 代码修改",
    [C] = alGitIndex:parseCommitLines(Line ++ "\n"),
    ?assertEqual(<<"deadbeef">>, maps:get(hash, C)),
    ?assertEqual(<<"ft: 代码修改"/utf8>>, maps:get(subject, C)).

parseCommitShowStat_unicode_test() ->
    US = [16#1f],
    Out = lists:flatten([
        "abc", US, "dev", US, "d1", US, "ft: 代码修改", "\n",
        " src/a.erl | 2 +-\n",
        " 1 file changed\n"
    ]),
    #{hash := Hash, subject := Subj, files := Files} = alGitIndex:parseCommitShowStat(Out),
    ?assertEqual(<<"abc">>, Hash),
    ?assertEqual(<<"ft: 代码修改"/utf8>>, Subj),
    ?assert(length(Files) >= 1).

parseCommitBlocksWithFiles_test() ->
    US = [16#1f],
    Out = lists:flatten([
        "aaa", US, "bob", US, "d1", US, "subj1", "\n",
        "src/a.erl\n",
        "src/b.erl\n",
        "\n",
        "bbb", US, "carol", US, "d2", US, "subj2", "\n",
        "src/c.erl\n"
    ]),
    Commits = alGitIndex:parseCommitBlocksWithFiles(Out),
    ?assertEqual(2, length(Commits)),
    [C1, C2] = Commits,
    ?assertEqual(<<"aaa">>, maps:get(hash, C1)),
    ?assertEqual(2, maps:get(fileCount, C1)),
    ?assertEqual(["src/a.erl", "src/b.erl"], maps:get(files, C1)),
    ?assertEqual(<<"bbb">>, maps:get(hash, C2)),
    ?assertEqual(["src/c.erl"], maps:get(files, C2)).

searchCommits_missing_grep_test() ->
    ?assertEqual({error, missingGrep}, alGitIndex:searchCommits(#{limit => 5})).

%%--------------------------------------------------------------------
%% statusMatches / vcsFileFilter
%%--------------------------------------------------------------------
statusMatches_worktree_and_staged_test() ->
    ?assert(alGitIndex:statusMatches(modified, " M")),
    ?assert(alGitIndex:statusMatches(modified, "M ")),
    ?assert(alGitIndex:statusMatches(added, "A ")),
    ?assert(alGitIndex:statusMatches(added, " A")),
    ?assert(alGitIndex:statusMatches(added, "AM")),
    ?assert(alGitIndex:statusMatches(untracked, "??")),
    ?assert(alGitIndex:statusMatches(deleted, " D")),
    ?assert(alGitIndex:statusMatches(renamed, "R ")),
    ?assertNot(alGitIndex:statusMatches(added, "??")).

vcsFileFilter_no_filter_test() ->
    R = alGitIndex:vcsFileFilter(#{}),
    ?assertEqual(0, maps:get(count, R)),
    ?assertEqual(noFilter, maps:get(reason, R)).

%%--------------------------------------------------------------------
%% D1 回归：alCoreClient 不可用时，incrementalIndex 必须上抛 {error, _}，
%% 而不是把 {error, _} 包进 {ok, #{indexResponse => ...}}。
%%--------------------------------------------------------------------
incrementalIndex_propagates_core_error_test() ->
    case whereis(alCoreClient) of
        undefined ->
            ?assertMatch({error, _}, alGitIndex:incrementalIndex("."));
        _ ->
            %% 核心运行时走 {ok, _} 分支，本断言不适用。
            ok
    end.
