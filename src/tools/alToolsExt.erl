%%%-------------------------------------------------------------------
%% @doc 扩展的文件系统、beam、计划与委派工具。
%% @end
%%%-------------------------------------------------------------------

-module(alToolsExt).

-export([
    readFile/1,
    readFilePage/1,
    listFiles/1,
    writeFile/1,
    getBeamAbstract/1,
    moduleExports/1,
    getModuleTypes/1,
    getSymbolSource/1,
    formatCode/1,
    runEunit/1,
    runDialyzer/1,
    runTestsForPatch/1,
    planSet/2,
    planUpdate/3,
    planGet/1,
    planClear/1,
    delegateTo/1,
    useSkill/1,
    fetchUrl/1,
    fetchUrlPage/1,
    runProgram/3,
    sourceSnippet/1,
    enrichLocMap/2,
    enrichSearchHits/2
]).

%% Test helpers
-export([isSubpath/2, normalizeAbs/1, resolveAllowedPath/1, resolveReadablePath/1]).
-export([validateFetchUrl/1, isInternalHost/1]).
-export([redirectTarget/2, resolveRedirectUrl/2, parsePageCursor/1, contentTypeFormat/1]).
-export([findFunctionBlock/3, extractFunctionFromSourceFile/4, extractFunctionFromSourceFile/5]).

-define(DefaultListMaxEntries, 5000).
%% fetchUrl 默认正文上限 50KB，默认超时 15s。
-define(DefaultFetchMaxBytes, 51200).
-define(DefaultFetchTimeoutMs, 15000).
%% fetchUrlPage：首次抓取正文上限 512KB（提取后缓存），默认每页 24KB。
-define(PageFetchMaxBytes, 524288).
-define(DefaultPageChunkBytes, 24000).
-define(MaxPageChunkBytes, 48000).
-define(MinPageChunkBytes, 2000).
-define(PageCacheTable, alFetchPageCache).
-define(PageCacheMax, 32).
-define(PageCacheTtlMs, 600000).
-define(HostThrottleTable, alFetchHostThrottle).
-define(DefaultFetchChromeUa,
    <<"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36">>).

%%--------------------------------------------------------------------
%% @doc
%% 读取项目文件内容，超过 maxBytes 时返回截断结果，文件不存在时
%% 返回建议路径。路径必须在允许的项目根目录下。
%%
%% @param Args 含 path 和可选 maxBytes 的 map
%% @return `{ok, #{path, content, truncated, ...}}' 或 `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
readFile(#{path := Path, maxBytes := MaxBytes} = Args) ->
    case resolveReadablePath(Path) of
        {ok, Abs} ->
            case resolveLineRange(Args) of
                skip ->
                    readFileFromStart(Abs, MaxBytes, Args);
                {ok, Start, End} ->
                    readFileLineRange(Abs, Start, End, MaxBytes, Args);
                {error, badLineRange} ->
                    {error, #{
                        reason => badLineRange,
                        hint => <<"startLine/endLine/lineCount 无效；startLine>=1，endLine>=startLine"/utf8>>
                    }};
                {error, {badLineRange, Detail}} when is_map(Detail) ->
                    {error, Detail#{reason => badLineRange}}
            end;
        {error, pathNotAllowed} ->
            maybeRetryRead(Args, Path, Path);
        {error, _} = E ->
            E
    end;
%% 缺省 maxBytes 时填入默认值后递归调用。
readFile(#{path := _} = Args) ->
    readFile(Args#{maxBytes => defaultMaxBytes()});
%% 缺省 path 时补默认空值后递归调用。
readFile(Args) ->
    readFile(maps:put(path, maps:get(path, Args, <<>>), Args)).

%%--------------------------------------------------------------------
%% @doc
%% 分页读取大文件：用 cursor 续读，避免模型反复猜 startLine/endLine。
%% cursor 为上次返回的 nextCursor（binary，形如 "250" 表示已读到第 250 行）。
%% 首次调用传 null 或省略 cursor，从第 1 行开始读。
%%
%% @param Args 含 path、cursor(可选)、pageSize(可选，默认 200)
%% @return `{ok, #{path, content, nextCursor, hasMore, totalLines, pageSize, startLine, endLine}}'
%% @end
%%--------------------------------------------------------------------
readFilePage(#{path := Path} = Args) ->
    PageSize = case maps:get(pageSize, Args, maps:get(<<"pageSize">>, Args, undefined)) of
        N when is_integer(N), N > 0, N =< 1000 -> N;
        _ -> 200
    end,
    Cursor = maps:get(cursor, Args, maps:get(<<"cursor">>, Args, null)),
    StartLine = case parseCursor(Cursor) of
        {ok, Line} -> Line + 1;  %% cursor 表示已读到的最后一行，续读从下一行开始
        empty -> 1  %% 首次调用，从第 1 行开始
    end,
    EndLine = StartLine + PageSize - 1,
    case resolveReadablePath(Path) of
        {ok, Abs} ->
            case file:open(Abs, [read, binary, raw]) of
                {ok, Io} ->
                    try
                        {LinesRev, Total, _Truncated} =
                            readLineRangeLoop(Io, 1, StartLine, EndLine, defaultMaxBytes(), 0, [], false),
                        Lines = lists:reverse(LinesRev),
                        ActualEnd = case Lines of
                            [] -> StartLine;
                            _ -> StartLine + length(Lines) - 1
                        end,
                        HasMore = ActualEnd < Total,
                        NextCursor = case HasMore of
                            true -> integer_to_binary(ActualEnd);
                            false -> null
                        end,
                        Content = iolist_to_binary([<<L/binary, "\n">> || L <- Lines]),
                        {ok, #{
                            path => Abs,
                            content => Content,
                            startLine => StartLine,
                            endLine => ActualEnd,
                            pageSize => PageSize,
                            totalLines => Total,
                            hasMore => HasMore,
                            nextCursor => NextCursor
                        }}
                    after
                        file:close(Io)
                    end;
                {error, enoent} ->
                    {error, #{reason => enoent, path => Path}};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, pathNotAllowed} ->
            {error, #{reason => pathNotAllowed, path => Path}};
        {error, _} = E ->
            E
    end;
readFilePage(Args) ->
    readFilePage(maps:put(path, maps:get(path, Args, <<>>), Args)).

%% 解析 cursor：null/空/<<"null">> 返回 empty；否则解析为整数。
parseCursor(null) -> empty;
parseCursor(<<"null">>) -> empty;
parseCursor(<<>>) -> empty;
parseCursor(undefined) -> empty;
parseCursor(Bin) when is_binary(Bin) ->
    case string:trim(Bin) of
        <<>> -> empty;
        Trimmed ->
            try {ok, binary_to_integer(Trimmed)}
            catch _:_ -> empty
            end
    end;
parseCursor(Int) when is_integer(Int), Int >= 0 -> {ok, Int};
parseCursor(_) -> empty.

%% 从文件头读取（原语义）；大文件只返回前 maxBytes。
%% 截断时同时返回 totalBytes 与 totalLines，让上层 paginationHint 能精确推断续读区间。
readFileFromStart(Abs, MaxBytes, Args) ->
    case file:read_file(Abs) of
        {ok, Bin} when byte_size(Bin) =< MaxBytes ->
            {ok, #{path => Abs, content => Bin, truncated => false}};
        {ok, Bin} ->
            %% 截断时计算总行数，供 paginationHint 推断 startLine/endLine
            TotalLines = binary:matches(Bin, <<"\n">>),
            TotalLineCount = case TotalLines of
                [] -> 1;
                _ -> length(TotalLines) + 1
            end,
            {ok, #{
                path => Abs,
                content => utf8SafeTruncate(Bin, MaxBytes),
                truncated => true,
                totalBytes => byte_size(Bin),
                totalLines => TotalLineCount,
                hint => <<"大文件请用 startLine/endLine 读指定行区间，勿只靠增大 maxBytes"/utf8>>
            }};
        {error, enoent} ->
            maybeRetryRead(Args, maps:get(path, Args, Abs), Abs);
        {error, Reason} ->
            {error, Reason}
    end.

%% 按行区间读取：适合 40KB+ 源文件读 420–460 行等场景。
readFileLineRange(Abs, Start, End, MaxBytes, Args) ->
    case file:open(Abs, [read, binary, raw]) of
        {ok, Io} ->
            try
                {LinesRev, Total, Truncated} =
                    readLineRangeLoop(Io, 1, Start, End, MaxBytes, 0, [], false),
                case Start > Total andalso Total > 0 of
                    true ->
                        {error, #{
                            reason => lineOutOfRange,
                            path => Abs,
                            startLine => Start,
                            endLine => End,
                            totalLines => Total,
                            hint => iolist_to_binary(io_lib:format(
                                "startLine=~p 超出文件总行数 ~p；请用 gotoDef/moduleSymbols 取真实行号后再读",
                                [Start, Total]))
                        }};
                    false ->
                        Lines = lists:reverse(LinesRev),
                        Content = iolist_to_binary([<<L/binary, "\n">> || L <- Lines]),
                        ActualEnd = case Lines of
                            [] -> Start;
                            _ -> Start + length(Lines) - 1
                        end,
                        Clamped = End > Total andalso Total > 0,
                        {ok, #{
                            path => Abs,
                            content => Content,
                            startLine => Start,
                            endLine => ActualEnd,
                            lineCount => length(Lines),
                            totalLines => Total,
                            truncated => Truncated,
                            clamped => Clamped,
                            mode => lineRange
                        }}
                end
            catch
                throw:{readLinesFailed, Reason} ->
                    {error, Reason}
            after
                file:close(Io)
            end;
        {error, enoent} ->
            maybeRetryRead(Args, maps:get(path, Args, Abs), Abs);
        {error, Reason} ->
            {error, Reason}
    end.

readLineRangeLoop(Io, LineNo, Start, End, MaxBytes, AccBytes, Acc, Truncated) ->
    case file:read_line(Io) of
        eof ->
            {Acc, max(0, LineNo - 1), Truncated};
        {ok, LineBin0} ->
            LineBin = trimLineEnding(LineBin0),
            LineSize = byte_size(LineBin) + 1,
            InRange = LineNo >= Start andalso LineNo =< End,
            case InRange of
                true when not Truncated ->
                    case AccBytes + LineSize =< MaxBytes of
                        true ->
                            readLineRangeLoop(Io, LineNo + 1, Start, End,
                                             MaxBytes, AccBytes + LineSize, [LineBin | Acc], false);
                        false ->
                            readLineRangeLoop(Io, LineNo + 1, Start, End,
                                             MaxBytes, AccBytes, Acc, true)
                    end;
                _ ->
                    readLineRangeLoop(Io, LineNo + 1, Start, End,
                                     MaxBytes, AccBytes, Acc, Truncated)
            end;
        {error, Reason} ->
            throw({readLinesFailed, Reason})
    end.

trimLineEnding(Bin) ->
    case binary:match(Bin, <<"\r\n">>) of
        {Pos, _} -> binary:part(Bin, 0, Pos);
        nomatch ->
            case binary:match(Bin, <<"\n">>) of
                {Pos2, _} -> binary:part(Bin, 0, Pos2);
                nomatch -> Bin
            end
    end.

resolveLineRange(Args) ->
    Start = pickIntArg([startLine, start_line, <<"startLine">>, <<"start_line">>], Args),
    End = pickIntArg([endLine, end_line, <<"endLine">>, <<"end_line">>], Args),
    Count = pickIntArg([lineCount, line_count, <<"lineCount">>, <<"line_count">>], Args),
    MaxSpan = maxLineSpan(),
    case {Start, End, Count} of
        {undefined, undefined, undefined} ->
            skip;
        {S, undefined, undefined} when is_integer(S), S >= 1 ->
            {ok, S, S + defaultLineSpan() - 1};
        {S, E, undefined} when is_integer(S), is_integer(E), S >= 1, E >= S ->
            {ok, S, min(E, S + MaxSpan - 1)};
        {S, E, undefined} when is_integer(S), is_integer(E), S >= 1, E < S ->
            {error, {badLineRange, #{
                startLine => S,
                endLine => E,
                hint => iolist_to_binary(io_lib:format(
                    "endLine(~p) < startLine(~p)；请交换二者，或改用 startLine+lineCount",
                    [E, S]))
            }}};
        {S, undefined, C} when is_integer(S), is_integer(C), S >= 1, C >= 1 ->
            {ok, S, min(S + C - 1, S + MaxSpan - 1)};
        {undefined, E, undefined} when is_integer(E), E >= 1 ->
            S2 = max(1, E - defaultLineSpan() + 1),
            {ok, S2, E};
        _ ->
            {error, badLineRange}
    end.

pickIntArg(Keys, Args) ->
    pickIntArg(Keys, Args, undefined).

pickIntArg([], _Args, Default) ->
    Default;
pickIntArg([K | Rest], Args, Default) ->
    case maps:get(K, Args, undefined) of
        V when is_integer(V) -> V;
        V when is_binary(V) ->
            try binary_to_integer(V) of I -> I catch _:_ -> pickIntArg(Rest, Args, Default) end;
        V when is_list(V) ->
            try list_to_integer(V) of I -> I catch _:_ -> pickIntArg(Rest, Args, Default) end;
        _ ->
            pickIntArg(Rest, Args, Default)
    end.

defaultLineSpan() -> 80.
maxLineSpan() -> 250.

%%--------------------------------------------------------------------
%% 源码片段 enrichment：gotoDef / searchCode / findRefs 共用。
%% 对标 Cursor peek definition / grep -C：返回可直接引用的 source 字段。
%%--------------------------------------------------------------------
clampSnippetContext(N) when is_integer(N), N > 0 -> min(N, 10);
clampSnippetContext(_) -> 3.

sourceSnippet(Args) when is_map(Args) ->
    Context = clampSnippetContext(
        maps:get(context, Args, maps:get(<<"context">>, Args, 3))),
    File = snippetFileArg(Args),
    case {File, resolveSnippetRange(Args, Context)} of
        {undefined, _} ->
            {error, #{reason => missingPath}};
        {_, {error, _} = E} ->
            E;
        {Path, {ok, Start, End}} ->
            case readFile(#{path => Path, startLine => Start, endLine => End,
                           maxBytes => 96000}) of
                {ok, Range} ->
                    {ok, Range#{source => maps:get(content, Range)}};
                Err ->
                    Err
            end
    end.

enrichLocMap(Map, Opts) when is_map(Map) ->
    case includeSourceOpt(Opts) of
        false ->
            Map;
        true ->
            Args = locMapToSnippetArgs(Map, Opts),
            case sourceSnippet(Args) of
                {ok, Snip} ->
                    maps:merge(Map, #{
                        source => maps:get(source, Snip, maps:get(content, Snip)),
                        sourceStartLine => maps:get(startLine, Snip, undefined),
                        sourceEndLine => maps:get(endLine, Snip, undefined),
                        sourceLineCount => maps:get(lineCount, Snip, undefined),
                        sourceTruncated => maps:get(truncated, Snip, false)
                    });
                _ ->
                    Map
            end
    end.

enrichSearchHits(Hits, Opts) when is_list(Hits) ->
    [enrichSearchHit(H, Opts) || H <- Hits].

enrichSearchHit(H, Opts) when is_map(H) ->
    case includeSourceOpt(Opts) of
        false ->
            H;
        true ->
            case hitToSnippetArgs(H, Opts) of
                {ok, Args} ->
                    case sourceSnippet(Args) of
                        {ok, Snip} ->
                            H#{
                                sourcePreview => maps:get(source, Snip, maps:get(content, Snip)),
                                sourceStartLine => maps:get(startLine, Snip, undefined),
                                sourceEndLine => maps:get(endLine, Snip, undefined),
                                sourceLineCount => maps:get(lineCount, Snip, undefined)
                            };
                        _ ->
                            H
                    end;
                skip ->
                    H
            end
    end;
enrichSearchHit(H, _Opts) ->
    H.

includeSourceOpt(Opts) ->
    case maps:get(includeSource, Opts, maps:get(<<"includeSource">>, Opts, true)) of
        false -> false;
        _ -> true
    end.

snippetFileArg(Args) ->
    pickBinArg([path, file, <<"path">>, <<"file">>], Args).

locMapToSnippetArgs(Map, Opts) ->
    Context = clampSnippetContext(
        maps:get(context, Opts, maps:get(<<"context">>, Opts, 3))),
    Base = #{
        path => pickBinArg([file, path, <<"file">>, <<"path">>], Map),
        context => Context
    },
    maps:merge(Base, locRangeFields(Map)).

hitToSnippetArgs(H, Opts) ->
    File = pickBinArg([file, <<"file">>], H),
    case File of
        undefined ->
            skip;
        _ ->
            Context = clampSnippetContext(
                maps:get(context, Opts, maps:get(<<"context">>, Opts, 3))),
            case primaryFunctionRange(H) of
                {Start, End} when is_integer(Start), is_integer(End), Start >= 1 ->
                    {ok, #{path => File, startLine => Start, endLine => End, context => 0}};
                _ ->
                    Line = pickHitLine(H),
                    case Line of
                        L when is_integer(L), L >= 1 ->
                            {ok, #{path => File, line => L, context => Context}};
                        _ ->
                            skip
                    end
            end
    end.

primaryFunctionRange(H) ->
    Funs = pickList([functions, <<"functions">>], H, []),
    case [F || F <- Funs, is_map(F)] of
        [Fun | _] ->
            Start = pickIntFromMap([start_line, <<"start_line">>, line, <<"line">>], Fun),
            End = pickIntFromMap([end_line, <<"end_line">>, start_line, <<"start_line">>, line, <<"line">>], Fun),
            case Start of
                S when is_integer(S), S >= 1 ->
                    E = case End of
                        E0 when is_integer(E0), E0 >= S -> min(E0, S + maxLineSpan() - 1);
                        _ -> S + defaultLineSpan() - 1
                    end,
                    {S, E};
                _ ->
                    undefined
            end;
        _ ->
            undefined
    end.

pickHitLine(H) ->
    case pickIntFromMap([line, <<"line">>], H) of
        L when is_integer(L), L >= 1 ->
            L;
        _ ->
            Snips = pickList([snippets, <<"snippets">>], H, []),
            case [pickIntFromMap([line, <<"line">>], S) || S <- Snips, is_map(S)] of
                [SL | _] when is_integer(SL), SL >= 1 -> SL;
                _ -> undefined
            end
    end.

locRangeFields(Map) ->
    maps:filtermap(
        fun
            (startLine, V) -> {true, {startLine, V}};
            (endLine, V) -> {true, {endLine, V}};
            (line, V) -> {true, {line, V}};
            (<<"start_line">>, V) -> {true, {startLine, V}};
            (<<"end_line">>, V) -> {true, {endLine, V}};
            (<<"line">>, V) -> {true, {line, V}};
            (start_line, V) -> {true, {startLine, V}};
            (end_line, V) -> {true, {endLine, V}};
            (_, _) -> false
        end,
        Map).

resolveSnippetRange(Args, Context) ->
    Start0 = pickIntArg([startLine, start_line, <<"startLine">>, <<"start_line">>], Args),
    End0 = pickIntArg([endLine, end_line, <<"endLine">>, <<"end_line">>], Args),
    Line = pickIntArg([line, <<"line">>], Args),
    MaxSpan = maxLineSpan(),
    case {Start0, End0, Line} of
        {S, E, _} when is_integer(S), is_integer(E), S >= 1, E >= S ->
            {ok, S, min(E, S + MaxSpan - 1)};
        {S, undefined, _} when is_integer(S), S >= 1 ->
            {ok, S, S + defaultLineSpan() - 1};
        {undefined, E, _} when is_integer(E), E >= 1 ->
            S2 = max(1, E - defaultLineSpan() + 1),
            {ok, S2, E};
        {undefined, undefined, L} when is_integer(L), L >= 1 ->
            Ctx = clampSnippetContext(Context),
            {ok, max(1, L - Ctx), L + Ctx};
        _ ->
            {error, #{reason => noLineRange}}
    end.

pickBinArg(Keys, M) ->
    pickBinArg(Keys, M, undefined).

pickBinArg([], _M, Default) ->
    Default;
pickBinArg([K | Rest], M, Default) ->
    case maps:get(K, M, undefined) of
        V when is_binary(V) -> V;
        V when is_list(V) -> unicode:characters_to_binary(V);
        _ -> pickBinArg(Rest, M, Default)
    end.

pickList([], _M, Default) ->
    Default;
pickList([K | Rest], M, Default) ->
    case maps:get(K, M, undefined) of
        L when is_list(L) -> L;
        _ -> pickList(Rest, M, Default)
    end.

pickIntFromMap(Keys, M) ->
    pickIntArg(Keys, M).

%% 按字节限长截断二进制，保证不切断多字节 UTF-8 序列：
%% 截断点落在字符中间时回退到最近的字符边界。
utf8SafeTruncate(Bin, MaxBytes) when byte_size(Bin) =< MaxBytes ->
    Bin;
utf8SafeTruncate(Bin, MaxBytes) ->
    Part = binary:part(Bin, 0, MaxBytes),
    Sz = byte_size(Part),
    case binary:last(Part) < 128 of
        true ->
            Part;
        false ->
            Trailing = countTrailingContinuation(Part, Sz - 1, 0),
            case Trailing of
                0 ->
                    %% 末尾是孤立首字节（多字节序列被切断）→ 丢弃
                    binary:part(Part, 0, Sz - 1);
                _ ->
                    LeadPos = Sz - Trailing - 1,
                    case LeadPos >= 0 andalso
                         utf8RequiredLen(binary:at(Part, LeadPos)) =:= Trailing + 1 of
                        true ->
                            %% 完整多字节序列恰好收在截断点
                            Part;
                        false ->
                            %% 不完整序列：丢弃续字节串及前导首字节
                            KeepLen = max(0, Sz - Trailing - 1),
                            binary:part(Part, 0, KeepLen)
                    end
            end
    end.

%% 从末尾数连续续字节个数。
countTrailingContinuation(_Part, Pos, N) when Pos < 0 ->
    N;
countTrailingContinuation(Part, Pos, N) ->
    case binary:at(Part, Pos) band 2#11000000 of
        2#10000000 -> countTrailingContinuation(Part, Pos - 1, N + 1);
        _ -> N
    end.

%% UTF-8 首字节要求的序列总长度。
utf8RequiredLen(B) when B band 2#11110000 =:= 2#11110000 -> 4;
utf8RequiredLen(B) when B band 2#11100000 =:= 2#11100000 -> 3;
utf8RequiredLen(B) when B band 2#11000000 =:= 2#11000000 -> 2;
utf8RequiredLen(_) -> 1.

%% enoent / pathNotAllowed：用索引建议路径自动重试一次（防环 _retried）。
maybeRetryRead(Args, OriginalPath, FailedPath) ->
    Suggestions = suggestPaths(OriginalPath),
    case maps:get('_retried', Args, false) of
        true ->
            enoentError(FailedPath, Suggestions);
        false ->
            case firstDifferentSuggestion(Suggestions, OriginalPath) of
                undefined ->
                    enoentError(FailedPath, Suggestions);
                Suggested ->
                    case readFile(Args#{path => Suggested, '_retried' => true}) of
                        {ok, Ok} when is_map(Ok) ->
                            {ok, Ok#{
                                resolvedFrom => OriginalPath,
                                usedSuggestion => Suggested,
                                autoResolved => true
                            }};
                        {error, _} ->
                            enoentError(FailedPath, Suggestions)
                    end
            end
    end.

firstDifferentSuggestion([], _Original) ->
    undefined;
firstDifferentSuggestion([S | Rest], Original) ->
    case string:lowercase(toList(S)) =:= string:lowercase(toList(Original)) of
        true -> firstDifferentSuggestion(Rest, Original);
        false -> S
    end.

enoentError(FailedPath, Suggestions) ->
    {error, #{
        reason => enoent,
        path => FailedPath,
        suggestions => Suggestions,
        hint => <<"Path missing. Server may auto-resolve one indexed suggestion; "
                  "otherwise call resolveModule / searchCode — do not invent boot/... prefixes."/utf8>>
    }}.

%%--------------------------------------------------------------------
%% @doc
%% 列出指定目录下的文件条目，支持递归（wildcard）与非递归（list_dir）。
%% 默认跳过 indexIgnore（.git/_build 等），并限制 maxEntries（默认 500）。
%% 路径必须在允许的项目根目录下。
%%
%% @param Args 含 path 和可选 recursive/maxEntries 的 map
%% @return `{ok, #{path, entries, truncated, ...}}' 或 `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
listFiles(#{path := Path} = Args) ->
    Recursive = maps:get(recursive, Args, maps:get(<<"recursive">>, Args, false)),
    MaxEntries = pickIntArg([maxEntries, max_entries, <<"maxEntries">>, <<"max_entries">>],
                            Args, ?DefaultListMaxEntries),
    Glob = pickBinArg([glob, pattern, <<"glob">>, <<"pattern">>], Args),
    case Glob of
        undefined ->
            listFilesWithoutGlob(Path, Recursive, MaxEntries);
        GlobBin ->
            listFilesByGlob(Path, GlobBin, MaxEntries)
    end.

listFilesWithoutGlob(Path, Recursive, MaxEntries) ->
    case isProjectRootPath(Path) of
        true ->
            listProjectBrowse(Recursive, MaxEntries);
        false ->
            case resolveReadablePath(Path) of
                {ok, Abs} ->
                    listOneDir(Abs, Recursive, MaxEntries);
                {error, _} = E ->
                    E
            end
    end.

listFilesByGlob(Path, Glob, MaxEntries) ->
    Resolved = case isProjectRootPath(Path) of
        true -> {ok, normalizeAbs(alConfig:projectRoot())};
        false -> resolveReadablePath(Path)
    end,
    case Resolved of
        {error, _} = Err ->
            Err;
        {ok, AbsDir} ->
            Pattern = filename:join(AbsDir, toList(Glob)),
            Matches0 = filelib:wildcard(Pattern),
            Ignore = browseIgnoreNames(),
            Filtered = [M || M <- Matches0,
                             filelib:is_regular(M),
                             not isIgnoredPath(M, Ignore),
                             not isSensitiveBasename(M)],
            Truncated = length(Filtered) > MaxEntries,
            Kept = lists:sublist(Filtered, MaxEntries),
            Rel = [relativeToRoot(Entry) || Entry <- Kept],
            {ok, #{
                path => relativeToRoot(AbsDir),
                glob => Glob,
                entries => Rel,
                truncated => Truncated,
                count => length(Rel),
                originalCount => length(Filtered),
                browseMode => glob
            }}
    end.

%% path=. / "" / 项目根 → 浏览整个工程树
isProjectRootPath(Path) ->
    case string:trim(toList(Path)) of
        "" -> true;
        "." -> true;
        "./" -> true;
        ".\\" -> true;
        Other ->
            try normalizeAbs(Other) =:= normalizeAbs(alConfig:projectRoot())
            catch _:_ -> false
            end
    end.

listProjectBrowse(Recursive, MaxEntries) ->
    Root = normalizeAbs(alConfig:projectRoot()),
    Ignore = browseIgnoreNames(),
    Entries0 = case Recursive of
        true -> collectEntries(Root, true);
        false ->
            case file:list_dir(Root) of
                {ok, Names} -> [filename:join(Root, N) || N <- Names];
                {error, Reason} -> {error, Reason}
            end
    end,
    case Entries0 of
        {error, _} = E ->
            E;
        _ when is_list(Entries0) ->
            Filtered = [E || E <- Entries0,
                             not isIgnoredPath(E, Ignore),
                             not isSensitiveBasename(E)],
            Truncated = length(Filtered) > MaxEntries,
            Kept = lists:sublist(Filtered, MaxEntries),
            Rel = [relativeToRoot(E) || E <- Kept],
            PatchRoots = maps:get(allowedRoots, alConfig:get(patch, #{}),
                                  ["src", "config", "priv"]),
            {ok, #{
                path => <<".">>,
                projectRoot => unicode:characters_to_binary(Root),
                allowedRoots => [unicode:characters_to_binary(toList(A)) || A <- PatchRoots],
                browseMode => projectRoot,
                entries => Rel,
                truncated => Truncated,
                count => length(Rel),
                originalCount => length(Filtered)
            }}
    end.

%% 浏览忽略：权威来源 alConfig:indexIgnoreNames/0（core.indexIgnore → port ALI_INDEX_IGNORE）
browseIgnoreNames() ->
    alConfig:indexIgnoreNames().

listOneDir(Abs, Recursive, MaxEntries) ->
    Ignore = browseIgnoreNames(),
    case collectEntries(Abs, Recursive) of
        {error, _} = E ->
            E;
        Entries0 when is_list(Entries0) ->
            Filtered = [E || E <- Entries0,
                             not isIgnoredPath(E, Ignore),
                             not isSensitiveBasename(E)],
            Truncated = length(Filtered) > MaxEntries,
            Kept = lists:sublist(Filtered, MaxEntries),
            Rel = [relativeToRoot(E) || E <- Kept],
            {ok, #{
                path => relativeToRoot(Abs),
                entries => Rel,
                truncated => Truncated,
                count => length(Rel),
                originalCount => length(Filtered)
            }}
    end.

%% 收集目录条目：recursive 时优先 wildcard，空则手写遍历（Windows/旧 OTP 上 ** 常空）。
collectEntries(Abs, false) ->
    case file:list_dir(Abs) of
        {ok, Names} -> [filename:join(Abs, N) || N <- Names];
        {error, Reason} -> {error, Reason}
    end;
collectEntries(Abs, true) ->
    case filelib:wildcard(filename:join(Abs, "**/*")) of
        [] ->
            case filelib:is_dir(Abs) of
                true -> walkDir(Abs, []);
                false -> []
            end;
        Entries when is_list(Entries) ->
            Entries
    end.

walkDir(Dir, Acc) ->
    Ignore = browseIgnoreNames(),
    case file:list_dir(Dir) of
        {ok, Names} ->
            lists:foldl(fun(Name, A) ->
                %% 目录名命中忽略则整树跳过（避免 .svn/pristine 撑爆条目上限）
                case lists:member(string:lowercase(Name),
                                  [string:lowercase(toList(I)) || I <- Ignore]) of
                    true ->
                        A;
                    false ->
                        Path = filename:join(Dir, Name),
                        case filelib:is_dir(Path) of
                            true -> walkDir(Path, [Path | A]);
                            false -> [Path | A]
                        end
                end
            end, Acc, Names);
        {error, _} ->
            Acc
    end.

%%--------------------------------------------------------------------
%% @doc
%% 将内容写入项目文件（先 ensure_dir），成功后触发工具缓存失效。
%% 路径必须在允许的项目根目录下。
%%
%% @param Args 含 path 和 content 的 map
%% @return `{ok, #{path, bytes}}' 或 `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
writeFile(#{path := Path, content := Content}) ->
    case resolveAllowedPath(Path) of
        {ok, Abs} ->
            case filelib:ensure_dir(Abs) of
                ok ->
                    case file:write_file(Abs, toBinary(Content)) of
                        ok ->
                            alToolCache:invalidateForWrite(),
                            {ok, #{path => Abs, bytes => byte_size(toBinary(Content))}};
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, _} = E ->
            E
    end.

%%--------------------------------------------------------------------
%% @doc
%% 从 BEAM 文件中提取 abstract_code 形式（用于源码反查、符号提取）。
%% 支持传入 `#{module => M}' 或直接传入模块名。
%%
%% @param ModuleOrArgs 模块名或含 module 的 map
%% @return `{ok, #{module, path, forms}}' 或 `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
getBeamAbstract(#{module := Module}) ->
    getBeamAbstract(Module);
getBeamAbstract(Module0) ->
    case ensureAtom(Module0) of
        {ok, Module} ->
            case code:which(Module) of
                Path when is_list(Path) ->
                    case beam_lib:chunks(Path, [abstract_code]) of
                        {ok, {_, [{abstract_code, {raw_abstract_v1, Forms}}]}} ->
                            {ok, #{module => Module, path => Path, forms => Forms}};
                        {ok, {_, [{abstract_code, no_abstract_code}]}} ->
                            {error, no_abstract_code};
                        {error, beam_lib, Reason} ->
                            {error, Reason};
                        Other ->
                            {error, {unexpected, Other}}
                    end;
                non_existing ->
                    {error, moduleNotLoaded};
                preloaded ->
                    {error, preloaded};
                cover_compiled ->
                    {error, cover_compiled};
                _ ->
                    {error, unknownModule}
            end;
        error ->
            {error, {invalidModule, Module0}}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 列出模块的导出函数（来自 BEAM 的 exports chunk）。
%% 支持传入 `#{module => M}' 或直接传入模块名。
%%
%% @param ModuleOrArgs 模块名或含 module 的 map
%% @return `{ok, #{module, exports}}' 或 `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
moduleExports(#{module := Module}) ->
    moduleExports(Module);
moduleExports(Module0) ->
    case ensureAtom(Module0) of
        {ok, Module} ->
            case code:which(Module) of
                Path when is_list(Path) ->
                    case beam_lib:chunks(Path, [exports]) of
                        {ok, {_, [{exports, Exports}]}} ->
                            {ok, #{module => Module, exports => Exports}};
                        {error, beam_lib, Reason} ->
                            {error, Reason};
                        _ ->
                            {error, exportsUnavailable}
                    end;
                _ ->
                    {error, moduleNotLoaded}
            end;
        error ->
            {error, {invalidModule, Module0}}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 解析模块的 `-type' / `-opaque' / `-callback' / `-record' / `-spec'
%% 符号体系，按类别返回每个符号的名称、元数、行号与源码文本。
%% 复用 {@link getBeamAbstract/1} 拿 abstract_code forms，再按 attribute
%% tag 分类。用于补全 `getBeamAbstract' 仅暴露函数 form 的符号盲区。
%%
%% @param ModuleOrArgs 模块名或含 module 的 map
%% @return `{ok, #{module, types, opaques, callbacks, records, specs, summary}}'
%%         或 `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
getModuleTypes(#{module := Module}) ->
    getModuleTypes(Module);
getModuleTypes(Module0) ->
    case getBeamAbstract(Module0) of
        {ok, #{forms := Forms, module := Module}} ->
            Types = collectAttrForms(Forms, type),
            Opaques = collectAttrForms(Forms, opaque),
            Callbacks = collectAttrForms(Forms, callback),
            Records = collectAttrForms(Forms, record),
            Specs = collectAttrForms(Forms, spec),
            {ok, #{
                module => Module,
                types => Types,
                opaques => Opaques,
                callbacks => Callbacks,
                records => Records,
                specs => Specs,
                summary => #{
                    typeCount => length(Types),
                    opaqueCount => length(Opaques),
                    callbackCount => length(Callbacks),
                    recordCount => length(Records),
                    specCount => length(Specs)
                }
            }};
        {error, _} = E ->
            E
    end.

%%--------------------------------------------------------------------
%% @doc
%% 从模块的 abstract_code 中提取指定函数的源码文本。
%% 支持 contextLines（默认 5）：磁盘路径下函数体前后各扩展 N 行。
%%
%% @param Args 含 module/function/arity，可选 contextLines
%% @return `{ok, #{module, function, arity, source, ...}}' 或 `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
getSymbolSource(Args) when is_map(Args) ->
    Mod = maps:get(module, Args, maps:get(<<"module">>, Args, undefined)),
    Fun = maps:get(function, Args, maps:get(<<"function">>, Args, undefined)),
    Arity = maps:get(arity, Args, maps:get(<<"arity">>, Args, undefined)),
    Pad = contextLinesArg(Args),
    case {Mod, Fun, Arity} of
        {undefined, _, _} -> {error, missingModule};
        {_, undefined, _} -> {error, missingFunction};
        {_, _, undefined} -> {error, missingArity};
        _ ->
            case getSymbolSourceFromBeam(Mod, Fun, Arity) of
                {ok, _} = Ok ->
                    Ok;
                {error, _} ->
                    getSymbolSourceFromDisk(Mod, Fun, Arity, Pad)
            end
    end.

contextLinesArg(Args) ->
    case maps:get(contextLines, Args, maps:get(<<"contextLines">>, Args, 5)) of
        N when is_integer(N), N >= 0, N =< 50 -> N;
        _ -> 5
    end.

getSymbolSourceFromBeam(Mod, Fun, Arity) ->
    case getBeamAbstract(Mod) of
        {ok, #{forms := Forms, module := Module}} ->
            FunAtom = case ensureAtom(Fun) of {ok, F} -> F; error -> Fun end,
            ArityInt = toInteger(Arity),
            case findFunctionForms(Forms, FunAtom, ArityInt) of
                {ok, FnForms} ->
                    Source = try
                        unicode:characters_to_binary(
                            lists:flatten([erl_pp:form(F) || F <- FnForms]))
                    catch _:_ ->
                        iolist_to_binary(io_lib:format("~p.", [FnForms]))
                    end,
                    {ok, #{module => Module, function => FunAtom, arity => ArityInt,
                           source => Source, backend => beamAbstract}};
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

%% BEAM 无 abstract_code 时：索引行号 → readFile 行区间；再不行则扫 .erl 源码。
%% 索引绝对路径 enoent 时强制用 resolveModule 相对路径重试（与 maybeRetryRead 同策略）。
getSymbolSourceFromDisk(Mod, Fun, Arity, Pad) ->
    ArityInt = toInteger(Arity),
    FunAtom = case ensureAtom(Fun) of {ok, F} -> F; error -> undefined end,
    case lookupSymbolLocation(Mod, Fun, ArityInt) of
        {ok, #{file := File, startLine := Start, endLine := End}} ->
            S = max(1, Start - Pad),
            E = End + Pad,
            case readFileRangePreferRelative(File, Mod, S, E) of
                {ok, #{content := Source} = Range} ->
                    {ok, Range#{
                        module => Mod,
                        function => FunAtom,
                        arity => ArityInt,
                        source => Source,
                        backend => sourceLineRange,
                        contextLines => Pad,
                        symbolStartLine => Start,
                        symbolEndLine => End
                    }};
                {error, _} ->
                    case resolveModuleSourceFile(Mod) of
                        {ok, AltFile} ->
                            extractFunctionFromSourceFile(AltFile, FunAtom, ArityInt, Mod, Pad);
                        {error, _} = Err ->
                            Err
                    end
            end;
        {error, _} ->
            case resolveModuleSourceFile(Mod) of
                {ok, File} ->
                    extractFunctionFromSourceFile(File, FunAtom, ArityInt, Mod, Pad);
                {error, _} = E ->
                    E
            end
    end.

%% 先按索引路径读区间；失败则用模块解析路径重试（避免错误绝对路径拖死）。
readFileRangePreferRelative(File, Mod, StartLine, EndLine) ->
    Args = #{path => File, startLine => StartLine, endLine => EndLine, maxBytes => 96000},
    case readFile(Args) of
        {ok, _} = Ok ->
            Ok;
        {error, #{reason := Reason}} when Reason =:= enoent; Reason =:= pathNotAllowed ->
            retrySymbolRangeRead(Mod, File, StartLine, EndLine);
        {error, Reason} when Reason =:= enoent; Reason =:= pathNotAllowed ->
            retrySymbolRangeRead(Mod, File, StartLine, EndLine);
        {error, _} = Err ->
            Err
    end.

retrySymbolRangeRead(Mod, FailedPath, StartLine, EndLine) ->
    case resolveModuleSourceFile(Mod) of
        {ok, Alt} ->
            case string:lowercase(toList(Alt)) =:= string:lowercase(toList(FailedPath)) of
                true ->
                    {error, #{reason => enoent, path => FailedPath}};
                false ->
                    case readFile(#{path => Alt, startLine => StartLine, endLine => EndLine,
                                   maxBytes => 96000, '_retried' => true}) of
                        {ok, Ok} when is_map(Ok) ->
                            {ok, Ok#{
                                resolvedFrom => FailedPath,
                                usedSuggestion => Alt,
                                autoResolved => true
                            }};
                        {error, _} = E ->
                            E
                    end
            end;
        {error, _} = E ->
            E
    end.

lookupSymbolLocation(Mod, Fun, Arity) ->
    DefaultFile = case resolveModuleSourceFile(Mod) of
        {ok, F} -> F;
        {error, _} -> undefined
    end,
    case symbolLocFromCore(Mod, Fun, Arity) of
        {ok, Loc} ->
            File = case maps:get(file, Loc, undefined) of
                undefined -> DefaultFile;
                LocFile -> LocFile
            end,
            Start = maps:get(startLine, Loc, maps:get(line, Loc, undefined)),
            End = maps:get(endLine, Loc, Start),
            case {File, Start} of
                {FilePath, S} when FilePath =/= undefined, is_integer(S), S >= 1 ->
                    {ok, #{
                        file => FilePath,
                        startLine => S,
                        endLine => case End of E when is_integer(E), E >= S -> E; _ -> S + 40 end
                    }};
                _ ->
                    {error, noLocation}
            end;
        {error, _} = E ->
            E
    end.

symbolLocFromCore(Mod, Fun, Arity) ->
    case alCoreClient:unwrap(alCoreClient:getSymbol(Mod, Fun, Arity)) of
        {ok, Result} ->
            case extractSymbolLoc(Result) of
                undefined -> symbolLocFromModuleSymbols(Mod, Fun, Arity);
                Loc -> {ok, Loc}
            end;
        {error, _} ->
            symbolLocFromModuleSymbols(Mod, Fun, Arity)
    end.

symbolLocFromModuleSymbols(Mod, Fun, Arity) ->
    case alCoreClient:unwrap(alCoreClient:moduleSymbols(Mod)) of
        {ok, Result} ->
            case findFunLocInSymbols(Result, Fun, Arity) of
                undefined -> {error, symbolNotFound};
                Loc -> {ok, Loc}
            end;
        {error, _} = E ->
            E
    end.

extractSymbolLoc(Result) when is_map(Result) ->
    Sym = maps:get(symbol, Result,
                   maps:get(<<"symbol">>, Result,
                            nestedMap(Result, [data, symbol], undefined))),
    extractFunLoc(Sym);
extractSymbolLoc(_) ->
    undefined.

findFunLocInSymbols(Result, Fun, Arity) ->
    Funs = nestedMap(Result, [document, functions],
                     nestedMap(Result, [<<"document">>, <<"functions">>],
                               maps:get(functions, Result, []))),
    Target = toBinary(Fun),
    case is_list(Funs) of
        true ->
            case [F || F <- Funs, is_map(F),
                       toBinary(maps:get(name, F, maps:get(<<"name">>, F, <<>>))) =:= Target,
                       toInteger(maps:get(arity, F, maps:get(<<"arity">>, F, -1))) =:= Arity] of
                [F | _] -> extractFunLoc(F);
                [] -> undefined
            end;
        false ->
            undefined
    end.

extractFunLoc(M) when is_map(M) ->
    Line = firstInt([line, <<"line">>, start_line, <<"start_line">>], M),
    Start = firstInt([start_line, <<"start_line">>, line, <<"line">>], M, Line),
    End = firstInt([end_line, <<"end_line">>], M, Start),
    File = firstBin([file, <<"file">>, path, <<"path">>], M),
    case Start of
        S when is_integer(S), S >= 1 ->
            #{line => S, startLine => S, endLine => End, file => File};
        _ ->
            undefined
    end;
extractFunLoc(_) ->
    undefined.

resolveModuleSourceFile(Mod) ->
    ModBin = toBinary(Mod),
    ModStr = unicode:characters_to_list(ModBin),
    ModFile = ModStr ++ ".erl",
    Candidates = [
        filename:join(["src", ModFile]),
        filename:join(["src", filename:dirname(ModStr), ModFile]),
        ModFile
    ],
    tryFirstExisting(Candidates).

tryFirstExisting([]) ->
    {error, moduleFileNotFound};
tryFirstExisting([Rel | Rest]) ->
    case resolveReadablePath(Rel) of
        {ok, Abs} -> {ok, Abs};
        {error, _} -> tryFirstExisting(Rest)
    end.

extractFunctionFromSourceFile(File, Fun, Arity, Mod) ->
    extractFunctionFromSourceFile(File, Fun, Arity, Mod, 5).

extractFunctionFromSourceFile(File, Fun, Arity, Mod, Pad)
  when is_atom(Fun), is_integer(Arity) ->
    case readFile(#{path => File, maxBytes => 512000}) of
        {ok, #{content := Bin}} ->
            Lines = binary:split(Bin, <<"\n">>, [global]),
            FunStr = atom_to_list(Fun),
            HeadRe = "^\\s*" ++ reQuote(FunStr) ++ "\\s*\\(",
            case findFunctionBlock(Lines, HeadRe, Arity) of
                {ok, Start, End, _Block} ->
                    S = max(1, Start - Pad),
                    E = min(length(Lines), End + Pad),
                    Slice = lists:sublist(Lines, S, E - S + 1),
                    Source = iolist_to_binary(lists:join(<<"\n">>, Slice)),
                    {ok, #{
                        module => Mod,
                        function => Fun,
                        arity => Arity,
                        source => Source,
                        backend => sourceParse,
                        file => File,
                        startLine => S,
                        endLine => E,
                        contextLines => Pad,
                        symbolStartLine => Start,
                        symbolEndLine => End
                    }};
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end;
extractFunctionFromSourceFile(_File, _Fun, _Arity, _Mod, _Pad) ->
    {error, badArgs}.

findFunctionBlock(Lines, HeadRe, Arity) ->
    findFunctionBlock(Lines, HeadRe, Arity, 1, []).

findFunctionBlock([], _HeadRe, _Arity, _LineNo, _Acc) ->
    {error, functionNotFound};
findFunctionBlock([Line | Rest], HeadRe, Arity, LineNo, _Acc) ->
    %% re:run + {capture, none} 返回 match | nomatch（不是 {match, _}）
    case re:run(Line, HeadRe, [{capture, none}]) of
        match ->
            %% Acc 已含当前行，继续从 Rest 收集，避免函数头重复计入
            case collectFunctionLines(Rest, Arity, 1, [Line]) of
                {ok, BlockLines} ->
                    EndLine = LineNo + length(BlockLines) - 1,
                    Block = iolist_to_binary([<<L/binary, "\n">> || L <- BlockLines]),
                    {ok, LineNo, EndLine, Block};
                {error, _} ->
                    findFunctionBlock(Rest, HeadRe, Arity, LineNo + 1, [])
            end;
        nomatch ->
            findFunctionBlock(Rest, HeadRe, Arity, LineNo + 1, [])
    end.

collectFunctionLines([Line | Rest], Arity, Depth, Acc) ->
    NewDepth = clauseDepthDelta(Line, Arity, Depth),
    case NewDepth =< 0 andalso Depth > 0 of
        true ->
            {ok, lists:reverse([Line | Acc])};
        false ->
            case Rest of
                [] ->
                    {ok, lists:reverse(Acc)};
                _ ->
                    collectFunctionLines(Rest, Arity, NewDepth, [Line | Acc])
            end
    end;
collectFunctionLines([], _Arity, _Depth, Acc) ->
    {ok, lists:reverse(Acc)}.

%% 粗略跟踪 clause 深度：函数头匹配后 Depth 从 1 起；
%% 遇到以 `.` 结尾的行（Erlang clause 结束）则 Depth-1。
clauseDepthDelta(Line, _Arity, Depth) ->
    Trim = string:trim(toList(Line)),
    case Trim of
        "" ->
            Depth;
        "." ->
            Depth - 1;
        _ ->
            case lists:last(Trim) of
                $. when Depth >= 1 -> Depth - 1;
                _ -> Depth
            end
    end.

reQuote(S) ->
    re:replace(S, "([\\.\\^\\$\\|\\?\\*\\+\\(\\)\\[\\]\\{\\}\\\\])", "\\\\\\1",
                [global, {return, list}]).

nestedMap(M, Keys, Default) when is_map(M) ->
    nestedMapImpl(M, Keys, Default);
nestedMap(_, _, Default) ->
    Default.

nestedMapImpl(M, [], _Default) ->
    M;
nestedMapImpl(M, [K | Rest], Default) ->
    case maps:get(K, M, undefined) of
        Sub when is_map(Sub) -> nestedMapImpl(Sub, Rest, Default);
        undefined -> Default;
        Other when Rest =:= [] -> Other;
        _ -> Default
    end.

firstInt(Keys, M) ->
    firstInt(Keys, M, undefined).

firstInt([], _M, Default) ->
    Default;
firstInt([K | Rest], M, Default) ->
    case maps:get(K, M, undefined) of
        V when is_integer(V) -> V;
        V when is_binary(V) ->
            try binary_to_integer(V) catch _:_ -> firstInt(Rest, M, Default) end;
        _ -> firstInt(Rest, M, Default)
    end.

firstBin(Keys, M) ->
    firstBin(Keys, M, undefined).

firstBin([], _M, Default) ->
    Default;
firstBin([K | Rest], M, Default) ->
    case maps:get(K, M, undefined) of
        V when is_binary(V) -> V;
        V when is_list(V) -> unicode:characters_to_binary(V);
        _ -> firstBin(Rest, M, Default)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 使用 erlfmt 格式化代码：可直接传 code 文本，或传 path 读取后再格式化。
%% 格式化失败时回退为 trim 后的原文并附带 warning。
%%
%% @param Args 含 code 或 path 的 map
%% @return `{ok, #{formatted, warning?}}'
%% @end
%%--------------------------------------------------------------------
formatCode(#{code := Code}) ->
    String = toList(toBinary(Code)),
    case erlfmt:format_string(String, #{}) of
        {ok, Formatted, _} ->
            {ok, #{formatted => unicode:characters_to_binary(Formatted)}};
        {error, Reason} ->
            {ok, #{formatted => unicode:characters_to_binary(string:trim(String)),
                   warning => formatError(Reason)}}
    end;
formatCode(#{path := Path}) ->
    case readFile(#{path => Path}) of
        {ok, #{content := Bin}} ->
            formatCode(#{code => Bin});
        {error, _} = E ->
            E
    end.

%%--------------------------------------------------------------------
%% @doc
%% 运行 eunit 测试，支持指定模块或全量运行。
%%
%% @param Args 含可选 module（atom/binary/list）和 timeout 的 map
%% @return `{ok, #{exitCode, success, output, durationMs, command}}'
%% @end
%%--------------------------------------------------------------------
runEunit(Args) ->
    Module = maps:get(module, Args, all),
    Timeout = maps:get(timeout, Args, 300000),
    case eunitArgs(Module) of
        {ok, EunitArgs} ->
            runProgram("rebar3", EunitArgs, Timeout);
        {error, _} = E ->
            E
    end.

%% 构造 rebar3 eunit 参数，module 名必须匹配 `^[a-zA-Z][a-zA-Z0-9_]*$'
%% 以杜绝命令/参数注入。
eunitArgs(all) ->
    {ok, ["eunit"]};
eunitArgs(M) when is_atom(M) ->
    eunitArgs(atom_to_list(M));
eunitArgs(M) when is_binary(M) ->
    eunitArgs(binary_to_list(M));
eunitArgs(M) when is_list(M) ->
    case isValidModuleName(M) of
        true -> {ok, ["eunit", "--module=" ++ M]};
        false -> {error, {invalidModuleName, M}}
    end;
eunitArgs(Other) ->
    {error, {invalidModuleName, Other}}.

%% 合法 Erlang 模块名：字母开头，其后为字母/数字/下划线。
isValidModuleName(Name) when is_list(Name) ->
    match =:= re:run(Name, "^[a-zA-Z][a-zA-Z0-9_]*$", [{capture, none}]);
isValidModuleName(_) ->
    false.

%%--------------------------------------------------------------------
%% @doc
%% 运行 dialyzer 静态分析。
%%
%% @param Args 含可选 args（白名单参数列表）和 timeout 的 map
%% @return `{ok, #{exitCode, success, output, durationMs, command}}'
%% @end
%%--------------------------------------------------------------------
%% 固定为 `rebar3 dialyzer'，不接受任意 command；仅允许白名单参数，
%% 避免通过命令/参数注入执行任意程序。
runDialyzer(Args) ->
    Timeout = maps:get(timeout, Args, 600000),
    ExtraArgs = dialyzerArgs(maps:get(args, Args, [])),
    runProgram("rebar3", ["dialyzer" | ExtraArgs], Timeout).

%% 过滤 dialyzer 参数，仅保留白名单项。
dialyzerArgs(Args) when is_list(Args) ->
    Allowed = ["--update-plt", "--succ-typings", "--statistics", "-q", "--quiet",
               "--raw", "--no_native"],
    lists:filter(fun(A) -> lists:member(A, Allowed) end,
                 [toArgString(A) || A <- Args]);
dialyzerArgs(_) ->
    [].

%% 将参数值归一为字符串（用于白名单比对）。
toArgString(A) when is_binary(A) -> binary_to_list(A);
toArgString(A) when is_list(A) -> A;
toArgString(A) when is_atom(A) -> atom_to_list(A);
toArgString(_) -> "".

%%--------------------------------------------------------------------
%% @doc Run verification for files touched by a patch: compile, then
%% optional eunit for inferred modules. Returns a bounded failure summary
%% suitable for feeding back into the agent loop.
%% @end
%%--------------------------------------------------------------------
runTestsForPatch(Args) when is_map(Args) ->
    Files = patchFiles(Args),
    Modules = [pathToModule(F) || F <- Files],
    Modules1 = [M || M <- Modules, M =/= undefined],
    Timeout = maps:get(timeout, Args, 300000),
    Compile = runProgram("rebar3", ["compile"], min(Timeout, 120000)),
    Tests = case Modules1 of
        [] ->
            #{skipped => true, reason => noModules};
        [Mod | _] ->
            case runEunit(#{module => Mod, timeout => Timeout}) of
                {ok, R} -> R;
                {error, E} -> #{success => false, error => E}
            end
    end,
    CompileOk = case Compile of
        {ok, #{success := true}} -> true;
        _ -> false
    end,
    TestOk = case Tests of
        #{success := true} -> true;
        #{skipped := true} -> CompileOk;
        _ -> false
    end,
    Summary = iolist_to_binary(io_lib:format(
        "compile=~p test=~p modules=~p",
        [CompileOk, TestOk, Modules1])),
    CompileInfo = case Compile of
        {ok, C} -> C;
        {error, CE} -> #{error => CE};
        Other -> Other
    end,
    {ok, #{
        success => CompileOk andalso TestOk,
        files => Files,
        modules => Modules1,
        compile => CompileInfo,
        tests => Tests,
        summary => Summary
    }}.

patchFiles(#{file := File}) -> [File];
patchFiles(#{files := Files}) when is_list(Files) -> Files;
patchFiles(#{patches := Patches}) when is_list(Patches) ->
    [maps:get(file, P) || P <- Patches, is_map(P), maps:is_key(file, P)];
patchFiles(#{path := Path}) -> [Path];
patchFiles(_) -> [].

pathToModule(Path) when is_binary(Path) ->
    pathToModule(binary_to_list(Path));
pathToModule(Path) when is_list(Path) ->
    Base = filename:basename(Path, ".erl"),
    case Base =:= Path orelse filename:extension(Path) =/= ".erl" of
        true -> undefined;
        false ->
            try list_to_existing_atom(Base) catch _:_ -> undefined end
    end;
pathToModule(_) -> undefined.

%%--------------------------------------------------------------------
%% @doc
%% 在项目根目录以 `spawn_executable' 运行程序（不经 shell，杜绝命令
%% 注入），收集 stdout+stderr 合并输出并带超时控制。收到 exit_status
%% 即时返回退出码，无需等满 timeout。
%%
%% @param Program 程序名（如 "rebar3"）
%% @param Args    参数列表（每项独立传入，不做 shell 拼接）
%% @param Timeout 超时毫秒
%% @return `{ok, #{exitCode, success, output, durationMs, command}}' 或 `{error, ...}'
%% @end
%%--------------------------------------------------------------------
runProgram(Program, Args, Timeout) when is_list(Program), is_list(Args) ->
    %% 安全：Program 是上层（如 runEunit/runDialyzer/runTestsForPatch）传入的程序名，
    %% 默认会经 Windows cmd.exe /c 执行（cmd.exe /c <Program> <Args...>）。
    %% 在传给 cmd 前对 Program 做基本校验——拒绝 shell 元字符（& | > < ; 等），
    %% 避免 Program 内嵌 cmd 控制序列被 cmd.exe 解释执行。
    %% 注意：本层只校验 Program，Args 仍可能含元字符（cmd 会拼接 & 引号剥离等），
    %% 调用方仍需自行对 Args 做白名单/转义。Windows 下若 Args 不可信应改用
    %% spawn_executable 直接执行 .exe（不经 cmd.exe /c），但 rebar3 是 .cmd 脚本，
    %% 仍需经 cmd，故此校验是必要兜底。
    case validateProgramName(Program) of
        {error, _} = E -> E;
        ok ->
            Root = alConfig:root(),
            Started = erlang:monotonic_time(millisecond),
            CmdText = unicode:characters_to_binary(lists:join(" ", [Program | Args])),
            case resolveProgram(Program, Args) of
                {error, _} = E ->
                    E;
                {Exe, FullArgs} ->
                    PortOpts = [exit_status, use_stdio, stderr_to_stdout, binary,
                                {cd, Root}, {args, FullArgs}],
                    try open_port({spawn_executable, Exe}, PortOpts) of
                        Port when is_port(Port) ->
                            Deadline = erlang:monotonic_time(millisecond) + Timeout,
                            collectPortResult(Port, [], Deadline, Started, CmdText)
                    catch
                        error:Reason -> {error, Reason}
                    end
            end
    end.

%% 校验 Program 名不含 shell 元字符（& | > < ; ` $ % ( ) 等）。
%% 仅做基本拒绝，不尝试转义——调用方传错程序名是逻辑错误，应直接拒绝而非猜意图。
%% 通过的 Program 仍是字符串字面量（如 "rebar3"），cmd.exe /c <Program> 不会引入注入。
validateProgramName(Program) when is_list(Program) ->
    Banned = [$&, $|, $>, $<, $;, $`, $$, $%, $(, $), $\n, $\r, $", $'],
    case lists:any(fun(C) -> lists:member(C, Program) end, Banned) of
        false -> ok;
        true -> {error, #{reason => programNameHasShellMetachars,
                          program => Program}}
    end;
validateProgramName(Other) ->
    {error, #{reason => programNameNotAString, program => Other}}.

%% 解析程序为 spawn_executable 可用的 `{Exe, Args}'。
%% Windows 经 cmd.exe /c 运行（rebar3 常为 .cmd 脚本），参数逐个传入；
%% 由于上层已对 module 名/参数做白名单校验，cmd 解析不会引入注入。
%% 其他平台用 os:find_executable 定位可执行文件。
resolveProgram(Program, Args) ->
    case os:type() of
        {win32, _} ->
            Comspec = case os:getenv("COMSPEC") of
                false -> "cmd.exe";
                C -> C
            end,
            {Comspec, ["/c", Program | Args]};
        _ ->
            case os:find_executable(Program) of
                false -> {error, {executableNotFound, Program}};
                Path -> {Path, Args}
            end
    end.

%% 收集 Port 输出直到 exit_status 或 deadline。收到退出码即返回；
%% 超时则安全关闭 port 并返回已收集数据。prepend 累积避免 O(n²)。
collectPortResult(Port, Acc, Deadline, Started, CmdText) ->
    Now = erlang:monotonic_time(millisecond),
    Remaining = max(0, Deadline - Now),
    receive
        {Port, {data, Data}} ->
            collectPortResult(Port, [Data | Acc], Deadline, Started, CmdText);
        {Port, {exit_status, Code}} ->
            Elapsed = erlang:monotonic_time(millisecond) - Started,
            {ok, #{
                exitCode => Code,
                success => Code =:= 0,
                output => iolist_to_binary(lists:reverse(Acc)),
                durationMs => Elapsed,
                command => CmdText
            }}
    after Remaining ->
        safeKillPort(Port),
        {error, #{
            reason => portTimeout,
            output => iolist_to_binary(lists:reverse(Acc)),
            command => CmdText
        }}
    end.

%% 安全关闭 Port：已关闭时 port_close 抛 badarg，用 try 兜住。
safeKillPort(Port) ->
    try port_close(Port) catch _:_ -> ok end.

%% 将错误原因格式化为 binary 文本。
formatError(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).

%%--------------------------------------------------------------------
%% @doc 设置会话的任务计划，返回带摘要的计划。
%% @param SessionId 会话 ID
%% @param Steps 步骤列表
%% @return `{ok, PlanWithSummary}'
%% @end
%%--------------------------------------------------------------------
planSet(SessionId, Steps) ->
    Plan = alPlan:setPlan(SessionId, Steps),
    {ok, alPlan:withSummary(Plan)}.

%% 更新计划中指定步骤的状态/内容。
planUpdate(SessionId, StepId, Updates) ->
    alPlan:updateStep(SessionId, StepId, Updates).

%% 获取会话计划（含摘要）。
planGet(SessionId) ->
    {ok, alPlan:withSummary(alPlan:getPlan(SessionId))}.

%% 清除会话计划。
planClear(SessionId) ->
    alPlan:clear(SessionId),
    ok.

%%--------------------------------------------------------------------
%% @doc 委托任务给子代理执行。
%% @param Args 含 agent（子代理名）和 task（任务描述）的 map
%% @return 子代理执行结果或 `{error, missingTask}'
%% @end
%%--------------------------------------------------------------------
delegateTo(#{agent := Agent, task := Task}) ->
    Name = toAtom(Agent),
    alSubAgent:run(Name, toBinary(Task), #{persistMemory => false});
delegateTo(#{agent := _Agent}) ->
    {error, missingTask};
%% 缺少 task 字段时补默认空值后递归。
delegateTo(Args) when is_map(Args) ->
    delegateTo(maps:merge(#{task => <<>>}, Args)).

%%--------------------------------------------------------------------
%% @doc 激活指定技能，返回技能定义供上下文注入。
%% @param Args 含 skill（技能名）的 map
%% @return `{ok, SkillMap}' 或 `{error, notFound}'
%% @end
%%--------------------------------------------------------------------
useSkill(#{skill := Skill} = Args) ->
    case alSkill:lookup(Skill) of
        {ok, S} ->
            {ok, maps:merge(S, maps:without([skill], Args))};
        {error, _} = E ->
            E
    end.

%%--------------------------------------------------------------------
%% @doc
%% 只读网络工具：对指定 URL 发起 HTTP GET，返回状态码与截断后的正文。
%% 受安全约束：仅允许 http/https，默认拒绝明显内网地址（除非配置显式
%% 允许），默认超时 15s，正文默认最多 50KB。
%%
%% HTML 页面自动做 readability 正文提取：`body' 为提取后的纯文本，
%% 另附 `title' / `extracted => true' / `format'；提取失败才回退原始 HTML。
%% 请求带类 Chrome 的 UA/Accept 头（anti-bot 基础处理），同域名限速
%% （fetchUrl.perHostMinIntervalMs）。
%%
%% @param Args 含 url 与可选 maxBytes / timeout 的 map
%% @return `{ok, #{url, status, headers, body, bytes, truncated, format,
%%                 extracted, title, charset}}' 或 `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
fetchUrl(#{url := Url} = Args) ->
    MaxBytes = clampFetchBytes(maps:get(maxBytes, Args, ?DefaultFetchMaxBytes)),
    Timeout = clampFetchTimeout(maps:get(timeout, Args, ?DefaultFetchTimeoutMs)),
    case validateFetchUrl(Url) of
        {ok, Normalized} ->
            throttleFetchHost(Normalized),
            case doFetchUrl(Normalized, MaxBytes, Timeout, fetchRequestHeaders()) of
                {ok, Result} -> {ok, processFetchResult(Normalized, Result)};
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end;
fetchUrl(_) ->
    {error, #{reason => missingUrl}}.

%%--------------------------------------------------------------------
%% @doc
%% 分页读取网页正文：cursor 为上次返回的 nextCursor（已读字节偏移）。
%% 首次调用传 null 省略 cursor；正文已做 readability 提取并缓存
%% （TTL 10 分钟），续读不再重复抓取。
%%
%% @param Args 含 url、cursor(可选)、chunkBytes(可选，默认 24000)、
%%             timeout(可选)
%% @return `{ok, #{url, offset, content, bytes, totalBytes, hasMore,
%%                 nextCursor, cached}}' 或 `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
fetchUrlPage(#{url := Url} = Args) ->
    Timeout = clampFetchTimeout(maps:get(timeout, Args, ?DefaultFetchTimeoutMs)),
    Offset = parsePageCursor(maps:get(cursor, Args, null)),
    Chunk = clampPageChunkBytes(maps:get(chunkBytes, Args, ?DefaultPageChunkBytes)),
    case validateFetchUrl(Url) of
        {ok, Normalized} ->
            case cachedPageText(Normalized, Timeout) of
                {ok, Text, FromCache} ->
                    {ok, servePageChunk(Normalized, Text, Offset, Chunk, FromCache)};
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end;
fetchUrlPage(_) ->
    {error, #{reason => missingUrl}}.

%% cursor 解析：null/缺失 → 0；数字 binary/integer → 非负整数；非法 → 0。
parsePageCursor(null) -> 0;
parsePageCursor(undefined) -> 0;
parsePageCursor(N) when is_integer(N), N >= 0 -> N;
parsePageCursor(B) when is_binary(B) ->
    try binary_to_integer(string:trim(B)) of
        N when N >= 0 -> N;
        _ -> 0
    catch _:_ -> 0 end;
parsePageCursor(_) -> 0.

clampPageChunkBytes(N) when is_integer(N), N >= ?MinPageChunkBytes ->
    min(N, ?MaxPageChunkBytes);
clampPageChunkBytes(_) -> ?DefaultPageChunkBytes.

%% 页正文缓存：{Url, Text, Seq, StoredAt}，TTL 内直接复用。
cachedPageText(Url, Timeout) ->
    case pageCacheLookup(Url) of
        {ok, Text} ->
            {ok, Text, true};
        miss ->
            throttleFetchHost(Url),
            case doFetchUrl(Url, ?PageFetchMaxBytes, Timeout, fetchRequestHeaders()) of
                {ok, Result} ->
                    {_FinalUrl, Text} = pageCacheText(Url, Result),
                    pageCacheStore(Url, Text),
                    {ok, Text, false};
                {error, _} = E ->
                    E
            end
    end.

pageCacheText(Url, Result) ->
    Processed = processFetchResult(Url, Result),
    Text = maps:get(body, Processed, <<>>),
    {maps:get(url, Processed, Url), Text}.

pageCacheLookup(Url) ->
    ensurePageCache(),
    try ets:lookup(?PageCacheTable, Url) of
        [{Url, Text, _Seq, StoredAt}] ->
            Now = erlang:system_time(millisecond),
            case Now - StoredAt =< ?PageCacheTtlMs of
                true -> {ok, Text};
                false ->
                    ets:delete(?PageCacheTable, Url),
                    miss
            end;
        [] ->
            miss
    catch _:_ -> miss end.

pageCacheStore(Url, Text) ->
    ensurePageCache(),
    try
        Seq = erlang:unique_integer([positive, monotonic]),
        ets:insert(?PageCacheTable, {Url, Text, Seq, erlang:system_time(millisecond)}),
        evictPageCache()
    catch _:_ -> ok end.

%% 超 capacity 时淘汰最旧条目（select 只投影 {Seq, Key}，避免拷贝正文）。
evictPageCache() ->
    case ets:info(?PageCacheTable, size) of
        N when N > ?PageCacheMax ->
            MS = [{{'$1', '_', '$2', '_'}, [], [{{'$2', '$1'}}]}],
            case ets:select(?PageCacheTable, MS) of
                [] -> ok;
                Entries ->
                    {_MinSeq, Key} = lists:min(Entries),
                    ets:delete(?PageCacheTable, Key),
                    evictPageCache()
            end;
        _ ->
            ok
    end.

ensurePageCache() ->
    case ets:whereis(?PageCacheTable) of
        undefined ->
            try ets:new(?PageCacheTable,
                        [named_table, public, set,
                         {read_concurrency, true}, {write_concurrency, true}])
            catch _:_ -> ok end;
        _ -> ok
    end.

servePageChunk(Url, Text, Offset, Chunk, FromCache) ->
    Total = byte_size(Text),
    Avail = max(0, Total - Offset),
    Take = min(Avail, Chunk),
    Part = case Take of
        0 -> <<>>;
        _ -> binary:part(Text, Offset, Take)
    end,
    NextOffset = Offset + Take,
    HasMore = NextOffset < Total,
    #{
        url => Url,
        offset => Offset,
        content => Part,
        bytes => Take,
        totalBytes => Total,
        hasMore => HasMore,
        nextCursor => case HasMore of
            true -> integer_to_binary(NextOffset);
            false -> null
        end,
        cached => FromCache
    }.

%% HTML 正文提取与格式标注：按 content-type 分派，HTML 走 readability。
processFetchResult(Url, #{body := Body} = Result) ->
    Headers = maps:get(headers, Result, #{}),
    ContentType = toBinary(maps:get(<<"content-type">>, Headers, <<>>)),
    Format = contentTypeFormat(ContentType),
    Charset = contentTypeCharset(ContentType),
    Base = Result#{url => Url, format => Format},
    Base1 = case Charset of
        <<>> -> Base;
        _ -> Base#{charset => Charset}
    end,
    case Format of
        html when byte_size(Body) > 0 ->
            {Title, Text} = alWebSearch:extractMainContent(Body),
            case byte_size(Text) > 200 of
                true ->
                    Base1#{body => Text, extracted => true, title => Title,
                           rawBytes => byte_size(Body)};
                false ->
                    Base1#{extracted => false}
            end;
        _ ->
            Base1
    end;
processFetchResult(_Url, Result) ->
    Result.

contentTypeFormat(ContentType) ->
    CT = string:lowercase(toBinary(ContentType)),
    case binary:match(CT, <<"html">>) of
        {_, _} -> html;
        _ ->
            IsText = (binary:match(CT, <<"text/">>) =:= {0, 5})
                orelse (binary:match(CT, <<"json">>) =/= nomatch)
                orelse (binary:match(CT, <<"xml">>) =/= nomatch),
            case IsText of
                true -> text;
                false -> binary
            end
    end.

%% 从 content-type 提取 charset 值（如 text/html; charset=utf-8 → utf-8）。
contentTypeCharset(ContentType) ->
    CT = toBinary(ContentType),
    case re:run(CT, "charset\\s*=\\s*([!#$%&'*+.^_`|~0-9A-Za-z-]+)",
                [caseless, {capture, all_but_first, binary}]) of
        {match, [Cs]} -> string:lowercase(Cs);
        nomatch -> <<>>
    end.

%% 类 Chrome 请求头 + 自定义 UA（fetchUrl.userAgent）。
fetchRequestHeaders() ->
    [
        {<<"user-agent">>, fetchUserAgent()},
        {<<"accept">>, <<"text/html,application/xhtml+xml,application/xml;q=0.9,"
                         "application/json;q=0.8,*/*;q=0.7">>},
        {<<"accept-language">>, <<"zh-CN,zh;q=0.9,en;q=0.8">>}
    ].

fetchUserAgent() ->
    Cfg = alConfig:get(fetchUrl, #{}),
    case Cfg of
        M when is_map(M) ->
            case maps:get(userAgent, M, undefined) of
                UA when is_binary(UA), UA =/= <<>> -> UA;
                _ -> ?DefaultFetchChromeUa
            end;
        _ ->
            ?DefaultFetchChromeUa
    end.

%% 同域名限速：perHostMinIntervalMs 内的第二次请求等待差值（封顶 3s）。
throttleFetchHost(Url) ->
    MinIv = fetchHostMinInterval(),
    case MinIv > 0 of
        false -> ok;
        true ->
            case urlHost(Url) of
                <<>> -> ok;
                Host ->
                    Now = erlang:monotonic_time(millisecond),
                    Last = case hostThrottleLookup(Host) of
                        {ok, L} -> L;
                        error -> Now
                    end,
                    Wait = Last + MinIv - Now,
                    case Wait > 0 of
                        true -> timer:sleep(min(Wait, 3000));
                        false -> ok
                    end,
                    hostThrottleStore(Host, erlang:monotonic_time(millisecond))
            end
    end.

fetchHostMinInterval() ->
    Cfg = alConfig:get(fetchUrl, #{}),
    case Cfg of
        M when is_map(M) ->
            case maps:get(perHostMinIntervalMs, M, 1000) of
                N when is_integer(N), N >= 0 -> min(N, 10000);
                _ -> 1000
            end;
        _ -> 1000
    end.

urlHost(Url) ->
    try uri_string:parse(unicode:characters_to_list(toBinary(Url))) of
        Parsed when is_map(Parsed) ->
            unicode:characters_to_binary(string:lowercase(
                maps:get(host, Parsed, "")));
        _ ->
            <<>>
    catch _:_ -> <<>> end.

hostThrottleLookup(Host) ->
    ensureHostThrottle(),
    try ets:lookup(?HostThrottleTable, Host) of
        [{Host, At}] -> {ok, At};
        [] -> error
    catch _:_ -> error end.

hostThrottleStore(Host, At) ->
    ensureHostThrottle(),
    try ets:insert(?HostThrottleTable, {Host, At}) catch _:_ -> ok end.

ensureHostThrottle() ->
    case ets:whereis(?HostThrottleTable) of
        undefined ->
            try ets:new(?HostThrottleTable,
                        [named_table, public, set,
                         {read_concurrency, true}, {write_concurrency, true}])
            catch _:_ -> ok end;
        _ -> ok
    end.

%% 校验 URL：必须为 http/https，且非内网地址（除非配置放行）。
%% 返回 `{ok, BinaryUrl}' 或 `{error, #{reason => ...}}'。
validateFetchUrl(Url0) ->
    UrlBin = toBinary(Url0),
    case uri_string:parse(unicode:characters_to_list(UrlBin)) of
        Parsed when is_map(Parsed) ->
            Scheme = string:lowercase(toList(maps:get(scheme, Parsed, ""))),
            Host = toList(maps:get(host, Parsed, "")),
            case lists:member(Scheme, ["http", "https"]) of
                false ->
                    {error, #{reason => unsupportedScheme,
                              scheme => unicode:characters_to_binary(Scheme)}};
                true when Host =:= "" ->
                    {error, #{reason => invalidUrl}};
                true ->
                    case fetchAllowInternal() orelse not isInternalHost(Host) of
                        true -> {ok, UrlBin};
                        false ->
                            {error, #{reason => internalAddressBlocked,
                                      host => unicode:characters_to_binary(Host)}}
                    end
            end;
        {error, Reason, _} ->
            {error, #{reason => invalidUrl, detail => Reason}}
    end.

%% 判断 host 是否为明显的内网 / 回环地址。
%% 用 inet:parse_address 解析 IP 字面量后按网段判定：
%% - 十进制/十六进制整数形式的 IP（如 2130706433 → 127.0.0.1）一律拒绝
%% - 点分四段含前导零/0x 段（八进制/十六进制混淆）一律拒绝
%% - IPv4-mapped IPv6（::ffff:127.0.0.1）提取内嵌 IPv4 后判定
%% - 域名：DNS 解析后任一地址落在内网网段则拒绝（防 DNS 重绑定）
isInternalHost(Host0) ->
    Host = string:trim(string:lowercase(toList(Host0)), both, "[]"),
    lists:member(Host, ["localhost"])
        orelse lists:suffix(".localhost", Host)
        orelse isInternalIpLiteral(Host)
        orelse resolvesToInternal(Host).

%% 域名解析到内网 IP 则视为 internal（DNS rebinding 防护）。
resolvesToInternal(Host) ->
    case isInternalIpLiteral(Host) of
        true -> true;
        false ->
            V4 = case inet:getaddrs(Host, inet) of
                {ok, Addrs} -> lists:any(fun isInternalParsedIp/1, Addrs);
                _ -> false
            end,
            case V4 of
                true -> true;
                false ->
                    case inet:getaddrs(Host, inet6) of
                        {ok, Addrs6} -> lists:any(fun isInternalParsedIp/1, Addrs6);
                        _ -> false
                    end
            end
    end.

%% IP 字面量（含混淆形式）判定。
isInternalIpLiteral(Host) ->
    case isObfuscatedNumericIp(Host) of
        true ->
            true;
        false ->
            case inet:parse_address(Host) of
                {ok, Ip} -> isInternalParsedIp(Ip);
                {error, _} -> false
            end
    end.

%% 混淆数字 IP：
%% - 纯数字（十进制整数 IP，如 2130706433）不是合法主机名，直接拒绝，
%%   避免 DNS 将其解析回 127.0.0.1
%% - 0x 开头（十六进制 IP）
%% - 点分四段但含 0x 段或前导零段（八进制混淆，如 0177.0.0.1）
isObfuscatedNumericIp(Host) ->
    case re:run(Host, "^(0x[0-9a-f]+|[0-9]+)$") of
        {match, _} ->
            true;
        nomatch ->
            case re:run(Host, "^(0x[0-9a-f]+|[0-9]+)(\\.(0x[0-9a-f]+|[0-9]+)){3}$") of
                {match, _} ->
                    Octets = string:split(Host, ".", all),
                    lists:any(fun hasObfuscatedOctet/1, Octets);
                nomatch ->
                    false
            end
    end.

%% 单个点分段是否混淆：0x 前缀或前导零（长度 >1 且以 0 开头）。
hasObfuscatedOctet([$0, $x | _]) -> true;
hasObfuscatedOctet([$0 | _] = Octet) -> length(Octet) > 1;
hasObfuscatedOctet(_) -> false.

%% 已解析 IP 判定：4 元组为 IPv4；8 元组为 IPv6；
%% ::ffff:a.b.c.d 形式的 IPv4-mapped IPv6 提取内嵌 IPv4 后判定。
isInternalParsedIp({A, B, C, D}) ->
    isInternalIpv4(A, B, C, D);
isInternalParsedIp({0, 0, 0, 0, 0, 65535, C, D}) ->
    isInternalIpv4(highByte(C), lowByte(C), highByte(D), lowByte(D));
isInternalParsedIp(Ip6) when is_tuple(Ip6), tuple_size(Ip6) =:= 8 ->
    isInternalIpv6(Ip6);
isInternalParsedIp(_) ->
    false.

%% IPv4 网段判定：回环 127/8、私有 10/8、192.168/16、172.16-31/12、
%% 链路本地 169.254/16、未指定/本网 0/8。
isInternalIpv4(A, _B, _C, _D) when A =:= 127 -> true;
isInternalIpv4(A, _B, _C, _D) when A =:= 10 -> true;
isInternalIpv4(192, 168, _, _) -> true;
isInternalIpv4(172, B, _, _) when B >= 16, B =< 31 -> true;
isInternalIpv4(169, 254, _, _) -> true;
isInternalIpv4(0, _, _, _) -> true;
isInternalIpv4(_, _, _, _) -> false.

%% IPv6 判定：回环 ::1、未指定 ::、ULA fc00::/7、链路本地 fe80::/10。
isInternalIpv6({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
isInternalIpv6({0, 0, 0, 0, 0, 0, 0, 0}) -> true;
%% ULA fc00::/7 → 首 hextet 高 7 位为 1111110（16 位掩码 FE00）
isInternalIpv6({F, _, _, _, _, _, _, _}) when F band 16#FE00 =:= 16#FC00 -> true;
%% 链路本地 fe80::/10
isInternalIpv6({F, _, _, _, _, _, _, _}) when F band 16#FFC0 =:= 16#FE80 -> true;
isInternalIpv6(_) -> false.

highByte(N) -> N bsr 8.
lowByte(N) -> N band 16#FF.

%% 从配置读取是否允许访问内网地址（默认 false）。
fetchAllowInternal() ->
    Cfg = alConfig:get(fetchUrl, #{}),
    case Cfg of
        M when is_map(M) -> maps:get(allowInternal, M, false) =:= true;
        _ -> false
    end.

%% 将 maxBytes 归一到 [1, 1MB] 区间，非法值回退默认。
clampFetchBytes(N) when is_integer(N), N > 0 -> min(N, 1048576);
clampFetchBytes(_) -> ?DefaultFetchMaxBytes.

%% 将 timeout 归一到 [1s, 60s] 区间，非法值回退默认。
clampFetchTimeout(N) when is_integer(N), N >= 1000 -> min(N, 60000);
clampFetchTimeout(_) -> ?DefaultFetchTimeoutMs.

%% 实际发起 GET 请求：流式读取正文，最多 MaxBytes 字节。
%% 重定向手动跟随：每次跳转前对 Location 目标重新做 validateFetchUrl 校验
%% （防 redirect 到内网导致 SSRF 绕过），最多 3 跳。
doFetchUrl(Url, MaxBytes, Timeout, ReqHeaders) ->
    doFetchUrl(Url, MaxBytes, Timeout, ReqHeaders, 0).

doFetchUrl(Url, MaxBytes, Timeout, ReqHeaders, RedirectCount) ->
    Options = #{
        recvTimeout => Timeout,
        connectTimeout => Timeout,
        maxRedirects => 0,
        maxBytes => MaxBytes
    },
    case alHttp:requestCapped(get, Url, ReqHeaders, <<>>, Options) of
        {ok, Status, Headers, Body, Truncated} ->
            case redirectTarget(Status, Headers) of
                {redirect, Location} when RedirectCount < 3 ->
                    case resolveRedirectUrl(Url, Location) of
                        {ok, NewUrl} ->
                            case validateFetchUrl(NewUrl) of
                                {ok, _} ->
                                    doFetchUrl(NewUrl, MaxBytes, Timeout, ReqHeaders, RedirectCount + 1);
                                {error, _} = E ->
                                    E
                            end;
                        {error, _} = E ->
                            E
                    end;
                _ ->
                    {ok, #{
                        url => Url,
                        status => Status,
                        headers => simplifyHeaders(Headers),
                        body => Body,
                        bytes => byte_size(Body),
                        truncated => Truncated
                    }}
            end;
        {error, Reason} ->
            {error, #{reason => fetchFailed, detail => formatError(Reason)}}
    end.

%% 3xx 且带 Location 头才视为重定向。
redirectTarget(Status, Headers) when Status >= 300, Status < 400 ->
    case findHeader(<<"location">>, Headers) of
        {ok, Location} -> {redirect, Location};
        error -> none
    end;
redirectTarget(_, _) ->
    none.

%% 大小写不敏感地查找响应头（键可能为 binary 或 string）。
findHeader(Name, Headers) when is_list(Headers) ->
    NameL = string:lowercase(toList(Name)),
    case lists:search(fun({K, _V}) -> string:lowercase(toList(K)) =:= NameL end,
                      Headers) of
        {value, {_K, V}} -> {ok, toBinary(V)};
        false -> error
    end;
findHeader(_Name, _Headers) ->
    error.

%% 相对/绝对 Location 解析为绝对 URL；非法返回 {error, invalidRedirect}。
resolveRedirectUrl(Url, Location) ->
    try uri_string:resolve(unicode:characters_to_list(Location),
                           unicode:characters_to_list(Url)) of
        Resolved when is_list(Resolved), Resolved =/= [] ->
            {ok, unicode:characters_to_binary(Resolved)};
        _ ->
            {error, #{reason => invalidRedirect}}
    catch
        _:_ ->
            {error, #{reason => invalidRedirect}}
    end.

%% 流式读取正文直到达到 MaxBytes — 已迁至 alHttp:requestCapped/5。

%% 精简 HTTP 头：仅保留少量常用头，避免上下文膨胀。
simplifyHeaders(Headers) when is_list(Headers) ->
    Keep = [<<"content-type">>, <<"content-length">>, <<"location">>,
            <<"server">>, <<"date">>],
    maps:from_list([{string:lowercase(K), V}
                    || {K, V} <- Headers,
                       lists:member(string:lowercase(K), Keep)]);
simplifyHeaders(_) ->
    #{}.

%% 在 abstract forms 中查找指定函数名/元数的 form，未找到返回 {error, functionNotFound}。
findFunctionForms(Forms, Fun, Arity) ->
    Matches = [F || F <- Forms,
                    case erl_syntax:type(F) of
                        function ->
                            Name = erl_syntax:function_name(F),
                            erl_syntax:atom_value(Name) =:= Fun
                                andalso erl_syntax:function_arity(F) =:= Arity;
                        _ ->
                            false
                    end],
    case Matches of
        [] -> {error, functionNotFound};
        _ -> {ok, Matches}
    end.

%% 按 attribute tag（type | opaque | callback | record | spec）收集符号信息。
%% 返回 `#{name, arity, line, source}' 列表；arity 对 type/opaque/record 为
%% undefined（无 arity 概念），对 callback/spec 为函数元数。
collectAttrForms(Forms, Tag) ->
    lists:foldl(fun(F, Acc) -> collectOneAttr(F, Tag, Acc) end, [], Forms).

collectOneAttr({attribute, Anno, Tag, Value}, Tag, Acc) ->
    Line = annoLine(Anno),
    Source = formSource({attribute, Anno, Tag, Value}),
    Entry = case {Tag, Value} of
        {spec, {{Name, Arity}, _TypeSpec}} ->
            #{name => Name, arity => Arity, line => Line, source => Source};
        %% OTP 常见：{{Name, Arity}, [FunType,...]}（与 -spec 同形）
        {callback, {{Name, Arity}, _TypeSpec}} ->
            #{name => Name, arity => Arity, line => Line, source => Source};
        %% 兼容旧形：{Name, FunType}
        {callback, {Name, TypeSpec}} when is_atom(Name) ->
            #{name => Name, arity => callbackArity(TypeSpec),
              line => Line, source => Source};
        {Tag, {Name, _TypeDef, Args}} when Tag =:= type; Tag =:= opaque ->
            #{name => Name, arity => typeArity(Args), line => Line, source => Source};
        {record, {Name, Fields}} when is_list(Fields) ->
            #{name => Name, arity => undefined, line => Line, source => Source,
              fieldCount => length(Fields)};
        {record, {Name, _Fields}} ->
            #{name => Name, arity => undefined, line => Line, source => Source};
        _ ->
            #{name => undefined, arity => undefined, line => Line, source => Source}
    end,
    Acc ++ [Entry];
collectOneAttr(_, _Tag, Acc) ->
    Acc.

%% 从 callback 的 TypeSpec 推断元数：`{'fun',_,{type,_,'fun',[{type,_,product,Args},_]}}'
%% → length(Args)；无法识别时返回 undefined。
callbackArity({'fun', _Anno, {type, _, 'fun', [{type, _, product, Args} | _]}}) ->
    length(Args);
callbackArity({'fun', _Anno, {type, _, bounded_fun, [Inner | _]}}) ->
    callbackArity(Inner);
callbackArity([Inner | _]) ->
    callbackArity(Inner);
callbackArity(_) ->
    undefined.

%% -type/-opaque 的类型参数个数。
typeArity(Args) when is_list(Args) -> length(Args);
typeArity(_) -> undefined.

%% 安全取 erl_anno 的行号：旧版 anno 为整数，新版为 anno record。
annoLine(Anno) when is_integer(Anno) -> Anno;
annoLine(Anno) ->
    try erl_anno:line(Anno) catch _:_ -> undefined end.

%% 用 erl_pp 格式化单个 form 为 binary；失败时回退为 pretty-print 原始 term。
formSource(Form) ->
    try
        unicode:characters_to_binary(lists:flatten(erl_pp:form(Form)))
    catch _:_ ->
        iolist_to_binary(io_lib:format("~p.", [Form]))
    end.

%% 将路径解析为绝对路径并校验：必须位于允许的项目子树下，且不命中
%% 敏感/构建产物黑名单（.git/_build/node_modules/.rebar3/erts）。
%% 黑名单叠加在 allowlist 之上，避免"根在允许列表里 → 任意子路径可达"
%% 的失效策略。
%%
%% 注意：本函数用于「写/改」路径校验（writeFile / patch）。
%% Web 浏览与 readFile 走 {@link resolveReadablePath/1}（可看整个 projectRoot）。
resolveAllowedPath(Path) ->
    Root = normalizeAbs(alConfig:projectRoot()),
    Abs = normalizeAbs(filename:absname(toList(Path), Root)),
    Allowed = maps:get(allowedRoots, alConfig:get(patch, #{}), ["src", "config", "priv"]),
    AllowedAbs = [normalizeAbs(filename:absname(filename:join(Root, toList(A)))) || A <- Allowed],
    %% "." / 项目根：映射为第一个 allowedRoot（通常 src），禁止整树任意路径。
    EffectiveAbs = case Abs =:= Root of
        true when AllowedAbs =/= [] -> hd(AllowedAbs);
        _ -> Abs
    end,
    UnderAllowed = lists:any(fun(AllowedRoot) -> isSubpath(AllowedRoot, EffectiveAbs) end,
                             AllowedAbs),
    case UnderAllowed andalso not pathDenied(EffectiveAbs) of
        true -> {ok, EffectiveAbs};
        false -> {error, pathNotAllowed}
    end.

%% 只读路径：projectRoot 下除黑名单/敏感文件外均可读（含 include/test/c_src/README）。
%% 与 resolveAllowedPath 分离：浏览宽、写入窄。
resolveReadablePath(Path) ->
    Root = normalizeAbs(alConfig:projectRoot()),
    Abs = normalizeAbs(filename:absname(toList(Path), Root)),
    case isSubpath(Root, Abs) andalso not pathDenied(Abs) of
        true -> {ok, Abs};
        false -> {error, pathNotAllowed}
    end.

%% 路径是否命中忽略/敏感段：目录段走 core.indexIgnore；basename 另拦密钥文件。
pathDenied(Abs) ->
    Ignore = [string:lowercase(toList(N)) || N <- alConfig:indexIgnoreNames()],
    Comps = [string:lowercase(C) || C <- filename:split(Abs)],
    lists:any(fun(Seg) -> lists:member(Seg, Ignore) end, Comps)
        orelse isSensitiveBasename(Abs).

%% 即使位于可浏览树下，仍禁止直接读密钥配置（不进 indexIgnore，固定安全策略）。
isSensitiveBasename(Abs) ->
    Base = string:lowercase(filename:basename(Abs)),
    lists:member(Base, ["alicfg.cfg", ".env", "credentials.json",
                        "erl_crash.dump", "rebar3.crashdump"])
        orelse lists:suffix(".env", Base)
        orelse lists:suffix(".pem", Base)
        orelse lists:suffix(".key", Base)
        orelse lists:suffix(".secret", Base).

isIgnoredPath(Path, IgnoreNames) ->
    Parts = filename:split(normalizeAbs(Path)),
    lists:any(fun(Ig) ->
        IgL = string:lowercase(toList(Ig)),
        lists:any(fun(P) -> string:lowercase(P) =:= IgL end, Parts)
    end, IgnoreNames).

relativeToRoot(Path) ->
    RootParts = filename:split(normalizeAbs(alConfig:projectRoot())),
    PathParts = filename:split(normalizeAbs(Path)),
    RootL = [string:lowercase(P) || P <- RootParts],
    PathL = [string:lowercase(P) || P <- PathParts],
    case lists:prefix(RootL, PathL) of
        true ->
            Rel = lists:nthtail(length(RootParts), PathParts),
            case Rel of
                [] -> ".";
                _ -> filename:join(Rel)
            end;
        false ->
            normalizeAbs(Path)
    end.

%% Collapse "." / ".." so "f:/ali/." and "f:/ali" compare equal.
%% Also strip Windows extended-length prefixes (`\\?\` / `//?/`) from
%% index paths like `//?/f:/ali/src/...` which otherwise become `f:ali/...`.
normalizeAbs(Path) ->
    Parts = filename:split(filename:absname(stripWinLongPrefix(toList(Path)))),
    filename:join(collapseParts(Parts, [])).

%% Windows long-path / UNC device prefix → normal drive or UNC path.
stripWinLongPrefix(Path) when is_list(Path) ->
    case Path of
        [$\\, $\\, $? , $\\, $U, $N, $C, $\\ | Rest] -> "\\\\" ++ Rest;
        [$/, $/, $?, $/, $U, $N, $C, $/ | Rest] -> "//" ++ Rest;
        [$\\, $\\, $? , $\\ | Rest] -> Rest;
        [$/, $/, $?, $/ | Rest] -> Rest;
        [$\\, $\\, $? , $/ | Rest] -> Rest;
        _ -> Path
    end;
stripWinLongPrefix(Path) ->
    stripWinLongPrefix(toList(Path)).

collapseParts(["." | Rest], Acc) ->
    collapseParts(Rest, Acc);
collapseParts([".." | Rest], []) ->
    collapseParts(Rest, []);
collapseParts([".." | Rest], [_Top | Acc]) ->
    collapseParts(Rest, Acc);
collapseParts([Part | Rest], Acc) ->
    collapseParts(Rest, [Part | Acc]);
collapseParts([], []) ->
    ["."];
collapseParts([], Acc) ->
    lists:reverse(Acc).

%% 判断 Path 是否在 Root 目录下（大小写不敏感；按 path 分量比较）。
isSubpath(Root, Path) ->
    RootParts = [string:lowercase(P) || P <- filename:split(normalizeAbs(Root))],
    PathParts = [string:lowercase(P) || P <- filename:split(normalizeAbs(Path))],
    lists:prefix(RootParts, PathParts).

%% 读取配置中的文件读取最大字节数，默认 1MB。
defaultMaxBytes() ->
    case alConfig:limit(toolReadFileMaxBytes) of
        N when is_integer(N), N > 0 -> N;
        _ -> 1048576
    end.

%% 将各种类型转为 binary。
toBinary(B) when is_binary(B) -> B;
toBinary(L) when is_list(L) -> unicode:characters_to_binary(L);
toBinary(A) when is_atom(A) -> atom_to_binary(A, utf8);
toBinary(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).

%% 将 binary/list 转为 atom，只允许已存在 atom，避免原子表泄漏。
toAtom(B) when is_atom(B) -> B;
toAtom(B) when is_binary(B) ->
    try binary_to_existing_atom(B, utf8) catch _:_ -> undefined end;
toAtom(L) when is_list(L) ->
    try list_to_existing_atom(L) catch _:_ -> undefined end.

%%--------------------------------------------------------------------
%% @doc
%% 将值安全转换为 atom：仅复用已存在 atom，绝不新建
%% （LLM 工具入参常为字符串，避免 atom 表膨胀）。
%%
%% @param A atom | binary | list
%% @return `{ok, Atom}' | `error'
%% @end
%%--------------------------------------------------------------------
ensureAtom(A) when is_atom(A) -> {ok, A};
ensureAtom(B) when is_binary(B), B =/= <<>> ->
    try {ok, binary_to_existing_atom(B, utf8)}
    catch
        _:_ -> error
    end;
ensureAtom(L) when is_list(L), L =/= [] ->
    ensureAtom(unicode:characters_to_binary(L));
ensureAtom(_) ->
    error.

%% 将 binary/list/integer 转为 integer，转换失败返回 0。
toInteger(I) when is_integer(I) -> I;
toInteger(B) when is_binary(B) ->
    try binary_to_integer(B) catch _:_ -> 0 end;
toInteger(L) when is_list(L) ->
    try list_to_integer(L) catch _:_ -> 0 end;
toInteger(_) -> 0.

%%--------------------------------------------------------------------
%% @doc 当文件不存在时，根据文件名在项目中搜索相似路径作为建议。
%% @param Path 原始路径
%% @return binary 路径列表（最多 5 个），排除 _build 目录
%% @end
%%--------------------------------------------------------------------
suggestPaths(Path) ->
    Base = filename:basename(toList(Path)),
    case Base =:= "" orelse Base =:= "." orelse Base =:= ".." of
        true ->
            [];
        false ->
            %% 直接走文件系统通配（core 索引不提供按文件名查找）。
            suggestFromWildcard(Base)
    end.

suggestFromWildcard(Base) ->
    Root = alConfig:projectRoot(),
    %% 大仓库全树 ** 易卡死；只扫常见源码目录。
    Roots = [filename:join(Root, D) || D <- ["plugin", "src", "apps", "lib"],
             filelib:is_dir(filename:join(Root, D))],
    ScanRoots = case Roots of [] -> [Root]; _ -> Roots end,
    Matches = lists:flatmap(fun(R) ->
        filelib:wildcard(filename:join([R, "**", Base]))
    end, ScanRoots),
    Prefer = [M || M <- Matches, not isBuildPath(M)],
    Use = case Prefer of [] -> Matches; _ -> Prefer end,
    Rel = [relpath(Root, M) || M <- lists:sublist(Use, 5)],
    [unicode:characters_to_binary(R) || R <- Rel].

%% 判断路径是否包含 _build 目录（排除构建产物）。
isBuildPath(Path) ->
    P = string:lowercase(filename:absname(Path)),
    string:find(P, "\\_build\\") =/= nomatch
        orelse string:find(P, "/_build/") =/= nomatch.

%% 将绝对路径转为相对于 Root 的相对路径。
relpath(Root, Abs) ->
    R = filename:absname(Root),
    A = filename:absname(Abs),
    case string:prefix(A, R) of
        nomatch -> A;
        "/" ++ Rest -> Rest;
        "\\" ++ Rest -> Rest;
        Rest -> string:trim(Rest, leading, "/\\")
    end.

%% 将各种类型转为 list。
toList(B) when is_binary(B) -> unicode:characters_to_list(B);
toList(L) when is_list(L) -> L;
toList(A) when is_atom(A) -> atom_to_list(A);
toList(X) -> lists:flatten(io_lib:format("~p", [X])).
