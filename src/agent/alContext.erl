%%%-------------------------------------------------------------------
%% @doc 系统提示、技能注入、记忆上下文与历史压缩。
%% @end
%%%-------------------------------------------------------------------

-module(alContext).

-export([
    buildSystemPrompt/2,
    prepareMessages/4,
    trimMessages/2,
    injectWorkingContext/2,
    activeSkills/1,
    activeSkills/2,
    previewTrim/2,
    lastCompaction/0
]).

%% Test helpers
-export([isLlmSafeMessage/1, normalizeRole/1]).

-define(LastKey, {?MODULE, lastCompactionStats}).

%% 硬纪律：与 persona 身份分离，始终注入。细则见各工具 description，此处只留反臆造硬约束。
-define(HardDiscipline,
    <<"语言：与用户同语（中文问则中文答）。工具名/MFA/路径保持原文。\n"
      "自述：被问身份/能力/限制时，只描述角色与工具能力；底层模型、供应商、"
      "版本号、上下文窗口等技术参数不在任何工具结果中——禁止猜测编造，"
      "答不出就明说「不在可用信息中」。系统限制只引用 [self] 注入的真实值。\n"
      "行动：先想再调。证据不足必须发 tool_calls，禁止把「下一步打算调工具」当终答。"
      "调工具前用一两句说明：已知/还缺/为何选它。\n"
      "证据：结论须引用本轮工具结果的 file:line / MFA；禁止凭记忆编造路径、行号、未出现过的 MFA。"
      "@module/@path/@mfa 与 retrieved_context.anchors 优先于搜索猜测。\n"
      "路径：只能来自 anchors 或工具命中（resolveModule/gotoDef/searchCode/moduleSymbols）。"
      "只知模块名先 resolveModule（接受 mod 或 mod.erl）。禁止拼接 topLevel，禁止臆造 boot/...。"
      "enoent 用索引建议；相关 *_port.erl 命中不等于目标模块不存在。\n"
      "代码：谁调用→一次 getCallers/findRefs（byModule 已完整，勿逐文件复核，勿用 callGraph 顶替）。"
      "searchText 须收窄 path，禁止全仓并行。读函数→getSymbolSource；大文件→readFilePage。"
      "file:line 须来自本轮读源码（或用户贴文）。同参勿重试。多步用 todoWrite。\n"
      "数据：「怎么查」→traceDataQuery（有 retrieved_context.dataQuery 则用之），勿猜 get*/query*。"
      "低置信请用户给 @table/@mfa。已核实结论可 saveKnowledge。\n"
      "运行：已在本 live 节点，勿称离线/沙箱。禁止编造运行时数值与 MFA。\n"
      "执行分流：用户已给出明确 Mod:Fun(Args) → runMfa（写操 sideEffect=write；"
      "notExported 用返回样本，勿再猜）。自然语言要达成业务结果（修建筑、加钱、"
      "改玩家数据等多步）→ 先 searchCode/getSymbol/moduleExports 找齐真实 MFA，"
      "再 evalErl 拼表达式或匿名 fun 一次执行；组合≥2 个调用必须 evalErl，不要只 narrate。"
      "不确定先 dryRun=true，通过后再执行。dbQuery 仅 ali 本地 SQLite。"
      "热更用 hotReload，勿 raw purge。\n"
      "VCS：最后一次→lastCommit；最近 N 条→recentCommits；按天→dailyReview(days=1)；"
      "深挖→reviewChangeImpact。禁止用 dailyReview(days=30) 答「最后一次」。\n"
      "联网：只根据工具结果引用，句末 [n]，文末 Sources。空结果如实说。\n"
      "改码：validatePatch → dryRunPatch → applyPatch。保持简洁。"/utf8>>).

%%--------------------------------------------------------------------
%% @doc
%% 构建系统提示词：Persona 身份 + 硬纪律 + Extra + Skills + 上下文。
%%
%% @param Question 用户问题（用于匹配技能 / persona）
%% @param Opts 选项映射（含 agentCfg 与可选 workingContext / persona）
%% @return 拼接完成的系统提示词二进制
%% @end
%%--------------------------------------------------------------------
-spec buildSystemPrompt(binary(), map()) -> binary().
buildSystemPrompt(Question, Opts) ->
    AgentCfg = maps:get(agentCfg, Opts, alConfig:getAgentCfg()),
    Resolved = alPersona:resolve(Question, Opts#{agentCfg => AgentCfg}),
    WithIdentity = alPersona:inject(?HardDiscipline, Resolved),
    %% Config may yield binary / string / undefined — normalize before concat.
    Base = case normalizeExtra(maps:get(systemPromptExtra, AgentCfg, <<>>)) of
        <<>> -> WithIdentity;
        Extra -> <<WithIdentity/binary, "\n\n", Extra/binary>>
    end,
    SkillsEnabled = maps:get(skillsEnabled, AgentCfg, true),
    Prompt1 = case SkillsEnabled of
        true ->
            Names = activeSkills(Question, Opts#{agentCfg => AgentCfg, personaResolved => Resolved}),
            alSkill:inject(Base, Names);
        false ->
            Base
    end,
    %% 注入工具成功率警告：高失败率工具会让 LLM 更谨慎使用。
    Prompt2 = injectToolWarnings(Prompt1),
    Prompt2b = injectSelfFacts(Prompt2, AgentCfg),
    Prompt2c = injectPreferredTools(Prompt2b, Opts),
    Prompt2d = injectCriticFeedback(Prompt2c, Opts),
    Prompt3 = case maps:get(workingContext, Opts, undefined) of
        undefined -> Prompt2d;
        Ctx -> injectWorkingContext(Prompt2d, Ctx)
    end,
    case maps:get(modePromoted, Opts, false) of
        true ->
            <<Prompt3/binary,
              "\n\n[session] 因用户要求改代码，模式已自动提升为 edit。"
              "流程：validatePatch → dryRunPatch → applyPatch。"
              "线上单次 MFA 用 runMfa；多步业务拼装用 evalErl。"/utf8>>;
        _ ->
            case maps:get(mode, Opts, ask) of
                edit ->
                    <<Prompt3/binary,
                      "\n\n[session] mode=edit：可写工具（applyPatch/writeFile/rollbackPatch）可用。"/utf8>>;
                exec ->
                    <<Prompt3/binary,
                      "\n\n[session] mode=exec：可写与风险工具可用。"/utf8>>;
                plan ->
                    <<Prompt3/binary,
                      "\n\n[session] mode=plan（规划模式）：禁止写文件与高风险执行。"
                      "优先 todoWrite/planSet 列出步骤，用只读工具调研；"
                      "不要 applyPatch/writeFile/runMfa(write)。完成后请用户切回 ask/edit。"/utf8>>;
                _ -> Prompt3
            end
    end.

%% 注入工具成功率警告到系统提示尾部。
injectToolWarnings(Prompt) ->
    case alMetrics:toolWarnings() of
        [] -> Prompt;
        Warnings ->
            WarningText = iolist_to_binary([
                <<"\n\n工具可靠性警告：\n"/utf8>>,
                [<<"- ", W/binary, "\n">> || W <- Warnings]
            ]),
            <<Prompt/binary, WarningText/binary>>
    end.

injectPreferredTools(Prompt, Opts) ->
    case maps:get(preferredTools, Opts, []) of
        [] ->
            Prompt;
        Tools ->
            Names = iolist_to_binary(lists:join(<<", ">>,
                [toolLabel(T) || T <- Tools])),
            <<Prompt/binary,
              "\n\n[tools] For this question, prefer trying (in order): ",
              Names/binary, ".">>
    end.

injectCriticFeedback(Prompt, Opts) ->
    case maps:get(criticFeedback, Opts, undefined) of
        FB when is_binary(FB), FB =/= <<>> ->
            <<Prompt/binary,
              "\n\n[critic] Previous draft was rejected. Address this before answering: ",
              FB/binary>>;
        _ ->
            Prompt
    end.

toolLabel(T) when is_atom(T) -> atom_to_binary(T, utf8);
toolLabel(T) when is_binary(T) -> T;
toolLabel(T) -> iolist_to_binary(io_lib:format("~p", [T])).

%%--------------------------------------------------------------------
%% @doc
%% 自述事实注入：把真实的会话预算（来自 AgentCfg）注入系统提示，
%% 被问「上下文窗口多大/能记多少条」时模型有真数据可引用，
%% 杜绝编造供应商/参数。值异常时跳过注入（宁缺勿错）。
%%
%% @param Prompt 已拼接的系统提示
%% @param AgentCfg Agent 配置
%% @return 追加了 [self] 段的提示
%% @end
%%--------------------------------------------------------------------
injectSelfFacts(Prompt, AgentCfg) when is_map(AgentCfg) ->
    MaxMsgs = toInt(maps:get(maxMessages, AgentCfg, 50)),
    MaxChars = toInt(maps:get(maxContextChars, AgentCfg, 120000)),
    MaxTokens = toInt(maps:get(maxContextTokens, AgentCfg, 100000)),
    case MaxMsgs > 0 andalso MaxChars > 0 andalso MaxTokens > 0 of
        true ->
            SelfText = unicode:characters_to_binary(io_lib:format(
                "\n\n[self] 真实系统参数（自述限制时只引用这些值）："
                "会话历史上限 ~b 条消息；上下文预算 ~b 字符（估算 ~b tokens，"
                "超限自动压缩历史）。底层模型/供应商信息未提供——"
                "被问及就如实说不知道，禁止编造。",
                [MaxMsgs, MaxChars, MaxTokens])),
            <<Prompt/binary, SelfText/binary>>;
        false ->
            Prompt
    end;
injectSelfFacts(Prompt, _) ->
    Prompt.

toInt(I) when is_integer(I) -> I;
toInt(B) when is_binary(B) ->
    try binary_to_integer(B) catch _:_ -> 0 end;
toInt(L) when is_list(L) ->
    try list_to_integer(L) catch _:_ -> 0 end;
toInt(_) -> 0.

%% systemPromptExtra 可能来自 cfg：binary / iolist / string / undefined。
normalizeExtra(undefined) -> <<>>;
normalizeExtra(<<>>) -> <<>>;
normalizeExtra(B) when is_binary(B) -> B;
normalizeExtra([]) -> <<>>;
normalizeExtra(L) when is_list(L) ->
    case unicode:characters_to_binary(L) of
        B when is_binary(B) -> B;
        _ -> <<>>
    end;
normalizeExtra(_) -> <<>>.

%%--------------------------------------------------------------------
%% @doc
%% 根据用户问题文本匹配并返回激活的技能名列表。
%%
%% @param Question 问题文本（二进制或可转换值）
%% @return 技能原子名列表
%% @end
%%--------------------------------------------------------------------
-spec activeSkills(binary()) -> [atom()].
activeSkills(Question) ->
    activeSkills(Question, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 匹配技能；若未命中且 persona 有 recommendedSkills，则补 1 个推荐技能作轻量偏置。
%% @end
%%--------------------------------------------------------------------
-spec activeSkills(term(), map()) -> [atom()].
activeSkills(Question, Opts) when is_map(Opts) ->
    Q = toBinary(Question),
    AgentCfg = maps:get(agentCfg, Opts, alConfig:getAgentCfg()),
    Paths = try
        Anchors = alContextEngine:parseAnchors(Q),
        [toBinary(P) || P <- maps:get(paths, Anchors, [])]
    catch
        _:_ -> []
    end,
    Matched = alSkill:match(Q, #{paths => Paths}),
    case Matched of
        [_ | _] ->
            Matched;
        [] ->
            Resolved = case maps:get(personaResolved, Opts, undefined) of
                undefined -> alPersona:resolve(Q, Opts#{agentCfg => AgentCfg});
                R -> R
            end,
            case alPersona:recommendedSkills(Resolved) of
                [First | _] -> [First];
                _ -> []
            end
    end;
activeSkills(Question, _) ->
    activeSkills(Question, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 将工作上下文（模块/文件/进程）追加到系统提示词末尾；上下文缺失时原样返回。
%%
%% @param Prompt 系统提示词
%% @param Ctx 工作上下文映射
%% @return 拼接后的提示词二进制
%% @end
%%--------------------------------------------------------------------
-spec injectWorkingContext(binary(), map()) -> binary().
injectWorkingContext(Prompt, #{modules := Mods, files := Files, processes := Procs}) ->
    Section = iolist_to_binary([
        <<"\n\n## 工作上下文\n"/utf8>>,
        formatList(<<"模块"/utf8>>, Mods),
        formatList(<<"文件"/utf8>>, Files),
        formatList(<<"进程"/utf8>>, Procs)
    ]),
    <<Prompt/binary, Section/binary>>;
injectWorkingContext(Prompt, _) ->
    Prompt.

%% 将一组条目格式化为标签下的列表文本；空列表显示 (无)。
formatList(Label, []) ->
    <<Label/binary, ": (无)\n"/utf8>>;
formatList(Label, Items) ->
    Lines = [<<"- ", (toBinary(I))/binary, "\n">> || I <- Items],
    iolist_to_binary([Label, ":\n" | Lines]).

%%--------------------------------------------------------------------
%% @doc
%% 组装发送给 LLM 的消息列表：系统提示 + 检索上下文 + 用户问题 + 历史消息。
%%
%% @param Question 当前用户问题
%% @param Opts 选项映射
%% @param History 历史消息列表
%% @param Context 检索到的上下文映射
%% @return 待发送的消息列表
%% @end
%%--------------------------------------------------------------------
-spec prepareMessages(binary(), map(), [map()], map()) -> [map()].
prepareMessages(Question, Opts, History, Context) ->
    AgentCfg = maps:get(agentCfg, Opts, alConfig:getAgentCfg()),
    System = buildSystemPrompt(Question, Opts),
    Trimmed = trimMessages(History, AgentCfg),
    ContextBin = iolist_to_binary([
        <<"<retrieved_context>\n">>,
        alJson:encode(Context),
        <<"\n</retrieved_context>\n">>,
        <<"把 retrieved_context 仅当作检索提示。"
          "任何行为性结论请先用工具阅读所引源码。"/utf8>>
    ]),
    [
        #{role => system, content => System},
        #{role => user, content => ContextBin}
    ] ++ Trimmed ++ [
        #{role => user, content => Question}
    ].

%%--------------------------------------------------------------------
%% @doc
%% 对历史消息进行裁剪：保留最近若干条、过滤不安全消息，并按字符预算压缩。
%% 实际执行后会写一条 stats 到 process dict 供 {@link lastCompaction/0} 读取，
%% 供 WebUI 侧栏展示最近一次压缩的输入/输出条数与字符数。
%%
%% @param Messages 原始历史消息
%% @param AgentCfg Agent 配置（含 maxMessages、maxContextChars 等）
%% @return 裁剪后的消息列表
%% @end
%%--------------------------------------------------------------------
-spec trimMessages([map()], map()) -> [map()].
trimMessages(Messages, AgentCfg) when is_list(Messages) ->
    MaxMsgs = maps:get(maxMessages, AgentCfg, 50),
    MaxChars = maps:get(maxContextChars, AgentCfg, 120000),
    MaxTokens = maps:get(maxContextTokens, AgentCfg, 100000),
    KeepRecent = maps:get(keepRecentMessages, AgentCfg, 12),
    Compaction = maps:get(historyCompaction, AgentCfg, true),
    %% lists:sublist/3 start is 1-based; never pass 0.
    Start = max(1, length(Messages) - MaxMsgs + 1),
    Msgs0 = lists:sublist(Messages, Start, MaxMsgs),
    Msgs1 = [M || M <- Msgs0, isLlmSafeMessage(M)],
    Result = case Compaction of
        true ->
            %% First a cheap char-budget pass, then a token-aware pass that
            %% keeps system-adjacent recent turns and folds the middle into a
            %% single summary placeholder (system prompt is added by callers
            %% separately, so it is never dropped here).
            compactByTokens(compactByChars(Msgs1, MaxChars), MaxTokens, KeepRecent);
        false -> Msgs1
    end,
    recordCompaction(#{
        ts => erlang:system_time(millisecond),
        inputCount => length(Msgs1),
        outputCount => length(Result),
        inputChars => lists:sum([messageChars(M) || M <- Msgs1]),
        outputChars => lists:sum([messageChars(M) || M <- Result]),
        maxMessages => MaxMsgs,
        maxContextChars => MaxChars,
        compaction => Compaction
    }),
    Result;
trimMessages(_, _AgentCfg) ->
    [].

%% 把最近一次 trimMessages 的统计写进 process dict。
recordCompaction(Stats) ->
    put(?LastKey, Stats),
    Stats.

%%--------------------------------------------------------------------
%% @doc
%% 返回最近一次 {@link trimMessages/2} 的压缩统计。
%% 字段：`ts`（毫秒时间戳）、`inputCount`/`outputCount`（条数）、
%% `inputChars`/`outputChars`（估算字符数）、`maxMessages`/`maxContextChars`、
%% `compaction`（true/false）。从未调用过返回 `undefined`。
%%
%% @return 统计 map 或 undefined
%% @end
%%--------------------------------------------------------------------
-spec lastCompaction() -> map() | undefined.
lastCompaction() ->
    get(?LastKey).

%%--------------------------------------------------------------------
%% @doc
%% 不修改消息，直接预览 {@link trimMessages/2} 会对 `Messages` 应用什么裁剪。
%% 返回 map：`originalCount`、`trimmedCount`、`originalChars`、`trimmedChars`、
%% `wouldCompact`、`maxMessages`、`maxContextChars`。可在 UI 中展示给用户。
%%
%% @param Messages 原始历史消息
%% @param AgentCfg Agent 配置
%% @return 预览信息 map
%% @end
%%--------------------------------------------------------------------
-spec previewTrim([map()], map()) -> map().
previewTrim(Messages, AgentCfg) when is_list(Messages) ->
    MaxMsgs = maps:get(maxMessages, AgentCfg, 50),
    MaxChars = maps:get(maxContextChars, AgentCfg, 120000),
    Compaction = maps:get(historyCompaction, AgentCfg, true),
    OriginalChars = lists:sum([messageChars(M) || M <- Messages]),
    Trimmed = trimMessages(Messages, AgentCfg),
    TrimmedChars = lists:sum([messageChars(M) || M <- Trimmed]),
    #{
        originalCount => length(Messages),
        trimmedCount => length(Trimmed),
        originalChars => OriginalChars,
        trimmedChars => TrimmedChars,
        wouldCompact => OriginalChars > TrimmedChars orelse length(Messages) > length(Trimmed),
        maxMessages => MaxMsgs,
        maxContextChars => MaxChars,
        compaction => Compaction
    };
previewTrim(_Messages, _AgentCfg) ->
    #{originalCount => 0, trimmedCount => 0, originalChars => 0, trimmedChars => 0,
      wouldCompact => false, maxMessages => 0, maxContextChars => 0, compaction => false}.

%%--------------------------------------------------------------------
%% @doc
%% 判断单条消息是否可安全发送给 LLM：丢弃孤儿 tool 消息（无 tool_call_id）。
%%
%% @param Msg 待检查消息
%% @return boolean()
%% @end
%%--------------------------------------------------------------------
%% Drop orphan tool messages (role=tool without tool_call_id) — providers reject them.
%% Accept atom or binary roles from DB/checkpoint reloads.
isLlmSafeMessage(Msg) when is_map(Msg) ->
    case normalizeMsgRole(Msg) of
        {tool, M} ->
            maps:is_key(tool_call_id, M) orelse maps:is_key(<<"tool_call_id">>, M);
        {Role, _} when Role =:= system; Role =:= user; Role =:= assistant ->
            true;
        _ ->
            false
    end;
isLlmSafeMessage(_) ->
    false.

normalizeMsgRole(#{role := Role} = Msg) ->
    {normalizeRole(Role), Msg};
normalizeMsgRole(#{<<"role">> := Role} = Msg) ->
    {normalizeRole(Role), Msg#{role => normalizeRole(Role)}};
normalizeMsgRole(_) ->
    {other, #{}}.

normalizeRole(system) -> system;
normalizeRole(<<"system">>) -> system;
normalizeRole(user) -> user;
normalizeRole(<<"user">>) -> user;
normalizeRole(assistant) -> assistant;
normalizeRole(<<"assistant">>) -> assistant;
normalizeRole(tool) -> tool;
normalizeRole(<<"tool">>) -> tool;
normalizeRole(_) -> other.

%% 当消息总字符数超过预算时进入丢弃流程；否则原样返回。
%% 单次遍历计算总长度，超预算时反向累加找出可保留的最长后缀，避免 O(n²)。
compactByChars(Messages, MaxChars) ->
    Sizes = [messageChars(M) || M <- Messages],
    Total = lists:sum(Sizes),
    case Total =< MaxChars of
        true -> Messages;
        false ->
            KeepCount = countKeepable(lists:reverse(Sizes), MaxChars, 0, 0),
            lists:sublist(Messages, length(Messages) - KeepCount + 1, KeepCount)
    end.

%% 反向遍历 sizes（已是 reverse 后的），从原尾部累加直到超过预算。
countKeepable([S | Rest], MaxChars, Acc, Count) ->
    case Acc + S =< MaxChars of
        true -> countKeepable(Rest, MaxChars, Acc + S, Count + 1);
        false -> Count
    end;
countKeepable([], _MaxChars, _Acc, Count) ->
    Count.

%%--------------------------------------------------------------------
%% @doc
%% 基于 token 预算压缩：使用 alTokenStats 的 CJK 感知估算，若消息
%% 总 token 超过 MaxTokens，则保留最近 KeepRecent 轮，把更早的消息
%% 折叠为单条「摘要占位」user 消息（拼接旧轮关键句）。system 提示由
%% 调用方单独拼接，不在此丢弃。
%%
%% @param Messages   已按字符预算压缩后的消息列表
%% @param MaxTokens  token 预算上限（0 或负数表示不限制）
%% @param KeepRecent 保留的最近消息条数
%% @return 压缩后的消息列表
%% @end
%%--------------------------------------------------------------------
compactByTokens(Messages, MaxTokens, _KeepRecent) when not is_integer(MaxTokens); MaxTokens =< 0 ->
    Messages;
compactByTokens(Messages, MaxTokens, KeepRecent) ->
    case alTokenStats:estimateMessages(Messages) =< MaxTokens of
        true ->
            Messages;
        false ->
            N = length(Messages),
            Keep = max(1, min(KeepRecent, N)),
            case N =< Keep of
                true ->
                    Messages;
                false ->
                    {Older, Recent0} = lists:split(N - Keep, Messages),
                    %% Splitting mid-round can orphan tool messages (their
                    %% assistant parent went into Older) — drop leading tool msgs.
                    Recent = dropLeadingToolMessages(Recent0),
                    Placeholder = #{role => user, content => summarizeOlder(Older)},
                    [Placeholder | Recent]
            end
    end.

%% 丢弃列表头部的 tool 角色消息（其对应的 assistant(tool_calls) 已被折叠）。
dropLeadingToolMessages([Msg | Rest]) ->
    case normalizeRole(maps:get(role, Msg, maps:get(<<"role">>, Msg, undefined))) of
        tool -> dropLeadingToolMessages(Rest);
        _ -> [Msg | Rest]
    end;
dropLeadingToolMessages([]) ->
    [].

%% 将较早的消息折叠为单条摘要文本：逐条取「角色 + 首句」，拼接后限长。
summarizeOlder(Older) ->
    Lines = [Line || Line <- [summaryLine(M) || M <- Older], Line =/= <<>>],
    Joined = joinSummaryLines(Lines),
    Capped = capBinary(Joined, 4000),
    <<"[较早对话已摘要，以适配上下文预算]\n"/utf8, Capped/binary>>.

%% 单条消息的摘要行：`- <role>: <首句>`；无文本内容返回空。
summaryLine(M) ->
    case contentText(M) of
        <<>> -> <<>>;
        Text ->
            case firstSentence(Text, 160) of
                <<>> -> <<>>;
                Snippet ->
                    Role = atom_to_binary(normalizeRole(maps:get(role, M, maps:get(<<"role">>, M, user))), utf8),
                    <<"- ", Role/binary, ": ", Snippet/binary>>
            end
    end.

%% 提取消息内容的纯文本（binary/list）；结构化(map)/多模态内容跳过。
contentText(#{content := C}) -> toText(C);
contentText(#{<<"content">> := C}) -> toText(C);
contentText(_) -> <<>>.

toText(C) when is_binary(C) -> C;
toText(C) when is_list(C) ->
    case unicode:characters_to_binary(C) of
        B when is_binary(B) -> B;
        _ -> <<>>
    end;
toText(_) -> <<>>.

%% 取首行且限制到 MaxChars 个字符（按码点切分，避免截断多字节字符）。
firstSentence(Text, MaxChars) ->
    Line = case binary:split(Text, <<"\n">>) of
        [First | _] -> First;
        _ -> Text
    end,
    unicode:characters_to_binary(string:slice(Line, 0, MaxChars)).

joinSummaryLines([]) -> <<>>;
joinSummaryLines([L]) -> L;
joinSummaryLines([L | Rest]) ->
    <<L/binary, "\n", (joinSummaryLines(Rest))/binary>>.

%% 按码点安全地把二进制限制到 MaxChars 字符，超出追加省略号。
capBinary(Bin, MaxChars) ->
    case string:length(Bin) =< MaxChars of
        true -> Bin;
        false ->
            Head = unicode:characters_to_binary(string:slice(Bin, 0, MaxChars)),
            <<Head/binary, "\n...[summary truncated]">>
    end.

%% 估算消息内容的字节长度；无法识别的内容按 64 字节兜底。
messageChars(#{content := Content}) when is_binary(Content) ->
    byte_size(Content);
messageChars(#{content := Content}) when is_list(Content) ->
    byte_size(unicode:characters_to_binary(Content));
messageChars(#{content := Content}) when is_map(Content) ->
    byte_size(unicode:characters_to_binary(io_lib:format("~p", [Content])));
messageChars(_) ->
    64.

%% 将多种类型的值统一转换为二进制。
toBinary(B) when is_binary(B) -> B;
toBinary(L) when is_list(L) -> unicode:characters_to_binary(L);
toBinary(A) when is_atom(A) -> atom_to_binary(A, utf8);
toBinary(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).
