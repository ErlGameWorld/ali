%%% @doc Structural checks for alVerify (no running LLM / full app required).
-module(alVerify_tests).

-include_lib("eunit/include/eunit.hrl").

non_llm_categories_exclude_llm_test() ->
    Cats = alVerify:nonLlmCategories(),
    ?assert(is_list(Cats)),
    ?assert(Cats =/= []),
    ?assertNot(lists:member(llm, Cats)),
    %% memory may need embedding/API — keep it out of default non-LLM set
    ?assertNot(lists:member(memory, Cats)).

non_llm_categories_are_known_test() ->
    Known = [search, callgraph, symbol, fileread, runtime, policy, db, backup, memory, llm],
    lists:foreach(
        fun(Cat) -> ?assert(lists:member(Cat, Known)) end,
        alVerify:nonLlmCategories()
    ).

list_cases_returns_ok_test() ->
    ?assertEqual(ok, alVerify:listCases()).

help_returns_ok_test() ->
    ?assertEqual(ok, alVerify:help()).

%%--------------------------------------------------------------------
%% 本地思考模型兼容：extractLlmContent 逐级降级
%%--------------------------------------------------------------------

extract_content_prefers_content_test() ->
    ?assertEqual(<<"hello">>,
        alVerify:extractLlmContent(#{content => <<"hello">>,
                                     reasoning_content => <<"thinking">>})).

extract_content_falls_back_to_message_test() ->
    ?assertEqual(<<"from message">>,
        alVerify:extractLlmContent(#{message => #{content => <<"from message">>}})).

extract_content_falls_back_to_reasoning_test() ->
    %% qwen3 思考模式：content 空但 reasoning_content 有正文
    ?assertEqual(<<"thinking answer">>,
        alVerify:extractLlmContent(#{content => <<>>,
                                     reasoning_content => <<"thinking answer">>})).

extract_content_skips_undefined_test() ->
    %% undefined 不能被 toBinary 渲染成 <<"undefined">> 当正文
    ?assertEqual(<<>>,
        alVerify:extractLlmContent(#{content => undefined,
                                     message => #{content => undefined}})).

extract_content_non_map_test() ->
    ?assertEqual(<<>>, alVerify:extractLlmContent(undefined)),
    ?assertEqual(<<>>, alVerify:extractLlmContent({error, something})).

%%--------------------------------------------------------------------
%% 分类校验 / 结果形态兼容
%%--------------------------------------------------------------------

validate_categories_test() ->
    %% 合法分类（含 all）返回空列表
    ?assertEqual([], alVerify:validateCategories([llm, search, all])),
    %% 拼错的分类被识别出来
    ?assertEqual([srch], alVerify:validateCategories([search, srch])).

real_llm_cases_are_in_run_test() ->
    Ids = [Id || {Id, Cat, _, _, _} <- alVerify:realLlmCases(), Cat =:= llm],
    ?assert(lists:member(l1, Ids)),
    ?assert(lists:member(rl3, Ids)),
    ?assert(lists:member(rl6, Ids)).

list_of_shapes_test() ->
    %% 裸列表 / #{Key => [...]} 包装 / 其他形态
    ?assertEqual([1, 2], alVerify:listOf([1, 2], processes)),
    ?assertEqual([a], alVerify:listOf(#{processes => [a]}, processes)),
    ?assertEqual([], alVerify:listOf(#{other => [a]}, processes)),
    ?assertEqual([], alVerify:listOf(undefined, processes)).

memory_entries_shapes_test() ->
    ?assertEqual([m1], alVerify:memoryEntries([m1])),
    ?assertEqual([m2], alVerify:memoryEntries(#{memories => [m2]})),
    ?assertEqual([m3], alVerify:memoryEntries(#{results => [m3]})),
    ?assertEqual([m4], alVerify:memoryEntries(#{items => [m4]})),
    ?assertEqual([], alVerify:memoryEntries(#{unexpected => 1})),
    ?assertEqual([], alVerify:memoryEntries(bad)).
