%%%-------------------------------------------------------------------
%%% @doc Elixir 源码（.ex/.exs）轻量解析器。
%%%
%%% 用正则从 Elixir 源码提取模块元数据（模块名、def/defp/defmacro 函数及
%%% 行号范围、@spec、use/@behaviour、import/alias/require 依赖），产出与
%%% {@link alCodeIndexer} Erlang 条目<b>同构</b>的 map，从而复用同一套索引、
%%% 检索（{@link alRag}）、调用关系与图分析能力。
%%%
%%% 注：这是词法级解析（非完整 Elixir AST），用于离线、零依赖的代码导航；
%%% 多行函数头、宏展开等复杂场景为已知局限。
%%% @end
%%%-------------------------------------------------------------------
-module(alElixir).

-export([
    parseModule/4,
    parseModuleName/1,
    parseFunctions/1,
    isElixirFile/1
]).

%% @doc 判断路径是否为 Elixir 源文件（.ex/.exs）。
-spec isElixirFile(string() | binary()) -> boolean().
isElixirFile(Path) ->
    Ext = filename:extension(toList(Path)),
    Ext =:= ".ex" orelse Ext =:= ".exs".

%% @doc 解析 Elixir 模块为索引条目（与 alCodeIndexer Erlang 条目同构）。
-spec parseModule(string(), string() | binary(), binary(), term()) -> map().
parseModule(Root, AbsPath, Content, Mtime) ->
    Module = parseModuleName(Content),
    Lines = binary:split(Content, <<"\n"/utf8>>, [global]),
    Functions = parseFunctions(Lines),
    Exports = [{maps:get(name, F), maps:get(arity, F)}
               || F <- Functions, maps:get(public, F, false)],
    Behaviours = parseBehaviours(Content),
    Imports = parseDeps(Content),
    Specs = parseSpecs(Content),
    #{
        module => Module,
        language => elixir,
        file => relPath(Root, AbsPath),
        absPath => AbsPath,
        mtime => Mtime,
        exports => Exports,
        behaviours => Behaviours,
        imports => Imports,
        specs => Specs,
        functions => Functions,
        exportCount => length(Exports),
        functionCount => length(Functions)
    }.

%% @doc 提取首个 `defmodule Name do' 的模块名（atom），未匹配返回 undefined。
-spec parseModuleName(binary()) -> atom() | undefined.
parseModuleName(Content) ->
    case re:run(Content, <<"defmodule\\s+([A-Z][A-Za-z0-9_.]*)"/utf8>>,
                [{capture, all_but_first, binary}]) of
        {match, [Name]} -> binary_to_atom(Name, utf8);
        nomatch -> undefined
    end.

%% @doc 逐行解析 def/defp/defmacro/defmacrop 定义，记录名称、arity、可见性与行号范围。
-spec parseFunctions([binary()]) -> [map()].
parseFunctions(Lines) ->
    parseFunctions(Lines, 1, undefined, []).

parseFunctions([], _N, Cur, Acc) ->
    lists:reverse(closeFun(Cur, 0, Acc));
parseFunctions([Line | Rest], N, Cur, Acc) ->
    case matchDef(Line) of
        {ok, Name, Arity, Public} ->
            Closed = closeFun(Cur, N - 1, Acc),
            NewCur = #{
                name => Name,
                arity => Arity,
                public => Public,
                line_start => N
            },
            parseFunctions(Rest, N + 1, NewCur, Closed);
        nomatch ->
            parseFunctions(Rest, N + 1, Cur, Acc)
    end.

closeFun(undefined, _End, Acc) -> Acc;
closeFun(Cur, End, Acc) -> [maps:put(line_end, End, Cur) | Acc].

%% 匹配函数定义头：def/defp/defmacro/defmacrop Name(args)
matchDef(Line) ->
    Re = <<"^\\s*(def|defp|defmacrop|defmacro)\\s+([a-z_][A-Za-z0-9_]*[!?]?)\\s*(\\(([^)]*)\\))?"/utf8>>,
    case re:run(Line, Re, [{capture, all_but_first, binary}]) of
        {match, [Kind, Name | RestCaps]} ->
            Args = argsCapture(RestCaps),
            Arity = arityOf(Args),
            Public = (Kind =:= <<"def"/utf8>>) orelse (Kind =:= <<"defmacro"/utf8>>),
            {ok, binary_to_atom(Name, utf8), Arity, Public};
        nomatch ->
            nomatch
    end.

%% 从可选捕获组中取出括号内的参数串
argsCapture([]) -> <<>>;
argsCapture([_ParenGroup]) -> <<>>;
argsCapture([_ParenGroup, Inner | _]) -> Inner;
argsCapture(_) -> <<>>.

%% 按逗号粗略计算 arity（顶层逗号；嵌套结构为已知近似）
arityOf(ArgsBin) ->
    case trimWs(ArgsBin) of
        <<>> -> 0;
        Bin -> 1 + countTopCommas(Bin, 0, 0)
    end.

%% 统计顶层逗号数（忽略括号/方括号/花括号内部）
countTopCommas(<<>>, _Depth, Acc) -> Acc;
countTopCommas(<<C, Rest/binary>>, Depth, Acc) ->
    case C of
        $( -> countTopCommas(Rest, Depth + 1, Acc);
        $[ -> countTopCommas(Rest, Depth + 1, Acc);
        ${ -> countTopCommas(Rest, Depth + 1, Acc);
        $) -> countTopCommas(Rest, max(0, Depth - 1), Acc);
        $] -> countTopCommas(Rest, max(0, Depth - 1), Acc);
        $} -> countTopCommas(Rest, max(0, Depth - 1), Acc);
        $, when Depth =:= 0 -> countTopCommas(Rest, Depth, Acc + 1);
        _ -> countTopCommas(Rest, Depth, Acc)
    end.

%% @behaviour Mod 与 use Mod 视为行为/混入依赖
parseBehaviours(Content) ->
    B = captureAll(Content, <<"@behaviour\\s+([A-Z][A-Za-z0-9_.]*)"/utf8>>),
    U = captureAll(Content, <<"^\\s*use\\s+([A-Z][A-Za-z0-9_.]*)"/utf8>>),
    lists:usort([binary_to_atom(X, utf8) || X <- B ++ U]).

%% import/alias/require 的模块依赖（atom 列表，供 module_graph 复用）
parseDeps(Content) ->
    Deps = captureAll(Content, <<"^\\s*(?:import|alias|require)\\s+([A-Z][A-Za-z0-9_.]*)"/utf8>>),
    lists:usort([binary_to_atom(X, utf8) || X <- Deps]).

%% @spec name(args) :: ... → {Name, Arity}
parseSpecs(Content) ->
    case re:run(Content, <<"@spec\\s+([a-z_][A-Za-z0-9_]*[!?]?)\\(([^)]*)\\)"/utf8>>,
                [global, {capture, all_but_first, binary}]) of
        {match, Matches} ->
            [{binary_to_atom(Name, utf8), arityOf(Args)} || [Name, Args] <- Matches];
        nomatch ->
            []
    end.

%% 通用：全局捕获第一个分组的所有匹配
captureAll(Content, Pattern) ->
    case re:run(Content, Pattern, [global, multiline, {capture, all_but_first, binary}]) of
        {match, Matches} -> [hd(M) || M <- Matches];
        nomatch -> []
    end.

%% 计算相对项目根路径（binary）
relPath(Root, Abs) ->
    RootNorm = filename:absname(Root),
    AbsNorm = filename:absname(toList(Abs)),
    Sep = case os:type() of {win32, _} -> "\\"; _ -> "/" end,
    case string:prefix(AbsNorm, RootNorm ++ Sep) of
        nomatch -> unicode:characters_to_binary(filename:basename(AbsNorm));
        Rest -> unicode:characters_to_binary(string:trim(Rest, leading, "/\\"))
    end.

trimWs(Bin) when is_binary(Bin) ->
    re:replace(Bin, <<"^\\s+|\\s+$"/utf8>>, <<>>, [global, {return, binary}]).

toList(X) when is_binary(X) -> unicode:characters_to_list(X);
toList(X) when is_list(X) -> X.
