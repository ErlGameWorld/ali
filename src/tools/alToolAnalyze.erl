%%%-------------------------------------------------------------------
%%% @doc 代码分析工具集。
%%%
%%% 为 Agent 提供源码索引、函数调用分析、调用者查找、BEAM 抽象码、
%%% behaviour 分析、模块依赖图、调用图及代码质量检查等能力。
%%% 底层依赖 {@link alCodeIndexer} 与 {@link alAst}。
%%% @end
%%%-------------------------------------------------------------------
-module(alToolAnalyze).

-export([
    codeIndex/2,
    searchCodeIndex/2,
    searchCode/2,
    semanticSearch/2,
    getFunctionSource/2,
    analyzeCalls/2,
    findCallers/2,
    getBeamAbstract/2,
    analyzeBehaviours/2,
    moduleDependencies/2,
    dependencyGraph/2,
    analyzeCallGraph/2,
    codeQuality/2
]).

-define(MAX_SOURCE_LINES, 200).
-define(MAX_ABSTRACT, 12000).

%% @doc 刷新或返回代码索引统计；`force` 为 true 时强制重建索引。
-spec codeIndex(map(), map()) -> {ok, map()} | {error, term()}.
codeIndex(Args, Config) ->
    Force = maps:get(force, Args, false),
    case Force of
        true -> alCodeIndexer:refresh(Config);
        false ->
            Stats = alCodeIndexer:getStats(),
            case maps:get(moduleCount, Stats, 0) of
                0 -> alCodeIndexer:refresh(Config);
                _ -> {ok, Stats#{cached => true}}
            end
    end.

%% @doc 语义/关键词检索：按自然语言查询返回最相关的函数代码片段（TF-IDF）。
%% Args: `query`（必填）、`limit`（默认 5）、`reindex`（true 时强制重建语料）。
-spec searchCode(map(), map()) -> {ok, map()} | {error, term()}.
searchCode(Args, Config) ->
    case maps:get(query, Args, undefined) of
        undefined ->
            {error, missingQuery};
        Query ->
            case maps:get(reindex, Args, false) of
                true -> alRag:index(Config);
                false -> ok
            end,
            Limit = maps:get(limit, Args, 5),
            {ok, Results} = alRag:search(Query, #{limit => Limit}, Config),
            {ok, #{query => to_binary(Query), count => length(Results), results => Results}}
    end.

%% @doc 向量语义检索：强制使用混合（向量+TF-IDF）模式，适合自然语言查询。
%% 当 embedding 不可用时自动降级为 TF-IDF。
%% Args: `query`（必填）、`limit`（默认 5）、`reindex`（true 时强制重建语料）、
%%       `vectorWeight`/`tfidfWeight`（融合权重，默认 0.6/0.4）。
-spec semanticSearch(map(), map()) -> {ok, map()} | {error, term()}.
semanticSearch(Args, Config) ->
    case maps:get(query, Args, undefined) of
        undefined ->
            {error, missingQuery};
        Query ->
            case maps:get(reindex, Args, false) of
                true -> alRag:index(Config);
                false -> ok
            end,
            Limit = maps:get(limit, Args, 5),
            Opts = #{
                limit => Limit,
                vectorWeight => maps:get(vectorWeight, Args, 0.6),
                tfidfWeight => maps:get(tfidfWeight, Args, 0.4)
            },
            Mode = alRag:mode(),
            case Mode of
                hybrid ->
                    {ok, Results} = alRag:searchHybrid(Query, Opts, Config),
                    {ok, #{
                        query => to_binary(Query),
                        count => length(Results),
                        mode => hybrid,
                        results => Results
                    }};
                tfidf ->
                    %% embedding 不可用，降级为 TF-IDF
                    {ok, Results} = alRag:search(Query, Opts, Config),
                    {ok, #{
                        query => to_binary(Query),
                        count => length(Results),
                        mode => tfidf,
                        results => Results
                    }}
            end
    end.

%% @doc 在代码索引中搜索模块名/函数名（子串匹配，不区分大小写）。
-spec searchCodeIndex(map(), map()) -> {ok, map()} | {error, term()}.
searchCodeIndex(Args, Config) ->
    _ = ensure_index(Config),
    Query = maps:get(query, Args, undefined),
    MaxResults = maps:get(maxResults, Args, 30),
    case Query of
        undefined ->
            {error, missingQuery};
        _ ->
            Q = to_binary(Query),
            FunMatches = [M#{kind => function} || M <- alCodeIndexer:searchFunctions(Q)],
            ModMatches = search_modules_by_name(Q),
            Combined = dedupe_index_matches(FunMatches ++ ModMatches, MaxResults),
            {ok, #{
                query => Q,
                matchCount => length(Combined),
                matches => Combined
            }}
    end.

search_modules_by_name(Query) ->
    Q = string:lowercase(binary_to_list(Query)),
    lists:filtermap(fun(Mod) ->
        case string:str(string:lowercase(atom_to_list(Mod)), Q) > 0 of
            true ->
                Entry = case alCodeIndexer:lookupModule(Mod) of
                    {ok, E} -> E;
                    _ -> #{}
                end,
                {true, #{
                    module => Mod,
                    kind => module,
                    file => maps:get(file, Entry, undefined)
                }};
            false ->
                false
        end
    end, alCodeIndexer:allModules()).

dedupe_index_matches(Matches, Max) ->
    dedupe_index_matches(Matches, Max, [], sets:new()).

dedupe_index_matches(_Matches, Max, Acc, _Seen) when length(Acc) >= Max ->
    lists:reverse(Acc);
dedupe_index_matches([], _Max, Acc, _Seen) ->
    lists:reverse(Acc);
dedupe_index_matches([M | Rest], Max, Acc, Seen) ->
    Key = match_key(M),
    case sets:is_element(Key, Seen) of
        true ->
            dedupe_index_matches(Rest, Max, Acc, Seen);
        false ->
            dedupe_index_matches(Rest, Max, [M | Acc], sets:add_element(Key, Seen))
    end.

match_key(#{module := Mod, name := Fun, arity := Arity}) ->
    {Mod, Fun, Arity};
match_key(#{module := Mod}) ->
    {Mod, module}.

%% @doc 按模块名、函数名（及可选 arity）获取函数源码片段。
-spec getFunctionSource(map(), map()) -> {ok, map()} | {error, term()}.
getFunctionSource(Args, Config) ->
    _ = ensure_index(Config),
    Mod = to_atom(maps:get(module, Args, undefined)),
    Fun = to_atom(maps:get(function, Args, undefined)),
    Arity = maps:get(arity, Args, undefined),
    case Mod of
        undefined -> {error, missingModule};
        _ ->
            case Fun of
                undefined -> {error, missingFunction};
                _ ->
                    fetch_function_source(Mod, Fun, Arity)
            end
    end.

%% 从索引中定位函数并读取对应源码行范围。
fetch_function_source(Mod, Fun, Arity) ->
    case alCodeIndexer:lookupModule(Mod) of
        {ok, Entry} ->
            Funs = maps:get(functions, Entry, []),
            Match = pick_function(Funs, Fun, Arity),
            case Match of
                undefined ->
                    case lists:any(fun({F, _}) -> F =:= Fun end, maps:get(exports, Entry, [])) of
                        true -> read_file_range(Entry, undefined);
                        false -> {error, functionNotFound}
                    end;
                FunInfo ->
                    read_file_range(Entry, FunInfo)
            end;
        {error, not_found} ->
            {error, moduleNotIndexed}
    end.

%% 在函数列表中按名称与 arity 选取匹配项。
pick_function(Funs, Fun, undefined) ->
    case [F || F <- Funs, maps:get(name, F) =:= Fun] of
        [One] -> One;
        [] -> undefined;
        Many -> hd(Many)
    end;
pick_function(Funs, Fun, Arity) ->
    case [F || F <- Funs, maps:get(name, F) =:= Fun,
                maps:get(arity, F, -1) =:= Arity] of
        [One] -> One;
        [] -> undefined
    end.

%% 读取文件内容，按函数行号切片或返回整文件（截断大文件）。
read_file_range(Entry, FunInfo) ->
    Abs = maps:get(absPath, Entry),
    case file:read_file(Abs) of
        {ok, Content} ->
            Lines = binary:split(Content, <<"\n"/utf8>>, [global]),
            case FunInfo of
                undefined ->
                    {ok, #{
                        module => maps:get(module, Entry),
                        file => maps:get(file, Entry),
                        content => truncate_bin(Content),
                        truncated => byte_size(Content) > 65536
                    }};
                #{name := Name, line_start := Start, line_end := End} ->
                    Slice = slice_lines(Lines, Start, End),
                    {ok, #{
                        module => maps:get(module, Entry),
                        function => Name,
                        arity => maps:get(arity, FunInfo),
                        file => maps:get(file, Entry),
                        lineStart => Start,
                        lineEnd => End,
                        source => iolist_to_binary(lists:join(<<"\n"/utf8>>, Slice))
                    }}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% 从行列表中截取 [Start, End] 区间（1-based）。
slice_lines(Lines, Start, End) ->
    Total = length(Lines),
    S = max(1, Start),
    E = min(Total, max(End, Start)),
    lists:sublist(Lines, S, E - S + 1).

%% @doc 分析指定函数体内的远程/本地调用；AST 失败时回退正则。
-spec analyzeCalls(map(), map()) -> {ok, map()} | {error, term()}.
analyzeCalls(Args, Config) ->
    _ = ensure_index(Config),
    Mod = to_atom(maps:get(module, Args, undefined)),
    Fun = to_atom(maps:get(function, Args, undefined)),
    Arity = maps:get(arity, Args, undefined),
    case {Mod, Fun} of
        {undefined, _} -> {error, missingModule};
        {_, undefined} -> {error, missingFunction};
        _ ->
            case alCodeIndexer:lookupModule(Mod) of
                {ok, Entry} ->
                    Path = maps:get(absPath, Entry),
                    case alAst:functionCalls(Path, Mod, Fun, Arity) of
                        {ok, Calls} ->
                            {ok, #{
                                module => Mod,
                                function => Fun,
                                arity => Arity,
                                engine => ast,
                                callCount => length(Calls),
                                calls => lists:sublist(Calls, 100)
                            }};
                        {error, Reason} ->
                            regex_analyze_calls(Mod, Fun, Config, Reason)
                    end;
                {error, _} ->
                    regex_analyze_calls(Mod, Fun, Config, not_indexed)
            end
    end.

%% 正则回退：从函数源码中提取 Mod:Fun( 与本地 Fun( 调用。
regex_analyze_calls(Mod, Fun, Config, FallbackReason) ->
    case getFunctionSource(#{module => Mod, function => Fun}, Config) of
        {ok, #{source := Source}} ->
            Calls = extract_calls(Source),
            {ok, #{
                module => Mod,
                function => Fun,
                engine => regex,
                fallback => FallbackReason,
                callCount => length(Calls),
                calls => lists:sublist(Calls, 100)
            }};
        {error, Reason} ->
            {error, Reason}
    end.

%% 逐行提取调用模式。
extract_calls(Source) ->
    Lines = binary:split(Source, <<"\n"/utf8>>, [global]),
    lists:flatmap(fun extract_calls_line/1, Lines).

%% 单行内匹配远程调用或本地调用。
extract_calls_line(Line) ->
    case re:run(Line, <<"([A-Za-z_][A-Za-z0-9_]*):([A-Za-z_][A-Za-z0-9_]*)\\("/utf8>>,
                [global, {capture, all_but_first, binary}]) of
        {match, Matches} ->
            [#{module => binary_to_atom(M, utf8), function => binary_to_atom(F, utf8)}
             || [M, F] <- Matches];
        nomatch ->
            case re:run(Line, <<"\\b([A-Za-z_][A-Za-z0-9_]*)\\("/utf8>>,
                        [global, {capture, all_but_first, binary}]) of
                {match, Local} ->
                    [#{module => local, function => binary_to_atom(F, utf8)} || [F] <- Local];
                nomatch -> []
            end
    end.

%% @doc 查找项目中调用指定 Mod:Fun 的调用方模块及调用点。
-spec findCallers(map(), map()) -> {ok, map()} | {error, term()}.
findCallers(Args, Config) ->
    _ = ensure_index(Config),
    Mod = to_atom(maps:get(module, Args, undefined)),
    Fun = to_atom(maps:get(function, Args, undefined)),
    case {Mod, Fun} of
        {undefined, _} -> {error, missingModule};
        {_, undefined} -> {error, missingFunction};
        _ ->
            Callers = alAst:findCallers(Mod, Fun),
            {ok, #{
                module => Mod,
                function => Fun,
                engine => ast,
                callerCount => length(Callers),
                callers => format_callers(Callers)
            }}
    end.

%% 将调用者列表格式化为 map 列表。
format_callers(Callers) ->
    [#{module => M, sites => S} || {M, S} <- Callers].

%% @doc 读取已加载模块 BEAM 文件中的 abstract_code 并返回预览。
-spec getBeamAbstract(map(), map()) -> {ok, map()} | {error, term()}.
getBeamAbstract(Args, _Config) ->
    Mod = to_atom(maps:get(module, Args, undefined)),
    case Mod of
        undefined -> {error, missingModule};
        _ ->
            case code:which(Mod) of
                Path when is_list(Path) ->
                    case beam_lib:chunks(Path, [abstract_code]) of
                        {ok, {_, {raw_abstract_v1, Forms}}} ->
                            Preview = truncate_term(Forms),
                            {ok, #{
                                module => Mod,
                                beamPath => Path,
                                formCount => length(Forms),
                                abstractPreview => Preview
                            }};
                        {ok, {_, none}} ->
                            {error, no_abstract_code};
                        {error, beam_lib, Reason} ->
                            {error, Reason}
                    end;
                _ ->
                    {error, moduleNotLoaded}
            end
    end.

%% @doc 分析模块的 -behaviour 声明；未指定模块时列出所有含 behaviour 的模块。
-spec analyzeBehaviours(map(), map()) -> {ok, map()} | {error, term()}.
analyzeBehaviours(Args, Config) ->
    _ = ensure_index(Config),
    Mod = maps:get(module, Args, undefined),
    case Mod of
        undefined ->
            All = alCodeIndexer:allModules(),
            Entries = [behaviour_entry(M) || M <- All],
            With = [E || E <- Entries, maps:get(behaviourCount, E, 0) > 0],
            {ok, #{count => length(With), modules => With}};
        _ ->
            Atom = to_atom(Mod),
            {ok, behaviour_entry(Atom)}
    end.

%% 构建单个模块的 behaviour 摘要条目。
behaviour_entry(Mod) ->
    case alCodeIndexer:lookupModule(Mod) of
        {ok, Entry} ->
            #{
                module => Mod,
                behaviours => maps:get(behaviours, Entry, []),
                behaviourCount => length(maps:get(behaviours, Entry, [])),
                file => maps:get(file, Entry, undefined)
            };
        {error, _} ->
            #{module => Mod, behaviours => [], behaviourCount => 0}
    end.

%% @doc 返回指定模块的 import/依赖模块列表。
-spec moduleDependencies(map(), map()) -> {ok, map()} | {error, term()}.
moduleDependencies(Args, Config) ->
    _ = ensure_index(Config),
    Mod = to_atom(maps:get(module, Args, undefined)),
    case Mod of
        undefined -> {error, missingModule};
        _ ->
            case alCodeIndexer:lookupModule(Mod) of
                {ok, Entry} ->
                    Imports = maps:get(imports, Entry, []),
                    Modules = lists:usort([M || M <- Imports, is_atom(M)] ++
                                          [M || {M, _, _} <- Imports]),
                    {ok, #{
                        module => Mod,
                        dependencies => Modules,
                        importCount => length(Imports)
                    }};
                {error, _} ->
                    {error, moduleNotIndexed}
            end
    end.

%% @doc 生成全项目模块依赖边列表及 Mermaid 图文本。
-spec dependencyGraph(map(), map()) -> {ok, map()} | {error, term()}.
dependencyGraph(_Args, Config) ->
    _ = ensure_index(Config),
    Edges = alCodeIndexer:moduleGraph(),
    Mermaid = graph_to_mermaid(Edges),
    {ok, #{
        edgeCount => length(Edges),
        edges => lists:sublist(Edges, 500),
        mermaid => Mermaid
    }}.

%% 将依赖边转换为 Mermaid LR 图语法。
graph_to_mermaid(Edges) ->
    Lines = [io_lib:format("    ~s --> ~s", [atom_to_list(F), atom_to_list(T)])
             || #{from := F, to := T} <- Edges, is_atom(T)],
    iolist_to_binary(["graph LR\n" | Lines]).

%% @doc 基于 AST 分析指定模块内的跨模块调用边。
-spec analyzeCallGraph(map(), map()) -> {ok, map()} | {error, term()}.
analyzeCallGraph(Args, Config) ->
    _ = ensure_index(Config),
    Mod = to_atom(maps:get(module, Args, undefined)),
    case Mod of
        undefined -> {error, missingModule};
        _ ->
            Edges = alAst:callGraphEdges(Mod),
            {ok, #{
                module => Mod,
                edgeCount => length(Edges),
                edges => lists:sublist(Edges, 200),
                engine => ast
            }}
    end.

%% @doc 对模块做简单代码质量启发式检查（导出过多、缺 -spec、私有函数过多等）。
-spec codeQuality(map(), map()) -> {ok, map()} | {error, term()}.
codeQuality(Args, Config) ->
    _ = ensure_index(Config),
    Mod = maps:get(module, Args, undefined),
    Modules = case Mod of
        undefined -> alCodeIndexer:allModules();
        _ -> [to_atom(Mod)]
    end,
    Issues = lists:flatmap(fun analyze_module_quality/1, Modules),
    {ok, #{
        issueCount => length(Issues),
        issues => lists:sublist(Issues, 100)
    }}.

%% 对单个模块收集质量 issue 列表。
analyze_module_quality(Mod) ->
    case alCodeIndexer:lookupModule(Mod) of
        {ok, Entry} ->
            Exports = maps:get(exports, Entry, []),
            Funs = maps:get(functions, Entry, []),
            I1 = case length(Exports) > 30 of
                true -> [#{module => Mod, kind => tooManyExports, count => length(Exports)}];
                false -> []
            end,
            ExportedNames = [F || {F, _} <- Exports],
            I2 = [#{module => Mod, kind => missingSpec, function => F}
                  || F <- ExportedNames,
                     not has_spec(Entry, F)],
            I3 = case length(Funs) > length(Exports) + 5 of
                true -> [#{module => Mod, kind => manyPrivateFunctions,
                           privateCount => length(Funs) - length(Exports)}];
                false -> []
            end,
            I1 ++ I2 ++ I3;
        {error, _} ->
            []
    end.

%% 检查导出函数是否在索引 specs 中有对应 -spec。
has_spec(Entry, Fun) ->
    Specs = maps:get(specs, Entry, []),
    lists:any(fun({N, _}) -> N =:= Fun end, Specs).

%% 确保代码索引已就绪（惰性刷新）。
ensure_index(Config) ->
    codeIndex(#{}, Config).

%% 将二进制内容截断至 64KB。
truncate_bin(Bin) ->
    case byte_size(Bin) > 65536 of
        true -> binary:part(Bin, 0, 65536);
        false -> Bin
    end.

%% 将 Erlang 项格式化为字符串并截断过长输出。
truncate_term(Term) ->
    Bin = list_to_binary(io_lib:format("~p", [Term])),
    case byte_size(Bin) > ?MAX_ABSTRACT of
        true -> #{truncated => true, preview => binary:part(Bin, 0, ?MAX_ABSTRACT)};
        false -> Term
    end.

%% 将 binary/list/atom 统一转为 atom。
to_atom(undefined) -> undefined;
to_atom(X) when is_atom(X) -> X;
to_atom(X) when is_binary(X) ->
    try binary_to_existing_atom(X, utf8) catch _:_ -> undefined end;
to_atom(X) when is_list(X) ->
    try list_to_existing_atom(X) catch _:_ -> undefined end.

to_binary(X) when is_binary(X) -> X;
to_binary(X) when is_list(X) -> unicode:characters_to_binary(X);
to_binary(X) when is_atom(X) -> atom_to_binary(X, utf8);
to_binary(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).