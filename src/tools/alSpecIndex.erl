%%%-------------------------------------------------------------------
%% @doc Spec / dialyzer 类型反向检索。
%%
%% 给定类型名（或模式），找出所有 `-spec` 声明中引用该类型的函数。
%% 便于重构时让 LLM 枚举「谁依赖这个类型？」而无需手工 grep 大量 .erl。
%%
%% 实现基于文本：扫描项目中每个 .erl，检查每个 `-spec' 属性后到下一
%% 属性之间的行，匹配结果形如
%% `#{module, function, arity, file, line, snippet}'。
%%
%% `parseSpec/1' 将单条 `-spec F(A, B) -> ResType.' 拆成
%% `{[{Name, Arity}], SpecText}'。
%% @end
%%%-------------------------------------------------------------------

-module(alSpecIndex).

-export([
    findTypeUsages/2,
    findTypeUsages/3,
    searchSpecs/2,
    searchSpecs/3,
    parseSpec/1,
    moduleSpecs/1
]).

-define(MaxFileBytes, 2097152).
-define(SpecAttrRegex, "^-spec\\s+(.+?)\\.$").
-define(SpecAttrRegexC, "^\\s*-spec\\s+(.+?)\\.$").

%%--------------------------------------------------------------------
%% @doc
%% 在指定根目录下搜索所有 spec 中引用了 `TypeName'（atom 或 binary）
%% 的函数。`TypeName' 必须为合法 Erlang 类型标识符或子类型。
%%
%% @param TypeName 类型名（atom/binary/string）
%% @param Root 项目根目录
%% @return {ok, [#{module, function, arity, file, line, snippet}]}
%% @end
%%--------------------------------------------------------------------
-spec findTypeUsages(TypeName :: atom() | binary() | string(),
                     Root :: file:filename()) ->
    {ok, [map()]}.
findTypeUsages(TypeName, Root) ->
    findTypeUsages(TypeName, Root, 200).

%%--------------------------------------------------------------------
%% @doc
%% 同 `findTypeUsages/2'，但限制最大返回条数。
%%
%% @param TypeName 类型名
%% @param Root 项目根目录
%% @param Limit 上限
%% @end
%%--------------------------------------------------------------------
-spec findTypeUsages(TypeName :: atom() | binary() | string(),
                     Root :: file:filename(),
                     Limit :: pos_integer()) ->
    {ok, [map()]}.
findTypeUsages(TypeName, Root, Limit) ->
    Name = toTypeName(TypeName),
    Candidates = listTypeNames(Name),
    Files = collectErlFiles(Root),
    Raw = lists:flatmap(
        fun(File) -> scanFileForTypes(File, Candidates) end,
        Files),
    Sorted = lists:sort(fun cmpUsage/2, Raw),
    {ok, lists:sublist(Sorted, Limit)}.

%%--------------------------------------------------------------------
%% @doc
%% 在所有 spec 中按正则模式搜索（Erlang 正则语法）。
%% 返回匹配片段及其所属 function/arity。
%%
%% @param Pattern 正则字符串
%% @param Root 项目根目录
%% @end
%%--------------------------------------------------------------------
-spec searchSpecs(Pattern :: binary() | string(),
                  Root :: file:filename()) ->
    {ok, [map()]}.
searchSpecs(Pattern, Root) ->
    searchSpecs(Pattern, Root, 200).

-spec searchSpecs(Pattern :: binary() | string(),
                  Root :: file:filename(),
                  Limit :: pos_integer()) ->
    {ok, [map()]}.
searchSpecs(Pattern, Root, Limit) ->
    Re = toRegex(Pattern),
    Files = collectErlFiles(Root),
    Raw = lists:flatmap(
        fun(File) -> scanFileForRegex(File, Re) end,
        Files),
    Sorted = lists:sort(fun cmpUsage/2, Raw),
    {ok, lists:sublist(Sorted, Limit)}.

%%--------------------------------------------------------------------
%% @doc
%% 解析一行 `-spec F(A, B) -> R.'，返回
%% `{[{F, 2}], R.'} 或在无法解析时返回 `error'。
%% 支持多子句形式（按顶层 `;' 切分），如
%% `-spec f(X) -> X; g(Y) -> Y.' 会返回
%% `{[{f,1},{g,1}], "X"}'（返回类型仅取首段）。
%% 行内 `%%' / `%' 之后的注释会被去除。
%%
%% @param Line spec 行文本
%% @end
%%--------------------------------------------------------------------
-spec parseSpec(string()) -> {[{atom(), arity()}], string()} | error.
parseSpec(Line) ->
    Trim = string:trim(Line),
    Stripped = stripComment(Trim),
    SpecBody = stripPrefix(Stripped, "-spec"),
    SpecBody1 = stripPrefix(SpecBody, "spec"),
    Clauses = splitTopLevel(SpecBody1, $;),
    case parseClauses(Clauses) of
        error -> error;
        {[], _Ret} -> error;
        {Heads, Ret} -> {Heads, Ret}
    end.

%% 把 spec 主体按顶层 `;' 切分成多个子句。
splitTopLevel(S, Sep) ->
    splitTopLevel(S, Sep, [], 0, []).

splitTopLevel([], _Sep, Buf, _Depth, Acc) ->
    lists:reverse([lists:reverse(Buf) | Acc]);
splitTopLevel([Sep | Rest], Sep, Buf, 0, Acc) ->
    splitTopLevel(Rest, Sep, [], 0, [lists:reverse(Buf) | Acc]);
splitTopLevel([$( | Rest], Sep, Buf, Depth, Acc) ->
    splitTopLevel(Rest, Sep, [$( | Buf], Depth + 1, Acc);
splitTopLevel([$) | Rest], Sep, Buf, Depth, Acc) ->
    splitTopLevel(Rest, Sep, [$) | Buf], Depth - 1, Acc);
splitTopLevel([${ | Rest], Sep, Buf, Depth, Acc) ->
    splitTopLevel(Rest, Sep, [${ | Buf], Depth + 1, Acc);
splitTopLevel([$} | Rest], Sep, Buf, Depth, Acc) ->
    splitTopLevel(Rest, Sep, [$} | Buf], Depth - 1, Acc);
splitTopLevel([$[ | Rest], Sep, Buf, Depth, Acc) ->
    splitTopLevel(Rest, Sep, [$[ | Buf], Depth + 1, Acc);
splitTopLevel([$] | Rest], Sep, Buf, Depth, Acc) ->
    splitTopLevel(Rest, Sep, [$] | Buf], Depth - 1, Acc);
splitTopLevel([C | Rest], Sep, Buf, Depth, Acc) ->
    splitTopLevel(Rest, Sep, [C | Buf], Depth, Acc).

%% 解析多个子句：每个子句形如 `F(A, B) -> R.'。返回类型仅取首段。
parseClauses(Clauses) ->
    parseClauses(Clauses, [], undefined).

parseClauses([], Acc, Ret) ->
    {lists:reverse(Acc), Ret};
parseClauses([Clause | Rest], Acc, undefined) ->
    case parseSingle(string:trim(Clause)) of
        {Heads, R} ->
            NewAcc = Acc ++ Heads,
            parseClauses(Rest, NewAcc, R);
        error ->
            error
    end;
parseClauses([Clause | Rest], Acc, Ret) ->
    case parseSingle(string:trim(Clause)) of
        {Heads, _R} -> parseClauses(Rest, Acc ++ Heads, Ret);
        error -> parseClauses(Rest, Acc, Ret)
    end.

%% 解析单个子句 `F(A, B) -> R.'。
parseSingle(Clause) ->
    case string:str(Clause, "->") of
        0 -> error;
        Pos ->
            HeadStr = string:trim(string:substr(Clause, 1, Pos - 1)),
            Rest = string:trim(string:substr(Clause, Pos + 2)),
            Rest1 = string:trim(string:strip(string:strip(Rest, right, $.), right)),
            Heads = parseHeadList(HeadStr, []),
            case Heads of
                [] -> error;
                _ -> {Heads, Rest1}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 解析一个 .erl 文件，提取所有 `-spec' 行及其上下文，
%% 返回 `[{Spec, Line}]' 列表。仅做行级扫描，模块名从
%% `-module(NAME).' 行读取。
%%
%% @param File 绝对路径
%% @end
%%--------------------------------------------------------------------
-spec moduleSpecs(file:filename()) -> {ok, [{string(), pos_integer()}]} | {error, term()}.
moduleSpecs(File) ->
    case readLimited(File) of
        {ok, Bin} ->
            Lines = binary:split(Bin, <<"\n">>, [global]),
            Indexed = indexSpecs(Lines, 1, []),
            {ok, lists:reverse(Indexed)};
        Error -> Error
    end.

%%%===================================================================
%%% 内部实现
%%%===================================================================

%% 把任意类型名转为 binary 用于子串匹配。不再对 LLM 入参调用
%% binary_to_atom/list_to_atom，避免任意类型名膨胀全局原子表（DoS）。
toTypeName(B) when is_binary(B) -> B;
toTypeName(A) when is_atom(A) -> atom_to_binary(A, utf8);
toTypeName(S) when is_list(S) ->
    case unicode:characters_to_binary(S) of
        Bin when is_binary(Bin) -> Bin;
        _ -> <<>>
    end.

%% 把任意正则模式转为 re 引擎接受的 binary。列表输入可能是 unicode
%% charlist（码点 > 255），直接用 list_to_binary 会 badarg；统一走
%% unicode:characters_to_binary 并安全降级为空串。
toRegex(B) when is_binary(B) -> B;
toRegex(S) when is_list(S) ->
    case unicode:characters_to_binary(S) of
        Bin when is_binary(Bin) -> Bin;
        _ -> <<>>
    end.

%% 收集目录下所有 .erl 文件，过滤 _build 等目录。
collectErlFiles(Root) ->
    R = unicode:characters_to_list(Root),
    Wild = filename:join(R, "**/*.erl"),
    All = filelib:wildcard(Wild),
    [F || F <- All, not isExcludedPath(F)].

isExcludedPath(Path) ->
    Exclude = ["_build", ".git", "node_modules", ".rebar3", "rebar3.crashdump", "erts"],
    PathStr = unicode:characters_to_list(Path),
    lists:any(
        fun(Seg) -> string:str(PathStr, Seg) > 0 end,
        Exclude).

%% 在一个文件里扫描所有 spec，查找引用了 TypeName 的行。
scanFileForTypes(File, CandidateAtoms) ->
    case readLimited(File) of
        {ok, Bin} ->
            Lines = binary:split(Bin, <<"\n">>, [global]),
            Module = detectModule(Lines),
            scanLinesForTypes(File, Module, Lines, CandidateAtoms, 1, []);
        _ -> []
    end.

scanLinesForTypes(_File, _Module, [], _Names, _LineNo, Acc) ->
    lists:reverse(Acc);
scanLinesForTypes(File, Module, [Line | Rest], Names, LineNo, Acc) ->
    case isSpecAttr(Line) of
        {true, SpecText} ->
            NewAcc = lists:foldl(
                fun({F, A, Snippet}, A2) ->
                    case specMentions(SpecText, Names) of
                        true ->
                            [#{module => Module,
                               function => F,
                               arity => A,
                               file => File,
                               line => LineNo,
                               snippet => Snippet} | A2];
                        false -> A2
                    end
                end, Acc, headsToFunArity(SpecText)),
            scanLinesForTypes(File, Module, Rest, Names, LineNo + 1, NewAcc);
        false ->
            scanLinesForTypes(File, Module, Rest, Names, LineNo + 1, Acc)
    end.

%% 匹配 `-spec' 行（包括行尾注释已被 strip 过的内容）。
%% 接受 binary 或 list 输入。
isSpecAttr(Line) when is_binary(Line) -> isSpecAttr(binary_to_list(Line));
isSpecAttr(Line) when is_list(Line) ->
    Trim = string:trim(Line),
    case Trim of
        [$-, $s, $p, $e, $c | _] -> {true, Trim};
        _ -> false
    end.

%% 从一个 spec 字符串中提取所有 (F, A) 列表与 snippet 列表。
%% 单个 spec 可能有 `-spec f(X) -> R; g(Y) -> S.' 多子句。
headsToFunArity(SpecLine) ->
    Stripped = stripPeriod(stripComment(SpecLine)),
    Parts = string:split(Stripped, ";", all),
    lists:flatmap(fun(P) -> headToFuns(P) end, Parts).

headToFuns(Clause) ->
    Trim = string:trim(Clause),
    Stripped = string:strip(string:strip(Trim, right, $.), right),
    case parseSpec("-spec " ++ Stripped ++ ".") of
        {Heads, _} ->
            [{F, A, Stripped} || {F, A} <- Heads];
        error -> []
    end.

%% spec 文本里是否提到了任一候选类型（按子串匹配，词边界）。
specMentions(SpecText, Names) ->
    Bin = list_to_binary(SpecText),
    lists:any(fun(N) -> typeMatches(Bin, N) end, Names).

%% 词边界匹配：避免 `atom' 命中 `some_atom_type'。
typeMatches(Bin, Name) when is_binary(Name) ->
    typeMatchesBin(Bin, Name);
typeMatches(Bin, Name) when is_atom(Name) ->
    NameBin = atom_to_binary(Name, utf8),
    typeMatchesBin(Bin, NameBin);
typeMatches(Bin, Name) when is_list(Name) ->
    typeMatchesBin(Bin, list_to_binary(Name)).

typeMatchesBin(Bin, NameBin) ->
    case binary:match(Bin, NameBin) of
        nomatch -> false;
        {Pos, Len} ->
            BeforeOK = Pos =:= 0 orelse isWordBoundary(binary:at(Bin, Pos - 1)),
            AfterPos = Pos + Len,
            AfterOK = AfterPos >= byte_size(Bin) orelse
                isWordBoundary(binary:at(Bin, AfterPos)),
            BeforeOK andalso AfterOK
    end.

isWordBoundary(C) ->
    not ((C >= $a andalso C =< $z) orelse
         (C >= $A andalso C =< $Z) orelse
         (C >= $0 andalso C =< $9) orelse
         C =:= $_ orelse C =:= $@).

%% 推断类型名候选。当前仅返回类型名自身（binary），保留列表形态
%% 便于将来扩展（如去掉模块前缀的子类型）。
listTypeNames(Name) when is_binary(Name) ->
    [Name].

%% 按正则扫描：找到 -spec 行后若 regex 在 snippet 中命中则加入结果。
scanFileForRegex(File, Regex) ->
    case readLimited(File) of
        {ok, Bin} ->
            Lines = binary:split(Bin, <<"\n">>, [global]),
            Module = detectModule(Lines),
            scanLinesForRegex(File, Module, Lines, Regex, 1, []);
        _ -> []
    end.

scanLinesForRegex(_File, _Module, [], _Re, _LineNo, Acc) ->
    lists:reverse(Acc);
scanLinesForRegex(File, Module, [Line | Rest], Re, LineNo, Acc) ->
    case isSpecAttr(Line) of
        {true, SpecText} ->
            NewAcc = lists:foldl(
                fun({F, A, Snippet}, A2) ->
                    case regexInSpec(Snippet, Re) of
                        true ->
                            [#{module => Module,
                               function => F,
                               arity => A,
                               file => File,
                               line => LineNo,
                               snippet => Snippet} | A2];
                        false -> A2
                    end
                end, Acc, headsToFunArity(SpecText)),
            scanLinesForRegex(File, Module, Rest, Re, LineNo + 1, NewAcc);
        false ->
            scanLinesForRegex(File, Module, Rest, Re, LineNo + 1, Acc)
    end.

regexInSpec(Snippet, Re) ->
    Bin = list_to_binary(Snippet),
    case re:run(Bin, Re, [dotall]) of
        {match, _} -> true;
        _ -> false
    end.

%% 读取文件（限制大小以避免大文件阻塞）。
readLimited(File) ->
    case file:read_file(File) of
        {ok, Bin} when byte_size(Bin) =< ?MaxFileBytes -> {ok, Bin};
        {ok, _Big} -> {error, fileTooLarge};
        Error -> Error
    end.

%% 寻找 `-module(NAME).' 行。
detectModule(Lines) ->
    doDetectModule(Lines, 1).

doDetectModule([], _) -> undefined;
doDetectModule([Line | Rest], _N) ->
    S = binary_to_list(Line),
    Trim = string:trim(S),
    case Trim of
        "-module" ++ Rest1 ->
            case extractModuleAtom(Rest1) of
                {ok, Name} -> Name;
                error -> undefined
            end;
        _ -> doDetectModule(Rest, 1)
    end.

extractModuleAtom(Str) ->
    case string:str(Str, "(") of
        0 -> error;
        L ->
            Tail = string:substr(Str, L + 1),
            case string:str(Tail, ")") of
                0 -> error;
                R ->
                    Inner = string:substr(Tail, 1, R - 1),
                    Inner1 = stripComment(string:trim(Inner)),
                    Inner2 = string:strip(Inner1, right, $.),
                    Ident = string:trim(Inner2),
                    %% 安全：扫描源文件时不能用 list_to_atom 创建任意原子（DoS）。
                    %% 仅用 list_to_existing_atom；不存在的模块名保留为 binary，避免
                    %% 膨胀全局原子表。下游消费 module 字段时按 atom/binary 都能容错。
                    case Ident =/= "" andalso length(Ident) =< 255 andalso
                         re:run(Ident, <<"^[a-z][A-Za-z0-9_]*$">>, [{capture, none}]) =:= match of
                        true ->
                            try
                                {ok, list_to_existing_atom(Ident)}
                            catch _:_ ->
                                {ok, unicode:characters_to_binary(Ident)}
                            end;
                        false ->
                            error
                    end
            end
        end.

stripPrefix(Line, Prefix) ->
    case string:str(Line, Prefix) of
        0 -> Line;
        N -> string:trim(string:substr(Line, N + length(Prefix)))
    end.

stripComment(Line) ->
    case string:str(Line, "%") of
        0 -> Line;
        N -> string:trim(string:substr(Line, 1, N - 1))
    end.

stripPeriod(S) ->
    string:strip(string:strip(S, right, $.), right).

%% 解析 `-spec' 的 function head 部分：返回 `[{Name, Arity}]'。
parseHeadList(Str, Acc) ->
    case string:str(Str, ";") of
        0 -> parseOne(string:trim(Str), Acc);
        Pos ->
            Head = string:trim(string:substr(Str, 1, Pos - 1)),
            Rest = string:trim(string:substr(Str, Pos + 1)),
            parseOne(Head, Acc) ++ parseHeadList(Rest, [])
    end.

parseOne(Head, Acc) ->
    case string:str(Head, "(") of
        0 -> Acc;
        L ->
            Name = string:strip(string:substr(Head, 1, L - 1)),
            case string:trim(Name) of
                "" -> Acc;
                TrimmedName ->
                    Tail = string:substr(Head, L + 1),
                    case string:str(Tail, ")") of
                        0 -> Acc;
                        R ->
                            Inside = string:substr(Tail, 1, R - 1),
                            Arity = arityFromInside(Inside),
                            %% 安全：扫描源文件时不能用 list_to_atom 创建任意函数名原子（DoS）。
                            %% 仅用 list_to_existing_atom；不存在的函数名跳过（返回 Acc 不变），
                            %% 避免膨胀全局原子表。
                            NameAtom = try list_to_existing_atom(TrimmedName)
                                       catch _:_ -> undefined end,
                            case NameAtom of
                                undefined -> Acc;
                                _ -> [{NameAtom, Arity} | Acc]
                            end
                    end
            end
    end.

%% 计算 arity：空参列表为 0；否则按顶层 `,' 计数 + 1。
arityFromInside("") -> 0;
arityFromInside(Inside) ->
    TopCommas = countCommas(Inside, 0, 0),
    TopCommas + 1.

countCommas([], _Depth, N) -> N;
countCommas([$( | Rest], D, N) -> countCommas(Rest, D + 1, N);
countCommas([$) | Rest], D, N) -> countCommas(Rest, D - 1, N);
countCommas([$, | Rest], 0, N) -> countCommas(Rest, 0, N + 1);
countCommas([_ | Rest], D, N) -> countCommas(Rest, D, N).

cmpUsage(A, B) ->
    AFile = maps:get(file, A),
    BFile = maps:get(file, B),
    case AFile =:= BFile of
        true ->
            maps:get(line, A) =< maps:get(line, B);
        false ->
            AFile =< BFile
    end.

%% 行级提取所有 spec 行（不做引用计数）。
indexSpecs([], _N, Acc) -> Acc;
indexSpecs([Line | Rest], N, Acc) ->
    S = unicode:characters_to_list(Line),
    case isSpecAttr(S) of
        {true, _} -> indexSpecs(Rest, N + 1, [{S, N} | Acc]);
        false -> indexSpecs(Rest, N + 1, Acc)
    end.
