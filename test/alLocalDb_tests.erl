%%% @doc EUnit tests for alLocalDb.
-module(alLocalDb_tests).

-include_lib("eunit/include/eunit.hrl").

-define(setup, begin ok = alConfig:load() end).

critical_exports_test() ->
    Exports = alLocalDb:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{start_link, 0}, {query, 2}, {execute, 2},
                   {insert, 2}, {status, 0}]].

statusReturnsMap_test() ->
    ?setup,
    ensure_local_db(),
    Status = alLocalDb:status(),
    ?assert(is_map(Status)).

session_sql_routes_only_exact_table_names_test() ->
    ?assert(alLocalDb:isSessionSql(
        <<"SELECT * FROM sessions WHERE id = ?">>
    )),
    ?assert(alLocalDb:isSessionSql(
        "insert\ninto session_messages(session_id, message) values (?, ?)"
    )),
    ?assert(alLocalDb:isSessionSql(
        <<"WITH recent AS (SELECT * FROM sessions) SELECT * FROM recent">>
    )),
    ?assert(alLocalDb:isSessionSql(
        <<"DELETE FROM session_artifacts WHERE session_id = ?">>
    )),
    ?assertNot(alLocalDb:isSessionSql(
        <<"SELECT * FROM user_sessions_archive">>
    )).

ensure_local_db() ->
    case whereis(alLocalDb) of
        undefined ->
            {ok, Pid} = alLocalDb:start_link(),
            unlink(Pid),
            ok;
        _Pid ->
            ok
    end.

%% 3a：后端 function_clause 等异常被 safeRunQuery 捕获，gen_server 不崩溃

crashingQueryReturnsError_test() ->
    ?setup,
    ensure_local_db(),
    %% 非 binary/list 的 Sql 会让文件后端 toList function_clause
    Result = alLocalDb:query(make_ref(), []),
    ?assertMatch({error, #{reason := dbError}}, Result),
    %% gen_server 仍然存活，后续查询正常返回
    ?assert(is_process_alive(whereis(alLocalDb))),
    ?assertMatch({ok, _}, alLocalDb:query("SELECT * FROM memories LIMIT 1", [])).

%% 3c：query 有限超时下正常返回

queryReturnsRows_test() ->
    ?setup,
    ensure_local_db(),
    ?assertMatch({ok, _}, alLocalDb:query("SELECT * FROM memories LIMIT 1", [])).
