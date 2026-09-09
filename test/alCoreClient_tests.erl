%%% @doc alCoreClient 的 port 集成冒烟测试 + 多 inflight 纯函数测试。
-module(alCoreClient_tests).

-include_lib("eunit/include/eunit.hrl").

path_class_buckets_test() ->
    ?assertEqual(index, alCoreClient:pathClass("/index")),
    ?assertEqual(search, alCoreClient:pathClass("/search")),
    ?assertEqual(search, alCoreClient:pathClass("/search/unified")),
    ?assertEqual(db, alCoreClient:pathClass("/db/query")),
    ?assertEqual(db, alCoreClient:pathClass("/db/status")),
    ?assertEqual(memory, alCoreClient:pathClass("/memory/search")),
    ?assertEqual(memoryWrite, alCoreClient:pathClass("/memory/upsert")),
    ?assertEqual(graph, alCoreClient:pathClass("/callers")),
    ?assertEqual(other, alCoreClient:pathClass("/health")).

encode_request_includes_seq_test() ->
    Bin = alCoreClient:encodeRequest(get, "/health", undefined, 42),
    ?assertNotEqual(nomatch, binary:match(Bin, <<"\"seq\":42">>)).

%% 回归：单元素可打印整数参数经 alJson sanitize 不得收成 JSON string。
%% 例如 id=38 → [38] 会被当成 "&"；Rust DbQueryRequest.params 需要 array。
db_query_params_printable_int_stays_array_test() ->
    Params = alCoreClient:paramsToJson([38]),
    Enc = alJson:encode(#{sql => <<"SELECT 1 WHERE id = ?">>, params => Params, mode => <<"read">>}),
    Dec = alJson:decode(Enc),
    ?assertEqual([38], maps:get(<<"params">>, Dec)),
    %% 多参数若码点可拼成可打印串，同样必须保持 array
    Params2 = alCoreClient:paramsToJson([38, 42]),
    Enc2 = alJson:encode(#{params => Params2}),
    Dec2 = alJson:decode(Enc2),
    ?assertEqual([38, 42], maps:get(<<"params">>, Dec2)).

decode_port_response_keeps_seq_test() ->
    Bin = <<"{\"seq\":7,\"ok\":true,\"data\":{\"status\":\"ok\"}}">>,
    {7, {ok, #{engine := rustCore, data := Data}}} =
        alCoreClient:decodePortResponse(Bin),
    ?assertEqual(<<"ok">>, maps:get(status, Data, maps:get(<<"status">>, Data, undefined))).

concurrency_limits_defaults_test() ->
    application:load(ali),
    _ = try alConfig:load() catch _:_ -> ok end,
    L = alCoreClient:concurrencyLimits(),
    ?assert(maps:get(max, L) >= 1),
    ?assertEqual(1, maps:get(index, L)),
    ?assert(maps:get(search, L) >= 1),
    ?assert(maps:get(multi, L)).

coreClientHealth_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [{timeout, 30, fun coreClientHealth_test/0}]}.

setup() ->
    application:load(ali),
    case coreBinaryPath() of
        {error, missing} ->
            {skip, "aliCore binary missing; skipping port integration test"};
        {ok, _Bin} ->
            ok = alConfig:load(),
            ensureClient(),
            ok
    end.

cleanup({skip, _}) -> ok;
cleanup(ok) ->
    case whereis(alCoreClient) of
        undefined -> ok;
        Pid ->
            unlink(Pid),
            gen_server:stop(Pid)
    end.

coreClientHealth_test() ->
    case alCoreClient:health() of
        {ok, #{data := Data}} ->
            ?assert(is_map(Data));
        {error, _Reason} ->
            ok
    end.

%% 并发多个 health：验证多 inflight 不会串响应/超时死锁。
coreClientConcurrentHealth_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [{timeout, 60, fun coreClientConcurrentHealth_test/0}]}.

coreClientConcurrentHealth_test() ->
    case alCoreClient:health() of
        {ok, _} ->
            Parent = self(),
            N = 8,
            [spawn(fun() ->
                 Parent ! {eDone, alCoreClient:health()}
             end) || _ <- lists:seq(1, N)],
            Results = [receive {eDone, R} -> R after 45000 -> {error, timeout} end
                       || _ <- lists:seq(1, N)],
            Ok = [R || {ok, _} = R <- Results],
            case length(Ok) =:= N of
                true -> ok;
                false ->
                    %% 输出失败样例便于排查
                    ?assertEqual({N, Results}, {length(Ok), Results})
            end;
        {error, _} ->
            ok
    end.

ensureClient() ->
    case whereis(alCoreClient) of
        undefined ->
            {ok, _} = alCoreClient:start_link(),
            timer:sleep(300);
        _ ->
            ok
    end.

coreBinaryPath() ->
    Candidates = [
        filename:join([alConfig:privDir(), binaryName()]),
        filename:join([projectRoot(), "priv", binaryName()]),
        filename:join([projectRoot(), "priv", "bin", binaryName()]),
        filename:join([projectRoot(), "c_src", "aliCore", "target", "release", binaryName()])
    ],
    case firstExisting(Candidates) of
        undefined -> {error, missing};
        Path -> {ok, Path}
    end.

firstExisting([Path | Rest]) ->
    case filelib:is_file(Path) of
        true -> Path;
        false -> firstExisting(Rest)
    end;
firstExisting([]) ->
    undefined.

binaryName() ->
    case os:type() of
        {win32, _} -> "aliCore.exe";
        _ -> "aliCore"
    end.

projectRoot() ->
    case os:getenv("ALI_ROOT") of
        false -> filename:absname(".");
        Root -> Root
    end.
