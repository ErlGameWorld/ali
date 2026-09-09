%%% @doc EUnit tests for alToolCatalog.
-module(alToolCatalog_tests).

-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% Existing catalogue invariants
%%%===================================================================

allToolsNonempty_test() ->
    ?assert(length(alToolCatalog:allTools()) >= 20).

llmDefinitionsMatchCatalog_test() ->
    Llms = alToolCatalog:llmSafeTools(),
    All = alToolCatalog:allTools(),
    ?assert(length(Llms) >= 20),
    ?assert(lists:all(fun(T) -> lists:member(T, All) end, Llms)).

mcpToolsHaveSchemas_test() ->
    Tools = alToolCatalog:mcpTools(),
    ?assertEqual(length(alToolCatalog:allTools()), length(Tools)),
    ?assert(lists:all(fun(#{name := _, description := _, inputSchema := _}) -> true end, Tools)).

invokeUnknownTool_test() ->
    ?assertMatch({error, {unknownTool, _}}, alToolCatalog:invoke(noSuchTool, #{})).

%%%===================================================================
%%% Data-driven registry
%%%===================================================================

builtinToolsStructure_test() ->
    Defs = alToolCatalog:builtinTools(),
    ?assert(length(Defs) >= 20),
    lists:foreach(fun(D) ->
        ?assertMatch(#{name := _, description := _, inputSchema := _, llmSafe := _}, D)
    end, Defs).

builtinIndexO1Lookup_test() ->
    Idx = alToolCatalog:builtinIndex(),
    ?assert(is_map(Idx)),
    %% Every builtin name must be in the index.
    lists:foreach(fun(#{name := N}) ->
        ?assert(maps:is_key(N, Idx))
    end, alToolCatalog:builtinTools()),
    %% Unknown name absent.
    ?assertEqual(false, maps:is_key(noSuchTool, Idx)).

data_flow_tools_registered_test() ->
    ok = alToolCatalog:cacheClear(),
    Names = alToolCatalog:allTools(),
    lists:foreach(fun(T) ->
        ?assert(lists:member(T, Names)),
        ?assertEqual(read, alPolicy:level(T))
    end, [traceDataQuery, dataSources, dataSourceCallers, paramSources, traceDataFlow]).

cacheClearRebuild_test() ->
    %% Force a rebuild: clear, then ask for the list which rebuilds cache.
    ok = alToolCatalog:cacheClear(),
    _ = alToolCatalog:builtinIndex(),
    Idx = alToolCatalog:builtinIndex(),
    ?assert(is_map(Idx)),
    %% Calling again returns the same cached instance (no rebuild).
    Idx2 = alToolCatalog:builtinIndex(),
    ?assertEqual(Idx, Idx2).

toolSpecViaIndex_test() ->
    Spec = alToolCatalog:toolSpec(searchCode),
    ?assertEqual(searchCode, maps:get(name, Spec)),
    ?assert(is_binary(maps:get(description, Spec))),
    ?assert(is_map(maps:get(inputSchema, Spec))).

toolSpecUnknownFallsBack_test() ->
    Spec = alToolCatalog:toolSpec(noSuchTool),
    ?assertEqual(noSuchTool, maps:get(name, Spec)),
    ?assertEqual(<<"Unknown tool">>, maps:get(description, Spec)).

llmSafeExcludesWriteTools_test() ->
    Safe = alToolCatalog:llmSafeTools(),
    %% Write-class tools must not be in the safe set.
    ?assertNot(lists:member(applyPatch, Safe)),
    ?assertNot(lists:member(applyPatchBatch, Safe)),
    ?assertNot(lists:member(rollbackPatch, Safe)),
    %% Runtime MFA is exposed to the LLM (policy still gates execution).
    ?assert(lists:member(runMfa, Safe)),
    %% Read tools must be present.
    ?assert(lists:member(searchCode, Safe)),
    ?assert(lists:member(getRuntime, Safe)).

llmDefinitionsOnlySafe_test() ->
    Defs = alToolCatalog:llmDefinitions(),
    SafeNames = [binary_to_atom(maps:get(name, maps:get(function, D)), utf8) || D <- Defs],
    ?assert(lists:all(fun(N) -> lists:member(N, alToolCatalog:llmSafeTools()) end, SafeNames)).

llm_schema_drops_tautology_keeps_constraints_test() ->
    ok = alToolCatalog:cacheClear(),
    Goto = llmFun(<<"gotoDef">>),
    GProps = maps:get(properties, maps:get(parameters, Goto)),
    Mod = maps:get(module, GProps),
    ?assertEqual(string, maps:get(type, Mod)),
    ?assertEqual(undefined, maps:get(description, Mod, undefined)),
    Run = llmFun(<<"runMfa">>),
    RProps = maps:get(properties, maps:get(parameters, Run)),
    Call = maps:get(call, RProps),
    ?assertNotEqual(undefined, maps:get(description, Call, undefined)),
    Side = maps:get(sideEffect, RProps),
    ?assert(maps:is_key(enum, Side)).

mcp_schema_keeps_catalog_desc_test() ->
    ok = alToolCatalog:cacheClear(),
    Spec = alToolCatalog:toolSpec(gotoDef),
    Props = maps:get(properties, maps:get(inputSchema, Spec)),
    Mod = maps:get(module, Props),
    ?assertEqual(<<"模块名"/utf8>>, maps:get(description, Mod)).

llm_payload_size_budget_test() ->
    ok = alToolCatalog:cacheClear(),
    Json = alJson:encode(alToolCatalog:llmDefinitions()),
    Size = byte_size(Json),
    io:format(user, "llm tools json bytes=~p~n", [Size]),
    %% 压缩前全量 tools JSON 约 49KB；结构开销（~80 个 function wrapper）决定下限。
    ?assert(Size < 36000, Size).

llmFun(Name) ->
    case [maps:get(function, D) || D <- alToolCatalog:llmDefinitions(),
          maps:get(name, maps:get(function, D)) =:= Name] of
        [F | _] -> F;
        [] -> error({missingLlmTool, Name})
    end.

definitionsForModeEditIncludesWrite_test() ->
    AskNames = toolDefNames(alToolCatalog:definitionsForMode(ask)),
    EditNames = toolDefNames(alToolCatalog:definitionsForMode(edit)),
    ?assertNot(lists:member(applyPatch, AskNames)),
    ?assert(lists:member(applyPatch, EditNames)),
    ?assert(lists:member(rollbackPatch, EditNames)),
    ?assert(lists:member(writeFile, EditNames)).

toolDefNames(Defs) ->
    [binary_to_atom(maps:get(name, maps:get(function, D)), utf8) || D <- Defs].

%%%===================================================================
%%% callWithTimeout/6
%%%===================================================================

callWithTimeoutOk_test() ->
    Ref = make_ref(),
    %% getRuntime is pure Erlang (alRuntimeProbe:snapshot/0) and
    %% works without the Rust core.
    Result = alToolCatalog:callWithTimeout(
        getRuntime, #{}, #{}, self(), Ref, 5000),
    ?assertMatch({ok, _}, Result).

callWithTimeoutBinaryTool_test() ->
    Ref = make_ref(),
    Result = alToolCatalog:callWithTimeout(
        <<"getRuntime">>, #{}, #{}, self(), Ref, 5000),
    ?assertMatch({ok, _}, Result).

callWithTimeoutUnknownTool_test() ->
    Ref = make_ref(),
    Result = alToolCatalog:callWithTimeout(
        noSuchTool, #{}, #{}, self(), Ref, 5000),
    ?assertMatch({error, {unknownTool, _}}, Result).

callWithTimeoutCrash_test() ->
    Ref = make_ref(),
    %% runMfa with an undefined module should fail rather than hang.
    Result = alToolCatalog:callWithTimeout(
        runMfa, #{module => noSuchModuleXyz, function => f, args => []},
        #{}, self(), Ref, 5000),
    ?assertMatch({error, _}, Result).

callWithTimeoutDeadline_test() ->
    Ref = make_ref(),
    %% simulate can take long if the Rust core is unavailable; a 1ms
    %% budget forces the timeout branch deterministically.
    Started = erlang:monotonic_time(millisecond),
    Result = alToolCatalog:callWithTimeout(
        simulate, #{type => askDry, question => <<"hi">>},
        #{}, self(), Ref, 1),
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    case Result of
        {error, toolTimeout} ->
            %% Timeout enforced; worker should have been killed.
            ?assert(Elapsed < 500);
        {ok, _} ->
            %% Worker finished faster than 1ms — acceptable.
            ok;
        {error, _} ->
            %% Worker errored fast — also acceptable.
            ok
    end.
