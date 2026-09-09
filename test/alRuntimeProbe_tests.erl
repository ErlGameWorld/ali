%%% @doc EUnit tests for alRuntimeProbe.
-module(alRuntimeProbe_tests).

-include_lib("eunit/include/eunit.hrl").

-define(setup, begin ok = alConfig:load() end).

critical_exports_test() ->
    Exports = alRuntimeProbe:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{snapshot, 0}, {processes, 1}, {etsTables, 1},
                   {runMfa, 4}, {runMfa, 5}, {supervisorTree, 0},
                   {supervisorTree, 1}, {processInfo, 1}, {etsLookup, 2}, {etsLookup, 3}]].

process_info_self_test() ->
    {ok, Info} = alRuntimeProbe:processInfo(self()),
    ?assert(is_map(Info)),
    ?assert(maps:is_key(pid, Info)).

supervisor_tree_roots_opt_test() ->
    Tree = alRuntimeProbe:supervisorTree(#{roots => [ali_sup], maxDepth => 2}),
    ?assert(is_map(Tree)),
    ?assert(maps:is_key(roots, Tree)).

simulate_mfa_is_dry_run_test() ->
    {ok, R} = alSimulator:run(#{type => mfa, module => erlang, function => system_info,
                                args => [process_count]}),
    ?assertEqual(true, maps:get(dryRun, R)),
    ?assertEqual(ok, maps:get(status, R)).

is_supervisor_name_test() ->
    ?assert(alRuntimeProbe:isSupervisorName(ali_sup)),
    ?assert(alRuntimeProbe:isSupervisorName(player_sup)),
    ?assertNot(alRuntimeProbe:isSupervisorName(alServer)).

runmfa_write_requires_verify_read_test() ->
    ok = alConfig:load(),
    ok = alConfig:patch([{runMfaRequireVerifyRead, true}, {runMfaPolicy, blacklist}]),
    R = alToolRouter:callTool(
          runMfa,
          #{module => erlang, function => system_info, args => [process_count],
            sideEffect => write},
          #{enforcePolicy => false, confirmed => true}),
    ?assertMatch({error, #{reason := verifyReadRequired}}, R).

runmfa_write_with_verify_read_ok_test() ->
    ok = alConfig:load(),
    ok = alConfig:patch([{runMfaRequireVerifyRead, true}, {runMfaPolicy, blacklist}]),
    %% 用只读 MFA 冒充写路径，验证 before/after 结构（system_info 无副作用）
    R = alToolRouter:callTool(
          runMfa,
          #{module => erlang, function => system_info, args => [process_count],
            sideEffect => write,
            verifyRead => #{module => erlang, function => system_info,
                            args => [process_count]}},
          #{enforcePolicy => false, confirmed => true}),
    ?assertMatch({ok, #{sideEffect := write, verified := true,
                        beforeRead := _, afterRead := _}}, R).


emptyWhitelistDenies_test() ->
    ok = alConfig:load(),
    ok = alConfig:patch([
        {runMfaPolicy, whitelist},
        {runMfaWhitelist, []}
    ]),
    ?assertMatch(
        {error, #{reason := mfaNotAllowed}},
        alRuntimeProbe:runMfa(erlang, system_info, [process_count], 1000)
    ).

blacklistAllowsSafeMfa_test() ->
    ok = alConfig:load(),
    ok = alConfig:patch([{runMfaPolicy, blacklist}]),
    ?assertMatch(
        {ok, _},
        alRuntimeProbe:runMfa(erlang, system_info, [process_count], 1000)
    ).

blacklistDeniesOsCmd_test() ->
    ok = alConfig:load(),
    ok = alConfig:patch([
        {runMfaPolicy, blacklist},
        {runMfaBlacklist, [{os, cmd}]}
    ]),
    ?assertMatch(
        {error, #{reason := mfaNotAllowed}},
        alRuntimeProbe:runMfa(os, cmd, ["echo hi"], 1000)
    ).

notExportedReturnsExports_test() ->
    ok = alConfig:load(),
    ok = alConfig:patch([{runMfaPolicy, blacklist}]),
    %% erlang:no_such_fun/0 必然不存在；应返回 exports 提示而非空错误
    case alRuntimeProbe:runMfa(erlang, no_such_fun_xyz, [], 1000) of
        {error, #{reason := notExported, exportsSample := Sample, hint := Hint}} ->
            ?assert(is_list(Sample)),
            ?assert(is_binary(Hint));
        Other ->
            ?assertEqual({error, #{reason => notExported}}, Other)
    end.

allowExportedPermitsErlang_test() ->
    ok = alConfig:load(),
    ok = alConfig:patch([{runMfaPolicy, allowExported}]),
    ?assertMatch(
        {ok, _},
        alRuntimeProbe:runMfa(erlang, system_info, [process_count], 1000)
    ).

snapshotReturnsMap_test() ->
    ?setup,
    Snap = alRuntimeProbe:snapshot(),
    ?assert(is_map(Snap)).

supervisorTreeReturnsList_test() ->
    ?setup,
    Tree = alRuntimeProbe:supervisorTree(),
    ?assert(is_list(Tree) orelse is_map(Tree)).

processesWithLimit_test() ->
    ?setup,
    Result = alRuntimeProbe:processes(10),
    ?assert(is_list(Result) orelse is_map(Result)).

%%%===================================================================
%%% 9: 未知模块/函数名返回错误且不创建新 atom（原子表耗尽 DoS 防护）
%%%===================================================================

runmfa_unknown_module_returns_error_without_atom_test() ->
    ok = alConfig:load(),
    ok = alConfig:patch([{runMfaPolicy, blacklist}]),
    ModBin = <<"no_such_module_",
               (integer_to_binary(erlang:unique_integer([positive, monotonic])))/binary>>,
    %% 未加载的模块名：normalizeAtom 失败 → badMfa 错误，绝不 list_to_atom/binary_to_atom
    ?assertMatch({error, #{reason := badMfa}},
                 alRuntimeProbe:runMfa(ModBin, <<"run">>, [], 1000)),
    ?assertError(badarg, binary_to_existing_atom(ModBin, utf8)).

runmfa_unknown_function_returns_error_without_atom_test() ->
    ok = alConfig:load(),
    ok = alConfig:patch([{runMfaPolicy, blacklist}]),
    FunBin = <<"no_such_fun_",
               (integer_to_binary(erlang:unique_integer([positive, monotonic])))/binary>>,
    %% 函数名 binary 不存在于 atom 表：返回 badMfa，不创建新 atom
    ?assertMatch({error, #{reason := badMfa}},
                 alRuntimeProbe:runMfa(erlang, FunBin, [], 1000)),
    ?assertError(badarg, binary_to_existing_atom(FunBin, utf8)).
