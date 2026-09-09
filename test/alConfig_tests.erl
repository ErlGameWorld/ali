%%% @doc EUnit tests for aliCfg.cfg loading.
-module(alConfig_tests).

-include_lib("eunit/include/eunit.hrl").

loadCfgTest_test() ->
    ?assertEqual(ok, alConfig:load()),
    ?assert(is_list(alConfig:root())),
    ?assert(is_list(alConfig:dataDir())),
    ?assert(is_list(alConfig:privDir())),
    ?assertEqual(filename:join(alConfig:root(), ".ali"), alConfig:dataDir()),
    ?assertMatch(#{enabled := true}, alConfig:get(core)),
    ?assertMatch(#{enabled := true}, alConfig:get(gateway)),
    ?assert(is_list(alConfig:corePortArgs())),
    Args = alConfig:corePortArgs(),
    ?assert(lists:member("--port", Args)),
    ?assert(lists:any(fun(A) -> lists:prefix("--ali-data-dir=", A) end, Args)),
    ?assert(lists:any(fun(A) -> lists:prefix("--ali-index-ignore=", A) end, Args)),
    ?assert(lists:any(fun(A) -> lists:prefix("--ali-root=", A) end, Args)),
    Core = alConfig:get(core),
    ?assert(lists:prefix(alConfig:dataDir(), maps:get(dbPath, Core))),
    Schema = maps:get(dbSchema, Core),
    ?assert(is_list(Schema)),
    ?assertNotEqual(string:find(Schema, "schema.sql"), nomatch),
    Roots = alConfig:codeRoots(),
    ?assert(is_list(Roots)),
    ?assertEqual([alConfig:projectRoot()], Roots).

codeRootsExtra_test() ->
    ok = alConfig:load(),
    Root = alConfig:root(),
    Extra = filename:join(Root, "priv"),
    ok = alConfig:patch([{codeRoots, [Extra, Extra, "priv"]}]),
    Roots = alConfig:codeRoots(),
    ?assertEqual(alConfig:projectRoot(), hd(Roots)),
    ?assert(lists:member(Extra, Roots)),
    %% Extra 与 "priv" 解析为同一绝对路径，应去重
    ?assertEqual(2, length(Roots)),
    ok = alConfig:load().

dataDirPrefix_test() ->
    ok = alConfig:load(),
    Root = alConfig:root(),
    Prefixed = filename:join(Root, "xxx/.ali"),
    ok = alConfig:patch([{dataDir, Prefixed}]),
    ?assertEqual(Prefixed, alConfig:dataDir()),
    ?assertEqual(filename:join(Prefixed, "db/store"), alConfig:dataPath("db/store")),
    ok = alConfig:load().

qdrantUrlManagedTest_test() ->
    ok = alConfig:load(),
    ?assertEqual(undefined, alConfig:qdrantServiceUrl()),
    ?assertEqual(false, alConfig:qdrantManaged()).

qdrantEnabledPortTest_test() ->
    ok = alConfig:load(),
    ok = alConfig:patch([
        {qdrantUrl, undefined},
        {qdrant, #{enabled => true, httpPort => 16400, grpcPort => 16401}}
    ]),
    ?assertEqual("http://127.0.0.1:16400", alConfig:qdrantServiceUrl()),
    ?assertEqual(true, alConfig:qdrantManaged()),
    ?assert(lists:member("--ali-qdrant-url=http://127.0.0.1:16400", alConfig:corePortArgs())).

%% embedding/rerank 关闭时不得传相关启动参数。
embeddingDisabledNoArgs_test() ->
    ok = alConfig:load(),
    ok = alConfig:patch([
        {embedding, #{enabled => false, apiKey => inherit, baseUrl => undefined}},
        {rerank, #{enabled => false, apiKey => inherit, baseUrl => undefined}}
    ]),
    Args = alConfig:corePortArgs(),
    ?assertEqual(false, lists:any(fun(A) -> lists:prefix("--ali-embedding-", A) end, Args)),
    ?assertEqual(false, lists:any(fun(A) -> lists:prefix("--ali-rerank-", A) end, Args)),
    ok = alConfig:load().

%% embedding 启用且配齐 baseUrl+model 时经 args 传入；apiKey=inherit 复用 llm key。
embeddingEnabledArgs_test() ->
    ok = alConfig:load(),
    Llm0 = alConfig:get(llm, #{}),
    ok = alConfig:patch([
        {llm, Llm0#{apiKey => "sk-llm-test"}},
        {embedding, #{
            enabled => true,
            apiKey => inherit,
            baseUrl => "https://embed.example/v1/embeddings",
            model => "m1"
        }}
    ]),
    Args = alConfig:corePortArgs(),
    ?assert(lists:member("--ali-embedding-api-key=sk-llm-test", Args)),
    ?assert(lists:member("--ali-embedding-base-url=https://embed.example/v1/embeddings", Args)),
    ?assert(lists:member("--ali-embedding-model=m1", Args)),
    ok = alConfig:load().

%% apiKey 未写 inherit 时不得静默继承 llm key。
embeddingUndefinedKeyNoInherit_test() ->
    ok = alConfig:load(),
    Llm0 = alConfig:get(llm, #{}),
    ok = alConfig:patch([
        {llm, Llm0#{apiKey => "sk-llm-test"}},
        {embedding, #{
            enabled => true,
            apiKey => undefined,
            baseUrl => "https://embed.example/v1/embeddings",
            model => "m1"
        }}
    ]),
    Args = alConfig:corePortArgs(),
    ?assertEqual(false, lists:any(fun(A) -> lists:prefix("--ali-embedding-api-key=", A) end, Args)),
    ok = alConfig:load().

%% core.concurrency=auto 时应自动推导并发上限并写入启动参数。
coreConcurrencyAutoArgs_test() ->
    ok = alConfig:load(),
    Core0 = alConfig:get(core, #{}),
    ok = alConfig:patch([
        {core, Core0#{
            concurrency => #{
                mode => auto,
                profile => balanced,
                target => balanced,
                reserveSchedulers => 1,
                hardMaxInflight => 64
            }
        }}
    ]),
    Core = alConfig:get(core, #{}),
    ?assert(maps:get(maxInflight, Core, 0) >= 4),
    ?assert(maps:get(limitSearch, Core, 0) >= 1),
    ?assert(maps:get(limitDb, Core, 0) >= 1),
    Args = alConfig:corePortArgs(),
    ?assert(lists:any(fun(A) -> lists:prefix("--ali-core-limit-total=", A) end, Args)),
    ?assert(lists:any(fun(A) -> lists:prefix("--ali-core-limit-search=", A) end, Args)),
    ?assert(lists:any(fun(A) -> lists:prefix("--ali-core-limit-db=", A) end, Args)),
    ok = alConfig:load().

%% auto 模式只信 core.concurrency；旧顶层数字字段不应静默覆盖新策略。
coreConcurrencyAutoIgnoresLegacyTopLevelLimits_test() ->
    ok = alConfig:load(),
    Core0 = alConfig:get(core, #{}),
    Strategy = #{
        mode => auto,
        profile => aggressive,
        target => throughput,
        reserveSchedulers => 1,
        hardMaxInflight => 64
    },
    Path = filename:join(".", "alConfig_auto_legacy_override_test.cfg"),
    CoreExpected = Core0#{concurrency => Strategy},
    ok = file:write_file(Path, io_lib:format("~tp.~n", [[
        {root, "."},
        {dataDir, ".ali"},
        {strictCfg, false},
        {core, CoreExpected}
    ]])),
    try
        ok = alConfig:load(Path),
        Expected = alConfig:get(core, #{}),
        CoreWithLegacy = CoreExpected#{
            %% 故意塞入极端旧值，验证 auto 时会被忽略
            maxInflight => 1,
            limitSearch => 1,
            limitDb => 1,
            workerThreads => 1
        },
        ok = file:write_file(Path, io_lib:format("~tp.~n", [[
            {root, "."},
            {dataDir, ".ali"},
            {strictCfg, false},
            {core, CoreWithLegacy}
        ]])),
        ok = alConfig:load(Path),
        Core = alConfig:get(core, #{}),
        ?assertEqual(maps:get(maxInflight, Expected), maps:get(maxInflight, Core)),
        ?assertEqual(maps:get(limitSearch, Expected), maps:get(limitSearch, Core)),
        ?assertEqual(maps:get(limitDb, Expected), maps:get(limitDb, Core)),
        ?assertEqual(maps:get(workerThreads, Expected), maps:get(workerThreads, Core))
    after
        _ = file:delete(Path),
        ok = alConfig:load()
    end,
    ok = alConfig:load().

getDefaultTest_test() ->
    ok = alConfig:load(),
    ?assertEqual(defaultValue, alConfig:get(missingKey, defaultValue)).
