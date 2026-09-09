%%% @doc EUnit tests for alModuleSummary pure helpers.
-module(alModuleSummary_tests).

-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% 关键导出存在性
%%--------------------------------------------------------------------
critical_exports_test() ->
    Exports = alModuleSummary:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{get, 1}, {getOrGenerate, 1}, {generate, 1},
                   {search, 1}, {search, 2}, {invalidate, 1}, {clearCache, 0}]].

%%--------------------------------------------------------------------
%% summaryPrompt/2 — 构造含模块名与函数签名的 prompt
%%--------------------------------------------------------------------
summaryPrompt_contains_module_test() ->
    Prompt = alModuleSummary:summaryPrompt(ali_sup, [#{name => start_link, arity => 0}]),
    ?assert(is_binary(Prompt)),
    ?assert(binary:match(Prompt, <<"ali_sup">>) =/= nomatch).

summaryPrompt_contains_function_signatures_test() ->
    Prompt = alModuleSummary:summaryPrompt(ali_sup,
        [#{name => start_link, arity => 0}, #{name => init, arity => 1}]),
    %% 应包含 start_link/0 与 init/1 签名
    ?assert(binary:match(Prompt, <<"start_link/0">>) =/= nomatch),
    ?assert(binary:match(Prompt, <<"init/1">>) =/= nomatch).

summaryPrompt_empty_functions_test() ->
    Prompt = alModuleSummary:summaryPrompt(ali_sup, []),
    ?assert(is_binary(Prompt)),
    %% 模块名仍应出现
    ?assert(binary:match(Prompt, <<"ali_sup">>) =/= nomatch).

summaryPrompt_caps_function_count_test() ->
    %% 超过 ?MaxFunctionsInPrompt(30) 个函数也应正常生成
    Funs = [#{name => list_to_atom("f" ++ integer_to_list(N)), arity => 1}
            || N <- lists:seq(1, 50)],
    Prompt = alModuleSummary:summaryPrompt(bigMod, Funs),
    ?assert(is_binary(Prompt)),
    %% 前 30 个应出现，第 31+ 个不应出现
    ?assert(binary:match(Prompt, <<"f1/1">>) =/= nomatch),
    ?assert(binary:match(Prompt, <<"f30/1">>) =/= nomatch),
    ?assert(binary:match(Prompt, <<"f31/1">>) =:= nomatch).

%%--------------------------------------------------------------------
%% parseSummary/1 — trim、限长、非法输入
%%--------------------------------------------------------------------
parseSummary_trims_whitespace_test() ->
    ?assertEqual(<<"hello">>, alModuleSummary:parseSummary(<<"  hello  \n">>)).

parseSummary_caps_length_test() ->
    Long = binary:copy(<<"a">>, 1000),
    Result = alModuleSummary:parseSummary(Long),
    %% 限长到 ?MaxSummaryBytes(600)
    ?assertEqual(600, byte_size(Result)).

parseSummary_empty_test() ->
    ?assertEqual(<<>>, alModuleSummary:parseSummary(<<>>)),
    ?assertEqual(<<>>, alModuleSummary:parseSummary(<<"   ">>)).

parseSummary_non_binary_test() ->
    ?assertEqual(<<>>, alModuleSummary:parseSummary(not_a_binary)),
    ?assertEqual(<<>>, alModuleSummary:parseSummary(123)).

%%--------------------------------------------------------------------
%% cacheKey/1 — 归一化为 binary
%%--------------------------------------------------------------------
cacheKey_atom_test() ->
    ?assertEqual(<<"ali_sup">>, alModuleSummary:cacheKey(ali_sup)).

cacheKey_binary_test() ->
    ?assertEqual(<<"ali_sup">>, alModuleSummary:cacheKey(<<"ali_sup">>)).

cacheKey_list_test() ->
    ?assertEqual(<<"ali_sup">>, alModuleSummary:cacheKey("ali_sup")).

%%--------------------------------------------------------------------
%% ensureCacheTable/0 — 幂等建表（ETS 表 owner 为调用进程，仅验证不崩溃）
%%--------------------------------------------------------------------
ensureCacheTable_idempotent_test() ->
    %% 多次调用不应报错，均返回 ok
    ?assertEqual(ok, alModuleSummary:ensureCacheTable()),
    ?assertEqual(ok, alModuleSummary:ensureCacheTable()),
    ?assertEqual(ok, alModuleSummary:ensureCacheTable()).

ensureCacheTable_returns_ok_test() ->
    ?assertEqual(ok, alModuleSummary:ensureCacheTable()).

%%--------------------------------------------------------------------
%% invalidate/1 — 清除缓存项（不报错）
%%--------------------------------------------------------------------
invalidate_no_crash_test() ->
    %% 即使表不存在或键不存在也不应崩溃
    ?assertEqual(ok, alModuleSummary:invalidate(ali_sup)),
    ?assertEqual(ok, alModuleSummary:invalidate(<<"any_module">>)).

clearCache_no_crash_test() ->
    ?assertEqual(ok, alModuleSummary:clearCache()).
