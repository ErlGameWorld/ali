%%%-------------------------------------------------------------------
%% @doc 带 LLM 工具循环、critic、记忆与仿真钩子的 Agent。
%% @end
%%%-------------------------------------------------------------------

-module(alAgent).

-export([run/2, resumeAfterApproval/3]).
%% Test exports
-export([isCodeEditIntent/1, isLiveDataQuestion/1, isTrivialChat/1, maybePromoteEditMode/2,
         maybeSemanticCacheHit/2, answerText/1, cacheAnchorFiles/1]).

%%--------------------------------------------------------------------
%% @doc
%% Agent 主入口：执行带工具的 LLM 循环，再走 critic 复审，最终落库记忆与会话消息。
%%
%% @param Question 用户问题
%% @param Opts 选项映射（可包含 sessionId、maxToolSteps、maxCriticRounds 等）
%% @return {ok, ResultMap} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
run(Question, Opts) ->
    case isBlankPrompt(Question) of
        true -> {error, emptyPrompt};
        false -> doRun(Question, Opts)
    end.

doRun(Question, Opts) ->
    AgentCfg = alConfig:getAgentCfg(),
    OptsPromoted = maybePromoteEditMode(Question, Opts),
    Mode = maps:get(mode, OptsPromoted, ask),
    BasePolicy = maps:get(policy, OptsPromoted,
                          maps:get(policy, AgentCfg, alPolicy:defaultPolicy())),
    Policy = maps:merge(BasePolicy, alPolicy:policyForMode(Mode)),
    Opts0 = OptsPromoted#{agentCfg => AgentCfg, policy => Policy, mode => Mode},
    case ensureSession(Opts0) of
        {ok, Opts1} ->
            runWithSession(Question, Opts1, AgentCfg);
        {error, Reason} ->
            {error, Reason}
    end.

%% 会话已就绪后执行工具循环、critic 复审与记忆流程。
runWithSession(Question, Opts1, AgentCfg) ->
    SessionId = maps:get(sessionId, Opts1, undefined),
    MaxToolSteps0 = maps:get(maxToolSteps, Opts1, maps:get(maxSteps, AgentCfg, 50)),
    %% 唯一复审开关：0=关；>0=同步复审后再展示（展示的就是审完的答案）。
    MaxCriticRounds0 = maps:get(maxCriticRounds, Opts1,
                           maps:get(maxCriticRounds, AgentCfg, 3)),
    %% 运行时查/改数据：跳过 critic；并提高工具步数上限
    %% 改码升档时保留 critic（有助于审查补丁叙述）
    %% 问候短句：无工具、无 critic
    {MaxToolSteps, MaxCriticRounds} = case {isTrivialChat(Question),
                                           isLiveDataQuestion(Question),
                                           maps:get(modePromoted, Opts1, false)} of
        {true, _, _} -> {0, 0};
        {false, true, false} -> {max(MaxToolSteps0, 80), 0};
        _ -> {MaxToolSteps0, MaxCriticRounds0}
    end,
    maybeAppendMessage(SessionId, Opts1, #{role => user, content => Question}),
    case maybeSemanticCacheHit(Question, Opts1) of
        {ok, Cached} ->
            %% 语义缓存命中：零 LLM 调用直接返回（引用文件未变更才可能命中）。
            maybeAppendMessage(SessionId, Opts1, #{role => assistant, content => Cached}),
            {ok, #{answer => Cached, cached => true, sessionId => SessionId}};
        miss ->
            runWithToolsAndCritic(Question, Opts1, SessionId,
                                  MaxToolSteps, MaxCriticRounds)
    end.

%% 完整问答流程：工具循环 + critic 复审 + 记忆/经验/缓存沉淀。
runWithToolsAndCritic(Question, Opts1, SessionId, MaxToolSteps, MaxCriticRounds) ->
    Opts2 = maybeSeedPlan(SessionId, Question, Opts1),
    RunOpts = case isTrivialChat(Question) of
        true ->
            Opts2#{
                maxToolSteps => 0,
                tools => false,
                includeMemory => false,
                skipQueryLlm => true
            };
        false ->
            Opts2#{
                maxToolSteps => MaxToolSteps,
                includeMemory => maps:get(includeMemory, Opts2, true)
            }
    end,
    case alToolRouter:runWithTools(Question, RunOpts) of
        {ok, #{answer := Draft} = ToolResult} ->
            Trace = maps:get(trace, ToolResult, []),
            Context = maps:get(context, ToolResult, #{}),
            ToolCalls = maps:get(toolCalls, ToolResult, []),
            case MaxCriticRounds > 0 of
                true ->
                    emitAgentProgress(Opts1, #{
                        type => step, phase => critic,
                        message => <<"正在复审草稿，通过后才作为最终答案…"/utf8>>
                    });
                false ->
                    ok
            end,
            {ok, CritiqueLoop} = alCritic:reviewLoop(
                Question,
                Draft,
                enrichCriticContext(Context#{agentTrace => Trace}, Question, Opts1),
                Opts1#{maxCriticRounds => MaxCriticRounds, llmRole => critic}
            ),
            {Final0, Critique, ToolResult1} =
                maybeRerunToolsAfterCriticReject(
                    Question, Draft, ToolResult, CritiqueLoop, Opts1,
                    SessionId, MaxToolSteps, MaxCriticRounds),
            Final = markCriticWarning(Final0, Critique),
            Trace1 = maps:get(trace, ToolResult1, Trace),
            ToolCalls1 = maps:get(toolCalls, ToolResult1, ToolCalls),
            _ = recordSessionArtifacts(SessionId, Final, Critique, Trace1, ToolCalls1, Opts1),
            %% 记忆/经验/缓存沉淀只影响后续轮次，与本次答案无关：
            %% 全部后台执行（内含 aux 角色 LLM 提炼，同步跑会让前端在
            %% 思考流结束后白等数十秒才收到 answer 帧）。
            spawnMonitoredJob(fun() ->
                persistTurnKnowledge(SessionId, Question, Final, Critique, Trace1, Opts1)
            end),
            maybeAppendMessage(SessionId, Opts1, #{role => assistant, content => Final}),
            {ok, ToolResult1#{
                answer => Final,
                draft => Draft,
                critique => Critique,
                critiqueRounds => maps:get(rounds, CritiqueLoop, 0),
                critiqueTrace => maps:get(trace, CritiqueLoop, []),
                sessionId => SessionId
            }};
        {error, Reason} ->
            {error, Reason}
    end.

%% 语义缓存命中检查：写模式（edit）跳过——其结果依赖实时状态；
%% 纯闲聊（skipQueryLlm）无缓存价值。挂起恢复流程不经过此处。
maybeSemanticCacheHit(Question, Opts) ->
    case maps:get(mode, Opts, ask) =:= edit
         orelse maps:get(skipQueryLlm, Opts, false) of
        true ->
            miss;
        false ->
            try alSemanticCache:lookup(Question)
            catch _:_ -> miss
            end
    end.

%% 从 Final（binary 或 critic 包装 map）提取纯答案文本。
answerText(Final) when is_binary(Final) -> Final;
answerText(#{answer := A}) when is_binary(A) -> A;
answerText(_) -> <<>>.

%% 缓存失效锚点：本轮工具轨迹中真实读过的文件。
%% 两个来源合并去重：搜索/读取结果 JSON 中的 file 字段（pathBitsFromTrace）
%% + readFile/readFilePage 调用的 path 参数（答案直接基于其内容，必须锚定）。
cacheAnchorFiles(Trace) when is_list(Trace) ->
    try
        Files = maps:get(files, alExperience:pathBitsFromTrace(Trace), []),
        lists:usort(Files ++ readFilePathsFromTrace(Trace))
    catch _:_ -> [] end;
cacheAnchorFiles(_) ->
    [].

readFilePathsFromTrace(Trace) ->
    lists:usort(lists:flatmap(fun
        ({tool_calls, Calls}) when is_list(Calls) ->
            lists:filtermap(fun(C) when is_map(C) ->
                try
                    #{function := #{name := Name, arguments := Args}} = C,
                    case {isReadFileTool(Name), extractPathArg(Args)} of
                        {true, <<>>} -> false;
                        {true, Path} -> {true, Path};
                        _ -> false
                    end
                catch _:_ -> false end
            end, Calls);
        (_) ->
            []
    end, Trace)).

isReadFileTool(readFile) -> true;
isReadFileTool(<<"readFile">>) -> true;
isReadFileTool(readFilePage) -> true;
isReadFileTool(<<"readFilePage">>) -> true;
isReadFileTool(_) -> false.

extractPathArg(#{path := P}) when is_binary(P), P =/= <<>> -> P;
extractPathArg(#{<<"path">> := P}) when is_binary(P), P =/= <<>> -> P;
extractPathArg(Args) when is_binary(Args) ->
    try alJson:decode(Args) of
        M when is_map(M) -> extractPathArg(M);
        _ -> <<>>
    catch _:_ -> <<>> end;
extractPathArg(_) -> <<>>.

emitAgentProgress(Opts, Event) when is_map(Opts), is_map(Event) ->
    case maps:get(onProgress, Opts, undefined) of
        Fun when is_function(Fun, 1) ->
            try Fun(Event) catch _:_ -> ok end;
        _ ->
            ok
    end;
emitAgentProgress(_, _) ->
    ok.

%% 后台任务统一 spawn_monitor：立即返回不阻塞主流程，但由独立 watcher 进程
%% 消费 DOWN，异常退出记日志，避免裸 spawn 崩溃无声。
spawnMonitoredJob(Fun) ->
    {Pid, MonRef} = spawn_monitor(Fun),
    %% 主进程不消费 DOWN，先解除自己的 monitor 并 flush，避免消息残留。
    _ = erlang:demonitor(MonRef, [flush]),
    _ = spawn(fun() ->
        WatcherRef = erlang:monitor(process, Pid),
        receive
            {'DOWN', WatcherRef, process, Pid, normal} -> ok;
            {'DOWN', WatcherRef, process, Pid, noproc} -> ok;
            {'DOWN', WatcherRef, process, Pid, Reason} ->
                logger:warning("alAgent background job ~p exited abnormally: ~p", [Pid, Reason])
        end
    end),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% 记录会话级完整信息：summary / toolTrace / critiques，调用方保证
%% 已 ensureSession。
%%
%% @param SessionId 会话 ID
%% @param Final     最终回答
%% @param Critique  critic 评审结果
%% @param Trace     工具 trace
%% @param ToolCalls 工具调用列表（可能为空）
%% @param Opts      选项（含 tokenUsage 等）
%% @end
%%--------------------------------------------------------------------
recordSessionArtifacts(SessionId, Final, Critique, Trace, ToolCalls, Opts) ->
    Summary = #{
        finalAnswer => Final,
        lastUpdated => erlang:system_time(millisecond),
        toolCallCount => length(ToolCalls)
    },
    logArtifactError(setSummary, alSessionMgr:setSummary(SessionId, Summary)),
    lists:foreach(fun(Entry) ->
        logArtifactError(appendToolTrace, alSessionMgr:appendToolTrace(SessionId, Entry))
    end, Trace),
    logArtifactError(appendCritique, alSessionMgr:appendCritique(SessionId, Critique)),
    case maps:get(tokenUsage, Opts, undefined) of
        undefined -> ok;
        Usage -> logArtifactError(addTokenUsage, alSessionMgr:addTokenUsage(SessionId, Usage))
    end.

%% 会话工件写入失败不阻断主流程，但必须留痕，便于排查「记忆/审计缺失」。
logArtifactError(_Op, ok) -> ok;
logArtifactError(Op, {error, Reason}) ->
    logger:warning("alAgent session artifact ~p failed: ~p", [Op, Reason]);
logArtifactError(Op, Other) ->
    logger:warning("alAgent session artifact ~p returned unexpected: ~p", [Op, Other]).

%%--------------------------------------------------------------------
%% @doc
%% 用户审批后恢复工具循环执行，并复用与 run/2 相同的 critic 复审与记忆流程。
%%
%% @param Continuation 暂停时返回的续续上下文
%% @param ApprovedToolContent 已被批准的工具内容
%% @param Opts 选项映射
%% @return {ok, ResultMap} | {error, Reason} | 其他透传结果
%% @end
%%--------------------------------------------------------------------
resumeAfterApproval(Continuation, ApprovedToolContent, Opts) ->
    AgentCfg = maps:get(agentCfg, Opts, alConfig:getAgentCfg()),
    Mode = maps:get(mode, Opts, ask),
    BasePolicy = maps:get(policy, Opts,
                          maps:get(policy, AgentCfg, alPolicy:defaultPolicy())),
    Policy = maps:merge(BasePolicy, alPolicy:policyForMode(Mode)),
    Opts1 = Opts#{agentCfg => AgentCfg, policy => Policy, mode => Mode},
    SessionId = maps:get(sessionId, Continuation, maps:get(sessionId, Opts1, undefined)),
    MaxCriticRounds = maps:get(maxCriticRounds, Opts1,
                          maps:get(maxCriticRounds, AgentCfg, 3)),
    Question = maps:get(question, Continuation, <<>>),
    %% 把 WS/调用方注入的 streamCaller 等运行时选项挂回续接 opts。
    ContOpts0 = maps:get(opts, Continuation, #{}),
    ContOpts = maps:merge(ContOpts0, maps:with([streamCaller, progressId, taskId], Opts1)),
    Continuation1 = Continuation#{opts => ContOpts},
    case alToolRouter:resumeToolLoop(Continuation1, ApprovedToolContent, Opts1) of
        {ok, #{answer := Draft, trace := Trace, context := Context, toolCalls := ToolCalls} = ToolResult} ->
            {ok, CritiqueLoop} = alCritic:reviewLoop(
                Question,
                Draft,
                Context#{agentTrace => Trace},
                Opts1#{maxCriticRounds => MaxCriticRounds, llmRole => critic}
            ),
            Final0 = maps:get(finalDraft, CritiqueLoop, Draft),
            Critique = maps:get(critique, CritiqueLoop),
            Final = markCriticWarning(Final0, Critique),
            _ = recordSessionArtifacts(SessionId, Final, Critique, Trace, ToolCalls, Opts1),
            spawnMonitoredJob(fun() ->
                persistTurnKnowledge(SessionId, Question, Final, Critique, Trace, Opts1)
            end),
            maybeAppendMessage(SessionId, Opts1, #{role => assistant, content => Final}),
            {ok, ToolResult#{
                answer => Final,
                draft => Draft,
                critique => Critique,
                critiqueRounds => maps:get(rounds, CritiqueLoop, 1),
                critiqueTrace => maps:get(trace, CritiqueLoop, []),
                sessionId => SessionId,
                resumed => true
            }};
        {ok, #{answer := Draft, trace := Trace, context := Context} = ToolResult} ->
            {ok, CritiqueLoop} = alCritic:reviewLoop(
                Question, Draft, Context#{agentTrace => Trace},
                Opts1#{maxCriticRounds => MaxCriticRounds, llmRole => critic}),
            Final0 = maps:get(finalDraft, CritiqueLoop, Draft),
            Critique = maps:get(critique, CritiqueLoop),
            Final = markCriticWarning(Final0, Critique),
            _ = recordSessionArtifacts(SessionId, Final, Critique, Trace, [], Opts1),
            spawnMonitoredJob(fun() ->
                persistTurnKnowledge(SessionId, Question, Final, Critique, Trace, Opts1)
            end),
            maybeAppendMessage(SessionId, Opts1, #{role => assistant, content => Final}),
            {ok, ToolResult#{
                answer => Final, draft => Draft, critique => Critique,
                critiqueRounds => maps:get(rounds, CritiqueLoop, 1),
                critiqueTrace => maps:get(trace, CritiqueLoop, []),
                sessionId => SessionId, resumed => true
            }};
        {error, Reason} ->
            {error, Reason};
        Other ->
            Other
    end.

%% 根据 critic 评审结果在最终答案上追加 criticWarning 与 verdict 字段；verdict=pass 时原样返回。
markCriticWarning(Final, #{verdict := pass}) ->
    Final;
markCriticWarning(Final, #{verdict := Verdict, feedback := Feedback}) ->
    case is_map(Final) of
        true -> Final#{criticWarning => Feedback, verdict => Verdict};
        false -> #{answer => Final, criticWarning => Feedback, verdict => Verdict}
    end;
markCriticWarning(Final, _Critique) ->
    Final.

%% 若 Opts 中没有 sessionId，则创建新会话并写回 Opts；否则原样返回。
%% 创建失败时向上传递错误，避免裸匹配导致 badmatch 崩溃。
ensureSession(Opts) ->
    case maps:get(sessionId, Opts, undefined) of
        undefined ->
            case alSessionMgr:createSession(maps:get(user, Opts, agent)) of
                {ok, SessionId} -> {ok, Opts#{sessionId => SessionId}};
                {error, Reason} -> {error, Reason}
            end;
        _ ->
            {ok, Opts}
    end.

%% Seed a lightweight plan for multi-step / edit-mode tasks so the LLM
%% can track progress via planGet/planUpdate tools.
maybeSeedPlan(undefined, _Question, Opts) ->
    Opts;
maybeSeedPlan(SessionId, Question, Opts) ->
    case maps:get(autoPlan, Opts, true) of
        false -> Opts;
        true ->
            Existing = alPlan:getPlan(SessionId),
            case maps:get(steps, Existing, []) of
                [_ | _] ->
                    Opts#{plan => Existing};
                [] ->
                    case needsPlan(Question, Opts) of
                        false -> Opts;
                        true ->
                            Steps = defaultPlanSteps(Question, Opts),
                            Plan = alPlan:setPlan(SessionId, Steps),
                            Opts#{plan => Plan}
                    end
            end
    end.

needsPlan(Question, Opts) ->
    Mode = maps:get(mode, Opts, ask),
    Bin = case Question of
        B when is_binary(B) -> B;
        L when is_list(L) -> unicode:characters_to_binary(L);
        _ -> <<>>
    end,
    Mode =/= ask
        orelse maps:get(modePromoted, Opts, false)
        orelse byte_size(Bin) > 80
        orelse binary:match(Bin, [<<"修复"/utf8>>, <<"重构"/utf8>>, <<"实现"/utf8>>, <<"fix">>,
                                  <<"refactor">>, <<"implement">>, <<"patch">>,
                                  <<"改代码"/utf8>>, <<"审查"/utf8>>, <<"review">>]) =/= nomatch.

defaultPlanSteps(Question, Opts) ->
    case planStepsFromSkills(Question, Opts) of
        [_ | _] = Steps -> Steps;
        [] -> defaultPlanStepsFallback(Opts)
    end.

planStepsFromSkills(Question, Opts) ->
    AgentCfg = maps:get(agentCfg, Opts, alConfig:getAgentCfg()),
    case maps:get(skillsEnabled, AgentCfg, true) of
        false ->
            [];
        true ->
            SkillNames = alContext:activeSkills(Question, Opts#{agentCfg => AgentCfg}),
            lists:flatmap(fun(Name) ->
                case alSkill:lookup(Name) of
                    {ok, #{planTemplate := Template}}
                      when is_list(Template), Template =/= [] ->
                        Template;
                    _ ->
                        []
                end
            end, SkillNames)
    end.

defaultPlanStepsFallback(Opts) ->
    case maps:get(mode, Opts, ask) of
        ask ->
            [<<"理解问题并收集上下文"/utf8>>,
             <<"搜索代码与运行时状态"/utf8>>,
             <<"综合并给出有依据的回答"/utf8>>];
        _ ->
            [<<"探索相关模块与符号"/utf8>>,
             <<"提出并校验补丁"/utf8>>,
             <<"审批后应用改动"/utf8>>,
             <<"用编译/测试验证"/utf8>>]
    end.

%% critic reject 且缺证据时，带反馈再跑一轮工具循环（最多一次）。
maybeRerunToolsAfterCriticReject(Question, Draft, ToolResult, CritiqueLoop,
                                 Opts, SessionId, MaxToolSteps, MaxCriticRounds) ->
    Critique = maps:get(critique, CritiqueLoop),
    Final0 = maps:get(finalDraft, CritiqueLoop, Draft),
    case maps:get(criticRerun, Opts, false) of
        true ->
            {Final0, Critique, ToolResult};
        false ->
            case criticRejectNeedsTools(Critique) of
                false ->
                    {Final0, Critique, ToolResult};
                true ->
                    Feedback = maps:get(feedback, Critique, <<>>),
                    emitAgentProgress(Opts, #{
                        type => step, phase => tools,
                        message => <<"复审未通过，补充工具证据后重答…"/utf8>>
                    }),
                    RerunOpts = Opts#{
                        criticRerun => true,
                        sessionId => SessionId,
                        maxToolSteps => MaxToolSteps + 5,
                        criticFeedback => Feedback
                    },
                    case alToolRouter:runWithTools(Question, RerunOpts) of
                        {ok, Rerun} ->
                            RerunDraft = maps:get(answer, Rerun, Final0),
                            {ok, RerunCritiqueLoop} = alCritic:reviewLoop(
                                Question, RerunDraft,
                                enrichCriticContext(
                                    maps:get(context, Rerun, #{}),
                                    Question, Opts),
                                Opts#{maxCriticRounds => min(MaxCriticRounds, 1),
                                      llmRole => critic}),
                            {maps:get(finalDraft, RerunCritiqueLoop, RerunDraft),
                             maps:get(critique, RerunCritiqueLoop),
                             Rerun};
                        _ ->
                            {Final0, Critique, ToolResult}
                    end
            end
    end.

criticRejectNeedsTools(#{verdict := reject} = Critique) ->
    Fb = toLowerBinary(maps:get(feedback, Critique, <<>>)),
    Needles = [<<"证据"/utf8>>, <<"依据"/utf8>>, <<"未调用"/utf8>>,
               <<"无工具"/utf8>>, <<"evidence">>, <<"unsupported">>,
               <<"hallucin">>, <<"编造"/utf8>>],
    lists:any(fun(N) -> binary:match(Fb, N) =/= nomatch end, Needles);
criticRejectNeedsTools(_) ->
    false.

toLowerBinary(B) when is_binary(B) ->
    unicode:characters_to_binary(string:lowercase(unicode:characters_to_list(B)));
toLowerBinary(L) when is_list(L) ->
    unicode:characters_to_binary(string:lowercase(L));
toLowerBinary(_) ->
    <<>>.

%%--------------------------------------------------------------------
%% @doc
%% 本轮问答的知识沉淀（后台任务）：记忆写入、经验/失败教训提取、工具
%% 选择学习、成功路径与语义缓存。全部只影响后续轮次，与本次 answer
%% 帧无关——异步执行，避免 aux 角色的 LLM 提炼把前端挂在思考流结束之后。
%% 由 spawnMonitoredJob 调起；任何一步失败仅记日志。
%% @end
%%--------------------------------------------------------------------
persistTurnKnowledge(SessionId, Question, Final, Critique, Trace, Opts) ->
    _ = maybeReflectFailure(SessionId, Trace, Critique, Opts),
    _ = maybeRemember(SessionId, Question, Final, Critique, Opts),
    _ = alExperience:recordFromTurn(SessionId, Question, Final, Critique, Trace, Opts),
    %% 工具选择学习：干净通过（pass/warn）的轮次沉淀「此类问题 → 高频工具」，
    %% reject 的轮次工具链不可信，不记。
    _ = case maps:get(verdict, Critique, pass) of
        reject -> ok;
        _ -> alToolLearn:noteTurn(Question, Trace)
    end,
    %% 成功路径沉淀：pass 且有真实检索命中时，记录「问题 → 检索词 → 命中文件 → 工具链」。
    _ = case maps:get(verdict, Critique, pass) of
        pass -> alExperience:recordSuccessPath(SessionId, Question, Trace);
        _ -> ok
    end,
    %% 语义缓存：pass/warn 的最终答案 + 引用文件锚点落缓存，
    %% 同类问题（换措辞）下轮零 LLM 秒回；reject 答案不可信不缓存。
    case maps:get(verdict, Critique, pass) of
        reject -> ok;
        _ -> alSemanticCache:put(Question, answerText(Final), cacheAnchorFiles(Trace))
    end.

%% 无 SessionId 时直接返回 ok。
maybeRemember(undefined, _Question, _Answer, _Critique, _Opts) ->
    ok;
%% 当启用 persistMemory 时，将本轮问答与评审结果存入记忆库，
%% 并在 autoDistillMemories 开启时异步提炼事实到长期记忆。
maybeRemember(SessionId, Question, Answer, Critique, Opts) ->
    case maps:get(persistMemory, Opts, true) of
        true ->
            _ = alMemory:remember(SessionId, agentTurn, #{question => Question, answer => Answer, critique => Critique}, #{
                tags => [agent, critique],
                metadata => #{source => alAgent}
            }),
            maybeAutoDistill(SessionId, Opts);
        false ->
            ok
    end.

%%--------------------------------------------------------------------
%% @doc
%% 自动记忆提炼：当 agentCfg.autoDistillMemories 为 true 时，异步从本轮
%% 对话中提取可持久化的事实/偏好存入长期记忆。
%%
%% 异步执行（spawn）避免阻塞主响应；失败仅记日志不影响主流程。
%% 使用 memoryDistillModel（若配置）以降低成本，否则用默认模型。
%%
%% @param SessionId 会话 ID
%% @param Opts 选项（含 agentCfg）
%% @return ok
%% @end
%%--------------------------------------------------------------------
maybeAutoDistill(SessionId, Opts) ->
    AgentCfg = maps:get(agentCfg, Opts, alConfig:getAgentCfg()),
    case maps:get(autoDistillMemories, AgentCfg, true) of
        true ->
            DistillModel = maps:get(memoryDistillModel, AgentCfg, undefined),
            spawnMonitoredJob(fun() ->
                try
                    case enoughMessagesForDistill(SessionId) of
                        true ->
                            DistillOpts = case DistillModel of
                                undefined -> #{};
                                Model -> #{model => Model}
                            end,
                            case alMemory:distill(SessionId, DistillOpts) of
                                {ok, []} ->
                                    logger:info("alAgent auto-distill empty for session ~p", [SessionId]);
                                {ok, Items} ->
                                    logger:info("alAgent auto-distilled ~p memories for session ~p",
                                                [length(Items), SessionId]);
                                {error, ErrReason} ->
                                    logger:warning("alAgent auto-distill failed: ~p", [ErrReason])
                            end;
                        false ->
                            ok
                    end
                catch
                    Class:CrashReason ->
                        logger:warning("alAgent auto-distill crashed: ~p:~p", [Class, CrashReason])
                end
            end),
            ok;
        false ->
            ok
    end.

%% 会话消息达到一定量级才蒸馏，避免每轮单次问答都触发 LLM 提炼。
enoughMessagesForDistill(SessionId) ->
    case alSessionMgr:getContext(SessionId) of
        {ok, #{messages := Messages}} -> length(Messages) >= 4;
        _ -> false
    end.

%% 无 SessionId 时直接返回 ok。
maybeAppendMessage(undefined, _Opts, _Message) ->
    ok;
%% 当启用 persistMemory 时，将消息追加到会话历史。
maybeAppendMessage(SessionId, Opts, Message) ->
    case maps:get(persistMemory, Opts, true) of
        false -> ok;
        true -> _ = alSessionMgr:appendMessage(SessionId, Message), ok
    end.

%%--------------------------------------------------------------------
%% @doc
%% G3 plan-act-reflect 最小闭环：当本轮存在工具失败或 critic 有 findings /
%% 非 pass 结论时，若会话存在 active plan，则把失败摘要写入当前活跃步骤
%% 的 note，并将该步标记为 failed，引导下一轮修订。不自动续跑。
%%
%% @param SessionId 会话 ID（undefined 时跳过）
%% @param Trace     工具循环 trace（含 {results, ToolResults}）
%% @param Critique  critic 评审结果
%% @param Opts      选项（保留）
%% @return ok
%% @end
%%--------------------------------------------------------------------
maybeReflectFailure(undefined, _Trace, _Critique, _Opts) ->
    ok;
maybeReflectFailure(SessionId, Trace, Critique, _Opts) ->
    Plan = alPlan:getPlan(SessionId),
    case maps:get(steps, Plan, []) of
        [] ->
            ok;
        Steps ->
            Failures = collectFailures(Trace, Critique),
            case Failures of
                [] ->
                    ok;
                _ ->
                    case targetStep(Steps) of
                        undefined -> ok;
                        StepId ->
                            Note = failureNote(Failures),
                            _ = alPlan:updateStep(SessionId, StepId,
                                                  #{status => failed, note => Note}),
                            ok
                    end
            end
    end.

%% 汇总本轮的失败信号：工具错误结果 + critic 非 pass / findings。
collectFailures(Trace, Critique) ->
    toolFailures(Trace) ++ criticFailures(Critique).

%% 从 trace 中提取工具失败摘要（每条 binary 文本）。
toolFailures(Trace) when is_list(Trace) ->
    lists:foldl(fun
        ({results, Results}, Acc) when is_list(Results) ->
            [<<"tool failed">> || R <- Results, resultFailed(R)] ++ Acc;
        (_, Acc) ->
            Acc
    end, [], Trace);
toolFailures(_) ->
    [].

%% 判断一条 tool 结果消息是否为失败（content 为 map 或 JSON binary）。
resultFailed(#{content := C}) ->
    contentFailed(C);
resultFailed(_) ->
    false.

contentFailed(C) when is_map(C) ->
    maps:get(status, C, ok) =:= error;
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

%% 从 critic 结果提取失败信号：verdict 非 pass 或存在 findings。
criticFailures(Critique) when is_map(Critique) ->
    Verdict = maps:get(verdict, Critique, pass),
    Findings = maps:get(findings, Critique, []),
    Bad = Verdict =:= reject orelse Verdict =:= warn orelse Findings =/= [],
    case Bad of
        true ->
            Feedback = alCritic:toBinary(maps:get(feedback, Critique, <<>>)),
            [<<"critic ", (atom_to_binary(Verdict, utf8))/binary, ": ", Feedback/binary>>];
        false ->
            []
    end;
criticFailures(_) ->
    [].

%% 选取要标记 failed 的步骤：优先 inProgress，其次首个未完成（非 done/skipped）。
targetStep(Steps) ->
    case [Id || #{id := Id, status := inProgress} <- Steps] of
        [Id | _] ->
            Id;
        [] ->
            case [Id || #{id := Id, status := S} <- Steps,
                        S =/= done, S =/= skipped, S =/= failed] of
                [Id | _] -> Id;
                [] -> undefined
            end
    end.

%% 将失败摘要拼成一条限长的 note 文本。
failureNote(Failures) ->
    Joined = lists:join(<<"; ">>, lists:sublist(Failures, 5)),
    Bin = iolist_to_binary([<<"[reflect] ">>, Joined]),
    case byte_size(Bin) > 500 of
        true -> <<(binary:part(Bin, 0, 500))/binary, "...">>;
        false -> Bin
    end.

%% 把当前 persona 的 rubric 挂到 critic 上下文。
enrichCriticContext(Context, Question, Opts) when is_map(Context), is_map(Opts) ->
    try
        Resolved = alPersona:resolve(toBin(Question), Opts),
        case alPersona:rubric(Resolved) of
            <<>> -> Context;
            Rubric -> Context#{personaRubric => Rubric}
        end
    catch
        _:_ -> Context
    end;
enrichCriticContext(Context, _, _) ->
    Context.

%% ask 下识别「改代码」意图时自动升档 edit（暴露 applyPatch 等）；改线上业务数据不升档。
maybePromoteEditMode(Question, Opts) when is_map(Opts) ->
    case maps:get(mode, Opts, ask) of
        ask ->
            case isCodeEditIntent(Question) of
                true ->
                    Opts#{mode => edit, modePromoted => true};
                false ->
                    Opts
            end;
        Mode ->
            Opts#{mode => Mode}
    end;
maybePromoteEditMode(_Question, Opts) ->
    Opts.

%% 明确的改码意图（不含裸「改一下」——那常用于改线上业务数据）。
isCodeEditIntent(Q0) ->
    Q = string:lowercase(toBin(Q0)),
    CodeKeys = [
        <<"改代码"/utf8>>, <<"修改代码"/utf8>>, <<"改源码"/utf8>>,
        <<"改这个文件"/utf8>>, <<"改这个模块"/utf8>>, <<"改一下代码"/utf8>>,
        <<"帮我改代码"/utf8>>, <<"重构"/utf8>>, <<"修bug"/utf8>>, <<"修一下bug"/utf8>>,
        <<"修复编译"/utf8>>, <<"写补丁"/utf8>>,
        <<"applypatch">>, <<"dryrunpatch">>, <<"validatepatch">>, <<"apply patch">>,
        <<"refactor">>, <<"implement ">>, <<"fix bug">>, <<"fix the code">>,
        <<"edit the file">>,
        <<"修改函数实现"/utf8>>, <<"加上一个函数"/utf8>>, <<"删除这个函数"/utf8>>,
        <<"重写这个"/utf8>>,
        <<".erl">>, <<"src/">>, <<"patch 一下"/utf8>>, <<"提交补丁"/utf8>>
    ],
    HasCode = lists:any(fun(K) -> binary:match(Q, string:lowercase(K)) =/= nomatch end, CodeKeys),
    case HasCode of
        true -> true;
        false ->
            Live = isLiveDataQuestion(Q0),
            FileHint = binary:match(Q, <<".erl">>) =/= nomatch
                orelse binary:match(Q, <<"src/">>) =/= nomatch
                orelse binary:match(Q, <<"module ">>) =/= nomatch,
            (not Live) andalso FileHint
    end.

toBin(B) when is_binary(B) -> B;
toBin(L) when is_list(L) -> unicode:characters_to_binary(L);
toBin(A) when is_atom(A) -> atom_to_binary(A, utf8);
toBin(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).

%% 问候/短确认：不走工具循环（避免乱调 search → 误触发 embedding 超时）。
isBlankPrompt(Q) ->
    string:trim(unicode:characters_to_list(alCritic:toBinary(Q))) =:= "".

isTrivialChat(Q0) ->
    Q = string:trim(string:lowercase(unicode:characters_to_list(alCritic:toBinary(Q0)))),
    Greetings = ["hi", "hey", "hello", "ok", "yes", "no", "thanks", "thank you",
                 "你好", "您好", "嗨", "嗯", "好的", "谢谢", "再见", "在吗", "早上好",
                 "下午好", "晚上好"],
    lists:member(Q, Greetings).

%% 查/改线上数据、ETS、进程等：须经工具取证后 runMfa（禁止瞎猜 MFA）。
%% 与 isRuntimeQuestion 共用判定：业务实体词只来自 `.ali/knowledge/agent.json`。
isLiveDataQuestion(Q0) ->
    alToolRouter:isRuntimeQuestion(Q0).
