%%%-------------------------------------------------------------------
%%% @doc 项目 Erlang 源码索引器（gen_server）。
%%%
%%% 扫描 src/、test/ 及根目录下的 .erl 文件，用正则提取模块元数据
%%% （导出、import、behaviour、-spec、函数行号范围），构建模块→路径、
%%% 调用关系等索引，持久化到 `.al/index.dets`。Agent 的分析类工具
%%% （{@link alToolAnalyze}、{@link alAst}）依赖本模块提供的查询 API。
%%% @end
%%%-------------------------------------------------------------------
-module(alCodeIndexer).

-behaviour(gen_server).

-include_lib("kernel/include/file.hrl").

-export([
    startLink/0,
    ensureStarted/0,
    refresh/1,
    refreshAsync/1,
    lookupModule/1,
    lookupFunction/2,
    findCallers/2,
    getModule/1,
    getStats/0,
    searchFunctions/1,
    allModules/0,
    moduleGraph/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, alCodeIndexer).
-define(ETS, alCodeIndex).
-define(DETS_FILE, "index.dets").
-define(DEFAULT_EXCLUDE, ["/_build/", "/.git/", "\\_build\\", "\\.git\\"]).

-record(state, {root, exclude}).

%% @doc 启动索引器 gen_server 进程。
startLink() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc 确保索引器已启动（幂等）。
ensureStarted() ->
    case whereis(?SERVER) of
        undefined ->
            case startLink() of
                {ok, _} -> ok;
                {error, {already_started, _}} -> ok
            end;
        _ ->
            ok
    end.

%% @doc 同步刷新全项目索引，阻塞直至完成。
refresh(Config) ->
    ensureStarted(),
    gen_server:call(?SERVER, {refresh, Config}, infinity).

%% @doc 异步投递刷新任务，立即返回。
refreshAsync(Config) ->
    ensureStarted(),
    gen_server:cast(?SERVER, {refresh, Config}).

%% @doc 按模块名查询索引条目。
lookupModule(Mod) when is_atom(Mod) ->
    ensureStarted(),
    case ets:lookup(?ETS, Mod) of
        [{Mod, Entry}] -> {ok, Entry};
        [] -> {error, not_found}
    end.

%% @doc 在模块内按函数名查找函数元数据（含行号范围）。
lookupFunction(Mod, Fun) when is_atom(Mod), is_atom(Fun) ->
    case lookupModule(Mod) of
        {ok, #{functions := Funs}} ->
            case [F || F <- Funs, maps:get(name, F) =:= Fun] of
                [One | _] -> {ok, One};
                [] -> {error, not_found}
            end;
        {error, _} = E ->
            E
    end.

%% @doc 用文本模式在全索引中查找调用 Mod:Fun 的调用方及行号片段。
%% 使用 ets:foldl 流式遍历，避免 ets:tab2list 全量加载到内存。
%% 跳过注释行（%% 开头）以减少误报。
findCallers(Mod, Fun) when is_atom(Mod), is_atom(Fun) ->
    ensureStarted(),
    Needle1 = atom_to_binary(Mod),
    Needle2 = atom_to_binary(Fun),
    Pattern = iolist_to_binary([Needle1, ":", Needle2, "("]),
    LocalPat = iolist_to_binary([Needle2, "("]),
    ets:foldl(fun({CallerMod, Entry}, Acc) ->
        case CallerMod =:= Mod of
            true -> Acc;
            false ->
                AbsPath = maps:get(absPath, Entry, undefined),
                case AbsPath of
                    undefined -> Acc;
                    _ ->
                        case file:read_file(AbsPath) of
                            {ok, Content} ->
                                case findCallSites(Content, Pattern, LocalPat, CallerMod, Mod) of
                                    [] -> Acc;
                                    Sites -> [{CallerMod, Sites} | Acc]
                                end;
                            _ -> Acc
                        end
                end
        end
    end, [], ?ETS).

%% @doc `lookupModule/1` 的别名。
getModule(Mod) -> lookupModule(Mod).

%% @doc 返回当前索引中的模块数量等统计信息。
getStats() ->
    ensureStarted(),
    Size = ets:info(?ETS, size),
    #{moduleCount => Size}.

%% @doc 按子串（不区分大小写）搜索函数名，返回匹配的函数元数据列表。
searchFunctions(Query) when is_binary(Query); is_list(Query) ->
    ensureStarted(),
    Q = string:lowercase(toList(Query)),
    ets:foldl(fun({_Mod, Entry}, Acc) ->
        Funs = maps:get(functions, Entry, []),
        Matches = [
            maps:merge(#{module => maps:get(module, Entry)}, F) ||
            F <- Funs,
            string:str(string:lowercase(atom_to_list(maps:get(name, F))), Q) > 0
        ],
        Matches ++ Acc
    end, [], ?ETS).

%% @doc 返回索引中所有模块名列表（不含 .hrl 文件条目）。
allModules() ->
    ensureStarted(),
    [Mod || {Mod, _} <- ets:tab2list(?ETS), is_atom(Mod)].

%% @doc 根据各模块 import 列表构建模块依赖有向边（不含 .hrl 文件）。
moduleGraph() ->
    ensureStarted(),
    ets:foldl(fun({Mod, Entry}, Acc) ->
        case is_atom(Mod) of
            false -> Acc;  %% 跳过 {hrl, Name} 等非模块条目
            true ->
                Imports = maps:get(imports, Entry, []),
                Mods = lists:usort([
                    case I of
                        M when is_atom(M) -> M;
                        {M, _, _} -> M
                    end || I <- Imports, is_atom(I) orelse is_tuple(I)
                ]),
                [#{from => Mod, to => T} || T <- Mods, T =/= Mod] ++ Acc
        end
    end, [], ?ETS).

%% @doc gen_server 初始化：创建 ETS 并从 dets 加载持久化索引。
init([]) ->
    %% 防止并发启动时重复创建同名 ETS 表
    case ets:info(?ETS) of
        undefined ->
            ets:new(?ETS, [named_table, public, set, {read_concurrency, true}]);
        _ -> ok
    end,
    loadDets(),
    {ok, #state{root = undefined, exclude = ?DEFAULT_EXCLUDE}}.

%% @doc 处理同步刷新与 getStats 调用。
handle_call({refresh, Config}, _From, State) ->
    {Reply, NewState} = doRefresh(Config, State),
    {reply, Reply, NewState};
handle_call(getStats, _From, State) ->
    {reply, getStats(), State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

%% @doc 处理异步刷新 cast。
handle_cast({refresh, Config}, State) ->
    {_Reply, NewState} = doRefresh(Config, State),
    {noreply, NewState};
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @doc gen_server 回调：忽略无关消息。
handle_info(_Info, State) ->
    {noreply, State}.

%% 扫描项目、逐文件索引、写入 ETS 并持久化 dets。
doRefresh(Config, State) ->
    Root = projectRoot(Config),
    Exclude = maps:get(indexExclude, Config, ?DEFAULT_EXCLUDE),
    Files = scanErlFiles(Root, Exclude),
    ets:delete_all_objects(?ETS),
    Updated = lists:foldl(fun(File, Count) ->
        case indexFile(Root, File, Exclude) of
            {ok, Key, Entry} ->
                ets:insert(?ETS, {Key, Entry}),
                Count + 1;
            _ ->
                Count
        end
    end, 0, Files),
    RefreshResult = case saveDets() of
        ok ->
            persistent_term:put({?MODULE, lastRefresh}, erlang:system_time(second)),
            {ok, #{indexed => Updated, moduleCount => ets:info(?ETS, size)}};
        {error, Reason} ->
            {error, #{reason => Reason, indexed => Updated}}
    end,
    {RefreshResult, State#state{root = Root, exclude = Exclude}}.

%% 收集待索引的源文件：src/、lib/、test/（递归）及根目录下的 .erl/.hrl/.ex/.exs。
%% 同时支持 Erlang（.erl/.hrl）与 Elixir（.ex/.exs，约定在 lib/ 下）。
%% .hrl 文件以 {hrl, Filename} 为键存入索引，便于 findCallers 搜索。
scanErlFiles(Root, Exclude) ->
    Exts = [".erl", ".hrl", ".ex", ".exs"],
    Dirs = ["src", "lib", "test", "include"],
    FromDirs = lists:flatmap(fun(D) ->
        Dir = filename:join(Root, D),
        case filelib:is_dir(Dir) of
            true -> collectSource(Dir, Exts, [], Exclude);
            false -> []
        end
    end, Dirs),
    RootFiles = lists:flatmap(fun(Ext) ->
        [F || F <- filelib:wildcard(filename:join(Root, "*" ++ Ext)),
              not isExcluded(F, Exclude)]
    end, Exts),
    lists:usort(FromDirs ++ RootFiles).

%% 递归收集目录下匹配任一扩展名的源文件，跳过排除路径。
collectSource(Dir, Exts, Acc, Exclude) ->
    Files = lists:flatmap(fun(Ext) ->
        [F || F <- filelib:wildcard(filename:join(Dir, "*" ++ Ext)),
              not isExcluded(F, Exclude)]
    end, Exts),
    %% 前插累加，避免 Acc ++ Files 对大列表重复复制；顶层 scanErlFiles 会 usort。
    Acc1 = Files ++ Acc,
    Subs = [filename:join(Dir, D) || D <- filelib:wildcard(filename:join(Dir, "*")),
            filelib:is_dir(filename:join(Dir, D)),
            not isExcluded(filename:join(Dir, D), Exclude)],
    lists:foldl(fun(S, A) -> collectSource(S, Exts, A, Exclude) end, Acc1, Subs).

%% 读取并解析单个源文件为索引条目。
%% .erl/.ex/.exs 返回 {ok, ModuleAtom, Entry}；
%% .hrl 返回 {ok, {hrl, Basename}, Entry}（无模块属性）。
indexFile(Root, AbsPath, Exclude) ->
    case isExcluded(AbsPath, Exclude) of
        true -> {error, excluded};
        false ->
            case file:read_file_info(AbsPath) of
                {ok, #file_info{mtime = Mtime}} ->
                    case file:read_file(AbsPath) of
                        {ok, Content} ->
                            Entry = parseSource(Root, AbsPath, Content, Mtime),
                            case maps:get(module, Entry, undefined) of
                                undefined ->
                                    %% .hrl 文件无 -module 属性，用 {hrl, Basename} 作为键
                                    case filename:extension(AbsPath) of
                                        ".hrl" ->
                                            HrlKey = {hrl, list_to_atom(filename:basename(AbsPath, ".hrl"))},
                                            {ok, HrlKey, Entry#{module => HrlKey}};
                                        _ ->
                                            {error, no_module}
                                    end;
                                Mod ->
                                    {ok, Mod, Entry}
                            end;
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

%% 按文件类型分派解析：.ex/.exs 走 Elixir 解析器，其余按 Erlang 处理。
parseSource(Root, AbsPath, Content, Mtime) ->
    case alElixir:isElixirFile(AbsPath) of
        true -> alElixir:parseModule(Root, AbsPath, Content, Mtime);
        false -> parseModule(Root, AbsPath, Content, Mtime)
    end.

%% 用正则从源码内容提取模块索引字段并组装 map。
parseModule(Root, AbsPath, Content, Mtime) ->
    Mod = parseAtomAttr(Content, <<"-module\\((\\w+)"/utf8>>),
    Lines = binary:split(Content, <<"\n"/utf8>>, [global]),
    Exports = parseExportList(Content),
    Behaviours = parseBehaviours(Content),
    Imports = parseImports(Content),
    Specs = parseSpecs(Content),
    Functions = parseFunctions(Lines),
    #{
        module => Mod,
        language => erlang,
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

%% 通用正则提取单个 atom 属性值。
parseAtomAttr(Content, Pattern) ->
    case re:run(Content, Pattern, [{capture, all_but_first, binary}]) of
        {match, [Bin]} -> binary_to_atom(Bin, utf8);
        nomatch -> undefined
    end.

%% 解析 -export([...]) 为 {Name, Arity} 列表。
parseExportList(Content) ->
    parseNameArityList(Content, <<"-export\\(\\[([\\s\\S]*?)\\]\\)"/utf8>>).

%% 解析所有 import 子句（模块导入或带函数列表的导入）。
parseImports(Content) ->
    case re:run(Content, <<"-import\\(([^)]+)\\)"/utf8>>, [global, {capture, all_but_first, binary}]) of
        {match, Matches} ->
            lists:usort(lists:flatmap(fun parseImportClause/1, Matches));
        nomatch ->
            []
    end.

%% 解析单条 import 子句（整模块或 Fun/Arity 列表）。
parseImportClause(Clause) ->
    Bin = importClauseBinary(Clause),
    case binary:split(Bin, <<","/utf8>>, [global]) of
        [ModBin, FunList] ->
            Mod = binary_to_atom(trimWs(ModBin), utf8),
            parseImportFuns(Mod, FunList);
        [ModBin] ->
            [binary_to_atom(trimWs(ModBin), utf8)]
    end.

%% 将 re:run 捕获结果规范为 binary（兼容单元素列表等格式）
importClauseBinary(B) when is_binary(B) -> B;
importClauseBinary([B]) when is_binary(B) -> B;
importClauseBinary(L) when is_list(L) -> iolist_to_binary(L).

%% 从 import 函数列表提取 {Mod, Fun, Arity} 或仅 Mod。
parseImportFuns(Mod, FunList) ->
    case re:run(FunList, <<"(\\w+)/(\\d+)"/utf8>>, [global, {capture, all_but_first, binary}]) of
        {match, Matches} ->
            [{Mod, captureAtom([F]), binary_to_integer(A)} || [F, A] <- Matches];
        nomatch ->
            [Mod]
    end.

%% 解析所有 -behaviour(Name) 声明。
parseBehaviours(Content) ->
    case re:run(Content, <<"-behaviour\\((\\w+)\\)"/utf8>>, [global, {capture, all_but_first, binary}]) of
        {match, Matches} ->
            [captureAtom(M) || M <- Matches];
        nomatch ->
            []
    end.

%% 解析 -spec Name(Args) 为 {Name, Arity} 列表。
parseSpecs(Content) ->
    case re:run(Content, <<"-spec\\s+(\\w+)\\(([^)]*)\\)"/utf8>>, [global, {capture, all_but_first, binary}]) of
        {match, Matches} ->
            [{captureAtom([Name]), arityOfSpec(Args)} || [Name, Args] <- Matches];
        nomatch ->
            []
    end.

%% binary 转 atom 的辅助。
captureAtom([B]) when is_binary(B) -> binary_to_atom(B, utf8);
captureAtom(B) when is_binary(B) -> binary_to_atom(B, utf8).

%% 根据 -spec 参数列表计算 arity。
arityOfSpec(ArgsBin) ->
    case trimWs(ArgsBin) of
        <<>> -> 0;
        Bin ->
            Parts = binary:split(Bin, <<","/utf8>>, [global]),
            length(Parts)
    end.

%% 解析 export/import 块中的 Name/Arity 对。
parseNameArityList(Content, BlockPattern) ->
    case re:run(Content, BlockPattern, [{capture, all_but_first, binary}]) of
        {match, [Block]} ->
            case re:run(Block, <<"(\\w+)/(\\d+)"/utf8>>, [global, {capture, all_but_first, binary}]) of
                {match, Matches} ->
                    [{captureAtom([F]), binary_to_integer(A)} || [F, A] <- Matches];
                nomatch -> []
            end;
        nomatch -> []
    end.

%% 逐行扫描函数定义 `Name(Args) ->` 并记录起止行号。
parseFunctions(Lines) ->
    parseFunctions(Lines, 1, undefined, []).

parseFunctions([], _N, Cur, Acc) ->
    lists:reverse(closeFun(Cur, 0, Acc));
parseFunctions([Line | Rest], N, Cur, Acc) ->
    case matchFunLine(Line) of
        {ok, Name, Arity} ->
            Closed = closeFun(Cur, N - 1, Acc),
            NewCur = #{name => Name, arity => Arity, line_start => N},
            parseFunctions(Rest, N + 1, NewCur, Closed);
        nomatch ->
            parseFunctions(Rest, N + 1, Cur, Acc)
    end.

%% 结束当前函数记录并追加 line_end。
closeFun(undefined, _End, Acc) ->
    Acc;
closeFun(Cur, End, Acc) ->
    [maps:put(line_end, End, Cur) | Acc].

%% 匹配函数头行并返回名称与 arity。
matchFunLine(Line) ->
    case re:run(Line, <<"^(\\w+)\\s*\\(([^)]*)\\)\\s*->"/utf8>>, [{capture, all_but_first, binary}]) of
        {match, [Name, Args]} ->
            Arity = arityOfSpec(Args),
            {ok, binary_to_atom(Name, utf8), Arity};
        nomatch ->
            nomatch
    end.

%% 在文件内容中查找远程/本地调用点并记录行号与片段。
%% 跳过注释行（%% 开头）以减少误报。
findCallSites(Content, RemotePat, LocalPat, CallerMod, TargetMod) ->
    Lines = binary:split(Content, <<"\n"/utf8>>, [global]),
    findCallSites(Lines, 1, RemotePat, LocalPat, CallerMod, TargetMod, []).

findCallSites([], _N, _R, _L, _CM, _TM, Acc) ->
    lists:reverse(Acc);
findCallSites([Line | Rest], N, RemotePat, LocalPat, CallerMod, TargetMod, Acc) ->
    Trimmed = trimLeadingWs(Line),
    IsComment = case Trimmed of
        <<"%%", _/binary>> -> true;
        <<"%", _/binary>> -> true;
        _ -> false
    end,
    NewAcc = case IsComment of
        true ->
            Acc;
        false ->
            case binary:match(Line, RemotePat) of
                {Start, Len} ->
                    [#{line => N, kind => remote, snippet => snippet(Line, Start, Len)} | Acc];
                nomatch when CallerMod =:= TargetMod ->
                    case binary:match(Line, LocalPat) of
                        {S, L} -> [#{line => N, kind => local, snippet => snippet(Line, S, L)} | Acc];
                        nomatch -> Acc
                    end;
                nomatch ->
                    Acc
            end
    end,
    findCallSites(Rest, N + 1, RemotePat, LocalPat, CallerMod, TargetMod, NewAcc).

%% 去除行首空白以便判断是否为注释行。
trimLeadingWs(Bin) ->
    re:replace(Bin, <<"^\\s+"/utf8>>, <<>>, [{return, binary}]).

%% 截取匹配位置附近的代码片段。
snippet(Line, Start, Len) ->
    binary:part(Line, Start, min(Len + 20, byte_size(Line) - Start)).

%% 判断路径是否命中排除模式（_build、.git 等）。
isExcluded(Path, Patterns) ->
    Lower = string:lowercase(Path),
    lists:any(fun(P) -> string:str(Lower, P) > 0 end, Patterns).

%% 从配置解析项目根目录。
projectRoot(Config) ->
    case maps:get(projectRoot, Config, undefined) of
        undefined -> alToolProject:findProjectRootFromModule();
        Root -> filename:absname(toList(Root))
    end.

%% 计算相对于项目根的文件路径（binary）。
relPath(Root, Abs) ->
    RootNorm = filename:absname(Root),
    AbsNorm = filename:absname(Abs),
    Sep = sep(),
    case string:prefix(AbsNorm, RootNorm ++ Sep) of
        nomatch ->
            unicode:characters_to_binary(filename:basename(AbsNorm));
        Rest ->
            unicode:characters_to_binary(string:trim(Rest, leading, "/\\"))
    end.

%% 路径分隔符（Windows / Unix）。
sep() ->
    case os:type() of
        {win32, _} -> "\\";
        _ -> "/"
    end.

%% 返回 `.al/index.dets` 绝对路径并确保目录存在。
detsPath() ->
    Dir = filename:join(alToolProject:findProjectRootFromModule(), ".al"),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    filename:join(Dir, ?DETS_FILE).

%% 启动时从 dets 加载索引到 ETS。
loadDets() ->
    Path = detsPath(),
    case filelib:is_file(Path) of
        true ->
            case dets:open_file(alIndexDets, [{file, Path}, {type, set}]) of
                {ok, _} ->
                    ets:delete_all_objects(?ETS),
                    dets:to_ets(alIndexDets, ?ETS),
                    dets:close(alIndexDets),
                    ok;
                _ ->
                    ok
            end;
        false ->
            ok
    end.

%% 将当前 ETS 索引原子写入 dets 文件。
saveDets() ->
    Path = detsPath(),
    Tmp = Path ++ ".tmp",
    %% 先写入临时文件，再原子重命名，避免并发或崩溃导致 index.dets 损坏
    case dets:open_file(alIndexDetsTmp, [{file, Tmp}, {type, set}, {keypos, 1}]) of
        {ok, _} ->
            dets:from_ets(alIndexDetsTmp, ?ETS),
            dets:close(alIndexDetsTmp),
            file:rename(Tmp, Path),
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

%% 去除 binary 首尾空白。
trimWs(Bin) when is_binary(Bin) ->
    re:replace(Bin, <<"^\\s+|\\s+$"/utf8>>, <<>>, [global, {return, binary}]).

toList(X) when is_binary(X) -> unicode:characters_to_list(X);
toList(X) when is_list(X) -> X.