%%% @doc EUnit tests for alPolicy.
-module(alPolicy_tests).

-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% level/1
%%%===================================================================

levelReadTools_test() ->
    ?assertEqual(read, alPolicy:level(indexCode)),
    ?assertEqual(read, alPolicy:level(searchCode)),
    ?assertEqual(read, alPolicy:level(readFile)),
    ?assertEqual(read, alPolicy:level(coreHealth)),
    ?assertEqual(read, alPolicy:level(getModuleTypes)),
    ?assertEqual(read, alPolicy:level(getOldCodeProcesses)).

levelWriteTools_test() ->
    ?assertEqual(write, alPolicy:level(applyPatch)),
    ?assertEqual(write, alPolicy:level(writeFile)),
    ?assertEqual(write, alPolicy:level(refactor)),
    ?assertEqual(write, alPolicy:level(batchRefactor)).

levelRiskyTools_test() ->
    ?assertEqual(executeRisky, alPolicy:level(runMfa)),
    ?assertEqual(executeRisky, alPolicy:level(evalErl)),
    ?assertEqual(executeRisky, alPolicy:level(hotReload)).

levelUnknownDefaultsDenied_test() ->
    %% 未知工具默认 denied（defense in depth）：alToolRouter 应已拒绝未注册工具，
    %% alPolicy 兜底防止未知工具名穿透到执行路径。
    ?assertEqual(denied, alPolicy:level(unknownTool)).

%%%===================================================================
%%% modeAllows/2
%%%===================================================================

modeAllowsAsk_test() ->
    ?assert(alPolicy:modeAllows(ask, read)),
    ?assert(alPolicy:modeAllows(ask, executeSafe)),
    ?assert(alPolicy:modeAllows(ask, executeRisky)),
    ?assertNot(alPolicy:modeAllows(ask, write)).

modeAllowsEdit_test() ->
    ?assert(alPolicy:modeAllows(edit, read)),
    ?assert(alPolicy:modeAllows(edit, write)),
    ?assert(alPolicy:modeAllows(edit, executeRisky)).

modeAllowsExec_test() ->
    ?assert(alPolicy:modeAllows(exec, read)),
    ?assert(alPolicy:modeAllows(exec, write)),
    ?assert(alPolicy:modeAllows(exec, executeRisky)).

%%%===================================================================
%%% checkTool/3
%%%===================================================================

checkToolRiskyAllowedByDefault_test() ->
    Policy = alPolicy:defaultPolicy(),
    ?assertEqual(ok, alPolicy:checkTool(runMfa, Policy, #{mode => ask})).

checkToolRunMfaReadNoConfirmation_test() ->
    Policy = alPolicy:defaultPolicy(),
    Args = #{module => player, function => get_role, args => [1], sideEffect => read},
    ?assertEqual(ok, alPolicy:checkTool(runMfa, Policy, #{mode => ask, args => Args})).

checkToolRunMfaWriteNeedsConfirmation_test() ->
    %% 审批默认已关；显式打开后写意图才需确认
    Policy = (alPolicy:defaultPolicy())#{requireConfirmationWrite => true},
    Args = #{module => player, function => set_gold, args => [1, 100], sideEffect => write},
    ?assertEqual({error, confirmationRequired},
                 alPolicy:checkTool(runMfa, Policy, #{mode => ask, args => Args})).

checkToolRunMfaWriteHeuristic_test() ->
    Policy = (alPolicy:defaultPolicy())#{requireConfirmationWrite => true},
    Args = #{module => player, function => update_attr, args => [1]},
    ?assertEqual(true, alPolicy:isRunMfaWrite(Args)),
    ?assertEqual({error, confirmationRequired},
                 alPolicy:checkTool(runMfa, Policy, #{mode => ask, args => Args})).

%% LLM 谎报 sideEffect=read 无法绕过确认：函数名不像只读即视为 write。
checkToolRunMfaIgnoresLlmReportedRead_test() ->
    Policy = (alPolicy:defaultPolicy())#{requireConfirmationWrite => true},
    Args = #{module => player, function => set_gold, args => [1, 100], sideEffect => read},
    ?assertEqual(true, alPolicy:isRunMfaWrite(Args)),
    ?assertEqual({error, confirmationRequired},
                 alPolicy:checkTool(runMfa, Policy, #{mode => ask, args => Args})).

checkToolRunMfaWriteConfirmed_test() ->
    Policy = (alPolicy:defaultPolicy())#{requireConfirmationWrite => true},
    Args = #{function => set_gold, sideEffect => write},
    ?assertEqual(ok, alPolicy:checkTool(runMfa, Policy,
                                        #{mode => ask, args => Args, confirmed => true})).

checkToolOtherRiskyNeedsConfirmationWhenConfigured_test() ->
    Policy = (alPolicy:defaultPolicy())#{requireConfirmationRisky => true},
    ?assertEqual({error, confirmationRequired},
                 alPolicy:checkTool(execute, Policy, #{mode => ask})).

policyForModeEditAllowsWrite_test() ->
    P = alPolicy:policyForMode(edit),
    ?assertEqual(true, maps:get(allowWrite, P)).

checkToolWriteDeniedInAskMode_test() ->
    Policy = alPolicy:defaultPolicy(),
    ?assertEqual({error, denied}, alPolicy:checkTool(applyPatch, Policy, #{mode => ask})).

checkToolWriteNeedsConfirmation_test() ->
    Policy = (alPolicy:defaultPolicy())#{requireConfirmationWrite => true},
    ?assertEqual({error, confirmationRequired},
                 alPolicy:checkTool(applyPatch, Policy#{allowWrite => true}, #{mode => edit})).

checkToolWriteConfirmed_test() ->
    Policy = (alPolicy:defaultPolicy())#{requireConfirmationWrite => true},
    ?assertEqual(ok, alPolicy:checkTool(applyPatch, Policy#{allowWrite => true},
                                          #{mode => edit, confirmed => true})).

checkToolDbQueryWriteNeedsConfirmation_test() ->
    Policy = (alPolicy:defaultPolicy())#{requireConfirmationWrite => true},
    %% 写语句（DELETE）应基于 SQL 内容判定为 write，需确认。
    Ctx = #{mode => edit, args => #{sql => <<"DELETE FROM t WHERE id=1">>}},
    ?assertEqual({error, confirmationRequired},
                 alPolicy:checkTool(dbQuery, Policy#{allowWrite => true}, Ctx)).

%% 默认关闭审批：写意图可直接过策略门。
checkToolRunMfaWriteNoConfirmationByDefault_test() ->
    Policy = alPolicy:defaultPolicy(),
    Args = #{module => player, function => set_gold, args => [1, 100], sideEffect => write},
    ?assertEqual(ok, alPolicy:checkTool(runMfa, Policy, #{mode => ask, args => Args})).

%% dbQuery 风险等级基于 SQL 内容，而非 LLM 自报 mode。
effectiveLevelDbQueryReadOnlySql_test() ->
    ?assertEqual(read, alPolicy:effectiveLevel(dbQuery, #{sql => <<"SELECT * FROM t">>})),
    ?assertEqual(read, alPolicy:effectiveLevel(dbQuery, #{<<"sql">> => <<"select 1">>})).

effectiveLevelDbQueryWriteSql_test() ->
    ?assertEqual(write, alPolicy:effectiveLevel(dbQuery, #{sql => <<"UPDATE t SET x=1">>})),
    ?assertEqual(write, alPolicy:effectiveLevel(dbQuery, #{sql => <<"INSERT INTO t VALUES (1)">>})),
    ?assertEqual(write, alPolicy:effectiveLevel(dbQuery, #{sql => <<"DROP TABLE t">>})).

%% 谎报 mode => read 无法降级：写语句仍判为 write。
effectiveLevelDbQueryIgnoresReportedMode_test() ->
    Args = #{mode => read, sql => <<"DELETE FROM t">>},
    ?assertEqual(write, alPolicy:effectiveLevel(dbQuery, Args)).

%% WITH ... DELETE 这类以 with 开头却夹带写操作的语句应判为 write。
effectiveLevelDbQueryWithDelete_test() ->
    Args = #{sql => <<"WITH x AS (SELECT 1) DELETE FROM t">>},
    ?assertEqual(write, alPolicy:effectiveLevel(dbQuery, Args)).

%% 缺失 SQL 时保守判为 write（需审批）。
effectiveLevelDbQueryMissingSql_test() ->
    ?assertEqual(write, alPolicy:effectiveLevel(dbQuery, #{mode => write})),
    ?assertEqual(write, alPolicy:effectiveLevel(dbQuery, #{})).

%%%===================================================================
%%% sanitizeTerm/1
%%%===================================================================

sanitizeRedactsApiKey_test() ->
    Input = #{apiKey => <<"sk-123">>, name => <<"ali">>},
    Result = alPolicy:sanitizeTerm(Input),
    ?assertEqual(<<"***REDACTED***">>, maps:get(apiKey, Result)),
    ?assertEqual(<<"ali">>, maps:get(name, Result)).

sanitizeRedactsPassword_test() ->
    Input = #{password => <<"secret">>, user => <<"admin">>},
    Result = alPolicy:sanitizeTerm(Input),
    ?assertEqual(<<"***REDACTED***">>, maps:get(password, Result)).

sanitizeRedactsToken_test() ->
    Input = #{authToken => <<"abc">>},
    Result = alPolicy:sanitizeTerm(Input),
    ?assertEqual(<<"***REDACTED***">>, maps:get(authToken, Result)).

sanitizeRedactsCommonCredentialAliases_test() ->
    Input = #{
        <<"access_token">> => <<"a">>,
        clientSecret => <<"b">>,
        "private_key" => <<"c">>
    },
    Result = alPolicy:sanitizeTerm(Input),
    ?assertEqual(<<"***REDACTED***">>, maps:get(<<"access_token">>, Result)),
    ?assertEqual(<<"***REDACTED***">>, maps:get(clientSecret, Result)),
    ?assertEqual(<<"***REDACTED***">>, maps:get("private_key", Result)).

%% 子串匹配下，含敏感词的键会被打码（更激进）；此处验证白名单守护键
%% （keyboard 含 "key"）不被误伤。
sanitizeSubstringMatchRedactsAndGuards_test() ->
    Input = #{
        tokenizer_model => <<"bpe">>,
        ourSecretFormula => <<"x">>,
        api_key_suffix => <<"last-four">>,
        keyboard => <<"qwerty">>,
        name => <<"ali">>
    },
    Result = alPolicy:sanitizeTerm(Input),
    %% 含敏感子串 token/secret/key 的键被打码。
    ?assertEqual(<<"***REDACTED***">>, maps:get(tokenizer_model, Result)),
    ?assertEqual(<<"***REDACTED***">>, maps:get(ourSecretFormula, Result)),
    ?assertEqual(<<"***REDACTED***">>, maps:get(api_key_suffix, Result)),
    %% 白名单守护键与普通键保持原值。
    ?assertEqual(<<"qwerty">>, maps:get(keyboard, Result)),
    ?assertEqual(<<"ali">>, maps:get(name, Result)).

sanitizePreservesSafeKeys_test() ->
    Input = #{tool => search, args => #{query => "hello"},
              prompt_tokens => 3, maxTokensBudget => 100},
    Result = alPolicy:sanitizeTerm(Input),
    ?assertEqual(search, maps:get(tool, Result)),
    ?assertEqual(3, maps:get(prompt_tokens, Result)),
    ?assertEqual(100, maps:get(maxTokensBudget, Result)).

sanitizeList_test() ->
    Input = [#{apiKey => <<"k">>}, #{name => <<"ok">>}],
    [R1, R2] = alPolicy:sanitizeTerm(Input),
    ?assertEqual(<<"***REDACTED***">>, maps:get(apiKey, R1)),
    ?assertEqual(<<"ok">>, maps:get(name, R2)).
