%%%-------------------------------------------------------------------
%% @doc 从代码搜索、Rust 符号与运行时构建紧凑上下文。
%% @end
%%%-------------------------------------------------------------------

-module(alContextEngine).

-export([build/2]).
%% Test exports — pure helpers
-export([normalizeHits/1, normalizeHit/1, modulesFromHits/2, guessModules/1,
         isModuleLike/1, parseFa/1, parseAnchors/1, moduleEdgeMatch/2, toBinary/1, toList/1,
         needsCodeSearch/1, compactHit/1, relativePath/1, projectOutline/0,
         expandCallContext/1, extractTopFa/1, mergeCallContext/2, faFromHit/1,
         fetchModuleSummaries/1,
         boostByGitFreshness/2, boostHit/2, isRecentFile/2,
         fetchRuntime/3, needsRuntime/1, compactRuntime/1, relevantProcesses/2,
         paramSourceHints/3, classifyParamSource/1, needsDataFlow/1,
         findReferences/2, findReferences/3, extractReferencesFromHit/3,
         isReferenceKind/1,
         traceDataQuery/2, extractDataNouns/1, findDataSourceCandidates/2,
         parseDataQueryAnchor/1, confidenceOf/1, buildClarifyPrompt/1,
         absUnderRoot/1,
         fetchRelatedTests/1, isWriteTask/1]).

-define(MaxSnippetLines, 3).
-define(MaxFunctionsPerHit, 8).
-define(MaxModulesForSymbols, 3).
-define(MaxFunsInSymbolSummary, 24).
-define(MaxOutlineEntries, 40).
-define(MaxAnchorSnippets, 5).
-define(AnchorSnippetRadius, 6).
-define(AnchorSnippetHeadLines, 24).
%% 调用图扩展召回：最多对 N 个命中函数做 1-hop 扩展，每方向最多 M 条边。
%% 大型项目调用图可能极密，必须限流避免上下文爆炸。
-define(MaxExpandHits, 3).
-define(MaxExpandedEdgesPerDirection, 20).
%% Git 加权：最近改过的文件 score 乘以此因子并重排，让 LLM 优先看到近期变更。
-define(GitBoostFactor, 1.5).

%%--------------------------------------------------------------------
%% @doc
%% 构建供 LLM 使用的紧凑上下文。默认不含全量 runtime / 全图调用边，
%% 命中只保留相对路径 + 短 snippet + 少量函数名，迫使模型再 readFile。
%%
%% @param Question 用户问题
%% @param Opts searchLimit、includeRuntime、includeOutline 等
%% @return context map
%% @end
%%--------------------------------------------------------------------
build(Question, Opts) ->
    SearchLimit = maps:get(searchLimit, Opts, 6),
    IncludeRuntime = maps:get(includeRuntime, Opts, false),
    IncludeOutline = maps:get(includeOutline, Opts, true),
    %% 写任务侦察（map-reduce 编排）：edit 模式（含运行中升档 modePromoted）追加
    %% 写专属召回维度——相关测试文件（写后验证入口）。写目标快照与影响面
    %% （锚点 MFA 的 callers/callees）已由 anchorSnippets/anchorCalls 覆盖。
    IsWriteTask = isWriteTask(Opts),
    Anchors = parseAnchors(Question),
    AnchorMods = maps:get(modules, Anchors, []),
    AnchorMfas = maps:get(mfas, Anchors, []),
    %% 检索：查询分解（复合问题）→ 改写（简单问题）→ BM25 命中。
    %% 分解与改写正交：分解是意图拆分，改写是关键词扩展。
    %% 复合问题分解后每个子查询独立检索合并去重；简单问题走改写+单检索。
    {RewrittenTerms, CodeHits0} = fetchHits(Question, SearchLimit, Opts),
    %% VCS 加权：最近改过的文件 score * 1.5 并重排，让 LLM 优先看到近期变更。
    %% 大型项目里"最近改的代码"往往与当前问题最相关。vcs 不可用时降级为无加权。
    RecentFiles = try alVcsIndex:recentFiles() catch _:_ -> ordsets:new() end,
    CodeHits0Boosted = boostByGitFreshness(CodeHits0, RecentFiles),
    CodeHits = [compactHit(H) || H <- CodeHits0Boosted],
    HitMods = modulesFromHits(CodeHits0, Question),
    MfaMods = [M || #{module := M} <- AnchorMfas, M =/= undefined],
    Preferred = lists:usort(AnchorMods ++ MfaMods),
    Modules = lists:usort(Preferred ++ HitMods),
    OrderedMods = prioritizeModules(Preferred, HitMods),
    %% 独立召回并行：symbols / summaries / calls / runtime / outline / paths /
    %% anchors / dataQuery / knowledge。单路失败降级为空，不拖垮整包。
    Parallel = parallelFetch([
        {symbols, fun() -> fetchModuleSymbols(OrderedMods) end},
        {summaries, fun() -> fetchModuleSummaries(OrderedMods) end},
        {explicitCalls, fun() -> fetchCallContext(Question) end},
        {anchorCalls, fun() -> fetchAnchorCallContexts(AnchorMfas) end},
        {expandedCalls, fun() -> expandCallContext(CodeHits0) end},
        {runtime, fun() -> fetchRuntime(Question, OrderedMods, IncludeRuntime) end},
        {outline, fun() ->
            case IncludeOutline of true -> projectOutline(); false -> [] end
         end},
        {modulePaths, fun() -> resolveModulePaths(OrderedMods) end},
        {anchorResolved, fun() -> resolveAnchors(Anchors) end},
        {dataQuery, fun() -> maybeFetchDataQuery(Question, Opts) end},
        {knowledge, fun() -> maybeFetchKnowledge(Question, Opts) end},
        {relatedTests, fun() ->
            case IsWriteTask of
                true -> fetchRelatedTests(OrderedMods);
                false -> []
            end
         end}
    ], 15000),
    SymbolContext = maps:get(symbols, Parallel, #{}),
    ModuleSummaries = maps:get(summaries, Parallel, #{}),
    ExplicitCalls = maps:get(explicitCalls, Parallel, #{}),
    AnchorCalls = maps:get(anchorCalls, Parallel, #{}),
    ExpandedCalls = maps:get(expandedCalls, Parallel, #{}),
    CallContext = mergeCallContext(ExplicitCalls, ExpandedCalls),
    Runtime = maps:get(runtime, Parallel, #{}),
    Outline = maps:get(outline, Parallel, []),
    ModulePaths = maps:get(modulePaths, Parallel, #{}),
    AnchorResolved = maps:get(anchorResolved, Parallel, #{}),
    %% snippets 依赖已解析 anchors，串行在并行阶段之后。
    AnchorSnippets = prefetchAnchorSnippets(AnchorResolved),
    DataQuery = enrichDataQuery(maps:get(dataQuery, Parallel, undefined)),
    Knowledge = maps:get(knowledge, Parallel, undefined),
    RelatedTests = maps:get(relatedTests, Parallel, []),
    Hint0 = <<"Honor retrieved_context.anchors and anchorSnippets first. "
              "Use modulePaths / codeHits.file / gotoDef as ground-truth paths. "
              "Never invent paths from topLevel (e.g. boot/+plugin). "
              "Prefer gotoDef then readFile; findRefs for call sites. "
              "Cite only symbols/paths present in context or tool results.">>,
    Hint1 = case DataQuery of
        undefined -> Hint0;
        #{confidence := Conf, clarifyPrompt := CP} when (Conf =:= low orelse Conf =:= none),
                                             is_binary(CP), CP =/= <<>> ->
            <<Hint0/binary,
               " Data-query confidence is low — prefer asking the user to clarify "
               "before guessing table/MFA names: ", CP/binary>>;
        _ -> <<Hint0/binary,
               " For data-query questions prefer retrieved_context.dataQuery "
               "(traceDataQuery result). Do not guess get*/query* names; "
               "use @table: / @mfa: when confidence is low.">>
    end,
    Hint = case Knowledge of
        undefined -> Hint1;
        _ -> <<Hint1/binary,
               " Prefer retrieved_context.knowledge and suggestedActions when present; "
               "use searchKnowledge / lookupAction to refine. Still verify MFA before runMfa.">>
    end,
    %% 工具选择学习：同类问题历史上高频工具注入 hint，降低 LLM 工具决策成本。
    ToolHints = try alToolLearn:suggestTools(Question) catch _:_ -> [] end,
    Hint2 = case ToolHints of
        [] -> Hint;
        _ ->
            ToolsBin = iolist_to_binary(lists:join(<<", ">>, ToolHints)),
            <<Hint/binary, " For questions like this, tools that worked well before: ",
              ToolsBin/binary, ".">>
    end,
    %% 写任务纪律（map-reduce 的 reduce 阶段定向注入）：侦察报告已就位，
    %% 约束 LLM 直接从「读目标 → 最小补丁 → 写后验证」进入，减少探索轮次。
    Hint3 = case IsWriteTask of
        true ->
            <<Hint2/binary,
              " WRITE-TASK DISCIPLINE: (1) anchors/anchorSnippets are the edit "
              "targets — readFile them fully before drafting (snippets are previews); "
              "(2) prefer minimal-diff applyPatch hunks over whole-file rewrites; "
              "(3) after every write run verifyCompile; when writeRecon.relatedTests "
              "is non-empty, runEunit those files; (4) callSites in anchorCalls are "
              "the blast radius — re-read callers you may break.">>;
        false ->
            Hint2
    end,
    Context0 = #{
        question => Question,
        searchQuery => joinTerms(RewrittenTerms, Question),
        rewrittenTerms => RewrittenTerms,
        projectOutline => Outline,
        codeHits => CodeHits,
        modules => Modules,
        modulePaths => ModulePaths,
        anchors => AnchorResolved,
        anchorSnippets => AnchorSnippets,
        symbols => SymbolContext,
        moduleSummaries => ModuleSummaries,
        calls => CallContext,
        anchorCalls => AnchorCalls,
        runtime => Runtime,
        dataQuery => DataQuery,
        knowledge => Knowledge,
        toolHints => ToolHints,
        coreAvailable => alCoreClient:available(),
        hint => Hint3
    },
    case IsWriteTask of
        true ->
            Context0#{writeRecon => #{
                relatedTests => RelatedTests,
                note => <<"scout report for write task: edit targets + "
                          "verification entry points"/utf8>>
            }};
        false ->
            Context0
    end.

%% 并行执行互不依赖的 Fun；超时/崩溃用 Default 占位（按键选空值）。
parallelFetch(Jobs, TimeoutMs) ->
    Parent = self(),
    Started = [begin
        Ref = make_ref(),
        {Pid, Mon} = spawn_monitor(fun() ->
            Result = try Fun() catch Class:Reason:Stack ->
                {error, {Class, Reason, Stack}}
            end,
            Parent ! {ctxFetch, Ref, Result}
        end),
        {Key, Ref, Pid, Mon}
    end || {Key, Fun} <- Jobs],
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    collectParallelFetch(Started, Deadline, #{}).

collectParallelFetch([], _Deadline, Acc) ->
    Acc;
collectParallelFetch(Pending, Deadline, Acc) ->
    Remain = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {ctxFetch, Ref, Result} ->
            case lists:keyfind(Ref, 2, Pending) of
                {Key, Ref, _Pid, Mon} ->
                    erlang:demonitor(Mon, [flush]),
                    Val = case Result of
                        {error, _} -> parallelDefault(Key);
                        Other -> Other
                    end,
                    collectParallelFetch(lists:keydelete(Ref, 2, Pending), Deadline,
                                        Acc#{Key => Val});
                false ->
                    collectParallelFetch(Pending, Deadline, Acc)
            end;
        {'DOWN', Mon, process, _Pid, _Reason} ->
            case lists:keyfind(Mon, 4, Pending) of
                {Key, _Ref, _Pid2, Mon} ->
                    collectParallelFetch(lists:keydelete(Mon, 4, Pending), Deadline,
                                        Acc#{Key => parallelDefault(Key)});
                false ->
                    collectParallelFetch(Pending, Deadline, Acc)
            end
    after Remain ->
        lists:foreach(fun({_Key, _Ref, Pid, Mon}) ->
            exit(Pid, kill),
            erlang:demonitor(Mon, [flush])
        end, Pending),
        lists:foldl(fun({Key, _, _, _}, A) -> A#{Key => parallelDefault(Key)} end,
                    Acc, Pending)
    end.

parallelDefault(symbols) -> [];
parallelDefault(summaries) -> [];
parallelDefault(explicitCalls) -> #{};
parallelDefault(anchorCalls) -> [];
parallelDefault(expandedCalls) -> #{};
parallelDefault(runtime) -> #{};
parallelDefault(outline) -> [];
parallelDefault(modulePaths) -> [];
parallelDefault(anchorResolved) -> #{modules => [], paths => [], mfas => []};
parallelDefault(dataQuery) -> undefined;
parallelDefault(knowledge) -> undefined;
parallelDefault(_) -> undefined.

%%--------------------------------------------------------------------
%% @doc
%% 检索入口：先尝试查询分解，复合问题并行检索多子查询合并；
%% 简单问题走改写+单检索；不需代码检索时返回空。
%%
%% @param Question 用户问题
%% @param SearchLimit 每路检索上限
%% @param Opts 选项（透传给 alQueryDecompose/alQueryRewrite）
%% @return {RewrittenTerms, CodeHits}
%% @end
%%--------------------------------------------------------------------
fetchHits(Question, SearchLimit, Opts) ->
    case needsCodeSearch(Question) of
        false ->
            {[], []};
        true ->
            emitContextProgress(Opts, <<"building context: code search...">>),
            %% 活数据/显式跳过：不做 decompose/rewrite 预调 LLM，避免卡在「思考中」
            case maps:get(skipQueryLlm, Opts, false) of
                true ->
                    Hits = fetchCodeHits(toBinary(Question), SearchLimit),
                    {[toBinary(Question)], Hits};
                false ->
                    fetchHitsWithLlm(Question, SearchLimit, Opts)
            end
    end.

fetchHitsWithLlm(Question, SearchLimit, Opts) ->
    emitContextProgress(Opts, <<"building context: query decompose/rewrite...">>),
    SubQueries = alQueryDecompose:decompose(Question, Opts),
    case SubQueries of
        [] ->
            %% 单查询流程：改写关键词 → BM25 检索；0 结果时重试一次
            Terms = alQueryRewrite:rewrite(Question, Opts),
            Hits = fetchCodeHitsWithRetry(Terms, Question, SearchLimit, Opts),
            {Terms, Hits};
        [_|_] ->
            %% 分解流程：每个子查询关键词组独立检索，合并去重。
            Hits = lists:flatmap(fun(Kws) ->
                SQ = joinTerms(Kws, <<>>),
                case SQ of
                    <<>> -> [];
                    _ -> fetchCodeHits(SQ, SearchLimit)
                end
            end, SubQueries),
            Deduped = alQueryDecompose:dedupHits(Hits),
            FinalHits = case Deduped of
                [] -> fetchCodeHitsWithRetry([], Question, SearchLimit, Opts);
                _ -> Deduped
            end,
            {[], FinalHits}
    end.

%% 检索 0 结果时用原问或二次改写再试一次。
fetchCodeHitsWithRetry(Terms, Question, SearchLimit, Opts) ->
    QBin = toBinary(Question),
    Hits0 = case Terms of
        [] -> fetchCodeHits(QBin, SearchLimit);
        _ -> fetchCodeHits(joinTerms(Terms, Question), SearchLimit)
    end,
    case Hits0 of
        [_ | _] ->
            Hits0;
        [] ->
            AltTerms = alQueryRewrite:rewrite(
                <<QBin/binary, " erlang module">>, Opts),
            case AltTerms of
                Terms -> fetchCodeHits(QBin, SearchLimit);
                _ ->
                    case AltTerms of
                        [] -> fetchCodeHits(QBin, SearchLimit);
                        _ -> fetchCodeHits(joinTerms(AltTerms, Question), SearchLimit)
                    end
            end
    end.

enrichDataQuery(undefined) ->
    undefined;
enrichDataQuery(DQ) when is_map(DQ) ->
    case paramHintsForDataQuery(DQ) of
        undefined -> DQ;
        Hints -> DQ#{paramSourceHints => Hints}
    end;
enrichDataQuery(Other) ->
    Other.

paramHintsForDataQuery(#{candidates := [Top | _]}) ->
    case mfaFromCandidate(Top) of
        {ok, M, F, A} ->
            try paramSourceHints(M, F, A) catch _:_ -> undefined end;
        _ ->
            undefined
    end;
paramHintsForDataQuery(_) ->
    undefined.

mfaFromCandidate(#{target := {mfa, M, F, A}}) ->
    {ok, M, F, A};
mfaFromCandidate(#{mfa := MfaBin}) when is_binary(MfaBin) ->
    parseMfaBinary(MfaBin);
mfaFromCandidate(_) ->
    error.

parseMfaBinary(Bin) ->
    case re:run(Bin, <<"^([^:]+):([^/]+)/(\\d+)$">>, [{capture, all_but_first, binary}]) of
        {match, [ModB, FunB, ArityB]} ->
            {ok, binary_to_atom(ModB, utf8),
             binary_to_atom(FunB, utf8),
             binary_to_integer(ArityB)};
        _ ->
            error
    end.

emitContextProgress(Opts, Message) when is_map(Opts), is_binary(Message) ->
    case maps:get(progressId, Opts, undefined) of
        undefined -> ok;
        ProgressId ->
            try alProgress:emit(ProgressId, #{
                type => step,
                phase => context,
                message => Message
            }) catch _:_ -> ok end
    end;
emitContextProgress(_, _) ->
    ok.

%% 关键词列表 join 为空格分隔的搜索串；空列表时回退到 Fallback。
joinTerms([], Fallback) -> toBinary(Fallback);
joinTerms(Terms, _Fallback) when is_list(Terms) ->
    unicode:characters_to_binary(string:join([toList(T) || T <- Terms], " "));
joinTerms(_Terms, Fallback) ->
    toBinary(Fallback).

%% 拉取代码检索命中。强制走 Rust core；core 不可用/出错时返回空。
fetchCodeHits(SearchQuery, Limit) ->
    case alCoreClient:search(SearchQuery, Limit) of
        {ok, #{data := #{hits := Hits}}} -> normalizeHits(Hits);
        {ok, #{data := Data}} -> normalizeHits(maps:get(hits, Data, []));
        _ -> []
    end.

normalizeHits(Hits) when is_list(Hits) ->
    [normalizeHit(Hit) || Hit <- Hits];
normalizeHits(_) ->
    [].

normalizeHit(Hit) when is_map(Hit) ->
    #{
        engine => rustCore,
        file => maps:get(file, Hit, undefined),
        module => maps:get(module, Hit, undefined),
        score => maps:get(score, Hit, 0),
        functions => maps:get(functions, Hit, []),
        snippets => maps:get(snippets, Hit, [])
    };
normalizeHit(Hit) ->
    Hit.

%% 压缩单条命中：相对路径、少函数名、短 snippet。
compactHit(Hit) when is_map(Hit) ->
    Funs0 = maps:get(functions, Hit, []),
    Funs = case is_list(Funs0) of
        true ->
            [compactFun(F) || F <- lists:sublist(Funs0, ?MaxFunctionsPerHit)];
        false ->
            []
    end,
    Snips0 = maps:get(snippets, Hit, []),
    Snips = case is_list(Snips0) of
        true -> lists:sublist(Snips0, ?MaxSnippetLines);
        false -> []
    end,
    File = maps:get(file, Hit, undefined),
    #{
        file => relativePath(File),
        absFile => File,
        module => maps:get(module, Hit, undefined),
        score => maps:get(score, Hit, 0),
        functions => Funs,
        snippets => Snips
    };
compactHit(Hit) ->
    Hit.

compactFun(F) when is_map(F) ->
    #{
        name => maps:get(name, F, maps:get(<<"name">>, F, undefined)),
        arity => maps:get(arity, F, maps:get(<<"arity">>, F, undefined)),
        line => maps:get(line, F, maps:get(<<"line">>, F, undefined))
    };
compactFun(F) ->
    F.

%% 绝对路径投影为相对 projectRoot / codeRoots（便于 LLM）；失败则原样。
%% 多根时取最短相对路径，避免把 plugin/... 误写成 boot/plugin/... 之类。
relativePath(undefined) -> undefined;
relativePath(null) -> undefined;
relativePath(Path0) ->
    PathNorm = normalizeSlashes(toList(Path0)),
    PathLower = string:lowercase(PathNorm),
    Roots = try alConfig:codeRoots() catch _:_ ->
        try [alConfig:projectRoot()] catch _:_ -> [] end
    end,
    Rels = lists:filtermap(fun(Root) ->
        RootNorm = string:lowercase(normalizeSlashes(toList(Root))),
        case RootNorm =/= "" andalso lists:prefix(RootNorm, PathLower) of
            true ->
                Rel0 = lists:nthtail(length(RootNorm), PathNorm),
                Rel = case Rel0 of
                    [$/ | Rest] -> Rest;
                    [$\\ | Rest] -> Rest;
                    _ -> Rel0
                end,
                {true, Rel};
            false ->
                false
        end
    end, Roots),
    case Rels of
        [] -> PathNorm;
        _ ->
            %% 最短相对路径通常最贴近真实源码根（避免多嵌套假前缀）
            hd(lists:sort(fun(A, B) -> length(A) =< length(B) end, Rels))
    end.

normalizeSlashes(S) ->
    lists:map(fun($\\) -> $/; (C) -> C end, S).

modulesFromHits(Hits, Question) ->
    FromHits = [Mod || #{module := Mod} <- Hits, Mod =/= undefined, Mod =/= null],
    FromQuestion = guessModules(Question),
    lists:usort(FromHits ++ FromQuestion).

guessModules(Question) when is_binary(Question) ->
    guessModules(unicode:characters_to_list(Question));
guessModules(Question) when is_list(Question) ->
    QuestionBin = unicode:characters_to_binary(string:lowercase(Question)),
    Tokens = re:split(QuestionBin, "[^a-zA-Z0-9_]+", [{return, binary}]),
    [Atom || Token <- Tokens, Token =/= <<>>, isModuleLike(binary_to_list(Token)),
             Atom <- [existingModuleAtom(Token)], Atom =/= undefined];
guessModules(_) ->
    [].

%% 仅接受已存在的原子，统一返回 atom 列表；未知 token 直接跳过，
%% 避免 list_to_atom 造成原子泄漏，也避免返回 atom/string 混合。
existingModuleAtom(Token) ->
    try list_to_existing_atom(binary_to_list(Token))
    catch _:_ -> undefined
    end.

isModuleLike(Token) ->
    length(Token) >= 3 andalso
        string:find(Token, "_") =/= nomatch andalso
        hd(Token) >= $a andalso hd(Token) =< $z.

fetchModuleSymbols([]) ->
    [];
fetchModuleSymbols(Modules) ->
    lists:filtermap(fun(Module) ->
        case alCoreClient:moduleSymbols(Module) of
            {ok, #{data := #{document := Doc}}} when is_map(Doc) ->
                {true, #{module => Module, summary => compactSymbolDoc(Doc)}};
            {ok, #{data := Data}} when is_map(Data) ->
                case maps:get(document, Data, undefined) of
                    Doc when is_map(Doc) ->
                        {true, #{module => Module, summary => compactSymbolDoc(Doc)}};
                    _ ->
                        false
                end;
            _ ->
                false
        end
    end, lists:sublist(Modules, ?MaxModulesForSymbols)).

%%--------------------------------------------------------------------
%% @doc
%% 拉取模块摘要：对每个模块调 {@link alModuleSummary:getOrGenerate/1}，
%% 异步生成（首轮可能为空），收集已命中的摘要注入上下文。
%%
%% 限流到 ?MaxModulesForSymbols 个模块，避免对大型项目的命中模块
%% 一次性触发过多 LLM 生成。
%%
%% @param Modules 模块名列表
%% @return [#{module, summary}]（仅含已命中的，未生成的不含）
%% @end
%%--------------------------------------------------------------------
fetchModuleSummaries(Modules) when is_list(Modules) ->
    lists:filtermap(fun(Module) ->
        try alModuleSummary:getOrGenerate(Module) of
            {ok, Summary} -> {true, #{module => Module, summary => Summary}};
            undefined -> false
        catch
            _:_ -> false
        end
    end, lists:sublist(Modules, ?MaxModulesForSymbols));
fetchModuleSummaries(_) ->
    [].

%% 符号摘要：文件 + 函数名列表，不含 calls/chunks/全文。
compactSymbolDoc(Doc) ->
    Funs0 = maps:get(functions, Doc, maps:get(<<"functions">>, Doc, [])),
    Funs = case is_list(Funs0) of
        true -> [compactFun(F) || F <- lists:sublist(Funs0, ?MaxFunsInSymbolSummary)];
        false -> []
    end,
    File = maps:get(file, Doc, maps:get(<<"file">>, Doc, undefined)),
    Behaviours = maps:get(behaviours, Doc, maps:get(<<"behaviours">>, Doc, [])),
    TestCases = maps:get(test_cases, Doc, maps:get(<<"test_cases">>, Doc, [])),
    TechDebt = maps:get(tech_debt, Doc, maps:get(<<"tech_debt">>, Doc, [])),
    Base = #{
        file => relativePath(File),
        module => maps:get(module, Doc, maps:get(<<"module">>, Doc, undefined)),
        functions => Funs
    },
    Base#{
        behaviours => Behaviours,
        testCases => TestCases,
        techDebt => TechDebt
    }.

%% 仅在问题含 M:F/A 时拉 callers/callees；不再每轮拉全图。
fetchCallContext(Question) ->
    case parseFa(Question) of
        {ok, Module, Function, Arity} ->
            Callees = case alCoreClient:getCallees(Module, Function, Arity) of
                {ok, #{data := #{edges := CalleeEdges}}} -> lists:sublist(CalleeEdges, 40);
                _ -> []
            end,
            Callers = case alCoreClient:getCallers(Module, Function, Arity) of
                {ok, #{data := #{edges := CallerEdges}}} -> lists:sublist(CallerEdges, 40);
                _ -> []
            end,
            #{module => Module, function => Function, arity => Arity,
              callers => Callers, callees => Callees};
        error ->
            #{}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 调用图扩展召回：从代码命中里提取 top-N 函数，对每个函数做 1-hop
%% callers/callees 扩展，把上下游调用边注入上下文。
%%
%% 设计要点：
%% - 仅在 core 可用时生效，否则返回空 map（Erlang fallback 无调用图）
%% - 限制扩展规模（?MaxExpandHits 个函数，每方向 ?MaxExpandedEdgesPerDirection 条边）
%% - 每条扩展边附带 expandedFrom 标记来源，便于 LLM 区分显式查询与扩展召回
%% - core 调用全部 try/catch，避免调用图故障影响主流程
%%
%% @param Hits 代码搜索命中列表（normalizeHits 后）
%% @return #{} 或 #{expandedEdges => [Edge], sources => [Fa]}
%% @end
%%--------------------------------------------------------------------
expandCallContext(Hits) ->
    Fas = extractTopFa(Hits),
    case Fas of
        [] ->
            #{};
        _ ->
            Edges = lists:flatmap(fun expandFa/1, Fas),
            case Edges of
                [] -> #{};
                _ -> #{expandedEdges => Edges, sources => Fas}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 从命中列表提取 top-N（按 score 降序）的 {Module, Function, Arity} 三元组。
%% 仅取每个命中的第一个函数，跳过无 module 或无 functions 的命中。
%%
%% @param Hits 命中列表
%% @return [{Module, Function, Arity}]（最多 ?MaxExpandHits 个）
%% @end
%%--------------------------------------------------------------------
extractTopFa(Hits) when is_list(Hits) ->
    Sorted = lists:sort(fun(A, B) ->
        maps:get(score, A, 0) >= maps:get(score, B, 0)
    end, Hits),
    extractFaFromHits(Sorted, ?MaxExpandHits, []);
extractTopFa(_) ->
    [].

extractFaFromHits(_Hits, 0, Acc) ->
    lists:reverse(Acc);
extractFaFromHits([], _N, Acc) ->
    lists:reverse(Acc);
extractFaFromHits([Hit | Rest], N, Acc) ->
    case faFromHit(Hit) of
        undefined ->
            extractFaFromHits(Rest, N, Acc);
        Fa ->
            extractFaFromHits(Rest, N - 1, [Fa | Acc])
    end.

%%--------------------------------------------------------------------
%% @doc
%% 从单个命中提取 {Module, Function, Arity}：module 取命中顶层，
%% function/arity 取 functions 列表首项。归一化为 atom/atom/integer。
%%
%% @param Hit 命中 map
%% @return {Module, Function, Arity} | undefined
%% @end
%%--------------------------------------------------------------------
faFromHit(Hit) when is_map(Hit) ->
    Module = maps:get(module, Hit, undefined),
    Funs = maps:get(functions, Hit, []),
    case Module =/= undefined andalso is_list(Funs) andalso Funs =/= [] of
        true ->
            case hd(Funs) of
                #{name := Name, arity := Arity} when Name =/= undefined, Arity =/= undefined ->
                    M = normalizeModule(Module),
                    F = normalizeAtom(Name),
                    A = normalizeArity(Arity),
                    case M =:= undefined orelse F =:= undefined orelse A =:= undefined of
                        true -> undefined;
                        false -> {M, F, A}
                    end;
                _ ->
                    undefined
            end;
        false ->
            undefined
    end;
faFromHit(_) ->
    undefined.

%%--------------------------------------------------------------------
%% @doc
%% 对单个 {Module, Function, Arity} 做 1-hop callers/callees 扩展，
%% 返回带来源标记的边列表。core 调用失败时该方向返回空。
%% @end
%%--------------------------------------------------------------------
expandFa({Module, Function, Arity}) ->
    Callers = safeGraphCall(getCallers, Module, Function, Arity),
    Callees = safeGraphCall(getCallees, Module, Function, Arity),
    CallerEdges = tagEdges(callers, Module, Function, Arity, Callers),
    CalleeEdges = tagEdges(callees, Module, Function, Arity, Callees),
    CallerEdges ++ CalleeEdges.

%% 安全调用 core 图接口：失败/异常返回空列表，不传播错误。
safeGraphCall(Op, Module, Function, Arity) ->
    try apply(alCoreClient, Op, [Module, Function, Arity]) of
        {ok, #{data := #{edges := E}}} when is_list(E) -> E;
        {ok, #{data := Data}} when is_map(Data) ->
            maps:get(edges, Data, []);
        _ -> []
    catch
        _:_ -> []
    end.

%% 给扩展边打上来源标记（来源函数 + 方向），并限流到 ?MaxExpandedEdgesPerDirection。
tagEdges(Direction, Module, Function, Arity, Edges) ->
    Limited = lists:sublist(Edges, ?MaxExpandedEdgesPerDirection),
    Source = #{module => Module, function => Function, arity => Arity, direction => Direction},
    [Edge#{expandedFrom => Source} || Edge <- Limited, is_map(Edge)].

%%--------------------------------------------------------------------
%% @doc
%% 合并显式调用上下文（问题含 M:F/A 时拉取）与扩展召回上下文。
%% 两者字段不冲突（显式用 callers/callees，扩展用 expandedEdges/sources），
%% 合并后 LLM 能同时看到"问题指定的"和"代码命中扩展的"调用边。
%%
%% @param Explicit 显式调用上下文 map（可能为空）
%% @param Expanded 扩展召回上下文 map（可能为空）
%% @return 合并后的 map（两者皆空时返回空 map）
%% @end
%%--------------------------------------------------------------------
mergeCallContext(Explicit, Expanded)
  when map_size(Explicit) =:= 0, map_size(Expanded) =:= 0 ->
    #{};
mergeCallContext(Explicit, Expanded)
  when map_size(Explicit) =:= 0 ->
    Expanded;
mergeCallContext(Explicit, Expanded)
  when map_size(Expanded) =:= 0 ->
    Explicit;
mergeCallContext(Explicit, Expanded) ->
    maps:merge(Explicit, Expanded).

%%--------------------------------------------------------------------
%% @doc 归一化模块名：atom 原样，binary 转 existing atom，失败返回 undefined。
%% @end
%%--------------------------------------------------------------------
normalizeModule(M) when is_atom(M) -> M;
normalizeModule(M) when is_binary(M) ->
    try binary_to_existing_atom(M, utf8) catch _:_ -> undefined end;
normalizeModule(_) -> undefined.

%%--------------------------------------------------------------------
%% @doc 归一化函数名：atom 原样，binary 转 existing atom，失败返回 undefined。
%% @end
%%--------------------------------------------------------------------
normalizeAtom(A) when is_atom(A) -> A;
normalizeAtom(A) when is_binary(A) ->
    try binary_to_existing_atom(A, utf8) catch _:_ -> undefined end;
normalizeAtom(_) -> undefined.

%%--------------------------------------------------------------------
%% @doc 归一化元数：integer 原样，binary 转 integer，失败返回 undefined。
%% @end
%%--------------------------------------------------------------------
normalizeArity(A) when is_integer(A) -> A;
normalizeArity(A) when is_binary(A) ->
    try binary_to_integer(A) catch _:_ -> undefined end;
normalizeArity(_) -> undefined.

%%%===================================================================
%%% 运行时状态主动融合
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 运行时状态主动融合入口：
%% - `IncludeRuntime = true' 时返回完整 snapshot（向后兼容显式开启场景）
%% - 问题含 runtime 关键词（进程/ets/内存等，或 agent.json 业务词）时返回精简 snapshot
%%   并附加与命中模块相关的进程列表，让 LLM 看到"代码对应的活状态"
%% - 其它情况返回空 map，避免无谓的运行时噪声污染代码问答上下文
%%
%% 设计要点：
%% - alRuntimeProbe 调用全部 try/catch，避免 runtime 探测故障影响主流程
%% - 精简模式只保留关键指标 + top-5 进程 + top-5 ETS，避免上下文爆炸
%% - relevantProcesses 仅在命中模块数 ≤ ?MaxModulesForSymbols 时拉取，控制成本
%%
%% @param Question 用户问题
%% @param Modules 命中模块列表（用于过滤相关进程）
%% @param IncludeRuntime 是否显式开启完整 runtime
%% @return runtime map（可能为空）
%% @end
%%--------------------------------------------------------------------
fetchRuntime(Question, Modules, IncludeRuntime) when is_map(Question); is_binary(Question); is_list(Question) ->
    case IncludeRuntime of
        true ->
            try alRuntimeProbe:snapshot() catch _:_ -> #{} end;
        false ->
            case needsRuntime(Question) of
                false ->
                    #{};
                true ->
                    try
                        Snapshot = alRuntimeProbe:snapshot(),
                        Compact = compactRuntime(Snapshot),
                        case Modules of
                            [] -> Compact;
                            _ ->
                                Relevant = relevantProcesses(Snapshot, Modules),
                                case Relevant of
                                    [] -> Compact;
                                    _ -> Compact#{relevantProcesses => Relevant}
                                end
                        end
                    catch
                        _:_ -> #{}
                    end
            end
    end;
fetchRuntime(_, _, _) ->
    #{}.

%%--------------------------------------------------------------------
%% @doc
%% 检测问题是否需要 runtime 上下文。
%% 通用：进程/ETS/内存/节点等 BEAM 信号；业务词来自 `.ali/knowledge/agent.json`。
%% @end
%%--------------------------------------------------------------------
needsRuntime(Question) ->
    Q = string:lowercase(toBinary(Question)),
    Keywords = [
        <<"进程"/utf8>>, <<"ets"/utf8>>, <<"内存"/utf8>>,
        <<"监督"/utf8>>, <<"消息队列"/utf8>>, <<"运行时"/utf8>>,
        <<"快照"/utf8>>, <<"节点"/utf8>>,
        <<"process">>, <<"ets">>, <<"memory">>,
        <<"pid">>, <<"supervisor">>, <<"message_queue">>,
        <<"messagequeue">>, <<"reductions">>, <<"runtime">>, <<"snapshot">>,
        <<"node">>, <<"scheduler">>, <<"heap">>, <<"runqueue">>, <<"run_queue">>
    ] ++ projectLiveDataBins(),
    lists:any(fun(K) -> binary:match(Q, K) =/= nomatch end, Keywords).

projectLiveDataBins() ->
    try
        [unicode:characters_to_binary(K)
         || K <- alProjectDigest:liveDataKeywords() ++ alProjectDigest:liveDataOpKeywords()]
    catch _:_ ->
        []
    end.
%%--------------------------------------------------------------------
%% @doc
%% 压缩 runtime snapshot：仅保留关键指标，避免上下文爆炸。
%% - 节点信息、进程数、调度器数、run queue（核心负载指标）
%% - memory 仅保留 total/binary/process/ets 四项（其它省略）
%% - processesTop / etsTop 各取 top-5（默认 10 太多）
%% - supervisorTree 完整保留（异常节点数有限，结构信息对诊断有价值）
%%
%% @param Snapshot alRuntimeProbe:snapshot() 返回的完整 map
%% @return 精简后的 map
%% @end
%%--------------------------------------------------------------------
compactRuntime(Snapshot) when is_map(Snapshot) ->
    Memory0 = maps:get(memory, Snapshot, #{}),
    %% erlang:memory() 返回 proplists；alRuntimeProbe:snapshot() 直接透传。
    %% 这里归一化为 map 兼容两种形态。
    Memory = case is_list(Memory0) of
        true -> maps:from_list(Memory0);
        false -> Memory0
    end,
    CompactMemory = #{
        total => maps:get(total, Memory, 0),
        binary => maps:get(binary, Memory, 0),
        processes => maps:get(processes, Memory, 0),
        ets => maps:get(ets, Memory, 0)
    },
    Snapshot#{
        memory => CompactMemory,
        processesTop => lists:sublist(maps:get(processesTop, Snapshot, []), 5),
        etsTop => lists:sublist(maps:get(etsTop, Snapshot, []), 5)
    };
compactRuntime(_) ->
    #{}.

%%--------------------------------------------------------------------
%% @doc
%% 从 snapshot 的 processesTop 中筛选与命中模块相关的进程：
%% initial_call 或 current_function 的模块名匹配任一命中模块即视为相关。
%%
%% 仅筛选 snapshot 中已采集的 top 进程（避免触发全量 erlang:processes() 扫描），
%% 控制成本。LLM 如需更细可显式调 runtimeSnapshot 工具。
%%
%% @param Snapshot runtime 快照
%% @param Modules 命中模块列表（atom | binary | list）
%% @return 相关进程列表（保持原 map 结构）
%% @end
%%--------------------------------------------------------------------
relevantProcesses(Snapshot, Modules) when is_map(Snapshot), is_list(Modules) ->
    Procs = maps:get(processesTop, Snapshot, []),
    ModBins = [string:lowercase(toBinary(M)) || M <- Modules, M =/= undefined, M =/= null],
    case ModBins of
        [] ->
            [];
        _ ->
            [P || P <- Procs, processMatchesModules(P, ModBins)]
    end;
relevantProcesses(_, _) ->
    [].

%% 检查进程的 initial_call / current_function 是否命中任一模块名（小写前缀匹配）。
processMatchesModules(P, ModBins) ->
    Initial = mfaModule(maps:get(initial_call, P, undefined)),
    Current = mfaModule(maps:get(current_function, P, undefined)),
    matchesAny(Initial, ModBins) orelse matchesAny(Current, ModBins).

%% 从 {M,F,A} 元组或其它形式中提取模块名 binary（小写）。
mfaModule({M, _F, _A}) when is_atom(M) ->
    string:lowercase(atom_to_binary(M, utf8));
mfaModule(M) when is_atom(M) ->
    string:lowercase(atom_to_binary(M, utf8));
mfaModule(Tuple) when is_tuple(Tuple), tuple_size(Tuple) >= 1 ->
    case element(1, Tuple) of
        M when is_atom(M) -> string:lowercase(atom_to_binary(M, utf8));
        _ -> <<>>
    end;
mfaModule(_) ->
    <<>>.

%% 二进制前缀匹配：Needle 是否为任一 ModBin 的前缀（模块名可能带后缀如 foo_sup）。
matchesAny(<<>>, _ModBins) -> false;
matchesAny(Needle, ModBins) when is_binary(Needle) ->
    lists:any(fun(M) -> byte_size(M) > 0 andalso binary:match(Needle, M) =/= nomatch end, ModBins);
matchesAny(_, _) ->
    false.

%%%===================================================================
%%% 数据流/参数来源追踪（P2-7）
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 参数来源追踪：给定 M:F/A，分析其调用方传入参数的典型来源模式。
%%
%% 流程：
%% 1. {@link alCoreClient:getCallers/3} 拿调用方 edges
%% 2. 对每个调用方，用 {@link alCoreClient:moduleSymbols/1} 拿文件路径
%% 3. 读调用方源码，定位调用行，提取参数表达式片段
%% 4. {@link classifyParamSource/1} 按模式分类：
%%    - callerArgument: 直接透传调用方的入参（形如 `foo(Arg1)`）
%%    - etsLookup: 来自 ets:lookup/match 查询
%%    - config: 来自 alConfig:get/application:get_env
%%    - messageInput: 来自 receive 消息匹配
%%    - literal: 字面量（数字/二进制/list/record 构造）
%%    - computed: 计算表达式（其它情况）
%% 5. 聚合输出：callerCount、各来源类型计数、典型 hint
%%
%% @param Module 模块名
%% @param Function 函数名
%% @param Arity 元数
%% @return #{targetMfa, callerCount, sourceCounts, hints, sampledCallers}
%% @end
%%--------------------------------------------------------------------
paramSourceHints(Module, Function, Arity) ->
    case safeGetCallers(Module, Function, Arity) of
        [] ->
            #{targetMfa => {Module, Function, Arity}, callerCount => 0,
              sourceCounts => #{}, hints => [], sampledCallers => []};
        CallerEdges ->
            Analyzed = lists:filtermap(fun analyzeCallerEdge/1, CallerEdges),
            {SourceCounts, Hints} = aggregateSources(Analyzed),
            #{targetMfa => {Module, Function, Arity},
              callerCount => length(CallerEdges),
              sourceCounts => SourceCounts,
              hints => Hints,
              sampledCallers => lists:sublist(Analyzed, ?MaxExpandHits)}
    end.

%% 安全调用 getCallers：失败/异常返回空。
safeGetCallers(Module, Function, Arity) ->
    try alCoreClient:getCallers(Module, Function, Arity) of
        {ok, #{data := #{edges := Edges}}} when is_list(Edges) -> Edges;
        {ok, #{data := Data}} when is_map(Data) ->
            maps:get(edges, Data, []);
        _ -> []
    catch _:_ -> []
    end.

%% 分析单个 caller edge：拿调用方文件 + 调用行，提取参数表达式并分类。
analyzeCallerEdge(Edge) when is_map(Edge) ->
    CallerMod = maps:get(from_module, Edge, maps:get(<<"from_module">>, Edge, undefined)),
    CallerFun = maps:get(from_function, Edge, maps:get(<<"from_function">>, Edge, undefined)),
    CallerArity = maps:get(from_arity, Edge, maps:get(<<"from_arity">>, Edge, undefined)),
    Line = maps:get(line, Edge, maps:get(<<"line">>, Edge, undefined)),
    case CallerMod =:= undefined orelse CallerFun =:= undefined of
        true -> false;
        false ->
            ArgSnippet = readCallSiteSnippet(CallerMod, Line),
            SourceType = case ArgSnippet of
                <<>> -> unknown;
                _ -> classifyParamSource(ArgSnippet)
            end,
            {true, #{
                caller => {CallerMod, CallerFun, CallerArity},
                line => Line,
                snippet => ArgSnippet,
                sourceType => SourceType
            }}
    end;
analyzeCallerEdge(_) ->
    false.

%% 读取调用方源码中调用点附近片段（line ± 2 行），用于参数来源分类。
%% 无法读取时返回 <<>>。
readCallSiteSnippet(CallerMod, Line) when is_integer(Line), Line > 0 ->
    try alCoreClient:moduleSymbols(CallerMod) of
        {ok, #{data := #{document := Doc}}} when is_map(Doc) ->
            File = maps:get(file, Doc, maps:get(<<"file">>, Doc, undefined)),
            readSnippetFromFile(File, Line);
        _ -> <<>>
    catch _:_ -> <<>>
    end;
readCallSiteSnippet(_, _) ->
    <<>>.

%% 从文件读取指定行号附近的代码片段（line-2 到 line+2）。
readSnippetFromFile(File, Line) when is_binary(File); is_list(File) ->
    Path = toList(File),
    case file:read_file(Path) of
        {ok, Bin} ->
            Lines = binary:split(Bin, <<"\n">>, [global]),
            Start = max(1, Line - 2),
            End = min(length(Lines), Line + 2),
            SnippetLines = lists:sublist(Lines, Start, End - Start + 1),
            unicode:characters_to_binary(string:join([binary_to_list(L) || L <- SnippetLines], "\n"));
        _ -> <<>>
    end;
readSnippetFromFile(_, _) ->
    <<>>.

%%--------------------------------------------------------------------
%% @doc
%% 按模式分类参数来源：扫描 snippet 中的调用表达式，识别典型来源模式。
%%
%% @param Snippet 调用点附近的源码片段
%% @return callerArgument | etsLookup | config | messageInput | literal | computed | unknown
%% @end
%%--------------------------------------------------------------------
classifyParamSource(Snippet) when is_binary(Snippet) ->
    S = string:lowercase(Snippet),
    CondList = [
        {fun matchesPattern/2, <<"ets:lookup">>, etsLookup},
        {fun matchesPattern/2, <<"ets:match">>, etsLookup},
        {fun matchesPattern/2, <<"ets:foldl">>, etsLookup},
        {fun matchesPattern/2, <<"ets:foldr">>, etsLookup},
        {fun matchesPattern/2, <<"alconfig:get">>, config},
        {fun matchesPattern/2, <<"application:get_env">>, config},
        {fun matchesPattern/2, <<"persistent_term:get">>, config},
        {fun matchesPattern/2, <<"receive">>, messageInput},
        {fun matchesPattern/2, <<"#">>, literal},
        {fun matchesPattern/2, <<"<<\"">>, literal}
    ],
    case lists:filtermap(fun({Pred, Pattern, Type}) ->
        case Pred(S, Pattern) of true -> {true, Type}; false -> false end
    end, CondList) of
        [Type | _] -> Type;
        [] ->
            %% 没有特殊模式：检查是否纯变量名（首字母大写）
            %% 注意要在原始 snippet 中查找，因为变量名大小写敏感
            case re:run(Snippet, <<"[A-Z][a-zA-Z0-9_]*">>, [{capture, none}]) of
                match -> callerArgument;
                _ -> computed
            end
    end;
classifyParamSource(_) ->
    unknown.

matchesPattern(S, Pattern) ->
    binary:match(S, Pattern) =/= nomatch.

%% 聚合各调用方的参数来源分类，输出计数与 hint 列表。
aggregateSources(Analyzed) ->
    Counts = lists:foldl(fun(#{sourceType := T}, Acc) ->
        maps:update_with(T, fun(V) -> V + 1 end, 1, Acc)
    end, #{}, Analyzed),
    Hints = buildSourceHints(Counts, length(Analyzed)),
    {Counts, Hints}.

%% 根据来源分类计数生成人类可读 hint，帮助 LLM 理解参数数据流。
buildSourceHints(Counts, Total) when Total > 0 ->
    Sorted = lists:sort(fun({_, A}, {_, B}) -> A >= B end, maps:to_list(Counts)),
    TopType = case Sorted of
        [{T, _} | _] -> T;
        [] -> unknown
    end,
    Percent = case maps:get(TopType, Counts, 0) of
        0 -> 0;
        V -> round(V * 100 / Total)
    end,
    Hint = case TopType of
        callerArgument ->
            <<"参数主要来自调用方入参透传（数据流上游传递）"/utf8>>;
        etsLookup ->
            iolist_to_binary([<<"参数主要来自 ETS 查询（约"/utf8>>,
                              integer_to_binary(Percent), <<"%）"/utf8>>]);
        config ->
            <<"参数主要来自配置（alConfig/application env）"/utf8>>;
        messageInput ->
            <<"参数主要来自 receive 消息（外部输入）"/utf8>>;
        literal ->
            <<"参数多为字面量（调用方硬编码）"/utf8>>;
        computed ->
            <<"参数多为计算表达式（动态构造）"/utf8>>;
        unknown ->
            <<"参数来源未能识别（可能是复杂表达式）"/utf8>>
    end,
    [Hint];
buildSourceHints(_, _) ->
    [].

%%--------------------------------------------------------------------
%% @doc
%% 检测问题是否需要数据流分析：扫描中英文关键词。
%% 触发词：参数来源、数据流、哪里来、传入、调用方、parameter source、data flow。
%%
%% @param Question 用户问题
%% @return boolean()
%% @end
%%--------------------------------------------------------------------
needsDataFlow(Question) ->
    Q = string:lowercase(toBinary(Question)),
    Keywords = [
        %% 参数/数据流分析
        <<"参数来源"/utf8>>, <<"数据流"/utf8>>, <<"哪里来"/utf8>>,
        <<"传入"/utf8>>, <<"调用方"/utf8>>, <<"怎么来的"/utf8>>,
        <<"parameter source">>, <<"data flow">>, <<"dataflow">>,
        <<"where does">>, <<"caller">>, <<"argument">>,
        <<"trace data">>, <<"data source">>,
        %% 自然语言「查 XX 数据 / 调用链」——对应 data-flow-trace skill
        <<"查一下"/utf8>>, <<"查询"/utf8>>, <<"怎么查"/utf8>>,
        <<"怎么得到"/utf8>>, <<"数据从哪"/utf8>>, <<"从哪来"/utf8>>,
        <<"调用链"/utf8>>, <<"前置函数"/utf8>>, <<"需要先调"/utf8>>,
        <<"查数据"/utf8>>, <<"字段从哪"/utf8>>, <<"ets"/utf8>>,
        <<"mnesia"/utf8>>
    ],
    lists:any(fun(K) -> binary:match(Q, K) =/= nomatch end, Keywords).

%% 首轮上下文注入：命中数据查询意图时跑 traceDataQuery，失败则静默跳过。
maybeFetchDataQuery(Question, Opts) ->
    case needsDataFlow(Question) of
        false ->
            undefined;
        true ->
            emitContextProgress(Opts, <<"building context: data-flow query...">>),
            try
                TraceOpts = maps:with([maxDepth, maxNodes], Opts),
                compactDataQuery(traceDataQuery(Question, TraceOpts))
            catch _:_ ->
                undefined
            end
    end.

%% 压缩 traceDataQuery 结果，避免把整棵 DAG/caller 列表塞进首轮上下文。
compactDataQuery(Result) when is_map(Result) ->
    Candidates = [compactDataCandidate(C)
                  || C <- lists:sublist(maps:get(candidates, Result, []), 5)],
    #{
        confidence => maps:get(confidence, Result, none),
        nouns => maps:get(nouns, Result, []),
        candidates => Candidates,
        clarifyPrompt => maps:get(clarifyPrompt, Result, undefined),
        dagSummary => compactDagSummary(maps:get(dag, Result, undefined)),
        hint => maps:get(hint, Result, <<>>)
    };
compactDataQuery(_) ->
    undefined.

compactDataCandidate(#{target := {mfa, M, F, A}} = C) ->
    #{
        mfa => iolist_to_binary(io_lib:format("~s:~s/~w", [M, F, A])),
        table => maps:get(table, C, <<>>),
        score => maps:get(score, C, 0.0),
        reason => maps:get(reason, C, <<>>)
    };
compactDataCandidate(C) when is_map(C) ->
    maps:with([table, score, reason, target], C);
compactDataCandidate(Other) ->
    Other.

compactDagSummary(undefined) -> undefined;
compactDagSummary(#{nodes := Nodes}) when is_list(Nodes) ->
    #{
        nodeCount => length(Nodes),
        mfas => lists:sublist([maps:get(mfa, N, <<>>) || N <- Nodes], 12)
    };
compactDagSummary(_) -> undefined.

%% 若已构建 Project Digest，按问题检索知识片段 + 动作词典建议。
maybeFetchKnowledge(Question, Opts) ->
    case alProjectDigest:loadMeta() of
        undefined ->
            undefined;
        {ok, _} ->
            emitContextProgress(Opts, <<"building context: project knowledge...">>),
            try
                Limit = maps:get(knowledgeLimit, Opts, 6),
                {ok, Hits} = alProjectDigest:search(Question, Limit),
                {ok, Actions} = alProjectDigest:lookupAction(Question),
                case {Hits, Actions} of
                    {[], []} -> undefined;
                    _ ->
                        #{
                            hits => Hits,
                            suggestedActions => lists:sublist(Actions, 5)
                        }
                end
            catch _:_ ->
                undefined
            end
    end.

%%%===================================================================
%%% 符号引用图（跨文件 record/macro/函数引用，P2-9）
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 跨文件符号引用查找：给定符号名 + 类型，返回所有引用位置。
%%
%% 利用 {@link alCoreClient:search/2} 拿到包含该符号的命中文件，
%% 然后从 hit 的 records/macros/functions 字段中提取具体引用位置。
%%
%% @param Name 符号名（atom/binary/list）
%% @param Kind record | macro | function
%% @return [{file, module, line, kind, name}] 引用位置列表
%% @end
%%--------------------------------------------------------------------
findReferences(Name, Kind) ->
    findReferences(Name, Kind, 30).

%%--------------------------------------------------------------------
%% @doc
%% 带命中上限的引用查找：默认 Limit=30，避免大型项目返回过多。
%%
%% @param Name 符号名
%% @param Kind record | macro | function
%% @param Limit 命中上限
%% @return [{file, module, line, kind, name}] 引用位置列表
%% @end
%%--------------------------------------------------------------------
findReferences(Name, Kind, Limit) when is_integer(Limit), Limit > 0 ->
    case isReferenceKind(Kind) of
        false ->
            [];
        true ->
            NameBin = toBinary(Name),
            case alCoreClient:search(NameBin, Limit) of
                {ok, #{data := #{hits := Hits}}} when is_list(Hits) ->
                    lists:flatmap(fun(Hit) ->
                        extractReferencesFromHit(Hit, NameBin, Kind)
                    end, Hits);
                {ok, #{data := Data}} when is_map(Data) ->
                    Hits = maps:get(hits, Data, []),
                    lists:flatmap(fun(Hit) ->
                        extractReferencesFromHit(Hit, NameBin, Kind)
                    end, Hits);
                _ ->
                    []
            end
    end;
findReferences(_, _, _) ->
    [].

%%--------------------------------------------------------------------
%% @doc
%% 判定 Kind 是否为合法的引用类型：record/macro/function。
%%
%% @param Kind 待校验类型
%% @return boolean()
%% @end
%%--------------------------------------------------------------------
isReferenceKind(record) -> true;
isReferenceKind(macro) -> true;
isReferenceKind(function) -> true;
isReferenceKind(<<"record">>) -> true;
isReferenceKind(<<"macro">>) -> true;
isReferenceKind(<<"function">>) -> true;
isReferenceKind(_) -> false.

%%--------------------------------------------------------------------
%% @doc
%% 从单个搜索命中提取匹配 Name/Kind 的引用位置：
%% - record：从 hit.records 中找 name 匹配的条目
%% - macro：从 hit.macros 中找 name 匹配的条目
%% - function：从 hit.functions 中找 name 匹配的条目
%%
%% @param Hit 搜索命中 map（含 records/macros/functions 字段）
%% @param Name 待查找符号名（binary，大小写敏感）
%% @param Kind record | macro | function
%% @return [{file, module, line, kind, name}] 引用位置列表
%% @end
%%--------------------------------------------------------------------
extractReferencesFromHit(Hit, Name, Kind) when is_map(Hit), is_binary(Name) ->
    File = maps:get(file, Hit, maps:get(<<"file">>, Hit, undefined)),
    Module = maps:get(module, Hit, maps:get(<<"module">>, Hit, undefined)),
    FieldKey = case normalizeKind(Kind) of
        record -> records;
        macro -> macros;
        function -> functions;
        _ -> undefined
    end,
    case FieldKey of
        undefined ->
            [];
        _ ->
            Entries = maps:get(FieldKey, Hit, maps:get(atom_to_binary(FieldKey, utf8), Hit, [])),
            case is_list(Entries) of
                false -> [];
                true ->
                    lists:filtermap(fun(E) ->
                        case entryMatches(E, Name) of
                            {true, Line} ->
                                {true, #{
                                    file => File,
                                    module => Module,
                                    line => Line,
                                    kind => normalizeKind(Kind),
                                    name => Name
                                }};
                            false ->
                                false
                        end
                    end, Entries)
            end
    end;
extractReferencesFromHit(_, _, _) ->
    [].

%% 归一化 Kind 为 atom。
normalizeKind(record) -> record;
normalizeKind(macro) -> macro;
normalizeKind(function) -> function;
normalizeKind(<<"record">>) -> record;
normalizeKind(<<"macro">>) -> macro;
normalizeKind(<<"function">>) -> function;
normalizeKind(_) -> undefined.

%% 检查单条 record/macro/function 条目是否匹配 Name，匹配时返回 {true, Line}。
entryMatches(E, Name) when is_map(E) ->
    EName = maps:get(name, E, maps:get(<<"name">>, E, undefined)),
    Line = maps:get(line, E, maps:get(<<"line">>, E, undefined)),
    case namesEqual(EName, Name) of
        true -> {true, Line};
        false -> false
    end;
entryMatches(_, _) ->
    false.

%% 名称相等判定：atom/binary/list 互通比较（大小写敏感）。
namesEqual(A, B) when is_atom(A), is_atom(B) -> A =:= B;
namesEqual(A, B) when is_atom(A), is_binary(B) -> atom_to_binary(A, utf8) =:= B;
namesEqual(A, B) when is_binary(A), is_atom(B) -> A =:= atom_to_binary(B, utf8);
namesEqual(A, B) when is_binary(A), is_binary(B) -> A =:= B;
namesEqual(A, B) when is_list(A), is_binary(B) -> unicode:characters_to_binary(A) =:= B;
namesEqual(A, B) when is_binary(A), is_list(B) -> A =:= unicode:characters_to_binary(B);
namesEqual(_, _) -> false.

%%%===================================================================
%%% 数据查询链路推断（traceDataQuery，P3 数据流推断核心）
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 数据查询链路推断：从自然语言问题推断「查询某数据所需的函数调用链」。
%%
%% 设计哲学（用户要求）：
%% - 不依赖函数命名规范（get*/query*/handle* 等前缀搜索）
%% - 纯靠代码上下文与数据流静态分析推断
%% - 推不出时主动反问用户给提示（比乱猜好）
%%
%% 流程：
%% 1. 从问题中提取数据名词候选（中文 token + 英文 noun）
%% 2. 在数据源索引里按表名/函数名做语义近似匹配，找出 candidate targets
%% 3. 对 top-1 candidate 跑 traceDataFlow，构建参数依赖 DAG
%% 4. 评估置信度：candidate 数量、DAG 节点数、是否有 Unknown 节点
%% 5. 低置信度时返回 clarifyPrompt，列出可选表/函数让用户给提示
%%
%% @param Question 用户问题（binary/list/atom）
%% @param Opts 可选参数：#{maxDepth => pos_integer(), maxNodes => pos_integer()}
%% @return #{
%%   question => binary(),
%%   nouns => [binary()],
%%   candidates => [#{table, callers, score}],
%%   confidence => high | medium | low | none,
%%   dag => DataFlowTrace | undefined,
%%   clarifyPrompt => binary() | undefined,
%%   hint => binary()
%% }
%% @end
%%--------------------------------------------------------------------
traceDataQuery(Question, Opts) when is_map(Opts) ->
    QBin = toBinary(Question),
    %% 1. 提取数据名词候选
    Nouns = extractDataNouns(QBin),
    %% 2. 锚定优先：问题含 @table:xxx 或 @mfa:M:F/A 时直接用
    Anchor = parseDataQueryAnchor(QBin),
    %% 3. 找数据源候选
    Candidates = case Anchor of
        #{table := T} ->
            %% 显式锚定表名：只查这个表
            findDataSourceCandidates([T], explicit);
        #{mfa := {M, F, A}} ->
            %% 显式锚定 MFA：构造直接 candidate
            [#{target => {mfa, M, F, A}, table => <<>>, callers => [], score => 1.0,
               reason => <<"explicit mfa anchor"/utf8>>}];
        _ ->
            %% 无锚定：用数据名词匹配
            findDataSourceCandidates(Nouns, fuzzy)
    end,
    %% 4. 选 top-1 candidate 跑 traceDataFlow
    {Confidence, Dag, TraceError} = runTraceForTopCandidate(Candidates, Opts),
    %% 5. 低置信度时构造追问 prompt
    ClarifyPrompt = case Confidence of
        low -> buildClarifyPrompt(Candidates);
        none -> buildClarifyPrompt(Candidates);
        _ -> undefined
    end,
    #{
        question => QBin,
        nouns => Nouns,
        candidates => Candidates,
        confidence => Confidence,
        dag => Dag,
        traceError => TraceError,
        clarifyPrompt => ClarifyPrompt,
        hint => <<"数据流推断：基于代码上下文（ets/mnesia/sql 调用点 + use-def chain），"
                  "不依赖命名规范。低置信度时请用户给提示（表名/MFA/数据名词）。"/utf8>>
    }.

%%--------------------------------------------------------------------
%% @doc
%% 从自然语言问题中提取数据名词候选。
%%
%% 策略：
%% - 中文：连续汉字片段（>= 2 字）
%% - 英文：连续字母片段（>= 3 字，过滤停用词）
%% - 过滤常见停用词（the/what/how/where/怎么/什么/哪里/查询/调用 等）
%%
%% @param Question 用户问题
%% @return [binary()] 数据名词列表（去重）
%% @end
%%--------------------------------------------------------------------
extractDataNouns(Question) ->
    QBin = toBinary(Question),
    %% 中文片段：连续汉字
    CnTokens = case re:run(QBin, <<"[\x{4e00}-\x{9fa5}]{2,}"/utf8>>, [global, {capture, all, binary}]) of
        {match, Captured} -> lists:flatten(Captured);
        nomatch -> []
    end,
    %% 英文 token：字母序列
    EnTokens = case re:run(QBin, <<"[A-Za-z][A-Za-z0-9_]{2,}">>, [global, {capture, all, binary}]) of
        {match, CapturedEn} -> lists:flatten(CapturedEn);
        nomatch -> []
    end,
    AllTokens = CnTokens ++ [T || T <- EnTokens, not isStopWord(T)],
    lists:usort(AllTokens).

%% 停用词集合：过滤掉无信息量的通用词
isStopWord(W) ->
    Stop = [
        <<"the">>, <<"what">>, <<"how">>, <<"where">>, <<"which">>, <<"why">>,
        <<"who">>, <<"when">>, <<"from">>, <<"with">>, <<"that">>, <<"this">>,
        <<"for">>, <<"are">>, <<"was">>, <<"were">>, <<"have">>, <<"has">>,
        <<"does">>, <<"did">>, <<"can">>, <<"could">>, <<"would">>, <<"should">>,
        <<"get">>, <<"set">>, <<"put">>, <<"let">>, <<"run">>, <<"call">>,
        <<"use">>, <<"used">>, <<"using">>, <<"make">>, <<"made">>, <<"out">>,
        <<"into">>, <<"onto">>, <<"over">>, <<"under">>, <<"about">>, <<"than">>,
        %% 中文停用词
        <<"怎么"/utf8>>, <<"什么"/utf8>>, <<"哪里"/utf8>>, <<"哪个"/utf8>>,
        <<"如何"/utf8>>, <<"为何"/utf8>>, <<"为何"/utf8>>, <<"是否"/utf8>>,
        <<"查询"/utf8>>, <<"调用"/utf8>>, <<"代码"/utf8>>, <<"函数"/utf8>>,
        <<"模块"/utf8>>, <<"实现"/utf8>>, <<"过程"/utf8>>, <<"现在"/utf8>>,
        <<"目前"/utf8>>, <<"当前"/utf8>>, <<"今天"/utf8>>, <<"昨天"/utf8>>
    ],
    lists:member(string:lowercase(W), Stop).

%%--------------------------------------------------------------------
%% @doc
%% 解析数据查询锚定：@table:foo_tab / @mfa:Mod:fun/arity
%%
%% @param Question 用户问题
%% @return #{table => binary()} | #{mfa => {M, F, A}} | #{}
%% @end
%%--------------------------------------------------------------------
parseDataQueryAnchor(Question) ->
    Bin = toBinary(Question),
    case re:run(Bin, <<"(?i)@table\\s*:?\\s*([a-zA-Z][a-zA-Z0-9_]*)">>,
                [{capture, all_but_first, binary}]) of
        {match, [Tab]} ->
            #{table => Tab};
        nomatch ->
            case re:run(Bin, <<"(?i)@mfa\\s*:?\\s*([a-z][a-zA-Z0-9_]*)\\s*:\\s*"
                               "([a-z][a-zA-Z0-9_]*)\\s*/\\s*(\\d+)">>,
                        [{capture, all_but_first, binary}]) of
                {match, [M, F, ABin]} ->
                    try
                        MAtom = binary_to_existing_atom(M, utf8),
                        FAtom = binary_to_existing_atom(F, utf8),
                        Arity = binary_to_integer(ABin),
                        #{mfa => {MAtom, FAtom, Arity}}
                    catch _:_ -> #{} end;
                nomatch -> #{}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 在数据源索引里按数据名词找候选目标函数。
%%
%% 策略：
%% - 全量拉取 data sources（ets/mnesia/sql 调用点）
%% - 对每个数据名词，找表名包含该名词的调用点（大小写不敏感子串匹配）
%% - 也匹配 caller_function 名（用户问题里的名词可能是函数名一部分）
%% - 按匹配数打分，去重排序
%%
%% @param Nouns 数据名词列表
%% @param Mode explicit | fuzzy（影响匹配策略）
%% @return [#{target => {mfa,M,F,A}|{table,T}, table, callers, score, reason}]
%% @end
%%--------------------------------------------------------------------
findDataSourceCandidates(Nouns, Mode) when is_list(Nouns) ->
    case safeDataSources() of
        [] ->
            [];
        Sources ->
            NounsLower = [string:lowercase(toBinary(N)) || N <- Nouns],
            %% 按 caller MFA 聚合匹配分
            Matches = aggregateDataSourceMatches(Sources, NounsLower, Mode),
            %% 按分降序，取 top-5
            Sorted = lists:sort(fun(#{score := A}, #{score := B}) -> A >= B end, Matches),
            lists:sublist(Sorted, 5)
    end.

%% 安全拉取 data sources：core 不可用/出错时返回空。
safeDataSources() ->
    try alCoreClient:dataSources() of
        {ok, #{data := #{sources := Srcs}}} when is_list(Srcs) -> Srcs;
        {ok, #{data := Data}} when is_map(Data) ->
            maps:get(sources, Data, []);
        _ -> []
    catch _:_ -> []
    end.

%% 聚合数据源匹配：对每个 caller MFA 统计匹配分
aggregateDataSourceMatches(Sources, NounsLower, Mode) ->
    %% 把 sources 按 caller MFA 分组
    Grouped = groupByCaller(Sources),
    lists:filtermap(fun({CallerMfa, Calls}) ->
        Score = scoreCaller(CallerMfa, Calls, NounsLower, Mode),
        case Score > 0 of
            true ->
                Tables = lists:usort([toBinary(maps:get(table, C, <<>>)) || C <- Calls,
                                                                          C =/= <<>>]),
                {M, F, A} = CallerMfa,
                {true, #{
                    target => {mfa, M, F, A},
                    table => case Tables of [T | _] -> T; _ -> <<>> end,
                    callers => Calls,
                    score => Score,
                    reason => case Mode of
                        explicit -> <<"explicit table match"/utf8>>;
                        fuzzy -> <<"fuzzy noun match"/utf8>>
                    end
                }};
            false ->
                false
        end
    end, Grouped).

%% 按 caller MFA 分组
groupByCaller(Sources) ->
    Dict = lists:foldl(fun(Src, Acc) ->
        CallerMod = maps:get(caller_module, Src, maps:get(<<"caller_module">>, Src, undefined)),
        CallerFun = maps:get(caller_function, Src, maps:get(<<"caller_function">>, Src, <<>>)),
        CallerArity = maps:get(caller_arity, Src, maps:get(<<"caller_arity">>, Src, 0)),
        Key = mfaKey(CallerMod, CallerFun, CallerArity),
        maps:update_with(Key, fun(L) -> [Src | L] end, [Src], Acc)
    end, #{}, Sources),
    maps:to_list(Dict).

%% 计算 caller MFA 的匹配分：表名匹配 + 函数名匹配
scoreCaller(CallerMfaTuple, Calls, NounsLower, Mode) ->
    %% 表名得分
    TableScore = lists:foldl(fun(C, Acc) ->
        Tab = toBinary(maps:get(table, C, maps:get(<<"table">>, C, <<>>))),
        case Tab of
            <<>> -> Acc;
            _ ->
                TabLower = string:lowercase(Tab),
                case anyNounMatches(NounsLower, TabLower) of
                    true -> Acc + 2.0;  %% 表名匹配权重高
                    false -> Acc
                end
        end
    end, 0.0, Calls),
    %% 函数名得分
    {_M, FunName, _A} = CallerMfaTuple,
    FunBin = string:lowercase(toBinary(FunName)),
    FunScore = case FunBin of
        <<>> -> 0.0;
        _ ->
            case anyNounMatches(NounsLower, FunBin) of
                true -> 1.0;
                false -> 0.0
            end
    end,
    %% explicit 模式：必须有表名匹配
    case Mode of
        explicit -> case TableScore > 0 of true -> TableScore + FunScore; false -> 0.0 end;
        fuzzy -> TableScore + FunScore
    end.

%% 检查 noun 是否为 target 的子串（双向，覆盖 player/role 互转场景）
anyNounMatches([], _Target) -> false;
anyNounMatches([N | Rest], Target) ->
    case binary:match(Target, N) =/= nomatch orelse binary:match(N, Target) =/= nomatch of
        true -> true;
        false -> anyNounMatches(Rest, Target)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 对 top-1 candidate 跑 traceDataFlow，构建参数依赖 DAG。
%%
%% @param Candidates 候选列表
%% @param Opts traceDataFlow 选项
%% @return {Confidence, Dag | undefined, TraceError | undefined}
%% @end
%%--------------------------------------------------------------------
runTraceForTopCandidate([], _Opts) ->
    {none, undefined, undefined};
runTraceForTopCandidate([Top | _], Opts) ->
    case maps:get(target, Top, undefined) of
        {mfa, M, F, A} ->
            %% 对 top-1 candidate 的第 1 个参数跑 trace
            case safeTraceDataFlow(M, F, A, 1, Opts) of
                {ok, Dag} ->
                    Confidence = confidenceOf(Dag),
                    {Confidence, Dag, undefined};
                {error, Reason} ->
                    {low, undefined, Reason}
            end;
        _ ->
            {low, undefined, <<"target is not an MFA"/utf8>>}
    end.

%% 安全调用 traceDataFlow：core 不可用/出错时返回 {error, Reason}。
safeTraceDataFlow(M, F, A, ParamIdx, Opts) ->
    try alCoreClient:traceDataFlow(M, F, A, ParamIdx, Opts) of
        {ok, #{data := Dag}} when is_map(Dag) -> {ok, Dag};
        {ok, #{data := Data}} when is_map(Data) -> {ok, Data};
        {error, Reason} -> {error, Reason}
    catch
        Class:Reason -> {error, #{class => Class, reason => Reason}}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 评估数据流推断的置信度。
%%
%% 规则：
%% - DAG 为空 / 无节点 → none
%% - 节点数 1（只有根节点，无 caller）→ low
%% - 节点数 2-5 且无 Unknown → high
%% - 节点数 2-5 含 Unknown → medium
%% - 节点数 >5 含 Unknown 占比 >50% → medium
%% - 节点数 >5 无/少 Unknown → high
%%
%% @param Dag DataFlowTrace map
%% @return high | medium | low | none
%% @end
%%--------------------------------------------------------------------
confidenceOf(undefined) -> none;
confidenceOf(#{nodes := Nodes}) when not is_list(Nodes); Nodes =:= [] -> none;
confidenceOf(#{nodes := [_Root]}) -> low;  %% 只有根节点，无 caller
confidenceOf(#{nodes := Nodes}) when is_list(Nodes) ->
    Total = length(Nodes),
    UnknownCount = lists:foldl(fun(N, Acc) ->
        case maps:get(source, N, undefined) of
            #{kind := Kind} when Kind =:= <<"unknown">>; Kind =:= unknown -> Acc + 1;
            undefined -> Acc + 1;  %% 无 source 视为未知
            _ -> Acc
        end
    end, 0, Nodes),
    UnknownRatio = UnknownCount / Total,
    if
        UnknownCount =:= 0 -> high;
        UnknownRatio < 0.3 -> high;
        UnknownRatio < 0.6 -> medium;
        true -> medium
    end;
confidenceOf(_) -> none.

%%--------------------------------------------------------------------
%% @doc
%% 构造追问 prompt：列出可选表/函数让用户给提示。
%%
%% @param Candidates 候选列表
%% @return binary() 追问 prompt
%% @end
%%--------------------------------------------------------------------
buildClarifyPrompt(Candidates) when is_list(Candidates) ->
    Tables = lists:usort([T || #{table := T} <- Candidates, T =/= undefined, T =/= <<>>]),
    Mfas = [Mfa || #{target := Mfa} <- Candidates],
    Prompt = case {Tables, Mfas} of
        {[], []} ->
            <<"未找到匹配的数据源候选。请提供更具体的提示：\n"
              "1. 该数据存储在哪个 ETS/Mnesia 表？（用 @table:表名 锚定）\n"
              "2. 或直接给出查询入口 MFA（用 @mfa:Mod:fun/arity 锚定）\n"
              "3. 或描述数据的相关名词（如表名片段、字段名、模块名等）"/utf8>>;
        {_, _} ->
            TabBin = string:join([binary_to_list(T) || T <- lists:sublist(Tables, 10)], ", "),
            MfaBin = string:join([formatMfa(M) || M <- lists:sublist(Mfas, 10)], ", "),
            iolist_to_binary([
                <<"找到以下候选数据源，但置信度不足。请确认：\n"/utf8>>,
                <<"匹配的表名："/utf8>>, TabBin, <<"\n"/utf8>>,
                <<"匹配的函数："/utf8>>, MfaBin, <<"\n"/utf8>>,
                <<"请回复：\n"/utf8>>,
                <<"  - @table:确切表名  锚定到某个表\n"/utf8>>,
                <<"  - @mfa:Mod:fun/arity  锚定到某个 MFA\n"/utf8>>,
                <<"  - 或补充数据的相关名词（字段名、业务术语等）"/utf8>>
            ])
    end,
    Prompt.

formatMfa({mfa, M, F, A}) when is_atom(M), is_atom(F), is_integer(A) ->
    lists:flatten(io_lib:format("~p:~p/~p", [M, F, A]));
formatMfa({M, F, A}) when is_atom(M), is_atom(F), is_integer(A) ->
    lists:flatten(io_lib:format("~p:~p/~p", [M, F, A]));
formatMfa(Other) ->
    lists:flatten(io_lib:format("~p", [Other])).

%% MFA key 工具函数：归一化 module/function 为 atom，构造 {M, F, Arity} 元组。
mfaKey(Module, Function, Arity) ->
    M = case Module of
        undefined -> undefined;
        _ when is_atom(Module) -> Module;
        _ when is_binary(Module) ->
            try binary_to_existing_atom(Module, utf8) catch _:_ -> Module end;
        _ -> Module
    end,
    F = case Function of
        _ when is_atom(Function) -> Function;
        _ when is_binary(Function) ->
            try binary_to_existing_atom(Function, utf8) catch _:_ -> Function end;
        _ -> Function
    end,
    {M, F, Arity}.

%%%===================================================================
%%% Git 新鲜度加权
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Git 新鲜度加权：对命中列表里属于最近 git 变更集合的文件，score 乘以
%% ?GitBoostFactor 并打上 `gitBoosted' 标记，然后按新 score 降序重排。
%%
%% RecentSet 为空（非 git 仓库/git 不可用）时原样返回，不影响排序。
%% 大型项目里"最近改的代码"往往与当前问题最相关，加权后 LLM 优先看到。
%%
%% @param Hits 命中列表
%% @param RecentSet ordsets:ordset(string()) 最近变更文件归一化路径
%% @return 加权重排后的命中列表
%% @end
%%--------------------------------------------------------------------
boostByGitFreshness(Hits, RecentSet) when is_list(Hits) ->
    case ordsets:size(RecentSet) of
        0 ->
            Hits;
        _ ->
            Boosted = [boostHit(Hit, RecentSet) || Hit <- Hits],
            lists:sort(fun(A, B) ->
                maps:get(score, A, 0) >= maps:get(score, B, 0)
            end, Boosted)
    end;
boostByGitFreshness(Hits, _) ->
    Hits.

%%--------------------------------------------------------------------
%% @doc
%% 对单个命中做 Git 加权：文件在最近变更集合里则 score * ?GitBoostFactor
%% 并打 `gitBoosted => true' 标记。纯函数，便于测试。
%% @end
%%--------------------------------------------------------------------
boostHit(Hit, RecentSet) when is_map(Hit) ->
    case isRecentFile(maps:get(file, Hit, undefined), RecentSet) of
        true ->
            Score = maps:get(score, Hit, 0),
            Hit#{score => Score * ?GitBoostFactor, gitBoosted => true};
        false ->
            Hit
    end;
boostHit(Hit, _) ->
    Hit.

%%--------------------------------------------------------------------
%% @doc
%% 判断文件是否在最近变更集合里：归一化路径后 ordsets 查询。
%% @end
%%--------------------------------------------------------------------
isRecentFile(undefined, _RecentSet) ->
    false;
isRecentFile(File, RecentSet) ->
    Norm = alVcsIndex:normalizePath(File),
    ordsets:is_element(Norm, RecentSet).

%% 短项目大纲：projectRoot 下一层目录 + 索引就绪提示。
%% 注意：不要在这里同步调 ali:ready()/indexStatus——后台索引时会堵在
%% Port 上，网页一直停在 worker started，同时 aliCore 单核打满像「死循环」。
projectOutline() ->
    Root = try alConfig:projectRoot() catch _:_ -> "." end,
    Entries = case file:list_dir(Root) of
        {ok, Names} ->
            Interesting = [N || N <- lists:sort(Names), isOutlineEntry(N)],
            lists:sublist(Interesting, ?MaxOutlineEntries);
        _ ->
            []
    end,
    #{
        projectRoot => Root,
        topLevel => Entries,
        codeRoots => try alConfig:codeRoots() catch _:_ -> [] end,
        indexReady => alCoreClient:available(),
        pathNote => <<"topLevel is navigation only — do NOT concatenate names into paths. "
                      "Use modulePaths, searchCode hits, or resolveModule."/utf8>>
    }.

%% 为命中/猜测的模块名解析真实相对路径（供 LLM 直接 readFile）。
resolveModulePaths(Modules) when is_list(Modules) ->
    lists:filtermap(fun(Module) ->
        case resolveOneModulePath(Module) of
            {ok, Rel} -> {true, #{module => Module, file => Rel}};
            _ -> false
        end
    end, lists:sublist(Modules, ?MaxModulesForSymbols));
resolveModulePaths(_) ->
    [].

resolveOneModulePath(Module) ->
    case alCoreClient:moduleSymbols(Module) of
        {ok, Result} when is_map(Result) ->
            case fileFromSymbols(Result) of
                undefined -> error;
                File -> {ok, relativePath(File)}
            end;
        _ ->
            error
    end.

fileFromSymbols(Result) ->
    case maps:get(file, Result, maps:get(<<"file">>, Result, undefined)) of
        F when F =/= undefined, F =/= null, F =/= <<>>, F =/= "" -> F;
        _ ->
            Doc = maps:get(document, Result,
                  maps:get(<<"document">>, Result,
                  maps:get(data, Result, maps:get(<<"data">>, Result, undefined)))),
            case Doc of
                M when is_map(M) ->
                    maps:get(file, M, maps:get(<<"file">>, M,
                        begin
                            D2 = maps:get(document, M, maps:get(<<"document">>, M, undefined)),
                            case D2 of
                                M2 when is_map(M2) ->
                                    maps:get(file, M2, maps:get(<<"file">>, M2, undefined));
                                _ -> undefined
                            end
                        end));
                _ -> undefined
            end
    end.

isOutlineEntry([]) -> false;
isOutlineEntry(Name) ->
    Hidden = hd(Name) =:= $.,
    Skip = lists:member(Name, ["_build", "deps", "node_modules", "target", "log", "logs", "ebin"]),
    not Hidden andalso not Skip.

parseFa(Text) ->
    Pattern = "([a-z][a-zA-Z0-9_]*)\\s*:\\s*([a-z][a-zA-Z0-9_]*)\\s*/\\s*(\\d+)",
    Input = toBinary(Text),
    case re:run(Input, Pattern, [{capture, all_but_first, list}]) of
        {match, [Module, Function, ArityStr]} ->
            ModAtom = try list_to_existing_atom(Module) catch _:_ -> Module end,
            FnAtom = try list_to_existing_atom(Function) catch _:_ -> Function end,
            {ok, ModAtom, FnAtom, list_to_integer(ArityStr)};
        _ ->
            error
    end.

%%--------------------------------------------------------------------
%% @doc
%% 解析用户问题中的显式锚定：
%%   @module alToolRouter
%%   @path plugin/game/src/foo.erl
%%   @mfa alAgent:run/2
%% 也接受 @module:name / @path:rel / @mfa:M:F/A 写法。
%% @end
%%--------------------------------------------------------------------
-spec parseAnchors(term()) -> #{modules := [term()], paths := [binary()], mfas := [map()]}.
parseAnchors(Question) ->
    Bin = toBinary(Question),
    Modules = collectAnchorMatches(Bin,
        "(?i)@module\\s*:?\\s*([a-z][a-zA-Z0-9_]*)", fun parseAnchorModule/1),
    Paths = collectAnchorMatches(Bin,
        "(?i)@path\\s*:?\\s*([^\\s]+)", fun parseAnchorPath/1),
    Mfas = collectAnchorMatches(Bin,
        "(?i)@mfa\\s*:?\\s*([a-z][a-zA-Z0-9_]*)\\s*:\\s*([a-z][a-zA-Z0-9_]*)\\s*/\\s*(\\d+)",
        fun parseAnchorMfa/1),
    #{
        modules => lists:usort(Modules),
        paths => lists:usort(Paths),
        mfas => dedupMfas(Mfas)
    }.

collectAnchorMatches(Bin, Pattern, Fun) ->
    case re:run(Bin, Pattern, [global, {capture, all_but_first, list}]) of
        {match, Captures} ->
            lists:filtermap(fun(Parts) ->
                try
                    case Fun(Parts) of
                        undefined -> false;
                        V -> {true, V}
                    end
                catch
                    _:_ -> false
                end
            end, Captures);
        nomatch ->
            []
    end.

parseAnchorModule([Mod]) ->
    try list_to_existing_atom(Mod) catch _:_ -> undefined end;
parseAnchorModule(_) ->
    undefined.

parseAnchorPath([Path]) ->
    unicode:characters_to_binary(string:trim(Path, both, "\"'"));
parseAnchorPath(_) ->
    undefined.

parseAnchorMfa([Mod, Fun, ArityStr]) ->
    ModA = try list_to_existing_atom(Mod) catch _:_ -> undefined end,
    FunA = try list_to_existing_atom(Fun) catch _:_ -> undefined end,
    case {ModA, FunA} of
        {undefined, _} -> undefined;
        {_, undefined} -> undefined;
        _ ->
            try #{module => ModA, function => FunA, arity => list_to_integer(ArityStr)}
            catch _:_ -> undefined end
    end;
parseAnchorMfa(_) ->
    undefined.

dedupMfas(Mfas) ->
    maps:values(maps:from_list([
        {{maps:get(module, M), maps:get(function, M), maps:get(arity, M)}, M}
     || M <- Mfas
    ])).

%% 锚定模块优先，再补检索命中模块（限流）。
prioritizeModules(Preferred, Rest) ->
    Pref = lists:usort(Preferred),
    Extra = [M || M <- lists:usort(Rest), not lists:member(M, Pref)],
    lists:sublist(Pref ++ Extra, ?MaxModulesForSymbols).

resolveAnchors(#{modules := Mods, paths := Paths, mfas := Mfas}) ->
    #{
        modules => [
            case resolveOneModulePath(M) of
                {ok, Rel} -> #{module => M, file => Rel};
                _ -> #{module => M, file => undefined}
            end
         || M <- Mods],
        paths => [
            #{
                path => P,
                relative => relativePath(P),
                exists => filelib:is_file(
                    filename:absname(toList(P),
                        try alConfig:projectRoot() catch _:_ -> "." end))
            }
         || P <- Paths],
        mfas => [resolveAnchorMfa(Mfa) || Mfa <- Mfas],
        note => <<"User-pinned context; treat as authoritative over search guesses">>
    }.

resolveAnchorMfa(#{module := M, function := F, arity := A} = Mfa) ->
    File = case resolveOneModulePath(M) of
        {ok, Rel} -> Rel;
        _ -> undefined
    end,
    Loc = try
        case alCoreClient:getSymbol(M, F, A) of
            {ok, Result} when is_map(Result) ->
                extractSymbolLoc(Result);
            _ ->
                #{}
        end
    catch
        _:_ -> #{}
    end,
    maps:merge(Mfa#{file => File}, Loc).

%%--------------------------------------------------------------------
%% @doc
%% 为锚定目标预取源码片段，减少首轮 tool 往返。
%% MFA：围绕定义行；path：文件头；module：文件头。
%% @end
%%--------------------------------------------------------------------
prefetchAnchorSnippets(#{mfas := Mfas, paths := Paths, modules := Mods}) ->
    FromMfa = lists:filtermap(fun prefetchMfaSnippet/1, Mfas),
    FromPath = lists:filtermap(fun prefetchPathSnippet/1, Paths),
    FromMod = lists:filtermap(fun prefetchModuleSnippet/1, Mods),
    lists:sublist(FromMfa ++ FromPath ++ FromMod, ?MaxAnchorSnippets);
prefetchAnchorSnippets(_) ->
    [].

prefetchMfaSnippet(#{file := File} = Mfa) when File =/= undefined, File =/= <<>>, File =/= "" ->
    Line = maps:get(start_line, Mfa, maps:get(line, Mfa, 1)),
    case readFileWindow(File, Line, ?AnchorSnippetRadius) of
        {ok, Snip} ->
            {true, Snip#{
                kind => mfa,
                module => maps:get(module, Mfa, undefined),
                function => maps:get(function, Mfa, undefined),
                arity => maps:get(arity, Mfa, undefined)
            }};
        _ ->
            false
    end;
prefetchMfaSnippet(_) ->
    false.

prefetchPathSnippet(#{exists := true} = P) ->
    Rel = maps:get(relative, P, maps:get(path, P, undefined)),
    case Rel of
        undefined -> false;
        _ ->
            case readFileWindow(Rel, 1, ?AnchorSnippetHeadLines) of
                {ok, Snip} -> {true, Snip#{kind => path}};
                _ -> false
            end
    end;
prefetchPathSnippet(_) ->
    false.

prefetchModuleSnippet(#{file := File} = M) when File =/= undefined, File =/= <<>>, File =/= "" ->
    case readFileWindow(File, 1, ?AnchorSnippetHeadLines) of
        {ok, Snip} ->
            {true, Snip#{kind => module, module => maps:get(module, M, undefined)}};
        _ ->
            false
    end;
prefetchModuleSnippet(_) ->
    false.

%% 读取 CenterLine 附近窗口（1-based）；Radius 为前后行数或从头取 N 行。
readFileWindow(Path0, CenterLine, Radius) ->
    case absUnderRoot(Path0) of
        {error, _} = Err ->
            Err;
        Abs ->
            case file:read_file(Abs) of
                {ok, Bin} ->
                    Lines = binary:split(Bin, <<"\n">>, [global]),
                    Total = length(Lines),
                    case Total of
                        0 ->
                            {error, empty};
                        _ ->
                            Center = max(1, min(Total, toInt(CenterLine, 1))),
                            Start = max(1, Center - Radius),
                            End = min(Total, Center + Radius),
                            %% 若 Center=1 且 Radius 大，等价文件头预览
                            Window = lists:sublist(Lines, Start, End - Start + 1),
                            Numbered = lists:zip(lists:seq(Start, Start + length(Window) - 1), Window),
                            Text = iolist_to_binary([[integer_to_binary(N), <<"| ">>, L, <<"\n">>]
                                                    || {N, L} <- Numbered]),
                            {ok, #{
                                file => relativePath(Abs),
                                startLine => Start,
                                endLine => End,
                                text => Text
                            }}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

absUnderRoot(Path0) ->
    Path = toList(Path0),
    Root = try alConfig:projectRoot() catch _:_ -> "." end,
    Abs = case filelib:is_file(Path) of
        true ->
            filename:absname(Path);
        false ->
            filename:absname(Path, Root)
    end,
    case isUnderRoot(Abs, Root) of
        true -> Abs;
        false -> {error, forbidden}
    end.

%% 规范化后校验绝对路径是否位于 Root 内（拒绝 `..` 与目录外绝对路径）。
isUnderRoot(Path, Root) ->
    RootParts = [string:lowercase(P) || P <- filename:split(filename:absname(Root))],
    PathParts = [string:lowercase(P) || P <- filename:split(filename:absname(Path))],
    not lists:member("..", PathParts)
        andalso length(PathParts) >= length(RootParts)
        andalso lists:sublist(PathParts, length(RootParts)) =:= RootParts.

toInt(N, _Def) when is_integer(N) -> N;
toInt(N, Def) when is_binary(N) ->
    try binary_to_integer(N) catch _:_ -> Def end;
toInt(N, Def) when is_list(N) ->
    try list_to_integer(N) catch _:_ -> Def end;
toInt(_, Def) -> Def.

extractSymbolLoc(Result) when is_map(Result) ->
    Sym = case maps:get(symbol, Result, maps:get(<<"symbol">>, Result, undefined)) of
        undefined ->
            Data = maps:get(data, Result, maps:get(<<"data">>, Result, #{})),
            case Data of
                DataMap when is_map(DataMap) ->
                    maps:get(symbol, DataMap, maps:get(<<"symbol">>, DataMap, undefined));
                _ -> undefined
            end;
        S -> S
    end,
    case Sym of
        SymMap when is_map(SymMap) ->
            Line = maps:get(line, SymMap, maps:get(<<"line">>, SymMap, undefined)),
            Start = maps:get(start_line, SymMap, maps:get(<<"start_line">>, SymMap, Line)),
            End = maps:get(end_line, SymMap, maps:get(<<"end_line">>, SymMap, Start)),
            maps:filter(fun(_, V) -> V =/= undefined end, #{
                line => Line,
                start_line => Start,
                end_line => End
            });
        _ ->
            #{}
    end;
extractSymbolLoc(_) ->
    #{}.

fetchAnchorCallContexts([]) ->
    [];
fetchAnchorCallContexts(Mfas) ->
    lists:filtermap(fun(#{module := M, function := F, arity := A}) ->
        case fetchCallContextForFa(M, F, A) of
            Ctx when map_size(Ctx) > 0 -> {true, Ctx};
            _ -> false
        end
    end, lists:sublist(Mfas, 3)).

%%--------------------------------------------------------------------
%% @doc
%% 写任务判定：edit 模式，或 ask 中途被升档为 edit（modePromoted）。
%% 写任务走 map-reduce 编排：侦察维度加 relatedTests，hint 加写纪律。
%%
%% @param Opts 选项 map
%% @return boolean()
%% @end
%%--------------------------------------------------------------------
isWriteTask(Opts) when is_map(Opts) ->
    maps:get(mode, Opts, ask) =:= edit
        orelse maps:get(modePromoted, Opts, false) =:= true;
isWriteTask(_) ->
    false.

%%--------------------------------------------------------------------
%% @doc
%% 推导相关测试文件（写后验证入口）：模块 `foo' → `test/foo_tests.erl'，
%% 仅收录真实存在的文件。测试文件命名遵循项目约定（`_tests' 后缀）。
%%
%% @param Modules 模块名列表（atom/binary）
%% @return `#{module => Mod, testFile => RelPath}' 列表
%% @end
%%--------------------------------------------------------------------
fetchRelatedTests(Modules) when is_list(Modules) ->
    lists:filtermap(fun(Mod) ->
        case relatedTestPath(Mod) of
            undefined -> false;
            Rel -> {true, #{module => Mod, testFile => Rel}}
        end
    end, lists:sublist(Modules, ?MaxModulesForSymbols));
fetchRelatedTests(_) ->
    [].

relatedTestPath(Mod) when Mod =/= undefined ->
    Base = toBinary(Mod),
    Rel = << "test/", Base/binary, "_tests.erl" >>,
    case absUnderRoot(Rel) of
        {error, _} ->
            undefined;
        Abs ->
            case filelib:is_file(Abs) of
                true -> Rel;
                false -> undefined
            end
    end;
relatedTestPath(_) ->
    undefined.

fetchCallContextForFa(Module, Function, Arity) ->
    Callees = case alCoreClient:getCallees(Module, Function, Arity) of
        {ok, #{data := #{edges := CalleeEdges}}} -> lists:sublist(CalleeEdges, 40);
        _ -> []
    end,
    Callers = case alCoreClient:getCallers(Module, Function, Arity) of
        {ok, #{data := #{edges := CallerEdges}}} -> lists:sublist(CallerEdges, 40);
        _ -> []
    end,
    #{module => Module, function => Function, arity => Arity,
      callers => Callers, callees => Callees}.

moduleEdgeMatch(Edge, ModuleSet) ->
    From = maps:get(fromModule, Edge, undefined),
    To = maps:get(toModule, Edge, undefined),
    (From =/= undefined andalso sets:is_element(From, ModuleSet)) orelse
        (To =/= undefined andalso sets:is_element(To, ModuleSet)).

needsCodeSearch(Question) ->
    Q = string:lowercase(toList(Question)),
    %% 问候/短确认：不做代码检索与 rewrite LLM，避免「你好」也卡住
    Greetings = ["hi", "hey", "hello", "ok", "yes", "no",
                 "你好", "您好", "嗨", "嗯", "好的", "谢谢", "再见"],
    case lists:member(string:trim(Q), Greetings) of
        true ->
            false;
        false ->
            Keywords = ["module", "function", "call", "where", "how", "实现", "模块", "函数",
                        "调用", "哪里", "怎么", "代码", "code", "erl", "handler", "协议"],
            Anchors = parseAnchors(Question),
            HasAnchors = maps:get(modules, Anchors, []) =/= []
                orelse maps:get(paths, Anchors, []) =/= []
                orelse maps:get(mfas, Anchors, []) =/= [],
            CharLen = try string:length(Q) catch _:_ -> length(Q) end,
            lists:any(fun(K) -> string:find(Q, K) =/= nomatch end, Keywords)
                orelse parseFa(Question) =/= error
                orelse HasAnchors
                %% 用字符长度；纯短句不搜。阈值提高，避免短中文误触发 rewrite。
                orelse CharLen >= 24
    end.

toBinary(V) when is_binary(V) -> V;
toBinary(V) when is_list(V) -> unicode:characters_to_binary(V);
toBinary(V) when is_atom(V) -> atom_to_binary(V, utf8);
toBinary(V) -> unicode:characters_to_binary(io_lib:format("~p", [V])).

toList(V) when is_list(V) -> V;
toList(V) when is_binary(V) -> unicode:characters_to_list(V);
toList(V) when is_atom(V) -> atom_to_list(V);
toList(V) -> lists:flatten(io_lib:format("~p", [V])).
