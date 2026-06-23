%%%-------------------------------------------------------------------
%%% @doc 项目文件浏览与路径安全工具。
%%%
%%% 在沙箱内读取/列举文件、全文搜索、触发代码索引刷新，
%%% 并提供路径规范化、符号链接解析及禁止访问敏感目录的规则。
%%% @end
%%%-------------------------------------------------------------------
-module(alToolProject).

-include_lib("kernel/include/file.hrl").

-export([
    readFile/2,
    listFiles/2,
    searchText/2,
    projectIndex/2,
    resolvePathForEdit/2,
    findProjectRootFromModule/0
]).

%% @doc 读取项目内相对路径文件，超大文件按 maxBytes 截断。
-spec readFile(map(), map()) -> {ok, map()} | {error, term()}.
readFile(Args, Config) ->
    Path = maps:get(path, Args, undefined),
    Root = projectRoot(Config),
    case Path of
        undefined ->
            {error, missingPath};
        _ ->
            case resolvePath(Root, Path) of
                {ok, AbsPath} ->
                    MaxBytes = maps:get(maxBytes, Args, alConfig:get(toolReadFileMaxBytes)),
                    readFileLimited(AbsPath, MaxBytes);
                {error, Reason} ->
                    {error, Reason}
            end
    end.

%% 按大小限制读取常规文件或返回目录/错误。
readFileLimited(AbsPath, MaxBytes) ->
    case file:read_file_info(AbsPath) of
        {ok, #file_info{type = regular, size = Size}} when Size > MaxBytes ->
            case file:open(AbsPath, [read, binary]) of
                {ok, Fd} ->
                    {ok, Partial} = file:read(Fd, MaxBytes),
                    file:close(Fd),
                    {ok, #{
                        path => AbsPath,
                        truncated => true,
                        size => Size,
                        content => llmJson:sanitize_binary(Partial)
                    }};
                {error, Reason} ->
                    {error, Reason}
            end;
        {ok, #file_info{type = regular}} ->
            case file:read_file(AbsPath) of
                {ok, Content} ->
                    {ok, #{
                        path => AbsPath,
                        truncated => false,
                        content => llmJson:sanitize_binary(Content)
                    }};
                {error, Reason} ->
                    {error, Reason}
            end;
        {ok, #file_info{type = directory}} ->
            {error, isDirectory};
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc 按 glob 模式列举项目目录下文件（可选递归）。
-spec listFiles(map(), map()) -> {ok, map()} | {error, term()}.
listFiles(Args, Config) ->
    Root = projectRoot(Config),
    SubPath = maps:get(path, Args, <<"."/utf8>>),
    Pattern = maps:get(pattern, Args, "*"),
    Recursive = maps:get(recursive, Args, true),
    case resolvePath(Root, SubPath) of
        {ok, AbsDir} ->
            case filelib:is_dir(AbsDir) of
                true ->
                    Files = collectFiles(AbsDir, Pattern, Recursive, []),
                    Rel = [relativePath(Root, F) || F <- Files],
                    {ok, #{root => Root, path => SubPath, files => Rel, count => length(Rel)}};
                false ->
                    {error, notADirectory}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% 递归或非递归收集匹配 pattern 的文件路径。
%% 递归时跳过构建产物、版本控制、Agent 数据等噪音目录（见 excludedDirs/0），
%% 避免遍历 _build 等海量目录拖慢大型项目。
collectFiles(Dir, Pattern, true, Acc) ->
    PatternStr = toList(Pattern),
    Direct = filelib:wildcard(filename:join(Dir, PatternStr)),
    Acc1 = lists:usort(Acc ++ Direct),
    lists:foldl(fun(Sub, A) -> collectFiles(Sub, Pattern, true, A) end, Acc1, subDirectories(Dir));
collectFiles(Dir, Pattern, false, Acc) ->
    PatternStr = toList(Pattern),
    lists:usort(Acc ++ filelib:wildcard(filename:join(Dir, PatternStr))).

%% 列出 Dir 下未被排除的子目录绝对路径。
subDirectories(Dir) ->
    case file:list_dir(Dir) of
        {ok, Entries} ->
            [filename:join(Dir, E) || E <- Entries,
                                      not isExcludedDir(E),
                                      filelib:is_dir(filename:join(Dir, E))];
        {error, _} ->
            []
    end.

%% @doc 递归遍历时默认跳过的目录名（叠加配置项 `indexExclude` 与 `.gitignore`）。
excludedDirs() ->
    Base = ["_build", ".git", ".rebar3", ".hg", ".svn", ".eunit",
            "node_modules", ".al", "_checkouts", ".elixir_ls", "deps"],
    Extra = case aliCfg:getV(indexExclude) of
        {ok, L} when is_list(L) -> [toList(X) || X <- L];
        _ -> []
    end,
    Base ++ Extra ++ gitignorePatterns().

%% 解析项目根目录 `.gitignore` 中不含通配符的目录名（如 `ebin/`、`logs/`），
%% 合并进 excludedDirs 避免遍历垃圾目录；同时返回模式列表供文件级过滤。
%% 结果按文件 mtime 缓存到 persistent_term，避免每次目录遍历都重复读文件。
gitignorePatterns() ->
    Root = findProjectRootFromModule(),
    Path = filename:join(Root, ".gitignore"),
    CacheKey = {?MODULE, gitignorePatterns},
    CurrentMtime = case file:read_file_info(Path) of
        {ok, #file_info{mtime = M}} -> M;
        {error, _} -> undefined
    end,
    case persistent_term:get(CacheKey, undefined) of
        {CurrentMtime, Patterns} -> Patterns;
        _ -> loadGitignorePatterns(Path, CurrentMtime, CacheKey)
    end.

loadGitignorePatterns(Path, Mtime, CacheKey) ->
    Patterns = case file:read_file(Path) of
        {ok, Content} ->
            Lines = binary:split(Content, <<"\n"/utf8>>, [global]),
            lists:filtermap(fun parseGitignoreLine/1, Lines);
        {error, _} ->
            []
    end,
    persistent_term:put(CacheKey, {Mtime, Patterns}),
    Patterns.

%% 解析单行 .gitignore：跳过注释/空行，提取以 `/` 结尾的目录模式名（去掉尾 `/`）。
parseGitignoreLine(Line) ->
    Stripped = string:trim(binary_to_list(Line)),
    case Stripped of
        "" -> false;
        "#" ++ _ -> false;
        Name ->
            case lists:last(Name) =:= $/ of
                true ->
                    %% 目录模式如 "ebin/" → 排除同名目录
                    DirName = string:trim(Name, trailing, "/"),
                    case string:chr(DirName, $*) =:= 0 andalso
                         string:chr(DirName, $?) =:= 0 andalso
                         string:chr(DirName, $[) =:= 0 of
                        true -> {true, DirName};
                        false -> false
                    end;
                false ->
                    false
            end
    end.

%% 判断目录名是否应被排除。
isExcludedDir(Name) ->
    lists:member(toList(Name), excludedDirs()).

%% @doc 在项目文本文件中搜索 query 子串，返回匹配行列表。
-spec searchText(map(), map()) -> {ok, map()} | {error, term()}.
searchText(Args, Config) ->
    Query = maps:get(query, Args, undefined),
    Root = projectRoot(Config),
    MaxResults = maps:get(maxResults, Args, alConfig:get(toolListFilesMaxResults)),
    SubPath = maps:get(path, Args, <<"."/utf8>>),
    case Query of
        undefined ->
            {error, missingQuery};
        _ ->
            QueryBin = toBinary(Query),
            {ok, #{files := Files}} = listFiles(#{path => SubPath, pattern => "*", recursive => true}, Config),
            TextFiles = [F || F <- Files, isTextFile(F)],
            Matches = searchFiles(Root, TextFiles, QueryBin, MaxResults, []),
            {ok, #{query => QueryBin, matchCount => length(Matches), matches => Matches}}
    end.

%% 在文件列表中逐文件搜索直至达到 maxResults。
searchFiles(_Root, [], _Query, _Max, Acc) ->
    lists:reverse(Acc);
searchFiles(_Root, _Files, _Query, Max, Acc) when length(Acc) >= Max ->
    lists:reverse(Acc);
searchFiles(Root, [Rel | Rest], Query, Max, Acc) ->
    Abs = filename:join([Root | filename:split(toList(Rel))]),
    case file:read_file(Abs) of
        {ok, Content} ->
            Lines = binary:split(Content, <<"\n"/utf8>>, [global]),
            FileMatches = collectLineMatches(Rel, Lines, Query, 1, []),
            %% FileMatches 与 Acc 均按“最新匹配前置”累积，避免 Acc ++ FileMatches 的 O(n²) 复制。
            searchFiles(Root, Rest, Query, Max, FileMatches ++ Acc);
        {error, _} ->
            searchFiles(Root, Rest, Query, Max, Acc)
    end.

%% 收集单文件中包含 query 的行号与截断后的行文本。
%% 采用前插累加器，最终由 searchFiles 统一 reverse，保持原始顺序。
collectLineMatches(_Rel, [], _Query, _N, Acc) ->
    Acc;
collectLineMatches(Rel, [Line | Rest], Query, N, Acc) ->
    case binary:match(Line, Query) of
        nomatch ->
            collectLineMatches(Rel, Rest, Query, N + 1, Acc);
        _ ->
            collectLineMatches(Rel, Rest, Query, N + 1,
                               [#{file => Rel, line => N, text => trimLine(Line)} | Acc])
    end.

%% 将过长行截断至 200 字节。
trimLine(Line) ->
    case byte_size(Line) > 200 of
        true -> binary:part(Line, 0, 200);
        false -> Line
    end.

%% @doc 刷新代码索引并返回统计与模块摘要列表。
-spec projectIndex(map(), map()) -> {ok, map()} | {error, term()}.
projectIndex(_Args, Config) ->
    case alCodeIndexer:refresh(Config) of
        {ok, Stats} ->
            Modules = [summarizeIndex(M) || M <- alCodeIndexer:allModules()],
            {ok, maps:merge(Stats, #{
                root => maps:get(projectRoot, Config, <<"."/utf8>>),
                modules => lists:sublist(Modules, 50)
            })};
        {error, Reason} ->
            {error, Reason}
    end.

%% 将索引条目压缩为模块摘要 map。
summarizeIndex(Mod) ->
    case alCodeIndexer:lookupModule(Mod) of
        {ok, E} ->
            #{
                module => Mod,
                file => maps:get(file, E),
                exports => maps:get(exports, E),
                behaviours => maps:get(behaviours, E, [])
            };
        {error, _} ->
            #{module => Mod}
    end.

%% 从配置或自动探测获取项目根目录。
projectRoot(Config) ->
    case maps:get(projectRoot, Config, undefined) of
        undefined ->
            findProjectRootFromModule();
        Root ->
            normalizePath(Root)
    end.

%% @doc 通过已加载模块路径向上查找含 rebar.config 的项目根。
-spec findProjectRootFromModule() -> string().
findProjectRootFromModule() ->
    case code:which(llmCli) of
        Path when is_list(Path) ->
            findProjectRoot(filename:dirname(Path));
        _ ->
            case file:get_cwd() of
                {ok, Cwd} -> normalizePath(Cwd);
                {error, _} -> "."
            end
    end.

%% 自底向上递归查找 rebar.config 所在目录。
findProjectRoot(Dir) ->
    case filelib:is_file(filename:join(Dir, "rebar.config")) of
        true ->
            normalizePath(Dir);
        false ->
            Parent = filename:dirname(Dir),
            case Parent =:= Dir of
                true ->
                    case file:get_cwd() of
                        {ok, Cwd} -> normalizePath(Cwd);
                        {error, _} -> "."
                    end;
                false ->
                    findProjectRoot(Parent)
            end
    end.

%% @doc 解析编辑用路径（别名，与 resolvePath 相同约束）。
-spec resolvePathForEdit(string(), term()) -> {ok, string()} | {error, term()}.
resolvePathForEdit(Root, Path) ->
    resolvePath(Root, Path).

%% 将相对路径解析为绝对路径并校验在项目根内且非屏蔽路径。
resolvePath(Root, Path) ->
    RootNorm = normalizePath(Root),
    Rel = toList(Path),
    Abs = case Rel of
        "." -> RootNorm;
        "./" ++ _ -> normalizePath(filename:join(RootNorm, Rel));
        _ -> normalizePath(filename:join(RootNorm, Rel))
    end,
    case isSubpath(RootNorm, Abs) of
        true ->
            case isBlockedPath(Abs) of
                true -> {error, pathBlocked};
                false -> {ok, Abs}
            end;
        false ->
            {error, pathOutsideProject}
    end.

%% 判断 Abs 是否在 Root 目录树下。
%% 统一分隔符为 "/" 后比较：Erlang 的 filename 函数在 Windows 上也用 "/"，
%% 直接用 OS 原生 "\\" 比较会导致嵌套路径误判为越界。
isSubpath(Root, Path) ->
    R = unifySep(Root),
    P = unifySep(Path),
    P =:= R orelse string:prefix(P, R ++ "/") =/= nomatch.

%% 将路径中的反斜杠统一为正斜杠，便于跨平台前缀比较。
unifySep(Path) ->
    [case C of $\\ -> $/; _ -> C end || C <- Path].

%% 检测 .git、_build、.env 等禁止 Agent 访问的路径片段。
%% 注意：路径已通过 unifySep 统一为 "/" 分隔符，无需匹配 "\\" 模式。
isBlockedPath(Path) ->
    Lower = string:lowercase(unifySep(Path)),
    Blocked = [
        "/.git/",
        "/_build/",
        "/.rebar3/",
        "/.env",
        "/.env.",
        "/.erlang.cookie",
        "/.ssh/",
        "/.aws/",
        "/config/aliCfg.cfg",
        "/config/config.local.cfg",
        "/.al/",
        "/rebar3.crashdump"
    ],
    lists:any(fun(B) -> string:str(Lower, string:lowercase(B)) > 0 end, Blocked).

%% 按扩展名判断是否为可搜索的文本文件。
isTextFile(F) ->
    Ext = filename:extension(toList(F)),
    lists:member(Ext, [".erl", ".hrl", ".md", ".json", ".config", ".src", ".txt", ".yaml", ".yml"]).

%% 计算相对于项目根的路径（binary）。
relativePath(Root, Abs) ->
    RootNorm = unifySep(normalizePath(Root)),
    AbsNorm = unifySep(normalizePath(Abs)),
    case string:prefix(AbsNorm, RootNorm ++ "/") of
        nomatch ->
            toBinary(filename:basename(AbsNorm));
        Rest ->
            toBinary(Rest)
    end.

%% 规范化路径：absname 并解析符号链接。
normalizePath(Path) when is_binary(Path) ->
    normalizePath(binary_to_list(Path));
normalizePath(Path) ->
    canonicalPath(filename:absname(Path), 0).

%% 解析符号链接获取规范路径，防止路径穿越攻击和无限递归
canonicalPath(Path, Depth) ->
    MaxDepth = alConfig:get(symlinkMaxDepth),
    canonicalPath(Path, Depth, MaxDepth).

canonicalPath(Path, Depth, MaxDepth) when Depth >= MaxDepth ->
    error_logger:warning_msg("~p: symlink too deep: ~s~n", [?MODULE, Path]),
    Path;
canonicalPath(Path, Depth, MaxDepth) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = symlink}} ->
            case file:read_link(Path) of
                {ok, Target} ->
                    TargetNorm = filename:absname(Target, filename:dirname(Path)),
                    canonicalPath(TargetNorm, Depth + 1, MaxDepth);
                _ ->
                    Path
            end;
        _ ->
            Path
    end.

toList(X) when is_binary(X) -> unicode:characters_to_list(X);
toList(X) when is_list(X) -> X;
toList(X) when is_atom(X) -> atom_to_list(X).

toBinary(X) when is_binary(X) -> X;
toBinary(X) when is_list(X) -> unicode:characters_to_binary(X);
toBinary(X) when is_atom(X) -> atom_to_binary(X, utf8);
toBinary(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).