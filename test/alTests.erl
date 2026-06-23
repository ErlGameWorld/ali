%%%-------------------------------------------------------------------
%%% @doc Agent 核心功能 EUnit 测试套件。
%%%
%%% 覆盖工具调用解析、策略检查、项目索引、代码分析、
%%% 会话持久化、进度追踪等模块的基本行为。
%%% @end
%%%-------------------------------------------------------------------
-module(alTests).

-include_lib("eunit/include/eunit.hrl").

%% 验证从 LLM 响应中解析 tool_call XML 标签。
parseToolCalls_test() ->
    Response = <<"<tool_call>{\"id\":\"1\",\"tool\":\"readFile\",\"args\":{\"path\":\"README.md\"}}</tool_call>"/utf8>>,
    [#{tool := <<"readFile"/utf8>>} | _] = alLoop:parseToolCalls(Response).

%% 纯文本回答不应解析出任何 tool_call。
parseToolCallsEmpty_test() ->
    [] = alLoop:parseToolCalls(<<"This is a plain answer"/utf8>>).

%% 默认策略下 readFile 应被允许。
policyReadAllowed_test() ->
    ok = alPolicy:checkTool(readFile, alPolicy:defaultPolicy()).

%% 默认策略下 writeFile 应被拒绝。
policyWriteDenied_test() ->
    {error, denied} = alPolicy:checkTool(writeFile, alPolicy:defaultPolicy()).

%% allowWrite 开启时 writeFile 需用户确认。
policyWriteWithAllow_test() ->
    Policy = (alPolicy:defaultPolicy())#{allowWrite => true},
    {error, confirmationRequired} =
        alPolicy:checkTool(writeFile, Policy, #{mode => edit}).

%% 内置黑名单应拦截 os:cmd/1 与 erlang:halt/0。
blacklistBlocks_test() ->
    false = alToolEval:isAllowed(os, cmd, 1),
    false = alToolEval:isAllowed(erlang, halt, 0),
    false = alToolEval:isAllowed(file, delete, 1),
    false = alToolEval:isAllowed(init, stop, 0).

%% 非黑名单 MFA 应允许执行。
allowedUnlessBlacklisted_test() ->
    true = alToolEval:isAllowed(llmCli, estimateTokens, 1),
    true = alToolEval:isAllowed(alConfig, load, 0),
    true = alToolEval:isAllowed(erlang, memory, 0).

%% callFunction 工具应能执行非黑名单函数。
callFunctionSafe_test() ->
    {ok, #{ok := true, value := 1}} =
        alToolEval:callFunction(
            #{module => llmCli, function => estimateTokens, args => [<<"abcd"/utf8>>]},
            #{}
        ).

%% callFunction 应把 atom 形参从字符串转为 atom（如 ets:info/1）。
callFunction_coerceAtom_test() ->
    Tab = ali_call_fn_test_table,
    catch ets:delete(Tab),
    _ = ets:new(Tab, [named_table, public]),
    try
        {ok, #{ok := true, value := Info}} =
            alToolEval:callFunction(
                #{module => ets, function => info, args => [<<"ali_call_fn_test_table"/utf8>>]},
                #{}
            ),
        ?assert(is_list(Info)),
        {ok, #{ok := true, value := Size}} =
            alToolEval:callFunction(
                #{module => ets, function => info,
                  args => [<<"ali_call_fn_test_table"/utf8>>, <<"size"/utf8>>]},
                #{}
            ),
        ?assert(is_integer(Size))
    after
        catch ets:delete(Tab)
    end.

%% etsTables 应返回 ETS 表列表。
etsTables_test() ->
    {ok, #{count := Count, tables := Tables}} = alToolRuntime:etsTables(#{limit => 5}, #{}),
    ?assert(Count >= 1),
    ?assert(length(Tables) =< 5),
    ?assert(lists:all(fun(#{memory := M}) -> is_integer(M) end, Tables)).

%% projectIndex 应返回至少一个模块。
projectIndex_test() ->
    {ok, #{moduleCount := Count, modules := Modules}} =
        alToolProject:projectIndex(#{}, #{}),
    ?assert(Count >= 1),
    ?assert(lists:any(fun(#{module := llmCli}) -> true;
                          (_) -> false end, Modules)).

%% 路径穿越攻击应被 resolvePathForEdit 拒绝。
pathOutsideProject_test() ->
    Root = filename:absname("."),
    {error, pathOutsideProject} =
        alToolProject:resolvePathForEdit(Root, <<"../../etc/passwd"/utf8>>).

%% listFiles 返回的路径应为合法 UTF-8 二进制。
listFiles_paths_are_utf8_test() ->
    {ok, #{files := Files}} =
        alToolProject:listFiles(#{path => <<"."/utf8>>, pattern => "*.md"}, #{}),
    lists:foreach(fun(F) ->
        ?assert(is_binary(F)),
        ?assertEqual(F, unicode:characters_to_binary(unicode:characters_to_list(F)))
    end, Files).

%% listTools 应包含核心工具名。
listTools_test() ->
    Tools = alTools:listTools(),
    ?assert(lists:member(readFile, Tools)),
    ?assert(lists:member(callFunction, Tools)),
    ?assert(lists:member(remoteNodeInfo, Tools)),
    ?assert(lists:member(getFunctionSource, Tools)),
    ?assert(lists:member(compileLoad, Tools)),
    ?assert(lists:member(getSupTree, Tools)),
    ?assert(lists:member(analyzeCallGraph, Tools)),
    ?assert(lists:member(runEunit, Tools)),
    ?assert(lists:member(generateEunit, Tools)).

%% analyzeCalls 应基于 AST 索引返回调用信息。
astAnalyzeCalls_test() ->
    alCodeIndexer:refresh(#{}),
    {ok, #{engine := ast, callCount := Count}} =
        alToolAnalyze:analyzeCalls(
            #{module => llmCli, function => start},
            #{}),
    ?assert(Count >= 0).

%% findCallers 应能查找函数的调用方。
astFindCallers_test() ->
    alCodeIndexer:refresh(#{}),
    {ok, #{engine := ast}} =
        alToolAnalyze:findCallers(
            #{module => llmCli, function => start},
            #{}).

%% listTestModules 应至少发现一个测试模块。
listTestModules_test() ->
    {ok, #{count := Count}} = alToolTest:listTestModules(#{}, #{}),
    ?assert(Count >= 1).

%% 代码索引 refresh 与 lookup 应正常工作。
codeIndex_test() ->
    {ok, #{moduleCount := Count}} = alCodeIndexer:refresh(#{}),
    ?assert(Count >= 1),
    {ok, Entry} = alCodeIndexer:lookupModule(llmCli),
    ?assert(maps:is_key(exports, Entry)).

%% getFunctionSource 应返回指定函数的源码信息。
getFunctionSource_test() ->
    alCodeIndexer:refresh(#{}),
    {ok, #{module := llmCli}} =
        alToolAnalyze:getFunctionSource(
            #{module => llmCli, function => start},
            #{}).

%% diff 格式化应产生非空输出。
diffFormat_test() ->
    Diff = alDiff:format(<<"a\n"/utf8>>, <<"a\nb\n"/utf8>>),
    ?assert(byte_size(Diff) > 0).

%% ask 模式下写操作应被拒绝，读操作允许。
modePolicy_test() ->
    Policy = alPolicy:defaultPolicy(),
  {error, denied} = alPolicy:checkTool(writeFile, Policy, #{mode => ask}),
    ok = alPolicy:checkTool(readFile, Policy, #{mode => ask}),
    {error, denied} = alPolicy:checkTool(callFunction, Policy, #{mode => ask}).

configCfgBlocked_test() ->
    Root = alToolProject:findProjectRootFromModule(),
    {error, pathBlocked} =
        alToolProject:readFile(#{path => <<"config/aliCfg.cfg">>}, #{projectRoot => Root}).

%% getSupTree 应返回监督树列表。
getSupTree_test() ->
    {ok, #{trees := Trees}} = alToolOtp:getSupTree(#{}, #{}),
    ?assert(is_list(Trees)).

%% 会话 save/load/delete 往返应保持一致。
sessionRoundtrip_test() ->
    SessionId = <<"test-session"/utf8>>,
    Session = #{
        id => SessionId,
        messages => [llmCli:userMessage(<<"hello"/utf8>>)],
        createdAt => 1,
        updatedAt => 2
    },
    ok = alSession:save(SessionId, Session),
    {ok, Loaded} = alSession:load(SessionId),
    ?assertEqual(SessionId, maps:get(id, Loaded)),
    ok = alSession:delete(SessionId).

%% 进度追踪：start/emit/finish/snapshot 生命周期。
progress_snapshot_test() ->
    Id = <<"test-progress"/utf8>>,
    ok = alProgress:start(Id),
    #{status := running, eventCount := 1} = alProgress:snapshot(Id),
    ok = alProgress:emit(Id, #{type => step, message => <<"hi"/utf8>>}),
    #{eventCount := 2} = alProgress:snapshot(Id, 0),
    ok = alProgress:finish(Id, {ok, <<"done"/utf8>>}),
    #{status := completed} = alProgress:snapshot(Id),
    ok = alProgress:drop(Id).

%% 敏感字段（如 apiKey）应被脱敏。
sanitizeSensitive_test() ->
    #{apiKey := <<"***REDACTED***"/utf8>>} =
        alPolicy:sanitizeTerm(#{apiKey => <<"secret-value"/utf8>>}).

%% listTools 应包含新增的 formatCode 与 listBackups 工具。
newToolsRegistered_test() ->
    Tools = alTools:listTools(),
    ?assert(lists:member(formatCode, Tools)),
    ?assert(lists:member(listBackups, Tools)).

%% formatCode 策略应为 write（需确认），listBackups 应为 read（只读）。
newToolsPolicy_test() ->
    ?assertEqual(write, alPolicy:level(formatCode)),
    ?assertEqual(read, alPolicy:level(listBackups)).

%% listBackups 对无备份的文件应返回空列表（只读，不报错）。
listBackups_noBackups_test() ->
    Result = alToolEdit:listBackups(
        #{path => <<"nonexistent_file.erl"/utf8>>}, #{}),
    ?assertMatch({ok, #{count := 0, backups := []}}, Result).

%% listBackups 缺少 path 参数应返回错误。
listBackups_missingPath_test() ->
    ?assertEqual({error, missingPath}, alToolEdit:listBackups(#{}, #{})).

%% formatCode 对不支持的文件类型应返回 unsupportedFileType。
formatCode_nonErlang_test() ->
    {error, unsupportedFileType} =
        alToolEdit:formatCode(#{path => <<"README.md"/utf8>>}, #{}).

%% formatCode 缺少 path 参数应返回 missingPath。
formatCode_missingPath_test() ->
    {error, missingPath} = alToolEdit:formatCode(#{}, #{}).

%% EUnit 渲染：0 元函数应生成调用断言测试。
renderEunit_zeroArity_test() ->
    Bin = alToolTest:render_eunit_test(alTests, {test_fun, 0}),
    ?assert(binary:match(Bin, <<"test_fun_test()">>) =/= nomatch),
    ?assert(binary:match(Bin, <<"alTests:test_fun()">>) =/= nomatch),
    ?assert(binary:match(Bin, <<"?assert">>) =/= nomatch).

%% EUnit 渲染：多元函数应生成 skip 占位测试。
renderEunit_nonZeroArity_test() ->
    Bin = alToolTest:render_eunit_test(alTests, {foo, 2}),
    ?assert(binary:match(Bin, <<"foo_2_test()">>) =/= nomatch),
    ?assert(binary:match(Bin, <<"{skip,">>) =/= nomatch).

%% Common Test 用例名生成应避免非法字符。
ct_case_name_test() ->
    Name = alToolTest:ct_case_name(my_fun, 0),
    ?assert(is_atom(Name)).

%% build_ct_cases 应为每个导出生成用例名。
build_ct_cases_test() ->
    Cases = alToolTest:build_ct_cases([{foo, 0}, {bar, 1}]),
    ?assertEqual(2, length(Cases)).

%%%===================================================================
%%% 优化与新增功能测试
%%%===================================================================

%% listFiles 递归不应包含 _build 等被排除目录下的文件。
listFiles_excludesBuildDir_test() ->
    {ok, #{files := Files}} =
        alToolProject:listFiles(#{path => <<"."/utf8>>, pattern => "*.beam", recursive => true}, #{}),
    NoBuild = lists:all(fun(F) ->
        binary:match(F, <<"_build"/utf8>>) =:= nomatch
            andalso binary:match(F, <<".git"/utf8>>) =:= nomatch
    end, Files),
    ?assert(NoBuild).

%% patchFile 在 oldText 多处匹配且未指定 replaceAll 时应返回 ambiguousMatch。
patchFile_ambiguousMatch_test() ->
    Root = alToolProject:findProjectRootFromModule(),
    Abs = filename:join(Root, "tmp_patch_ambiguous_test.txt"),
    ok = file:write_file(Abs, <<"foo bar foo"/utf8>>),
    Config = #{projectRoot => list_to_binary(Root)},
    Result = alToolEdit:patchFile(
        #{path => <<"tmp_patch_ambiguous_test.txt"/utf8>>,
          oldText => <<"foo"/utf8>>, newText => <<"baz"/utf8>>, backup => false},
        Config),
    file:delete(Abs),
    ?assertMatch({error, #{reason := ambiguousMatch, matchCount := 2}}, Result).

%% patchFile 指定 replaceAll=true 时应全部替换并写回。
patchFile_replaceAll_test() ->
    Root = alToolProject:findProjectRootFromModule(),
    Abs = filename:join(Root, "tmp_patch_replaceall_test.txt"),
    ok = file:write_file(Abs, <<"foo bar foo"/utf8>>),
    Config = #{projectRoot => list_to_binary(Root)},
    Result = alToolEdit:patchFile(
        #{path => <<"tmp_patch_replaceall_test.txt"/utf8>>,
          oldText => <<"foo"/utf8>>, newText => <<"baz"/utf8>>,
          backup => false, replaceAll => true},
        Config),
    {ok, Content} = file:read_file(Abs),
    file:delete(Abs),
    ?assertMatch({ok, #{action := patch, replacements := 2}}, Result),
    ?assertEqual(<<"baz bar baz"/utf8>>, Content).

%% tokenStats 应包含估算费用字段 estimatedCostUsd。
tokenStats_hasCost_test() ->
    Stats = llmCli:tokenStats(),
    ?assert(maps:is_key(estimatedCostUsd, Stats)),
    ?assert(is_number(maps:get(estimatedCostUsd, Stats))).

%% estimateTokens 应区分 ASCII 与宽字符（CJK 每字符约 2/3 token）。
estimateTokens_cjk_test() ->
    ?assert(llmCli:estimateTokens(<<"你好世界"/utf8>>) >= 2),
    ?assert(llmCli:estimateTokens(<<"hello world test"/utf8>>) >= 3),
    ?assertEqual(0, llmCli:estimateTokens(123)).

%% 系统提示词应包含中文回答约定。
systemPrompt_chinese_test() ->
    Prompt = alContext:buildSystemPrompt(#{useNativeTools => false}),
    ?assert(binary:match(Prompt, <<"简体中文"/utf8>>) =/= nomatch).

%% systemPromptExtra 配置应被追加到系统提示词末尾。
systemPrompt_extra_test() ->
    Prompt = alContext:buildSystemPrompt(
        #{useNativeTools => false, systemPromptExtra => <<"MARKER_XYZ_123"/utf8>>}),
    ?assert(binary:match(Prompt, <<"MARKER_XYZ_123"/utf8>>) =/= nomatch).

%% isTransientError 应识别可重试的瞬时错误，拒绝永久错误。
isTransientError_test() ->
    ?assert(alLoop:isTransientError({http_error, 503, <<>>})),
    ?assert(alLoop:isTransientError({http_error, 429})),
    ?assert(alLoop:isTransientError(timeout)),
    ?assert(alLoop:isTransientError(closed)),
    ?assertNot(alLoop:isTransientError(missing_api_key)),
    ?assertNot(alLoop:isTransientError({http_error, 400, <<>>})).

%%%===================================================================
%%% 第二批：诊断 / Git / 插件 / 可观测性 / 历史压缩 / 国产模型
%%%===================================================================

%% 国产模型 provider 预设应存在。
providers_presets_test() ->
    P = alConfig:listProviders(),
    ?assert(lists:member(qwen, P)),
    ?assert(lists:member(kimi, P)),
    ?assert(lists:member(zhipu, P)),
    ?assert(lists:member(ernie, P)),
    ?assert(lists:member(doubao, P)).

%% qwen provider 预设应有 DashScope base_url。
qwenProvider_test() ->
    {ok, #{baseUrl := Url}} = alConfig:getProvider(qwen),
    ?assert(binary:match(Url, <<"dashscope"/utf8>>) =/= nomatch).

%% topProcesses 应按内存返回 Top 进程列表。
topProcesses_test() ->
    {ok, #{metric := memory, top := Top}} =
        alToolRuntime:topProcesses(#{by => <<"memory"/utf8>>, limit => 5}, #{}),
    ?assert(is_list(Top)),
    ?assert(length(Top) =< 5).

%% topProcesses 非法指标应报错。
topProcesses_invalid_test() ->
    ?assertEqual({error, invalidMetric},
        alToolRuntime:topProcesses(#{by => <<"bogus"/utf8>>}, #{})).

%% schedulerInfo 应返回调度器与内存概览。
schedulerInfo_test() ->
    {ok, Info} = alToolRuntime:schedulerInfo(#{}, #{}),
    ?assert(maps:is_key(schedulers, Info)),
    ?assert(maps:is_key(memory, Info)).

%% gitStatus 应返回 2 元组（ok 或 error，取决于 git/仓库是否可用）。
gitStatus_test() ->
    R = alToolGit:gitStatus(#{}, #{}),
    ?assert(element(1, R) =:= ok orelse element(1, R) =:= error).

%% svnStatus 应返回 2 元组（ok 或 error，取决于 svn/工作副本是否可用）。
svnStatus_test() ->
    R = alToolSvn:svnStatus(#{}, #{}),
    ?assert(element(1, R) =:= ok orelse element(1, R) =:= error).

%% svnDiff 非法 revision 应拒绝（防注入）。
svnDiff_invalidRevision_test() ->
    ?assertEqual({error, invalidRevision},
                 alToolSvn:svnDiff(#{revision => <<"1; rm -rf"/utf8>>}, #{})).

%% 自定义工具注册/注销往返。
registerCustomTool_test() ->
    Def = #{name => myCustomTool, description => <<"demo"/utf8>>,
            parameters => <<"{}"/utf8>>, module => lists, function => reverse,
            level => read},
    ok = alTools:registerTool(Def),
    ?assert(lists:member(myCustomTool, alTools:listTools())),
    ?assertEqual(read, alPolicy:level(myCustomTool)),
    ?assertEqual(read, alTools:customToolLevel(myCustomTool)),
    ok = alTools:unregisterTool(myCustomTool),
    ?assertNot(lists:member(myCustomTool, alTools:listTools())).

%% 注册缺字段应报错；覆盖内置工具应被拒绝。
registerToolValidation_test() ->
    ?assertMatch({error, {missingKeys, _}},
        alTools:registerTool(#{name => foo})),
    ?assertEqual({error, builtinConflict},
        alTools:registerTool(#{name => readFile, description => <<"x"/utf8>>,
                               parameters => <<"{}"/utf8>>, module => m, function => f})).

%% 未注册的工具级别缺省为 executeRisky。
customToolDefaultLevel_test() ->
    ?assertEqual(executeRisky, alTools:customToolLevel(neverRegisteredTool)).

%% 审计检索与统计。
auditQueryStats_test() ->
    alAudit:log(<<"qsess"/utf8>>, readFile, #{path => <<"x"/utf8>>}, #{ok => true}),
    Res = alAudit:query(#{sessionId => <<"qsess"/utf8>>}),
    ?assert(lists:any(fun(E) -> maps:get(sessionId, E, undefined) =:= <<"qsess"/utf8>> end, Res)),
    Stats = alAudit:stats(),
    ?assert(maps:is_key(total, Stats)),
    ?assert(maps:is_key(byTool, Stats)).

%% 运行指标记录与快照。
metrics_test() ->
    ok = alMetrics:reset(),
    ok = alMetrics:recordAsk(#{durationMs => 100, ok => true, toolCalls => 2}),
    ok = alMetrics:recordAsk(#{durationMs => 300, ok => false, toolCalls => 1}),
    S = alMetrics:snapshot(),
    ?assertEqual(2, maps:get(askCount, S)),
    ?assertEqual(1, maps:get(okCount, S)),
    ?assertEqual(1, maps:get(errorCount, S)),
    ?assertEqual(3, maps:get(totalToolCalls, S)),
    ?assertEqual(200, maps:get(avgDurationMs, S)).

%% 历史压缩：空历史返回空。
compactHistory_empty_test() ->
    ?assertEqual([], alContext:compactHistory([])).

%% 历史压缩：被裁剪历史应生成中文摘要 system 消息。
compactHistory_summary_test() ->
    Dropped = [
        #{role => user, content => <<"hi"/utf8>>},
        #{role => tool, content => <<"result"/utf8>>},
        #{role => assistant, content => <<"分析完成"/utf8>>}
    ],
    [Msg] = alContext:compactHistory(Dropped),
    ?assertEqual(system, maps:get(role, Msg)),
    ?assert(binary:match(maps:get(content, Msg), <<"历史摘要"/utf8>>) =/= nomatch).

%% buildMessages 在历史超出 maxMessages 时应注入摘要 system 消息。
buildMessages_compaction_test() ->
    History = [#{role => user, content => integer_to_binary(N)} || N <- lists:seq(1, 10)],
    Config = #{maxMessages => 3, historyCompaction => true, useNativeTools => false},
    Msgs = alContext:buildMessages(Config, History, <<"now"/utf8>>),
    HasSummary = lists:any(fun(M) ->
        maps:get(role, M, undefined) =:= system
            andalso is_binary(maps:get(content, M, undefined))
            andalso binary:match(maps:get(content, M), <<"历史摘要"/utf8>>) =/= nomatch
    end, Msgs),
    ?assert(HasSummary).

%% 孤立 tool 消息应被移除。
sanitizeToolHistory_test() ->
    OrphanMid = [
        #{role => user, content => <<"u1"/utf8>>},
        #{role => assistant, content => <<"a1"/utf8>>},
        #{role => tool, tool_call_id => <<"1"/utf8>>, content => <<"r1"/utf8>>},
        #{role => user, content => <<"u2"/utf8>>}
    ],
    [U1, A1, U2] = alContext:sanitizeToolHistory(OrphanMid),
    ?assertEqual(user, maps:get(role, U1)),
    ?assertEqual(assistant, maps:get(role, A1)),
    ?assertEqual(user, maps:get(role, U2)).

%% 末尾 assistant+tool_calls 无 tool 回复时应整组移除。
sanitizeToolHistory_incompleteAssistant_test() ->
    Call = #{
        <<"id"/utf8>> => <<"call_00_hpDssE9kl1qFH0BBhyM60858"/utf8>>,
        <<"type"/utf8>> => <<"function"/utf8>>,
        <<"function"/utf8>> => #{<<"name"/utf8>> => <<"patchFile"/utf8>>, <<"arguments"/utf8>> => <<"{}"/utf8>>}
    },
    History = [
        #{role => user, content => <<"u1"/utf8>>},
        #{role => assistant, tool_calls => [Call], content => null},
        #{role => user, content => <<"u2"/utf8>>}
    ],
    [U1, U2] = alContext:sanitizeToolHistory(History),
    ?assertEqual(user, maps:get(role, U1)),
    ?assertEqual(user, maps:get(role, U2)).

%% 多个 tool_calls 仅部分有 tool 回复时应整组移除。
sanitizeToolHistory_partialTools_test() ->
    C1 = #{<<"id"/utf8>> => <<"c1"/utf8>>, <<"type"/utf8>> => <<"function"/utf8>>,
           <<"function"/utf8>> => #{<<"name"/utf8>> => <<"readFile"/utf8>>, <<"arguments"/utf8>> => <<"{}"/utf8>>}},
    C2 = #{<<"id"/utf8>> => <<"c2"/utf8>>, <<"type"/utf8>> => <<"function"/utf8>>,
           <<"function"/utf8>> => #{<<"name"/utf8>> => <<"readFile"/utf8>>, <<"arguments"/utf8>> => <<"{}"/utf8>>}},
    History = [
        #{role => assistant, tool_calls => [C1, C2], content => null},
        #{role => tool, tool_call_id => <<"c1"/utf8>>, content => <<"ok"/utf8>>}
    ],
    ?assertEqual([], alContext:sanitizeToolHistory(History)).

%% buildMessages 不应向 API 发送不完整的 tool_calls 历史。
buildMessages_sanitizeIncompleteTools_test() ->
    Call = #{
        <<"id"/utf8>> => <<"call_x"/utf8>>,
        <<"type"/utf8>> => <<"function"/utf8>>,
        <<"function"/utf8>> => #{<<"name"/utf8>> => <<"patchFile"/utf8>>, <<"arguments"/utf8>> => <<"{}"/utf8>>}
    },
    History = [
        #{role => assistant, tool_calls => [Call], content => null}
    ],
    Config = #{useNativeTools => false, historyCompaction => false},
    Msgs = alContext:buildMessages(Config, History, <<"now"/utf8>>),
    HasBadAssistant = lists:any(fun(M) ->
        maps:get(role, M, undefined) =:= assistant
            andalso maps:get(tool_calls, M, []) =/= []
    end, Msgs),
    ?assertNot(HasBadAssistant).

%% 新增工具应已注册。
newDiagnosticTools_test() ->
    Tools = alTools:listTools(),
    ?assert(lists:member(topProcesses, Tools)),
    ?assert(lists:member(schedulerInfo, Tools)),
    ?assert(lists:member(etsTables, Tools)),
    ?assert(lists:member(gitStatus, Tools)),
    ?assert(lists:member(svnStatus, Tools)),
    ?assert(lists:member(gitDiff, Tools)),
    ?assert(lists:member(searchCode, Tools)),
    ?assert(lists:member(planSet, Tools)),
    ?assert(lists:member(planGet, Tools)).

%%%===================================================================
%%% 第三批：代码 RAG 检索 + 任务规划
%%%===================================================================

%% 分词应感知 camelCase / snake_case 并剔除停用词。
rag_tokenize_test() ->
    Tokens = alRag:tokenize(<<"getUserName and parse_module_attr"/utf8>>),
    ?assert(lists:member(<<"get"/utf8>>, Tokens)),
    ?assert(lists:member(<<"user"/utf8>>, Tokens)),
    ?assert(lists:member(<<"name"/utf8>>, Tokens)),
    ?assert(lists:member(<<"parse"/utf8>>, Tokens)),
    ?assert(lists:member(<<"module"/utf8>>, Tokens)),
    ?assertNot(lists:member(<<"and"/utf8>>, Tokens)).

%% RAG 索引应能从代码库构建出若干 chunk。
rag_index_test() ->
    {ok, #{chunks := N}} = alRag:index(#{}),
    ?assert(N > 0),
    #{chunks := M} = alRag:stats(),
    ?assertEqual(N, M).

%% RAG 检索应返回结构化结果，且与查询相关的函数排名靠前。
rag_search_test() ->
    {ok, _} = alRag:index(#{}),
    {ok, Results} = alRag:search(<<"transient error retry"/utf8>>, #{limit => 5}, #{}),
    ?assert(is_list(Results)),
    ?assert(length(Results) =< 5),
    case Results of
        [] -> ok;
        [Top | _] ->
            ?assert(maps:is_key(module, Top)),
            ?assert(maps:is_key(score, Top)),
            ?assert(maps:is_key(snippet, Top)),
            ?assert(maps:get(score, Top) > 0)
    end.

%% searchCode 工具：缺 query 报错；正常返回结果集合。
searchCodeTool_test() ->
    ?assertEqual({error, missingQuery}, alToolAnalyze:searchCode(#{}, #{})),
    {ok, Res} = alToolAnalyze:searchCode(#{query => <<"policy check tool"/utf8>>, limit => 3}, #{}),
    ?assert(maps:is_key(results, Res)),
    ?assert(maps:get(count, Res) =< 3).

%% semanticSearch 工具：缺 query 报错；无 embedding 时降级为 tfidf 模式。
semanticSearchTool_test() ->
    ?assertEqual({error, missingQuery}, alToolAnalyze:semanticSearch(#{}, #{})),
    {ok, _} = alRag:index(#{}),
    {ok, Res} = alToolAnalyze:semanticSearch(#{query => <<"policy check tool"/utf8>>, limit => 3}, #{}),
    ?assert(maps:is_key(results, Res)),
    ?assert(maps:is_key(mode, Res)),
    ?assert(lists:member(maps:get(mode, Res), [tfidf, hybrid])).

%% alEmbedding 余弦相似度：相同向量得 1，正交向量得 0。
embedding_cosine_test() ->
    ?assertEqual(0.0, alEmbedding:cosine([], [])),
    ?assertEqual(0.0, alEmbedding:cosine([], [1.0])),
    %% 相同向量相似度为 1（允许浮点误差）
    Same = alEmbedding:cosine([1.0, 2.0, 3.0], [1.0, 2.0, 3.0]),
    ?assert(abs(Same - 1.0) < 1.0e-9),
    %% 正交向量相似度为 0
    Ortho = alEmbedding:cosine([1.0, 0.0], [0.0, 1.0]),
    ?assert(abs(Ortho) < 1.0e-9),
    %% 零向量相似度为 0
    ?assertEqual(0.0, alEmbedding:cosine([0.0, 0.0], [1.0, 2.0])).

%% alEmbedding 向量存储与检索：存入后能按相似度召回。
embedding_store_search_test() ->
    alEmbedding:reset(),
    ok = alEmbedding:store(<<"a">>, [1.0, 0.0], #{name => <<"a"/utf8>>}),
    ok = alEmbedding:store(<<"b">>, [0.9, 0.1], #{name => <<"b"/utf8>>}),
    ok = alEmbedding:store(<<"c">>, [1.0, 1.0], #{name => <<"c"/utf8>>}),
    %% 查询向量 [1,0] 应最匹配 "a"（正交向量被过滤，返回非零相似度的项）
    Hits = alEmbedding:search([1.0, 0.0], 3),
    ?assert(length(Hits) >= 1),
    {TopScore, TopId, _Meta} = hd(Hits),
    ?assertEqual(<<"a">>, TopId),
    ?assert(TopScore > 0.99),
    %% lookup 能取回向量与元数据
    {ok, {Vec, Meta}} = alEmbedding:lookup(<<"a">>),
    ?assertEqual([1.0, 0.0], Vec),
    ?assertEqual(<<"a"/utf8>>, maps:get(name, Meta)),
    alEmbedding:reset().

%% alEmbedding 缓存：相同输入不重复调用 embedder。
embedding_cache_test() ->
    alEmbedding:reset(),
    %% 注入计数 embedder（处理单条与批量两种调用形态）
    Counter = spawn_counter(),
    Embedder = fun(Input, _Opts) ->
        Counter ! {inc, self()},
        receive {ack, N} -> {ok, mock_vector_for(Input, N)} end
    end,
    ok = alEmbedding:setEmbedder(Embedder),
    %% 第一次调用：embedder 被调用
    {ok, V1} = alEmbedding:embed(<<"hello"/utf8>>),
    ?assert(is_list(V1)),
    %% 第二次调用相同文本：应命中缓存，embedder 不再被调用
    {ok, V2} = alEmbedding:embed(<<"hello"/utf8>>),
    ?assertEqual(V1, V2),
    %% 清理
    Counter ! stop,
    alEmbedding:reset().

%% alEmbedding 批量嵌入：返回向量顺序与输入一致，缓存命中不重复请求。
embedding_batch_test() ->
    alEmbedding:reset(),
    CallCount = spawn_counter(),
    Embedder = fun(Input, _Opts) ->
        CallCount ! {inc, self()},
        receive {ack, N} -> {ok, mock_vector_for(Input, N)} end
    end,
    ok = alEmbedding:setEmbedder(Embedder),
    %% 先缓存第一条（单条调用走 embed/2）
    {ok, _} = alEmbedding:embed(<<"a"/utf8>>),
    %% 批量：第一条命中缓存，第二、三条新请求
    {ok, Vecs} = alEmbedding:embedBatch([<<"a"/utf8>>, <<"b"/utf8>>, <<"c"/utf8>>], #{}),
    ?assertEqual(3, length(Vecs)),
    %% 再次批量相同输入：应全部命中缓存
    {ok, Vecs2} = alEmbedding:embedBatch([<<"a"/utf8>>, <<"b"/utf8>>, <<"c"/utf8>>], #{}),
    ?assertEqual(Vecs, Vecs2),
    CallCount ! stop,
    alEmbedding:reset().

%% alRag 混合检索：注入 mock embedder 后能跑通 hybrid 模式。
rag_hybrid_search_test() ->
    alEmbedding:reset(),
    %% 注入确定性 embedder：把文本哈希为低维向量
    Embedder = fun(Input, _Opts) ->
        {ok, mock_vector_for(Input, 0)}
    end,
    ok = alEmbedding:setEmbedder(Embedder),
    %% 强制 hybrid 模式
    ok = alKvsToBeam:load(aliCfg, [{ragMode, hybrid}], undefined),
    %% 重建索引（会触发批量 embedding）
    {ok, #{chunks := N}} = alRag:index(#{}),
    ?assert(N > 0),
    %% 混合检索应返回结果
    {ok, Results} = alRag:searchHybrid(<<"error retry"/utf8>>, #{limit => 3}, #{}),
    ?assert(is_list(Results)),
    ?assert(length(Results) =< 3),
    %% 还原配置
    ok = alConfig:load("config/aliCfg.example.cfg"),
    alEmbedding:reset().

%% alRag 模式：默认 auto，无 API key 时降级为 tfidf。
rag_mode_test() ->
    ok = alConfig:load("config/aliCfg.example.cfg"),
    ok = alKvsToBeam:load(aliCfg, [{api_key, <<>>}, {ragMode, auto}], undefined),
    ?assertEqual(tfidf, alRag:mode()),
    ok = alKvsToBeam:load(aliCfg, [{ragMode, hybrid}], undefined),
    ?assertEqual(hybrid, alRag:mode()),
    ok = alKvsToBeam:load(aliCfg, [{ragMode, tfidf}], undefined),
    ?assertEqual(tfidf, alRag:mode()),
    ok = alConfig:load("config/aliCfg.example.cfg").

%% alRerank：默认 reranker 对函数名命中的候选打分更高。
rerank_funcNameBoost_test() ->
    alRerank:reset(),
    C1 = #{module => alRag, function => search, arity => 2, file => <<"src/alRag.erl"/utf8>>,
           lineStart => 1, lineEnd => 10, score => 0.5, snippet => <<>>, text => <<"search query"/utf8>>},
    C2 = #{module => alRag, function => tokenize, arity => 1, file => <<"src/alRag.erl"/utf8>>,
           lineStart => 1, lineEnd => 10, score => 0.5, snippet => <<>>, text => <<"tokenize text"/utf8>>},
    %% 查询 "search" 应让 C1 排在 C2 前面（函数名命中）
    Sorted = alRerank:rerank(<<"search"/utf8>>, [C2, C1], #{}),
    ?assertEqual(search, maps:get(function, hd(Sorted))),
    alRerank:reset().

%% alRerank：注入自定义 reranker 可覆盖默认排序。
rerank_injectReranker_test() ->
    %% 注入：始终返回固定分数，使列表逆序
    Reranker = fun(_Q, C) -> -maps:get(arity, C, 0) end,
    ok = alRerank:setReranker(Reranker),
    C1 = #{module => m, function => f, arity => 1, file => <<"a"/utf8>>,
           lineStart => 1, lineEnd => 1, score => 0.9, snippet => <<>>, text => <<>>},
    C2 = #{module => m, function => g, arity => 2, file => <<"a"/utf8>>,
           lineStart => 1, lineEnd => 1, score => 0.1, snippet => <<>>, text => <<>>},
    Sorted = alRerank:rerank(<<"x"/utf8>>, [C1, C2], #{}),
    %% arity 小的分数更高（-1 > -2），C1 应排前
    ?assertEqual(f, maps:get(function, hd(Sorted))),
    alRerank:reset().

%% alRerank：keepTop 截断。
rerank_keepTop_test() ->
    alRerank:reset(),
    Cs = [#{module => m, function => F, arity => 0, file => <<"a"/utf8>>,
            lineStart => 1, lineEnd => 1, score => 0.5, snippet => <<>>, text => <<>>}
          || F <- [a, b, c, d, e]],
    Sorted = alRerank:rerank(<<"a"/utf8>>, Cs, #{keepTop => 2}),
    ?assertEqual(2, length(Sorted)),
    alRerank:reset().

%% alRag 增量索引：连续两次 index，第二次应跳过重建。
rag_incrementalIndex_test() ->
    alRerank:reset(),
    alEmbedding:reset(),
    %% 确保无 API key，避免触发真实 embedding API 调用
    ok = alKvsToBeam:load(aliCfg, [{api_key, <<>>}, {ragMode, tfidf}], undefined),
    alRag:clear(),
    %% 确保 alCodeIndexer 有最新索引（含 mtime 字段）
    alCodeIndexer:ensureStarted(),
    alCodeIndexer:refresh(#{}),
    %% 第一次：全量重建
    {ok, #{chunks := N1, skipped := Skip1}} = alRag:index(#{}),
    ?assert(N1 > 0),
    ?assertNot(Skip1),
    %% 第二次：mtime 未变，应跳过
    {ok, #{chunks := N2, skipped := Skip2}} = alRag:index(#{}),
    ?assertEqual(N1, N2),
    ?assert(Skip2),
    alRag:clear(),
    alEmbedding:reset(),
    ok = alConfig:load("config/aliCfg.example.cfg").

%% llmCli embeddings URL 与默认模型。
embedding_default_model_test() ->
    ?assertEqual(<<"text-embedding-3-small"/utf8>>, llmCli:defaultEmbeddingModel(openai)),
    ?assertEqual(<<"text-embedding-v3"/utf8>>, llmCli:defaultEmbeddingModel(qwen)),
    ?assertEqual(<<"text-embedding-3-small"/utf8>>, llmCli:defaultEmbeddingModel(unknown_provider)).

%% llmCli embeddings 响应解析：单条与多条。
embedding_parse_response_test() ->
    Single = #{<<"data"/utf8>> => [#{<<"embedding"/utf8>> => [0.1, 0.2, 0.3]}]},
    {ok, [0.1, 0.2, 0.3]} = llmCli:parseEmbeddingsResponse(Single, false),
    Multi = #{<<"data"/utf8>> => [
        #{<<"embedding"/utf8>> => [1.0]},
        #{<<"embedding"/utf8>> => [2.0]}
    ]},
    {ok, [[1.0], [2.0]]} = llmCli:parseEmbeddingsResponse(Multi, true),
    {error, invalid_response} = llmCli:parseEmbeddingsResponse(#{}, false).

%% 辅助：生成 mock 计数器进程。
spawn_counter() ->
    spawn(fun() -> counter_loop(0) end).

counter_loop(N) ->
    receive
        {inc, From} ->
            From ! {ack, N + 1},
            counter_loop(N + 1);
        stop ->
            ok
    end.

%% 辅助：为文本生成确定性 mock 向量（3 维，基于哈希）。
%% 支持单条 binary 与批量 list 两种输入形态。
mock_vector_for(Input, Salt) when is_binary(Input) ->
    H = erlang:phash2({Input, Salt}),
    [(H rem 7) * 1.0, ((H div 7) rem 7) * 1.0, ((H div 49) rem 7) * 1.0];
mock_vector_for(Inputs, Salt) when is_list(Inputs) ->
    [mock_vector_for(I, Salt) || I <- Inputs].

%% 规划：设置清单并自动编号。
plan_set_test() ->
    Sid = <<"plan_test_set"/utf8>>,
    Plan = alPlan:setPlan(Sid, [<<"步骤一"/utf8>>, <<"步骤二"/utf8>>, <<"步骤三"/utf8>>]),
    Steps = maps:get(steps, Plan),
    ?assertEqual(3, length(Steps)),
    ?assertEqual(1, maps:get(id, hd(Steps))),
    ?assertEqual(pending, maps:get(status, hd(Steps))),
    alPlan:clear(Sid).

%% 规划：更新步骤状态。
plan_update_test() ->
    Sid = <<"plan_test_update"/utf8>>,
    alPlan:setPlan(Sid, [<<"a"/utf8>>, <<"b"/utf8>>]),
    {ok, Plan} = alPlan:updateStep(Sid, 1, #{status => done, note => <<"完成"/utf8>>}),
    [S1 | _] = maps:get(steps, Plan),
    ?assertEqual(done, maps:get(status, S1)),
    ?assertEqual(<<"完成"/utf8>>, maps:get(note, S1)),
    ?assertEqual({error, stepNotFound}, alPlan:updateStep(Sid, 99, #{status => done})),
    alPlan:clear(Sid).

%% 规划工具：经 Config.sessionId 作用域，含进度摘要。
plan_tools_test() ->
    Config = #{sessionId => <<"plan_test_tools"/utf8>>},
    {ok, P1} = alPlan:planSet(#{steps => [<<"x"/utf8>>, <<"y"/utf8>>]}, Config),
    ?assertEqual(#{done => 0, total => 2}, maps:get(summary, P1)),
    {ok, P2} = alPlan:planUpdate(#{id => 1, status => <<"done"/utf8>>}, Config),
    ?assertEqual(#{done => 1, total => 2}, maps:get(summary, P2)),
    {ok, P3} = alPlan:planGet(#{}, Config),
    ?assertEqual(2, length(maps:get(steps, P3))),
    ?assertEqual({error, missingSteps}, alPlan:planSet(#{}, Config)),
    alPlan:clear(<<"plan_test_tools"/utf8>>).

%% 系统提示词应包含规划与检索引导。
systemPrompt_planRule_test() ->
    Prompt = alContext:buildSystemPrompt(#{useNativeTools => true}),
    ?assert(binary:match(Prompt, <<"planSet"/utf8>>) =/= nomatch),
    ?assert(binary:match(Prompt, <<"searchCode"/utf8>>) =/= nomatch).

%%%===================================================================
%%% 第四批：Web UI 升级（WebSocket + 可视化 diff）
%%%===================================================================

%% previewPatch 应返回 diff 文本，供前端可视化确认。
previewPatch_diff_test() ->
    Root = alToolProject:findProjectRootFromModule(),
    Abs = filename:join(Root, "tmp_preview_diff_test.txt"),
    ok = file:write_file(Abs, <<"hello world"/utf8>>),
    Config = #{projectRoot => list_to_binary(Root)},
    {ok, R} = alToolEdit:previewPatch(
        #{path => <<"tmp_preview_diff_test.txt"/utf8>>,
          oldText => <<"world"/utf8>>, newText => <<"erlang"/utf8>>}, Config),
    file:delete(Abs),
    ?assertEqual(patch, maps:get(action, R)),
    ?assert(maps:is_key(diff, R)),
    ?assert(is_binary(maps:get(diff, R))).

%% Web 处理器应导出 HTTP 与 WebSocket 回调。
webHandler_callbacks_test() ->
    _ = code:ensure_loaded(alWebHer),
    ?assert(erlang:function_exported(alWebHer, handle, 3)),
    ?assert(erlang:function_exported(alWebHer, handleWs, 3)).

%%%===================================================================
%%% 第五批：MCP（Model Context Protocol）客户端
%%%===================================================================

%% JSON-RPC 请求编码：含 jsonrpc/id/method，并以换行结尾。
mcp_encodeRpc_test() ->
    Bin = alMcp:encodeRpc(7, <<"tools/list"/utf8>>, #{}),
    ?assertEqual($\n, binary:last(Bin)),
    Decoded = llmJson:decode(Bin),
    ?assertEqual(7, maps:get(<<"id"/utf8>>, Decoded)),
    ?assertEqual(<<"2.0"/utf8>>, maps:get(<<"jsonrpc"/utf8>>, Decoded)),
    ?assertEqual(<<"tools/list"/utf8>>, maps:get(<<"method"/utf8>>, Decoded)).

%% 通知无 id。
mcp_encodeNotification_test() ->
    Bin = alMcp:encodeNotification(<<"notifications/initialized"/utf8>>, #{}),
    Decoded = llmJson:decode(Bin),
    ?assertNot(maps:is_key(<<"id"/utf8>>, Decoded)),
    ?assertEqual(<<"notifications/initialized"/utf8>>, maps:get(<<"method"/utf8>>, Decoded)).

%% 缓冲区按换行切分出完整消息，保留不完整的尾部。
mcp_splitMessages_test() ->
    Buf = <<"{\"id\":1}\n{\"id\":2}\n{\"id\":3,\"x"/utf8>>,
    {Msgs, Rest} = alMcp:splitMessages(Buf),
    ?assertEqual(2, length(Msgs)),
    ?assertEqual(1, maps:get(<<"id"/utf8>>, hd(Msgs))),
    ?assertEqual(<<"{\"id\":3,\"x"/utf8>>, Rest).

%% camelKey 单词键应保持不变（与 alLoop 归一化一致）。
mcp_camelKey_test() ->
    ?assertEqual(path, alMcp:camelKey(<<"path"/utf8>>)),
    ?assertEqual(query, alMcp:camelKey(<<"query"/utf8>>)),
    %% 多段键映射须确定且可逆（同一输入恒等）。
    ?assertEqual(alMcp:camelKey(<<"file_path"/utf8>>), alMcp:camelKey(<<"file_path"/utf8>>)).

%% buildToolDef 生成稳定（无下划线）的工具名与正确的注册定义。
mcp_buildToolDef_test() ->
    ToolJson = #{
        <<"name"/utf8>> => <<"read_file"/utf8>>,
        <<"description"/utf8>> => <<"Read a file"/utf8>>,
        <<"inputSchema"/utf8>> => #{
            <<"type"/utf8>> => <<"object"/utf8>>,
            <<"properties"/utf8>> => #{<<"path"/utf8>> => #{<<"type"/utf8>> => <<"string"/utf8>>}}
        }
    },
    {ok, Atom, Def, Props, Remote} = alMcp:buildToolDef(filesystem, ToolJson, read),
    ?assertEqual(<<"read_file"/utf8>>, Remote),
    ?assertEqual(read, maps:get(level, Def)),
    ?assertEqual(alMcp, maps:get(module, Def)),
    ?assertEqual(callTool, maps:get(function, Def)),
    ?assert(maps:is_key(<<"path"/utf8>>, Props)),
    ?assertEqual(nomatch, binary:match(atom_to_binary(Atom, utf8), <<"_"/utf8>>)).

%% restoreArgs 把 alLoop 归一化后的 camelCase 键还原为 schema 原始属性名。
mcp_restoreArgs_test() ->
    Props = #{
        <<"file_path"/utf8>> => #{<<"type"/utf8>> => <<"string"/utf8>>},
        <<"max"/utf8>> => #{<<"type"/utf8>> => <<"integer"/utf8>>}
    },
    %% 用 camelKey 构造键，模拟 alLoop 归一化输出，确保与 restoreArgs 逻辑一致。
    Args = #{alMcp:camelKey(<<"file_path"/utf8>>) => <<"/a/b"/utf8>>, max => 5},
    Restored = alMcp:restoreArgs(Args, Props),
    ?assertEqual(<<"/a/b"/utf8>>, maps:get(<<"file_path"/utf8>>, Restored)),
    ?assertEqual(5, maps:get(<<"max"/utf8>>, Restored)).

%% schema 未声明的多余键应原样透传。
mcp_restoreArgs_extra_test() ->
    Restored = alMcp:restoreArgs(#{extraKey => <<"v"/utf8>>}, #{}),
    ?assertEqual(<<"v"/utf8>>, maps:get(<<"extraKey"/utf8>>, Restored)).

%%%===================================================================
%%% 第八批：Web 安全加固（P0-5）
%%%===================================================================

%% CORS：默认不放行跨源；通配；单来源；来源列表。
web_cors_default_test() ->
    ?assertEqual([], alWebSec:corsHeaders(<<"http://evil.com"/utf8>>, <<>>)).

web_cors_wildcard_test() ->
    H = alWebSec:corsHeaders(<<"http://x"/utf8>>, <<"*"/utf8>>),
    ?assertEqual(<<"*"/utf8>>, proplists:get_value(<<"Access-Control-Allow-Origin"/utf8>>, H)).

web_cors_single_test() ->
    Allow = <<"http://localhost:3000"/utf8>>,
    H1 = alWebSec:corsHeaders(Allow, Allow),
    ?assertEqual(Allow, proplists:get_value(<<"Access-Control-Allow-Origin"/utf8>>, H1)),
    ?assertEqual([], alWebSec:corsHeaders(<<"http://evil.com"/utf8>>, Allow)).

web_cors_list_test() ->
    Allow = [<<"http://a"/utf8>>, <<"http://b"/utf8>>],
    H = alWebSec:corsHeaders(<<"http://b"/utf8>>, Allow),
    ?assertEqual(<<"http://b"/utf8>>, proplists:get_value(<<"Access-Control-Allow-Origin"/utf8>>, H)),
    ?assertEqual([], alWebSec:corsHeaders(<<"http://c"/utf8>>, Allow)).

%% 常数时间比较：相等、不等、不同长度。
web_constantEq_test() ->
    ?assert(alWebSec:constantEq(<<"secret"/utf8>>, <<"secret"/utf8>>)),
    ?assertNot(alWebSec:constantEq(<<"secret"/utf8>>, <<"secreT"/utf8>>)),
    ?assertNot(alWebSec:constantEq(<<"secret"/utf8>>, <<"longersecret"/utf8>>)).

%% 写方法与回环地址判定。
web_isWrite_test() ->
    ?assert(alWebSec:isWrite('POST')),
    ?assert(alWebSec:isWrite('DELETE')),
    ?assertNot(alWebSec:isWrite('GET')),
    ?assert(alWebSec:isWrite(<<"post"/utf8>>)),
    ?assert(alWebSec:isSideEffectPath(<<"/api/ask/stream">>)),
    ?assert(alWebSec:isProtectedPath('GET', <<"/api/ask/stream">>)).

web_isLoopback_test() ->
    ?assert(alWebSec:isLoopback({127, 0, 0, 1})),
    ?assert(alWebSec:isLoopback({0, 0, 0, 0, 0, 0, 0, 1})),
    ?assertNot(alWebSec:isLoopback({10, 0, 0, 5})),
    ?assertNot(alWebSec:isLoopback(undefined)).

%% 鉴权决策：未配置 token 时读放行、远程写拒绝、回环写放行。
web_auth_notoken_test() ->
    ?assertEqual(ok, alWebHer:authDecision(false, <<>>, undefined, {10, 0, 0, 1})),
    ?assertEqual({error, unauthorized},
                 alWebHer:authDecision(true, <<>>, undefined, {10, 0, 0, 1})),
    ?assertEqual(ok, alWebHer:authDecision(true, <<>>, undefined, {127, 0, 0, 1})).

%% 鉴权决策：配置 token 时必须提供匹配 token。
web_auth_token_test() ->
    Token = <<"s3cr3t"/utf8>>,
    ?assertEqual(ok, alWebHer:authDecision(true, Token, <<"s3cr3t"/utf8>>, {10, 0, 0, 1})),
    ?assertEqual({error, unauthorized},
                 alWebHer:authDecision(true, Token, <<"wrong"/utf8>>, {127, 0, 0, 1})),
    ?assertEqual({error, unauthorized},
                 alWebHer:authDecision(false, Token, undefined, {127, 0, 0, 1})).

%% 速率限制：超过窗口内上限后拒绝。
web_rateLimit_test() ->
    ok = alKvsToBeam:load(aliCfg, [{webRateLimit, 3}, {webRateWindowMs, 60000}], undefined),
    alWebSec:resetRate(),
    Ip = {203, 0, 113, 7},
    ?assertEqual(ok, alWebSec:checkRate(Ip)),
    ?assertEqual(ok, alWebSec:checkRate(Ip)),
    ?assertEqual(ok, alWebSec:checkRate(Ip)),
    ?assertEqual({error, rate_limited}, alWebSec:checkRate(Ip)),
    ?assertEqual(ok, alWebSec:checkRate(undefined)),
    alWebSec:resetRate(),
    ok = alConfig:load("config/aliCfg.example.cfg").

%% SSE 解析：从 text/event-stream 响应体提取 JSON-RPC 消息。
mcp_parseSse_test() ->
    Body = <<"event: message\n"
             "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}\n"
             "\n"/utf8>>,
    [Msg] = alMcp:parseSse(Body),
    ?assertEqual(1, maps:get(<<"id"/utf8>>, Msg)),
    ?assertEqual(true, maps:get(<<"ok"/utf8>>, maps:get(<<"result"/utf8>>, Msg))).

%% SSE 解析：多行 data 拼接 + CRLF + 多事件。
mcp_parseSse_multi_test() ->
    Body = <<"data: {\"a\":1}\r\n\r\ndata: {\"b\":2}\r\n\r\n"/utf8>>,
    Msgs = alMcp:parseSse(Body),
    ?assertEqual(2, length(Msgs)),
    ?assertEqual(1, maps:get(<<"a"/utf8>>, hd(Msgs))).

%% decodeHttpMessages：依 content-type 选择 SSE 或 JSON 解析（大小写不敏感）。
mcp_decodeHttp_sse_test() ->
    Headers = [{<<"Content-Type"/utf8>>, <<"text/event-stream; charset=utf-8"/utf8>>}],
    Body = <<"data: {\"id\":9}\n\n"/utf8>>,
    [Msg] = alMcp:decodeHttpMessages(Headers, Body),
    ?assertEqual(9, maps:get(<<"id"/utf8>>, Msg)).

mcp_decodeHttp_json_test() ->
    Headers = [{"content-type", "application/json"}],
    Body = <<"{\"id\":3,\"result\":{}}"/utf8>>,
    [Msg] = alMcp:decodeHttpMessages(Headers, Body),
    ?assertEqual(3, maps:get(<<"id"/utf8>>, Msg)).

%% decodeHttpMessages：JSON 批量数组 → 多消息。
mcp_decodeHttp_batch_test() ->
    Headers = [{<<"content-type"/utf8>>, <<"application/json"/utf8>>}],
    Body = <<"[{\"id\":1},{\"id\":2}]"/utf8>>,
    Msgs = alMcp:decodeHttpMessages(Headers, Body),
    ?assertEqual(2, length(Msgs)).

%%%===================================================================
%%% 第六批：Elixir / 多 BEAM 语言支持
%%%===================================================================

-define(EX_SAMPLE, <<"defmodule MyApp.Calc do\n"
                     "  @moduledoc \"sample\"\n"
                     "  use GenServer\n"
                     "  import Enum\n"
                     "  alias MyApp.Util\n"
                     "\n"
                     "  @spec add(integer, integer) :: integer\n"
                     "  def add(a, b) do\n"
                     "    a + b\n"
                     "  end\n"
                     "\n"
                     "  def noop, do: :ok\n"
                     "\n"
                     "  defp helper(x) do\n"
                     "    x * 2\n"
                     "  end\n"
                     "\n"
                     "  defmacro mac(ast) do\n"
                     "    ast\n"
                     "  end\n"
                     "end\n"/utf8>>).

%% Elixir 文件识别：.ex/.exs 为真，.erl 为假。
elixir_isFile_test() ->
    ?assert(alElixir:isElixirFile("lib/foo.ex")),
    ?assert(alElixir:isElixirFile(<<"lib/foo.exs"/utf8>>)),
    ?assertNot(alElixir:isElixirFile("src/foo.erl")).

%% 模块名解析：取首个 defmodule 的限定名（含点）。
elixir_moduleName_test() ->
    ?assertEqual('MyApp.Calc', alElixir:parseModuleName(?EX_SAMPLE)),
    ?assertEqual(undefined, alElixir:parseModuleName(<<"x = 1\n"/utf8>>)).

%% 函数解析：def/defp/defmacro 名称、arity、可见性与行号范围。
elixir_functions_test() ->
    Lines = binary:split(?EX_SAMPLE, <<"\n"/utf8>>, [global]),
    Funs = alElixir:parseFunctions(Lines),
    Names = [maps:get(name, F) || F <- Funs],
    ?assert(lists:member(add, Names)),
    ?assert(lists:member(noop, Names)),
    ?assert(lists:member(helper, Names)),
    ?assert(lists:member(mac, Names)),
    [Add] = [F || F <- Funs, maps:get(name, F) =:= add],
    ?assertEqual(2, maps:get(arity, Add)),
    ?assert(maps:get(public, Add)),
    ?assert(maps:get(line_start, Add) =< maps:get(line_end, Add)),
    [Noop] = [F || F <- Funs, maps:get(name, F) =:= noop],
    ?assertEqual(0, maps:get(arity, Noop)),
    [Helper] = [F || F <- Funs, maps:get(name, F) =:= helper],
    ?assertNot(maps:get(public, Helper)).

%% 完整条目：与 Erlang 索引条目同构（含 language=elixir、exports、specs、deps）。
elixir_parseModule_test() ->
    Entry = alElixir:parseModule("/proj", "/proj/lib/calc.ex", ?EX_SAMPLE, 0),
    ?assertEqual('MyApp.Calc', maps:get(module, Entry)),
    ?assertEqual(elixir, maps:get(language, Entry)),
    Exports = maps:get(exports, Entry),
    ?assert(lists:member({add, 2}, Exports)),
    ?assert(lists:member({mac, 1}, Exports)),
    ?assertNot(lists:member({helper, 1}, Exports)),
    ?assert(lists:member({add, 2}, maps:get(specs, Entry))),
    Behaviours = maps:get(behaviours, Entry),
    ?assert(lists:member('GenServer', Behaviours)),
    Imports = maps:get(imports, Entry),
    ?assert(lists:member('Enum', Imports)),
    ?assert(lists:member('MyApp.Util', Imports)).