%%%-------------------------------------------------------------------
%% @doc Tests for alProgress.
%% @end
%%%-------------------------------------------------------------------

-module(alProgress_tests).

-include_lib("eunit/include/eunit.hrl").

ets_enables_write_concurrency_test() ->
    ok = alProgress:ensureStarted(),
    ?assertEqual(true, ets:info(alProgress, write_concurrency)).

start_creates_running_run_test() ->
    alProgress:ensureStarted(),
    RunId = <<"test-start-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    ok = alProgress:start(RunId),
    Snap = alProgress:snapshot(RunId),
    ?assertEqual(running, maps:get(status, Snap)),
    ?assertEqual(1, maps:get(eventCount, Snap)),
    [First] = maps:get(events, Snap),
    ?assertEqual(started, maps:get(type, First)),
    alProgress:drop(RunId).

emit_appends_event_test() ->
    RunId = <<"test-emit-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    alProgress:start(RunId),
    ok = alProgress:emit(RunId, #{type => step, message => <<"step1">>}),
    ok = alProgress:emit(RunId, #{type => tool, message => <<"tool1">>}),
    Snap = alProgress:snapshot(RunId),
    ?assertEqual(3, maps:get(eventCount, Snap)),
    Events = maps:get(events, Snap),
    [Started, Step, Tool] = Events,
    ?assertEqual(started, maps:get(type, Started)),
    ?assertEqual(step, maps:get(type, Step)),
    ?assertEqual(tool, maps:get(type, Tool)),
    ?assertEqual(0, maps:get(index, Started)),
    ?assertEqual(1, maps:get(index, Step)),
    ?assertEqual(2, maps:get(index, Tool)),
    alProgress:drop(RunId).

snapshot_since_returns_increment_test() ->
    RunId = <<"test-since-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    alProgress:start(RunId),
    alProgress:emit(RunId, #{type => step, message => <<"a">>}),
    alProgress:emit(RunId, #{type => step, message => <<"b">>}),
    alProgress:emit(RunId, #{type => step, message => <<"c">>}),
    Snap = alProgress:snapshot(RunId, 2),
    Events = maps:get(events, Snap),
    ?assertEqual(2, length(Events)),
    [B, C] = Events,
    ?assertEqual(<<"b">>, maps:get(message, B)),
    ?assertEqual(<<"c">>, maps:get(message, C)),
    alProgress:drop(RunId).

finish_ok_marks_completed_test() ->
    RunId = <<"test-finish-ok-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    alProgress:start(RunId),
    ok = alProgress:finish(RunId, {ok, <<"answer">>}),
    Snap = alProgress:snapshot(RunId),
    ?assertEqual(completed, maps:get(status, Snap)),
    ?assertEqual({ok, <<"answer">>}, maps:get(result, Snap)),
    ?assert(maps:is_key(finishedAt, Snap)),
    alProgress:drop(RunId).

finish_error_marks_failed_test() ->
    RunId = <<"test-finish-err-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    alProgress:start(RunId),
    ok = alProgress:finish(RunId, {error, timeout}),
    Snap = alProgress:snapshot(RunId),
    ?assertEqual(failed, maps:get(status, Snap)),
    ?assertEqual({error, timeout}, maps:get(result, Snap)),
    alProgress:drop(RunId).

drop_removes_run_test() ->
    RunId = <<"test-drop-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    alProgress:start(RunId),
    alProgress:drop(RunId),
    Snap = alProgress:snapshot(RunId),
    ?assertEqual(notFound, maps:get(status, Snap)).

snapshot_unknown_returns_not_found_test() ->
    Snap = alProgress:snapshot(<<"nonexistent-run-id">>),
    ?assertEqual(notFound, maps:get(status, Snap)),
    ?assertEqual(0, maps:get(eventCount, Snap)).

emit_after_finish_ignored_test() ->
    RunId = <<"test-emit-after-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    alProgress:start(RunId),
    alProgress:finish(RunId, {ok, done}),
    ok = alProgress:emit(RunId, #{type => step, message => <<"late">>}),
    Snap = alProgress:snapshot(RunId),
    ?assertEqual(1, maps:get(eventCount, Snap)),
    alProgress:drop(RunId).

subscribe_receives_push_test() ->
    RunId = <<"test-sub-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    alProgress:start(RunId),
    ok = alProgress:subscribe(RunId),
    ok = alProgress:emit(RunId, #{type => step, message => <<"pushed">>}),
    receive
        {eProgressEvent, Bin, Ev} ->
            ?assertEqual(to_bin(RunId), Bin),
            ?assertEqual(step, maps:get(type, Ev)),
            ?assertEqual(<<"pushed">>, maps:get(message, Ev))
    after 1000 ->
        ?assert(false)
    end,
    alProgress:unsubscribe(RunId),
    alProgress:drop(RunId).

partial_append_and_answer_test() ->
    RunId = <<"test-partial-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    alProgress:start(RunId),
    ?assertEqual(<<>>, alProgress:getPartial(RunId)),
    ok = alProgress:appendPartial(RunId, <<"hel">>),
    ok = alProgress:appendPartial(RunId, <<"lo">>),
    ?assertEqual(<<"hello">>, alProgress:getPartial(RunId)),
    ok = alProgress:emit(RunId, #{type => answer, text => <<"hello world">>}),
    ?assertEqual(<<"hello world">>, alProgress:getPartial(RunId)),
    alProgress:drop(RunId).

to_bin(B) when is_binary(B) -> B;
to_bin(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).
