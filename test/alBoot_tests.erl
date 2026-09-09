%%% @doc Boot / wiring checks that unit tests miss.
%%%
%%% Catches stale beams (missing exports), broken DeepSeek LLM config,
%%% and supervision order assumptions — the class of bugs that pass
%%% eunit but break `rebar3 shell` + Web UI.
-module(alBoot_tests).

-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% Critical MFA must exist in loaded beams (stale-beam detector).
%%--------------------------------------------------------------------

critical_exports_test() ->
    lists:foreach(
        fun({M, F, A}) ->
            Exports = M:module_info(exports),
            ?assertEqual(
                {M, F, A, true},
                {M, F, A, lists:member({F, A}, Exports)}
            )
        end,
        criticalMfas()
    ).

criticalMfas() ->
    [
        {alConfig, load, 0},
        {alConfig, get, 1},
        {alConfig, get, 2},
        {alConfig, root, 0},
        {alConfig, projectRoot, 0},
        {alConfig, codeRoots, 0},
        {ali, addPaths, 1},
        {ali, start, 0},
        {ali, start, 1},
        {ali, stop, 0},
        {ali, prepare, 0},
        {ali, prepare, 1},
        {ali, ready, 0},
        {alConfig, getAgentCfg, 0},
        {alConfig, corePortArgs, 0},
        {alConfig, qdrantServiceUrl, 0},
        {alConfig, qdrantManaged, 0},
        {alConfig, resolvePath, 2},
        {alSessionMgr, start_link, 0},
        {alSessionMgr, ensureSession, 2},
        {alSessionMgr, getContext, 1},
        {alSessionMgr, appendMessage, 2},
        {alServer, start_link, 0},
        {alServer, ask, 2},
        {alServer, sessions, 0},
        {alServer, getMode, 0},
        {alServer, ensureSessionWorker, 1},
        {alHttpGateway, start_link, 0},
        {alHttpGateway, status, 0},
        {alHttpGateway, enabled, 0},
        {alHttpGateway, port, 0},
        {alWebConnSup, start_link, 0},
        {alWebSup, start_link, 0},
        {alWebHandler, handle, 3},
        {alWs, initState, 0},
        {alWs, dispatch, 3},
        {alLlmClient, chat, 2},
        {alLlmClient, llmConfig, 1},
        {alQdrant, start_link, 0},
        {alQdrant, status, 0},
        {alCoreClient, start_link, 0},
        {ali_sup, start_link, 0},
        {ali_app, start, 2}
    ].

%%--------------------------------------------------------------------
%% Config + LLM wiring（provider 无关：用户可在 deepseek / 本地 provider 间切换）
%%--------------------------------------------------------------------

config_loads_test() ->
    ?assertEqual(ok, alConfig:load()),
    ?assert(is_list(alConfig:root())).

llm_config_ready_test() ->
    ok = alConfig:load(),
    Llm = alConfig:get(llm, #{}),
    HasChain = case maps:get(chain, Llm, []) of
        [E | _] when is_map(E) -> true;
        _ -> false
    end,
    ?assert(maps:is_key(provider, Llm) orelse HasChain),
    Cfg = alLlmClient:llmConfig(#{}),
    %% apiKey is intentionally undefined by default (user-configured);
    %% only validate non-emptiness when it has been set.
    ApiKey = maps:get(apiKey, Cfg, undefined),
    case ApiKey of
        undefined -> ok;
        <<>> -> ?assert(false);
        "" -> ?assert(false);
        _ -> ok
    end,
    ?assertNotEqual(undefined, maps:get(baseUrl, Cfg, undefined)),
    ?assertNotEqual(undefined, maps:get(model, Cfg, undefined)).

web_and_gateway_listen_config_test() ->
    ok = alConfig:load(),
    ?assertEqual(true, alHttpGateway:enabled()),
    Port = alHttpGateway:port(),
    ?assert(is_integer(Port) andalso Port > 0).

%%--------------------------------------------------------------------
%% Supervision order: web must start after session_mgr + server.
%%--------------------------------------------------------------------

sup_child_order_test() ->
    {ok, {_Flags, Children}} = ali_sup:init([]),
    Ids = [maps:get(id, C) || C <- Children],
    SessionPos = indexOf(alSessionMgr, Ids),
    ServerPos = indexOf(alServer, Ids),
    WebPos = indexOf(alWebSup, Ids),
    ?assert(SessionPos < WebPos),
    ?assert(ServerPos < WebPos).

indexOf(Id, List) ->
    indexOf(Id, List, 1).

indexOf(Id, [Id | _], N) -> N;
indexOf(Id, [_ | Rest], N) -> indexOf(Id, Rest, N + 1);
indexOf(Id, [], _) -> error({missingChild, Id}).
