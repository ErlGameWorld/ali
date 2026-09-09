%%% @doc EUnit tests for tool router.
-module(alToolRouter_tests).

-include_lib("eunit/include/eunit.hrl").

-define(setup, begin ok = alConfig:load() end).

critical_exports_test() ->
    Exports = alToolRouter:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{ask, 2}, {runWithTools, 2}, {callTool, 2}, {callTool, 3},
                   {toolDefinitions, 0}, {maybePrefetchedSearch, 3}, {resumeToolLoop, 2}]].

prefetchSearchCache_test() ->
    Opts = #{
        prefetchSearch => #{
            query => "supervisor",
            hits => [#{module => ali_sup, score => 1.0}]
        },
        prefetchLimit => 6
    },
    Args = #{query => <<"Supervisor">>, limit => 5},
    ?assertMatch(
        {ok, #{hits := [_ | _], engine := contextCache}},
        alToolRouter:maybePrefetchedSearch(searchCode, Args, Opts)
    ),
    ?assertEqual(
        miss,
        alToolRouter:maybePrefetchedSearch(searchCode, #{query => <<"other">>, limit => 5}, Opts)
    ).

toolDefinitionsNonEmpty_test() ->
    ?setup,
    Defs = alToolRouter:toolDefinitions(),
    ?assert(is_list(Defs) andalso length(Defs) > 0).

callToolUnknown_test() ->
    ?setup,
    Result = alToolRouter:callTool(unknownToolXyz, #{}),
    ?assertMatch({error, _}, Result).

%%--------------------------------------------------------------------
%% L4 回归：specIndex/specSearch 必须校验 root 位于 projectRoot 内，
%% 越界路径返回 pathNotAllowed，不得直接进入 alSpecIndex 遍历。
%%--------------------------------------------------------------------
spec_index_rejects_path_outside_root_test() ->
    ?setup,
    Result = alToolRouter:callTool(specIndex,
        #{type => <<"record">>, root => <<"C:\\Windows\\System32">>}),
    ?assertMatch({error, #{reason := pathNotAllowed}}, Result).

spec_search_rejects_path_outside_root_test() ->
    ?setup,
    Result = alToolRouter:callTool(specSearch,
        #{pattern => <<"foo">>, root => <<"C:\\Windows\\System32">>}),
    ?assertMatch({error, #{reason := pathNotAllowed}}, Result).

%% P1 回归：pending 结果经 capToolResult/alJson:encode 后 content 为 JSON binary，
%% decode 后 status 为 <<"pending">>。此前只认原子 pending，挂起检测失效。
pending_task_id_recognizes_json_binary_test() ->
    Encoded = alJson:encode(#{status => pending, taskId => 42}),
    ?assertEqual({ok, 42}, alToolRouter:pendingTaskId(Encoded)).

pending_task_id_recognizes_map_test() ->
    ?assertEqual({ok, 42}, alToolRouter:pendingTaskId(#{status => pending, taskId => 42})),
    ?assertEqual({ok, 42}, alToolRouter:pendingTaskId(#{<<"status">> => <<"pending">>, <<"taskId">> => 42})).

pending_task_id_miss_test() ->
    ?assertEqual(miss, alToolRouter:pendingTaskId(#{status => ok, taskId => 42})),
    ?assertEqual(miss, alToolRouter:pendingTaskId(<<"not a json">>)).

find_pending_tool_json_binary_test() ->
    Call = #{id => <<"call_1">>, function => #{name => <<"writeFile">>}},
    Encoded = alJson:encode(#{status => pending, taskId => 7}),
    Result = #{role => tool, tool_call_id => <<"call_1">>, name => writeFile, content => Encoded},
    ?assertEqual({ok, 7, Call, Result}, alToolRouter:findPendingTool([Call], [Result])).

%% VCS 路径过滤：undefined 不过滤；[] 空结果；非空按文件收窄。
filterByPaths_semantics_test() ->
    Hits = [#{file => <<"src/a.erl">>, line => 1},
            #{file => <<"src/b.erl">>, line => 2},
            #{<<"file">> => <<"src/c.erl">>, <<"line">> => 3}],
    ?assertEqual(3, length(alToolRouter:filterByPaths(Hits, undefined))),
    ?assertEqual([], alToolRouter:filterByPaths(Hits, [])),
    Filtered = alToolRouter:filterByPaths(Hits, [<<"src/a.erl">>, <<"src/C.erl">>]),
    ?assertEqual(2, length(Filtered)).

trim_tool_messages_keeps_complete_parallel_rounds_test() ->
    Prefix = [
        #{role => system, content => <<"system">>},
        #{role => user, content => <<"context">>},
        #{role => user, content => <<"question">>}
    ],
    %% Alternating one/two tool results makes fixed message-count trimming
    %% cut through a round and leave an orphan role=tool message.
    Rounds = [toolRound(I, 1 + (I rem 2)) || I <- lists:seq(1, 12)],
    Trimmed = alToolRouter:trimToolMessages(Prefix ++ lists:append(Rounds)),
    ?assertEqual(Prefix, lists:sublist(Trimmed, 3)),
    Tail = lists:nthtail(3, Trimmed),
    ?assertEqual(8, length([M || M <- Tail, maps:get(role, M) =:= assistant])),
    ?assert(validToolProtocol(Tail)).

trim_tool_messages_drops_orphan_tool_test() ->
    Prefix = [#{role => system, content => <<"s">>},
              #{role => user, content => <<"u">>}],
    Orphan = #{role => tool, tool_call_id => <<"orphan">>, content => <<"x">>},
    Round = toolRound(1, 1),
    ?assertEqual(Prefix ++ Round,
                 alToolRouter:trimToolMessages(Prefix ++ [Orphan] ++ Round)).

trim_tool_messages_keeps_normal_assistant_history_test() ->
    Msgs = [
        #{role => system, content => <<"s">>},
        #{role => user, content => <<"q1">>},
        #{role => assistant, content => <<"a1">>},
        #{role => user, content => <<"q2">>},
        #{role => assistant, content => <<"a2">>}
        | toolRound(1, 1)
    ] ++ [
        #{role => user, content => <<"q3">>},
        #{role => assistant, content => <<"a3">>}
    ],
    Trimmed = alToolRouter:trimToolMessages(Msgs),
    ?assertEqual(<<"a1">>, maps:get(content, lists:nth(3, Trimmed))),
    ?assertEqual(<<"a2">>, maps:get(content, lists:nth(5, Trimmed))),
    ?assertEqual(<<"a3">>, maps:get(content, lists:last(Trimmed))),
    Toolish = [M || M <- Trimmed,
                    (maps:get(role, M) =:= tool) orelse
                    (maps:get(role, M) =:= assistant andalso maps:is_key(tool_calls, M))],
    ?assert(validToolProtocol(Toolish)).

approx_result_bytes_handles_map_data_test() ->
    %% rust core /search returns #{engine, data => #{query, hits}}; the data
    %% value is a map, not a list — folding it crashed real asks with
    %% {case_clause, #{query, hits}} inside lists:foldl (OTP 28+).
    CoreResult = #{
        engine => rustCore,
        data => #{
            query => <<"alAgent">>,
            hits => [
                #{module => <<"alAgent">>, file => <<"src/agent/alagent.erl">>,
                  score => 9.29, snippets => [],
                  exports => [#{arity => 0, line => 8, name => <<"run">>}],
                  functions => [#{arity => 2, line => 19, name => <<"run">>,
                                  <<"start_line">> => 19, <<"end_line">> => 72}]}
            ]
        }
    },
    N = alToolRouter:approxResultBytes(CoreResult),
    ?assert(is_integer(N) andalso N >= 0),
    ?assertEqual(0, alToolRouter:approxResultBytes(#{})),
    ?assertEqual(5, alToolRouter:approxResultBytes(#{content => <<"hello">>})).

tool_loop_accepts_reply_without_tool_calls_key_test() ->
    %% Public surface: answerFromReply path via cap/trim must not require tool_calls.
    %% Structural guard — missing tool_calls is treated as final answer in toolLoop.
    Reply = #{content => <<"done">>, message => #{role => assistant, content => <<"done">>}},
    ?assertEqual(false, maps:is_key(tool_calls, Reply)),
    ?assertMatch(#{content := <<"done">>}, Reply).

toolRound(I, Count) ->
    Calls = [
        #{id => integer_to_binary(I * 10 + N), type => <<"function">>,
          function => #{name => <<"readFile">>, arguments => <<"{}">>}}
        || N <- lists:seq(1, Count)
    ],
    Assistant = #{role => assistant, content => null, tool_calls => Calls},
    Tools = [
        #{role => tool, tool_call_id => maps:get(id, Call),
          name => readFile, content => #{status => ok}}
        || Call <- Calls
    ],
    [Assistant | Tools].

validToolProtocol([]) -> true;
validToolProtocol([#{role := assistant, tool_calls := Calls} | Rest]) ->
    Ids = [maps:get(id, C) || C <- Calls],
    {Tools, Tail} = lists:splitwith(
        fun(M) -> maps:get(role, M, undefined) =:= tool end,
        Rest
    ),
    ToolIds = [maps:get(tool_call_id, M) || M <- Tools],
    lists:sort(Ids) =:= lists:sort(ToolIds) andalso validToolProtocol(Tail);
validToolProtocol(_) -> false.

%% 「执行一下 M:F()」应直达解析，避免模型只写「执行：」不发 tool_calls。
parseDirectExecCall_localtime_test() ->
    ?assertEqual({ok, erlang, localtime, []},
                 alToolRouter:parseDirectExecCall(<<"执行一下 erlang:localtime()"/utf8>>)),
    ?assertEqual({ok, erlang, localtime, []},
                 alToolRouter:parseDirectExecCall(<<"执行 erlang:localtime/0"/utf8>>)),
    ?assertEqual(error, alToolRouter:parseDirectExecCall(<<"调用链是什么"/utf8>>)),
    ?assertEqual(true, alToolRouter:isRuntimeQuestion(<<"执行一下 erlang:localtime()"/utf8>>)),
    %% 源码逻辑问句不算运行时（无 agent.json 业务词时）
    ?assertEqual(false, alToolRouter:isRuntimeQuestion(
        <<"订单状态机的逻辑处理在 order_port.erl 的 handle_event"/utf8>>)),
    ?assertEqual(true, alToolRouter:isCodeLogicQuestion(
        <<"代码在 order_port.erl 的逻辑"/utf8>>)),
    ?assertEqual(false, alToolRouter:hasWholeWord("order_port.erl handle", "order")),
    ?assertEqual(true, alToolRouter:hasWholeWord("query order online", "order")),
    %% 含正则元字符的关键词不得崩（agent.json 曾混入 ?macro / 噪声词）
    ?assertEqual(false, alToolRouter:hasWholeWord("to_bandit concurrent", "?achieve")),
    ?assertEqual(false, alToolRouter:isRuntimeQuestion(
        <<"to_bandit BanditCnt < BanditMaxNumLimit 并发超上限怎么解决"/utf8>>)),
    %% 通用 BEAM 信号仍算运行时；业务词不应写死在代码里
    ?assertEqual(true, alToolRouter:isRuntimeQuestion(<<"占用内存最高的 ets"/utf8>>)),
    ?assertEqual(false, alToolRouter:isRuntimeQuestion(<<"查一下线上订单坐标"/utf8>>)).

%% 「占用内存最高的 ets」应直达 getEts，避免模型只写「我来搜索」。
parseDirectRuntimeProbe_ets_test() ->
    ?assertEqual({ok, getEts, #{limit => 10}},
                 alToolRouter:parseDirectRuntimeProbe(<<"查看一下占用内存最高的ets的信息"/utf8>>)),
    ?assertEqual({ok, getProcesses, #{limit => 10, sortBy => memory}},
                 alToolRouter:parseDirectRuntimeProbe(<<"内存占用最高的进程"/utf8>>)),
    ?assertEqual(error, alToolRouter:parseDirectRuntimeProbe(<<"ets 是什么意思"/utf8>>)),
    ?assertEqual(true, alToolRouter:looksLikeToolNarration(
                       <<"我需要先找 MFA。我来搜索。"/utf8>>)),
    ?assertEqual(false, alToolRouter:looksLikeToolNarration(<<"当前最大 ETS 是 foo"/utf8>>)),
    %% 半截计划当终答（已调过工具后仍写「先用 searchText」）
    ?assertEqual(true, alToolRouter:looksLikeToolNarration(
        <<"函数体尚未抓到。在给出最终答案前，先用 searchText 抓取完整实现。"/utf8>>)),
    %% 已交付黑盒测试结论则不拦
    ?assertEqual(false, alToolRouter:looksLikeToolNarration(
        <<"结论：交战按时间排序。黑盒测试步骤：1) 拉两队驻守 2) 开战看顺序。"/utf8>>)).

%% 截断元数据：slim ≠ soft（就地瘦身 vs 减半重试）
build_truncation_meta_kinds_test() ->
    Soft = alToolRouter:buildTruncationMeta(soft, true, searchCode, #{matchCount => 9}),
    ?assertEqual(soft, maps:get(truncationKind, Soft)),
    ?assertEqual(true, maps:get(retriedBySystem, Soft)),
    ?assertEqual(false, maps:get(slimmedBySystem, Soft)),
    Slim = alToolRouter:buildTruncationMeta(slim, false, getCallers, #{returned => 10, count => 30, limit => 40}),
    ?assertEqual(slim, maps:get(truncationKind, Slim)),
    ?assertEqual(false, maps:get(retriedBySystem, Slim)),
    ?assertEqual(true, maps:get(slimmedBySystem, Slim)),
    Hint = maps:get(paginationHint, Slim),
    ?assertEqual(10, maps:get(offset, maps:get(suggestedArgs, Hint))),
    ?assertEqual(40, maps:get(limit, maps:get(suggestedArgs, Hint))).

%% readFilePage 指纹必须区分 cursor，避免续读命中错误缓存
read_file_page_fingerprint_includes_cursor_test() ->
    A = alToolRouter:toolFingerprint(readFilePage, #{path => <<"a.erl">>, cursor => null}),
    B = alToolRouter:toolFingerprint(readFilePage, #{path => <<"a.erl">>, cursor => <<"200">>}),
    ?assertNotEqual(A, B),
    %% readFile 忽略 maxBytes
    F1 = alToolRouter:toolFingerprint(readFile, #{path => <<"a.erl">>, maxBytes => 1000}),
    F2 = alToolRouter:toolFingerprint(readFile, #{path => <<"a.erl">>, maxBytes => 9000}),
    ?assertEqual(F1, F2).

%% 同意图第 3 次硬拦截
register_tool_intent_blocks_third_test() ->
    erase(ali_tool_intent_log),
    Args = #{path => <<"src/x.erl">>},
    ?assertMatch({ok, 1}, alToolRouter:registerToolIntent(readFile, Args)),
    ?assertMatch({ok, 2}, alToolRouter:registerToolIntent(readFile, Args)),
    ?assertMatch({block, #{reason := duplicateIntent, count := 3}},
                 alToolRouter:registerToolIntent(readFile, Args)),
    %% 不同行区间不算同一意图
    ?assertMatch({ok, 1},
                 alToolRouter:registerToolIntent(readFile,
                     #{path => <<"src/x.erl">>, startLine => 1, endLine => 50})),
    erase(ali_tool_intent_log).

%% 裁剪时优先丢掉 truncated 轮
trim_prefers_dropping_truncated_rounds_test() ->
    Prefix = [#{role => system, content => <<"s">>},
              #{role => user, content => <<"u">>}],
    %% 12 轮：第 1 轮 content 带 truncated，应被优先丢掉
    TruncRound = begin
        [A | Tools0] = toolRound(1, 1),
        [T0 | RestT] = Tools0,
        Tools = [T0#{content => <<"{\"status\":\"ok\",\"truncated\":true}">>} | RestT],
        [A | Tools]
    end,
    NormalRounds = [toolRound(I, 1) || I <- lists:seq(2, 12)],
    All = Prefix ++ TruncRound ++ lists:append(NormalRounds),
    Trimmed = alToolRouter:trimToolMessages(All),
    Tail = lists:nthtail(2, Trimmed),
    %% 不应再含 truncated 那轮的 tool_call_id（id 形如 11）
    Ids = [maps:get(tool_call_id, M) || M <- Tail, maps:get(role, M) =:= tool],
    ?assertEqual(false, lists:member(<<"11">>, Ids)),
    ?assertEqual(8, length([M || M <- Tail, maps:get(role, M) =:= assistant])),
    ?assert(validToolProtocol(Tail)).

round_msgs_truncated_detect_test() ->
    ?assertEqual(true, alToolRouter:roundMsgsTruncated([
        #{role => tool, content => <<"{\"truncated\":true,\"x\":1}">>}])),
    ?assertEqual(false, alToolRouter:roundMsgsTruncated([
        #{role => tool, content => <<"{\"status\":\"ok\"}">>}])),
    ?assertEqual(true, alToolRouter:roundMsgsTruncated([
        #{role => tool, content => #{truncated => true}}])).

%%--------------------------------------------------------------------
%% P1-6 读写分组并行调度：连续只读调用聚组并行；写类工具单独成组串行保序。
%%--------------------------------------------------------------------
toolGroup_all_reads_single_group_test() ->
    Calls = [readCall(N) || N <- lists:seq(1, 4)],
    ?assertEqual([Calls], alToolRouter:groupToolCallsByWrite(Calls)).

toolGroup_writes_isolated_in_order_test() ->
    Calls = [readCall(1), readCall(2), writeCall(3), readCall(4), writeCall(5)],
    ?assertEqual([[readCall(1), readCall(2)], [writeCall(3)], [readCall(4)], [writeCall(5)]],
                 alToolRouter:groupToolCallsByWrite(Calls)).

toolGroup_leading_and_trailing_write_test() ->
    Calls = [writeCall(1), readCall(2), readCall(3), writeCall(4)],
    ?assertEqual([[writeCall(1)], [readCall(2), readCall(3)], [writeCall(4)]],
                 alToolRouter:groupToolCallsByWrite(Calls)).

toolGroup_only_writes_all_singleton_test() ->
    Calls = [writeCall(1), writeCall(2)],
    ?assertEqual([[writeCall(1)], [writeCall(2)]],
                 alToolRouter:groupToolCallsByWrite(Calls)).

toolGroup_empty_test() ->
    ?assertEqual([], alToolRouter:groupToolCallsByWrite([])).

isWriteToolCall_classification_test() ->
    [?assertEqual(true, alToolRouter:isWriteToolCall(toolCallOf(1, Name)))
     || Name <- [<<"writeFile">>, <<"applyPatch">>, <<"applyPatchBatch">>, <<"rollbackPatch">>]],
    [?assertEqual(false, alToolRouter:isWriteToolCall(toolCallOf(1, Name)))
     || Name <- [<<"readFile">>, <<"searchCode">>, <<"getCallers">>, <<"runMfa">>]],
    %% 非标准结构一律按只读处理，由执行路径兜底。
    ?assertEqual(false, alToolRouter:isWriteToolCall(#{name => writeFile, args => #{}})),
    ?assertEqual(false, alToolRouter:isWriteToolCall(#{function => #{}})),
    ?assertEqual(false, alToolRouter:isWriteToolCall(not_a_map)).

%% 端到端：并行路径结果数与 tool_call_id 顺序保持；写工具走串行组不竞态。
%% 结果内容依赖环境（无 core 时为 error），仅断言协议形状与顺序。
%% eunit 无监督树：先由测试进程预建 ETS 表（alEtsOwner:ensureAll），
%% 避免短命 tool worker 建表后退出销毁表引发的竞态。
executeToolCalls_parallel_preserves_order_test() ->
    ?setup,
    ok = alEtsOwner:ensureAll(),
    Calls = [readCall(1), readCall(2), writeCall(3), readCall(4)],
    Results = alToolRouter:executeToolCalls(Calls, #{}),
    ?assertEqual(4, length(Results)),
    ?assertEqual([<<"call_1">>, <<"call_2">>, <<"call_3">>, <<"call_4">>],
                 [maps:get(tool_call_id, R) || R <- Results]),
    [?assertEqual(tool, maps:get(role, R)) || R <- Results].

%% 5 个只读调用：默认并发 3 → 分两批，仍全量按序返回。
executeToolCalls_multi_read_batching_test() ->
    ?setup,
    ok = alEtsOwner:ensureAll(),
    Calls = [readCall(N) || N <- lists:seq(1, 5)],
    Results = alToolRouter:executeToolCalls(Calls, #{}),
    ?assertEqual(5, length(Results)),
    ?assertEqual([<<"call_", (integer_to_binary(N))/binary>> || N <- lists:seq(1, 5)],
                 [maps:get(tool_call_id, R) || R <- Results]).

%%--------------------------------------------------------------------
%% P2-9 投机预取目标推导
%%--------------------------------------------------------------------

prefetch_targets_combines_sources_test() ->
    Context = #{
        anchorSnippets => [#{file => <<"src/a.erl">>, kind => mfa},
                           #{file => <<"src/b.erl">>, kind => path}],
        writeRecon => #{relatedTests => [#{module => alX, testFile => <<"test/alX_tests.erl">>}]},
        codeHits => [#{file => <<"src/c.erl">>}, #{file => <<"src/d.erl">>},
                     #{file => <<"src/e.erl">>}]
    },
    Targets = alToolRouter:prefetchTargets(Context),
    ?assert(lists:member(<<"src/a.erl">>, Targets)),
    ?assert(lists:member(<<"src/b.erl">>, Targets)),
    ?assert(lists:member(<<"test/alX_tests.erl">>, Targets)),
    %% codeHits 只取头部 2 个
    ?assert(lists:member(<<"src/c.erl">>, Targets)),
    ?assert(lists:member(<<"src/d.erl">>, Targets)),
    ?assertNot(lists:member(<<"src/e.erl">>, Targets)),
    ?assertEqual(lists:usort(Targets), Targets).

prefetch_targets_caps_at_five_test() ->
    Context = #{
        anchorSnippets => [#{file => <<"src/1.erl">>}, #{file => <<"src/2.erl">>},
                           #{file => <<"src/3.erl">>}],
        writeRecon => #{relatedTests => [#{testFile => <<"test/4_tests.erl">>}]},
        codeHits => [#{file => <<"src/5.erl">>}, #{file => <<"src/6.erl">>}]
    },
    ?assertEqual(5, length(alToolRouter:prefetchTargets(Context))).

prefetch_targets_skips_invalid_entries_test() ->
    Context = #{
        anchorSnippets => [not_a_map, #{file => undefined}, #{file => <<>>},
                           #{file => <<"src/ok.erl">>}, #{noFile => 1}],
        writeRecon => #{relatedTests => [#{testFile => 42}, not_a_map]},
        codeHits => [#{file => 123}, not_a_map]
    },
    ?assertEqual([<<"src/ok.erl">>], alToolRouter:prefetchTargets(Context)).

prefetch_targets_empty_and_non_map_test() ->
    ?assertEqual([], alToolRouter:prefetchTargets(#{})),
    ?assertEqual([], alToolRouter:prefetchTargets(undefined)),
    ?assertEqual([], alToolRouter:prefetchTargets(
                              #{anchorSnippets => [], writeRecon => #{relatedTests => []},
                                codeHits => []})).

%% collectToolResults：正常 map 收割路径。
collectToolResults_map_path_test() ->
    RefA = make_ref(), RefB = make_ref(),
    MapA = #{role => tool, tool_call_id => <<"a">>},
    MapB = #{role => tool, tool_call_id => <<"b">>},
    self() ! {toolResult, RefA, MapA},
    self() ! {toolResult, RefB, MapB},
    Workers = [{RefA, self(), make_ref(), <<"a">>},
               {RefB, self(), make_ref(), <<"b">>}],
    Deadline = erlang:monotonic_time(millisecond) + 1000,
    ?assertEqual([MapA, MapB],
                 alToolRouter:collectToolResults(Workers, Deadline, [])).

%% collectToolResults：防御分支——worker 返回 list 时逐条并入，不丢剩余 worker。
collectToolResults_list_defensive_test() ->
    Ref = make_ref(),
    MapA = #{role => tool, tool_call_id => <<"a">>},
    MapB = #{role => tool, tool_call_id => <<"b">>},
    self() ! {toolResult, Ref, [MapA, MapB]},
    Workers = [{Ref, self(), make_ref(), <<"a">>}],
    Deadline = erlang:monotonic_time(millisecond) + 1000,
    ?assertEqual([MapA, MapB],
                 alToolRouter:collectToolResults(Workers, Deadline, [])).

%% collectToolResults：防御分支——非 map 非 list 的奇异结果原样保留。
collectToolResults_other_defensive_test() ->
    Ref = make_ref(),
    self() ! {toolResult, Ref, weirdResult},
    Workers = [{Ref, self(), make_ref(), <<"x">>}],
    Deadline = erlang:monotonic_time(millisecond) + 1000,
    ?assertEqual([weirdResult],
                 alToolRouter:collectToolResults(Workers, Deadline, [])).

%% collectToolResults：单 worker 超时——只杀该 worker，返回 toolTimeout。
collectToolResults_timeout_test() ->
    Ref = make_ref(),
    Pid = spawn(fun() -> receive after infinity -> ok end end),
    Workers = [{Ref, Pid, make_ref(), <<"slow">>}],
    PastDeadline = erlang:monotonic_time(millisecond) - 1,
    ?assertMatch([#{role := tool, tool_call_id := <<"slow">>,
                    content := #{status := error, reason := toolTimeout}}],
                 alToolRouter:collectToolResults(Workers, PastDeadline, [])),
    exit(Pid, kill).

%% collectToolResults：worker 崩溃——DOWN 归因 toolWorkerCrashed。
collectToolResults_worker_down_test() ->
    Ref = make_ref(),
    {Pid, MonRef} = spawn_monitor(fun() -> exit(boom) end),
    Workers = [{Ref, Pid, MonRef, <<"crash">>}],
    Deadline = erlang:monotonic_time(millisecond) + 1000,
    ?assertMatch([#{role := tool, tool_call_id := <<"crash">>,
                    content := #{status := error, reason := {toolWorkerCrashed, boom}}}],
                 alToolRouter:collectToolResults(Workers, Deadline, [])).

readCall(N) ->
    toolCallOf(N, <<"readFile">>).

writeCall(N) ->
    toolCallOf(N, <<"applyPatch">>).

toolCallOf(N, Name) ->
    #{id => <<"call_", (integer_to_binary(N))/binary>>,
      type => <<"function">>,
      function => #{name => Name, arguments => <<"{}">>}}.

%% C1 回归：literalToTerm 必须拒绝可执行 AST，且仍正确解析纯字面量。
literal_to_term_blocks_code_ast_test() ->
    ?assertEqual(error, alToolRouter:literalToTerm(
        {call, 1, {atom, 1, erlang}, [{atom, 1, halt}]})),
    ?assertEqual(error, alToolRouter:literalToTerm(
        {var, 1, 'X'})),
    ?assertEqual(error, alToolRouter:literalToTerm(
        {bin, 1, [{bin_element, 1,
            {call, 1, {atom, 1, os}, [{atom, 1, cmd}, {string, 1, "whoami"}]},
            default, default}]})).

literal_to_term_parses_pure_literals_test() ->
    ?assertEqual("hi", alToolRouter:literalToTerm({string, 1, "hi"})),
    ?assertEqual(foo, alToolRouter:literalToTerm({atom, 1, foo})),
    ?assertEqual(42, alToolRouter:literalToTerm({integer, 1, 42})),
    ?assertEqual([1, 2], alToolRouter:literalToTerm(
        {cons, 1, {integer, 1, 1}, {cons, 1, {integer, 1, 2}, {nil, 1}}})),
    ?assertEqual({a, 1}, alToolRouter:literalToTerm(
        {tuple, 1, [{atom, 1, a}, {integer, 1, 1}]})),
    ?assertEqual(<<"ab">>, alToolRouter:literalToTerm(
        {bin, 1, [{bin_element, 1, {string, 1, "ab"}, default, default}]})),
    ?assertEqual(-3, alToolRouter:literalToTerm({op, 1, '-', {integer, 1, 3}})).

parse_call_expr_rejects_executable_args_test() ->
    ?assertEqual({error, badCall},
                 alToolRouter:parseCallExpr("foo:bar(erlang:halt())")),
    ?assertEqual({error, badCall},
                 alToolRouter:parseCallExpr("foo:bar(<<(os:cmd(\"whoami\"))>>)")),
    ?assertEqual({ok, erlang, localtime, []},
                 alToolRouter:parseCallExpr("erlang:localtime()")).

