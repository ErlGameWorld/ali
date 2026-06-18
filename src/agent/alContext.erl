%%%-------------------------------------------------------------------
%%% @doc LLM 对话上下文构建模块。
%%%
%%% 负责组装系统提示词、项目摘要、运行模式说明、工作上下文，
%%% 以及裁剪历史消息后拼接用户输入，供 {@link alLoop} 调用 LLM。
%%% 支持原生工具调用与文本 `<tool_call>` 两种模式。
%%% @end
%%%-------------------------------------------------------------------
-module(alContext).

-export([
    buildSystemPrompt/1,
    buildMessages/3,
    trimHistory/2,
    trimHistorySafe/2,
    trimHistoryByTokens/2,
    conversationHistory/1,
    projectSummary/1
]).

%% 默认保留的最大对话消息条数（不含 system）
-define(DEFAULT_MAX_MESSAGES, 40).

%% @doc 根据配置构建系统提示词（system message 内容）。
%% 原生工具模式下注入工具使用规则；否则附带 alTools 工具描述与
%% `<tool_call>` 文本格式说明。
%% @param Config 含 projectRoot、useNativeTools 等的配置 map
%% @returns `{binary()}` 系统提示词
-spec buildSystemPrompt(map()) -> binary().
buildSystemPrompt(Config) ->
    Root = maps:get(projectRoot, Config, <<"."/utf8>>),
    case useNativeTools(Config) of
        true ->
            iolist_to_binary([
                <<"You are an Erlang/OTP development agent running inside an Erlang node.\n"/utf8>>,
                <<"You help users understand, analyze, debug, and modify their Erlang project.\n\n"/utf8>>,
                <<"Project root: "/utf8>>, toBinary(Root), <<"\n\n"/utf8>>,
                <<"Use the provided tools when you need project or runtime information.\n"/utf8>>,
                <<"Rules:\n"/utf8>>,
                <<"- For overall node/runtime status, call runtimeSummary once instead of many separate tools.\n"/utf8>>,
                <<"- For agent settings: use callFunction once with ali:getAgentConfig/0 or the agentConfig tool. Do NOT use runtimeSummary for config-only questions.\n"/utf8>>,
                <<"- Minimize tool rounds: batch related reads and then answer.\n"/utf8>>,
                <<"- Distinguish facts from project code vs general advice.\n"/utf8>>,
                <<"- Prefer reading project files before answering code questions.\n"/utf8>>,
                <<"- writeFile and patchFile require user confirmation; explain planned changes first.\n"/utf8>>,
                <<"- For code structure: use codeIndex, getFunctionSource, analyzeCalls, findCallers, dependencyGraph.\n"/utf8>>,
                <<"- For OTP/runtime: use getSupTree, getAppInfo, etopSummary; avoid runtimeSummary for simple config queries.\n"/utf8>>,
                <<"- For edits: preview diff first; writeFile/patchFile need confirmation; then compileLoad to hot-reload.\n"/utf8>>,
                <<"- Respond in the user's language when possible.\n"/utf8>>
            ]);
        false ->
            Tools = alTools:toolDescriptions(),
            iolist_to_binary([
                <<"You are an Erlang/OTP development agent running inside an Erlang node.\n"/utf8>>,
                <<"You help users understand, analyze, debug, and modify their Erlang project.\n\n"/utf8>>,
                <<"Project root: "/utf8>>, toBinary(Root), <<"\n\n"/utf8>>,
                <<"Available tools:\n"/utf8>>, Tools, <<"\n\n"/utf8>>,
                <<"When you need to use a tool, respond ONLY with one or more blocks in this exact format:\n"/utf8>>,
                <<"<tool_call>\n"/utf8>>,
                <<"{\"id\":\"1\",\"tool\":\"readFile\",\"args\":{\"path\":\"README.md\"}}\n"/utf8>>,
                <<"</tool_call>\n\n"/utf8>>,
                <<"Rules:\n"/utf8>>,
                <<"- Use camelCase tool names exactly as listed.\n"/utf8>>,
                <<"- After receiving tool results, either call more tools or give the final answer.\n"/utf8>>,
                <<"- For final answers, respond in plain text without <tool_call> tags.\n"/utf8>>,
                <<"- Distinguish facts from project code vs general advice.\n"/utf8>>,
                <<"- Prefer reading project files before answering code questions.\n"/utf8>>,
                <<"- writeFile and patchFile require user confirmation; explain planned changes first.\n"/utf8>>
            ])
    end.

%% @doc 构建完整的 LLM 消息列表。
%% 依次注入系统提示、项目摘要、模式说明、工作上下文、裁剪后的历史及当前用户消息。
%% @param Config 配置 map，可含 maxMessages、mode、workingContext 等
%% @param History 历史消息列表
%% @param UserPrompt 当前用户输入（binary）
%% @returns `[map()]` llmCli 格式的消息列表
-spec buildMessages(map(), [map()], binary()) -> [map()].
buildMessages(Config, History, UserPrompt) ->
    System = buildSystemPrompt(Config),
    Summary = projectSummary(Config),
    ModeNote = modePrompt(Config),
    ContextNote = workingContextPrompt(Config),
    Base = [
        llmCli:systemMessage(System),
        llmCli:systemMessage(Summary),
        llmCli:systemMessage(ModeNote),
        llmCli:systemMessage(ContextNote)
    ],
    Max = maps:get(maxMessages, Config, ?DEFAULT_MAX_MESSAGES),
    Trimmed = case maps:get(maxTokens, Config, undefined) of
        undefined ->
            trimHistorySafe(History, Max);
        TokenBudget when is_integer(TokenBudget), TokenBudget > 0 ->
            trimHistoryByTokens(trimHistorySafe(History, Max), TokenBudget)
    end,
    Base ++ Trimmed ++ [llmCli:userMessage(UserPrompt)].

%% 会话持久化用：去掉 system，避免下次重复注入
%% @doc 从完整消息列表中提取可持久化的对话历史（过滤 role=system）。
%% @param Messages 完整消息列表
%% @returns `[map()]` 不含 system 角色的消息
-spec conversationHistory([map()]) -> [map()].
conversationHistory(Messages) ->
    [M || M = #{role := Role} <- Messages, Role =/= system].

%% @doc 裁剪历史消息至 Max 条（委托 trimHistorySafe/2）。
%% @param History 历史消息列表
%% @param Max 保留的最大条数
%% @returns `[map()]`
-spec trimHistory([map()], pos_integer()) -> [map()].
trimHistory(History, Max) ->
    trimHistorySafe(History, Max).

%% @doc 安全裁剪对话历史：保留最近 Max 条非 system 消息，
%% 并移除开头孤立的 tool 消息或不完整的 assistant+tool_calls 前缀。
%% @param History 历史消息列表
%% @param Max 保留的最大条数
%% @returns `[map()]`
-spec trimHistorySafe([map()], pos_integer()) -> [map()].
trimHistorySafe(History, Max) ->
    Conv = conversationHistory(History),
    Trimmed = case length(Conv) =< Max of
        true -> Conv;
        false -> lists:nthtail(length(Conv) - Max, Conv)
    end,
    dropOrphanPrefix(Trimmed).

%% @doc 按估算 token 预算裁剪历史（从最新消息向前保留）。
%% 单条消息至少计 1 token；与 {@link trimHistorySafe/2} 配合使用。
-spec trimHistoryByTokens([map()], pos_integer()) -> [map()].
trimHistoryByTokens(History, MaxTokens) ->
    trimHistoryByTokensRev(lists:reverse(History), MaxTokens, []).

trimHistoryByTokensRev([], _Budget, Acc) ->
    lists:reverse(Acc);
trimHistoryByTokensRev([Msg | Rest], Budget, Acc) ->
    Cost = messageTokenCost(Msg),
    case Cost =< Budget of
        true ->
            trimHistoryByTokensRev(Rest, Budget - Cost, [Msg | Acc]);
        false ->
            lists:reverse(Acc)
    end.

messageTokenCost(#{content := Content}) ->
    max(1, llmCli:estimateTokens(contentCost(Content)));
messageTokenCost(#{tool_calls := Calls}) when is_list(Calls) ->
    Bin = llmJson:encode(Calls),
    max(1, llmCli:estimateTokens(Bin));
messageTokenCost(_) ->
    1.

contentCost(null) -> <<>>;
contentCost(C) when is_binary(C) -> C;
contentCost(C) when is_list(C) -> unicode:characters_to_binary(C);
contentCost(C) -> unicode:characters_to_binary(io_lib:format("~p", [C])).

%% @doc 返回项目索引摘要文本（带 120 秒 persistent_term 缓存）。
%% @param Config 含 projectRoot 的配置 map
%% @returns `{binary()}` 描述索引模块数量或提示尚未预热
-spec projectSummary(map()) -> binary().
projectSummary(Config) ->
    Root = maps:get(projectRoot, Config, <<"."/utf8>>),
    Now = erlang:monotonic_time(second),
    CacheKey = {?MODULE, projectSummary},
    case persistent_term:get(CacheKey, undefined) of
        {Root, Summary, Ts} when Now - Ts =< 120 ->
            Summary;
        _ ->
            Summary = buildProjectSummary(Config),
            persistent_term:put(CacheKey, {Root, Summary, Now}),
            Summary
    end.

%% 查询 alCodeIndexer 统计并生成项目索引摘要文本
buildProjectSummary(_Config) ->
    case alCodeIndexer:get_stats() of
        #{moduleCount := Count} when Count > 0 ->
            iolist_to_binary([
                <<"Project index (cached): "/utf8>>, integer_to_binary(Count), <<" modules indexed.\n"/utf8>>,
                <<"Use codeIndex to refresh, getFunctionSource/analyzeCalls for deep analysis."/utf8>>
            ]);
        _ ->
            iolist_to_binary([
                <<"Project index not warmed yet. "/utf8>>,
                <<"Call codeIndex tool when you need module/function lookup.\n"/utf8>>
            ])
    end.

%% 根据 Config 中的 mode 生成当前运行模式说明 system 片段
modePrompt(Config) ->
    Mode = maps:get(mode, Config, ask),
    Text = case Mode of
        ask -> <<"Current mode: ask (read-only analysis and Q&A)."/utf8>>;
        edit -> <<"Current mode: edit (file changes allowed with confirmation)."/utf8>>;
        exec -> <<"Current mode: exec (function execution and compileLoad encouraged)."/utf8>>;
        _ -> <<"Current mode: ask."/utf8>>
    end,
    iolist_to_binary([<<"Agent mode:\n"/utf8>>, Text]).

%% 将 workingContext 中的 modules/files/processes 格式化为 system 片段
workingContextPrompt(Config) ->
    Ctx = maps:get(workingContext, Config, #{}),
    Mods = maps:get(modules, Ctx, []),
    Files = maps:get(files, Ctx, []),
    Procs = maps:get(processes, Ctx, []),
    case Mods =:= [] andalso Files =:= [] andalso Procs =:= [] of
        true ->
            <<"Working context: (empty)"/utf8>>;
        false ->
            iolist_to_binary([
                <<"Working context:\n"/utf8>>,
                formatCtx(<<"modules"/utf8>>, Mods),
                formatCtx(<<"files"/utf8>>, Files),
                formatCtx(<<"processes"/utf8>>, Procs)
            ])
    end.

%% 格式化工作上下文中某一类条目；空列表返回空 binary
formatCtx(_Label, []) -> <<>>;
formatCtx(Label, Items) ->
    iolist_to_binary([
        <<"  "/utf8>>, Label, <<": "/utf8>>,
        unicode:characters_to_binary(io_lib:format("~p", [Items])),
        <<"\n"/utf8>>
    ]).

%% 判断是否使用 LLM 原生 function calling（需配置开启且 provider 支持）
useNativeTools(Config) ->
    case maps:get(useNativeTools, Config, true) of
        false -> false;
        true ->
            Provider = llmCli:getConfig(provider, openai),
            Provider =:= openai orelse Provider =:= deepseek
                orelse Provider =:= anthropic orelse Provider =:= custom
    end.

%% 将任意值转为 binary
toBinary(X) when is_binary(X) -> X;
toBinary(X) when is_list(X) -> unicode:characters_to_binary(X);
toBinary(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).

%% 移除裁剪后开头的孤立 tool 消息，或不完整的 assistant tool_calls 前缀
dropOrphanPrefix([#{role := tool} | Rest]) ->
    dropOrphanPrefix(Rest);
dropOrphanPrefix([#{role := assistant, tool_calls := Calls} | Rest] = Ms)
        when is_list(Calls) ->
    case countLeadingTools(Rest) =:= length(Calls) of
        true -> Ms;
        false -> dropOrphanPrefix(Rest)
    end;
dropOrphanPrefix(Messages) ->
    Messages.

%% 统计消息列表开头连续 tool 角色的条数
countLeadingTools(Messages) ->
    countLeadingTools(Messages, 0).

countLeadingTools([#{role := tool} | Rest], N) ->
    countLeadingTools(Rest, N + 1);
countLeadingTools(_, N) ->
    N.