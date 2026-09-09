%%%-------------------------------------------------------------------
%% @doc ali 系统功能验证脚本。
%%
%% 通过 {@link run/0} 运行全部验证用例，或 {@link run/1} 运行指定分类。
%% 用例混合了直接工具调用（确定性）和 LLM 对话（需 API key）。
%%
%% == 使用方法 ==
%%
%% 在 `rebar3 shell' 中：
%%
%% ```
%% alVerify:run().                      %% 运行全部（含真实 LLM 请求）
%% alVerify:run(llm).                   %% 只运行 LLM 分类（含流式/工具/取消）
%% alVerify:run([search, memory]).      %% 运行多个分类
%% alVerify:help().                     %% 查看测试计划
%% alVerify:listCases().                %% 列出全部用例
%% '''
%%
%% == 验证分类 ==
%%
%% <table border="1">
%% <tr><th>分类</th><th>atom</th><th>用例数</th><th>说明</th></tr>
%% <tr><td>LLM 真实请求</td><td>`llm'</td><td>8</td><td>同步/流式/工具/取消，走当前 ali 配置</td></tr>
%% <tr><td>代码搜索</td><td>`search'</td><td>3</td><td>BM25 检索、索引状态</td></tr>
%% <tr><td>调用图</td><td>`callgraph'</td><td>3</td><td>调用者/被调用者/完整图</td></tr>
%% <tr><td>符号查找</td><td>`symbol'</td><td>2</td><td>模块符号、符号详情</td></tr>
%% <tr><td>记忆系统</td><td>`memory'</td><td>3</td><td>存储/关键词回忆/语义回忆</td></tr>
%% <tr><td>文件读取</td><td>`fileread'</td><td>2</td><td>配置文件、源码文件</td></tr>
%% <tr><td>运行时探针</td><td>`runtime'</td><td>4</td><td>运行时/进程/ETS/监督树</td></tr>
%% <tr><td>策略安全</td><td>`policy'</td><td>2</td><td>危险命令/路径遍历拦截</td></tr>
%% <tr><td>数据库</td><td>`db'</td><td>2</td><td>状态查询、SQL 查询</td></tr>
%% <tr><td>备份恢复</td><td>`backup'</td><td>2</td><td>创建备份、列出备份</td></tr>
%% </table>
%%
%% == 用例清单 ==
%%
%% === LLM 真实请求 (`llm') ===
%%
%% <table>
%% <tr><th>ID</th><th>描述</th><th>验证点</th></tr>
%% <tr><td>L1</td><td>基础对话：自我介绍</td><td>LLM API 连通性、响应解析</td></tr>
%% <tr><td>L2</td><td>数学计算：1+1</td><td>指令遵循、回答准确性</td></tr>
%% <tr><td>RL1</td><td>同步对话：严格短答</td><td>chat/2 短答遵循</td></tr>
%% <tr><td>RL2</td><td>同步对话：多行格式遵循</td><td>chat/2 多行输出</td></tr>
%% <tr><td>RL3</td><td>流式对话：chunk/done 链路</td><td>stream/4 SSE 事件</td></tr>
%% <tr><td>RL4</td><td>同步工具调用</td><td>chatWithTools + toolChoice</td></tr>
%% <tr><td>RL5</td><td>流式工具调用</td><td>streamChatWithTools 汇总</td></tr>
%% <tr><td>RL6</td><td>流式取消：callerDown</td><td>caller 退出后取消 HTTP 流</td></tr>
%% </table>
%%
%% === 代码搜索 (`search') ===
%%
%% <table>
%% <tr><th>ID</th><th>描述</th><th>验证点</th></tr>
%% <tr><td>S1</td><td>BM25 搜索：alServer ask</td><td>全文检索</td></tr>
%% <tr><td>S2</td><td>搜索 handle_call</td><td>跨模块搜索</td></tr>
%% <tr><td>S3</td><td>索引状态查询</td><td>indexStatus 工具</td></tr>
%% </table>
%%
%% === 调用图 (`callgraph') ===
%%
%% <table>
%% <tr><th>ID</th><th>描述</th><th>验证点</th></tr>
%% <tr><td>G1</td><td>获取调用者：alServer ask</td><td>getCallers 工具</td></tr>
%% <tr><td>G2</td><td>获取被调用者：alServer ask</td><td>getCallees 工具</td></tr>
%% <tr><td>G3</td><td>获取完整调用图</td><td>callGraph 工具</td></tr>
%% </table>
%%
%% === 符号查找 (`symbol') ===
%%
%% <table>
%% <tr><th>ID</th><th>描述</th><th>验证点</th></tr>
%% <tr><td>Y1</td><td>模块符号列表：alServer</td><td>moduleSymbols 工具</td></tr>
%% <tr><td>Y2</td><td>符号详情：alServer ask/1</td><td>getSymbol 工具</td></tr>
%% </table>
%%
%% === 记忆系统 (`memory') ===
%%
%% <table>
%% <tr><th>ID</th><th>描述</th><th>验证点</th></tr>
%% <tr><td>M1</td><td>存储记忆</td><td>remember 工具</td></tr>
%% <tr><td>M2</td><td>关键词回忆</td><td>recall 工具</td></tr>
%% <tr><td>M3</td><td>语义回忆</td><td>recallSemantic 工具</td></tr>
%% </table>
%%
%% === 文件读取 (`fileread') ===
%%
%% <table>
%% <tr><th>ID</th><th>描述</th><th>验证点</th></tr>
%% <tr><td>F1</td><td>读取配置文件</td><td>readFile 工具</td></tr>
%% <tr><td>F2</td><td>读取源码文件</td><td>readFile 范围读取</td></tr>
%% </table>
%%
%% === 运行时探针 (`runtime') ===
%%
%% <table>
%% <tr><th>ID</th><th>描述</th><th>验证点</th></tr>
%% <tr><td>R1</td><td>运行时快照</td><td>getRuntime 工具</td></tr>
%% <tr><td>R2</td><td>进程列表</td><td>getProcesses 工具</td></tr>
%% <tr><td>R3</td><td>ETS 表列表</td><td>getEts 工具</td></tr>
%% <tr><td>R4</td><td>监督树结构</td><td>supervisorTree 工具</td></tr>
%% </table>
%%
%% === 策略安全 (`policy') ===
%%
%% <table>
%% <tr><th>ID</th><th>描述</th><th>验证点</th></tr>
%% <tr><td>Q1</td><td>危险命令拦截</td><td>rm -rf 被策略拒绝</td></tr>
%% <tr><td>Q2</td><td>路径遍历防护</td><td>../etc/passwd 被拒绝</td></tr>
%% </table>
%%
%% === 数据库 (`db') ===
%%
%% <table>
%% <tr><th>ID</th><th>描述</th><th>验证点</th></tr>
%% <tr><td>D1</td><td>数据库状态</td><td>coreStatus/dbStatus</td></tr>
%% <tr><td>D2</td><td>DB 查询：记忆表</td><td>dbQuery 工具</td></tr>
%% </table>
%%
%% === 备份恢复 (`backup') ===
%%
%% <table>
%% <tr><th>ID</th><th>描述</th><th>验证点</th></tr>
%% <tr><td>B1</td><td>创建文件备份</td><td>alBackup:backupFile/1</td></tr>
%% <tr><td>B2</td><td>列出备份</td><td>alBackup:listBackups/1</td></tr>
%% </table>
%%
%% == 输出格式 ==
%%
%% ```
%% =========================================================
%%   ali 系统功能验证报告
%%   分类: 全部 | 用例数: 25
%% =========================================================
%% [LLM] L1: 基础对话：自我介绍 .......... PASS (1.2s)
%% [LLM] L2: 数学计算：1+1 .............. PASS (0.8s)
%% [SEARCH] S1: BM25 搜索：alServer ask .. PASS (0.3s)
%% ...
%% ---------------------------------------------------------
%%   总计: 23 通过 / 2 失败 / 25 用例
%%   耗时: 12.4s
%%   状态: 有失败用例 ✗
%% =========================================================
%% '''
%%
%% @end
%%%-------------------------------------------------------------------

-module(alVerify).

-export([run/0, run/1, runRealLlm/0, runRealLlm/1, realLlmCases/0,
         help/0, listCases/0, listRealLlmCases/0, nonLlmCategories/0]).
%% Test exports — pure helpers
-export([extractLlmContent/1, validateCategories/1, listOf/2, memoryEntries/1]).

-define(LineLen, 60).
-define(DefaultTimeout, 30000).
-define(LlmTimeout, 120000).

%%--------------------------------------------------------------------
%% @doc 运行全部验证用例。
%% @end
%%--------------------------------------------------------------------
run() ->
    run(allCategories()).

%%--------------------------------------------------------------------
%% @doc 运行指定分类的验证用例。Category 可以是 atom 或 atom list。
%% 全部通过返回 `ok'；有失败返回 `{error, {failed, N}}'（CI 可据此设
%% 非零退出码）；分类名未知时抛 `unknownCategory'。
%% @end
%%--------------------------------------------------------------------
run(Category) when is_atom(Category) ->
    run([Category]);
run(Categories) when is_list(Categories) ->
    ensureStarted(),
    Cases = selectCases(Categories),
    case {validateCategories(Categories), Cases} of
        {Unknown, []} when Unknown =/= [] ->
            io:format("~n  未知分类: ~p（可用: ~p）~n",
                      [Unknown, allCategories()]),
            erlang:error(unknownCategory);
        {_, []} ->
            io:format("~n  无匹配用例~n"),
            erlang:error(noCases);
        _ ->
            maybeWaitForIndex(Cases),
            printHeader(Categories, length(Cases)),
            {Pass, Fail, TotalMs} = runCases(Cases),
            printFooter(Pass, Fail, TotalMs),
            case Fail of
                0 -> ok;
                N -> {error, {failed, N}}
            end
    end.

%% 找出不在 allCategories 里的分类 atom（all 视为合法）。
validateCategories(Categories) ->
    [C || C <- Categories, C =/= all, not lists:member(C, allCategories())].

%% 仅当选中用例依赖代码索引（search/callgraph/symbol）时才等待构建完成。
maybeWaitForIndex(Cases) ->
    IndexDeps = [search, callgraph, symbol],
    NeedsIndex = lists:any(fun({_, Cat, _, _, _}) ->
                                lists:member(Cat, IndexDeps)
                        end, Cases),
    case NeedsIndex of
        true -> waitForIndex();
        false -> ok
    end.

%%--------------------------------------------------------------------
%% @doc 等待代码索引就绪（fresh 启动后索引异步构建，搜索/符号用例
%% 依赖它）。最多 90 秒；超时不阻断，相关用例将报告真实失败。
%% @end
%%--------------------------------------------------------------------
waitForIndex() ->
    case indexReady() of
        true ->
            ok;
        false ->
            io:format("  等待代码索引构建...~n"),
            waitIndexLoop(90)
    end.

waitIndexLoop(0) ->
    io:format("  索引等待超时（搜索/符号用例可能失败）~n"),
    ok;
waitIndexLoop(RemainSecs) ->
    case indexReady() of
        true ->
            io:format("  索引就绪（~b 秒内）~n", [90 - RemainSecs]),
            ok;
        false ->
            timer:sleep(1000),
            waitIndexLoop(RemainSecs - 1)
    end.

indexReady() ->
    try alToolCatalog:invoke(indexStatus, #{}) of
        {ok, #{ready := Ready}} when is_boolean(Ready) -> Ready;
        {ok, #{<<"ready">> := Ready}} when is_boolean(Ready) -> Ready;
        _ -> false
    catch
        _:_ -> false
    end.

%%--------------------------------------------------------------------
%% @doc 打印验证测试计划摘要。
%% @end
%%--------------------------------------------------------------------
help() ->
    setUnicodeIo(),
    io:format("~n========================================~n"),
    io:format("  ali 系统功能验证 — 测试计划~n"),
    io:format("========================================~n~n"),
    io:format("使用方法:~n"),
    io:format("  alVerify:run().                运行全部 ~p 个用例~n", [length(allCases())]),
    io:format("  alVerify:run(Category).        运行指定分类~n"),
    io:format("  alVerify:run([Cat1, Cat2]).    运行多个分类~n"),
    io:format("  alVerify:run(llm).             只跑真实 LLM 请求路径~n"),
    io:format("  alVerify:listCases().          列出全部用例~n~n"),
    io:format("分类列表:~n"),
    lists:foreach(fun({Cat, Desc, Count}) ->
        io:format("  ~-12s ~p 用例  ~ts~n", [atom_to_list(Cat), Count, Desc])
    end, categorySummary()),
    io:format("~n可用分类 atom: ~p~n", [allCategories()]),
    io:format("~nLLM 分类会真实请求当前 ali 配置的模型，不单独设置地址。~n"),
    io:format("建议在 ali:start() 后调用 alVerify:run() / run(llm)，不要跟 eunit 混跑。~n"),
    io:format("========================================~n"),
    ok.

%%--------------------------------------------------------------------
%% @doc 列出全部验证用例的 ID、分类、描述。
%% @end
%%--------------------------------------------------------------------
listCases() ->
    setUnicodeIo(),
    io:format("~n  ID   分类         描述~n"),
    io:format("  ---- ------------ ---------------------------------------~n"),
    lists:foreach(fun({Id, Cat, Desc, _Timeout, _Fun}) ->
        IdStr = string:to_upper(atom_to_list(Id)),
        CatStr = atom_to_list(Cat),
        io:format("  ~-4s ~-12s ~ts~n", [IdStr, CatStr, Desc])
    end, allCases()),
    io:format("~n  共 ~p 个用例~n", [length(allCases())]),
    ok.

%%--------------------------------------------------------------------
%% @doc 列出真实 LLM 请求验证用例。
%% @end
%%--------------------------------------------------------------------
listRealLlmCases() ->
    listCases().

%%--------------------------------------------------------------------
%% @doc 运行真实 LLM 请求验证。
%%
%% 这些用例会直接命中当前 ali 的 llm 配置，适合在 `ali:start()' 后手动
%% 执行，覆盖同步/流式/工具调用/流式工具/取消等真实链路。
%% @end
%%--------------------------------------------------------------------
runRealLlm() ->
    run(llm).

runRealLlm(all) ->
    run(llm);
runRealLlm(CaseId) when is_atom(CaseId) ->
    runRealLlm([CaseId]);
runRealLlm(CaseIds) when is_list(CaseIds) ->
    Cases = [C || C = {Id, _, _, _, _} <- realLlmCases(), lists:member(Id, CaseIds)],
    case Cases of
        [] ->
            io:format("~n  未知真实 LLM 用例: ~p（可用: ~p）~n",
                      [CaseIds, [Id || {Id, _, _, _, _} <- realLlmCases()]]),
            erlang:error(unknownRealLlmCase);
        _ ->
            runNamedCases("真实 LLM 请求验证", Cases)
    end.

%%%===================================================================
%%% 用例定义
%%%===================================================================

%% 全部分类
allCategories() ->
    [llm, search, callgraph, symbol, memory, fileread, runtime, policy, db, backup].

%% Categories that do not require an LLM API key — suitable for CI smoke.
-spec nonLlmCategories() -> [atom()].
nonLlmCategories() ->
    [search, callgraph, symbol, fileread, runtime, policy, db, backup].

%% 分类摘要：{atom, 描述, 用例数}
categorySummary() ->
    Cases = allCases(),
    [{Cat, categoryDesc(Cat), length([C || {_, C, _, _, _} <- Cases, C =:= Cat])}
     || Cat <- allCategories()].

%% 分类中文描述
categoryDesc(llm) -> "LLM 真实请求";
categoryDesc(search) -> "代码搜索";
categoryDesc(callgraph) -> "调用图分析";
categoryDesc(symbol) -> "符号查找";
categoryDesc(memory) -> "记忆系统";
categoryDesc(fileread) -> "文件读取";
categoryDesc(runtime) -> "运行时探针";
categoryDesc(policy) -> "策略安全";
categoryDesc(db) -> "数据库";
categoryDesc(backup) -> "备份恢复";
categoryDesc(_) -> "未知".

%% 按分类选取用例
selectCases(Categories) ->
    All = allCases(),
    Filter = case lists:member(all, Categories) of
        true -> fun(_) -> true end;
        false -> fun({_, Cat, _, _, _}) -> lists:member(Cat, Categories) end
    end,
    lists:filter(Filter, All).

%% 全部用例：{Id, Category, Description, TimeoutMs, Fun}
allCases() ->
    [
        %% ===== LLM 基础对话 =====
        {l1, llm, "基础对话：自我介绍", ?LlmTimeout, fun caseLlmBasic/0},
        {l2, llm, "数学计算：1+1", ?LlmTimeout, fun caseLlmMath/0},
        {rl1, llm, "同步对话：严格短答", ?LlmTimeout, fun caseRealSyncShort/0},
        {rl2, llm, "同步对话：多行格式遵循", ?LlmTimeout, fun caseRealSyncMultiline/0},
        {rl3, llm, "流式对话：chunk/done 链路", ?LlmTimeout, fun caseRealStreamBasic/0},
        {rl4, llm, "同步工具调用：required tool_choice", ?LlmTimeout, fun caseRealToolCall/0},
        {rl5, llm, "流式工具调用：delta + 汇总回复", ?LlmTimeout, fun caseRealStreamToolCall/0},
        {rl6, llm, "流式取消：callerDown 取消链路", ?LlmTimeout + 20000, fun caseRealStreamCancel/0},

        %% ===== 代码搜索 =====
        {s1, search, "BM25 搜索：alServer ask", 15000, fun caseSearchBasic/0},
        {s2, search, "搜索 handle_call", 15000, fun caseSearchHandleCall/0},
        {s3, search, "索引状态查询", 10000, fun caseIndexStatus/0},

        %% ===== 调用图 =====
        {g1, callgraph, "获取调用者：alServer ask", 15000, fun caseCallers/0},
        {g2, callgraph, "获取被调用者：alServer ask", 15000, fun caseCallees/0},
        {g3, callgraph, "获取完整调用图", 15000, fun caseCallGraph/0},

        %% ===== 符号查找 =====
        {y1, symbol, "模块符号列表：alServer", 15000, fun caseModuleSymbols/0},
        {y2, symbol, "符号详情：alServer ask/1", 15000, fun caseGetSymbol/0},

        %% ===== 记忆系统 =====
        {m1, memory, "存储记忆", 15000, fun caseMemoryStore/0},
        {m2, memory, "关键词回忆", 15000, fun caseMemoryRecall/0},
        {m3, memory, "语义回忆", 15000, fun caseMemorySemantic/0},

        %% ===== 文件读取 =====
        {f1, fileread, "读取配置文件", 10000, fun caseReadConfig/0},
        {f2, fileread, "读取源码文件", 10000, fun caseReadSource/0},

        %% ===== 运行时探针 =====
        {r1, runtime, "运行时快照", 10000, fun caseGetRuntime/0},
        {r2, runtime, "进程列表", 10000, fun caseGetProcesses/0},
        {r3, runtime, "ETS 表列表", 10000, fun caseGetEts/0},
        {r4, runtime, "监督树结构", 10000, fun caseSupervisorTree/0},

        %% ===== 策略安全 =====
        {q1, policy, "危险命令拦截", 10000, fun casePolicyBlock/0},
        {q2, policy, "路径遍历防护", 10000, fun casePolicyPath/0},

        %% ===== 数据库 =====
        {d1, db, "数据库状态", 10000, fun caseDbStatus/0},
        {d2, db, "DB 查询：记忆表", 10000, fun caseDbQuery/0},

        %% ===== 备份 =====
        {b1, backup, "创建文件备份", 15000, fun caseBackupCreate/0},
        {b2, backup, "列出备份", 10000, fun caseBackupList/0}
    ].

realLlmCases() ->
    [C || C = {_, Cat, _, _, _} <- allCases(), Cat =:= llm].

%%%===================================================================
%%% 用例实现
%%%===================================================================

%% ===== LLM 基础对话 =====

caseLlmBasic() ->
    Messages = [#{role => user, content => <<"你好，请用一句话介绍你自己"/utf8>>}],
    case alLlmClient:chat(Messages, #{}) of
        {ok, Result} ->
            Answer = extractLlmContent(Result),
            case isNonEmpty(Answer) of
                true -> ok;
                false -> {fail, "回复为空"}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

caseLlmMath() ->
    Messages = [#{role => user, content => <<"1+1等于几？只回答阿拉伯数字，不要任何其他文字"/utf8>>}],
    case alLlmClient:chat(Messages, #{}) of
        {ok, Result} ->
            Answer = toBinary(extractLlmContent(Result)),
            case binary:match(Answer, <<"2">>) of
                nomatch -> {fail, io_lib:format("回复未包含 2: ~s", [Answer])};
                _ -> ok
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% ===== 真实 LLM 请求路径（手动调用） =====

caseRealSyncShort() ->
    Messages = [#{role => user,
                  content => <<"只回答 OK ，不要任何别的字符"/utf8>>}],
    case alLlmClient:chat(Messages, #{}) of
        {ok, Result} ->
            Answer0 = extractLlmContent(Result),
            Answer = trimUpper(Answer0),
            case Answer of
                <<"OK">> -> ok;
                _ -> {fail, io_lib:format("期望严格返回 OK，实际: ~ts", [Answer0])}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

caseRealSyncMultiline() ->
    Messages = [#{role => user,
                  content => <<"请严格输出三行：\nA\nB\nC\n不要添加任何解释"/utf8>>}],
    case alLlmClient:chat(Messages, #{}) of
        {ok, Result} ->
            Answer = extractLlmContent(Result),
            case normalizeLines(Answer) of
                [<<"A">>, <<"B">>, <<"C">>] -> ok;
                Lines -> {fail, io_lib:format("多行格式不符合预期: ~p", [Lines])}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

caseRealStreamBasic() ->
    flushStreamEvents(),
    Messages = [#{role => user,
                  content => <<"请严格输出三行：red\nblue\ngreen\n不要解释"/utf8>>}],
    case alLlmClient:stream(Messages, [], #{}, self()) of
        {ok, Pid} ->
            case collectStreamResult(Pid, ?LlmTimeout) of
                {ok, #{done := Done, chunkCount := ChunkCount, content := Content}}
                  when Done =:= true, ChunkCount > 0 ->
                    case isNonEmpty(Content) of
                        true -> ok;
                        false -> {fail, "流式完成但内容为空"}
                    end;
                {ok, State} ->
                    {fail, io_lib:format("流式事件不足: ~p", [State])};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

caseRealToolCall() ->
    Messages = [#{role => user,
                  content => <<"不要心算，必须调用 add_numbers 工具计算 2+3。不要直接给答案。"/utf8>>}],
    Tools = verifyMathTools(),
    case alLlmClient:chatWithTools(Messages, Tools, #{toolChoice => required}) of
        {ok, Result} ->
            assertToolCallNamed(Result, <<"add_numbers">>);
        {error, Reason} ->
            {error, Reason}
    end.

caseRealStreamToolCall() ->
    flushStreamEvents(),
    Messages = [#{role => user,
                  content => <<"不要心算，必须调用 add_numbers 工具计算 12+30。不要直接给答案。"/utf8>>}],
    Tools = verifyMathTools(),
    case alLlmClient:streamChatWithTools(Messages, Tools, #{toolChoice => required}, self()) of
        {ok, Result} ->
            case assertToolCallNamed(Result, <<"add_numbers">>) of
                ok ->
                    Events = drainQueuedStreamEvents(),
                    case hasToolSignals(Events) of
                        true -> ok;
                        false -> {fail, io_lib:format("未观察到流式 tool 事件: ~p", [Events])}
                    end;
                Other ->
                    Other
            end;
        {error, Reason} ->
            {error, Reason}
    end.

caseRealStreamCancel() ->
    %% 思考模型可能先发 eStreamReasoning、很久才有 content。
    %% 任意流式活动都视为“流已开始”，然后杀掉 caller 验证 cancel watch。
    Parent = self(),
    Sink = spawn(fun() -> verifyStreamSink(Parent, false) end),
    Messages = [#{role => user,
                  content => <<"从 1 开始一直输出数字和空格，不要总结，不要停。"/utf8>>}],
    Opts = #{thinking => disabled},
    case alLlmClient:stream(Messages, [], Opts, Sink) of
        {ok, Worker} ->
            Mon = erlang:monitor(process, Worker),
            receive
                {verifyFirstEvent, Sink} ->
                    exit(Sink, kill),
                    waitWorkerExit(Mon, 15000);
                {verifySinkDone, Sink, Final} ->
                    erlang:demonitor(Mon, [flush]),
                    {fail, io_lib:format("callerDown 未触发，流已自然结束: ~ts", [Final])};
                {verifySinkError, Sink, Reason} ->
                    erlang:demonitor(Mon, [flush]),
                    {error, Reason}
            after ?LlmTimeout ->
                exit(Sink, kill),
                erlang:demonitor(Mon, [flush]),
                {fail, "等待流式首包超时，无法验证 callerDown 取消链路"}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% ===== 代码搜索 =====

caseSearchBasic() ->
    case alToolCatalog:invoke(searchCode, #{query => "alServer ask", limit => 5}) of
        {ok, Result} ->
            Hits = toolHits(Result),
            case length(Hits) > 0 of
                true -> ok;
                false -> {fail, "搜索结果为空（可能未索引）"}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

caseSearchHandleCall() ->
    case alToolCatalog:invoke(searchCode, #{query => "handle_call", limit => 10}) of
        {ok, Result} ->
            Hits = toolHits(Result),
            case length(Hits) > 0 of
                true -> ok;
                false -> {fail, "handle_call 搜索结果为空"}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

caseIndexStatus() ->
    case alToolCatalog:invoke(indexStatus, #{}) of
        {ok, Result} when is_map(Result), map_size(Result) > 0 -> ok;
        {error, Reason} -> {error, Reason}
    end.

%% ===== 调用图 =====

caseCallers() ->
    %% format=edges 请求原始边列表；ask/1 无静态调用者（0 条是真实状态），
    %% 断言的是「查询管道 + 边结构」而非非空。
    case alToolCatalog:invoke(getCallers, #{module => "alServer", function => "ask",
                                            arity => 1, format => edges}) of
        {ok, #{edges := Edges}} when is_list(Edges) -> ok;
        {error, Reason} -> {error, Reason}
    end.

caseCallees() ->
    %% ask/1 有 1 条被调用边（summary 实测 totalCount=1）——断言非空。
    case alToolCatalog:invoke(getCallees, #{module => "alServer", function => "ask",
                                            arity => 1, format => edges}) of
        {ok, #{edges := Edges}} when is_list(Edges), length(Edges) > 0 -> ok;
        {ok, #{edges := []}} -> {fail, "被调用边为空（索引数据缺失）"};
        {error, Reason} -> {error, Reason}
    end.

caseCallGraph() ->
    case alToolCatalog:invoke(callGraph, #{module => "alServer", maxEdges => 40}) of
        {ok, _} -> ok;
        {error, Reason} -> {error, Reason}
    end.

%% ===== 符号查找 =====

caseModuleSymbols() ->
    case alToolCatalog:invoke(moduleSymbols, #{module => "alServer"}) of
        {ok, Result} when is_map(Result) ->
            Symbols = toolFunctions(Result),
            case length(Symbols) > 0 of
                true -> ok;
                false -> {fail, "符号列表为空"}
            end;
        {error, Reason} -> {error, Reason}
    end.

caseGetSymbol() ->
    case alToolCatalog:invoke(getSymbol, #{module => "alServer", function => "ask", arity => 1}) of
        {ok, _} -> ok;
        {error, Reason} -> {error, Reason}
    end.

%% ===== 记忆系统 =====

caseMemoryStore() ->
    %% remember 是 write 级工具：验证脚本以 edit 模式调用（ask 下被策略拒绝是设计行为）
    Content = "验证测试记忆_" ++ integer_to_list(erlang:unique_integer([positive])),
    case alToolCatalog:invoke(remember, #{mode => edit, kind => note,
                                           content => Content, tags => [verification]}) of
        {ok, _} -> ok;
        {error, Reason} -> {error, Reason}
    end.

caseMemoryRecall() ->
    case alToolCatalog:invoke(recall, #{query => "验证测试", limit => 5}) of
        {ok, Result} ->
            Memories = memoryEntries(Result),
            case length(Memories) > 0 of
                true -> ok;
                false -> {fail, "关键词回忆结果为空（可能刚清空）"}
            end;
        {error, Reason} -> {error, Reason}
    end.

caseMemorySemantic() ->
    case alToolCatalog:invoke(recallSemantic, #{query => "测试验证", limit => 5}) of
        {ok, _} ->
            %% 语义搜索可能因未配置 embedding 而返回空，这是预期行为
            ok;
        {error, Reason} -> {error, Reason}
    end.

%% 记忆结果兼容三种形态：裸列表 / #{memories => [...]} / #{results => [...]}。
memoryEntries(List) when is_list(List) -> List;
memoryEntries(Map) when is_map(Map) ->
    maps:get(memories, Map, maps:get(results, Map, maps:get(items, Map, [])));
memoryEntries(_) -> [].

%% ===== 文件读取 =====

caseReadConfig() ->
    %% 读项目根的构建配置（一定存在且非敏感；alicfg.cfg 被 pathDenied 屏蔽）
    case alToolCatalog:invoke(readFile, #{path => "rebar.config"}) of
        {ok, #{content := Content}} when is_binary(Content) ->
            case byte_size(Content) > 0 of
                true -> ok;
                false -> {fail, "文件内容为空"}
            end;
        {error, pathNotAllowed} ->
            %% 亦被敏感名单拦截时，退回读 src 下文件证明 readFile 可用
            caseReadSource();
        {error, Reason} -> {error, Reason}
    end.

caseReadSource() ->
    case alToolCatalog:invoke(readFile, #{path => "src/agent/alServer.erl", maxBytes => 2048}) of
        {ok, #{content := Content}} when is_binary(Content) ->
            case binary:match(Content, <<"alServer">>) of
                nomatch -> {fail, "文件内容不包含 alServer"};
                _ -> ok
            end;
        {error, Reason} -> {error, Reason}
    end.

%% ===== 运行时探针 =====

caseGetRuntime() ->
    case alToolCatalog:invoke(getRuntime, #{}) of
        {ok, Result} when is_map(Result) -> ok;
        {error, Reason} -> {error, Reason}
    end.

caseGetProcesses() ->
    case alToolCatalog:invoke(getProcesses, #{limit => 20}) of
        {ok, Result} ->
            Procs = listOf(Result, processes),
            case length(Procs) > 0 of
                true -> ok;
                false -> {fail, "进程列表为空"}
            end;
        {error, Reason} -> {error, Reason}
    end.

caseGetEts() ->
    case alToolCatalog:invoke(getEts, #{limit => 20}) of
        {ok, Result} ->
            Tables = listOf(Result, tables),
            case length(Tables) > 0 of
                true -> ok;
                false -> {fail, "ETS 表列表为空"}
            end;
        {error, Reason} -> {error, Reason}
    end.

%% 结果兼容两种形态：裸列表 / #{Key => [...]} 包装。
listOf(List, _Key) when is_list(List) -> List;
listOf(Map, Key) when is_map(Map) -> maps:get(Key, Map, []);
listOf(_, _) -> [].

verifyMathTools() ->
    [
        #{
            type => function,
            function => #{
                name => <<"add_numbers">>,
                description => <<"Add two integers and return the sum.">>,
                parameters => #{
                    type => <<"object">>,
                    properties => #{
                        <<"a">> => #{type => <<"integer">>},
                        <<"b">> => #{type => <<"integer">>}
                    },
                    required => [<<"a">>, <<"b">>]
                }
            }
        }
    ].

assertToolCallNamed(Result, Name) when is_map(Result), is_binary(Name) ->
    ToolCalls = maps:get(tool_calls, Result, []),
    case lists:any(fun(Call) -> toolCallName(Call) =:= Name end, ToolCalls) of
        true -> ok;
        false -> {fail, io_lib:format("未看到期望工具调用 ~ts，实际 tool_calls=~p",
                                      [Name, ToolCalls])}
    end;
assertToolCallNamed(Other, _Name) ->
    {fail, io_lib:format("工具调用返回格式异常: ~p", [Other])}.

toolCallName(Call) when is_map(Call) ->
    Function = maps:get(function, Call, maps:get(<<"function">>, Call, #{})),
    maps:get(name, Function, maps:get(<<"name">>, Function, <<>>));
toolCallName(_) ->
    <<>>.

caseSupervisorTree() ->
    case alToolCatalog:invoke(supervisorTree, #{}) of
        {ok, _} -> ok;
        {error, Reason} -> {error, Reason}
    end.

%% ===== 策略安全 =====

casePolicyBlock() ->
    %% 危险命令应被策略拦截
    case alToolCatalog:invoke(runMfa, #{
        module => "os", function => "cmd", args => ["rm -rf /"]
    }) of
        {error, _Reason} -> ok;  %% 被拦截 = 通过
        {ok, _} -> {fail, "危险命令未被策略拦截"}
    end.

casePolicyPath() ->
    %% 路径遍历应被拦截
    case alToolCatalog:invoke(readFile, #{path => "../../../etc/passwd"}) of
        {error, _Reason} -> ok;  %% 被拦截 = 通过
        {ok, _} -> {fail, "路径遍历未被拦截"}
    end.

%% ===== 数据库 =====

caseDbStatus() ->
    case alToolCatalog:invoke(coreStatus, #{}) of
        {ok, _} -> ok;
        {error, _} ->
            %% coreStatus 失败时尝试 dbStatus
            case alCoreClient:dbStatus() of
                {ok, _} -> ok;
                {error, Reason} -> {error, Reason}
            end
    end.

caseDbQuery() ->
    %% 注意：不能传 mode => read——invoke/2 会把 Args 里的 mode 当作
    %% 会话模式（合法值 ask/edit/exec/plan），read 会被判非法而拒绝。
    %% SELECT 语句由 alPolicy:sqlIsReadOnly 自动识别为只读。
    case alToolCatalog:invoke(dbQuery, #{
        sql => "SELECT COUNT(*) as cnt FROM memories",
        params => []
    }) of
        {ok, _} -> ok;
        {error, Reason} -> {error, Reason}
    end.

%% ===== 备份 =====

caseBackupCreate() ->
    %% 备份一个已知存在的源文件（绝对路径，不依赖 shell cwd）
    Target = filename:join(alConfig:root(), "src/agent/alServer.erl"),
    case alBackup:backupFile(Target) of
        {ok, _} -> ok;
        {error, Reason} -> {error, Reason}
    end.

caseBackupList() ->
    %% alBackup:listBackups/1 返回裸列表（[map()]），不是 {ok, List}。
    Target = filename:join(alConfig:root(), "src/agent/alServer.erl"),
    case alBackup:listBackups(Target) of
        List when is_list(List) -> ok;
        Other -> {error, Other}
    end.

%%%===================================================================
%%% 辅助函数
%%%===================================================================

%% 设置标准 I/O 为 Unicode 编码，确保中文字符能正确输出。
setUnicodeIo() ->
    try io:setopts([{encoding, unicode}]) catch _:_ -> ok end,
    ok.

%% 确保应用已启动
ensureStarted() ->
    setUnicodeIo(),
    case application:ensure_all_started(ali) of
        {ok, _} -> ok;
        {error, {already_started, ali}} -> ok;
        {error, Reason} ->
            io:format("启动失败: ~p~n", [Reason]),
            error(Reason)
    end.

runNamedCases(Title, Cases) ->
    ensureStarted(),
    printNamedHeader(Title, length(Cases)),
    {Pass, Fail, TotalMs} = runCases(Cases),
    printFooter(Pass, Fail, TotalMs),
    case Fail of
        0 -> ok;
        N -> {error, {failed, N}}
    end.

%% 运行用例列表
runCases(Cases) ->
    runCases(Cases, 0, 0, 0).

runCases([], Pass, Fail, TotalMs) ->
    {Pass, Fail, TotalMs};
runCases([{Id, Cat, Desc, Timeout, Fun} | Rest], Pass, Fail, TotalMs) ->
    {Result, DurationMs} = timedRun(Fun, Timeout),
    printResult(Id, Cat, Desc, Result, DurationMs),
    {NewPass, NewFail} = case Result of
        ok -> {Pass + 1, Fail};
        _ -> {Pass, Fail + 1}
    end,
    runCases(Rest, NewPass, NewFail, TotalMs + DurationMs).

%% 带超时执行用例
timedRun(Fun, Timeout) ->
    Start = erlang:monotonic_time(millisecond),
    Parent = self(),
    Ref = make_ref(),
    {Pid, MonRef} = spawn_monitor(fun() ->
        Result = try Fun() of
            ok -> ok;
            {fail, _} = F -> F;
            {error, _} = E -> E;
            Other -> {fail, io_lib:format("意外返回: ~p", [Other])}
        catch
            Class:Reason ->
                {error, io_lib:format("~p:~p", [Class, Reason])}
        end,
        Parent ! {done, Ref, Result}
    end),
    receive
        {done, Ref, Result} ->
            %% 消费随后到达的 DOWN，避免残留在调用方邮箱。
            receive
                {'DOWN', MonRef, process, Pid, _} -> ok
            end,
            End = erlang:monotonic_time(millisecond),
            {Result, End - Start};
        {'DOWN', MonRef, process, Pid, Reason} ->
            End = erlang:monotonic_time(millisecond),
            {{error, {crash, Reason}}, End - Start}
    after Timeout ->
        exit(Pid, kill),
        %% 等 DOWN 确认子进程已死；信号顺序保证其此前发出的迟到消息已投递。
        receive
            {'DOWN', MonRef, process, Pid, _} -> ok
        end,
        %% 清理子进程在被 kill 前可能已发出的迟到 {done, Ref, _} 消息。
        receive
            {done, Ref, _} -> ok
        after 0 ->
            ok
        end,
        End = erlang:monotonic_time(millisecond),
        {{error, timeout}, End - Start}
    end.

flushStreamEvents() ->
    receive
        {eStreamChunk, _} -> flushStreamEvents();
        {eStreamReasoning, _} -> flushStreamEvents();
        {eStreamToolDelta, _} -> flushStreamEvents();
        {eStreamUsage, _} -> flushStreamEvents();
        {eStreamDone, _} -> flushStreamEvents();
        {eStreamError, _} -> flushStreamEvents()
    after 0 ->
        ok
    end.

collectStreamResult(Pid, Timeout) when is_pid(Pid) ->
    Mon = erlang:monitor(process, Pid),
    try collectStreamLoop(Mon, #{chunkCount => 0, reasoningCount => 0,
                                 toolDeltaCount => 0, done => false,
                                 content => <<>>}, Timeout)
    after
        erlang:demonitor(Mon, [flush])
    end.

collectStreamLoop(Mon, State, Timeout) ->
    receive
        {eStreamChunk, Chunk} when is_binary(Chunk) ->
            Content0 = maps:get(content, State, <<>>),
            State1 = State#{chunkCount => maps:get(chunkCount, State) + 1,
                            content => <<Content0/binary, Chunk/binary>>},
            collectStreamLoop(Mon, State1, Timeout);
        {eStreamChunk, Chunk} ->
            Bin = toBinary(Chunk),
            Content0 = maps:get(content, State, <<>>),
            State1 = State#{chunkCount => maps:get(chunkCount, State) + 1,
                            content => <<Content0/binary, Bin/binary>>},
            collectStreamLoop(Mon, State1, Timeout);
        {eStreamReasoning, _Chunk} ->
            State1 = State#{reasoningCount => maps:get(reasoningCount, State) + 1},
            collectStreamLoop(Mon, State1, Timeout);
        {eStreamToolDelta, _Delta} ->
            State1 = State#{toolDeltaCount => maps:get(toolDeltaCount, State) + 1},
            collectStreamLoop(Mon, State1, Timeout);
        {eStreamUsage, _Usage} ->
            collectStreamLoop(Mon, State, Timeout);
        {eStreamDone, Final} ->
            FinalBin = toBinary(Final),
            {ok, State#{done => true, content => FinalBin}};
        {eStreamError, Reason} ->
            {error, Reason};
        {'DOWN', Mon, process, _Pid, Reason} ->
            case maps:get(done, State, false) of
                true -> {ok, State};
                false -> {error, {streamDown, Reason, State}}
            end
    after Timeout ->
        {error, {streamWaitTimeout, State}}
    end.

drainQueuedStreamEvents() ->
    drainQueuedStreamEvents([]).

drainQueuedStreamEvents(Acc) ->
    receive
        {eStreamChunk, Chunk} ->
            drainQueuedStreamEvents([{chunk, toBinary(Chunk)} | Acc]);
        {eStreamReasoning, Chunk} ->
            drainQueuedStreamEvents([{reasoning, toBinary(Chunk)} | Acc]);
        {eStreamToolDelta, Delta} ->
            drainQueuedStreamEvents([{toolDelta, Delta} | Acc]);
        {eStreamUsage, Usage} ->
            drainQueuedStreamEvents([{usage, Usage} | Acc]);
        {eStreamDone, Content} ->
            drainQueuedStreamEvents([{done, toBinary(Content)} | Acc]);
        {eStreamError, Reason} ->
            drainQueuedStreamEvents([{error, Reason} | Acc])
    after 50 ->
        lists:reverse(Acc)
    end.

hasToolSignals(Events) ->
    lists:any(fun
        ({toolDelta, _}) -> true;
        ({done, _}) -> true;
        (_) -> false
    end, Events).

verifyStreamSink(Parent, Seen) ->
    receive
        {eStreamChunk, Chunk} ->
            notifyFirstStreamEvent(Parent, Seen),
            _ = Chunk,
            verifyStreamSink(Parent, true);
        {eStreamReasoning, _Chunk} ->
            notifyFirstStreamEvent(Parent, Seen),
            verifyStreamSink(Parent, true);
        {eStreamToolDelta, _Delta} ->
            notifyFirstStreamEvent(Parent, Seen),
            verifyStreamSink(Parent, true);
        {eStreamUsage, _Usage} ->
            notifyFirstStreamEvent(Parent, Seen),
            verifyStreamSink(Parent, true);
        {eStreamDone, Final} ->
            Parent ! {verifySinkDone, self(), toBinary(Final)};
        {eStreamError, Reason} ->
            Parent ! {verifySinkError, self(), Reason}
    end.

notifyFirstStreamEvent(Parent, false) ->
    Parent ! {verifyFirstEvent, self()};
notifyFirstStreamEvent(_Parent, true) ->
    ok.

waitWorkerExit(Mon, Timeout) ->
    receive
        {'DOWN', Mon, process, _Pid, _Reason} -> ok
    after Timeout ->
        {fail, "callerDown 后 worker 未在预期时间内退出"}
    end.

%% 从 alLlmClient:chat/2 返回的结果中提取 content。
%% 本地思考模型（qwen3 类）content 可能为空、正文在 reasoning_content——逐级降级。
extractLlmContent(Result) when is_map(Result) ->
    case pickContent([
        maps:get(content, Result, undefined),
        case maps:get(message, Result, undefined) of
            Msg when is_map(Msg) -> maps:get(content, Msg, undefined);
            _ -> undefined
        end,
        maps:get(reasoning_content, Result, undefined),
        case maps:get(message, Result, undefined) of
            Msg2 when is_map(Msg2) -> maps:get(reasoning_content, Msg2, undefined);
            _ -> undefined
        end
    ]) of
        undefined -> <<>>;
        Bin -> Bin
    end;
extractLlmContent(_) ->
    <<>>.

%% 取第一个非空候选内容（undefined / null / 空串均跳过）
pickContent([undefined | Rest]) -> pickContent(Rest);
pickContent([null | Rest]) -> pickContent(Rest);
pickContent([Candidate | Rest]) ->
    case toBinary(Candidate) of
        <<>> -> pickContent(Rest);
        <<"undefined">> -> pickContent(Rest);
        <<"null">> -> pickContent(Rest);
        Bin -> Bin
    end;
pickContent([]) ->
    undefined.

%% 工具结果可能仍带 data 包装；兼容顶层 hits 与 data.hits / document.functions。
toolHits(Result) when is_map(Result) ->
    case maps:get(hits, Result, undefined) of
        L when is_list(L) -> L;
        _ ->
            Data = maps:get(data, Result, maps:get(<<"data">>, Result, #{})),
            case Data of
                M when is_map(M) -> maps:get(hits, M, maps:get(<<"hits">>, M, []));
                _ -> []
            end
    end;
toolHits(_) -> [].

toolFunctions(Result) when is_map(Result) ->
    case maps:get(functions, Result, maps:get(symbols, Result, undefined)) of
        L when is_list(L), L =/= [] -> L;
        _ ->
            Doc = maps:get(document, Result, maps:get(<<"document">>, Result,
                 maps:get(data, Result, maps:get(<<"data">>, Result, #{})))),
            case Doc of
                M when is_map(M) ->
                    maps:get(functions, M, maps:get(<<"functions">>, M,
                             maps:get(symbols, M, maps:get(<<"symbols">>, M, []))));
                _ -> []
            end
    end;
toolFunctions(_) -> [].

%% 判断值是否非空
isNonEmpty(<<>>) -> false;
isNonEmpty([]) -> false;
isNonEmpty(undefined) -> false;
isNonEmpty(_) -> true.

%% 转为 binary
toBinary(B) when is_binary(B) -> B;
toBinary(L) when is_list(L) -> unicode:characters_to_binary(L);
toBinary(A) when is_atom(A) -> atom_to_binary(A, utf8);
toBinary(Other) -> unicode:characters_to_binary(io_lib:format("~p", [Other])).

trimUpper(V) ->
    string:uppercase(string:trim(toBinary(V), both)).

normalizeLines(V) ->
    [string:trim(Line, both) ||
        Line <- binary:split(toBinary(V), <<"\n">>, [global, trim_all]),
        Line =/= <<>>].

%%%===================================================================
%%% 报告输出
%%%===================================================================

printHeader(Categories, CaseCount) ->
    CatStr = case Categories of
        [all] -> "全部";
        _ -> string:join([atom_to_list(C) || C <- Categories], ", ")
    end,
    io:format("~n=========================================================~n"),
    io:format("  ali 系统功能验证报告~n"),
    io:format("  分类: ~s | 用例数: ~p~n", [CatStr, CaseCount]),
    io:format("=========================================================~n").

printNamedHeader(Title, CaseCount) ->
    io:format("~n=========================================================~n"),
    io:format("  ~ts~n", [Title]),
    io:format("  用例数: ~p~n", [CaseCount]),
    io:format("=========================================================~n").

printResult(Id, Cat, Desc, Result, DurationMs) ->
    CatUpper = string:to_upper(atom_to_list(Cat)),
    IdUpper = string:to_upper(atom_to_list(Id)),
    Status = case Result of
        ok -> "PASS";
        {fail, _} -> "FAIL";
        {error, _} -> "ERROR"
    end,
    Reason = case Result of
        ok -> <<>>;
        {fail, R} -> formatReason(R);
        {error, R} -> formatReason(R)
    end,
    Label = unicode:characters_to_binary(io_lib:format("[~s] ~s: ~ts", [CatUpper, IdUpper, Desc])),
    %% 中文占 2 列：按显示宽度算 padding，点线才能对齐
    Padding = max(0, ?LineLen - displayWidth(Label)),
    io:format("~ts~s~s (~.1fs)~ts~n", [
        Label,
        lists:duplicate(Padding, $.),
        Status,
        DurationMs / 1000,
        Reason
    ]).

%% 终端显示宽度：CJK/全角字符按 2 列计。
displayWidth(Bin) when is_binary(Bin) ->
    Ws = [charWidth(C) || C <- unicode:characters_to_list(Bin, utf8), C =/= $\n],
    lists:sum(Ws);
displayWidth(L) when is_list(L) ->
    displayWidth(unicode:characters_to_binary(L)).

%% 格式化失败原因；非法 UTF-8（HTTP 原始字节等）不得崩掉报告输出。
formatReason(R) ->
    try
        unicode:characters_to_binary(io_lib:format(" - ~ts", [toBinary(R)]))
    catch
        _:_ ->
            %% 降级 ~p（可打印转义形式），仍失败就返回占位
            try unicode:characters_to_binary(io_lib:format(" - ~p", [R]))
            catch _:_ -> <<" - <unreadable>">> end
    end.

charWidth(C) when C >= 16#4E00, C =< 16#9FFF -> 2;  %% CJK 统一表意
charWidth(C) when C >= 16#3000, C =< 16#303F -> 2;  %% CJK 标点
charWidth(C) when C >= 16#FF00, C =< 16#FFEF -> 2;  %% 全角形式
charWidth(C) when C >= 16#2000, C =< 16#206F -> 2;  %% 通用标点（—…等）
charWidth(_) -> 1.

printFooter(Pass, Fail, TotalMs) ->
    Total = Pass + Fail,
    io:format("- - - - - - - - - - - - - - - - - - - - - - - - - - -~n"),
    io:format("  总计: ~p 通过 / ~p 失败 / ~p 用例~n", [Pass, Fail, Total]),
    io:format("  耗时: ~.1fs~n", [TotalMs / 1000]),
    case {Total, Fail} of
        {0, _} -> io:format("  状态: 无用例运行~n");
        {_, 0} -> io:format("  状态: 全部通过~n");
        _ -> io:format("  状态: 有失败用例~n")
    end,
    io:format("=========================================================~n").
