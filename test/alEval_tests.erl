-module(alEval_tests).
-include_lib("eunit/include/eunit.hrl").

expr_add_test() ->
    {ok, R} = alEval:eval(<<"1+2.">>),
    ?assertEqual(3, maps:get(result, R)),
    ?assertEqual(expr, maps:get(kind, R)),
    ?assertEqual(true, maps:get(executed, R)).

expr_missing_dot_test() ->
    {ok, R} = alEval:eval("lists:seq(1, 3)"),
    ?assertEqual([1, 2, 3], maps:get(result, R)).

fun_with_args_test() ->
    {ok, R} = alEval:eval(<<"fun(X) -> X + 1 end.">>, #{args => [41]}),
    ?assertEqual(42, maps:get(result, R)),
    ?assertEqual(fun_expr, maps:get(kind, R)),
    ?assertEqual(1, maps:get(arity, R)).

fun_zero_arity_test() ->
    {ok, R} = alEval:eval("fun() -> erlang:system_info(process_count) end.", #{args => []}),
    ?assert(is_integer(maps:get(result, R))).

remote_allowed_test() ->
    {ok, R} = alEval:eval("erlang:system_info(process_count)."),
    ?assert(is_integer(maps:get(result, R))),
    ?assert(lists:member({erlang, system_info, 1}, maps:get(remoteCalls, R))).

remote_blacklist_test() ->
    {error, Err} = alEval:eval("os:cmd(\"echo hi\")."),
    ?assertEqual(forbiddenCall, maps:get(reason, Err)).

apply_rejected_test() ->
    {error, Err} = alEval:eval("apply(erlang, system_info, [process_count])."),
    ?assertEqual(forbiddenCall, maps:get(reason, Err)).

dynamic_remote_rejected_test() ->
    {error, Err} = alEval:eval("M = erlang, M:system_info(process_count)."),
    %% either dynamic remote on call, or local match then dynamic
    ?assert(lists:member(maps:get(reason, Err),
                         [dynamicRemoteCall, localCallNotAllowed, parseError, compileError,
                          dynamicCall])).

dry_run_test() ->
    {ok, R} = alEval:eval("1+1.", #{dryRun => true}),
    ?assertEqual(true, maps:get(dryRun, R)),
    ?assertEqual(false, maps:get(executed, R)),
    ?assertEqual(true, maps:get(compileOk, R)),
    ?assertEqual(false, maps:is_key(result, R)).

validate_syntax_error_test() ->
    {error, Err} = alEval:validate("1 + ."),
    ?assert(lists:member(maps:get(reason, Err), [parseError, scanError])).

bindings_test() ->
    {ok, R} = alEval:eval("X + 10.", #{bindings => #{'X' => 7}}),
    ?assertEqual(17, maps:get(result, R)).

spawn_rejected_test() ->
    {error, Err} = alEval:eval("spawn(fun() -> ok end)."),
    ?assertEqual(forbiddenCall, maps:get(reason, Err)).

receive_rejected_test() ->
    {error, Err} = alEval:validate("receive X -> X end."),
    ?assertEqual(forbiddenReceive, maps:get(reason, Err)).

fun_bad_arity_test() ->
    {error, Err} = alEval:eval("fun(X) -> X end.", #{args => []}),
    %% apply path returns badArity or applyFailed with detail
    Reason = maps:get(reason, Err, undefined),
    ?assert(Reason =/= undefined).

disabled_test() ->
    {error, Err} = alEval:eval("1+1.", #{evalErlEnabled => false}),
    ?assertEqual(evalErlDisabled, maps:get(reason, Err)).

check_mfa_allowed_export_test() ->
    ?assertEqual(ok, alRuntimeProbe:checkMfaAllowed(erlang, system_info, 1)),
    {error, E} = alRuntimeProbe:checkMfaAllowed(os, cmd, 1),
    ?assertEqual(mfaNotAllowed, maps:get(reason, E)).
