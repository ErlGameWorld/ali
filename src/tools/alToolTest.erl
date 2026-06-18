%%%-------------------------------------------------------------------
%%% @doc EUnit 测试执行与生成工具。
%%%
%%% 通过 rebar3 eunit 运行测试、为目标模块生成冒烟测试骨架，
%%% 并列举项目中可用的测试模块。
%%% @end
%%%-------------------------------------------------------------------
-module(alToolTest).

-export([
    runEunit/2,
    generateEunit/2,
    runCommonTest/2,
    generateCommonTest/2,
    listTestModules/2,
    %% 导出供单元测试直接调用
    render_eunit_test/2,
    build_ct_cases/1,
    ct_case_name/2
]).

-define(MAX_OUTPUT, 12000).

%% @doc 在项目根执行 rebar3 eunit（可按 module 过滤），返回退出码与输出。
-spec runEunit(map(), map()) -> {ok, map()} | {error, term()}.
runEunit(Args, Config) ->
    Root = project_root(Config),
    Module = maps:get(module, Args, all),
    Timeout = maps:get(timeout, Args, 120000),
    Cmd = build_eunit_cmd(Module),
    Started = erlang:monotonic_time(millisecond),
    case run_command(Cmd, Root, Timeout) of
        {ok, {ExitCode, Output}} ->
            Elapsed = erlang:monotonic_time(millisecond) - Started,
            {ok, #{
                exitCode => ExitCode,
                success => ExitCode =:= 0,
                elapsedMs => Elapsed,
                output => truncate(Output)
            }};
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc 在项目根执行 rebar3 ct（可按 suite 过滤）。
-spec runCommonTest(map(), map()) -> {ok, map()} | {error, term()}.
runCommonTest(Args, Config) ->
    Root = project_root(Config),
    Suite = maps:get(suite, Args, all),
    Timeout = maps:get(timeout, Args, 300000),
    Cmd = build_ct_cmd(Suite),
    Started = erlang:monotonic_time(millisecond),
    case run_command(Cmd, Root, Timeout) of
        {ok, {ExitCode, Output}} ->
            Elapsed = erlang:monotonic_time(millisecond) - Started,
            {ok, #{
                exitCode => ExitCode,
                success => ExitCode =:= 0,
                elapsedMs => Elapsed,
                output => truncate(Output)
            }};
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc 为目标模块生成 Common Test 套件骨架到 test/ 目录。
%%
%% 基于代码索引的导出函数生成针对性测试用例（0 元函数调用并断言返回 term，
%% 其余生成 todo 占位）；索引不可用时回退到最小冒烟测试。
-spec generateCommonTest(map(), map()) -> {ok, map()} | {error, term()}.
generateCommonTest(Args, Config) ->
    Mod = to_atom(maps:get(module, Args, undefined)),
    case Mod of
        undefined -> {error, missingModule};
        _ ->
            Root = project_root(Config),
            SuiteMod = list_to_atom(atom_to_list(Mod) ++ "_agent_ct_SUITE"),
            File = filename:join(Root, "test/" ++ atom_to_list(SuiteMod) ++ ".erl"),
            Exports = fetch_exports(Mod, Config),
            Content = render_ct_suite(SuiteMod, Mod, Exports),
            ok = filelib:ensure_dir(File),
            case file:write_file(File, Content) of
                ok ->
                    {ok, #{
                        suite => SuiteMod,
                        target => Mod,
                        path => File,
                        bytes => byte_size(Content),
                        exportedFunctionsCovered => length(Exports),
                        hint => <<"Run runCommonTest with suite set to this module or use 'all'"/utf8>>
                    }};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

%% @doc 为目标模块生成 `Mod_agent_gen_test` EUnit 文件到 test/ 目录。
%%
%% 生成策略：先尝试基于代码索引的导出函数生成针对性测试（每个 0 元函数
%% 生成一个 `_test` 断言其返回值为 term；其余生成占位待办测试）；
%% 若索引不可用则回退到最小冒烟测试。
-spec generateEunit(map(), map()) -> {ok, map()} | {error, term()}.
generateEunit(Args, Config) ->
    Mod = to_atom(maps:get(module, Args, undefined)),
    case Mod of
        undefined -> {error, missingModule};
        _ ->
            Root = project_root(Config),
            TestMod = list_to_atom(atom_to_list(Mod) ++ "_agent_gen_test"),
            File = filename:join(Root, "test/" ++ atom_to_list(TestMod) ++ ".erl"),
            Exports = fetch_exports(Mod, Config),
            Content = render_test_module(TestMod, Mod, Exports),
            ok = filelib:ensure_dir(File),
            case file:write_file(File, Content) of
                ok ->
                    {ok, #{
                        module => TestMod,
                        target => Mod,
                        path => File,
                        bytes => byte_size(Content),
                        exportedFunctionsCovered => length(Exports),
                        hint => <<"Run runEunit with module set to this test module or use 'all'"/utf8>>
                    }};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

%% 从代码索引获取目标模块的导出函数列表（{Name, Arity}）。
%% 索引不可用时返回空列表，调用方回退到冒烟测试。
fetch_exports(Mod, _Config) ->
    case alCodeIndexer:lookup_module(Mod) of
        {ok, #{exports := Exports}} when is_list(Exports) -> Exports;
        _ -> []
    end.

%% @doc 列举 test/ 及 _build 下所有 *_test.erl / *Tests.erl 模块名。
-spec listTestModules(map(), map()) -> {ok, map()}.
listTestModules(_Args, Config) ->
    Root = project_root(Config),
    Dirs = lists:usort([filename:join(Root, "test") | extra_test_dirs(Root)]),
    Files = lists:usort(lists:flatmap(fun collect_test_files/1, Dirs)),
    Modules = [list_to_atom(filename:basename(F, ".erl")) || F <- Files],
    {ok, #{count => length(Modules), modules => Modules, root => Root}}.

%% 收集 rebar3 构建产物中的 test 目录。
extra_test_dirs(Root) ->
    Pattern = filename:join([Root, "_build", "*", "lib", "ali", "test"]),
    case filelib:wildcard(Pattern) of
        [] -> [];
        Dirs -> Dirs
    end.

%% 在目录中 wildcard 测试源文件。
collect_test_files(Dir) ->
    case filelib:is_dir(Dir) of
        true ->
            filelib:wildcard(filename:join(Dir, "*_test.erl")) ++
            filelib:wildcard(filename:join(Dir, "*Tests.erl"));
        false ->
            []
    end.

%% 构建 rebar3 eunit 命令行（全部或单模块）。
build_eunit_cmd(all) ->
    "rebar3 eunit";
build_eunit_cmd(Mod) when is_atom(Mod) ->
    "rebar3 eunit --module=" ++ atom_to_list(Mod).

build_ct_cmd(all) ->
    "rebar3 ct";
build_ct_cmd(Suite) when is_atom(Suite) ->
    "rebar3 ct --suite=" ++ atom_to_list(Suite);
build_ct_cmd(Suite) when is_binary(Suite) ->
    build_ct_cmd(binary_to_atom(Suite, utf8));
build_ct_cmd(Suite) when is_list(Suite) ->
    build_ct_cmd(list_to_atom(Suite)).

%% 渲染 Common Test 套件源码，基于导出函数生成测试用例。
%% 0 元函数生成调用断言；其余生成 todo 占位用例。
render_ct_suite(SuiteMod, Target, Exports) ->
    TestCases = build_ct_cases(Exports),
    AllList = case TestCases of
        [] -> <<"smoke_test"/utf8>>;
        _ ->
            Names = [case C of {N, _} -> N; N -> N end || C <- TestCases],
            iolist_to_binary(lists:join(<<", "/utf8>>, [atom_to_binary(N, utf8) || N <- Names]))
    end,
    Body = case TestCases of
        [] -> render_ct_smoke(Target);
        _ ->
            [render_ct_case(Target, C) || C <- TestCases]
    end,
    iolist_to_binary([
        <<"-module("/utf8>>, atom_to_binary(SuiteMod, utf8), <<").\n\n"/utf8>>,
        <<"-compile(export_all).\n\n"/utf8>>,
        <<"all() -> ["/utf8>>, AllList, <<"].\n\n"/utf8>>,
        Body,
        <<".\n"/utf8>>
    ]).

%% 为每个导出函数构造 Common Test 用例名与调用信息。
build_ct_cases(Exports) ->
    [{ct_case_name(Name, Arity), {Name, Arity}} || {Name, Arity} <- Exports,
                                                   is_atom(Name), is_integer(Arity)].

%% 生成单个 Common Test 用例函数体。
render_ct_case(Target, {CaseName, {Name, 0}}) ->
    iolist_to_binary([
        atom_to_binary(CaseName, utf8), <<"(_Config) ->\n"/utf8>>,
        <<"    Result = "/utf8>>, atom_to_binary(Target, utf8), <<":"/utf8>>,
        atom_to_binary(Name, utf8), <<"(),\n"/utf8>>,
        <<"    true = is_tuple(Result) orelse is_list(Result) orelse is_atom(Result)\n"/utf8>>,
        <<"           orelse is_integer(Result) orelse is_binary(Result) orelse is_map(Result),\n"/utf8>>,
        <<"    ok.\n\n"/utf8>>
    ]);
render_ct_case(Target, {CaseName, {Name, Arity}}) when Arity > 0 ->
    iolist_to_binary([
        atom_to_binary(CaseName, utf8), <<"(_Config) ->\n"/utf8>>,
        <<"    {skip, \"TODO: provide arguments for "/utf8>>,
        atom_to_binary(Target, utf8), <<":"/utf8>>, atom_to_binary(Name, utf8),
        <<"/"/utf8>>, integer_to_binary(Arity), <<"\"}.\n\n"/utf8>>
    ]).

%% 渲染最小冒烟测试（无导出信息时回退）。
render_ct_smoke(Target) ->
    iolist_to_binary([
        <<"smoke_test(_Config) ->\n"/utf8>>,
        <<"    true = is_atom("/utf8>>, atom_to_binary(Target, utf8), <<"),\n"/utf8>>,
        <<"    ok.\n"/utf8>>
    ]).

%% 由函数名与 arity 构造合法的 CT 用例原子名。
ct_case_name(Name, Arity) ->
    list_to_atom(atom_to_list(Name) ++ "_" ++ integer_to_list(Arity) ++ "_test").

%% 在指定工作目录启动 shell 命令并收集 stdout/stderr 与退出码。
run_command(Cmd, Cwd, Timeout) ->
    ShellCmd = shell_cmd(Cmd),
    Port = open_port({spawn, ShellCmd}, [
        stream,
        exit_status,
        stderr_to_stdout,
        binary,
        {cd, Cwd}
    ]),
    collect_port(Port, <<>>, Timeout).

%% Windows 下通过 cmd /c 执行命令。
shell_cmd(Cmd) ->
    case os:type() of
        {win32, _} -> "cmd /c " ++ Cmd;
        _ -> Cmd
    end.

%% 端口读取入口：超时为 0 时立即关闭。
collect_port(Port, _Acc, Timeout) when Timeout =< 0 ->
    port_close(Port),
    {error, timeout};
collect_port(Port, Acc, Timeout) ->
    collect_port_deadline(Port, Acc, erlang:monotonic_time(millisecond) + Timeout).

%% 按绝对截止时间从 port 收集输出直至 eof 或 exit_status。
collect_port_deadline(Port, Acc, Deadline) ->
    Now = erlang:monotonic_time(millisecond),
    case Deadline > Now of
        false ->
            {error, timeout};
        true ->
            Remaining = Deadline - Now,
            receive
                {Port, {data, Data}} ->
                    collect_port_deadline(Port, <<Acc/binary, Data/binary>>, Deadline);
                {Port, eof} ->
                    ok;
                {Port, {exit_status, Code}} ->
                    {ok, {Code, Acc}}
            after Remaining ->
                {error, timeout}
            end
    end.

%% 渲染 EUnit 测试模块源码，基于导出函数生成测试用例。
%% 0 元函数生成调用断言；其余生成待办占位。
render_test_module(TestMod, Target, Exports) ->
    Tests = build_eunit_tests(Target, Exports),
    Body = case Tests of
        [] -> render_smoke_test(Target);
        _ -> Tests
    end,
    iolist_to_binary([
        <<"-module("/utf8>>, atom_to_binary(TestMod, utf8), <<").\n\n"/utf8>>,
        <<"-include_lib(\"eunit/include/eunit.hrl\").\n\n"/utf8>>,
        Body,
        <<".\n"/utf8>>
    ]).

%% 为每个导出函数构造 EUnit 测试生成器代码片段。
build_eunit_tests(Target, Exports) ->
    [render_eunit_test(Target, {Name, Arity}) || {Name, Arity} <- Exports,
                                                  is_atom(Name), is_integer(Arity)].

%% 0 元函数：调用并断言返回值是合法 term。
render_eunit_test(Target, {Name, 0}) ->
    iolist_to_binary([
        atom_to_binary(Name, utf8), <<"_test() ->\n"/utf8>>,
        <<"    Result = "/utf8>>, atom_to_binary(Target, utf8), <<":"/utf8>>,
        atom_to_binary(Name, utf8), <<"(),\n"/utf8>>,
        <<"    ?assert(is_tuple(Result) orelse is_list(Result) orelse is_atom(Result)\n"/utf8>>,
        <<"           orelse is_integer(Result) orelse is_binary(Result) orelse is_map(Result)).\n\n"/utf8>>
    ]);
%% 多元函数：生成待办占位测试，提示用户补充参数。
render_eunit_test(Target, {Name, Arity}) when Arity > 0 ->
    iolist_to_binary([
        atom_to_binary(Name, utf8), <<"_"/utf8>>, integer_to_binary(Arity),
        <<"_test() ->\n"/utf8>>,
        <<"    {skip, \"TODO: provide arguments for "/utf8>>,
        atom_to_binary(Target, utf8), <<":"/utf8>>, atom_to_binary(Name, utf8),
        <<"/"/utf8>>, integer_to_binary(Arity), <<"\"}.\n\n"/utf8>>
    ]).

%% 渲染最小冒烟测试（无导出信息时回退）。
render_smoke_test(Target) ->
    iolist_to_binary([
        <<"smoke_test() ->\n"/utf8>>,
        <<"    ?assert(is_atom("/utf8>>, atom_to_binary(Target, utf8), <<")).\n"/utf8>>
    ]).

%% 截断过长的命令输出。
truncate(Bin) when byte_size(Bin) > ?MAX_OUTPUT ->
    binary:part(Bin, 0, ?MAX_OUTPUT);
truncate(Bin) ->
    Bin.

%% 从配置解析项目根路径。
project_root(Config) ->
    case maps:get(projectRoot, Config, undefined) of
        undefined -> alToolProject:findProjectRootFromModule();
        Root -> filename:absname(to_list(Root))
    end.

to_list(X) when is_binary(X) -> binary_to_list(X);
to_list(X) when is_list(X) -> X;
to_list(X) when is_atom(X) -> atom_to_list(X).

to_atom(X) when is_atom(X) -> X;
to_atom(X) when is_binary(X) -> binary_to_atom(X, utf8);
to_atom(X) when is_list(X) -> list_to_atom(X).