%%%-------------------------------------------------------------------
%% @doc Tests for alChat REPL helpers.
%% @end
%%%-------------------------------------------------------------------

-module(alChat_tests).

-include_lib("eunit/include/eunit.hrl").

normalizeOptsConvertsSessionId_test() ->
    Opts = alChat:normalizeOpts(#{sessionId => <<"dev"/utf8>>}),
    ?assertEqual(<<"dev"/utf8>>, maps:get(sessionId, Opts)).

trimLineStripsNewline_test() ->
    ?assertEqual(<<"hello">>, alChat:trimLine(<<"hello\n"/utf8>>)).

quitCommand_test() ->
    ?assertEqual(stop, alChat:handleChatCommand(<<"/quit"/utf8>>, #{})).

helpCommandContinues_test() ->
    ?assertMatch({continue, _}, alChat:handleChatCommand(<<"/help"/utf8>>, #{})).

sessionSwitchUpdatesOpts_test() ->
    ?assertMatch({continue, #{sessionId := <<"dev"/utf8>>}},
                 alChat:handleChatCommand(<<"/session dev"/utf8>>, #{})).

%% alAgent / callGraph 提问不得误判为「查看 Agent 配置」
callGraphAlAgentNotConfigQuery_test() ->
    Q = <<"用 callGraph 画一下 alAgent 的调用图，module 设为 alAgent"/utf8>>,
    ?assertEqual(false, alChat:matchAgentConfigQuery(Q)),
    ?assertEqual(false, alChat:tryLocalAnswer(Q)).

agentConfigQueryStillMatches_test() ->
    ?assertEqual(true, alChat:matchAgentConfigQuery(<<"查看 agent 配置"/utf8>>)),
    ?assertEqual(true, alChat:matchAgentConfigQuery(<<"Agent config"/utf8>>)).

reconfigureAgentNotConfigQuery_test() ->
    ?assertEqual(false, alChat:matchAgentConfigQuery(<<"please reconfigure the agent carefully">>)),
    ?assertEqual(false, alChat:matchAgentConfigQuery(
        <<"请详细解释 agent 配置里每一个 timeout 字段的含义以及如何调优"/utf8>>)).

affirmativeApprovalReply_test() ->
    ?assertEqual(approve, alChat:classifyApprovalReply(<<"确认"/utf8>>)),
    ?assertEqual(approve, alChat:classifyApprovalReply(<<"yes">>)),
    ?assertEqual(approve, alChat:classifyApprovalReply(<<"OK">>)),
    ?assertEqual(dismiss, alChat:classifyApprovalReply(<<"取消"/utf8>>)),
    ?assertEqual(dismiss, alChat:classifyApprovalReply(<<"no"/utf8>>)),
    ?assertEqual(neither, alChat:classifyApprovalReply(<<"好的，请继续分析代码"/utf8>>)),
    ?assertEqual(neither, alChat:classifyApprovalReply(<<"帮我改一下配置"/utf8>>)).
