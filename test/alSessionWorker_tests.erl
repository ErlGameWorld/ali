%%%-------------------------------------------------------------------
%% @doc Tests for alSessionWorker.
%% @end
%%%-------------------------------------------------------------------

-module(alSessionWorker_tests).

-include_lib("eunit/include/eunit.hrl").

start_link_and_snapshot_test() ->
    {ok, Pid} = alSessionWorker:start_link(<<"snap-test">>, #{}),
    Snap = alSessionWorker:snapshot(Pid),
    ?assertEqual(<<"snap-test">>, maps:get(id, Snap)),
    ?assertEqual(0, maps:get(pendingAskCount, Snap)),
    ?assertEqual(false, maps:get(hasLlmOverride, Snap)),
    alSessionWorker:stop(Pid).

set_llm_override_updates_snapshot_test() ->
    {ok, Pid} = alSessionWorker:start_link(<<"override-test">>, #{}),
    ok = alSessionWorker:setLlmOverride(Pid, #{model => <<"gpt-4">>}),
    timer:sleep(50),
    Snap = alSessionWorker:snapshot(Pid),
    ?assertEqual(true, maps:get(hasLlmOverride, Snap)),
    alSessionWorker:stop(Pid).

init_opts_carries_llm_override_test() ->
    {ok, Pid} = alSessionWorker:start_link(<<"init-override">>, #{llmOverride => #{model => <<"m">>}}),
    Snap = alSessionWorker:snapshot(Pid),
    ?assertEqual(true, maps:get(hasLlmOverride, Snap)),
    alSessionWorker:stop(Pid).

cancel_ask_all_with_no_pending_returns_zero_test() ->
    {ok, Pid} = alSessionWorker:start_link(<<"cancel-empty">>, #{}),
    Result = alSessionWorker:cancelAsk(Pid, all),
    ?assertEqual(0, maps:get(cancelled, Result)),
    alSessionWorker:stop(Pid).

cancel_by_task_id_unknown_returns_error_test() ->
    {ok, Pid} = alSessionWorker:start_link(<<"cancel-unknown">>, #{}),
    ?assertEqual({error, notFound}, alSessionWorker:cancelByTaskId(Pid, <<"no-such">>)),
    alSessionWorker:stop(Pid).

pending_list_empty_when_no_asks_test() ->
    {ok, Pid} = alSessionWorker:start_link(<<"pending-empty">>, #{}),
    ?assertEqual([], alSessionWorker:pendingList(Pid)),
    alSessionWorker:stop(Pid).

unknown_call_returns_error_test() ->
    {ok, Pid} = alSessionWorker:start_link(<<"unknown">>, #{}),
    ?assertEqual({error, unknownRequest}, gen_server:call(Pid, weird_message)),
    alSessionWorker:stop(Pid).

snapshot_has_timestamps_test() ->
    {ok, Pid} = alSessionWorker:start_link(<<"ts-test">>, #{}),
    Snap = alSessionWorker:snapshot(Pid),
    ?assert(maps:is_key(createdAt, Snap)),
    ?assert(maps:is_key(updatedAt, Snap)),
    Created = maps:get(createdAt, Snap),
    Updated = maps:get(updatedAt, Snap),
    ?assert(Created =< Updated),
    alSessionWorker:stop(Pid).

clear_session_with_no_asks_returns_zero_test() ->
    {ok, Pid} = alSessionWorker:start_link(<<"clear-empty">>, #{}),
    Result = alSessionWorker:clearSession(Pid),
    ?assertEqual(0, Result),
    alSessionWorker:stop(Pid).

init_with_default_opts_succeeds_test() ->
    {ok, Pid} = alSessionWorker:start_link(<<"default-opts">>, #{}),
    Snap = alSessionWorker:snapshot(Pid),
    ?assertEqual(<<"default-opts">>, maps:get(id, Snap)),
    alSessionWorker:stop(Pid).

stop_terminates_worker_test() ->
    {ok, Pid} = alSessionWorker:start_link(<<"stop-test">>, #{}),
    ok = alSessionWorker:stop(Pid),
    ?assertNot(is_process_alive(Pid)).

%%%===================================================================
%%% Mode (ask | edit | exec) tests
%%%===================================================================

get_mode_default_is_ask_test() ->
    {ok, Pid} = alSessionWorker:start_link(<<"mode-default">>, #{}),
    ?assertEqual({ok, ask}, alSessionWorker:getMode(Pid)),
    alSessionWorker:stop(Pid).

set_mode_to_edit_test() ->
    {ok, Pid} = alSessionWorker:start_link(<<"mode-edit">>, #{}),
    ok = alSessionWorker:setMode(Pid, edit),
    ?assertEqual({ok, edit}, alSessionWorker:getMode(Pid)),
    alSessionWorker:stop(Pid).

set_mode_to_exec_test() ->
    {ok, Pid} = alSessionWorker:start_link(<<"mode-exec">>, #{}),
    ok = alSessionWorker:setMode(Pid, exec),
    ?assertEqual({ok, exec}, alSessionWorker:getMode(Pid)),
    alSessionWorker:stop(Pid).

set_mode_back_to_ask_test() ->
    {ok, Pid} = alSessionWorker:start_link(<<"mode-back">>, #{}),
    ok = alSessionWorker:setMode(Pid, edit),
    ok = alSessionWorker:setMode(Pid, ask),
    ?assertEqual({ok, ask}, alSessionWorker:getMode(Pid)),
    alSessionWorker:stop(Pid).

init_opts_carries_mode_exec_test() ->
    {ok, Pid} = alSessionWorker:start_link(<<"mode-init-exec">>, #{mode => exec}),
    ?assertEqual({ok, exec}, alSessionWorker:getMode(Pid)),
    alSessionWorker:stop(Pid).

init_opts_mode_binary_edit_test() ->
    {ok, Pid} = alSessionWorker:start_link(<<"mode-init-bin">>, #{mode => <<"edit">>}),
    ?assertEqual({ok, edit}, alSessionWorker:getMode(Pid)),
    alSessionWorker:stop(Pid).

init_opts_mode_binary_ask_test() ->
    {ok, Pid} = alSessionWorker:start_link(<<"mode-init-bin-ask">>, #{mode => <<"ask">>}),
    ?assertEqual({ok, ask}, alSessionWorker:getMode(Pid)),
    alSessionWorker:stop(Pid).

init_opts_mode_invalid_defaults_ask_test() ->
    {ok, Pid} = alSessionWorker:start_link(<<"mode-init-bad">>, #{mode => bogus}),
    ?assertEqual({ok, ask}, alSessionWorker:getMode(Pid)),
    alSessionWorker:stop(Pid).

snapshot_includes_mode_test() ->
    {ok, Pid} = alSessionWorker:start_link(<<"mode-snap">>, #{}),
    Snap = alSessionWorker:snapshot(Pid),
    ?assert(maps:is_key(mode, Snap)),
    ?assertEqual(ask, maps:get(mode, Snap)),
    alSessionWorker:stop(Pid).

snapshot_mode_reflects_set_mode_test() ->
    {ok, Pid} = alSessionWorker:start_link(<<"mode-snap-edit">>, #{}),
    ok = alSessionWorker:setMode(Pid, exec),
    Snap = alSessionWorker:snapshot(Pid),
    ?assertEqual(exec, maps:get(mode, Snap)),
    alSessionWorker:stop(Pid).
