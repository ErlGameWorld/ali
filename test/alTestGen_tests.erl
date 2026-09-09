%%% @doc EUnit tests for alTestGen skeleton generator.
-module(alTestGen_tests).

-include_lib("eunit/include/eunit.hrl").

%% 对已知模块生成骨架：头部、module_loaded、导出函数测试名齐全。
generate_known_module_test() ->
    {ok, #{module := Module, code := Code, functions := N, tests := T}} =
        alTestGen:generate(alWebSec),
    ?assertEqual(alWebSec, Module),
    ?assert(N > 0),
    ?assert(T =:= N + 1),
    ?assertMatch({_, B} when is_binary(B), {code, Code}),
    ?assert(binary:match(Code, <<"-module(alWebSec_tests).">>) =/= nomatch),
    ?assert(binary:match(Code, <<"module_loaded_test() ->">>) =/= nomatch),
    %% constantEq 是 alWebSec 的导出函数，应生成对应测试
    ?assert(binary:match(Code, <<"constantEq_test() ->">>) =/= nomatch).

%% 同名多 arity 函数（如 corsHeaders/1、corsHeaders/2）追加 arity 消歧。
generate_multi_arity_disambiguate_test() ->
    {ok, #{code := Code}} = alTestGen:generate(alWebSec),
    ?assert(binary:match(Code, <<"corsHeaders_1_test() ->">>) =/= nomatch),
    ?assert(binary:match(Code, <<"corsHeaders_2_test() ->">>) =/= nomatch),
    ?assert(binary:match(Code, <<"corsHeaders_test() ->">>) =:= nomatch).

%% binary 模块名同样可用。
generate_binary_module_test() ->
    {ok, #{module := alJson}} = alTestGen:generate(<<"alJson">>).

%% 未加载/不存在的模块返回错误。
generate_missing_module_test() ->
    {error, #{reason := _}} = alTestGen:generate(no_such_module_xyz),
    {error, #{reason := _}} = alTestGen:generate(<<"no_such_module_xyz">>).

%% 缺少 module 参数返回错误。
generate_missing_args_test() ->
    {error, #{reason := missingModule}} = alTestGen:generate(#{}).

%% exclude 列表过滤对应函数。
generate_exclude_test() ->
    {ok, #{code := Code}} = alTestGen:generate(alWebSec, #{exclude => [constantEq]}),
    ?assert(binary:match(Code, <<"constantEq_test() ->">>) =:= nomatch),
    ?assert(binary:match(Code, <<"module_loaded_test() ->">>) =/= nomatch).

%% 0-arity 导出函数生成真实调用冒烟，高 arity 函数生成占位。
generate_zero_arity_smoke_test() ->
    {ok, #{code := Code}} = alTestGen:generate(alWebSec),
    ?assert(binary:match(Code, <<"securityHeaders_test() ->">>) =/= nomatch),
    ?assert(binary:match(Code, <<"?assertMatch(_, catch alWebSec:securityHeaders()).">>) =/= nomatch),
    %% 高 arity 函数（如 constantEq/2）生成占位断言
    ?assert(binary:match(Code, <<"?assert(true).">>) =/= nomatch).

%% 生成骨架可被真实编译（epp 处理 include_lib 与 ?assert 宏）。
generate_parseable_test() ->
    {ok, #{code := Code}} = alTestGen:generate(alWebSec),
    TmpFile = filename:join(".", "alTestGen_parse_tmp.erl"),
    ok = file:write_file(TmpFile, Code),
    try
        case compile:file(TmpFile, [binary, return_errors, no_core]) of
            {ok, _Beam, _Warnings} -> ok;
            {error, Errors, _Warnings} -> erlang:error({compileFailed, Errors})
        end
    after
        _ = file:delete(TmpFile)
    end.

%% 建议输出路径符合项目测试文件命名约定。
generate_suggested_path_test() ->
    {ok, #{suggestedPath := Path}} = alTestGen:generate(alWebSec),
    ?assertEqual("test/alWebSec_tests.erl", Path).
