%%%-------------------------------------------------------------------
%% @doc Tests for alPlan.
%% @end
%%%-------------------------------------------------------------------

-module(alPlan_tests).

-include_lib("eunit/include/eunit.hrl").

ets_enables_write_concurrency_test() ->
    ok = alPlan:ensureStarted(),
    ?assertEqual(true, ets:info(alPlan, write_concurrency)).

set_plan_from_titles_test() ->
    Sid = <<"plan-titles-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Plan = alPlan:setPlan(Sid, [<<"step one">>, <<"step two">>, <<"step three">>]),
    Steps = maps:get(steps, Plan),
    ?assertEqual(3, length(Steps)),
    [S1, S2, S3] = Steps,
    ?assertEqual(1, maps:get(id, S1)),
    ?assertEqual(<<"step one">>, maps:get(title, S1)),
    ?assertEqual(pending, maps:get(status, S1)),
    ?assertEqual(2, maps:get(id, S2)),
    ?assertEqual(3, maps:get(id, S3)),
    alPlan:clear(Sid).

set_plan_from_maps_test() ->
    Sid = <<"plan-maps-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Plan = alPlan:setPlan(Sid, [
        #{title => <<"a">>, status => done},
        #{title => <<"b">>, note => <<"note b">>}
    ]),
    Steps = maps:get(steps, Plan),
    [S1, S2] = Steps,
    ?assertEqual(done, maps:get(status, S1)),
    ?assertEqual(<<"note b">>, maps:get(note, S2)),
    ?assertEqual(pending, maps:get(status, S2)),
    alPlan:clear(Sid).

get_plan_empty_when_absent_test() ->
    Sid = <<"plan-absent-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Plan = alPlan:getPlan(Sid),
    ?assertEqual([], maps:get(steps, Plan)),
    ?assertEqual(0, maps:get(updatedAt, Plan)).

get_plan_after_set_test() ->
    Sid = <<"plan-get-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    alPlan:setPlan(Sid, [<<"x">>]),
    Plan = alPlan:getPlan(Sid),
    ?assertEqual(1, length(maps:get(steps, Plan))),
    alPlan:clear(Sid).

update_step_status_test() ->
    Sid = <<"plan-update-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    alPlan:setPlan(Sid, [<<"a">>, <<"b">>]),
    {ok, Plan} = alPlan:updateStep(Sid, 2, #{status => inProgress}),
    Steps = maps:get(steps, Plan),
    [_, S2] = Steps,
    ?assertEqual(inProgress, maps:get(status, S2)),
    alPlan:clear(Sid).

update_step_unknown_returns_error_test() ->
    Sid = <<"plan-unknown-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    alPlan:setPlan(Sid, [<<"a">>]),
    ?assertEqual({error, stepNotFound}, alPlan:updateStep(Sid, 99, #{})),
    alPlan:clear(Sid).

with_summary_counts_done_test() ->
    Plan = #{steps => [
        #{id => 1, status => done, title => <<"a">>},
        #{id => 2, status => pending, title => <<"b">>},
        #{id => 3, status => done, title => <<"c">>}
    ]},
    WithSum = alPlan:withSummary(Plan),
    Summary = maps:get(summary, WithSum),
    ?assertEqual(2, maps:get(done, Summary)),
    ?assertEqual(3, maps:get(total, Summary)).

normalize_status_completed_test() ->
    Sid = <<"plan-completed-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Plan = alPlan:setPlan(Sid, [#{title => <<"x">>, status => completed}]),
    [S1] = maps:get(steps, Plan),
    ?assertEqual(done, maps:get(status, S1)),
    alPlan:clear(Sid).

clear_removes_plan_test() ->
    Sid = <<"plan-clear-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    alPlan:setPlan(Sid, [<<"x">>]),
    ok = alPlan:clear(Sid),
    Plan = alPlan:getPlan(Sid),
    ?assertEqual([], maps:get(steps, Plan)).

update_step_note_test() ->
    Sid = <<"plan-note-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    alPlan:setPlan(Sid, [<<"a">>]),
    {ok, Plan} = alPlan:updateStep(Sid, 1, #{note => <<"my note">>}),
    [S1] = maps:get(steps, Plan),
    ?assertEqual(<<"my note">>, maps:get(note, S1)),
    alPlan:clear(Sid).
