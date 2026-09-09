%%% @doc EUnit tests for alQueryRewrite.
-module(alQueryRewrite_tests).

-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% 关键导出存在性
%%--------------------------------------------------------------------
critical_exports_test() ->
    Exports = alQueryRewrite:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{rewrite, 1}, {rewrite, 2}, {clearCache, 0}]].

%%--------------------------------------------------------------------
%% rewritePrompt/1：返回包含关键指令的 binary
%%--------------------------------------------------------------------
rewritePrompt_test() ->
    Prompt = alQueryRewrite:rewritePrompt(<<"test">>),
    ?assert(is_binary(Prompt)),
    ?assert(binary:match(Prompt, <<"JSON array">>) =/= nomatch).

%%--------------------------------------------------------------------
%% parseTerms/1：解析 JSON 数组
%%--------------------------------------------------------------------
parseTerms_jsonArray_test() ->
    Content = <<"[\"try\", \"catch\", \"error_handler\"]">>,
    ?assertEqual([<<"try">>, <<"catch">>, <<"error_handler">>],
                 alQueryRewrite:parseTerms(Content)).

parseTerms_withMarkdown_test() ->
    Content = <<"Here are the terms:\n```json\n[\"foo\", \"bar\"]\n```\nDone.">>,
    Result = alQueryRewrite:parseTerms(Content),
    ?assertEqual([<<"foo">>, <<"bar">>], Result).

parseTerms_emptyArray_test() ->
    ?assertEqual([], alQueryRewrite:parseTerms(<<"[]">>)).

parseTerms_invalid_test() ->
    ?assertEqual([], alQueryRewrite:parseTerms(<<"not json">>)),
    ?assertEqual([], alQueryRewrite:parseTerms(<<>>)).

%%--------------------------------------------------------------------
%% fallbackTerms/1：降级分词
%%--------------------------------------------------------------------
fallbackTerms_spaces_test() ->
    ?assertEqual([<<"how">>, <<"to">>, <<"handle">>, <<"errors">>],
                 alQueryRewrite:fallbackTerms(<<"how to handle errors">>)).

fallbackTerms_singleWord_test() ->
    ?assertEqual([<<"error">>],
                 alQueryRewrite:fallbackTerms(<<"error">>)).

fallbackTerms_chinese_test() ->
    %% 纯中文无空格，原样返回
    ?assertEqual([<<"如何处理错误"/utf8>>],
                 alQueryRewrite:fallbackTerms(<<"如何处理错误"/utf8>>)).

fallbackTerms_empty_test() ->
    ?assertEqual([<<>>], alQueryRewrite:fallbackTerms(<<>>)).

%%--------------------------------------------------------------------
%% 缓存键语义：不同查询文本应作为独立键存储（键即查询文本 binary）
%%--------------------------------------------------------------------
cache_key_distinct_queries_test() ->
    _ = alQueryRewrite:storeCache(<<"query alpha">>, [<<"a">>]),
    _ = alQueryRewrite:storeCache(<<"query beta">>, [<<"b">>]),
    %% 键为查询文本 binary 本身，无 phash2 中间层
    ?assertMatch([{<<"query alpha">>, [<<"a">>], _}],
                 ets:lookup(alQueryRewriteCache, <<"query alpha">>)),
    ?assertMatch([{<<"query beta">>, [<<"b">>], _}],
                 ets:lookup(alQueryRewriteCache, <<"query beta">>)),
    ?assertEqual(2, ets:info(alQueryRewriteCache, size)),
    %% 同查询再次写入覆盖旧值，键不变（不新增条目）
    _ = alQueryRewrite:storeCache(<<"query alpha">>, [<<"a2">>]),
    ?assertEqual(2, ets:info(alQueryRewriteCache, size)),
    ?assertMatch([{<<"query alpha">>, [<<"a2">>], _}],
                 ets:lookup(alQueryRewriteCache, <<"query alpha">>)).
