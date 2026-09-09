%%%-------------------------------------------------------------------
%%% @doc 节点内受控执行 AI 写出的 Erlang 表达式 / 匿名 fun。
%%%
%%% 流程：解析 → AST 校验（远程 MFA 复用 {@link alRuntimeProbe:checkMfaAllowed/3}）
%%% → 编译临时模块 → 隔离 apply → 清理。不走裸 erl_eval。
%%% @end
%%%-------------------------------------------------------------------
-module(alEval).

-export([validate/1, validate/2, eval/1, eval/2]).

-define(DefaultTimeout, 5000).

%%--------------------------------------------------------------------
-spec validate(term()) -> {ok, map()} | {error, map()}.
validate(Code) ->
    validate(Code, #{}).

-spec validate(term(), map()) -> {ok, map()} | {error, map()}.
validate(Code, Opts) when is_map(Opts) ->
    case enabled(Opts) of
        false -> {error, #{reason => evalErlDisabled}};
        true ->
            case parseCode(Code) of
                {ok, Exprs} ->
                    case classify(Exprs) of
                        {error, Reason} -> {error, Reason};
                        {ok, Kind, Meta} ->
                            case lintExprs(Exprs, Opts) of
                                {error, Reason} -> {error, Reason};
                                {ok, Lint} ->
                                    case tryCompile(Kind, Exprs, Meta, Opts) of
                                        {ok, CompileInfo} ->
                                            {ok, maps:merge(#{
                                                kind => Kind,
                                                arity => maps:get(arity, Meta, 0),
                                                remoteCalls => maps:get(remoteCalls, Lint, []),
                                                warnings => maps:get(warnings, Lint, [])
                                            }, CompileInfo)};
                                        {error, Reason} ->
                                            {error, Reason}
                                    end
                            end
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end;
validate(Code, _) ->
    validate(Code, #{}).

%%--------------------------------------------------------------------
-spec eval(term()) -> {ok, map()} | {error, map()}.
eval(Code) ->
    eval(Code, #{}).

-spec eval(term(), map()) -> {ok, map()} | {error, map()}.
eval(Code, Opts0) when is_map(Opts0) ->
    Opts = normalizeOpts(Opts0),
    case maps:get(dryRun, Opts, false) of
        true ->
            case validate(Code, Opts) of
                {ok, Report} -> {ok, Report#{dryRun => true, executed => false}};
                Error -> Error
            end;
        false ->
            case enabled(Opts) of
                false -> {error, #{reason => evalErlDisabled}};
                true ->
                    case parseCode(Code) of
                        {ok, Exprs} ->
                            case classify(Exprs) of
                                {error, Reason} -> {error, Reason};
                                {ok, Kind, Meta} ->
                                    case lintExprs(Exprs, Opts) of
                                        {error, Reason} -> {error, Reason};
                                        {ok, Lint} ->
                                            runCompiled(Kind, Exprs, Meta, Lint, Opts)
                                    end
                            end;
                        {error, Reason} ->
                            {error, Reason}
                    end
            end
    end;
eval(Code, _) ->
    eval(Code, #{}).

%%====================================================================
%% parse
%%====================================================================

parseCode(Code0) ->
    Code = toList(Code0),
    case Code of
        "" -> {error, #{reason => emptyCode}};
        _ ->
            case scanAndParse(Code) of
                {ok, Exprs} -> {ok, Exprs};
                {error, _} = E1 ->
                    case endsWithDot(Code) of
                        true -> E1;
                        false ->
                            case scanAndParse(Code ++ ".") of
                                {ok, Exprs} -> {ok, Exprs};
                                {error, _} -> E1
                            end
                    end
            end
    end.

scanAndParse(Code) ->
    case erl_scan:string(Code) of
        {ok, Tokens, _} ->
            case erl_parse:parse_exprs(Tokens) of
                {ok, Exprs} -> {ok, Exprs};
                {error, {Line, Mod, Desc}} ->
                    {error, #{reason => parseError, line => Line,
                              detail => formatParseError(Mod, Desc)}};
                {error, Other} ->
                    {error, #{reason => parseError, detail => Other}}
            end;
        {error, {Line, Mod, Desc}, _} ->
            {error, #{reason => scanError, line => Line,
                      detail => formatParseError(Mod, Desc)}};
        {error, Error, _} ->
            {error, #{reason => scanError, detail => Error}}
    end.

formatParseError(Mod, Desc) ->
    try Mod:format_error(Desc) of
        S when is_list(S) -> list_to_binary(S);
        Other -> Other
    catch _:_ ->
        Desc
    end.

endsWithDot(Code) ->
    case string:trim(Code, trailing) of
        "" -> false;
        S -> lists:last(S) =:= $.
    end.

%%====================================================================
%% classify
%%====================================================================

classify([{'fun', _, {clauses, Clauses}}] = _Exprs) ->
    case funArity(Clauses) of
        {ok, Arity} -> {ok, fun_expr, #{arity => Arity}};
        {error, Reason} -> {error, Reason}
    end;
classify([_ | _] = Exprs) ->
    {ok, expr, #{arity => 0, exprCount => length(Exprs)}};
classify([]) ->
    {error, #{reason => emptyExprs}}.

funArity([]) ->
    {error, #{reason => emptyFunClauses}};
funArity([Clause | Rest]) ->
    Arity = clauseArity(Clause),
    case lists:all(fun(C) -> clauseArity(C) =:= Arity end, Rest) of
        true -> {ok, Arity};
        false -> {error, #{reason => funArityMismatch}}
    end.

clauseArity({clause, _, Patterns, _, _}) ->
    length(Patterns);
clauseArity(_) ->
    0.

%%====================================================================
%% lint
%%====================================================================

lintExprs(Exprs, _Opts) ->
    case walk(Exprs, #{remoteCalls => [], warnings => []}) of
        {error, _} = E -> E;
        {ok, Acc} ->
            case checkRemotes(lists:usort(maps:get(remoteCalls, Acc, []))) of
                {error, Reason} -> {error, Reason};
                ok -> {ok, Acc#{remoteCalls => lists:usort(maps:get(remoteCalls, Acc, []))}}
            end
    end.

checkRemotes([]) ->
    ok;
checkRemotes([{M, F, A} | Rest]) ->
    case alRuntimeProbe:checkMfaAllowed(M, F, A) of
        ok -> checkRemotes(Rest);
        {error, Reason} ->
            {error, Reason#{context => evalErlRemoteCall}}
    end.

walk(List, Acc) when is_list(List) ->
    foldWalk(List, Acc);
walk(Node, Acc) ->
    walkNode(Node, Acc).

foldWalk([], Acc) ->
    {ok, Acc};
foldWalk([H | T], Acc) ->
    case walk(H, Acc) of
        {ok, Acc1} -> foldWalk(T, Acc1);
        Error -> Error
    end.

walkNode({call, _Anno, {remote, _, ModAst, FunAst}, Args}, Acc) ->
    case {atomOf(ModAst), atomOf(FunAst)} of
        {{ok, Mod}, {ok, Fun}} ->
            case isForbiddenRemote(Mod, Fun, length(Args)) of
                true ->
                    {error, #{reason => forbiddenCall, module => Mod, function => Fun,
                              arity => length(Args)}};
                false ->
                    Acc1 = addRemote(Acc, Mod, Fun, length(Args)),
                    walk(Args, Acc1)
            end;
        _ ->
            {error, #{reason => dynamicRemoteCall,
                      hint => <<"Remote MFA must be literal atoms (Mod:Fun(...)).">>}}
    end;
walkNode({call, _Anno, {atom, _, Name}, Args}, Acc) ->
    Arity = length(Args),
    case isForbiddenLocal(Name, Arity) of
        true ->
            {error, #{reason => forbiddenCall, module => erlang, function => Name, arity => Arity}};
        false ->
            %% auto-imported BIF：按 erlang:Name/Arity 走同一策略
            case is_erlang_autoimport(Name, Arity) of
                true ->
                    case isForbiddenRemote(erlang, Name, Arity) of
                        true ->
                            {error, #{reason => forbiddenCall, module => erlang,
                                      function => Name, arity => Arity}};
                        false ->
                            Acc1 = addRemote(Acc, erlang, Name, Arity),
                            walk(Args, Acc1)
                    end;
                false ->
                    %% 临时模块内不应出现未定义本地调用；当作可疑拒绝
                    {error, #{reason => localCallNotAllowed, function => Name, arity => Arity,
                              hint => <<"Use Mod:Fun(...) or a pure expression/fun body.">>}}
            end
    end;
walkNode({call, _Anno, _Callee, _Args}, _Acc) ->
    {error, #{reason => dynamicCall,
              hint => <<"Callee must be Mod:Fun or an auto-imported BIF.">>}};
walkNode({op, _Anno, '!', _L, _R}, _Acc) ->
    {error, #{reason => forbiddenOp, op => '!'}};
walkNode({'receive', _Anno, _Clauses}, _Acc) ->
    {error, #{reason => forbiddenReceive}};
walkNode({'receive', _Anno, _Clauses, _Timeout, _TimeoutBody}, _Acc) ->
    {error, #{reason => forbiddenReceive}};
walkNode({'fun', _Anno, {function, Mod, Name, Arity}}, Acc)
  when is_atom(Mod), is_atom(Name), is_integer(Arity) ->
    %% fun Mod:Name/Arity
    case isForbiddenRemote(Mod, Name, Arity) of
        true -> {error, #{reason => forbiddenCall, module => Mod, function => Name, arity => Arity}};
        false -> {ok, addRemote(Acc, Mod, Name, Arity)}
    end;
walkNode({'fun', _Anno, {function, {atom, _, Mod}, {atom, _, Name}, {integer, _, Arity}}}, Acc) ->
    case isForbiddenRemote(Mod, Name, Arity) of
        true -> {error, #{reason => forbiddenCall, module => Mod, function => Name, arity => Arity}};
        false -> {ok, addRemote(Acc, Mod, Name, Arity)}
    end;
walkNode({'fun', _Anno, {function, _, _, _}}, _Acc) ->
    {error, #{reason => dynamicFunRef}};
walkNode({'fun', _Anno, {clauses, Clauses}}, Acc) ->
    walk(Clauses, Acc);
walkNode({clause, _Anno, Patterns, Guards, Body}, Acc) ->
    case walk(Patterns, Acc) of
        {ok, Acc1} ->
            case walk(Guards, Acc1) of
                {ok, Acc2} -> walk(Body, Acc2);
                Error -> Error
            end;
        Error -> Error
    end;
walkNode(Tuple, Acc) when is_tuple(Tuple) ->
    walk(tuple_to_list(Tuple), Acc);
walkNode(_Leaf, Acc) ->
    {ok, Acc}.

addRemote(Acc, Mod, Fun, Arity) ->
    Calls = maps:get(remoteCalls, Acc, []),
    Acc#{remoteCalls => [{Mod, Fun, Arity} | Calls]}.

atomOf({atom, _, A}) when is_atom(A) -> {ok, A};
atomOf(_) -> error.

%% 静态禁止的危险原语（即使不在 blacklist 配置里也拒）
isForbiddenRemote(os, cmd, _) -> true;
isForbiddenRemote(os, putenv, _) -> true;
isForbiddenRemote(erlang, halt, _) -> true;
isForbiddenRemote(erlang, open_port, _) -> true;
isForbiddenRemote(erlang, apply, _) -> true;
isForbiddenRemote(init, stop, _) -> true;
isForbiddenRemote(init, reboot, _) -> true;
isForbiddenRemote(code, purge, _) -> true;
isForbiddenRemote(code, delete, _) -> true;
isForbiddenRemote(code, load_binary, _) -> true;
isForbiddenRemote(code, load_file, _) -> true;
isForbiddenRemote(code, load_abs, _) -> true;
isForbiddenRemote(code, atomic_load, _) -> true;
isForbiddenRemote(code, soft_purge, _) -> true;
isForbiddenRemote(rpc, call, _) -> true;
isForbiddenRemote(erpc, call, _) -> true;
isForbiddenRemote(file, write_file, _) -> true;
isForbiddenRemote(file, delete, _) -> true;
isForbiddenRemote(_, _, _) -> false.

isForbiddenLocal(apply, A) when A >= 2 -> true;
isForbiddenLocal(spawn, _) -> true;
isForbiddenLocal(spawn_link, _) -> true;
isForbiddenLocal(spawn_monitor, _) -> true;
isForbiddenLocal(spawn_opt, _) -> true;
isForbiddenLocal(open_port, _) -> true;
isForbiddenLocal(halt, _) -> true;
isForbiddenLocal(exit, _) -> true;
isForbiddenLocal(_, _) -> false.

%% 常见可自动导入 BIF（用于表达式里 length/hd 等）；其余本地调用拒绝。
is_erlang_autoimport(Name, Arity) when is_atom(Name), is_integer(Arity) ->
    lists:member({Name, Arity}, erlang:module_info(exports))
        andalso not lists:member(Name, [module_info, apply, spawn, spawn_link,
                                        spawn_monitor, open_port, halt, exit]);
is_erlang_autoimport(_, _) ->
    false.

%%====================================================================
%% compile + run
%%====================================================================

normalizeOpts(Opts) ->
    Dry = case maps:get(dryRun, Opts, maps:get(<<"dryRun">>, Opts, false)) of
        true -> true;
        <<"true">> -> true;
        _ -> false
    end,
    Timeout = toInt(maps:get(timeout, Opts, maps:get(<<"timeout">>, Opts, ?DefaultTimeout)),
                    ?DefaultTimeout),
    Args = case maps:get(args, Opts, maps:get(<<"args">>, Opts, [])) of
        L when is_list(L) -> L;
        _ -> []
    end,
    Bindings = case maps:get(bindings, Opts, maps:get(<<"bindings">>, Opts, #{})) of
        M when is_map(M) -> M;
        _ -> #{}
    end,
    Opts#{dryRun => Dry, timeout => max(1, Timeout), args => Args, bindings => Bindings}.

enabled(Opts) ->
    case maps:get(evalErlEnabled, Opts, undefined) of
        true -> true;
        false -> false;
        _ ->
            case alConfig:get(evalErlEnabled, true) of
                false -> false;
                <<"false">> -> false;
                0 -> false;
                _ -> true
            end
    end.

tryCompile(Kind, Exprs, Meta, Opts) ->
    case buildAndCompile(Kind, Exprs, Meta, Opts) of
        {ok, Mod, _Bin} ->
            ok = unloadTemp(Mod),
            {ok, #{compileOk => true}};
        {error, _} = E ->
            E
    end.

runCompiled(Kind, Exprs, Meta, Lint, Opts) ->
    case buildAndCompile(Kind, Exprs, Meta, Opts) of
        {error, _} = E -> E;
        {ok, Mod, _Bin} ->
            try
                Timeout = maps:get(timeout, Opts, ?DefaultTimeout),
                ApplyArgs = case Kind of
                    fun_expr -> [maps:get(args, Opts, [])];
                    expr -> []
                end,
                FunName = run,
                case alRuntimeProbe:runApplySafe(Mod, FunName, ApplyArgs, Timeout) of
                    {ok, Value} ->
                        {ok, #{
                            kind => Kind,
                            arity => maps:get(arity, Meta, 0),
                            remoteCalls => maps:get(remoteCalls, Lint, []),
                            warnings => maps:get(warnings, Lint, []),
                            result => alPolicy:sanitizeTerm(Value),
                            executed => true
                        }};
                    {error, timeout} ->
                        {error, #{reason => timeout, timeoutMs => Timeout}};
                    {error, Reason} when is_map(Reason) ->
                        {error, Reason#{reason => maps:get(reason, Reason, applyFailed)}};
                    {error, Reason} ->
                        {error, #{reason => applyFailed, detail => Reason}}
                end
            after
                unloadTemp(Mod)
            end
    end.

buildAndCompile(Kind, Exprs, Meta, Opts) ->
    _ = application:ensure_all_started(compiler),
    Mod = tempModuleName(),
    Bindings = maps:get(bindings, Opts, #{}),
    Forms = case Kind of
        expr -> wrapExprForms(Mod, Exprs, Bindings);
        fun_expr -> wrapFunForms(Mod, Exprs, maps:get(arity, Meta, 0), Bindings)
    end,
    case compile:forms(Forms, [return_errors, return_warnings, binary]) of
        {ok, Mod, Bin} ->
            code:purge(Mod),
            case code:load_binary(Mod, atom_to_list(Mod) ++ ".alEval", Bin) of
                {module, Mod} -> {ok, Mod, Bin};
                {error, What} -> {error, #{reason => loadFailed, detail => What}}
            end;
        {ok, Mod, Bin, _Warn} ->
            code:purge(Mod),
            case code:load_binary(Mod, atom_to_list(Mod) ++ ".alEval", Bin) of
                {module, Mod} -> {ok, Mod, Bin};
                {error, What} -> {error, #{reason => loadFailed, detail => What}}
            end;
        {error, Errors, Warnings} ->
            {error, #{reason => compileError, errors => Errors, warnings => Warnings}};
        error ->
            {error, #{reason => compileError}}
    end.

tempModuleName() ->
    list_to_atom(
        lists:flatten(
            io_lib:format("alEvalTmp_~p_~p", [erlang:unique_integer([positive]), erlang:phash2(self())]))).

unloadTemp(Mod) when is_atom(Mod) ->
    _ = code:purge(Mod),
    _ = code:delete(Mod),
    _ = code:purge(Mod),
    ok;
unloadTemp(_) ->
    ok.

%% -module(M). -export([run/0]). run() -> Bindings..., Exprs.
wrapExprForms(Mod, Exprs, Bindings) ->
    Anno = erl_anno:new(1),
    BindingExprs = bindingExprs(Bindings, Anno),
    Body = BindingExprs ++ Exprs,
    [moduleAttr(Mod, Anno),
     exportAttr([{run, 0}], Anno),
     {function, Anno, run, 0, [{clause, Anno, [], [], Body}]}].

%% -module(M). -export([run/1]). run(Args) -> (fun ...)(with apply via case arity).
wrapFunForms(Mod, [FunExpr], Arity, Bindings) ->
    Anno = erl_anno:new(1),
    BindingExprs = bindingExprs(Bindings, Anno),
    ArgsVar = {var, Anno, 'AliEvalArgs'},
    FunVar = {var, Anno, 'AliEvalFun'},
    %% AliEvalFun = fun..., then apply
    AssignFun = {match, Anno, FunVar, FunExpr},
    ApplyCall = {call, Anno, {atom, Anno, apply}, [FunVar, ArgsVar]},
    Body = BindingExprs ++ [AssignFun, ApplyCall],
    %% run/1 — apply/2 在我们生成的 wrapper 里，不经 AI AST lint
    [moduleAttr(Mod, Anno),
     exportAttr([{run, 1}], Anno),
     {function, Anno, run, 1,
      [{clause, Anno, [ArgsVar],
        [[{call, Anno, {atom, Anno, is_list}, [ArgsVar]},
          {op, Anno, '=:=',
           {call, Anno, {atom, Anno, length}, [ArgsVar]},
           {integer, Anno, Arity}}]],
        Body},
       {clause, Anno, [ArgsVar], [],
        [{call, Anno, {remote, Anno, {atom, Anno, erlang}, {atom, Anno, error}},
          [{tuple, Anno, [{atom, Anno, badArity},
                          {tuple, Anno, [{integer, Anno, Arity}, ArgsVar]}]}]}]}]}].

bindingExprs(Bindings, Anno) when is_map(Bindings) ->
    maps:fold(fun(K, V, Acc) ->
        case toVarAtom(K) of
            {ok, Var} ->
                [{match, Anno, {var, Anno, Var}, erl_syntax:revert(erl_syntax:abstract(V))} | Acc];
            error ->
                Acc
        end
    end, [], Bindings);
bindingExprs(_, _) ->
    [].

toVarAtom(A) when is_atom(A) ->
    case atom_to_list(A) of
        [C | _] when C >= $A, C =< $Z -> {ok, A};
        [$_ | _] -> {ok, A};
        _ -> error
    end;
toVarAtom(B) when is_binary(B) ->
    toVarAtom(binary_to_list(B));
toVarAtom(L) when is_list(L) ->
    try list_to_atom(L) of
        A -> toVarAtom(A)
    catch _:_ -> error
    end;
toVarAtom(_) ->
    error.

moduleAttr(Mod, Anno) ->
    {attribute, Anno, module, Mod}.

exportAttr(FAs, Anno) ->
    {attribute, Anno, export, FAs}.

%%====================================================================
%% utils
%%====================================================================

toList(B) when is_binary(B) -> unicode:characters_to_list(B);
toList(L) when is_list(L) -> L;
toList(A) when is_atom(A) -> atom_to_list(A);
toList(Other) -> lists:flatten(io_lib:format("~p", [Other])).

toInt(I, _Def) when is_integer(I), I > 0 -> I;
toInt(B, Def) when is_binary(B) ->
    try binary_to_integer(B) catch _:_ -> Def end;
toInt(L, Def) when is_list(L) ->
    try list_to_integer(L) catch _:_ -> Def end;
toInt(_, Def) -> Def.
