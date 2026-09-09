%%% @doc EUnit tests for {@link alTokenStats}.
-module(alTokenStats_tests).

-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% Estimation
%%%===================================================================

estimateAscii_test() ->
    %% 8 ASCII chars / 4 ≈ 2 tokens.
    ?assertEqual(2, alTokenStats:estimate(<<"abcdefgh">>)).

estimateCjk_test() ->
    %% 3 CJK chars / 1.5 = 2 tokens.
    ?assertEqual(2, alTokenStats:estimate(<<"你好世"/utf8>>)).

estimateMixed_test() ->
    %% 4 ASCII (1 token) + 3 CJK (2 tokens) = 3 tokens.
    ?assertEqual(3, alTokenStats:estimate(<<"abcd你好世"/utf8>>)).

estimateListInput_test() ->
    ?assertEqual(2, alTokenStats:estimate("abcdefgh")).

estimateEmpty_test() ->
    ?assertEqual(0, alTokenStats:estimate(<<>>)),
    ?assertEqual(0, alTokenStats:estimate("")).

estimateInvalidUtf8FallsBack_test() ->
    %% Invalid UTF-8 falls back to byte_size / 4.
    ?assertEqual(1, alTokenStats:estimate(<<255, 1, 2, 3, 4>>)).

estimateMessages_test() ->
    Msgs = [
        #{role => user, content => <<"abcdefgh">>},        %% 2 tokens
        #{role => assistant, content => <<"你好世"/utf8>>}, %% 2 tokens
        #{role => tool, content => #{k => <<"abcdefgh">>}} %% JSON-serialized estimate
    ],
    Total = alTokenStats:estimateMessages(Msgs),
    ?assert(Total >= 4).

estimateMessagesSkipsNull_test() ->
    Msgs = [
        #{role => assistant, content => null},
        #{role => assistant, content => undefined}
    ],
    ?assertEqual(0, alTokenStats:estimateMessages(Msgs)).

%%%===================================================================
%%% Tracking
%%%===================================================================

trackRecordsCounts_test() ->
    ok = alTokenStats:reset(),
    ok = alTokenStats:track(<<"gpt-4o">>, <<"abcdefgh">>, <<"abcdefgh">>),
    Stats = alTokenStats:stats(),
    ?assertEqual(2, maps:get(input_tokens, Stats)),
    ?assertEqual(2, maps:get(output_tokens, Stats)),
    ?assertEqual(1, maps:get(apiCalls, Stats)),
    ?assertEqual(4, maps:get(totalTokens, Stats)).

trackAccumulatesAcrossCalls_test() ->
    ok = alTokenStats:reset(),
    ok = alTokenStats:track(<<"gpt-4o">>, <<"abcdefgh">>, <<"abcdefgh">>),
    ok = alTokenStats:track(<<"gpt-4o">>, <<"abcdefgh">>, <<"abcdefgh">>),
    Stats = alTokenStats:stats(),
    ?assertEqual(2, maps:get(apiCalls, Stats)),
    ?assertEqual(4, maps:get(input_tokens, Stats)).

trackSeparatesByModel_test() ->
    ok = alTokenStats:reset(),
    ok = alTokenStats:track(<<"gpt-4o">>, <<"abcdefgh">>, <<"abcdefgh">>),
    ok = alTokenStats:track(<<"deepseek-chat">>, <<"abcdefgh">>, <<"abcdefgh">>),
    Stats = alTokenStats:stats(),
    ByModel = maps:get(byModel, Stats),
    ?assert(maps:is_key(<<"gpt-4o">>, ByModel)),
    ?assert(maps:is_key(<<"deepseek-chat">>, ByModel)).

trackUsageAtomKeys_test() ->
    ok = alTokenStats:reset(),
    ok = alTokenStats:trackUsage(<<"gpt-4o">>,
        #{input_tokens => 100, output_tokens => 50}),
    Stats = alTokenStats:stats(),
    ?assertEqual(100, maps:get(input_tokens, Stats)),
    ?assertEqual(50, maps:get(output_tokens, Stats)).

trackUsageBinaryKeys_test() ->
    ok = alTokenStats:reset(),
    ok = alTokenStats:trackUsage(<<"gpt-4o">>,
        #{<<"input_tokens">> => 200, <<"output_tokens">> => 75}),
    Stats = alTokenStats:stats(),
    ?assertEqual(200, maps:get(input_tokens, Stats)),
    ?assertEqual(75, maps:get(output_tokens, Stats)).

trackUsageOpenaiKeys_test() ->
    ok = alTokenStats:reset(),
    ok = alTokenStats:trackUsage(<<"gpt-4o">>,
        #{prompt_tokens => 11, completion_tokens => 7}),
    Stats = alTokenStats:stats(),
    ?assertEqual(11, maps:get(input_tokens, Stats)),
    ?assertEqual(7, maps:get(output_tokens, Stats)).

trackUsageMissingKeys_test() ->
    ok = alTokenStats:reset(),
    ok = alTokenStats:trackUsage(<<"gpt-4o">>, #{}),
    Stats = alTokenStats:stats(),
    ?assertEqual(0, maps:get(input_tokens, Stats)),
    ?assertEqual(0, maps:get(output_tokens, Stats)),
    ?assertEqual(1, maps:get(apiCalls, Stats)).

%%%===================================================================
%%% Pricing & cost
%%%===================================================================

pricingKnownModels_test() ->
    P = alTokenStats:pricing(),
    ?assertEqual({2.5, 10.0}, maps:get(<<"gpt-4o">>, P)),
    ?assertEqual({0.27, 1.1}, maps:get(<<"deepseek-chat">>, P)),
    ?assertEqual({3.0, 15.0}, maps:get(<<"claude-3-5-sonnet-20241022">>, P)).

modelCostKnown_test() ->
    %% 1M input × 2.5 + 1M output × 10.0 = 12.5.
    Cost = alTokenStats:modelCost(<<"gpt-4o">>, 1000000, 1000000),
    ?assertEqual(12.5, Cost).

modelCostUnknownModel_test() ->
    ?assertEqual(0.0, alTokenStats:modelCost(<<"unknown-model">>, 9999, 9999)).

statsIncludesCost_test() ->
    ok = alTokenStats:reset(),
    ok = alTokenStats:trackUsage(<<"gpt-4o">>,
        #{input_tokens => 1000000, output_tokens => 1000000}),
    Stats = alTokenStats:stats(),
    ?assertEqual(12.5, maps:get(estimatedCostUsd, Stats)).

statsByModelHasCostField_test() ->
    ok = alTokenStats:reset(),
    ok = alTokenStats:trackUsage(<<"gpt-4o-mini">>,
        #{input_tokens => 1000000, output_tokens => 1000000}),
    Stats = alTokenStats:stats(),
    ByModel = maps:get(byModel, Stats),
    Entry = maps:get(<<"gpt-4o-mini">>, ByModel),
    ?assert(maps:is_key(estimatedCostUsd, Entry)),
    ?assertEqual(0.75, maps:get(estimatedCostUsd, Entry)).

%%%===================================================================
%%% Reset
%%%===================================================================

resetClearsCounters_test() ->
    ok = alTokenStats:reset(),
    ok = alTokenStats:track(<<"gpt-4o">>, <<"abcdefgh">>, <<"abcdefgh">>),
    ?assertEqual(1, maps:get(apiCalls, alTokenStats:stats())),
    ok = alTokenStats:reset(),
    Stats = alTokenStats:stats(),
    ?assertEqual(0, maps:get(apiCalls, Stats)),
    ?assertEqual(0, maps:get(totalTokens, Stats)),
    ?assertEqual(0.0, maps:get(estimatedCostUsd, Stats)),
    ?assertEqual(#{}, maps:get(byModel, Stats)).

statsEmptyDefault_test() ->
    ok = alTokenStats:reset(),
    Stats = alTokenStats:stats(),
    ?assertEqual(0, maps:get(input_tokens, Stats)),
    ?assertEqual(0, maps:get(output_tokens, Stats)),
    ?assertEqual(0, maps:get(totalTokens, Stats)),
    ?assertEqual(0, maps:get(apiCalls, Stats)),
    ?assertEqual(0.0, maps:get(estimatedCostUsd, Stats)),
    ?assertEqual(#{}, maps:get(byModel, Stats)).
