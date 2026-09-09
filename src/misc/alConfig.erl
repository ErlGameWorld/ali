%%%-------------------------------------------------------------------
%%% @doc 配置加载与访问模块。
%%%
%%% 从 `config/aliCfg.cfg' 读取 Erlang term 键值列表，经 {@link alKvsToBeam}
%%% 编译为 {@link alCfg} 模块 beam，运行时通过 {@link alCfg:getV/1} 查询。
%%%
%%% 查找顺序：`./config/aliCfg.cfg` → `./aliCfg.cfg`
%%%
%%% 路径约定：
%%% - 运行时数据：`dataDir`（默认 `./.ali`，可配置为 `xxx/.ali`），
%%%   下含 db / index / qdrant / sessions / backups / audit 等子目录。
%%% - 代码索引根：`projectRoot`（主工程）+ 顶层 `codeRoots`（额外库 / OTP 等），
%%%   见 {@link codeRoots/0}。
%%% - 可执行文件与打包资产：`privDir/0`（`code:priv_dir(ali)` + 回退），
%%%   配置里只写文件名（如 `aliCore`），release 放到任意目录均可定位。
%%% @end
%%%-------------------------------------------------------------------
-module(alConfig).

-compile({no_auto_import, [get/1]}).

-export([
    load/0,
    load/1,
    get/1,
    get/2,
    val/1,
    root/0,
    projectRoot/0,
    codeRoots/0,
    dataDir/0,
    dataPath/1,
    privDir/0,
    privFile/1,
    resolvePrivBinary/1,
    getAgentCfg/0,
    limit/1,
    corePortArgs/0,
    indexIgnoreCsv/0,
    indexIgnoreNames/0,
    qdrantServiceUrl/0,
    qdrantManaged/0,
    resolvePath/2,
    patch/1,
    validate/0
]).

%%--------------------------------------------------------------------
%% @doc
%% 加载配置文件：自动查找 ./config/aliCfg.cfg 或 ./aliCfg.cfg 并加载。
%% 加载后会执行 {@link expandPlaceholders/1} 把 `${ENV:VAR}' 替换为环境变量。
%%
%% @return ok | {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec load() -> ok | {error, term()}.
load() ->
    case findCfgFile() of
        {ok, Path} ->
            load(Path);
        {error, _} = Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% @doc
%% 加载指定路径的配置文件：file:consult 解析为 term，归一化为 KVs，
%% 编译到 alCfg beam 并写入 persistent_term。
%% 加载后展开 `${ENV:VAR}' 占位符，再调用 {@link validate/0}。
%% 若 cfg 中显式设置 `strictCfg => true' 且关键项缺失，load 返回
%% `{error, {cfgMissing, _}}' 而非 ok，并回滚到加载前的旧 KVs，
%% 避免半加载的坏配置污染运行时。
%%
%% @param Path 配置文件路径
%% @return ok | {error, {cfgReadFailed, Path, Reason} | {error, {cfgMissing, _}}}
%% @end
%%--------------------------------------------------------------------
-spec load(file:name()) -> ok | {error, term()}.
load(Path) ->
    case file:consult(Path) of
        {ok, Terms} ->
            KVs0 = kvsFromTerms(Terms),
            KVs1 = normalizeKvs(KVs0),
            KVs = expandPlaceholders(KVs1),
            OldKVs = persistent_term:get({?MODULE, kvs}, undefined),
            case alKvsToBeam:load(alCfg, KVs) of
                ok ->
                    persistent_term:put({?MODULE, kvs}, KVs),
                    Strict = case lists:keyfind(strictCfg, 1, KVs) of
                        {strictCfg, V} -> V =:= true;
                        false -> false
                    end,
                    case validate(Strict) of
                        ok -> ok;
                        {error, _} = Err ->
                            %% 校验失败：回滚到旧 KVs，避免坏配置污染运行时。
                            rollbackKvs(OldKVs),
                            Err
                    end;
                {error, _} = Err ->
                    %% 编译失败：保留旧配置不变。
                    Err
            end;
        {error, Reason} ->
            {error, {cfgReadFailed, Path, Reason}}
    end.

%% 把 persistent_term 与 alCfg beam 回滚到 OldKVs。
%% OldKVs 为 undefined（首次加载）时不做任何事，保持 undefined 状态。
rollbackKvs(undefined) ->
    ok;
rollbackKvs(OldKVs) ->
    _ = alKvsToBeam:load(alCfg, OldKVs),
    persistent_term:put({?MODULE, kvs}, OldKVs),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% 按键查询配置值（委托 alCfg:getV/1）。
%%
%% @param Key 配置键
%% @return 配置值；未定义返回 undefined
%% @end
%%--------------------------------------------------------------------
-spec get(term()) -> term().
get(Key) ->
    alCfg:getV(Key).

%%--------------------------------------------------------------------
%% @doc
%% 按键查询配置值，未定义时返回 Default。
%%
%% @param Key 配置键
%% @param Default 默认值
%% @return 配置值或 Default
%% @end
%%--------------------------------------------------------------------
-spec get(term(), term()) -> term().
get(Key, Default) ->
    case alCfg:getV(Key) of
        undefined -> Default;
        Value -> Value
    end.

%%--------------------------------------------------------------------
%% @doc
%% 返回项目根目录（配置 root 键，默认当前目录）。
%%
%% @return 根目录 string
%% @end
%%--------------------------------------------------------------------
-spec root() -> string().
root() ->
    collapseDots(toList(get(root, filename:absname(".")))).

%%--------------------------------------------------------------------
%% @doc
%% 返回项目代码根目录：优先取 agent.projectRoot，否则回退到 root/0。
%%
%% @return 项目根目录 string
%% @end
%%--------------------------------------------------------------------
-spec projectRoot() -> string().
projectRoot() ->
    Agent = get(agent, #{}),
    case maps:get(projectRoot, Agent, undefined) of
        undefined -> collapseDots(root());
        P -> collapseDots(resolvePath(root(), P))
    end.

%%--------------------------------------------------------------------
%% @doc
%% 返回需要建立代码索引的目录列表（绝对路径）。
%% 始终包含 {@link projectRoot/0}；另将顶层 `codeRoots` 配置（额外代码库、
%% OTP 源码目录等）解析后追加，并去重保序。
%%
%% 相对路径相对 {@link root/0}（启动/配置根）；绝对路径原样使用。
%%
%% @return [AbsPath :: string()]
%% @end
%%--------------------------------------------------------------------
-spec codeRoots() -> [string()].
codeRoots() ->
    Primary = projectRoot(),
    Extra = case get(codeRoots, []) of
        List when is_list(List) ->
            [collapseDots(resolvePath(root(), P)) || P <- List, isPathish(P)];
        _ ->
            []
    end,
    dedupePaths([Primary | Extra]).

%%--------------------------------------------------------------------
%% @doc
%% 返回运行时数据目录（默认 `./.ali`，相对启动时的 root/cwd）。
%% 可通过配置 `dataDir` 改为前缀路径，例如 `xxx/.ali`。
%%
%% @return 数据目录绝对路径 string
%% @end
%%--------------------------------------------------------------------
-spec dataDir() -> string().
dataDir() ->
    toList(get(dataDir, resolvePath(root(), ".ali"))).

%%--------------------------------------------------------------------
%% @doc
%% 在 dataDir 下拼接子路径（如 `"db/ali.db"` → `<dataDir>/db/ali.db`）。
%%
%% @param Rel 相对 dataDir 的路径
%% @return 绝对路径 string
%% @end
%%--------------------------------------------------------------------
-spec dataPath(term()) -> string().
dataPath(Rel) ->
    resolvePath(dataDir(), Rel).

%%--------------------------------------------------------------------
%% @doc
%% 返回应用 priv 目录：优先 `code:priv_dir(ali)`，失败则按 beam 位置回退，
%% 保证 release 放到任意目录都能找到打包的可执行文件与静态资源。
%%
%% @return priv 目录绝对路径 string
%% @end
%%--------------------------------------------------------------------
-spec privDir() -> string().
privDir() ->
    case code:priv_dir(ali) of
        {error, _} ->
            case code:which(?MODULE) of
                Filename when is_list(Filename) ->
                    filename:absname(filename:join([filename:dirname(Filename), "..", "priv"]));
                _ ->
                    filename:absname(filename:join(root(), "priv"))
            end;
        Dir ->
            filename:absname(Dir)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 在 priv 目录下拼接相对路径（如 `"db/schema.sql"`、`"web/index.html"`）。
%%
%% @param Rel 相对 priv 的路径
%% @return 绝对路径 string
%% @end
%%--------------------------------------------------------------------
-spec privFile(term()) -> string().
privFile(Rel) ->
    resolvePath(privDir(), Rel).

%%--------------------------------------------------------------------
%% @doc
%% 解析 priv 根目录下的可执行文件。配置可只写文件名（如 `"aliCore"`），
%% 也可写历史相对路径 `"priv/aliCore"`（会取 basename）。release / 源码树
%% 均通过 {@link privDir/0} 定位，无需改配置。
%%
%% @param Bin 可执行文件名或路径
%% @return 绝对路径 string
%% @end
%%--------------------------------------------------------------------
-spec resolvePrivBinary(term()) -> string().
resolvePrivBinary(undefined) ->
    resolvePrivBinary(binaryName());
resolvePrivBinary(Bin) ->
    Name = stripPrivPrefix(filename:basename(toList(Bin))),
    Priv = privDir(),
    Primary = filename:join(Priv, Name),
    Candidates = [
        Primary,
        alternateBinaryPath(Primary),
        %% 开发期：尚未 copy 到 priv 时回退 cargo release 产物
        filename:join([root(), "c_src", "aliCore", "target", "release", Name]),
        alternateBinaryPath(filename:join([root(), "c_src", "aliCore", "target", "release", Name])),
        %% legacy layout
        filename:join([Priv, "bin", Name]),
        alternateBinaryPath(filename:join([Priv, "bin", Name]))
    ],
    case firstExistingFile(Candidates) of
        {ok, Path} -> Path;
        error -> Primary
    end.

%%--------------------------------------------------------------------
%% @doc
%% get/1 的别名。
%%
%% @end
%%--------------------------------------------------------------------
-spec val(term()) -> term().
val(Key) ->
    get(Key).

%%--------------------------------------------------------------------
%% @doc
%% 返回 Agent 配置 map：合并配置文件中的 agent 配置与一组默认值（mode、
%% maxSteps、maxMessages、policy、skills 等），并补充 projectRoot 与 llm。
%%
%% @return Agent 配置 map
%% @end
%%--------------------------------------------------------------------
-spec getAgentCfg() -> map().
getAgentCfg() ->
    Agent = get(agent, #{}),
    Root = projectRoot(),
    SkillsRel = maps:get(skillsDir, Agent, "skills"),
    maps:merge(#{
        projectRoot => Root,
        mode => maps:get(mode, Agent, ask),
        maxSteps => maps:get(maxSteps, Agent, 50),
        maxMessages => maps:get(maxMessages, Agent, 50),
        maxContextChars => maps:get(maxContextChars, Agent, 120000),
        historyCompaction => maps:get(historyCompaction, Agent, true),
        skillsEnabled => maps:get(skillsEnabled, Agent, true),
        skillsDir => resolveSkillsDir(SkillsRel),
        maxActiveSkills => maps:get(maxActiveSkills, Agent, 2),
        personasEnabled => maps:get(personasEnabled, Agent, true),
        personasDir => resolveSkillsDir(maps:get(personasDir, Agent, "personas")),
        defaultPersona => maps:get(defaultPersona, Agent, erlang_expert),
        personasAutoMatch => maps:get(personasAutoMatch, Agent, true),
        experienceEnabled => maps:get(experienceEnabled, Agent, true),
        autoRecordLessons => maps:get(autoRecordLessons, Agent, true),
        experienceRecallLimit => maps:get(experienceRecallLimit, Agent, 5),
        systemPromptExtra => maps:get(systemPromptExtra, Agent, <<>>),
        policy => maps:get(policy, Agent, alPolicy:defaultPolicy()),
        toolCacheEnabled => maps:get(toolCacheEnabled, Agent, true),
        autoDistillMemories => maps:get(autoDistillMemories, Agent, true),
        memoryDistillModel => maps:get(memoryDistillModel, Agent, undefined),
        llm => get(llm, #{})
    }, Agent).

%%--------------------------------------------------------------------
%% @doc
%% 读取 limits 配置中的某一项；未定义返回 undefined。
%%
%% @param Key 限流键
%% @return 限流值 | undefined
%% @end
%%--------------------------------------------------------------------
-spec limit(atom()) -> term().
limit(Key) ->
    Limits = get(limits, #{}),
    maps:get(Key, Limits, undefined).

%%--------------------------------------------------------------------
%% @doc
%% 返回 Qdrant 服务 URL：优先取 qdrantUrl；否则当 qdrant.enabled 且 httpPort
%% 存在时构造 http://127.0.0.1:Port；其余情况返回 undefined。
%%
%% @return Qdrant URL string | undefined
%% @end
%%--------------------------------------------------------------------
-spec qdrantServiceUrl() -> string() | undefined.
qdrantServiceUrl() ->
    case get(qdrantUrl, undefined) of
        Url when Url =/= undefined ->
            toList(Url);
        undefined ->
            case get(qdrant, #{}) of
                #{enabled := true, httpPort := Port} when is_integer(Port) ->
                    "http://127.0.0.1:" ++ integer_to_list(Port);
                #{enabled := true, httpPort := Port} when is_list(Port) ->
                    "http://127.0.0.1:" ++ lists:flatten(Port);
                _ ->
                    undefined
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 判断 Qdrant 是否由本应用托管：未配置 qdrantUrl 且 qdrant.enabled=true 时为 true。
%%
%% @return boolean()
%% @end
%%--------------------------------------------------------------------
-spec qdrantManaged() -> boolean().
qdrantManaged() ->
    case get(qdrantUrl, undefined) of
        undefined ->
            maps:get(enabled, get(qdrant, #{}), false) =:= true;
        _ ->
            false
    end.

%%--------------------------------------------------------------------
%% @doc
%% 构造 aliCore 启动参数（唯一配置通道）：
%% `core.args`（默认含 `--port`）+ 按需 `--ali-*=`。
%% 未启用的 embedding/rerank/qdrant 等不传。
%% Rust `main` 解析 `--ali-*` 后供内部使用；Erlang **不**再注入 ALI_* env。
%%
%% @return [string()]
%% @end
%%--------------------------------------------------------------------
-spec corePortArgs() -> [string()].
corePortArgs() ->
    Core = get(core, #{}),
    BaseArgs0 = case maps:get(args, Core, undefined) of
        Args when is_list(Args), Args =/= [] -> [toList(A) || A <- Args];
        _ -> ["--port"]
    end,
    BaseArgs = case lists:member("--port", BaseArgs0) of
        true -> BaseArgs0;
        false -> BaseArgs0 ++ ["--port"]
    end,
    Exts = case maps:get(indexExtensions, Core, undefined) of
        undefined -> "erl,hrl";
        <<>> -> "erl,hrl";
        "" -> "erl,hrl";
        E -> toList(E)
    end,
    Required = [
        "--ali-root=" ++ projectRoot(),
        "--ali-data-dir=" ++ dataDir(),
        "--ali-db-path=" ++ toList(maps:get(dbPath, Core, dataPath("db/ali.db"))),
        "--ali-db-schema=" ++ toList(maps:get(dbSchema, Core, privFile("db/schema.sql"))),
        "--ali-index-dir=" ++ toList(maps:get(indexDir, Core, dataPath("index/tantivy"))),
        "--ali-index-ignore=" ++ indexIgnoreCsv(),
        "--ali-index-extensions=" ++ Exts,
        "--ali-index-async=" ++ envBool(maps:get(indexAsync, Core, true)),
        "--ali-hybrid-candidate-scan=" ++ envBool(maps:get(hybridCandidateScan, Core, true))
    ],
    Optional0 = [
        maybeArg("--ali-code-roots", string:join(codeRoots(), ";")),
        maybeArg("--ali-rust-log", coreRustLog(Core)),
        maybeArg("--ali-index-threads", maps:get(indexThreads, Core, undefined)),
        maybeArg("--ali-index-file-timeout-secs", maps:get(indexFileTimeoutSecs, Core, 30)),
        maybeArg("--ali-core-limit-total", maps:get(maxInflight, Core, undefined)),
        maybeArg("--ali-core-limit-index", maps:get(limitIndex, Core, undefined)),
        maybeArg("--ali-core-limit-search", maps:get(limitSearch, Core, undefined)),
        maybeArg("--ali-core-limit-db", maps:get(limitDb, Core, undefined)),
        maybeArg("--ali-core-limit-memory", maps:get(limitMemory, Core, undefined)),
        maybeArg("--ali-core-limit-memory-write", maps:get(limitMemoryWrite, Core, undefined)),
        maybeArg("--ali-core-limit-graph", maps:get(limitGraph, Core, undefined)),
        maybeArg("--ali-core-limit-other", maps:get(limitOther, Core, undefined)),
        maybeArg("--ali-core-worker-threads", maps:get(workerThreads, Core, undefined))
    ],
    Embedding = get(embedding, #{}),
    Rerank = get(rerank, #{}),
    Llm = get(llm, #{}),
    LlmKey = firstNonempty([
        maps:get(apiKey, Llm, undefined),
        llmChainApiKey(Llm)
    ]),
    {EmbedKey, EmbedBase, EmbedModel} = featureEnv(Embedding, LlmKey),
    {RerankKey, RerankBase, RerankModel} = featureEnv(Rerank, LlmKey),
    Optional1 = [
        maybeArg("--ali-qdrant-url", qdrantServiceUrl()),
        maybeArg("--ali-embedding-api-key", EmbedKey),
        maybeArg("--ali-embedding-base-url", EmbedBase),
        maybeArg("--ali-embedding-model", EmbedModel),
        maybeArg("--ali-rerank-api-key", RerankKey),
        maybeArg("--ali-rerank-base-url", RerankBase),
        maybeArg("--ali-rerank-model", RerankModel)
    ],
    BaseArgs ++ Required ++ [A || A <- Optional0 ++ Optional1, A =/= undefined].

%% 有值才生成 `--flag=value`；undefined / 空串不传。
maybeArg(_Flag, undefined) -> undefined;
maybeArg(_Flag, <<>>) -> undefined;
maybeArg(_Flag, "") -> undefined;
maybeArg(Flag, Value) -> Flag ++ "=" ++ toList(Value).

%%--------------------------------------------------------------------
%% @doc
%% 索引/浏览/文本搜索共用的忽略目录 CSV（权威来源：`core.indexIgnore`）。
%% 未配置时用内置默认串，保证启动参数始终非空。
%% @end
%%--------------------------------------------------------------------
-spec indexIgnoreCsv() -> string().
indexIgnoreCsv() ->
    Core = get(core, #{}),
    case maps:get(indexIgnore, Core, undefined) of
        undefined -> defaultIndexIgnoreCsv();
        <<>> -> defaultIndexIgnoreCsv();
        "" -> defaultIndexIgnoreCsv();
        V -> toList(V)
    end.

%%--------------------------------------------------------------------
%% @doc 将 {@link indexIgnoreCsv/0} 拆成目录名列表（已 trim）。
%% @end
%%--------------------------------------------------------------------
-spec indexIgnoreNames() -> [string()].
indexIgnoreNames() ->
    [string:trim(P) || P <- string:tokens(indexIgnoreCsv(), ",;"),
                       string:trim(P) =/= ""].

%% 唯一默认忽略列表（Erlang 侧兜底）；正式环境请在 aliCfg.cfg 写全。
defaultIndexIgnoreCsv() ->
    "_build,deps,.git,.svn,target,.ali,log,logs,ebin,node_modules,"
    ".idea,.cursor,.vscode,priv/index,pb,*_pb.erl".

%% aliCore 日志级别：debugLog=false → error；true → logFilter 或 info。
coreRustLog(Core) when is_map(Core) ->
    case maps:get(debugLog, Core, false) of
        true ->
            case maps:get(logFilter, Core, undefined) of
                undefined -> "info";
                Filter -> toList(Filter)
            end;
        _ ->
            "error"
    end.

%% embedding / rerank：enabled 且 baseUrl+apiKey 齐才启用。
%% apiKey 仅当显式 `inherit` 时复用 llm key；undefined 视为未配置。
%% model 必填（不向 Rust 留空让其发明 OpenAI 模型名）。
featureEnv(Cfg, LlmKey) when is_map(Cfg) ->
    Enabled = maps:get(enabled, Cfg, false) =:= true,
    BaseUrl = nonempty(maps:get(baseUrl, Cfg, undefined)),
    Model = nonempty(maps:get(model, Cfg, undefined)),
    Key = case maps:get(apiKey, Cfg, undefined) of
        inherit -> nonempty(LlmKey);
        Other -> nonempty(Other)
    end,
    case Enabled andalso BaseUrl =/= undefined andalso Key =/= undefined
         andalso Model =/= undefined of
        true -> {Key, BaseUrl, Model};
        false -> {undefined, undefined, undefined}
    end;
featureEnv(_, _) ->
    {undefined, undefined, undefined}.

nonempty(undefined) -> undefined;
nonempty(<<>>) -> undefined;
nonempty("") -> undefined;
nonempty(V) -> V.

%% llm.chain 非空即视为已配置 LLM（项内仍须各自有效 baseUrl/model）。
llmChainConfigured(Llm) when is_map(Llm) ->
    case maps:get(chain, Llm, undefined) of
        Chain when is_list(Chain), Chain =/= [] -> true;
        _ -> false
    end;
llmChainConfigured(_) ->
    false.

%% 从 chain 云端项取 apiKey，供 embedding/rerank inherit。
llmChainApiKey(Llm) when is_map(Llm) ->
    Chain = maps:get(chain, Llm, []),
    CloudKeys = [maps:get(apiKey, E, undefined)
                 || E <- Chain, is_map(E),
                    maps:get(local, E, maps:get(<<"local">>, E, false)) =:= false,
                    maps:get(apiKey, E, undefined) =/= undefined],
    case CloudKeys of
        [K | _] -> K;
        [] ->
            case Chain of
                [E | _] when is_map(E) -> maps:get(apiKey, E, undefined);
                _ -> undefined
            end
    end;
llmChainApiKey(_) ->
    undefined.

firstNonempty([]) -> undefined;
firstNonempty([V | Rest]) ->
    case isMissingConfigValue(V) of
        true -> firstNonempty(Rest);
        false -> V
    end.

%%--------------------------------------------------------------------
%% @doc
%% 运行时打补丁：将 PatchKVs 合并到当前 KVs（覆盖同名键、追加新键），
%% 重新编译 alCfg beam 并更新 persistent_term。
%% 合并后展开占位符（占位符可在运行时覆盖项中再次出现）。
%% 编译失败时不更新 persistent_term，避免运行时配置与 beam 不一致。
%%
%% @param PatchKVs 待合并的 [{Key, Value}]
%% @return ok | {error, {compile, Reason}}
%% @end
%%--------------------------------------------------------------------
-spec patch([{term(), term()}]) -> ok | {error, {compile, term()}}.
patch(PatchKVs) ->
    Base = persistent_term:get({?MODULE, kvs}, []),
    Merged = mergeKvs(Base, PatchKVs),
    KVs = expandPlaceholders(Merged),
    case alKvsToBeam:load(alCfg, KVs) of
        ok ->
            persistent_term:put({?MODULE, kvs}, KVs),
            ok;
        {error, _} = Err ->
            Err
    end.

%%--------------------------------------------------------------------
%% @doc
%% 配置验证：检查关键配置项的完整性与一致性，缺失项输出 warning 日志。
%% 验证内容：LLM apiKey/baseUrl/model、core 二进制存在性、db schema 存在性。
%% 严格模式下（Strict = true）会通过 load/1 调用，对未设置关键项返回
%% `{error, {cfgMissing, ...}}'，使启动失败而非静默使用空配置。
%%
%% @return `ok'（仅输出日志，不阻断启动）
%% @end
%%--------------------------------------------------------------------
-spec validate() -> ok.
validate() ->
    validate(false).

%%--------------------------------------------------------------------
%% @doc
%% 配置验证的严格模式：除日志外还会检测必填关键项，缺失时通过日志
%% 报告全部问题。仅当 Strict = true 且存在关键项缺失时返回 error；
%% 警告/信息项仅记录不阻断。
%%
%% @param Strict true 时对核心缺失返回 {error, _}
%% @return ok | {error, {cfgMissing, [MissingKeys]}}
%% @end
%%--------------------------------------------------------------------
-spec validate(boolean()) -> ok | {error, {cfgMissing, [atom()]}}.
validate(Strict) ->
    Llm = get(llm, #{}),
    HasChain = llmChainConfigured(Llm),
    TopMissing = lists:foldl(fun({K, Val}, Acc) ->
        case isMissingConfigValue(Val) of
            true -> [K | Acc];
            false -> Acc
        end
    end, [], [{llmApiKey, maps:get(apiKey, Llm, undefined)},
              {llmBaseUrl, maps:get(baseUrl, Llm, undefined)},
              {llmModel, maps:get(model, Llm, undefined)}]),
    Missing = case HasChain of
        true -> [];
        false -> [llmChain | TopMissing]
    end,
    case Missing of
        [] -> ok;
        _ ->
            logger:warning("alConfig: missing critical config: ~p", [Missing])
    end,
    case HasChain of
        true -> ok;
        false ->
            case maps:get(apiKey, Llm, undefined) of
                undefined -> logger:warning("alConfig: llm.chain empty and llm.apiKey not set; LLM unavailable");
                _ -> ok
            end,
            case maps:get(model, Llm, undefined) of
                undefined -> logger:warning("alConfig: llm.chain empty and llm.model not set");
                _ -> ok
            end,
            case maps:get(baseUrl, Llm, undefined) of
                undefined -> logger:warning("alConfig: llm.chain empty and llm.baseUrl not set");
                _ -> ok
            end
    end,
    Core = get(core, #{}),
    case maps:get(enabled, Core, false) of
        true ->
            Bin = maps:get(binary, Core, undefined),
            case Bin =/= undefined andalso filelib:is_file(Bin) of
                true -> ok;
                false -> logger:warning("alConfig: core.binary not found at ~p", [Bin])
            end;
        false ->
            ok
    end,
    Db = get(db, #{}),
    case maps:get(enabled, Db, false) of
        true ->
            Schema = maps:get(schema, Db, undefined),
            case Schema =/= undefined andalso filelib:is_file(Schema) of
                true -> ok;
                false -> logger:warning("alConfig: db.schema not found at ~p", [Schema])
            end;
        false ->
            ok
    end,
    case Missing of
        [] -> ok;
        _ ->
            case Strict of
                true -> {error, {cfgMissing, Missing}};
                false -> ok
            end
    end.

%% Empty values and unresolved environment placeholders are both missing.
%% Treating a literal placeholder as a credential defers a clear startup
%% error into a confusing remote HTTP authentication failure.
isMissingConfigValue(undefined) -> true;
isMissingConfigValue(<<>>) -> true;
isMissingConfigValue("") -> true;
isMissingConfigValue(Value) when is_list(Value) ->
    isMissingConfigValue(unicode:characters_to_binary(Value));
isMissingConfigValue(Value) when is_binary(Value) ->
    binary:match(Value, <<"${ENV:">>) =/= nomatch;
isMissingConfigValue(_) -> false.

%%--------------------------------------------------------------------
%% @doc
%% 合并 KVs：对原 KVs 中已存在的键用 Patch 覆盖，其余保持；追加 Patch 中的全新键。
%%
%% @end
%%--------------------------------------------------------------------
mergeKvs(KVs, PatchKVs) ->
    PatchMap = maps:from_list(PatchKVs),
    Merged0 = [{Key, maps:get(Key, PatchMap, Value)} || {Key, Value} <- KVs],
    Extra = [{Key, Value} || {Key, Value} <- PatchKVs, not lists:keymember(Key, 1, KVs)],
    Merged0 ++ Extra.

%%--------------------------------------------------------------------
%% @doc
%% 查找配置文件：按 ./config/aliCfg.cfg → ./aliCfg.cfg 顺序查找。
%%
%% @return {ok, Path} | {error, cfgNotFound}
%% @end
%%--------------------------------------------------------------------
findCfgFile() ->
    EnvCandidates = case os:getenv("ALI_CFG") of
        false -> [];
        "" -> [];
        EnvPath -> [EnvPath]
    end,
    AppCandidates = case application:get_env(ali, cfg) of
        {ok, Path} when is_list(Path); is_binary(Path) -> [toList(Path)];
        _ -> []
    end,
    Cwd = filename:absname("."),
    CwdCandidates = [
        filename:join(Cwd, "config/aliCfg.cfg"),
        filename:join(Cwd, "aliCfg.cfg")
    ],
    findExisting(AppCandidates ++ EnvCandidates ++ CwdCandidates).

%%--------------------------------------------------------------------
%% @doc
%% 在候选路径列表中查找第一个存在的常规文件。
%%
%% @end
%%--------------------------------------------------------------------
findExisting([Path | Rest]) ->
    case filelib:is_regular(Path) of
        true -> {ok, Path};
        false -> findExisting(Rest)
    end;
findExisting([]) ->
    {error, cfgNotFound}.

%%--------------------------------------------------------------------
%% @doc
%% 从 file:consult 解析出的 Terms 中提取键值列表：取第一个 list 或整个 list。
%%
%% @end
%%--------------------------------------------------------------------
kvsFromTerms([List | _]) when is_list(List) ->
    List;
kvsFromTerms(List) when is_list(List) ->
    List;
kvsFromTerms(_) ->
    [].

%%--------------------------------------------------------------------
%% @doc
%% 归一化 KVs：将 root / dataDir / codeRoots 解析为绝对路径，对 core/db/qdrant
%% 等条目做路径归一化，并展开 web 子键为 web* 平铺键。
%%
%% @end
%%--------------------------------------------------------------------
normalizeKvs(KVs) ->
    Root0 = proplists:get_value(root, KVs, "."),
    Root = collapseDots(resolvePath(filename:absname("."), Root0)),
    DataDir0 = proplists:get_value(dataDir, KVs, ".ali"),
    DataDir = collapseDots(resolvePath(Root, DataDir0)),
    CodeRoots = normalizeCodeRootsList(Root, proplists:get_value(codeRoots, KVs, [])),
    Base = [
        {root, Root},
        {dataDir, DataDir},
        {codeRoots, CodeRoots}
        | [normalizeEntry(Key, Value, Root, DataDir)
           || {Key, Value} <- KVs, Key =/= root, Key =/= dataDir, Key =/= codeRoots]
    ],
    flattenWebKeys(Base).

%% 将 codeRoots 配置项解析为绝对路径列表（相对路径相对 Root）。
normalizeCodeRootsList(Root, List) when is_list(List) ->
    dedupePaths([collapseDots(resolvePath(Root, P)) || P <- List, isPathish(P)]);
normalizeCodeRootsList(_Root, _) ->
    [].

%% 路径样配置值：非空 list / binary。
isPathish(P) when is_list(P), P =/= [] -> true;
isPathish(P) when is_binary(P), byte_size(P) > 0 -> true;
isPathish(_) -> false.

%% 去重保序（路径按字符串比较）。
dedupePaths(Paths) ->
    {Out, _} = lists:foldl(
        fun(P, {Acc, Seen}) ->
            Key = string:lowercase(toList(P)),
            case maps:is_key(Key, Seen) of
                true -> {Acc, Seen};
                false -> {Acc ++ [toList(P)], Seen#{Key => true}}
            end
        end,
        {[], #{}},
        Paths
    ),
    Out.

%% Fold "." / ".." so absname("f:/ali", ".") does not leave a trailing
%% "/." (or a "." component) that breaks prefix path checks.
collapseDots(Path) when is_list(Path) ->
    filename:join(collapseParts(filename:split(Path), []));
collapseDots(Path) when is_binary(Path) ->
    unicode:characters_to_list(collapseDots(unicode:characters_to_list(Path)));
collapseDots(Path) ->
    Path.

collapseParts(["." | Rest], Acc) ->
    collapseParts(Rest, Acc);
collapseParts([".." | Rest], []) ->
    collapseParts(Rest, []);
collapseParts([".." | Rest], [_Top | Acc]) ->
    collapseParts(Rest, Acc);
collapseParts([Part | Rest], Acc) ->
    collapseParts(Rest, [Part | Acc]);
collapseParts([], []) ->
    ["."];
collapseParts([], Acc) ->
    lists:reverse(Acc).

%%--------------------------------------------------------------------
%% @doc
%% 将 web map 的子字段平铺为 webEnabled / webPort / webAllowOrigin 等
%% 独立键，便于快速查询；web 非 map 时原样返回。
%%
%% @end
%%--------------------------------------------------------------------
flattenWebKeys(KVs) ->
    case proplists:get_value(web, KVs) of
        Web when is_map(Web) ->
            KVs ++ [
                {webEnabled, maps:get(enabled, Web, true)},
                {webPort, maps:get(port, Web, 8088)},
                {webAllowOrigin, maps:get(allowOrigin, Web, undefined)},
                {webApiToken, maps:get(apiToken, Web, undefined)},
                {webRateLimit, maps:get(rateLimit, Web, 0)},
                {webRateWindowMs, maps:get(rateWindowMs, Web, 60000)},
                {webAllowRemoteWrites, maps:get(allowRemoteWrites, Web, false)}
            ];
        _ ->
            KVs
    end.

%%--------------------------------------------------------------------
%% @doc
%% 单个条目归一化分发：core / db / qdrant / agent 走对应归一化函数，其余原样返回。
%%
%% @end
%%--------------------------------------------------------------------
normalizeEntry(core, Map, Root, DataDir) when is_map(Map) ->
    {core, normalizeCore(Map, Root, DataDir)};
normalizeEntry(db, Map, Root, DataDir) when is_map(Map) ->
    {db, normalizeDb(Map, Root, DataDir)};
normalizeEntry(qdrant, Map, Root, DataDir) when is_map(Map) ->
    {qdrant, normalizeQdrant(Map, Root, DataDir)};
normalizeEntry(agent, Map, Root, DataDir) when is_map(Map) ->
    {agent, normalizeAgent(Map, Root, DataDir)};
normalizeEntry(Key, Value, _Root, _DataDir) ->
    {Key, Value}.

%%--------------------------------------------------------------------
%% @doc
%% 归一化 qdrant 配置：binary 经 priv_dir 解析；storagePath 落在 dataDir 下。
%%
%% @end
%%--------------------------------------------------------------------
normalizeQdrant(Map, Root, DataDir) ->
    maps:merge(Map, #{
        binary => resolvePrivBinary(maps:get(binary, Map, qdrantBinaryName())),
        storagePath => resolveDataPath(Root, DataDir, maps:get(storagePath, Map, "qdrant/storage"))
    }).

%%--------------------------------------------------------------------
%% @doc
%% 返回当前 OS 下 Qdrant 可执行文件名（Windows 为 qdrant.exe，其它为 qdrant）。
%%
%% @end
%%--------------------------------------------------------------------
qdrantBinaryName() ->
    case os:type() of
        {win32, _} -> "qdrant.exe";
        _ -> "qdrant"
    end.

%%--------------------------------------------------------------------
%% @doc
%% 归一化 core 配置：binary 经 priv_dir；db/index 落在 dataDir；schema 在 priv。
%%
%% @end
%%--------------------------------------------------------------------
normalizeCore(Map, Root, DataDir) ->
    Base = maps:merge(Map, #{
        binary => resolvePrivBinary(maps:get(binary, Map, undefined)),
        dbPath => resolveDataPath(Root, DataDir, maps:get(dbPath, Map, "db/ali.db")),
        dbSchema => resolveAssetPath(Root, maps:get(dbSchema, Map, "db/schema.sql")),
        indexDir => resolveDataPath(Root, DataDir, maps:get(indexDir, Map, "index/tantivy"))
    }),
    deriveCoreConcurrency(Base).

%%--------------------------------------------------------------------
%% @doc
%% 从 core.concurrency 策略推导并发数，并回填为旧字段：
%% maxInflight/limitSearch/.../workerThreads。
%%
%% 兼容策略：
%% - manual：尊重显式 limit* / workerThreads
%% - auto（默认）：若未显式设置旧字段，则根据 schedulers_online 与 profile 推导
%%
%% 配置意图应尽量表达“策略”而非直接数字：
%% `#{mode => auto, profile => balanced, target => balanced}'
%% @end
%%--------------------------------------------------------------------
deriveCoreConcurrency(Core0) when is_map(Core0) ->
    Cfg0 = maps:get(concurrency, Core0, #{}),
    Cfg = case Cfg0 of
        M when is_map(M) -> M;
        _ -> #{}
    end,
    Mode = maps:get(mode, Cfg, auto),
    case Mode of
        manual ->
            Core0;
        _ ->
            Profile0 = maps:get(profile, Cfg, balanced),
            Profile = normalizeConcurrencyProfile(Profile0),
            Target = normalizeConcurrencyTarget(maps:get(target, Cfg, balanced)),
            Schedulers = max(2, erlang:system_info(schedulers_online)),
            Reserve = clampInt(maps:get(reserveSchedulers, Cfg, reserveSchedulers(Profile)), 0,
                               max(0, Schedulers - 1), reserveSchedulers(Profile)),
            Effective = max(1, Schedulers - Reserve),
            WorkerThreads = deriveWorkerThreads(Effective, Profile, Cfg),
            Total = deriveTotalInflight(Effective, Profile, Target, Cfg),
            Limits = deriveClassLimits(Effective, Profile, Target, Total, Cfg),
            Core0#{
                concurrency => Cfg#{
                    mode => auto,
                    profile => Profile,
                    target => Target,
                    schedulersOnline => Schedulers,
                    effectiveSchedulers => Effective
                },
                %% auto 模式下仅信 concurrency 策略，不再被旧顶层数字静默覆盖。
                workerThreads => WorkerThreads,
                maxInflight => Total,
                limitIndex => maps:get(index, Limits),
                limitSearch => maps:get(search, Limits),
                limitDb => maps:get(db, Limits),
                limitMemory => maps:get(memory, Limits),
                limitMemoryWrite => maps:get(memoryWrite, Limits),
                limitGraph => maps:get(graph, Limits),
                limitOther => maps:get(other, Limits)
            }
    end.

normalizeConcurrencyProfile(conservative) -> conservative;
normalizeConcurrencyProfile(aggressive) -> aggressive;
normalizeConcurrencyProfile(_) -> balanced.

normalizeConcurrencyTarget(latency) -> latency;
normalizeConcurrencyTarget(throughput) -> throughput;
normalizeConcurrencyTarget(_) -> balanced.

reserveSchedulers(conservative) -> 2;
reserveSchedulers(aggressive) -> 1;
reserveSchedulers(balanced) -> 1.

deriveWorkerThreads(Effective, Profile, Cfg) ->
    Default = case Profile of
        conservative -> max(1, min(4, Effective));
        aggressive -> max(2, min(16, Effective));
        balanced -> max(2, min(8, Effective))
    end,
    clampInt(maps:get(workerThreads, Cfg, Default), 1, max(1, Effective), Default).

deriveTotalInflight(Effective, Profile, Target, Cfg) ->
    Base = case {Profile, Target} of
        {conservative, _} -> Effective * 2;
        {balanced, latency} -> Effective * 3;
        {balanced, throughput} -> Effective * 4;
        {balanced, _} -> Effective * 3;
        {aggressive, latency} -> Effective * 4;
        {aggressive, throughput} -> Effective * 6;
        {aggressive, _} -> Effective * 5
    end,
    HardMax = clampInt(maps:get(hardMaxInflight, Cfg, 64), 4, 256, 64),
    clampInt(maps:get(maxInflight, Cfg, Base), 4, HardMax, Base).

deriveClassLimits(Effective, Profile, Target, Total, Cfg) ->
    Search0 = case {Profile, Target} of
        {conservative, _} -> max(2, Effective);
        {balanced, latency} -> max(4, Effective * 2);
        {balanced, throughput} -> max(6, Effective * 2);
        {balanced, _} -> max(4, Effective * 2);
        {aggressive, latency} -> max(6, Effective * 2);
        {aggressive, throughput} -> max(8, Effective * 3);
        {aggressive, _} -> max(6, Effective * 2)
    end,
    Db0 = case Profile of
        conservative -> max(2, min(4, Effective));
        aggressive -> max(4, min(8, Effective * 2));
        balanced -> max(3, min(6, Effective))
    end,
    Memory0 = case Target of
        throughput -> max(4, Effective * 2);
        _ -> max(4, Effective)
    end,
    Graph0 = max(2, min(8, Effective)),
    Other0 = max(2, min(8, Effective)),
    LimitIndex = clampInt(maps:get(limitIndex, Cfg, 1), 1, 1, 1),
    LimitSearch = clampInt(maps:get(limitSearch, Cfg, Search0), 1, Total, Search0),
    LimitDb = clampInt(maps:get(limitDb, Cfg, Db0), 1, Total, Db0),
    LimitMemory = clampInt(maps:get(limitMemory, Cfg, Memory0), 1, Total, Memory0),
    LimitMemoryWrite = clampInt(maps:get(limitMemoryWrite, Cfg, 2), 1, Total, 2),
    LimitGraph = clampInt(maps:get(limitGraph, Cfg, Graph0), 1, Total, Graph0),
    LimitOther = clampInt(maps:get(limitOther, Cfg, Other0), 1, Total, Other0),
    #{
        index => LimitIndex,
        search => LimitSearch,
        db => LimitDb,
        memory => LimitMemory,
        memoryWrite => LimitMemoryWrite,
        graph => LimitGraph,
        other => LimitOther
    }.

clampInt(V, Min, Max, _Default) when is_integer(V) ->
    if V < Min -> Min; V > Max -> Max; true -> V end;
clampInt(V, Min, Max, Default) when is_binary(V) ->
    try clampInt(binary_to_integer(V), Min, Max, Default) catch _:_ -> Default end;
clampInt(V, Min, Max, Default) when is_list(V) ->
    try clampInt(list_to_integer(V), Min, Max, Default) catch _:_ -> Default end;
clampInt(_, _Min, _Max, Default) ->
    Default.

%%--------------------------------------------------------------------
%% @doc
%% 归一化 db 配置：path 在 dataDir，schema 在 priv。
%%
%% @end
%%--------------------------------------------------------------------
normalizeDb(Map, Root, DataDir) ->
    maps:merge(Map, #{
        path => resolveDataPath(Root, DataDir, maps:get(path, Map, "db/ali.db")),
        schema => resolveAssetPath(Root, maps:get(schema, Map, "db/schema.sql"))
    }).

%%--------------------------------------------------------------------
%% @doc
%% 归一化 agent：backupDir 相对 dataDir；skillsDir 相对 priv。
%%
%% @end
%%--------------------------------------------------------------------
normalizeAgent(Map, Root, DataDir) ->
    Backup = maps:get(backupDir, Map, "backups"),
    Skills = maps:get(skillsDir, Map, "skills"),
    Personas = maps:get(personasDir, Map, "personas"),
    maps:merge(Map, #{
        backupDir => resolveDataPath(Root, DataDir, Backup),
        skillsDir => resolveSkillsDir(Skills),
        personasDir => resolveSkillsDir(Personas)
    }).

%%--------------------------------------------------------------------
%% @doc
%% 解析运行时数据路径：相对路径默认相对 dataDir；以 `.ali/` / `priv/` 开头或
%% 含 `/.ali/` 的路径按 root 解析（兼容旧配置）。
%%
%% @end
%%--------------------------------------------------------------------
resolveDataPath(Root, DataDir, Path) ->
    List = toList(Path),
    case filename:pathtype(List) of
        relative ->
            case isRootRelativeDataPath(List) of
                true -> resolvePathImpl(Root, migrateLegacyPrivData(List));
                false -> resolvePathImpl(DataDir, List)
            end;
        _ ->
            filename:absname(List)
    end.

%% 旧配置把可变数据放在 priv/ 下：映射到 dataDir 相对路径（去掉 priv/ 前缀）。
migrateLegacyPrivData("priv/" ++ Rest) ->
    case lists:prefix("db/", Rest)
        orelse lists:prefix("index/", Rest)
        orelse lists:prefix("qdrant/", Rest) of
        true -> filename:join(".ali", Rest);
        false -> "priv/" ++ Rest
    end;
migrateLegacyPrivData(Path) ->
    Path.

%% 判断路径是否按项目 root 表达（而非相对 dataDir 的短路径）。
isRootRelativeDataPath(Path) ->
    Path =:= ".ali"
        orelse lists:prefix(".ali/", Path)
        orelse lists:prefix("priv/", Path)
        orelse string:find(Path, "/.ali/") =/= nomatch
        orelse lists:suffix("/.ali", Path).

%%--------------------------------------------------------------------
%% @doc
%% 解析打包资产路径（schema / skills 等）：相对路径落在 priv_dir 下。
%%
%% @end
%%--------------------------------------------------------------------
resolveAssetPath(_Root, Path) ->
    List = toList(Path),
    case filename:pathtype(List) of
        relative -> privFile(stripPrivPrefix(List));
        _ -> filename:absname(List)
    end.

%% skills 目录：相对路径相对 priv；绝对路径原样。
resolveSkillsDir(Path) ->
    resolveAssetPath(undefined, Path).

%% 去掉配置里可选的 `priv/` 前缀，得到相对 priv 根的路径。
stripPrivPrefix("priv/" ++ Rest) -> Rest;
stripPrivPrefix("priv\\" ++ Rest) -> Rest;
stripPrivPrefix(Path) -> Path.

%%--------------------------------------------------------------------
%% @doc
%% 在路径列表中查找第一个存在的文件。
%%
%% @return {ok, Path} | error
%% @end
%%--------------------------------------------------------------------
firstExistingFile([Path | Rest]) ->
    case filelib:is_file(Path) of
        true -> {ok, Path};
        false -> firstExistingFile(Rest)
    end;
firstExistingFile([]) ->
    error.

%%--------------------------------------------------------------------
%% @doc
%% 按 OS 切换二进制路径的扩展名：Windows 下 .exe ⇄ 无扩展名，其它 OS 去掉扩展名。
%%
%% @end
%%--------------------------------------------------------------------
alternateBinaryPath(Path) ->
    case os:type() of
        {win32, _} ->
            case filename:extension(Path) of
                ".exe" -> filename:rootname(Path);
                _ -> Path ++ ".exe"
            end;
        _ ->
            filename:rootname(Path)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 返回当前 OS 下 aliCore 可执行文件名（Windows 为 aliCore.exe，其它为 aliCore）。
%%
%% @end
%%--------------------------------------------------------------------
binaryName() ->
    case os:type() of
        {win32, _} -> "aliCore.exe";
        _ -> "aliCore"
    end.

%%--------------------------------------------------------------------
%% @doc
%% 将路径解析为相对 root 的绝对路径；支持 binary / list / atom 类型输入。
%% 非常规类型直接原样返回。
%%
%% @param Root 根目录
%% @param Path 待解析路径
%% @return 绝对路径 string
%% @end
%%--------------------------------------------------------------------
-spec resolvePath(string(), term()) -> string().
resolvePath(_Root, Path) when is_binary(Path) ->
    resolvePathImpl(_Root, unicode:characters_to_list(Path));
resolvePath(Root, Path) when is_list(Path) ->
    resolvePathImpl(Root, Path);
resolvePath(Root, Path) when is_atom(Path) ->
    resolvePathImpl(Root, atom_to_list(Path));
resolvePath(_Root, Path) ->
    Path.

%%--------------------------------------------------------------------
%% @doc
%% 路径解析实现：相对路径按 root 拼接为绝对路径，绝对路径原样返回。
%%
%% @end
%%--------------------------------------------------------------------
resolvePathImpl(Root, Path) when is_list(Path) ->
    case filename:pathtype(Path) of
        relative -> filename:absname(filename:join(Root, Path));
        _ -> filename:absname(Path)
    end;
resolvePathImpl(Root, Path) ->
    resolvePathImpl(Root, toList(Path)).

%%--------------------------------------------------------------------
%% @doc
%% 将布尔/原子/任意值转为字符串形式的环境变量值。
%%
%% @end
%%--------------------------------------------------------------------
envBool(true) -> "true";
envBool(false) -> "false";
envBool(Value) when is_atom(Value) -> atom_to_list(Value);
envBool(Value) -> toList(Value).

%%--------------------------------------------------------------------
%% @doc
%% 将任意输入转为 list：支持 list / binary / atom 及其它 term（~p 格式化）。
%%
%% @end
%%--------------------------------------------------------------------
toList(Value) when is_list(Value) ->
    Value;
toList(Value) when is_binary(Value) ->
    unicode:characters_to_list(Value);
toList(Value) when is_atom(Value) ->
    atom_to_list(Value);
toList(Value) ->
    lists:flatten(io_lib:format("~p", [Value])).

%%--------------------------------------------------------------------
%% @doc
%% 展开 KVs 字符串值中的 `${ENV:VAR}' 占位符：
%%   - `${ENV:VAR_NAME}'  → os:getenv("VAR_NAME")
%%   - 变量未设置时占位符保持原样（避免误删合法字面量）
%%   - 递归展开 map / list 中的字符串；其他类型原样保留
%% 数字、atom、binary 中的 binary 列表/非字符串均按值透传。
%%
%% @param KVs [{Key, Value}] 配置项列表
%% @return 展开后的 KVs
%% @end
%%--------------------------------------------------------------------
expandPlaceholders(KVs) when is_list(KVs) ->
    [{K, expandValue(V)} || {K, V} <- KVs].

expandValue(V) when is_map(V) ->
    maps:from_list([{K, expandValue(Val)} || {K, Val} <- maps:to_list(V)]);
expandValue(V) when is_list(V) ->
    case io_lib:char_list(V) of
        true -> expandString(V);
        false -> [expandValue(I) || I <- V]
    end;
expandValue(V) when is_binary(V) ->
    expandString(unicode:characters_to_list(V));
expandValue(V) when is_atom(V) ->
    V;
expandValue(V) ->
    V.

%% 在字符串中查找并替换 `${ENV:VAR}' 占位符。
%% 匹配失败时保留原值以避免误删合法 `${` 字面量。
expandString(Str) when is_list(Str) ->
    case string:find(Str, "${ENV:") of
        nomatch -> Str;
        _ -> doExpand(unicode:characters_to_binary(Str))
    end;
expandString(Bin) when is_binary(Bin) ->
    case string:find(unicode:characters_to_list(Bin), "${ENV:") of
        nomatch -> Bin;
        _ -> doExpand(Bin)
    end;
expandString(Other) -> Other.

%% 在 binary 中扫描 ${ENV:VAR}，逐个替换为 os:getenv(...)
%% 未设置时保留原占位符 + 输出 warning。
%% 使用累加器尾递归，规避 ${ENV:} 之类的非法占位符造成无限递归。
doExpand(Bin) when is_binary(Bin) ->
    doExpand(Bin, <<>>).

doExpand(Bin, Acc) when byte_size(Bin) =< 5 ->
    <<Acc/binary, Bin/binary>>;
doExpand(Bin, Acc) ->
    case binary:match(Bin, <<"${ENV:">>) of
        nomatch ->
            <<Acc/binary, Bin/binary>>;
        {Start, _} ->
            Pre = binary:part(Bin, 0, Start),
            Rest = binary:part(Bin, Start + 6, byte_size(Bin) - Start - 6),
            {Name, After} = readEnvName(Rest, <<>>),
            Acc1 = <<Acc/binary, Pre/binary>>,
            case Name of
                <<>> ->
                    %% 变量名为空：原样保留 ${ENV:... 字面量。
                    Acc2 = <<Acc1/binary, "${ENV:">>,
                    doExpand(After, Acc2);
                _ ->
                    Replacement = lookupEnv(Name),
                    %% 若 readEnvName 以 '}' 结束，把 '}' 拼回 Replacement。
                    Acc2 = case After of
                        <<$}, Tail/binary>> ->
                            <<Acc1/binary, Replacement/binary, $}, Tail/binary>>;
                        _ ->
                            doExpand(After, <<Acc1/binary, Replacement/binary>>)
                    end,
                    Acc2
            end
    end.

%% 读取环境变量名（连续字母/数字/下划线），返回 {Name, Remainder}。
%% 第一个 byte 必须是字母/数字/下划线；否则终止并返回空名。
%% 余下的第一个 byte（若为 '}'）即占位符结束符，会在调用方被重新拼回。
readEnvName(<<H, Rest/binary>>, Acc)
        when (H >= $A andalso H =< $Z); (H >= $a andalso H =< $z);
             (H >= $0 andalso H =< $9); H =:= $_ ->
    readEnvName(Rest, <<Acc/binary, H>>);
readEnvName(<<$}, Rest/binary>>, Acc) ->
    {Acc, Rest};
readEnvName(Other, Acc) ->
    {Acc, Other}.

%% 查找环境变量，未设置时返回原占位符的提示文本。
lookupEnv(<<>>) ->
    <<"${ENV:}">>;
lookupEnv(Name) when is_binary(Name) ->
    lookupEnv(unicode:characters_to_list(Name));
lookupEnv(Name) when is_list(Name) ->
    case os:getenv(Name) of
        false ->
            logger:warning("alConfig: env var ~s not set; placeholder kept literal", [Name]),
            <<"${ENV:", (list_to_binary(Name))/binary, "}">>;
        Val when is_list(Val) ->
            unicode:characters_to_binary(Val);
        Val when is_binary(Val) ->
            Val
    end;
lookupEnv(Name) when is_atom(Name) ->
    lookupEnv(atom_to_list(Name)).
