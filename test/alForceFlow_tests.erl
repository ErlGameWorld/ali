-module(alForceFlow_tests).

-include_lib("eunit/include/eunit.hrl").

heal_classify_compile_test() ->
    ?assertEqual(compile,
                 alToolRouter:classifyHealFailures(
                   [<<"verifyCompile: compileFailed [src/x.erl:10]">>])).

heal_classify_test_test() ->
    ?assertEqual(test,
                 alToolRouter:classifyHealFailures(
                   [<<"runEunit: failed\n--- output ---\nmodule_tests">>])).

heal_classify_patch_test() ->
    ?assertEqual(patch,
                 alToolRouter:classifyHealFailures(
                   [<<"applyPatch: oldTextNotFound">>])).

heal_workflow_mentions_tools_test() ->
    W = alToolRouter:healForcedWorkflow(compile),
    ?assertNotEqual(nomatch, binary:match(W, <<"verifyCompile">>)),
    ?assertNotEqual(nomatch, binary:match(W, <<"applyPatch">>)),
    Wp = alToolRouter:healForcedWorkflow(patch),
    ?assertNotEqual(nomatch, binary:match(Wp, <<"suggestions">>)).

batch_plan_detect_test() ->
    PlanRes = #{status => ok, result => #{
        action => plan,
        files => [<<"src/a.erl">>, <<"src/b.erl">>]
    }},
    Trace = [
        {results, [#{role => tool, name => batchRefactor,
                     content => alJson:encode(PlanRes)}]}
    ],
    ?assertMatch({ok, #{}}, alToolRouter:latestBatchPlan(Trace)),
    {ok, Plan} = alToolRouter:latestBatchPlan(Trace),
    Action = maps:get(action, Plan, maps:get(<<"action">>, Plan)),
    ?assert(Action =:= plan orelse Action =:= <<"plan">>).

batch_plan_miss_after_apply_test() ->
    PlanRes = #{status => ok, result => #{action => plan, files => [<<"src/a.erl">>]}},
    ApplyRes = #{status => ok, result => #{action => apply, files => [<<"src/a.erl">>]}},
    Trace = [
        {results, [#{role => tool, name => batchRefactor,
                     content => alJson:encode(ApplyRes)}]},
        {results, [#{role => tool, name => batchRefactor,
                     content => alJson:encode(PlanRes)}]}
    ],
    %% Latest results are apply — no pending plan.
    ?assertEqual(miss, alToolRouter:latestBatchPlan(Trace)).

patch_suggest_similar_test() ->
    Content = <<
        "-module(demo).\n"
        "-export([foo/1]).\n"
        "foo(X) -> X + 1.\n"
        "bar(Y) -> Y - 1.\n"
    >>,
    Needle = <<"foo(X) -> X + 2.">>,
    Sugs = alPatchManager:suggestSimilarSnippets(Content, Needle, 3),
    ?assert(is_list(Sugs)),
    ?assert(length(Sugs) >= 1),
    [#{snippet := Snip} | _] = Sugs,
    ?assertNotEqual(nomatch, binary:match(Snip, <<"foo">>)).

batch_plan_has_forced_workflow_test() ->
    {ok, Plan} = alBatchRefactor:plan(#{modules => [alDocGen]}),
    ?assert(is_binary(maps:get(forcedWorkflow, Plan))),
    ?assertNotEqual(nomatch, binary:match(maps:get(forcedWorkflow, Plan), <<"action=apply">>)),
    ?assert(is_list(maps:get(mustCoverFiles, Plan))).
