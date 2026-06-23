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
    compactHistory/1,
    conversationHistory/1,
    sanitizeToolHistory/1,
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
    LangRule = <<"- 默认使用简体中文回答用户（除非用户明确使用其他语言）。\n"/utf8>>,
    StructRule = <<"- 适合用图表表达的内容（流程、状态机、时序、类关系等）使用 Mermaid 围栏块（```mermaid ... ```）输出。\n"
                   "- 适合用表格表达的内容（对比、属性列表、参数说明等）使用 Markdown 表格（| 列 | 列 |）输出。\n"
                   "- 代码示例使用带语言标签的围栏代码块（如 ```erlang ... ```）。\n"/utf8>>,
    PlanRule = <<"- 对需要多步完成的复杂任务，先用 planSet 制定步骤清单，执行中用 planUpdate 标记进度，完成后核对。\n"
                 "- 不确定相关代码在哪里时，优先用 searchCode（语义检索，查函数/模块名）或 semanticSearch（自然语言搜索代码片段）快速定位，定位到目标函数后再用 readFile 或 getFunctionSource 精读源码，避免盲目遍历目录。\n"/utf8>>,
    Body = case useNativeTools(Config) of
        true ->
            [
                <<"You are an Erlang/OTP development agent running inside an Erlang node.\n"/utf8>>,
                <<"You help users understand, analyze, debug, and modify their Erlang project.\n\n"/utf8>>,
                <<"Project root: "/utf8>>, toBinary(Root), <<"\n\n"/utf8>>,
                <<"Use the provided tools when you need project or runtime information.\n"/utf8>>,
                <<"- Do NOT reply with only a preamble (e.g. \"let me look at the project\"); call tools first, then answer.\n"/utf8>>,
                <<"Rules:\n"/utf8>>,
                <<"- For overall node/runtime status, call runtimeSummary once instead of many separate tools.\n"/utf8>>,
                <<"- For agent settings: use callFunction once with ali:getAgentConfig/0 or the agentConfig tool. Do NOT use runtimeSummary for config-only questions.\n"/utf8>>,
                <<"- Minimize tool rounds: batch related reads and then answer.\n"/utf8>>,
                <<"- Distinguish facts from project code vs general advice.\n"/utf8>>,
                <<"- Prefer reading project files before answering code questions.\n"/utf8>>,
                <<"- writeFile and patchFile require user confirmation; explain planned changes first.\n"/utf8>>,
                <<"- For code structure: use codeIndex, getFunctionSource, analyzeCalls, findCallers, dependencyGraph.\n"/utf8>>,
                <<"- For OTP/runtime: use getSupTree, getAppInfo, etopSummary, etsTables; avoid runtimeSummary for simple config queries.\n"/utf8>>,
                <<"- For edits: preview diff first; writeFile/patchFile need confirmation; then compileLoad to hot-reload.\n"/utf8>>,
                PlanRule,
                StructRule,
                LangRule
            ];
        false ->
            Tools = alTools:toolDescriptions(),
            [
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
                <<"- writeFile and patchFile require user confirmation; explain planned changes first.\n"/utf8>>,
                PlanRule,
                StructRule,
                LangRule
            ]
    end,
    iolist_to_binary(Body ++ extraPrompt(Config)).

%% 读取并拼接用户自定义的系统提示词补充（配置项 systemPromptExtra）。
extraPrompt(Config) ->
    case maps:get(systemPromptExtra, Config, <<>>) of
        Extra when is_binary(Extra), Extra =/= <<>> ->
            [<<"\n"/utf8>>, Extra];
        Extra when is_list(Extra), Extra =/= [] ->
            [<<"\n"/utf8>>, unicode:characters_to_binary(Extra)];
        _ ->
            []
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
    Max = maps:get(maxMessages, Config, ?DEFAULT_MAX_MESSAGES),
    Conv = conversationHistory(History),
    {Dropped, Kept1} = case length(Conv) =< Max of
        true -> {[], Conv};
        false -> lists:split(length(Conv) - Max, Conv)
    end,
    Kept2 = case maps:get(maxTokens, Config, undefined) of
        undefined ->
            Kept1;
        TokenBudget when is_integer(TokenBudget), TokenBudget > 0 ->
            trimHistoryByTokens(Kept1, TokenBudget)
    end,
    Kept = sanitizeToolHistory(Kept2),
    Compaction = case maps:get(historyCompaction, Config, true) of
        false -> [];
        _ -> compactHistory(Dropped)
    end,
    Attachments = #{
        images => maps:get(images, Config, []),
        files => maps:get(files, Config, []),
        documents => maps:get(documents, Config, [])
    },
    HasAttach = maps:get(images, Config, []) =/= []
        orelse maps:get(files, Config, []) =/= []
        orelse maps:get(documents, Config, []) =/= [],
    UserMsg = case HasAttach of
        false -> llmCli:userMessage(UserPrompt);
        true -> llmCli:userMessage(UserPrompt, Attachments)
    end,
    Base = [
        llmCli:systemMessage(System),
        llmCli:systemMessage(Summary),
        llmCli:systemMessage(ModeNote),
        llmCli:systemMessage(ContextNote)
    ] ++ Compaction,
    Base ++ Kept ++ [UserMsg].

%% @doc 将被裁剪掉的历史消息压缩为一条摘要 system 消息，
%% 让模型知悉此前发生过的工具调用与关键结论，避免信息完全丢失。
%% 当前为确定性结构化摘要（无额外 LLM 调用）。
-spec compactHistory([map()]) -> [map()].
compactHistory([]) ->
    [];
compactHistory(Dropped) ->
    ToolCount = length([1 || #{role := R} <- Dropped, R =:= tool]),
    Snippets = [snippet(C) || #{role := assistant, content := C} <- Dropped,
                              is_binary(C), C =/= <<>>],
    LastSnippets = lists:sublist(lists:reverse(Snippets), 3),
    SnippetText = case LastSnippets of
        [] -> <<>>;
        _ -> iolist_to_binary([<<" 较早的助手要点："/utf8>>,
                               lists:join(<<" | "/utf8>>, lists:reverse(LastSnippets))])
    end,
    Text = iolist_to_binary([
        <<"[历史摘要] 此前对话已省略 "/utf8>>, integer_to_binary(length(Dropped)),
        <<" 条消息（含 "/utf8>>, integer_to_binary(ToolCount),
        <<" 次工具结果）。"/utf8>>, SnippetText
    ]),
    [llmCli:systemMessage(Text)].

%% 截取助手内容片段（最多约 100 字符）作为摘要要点。
snippet(Content) ->
    case Content of
        <<Part:100/binary, _/binary>> -> <<Part/binary, "..."/utf8>>;
        _ -> Content
    end.

%% 会话持久化用：去掉 system，避免下次重复注入；并降级附件 parts。
%% @doc 从完整消息列表中提取可持久化的对话历史。
%% 过滤 role=system，并将 user 消息中的 image_url/file parts 替换为文本占位，
%% 避免大体积 base64 数据在后续每轮请求中重复发送。
%% @param Messages 完整消息列表
%% @returns `[map()]` 不含 system 角色、附件已降级的消息
-spec conversationHistory([map()]) -> [map()].
conversationHistory(Messages) ->
    [downgradeAttachments(M) || M = #{role := Role} <- Messages, Role =/= system].

%% 将 user 消息中的多模态附件 parts（image_url/file）降级为文本占位，
%% 保留 text parts 原样。非 user 消息或纯文本 content 不受影响。
downgradeAttachments(#{role := user, content := Parts} = Msg) when is_list(Parts) ->
    case llmCli:isContentParts(Parts) of
        true ->
            Downgraded = [downgradePart(P) || P <- Parts],
            Msg#{content := Downgraded};
        false ->
            Msg
    end;
downgradeAttachments(Msg) ->
    Msg.

downgradePart(#{<<"type"/utf8>> := <<"image_url"/utf8>>}) ->
    #{<<"type"/utf8>> => <<"text"/utf8>>, <<"text"/utf8>> => <<"[图片已省略]"/utf8>>};
downgradePart(#{<<"type"/utf8>> := <<"file"/utf8>>}) ->
    #{<<"type"/utf8>> => <<"text"/utf8>>, <<"text"/utf8>> => <<"[文档附件已省略]"/utf8>>};
downgradePart(Part) ->
    Part.

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
    sanitizeToolHistory(Trimmed).

%% @doc 清理对话历史中的孤立 tool 消息与不完整的 tool_calls 组。
-spec sanitizeToolHistory([map()]) -> [map()].
sanitizeToolHistory(Messages) ->
    sanitizeToolHistory(Messages, []).

sanitizeToolHistory([], Acc) ->
    lists:reverse(Acc);
sanitizeToolHistory([Msg | Rest], Acc) ->
    case msgRole(Msg) of
        assistant ->
            case msgToolCalls(Msg) of
                [_ | _] = Calls ->
                    N = length(Calls),
                    {Tools, Rest2} = takeToolMessages(Rest, N),
                    case toolBlockValid(Calls, Tools) of
                        true ->
                            Block = lists:reverse(Tools) ++ [Msg],
                            sanitizeToolHistory(Rest2, Block ++ Acc);
                        false ->
                            sanitizeToolHistory(Rest, Acc)
                    end;
                _ ->
                    sanitizeToolHistory(Rest, [Msg | Acc])
            end;
        tool ->
            sanitizeToolHistory(Rest, Acc);
        _ ->
            sanitizeToolHistory(Rest, [Msg | Acc])
    end.

takeToolMessages(Rest, 0) ->
    {[], Rest};
takeToolMessages([Msg | Rest], N) ->
    case msgRole(Msg) of
        tool ->
            {More, Rest2} = takeToolMessages(Rest, N - 1),
            {[Msg | More], Rest2};
        _ ->
            {[], [Msg | Rest]}
    end;
takeToolMessages(Rest, _N) ->
    {[], Rest}.

msgRole(#{role := Role}) when is_atom(Role) ->
    Role;
msgRole(#{<<"role"/utf8>> := RoleBin}) when is_binary(RoleBin) ->
    binary_to_existing_atom(RoleBin, utf8);
msgRole(_) ->
    unknown.

msgToolCalls(#{tool_calls := Calls}) when is_list(Calls) ->
    Calls;
msgToolCalls(#{<<"tool_calls"/utf8>> := Calls}) when is_list(Calls) ->
    Calls;
msgToolCalls(_) ->
    [].

toolBlockValid(Calls, Tools) ->
    Required = [callId(C) || C <- Calls],
    Got = [toolId(T) || T <- Tools],
    length(Required) =:= length(Got)
        andalso lists:all(fun(Id) -> lists:member(Id, Got) end, Required).

callId(#{<<"id"/utf8>> := Id}) ->
    toBinary(Id);
callId(#{id := Id}) ->
    toBinary(Id);
callId(_) ->
    <<>>.

toolId(#{tool_call_id := Id}) ->
    toBinary(Id);
toolId(#{<<"tool_call_id"/utf8>> := Id}) ->
    toBinary(Id);
toolId(_) ->
    <<>>.

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
    max(1, llmCli:estimateContentTokens(Content));
messageTokenCost(#{tool_calls := Calls}) when is_list(Calls) ->
    Bin = llmJson:encode(Calls),
    max(1, llmCli:estimateTokens(Bin));
messageTokenCost(_) ->
    1.

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
    case alCodeIndexer:getStats() of
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

%% 判断是否使用 LLM 原生 function calling（除非配置显式关闭）
useNativeTools(Config) ->
    case maps:get(useNativeTools, Config, true) of
        false -> false;
        _ -> true
    end.

%% 将任意值转为 binary
toBinary(X) when is_binary(X) -> X;
toBinary(X) when is_list(X) -> unicode:characters_to_binary(X);
toBinary(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).