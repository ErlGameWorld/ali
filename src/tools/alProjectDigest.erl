%%%-------------------------------------------------------------------
%% @doc 目标项目分层知识库（Project Digest）。
%%
%% 生成可检索资产到 `{dataDir}/knowledge/`，供问答 / NL 找 MFA 使用。
%% 不做整仓长文，不做审计流水。
%%
%% 层级：
%% <ul>
%% <li>L1 map.json — 模块地图（路径 + 摘要）</li>
%% <li>L2 api.json — export 面</li>
%% <li>L3 data.json — 表 ↔ 读写 MFA（dataSources）</li>
%% <li>L5 actions.json — NL → MFA 词典骨架</li>
%% <li>L6 modules/*.json — 模块上下文（注释 brief、behaviour、deps、include）</li>
%% <li>L7 summaries/*.md — 对话验证过的主题知识（saveKnowledge）</li>
%% <li>L8 deps.json — 模块调用依赖</li>
%% <li>L9 config.json — 项目配置摘录（可检索）</li>
%% </ul>
%% 构建结束时可选预学习经验（{@link alExperience:seedFromDigest/2}），
%% 把 actions / 表 MFA / OTP behaviour 写成 lesson，供后续召回。
%% @end
%%%-------------------------------------------------------------------

-module(alProjectDigest).

-include_lib("kernel/include/file.hrl").

-export([
    build/0,
    build/1,
    status/0,
    search/1,
    search/2,
    lookupAction/1,
    saveKnowledge/1,
    saveAction/1,
    knowledgeDir/0,
    loadMeta/0,
    agentHints/0,
    liveDataKeywords/0,
    liveDataOpKeywords/0,
    maybeBuildAfterIndex/0,
    maybeBuildOnStartup/0,
    rebuild/0,
    rebuild/1,
    browse/1,
    getSummary/1
]).

%% Test exports
-export([
    aggregateDataSources/1,
    matchKnowledge/2,
    moduleFromPath/1,
    sanitizeTopic/1,
    writeJsonAtomic/2,
    defaultOpts/0,
    seedActions/2,
    mergeActions/2,
    normalizeAgentHints/1,
    seedAgentHints/2,
    mergeAgentHints/2,
    pruneStaleActions/2,
    tableNameTokens/1,
    extractModuleDocFromErl/1,
    extractIncludesFromErl/1,
    composeModuleSearchText/1,
    expandTokensWithAliases/2,
    extractAliasesFromModuleDoc/2,
    autoAliasesFromModuleContexts/1,
    agentAliases/0,
    normalizeAgentAliases/1,
    mergeAliasMaps/2,
    resolveSourcePath/1,
    classifyModuleBucket/2,
    normalizeExports/1,
    correctExportArities/2,
    ignorePatternMatches/2,
    shouldSkipPath/1
]).

%% 默认不截断：知识库覆盖 discover 到的全部模块；仅调试时可显式传 maxModules
-define(DefaultMaxModules, unlimited).
-define(DefaultMaxSummaryWarm, 80).
-define(DefaultSearchLimit, 8).
-define(KnowledgeVersion, 1).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc 使用默认选项构建知识库。
%% @end
%%--------------------------------------------------------------------
-spec build() -> {ok, map()} | {error, term()}.
build() ->
    build(#{}).

%%--------------------------------------------------------------------
%% @doc
%% 构建分层知识库。
%%
%% Opts：
%% - `maxModules` — 可选截断；默认 `unlimited`（全量写入 api/map/deps/modules/*.json）
%% - `maxSummaryWarm` — warmLlm=true 时异步 LLM 摘要的模块数（按 export 数排序，默认 80；与落盘无关）
%% - `warmLlm` — true 时对 top 模块异步触发 alModuleSummary:generate/1
%% - `force` — true 时忽略 mtime，全量重写 modules（rebuild 默认 true）
%% - `updateAgentHints` — true 时软合并 agent.json（默认 true）
%% - `pruneStaleActions` — true 时剔除 api 中已不存在的 auto 动作（默认 true）
%% - `seedExperience` — true 时从 actions/表/behaviour 预学习 lesson（默认 true）
%% @end
%%--------------------------------------------------------------------
-spec build(map()) -> {ok, map()} | {error, term()}.
build(Opts) when is_map(Opts) ->
    Opts1 = maps:merge(defaultOpts(), Opts),
    try
        eraseDigestCache(),
        Dir = knowledgeDir(),
        ok = filelib:ensure_dir(filename:join(Dir, "modules/dummy")),
        Root = projectRoot(),
        Modules0 = discoverModules(Root),
        Modules1 = takeModules(Modules0, maps:get(maxModules, Opts1)),
        %% 打上分桶标签（core/cfg/test/gm），便于检索降权
        Modules = [M#{bucket => classifyModuleBucket(
            maps:get(module, M), maps:get(file, M, <<>>))} || M <- Modules1],
        ApiEntries = buildApiEntries(Modules),
        SortedByExports = sortByExportCount(ApiEntries),
        WarmN = maps:get(maxSummaryWarm, Opts1),
        WarmMods = [maps:get(module, E) || E <- lists:sublist(SortedByExports, WarmN)],
        WarmSet = maps:from_list([{M, true} || M <- WarmMods]),
        ModByAtom = maps:from_list([{maps:get(module, M), M} || M <- Modules]),
        AllModAtoms = [maps:get(module, M) || M <- Modules],
        Force = maps:get(force, Opts1, false) =:= true,
        {ModuleContexts, CtxStats} = buildModuleContexts(Dir, AllModAtoms, ModByAtom,
            maps:get(warmLlm, Opts1, false), WarmSet, Force),
        MapEntries = buildMapEntries(ApiEntries, ModuleContexts),
        DepsLayer = buildDepsLayer(Modules),
        ConfigLayer = buildConfigLayer(Root),
        Data = buildDataLayer(),
        Actions0 = loadOrInitActions(Dir, Data, ApiEntries),
        Actions = case maps:get(pruneStaleActions, Opts1, true) of
            true -> pruneStaleActions(Actions0, ApiEntries);
            false -> Actions0
        end,
        AgentHintInfo = case maps:get(updateAgentHints, Opts1, true) of
            true ->
                AutoAliases = autoAliasesFromModules(AllModAtoms, ModByAtom),
                Seeded0 = seedAgentHints(Data, Actions),
                Seeded = Seeded0#{aliases => AutoAliases},
                Existing = agentHints(),
                Merged = mergeAgentHints(Existing, Seeded),
                case writeAgentHints(Dir, Merged) of
                    ok -> #{updated => true, hints => Merged};
                    {error, WriteErr} ->
                        logger:warning("alProjectDigest: write agent.json failed: ~p", [WriteErr]),
                        #{updated => false, error => WriteErr}
                end;
            false ->
                #{updated => false, skipped => true}
        end,
        ExperienceSeed = maybeSeedExperience(Opts1, Actions, Data, ModuleContexts),
        BucketCounts = countBuckets(Modules),
        Meta = #{
            version => ?KnowledgeVersion,
            projectRoot => toBinary(Root),
            builtAt => erlang:system_time(second),
            moduleCount => length(Modules),
            discoveredCount => length(Modules0),
            apiCount => length(ApiEntries),
            tableCount => maps:size(maps:get(tables, Data, #{})),
            actionCount => length(Actions),
            summaryCount => maps:size(ModuleContexts),
            depsCount => length(maps:get(modules, DepsLayer, [])),
            configCount => length(maps:get(configs, ConfigLayer, [])),
            buckets => BucketCounts,
            incremental => CtxStats,
            agentHints => AgentHintInfo,
            experienceSeed => ExperienceSeed
        },
        ok = writeJsonAtomic(filename:join(Dir, "meta.json"), Meta),
        ok = writeJsonAtomic(filename:join(Dir, "map.json"), #{modules => MapEntries}),
        ok = writeJsonAtomic(filename:join(Dir, "api.json"), #{modules => stripApiInternal(ApiEntries)}),
        ok = writeJsonAtomic(filename:join(Dir, "data.json"), Data),
        ok = writeJsonAtomic(filename:join(Dir, "actions.json"), #{actions => Actions}),
        ok = writeJsonAtomic(filename:join(Dir, "deps.json"), DepsLayer),
        ok = writeJsonAtomic(filename:join(Dir, "config.json"), ConfigLayer),
        ok = writeModuleContextFiles(Dir, ModuleContexts),
        {ok, Meta}
    catch
        Class:Reason:Stack ->
            logger:warning("alProjectDigest:build failed: ~p:~p ~p",
                           [Class, Reason, lists:sublist(Stack, 8)]),
            {error, {Class, Reason}}
    end.

%%--------------------------------------------------------------------
%% @doc 知识库状态：是否存在、meta、路径。
%% @end
%%--------------------------------------------------------------------
-spec status() -> map().
status() ->
    Dir = knowledgeDir(),
    case loadMeta() of
        {ok, Meta} ->
            #{
                ready => true,
                path => toBinary(Dir),
                meta => Meta
            };
        undefined ->
            #{
                ready => false,
                path => toBinary(Dir),
                meta => undefined
            }
    end.

%%--------------------------------------------------------------------
%% @doc 在 map/api/actions/data 中按关键词检索。
%% @end
%%--------------------------------------------------------------------
-spec search(term()) -> {ok, [map()]}.
search(Query) ->
    search(Query, ?DefaultSearchLimit).

-spec search(term(), pos_integer()) -> {ok, [map()]}.
search(Query, Limit) when is_integer(Limit), Limit > 0 ->
    Q = string:lowercase(toBinary(Query)),
    Tokens0 = splitTokens(Q),
    Tokens = expandTokensWithAliases(Tokens0, agentAliases()),
    Hits0 = searchMap(Tokens) ++ searchApi(Tokens) ++ searchActions(Tokens)
        ++ searchData(Tokens) ++ searchSummaries(Tokens)
        ++ searchTopicSummaries(Tokens) ++ searchConfig(Tokens)
        ++ searchDeps(Tokens),
    Hits1 = dedupHits(Hits0),
    Scored = lists:sort(fun(#{score := A}, #{score := B}) -> A >= B end, Hits1),
    {ok, lists:sublist(Scored, Limit)}.

%%--------------------------------------------------------------------
%% @doc 查动作词典：短语 → 推荐 MFA。
%% @end
%%--------------------------------------------------------------------
-spec lookupAction(term()) -> {ok, [map()]} | {ok, []}.
lookupAction(Phrase) ->
    P = string:lowercase(toBinary(Phrase)),
    Actions = case readJson(filename:join(knowledgeDir(), "actions.json")) of
        {ok, #{actions := List}} when is_list(List) -> List;
        {ok, #{<<"actions">> := List}} when is_list(List) -> List;
        _ -> []
    end,
    Hits = [normalizeAction(A) || A <- Actions, actionMatches(P, A)],
    {ok, Hits}.

%%--------------------------------------------------------------------
%% @doc
%% 将本轮验证过的主题知识写入 `.ali/knowledge/summaries/<topic>.md`。
%% Args：topic（必填）、content（必填）、source（可选）。
%% @end
%%--------------------------------------------------------------------
-spec saveKnowledge(map()) -> {ok, map()} | {error, term()}.
saveKnowledge(Args) when is_map(Args) ->
    Topic0 = maps:get(topic, Args, maps:get(<<"topic">>, Args, undefined)),
    Content0 = maps:get(content, Args, maps:get(<<"content">>, Args, undefined)),
    Source = maps:get(source, Args, maps:get(<<"source">>, Args, <<"manual">>)),
    case {Topic0, Content0} of
        {undefined, _} -> {error, missingTopic};
        {_, undefined} -> {error, missingContent};
        {TopicRaw, ContentRaw} ->
            Topic = sanitizeTopic(TopicRaw),
            Content = toBinary(ContentRaw),
            case Topic =:= <<>> orelse Content =:= <<>> of
                true -> {error, emptyTopicOrContent};
                false ->
                    Dir = filename:join(knowledgeDir(), "summaries"),
                    ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
                    Path = filename:join(Dir, <<Topic/binary, ".md">>),
                    Now = calendar:universal_time(),
                    {{Y, Mo, D}, {H, Mi, S}} = Now,
                    Stamp = iolist_to_binary(io_lib:format(
                        "~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ",
                        [Y, Mo, D, H, Mi, S])),
                    Body = iolist_to_binary([
                        <<"---\n">>,
                        <<"topic: ">>, Topic, <<"\n">>,
                        <<"savedAt: ">>, Stamp, <<"\n">>,
                        <<"source: ">>, toBinary(Source), <<"\n">>,
                        <<"---\n\n">>,
                        Content, <<"\n">>
                    ]),
                    case file:write_file(Path, Body) of
                        ok ->
                            _ = try
                                alExperience:recordLesson(#{
                                    source => insight,
                                    symptom => <<"核实主题："/utf8, Topic/binary>>,
                                    prevention => Content,
                                    content => iolist_to_binary([
                                        <<"[knowledge:"/utf8>>, Topic, <<"]\n"/utf8>>, Content
                                    ]),
                                    tags => [insight, knowledge, Topic]
                                })
                            catch _:_ -> ok
                            end,
                            {ok, #{
                                topic => Topic,
                                path => Path,
                                bytes => byte_size(Body),
                                savedAt => Stamp
                            }};
                        {error, Reason} ->
                            {error, Reason}
                    end
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 固化/纠正一条 NL→MFA 动作到 actions.json（source=manual）。
%% Args：phrase、mfa 必填；note 可选。
%% @end
%%--------------------------------------------------------------------
-spec saveAction(map()) -> {ok, map()} | {error, term()}.
saveAction(Args) when is_map(Args) ->
    Phrase0 = maps:get(phrase, Args, maps:get(<<"phrase">>, Args, undefined)),
    Mfa0 = maps:get(mfa, Args, maps:get(<<"mfa">>, Args, undefined)),
    Note0 = maps:get(note, Args, maps:get(<<"note">>, Args, <<"manual correction">>)),
    case {Phrase0, Mfa0} of
        {undefined, _} -> {error, missingPhrase};
        {_, undefined} -> {error, missingMfa};
        {PhraseRaw, MfaRaw} ->
            Phrase = toBinary(PhraseRaw),
            Mfa = toBinary(MfaRaw),
            case Phrase =:= <<>> orelse Mfa =:= <<>> of
                true -> {error, emptyPhraseOrMfa};
                false ->
                    Dir = knowledgeDir(),
                    ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
                    Path = filename:join(Dir, "actions.json"),
                    Existing = case readJson(Path) of
                        {ok, #{actions := List}} when is_list(List) -> List;
                        {ok, #{<<"actions">> := List}} when is_list(List) -> List;
                        _ -> []
                    end,
                    Entry = #{
                        phrase => Phrase,
                        mfa => Mfa,
                        note => toBinary(Note0),
                        source => manual
                    },
                    Merged = mergeActions([Entry], [normalizeAction(A) || A <- Existing]),
                    case writeJsonAtomic(Path, #{actions => Merged}) of
                        ok ->
                            {ok, #{phrase => Phrase, mfa => Mfa, path => toBinary(Path),
                                   actionCount => length(Merged)}};
                        {error, Reason} ->
                            {error, Reason}
                    end
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 索引完成后异步刷新 knowledge（受 agent.digestAfterIndex 控制，默认 true）。
%% @end
%%--------------------------------------------------------------------
-spec maybeBuildAfterIndex() -> ok.
maybeBuildAfterIndex() ->
    Agent = alConfig:get(agent, #{}),
    case maps:get(digestAfterIndex, Agent, true) of
        false -> ok;
        _ -> spawnBuild(#{reason => afterIndex}, false)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 应用启动时：若尚无 knowledge（首次），等索引就绪后自动构建；
%% 已有 knowledge 时默认跳过（可用 digestRefreshOnStartup=true 强制刷新）。
%% 受 agent.digestOnStartup 控制，默认 true。
%% @end
%%--------------------------------------------------------------------
-spec maybeBuildOnStartup() -> ok.
maybeBuildOnStartup() ->
    Agent = alConfig:get(agent, #{}),
    case maps:get(digestOnStartup, Agent, true) of
        false ->
            ok;
        _ ->
            case {loadMeta(), maps:get(digestRefreshOnStartup, Agent, false)} of
                {undefined, _} ->
                    logger:info("alProjectDigest: no knowledge yet; will build after index ready"),
                    spawnBuild(#{reason => firstStart}, true);
                {{ok, _}, true} ->
                    logger:info("alProjectDigest: digestRefreshOnStartup; rebuild after index ready"),
                    spawnBuild(#{reason => startupRefresh}, true);
                {{ok, _}, _} ->
                    ok
            end
    end.

%%--------------------------------------------------------------------
%% @doc 强制重建知识库（不等待索引；供 /digest rebuild、Web API）。
%% @end
%%--------------------------------------------------------------------
-spec rebuild() -> {ok, map()} | {error, term()}.
rebuild() ->
    rebuild(#{}).

-spec rebuild(map()) -> {ok, map()} | {error, term()}.
rebuild(Opts) when is_map(Opts) ->
    %% Web /digest rebuild：默认强制全量（忽略 mtime 增量跳过）
    Force = maps:get(force, Opts, true),
    build(Opts#{force => Force}).

%%--------------------------------------------------------------------
%% @doc
%% 网页浏览：按层列出 knowledge 内容。
%% Opts：layer=overview|map|api|data|actions|summaries|agent，
%% q 过滤，limit/offset 分页。
%% @end
%%--------------------------------------------------------------------
-spec browse(map()) -> {ok, map()} | {error, term()}.
browse(Opts) when is_map(Opts) ->
    Layer0 = maps:get(layer, Opts, maps:get(<<"layer">>, Opts, overview)),
    Layer = normalizeBrowseLayer(Layer0),
    Q = string:lowercase(toBinary(maps:get(q, Opts, maps:get(<<"q">>, Opts, <<>>)))),
    Limit = positiveInt(maps:get(limit, Opts, maps:get(<<"limit">>, Opts, 80)), 80),
    Offset = nonNegInt(maps:get(offset, Opts, maps:get(<<"offset">>, Opts, 0)), 0),
    try
        {ok, browseLayer(Layer, Q, Limit, Offset)}
    catch
        Class:Reason:Stack ->
            logger:warning("alProjectDigest:browse failed: ~p:~p ~p",
                           [Class, Reason, lists:sublist(Stack, 6)]),
            {error, {Class, Reason}}
    end.

%%--------------------------------------------------------------------
%% @doc 读取 summaries/<topic>.md 正文（含 frontmatter）。
%% @end
%%--------------------------------------------------------------------
-spec getSummary(term()) -> {ok, map()} | {error, term()}.
getSummary(Topic0) ->
    Topic = sanitizeTopic(Topic0),
    case Topic =:= <<>> of
        true -> {error, emptyTopic};
        false ->
            Path = filename:join([knowledgeDir(), "summaries", <<Topic/binary, ".md">>]),
            case file:read_file(Path) of
                {ok, Bin} ->
                    {ok, #{topic => Topic, path => toBinary(Path), content => Bin,
                           bytes => byte_size(Bin)}};
                {error, enoent} -> {error, notFound};
                {error, Reason} -> {error, Reason}
            end
    end.

normalizeBrowseLayer(L) when is_atom(L) -> L;
normalizeBrowseLayer(L) when is_binary(L) ->
    case string:lowercase(L) of
        <<"overview">> -> overview;
        <<"map">> -> map;
        <<"api">> -> api;
        <<"data">> -> data;
        <<"actions">> -> actions;
        <<"summaries">> -> summaries;
        <<"summary">> -> summaries;
        <<"agent">> -> agent;
        <<"hints">> -> agent;
        _ -> overview
    end;
normalizeBrowseLayer(L) when is_list(L) ->
    normalizeBrowseLayer(unicode:characters_to_binary(L));
normalizeBrowseLayer(_) -> overview.

positiveInt(N, _Def) when is_integer(N), N > 0 -> min(N, 500);
positiveInt(_, Def) -> Def.

nonNegInt(N, _Def) when is_integer(N), N >= 0 -> N;
nonNegInt(_, Def) -> Def.

browseLayer(overview, _Q, _Limit, _Offset) ->
    St = status(),
    Hints = agentHints(),
    Dir = knowledgeDir(),
    Files = [
        {meta, filelib:is_file(filename:join(Dir, "meta.json"))},
        {map, filelib:is_file(filename:join(Dir, "map.json"))},
        {api, filelib:is_file(filename:join(Dir, "api.json"))},
        {data, filelib:is_file(filename:join(Dir, "data.json"))},
        {actions, filelib:is_file(filename:join(Dir, "actions.json"))},
        {agent, filelib:is_file(filename:join(Dir, "agent.json"))},
        {deps, filelib:is_file(filename:join(Dir, "deps.json"))},
        {config, filelib:is_file(filename:join(Dir, "config.json"))}
    ],
    TopicSummaryCount = length(listSummaryTopics()),
    ModuleSummaryCount = case St of
        #{meta := Meta0} when is_map(Meta0) ->
            maps:get(summaryCount, Meta0, maps:get(<<"summaryCount">>, Meta0, 0));
        _ -> 0
    end,
    St#{
        layer => overview,
        files => maps:from_list(Files),
        agentHints => Hints,
        summaryCount => TopicSummaryCount,
        topicSummaryCount => TopicSummaryCount,
        moduleSummaryCount => ModuleSummaryCount,
        liveDataKeywordCount => length(maps:get(liveDataKeywords, Hints, [])),
        liveDataOpKeywordCount => length(maps:get(liveDataOpKeywords, Hints, []))
    };
browseLayer(map, Q, Limit, Offset) ->
    Items0 = case readJson(filename:join(knowledgeDir(), "map.json")) of
        {ok, Map} ->
            [normalizeMapEntry(M) || M <- maps:get(modules, Map, maps:get(<<"modules">>, Map, []))];
        _ -> []
    end,
    Items1 = filterBrowseItems(Items0, Q, [module, summary, file]),
    pageBrowse(map, Items1, Limit, Offset);
browseLayer(api, Q, Limit, Offset) ->
    Items0 = case readJson(filename:join(knowledgeDir(), "api.json")) of
        {ok, Map} ->
            [normalizeApiEntry(M) || M <- maps:get(modules, Map, maps:get(<<"modules">>, Map, []))];
        _ -> []
    end,
    Items1 = filterBrowseItems(Items0, Q, [module, file]),
    pageBrowse(api, Items1, Limit, Offset);
browseLayer(data, Q, Limit, Offset) ->
    Items0 = case readJson(filename:join(knowledgeDir(), "data.json")) of
        {ok, Map} ->
            Tables = maps:get(tables, Map, maps:get(<<"tables">>, Map, #{})),
            maps:fold(fun(Tab, Callers, Acc) ->
                [#{
                    table => toBinary(Tab),
                    callerCount => length(ensureList(Callers)),
                    callers => lists:sublist(ensureList(Callers), 12)
                 } | Acc]
            end, [], Tables);
        _ -> []
    end,
    Items1 = filterBrowseItems(Items0, Q, [table]),
    pageBrowse(data, lists:sort(fun(A, B) ->
        maps:get(table, A, <<>>) =< maps:get(table, B, <<>>)
    end, Items1), Limit, Offset);
browseLayer(actions, Q, Limit, Offset) ->
    Items0 = case readJson(filename:join(knowledgeDir(), "actions.json")) of
        {ok, Map} ->
            [normalizeAction(A) || A <- maps:get(actions, Map, maps:get(<<"actions">>, Map, []))];
        _ -> []
    end,
    Items1 = filterBrowseItems(Items0, Q, [phrase, mfa, note]),
    pageBrowse(actions, Items1, Limit, Offset);
browseLayer(summaries, Q, Limit, Offset) ->
    Items0 = listSummaryTopics(),
    Items1 = case Q of
        <<>> -> Items0;
        _ -> [T || T <- Items0, binary:match(string:lowercase(maps:get(topic, T, <<>>)), Q) =/= nomatch]
    end,
    pageBrowse(summaries, Items1, Limit, Offset);
browseLayer(agent, _Q, _Limit, _Offset) ->
    Hints = agentHints(),
    Raw = case readJson(filename:join(knowledgeDir(), "agent.json")) of
        {ok, M} when is_map(M) -> M;
        _ -> #{}
    end,
    #{
        layer => agent,
        total => length(maps:get(liveDataKeywords, Hints, []))
            + length(maps:get(liveDataOpKeywords, Hints, [])),
        items => [Hints],
        liveDataKeywords => maps:get(liveDataKeywords, Hints, []),
        liveDataOpKeywords => maps:get(liveDataOpKeywords, Hints, []),
        updatedAt => maps:get(updatedAt, Raw, maps:get(<<"updatedAt">>, Raw, undefined)),
        note => maps:get(note, Raw, maps:get(<<"note">>, Raw, <<>>)),
        path => toBinary(filename:join(knowledgeDir(), "agent.json"))
    }.

normalizeMapEntry(M) when is_map(M) ->
    #{
        module => toBinary(maps:get(module, M, maps:get(<<"module">>, M, <<>>))),
        summary => toBinary(maps:get(summary, M, maps:get(<<"summary">>, M, <<>>))),
        file => toBinary(maps:get(file, M, maps:get(<<"file">>, M, <<>>)))
    };
normalizeMapEntry(_) -> #{module => <<>>, summary => <<>>, file => <<>>}.

normalizeApiEntry(M) when is_map(M) ->
    Exports = maps:get(exports, M, maps:get(<<"exports">>, M, [])),
    #{
        module => toBinary(maps:get(module, M, maps:get(<<"module">>, M, <<>>))),
        file => toBinary(maps:get(file, M, maps:get(<<"file">>, M, <<>>))),
        exportCount => length(ensureList(Exports)),
        exports => lists:sublist([
            #{
                name => toBinary(maps:get(name, E, maps:get(<<"name">>, E, <<>>))),
                arity => maps:get(arity, E, maps:get(<<"arity">>, E, 0))
             }
            || E <- ensureList(Exports), is_map(E)
        ], 40)
    };
normalizeApiEntry(_) -> #{module => <<>>, file => <<>>, exportCount => 0, exports => []}.

filterBrowseItems(Items, <<>>, _Keys) -> Items;
filterBrowseItems(Items, Q, Keys) ->
    lists:filter(fun(Item) when is_map(Item) ->
        lists:any(fun(K) ->
            V = string:lowercase(toBinary(maps:get(K, Item, <<>>))),
            binary:match(V, Q) =/= nomatch
        end, Keys);
    (_) -> false end, Items).

pageBrowse(Layer, Items, Limit, Offset) ->
    Total = length(Items),
    Slice = lists:sublist(lists:nthtail(min(Offset, Total), Items), Limit),
    #{layer => Layer, total => Total, offset => Offset, limit => Limit, items => Slice}.

listSummaryTopics() ->
    Dir = filename:join(knowledgeDir(), "summaries"),
    case file:list_dir(Dir) of
        {ok, Names} ->
            lists:filtermap(fun(Name) ->
                case filename:extension(Name) =:= ".md" of
                    false -> false;
                    true ->
                        Topic = filename:basename(Name, ".md"),
                        Path = filename:join(Dir, Name),
                        Size = case file:read_file_info(Path) of
                            {ok, #file_info{size = S}} -> S;
                            _ -> 0
                        end,
                        {true, #{topic => toBinary(Topic), path => toBinary(Path), bytes => Size}}
                end
            end, lists:sort(Names));
        _ -> []
    end.

spawnBuild(Meta, WaitIndex) ->
    _ = alAsync:run({projectDigestBuild, maps:get(reason, Meta, unknown)}, fun() ->
        case WaitIndex of
            true -> waitIndexQuiet(maps:get(digestWaitIndexMs,
                alConfig:get(agent, #{}), 600000));
            false -> ok
        end,
        case build(#{}) of
            {ok, Result} ->
                logger:info("alProjectDigest: build ok (~p) meta=~p",
                            [maps:get(reason, Meta, unknown),
                             maps:with([moduleCount, actionCount, tableCount], Result)]);
            {error, Reason} ->
                logger:warning("alProjectDigest: build failed (~p): ~p",
                               [maps:get(reason, Meta, unknown), Reason])
        end
    end),
    ok.

%% 轮询索引至非 indexing（或超时）；不抛错，超时仍尝试 build。
waitIndexQuiet(TimeoutMs) when is_integer(TimeoutMs), TimeoutMs > 0 ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    waitIndexQuietLoop(Deadline, 0);
waitIndexQuiet(_) ->
    waitIndexQuiet(600000).

waitIndexQuietLoop(Deadline, Stable) ->
    Now = erlang:monotonic_time(millisecond),
    case Now >= Deadline of
        true ->
            logger:warning("alProjectDigest: wait index timed out; building anyway"),
            ok;
        false ->
            case indexBusy() of
                false when Stable >= 2 ->
                    ok;
                false ->
                    timer:sleep(1000),
                    waitIndexQuietLoop(Deadline, Stable + 1);
                true ->
                    timer:sleep(2000),
                    waitIndexQuietLoop(Deadline, 0)
            end
    end.

indexBusy() ->
    try
        case alCoreClient:indexStatus() of
            {ok, Body} ->
                St = case Body of
                    #{data := D} when is_map(D) -> D;
                    M when is_map(M) -> M;
                    _ -> #{}
                end,
                maps:get(indexing, St, maps:get(<<"indexing">>, St, false)) =:= true;
            _ ->
                false
        end
    catch _:_ ->
        false
    end.

%% topic → 安全文件名（字母数字、-_）
sanitizeTopic(Topic) ->
    Bin = toBinary(Topic),
    Lower = string:lowercase(Bin),
    << <<(sanitizeTopicByte(C))/binary>> || <<C>> <= Lower >>.

sanitizeTopicByte(C) when C >= $a, C =< $z -> <<C>>;
sanitizeTopicByte(C) when C >= $0, C =< $9 -> <<C>>;
sanitizeTopicByte($-) -> <<"-">>;
sanitizeTopicByte($_) -> <<"_">>;
sanitizeTopicByte($.) -> <<"-">>;
sanitizeTopicByte($/) -> <<"-">>;
sanitizeTopicByte($\\) -> <<"-">>;
sanitizeTopicByte($ ) -> <<"-">>;
sanitizeTopicByte(_) -> <<>>.

-spec knowledgeDir() -> file:filename().
knowledgeDir() ->
    filename:join(alConfig:dataDir(), "knowledge").

-spec loadMeta() -> {ok, map()} | undefined.
loadMeta() ->
    case readJson(filename:join(knowledgeDir(), "meta.json")) of
        {ok, Meta} when is_map(Meta) -> {ok, Meta};
        _ -> undefined
    end.

%%--------------------------------------------------------------------
%% @doc
%% 读取项目侧 agent 提示：`.ali/knowledge/agent.json`。
%% 业务实体词放这里（由 digest 从本项目表名/动作短语自动软合并维护），
%% 不要写死进通用助手代码。
%% 文件不存在或坏 JSON 时返回空 map。
%% @end
%%--------------------------------------------------------------------
-spec agentHints() -> map().
agentHints() ->
    case readJson(filename:join(knowledgeDir(), "agent.json")) of
        {ok, Map} when is_map(Map) -> normalizeAgentHints(Map);
        _ -> #{}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 读取项目侧 agent.json 的别名/同义词映射：
%%  - key：自然语言 token（建议小写/中文直接写原词）
%%  - value：该 token 可扩展到的其它 token 列表（用于检索召回）
%%
%% 兼容 key 为 `aliases` 或 `synonyms`，值兼容 string/list/binary。
%% @end
%%--------------------------------------------------------------------
-spec agentAliases() -> map().
agentAliases() ->
    case readJson(filename:join(knowledgeDir(), "agent.json")) of
        {ok, Map} when is_map(Map) -> normalizeAgentAliases(Map);
        _ -> #{}
    end.

-spec normalizeAgentAliases(map()) -> map().
normalizeAgentAliases(Map) when is_map(Map) ->
    RawAliases = maps:get(<<"aliases">>, Map, maps:get(<<"synonyms">>, Map, #{})),
    case RawAliases of
        M when is_map(M) ->
            maps:fold(fun(K, V, Acc0) ->
                Key0 = lowerBin(toBinary(K)),
                Vs = case V of
                    L when is_list(L) -> L;
                    Bin when is_binary(Bin) -> [Bin];
                    A when is_atom(A) -> [A];
                    I when is_integer(I) -> [I];
                    _ -> []
                end,
                ValTokens = [lowerBin(toBinary(X))
                              || X <- ensureList(Vs), toBinary(X) =/= <<>>],
                case ValTokens of
                    [] -> Acc0;
                    _ -> Acc0#{Key0 => lists:usort(ValTokens)}
                end
            end, #{}, M);
        _ ->
            #{}
    end;
normalizeAgentAliases(_) ->
    #{}.

-spec expandTokensWithAliases([binary()], map()) -> [binary()].
expandTokensWithAliases(Tokens, Aliases) when is_list(Tokens), is_map(Aliases) ->
    Expanded = lists:flatmap(fun(T) ->
        case toBinary(T) of
            <<>> -> [];
            T0 ->
                TKey = lowerBin(T0),
                case maps:get(TKey, Aliases, undefined) of
                    undefined -> [T0];
                    Vs -> [T0] ++ ensureList(Vs)
                end
        end
    end, Tokens),
    [toBinary(X) || X <- lists:usort([toBinary(E) || E <- Expanded, toBinary(E) =/= <<>>])];
expandTokensWithAliases(_, _) -> [].

lowerBin(Bin) ->
    Bin0 = toBinary(Bin),
    %% 兼容源码文件非 UTF-8 字面量导致的 bad utf8：
    %% 失败则直接返回原始二进制（仍能完成 substring 匹配）。
    try
        unicode:characters_to_binary(
            string:lowercase(unicode:characters_to_list(Bin0)))
    catch
        _:_ -> Bin0
    end.

%%--------------------------------------------------------------------
%% @doc 从 moduleDoc 中提取显式别名标记：
%%   - `@alias 主城`：把该别名映射到当前模块（module）
%%   - `@alias 主城=castle`：把别名映射到指定目标模块名（castle）
%%   - `@aliases 城堡,主城`：多个别名都映射到当前模块
%%
%% 注意：只提取“显式标记”，避免用启发式抽取导致噪声。
%% @end
%%--------------------------------------------------------------------
-spec extractAliasesFromModuleDoc(binary(), atom()) -> map().
extractAliasesFromModuleDoc(Doc, CurrentModule) when is_binary(Doc), is_atom(CurrentModule) ->
    Lines = binary:split(Doc, <<"\n">>, [global]),
    DefaultTarget = lowerBin(toBinary(CurrentModule)),
    lists:foldl(fun(Line, Acc0) ->
        Trim = trimAsciiLine(Line),
        case isAliasLine(Trim) of
            {alias, Spec} ->
                mergeAliasMaps(Acc0, aliasSpecToMap(Spec, DefaultTarget));
            {aliases, Rest} ->
                Parts = splitAliasParts(Rest),
                foldAliasParts(Parts, DefaultTarget, Acc0);
            _ ->
                Acc0
        end
    end, #{}, Lines);
extractAliasesFromModuleDoc(_, _) ->
    #{}.

isAliasLine(Trim) ->
    case binary:match(Trim, <<"@alias">>) of
        {0, _Len} ->
            PrefixLen = byte_size(<<"@alias">>),
            Rest = trimAsciiLine(binary:part(Trim, PrefixLen, byte_size(Trim) - PrefixLen)),
            if Rest =:= <<>> -> false; true -> {alias, Rest} end;
        _ ->
            case binary:match(Trim, <<"@aliases">>) of
                {0, _Len2} ->
                    PrefixLen2 = byte_size(<<"@aliases">>),
                    Rest2 = trimAsciiLine(binary:part(Trim, PrefixLen2, byte_size(Trim) - PrefixLen2)),
                    if Rest2 =:= <<>> -> false; true -> {aliases, Rest2} end;
                _ -> false
            end
    end.

splitAliasParts(Rest) ->
    %% 支持逗号/中文逗号/空白分隔
    R0 = binary:replace(Rest, <<"，"/utf8>>, <<",">>, [global]),
    R1 = binary:replace(R0, <<" ">>, <<",">>, [global]),
    R2 = binary:replace(R1, <<"\t">>, <<",">>, [global]),
    Parts0 = binary:split(R2, <<",">>, [global]),
    [trimAsciiLine(P) || P <- Parts0, trimAsciiLine(P) =/= <<>>].

foldAliasParts([], _DefaultTarget, Acc) -> Acc;
foldAliasParts([P | Rest], DefaultTarget, Acc0) ->
    T = lowerBin(toBinary(P)),
    if T =:= <<>> ->
        foldAliasParts(Rest, DefaultTarget, Acc0);
       true ->
        mergeAliasMaps(Acc0, #{T => [DefaultTarget]})
    end.

aliasSpecToMap(Spec, DefaultTarget) ->
    S0 = trimAsciiLine(Spec),
    case binary:match(S0, <<"=">>) of
        nomatch ->
            A = lowerBin(S0),
            if A =:= <<>> -> #{}; true -> #{A => [DefaultTarget]} end;
        {Pos, 1} ->
            Alias = binary:part(S0, 0, Pos),
            Target = binary:part(S0, Pos + 1, byte_size(S0) - (Pos + 1)),
            A = lowerBin(trimAsciiLine(Alias)),
            T = lowerBin(trimAsciiLine(Target)),
            if A =:= <<>> orelse T =:= <<>> -> #{}; true -> #{A => [T]} end
    end.

trimAsciiLine(Bin) when is_binary(Bin) ->
    trimAsciiLeading(trimAsciiTrailing(Bin));
trimAsciiLine(_) ->
    <<>>.

trimAsciiLeading(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t ->
    trimAsciiLeading(Rest);
trimAsciiLeading(Bin) ->
    Bin.

trimAsciiTrailing(Bin) ->
    case Bin of
        <<>> -> <<>>;
        _ ->
    case binary:last(Bin) of
        C when C =:= $\s; C =:= $\t -> trimAsciiTrailing(binary:part(Bin, 0, byte_size(Bin) - 1));
        _ -> Bin
    end
    end.

%%--------------------------------------------------------------------
%% @doc 聚合整个项目模块上下文里的别名标记
%% @end
%%--------------------------------------------------------------------
-spec autoAliasesFromModuleContexts(map()) -> map().
autoAliasesFromModuleContexts(ModuleContexts) when is_map(ModuleContexts) ->
    maps:fold(fun(_Mod, Ctx, Acc0) ->
        Doc = maps:get(moduleDoc, Ctx, <<>>),
        ModAtom = maps:get(module, Ctx, undefined),
        case is_atom(ModAtom) andalso is_binary(Doc) of
            true ->
                mergeAliasMaps(Acc0, extractAliasesFromModuleDoc(Doc, ModAtom));
            false -> Acc0
        end
    end, #{}, ModuleContexts);
autoAliasesFromModuleContexts(_) ->
    #{}.

%%--------------------------------------------------------------------
%% @doc 扫描所有待索引模块（而不是仅温启动模块），从源文件
%% `moduleDoc` 中抽取显式 aliases，避免导出少的模块被漏掉。
%% @end
%%--------------------------------------------------------------------
-spec autoAliasesFromModules([atom()], map()) -> map().
autoAliasesFromModules(Mods, ModByAtom) when is_list(Mods), is_map(ModByAtom) ->
    lists:foldl(fun(Mod, Acc0) ->
        Info = maps:get(Mod, ModByAtom, #{file => <<>>}),
        File = maps:get(file, Info, <<>>),
        Src = readSourceFile(File),
        Doc = extractModuleDocFromErl(Src),
        mergeAliasMaps(Acc0, extractAliasesFromModuleDoc(Doc, Mod))
    end, #{}, Mods);
autoAliasesFromModules(_, _) ->
    #{}.

%%--------------------------------------------------------------------
%% @doc 合并 aliases map：value 列表做并集去重
%% @end
%%--------------------------------------------------------------------
-spec mergeAliasMaps(map(), map()) -> map().
mergeAliasMaps(A1, A2) when is_map(A1), is_map(A2) ->
    maps:fold(fun(K, V, Acc0) ->
        V1 = maps:get(K, Acc0, []),
        V2 = lists:usort(ensureList(V1) ++ ensureList(V)),
        Acc0#{K => V2}
    end, A1, A2);
mergeAliasMaps(_, _) ->
    #{}.

%% @doc 项目活数据实体关键词（来自 agent.json liveDataKeywords）。
-spec liveDataKeywords() -> [string()].
liveDataKeywords() ->
    maps:get(liveDataKeywords, agentHints(), []).

%% @doc 项目活数据操作关键词（来自 agent.json liveDataOpKeywords）。
-spec liveDataOpKeywords() -> [string()].
liveDataOpKeywords() ->
    maps:get(liveDataOpKeywords, agentHints(), []).

normalizeAgentHints(Map) when is_map(Map) ->
    #{
        liveDataKeywords => hintKeywordList(Map, liveDataKeywords, <<"liveDataKeywords">>),
        liveDataOpKeywords => hintKeywordList(Map, liveDataOpKeywords, <<"liveDataOpKeywords">>),
        aliases => normalizeAgentAliases(Map)
    }.

hintKeywordList(Map, AtomKey, BinKey) ->
    Raw = case maps:find(AtomKey, Map) of
        {ok, V} -> V;
        error -> maps:get(BinKey, Map, [])
    end,
    [string:lowercase(unicode:characters_to_list(toBinary(K)))
     || K <- ensureList(Raw), isUsableHintToken(K)].

%% 过滤宏名（?FOO）、空串、过短词，避免污染 isRuntimeQuestion 正则。
isUsableHintToken(K) ->
    B = toBinary(K),
    case B of
        <<>> -> false;
        <<$?, _/binary>> -> false;
        _ -> byte_size(B) >= 2
    end.

writeAgentHints(Dir, Hints) when is_map(Hints) ->
    Payload = #{
        liveDataKeywords => [unicode:characters_to_binary(K)
                             || K <- maps:get(liveDataKeywords, Hints, [])],
        liveDataOpKeywords => [unicode:characters_to_binary(K)
                              || K <- maps:get(liveDataOpKeywords, Hints, [])],
        aliases => maps:get(aliases, Hints, #{}),
        updatedAt => erlang:system_time(second),
        note => <<"auto-merged by projectDigest; manual keywords are preserved"/utf8>>
    },
    writeJsonAtomic(filename:join(Dir, "agent.json"), Payload).

%%--------------------------------------------------------------------
%% @doc
%% 从 data 表名 + actions 短语启发式生成 agent 关键词候选（项目相关，非通用硬编码）。
%% @end
%%--------------------------------------------------------------------
-spec seedAgentHints(map(), [map()]) -> map().
seedAgentHints(Data, Actions) when is_map(Data), is_list(Actions) ->
    FromTables = lists:flatmap(fun(Tab) -> tableNameTokens(Tab) end,
                               maps:keys(maps:get(tables, Data, #{}))),
    {EntFromAct, OpFromAct} = lists:foldl(fun(A, {EntAcc, OpAcc}) ->
        Phrase = maps:get(phrase, normalizeAction(A), <<>>),
        case phraseKeyword(Phrase) of
            {entity, K} -> {[K | EntAcc], OpAcc};
            {op, K} -> {EntAcc, [K | OpAcc]};
            none -> {EntAcc, OpAcc}
        end
    end, {[], []}, Actions),
    #{
        liveDataKeywords => uniqStrings(FromTables ++ EntFromAct),
        liveDataOpKeywords => uniqStrings(OpFromAct)
    };
seedAgentHints(_, _) ->
    #{liveDataKeywords => [], liveDataOpKeywords => []}.

%%--------------------------------------------------------------------
%% @doc 合并 agent hints：Existing 优先，Seeded 只追加未见过的词。
%% @end
%%--------------------------------------------------------------------
-spec mergeAgentHints(map(), map()) -> map().
mergeAgentHints(Existing, Seeded) when is_map(Existing), is_map(Seeded) ->
    E1 = maps:get(liveDataKeywords, Existing, []),
    E2 = maps:get(liveDataOpKeywords, Existing, []),
    S1 = maps:get(liveDataKeywords, Seeded, []),
    S2 = maps:get(liveDataOpKeywords, Seeded, []),
    ExistingAliases = maps:get(aliases, Existing, #{}),
    SeededAliases = maps:get(aliases, Seeded, #{}),
    Aliases = mergeAliasMaps(ExistingAliases, SeededAliases),
    #{
        liveDataKeywords => uniqStrings(E1 ++ S1),
        liveDataOpKeywords => uniqStrings(E2 ++ S2),
        aliases => Aliases
    };
mergeAgentHints(_, Seeded) when is_map(Seeded) ->
    normalizeAgentHints(Seeded);
mergeAgentHints(Existing, _) when is_map(Existing) ->
    normalizeAgentHints(Existing);
mergeAgentHints(_, _) ->
    #{liveDataKeywords => [], liveDataOpKeywords => [], aliases => #{}}.

%%--------------------------------------------------------------------
%% @doc 剔除 source=auto 且 MFA 已不在 api exports 中的动作；manual 保留。
%% @end
%%--------------------------------------------------------------------
-spec pruneStaleActions([map()], [map()]) -> [map()].
pruneStaleActions(Actions, ApiEntries) when is_list(Actions), is_list(ApiEntries) ->
    ExportSet = exportMfaSet(ApiEntries),
    lists:filter(fun(A) ->
        NA = normalizeAction(A),
        Source = maps:get(source, NA, auto),
        case Source of
            manual -> true;
            <<"manual">> -> true;
            _ ->
                Mfa = maps:get(mfa, NA, <<>>),
                sets:is_element(mfaKey(Mfa), ExportSet)
        end
    end, Actions);
pruneStaleActions(Actions, _) ->
    Actions.

%% 表名 → 可读 token（去掉 _tab/_db/_ets/_table 等后缀，再按 _ 拆分）。
-spec tableNameTokens(term()) -> [string()].
tableNameTokens(Tab) ->
    S0 = string:lowercase(unicode:characters_to_list(toBinary(Tab))),
    %% 宏表名（?CACHE_TABLE）不当作业务实体词。
    case S0 of
        [$? | _] -> [];
        _ ->
            S1 = stripTableSuffix(S0),
            Parts = string:tokens(S1, "_."),
            [P || P <- Parts, length(P) >= 2, not lists:member(P, noiseTokens()),
                  hd(P) =/= $?]
    end.

stripTableSuffix(S) ->
    Suffixes = ["_table", "_tabs", "_tab", "_ets", "_db", "_data", "_store"],
    stripFirstSuffix(S, Suffixes).

stripFirstSuffix(S, []) -> S;
stripFirstSuffix(S, [Suf | Rest]) ->
    case lists:suffix(Suf, S) of
        true -> lists:sublist(S, length(S) - length(Suf));
        false -> stripFirstSuffix(S, Rest)
    end.

noiseTokens() ->
    ["tab", "tabs", "table", "ets", "db", "data", "store", "mgr", "lib",
     "server", "port", "sup", "app", "mod", "tmp", "old", "new"].

phraseKeyword(Phrase) when is_binary(Phrase) ->
    phraseKeyword(unicode:characters_to_list(Phrase));
phraseKeyword(Phrase) when is_list(Phrase) ->
    P = string:lowercase(string:trim(Phrase)),
    case P of
        [$查 | Rest] when length(Rest) >= 2 ->
            case usablePhraseToken(string:trim(Rest)) of
                true -> {entity, string:trim(Rest)};
                false -> none
            end;
        [$改 | Rest] when length(Rest) >= 2 ->
            case usablePhraseToken(P) of
                true -> {op, P};
                false -> none
            end;
        _ ->
            case string:prefix(P, "查询 ") of
                nomatch ->
                    case string:prefix(P, "调用 ") of
                        nomatch -> none;
                        Rest2 when length(Rest2) >= 2 ->
                            case usablePhraseToken(string:trim(Rest2)) of
                                true -> {op, string:trim(Rest2)};
                                false -> none
                            end;
                        _ -> none
                    end;
                Rest1 when length(Rest1) >= 2 ->
                    case usablePhraseToken(string:trim(Rest1)) of
                        true -> {entity, string:trim(Rest1)};
                        false -> none
                    end;
                _ -> none
            end
    end;
phraseKeyword(_) -> none.

%% MFA / 宏名不当作 NL 实体词（否则会进 agent.json 并炸 hasWholeWord）。
usablePhraseToken([]) -> false;
usablePhraseToken([$? | _]) -> false;
usablePhraseToken(T) when is_list(T) ->
    not lists:member($:, T);
usablePhraseToken(_) -> false.

uniqStrings(List) ->
    lists:usort([string:lowercase(unicode:characters_to_list(toBinary(X)))
                 || X <- List, toBinary(X) =/= <<>>]).

exportMfaSet(ApiEntries) ->
    sets:from_list(lists:flatmap(fun(E) ->
        Mod = maps:get(module, E, maps:get(<<"module">>, E, undefined)),
        Exports = maps:get(exports, E, maps:get(<<"exports">>, E, [])),
        case Mod of
            undefined -> [];
            _ ->
                [mfaKey(iolist_to_binary(io_lib:format("~s:~s/~w",
                    [toBinary(Mod),
                     toBinary(maps:get(name, Exp, maps:get(<<"name">>, Exp, <<>>))),
                     maps:get(arity, Exp, maps:get(<<"arity">>, Exp, 0))])))
                 || Exp <- ensureList(Exports)]
        end
    end, ApiEntries)).

mfaKey(Mfa) ->
    unicode:characters_to_binary(
        string:lowercase(unicode:characters_to_list(toBinary(Mfa)))).

-spec defaultOpts() -> map().
defaultOpts() ->
    #{
        maxModules => ?DefaultMaxModules,
        maxSummaryWarm => ?DefaultMaxSummaryWarm,
        warmLlm => false,
        force => false,
        updateAgentHints => true,
        pruneStaleActions => true,
        seedExperience => true,
        maxExperienceSeeds => 40
    }.

%% digest 构建后预学习：actions / 表 MFA / OTP behaviour → lesson
maybeSeedExperience(Opts, Actions, Data, ModuleContexts) ->
    case maps:get(seedExperience, Opts, true) of
        false ->
            #{seeded => 0, skipped => true};
        _ ->
            try
                Max = maps:get(maxExperienceSeeds, Opts, 40),
                case alExperience:seedFromDigest(#{
                    actions => Actions,
                    data => Data,
                    moduleContexts => ModuleContexts
                }, #{maxSeeds => Max}) of
                    {ok, Info} when is_map(Info) ->
                        logger:info("alProjectDigest: experience seed ~p", [Info]),
                        Info;
                    {error, ErrReason} ->
                        logger:warning("alProjectDigest: experience seed failed: ~p", [ErrReason]),
                        #{seeded => 0, error => ErrReason}
                end
            catch
                Class:CrashReason:Stack ->
                    logger:warning("alProjectDigest: experience seed crash ~p:~p ~p",
                                   [Class, CrashReason, lists:sublist(Stack, 4)]),
                    #{seeded => 0, error => {Class, CrashReason}}
            end
    end.

%% 默认全量；仅当显式传入正整数 maxModules 时截断（单测/调试用）。
takeModules(Modules, unlimited) -> Modules;
takeModules(Modules, all) -> Modules;
takeModules(Modules, Max) when is_integer(Max), Max > 0 ->
    lists:sublist(Modules, Max);
takeModules(Modules, _) ->
    Modules.

eraseDigestCache() ->
    lists:foreach(fun
        ({{digest_idx, _} = K, _}) -> erase(K);
        ({{digest_deps, _} = K, _}) -> erase(K);
        (_) -> ok
    end, get()).

countBuckets(Modules) ->
    lists:foldl(fun(M, Acc) ->
        B = maps:get(bucket, M, core),
        maps:update_with(B, fun(N) -> N + 1 end, 1, Acc)
    end, #{}, Modules).

%% 模块分桶：默认检索应对 cfg/test/gm 降权。
-spec classifyModuleBucket(term(), term()) -> core | cfg | test | gm.
classifyModuleBucket(Mod, File) ->
    Name = string:lowercase(atom_to_list(toAtom(Mod))),
    Path = string:lowercase(unicode:characters_to_list(toBinary(File))),
    case isTestBucket(Name, Path) of
        true -> test;
        false ->
            case isGmBucket(Name, Path) of
                true -> gm;
                false ->
                    case isCfgBucket(Name, Path) of
                        true -> cfg;
                        false -> core
                    end
            end
    end.

isTestBucket(Name, Path) ->
    lists:prefix("test_", Name)
        orelse lists:suffix("_tests", Name)
        orelse lists:suffix("_SUITE", Name)
        orelse lists:suffix("_suite", Name)
        orelse pathHasSeg(Path, "test")
        orelse pathHasSeg(Path, "tests")
        orelse pathHasSeg(Path, "eunit").

isGmBucket(Name, Path) ->
    lists:prefix("gm_", Name)
        orelse lists:suffix("_gm", Name)
        orelse pathHasSeg(Path, "gm").

isCfgBucket(Name, Path) ->
    lists:suffix("_pb_cfg", Name)
        orelse lists:suffix("_cfg", Name)
        orelse lists:suffix("_config", Name)
        orelse lists:prefix("cfg_", Name)
        orelse pathHasSeg(Path, "config")
        orelse pathHasSeg(Path, "cfg").

pathHasSeg(Path, Seg) ->
    Parts = filename:split(Path),
    lists:member(Seg, Parts).

%%%===================================================================
%%% Build helpers
%%%===================================================================

projectRoot() ->
    try alConfig:projectRoot() catch _:_ -> "." end.

%% 扫描 projectRoot 下 .erl，解析 -module(Name).
discoverModules(Root) ->
    Files = listErlFiles(Root),
    Mods = lists:foldl(fun(Path, Acc) ->
        case moduleFromPath(Path) of
            undefined -> Acc;
            Mod ->
                Rel = safeRelPath(Root, Path),
                [#{module => Mod, file => Rel} | Acc]
        end
    end, [], Files),
    %% 去重：同名模块保留第一条
    [M || {_K, M} <- lists:ukeysort(1, [{maps:get(module, M), M} || M <- Mods])].

listErlFiles(Root) ->
    case filelib:is_dir(Root) of
        false -> [];
        true ->
            filelib:fold_files(
                Root,
                "\\.erl$",
                true,
                fun(F, Acc) ->
                    case shouldSkipPath(F) of
                        true -> Acc;
                        false -> [F | Acc]
                    end
                end,
                []
            )
    end.

shouldSkipPath(Path) ->
    Root = projectRoot(),
    Rel = normalizeRelSlashes(safeRelPath(Root, Path)),
    case matchesIndexIgnore(Rel) of
        true -> true;
        false ->
            %% 单测模块默认仍跳过（即使未写进 indexIgnore）
            Base = filename:basename(pathToStr(Path), ".erl"),
            lists:suffix("_tests", Base) orelse lists:suffix("_SUITE", Base)
    end.

%% 与索引共用 core.indexIgnore（aliCfg.cfg → alConfig:indexIgnoreNames/0）。
matchesIndexIgnore(RelNorm) ->
    Patterns = try alConfig:indexIgnoreNames() catch _:_ -> [] end,
    lists:any(fun(Pat) -> ignorePatternMatches(Pat, RelNorm) end, Patterns).

%% 与 aliCore `ignore.rs::pattern_matches` 对齐：相对路径、`/` 分隔、支持 `*_pb.erl`。
-spec ignorePatternMatches(term(), term()) -> boolean().
ignorePatternMatches(Pat0, Rel0) ->
    Pat = string:lowercase(string:trim(pathToStr(Pat0))),
    Rel = string:lowercase(normalizeRelSlashes(pathToStr(Rel0))),
    Pat1 = string:trim(Pat, trailing, "/"),
    case Pat1 of
        "" ->
            false;
        [$* | Rest] ->
            Suffix = string:trim(Rest, trailing, "*"),
            case Suffix of
                "" -> true;
                _ -> lists:suffix(Suffix, Rel)
            end;
        _ ->
            case lists:suffix("*", Pat1) of
                true ->
                    Prefix = lists:droplast(Pat1),
                    lists:prefix(Prefix, Rel)
                        orelse prefixAtSlashBoundary(Rel, Prefix);
                false ->
                    case lists:member($*, Pat1) of
                        true ->
                            {Head, Tail0} = splitOnceStar(Pat1),
                            Tail = string:trim(Tail0, trailing, "*"),
                            lists:prefix(Head, Rel) andalso lists:suffix(Tail, Rel);
                        false ->
                            containsPathSegment(Rel, Pat1)
                    end
            end
    end.

normalizeRelSlashes(Path) ->
    binary_to_list(binary:replace(
        unicode:characters_to_binary(pathToStr(Path)),
        <<"\\">>, <<"/">>, [global])).

pathToStr(B) when is_binary(B) -> unicode:characters_to_list(B);
pathToStr(L) when is_list(L) -> L;
pathToStr(A) when is_atom(A) -> atom_to_list(A);
pathToStr(X) -> unicode:characters_to_list(toBinary(X)).

%% 边界前缀匹配（对齐 Rust match_indices + '/' 前界）。
prefixAtSlashBoundary(Rel, Prefix) ->
    prefixAtSlashBoundary1(Rel, Prefix, 0).

prefixAtSlashBoundary1(Rel, Prefix, Off) ->
    case findSubstr(Rel, Prefix, Off) of
        nomatch -> false;
        Idx ->
            %% Idx 为 0-based；前一字符的 1-based 下标是 Idx
            BeforeOk = (Idx =:= 0) orelse (lists:nth(Idx, Rel) =:= $/),
            case BeforeOk of
                true -> true;
                false -> prefixAtSlashBoundary1(Rel, Prefix, Idx + 1)
            end
    end.

findSubstr(Hay, _Needle, Off) when Off > length(Hay) -> nomatch;
findSubstr(Hay, Needle, Off) ->
    Tail = lists:nthtail(Off, Hay),
    case lists:prefix(Needle, Tail) of
        true -> Off;
        false ->
            case Tail of
                [] -> nomatch;
                _ -> findSubstr(Hay, Needle, Off + 1)
            end
    end.

splitOnceStar(Pat) ->
    {Head, [$* | Tail]} = lists:splitwith(fun(C) -> C =/= $* end, Pat),
    {Head, Tail}.

containsPathSegment(Rel, Pat) ->
    Rel =:= Pat
        orelse lists:prefix(Pat ++ "/", Rel)
        orelse lists:suffix("/" ++ Pat, Rel)
        orelse (findSubstr(Rel, "/" ++ Pat ++ "/", 0) =/= nomatch).

moduleFromPath(Path) ->
    case file:open(Path, [read, raw, binary, {read_ahead, 4096}]) of
        {ok, Fd} ->
            try
                scanModuleAttr(Fd, 32)
            after
                file:close(Fd)
            end;
        _ ->
            %% fallback: filename
            Base = filename:basename(Path, ".erl"),
            identAtom(Base)
    end.

scanModuleAttr(_Fd, 0) -> undefined;
scanModuleAttr(Fd, N) ->
    case file:read_line(Fd) of
        {ok, Line} ->
            case re:run(Line, <<"-module\\(([A-Za-z_][A-Za-z0-9_]*)\\)">>,
                        [{capture, [1], list}]) of
                {match, [Name]} ->
                    identAtom(Name);
                nomatch ->
                    scanModuleAttr(Fd, N - 1)
            end;
        eof -> undefined;
        _ -> undefined
    end.

buildApiEntries(Modules) ->
    lists:filtermap(fun(#{module := Mod} = Info) ->
        case fetchModuleIndex(Mod) of
            {ok, Idx} ->
                Exports = maps:get(exports, Idx, []),
                {true, Info#{
                    exports => Exports,
                    exportCount => length(Exports),
                    behaviours => maps:get(behaviours, Idx, []),
                    callbackCount => length(maps:get(callbacks, Idx, [])),
                    specCount => length(maps:get(specs, Idx, [])),
                    bucket => maps:get(bucket, Info, classifyModuleBucket(Mod, maps:get(file, Info, <<>>)))
                }};
            _ ->
                {true, Info#{exports => [], exportCount => 0,
                             behaviours => [], callbackCount => 0, specCount => 0,
                             bucket => maps:get(bucket, Info, core)}}
        end
    end, Modules).

stripApiInternal(Entries) ->
    [maps:without([index], E) || E <- Entries, is_map(E)].

fetchModuleIndex(Mod) ->
    case get({digest_idx, Mod}) of
        {ok, Idx} when is_map(Idx) ->
            {ok, Idx};
        _ ->
            Idx = loadModuleIndex(Mod),
            put({digest_idx, Mod}, {ok, Idx}),
            {ok, Idx}
    end.

loadModuleIndex(Mod) ->
    case alCoreClient:available() of
        true ->
            case alCoreClient:unwrap(alCoreClient:moduleSymbols(Mod)) of
                {ok, Result} when is_map(Result) ->
                    parseModuleIndexDoc(Result);
                _ ->
                    beamIndexFallback(Mod)
            end;
        false ->
            beamIndexFallback(Mod)
    end.

parseModuleIndexDoc(Result) ->
    Data0 = alCoreClient:unwrapMap(Result),
    Data = if is_map(Data0) -> Data0; true -> #{} end,
    Doc0 = maps:get(document, Data, maps:get(<<"document">>, Data, #{})),
    Doc = if is_map(Doc0) -> Doc0; true -> #{} end,
    Exports = extractExportsSafe(Result),
    #{
        exports => Exports,
        behaviours => normalizeNameList(maps:get(behaviours, Doc,
            maps:get(<<"behaviours">>, Doc, []))),
        callbacks => normalizeCallbackList(maps:get(callbacks, Doc,
            maps:get(<<"callbacks">>, Doc, []))),
        specs => normalizeSpecList(maps:get(specs, Doc,
            maps:get(<<"specs">>, Doc, []))),
        tech_debt => normalizeTechDebtList(maps:get(tech_debt, Doc,
            maps:get(<<"tech_debt">>, Doc, [])))
    }.

beamIndexFallback(Mod) ->
    Exports = case beamExports(Mod) of
        {ok, L} -> L;
        _ -> []
    end,
    #{exports => Exports, behaviours => [], callbacks => [],
      specs => [], tech_debt => []}.

normalizeNameList(List) when is_list(List) ->
    [toBinary(N) || N <- List, toBinary(N) =/= <<>>];
normalizeNameList(_) -> [].

normalizeCallbackList(List) when is_list(List) ->
    lists:filtermap(fun
        (C) when is_map(C) ->
            Name = maps:get(name, C, maps:get(<<"name">>, C, undefined)),
            Arity = maps:get(arity, C, maps:get(<<"arity">>, C, undefined)),
            case Name =/= undefined of
                true -> {true, #{
                    name => toBinary(Name),
                    arity => case Arity of A when is_integer(A) -> A; _ -> 0 end
                }};
                false -> false
            end;
        (_) -> false
    end, List);
normalizeCallbackList(_) -> [].

normalizeSpecList(List) when is_list(List) ->
    lists:filtermap(fun
        (S) when is_map(S) ->
            Name = maps:get(name, S, maps:get(<<"name">>, S, undefined)),
            Arity = maps:get(arity, S, maps:get(<<"arity">>, S, undefined)),
            case Name =/= undefined of
                true -> {true, #{
                    name => toBinary(Name),
                    arity => case Arity of A when is_integer(A) -> A; _ -> 0 end
                }};
                false -> false
            end;
        (_) -> false
    end, List);
normalizeSpecList(_) -> [].

normalizeTechDebtList(List) when is_list(List) ->
    lists:filtermap(fun
        (T) when is_map(T) ->
            Line = maps:get(line, T, maps:get(<<"line">>, T, undefined)),
            Text = maps:get(text, T, maps:get(<<"text">>, T, <<>>)),
            case Line =/= undefined andalso toBinary(Text) =/= <<>> of
                true ->
                    {true, #{line => Line, text => toBinary(Text)}};
                false ->
                    false
            end;
        (_) -> false
    end, List);
normalizeTechDebtList(_) -> [].

extractExportsSafe(Result) ->
    try extractExports(Result) catch _:_ -> [] end.

extractExports(Result) ->
    Data0 = alCoreClient:unwrapMap(Result),
    Data = if is_map(Data0) -> Data0; true -> #{} end,
    Doc0 = maps:get(document, Data, maps:get(<<"document">>, Data, #{})),
    Doc = if is_map(Doc0) -> Doc0; true -> #{} end,
    Raw = maps:get(exports, Doc,
        maps:get(<<"exports">>, Doc,
            maps:get(exports, Data, maps:get(<<"exports">>, Data, [])))),
    Funs = maps:get(functions, Doc,
        maps:get(<<"functions">>, Doc,
            maps:get(functions, Data, maps:get(<<"functions">>, Data, [])))),
    correctExportArities(normalizeExports(Raw), Funs).

-spec normalizeExports(term()) -> [map()].
normalizeExports(List) when is_list(List) ->
    lists:filtermap(fun(Item) ->
        case exportItem(Item) of
            undefined -> false;
            Exp -> {true, Exp}
        end
    end, List);
normalizeExports(_) -> [].

exportItem(#{name := N, arity := A}) ->
    exportItemNameArity(N, A);
exportItem(#{<<"name">> := N, <<"arity">> := A}) ->
    exportItemNameArity(N, A);
exportItem(#{name := N}) ->
    exportItemNameArity(N, 0);
exportItem(#{<<"name">> := N}) ->
    exportItemNameArity(N, 0);
exportItem({N, A}) ->
    exportItemNameArity(N, A);
exportItem(Bin) when is_binary(Bin) ->
    case re:run(Bin, <<"^([A-Za-z_][\\w]*)\\/(\\d+)$">>,
                [{capture, all_but_first, binary}]) of
        {match, [N, ABin]} ->
            exportItemNameArity(N, binary_to_integer(ABin));
        nomatch -> undefined
    end;
exportItem(_) -> undefined.

exportItemNameArity(N, A) ->
    case {toBinary(N), parseArity(A)} of
        {<<>>, _} -> undefined;
        {Name, Arity} when is_integer(Arity), Arity >= 0 ->
            #{name => Name, arity => Arity};
        _ -> undefined
    end.

parseArity(A) when is_integer(A), A >= 0 -> A;
parseArity(A) when is_float(A), A >= 0 -> trunc(A);
parseArity(A) when is_binary(A) ->
    try binary_to_integer(A) catch _:_ -> undefined end;
parseArity(A) when is_list(A) ->
    try list_to_integer(A) catch _:_ -> undefined end;
parseArity(_) -> undefined.

%% 用 document.functions 纠偏 exports 里错误的 arity=0。
-spec correctExportArities([map()], term()) -> [map()].
correctExportArities(Exports, Funs) when is_list(Exports) ->
    ByName = functionAritiesByName(Funs),
    lists:flatmap(fun(#{name := N, arity := A} = E) ->
        case A > 0 of
            true -> [E];
            false ->
                case maps:get(N, ByName, []) of
                    [] -> [E];
                    [One] -> [E#{arity => One}];
                    Many ->
                        %% 同名多 arity：展开为多条真实 export
                        [E#{arity => X} || X <- lists:usort(Many)]
                end
        end
    end, Exports);
correctExportArities(Exports, _) ->
    Exports.

functionAritiesByName(Funs) when is_list(Funs) ->
    lists:foldl(fun(F, Acc) when is_map(F) ->
        Name = toBinary(maps:get(name, F, maps:get(<<"name">>, F,
            maps:get(function, F, maps:get(<<"function">>, F, <<>>))))),
        Arity = parseArity(maps:get(arity, F, maps:get(<<"arity">>, F,
            maps:get(a, F, maps:get(<<"a">>, F, undefined))))),
        case Name =/= <<>> andalso is_integer(Arity) andalso Arity > 0 of
            true ->
                maps:update_with(Name, fun(L) -> [Arity | L] end, [Arity], Acc);
            false -> Acc
        end;
        (_, Acc) -> Acc
    end, #{}, Funs);
functionAritiesByName(_) -> #{}.

beamExports(Mod) ->
    try
        case code:which(Mod) of
            non_existing -> {ok, []};
            _ ->
                Exp = Mod:module_info(exports),
                {ok, [#{name => toBinary(N), arity => A}
                      || {N, A} <- Exp, N =/= module_info]}
        end
    catch _:_ ->
        {ok, []}
    end.

sortByExportCount(Entries) ->
    lists:sort(fun(#{exportCount := A}, #{exportCount := B}) -> A >= B end, Entries).

buildModuleContexts(Dir, Mods, ModByAtom, WarmLlm, WarmSet, Force) ->
    {Ctx, Written, Skipped} = lists:foldl(fun(Mod, {Acc, W, S}) ->
        Info = maps:get(Mod, ModByAtom, #{module => Mod, file => <<>>}),
        File = maps:get(file, Info, <<>>),
        Bucket = maps:get(bucket, Info, classifyModuleBucket(Mod, File)),
        Abs = resolveSourcePath(File),
        Mtime = sourceMtime(Abs),
        case (not Force) andalso loadFreshModuleContext(Dir, Mod, Mtime) of
            {ok, OldCtx} ->
                {Acc#{Mod => OldCtx#{bucket => Bucket}}, W, S + 1};
            false ->
                {ok, Idx} = fetchModuleIndex(Mod),
                DoWarm = case WarmSet of
                    undefined -> WarmLlm;
                    #{} -> WarmLlm andalso maps:is_key(Mod, WarmSet)
                end,
                Ctx = buildModuleContext(Mod, File, Idx, DoWarm, Bucket, Abs, Mtime),
                {Acc#{Mod => Ctx}, W + 1, S}
        end
    end, {#{}, 0, 0}, Mods),
    {Ctx, #{written => Written, skipped => Skipped, force => Force}}.

safeModuleSummaryGet(Mod) ->
    try alModuleSummary:get(Mod) of
        {ok, S} -> {ok, S};
        undefined -> undefined;
        _ -> undefined
    catch
        _:_ -> undefined
    end.

buildModuleContext(Mod, File, Idx, WarmLlm, Bucket, AbsPath, Mtime) ->
    Summary = case safeModuleSummaryGet(Mod) of
        {ok, S} -> S;
        undefined ->
            case WarmLlm of
                true ->
                    alAsync:run({moduleSummaryWarm, Mod},
                        fun() -> alModuleSummary:generate(Mod) end);
                false -> ok
            end,
            alModuleSummary:fallbackSummary(Mod)
    end,
    SourceBin = readSourceAbs(AbsPath),
    ModuleDoc = extractModuleDocFromErl(SourceBin),
    Includes = extractIncludesFromErl(SourceBin),
    DocBriefs = briefsMapForJson(alDocGen:extractBriefsFromErl(SourceBin)),
    Deps = fetchModuleDeps(Mod),
    Behaviours0 = maps:get(behaviours, Idx, []),
    Behaviours = case Behaviours0 of
        [] -> extractBehavioursFromErl(SourceBin);
        _ -> Behaviours0
    end,
    Callbacks = maps:get(callbacks, Idx, []),
    TechDebt = maps:get(tech_debt, Idx, []),
    SpecCount = length(maps:get(specs, Idx, [])),
    SearchText = composeModuleSearchText(#{
        module => Mod,
        summary => Summary,
        moduleDoc => ModuleDoc,
        includes => Includes,
        behaviours => Behaviours,
        deps => Deps,
        docBriefs => DocBriefs,
        bucket => Bucket
    }),
    #{
        module => Mod,
        file => File,
        absFile => AbsPath,
        bucket => Bucket,
        sourceMtime => Mtime,
        builtAt => erlang:system_time(second),
        summary => Summary,
        searchText => SearchText,
        moduleDoc => ModuleDoc,
        includes => Includes,
        behaviours => Behaviours,
        callbacks => lists:sublist(Callbacks, 40),
        specCount => SpecCount,
        techDebt => lists:sublist(TechDebt, 20),
        deps => Deps,
        docBriefs => DocBriefs
    }.

%% 相对路径按 projectRoot 解析；绝对路径原样。旧实现用 CWD 读，游戏仓会整库空注释。
-spec resolveSourcePath(term()) -> binary().
resolveSourcePath(File) when is_binary(File), File =/= <<>> ->
    Path = unicode:characters_to_list(File),
    Abs = case filename:pathtype(Path) of
        absolute -> Path;
        _ ->
            Root = projectRoot(),
            filename:absname(filename:join(Root, Path))
    end,
    unicode:characters_to_binary(Abs);
resolveSourcePath(File) when is_list(File) ->
    resolveSourcePath(toBinary(File));
resolveSourcePath(_) ->
    <<>>.

readSourceFile(File) ->
    readSourceAbs(resolveSourcePath(File)).

readSourceAbs(Abs) when is_binary(Abs), Abs =/= <<>> ->
    case file:read_file(Abs) of
        {ok, Bin} -> Bin;
        _ -> <<>>
    end;
readSourceAbs(_) ->
    <<>>.

sourceMtime(Abs) when is_binary(Abs), Abs =/= <<>> ->
    case file:read_file_info(Abs) of
        {ok, #file_info{mtime = Mtime}} ->
            calendarDatetimeToEpoch(Mtime);
        _ -> 0
    end;
sourceMtime(_) -> 0.

calendarDatetimeToEpoch({{Y, Mo, D}, {H, Mi, S}})
  when is_integer(Y), is_integer(Mo), is_integer(D) ->
    try
        calendar:datetime_to_gregorian_seconds({{Y, Mo, D}, {H, Mi, S}})
            - 62167219200
    catch _:_ -> 0
    end;
calendarDatetimeToEpoch(_) -> 0.

loadFreshModuleContext(Dir, Mod, SourceMtime) when SourceMtime > 0 ->
    Name = atom_to_list(toAtom(Mod)) ++ ".json",
    Path = filename:join([Dir, "modules", Name]),
    case readJson(Path) of
        {ok, Map} when is_map(Map) ->
            Old = maps:get(sourceMtime, Map, maps:get(<<"sourceMtime">>, Map, 0)),
            OldN = case Old of
                N when is_integer(N) -> N;
                _ -> 0
            end,
            case OldN > 0 andalso OldN =:= SourceMtime of
                true -> {ok, atomizeModuleContext(Map)};
                false -> false
            end;
        _ -> false
    end;
loadFreshModuleContext(_, _, _) ->
    false.

atomizeModuleContext(Map) when is_map(Map) ->
    %% 增量复用时保留关键字段；键可能是 binary（json decode）
    #{
        module => maps:get(module, Map, maps:get(<<"module">>, Map, <<>>)),
        file => maps:get(file, Map, maps:get(<<"file">>, Map, <<>>)),
        absFile => maps:get(absFile, Map, maps:get(<<"absFile">>, Map, <<>>)),
        bucket => binaryToBucket(maps:get(bucket, Map, maps:get(<<"bucket">>, Map, core))),
        sourceMtime => maps:get(sourceMtime, Map, maps:get(<<"sourceMtime">>, Map, 0)),
        builtAt => maps:get(builtAt, Map, maps:get(<<"builtAt">>, Map, 0)),
        summary => maps:get(summary, Map, maps:get(<<"summary">>, Map, <<>>)),
        searchText => maps:get(searchText, Map, maps:get(<<"searchText">>, Map, <<>>)),
        moduleDoc => maps:get(moduleDoc, Map, maps:get(<<"moduleDoc">>, Map, <<>>)),
        includes => maps:get(includes, Map, maps:get(<<"includes">>, Map, [])),
        behaviours => maps:get(behaviours, Map, maps:get(<<"behaviours">>, Map, [])),
        callbacks => maps:get(callbacks, Map, maps:get(<<"callbacks">>, Map, [])),
        specCount => maps:get(specCount, Map, maps:get(<<"specCount">>, Map, 0)),
        techDebt => maps:get(techDebt, Map, maps:get(<<"techDebt">>, Map, [])),
        deps => maps:get(deps, Map, maps:get(<<"deps">>, Map, [])),
        docBriefs => maps:get(docBriefs, Map, maps:get(<<"docBriefs">>, Map, #{}))
    }.

binaryToBucket(core) -> core;
binaryToBucket(cfg) -> cfg;
binaryToBucket(test) -> test;
binaryToBucket(gm) -> gm;
binaryToBucket(<<"core">>) -> core;
binaryToBucket(<<"cfg">>) -> cfg;
binaryToBucket(<<"test">>) -> test;
binaryToBucket(<<"gm">>) -> gm;
binaryToBucket(_) -> core.

briefsMapForJson(Briefs) when is_map(Briefs) ->
    maps:from_list(lists:sublist(
        [{faKeyBin(K), toBinary(V)}
         || {K, V} <- maps:to_list(Briefs), toBinary(V) =/= <<>>],
        60));
briefsMapForJson(_) ->
    #{}.

faKeyBin({Name, Arity}) when is_integer(Arity) ->
    iolist_to_binary(io_lib:format("~s/~w", [toBinary(Name), Arity]));
faKeyBin(K) ->
    toBinary(K).

fetchModuleDeps(Mod) ->
    case get({digest_deps, Mod}) of
        L when is_list(L) -> L;
        _ ->
            L = fetchModuleDepsUncached(Mod),
            put({digest_deps, Mod}, L),
            L
    end.

fetchModuleDepsUncached(Mod) ->
    try
        case alCoreClient:available() of
            true ->
                case alCoreClient:unwrap(alCoreClient:moduleDeps(Mod)) of
                    {ok, Res} when is_map(Res) ->
                        Raw = maps:get(deps, Res, maps:get(<<"deps">>, Res, [])),
                        [toBinary(D) || D <- ensureList(Raw), toBinary(D) =/= <<>>];
                    _ -> []
                end;
            false -> []
        end
    catch _:_ ->
        []
    end.

buildDepsLayer(Modules) ->
    Items = [begin
        Mod = maps:get(module, M),
        File = maps:get(file, M, <<>>),
        #{
            module => toBinary(Mod),
            file => toBinary(File),
            deps => fetchModuleDeps(Mod)
        }
    end || M <- Modules],
    #{modules => Items}.

buildConfigLayer(Root) ->
    Patterns = [
        filename:join(Root, "config/aliCfg.cfg"),
        filename:join(Root, "config/aliCfg.cfg.example")
    ],
    Configs = lists:filtermap(fun(Path) ->
        case file:read_file(Path) of
            {ok, Bin} ->
                {true, #{
                    path => toBinary(Path),
                    keys => extractConfigKeys(Bin),
                    preview => configPreview(Bin)
                }};
            _ -> false
        end
    end, Patterns),
    #{configs => Configs}.

extractConfigKeys(Bin) when is_binary(Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global]),
    Keys = lists:filtermap(fun(Line) ->
        case matchConfigKeyLine(Line) of
            {ok, Key} -> {true, Key};
            _ -> false
        end
    end, Lines),
    lists:sublist(Keys, 120);
extractConfigKeys(_) ->
    [].

matchConfigKeyLine(Line) ->
    Trim = trimLine(Line),
    case Trim of
        <<"%", _/binary>> -> not_found;
        <<"%%", _/binary>> -> not_found;
        _ ->
            case re:run(Trim, <<"^\\{([a-zA-Z_][a-zA-Z0-9_]*)\\s*,">>,
                        [{capture, all_but_first, binary}]) of
                {match, [Key]} -> {ok, Key};
                nomatch ->
                    case re:run(Trim, <<"^([a-zA-Z_][a-zA-Z0-9_]*)\\s*=>">>,
                                [{capture, all_but_first, binary}]) of
                        {match, [Key2]} -> {ok, Key2};
                        nomatch -> not_found
                    end
            end
    end.

configPreview(Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global]),
    NonEmpty = [L || L <- Lines, trimLine(L) =/= <<>>],
    Preview = iolist_to_binary(lists:join(<<"\n">>,
        lists:sublist(NonEmpty, 40))),
    case byte_size(Preview) > 4000 of
        true -> truncateUtf8(Preview, 4000);
        false -> Preview
    end.

trimLine(Bin) ->
    string:trim(toBinary(Bin), leading, [$\s, $\t]).

-spec extractModuleDocFromErl(binary()) -> binary().
extractModuleDocFromErl(Bin) when is_binary(Bin), Bin =/= <<>> ->
    case extractModuledocAttr(Bin) of
        <<>> ->
            case extractDescriptionAttr(Bin) of
                <<>> -> extractHeaderCommentDoc(Bin);
                Desc -> Desc
            end;
        Doc -> Doc
    end;
extractModuleDocFromErl(_) ->
    <<>>.

extractModuledocAttr(Bin) ->
    case binary:match(Bin, <<"-moduledoc">>) of
        nomatch -> <<>>;
        _ ->
            case re:run(Bin,
                <<"-moduledoc\\s+\"([^\"]*)\"\\s*\\.">>,
                [{capture, all_but_first, binary}, unicode]) of
                {match, [Doc2]} -> trimDoc(Doc2);
                nomatch -> <<>>
            end
    end.

%% 游戏仓常见：-description("玩家城池").
extractDescriptionAttr(Bin) ->
    try
        case re:run(Bin,
                <<"-description\\s*\\(\\s*\"([^\"]*)\"\\s*\\)\\s*\\.">>,
                [{capture, all_but_first, binary}, unicode]) of
            {match, [Doc]} -> trimDoc(Doc);
            nomatch ->
                case re:run(Bin,
                        <<"-description\\s*\\(\\s*'([^']*)'\\s*\\)\\s*\\.">>,
                        [{capture, all_but_first, binary}, unicode]) of
                    {match, [Doc2]} -> trimDoc(Doc2);
                    nomatch -> <<>>
                end
        end
    catch
        _:_ -> <<>>
    end.

extractHeaderCommentDoc(Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global]),
    case extractAtDocBlock(Lines) of
        <<>> -> extractLeadingPercentComments(Lines);
        Block -> Block
    end.

extractAtDocBlock(Lines) ->
    extractAtDocBlock(Lines, [], false).

extractAtDocBlock([], Acc, _In) ->
    briefFromCommentLines(lists:reverse(Acc));
extractAtDocBlock([Line | Rest], Acc, In) ->
    Trim = trimLine(Line),
    case In of
        false ->
            case isAtDocStart(Trim) of
                true ->
                    Inline = atDocInline(Trim),
                    Acc0 = case Inline of <<>> -> []; _ -> [Inline] end,
                    extractAtDocBlock(Rest, Acc0, true);
                false ->
                    extractAtDocBlock(Rest, Acc, false)
            end;
        true ->
            case isAtDocEnd(Trim) of
                true -> briefFromCommentLines(lists:reverse(Acc));
                false ->
                    case Trim of
                        <<"-", _/binary>> ->
                            briefFromCommentLines(lists:reverse(Acc));
                        _ ->
                            case commentText(Trim) of
                                skip -> extractAtDocBlock(Rest, Acc, true);
                                <<>> -> extractAtDocBlock(Rest, Acc, true);
                                T -> extractAtDocBlock(Rest, [T | Acc], true)
                            end
                    end
            end
    end.

isAtDocStart(<<"%", "%", "%", Rest/binary>>) ->
    string:prefix(trimLine(Rest), <<"@doc">>) =/= nomatch;
isAtDocStart(<<"%%", Rest/binary>>) ->
    string:prefix(trimLine(Rest), <<"@doc">>) =/= nomatch;
isAtDocStart(Trim) ->
    string:prefix(trimLine(Trim), <<"@doc">>) =/= nomatch.

atDocInline(Trim) ->
    case re:run(Trim, <<"@doc\\s+(.*)">>, [{capture, all_but_first, binary}, unicode]) of
        {match, [T]} -> trimDoc(T);
        nomatch -> <<>>
    end.

isAtDocEnd(Trim) ->
    string:prefix(Trim, <<"% @end">>) =/= nomatch
        orelse string:prefix(Trim, <<"%% @end">>) =/= nomatch
        orelse string:prefix(Trim, <<"%%, @end">>) =/= nomatch.

extractLeadingPercentComments(Lines) ->
    extractLeadingPercentComments(Lines, []).

extractLeadingPercentComments([], Acc) ->
    briefFromCommentLines(lists:reverse(Acc));
extractLeadingPercentComments([Line | Rest], Acc) ->
    Trim = trimLine(Line),
    case Trim of
        <<>> ->
            extractLeadingPercentComments(Rest, Acc);
        <<"-", _/binary>> ->
            briefFromCommentLines(lists:reverse(Acc));
        <<"%", _/binary>> ->
            case commentText(Trim) of
                skip -> extractLeadingPercentComments(Rest, Acc);
                <<>> -> extractLeadingPercentComments(Rest, Acc);
                T -> extractLeadingPercentComments(Rest, [T | Acc])
            end;
        _ ->
            briefFromCommentLines(lists:reverse(Acc))
    end.

commentText(<<"%", "%", "%", Rest/binary>>) -> commentText(trimLine(Rest));
commentText(<<"%%", Rest/binary>>) -> commentText(trimLine(Rest));
commentText(Text) ->
    case string:prefix(Text, <<"@doc">>) of
        nomatch -> Text;
        _ -> skip
    end.

briefFromCommentLines(Lines) ->
    case Lines of
        [] -> <<>>;
        _ ->
            Bin = iolist_to_binary(lists:join(<<"\n">>, Lines)),
            trimDoc(Bin)
    end.

trimDoc(Bin) ->
    string:trim(toBinary(Bin), leading, [$\s, $\t, $\n, $\r]).

-spec extractIncludesFromErl(binary()) -> [binary()].
extractIncludesFromErl(Bin) when is_binary(Bin) ->
    Lib = extractIncludePattern(Bin, <<"-include_lib\\(\"([^\"]+)\"\\)">>)
        ++ extractIncludePattern(Bin, <<"-include_lib\\('([^']+)'\\)">>),
    Inc = extractIncludePattern(Bin, <<"-include\\(\"([^\"]+)\"\\)">>)
        ++ extractIncludePattern(Bin, <<"-include\\('([^']+)'\\)">>),
    uniqBin(Lib ++ Inc);
extractIncludesFromErl(_) ->
    [].

extractBehavioursFromErl(Bin) when is_binary(Bin), Bin =/= <<>> ->
    A = extractIncludePattern(Bin, <<"-behaviour\\(([A-Za-z_][\\w]*)\\)">>)
        ++ extractIncludePattern(Bin, <<"-behavior\\(([A-Za-z_][\\w]*)\\)">>),
    uniqBin(A);
extractBehavioursFromErl(_) ->
    [].

extractIncludePattern(Bin, Pat) ->
    case re:run(Bin, Pat, [global, {capture, all_but_first, binary}, unicode]) of
        {match, Matches} ->
            lists:flatmap(fun
                ([One]) when is_binary(One) -> [One];
                (One) when is_binary(One) -> [One];
                (_) -> []
            end, Matches);
        nomatch -> []
    end.

uniqBin(List) ->
    lists:foldl(fun(B, Acc) ->
        case lists:member(B, Acc) of
            true -> Acc;
            false -> [B | Acc]
        end
    end, [], List).

-spec composeModuleSearchText(map()) -> binary().
composeModuleSearchText(Ctx) when is_map(Ctx) ->
    Mod = maps:get(module, Ctx, <<>>),
    Summary = maps:get(summary, Ctx, <<>>),
    ModuleDoc = maps:get(moduleDoc, Ctx, <<>>),
    Includes = joinBinList(maps:get(includes, Ctx, [])),
    Behaviours = joinBinList(maps:get(behaviours, Ctx, [])),
    Deps = joinBinList(maps:get(deps, Ctx, [])),
    BriefText = briefsSearchText(maps:get(docBriefs, Ctx, #{})),
    Bucket = toBinary(maps:get(bucket, Ctx, core)),
    iolist_to_binary(lists:join(<<"\n">>, [
        toBinary(Mod), Bucket, toBinary(Summary), toBinary(ModuleDoc),
        Includes, Behaviours, Deps, BriefText
    ])).

joinBinList(List) ->
    iolist_to_binary(lists:join(<<", ">>,
        [toBinary(X) || X <- ensureList(List), toBinary(X) =/= <<>>])).

briefsSearchText(Briefs) when is_map(Briefs) ->
    Parts = [iolist_to_binary([K, <<": ">>, V])
             || {K, V} <- maps:to_list(Briefs)],
    iolist_to_binary(lists:join(<<"; ">>, lists:sublist(Parts, 24)));
briefsSearchText(_) ->
    <<>>.

buildMapEntries(ApiEntries, Contexts) ->
    [begin
         Mod = maps:get(module, E),
         Ctx = maps:get(Mod, Contexts, #{}),
         Summary = case maps:get(searchText, Ctx, undefined) of
             undefined -> fallbackMapSummary(E);
             ST -> ST
         end,
         #{
             module => toBinary(Mod),
             file => toBinary(maps:get(file, E, <<>>)),
             exportCount => maps:get(exportCount, E, 0),
             summary => Summary,
             bucket => maps:get(bucket, Ctx, maps:get(bucket, E, core)),
             behaviours => maps:get(behaviours, Ctx,
                 maps:get(behaviours, E, []))
         }
     end || E <- ApiEntries].

fallbackMapSummary(E) ->
    Mod = maps:get(module, E, <<>>),
    Beh = maps:get(behaviours, E, []),
    case Beh of
        [] ->
            iolist_to_binary([<<"Module ">>, toBinary(Mod), <<".">>]);
        _ ->
            iolist_to_binary([
                <<"Module ">>, toBinary(Mod),
                <<". behaviours: ">>, joinBinList(Beh), <<".">>
            ])
    end.

buildDataLayer() ->
    Sources = case alCoreClient:available() of
        true ->
            try
                case alCoreClient:dataSources() of
                    {ok, #{data := #{sources := Srcs}}} when is_list(Srcs) -> Srcs;
                    {ok, #{data := Data}} when is_map(Data) ->
                        maps:get(sources, Data, maps:get(<<"sources">>, Data, []));
                    {ok, #{<<"data">> := Data}} when is_map(Data) ->
                        maps:get(<<"sources">>, Data, []);
                    _ -> []
                end
            catch _:_ -> []
            end;
        false -> []
    end,
    #{tables => aggregateDataSources(Sources)}.

%% 聚合 dataSources → #{TableBin => [#{mfa, kind}]}
aggregateDataSources(Sources) when is_list(Sources) ->
    lists:foldl(fun(Src, Acc) ->
        Tab = toBinary(maps:get(table, Src, maps:get(<<"table">>, Src, <<>>))),
        case Tab of
            <<>> -> Acc;
            _ ->
                Mod = maps:get(caller_module, Src, maps:get(<<"caller_module">>, Src, undefined)),
                Fun = maps:get(caller_function, Src, maps:get(<<"caller_function">>, Src, <<>>)),
                Arity = maps:get(caller_arity, Src, maps:get(<<"caller_arity">>, Src, 0)),
                Kind0 = maps:get(source_type, Src,
                         maps:get(<<"source_type">>, Src,
                           maps:get(kind, Src, maps:get(<<"kind">>, Src,
                             <<"unknown">>)))),
                Kind = toBinary(Kind0),
                Line = maps:get(line, Src, maps:get(<<"line">>, Src, undefined)),
                Mfa = iolist_to_binary(io_lib:format("~s:~s/~w",
                    [toBinary(Mod), toBinary(Fun), Arity])),
                Entry0 = #{mfa => Mfa, kind => Kind},
                Entry = case Line of
                    L when is_integer(L) -> Entry0#{line => L};
                    _ -> Entry0
                end,
                maps:update_with(Tab, fun(L) ->
                    case lists:member(Entry, L) of
                        true -> L;
                        false -> [Entry | L]
                    end
                end, [Entry], Acc)
        end
    end, #{}, Sources);
aggregateDataSources(_) -> #{}.

loadOrInitActions(Dir, Data, ApiEntries) ->
    Existing = case readJson(filename:join(Dir, "actions.json")) of
        {ok, #{actions := List}} when is_list(List) -> List;
        {ok, #{<<"actions">> := List}} when is_list(List) -> List;
        _ -> []
    end,
    Seeded = seedActions(Data, ApiEntries),
    mergeActions(Existing, Seeded).

%%--------------------------------------------------------------------
%% @doc
%% 从 data 层 callers + api 导出名启发式生成 NL→MFA 动作种子。
%% 手工 actions 优先：merge 时同 phrase 保留 Existing。
%% @end
%%--------------------------------------------------------------------
seedActions(Data, ApiEntries) when is_map(Data), is_list(ApiEntries) ->
    FromTables = seedFromTables(maps:get(tables, Data, #{})),
    FromApi = seedFromApi(ApiEntries),
    dedupActions(FromTables ++ FromApi);
seedActions(_, _) -> [].

seedFromTables(Tables) when is_map(Tables) ->
    maps:fold(fun(Tab, Callers, Acc) ->
        TabBin = toBinary(Tab),
        lists:foldl(fun(Caller, Acc2) ->
            case actionFromCaller(TabBin, Caller) of
                undefined -> Acc2;
                Action -> [Action | Acc2]
            end
        end, Acc, ensureList(Callers))
    end, [], Tables);
seedFromTables(_) -> [].

actionFromCaller(Tab, Caller) when is_map(Caller) ->
    Mfa = maps:get(mfa, Caller, maps:get(<<"mfa">>, Caller, undefined)),
    Kind = toBinary(maps:get(kind, Caller, maps:get(<<"kind">>, Caller, <<>>))),
    case Mfa of
        undefined -> undefined;
        _ ->
            Fun = mfaFunBinary(Mfa),
            Phrase = case looksWriteName(Fun) of
                true -> iolist_to_binary([<<"改"/utf8>>, Tab]);
                false -> iolist_to_binary([<<"查"/utf8>>, Tab])
            end,
            #{
                phrase => Phrase,
                mfa => toBinary(Mfa),
                note => iolist_to_binary([<<"auto from ">>, Kind, <<" table ">>, Tab]),
                source => auto
            }
    end;
actionFromCaller(_, _) -> undefined.

seedFromApi(ApiEntries) ->
    lists:flatmap(fun(E) ->
        Mod = maps:get(module, E, undefined),
        Exports = maps:get(exports, E, []),
        case Mod of
            undefined -> [];
            _ ->
                lists:filtermap(fun(Exp) ->
                    NameBin = toBinary(maps:get(name, Exp, maps:get(<<"name">>, Exp, <<>>))),
                    Arity = maps:get(arity, Exp, maps:get(<<"arity">>, Exp, 0)),
                    case interestingExport(NameBin) of
                        false -> false;
                        true ->
                            Phrase = case looksWriteName(NameBin) of
                                true ->
                                    iolist_to_binary([<<"调用 "/utf8>>, toBinary(Mod), <<":">>, NameBin]);
                                false ->
                                    iolist_to_binary([<<"查询 "/utf8>>, toBinary(Mod), <<":">>, NameBin])
                            end,
                            {true, #{
                                phrase => Phrase,
                                mfa => iolist_to_binary([toBinary(Mod), <<":">>, NameBin, <<"/">>,
                                                        integer_to_binary(Arity)]),
                                note => <<"auto from exports">>,
                                source => auto
                            }}
                    end
                end, lists:sublist(ensureList(Exports), 12))
        end
    end, lists:sublist(ApiEntries, 80)).

interestingExport(<<>>) -> false;
interestingExport(Name) ->
    Prefixes = [<<"get">>, <<"set">>, <<"lookup">>, <<"find">>, <<"query">>,
                <<"update">>, <<"add">>, <<"del">>, <<"delete">>, <<"info">>,
                <<"list">>, <<"save">>, <<"load">>, <<"create">>, <<"remove">>],
    lists:any(fun(P) -> string:prefix(string:lowercase(Name), P) =/= nomatch end, Prefixes).

looksWriteName(Fun) ->
    Prefixes = [<<"set">>, <<"update">>, <<"add">>, <<"del">>, <<"delete">>,
                <<"put">>, <<"insert">>, <<"save">>, <<"write">>, <<"modify">>,
                <<"create">>, <<"remove">>, <<"clear">>, <<"reset">>],
    lists:any(fun(P) -> string:prefix(string:lowercase(toBinary(Fun)), P) =/= nomatch end, Prefixes).

mfaFunBinary(Mfa) ->
    Bin = toBinary(Mfa),
    case re:run(Bin, <<":([a-zA-Z_][a-zA-Z0-9_]*)/">>, [{capture, [1], binary}]) of
        {match, [Fun]} -> Fun;
        _ -> Bin
    end.

%% Existing（含手工）优先：同 phrase 不覆盖。
mergeActions(Existing, Seeded) ->
    lists:foldl(fun(A, Acc) ->
        P = phraseKey(A),
        case P =:= <<>> orelse lists:any(fun(E) -> phraseKey(E) =:= P end, Acc) of
            true -> Acc;
            false -> Acc ++ [A]
        end
    end, normalizeActionList(Existing), normalizeActionList(Seeded)).

normalizeActionList(List) when is_list(List) ->
    [A || A <- List, is_map(A)];
normalizeActionList(_) -> [].

phraseKey(A) when is_map(A) ->
    string:lowercase(toBinary(maps:get(phrase, A, maps:get(<<"phrase">>, A, <<>>))));
phraseKey(_) -> <<>>.

dedupActions(List) ->
    mergeActions([], List).

writeModuleContextFiles(Dir, Contexts) ->
    ModDir = filename:join(Dir, "modules"),
    ok = filelib:ensure_dir(filename:join(ModDir, "dummy")),
    Keep = maps:fold(fun(Mod, Ctx, Acc) ->
        Name = atom_to_list(toAtom(Mod)) ++ ".json",
        Payload = #{
            module => toBinary(maps:get(module, Ctx, Mod)),
            file => toBinary(maps:get(file, Ctx, <<>>)),
            absFile => toBinary(maps:get(absFile, Ctx, <<>>)),
            bucket => maps:get(bucket, Ctx, core),
            sourceMtime => maps:get(sourceMtime, Ctx, 0),
            builtAt => maps:get(builtAt, Ctx, erlang:system_time(second)),
            summary => toBinary(maps:get(summary, Ctx, <<>>)),
            searchText => toBinary(maps:get(searchText, Ctx, <<>>)),
            moduleDoc => toBinary(maps:get(moduleDoc, Ctx, <<>>)),
            includes => [toBinary(I) || I <- ensureList(maps:get(includes, Ctx, []))],
            behaviours => [toBinary(B) || B <- ensureList(maps:get(behaviours, Ctx, []))],
            deps => [toBinary(D) || D <- ensureList(maps:get(deps, Ctx, []))],
            callbacks => maps:get(callbacks, Ctx, []),
            specCount => maps:get(specCount, Ctx, 0),
            techDebt => maps:get(techDebt, Ctx, []),
            docBriefs => maps:get(docBriefs, Ctx, #{})
        },
        writeJsonAtomic(filename:join(ModDir, Name), Payload),
        Acc#{Name => true}
    end, #{}, Contexts),
    pruneStaleModuleFiles(ModDir, Keep),
    ok.

pruneStaleModuleFiles(ModDir, Keep) when is_map(Keep) ->
    case file:list_dir(ModDir) of
        {ok, Names} ->
            lists:foreach(fun(Name) ->
                case filename:extension(Name) =:= ".json" andalso not maps:is_key(Name, Keep) of
                    true -> _ = file:delete(filename:join(ModDir, Name));
                    false -> ok
                end
            end, Names);
        _ ->
            ok
    end.

searchConfig(Tokens) ->
    case readJson(filename:join(knowledgeDir(), "config.json")) of
        {ok, Map} ->
            Configs = maps:get(configs, Map, maps:get(<<"configs">>, Map, [])),
            lists:filtermap(fun(C) when is_map(C) ->
                Path = maps:get(path, C, maps:get(<<"path">>, C, <<>>)),
                Keys = maps:get(keys, C, maps:get(<<"keys">>, C, [])),
                Preview = maps:get(preview, C, maps:get(<<"preview">>, C, <<>>)),
                Score = matchKnowledge(Tokens, [Path, Keys, Preview]),
                case Score > 0 of
                    true ->
                        PreviewBin = toBinary(Preview),
                        Summary = case byte_size(PreviewBin) > 240 of
                            true -> truncateUtf8(PreviewBin, 240);
                            false -> PreviewBin
                        end,
                        {true, #{
                            kind => config,
                            path => toBinary(Path),
                            keys => lists:sublist(ensureList(Keys), 12),
                            summary => Summary,
                            score => Score
                        }};
                    false -> false
                end
            end, ensureList(Configs));
        _ -> []
    end.

searchDeps(Tokens) ->
    case readJson(filename:join(knowledgeDir(), "deps.json")) of
        {ok, Map} ->
            Mods = maps:get(modules, Map, maps:get(<<"modules">>, Map, [])),
            lists:filtermap(fun
                (M) when is_map(M) ->
                    Mod = maps:get(module, M, maps:get(<<"module">>, M, <<>>)),
                    Deps = maps:get(deps, M, maps:get(<<"deps">>, M, [])),
                    Score = matchKnowledge(Tokens, [Mod, Deps]),
                    case Score > 0 of
                        true ->
                            {true, #{
                                kind => deps,
                                module => toBinary(Mod),
                                deps => lists:sublist(ensureList(Deps), 16),
                                score => Score
                            }};
                        false -> false
                    end;
                (_) -> false
            end, ensureList(Mods));
        _ -> []
    end.

%%%===================================================================
%%% Search
%%%===================================================================

searchMap(Tokens) ->
    case readJson(filename:join(knowledgeDir(), "map.json")) of
        {ok, #{modules := Mods}} when is_list(Mods) ->
            [#{
                kind => map,
                module => maps:get(module, M, maps:get(<<"module">>, M, <<>>)),
                summary => maps:get(summary, M, maps:get(<<"summary">>, M, <<>>)),
                file => maps:get(file, M, maps:get(<<"file">>, M, <<>>)),
                score => matchKnowledge(Tokens,
                    [maps:get(module, M, <<>>), maps:get(summary, M, <<>>)])
             } || M <- Mods,
                  matchKnowledge(Tokens,
                      [maps:get(module, M, maps:get(<<"module">>, M, <<>>)),
                       maps:get(summary, M, maps:get(<<"summary">>, M, <<>>))]) > 0];
        _ -> []
    end.

searchApi(Tokens) ->
    case readJson(filename:join(knowledgeDir(), "api.json")) of
        {ok, #{modules := Mods}} when is_list(Mods) ->
            lists:flatmap(fun(M) ->
                Mod = maps:get(module, M, maps:get(<<"module">>, M, <<>>)),
                Exports = maps:get(exports, M, maps:get(<<"exports">>, M, [])),
                [begin
                     Name = maps:get(name, E, maps:get(<<"name">>, E, <<>>)),
                     Arity = maps:get(arity, E, maps:get(<<"arity">>, E, 0)),
                     Score = matchKnowledge(Tokens, [Mod, Name]),
                     #{
                         kind => api,
                         module => Mod,
                         mfa => iolist_to_binary(io_lib:format("~s:~s/~w",
                             [toBinary(Mod), toBinary(Name), Arity])),
                         score => Score
                     }
                 end || E <- Exports,
                        matchKnowledge(Tokens, [Mod,
                            maps:get(name, E, maps:get(<<"name">>, E, <<>>))]) > 0]
            end, Mods);
        _ -> []
    end.

searchActions(Tokens) ->
    case readJson(filename:join(knowledgeDir(), "actions.json")) of
        {ok, Map} ->
            List = maps:get(actions, Map, maps:get(<<"actions">>, Map, [])),
            [begin
                 NA = normalizeAction(A),
                 NA#{
                     kind => action,
                     score => matchKnowledge(Tokens, [
                         maps:get(phrase, NA, <<>>),
                         maps:get(mfa, NA, <<>>),
                         maps:get(note, NA, <<>>)
                     ])
                 }
             end || A <- List,
                  begin
                      NA0 = normalizeAction(A),
                      matchKnowledge(Tokens, [
                          maps:get(phrase, NA0, <<>>),
                          maps:get(mfa, NA0, <<>>)
                      ]) > 0
                  end];
        _ -> []
    end.

searchData(Tokens) ->
    case readJson(filename:join(knowledgeDir(), "data.json")) of
        {ok, Map} ->
            Tables = maps:get(tables, Map, maps:get(<<"tables">>, Map, #{})),
            maps:fold(fun(Tab, Callers, Acc) ->
                Score = matchKnowledge(Tokens, [Tab]),
                case Score > 0 of
                    true ->
                        [#{
                            kind => data,
                            table => toBinary(Tab),
                            callers => lists:sublist(ensureList(Callers), 8),
                            score => Score + 1.0
                         } | Acc];
                    false -> Acc
                end
            end, [], Tables);
        _ -> []
    end.

searchSummaries(Tokens) ->
    %% 仅扫 knowledge/modules/*.json，避免走 alModuleSummary→alLocalDb→aliCore
    %%（首轮上下文里会把网页卡在 project knowledge，且 DB 默认超时可达 120s）。
    Query = iolist_to_binary(lists:join(<<" ">>, Tokens)),
    case Query of
        <<>> -> [];
        _ ->
            ModDir = filename:join(knowledgeDir(), "modules"),
            case file:list_dir(ModDir) of
                {ok, Names} ->
                    lists:filtermap(fun(Name) ->
                        case filename:extension(Name) =:= ".json" of
                            false -> false;
                            true ->
                                case readJson(filename:join(ModDir, Name)) of
                                    {ok, M} when is_map(M) ->
                                        Mod = maps:get(module, M, maps:get(<<"module">>, M, <<>>)),
                                        Sum = maps:get(searchText, M,
                                            maps:get(<<"searchText">>, M,
                                                maps:get(summary, M,
                                                    maps:get(<<"summary">>, M, <<>>)))),
                                        ModuleDoc = maps:get(moduleDoc, M,
                                            maps:get(<<"moduleDoc">>, M, <<>>)),
                                        Includes = maps:get(includes, M,
                                            maps:get(<<"includes">>, M, [])),
                                        Behaviours = maps:get(behaviours, M,
                                            maps:get(<<"behaviours">>, M, [])),
                                        Deps = maps:get(deps, M,
                                            maps:get(<<"deps">>, M, [])),
                                        BriefText = briefsSearchText(
                                            maps:get(docBriefs, M,
                                                maps:get(<<"docBriefs">>, M, #{}))),
                                        Bucket = binaryToBucket(maps:get(bucket, M,
                                            maps:get(<<"bucket">>, M, core))),
                                        Score0 = matchKnowledge(Tokens,
                                            [Mod, Sum, ModuleDoc, Includes,
                                             Behaviours, Deps, BriefText]),
                                        Score = bucketAdjustScore(Score0, Bucket),
                                        case Score > 0 of
                                            true ->
                                                {true, #{
                                                    kind => summary,
                                                    module => Mod,
                                                    bucket => Bucket,
                                                    summary => Sum,
                                                    score => Score
                                                }};
                                            false -> false
                                        end;
                                    _ -> false
                                end
                        end
                    end, Names);
                _ -> []
            end
    end.

bucketAdjustScore(Score, core) -> Score;
bucketAdjustScore(Score, cfg) -> dampScore(Score, 3);
bucketAdjustScore(Score, test) -> dampScore(Score, 4);
bucketAdjustScore(Score, gm) -> dampScore(Score, 3);
bucketAdjustScore(Score, _) -> Score.

%% matchKnowledge 可能返回 float；`div` 只接受整数，否则 badarith。
dampScore(Score, Div) when is_integer(Score), is_integer(Div), Div > 0 ->
    max(1, Score div Div);
dampScore(Score, Div) when is_float(Score), is_number(Div), Div > 0 ->
    max(1.0, Score / Div);
dampScore(Score, _) ->
    Score.

%% 对话沉淀的主题摘要：.ali/knowledge/summaries/*.md
searchTopicSummaries(Tokens) ->
    Query = iolist_to_binary(lists:join(<<" ">>, Tokens)),
    case Query of
        <<>> -> [];
        _ ->
            Dir = filename:join(knowledgeDir(), "summaries"),
            case file:list_dir(Dir) of
                {ok, Names} ->
                    lists:filtermap(fun(Name) ->
                        Ext = filename:extension(Name),
                        case Ext =:= ".md" orelse Ext =:= ".json" of
                            false -> false;
                            true ->
                                Path = filename:join(Dir, Name),
                                case file:read_file(Path) of
                                    {ok, Bin} ->
                                        Topic = unicode:characters_to_binary(
                                            filename:basename(Name, Ext)),
                                        Score = matchKnowledge(Tokens, [Topic, Bin]),
                                        case Score > 0 of
                                            true ->
                                                Preview = case byte_size(Bin) > 800 of
                                                    true ->
                                                        <<(truncateUtf8(Bin, 800))/binary, "...">>;
                                                    false -> Bin
                                                end,
                                                {true, #{
                                                    kind => topicSummary,
                                                    topic => Topic,
                                                    summary => Preview,
                                                    path => Path,
                                                    score => Score + 0.5
                                                }};
                                            false -> false
                                        end;
                                    _ -> false
                                end
                        end
                    end, lists:sublist(Names, 200));
                _ -> []
            end
    end.

%% 简单打分：命中 token 数
matchKnowledge([], _Fields) -> 0.0;
matchKnowledge(Tokens, Fields) ->
    Hay = string:lowercase(iolist_to_binary([toBinary(F) || F <- Fields, F =/= undefined])),
    lists:foldl(fun(T, Acc) ->
        case T =:= <<>> of
            true -> Acc;
            false ->
                case binary:match(Hay, T) of
                    nomatch -> Acc;
                    _ -> Acc + 1.0
                end
        end
    end, 0.0, Tokens).

dedupHits(Hits) ->
    {_, Out} = lists:foldl(fun(H, {Seen, Acc}) ->
        Key = {maps:get(kind, H, undefined),
               maps:get(module, H, undefined),
               maps:get(mfa, H, undefined),
               maps:get(table, H, undefined),
               maps:get(phrase, H, undefined),
               maps:get(topic, H, undefined)},
        case maps:is_key(Key, Seen) of
            true -> {Seen, Acc};
            false -> {Seen#{Key => true}, [H | Acc]}
        end
    end, {#{}, []}, Hits),
    lists:reverse(Out).

splitTokens(Bin) ->
    Parts = binary:split(Bin, [<<" ">>, <<"\t">>, <<",">>, <<"，"/utf8>>, <<"的"/utf8>>],
                         [global, trim_all]),
    [P || P <- Parts, byte_size(P) >= 2].

actionMatches(PhraseLower, Action) ->
    A = normalizeAction(Action),
    P = string:lowercase(toBinary(maps:get(phrase, A, <<>>))),
    binary:match(PhraseLower, P) =/= nomatch
        orelse binary:match(P, PhraseLower) =/= nomatch.

normalizeAction(A) when is_map(A) ->
    Source0 = maps:get(source, A, maps:get(<<"source">>, A, auto)),
    Source = case Source0 of
        <<"manual">> -> manual;
        manual -> manual;
        <<"auto">> -> auto;
        auto -> auto;
        Other -> Other
    end,
    #{
        phrase => toBinary(maps:get(phrase, A, maps:get(<<"phrase">>, A, <<>>))),
        mfa => toBinary(maps:get(mfa, A, maps:get(<<"mfa">>, A, <<>>))),
        note => toBinary(maps:get(note, A, maps:get(<<"note">>, A, <<>>))),
        source => Source,
        confidence => maps:get(confidence, A, maps:get(<<"confidence">>, A, <<"manual">>))
    };
normalizeAction(_) ->
    #{phrase => <<>>, mfa => <<>>, note => <<>>, source => auto, confidence => <<"manual">>}.

%%%===================================================================
%%% IO helpers
%%%===================================================================

writeJsonAtomic(Path, Term) ->
    Bin = alJson:encode(Term),
    Tmp = Path ++ ".tmp." ++ integer_to_list(erlang:unique_integer([positive])),
    case file:write_file(Tmp, Bin) of
        ok ->
            case file:rename(Tmp, Path) of
                ok -> ok;
                {error, _} = E ->
                    _ = file:delete(Tmp),
                    E
            end;
        {error, _} = E ->
            E
    end.

readJson(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            try {ok, alJson:decode(Bin)}
            catch _:_ -> {error, badJson}
            end;
        {error, _} = E ->
            E
    end.

safeRelPath(Root, Path) ->
    try
        case string:prefix(filename:absname(Path), filename:absname(Root)) of
            nomatch -> Path;
            Rel0 ->
                Rel1 = string:trim(Rel0, leading, "/\\"),
                filename:join(filename:split(Rel1))
        end
    catch _:_ -> Path
    end.

ensureList(L) when is_list(L) -> L;
ensureList(_) -> [].

toBinary(B) when is_binary(B) -> B;
toBinary(A) when is_atom(A) -> atom_to_binary(A, utf8);
toBinary(L) when is_list(L) -> unicode:characters_to_binary(L);
toBinary(I) when is_integer(I) -> integer_to_binary(I);
toBinary(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).

%% 按 UTF-8 码点边界截断，避免切断多字节字符（如中文）产生非法 UTF-8。
truncateUtf8(Bin, Max) when is_binary(Bin), byte_size(Bin) =< Max ->
    Bin;
truncateUtf8(Bin, Max) when is_binary(Bin) ->
    binary:part(Bin, 0, truncateUtf8Len(Bin, min(Max, byte_size(Bin))));
truncateUtf8(_Bin, _Max) ->
    <<>>.

truncateUtf8Len(_Bin, Len) when Len =< 0 ->
    0;
truncateUtf8Len(Bin, Len) ->
    truncateUtf8Len(Bin, Len, 0).

truncateUtf8Len(_Bin, 0, _Back) ->
    0;
truncateUtf8Len(Bin, Len, Back) when Back < 3 ->
    <<_:Len/binary, Byte, _/binary>> = Bin,
    case (Byte band 16#C0) =:= 16#80 of
        true -> truncateUtf8Len(Bin, Len - 1, Back + 1);
        false -> Len
    end;
truncateUtf8Len(_Bin, Len, _Back) ->
    Len.

toAtom(A) when is_atom(A) -> A;
toAtom(B) when is_binary(B) ->
    try binary_to_existing_atom(B, utf8) catch _:_ -> undefined end;
toAtom(L) when is_list(L) ->
    try list_to_existing_atom(L) catch _:_ -> undefined end.

%% 仅返回已存在的 atom（项目源文件模块名）；不创建新 atom，避免原子表耗尽。
identAtom(Name) when is_list(Name), length(Name) > 0, length(Name) =< 255 ->
    try list_to_existing_atom(Name)
    catch _:_ -> undefined
    end;
identAtom(Name) when is_binary(Name) ->
    identAtom(unicode:characters_to_list(Name));
identAtom(_) -> undefined.
