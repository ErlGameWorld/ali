%%%-------------------------------------------------------------------
%% @doc 项目经验成长：踩坑 / 纠正 / 核实结论 → 结构化沉淀 → 提问时召回。
%%
%% 闭环：
%% <ul>
%%   <li>建库：digest 结束 {@link seedFromDigest/1} 预学习 actions/表/behaviour</li>
%%   <li>增量：{@link reconcileAfterCodeChange/1} 对删除模块废止旧课；digest 重种子纠错</li>
%%   <li>对话：失败/纠正自动记；成功轮 {@link extractFromTurn/4} 启发式沉淀</li>
%% </ul>
%% 存储复用 {@link alMemory}（kind=`lesson`），不另起库。
%% @end
%%%-------------------------------------------------------------------

-module(alExperience).

-export([
    recordLesson/1,
    recordLesson/2,
    recordFromTurn/5,
    recordFromTurn/6,
    recordCorrection/2,
    correctLesson/1,
    correctLesson/2,
    findRelatedLessons/2,
    recallFor/1,
    recallFor/2,
    familiarityDigest/0,
    familiarityDigest/1,
    detectCorrection/1,
    formatCard/1,
    enabled/0,
    seedFromDigest/1,
    seedFromDigest/2,
    reconcileAfterCodeChange/1,
    extractFromTurn/4,
    recordSuccessPath/3,
    unifiedRecall/2,
    recordBuildFailure/1
]).

%% Test helpers
-export([
    compactLesson/1,
    lessonBoost/1,
    mergeRecall/3,
    correctionPhrases/0,
    buildDigestCandidates/1,
    fingerprintOf/1,
    isSuperseded/1,
    overlapScore/2,
    pathsFromStatusMap/1,
    modulesFromPaths/1,
    shouldExtractTurn/3,
    shouldRecordSuccessPath/3,
    pathBitsFromTrace/1,
    extractJsonPaths/1,
    isStale/1,
    parseLessonExtractJson/1,
    unifiedScore/1,
    knowledgeHitsToRows/1
]).

-define(DefaultRecallLimit, 5).
-define(MaxCardBytes, 1200).
-define(MaxFamiliarityLessons, 8).
-define(DefaultMaxDigestSeeds, 40).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc 是否启用经验层（agent.experienceEnabled，默认 true）。
%% @end
%%--------------------------------------------------------------------
-spec enabled() -> boolean().
enabled() ->
    Agent = alConfig:get(agent, #{}),
    maps:get(experienceEnabled, Agent, true) =/= false.

%%--------------------------------------------------------------------
%% @doc 写入一条结构化教训（无 session）。
%% @end
%%--------------------------------------------------------------------
-spec recordLesson(map()) -> {ok, map()} | {error, term()}.
recordLesson(Args) when is_map(Args) ->
    recordLesson(undefined, Args).

%%--------------------------------------------------------------------
%% @doc
%% 写入教训卡片。Args 常用字段：
%% symptom / rootCause / prevention / content（或直接 content）、
%% source（failure|correction|insight|manual）、tags、relatedPaths、relatedMfas。
%% @end
%%--------------------------------------------------------------------
-spec recordLesson(term(), map()) -> {ok, map()} | {error, term()}.
recordLesson(SessionId, Args) when is_map(Args) ->
    case enabled() of
        false -> {error, disabled};
        true ->
            Card = formatCard(Args),
            case Card =:= <<>> of
                true -> {error, emptyLesson};
                false ->
                    Source = normalizeSource(maps:get(source, Args,
                                maps:get(<<"source">>, Args, manual))),
                    Tags0 = ensureList(maps:get(tags, Args, maps:get(<<"tags">>, Args, []))),
                    Tags = lists:usort([lesson, Source | [toAtomOrBin(T) || T <- Tags0]]),
                    Meta0 = #{
                        source => Source,
                        symptom => maps:get(symptom, Args, maps:get(<<"symptom">>, Args, <<>>)),
                        rootCause => maps:get(rootCause, Args, maps:get(<<"rootCause">>, Args, <<>>)),
                        prevention => maps:get(prevention, Args, maps:get(<<"prevention">>, Args, <<>>)),
                        relatedPaths => ensureList(maps:get(relatedPaths, Args,
                                            maps:get(<<"relatedPaths">>, Args, []))),
                        relatedMfas => ensureList(maps:get(relatedMfas, Args,
                                           maps:get(<<"relatedMfas">>, Args, []))),
                        experience => true
                    },
                    Meta = case maps:get(fingerprint, Args, undefined) of
                        undefined -> Meta0;
                        Fp -> Meta0#{fingerprint => toBinary(Fp), digestSeed => true}
                    end,
                    try
                        alMemory:remember(SessionId, lesson, Card, #{
                            tags => Tags,
                            metadata => Meta,
                            scope => project
                        })
                    catch
                        exit:{noproc, _} -> {error, dbUnavailable};
                        _:Reason -> {error, Reason}
                    end
            end
    end.

%%--------------------------------------------------------------------
%% @doc 从 project digest 产物预学习经验（构建知识库时调用）。
%% Digest 可含：actions / data / moduleContexts。
%% @end
%%--------------------------------------------------------------------
-spec seedFromDigest(map()) -> {ok, map()} | {error, term()}.
seedFromDigest(Digest) when is_map(Digest) ->
    seedFromDigest(Digest, #{}).

-spec seedFromDigest(map(), map()) -> {ok, map()} | {error, term()}.
seedFromDigest(Digest, Opts) when is_map(Digest), is_map(Opts) ->
    case enabled() of
        false ->
            {ok, #{seeded => 0, skipped => 0, reason => disabled}};
        true ->
            Max = case maps:get(maxSeeds, Opts, ?DefaultMaxDigestSeeds) of
                N when is_integer(N), N > 0 -> N;
                _ -> ?DefaultMaxDigestSeeds
            end,
            Candidates0 = buildDigestCandidates(Digest),
            Candidates = lists:sublist(Candidates0, Max),
            Existing = existingDigestFingerprints(),
            {Seeded, Skipped, Corrected} = lists:foldl(fun(Cand, {S, K, C}) ->
                Fp = maps:get(fingerprint, Cand, <<>>),
                case Fp =/= <<>> andalso maps:is_key(Fp, Existing) of
                    true ->
                        {S, K + 1, C};
                    false ->
                        %% 同 MFA/主题但内容变了 → 纠错废旧立新
                        case relatedDigestConflict(Cand) of
                            [] ->
                                case recordLesson(Cand) of
                                    {ok, _} -> {S + 1, K, C};
                                    _ -> {S, K + 1, C}
                                end;
                            OldRows ->
                                case correctLesson(Cand#{
                                    relatedIds => [maps:get(id, R) || R <- OldRows,
                                                   maps:is_key(id, R)],
                                    source => insight,
                                    tags => [digest_seed, revised |
                                        ensureList(maps:get(tags, Cand, []))]
                                }) of
                                    {ok, _} -> {S + 1, K, C + 1};
                                    _ -> {S, K + 1, C}
                                end
                        end
                end
            end, {0, 0, 0}, Candidates),
            {ok, #{
                seeded => Seeded,
                skipped => Skipped,
                corrected => Corrected,
                candidates => length(Candidates0),
                attempted => length(Candidates)
            }}
    end.

%%--------------------------------------------------------------------
%% @doc 纯函数：从 digest 产物生成候选经验卡片（不写库）。
%% @end
%%--------------------------------------------------------------------
-spec buildDigestCandidates(map()) -> [map()].
buildDigestCandidates(Digest) when is_map(Digest) ->
    Actions = maps:get(actions, Digest, maps:get(<<"actions">>, Digest, [])),
    Data = maps:get(data, Digest, maps:get(<<"data">>, Digest, #{})),
    Ctxs = maps:get(moduleContexts, Digest,
              maps:get(<<"moduleContexts">>, Digest, #{})),
    Cand0 = fromActions(ensureList(Actions))
         ++ fromTables(Data)
         ++ fromBehaviours(Ctxs),
    %% 去重指纹
    {_, Out} = lists:foldl(fun(C, {Seen, Acc}) ->
        Fp = maps:get(fingerprint, C, <<>>),
        case Fp =:= <<>> orelse maps:is_key(Fp, Seen) of
            true -> {Seen, Acc};
            false -> {Seen#{Fp => true}, [C | Acc]}
        end
    end, {#{}, []}, Cand0),
    lists:reverse(Out);
buildDigestCandidates(_) ->
    [].

fingerprintOf(Content) ->
    Bin = toBinary(Content),
    Hash = crypto:hash(sha, Bin),
    list_to_binary(lists:flatten([io_lib:format("~2.16.0b", [B]) || <<B>> <= Hash])).

%%--------------------------------------------------------------------
%% @doc 从一轮 agent 结果自动沉淀失败/评审教训。
%% @end
%%--------------------------------------------------------------------
-spec recordFromTurn(term(), term(), term(), map(), term()) -> ok.
recordFromTurn(SessionId, Question, Answer, Critique, Trace) ->
    recordFromTurn(SessionId, Question, Answer, Critique, Trace, #{}).

-spec recordFromTurn(term(), term(), term(), map(), term(), map()) -> ok.
recordFromTurn(SessionId, Question, Answer, Critique, Trace, Opts) when is_map(Opts) ->
    case enabled() andalso autoRecord(Opts) of
        false -> ok;
        true ->
            try
                Failures = collectFailureBits(Trace, Critique),
                case Failures of
                    [] ->
                        _ = extractFromTurn(SessionId, Question, Answer, Critique),
                        ok;
                    _ ->
                        Symptom = iolist_to_binary(lists:join(<<"；"/utf8>>,
                                                             lists:sublist(Failures, 4))),
                        Prevention = case maps:get(verdict, Critique, pass) of
                            reject -> <<"先核对工具证据与 MFA/路径，勿凭记忆下结论"/utf8>>;
                            warn -> <<"按 critic feedback 修正后再作答"/utf8>>;
                            _ -> <<"复现失败步骤前先查经验召回与相关源码"/utf8>>
                        end,
                        _ = recordLesson(SessionId, #{
                            source => failure,
                            symptom => Symptom,
                            rootCause => maps:get(feedback, Critique, <<>>),
                            prevention => Prevention,
                            content => iolist_to_binary([
                                <<"问题："/utf8>>, toBinary(Question), <<"\n"/utf8>>,
                                <<"失败："/utf8>>, Symptom, <<"\n"/utf8>>,
                                <<"评审："/utf8>>, toBinary(maps:get(feedback, Critique, <<>>))
                            ]),
                            tags => [pitfall, agent]
                        }),
                        ok
                end
            catch
                _:_ -> ok
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 成功路径沉淀：critic 干净通过（pass）且带真实检索的轮次，把
%% 「问题 → 有效检索词 → 命中文件 → 工具链」沉淀为 source=success 的
%% lesson 卡。下次同类问题召回直接给出入口文件，跳过探索轮次。
%%
%% 与 {@link extractFromTurn/4} 互补：那个沉淀答案里的结论（MFA/要点），
%% 本函数沉淀到达答案的**检索路径**。触发条件更严（仅 pass + 有命中文件）。
%%
%% @param SessionId 会话 ID
%% @param Question  用户问题
%% @param Trace     工具循环 trace
%% @return ok
%% @end
%%--------------------------------------------------------------------
-spec recordSuccessPath(term(), term(), list()) -> ok.
recordSuccessPath(SessionId, Question, Trace) ->
    case enabled() andalso shouldRecordSuccessPath(Question, Trace, #{}) of
        false ->
            ok;
        true ->
            try
                #{queries := Queries, files := Files, tools := Tools} = pathBitsFromTrace(Trace),
                Content = iolist_to_binary([
                    <<"【成功路径】"/utf8>>, <<"\n"/utf8>>,
                    <<"问："/utf8>>, truncate(toBinary(Question), 200), <<"\n"/utf8>>,
                    <<"检索词："/utf8>>, joinPreview(Queries, 6), <<"\n"/utf8>>,
                    <<"命中文件："/utf8>>, joinPreview(Files, 8), <<"\n"/utf8>>,
                    <<"工具链："/utf8>>, joinPreview(Tools, 8)
                ]),
                Related = findRelatedLessons(Content, 3),
                case isNearDuplicate(Content, Related) of
                    true -> ok;
                    false ->
                        _ = recordLesson(SessionId, #{
                            source => success,
                            content => Content,
                            symptom => truncate(toBinary(Question), 160),
                            prevention => <<"同类问题先读本卡命中文件，再下钻源码"/utf8>>,
                            relatedPaths => lists:sublist(Files, 8),
                            tags => [success, path],
                            fingerprint => fingerprintOf(Content)
                        }),
                        ok
                end
            catch
                _:_ -> ok
            end
    end.

%% 是否值得沉淀成功路径：问题非平凡、非用户纠正、trace 有真实工具调用
%% 且能从工具结果中提取到命中文件（证明是"检索型"成功而非纯闲聊）。
shouldRecordSuccessPath(Question, Trace, _Opts) when is_list(Trace) ->
    Q = toBinary(Question),
    case Q =:= <<>> orelse isTrivialQuestion(Q) orelse detectCorrection(Q) of
        true -> false;
        false ->
            #{files := Files, tools := Tools} = pathBitsFromTrace(Trace),
            Tools =/= [] andalso Files =/= []
    end;
shouldRecordSuccessPath(_, _, _) ->
    false.

%%--------------------------------------------------------------------
%% @doc
%% 纯函数：从 trace 提取成功路径三要素。
%% <ul>
%%   <li>queries：搜索类工具的 query 参数</li>
%%   <li>files：工具结果 JSON 里的 file/path 字段值（正则抽取，结构无关）</li>
%%   <li>tools：去重工具名序列（复用 alToolLearn:toolsFromTrace/1）</li>
%% </ul>
%% @end
%%--------------------------------------------------------------------
-spec pathBitsFromTrace(list()) -> #{queries := [binary()], files := [binary()], tools := [binary()]}.
pathBitsFromTrace(Trace) when is_list(Trace) ->
    Queries = lists:usort(lists:flatmap(fun
        ({tool_calls, Calls}) when is_list(Calls) ->
            lists:filtermap(fun(C) when is_map(C) ->
                try
                    Name = maps:get(name, maps:get(function, C, #{}), undefined),
                    Args = maps:get(arguments, maps:get(function, C, #{}), #{}),
                    case isSearchTool(Name) of
                        true ->
                            case extractQueryArg(Args) of
                                <<>> -> false;
                                Q -> {true, Q}
                            end;
                        false ->
                            false
                    end
                catch _:_ -> false end
            end, Calls);
        (_) -> []
    end, Trace)),
    Files = lists:usort(lists:flatmap(fun
        ({results, Results}) when is_list(Results) ->
            lists:flatmap(fun(R) when is_map(R) ->
                try extractJsonPaths(toBinary(maps:get(content, R, <<>>)))
                catch _:_ -> [] end;
                (_) -> []
            end, Results);
        (_) -> []
    end, Trace)),
    Tools = try alToolLearn:toolsFromTrace(Trace) catch _:_ -> [] end,
    #{queries => lists:sublist(Queries, 12), files => lists:sublist(Files, 16), tools => Tools};
pathBitsFromTrace(_) ->
    #{queries => [], files => [], tools => []}.

isSearchTool(search) -> true;
isSearchTool(<<"search">>) -> true;
isSearchTool(searchCode) -> true;
isSearchTool(<<"searchCode">>) -> true;
isSearchTool(searchUnified) -> true;
isSearchTool(<<"searchUnified">>) -> true;
isSearchTool(findRefs) -> true;
isSearchTool(<<"findRefs">>) -> true;
isSearchTool(_) -> false.

%% 工具 arguments 可能是 map 或 JSON binary，两种都取 query。
extractQueryArg(#{query := Q}) when is_binary(Q), Q =/= <<>> -> Q;
extractQueryArg(#{<<"query">> := Q}) when is_binary(Q), Q =/= <<>> -> Q;
extractQueryArg(Args) when is_binary(Args) ->
    try alJson:decode(Args) of
        M when is_map(M) -> extractQueryArg(M);
        _ -> <<>>
    catch _:_ -> <<>> end;
extractQueryArg(_) -> <<>>.

%% 从工具结果 JSON 文本中正则抽取 "file":"..." / "path":"..." 值。
%% 沉淀 hint 用途，允许对转义路径的近似处理；去空并截断长度。
extractJsonPaths(JsonBin) when is_binary(JsonBin), byte_size(JsonBin) > 0 ->
    case re:run(JsonBin,
                <<"\"(?:file|path)\"\\s*:\\s*\"([^\"]{1,200})\"">>,
                [global, {capture, all_but_first, binary}]) of
        {match, Groups} ->
            Paths = [unescapeJson(P) || [P] <- Groups],
            lists:usort([P || P <- Paths, P =/= <<>>]);
        _ ->
            []
    end;
extractJsonPaths(_) ->
    [].

unescapeJson(P) ->
    binary:replace(binary:replace(P, <<"\\\\">>, <<"\\">>, [global]),
                   <<"\\\"">>, <<"\"">>, [global]).

joinPreview(Items, Limit) ->
    case Items of
        [] -> <<"-"/utf8>>;
        _ -> iolist_to_binary(lists:join(<<", ">>, lists:sublist(Items, Limit)))
    end.

%%--------------------------------------------------------------------
%% @doc 用户纠正：废止相关旧经验并写入新教训。
%% @end
%%--------------------------------------------------------------------
-spec recordCorrection(term(), map() | binary()) -> {ok, map()} | {error, term()}.
recordCorrection(SessionId, Content) when is_binary(Content) ->
    recordCorrection(SessionId, #{content => Content, source => correction});
recordCorrection(SessionId, Args) when is_map(Args) ->
    correctLesson(SessionId, Args#{
        source => correction,
        tags => [correction, user, revised | ensureList(maps:get(tags, Args, []))],
        prevention => maps:get(prevention, Args,
            <<"以本条纠正为准；旧经验已废止"/utf8>>)
    }).

%%--------------------------------------------------------------------
%% @doc 纠错入口（无 session）：找相关旧 lesson → 标 superseded → 写新卡。
%% @end
%%--------------------------------------------------------------------
-spec correctLesson(map()) -> {ok, map()} | {error, term()}.
correctLesson(Args) when is_map(Args) ->
    correctLesson(undefined, Args).

%%--------------------------------------------------------------------
%% @doc
%% 自动维护经验：根据纠正内容定位旧教训，软废止后写入新版。
%% Args 可含 `relatedIds` 显式指定要废止的 id 列表。
%% @end
%%--------------------------------------------------------------------
-spec correctLesson(term(), map()) -> {ok, map()} | {error, term()}.
correctLesson(SessionId, Args) when is_map(Args) ->
    case enabled() of
        false -> {error, disabled};
        true ->
            Query = correctionQuery(Args),
            Explicit = ensureList(maps:get(relatedIds, Args,
                                maps:get(<<"relatedIds">>, Args, []))),
            Related0 = case Explicit of
                [] -> findRelatedLessons(Query, 8);
                Ids ->
                    lists:filtermap(fun(Id) ->
                        case alMemory:get(Id) of
                            {ok, Row} -> {true, Row};
                            _ -> false
                        end
                    end, Ids)
            end,
            Related = [R || R <- Related0, not isSuperseded(R)],
            NewArgs0 = Args#{
                source => maps:get(source, Args, correction),
                tags => lists:usort([revised, correction |
                    ensureList(maps:get(tags, Args, []))])
            },
            NewArgs = case Related of
                [] -> NewArgs0;
                _ ->
                    NewArgs0#{
                        content => formatCorrectionContent(NewArgs0, Related)
                    }
            end,
            case recordLesson(SessionId, NewArgs) of
                {ok, NewInfo} ->
                    NewId = maps:get(id, NewInfo, undefined),
                    Superseded = lists:foldl(fun(Old, Acc) ->
                        case maps:get(id, Old, undefined) of
                            undefined -> Acc;
                            OldId when OldId =:= NewId -> Acc;
                            OldId ->
                                case alMemory:markSuperseded(OldId, NewId) of
                                    {ok, _} -> [OldId | Acc];
                                    _ -> Acc
                                end
                        end
                    end, [], Related),
                    {ok, NewInfo#{
                        supersededIds => lists:reverse(Superseded),
                        corrected => length(Superseded) > 0
                    }};
                Error ->
                    Error
            end
    end.

%%--------------------------------------------------------------------
%% @doc 按查询找相关（未废止）lesson，按重叠分排序。
%% @end
%%--------------------------------------------------------------------
-spec findRelatedLessons(term(), pos_integer()) -> [map()].
findRelatedLessons(Query, Limit) when is_integer(Limit), Limit > 0 ->
    Q = toBinary(Query),
    case Q =:= <<>> of
        true -> [];
        false ->
            Tokens = significantTokens(Q),
            Raw = lists:append([
                case alMemory:list(#{kind => lesson, q => T, limit => Limit}) of
                    {ok, Rows} -> [R || R <- Rows, not isSuperseded(R)];
                    _ -> []
                end || T <- lists:sublist(Tokens, 5)
            ]),
            Candidates = dedupById(Raw),
            Scored = [{overlapScore(Q, R), R} || R <- Candidates],
            Filtered = [{S, R} || {S, R} <- Scored, S >= 1.0],
            Sorted = lists:sort(fun({A, _}, {B, _}) -> A >= B end, Filtered),
            [R || {_, R} <- lists:sublist(Sorted, Limit)]
    end.

isSuperseded(Row) when is_map(Row) ->
    Tags = maps:get(tags, Row, []),
    Meta = maps:get(metadata, Row, #{}),
    lists:member(superseded, Tags)
        orelse lists:member(<<"superseded">>, Tags)
        orelse (is_map(Meta) andalso (
            maps:get(superseded, Meta, false) =:= true
            orelse maps:get(<<"superseded">>, Meta, false) =:= true
        ));
isSuperseded(_) ->
    false.

%% 粗重叠分：共享 token / MFA 命中加分。
overlapScore(Query, Row) when is_map(Row) ->
    QTokens = significantTokens(Query),
    Content = toBinary(maps:get(content, Row, <<>>)),
    CTokens = significantTokens(Content),
    Shared = length([T || T <- QTokens, lists:member(T, CTokens)]),
    Meta = maps:get(metadata, Row, #{}),
    MfaBonus = case is_map(Meta) of
        true ->
            Mfas = ensureList(maps:get(relatedMfas, Meta,
                        maps:get(<<"relatedMfas">>, Meta, []))),
            length([1 || M <- Mfas,
                         binary:match(toBinary(Query), toBinary(M)) =/= nomatch]);
        false -> 0
    end,
    float(Shared + MfaBonus * 2);
overlapScore(_, _) ->
    0.0.

%%--------------------------------------------------------------------
%% @doc 提问时召回经验（lesson 加权 + 普通相关记忆）。
%% @end
%%--------------------------------------------------------------------
-spec recallFor(term()) -> {ok, [map()]}.
recallFor(Query) ->
    recallFor(Query, ?DefaultRecallLimit).

-spec recallFor(term(), pos_integer() | map()) -> {ok, [map()]}.
recallFor(Query, Limit) when is_integer(Limit), Limit > 0 ->
    recallFor(Query, #{limit => Limit});
recallFor(Query, Opts) when is_map(Opts) ->
    case enabled() of
        false -> {ok, []};
        true ->
            Limit = maps:get(limit, Opts, ?DefaultRecallLimit),
            Lessons = [R || R <- fetchLessons(Query, Limit * 2), not isSuperseded(R)],
            Semantic = case alMemory:relevantFor(Query, Limit * 2) of
                {ok, Rows} -> [R || R <- Rows, not isSuperseded(R)];
                _ -> []
            end,
            %% 语义召回命中的 lesson 与关键词 lesson 合并，避免中文/近义场景漏召回。
            SemanticLessons = [R || R <- Semantic, isLesson(R)],
            General = [R || R <- Semantic, not isLesson(R)],
            {ok, mergeRecall(Lessons ++ SemanticLessons, General, Limit)}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 统一召回：合并 lesson、长期记忆、digest 知识片段，按可信度与
%% finalScore 排序，供 buildContext 一次注入。
%% @end
%%--------------------------------------------------------------------
-spec unifiedRecall(term(), map()) -> {ok, map()}.
unifiedRecall(Query, Opts) when is_map(Opts) ->
    case enabled() of
        false ->
            {ok, #{lessons => [], memories => [], knowledge => [], merged => []}};
        true ->
            Limit = maps:get(limit, Opts, ?DefaultRecallLimit),
            Over = max(Limit * 2, Limit + 4),
            {ok, LessonRows} = recallFor(Query, #{limit => Over}),
            MemRows = case alMemory:relevantFor(Query, Over) of
                {ok, Rows} ->
                    [compactMemoryRow(scoreMemoryRow(R))
                     || R <- Rows, not isSuperseded(R), not isLesson(R)];
                _ -> []
            end,
            KnowRows = [compactKnowledgeRow(R) || R <- knowledgeHitsToRows(
                maps:get(knowledge, Opts, undefined))],
            Merged0 = dedupRows(LessonRows ++ MemRows ++ KnowRows),
            Sorted = lists:sort(fun(A, B) ->
                unifiedScore(A) >= unifiedScore(B)
            end, Merged0),
            Top = lists:sublist(Sorted, Limit),
            Lessons = [R || R <- Top, maps:get(kind, R, undefined) =:= lesson],
            Memories = [R || R <- Top, maps:get(fromKnowledge, R, false) =:= false,
                             maps:get(kind, R, undefined) =/= lesson],
            Knowledge = [R || R <- Top, maps:get(fromKnowledge, R, false) =:= true],
            {ok, #{
                lessons => Lessons,
                memories => Memories,
                knowledge => Knowledge,
                merged => Top
            }}
    end.

%%--------------------------------------------------------------------
%% @doc 熟悉度摘要：数量 + 近期教训，注入上下文让模型「记得这仓摔过什么」。
%% @end
%%--------------------------------------------------------------------
-spec familiarityDigest() -> map().
familiarityDigest() ->
    familiarityDigest(#{}).

-spec familiarityDigest(map()) -> map().
familiarityDigest(Opts) when is_map(Opts) ->
    case enabled() of
        false -> #{enabled => false, lessonCount => 0, recent => [], summary => <<>>};
        true ->
            Limit = maps:get(limit, Opts, ?MaxFamiliarityLessons),
            {Count, Recent} = case alMemory:list(#{kind => lesson, limit => max(Limit, 50)}) of
                {ok, Rows0} ->
                    Rows = [R || R <- Rows0, not isSuperseded(R)],
                    {length(Rows), [compactLesson(R) || R <- lists:sublist(Rows, Limit)]};
                _ ->
                    {0, []}
            end,
            Summary = case Count of
                0 ->
                    <<"本仓尚无沉淀项目经验；核实结论与踩坑后应写入 lesson。"/utf8>>;
                N ->
                    iolist_to_binary([
                        <<"本仓已沉淀 "/utf8>>, integer_to_binary(N),
                        <<" 条项目经验（踩坑/纠正/核实）。回答前优先看 experience.lessons，"
                          "避免重复已知失败。"/utf8>>
                    ])
            end,
            #{
                enabled => true,
                lessonCount => Count,
                recent => Recent,
                summary => Summary
            }
    end.

%%--------------------------------------------------------------------
%% @doc 检测用户纠正意图（启发式）。
%% @end
%%--------------------------------------------------------------------
-spec detectCorrection(term()) -> boolean().
detectCorrection(Text) ->
    Bin = string:lowercase(toBinary(Text)),
    lists:any(fun(P) -> binary:match(Bin, P) =/= nomatch end, correctionPhrases()).

correctionPhrases() ->
    [
        <<"不对"/utf8>>, <<"不是这样"/utf8>>, <<"你错了"/utf8>>,
        <<"记错了"/utf8>>, <<"纠正"/utf8>>, <<"搞错了"/utf8>>,
        <<"应该是"/utf8>>, <<"其实是"/utf8>>, <<"不是这个"/utf8>>,
        <<"你又错了"/utf8>>, <<"前面说错"/utf8>>,
        <<"that's wrong">>, <<"you are wrong">>, <<"incorrect">>,
        <<"actually it is">>, <<"should be">>
    ].

%%--------------------------------------------------------------------
%% @doc 将 Args 格式化为可读教训卡片文本。
%% @end
%%--------------------------------------------------------------------
-spec formatCard(map()) -> binary().
formatCard(Args) when is_map(Args) ->
    Content0 = maps:get(content, Args, maps:get(<<"content">>, Args, undefined)),
    case Content0 of
        C when is_binary(C), C =/= <<>> ->
            truncate(C, ?MaxCardBytes);
        _ ->
            Symptom = toBinary(maps:get(symptom, Args, maps:get(<<"symptom">>, Args, <<>>))),
            Root = toBinary(maps:get(rootCause, Args, maps:get(<<"rootCause">>, Args, <<>>))),
            Prev = toBinary(maps:get(prevention, Args, maps:get(<<"prevention">>, Args, <<>>))),
            Parts = [
                case Symptom of <<>> -> <<>>; _ -> <<"症状："/utf8, Symptom/binary>> end,
                case Root of <<>> -> <<>>; _ -> <<"根因："/utf8, Root/binary>> end,
                case Prev of <<>> -> <<>>; _ -> <<"规避："/utf8, Prev/binary>> end
            ],
            Joined = iolist_to_binary(lists:join(<<"\n">>, [P || P <- Parts, P =/= <<>>])),
            truncate(Joined, ?MaxCardBytes)
    end.

%%%===================================================================
%%% Internal
%%%===================================================================

autoRecord(Opts) ->
    AgentCfg = maps:get(agentCfg, Opts, alConfig:get(agent, #{})),
    maps:get(autoRecordLessons, Opts,
        maps:get(autoRecordLessons, AgentCfg, true)) =/= false.

fetchLessons(Query, Limit) ->
    Q = toBinary(Query),
    case alMemory:list(#{kind => lesson, q => Q, limit => Limit * 2}) of
        {ok, Rows} when Rows =/= [] ->
            [R || R <- Rows, not isSuperseded(R)];
        _ ->
            %% 无关键词命中时仍取最近教训，保证「熟悉度」不断档
            case alMemory:list(#{kind => lesson, limit => Limit}) of
                {ok, Rows2} -> [R || R <- Rows2, not isSuperseded(R)];
                _ -> []
            end
    end.

%% lesson 优先；同内容去重；限制条数。
mergeRecall(Lessons, General, Limit) ->
    Boosted = [R#{score => lessonBoost(R)} || R <- Lessons],
    Rest = [R || R <- General, not isLesson(R)],
    Merged = dedupRows(Boosted ++ Rest),
    Sorted = lists:sort(fun(A, B) ->
        maps:get(score, A, 0.0) >= maps:get(score, B, 0.0)
    end, Merged),
    [compactLesson(R) || R <- lists:sublist(Sorted, Limit)].

lessonBoost(Row) ->
    Base = maps:get(score, Row, 0.5),
    case isLesson(Row) of
        true ->
            Tags = maps:get(tags, Row, []),
            TagBoost = condPickTagBoost(Tags),
            StalePenalty = case isStale(Row) of true -> -0.35; false -> 0.0 end,
            Base + TagBoost + StalePenalty;
        false ->
            Base
    end.

%% 权重：用户纠正 > 已验证 > 成功路径 > 一般教训。
condPickTagBoost(Tags) ->
    HasTag = fun(T) -> lists:member(T, Tags) orelse lists:member(toBinary(T), Tags) end,
    case HasTag(correction) of
        true -> 0.35;
        false ->
            case HasTag(verified) of
                true -> 0.32;
                false ->
                    case HasTag(success) of
                        true -> 0.30;
                        false -> 0.25
                    end
            end
    end.

isLesson(Row) ->
    K = toBinary(maps:get(kind, Row, maps:get(<<"kind">>, Row, <<>>))),
    K =:= <<"lesson">>.

dedupRows(Rows) ->
    {_, Out} = lists:foldl(fun(R, {Seen, Acc}) ->
        Key = toBinary(maps:get(content, R, maps:get(<<"content">>, R, <<>>))),
        case maps:is_key(Key, Seen) orelse Key =:= <<>> of
            true -> {Seen, Acc};
            false -> {Seen#{Key => true}, [R | Acc]}
        end
    end, {#{}, []}, Rows),
    lists:reverse(Out).

compactLesson(Row) when is_map(Row) ->
    Meta = maps:get(metadata, Row, maps:get(<<"metadata">>, Row, #{})),
    Source = case is_map(Meta) of
        true -> maps:get(source, Meta, maps:get(<<"source">>, Meta, undefined));
        false -> undefined
    end,
    #{
        id => maps:get(id, Row, maps:get(<<"id">>, Row, undefined)),
        kind => maps:get(kind, Row, lesson),
        content => truncate(toBinary(maps:get(content, Row,
                            maps:get(<<"content">>, Row, <<>>))), 600),
        tags => maps:get(tags, Row, []),
        score => maps:get(score, Row, undefined),
        source => Source,
        stale => isStale(Row),
        createdAt => maps:get(createdAt, Row,
                        maps:get(<<"created_at">>, Row, undefined))
    };
compactLesson(Other) ->
    Other.

collectFailureBits(Trace, Critique) ->
    toolFailBits(Trace) ++ criticFailBits(Critique).

toolFailBits(Trace) when is_list(Trace) ->
    lists:foldl(fun
        ({results, Results}, Acc) when is_list(Results) ->
            Bits = lists:filtermap(fun(R) ->
                case resultErrorText(R) of
                    <<>> -> false;
                    T -> {true, T}
                end
            end, Results),
            Bits ++ Acc;
        (_, Acc) -> Acc
    end, [], Trace);
toolFailBits(_) -> [].

resultErrorText(#{content := C}) ->
    contentErrorText(C);
resultErrorText(_) ->
    <<>>.

contentErrorText(C) when is_map(C) ->
    case maps:get(status, C, ok) of
        error ->
            Reason = maps:get(reason, C, maps:get(error, C, <<"tool error">>)),
            iolist_to_binary([<<"tool:"/utf8>>, toBinary(Reason)]);
        _ -> <<>>
    end;
contentErrorText(C) when is_binary(C) ->
    try alJson:decode(C) of
        M when is_map(M) ->
            St = maps:get(<<"status">>, M, maps:get(status, M, undefined)),
            case St =:= <<"error">> orelse St =:= error of
                true ->
                    Reason = maps:get(<<"reason">>, M,
                                maps:get(reason, M, <<"tool error">>)),
                    iolist_to_binary([<<"tool:"/utf8>>, toBinary(Reason)]);
                false -> <<>>
            end;
        _ -> <<>>
    catch _:_ -> <<>>
    end;
contentErrorText(_) -> <<>>.

criticFailBits(Critique) when is_map(Critique) ->
    Verdict = maps:get(verdict, Critique, pass),
    case Verdict =:= reject orelse Verdict =:= warn of
        true ->
            Fb = toBinary(maps:get(feedback, Critique, <<>>)),
            [iolist_to_binary([<<"critic:"/utf8>>, atom_to_binary(Verdict, utf8),
                               <<" "/utf8>>, Fb])];
        false -> []
    end;
criticFailBits(_) -> [].

%%--------------------------------------------------------------------
%% @doc
%% 从本轮成功问答启发式提取有用知识 → lesson（默认开启）。
%% 含 MFA / 明确结论时写入；与旧经验冲突则 correctLesson。
%% @end
%%--------------------------------------------------------------------
-spec extractFromTurn(term(), term(), term(), map()) -> ok.
extractFromTurn(SessionId, Question, Answer, Critique) ->
    case enabled() andalso autoExtractTurn() andalso shouldExtractTurn(Question, Answer, Critique) of
        false ->
            ok;
        true ->
            try
                case extractFromTurnLlm(SessionId, Question, Answer, Critique) of
                    ok ->
                        ok;
                    skip ->
                        extractFromTurnHeuristic(SessionId, Question, Answer)
                end
            catch
                _:_ -> extractFromTurnHeuristic(SessionId, Question, Answer)
            end
    end.

extractFromTurnHeuristic(SessionId, Question, Answer) ->
    case buildTurnInsight(Question, Answer) of
        undefined ->
            ok;
        Cand ->
            persistTurnInsight(SessionId, Cand)
    end.

extractFromTurnLlm(SessionId, Question, Answer, Critique) ->
    case autoExtractTurnLlm() of
        false ->
            skip;
        true ->
            Q = truncate(toBinary(Question), 400),
            A = truncate(toBinary(Answer), 2000),
            Verdict = maps:get(verdict, Critique, pass),
            Prompt = [
                #{role => system, content =>
                    <<"从本轮已通过的问答中提取一条可长期保留的项目经验。"
                      "返回单个 JSON 对象（不要数组）："
                      "{\"symptom\":\"现象\",\"rootCause\":\"根因\","
                      "\"prevention\":\"下次怎么做/别踩什么坑\","
                      "\"relatedMfas\":[\"mod:fun/1\"],\"tags\":[\"pitfall\"]}"
                      "。只写从对话中能证实的结论；无关则返回 {}。只返回 JSON。"/utf8>>},
                #{role => user, content =>
                    iolist_to_binary([
                        <<"verdict="/utf8>>, atom_to_binary(Verdict, utf8),
                        <<"\n问："/utf8>>, Q, <<"\n答："/utf8>>, A
                    ])}
            ],
            case alLlmClient:chat(Prompt, #{llmRole => aux}) of
                {ok, #{content := Content}} ->
                    case parseLessonExtractJson(Content) of
                        undefined -> skip;
                        Cand -> persistTurnInsight(SessionId, Cand)
                    end;
                _ ->
                    skip
            end
    end.

persistTurnInsight(SessionId, Cand) ->
    Content = maps:get(content, Cand),
    Related = findRelatedLessons(Content, 3),
    case isNearDuplicate(Content, Related) of
        true -> ok;
        false ->
            _ = recordLesson(SessionId, Cand),
            ok
    end.

autoExtractTurnLlm() ->
    Agent = alConfig:get(agent, #{}),
    maps:get(autoExtractTurnLlm, Agent, true) =/= false.

parseLessonExtractJson(Content) when is_binary(Content) ->
    Trim = string:trim(Content),
    Json = case string:prefix(Trim, "```") of
        nomatch -> Trim;
        _ ->
            case re:run(Trim, "```(?:json)?\\s*([\\s\\S]*?)```",
                        [{capture, all_but_first, binary}]) of
                {match, [Inner]} -> Inner;
                _ -> Trim
            end
    end,
    try alJson:decode(Json) of
        #{} = Map ->
            case maps:size(Map) of
                0 -> undefined;
                _ -> lessonCandFromJson(Map)
            end;
        _ -> undefined
    catch
        _:_ -> undefined
    end;
parseLessonExtractJson(_) ->
    undefined.

lessonCandFromJson(Map) ->
    Symptom = fieldBin(Map, symptom, <<>>),
    Root = fieldBin(Map, rootCause, <<>>),
    Prev = fieldBin(Map, prevention, <<>>),
    case Symptom =:= <<>> andalso Root =:= <<>> andalso Prev =:= <<>> of
        true ->
            undefined;
        false ->
            Mfas = fieldList(Map, relatedMfas),
            Tags0 = fieldList(Map, tags),
            Tags = lists:usort([insight, llm | Tags0]),
            Body = iolist_to_binary([
                <<"【对话沉淀】"/utf8>>, <<"\n"/utf8>>,
                case Symptom of <<>> -> <<>>; _ -> [<<"现象："/utf8>>, Symptom, <<"\n"/utf8>>] end,
                case Root of <<>> -> <<>>; _ -> [<<"根因："/utf8>>, Root, <<"\n"/utf8>>] end,
                case Prev of <<>> -> <<>>; _ -> [<<"规避："/utf8>>, Prev] end
            ]),
            #{
                source => insight,
                content => Body,
                symptom => Symptom,
                rootCause => Root,
                prevention => Prev,
                relatedMfas => Mfas,
                tags => Tags,
                fingerprint => fingerprintOf(Body)
            }
    end.

fieldBin(Map, AtomKey, Default) ->
    V = maps:get(AtomKey, Map,
         maps:get(atom_to_binary(AtomKey, utf8), Map, Default)),
    toBinary(V).

fieldList(Map, AtomKey) ->
    V = maps:get(AtomKey, Map,
         maps:get(atom_to_binary(AtomKey, utf8), Map, [])),
    ensureList(V).

shouldExtractTurn(Question, Answer, Critique) ->
    Q = toBinary(Question),
    A = toBinary(Answer),
    Verdict = maps:get(verdict, Critique, pass),
    byte_size(A) >= 160
        andalso byte_size(Q) >= 6
        andalso (Verdict =:= pass orelse Verdict =:= warn)
        andalso not detectCorrection(Q)
        andalso not isTrivialQuestion(Q).

autoExtractTurn() ->
    Agent = alConfig:get(agent, #{}),
    maps:get(autoExtractTurnKnowledge, Agent, true) =/= false.

buildTurnInsight(Question, Answer) ->
    Q = toBinary(Question),
    A = toBinary(Answer),
    Mfas = extractMfas(A),
    case Mfas =/= [] orelse hasInsightCue(A) orelse hasInsightCue(Q) of
        false ->
            undefined;
        true ->
            Body = iolist_to_binary([
                <<"【对话沉淀】"/utf8>>, <<"\n"/utf8>>,
                <<"问："/utf8>>, truncate(Q, 200), <<"\n"/utf8>>,
                <<"要点："/utf8>>, truncate(insightBody(A, Mfas), 520)
            ]),
            #{
                source => insight,
                content => Body,
                symptom => truncate(Q, 160),
                prevention => <<"同类问题先召回本条，再查源码核实"/utf8>>,
                relatedMfas => Mfas,
                tags => [turn, auto, insight],
                fingerprint => fingerprintOf(Body)
            }
    end.

insightBody(Answer, []) ->
    Answer;
insightBody(Answer, Mfas) ->
    iolist_to_binary([
        <<"关键 MFA: "/utf8>>,
        lists:join(<<", ">>, lists:sublist(Mfas, 6)),
        <<"\n"/utf8>>,
        Answer
    ]).

extractMfas(Bin) when is_binary(Bin) ->
    case re:run(Bin,
                <<"([a-z][a-zA-Z0-9_]*)[:]([a-z][a-zA-Z0-9_]*)[/]([0-9]+)">>,
                [global, {capture, all_but_first, binary}]) of
        {match, Ms} ->
            lists:usort([iolist_to_binary([M, <<":">>, F, <<"/">>, A])
                         || [M, F, A] <- Ms]);
        _ ->
            []
    end;
extractMfas(_) -> [].

hasInsightCue(Bin) when is_binary(Bin) ->
    Cues = [<<"结论"/utf8>>, <<"根因"/utf8>>, <<"注意"/utf8>>, <<"必须"/utf8>>,
            <<"不要"/utf8>>, <<"应该"/utf8>>, <<"入口"/utf8>>, <<"规避"/utf8>>,
            <<"MFA">>, <<"behaviour">>, <<"gen_server">>],
    lists:any(fun(Cue) -> binary:match(Bin, Cue) =/= nomatch end, Cues);
hasInsightCue(_) -> false.

isTrivialQuestion(Q) ->
    Lower = try string:lowercase(Q) catch _:_ -> Q end,
    lists:member(Lower, [<<"hi">>, <<"ok">>, <<"yes">>, <<"no">>,
                         <<"你好"/utf8>>, <<"嗯"/utf8>>, <<"好的"/utf8>>]).

isNearDuplicate(_Content, []) ->
    false;
isNearDuplicate(Content, Related) ->
    lists:any(fun(R) ->
        overlapScore(Content, R) >= 3.0
            orelse fingerprintMatch(Content, R)
    end, Related).

fingerprintMatch(Content, Row) when is_map(Row) ->
    Meta = maps:get(metadata, Row, maps:get(<<"metadata">>, Row, #{})),
    OldFp = case is_map(Meta) of
        true -> toBinary(maps:get(fingerprint, Meta,
                    maps:get(<<"fingerprint">>, Meta, <<>>)));
        false -> <<>>
    end,
    OldFp =/= <<>> andalso OldFp =:= fingerprintOf(Content);
fingerprintMatch(_, _) ->
    false.

%%--------------------------------------------------------------------
%% @doc
%% 代码增量变更后对账经验：删除模块相关 lesson → 废止；变更模块相关 → 记 touched。
%% Digest 重建与 seed/纠错由索引后的 {@link alProjectDigest:maybeBuildAfterIndex/0} 负责。
%% 入参可为 vcsIndex 返回 map（含 statusMap）、`#{changed, deleted}`、或路径列表。
%% @end
%%--------------------------------------------------------------------
-spec reconcileAfterCodeChange(map() | [term()]) -> {ok, map()} | {error, term()}.
reconcileAfterCodeChange(#{changed := Changed0} = M) ->
    Deleted0 = maps:get(deleted, M, []),
    case enabled() of
        false ->
            {ok, #{reconciled => 0, reason => disabled}};
        true ->
            try
                ChangedMods = modulesFromPaths(Changed0),
                DeletedMods = modulesFromPaths(Deleted0),
                Obsolete = supersedeLessonsForModules(DeletedMods),
                Stale = markStaleLessonsForModules(ChangedMods),
                Touched = countLessonsForModules(ChangedMods),
                {ok, #{
                    deletedModules => DeletedMods,
                    changedModules => ChangedMods,
                    superseded => Obsolete,
                    stale => Stale,
                    touched => Touched
                }}
            catch
                Class:Reason ->
                    {error, {Class, Reason}}
            end
    end;
reconcileAfterCodeChange(Result) when is_map(Result) ->
    Status = maps:get(statusMap, Result, maps:get(<<"statusMap">>, Result, [])),
    reconcileAfterCodeChange(#{
        changed => pathsFromStatusMap(Status),
        deleted => deletedPathsFromStatusMap(Status)
    });
reconcileAfterCodeChange(Paths) when is_list(Paths) ->
    reconcileAfterCodeChange(#{changed => Paths, deleted => []}).

pathsFromStatusMap(Status) when is_list(Status) ->
    lists:usort(lists:filtermap(fun
        ({_St, Path}) -> {true, toBinary(Path)};
        (#{path := P}) -> {true, toBinary(P)};
        (#{<<"path">> := P}) -> {true, toBinary(P)};
        (P) when is_binary(P); is_list(P) -> {true, toBinary(P)};
        (_) -> false
    end, Status));
pathsFromStatusMap(_) -> [].

deletedPathsFromStatusMap(Status) when is_list(Status) ->
    lists:usort(lists:filtermap(fun
        ({St, Path}) ->
            case isDeletedStatus(St) of
                true -> {true, toBinary(Path)};
                false -> false
            end;
        (_) -> false
    end, Status));
deletedPathsFromStatusMap(_) -> [].

modulesFromPaths(Paths) ->
    lists:usort(lists:filtermap(fun(P) ->
        case alChangeImpact:moduleFromPath(P) of
            undefined -> false;
            Mod -> {true, Mod}
        end
    end, ensureList(Paths))).

isDeletedStatus(St) ->
    S = string:trim(to_list_status(St)),
    (length(S) >= 1 andalso (lists:nth(1, S) =:= $D orelse lists:nth(1, S) =:= $!))
        orelse (length(S) >= 2 andalso lists:nth(2, S) =:= $D).

to_list_status(S) when is_list(S) -> S;
to_list_status(B) when is_binary(B) -> unicode:characters_to_list(B);
to_list_status(A) when is_atom(A) -> atom_to_list(A);
to_list_status(_) -> "".

supersedeLessonsForModules([]) ->
    0;
supersedeLessonsForModules(Mods) ->
    lists:sum([supersedeLessonsForModule(M) || M <- Mods]).

supersedeLessonsForModule(Mod) ->
    Needle = toBinary(Mod),
    Rows = findRelatedLessons(Needle, 20),
    lists:foldl(fun(Row, Acc) ->
        case maps:get(id, Row, undefined) of
            undefined -> Acc;
            Id ->
                case lessonMentionsModule(Row, Needle) of
                    true ->
                        _ = try alMemory:markSuperseded(Id, undefined) catch _:_ -> ok end,
                        Acc + 1;
                    false ->
                        Acc
                end
        end
    end, 0, Rows).

countLessonsForModules([]) ->
    0;
countLessonsForModules(Mods) ->
    lists:sum([length(findRelatedLessons(toBinary(M), 10)) || M <- Mods]).

lessonMentionsModule(Row, Needle) when is_map(Row), is_binary(Needle) ->
    Content = toBinary(maps:get(content, Row, maps:get(<<"content">>, Row, <<>>))),
    Meta = maps:get(metadata, Row, maps:get(<<"metadata">>, Row, #{})),
    Mfas = case is_map(Meta) of
        true -> ensureList(maps:get(relatedMfas, Meta,
                        maps:get(<<"relatedMfas">>, Meta, [])));
        false -> []
    end,
    binary:match(Content, Needle) =/= nomatch
        orelse lists:any(fun(M) -> binary:match(toBinary(M), Needle) =/= nomatch end, Mfas);
lessonMentionsModule(_, _) ->
    false.

%%--------------------------------------------------------------------
%% @doc 编译/测试失败写入 pitfall lesson。
%% @end
%%--------------------------------------------------------------------
-spec recordBuildFailure(map()) -> ok.
recordBuildFailure(Args) when is_map(Args) ->
    case enabled() of
        false -> ok;
        true ->
            File = toBinary(maps:get(file, Args,
                           maps:get(patch, Args, maps:get(command, Args, <<>>)))),
            Output = truncate(toBinary(maps:get(output, Args,
                                    maps:get(detail, Args, <<>>))), 800),
            Reason = maps:get(reason, Args, compileFailed),
            Tags = case maps:get(tags, Args, [compile, pitfall]) of
                L when is_list(L) -> L;
                _ -> [compile, pitfall]
            end,
            _ = recordLesson(#{
                source => failure,
                symptom => iolist_to_binary([<<"构建失败："/utf8>>, File]),
                rootCause => Output,
                prevention => <<"修复编译/测试错误后再 applyPatch；查本条避免重复踩坑"/utf8>>,
                content => iolist_to_binary([
                    <<"【构建失败】"/utf8>>, Reason, <<"\n文件/命令："/utf8>>, File,
                    <<"\n输出："/utf8>>, Output
                ]),
                relatedPaths => [File],
                tags => Tags
            }),
            ok
    end;
recordBuildFailure(_) ->
    ok.

isStale(Row) when is_map(Row) ->
    Meta = maps:get(metadata, Row, maps:get(<<"metadata">>, Row, #{})),
    Tags = maps:get(tags, Row, []),
    maps:get(stale, Row, false) =:= true
        orelse (is_map(Meta) andalso (
            maps:get(stale, Meta, false) =:= true
            orelse maps:get(<<"stale">>, Meta, false) =:= true
        ))
        orelse lists:member(stale, Tags)
        orelse lists:member(<<"stale">>, Tags);
isStale(_) ->
    false.

markStaleLessonsForModules([]) ->
    0;
markStaleLessonsForModules(Mods) ->
    lists:sum([markStaleLessonsForModule(M) || M <- Mods]).

markStaleLessonsForModule(Mod) ->
    Needle = toBinary(Mod),
    Rows = findRelatedLessons(Needle, 20),
    lists:foldl(fun(Row, Acc) ->
        case maps:get(id, Row, undefined) of
            undefined -> Acc;
            Id ->
                case lessonMentionsModule(Row, Needle) of
                    true ->
                        case isStale(Row) of
                            true -> Acc;
                            false ->
                                _ = try alMemory:patchMetadata(Id, #{
                                    stale => true,
                                    staleAt => erlang:system_time(second),
                                    staleModules => [Mod]
                                }) catch _:_ -> ok end,
                                Acc + 1
                        end;
                    false ->
                        Acc
                end
        end
    end, 0, Rows).

unifiedScore(Row) when is_map(Row) ->
    maps:get(score, Row, 0.4).

scoreMemoryRow(R) ->
    Now = erlang:system_time(second),
    Sem = maps:get(score, R, maps:get(semanticScore, R, 0.5)),
    R#{score => alMemory:finalScore(Sem, R, Now)}.

compactMemoryRow(R) when is_map(R) ->
    #{
        kind => maps:get(kind, R, maps:get(<<"kind">>, R, note)),
        content => truncate(toBinary(maps:get(content, R,
                            maps:get(<<"content">>, R, <<>>))), 500),
        score => maps:get(score, R, undefined),
        fromKnowledge => false
    }.

compactKnowledgeRow(R) when is_map(R) ->
    R#{fromKnowledge => true}.

knowledgeHitsToRows(undefined) ->
    [];
knowledgeHitsToRows(#{hits := Hits}) when is_list(Hits) ->
    [#{
        kind => knowledge,
        fromKnowledge => true,
        content => truncate(knowledgeHitText(H), 500),
        score => 0.55 + knowledgeHitScore(H) * 0.2,
        title => maps:get(title, H, maps:get(<<"title">>, H, <<>>))
    } || H <- Hits, is_map(H)];
knowledgeHitsToRows(_) ->
    [].

knowledgeHitText(H) ->
    toBinary(maps:get(summary, H,
        maps:get(<<"summary">>, H,
            maps:get(text, H, maps:get(<<"text">>, H, <<>>))))).

knowledgeHitScore(H) ->
    case maps:get(score, H, maps:get(<<"score">>, H, 0.0)) of
        S when is_number(S) -> S;
        _ -> 0.0
    end.

%%%===================================================================
%%% Digest seed helpers
%%%===================================================================

fromActions(Actions) ->
    lists:filtermap(fun(A) when is_map(A) ->
        Phrase = toBinary(maps:get(phrase, A, maps:get(<<"phrase">>, A, <<>>))),
        Mfa = toBinary(maps:get(mfa, A, maps:get(<<"mfa">>, A, <<>>))),
        case Phrase =/= <<>> andalso Mfa =/= <<>> of
            false -> false;
            true ->
                Content = iolist_to_binary([
                    <<"[digest] 业务动作「"/utf8>>, Phrase,
                    <<"」对应 MFA "/utf8>>, Mfa,
                    <<"。NL 查改优先 lookupAction / 该 MFA，勿臆造函数名。"/utf8>>
                ]),
                {true, digestCand(Content, insight, [digest_seed, action],
                                  #{relatedMfas => [Mfa],
                                    symptom => Phrase,
                                    prevention => Mfa})}
        end;
    (_) -> false
    end, lists:sublist(Actions, 25)).

fromTables(Data) when is_map(Data) ->
    Tables = maps:get(tables, Data, maps:get(<<"tables">>, Data, #{})),
    case is_map(Tables) of
        false -> [];
        true ->
            Items = maps:to_list(Tables),
            lists:filtermap(fun({Tab, Callers}) ->
                TabBin = toBinary(Tab),
                CallerList = ensureList(Callers),
                Mfas = lists:filtermap(fun(C) when is_map(C) ->
                    case maps:get(mfa, C, maps:get(<<"mfa">>, C, undefined)) of
                        undefined -> false;
                        M -> {true, toBinary(M)}
                    end;
                (_) -> false
                end, lists:sublist(CallerList, 3)),
                case Mfas of
                    [] -> false;
                    _ ->
                        Content = iolist_to_binary([
                            <<"[digest] 表/数据源「"/utf8>>, TabBin,
                            <<"」主要经 "/utf8>>,
                            lists:join(<<", ">>, Mfas),
                            <<" 访问。查改该表先走这些 MFA。"/utf8>>
                        ]),
                        {true, digestCand(Content, insight, [digest_seed, table],
                                          #{relatedMfas => Mfas,
                                            symptom => TabBin})}
                end
            end, lists:sublist(Items, 20))
    end;
fromTables(_) -> [].

fromBehaviours(Ctxs) when is_map(Ctxs) ->
    Items = maps:to_list(Ctxs),
    lists:filtermap(fun({Mod, Ctx}) when is_map(Ctx) ->
        Beh = ensureList(maps:get(behaviours, Ctx,
                        maps:get(<<"behaviours">>, Ctx, []))),
        BehBins = [toBinary(B) || B <- Beh, B =/= <<>>, B =/= undefined],
        Interesting = [B || B <- BehBins,
                            lists:member(B, [<<"gen_server">>, <<"gen_statem">>,
                                             <<"supervisor">>, <<"gen_event">>,
                                             <<"application">>])],
        case Interesting of
            [] -> false;
            _ ->
                ModBin = toBinary(Mod),
                Content = iolist_to_binary([
                    <<"[digest] 模块 "/utf8>>, ModBin,
                    <<" 实现 "/utf8>>, lists:join(<<"/">>, Interesting),
                    <<"。改其状态/回调前先 getSymbolSource 读回调，"
                      "热更注意导出兼容。"/utf8>>
                ]),
                {true, digestCand(Content, insight, [digest_seed, otp],
                                  #{relatedPaths => [],
                                    symptom => ModBin})}
        end;
    (_) -> false
    end, lists:sublist(Items, 30));
fromBehaviours(List) when is_list(List) ->
    %% 允许 [{Mod, Ctx}] 或 [#{module := ..., behaviours := ...}]
    fromBehaviours(maps:from_list([
        case E of
            {M, C} -> {M, C};
            M when is_map(M) ->
                {maps:get(module, M, maps:get(<<"module">>, M, unknown)), M};
            _ -> {unknown, #{}}
        end || E <- List
    ]));
fromBehaviours(_) -> [].

digestCand(Content, Source, Tags, Extra) when is_map(Extra) ->
    Card = truncate(Content, ?MaxCardBytes),
    Fp = fingerprintOf(Card),
    Extra#{
        content => Card,
        source => Source,
        tags => Tags,
        fingerprint => Fp
    }.

existingDigestFingerprints() ->
    try
        case alMemory:list(#{kind => lesson, tag => digest_seed, limit => 200}) of
            {ok, Rows} ->
                lists:foldl(fun(R, Acc) ->
                    case isSuperseded(R) of
                        true -> Acc;
                        false ->
                            Meta = maps:get(metadata, R, #{}),
                            case is_map(Meta) of
                                true ->
                                    case maps:get(fingerprint, Meta,
                                             maps:get(<<"fingerprint">>, Meta, undefined)) of
                                        undefined -> Acc;
                                        Fp -> Acc#{toBinary(Fp) => true}
                                    end;
                                false -> Acc
                            end
                    end
                end, #{}, Rows);
            _ -> #{}
        end
    catch
        _:_ -> #{}
    end.

%% digest 种子：同 MFA / 同症状主题但指纹不同 → 视为旧经验过期
relatedDigestConflict(Cand) when is_map(Cand) ->
    Mfas = [toBinary(M) || M <- ensureList(maps:get(relatedMfas, Cand, []))],
    Symptom = toBinary(maps:get(symptom, Cand, <<>>)),
    Keys = [K || K <- Mfas ++ [Symptom], byte_size(K) >= 3],
    case Keys of
        [] -> [];
        _ ->
            Found = lists:append([
                case alMemory:list(#{kind => lesson, tag => digest_seed, q => K, limit => 5}) of
                    {ok, Rows} ->
                        [R || R <- Rows, not isSuperseded(R),
                              digestConflictMatch(Cand, R)];
                    _ -> []
                end || K <- lists:sublist(Keys, 3)
            ]),
            dedupById(Found)
    end.

digestConflictMatch(Cand, Row) ->
    NewFp = toBinary(maps:get(fingerprint, Cand, <<>>)),
    Meta = maps:get(metadata, Row, #{}),
    OldFp = case is_map(Meta) of
        true -> toBinary(maps:get(fingerprint, Meta,
                    maps:get(<<"fingerprint">>, Meta, <<>>)));
        false -> <<>>
    end,
    NewFp =/= <<>> andalso OldFp =/= <<>> andalso NewFp =/= OldFp.

correctionQuery(Args) when is_map(Args) ->
    Parts = [
        toBinary(maps:get(content, Args, maps:get(<<"content">>, Args, <<>>))),
        toBinary(maps:get(symptom, Args, maps:get(<<"symptom">>, Args, <<>>))),
        toBinary(maps:get(rootCause, Args, maps:get(<<"rootCause">>, Args, <<>>))),
        toBinary(maps:get(prevention, Args, maps:get(<<"prevention">>, Args, <<>>)))
    ],
    Mfas = [toBinary(M) || M <- ensureList(maps:get(relatedMfas, Args,
                                maps:get(<<"relatedMfas">>, Args, [])))],
    iolist_to_binary(lists:join(<<" ">>, [P || P <- Parts ++ Mfas, P =/= <<>>])).

formatCorrectionContent(Args, OldRows) when is_map(Args), is_list(OldRows) ->
    NewBody = case formatCard(Args) of
        <<>> -> toBinary(maps:get(content, Args, <<>>));
        C -> C
    end,
    OldPreviews = lists:sublist([
        truncate(toBinary(maps:get(content, R, <<>>)), 120)
        || R <- OldRows
    ], 3),
    iolist_to_binary([
        <<"[已纠正] "/utf8>>, NewBody, <<"\n"/utf8>>,
        <<"废止旧经验："/utf8>>,
        lists:join(<<" | "/utf8>>, OldPreviews)
    ]).

significantTokens(Bin) ->
    Lower = try string:lowercase(toBinary(Bin)) catch _:_ -> toBinary(Bin) end,
    %% 按空白与常见分隔切开，过滤短 token
    Parts = re:split(Lower, <<"[\\s,;:|/\\\\<>\\[\\](){}\"'，。；：、]+"/utf8>>,
                     [{return, binary}, trim]),
    [P || P <- Parts, byte_size(P) >= 3,
          not lists:member(P, [<<"the">>, <<"and">>, <<"for">>, <<"with">>,
                               <<"digest">>, <<"lesson">>, <<"http">>])].

dedupById(Rows) ->
    {_, Out} = lists:foldl(fun(R, {Seen, Acc}) ->
        Id = maps:get(id, R, undefined),
        case Id =:= undefined orelse maps:is_key(Id, Seen) of
            true -> {Seen, Acc};
            false -> {Seen#{Id => true}, [R | Acc]}
        end
    end, {#{}, []}, Rows),
    lists:reverse(Out).

normalizeSource(failure) -> failure;
normalizeSource(<<"failure">>) -> failure;
normalizeSource(correction) -> correction;
normalizeSource(<<"correction">>) -> correction;
normalizeSource(insight) -> insight;
normalizeSource(<<"insight">>) -> insight;
normalizeSource(manual) -> manual;
normalizeSource(<<"manual">>) -> manual;
normalizeSource(_) -> manual.

ensureList(L) when is_list(L) -> L;
ensureList(B) when is_binary(B), B =/= <<>> -> [B];
ensureList(A) when is_atom(A) -> [A];
ensureList(_) -> [].

toAtomOrBin(A) when is_atom(A) -> A;
toAtomOrBin(B) when is_binary(B) ->
    try binary_to_existing_atom(B, utf8) catch _:_ -> B end;
toAtomOrBin(L) when is_list(L) -> toAtomOrBin(unicode:characters_to_binary(L));
toAtomOrBin(X) -> toBinary(X).

truncate(Bin, Max) when is_binary(Bin), byte_size(Bin) > Max ->
    <<(binary:part(Bin, 0, Max))/binary, "...">>;
truncate(Bin, _) when is_binary(Bin) -> Bin;
truncate(Other, Max) -> truncate(toBinary(Other), Max).

toBinary(B) when is_binary(B) -> B;
toBinary(A) when is_atom(A) -> atom_to_binary(A, utf8);
toBinary(L) when is_list(L) -> unicode:characters_to_binary(L);
toBinary(I) when is_integer(I) -> integer_to_binary(I);
toBinary(M) when is_map(M) ->
    try alJson:encode(M) catch _:_ -> iolist_to_binary(io_lib:format("~p", [M])) end;
toBinary(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).
