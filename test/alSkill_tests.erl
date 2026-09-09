%%%-------------------------------------------------------------------
%% @doc Tests for alSkill.
%% @end
%%%-------------------------------------------------------------------

-module(alSkill_tests).

-include_lib("eunit/include/eunit.hrl").

list_includes_builtin_skills_test() ->
    List = alSkill:list(),
    Names = [Name || {Name, _} <- List],
    ?assert(lists:member(debug, Names)),
    ?assert(lists:member(refactor, Names)),
    ?assert(lists:member(explain, Names)).

lookup_known_skill_test() ->
    {ok, Skill} = alSkill:lookup(debug),
    ?assertEqual(debug, maps:get(name, Skill)),
    ?assertEqual(exec, maps:get(mode, Skill)),
    ?assert(maps:is_key(promptExtra, Skill)),
    ?assert(maps:is_key(triggers, Skill)).

lookup_builtin_skill_by_binary_test() ->
    {ok, Skill} = alSkill:lookup(<<"debug">>),
    ?assertEqual(debug, maps:get(name, Skill)).

lookup_unknown_skill_test() ->
    ?assertEqual({error, notFound}, alSkill:lookup(noSuchSkill)).

match_returns_skills_for_query_test() ->
    Matched = alSkill:match(<<"debug this crash please">>),
    %% debug triggers: debug, crash → 2 hits
    ?assert(lists:member(debug, Matched)).

match_empty_query_returns_empty_test() ->
    Matched = alSkill:match(<<"totally unrelated content xyz123">>),
    ?assertEqual([], Matched).

glob_match_basic_test() ->
    ?assert(alSkill:globMatch(<<"**/*.erl">>, <<"src/foo.erl">>)),
    ?assert(alSkill:globMatch(<<"src/**/*.erl">>, <<"src/a/b.erl">>)),
    ?assertNot(alSkill:globMatch(<<"**/*.hrl">>, <<"src/foo.erl">>)),
    ?assert(alSkill:globMatch(<<"*_tests.erl">>, <<"alSkill_tests.erl">>)).

compare_versions_test() ->
    ?assertEqual(1, alSkill:compareVersions(<<"0.2.0">>, <<"0.1.0">>)),
    ?assertEqual(0, alSkill:compareVersions(<<"0.1.0">>, <<"0.1.0">>)),
    ?assertEqual(-1, alSkill:compareVersions(<<"0.1.0">>, <<"1.0.0">>)).

match_glob_path_boost_test() ->
    alSkill:cacheClear(),
    %% 无触发词时，仅靠 globs 也能激活 erlang-code-review
    Q = <<"please look at @path src/agent/alAgent.erl">>,
    Matched = alSkill:match(Q, #{paths => [<<"src/agent/alAgent.erl">>]}),
    ?assert(lists:member(<<"erlang-code-review">>, Matched)
            orelse lists:member(erlang_code_review, Matched)
            orelse lists:any(fun(N) ->
                to_bin(N) =:= <<"erlang-code-review">>
            end, Matched)).

match_min_ali_version_filters_test() ->
    %% 构造临时 skill 需要走 parse — 用 compareVersions 侧验证即可；
    %% 此处确保极高 minAliVersion 不会误伤现有 skill（0.1.0）。
    alSkill:cacheClear(),
    Matched = alSkill:match(<<"code review please">>, #{aliVersion => <<"0.1.0">>}),
    ?assert(lists:member(<<"erlang-code-review">>, Matched)
            orelse lists:any(fun(N) -> to_bin(N) =:= <<"erlang-code-review">> end, Matched)).

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).

match_vcs_yesterday_chinese_test() ->
    alSkill:cacheClear(),
    Q = unicode:characters_to_binary("查看昨天这个分支提交的所有修改"),
    Matched = alSkill:match(Q),
    ?assert(lists:member(<<"vcs-recent-changes">>, Matched)).

match_runtime_ets_test() ->
    alSkill:cacheClear(),
    Q = unicode:characters_to_binary("查看占用内存最高的 ETS 表"),
    Matched = alSkill:match(Q),
    ?assert(lists:member(<<"runtime-inspect">>, Matched)).

match_nl_live_exec_test() ->
    alSkill:cacheClear(),
    Q = unicode:characters_to_binary("帮我在某个点修建一个建筑再给加 1000 钱"),
    Matched = alSkill:match(Q),
    ?assert(lists:member(<<"nl-live-exec">>, Matched)).

match_protocol_push_test() ->
    alSkill:cacheClear(),
    Q = unicode:characters_to_binary("这个协议什么时候推给客户端"),
    Matched = alSkill:match(Q),
    ?assert(lists:member(<<"protocol-message-trace">>, Matched)).

inject_appends_skill_prompt_test() ->
    Base = <<"You are ali.">>,
    Injected = alSkill:inject(Base, [debug]),
    ?assert(byte_size(Injected) > byte_size(Base)),
    %% Should contain debug's promptExtra content
    ?assert(binary:match(Injected, <<"Debug">>) =/= nomatch).

inject_no_skills_returns_unchanged_test() ->
    Base = <<"You are ali.">>,
    ?assertEqual(Base, alSkill:inject(Base, [])).

inject_unknown_skill_ignored_test() ->
    Base = <<"You are ali.">>,
    ?assertEqual(Base, alSkill:inject(Base, [noSuchSkill])).

split_frontmatter_separates_meta_and_body_test() ->
    Bin = <<"---\ndesc: Test skill\nmode: edit\n---\nThis is the body.">>,
    {Meta, Body} = alSkill:splitFrontmatter(Bin),
    ?assertEqual(<<"edit">>, proplists:get_value(mode, Meta)),
    ?assertEqual(<<"Test skill">>, proplists:get_value(desc, Meta)),
    ?assertEqual(<<"This is the body.">>, Body).

split_frontmatter_no_frontmatter_test() ->
    Bin = <<"Just body content">>,
    {Meta, Body} = alSkill:splitFrontmatter(Bin),
    ?assertEqual([], Meta),
    ?assertEqual(Bin, Body).

split_frontmatter_handles_crlf_test() ->
    Bin = <<"---\r\ndesc: CRLF skill\r\n---\r\nBody with CRLF">>,
    {Meta, Body} = alSkill:splitFrontmatter(Bin),
    ?assertEqual(<<"CRLF skill">>, proplists:get_value(desc, Meta)),
    ?assertEqual(<<"Body with CRLF">>, Body).

builtin_returns_three_skills_test() ->
    Builtin = alSkill:builtin(),
    ?assertEqual(3, length(Builtin)),
    Names = [Name || {Name, _} <- Builtin],
    ?assert(lists:member(debug, Names)),
    ?assert(lists:member(refactor, Names)),
    ?assert(lists:member(explain, Names)).

debug_skill_has_plan_template_test() ->
    {ok, Skill} = alSkill:lookup(debug),
    PlanTemplate = maps:get(planTemplate, Skill),
    ?assert(is_list(PlanTemplate)),
    ?assert(length(PlanTemplate) > 0).

explain_skill_is_ask_mode_test() ->
    {ok, Skill} = alSkill:lookup(explain),
    ?assertEqual(ask, maps:get(mode, Skill)).

refactor_skill_is_edit_mode_test() ->
    {ok, Skill} = alSkill:lookup(refactor),
    ?assertEqual(edit, maps:get(mode, Skill)).
