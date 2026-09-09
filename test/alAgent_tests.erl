%%% @doc EUnit tests for alAgent exports and structure.
-module(alAgent_tests).

-include_lib("eunit/include/eunit.hrl").

-define(setup, begin ok = alConfig:load() end).

critical_exports_test() ->
    Exports = alAgent:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{run, 2}, {resumeAfterApproval, 3}]].

runRejectsEmptyPrompt_test() ->
    ?setup,
    ?assertMatch({error, emptyPrompt}, alAgent:run(<<>>, #{})),
    ?assertMatch({error, emptyPrompt}, alAgent:run(<<"   "/utf8>>, #{})).

%%--------------------------------------------------------------------
%% P1-4 语义缓存集成：命中检查守卫 + 答案文本提取 + 失效锚点提取。
%%--------------------------------------------------------------------
semantic_cache_hit_guards_test() ->
    ?setup,
    Q = <<"如何调用 alSearch 搜索"/utf8>>,
    %% 写模式（edit）不查缓存：结果依赖实时状态
    ?assertEqual(miss, alAgent:maybeSemanticCacheHit(Q, #{mode => edit})),
    %% 纯闲聊直答（skipQueryLlm）不查缓存
    ?assertEqual(miss, alAgent:maybeSemanticCacheHit(Q, #{skipQueryLlm => true})),
    %% ask 模式正常查询（未写入 → miss，但不抛异常）
    ?assertEqual(miss, alAgent:maybeSemanticCacheHit(Q, #{})).

answer_text_extraction_test() ->
    ?assertEqual(<<"plain">>, alAgent:answerText(<<"plain">>)),
    ?assertEqual(<<"wrapped">>, alAgent:answerText(#{answer => <<"wrapped">>,
                                                    verdict => warn})),
    ?assertEqual(<<>>, alAgent:answerText(#{other => 1})),
    ?assertEqual(<<>>, alAgent:answerText(42)).

cache_anchor_files_from_trace_test() ->
    %% trace 中 readFile 调用的 path 参数与搜索结果 JSON 里的 file 字段都被提取
    Trace = [
        {step, 1},
        {tool_calls, [
            #{id => <<"c1">>,
              function => #{name => <<"readFile">>,
                            arguments => #{path => <<"src/a.erl">>}}}
        ]},
        {results, [
            #{role => tool, tool_call_id => <<"c1">>,
              content => <<"{\"status\":\"ok\",\"hits\":[{\"file\":\"src/b.erl\"}]}">>}
        ]}
    ],
    Files = alAgent:cacheAnchorFiles(Trace),
    ?assert(is_list(Files)),
    ?assert(lists:member(<<"src/a.erl">>, Files)),
    ?assert(lists:member(<<"src/b.erl">>, Files)),
    %% 非 trace 输入与空 trace 都安全
    ?assertEqual([], alAgent:cacheAnchorFiles(not_a_list)),
    ?assertEqual([], alAgent:cacheAnchorFiles([])).
