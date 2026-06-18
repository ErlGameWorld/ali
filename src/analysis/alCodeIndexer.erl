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
    start_link/0,
    ensure_started/0,
    refresh/1,
    refresh_async/1,
    lookup_module/1,
    lookup_function/2,
    find_callers/2,
    get_module/1,
    get_stats/0,
    search_functions/1,
    all_modules/0,
    module_graph/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, alCodeIndexer).
-define(ETS, alCodeIndex).
-define(DETS_FILE, "index.dets").
-define(DEFAULT_EXCLUDE, ["/_build/", "/.git/", "\\_build\\", "\\.git\\"]).

-record(state, {root, exclude}).

%% @doc 启动索引器 gen_server 进程。
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc 确保索引器已启动（幂等）。
ensure_started() ->
    case whereis(?SERVER) of
        undefined ->
            case start_link() of
                {ok, _} -> ok;
                {error, {already_started, _}} -> ok
            end;
        _ ->
            ok
    end.

%% @doc 同步刷新全项目索引，阻塞直至完成。
refresh(Config) ->
    ensure_started(),
    gen_server:call(?SERVER, {refresh, Config}, infinity).

%% @doc 异步投递刷新任务，立即返回。
refresh_async(Config) ->
    ensure_started(),
    gen_server:cast(?SERVER, {refresh, Config}).

%% @doc 按模块名查询索引条目。
lookup_module(Mod) when is_atom(Mod) ->
    ensure_started(),
    case ets:lookup(?ETS, Mod) of
        [{Mod, Entry}] -> {ok, Entry};
        [] -> {error, not_found}
    end.

%% @doc 在模块内按函数名查找函数元数据（含行号范围）。
lookup_function(Mod, Fun) when is_atom(Mod), is_atom(Fun) ->
    case lookup_module(Mod) of
        {ok, #{functions := Funs}} ->
            case [F || F <- Funs, maps:get(name, F) =:= Fun] of
                [One | _] -> {ok, One};
                [] -> {error, not_found}
            end;
        {error, _} = E ->
            E
    end.

%% @doc 用文本模式在全索引中查找调用 Mod:Fun 的调用方及行号片段。
find_callers(Mod, Fun) when is_atom(Mod), is_atom(Fun) ->
    ensure_started(),
    All = ets:tab2list(?ETS),
    Needle1 = atom_to_binary(Mod),
    Needle2 = atom_to_binary(Fun),
    Pattern = iolist_to_binary([Needle1, ":", Needle2, "("]),
    LocalPat = iolist_to_binary([Needle2, "("]),
    lists:foldl(fun({CallerMod, Entry}, Acc) ->
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
    end, [], All).

%% @doc `lookup_module/1` 的别名。
get_module(Mod) -> lookup_module(Mod).

%% @doc 返回当前索引中的模块数量等统计信息。
get_stats() ->
    ensure_started(),
    Size = ets:info(?ETS, size),
    #{moduleCount => Size}.

%% @doc 按子串（不区分大小写）搜索函数名，返回匹配的函数元数据列表。
search_functions(Query) when is_binary(Query); is_list(Query) ->
    ensure_started(),
    Q = string:lowercase(to_list(Query)),
    ets:foldl(fun({_Mod, Entry}, Acc) ->
        Funs = maps:get(functions, Entry, []),
        Matches = [
            maps:merge(#{module => maps:get(module, Entry)}, F) ||
            F <- Funs,
            string:str(string:lowercase(atom_to_list(maps:get(name, F))), Q) > 0
        ],
        Matches ++ Acc
    end, [], ?ETS).

%% @doc 返回索引中所有模块名列表。
all_modules() ->
    ensure_started(),
    [Mod || {Mod, _} <- ets:tab2list(?ETS)].

%% @doc 根据各模块 import 列表构建模块依赖有向边。
module_graph() ->
    ensure_started(),
    ets:foldl(fun({Mod, Entry}, Acc) ->
        Imports = maps:get(imports, Entry, []),
        Mods = lists:usort([
            case I of
                M when is_atom(M) -> M;
                {M, _, _} -> M
            end || I <- Imports, is_atom(I) orelse is_tuple(I)
        ]),
        [#{from => Mod, to => T} || T <- Mods, T =/= Mod] ++ Acc
    end, [], ?ETS).

%% @doc gen_server 初始化：创建 ETS 并从 dets 加载持久化索引。
init([]) ->
    %% 防止并发启动时重复创建同名 ETS 表
    case ets:info(?ETS) of
        undefined ->
            ets:new(?ETS, [named_table, public, set, {read_concurrency, true}]);
        _ -> ok
    end,
    load_dets(),
    {ok, #state{root = undefined, exclude = ?DEFAULT_EXCLUDE}}.

%% @doc 处理同步刷新与 get_stats 调用。
handle_call({refresh, Config}, _From, State) ->
    {Reply, NewState} = do_refresh(Config, State),
    {reply, Reply, NewState};
handle_call(get_stats, _From, State) ->
    {reply, get_stats(), State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

%% @doc 处理异步刷新 cast。
handle_cast({refresh, Config}, State) ->
    {_Reply, NewState} = do_refresh(Config, State),
    {noreply, NewState};
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @doc gen_server 回调：忽略无关消息。
handle_info(_Info, State) ->
    {noreply, State}.

%% 扫描项目、逐文件索引、写入 ETS 并持久化 dets。
do_refresh(Config, State) ->
    Root = project_root(Config),
    Exclude = maps:get(indexExclude, Config, ?DEFAULT_EXCLUDE),
    Files = scan_erl_files(Root, Exclude),
    Updated = lists:foldl(fun(File, Count) ->
        case index_file(Root, File, Exclude) of
            {ok, Entry} ->
                Mod = maps:get(module, Entry),
                ets:insert(?ETS, {Mod, Entry}),
                Count + 1;
            _ ->
                Count
        end
    end, 0, Files),
    save_dets(),
    persistent_term:put({?MODULE, lastRefresh}, erlang:system_time(second)),
    {{ok, #{indexed => Updated, moduleCount => ets:info(?ETS, size)}},
     State#state{root = Root, exclude = Exclude}}.

%% 收集 src/、根目录 *.erl 及 test/ 下所有待索引文件。
scan_erl_files(Root, Exclude) ->
    SrcDir = filename:join(Root, "src"),
    FromSrc = case filelib:is_dir(SrcDir) of
        true -> collect_erl(SrcDir, true, [], Exclude);
        false -> []
    end,
    RootErl = [F || F <- filelib:wildcard(filename:join(Root, "*.erl")),
                    not is_excluded(F, Exclude)],
    TestDir = filename:join(Root, "test"),
    FromTest = case filelib:is_dir(TestDir) of
        true -> collect_erl(TestDir, true, [], Exclude);
        false -> []
    end,
    lists:usort(FromSrc ++ RootErl ++ FromTest).

%% 递归收集目录下 .erl 文件，跳过排除路径。
collect_erl(Dir, Recursive, Acc, Exclude) ->
    Files = [F || F <- filelib:wildcard(filename:join(Dir, "*.erl")),
                  not is_excluded(F, Exclude)],
    Acc1 = Acc ++ Files,
    case Recursive of
        true ->
            Subs = [filename:join(Dir, D) || D <- filelib:wildcard(filename:join(Dir, "*")),
                    filelib:is_dir(filename:join(Dir, D)),
                    not is_excluded(filename:join(Dir, D), Exclude)],
            lists:foldl(fun(S, A) -> collect_erl(S, true, A, Exclude) end, Acc1, Subs);
        false ->
            Acc1
    end.

%% 读取并解析单个 .erl 文件为索引条目。
index_file(Root, AbsPath, Exclude) ->
    case is_excluded(AbsPath, Exclude) of
        true -> {error, excluded};
        false ->
            case file:read_file_info(AbsPath) of
                {ok, #file_info{mtime = Mtime}} ->
                    case file:read_file(AbsPath) of
                        {ok, Content} ->
                            Entry = parse_module(Root, AbsPath, Content, Mtime),
                            case maps:get(module, Entry, undefined) of
                                undefined -> {error, no_module};
                                _ -> {ok, Entry}
                            end;
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

%% 用正则从源码内容提取模块索引字段并组装 map。
parse_module(Root, AbsPath, Content, Mtime) ->
    Mod = parse_atom_attr(Content, <<"-module\\((\\w+)"/utf8>>),
    Lines = binary:split(Content, <<"\n"/utf8>>, [global]),
    Exports = parse_export_list(Content),
    Behaviours = parse_behaviours(Content),
    Imports = parse_imports(Content),
    Specs = parse_specs(Content),
    Functions = parse_functions(Lines),
    #{
        module => Mod,
        file => rel_path(Root, AbsPath),
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
parse_atom_attr(Content, Pattern) ->
    case re:run(Content, Pattern, [{capture, all_but_first, binary}]) of
        {match, [Bin]} -> binary_to_atom(Bin, utf8);
        nomatch -> undefined
    end.

%% 解析 -export([...]) 为 {Name, Arity} 列表。
parse_export_list(Content) ->
    parse_name_arity_list(Content, <<"-export\\(\\[([\\s\\S]*?)\\]\\)"/utf8>>).

%% 解析所有 import 子句（模块导入或带函数列表的导入）。
parse_imports(Content) ->
    case re:run(Content, <<"-import\\(([^)]+)\\)"/utf8>>, [global, {capture, all_but_first, binary}]) of
        {match, Matches} ->
            lists:usort(lists:flatmap(fun parse_import_clause/1, Matches));
        nomatch ->
            []
    end.

%% 解析单条 import 子句（整模块或 Fun/Arity 列表）。
parse_import_clause(Clause) ->
    Bin = import_clause_binary(Clause),
    case binary:split(Bin, <<","/utf8>>, [global]) of
        [ModBin, FunList] ->
            Mod = binary_to_atom(trim_ws(ModBin), utf8),
            parse_import_funs(Mod, FunList);
        [ModBin] ->
            [binary_to_atom(trim_ws(ModBin), utf8)]
    end.

%% 将 re:run 捕获结果规范为 binary（兼容单元素列表等格式）
import_clause_binary(B) when is_binary(B) -> B;
import_clause_binary([B]) when is_binary(B) -> B;
import_clause_binary(L) when is_list(L) -> iolist_to_binary(L).

%% 从 import 函数列表提取 {Mod, Fun, Arity} 或仅 Mod。
parse_import_funs(Mod, FunList) ->
    case re:run(FunList, <<"(\\w+)/(\\d+)"/utf8>>, [global, {capture, all_but_first, binary}]) of
        {match, Matches} ->
            [{Mod, capture_atom([F]), binary_to_integer(A)} || [F, A] <- Matches];
        nomatch ->
            [Mod]
    end.

%% 解析所有 -behaviour(Name) 声明。
parse_behaviours(Content) ->
    case re:run(Content, <<"-behaviour\\((\\w+)\\)"/utf8>>, [global, {capture, all_but_first, binary}]) of
        {match, Matches} ->
            [capture_atom(M) || M <- Matches];
        nomatch ->
            []
    end.

%% 解析 -spec Name(Args) 为 {Name, Arity} 列表。
parse_specs(Content) ->
    case re:run(Content, <<"-spec\\s+(\\w+)\\(([^)]*)\\)"/utf8>>, [global, {capture, all_but_first, binary}]) of
        {match, Matches} ->
            [{capture_atom([Name]), arity_of_spec(Args)} || [Name, Args] <- Matches];
        nomatch ->
            []
    end.

%% binary 转 atom 的辅助。
capture_atom([B]) when is_binary(B) -> binary_to_atom(B, utf8);
capture_atom(B) when is_binary(B) -> binary_to_atom(B, utf8).

%% 根据 -spec 参数列表计算 arity。
arity_of_spec(ArgsBin) ->
    case trim_ws(ArgsBin) of
        <<>> -> 0;
        Bin ->
            Parts = binary:split(Bin, <<","/utf8>>, [global]),
            length(Parts)
    end.

%% 解析 export/import 块中的 Name/Arity 对。
parse_name_arity_list(Content, BlockPattern) ->
    case re:run(Content, BlockPattern, [{capture, all_but_first, binary}]) of
        {match, [Block]} ->
            case re:run(Block, <<"(\\w+)/(\\d+)"/utf8>>, [global, {capture, all_but_first, binary}]) of
                {match, Matches} ->
                    [{capture_atom([F]), binary_to_integer(A)} || [F, A] <- Matches];
                nomatch -> []
            end;
        nomatch -> []
    end.

%% 逐行扫描函数定义 `Name(Args) ->` 并记录起止行号。
parse_functions(Lines) ->
    parse_functions(Lines, 1, undefined, []).

parse_functions([], _N, Cur, Acc) ->
    lists:reverse(close_fun(Cur, 0, Acc));
parse_functions([Line | Rest], N, Cur, Acc) ->
    case match_fun_line(Line) of
        {ok, Name, Arity} ->
            Closed = close_fun(Cur, N - 1, Acc),
            NewCur = #{name => Name, arity => Arity, line_start => N},
            parse_functions(Rest, N + 1, NewCur, Closed);
        nomatch ->
            parse_functions(Rest, N + 1, Cur, Acc)
    end.

%% 结束当前函数记录并追加 line_end。
close_fun(undefined, _End, Acc) ->
    Acc;
close_fun(Cur, End, Acc) ->
    [maps:put(line_end, End, Cur) | Acc].

%% 匹配函数头行并返回名称与 arity。
match_fun_line(Line) ->
    case re:run(Line, <<"^(\\w+)\\s*\\(([^)]*)\\)\\s*->"/utf8>>, [{capture, all_but_first, binary}]) of
        {match, [Name, Args]} ->
            Arity = arity_of_spec(Args),
            {ok, binary_to_atom(Name, utf8), Arity};
        nomatch ->
            nomatch
    end.

%% 在文件内容中查找远程/本地调用点并记录行号与片段。
findCallSites(Content, RemotePat, LocalPat, CallerMod, TargetMod) ->
    Lines = binary:split(Content, <<"\n"/utf8>>, [global]),
    findCallSites(Lines, 1, RemotePat, LocalPat, CallerMod, TargetMod, []).

findCallSites([], _N, _R, _L, _CM, _TM, Acc) ->
    lists:reverse(Acc);
findCallSites([Line | Rest], N, RemotePat, LocalPat, CallerMod, TargetMod, Acc) ->
    NewAcc = case binary:match(Line, RemotePat) of
        {Start, Len} ->
            [#{line => N, kind => remote, snippet => snippet(Line, Start, Len)} | Acc];
        nomatch when CallerMod =:= TargetMod ->
            case binary:match(Line, LocalPat) of
                {S, L} -> [#{line => N, kind => local, snippet => snippet(Line, S, L)} | Acc];
                nomatch -> Acc
            end;
        nomatch ->
            Acc
    end,
    findCallSites(Rest, N + 1, RemotePat, LocalPat, CallerMod, TargetMod, NewAcc).

%% 截取匹配位置附近的代码片段。
snippet(Line, Start, Len) ->
    binary:part(Line, Start, min(Len + 20, byte_size(Line) - Start)).

%% 判断路径是否命中排除模式（_build、.git 等）。
is_excluded(Path, Patterns) ->
    Lower = string:lowercase(Path),
    lists:any(fun(P) -> string:str(Lower, P) > 0 end, Patterns).

%% 从配置解析项目根目录。
project_root(Config) ->
    case maps:get(projectRoot, Config, undefined) of
        undefined -> alToolProject:findProjectRootFromModule();
        Root -> filename:absname(to_list(Root))
    end.

%% 计算相对于项目根的文件路径（binary）。
rel_path(Root, Abs) ->
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
dets_path() ->
    Dir = filename:join(alToolProject:findProjectRootFromModule(), ".al"),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    filename:join(Dir, ?DETS_FILE).

%% 启动时从 dets 加载索引到 ETS。
load_dets() ->
    Path = dets_path(),
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
save_dets() ->
    Path = dets_path(),
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
trim_ws(Bin) when is_binary(Bin) ->
    re:replace(Bin, <<"^\\s+|\\s+$"/utf8>>, <<>>, [global, {return, binary}]).

to_list(X) when is_binary(X) -> unicode:characters_to_list(X);
to_list(X) when is_list(X) -> X.