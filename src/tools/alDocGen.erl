%%%-------------------------------------------------------------------
%% @doc 从 BEAM abstract forms + edoc 注释生成模块 API 文档。
%%
%% 合并来源：
%% <ul>
%% <li>abstract_code 中的 `-moduledoc` / `-doc` / `-spec`（OTP 27+）</li>
%% <li>对应 `.erl` 源中的 `%% @doc` edoc 块</li>
%% <li>可选的 Mermaid 依赖图（{@link alCoreClient:moduleDeps/1}）</li>
%% </ul>
%% 输出为适合聊天中 Mermaid 渲染的 Markdown。
%% @end
%%%-------------------------------------------------------------------

-module(alDocGen).

-export([
    generateModuleDoc/1,
    generateModuleDoc/2,
    mermaidCallEdges/2,
    mermaidCallEdges/3,
    mermaidModuleDeps/2,
    filterCallEdges/2,
    briefDocsFromEdges/1,
    extractBriefsFromErl/1
]).

%% Test helpers
-export([
    extractFromForms/1,
    parseEdocFromSource/1,
    toMarkdown/1
]).

-define(DefaultMaxFunctions, 80).

%%--------------------------------------------------------------------
%% @doc Generate docs for a module (map args or bare module name).
%% @end
%%--------------------------------------------------------------------
generateModuleDoc(#{module := Module} = Args) ->
    generateModuleDoc(Module, Args);
generateModuleDoc(Module) ->
    generateModuleDoc(Module, #{}).

generateModuleDoc(Module0, Opts) when is_map(Opts) ->
    case ensureAtom(Module0) of
        {ok, Module} ->
            MaxFuns = positiveInt(maps:get(maxFunctions, Opts, ?DefaultMaxFunctions),
                                  ?DefaultMaxFunctions),
            IncludeDeps = maps:get(includeDeps, Opts, true) =/= false,
            IncludeMarkdown = maps:get(includeMarkdown, Opts, true) =/= false,
            WritePath = maps:get(writePath, Opts,
                          maps:get(<<"writePath">>, Opts, undefined)),
            case buildDoc(Module, MaxFuns, IncludeDeps) of
                {ok, Doc1} ->
                    Doc2 = case IncludeMarkdown of
                        true -> Doc1#{markdown => toMarkdown(Doc1)};
                        false -> Doc1
                    end,
                    maybeWriteDoc(Doc2, WritePath);
                {error, _} = E ->
                    E
            end;
        error ->
            {error, #{reason => invalidModule, module => Module0}}
    end.

%% Prefer BEAM abstract; on no_abstract_code fall back to source edoc only.
buildDoc(Module, MaxFuns, IncludeDeps) ->
    case alToolsExt:getBeamAbstract(Module) of
        {ok, #{forms := Forms, path := BeamPath}} ->
            FromForms = extractFromForms(Forms),
            SourcePath = resolveSourcePath(Module, BeamPath),
            FromEdoc = readEdoc(SourcePath),
            finalizeDoc(Module, BeamPath, SourcePath, FromForms, FromEdoc,
                        MaxFuns, IncludeDeps, []);
        {error, no_abstract_code} ->
            SourcePath = resolveSourcePath(Module, undefined),
            case SourcePath of
                undefined ->
                    {error, #{
                        reason => no_abstract_code,
                        module => Module,
                        hint => <<"Recompile with debug_info, or ensure .erl is under src/. "
                                  "Edoc-only fallback needs a resolvable source path.">>
                    }};
                Src ->
                    FromEdoc = readEdoc(Src),
                    case maps:get(functions, FromEdoc, []) of
                        [] ->
                            {error, #{
                                reason => no_abstract_code,
                                module => Module,
                                sourcePath => Src,
                                hint => <<"BEAM has no abstract_code (compile with +debug_info). "
                                          "Source found but no %% @doc blocks parsed.">>
                            }};
                        _ ->
                            finalizeDoc(Module, undefined, Src, #{}, FromEdoc,
                                        MaxFuns, IncludeDeps,
                                        [<<"degraded: edoc-only (no BEAM abstract_code; "
                                           "recompile with debug_info for -spec/-doc)">>])
                    end
            end;
        {error, Reason} ->
            %% Still try source-only if module not loaded but path guess works.
            SourcePath = resolveSourcePath(Module, undefined),
            case {Reason, SourcePath} of
                {moduleNotLoaded, Src} when Src =/= undefined ->
                    FromEdoc = readEdoc(Src),
                    HasContent = maps:get(moduleDoc, FromEdoc, undefined) =/= undefined
                        orelse maps:get(functions, FromEdoc, []) =/= [],
                    case HasContent of
                        false ->
                            {error, #{reason => Reason, module => Module,
                                      hint => <<"Module not loaded; source had no edoc.">>}};
                        true ->
                            finalizeDoc(Module, undefined, Src, #{}, FromEdoc,
                                        MaxFuns, IncludeDeps,
                                        [<<"degraded: module not loaded; edoc-only from source">>])
                    end;
                _ ->
                    {error, #{reason => Reason, module => Module,
                              hint => hintForReason(Reason)}}
            end
    end.

readEdoc(undefined) -> #{};
readEdoc(Src) ->
    case file:read_file(Src) of
        {ok, Bin} -> parseEdocFromSource(Bin);
        {error, _} -> #{}
    end.

finalizeDoc(Module, BeamPath, SourcePath, FromForms, FromEdoc, MaxFuns, IncludeDeps, Warnings) ->
    Merged = mergeDocs(FromForms, FromEdoc),
    Funs0 = maps:get(functions, Merged, []),
    Funs = lists:sublist(sortFunctions(Funs0), MaxFuns),
    Doc = Merged#{
        module => Module,
        beamPath => BeamPath,
        sourcePath => SourcePath,
        functions => Funs,
        truncated => length(Funs0) > MaxFuns,
        warnings => Warnings
    },
    Doc1 = case IncludeDeps of
        true -> attachDeps(Doc, Module);
        false -> Doc
    end,
    {ok, Doc1}.

hintForReason(no_abstract_code) ->
    <<"Recompile the module with debug_info (+debug_info / rebar profile).">>;
hintForReason(moduleNotLoaded) ->
    <<"code:ensure_loaded(Module) or compile the project first.">>;
hintForReason(_) ->
    <<"Check module name and that the BEAM is available on this node.">>.

maybeWriteDoc(Doc, undefined) ->
    {ok, Doc};
maybeWriteDoc(Doc, <<>>) ->
    {ok, Doc};
maybeWriteDoc(Doc, WritePath0) ->
    Md = maps:get(markdown, Doc, toMarkdown(Doc)),
    Path = case WritePath0 of
        auto -> defaultDocPath(maps:get(module, Doc, unknown));
        <<"auto">> -> defaultDocPath(maps:get(module, Doc, unknown));
        Other -> Other
    end,
    case alToolsExt:writeFile(#{path => Path, content => Md}) of
        {ok, Wrote} ->
            {ok, Doc#{written => Wrote, writePath => Path}};
        {error, Reason} ->
            {ok, Doc#{writeError => Reason, writePath => Path}}
    end.

defaultDocPath(Module) ->
    Name = toBin(Module),
    filename:join(["priv", "docs", "api", <<Name/binary, ".md">>]).

%%--------------------------------------------------------------------
%% Filter call edges by module / function / arity (any side match).
%%--------------------------------------------------------------------
filterCallEdges(Edges, Filters) when is_list(Edges), is_map(Filters) ->
    Mod = normalizeFilter(maps:get(module, Filters,
                            maps:get(<<"module">>, Filters, undefined))),
    Fun = normalizeFilter(maps:get(function, Filters,
                            maps:get(<<"function">>, Filters, undefined))),
    Arity = maps:get(arity, Filters, maps:get(<<"arity">>, Filters, undefined)),
    case {Mod, Fun, Arity} of
        {undefined, undefined, undefined} -> Edges;
        _ ->
            lists:filter(fun(E) -> edgeMatches(E, Mod, Fun, Arity) end, Edges)
    end;
filterCallEdges(Edges, _) ->
    Edges.

normalizeFilter(undefined) -> undefined;
normalizeFilter(A) when is_atom(A) -> string:lowercase(atom_to_binary(A, utf8));
normalizeFilter(B) when is_binary(B) -> string:lowercase(B);
normalizeFilter(L) when is_list(L) -> string:lowercase(unicode:characters_to_binary(L));
normalizeFilter(_) -> undefined.

edgeMatches(E, Mod, Fun, Arity) when is_map(E) ->
    FromM = edgeStr(E, from_module),
    FromF = edgeStr(E, from_function),
    FromA = edgeInt(E, from_arity),
    ToM = edgeStr(E, to_module),
    ToF = edgeStr(E, to_function),
    ToA = edgeInt(E, arity),
    modOk(Mod, FromM, ToM)
        andalso funOk(Fun, FromF, ToF)
        andalso arityOk(Arity, FromA, ToA);
edgeMatches(_, _, _, _) ->
    false.

modOk(undefined, _, _) -> true;
modOk(Mod, FromM, ToM) -> FromM =:= Mod orelse ToM =:= Mod.

funOk(undefined, _, _) -> true;
funOk(Fun, FromF, ToF) -> FromF =:= Fun orelse ToF =:= Fun.

arityOk(undefined, _, _) -> true;
arityOk(A, FromA, ToA) when is_integer(A) -> FromA =:= A orelse ToA =:= A;
arityOk(_, _, _) -> true.

edgeStr(E, Key) ->
    BinKey = atom_to_binary(Key, utf8),
    case maps:get(Key, E, maps:get(BinKey, E, undefined)) of
        undefined -> <<>>;
        V -> string:lowercase(toBin(V))
    end.

edgeInt(E, Key) ->
    BinKey = atom_to_binary(Key, utf8),
    case maps:get(Key, E, maps:get(BinKey, E, undefined)) of
        N when is_integer(N) -> N;
        _ -> -1
    end.

%%--------------------------------------------------------------------
%% Walk abstract forms → moduleDoc + function entries with doc/spec.
%%--------------------------------------------------------------------
extractFromForms(Forms) when is_list(Forms) ->
    {ModDoc, Funs, _Pending} =
        lists:foldl(fun foldForm/2, {undefined, [], undefined}, Forms),
    #{
        moduleDoc => ModDoc,
        functions => lists:reverse(Funs)
    };
extractFromForms(_) ->
    #{moduleDoc => undefined, functions => []}.

%% Acc = {ModDoc, FunAcc, PendingDoc}
foldForm({attribute, _Anno, moduledoc, Doc}, {_ModDoc, Funs, Pending}) ->
    {normalizeDoc(Doc), Funs, Pending};
foldForm({attribute, _Anno, doc, Doc}, {ModDoc, Funs, _Pending}) ->
    {ModDoc, Funs, normalizeDoc(Doc)};
foldForm({attribute, _Anno, spec, Spec}, {ModDoc, Funs, Pending}) ->
    case parseSpec(Spec) of
        {ok, Name, Arity, SpecText} ->
            {Fun, Rest} = takeOrNewFun(Funs, Name, Arity),
            Fun1 = Fun#{spec => SpecText},
            Fun2 = case Pending of
                undefined -> Fun1;
                D -> Fun1#{doc => maps:get(doc, Fun1, D)}
            end,
            {ModDoc, [Fun2 | Rest], undefined};
        error ->
            {ModDoc, Funs, Pending}
    end;
foldForm({function, _Anno, Name, Arity, _Clauses}, {ModDoc, Funs, Pending})
  when is_atom(Name), is_integer(Arity) ->
    {Fun, Rest} = takeOrNewFun(Funs, Name, Arity),
    Fun1 = case Pending of
        undefined -> Fun;
        D -> Fun#{doc => maps:get(doc, Fun, D)}
    end,
    Fun2 = Fun1#{name => Name, arity => Arity},
    {ModDoc, [Fun2 | Rest], undefined};
foldForm({attribute, _Anno, export, Exports}, {ModDoc, Funs, Pending})
  when is_list(Exports) ->
    Marked = markExported(Funs, Exports),
    {ModDoc, Marked, Pending};
foldForm(_, Acc) ->
    Acc.

takeOrNewFun(Funs, Name, Arity) ->
    case lists:partition(fun(F) ->
            maps:get(name, F, undefined) =:= Name
                andalso maps:get(arity, F, undefined) =:= Arity
        end, Funs) of
        {[Existing | _], Rest} -> {Existing, Rest};
        {[], Rest} -> {#{name => Name, arity => Arity}, Rest}
    end.

markExported(Funs, Exports) ->
    Set = maps:from_list([{FA, true} || FA <- Exports]),
    [case maps:is_key({maps:get(name, F, undefined), maps:get(arity, F, undefined)}, Set) of
         true -> F#{exported => true};
         false -> F
     end || F <- Funs].

parseSpec({{Name, Arity}, Types}) when is_atom(Name), is_integer(Arity) ->
    Text = try
        unicode:characters_to_binary(erl_pp:form(
            {attribute, erl_anno:new(0), spec, {{Name, Arity}, Types}}))
    catch _:_ ->
        iolist_to_binary(io_lib:format("-spec ~p/~p.", [Name, Arity]))
    end,
    {ok, Name, Arity, Text};
parseSpec(_) ->
    error.

normalizeDoc(Bin) when is_binary(Bin) -> Bin;
normalizeDoc(List) when is_list(List) ->
    try unicode:characters_to_binary(List)
    catch _:_ -> list_to_binary(io_lib:format("~p", [List]))
    end;
normalizeDoc(Map) when is_map(Map) ->
    case maps:get(<<"en">>, Map, maps:get(en, Map, undefined)) of
        undefined ->
            case maps:get(<<"text">>, Map, maps:get(text, Map, undefined)) of
                undefined -> iolist_to_binary(io_lib:format("~p", [Map]));
                T -> normalizeDoc(T)
            end;
        T -> normalizeDoc(T)
    end;
normalizeDoc(Other) ->
    iolist_to_binary(io_lib:format("~p", [Other])).

%%--------------------------------------------------------------------
%% Parse `%% @doc ...` blocks from source (edoc style used in this repo).
%%--------------------------------------------------------------------
parseEdocFromSource(Bin) when is_binary(Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global]),
    {ModDoc, Funs} = scanEdoc(Lines, undefined, [], []),
    #{moduleDoc => ModDoc, functions => lists:reverse(Funs)};
parseEdocFromSource(_) ->
    #{}.

scanEdoc([], ModDoc, DocAcc, Funs) ->
    {ModDoc, maybeFlushDoc(DocAcc, Funs)};
scanEdoc([Line | Rest], ModDoc, DocAcc, Funs) ->
    Trim = trimBin(Line),
    case Trim of
        <<"%% @doc", After/binary>> ->
            scanEdoc(Rest, ModDoc, [trimBin(After)], Funs);
        <<"%%% @doc", After/binary>> ->
            scanEdoc(Rest, ModDoc, [trimBin(After)], Funs);
        <<"%% @end", _/binary>> when DocAcc =/= [] ->
            %% Keep accumulating until function/-export; @end just closes prose.
            scanEdoc(Rest, ModDoc, DocAcc, Funs);
        <<"%%", After/binary>> when DocAcc =/= [] ->
            case After of
                <<" @", _/binary>> ->
                    %% Other edoc tag — flush later at function.
                    scanEdoc(Rest, ModDoc, DocAcc, Funs);
                _ ->
                    scanEdoc(Rest, ModDoc, DocAcc ++ [trimBin(After)], Funs)
            end;
        _ ->
            case {DocAcc, matchFunctionHead(Trim)} of
                {[], _} ->
                    scanEdoc(Rest, ModDoc, [], Funs);
                {Docs, {ok, Name, Arity}} ->
                    Text = joinDocs(Docs),
                    Fun = #{name => Name, arity => Arity, doc => Text},
                    scanEdoc(Rest, ModDoc, [], [Fun | Funs]);
                {Docs, error} ->
                    case isModuleAttr(Trim) of
                        true ->
                            Text = joinDocs(Docs),
                            scanEdoc(Rest, coalesce(ModDoc, Text), [], Funs);
                        false ->
                            %% Keep pending docs across blank / attribute lines until fun head.
                            scanEdoc(Rest, ModDoc, Docs, Funs)
                    end
            end
    end.

maybeFlushDoc([], Funs) -> Funs;
maybeFlushDoc(_Docs, Funs) -> Funs.

joinDocs(Parts) ->
    unicode:characters_to_binary(lists:join(<<"\n">>, [P || P <- Parts, P =/= <<>>])).

matchFunctionHead(Line) ->
    %% name(Args...) ->  or name/Arity in -export is handled separately
    case re:run(Line, <<"^([a-z][a-zA-Z0-9_]*)\\s*\\((.*)\\)\\s*(?:->|when)">>,
                [{capture, all_but_first, binary}]) of
        {match, [NameBin, ArgsBin]} ->
            %% 源码解析：仅对已校验的 Erlang 标识符建原子（非 LLM 输入）。
            %% existing 优先；新函数名允许 binary_to_atom，避免 DocGen 丢简述。
            Name = try binary_to_existing_atom(NameBin, utf8)
                   catch _:_ ->
                       case byte_size(NameBin) =< 255 andalso
                            re:run(NameBin, <<"^[a-z][A-Za-z0-9_]*$">>,
                                   [{capture, none}]) =:= match of
                           true -> binary_to_atom(NameBin, utf8);
                           false -> undefined
                       end
                   end,
            case Name of
                undefined -> error;
                _ ->
                    Arity = countArgs(ArgsBin),
                    {ok, Name, Arity}
            end;
        nomatch ->
            error
    end.

countArgs(<<>>) -> 0;
countArgs(Bin) ->
    Trim = trimBin(Bin),
    case Trim of
        <<>> -> 0;
        _ ->
            %% Rough arity: top-level commas outside brackets.
            length(splitTopLevel(Trim, $,)) 
    end.

splitTopLevel(Bin, Sep) ->
    splitTopLevel(Bin, Sep, 0, 0, <<>>, []).

splitTopLevel(<<>>, _Sep, _P, _B, Acc, Parts) ->
    lists:reverse([Acc | Parts]);
splitTopLevel(<<C, Rest/binary>>, Sep, Paren, Brack, Acc, Parts) ->
    case {C, Paren, Brack} of
        {Sep, 0, 0} ->
            splitTopLevel(Rest, Sep, 0, 0, <<>>, [Acc | Parts]);
        {$(, P, B} ->
            splitTopLevel(Rest, Sep, P + 1, B, <<Acc/binary, C>>, Parts);
        {$), P, B} when P > 0 ->
            splitTopLevel(Rest, Sep, P - 1, B, <<Acc/binary, C>>, Parts);
        {$[, P, B} ->
            splitTopLevel(Rest, Sep, P, B + 1, <<Acc/binary, C>>, Parts);
        {$], P, B} when B > 0 ->
            splitTopLevel(Rest, Sep, P, B - 1, <<Acc/binary, C>>, Parts);
        _ ->
            splitTopLevel(Rest, Sep, Paren, Brack, <<Acc/binary, C>>, Parts)
    end.

isModuleAttr(<<"-module", _/binary>>) -> true;
isModuleAttr(_) -> false.

%%--------------------------------------------------------------------
mergeDocs(FromForms, FromEdoc) ->
    ModDoc = coalesce(maps:get(moduleDoc, FromForms, undefined),
                      maps:get(moduleDoc, FromEdoc, undefined)),
    ByKey = maps:new(),
    ByKey1 = foldFunsInto(ByKey, maps:get(functions, FromEdoc, [])),
    ByKey2 = foldFunsInto(ByKey1, maps:get(functions, FromForms, [])),
    Funs = maps:values(ByKey2),
    #{moduleDoc => ModDoc, functions => Funs}.

foldFunsInto(Map, Funs) ->
    lists:foldl(fun(F, Acc) ->
        Name = maps:get(name, F, undefined),
        Arity = maps:get(arity, F, undefined),
        case {Name, Arity} of
            {N, A} when is_atom(N), is_integer(A) ->
                Key = {N, A},
                Prev = maps:get(Key, Acc, #{}),
                maps:put(Key, maps:merge(Prev, F), Acc);
            _ ->
                Acc
        end
    end, Map, Funs).

sortFunctions(Funs) ->
    lists:sort(fun(A, B) ->
        {maps:get(name, A, ''), maps:get(arity, A, 0)}
            =< {maps:get(name, B, ''), maps:get(arity, B, 0)}
    end, Funs).

attachDeps(Doc, Module) ->
    try alCoreClient:unwrap(alCoreClient:moduleDeps(Module)) of
        {ok, Res} when is_map(Res) ->
            Deps = maps:get(deps, Res, maps:get(<<"deps">>, Res, [])),
            Mermaid = mermaidModuleDeps(Module, Deps),
            Doc#{deps => Deps, mermaid => Mermaid};
        _ ->
            Doc
    catch
        _:_ -> Doc
    end.

%%--------------------------------------------------------------------
toMarkdown(Doc) when is_map(Doc) ->
    Module = maps:get(module, Doc, unknown),
    ModName = toBin(Module),
    Parts0 = [
        <<"# ", ModName/binary, "\n\n">>
    ],
    Parts1 = case maps:get(moduleDoc, Doc, undefined) of
        undefined -> Parts0;
        MD when is_binary(MD), MD =/= <<>> ->
            Parts0 ++ [MD, <<"\n\n">>];
        _ -> Parts0
    end,
    Parts2 = Parts1 ++ [<<"## Functions\n\n">>],
    FunParts = lists:flatmap(fun formatFunMd/1, maps:get(functions, Doc, [])),
    Parts3 = Parts2 ++ FunParts,
    Parts4 = case maps:get(mermaid, Doc, undefined) of
        undefined -> Parts3;
        Mermaid when is_binary(Mermaid), Mermaid =/= <<>> ->
            Parts3 ++ [
                <<"## Module dependencies\n\n">>,
                <<"```mermaid\n">>, Mermaid, <<"\n```\n">>
            ];
        _ -> Parts3
    end,
    case maps:get(truncated, Doc, false) of
        true ->
            unicode:characters_to_binary(Parts4 ++ [
                <<"\n_…truncated: showing first functions only._\n"/utf8>>
            ]);
        false ->
            unicode:characters_to_binary(Parts4)
    end.

formatFunMd(F) when is_map(F) ->
    Name = toBin(maps:get(name, F, '?')),
    Arity = maps:get(arity, F, 0),
    Exp = case maps:get(exported, F, undefined) of
        true -> <<" (exported)">>;
        _ -> <<>>
    end,
    Head = [<<"### `", Name/binary, "/", (integer_to_binary(Arity))/binary, "`",
              Exp/binary, "\n\n">>],
    SpecPart = case maps:get(spec, F, undefined) of
        undefined -> [];
        Spec when is_binary(Spec) -> [<<"```erlang\n">>, Spec, <<"\n```\n\n">>];
        _ -> []
    end,
    DocPart = case maps:get(doc, F, undefined) of
        undefined -> [];
        D when is_binary(D), D =/= <<>> -> [D, <<"\n\n">>];
        _ -> []
    end,
    Head ++ SpecPart ++ DocPart.

mermaidModuleDeps(Module, Deps) when is_list(Deps) ->
    Mod = sanitizeId(Module),
    Edges = lists:sublist([D || D <- Deps], 40),
    Lines = [<<"flowchart LR">>, <<"  ", Mod/binary, "(", (toBin(Module))/binary, ")">> |
             [begin
                  DepId = sanitizeId(D),
                  <<"  ", Mod/binary, " --> ", DepId/binary, "[", (toBin(D))/binary, "]">>
              end || D <- Edges]],
    unicode:characters_to_binary(lists:join(<<"\n">>, Lines));
mermaidModuleDeps(_, _) ->
    <<>>.

%%--------------------------------------------------------------------
%% Call-graph Mermaid helpers (shared by router enrichment)
%%--------------------------------------------------------------------
mermaidCallEdges(Edges, MaxEdges) ->
    mermaidCallEdges(Edges, MaxEdges, #{}).

mermaidCallEdges(Edges, MaxEdges, Briefs) when is_list(Edges), is_map(Briefs) ->
    Cap = positiveInt(MaxEdges, 60),
    Taken = lists:sublist(Edges, Cap),
    Lines = [<<"flowchart LR">> |
             lists:filtermap(fun(E) -> edgeToMermaid(E, Briefs) end, Taken)],
    unicode:characters_to_binary(lists:join(<<"\n">>, Lines));
mermaidCallEdges(_, _, _) ->
    <<>>.

edgeToMermaid(E, Briefs) when is_map(E), is_map(Briefs) ->
    FromM = maps:get(from_module, E, maps:get(<<"from_module">>, E, undefined)),
    FromF = maps:get(from_function, E, maps:get(<<"from_function">>, E, undefined)),
    FromA = maps:get(from_arity, E, maps:get(<<"from_arity">>, E, 0)),
    ToM = maps:get(to_module, E, maps:get(<<"to_module">>, E, undefined)),
    ToF = maps:get(to_function, E, maps:get(<<"to_function">>, E, undefined)),
    ToA = maps:get(arity, E, maps:get(<<"arity">>, E, 0)),
    case {FromF, ToF} of
        {undefined, _} -> false;
        {_, undefined} -> false;
        _ ->
            FromLabel = mfaLabel(FromM, FromF, FromA),
            ToLabel = mfaLabel(ToM, ToF, ToA),
            FromId = sanitizeId(FromLabel),
            ToId = sanitizeId(ToLabel),
            FromDisp = mfaDisplay(FromLabel, Briefs),
            ToDisp = mfaDisplay(ToLabel, Briefs),
            {true, <<"  ", FromId/binary, "[\"", FromDisp/binary, "\"] --> ",
                     ToId/binary, "[\"", ToDisp/binary, "\"]">>}
    end;
edgeToMermaid(_, _) ->
    false.

mfaLabel(Mod, Fun, Arity) ->
    M = case Mod of
        undefined -> <<"?">>;
        _ -> toBin(Mod)
    end,
    F = toBin(Fun),
    A = case Arity of
        N when is_integer(N) -> integer_to_binary(N);
        _ -> <<"?">>
    end,
    <<M/binary, ":", F/binary, "/", A/binary>>.

mfaDisplay(Label, Briefs) when is_binary(Label), is_map(Briefs) ->
    Esc = escapeMermaidText(Label),
    case maps:get(Label, Briefs, undefined) of
        undefined -> Esc;
        <<>> -> Esc;
        Brief ->
            <<Esc/binary, "<br/>", (escapeMermaidText(Brief))/binary>>
    end;
mfaDisplay(Label, _) ->
    escapeMermaidText(toBin(Label)).

escapeMermaidText(Bin) when is_binary(Bin) ->
    %% 节点文案用双引号包裹；去掉会破坏语法的字符。
    B1 = binary:replace(Bin, <<"\"">>, <<"'">>, [global]),
    B2 = binary:replace(B1, <<"\n">>, <<" ">>, [global]),
    binary:replace(B2, <<"\r">>, <<>>, [global]);
escapeMermaidText(Other) ->
    escapeMermaidText(toBin(Other)).

%%--------------------------------------------------------------------
%% 从索引模块源码提取 MFA 简述（%% @doc / 函数上方 %%，不经 LLM）。
%% 返回 #{<<"mod:fun/arity">> => <<"简述"/utf8>>}。
%%--------------------------------------------------------------------
briefDocsFromEdges(Edges) when is_list(Edges) ->
    Wanted = lists:usort(lists:flatmap(fun edgeMfaPairs/1, Edges)),
    ByMod = groupMfasByModule(Wanted),
    Mods = lists:sublist(maps:keys(ByMod), 40),
    lists:foldl(fun(Mod, Acc) ->
        case loadModuleFunBriefs(Mod) of
            {ok, FunMap} ->
                lists:foldl(fun({Fun, Arity}, Acc2) ->
                    case lookupFunBrief(FunMap, Fun, Arity) of
                        undefined -> Acc2;
                        Brief ->
                            Acc2#{mfaLabel(Mod, Fun, Arity) => Brief}
                    end
                end, Acc, maps:get(Mod, ByMod, []));
            _ ->
                Acc
        end
    end, #{}, Mods);
briefDocsFromEdges(_) ->
    #{}.

edgeMfaPairs(E) when is_map(E) ->
    FromM = maps:get(from_module, E, maps:get(<<"from_module">>, E, undefined)),
    FromF = maps:get(from_function, E, maps:get(<<"from_function">>, E, undefined)),
    FromA = maps:get(from_arity, E, maps:get(<<"from_arity">>, E, 0)),
    ToM = maps:get(to_module, E, maps:get(<<"to_module">>, E, undefined)),
    ToF = maps:get(to_function, E, maps:get(<<"to_function">>, E, undefined)),
    ToA = maps:get(arity, E, maps:get(<<"arity">>, E, 0)),
    lists:filter(fun({_M, F, _A}) -> F =/= undefined end,
                 [{FromM, FromF, FromA}, {ToM, ToF, ToA}]);
edgeMfaPairs(_) ->
    [].

groupMfasByModule(Pairs) ->
    lists:foldl(fun({Mod, Fun, Arity}, Acc) ->
        M = case Mod of undefined -> <<"?">>; _ -> toBin(Mod) end,
        Funs0 = maps:get(M, Acc, []),
        Acc#{M => lists:usort([{toBin(Fun), normalizeArity(Arity)} | Funs0])}
    end, #{}, Pairs).

normalizeArity(N) when is_integer(N) -> N;
normalizeArity(_) -> 0.

loadModuleFunBriefs(Mod) ->
    case alCoreClient:moduleSymbols(Mod) of
        {ok, Raw} when is_map(Raw) ->
            Data = alCoreClient:unwrapMap(Raw),
            Doc = case maps:get(document, Data, maps:get(<<"document">>, Data, undefined)) of
                D when is_map(D) -> D;
                _ -> Data
            end,
            File = maps:get(file, Doc, maps:get(<<"file">>, Doc, undefined)),
            case File of
                undefined -> {error, noFile};
                null -> {error, noFile};
                <<>> -> {error, noFile};
                Path ->
                    PathStr = case Path of
                        B when is_binary(B) -> unicode:characters_to_list(B);
                        L when is_list(L) -> L;
                        _ -> undefined
                    end,
                    case PathStr =/= undefined andalso file:read_file(PathStr) of
                        {ok, Bin} -> {ok, extractBriefsFromErl(Bin)};
                        false -> {error, badPath};
                        {error, Reason} -> {error, Reason}
                    end
            end;
        {ok, _} ->
            {error, badResponse};
        {error, Reason} ->
            {error, Reason};
        _ ->
            {error, unavailable}
    end.

lookupFunBrief(FunMap, Fun, Arity) when is_map(FunMap) ->
    KeyBin = {toBin(Fun), normalizeArity(Arity)},
    case maps:get(KeyBin, FunMap, undefined) of
        undefined ->
            case Fun of
                A when is_atom(A) -> maps:get({A, normalizeArity(Arity)}, FunMap, undefined);
                _ -> undefined
            end;
        Brief -> Brief
    end;
lookupFunBrief(_, _, _) ->
    undefined.

%% 解析 .erl：优先 %% @doc，否则取函数头上方连续 %% 注释首行。
extractBriefsFromErl(Bin) when is_binary(Bin) ->
    Edoc = edocBriefMap(parseEdocFromSource(Bin)),
    Plain = plainBriefMap(binary:split(Bin, <<"\n">>, [global])),
    maps:merge(Plain, Edoc);
extractBriefsFromErl(_) ->
    #{}.

edocBriefMap(#{functions := Funs}) when is_list(Funs) ->
    lists:foldl(fun
        (F, Acc) when is_map(F) ->
            Name = maps:get(name, F, undefined),
            Arity = maps:get(arity, F, undefined),
            Doc = maps:get(doc, F, <<>>),
            Brief = firstLineBrief(Doc),
            case {Name, Arity, Brief} of
                {N, A, B} when N =/= undefined, is_integer(A), B =/= <<>> ->
                    Acc#{{toBin(N), A} => B};
                _ ->
                    Acc
            end;
        (_, Acc) ->
            Acc
    end, #{}, Funs);
edocBriefMap(_) ->
    #{}.

plainBriefMap(Lines) when is_list(Lines) ->
    plainBriefScan(Lines, [], #{});
plainBriefMap(_) ->
    #{}.

plainBriefScan([], _Pending, Acc) ->
    Acc;
plainBriefScan([Line | Rest], Pending, Acc) ->
    Trim = trimBin(Line),
    case Trim of
        <<>> ->
            plainBriefScan(Rest, Pending, Acc);
        <<"-spec", _/binary>> ->
            plainBriefScan(Rest, Pending, Acc);
        <<"-doc", _/binary>> ->
            plainBriefScan(Rest, Pending, Acc);
        <<"-export", _/binary>> ->
            plainBriefScan(Rest, [], Acc);
        <<"-moduledoc", _/binary>> ->
            plainBriefScan(Rest, [], Acc);
        <<"%%%", _/binary>> ->
            %% 文件级头注释，不作为函数简述
            plainBriefScan(Rest, [], Acc);
        <<"%%", After/binary>> ->
            AfterTrim = trimBin(After),
            %% 注释里出现“被注释掉的函数头”（形如 %%foo(A)-> / %%foo(A) ->）
            %% 或装饰分隔线时，应断开 Pending，避免把上一段注释污染到下一函数。
            %% 分隔线（%% ---）在现有解析用例里是“描述字段的外框”，不能清空 Pending，
            %% 只在真正的“注释函数头”出现时清空。
            case isCommentedFunctionHead(AfterTrim) of
                true ->
                    plainBriefScan(Rest, [], Acc);
                false ->
                    case commentLineForBrief(AfterTrim) of
                        skip -> plainBriefScan(Rest, Pending, Acc);
                        <<>> -> plainBriefScan(Rest, Pending, Acc);
                        C -> plainBriefScan(Rest, Pending ++ [C], Acc)
                    end
            end;
        _ ->
            case matchFunctionHead(Trim) of
                {ok, Name, Arity} when Pending =/= [], Name =/= undefined ->
                    Brief = briefFromCommentLines(Pending),
                    Acc1 = case Brief of
                        <<>> -> Acc;
                        _ -> Acc#{{toBin(Name), Arity} => Brief}
                    end,
                    plainBriefScan(Rest, [], Acc1);
                _ ->
                    plainBriefScan(Rest, [], Acc)
            end
    end.

commentLineForBrief(<<"@doc", Rest/binary>>) ->
    trimBin(Rest);
commentLineForBrief(<<"@end", _/binary>>) ->
    skip;
commentLineForBrief(<<"@", _/binary>>) ->
    skip;
commentLineForBrief(Other) ->
    case isNoiseCommentLine(Other) of
        true -> skip;
        false -> Other
    end.

%% 注释行里“函数头”判定：用于断开 Pending 的噪声边界
isCommentedFunctionHead(Bin) when is_binary(Bin) ->
    re:run(Bin,
           <<"^[A-Za-z_][A-Za-z0-9_]*\\([^\\)]*\\)\\s*(?:when\\s+.*)?\\s*->">>,
           [{capture, none}]) =:= match;
isCommentedFunctionHead(_) ->
    false.

%% 优先 Description:；否则取第一条有意义注释（跳过分隔线 / 空 Func:/Returns:）。
firstLineBrief(Bin) when is_binary(Bin) ->
    briefFromCommentLines(binary:split(Bin, <<"\n">>, [global]));
firstLineBrief(_) ->
    <<>>.

briefFromCommentLines(Parts) when is_list(Parts) ->
    case findDescriptionBrief(Parts) of
        <<>> -> firstMeaningfulBrief(Parts);
        B -> B
    end;
briefFromCommentLines(_) ->
    <<>>.

findDescriptionBrief([]) ->
    <<>>;
findDescriptionBrief([P | Rest]) ->
    case matchDescriptionField(trimBin(P)) of
        {ok, Text} when Text =/= <<>> ->
            truncateBrief(Text, 36);
        _ ->
            findDescriptionBrief(Rest)
    end.

matchDescriptionField(Bin) when is_binary(Bin) ->
    %% Description: / Description： / Desc: / 描述:
    case re:run(Bin,
                <<"^(?:Description|Desc|描述)\\s*[:：]\\s*(.*)$"/utf8>>,
                [{capture, all_but_first, binary}, caseless, unicode]) of
        {match, [Rest]} -> {ok, trimBin(Rest)};
        nomatch -> false
    end;
matchDescriptionField(_) ->
    false.

firstMeaningfulBrief(Parts) ->
    lists:foldl(fun(P, Acc) ->
        case Acc of
            <<>> ->
                T = trimBin(P),
                case isNoiseCommentLine(T) of
                    true ->
                        <<>>;
                    false ->
                        case matchDescriptionField(T) of
                            {ok, Text} when Text =/= <<>> ->
                                truncateBrief(Text, 36);
                            {ok, _} ->
                                <<>>;
                            false ->
                                truncateBrief(T, 36)
                        end
                end;
            _ ->
                Acc
        end
    end, <<>>, Parts).

isNoiseCommentLine(<<>>) ->
    true;
isNoiseCommentLine(Bin) when is_binary(Bin) ->
    isSeparatorLine(Bin)
        orelse isEmptyLabeledField(Bin)
        orelse isCommentedErlangCodeLine(Bin);
isNoiseCommentLine(_) ->
    true.

%% ---- / ==== / **** 一类装饰分隔线
isSeparatorLine(Bin) ->
    re:run(Bin, <<"^[\\s\\-=*_~]+$">>, [{capture, none}]) =:= match.

%% Func: / Returns: / Description: 等仅标签无正文
isEmptyLabeledField(Bin) ->
    case re:run(Bin,
                <<"^(?:Func|Function|Name|Description|Desc|描述|Returns?|Params?|Args?|Author|Created|Modified|Spec|Note|Notes|See)\\s*[:：]\\s*$"/utf8>>,
                [{capture, none}, caseless, unicode]) of
        match -> true;
        nomatch -> false
    end.

%% 简述里尽量跳过注释掉的“代码语句”，避免把 `X = ...` 当成描述
isCommentedErlangCodeLine(Bin) when is_binary(Bin) ->
    %% 形如：foo = bar(...) 或 foo = 123,
    re:run(Bin,
           <<"^[A-Za-z_][A-Za-z0-9_]*\\s*=.*">>,
           [{capture, none}]) =:= match;
isCommentedErlangCodeLine(_) ->
    false.

truncateBrief(Bin, Max) when is_binary(Bin), is_integer(Max), Max > 0 ->
    Chars = unicode:characters_to_list(Bin),
    case is_list(Chars) andalso length(Chars) > Max of
        true ->
            unicode:characters_to_binary(lists:sublist(Chars, Max) ++ [8230]);
        false when is_list(Chars) ->
            Bin;
        _ ->
            case byte_size(Bin) > Max * 3 of
                true -> binary:part(Bin, 0, min(byte_size(Bin), Max * 3));
                false -> Bin
            end
    end;
truncateBrief(_, _) ->
    <<>>.

%%--------------------------------------------------------------------
resolveSourcePath(Module, BeamPath) when is_atom(Module) ->
    try Module:module_info(compile) of
        Info when is_list(Info) ->
            case proplists:get_value(source, Info, undefined) of
                Src when is_list(Src) ->
                    case filelib:is_regular(Src) of
                        true -> Src;
                        false -> fallbackErl(Module, BeamPath)
                    end;
                _ ->
                    fallbackErl(Module, BeamPath)
            end;
        _ ->
            fallbackErl(Module, BeamPath)
    catch
        _:_ -> fallbackErl(Module, BeamPath)
    end;
resolveSourcePath(_, BeamPath) ->
    beamToErl(BeamPath).

fallbackErl(Module, BeamPath) ->
    case beamToErl(BeamPath) of
        undefined -> guessErlByBasename(atom_to_list(Module) ++ ".erl");
        Path -> Path
    end.

beamToErl(undefined) ->
    undefined;
beamToErl(BeamPath) when is_list(BeamPath) ->
    case filename:extension(BeamPath) of
        ".beam" ->
            Erl = filename:rootname(BeamPath) ++ ".erl",
            case filelib:is_regular(Erl) of
                true -> Erl;
                false -> guessErlByBasename(filename:basename(Erl))
            end;
        _ ->
            undefined
    end;
beamToErl(_) ->
    undefined.

guessErlByBasename(Base) when is_list(Base) ->
    Candidates = [
        filename:join(["src", Base]),
        filename:join(["src", "tools", Base]),
        filename:join(["src", "agent", Base]),
        filename:join(["src", "web", Base]),
        filename:join(["src", "core", Base]),
        filename:join(["src", "llm", Base]),
        filename:join(["src", "db", Base]),
        filename:join(["src", "misc", Base]),
        filename:join(["src", "mcp", Base])
    ],
    firstExisting(Candidates).

firstExisting([]) -> undefined;
firstExisting([P | Rest]) ->
    case filelib:is_regular(P) of
        true -> P;
        false -> firstExisting(Rest)
    end.

%%--------------------------------------------------------------------
ensureAtom(A) when is_atom(A) -> {ok, A};
ensureAtom(B) when is_binary(B) ->
    try {ok, binary_to_existing_atom(B, utf8)}
    catch _:_ -> error
    end;
ensureAtom(L) when is_list(L) ->
    ensureAtom(list_to_binary(L));
ensureAtom(_) -> error.

positiveInt(N, _Def) when is_integer(N), N > 0 -> N;
positiveInt(_, Def) -> Def.

coalesce(undefined, B) -> B;
coalesce(<<>>, B) -> B;
coalesce(A, _) -> A.

toBin(A) when is_atom(A) -> atom_to_binary(A, utf8);
toBin(B) when is_binary(B) -> B;
toBin(L) when is_list(L) -> unicode:characters_to_binary(L);
toBin(N) when is_integer(N) -> integer_to_binary(N);
toBin(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

sanitizeId(Term) ->
    Bin = toBin(Term),
    re:replace(Bin, <<"[^A-Za-z0-9_]">>, <<"_">>, [global, {return, binary}]).

trimBin(Bin) when is_binary(Bin) ->
    string:trim(Bin);
trimBin(Other) ->
    trimBin(toBin(Other)).
