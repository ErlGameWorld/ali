%%%-------------------------------------------------------------------
%% @doc ali 交互式 REPL（自 aili {@code chat/0} 移植）。
%%
%% 斜杠命令：{@code /quit}, {@code /clear}, {@code /config}, {@code /mode},
%% {@code /context}, {@code /index}, {@code /web}, {@code /save}, {@code /save-knowledge},
%% {@code /persona}, {@code /load}, {@code /session}, {@code /cancel}, {@code /status},
%% {@code /approve}, {@code /dismiss}, {@code /help}.
%% 待审批时回复「确认」/ yes / ok 等肯定语即可批准（无 Web 按钮场景）。
%% @end
%%%-------------------------------------------------------------------

-module(alChat).

-export([chat/0, chat/1]).
-export([normalizeOpts/1, trimLine/1, handleChatCommand/2, safeDisplayAnswer/1, formatChatError/1]).
-export([refreshIndex/0, refreshIndex/1]).
-ifdef(TEST).
-export([matchAgentConfigQuery/1, tryLocalAnswer/1, classifyApprovalReply/1]).
-endif.

%% 未配置 agent.agentTimeoutMs 时的兜底（毫秒）；与 alSessionWorker 默认一致
-define(DefaultChatTimeoutMs, 1800000).

%%--------------------------------------------------------------------
%% @doc
%% 启动交互式 REPL 对话（使用空选项）。
%%
%% @return ok | {error, Reason}
%% @end
%%--------------------------------------------------------------------
chat() ->
    chat(#{}).

%%--------------------------------------------------------------------
%% @doc
%% 启动交互式 REPL 对话：确保应用已启动、打印 banner、进入 chatLoop。
%%
%% @param Opts 初始选项（可含 sessionId 等）
%% @return ok | {error, Reason}
%% @end
%%--------------------------------------------------------------------
chat(Opts) ->
    case ensureStarted() of
        {ok, _} ->
            printChatBanner(Opts),
            chatLoop(normalizeOpts(Opts));
        {error, Reason} ->
            {error, Reason}
    end.

%%--------------------------------------------------------------------
%% @doc
%% REPL 主循环：读取一行输入，处理后根据命令结果决定停止、继续或提问。
%%
%% @end
%%--------------------------------------------------------------------
chatLoop(Opts) ->
    case io:get_line(chatPrompt(Opts)) of
        eof ->
            io:format("~n"),
            ok;
        {error, Reason} ->
            {error, Reason};
        Line ->
            Prompt = trimLine(Line),
            case handleChatCommand(Prompt, Opts) of
                stop ->
                    io:format("~n再见。~n"),
                    ok;
                {continue, NewOpts} ->
                    chatLoop(NewOpts);
                ask ->
                    NewOpts = chatTurn(Prompt, Opts),
                    chatLoop(NewOpts)
            end
    end.

%% 提示符：有待审批任务时提示可直接确认
chatPrompt(#{pendingApprove := Tid}) when Tid =/= undefined ->
    "ali [待确认] >>> ";
chatPrompt(_Opts) ->
    "ali >>> ".


%%--------------------------------------------------------------------
%% @doc
%% 处理用户输入的斜杠命令或普通提问。识别 /quit、/clear、/config、/mode、
%% /context、/index、/web、/save、/load、/session、/status、/help、/cancel 等；
%% 非命令输入先尝试本地回答，否则返回 ask 由 chatTurn 处理。
%%
%% @param Prompt 输入文本（binary 或其它）
%% @param Opts 当前选项
%% @return stop | {continue, NewOpts} | ask
%% @end
%%--------------------------------------------------------------------
handleChatCommand(<<>>, Opts) ->
    {continue, Opts};
handleChatCommand(<<"/quit"/utf8>>, _Opts) ->
    stop;
handleChatCommand(<<"/exit"/utf8>>, _Opts) ->
    stop;
handleChatCommand(<<"/config"/utf8>>, Opts) ->
    printAgentConfig(),
    {continue, Opts};
handleChatCommand(<<"/mode"/utf8>>, Opts) ->
    io:format("当前模式: ~p~n", [ali:getMode()]),
    {continue, Opts};
handleChatCommand(<<"/mode ", Rest/binary>>, Opts) ->
    Mode = safeExistingAtom(string:trim(Rest)),
    case ali:setMode(Mode) of
        ok -> io:format("已切换到模式 ~p~n", [Mode]);
        {error, R} -> io:format("切换失败: ~p~n", [R])
    end,
    {continue, Opts};
handleChatCommand(<<"/context"/utf8>>, Opts) ->
    io:format("~p~n", [ali:getWorkingContext()]),
    {continue, Opts};
handleChatCommand(<<"/context clear"/utf8>>, Opts) ->
    ali:clearContext(),
    io:format("工作上下文已清空~n"),
    {continue, Opts};
handleChatCommand(<<"/context add module ", Mod/binary>>, Opts) ->
    ModAtom = safeExistingAtom(string:trim(Mod)),
    ali:addContext(module, ModAtom),
    io:format("已将模块加入上下文: ~ts~n", [string:trim(Mod)]),
    {continue, Opts};
handleChatCommand(<<"/context add file ", Path/binary>>, Opts) ->
    PathBin = string:trim(Path),
    ali:addContext(file, PathBin),
    io:format("已将文件加入上下文: ~ts~n", [PathBin]),
    {continue, Opts};
handleChatCommand(<<"/index"/utf8>>, Opts) ->
    case refreshIndex(#{wait => true}) of
        {ok, Result} ->
            io:format("索引完成: ~ts~n", [formatIndexResult(Result)]);
        {error, R} ->
            io:format("索引失败: ~p~n", [R])
    end,
    {continue, Opts};
handleChatCommand(<<"/index status"/utf8>>, Opts) ->
    printIndexStatus(),
    {continue, Opts};
handleChatCommand(<<"/index restart"/utf8>>, Opts) ->
    io:format("正在重启 aliCore 并强制重建索引...~n"),
    case alCoreClient:restart() of
        ok ->
            Roots = alConfig:codeRoots(),
            io:format("已重启，触发全量重解析索引 roots=~p~n", [Roots]),
            _ = alCoreClient:indexAsyncRoots(Roots, #{force_reparse => true}),
            case refreshIndex(#{wait => true, skipStart => true}) of
                {ok, Result} ->
                    io:format("索引完成: ~ts~n", [formatIndexResult(Result)]);
                {error, E} ->
                    io:format("等待索引结束: ~p~n", [E])
            end;
        {error, R} ->
            io:format("重启失败: ~p~n", [R])
    end,
    {continue, Opts};
handleChatCommand(<<"/digest"/utf8>>, Opts) ->
    io:format("正在构建项目知识库（.ali/knowledge）...~n"),
    case alProjectDigest:rebuild(#{}) of
        {ok, Meta} ->
            io:format("知识库构建完成: ~p~n", [Meta]),
            io:format("路径: ~ts~n", [alProjectDigest:knowledgeDir()]);
        {error, R} ->
            io:format("知识库构建失败: ~p~n", [R])
    end,
    {continue, Opts};
handleChatCommand(<<"/digest rebuild"/utf8>>, Opts) ->
    handleChatCommand(<<"/digest"/utf8>>, Opts);
handleChatCommand(<<"/digest status"/utf8>>, Opts) ->
    io:format("~p~n", [alProjectDigest:status()]),
    {continue, Opts};
handleChatCommand(<<"/persona"/utf8>>, Opts) ->
    AgentCfg = maps:get(agentCfg, Opts, alConfig:getAgentCfg()),
    case alPersona:resolve(<<>>, Opts#{agentCfg => AgentCfg}) of
        {ok, builtin} ->
            io:format("当前身份: builtin（内置 Erlang 专家回退）~n");
        {ok, P} when is_map(P) ->
            io:format("当前身份: ~ts — ~ts~n",
                      [maps:get(name, P, <<>>), maps:get(desc, P, <<>>)])
    end,
    {continue, Opts};
handleChatCommand(<<"/persona list"/utf8>>, Opts) ->
    lists:foreach(fun({Name, Desc}) ->
        io:format("  ~ts  ~ts~n", [Name, Desc])
    end, alPersona:list()),
    {continue, Opts};
handleChatCommand(<<"/persona ", Rest/binary>>, Opts) ->
    Name = string:trim(Rest),
    case Name of
        <<"list">> ->
            handleChatCommand(<<"/persona list"/utf8>>, Opts);
        <<>> ->
            handleChatCommand(<<"/persona"/utf8>>, Opts);
        _ ->
            case alPersona:lookup(Name) of
                {ok, P} ->
                    AgentCfg0 = maps:get(agentCfg, Opts, alConfig:getAgentCfg()),
                    AgentCfg1 = AgentCfg0#{persona => maps:get(name, P)},
                    io:format("已切换身份: ~ts — ~ts~n",
                              [maps:get(name, P), maps:get(desc, P, <<>>)]),
                    {continue, Opts#{persona => maps:get(name, P), agentCfg => AgentCfg1}};
                {error, notFound} ->
                    io:format("未找到 persona: ~ts（/persona list 查看）~n", [Name]),
                    {continue, Opts}
            end
    end;
handleChatCommand(<<"/lessons"/utf8>>, Opts) ->
    Digest = alExperience:familiarityDigest(#{limit => 8}),
    io:format("~ts~n", [maps:get(summary, Digest, <<>>)]),
    lists:foreach(fun(L) ->
        io:format("  - ~ts~n", [maps:get(content, L, <<>>)])
    end, maps:get(recent, Digest, [])),
    {continue, Opts};
handleChatCommand(<<"/lesson"/utf8>>, Opts) ->
    io:format("用法:~n"
              "  /lesson <教训正文>     新增经验~n"
              "  /correct <纠正正文>    废止相关旧经验并写入新版~n"),
    {continue, Opts};
handleChatCommand(<<"/lesson ", Rest/binary>>, Opts) ->
    Trimmed = string:trim(Rest),
    case Trimmed of
        <<>> -> handleChatCommand(<<"/lesson"/utf8>>, Opts);
        _ ->
            case alExperience:recordLesson(#{
                content => Trimmed,
                source => manual,
                tags => [manual, chat]
            }) of
                {ok, Info} ->
                    io:format("已沉淀经验 id=~p~n", [maps:get(id, Info, undefined)]);
                {error, Reason} ->
                    io:format("沉淀失败: ~p~n", [Reason])
            end,
            {continue, Opts}
    end;
handleChatCommand(<<"/correct"/utf8>>, Opts) ->
    io:format("用法: /correct <正确结论>~n"
              "会自动匹配相关旧经验并标为已废止。~n"),
    {continue, Opts};
handleChatCommand(<<"/correct ", Rest/binary>>, Opts) ->
    Trimmed = string:trim(Rest),
    case Trimmed of
        <<>> -> handleChatCommand(<<"/correct"/utf8>>, Opts);
        _ ->
            SessionId = maps:get(sessionId, Opts, undefined),
            case alExperience:correctLesson(SessionId, #{
                content => Trimmed,
                source => correction,
                tags => [correction, chat, revised]
            }) of
                {ok, Info} ->
                    io:format("已纠正：新 id=~p 废止=~p~n",
                              [maps:get(id, Info, undefined),
                               maps:get(supersededIds, Info, [])]);
                {error, Reason} ->
                    io:format("纠正失败: ~p~n", [Reason])
            end,
            {continue, Opts}
    end;
handleChatCommand(<<"/save-knowledge"/utf8>>, Opts) ->
    io:format("用法: /save-knowledge <topic> <content>~n"
              "写入 .ali/knowledge/summaries/<topic>.md~n"),
    {continue, Opts};
handleChatCommand(<<"/save-knowledge ", Rest/binary>>, Opts) ->
    Trimmed = string:trim(Rest),
    case binary:split(Trimmed, <<" ">>, [global]) of
        [] ->
            handleChatCommand(<<"/save-knowledge"/utf8>>, Opts);
        [<<>>] ->
            handleChatCommand(<<"/save-knowledge"/utf8>>, Opts);
        [_Topic] ->
            io:format("缺少 content。用法: /save-knowledge <topic> <content>~n"),
            {continue, Opts};
        [Topic | ContentParts] ->
            Content = iolist_to_binary(lists:join(<<" ">>, ContentParts)),
            case alProjectDigest:saveKnowledge(#{
                topic => Topic,
                content => Content,
                source => <<"chat">>
            }) of
                {ok, Info} ->
                    io:format("已保存主题知识: topic=~ts path=~ts~n",
                              [maps:get(topic, Info, Topic),
                               maps:get(path, Info, <<>>)]);
                {error, Reason} ->
                    io:format("保存失败: ~p~n", [Reason])
            end,
            {continue, Opts}
    end;
handleChatCommand(<<"/save-action"/utf8>>, Opts) ->
    io:format("用法: /save-action <phrase> <Mod:Fun/Arity>~n"
              "写入/纠正 .ali/knowledge/actions.json（source=manual）~n"),
    {continue, Opts};
handleChatCommand(<<"/save-action ", Rest/binary>>, Opts) ->
    Trimmed = string:trim(Rest),
    case binary:split(Trimmed, <<" ">>, [global]) of
        [Phrase, Mfa | NoteParts] when Phrase =/= <<>>, Mfa =/= <<>> ->
            Note = case NoteParts of
                [] -> <<"chat">>;
                _ -> iolist_to_binary(lists:join(<<" ">>, NoteParts))
            end,
            case alProjectDigest:saveAction(#{
                phrase => Phrase,
                mfa => Mfa,
                note => Note
            }) of
                {ok, Info} ->
                    io:format("已保存动作: phrase=~ts mfa=~ts count=~p~n",
                              [maps:get(phrase, Info, Phrase),
                               maps:get(mfa, Info, Mfa),
                               maps:get(actionCount, Info, 0)]);
                {error, Reason} ->
                    io:format("保存失败: ~p~n", [Reason])
            end,
            {continue, Opts};
        _ ->
            handleChatCommand(<<"/save-action"/utf8>>, Opts)
    end;
handleChatCommand(<<"/web"/utf8>>, Opts) ->
    printWebStatus(),
    {continue, Opts};
handleChatCommand(<<"/web stop"/utf8>>, Opts) ->
    io:format("Web/Gateway 由 aliCfg.cfg 的 web.enabled / gateway.enabled 控制，修改后重启应用生效。~n"),
    {continue, Opts};
handleChatCommand(<<"/help"/utf8>>, Opts) ->
    io:format(
        "命令:~n"
        "  /quit /exit     退出~n"
        "  /clear          清空当前会话历史~n"
        "  /cancel         取消进行中的问答~n"
        "  /config         查看 Agent 配置~n"
        "  /mode [ask|edit|exec]  查看或切换运行模式~n"
        "  /context          查看工作上下文~n"
        "  /context clear    清空工作上下文~n"
        "  /context add module <Mod>  将模块加入上下文~n"
        "  /context add file <Path>   将文件加入上下文~n"
        "  /index          刷新代码索引并等待完成（全部 codeRoots）~n"
        "  /index status   查看索引状态（files/indexing/last_index_root）~n"
        "  /index restart  重启 aliCore 后重建索引（解僵死 indexing）~n"
        "  /digest         构建/刷新项目知识库（并预学习经验）~n"
        "  /digest rebuild 同上（强制重建）~n"
        "  /digest status  查看知识库状态~n"
        "  /persona [name] 查看/切换专家身份（list 列出）~n"
        "  /lessons        查看本仓已沉淀经验~n"
        "  /lesson <text>  手动沉淀一条教训~n"
        "  /correct <text> 纠正旧经验（废旧立新）~n"
        "  /save-knowledge <topic> <content>  沉淀主题知识到 summaries~n"
        "  /save-action <phrase> <MFA>  纠正 NL→MFA 动作词典~n"
        "  /web            查看 Web / Gateway 地址~n"
        "  /save [id]      保存当前会话~n"
        "  /load <id>      加载历史会话~n"
        "  /session <id>   切换到指定会话~n"
        "  /status         查看运行状态~n"
        "  /approve [id]   批准待确认任务（无 id 则批最近一次）~n"
        "  /dismiss [id]   驳回待确认任务~n~n"
        "待审批时也可直接回复：确认 / 好的 / yes / ok~n"
        "驳回可回复：取消 / 拒绝 / no~n~n"
        "提问时可锚定上下文（优先于搜索猜测）:~n"
        "  @module name     例如 @module alAgent~n"
        "  @path rel/file   例如 @path src/agent/alAgent.erl~n"
        "  @mfa Mod:Fun/A   例如 @mfa alAgent:run/2~n~n"
    ),
    {continue, Opts};
handleChatCommand(<<"/clear"/utf8>>, Opts) ->
    clearChatSession(Opts),
    io:format("会话历史已清空~n"),
    {continue, Opts};
handleChatCommand(<<"/cancel"/utf8>>, Opts) ->
    cancelChatTurnAsk(Opts),
    io:format("已取消进行中的问答~n"),
    {continue, Opts};
handleChatCommand(<<"/status"/utf8>>, Opts) ->
    io:format("~p~n", [ali:serverStatus()]),
    {continue, Opts};
handleChatCommand(<<"/approve"/utf8>>, Opts) ->
    case maps:get(pendingApprove, Opts, undefined) of
        undefined ->
            io:format("当前没有待确认任务。有审批时回复「确认」或 /approve~n"),
            {continue, Opts};
        Tid ->
            {continue, runChatApprove(Tid, Opts)}
    end;
handleChatCommand(<<"/approve ", Rest/binary>>, Opts) ->
    Tid = string:trim(Rest),
    case Tid of
        <<>> -> handleChatCommand(<<"/approve"/utf8>>, Opts);
        _ -> {continue, runChatApprove(Tid, Opts)}
    end;
handleChatCommand(<<"/dismiss"/utf8>>, Opts) ->
    case maps:get(pendingApprove, Opts, undefined) of
        undefined ->
            io:format("当前没有待确认任务~n"),
            {continue, Opts};
        Tid ->
            {continue, runChatDismiss(Tid, Opts)}
    end;
handleChatCommand(<<"/dismiss ", Rest/binary>>, Opts) ->
    Tid = string:trim(Rest),
    case Tid of
        <<>> -> handleChatCommand(<<"/dismiss"/utf8>>, Opts);
        _ -> {continue, runChatDismiss(Tid, Opts)}
    end;
handleChatCommand(<<"/save"/utf8>>, Opts) ->
    printSaveResult(ali:saveSession()),
    {continue, Opts};
handleChatCommand(<<"/save ", Rest/binary>>, Opts) ->
    Id = string:trim(Rest),
    printSaveResult(ali:saveSession(Id)),
    {continue, Opts};
handleChatCommand(<<"/load ", Rest/binary>>, Opts) ->
    Id = string:trim(Rest),
    case ali:loadSession(Id) of
        {ok, Loaded} ->
            io:format("已加载会话 ~ts~n", [formatSessionId(Loaded, Id)]),
            {continue, Opts#{sessionId => toBinary(Loaded)}};
        ok ->
            io:format("已加载会话 ~ts~n", [Id]),
            {continue, Opts#{sessionId => toBinary(Id)}};
        {error, Reason} ->
            io:format("加载失败: ~p~n", [Reason]),
            {continue, Opts}
    end;
handleChatCommand(<<"/session ", Rest/binary>>, Opts) ->
    Id = string:trim(Rest),
    io:format("已切换到会话 ~ts~n", [Id]),
    {continue, Opts#{sessionId => toBinary(Id)}};
handleChatCommand(<<"/load"/utf8>>, Opts) ->
    io:format("用法: /load <sessionId>~n"),
    {continue, Opts};
handleChatCommand(<<"/session"/utf8>>, Opts) ->
    io:format("用法: /session <sessionId>~n"),
    {continue, Opts};
%% 非命令输入：待审批时肯定语→批准、否定语→驳回；否则尝试本地回答，否则交给 chatTurn。
handleChatCommand(Prompt, Opts) when is_binary(Prompt) ->
    case maybeHandleApprovalReply(Prompt, Opts) of
        {handled, NewOpts} ->
            {continue, NewOpts};
        false ->
            case tryLocalAnswer(Prompt) of
                true -> {continue, Opts};
                false -> ask
            end
    end;
%% 非 binary 输入归一化为 binary 后再处理。
handleChatCommand(Prompt, Opts) ->
    handleChatCommand(promptBinary(Prompt), Opts).

%%--------------------------------------------------------------------
%% @doc
%% 执行一次提问：在新进程中调用 alServer:ask，主进程同时打印进度点，
%% 收到结果或超时后输出回答/错误。Prompt 非 binary 时先归一化。
%%
%% @end
%%--------------------------------------------------------------------
chatTurn(Prompt, Opts) when is_binary(Prompt) ->
    maybeRecordUserCorrection(Prompt, Opts),
    Parent = self(),
    Ref = make_ref(),
    ProgressId = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    alProgress:start(ProgressId),
    AskOpts = chatAskOpts(Opts, ProgressId),
    printUserTurn(Prompt),
    {Pid, MonRef} = spawn_monitor(fun() ->
        Result =
            case ensureStarted() of
                {ok, _} ->
                    try alServer:ask(Prompt, AskOpts) of
                        {ok, Answer} -> {ok, Answer};
                        {error, Reason} -> {error, Reason}
                    catch
                        Class:Reason:Stack ->
                            {error, {Class, Reason, Stack}}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end,
        Parent ! {eChatTurnDone, Ref, Result}
    end),
    printSection(<<"思考中"/utf8>>),
    StartMs = erlang:monotonic_time(millisecond),
    TimeoutMs = chatTimeoutMs(AskOpts),
    case waitChatTurn(Ref, StartMs, TimeoutMs, ProgressId, 0, AskOpts) of
        {ok, Answer} ->
            _ = erlang:demonitor(MonRef, [flush]),
            io:format("~n"),
            printAgentTurn(safeDisplayAnswer(Answer)),
            rememberPending(Opts, Answer);
        {error, Reason} ->
            _ = erlang:demonitor(MonRef, [flush]),
            io:format("~n"),
            printSection(<<"错误"/utf8>>),
            io:format("  ~ts~n", [formatChatError(Reason)]),
            printRule(),
            clearPending(Opts);
        timeout ->
            exit(Pid, kill),
            _ = erlang:demonitor(MonRef, [flush]),
            io:format("~n"),
            Mins = max(1, TimeoutMs div 60000),
            printSection(<<"超时"/utf8>>),
            io:format("  思考超过 ~p 分钟，已中止~n", [Mins]),
            printRule(),
            clearPending(Opts)
    end;
chatTurn(Prompt, Opts) ->
    chatTurn(promptBinary(Prompt), Opts).

%% 用户纠正话术 → 高优先级 lesson（不打断问答）。
maybeRecordUserCorrection(Prompt, Opts) when is_binary(Prompt) ->
    case alExperience:detectCorrection(Prompt) of
        true ->
            SessionId = maps:get(sessionId, Opts, undefined),
            _ = alExperience:recordCorrection(SessionId, #{
                content => Prompt,
                symptom => <<"用户纠正"/utf8>>,
                prevention => <<"以本条用户纠正为准"/utf8>>,
                tags => [correction, chat]
            }),
            ok;
        false ->
            ok
    end;
maybeRecordUserCorrection(_, _) ->
    ok.

printUserTurn(Prompt) ->
    printSection(<<"你"/utf8>>),
    lists:foreach(fun(Line) ->
        io:format("  ~ts~n", [Line])
    end, binary:split(Prompt, <<"\n">>, [global])),
    ok.

printAgentTurn(Text) when is_binary(Text) ->
    printSection(<<"Agent"/utf8>>),
    %% 回答正文相对 section 缩进一级，多行保持可读
    lists:foreach(fun(Line) ->
        case Line of
            <<>> -> io:format("~n");
            _ -> io:format("  ~ts~n", [Line])
        end
    end, binary:split(Text, <<"\n">>, [global])),
    printRule();
printAgentTurn(Text) ->
    printAgentTurn(toBinary(Text)).

printSection(Title) when is_binary(Title) ->
    io:format("~n── ~ts ──~n", [Title]);
printSection(Title) ->
    printSection(toBinary(Title)).

printRule() ->
    io:format("──────────────────────────────~n").

%%--------------------------------------------------------------------
%% @doc
%% 构造提问用选项：合并归一化选项与 progressId。
%%
%% @end
%%--------------------------------------------------------------------
chatAskOpts(Opts, ProgressId) ->
    Norm = normalizeOpts(Opts),
    maps:merge(Norm, #{progressId => ProgressId}).

%% 交互 chat 等待上限：Opts.agentTimeoutMs > agent.agentTimeoutMs > 默认 30 分钟。
%% 与 alSessionWorker 共用同一配置项，避免 UI 先砍、worker 还在跑。
chatTimeoutMs(Opts) when is_map(Opts) ->
    AgentCfg = maps:get(agentCfg, Opts, alConfig:getAgentCfg()),
    firstPositiveMs([
        maps:get(agentTimeoutMs, Opts, undefined),
        maps:get(agentTimeoutMs, AgentCfg, undefined),
        ?DefaultChatTimeoutMs
    ]);
chatTimeoutMs(_) ->
    ?DefaultChatTimeoutMs.

firstPositiveMs([V | _Rest]) when is_integer(V), V > 0 -> V;
firstPositiveMs([_ | Rest]) -> firstPositiveMs(Rest);
firstPositiveMs([]) -> ?DefaultChatTimeoutMs.

%%--------------------------------------------------------------------
%% @doc
%% 等待提问结果：每 300ms 打印进度点与新增 progress 事件；
%% 用单调时钟累计真实耗时，达到 TimeoutMs（来自 agent.agentTimeoutMs）则取消。
%%
%% @end
%%--------------------------------------------------------------------
waitChatTurn(Ref, StartMs, TimeoutMs, ProgressId, LastCount, AskOpts) ->
    ElapsedMs = erlang:monotonic_time(millisecond) - StartMs,
    case ElapsedMs >= TimeoutMs of
        true ->
            alProgress:drop(ProgressId),
            cancelChatTurnAsk(AskOpts),
            timeout;
        false ->
            NewCount = printChatProgress(ProgressId, LastCount),
            receive
                {eChatTurnDone, Ref, {ok, Answer}} ->
                    alProgress:drop(ProgressId),
                    {ok, Answer};
                {eChatTurnDone, Ref, {error, Reason}} ->
                    alProgress:drop(ProgressId),
                    {error, Reason}
            after 300 ->
                %% 本轮已打出进度行时不再刷心跳点，避免满屏无意义的「.」
                case NewCount > LastCount of
                    true -> ok;
                    false -> io:format(".", [])
                end,
                waitChatTurn(Ref, StartMs, TimeoutMs, ProgressId, NewCount, AskOpts)
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 取消当前提问：根据 Opts 中是否含 sessionId 调用对应 cancelAsk；
%% 任何异常均吞掉返回 ok。
%%
%% @end
%%--------------------------------------------------------------------
cancelChatTurnAsk(#{sessionId := Sid}) ->
    try ali:cancelAsk(Sid) catch _:_ -> ok end,
    ok;
cancelChatTurnAsk(Opts) when is_map(Opts) ->
    try ali:cancelAsk() catch _:_ -> ok end,
    ok;
cancelChatTurnAsk(_) ->
    ok.

%%--------------------------------------------------------------------
%% @doc
%% 清空当前会话历史：若 Opts 含 sessionId 则清空指定会话，否则清空默认会话。
%%
%% @end
%%--------------------------------------------------------------------
clearChatSession(Opts) ->
    case maps:get(sessionId, normalizeOpts(Opts), undefined) of
        undefined -> ali:clearSession();
        Sid -> ali:clearSession(Sid)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 刷新项目代码索引。默认等待后台索引真正结束（files 可见或超时）。
%% Opts：
%%   wait       — true 时轮询 /index/status（默认 true）
%%   skipStart  — true 时不重新 POST /index（仅等待已触发的任务）
%%   timeoutMs  — 等待上限，默认用 core.indexTimeout
%% @end
%%--------------------------------------------------------------------
refreshIndex() ->
    refreshIndex(#{}).

refreshIndex(Opts) when is_map(Opts) ->
    Roots = alConfig:codeRoots(),
    io:format("codeRoots (~p):~n", [length(Roots)]),
    lists:foreach(fun(R) -> io:format("  - ~ts~n", [toIo(R)]) end, Roots),
    case Roots of
        [] ->
            {error, #{reason => noCodeRoots,
                      hint => <<"请在 aliCfg.cfg 设置 agent.projectRoot 或 codeRoots"/utf8>>}};
        _ ->
            _ = maybeUnstickIndex(),
            StartRes = case maps:get(skipStart, Opts, false) of
                true ->
                    [{R, skipped} || R <- Roots];
                false ->
                    lists:map(fun(Root) ->
                        io:format("触发索引: ~ts ... ", [toIo(Root)]),
                        case alCoreClient:index(Root) of
                            {ok, Body} ->
                                Data = alCoreClient:unwrapMap(
                                    case Body of
                                        #{data := D} -> D;
                                        M when is_map(M) -> M;
                                        _ -> #{}
                                    end),
                                Warn = maps:get(warnings, Data, maps:get(<<"warnings">>, Data, [])),
                                io:format("ok (~p)~n", [Warn]),
                                {Root, {ok, Data}};
                            {error, Reason} = Err ->
                                io:format("error ~p~n", [Reason]),
                                {Root, Err}
                        end
                    end, Roots)
            end,
            Failed = [R || {R, {error, _}} <- StartRes],
            case Failed of
                [_|_] ->
                    {error, #{failed => Failed, results => StartRes}};
                [] ->
                    case maps:get(wait, Opts, true) of
                        false ->
                            {ok, #{roots => Roots, results => StartRes, waited => false}};
                        true ->
                            Timeout = maps:get(timeoutMs, Opts,
                                maps:get(indexTimeout, alConfig:get(core, #{}), 600000)),
                            case waitIndexProgress(Timeout) of
                                {ok, Status} ->
                                    _ = alProjectDigest:maybeBuildAfterIndex(),
                                    _ = spawn(fun() ->
                                        try
                                            Recent = try alVcsIndex:recentFiles()
                                                     catch _:_ -> [] end,
                                            Paths = case is_list(Recent) of
                                                true -> Recent;
                                                false ->
                                                    try ordsets:to_list(Recent)
                                                    catch _:_ -> [] end
                                            end,
                                            alExperience:reconcileAfterCodeChange(#{
                                                changed => Paths,
                                                deleted => []
                                            })
                                        catch _:_ -> ok
                                        end
                                    end),
                                    {ok, #{roots => Roots, results => StartRes,
                                           waited => true, status => Status}};
                                {error, Reason} ->
                                    {error, #{reason => Reason, results => StartRes,
                                              status => indexStatusMap()}}
                            end
                    end
            end
    end.

maybeUnstickIndex() ->
    St = indexStatusMap(),
    Indexing = maps:get(indexing, St, false),
    Files = maps:get(files, St, 0),
    Walk = maps:get(walk_seen, St, 0),
    LastRoot = maps:get(last_index_root, St, <<>>),
    Stuck = Indexing =:= true
        andalso (Files =:= 0 orelse Files =:= <<"0">>)
        andalso (Walk =:= 0 orelse Walk =:= <<"0">>)
        andalso (LastRoot =:= <<>> orelse LastRoot =:= ""),
    case Stuck of
        true ->
            io:format("检测到僵死 indexing（files=0, walk_seen=0, last_index_root 空），"
                      "重启 aliCore...~n"),
            case alCoreClient:restart() of
                ok -> io:format("aliCore 已重启~n"), ok;
                {error, R} -> io:format("重启失败: ~p（继续尝试索引）~n", [R]), ok
            end;
        false ->
            ok
    end.

waitIndexProgress(TimeoutMs) when is_integer(TimeoutMs), TimeoutMs > 0 ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    waitIndexProgressLoop(Deadline, undefined, 0);
waitIndexProgress(_) ->
    waitIndexProgress(600000).

waitIndexProgressLoop(Deadline, LastWalk, StableRounds) ->
    Now = erlang:monotonic_time(millisecond),
    case Now >= Deadline of
        true ->
            {error, #{reason => indexWaitTimeout, status => indexStatusMap()}};
        false ->
            St = indexStatusMap(),
            Indexing = maps:get(indexing, St, false),
            Files = toInt(maps:get(files, St, 0), 0),
            Walk = toInt(maps:get(walk_seen, St, 0), 0),
            Root = maps:get(last_index_root, St, <<>>),
            io:format("  … indexing=~p files=~p walk_seen=~p root=~ts~n",
                      [Indexing, Files, Walk, toIo(Root)]),
            case Indexing of
                false when Files > 0 ->
                    {ok, St};
                false when Files =:= 0 ->
                    %% 已结束但仍 0：可能根路径无 .erl，或扫盘失败
                    {error, #{reason => indexEmptyAfterFinish, status => St,
                              hint => <<"检查 projectRoot/codeRoots 是否指向含 .erl 的目录；"
                                        "以及 core.indexIgnore 是否过宽"/utf8>>}};
                true ->
                    NewStable = case Walk =:= LastWalk of
                        true -> StableRounds + 1;
                        false -> 0
                    end,
                    %% 仅当完全没扫到任何文件（walk=0,files=0）且长时间不动才重启。
                    %% 解析阶段 walk_seen 会停住、files 爬升——不能把「walk 不动」当成卡死。
                    case NewStable >= 30 andalso Walk =:= 0 andalso Files =:= 0 of
                        true ->
                            io:format("walk_seen 长时间为 0，重启 aliCore 后重试等待...~n"),
                            _ = alCoreClient:restart(),
                            _ = alCoreClient:indexAsyncRoots(alConfig:codeRoots()),
                            timer:sleep(2000),
                            waitIndexProgressLoop(Deadline, undefined, 0);
                        false ->
                            timer:sleep(2000),
                            waitIndexProgressLoop(Deadline, Walk, NewStable)
                    end;
                _ ->
                    timer:sleep(2000),
                    waitIndexProgressLoop(Deadline, Walk, StableRounds)
            end
    end.

indexStatusMap() ->
    try
        case alCoreClient:unwrap(alCoreClient:indexStatus()) of
            {ok, M} when is_map(M) -> M;
            _ -> #{}
        end
    catch _:_ ->
        #{}
    end.

printIndexStatus() ->
    St = indexStatusMap(),
    Indexing = maps:get(indexing, St, false),
    Ready = maps:get(ready, St, maps:get(<<"ready">>, St, false)),
    Files = maps:get(files, St, 0),
    Walk = maps:get(walk_seen, St, 0),
    Phase = maps:get(phase, St, maps:get(<<"phase">>, St, <<>>)),
    Pending = maps:get(pending_total, St, maps:get(<<"pending_total">>, St, 0)),
    Parsed = maps:get(parsed_done, St, maps:get(<<"parsed_done">>, St, 0)),
    LastFile = maps:get(last_file, St, maps:get(<<"last_file">>, St, <<>>)),
    Slow = maps:get(slow_files, St, maps:get(<<"slow_files">>, St, [])),
    Busy = maps:get(busy_files, St, maps:get(<<"busy_files">>, St, [])),
    TimedOut = maps:get(timed_out_files, St, maps:get(<<"timed_out_files">>, St, [])),
    LastErr = maps:get(last_error, St, maps:get(<<"last_error">>, St, <<>>)),
    io:format("index status:~n  ~p~n", [St]),
    io:format("projectRoot=~ts~ncodeRoots=~p~ndataDir=~ts~n",
              [toIo(alConfig:projectRoot()), alConfig:codeRoots(),
               toIo(alConfig:dataDir())]),
    printSlowBusyFiles(Busy, Slow, TimedOut),
    case {Indexing, toInt(Walk, 0), toInt(Files, 0), Phase, Ready} of
        {false, _, _, <<"failed">>, _} ->
            io:format("说明: 索引失败 phase=failed。last_error=~ts~n"
                      "可试 /index restart；若刚屏蔽了大目录，确认已重启 aliCore 使 ignore 生效。~n",
                      [toIo(LastErr)]);
        {false, _, F, <<"build">>, false} when F > 0 ->
            io:format("说明: 解析已完成但收尾失败（phase=build 且 indexing=false, ready=false）。~n"
                      "常见原因: Tantivy/调用图构建 OOM 或写 state.json 失败。~n"
                      "last_error=~ts~n请看 shell 里 [aliCore] INDEX_FAILED，然后 /index restart。~n",
                      [toIo(LastErr)]);
        {true, W, _, <<"build">>, _} when W > 0 ->
            io:format("说明: 解析已完成，正在写 Tantivy/state（phase=build）。"
                      "files=~p，可能还需一两分钟。~n", [toInt(Files, 0)]);
        {true, W, _, <<"parse_done">>, _} when W > 0 ->
            io:format("说明: 解析刚结束，即将进入 build。files=~p~n", [toInt(Files, 0)]);
        {true, W, _, <<"parse">>, _} when W > 0 ->
            io:format("说明: 解析中 phase=parse parsed=~p/~p files=~p walk_seen=~p。"
                      "symbols 要等全部结束后才写入；last_file=~ts~n",
                      [toInt(Parsed, 0), toInt(Pending, 0), toInt(Files, 0), W,
                       toIo(LastFile)]);
        {true, W, _, _, _} when W > 0 ->
            io:format("说明: 正在扫盘/解析（walk_seen=~p phase=~ts）。"
                      "files 会随进度上升；全部结束后 ready=true。~n",
                      [W, toIo(Phase)]);
        {true, 0, 0, _, _} ->
            io:format("说明: indexing=true 但 walk_seen=0，可能刚启动或卡住；"
                      "可试 /index restart~n");
        {false, _, 0, _, _} ->
            io:format("说明: 索引已结束但 files=0。检查 codeRoots 是否含 .erl，"
                      "或看 core 日志是否有解析错误。~n");
        {false, _, F, _, true} when F > 0 ->
            io:format("说明: 索引就绪 ready=true files=~p。~n", [F]);
        _ ->
            ok
    end.

%% 打印卡住/过慢/超时跳过文件，方便决定是否加入 indexIgnore。
printSlowBusyFiles(Busy, Slow, TimedOut) ->
    case TimedOut of
        [_|_] ->
            io:format("超时已跳过（core.indexFileTimeoutSecs）:~n"),
            lists:foreach(fun(Item) -> printSlowItem(Item) end, lists:sublist(TimedOut, 20)),
            io:format("建议: 把路径片段写入 core.indexIgnore~n");
        _ -> ok
    end,
    case Busy of
        [_|_] ->
            io:format("正在啃（已 ≥10s，可能卡住）:~n"),
            lists:foreach(fun(Item) -> printSlowItem(Item) end, lists:sublist(Busy, 10));
        _ -> ok
    end,
    case Slow of
        [_|_] ->
            io:format("过慢文件（解析 ≥10s，可考虑屏蔽）:~n"),
            lists:foreach(fun(Item) -> printSlowItem(Item) end, lists:sublist(Slow, 20)),
            io:format("屏蔽示例: 在 aliCfg.cfg 的 core.indexIgnore 追加路径片段，"
                      "如 pb,*_pb.erl,某模块名~n");
        _ -> ok
    end.

printSlowItem(Item) when is_map(Item) ->
    File = maps:get(file, Item, maps:get(<<"file">>, Item, <<>>)),
    Size = maps:get(size_bytes, Item, maps:get(<<"size_bytes">>, Item, 0)),
    Secs = maps:get(secs, Item, maps:get(<<"secs">>, Item, 0)),
    io:format("  - ~ts  (~p bytes, ~p s)~n", [toIo(File), Size, Secs]);
printSlowItem(Other) ->
    io:format("  - ~p~n", [Other]).

formatIndexResult(#{status := St}) when is_map(St) ->
    Files = maps:get(files, St, maps:get(<<"files">>, St, 0)),
    Sym = maps:get(symbols, St, maps:get(<<"symbols">>, St, 0)),
    Root = maps:get(last_index_root, St, maps:get(<<"last_index_root">>, St, <<>>)),
    iolist_to_binary(io_lib:format("files=~p symbols=~p root=~ts",
                                   [Files, Sym, toIo(Root)]));
formatIndexResult(Other) ->
    iolist_to_binary(io_lib:format("~p", [Other])).

toIo(B) when is_binary(B) -> B;
toIo(L) when is_list(L) -> unicode:characters_to_binary(L);
toIo(A) when is_atom(A) -> atom_to_binary(A, utf8);
toIo(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).

toInt(I, _) when is_integer(I) -> I;
toInt(B, Def) when is_binary(B) ->
    try binary_to_integer(B) catch _:_ -> Def end;
toInt(_, Def) -> Def.

%%--------------------------------------------------------------------
%% @doc
%% 打印 Web/Gateway 监听状态：启用时输出访问地址，未启用时输出原因与排查提示。
%%
%% @end
%%--------------------------------------------------------------------
printWebStatus() ->
    St = alHttpGateway:status(),
    Port = maps:get(port, St, alHttpGateway:port()),
    case maps:get(enabled, St, false) of
        true ->
            io:format("Web UI + Gateway: http://127.0.0.1:~p/~n", [Port]),
            io:format("  (Web UI / 与 /api/*、/tool 共用同一端口)~n");
        false ->
            Reason = maps:get(error, St, maps:get(mode, St, disabled)),
            io:format("HTTP 未监听 (port=~p, reason=~p)~n", [Port, Reason]),
            io:format("  检查 aliCfg.cfg 中 web.enabled / gateway.enabled~n")
    end.

%%--------------------------------------------------------------------
%% @doc
%% 打印当前 Agent 配置。
%%
%% @end
%%--------------------------------------------------------------------
printAgentConfig() ->
    io:format("~n--- Agent config ---~n~p~n---~n", [alConfig:getAgentCfg()]).

%%--------------------------------------------------------------------
%% @doc
%% 打印保存会话的结果：支持 {ok, Path} / ok / {ok, ok} / {error, _} 等多种返回。
%%
%% @end
%%--------------------------------------------------------------------
printSaveResult({ok, Path}) when is_list(Path); is_binary(Path) ->
    io:format("会话已保存: ~ts~n", [toList(Path)]);
printSaveResult(ok) ->
    io:format("会话已保存~n");
printSaveResult({ok, ok}) ->
    io:format("会话已保存~n");
printSaveResult({error, Reason}) ->
    io:format("保存失败: ~p~n", [Reason]);
printSaveResult(Other) ->
    io:format("保存结果: ~p~n", [Other]).

%%--------------------------------------------------------------------
%% @doc
%% 打印 REPL 启动 banner：会话 ID、使用提示与命令列表。
%%
%% @end
%%--------------------------------------------------------------------
printChatBanner(Opts) ->
    Norm = normalizeOpts(Opts),
    SessionId = maps:get(sessionId, Norm, <<"server-default"/utf8>>),
    Mode = try ali:getMode() catch _:_ -> ask end,
    io:format("~n"),
    io:format("╔══════════════════════════════════════╗~n"),
    io:format("║          ali 交互式对话              ║~n"),
    io:format("╚══════════════════════════════════════╝~n"),
    io:format("  会话  ~ts~n", [SessionId]),
    io:format("  模式  ~p~n", [Mode]),
    io:format("  输入问题回车发送；/ 开头为命令（/help）~n"),
    io:format("  待审批时可直接回复「确认」/ yes / ok~n"),
    io:format("  /quit /clear /cancel /config /mode /context~n"),
    io:format("  /index /digest /persona /save-knowledge /web /save /load /session /approve~n"),
    printRule().

%%--------------------------------------------------------------------
%% @doc
%% 打印自上次以来的新增 progress 事件，并返回最新的事件总数。
%%
%% @param ProgressId 进度 ID
%% @param LastCount 上次已处理的事件数
%% @return 当前事件总数
%% @end
%%--------------------------------------------------------------------
printChatProgress(ProgressId, LastCount) ->
  #{events := Events, eventCount := Total} = alProgress:snapshot(ProgressId, LastCount),
  lists:foreach(fun(E) ->
      case formatProgressEvent(E) of
          <<>> -> ok;
          Line -> io:format("~n  ~ts", [Line])
      end
  end, Events),
  Total.

%%--------------------------------------------------------------------
%% @doc
%% 将单个 progress 事件格式化为可读 binary。
%% 支持 started / step / tool|toolStarted / toolDone|toolFinished /
%% thought / completed / approvalRequired / error 等。
%%
%% @end
%%--------------------------------------------------------------------
formatProgressEvent(#{type := started, phase := llm} = E) ->
    maps:get(message, E, <<"LLM...">>);
formatProgressEvent(#{type := started} = E) ->
    maps:get(message, E, <<"开始任务"/utf8>>);
formatProgressEvent(#{type := step, phase := grounding} = E) ->
    Msg = maps:get(message, E, <<"grounding">>),
    iolist_to_binary([<<"↻ "/utf8>>, Msg]);
formatProgressEvent(#{type := step} = E) ->
    maps:get(message, E, maps:get(phase, E, <<"步骤"/utf8>>));
formatProgressEvent(#{type := thought} = E) ->
    case maps:get(message, E, <<>>) of
        <<>> -> <<>>;
        Msg when is_binary(Msg) ->
            %% 完整思考过程：保留全文，便于审查推理链路（不再 80 字截断）。
            <<"💭 "/utf8, Msg/binary>>;
        Msg ->
            case unicode:characters_to_binary(Msg) of
                Bin when is_binary(Bin), Bin =/= <<>> ->
                    <<"💭 "/utf8, Bin/binary>>;
                _ ->
                    <<>>
            end
    end;
formatProgressEvent(#{type := Type} = E)
  when Type =:= tool; Type =:= toolStarted ->
    Tool = maps:get(tool, E, unknown),
    iolist_to_binary([<<"· 调用 "/utf8>>, toolLabel(Tool), formatArgsSuffix(maps:get(args, E, undefined))]);
formatProgressEvent(#{type := Type, tool := Tool, ok := true} = E)
  when Type =:= toolDone; Type =:= toolFinished ->
    Ms = case maps:get(elapsedMs, E, undefined) of
        N when is_integer(N) -> iolist_to_binary(io_lib:format(" ~pms", [N]));
        _ -> <<>>
    end,
    iolist_to_binary([<<"✓ "/utf8>>, toolLabel(Tool), <<" 完成"/utf8>>, Ms,
                      formatArgsSuffix(maps:get(args, E, undefined))]);
formatProgressEvent(#{type := toolDone, tool := Tool, status := confirmationRequired} = E) ->
    iolist_to_binary([<<"✓ "/utf8>>, toolLabel(Tool), <<" 待确认"/utf8>>, formatArgsSuffix(maps:get(args, E, undefined))]);
formatProgressEvent(#{type := approvalRequired, tool := Tool, taskId := TaskId} = E) ->
    iolist_to_binary([
        <<"⏸ "/utf8>>, toolLabel(Tool), <<" 待确认 TaskId="/utf8>>, toBinary(TaskId),
        <<" → 回复「确认」或 /approve"/utf8>>,
        formatArgsSuffix(maps:get(args, E, undefined))
    ]);
formatProgressEvent(#{type := Type, tool := Tool, error := Reason} = E)
  when Type =:= toolDone; Type =:= toolFinished ->
    iolist_to_binary([<<"✗ "/utf8>>, toolLabel(Tool), <<" 失败: "/utf8>>, formatTerm(Reason),
        formatArgsSuffix(maps:get(args, E, undefined))]);
formatProgressEvent(#{type := Type, tool := Tool, ok := false} = E)
  when Type =:= toolFinished ->
    Reason = maps:get(error, E, failed),
    iolist_to_binary([<<"✗ "/utf8>>, toolLabel(Tool), <<" 失败: "/utf8>>, formatTerm(Reason),
        formatArgsSuffix(maps:get(args, E, undefined))]);
formatProgressEvent(#{type := Type, tool := Tool} = E)
  when Type =:= toolDone; Type =:= toolFinished ->
    iolist_to_binary([<<"✓ "/utf8>>, toolLabel(Tool), <<" 完成"/utf8>>, formatArgsSuffix(maps:get(args, E, undefined))]);
formatProgressEvent(#{type := completed}) ->
    <<"✓ 本轮完成"/utf8>>;
formatProgressEvent(#{type := failed, reason := Reason}) ->
    iolist_to_binary([<<"! 失败: "/utf8>>, formatTerm(Reason)]);
formatProgressEvent(#{type := error, reason := Reason}) ->
    iolist_to_binary([<<"! 错误: "/utf8>>, formatTerm(Reason)]);
formatProgressEvent(_) ->
    <<>>.

%%--------------------------------------------------------------------
%% @doc
%% 尝试本地直接回答：匹配"查看 agent 配置"或 alConfig:load 关键词时直接输出，
%% 命中返回 true（无需走 LLM），未命中返回 false。
%%
%% @end
%%--------------------------------------------------------------------
tryLocalAnswer(Prompt) when is_binary(Prompt) ->
    S = string:trim(Prompt),
    case {matchAgentConfigQuery(S), matchLoadConfigQuery(S)} of
        {true, _} ->
            printAgentConfig(),
            true;
        {_, true} ->
            io:format("~n~p~n", [alConfig:load()]),
            true;
        _ ->
            false
    end;
tryLocalAnswer(Prompt) ->
    tryLocalAnswer(promptBinary(Prompt)).

%%--------------------------------------------------------------------
%% @doc
%% 判断输入是否为查询 Agent 配置的同义问句。
%% 必须同时具备「agent」整词与「配置/config」，避免 alAgent / callGraph
%% 等正常提问被误判成 /config。
%% @end
%%--------------------------------------------------------------------
matchAgentConfigQuery(S) when is_binary(S) ->
    HasConfig = case re:run(S, <<"(?<![A-Za-z])(config|配置)(?![A-Za-z])"/utf8>>,
                            [unicode, caseless]) of
        {match, _} -> true;
        nomatch -> false
    end,
    HasAgent = case re:run(S, <<"(?<![A-Za-z])agent(?![A-Za-z])">>, [unicode, caseless]) of
        {match, _} -> true;
        nomatch -> false
    end,
    %% 排除 reconfigure / misconfigured 等长词里的 config 子串（整词已挡）
    %% 以及过长自由问答：仅短句更像「看配置」命令
    HasConfig andalso HasAgent andalso byte_size(S) < 80.
%%--------------------------------------------------------------------
%% @doc
%% 判断输入是否为请求 alConfig:load 的语句。
%%
%% @end
%%--------------------------------------------------------------------
matchLoadConfigQuery(S) when is_binary(S) ->
    case re:run(S, <<"alConfig\\s*:\\s*load"/utf8>>, [unicode, caseless]) of
        {match, _} -> true;
        nomatch -> false
    end.

%%--------------------------------------------------------------------
%% @doc
%% 待审批时：肯定语批准、否定语驳回；无 pending 或不匹配则返回 false。
%% @end
%%--------------------------------------------------------------------
maybeHandleApprovalReply(Prompt, Opts) when is_binary(Prompt) ->
    case maps:get(pendingApprove, Opts, undefined) of
        undefined ->
            false;
        Tid ->
            case classifyApprovalReply(Prompt) of
                approve -> {handled, runChatApprove(Tid, Opts)};
                dismiss -> {handled, runChatDismiss(Tid, Opts)};
                neither -> false
            end
    end.

%% 短句肯定/否定分类（避免把含「好的」的长问题误判为批准）。
classifyApprovalReply(Prompt) when is_binary(Prompt) ->
    S = string:lowercase(string:trim(Prompt)),
    case byte_size(S) > 24 of
        true -> neither;
        false ->
            case isAffirmative(S) of
                true -> approve;
                false ->
                    case isNegative(S) of
                        true -> dismiss;
                        false -> neither
                    end
            end
    end.

isAffirmative(S) ->
    lists:member(S, [
        <<"确认"/utf8>>, <<"好的"/utf8>>, <<"好"/utf8>>, <<"是"/utf8>>,
        <<"是的"/utf8>>, <<"同意"/utf8>>, <<"批准"/utf8>>, <<"可以"/utf8>>,
        <<"行"/utf8>>, <<"确定"/utf8>>, <<"没问题"/utf8>>, <<"继续"/utf8>>,
        <<"ok">>, <<"okay">>, <<"yes">>, <<"y">>, <<"approve">>, <<"lgtm">>, <<"go">>
    ]).

isNegative(S) ->
    lists:member(S, [
        <<"取消"/utf8>>, <<"拒绝"/utf8>>, <<"否"/utf8>>, <<"不"/utf8>>,
        <<"不要"/utf8>>, <<"驳回"/utf8>>, <<"算了"/utf8>>,
        <<"no">>, <<"n">>, <<"dismiss">>, <<"cancel">>, <<"reject">>
    ]).

%% 记住本轮挂起的审批 TaskId；无挂起则清掉旧的。
rememberPending(Opts, #{pendingTaskId := Tid, suspended := true}) when Tid =/= undefined ->
    io:format("  （回复「确认」或 /approve 继续；「取消」或 /dismiss 驳回）~n"),
    Opts#{pendingApprove => toBinary(Tid)};
rememberPending(Opts, #{<<"pendingTaskId">> := Tid, <<"suspended">> := true})
  when Tid =/= undefined ->
    rememberPending(Opts, #{pendingTaskId => Tid, suspended => true});
rememberPending(Opts, #{answer := Inner}) when is_map(Inner) ->
    rememberPending(Opts, Inner);
rememberPending(Opts, _) ->
    clearPending(Opts).

clearPending(Opts) when is_map(Opts) ->
    maps:remove(pendingApprove, Opts);
clearPending(Opts) ->
    Opts.

%% 批准并展示续跑结果；成功后清除 pendingApprove。
runChatApprove(TaskId, Opts) ->
    Parent = self(),
    Ref = make_ref(),
    ProgressId = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    alProgress:start(ProgressId),
    Tid = toBinary(TaskId),
    Extra = #{progressId => ProgressId},
    Extra1 = case maps:get(sessionId, Opts, undefined) of
        undefined -> Extra;
        Sid -> Extra#{sessionId => Sid}
    end,
    printSection(<<"批准"/utf8>>),
    io:format("  正在批准 TaskId=~ts ...~n", [Tid]),
    {Pid, MonRef} = spawn_monitor(fun() ->
        Result =
            try alServer:approve(Tid, Extra1) of
                {ok, Answer} -> {ok, Answer};
                {error, Reason} -> {error, Reason};
                Other -> {ok, Other}
            catch
                Class:Reason:Stack ->
                    {error, {Class, Reason, Stack}}
            end,
        Parent ! {eChatTurnDone, Ref, Result}
    end),
    StartMs = erlang:monotonic_time(millisecond),
    TimeoutMs = chatTimeoutMs(chatAskOpts(Opts, ProgressId)),
    case waitChatTurn(Ref, StartMs, TimeoutMs, ProgressId, 0, chatAskOpts(Opts, ProgressId)) of
        {ok, Answer} ->
            _ = erlang:demonitor(MonRef, [flush]),
            io:format("~n"),
            printAgentTurn(safeDisplayAnswer(Answer)),
            rememberPending(clearPending(Opts), Answer);
        {error, Reason} ->
            _ = erlang:demonitor(MonRef, [flush]),
            io:format("~n"),
            printSection(<<"错误"/utf8>>),
            io:format("  ~ts~n", [formatChatError(Reason)]),
            printRule(),
            %% 批准失败时保留 pending，便于重试
            Opts#{pendingApprove => Tid};
        timeout ->
            exit(Pid, kill),
            _ = erlang:demonitor(MonRef, [flush]),
            io:format("~n"),
            printSection(<<"超时"/utf8>>),
            io:format("  批准后续跑超时~n"),
            printRule(),
            Opts#{pendingApprove => Tid}
    end.

runChatDismiss(TaskId, Opts) ->
    Tid = toBinary(TaskId),
    case ali:dismiss(Tid) of
        ok ->
            io:format("已驳回 TaskId=~ts~n", [Tid]);
        {error, Reason} ->
            io:format("驳回失败: ~p~n", [Reason]);
        Other ->
            io:format("驳回结果: ~p~n", [Other])
    end,
    clearPending(Opts).

%%--------------------------------------------------------------------
%% @doc
%% 将 Agent 返回值安全转为可显示文本：处理 map（answer / reason / summary）、
%% binary（校验 UTF-8 合法性与空回答）、list 等，给出友好提示。
%%
%% @end
%%--------------------------------------------------------------------
safeDisplayAnswer(#{answer := Answer}) ->
    safeDisplayAnswer(Answer);
safeDisplayAnswer(#{reason := llmNotConfigured}) ->
    <<"LLM 未配置。请在 config/aliCfg.cfg 设置 llm.api_key（及 base_url/model），"
      "保存后重启 rebar3 shell，输入 /config 确认。"/utf8>>;
safeDisplayAnswer(#{reason := Reason, summary := Summary}) when is_binary(Summary) ->
    iolist_to_binary([Summary, <<"\n(reason: ">>, formatTerm(Reason), <<")">>]);
safeDisplayAnswer(#{reason := Reason}) ->
    iolist_to_binary([<<"本地回退回答（LLM 不可用）: "/utf8>>, formatTerm(Reason),
                      <<"\n输入 /config 检查 api_key / base_url。"/utf8>>]);
safeDisplayAnswer(Answer) when is_binary(Answer) ->
    case utf8Printable(Answer) of
        true ->
            case byte_size(Answer) of
                0 -> <<"（回答为空，可能配置有误，输入 /config 查看当前配置）"/utf8>>;
                _ ->
                    try alMdTerm:format(Answer)
                    catch _:_ -> Answer
                    end
            end;
        false ->
            <<"（回答包含非法字符无法显示，输入 /clear 清空历史后重试，或 /config 检查配置）"/utf8>>
    end;
safeDisplayAnswer(Answer) when is_list(Answer) ->
    safeDisplayAnswer(toBinary(Answer));
safeDisplayAnswer(Answer) ->
    safeDisplayAnswer(toBinary(Answer)).

%%--------------------------------------------------------------------
%% @doc
%% 判断 binary 是否为合法可打印的 UTF-8 文本。
%%
%% @end
%%--------------------------------------------------------------------
utf8Printable(Bin) when is_binary(Bin) ->
    try
        _ = unicode:characters_to_list(Bin, utf8),
        true
    catch
        _:_ -> false
    end;
utf8Printable(_) ->
    false.

%% 按「字符」截断预览，禁止 binary:part 切断 UTF-8 多字节序列。
%% 切断后的非法 UTF-8 在 Windows 上 ~ts 会整段按 Latin-1 显示成乱码。
utf8Preview(Msg, MaxChars) when is_binary(Msg), is_integer(MaxChars), MaxChars > 0 ->
    case unicode:characters_to_list(Msg, utf8) of
        List when is_list(List) ->
            Flat = lists:flatten(List),
            {Head, Suff} = case string:length(Flat) > MaxChars of
                true -> {string:slice(Flat, 0, MaxChars), "..."};
                false -> {Flat, ""}
            end,
            case unicode:characters_to_binary(Head ++ Suff, utf8) of
                Bin when is_binary(Bin) -> Bin;
                _ -> <<>>
            end;
        {error, Good, _Rest} ->
            %% 部分合法前缀仍可展示
            case unicode:characters_to_binary(Good, utf8) of
                Bin when is_binary(Bin) -> Bin;
                _ -> <<"[binary]">>
            end;
        {incomplete, Good, _Rest} ->
            case unicode:characters_to_binary(Good, utf8) of
                Bin when is_binary(Bin) -> Bin;
                _ -> <<"[binary]">>
            end;
        _ ->
            <<"[binary]">>
    end;
utf8Preview(Msg, MaxChars) when is_list(Msg) ->
    utf8Preview(unicode:characters_to_binary(Msg), MaxChars);
utf8Preview(_, _) ->
    <<>>.

%%--------------------------------------------------------------------
%% @doc
%% 将错误原因格式化为人类可读的中文提示，覆盖常见错误原子。
%%
%% @end
%%--------------------------------------------------------------------
formatChatError(maxStepsExceeded) ->
    <<"已达到最大步数上限，请调整 aliCfg.cfg 中的 max_steps，或 /clear 清空历史后重试"/utf8>>;
formatChatError(timeout) ->
    <<"请求超时，请检查 LLM API 连通性、aliCfg.cfg 中的 api_key/base_url，或调大 exec_timeout"/utf8>>;
formatChatError(streamTimeout) ->
    <<"流式响应超时，可能网络抖动或服务繁忙，请稍后重新提问"/utf8>>;
formatChatError(sessionBusy) ->
    <<"会话正忙（上一轮可能超时未释放），输入 /cancel 取消后再试"/utf8>>;
formatChatError(cancelled) ->
    <<"问答已取消"/utf8>>;
formatChatError({llmFailed, #{status := Status, body := Body}, _}) ->
    unicode:characters_to_binary(
        io_lib:format("LLM HTTP ~p: ~ts。请检查 aliCfg.cfg 中 llm.model（DeepSeek 现为 deepseek-v4-pro / deepseek-v4-flash）",
                      [Status, truncateErrBody(Body)]));
formatChatError({llmFailed, closed, _}) ->
    <<"LLM 连接被对端关闭（closed）。已会自动重试；若仍失败请检查网络/API，或 /clear 后重试"/utf8>>;
formatChatError({llmFailed, {closed, _}, _}) ->
    <<"LLM 连接被对端关闭（closed）。已会自动重试；若仍失败请检查网络/API，或 /clear 后重试"/utf8>>;
formatChatError({llmFailed, callerDown, _}) ->
    <<"流式接收进程已退出（多为中间轮误关）。已修复后请重试本问；若仍出现请 /clear 后重试"/utf8>>;
formatChatError({llmFailed, cancelled, _}) ->
    <<"问答流已取消"/utf8>>;
formatChatError({llmFailed, Reason, _}) ->
    unicode:characters_to_binary(io_lib:format(
        "LLM 调用失败: ~p。可检查 api_key/base_url/model/网络后重试，或 /clear 清空会话", [Reason]));
formatChatError(closed) ->
    <<"LLM 连接被关闭，请稍后重试"/utf8>>;
formatChatError({error, badarg}) ->
    <<"内部参数错误（badarg）。请查看终端输出或 .ali/logs/ask_errors.log"/utf8>>;
formatChatError(badarg) ->
    <<"内部参数错误（badarg）。请查看终端输出或 .ali/logs/ask_errors.log"/utf8>>;
formatChatError({agentCrash, Class, Reason, Stack}) ->
    alAskDiag:formatDetail(Class, Reason, Stack);
formatChatError({error, Reason}) ->
    formatChatError(Reason);
formatChatError(Reason) when is_binary(Reason) ->
    utf8Preview(Reason, 800);
formatChatError(Reason) ->
    unicode:characters_to_binary(io_lib:format("error: ~p", [Reason])).

truncateErrBody(Body) when is_binary(Body) ->
    utf8Preview(Body, 400);
truncateErrBody(Body) ->
    truncateErrBody(unicode:characters_to_binary(io_lib:format("~p", [Body]))).

%%--------------------------------------------------------------------
%% @doc
%% 归一化选项：将 map 或 proplist 转为以 atom 为键的 map，
%% 同时将 sessionId/progressId 驼峰键统一为 atom 形式并转为 binary。
%%
%% @end
%%--------------------------------------------------------------------
normalizeOpts(Opts) when is_map(Opts) ->
    maps:fold(fun normalizeOptKey/3, #{}, Opts);
normalizeOpts(Opts) when is_list(Opts) ->
    normalizeOpts(maps:from_list(Opts)).

%% 单个键值归一化：sessionId（binary），progressId（binary）。
normalizeOptKey(sessionId, V, Acc) ->
    Acc#{sessionId => toBinary(V)};
normalizeOptKey(progressId, V, Acc) ->
    Acc#{progressId => toBinary(V)};
normalizeOptKey(pendingApprove, V, Acc) ->
    Acc#{pendingApprove => toBinary(V)};
normalizeOptKey(K, V, Acc) when is_atom(K) ->
    Acc#{K => V};
normalizeOptKey(K, V, Acc) when is_binary(K) ->
    normalizeOptKey(safeExistingAtom(K), V, Acc).

%%--------------------------------------------------------------------
%% @doc
%% 去除输入行尾部的换行/回车，并归一化为 binary。
%%
%% @end
%%--------------------------------------------------------------------
trimLine(Line) when is_binary(Line) ->
    promptBinary(string:trim(binary_to_list(Line), trailing, "\r\n"));
trimLine(Line) when is_list(Line) ->
    promptBinary(string:trim(Line, trailing, "\r\n"));
trimLine(Line) ->
    promptBinary(Line).

%%--------------------------------------------------------------------
%% @doc
%% 将任意输入归一化为 binary：binary 原样、list 转 binary、其它用 ~p 格式化。
%%
%% @end
%%--------------------------------------------------------------------
promptBinary(Bin) when is_binary(Bin) ->
    Bin;
promptBinary(List) when is_list(List) ->
    unicode:characters_to_binary(List);
promptBinary(Other) ->
    unicode:characters_to_binary(io_lib:format("~p", [Other])).

%%--------------------------------------------------------------------
%% @doc
%% 确保 ali 应用已启动：若 alServer 已存在直接返回；否则 ensure_all_started。
%%
%% @return {ok, Pid} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
ensureStarted() ->
    case whereis(alServer) of
        Pid when is_pid(Pid) ->
            {ok, Pid};
        undefined ->
            case application:ensure_all_started(ali) of
                {ok, _} ->
                    case whereis(alServer) of
                        Pid2 when is_pid(Pid2) -> {ok, Pid2};
                        undefined -> {error, agentNotStarted}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 安全将 binary 转为已存在的 atom；若 atom 不存在则原样返回 binary。
%%
%% @end
%%--------------------------------------------------------------------
safeExistingAtom(B) when is_binary(B) ->
    try binary_to_existing_atom(B, utf8) catch _:_ -> B end.

%%--------------------------------------------------------------------
%% @doc
%% 格式化工具参数后缀：map 为 [k=>v, ...]，其它为 [value]，空则返回 <<>>。
%%
%% @end
%%--------------------------------------------------------------------
formatArgsSuffix(undefined) -> <<>>;
formatArgsSuffix(Args) when is_map(Args) ->
    case maps:size(Args) of
        0 -> <<>>;
        _ ->
            Pairs = [iolist_to_binary([argLabel(K), <<"=>"/utf8>>, formatArgValue(V)])
                || {K, V} <- lists:sort(maps:to_list(Args))],
            iolist_to_binary([<<" ["/utf8>>, lists:join(<<", "/utf8>>, Pairs), <<"]"/utf8>>])
    end;
formatArgsSuffix(Other) ->
    iolist_to_binary([<<" ["/utf8>>, formatArgValue(Other), <<"]"/utf8>>]).

%% 将参数键转为 binary 标签。
argLabel(K) when is_atom(K) -> atom_to_binary(K, utf8);
argLabel(K) when is_binary(K) -> K;
argLabel(K) -> formatTerm(K).

%% 格式化单个参数值（当前所有类型统一走 formatTerm）。
formatArgValue(V) when is_binary(V); is_atom(V); is_integer(V); is_float(V); is_boolean(V) ->
    formatTerm(V);
formatArgValue(V) ->
    formatTerm(V).

%% 将工具名转为可读 binary 标签。
toolLabel(T) when is_atom(T) -> atom_to_binary(T, utf8);
toolLabel(T) when is_binary(T) -> T;
toolLabel(T) ->
    unicode:characters_to_binary(io_lib:format("~p", [T])).

%%--------------------------------------------------------------------
%% @doc
%% 将任意 term 格式化为 binary：binary 原样返回，其它用 ~p 格式化后转 binary。
%%
%% @end
%%--------------------------------------------------------------------
formatTerm(Reason) when is_binary(Reason) -> Reason;
formatTerm(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).

%%--------------------------------------------------------------------
%% @doc
%% 格式化会话 ID 用于显示：Loaded 与原始 Id 一致时直接用 Id，否则用 Loaded。
%%
%% @end
%%--------------------------------------------------------------------
formatSessionId(Loaded, Id) ->
    case Loaded of
        X when X =:= Id -> toList(Id);
        X -> toList(X)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 将任意输入转为 binary：支持 binary / list / atom 及其它 term（~p 格式化）。
%%
%% @end
%%--------------------------------------------------------------------
toBinary(X) when is_binary(X) -> X;
toBinary(X) when is_list(X) -> unicode:characters_to_binary(X);
toBinary(X) when is_atom(X) -> atom_to_binary(X, utf8);
toBinary(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).

%%--------------------------------------------------------------------
%% @doc
%% 将任意输入转为 list：支持 list / binary / atom 及其它 term（~p 格式化）。
%%
%% @end
%%--------------------------------------------------------------------
toList(X) when is_list(X) -> X;
toList(X) when is_binary(X) -> unicode:characters_to_list(X);
toList(X) when is_atom(X) -> atom_to_list(X);
toList(X) -> io_lib:format("~p", [X]).
