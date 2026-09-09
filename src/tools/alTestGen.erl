%%%-------------------------------------------------------------------
%% @doc EUnit 测试骨架生成器。
%%
%% 从已加载模块的 BEAM abstract code 提取导出函数，生成对应模块的
%% EUnit 测试骨架源码（`<Module>_tests.erl'）。骨架保证可编译可运行：
%% - `module_loaded_test'：模块加载冒烟测试
%% - 每个导出函数一个 `_test' 函数，0-arity 函数附带真实调用冒烟
%% - 其余函数以 `?assert(true)' 占位，用户在此基础上补充真实断言
%%
%% 生成器本身只读（不写文件），LLM 可结合 writeFile 落盘。
%% @end
%%%-------------------------------------------------------------------
-module(alTestGen).

-export([generate/1, generate/2, ensureModuleAtom/1, toBinary/1]).

%%--------------------------------------------------------------------
%% @doc
%% 生成测试骨架：从 Args 中读取 module 并生成。
%%
%% Args 支持：
%%   - `module'：模块名（atom 或 binary，必填）
%%   - `exclude'：跳过生成的函数名列表（atom/binary），可选
%%
%% @param Args 参数 map
%% @return `{ok, #{module, code, functions, tests, suggestedPath}}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
generate(Args) when is_map(Args) ->
    case maps:get(module, Args, undefined) of
        undefined -> {error, #{reason => missingModule}};
        Module0 -> generate(Module0, Args)
    end;
generate(Module0) ->
    generate(Module0, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 按模块名生成测试骨架，Opts 可含 exclude 列表。
%%
%% @param Module0 模块名（atom 或 binary）
%% @param Opts 选项 map（exclude 等）
%% @return `{ok, map()}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
generate(Module0, Opts) when is_map(Opts) ->
    case ensureModuleAtom(Module0) of
        {ok, Module} ->
            case alToolsExt:getBeamAbstract(Module) of
                {ok, #{forms := Forms}} ->
                    buildSkeleton(Module, Forms, Opts);
                {error, Reason} ->
                    {error, #{reason => Reason}}
            end;
        error ->
            {error, #{reason => invalidModule}}
    end;
generate(Module0, _Opts) ->
    case ensureModuleAtom(Module0) of
        {ok, Module} -> generate(Module, #{});
        error -> {error, #{reason => invalidModule}}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 将输入规范化为已存在的模块原子；binary 转 atom、atom 原样返回。
%% 转换失败（原子不存在）返回 `error'，避免动态创建原子。
%%
%% @param Module0 模块名（atom 或 binary）
%% @return `{ok, atom()}' | `error'
%% @end
%%--------------------------------------------------------------------
ensureModuleAtom(Module) when is_atom(Module) ->
    case code:which(Module) of
        non_existing -> error;
        _ -> {ok, Module}
    end;
ensureModuleAtom(Module) when is_binary(Module) ->
    try binary_to_existing_atom(Module, utf8) of
        Atom -> ensureModuleAtom(Atom)
    catch
        _:_ -> error
    end;
ensureModuleAtom(_) ->
    error.

%% 从 abstract forms 构建测试骨架源码。
buildSkeleton(Module, Forms, Opts) ->
    Exports = lists:usort(collectExports(Forms)),
    Excluded = normalizeExcludes(maps:get(exclude, Opts, [])),
    Targets = [{N, A} || {N, A} <- Exports, not lists:member(N, Excluded)],
    %% 同名多 arity 时测试函数名需追加 arity 消歧（如 corsHeaders/1 与 /2）
    Counts = lists:foldl(
        fun({N, _}, Acc) -> maps:update_with(N, fun(C) -> C + 1 end, 1, Acc) end,
        #{}, Targets),
    ModBin = atom_to_binary(Module, utf8),
    Header = [
        <<"%%% @doc EUnit tests for ", ModBin/binary, " (generated skeleton; fill in assertions).\n">>,
        <<"-module(", ModBin/binary, "_tests).\n">>,
        <<"\n">>,
        <<"-include_lib(\"eunit/include/eunit.hrl\").\n">>,
        <<"\n">>,
        <<"%%%===================================================================\n">>,
        <<"%%% Smoke\n">>,
        <<"%%%===================================================================\n">>,
        <<"\n">>,
        <<"module_loaded_test() ->\n">>,
        <<"    ?assertEqual({module, ", ModBin/binary, "}, code:ensure_loaded(", ModBin/binary, ")).\n">>
    ],
    Bodies = [genTestBody(Module, Name, Arity, maps:get(Name, Counts, 1) > 1)
              || {Name, Arity} <- Targets],
    Code = iolist_to_binary([Header, Bodies]),
    {ok, #{
        module => Module,
        code => Code,
        functions => length(Targets),
        tests => length(Targets) + 1,
        suggestedPath => filename:join("test", atom_to_list(Module) ++ "_tests.erl")
    }}.

%% 提取 `-export([{Name, Arity}, ...]).' 属性中的函数列表。
collectExports(Forms) ->
    lists:append([
        Es
     || {attribute, _, export, Es} <- Forms, is_list(Es)
    ]).

%% 将 exclude 列表归一化为原子集合（binary 转已存在原子，未知名忽略）。
normalizeExcludes(List) when is_list(List) ->
    lists:filtermap(fun
        (N) when is_atom(N) -> {true, N};
        (N) when is_binary(N) ->
            try binary_to_existing_atom(N, utf8) of
                A -> {true, A}
            catch
                _:_ -> false
            end;
        (_) -> false
    end, List);
normalizeExcludes(_) ->
    [].

%% 单个导出函数的测试函数源码。Same 为真（同名多 arity）时，
%% 测试函数名追加 arity 以避免重复定义。
genTestBody(Module, Name, Arity, true) ->
    M = atom_to_binary(Module, utf8),
    N = atom_to_binary(Name, utf8),
    A = integer_to_binary(Arity),
    Suffix = <<"_", A/binary, "_test() ->\n">>,
    [<<"\n", N/binary, Suffix/binary, "    %% TODO: ", M/binary, ":", N/binary, "/", A/binary,
       " — 补充真实参数与断言\n"/utf8>>,
     <<"    ?assert(true).\n">>];
genTestBody(Module, Name, 0, false) ->
    M = atom_to_binary(Module, utf8),
    N = atom_to_binary(Name, utf8),
    [<<"\n", N/binary, "_test() ->\n">>,
     <<"    %% smoke: 0-arity 真实调用（返回值断言按需补充）\n"/utf8>>,
     <<"    ?assertMatch(_, catch ", M/binary, ":", N/binary, "()).\n">>];
genTestBody(Module, Name, Arity, false) ->
    M = atom_to_binary(Module, utf8),
    N = atom_to_binary(Name, utf8),
    A = integer_to_binary(Arity),
    [<<"\n", N/binary, "_test() ->\n">>,
     <<"    %% TODO: ", M/binary, ":", N/binary, "/", A/binary, " — 补充真实参数与断言\n"/utf8>>,
     <<"    ?assert(true).\n">>].

%%--------------------------------------------------------------------
%% @doc
%% 将任意值转为 UTF-8 binary（复用项目约定）。
%%
%% @param V 任意值
%% @return binary()
%% @end
%%--------------------------------------------------------------------
toBinary(V) when is_binary(V) -> V;
toBinary(V) when is_atom(V) -> atom_to_binary(V, utf8);
toBinary(V) when is_list(V) ->
    case unicode:characters_to_binary(V) of
        B when is_binary(B) -> B;
        _ -> iolist_to_binary(io_lib:format("~p", [V]))
    end;
toBinary(V) -> iolist_to_binary(io_lib:format("~p", [V])).
