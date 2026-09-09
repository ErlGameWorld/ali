%%% @doc EUnit tests for alReviewPackage and edit-mode promotion.
-module(alReviewPackage_tests).

-include_lib("eunit/include/eunit.hrl").

%% 测试临时目录基址：项目内 .eunit（gitignored，且不在 indexIgnore 黑名单，
%% 沙箱环境禁止写 AppData user_cache）。
testTmpDir() ->
    filename:absname(".eunit").

scan_detects_bare_catch_test() ->
    Src = <<"-module(t).\n-export([f/0]).\nf() -> catch _:_ -> ok end.\n">>,
    Findings = alReviewPackage:scanSource(<<"src/t.erl">>, Src),
    Rules = [maps:get(rule, F) || F <- Findings],
    ?assert(lists:member(swallowCatch, Rules)).

scan_detects_os_cmd_test() ->
    Src = <<"x() -> os:cmd(\"ls\").\n">>,
    Findings = alReviewPackage:scanSource(<<"src/x.erl">>, Src),
    ?assert(lists:any(fun(F) -> maps:get(rule, F) =:= osCmd end, Findings)).

summarize_counts_test() ->
    Fs = [
        #{severity => blocker},
        #{severity => major},
        #{severity => major},
        #{severity => minor}
    ],
    S = alReviewPackage:summarizeFindings(Fs),
    ?assertEqual(4, maps:get(total, S)),
    ?assertEqual(1, maps:get(blocker, S)),
    ?assertEqual(2, maps:get(major, S)),
    ?assertEqual(1, maps:get(minor, S)).

build_from_files_test() ->
    Dir = filename:join(testTmpDir(),
                        "rp_" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
    Path = filename:join(Dir, "demo.erl"),
    ok = file:write_file(Path, <<"-module(demo).\nf() -> timer:sleep(1).\n">>),
    {ok, Pkg} = alReviewPackage:build(#{files => [Path]}),
    ?assert(maps:is_key(findings, Pkg)),
    ?assert(maps:is_key(summary, Pkg)),
    _ = file:del_dir_r(Dir).

code_edit_intent_promotes_test() ->
    ?assert(alAgent:isCodeEditIntent(<<"帮我改代码"/utf8>>)),
    ?assert(alAgent:isCodeEditIntent(<<"refactor this module">>)),
    ?assert(alAgent:isCodeEditIntent(<<"fix bug in src/foo.erl">>)),
    Opts = alAgent:maybePromoteEditMode(<<"请修改代码"/utf8>>, #{mode => ask}),
    ?assertEqual(edit, maps:get(mode, Opts)),
    ?assertEqual(true, maps:get(modePromoted, Opts)).

live_data_does_not_promote_test() ->
    %% 改玩家数据：保持 ask
    ?assertNot(alAgent:isCodeEditIntent(<<"改一下玩家金币"/utf8>>)),
    Opts = alAgent:maybePromoteEditMode(<<"改一下玩家金币"/utf8>>, #{mode => ask}),
    ?assertEqual(ask, maps:get(mode, Opts, ask)).

tool_registered_test() ->
    ok = alToolCatalog:cacheClear(),
    ?assert(lists:member(reviewPackage, alToolCatalog:allTools())),
    ?assertEqual(read, alPolicy:level(reviewPackage)).
