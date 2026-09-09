%%% @doc EUnit tests for alSessionMgr pure helpers (encode/decode/normalize).
-module(alSessionMgr_tests).

-include_lib("eunit/include/eunit.hrl").

%% encodeMessage/1 — atom keys → binary keys

encode_message_map_test() ->
    Encoded = alSessionMgr:encodeMessage(#{role => user, content => <<"hi">>}),
    ?assertEqual(#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}, Encoded).

encode_message_nested_test() ->
    Encoded = alSessionMgr:encodeMessage(#{role => user, meta => #{seq => 1}}),
    ?assertEqual(#{<<"role">> => <<"user">>, <<"meta">> => #{<<"seq">> => 1}}, Encoded).

encode_message_list_of_atoms_test() ->
    Encoded = alSessionMgr:encodeMessage(#{roles => [user, assistant]}),
    ?assertEqual(#{<<"roles">> => [<<"user">>, <<"assistant">>]}, Encoded).

encode_message_passthrough_non_map_test() ->
    ?assertEqual(other, alSessionMgr:encodeMessage(other)).

%% encodeKey/1

encode_key_atom_test() ->
    ?assertEqual(<<"role">>, alSessionMgr:encodeKey(role)).

encode_key_binary_passthrough_test() ->
    ?assertEqual(<<"role">>, alSessionMgr:encodeKey(<<"role">>)).

%% encodeValue/1

encode_value_atom_test() ->
    ?assertEqual(<<"user">>, alSessionMgr:encodeValue(user)).

encode_value_char_list_test() ->
    ?assertEqual(<<"hi">>, alSessionMgr:encodeValue("hi")).

encode_value_non_char_list_test() ->
    ?assertEqual([<<"a">>, <<"b">>], alSessionMgr:encodeValue([a, b])).

encode_value_map_test() ->
    ?assertEqual(#{<<"x">> => <<"y">>}, alSessionMgr:encodeValue(#{x => y})).

encode_value_passthrough_test() ->
    ?assertEqual(42, alSessionMgr:encodeValue(42)).

%% decodeMessage/1 — JSON binary → normalized map

decode_message_binary_valid_test() ->
    Result = alSessionMgr:decodeMessage(<<"{\"role\":\"user\",\"content\":\"hi\"}">>),
    ?assertMatch(#{role := user, content := <<"hi">>}, Result).

decode_message_binary_malformed_test() ->
    Result = alSessionMgr:decodeMessage(<<"not json">>),
    ?assertMatch(#{role := unknown, content := <<"not json">>}, Result).

decode_message_other_test() ->
    Result = alSessionMgr:decodeMessage(other),
    ?assertMatch(#{role := unknown, content := other}, Result).

%% normalizeKey/1

normalize_key_known_atom_test() ->
    ?assertEqual(role, alSessionMgr:normalizeKey(<<"role">>)).

normalize_key_unknown_keeps_binary_test() ->
    ?assertEqual(<<"unknown_field">>, alSessionMgr:normalizeKey(<<"unknown_field">>)).

normalize_key_passthrough_test() ->
    ?assertEqual(existing, alSessionMgr:normalizeKey(existing)).

%% normalizeValue/1

normalize_value_map_test() ->
    ?assertEqual(#{role => user}, alSessionMgr:normalizeValue(#{<<"role">> => <<"user">>})).

normalize_value_list_test() ->
    ?assertEqual([<<"user">>, <<"assistant">>], alSessionMgr:normalizeValue([<<"user">>, <<"assistant">>])).

normalize_value_passthrough_test() ->
    ?assertEqual(42, alSessionMgr:normalizeValue(42)).

%% normalizeMessage/1

normalize_message_map_test() ->
    Result = alSessionMgr:normalizeMessage(#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}),
    ?assertMatch(#{role := user, content := <<"hi">>}, Result).

normalize_message_passthrough_test() ->
    ?assertEqual(other, alSessionMgr:normalizeMessage(other)).

%% normalizeToolTraceEntry/1 — router tuple trace → persistent map

normalize_tool_trace_step_test() ->
    ?assertEqual(
        #{type => step, step => 3},
        alSessionMgr:normalizeToolTraceEntry({step, 3})
    ).

normalize_tool_trace_results_test() ->
    Results = [#{role => tool, tool_call_id => <<"call-1">>,
                 content => #{status => ok}}],
    ?assertEqual(
        #{type => results, results => Results},
        alSessionMgr:normalizeToolTraceEntry({results, Results})
    ).

normalize_tool_trace_calls_test() ->
    Calls = [#{id => <<"call-1">>, function => #{name => <<"readFile">>}}],
    ?assertEqual(
        #{type => toolCalls, calls => Calls},
        alSessionMgr:normalizeToolTraceEntry({tool_calls, Calls})
    ).

normalize_tool_trace_map_passthrough_test() ->
    Entry = #{tool => readFile, status => ok},
    ?assertEqual(Entry, alSessionMgr:normalizeToolTraceEntry(Entry)).

%% toBinary/1

to_binary_binary_test() ->
    ?assertEqual(<<"x">>, alSessionMgr:toBinary(<<"x">>)).

to_binary_atom_test() ->
    ?assertEqual(<<"user">>, alSessionMgr:toBinary(user)).

to_binary_list_test() ->
    ?assertEqual(<<"hi">>, alSessionMgr:toBinary("hi")).

%%%===================================================================
%%% 6: loadSession / loadSessionMeta 的 DB 异常降级
%%%===================================================================

load_session_db_unavailable_returns_error_test() ->
    %% eunit 环境默认不启动 alLocalDb：修复后的 try/catch 必须把
    %% noproc 等异常降级为 {error, dbUnavailable}，不得崩溃。
    %% 经导出 API getContext/1 触发内部 loadSession。
    case whereis(alLocalDb) of
        undefined ->
            _ = case whereis(alSessionMgr) of
                    undefined -> alSessionMgr:start_link();
                    _ -> ok
                end,
            ?assertEqual({error, dbUnavailable},
                         alSessionMgr:getContext(<<"no-such-session-db-down">>));
        _ ->
            %% DB 已启动（其它测试拉起）：跳过本断言，避免环境耦合。
            ok
    end.

%%%===================================================================
%%% 任务5 W3: saveSession 中 ensure_dir 失败必须返回 {error, _} 不崩溃
%%%===================================================================

save_session_ensure_dir_failure_returns_error_test() ->
    _ = alConfig:load(),
    _ = case whereis(alSessionMgr) of
            undefined -> alSessionMgr:start_link();
            _ -> ok
        end,
    Dir = alSessionMgr:sessionsDir(),
    Backup = Dir ++ ".bak-" ++ integer_to_list(erlang:unique_integer([positive])),
    HadDir = filelib:is_dir(Dir),
    _ = case HadDir of
            true -> file:rename(Dir, Backup);
            false -> file:delete(Dir)
        end,
    %% 确保 Dir 父目录存在，并把 Dir 本身建成普通文件，令 ensure_dir 失败。
    ok = filelib:ensure_dir(filename:join(filename:dirname(Dir), "dummy")),
    ok = file:write_file(Dir, <<"not-a-dir">>),
    try
        Sid = <<"w3-", (integer_to_binary(erlang:unique_integer([positive, monotonic])))/binary>>,
        {ok, Sid} = alSessionMgr:ensureSession(Sid, web),
        Result = alSessionMgr:saveSession(Sid),
        ?assertMatch({error, _}, Result)
    after
        _ = file:delete(Dir),
        case HadDir of
            true -> _ = file:rename(Backup, Dir);
            false -> ok
        end
    end.
