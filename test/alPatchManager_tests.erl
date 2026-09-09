%%% @doc EUnit tests for alPatchManager pure helpers.
-module(alPatchManager_tests).

-include_lib("eunit/include/eunit.hrl").

%% normalizePatch/1 — accepts atom keys, binary keys, and flat form

normalize_patch_atom_keys_test() ->
    Patch = #{file => "x.erl", replace => #{old => <<"a">>, new => <<"b">>}},
    {ok, Normalized} = alPatchManager:normalizePatch(Patch),
    ?assertEqual(<<"a">>, maps:get(old, Normalized)),
    ?assertEqual(<<"b">>, maps:get(new, Normalized)).

normalize_patch_binary_keys_test() ->
    Patch = #{<<"file">> => "x.erl", <<"replace">> => #{<<"old">> => <<"a">>, <<"new">> => <<"b">>}},
    {ok, Normalized} = alPatchManager:normalizePatch(Patch),
    ?assertEqual(<<"a">>, maps:get(old, Normalized)).

normalize_patch_flat_form_test() ->
    {ok, Normalized} = alPatchManager:normalizePatch(#{file => "x.erl", old => <<"a">>, new => <<"b">>}),
    ?assertEqual(<<"a">>, maps:get(old, Normalized)).

normalize_patch_invalid_returns_error_test() ->
    ?assertEqual({error, badPatchFormat}, alPatchManager:normalizePatch(#{})).

normalize_patch_path_is_absname_test() ->
    {ok, #{file := Path}} = alPatchManager:normalizePatch(#{file => "x.erl", old => <<"a">>, new => <<"b">>}),
    ?assertEqual(filename:absname("x.erl"), Path).

%% occurrenceCount/2

occurrence_count_zero_test() ->
    ?assertEqual(0, alPatchManager:occurrenceCount(<<"hello world">>, <<"xyz">>)).

occurrence_count_one_test() ->
    ?assertEqual(1, alPatchManager:occurrenceCount(<<"hello world">>, <<"hello">>)).

occurrence_count_many_test() ->
    ?assertEqual(3, alPatchManager:occurrenceCount(<<"aaa">>, <<"a">>)).

occurrence_count_empty_needle_test() ->
    ?assertEqual(0, alPatchManager:occurrenceCount(<<"text">>, <<>>)).

occurrence_count_substring_test() ->
    ?assertEqual(3, alPatchManager:occurrenceCount(<<"foo bar foo baz foo">>, <<"foo">>)).

%% replaceOnce/3 — only first occurrence (binary:replace default)

replace_once_replaces_first_test() ->
    ?assertEqual(<<"heLlo">>, alPatchManager:replaceOnce(<<"hello">>, <<"l">>, <<"L">>)).

replace_once_no_match_test() ->
    ?assertEqual(<<"hello">>, alPatchManager:replaceOnce(<<"hello">>, <<"x">>, <<"y">>)).

replace_once_multi_test() ->
    ?assertEqual(<<"Xaa">>, alPatchManager:replaceOnce(<<"aaa">>, <<"a">>, <<"X">>)).

%% toBinary/1

to_binary_binary_test() ->
    ?assertEqual(<<"x">>, alPatchManager:toBinary(<<"x">>)).

to_binary_list_test() ->
    ?assertEqual(<<"hi">>, alPatchManager:toBinary("hi")).

to_binary_other_test() ->
    ?assertEqual(<<"42">>, alPatchManager:toBinary(42)).

%% stripBackupSuffix/1

strip_backup_suffix_strips_test() ->
    ?assertEqual("foo.erl", alPatchManager:stripBackupSuffix("foo.erl.ali.bak.123")).

strip_backup_suffix_no_suffix_passthrough_test() ->
    ?assertEqual("foo.erl", alPatchManager:stripBackupSuffix("foo.erl")).

%% normalizePath/1

normalize_path_string_test() ->
    ?assertEqual(filename:absname("foo.erl"), alPatchManager:normalizePath("foo.erl")).

normalize_path_binary_test() ->
    ?assertEqual(filename:absname("foo.erl"), alPatchManager:normalizePath(<<"foo.erl">>)).

%% backupPath/1 — produces file with timestamp suffix

backup_path_format_test() ->
    Backup = alPatchManager:backupPath("foo.erl"),
    ?assert(string:prefix(Backup, "foo.erl.ali.bak.") =/= nomatch),
    %% Verify the timestamp is numeric after the suffix
    Suffix = string:trim(Backup, leading, "foo.erl.ali.bak."),
    ?assertMatch({_, _}, string:to_integer(Suffix)).

%% normalizeOp/1 — atom/binary 归一

normalize_op_atom_test() ->
    ?assertEqual(create, alPatchManager:normalizeOp(create)),
    ?assertEqual(delete, alPatchManager:normalizeOp(delete)),
    ?assertEqual(rename, alPatchManager:normalizeOp(rename)).

normalize_op_binary_test() ->
    ?assertEqual(create, alPatchManager:normalizeOp(<<"create">>)),
    ?assertEqual(delete, alPatchManager:normalizeOp(<<"delete">>)),
    ?assertEqual(rename, alPatchManager:normalizeOp(<<"rename">>)).

normalize_op_unknown_test() ->
    ?assertEqual(unknown, alPatchManager:normalizeOp(<<"bogus">>)),
    ?assertEqual(unknown, alPatchManager:normalizeOp(42)).

%% normalizePatch op forms

normalize_patch_op_create_test() ->
    {ok, #{op := create, file := File, content := Content}} =
        alPatchManager:normalizePatch(#{op => create, file => "x.erl",
                                        content => <<"-module(x).">>}),
    ?assertEqual(filename:absname("x.erl"), File),
    ?assertEqual(<<"-module(x).">>, Content).

normalize_patch_op_create_binary_keys_test() ->
    {ok, #{op := create, file := File, content := Content}} =
        alPatchManager:normalizePatch(#{<<"op">> => <<"create">>,
                                        <<"file">> => "x.erl",
                                        <<"content">> => <<"abc">>}),
    ?assertEqual(filename:absname("x.erl"), File),
    ?assertEqual(<<"abc">>, Content).

normalize_patch_op_delete_test() ->
    {ok, #{op := delete, file := File}} =
        alPatchManager:normalizePatch(#{op => delete, file => "x.erl"}),
    ?assertEqual(filename:absname("x.erl"), File).

normalize_patch_op_rename_test() ->
    {ok, #{op := rename, file := File, to := To}} =
        alPatchManager:normalizePatch(#{op => rename, file => "a.erl", to => "b.erl"}),
    ?assertEqual(filename:absname("a.erl"), File),
    ?assertEqual(filename:absname("b.erl"), To).

normalize_patch_op_rename_binary_keys_test() ->
    {ok, #{op := rename, to := To}} =
        alPatchManager:normalizePatch(#{<<"op">> => <<"rename">>,
                                        <<"file">> => "a.erl",
                                        <<"to">> => "b.erl"}),
    ?assertEqual(filename:absname("b.erl"), To).

normalize_patch_op_unknown_test() ->
    ?assertEqual({error, badPatchFormat},
                 alPatchManager:normalizePatch(#{op => bogus, file => "x.erl"})).

normalize_patch_op_missing_content_test() ->
    ?assertMatch({error, #{reason := missingContent}},
                 alPatchManager:normalizePatch(#{op => create, file => "x.erl"})).

normalize_patch_op_missing_target_test() ->
    ?assertMatch({error, #{reason := missingTarget}},
                 alPatchManager:normalizePatch(#{op => rename, file => "x.erl"})).
