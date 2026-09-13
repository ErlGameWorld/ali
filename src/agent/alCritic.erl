%%%-------------------------------------------------------------------
%% @doc Agent 评审模块：审查草稿答案的安全性与质量。
%% @end
%%%-------------------------------------------------------------------

-module(alCritic).

-export([review/3, review/4, reviewLoop/3, reviewLoop/4, persist/4, persist/5,
         noteOutcome/2, calibratedThreshold/0]).
%% Test exports — pure helpers
-export([shouldRevise/4, shouldRevise/5, computeThreshold/1, parseCritique/1,
         localCritique/4, criticMessages/3,
         reviseSystemPrompt/0, scanFindings/1, maxSeverity/1, scoreFromFindings/1,
         toBinary/1]).

%%--------------------------------------------------------------------
%% @doc
%% review/4 的简化入口：使用空选项 map 调用 LLM critic 审查草稿答案。
%%
%% @param Question 用户问题
%% @param Answer 待审查的草稿答案
%% @param Context 上下文信息
%% @return {ok, Critique} 审查结果 map（LLM 失败时回退到本地启发式审查）
%% @end
%%--------------------------------------------------------------------
review(Question, Answer, Context) ->
    %% 默认按 critic 角色路由（链配置时取声明 critic 角色的链项）。
    review(Question, Answer, Context, #{llmRole => critic}).

%%--------------------------------------------------------------------
%% @doc
%% 调用 LLM critic 审查草稿答案：构造消息、调用 chat、解析 JSON 评判结果。
%% LLM 调用失败时回退到 localCritique 的本地启发式审查。
%%
%% @param Opts 选项 map，可包含 sessionId、maxCriticRounds 等
%% @return {ok, Critique} 始终返回 ok 元组，Critique 中包含 provider 字段标识来源
%% @end
%%--------------------------------------------------------------------
review(Question, Answer, Context, Opts) ->
    %% critic 位于主模型流结束之后，任何慢思考都会表现为“思考已完成但
    %% 最终答案迟迟不出”。默认禁用深度思考并给独立短超时；仍可通过
    %% agent.criticThinking / criticTimeoutMs 显式放开。
    Opts1 = criticCallOpts(Opts),
    case alLlmClient:chat(criticMessages(Question, Answer, Context), Opts1) of
        {ok, Reply} ->
            Content = maps:get(content, Reply, <<>>),
            Critique = parseCritique(Content),
            {ok, Critique#{provider => llm, raw => Reply}};
        {error, Reason} ->
            {ok, localCritique(Question, Answer, Context, Reason)}
    end.

%%--------------------------------------------------------------------
%% @doc
%% reviewLoop/4 的简化入口：使用空选项 map 进行多轮审查-修订循环。
%%
%% @return {ok, #{critique, finalDraft, rounds, trace}}
%% @end
%%--------------------------------------------------------------------
reviewLoop(Question, Draft, Context) ->
    reviewLoop(Question, Draft, Context, #{}).

%%--------------------------------------------------------------------
%% @doc
%% reviewLoop/5 的入口：初始化累加器（round=1, 空 trace, 无 prevFeedback）后进入递归。
%%
%% @return {ok, FinalResult}
%% @end
%%--------------------------------------------------------------------
reviewLoop(Question, Draft, Context, Opts) ->
    reviewLoop(Question, Draft, Context, Opts, #{round => 1, trace => [], prevFeedback => undefined}).

%%--------------------------------------------------------------------
%% @doc
%% 多轮审查-修订循环主体：每轮调用 review，持久化评判结果，判断是否需要继续修订。
%% 终止条件：评判通过、达到最大轮数、或反馈与上一轮相同（陷入循环）。
%%
%% @param Acc 累加器，包含 round、trace、prevFeedback
%% @return {ok, #{critique, finalDraft, rounds, trace}}
%% @end
%%--------------------------------------------------------------------
reviewLoop(Question, Draft, Context, Opts, Acc) ->
    Round = maps:get(round, Acc, 1),
    MaxRounds = maps:get(maxCriticRounds, Opts, 3),
    %% maxCriticRounds=0：跳过 critic（运行时探查等场景避免被改写成说教）
    case MaxRounds < 1 of
        true ->
            {ok, #{
                critique => #{verdict => pass, score => 1.0, feedback => <<>>,
                              safe => true, provider => skipped},
                finalDraft => Draft,
                rounds => 0,
                trace => []
            }};
        false ->
            reviewLoopBody(Question, Draft, Context, Opts, Acc, Round, MaxRounds)
    end.

reviewLoopBody(Question, Draft, Context, Opts, Acc, Round, MaxRounds) ->
    {ok, Critique} = review(Question, Draft, Context, Opts),
    SessionId = maps:get(sessionId, Opts, undefined),
    case persist(SessionId, Question, Draft, Critique, Round) of
        {ok, _} ->
            ok;
        Other ->
            logger:warning("alCritic persist failed for session ~p: ~p", [SessionId, Other])
    end,
    Trace = maps:get(trace, Acc, []) ++ [#{round => Round, critique => Critique}],
    Feedback = maps:get(feedback, Critique, undefined),
    case shouldRevise(Critique, Round, MaxRounds, maps:get(prevFeedback, Acc, undefined)) of
        false ->
            {ok, #{critique => Critique, finalDraft => Draft, rounds => Round, trace => Trace}};
        true ->
            Revised = revise(Question, Draft, Critique, Context, Opts),
            reviewLoop(Question, Revised, Context, Opts, Acc#{
                round => Round + 1,
                trace => Trace,
                prevFeedback => Feedback
            })
    end.

%% 评判是否继续修订：pass / 分数达动态阈值 / 达最大轮 / 反馈重复 → 不修订。
%% 阈值由 calibratedThreshold/0 按用户反馈滑动窗口自校准（DB 不可用时 0.8）。
shouldRevise(Critique, Round, MaxRounds, Prev) ->
    shouldRevise(Critique, Round, MaxRounds, Prev, calibratedThreshold()).

%%--------------------------------------------------------------------
%% @doc
%% 带显式阈值的纯判定（测试用）：pass / 达阈值 / 达最大轮 / 反馈重复 → 不修订。
%% @end
%%--------------------------------------------------------------------
shouldRevise(#{verdict := pass}, _Round, _MaxRounds, _Prev, _Threshold) ->
    false;
shouldRevise(#{score := Score}, _Round, _MaxRounds, _Prev, Threshold)
        when is_number(Score), is_number(Threshold), Score >= Threshold ->
    false;
shouldRevise(_Critique, Round, MaxRounds, _Prev, _Threshold) when Round >= MaxRounds ->
    false;
shouldRevise(#{feedback := Feedback}, _Round, _MaxRounds, Prev, _Threshold)
        when Feedback =:= Prev, Feedback =/= undefined ->
    false;
shouldRevise(_Critique, Round, MaxRounds, _Prev, _Threshold) ->
    Round < MaxRounds.

%%--------------------------------------------------------------------
%% @doc
%% Critic 阈值自校准：按用户反馈（critique_logs.outcome）滑动窗口动态调整
%% 「分数多高可免修订」的门槛。
%%
%% <ul>
%%   <li>overConfident：critic 打高分但用户重新生成 → 阈值上调（更严）</li>
%%   <li>overStrict：critic 打低分但用户采纳 → 阈值下调（更宽松，省修订轮）</li>
%% </ul>
%% 样本不足（< 10）或 DB 不可用时返回默认 0.8；调整幅度 ±0.3 内钳位 [0.6, 0.95]。
%%
%% @return float() 校准后的阈值
%% @end
%%--------------------------------------------------------------------
-spec calibratedThreshold() -> float().
calibratedThreshold() ->
    try
        Sql = "SELECT score, outcome FROM critique_logs "
              "WHERE outcome IS NOT NULL ORDER BY id DESC LIMIT 50",
        case alLocalDb:query(Sql, []) of
            {ok, Rows} when is_list(Rows) ->
                Samples = [{maps:get(score, R, undefined), maps:get(outcome, R, undefined)}
                           || R <- Rows, is_map(R)],
                computeThreshold(Samples);
            _ ->
                0.8
        end
    catch
        _:_ -> 0.8
    end.

%%--------------------------------------------------------------------
%% @doc
%% 纯函数：由 [{Score, Outcome}] 样本计算校准阈值。
%% Outcome ∈ accepted | regenerated；样本 < 10 返回 0.8。
%% @end
%%--------------------------------------------------------------------
-spec computeThreshold([{number() | undefined, binary() | atom() | undefined}]) -> float().
computeThreshold(Samples) when is_list(Samples) ->
    Valid = [{S, normalizeOutcome(O)} || {S, O} <- Samples,
                                         is_number(S),
                                         O =/= undefined],
    case length(Valid) < 10 of
        true -> 0.8;
        false ->
            N = length(Valid),
            OverConfident = length([1 || {S, O} <- Valid,
                                         S >= 0.8, O =:= regenerated]),
            OverStrict = length([1 || {S, O} <- Valid,
                                      S < 0.65, O =:= accepted]),
            Delta = (OverConfident - OverStrict) / N * 0.3,
            min(0.95, max(0.6, 0.8 + Delta))
    end;
computeThreshold(_) ->
    0.8.

normalizeOutcome(<<"accepted">>) -> accepted;
normalizeOutcome(<<"regenerated">>) -> regenerated;
normalizeOutcome(accepted) -> accepted;
normalizeOutcome(regenerated) -> regenerated;
normalizeOutcome(_) -> undefined.

%%--------------------------------------------------------------------
%% @doc
%% 用户反馈回流：把 accepted / regenerated 记到该会话最近一条 critique 上，
%% 供 calibratedThreshold/0 滑动窗口统计。文件后端不支持 UPDATE 时静默降级。
%%
%% @param SessionId 会话 ID
%% @param Outcome   accepted | regenerated | rejected
%% @return ok
%% @end
%%--------------------------------------------------------------------
-spec noteOutcome(term(), atom() | binary()) -> ok.
noteOutcome(SessionId, Outcome) when Outcome =:= accepted;
                                     Outcome =:= regenerated;
                                     Outcome =:= rejected;
                                     Outcome =:= <<"accepted">>;
                                     Outcome =:= <<"regenerated">>;
                                     Outcome =:= <<"rejected">> ->
    OutcomeBin = case Outcome of
        B when is_binary(B) -> B;
        A -> atom_to_binary(A, utf8)
    end,
    try
        Sql = "UPDATE critique_logs SET outcome = ? "
              "WHERE id = (SELECT id FROM critique_logs WHERE session_id = ? "
              "ORDER BY id DESC LIMIT 1)",
        _ = alLocalDb:execute(Sql, [OutcomeBin, SessionId]),
        ok
    catch
        _:_ -> ok
    end;
noteOutcome(_, _) ->
    ok.

%%--------------------------------------------------------------------
%% @doc
%% 根据 critic 反馈调用 LLM 修订草稿答案。LLM 返回空时在草稿中附加 criticWarning，
%% 保留原草稿内容并标记 verdict。
%%
%% @return 修订后的答案（Content 或附加警告的 map/原值）
%% @end
%%--------------------------------------------------------------------
revise(Question, Draft, Critique, Context, Opts) ->
    Feedback = maps:get(feedback, Critique, <<>>),
    Messages = [
        #{role => system, content => reviseSystemPrompt()},
        #{role => user, content => #{
            instruction => <<"请根据 critic 反馈修订答案。"/utf8>>,
            feedback => Feedback,
            question => Question,
            draft => Draft,
            context => Context
        }}
    ],
    %% 修订同样处在终答前的同步关键路径，共用 critic 快速选项。
    Opts1 = criticCallOpts(Opts),
    case alLlmClient:chat(Messages, Opts1) of
        {ok, #{content := Content}} when Content =/= null, Content =/= undefined ->
            Content;
        _ ->
            case is_map(Draft) of
                true -> Draft#{criticWarning => Feedback, verdict => maps:get(verdict, Critique, warn)};
                false -> #{answer => Draft, criticWarning => Feedback, verdict => maps:get(verdict, Critique, warn)}
            end
    end.

criticCallOpts(Opts) ->
    AgentCfg = alConfig:getAgentCfg(),
    Timeout = maps:get(criticTimeoutMs, Opts,
                       maps:get(criticTimeoutMs, AgentCfg, 45000)),
    Thinking = maps:get(criticThinking, Opts,
                        maps:get(criticThinking, AgentCfg, disabled)),
    Base = Opts#{llmRecvTimeout => Timeout, thinking => Thinking},
    case Thinking of
        disabled -> Base#{allowThinking => false};
        false -> Base#{allowThinking => false};
        _ -> Base#{thinkingBudget => maps:get(thinkingBudget, Opts, low)}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 返回修订阶段使用的 system prompt：约束助手基于工具追踪和上下文修订，禁止编造运行时状态。
%%
%% @return binary()
%% @end
%%--------------------------------------------------------------------
reviseSystemPrompt() ->
    <<"你在修订 Erlang 助手草稿。规则：\n"
      "- 紧扣工具轨迹与用户问题，禁止编造运行时状态。\n"
      "- 若用户问的是提交/diff/审核，修订必须回到该提交的审核结论；"
      "不要改写成 getEts/getProcesses/getRuntime 节点快照。\n"
      "- 若草稿已含 runMfa/evalErl/工具结果（线上业务数据等），必须保留这些事实——"
      "不要换成外部后台网页/安全说教。\n"
      "- 禁止声称助手离线或在沙箱中；它运行在 BEAM 节点上。\n"
      "- 只剔除真正危险建议（halt、os:cmd、清库）。"
      "通过 runMfa/evalErl 做线上检查或拼装执行是允许且预期的。\n"
      "- 修订后的正文语言与用户问题一致（用户中文则全文中文）。"/utf8>>.

%%--------------------------------------------------------------------
%% @doc
%% persist/5 的简化入口：默认轮数为 1，将评判记录写入 critique_logs 表。
%%
%% @return alLocalDb:insert 的返回值
%% @end
%%--------------------------------------------------------------------
persist(SessionId, Question, Answer, Critique) ->
    persist(SessionId, Question, Answer, Critique, 1).

%%--------------------------------------------------------------------
%% @doc
%% 将一轮审查的评判记录持久化到 critique_logs 表，包含 session、问题、答案、
%% verdict、score、feedback、轮数与时间戳。
%%
%% @return alLocalDb:insert 的返回值
%% @end
%%--------------------------------------------------------------------
persist(SessionId, Question, Answer, Critique, Round) ->
    Sql =
        "INSERT INTO critique_logs (session_id, question, answer, verdict, score, feedback, round, created_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
    Params = [
        SessionId,
        toBinary(Question),
        toBinary(Answer),
        maps:get(verdict, Critique, pass),
        maps:get(score, Critique, 0.5),
        toBinary(maps:get(feedback, Critique, <<>>)),
        Round,
        erlang:system_time(second)
    ],
    alLocalDb:insert(Sql, Params).

%%--------------------------------------------------------------------
%% @doc
%% 构造发送给 LLM critic 的消息列表。
%% @end
%%--------------------------------------------------------------------
criticMessages(Question, Answer, Context) ->
    Rubric = case maps:get(personaRubric, Context, maps:get(<<"personaRubric">>, Context, <<>>)) of
        B when is_binary(B), B =/= <<>> -> B;
        _ -> <<>>
    end,
    BaseSys =
        <<"你是嵌入式 BEAM 节点上的 Erlang 专家审查员。\n"
          "只返回 JSON："
          "{\"verdict\":\"pass|warn|reject\",\"score\":0.0-1.0,\"feedback\":\"...\",\"safe\":true|false}。\n"
          "先逐项核对：是否直接回答问题；关键结论是否被 context/工具结果支持；"
          "路径、行号、MFA、运行时数字、网页引用是否真实出现；是否遗漏会改变结论的限制。\n"
          "PASS：答案正确、相关、关键结论有充分依据；调用过工具本身不等于有依据。\n"
          "WARN：结论基本正确，仅有不影响主结论的小遗漏或表达问题。\n"
          "REJECT：答非所问、与证据矛盾、把推测写成事实、伪造引用/路径/MFA/数字，"
          "或证据不足却给出确定结论。网页引用 [n] 必须确实支持紧邻主张。\n"
          "一般常识题不强制调用工具；但若 context 已提供证据，必须优先以证据为准。\n"
          "PASS：用 runMfa 做单次线上 MFA，或用 evalErl 拼装多步业务——这是预期能力。\n"
          "PASS：用户问提交/diff/审核时，答案基于 lastCommit/commitDiff/reviewChangeImpact 即可；"
          "不要要求再去 getEts/getRuntime。\n"
          "安全上必须 REJECT：halt/os:cmd/open_port、未经授权的破坏性写入。\n"
          "若用户问的是提交审核，而草稿却是节点运行时快照——判 warn，并要求改回提交审核结论"
          "（不要再扩写 runtime）。\n"
          "不要仅因建议或使用 runMfa/evalErl 而 reject。"
          "不要要求以外部后台网页为主要答案。"
          "不要要求助手假装连不上节点。"
          "feedback 与用户问题同语言（用户中文则用中文）。"/utf8>>,
    Sys = case Rubric of
        <<>> -> BaseSys;
        _ -> <<BaseSys/binary, "\n额外专家评审维度："/utf8, Rubric/binary, "\n">>
    end,
    [
        #{role => system, content => Sys},
        #{
            role => user,
            content => #{
                question => Question,
                answer => Answer,
                context => Context
            }
        }
    ].

%%--------------------------------------------------------------------
%% @doc
%% 解析 LLM 返回的评判内容为结构化 map。binary 先转 list；list 提取 JSON 子串后
%% 用 alJson 解析，成功返回 #{verdict, score, feedback, safe}，失败回退到本地文本审查。
%%
%% @param Content LLM 返回的评判内容（binary / list / 其它）
%% @return 评判 map
%% @end
%%--------------------------------------------------------------------
parseCritique(Content) when is_binary(Content) ->
    parseCritique(unicode:characters_to_list(Content));
parseCritique(Content) when is_list(Content) ->
    Json = extractJson(Content),
    try alJson:decode(unicode:characters_to_binary(Json)) of
        Map when is_map(Map) ->
            #{
                verdict => normalizeVerdict(maps:get(<<"verdict">>, Map, <<"pass">>)),
                score => normalizeScore(maps:get(<<"score">>, Map, 0.7)),
                feedback => maps:get(<<"feedback">>, Map, <<>>),
                safe => maps:get(<<"safe">>, Map, true)
            };
        _ ->
            localCritiqueText(Content)
    catch
        _:_ ->
            localCritiqueText(Content)
    end;
%% 非 binary/list 内容直接走本地文本审查。
parseCritique(Content) ->
    localCritiqueText(Content).

%% binary 文本先转 list 再提取 JSON。
extractJson(Text) when is_binary(Text) ->
    extractJson(unicode:characters_to_list(Text));
%% 从文本中提取首个平衡的 JSON 对象子串（找不到则原样返回）。
extractJson(Text) when is_list(Text) ->
    case string:str(Text, "{") of
        0 ->
            Text;
        StartIdx ->
            FromBrace = string:slice(Text, StartIdx - 1),
            case jsonSpan(FromBrace, 0, false) of
                {ok, Len} ->
                    string:slice(Text, StartIdx - 1, Len);
                notFound ->
                    Text
            end
    end.

%% jsonSpan(Chars, Depth, InString) -> {ok, Length} | notFound
%% Length counts chars from the opening `{` through the matching `}`.
%% 计算 JSON 对象的字符跨度：从首个 `{` 到匹配的 `}`，正确处理字符串与转义字符。
jsonSpan([], _Depth, _InStr) ->
    notFound;
%% 字符串内遇到转义字符：跳过转义符和被转义字符，长度+2。
jsonSpan([$\\, _C | Rest], Depth, true) ->
    case jsonSpan(Rest, Depth, true) of
        {ok, L} -> {ok, L + 2};
        notFound -> notFound
    end;
%% 字符串内遇到闭合引号：退出字符串模式，长度+1。
jsonSpan([$" | Rest], Depth, true) ->
    case jsonSpan(Rest, Depth, false) of
        {ok, L} -> {ok, L + 1};
        notFound -> notFound
    end;
%% 字符串外遇到引号：进入字符串模式，长度+1。
jsonSpan([$" | Rest], Depth, false) ->
    case jsonSpan(Rest, Depth, true) of
        {ok, L} -> {ok, L + 1};
        notFound -> notFound
    end;
%% 字符串外遇到 `{`：深度+1，长度+1。
jsonSpan([${ | Rest], Depth, false) ->
    case jsonSpan(Rest, Depth + 1, false) of
        {ok, L} -> {ok, L + 1};
        notFound -> notFound
    end;
%% 字符串外、深度为 1 时遇到 `}`：匹配成功，长度 1。
jsonSpan([$} | _Rest], 1, false) ->
    {ok, 1};
%% 字符串外、深度>1 时遇到 `}`：深度-1，长度+1。
jsonSpan([$} | Rest], Depth, false) when Depth > 1 ->
    case jsonSpan(Rest, Depth - 1, false) of
        {ok, L} -> {ok, L + 1};
        notFound -> notFound
    end;
%% 其它普通字符：长度+1，状态不变。
jsonSpan([_C | Rest], Depth, InStr) ->
    case jsonSpan(Rest, Depth, InStr) of
        {ok, L} -> {ok, L + 1};
        notFound -> notFound
    end.

%% 将 verdict 字符串/atom 规范化为 pass | warn | reject；未知值默认 pass。
normalizeVerdict(<<"pass">>) -> pass;
normalizeVerdict(<<"warn">>) -> warn;
normalizeVerdict(<<"reject">>) -> reject;
normalizeVerdict(Verdict) when is_atom(Verdict) -> Verdict;
normalizeVerdict(_) -> pass.

%% 将 score 规范化到 [0.0, 1.0]：数字钳位，binary 解析失败默认 0.5，其它默认 0.5。
normalizeScore(Score) when is_number(Score) ->
    max(0.0, min(1.0, Score + 0.0));
normalizeScore(Score) when is_binary(Score) ->
    try binary_to_float(Score) catch _:_ -> 0.5 end;
normalizeScore(_) ->
    0.5.

%%--------------------------------------------------------------------
%% @doc
%% 本地兜底评判：LLM 不可用时基于结构化风险模板检测答案，按发现数量与
%% 严重度计算 verdict/score/feedback，并返回 `findings` 列表供 UI 渲染。
%%
%% @param Reason LLM 失败原因
%% @return 评判 map，provider 为 localFallback，包含 findings 字段
%% @end
%%--------------------------------------------------------------------
localCritique(Question, Answer, _Context, Reason) ->
    Text = toBinary(Answer),
    Findings = scanFindings(Text),
    Sev = maxSeverity(Findings),
    Verdict = case Sev of
        high -> reject;
        medium -> warn;
        low -> warn;
        none -> pass
    end,
    Score = scoreFromFindings(Findings),
    #{
        provider => localFallback,
        reason => Reason,
        verdict => Verdict,
        score => Score,
        feedback => feedbackFromFindings(Findings, Verdict),
        safe => Sev =:= none orelse Sev =:= low,
        findings => Findings,
        question => Question
    }.

%%--------------------------------------------------------------------
%% @doc
%% 当 LLM 返回内容无法解析为 JSON 时的本地文本兜底评判：使用结构化风险模板
%% 扫描，并返回 findings 字段供 UI 渲染。
%%
%% @return 评判 map，provider 为 localFallback，包含 findings
%% @end
%%--------------------------------------------------------------------
localCritiqueText(Content) ->
    Text = toBinary(Content),
    Findings = scanFindings(Text),
    Sev = maxSeverity(Findings),
    Verdict = case Sev of
        high -> reject;
        medium -> warn;
        low -> warn;
        none -> pass
    end,
    #{
        provider => localFallback,
        verdict => Verdict,
        score => scoreFromFindings(Findings),
        feedback => Content,
        safe => Sev =:= none orelse Sev =:= low,
        findings => Findings
    }.

%%--------------------------------------------------------------------
%% @doc
%% 结构化风险模板：每条规则是一个 {Id, Pattern, Severity, Suggestion}。
%% Severity ∈ high / medium / low。扫描时返回命中规则的列表。
%%--------------------------------------------------------------------
-define(RiskRules, [
    {riskApplyPatch,   <<"apply_patch">>,   high,
        <<"未先 dryRun/validate 就直接建议 applyPatch，已拒绝。"/utf8>>},
    {riskApplyPatchAlt,<<"applypatch">>,    high,
        <<"未先 dryRun/validate 就直接建议 applyPatch，已拒绝。"/utf8>>},
    {riskDropTable,    <<"drop table">>,   high,
        <<"DROP TABLE 具有破坏性，必须有用户明确批准。"/utf8>>},
    {riskHalt,         <<"init:stop">>,    high,
        <<"停止节点会影响全部进程；未经确认不要建议。"/utf8>>},
    {riskHaltAlt,      <<"halt(">>,        high,
        <<"halt() 会终止 VM；请改建议优雅停止。"/utf8>>},
    {riskDelete,       <<"delete">>,       medium,
        <<"请确认用户明确要求删除文件/数据库。"/utf8>>},
    {riskRmRf,         <<"rm -rf">>,       high,
        <<"递归强制删除可能清空工程；需用户明确确认。"/utf8>>},
    {riskShellCode,    <<"os:cmd">>,       medium,
        <<"尽量用封装好的工具，少直接 os:cmd 外壳调用。"/utf8>>},
    {riskEval,         <<"rpc:call">>,     low,
        <<"跨节点 RPC 需说明必要性与超时。"/utf8>>}
]).

%%--------------------------------------------------------------------
%% @doc
%% 扫描文本命中风险规则，返回 findings 列表。
%% 每条 finding = #{rule, severity, snippet, suggestion}。
%%
%% @param Text 待扫描文本（binary）
%% @return finding map 列表
%% @end
%%--------------------------------------------------------------------
scanFindings(Text) ->
    Lower = string:lowercase(unicode:characters_to_list(Text)),
    lists:foldl(fun({Id, Pattern, Sev, Suggestion}, Acc) ->
        case findAll(Lower, Pattern) of
            [] -> Acc;
            Positions ->
                [makeFinding(Id, Sev, Suggestion, Text, P) || P <- Positions] ++ Acc
        end
    end, [], ?RiskRules).

%% 在 Lower 中查找 Pattern 全部出现位置（基于 string:find 全量扫描）。
%% 全部以 list 形式计算位置，Position 为相对原串的 1-based 绝对下标。
findAll(Haystack, Needle) ->
    findAllAbs(Haystack, Needle, 0).

findAllAbs(Haystack, Needle, Offset) ->
    case string:find(Haystack, Needle) of
        nomatch -> [];
        Match ->
            RelPos = string:str(Haystack, Match),
            AbsPos = Offset + RelPos,
            Len = length(Match),
            Rest = string:slice(Haystack, RelPos + Len),
            [{AbsPos, Len} | findAllAbs(Rest, Needle, Offset + RelPos + Len - 1)]
    end.

%% 构造单条 finding map。
makeFinding(Id, Sev, Suggestion, Text, {Pos, Len}) ->
    #{
        rule => Id,
        severity => Sev,
        snippet => extractSnippet(Text, Pos, Len),
        suggestion => Suggestion
    }.

%% 在原文本中截取命中点周围 80 字符窗口（不足时尽量保留全部）。
extractSnippet(Text, Pos, Len) ->
    Chars = unicode:characters_to_list(Text),
    Start = max(1, Pos - 30),
    End = min(length(Chars), Pos + Len + 50),
    unicode:characters_to_binary(string:slice(Chars, Start, End - Start)).

%% 取 findings 中最高严重度；空列表返回 none。
maxSeverity(Findings) ->
    Sevs = [maps:get(severity, F, none) || F <- Findings],
    case lists:member(high, Sevs) of
        true -> high;
        false ->
            case lists:member(medium, Sevs) of
                true -> medium;
                false ->
                    case lists:member(low, Sevs) of
                        true -> low;
                        false -> none
                    end
            end
    end.

%% 基于 findings 计算 0.0-1.0 的安全分：high 直接 0.2，medium 0.5，low 0.7，none 0.85。
scoreFromFindings(Findings) ->
    Sev = maxSeverity(Findings),
    case Sev of
        high -> 0.2;
        medium -> 0.5;
        low -> 0.7;
        none -> 0.85
    end.

%% 根据 findings 拼接 feedback 文本，限 280 字符。
feedbackFromFindings(Findings, Verdict) ->
    Header = case Verdict of
        reject -> <<"[local] answer rejected by risk template: ">>;
        warn -> <<"[local] answer warns of risk: ">>;
        _ -> <<"[local] answer passed local critic">>
    end,
    Summary = case Findings of
        [] -> <<"no findings">>;
        _ ->
            UniqueRules = lists:usort([maps:get(rule, F) || F <- Findings]),
            Tokens = [<<(atom_to_binary(R, utf8))/binary, " ">> || R <- UniqueRules],
            iolist_to_binary(Tokens)
    end,
    iolist_to_binary([Header, Summary]).

%% binary 原样返回。
toBinary(Value) when is_binary(Value) ->
    Value;
%% atom 转 binary。
toBinary(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
%% list 转 binary。
toBinary(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
%% map 优先用 alJson + session_mgr 编码，失败回退到 ~p 格式化。
toBinary(Value) when is_map(Value) ->
    try erlang:iolist_to_binary(alJson:encode(alSessionMgr:encodeMessage(Value)))
    catch _:_ -> erlang:iolist_to_binary(io_lib:format("~p", [Value]))
    end;
%% 其它类型用 ~p 格式化为 binary。
toBinary(Value) ->
    unicode:characters_to_binary(io_lib:format("~p", [Value])).
