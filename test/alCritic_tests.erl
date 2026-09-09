%%% @doc EUnit tests for alCritic pure helpers.
-module(alCritic_tests).

-include_lib("eunit/include/eunit.hrl").

%% shouldRevise/4 — verdict / round / max / prevFeedback decision

should_revise_pass_returns_false_test() ->
    ?assertEqual(false, alCritic:shouldRevise(#{verdict => pass}, 1, 3, undefined)).

should_revise_at_max_rounds_returns_false_test() ->
    ?assertEqual(false, alCritic:shouldRevise(#{verdict => warn}, 3, 3, undefined)).

should_revise_within_max_rounds_returns_true_test() ->
    ?assertEqual(true, alCritic:shouldRevise(#{verdict => warn}, 1, 3, undefined)).

should_revise_same_feedback_stops_loop_test() ->
    ?assertEqual(false, alCritic:shouldRevise(#{verdict => warn, feedback => <<"same">>}, 1, 3, <<"same">>)).

should_revise_different_feedback_continues_test() ->
    ?assertEqual(true, alCritic:shouldRevise(#{verdict => warn, feedback => <<"new">>}, 1, 3, <<"old">>)).

%% parseCritique/1 — JSON extraction with fallback

parse_critique_valid_json_test() ->
    Json = <<"{\"verdict\":\"warn\",\"score\":0.3,\"feedback\":\"risky\",\"safe\":false}">>,
    ?assertMatch(#{verdict := warn, score := 0.3, feedback := <<"risky">>, safe := false},
                 alCritic:parseCritique(Json)).

parse_critique_embedded_in_text_test() ->
    Text = <<"The review: {\"verdict\":\"pass\",\"score\":0.9,\"feedback\":\"ok\",\"safe\":true} done">>,
    ?assertMatch(#{verdict := pass, score := 0.9}, alCritic:parseCritique(Text)).

parse_critique_malformed_falls_back_test() ->
    Result = alCritic:parseCritique(<<"not json at all">>),
    ?assertMatch(#{provider := localFallback, verdict := pass}, Result).

parse_critique_risky_text_falls_back_to_reject_test() ->
    Result = alCritic:parseCritique(<<"please apply_patch now">>),
    ?assertMatch(#{provider := localFallback, verdict := reject, safe := false}, Result).

parse_critique_list_input_test() ->
    Result = alCritic:parseCritique("not even binary"),
    ?assertMatch(#{provider := localFallback}, Result).

%% scanFindings/1 — keyword scan via ?RiskRules

contains_risky_apply_patch_test() ->
    ?assertNotEqual([], alCritic:scanFindings(<<"please apply_patch now">>)).

contains_risky_run_mfa_test() ->
    %% runMfa 是嵌入节点的正规工具，不再当作高危关键词
    ?assertEqual([], alCritic:scanFindings(<<"use run_mfa to call">>)).

contains_risky_delete_test() ->
    ?assertNotEqual([], alCritic:scanFindings(<<"DELETE this row">>)).

contains_risky_drop_table_test() ->
    ?assertNotEqual([], alCritic:scanFindings(<<"DROP TABLE users">>)).

contains_risky_safe_text_test() ->
    ?assertEqual([], alCritic:scanFindings(<<"hello world">>)).

%% maxSeverity/1 + scoreFromFindings/1

max_severity_empty_test() ->
    ?assertEqual(none, alCritic:maxSeverity([])).

max_severity_high_test() ->
    Findings = [#{severity => low}, #{severity => high}, #{severity => medium}],
    ?assertEqual(high, alCritic:maxSeverity(Findings)).

score_no_findings_is_safe_test() ->
    ?assertEqual(0.85, alCritic:scoreFromFindings([])).

score_high_severity_lowers_test() ->
    Findings = [#{severity => high}],
    ?assert(alCritic:scoreFromFindings(Findings) < 1.0).

%% reviseSystemPrompt/0

revise_system_prompt_returns_binary_test() ->
    Prompt = alCritic:reviseSystemPrompt(),
    ?assert(is_binary(Prompt)),
    ?assert(byte_size(Prompt) > 0).

%% criticMessages/3 — message construction

critic_messages_returns_two_messages_test() ->
    Messages = alCritic:criticMessages(<<"q">>, <<"a">>, #{}),
    ?assertEqual(2, length(Messages)),
    [Sys, User] = Messages,
    ?assertEqual(system, maps:get(role, Sys)),
    ?assert(is_binary(maps:get(content, Sys))),
    ?assertEqual(user, maps:get(role, User)),
    ?assertMatch(#{question := <<"q">>, answer := <<"a">>, context := #{}}, maps:get(content, User)).

%% localCritique/4 — fallback path

local_critique_safe_answer_test() ->
    Result = alCritic:localCritique(<<"q">>, <<"safe answer">>, #{}, llmUnavailable),
    ?assertMatch(#{provider := localFallback, reason := llmUnavailable,
                   verdict := pass, safe := true}, Result).

local_critique_risky_answer_test() ->
    Result = alCritic:localCritique(<<"q">>, <<"apply_patch now">>, #{}, llmUnavailable),
    ?assertMatch(#{verdict := reject, safe := false}, Result).

%% toBinary/1

to_binary_binary_passthrough_test() ->
    ?assertEqual(<<"x">>, alCritic:toBinary(<<"x">>)).

to_binary_atom_test() ->
    ?assertEqual(<<"hello">>, alCritic:toBinary(hello)).

to_binary_list_test() ->
    ?assertEqual(<<"hi">>, alCritic:toBinary("hi")).

to_binary_map_test() ->
    Bin = alCritic:toBinary(#{a => 1}),
    ?assert(is_binary(Bin)).
