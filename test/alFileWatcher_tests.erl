%%% @doc EUnit tests for alFileWatcher.
-module(alFileWatcher_tests).

-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% 关键导出存在性
%%--------------------------------------------------------------------
critical_exports_test() ->
    Exports = alFileWatcher:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{start_link, 0}, {init, 1}, {handle_call, 3},
                   {handle_cast, 2}, {handle_info, 2}, {terminate, 2}]].

%%--------------------------------------------------------------------
%% parseList/1：逗号分隔字符串 → trimmed lower binary 列表
%%--------------------------------------------------------------------
parseList_string_test() ->
    ?assertEqual([<<"erl">>, <<"hrl">>, <<"rs">>],
                 alFileWatcher:parseList("erl,hrl,rs")).

parseList_withSpaces_test() ->
    ?assertEqual([<<"erl">>, <<"hrl">>],
                 alFileWatcher:parseList(" erl , hrl ")).

parseList_mixedCase_test() ->
    ?assertEqual([<<"erl">>, <<"rs">>],
                 alFileWatcher:parseList("ERL,Rs")).

parseList_binary_test() ->
    ?assertEqual([<<"erl">>, <<"hrl">>],
                 alFileWatcher:parseList(<<"erl,hrl">>)).

parseList_empty_test() ->
    ?assertEqual([], alFileWatcher:parseList("")),
    ?assertEqual([], alFileWatcher:parseList(<<"">>)).

parseList_other_test() ->
    ?assertEqual([], alFileWatcher:parseList(12345)).

%%--------------------------------------------------------------------
%% diffChanged/2：新增/修改/删除路径
%%--------------------------------------------------------------------
diffChanged_noChange_test() ->
    Snap = #{<<"a.erl">> => 1, <<"b.erl">> => 2},
    ?assertEqual([], alFileWatcher:diffChanged(Snap, Snap)).

diffChanged_added_test() ->
    Old = #{<<"a.erl">> => 1},
    New = #{<<"a.erl">> => 1, <<"b.erl">> => 2},
    ?assertEqual([<<"b.erl">>], alFileWatcher:diffChanged(Old, New)).

diffChanged_modified_test() ->
    Old = #{<<"a.erl">> => 1},
    New = #{<<"a.erl">> => 5},
    ?assertEqual([<<"a.erl">>], alFileWatcher:diffChanged(Old, New)).

diffChanged_removed_test() ->
    Old = #{<<"a.erl">> => 1, <<"b.erl">> => 2},
    New = #{<<"a.erl">> => 1},
    Diff = alFileWatcher:diffChanged(Old, New),
    ?assert(lists:member(<<"b.erl">>, Diff)).

diffChanged_mixed_test() ->
    Old = #{<<"a.erl">> => 1, <<"b.erl">> => 2},
    New = #{<<"b.erl">> => 3, <<"c.erl">> => 4},
    Diff = lists:sort(alFileWatcher:diffChanged(Old, New)),
    ?assertEqual([<<"a.erl">>, <<"b.erl">>, <<"c.erl">>], Diff).

%%--------------------------------------------------------------------
%% snapshotToMap/1：转 list 并按 key 排序
%%--------------------------------------------------------------------
snapshotToMap_sorted_test() ->
    Snap = #{<<"z.erl">> => 1, <<"a.erl">> => 2, <<"m.erl">> => 3},
    ?assertEqual([{<<"a.erl">>, 2}, {<<"m.erl">>, 3}, {<<"z.erl">>, 1}],
                 alFileWatcher:snapshotToMap(Snap)).

snapshotToMap_empty_test() ->
    ?assertEqual([], alFileWatcher:snapshotToMap(#{})).

%%--------------------------------------------------------------------
%% pathMatchesAny/2：路径段匹配（不误匹配子串）
%%--------------------------------------------------------------------
pathMatchesAny_segmentMatch_test() ->
    IgnoreSet = sets:from_list([<<"src">>, <<"test">>]),
    %% src 作为独立路径段应匹配
    ?assert(alFileWatcher:pathMatchesAny(<<"project/src/main.erl">>, IgnoreSet)),
    ?assert(alFileWatcher:pathMatchesAny(<<"project/test/foo.erl">>, IgnoreSet)).

pathMatchesAny_noSubstringMatch_test() ->
    IgnoreSet = sets:from_list([<<"src">>]),
    %% binary_src 不应被 src 误匹配
    ?assertNot(alFileWatcher:pathMatchesAny(<<"project/binary_src/foo.erl">>, IgnoreSet)),
    %% src_legacy 也不应被 src 误匹配
    ?assertNot(alFileWatcher:pathMatchesAny(<<"project/src_legacy/foo.erl">>, IgnoreSet)).

pathMatchesAny_backslashPath_test() ->
    IgnoreSet = sets:from_list([<<"src">>]),
    %% Windows 反斜杠路径也应正确匹配
    ?assert(alFileWatcher:pathMatchesAny(<<"project\\src\\main.erl">>, IgnoreSet)),
    ?assertNot(alFileWatcher:pathMatchesAny(<<"project\\binary_src\\main.erl">>, IgnoreSet)).
