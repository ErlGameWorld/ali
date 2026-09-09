-module(alBatchRefactor_tests).

-include_lib("eunit/include/eunit.hrl").

normalize_action_test() ->
    ?assertEqual(plan, alBatchRefactor:normalizeAction(<<"plan">>)),
    ?assertEqual(apply, alBatchRefactor:normalizeAction(apply)),
    ?assertEqual(planAndApply, alBatchRefactor:normalizeAction(<<"plan_and_apply">>)).

plan_modules_test() ->
    {ok, Plan} = alBatchRefactor:plan(#{
        modules => [alDocGen],
        intent => <<"docs polish">>
    }),
    ?assertEqual(plan, maps:get(action, Plan)),
    ?assert(is_list(maps:get(files, Plan))),
    ?assert(is_binary(maps:get(mermaid, Plan))),
    ?assertNotEqual(nomatch, binary:match(maps:get(mermaid, Plan), <<"flowchart">>)),
    ?assert(is_binary(maps:get(markdown, Plan))).

apply_empty_test() ->
    ?assertMatch({error, #{reason := emptyPatches}},
                 alBatchRefactor:apply(#{patches => []})).

catalog_batch_refactor_test() ->
    alToolCatalog:cacheClear(),
    Spec = alToolCatalog:toolSpec(batchRefactor),
    ?assertEqual(batchRefactor, maps:get(name, Spec)),
    ?assertNotEqual(<<"Unknown tool">>, maps:get(description, Spec)).
