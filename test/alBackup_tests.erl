%%% @doc EUnit tests for {@link alBackup}.
-module(alBackup_tests).

-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% Setup / teardown
%%%===================================================================

%% Patch alConfig root to a unique temp dir so tests never touch the
%% real project. Returns the temp root for the test body to use.
setupRoot() ->
    Tmp = tmpRoot(),
    ok = filelib:ensure_dir(filename:join(Tmp, "x")),
    DataDir = filename:join(Tmp, ".ali"),
    Agent = maps:without([backupDir], alConfig:get(agent, #{})),
    ok = alConfig:patch([
        {root, Tmp},
        {dataDir, DataDir},
        {agent, Agent}
    ]),
    Tmp.

tmpRoot() ->
    Ts = erlang:system_time(microsecond),
    N = erlang:unique_integer([positive]),
    filename:join(tempDir(), "alBackup_" ++ integer_to_list(Ts) ++ "_" ++ integer_to_list(N)).

tempDir() ->
    case os:getenv("TMPDIR") of
        false ->
            case os:type() of
                {win32, _} -> os:getenv("TEMP");
                _ -> "/tmp"
            end;
        Dir -> Dir
    end.

cleanupRoot(Tmp) ->
    case file:del_dir_r(Tmp) of
        ok -> ok;
        _ -> ok
    end.

writeFile(Path, Content) ->
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Content).

%%%===================================================================
%%% Tests
%%%===================================================================

backupDirUnderRoot_test() ->
    Tmp = setupRoot(),
    try
        Dir = alBackup:backupDir(),
        ?assertEqual(filename:join(Tmp, ".ali/backups"), Dir),
        ?assert(filelib:is_dir(Dir))
    after
        cleanupRoot(Tmp)
    end.

backupFileAndRestore_test() ->
    Tmp = setupRoot(),
    try
        File = filename:join(Tmp, "src/hello.erl"),
        ok = writeFile(File, <<"hello">>),
        {ok, Meta} = alBackup:backupFile(File),
        ?assertEqual(File, maps:get(original, Meta)),
        ?assert(filelib:is_file(maps:get(backup, Meta))),
        %% Mutate the original then restore.
        ok = file:write_file(File, <<"changed">>),
        ?assertEqual(ok, alBackup:restore(maps:get(backup, Meta))),
        ?assertEqual({ok, <<"hello">>}, file:read_file(File))
    after
        cleanupRoot(Tmp)
    end.

backupFileWithSessionMeta_test() ->
    Tmp = setupRoot(),
    try
        File = filename:join(Tmp, "src/foo.erl"),
        ok = writeFile(File, <<"foo">>),
        {ok, Meta} = alBackup:backupFile(File, #{sessionId => <<"sess-1">>}),
        ?assertEqual(<<"sess-1">>, maps:get(sessionId, Meta)),
        Backups = alBackup:listSessionBackups(<<"sess-1">>),
        ?assertEqual(1, length(Backups))
    after
        cleanupRoot(Tmp)
    end.

listBackupsDescending_test() ->
    Tmp = setupRoot(),
    try
        File = filename:join(Tmp, "src/bar.erl"),
        ok = writeFile(File, <<"v1">>),
        {ok, _} = alBackup:backupFile(File),
        timer:sleep(2),
        ok = file:write_file(File, <<"v2">>),
        {ok, _} = alBackup:backupFile(File),
        Backups = alBackup:listBackups(File),
        ?assertEqual(2, length(Backups)),
        [First, Second | _] = Backups,
        ?assert(maps:get(timestamp, First) >= maps:get(timestamp, Second))
    after
        cleanupRoot(Tmp)
    end.

restoreLatest_test() ->
    Tmp = setupRoot(),
    try
        File = filename:join(Tmp, "src/baz.erl"),
        ok = writeFile(File, <<"v1">>),
        {ok, _} = alBackup:backupFile(File),
        timer:sleep(2),
        ok = file:write_file(File, <<"v2">>),
        {ok, _} = alBackup:backupFile(File),
        ok = file:write_file(File, <<"v3">>),
        ?assertEqual(ok, alBackup:restoreLatest(File)),
        ?assertEqual({ok, <<"v2">>}, file:read_file(File))
    after
        cleanupRoot(Tmp)
    end.

restoreLatestNoBackup_test() ->
    Tmp = setupRoot(),
    try
        File = filename:join(Tmp, "src/none.erl"),
        ?assertEqual({error, noBackup}, alBackup:restoreLatest(File))
    after
        cleanupRoot(Tmp)
    end.

backupNonexistentFile_test() ->
    Tmp = setupRoot(),
    try
        File = filename:join(Tmp, "missing.erl"),
        ?assertMatch({error, _}, alBackup:backupFile(File))
    after
        cleanupRoot(Tmp)
    end.

restoreMissingOriginalMeta_test() ->
    Tmp = setupRoot(),
    try
        %% Drop a backup file without a sibling .meta — restore should
        %% refuse because original path cannot be resolved.
        Dir = alBackup:backupDir(),
        Ts = integer_to_list(erlang:system_time(millisecond)),
        SubDir = filename:join(Dir, Ts),
        ok = filelib:ensure_dir(filename:join(SubDir, "x")),
        Path = filename:join(SubDir, "orphan.erl"),
        ok = file:write_file(Path, <<"orphan">>),
        ?assertEqual({error, missingOriginal}, alBackup:restore(Path))
    after
        cleanupRoot(Tmp)
    end.

restoreSession_test() ->
    Tmp = setupRoot(),
    try
        File1 = filename:join(Tmp, "src/a.erl"),
        File2 = filename:join(Tmp, "src/b.erl"),
        ok = writeFile(File1, <<"a-original">>),
        ok = writeFile(File2, <<"b-original">>),
        {ok, _} = alBackup:backupFile(File1, #{sessionId => <<"s1">>}),
        timer:sleep(2),
        {ok, _} = alBackup:backupFile(File2, #{sessionId => <<"s1">>}),
        %% Simulate session edits.
        ok = file:write_file(File1, <<"a-edited">>),
        ok = file:write_file(File2, <<"b-edited">>),
        {ok, Result} = alBackup:restoreSession(<<"s1">>),
        ?assertEqual(2, maps:get(fileCount, Result)),
        ?assertEqual({ok, <<"a-original">>}, file:read_file(File1)),
        ?assertEqual({ok, <<"b-original">>}, file:read_file(File2))
    after
        cleanupRoot(Tmp)
    end.

restoreSessionNoBackups_test() ->
    Tmp = setupRoot(),
    try
        {ok, Result} = alBackup:restoreSession(<<"no-such-session">>),
        ?assertEqual([], maps:get(restored, Result)),
        ?assertEqual(0, maps:get(fileCount, Result))
    after
        cleanupRoot(Tmp)
    end.

cleanupCapsPerFile_test() ->
    Tmp = setupRoot(),
    try
        File = filename:join(Tmp, "src/many.erl"),
        ok = writeFile(File, <<"v0">>),
        %% Make 5 distinct backups with monotonic timestamps.
        [begin
            ok = file:write_file(File, integer_to_binary(N)),
            {ok, _} = alBackup:backupFile(File),
            timer:sleep(2)
         end || N <- lists:seq(1, 5)],
        All = alBackup:listBackups(File),
        ?assertEqual(5, length(All)),
        ok = alBackup:cleanup(3),
        Remaining = alBackup:listBackups(File),
        ?assertEqual(3, length(Remaining))
    after
        cleanupRoot(Tmp)
    end.

listSessionBackupsAscending_test() ->
    Tmp = setupRoot(),
    try
        File = filename:join(Tmp, "src/seq.erl"),
        ok = writeFile(File, <<"1">>),
        {ok, _} = alBackup:backupFile(File, #{sessionId => <<"sx">>}),
        timer:sleep(2),
        {ok, _} = alBackup:backupFile(File, #{sessionId => <<"sx">>}),
        Backups = alBackup:listSessionBackups(<<"sx">>),
        ?assertEqual(2, length(Backups)),
        [First, Second | _] = Backups,
        ?assert(maps:get(timestamp, First) =< maps:get(timestamp, Second))
    after
        cleanupRoot(Tmp)
    end.

%% C3 回归：.meta 的 original 指向项目外路径时，restoreSession 不得覆盖该文件。
restoreSessionSkipsOutsideOriginal_test() ->
    Tmp = setupRoot(),
    OutsideDir = filename:join(tempDir(),
        "alBackup_outside_" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(OutsideDir, "x")),
    try
        File = filename:join(Tmp, "src/outside.erl"),
        ok = writeFile(File, <<"inside">>),
        {ok, Meta} = alBackup:backupFile(File, #{sessionId => <<"s-out">>}),
        Backup = maps:get(backup, Meta),
        MetaPath = <<Backup/binary, ".meta">>,
        {ok, MetaBin} = file:read_file(MetaPath),
        Decoded = alJson:decode(MetaBin),
        Outside = filename:join(OutsideDir, "target.erl"),
        ok = file:write_file(Outside, <<"outside-original">>),
        Tampered = Decoded#{<<"original">> => unicode:characters_to_binary(Outside)},
        ok = file:write_file(MetaPath, alJson:encode(Tampered)),
        {ok, Result} = alBackup:restoreSession(<<"s-out">>),
        ?assertEqual([], maps:get(restored, Result)),
        Errors = maps:get(errors, Result),
        ?assertEqual(1, length(Errors)),
        [Err] = Errors,
        ?assertEqual(Outside, maps:get(path, Err)),
        ?assertEqual(forbidden, maps:get(error, Err)),
        %% 项目外文件未被覆盖
        ?assertEqual({ok, <<"outside-original">>}, file:read_file(Outside))
    after
        cleanupRoot(Tmp),
        cleanupRoot(OutsideDir)
    end.

%% C3 连带修复：.meta 缺 original 字段时 restoreSession 不崩溃。
restoreSessionMissingOriginalMeta_test() ->
    Tmp = setupRoot(),
    try
        File = filename:join(Tmp, "src/miss.erl"),
        ok = writeFile(File, <<"miss">>),
        {ok, Meta} = alBackup:backupFile(File, #{sessionId => <<"s-miss">>}),
        Backup = maps:get(backup, Meta),
        MetaPath = <<Backup/binary, ".meta">>,
        {ok, MetaBin} = file:read_file(MetaPath),
        Decoded = alJson:decode(MetaBin),
        Tampered = maps:remove(<<"original">>, Decoded),
        ok = file:write_file(MetaPath, alJson:encode(Tampered)),
        {ok, Result} = alBackup:restoreSession(<<"s-miss">>),
        ?assertEqual([], maps:get(restored, Result)),
        ?assertEqual(0, maps:get(fileCount, Result))
    after
        cleanupRoot(Tmp)
    end.

%% A2 回归：无 .meta 的时间戳目录（parseTs 解析失败返回 0）不得被误删。
cleanupExpiredSkipsDirWithoutMeta_test() ->
    Tmp = setupRoot(),
    try
        Dir = alBackup:backupDir(),
        NoMetaDir = filename:join(Dir, "notatimestamp"),
        ok = filelib:ensure_dir(filename:join(NoMetaDir, "x")),
        ok = file:write_file(filename:join(NoMetaDir, "data.txt"), <<"data">>),
        {ok, Deleted} = alBackup:cleanupExpired(0),
        ?assertEqual(0, Deleted),
        ?assert(filelib:is_dir(NoMetaDir))
    after
        cleanupRoot(Tmp)
    end.
