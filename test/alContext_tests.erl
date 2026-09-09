%%% @doc EUnit tests for alContext pure helpers.
-module(alContext_tests).

-include_lib("eunit/include/eunit.hrl").

-define(setup, begin ok = alConfig:load() end).

critical_exports_test() ->
    Exports = alContext:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{buildSystemPrompt, 2}, {prepareMessages, 4},
                   {trimMessages, 2}, {injectWorkingContext, 2},
                   {activeSkills, 1}, {activeSkills, 2}]].

trimMessagesEmpty_test() ->
    ?assertEqual([], alContext:trimMessages([], #{})).

trimMessagesUnderLimit_test() ->
    Msgs = [#{role => user, content => <<"hello">>},
            #{role => assistant, content => <<"hi">>}],
    ?assertEqual(Msgs, alContext:trimMessages(Msgs, #{})).

trimMessagesTrimsLongHistory_test() ->
    Big = iolist_to_binary([<<"x">> || _ <- lists:seq(1, 50000)]),
    Msgs = [#{role => user, content => Big} || _ <- lists:seq(1, 20)],
    Trimmed = alContext:trimMessages(Msgs, #{maxHistoryTokens => 1000}),
    ?assert(length(Trimmed) =< length(Msgs)).

injectWorkingContextEmpty_test() ->
    ?assertEqual(<<>>, alContext:injectWorkingContext(<<>>, #{})).

injectWorkingContextModules_test() ->
    Ctx = #{modules => [ali_sup, ali_app], files => [], processes => []},
    Result = alContext:injectWorkingContext(<<>>, Ctx),
    ?assert(is_binary(Result)).

is_llm_safe_message_accepts_binary_role_test() ->
    ?assert(alContext:isLlmSafeMessage(#{role => <<"user">>, content => <<"hi">>})),
    ?assert(alContext:isLlmSafeMessage(#{<<"role">> => <<"assistant">>, content => <<"ok">>})),
    ?assertEqual(user, alContext:normalizeRole(<<"user">>)),
    ?assertNot(alContext:isLlmSafeMessage(#{role => tool, content => <<"x">>})).

%% buildSystemPrompt/2 — systemPromptExtra 各种类型都不能 badarg

build_system_prompt_extra_binary_test() ->
    Cfg = #{systemPromptExtra => <<"extra rules">>, skillsEnabled => false},
    P = alContext:buildSystemPrompt(<<"q">>, #{agentCfg => Cfg}),
    ?assert(is_binary(P)),
    ?assertNotEqual(nomatch, binary:match(P, <<"extra rules">>)).

build_system_prompt_extra_string_test() ->
    Cfg = #{systemPromptExtra => "extra string rules", skillsEnabled => false},
    P = alContext:buildSystemPrompt(<<"q">>, #{agentCfg => Cfg}),
    ?assert(is_binary(P)),
    ?assertNotEqual(nomatch, binary:match(P, <<"extra string rules">>)).

build_system_prompt_extra_undefined_test() ->
    Cfg = #{systemPromptExtra => undefined, skillsEnabled => false},
    P = alContext:buildSystemPrompt(<<"q">>, #{agentCfg => Cfg}),
    ?assert(is_binary(P)).

build_system_prompt_extra_missing_test() ->
    P = alContext:buildSystemPrompt(<<"q">>, #{agentCfg => #{skillsEnabled => false}}),
    ?assert(is_binary(P)).

hard_discipline_keeps_anti_hallucination_test() ->
    P = alContext:buildSystemPrompt(<<"zzzz">>, #{agentCfg => #{skillsEnabled => false}}),
    ?assertNotEqual(nomatch, binary:match(P, <<"tool_calls">>)),
    ?assertNotEqual(nomatch, binary:match(P, <<"resolveModule">>)),
    ?assertNotEqual(nomatch, binary:match(P, <<"getCallers">>)),
    ?assertNotEqual(nomatch, binary:match(P, <<"lastCommit">>)),
    ?assertNotEqual(nomatch, binary:match(P, <<"sideEffect">>)),
    ?assertNotEqual(nomatch, binary:match(P, <<"runMfa">>)),
    ?assertNotEqual(nomatch, binary:match(P, <<"evalErl">>)),
    io:format(user, "system prompt bytes=~p~n", [byte_size(P)]),
    %% 压缩前 HardDiscipline 约 8.5KB；身份+纪律+[self] 应远小于此。
    ?assert(byte_size(P) < 4500).

%%--------------------------------------------------------------------
%% 自述反臆造：硬纪律条款 + [self] 真实参数注入
%%--------------------------------------------------------------------

hard_discipline_self_description_rules_test() ->
    P = alContext:buildSystemPrompt(<<"zzzz">>, #{agentCfg => #{skillsEnabled => false}}),
    ?assertNotEqual(nomatch, binary:match(P, <<"自述"/utf8>>)),
    ?assertNotEqual(nomatch, binary:match(P, <<"禁止猜测编造"/utf8>>)),
    ?assertNotEqual(nomatch, binary:match(P, <<"不在可用信息中"/utf8>>)).

self_facts_injects_real_budget_test() ->
    Cfg = #{skillsEnabled => false,
            maxMessages => 77, maxContextChars => 234000, maxContextTokens => 99000},
    P = alContext:buildSystemPrompt(<<"q">>, #{agentCfg => Cfg}),
    ?assertNotEqual(nomatch, binary:match(P, <<"[self]">>)),
    ?assertNotEqual(nomatch, binary:match(P, <<"77 条消息"/utf8>>)),
    ?assertNotEqual(nomatch, binary:match(P, <<"234000 字符"/utf8>>)),
    ?assertNotEqual(nomatch, binary:match(P, <<"99000 tokens"/utf8>>)),
    %% 明示供应商信息未提供——被问身份时不得编造
    ?assertNotEqual(nomatch, binary:match(P, <<"禁止编造"/utf8>>)).

self_facts_defaults_when_absent_test() ->
    %% AgentCfg 未配置预算 → 用默认值注入（50/120000/100000）
    P = alContext:buildSystemPrompt(<<"q">>, #{agentCfg => #{skillsEnabled => false}}),
    ?assertNotEqual(nomatch, binary:match(P, <<"120000 字符"/utf8>>)),
    ?assertNotEqual(nomatch, binary:match(P, <<"100000 tokens"/utf8>>)).

self_facts_skips_invalid_values_test() ->
    %% 预算为 0/负数：宁缺勿错，跳过注入。
    %% 注意硬纪律本身含「[self]」字样，须断言注入段标题不出现。
    Cfg = #{skillsEnabled => false, maxMessages => 0, maxContextChars => -1},
    P = alContext:buildSystemPrompt(<<"q">>, #{agentCfg => Cfg}),
    ?assertEqual(nomatch, binary:match(P, <<"真实系统参数"/utf8>>)).

self_facts_tolerates_string_values_test() ->
    %% cfg 文件里数值可能是字符串形态
    Cfg = #{skillsEnabled => false,
            maxMessages => <<"30">>, maxContextChars => "80000", maxContextTokens => 60000},
    P = alContext:buildSystemPrompt(<<"q">>, #{agentCfg => Cfg}),
    ?assertNotEqual(nomatch, binary:match(P, <<"30 条消息"/utf8>>)),
    ?assertNotEqual(nomatch, binary:match(P, <<"80000 字符"/utf8>>)),
    ?assertNotEqual(nomatch, binary:match(P, <<"60000 tokens"/utf8>>)).
