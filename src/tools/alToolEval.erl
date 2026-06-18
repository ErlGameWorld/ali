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
    defaultBlacklist/0,
    isAllowed/3,
    isBlacklisted/3
]).

-define(DEFAULT_TIMEOUT, 60000).
-define(MAX_OUTPUT, 8192).

%% @doc 内置默认禁止执行的 {模块, 函数, 元数} 列表。
-spec defaultBlacklist() -> [{module(), atom(), non_neg_integer()}].
defaultBlacklist() ->
    [
        {os, cmd, 1},
        {os, cmd, 2},
        {os, execute, 2}
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
    Extra = case application:get_env(ali, execBlacklist) of
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
    FunArgs = maps:get(args, Args, []),
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
        {'DOWN', Pid, process, _, Reason} ->
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
toAtom(X) when is_binary(X) -> binary_to_atom(X, utf8);
toAtom(X) when is_list(X) -> list_to_atom(X).
