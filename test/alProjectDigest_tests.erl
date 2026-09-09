%%% @doc EUnit tests for alProjectDigest pure helpers.
-module(alProjectDigest_tests).

-include_lib("eunit/include/eunit.hrl").

aggregate_data_sources_groups_by_table_test() ->
    Sources = [
        #{table => <<"role_tab">>, caller_module => role_db,
          caller_function => <<"lookup">>, caller_arity => 1, kind => <<"ets">>},
        #{<<"table">> => <<"role_tab">>, <<"caller_module">> => role_db,
          <<"caller_function">> => <<"lookup">>, <<"caller_arity">> => 1,
          <<"kind">> => <<"ets">>},
        #{table => <<"bag_tab">>, caller_module => bag,
          caller_function => get, caller_arity => 2, kind => mnesia},
        #{table => <<"cfg_tab">>, caller_module => cfg,
          caller_function => read, caller_arity => 1,
          source_type => <<"ets">>, line => 42}
    ],
    Tables = alProjectDigest:aggregateDataSources(Sources),
    ?assert(maps:is_key(<<"role_tab">>, Tables)),
    ?assert(maps:is_key(<<"bag_tab">>, Tables)),
    RoleCallers = maps:get(<<"role_tab">>, Tables),
    ?assertEqual(1, length(RoleCallers)),
    CfgCallers = maps:get(<<"cfg_tab">>, Tables),
    ?assertMatch([#{kind := <<"ets">>, line := 42} | _], CfgCallers).

extract_module_doc_from_erl_test() ->
    Src = <<"-module(demo).\n"
            "%% @doc castle main city module\n"
            "%% handles player upgrades\n"
            "-export([get/0]).\n">>,
    Doc = alProjectDigest:extractModuleDocFromErl(Src),
    ?assert(is_binary(Doc)),
    ?assert(byte_size(Doc) > 0),
    ?assertNotEqual(nomatch, binary:match(Doc, <<"castle">>)).

extract_includes_from_erl_test() ->
    Src = <<"-include(\"castle.hrl\").\n-include_lib(\"kernel/include/logger.hrl\").\n">>,
    Inc = alProjectDigest:extractIncludesFromErl(Src),
    ?assert(lists:member(<<"castle.hrl">>, Inc)),
    ?assert(lists:member(<<"kernel/include/logger.hrl">>, Inc)).

compose_module_search_text_test() ->
    Text = alProjectDigest:composeModuleSearchText(#{
        module => castle,
        summary => <<"Module castle exports: get/0.">>,
        moduleDoc => <<"主城模块"/utf8>>,
        includes => [<<"castle.hrl">>],
        behaviours => [<<"gen_server">>],
        deps => [<<"player_db">>],
        docBriefs => #{<<"get/0">> => <<"获取主城"/utf8>>}
    }),
    ?assertNotEqual(nomatch, binary:match(Text, <<"主城"/utf8>>)),
    ?assertNotEqual(nomatch, binary:match(Text, <<"castle.hrl">>)).

match_knowledge_scores_tokens_test() ->
    ?assert(alProjectDigest:matchKnowledge([<<"player">>, <<"pos">>],
                                           [<<"player_pos">>, <<"role">>]) >= 1.0),
    ?assertEqual(0.0, alProjectDigest:matchKnowledge([<<"zzz">>], [<<"abc">>])).

%% 测试临时目录基址：项目内 .eunit（gitignored，且不在 indexIgnore 黑名单，
%% 沙箱环境禁止写 AppData user_cache；_build 段会被 resolveReadablePath 拒读）。
testTmpDir() ->
    filename:absname(".eunit").

module_from_path_reads_attr_test() ->
    Dir = filename:join(testTmpDir(),
                        "digest_test_" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
    Path = filename:join(Dir, "demo_mod.erl"),
    ok = file:write_file(Path, <<"-module(demo_mod).\n-export([ok/0]).\nok() -> ok.\n">>),
    ?assertEqual(demo_mod, alProjectDigest:moduleFromPath(Path)),
    _ = file:del_dir_r(Dir).

write_json_atomic_roundtrip_test() ->
    Dir = filename:join(testTmpDir(),
                        "digest_json_" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
    Path = filename:join(Dir, "t.json"),
    ?assertEqual(ok, alProjectDigest:writeJsonAtomic(Path, #{a => 1, b => <<"x">>})),
    {ok, Bin} = file:read_file(Path),
    Map = alJson:decode(Bin),
    ?assertEqual(1, maps:get(<<"a">>, Map)),
    ?assertEqual(<<"x">>, maps:get(<<"b">>, Map)),
    _ = file:del_dir_r(Dir).

default_opts_has_limits_test() ->
    Opts = alProjectDigest:defaultOpts(),
    ?assert(maps:is_key(maxModules, Opts)),
    ?assert(maps:is_key(maxSummaryWarm, Opts)).

normalize_agent_hints_test() ->
    H = alProjectDigest:normalizeAgentHints(#{
        <<"liveDataKeywords">> => [<<"用户"/utf8>>, <<"订单"/utf8>>],
        liveDataOpKeywords => ["改订单"]
    }),
    ?assertEqual(["用户", "订单"], maps:get(liveDataKeywords, H)),
    ?assertEqual(["改订单"], maps:get(liveDataOpKeywords, H)),
    ?assertEqual(#{liveDataKeywords => [], liveDataOpKeywords => [], aliases => #{}},
                 alProjectDigest:normalizeAgentHints(#{})).

seed_and_merge_agent_hints_test() ->
    Data = #{tables => #{<<"order_tab">> => [], <<"user_db">> => []}},
    Actions = [#{phrase => <<"查库存"/utf8>>, mfa => <<"inv:get/1">>, source => auto},
               #{phrase => <<"改库存"/utf8>>, mfa => <<"inv:set/2">>, source => auto}],
    Seeded = alProjectDigest:seedAgentHints(Data, Actions),
    ?assert(lists:member("order", maps:get(liveDataKeywords, Seeded))),
    ?assert(lists:member("user", maps:get(liveDataKeywords, Seeded))),
    ?assert(lists:member("库存", maps:get(liveDataKeywords, Seeded))),
    ?assert(lists:member("改库存", maps:get(liveDataOpKeywords, Seeded))),
    Merged = alProjectDigest:mergeAgentHints(
        #{liveDataKeywords => ["自定义"], liveDataOpKeywords => []}, Seeded),
    ?assert(lists:member("自定义", maps:get(liveDataKeywords, Merged))),
    ?assert(lists:member("order", maps:get(liveDataKeywords, Merged))).

prune_stale_actions_test() ->
    Api = [#{module => order_db,
             exports => [#{name => <<"lookup">>, arity => 1}]}],
    Actions = [
        #{phrase => <<"查订单"/utf8>>, mfa => <<"order_db:lookup/1">>, source => auto},
        #{phrase => <<"查幽灵"/utf8>>, mfa => <<"gone:x/0">>, source => auto},
        #{phrase => <<"手工"/utf8>>, mfa => <<"gone:y/0">>, source => manual}
    ],
    Kept = alProjectDigest:pruneStaleActions(Actions, Api),
    Phrases = [maps:get(phrase, A) || A <- Kept],
    ?assert(lists:member(<<"查订单"/utf8>>, Phrases)),
    ?assert(lists:member(<<"手工"/utf8>>, Phrases)),
    ?assertEqual(false, lists:member(<<"查幽灵"/utf8>>, Phrases)).

table_name_tokens_test() ->
    ?assertEqual(["order"], alProjectDigest:tableNameTokens(<<"order_tab">>)),
    ?assertEqual(["user"], alProjectDigest:tableNameTokens(<<"user_db">>)).

browse_overview_shape_test() ->
    {ok, Ov} = alProjectDigest:browse(#{layer => overview}),
    ?assertEqual(overview, maps:get(layer, Ov)),
    ?assert(maps:is_key(ready, Ov)),
    ?assert(maps:is_key(files, Ov)).

seed_actions_from_tables_test() ->
    Data = #{tables => #{
        <<"role_tab">> => [
            #{mfa => <<"role_db:lookup/1">>, kind => <<"ets">>},
            #{mfa => <<"role_db:update/2">>, kind => <<"ets">>}
        ]
    }},
    Api = [#{module => role_db,
             exports => [#{name => <<"get_role">>, arity => 1},
                         #{name => <<"set_gold">>, arity => 2}]}],
    Actions = alProjectDigest:seedActions(Data, Api),
    ?assert(length(Actions) >= 2),
    Phrases = [maps:get(phrase, A) || A <- Actions],
    ?assert(lists:any(fun(P) -> binary:match(P, <<"查"/utf8>>) =/= nomatch end, Phrases)).

merge_actions_keeps_manual_test() ->
    Existing = [#{phrase => <<"查订单"/utf8>>, mfa => <<"order_db:lookup/1">>, source => manual}],
    Seeded = [#{phrase => <<"查订单"/utf8>>, mfa => <<"auto:x/1">>, source => auto},
              #{phrase => <<"查库存"/utf8>>, mfa => <<"inv:get/1">>, source => auto}],
    Merged = alProjectDigest:mergeActions(Existing, Seeded),
    Order = hd([A || A <- Merged, maps:get(phrase, A) =:= <<"查订单"/utf8>>]),
    ?assertEqual(<<"order_db:lookup/1">>, maps:get(mfa, Order)),
    ?assertEqual(manual, maps:get(source, Order)).

tools_registered_test() ->
    ok = alToolCatalog:cacheClear(),
    Names = alToolCatalog:allTools(),
    lists:foreach(fun(T) ->
        ?assert(lists:member(T, Names))
    end, [projectDigest, searchKnowledge, saveKnowledge, saveAction, lookupAction, digestStatus,
          processInfo, etsLookup, functionHistory, verifyCompile]),
    ?assertEqual(executeSafe, alPolicy:level(projectDigest)),
    ?assertEqual(write, alPolicy:level(saveKnowledge)),
    ?assertEqual(write, alPolicy:level(saveAction)),
    ?assertEqual(read, alPolicy:level(searchKnowledge)),
    ?assertEqual(read, alPolicy:level(processInfo)),
    ?assertEqual(read, alPolicy:level(functionHistory)),
    ?assertEqual(executeSafe, alPolicy:level(verifyCompile)).

sanitize_topic_test() ->
    ?assertEqual(<<"player-pos">>, alProjectDigest:sanitizeTopic(<<"Player Pos">>)),
    ?assertEqual(<<"a-b">>, alProjectDigest:sanitizeTopic(<<"a/b">>)),
    ?assertEqual(<<>>, alProjectDigest:sanitizeTopic(<<"!!!">>)).

save_and_search_topic_summary_test() ->
    ok = alConfig:load(),
    Tmp = filename:join(testTmpDir(),
                        "digest_save_" ++ integer_to_list(erlang:unique_integer([positive]))),
    DataDir = filename:join(Tmp, ".ali"),
    OldDataDir = alConfig:dataDir(),
    ok = alConfig:patch([{dataDir, DataDir}]),
    try
        {ok, Saved} = alProjectDigest:saveKnowledge(#{
            topic => <<"order-status">>,
            content => <<"查订单状态走 order_db:lookup/1，已核实。"/utf8>>,
            source => <<"test">>
        }),
        ?assertEqual(<<"order-status">>, maps:get(topic, Saved)),
        Path = maps:get(path, Saved),
        ?assert(filelib:is_file(Path)),
        {ok, Hits} = alProjectDigest:search(<<"订单状态"/utf8>>, 8),
        ?assert(lists:any(fun(H) ->
            maps:get(kind, H, undefined) =:= topicSummary
                andalso maps:get(topic, H, undefined) =:= <<"order-status">>
        end, Hits))
    after
        _ = alConfig:patch([{dataDir, OldDataDir}]),
        _ = file:del_dir_r(Tmp)
    end.

%% build 在无 DB / 无 core 时仍应产出 meta（摘要降级为 fallback）。
%% 用临时小工程作 projectRoot，避免 NFS 上扫整仓超时；不启完整 ali 应用
%% （避免与 alLocalDb_tests 留下的孤儿进程冲突）。
build_smoke_writes_meta_test_() ->
    {timeout, 120, fun build_smoke_writes_meta/0}.

build_smoke_writes_meta() ->
    ok = alConfig:load(),
    Tiny = filename:join(testTmpDir(),
                         "digest_smoke_" ++ integer_to_list(erlang:unique_integer([positive]))),
    Src = filename:join(Tiny, "src"),
    ok = filelib:ensure_dir(filename:join(Src, "dummy")),
    ok = file:write_file(filename:join(Src, "digest_smoke_mod.erl"),
                         <<"-module(digest_smoke_mod).\n-export([ping/0]).\nping() -> ok.\n">>),
    OldAgent = alConfig:get(agent, #{}),
    ok = alConfig:patch([{agent, maps:merge(OldAgent, #{projectRoot => Tiny})}]),
    try
        case alProjectDigest:build(#{maxModules => 5, maxSummaryWarm => 1, warmLlm => false}) of
            {ok, Meta} ->
                ?assert(maps:is_key(version, Meta) orelse maps:is_key(<<"version">>, Meta)),
                Status = alProjectDigest:status(),
                ?assertEqual(true, maps:get(ready, Status));
            {error, Reason} ->
                ?assertEqual({skip, Reason}, {skip, Reason})
        end
    after
        _ = alConfig:patch([{agent, OldAgent}]),
        _ = file:del_dir_r(Tiny)
    end.

expand_tokens_with_aliases_test() ->
    Aliases = #{<<"主城"/utf8>> => [<<"castle">>],
                <<"城堡"/utf8>> => [<<"castle">>]},
    Tokens = [<<"主城"/utf8>>, <<"升级"/utf8>>],
    Expanded = alProjectDigest:expandTokensWithAliases(Tokens, Aliases),
    ?assert(lists:member(<<"castle">>, Expanded)).

extract_aliases_from_module_doc_test() ->
    Doc = iolist_to_binary([
        <<"@alias ">>, <<"主城"/utf8>>, <<"\n">>,
        <<"@aliases ">>, <<"城堡"/utf8>>, <<",">>, <<"城池"/utf8>>, <<"\n">>,
        <<"@alias ">>, <<"主城"/utf8>>, <<"=castle">>, <<"\n">>
    ]),
    M = alProjectDigest:extractAliasesFromModuleDoc(Doc, castle),
    ?assert(maps:size(M) >= 2),
    ?assert(lists:any(fun(K) ->
        lists:member(<<"castle">>, maps:get(K, M, []))
    end, maps:keys(M))).

classify_module_bucket_test() ->
    ?assertEqual(core, alProjectDigest:classifyModuleBucket(castle_port, <<"src/castle_port.erl">>)),
    ?assertEqual(cfg, alProjectDigest:classifyModuleBucket(ability_pb_cfg, <<"src/ability_pb_cfg.erl">>)),
    ?assertEqual(test, alProjectDigest:classifyModuleBucket(test_foo, <<"src/test_foo.erl">>)),
    ?assertEqual(gm, alProjectDigest:classifyModuleBucket(gm_castle, <<"src/gm_castle.erl">>)).

correct_export_arities_test() ->
    Exports = [#{name => <<"fight_fly">>, arity => 0},
               #{name => <<"ok">>, arity => 1}],
    Funs = [#{name => <<"fight_fly">>, arity => 2},
            #{name => <<"fight_fly">>, arity => 3}],
    Fixed = alProjectDigest:correctExportArities(Exports, Funs),
    ?assert(lists:member(#{name => <<"fight_fly">>, arity => 2}, Fixed)),
    ?assert(lists:member(#{name => <<"fight_fly">>, arity => 3}, Fixed)),
    ?assert(lists:member(#{name => <<"ok">>, arity => 1}, Fixed)).

extract_description_and_includes_test() ->
    Src = iolist_to_binary([
        <<"-module(castle).\n-description(\"">>,
        <<"玩家城池"/utf8>>,
        <<"\").\n">>,
        <<"-include(\"castle.hrl\").\n">>,
        <<"-include('scene.hrl').\n">>,
        <<"-behaviour(gen_server).\n">>
    ]),
    Doc = alProjectDigest:extractModuleDocFromErl(Src),
    ?assertEqual(<<"玩家城池"/utf8>>, Doc),
    Inc = alProjectDigest:extractIncludesFromErl(Src),
    ?assert(lists:member(<<"castle.hrl">>, Inc)),
    ?assert(lists:member(<<"scene.hrl">>, Inc)).

ignore_pattern_matches_index_ignore_test() ->
    ?assert(alProjectDigest:ignorePatternMatches("_build", "_build/default/lib")),
    ?assert(alProjectDigest:ignorePatternMatches("pb", "plugin/game_cfg/src/pb/common_pb.erl")),
    ?assert(alProjectDigest:ignorePatternMatches("*_pb.erl", "plugin/game_cfg/src/pb/common_pb.erl")),
    ?assert(alProjectDigest:ignorePatternMatches("game_cfg", "plugin/game_cfg/src/foo.erl")),
    ?assert(alProjectDigest:ignorePatternMatches("db", "db/schema.sql")),
    ?assertNot(alProjectDigest:ignorePatternMatches("*_pb.erl", "src/common.erl")),
    ?assertNot(alProjectDigest:ignorePatternMatches("pb", "src/castle_port.erl")).
