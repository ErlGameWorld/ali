%%%-------------------------------------------------------------------
%% @doc SVN 后端：为 {@link alVcsIndex} 提供 svn 仓库的提交历史与 diff 能力。
%%
%% 通过 `svn' 命令行工具实现，与 {@link alGitIndex} 接口对齐：
%% <ul>
%% <li>{@link isSvnRepo/1}：`svn info' 检测是否 svn 工作副本。</li>
%% <li>{@link recentCommits/1}：`svn log -l N' 拿最近提交。</li>
%% <li>{@link commitFiles/1}：`svn log -v -r REV' 拿某次提交改了哪些文件。</li>
%% <li>{@link commitDiff/1}：`svn diff -c REV' 拿某次提交的 patch。</li>
%% <li>{@link recentFiles/2}：`svn log -v -r {DATE}:{HEAD}' 按日期范围拿变更文件。</li>
%% <li>{@link vcsFileFilter/1}：与 git 对称的 modifiedSince/author/vcsStatus 文件过滤。</li>
%% </ul>
%%
%% svn log 输出为非结构化文本，本模块按 `---...---' 分隔条目解析。
%% @end
%%%-------------------------------------------------------------------

-module(alSvnIndex).

-export([
    isSvnRepo/1,
    probeRepo/1,
    svnChangedFiles/1,
    svnStatusMap/1,
    incrementalIndex/1,
    filesModifiedSince/2,
    filesByAuthor/2,
    filesByVcsStatus/2,
    vcsFileFilter/1,
    recentCommits/0,
    recentCommits/1,
    recentCommits/2,
    listCommits/1,
    searchCommits/1,
    commitFiles/1,
    commitDiff/1,
    recentFiles/0,
    recentFiles/1,
    recentFiles/2
]).
%% 测试导出 — 纯辅助函数
-export([
    parseSvnLog/1,
    parseSvnLogVerbose/1,
    parseRevision/1,
    formatDateForSvn/1,
    buildLogArgs/1,
    parseSvnStatusLine/1,
    statusMatches/2,
    parseSinceForSvn/1
]).

-define(DefaultRecentDays, 14).

%%%===================================================================
%%% 公共 API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 检测目录是否为 svn 工作副本：`svn info' 成功且输出含 `URL:' 即为 svn。
%% @end
%%--------------------------------------------------------------------
isSvnRepo(Root) ->
    case probeRepo(Root) of
        {ok, svn} -> true;
        _ -> false
    end.

%%--------------------------------------------------------------------
%% @doc
%% 探测 svn 工作副本；失败返回具体原因。进程内 open_port，与 runMfa 无关。
%% @end
%%--------------------------------------------------------------------
-spec probeRepo(file:filename()) -> {ok, svn} | {error, term()}.
probeRepo(Root) when is_list(Root); is_binary(Root) ->
    try
        case runSvn(unicode:characters_to_list(Root), ["info"]) of
            {ok, Out} when is_list(Out) ->
                case string:find(Out, "URL:") =/= nomatch of
                    true -> {ok, svn};
                    false -> {error, notSvnWorkingCopy}
                end;
            {error, _} = Err ->
                Err;
            Other ->
                {error, Other}
        end
    catch
        Class:Reason -> {error, {Class, Reason}}
    end;
probeRepo(_) ->
    {error, invalidRoot}.

%%--------------------------------------------------------------------
%% @doc
%% `svn status' 变更文件（仅索引白名单扩展名且磁盘上仍存在）。
%% @end
%%--------------------------------------------------------------------
-spec svnChangedFiles(file:filename()) -> [string()].
svnChangedFiles(Root) ->
    [Path || {_, Path} <- svnStatusMap(Root)].

%%--------------------------------------------------------------------
%% @doc
%% 返回 `[{Status, RelPath}]'（Status 如 `"M"'/`"?"'/`"A"'）。
%% @end
%%--------------------------------------------------------------------
-spec svnStatusMap(file:filename()) -> [{string(), string()}].
svnStatusMap(Root) when is_list(Root); is_binary(Root) ->
    R = unicode:characters_to_list(Root),
    case runSvn(R, ["status"]) of
        {ok, Output} ->
            Lines = [L || L <- string:split(Output, "\n", all),
                          string:trim(L) =/= ""],
            Parsed = lists:filtermap(
                fun(L) ->
                    case parseSvnStatusLine(L) of
                        undefined -> false;
                        P -> {true, P}
                    end
                end, Lines),
            lists:filter(fun({_S, P}) -> indexableRel(R, P) end, Parsed);
        _ -> []
    end;
svnStatusMap(_) -> [].

%%--------------------------------------------------------------------
%% @doc
%% 与 {@link alGitIndex:incrementalIndex/1} 对称：汇总 svn status 后触发
%% Rust 增量索引（hash 跳过未变文件）。
%% @end
%%--------------------------------------------------------------------
-spec incrementalIndex(file:filename()) -> {ok, map()} | {error, term()}.
incrementalIndex(Root) ->
    R = unicode:characters_to_list(Root),
    Status = svnStatusMap(R),
    ChangedCount = length(Status),
    try
        case alCoreClient:index(R) of
            {ok, M} ->
                {ok, #{
                    root => R,
                    backend => svn,
                    svnRepo => isSvnRepo(R),
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
%% 返回自 `Since' 后被 svn 提交修改过的文件集合（去重）。
%% `Since' 可为相对时间（"2 weeks ago"）或绝对日期（"2026-07-01" / "{2026-07-01}"）。
%% 仅返回通过索引白名单的文件。限最近 500 条 log。
%% @end
%%--------------------------------------------------------------------
-spec filesModifiedSince(file:filename(), iodata()) -> [string()].
filesModifiedSince(Root, Since) ->
    R = unicode:characters_to_list(Root),
    Start = parseSinceForSvn(Since),
    Args = ["log", "-v", "-l", "500", "-r", Start ++ ":HEAD"],
    case runSvn(R, Args) of
        {ok, Output} ->
            Paths = extractChangedPaths(Output),
            lists:usort([normalizeRel(P) || P <- Paths, indexableRel(R, normalizeRel(P))]);
        _ ->
            []
    end.

%%--------------------------------------------------------------------
%% @doc
%% 返回指定作者提交过的文件集合（去重）。作者名子串匹配（大小写不敏感）。
%% @end
%%--------------------------------------------------------------------
-spec filesByAuthor(file:filename(), iodata()) -> [string()].
filesByAuthor(Root, Author) ->
    R = unicode:characters_to_list(Root),
    AuthorLower = string:lowercase(unicode:characters_to_list(Author)),
    case runSvn(R, ["log", "-v", "-l", "500"]) of
        {ok, Output} ->
            Entries = parseSvnLogVerbose(Output),
            Files = lists:flatmap(
                fun(#{author := A, files := Fs}) ->
                        AList = unicode:characters_to_list(A),
                        case string:find(string:lowercase(AList), AuthorLower) of
                            nomatch -> [];
                            _ -> [normalizeRel(F) || F <- Fs]
                        end;
                   (_) ->
                        []
                end, Entries),
            lists:usort([P || P <- Files, indexableRel(R, P)]);
        _ ->
            []
    end.

%%--------------------------------------------------------------------
%% @doc
%% 按工作区状态过滤文件。`Statuses' 取值
%% `modified | added | untracked | deleted | renamed'（svn 的 R=Replaced）。
%% @end
%%--------------------------------------------------------------------
-spec filesByVcsStatus(file:filename(), term()) -> [string()].
filesByVcsStatus(Root, Statuses) ->
    NormStatuses = [normalizeStatus(S) || S <- ensureListVcs(Statuses)],
    StatusMap = svnStatusMap(Root),
    [normalizeRel(P) || {S, P} <- StatusMap,
                        lists:any(fun(NS) -> statusMatches(NS, S) end, NormStatuses)].

%%--------------------------------------------------------------------
%% @doc
%% 组合 VCS 文件过滤（与 {@link alGitIndex:vcsFileFilter/1} 对称）。
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
%% @doc
%% 把 Git 风格 since / 绝对日期 转成 svn `-r` 起始：`{YYYY-MM-DD}'。
%% @end
%%--------------------------------------------------------------------
-spec parseSinceForSvn(iodata()) -> string().
parseSinceForSvn(Since) ->
    S = string:trim(unicode:characters_to_list(Since)),
    case S of
        [${ | _] ->
            S;
        _ ->
            case re:run(S, "^(\\d{4}-\\d{2}-\\d{2})", [{capture, all_but_first, list}]) of
                {match, [D]} ->
                    "{" ++ D ++ "}";
                nomatch ->
                    case parseRelativeDays(S) of
                        {ok, Days} -> formatDateForSvn(Days);
                        error -> formatDateForSvn(?DefaultRecentDays)
                    end
            end
    end.

%% svn status 第一列 → 统一状态名。
statusMatches(modified, [C | _]) -> C =:= $M;
statusMatches(added, [C | _]) -> C =:= $A;
statusMatches(untracked, [$? | _]) -> true;
statusMatches(deleted, [C | _]) -> C =:= $D orelse C =:= $!;
statusMatches(renamed, [C | _]) -> C =:= $R;  %% svn Replaced
statusMatches(_, _) -> false.

normalizeStatus(S) when is_atom(S) -> S;
normalizeStatus(S) when is_binary(S) ->
    try binary_to_existing_atom(S, utf8) catch _:_ -> unknown end;
normalizeStatus(S) when is_list(S) ->
    try list_to_existing_atom(S) catch _:_ -> unknown end;
normalizeStatus(_) -> unknown.

ensureListVcs([]) -> [];
ensureListVcs(L) when is_list(L), is_integer(hd(L)) -> [L];
ensureListVcs(L) when is_list(L) -> L;
ensureListVcs(B) when is_binary(B) -> [B];
ensureListVcs(A) when is_atom(A) -> [A];
ensureListVcs(undefined) -> [];
ensureListVcs(_) -> [].

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

normalizeRel(P) when is_binary(P) ->
    alGitIndex:normalizePath(unicode:characters_to_list(P));
normalizeRel(P) ->
    alGitIndex:normalizePath(P).

parseRelativeDays(S) ->
    Lower = string:lowercase(string:trim(S)),
    case re:run(Lower, "^(\\d+)\\s+(day|days|week|weeks|month|months)\\s+ago$",
                [{capture, all_but_first, list}]) of
        {match, [NStr, Unit]} ->
            N = list_to_integer(NStr),
            Mult = case Unit of
                "day" ++ _ -> 1;
                "week" ++ _ -> 7;
                "month" ++ _ -> 30;
                _ -> 1
            end,
            {ok, max(1, N * Mult)};
        nomatch ->
            error
    end.

%% svn status 行：前 8 列为固定宽度状态区，其后为路径（含 `A  +` 带历史）。
parseSvnStatusLine(Line0) ->
    Line = string:trim(Line0, trailing),
    case Line of
        "" -> undefined;
        "Performing status" ++ _ -> undefined;
        _ ->
            case length(Line) >= 9 of
                true ->
                    {StatusChars, Rest} = lists:split(8, Line),
                    Path = string:trim(Rest),
                    case Path of
                        "" -> undefined;
                        _ -> {string:trim(StatusChars), Path}
                    end;
                false ->
                    case re:run(Line, "^([A-Z?!~C]+)\\s+(.+)$",
                                [{capture, all_but_first, list}, unicode]) of
                        {match, [Status, Path]} ->
                            {string:trim(Status), string:trim(Path)};
                        nomatch ->
                            undefined
                    end
            end
    end.

%% 与 alGitIndex 相同的扩展名白名单（磁盘上仍存在的文件）。
indexableRel(Root, RelPath) ->
    Abs = filename:join(Root, RelPath),
    case filename:extension(Abs) of
        <<>> -> false;
        Ext ->
            Norm = string:lowercase(unicode:characters_to_list(Ext)),
            Trim = case Norm of [$., C | Rest] -> [C | Rest]; _ -> Norm end,
            lists:member(Trim, defaultIndexExts()) andalso filelib:is_file(Abs)
    end.

defaultIndexExts() ->
    ["erl", "hrl", "cfg", "rs", "c", "h", "md", "txt", "json", "yaml", "yml",
     "toml", "sh", "py", "js", "ts", "tsx", "jsx"].

%%--------------------------------------------------------------------
%% @doc 最近 10 条提交。
%%--------------------------------------------------------------------
recentCommits() ->
    recentCommits(10).

%%--------------------------------------------------------------------
%% @doc
%% 返回最近 N 条 svn 提交记录。
%%
%% @param N 条数
%% @return {ok, [#{revision, author, date, subject}]} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
recentCommits(N) when is_integer(N), N > 0 ->
    case runSvn(projectRootList(), ["log", "-l", integer_to_list(N)]) of
        {ok, Out} -> {ok, parseSvnLog(Out)};
        Error -> Error
    end;
recentCommits(_) ->
    {error, invalidCount}.

%%--------------------------------------------------------------------
%% @doc
%% 最近 N 条提交，且限制在最近 Days 天内（`svn log -r {DATE}:HEAD`）。
%% Days=1 约等于「昨天至今」。
%% @end
%%--------------------------------------------------------------------
recentCommits(N, Days) when is_integer(N), N > 0, is_integer(Days), Days > 0 ->
    Since = formatDateForSvn(Days),
    RevRange = Since ++ ":HEAD",
    case runSvn(projectRootList(),
                ["log", "-l", integer_to_list(N), "-r", RevRange]) of
        {ok, Out} -> {ok, parseSvnLog(Out)};
        Error -> Error
    end;
recentCommits(_, _) ->
    {error, invalidCount}.

%%--------------------------------------------------------------------
%% @doc
%% 按选项列提交。Opts：limit / days / grep|query（--search）/ withFiles（-v）。
%% @end
%%--------------------------------------------------------------------
-spec listCommits(map()) -> {ok, [map()]} | {error, term()}.
listCommits(Opts) when is_map(Opts) ->
    Args = buildLogArgs(Opts),
    case runSvn(projectRootList(), Args) of
        {ok, Out} ->
            Commits = case maps:get(withFiles, Opts, false) =:= true of
                true -> parseSvnLogVerbose(Out);
                false -> parseSvnLog(Out)
            end,
            {ok, Commits};
        Error ->
            Error
    end;
listCommits(_) ->
    {error, invalidOpts}.

%%--------------------------------------------------------------------
%% @doc 按日志关键字搜索（svn log --search）。Opts 必含 grep/query。
%% @end
%%--------------------------------------------------------------------
-spec searchCommits(map()) -> {ok, [map()]} | {error, term()}.
searchCommits(Opts) when is_map(Opts) ->
    Grep = maps:get(grep, Opts, maps:get(query, Opts, maps:get(<<"grep">>, Opts,
                    maps:get(<<"query">>, Opts, undefined)))),
    case Grep of
        undefined -> {error, missingGrep};
        <<>> -> {error, missingGrep};
        "" -> {error, missingGrep};
        Q -> listCommits(Opts#{grep => Q})
    end;
searchCommits(_) ->
    {error, invalidOpts}.

%% 构造 svn log 参数。
buildLogArgs(Opts) when is_map(Opts) ->
    Limit = case maps:get(limit, Opts, maps:get(count, Opts, 20)) of
        N when is_integer(N), N > 0 -> min(N, 200);
        _ -> 20
    end,
    Base0 = ["log", "-l", integer_to_list(Limit)],
    Base1 = case maps:get(withFiles, Opts, false) =:= true of
        true -> Base0 ++ ["-v"];
        false -> Base0
    end,
    Base2 = case maps:get(days, Opts, undefined) of
        Days when is_integer(Days), Days > 0 ->
            Base1 ++ ["-r", formatDateForSvn(Days) ++ ":HEAD"];
        _ -> Base1
    end,
    Grep = maps:get(grep, Opts, maps:get(query, Opts, undefined)),
    case Grep of
        undefined -> Base2;
        <<>> -> Base2;
        "" -> Base2;
        Q when is_binary(Q) -> Base2 ++ ["--search=" ++ unicode:characters_to_list(Q)];
        Q when is_list(Q) -> Base2 ++ ["--search=" ++ Q];
        Q -> Base2 ++ ["--search=" ++ lists:flatten(io_lib:format("~p", [Q]))]
    end.

%%--------------------------------------------------------------------
%% @doc
%% 返回某次 svn 提交修改的文件列表。
%%
%% @param Ref revision（`r123' 或 `123'）
%% @return {ok, [string()]} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
commitFiles(Ref) ->
    Rev = parseRevision(Ref),
    case runSvn(projectRootList(), ["log", "-v", "-r", Rev]) of
        {ok, Out} ->
            {ok, extractChangedPaths(Out)};
        Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% @doc
%% 返回某次 svn 提交的完整信息：元数据 + 文件列表 + patch。
%%
%% @param Ref revision
%% @return {ok, #{revision, author, date, subject, files, patch}} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
commitDiff(Ref) ->
    Rev = parseRevision(Ref),
    %% 先拿元数据 + 文件列表
    case runSvn(projectRootList(), ["log", "-v", "-r", Rev]) of
        {ok, LogOut} ->
            Commits = parseSvnLogVerbose(LogOut),
            Meta = case Commits of
                [C | _] -> C;
                [] -> #{revision => Rev, author => <<>>, date => <<>>, subject => <<>>, files => []}
            end,
            %% 再拿 diff
            case runSvn(projectRootList(), ["diff", "-c", Rev]) of
                {ok, DiffOut} ->
                    Patch = trimPatch(DiffOut),
                    {ok, Meta#{patch => Patch}};
                _ ->
                    {ok, Meta#{patch => <<>>}}
            end;
        Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% @doc 默认 14 天内的变更文件（projectRoot）。
%%--------------------------------------------------------------------
recentFiles() ->
    recentFiles(projectRootList(), ?DefaultRecentDays).

%%--------------------------------------------------------------------
%% @doc 指定根目录默认 14 天。
%%--------------------------------------------------------------------
recentFiles(Root) ->
    recentFiles(Root, ?DefaultRecentDays).

%%--------------------------------------------------------------------
%% @doc
%% 返回指定根目录最近 Days 天内 svn 提交涉及的文件集合（ordset）。
%% 用 `svn log -v -r {DATE}:{HEAD}' 按日期范围查询。
%%
%% @param Root 工作副本根目录
%% @param Days 回溯天数
%% @return ordsets:ordset(string())
%% @end
%%--------------------------------------------------------------------
recentFiles(Root, Days) when is_integer(Days), Days > 0 ->
    R = unicode:characters_to_list(Root),
    Since = formatDateForSvn(Days),
    RevRange = Since ++ ":" ++ "HEAD",
    case runSvn(R, ["log", "-v", "-r", RevRange]) of
        {ok, Out} ->
            Paths = extractChangedPaths(Out),
            ordsets:from_list([alGitIndex:normalizePath(P) || P <- Paths]);
        _ ->
            ordsets:new()
    end;
recentFiles(_, _) ->
    ordsets:new().

%%%===================================================================
%%% 纯辅助函数（可测）
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 解析 `svn log' 输出为提交记录列表。
%% 每个条目格式：
%% ```
%% ------------------------------------------------------------------------
%% r123 | author | date | N line(s)
%% subject line 1
%% subject line 2
%% ------------------------------------------------------------------------
%% '''
%% @end
%%--------------------------------------------------------------------
parseSvnLog(Out) ->
    Blocks = splitSvnLogBlocks(Out),
    [parseSvnLogBlock(B) || B <- Blocks, B =/= []].

%%--------------------------------------------------------------------
%% @doc
%% 解析 `svn log -v' 输出（带 Changed paths），每个条目含 files 字段。
%% @end
%%--------------------------------------------------------------------
parseSvnLogVerbose(Out) ->
    Blocks = splitSvnLogBlocks(Out),
    [parseSvnLogBlockVerbose(B) || B <- Blocks, B =/= []].

%%--------------------------------------------------------------------
%% @doc
%% 规范化 revision 引用：`r123' → `123'，`123' → `123'，binary/list 通用。
%% @end
%%--------------------------------------------------------------------
parseRevision(Ref) when is_binary(Ref) ->
    parseRevision(unicode:characters_to_list(Ref));
parseRevision(Ref) when is_list(Ref) ->
    case Ref of
        [] -> "HEAD";
        [$r | Rest] -> string:trim(Rest);
        _ -> string:trim(Ref)
    end;
parseRevision(Ref) when is_integer(Ref) ->
    integer_to_list(Ref);
parseRevision(_) ->
    "HEAD".

%%--------------------------------------------------------------------
%% @doc
%% 生成 svn 日期范围起始字符串：`{YYYY-MM-DD}'。
%% @param Days 回溯天数
%% @return string()
%% @end
%%--------------------------------------------------------------------
formatDateForSvn(Days) ->
    Now = calendar:local_time(),
    {{Y, M, D}, _} = calendar:gregorian_seconds_to_datetime(
                        calendar:datetime_to_gregorian_seconds(Now) - Days * 86400),
    lists:flatten(io_lib:format("{~4..0B-~2..0B-~2..0B}", [Y, M, D])).

%%%===================================================================
%%% Internal: svn log 解析
%%%===================================================================

%% 按 `---...---' 分隔行拆分 svn log 输出为块。
splitSvnLogBlocks(Out) ->
    Lines = string:split(Out, "\n", all),
    splitBySeparator(Lines, []).

splitBySeparator([], Acc) ->
    case [L || L <- lists:reverse(Acc), L =/= ""] of
        [] -> [];
        Block -> [Block]
    end;
splitBySeparator([Line | Rest], Acc) ->
    Trimmed = string:trim(Line),
    case isSeparatorLine(Trimmed) of
        true ->
            Block = [L || L <- lists:reverse(Acc), L =/= ""],
            Blocks = case Block of
                [] -> [];
                _ -> [Block]
            end,
            Blocks ++ splitBySeparator(Rest, []);
        false ->
            splitBySeparator(Rest, [Trimmed | Acc])
    end.

isSeparatorLine(Line) ->
    Length = length(Line),
    Length >= 10 andalso lists:all(fun(C) -> C =:= $- end, Line).

%% 解析单个 svn log 块（无 -v）。
parseSvnLogBlock(Lines) when is_list(Lines) ->
    case Lines of
        [] -> #{revision => <<>>, author => <<>>, date => <<>>, subject => <<>>};
        [Header | MsgLines] ->
            Meta = parseSvnLogHeader(Header),
            Subject = string:trim(string:join(MsgLines, "\n")),
            Meta#{subject => unicode:characters_to_binary(Subject)}
    end.

%% 解析带 Changed paths 的块（-v）。
parseSvnLogBlockVerbose(Lines) when is_list(Lines) ->
    case Lines of
        [] -> #{revision => <<>>, author => <<>>, date => <<>>, subject => <<>>, files => []};
        [Header | Rest] ->
            Meta = parseSvnLogHeader(Header),
            {Files, MsgLines} = extractChangedAndMsg(Rest),
            Meta#{files => Files, subject => unicode:characters_to_binary(string:join(MsgLines, "\n"))}
    end.

%% 解析 header 行：`r123 | author | date | N line(s)'
parseSvnLogHeader(Header) ->
    Parts = string:split(Header, "|", all),
    case Parts of
        [Rev, Author, Date | _] ->
            #{revision => trimBin(Rev), author => trimBin(Author), date => trimBin(Date)};
        [Rev | _] ->
            #{revision => trimBin(Rev), author => <<>>, date => <<>>};
        _ ->
            #{revision => <<>>, author => <<>>, date => <<>>}
    end.

%% 从 -v log 块的剩余行里提取 Changed paths 和 message。
extractChangedAndMsg(Lines) ->
    case Lines of
        ["Changed paths:" | PathLines] ->
            %% 路径行格式：`   M /trunk/src/foo.erl'
            {Paths, MsgLines} = lists:splitwith(
                fun(L) -> isPathLine(L) end, PathLines),
            Files = [extractPathFromLine(L) || L <- Paths],
            {Files, [string:trim(L) || L <- MsgLines, string:trim(L) =/= ""]};
        MsgOnly ->
            {[], [string:trim(L) || L <- MsgOnly, string:trim(L) =/= ""]}
    end.

%% 路径行：状态字母（1-2 大写字母）+ 以 / 开头的路径。
%% 收紧判断避免 commit message（如 "add impact analysis"）被误判。
isPathLine(Line) ->
    case string:trim(Line) of
        "" -> false;
        Trimmed ->
            case string:split(Trimmed, " ", leading) of
                [Status, Path] when length(Status) =< 2 ->
                    IsUpper = lists:all(fun(C) -> C >= $A andalso C =< $Z end, Status),
                    IsPath = case Path of
                        [$/ | _] -> true;
                        _ -> false
                    end,
                    IsUpper andalso IsPath;
                _ ->
                    false
            end
    end.

%% 从路径行提取路径：`M /trunk/src/foo.erl' → `src/foo.erl'（去 trunk/ 前缀）
extractPathFromLine(Line) ->
    Trimmed = string:trim(Line),
    case string:split(Trimmed, " ", leading) of
        [_Status, Path] -> stripSvnPrefix(Path);
        _ -> Trimmed
    end.

%% 去除 svn 仓库路径前缀：trunk/, branches/x/, tags/x/
%% 用纯 string 操作避免 re:run 的选项兼容性问题。
stripSvnPrefix(Path) ->
    Parts = string:split(Path, "/", all),
    stripFromBase(Parts).

stripFromBase([]) -> [];
stripFromBase([Base | Rest]) when Base =:= "trunk" ->
    string:join(Rest, "/");
stripFromBase([Base | Rest]) when Base =:= "branches" orelse Base =:= "tags" ->
    %% branches/x/... 或 tags/x/... → 跳过子目录
    case Rest of
        [_SubDir | Rest2] -> string:join(Rest2, "/");
        _ -> string:join(Rest, "/")
    end;
stripFromBase([_ | Rest]) ->
    stripFromBase(Rest).

%% 从 svn log -v 输出里提取所有 Changed paths（跨多个条目）。
extractChangedPaths(Out) ->
    Lines = [string:trim(L) || L <- string:split(Out, "\n", all)],
    [extractPathFromLine(L) || L <- Lines, isPathLine(L)].

%%%===================================================================
%%% Internal: svn 命令执行
%%%===================================================================

%% 执行 svn 命令，复用 alGitIndex 的端口模式。
runSvn(Root, Args) ->
    case os:find_executable("svn") of
        false ->
            {error, svnNotFound};
        Svn ->
            PortOpts = [exit_status, use_stdio, stderr_to_stdout, binary,
                        {cd, Root}, {args, Args}],
            try open_port({spawn_executable, Svn}, PortOpts) of
                Port when is_port(Port) ->
                    collectSvnOutput(Port, [])
            catch
                error:Reason -> {error, Reason}
            end
    end.

collectSvnOutput(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collectSvnOutput(Port, [Data | Acc]);
        {Port, {exit_status, Code}} ->
            Bin = iolist_to_binary(lists:reverse(Acc)),
            case decodeCmdOutput(Bin) of
                {ok, Out} when Code =:= 0 -> {ok, Out};
                {ok, Out} -> {error, {svnExit, Code, Out}};
                {error, Reason} -> {error, Reason}
            end
    after 30000 ->
        safeClosePort(Port),
        flushPortMessages(Port),
        Bin = iolist_to_binary(lists:reverse(Acc)),
        case decodeCmdOutput(Bin) of
            {ok, Out} -> {ok, Out};  %% 超时但有输出时尽量返回
            {error, _} -> {error, timeout}
        end
    end.

%% 同步清空 Port 邮箱中残留的 {Port,...} 消息（超时强杀后兜底）。
%% 与 alGitIndex 对称，避免下次 open_port 复用句柄时被旧消息污染。
flushPortMessages(Port) ->
    receive
        {Port, _} -> flushPortMessages(Port)
    after 0 -> ok
    end.

%% Windows 中文环境 svn 常输出本地编码（GBK）；UTF-8 解码失败时把剩余
%% 字节按 latin1 拼上，保证 ASCII 字段（URL:/r123|）仍可解析。
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

safeClosePort(Port) ->
    try port_close(Port) catch _:_ -> ok end.

%% 原样转为 UTF-8 binary，不做长度截断。
trimPatch(PatchStr) when is_binary(PatchStr) ->
    PatchStr;
trimPatch(PatchStr) ->
    case unicode:characters_to_binary(PatchStr) of
        Bin when is_binary(Bin) -> Bin;
        {error, Good, _} -> unicode:characters_to_binary(Good);
        {incomplete, Good, _} -> unicode:characters_to_binary(Good);
        _ -> <<>>
    end.

projectRootList() ->
    try unicode:characters_to_list(alConfig:projectRoot())
    catch _:_ -> "." end.

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
