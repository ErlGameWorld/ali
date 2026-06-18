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

%% 内置黑名单应拦截 os:cmd/1。
blacklistBlocks_test() ->
    false = alToolEval:isAllowed(os, cmd, 1).

%% 非黑名单 MFA 应允许执行。
allowedUnlessBlacklisted_test() ->
    true = alToolEval:isAllowed(llmCli, estimateTokens, 1),
    true = alToolEval:isAllowed(llmCliConfig, load, 0),
    true = alToolEval:isAllowed(erlang, memory, 0).

%% callFunction 工具应能执行非黑名单函数。
callFunctionSafe_test() ->
    {ok, #{ok := true, value := 1}} =
        alToolEval:callFunction(
            #{module => llmCli, function => estimateTokens, args => [<<"abcd"/utf8>>]},
            #{}
        ).

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
    {ok, Entry} = alCodeIndexer:lookup_module(llmCli),
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
    ok = alPolicy:checkTool(readFile, Policy, #{mode => ask}).

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

%% listBackups 对不存在文件应返回错误。
listBackups_missingFile_test() ->
    Result = alToolEdit:listBackups(
        #{path => <<"nonexistent_file.erl"/utf8>>}, #{}),
    ?assertMatch({error, _}, Result).

%% formatCode 对非 .erl 文件应返回 notErlangFile。
formatCode_nonErlang_test() ->
    {error, notErlangFile} =
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