%%%-------------------------------------------------------------------
%%% @doc Erlang 源码 AST 解析与调用分析。
%%%
%%% 基于 syntax_tools/epp_dodger 解析 .erl 文件，提取函数体内
%%% 远程/本地/apply 调用，支持查找调用方与构建模块级调用图边。
%%% @end
%%%-------------------------------------------------------------------
-module(alAst).

-export([
    parse_file/1,
    module_from_forms/1,
    function_calls/4,
    find_callers/2,
    call_graph_edges/1
]).

-type call_info() :: #{
    module => atom() | local | apply,
    function => atom() | undefined,
    arity => non_neg_integer() | undefined,
    line => non_neg_integer() | undefined,
    kind => remote | local | apply | mfa
}.

%% @doc 解析 Erlang 源文件为 abstract_form 列表。
-spec parse_file(string()) -> {ok, [erl_parse:abstract_form()]} | {error, term()}.
parse_file(Path) ->
    Opts = [{encoding, utf8}, {record_name, true}],
    {ok, _} = application:ensure_all_started(syntax_tools),
    case epp_dodger:parse_file(Path, Opts) of
        {ok, Trees} ->
            Forms = [erl_syntax:revert(T) || T <- Trees],
            {ok, Forms};
        {error, Reason} -> {error, Reason}
    end.

%% @doc 从 abstract forms 中提取 -module 声明的模块名。
-spec module_from_forms([erl_parse:abstract_form()]) -> atom() | undefined.
module_from_forms(Forms) ->
    case lists:keyfind(module, 1, Forms) of
        {attribute, _, module, Mod} when is_atom(Mod) -> Mod;
        _ -> undefined
    end.

%% @doc 分析指定函数子句体内的所有调用并去重返回。
-spec function_calls(string(), atom(), atom(), non_neg_integer() | undefined) ->
    {ok, [call_info()]} | {error, term()}.
function_calls(File, _Mod, Fun, Arity) ->
    case parse_file(File) of
        {ok, Forms} ->
            case find_function_clauses(Forms, Fun, Arity) of
                {ok, Clauses} ->
                    Self = module_from_forms(Forms),
                    Calls = lists:flatmap(fun(Clause) ->
                        collect_calls_in_clause(Clause, Self)
                    end, Clauses),
                    Dedup = dedup_calls(Calls),
                    {ok, Dedup};
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

%% @doc 在全项目索引模块中查找调用 TargetMod:TargetFun 的调用方。
-spec find_callers(atom(), atom()) -> [{atom(), [map()]}].
find_callers(TargetMod, TargetFun) ->
    alCodeIndexer:ensure_started(),
    All = alCodeIndexer:all_modules(),
    lists:foldl(fun(CallerMod, Acc) ->
        case CallerMod =:= TargetMod of
            true -> Acc;
            false ->
                case alCodeIndexer:lookup_module(CallerMod) of
                    {ok, #{absPath := Path}} ->
                        case scan_file_callers(Path, CallerMod, TargetMod, TargetFun) of
                            [] -> Acc;
                            Sites -> [{CallerMod, Sites} | Acc]
                        end;
                    _ -> Acc
                end
        end
    end, [], All).

%% @doc 构建模块内各函数到外部模块的远程调用边列表。
-spec call_graph_edges(atom()) -> [#{from => atom(), to => atom(), calls => [atom()]}].
call_graph_edges(Mod) ->
    case alCodeIndexer:lookup_module(Mod) of
        {ok, #{absPath := Path, functions := Funs}} ->
            Edges = lists:flatmap(fun(FunInfo) ->
                Name = maps:get(name, FunInfo),
                Arity = maps:get(arity, FunInfo, 0),
                case function_calls(Path, Mod, Name, Arity) of
                    {ok, Calls} ->
                        Remotes = [
                            #{from => Mod, to => T, via => Name} ||
                            #{module := T, function := _Fn, kind := remote} <- Calls,
                            is_atom(T), T =/= erlang, T =/= Mod
                        ],
                        Remotes;
                    _ -> []
                end
            end, Funs),
            Edges;
        _ -> []
    end.

%% 扫描单文件 AST，筛选匹配目标 Mod:Fun 的调用点。
scan_file_callers(Path, CallerMod, TargetMod, TargetFun) ->
    case parse_file(Path) of
        {ok, Forms} ->
            Self = module_from_forms(Forms),
            AllCalls = collect_calls_in_forms(Forms, Self),
            [#{line => maps:get(line, C, undefined), kind => maps:get(kind, C)}
             || C <- AllCalls,
                call_matches(C, CallerMod, TargetMod, TargetFun, Self)];
        _ ->
            []
    end.

%% 判断单条 call_info 是否指向目标 Mod:Fun（含同模块本地调用）。
call_matches(#{module := TargetMod, function := TargetFun}, _, TargetMod, TargetFun, _) ->
    true;
call_matches(#{module := local, function := TargetFun}, CallerMod, TargetMod, TargetFun, Self)
        when CallerMod =:= TargetMod; Self =:= TargetMod ->
    true;
call_matches(_, _, _, _, _) ->
    false.

%% 按函数名与 arity 定位函数子句列表。
find_function_clauses(Forms, Fun, undefined) ->
    find_function_clauses(Forms, Fun);
find_function_clauses(Forms, Fun, Arity) ->
    case [Cs || {function, _, Name, A, Cs} <- Forms, Name =:= Fun, A =:= Arity] of
        [Clauses | _] -> {ok, Clauses};
        [] -> {error, functionNotFound}
    end.

%% 按函数名定位（忽略 arity，取第一个匹配）。
find_function_clauses(Forms, Fun) ->
    case [Cs || {function, _, Name, _A, Cs} <- Forms, Name =:= Fun] of
        [Clauses | _] -> {ok, Clauses};
        [] -> {error, functionNotFound}
    end.

%% 遍历所有 function form 收集调用。
collect_calls_in_forms(Forms, SelfMod) ->
    lists:flatmap(fun(Form) ->
        case Form of
            {function, _, _N, _A, Clauses} ->
                lists:flatmap(fun(C) -> collect_calls_in_clause(C, SelfMod) end, Clauses);
            _ -> []
        end
    end, Forms).

%% 在单个 clause 的 Body 表达式列表中收集调用。
collect_calls_in_clause({clause, _Anno, _P, _G, Body}, SelfMod) ->
    lists:flatmap(fun(Expr) -> collect_calls_in_expr(Expr, SelfMod) end, Body).

%% 遇到 {call, ...} 则规范化；否则递归 walk_expr。
collect_calls_in_expr(Expr, SelfMod) ->
    case Expr of
        {call, Anno, FunExpr, Args} ->
            [normalize_call(FunExpr, Args, line_of(Anno), SelfMod)];
        _ ->
            walk_expr(Expr, SelfMod)
    end.

%% 深度优先遍历表达式树中的嵌套调用（match、case、lc、fun 等）。
walk_expr(Expr, SelfMod) ->
    case Expr of
        {call, _, _, _} -> [];
        {match, _, _, R} -> walk_expr(R, SelfMod);
        {op, _, L, R} -> walk_expr(L, SelfMod) ++ walk_expr(R, SelfMod);
        {cons, _, H, T} -> walk_expr(H, SelfMod) ++ walk_expr(T, SelfMod);
        {lc, _, _, Gens, _} ->
            lists:flatmap(fun
                ({generate, _, E, _}) -> walk_expr(E, SelfMod);
                ({bgenerate, _, E, _}) -> walk_expr(E, SelfMod);
                (_) -> []
            end, Gens);
        {block, _, Es} -> lists:flatmap(fun(E) -> walk_expr(E, SelfMod) end, Es);
        {'if', _, Clauses} ->
            lists:flatmap(fun
                ({clause, _, [], [], Body}) ->
                    lists:flatmap(fun(E) -> walk_expr(E, SelfMod) end, Body);
                ({clause, _, _, G, Body}) ->
                    lists:flatmap(fun(E) -> walk_expr(E, SelfMod) end, G) ++
                    lists:flatmap(fun(E) -> walk_expr(E, SelfMod) end, Body)
            end, Clauses);
        {'case', _, E, Clauses} ->
            walk_expr(E, SelfMod) ++
            lists:flatmap(fun({clause, _, _, G, Body}) ->
                lists:flatmap(fun(X) -> walk_expr(X, SelfMod) end, G) ++
                lists:flatmap(fun(X) -> walk_expr(X, SelfMod) end, Body)
            end, Clauses);
        {'receive', _, Clauses} ->
            lists:flatmap(fun({clause, _, _, G, Body}) ->
                lists:flatmap(fun(X) -> walk_expr(X, SelfMod) end, G) ++
                lists:flatmap(fun(X) -> walk_expr(X, SelfMod) end, Body)
            end, Clauses);
        {'try', _, Body, _, Clauses} ->
            lists:flatmap(fun(E) -> walk_expr(E, SelfMod) end, Body) ++
            lists:flatmap(fun({clause, _, _, G, CBody}) ->
                lists:flatmap(fun(X) -> walk_expr(X, SelfMod) end, G) ++
                lists:flatmap(fun(X) -> walk_expr(X, SelfMod) end, CBody)
            end, Clauses);
        {'fun', _, {function, _, M, F, A}} ->
            [#{module => M, function => F, arity => A, line => undefined, kind => mfa}];
        {'fun', _, {function, _, F, A}} ->
            [#{module => SelfMod, function => F, arity => A, line => undefined, kind => local}];
        _ -> []
    end.

%% 将 call 的 FunExpr 规范化为 call_info（remote/local/apply）。
normalize_call({remote, Anno, {atom, _, M}, {atom, _, F}}, Args, _Line, _Self) ->
    #{
        module => M,
        function => F,
        arity => length(Args),
        line => line_of(Anno),
        kind => remote
    };
normalize_call({atom, Anno, F}, Args, _Line, Self) ->
    #{
        module => Self,
        function => F,
        arity => length(Args),
        line => line_of(Anno),
        kind => local
    };
normalize_call({local, Anno, {atom, _, F}}, Args, _Line, Self) ->
    #{
        module => Self,
        function => F,
        arity => length(Args),
        line => line_of(Anno),
        kind => local
    };
normalize_call(FunExpr, Args, Line, _Self) ->
    #{
        module => apply,
        function => undefined,
        arity => length(Args),
        line => Line,
        expr => list_to_binary(io_lib:format("~p", [FunExpr])),
        kind => apply
    }.

%% 从注解中提取行号。
line_of(Line) when is_integer(Line) -> Line;
line_of(_) -> undefined.

%% 按 {module, function, arity, line, kind} 去重调用列表。
dedup_calls(Calls) ->
    maps:values(maps:from_list([{call_key(C), C} || C <- Calls])).

%% 构建调用项的唯一键。
call_key(#{module := M, function := F, arity := A, line := L, kind := K}) ->
    {M, F, A, L, K};
call_key(C) ->
    {maps:get(module, C, undefined), maps:get(function, C, undefined),
     maps:get(arity, C, undefined), maps:get(line, C, undefined),
     maps:get(kind, C, undefined)}.