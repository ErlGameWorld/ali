%%%-------------------------------------------------------------------
%%% @doc Integration tests for the core execution chain:
%%% ali → alToolRouter → alToolCatalog → tool dispatch.
%%%
%%% Tests the delegation chain and tool catalog without requiring
%%% the full application or Rust Core to be running.
%%% @end
%%%-------------------------------------------------------------------
-module(alExecutionChain_tests).

-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% Tool catalog integrity
%%%===================================================================

%% 内置工具列表非空且每条 entry 包含必需字段。
builtinToolsNonEmpty_test() ->
    Tools = alToolCatalog:builtinTools(),
    ?assert(length(Tools) >= 40),
    lists:foreach(fun(T) ->
        ?assertMatch(#{name := _, description := _, inputSchema := _, llmSafe := _}, T)
    end, Tools).

%% allTools 返回 atom 列表，与 builtinTools 一致。
allToolsMatchesBuiltins_test() ->
    All = alToolCatalog:allTools(),
    Builtins = [maps:get(name, T) || T <- alToolCatalog:builtinTools()],
    ?assertEqual(lists:sort(Builtins), lists:sort(All)).

%% LLM 安全工具数量 + 写工具数量 = 总工具数。
llmSafeAndWritePartition_test() ->
    All = alToolCatalog:allTools(),
    Safe = alToolCatalog:llmSafeTools(),
    Write = [T || T <- All, not lists:member(T, Safe)],
    ?assertEqual(length(All), length(Safe) + length(Write)),
    %% Write-class tools must include applyPatch (runMfa is llmSafe but policy-gated)
    ?assert(lists:member(applyPatch, Write)),
    ?assert(lists:member(runMfa, Safe)).

%%%===================================================================
%%% Tool spec lookup
%%%===================================================================

%% 已知工具的 spec 包含 name, description, inputSchema。
knownToolSpec_test() ->
    Spec = alToolCatalog:toolSpec(searchCode),
    ?assertEqual(searchCode, maps:get(name, Spec)),
    ?assert(is_binary(maps:get(description, Spec))),
    ?assert(is_map(maps:get(inputSchema, Spec))).

%% 未知工具返回带 llmSafe=false 的 stub spec。
unknownToolSpec_test() ->
    Spec = alToolCatalog:toolSpec(noSuchTool),
    ?assertEqual(noSuchTool, maps:get(name, Spec)),
    ?assertEqual(<<"Unknown tool">>, maps:get(description, Spec)),
    ?assertEqual(false, maps:get(llmSafe, Spec)).

%%%===================================================================
%%% LLM definitions
%%%===================================================================

%% LLM 定义列表仅包含 llmSafe 工具，且每条是 OpenAI function 格式。
llmDefinitionsFormat_test() ->
    Defs = alToolCatalog:llmDefinitions(),
    ?assert(length(Defs) >= 35),
    lists:foreach(fun(D) ->
        ?assertMatch(#{type := <<"function">>, function := #{name := _, description := _, parameters := _}}, D)
    end, Defs).

%%%===================================================================
%%% Tool routing: callTool
%%%===================================================================

%% 已知工具调用通过路由（readFile 不需要 core）。
callToolReadFile_test() ->
    case alToolRouter:callTool(readFile, #{path => "rebar.config", maxBytes => 100}) of
        {ok, Result} ->
            ?assertMatch(#{path := _, content := _}, Result);
        {error, _} ->
            %% 文件可能不存在或路径解析不同，只要不崩溃即可
            ok
    end.

%% 未知工具返回 {error, {unknownTool, _}}。
callToolUnknown_test() ->
    Result = alToolRouter:callTool(noSuchTool, #{}),
    ?assertMatch({error, {unknownTool, noSuchTool}}, Result).

%%%===================================================================
%%% ali module delegation
%%%===================================================================

%% ali:tools/0 委托到 alToolCatalog:allTools/0。
aliToolsDelegates_test() ->
    ?assertEqual(alToolCatalog:allTools(), ali:tools()).

%% ali:toolSpec/1 委托到 alToolCatalog:toolSpec/1。
aliToolSpecDelegates_test() ->
    ?assertEqual(alToolCatalog:toolSpec(searchCode), ali:toolSpec(searchCode)).

%% ali:callTool/2 委托到 alToolRouter:callTool/2。
aliCallToolDelegates_test() ->
    Result1 = ali:callTool(noSuchTool, #{}),
    Result2 = alToolRouter:callTool(noSuchTool, #{}),
    ?assertEqual(Result1, Result2).

%%%===================================================================
%%% MCP tool catalog
%%%===================================================================

%% MCP tools 列表与 allTools 一致（名称为 binary）。
mcpToolsMatchAll_test() ->
    McpTools = alToolCatalog:mcpTools(),
    AllNames = [atom_to_binary(N, utf8) || N <- alToolCatalog:allTools()],
    McpNames = [maps:get(name, T) || T <- McpTools],
    ?assertEqual(lists:sort(AllNames), lists:sort(McpNames)).

%%%===================================================================
%%% Cache integrity
%%%===================================================================

%% 缓存清除后重建结果一致。
cacheRebuildConsistent_test() ->
    Before = alToolCatalog:allTools(),
    alToolCatalog:cacheClear(),
    After = alToolCatalog:allTools(),
    ?assertEqual(lists:sort(Before), lists:sort(After)).
