%%% @doc EUnit tests for {@link alSessionMgr} session save/load + export/import.
%%%
%%% These tests exercise the gen_server paths (createSession, appendMessage,
%%% exportSession, importSession, saveSession, loadSessionFile,
%%% listSavedSessions) that the sibling {@link alSessionMgr_tests} does
%%% not cover — that module only tests the pure helpers.
%%%
%%% The DB layer (alLocalDb) is intentionally left unstarted; {@link
%%% alSessionMgr:safeInsert/2} catches the resulting noproc/exit so
%%% sessions live entirely in memory for these tests.
%%%
%%% Tests are exposed via a single {foreach,...} fixture so each gets a fresh
%%% gen_server + isolated temp root. Helpers are named t_*/0 (not _test) so
%%% eunit does not auto-discover them as standalone tests.
-module(alSessionMgrSaveLoad_tests).

-include_lib("eunit/include/eunit.hrl").

-define(MGR, alSessionMgr).

%%%===================================================================
%%% Fixture: each test gets a fresh gen_server + isolated temp root
%%%===================================================================

session_mgr_test_() ->
    {foreach,
        fun setup/0,
        fun cleanup/1,
        [
            fun t_sessions_dir_under_root/0,
            fun t_export_session_returns_json/0,
            fun t_export_session_includes_messages/0,
            fun t_import_session_bad_json/0,
            fun t_import_session_missing_id/0,
            fun t_import_session_round_trip/0,
            fun t_save_session_writes_file/0,
            fun t_load_session_file_missing_returns_error/0,
            fun t_load_session_file_imports/0,
            fun t_list_saved_sessions_empty/0,
            fun t_list_saved_sessions_lists_ids/0
        ]}.

setup() ->
    Tmp = tmp_root(),
    ok = filelib:ensure_dir(filename:join(Tmp, "x")),
    ok = alConfig:patch([
        {root, Tmp},
        {dataDir, filename:join(Tmp, ".ali")}
    ]),
    ensure_started(?MGR),
    Tmp.

cleanup(Tmp) ->
    try gen_server:stop(?MGR, normal, 5000) catch _:_ -> ok end,
    cleanup_root(Tmp).

ensure_started(Mod) ->
    case Mod:start_link() of
        {ok, Pid} -> {started, Pid};
        {error, {already_started, Pid}} -> {existing, Pid}
    end.

tmp_root() ->
    Ts = erlang:system_time(microsecond),
    N = erlang:unique_integer([positive]),
    filename:join(temp_dir(), "ali_sess_" ++ integer_to_list(Ts) ++ "_" ++ integer_to_list(N)).

temp_dir() ->
    case os:getenv("TMPDIR") of
        false ->
            case os:type() of
                {win32, _} -> os:getenv("TEMP");
                _ -> "/tmp"
            end;
        Dir -> Dir
    end.

cleanup_root(Tmp) ->
    case file:del_dir_r(Tmp) of
        ok -> ok;
        _ -> ok
    end.

%%%===================================================================
%%% Tests
%%%===================================================================

t_sessions_dir_under_root() ->
    Expected = alConfig:dataPath("sessions"),
    ?assertEqual(Expected, ?MGR:sessionsDir()).

t_export_session_returns_json() ->
    {ok, Sid} = ?MGR:createSession(<<"alice">>),
    {ok, JsonBin} = ?MGR:exportSession(Sid),
    Decoded = alJson:decode(JsonBin),
    ?assertEqual(Sid, maps:get(<<"id">>, Decoded)),
    ?assertEqual(<<"alice">>, maps:get(<<"user">>, Decoded)),
    ?assert(maps:is_key(<<"createdAt">>, Decoded)),
    ?assert(maps:is_key(<<"messages">>, Decoded)).

t_export_session_includes_messages() ->
    {ok, Sid} = ?MGR:createSession(<<"bob">>),
    {ok, _} = ?MGR:appendMessage(Sid, #{role => user, content => <<"hello">>}),
    {ok, _} = ?MGR:appendMessage(Sid, #{role => assistant, content => <<"hi there">>}),
    {ok, JsonBin} = ?MGR:exportSession(Sid),
    Decoded = alJson:decode(JsonBin),
    Msgs = maps:get(<<"messages">>, Decoded),
    ?assertEqual(2, length(Msgs)).

t_import_session_bad_json() ->
    ?assertEqual({error, badJson}, ?MGR:importSession(<<"not valid json">>)).

t_import_session_missing_id() ->
    JsonBin = alJson:encode(#{<<"user">> => <<"noid">>, <<"messages">> => []}),
    ?assertEqual({error, badJson}, ?MGR:importSession(JsonBin)).

t_import_session_round_trip() ->
    {ok, Sid} = ?MGR:createSession(<<"carol">>),
    {ok, _} = ?MGR:appendMessage(Sid, #{role => user, content => <<"round trip">>}),
    {ok, _} = ?MGR:appendMessage(Sid, #{role => assistant, content => <<"ok">>}),
    {ok, JsonBin} = ?MGR:exportSession(Sid),
    {ok, Sid2} = ?MGR:importSession(JsonBin),
    ?assertEqual(Sid, Sid2),
    {ok, Session} = ?MGR:getContext(Sid),
    Msgs = maps:get(messages, Session, []),
    ?assertEqual(2, length(Msgs)).

t_save_session_writes_file() ->
    {ok, Sid} = ?MGR:createSession(<<"dave">>),
    {ok, _} = ?MGR:appendMessage(Sid, #{role => user, content => <<"persist me">>}),
    {ok, Path} = ?MGR:saveSession(Sid),
    ?assert(filelib:is_regular(Path)),
    {ok, Bin} = file:read_file(Path),
    Decoded = alJson:decode(Bin),
    ?assertEqual(Sid, maps:get(<<"id">>, Decoded)),
    ?assertEqual(1, length(maps:get(<<"messages">>, Decoded))).

t_load_session_file_missing_returns_error() ->
    ?assertMatch({error, _}, ?MGR:loadSessionFile(888888888)).

t_load_session_file_imports() ->
    Sid = 777777,
    Payload = #{
        id => Sid,
        user => <<"from-disk">>,
        createdAt => 1000,
        updatedAt => 2000,
        messages => [
            #{role => user, content => <<"disk hello">>},
            #{role => assistant, content => <<"disk reply">>}
        ]
    },
    Path = filename:join(?MGR:sessionsDir(), integer_to_list(Sid) ++ ".json"),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, alJson:encode(Payload)),
    {ok, Sid} = ?MGR:loadSessionFile(Sid),
    {ok, Session} = ?MGR:getContext(Sid),
    Msgs = maps:get(messages, Session, []),
    ?assertEqual(2, length(Msgs)).

t_list_saved_sessions_empty() ->
    ?assertEqual([], ?MGR:listSavedSessions()).

t_list_saved_sessions_lists_ids() ->
    Dir = ?MGR:sessionsDir(),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    ok = file:write_file(filename:join(Dir, "10001.json"), <<"{}">>),
    ok = file:write_file(filename:join(Dir, "10002.json"), <<"{}">>),
    ok = file:write_file(filename:join(Dir, "not_json.txt"), <<"ignore">>),
    List = ?MGR:listSavedSessions(),
    ?assert(lists:member(10001, List)),
    ?assert(lists:member(10002, List)),
    ?assertNot(lists:member("not_json", List)).
