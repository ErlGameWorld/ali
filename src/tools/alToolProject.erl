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

-define(DEFAULT_MAX_FILE_BYTES, 65536).
-define(DEFAULT_MAX_RESULTS, 50).

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
                    MaxBytes = maps:get(maxBytes, Args, ?DEFAULT_MAX_FILE_BYTES),
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
                        content => Partial
                    }};
                {error, Reason} ->
                    {error, Reason}
            end;
        {ok, #file_info{type = regular}} ->
            case file:read_file(AbsPath) of
                {ok, Content} ->
                    {ok, #{path => AbsPath, truncated => false, content => Content}};
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
collectFiles(Dir, Pattern, true, Acc) ->
    PatternStr = toList(Pattern),
    Glob = filename:join(Dir, PatternStr),
    Direct = filelib:wildcard(Glob),
    SubDirs = [filename:join(Dir, D) || D <- filelib:wildcard(filename:join(Dir, "*")),
                                       filelib:is_dir(filename:join(Dir, D))],
    Acc1 = lists:usort(Acc ++ Direct),
    lists:foldl(fun(Sub, A) -> collectFiles(Sub, Pattern, true, A) end, Acc1, SubDirs);
collectFiles(Dir, Pattern, false, Acc) ->
    PatternStr = toList(Pattern),
    Glob = filename:join(Dir, PatternStr),
    lists:usort(Acc ++ filelib:wildcard(Glob)).

%% @doc 在项目文本文件中搜索 query 子串，返回匹配行列表。
-spec searchText(map(), map()) -> {ok, map()} | {error, term()}.
searchText(Args, Config) ->
    Query = maps:get(query, Args, undefined),
    Root = projectRoot(Config),
    MaxResults = maps:get(maxResults, Args, ?DEFAULT_MAX_RESULTS),
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
    Acc;
searchFiles(_Root, _Files, _Query, Max, Acc) when length(Acc) >= Max ->
    Acc;
searchFiles(Root, [Rel | Rest], Query, Max, Acc) ->
    Abs = filename:join([Root | filename:split(toList(Rel))]),
    case file:read_file(Abs) of
        {ok, Content} ->
            Lines = binary:split(Content, <<"\n"/utf8>>, [global]),
            FileMatches = collectLineMatches(Rel, Lines, Query, 1, []),
            searchFiles(Root, Rest, Query, Max, Acc ++ FileMatches);
        {error, _} ->
            searchFiles(Root, Rest, Query, Max, Acc)
    end.

%% 收集单文件中包含 query 的行号与截断后的行文本。
collectLineMatches(_Rel, [], _Query, _N, Acc) ->
    Acc;
collectLineMatches(Rel, [Line | Rest], Query, N, Acc) ->
    case binary:match(Line, Query) of
        nomatch ->
            collectLineMatches(Rel, Rest, Query, N + 1, Acc);
        _ ->
            collectLineMatches(Rel, Rest, Query, N + 1,
                               Acc ++ [#{file => Rel, line => N, text => trimLine(Line)}])
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
            Modules = [summarize_index(M) || M <- alCodeIndexer:all_modules()],
            {ok, maps:merge(Stats, #{
                root => maps:get(projectRoot, Config, <<"."/utf8>>),
                modules => lists:sublist(Modules, 50)
            })};
        {error, Reason} ->
            {error, Reason}
    end.

%% 将索引条目压缩为模块摘要 map。
summarize_index(Mod) ->
    case alCodeIndexer:lookup_module(Mod) of
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
isSubpath(Root, Path) ->
    Sep = pathSeparator(),
    RootPrefix = Root ++ Sep,
    Path =:= Root orelse string:prefix(Path, RootPrefix) =/= nomatch.

%% 检测 .git、_build、.env 等禁止 Agent 访问的路径片段。
isBlockedPath(Path) ->
    Lower = string:lowercase(Path),
    Blocked = [
        "/.git/", "\\.git\\",
        "/_build/", "\\_build\\",
        "/.rebar3/", "\\.rebar3\\",
        "/.env", "\\.env",
        "/.env.", "\\.env.",
        "/.erlang.cookie", "\\.erlang.cookie",
        "/.ssh/", "\\.ssh\\",
        "/.aws/", "\\.aws\\",
        "/rebar3.crashdump", "\\rebar3.crashdump"
    ],
    lists:any(fun(B) -> string:str(Lower, B) > 0 end, Blocked).

%% 按扩展名判断是否为可搜索的文本文件。
isTextFile(F) ->
    Ext = filename:extension(toList(F)),
    lists:member(Ext, [".erl", ".hrl", ".md", ".json", ".config", ".src", ".txt", ".yaml", ".yml"]).

%% 计算相对于项目根的路径（binary）。
relativePath(Root, Abs) ->
    RootNorm = normalizePath(Root),
    AbsNorm = normalizePath(Abs),
    Sep = pathSeparator(),
    case string:prefix(AbsNorm, RootNorm ++ Sep) of
        nomatch ->
            toBinary(filename:basename(AbsNorm));
        Rest ->
            toBinary(Rest)
    end.

-define(MAX_SYMLINK_DEPTH, 20).

%% 规范化路径：absname 并解析符号链接。
normalizePath(Path) when is_binary(Path) ->
    normalizePath(binary_to_list(Path));
normalizePath(Path) ->
    canonicalPath(filename:absname(Path), 0).

%% 解析符号链接获取规范路径，防止路径穿越攻击和无限递归
canonicalPath(Path, Depth) when Depth >= ?MAX_SYMLINK_DEPTH ->
    error_logger:warning_msg("~p: symlink too deep: ~s~n", [?MODULE, Path]),
    Path;
canonicalPath(Path, Depth) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = symlink}} ->
            case file:read_link(Path) of
                {ok, Target} ->
                    TargetNorm = filename:absname(Target, filename:dirname(Path)),
                    canonicalPath(TargetNorm, Depth + 1);
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

%% 返回当前 OS 的路径分隔符。
pathSeparator() ->
    case os:type() of
        {win32, _} -> "\\";
        _ -> "/"
    end.