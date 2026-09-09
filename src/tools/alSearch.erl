%%%-------------------------------------------------------------------
%% @doc 文本搜索：优先 ripgrep，回退到 Erlang 并行读。
%% @end
%%%-------------------------------------------------------------------

-module(alSearch).

-export([search/3, search/4, search/5, backend/0, resolvePath/2]).
%% 测试导出
-export([searchScopeFiles/2]).

-define(SearchMaxFileBytes, 1048576).

%%--------------------------------------------------------------------
%% @doc
%% 获取文本搜索后端：从配置读取 backend 字段，默认为 rg，
%% 其他值（如 erlang）使用纯 Erlang 实现
%%
%% @return rg | erlang
%% @end
%%--------------------------------------------------------------------
-spec backend() -> rg | erlang.
backend() ->
    TextCfg = alConfig:get(textSearch, #{}),
    case maps:get(backend, TextCfg, rg) of
        rg -> rg;
        _ -> erlang
    end.

%%--------------------------------------------------------------------
%% @doc
%% 在项目根目录下搜索文本（3 参数版本，自动获取项目根目录）
%%
%% @param Query 查询字符串
%% @param SubPath 相对项目根的搜索子路径
%% @param MaxResults 最大返回结果数
%% @return {ok, Matches} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec search(binary(), binary(), pos_integer()) -> {ok, [map()]} | {error, term()}.
search(Query, SubPath, MaxResults) ->
    Root = unicode:characters_to_binary(alConfig:projectRoot()),
    search(Root, SubPath, Query, MaxResults, 0).

%%--------------------------------------------------------------------
%% @doc
%% 在指定根目录下搜索文本（4 参数版本）；
%% 优先使用 rg 后端，失败则回退到 Erlang 实现
%%
%% @param Root 项目根路径
%% @param SubPath 相对根的搜索子路径
%% @param QueryBin 查询字符串（二进制）
%% @param MaxResults 最大返回结果数
%% @return {ok, Matches} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec search(binary(), binary(), binary(), pos_integer()) ->
    {ok, [map()]} | {error, term()}.
search(Root, SubPath, QueryBin0, MaxResults) ->
    search(Root, SubPath, QueryBin0, MaxResults, 0).

-spec search(binary(), binary(), binary(), pos_integer(), non_neg_integer()) ->
    {ok, [map()]} | {error, term()}.
search(Root, SubPath, QueryBin0, MaxResults, ContextLines) ->
    QueryBin = normalizeQuery(QueryBin0),
    Ctx = clampContext(ContextLines),
    case QueryBin of
        <<>> ->
            {error, emptyQuery};
        _ ->
            Timeout = textSearchTimeoutMs(),
            Result = case backend() of
                rg ->
                    case searchRg(Root, SubPath, QueryBin, MaxResults, Timeout, Ctx) of
                        {ok, Ms} ->
                            {ok, Ms};
                        {error, rgNotFound} ->
                            searchErlang(Root, SubPath, QueryBin, MaxResults, Timeout, Ctx);
                        {error, timeout} ->
                            {error, #{reason => searchTimeout, backend => rg, timeoutMs => Timeout}};
                        {error, Reason} ->
                            {error, Reason}
                    end;
                _ ->
                    searchErlang(Root, SubPath, QueryBin, MaxResults, Timeout, Ctx)
            end,
            case Result of
                {ok, Matches} ->
                    {ok, enrichMatchesWithContext(Root, Matches, Ctx)};
                Other ->
                    Other
            end
    end.

clampContext(N) when is_integer(N), N > 0 -> min(N, 10);
clampContext(_) -> 0.

%% 统一成 binary；空白-only 视为空查询。
normalizeQuery(Q) when is_binary(Q) ->
    string:trim(Q);
normalizeQuery(Q) when is_list(Q) ->
    try unicode:characters_to_binary(Q) of
        B when is_binary(B) -> string:trim(B);
        _ -> <<>>
    catch
        _:_ -> <<>>
    end;
normalizeQuery(_) ->
    <<>>.

%%--------------------------------------------------------------------
%% @doc
%% 获取文本搜索超时（毫秒），默认 5000ms
%%
%% @return 超时毫秒
%% @end
%%--------------------------------------------------------------------
textSearchTimeoutMs() ->
    TextCfg = alConfig:get(textSearch, #{}),
    case maps:get(timeoutMs, TextCfg, 5000) of
        N when is_integer(N), N > 0 -> N;
        _ -> 5000
    end.

%%--------------------------------------------------------------------
%% @doc
%% 使用 ripgrep (rg) 进行搜索：解析子路径、构造参数、启动 port、
%% 收集输出并解析 JSON 结果
%%
%% @param Root 项目根路径
%% @param SubPath 搜索子路径
%% @param QueryBin 查询字符串
%% @param MaxResults 最大结果数
%% @param TimeoutMs 超时毫秒
%% @return {ok, Matches} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
searchRg(Root, SubPath, QueryBin, MaxResults, TimeoutMs, _Ctx) ->
    case os:find_executable("rg") of
        false ->
            {error, rgNotFound};
        RgPath ->
            case resolveSearchDir(Root, SubPath) of
                {ok, AbsDir} ->
                    Args = rgArgs(QueryBin, AbsDir, MaxResults),
                    Port = open_port(
                        {spawn_executable, RgPath},
                        [binary, exit_status, hide, eof, {args, Args}]
                    ),
                    case collectPort(Port, <<>>, erlang:monotonic_time(millisecond), TimeoutMs) of
                        {ok, Output} ->
                            {ok, parseRgJson(Output, Root, MaxResults)};
                        Err ->
                            Err
                    end;
                Err ->
                    Err
            end
    end.

%% rg 参数：限制扩展名/体积，并排除 _build/.git/logs 等（复用 indexIgnore）。
rgArgs(QueryBin, AbsDir, MaxResults) ->
    IgnoreArgs = lists:append([["--glob", "!" ++ Pat] || Pat <- ignoreGlobPatterns()]),
    TypeArgs = [
        "--glob", "*.{erl,hrl,cfg,c,h,rs,md,json,proto,txt}",
        "--max-filesize", "1M"
    ],
    IgnoreArgs ++ TypeArgs ++ [
        "--json",
        "--max-count", integer_to_list(MaxResults),
        "--",
        unicode:characters_to_list(QueryBin),
        AbsDir
    ].

ignoreGlobPatterns() ->
    Names = ignoreDirNames(),
    lists:append([
        ["**/" ++ Name ++ "/**", Name ++ "/**"]
     || Name <- Names
    ]).

ignoreDirNames() ->
    TextCfg = alConfig:get(textSearch, #{}),
    case maps:get(ignore, TextCfg, undefined) of
        undefined -> alConfig:indexIgnoreNames();
        <<>> -> alConfig:indexIgnoreNames();
        "" -> alConfig:indexIgnoreNames();
        S ->
            [string:trim(P) || P <- string:tokens(toList(S), ",;"),
                               string:trim(P) =/= ""]
    end.
%%--------------------------------------------------------------------
%% @doc
%% 收集 port 输出：循环接收 data 消息累积到 Acc，
%% 超时则关闭 port 返回 {error, timeout}；
%% eof/exit_status 表示结束，0/1 视为成功
%%
%% @param Port 已打开的 port
%% @param Acc 当前累积输出
%% @param StartMs 起始时间戳（毫秒）
%% @param TimeoutMs 超时毫秒
%% @return {ok, Acc} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
collectPort(Port, Acc, StartMs, TimeoutMs) ->
    Now = erlang:monotonic_time(millisecond),
    Remaining = max(0, TimeoutMs - (Now - StartMs)),
    case Remaining =:= 0 of
        true ->
            try port_close(Port) catch _:_ -> ok end,
            {error, timeout};
        false ->
            receive
                {Port, {data, Data}} ->
                    collectPort(Port, <<Acc/binary, Data/binary>>, StartMs, TimeoutMs);
                {Port, eof} ->
                    receive
                        {Port, {exit_status, Status}} ->
                            case Status of
                                0 -> {ok, Acc};
                                1 -> {ok, Acc};
                                _ -> {error, {rgExit, Status}}
                            end
                    after 1000 ->
                        %% eof 后等 exit_status 超时：port 仍可能未关闭，
                        %% 显式 port_close 兜底，避免 port 句柄泄漏（Windows 上
                        %% 更易留下孤儿进程或句柄）。
                        try port_close(Port) catch _:_ -> ok end,
                        {ok, Acc}
                    end;
                {Port, {exit_status, Status}} ->
                    case Status of
                        0 -> {ok, Acc};
                        1 -> {ok, Acc};
                        _ -> {error, {rgExit, Status}}
                    end
            after Remaining ->
                try port_close(Port) catch _:_ -> ok end,
                {error, timeout}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 解析 rg 的 JSON 输出（每行一个 JSON 对象），
%% 提取 type=match 的记录并转换为统一的匹配项 map
%%
%% @param Bin rg 输出二进制
%% @param Root 项目根路径
%% @param MaxResults 最大结果数
%% @return 匹配项列表
%% @end
%%--------------------------------------------------------------------
parseRgJson(Bin, Root, MaxResults) ->
    Lines = binary:split(Bin, <<"\n">>, [global, trim_all]),
    Matches = lists:filtermap(
        fun(Line) ->
            case byte_size(Line) of
                0 ->
                    false;
                _ ->
                    try alJson:decode(Line) of
                        #{<<"type">> := <<"match">>, <<"data">> := Data} ->
                            Path = rgTextField(maps:get(<<"path">>, Data, <<>>)),
                            LinesMap = maps:get(<<"lines">>, Data, #{}),
                            Text = rgTextField(maps:get(<<"text">>, LinesMap, <<>>)),
                            LineNo = maps:get(<<"line_number">>, Data, 0),
                            Rel = relativeFromRoot(Root, Path),
                            {true, #{file => Rel, line => LineNo, text => trimLine(Text)}};
                        _ ->
                            false
                    catch
                        _:_ ->
                            false
                    end
            end
        end,
        Lines
    ),
    lists:sublist(Matches, MaxResults).

%% rg --json 的 path/text 可能是 binary，也可能是 #{<<"text">> => Bin}。
rgTextField(Bin) when is_binary(Bin) -> Bin;
rgTextField(Map) when is_map(Map) ->
    maps:get(<<"text">>, Map, maps:get(text, Map, <<>>));
rgTextField(List) when is_list(List) ->
    unicode:characters_to_binary(List);
rgTextField(_) ->
    <<>>.

%% 去除行尾的 \r\n 字符
trimLine(Bin) ->
    re:replace(Bin, <<"[\\r\\n]+$">>, <<>>, [{return, binary}, global]).

%%--------------------------------------------------------------------
%% @doc
%% 使用纯 Erlang 实现进行搜索：先列出搜索范围内的文本文件，
%% 再并行扫描文件内容
%%
%% @param Root 项目根路径
%% @param SubPath 搜索子路径
%% @param QueryBin 查询字符串
%% @param MaxResults 最大结果数
%% @return {ok, Matches} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
searchErlang(Root, SubPath, QueryBin, MaxResults, TimeoutMs, _Ctx) ->
    Start = erlang:monotonic_time(millisecond),
    case searchScopeFiles(Root, SubPath) of
        {ok, Files} ->
            Elapsed = erlang:monotonic_time(millisecond) - Start,
            Remain = max(200, TimeoutMs - Elapsed),
            TextFiles = [F || F <- Files, isTextFile(F)],
            {ok, searchFilesParallel(Root, TextFiles, QueryBin, MaxResults, Remain)};
        Err ->
            Err
    end.

%% 解析搜索目录：委托给 resolvePath
resolveSearchDir(Root, SubPath) ->
    resolvePath(Root, SubPath).

%% 将绝对路径转换为相对根的二进制路径
relativeFromRoot(Root, Path) ->
    unicode:characters_to_binary(relativePath(Root, Path)).

%%--------------------------------------------------------------------
%% @doc
%% 列出搜索范围内的所有文件（相对路径形式）
%%
%% @param Root 项目根路径
%% @param SubPath 搜索子路径
%% @return {ok, Files} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
searchScopeFiles(Root, SubPath) ->
    case resolvePath(Root, SubPath) of
        {ok, AbsDir} ->
            case filelib:is_dir(AbsDir) of
                true ->
                    All = collectFiles(AbsDir),
                    Files = [relativePath(Root, F) || F <- lists:sort(All)],
                    {ok, Files};
                false ->
                    %% 模型常把单文件路径传给 searchText；降级为搜该文件
                    case filelib:is_regular(AbsDir) of
                        true ->
                            {ok, [relativePath(Root, AbsDir)]};
                        false ->
                            {error, notADirectory}
                    end
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% 递归收集目录下所有文件（入口）
collectFiles(Dir) ->
    collectFiles(Dir, []).

%%--------------------------------------------------------------------
%% @doc
%% 递归收集目录下所有文件：遍历子目录，遇到文件加入累加器
%%
%% @param Dir 当前目录
%% @param Acc 累加器
%% @return 文件路径列表
%% @end
%%--------------------------------------------------------------------
collectFiles(Dir, Acc) ->
    Ignore = ignoreDirNames(),
    collectFiles(Dir, Acc, Ignore).

collectFiles(Dir, Acc, Ignore) ->
    case file:list_dir(Dir) of
        {ok, Names} ->
            lists:foldl(
                fun(Name, Files) ->
                    case lists:member(Name, Ignore) of
                        true ->
                            Files;
                        false ->
                            Path = filename:join(Dir, Name),
                            case filelib:is_dir(Path) of
                                true -> collectFiles(Path, Files, Ignore);
                                false -> [Path | Files]
                            end
                    end
                end,
                Acc,
                Names
            );
        {error, _} ->
            Acc
    end.

%%--------------------------------------------------------------------
%% @doc
%% 并行扫描多个文件：按调度器数量拆分批次，每个批次由一个 worker 进程处理，
%% 主进程收集结果并截取 MaxResults 条
%%
%% @param Root 项目根路径
%% @param Files 待扫描文件列表（相对路径）
%% @param Query 查询字符串
%% @param MaxResults 最大结果数
%% @return 匹配项列表
%% @end
%%--------------------------------------------------------------------
searchFilesParallel(Root, Files, Query, MaxResults, TimeoutMs) ->
    case Files of
        [] ->
            [];
        _ ->
            Workers = erlang:max(1, erlang:system_info(schedulers)),
            Parent = self(),
            Ref = make_ref(),
            Batches = splitBatches(Files, Workers),
            Pids = [
                spawn(fun() -> searchWorker(Root, Batch, Query, Parent, Ref) end)
             || Batch <- Batches, Batch =/= []
            ],
            Start = erlang:monotonic_time(millisecond),
            Matches = collectMatches(Pids, Ref, MaxResults, [], Start, TimeoutMs),
            sortMatches(Matches, MaxResults)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 搜索 worker 进程：扫描分配到的文件列表，
%% 每个文件读取后调用 searchLines 查找匹配，结果汇总后发给父进程
%%
%% @param Root 项目根路径
%% @param Files 待扫描文件列表（相对路径）
%% @param Query 查询字符串
%% @param Parent 父进程 PID
%% @param Ref 本次搜索的唯一引用
%% @end
%%--------------------------------------------------------------------
searchWorker(Root, Files, Query, Parent, Ref) ->
    Results = lists:filtermap(
        fun(RelPath) ->
            Abs = filename:join(toList(Root), toList(RelPath)),
            try filelib:file_size(Abs) of
                Size when Size =< ?SearchMaxFileBytes ->
                    case file:read_file(Abs) of
                        {ok, Bin} ->
                            searchLines(Root, RelPath, Bin, Query);
                        _ ->
                            false
                    end;
                _ ->
                    false
            catch
                _:_ ->
                    false
            end
        end,
        Files
    ),
    Parent ! {Ref, self(), lists:append(Results)}.

%%--------------------------------------------------------------------
%% @doc
%% 在单个文件内容中查找匹配行：按 \n 切分行后逐行匹配
%%
%% @param Root 项目根路径
%% @param RelPath 文件相对路径
%% @param Bin 文件内容二进制
%% @param Query 查询字符串
%% @return {true, Matches} 或 false
%% @end
%%--------------------------------------------------------------------
searchLines(_Root, _RelPath, _Bin, <<>>) ->
    %% 防御：空 pattern 会使 binary:match badarg，拖垮 searchWorker
    false;
searchLines(Root, RelPath, Bin, Query) when is_binary(Query), byte_size(Query) > 0 ->
    Lines = binary:split(Bin, <<"\n">>, [global]),
    searchLines(Root, RelPath, Lines, Query, 1, []);
searchLines(_Root, _RelPath, _Bin, _Query) ->
    false.

%%--------------------------------------------------------------------
%% @doc
%% 递归扫描行列表：匹配则加入结果，未匹配继续下一行；
%% 全部扫描完后返回结果（无匹配返回 false）
%%
%% @param Root 项目根路径
%% @param RelPath 文件相对路径
%% @param Lines 行列表
%% @param Query 查询字符串
%% @param LineNo 当前行号
%% @param Acc 累加器
%% @return {true, Matches} 或 false
%% @end
%%--------------------------------------------------------------------
searchLines(_Root, _RelPath, [], _Query, _LineNo, Acc) ->
    case Acc of
        [] -> false;
        _ -> {true, Acc}
    end;
searchLines(Root, RelPath, [Line | Rest], Query, LineNo, Acc)
  when is_binary(Query), byte_size(Query) > 0 ->
    case binary:match(Line, Query) of
        nomatch ->
            searchLines(Root, RelPath, Rest, Query, LineNo + 1, Acc);
        _ ->
            Match = #{
                file => relativeFromRoot(Root, RelPath),
                line => LineNo,
                text => trimLine(Line)
            },
            searchLines(Root, RelPath, Rest, Query, LineNo + 1, [Match | Acc])
    end;
searchLines(_Root, _RelPath, _Lines, _Query, _LineNo, Acc) ->
    case Acc of
        [] -> false;
        _ -> {true, Acc}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 收集 worker 进程的搜索结果：每收到一批就累加并截取 Max 条；
%% 达到上限时终止剩余 worker；30s 超时强制终止所有 worker
%%
%% @param Pids 待收集的 worker PID 列表
%% @param Ref 本次搜索的唯一引用
%% @param Max 最大结果数
%% @param Acc 累加器
%% @return 匹配项列表
%% @end
%%--------------------------------------------------------------------
collectMatches([], _Ref, _Max, Acc, _Start, _TimeoutMs) ->
    Acc;
collectMatches(Pids, Ref, Max, Acc, Start, TimeoutMs) ->
    Now = erlang:monotonic_time(millisecond),
    Remain = max(0, TimeoutMs - (Now - Start)),
    case Remain =:= 0 of
        true ->
            [exit(P, kill) || P <- Pids],
            Acc;
        false ->
            receive
                {Ref, Pid, Batch} ->
                    NewAcc = lists:sublist(Acc ++ Batch, Max),
                    Remaining = lists:delete(Pid, Pids),
                    case length(NewAcc) >= Max of
                        true ->
                            [exit(P, kill) || P <- Remaining],
                            NewAcc;
                        false ->
                            collectMatches(Remaining, Ref, Max, NewAcc, Start, TimeoutMs)
                    end
            after Remain ->
                [exit(P, kill) || P <- Pids],
                Acc
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 对匹配结果按文件名和行号升序排序，并截取 MaxResults 条
%%
%% @param Matches 匹配项列表
%% @param MaxResults 最大结果数
%% @return 排序后的匹配项列表
%% @end
%%--------------------------------------------------------------------
sortMatches(Matches, MaxResults) ->
    Sorted = lists:sort(
        fun(#{file := F1, line := L1}, #{file := F2, line := L2}) ->
            case F1 =:= F2 of
                true -> L1 =< L2;
                false -> F1 =< F2
            end
        end,
        Matches
    ),
    lists:sublist(Sorted, MaxResults).

%%--------------------------------------------------------------------
%% @doc
%% 将列表均匀拆分为 N 个批次（N <= 1 时返回单批）
%%
%% @param List 待拆分列表
%% @param N 批次数
%% @return 批次列表
%% @end
%%--------------------------------------------------------------------
splitBatches(List, N) when N =< 1 ->
    [List];
splitBatches(List, N) ->
    Len = length(List),
    BatchSize = (Len + N - 1) div N,
    splitBatches(List, BatchSize, []).

%% 递归切分批次：每批 BatchSize 个，剩余不足时取完
splitBatches([], _Size, Acc) ->
    lists:reverse(Acc);
splitBatches(List, Size, Acc) ->
    {Batch, Rest} = lists:split(erlang:min(Size, length(List)), List),
    splitBatches(Rest, Size, [Batch | Acc]).

%%--------------------------------------------------------------------
%% @doc
%% 根据扩展名判断文件是否为可搜索的文本文件
%%
%% @param Path 文件路径
%% @return boolean()
%% @end
%%--------------------------------------------------------------------
isTextFile(Path) ->
    Ext = filename:extension(Path),
    lists:member(string:lowercase(Ext), [".erl", ".hrl", ".cfg", ".c", ".h", ".rs", ".md", ".txt", ".json", ".yml", ".yaml", ".toml", ".ex", ".exs"]).

%%--------------------------------------------------------------------
%% @doc
%% 解析搜索路径：相对于 Root 计算绝对路径，并验证文件或目录存在
%%
%% @param Root 项目根路径
%% @param SubPath 相对子路径
%% @return {ok, AbsPath} 或 {error, notFound}
%% @end
%%--------------------------------------------------------------------
resolvePath(Root, SubPath) ->
    RootList = toList(Root),
    SubList = toList(SubPath),
    %% 绝对路径会绕过 Root（filename:absname 忽略 Dir），一律拒绝。
    case filename:pathtype(SubList) of
        absolute ->
            {error, outsideRoot};
        _ ->
            Abs = filename:absname(SubList, RootList),
            case isSubpathOf(RootList, Abs) of
                false ->
                    %% `..' 逃逸 / 反斜杠拼接等使结果跳出项目根 → 拒绝
                    {error, outsideRoot};
                true ->
                    case filelib:is_regular(Abs) orelse filelib:is_dir(Abs) of
                        true -> {ok, Abs};
                        false -> {error, notFound}
                    end
            end
    end.

%% 分量级 prefix 校验：Abs 规范化后必须仍在 Root 子树内（大小写不敏感，
%% 折叠 "." / ".."，防 `../` 或目录拼接逃逸）。
isSubpathOf(Root, Abs) ->
    RootParts = normalizePathParts(Root),
    AbsParts = normalizePathParts(Abs),
    lists:prefix(RootParts, AbsParts).

%% 规范化路径分量：absname 解析后折叠 "." / ".."，统一小写比较。
normalizePathParts(Path) ->
    Parts = filename:split(filename:absname(toList(Path))),
    [string:lowercase(P) || P <- collapseDots(Parts, [])].

collapseDots(["." | Rest], Acc) ->
    collapseDots(Rest, Acc);
collapseDots([".." | Rest], []) ->
    collapseDots(Rest, []);
collapseDots([".." | Rest], [_Top | Acc]) ->
    collapseDots(Rest, Acc);
collapseDots([Part | Rest], Acc) ->
    collapseDots(Rest, [Part | Acc]);
collapseDots([], Acc) ->
    lists:reverse(Acc).

%%--------------------------------------------------------------------
%% @doc
%% 计算路径相对于 Root 的相对路径；不在 Root 下时返回原路径
%%
%% @param Root 项目根路径
%% @param Path 输入路径
%% @return 相对路径字符串
%% @end
%%--------------------------------------------------------------------
relativePath(Root, Path) ->
    RootBin = toList(Root),
    PathList = toList(Path),
    AbsPath = filename:absname(PathList),
    case lists:prefix(RootBin, AbsPath) of
        true ->
            string:trim(string:slice(AbsPath, length(RootBin)), leading, [$/, $\\]);
        false ->
            PathList
    end.

%%--------------------------------------------------------------------
%% @doc
%% 将值转换为列表：二进制转 unicode 列表，列表原样返回
%%
%% @param B 输入值
%% @return 列表
%% @end
%%--------------------------------------------------------------------
toList(B) when is_binary(B) -> unicode:characters_to_list(B);
toList(L) when is_list(L) -> L.

%% 为每条命中附加多行 snippet（context 行数）；0 则原样返回。
enrichMatchesWithContext(_Root, Matches, 0) ->
    Matches;
enrichMatchesWithContext(Root, Matches, Ctx) when Ctx > 0 ->
    lists:map(fun(M) -> enrichOneMatch(Root, M, Ctx) end, Matches).

enrichOneMatch(Root, #{file := File, line := Line} = M, Ctx) when is_integer(Line), Line >= 1 ->
    Start = max(1, Line - Ctx),
    End = Line + Ctx,
    Path = case File of
        <<>> -> undefined;
        F -> resolveMatchPath(Root, F)
    end,
    case Path of
        undefined ->
            M;
        P ->
            case alToolsExt:readFile(#{path => P, startLine => Start, endLine => End,
                                     maxBytes => 48000}) of
                {ok, #{content := Snippet}} ->
                    M#{snippet => Snippet, contextLines => Ctx,
                       snippetStartLine => Start, snippetEndLine => End};
                _ ->
                    M
            end
    end;
enrichOneMatch(_Root, M, _Ctx) ->
    M.

%% 相对路径拼到搜索根；已是绝对路径则原样使用。
resolveMatchPath(Root, File) ->
    FileList = unicode:characters_to_list(File),
    case filename:pathtype(FileList) of
        absolute ->
            File;
        _ when Root =:= undefined; Root =:= <<>>; Root =:= "" ->
            File;
        _ ->
            filename:join(Root, File)
    end.
