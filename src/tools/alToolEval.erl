%%%-------------------------------------------------------------------
%%% @doc 受控 Erlang 函数调用工具。
%%%
%%% 在独立进程中执行 `apply/3`，带超时与输出截断。
%%% 默认允许调用任意 MFA，仅 {@link execBlacklist} 与内置
%%% {@link defaultBlacklist/0} 中的条目会被拒绝。
%%% @end
%%%-------------------------------------------------------------------
-module(alToolEval).

-export([
    callFunction/2,
    coerceCallArg/1,
    defaultBlacklist/0,
    isAllowed/3,
    isBlacklisted/3
]).

-define(DEFAULT_TIMEOUT, 60000).
-define(MAX_OUTPUT, 8192).

%% @doc 内置默认禁止执行的 {模块, 函数, 元数} 列表。
%% 采用黑名单策略：仅拦截已知高危 MFA，其余由策略引擎与模式（ask/edit/exec）约束。
-spec defaultBlacklist() -> [{module(), atom(), non_neg_integer()}].
defaultBlacklist() ->
    [
        %% 子进程 / Shell
        {os, cmd, 1},
        {os, cmd, 2},
        {os, execute, 2},
        {os, putenv, 2},
        {os, unsetenv, 1},
        %% 节点 / OTP 生命周期
        {erlang, halt, 0},
        {erlang, halt, 1},
        {erlang, halt, 2},
        {erlang, system_shutdown, 0},
        {erlang, system_shutdown, 1},
        {erlang, disconnect_node, 1},
        {init, stop, 0},
        {init, restart, 0},
        {init, reboot, 0},
        {net_kernel, stop, 0},
        {application, stop, 1},
        {application, unload, 1},
        %% 文件系统破坏
        {file, delete, 1},
        {file, del_dir, 1},
        {file, del_dir_r, 1},
        {file, write_file, 2},
        {file, write_file, 3},
        {file, copy, 2},
        {file, rename, 2},
        {file, change_mode, 2},
        {rpc, call, 4},
        {rpc, call, 5},
        {rpc, multicall, 3},
        {rpc, multicall, 4},
        {erlang, spawn, 1},
        {erlang, spawn, 2},
        {erlang, spawn, 3},
        {erlang, spawn_link, 1},
        {erlang, spawn_link, 2},
        {erlang, spawn_link, 3},
        {erlang, open_port, 2},
        {erlang, open_port, 3},
        {application, set_env, 3},
        {application, set_env, 4},
        {persistent_term, put, 2},
        {persistent_term, erase, 1},
        {ssl, connect, 3},
        {ssl, connect, 4},
        {inet, connect, 3},
        {gen_tcp, connect, 3},
        {gen_tcp, connect, 4},
        {gen_udp, open, 1},
        {gen_udp, open, 2},
        %% 代码卸载
        {code, delete, 1},
        {code, purge, 1},
        {code, soft_purge, 1}
    ].

%% @doc 判断 {Mod, Fun, Arity} 是否允许执行（不在黑名单内）。
-spec isAllowed(module(), atom(), non_neg_integer()) -> boolean().
isAllowed(Mod, Fun, Arity) ->
    not isBlacklisted(Mod, Fun, Arity).

%% @doc 判断 {Mod, Fun, Arity} 是否在有效黑名单内。
-spec isBlacklisted(module(), atom(), non_neg_integer()) -> boolean().
isBlacklisted(Mod, Fun, Arity) ->
    lists:member({Mod, Fun, Arity}, effectiveBlacklist()).

%% 内置黑名单与配置项 `execBlacklist` 合并（去重）。
effectiveBlacklist() ->
    Extra = case aliCfg:getV(execBlacklist) of
        {ok, BL} when is_list(BL) -> parseMfaList(BL);
        undefined -> [];
        BL when is_list(BL) -> parseMfaList(BL)
    end,
    lists:usort(defaultBlacklist() ++ Extra).

%% 将配置中的黑名单项规范为 {M, F, A} 三元组。
parseMfaList(List) ->
    lists:filtermap(fun
        ({M, F, A}) when is_atom(M), is_atom(F), is_integer(A) -> {true, {M, F, A}};
        ({M, F}) when is_atom(M), is_atom(F) -> {true, {M, F, 0}};
        (_) -> false
    end, List).

%% @doc 校验非黑名单后调用指定模块函数并返回 JSON 友好结果。
-spec callFunction(map(), map()) -> {ok, map()} | {error, term()}.
callFunction(Args, Config) ->
    Mod = toAtom(maps:get(module, Args, undefined)),
    Fun = toAtom(maps:get(function, Args, undefined)),
    RawArgs = maps:get(args, Args, []),
    FunArgs = coerceCallArgs(RawArgs),
    Timeout = maps:get(execTimeout, Config, maps:get(timeout, Config, ?DEFAULT_TIMEOUT)),
    case {Mod, Fun} of
        {undefined, _} -> {error, missingModule};
        {_, undefined} -> {error, missingFunction};
        _ ->
            Arity = length(FunArgs),
            case isAllowed(Mod, Fun, Arity) of
                false ->
                    {error, blacklisted};
                true ->
                    executeCall(Mod, Fun, FunArgs, Timeout)
            end
    end.

%% 在监控子进程中执行 apply，主进程等待结果或超时。
executeCall(Mod, Fun, Args, Timeout) ->
    Parent = self(),
    MsgRef = make_ref(),
    {Pid, MonRef} = spawn_monitor(fun() ->
        Parent ! {MsgRef, safeApply(Mod, Fun, Args)}
    end),
    receive
        {MsgRef, Result} ->
            demonitor(MonRef, [flush]),
            formatResult(Result);
        {'DOWN', MonRef, process, _, Reason} ->
            receive {MsgRef, _} -> ok after 0 -> ok end,
            {error, {crashed, Reason}}
    after Timeout ->
        exit(Pid, kill),
        demonitor(MonRef, [flush]),
        %% 清理竞态: kill 后可能仍有路径上的消息残留
        receive
            {MsgRef, _} -> ok
        after 0 -> ok
        end,
        {error, timeout}
    end.

%% 捕获 apply 过程中的异常并包装为 error map。
safeApply(Mod, Fun, Args) ->
    try
        apply(Mod, Fun, Args)
    catch
        Class:Reason:Stack ->
            {error, #{class => Class, reason => Reason, stack => truncateStack(Stack)}}
    end.

%% 将执行结果格式化为 {ok, #{ok => ..., value|error => ...}}。
formatResult({error, Err}) ->
    {ok, #{ok => false, error => llmJson:sanitize(truncateTerm(Err))}};
formatResult(Value) ->
    {ok, #{ok => true, value => llmJson:sanitize(truncateTerm(Value))}}.

%% 将 callFunction 的 JSON args 转为 Erlang 术语（atom/pid/数值等）。
-spec coerceCallArgs(term()) -> term().
coerceCallArgs(List) when is_list(List) ->
    [coerceCallArg(A) || A <- List];
coerceCallArgs(Other) ->
    coerceCallArg(Other).

-spec coerceCallArg(term()) -> term().
coerceCallArg(V) when is_atom(V); is_integer(V); is_float(V); is_boolean(V); is_pid(V); is_reference(V) ->
    V;
coerceCallArg(V) when is_map(V) ->
    maps:map(fun(_, X) -> coerceCallArg(X) end, V);
coerceCallArg(V) when is_list(V) ->
    case io_lib:printable_unicode_list(V) of
        true -> coerceBinaryArg(llmJson:text(V));
        false -> [coerceCallArg(X) || X <- V]
    end;
coerceCallArg(V) when is_binary(V) ->
    coerceBinaryArg(V);
coerceCallArg(null) ->
    null;
coerceCallArg(V) ->
    coerceBinaryArg(llmJson:text(V)).

coerceBinaryArg(Bin) ->
    case maybePid(Bin) of
        {ok, Pid} ->
            Pid;
        error ->
            case maybeNumber(Bin) of
                {ok, Num} ->
                    Num;
                error ->
                    case isAtomLike(Bin) of
                        true -> toExistingOrNewAtom(Bin);
                        false -> Bin
                    end
            end
    end.

maybePid(Bin) ->
    Str = binary_to_list(Bin),
    case Str of
        "<" ++ _ ->
            try {ok, list_to_pid(Str)} catch _:_ -> error end;
        _ ->
            error
    end.

maybeNumber(Bin) ->
    Str = binary_to_list(Bin),
    case Str of
        [$- | Rest] when Rest =/= [] ->
            maybeUnsignedNumber(list_to_binary(Rest), true);
        _ ->
            maybeUnsignedNumber(Bin, false)
    end.

maybeUnsignedNumber(Bin, Negative) ->
    case binary:match(Bin, <<".">>) of
        nomatch ->
            try
                I = binary_to_integer(Bin),
                {ok, case Negative of true -> -I; false -> I end}
            catch _:_ ->
                error
            end;
        _ ->
            try
                F = binary_to_float(Bin),
                {ok, case Negative of true -> -F; false -> F end}
            catch _:_ ->
                error
            end
    end.

isAtomLike(Bin) ->
    case Bin of
        <<C, Rest/binary>> when C >= $a, C =< $z ->
            atomLikeTail(Rest);
        _ ->
            false
    end.

atomLikeTail(<<>>) ->
    true;
atomLikeTail(<<C, Rest/binary>>) when (C >= $a andalso C =< $z);
                                       (C >= $A andalso C =< $Z);
                                       (C >= $0 andalso C =< $9);
                                       C =:= $_ ->
    atomLikeTail(Rest);
atomLikeTail(_) ->
    false.

toExistingOrNewAtom(Bin) ->
    try binary_to_existing_atom(Bin, utf8)
    catch error:badarg -> Bin
    end.

%% 截断调用栈深度。
truncateStack(Stack) ->
    lists:sublist(Stack, 10).

%% 截断过大的返回值/错误项。
truncateTerm(Term) ->
    Bin = list_to_binary(io_lib:format("~p", [Term])),
    case byte_size(Bin) > ?MAX_OUTPUT of
        true ->
            #{truncated => true, preview => binary:part(Bin, 0, ?MAX_OUTPUT)};
        false ->
            Term
    end.

%% 将参数转为 atom。
toAtom(undefined) -> undefined;
toAtom(X) when is_atom(X) -> X;
toAtom(X) when is_binary(X) ->
    try binary_to_existing_atom(X, utf8) catch _:_ -> undefined end;
toAtom(X) when is_list(X) ->
    try binary_to_existing_atom(llmJson:text(X), utf8) catch _:_ -> undefined end.
