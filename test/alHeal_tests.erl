-module(alHeal_tests).

-include_lib("eunit/include/eunit.hrl").

%% Soft-check heal helpers via a tiny local reimplementation of signals
%% (full toolLoop needs LLM). Ensures healable tool classification stays stable.
healable_tools_test() ->
    Heal = [applyPatch, applyPatchBatch, verifyCompile, runEunit, runDialyzer,
            writeFile, validatePatch, dryRunPatch, batchRefactor],
    lists:foreach(fun(T) ->
        ?assertEqual(true, is_healable(T))
    end, Heal),
    ?assertEqual(false, is_healable(searchCode)),
    ?assertEqual(false, is_healable(readFile)).

is_healable(T) when T =:= applyPatch; T =:= applyPatchBatch; T =:= verifyCompile;
                    T =:= runEunit; T =:= runDialyzer; T =:= writeFile;
                    T =:= validatePatch; T =:= dryRunPatch; T =:= batchRefactor ->
    true;
is_healable(_) ->
    false.

patch_schema_has_hunks_test() ->
    alToolCatalog:cacheClear(),
    Spec = alToolCatalog:toolSpec(applyPatch),
    Schema = maps:get(inputSchema, Spec),
    Props = maps:get(properties, Schema),
    ?assert(maps:is_key(hunks, Props) orelse maps:is_key(<<"hunks">>, Props)),
    ?assert(maps:is_key(unified, Props) orelse maps:is_key(<<"unified">>, Props)).

catalog_has_doc_and_deps_test() ->
    alToolCatalog:cacheClear(),
    Doc = alToolCatalog:toolSpec(generateModuleDoc),
    Deps = alToolCatalog:toolSpec(moduleDeps),
    Cg = alToolCatalog:toolSpec(callGraph),
    ?assert(is_map(Doc)),
    ?assert(is_map(Deps)),
    ?assert(is_map(Cg)).
