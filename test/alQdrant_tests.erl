%%% @doc EUnit tests for alQdrant config helpers.
-module(alQdrant_tests).

-include_lib("eunit/include/eunit.hrl").

-define(setup, begin ok = alConfig:load() end).

critical_exports_test() ->
    Exports = alQdrant:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{start_link, 0}, {enabled, 0}, {managed, 0},
                   {url, 0}, {status, 0}]].

enabledReturnsBool_test() ->
    ?setup,
    Result = alQdrant:enabled(),
    ?assert(is_boolean(Result)).

managedReturnsBool_test() ->
    ?setup,
    Result = alQdrant:managed(),
    ?assert(is_boolean(Result)).

urlReturnsBinaryOrUndefined_test() ->
    ?setup,
    Result = alQdrant:url(),
    ?assert(Result =:= undefined orelse is_binary(Result) orelse is_list(Result)).

%% 4：scheduleReconnect 在 failed 模式下也调度重连（而非永久停止）

scheduleReconnectFailedModeSchedules_test() ->
    ?setup,
    State = #{mode => failed, port => fake, enabled => true, url => <<"http://localhost:6333">>},
    Result = alQdrant:scheduleReconnect(State),
    %% 走调度分支：closePort 将 port 置为 undefined（区别于原样返回的兜底分支）
    ?assertEqual(undefined, maps:get(port, Result, sentinel)),
    %% failed 模式应调度 eReconnectPort（约 3 秒后到达本测试进程）
    receive
        eReconnectPort -> ok
    after 3500 ->
        ?assert(false)
    end.

scheduleReconnectExternalNoSchedule_test() ->
    ?setup,
    State = #{mode => external, port => fake, enabled => true, url => <<"http://localhost:6333">>},
    %% 非托管/非失败模式直接返回原状态，不调度重连
    ?assertEqual(State, alQdrant:scheduleReconnect(State)),
    receive
        eReconnectPort -> ?assert(false)
    after 200 ->
        ok
    end.
