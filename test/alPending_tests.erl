%%% @doc EUnit tests for alPending ETS operations.
-module(alPending_tests).

-include_lib("eunit/include/eunit.hrl").

finite_call_timeout_config_test() ->
    Old = application:get_env(ali, pendingCallTimeoutMs),
    try
        application:set_env(ali, pendingCallTimeoutMs, 1234),
        ?assertEqual(1234, alPending:callTimeoutMs()),
        application:set_env(ali, pendingCallTimeoutMs, infinity),
        ?assertEqual(30000, alPending:callTimeoutMs())
    after
        case Old of
            {ok, Value} -> application:set_env(ali, pendingCallTimeoutMs, Value);
            undefined -> application:unset_env(ali, pendingCallTimeoutMs)
        end
    end.

call_timeout_returns_error_instead_of_exit_test() ->
    alPending:ensureStarted(),
    Old = application:get_env(ali, pendingCallTimeoutMs),
    ok = sys:suspend(alPending),
    try
        application:set_env(ali, pendingCallTimeoutMs, 10),
        ?assertEqual({error, pendingCallTimeout}, alPending:get(<<"timeout-test">>))
    after
        ok = sys:resume(alPending),
        case Old of
            {ok, Value} -> application:set_env(ali, pendingCallTimeoutMs, Value);
            undefined -> application:unset_env(ali, pendingCallTimeoutMs)
        end
    end.

critical_exports_test() ->
    Exports = alPending:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{put, 5}, {get, 1}, {list, 0}, {list, 1},
                   {approve, 1}, {claimApprove, 1}, {executeApproved, 1},
                   {dismiss, 1}, {attachContinuation, 2}, {ensureStarted, 0}]].

putAndGet_test() ->
    alPending:ensureStarted(),
    TaskId = <<"test-pending-1">>,
    {ok, _} = alPending:put(TaskId, <<"sid">>, readFile, #{path => <<"a.erl">>}, #{}),
    ?assertMatch({ok, #{tool := readFile}}, alPending:get(TaskId)).

listTest_test() ->
    alPending:ensureStarted(),
    TaskId = <<"test-pending-list">>,
    {ok, _} = alPending:put(TaskId, <<"sid">>, searchCode, #{}, #{}),
    List = alPending:list(),
    ?assert(is_list(List)).

attachContinuation_test() ->
    alPending:ensureStarted(),
    TaskId = <<"test-cont-1">>,
    {ok, _} = alPending:put(TaskId, <<"sid">>, readFile, #{}, #{}),
    Cont = #{messages => [], opts => #{}, step => 1},
    ok = alPending:attachContinuation(TaskId, Cont),
    {ok, Task} = alPending:get(TaskId),
    ?assert(maps:is_key(continuation, Task)).

dismiss_test() ->
    alPending:ensureStarted(),
    TaskId = <<"test-dismiss-1">>,
    {ok, _} = alPending:put(TaskId, <<"sid">>, readFile, #{}, #{}),
    ok = alPending:dismiss(TaskId),
    ?assertEqual({error, notFound}, alPending:get(TaskId)).

claim_approve_returns_spec_without_executing_in_server_test() ->
    alPending:ensureStarted(),
    TaskId = <<"test-claim-approve-1">>,
    {ok, _} = alPending:put(TaskId, <<"sid">>, readFile,
                            #{path => <<"src/nonexistent_claim_test.erl">>}, #{}),
    ?assertMatch({ok, #{tool := readFile, opts := #{confirmed := true}}},
                 alPending:claimApprove(TaskId)),
    %% Second claim must lose the race / find nothing.
    ?assertEqual({error, notFound}, alPending:claimApprove(TaskId)).

approve_executes_outside_claim_test() ->
    alPending:ensureStarted(),
    TaskId = <<"test-approve-exec-1">>,
    {ok, _} = alPending:put(TaskId, <<"sid">>, readFile,
                            #{path => <<"src/nonexistent_approve_test.erl">>},
                            #{confirmed => false}),
    Result = alPending:approve(TaskId),
    ?assertMatch({error, _}, Result),
    ?assertEqual({error, notFound}, alPending:get(TaskId)).

%%%===================================================================
%%% 5a: 恶意 Id 路径净化（persist / deletePersisted 穿越防护）
%%%===================================================================

persist_malicious_id_sanitized_test() ->
    ok = alConfig:load(),
    Unique = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    Id = <<"../../evil", Unique/binary>>,
    Entry = #{id => Id, status => pending, tool => readFile,
              args => #{}, opts => #{}, sessionId => <<"sid">>},
    ?assertEqual(ok, alPending:persist(Entry)),
    DataDir = alConfig:dataDir(),
    %% 净化段：../../evil<unique> → evil<unique>（/→_、折叠点、trim 首尾 . _ -）
    Clean = "evil" ++ unicode:characters_to_list(Unique),
    PendingFile = filename:join([DataDir, "pending", Clean ++ ".json"]),
    ?assert(filelib:is_regular(PendingFile)),
    %% 绝不越界写到 dataDir 根目录
    ?assertNot(filelib:is_regular(filename:join(DataDir, Clean ++ ".json"))),
    ok = alPending:deletePersisted(Id).

delete_persisted_malicious_id_is_sanitized_test() ->
    ok = alConfig:load(),
    %% 恶意 Id 净化后只可能指向 <dataDir>/pending/evil.json，不触碰父目录
    ?assertEqual(ok, alPending:deletePersisted(<<"../../evil">>)),
    DataDir = alConfig:dataDir(),
    ?assertNot(filelib:is_regular(filename:join(DataDir, "evil.json"))),
    ?assertNot(filelib:is_regular(filename:join([DataDir, "..", "evil.json"]))).
