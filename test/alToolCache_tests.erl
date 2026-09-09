%%% @doc EUnit tests for alToolCache.
-module(alToolCache_tests).

-include_lib("eunit/include/eunit.hrl").

-define(setup, begin ok = alConfig:load(), alToolCache:invalidateForWrite() end).

%%%===================================================================
%%% isCacheable/1
%%%===================================================================

isCacheableWhitelisted_test() ->
    ?assert(alToolCache:isCacheable(indexCode)),
    ?assert(alToolCache:isCacheable(searchCode)),
    ?assert(alToolCache:isCacheable(readFile)).

isCacheableNotWhitelisted_test() ->
    ?assertNot(alToolCache:isCacheable(applyPatch)),
    ?assertNot(alToolCache:isCacheable(writeFile)),
    ?assertNot(alToolCache:isCacheable(runMfa)).

%%%===================================================================
%%% lookup/2 + store/3
%%%===================================================================

lookupMiss_test() ->
    ?setup,
    ?assertEqual(miss, alToolCache:lookup(searchCode, #{query => "nonexistent"})).

storeThenLookup_test() ->
    ?setup,
    Args = #{query => "hello"},
    Result = #{hits => [#{file => "test.erl"}]},
    ok = alToolCache:store(searchCode, Args, Result),
    ?assertEqual({ok, Result}, alToolCache:lookup(searchCode, Args)).

storeNonCacheableIgnored_test() ->
    ?setup,
    ok = alToolCache:store(applyPatch, #{}, #{result => ok}),
    ?assertEqual(miss, alToolCache:lookup(applyPatch, #{})).

%%%===================================================================
%%% invalidateForWrite/0
%%%===================================================================

invalidateClearsCache_test() ->
    ?setup,
    Args = #{query => "test"},
    ok = alToolCache:store(searchCode, Args, #{hits => []}),
    ?assertMatch({ok, _}, alToolCache:lookup(searchCode, Args)),
    alToolCache:invalidateForWrite(),
    ?assertEqual(miss, alToolCache:lookup(searchCode, Args)).

%%%===================================================================
%%% P2-9 精确写失效 invalidateForWrite/1
%%%===================================================================

invalidatePreciseKeepsUnrelatedFileRead_test() ->
    ?setup,
    ReadA = #{path => <<"src/a.erl">>},
    ReadB = #{path => <<"src/b.erl">>},
    ok = alToolCache:store(readFile, ReadA, #{content => <<"a">>}),
    ok = alToolCache:store(readFile, ReadB, #{content => <<"b">>}),
    %% 写 b.erl：b 的读缓存失效，a 的保留
    alToolCache:invalidateForWrite([<<"src/b.erl">>]),
    ?assertEqual(miss, alToolCache:lookup(readFile, ReadB)),
    ?assertMatch({ok, #{content := <<"a">>}}, alToolCache:lookup(readFile, ReadA)).

invalidatePrecisePathNormalization_test() ->
    ?setup,
    %% 缓存正斜杠相对路径，被写路径是反斜杠绝对路径 + ./ 前缀 + 大小写差异
    Read = #{path => <<"src/tools/alToolCache.erl">>},
    ok = alToolCache:store(readFile, Read, #{content => <<"x">>}),
    Written = <<"./SRC\\TOOLS\\AlToolCache.erl">>,
    alToolCache:invalidateForWrite([Written]),
    ?assertEqual(miss, alToolCache:lookup(readFile, Read)).

invalidatePreciseDropsIndexDependent_test() ->
    ?setup,
    %% 索引依赖缓存（searchCode 等）即使路径无关也全部失效
    ReadOther = #{path => <<"src/zzz.erl">>},
    Search = #{query => <<"foo">>},
    ok = alToolCache:store(readFile, ReadOther, #{content => <<"z">>}),
    ok = alToolCache:store(searchCode, Search, #{hits => []}),
    alToolCache:invalidateForWrite([<<"src/b.erl">>]),
    ?assertEqual(miss, alToolCache:lookup(searchCode, Search)),
    ?assertMatch({ok, _}, alToolCache:lookup(readFile, ReadOther)).

invalidatePreciseEmptyPathsFallsBackToFull_test() ->
    ?setup,
    Args = #{query => <<"q">>},
    ok = alToolCache:store(searchCode, Args, #{hits => []}),
    %% 空路径列表：无法定位被写文件，退化为全表清空（保守正确）
    alToolCache:invalidateForWrite([]),
    ?assertEqual(miss, alToolCache:lookup(searchCode, Args)),
    alToolCache:invalidateForWrite(undefined),
    ?assertEqual(miss, alToolCache:lookup(searchCode, Args)).

invalidatePreciseBinaryPathKey_test() ->
    ?setup,
    %% Rust/JSON 路径参数是 binary 键形态
    Read = #{<<"path">> => <<"src/binkey.erl">>},
    ok = alToolCache:store(readFilePage, Read, #{content => <<"b">>}),
    alToolCache:invalidateForWrite([<<"src/binkey.erl">>]),
    ?assertEqual(miss, alToolCache:lookup(readFilePage, Read)).

normalizeCachePath_test() ->
    ?assertEqual(<<"src/a.erl">>, alToolCache:normalizeCachePath(<<"./SRC\\A.erl">>)),
    ?assertEqual(<<"src/a.erl">>, alToolCache:normalizeCachePath("src/a.erl")),
    ?assertEqual(<<"a/b/c.rs">>, alToolCache:normalizeCachePath(<<"A\\B\\C.rs">>)).

%%%===================================================================
%%% stats/0
%%%===================================================================

statsStructure_test() ->
    ?setup,
    Stats = alToolCache:stats(),
    ?assertMatch(#{size := _, maxSize := _, ttlMs := _, whitelist := _}, Stats),
    ?assert(lists:member(searchCode, maps:get(whitelist, Stats))).
