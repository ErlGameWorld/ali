%%% @doc EUnit tests for alGrounding.
-module(alGrounding_tests).

-include_lib("eunit/include/eunit.hrl").

extract_claims_mfa_test() ->
    Claims = alGrounding:extractClaims(<<"see alAgent:run/2 and foo:bar/1">>),
    Keys = [alGrounding:claimKey(C) || C <- Claims],
    ?assert(lists:member({mfa, <<"alAgent">>, <<"run">>, 2}, Keys)),
    ?assert(lists:member({mfa, <<"foo">>, <<"bar">>, 1}, Keys)).

%% OTP/stdlib MFA 不进入 claims，避免讲语言原理时被 grounding 末尾警告「截断感」
extract_claims_skips_otp_mfa_test() ->
    Claims = alGrounding:extractClaims(
        <<"process_info reads dictionary; erlang:send/2 is unrelated mailbox API">>),
    Keys = [alGrounding:claimKey(C) || C <- Claims],
    ?assertEqual([], Keys),
    ?assert(alGrounding:isBuiltinMfa(
        #{type => mfa, module => <<"erlang">>, function => <<"send">>, arity => 2})).

extract_claims_path_test() ->
    Claims = alGrounding:extractClaims(<<"in src/agent/alAgent.erl:42">>),
    ?assert(lists:any(fun(#{type := path, path := P}) ->
                               string:find(P, <<"alAgent.erl">>) =/= nomatch;
                          (_) -> false
                       end, Claims)).

should_check_with_hits_test() ->
    ?assert(alGrounding:shouldCheck(#{codeHits => [#{file => <<"a.erl">>}]})).

should_check_empty_test() ->
    ?assertNot(alGrounding:shouldCheck(#{})).

check_ok_when_evidence_present_test() ->
    Ctx = #{
        codeHits => [#{file => <<"src/agent/alAgent.erl">>, module => alAgent}],
        modules => [alAgent],
        anchors => #{
            mfas => [#{module => alAgent, function => run, arity => 2,
                       file => <<"src/agent/alAgent.erl">>}],
            modules => [],
            paths => []
        }
    },
    Answer = <<"alAgent:run/2 is the entry in src/agent/alAgent.erl">>,
    ?assertEqual(ok, alGrounding:check(Answer, Ctx, [])).

check_ungrounded_when_missing_test() ->
    Ctx = #{codeHits => [#{file => <<"src/a.erl">>, module => a}]},
    Answer = <<"totally_fake_mod:nope/9 lives in invent/boot/plugin/x.erl">>,
    ?assertMatch({ungrounded, [_|_]}, alGrounding:check(Answer, Ctx, [])).

check_skips_idle_chat_test() ->
    ?assertEqual(ok, alGrounding:check(<<"hello">>, #{}, [])).

append_warning_binary_test() ->
    Out = alGrounding:appendWarning(<<"ans">>, <<"\nwarn">>),
    ?assertEqual(<<"ans\nwarn">>, Out).
