%% Boot smoke — run via priv/scripts/smoke.ps1 (not part of the release app).
-module(smoke_boot).
-export([main/0]).

main() ->
    ok = alConfig:load(),
    Llm = alLlmClient:llmConfig(#{}),
    KeySet = maps:get(apiKey, Llm, undefined) =/= undefined,
    io:format("llm.provider=~p model=~p key_set=~p~n",
              [maps:get(provider, Llm), maps:get(model, Llm), KeySet]),
    case KeySet of
        false ->
            io:format("FAIL llm.apiKey not configured in aliCfg.cfg~n"),
            halt(1);
        true ->
            ok
    end,
    case application:ensure_all_started(ali) of
        {ok, _} -> ok;
        {error, Reason} ->
            io:format("FAIL application start: ~p~n", [Reason]),
            halt(1)
    end,
    Checks = [
        alSessionMgr,
        alServer,
        alHttpGateway,
        alWebConnSup,
        alWebSup,
        ali_sup
    ],
    lists:foreach(
        fun(Name) ->
            case whereis(Name) of
                Pid when is_pid(Pid) ->
                    io:format("OK  ~p ~p~n", [Name, Pid]);
                _ ->
                    io:format("FAIL ~p not running~n", [Name]),
                    halt(1)
            end
        end,
        Checks
    ),
    case erlang:function_exported(alSessionMgr, ensureSession, 2) of
        true -> ok;
        false ->
            io:format("FAIL alSessionMgr:ensureSession/2 not exported (stale beam)~n"),
            halt(1)
    end,
    case alSessionMgr:ensureSession(<<"web">>, web) of
        {ok, _} ->
            io:format("OK  ensureSession(web)~n");
        Other ->
            io:format("FAIL ensureSession: ~p~n", [Other]),
            halt(1)
    end,
    Gw = alHttpGateway:status(),
    io:format("gateway=~p~n", [Gw]),
    case maps:get(enabled, Gw, false) of
        true ->
            Port = maps:get(port, Gw),
            io:format("SMOKE OK — open http://127.0.0.1:~p/~n", [Port]),
            halt(0);
        false ->
            io:format("FAIL gateway not listening: ~p~n", [Gw]),
            halt(1)
    end.
