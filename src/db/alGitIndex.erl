%%%-------------------------------------------------------------------
%% @doc 感知 Git 的增量索引驱动。
%%
%% `gitChangedFiles/1` 调用 `git status --porcelain`，返回给定根下
%% 变更文件列表，并经 `ignore:is_indexable/1` 过滤。
%%
%% `incrementalIndex/1` 是薄封装：
%%   1. 计算变更文件列表（含 status）
%%   2. 以列表形式报告
%%   3. 触发 Rust 再索引（`/index`），未变文件按内容哈希跳过
%%
%% 驱动让 WebUI 显示「自上次 commit 起 N 个文件变更」，并仅对脏文件
%% 强制再索引。全量遍历仍在 Rust 中完成，但运维可见触发原因。
%% @end
%%%-------------------------------------------------------------------

-module(alGitIndex).

-export([
    isGitRepo/1,
    probeRepo/1,
    gitChangedFiles/1,
    gitStatusMap/1,
    incrementalIndex/1,
    recentFiles/0,
    recentFiles/1,
    recentFiles/2,
    clearRecentCache/0,
    recentCommits/0,
    recentCommits/1,
    recentCommits/2,
    listCommits/1,
    searchCommits/1,
    commitFiles/1,
    commitDiff/1,
    filesModifiedSince/2,
    filesByAuthor/2,
    filesByVcsStatus/2,
    vcsFileFilter/1
]).
%% 测试导出 — 纯辅助函数
-export([normalizePath/1, parseCommitLines/1, parseCommitShowStat/1,
         parseCommitBlocksWithFiles/1, buildLogArgs/1, statusMatches/2,
         parseNameOnly/1]).

-define(RecentCacheTable, alGitRecentCache).
-define(RecentCacheTtlMs, 300000).  %% 5 分钟：git log 较慢，缓存避免重复 shell out
-define(DefaultRecentDays, 14).

%%--------------------------------------------------------------------
%% @doc
%% 检测给定根目录是否在 git 工作树中。
%%
%% @param Root 仓库根目录
%% @return boolean()
%% @end
%%--------------------------------------------------------------------
-spec isGitRepo(file:filename()) -> boolean().
isGitRepo(Root) ->
    case probeRepo(Root) of
        {ok, git} -> true;
        _ -> false
    end.

%%--------------------------------------------------------------------
%% @doc
%% 探测 git 仓库，失败时返回具体原因（不再吞成 false）。
%% 注意：本模块用进程内 `open_port` 起 git，与 runMfa 黑名单无关。
%%
%% @return {ok, git} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec probeRepo(file:filename()) -> {ok, git} | {error, term()}.
probeRepo(Root) when is_list(Root); is_binary(Root) ->
    R = unicode:characters_to_list(Root),
    case runGit(R, ["rev-parse", "--is-inside-work-tree"]) of
        {ok, Out} ->
            case string:trim(Out) =:= "true" of
                true -> {ok, git};
                false -> {error, {notInsideWorkTree, string:trim(Out)}}
            end;
        {error, _} = Err ->
            Err
    end;
probeRepo(_) ->
    {error, invalidRoot}.

%%--------------------------------------------------------------------
%% @doc
%% `git status --porcelain' 的解析结果：
%% 每行形如 `XY <path>'，第二列之后是路径。
%% 过滤掉不在白名单内的文件。
%%
%% @param Root 仓库根目录
%% @return 文件路径列表（相对 Root）
%% @end
%%--------------------------------------------------------------------
-spec gitChangedFiles(file:filename()) -> [string()].
gitChangedFiles(Root) ->
    [Path || {_, Path} <- gitStatusMap(Root)].

%%--------------------------------------------------------------------
%% @doc
%% 返回 `[ {Status, Path} ]' 形式的 git status 列表（Status 为
%% porcelain 两字母代码加空格，例如 " M"、"M "、"A "、"??")。
%%
%% @param Root 仓库根目录
%% @return 状态/路径元组列表
%% @end
%%--------------------------------------------------------------------
-spec gitStatusMap(file:filename()) -> [{string(), string()}].
gitStatusMap(Root) when is_list(Root); is_binary(Root) ->
    R = unicode:characters_to_list(Root),
    case runGit(R, ["status", "--porcelain", "--untracked-files=all"]) of
        {ok, Output} ->
            Lines = [L || L <- string:split(Output, "\n", all),
                          string:trim(L) =/= ""],
            Parsed = [parsePorcelainLine(L) || L <- Lines],
            lists:filter(fun({_S, P}) -> indexableRel(R, P) end, Parsed);
        _ -> []
    end;
gitStatusMap(_) -> [].

%%--------------------------------------------------------------------
%% @doc
%% 触发增量索引：返回 `{ok, Map}' 包含
%%   - changedFiles: git 报告的索引白名单内变更文件数
%%   - statusMap: 完整 git status map
%%   - indexResponse: Rust `/index` 调用结果
%% 适用于：agent 工具、HTTP 入口 `POST /api/index/git`。
%%
%% @param Root 仓库根目录
%% @return {ok, Map} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec incrementalIndex(file:filename()) -> {ok, map()} | {error, term()}.
incrementalIndex(Root) ->
    R = unicode:characters_to_list(Root),
    Status = gitStatusMap(R),
    ChangedCount = length(Status),
    try
        %% 调 Rust 增量索引；现有实现已基于 hash 跳过未变文件。
        case alCoreClient:index(R) of
            {ok, M} ->
                {ok, #{
                    root => R,
                    gitRepo => isGitRepo(R),
                    changedFiles => ChangedCount,
                    statusMap => Status,
                    indexResponse => M
                }};
            {error, Reason} ->
                {error, Reason}
        end
    catch C:E ->
        {error, {C, E}}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 返回自 `Since' 后被 git 提交修改过的文件集合（去重）。
%% `Since' 可为相对时间（"2 weeks ago"）或绝对日期（"2026-07-01"）。
%% 仅返回通过索引白名单的文件。
%%
%% @param Root 仓库根目录
%% @param Since git --since 参数
%% @return 文件路径（相对 root）列表
%% @end
%%--------------------------------------------------------------------
-spec filesModifiedSince(file:filename(), iodata()) -> [string()].
filesModifiedSince(Root, Since) ->
    R = unicode:characters_to_list(Root),
    SinceArg = unicode:characters_to_list(Since),
    Args = ["log", "--since=" ++ SinceArg, "--name-only", "--pretty=format:",
            "--max-count=500"],
    case runGit(R, Args) of
        {ok, Output} ->
            Files = parseNameOnly(Output),
            lists:usort([normalizePath(F) || F <- Files, indexableRel(R, F)]);
        _ ->
            []
    end.

%%--------------------------------------------------------------------
%% @doc
%% 返回指定作者提交过的文件集合（去重）。仅返回索引白名单内文件。
%%
%% @param Root 仓库根目录
%% @param Author git --author 参数
%% @return 文件路径列表
%% @end
%%--------------------------------------------------------------------
-spec filesByAuthor(file:filename(), iodata()) -> [string()].
filesByAuthor(Root, Author) ->
    R = unicode:characters_to_list(Root),
    AuthorArg = unicode:characters_to_list(Author),
    Args = ["log", "--author=" ++ AuthorArg, "--name-only", "--pretty=format:",
            "--max-count=500"],
    case runGit(R, Args) of
        {ok, Output} ->
            Files = parseNameOnly(Output),
            lists:usort([normalizePath(F) || F <- Files, indexableRel(R, F)]);
        _ ->
            []
    end.

%%--------------------------------------------------------------------
%% @doc
%% 按工作区状态过滤文件。`Statuses' 为 atom/binary/list 或其列表，
%% 取值 `modified | added | untracked | deleted | renamed'。
%%
%% @param Root 仓库根目录
%% @param Statuses 状态名或列表
%% @return 文件路径列表
%% @end
%%--------------------------------------------------------------------
-spec filesByVcsStatus(file:filename(), term()) -> [string()].
filesByVcsStatus(Root, Statuses) ->
    NormStatuses = [normalizeStatus(S) || S <- ensureListVcs(Statuses)],
    StatusMap = gitStatusMap(Root),
    [P || {S, P} <- StatusMap,
          lists:any(fun(NS) -> statusMatches(NS, S) end, NormStatuses)].

%%--------------------------------------------------------------------
%% @doc
%% 组合 VCS 文件过滤：`Opts' 可含 `modifiedSince' / `author' / `vcsStatus'
%% / `root'（缺省项目根）。多个条件取交集；任一条件为空结果则整体为空。
%%
%% @param Opts 过滤选项 map
%% @return `#{files => [binary()], count => integer()}'
%% @end
%%--------------------------------------------------------------------
-spec vcsFileFilter(map()) -> map().
vcsFileFilter(Opts) when is_map(Opts) ->
    Root0 = case maps:get(root, Opts, undefined) of
        undefined -> unicode:characters_to_list(alConfig:projectRoot());
        R -> unicode:characters_to_list(R)
    end,
    Since = nonemptyStr(maps:get(modifiedSince, Opts, undefined)),
    Author = nonemptyStr(maps:get(author, Opts, undefined)),
    VcsStatus = case maps:get(vcsStatus, Opts, undefined) of
        undefined -> undefined;
        V -> V
    end,
    Sets = lists:filtermap(
        fun
            ({since, V}) when V =/= undefined ->
                {true, filesModifiedSince(Root0, V)};
            ({author, V}) when V =/= undefined ->
                {true, filesByAuthor(Root0, V)};
            ({vcsStatus, V}) when V =/= undefined ->
                {true, filesByVcsStatus(Root0, V)};
            (_) ->
                false
        end,
        [{since, Since}, {author, Author}, {vcsStatus, VcsStatus}]),
    case Sets of
        [] ->
            #{files => [], count => 0, reason => noFilter};
        _ ->
            OrdSets = [ordsets:from_list(S) || S <- Sets],
            Intersection = lists:foldl(fun ordsets:intersection/2,
                                       hd(OrdSets), tl(OrdSets)),
            Files = [unicode:characters_to_binary(F) || F <- Intersection],
            #{files => Files, count => length(Files)}
    end.

%%--------------------------------------------------------------------
%% 内部：解析 `git log --name-only --pretty=format:' 输出，按行取非空路径。
%%--------------------------------------------------------------------
parseNameOnly(Output) ->
    Lines = string:split(Output, "\n", all),
    [string:trim(L) || L <- Lines, string:trim(L) =/= ""].

%%--------------------------------------------------------------------
%% 内部：状态名归一化为 atom（modified|added|untracked|deleted|renamed）。
%%--------------------------------------------------------------------
normalizeStatus(S) when is_atom(S) -> S;
normalizeStatus(S) when is_binary(S) ->
    try binary_to_existing_atom(S, utf8) catch _:_ -> unknown end;
normalizeStatus(S) when is_list(S) ->
    try list_to_existing_atom(S) catch _:_ -> unknown end;
normalizeStatus(_) -> unknown.

%%--------------------------------------------------------------------
%% 内部：porcelain 状态码（2 字符）是否匹配给定状态名。
%% XY 格式：X=staged，Y=worktree。
%%--------------------------------------------------------------------
statusMatches(modified, [X, Y | _]) -> X =:= $M orelse Y =:= $M;
statusMatches(added, [X, Y | _]) -> X =:= $A orelse Y =:= $A;
statusMatches(untracked, "??") -> true;
statusMatches(deleted, [X, Y | _]) -> X =:= $D orelse Y =:= $D;
statusMatches(renamed, [X, Y | _]) -> X =:= $R orelse Y =:= $R;
statusMatches(_, _) -> false.

%%--------------------------------------------------------------------
%% 内部：把 VCS 状态参数归一为列表（单值 → 单元素列表）。
%%--------------------------------------------------------------------
ensureListVcs([]) -> [];
ensureListVcs(L) when is_list(L), is_integer(hd(L)) -> [L];
ensureListVcs(L) when is_list(L) -> L;
ensureListVcs(B) when is_binary(B) -> [B];
ensureListVcs(A) when is_atom(A) -> [A];
ensureListVcs(undefined) -> [];
ensureListVcs(_) -> [].

%%--------------------------------------------------------------------
%% 内部：执行 git 命令并返回 stdout。
%% 使用 `spawn_executable' 逐参数传入（不经 shell 拼接），避免 Windows 下
%% os:cmd 单引号无效、以及路径含空格/引号造成的命令注入或解析错误。
%%
%% NFS/多用户检出常见「dubious ownership」：对本调用注入
%% `-c safe.directory=<Root>` 与 `safe.directory=*`（仅本次进程，不改全局 gitconfig）。
%%--------------------------------------------------------------------
runGit(Root, Args) ->
    case os:find_executable("git") of
        false ->
            {error, gitNotFound};
        Git ->
            AbsRoot = filename:absname(Root),
            %% 先标具体路径，再标 *，覆盖路径规范化不一致的挂载点
            %% core.quotePath=false：让 git 直接输出 UTF-8 路径，而非把非 ASCII
            %% 字符转义成 \"\\nnn\" 八进制（unquotePath 仅做引号去除，无法反转义）。
            SafeArgs = ["-c", "safe.directory=" ++ AbsRoot,
                        "-c", "safe.directory=*",
                        "-c", "core.quotePath=false" | Args],
            PortOpts = [exit_status, use_stdio, stderr_to_stdout, binary,
                        {cd, Root}, {args, SafeArgs}],
            try open_port({spawn_executable, Git}, PortOpts) of
                Port when is_port(Port) ->
                    classifyGitError(collectGitOutput(Port, []), AbsRoot)
            catch
                error:Reason -> {error, Reason}
            end
    end.

%% 把 dubious ownership 等常见失败标成可读 atom，便于 diagnose / 工具提示。
classifyGitError({error, {gitExit, _Code, Out}} = Err, Root) ->
    case isDubiousOwnership(Out) of
        true ->
            {error, {dubiousOwnership, Root, Out}};
        false ->
            Err
    end;
classifyGitError(Other, _Root) ->
    Other.

isDubiousOwnership(Out) when is_list(Out) ->
    string:find(Out, "dubious ownership") =/= nomatch;
isDubiousOwnership(Out) when is_binary(Out) ->
    isDubiousOwnership(unicode:characters_to_list(Out));
isDubiousOwnership(_) ->
    false.

%% 收集 git 端口输出直到 exit_status，返回 `{ok, OutputString}'。
%% 空输出返回 `{error, empty}'（与调用方既有语义一致）。
%% 超时后 safeClosePort + flushPortMessages 清空残留 {Port,...} 消息，
%% 避免下次 open_port 复用端口句柄时被旧消息污染。
collectGitOutput(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collectGitOutput(Port, [Data | Acc]);
        {Port, {exit_status, Code}} ->
            Bin = iolist_to_binary(lists:reverse(Acc)),
            case decodeCmdOutput(Bin) of
                {ok, Out} when Code =:= 0 -> {ok, Out};
                {ok, Out} -> {error, {gitExit, Code, Out}};
                {error, Reason} -> {error, Reason}
            end
    after 30000 ->
        safeClosePort(Port),
        flushPortMessages(Port),
        Bin = iolist_to_binary(lists:reverse(Acc)),
        case decodeCmdOutput(Bin) of
            {ok, Out} -> {ok, Out};
            {error, _} -> {error, timeout}
        end
    end.

%% 同步清空 Port 邮箱中残留的 {Port,...} 消息（超时强杀后兜底）。
%% 0 超时立即返回，不阻塞。
flushPortMessages(Port) ->
    receive
        {Port, _} -> flushPortMessages(Port)
    after 0 -> ok
    end.

%% 与 alSvnIndex 相同：UTF-8 失败时 latin1 兜底，避免中文 locale 崩解析。
decodeCmdOutput(<<>>) ->
    {error, empty};
decodeCmdOutput(Bin) when is_binary(Bin) ->
    case unicode:characters_to_list(Bin) of
        L when is_list(L) ->
            {ok, L};
        {error, Good, Rest} ->
            {ok, unicode_good(Good) ++ binary_to_list(iolist_to_binary(Rest))};
        {incomplete, Good, Rest} ->
            {ok, unicode_good(Good) ++ binary_to_list(iolist_to_binary(Rest))}
    end.

unicode_good(G) when is_list(G) -> G;
unicode_good(G) when is_binary(G) -> binary_to_list(G);
unicode_good(_) -> [].

%% 安全关闭端口：已关闭时 port_close 抛 badarg，用 try 兜住。
safeClosePort(Port) ->
    try port_close(Port) catch _:_ -> ok end.

%% 内部：把单行 porcelain 解析为 {Status, Path}，处理引号包裹的路径。
parsePorcelainLine(Line) ->
    case Line of
        [S1, S2, $\s | Rest] -> {[S1, S2], unquotePath(Rest)};
        [S1, S2 | Rest] -> {[S1, S2], unquotePath(Rest)};
        _ -> {"", unquotePath(Line)}
    end.

unquotePath(Path) ->
    case Path of
        [$" | _] ->
            string:trim(Path, both, "\"");
        _ -> string:trim(Path)
    end.

%% 内部：路径是否在索引白名单内（用绝对路径判定）。
%% Erlang 端没有 ignore.rs 镜像，使用一份默认扩展名白名单同步。
indexableRel(Root, RelPath) ->
    Abs = filename:join(Root, RelPath),
    case filename:extension(Abs) of
        <<>> -> false;
        Ext ->
            Norm = string:lowercase(unicode:characters_to_list(Ext)),
            Trim = case Norm of [$., C | Rest] -> [C | Rest]; _ -> Norm end,
            lists:member(Trim, defaultIndexExts()) andalso filelib:is_file(Abs)
    end.

%% 默认索引扩展名白名单（与 c_src/aliCore/src/ignore.rs 同步）。
defaultIndexExts() ->
    ["erl", "hrl", "cfg", "rs", "c", "h", "md", "txt", "json", "yaml", "yml",
     "toml", "sh", "py", "js", "ts", "tsx", "jsx"].

%%%===================================================================
%%% 最近变更文件（git log）— 用于召回结果 Git 加权
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 返回默认项目根 + 默认 14 天内 git 提交涉及的文件集合（去重 ordset）。
%% 结果带 5 分钟 ETS 缓存，避免每次检索都 shell out git log。
%%
%% @return ordsets:ordset(string()) 相对 root 的归一化路径
%% @end
%%--------------------------------------------------------------------
recentFiles() ->
    recentFiles(alConfig:projectRoot(), ?DefaultRecentDays).

%%--------------------------------------------------------------------
%% @doc
%% 返回指定根目录最近 14 天内 git 提交涉及的文件集合。
%%
%% @param Root 仓库根目录
%% @return ordsets:ordset(string())
%% @end
%%--------------------------------------------------------------------
recentFiles(Root) ->
    recentFiles(Root, ?DefaultRecentDays).

%%--------------------------------------------------------------------
%% @doc
%% 返回指定根目录最近 Days 天内 git 提交涉及的文件集合（去重 ordset）。
%%
%% 用 `git log --name-only --since=N.days.ago' 一次拿到所有变更文件，
%% 归一化路径后去重。非 git 仓库返回空 ordset。
%%
%% @param Root 仓库根目录
%% @param Days 回溯天数
%% @return ordsets:ordset(string()) 归一化后的相对路径
%% @end
%%--------------------------------------------------------------------
recentFiles(Root, Days) when is_integer(Days), Days > 0 ->
    case lookupRecentCache(Root, Days) of
        {ok, Set} ->
            Set;
        false ->
            Set = computeRecentFiles(Root, Days),
            storeRecentCache(Root, Days, Set),
            Set
    end;
recentFiles(_, _) ->
    ordsets:new().

%%--------------------------------------------------------------------
%% @doc 清空 recentFiles 缓存（文件变更后强制刷新）。
%% @end
%%--------------------------------------------------------------------
clearRecentCache() ->
    case ets:whereis(?RecentCacheTable) of
        undefined -> ok;
        _ -> ets:match_delete(?RecentCacheTable, '_'), ok
    end.

%%--------------------------------------------------------------------
%% @doc
%% 路径归一化：统一为正斜杠、去除前导 ./ ，便于跨平台匹配。
%%
%% @param Path 文件路径（list/binary/atom）
%% @return string() 归一化路径
%% @end
%%--------------------------------------------------------------------
normalizePath(Path) when is_atom(Path) ->
    normalizePath(atom_to_list(Path));
normalizePath(Path) ->
    S = unicode:characters_to_list(Path),
    %% string:replace 可能返回深 list，再扁平化一次确保 case 模式匹配字符
    Fwd = unicode:characters_to_list(string:replace(S, "\\", "/", all)),
    Trim = case Fwd of
        [$., $/ | Rest] -> Rest;  %% "./foo" -> "foo"
        _ -> Fwd
    end,
    string:trim(Trim).

%%%===================================================================
%%% Internal: git log + cache
%%%===================================================================

%% 实际执行 git log 拿最近变更文件。
computeRecentFiles(Root, Days) ->
    case isGitRepo(Root) of
        false -> ordsets:new();
        true ->
            R = unicode:characters_to_list(Root),
            SinceArg = io_lib:format("~p.days.ago", [Days]),
            Args = ["log", "--name-only", "--since", SinceArg,
                    "--pretty=format:", "--no-merges"],
            case runGit(R, Args) of
                {ok, Out} ->
                    Lines = [string:trim(L) || L <- string:split(Out, "\n", all)],
                    Paths = [normalizePath(L) || L <- Lines,
                                               L =/= "",
                                               indexableRel(R, L)],
                    ordsets:from_list(Paths);
                _ ->
                    ordsets:new()
            end
    end.

%%%===================================================================
%%% ETS cache for recentFiles
%%%===================================================================

ensureRecentCacheTable() ->
    case ets:whereis(?RecentCacheTable) of
        undefined ->
            try
                ets:new(?RecentCacheTable, [named_table, set, public,
                                            {read_concurrency, true}]),
                ok
            catch
                _:_ -> ok
            end;
        _ ->
            ok
    end.

lookupRecentCache(Root, Days) ->
    case ets:whereis(?RecentCacheTable) of
        undefined -> false;
        _ ->
            Key = {Root, Days},
            case ets:lookup(?RecentCacheTable, Key) of
                [{_, Set, Expiry}] when is_integer(Expiry) ->
                    case erlang:system_time(millisecond) < Expiry of
                        true -> {ok, Set};
                        false -> false
                    end;
                _ ->
                    false
            end
    end.

storeRecentCache(Root, Days, Set) ->
    ensureRecentCacheTable(),
    Key = {Root, Days},
    Expiry = erlang:system_time(millisecond) + ?RecentCacheTtlMs,
    ets:insert(?RecentCacheTable, {Key, Set, Expiry}),
    ok.

%%%===================================================================
%%% 提交历史与 diff（变更影响分析用）
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 返回最近 10 条提交记录（hash/author/date/subject）。
%%
%% @return {ok, [#{hash, author, date, subject}]} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
recentCommits() ->
    recentCommits(10).

%%--------------------------------------------------------------------
%% @doc
%% 返回最近 N 条提交记录。用 `%x1f'（unit separator）分隔字段，
%% 避免与 commit message 里的 `|' 冲突。
%%
%% @param N 条数
%% @return {ok, [map()]} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
recentCommits(N) when is_integer(N), N > 0 ->
    R = projectRootList(),
    Args = ["log", "-n", integer_to_list(N),
            "--format=%H%x1f%an%x1f%ad%x1f%s"],
    case runGit(R, Args) of
        {ok, Out} -> {ok, parseCommitLines(Out)};
        Error -> Error
    end;
recentCommits(_) ->
    {error, invalidCount}.

%%--------------------------------------------------------------------
%% @doc 最近 N 条，且限制在最近 Days 天内（`--since=N days ago`）。
%% @end
%%--------------------------------------------------------------------
recentCommits(N, Days) when is_integer(N), N > 0, is_integer(Days), Days > 0 ->
    R = projectRootList(),
    Since = integer_to_list(Days) ++ " days ago",
    Args = ["log", "-n", integer_to_list(N),
            "--since=" ++ Since,
            "--format=%H%x1f%an%x1f%ad%x1f%s"],
    case runGit(R, Args) of
        {ok, Out} -> {ok, parseCommitLines(Out)};
        Error -> Error
    end;
recentCommits(_, _) ->
    {error, invalidCount}.

%%--------------------------------------------------------------------
%% @doc
%% 按选项列出提交。Opts 支持：
%%   limit / days / grep（message 子串，忽略大小写）/ author / path /
%%   withFiles（true 时附带本次改动文件列表，单次 git log --name-only）
%% @end
%%--------------------------------------------------------------------
-spec listCommits(map()) -> {ok, [map()]} | {error, term()}.
listCommits(Opts) when is_map(Opts) ->
    R = projectRootList(),
    Args = buildLogArgs(Opts),
    case runGit(R, Args) of
        {ok, Out} ->
            Commits = case maps:get(withFiles, Opts, false) =:= true of
                true -> parseCommitBlocksWithFiles(Out);
                false -> parseCommitLines(Out)
            end,
            {ok, Commits};
        Error ->
            Error
    end;
listCommits(_) ->
    {error, invalidOpts}.

%%--------------------------------------------------------------------
%% @doc
%% 按提交说明搜索（git log --grep）。Opts 必含 grep/query，其余同 listCommits。
%% @end
%%--------------------------------------------------------------------
-spec searchCommits(map()) -> {ok, [map()]} | {error, term()}.
searchCommits(Opts) when is_map(Opts) ->
    Grep = maps:get(grep, Opts, maps:get(query, Opts, maps:get(<<"grep">>, Opts,
                    maps:get(<<"query">>, Opts, undefined)))),
    case nonemptyStr(Grep) of
        undefined ->
            {error, missingGrep};
        Q ->
            listCommits(Opts#{grep => Q})
    end;
searchCommits(_) ->
    {error, invalidOpts}.

%%--------------------------------------------------------------------
%% @doc
%% 返回某次提交修改的文件列表（相对 root 的归一化路径；不过滤扩展名）。
%%
%% @param Ref 提交 hash/tag/branch
%% @return {ok, [string()]} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
commitFiles(Ref) when is_list(Ref); is_binary(Ref) ->
    R = projectRootList(),
    RefStr = unicode:characters_to_list(Ref),
    case runGit(R, ["show", "--name-only", "--pretty=format:", RefStr]) of
        {ok, Out} ->
            Paths = [normalizePath(string:trim(L))
                     || L <- string:split(Out, "\n", all),
                        string:trim(L) =/= ""],
            {ok, Paths};
        Error ->
            Error
    end;
commitFiles(_) ->
    {error, invalidRef}.

%%--------------------------------------------------------------------
%% @doc
%% 返回某次提交的完整信息：元数据 + 文件变更统计 + patch（限长避免过大）。
%%
%% @param Ref 提交 hash/tag/branch
%% @return {ok, #{hash, author, date, subject, files, stat, patch}} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
commitDiff(Ref) when is_list(Ref); is_binary(Ref) ->
    R = projectRootList(),
    RefStr = unicode:characters_to_list(Ref),
    %% 先拿元数据 + stat
    StatArgs = ["show", "--stat", "--format=%H%x1f%an%x1f%ad%x1f%s", RefStr],
    case runGit(R, StatArgs) of
        {ok, StatOut} ->
            Meta = parseCommitShowStat(StatOut),
            %% 再拿 patch（限长见 trimPatch）
            case runGit(R, ["show", "--format=", RefStr]) of
                {ok, PatchOut} ->
                    Patch = trimPatch(PatchOut),
                    {ok, Meta#{patch => Patch}};
                _ ->
                    {ok, Meta#{patch => <<>>}}
            end;
        Error ->
            Error
    end;
commitDiff(_) ->
    {error, invalidRef}.

%%%===================================================================
%%% Internal: commit parsing
%%%===================================================================

%% 构造 git log 参数（供测试）。
buildLogArgs(Opts) when is_map(Opts) ->
    Limit = clampInt(maps:get(limit, Opts, maps:get(count, Opts, 20)), 1, 200, 20),
    Format = "%H%x1f%an%x1f%ad%x1f%s",
    Base0 = ["log", "-n", integer_to_list(Limit), "--format=" ++ Format],
    Base1 = case maps:get(withFiles, Opts, false) =:= true of
        true -> Base0 ++ ["--name-only"];
        false -> Base0
    end,
    Base2 = case clampInt(maps:get(days, Opts, undefined), 1, 3650, undefined) of
        undefined -> Base1;
        Days -> Base1 ++ ["--since=" ++ integer_to_list(Days) ++ " days ago"]
    end,
    Base3 = case nonemptyStr(maps:get(grep, Opts, maps:get(query, Opts, undefined))) of
        undefined -> Base2;
        Grep -> Base2 ++ ["--grep=" ++ Grep, "-i"]
    end,
    Base4 = case nonemptyStr(maps:get(author, Opts, undefined)) of
        undefined -> Base3;
        Author -> Base3 ++ ["--author=" ++ Author]
    end,
    case nonemptyStr(maps:get(path, Opts, undefined)) of
        undefined -> Base4;
        Path -> Base4 ++ ["--", Path]
    end.

%% 解析带 --name-only 的 log：meta 行后跟文件路径，空行分隔提交。
parseCommitBlocksWithFiles(Out) ->
    Lines = string:split(Out, "\n", all),
    parseCommitBlocksWithFiles(Lines, undefined, [], []).

parseCommitBlocksWithFiles([], undefined, _FilesAcc, Acc) ->
    lists:reverse(Acc);
parseCommitBlocksWithFiles([], Meta, FilesAcc, Acc) when is_map(Meta) ->
    lists:reverse([finalizeCommitFiles(Meta, FilesAcc) | Acc]);
parseCommitBlocksWithFiles([Line | Rest], Meta, FilesAcc, Acc) ->
    Trim = string:trim(Line),
    case {Trim, lists:member(16#1f, Trim)} of
        {"", _} when is_map(Meta) ->
            parseCommitBlocksWithFiles(Rest, undefined, [],
                                       [finalizeCommitFiles(Meta, FilesAcc) | Acc]);
        {"", _} ->
            parseCommitBlocksWithFiles(Rest, Meta, FilesAcc, Acc);
        {_, false} when is_map(Meta) ->
            parseCommitBlocksWithFiles(Rest, Meta, [normalizePath(Trim) | FilesAcc], Acc);
        {_, _} ->
            NewMeta = parseCommitLine(Trim),
            case is_map(Meta) of
                true ->
                    parseCommitBlocksWithFiles(Rest, NewMeta, [],
                                               [finalizeCommitFiles(Meta, FilesAcc) | Acc]);
                false ->
                    parseCommitBlocksWithFiles(Rest, NewMeta, [], Acc)
            end
    end.

finalizeCommitFiles(Meta, FilesAcc) ->
    Files = lists:reverse(FilesAcc),
    Meta#{files => Files, fileCount => length(Files)}.

nonemptyStr(undefined) -> undefined;
nonemptyStr(<<>>) -> undefined;
nonemptyStr("") -> undefined;
nonemptyStr(B) when is_binary(B) ->
    case string:trim(unicode:characters_to_list(B)) of
        "" -> undefined;
        S -> S
    end;
nonemptyStr(L) when is_list(L) ->
    case string:trim(L) of
        "" -> undefined;
        S -> S
    end;
nonemptyStr(A) when is_atom(A) -> atom_to_list(A);
nonemptyStr(_) -> undefined.

clampInt(undefined, _Min, _Max, Default) -> Default;
clampInt(V, Min, Max, _Default) when is_integer(V) ->
    if V < Min -> Min; V > Max -> Max; true -> V end;
clampInt(V, Min, Max, Default) when is_binary(V) ->
    try clampInt(binary_to_integer(V), Min, Max, Default) catch _:_ -> Default end;
clampInt(V, Min, Max, Default) when is_list(V) ->
    try clampInt(list_to_integer(V), Min, Max, Default) catch _:_ -> Default end;
clampInt(_, _Min, _Max, Default) -> Default.

%% 解析 recentCommits 的输出：每行 `hash\x1fauthor\x1fdate\x1fsubject`
parseCommitLines(Out) ->
    Lines = [L || L <- string:split(Out, "\n", all), string:trim(L) =/= ""],
    [parseCommitLine(L) || L <- Lines].

parseCommitLine(Line) ->
    Parts = string:split(Line, [16#1f], all),  %% \x1f = unit separator
    case Parts of
        [Hash, Author, Date, Subject] ->
            #{hash => trimBin(Hash), author => trimBin(Author),
              date => trimBin(Date), subject => trimBin(Subject)};
        [Hash | _] ->
            #{hash => trimBin(Hash), author => <<>>, date => <<>>, subject => <<>>};
        _ ->
            #{hash => <<>>, author => <<>>, date => <<>>, subject => <<>>}
    end.

%% 解析 commitDiff 的 stat 输出：首行 `hash\x1fauthor\x1fdate\x1fsubject`，
%% 后续行是文件变更统计。
parseCommitShowStat(Out) ->
    Lines = string:split(Out, "\n", all),
    case [L || L <- Lines, string:trim(L) =/= ""] of
        [] ->
            #{hash => <<>>, author => <<>>, date => <<>>, subject => <<>>,
              files => [], stat => <<>>};
        [MetaLine | Rest] ->
            Meta = parseCommitLine(MetaLine),
            %% --stat 行含 " | " 的是统计；纯路径行较少。保留全部非空为 files 预览。
            Files = [trimBin(L) || L <- Rest, string:trim(L) =/= ""],
            Meta#{files => Files, stat => unicode:characters_to_binary(string:join(Rest, "\n"))}
    end.

%% 原样转为 UTF-8 binary，不做长度截断（上下文预算由工具层统一处理）。
trimPatch(PatchStr) when is_binary(PatchStr) ->
    PatchStr;
trimPatch(PatchStr) ->
    case unicode:characters_to_binary(PatchStr) of
        Bin when is_binary(Bin) -> Bin;
        {error, Good, _} -> unicode:characters_to_binary(Good);
        {incomplete, Good, _} -> unicode:characters_to_binary(Good);
        _ -> <<>>
    end.

%% 安全 projectRoot 转 list（alConfig 可能未启动）。
projectRootList() ->
    try unicode:characters_to_list(alConfig:projectRoot())
    catch _:_ -> "." end.

%% trim 为 binary。
%% trim 为 UTF-8 binary（中文 subject 含 >255 码点，不能用 iolist_to_binary）。
trimBin(S) when is_binary(S) ->
    case unicode:characters_to_binary(string:trim(unicode:characters_to_list(S))) of
        Bin when is_binary(Bin) -> Bin;
        _ -> S
    end;
trimBin(S) ->
    case unicode:characters_to_binary(string:trim(unicode:characters_to_list(S))) of
        Bin when is_binary(Bin) -> Bin;
        {error, Good, _} -> unicode:characters_to_binary(Good);
        {incomplete, Good, _} -> unicode:characters_to_binary(Good);
        _ -> <<>>
    end.
