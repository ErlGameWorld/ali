%%%-------------------------------------------------------------------
%% @doc MFA、补丁与编译场景的沙箱模拟。
%% @end
%%%-------------------------------------------------------------------

-module(alSimulator).

-export([run/1, listRecent/1]).

%%--------------------------------------------------------------------
%% @doc
%% 执行一个沙箱模拟场景，并记录执行耗时与结果到本地数据库。
%%
%% @param Scenario 场景映射，至少包含 type 字段
%% @return {ok, ResultMap} | {error, ReasonMap}
%% @end
%%--------------------------------------------------------------------
run(Scenario) when is_map(Scenario) ->
    try
        Started = erlang:system_time(millisecond),
        Result = execute(Scenario),
        Duration = erlang:system_time(millisecond) - Started,
        persist(Scenario, Result, Duration),
        Result
    catch
        Class:Reason ->
            {error, #{class => Class, reason => Reason}}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 根据 type 分派执行具体场景：mfa / patch / compile / askDry。
%%
%% @param Scenario 场景映射
%% @return {ok, ResultMap} | {error, ReasonMap}
%% @end
%%--------------------------------------------------------------------
execute(#{type := mfa} = Scenario) ->
    Module = maps:get(module, Scenario, undefined),
    Function = maps:get(function, Scenario, undefined),
    case {Module, Function} of
        {undefined, _} ->
            {error, #{reason => missingMfa, field => module}};
        {_, undefined} ->
            {error, #{reason => missingMfa, field => function}};
        _ ->
            executeMfa(Scenario, Module, Function)
    end;
execute(#{type := patch} = Scenario) ->
    Patch = maps:get(patch, Scenario, undefined),
    case alPatchManager:dryRun(Patch) of
        {ok, Preview} ->
            {ok, #{type => patch, status => ok, preview => Preview}};
        {error, Reason} ->
            {ok, #{type => patch, status => error, reason => Reason}}
    end;
execute(#{type := compile, file := File, source := Source}) ->
    Temp = tempErlPath(File),
    case filelib:ensure_dir(Temp) of
        ok ->
            case file:write_file(Temp, toBinary(Source)) of
                ok ->
                    Result = compile:file(Temp, [binary, return_errors, return_warnings]),
                    file:delete(Temp),
                    case Result of
                        {ok, Module, _Beam} ->
                            {ok, #{type => compile, status => ok, module => Module, file => Temp}};
                        {ok, Module, _Beam, Warnings} ->
                            {ok, #{type => compile, status => ok, module => Module, warnings => Warnings}};
                        {error, Errors, Warnings} ->
                            {ok, #{type => compile, status => error, errors => Errors, warnings => Warnings}};
                        error ->
                            {ok, #{type => compile, status => error}}
                    end;
                {error, Reason} ->
                    {ok, #{type => compile, status => error, reason => Reason}}
            end;
        {error, Reason} ->
            {ok, #{type => compile, status => error, reason => Reason}}
    end;
execute(#{type := askDry, question := Question} = Scenario) ->
    Opts = maps:get(opts, Scenario, #{tools => false}),
    case alToolRouter:ask(Question, Opts#{autoSession => false}) of
        {ok, Reply} ->
            {ok, #{type => askDry, status => ok, reply => Reply}};
        {error, Reason} ->
            {ok, #{type => askDry, status => error, reason => Reason}}
    end;
execute(Scenario) ->
    {error, #{reason => unknownScenario, scenario => Scenario}}.

executeMfa(Scenario, Module, Function) ->
    Args = maps:get(args, Scenario, []),
    ArgList = case is_list(Args) of true -> Args; false -> [Args] end,
    Arity = length(ArgList),
    ModAtom = toExistingAtom(Module),
    FunAtom = toExistingAtom(Function),
    case {ModAtom, FunAtom} of
        {undefined, _} ->
            {ok, #{type => mfa, status => error, dryRun => true,
                   reason => badModule, hint => <<"Use runMfa for live execution">>}};
        {_, undefined} ->
            {ok, #{type => mfa, status => error, dryRun => true,
                   reason => badFunction, hint => <<"Use runMfa for live execution">>}};
        {M, F} ->
            case code:ensure_loaded(M) of
                {module, M} ->
                    Exported = erlang:function_exported(M, F, Arity),
                    {ok, #{
                        type => mfa,
                        status => ok,
                        dryRun => true,
                        wouldCall => #{module => M, function => F, arity => Arity},
                        exported => Exported,
                        hint => case Exported of
                            true -> <<"Dry-run only. Call runMfa to execute on the live node.">>;
                            false -> <<"Not exported at this arity. Fix MFA before runMfa.">>
                        end
                    }};
                _ ->
                    {ok, #{type => mfa, status => error, dryRun => true,
                           reason => moduleNotLoaded, module => M}}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 查询最近若干条模拟运行记录（按创建时间倒序）。
%%
%% @param Limit 返回条数上限
%% @return {ok, Rows} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
listRecent(Limit) ->
    Sql =
        "SELECT id, scenario_type, input, output, status, created_at "
        "FROM simulation_runs ORDER BY created_at DESC LIMIT ?",
    case alLocalDb:query(Sql, [Limit]) of
        {ok, Rows} -> {ok, Rows};
        Error -> Error
    end.

%% 根据 Result 形态选择对应的状态标签后持久化记录。
persist(Scenario, {ok, Result}, Duration) ->
    persistRecord(Scenario, Result, ok, Duration);
persist(Scenario, {error, Reason}, Duration) ->
    persistRecord(Scenario, Reason, error, Duration);
persist(_Scenario, Result, Duration) ->
    persistRecord(#{type => unknown}, Result, ok, Duration).

%% 将单条模拟运行记录写入 simulation_runs 表。
persistRecord(Scenario, Output, Status, Duration) ->
    Sql =
        "INSERT INTO simulation_runs (scenario_type, input, output, status, created_at) "
        "VALUES (?, ?, ?, ?, ?)",
    %% 落盘前深度脱敏：场景与输出可能含凭据，按敏感键递归打码后再入库。
    SafeScenario = safeSanitize(Scenario),
    SafeOutput = safeSanitize(Output),
    Params = [
        toBinary(maps:get(type, Scenario, unknown)),
        alJson:encode(SafeScenario),
        alJson:encode(#{output => SafeOutput, durationMs => Duration}),
        atom_to_binary(Status, utf8),
        erlang:system_time(second)
    ],
    try alLocalDb:insert(Sql, Params) catch _:_ -> ok end.

%% 安全脱敏：对任意项调用 alPolicy:sanitizeTerm，异常时原样返回。
safeSanitize(Term) ->
    try alPolicy:sanitizeTerm(Term) catch _:_ -> Term end.

%% 为编译场景生成位于用户缓存目录下的临时 .erl 文件路径（带唯一前缀避免冲突）。
tempErlPath(File) ->
    Base = filename:basename(toList(File)),
    filename:join([
        filename:basedir(user_cache, "ali"),
        "sim",
        integer_to_list(erlang:unique_integer([positive])) ++ "_" ++ Base
    ]).

%% 将多种类型的值统一转换为已存在原子（失败返回 undefined）。
toExistingAtom(A) when is_atom(A) -> A;
toExistingAtom(B) when is_binary(B) ->
    try binary_to_existing_atom(B, utf8) catch _:_ -> undefined end;
toExistingAtom(L) when is_list(L) ->
    try list_to_existing_atom(L) catch _:_ -> undefined end;
toExistingAtom(_) -> undefined.

%% 将多种类型的值统一转换为二进制；映射类型使用 JSON 编码。
toBinary(Value) when is_binary(Value) ->
    Value;
toBinary(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
toBinary(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
toBinary(Value) when is_map(Value) ->
    alJson:encode(Value);
toBinary(Value) ->
    unicode:characters_to_binary(io_lib:format("~p", [Value])).

%% 将二进制转换为列表；列表原样返回。
toList(Value) when is_binary(Value) ->
    unicode:characters_to_list(Value);
toList(Value) when is_list(Value) ->
    Value.
