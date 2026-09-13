%%%-------------------------------------------------------------------
%% @doc 助手与 LLM 工具调用共用的统一工具路由器。
%% @end
%%%-------------------------------------------------------------------

-module(alToolRouter).

-export([ask/2, runWithTools/2, callTool/2, callTool/3, toolDefinitions/0,
         maybePrefetchedSearch/3, resumeToolLoop/2, resumeToolLoop/3,
         resumeFromCheckpoint/1, resumeFromCheckpoint/2, resumeFromCheckpoint/3,
         isRuntimeQuestion/1, isCodeLogicQuestion/1, hasWholeWord/2]).

-ifdef(TEST).
-export([trimToolMessages/1, trimToolMessages/2]).
%% Test exports
-export([approxResultBytes/1,
         classifyHealFailures/1,
         healForcedWorkflow/1,
         latestBatchPlan/1,
         classifyHealFailureText/1,
         callGraphFilters/1,
         unwrapCoreData/1,
         filterByPaths/2,
         normalizeSearchMode/1,
         parseDirectExecCall/1,
         parseCallExpr/1,
         literalToTerm/1,
         parseDirectRuntimeProbe/1,
         looksLikeToolNarration/1,
         isVcsOrCodeReviewQuestion/1,
         toolFingerprint/2,
         buildTruncationMeta/4,
         paginationHintFor/2,
         effectiveMaxToolMsgPairs/2,
         registerToolIntent/2,
         roundMsgsTruncated/1,
         findPendingTool/2,
         pendingTaskId/1,
         groupToolCallsByWrite/1,
         isWriteToolCall/1,
         executeToolCalls/2,
         collectToolResults/3,
         prefetchTargets/1,
         toolDefinitions/1]).
-endif.

-define(DefaultMaxToolSteps, 50).
-define(LiveDataMaxToolSteps, 80).
%% 保留最近几轮工具消息即可；过多会把大结果反复送进 LLM 烧 token。
%% 默认 8 轮（配合 DeepSeek 1M 上下文），可在 Opts/agentCfg 中通过
%% maxToolMsgPairs 覆盖；token 紧张时 trimToolMessages 会动态压到 4。
-define(MaxToolMsgPairs, 8).
-define(MaxToolMsgPairsLowBudget, 4).
%% 写后 digest 重建节流：默认 30s 内最多触发一次，避免批量写反复全量重建。
-define(DigestRebuildThrottleMs, 30000).
-define(DigestRebuildThrottleKey, {alToolRouter, digestLast}).
%% 截断阈值已上调以配合 DeepSeek 1M 上下文：原来 12KB 易触发截断→模型反复重调。
%% 新阈值让单次工具结果足以覆盖完整函数体/调用方列表，避免「截断→重试→再截断」循环。
-define(MaxToolResultBytes, 32000).
-define(MaxReadToolResultBytes, 96000).
-define(MaxCallGraphResultBytes, 48000).
-define(MaxRunMfaResultBytes, 128000).
%% 触发自动减半重试的阈值：与 MaxToolResultBytes 保持比例（约 1.5x 默认预算），
%% 避免刚过预算就重试导致额外开销。
-define(DefaultMaxToolContentBytes, 48000).
%% Token 预算：DeepSeek 1M 上下文下取 1/4（256K）作为工具循环软上限，
%% 留 3/4 给 system prompt、对话历史与最终输出。
-define(DefaultTokenBudget, 256000).
-define(DefaultToolConcurrency, 3).
-define(ToolFpCacheKey, ali_tool_fp_cache).
%% 调用意图日志：记录本会话已调用的 (工具, 目标实体) 二元组，用于检测重复读取。
-define(ToolIntentLogKey, ali_tool_intent_log).

%%--------------------------------------------------------------------
%% @doc
%% 主入口：根据会话选项执行一次问答（自动选择带工具或纯 LLM 模式）。
%%
%% @param Question 用户问题
%% @param Opts 选项 map（含 sessionId 等）
%% @return `{ok, Reply}' 或 `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
ask(Question, Opts) ->
    SessionId = maps:get(sessionId, Opts, undefined),
    case ensureSession(SessionId, Opts) of
        ok ->
            askWithSession(Question, Opts, SessionId);
        {error, Reason} ->
            {error, Reason}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 强制使用工具循环模式执行问答（忽略 Opts 中的 tools 开关）。
%%
%% @param Question 用户问题
%% @param Opts 选项 map
%% @return `{ok, Reply}' 或 `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
runWithTools(Question, Opts) ->
    SessionId = maps:get(sessionId, Opts, undefined),
    case ensureSession(SessionId, Opts) of
        ok ->
            case maps:get(tools, Opts, true) of
                false -> askPlain(Question, Opts);
                _ -> runWithToolsSession(Question, Opts, SessionId)
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 在已校验的会话中执行问答：先记录用户消息，按 tools 开关选择
%% 带工具循环或纯 LLM 路径，最后追加 assistant 回复并附带 sessionId。
%%
%% @param Question 用户问题
%% @param Opts 选项 map
%% @param SessionId 会话 id
%% @return `{ok, Reply#{sessionId => SessionId}}' 或原 Result
%% @end
%%--------------------------------------------------------------------
askWithSession(Question, Opts, SessionId) ->
    maybeAppendMessage(SessionId, Opts, #{role => user, content => Question}),
    Result = case maps:get(tools, Opts, true) of
        true -> runWithToolsSession(Question, Opts, SessionId);
        false -> askPlain(Question, Opts)
    end,
    case Result of
        {ok, #{answer := Answer} = Reply} ->
            maybeAppendMessage(SessionId, Opts, #{role => assistant, content => Answer}),
            {ok, Reply#{sessionId => SessionId}};
        Other ->
            Other
    end.

%%--------------------------------------------------------------------
%% @doc
%% 构建上下文（含记忆）、系统提示与消息列表，启动工具循环 toolLoop。
%%
%% @param Question 用户问题
%% @param Opts 选项 map
%% @param SessionId 会话 id
%% @return toolLoop 返回的 `{ok, Reply}' 结果
%% @end
%%--------------------------------------------------------------------
runWithToolsSession(Question, Opts, SessionId) ->
    case maybeDirectExecMfa(Question, Opts) of
        {ok, _} = Direct ->
            Direct;
        skip ->
            case maybeDirectRuntimeProbe(Question, Opts) of
                {ok, _} = Probe ->
                    Probe;
                skip ->
                    runWithToolsSessionLlm(Question, Opts, SessionId)
            end
    end.

%% 「执行一下 erlang:localtime()」这类明确 MFA：直接 runMfa，不依赖模型是否发出 tool_calls。
%% 模型常会只在正文里写「选择工具：runMfa / 执行：」然后结束，导致网页看不到返回值。
maybeDirectExecMfa(Question, Opts) ->
    case parseDirectExecCall(Question) of
        {ok, Module, Function, Args} ->
            emitProgress(Opts, #{type => step, phase => runtime,
                                 message => iolist_to_binary(io_lib:format(
                                     "direct runMfa ~s:~s/~w",
                                     [Module, Function, length(Args)]))}),
            ToolArgs = #{
                module => Module,
                function => Function,
                args => Args,
                sideEffect => read,
                caller => interactive
            },
            case dispatchTool(runMfa, ToolArgs, Opts) of
                {ok, Result} ->
                    Answer = formatDirectExecAnswer(Module, Function, Args, Result),
                    emitProgress(Opts, #{type => toolFinished, tool => runMfa,
                                         ok => true, result => Result}),
                    {ok, #{
                        answer => Answer,
                        context => #{directExec => true},
                        toolCalls => [#{name => runMfa, args => ToolArgs}],
                        trace => [{directExec, Module, Function, length(Args)}]
                    }};
                {error, Reason} ->
                    Answer = formatDirectExecError(Module, Function, Args, Reason),
                    emitProgress(Opts, #{type => toolFinished, tool => runMfa,
                                         ok => false, error => Reason}),
                    {ok, #{
                        answer => Answer,
                        context => #{directExec => true},
                        toolCalls => [],
                        trace => [{directExecError, Reason}]
                    }}
            end;
        error ->
            skip
    end.

%% 「占用内存最高的 ets / 进程」等明确观测问句：直达 getEts/getProcesses/getRuntime，
%% 不依赖模型是否发出 tool_calls（DeepSeek 常只写「我来搜索」然后结束）。
maybeDirectRuntimeProbe(Question, Opts) ->
    case parseDirectRuntimeProbe(Question) of
        {ok, Tool, Args} ->
            emitProgress(Opts, #{type => step, phase => runtime,
                                 message => iolist_to_binary(io_lib:format(
                                     "direct ~s ~p", [Tool, Args]))}),
            case dispatchTool(Tool, Args, Opts) of
                {ok, Result} ->
                    Answer = formatDirectProbeAnswer(Tool, Result),
                    emitProgress(Opts, #{type => toolFinished, tool => Tool,
                                         ok => true, result => Result}),
                    {ok, #{
                        answer => Answer,
                        context => #{directProbe => true, tool => Tool},
                        toolCalls => [#{name => Tool, args => Args}],
                        trace => [{directProbe, Tool}]
                    }};
                {error, Reason} ->
                    Answer = formatDirectProbeError(Tool, Reason),
                    emitProgress(Opts, #{type => toolFinished, tool => Tool,
                                         ok => false, error => Reason}),
                    {ok, #{
                        answer => Answer,
                        context => #{directProbe => true, tool => Tool},
                        toolCalls => [],
                        trace => [{directProbeError, Tool, Reason}]
                    }}
            end;
        error ->
            skip
    end.

%% 明确可直达的运行时观测问句 → {ok, Tool, Args} | error
parseDirectRuntimeProbe(Question) ->
    Q = string:lowercase(unicode:characters_to_list(to_binary(Question))),
    Has = fun(K) -> string:find(Q, K) =/= nomatch end,
    case Has("ets") andalso (Has("内存") orelse Has("memory") orelse Has("占用")
                             orelse Has("最高") orelse Has("top") orelse Has("最大")
                             orelse Has("有哪些") orelse Has("列表") orelse Has("查看")) of
        true ->
            {ok, getEts, #{limit => 10}};
        false ->
            case (Has("进程") orelse Has("process"))
                 andalso (Has("内存") orelse Has("memory") orelse Has("mailbox")
                          orelse Has("消息队列") orelse Has("最高") orelse Has("top")) of
                true ->
                    {ok, getProcesses, #{limit => 10, sortBy => memory}};
                false ->
                    case Has("运行时快照") orelse Has("节点快照")
                         orelse Has("runtime snapshot") orelse Has("getruntime") of
                        true -> {ok, getRuntime, #{}};
                        false -> error
                    end
            end
    end.

formatDirectProbeAnswer(Tool, Result) ->
    Title = iolist_to_binary(io_lib:format("~s =>", [Tool])),
    Body = try iolist_to_binary(io_lib:format("~p", [Result]))
           catch _:_ ->
               try unicode:characters_to_binary(alJson:encode(Result))
               catch _:_ -> <<"ok">> end
           end,
    <<Title/binary, "\n", Body/binary>>.

formatDirectProbeError(Tool, Reason) ->
    Title = iolist_to_binary(io_lib:format("~s failed:", [Tool])),
    Body = try iolist_to_binary(io_lib:format("~p", [Reason]))
           catch _:_ -> <<"error">> end,
    <<Title/binary, " ", Body/binary>>.

%% 匹配：执行一下 / 执行 / 跑一下 / 调用一下 + Mod:Fun() 或 Mod:Fun/Arity
parseDirectExecCall(Question) ->
    Bin0 = string:trim(to_binary(Question)),
    case stripDirectExecPrefix(Bin0) of
        {ok, Rest0} ->
            Rest = string:trim(Rest0),
            parseDirectExecMfa(Rest);
        error ->
            error
    end.

stripDirectExecPrefix(Bin) ->
    Prefixes = [
        <<"请帮忙执行一下"/utf8>>, <<"请执行一下"/utf8>>, <<"帮忙执行一下"/utf8>>,
        <<"执行一下"/utf8>>, <<"跑一下"/utf8>>, <<"调用一下"/utf8>>,
        <<"请执行"/utf8>>, <<"请运行"/utf8>>, <<"请调用"/utf8>>,
        <<"执行"/utf8>>, <<"运行"/utf8>>, <<"调用"/utf8>>
    ],
    stripDirectExecPrefix(Bin, Prefixes).

stripDirectExecPrefix(_Bin, []) ->
    error;
stripDirectExecPrefix(Bin, [P | Rest]) ->
    PSize = byte_size(P),
    case Bin of
        <<P:PSize/binary, Tail/binary>> ->
            %% 前缀后须有空白或直接接 MFA，避免「执行函数」误伤
            case Tail of
                <<>> -> error;
                <<C, _/binary>> when C =:= $\s; C =:= $\t; C =:= $\n ->
                    {ok, string:trim(Tail)};
                <<C, _/binary>> when C >= $a, C =< $z; C >= $A, C =< $Z ->
                    {ok, Tail};
                _ ->
                    stripDirectExecPrefix(Bin, Rest)
            end;
        _ ->
            stripDirectExecPrefix(Bin, Rest)
    end.

%% Rest = "erlang:localtime()" | "erlang:localtime/0" | "erlang:localtime"
parseDirectExecMfa(Rest) ->
    case re:run(Rest,
                <<"^([a-z][a-zA-Z0-9_]*)\\s*:\\s*([a-z][a-zA-Z0-9_]*)\\s*(?:/\\s*(\\d+)|\\(([^)]*)\\))?\\s*$">>,
                [{capture, all_but_first, binary}]) of
        {match, [ModBin, FunBin]} ->
            finishDirectExecParse(ModBin, FunBin, <<>>, <<>>);
        {match, [ModBin, FunBin, ArityBin, ArgsBin]} ->
            finishDirectExecParse(ModBin, FunBin, ArityBin, ArgsBin);
        {match, [ModBin, FunBin, Third]} ->
            case re:run(Third, <<"^\\d+$">>) of
                {match, _} -> finishDirectExecParse(ModBin, FunBin, Third, <<>>);
                nomatch -> finishDirectExecParse(ModBin, FunBin, <<>>, Third)
            end;
        nomatch ->
            error
    end.

finishDirectExecParse(ModBin, FunBin, ArityBin, ArgsBin) ->
    try
        Module = binary_to_existing_atom(ModBin, utf8),
        Function = binary_to_existing_atom(FunBin, utf8),
        Args = case ArgsBin of
            <<>> when ArityBin =:= <<>> -> [];
            <<>> ->
                %% 仅写了 /0：无参
                case binary_to_integer(ArityBin) of
                    0 -> [];
                    _ -> error(needArgs)
                end;
            _ ->
                parseDirectExecArgs(ArgsBin)
        end,
        {ok, Module, Function, Args}
    catch
        _:_ -> error
    end.

%% 极简实参：空、数字、atom、双引号/单引号字符串、true/false
parseDirectExecArgs(<<>>) -> [];
parseDirectExecArgs(Bin) ->
    Parts = [string:trim(P) || P <- binary:split(Bin, <<",">>, [global]), P =/= <<>>],
    [parseDirectExecArg(P) || P <- Parts].

parseDirectExecArg(<<"true">>) -> true;
parseDirectExecArg(<<"false">>) -> false;
parseDirectExecArg(<<"undefined">>) -> undefined;
parseDirectExecArg(<<$", Rest/binary>>) ->
    case binary:last(Rest) of
        $" -> binary:part(Rest, 0, byte_size(Rest) - 1);
        _ -> Rest
    end;
parseDirectExecArg(<<$', Rest/binary>>) ->
    case binary:last(Rest) of
        $' -> binary:part(Rest, 0, byte_size(Rest) - 1);
        _ -> Rest
    end;
parseDirectExecArg(Bin) ->
    try binary_to_integer(Bin) catch _:_ ->
        try binary_to_float(Bin) catch _:_ ->
            try binary_to_existing_atom(Bin, utf8) catch _:_ -> Bin end
        end
    end.

formatDirectExecAnswer(Module, Function, Args, Result) ->
    Mfa = iolist_to_binary(io_lib:format("~s:~s/~w", [Module, Function, length(Args)])),
    Body = try iolist_to_binary(io_lib:format("~p", [Result]))
           catch _:_ -> unicode:characters_to_binary(alJson:encode(Result)) end,
    <<Mfa/binary, " => ", Body/binary>>.

formatDirectExecError(Module, Function, Args, Reason) ->
    Mfa = iolist_to_binary(io_lib:format("~s:~s/~w", [Module, Function, length(Args)])),
    Body = try iolist_to_binary(io_lib:format("~p", [Reason]))
           catch _:_ -> <<"error">> end,
    <<Mfa/binary, " failed: ", Body/binary>>.

runWithToolsSessionLlm(Question, Opts, SessionId) ->
    AgentCfg = maps:get(agentCfg, Opts, alConfig:getAgentCfg()),
    Mode = maps:get(mode, Opts, ask),
    BasePolicy = maps:get(policy, Opts,
                          maps:get(policy, AgentCfg, alPolicy:defaultPolicy())),
    Policy = maps:merge(BasePolicy, alPolicy:policyForMode(Mode)),
    Opts1 = Opts#{
        sessionId => SessionId,
        agentCfg => AgentCfg,
        mode => Mode,
        policy => Policy,
        currentQuestion => Question,
        %% 运行时/活数据查询：跳过上下文预取里的 decompose/rewrite LLM，直接搜+进主循环
        skipQueryLlm => isRuntimeQuestion(Question)
    },
    Opts1b = maybeDefaultHealOpts(Opts1, Mode, AgentCfg),
    Preferred = preferredToolsForQuestion(Question, Opts1b),
    Context = buildContext(Question, Opts1b#{preferredTools => Preferred}),
    emitProgress(Opts1b, #{type => step, phase => ready,
                          message => <<"context built; calling model...">>}),
    SearchLimit = maps:get(searchLimit, Opts1b, 6),
    %% 预取查询使用改写后的搜索词（若可用），让 searchCode 工具能命中缓存。
    PrefetchQuery = case maps:get(searchQuery, Context, undefined) of
        undefined -> normalizeSearchQuery(Question);
        SQ -> normalizeSearchQuery(SQ)
    end,
    Opts2 = Opts1b#{
        preferredTools => Preferred,
        prefetchSearch => #{
            query => PrefetchQuery,
            hits => maps:get(codeHits, Context, [])
        },
        prefetchLimit => SearchLimit
    },
    History0 = sessionMessages(SessionId, Opts2),
    History = dropTrailingCurrentUser(History0, Question),
    UserMsg = userMessageWithAttachments(Question, Opts2),
    Trimmed = alContext:trimMessages(History, AgentCfg),
    System = alContext:buildSystemPrompt(Question, Opts2),
    %% Never use role=tool without tool_call_id — OpenAI/DeepSeek reject it.
    ContextMsg = #{role => user, content => contextUserContent(Context)},
    %% Chronological: system + context + history, then the current question.
    Messages0 = [#{role => system, content => System}, ContextMsg | Trimmed] ++ [UserMsg],
    MaxSteps0 = maps:get(maxToolSteps, Opts2, maps:get(maxSteps, AgentCfg, ?DefaultMaxToolSteps)),
    MaxSteps = case isRuntimeQuestion(Question) of
        true -> max(MaxSteps0, ?LiveDataMaxToolSteps);
        false -> MaxSteps0
    end,
    %% 投机预取（P2-9）：上下文侦察出的高概率文件异步预热工具缓存，
    %% LLM 首轮 readFile 直接命中。投机性质：未命中无害，TTL 自动清理。
    _ = alAsync:run(speculativePrefetch,
                    fun() -> speculativePrefetch(Context) end),
    toolLoop(Messages0, Opts2, Context, 0, [], MaxSteps).

%%--------------------------------------------------------------------
%% @doc
%% 投机预取目标：锚点片段对应文件（编辑目标）+ 写任务相关测试 +
%% 搜索命中头部文件。合并去重，最多预取 5 个。
%%
%% @param Context 上下文 map（anchorSnippets/writeRecon/codeHits）
%% @return 文件路径列表
%% @end
%%--------------------------------------------------------------------
prefetchTargets(Context) when is_map(Context) ->
    FromAnchors = [F || S <- maps:get(anchorSnippets, Context, []), is_map(S),
                        F <- [maps:get(file, S, undefined)], is_binary(F), F =/= <<>>],
    WriteRecon = maps:get(writeRecon, Context, #{}),
    FromTests = [F || T <- maps:get(relatedTests, WriteRecon, []), is_map(T),
                      F <- [maps:get(testFile, T, undefined)], is_binary(F), F =/= <<>>],
    FromHits = [F || H <- lists:sublist(maps:get(codeHits, Context, []), 2), is_map(H),
                     F <- [maps:get(file, H, undefined)], is_binary(F), F =/= <<>>],
    lists:sublist(lists:usort(FromAnchors ++ FromTests ++ FromHits), 5);
prefetchTargets(_) ->
    [].

%% 异步执行预取：逐文件 readFile 并写入工具缓存。失败静默（投机路径）。
speculativePrefetch(Context) ->
    try
        [begin
             case alToolsExt:readFile(#{path => File}) of
                 {ok, Result} -> alToolCache:store(readFile, #{path => File}, Result);
                 _ -> ok
             end
         end || File <- prefetchTargets(Context)]
    catch
        _:_ -> ok
    end.

%% edit/exec 默认开启自愈（maxHealAttempts=3）；ask 默认关闭（0）。
%% 显式 Opts / agentCfg 优先。
maybeDefaultHealOpts(Opts, Mode, AgentCfg) ->
    case maps:is_key(maxHealAttempts, Opts) of
        true -> Opts;
        false ->
            case maps:is_key(maxHealAttempts, AgentCfg) of
                true ->
                    Opts#{maxHealAttempts => maps:get(maxHealAttempts, AgentCfg)};
                false ->
                    Default = case Mode of
                        edit -> 3;
                        exec -> 3;
                        _ -> 0
                    end,
                    Opts#{maxHealAttempts => Default}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 不带工具的纯 LLM 问答路径：构建上下文与消息后直接调用 LLM，
%% 失败时返回 fallback 答案。
%%
%% @param Question 用户问题
%% @param Opts 选项 map
%% @return `{ok, #{answer, context, llm}}' 或 fallback
%% @end
%%--------------------------------------------------------------------
askPlain(Question, Opts) ->
    OptsR = ensureModelRouting([], Opts#{currentQuestion => Question}),
    Context = buildContext(Question, OptsR),
    History0 = sessionMessages(maps:get(sessionId, Opts, undefined), Opts),
    History = dropTrailingCurrentUser(History0, Question),
    UserMsg = userMessageWithAttachments(Question, Opts),
    System = alContext:buildSystemPrompt(Question, Opts),
    Trimmed = alContext:trimMessages(History, maps:get(agentCfg, OptsR, alConfig:getAgentCfg())),
    Messages = [#{role => system, content => System} | Trimmed] ++ [UserMsg],
    LlmOpts = llmOpts(OptsR),
    case alLlmClient:chat(Messages, LlmOpts) of
        {ok, Reply0} ->
            %% DSML 正文工具调用：纯问答路径也要剥掉标记，避免把 invoke 当最终答案
            Reply = case maps:get(tool_calls, Reply0, []) of
                [] ->
                    {Content1, Calls} = alDsmlTools:recoverFromContent(
                        maps:get(content, Reply0, <<>>)),
                    case Calls of
                        [] -> Reply0;
                        _ ->
                            Msg0 = maps:get(message, Reply0, #{role => assistant}),
                            Reply0#{
                                content => Content1,
                                tool_calls => [],
                                message => Msg0#{content => Content1, tool_calls => []}
                            }
                    end;
                _ ->
                    Reply0
            end,
            {ok, #{
                answer => answerFromReply(Reply),
                context => Context,
                llm => Reply,
                trace => []
            }};
        {error, Reason} ->
            {ok, #{
                answer => fallbackAnswer(Question, Context, Reason),
                context => Context,
                trace => []
            }}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 构建回答所需的上下文，可选地合并长期记忆中的相关条目。
%%
%% @param Question 用户问题
%% @param Opts 选项 map（可含 includeMemory / memoryLimit）
%% @return 上下文 map，可能含 longTermMemory 字段
%% @end
%%--------------------------------------------------------------------
buildContext(Question, Opts) ->
    Context0 = alContextEngine:build(Question, Opts),
    injectUnifiedRecall(Question, Context0, Opts).

injectUnifiedRecall(Question, Context, Opts) when is_map(Context) ->
    AgentCfg = maps:get(agentCfg, Opts, alConfig:getAgentCfg()),
    UnifiedOn = maps:get(experienceUnifiedRecall, AgentCfg, true) =/= false,
    case UnifiedOn andalso alExperience:enabled() of
        true ->
            Limit = maps:get(experienceRecallLimit, Opts,
                       maps:get(experienceRecallLimit, AgentCfg, 5)),
            MemLimit = maps:get(memoryLimit, Opts, 8),
            TopK = max(Limit, MemLimit),
            case alExperience:unifiedRecall(Question, #{
                limit => TopK,
                knowledge => maps:get(knowledge, Context, undefined)
            }) of
                {ok, #{lessons := Lessons, memories := Mems} = U} ->
                    Digest = alExperience:familiarityDigest(#{limit => 5}),
                    Hint0 = maps:get(hint, Context, <<>>),
                    Hint1 = case Lessons =:= [] andalso maps:get(lessonCount, Digest, 0) =:= 0 of
                        true -> Hint0;
                        false ->
                            <<Hint0/binary,
                              " Prefer retrieved_context.experience.lessons; "
                              "stale=true entries may be outdated after code changes—"
                              "verify against current source.">>
                    end,
                    Context#{
                        experience => #{
                            familiarity => Digest,
                            lessons => Lessons,
                            knowledge => maps:get(knowledge, U, []),
                            unified => maps:get(merged, U, [])
                        },
                        longTermMemory => Mems,
                        hint => Hint1
                    };
                _ ->
                    injectExperienceFallback(Question, Context, Opts)
            end;
        false ->
            injectExperienceFallback(Question, Context, Opts)
    end.

injectExperienceFallback(Question, Context, Opts) ->
    Context1 = injectExperience(Question, Context, Opts),
    case maps:get(includeMemory, Opts, true) andalso needsMemoryLookup(Question) of
        true ->
            Limit = maps:get(memoryLimit, Opts, 8),
            Memories = case alMemory:relevantFor(Question, Limit) of
                {ok, Rows} -> Rows;
                _ -> []
            end,
            Context1#{longTermMemory => Memories};
        false ->
            Context1
    end.

%% 注入项目经验：熟悉度摘要 + 与问题相关的教训召回。
injectExperience(Question, Context, Opts) when is_map(Context) ->
    case maps:get(includeExperience, Opts, true) of
        false -> Context;
        _ ->
            try
                Limit = maps:get(experienceRecallLimit, Opts,
                           maps:get(experienceRecallLimit,
                                    maps:get(agentCfg, Opts, #{}),
                                    5)),
                Lessons = case alExperience:recallFor(Question, Limit) of
                    {ok, Rows} -> Rows;
                    _ -> []
                end,
                Digest = alExperience:familiarityDigest(#{limit => 5}),
                Hint0 = maps:get(hint, Context, <<>>),
                Hint1 = case Lessons =:= [] andalso maps:get(lessonCount, Digest, 0) =:= 0 of
                    true -> Hint0;
                    false ->
                        <<Hint0/binary,
                          " Prefer retrieved_context.experience.lessons when present "
                          "(project pitfalls / corrections / verified insights). "
                          "Do not repeat known failures.">>
                end,
                Context#{
                    experience => #{
                        familiarity => Digest,
                        lessons => Lessons
                    },
                    hint => Hint1
                }
            catch
                _:_ -> Context
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 判断是否需要记忆检索：短消息（<=3 字符）或常见问候语跳过，
%% 避免对简单问候做不必要的 DB 查询。
%%
%% @param Question 用户问题
%% @return boolean()
%% @end
%%--------------------------------------------------------------------
needsMemoryLookup(Question) ->
    Bin = toBinary(Question),
    case byte_size(Bin) =< 3 of
        true -> false;
        false ->
            Lower = string:lowercase(Bin),
            not lists:member(Lower, [<<"hi">>, <<"hey">>, <<"hello">>,
                                     <<"ok">>, <<"yes">>, <<"no">>,
                                     <<"你好"/utf8>>, <<"嗯"/utf8>>, <<"好的"/utf8>>])
    end.

%%--------------------------------------------------------------------
%% @doc
%% 工具调用主循环：调用 LLM，若返回 tool_calls 则执行后递归进入下一轮，
%% 直到 LLM 不再返回工具调用、达到最大步数或遇到错误。
%% 当工具返回 pending（需要确认）时挂起循环并保存续接信息。
%%
%% @param Messages 当前消息列表
%% @param Opts 选项 map
%% @param Context 上下文
%% @param Step 当前步数
%% @param Trace 累积的调用轨迹
%% @param MaxSteps 最大步数
%% @return `{ok, Reply}'，Reply 含 answer/context/trace 等字段
%% @end
%%--------------------------------------------------------------------
toolLoop(Messages, Opts, Context, Step, Trace, MaxSteps) when Step >= MaxSteps ->
    %% 步数用尽：用已收集的工具结果收敛出最终答案，勿返回误导性的「LLM 未配置」
    convergeOnMaxSteps(Messages, Opts, Context, Trace);
toolLoop(Messages, Opts, Context, Step, Trace, MaxSteps) ->
    case Step of
        0 -> erase(?ToolFpCacheKey),
             erase(?ToolIntentLogKey);
        _ -> ok
    end,
    Opts1 = ensureModelRouting(Messages, Opts),
    LlmOpts = llmOpts(Opts1),
    BoundedMessages = trimToolMessages(Messages, Opts1),
    %% Per-turn token budget: converge early instead of burning budget on
    %% another tool round once the running prompt exceeds maxTokensBudget.
    Budget = maps:get(maxTokensBudget, Opts1, ?DefaultTokenBudget),
    case alTokenStats:estimateMessages(BoundedMessages) > Budget of
        true ->
            convergeOnBudget(BoundedMessages, LlmOpts, Opts1, Context, Trace);
        false ->
            toolLoopStep(BoundedMessages, LlmOpts, Opts1, Context, Step, Trace, MaxSteps)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 会话级模型路由 pin：配置了模型链（llm.chain）且本轮未 pin 时，
%% 经 alLlmRouter 按问题分级 / 经验路由决策起始链项，pin 到 Opts.modelEntry
%% 让整轮工具循环使用同一模型；已 pin（含 pending 续接恢复）或链未配置时
%% 原样返回。升级换链（qualityEscalate）会显式更新 modelEntry。
%%
%% 用户 llmOverride（Web setLlm）在链启用时仅覆盖云端链项，不跳过本地先试规则；
%% 仅显式 llmPin=true 时完全禁用链路由。
%%
%% @param Messages 当前消息列表
%% @param Opts     选项 map
%% @return 更新后的 Opts
%% @end
%%--------------------------------------------------------------------
ensureModelRouting(_Messages, Opts) ->
    case maps:get(modelEntry, Opts, undefined) of
        Entry when is_map(Entry) ->
            Opts;
        _ ->
            case maps:get(llmPin, Opts, false) of
                true ->
                    Opts;
                _ ->
                    routeByQuestion(Opts)
            end
    end.

routeByQuestion(Opts) ->
    Question = toBinary(maps:get(currentQuestion, Opts, <<>>)),
    case Question of
        <<>> ->
            Opts;
        _ ->
            HasTools = toolDefinitions(Opts) =/= [],
            case alLlmRouter:routeFor(Question, HasTools) of
                {ok, Entry, Info} ->
                    logger:debug("alToolRouter route ~s -> ~s (~p)",
                                 [Question, maps:get(id, Entry, <<>>), Info]),
                    Opts#{modelEntry => Entry,
                          taskGrade => maps:get(grade, Info, medium)};
                disabled ->
                    Opts
            end
    end.

%% LLM tool round: call the model, execute any tool_calls, recurse.
toolLoopStep(BoundedMessages, LlmOpts0, Opts, Context, Step, Trace, MaxSteps) ->
    %% 工具轮默认强制关闭 thinking：DeepSeek V4 默认深思会导致网页长时间停在
    %% 「LLM round 0」且无任何 token。显式 allowThinking=true 才放开。
    LlmOpts = case maps:get(allowThinking, Opts, false) of
        true -> LlmOpts0;
        _ -> LlmOpts0#{thinking => disabled}
    end,
    Model = maps:get(model, LlmOpts, <<"?">>),
    Thinking = maps:get(thinking, LlmOpts, undefined),
    emitProgress(Opts, #{type => started, phase => llm, step => Step,
                         message => iolist_to_binary(io_lib:format(
                             "LLM round ~p · ~s · thinking=~p",
                             [Step, Model, Thinking]))}),
    Tools = toolDefinitions(Opts),
    StreamCaller = maps:get(streamCaller, Opts, undefined),
    Parent = self(),
    emitProgress(Opts, #{type => step, phase => llmConnect, step => Step,
                         message => <<"正在请求模型…"/utf8>>}),
    Ticker = alAsync:run(llmWaitTicker,
                         fun() -> llmWaitTicker(Parent, Opts, Step, 0) end),
    LlmResult0 = try
        case is_pid(StreamCaller) of
            true ->
                streamOrFallbackChat(BoundedMessages, Tools, LlmOpts, StreamCaller);
            false ->
                alLlmClient:chatWithTools(BoundedMessages, Tools, LlmOpts)
        end
    after
        Ticker ! eStop
    end,
    %% DeepSeek V4 may put DSML tool markup in content; recover before branching.
    LlmResult = case LlmResult0 of
        {ok, R} when is_map(R) -> {ok, maybeRecoverDsmlReply(R)};
        Other -> Other
    end,
    case LlmResult of
        {ok, #{tool_calls := ToolCalls} = Reply} when is_list(ToolCalls), ToolCalls =/= [] ->
            AssistantMsg0 = maps:get(message, Reply, #{
                role => assistant,
                content => maps:get(content, Reply, <<>>),
                tool_calls => ToolCalls
            }),
            AssistantMsg1 = AssistantMsg0#{role => assistant, tool_calls => ToolCalls},
            %% DeepSeek thinking：必须把 reasoning_content 带回后续请求 / checkpoint。
            AssistantMessage = case maps:get(reasoning_content, Reply,
                                             maps:get(reasoning_content, AssistantMsg1, undefined)) of
                undefined -> AssistantMsg1;
                RC -> AssistantMsg1#{reasoning_content => RC}
            end,
            %% ReAct: 优先推送真正的 reasoning_content。旧逻辑优先 content，
            %% thinking 模型同时返回两者时，前端实时 reasoning 与结束后的
            %% thought 快照来自两个字段，造成“思考过程前后不一致”。
            case maps:get(reasoning_content, AssistantMessage, <<>>) of
                RThought when is_binary(RThought), RThought =/= <<>> ->
                    emitProgress(Opts, #{type => thought, phase => reasoning,
                                         step => Step, message => RThought});
                _ ->
                    case maps:get(content, AssistantMessage, <<>>) of
                        Thought when is_binary(Thought), Thought =/= <<>> ->
                            emitProgress(Opts, #{type => thought, phase => reasoning,
                                                 step => Step, message => Thought});
                        _ -> ok
                    end
            end,
            ToolResults = executeToolCalls(ToolCalls, Opts),
            case findPendingTool(ToolCalls, ToolResults) of
                {ok, TaskId, PendingCall, PendingResult} ->
                    Continuation = #{
                        messages => BoundedMessages ++ [AssistantMessage | ToolResults],
                        opts => maps:remove(streamCaller, Opts),
                        context => Context,
                        step => Step + 1,
                        trace => [{step, Step}, {tool_calls, ToolCalls}, {results, ToolResults} | Trace],
                        maxSteps => MaxSteps,
                        pendingCall => PendingCall,
                        question => maps:get(currentQuestion, Opts, undefined)
                    },
                    case alPending:attachContinuation(TaskId, Continuation) of
                        ok ->
                            _ = alCheckpoint:save(to_binary(TaskId), Continuation),
                            %% 并行工具批次中可能有多个工具各自登记了 pending，
                            %% 但只有第一个被挂起并附带续接；其余若不处理会永远
                            %% 滞留在 pending 表直到 TTL 过期。这里主动 dismiss 同批
                            %% 其余 pending，避免悬挂 / 误批准。
                            dismissOtherPending(ToolResults, TaskId),
                            emitProgress(Opts, #{type => approvalRequired, taskId => TaskId}),
                            {ok, #{
                                answer => pendingAnswer(TaskId, PendingCall, PendingResult),
                                context => Context,
                                suspended => true,
                                pendingTaskId => TaskId,
                                trace => lists:reverse([{suspended, TaskId} | Trace])
                            }};
                        {error, AttachReason} ->
                            emitProgress(Opts, #{type => failed, reason => AttachReason}),
                            {error, {pendingAttachFailed, AttachReason, lists:reverse(Trace)}}
                    end;
                miss ->
                    TaskId = case maps:get(taskId, Opts, undefined) of
                        undefined -> makeTaskId();
                        T -> T
                    end,
                    Continuation = #{
                        messages => BoundedMessages ++ [AssistantMessage | ToolResults],
                        opts => maps:remove(streamCaller, Opts),
                        context => Context,
                        step => Step + 1,
                        trace => [{step, Step}, {tool_calls, ToolCalls}, {results, ToolResults} | Trace],
                        maxSteps => MaxSteps,
                        question => maps:get(currentQuestion, Opts, undefined)
                    },
                    _ = alCheckpoint:save(to_binary(TaskId), Continuation),
                    NextMessages = BoundedMessages ++ [AssistantMessage | ToolResults],
                    toolLoop(
                        NextMessages,
                        Opts#{taskId => TaskId},
                        Context,
                        Step + 1,
                        [{step, Step}, {tool_calls, ToolCalls}, {results, ToolResults} | Trace],
                        MaxSteps
                    )
            end;
        {ok, Reply} when is_map(Reply) ->
            %% Missing/empty tool_calls — treat as final answer (malformed
            %% parse paths must not case_clause-crash the agent worker).
            Answer0 = answerFromReply(Reply),
            case maybeGroundingRetry(Answer0, Reply, BoundedMessages, Opts,
                                     Context, Step, Trace, MaxSteps) of
                {retry, NewMessages, NewOpts, NewStep, NewTrace} ->
                    toolLoop(NewMessages, NewOpts, Context, NewStep, NewTrace, MaxSteps);
                {done, Answer1} ->
                    case maybeToolNarrationRetry(Answer1, Reply, BoundedMessages, Opts,
                                                 Context, Step, Trace, MaxSteps) of
                        {retry, MsgsN, OptsN, StepN, TraceN} ->
                            toolLoop(MsgsN, OptsN, Context, StepN, TraceN, MaxSteps);
                        {done, Answer1b} ->
                            case maybeRuntimeRetry(Answer1b, Reply, BoundedMessages, Opts,
                                                   Context, Step, Trace, MaxSteps) of
                                {retry, Msgs2, Opts2, Step2, Trace2} ->
                                    toolLoop(Msgs2, Opts2, Context, Step2, Trace2, MaxSteps);
                                {done, Answer2} ->
                                    case maybeHealRetry(Answer2, Reply, BoundedMessages, Opts,
                                                        Context, Step, Trace, MaxSteps) of
                                        {retry, Msgs3, Opts3, Step3, Trace3} ->
                                            toolLoop(Msgs3, Opts3, Context, Step3, Trace3, MaxSteps);
                                        {done, Answer3} ->
                                            case maybeBatchPlanRetry(Answer3, Reply, BoundedMessages, Opts,
                                                                     Context, Step, Trace, MaxSteps) of
                                                {retry, Msgs4, Opts4, Step4, Trace4} ->
                                                    toolLoop(Msgs4, Opts4, Context, Step4, Trace4, MaxSteps);
                                                {done, Answer} ->
                                                    case maybeQualityEscalate(Answer, BoundedMessages, Opts,
                                                                              Context, Trace) of
                                                        {retry, EscMsgs, EscOpts} ->
                                                            toolLoop(EscMsgs, EscOpts, Context, 0,
                                                                     [{qualityEscalate,
                                                                       maps:get(id, maps:get(modelEntry, EscOpts, #{}), <<>>)}
                                                                      | Trace], MaxSteps);
                                                        done ->
                                                            emitProgress(Opts, #{type => completed, step => Step}),
                                                            maybeDeleteCheckpoint(Opts),
                                                            {ok, #{
                                                                answer => Answer,
                                                                context => Context,
                                                                llm => Reply,
                                                                trace => lists:reverse(Trace)
                                                            }}
                                                    end
                                            end
                                    end
                            end
                    end
            end;
        {error, Reason} ->
            emitProgress(Opts, #{type => failed, reason => Reason}),
            {error, {llmFailed, Reason, lists:reverse(Trace)}}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 流式失败降级：streamChatWithTools 重试耗尽仍失败时（含链 pin 模型
%% 不可用），回退非流式 chatWithTools——其内部会沿模型链升级到下一个
%% 模型；成功后把答案正文以单帧推给 StreamCaller，避免前端拿到空答案。
%%
%% @param Messages    消息列表
%% @param Tools       工具规格列表
%% @param LlmOpts     LLM 选项（含 modelEntry pin）
%% @param StreamCaller 流式事件接收进程
%% @return LLM 调用结果
%% @end
%%--------------------------------------------------------------------
streamOrFallbackChat(Messages, Tools, LlmOpts, StreamCaller) ->
    case alLlmClient:streamChatWithTools(Messages, Tools, LlmOpts, StreamCaller) of
        {error, StreamReason} = StreamError ->
            %% eWCli 规定 streamStarted 后不应再重试/降级：正文已部分推送，
            %% 非流式回退会把同一段生成重复追加到前端。仅在可安全回退的错误上降级。
            case alLlmClient:streamFallbackSafe(StreamReason) of
                true ->
                    logger:warning("alToolRouter stream failed, fallback to chatWithTools (~p)",
                                   [alAskDiag:sanitize(StreamReason)]),
                    case alLlmClient:chatWithTools(Messages, Tools, LlmOpts) of
                        {ok, Reply} = Ok ->
                            forwardReplyContent(StreamCaller, Reply),
                            Ok;
                        _ ->
                            StreamError
                    end;
                false ->
                    logger:warning("alToolRouter stream failed (~p), skip non-stream fallback",
                                   [alAskDiag:sanitize(StreamReason)]),
                    StreamError
            end;
        Ok ->
            Ok
    end.

%% 把非流式降级得到的答案正文以单帧推给流式调用方（前端 token 帧追加显示）。
forwardReplyContent(StreamCaller, Reply) when is_pid(StreamCaller) ->
    Content = case maps:get(content, Reply, undefined) of
        Bin when is_binary(Bin) -> Bin;
        _ -> <<>>
    end,
    case Content of
        <<>> -> ok;
        _ -> StreamCaller ! {eStreamChunk, Content}
    end;
forwardReplyContent(_, _) ->
    ok.

%%--------------------------------------------------------------------
%% @doc
%% 质量升级门（模型链启用时）：本地模型的最终答案「不能处理」（空答案 /
%% 短答案含拒答模式）直接升级；否则按问题复杂度决定是否交 critic 角色
%% 模型打分 —— simple 直接放行（本地处理基础回答），medium / complex
%% 分数低于阈值（llm.routing.criticThreshold，默认 0.5）时升级链上下一个
%% 模型重跑整轮工具循环。这样「答不好」而不只是「拒答」也会触发云模型。
%% 升级只做一次（qualityEscalated 标记防循环）。
%%
%% @param Answer   最终答案
%% @param Messages 当前（已收敛前的）消息列表
%% @param Opts     选项 map
%% @param Context  上下文
%% @param Trace    调用轨迹
%% @return `{retry, Messages, Opts}' | `done'
%% @end
%%--------------------------------------------------------------------
maybeQualityEscalate(Answer, Messages, Opts, Context, Trace) ->
    case maps:get(modelEntry, Opts, undefined) of
        Entry when is_map(Entry) ->
            case maps:get(local, Entry, false) =:= true of
                false ->
                    done;
                true ->
                    escalateIfSuspicious(Entry, Answer, Messages, Opts, Context, Trace)
            end;
        _ ->
            done
    end.

escalateIfSuspicious(Entry, Answer, Messages, Opts, Context, _Trace) ->
    case maps:get(qualityEscalated, Opts, false) of
        true ->
            done;
        false ->
            case alLlmRouter:nextEntry(maps:get(id, Entry, undefined)) of
                {ok, Next} ->
                    case qualityVerdict(Answer, Opts, Context) of
                        {upgrade, Why, Score} ->
                            Question = toBinary(maps:get(currentQuestion, Opts, <<>>)),
                            alLlmRouter:noteLocalFailure(
                                Question, Entry, {quality, Why}),
                            emitProgress(Opts, #{
                                type => step, phase => escalate,
                                message => iolist_to_binary([
                                    <<"本地模型答案质量不足（"/utf8>>,
                                    qualityReasonText(Why),
                                    <<"），升级更强模型重答…"/utf8>>])}),
                            logger:info("alToolRouter quality escalate ~s -> ~s reason=~p score=~p",
                                        [maps:get(id, Entry, <<>>),
                                         maps:get(id, Next, <<>>), Why, Score]),
                            {retry, handoffMessages(Messages, Question, Why, Score),
                             Opts#{modelEntry => Next, qualityEscalated => true}};
                        pass ->
                            done
                    end;
                none ->
                    done
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 判定本地弱模型答案是否需要升级到更强模型（即「主模型答不好就上云」的
%% 触发时机，而非「仅空答案/拒答才上云」）：
%% <ul>
%%   <li>空答案 / 明显拒答 → 直接升级，无需 critic 白跑一趟；</li>
%%   <li>其余：simple 问题直接信任本地基础回答（省一次 critic 调用），
%%       medium / complex 问题交 critic 角色模型（通常为更强的云端）打分，
%%       分数低于 llm.routing.criticThreshold 即视为「回答不好」升级。</li>
%% </ul>
%% @end
%%--------------------------------------------------------------------
qualityVerdict(Answer, Opts, Context) ->
    case alLlmRouter:suspiciousReason(Answer) of
        {reason, emptyAnswer} -> {upgrade, emptyAnswer, 0.0};
        {reason, refusal} -> {upgrade, refusal, 0.0};
        ok ->
            case qualityCriticWanted(Opts) of
                true ->
                    case criticGate(Answer, Opts, Context) of
                        {reject, Score} -> {upgrade, quality, Score};
                        _ -> pass
                    end;
                false ->
                    pass
            end
    end.

%% 简单问题（短、无工具、无代码关键词）直接信任本地基础回答，
%% 只做空答案/拒答升级；中/复杂问题才用 critic 复审「回答好不好」。
qualityCriticWanted(Opts) ->
    maps:get(taskGrade, Opts, medium) =/= simple.

%%--------------------------------------------------------------------
%% @doc
%% 升级前把「本地模型为何失败」整理成一段交接提示，追加到消息末尾，
%% 让云端模型知道这是一次升级重答：结合上方检索到的项目经验教训 /
%% 长期记忆 / 代码命中，重新完整作答，不要重复已知错误或轻易拒答。
%%
%% @param Messages 当前消息列表
%% @param Question 原问题
%% @param Why      失败原因（emptyAnswer | refusal）
%% @param Score    critic 打分
%% @return 追加了 handoff 提示的消息列表
%% @end
%%--------------------------------------------------------------------
handoffMessages(Messages, Question, Why, Score) ->
    Note = iolist_to_binary([
        <<"[升级提示] 本地弱模型未能充分回答，已切换更强模型重答。"/utf8>>,
        <<"\n原问题："/utf8>>, toBinary(Question),
        <<"\n失败原因："/utf8>>, qualityReasonText(Why),
        <<"（质量分 "/utf8>>, float_to_binary(Score, [{decimals, 2}]), <<"）"/utf8>>,
        <<"\n请结合上方检索到的项目经验教训、长期记忆与代码命中，"/utf8>>,
        <<"重新完整、准确地作答；不要重复已知错误，也不要轻易说“无法回答”。"/utf8>>
    ]),
    Messages ++ [#{role => user, content => Note}].

qualityReasonText(emptyAnswer) -> <<"空答案"/utf8>>;
qualityReasonText(refusal) -> <<"疑似拒答"/utf8>>;
qualityReasonText(quality) -> <<"回答不好"/utf8>>;
qualityReasonText(Why) -> toBinary(Why).

%%--------------------------------------------------------------------
%% @doc
%% critic 抽查：用 critic 角色模型（llmRole => critic，解除本轮 modelEntry
%% pin）审查可疑答案，返回 {reject, Score} | {pass, Score} | pass（不可判）。
%% critic 失败时 alCritic 回退本地风险模板（高危答案低分也会触发升级，
%% 这是合理的兜底）。critic Opts 需去掉 streamCaller 避免复审文本混入
%% 用户流式输出。
%%
%% @param Answer  最终答案
%% @param Opts    选项 map
%% @param Context 上下文
%% @return `{reject, Score}' | `{pass, Score}' | `pass'
%% @end
%%--------------------------------------------------------------------
criticGate(Answer, Opts, Context) ->
    Question = toBinary(maps:get(currentQuestion, Opts, <<>>)),
    CriticOpts0 = maps:remove(modelEntry,
                     maps:remove(streamCaller,
                                 maps:remove(progressId, Opts))),
    CriticOpts = CriticOpts0#{llmRole => critic, maxCriticRounds => 1},
    try alCritic:review(Question, Answer, Context, CriticOpts) of
        {ok, Critique} ->
            Score = maps:get(score, Critique, undefined),
            case is_number(Score) of
                true ->
                    case Score < alLlmRouter:criticThreshold() of
                        true -> {reject, Score};
                        false -> {pass, Score}
                    end;
                false ->
                    pass
            end;
        _ ->
            pass
    catch
        _:_ ->
            pass
    end.

%% 从 content 中的 DeepSeek DSML 标记恢复 tool_calls（结构化字段为空时）。
maybeRecoverDsmlReply(Reply) when is_map(Reply) ->
    Existing = maps:get(tool_calls, Reply, []),
    case is_list(Existing) andalso Existing =/= [] of
        true ->
            Reply;
        false ->
            Content0 = maps:get(content, Reply,
                                maps:get(content, maps:get(message, Reply, #{}), <<>>)),
            case alDsmlTools:recoverFromContent(Content0) of
                {_C, []} ->
                    Reply;
                {Content1, ToolCalls} ->
                    Msg0 = maps:get(message, Reply, #{role => assistant}),
                    Msg1 = Msg0#{content => Content1, tool_calls => ToolCalls, role => assistant},
                    Reply#{
                        content => Content1,
                        tool_calls => ToolCalls,
                        message => Msg1,
                        dsmlRecovered => true
                    }
            end
    end;
maybeRecoverDsmlReply(Reply) ->
    Reply.

%% 终答接地：无证据的 MFA/路径声明 → 强制再跑一轮工具；否则仅附加 warning。
maybeGroundingRetry(Answer, Reply, Messages, Opts, Context, Step, Trace, MaxSteps) ->
    Enabled = maps:get(groundingCheck, Opts, true),
    Already = maps:get(groundingRetried, Opts, false),
    Check = case Enabled of
        true ->
            try alGrounding:check(Answer, Context, Trace)
            catch _:_ -> ok
            end;
        false ->
            ok
    end,
    case Check of
        {ungrounded, Claims} when Step + 1 < MaxSteps, Already =:= false ->
            case retryBudgetAvailable(Opts) of
                true ->
                    Fixup = alGrounding:fixupMessage(Claims),
                    AssistantMsg = case maps:get(message, Reply, undefined) of
                        M when is_map(M) -> M#{role => assistant};
                        _ -> #{role => assistant, content => Answer}
                    end,
                    emitProgress(Opts, #{type => step, phase => grounding,
                                         message => <<"引用未接地；请求 gotoDef/readFile"/utf8>>,
                                         claims => Claims}),
                    {retry,
                     Messages ++ [AssistantMsg, Fixup],
                     incrementRetryUsed(Opts#{groundingRetried => true}),
                     Step + 1,
                     [{step, Step}, {groundingRetry, Claims} | Trace]};
                false ->
                    Warn = alGrounding:warningText(Claims),
                    {done, alGrounding:appendWarning(Answer, Warn)}
            end;
        {ungrounded, Claims} ->
            Warn = alGrounding:warningText(Claims),
            {done, alGrounding:appendWarning(Answer, Warn)};
        _ ->
            {done, Answer}
    end.

%%--------------------------------------------------------------------
%% @doc
%% retry 链预算独立隔离：从 MaxSteps 分出 20% 专门给 retry 链
%% (grounding/toolNarration/runtime/heal/batchPlan)，避免 retry 叠加
%% 最多吃掉 7+ 步正常工具调用配额。retryBudget 默认 MaxSteps div 5。
%%
%% @param Opts 选项 map
%% @return boolean — 是否还有 retry 预算
%% @end
%%--------------------------------------------------------------------
retryBudgetAvailable(Opts) ->
    Used = maps:get(retryUsed, Opts, 0),
    Budget = maps:get(retryBudget, Opts, retryBudgetDefault(Opts)),
    Used < Budget.

retryBudgetDefault(Opts) ->
    MaxSteps = maps:get(maxToolSteps, Opts, ?DefaultMaxToolSteps),
    max(1, MaxSteps div 5).

incrementRetryUsed(Opts) ->
    Opts#{retryUsed => maps:get(retryUsed, Opts, 0) + 1}.

%% 模型在正文里叙述「还要再调工具」却未发出 tool_calls：强制再跑。
%% 即使前面已跑过工具，也要拦「半截过程叙述当终答」——最多重试 N 次。
%% 注意：完整终答里提到工具名（如「已用 searchCode」）不应触发。
maybeToolNarrationRetry(Answer, Reply, Messages, Opts, _Context, Step, Trace, MaxSteps) ->
    Retries = maps:get(toolNarrationRetries, Opts, 0),
    MaxNarration = 3,
    Need = looksLikeToolNarration(Answer),
    case Need andalso Retries < MaxNarration andalso (Step + 1 < MaxSteps) of
        false ->
            {done, Answer};
        true ->
            case retryBudgetAvailable(Opts) of
                false ->
                    {done, Answer};
                true ->
                    Fixup = #{
                        role => user,
                        content =>
                            <<"你刚才把「下一步打算用某工具」写进了终答正文，但没有发出结构化 tool_calls。\n"
                              "这不是完整答案。请立刻通过 tools API 真正调用所需工具"
                              "（如 searchText / getSymbolSource / readFile / searchCode），"
                              "拿到证据后再写完整终答。"
                              "禁止只叙述计划。"/utf8>>
                    },
                    AssistantMsg = case maps:get(message, Reply, undefined) of
                        M when is_map(M) -> M#{role => assistant};
                        _ -> #{role => assistant, content => Answer}
                    end,
                    emitProgress(Opts, #{type => step, phase => toolNarration,
                                         message => <<"正文仍是工具计划而非终答；强制再调工具"/utf8>>,
                                         narrationRetry => Retries + 1}),
                    {retry,
                     Messages ++ [AssistantMsg, Fixup],
                     incrementRetryUsed(Opts#{toolNarrationRetries => Retries + 1}),
                     Step + 1,
                     [{step, Step}, {toolNarrationRetry, Retries + 1} | Trace]}
            end
    end.

%% 兼容旧导出名：意图性叙述（将调用工具）或半截计划。
looksLikeToolNarration(Answer) ->
    looksLikeIncompleteToolPlan(Answer) orelse looksLikePendingToolIntent(Answer).

%% 「我还要去调工具 / 先用 searchText」类意图，且未见交付性结论。
looksLikePendingToolIntent(Answer) ->
    Bin = to_binary(Answer),
    Lower = string:lowercase(Bin),
    IntentKeys = [
        <<"选择工具"/utf8>>, <<"我来搜索"/utf8>>, <<"让我先"/utf8>>, <<"让我搜索"/utf8>>,
        <<"先搜索"/utf8>>, <<"执行："/utf8>>, <<"执行:"/utf8>>,
        <<"接下来调用"/utf8>>, <<"接下来用"/utf8>>, <<"继续调用"/utf8>>,
        <<"在给出最终答案前"/utf8>>, <<"最终答案前"/utf8>>,
        <<"先用 searchtext"/utf8>>, <<"先用searchtext"/utf8>>,
        <<"先用 getsymbolsource"/utf8>>, <<"先用 readfile"/utf8>>,
        <<"i'll search">>, <<"let me search">>, <<"choosing tool">>, <<"i will search">>,
        <<"before giving">>, <<"before the final">>, <<"will use search">>,
        <<"i will use">>, <<"let me use">>, <<"need to call">>, <<"next i will">>
    ],
    HasIntent = lists:any(
        fun(K) -> binary:match(Lower, string:lowercase(K)) =/= nomatch end,
        IntentKeys),
    HasIntent andalso not looksLikeDeliveredAnswer(Bin).

%% 终答像「半截调查笔记」：缺证据 / 还要再读函数体，且未交付测试结论。
looksLikeIncompleteToolPlan(Answer) ->
    Bin = to_binary(Answer),
    HasPlan = lists:any(
        fun(K) -> binary:match(Bin, K) =/= nomatch end,
        [
            <<"在给出最终答案前"/utf8>>, <<"最终答案前"/utf8>>,
            <<"先用 searchText"/utf8>>, <<"先用searchText"/utf8>>,
            <<"函数体尚未"/utf8>>, <<"尚未抓到"/utf8>>,
            <<"再抓取"/utf8>>, <<"先抓取"/utf8>>
        ]),
    HasPlan andalso not looksLikeDeliveredAnswer(Bin).

looksLikeDeliveredAnswer(Bin) when is_binary(Bin) ->
    lists:any(
        fun(K) -> binary:match(Bin, K) =/= nomatch end,
        [
            <<"黑盒测试"/utf8>>, <<"测试步骤"/utf8>>, <<"影响范围"/utf8>>,
            <<"影响功能"/utf8>>, <<"回归点"/utf8>>, <<"验证步骤"/utf8>>,
            <<"综上所述"/utf8>>, <<"结论："/utf8>>, <<"结论:"/utf8>>,
            <<"建议如下"/utf8>>, <<"完整答案"/utf8>>
        ]).

%% 运行时问题却未拿到实况工具结果：先强制再跑一轮；仍失败则自动 getEts/getRuntime。
%% 注意：不得把「审核提交修改」等 VCS/代码评审问句误判为运行时问题。
maybeRuntimeRetry(Answer, Reply, Messages, Opts, Context, Step, Trace, MaxSteps) ->
    Question = maps:get(currentQuestion, Opts, maps:get(question, Context, <<>>)),
    Already = maps:get(runtimeRetried, Opts, false),
    Need = isRuntimeQuestion(Question)
        andalso not isVcsOrCodeReviewQuestion(Question)
        andalso not traceHasLiveRuntime(Trace),
    case Need andalso Already =:= false andalso (Step + 1 < MaxSteps) of
        true ->
            case retryBudgetAvailable(Opts) of
                true ->
                    Fixup = #{
                        role => user,
                        content =>
                            <<"你仍需要本机 BEAM 节点的实况数据（不是沙箱）。\n"
                              "优先用专用工具：\n"
                              "- ETS 内存/Top → getEts\n"
                              "- 进程内存/邮箱 → getProcesses\n"
                              "- 完整快照 → getRuntime\n"
                              "- 其它：先 searchCode/moduleExports；单次 MFA 用 runMfa，多步拼装用 evalErl\n"
                              "请立刻发出结构化 tool_calls。禁止只叙述、禁止拒绝。"/utf8>>
                    },
                    AssistantMsg = case maps:get(message, Reply, undefined) of
                        M when is_map(M) -> M#{role => assistant};
                        _ -> #{role => assistant, content => Answer}
                    end,
                    emitProgress(Opts, #{type => step, phase => runtime,
                                         message => <<"运行时问题但无实况工具；强制再跑一轮"/utf8>>}),
                    {retry,
                     Messages ++ [AssistantMsg, Fixup],
                     incrementRetryUsed(Opts#{runtimeRetried => true}),
                     Step + 1,
                     [{step, Step}, runtimeRetry | Trace]};
                false ->
                    case Need of
                        true ->
                            case autoRuntimeProbeFallback(Question, Opts) of
                                {ok, FallbackAnswer} -> {done, FallbackAnswer};
                                skip -> {done, Answer}
                            end;
                        false ->
                            {done, Answer}
                    end
            end;
        false ->
            case Need of
                true ->
                    case autoRuntimeProbeFallback(Question, Opts) of
                        {ok, FallbackAnswer} -> {done, FallbackAnswer};
                        skip -> {done, Answer}
                    end;
                false ->
                    {done, Answer}
            end
    end.

%% 催促失败后的保底：按问句直接跑观测工具，保证网页有结果。
autoRuntimeProbeFallback(Question, Opts) ->
    {Tool, Args} = case parseDirectRuntimeProbe(Question) of
        {ok, T, A} -> {T, A};
        error ->
            Q = string:lowercase(unicode:characters_to_list(to_binary(Question))),
            Has = fun(K) -> string:find(Q, K) =/= nomatch end,
            case Has("ets") of
                true -> {getEts, #{limit => 10}};
                false ->
                    case Has("进程") orelse Has("process") of
                        true -> {getProcesses, #{limit => 10, sortBy => memory}};
                        false -> {getRuntime, #{}}
                    end
            end
    end,
    emitProgress(Opts, #{type => step, phase => runtime,
                         message => iolist_to_binary(io_lib:format(
                             "runtime fallback auto ~s", [Tool]))}),
    case dispatchTool(Tool, Args, Opts) of
        {ok, Result} ->
            emitProgress(Opts, #{type => toolFinished, tool => Tool,
                                 ok => true, result => Result}),
            {ok, formatDirectProbeAnswer(Tool, Result)};
        {error, _} ->
            skip
    end.

isRuntimeQuestion(Q0) ->
    %% 源码逻辑 / VCS 评审不是「查线上实况」——误判会在已写好终答后强制
    %% getEts/getRuntime，把中间正确结论冲成「没查实况」。
    case isVcsOrCodeReviewQuestion(Q0) orelse isCodeLogicQuestion(Q0) of
        true ->
            false;
        false ->
            Q = string:lowercase(unicode:characters_to_list(to_binary(Q0))),
            %% 运行时分类必须同时具备「运行时实体 + 观测意图」。过去这里用
            %% HasEntity orelse HasOp，导致普通的 process/state 解释题、甚至只含
            %% “执行”二字的问答也被强制补一次 getRuntime。
            %% 显式 MFA 执行和明确快照问句仍由下面两个 parser 独立直达。
            GenericEntity = [
                "ets", "进程", "process", "processes", "mailbox", "pid", "supervisor",
                "内存", "memory", "节点", "node", "scheduler", "heap",
                "runqueue", "run_queue", "消息队列", "message_queue"
            ],
            ObserveOp = [
                "当前", "现在", "查看", "查一下", "状态", "占用", "最高",
                "最大", "列表", "多少", "泄漏", "卡住", "运行中", "快照",
                "current", "show", "list", "status", "state", "usage", "top",
                "running", "snapshot", "inspect", "dump"
            ],
            ProjectEntity = safeProjectKeywords(fun alProjectDigest:liveDataKeywords/0),
            ProjectOp = safeProjectKeywords(fun alProjectDigest:liveDataOpKeywords/0),
            HasGenericEntity = lists:any(fun(K) -> matchHintKeyword(Q, K) end,
                                         GenericEntity),
            HasProjectEntity = lists:any(fun(K) -> matchHintKeyword(Q, K) end,
                                         ProjectEntity),
            HasObserveOp = lists:any(fun(K) -> matchHintKeyword(Q, K) end,
                                     ObserveOp),
            HasProjectOp = lists:any(fun(K) -> matchHintKeyword(Q, K) end,
                                     ProjectOp),
            (HasGenericEntity andalso HasObserveOp)
                orelse (HasProjectEntity andalso (HasObserveOp orelse HasProjectOp))
                orelse parseDirectExecCall(Q0) =/= error
                orelse parseDirectRuntimeProbe(Q0) =/= error
    end.

safeProjectKeywords(Fun) ->
    try Fun() of
        L when is_list(L) -> L;
        _ -> []
    catch _:_ ->
        []
    end.

%% ASCII 关键词整词匹配，避免标识符子串误伤（如 foo_bar 中的 foo）。
matchHintKeyword(Q, Key) when is_list(Q), is_list(Key) ->
    case usableHintKeyword(Key) of
        false -> false;
        true ->
            case isAsciiKeyword(Key) of
                true -> hasWholeWord(Q, Key);
                false -> string:find(Q, Key) =/= nomatch
            end
    end;
matchHintKeyword(Q, Key) ->
    matchHintKeyword(unicode:characters_to_list(to_binary(Q)),
                     unicode:characters_to_list(to_binary(Key))).

%% 跳过宏名 / MFA 碎片等噪声关键词（agent.json 自动种子可能混入）。
usableHintKeyword([]) -> false;
usableHintKeyword([$? | _]) -> false;
usableHintKeyword(Key) when is_list(Key) ->
    length(Key) >= 2 andalso not lists:member($:, Key);
usableHintKeyword(_) -> false.

isAsciiKeyword(Key) when is_list(Key) ->
    lists:all(fun(C) -> is_integer(C) andalso C >= 0 andalso C =< 127 end, Key);
isAsciiKeyword(_) ->
    false.

%% 问源码怎么走 / 读 .erl 实现：走 gotoDef/readFile，不要逼实况探针。
isCodeLogicQuestion(Q0) ->
    Q = string:lowercase(unicode:characters_to_list(to_binary(Q0))),
    Keys = [".erl", "源码", "代码在", "代码里", "逻辑处理", "走的逻辑",
            "处理逻辑", "这段逻辑", "调用链", "函数实现", "实现逻辑",
            "怎么实现", "如何实现", "看一下代码", "读一下代码",
            "流程图", "时序图", "gotodef", "readfile", "getsymbolsource"],
    lists:any(fun(K) -> string:find(Q, K) =/= nomatch end, Keys).

%% 英文整词匹配（\b）；用于通用/项目 ASCII 关键词。
%% Word 必须转义，否则 agent.json 里的 `?table` / `foo.bar` 等会让 re:run badarg，
%% 整次 ask 在 isRuntimeQuestion 阶段就崩掉。
hasWholeWord(Q, Word) when is_list(Q), is_list(Word) ->
    case Word of
        [] -> false;
        _ ->
            Pat = "\\b" ++ escapeReLiteral(Word) ++ "\\b",
            try re:run(Q, Pat, [{capture, none}, unicode, caseless]) of
                match -> true;
                nomatch -> false
            catch
                error:badarg -> false;
                _:_ -> false
            end
    end;
hasWholeWord(Q, Word) ->
    hasWholeWord(unicode:characters_to_list(to_binary(Q)),
                 unicode:characters_to_list(to_binary(Word))).

%% 把字符串当作字面量塞进正则时转义元字符。
escapeReLiteral(S) when is_list(S) ->
    lists:flatmap(fun
        (C) when C =:= $\\; C =:= $^; C =:= $$; C =:= $.; C =:= $|;
                 C =:= $(; C =:= $); C =:= $[; C =:= $]; C =:= ${; C =:= $};
                 C =:= $*; C =:= $+; C =:= $?; C =:= $/ ->
            [$\\, C];
        (C) ->
            [C]
    end, S);
escapeReLiteral(S) ->
    escapeReLiteral(unicode:characters_to_list(to_binary(S))).

%% 提交审核 / VCS 评审 / 代码 diff 类问题：走 lastCommit/commitDiff，不是运行时探针。
isVcsOrCodeReviewQuestion(Q0) ->
    Q = string:lowercase(unicode:characters_to_list(to_binary(Q0))),
    Keys = ["提交", "commit", "svn", "git log", "git diff", "changelog",
            "审核", "评审", "review", "diff", "最后一条提交", "最近提交",
            "改动影响", "变更影响", "代码评审", "reviewchangeimpact"],
    lists:any(fun(K) -> string:find(Q, K) =/= nomatch end, Keys).

traceHasLiveRuntime(Trace) when is_list(Trace) ->
    traceHasRunMfa(Trace) orelse traceHasRuntimeProbeTool(Trace);
traceHasLiveRuntime(_) ->
    false.

traceHasRuntimeProbeTool(Trace) when is_list(Trace) ->
    lists:any(fun
        ({tool_calls, Calls}) when is_list(Calls) ->
            lists:any(fun isRuntimeProbeCall/1, Calls);
        ({results, Results}) when is_list(Results) ->
            lists:any(fun isRuntimeProbeResult/1, Results);
        ({directProbe, _}) -> true;
        (_) -> false
    end, Trace);
traceHasRuntimeProbeTool(_) ->
    false.

isRuntimeProbeCall(Call) ->
    Name = toolCallName(Call),
    lists:member(Name, [<<"getets">>, <<"getruntime">>, <<"getprocesses">>,
                        <<"etslookup">>, <<"processinfo">>, <<"supervisortree">>]).

isRuntimeProbeResult(#{content := C}) when is_map(C) ->
    Tool = maps:get(tool, C, maps:get(<<"tool">>, C, undefined)),
    lists:member(Tool, [getEts, getRuntime, getProcesses, etsLookup,
                        processInfo, supervisorTree,
                        <<"getEts">>, <<"getRuntime">>, <<"getProcesses">>]);
isRuntimeProbeResult(_) -> false.

toolCallName(#{<<"function">> := #{<<"name">> := Name}}) ->
    normalizeToolHint(Name);
toolCallName(#{function := #{name := Name}}) ->
    normalizeToolHint(Name);
toolCallName(_) ->
    <<>>.

traceHasRunMfa(Trace) when is_list(Trace) ->
    lists:any(fun
        ({tool_calls, Calls}) when is_list(Calls) ->
            lists:any(fun isRunMfaCall/1, Calls);
        ({results, Results}) when is_list(Results) ->
            lists:any(fun isRunMfaResult/1, Results);
        (T) when is_tuple(T) ->
            lists:any(fun isRunMfaCall/1, tuple_to_list(T));
        (_) ->
            false
    end, Trace);
traceHasRunMfa(_) ->
    false.

isRunMfaCall(#{<<"function">> := #{<<"name">> := Name}}) ->
    normalizeToolHint(Name) =:= <<"runmfa">>;
isRunMfaCall(#{function := #{name := Name}}) ->
    normalizeToolHint(Name) =:= <<"runmfa">>;
isRunMfaCall(_) ->
    false.

isRunMfaResult(#{content := #{tool := runMfa}}) -> true;
isRunMfaResult(#{content := C}) when is_map(C) ->
    maps:get(tool, C, undefined) =:= runMfa
        orelse maps:get(<<"tool">>, C, undefined) =:= <<"runMfa">>;
isRunMfaResult(_) -> false.

%%--------------------------------------------------------------------
%% 自动调试闭环：最近一轮出现可修复失败（编译/测试/patch）且 LLM 已收束
%% 为终答时，注入错误摘要并强制再跑一轮（最多 maxHealAttempts 次）。
%% edit/exec 默认 3 次；ask 默认 0（关闭）。
%%--------------------------------------------------------------------
maybeHealRetry(Answer, Reply, Messages, Opts, _Context, Step, Trace, MaxSteps) ->
    MaxHeal = positiveHeal(maps:get(maxHealAttempts, Opts, 0)),
    Attempts = case maps:get(healAttempts, Opts, 0) of
        N when is_integer(N), N >= 0 -> N;
        _ -> 0
    end,
    Failures = healableFailures(Trace),
    case MaxHeal > 0 andalso Failures =/= []
         andalso Attempts < MaxHeal andalso (Step + 1 < MaxSteps) of
        false ->
            {done, maybeAppendHealReport(Answer, Failures, Attempts, MaxHeal)};
        true ->
            case retryBudgetAvailable(Opts) of
                false ->
                    {done, maybeAppendHealReport(Answer, Failures, Attempts, MaxHeal)};
                true ->
                    Kind = classifyHealFailures(Failures),
                    Detail = unicode:characters_to_binary(lists:join(<<"\n">>, Failures)),
                    LocHint = healLocationHint(Failures),
                    Workflow = healForcedWorkflow(Kind),
                    Fixup = #{
                        role => user,
                        content => iolist_to_binary([
                            <<"自动修复（"/utf8>>, atom_to_binary(Kind, utf8), <<"）：工具失败了。"
                              "先不要给最终答案。\n"
                              "失败信息：\n"/utf8>>,
                            Detail, <<"\n">>, LocHint, <<"\n">>, Workflow
                        ])
                    },
                    AssistantMsg = case maps:get(message, Reply, undefined) of
                        M when is_map(M) -> M#{role => assistant};
                        _ -> #{role => assistant, content => Answer}
                    end,
                    emitProgress(Opts, #{type => step, phase => heal,
                                         healAttempt => Attempts + 1,
                                         maxHealAttempts => MaxHeal,
                                         healKind => Kind,
                                         failures => Failures,
                                         message => iolist_to_binary([
                                             <<"自愈循环：强制工作流（"/utf8>>,
                                             atom_to_binary(Kind, utf8), <<"）"/utf8>>])}),
                    {retry,
                     Messages ++ [AssistantMsg, Fixup],
                     incrementRetryUsed(Opts#{healAttempts => Attempts + 1, lastHealKind => Kind}),
                     Step + 1,
                     [{step, Step}, {healRetry, Attempts + 1}, {healKind, Kind},
                      {healFailures, Failures} | Trace]}
            end
    end.

%% batchRefactor plan 成功后若直接终答（未 apply），强制再跑一轮补丁应用。
%% 仅 edit/exec；每会话最多 1 次。
maybeBatchPlanRetry(Answer, Reply, Messages, Opts, _Context, Step, Trace, MaxSteps) ->
    Mode = maps:get(mode, Opts, ask),
    Already = maps:get(batchPlanRetried, Opts, false),
    case (Mode =:= edit orelse Mode =:= exec)
         andalso Already =:= false
         andalso (Step + 1 < MaxSteps)
         andalso retryBudgetAvailable(Opts) of
        false ->
            {done, Answer};
        true ->
            case latestBatchPlan(Trace) of
                {ok, Plan} ->
                    Files = maps:get(files, Plan, maps:get(<<"files">>, Plan, [])),
                    FileLines = [[<<"- `">>, to_binary(F), <<"`\n">>]
                                 || F <- lists:sublist(ensure_list(Files), 40)],
                    Fixup = #{
                        role => user,
                        content => unicode:characters_to_binary([
                            <<"批量重构：你已产出 plan 但尚未 apply 补丁。先不要终答。\n"/utf8>>,
                            <<"强制流程：\n"/utf8>>,
                            <<"1) 对下列每个文件 readFile（先扫将要改的部分）\n"/utf8>>,
                            <<"2) 为所有列出文件生成 applyPatch 兼容的 hunks"
                              "（优先 hunks；每个文件都要覆盖）\n"/utf8>>,
                            <<"3) 调用 batchRefactor，action=apply，patches=[...]\n"/utf8>>,
                            <<"4) apply 成功后再给最终报告\n\n"/utf8>>,
                            <<"必须覆盖的文件：\n"/utf8>>, FileLines
                        ])
                    },
                    AssistantMsg = case maps:get(message, Reply, undefined) of
                        M when is_map(M) -> M#{role => assistant};
                        _ -> #{role => assistant, content => Answer}
                    end,
                    emitProgress(Opts, #{type => step, phase => batchPlan,
                                         message => <<"仅有 plan 未 apply；强制补丁轮"/utf8>>,
                                         fileCount => length(ensure_list(Files))}),
                    {retry,
                     Messages ++ [AssistantMsg, Fixup],
                     incrementRetryUsed(Opts#{batchPlanRetried => true}),
                     Step + 1,
                     [{step, Step}, batchPlanRetry | Trace]};
                miss ->
                    {done, Answer}
            end
    end.

positiveHeal(N) when is_integer(N), N >= 0 -> N;
positiveHeal(_) -> 0.

%% compile | test | patch | mixed — drives forced checklist.
classifyHealFailures(Failures) when is_list(Failures) ->
    Kinds = lists:usort([classifyHealFailureText(F) || F <- Failures]),
    case Kinds of
        [One] -> One;
        _ -> mixed
    end.

classifyHealFailureText(Bin) when is_binary(Bin) ->
    L = string:lowercase(Bin),
    case {binary:match(L, <<"verifycompile">>) =/= nomatch
            orelse binary:match(L, <<"compilefailed">>) =/= nomatch
            orelse binary:match(L, <<"compile ">>) =/= nomatch,
          binary:match(L, <<"runeunit">>) =/= nomatch
            orelse binary:match(L, <<"rundialyzer">>) =/= nomatch
            orelse binary:match(L, <<"eunit">>) =/= nomatch,
          binary:match(L, <<"applypatch">>) =/= nomatch
            orelse binary:match(L, <<"oldtext">>) =/= nomatch
            orelse binary:match(L, <<"batchrefactor">>) =/= nomatch
            orelse binary:match(L, <<"validatepatch">>) =/= nomatch
            orelse binary:match(L, <<"dryrun">>) =/= nomatch
            orelse binary:match(L, <<"writefile">>) =/= nomatch} of
        {true, false, false} -> compile;
        {false, true, false} -> test;
        {false, false, true} -> patch;
        {true, true, _} -> mixed;
        {true, _, true} -> mixed;
        {_, true, true} -> mixed;
        _ -> mixed
    end;
classifyHealFailureText(Other) ->
    classifyHealFailureText(to_binary(Other)).

healForcedWorkflow(compile) ->
    <<"强制流程（编译）：\n"
      "1) 对上面每个 file:line 的 .erl 做 readFile\n"
      "2) 用 applyPatch（hunks）只修报告的错误\n"
      "3) 反复 verifyCompile 直到 exitCode=0\n"
      "不要调用无关工具。"/utf8>>;
healForcedWorkflow(test) ->
    <<"强制流程（测试）：\n"
      "1) 从输出里 readFile 失败的测试/模块\n"
      "2) 用 applyPatch（hunks）修断言/逻辑\n"
      "3) 对该模块 runEunit 直到通过\n"
      "不要只用文字解释就终答。"/utf8>>;
healForcedWorkflow(patch) ->
    <<"强制流程（补丁）：\n"
      "1) 若有 suggestions[]，按建议片段改写 old 文本\n"
      "2) 优先带更多唯一上下文的 hunks；避免 oldTextNotUnique\n"
      "3) dryRunPatch 或 validatePatch，再 applyPatch\n"
      "4) 若是 .erl 再 verifyCompile\n"
      "不要臆造错误里没有的路径。"/utf8>>;
healForcedWorkflow(_) ->
    <<"强制流程：\n"
      "1) 对列出的 file:line 做 readFile\n"
      "2) applyPatch（优先 hunks）\n"
      "3) verifyCompile 和/或 runEunit 直到通过\n"
      "然后再给最终答案。"/utf8>>.

healLocationHint(Failures) ->
    Locs = lists:usort(lists:flatmap(fun extractLocationsFromText/1, Failures)),
    case Locs of
        [] -> <<>>;
        _ ->
            Lines = [<<"- ", L/binary>> || L <- lists:sublist(Locs, 12)],
            unicode:characters_to_binary([
                <<"可能位置（file:line）：\n"/utf8>>,
                lists:join(<<"\n">>, Lines), <<"\n">>
            ])
    end.

%% Latest successful batchRefactor plan in trace (no later apply).
latestBatchPlan(Trace) when is_list(Trace) ->
    case lists:filtermap(fun
            ({results, Results}) when is_list(Results) -> {true, Results};
            (_) -> false
        end, Trace) of
        [Latest | Rest] ->
            case extractBatchPlan(Latest) of
                {ok, Plan} ->
                    case lists:any(fun batchApplyInResults/1, [Latest | Rest]) of
                        true -> miss;
                        false -> {ok, Plan}
                    end;
                miss ->
                    miss
            end;
        [] ->
            miss
    end;
latestBatchPlan(_) ->
    miss.

extractBatchPlan(Results) when is_list(Results) ->
    lists:foldl(fun
        (Msg, miss) ->
            case isBatchRefactorMsg(Msg) of
                true ->
                    case decodeToolContent(Msg) of
                        #{status := ok, result := Res} when is_map(Res) ->
                            maybePlanMap(Res);
                        #{<<"status">> := <<"ok">>, <<"result">> := Res} when is_map(Res) ->
                            maybePlanMap(Res);
                        M when is_map(M) ->
                            %% content may already be the result map after some paths
                            case maps:get(result, M, maps:get(<<"result">>, M, M)) of
                                Res when is_map(Res) -> maybePlanMap(Res);
                                _ -> miss
                            end;
                        _ ->
                            miss
                    end;
                false ->
                    miss
            end;
        (_, Acc) -> Acc
    end, miss, Results);
extractBatchPlan(_) ->
    miss.

isBatchRefactorMsg(#{name := batchRefactor}) -> true;
isBatchRefactorMsg(#{name := <<"batchRefactor">>}) -> true;
isBatchRefactorMsg(#{<<"name">> := <<"batchRefactor">>}) -> true;
isBatchRefactorMsg(_) -> false.

maybePlanMap(Res) ->
    Toolish = maps:get(action, Res, maps:get(<<"action">>, Res, undefined)),
    case Toolish =:= plan orelse Toolish =:= <<"plan">> of
        true -> {ok, atomizePlanKeys(Res)};
        false ->
            case maps:get(status, Res, maps:get(<<"status">>, Res, undefined)) of
                planOnly -> {ok, atomizePlanKeys(Res)};
                <<"planOnly">> -> {ok, atomizePlanKeys(Res)};
                _ -> miss
            end
    end.

%% Normalize JSON-decoded plan maps so callers can use atom keys.
atomizePlanKeys(Res) when is_map(Res) ->
    Files = maps:get(files, Res, maps:get(<<"files">>, Res, [])),
    Action = maps:get(action, Res, maps:get(<<"action">>, Res, plan)),
    Res#{
        action => case Action of
            <<"plan">> -> plan;
            <<"apply">> -> apply;
            A -> A
        end,
        files => Files
    }.


batchApplyInResults(Results) when is_list(Results) ->
    lists:any(fun(Msg) ->
        isBatchRefactorMsg(Msg) andalso begin
            case decodeToolContent(Msg) of
                #{status := ok, result := Res} when is_map(Res) ->
                    isApplyAction(Res);
                #{<<"status">> := <<"ok">>, <<"result">> := Res} when is_map(Res) ->
                    isApplyAction(Res);
                _ -> false
            end
        end
    end, Results);
batchApplyInResults(_) ->
    false.

isApplyAction(Res) when is_map(Res) ->
    A = maps:get(action, Res, maps:get(<<"action">>, Res, undefined)),
    A =:= apply orelse A =:= <<"apply">>
        orelse A =:= planAndApply orelse A =:= <<"planAndApply">>
        orelse maps:get(status, Res, undefined) =:= applied
        orelse maps:get(<<"status">>, Res, undefined) =:= <<"applied">>;
isApplyAction(_) ->
    false.

decodeToolContent(#{content := C}) ->
    case C of
        M when is_map(M) -> M;
        B when is_binary(B) ->
            try alJson:decode(B) of
                M when is_map(M) -> M;
                _ -> #{}
            catch _:_ -> #{}
            end;
        _ -> #{}
    end;
decodeToolContent(_) ->
    #{}.

ensure_list(L) when is_list(L) -> L;
ensure_list(undefined) -> [];
ensure_list(Other) -> [Other].

healableFailures(Trace) when is_list(Trace) ->
    %% Prefer the most recent {results, ...} entry.
    case lists:filtermap(fun
            ({results, Results}) when is_list(Results) -> {true, Results};
            (_) -> false
        end, Trace) of
        [Latest | _] ->
            lists:filtermap(fun healableResultSummary/1, Latest);
        [] ->
            []
    end;
healableFailures(_) ->
    [].

healableResultSummary(#{content := C} = Msg) ->
    Decoded = case C of
        M when is_map(M) -> M;
        B when is_binary(B) ->
            try alJson:decode(B) of
                M when is_map(M) -> M;
                _ -> #{}
            catch _:_ -> #{}
            end;
        _ -> #{}
    end,
    case contentFailed(Decoded) orelse contentFailed(C) of
        true ->
            Tool = toolNameFromMsg(Msg, Decoded),
            case isHealableTool(Tool) of
                true ->
                    {true, formatHealFailure(Tool, Decoded)};
                false ->
                    false
            end;
        false ->
            false
    end;
healableResultSummary(_) ->
    false.

formatHealFailure(Tool, Decoded) when is_map(Decoded) ->
    Reason = failureReasonText(Decoded),
    Output = maps:get(output, Decoded,
              maps:get(<<"output">>, Decoded,
              maps:get(result, Decoded,
              maps:get(<<"result">>, Decoded, undefined)))),
    Nested = case maps:get(reason, Decoded, maps:get(<<"reason">>, Decoded, undefined)) of
        M when is_map(M) -> M;
        _ -> Decoded
    end,
    Suggestions = maps:get(suggestions, Nested,
                    maps:get(<<"suggestions">>, Nested,
                    maps:get(suggestions, Decoded,
                    maps:get(<<"suggestions">>, Decoded, [])))),
    OutBin = case Output of
        undefined -> <<>>;
        O when is_map(O) -> <<>>;
        O -> truncateBin(to_binary(O), 1200)
    end,
    Locs = extractLocationsFromText(<<Reason/binary, "\n", OutBin/binary>>),
    LocLine = case Locs of
        [] -> <<>>;
        _ ->
            unicode:characters_to_binary([
                <<" [">>, lists:join(<<", ">>, lists:sublist(Locs, 5)), <<"]">>
            ])
    end,
    SugBin = formatSuggestions(Suggestions),
    <<(to_binary(Tool))/binary, ": ", Reason/binary, LocLine/binary,
      SugBin/binary,
      (case OutBin of
           <<>> -> <<>>;
           _ -> <<"\n--- output ---\n", OutBin/binary>>
       end)/binary>>;
formatHealFailure(Tool, Other) ->
    <<(to_binary(Tool))/binary, ": ", (to_binary(Other))/binary>>.

formatSuggestions(List) when is_list(List), List =/= [] ->
    Lines = lists:filtermap(fun
        (#{snippet := S, startLine := L}) ->
            {true, iolist_to_binary(io_lib:format(
                "~n  suggestion@~p: ~s", [L, truncateBin(to_binary(S), 160)]))};
        (#{<<"snippet">> := S, <<"startLine">> := L}) ->
            {true, iolist_to_binary(io_lib:format(
                "~n  suggestion@~p: ~s", [L, truncateBin(to_binary(S), 160)]))};
        (_) -> false
    end, lists:sublist(List, 3)),
    case Lines of
        [] -> <<>>;
        _ -> unicode:characters_to_binary([<<"\n--- similar snippets ---">> | Lines])
    end;
formatSuggestions(_) ->
    <<>>.

extractLocationsFromText(Bin) when is_binary(Bin) ->
    %% Erlang compiler / dialyzer style: path.erl:123: or path.erl:123:45:
    case re:run(Bin, <<"([\\\\/A-Za-z0-9_.-]+\\.erl):(\\d+)">>,
                [global, {capture, all_but_first, binary}]) of
        {match, Groups} ->
            [<<F/binary, ":", L/binary>> || [F, L] <- Groups];
        nomatch ->
            []
    end;
extractLocationsFromText(Other) ->
    extractLocationsFromText(to_binary(Other)).

truncateBin(Bin, Max) when is_binary(Bin), byte_size(Bin) =< Max -> Bin;
truncateBin(Bin, Max) when is_binary(Bin) ->
    <<(truncateUtf8(Bin, Max))/binary, "…"/utf8>>;
truncateBin(Other, Max) ->
    truncateBin(to_binary(Other), Max).

toolNameFromMsg(Msg, C) when is_map(C) ->
    case maps:get(tool, C, maps:get(<<"tool">>, C, undefined)) of
        undefined -> maps:get(name, Msg, maps:get(<<"name">>, Msg, unknown));
        T -> T
    end;
toolNameFromMsg(Msg, _) ->
    maps:get(name, Msg, maps:get(<<"name">>, Msg, unknown)).

isHealableTool(T) when T =:= applyPatch; T =:= applyPatchBatch; T =:= verifyCompile;
                       T =:= runEunit; T =:= runDialyzer; T =:= writeFile;
                       T =:= validatePatch; T =:= dryRunPatch; T =:= batchRefactor ->
    true;
isHealableTool(T) when is_binary(T) ->
    isHealableTool(try binary_to_existing_atom(T, utf8) catch _:_ -> undefined end);
isHealableTool(T) when is_list(T) ->
    isHealableTool(list_to_binary(T));
isHealableTool(_) ->
    false.

failureReasonText(C) when is_map(C) ->
    Nested = case maps:get(reason, C, maps:get(<<"reason">>, C, undefined)) of
        M when is_map(M) ->
            maps:get(reason, M, maps:get(<<"reason">>, M,
                     maps:get(message, M, maps:get(<<"message">>, M, M))));
        Other -> Other
    end,
    R = case Nested of
        undefined ->
            maps:get(error, C,
             maps:get(<<"error">>, C,
             maps:get(message, C, <<"failed">>)));
        V -> V
    end,
    to_binary(R);
failureReasonText(C) when is_binary(C) ->
    truncateBin(C, 500);
failureReasonText(Other) ->
    to_binary(Other).

contentFailed(C) when is_map(C) ->
    maps:get(status, C, ok) =:= error
        orelse maps:get(<<"status">>, C, ok) =:= <<"error">>
        orelse maps:get(<<"status">>, C, ok) =:= error;
contentFailed(C) when is_binary(C) ->
    try alJson:decode(C) of
        M when is_map(M) ->
            St = maps:get(<<"status">>, M, maps:get(status, M, undefined)),
            St =:= <<"error">> orelse St =:= error;
        _ -> false
    catch _:_ -> false
    end;
contentFailed(_) ->
    false.

maybeAppendHealReport(Answer, [], _Attempts, _Max) ->
    Answer;
maybeAppendHealReport(Answer, Failures, Attempts, MaxHeal)
  when is_integer(MaxHeal), MaxHeal > 0, Attempts >= MaxHeal ->
    Detail = unicode:characters_to_binary(lists:join(<<"\n\n">>, Failures)),
    Locs = lists:usort(lists:flatmap(fun extractLocationsFromText/1, Failures)),
    LocBlock = case Locs of
        [] -> <<>>;
        _ ->
            unicode:characters_to_binary([
                <<"\n### 位置\n"/utf8>>,
                [[<<"- `">>, L, <<"`\n">>] || L <- lists:sublist(Locs, 20)]
            ])
    end,
    Note = unicode:characters_to_binary([
        <<"\n\n---\n## 自愈报告（已用尽 "/utf8>>,
        integer_to_binary(Attempts), <<"/">>, integer_to_binary(MaxHeal),
        <<"）\n\n自动修复后仍失败。建议下一步：\n"/utf8>>,
        <<"1. 打开下方 file:line，对照错误输出排查\n"/utf8>>,
        <<"2. 若尚未处于 edit 模式请切换，并用更窄的补丁重试\n"/utf8>>,
        <<"3. 修好后手动跑 verifyCompile / runEunit\n"/utf8>>,
        LocBlock,
        <<"\n### 失败信息\n"/utf8>>, Detail
    ]),
    case Answer of
        Bin when is_binary(Bin) -> <<Bin/binary, Note/binary>>;
        _ -> Answer
    end;
maybeAppendHealReport(Answer, _Failures, _Attempts, _Max) ->
    Answer.

normalizeToolHint(N) when is_atom(N) ->
    string:lowercase(atom_to_binary(N, utf8));
normalizeToolHint(N) when is_binary(N) ->
    string:lowercase(binary:replace(N, <<"_">>, <<>>, [global]));
normalizeToolHint(N) when is_list(N) ->
    normalizeToolHint(unicode:characters_to_binary(N));
normalizeToolHint(_) ->
    <<>>.

%%--------------------------------------------------------------------
%% @doc
%% Token 预算触顶时的收敛：停止再调用工具，让 LLM 基于已收集的信息
%% 直接给出最终答案。LLM 调用失败时退回本地兜底答案。
%%
%% @param BoundedMessages 当前裁剪后的消息列表
%% @param LlmOpts LLM 选项
%% @param Opts 选项 map
%% @param Context 上下文
%% @param Trace 累积轨迹
%% @return `{ok, Reply}'
%% @end
%%--------------------------------------------------------------------
convergeOnBudget(BoundedMessages, LlmOpts, Opts, Context, Trace) ->
    emitProgress(Opts, #{type => step, phase => budget,
                         message => <<"token budget exceeded; converging to final answer">>}),
    Question = maps:get(currentQuestion, Opts, undefined),
    Nudge = #{role => user,
              content => <<"已达到本任务的 token 预算。请停止调用工具，"
                           "根据目前已收集的信息给出最终答案。"
                           "语言与用户问题一致（用户中文则用中文）。"/utf8>>},
    FinalMessages = BoundedMessages ++ [Nudge],
    case alLlmClient:chat(FinalMessages, LlmOpts) of
        {ok, Reply} ->
            emitProgress(Opts, #{type => completed, reason => tokenBudgetExceeded}),
            maybeDeleteCheckpoint(Opts),
            Answer0 = answerFromReply(Reply),
            Answer = case maps:get(groundingCheck, Opts, true) of
                true ->
                    try alGrounding:check(Answer0, Context, Trace) of
                        {ungrounded, Claims} ->
                            alGrounding:appendWarning(Answer0, alGrounding:warningText(Claims));
                        _ ->
                            Answer0
                    catch
                        _:_ -> Answer0
                    end;
                false ->
                    Answer0
            end,
            {ok, #{
                answer => Answer,
                context => Context,
                llm => Reply,
                budgetExceeded => true,
                trace => lists:reverse(Trace)
            }};
        {error, Reason} ->
            emitProgress(Opts, #{type => failed, reason => {tokenBudgetExceeded, Reason}}),
            maybeDeleteCheckpoint(Opts),
            Base = fallbackAnswer(Question, Context, tokenBudgetExceeded),
            {ok, #{
                answer => Base#{trace => lists:reverse(Trace)},
                context => Context,
                budgetExceeded => true,
                trace => lists:reverse(Trace)
            }}
    end.

%% 工具步数用尽：禁止再调工具，基于已有 runMfa/检索结果直接作答。
convergeOnMaxSteps(Messages, Opts, Context, Trace) ->
    emitProgress(Opts, #{type => step, phase => maxSteps,
                         message => <<"已达工具步数上限；收敛为终答"/utf8>>}),
    Question = maps:get(currentQuestion, Opts, undefined),
    LlmOpts = maps:remove(tools, llmOpts(Opts)),
    Bounded = trimToolMessages(Messages, Opts),
    TraceHint = summarizeTraceForConverge(Trace),
    Nudge = #{role => user,
              content => iolist_to_binary([
                    <<"已达到最大工具调用步数。停止再调工具。"
                    "请立刻根据对话里已有的工具结果回答用户"
                    "（尤其是成功的 runMfa / searchCode 命中）。"
                    "若有关键数值或标识，请明确写出。"
                    "不要编造工具结果里没有的 MFA 或数值。\n"/utf8>>,
                  TraceHint
              ])},
    FinalMessages = Bounded ++ [Nudge],
    case alLlmClient:chat(FinalMessages, LlmOpts) of
        {ok, Reply} ->
            emitProgress(Opts, #{type => completed, reason => maxToolSteps}),
            maybeDeleteCheckpoint(Opts),
            {ok, #{
                answer => answerFromReply(Reply),
                context => Context,
                llm => Reply,
                maxStepsExceeded => true,
                trace => lists:reverse(Trace)
            }};
        {error, Reason} ->
            emitProgress(Opts, #{type => failed, reason => {maxToolSteps, Reason}}),
            maybeDeleteCheckpoint(Opts),
            Base = fallbackAnswer(Question, Context, maxToolSteps),
            {ok, #{
                answer => Base#{
                    trace => lists:reverse(Trace),
                    toolTraceSummary => TraceHint
                },
                context => Context,
                maxStepsExceeded => true,
                trace => lists:reverse(Trace)
            }}
    end.

%% 从 trace 抽出最近 runMfa 结果摘要，帮助收敛作答。
summarizeTraceForConverge(Trace) when is_list(Trace) ->
    Snips = lists:flatmap(fun
        ({results, Results}) when is_list(Results) ->
            [toolResultSnippet(R) || R <- Results];
        (_) -> []
    end, lists:sublist(Trace, 12)),
    case [S || S <- Snips, S =/= <<>>] of
        [] -> <<"（无紧凑工具摘要；请看消息历史）"/utf8>>;
        L -> iolist_to_binary([<<"近期工具片段：\n"/utf8>>, [[S, <<"\n">>] || S <- lists:sublist(L, 6)]])
    end;
summarizeTraceForConverge(_) ->
    <<>>.

toolResultSnippet(#{content := Content}) ->
    Bin = case Content of
        B when is_binary(B) -> B;
        M when is_map(M) ->
            try alJson:encode(M) catch _:_ -> unicode:characters_to_binary(io_lib:format("~p", [M])) end;
        Other -> unicode:characters_to_binary(io_lib:format("~p", [Other]))
    end,
    case byte_size(Bin) > 2000 of
        true -> <<(binary:part(Bin, 0, 2000))/binary, "...[truncated]">>;
        false -> Bin
    end;
toolResultSnippet(_) ->
    <<>>.

%%--------------------------------------------------------------------
%% @doc
%% 批量执行 LLM 返回的 tool_calls，返回每条工具结果消息列表。
%%
%% @param ToolCalls 工具调用列表
%% @param Opts 选项 map
%% @return 工具结果消息列表（每条含 role=tool/tool_call_id/content）
%% @end
%%--------------------------------------------------------------------
executeToolCalls(ToolCalls, Opts) ->
    case length(ToolCalls) =< 1 of
        true ->
            %% Single call — no need for parallel overhead.
            [toolResultMessage(Call, Opts) || Call <- ToolCalls];
        false ->
            executeToolCallsParallel(ToolCalls, Opts)
    end.

%% 并行执行多个工具调用：先按读写分组，再分批执行。
%% - 连续只读调用聚为一组，组内受 maxToolConcurrency（默认
%%   ?DefaultToolConcurrency=3）限制并发度：批内并行、批间串行。
%% - 写类工具（isWriteToolCall/1）单独成组串行保序，绝不与读写并行，
%%   杜绝「同轮 写+读 同文件」竞态与写乱序。
%% 结果整体按原始顺序返回。
executeToolCallsParallel(ToolCalls, Opts) ->
    MaxConc = max(1, maps:get(maxToolConcurrency, Opts, ?DefaultToolConcurrency)),
    Groups = groupToolCallsByWrite(ToolCalls),
    runToolGroups(Groups, Opts, MaxConc, []).

%% 读写分组：连续只读调用聚成一组（组内可并行），写调用单独成组（串行）。
%% 分组保持原始顺序——写之后的读必然看到写完成后的状态。
groupToolCallsByWrite(ToolCalls) when is_list(ToolCalls) ->
    groupToolCallsByWrite(ToolCalls, [], []).

groupToolCallsByWrite([], ReadAcc, GroupAcc) ->
    lists:reverse(flushReadGroup(ReadAcc, GroupAcc));
groupToolCallsByWrite([Call | Rest], ReadAcc, GroupAcc) ->
    case isWriteToolCall(Call) of
        true ->
            groupToolCallsByWrite(Rest, [], [[Call] | flushReadGroup(ReadAcc, GroupAcc)]);
        false ->
            groupToolCallsByWrite(Rest, [Call | ReadAcc], GroupAcc)
    end.

%% 把积攒的只读组（反向累积）落进组列表（反向累积）。
flushReadGroup([], GroupAcc) ->
    GroupAcc;
flushReadGroup(ReadAcc, GroupAcc) ->
    [lists:reverse(ReadAcc) | GroupAcc].

%% 从 OpenAI tool_call 结构判断是否写类工具；非标准结构按只读处理，
%% 由后续 toolResultMessage 的执行路径兜底。
isWriteToolCall(#{function := #{name := Name}}) ->
    try isWriteTool(alLlmTools:toolAtom(Name)) catch _:_ -> false end;
isWriteToolCall(_) ->
    false.

%% 逐组执行：写组（单元素）同样走 worker 路径，保持与读组一致的崩溃隔离；
%% 结果按组拼接还原整体顺序。
runToolGroups([], _Opts, _MaxConc, Acc) ->
    lists:append(lists:reverse(Acc));
runToolGroups([Group | Rest], Opts, MaxConc, Acc) ->
    Results = runToolBatches(Group, Opts, MaxConc, []),
    runToolGroups(Rest, Opts, MaxConc, [Results | Acc]).

%% 逐批执行，累积各批结果（反向），最后拼接还原顺序。
runToolBatches([], _Opts, _MaxConc, Acc) ->
    lists:append(lists:reverse(Acc));
runToolBatches(ToolCalls, Opts, MaxConc, Acc) ->
    {Batch, Rest} = splitBatch(ToolCalls, MaxConc),
    Results = runToolBatch(Batch, Opts),
    runToolBatches(Rest, Opts, MaxConc, [Results | Acc]).

%% 取前 N 个作为一批，其余留待下一批。
splitBatch(List, N) when length(List) =< N -> {List, []};
splitBatch(List, N) -> lists:split(N, List).

%% 单批并行执行：每个工具在独立进程中执行；每个 worker 独立计算剩余超时，
%% 慢工具单独返回 toolTimeout 而不杀整批，避免一个慢搜索拖累其他快工具。
runToolBatch(ToolCalls, Opts) ->
    Parent = self(),
    Workers = [begin
        Ref = make_ref(),
        {Pid, MonRef} = spawn_monitor(fun() ->
            Result = toolResultMessage(Call, Opts),
            Parent ! {toolResult, Ref, Result}
        end),
        {Ref, Pid, MonRef, maps:get(id, Call, to_binary(Ref))}
    end || Call <- ToolCalls],
    Timeout = maps:get(toolTimeoutMs, Opts, 20000),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    collectToolResults(Workers, Deadline, []).

%% 每个 worker 独立按剩余时间等待：超时只杀当前 worker，其余继续。
%% 这样慢工具（如大文件 searchCode）单独返回 toolTimeout，快工具结果正常返回。
collectToolResults([], _Deadline, Acc) ->
    lists:reverse(Acc);
collectToolResults([{Ref, Pid, MonRef, ToolCallId} | Rest], Deadline, Acc) ->
    Now = erlang:monotonic_time(millisecond),
    Remain = max(0, Deadline - Now),
    Result = receive
        {toolResult, Ref, Res} ->
            erlang:demonitor(MonRef, [flush]),
            Res;
        {'DOWN', MonRef, process, Pid, Reason} ->
            #{role => tool, tool_call_id => ToolCallId,
              content => #{status => error, reason => {toolWorkerCrashed, Reason}}}
    after Remain ->
        %% 仅杀当前超时的 worker，不杀整批
        exit(Pid, kill),
        erlang:demonitor(MonRef, [flush]),
        flushToolResults([Ref]),
        #{role => tool, tool_call_id => ToolCallId,
          content => #{status => error, reason => toolTimeout}}
    end,
    case Result of
        Map when is_map(Map) ->
            collectToolResults(Rest, Deadline, [Map | Acc]);
        List when is_list(List) ->
            %% 防御：正常 toolResultMessage 恒返回 map；万一返回列表，
            %% 逐条并入结果继续收割，绝不丢弃剩余 worker。
            collectToolResults(Rest, Deadline, lists:foldl(fun(R, A) -> [R | A] end, Acc, List));
        Other ->
            collectToolResults(Rest, Deadline, [Other | Acc])
    end.

%% 清空信箱中可能残留的 {toolResult, Ref, _} 消息：每个 Ref 做一次非阻塞 receive。
%% 杀掉 worker 后 worker 可能已发出 toolResult（但还没轮到 receive 取走），不 flush
%% 会污染下一次 collectToolResults 的 receive，导致邮箱长期累积。
flushToolResults([]) ->
    ok;
flushToolResults([Ref | Rest]) ->
    receive
        {toolResult, Ref, _} ->
            flushToolResults(Rest)
    after 0 ->
        flushToolResults(Rest)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 裁剪工具循环中的消息列表：保留全部非 tool 协议轮次（含普通 assistant），
%% 仅对 assistant(tool_calls)+tools 轮次按 maxToolMsgPairs 裁剪。
%%
%% 默认保留 ?MaxToolMsgPairs 轮（8）。可在 Opts/agentCfg 中通过
%% maxToolMsgPairs 覆盖。token 紧张时（estimate > Budget * 0.7）自动压到
%% ?MaxToolMsgPairsLowBudget（4），避免大结果反复送进 LLM 烧 token。
%%
%% @param Messages 当前消息列表
%% @return 裁剪后的消息列表
%% @end
%%--------------------------------------------------------------------
-ifdef(TEST).
trimToolMessages(Messages) ->
    trimToolMessages(Messages, #{}).
-endif.

trimToolMessages(Messages, Opts) when is_map(Opts) ->
    %% Always validate grouping, even for short lists: an orphan tool message
    %% is a protocol error regardless of context size.
    Parts = segmentToolParts(Messages),
    RoundCount = length([1 || {round, _} <- Parts]),
    MaxPairs = effectiveMaxToolMsgPairs(Messages, Opts),
    DropN = max(0, RoundCount - MaxPairs),
    %% 优先丢掉带 truncated 的旧轮，再 FIFO 丢最早轮，减轻「截断结果反复进上下文」
    lists:append([Msgs || {_, Msgs} <- dropRoundsPreferTruncated(Parts, DropN)]).

%% 计算生效的最大保留轮数：默认 ?MaxToolMsgPairs（8），
%% 可被 Opts.maxToolMsgPairs / agentCfg.maxToolMsgPairs 覆盖。
%% token 紧张时自动压到 ?MaxToolMsgPairsLowBudget（4）。
effectiveMaxToolMsgPairs(Messages, Opts) ->
    AgentCfg = maps:get(agentCfg, Opts, #{}),
    Configured = maps:get(maxToolMsgPairs, Opts,
                          maps:get(maxToolMsgPairs, AgentCfg, ?MaxToolMsgPairs)),
    Budget = maps:get(maxTokensBudget, Opts, ?DefaultTokenBudget),
    Estimated = try alTokenStats:estimateMessages(Messages)
                 catch _:_ -> 0 end,
    case Estimated > Budget * 0.7 of
        true -> min(Configured, ?MaxToolMsgPairsLowBudget);
        false -> Configured
    end.

%% 优先丢弃含 truncated 标记的工具轮；没有则回退按时间丢最早轮。
dropRoundsPreferTruncated(Parts, 0) ->
    Parts;
dropRoundsPreferTruncated(Parts, N) when N > 0 ->
    case findFirstTruncatedRoundIndex(Parts, 0) of
        {ok, Idx} ->
            dropRoundsPreferTruncated(dropAtIndex(Parts, Idx), N - 1);
        none ->
            dropFirstRounds(Parts, N)
    end.

findFirstTruncatedRoundIndex([{round, Msgs} | Rest], Idx) ->
    case roundMsgsTruncated(Msgs) of
        true -> {ok, Idx};
        false -> findFirstTruncatedRoundIndex(Rest, Idx + 1)
    end;
findFirstTruncatedRoundIndex([_ | Rest], Idx) ->
    findFirstTruncatedRoundIndex(Rest, Idx + 1);
findFirstTruncatedRoundIndex([], _) ->
    none.

dropAtIndex(List, Idx) when Idx >= 0 ->
    {Left, Rest} = lists:split(Idx, List),
    case Rest of
        [_ | Right] -> Left ++ Right;
        [] -> Left
    end.

%% 判断一轮工具消息是否带 truncated（content 为 JSON binary 或 map）。
roundMsgsTruncated(Msgs) when is_list(Msgs) ->
    lists:any(fun contentLooksTruncated/1, Msgs).

contentLooksTruncated(#{content := C}) ->
    contentLooksTruncated(C);
contentLooksTruncated(Bin) when is_binary(Bin) ->
    binary:match(Bin, <<"\"truncated\":true">>) =/= nomatch
        orelse binary:match(Bin, <<"\"truncated\": true">>) =/= nomatch;
contentLooksTruncated(Map) when is_map(Map) ->
    maps:get(truncated, Map, false) =:= true
        orelse maps:get(<<"truncated">>, Map, false) =:= true;
contentLooksTruncated(_) ->
    false.

%% Split into chronological plain segments and complete tool rounds.
segmentToolParts([]) ->
    [];
segmentToolParts([M | Rest]) ->
    case isAssistantWithToolCalls(M) of
        true ->
            {ToolResults, Tail} = takeToolResults(Rest, []),
            case ToolResults of
                [] -> segmentToolParts(Tail);
                _ -> [{round, [M | ToolResults]} | segmentToolParts(Tail)]
            end;
        false ->
            case messageRole(M) of
                tool ->
                    %% Orphan tool — drop from protocol stream.
                    segmentToolParts(Rest);
                _ ->
                    {Plain, Tail} = takePlainMessages(Rest, [M]),
                    [{plain, Plain} | segmentToolParts(Tail)]
            end
    end.

takePlainMessages([M | Rest], Acc) ->
    case isAssistantWithToolCalls(M) orelse messageRole(M) =:= tool of
        true -> {lists:reverse(Acc), [M | Rest]};
        false -> takePlainMessages(Rest, [M | Acc])
    end;
takePlainMessages([], Acc) ->
    {lists:reverse(Acc), []}.

dropFirstRounds(Parts, 0) ->
    Parts;
dropFirstRounds([{round, _} | Rest], N) when N > 0 ->
    dropFirstRounds(Rest, N - 1);
dropFirstRounds([P | Rest], N) when N > 0 ->
    [P | dropFirstRounds(Rest, N)];
dropFirstRounds([], _) ->
    [].

takeToolResults([M | Rest], Acc) ->
    case messageRole(M) of
        tool -> takeToolResults(Rest, [M | Acc]);
        _ -> {lists:reverse(Acc), [M | Rest]}
    end;
takeToolResults([], Acc) ->
    {lists:reverse(Acc), []}.

isAssistantWithToolCalls(M) ->
    messageRole(M) =:= assistant andalso messageToolCalls(M) =/= [].

messageRole(#{role := Role}) -> normalizeRole(Role);
messageRole(#{<<"role">> := Role}) -> normalizeRole(Role);
messageRole(_) -> other.

normalizeRole(system) -> system;
normalizeRole(<<"system">>) -> system;
normalizeRole(user) -> user;
normalizeRole(<<"user">>) -> user;
normalizeRole(assistant) -> assistant;
normalizeRole(<<"assistant">>) -> assistant;
normalizeRole(tool) -> tool;
normalizeRole(<<"tool">>) -> tool;
normalizeRole(_) -> other.

messageToolCalls(M) ->
    maps:get(tool_calls, M, maps:get(<<"tool_calls">>, M, [])).

%% If alAgent already appended the current question, drop that trailing user
%% message so Messages0 does not duplicate it.
dropTrailingCurrentUser([], _Question) ->
    [];
dropTrailingCurrentUser(History, Question) ->
    case lists:reverse(History) of
        [#{role := Role, content := Content} | Rest]
          when Role =:= user; Role =:= <<"user">> ->
            case sameUserContent(Content, Question) of
                true -> lists:reverse(Rest);
                false -> History
            end;
        _ ->
            History
    end.

sameUserContent(Content, Question) when is_binary(Content), is_binary(Question) ->
    Content =:= Question;
sameUserContent(Content, Question) ->
    to_binary(Content) =:= to_binary(Question).

%%--------------------------------------------------------------------
%% @doc
%% 执行单条工具调用：解码参数、注入上下文、检查策略并执行工具，
%% 返回 OpenAI 工具结果消息格式。
%%
%% @param Call 工具调用 map（含 id/function/arguments）
%% @param Opts 选项 map
%% @return 工具结果消息 map
%% @end
%%--------------------------------------------------------------------
toolResultMessage(#{id := Id, function := #{name := Name, arguments := Args}}, Opts) ->
    Tool = alLlmTools:toolAtom(Name),
    Decoded0 = case alLlmTools:decodeArgs(Args) of
        {ok, Map} -> {ok, injectToolContext(Tool, Map, Opts)};
        Error -> Error
    end,
    RawResult = case Decoded0 of
        {ok, Decoded} ->
            case registerToolIntent(Tool, Decoded) of
                {block, Blocked} ->
                    Blocked;
                {ok, IntentCount} ->
                    case maybeReuseToolResult(Tool, Decoded) of
                        {hit, Cached} ->
                            maybeAttachDuplicateHint(Tool, Decoded, IntentCount, Cached);
                        miss ->
                            Executed = executeTool(Tool, Decoded, Opts),
                            %% 截断感知：超 maxToolContentBytes 的搜索/读取结果，
                            %% 自动用 limit/2 重试一次，避免 LLM 看到被截断的内容而
                            %% 产生幻觉。最多重试一次（防无限循环）。
                            Retried = maybeRetractToolResult(Tool, Decoded, Executed, Opts),
                            Annotated = maybeAnnotateTruncated(Retried),
                            rememberToolResult(Tool, Decoded, Annotated),
                            maybeAttachDuplicateHint(Tool, Decoded, IntentCount, Annotated)
                    end
            end;
        {error, Reason} ->
            #{status => error, reason => Reason}
    end,
    Result = capToolResult(Tool, RawResult),
    #{
        role => tool,
        tool_call_id => Id,
        name => Tool,
        %% Always a JSON text binary so encode/cap layers cannot mid-cut a map.
        content => Result
    }.

%% 同参工具结果缓存：避免一轮对话里反复 getCallers 烧 token。
%% 字段白名单已补全 context/mode/maxBytes/lineCount/glob/recursive 等影响结果的参数，
%% 避免不同 context/mode 的搜索被误判为相同调用返回旧缓存。
toolFingerprint(Tool, Args) when is_map(Args) ->
    Keys = [module, function, arity, limit, offset, includeSource, includeMermaid,
            format, detail, path, query, startLine, endLine, maxEdges, ref, days,
            count, withFiles, context, mode, maxBytes, lineCount, glob, recursive,
            maxEntries, modifiedSince, author, vcsStatus, paths, backend,
            cursor, pageSize, summaryMode, contextLines, topic],
    Norm = lists:foldl(
        fun(K, Acc) ->
            case maps:get(K, Args, maps:get(atom_to_binary(K, utf8), Args, undefined)) of
                undefined -> Acc;
                V -> Acc#{K => V}
            end
        end, #{}, Keys),
    %% readFile：用「文件路径 + 行区间」做 fingerprint，但忽略 maxBytes 差异
    %% （模型常改 maxBytes 试探，但同文件同区间结果一致）。无行区间时按路径归一。
    case Tool of
        readFile ->
            {readFile, readFileFingerprint(Norm)};
        readFilePage ->
            %% 不同 cursor 是不同页，必须进指纹，避免续读命中错误缓存
            {readFilePage, #{
                path => maps:get(path, Norm, undefined),
                cursor => maps:get(cursor, Norm, null),
                pageSize => maps:get(pageSize, Norm, 200)
            }};
        _ ->
            {Tool, Norm}
    end.

%% readFile 指纹：以 path + 行区间为核心，忽略 maxBytes。
%% 无 startLine 时按「文件头」归一，让「改 maxBytes 从头读」的多次调用命中同一缓存。
readFileFingerprint(Norm) ->
    Path = maps:get(path, Norm, undefined),
    StartLine = maps:get(startLine, Norm, undefined),
    EndLine = maps:get(endLine, Norm, undefined),
    LineCount = maps:get(lineCount, Norm, undefined),
    %% 有行区间：用区间标识；无行区间：统一为 fromHead
    Interval = case {StartLine, EndLine, LineCount} of
        {S, E, _} when is_integer(S), is_integer(E) -> {S, E};
        {S, _, LC} when is_integer(S), is_integer(LC) -> {S, S + LC - 1};
        _ -> fromHead
    end,
    #{path => Path, interval => Interval}.

maybeReuseToolResult(Tool, Decoded) ->
    case isCacheableTool(Tool) of
        false ->
            miss;
        true ->
            Fp = toolFingerprint(Tool, Decoded),
            case get(?ToolFpCacheKey) of
                Cache when is_map(Cache) ->
                    case maps:get(Fp, Cache, undefined) of
                        undefined ->
                            miss;
                        Prev when is_map(Prev) ->
                            {hit, Prev#{cached => true,
                                        hint => <<"同参结果已缓存；勿重复调用。请直接作答。"/utf8>>}};
                        _ ->
                            miss
                    end;
                _ ->
                    miss
            end
    end.

rememberToolResult(Tool, Decoded, Result) ->
    case isCacheableTool(Tool) andalso is_map(Result) of
        true ->
            Fp = toolFingerprint(Tool, Decoded),
            Cache0 = case get(?ToolFpCacheKey) of
                C when is_map(C) -> C;
                _ -> #{}
            end,
            Cache1 = case maps:size(Cache0) >= 32 of
                true -> maps:from_list(lists:sublist(maps:to_list(Cache0), 24));
                false -> Cache0
            end,
            put(?ToolFpCacheKey, Cache1#{Fp => Result});
        _ ->
            ok
    end.

%%--------------------------------------------------------------------
%% @doc
%% 调用意图登记：同一 toolLoop 内对相同意图计数。
%% - 第 3 次起硬拦截（不执行工具），强制模型换工具或按 pagination 续读
%% - 第 2 次仍执行，稍后附加 duplicateIntentHint
%% 意图实体对 readFile/readFilePage 含行区间/cursor，避免误伤合法分页。
%%
%% @return `{ok, Count}' | `{block, ErrorMap}'
%% @end
%%--------------------------------------------------------------------
registerToolIntent(Tool, Decoded) ->
    case toolIntentEntity(Tool, Decoded) of
        undefined ->
            {ok, 0};
        Entity ->
            IntentKey = {Tool, Entity},
            Log0 = case get(?ToolIntentLogKey) of
                L when is_map(L) -> L;
                _ -> #{}
            end,
            Count = maps:get(IntentKey, Log0, 0) + 1,
            put(?ToolIntentLogKey, Log0#{IntentKey => Count}),
            case Count > 2 of
                true ->
                    {block, duplicateIntentError(Tool, Decoded, Entity, Count)};
                false ->
                    {ok, Count}
            end
    end.

maybeAttachDuplicateHint(Tool, Decoded, Count, Result) when is_map(Result), Count >= 2 ->
    Entity = toolIntentEntity(Tool, Decoded),
    Hint = iolist_to_binary([
        <<"你已"/utf8>>, integer_to_binary(Count),
        <<"次用相同意图读取("/utf8>>, to_binary(Entity),
        <<")。若仍不完整请按 paginationHint/readFilePage 续读，"
          "或改用 getSymbol/getSymbolSource；勿反复同参重试。"/utf8>>
    ]),
    Result#{duplicateIntentHint => Hint};
maybeAttachDuplicateHint(_Tool, _Decoded, _Count, Result) ->
    Result.

duplicateIntentError(Tool, Decoded, Entity, Count) ->
    HintBase = case Tool of
        readFile ->
            <<"已拦截重复 readFile。请改用 readFilePage(cursor) 续读，"
              "或 getSymbolSource 读单函数；勿再改 maxBytes 从头读。"/utf8>>;
        readFilePage ->
            <<"已拦截重复 readFilePage（相同 cursor）。请传上次的 nextCursor 读下一页，"
              "或改用 getSymbolSource。"/utf8>>;
        searchCode ->
            <<"已拦截重复 searchCode。请缩小 query/limit，或改用 getSymbolSource/readFilePage。"/utf8>>;
        searchText ->
            <<"已拦截重复 searchText。请缩小 query，或改用精确 MFA 工具。"/utf8>>;
        _ ->
            <<"已拦截重复工具调用。请换工具或按 paginationHint 续读，勿同参重试。"/utf8>>
    end,
    #{
        status => error,
        reason => duplicateIntent,
        duplicateIntent => true,
        count => Count,
        entity => Entity,
        hint => HintBase,
        paginationHint => paginationHintFor(Tool, Decoded#{path =>
            maps:get(path, Decoded, maps:get(<<"path">>, Decoded, undefined))})
    }.

%% 提取工具调用的目标实体（用于意图去重）。readFile 含行区间；readFilePage 含 cursor。
toolIntentEntity(readFile, Args) ->
    case maps:get(path, Args, maps:get(<<"path">>, Args, undefined)) of
        undefined -> undefined;
        _ ->
            {_Tag, Fp} = toolFingerprint(readFile, Args),
            Fp
    end;
toolIntentEntity(readFilePage, Args) ->
    case maps:get(path, Args, maps:get(<<"path">>, Args, undefined)) of
        undefined -> undefined;
        _ ->
            {_Tag, Fp} = toolFingerprint(readFilePage, Args),
            Fp
    end;
toolIntentEntity(getSymbolSource, Args) ->
    Module = maps:get(module, Args, maps:get(<<"module">>, Args, undefined)),
    Function = maps:get(function, Args, maps:get(<<"function">>, Args, undefined)),
    Arity = maps:get(arity, Args, maps:get(<<"arity">>, Args, undefined)),
    case {Module, Function} of
        {M, F} when M =/= undefined, F =/= undefined -> {M, F, Arity};
        _ -> undefined
    end;
toolIntentEntity(searchCode, Args) ->
    maps:get(query, Args, maps:get(<<"query">>, Args, undefined));
toolIntentEntity(searchText, Args) ->
    maps:get(query, Args, maps:get(<<"query">>, Args, undefined));
toolIntentEntity(getSymbol, Args) ->
    Module = maps:get(module, Args, maps:get(<<"module">>, Args, undefined)),
    Function = maps:get(function, Args, maps:get(<<"function">>, Args, undefined)),
    case {Module, Function} of
        {M, F} when M =/= undefined, F =/= undefined -> {M, F};
        _ -> undefined
    end;
toolIntentEntity(moduleSymbols, Args) ->
    maps:get(module, Args, maps:get(<<"module">>, Args, undefined));
toolIntentEntity(_Tool, _Args) ->
    undefined.

isCacheableTool(Tool) ->
    isCallEdgeTool(Tool)
        orelse Tool =:= resolveModule
        orelse Tool =:= gotoDef
        orelse Tool =:= lastCommit
        orelse Tool =:= recentCommits
        orelse Tool =:= commitDiff
        orelse Tool =:= reviewChangeImpact
        orelse Tool =:= getSymbolSource
        %% 高频只读工具：纳入 in-loop 缓存，避免模型改 maxBytes/context 等次要参数
        %% 后反复重调同一目标。readFile 行区间近似命中由 readFileFingerprint 处理。
        orelse Tool =:= readFile
        orelse Tool =:= readFilePage
        orelse Tool =:= searchCode
        orelse Tool =:= searchText
        orelse Tool =:= listFiles
        orelse Tool =:= moduleSymbols
        orelse Tool =:= moduleExports
        orelse Tool =:= getModuleTypes
        orelse Tool =:= getSymbol.

%% Encode tool results as a valid JSON string under a per-tool budget.
%% Prefer a structured truncated marker over slicing arbitrary JSON.
capToolResult(Tool, Result) ->
    Budget = toolResultBudget(Tool),
    Prepared = prepareToolResultForCap(Tool, Result),
    Encoded = try alJson:encode(Prepared)
              catch _:_ -> alJson:encode(#{status => error, reason => encodeFailed,
                                           preview => to_binary(Prepared)})
              end,
    case byte_size(Encoded) =< Budget of
        true ->
            Encoded;
        false ->
            case slimOversizedToolResult(Tool, Prepared, Budget) of
                {ok, SlimBin} ->
                    SlimBin;
                error ->
                    PreviewBytes = max(64, min(1024, Budget div 4)),
                    Preview = truncateUtf8(Encoded, min(byte_size(Encoded), PreviewBytes)),
                    %% 硬截断：序列化后超预算，模型需缩小范围重调。
                    %% 统一协议：truncationKind=hard + retriedBySystem=false + paginationHint
                    Meta = buildTruncationMeta(hard, false, Tool, Prepared),
                    alJson:encode(maps:merge(#{
                        status => truncated,
                        truncated => true,
                        originalBytes => byte_size(Encoded),
                        keptBytes => byte_size(Preview),
                        preview => Preview,
                        hint => truncatedHint(Tool)
                    }, Meta))
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 构造统一的截断元数据，让 LLM 能区分：
%% - hard：需按 paginationHint 续读/缩小范围重调
%% - soft：系统已自动减半重试，结果可直接用
%% - slim：仅就地瘦身（去 mermaid/砍条数），未重新调用工具
%%
%% @param Kind       hard | soft | slim
%% @param Retried    是否已由系统自动减半重试（仅 soft 应为 true）
%% @param Tool       工具 atom
%% @param Result     原始结果 map（用于推断 paginationHint）
%% @return 截断元数据 map
%% @end
%%--------------------------------------------------------------------
buildTruncationMeta(Kind, Retried, Tool, Result) when is_map(Result) ->
    #{
        truncationKind => Kind,
        retriedBySystem => Retried,
        slimmedBySystem => Kind =:= slim,
        paginationHint => paginationHintFor(Tool, Result)
    };
buildTruncationMeta(Kind, Retried, _Tool, _Result) ->
    #{
        truncationKind => Kind,
        retriedBySystem => Retried,
        slimmedBySystem => Kind =:= slim,
        paginationHint => null
    }.

%%--------------------------------------------------------------------
%% @doc
%% 根据工具类型推断续读提示：readFile 给出 startLine/endLine；
%% 调用方类工具给出 limit/offset；其他工具返回 null。
%%
%% @param Tool   工具 atom
%% @param Result 原始结果 map
%% @return #{tool, suggestedArgs} | null
%% @end
%%--------------------------------------------------------------------
paginationHintFor(readFile, Result) when is_map(Result) ->
    %% readFile 截断后：基于已知 totalLines/endLine/lineCount 推断续读区间
    Path = maps:get(path, Result, <<>>),
    case {maps:get(totalLines, Result, undefined),
          maps:get(endLine, Result, undefined),
          maps:get(lineCount, Result, undefined)} of
        %% 行区间模式截断：endLine < totalLines，续读 endLine+1 起
        {TotalLines, EndLine, LineCount} when is_integer(TotalLines),
                                              is_integer(EndLine), is_integer(LineCount),
                                              TotalLines > EndLine ->
            NextStart = EndLine + 1,
            NextEnd = min(TotalLines, NextStart + LineCount - 1),
            #{tool => readFile,
              suggestedArgs => #{path => Path, startLine => NextStart, endLine => NextEnd}};
        %% 文件头截断但有 totalLines：从第 1 行读 250 行
        {TotalLines, _, _} when is_integer(TotalLines), TotalLines > 0 ->
            NextEnd = min(TotalLines, 250),
            #{tool => readFile,
              suggestedArgs => #{path => Path, startLine => 1, endLine => NextEnd}};
        %% 仅有 totalBytes：用估算（平均每行约 40 字节）
        _ ->
            case maps:get(totalBytes, Result, undefined) of
                TB when is_integer(TB), TB > 0 ->
                    EstLines = max(250, TB div 40),
                    #{tool => readFile,
                      suggestedArgs => #{path => Path, startLine => 1,
                                         endLine => min(EstLines, 250)}};
                _ ->
                    case Path of
                        <<>> -> null;
                        _ ->
                            %% 无尺寸信息时仍建议改用分页工具
                            #{tool => readFilePage,
                              suggestedArgs => #{path => Path, cursor => null, pageSize => 200}}
                    end
            end
    end;
paginationHintFor(Tool, Result) when Tool =:= getCallers; Tool =:= getCallees;
                                      Tool =:= findCallers; Tool =:= findCallees;
                                      Tool =:= findRefs ->
    %% 调用方类工具：固定页大小推进 offset，避免 limit 跟着 returned 越缩越小
    PageLimit = case maps:get(limit, Result, undefined) of
        L when is_integer(L), L > 0 -> L;
        _ -> 40
    end,
    case {maps:get(returned, Result, undefined),
          maps:get(count, Result, undefined)} of
        {Returned, Count} when is_integer(Returned), is_integer(Count),
                               Count > Returned ->
            #{tool => Tool,
              suggestedArgs => #{offset => Returned, limit => PageLimit}};
        _ ->
            null
    end;
paginationHintFor(searchCode, Result) when is_map(Result) ->
    %% 搜索类：建议减小 limit 重搜，或用更精确的 query
    case maps:get(matchCount, Result, undefined) of
        MC when is_integer(MC), MC > 0 ->
            #{tool => searchCode,
              suggestedArgs => #{query => maps:get(query, Result, <<>>),
                                 limit => 3,
                                 hint => <<"缩小 limit 或用更精确的 query 重搜"/utf8>>}};
        _ ->
            null
    end;
paginationHintFor(searchText, Result) when is_map(Result) ->
    case maps:get(matchCount, Result, undefined) of
        MC when is_integer(MC), MC > 0 ->
            #{tool => searchText,
              suggestedArgs => #{query => maps:get(query, Result, <<>>),
                                 limit => 3}};
        _ ->
            null
    end;
paginationHintFor(fetchUrl, Result) when is_map(Result) ->
    %% 网页截断：建议改用 fetchUrlPage 从头分页续读
    case maps:get(url, Result, <<>>) of
        <<>> -> null;
        Url ->
            #{tool => fetchUrlPage,
              suggestedArgs => #{url => Url, cursor => null,
                                 chunkBytes => 24000}}
    end;
paginationHintFor(_Tool, _Result) ->
    null.

truncatedHint(Tool) when Tool =:= getCallers; Tool =:= getCallees;
                     Tool =:= findCallers; Tool =:= findCallees; Tool =:= findRefs ->
    <<"结果仍过大。请用 includeSource=false、limit/offset 分页；"
      "不要重复同参调用，也不要改 path。"/utf8>>;
truncatedHint(readFile) ->
    <<"文件较大已截断。请按 paginationHint.suggestedArgs 续读（传 startLine+endLine），"
      "或改用 moduleSymbols 列出函数、getSymbolSource 读单个函数体。"
      "勿只靠增大 maxBytes 从文件头反复截断。"/utf8>>;
truncatedHint(_) ->
    <<"结果已截断；请缩小 path/limit 或读更小范围。"/utf8>>.

%% 调用方/引用类：优先丢掉 mermaid 与 sourcePreview，保留 MFA 列表。
%% slim：就地瘦身（未重新调工具）；模型可直接用列表，过大时再按 paginationHint 翻页。
slimOversizedToolResult(Tool, Result, Budget)
  when is_map(Result),
       (Tool =:= getCallers orelse Tool =:= getCallees orelse Tool =:= findCallers
        orelse Tool =:= findCallees orelse Tool =:= findRefs) ->
    Slim0 = maps:without([mermaid, markdown], Result),
    Slim1 = case maps:get(edges, Slim0, undefined) of
        Edges when is_list(Edges) ->
            Slim0#{edges => [compactCallEdge(E) || E <- Edges]};
        _ -> Slim0
    end,
    Slim2 = case maps:get(refs, Slim1, undefined) of
        Refs when is_list(Refs) ->
            Slim1#{refs => [compactCallEdge(E) || E <- Refs]};
        _ -> Slim1
    end,
    Meta = buildTruncationMeta(slim, false, Tool, Result),
    Enc = try alJson:encode(maps:merge(Slim2#{truncated => true,
                                              hint => truncatedHint(Tool)}, Meta))
          catch _:_ -> <<>> end,
    case byte_size(Enc) > 0 andalso byte_size(Enc) =< Budget of
        true -> {ok, Enc};
        false ->
            %% 再砍一半条数
            Slim3 = case maps:get(edges, Slim2, undefined) of
                E2 when is_list(E2), E2 =/= [] ->
                    Keep = max(10, length(E2) div 2),
                    Slim2#{edges => lists:sublist(E2, Keep),
                           returned => Keep,
                           truncated => true};
                _ -> Slim2
            end,
            Slim4 = case maps:get(refs, Slim3, undefined) of
                R2 when is_list(R2), R2 =/= [] ->
                    Keep2 = max(10, length(R2) div 2),
                    Slim3#{refs => lists:sublist(R2, Keep2),
                           count => Keep2,
                           truncated => true};
                _ -> Slim3
            end,
            Meta2 = buildTruncationMeta(slim, false, Tool, Slim4),
            Enc2 = try alJson:encode(maps:merge(Slim4#{hint => truncatedHint(Tool)}, Meta2))
                   catch _:_ -> <<>> end,
            case byte_size(Enc2) > 0 andalso byte_size(Enc2) =< Budget of
                true -> {ok, Enc2};
                false -> error
            end
    end;
slimOversizedToolResult(_, _, _) ->
    error.

prepareToolResultForCap(_Tool, Result) ->
    Result.

compactCallEdge(E) when is_map(E) ->
    maps:with([
        from_module, from_function, from_arity,
        to_module, to_function, arity,
        line, file
    ], normalizeEdgeKeys(E));
compactCallEdge(E) ->
    E.

normalizeEdgeKeys(E) when is_map(E) ->
    #{
        from_module => firstDefined([
            maps:get(from_module, E, undefined),
            maps:get(<<"from_module">>, E, undefined),
            maps:get(fromModule, E, undefined)
        ]),
        from_function => firstDefined([
            maps:get(from_function, E, undefined),
            maps:get(<<"from_function">>, E, undefined),
            maps:get(fromFunction, E, undefined)
        ]),
        from_arity => firstDefined([
            maps:get(from_arity, E, undefined),
            maps:get(<<"from_arity">>, E, undefined),
            maps:get(fromArity, E, undefined)
        ]),
        to_module => firstDefined([
            maps:get(to_module, E, undefined),
            maps:get(<<"to_module">>, E, undefined)
        ]),
        to_function => firstDefined([
            maps:get(to_function, E, undefined),
            maps:get(<<"to_function">>, E, undefined),
            maps:get(function, E, undefined)
        ]),
        arity => firstDefined([
            maps:get(arity, E, undefined),
            maps:get(<<"arity">>, E, undefined)
        ]),
        line => firstDefined([
            maps:get(line, E, undefined),
            maps:get(<<"line">>, E, undefined)
        ]),
        file => firstDefined([
            maps:get(file, E, undefined),
            maps:get(<<"file">>, E, undefined)
        ])
    };
normalizeEdgeKeys(E) ->
    E.

%% 读源码类工具给更大预算；调用方/引用列表同样需要大预算（默认不带源码预览）。
toolResultBudget(readFile) -> ?MaxReadToolResultBytes;
toolResultBudget(readFilePage) -> ?MaxReadToolResultBytes;
toolResultBudget(getSymbolSource) -> ?MaxReadToolResultBytes;
toolResultBudget(getSymbol) -> ?MaxReadToolResultBytes;
%% 网页抓取默认 50KB body，32KB 通用预算会硬截断，单独放宽
toolResultBudget(fetchUrl) -> ?MaxReadToolResultBytes;
toolResultBudget(fetchUrlPage) -> ?MaxReadToolResultBytes;
toolResultBudget(webQa) -> ?MaxReadToolResultBytes;
toolResultBudget(callGraph) -> ?MaxCallGraphResultBytes;
toolResultBudget(moduleDeps) -> ?MaxCallGraphResultBytes;
toolResultBudget(getCallers) -> ?MaxCallGraphResultBytes;
toolResultBudget(getCallees) -> ?MaxCallGraphResultBytes;
toolResultBudget(findCallers) -> ?MaxCallGraphResultBytes;
toolResultBudget(findCallees) -> ?MaxCallGraphResultBytes;
toolResultBudget(findRefs) -> ?MaxCallGraphResultBytes;
toolResultBudget(runMfa) -> ?MaxRunMfaResultBytes;
%% commit patch 不截断：与 read 工具同档预算，避免 32KB 通用帽再砍
toolResultBudget(lastCommit) -> ?MaxReadToolResultBytes;
toolResultBudget(commitDiff) -> ?MaxReadToolResultBytes;
toolResultBudget(commitFiles) -> ?MaxReadToolResultBytes;
toolResultBudget(reviewChangeImpact) -> ?MaxReadToolResultBytes;
toolResultBudget(_) -> ?MaxToolResultBytes.

%% callGraph 参数：兼容 atom / binary 键（LLM JSON 多为 binary）。
callGraphFilters(Args) when is_map(Args) ->
    maps:filter(fun(_, V) -> V =/= undefined end, #{
        module => maps:get(module, Args, maps:get(<<"module">>, Args, undefined)),
        function => maps:get(function, Args, maps:get(<<"function">>, Args, undefined)),
        arity => maps:get(arity, Args, maps:get(<<"arity">>, Args, undefined))
    });
callGraphFilters(_) ->
    #{}.

%% alCoreClient 成功响应形如 #{engine => rustCore, data => Payload}；
%% 工具层必须先 unwrap，否则 calls/deps/edges 永远在顶层取不到（0/0 edges）。
unwrapCoreData(Map) when is_map(Map) ->
    alCoreClient:unwrapMap(Map);
unwrapCoreData(_) ->
    #{}.

%% coreCall 成功后剥 data，供 search/moduleSymbols 等工具出口使用。
coreCallUnwrapped(Fun) when is_function(Fun, 0) ->
    alCoreClient:unwrap(coreCall(Fun)).
coreEdges(Map) when is_map(Map) ->
    case maps:get(edges, Map, maps:get(<<"edges">>, Map, undefined)) of
        L when is_list(L) -> L;
        _ ->
            case maps:get(calls, Map, maps:get(<<"calls">>, Map, undefined)) of
                L2 when is_list(L2) -> L2;
                _ -> []
            end
    end;
coreEdges(_) ->
    [].

%% 按模块收集调用边：优先 moduleSymbols.calls（出边）+ 导出函数 getCallers（入边），
%% 避免每次拉取全项目 /call_graph（可达数 MB）。
collectModuleCallEdges(Module) ->
    Variants = moduleNameVariants(Module),
    Outbound = lists:flatmap(fun moduleOutboundCalls/1, Variants),
    Funs = lists:usort(lists:flatmap(fun moduleFunctionFas/1, Variants)),
    Inbound = lists:flatmap(
        fun({F, A}) ->
            lists:flatmap(fun(M) -> moduleCallerEdges(M, F, A) end, Variants)
        end, lists:sublist(Funs, 50)),
    Scoped = dedupeCallEdges(Outbound ++ Inbound),
    case Scoped of
        [_ | _] ->
            {Scoped, moduleScoped};
        [] ->
            case fullGraphEdgesTouching(Module) of
                {ok, Edges} -> {Edges, fullGraph};
                _ -> {[], empty}
            end
    end.

moduleNameVariants(Module) ->
    Bin = case Module of
        B when is_binary(B) -> B;
        A when is_atom(A) -> atom_to_binary(A, utf8);
        L when is_list(L) -> unicode:characters_to_binary(L);
        _ -> to_binary(Module)
    end,
    Low = string:lowercase(Bin),
    lists:usort([Bin, Low, try binary_to_existing_atom(Bin, utf8) catch _:_ -> Bin end]).

moduleOutboundCalls(Module) ->
    case coreCall(fun() -> alCoreClient:moduleSymbols(Module) end) of
        {ok, Wrap} ->
            Data = unwrapCoreData(Wrap),
            Doc = maps:get(document, Data, maps:get(<<"document">>, Data, undefined)),
            case Doc of
                Map when is_map(Map) ->
                    case maps:get(calls, Map, maps:get(<<"calls">>, Map, [])) of
                        L when is_list(L) -> L;
                        _ -> []
                    end;
                _ -> []
            end;
        _ -> []
    end.

moduleFunctionFas(Module) ->
    case coreCall(fun() -> alCoreClient:moduleSymbols(Module) end) of
        {ok, Wrap} ->
            Data = unwrapCoreData(Wrap),
            Doc = maps:get(document, Data, maps:get(<<"document">>, Data, #{})),
            Doc1 = case is_map(Doc) of true -> Doc; false -> #{} end,
            Exports = maps:get(exports, Doc1, maps:get(<<"exports">>, Doc1, [])),
            Funs = maps:get(functions, Doc1, maps:get(<<"functions">>, Doc1, [])),
            faPairs(Exports) ++ faPairs(Funs);
        _ ->
            case alToolsExt:moduleExports(#{module => Module}) of
                {ok, #{exports := Ex}} when is_list(Ex) -> faPairs(Ex);
                {ok, #{data := #{exports := Ex2}}} when is_list(Ex2) -> faPairs(Ex2);
                _ -> []
            end
    end.

faPairs(List) when is_list(List) ->
    lists:filtermap(fun
        (#{name := N, arity := A}) -> {true, {N, A}};
        (#{<<"name">> := N, <<"arity">> := A}) -> {true, {N, A}};
        (#{function := N, arity := A}) -> {true, {N, A}};
        (#{<<"function">> := N, <<"arity">> := A}) -> {true, {N, A}};
        ({N, A}) when is_integer(A) -> {true, {N, A}};
        (_) -> false
    end, List);
faPairs(_) ->
    [].

moduleCallerEdges(Module, Function, Arity) ->
    case coreCall(fun() -> alCoreClient:getCallers(Module, Function, Arity) end) of
        {ok, Wrap} -> coreEdges(unwrapCoreData(Wrap));
        _ -> []
    end.

fullGraphEdgesTouching(Module) ->
    case coreCall(fun() -> alCoreClient:callGraph() end) of
        {ok, Wrap} ->
            Data = unwrapCoreData(Wrap),
            Calls = maps:get(calls, Data, maps:get(<<"calls">>, Data, [])),
            case is_list(Calls) of
                true ->
                    {ok, alDocGen:filterCallEdges(Calls, #{module => Module})};
                false ->
                    {error, badCalls}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

dedupeCallEdges(Edges) when is_list(Edges) ->
    {_, Acc} = lists:foldl(fun(E, {Seen, Out}) ->
        Key = {edgeStrSafe(E, from_module), edgeStrSafe(E, from_function),
               edgeIntSafe(E, from_arity), edgeStrSafe(E, to_module),
               edgeStrSafe(E, to_function), edgeIntSafe(E, arity)},
        case maps:is_key(Key, Seen) of
            true -> {Seen, Out};
            false -> {Seen#{Key => true}, [E | Out]}
        end
    end, {#{}, []}, Edges),
    lists:reverse(Acc);
dedupeCallEdges(_) ->
    [].

edgeStrSafe(E, Key) ->
    BinKey = atom_to_binary(Key, utf8),
    case maps:get(Key, E, maps:get(BinKey, E, undefined)) of
        undefined -> <<>>;
        V -> to_binary(V)
    end.

edgeIntSafe(E, Key) ->
    BinKey = atom_to_binary(Key, utf8),
    case maps:get(Key, E, maps:get(BinKey, E, undefined)) of
        N when is_integer(N) -> N;
        _ -> -1
    end.

%% UTF-8 安全截断：从 Len 字节处向前回退到最近的合法 UTF-8 字符边界。
%% 避免在多字节字符中间切断产生非法 binary（会导致 jiffy 编码失败）。
truncateUtf8(Bin, Len) when is_binary(Bin), Len >= byte_size(Bin) -> Bin;
truncateUtf8(_Bin, Len) when Len =< 0 -> <<>>;
truncateUtf8(Bin, Len) ->
    case unicode:characters_to_binary(binary:part(Bin, 0, Len)) of
        {error, Good, _Rest} -> Good;
        {incomplete, Good, _Rest} -> Good;
        Result when is_binary(Result) -> Result
    end.

%%--------------------------------------------------------------------
%% @doc
%% 截断感知重试：若工具结果超过 cfg.maxToolContentBytes（默认 16KB），
%% 且工具支持 limit 参数（search/searchUnified/searchText/readFile），
%% 把 limit 减半重新调用一次。返回新的 Result，原 Result 中
%% truncated=true 字段会被保留以供调试。
%%
%% 仅在 Result 含有 data 列表或 content 字符串时触发；纯 ok/error
%% 短消息不做重试。
%%
%% @param Tool     工具 atom
%% @param Decoded  工具参数 map
%% @param Result   首次执行结果
%% @param Opts     选项 map
%% @return 重试后或原 Result
%% @end
%%--------------------------------------------------------------------
maybeRetractToolResult(Tool, Decoded, Result, Opts) ->
    Max = maps:get(maxToolContentBytes, Opts, ?DefaultMaxToolContentBytes),
    Size = approxResultBytes(Result),
    %% 调用方工具：即使调用方未传 limit，也注入默认 limit 以便减半重试
    Decoded1 = case Size > Max andalso isCallEdgeTool(Tool)
                   andalso not maps:is_key(limit, Decoded)
                   andalso not maps:is_key(<<"limit">>, Decoded) of
        true -> Decoded#{limit => 80};
        false -> Decoded
    end,
    %% readFile：从文件头截断时，自动改用行区间（startLine=1, endLine=250）重试一次，
    %% 避免模型反复增大 maxBytes 仍从文件头截断。仅当未传 startLine 时触发。
    Decoded1b = case Size > Max andalso Tool =:= readFile
                    andalso not maps:is_key(startLine, Decoded)
                    andalso not maps:is_key(<<"startLine">>, Decoded) of
        true -> Decoded#{startLine => 1, endLine => 250};
        false -> Decoded1
    end,
    case Size > Max andalso (maps:is_key(limit, Decoded1b) orelse
                              maps:is_key(<<"limit">>, Decoded1b) orelse
                              (Tool =:= readFile andalso
                               maps:is_key(startLine, Decoded1b))) of
        true ->
            OldLimit = maps:get(limit, Decoded1b, maps:get(<<"limit">>, Decoded1b, 20)),
            NewLimit = max(1, toPositiveInt(OldLimit, 20) div 2),
            Decoded2 = case {maps:is_key(limit, Decoded1b),
                             maps:is_key(startLine, Decoded1b)} of
                {true, _} -> Decoded1b#{limit => NewLimit};
                {false, true} -> Decoded1b;  %% readFile 行区间重试，不改 limit
                _ -> Decoded1b#{limit => NewLimit}
            end,
            case executeTool(Tool, Decoded2, Opts) of
                {ok, RetriedResult} when is_map(RetriedResult) ->
                    %% soft 截断：已自动减半重试，模型可直接用
                    Meta = buildTruncationMeta(soft, true, Tool, RetriedResult),
                    RetriedMeta = case Tool =:= readFile of
                        true ->
                            maps:merge(Meta, #{originalArgs => Decoded,
                                               retriedArgs => Decoded2});
                        false ->
                            maps:merge(Meta, #{originalLimit => OldLimit,
                                               retriedLimit => NewLimit})
                    end,
                    maps:merge(RetriedResult#{truncated => true}, RetriedMeta);
                _ ->
                    case is_map(Result) of
                        true ->
                            Meta = buildTruncationMeta(hard, false, Tool, Result),
                            maps:merge(Result#{truncated => true,
                                               originalLimit => OldLimit}, Meta);
                        false -> Result
                    end
            end;
        false when Size > Max, is_map(Result) ->
            %% 无法自动重试（无 limit 参数）：标记为 hard 截断
            Meta = buildTruncationMeta(hard, false, Tool, Result),
            maps:merge(Result#{truncated => true}, Meta);
        false ->
            Result
    end.

isCallEdgeTool(getCallers) -> true;
isCallEdgeTool(getCallees) -> true;
isCallEdgeTool(findCallers) -> true;
isCallEdgeTool(findCallees) -> true;
isCallEdgeTool(findRefs) -> true;
isCallEdgeTool(_) -> false.

%%--------------------------------------------------------------------
%% @doc
%% 对 Result 中的 content/data 做字节估算，用于触发截断重试。
%% 字符串 / binary 直接取字节数；map 透传到 content/data。
%%
%% @param Result 工具执行结果
%% @return 估算字节数（非负整数）
%% @end
%%--------------------------------------------------------------------
approxResultBytes(Result) when is_binary(Result) ->
    byte_size(Result);
approxResultBytes(Result) when is_list(Result) ->
    case io_lib:char_list(Result) of
        true -> byte_size(unicode:characters_to_binary(Result));
        false -> lists:foldl(fun(I, Acc) -> Acc + approxResultBytes(I) end, 0, Result)
    end;
approxResultBytes(Result) when is_map(Result) ->
    %% Inner payload may itself be a map (e.g. rust core /search data is
    %% #{query, hits}) — recurse instead of folding, never assume a list.
    %% lists:foldl on a map raises {case_clause, Map} on OTP >= 28.
    case firstPresentValue([content, entries, data, hits, result], Result) of
        undefined ->
            maps:fold(fun(_K, V, Acc) -> Acc + approxResultBytes(V) end, 0, Result);
        Inner ->
            approxResultBytes(Inner)
    end;
approxResultBytes(_) ->
    0.

firstPresentValue([], _Map) ->
    undefined;
firstPresentValue([Key | Rest], Map) ->
    case maps:get(Key, Map, undefined) of
        undefined -> firstPresentValue(Rest, Map);
        Value -> Value
    end.

%% 在结果中追加 truncated: true 标记（用于 LLM 直观感知）。
%% 阈值与 maybeRetractToolResult 对齐，避免标记与重试不一致。
maybeAnnotateTruncated(Result) when is_map(Result) ->
    case maps:get(truncated, Result, false) of
        true -> Result;
        false ->
            case approxResultBytes(Result) of
                N when N > ?DefaultMaxToolContentBytes -> Result#{truncated => true};
                _ -> Result
            end
    end;
maybeAnnotateTruncated(Other) ->
    Other.

%%--------------------------------------------------------------------
%% @doc
%% 执行单个工具的策略检查与调用：处理需要确认的工具（创建 pending
%% task）、被拒绝的工具，以及命中预取缓存或正常调用。
%%
%% @param Tool 工具名 atom
%% @param Decoded 已解码的参数 map
%% @param Opts 选项 map
%% @return 结果 map：`#{status => ok|error|pending, ...}'
%% @end
%%--------------------------------------------------------------------
executeTool(Tool, Decoded, Opts) ->
    Policy = maps:get(policy, Opts, alPolicy:defaultPolicy()),
    Mode = maps:get(mode, Opts, ask),
    PolicyCtx = #{mode => Mode, confirmed => maps:get(confirmed, Opts, false), args => Decoded},
    case alPolicy:checkTool(Tool, Policy, PolicyCtx) of
        {error, confirmationRequired} ->
            TaskId = integer_to_binary(erlang:unique_integer([positive, monotonic])),
            SessionId = maps:get(sessionId, Opts, undefined),
            {ok, _} = alPending:put(TaskId, SessionId, Tool, Decoded, Opts),
            Preview = approvalPreview(Tool, Decoded),
            emitProgress(Opts, #{
                type => approvalRequired,
                status => <<"confirmationRequired">>,
                taskId => TaskId,
                tool => Tool,
                args => alPolicy:sanitizeTerm(Decoded),
                preview => Preview
            }),
            #{status => pending, taskId => TaskId, tool => Tool,
              message => <<"approval required">>, preview => Preview};
        {error, denied} ->
            #{status => error, reason => denied};
        ok ->
            case maybePrefetchedSearch(Tool, Decoded, Opts) of
                {ok, Value} ->
                    #{status => ok, result => Value, cached => true};
                miss ->
                    invokeWithCache(Tool, Decoded, Opts)
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 在工具缓存启用时先查缓存，命中则直接返回；未命中或禁用缓存时
%% 调用 doInvoke 实际执行工具。
%%
%% @param Tool 工具名
%% @param Decoded 参数 map
%% @param Opts 选项 map
%% @return 结果 map，缓存命中时含 `cached => true'
%% @end
%%--------------------------------------------------------------------
invokeWithCache(Tool, Decoded, Opts) ->
    AgentCfg = maps:get(agentCfg, Opts, #{}),
    CacheEnabled = maps:get(toolCacheEnabled, AgentCfg, true),
    case CacheEnabled of
        true ->
            case alToolCache:lookup(Tool, Decoded) of
                {ok, Cached} ->
                    #{status => ok, result => Cached, cached => true};
                miss ->
                    %% runMfa 只读调用：用 in-loop 缓存（?ToolFpCacheKey）做短 TTL 去重，
                    %% 避免模型反复调同一只读 MFA（如 player:get(Id)）重复执行。
                    %% 写 MFA（sideEffect=write）不缓存。
                    case Tool =:= runMfa andalso isRunMfaReadOnly(Decoded) of
                        true ->
                            invokeRunMfaReadOnlyWithCache(Decoded, Opts);
                        false ->
                            doInvoke(Tool, Decoded, Opts, true)
                    end
            end;
        false ->
            doInvoke(Tool, Decoded, Opts, false)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 只读 runMfa 的 in-loop 缓存：用 {runMfaReadOnly, Module, Function, Arguments}
%% 作为 fingerprint，命中则返回缓存结果，未命中则执行后存入。
%% 仅在同一轮 toolLoop 内生效（Step 0 时 ?ToolFpCacheKey 被清空）。
%%
%% @param Decoded 工具参数 map
%% @param Opts    选项 map
%% @return 结果 map，缓存命中时含 `cached => true'
%% @end
%%--------------------------------------------------------------------
invokeRunMfaReadOnlyWithCache(Decoded, Opts) ->
    Fp = runMfaReadOnlyFingerprint(Decoded),
    case get(?ToolFpCacheKey) of
        Cache when is_map(Cache) ->
            case maps:get(Fp, Cache, undefined) of
                #{status := ok, result := _CachedValue} = Prev ->
                    Prev#{cached => true,
                          hint => <<"只读 runMfa 结果已缓存；勿重复调用。请直接作答。"/utf8>>};
                _ ->
                    execAndCacheRunMfaReadOnly(Fp, Decoded, Opts, true)
            end;
        _ ->
            execAndCacheRunMfaReadOnly(Fp, Decoded, Opts, true)
    end.

execAndCacheRunMfaReadOnly(Fp, Decoded, Opts, StoreCache) ->
    Result = doInvoke(runMfa, Decoded, Opts, StoreCache),
    case Result of
        #{status := ok} = OkResult ->
            Cache0 = case get(?ToolFpCacheKey) of
                C when is_map(C) -> C;
                _ -> #{}
            end,
            Cache1 = case maps:size(Cache0) >= 32 of
                true -> maps:from_list(lists:sublist(maps:to_list(Cache0), 24));
                false -> Cache0
            end,
            put(?ToolFpCacheKey, Cache1#{Fp => OkResult});
        _ ->
            ok
    end,
    Result.

%% 判断 runMfa 是否为只读：alPolicy:isRunMfaWrite/1 返回 false 即只读。
isRunMfaReadOnly(Args) ->
    not alPolicy:isRunMfaWrite(Args).

%% 只读 runMfa 指纹：{runMfaReadOnly, Module, Function, Arguments}
runMfaReadOnlyFingerprint(Args) ->
    Module = maps:get(module, Args, maps:get(<<"module">>, Args, undefined)),
    Function = maps:get(function, Args, maps:get(<<"function">>, Args, undefined)),
    Arguments = maps:get(args, Args, maps:get(<<"args">>, Args, undefined)),
    {runMfaReadOnly, Module, Function, Arguments}.

%%--------------------------------------------------------------------
%% @doc
%% 实际调用工具并记录审计日志、度量与进度事件；成功时按需写缓存，
%% 写类工具会触发缓存失效。
%%
%% @param Tool 工具名
%% @param Decoded 参数 map
%% @param Opts 选项 map
%% @param StoreCache 是否将结果写入缓存
%% @return 结果 map（`#{status => ok|error, ...}'）
%% @end
%%--------------------------------------------------------------------
doInvoke(Tool, Decoded, Opts, StoreCache) ->
    Started = erlang:monotonic_time(millisecond),
    emitProgress(Opts, #{
        type => toolStarted,
        tool => Tool,
        args => alPolicy:sanitizeTerm(Decoded),
        taskId => maps:get(taskId, Opts, maps:get(progressId, Opts, undefined))
    }),
    Result = callTool(Tool, Decoded, Opts),
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    AuditResult = capPersistResult(Result),
    alAudit:log(#{
        session => maps:get(sessionId, Opts, undefined),
        tool => Tool,
        ok => isOk(Result),
        ms => Elapsed,
        args => Decoded,
        result => AuditResult
    }),
    alMetrics:recordTool(#{
        tool => Tool,
        status => case Result of {ok, _} -> ok; _ -> error end,
        durationMs => Elapsed
    }),
    case Result of
        {ok, Value} ->
            StoreValue = capPersistValue(Value),
            case StoreCache of
                true -> alToolCache:store(Tool, Decoded, StoreValue);
                false -> ok
            end,
            case isWriteTool(Tool) of
                true -> alToolCache:invalidateForWrite(writeResultPaths(Result));
                false -> ok
            end,
            emitProgress(Opts, #{
                type => toolFinished,
                tool => Tool,
                ok => true,
                elapsedMs => Elapsed,
                result => progressResultPreview(Tool, StoreValue),
                taskId => maps:get(taskId, Opts, maps:get(progressId, Opts, undefined))
            }),
            #{status => ok, result => StoreValue};
        {error, Reason} ->
            emitProgress(Opts, #{
                type => toolFinished,
                tool => Tool,
                ok => false,
                error => Reason,
                elapsedMs => Elapsed,
                taskId => maps:get(taskId, Opts, maps:get(progressId, Opts, undefined))
            }),
            #{status => error, reason => Reason}
    end.

%% Cap oversized tool payloads before audit/cache so listFiles etc. cannot
%% blow memory or produce multi-MB JSONL lines.
capPersistResult({ok, Value}) -> {ok, capPersistValue(Value)};
capPersistResult(Other) -> Other.

%% Progress 帧里的结果预览：图/文档工具带上 mermaid / markdown 摘要，供前端渲染。
progressResultPreview(Tool, Value) when is_map(Value) ->
    case Tool of
        T when T =:= callGraph; T =:= moduleDeps; T =:= generateModuleDoc;
               T =:= getCallers; T =:= getCallees; T =:= findCallers; T =:= findCallees;
               T =:= traceDataFlow; T =:= batchRefactor ->
            maps:with([mermaid, markdown, edgeCount, mermaidEdgeCount, module,
                       deps, truncated, functions, files, fileCount, summary,
                       warnings, written, writePath, totalEdgeCount, filtered,
                       source, depCount, sampleEdges],
                      maybeEnrichCalleeMermaid(Tool, Value));
        _ ->
            %% 搜索类：保留可渲染的短列表
            case maps:get(data, Value, maps:get(hits, Value, maps:get(results, Value, undefined))) of
                List when is_list(List) ->
                    #{data => lists:sublist(List, 8)};
                _ ->
                    #{}
            end
    end;
progressResultPreview(_, _) ->
    #{}.

maybeEnrichCalleeMermaid(Tool, Value) when Tool =:= getCallers; Tool =:= getCallees;
                                           Tool =:= findCallers; Tool =:= findCallees ->
    case maps:is_key(mermaid, Value) of
        true -> Value;
        false ->
            Edges = maps:get(edges, Value, maps:get(<<"edges">>, Value, [])),
            case is_list(Edges) andalso Edges =/= [] of
                true -> Value#{mermaid => alDocGen:mermaidCallEdges(Edges, 40)};
                false -> Value
            end
    end;
maybeEnrichCalleeMermaid(_, Value) ->
    Value.

capPersistValue(Value) when is_map(Value) ->
    case maps:get(entries, Value, undefined) of
        Entries when is_list(Entries), length(Entries) > 200 ->
            Value#{
                entries => lists:sublist(Entries, 200),
                truncated => true,
                originalCount => length(Entries)
            };
        _ ->
            case approxResultBytes(Value) > ?MaxToolResultBytes of
                true ->
                    Enc = try alJson:encode(Value) catch _:_ -> <<>> end,
                    #{
                        status => truncated,
                        truncated => true,
                        originalBytes => byte_size(Enc),
                        preview => truncateUtf8(Enc, min(byte_size(Enc), 512))
                    };
                false ->
                    Value
            end
    end;
capPersistValue(Value) ->
    Value.

%% 判断工具是否属于写类工具（会触发缓存失效）。
isWriteTool(applyPatch) -> true;
isWriteTool(applyPatchBatch) -> true;
isWriteTool(writeFile) -> true;
isWriteTool(rollbackPatch) -> true;
isWriteTool(_) -> false.

%% 判断调用结果是否为成功（{ok, _}）。
isOk({ok, _}) -> true;
isOk(_) -> false.

%%--------------------------------------------------------------------
%% @doc
%% 为特定工具注入运行时上下文：remember 工具在缺少 sessionId 时
%% 自动从 Opts 注入，其他工具原样返回参数。
%%
%% @param Tool 工具名
%% @param Args 参数 map
%% @param Opts 选项 map
%% @return 注入后的参数 map
%% @end
%%--------------------------------------------------------------------
injectToolContext(remember, Args, Opts) ->
    case maps:is_key(sessionId, Args) of
        true -> Args;
        false ->
            case maps:get(sessionId, Opts, undefined) of
                undefined -> Args;
                SessionId -> Args#{sessionId => SessionId}
            end
    end;
injectToolContext(_Tool, Args, _Opts) ->
    Args.

%%--------------------------------------------------------------------
%% @doc
%% 检查当前 searchCode 调用是否可命中预取搜索结果：当查询与预取
%% 查询一致、无过滤条件且 limit 在预取上限内时直接返回缓存的 hits。
%%
%% @param Tool 工具名
%% @param Args 参数 map
%% @param Opts 选项 map（含 prefetchSearch/prefetchLimit）
%% @return `{ok, Value}' 或 `miss'
%% @end
%%--------------------------------------------------------------------
maybePrefetchedSearch(searchCode, Args, Opts) ->
    case maps:get(prefetchSearch, Opts, undefined) of
        #{query := PrefetchQuery, hits := Hits} ->
            Query = maps:get(query, Args, <<>>),
            Limit = maps:get(limit, Args, 10),
            Filters = maps:without([query, limit], Args),
            PrefLimit = maps:get(prefetchLimit, Opts, 6),
            case normalizeSearchQuery(Query) =:= PrefetchQuery
                andalso map_size(Filters) =:= 0
                andalso Limit =< PrefLimit of
                true ->
                    {ok, #{hits => lists:sublist(Hits, Limit), engine => contextCache}};
                false ->
                    miss
            end;
        _ ->
            miss
    end;
maybePrefetchedSearch(_Tool, _Args, _Opts) ->
    miss.

%% 将查询字符串归一化为小写去空白列表，用于预取比对。
normalizeSearchQuery(Query) when is_binary(Query) ->
    string:trim(string:lowercase(unicode:characters_to_list(Query)));
normalizeSearchQuery(Query) when is_list(Query) ->
    normalizeSearchQuery(list_to_binary(Query));
normalizeSearchQuery(Query) when is_atom(Query) ->
    normalizeSearchQuery(atom_to_binary(Query, utf8));
normalizeSearchQuery(_) ->
    "".

%% 将任意输入归一化为 binary（用于长度比较等场景）。
toBinary(Term) when is_binary(Term) -> Term;
toBinary(Term) when is_list(Term) ->
    try list_to_binary(Term)
    catch _:_ -> unicode:characters_to_binary(Term)
    end;
toBinary(Term) when is_atom(Term) -> atom_to_binary(Term, utf8);
toBinary(_) -> <<>>.

%%--------------------------------------------------------------------
%% searchCode / searchUnified 的模式归一化：
%%   bm25 | keyword → bm25
%%   vector | semantic → vector
%%   regex → regex（走 alSearch 的 rg 后端）
%%   hybrid → hybrid（Erlang 侧合并 bm25 + vector + regex）
%%--------------------------------------------------------------------
normalizeSearchMode(bm25) -> bm25;
normalizeSearchMode(keyword) -> bm25;
normalizeSearchMode(vector) -> vector;
normalizeSearchMode(semantic) -> vector;
normalizeSearchMode(regex) -> regex;
normalizeSearchMode(hybrid) -> hybrid;
normalizeSearchMode(<<"bm25">>) -> bm25;
normalizeSearchMode(<<"keyword">>) -> bm25;
normalizeSearchMode(<<"vector">>) -> vector;
normalizeSearchMode(<<"semantic">>) -> vector;
normalizeSearchMode(<<"regex">>) -> regex;
normalizeSearchMode(<<"hybrid">>) -> hybrid;
normalizeSearchMode(undefined) -> bm25;
normalizeSearchMode(_) -> bm25.

%%--------------------------------------------------------------------
%% 从 Args 解析 VCS 过滤条件：
%%   undefined — 未启用过滤
%%   []        — 已启用但交集为空（搜索应返回 0 命中）
%%   [Path…]   — 仅在这些文件内搜
%%--------------------------------------------------------------------
resolveVcsPaths(Args) ->
    Since = maps:get(modifiedSince, Args, maps:get(<<"modifiedSince">>, Args, undefined)),
    Author = maps:get(author, Args, maps:get(<<"author">>, Args, undefined)),
    VcsStatus = maps:get(vcsStatus, Args, maps:get(<<"vcsStatus">>, Args, undefined)),
    case Since =:= undefined andalso Author =:= undefined andalso VcsStatus =:= undefined of
        true ->
            undefined;
        false ->
            Opts = #{modifiedSince => Since, author => Author, vcsStatus => VcsStatus},
            case alVcsIndex:vcsFileFilter(Opts) of
                #{files := Fs} when is_list(Fs) -> Fs;
                _ -> []
            end
    end.

%%--------------------------------------------------------------------
%% 构造传给 core 的 Filters：剥离 search 自有字段与 VCS 字段。
%% 注意：aliCore SearchFilter 仅支持 module/function/arity，不认 paths；
%% 路径过滤一律在 Erlang 侧 {@link filterByPaths/2} 完成。
%%--------------------------------------------------------------------
buildSearchFilters(Args, _VcsPaths) ->
    Strip = [query, limit, mode, modifiedSince, author, vcsStatus, paths,
             context, includeSource,
             <<"query">>, <<"limit">>, <<"mode">>,
             <<"modifiedSince">>, <<"author">>, <<"vcsStatus">>, <<"paths">>,
             <<"context">>, <<"includeSource">>],
    maps:without(Strip, Args).

%%--------------------------------------------------------------------
%% 正则搜索：走 alSearch 的 rg 后端（rg 原生支持正则）。
%% VcsPaths=undefined 不过滤；=[] 返回空；非空按文件列表过滤。
%%--------------------------------------------------------------------
runRegexSearch(Query, VcsPaths, Limit) ->
    case VcsPaths of
        [] ->
            {ok, #{hits => [], engine => regex, matchCount => 0,
                   backend => alSearch:backend(), vcsFilter => empty}};
        _ ->
            Root = unicode:characters_to_binary(alConfig:projectRoot()),
            Fetch = case VcsPaths of
                undefined -> max(toPositiveInt(Limit, 10), 10);
                _ -> max(toPositiveInt(Limit, 10) * 5, 50)
            end,
            case alSearch:search(Root, <<>>, Query, Fetch) of
                {ok, Matches} ->
                    Filtered = filterByPaths(Matches, VcsPaths),
                    {ok, #{hits => lists:sublist(Filtered, toPositiveInt(Limit, 10)),
                           engine => regex,
                           matchCount => length(Filtered),
                           backend => alSearch:backend()}};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

%%--------------------------------------------------------------------
%% 组合查询：bm25 + vector + regex，合并去重后按 VCS 路径过滤。
%%--------------------------------------------------------------------
runHybridSearch(Query, CoreFilters, VcsPaths, Limit) ->
    case VcsPaths of
        [] ->
            {ok, #{hits => [], engine => hybrid, matchCount => 0,
                   counts => #{bm25 => 0, vector => 0, regex => 0},
                   vcsFilter => empty}};
        _ ->
            Lim = toPositiveInt(Limit, 10),
            Fetch = case VcsPaths of
                undefined -> Lim;
                _ -> max(Lim * 5, 50)
            end,
            Root = unicode:characters_to_binary(alConfig:projectRoot()),
            Bm25 = filterByPaths(
                fetchCoreHits(Query, Fetch, CoreFilters#{mode => bm25}), VcsPaths),
            Vector = filterByPaths(
                fetchCoreHits(Query, Fetch, CoreFilters#{mode => vector}), VcsPaths),
            Regex = case alSearch:search(Root, <<>>, Query, max(Fetch, 30)) of
                {ok, Ms} -> filterByPaths(Ms, VcsPaths);
                _ -> []
            end,
            Merged = dedupHits(Bm25 ++ Vector ++ Regex),
            {ok, #{hits => lists:sublist(Merged, Lim), engine => hybrid,
                   matchCount => length(Merged),
                   counts => #{bm25 => length(Bm25), vector => length(Vector),
                               regex => length(Regex)}}}
    end.

%% 安全调用 core 搜索并提取 hits 列表；任意异常返回 []。
fetchCoreHits(Query, Limit, Filters) ->
    try alCoreClient:unwrap(alCoreClient:search(Query, Limit, Filters)) of
        {ok, #{hits := Hs}} when is_list(Hs) -> Hs;
        {ok, Hs} when is_list(Hs) -> Hs;
        _ -> []
    catch _:_ -> [] end.

%% 按 VcsPaths 过滤搜索结果：
%%   undefined → 不过滤
%%   []        → 空结果（VCS 条件无匹配文件）
%%   非空列表  → 仅保留命中文件
filterByPaths(Matches, undefined) -> Matches;
filterByPaths(_Matches, []) -> [];
filterByPaths(Matches, Paths) when is_list(Paths) ->
    NormSet = sets:from_list([normSearchPath(P) || P <- Paths], [{version, 2}]),
    [M || M <- Matches,
          sets:is_element(
              normSearchPath(toBinary(maps:get(file, M, maps:get(<<"file">>, M, <<>>)))),
              NormSet)];
filterByPaths(Matches, _) -> Matches.

%% 按 {file, line} 去重，保留首次出现的 hit 原结构。
dedupHits(Hits) ->
    {Dedup, _Seen} = lists:foldl(
        fun(H, {Acc, Seen}) ->
            Key = hitKey(H),
            case sets:is_element(Key, Seen) of
                true -> {Acc, Seen};
                false -> {[H | Acc], sets:add_element(Key, Seen)}
            end
        end, {[], sets:new([{version, 2}])}, Hits),
    lists:reverse(Dedup).

hitKey(H) ->
    File = normSearchPath(toBinary(maps:get(file, H, maps:get(<<"file">>, H, <<>>)))),
    Line = searchToInt(maps:get(line, H, maps:get(<<"line">>, H, 0)), 0),
    {File, Line}.

%% 路径归一化用于比对：反斜杠转正斜杠，去空白，小写。
normSearchPath(P) ->
    B = toBinary(P),
    Norm = re:replace(B, <<"\\\\">>, <<"/">>, [global, {return, binary}]),
    string:lowercase(string:trim(Norm)).

%% 整数归一化（本地版，避免与别的模块同名冲突）。
searchToInt(N, _Default) when is_integer(N) -> N;
searchToInt(B, Default) when is_binary(B) ->
    try binary_to_integer(B) catch _:_ -> Default end;
searchToInt(L, Default) when is_list(L) ->
    try list_to_integer(L) catch _:_ -> Default end;
searchToInt(_, Default) -> Default.

%%--------------------------------------------------------------------
%% @doc
%% 根据当前模式与 allowlist 过滤后，返回给 LLM 的工具定义列表。
%%
%% @param Opts 选项 map（含 mode / toolsAllowlist）
%% @return 工具定义 map 列表
%% @end
%%--------------------------------------------------------------------
toolDefinitions(Opts) ->
    Mode = maps:get(mode, Opts, ask),
    Allow = maps:get(toolsAllowlist, Opts, all),
    Defs0 = [Def || Def <- alToolCatalog:definitionsForMode(Mode),
            modeAllowsTool(Def, Mode),
            allowlistAllows(Def, Allow)],
    %% 运行时工具具有很强的“行动诱惑”：普通代码/知识问答也可能被模型误选，
    %% 随后整个流程被实时快照带偏。只有统一分类器确认是运行时观测问题时
    %% 才下发这些定义；callTool API 本身不受影响。
    Defs = filterRuntimeToolDefinitions(Defs0,
        maps:get(currentQuestion, Opts, <<>>)),
    sortToolsByPreferred(Defs, maps:get(preferredTools, Opts, [])).

filterRuntimeToolDefinitions(Defs, Question) ->
    case isRuntimeQuestion(Question) of
        true -> Defs;
        false ->
            RuntimeOnly = [getRuntime, supervisorTree, getProcesses, processInfo,
                           getOldCodeProcesses, etsLookup, getEts, appTopology],
            [D || D <- Defs,
                  not lists:member(toolDefAtom(D), RuntimeOnly)]
    end.

preferredToolsForQuestion(Question, Opts) ->
    Learn = try alToolLearn:suggestTools(Question, 5) catch _:_ -> [] end,
    LearnAtoms = [toolNameToAtom(T) || T <- Learn],
    AgentCfg = maps:get(agentCfg, Opts, alConfig:getAgentCfg()),
    Resolved = alPersona:resolve(Question, Opts#{agentCfg => AgentCfg}),
    PersonaTools = alPersona:recommendedTools(Resolved),
    dedupeToolNames(PersonaTools ++ LearnAtoms).

dedupeToolNames(Names) ->
    dedupeToolNames(Names, []).

dedupeToolNames([], Acc) ->
    lists:reverse(Acc);
dedupeToolNames([T | Rest], Acc) ->
    Key = toolNameToAtom(T),
    case lists:any(fun(X) -> toolNameToAtom(X) =:= Key end, Acc) of
        true -> dedupeToolNames(Rest, Acc);
        false -> dedupeToolNames(Rest, [Key | Acc])
    end.

toolNameToAtom(T) when is_atom(T) -> T;
toolNameToAtom(T) when is_binary(T) ->
    try binary_to_existing_atom(T, utf8) catch _:_ -> T end;
toolNameToAtom(T) -> T.

sortToolsByPreferred(Defs, []) ->
    Defs;
sortToolsByPreferred(Defs, Preferred) ->
    PrefKeys = [toolNameToAtom(T) || T <- Preferred],
    {Front, Rest} = lists:partition(
        fun(D) -> lists:member(toolDefAtom(D), PrefKeys) end, Defs),
    SortedFront = lists:sort(fun(A, B) ->
        toolPrefRank(toolDefAtom(A), PrefKeys)
            =< toolPrefRank(toolDefAtom(B), PrefKeys)
    end, Front),
    SortedFront ++ Rest.

toolDefAtom(#{function := #{name := NameBin}}) ->
    toolNameToAtom(NameBin);
toolDefAtom(#{name := Name}) ->
    toolNameToAtom(Name);
toolDefAtom(_) ->
    undefined.

toolPrefRank(Name, PrefKeys) ->
    toolPrefRank(PrefKeys, toolNameToAtom(Name), 0).

toolPrefRank([], _Name, _I) ->
    999;
toolPrefRank([K | Rest], Name, I) ->
    case toolNameToAtom(K) =:= Name of
        true -> I;
        false -> toolPrefRank(Rest, Name, I + 1)
    end.

%% 判断工具是否在 allowlist 中（all 表示全部允许）。
allowlistAllows(_, all) ->
    true;
allowlistAllows(#{function := #{name := NameBin}}, Allow) when is_list(Allow) ->
    Tool = try binary_to_existing_atom(NameBin, utf8) catch _:_ -> NameBin end,
    lists:member(Tool, Allow) orelse lists:member(NameBin, Allow).

%% 返回全部工具定义（无过滤），对外公开入口。
toolDefinitions() ->
    alLlmTools:definitions().

%% 判断工具在给定模式下是否被允许（基于策略 level 与 modeAllows）。
modeAllowsTool(#{function := #{name := NameBin}}, Mode) ->
    case binary:match(NameBin, <<":">>) of
        {_, _} ->
            %% 外部 MCP：ask 仅当 requireConfirmationRisky 关闭时直接跑；
            %% 统一按 executeRisky，走确认策略。
            alPolicy:modeAllows(Mode, executeRisky);
        nomatch ->
            Tool = try binary_to_existing_atom(NameBin, utf8) catch _:_ -> NameBin end,
            Level = alPolicy:level(Tool),
            alPolicy:modeAllows(Mode, Level)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 调用工具的便捷入口（无选项）。
%%
%% @param Tool 工具名
%% @param Args 参数 map
%% @return `{ok, Value}' 或 `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
callTool(Tool, Args) ->
    callTool(Tool, Args, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 调用工具的核心入口：先校验工具是否已知，若 Opts 中开启
%% enforcePolicy 则进行策略检查，最后通过 safeDispatch 派发。
%%
%% @param Tool 工具名
%% @param Args 参数 map
%% @param Opts 选项 map
%% @return `{ok, Value}' 或 `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
callTool(Tool, Args, Opts) ->
    case splitExternalMcpTool(Tool) of
        {ok, Conn, ToolName} ->
            case alMcpClient:isDynamicTool(mcpToolKey(Conn, ToolName)) of
                true -> alMcpClient:callTool(Conn, ToolName, Args);
                false -> {error, {unknownTool, Tool}}
            end;
        error ->
            case isKnownTool(Tool) of
                false ->
                    {error, {unknownTool, Tool}};
                true ->
                    case maps:get(enforcePolicy, Opts, false) of
                        true ->
                            Policy = maps:get(policy, Opts, alPolicy:defaultPolicy()),
                            Mode = maps:get(mode, Opts, ask),
                            PolicyCtx = #{mode => Mode, confirmed => maps:get(confirmed, Opts, false), args => Args},
                            case alPolicy:checkTool(Tool, Policy, PolicyCtx) of
                                ok ->
                                    safeDispatch(Tool, Args, Opts);
                                {error, _} = Denied ->
                                    Denied
                            end;
                        false ->
                            safeDispatch(Tool, Args, Opts)
                    end
            end
    end.

%% `"conn:tool"` → 外部 MCP；否则非动态工具。
splitExternalMcpTool(Tool) when is_binary(Tool) ->
    case binary:split(Tool, <<":">>) of
        [ConnBin, ToolName] when ConnBin =/= <<>>, ToolName =/= <<>> ->
            Conn = try binary_to_existing_atom(ConnBin, utf8) catch _:_ -> ConnBin end,
            {ok, Conn, ToolName};
        _ ->
            error
    end;
splitExternalMcpTool(Tool) when is_atom(Tool) ->
    splitExternalMcpTool(atom_to_binary(Tool, utf8));
splitExternalMcpTool(_) ->
    error.

mcpToolKey(Conn, ToolName) when is_atom(Conn), is_binary(ToolName) ->
    <<(atom_to_binary(Conn, utf8))/binary, ":", ToolName/binary>>;
mcpToolKey(Conn, ToolName) when is_binary(Conn), is_binary(ToolName) ->
    <<Conn/binary, ":", ToolName/binary>>;
mcpToolKey(Conn, ToolName) ->
    iolist_to_binary([io_lib:format("~s", [Conn]), $:, ToolName]).

%% 判断工具是否在 builtinIndex 中已知（atom/binary 均可）；含外部 MCP 动态名。
isKnownTool(Tool) when is_atom(Tool) ->
    maps:is_key(Tool, alToolCatalog:builtinIndex()) orelse alMcpClient:isDynamicTool(Tool);
isKnownTool(Tool) when is_binary(Tool) ->
    case alMcpClient:isDynamicTool(Tool) of
        true -> true;
        false ->
            case try binary_to_existing_atom(Tool, utf8) catch _:_ -> error end of
                error -> false;
                Atom -> maps:is_key(Atom, alToolCatalog:builtinIndex())
            end
    end;
isKnownTool(_) ->
    false.

%%--------------------------------------------------------------------
%% @doc
%% 在 try/catch 中派发工具调用，捕获异常并转为 `{error, #{...}}'。
%%
%% @param Tool 工具名
%% @param Args 参数 map
%% @param Opts 选项 map
%% @return 工具结果或 `{error, #{class, reason, stack}}'
%% @end
%%--------------------------------------------------------------------
safeDispatch(Tool, Args, Opts) ->
    try dispatchTool(Tool, Args, Opts) of
        Result -> Result
    catch
        Class:Reason:Stack ->
            {error, #{class => Class, reason => Reason, stack => lists:sublist(Stack, 5)}}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 工具实际派发函数：按工具名分派到具体后端实现（alCoreClient /
%% alToolsExt / alRuntimeProbe / alMemory 等）。
%% 未知工具返回 `{error, {unknownTool, Tool}}'。
%%
%% @param Tool 工具名 atom
%% @param Args 参数 map
%% @param Opts 选项 map
%% @return `{ok, Value}' 或 `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
dispatchTool(indexCode, Args, _Opts) when is_map(Args) ->
    Path = maps:get(path, Args, maps:get(<<"path">>, Args, undefined)),
    Force = maps:get(force_reparse, Args, maps:get(<<"force_reparse">>, Args, false)),
    IndexOpts = case Force of
        true -> #{force_reparse => true};
        <<"true">> -> #{force_reparse => true};
        _ -> #{}
    end,
    case alCoreClient:index(Path, IndexOpts) of
        {ok, _} = Ok ->
            _ = alAsync:run(reconcileAfterIndex, fun() ->
                Recent = try alVcsIndex:recentFiles() catch _:_ -> [] end,
                Paths = case is_list(Recent) of
                    true -> Recent;
                    false ->
                        try ordsets:to_list(Recent) catch _:_ -> [] end
                end,
                alExperience:reconcileAfterCodeChange(#{
                    changed => Paths,
                    deleted => []
                })
            end),
            _ = alProjectDigest:maybeBuildAfterIndex(),
            Ok;
        Other ->
            Other
    end;
dispatchTool(projectDigest, Args, _Opts) when is_map(Args) ->
    Opts = maps:with([maxModules, maxSummaryWarm, warmLlm,
                      updateAgentHints, pruneStaleActions], Args),
    alProjectDigest:build(Opts);
dispatchTool(searchKnowledge, Args, _Opts) ->
    Query = maps:get(query, Args, maps:get(<<"query">>, Args, <<>>)),
    Limit = maps:get(limit, Args, maps:get(<<"limit">>, Args, 8)),
    alProjectDigest:search(Query, toPositiveInt(Limit, 8));
dispatchTool(saveKnowledge, Args, _Opts) when is_map(Args) ->
    alProjectDigest:saveKnowledge(Args);
dispatchTool(saveAction, Args, _Opts) when is_map(Args) ->
    alProjectDigest:saveAction(Args);
dispatchTool(lookupAction, Args, _Opts) ->
    Phrase = maps:get(phrase, Args, maps:get(<<"phrase">>, Args, <<>>)),
    alProjectDigest:lookupAction(Phrase);
dispatchTool(digestStatus, _Args, _Opts) ->
    {ok, alProjectDigest:status()};
dispatchTool(searchCode, Args, _Opts) ->
    Query = maps:get(query, Args, maps:get(<<"query">>, Args, <<>>)),
    Limit0 = maps:get(limit, Args, maps:get(<<"limit">>, Args, 10)),
    Limit = toPositiveInt(Limit0, 10),
    Mode = normalizeSearchMode(maps:get(mode, Args, maps:get(<<"mode">>, Args, bm25))),
    EnrichOpts = snippetEnrichOpts(Args),
    VcsPaths = resolveVcsPaths(Args),
    %% aliCore 不认 paths；路径过滤在 Erlang 侧完成。
    CoreFilters = buildSearchFilters(Args, VcsPaths),
    case VcsPaths of
        [] ->
            {ok, #{hits => [], matchCount => 0, mode => Mode, vcsFilter => empty}};
        _ ->
            case Mode of
                regex ->
                    case runRegexSearch(Query, VcsPaths, Limit) of
                        {ok, #{hits := Hits} = M} when is_list(Hits) ->
                            {ok, M#{hits => alToolsExt:enrichSearchHits(Hits, EnrichOpts)}};
                        Other ->
                            Other
                    end;
                hybrid ->
                    case runHybridSearch(Query, CoreFilters, VcsPaths, Limit) of
                        {ok, #{hits := Hits} = M} when is_list(Hits) ->
                            {ok, M#{hits => alToolsExt:enrichSearchHits(Hits, EnrichOpts)}};
                        Other ->
                            Other
                    end;
                _ ->
                    Fetch = case VcsPaths of
                        undefined -> Limit;
                        _ -> max(Limit * 5, 50)
                    end,
                    case alCoreClient:unwrap(alCoreClient:search(Query, Fetch, CoreFilters)) of
                        {ok, #{hits := Hits} = M} when is_list(Hits) ->
                            Filtered = filterByPaths(Hits, VcsPaths),
                            OutHits = lists:sublist(Filtered, Limit),
                            {ok, M#{hits => alToolsExt:enrichSearchHits(OutHits, EnrichOpts),
                                    matchCount => length(OutHits)}};
                        {ok, Hits} when is_list(Hits) ->
                            Filtered = filterByPaths(Hits, VcsPaths),
                            OutHits = lists:sublist(Filtered, Limit),
                            {ok, #{hits => alToolsExt:enrichSearchHits(OutHits, EnrichOpts),
                                   matchCount => length(OutHits)}};
                        Other ->
                            Other
                    end
            end
    end;
dispatchTool(semanticSearch, Args, Opts) ->
    dispatchTool(searchCode, maps:merge(#{mode => vector}, Args), Opts);
dispatchTool(coreHealth, _Args, _Opts) ->
    alCoreClient:health();
dispatchTool(coreStatus, _Args, _Opts) ->
    {ok, alCoreClient:status()};
dispatchTool(getSymbol, Args, _Opts) ->
    Module = maps:get(module, Args, undefined),
    case {maps:get(function, Args, undefined), maps:get(arity, Args, undefined)} of
        {undefined, _} -> {error, #{reason => missingFunction}};
        {_, undefined} -> {error, #{reason => missingArity}};
        {Function, Arity} ->
            case coreCallUnwrapped(fun() -> alCoreClient:getSymbol(Module, Function, Arity) end) of
                {ok, Result} ->
                    {ok, alToolsExt:enrichLocMap(Result, snippetEnrichOpts(Args))};
                {error, _} -> alToolsExt:getSymbolSource(Args)
            end
    end;
dispatchTool(moduleSymbols, Args, _Opts) ->
    case maps:get(module, Args, undefined) of
        undefined -> {error, #{reason => missingModule}};
        Module ->
            case coreCallUnwrapped(fun() -> alCoreClient:moduleSymbols(Module) end) of
                {ok, Result} ->
                    EnrichOpts = snippetEnrichOpts(Args),
                    Enriched = enrichModuleSymbolsSources(Result, EnrichOpts),
                    {ok, relativizeModuleSymbols(Enriched)};
                {error, _} ->
                    case alToolsExt:moduleExports(#{module => Module}) of
                        {ok, Exports} ->
                            {ok, maps:merge(Exports, #{fallback => beamExports})};
                        Other ->
                            Other
                    end
            end
    end;

dispatchTool(resolveModule, Args, _Opts) ->
    case maps:get(module, Args, undefined) of
        undefined -> {error, #{reason => missingModule}};
        Module ->
            resolveModulePath(Module)
    end;
dispatchTool(gotoDef, Args, _Opts) ->
    Module = maps:get(module, Args, undefined),
    case {maps:get(function, Args, undefined), maps:get(arity, Args, undefined)} of
        {undefined, _} -> {error, #{reason => missingFunction}};
        {_, undefined} -> {error, #{reason => missingArity}};
        {Function, Arity} ->
            gotoDefinition(Module, Function, Arity, Args)
    end;
dispatchTool(findRefs, Args, _Opts) ->
    Module = maps:get(module, Args, undefined),
    case {maps:get(function, Args, undefined), maps:get(arity, Args, undefined)} of
        {undefined, _} -> {error, #{reason => missingFunction}};
        {_, undefined} -> {error, #{reason => missingArity}};
        {Function, Arity} ->
            findReferences(Module, Function, Arity, Args)
    end;
dispatchTool(callGraph, Args, _Opts) ->
    MaxEdges = case maps:get(maxEdges, Args, maps:get(<<"maxEdges">>, Args, 60)) of
        N when is_integer(N), N > 0 -> min(N, 120);
        _ -> 60
    end,
    %% LLM JSON 参数键多为 binary；maps:with([module,...]) 会得到空 map。
    Filters = callGraphFilters(Args),
    case maps:get(module, Filters, undefined) of
        undefined ->
            {error, #{
                reason => moduleFilterRequired,
                hint => <<"请传 module（如 {\"module\":\"alAgent\",\"maxEdges\":40}）。"
                          "全项目调用图过大。"/utf8>>
            }};
        Module ->
            {Edges0, Source} = collectModuleCallEdges(Module),
            Edges1 = alDocGen:filterCallEdges(Edges0, Filters),
            %% function/arity 过窄导致 0 边时回退到仅 module 过滤
            Edges = case Edges1 =:= [] andalso
                        (maps:is_key(function, Filters) orelse maps:is_key(arity, Filters)) of
                true -> alDocGen:filterCallEdges(Edges0, #{module => Module});
                false -> Edges1
            end,
            Mermaid = alDocGen:mermaidCallEdges(Edges, MaxEdges),
            {ok, #{
                module => Module,
                mermaid => Mermaid,
                edgeCount => length(Edges),
                totalEdgeCount => length(Edges0),
                filtered => true,
                filters => Filters,
                source => Source,
                mermaidEdgeCount => min(length(Edges), MaxEdges),
                sampleEdges => lists:sublist(Edges, min(25, MaxEdges)),
                hint => case length(Edges) of
                    0 -> <<"索引中该模块无调用边。请重新 /index，"
                           "或对已导出 MFA 用 getCallees。"/utf8>>;
                    _ -> <<"用 mermaid 看图；sampleEdges 仅为短预览。"/utf8>>
                end
            }}
    end;
dispatchTool(moduleDeps, Args, _Opts) ->
    case maps:get(module, Args, maps:get(<<"module">>, Args, undefined)) of
        undefined ->
            {error, #{reason => missingModule}};
        Module ->
            case coreCall(fun() -> alCoreClient:moduleDeps(Module) end) of
                {ok, Wrap} ->
                    Result = unwrapCoreData(Wrap),
                    Deps = maps:get(deps, Result, maps:get(<<"deps">>, Result, [])),
                    Mermaid = alDocGen:mermaidModuleDeps(Module, Deps),
                    {ok, Result#{
                        module => Module,
                        deps => Deps,
                        mermaid => Mermaid,
                        depCount => length(Deps)
                    }};
                {error, Reason} ->
                    {error, #{reason => Reason, degraded => true}}
            end
    end;
dispatchTool(generateModuleDoc, Args, _Opts) ->
    alDocGen:generateModuleDoc(Args);
dispatchTool(batchRefactor, Args, Opts) ->
    alBatchRefactor:run(Args, Opts);
dispatchTool(refactor, Args, _Opts) ->
    alRefactorTemplates:run(Args);
dispatchTool(embeddingSchema, _Args, _Opts) ->
    alCoreClient:embeddingSchema();
dispatchTool(getCallers, Args, _Opts) ->
    Module = maps:get(module, Args, maps:get(<<"module">>, Args, undefined)),
    case {maps:get(function, Args, maps:get(<<"function">>, Args, undefined)),
          maps:get(arity, Args, maps:get(<<"arity">>, Args, undefined))} of
        {undefined, _} -> {error, #{reason => missingFunction}};
        {_, undefined} -> {error, #{reason => missingArity}};
        {Function, Arity} ->
            case coreCall(fun() -> alCoreClient:getCallers(Module, Function, Arity) end) of
                {ok, Wrap} ->
                    Result = unwrapCoreData(Wrap),
                    Edges0 = coreEdges(Result),
                    {ok, packCallEdges(getCallers, Module, Function, Arity, Edges0, Args)};
                {error, Reason} ->
                    {ok, #{edges => [], edgeCount => 0, totalCount => 0,
                           fallback => erlang, reason => Reason}}
            end
    end;
dispatchTool(getCallees, Args, _Opts) ->
    Module = maps:get(module, Args, maps:get(<<"module">>, Args, undefined)),
    case {maps:get(function, Args, maps:get(<<"function">>, Args, undefined)),
          maps:get(arity, Args, maps:get(<<"arity">>, Args, undefined))} of
        {undefined, _} -> {error, #{reason => missingFunction}};
        {_, undefined} -> {error, #{reason => missingArity}};
        {Function, Arity} ->
            case coreCall(fun() -> alCoreClient:getCallees(Module, Function, Arity) end) of
                {ok, Wrap} ->
                    Result = unwrapCoreData(Wrap),
                    Edges0 = coreEdges(Result),
                    {ok, packCallEdges(getCallees, Module, Function, Arity, Edges0, Args)};
                {error, Reason} ->
                    {ok, #{edges => [], edgeCount => 0, totalCount => 0,
                           fallback => erlang, reason => Reason}}
            end
    end;
dispatchTool(traceDataQuery, Args, _Opts) ->
    case maps:get(question, Args, maps:get(<<"question">>, Args, undefined)) of
        undefined -> {error, #{reason => missingQuestion}};
        Question ->
            Opts = maps:with([maxDepth, maxNodes], Args),
            {ok, alContextEngine:traceDataQuery(Question, Opts)}
    end;
dispatchTool(dataSources, _Args, _Opts) ->
    coreCallUnwrapped(fun() -> alCoreClient:dataSources() end);
dispatchTool(dataSourceCallers, Args, _Opts) ->
    case maps:get(table, Args, maps:get(<<"table">>, Args, undefined)) of
        undefined -> {error, #{reason => missingTable}};
        Table ->
            coreCallUnwrapped(fun() -> alCoreClient:dataSourceCallers(Table) end)
    end;
dispatchTool(paramSources, Args, _Opts) ->
    Module = maps:get(module, Args, undefined),
    case {maps:get(function, Args, undefined), maps:get(arity, Args, undefined)} of
        {undefined, _} -> {error, #{reason => missingFunction}};
        {_, undefined} -> {error, #{reason => missingArity}};
        {Function, Arity} ->
            coreCallUnwrapped(fun() -> alCoreClient:paramSources(Module, Function, Arity) end)
    end;
dispatchTool(traceDataFlow, Args, _Opts) ->
    Module = maps:get(module, Args, undefined),
    case {maps:get(function, Args, undefined), maps:get(arity, Args, undefined)} of
        {undefined, _} -> {error, #{reason => missingFunction}};
        {_, undefined} -> {error, #{reason => missingArity}};
        {Function, Arity} ->
            ParamIndex = maps:get(paramIndex, Args, maps:get(<<"paramIndex">>, Args, 1)),
            Opts = maps:with([maxDepth, maxNodes], Args),
            coreCallUnwrapped(fun() ->
                alCoreClient:traceDataFlow(Module, Function, Arity, ParamIndex, Opts)
            end)
    end;
dispatchTool(findCallers, Args, Opts) ->
    dispatchTool(getCallers, Args, Opts);
dispatchTool(findCallees, Args, Opts) ->
    dispatchTool(getCallees, Args, Opts);
dispatchTool(recentCommits, Args, _Opts) ->
    Limit = toPositiveInt(maps:get(limit, Args, maps:get(count, Args, 10)), 10),
    HasExtra = maps:is_key(author, Args) orelse maps:is_key(path, Args)
        orelse maps:is_key(grep, Args) orelse maps:is_key(query, Args)
        orelse maps:get(withFiles, Args, false) =:= true,
    case {maps:get(days, Args, undefined), HasExtra} of
        {undefined, false} ->
            alChangeImpact:recentCommits(Limit);
        {Days0, false} ->
            Days = toPositiveInt(Days0, 1),
            alChangeImpact:recentCommits(Limit, Days);
        {Days0, true} ->
            Opts0 = #{limit => Limit, withFiles => maps:get(withFiles, Args, false)},
            Opts1 = case Days0 of
                undefined -> Opts0;
                D -> Opts0#{days => toPositiveInt(D, 1)}
            end,
            Opts2 = putIf(Opts1, author, maps:get(author, Args, undefined)),
            Opts3 = putIf(Opts2, path, maps:get(path, Args, undefined)),
            Grep = maps:get(grep, Args, maps:get(query, Args, undefined)),
            Opts = putIf(Opts3, grep, Grep),
            alChangeImpact:listCommits(Opts)
    end;
dispatchTool(lastCommit, _Args, _Opts) ->
    alChangeImpact:commitDiff(<<"HEAD">>);
dispatchTool(commitDiff, Args, _Opts) ->
    Ref = maps:get(ref, Args, <<"HEAD">>),
    alChangeImpact:commitDiff(Ref);
dispatchTool(commitFiles, Args, _Opts) ->
    Ref = maps:get(ref, Args, <<"HEAD">>),
    alChangeImpact:commitFiles(Ref);
dispatchTool(searchCommits, Args, _Opts) when is_map(Args) ->
    alChangeImpact:searchCommits(Args);
dispatchTool(dailyReview, Args, _Opts) when is_map(Args) ->
    alChangeImpact:dailyReview(Args);
dispatchTool(dailyReview, _Args, _Opts) ->
    alChangeImpact:dailyReview(#{});
dispatchTool(reviewChangeImpact, Args, _Opts) ->
    Ref = maps:get(ref, Args, maps:get(<<"ref">>, Args, <<"HEAD">>)),
    SummaryMode = maps:get(summaryMode, Args, maps:get(<<"summaryMode">>, Args, both)),
    alChangeImpact:review(Ref, #{summaryMode => SummaryMode});
dispatchTool(reviewPackage, Args, _Opts) when is_map(Args) ->
    alReviewPackage:build(Args);
dispatchTool(functionHistory, Args, _Opts) ->
    Mod = maps:get(module, Args, maps:get(<<"module">>, Args, undefined)),
    Fun = maps:get(function, Args, maps:get(<<"function">>, Args, undefined)),
    Arity = maps:get(arity, Args, maps:get(<<"arity">>, Args, 0)),
    Days = maps:get(days, Args, maps:get(<<"days">>, Args, 90)),
    alChangeImpact:functionHistory(Mod, Fun, Arity, toPositiveInt(Days, 90));
dispatchTool(getRuntime, _Args, _Opts) ->
    {ok, alRuntimeProbe:snapshot()};
dispatchTool(supervisorTree, Args, _Opts) when is_map(Args), map_size(Args) > 0 ->
    {ok, alRuntimeProbe:supervisorTree(Args)};
dispatchTool(supervisorTree, _Args, _Opts) ->
    {ok, alRuntimeProbe:supervisorTree()};
dispatchTool(getProcesses, Args, _Opts) ->
    ProcOpts = #{
        limit => maps:get(limit, Args, 20),
        sortBy => maps:get(sortBy, Args, memory),
        minMessageQueueLen => maps:get(minMessageQueueLen, Args, 0)
    },
    {ok, alRuntimeProbe:processes(ProcOpts)};
dispatchTool(processInfo, Args, _Opts) ->
    Pid = maps:get(pid, Args, maps:get(<<"pid">>, Args, undefined)),
    alRuntimeProbe:processInfo(Pid);
dispatchTool(getOldCodeProcesses, Args, _Opts) ->
    {ok, alRuntimeProbe:oldCodeProcesses(Args)};
dispatchTool(etsLookup, Args, _Opts) ->
    Tab = maps:get(table, Args, maps:get(<<"table">>, Args, undefined)),
    Key = maps:get(key, Args, maps:get(<<"key">>, Args, undefined)),
    Limit = maps:get(limit, Args, maps:get(<<"limit">>, Args, 20)),
    alRuntimeProbe:etsLookup(Tab, Key, Limit);
dispatchTool(getEts, Args, _Opts) ->
    Limit = maps:get(limit, Args, 20),
    {ok, alRuntimeProbe:etsTables(Limit)};
dispatchTool(verifyCompile, Args, _Opts) ->
    alPatchManager:verifyCompile(Args);
dispatchTool(genTest, Args, _Opts) ->
    alTestGen:generate(Args);
dispatchTool(webSearch, Args, _Opts) ->
    alWebSearch:search(Args);
dispatchTool(appTopology, _Args, _Opts) ->
    {ok, alAppTopology:snapshot()};
dispatchTool(contextPreview, Args, _Opts) ->
    Messages = maps:get(messages, Args, []),
    AgentCfg = alConfig:getAgentCfg(),
    {ok, alContext:previewTrim(Messages, AgentCfg)};
dispatchTool(memoryDistill, Args, _Opts) ->
    Sid = maps:get(sessionId, Args, undefined),
    Opts = case maps:get(messages, Args, undefined) of
        undefined -> #{};
        Msgs -> #{messages => Msgs}
    end,
    alMemory:distill(Sid, Opts);
dispatchTool(gitIndex, Args, Opts) ->
    dispatchTool(vcsIndex, Args, Opts);
dispatchTool(vcsIndex, Args, _Opts) ->
    Root = case maps:get(root, Args, undefined) of
        undefined -> unicode:characters_to_list(alConfig:projectRoot());
        R -> unicode:characters_to_list(R)
    end,
    case alVcsIndex:incrementalIndex(Root) of
        {ok, Result} = Ok ->
            _ = alAsync:run(reconcileAfterVcsIndex,
                fun() -> alExperience:reconcileAfterCodeChange(Result) end),
            Ok;
        Error ->
            Error
    end;
dispatchTool(hotReload, Args, _Opts) when is_map(Args) ->
    alHotReload:reload(Args);
dispatchTool(specIndex, Args, _Opts) ->
    Type = maps:get(type, Args, undefined),
    Root = case maps:get(root, Args, undefined) of
        undefined -> unicode:characters_to_list(alConfig:projectRoot());
        R -> unicode:characters_to_list(R)
    end,
    Limit = maps:get(limit, Args, 200),
    case Type of
        undefined -> {error, #{reason => missingType}};
        _ ->
            case alToolsExt:resolveReadablePath(Root) of
                {ok, ResolvedRoot} ->
                    alSpecIndex:findTypeUsages(Type, ResolvedRoot, Limit);
                {error, pathNotAllowed} ->
                    {error, #{reason => pathNotAllowed}}
            end
    end;
dispatchTool(specSearch, Args, _Opts) ->
    Pattern = maps:get(pattern, Args, undefined),
    Root = case maps:get(root, Args, undefined) of
        undefined -> unicode:characters_to_list(alConfig:projectRoot());
        R -> unicode:characters_to_list(R)
    end,
    Limit = maps:get(limit, Args, 200),
    case Pattern of
        undefined -> {error, #{reason => missingPattern}};
        _ ->
            case alToolsExt:resolveReadablePath(Root) of
                {ok, ResolvedRoot} ->
                    alSpecIndex:searchSpecs(Pattern, ResolvedRoot, Limit);
                {error, pathNotAllowed} ->
                    {error, #{reason => pathNotAllowed}}
            end
    end;
dispatchTool(runMfa, Args, _Opts) ->
    case resolveRunMfa(Args) of
        {ok, Module, Function, Arguments} ->
            Timeout = maps:get(timeout, Args, 5000),
            Caller = maps:get(caller, Args, interactive),
            runMfaWithVerifyLoop(Args, Module, Function, Arguments, Timeout, Caller);
        {error, Reason} ->
            {error, #{reason => Reason}}
    end;
dispatchTool(evalErl, Args, _Opts) when is_map(Args) ->
    Code = maps:get(code, Args, maps:get(<<"code">>, Args, undefined)),
    case Code of
        undefined -> {error, #{reason => missingCode}};
        _ ->
            Opts = maps:with([args, dryRun, timeout, bindings,
                              <<"args">>, <<"dryRun">>, <<"timeout">>, <<"bindings">>], Args),
            %% 统一成 atom 键
            Norm = #{
                args => maps:get(args, Opts, maps:get(<<"args">>, Opts, [])),
                dryRun => maps:get(dryRun, Opts, maps:get(<<"dryRun">>, Opts, false)),
                timeout => maps:get(timeout, Opts, maps:get(<<"timeout">>, Opts, 5000)),
                bindings => maps:get(bindings, Opts, maps:get(<<"bindings">>, Opts, #{}))
            },
            alEval:eval(Code, Norm)
    end;
dispatchTool(dbQuery, Args, _Opts) ->
    alDbAdapter:query(Args);
dispatchTool(remember, Args, _Opts) ->
    SessionId = maps:get(sessionId, Args, undefined),
    Kind = maps:get(kind, Args, note),
    case maps:get(content, Args, undefined) of
        undefined -> {error, #{reason => missingContent}};
        Content ->
            MemOpts = maps:without([sessionId, kind, content], Args),
            alMemory:remember(SessionId, Kind, Content, MemOpts)
    end;
dispatchTool(saveLesson, Args, Opts) when is_map(Args) ->
    SessionId = maps:get(sessionId, Args,
                    maps:get(<<"sessionId">>, Args,
                        maps:get(sessionId, Opts, undefined))),
    Source = maps:get(source, Args, maps:get(<<"source">>, Args, manual)),
    case Source =:= correction orelse Source =:= <<"correction">>
         orelse maps:get(correct, Args, false) =:= true of
        true -> alExperience:correctLesson(SessionId, Args);
        false -> alExperience:recordLesson(SessionId, Args)
    end;
dispatchTool(correctLesson, Args, Opts) when is_map(Args) ->
    SessionId = maps:get(sessionId, Args,
                    maps:get(<<"sessionId">>, Args,
                        maps:get(sessionId, Opts, undefined))),
    alExperience:correctLesson(SessionId, Args);
dispatchTool(recallExperience, Args, _Opts) ->
    Query = maps:get(query, Args, maps:get(<<"query">>, Args, <<>>)),
    Limit = maps:get(limit, Args, maps:get(<<"limit">>, Args, 5)),
    Lessons = case alExperience:recallFor(Query, toPositiveInt(Limit, 5)) of
        {ok, Rows} -> Rows;
        _ -> []
    end,
    {ok, #{
        lessons => Lessons,
        familiarity => alExperience:familiarityDigest(#{limit => 5})
    }};
dispatchTool(recall, Args, _Opts) ->
    Query = maps:get(query, Args, <<>>),
    Limit = maps:get(limit, Args, 20),
    alMemory:recall(Query, Limit);
dispatchTool(recallSemantic, Args, _Opts) ->
    Query = maps:get(query, Args, <<>>),
    Limit = maps:get(limit, Args, 10),
    alMemory:recallSemantic(Query, Limit);
dispatchTool(searchMemory, Args, _Opts) ->
    dispatchTool(recallSemantic, Args, _Opts);
dispatchTool(simulate, Scenario, _Opts) ->
    alSimulator:run(Scenario);
dispatchTool(validatePatch, Patch, _Opts) ->
    alPatchManager:validate(Patch);
dispatchTool(dryRunPatch, Patch, _Opts) ->
    alPatchManager:dryRun(Patch);
dispatchTool(applyPatch, Args, Opts) ->
    PatchOpts = maps:with([verifyCompile, compileCommand, compileTimeoutMs, rollbackOnFailure], Opts),
    Result = case maps:get(dryRun, Opts, false) orelse patchRequireDryRun() of
        true ->
            case alPatchManager:dryRun(Args) of
                {ok, _} -> alPatchManager:applyPatch(Args, PatchOpts);
                Error -> Error
            end;
        false ->
            alPatchManager:applyPatch(Args, PatchOpts)
    end,
    maybeReconcileAfterWrite(Result),
    Result;
dispatchTool(applyPatchBatch, Args, Opts) ->
    Result = case maps:get(patches, Args, undefined) of
        undefined -> {error, #{reason => missingPatches}};
        Patches ->
            BatchOpts = maps:merge(#{verifyCompile => true},
                                   maps:with([verifyCompile, compileCommand, compileTimeoutMs,
                                              rollbackOnFailure], Opts)),
            alPatchManager:applyBatch(Patches, BatchOpts)
    end,
    maybeReconcileAfterWrite(Result),
    Result;
dispatchTool(rollbackPatch, Args, _Opts) ->
    case maps:get(transactionId, Args, undefined) of
        undefined -> alPatchManager:rollbackLast();
        TxId -> alPatchManager:rollback(TxId)
    end;
dispatchTool(readFile, Args, _Opts) ->
    alToolsExt:readFile(Args);
dispatchTool(readFilePage, Args, _Opts) ->
    alToolsExt:readFilePage(Args);
dispatchTool(listFiles, Args, _Opts) ->
    alToolsExt:listFiles(Args);
dispatchTool(searchText, Args, _Opts) ->
    Query = maps:get(query, Args, <<>>),
    SubPath = maps:get(path, Args, <<".">>),
    Limit = maps:get(limit, Args, 20),
    Context = maps:get(context, Args, maps:get(<<"context">>, Args, 3)),
    Root = unicode:characters_to_binary(alConfig:projectRoot()),
    case alSearch:search(Root, SubPath, Query, Limit, Context) of
        {ok, Matches} ->
            {ok, #{
                query => Query,
                path => SubPath,
                matchCount => length(Matches),
                limit => Limit,
                context => Context,
                truncated => length(Matches) >= Limit,
                matches => Matches,
                backend => alSearch:backend()
            }};
        {error, Reason} ->
            {error, Reason}
    end;
dispatchTool(writeFile, Args, _Opts) ->
    Result = alToolsExt:writeFile(Args),
    maybeReconcileAfterWrite(Result),
    Result;
dispatchTool(getBeamAbstract, Args, _Opts) ->
    alToolsExt:getBeamAbstract(Args);
dispatchTool(moduleExports, Args, _Opts) ->
    alToolsExt:moduleExports(Args);
dispatchTool(getModuleTypes, Args, _Opts) ->
    alToolsExt:getModuleTypes(Args);
dispatchTool(getSymbolSource, Args, _Opts) ->
    alToolsExt:getSymbolSource(Args);
dispatchTool(formatCode, Args, _Opts) ->
    alToolsExt:formatCode(Args);
dispatchTool(indexStatus, _Args, _Opts) ->
    alCoreClient:unwrap(alCoreClient:indexStatus());
dispatchTool(searchUnified, Args, _Opts) ->
    %% searchUnified 默认 hybrid；其余复用 searchCode 分发逻辑（含 VCS 过滤 + 组合查询）。
    HasMode = maps:is_key(mode, Args) orelse maps:is_key(<<"mode">>, Args),
    Args1 = case HasMode of
        true -> Args;
        false -> maps:put(mode, hybrid, Args)
    end,
    dispatchTool(searchCode, Args1, #{});
dispatchTool(runEunit, Args, _Opts) ->
    alToolsExt:runEunit(Args);
dispatchTool(runDialyzer, Args, _Opts) ->
    alToolsExt:runDialyzer(Args);
dispatchTool(runTestsForPatch, Args, _Opts) ->
    alToolsExt:runTestsForPatch(Args);
dispatchTool(planSet, Args, Opts) ->
    SessionId = maps:get(sessionId, Args, maps:get(sessionId, Opts, undefined)),
    Steps = maps:get(steps, Args, maps:get(todos, Args,
                maps:get(<<"steps">>, Args, maps:get(<<"todos">>, Args, [])))),
    alToolsExt:planSet(SessionId, Steps);
dispatchTool(planGet, Args, Opts) ->
    SessionId = maps:get(sessionId, Args, maps:get(sessionId, Opts, undefined)),
    alToolsExt:planGet(SessionId);
dispatchTool(planUpdate, Args, Opts) ->
    SessionId = maps:get(sessionId, Args, maps:get(sessionId, Opts, undefined)),
    StepId = maps:get(stepId, Args, maps:get(id, Args,
                maps:get(<<"stepId">>, Args, maps:get(<<"id">>, Args, undefined)))),
    case StepId of
        undefined -> {error, #{reason => missingStepId}};
        _ ->
            Updates = maps:get(updates, Args, maps:without([sessionId, stepId, id,
                                                            <<"sessionId">>, <<"stepId">>, <<"id">>], Args)),
            alToolsExt:planUpdate(SessionId, StepId, Updates)
    end;
dispatchTool(planClear, Args, Opts) ->
    SessionId = maps:get(sessionId, Args, maps:get(sessionId, Opts, undefined)),
    {ok, alToolsExt:planClear(SessionId)};
dispatchTool(todoWrite, Args, Opts) ->
    dispatchTool(planSet, Args, Opts);
dispatchTool(todoRead, Args, Opts) ->
    dispatchTool(planGet, Args, Opts);
dispatchTool(todoUpdate, Args, Opts) ->
    dispatchTool(planUpdate, Args, Opts);
dispatchTool(todoClear, Args, Opts) ->
    dispatchTool(planClear, Args, Opts);
dispatchTool(delegateTo, Args, _Opts) ->
    alToolsExt:delegateTo(Args);
dispatchTool(useSkill, Args, _Opts) ->
    alToolsExt:useSkill(Args);
dispatchTool(fetchUrl, Args, Opts) ->
    case alToolsExt:fetchUrl(Args) of
        {ok, Result} = Ok ->
            maybeRememberWebPage(Result, Opts),
            Ok;
        Other ->
            Other
    end;
dispatchTool(fetchUrlPage, Args, _Opts) ->
    alToolsExt:fetchUrlPage(Args);
dispatchTool(webQa, Args, _Opts) ->
    alWebSearch:webQa(Args);
dispatchTool(Tool, _Args, _Opts) ->
    {error, {unknownTool, Tool}}.

%%--------------------------------------------------------------------
%% @doc
%% fetchUrl 成功后把网页正文异步存入长期记忆（kind=webPage，project
%% scope），供后续会话 recall 检索。仅记录提取成功且正文 ≥ 500 字节的
%% 页面；配置 fetchUrl.rememberWebPages=false 关闭。
%%
%% @param Result fetchUrl 的 ok 结果
%% @param Opts   调用上下文（取 sessionId）
%% @end
%%--------------------------------------------------------------------
maybeRememberWebPage(Result, Opts) ->
    try
        Cfg = alConfig:get(fetchUrl, #{}),
        Remember = maps:get(rememberWebPages, Cfg, true) =:= true,
        Extracted = maps:get(extracted, Result, false) =:= true,
        Body = maps:get(body, Result, <<>>),
        case Remember andalso Extracted andalso is_binary(Body)
             andalso byte_size(Body) >= 500 of
            true ->
                SessionId = maps:get(sessionId, Opts, undefined),
                Url = maps:get(url, Result, <<>>),
                Title = maps:get(title, Result, <<>>),
                Host = urlHostOf(Url),
                Content = webPageMemoryContent(Title, Url, Body),
                alAsync:run(rememberWebPage, fun() ->
                    alMemory:remember(SessionId, webPage, Content,
                                      #{scope => project,
                                        tags => [webPage, Host],
                                        metadata => #{url => Url,
                                                      title => Title}})
                end);
            false ->
                ok
        end
    catch _:_ -> ok end.

urlHostOf(Url) when is_binary(Url) ->
    case binary:split(Url, <<"//">>) of
        [_, Rest] ->
            case binary:split(Rest, <<"/">>) of
                [Host | _] -> Host;
                [] -> Rest
            end;
        _ ->
            <<>>
    end;
urlHostOf(_) ->
    <<>>.

%% 网页记忆内容：标题 + URL + 正文前 4KB（关键词召回主要靠这三段）。
webPageMemoryContent(Title, Url, Body) ->
    TitleLine = case Title of
        <<>> -> <<>>;
        _ -> <<Title/binary, "\n">>
    end,
    <<TitleLine/binary, Url/binary, "\n", (capBytes(Body, 4096))/binary>>.

capBytes(B, Max) when byte_size(B) > Max ->
    binary:part(B, 0, Max);
capBytes(B, _Max) ->
    B.

%% moduleSymbols 输出可能包含 document.functions，每个函数带 line/start_line/end_line。
%% 默认只给前 N 个函数做 sourcePreview，避免输出爆炸。
enrichModuleSymbolsSources(Result, Opts) when is_map(Result) ->
    case maps:get(includeSource, Opts, true) of
        false ->
            Result;
        _ ->
            AbsFile = fileFromModuleSymbolsResult(Result),
            Context = maps:get(context, Opts, 3),
            Limit = 12,
            %% 找 document.functions（兼容 atom/binary key）
            DocKey = case maps:get(document, Result, undefined) of
                         M when is_map(M) -> document;
                         _ -> <<"document">>
                     end,
            Doc0 = maps:get(DocKey, Result, #{}),
            FunKey = case maps:get(functions, Doc0, undefined) of
                         L when is_list(L) -> functions;
                         _ -> <<"functions">>
                     end,
            Funs0 = maps:get(FunKey, Doc0, []),
            N = min(Limit, length(Funs0)),
            Head = lists:sublist(Funs0, N),
            Tail = lists:nthtail(N, Funs0),
            HeadEnr = [enrichFunSourcePreview(F, AbsFile, Context) || F <- Head],
            Doc1 = Doc0#{FunKey => HeadEnr ++ Tail},
            Result#{DocKey => Doc1}
    end;
enrichModuleSymbolsSources(Result, _Opts) ->
    Result.

enrichFunSourcePreview(Fun0, AbsFile, Context) ->
    case AbsFile of
        undefined ->
            Fun0;
        FilePath ->
            Start = firstDefined([
                maps:get(start_line, Fun0, maps:get(<<"start_line">>, Fun0, undefined)),
                maps:get(startLine, Fun0, maps:get(<<"startLine">>, Fun0, undefined))
            ]),
            End = firstDefined([
                maps:get(end_line, Fun0, maps:get(<<"end_line">>, Fun0, undefined)),
                maps:get(endLine, Fun0, maps:get(<<"endLine">>, Fun0, undefined))
            ]),
            Line = firstDefined([
                maps:get(line, Fun0, maps:get(<<"line">>, Fun0, undefined))
            ]),
            case {Start, End, Line} of
                {S, E, _} when is_integer(S), is_integer(E), S >= 1, E >= S ->
                    case alToolsExt:readFile(#{path => FilePath,
                                                startLine => max(1, S - Context),
                                                endLine => E + Context,
                                                maxBytes => 48000}) of
                        {ok, Range} ->
                            Fun0#{
                                sourcePreview => maps:get(content, Range),
                                sourceStartLine => maps:get(startLine, Range, S - Context),
                                sourceEndLine => maps:get(endLine, Range, E + Context),
                                sourceTruncated => maps:get(truncated, Range, false)
                            };
                        _ ->
                            Fun0
                    end;
                {_, _, L} when is_integer(L), L >= 1 ->
                    case alToolsExt:sourceSnippet(#{path => FilePath, line => L,
                                                    context => Context}) of
                        {ok, Snip} ->
                            Fun0#{
                                sourcePreview => maps:get(source, Snip, maps:get(content, Snip)),
                                sourceStartLine => maps:get(startLine, Snip, undefined),
                                sourceEndLine => maps:get(endLine, Snip, undefined)
                            };
                        _ ->
                            Fun0
                    end;
                _ ->
                    Fun0
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 在 Rust core 可用时执行给定函数并返回其结果；不可用时返回
%% `{error, coreUnavailable}'。
%%
%% @param Fun 0 元 fun，通常封装 alCoreClient 调用
%% @return `{ok, _}' / `{error, _}' / `{error, coreUnavailable}'
%% @end
%%--------------------------------------------------------------------
coreCall(Fun) when is_function(Fun, 0) ->
    case alCoreClient:available() of
        true ->
            case Fun() of
                {ok, _} = Ok ->
                    Ok;
                {error, _} = Err ->
                    Err
            end;
        false ->
            {error, coreUnavailable}
    end.

%% 从 LLM 回复中提取 answer 文本：优先 content，其次 message.content，否则原样返回。
answerFromReply(#{content := Content}) when Content =/= null, Content =/= undefined ->
    Content;
answerFromReply(#{message := #{content := Content}}) when Content =/= null, Content =/= undefined ->
    Content;
answerFromReply(Reply) ->
    Reply.

%%--------------------------------------------------------------------
%% @doc
%% LLM 调用失败或未配置时返回的本地兜底答案：附上原因、上下文与建议工具。
%%
%% @param Question 原问题（可为 undefined）
%% @param Context 上下文 map
%% @param Reason 失败原因
%% @return 兜底答案 map
%% @end
%%--------------------------------------------------------------------
fallbackAnswer(Question, Context, Reason) ->
    Summary = case Reason of
        maxToolSteps ->
            <<"已达工具步数上限。下方为检索上下文 / 最近工具轨迹——"
              "若有成功的 runMfa 结果请从中提炼答案。"/utf8>>;
        tokenBudgetExceeded ->
            <<"已超 token 预算。请根据已收集信息作答。"/utf8>>;
        _ ->
            <<"LLM 调用失败或不完整。返回已检索上下文供本地查看。"/utf8>>
    end,
    Base = #{
        provider => localFallback,
        reason => Reason,
        summary => Summary,
        suggestedNextTools => [runMfa, searchCode, resolveModule, getRuntime],
        context => Context
    },
    case Question of
        undefined -> Base;
        _ -> Base#{question => Question}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 校验/创建会话：无 sessionId 时直接 ok；否则在开启持久化时调用
%% alSessionMgr:ensureSession 确保会话存在。
%%
%% @param SessionId 会话 id（可为 undefined）
%% @param Opts 选项 map
%% @return `ok' 或 `{error, {invalidSession, Reason}}'
%% @end
%%--------------------------------------------------------------------
ensureSession(undefined, _Opts) ->
    ok;
ensureSession(SessionId, Opts) ->
    case maps:get(persistMemory, Opts, true) of
        false ->
            ok;
        true ->
            case alSessionMgr:ensureSession(SessionId, maps:get(user, Opts, web)) of
                {ok, _} -> ok;
                {error, Reason} -> {error, {invalidSession, Reason}}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 读取会话历史消息：无 sessionId 或关闭持久化时返回空列表。
%%
%% @param SessionId 会话 id（可为 undefined）
%% @param Opts 选项 map
%% @return 消息列表
%% @end
%%--------------------------------------------------------------------
sessionMessages(undefined, _Opts) ->
    [];
sessionMessages(SessionId, Opts) ->
    case maps:get(persistMemory, Opts, true) of
        false -> [];
        true ->
            case alSessionMgr:getContext(SessionId) of
                {ok, #{messages := Messages}} -> Messages;
                _ -> []
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 向会话追加一条消息（关闭持久化或无 sessionId 时为 no-op）。
%% 追加前会先降级附件以避免大对象入库。
%%
%% @param SessionId 会话 id（可为 undefined）
%% @param Opts 选项 map
%% @param Message 消息 map
%% @return `ok'
%% @end
%%--------------------------------------------------------------------
maybeAppendMessage(undefined, _Opts, _Message) ->
    ok;
maybeAppendMessage(SessionId, Opts, Message) ->
    case maps:get(persistMemory, Opts, true) of
        false -> ok;
        true ->
            Safe = alAttachments:downgradeAttachments(Message),
            _ = alSessionMgr:appendMessage(SessionId, Safe),
            ok
    end.

%%--------------------------------------------------------------------
%% @doc
%% 将用户问题与 Opts 中的附件（images/files/documents）打包为 user 消息。
%%
%% @param Question 用户问题
%% @param Opts 选项 map
%% @return user 消息 map
%% @end
%%--------------------------------------------------------------------
userMessageWithAttachments(Question, Opts) ->
    Attachments = #{
        images => maps:get(images, Opts, []),
        files => maps:get(files, Opts, []),
        documents => maps:get(documents, Opts, [])
    },
    alAttachments:userMessage(Question, Attachments).

%%--------------------------------------------------------------------
%% @doc
%% 将检索到的上下文打包为 user 角色消息内容（避免使用 role=tool，
%% 因为 OpenAI/DeepSeek 要求 tool 角色必须带 tool_call_id）。
%%
%% @param Context 上下文（map/list/term）
%% @return 二进制文本内容
%% @end
%%--------------------------------------------------------------------
%% Injected context must not use role=tool (requires tool_call_id).
contextUserContent(Context) when is_map(Context); is_list(Context) ->
    iolist_to_binary([
        <<"<retrieved_context>\n">>,
        alJson:encode(Context),
        <<"\n</retrieved_context>\n">>,
        <<"把 retrieved_context 仅当作检索提示。"
          "任何行为性结论请先用工具阅读所引源码。"/utf8>>
    ]);
contextUserContent(Context) ->
    contextUserContent(#{raw => Context}).

%% 读取 patch 配置中的 requireDryRun 开关（默认 false）。
patchRequireDryRun() ->
    maps:get(requireDryRun, alConfig:get(patch, #{}), false).

%% 写文件工具成功后：异步触发经验对账（轻量，每次执行）+ digest 重建（重量级，节流）。
maybeReconcileAfterWrite(Result) ->
    case writeResultPaths(Result) of
        [] ->
            ok;
        Paths ->
            _ = alAsync:run(reconcileAfterWrite, fun() ->
                alExperience:reconcileAfterCodeChange(#{changed => Paths, deleted => []})
            end),
            maybeBuildDigestThrottled(),
            ok
    end.

%% digest 重建较重量级：写文件后节流触发，默认 30s 内最多一次。
%% 用 persistent_term 存时间戳，不依赖创建进程生命周期（避免 ETS 随进程退出丢失）。
maybeBuildDigestThrottled() ->
    Now = erlang:monotonic_time(millisecond),
    case persistent_term:get(?DigestRebuildThrottleKey, undefined) of
        undefined ->
            persistent_term:put(?DigestRebuildThrottleKey, Now),
            _ = alProjectDigest:maybeBuildAfterIndex(),
            ok;
        Last when is_integer(Last), Now - Last >= ?DigestRebuildThrottleMs ->
            persistent_term:put(?DigestRebuildThrottleKey, Now),
            _ = alProjectDigest:maybeBuildAfterIndex(),
            ok;
        _ ->
            ok
    end.

%% 从写文件工具结果中提取涉及的文件路径。
writeResultPaths({ok, #{results := Results}}) when is_list(Results) ->
    lists:usort([F || R <- Results, F <- resultPaths(R), F =/= undefined]);
writeResultPaths({ok, #{patch := Patch}}) ->
    resultPaths(Patch);
writeResultPaths({ok, #{path := Path}}) ->
    [Path];
writeResultPaths(_) ->
    [].

resultPaths(#{patch := #{file := File}}) -> [File];
resultPaths(#{file := File}) -> [File];
resultPaths(#{path := Path}) -> [Path];
resultPaths(_) -> [].

%%--------------------------------------------------------------------
%% @doc
%% 计算传给 LLM 客户端的选项：优先用 Opts.llmOverride 合并到全局
%% llm 配置；否则从 agentCfg.llm 取，再退回 alConfig:get(llm)。
%%
%% @param Opts 选项 map
%% @return LLM 选项 map
%% @end
%%--------------------------------------------------------------------
llmOpts(Opts) ->
    Override = maps:get(llmOverride, Opts, undefined),
    CfgLlm = maps:get(llm, maps:get(agentCfg, Opts, alConfig:getAgentCfg()),
                      alConfig:get(llm, #{})),
    Base = case {alLlmRouter:chainEnabled(), Override} of
        {true, _} ->
            CfgLlm;
        {false, undefined} ->
            CfgLlm;
        {false, O} ->
            maps:merge(CfgLlm, O)
    end,
    %% 单次 LLM 调用超时与工具循环总超时分离：
    %% - llmTimeout / execTimeout：单轮 LLM（含流式收集）
    %% - agentTimeoutMs（session worker）：整轮 ask/toolLoop 总时长
    LlmTimeout = firstPositive([
        maps:get(llmTimeout, Opts, undefined),
        maps:get(llmTimeout, Base, undefined),
        maps:get(execTimeout, Opts, undefined),
        maps:get(execTimeout, Base, undefined),
        1800000
    ]),
    Base1 = Base#{
        llmTimeout => LlmTimeout,
        execTimeout => LlmTimeout
    },
    %% 模型链 pin：会话路由/质量升级已决策的链项直接传给 LLM 客户端。
    %% llmOverride 在链启用时经 applyCloudOverride 仅 patch 云端链项。
    Result = case maps:get(modelEntry, Opts, undefined) of
        Entry when is_map(Entry) ->
            Entry1 = alLlmRouter:applyCloudOverride(Entry, Override),
            alLlmRouter:mergeEntryOpts(Entry1, Base1#{modelEntry => Entry1});
        _ ->
            case maps:get(llmPin, Opts, false) of
                true -> Base1#{llmPin => true};
                _ -> Base1
            end
    end,
    case Override of
        undefined -> Result;
        _ -> Result#{llmOverride => Override}
    end.

firstPositive([]) -> 1800000;
firstPositive([N | _]) when is_integer(N), N > 0 -> N;
firstPositive([_ | Rest]) -> firstPositive(Rest).

%% 当 Opts 中存在 progressId 时向 alProgress 推送一个事件，否则 no-op。
emitProgress(Opts, Event) ->
    case maps:get(progressId, Opts, undefined) of
        undefined -> ok;
        Id -> alProgress:emit(Id, Event)
    end.

%% 等待 LLM 首包时每 15s 推一次进度，避免网页一直停在「LLM round 0」无反馈。
%% 进度文案用 UTF-8 binary 拼接，避免 Unicode charlist + iolist_to_binary badarg。
llmWaitTicker(Parent, Opts, Step, N) ->
    receive
        eStop -> ok
    after 15000 ->
        case is_process_alive(Parent) of
            false -> ok;
            true ->
                Sec = (N + 1) * 15,
                Msg = <<"仍在等待模型响应… "/utf8,
                        (integer_to_binary(Sec))/binary,
                        <<"s（若持续无进展请检查 DeepSeek 网络/API）"/utf8>>/binary>>,
                try
                    emitProgress(Opts, #{
                        type => step,
                        phase => llmWait,
                        step => Step,
                        message => Msg
                    })
                catch _:_ -> ok
                end,
                llmWaitTicker(Parent, Opts, Step, N + 1)
        end
    end.

%% 任务以最终答案结束（成功/收敛/预算用尽）时清理 checkpoint，
%% 保持 "checkpoint = 未完成任务" 语义，避免重启扫描误报。失败静默。
maybeDeleteCheckpoint(Opts) ->
    case maps:get(taskId, Opts, undefined) of
        undefined -> ok;
        TaskId ->
            try alCheckpoint:delete(to_binary(TaskId)) catch _:_ -> ok end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 用户对 pending 工具确认后恢复工具循环：用批准结果替换对应的
%% tool 消息内容，从续接点继续 toolLoop。
%%
%% @param Continuation 挂起时保存的续接 map
%% @param ApprovedContent 批准后的工具结果内容
%% @return toolLoop 的后续结果
%% @end
%%--------------------------------------------------------------------
resumeToolLoop(Continuation, ApprovedContent) when is_map(Continuation) ->
    resumeToolLoop(Continuation, ApprovedContent, #{}).

%% ExtraOpts 可注入 streamCaller / progressId / taskId（WS 恢复流式时用）。
resumeToolLoop(Continuation, ApprovedContent, ExtraOpts)
  when is_map(Continuation), is_map(ExtraOpts) ->
    #{
        messages := Messages,
        opts := Opts0,
        context := Context,
        step := Step,
        trace := Trace,
        maxSteps := MaxSteps,
        pendingCall := #{id := ToolCallId}
    } = Continuation,
    Opts = mergeResumeOpts(Opts0, ExtraOpts),
    UpdatedMessages = replaceToolResult(Messages, ToolCallId, ApprovedContent),
    toolLoop(UpdatedMessages, Opts, Context, Step, Trace, MaxSteps).

%%--------------------------------------------------------------------
%% @doc
%% 从磁盘加载指定 TaskId 的 checkpoint（参见 alCheckpoint）并
%% 直接恢复工具循环，无需用户审批。失败/不存在返回 error。
%%
%% @param TaskId 任务 ID（binary 或 list）
%% @return toolLoop 返回的 `{ok, Reply}'
%% @end
%%--------------------------------------------------------------------
resumeFromCheckpoint(TaskId) ->
    resumeFromCheckpoint(TaskId, undefined, #{}).

resumeFromCheckpoint(TaskId, ApprovedContent) ->
    resumeFromCheckpoint(TaskId, ApprovedContent, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 加载 checkpoint 并恢复；ExtraOpts 可重挂 streamCaller 等运行时选项。
%% @end
%%--------------------------------------------------------------------
resumeFromCheckpoint(TaskId, ApprovedContent, ExtraOpts) when is_map(ExtraOpts) ->
    case alCheckpoint:load(TaskId) of
        {ok, Continuation} ->
            case {ApprovedContent, maps:find(pendingCall, Continuation)} of
                {undefined, _} ->
                    %% 无审批内容：直接续跑 messages
                    #{
                        messages := Messages,
                        opts := Opts0,
                        context := Context,
                        step := Step,
                        trace := Trace,
                        maxSteps := MaxSteps
                    } = Continuation,
                    Opts = mergeResumeOpts(Opts0, ExtraOpts),
                    toolLoop(Messages, Opts, Context, Step, Trace, MaxSteps);
                {_, {ok, _Pending}} ->
                    resumeToolLoop(Continuation, ApprovedContent, ExtraOpts);
                {_, error} ->
                    {error, {noPendingCall, TaskId}}
            end;
        {error, _} = E -> E
    end.

%% 续跑时合并运行时选项：streamCaller / progressId / taskId 等活 pid 不能进 checkpoint。
mergeResumeOpts(Opts, Extra) when is_map(Opts), is_map(Extra) ->
    maps:merge(Opts, maps:with([streamCaller, progressId, taskId, sessionId], Extra));
mergeResumeOpts(Opts, _) ->
    Opts.

%%--------------------------------------------------------------------
%% @doc
%% 在工具调用与结果中查找第一条 pending（需确认）的工具，返回其
%% TaskId/Call/Content，用于挂起循环并等待用户确认。
%%
%% @param Calls 工具调用列表
%% @param Results 对应结果列表
%% @return `{ok, TaskId, Call, Content}' 或 `miss'
%% @end
%%--------------------------------------------------------------------
findPendingTool(Calls, Results) ->
    Pairs = lists:zip(Calls, Results),
    findPendingTool(Pairs).

%% 内部辅助：在 (Call, Result) 对的列表中查找 pending 工具。
%% content 已被 toolResultMessage 经 capToolResult 编码为 JSON binary，
%% 故须兼容 map（旧/防御形态）与 binary 两种，避免挂起检测失效。
findPendingTool([]) ->
    miss;
findPendingTool([{Call, #{content := Content} = Full} | Rest]) ->
    case pendingTaskId(Content) of
        {ok, TaskId} ->
            {ok, TaskId, Call, Full};
        miss ->
            findPendingTool(Rest)
    end;
findPendingTool([_ | Rest]) ->
    findPendingTool(Rest).

%% 从工具结果 content 提取 pending taskId；兼容 map 与 JSON binary 两种形态。
%% status 值经 JSON encode/decode 后为 <<"pending">>，须与原子 pending 同时识别。
pendingTaskId(Content) when is_map(Content) ->
    case isPendingStatus(maps:get(status, Content, maps:get(<<"status">>, Content, undefined))) of
        true ->
            {ok, maps:get(taskId, Content, maps:get(<<"taskId">>, Content, undefined))};
        false ->
            miss
    end;
pendingTaskId(Content) when is_binary(Content) ->
    try alJson:decode(Content) of
        Map when is_map(Map) ->
            case isPendingStatus(maps:get(<<"status">>, Map, maps:get(status, Map, undefined))) of
                true ->
                    {ok, maps:get(<<"taskId">>, Map, maps:get(taskId, Map, undefined))};
                false ->
                    miss
            end;
        _ ->
            miss
    catch
        _:_ -> miss
    end;
pendingTaskId(_) ->
    miss.

isPendingStatus(pending) -> true;
isPendingStatus(<<"pending">>) -> true;
isPendingStatus(_) -> false.

%%--------------------------------------------------------------------
%% @doc
%% 批量 dismiss 同一并行批次中除 KeepTaskId 之外的其余 pending 工具。
%% 扫描本轮 tool 结果消息，收集所有 `status => pending' 的 taskId，
%% 逐一驳回（KeepTaskId 已被挂起并附带续接，保留）。
%%
%% @param ToolResults 本轮工具结果消息列表
%% @param KeepTaskId  被挂起保留的 pending 任务 id
%% @return ok
%% @end
%%--------------------------------------------------------------------
dismissOtherPending(ToolResults, KeepTaskId) ->
    TaskIds = [Tid
               || #{content := C} <- ToolResults,
                  {ok, Tid} <- [pendingTaskId(C)]],
    lists:foreach(fun(Tid) ->
        case Tid =/= undefined andalso Tid =/= KeepTaskId of
            true ->
                try alPending:dismiss(Tid) catch _:_ -> ok end;
            false -> ok
        end
    end, TaskIds),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% 在消息列表中，把指定 tool_call_id 对应的 tool 消息内容替换为新内容。
%%
%% @param Messages 消息列表
%% @param ToolCallId 要替换的工具调用 id
%% @param NewContent 新的工具结果内容
%% @return 更新后的消息列表
%% @end
%%--------------------------------------------------------------------
replaceToolResult(Messages, ToolCallId, NewContent) ->
    [case Msg of
        #{role := tool, tool_call_id := Id} = M when Id =:= ToolCallId ->
            M#{content => NewContent};
        M ->
            M
     end || Msg <- Messages].

%%--------------------------------------------------------------------
%% @doc
%% 生成 pending 工具的提示答案文本，告诉用户某工具需要确认及其 TaskId。
%%
%% @param TaskId 待确认任务 id
%% @param Call 工具调用 map（取 function.name）
%% @param Result 原结果（保留参数）
%% @return 二进制提示文本
%% @end
%%--------------------------------------------------------------------
pendingAnswer(TaskId, #{function := #{name := Name}}, _Result) ->
    iolist_to_binary([
        <<"工具 "/utf8>>, Name, <<" 需要确认后才能执行。"/utf8>>,
        <<"TaskId: ">>, TaskId,
        <<"。ali:chat() 中直接回复「确认」/ yes / ok；"/utf8>>,
        <<"或在 shell 执行 ali:approve(\""/utf8>>, TaskId, <<"\") 继续。"/utf8>>
    ]).

%%--------------------------------------------------------------------
%% @doc
%% 解析 runMfa 参数：支持 module+function+args，或 call 简写（如 rid("YY1") /
%% player:get(Id)）。call 未带模块时用 runMfaDefaultModule。
%% @end
%%--------------------------------------------------------------------
resolveRunMfa(Args) when is_map(Args) ->
    case maps:get(call, Args, undefined) of
        undefined ->
            resolveRunMfaParts(
                maps:get(module, Args, undefined),
                maps:get(function, Args, undefined),
                maps:get(args, Args, [])
            );
        Call ->
            case parseCallExpr(Call) of
                {ok, Mod, Fun, CallArgs} ->
                    Mod1 = case Mod of
                        undefined -> maps:get(module, Args, undefined);
                        _ -> Mod
                    end,
                    Args1 = case maps:get(args, Args, undefined) of
                        undefined -> CallArgs;
                        Explicit when Explicit =/= [] -> Explicit;
                        _ -> CallArgs
                    end,
                    resolveRunMfaParts(Mod1, Fun, Args1);
                {error, Reason} ->
                    {error, Reason}
            end
    end.

resolveRunMfaParts(undefined, Fun, Args) ->
    case alConfig:get(runMfaDefaultModule, undefined) of
        undefined -> {error, missingModule};
        DefaultMod -> resolveRunMfaParts(DefaultMod, Fun, Args)
    end;
resolveRunMfaParts(_Mod, undefined, _Args) ->
    {error, missingFunction};
resolveRunMfaParts(Module, Function, Arguments) ->
    {ok, Module, Function, Arguments}.

%%--------------------------------------------------------------------
%% 写 MFA 闭环：可选强制 verifyRead；执行后自动回读。
%%--------------------------------------------------------------------
runMfaWithVerifyLoop(Args, Module, Function, Arguments, Timeout, Caller) ->
    IsWrite = alPolicy:isRunMfaWrite(Args),
    case IsWrite andalso requireVerifyRead() andalso extractVerifyRead(Args) =:= undefined of
        true ->
            {error, #{
                reason => verifyReadRequired,
                hint => <<"实况写入需要 verifyRead（只读 MFA），以便审批前快照、变更后回读。"
                          "示例：verifyRead => #{call => \"Mod:get(Id)\"} 或 "
                          "#{module => Mod, function => get, args => [Id]}。"/utf8>>
            }};
        false ->
            Before = case IsWrite of
                true -> snapshotVerifyRead(Args, Timeout, Caller);
                false -> undefined
            end,
            case alRuntimeProbe:runMfa(Module, Function, Arguments, Timeout, Caller) of
                {ok, WriteResult} ->
                    case IsWrite of
                        false ->
                            {ok, WriteResult};
                        true ->
                            After = snapshotVerifyRead(Args, Timeout, Caller),
                            Verified = case After of
                                #{value := _} -> true;
                                _ -> false
                            end,
                            {ok, #{
                                result => WriteResult,
                                beforeRead => Before,
                                afterRead => After,
                                verified => Verified,
                                sideEffect => write
                            }}
                    end;
                {error, _} = Err ->
                    Err
            end
    end.

requireVerifyRead() ->
    %% 默认关闭：写活数据不再强制 verifyRead；有则仍做 before/after 快照
    case alConfig:get(runMfaRequireVerifyRead, false) of
        true -> true;
        _ -> false
    end.

extractVerifyRead(Args) when is_map(Args) ->
    case maps:get(verifyRead, Args, maps:get(<<"verifyRead">>, Args, undefined)) of
        undefined -> undefined;
        Spec when is_map(Spec) -> Spec;
        Call when is_binary(Call); is_list(Call) -> #{call => Call};
        _ -> undefined
    end;
extractVerifyRead(_) -> undefined.

snapshotVerifyRead(Args, Timeout, Caller) ->
    case extractVerifyRead(Args) of
        undefined -> undefined;
        Spec ->
            case resolveRunMfa(Spec) of
                {ok, M, F, A} ->
                    case alRuntimeProbe:runMfa(M, F, A, Timeout, Caller) of
                        {ok, V} -> #{mfa => formatMfa(M, F, A), value => V};
                        {error, Reason} -> #{mfa => formatMfa(M, F, A), error => Reason}
                    end;
                {error, Reason} ->
                    #{error => Reason}
            end
    end.

formatMfa(M, F, A) ->
    iolist_to_binary([toBin(M), <<":">>, toBin(F), <<"/">>,
                      integer_to_binary(length(ensureList(A)))]).

ensureList(L) when is_list(L) -> L;
ensureList(_) -> [].

toBin(B) when is_binary(B) -> B;
toBin(A) when is_atom(A) -> atom_to_binary(A, utf8);
toBin(L) when is_list(L) -> unicode:characters_to_binary(L);
toBin(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).

%% 审批预览：patch/writeFile 用 diff；runMfa 写带 before 快照。
approvalPreview(runMfa, Args) ->
    Diff = try alPending:buildDiff(runMfa, Args) catch _:_ -> <<>> end,
    Before = case alPolicy:isRunMfaWrite(Args) of
        true -> snapshotVerifyRead(Args, maps:get(timeout, Args, 5000), interactive);
        false -> undefined
    end,
    #{
        message => <<"approval required for live MFA write">>,
        diff => Diff,
        beforeRead => Before,
        verifyRead => extractVerifyRead(Args)
    };
approvalPreview(Tool, Args) ->
    Diff = try alPending:buildDiff(Tool, Args) catch _:_ -> <<>> end,
    case Diff of
        <<>> -> #{message => <<"approval required">>};
        _ -> #{message => <<"approval required">>, diff => Diff}
    end.

%% 用 erl_scan/erl_parse 解析 `Mod:Fun(A,...)` 或 `Fun(A,...)`。
parseCallExpr(Call0) ->
    Call = string:trim(callToList(Call0)),
    Src = Call ++ ".",
    case erl_scan:string(Src) of
        {ok, Tokens, _} ->
            case erl_parse:parse_exprs(Tokens) of
                {ok, [Expr]} ->
                    exprToMfa(Expr);
                {ok, _} ->
                    {error, badCall};
                {error, _} ->
                    {error, badCall}
            end;
        {error, _, _} ->
            {error, badCall}
    end.

exprToMfa({call, _, {remote, _, {atom, _, Mod}, {atom, _, Fun}}, Args}) ->
    case literalArgs(Args) of
        error -> {error, badCall};
        Terms -> {ok, Mod, Fun, Terms}
    end;
exprToMfa({call, _, {atom, _, Fun}, Args}) ->
    case literalArgs(Args) of
        error -> {error, badCall};
        Terms -> {ok, undefined, Fun, Terms}
    end;
exprToMfa(_) ->
    {error, badCall}.

literalArgs(Args) ->
    literalArgs(Args, []).

literalArgs([], Acc) ->
    lists:reverse(Acc);
literalArgs([A | Rest], Acc) ->
    case literalToTerm(A) of
        error -> error;
        Term -> literalArgs(Rest, [Term | Acc])
    end.

%% 只解析纯字面量 AST；任何可能执行代码的节点（call/var/bin 表达式段等）
%% 一律返回 error，绝不再经 erl_eval 求值，杜绝提示注入执行任意 Erlang 代码。
literalToTerm({string, _, S}) -> S;
literalToTerm({atom, _, A}) -> A;
literalToTerm({integer, _, I}) -> I;
literalToTerm({float, _, F}) -> F;
literalToTerm({char, _, C}) -> C;
literalToTerm({nil, _}) -> [];
literalToTerm({cons, _, H, T}) ->
    case literalToTerm(H) of
        error -> error;
        H1 ->
            case literalToTerm(T) of
                error -> error;
                T1 -> [H1 | T1]
            end
    end;
literalToTerm({tuple, _, Els}) ->
    literalTerms(Els, []);
literalToTerm({map, _, Assocs}) ->
    literalMap(Assocs, #{});
literalToTerm({bin, _, Els}) ->
    literalBin(Els, <<>>);
literalToTerm({op, _, '-', {integer, _, I}}) -> -I;
literalToTerm({op, _, '-', {float, _, F}}) -> -F;
literalToTerm(_Other) -> error.

literalTerms([], Acc) ->
    list_to_tuple(lists:reverse(Acc));
literalTerms([E | Rest], Acc) ->
    case literalToTerm(E) of
        error -> error;
        Term -> literalTerms(Rest, [Term | Acc])
    end.

literalMap([], Acc) ->
    Acc;
literalMap([{map_field_assoc, _, K, V} | Rest], Acc) ->
    literalMapField(Rest, K, V, Acc);
literalMap([{map_field_exact, _, K, V} | Rest], Acc) ->
    literalMapField(Rest, K, V, Acc);
literalMap([_ | _], _Acc) ->
    error.

literalMapField(Rest, K, V, Acc) ->
    case literalToTerm(K) of
        error -> error;
        K1 ->
            case literalToTerm(V) of
                error -> error;
                V1 -> literalMap(Rest, Acc#{K1 => V1})
            end
    end.

%% 二进制字面量只接受纯字面量段（string/integer/char/嵌套 bin），
%% 遇到表达式段（如 <<(os:cmd(...))>>）返回 error。
literalBin([], Acc) ->
    Acc;
literalBin([{bin_element, _, Expr, default, default} | Rest], Acc) ->
    case literalBinValue(Expr) of
        error -> error;
        V -> literalBin(Rest, <<Acc/binary, V/binary>>)
    end;
literalBin(_, _) ->
    error.

literalBinValue({string, _, S}) -> unicode:characters_to_binary(S);
literalBinValue({integer, _, I}) when I >= 0, I =< 255 -> <<I>>;
literalBinValue({char, _, C}) when C >= 0, C =< 255 -> <<C>>;
literalBinValue({bin, _, Els}) -> literalBin(Els, <<>>);
literalBinValue(_) -> error.

callToList(V) when is_list(V) -> V;
callToList(V) when is_binary(V) -> unicode:characters_to_list(V);
callToList(V) when is_atom(V) -> atom_to_list(V);
callToList(V) -> lists:flatten(io_lib:format("~ts", [V])).

resolveModulePath(Module0) ->
    Module = stripModuleExt(Module0),
    case extractCoreModuleFile(Module) of
        {ok, File} ->
            okPath(Module, File, aliCore);
        {error, _} ->
            case findModuleOnFilesystem(Module) of
                {ok, File} ->
                    okPath(Module, File, filesystem);
                {error, notFound} ->
                    {error, #{
                        reason => moduleNotFound,
                        module => Module,
                        hint => <<"索引可能过期。请 /index，或 searchCode "
                                  "\"-module(NAME)\"。不要仅凭一次局部命中"
                                  "（如只有 *_port.erl）就断定模块缺失。"/utf8>>,
                        tried => [aliCore, filesystem, codeWhich]
                    }};
                {error, {notFound, Cands}} ->
                    {error, #{
                        reason => moduleNotFound,
                        module => Module,
                        candidates => [relativePath(C) || C <- Cands],
                        hint => <<"索引可能过期。请 /index，或用 listFiles(glob=...) "
                                  "进一步定位。"/utf8>>,
                        tried => [aliCore, filesystem, codeWhich, fuzzyWildcard]
                    }}
            end
    end.

okPath(Module, File, Source) ->
    Rel = relativePath(File),
    {ok, #{
        module => Module,
        file => Rel,
        absFile => File,
        source => Source,
        hint => <<"用该 file 调用 readFile；不要臆造路径"/utf8>>
    }}.

%% 模块名归一化：atom/binary → list，去 .erl/.hrl 后缀，转小写，trim。
normalizeModuleName(M) when is_atom(M) ->
    normalizeModuleName(atom_to_list(M));
normalizeModuleName(M) when is_binary(M) ->
    normalizeModuleName(unicode:characters_to_list(M));
normalizeModuleName(M) when is_list(M) ->
    Lower = string:lowercase(string:trim(M)),
    case lists:reverse(Lower) of
        "lre." ++ Rest -> lists:reverse(Rest);
        "lrh." ++ Rest -> lists:reverse(Rest);
        _ -> Lower
    end;
normalizeModuleName(_) -> "".

stripModuleExt(M) ->
    case normalizeModuleName(M) of
        "" -> M;
        Name when is_list(Name) ->
            try list_to_existing_atom(Name) catch _:_ -> Name end
    end.

%% 索引未命中时：code:which → 推 src；再在 codeRoots 下通配 **/Name.erl
findModuleOnFilesystem(Module0) ->
    Name = normalizeModuleName(Module0),
    case Name =:= "" of
        true -> {error, notFound};
        false ->
            case findViaCodeWhich(Name) of
                {ok, _} = Ok -> Ok;
                {error, _} ->
                    case findViaWildcard(Name) of
                        {ok, _} = Ok -> Ok;
                        {error, notFound} ->
                            Cands = findViaFuzzyWildcard(Name),
                            case Cands of
                                [] -> {error, notFound};
                                _ -> {error, {notFound, Cands}}
                            end
                    end
            end
    end.

findViaCodeWhich(Name) ->
    ModAtom = try list_to_existing_atom(Name) catch _:_ ->
        case Name =/= "" andalso length(Name) =< 255 andalso
             re:run(Name, <<"^[a-z][A-Za-z0-9_]*$">>, [{capture, none}]) =:= match of
            true -> list_to_atom(Name);
            false -> undefined
        end
    end,
    case ModAtom of
        undefined -> {error, notFound};
        A ->
            case code:which(A) of
                Beam when is_list(Beam), Beam =/= non_existing ->
                    case beamToSrcCandidates(Beam, Name) of
                        [F | _] -> {ok, F};
                        [] -> {error, notFound}
                    end;
                _ ->
                    {error, notFound}
            end
    end.

beamToSrcCandidates(Beam, Name) ->
    Dir = filename:dirname(Beam),
    BaseErl = Name ++ ".erl",
    Cands = [
        filename:join(Dir, BaseErl),
        filename:join([filename:dirname(Dir), "src", BaseErl]),
        filename:join([filename:dirname(Dir), "src", Name, BaseErl]),
        filename:join([filename:dirname(filename:dirname(Dir)), "src", BaseErl])
    ],
    %% 再从 beam 目录向上扫一层常见 src
    Up = filename:join([filename:dirname(Dir), "**", BaseErl]),
    Extra = try filelib:wildcard(Up) catch _:_ -> [] end,
    lists:filter(fun filelib:is_file/1, Cands ++ lists:sublist(Extra, 5)).

findViaWildcard(Name) ->
    BaseErl = Name ++ ".erl",
    Roots = try alConfig:codeRoots() catch _:_ ->
        try [alConfig:projectRoot()] catch _:_ -> ["."] end
    end,
    Matches = lists:flatmap(fun(Root) ->
        %% 优先常见源码子树，避免扫整个资源仓
        SubRoots = [Root] ++
            [filename:join(Root, D) || D <- ["plugin", "src", "apps", "lib"],
             filelib:is_dir(filename:join(Root, D))],
        lists:flatmap(fun(R) ->
            try filelib:wildcard(filename:join([R, "**", BaseErl]))
            catch _:_ -> [] end
        end, lists:usort(SubRoots))
    end, Roots),
    Prefer = [M || M <- Matches, string:find(string:lowercase(M), "_build") =:= nomatch],
    case Prefer ++ (Matches -- Prefer) of
        [F | _] -> {ok, F};
        [] -> {error, notFound}
    end.

%% Fuzzy fallback: 找到可能的同名/近似模块文件，给候选列表，避免模型因一次 notFound 而打转。
%% 代价：仅在精确匹配失败时触发，且只在常见代码子树下扫。
findViaFuzzyWildcard(Name) ->
    try
        Roots = alConfig:codeRoots(),
        SubRoots = lists:flatmap(fun(Root) ->
            [Root] ++
            [filename:join(Root, D) || D <- ["plugin", "src", "apps", "lib"],
                                     filelib:is_dir(filename:join(Root, D))]
        end, Roots),
        Pattern0 = lists:usort(SubRoots),
        Pattern = lists:flatmap(fun(R) ->
            %% 形如 **/*Name*.erl 的粗匹配；再按 basename 相似度排序裁剪。
            filelib:wildcard(filename:join([R, "**", "*" ++ Name ++ "*.erl"]))
        end, Pattern0),
        %% 去掉构建目录；按 basename 相似度降序裁剪。
        C0 = [F || F <- Pattern,
                   string:find(string:lowercase(F), "_build") =:= nomatch],
        NameLow = string:lowercase(Name),
        Ranked = lists:sort(fun(A, B) ->
            scoreFuzzyCandidate(A, NameLow) >= scoreFuzzyCandidate(B, NameLow)
        end, C0),
        lists:sublist(Ranked, 8)
    catch
        _:_ -> []
    end.

scoreFuzzyCandidate(Path, NameLow) ->
    Base = string:lowercase(filename:basename(Path)),
    Erl = NameLow ++ ".erl",
    Hrl = NameLow ++ ".hrl",
    case Base of
        _ when Base =:= Erl -> 100;
        _ when Base =:= Hrl -> 95;
        _ ->
            case string:find(Base, NameLow) of
                nomatch -> 10;
                _ -> 50
            end
    end.

%%--------------------------------------------------------------------
%% Go to definition: resolve file + symbol line range for Mod:Fun/Arity.
%%--------------------------------------------------------------------
gotoDefinition(Module, Function, Arity, Args) ->
    Opts = snippetEnrichOpts(Args),
    FileInfo = case Module of
        undefined -> #{};
        _ ->
            case resolveModulePath(Module) of
                {ok, M} -> M;
                {error, _} -> #{}
            end
    end,
    Sym = lookupSymbol(Module, Function, Arity),
    Result = case {maps:get(file, FileInfo, undefined), Sym} of
        {undefined, {error, Reason}} ->
            {error, #{reason => Reason, module => Module, function => Function, arity => Arity}};
        {File, {ok, Loc}} ->
            {ok, maps:merge(#{
                module => Module,
                function => Function,
                arity => toIntegerArity(Arity),
                file => File,
                absFile => maps:get(absFile, FileInfo, undefined)
            }, Loc)};
        {undefined, {ok, Loc}} ->
            {ok, maps:merge(#{
                module => Module,
                function => Function,
                arity => toIntegerArity(Arity)
            }, Loc)};
        {File, {error, _}} ->
            {ok, #{
                module => Module,
                function => Function,
                arity => toIntegerArity(Arity),
                file => File,
                absFile => maps:get(absFile, FileInfo, undefined)
            }}
    end,
    case Result of
        {ok, LocMap} ->
            {ok, alToolsExt:enrichLocMap(LocMap, Opts)};
        Other ->
            Other
    end.

lookupSymbol(Module, Function, Arity) ->
    ArityN = toIntegerArity(Arity),
    case coreCall(fun() -> alCoreClient:getSymbol(Module, Function, ArityN) end) of
        {ok, Result} ->
            case symbolLocFromResult(Result) of
                undefined ->
                    lookupSymbolFromModule(Module, Function, ArityN);
                Loc ->
                    {ok, Loc}
            end;
        {error, _} ->
            lookupSymbolFromModule(Module, Function, ArityN)
    end.

lookupSymbolFromModule(undefined, _Function, _Arity) ->
    {error, symbolNotFound};
lookupSymbolFromModule(Module, Function, Arity) ->
    case coreCall(fun() -> alCoreClient:moduleSymbols(Module) end) of
        {ok, Result} ->
            case findFunInSymbols(Result, Function, Arity) of
                undefined -> {error, symbolNotFound};
                Loc -> {ok, Loc}
            end;
        {error, _} ->
            {error, symbolNotFound}
    end.

symbolLocFromResult(Result) when is_map(Result) ->
    Sym = firstDefined([
        maps:get(symbol, Result, undefined),
        maps:get(<<"symbol">>, Result, undefined),
        begin
            Data = maps:get(data, Result, maps:get(<<"data">>, Result, undefined)),
            case Data of
                DataMap when is_map(DataMap) ->
                    maps:get(symbol, DataMap, maps:get(<<"symbol">>, DataMap, undefined));
                _ -> undefined
            end
        end
    ]),
    case Sym of
        SymMap when is_map(SymMap) -> locFromFunMap(SymMap);
        _ -> undefined
    end;
symbolLocFromResult(_) ->
    undefined.

findFunInSymbols(Result, Function, Arity) ->
    Doc = firstDefined([
        maps:get(document, Result, undefined),
        maps:get(<<"document">>, Result, undefined),
        begin
            Data = maps:get(data, Result, maps:get(<<"data">>, Result, undefined)),
            case Data of
                DataMap when is_map(DataMap) ->
                    maps:get(document, DataMap, maps:get(<<"document">>, DataMap, undefined));
                _ -> undefined
            end
        end
    ]),
    Funs = case Doc of
        DocMap when is_map(DocMap) ->
            maps:get(functions, DocMap, maps:get(<<"functions">>, DocMap, []));
        _ ->
            maps:get(functions, Result, maps:get(<<"functions">>, Result, []))
    end,
    TargetName = to_binary(Function),
    case is_list(Funs) of
        true ->
            case lists:filter(fun(F) when is_map(F) ->
                                      Name = maps:get(name, F, maps:get(<<"name">>, F, undefined)),
                                      Ar = maps:get(arity, F, maps:get(<<"arity">>, F, undefined)),
                                      to_binary(Name) =:= TargetName
                                          andalso toIntegerArity(Ar) =:= Arity;
                                  (_) -> false
                              end, Funs) of
                [F | _] -> locFromFunMap(F);
                [] -> undefined
            end;
        false ->
            undefined
    end.

locFromFunMap(M) when is_map(M) ->
    Line = firstDefined([
        maps:get(line, M, undefined),
        maps:get(<<"line">>, M, undefined),
        maps:get(start_line, M, undefined),
        maps:get(<<"start_line">>, M, undefined)
    ]),
    Start = firstDefined([
        maps:get(start_line, M, undefined),
        maps:get(<<"start_line">>, M, undefined),
        Line
    ]),
    End = firstDefined([
        maps:get(end_line, M, undefined),
        maps:get(<<"end_line">>, M, undefined),
        Start
    ]),
    case Line of
        undefined -> undefined;
        _ ->
            #{
                line => toIntegerArity(Line),
                start_line => toIntegerArity(Start),
                end_line => toIntegerArity(End)
            }
    end;
locFromFunMap(_) ->
    undefined.

firstDefined([]) -> undefined;
firstDefined([undefined | Rest]) -> firstDefined(Rest);
firstDefined([null | Rest]) -> firstDefined(Rest);
firstDefined([V | _]) -> V.

toIntegerArity(A) when is_integer(A) -> A;
toIntegerArity(A) when is_binary(A) ->
    try binary_to_integer(A) catch _:_ -> 0 end;
toIntegerArity(A) when is_list(A) ->
    try list_to_integer(A) catch _:_ -> 0 end;
toIntegerArity(_) -> 0.

toPositiveInt(V, Default) ->
    case toIntegerArity(V) of
        N when is_integer(N), N > 0 -> N;
        _ -> Default
    end.

putIf(Map, _Key, undefined) -> Map;
putIf(Map, _Key, <<>>) -> Map;
putIf(Map, _Key, "") -> Map;
putIf(Map, Key, Value) -> Map#{Key => Value}.

snippetEnrichOpts(Args) when is_map(Args) ->
    #{
        context => toPositiveInt(maps:get(context, Args, maps:get(<<"context">>, Args, 3)), 3),
        %% searchCode / gotoDef / getSymbol：默认仍附源码预览
        includeSource => maps:get(includeSource, Args, maps:get(<<"includeSource">>, Args, true))
    };
snippetEnrichOpts(_) ->
    #{context => 3, includeSource => true}.

%% 分页：format=edges 时使用；默认 limit=80。
callEdgePageArgs(Args) ->
    Limit = min(200, toPositiveInt(
        maps:get(limit, Args, maps:get(<<"limit">>, Args, 80)), 80)),
    Offset = max(0, toNonNegInt(
        maps:get(offset, Args, maps:get(<<"offset">>, Args, 0)), 0)),
    {Offset, Limit}.

toNonNegInt(V, _Default) when is_integer(V), V >= 0 -> V;
toNonNegInt(V, Default) when is_binary(V) ->
    try binary_to_integer(V) of
        N when N >= 0 -> N;
        _ -> Default
    catch _:_ -> Default
    end;
toNonNegInt(_, Default) -> Default.

includeMermaidFlag(Args) ->
    case maps:get(includeMermaid, Args, maps:get(<<"includeMermaid">>, Args, false)) of
        true -> true;
        <<"true">> -> true;
        _ -> false
    end.

%% 打包调用边：本地聚合 byModule 摘要（省 token），默认不塞完整 edges/源码。
packCallEdges(Kind, Module, Function, Arity, Edges0, Args) when is_list(Edges0) ->
    Total = length(Edges0),
    WantSource = maps:get(includeSource, Args, maps:get(<<"includeSource">>, Args, false)) =:= true
        orelse maps:get(includeSource, Args, maps:get(<<"includeSource">>, Args, false)) =:= <<"true">>,
    %% 边多时强制不带源码——源码请对单点 gotoDef/readFile
    AllowSource = WantSource andalso Total =< 12,
    EnrichOpts = #{
        context => toPositiveInt(maps:get(context, Args, maps:get(<<"context">>, Args, 2)), 2),
        includeSource => AllowSource
    },
    ByModule = aggregateCallersByModule(Edges0),
    MfaBin = formatMfaBin(Module, Function, Arity),
    Detail = wantsCallEdgeDetail(Args),
    Base0 = #{
        kind => Kind,
        mfa => MfaBin,
        totalCount => Total,
        moduleCount => length(ByModule),
        byModule => ByModule,
        sourceIncluded => AllowSource,
        hint => callEdgeHint(Kind, Total, AllowSource, WantSource, Detail)
    },
    Base1 = case Detail of
        true ->
            {Offset, Limit} = callEdgePageArgs(Args),
            Page0 = case Offset >= Total of
                true -> [];
                false -> lists:sublist(lists:nthtail(Offset, Edges0), Limit)
            end,
            Page = [enrichRefEdge(E, EnrichOpts) || E <- Page0],
            Base0#{
                edges => Page,
                edgeCount => length(Page),
                offset => Offset,
                limit => Limit,
                truncated => Offset + length(Page) < Total
            };
        false ->
            Base0#{format => summary}
    end,
    case includeMermaidFlag(Args) of
        true ->
            %% mermaid 很吃 token，最多 25 边
            Base1#{mermaid => alDocGen:mermaidCallEdges(Edges0, min(25, Total))};
        false ->
            Base1
    end;
packCallEdges(Kind, Module, Function, Arity, _, Args) ->
    packCallEdges(Kind, Module, Function, Arity, [], Args).

wantsCallEdgeDetail(Args) ->
    case maps:get(format, Args, maps:get(<<"format">>, Args, undefined)) of
        edges -> true;
        <<"edges">> -> true;
        full -> true;
        <<"full">> -> true;
        detail -> true;
        <<"detail">> -> true;
        _ ->
            case maps:get(detail, Args, maps:get(<<"detail">>, Args, false)) of
                true -> true;
                <<"true">> -> true;
                _ -> false
            end
    end.

callEdgeHint(_Kind, 0, _, _, _) ->
    <<"无调用边。请确认索引已就绪（/index），或检查 MFA。"/utf8>>;
callEdgeHint(Kind, Total, AllowSource, WantSource, Detail) ->
    %% io_lib:format 对中文会产生 >255 的 Unicode 码点列表；与 binary 混成 iolist 后
    %% iolist_to_binary 会 badarg。必须用 unicode:characters_to_binary。
    Parts0 = [io_lib:format("本地已聚合 ~p 处（byModule）。请直接据此作答。", [Total])],
    Parts1 = case Kind of
        getCallers -> [Parts0, <<"禁止再逐文件 searchText/resolveModule 复核调用点。"/utf8>>];
        findRefs -> [Parts0, <<"禁止再逐文件 searchText 复核。"/utf8>>];
        _ -> Parts0
    end,
    Parts2 = case {WantSource, AllowSource} of
        {true, false} ->
            [Parts1, <<"边数较多已跳过 includeSource；要对某点看源码请 gotoDef。"/utf8>>];
        _ -> Parts1
    end,
    Parts3 = case Detail of
        false -> [Parts2, <<"需要原始 edges 时再传 format=edges。"/utf8>>];
        true -> Parts2
    end,
    case unicode:characters_to_binary(Parts3) of
        Bin when is_binary(Bin) -> Bin;
        {error, Good, _} -> to_binary(Good);
        {incomplete, Good, _} -> to_binary(Good)
    end.

formatMfaBin(Module, Function, Arity) ->
    iolist_to_binary(io_lib:format("~s:~s/~p",
        [to_binary(Module), to_binary(Function), toIntegerArity(Arity)])).

%% 按调用方模块聚合：[{mod, n, file?, sites:[<<"fun/arity@line">>, ...]}]
aggregateCallersByModule(Edges) ->
    Groups = lists:foldl(fun(E, Acc) ->
        N = normalizeEdgeKeys(E),
        Mod = case maps:get(from_module, N, undefined) of
            undefined -> <<"?">>;
            M -> to_binary(M)
        end,
        Fun = case maps:get(from_function, N, undefined) of
            undefined -> <<"?">>;
            F -> to_binary(F)
        end,
        Ar = case maps:get(from_arity, N, undefined) of
            A when is_integer(A) -> A;
            _ -> 0
        end,
        Line = case maps:get(line, N, undefined) of
            L when is_integer(L) -> L;
            _ -> 0
        end,
        File = maps:get(file, N, undefined),
        Site = iolist_to_binary(io_lib:format("~s/~p@~p", [Fun, Ar, Line])),
        {Sites0, File0} = maps:get(Mod, Acc, {[], File}),
        Acc#{Mod => {[Site | Sites0], case File0 of undefined -> File; _ -> File0 end}}
    end, #{}, Edges),
    lists:sort(fun(A, B) ->
        maps:get(n, A, 0) >= maps:get(n, B, 0)
    end, [
        begin
            Sites = lists:usort(lists:reverse(SitesRev)),
            Base = #{mod => Mod, n => length(Sites), sites => Sites},
            File1 = case File of
                undefined ->
                    case resolveModulePath(Mod) of
                        {ok, #{file := Resolved}} -> Resolved;
                        _ -> undefined
                    end;
                Existing -> Existing
            end,
            case File1 of
                undefined -> Base;
                Path when Path =/= undefined -> Base#{file => Path}
            end
        end
     || {Mod, {SitesRev, File}} <- maps:to_list(Groups)]).

%%--------------------------------------------------------------------
%% Find references: 本地聚合摘要（与 getCallers 同策略，省 token）。
%%--------------------------------------------------------------------
findReferences(Module, Function, Arity, Args) ->
    case coreCall(fun() -> alCoreClient:getCallers(Module, Function, Arity) end) of
        {ok, Wrap} ->
            Result = unwrapCoreData(Wrap),
            Edges0 = coreEdges(Result),
            Packed = packCallEdges(findRefs, Module, Function, Arity, Edges0, Args),
            TargetFile = case Module of
                undefined -> undefined;
                _ ->
                    case resolveModulePath(Module) of
                        {ok, #{file := F}} -> F;
                        _ -> undefined
                    end
            end,
            %% 兼容旧字段名 refs：detail 时从 edges 映射；摘要模式用 byModule
            Out0 = Packed#{
                module => Module,
                function => Function,
                arity => toIntegerArity(Arity),
                file => TargetFile,
                count => maps:get(totalCount, Packed, 0)
            },
            Out1 = case maps:get(edges, Out0, undefined) of
                Edges when is_list(Edges) -> Out0#{refs => Edges};
                _ -> Out0
            end,
            {ok, Out1};
        {error, Reason} ->
            {error, #{reason => Reason}}
    end.

enrichRefEdge(Edge, Opts) when is_map(Edge) ->
    FromMod = firstDefined([
        maps:get(from_module, Edge, undefined),
        maps:get(<<"from_module">>, Edge, undefined),
        maps:get(fromModule, Edge, undefined)
    ]),
    FromFun = firstDefined([
        maps:get(from_function, Edge, undefined),
        maps:get(<<"from_function">>, Edge, undefined),
        maps:get(fromFunction, Edge, undefined)
    ]),
    FromArity = firstDefined([
        maps:get(from_arity, Edge, undefined),
        maps:get(<<"from_arity">>, Edge, undefined),
        maps:get(fromArity, Edge, undefined)
    ]),
    Line = firstDefined([
        maps:get(line, Edge, undefined),
        maps:get(<<"line">>, Edge, undefined)
    ]),
    File = case maps:get(file, Edge, maps:get(<<"file">>, Edge, undefined)) of
        F0 when F0 =/= undefined, F0 =/= <<>>, F0 =/= "" -> F0;
        _ ->
            case FromMod of
                undefined -> undefined;
                _ ->
                    case resolveModulePath(FromMod) of
                        {ok, #{file := F}} -> F;
                        _ -> undefined
                    end
            end
    end,
    Base = Edge#{
        file => File,
        from_module => FromMod,
        from_function => FromFun,
        from_arity => FromArity,
        line => Line
    },
    case maps:get(includeSource, Opts, false) of
        true ->
            case {File, Line} of
                {FilePath, L} when FilePath =/= undefined, is_integer(L), L >= 1 ->
                    case alToolsExt:sourceSnippet(#{path => FilePath, line => L,
                                                    context => maps:get(context, Opts, 3)}) of
                        {ok, Snip} ->
                            Base#{
                                sourcePreview => maps:get(source, Snip, maps:get(content, Snip)),
                                sourceStartLine => maps:get(startLine, Snip, undefined),
                                sourceEndLine => maps:get(endLine, Snip, undefined)
                            };
                        _ ->
                            Base
                    end;
                _ ->
                    Base
            end;
        _ ->
            %% 去掉可能残留的大字段，保持列表紧凑
            maps:without([sourcePreview, sourceStartLine, sourceEndLine, source], Base)
    end;
enrichRefEdge(Edge, _Opts) ->
    Edge.

extractCoreModuleFile(Module) ->
    case coreCall(fun() -> alCoreClient:moduleSymbols(Module) end) of
        {ok, Result} when is_map(Result) ->
            case fileFromModuleSymbolsResult(Result) of
                undefined -> {error, noFile};
                File -> {ok, File}
            end;
        _ ->
            {error, coreUnavailable}
    end.

fileFromModuleSymbolsResult(Result) ->
    Candidates = [
        maps:get(file, Result, undefined),
        maps:get(<<"file">>, Result, undefined),
        nestedFile(maps:get(document, Result, undefined)),
        nestedFile(maps:get(<<"document">>, Result, undefined)),
        nestedFile(maps:get(data, Result, undefined)),
        nestedFile(maps:get(<<"data">>, Result, undefined))
    ],
    case [F || F <- Candidates, F =/= undefined, F =/= null, F =/= <<>>, F =/= ""] of
        [File | _] -> File;
        [] -> undefined
    end.

nestedFile(undefined) -> undefined;
nestedFile(null) -> undefined;
nestedFile(Map) when is_map(Map) ->
    case maps:get(file, Map, maps:get(<<"file">>, Map, undefined)) of
        undefined ->
            nestedFile(maps:get(document, Map, maps:get(<<"document">>, Map, undefined)));
        File ->
            File
    end;
nestedFile(_) ->
    undefined.

relativizeModuleSymbols(Result) when is_map(Result) ->
    case fileFromModuleSymbolsResult(Result) of
        undefined -> Result;
        File ->
            Rel = relativePath(File),
            %% 顶层补相对路径，方便 LLM 直接 readFile
            Result#{file => Rel, absFile => File}
    end;
relativizeModuleSymbols(Other) ->
    Other.

relativePath(Path) ->
    alContextEngine:relativePath(Path).

%%--------------------------------------------------------------------
%% @doc
%% 值 → binary：二进制原样、整数转 binary、atom 转 UTF-8、list 编
%% 码为 UTF-8 binary，其它走 ~p 格式化。
%%
%% @param V 任意值
%% @return binary
%% @end
%%--------------------------------------------------------------------
to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_integer(V) -> integer_to_binary(V);
to_binary(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_binary(V) when is_list(V) -> unicode:characters_to_binary(V);
to_binary(V) -> unicode:characters_to_binary(io_lib:format("~p", [V])).

%%--------------------------------------------------------------------
%% @doc
%% 生成新的 TaskId（binary），由 monotonic unique_integer 派生。
%%
%% @return task id binary
%% @end
%%--------------------------------------------------------------------
makeTaskId() ->
    integer_to_binary(erlang:unique_integer([positive, monotonic])).
