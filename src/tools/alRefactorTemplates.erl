%%%-------------------------------------------------------------------
%% @doc 基于 AST 定位的重构模板，生成 hunk 补丁。
%%
%% 每个模板基于 {@link epp:parse_file/3} 解析源码、定位函数/调用点，
%% 再生成与 {@link alPatchManager} hunk 格式兼容的 patch：
%% `#{file => File, hunks => [#{old => Old, new => New}, ...]}'。
%%
%% 生成的 patches 可直接传给 `batchRefactor action=apply' 应用 + verifyCompile + 回滚。
%%
%% <ul>
%% <li>{@link extractFunction/1}: 把函数内一段代码提取为新函数，原位替换为调用</li>
%% <li>{@link renameFunction/1}: 重命名函数 + 当前模块内所有调用点</li>
%% <li>{@link changeSignature/1}: 修改函数头参数；调用点由 LLM 后续处理</li>
%% <li>{@link addTypespec/1}: 在函数前插入 `-spec'</li>
%% </ul>
%% @end
%%%-------------------------------------------------------------------

-module(alRefactorTemplates).

-export([run/1, extractFunction/1, renameFunction/1,
         changeSignature/1, addTypespec/1]).

%% Test helpers
-export([locateFunctionForm/3, lineOf/1, moduleSourcePath/1,
         makeHunk/3, normalizeAction/1]).

%%%===================================================================
%%% 主入口
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 按 `action' 分发到对应模板。action 取值
%% `extract | rename | signature | spec'。
%%
%% @param Args 含 action 及模板所需字段的 map
%% @return `{ok, #{patches, summary}}' 或 `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
run(#{action := Action} = Args) ->
    dispatch(normalizeAction(Action), Args);
run(#{<<"action">> := Action} = Args) ->
    dispatch(normalizeAction(Action), Args);
run(_Args) ->
    {error, #{reason => missingAction,
              hint => <<"Provide action: extract | rename | signature | spec"/utf8>>}}.

dispatch(extract, Args) -> extractFunction(Args);
dispatch(rename, Args) -> renameFunction(Args);
dispatch(signature, Args) -> changeSignature(Args);
dispatch(spec, Args) -> addTypespec(Args);
dispatch(Other, _Args) ->
    {error, #{reason => badAction, action => Other,
              hint => <<"Use action: extract | rename | signature | spec"/utf8>>}}.

normalizeAction(extract) -> extract;
normalizeAction(rename) -> rename;
normalizeAction(signature) -> signature;
normalizeAction(spec) -> spec;
normalizeAction(B) when is_binary(B) ->
    try binary_to_existing_atom(B, utf8) catch _:_ -> unknown end;
normalizeAction(L) when is_list(L) ->
    try list_to_existing_atom(L) catch _:_ -> unknown end;
normalizeAction(_) -> unknown.

%%%===================================================================
%%% 公共能力
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 解析模块源码：返回 `{ok, Forms, Lines, Path}'。
%% `Forms' 为 epp 解析后的 abstract forms；`Lines' 为源码按行分割的
%% binary 列表（1-indexed，即 Lines 的第 1 个元素对应第 1 行）。
%%
%% @param Module 模块名 atom/binary/list
%% @return `{ok, Forms, Lines, Path}' 或 `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
parseModule(Module) ->
    case moduleSourcePath(Module) of
        undefined ->
            {error, #{reason => sourceNotFound, module => toBinary(Module)}};
        Path ->
            IncDir = filename:join([alConfig:projectRoot(), "include"]),
            ParseRes = try epp:parse_file(Path, [IncDir], [])
                       catch _:_ -> epp:parse_file(Path, [], []) end,
            case ParseRes of
                {ok, Forms} ->
                    case file:read_file(Path) of
                        {ok, Bin} ->
                            Lines = binary:split(Bin, <<"\n">>, [global]),
                            {ok, Forms, Lines, Path};
                        {error, R} ->
                            {error, #{reason => readFailed, detail => R}}
                    end;
                {error, R} ->
                    {error, #{reason => parseFailed, detail => R}}
            end
    end.

%%--------------------------------------------------------------------
%% @doc 模块源码路径：code:which 反推 .erl，再 fallback src 各子目录。
%% @end
%%--------------------------------------------------------------------
moduleSourcePath(Module) when is_atom(Module) ->
    Base = atom_to_list(Module) ++ ".erl",
    case code:which(Module) of
        Beam when is_list(Beam) ->
            Erl = filename:rootname(Beam) ++ ".erl",
            case filelib:is_regular(Erl) of
                true -> Erl;
                false -> guessErlPath(Base)
            end;
        _ ->
            guessErlPath(Base)
    end;
moduleSourcePath(Other) ->
    case toAtom(Other) of
        undefined -> undefined;
        M -> moduleSourcePath(M)
    end.

guessErlPath(Base) ->
    Root = alConfig:projectRoot(),
    Dirs = ["src", "src/tools", "src/agent", "src/db", "src/core", "src/misc"],
    Cands = [filename:join([Root, D, Base]) || D <- Dirs],
    lists:foldl(
        fun(_P, Acc) when Acc =/= undefined -> Acc;
           (P, _Acc) ->
            case filelib:is_regular(P) of true -> P; false -> undefined end
        end, undefined, Cands).

%%--------------------------------------------------------------------
%% @doc 在 forms 中定位函数 form，返回 `{ok, Form}' 或 `{error, functionNotFound}'。
%% @end
%%--------------------------------------------------------------------
locateFunctionForm(Forms, Name, Arity) when is_atom(Name), is_integer(Arity) ->
    case [F || F <- Forms,
               case F of
                   {function, _, N, A, _} when N =:= Name, A =:= Arity -> true;
                   _ -> false
               end] of
        [] -> {error, functionNotFound};
        [F | _] -> {ok, F}
    end.

%%--------------------------------------------------------------------
%% @doc 安全取 erl_anno 行号。
%% @end
%%--------------------------------------------------------------------
lineOf(Anno) when is_integer(Anno) -> Anno;
lineOf(Anno) -> try erl_anno:line(Anno) catch _:_ -> undefined end.

%%--------------------------------------------------------------------
%% @doc 构造 hunk patch map（多 hunk 形式，兼容 alPatchManager）。
%% @end
%%--------------------------------------------------------------------
makeHunk(File, Old, New) ->
    #{file => toBinary(File),
      hunks => [#{old => toBinary(Old), new => toBinary(New)}]}.

%%%===================================================================
%%% 模板 1: extractFunction
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 把函数内 `startLine..endLine' 的代码块提取为新函数 `newName/Args'，
%% 原位替换为 `newName(Args)' 调用。
%%
%% 必填：`module' / `function' / `arity' / `startLine' / `endLine' /
%% `newName' / `newArgs'（新函数参数名列表）。
%%
%% 生成单个 hunk：old = 提取块原文，new = 调用语句 + 新函数定义。
%% @end
%%--------------------------------------------------------------------
extractFunction(#{module := Mod, function := Fun, arity := Arity,
                  startLine := Start, endLine := End,
                  newName := NewName, newArgs := NewArgs} = _Args) ->
    FunAtom = toAtom(Fun),
    ArityInt = toInt(Arity),
    case parseModule(Mod) of
        {ok, Forms, Lines, Path} ->
            case locateFunctionForm(Forms, FunAtom, ArityInt) of
                {ok, _Form} ->
                    case extractLines(Lines, toInt(Start), toInt(End)) of
                        {ok, BlockText} ->
                            CallText = buildCall(NewName, NewArgs),
                            %% 根据提取块末尾分隔符决定调用末尾分隔符：
                            %% 块末尾是 `.`（函数体末尾表达式）→ 调用末尾用 `.`；
                            %% 块末尾是 `,`（中间表达式）→ 调用末尾用 `,`；
                            %% 否则默认 `,`。原 buildCall 硬编码 `,`，对函数体末尾
                            %% 表达式会生成非法 `call(...),` 序列，需由调用处决定。
                            Sep = callSeparator(BlockText),
                            CallText1 = <<CallText/binary, Sep/binary>>,
                            FnText = buildExtractedFunction(NewName, NewArgs, BlockText),
                            Old = BlockText,
                            New = <<CallText1/binary, "\n\n", FnText/binary>>,
                            {ok, #{
                                patches => [makeHunk(Path, Old, New)],
                                summary => <<"extracted ">>,
                                function => FunAtom,
                                arity => ArityInt,
                                newName => toAtom(NewName)
                            }};
                        {error, _} = E -> E
                    end;
                {error, _} = E -> E
            end;
        {error, _} = E -> E
    end;
extractFunction(_Args) ->
    {error, #{reason => missingFields,
              hint => <<"Require module/function/arity/startLine/endLine/newName/newArgs"/utf8>>}}.

%% 从 Lines 按 1-indexed 行号取 [Start, End] 范围文本（保留原缩进与换行）。
extractLines(Lines, Start, End) when is_integer(Start), is_integer(End), End >= Start ->
    Seg = lists:sublist(Lines, Start, End - Start + 1),
    case Seg of
        [] -> {error, #{reason => badLineRange, startLine => Start, endLine => End}};
        _ -> {ok, iolist_to_binary(lists:join(<<"\n">>, [toBinary(S) || S <- Seg]))}
    end.

%% 构造调用语句：`    newName(Arg1, Arg2, ...)'（4 空格缩进，不带尾随分隔符）。
%% 不硬编码尾随逗号——分隔符（`,`/`.`）由调用方根据上下文决定（见 callSeparator/1）。
buildCall(NewName, NewArgs) ->
    Name = toAtom(NewName),
    Args = [toAtom(A) || A <- ensureList(NewArgs)],
    ArgStr = lists:join(", ", [atom_to_binary(A, utf8) || A <- Args]),
    iolist_to_binary([<<"    ">>, atom_to_binary(Name, utf8), <<"(">>, ArgStr, <<")">>]).

%% 根据被替换块原文末尾分隔符决定调用末尾分隔符：
%% 块以 `.` 结尾 → 函数体末尾表达式 → 调用用 `.`；
%% 块以 `,` 结尾 → 中间表达式 → 调用用 `,`；
%% 其他 → 默认 `,`（保守，常见情况）。
callSeparator(BlockText) when is_binary(BlockText) ->
    Trimmed = binary:replace(BlockText,
                             [<<" ">>, <<"\t">>, <<"\n">>, <<"\r">>],
                             <<>>, [global]),
    case byte_size(Trimmed) of
        0 -> <<",">>;
        _ ->
            case binary:last(Trimmed) of
                $. -> <<".">>;
                $, -> <<",">>;
                _ -> <<",">>
            end
    end;
callSeparator(_) ->
    <<",">>.

%% 构造新函数定义：`newName(Args) ->\n    <提取块去外层缩进>.'。
buildExtractedFunction(NewName, NewArgs, BlockText) ->
    Name = toAtom(NewName),
    Args = [toAtom(A) || A <- ensureList(NewArgs)],
    ArgStr = lists:join(", ", [atom_to_binary(A, utf8) || A <- Args]),
    Body = dedent(BlockText),
    iolist_to_binary([
        atom_to_binary(Name, utf8), <<"(">>, ArgStr, <<") ->\n">>,
        Body, <<".\n">>
    ]).

%% 去除文本块每行的最小公共前导空白。
dedent(Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global]),
    Indents = [leadingSpaces(L) || L <- Lines, L =/= <<>>],
    Min = case Indents of [] -> 0; _ -> lists:min(Indents) end,
    Stripped = [stripPrefix(L, Min) || L <- Lines],
    iolist_to_binary(lists:join(<<"\n">>, Stripped)).

leadingSpaces(<<$\s, Rest/binary>>) -> 1 + leadingSpaces(Rest);
leadingSpaces(<<$\t, Rest/binary>>) -> 1 + leadingSpaces(Rest);
leadingSpaces(_) -> 0.

stripPrefix(Bin, 0) -> Bin;
stripPrefix(<<$\s, Rest/binary>>, N) -> stripPrefix(Rest, N - 1);
stripPrefix(<<$\t, Rest/binary>>, N) -> stripPrefix(Rest, N - 1);
stripPrefix(Bin, _N) -> Bin.

%%%===================================================================
%%% 模板 2: renameFunction
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 重命名函数 `function/arity' 为 `newName'，并改写当前模块内所有调用点。
%% 仅支持 `scope=module'（当前模块）；`scope=project' 需配合 findRefs，暂未实现。
%%
%% 生成单个 patch（多 hunk）：函数定义行 + 每个调用行，按词边界替换旧名。
%% @end
%%--------------------------------------------------------------------
renameFunction(#{module := Mod, function := Fun, arity := Arity,
                 newName := NewName} = Args) ->
    FunAtom = toAtom(Fun),
    ArityInt = toInt(Arity),
    NewAtom = toAtom(NewName),
    Scope = normalizeScope(maps:get(scope, Args, maps:get(<<"scope">>, Args, module))),
    case Scope of
        project ->
            {error, #{reason => scopeProjectNotSupported,
                      hint => <<"Use scope=module; for cross-module rename use findRefs + batchRefactor"/utf8>>}};
        module ->
            case parseModule(Mod) of
                {ok, Forms, Lines, Path} ->
                    LineNos = collectNameLines(Forms, FunAtom, ArityInt),
                    case LineNos of
                        [] ->
                            {error, #{reason => functionNotFound,
                                      module => Mod, function => FunAtom, arity => ArityInt}};
                        _ ->
                            Hunks = buildRenameHunks(Lines, LineNos, FunAtom, NewAtom),
                            {ok, #{
                                patches => [#{file => toBinary(Path), hunks => Hunks}],
                                summary => <<"renamed ">>,
                                function => FunAtom,
                                arity => ArityInt,
                                newName => NewAtom,
                                siteCount => length(Hunks)
                            }}
                    end;
                {error, _} = E -> E
            end
    end;
renameFunction(_Args) ->
    {error, #{reason => missingFields,
              hint => <<"Require module/function/arity/newName"/utf8>>}}.

%% 收集 forms 中与 Name/Arity 相关的行号：函数定义 + 同名调用（含 remote Mod:Name）。
collectNameLines(Forms, Name, Arity) ->
    lists:usort(lists:flatmap(fun(F) -> nameLinesInForm(F, Name, Arity) end, Forms)).

%% 在单个 form 内查找函数定义行与调用行。
nameLinesInForm({function, Anno, Name, Arity, _Clauses}, Name, Arity) ->
    [lineOf(Anno)];
nameLinesInForm({function, _Anno, _N, _A, Clauses}, Name, Arity) ->
    lists:flatmap(fun(C) -> callsInClause(C, Name, Arity) end, Clauses);
nameLinesInForm({attribute, _Anno, spec, {{Name, Arity}, _}}, Name, Arity) ->
    [];
nameLinesInForm(_F, _Name, _Arity) ->
    [].

%% 在 clause 体内查找 {call, _, {atom,_,Name}, Args}（长度=Arity）的调用行。
callsInClause({clause, _, _Pats, _Guards, Body}, Name, Arity) ->
    lists:flatmap(fun(E) -> callsInExpr(E, Name, Arity) end, Body);
callsInClause(_, _, _) -> [].

callsInExpr({call, Anno, {atom, _, Name}, Args}, Name, Arity)
  when length(Args) =:= Arity ->
    [lineOf(Anno) | lists:flatmap(fun(A) -> callsInExpr(A, Name, Arity) end, Args)];
callsInExpr({call, Anno, {remote, _, {atom, _, _Mod}, {atom, _, Name}}, Args}, Name, Arity)
  when length(Args) =:= Arity ->
    [lineOf(Anno) | lists:flatmap(fun(A) -> callsInExpr(A, Name, Arity) end, Args)];
callsInExpr(Tuple, Name, Arity) when is_tuple(Tuple) ->
    lists:flatmap(fun(E) -> callsInExpr(E, Name, Arity) end, tuple_to_list(Tuple));
callsInExpr(List, Name, Arity) when is_list(List) ->
    lists:flatmap(fun(E) -> callsInExpr(E, Name, Arity) end, List);
callsInExpr(_, _, _) -> [].

%% 按行号生成改名 hunk：每行 old=该行原文, new=该行把 `Name' 词边界替换为 NewName。
buildRenameHunks(Lines, LineNos, Name, NewName) ->
    NameBin = atom_to_binary(Name, utf8),
    NewBin = atom_to_binary(NewName, utf8),
    Pattern = <<"\\b", NameBin/binary, "\\b">>,
    lists:filtermap(
        fun(LineNo) ->
            case nthSafe(LineNo, Lines, undefined) of
                undefined -> false;
                LineBin0 ->
                    LineBin = toBinary(LineBin0),
                    case re:run(LineBin, Pattern) of
                        nomatch -> false;
                        _ ->
                            NewLine = re:replace(LineBin, Pattern, NewBin,
                                                 [global, {return, binary}]),
                            {true, #{old => LineBin, new => NewLine}}
                    end
            end
        end, LineNos).

normalizeScope(module) -> module;
normalizeScope(project) -> project;
normalizeScope(<<"module">>) -> module;
normalizeScope(<<"project">>) -> project;
normalizeScope(_) -> module.

%%%===================================================================
%%% 模板 3: changeSignature
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 修改函数头参数为 `newArgs'。仅生成函数头 hunk；调用点的参数调整
%% 由 LLM 用 `batchRefactor' 后续处理（参数重排场景多变，模板难以覆盖）。
%%
%% 必填：`module' / `function' / `arity' / `newArgs'（新参数名列表）。
%% @end
%%--------------------------------------------------------------------
changeSignature(#{module := Mod, function := Fun, arity := Arity, newArgs := NewArgs} = _Args) ->
    FunAtom = toAtom(Fun),
    ArityInt = toInt(Arity),
    case parseModule(Mod) of
        {ok, Forms, Lines, Path} ->
            case locateFunctionForm(Forms, FunAtom, ArityInt) of
                {ok, {function, Anno, FunAtom, ArityInt, _Clauses}} ->
                    Line = lineOf(Anno),
                    case lineAt(Lines, Line) of
                        {ok, LineText} ->
                            NewArgsList = [toAtom(A) || A <- ensureList(NewArgs)],
                            NewHead = buildNewHead(FunAtom, NewArgsList),
                            {ok, #{
                                patches => [makeHunk(Path, LineText, NewHead)],
                                summary => <<"changed signature; update call sites via batchRefactor"/utf8>>,
                                function => FunAtom,
                                arity => ArityInt,
                                newArity => length(NewArgsList),
                                hint => <<"Call sites NOT updated. Use batchRefactor to adjust arguments at each call site."/utf8>>
                            }};
                        {error, _} = E -> E
                    end;
                {error, _} = E -> E
            end;
        {error, _} = E -> E
    end;
changeSignature(_Args) ->
    {error, #{reason => missingFields,
              hint => <<"Require module/function/arity/newArgs"/utf8>>}}.

%% 取 1-indexed 第 N 行文本。
lineAt(Lines, N) when is_integer(N), N >= 1 ->
    case nthSafe(N, Lines, undefined) of
        undefined -> {error, #{reason => lineNotFound, line => N}};
        Bin -> {ok, toBinary(Bin)}
    end;
lineAt(_, _) -> {error, #{reason => badLine}}.

%% lists:nth/3 兼容封装：越界返回 Default。
nthSafe(1, [H | _], _Default) -> H;
nthSafe(N, [_ | T], Default) when N > 1 -> nthSafe(N - 1, T, Default);
nthSafe(_, [], Default) -> Default.

%% 构造新函数头行：`function(NewArg1, NewArg2) ->'。
buildNewHead(Name, NewArgs) ->
    ArgStr = lists:join(", ", [atom_to_binary(A, utf8) || A <- NewArgs]),
    iolist_to_binary([atom_to_binary(Name, utf8), <<"(">>, ArgStr, <<") ->">>]).

%%%===================================================================
%%% 模板 4: addTypespec
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 在函数定义前插入 `-spec'。`spec' 字段为 spec 文本（不含 `-spec' 前缀
%% 与结尾句点）或 `auto'（从函数 clauses 的参数模式尝试推断，仅基础类型）。
%%
%% 必填：`module' / `function' / `arity'；可选 `spec'。
%% @end
%%--------------------------------------------------------------------
addTypespec(#{module := Mod, function := Fun, arity := Arity} = Args) ->
    FunAtom = toAtom(Fun),
    ArityInt = toInt(Arity),
    Spec = maps:get(spec, Args, maps:get(<<"spec">>, Args, auto)),
    case parseModule(Mod) of
        {ok, Forms, Lines, Path} ->
            case hasSpec(Forms, FunAtom, ArityInt) of
                true ->
                    {error, #{reason => specAlreadyExists,
                              module => Mod, function => FunAtom, arity => ArityInt}};
                false ->
                    case locateFunctionForm(Forms, FunAtom, ArityInt) of
                        {ok, {function, Anno, FunAtom, ArityInt, Clauses}} ->
                            Line = lineOf(Anno),
                            SpecText = case Spec of
                                auto -> inferSpec(FunAtom, ArityInt, Clauses);
                                _ -> buildSpecText(FunAtom, ArityInt, toBinary(Spec))
                            end,
                            case SpecText of
                                undefined ->
                                    {error, #{reason => specInferFailed,
                                              hint => <<"Provide spec text or use getModuleTypes to inspect existing types"/utf8>>}};
                                _ ->
                                    case lineAt(Lines, Line) of
                                        {ok, LineText} ->
                                            New = <<SpecText/binary, "\n", LineText/binary>>,
                                            {ok, #{
                                                patches => [makeHunk(Path, LineText, New)],
                                                summary => <<"inserted -spec before ">>,
                                                function => FunAtom,
                                                arity => ArityInt,
                                                spec => SpecText
                                            }};
                                        {error, _} = E -> E
                                    end
                            end;
                        {error, _} = E -> E
                    end
            end;
        {error, _} = E -> E
    end;
addTypespec(_Args) ->
    {error, #{reason => missingFields,
              hint => <<"Require module/function/arity"/utf8>>}}.

%% 是否已存在该函数的 -spec。
hasSpec(Forms, Name, Arity) ->
    lists:any(fun(F) ->
        case F of
            {attribute, _, spec, {{N, A}, _}} when N =:= Name, A =:= Arity -> true;
            _ -> false
        end
    end, Forms).

%% 推断 spec：参数用 term()，返回值用 term()。仅基础占位，LLM 应修正。
inferSpec(Name, Arity, _Clauses) ->
    Args = lists:duplicate(Arity, <<"term()">>),
    ArgStr = lists:join(", ", Args),
    iolist_to_binary([
        <<"-spec ">>, atom_to_binary(Name, utf8), <<"(">>, ArgStr,
        <<") -> term().">>
    ]).

%% 构造 spec 文本：用户提供的 SpecBody 拼成 `-spec Name(SpecBody).'
buildSpecText(Name, _Arity, SpecBody) ->
    iolist_to_binary([<<"-spec ">>, atom_to_binary(Name, utf8),
                      <<"(">>, SpecBody, <<").">>]).

%%%===================================================================
%%% 辅助
%%%===================================================================

ensureList(L) when is_list(L), is_integer(hd(L)) -> [L];
ensureList(L) when is_list(L) -> L;
ensureList(B) when is_binary(B) -> [B];
ensureList(A) when is_atom(A) -> [A];
ensureList(undefined) -> [];
ensureList(Other) -> [Other].

toAtom(A) when is_atom(A) -> A;
toAtom(B) when is_binary(B) ->
    try binary_to_existing_atom(B, utf8) catch _:_ -> undefined end;
toAtom(L) when is_list(L) ->
    try list_to_existing_atom(L) catch _:_ -> undefined end;
toAtom(_) -> undefined.

toBinary(B) when is_binary(B) -> B;
toBinary(L) when is_list(L) -> unicode:characters_to_binary(L);
toBinary(A) when is_atom(A) -> atom_to_binary(A, utf8);
toBinary(I) when is_integer(I) -> integer_to_binary(I);
toBinary(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

toInt(N) when is_integer(N) -> N;
toInt(B) when is_binary(B) ->
    try binary_to_integer(B) catch _:_ -> 0 end;
toInt(L) when is_list(L) ->
    try list_to_integer(L) catch _:_ -> 0 end;
toInt(_) -> 0.
