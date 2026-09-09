%%% @doc EUnit tests for alToolCatalog MCP extensions (resources/prompts).
-module(alToolCatalogMcp_tests).

-include_lib("eunit/include/eunit.hrl").

%% mcpResources/0

mcpResourcesNonempty_test() ->
    Resources = alToolCatalog:mcpResources(),
    ?assert(length(Resources) >= 3),
    ?assert(lists:all(fun(R) -> is_map(R) andalso
        maps:is_key(uri, R) andalso maps:is_key(name, R) andalso
        maps:is_key(description, R) andalso maps:is_key(mimeType, R) end, Resources)).

mcpResourcesIncludesKnownUris_test() ->
    Resources = alToolCatalog:mcpResources(),
    Uris = [maps:get(uri, R) || R <- Resources],
    ?assert(lists:member(<<"ali://config">>, Uris)),
    ?assert(lists:member(<<"ali://schema/sql">>, Uris)),
    ?assert(lists:member(<<"ali://tools">>, Uris)).

%% mcpResourceRead/1

mcpResourceReadToolsReturnsJson_test() ->
    {ok, Result} = alToolCatalog:mcpResourceRead(<<"ali://tools">>),
    ?assertMatch(#{uri := <<"ali://tools">>, mimeType := <<"application/json">>, text := _}, Result),
    Decoded = alJson:decode(maps:get(text, Result)),
    Expected = length(alToolCatalog:allTools()),
    ?assertMatch(#{<<"tools">> := _, <<"count">> := _}, Decoded),
    ?assertEqual(Expected, maps:get(<<"count">>, Decoded)).

mcpResourceReadUnknownReturnsError_test() ->
    ?assertEqual({error, unknownResource}, alToolCatalog:mcpResourceRead(<<"ali://unknown">>)).

%% mcpPrompts/0

mcpPromptsNonempty_test() ->
    Prompts = alToolCatalog:mcpPrompts(),
    ?assert(length(Prompts) >= 5),
    ?assert(lists:all(fun(P) -> is_map(P) andalso
        maps:is_key(name, P) andalso maps:is_key(description, P) andalso
        maps:is_key(arguments, P) end, Prompts)).

mcpPromptsIncludesKnownNames_test() ->
    Prompts = alToolCatalog:mcpPrompts(),
    Names = [maps:get(name, P) || P <- Prompts],
    ?assert(lists:member(<<"explain_module">>, Names)),
    ?assert(lists:member(<<"trace_callers">>, Names)),
    ?assert(lists:member(<<"find_bottleneck">>, Names)),
    ?assert(lists:member(<<"review_patch">>, Names)),
    ?assert(lists:member(<<"draft_refactor">>, Names)).

%% mcpPromptGet/2 — render messages

mcpPromptGetExplainModule_test() ->
    {ok, Result} = alToolCatalog:mcpPromptGet(<<"explain_module">>, #{<<"module">> => <<"ali_sup">>}),
    ?assertMatch(#{description := _, messages := _}, Result),
    Messages = maps:get(messages, Result),
    ?assertEqual(2, length(Messages)),
    [Sys, User] = Messages,
    ?assertEqual(<<"system">>, maps:get(role, Sys)),
    ?assertEqual(<<"user">>, maps:get(role, User)),
    UserText = maps:get(text, maps:get(content, User)),
    ?assert(is_binary(UserText)),
    %% The rendered user message should contain the module name
    ?assert(byte_size(UserText) > byte_size(<<"ali_sup">>)).

mcpPromptGetTraceCallersWithArity_test() ->
    {ok, Result} = alToolCatalog:mcpPromptGet(<<"trace_callers">>,
        #{<<"module">> => <<"ali">>, <<"function">> => <<"search">>, <<"arity">> => 2}),
    Messages = maps:get(messages, Result),
    User = lists:last(Messages),
    UserText = maps:get(text, maps:get(content, User)),
    ?assert(is_binary(UserText)).

mcpPromptGetTraceCallersWithoutArity_test() ->
    {ok, Result} = alToolCatalog:mcpPromptGet(<<"trace_callers">>,
        #{<<"module">> => <<"ali">>, <<"function">> => <<"search">>}),
    Messages = maps:get(messages, Result),
    ?assertEqual(2, length(Messages)).

mcpPromptGetFindBottleneck_test() ->
    {ok, Result} = alToolCatalog:mcpPromptGet(<<"find_bottleneck">>,
        #{<<"symptom">> => <<"CPU 飙高"/utf8>>}),
    ?assertMatch(#{messages := [_Sys, _User]}, Result).

mcpPromptGetReviewPatch_test() ->
    {ok, Result} = alToolCatalog:mcpPromptGet(<<"review_patch">>,
        #{<<"patch_json">> => <<"{\"file\":\"x.erl\"}">>}),
    ?assertMatch(#{messages := [_Sys, _User]}, Result).

mcpPromptGetDraftRefactor_test() ->
    {ok, Result} = alToolCatalog:mcpPromptGet(<<"draft_refactor">>,
        #{<<"target">> => <<"ali_sup"/utf8>>}),
    ?assertMatch(#{messages := [_Sys, _User]}, Result).

mcpPromptGetUnknownReturnsError_test() ->
    ?assertEqual({error, unknownPrompt},
                 alToolCatalog:mcpPromptGet(<<"no_such">>, #{})).
