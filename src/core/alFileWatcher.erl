%%%-------------------------------------------------------------------
%% @doc 项目文件变更监听器（轮询 mtime）。
%%
%% 通过定时扫描项目根目录下匹配 `indexExtensions` 的源文件 mtime，
%% 与上次快照对比，检测到任何新增/修改/删除时触发 `alCoreClient:indexAsync/1`
%% 异步重建索引。无文件系统事件依赖（不引入 fs/inotify 等 native 库）。
%%
%% 配置（`core` map）：
%% - `fileWatchEnabled`（默认 `false`）：是否启用文件监听
%% - `fileWatchIntervalMs`（默认 `30000`）：扫描间隔
%% - `indexExtensions` / `indexIgnore`：复用索引配置
%%
%% 启用时可在编辑器保存文件后自动让搜索/补全用上新内容，
%% 适用于开发期；生产环境建议关闭以节省 CPU。
%% @end
%%%-------------------------------------------------------------------

-module(alFileWatcher).

-behaviour(gen_server).

-include_lib("kernel/include/file.hrl").

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
%% 测试导出 —— 纯辅助函数
-export([parseList/1, diffChanged/2, snapshotToMap/1, pathMatchesAny/2, changedRoots/2]).

-define(DefaultIntervalMs, 30000).

-record(state, {
    roots :: [file:name()],
    intervalMs :: pos_integer(),
    extensions :: [binary()],
    ignore :: [binary()],
    snapshot = #{} :: #{binary() => non_neg_integer()}
}).

%%--------------------------------------------------------------------
%% @doc
%% 启动文件监听 gen_server。配置 `core.fileWatchEnabled = false` 时
%% 进程立即返回 `ignore`，不占用 supervisor 子进程槽位。
%%
%% @return {ok, Pid} | ignore | {error, Reason}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% @doc
%% 初始化：读取 core 配置，未启用时返回 `ignore` 让 supervisor 跳过；
%% 启用时构建首次快照并调度下一次扫描。
%%
%% @param [] 启动参数（空）
%% @return {ok, State} | ignore
%% @end
%%--------------------------------------------------------------------
init([]) ->
    Core = alConfig:get(core, #{}),
    case maps:get(fileWatchEnabled, Core, false) of
        false ->
            ignore;
        true ->
            Roots = alConfig:codeRoots(),
            IntervalMs = maps:get(fileWatchIntervalMs, Core, ?DefaultIntervalMs),
            ExtStr = maps:get(indexExtensions, Core, "erl,hrl,cfg,c,h,cc,cpp,hpp,rs"),
            IgnoreStr = alConfig:indexIgnoreCsv(),
            State = #state{
                roots = Roots,
                intervalMs = IntervalMs,
                extensions = parseList(ExtStr),
                ignore = parseList(IgnoreStr)
            },
            Initial = scanFiles(State),
            logger:info("alFileWatcher started for ~p, ~p files tracked",
                        [State#state.roots, map_size(Initial)]),
            erlang:send_after(IntervalMs, self(), scan),
            {ok, State#state{snapshot = Initial}}
    end.

%%--------------------------------------------------------------------
%% @doc 不接受同步调用，仅占位以符合 gen_server 行为。
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    {reply, {error, notSupported}, State}.

%%--------------------------------------------------------------------
%% @doc 不接受异步消息。
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @doc
%% 扫描定时器回调：重新扫描文件树，与上次快照对比，若有差异则触发
%% 异步索引；然后重新调度下一次扫描。
%%
%% @param scan 扫描消息
%% @end
%%--------------------------------------------------------------------
handle_info(scan, State) ->
    NewSnapshot = scanFiles(State),
    case diffChanged(State#state.snapshot, NewSnapshot) of
        [] ->
            ok;
        Changed ->
            logger:info("alFileWatcher detected ~p changed files, triggering reindex",
                        [length(Changed)]),
            %% alCoreClient 暂未提供 indexFiles(Changed) API（按文件粒度增量索引），
            %% 退一步：按有变更的 root 分组只索引该 root，避免无变更 root 全量重扫。
            RootsToIndex = changedRoots(Changed, State#state.roots),
            _ = alCoreClient:indexAsyncRoots(RootsToIndex),
            %% 文件变更：清 ETS + SQLite，避免 stale 摘要回填
            try alModuleSummary:invalidateAll() catch _:_ -> ok end,
            %% 轻量重建 Project Digest（不阻塞监听循环）
            _ = alAsync:run(fileWatcherDigestBuild, fun() ->
                %% 与全量 digest 共用 defaultOpts，避免轻量/全量双轨漂移
                alProjectDigest:build(#{})
            end)
    end,
    erlang:send_after(State#state.intervalMs, self(), scan),
    {noreply, State#state{snapshot = NewSnapshot}};
handle_info(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @doc 进程终止时无需特殊清理。
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%%===================================================================
%%% Internal helpers
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 扫描 State 中全部 codeRoots 下匹配文件，合并为 path → mtime 快照。
%%
%% @param State 当前状态
%% @return #{binary() => non_neg_integer()}
%% @end
%%--------------------------------------------------------------------
scanFiles(#state{roots = Roots, extensions = Exts, ignore = Ignore}) ->
    lists:foldl(
        fun(Root, Acc) ->
            maps:merge(Acc, scanOneRoot(Root, Exts, Ignore))
        end,
        #{},
        Roots
    ).

scanOneRoot(Root, Exts, Ignore) ->
    ExtRegex = extensionRegex(Exts),
    IgnoreSet = sets:from_list([toBinary(I) || I <- Ignore]),
    filelib:fold_files(
        Root,
        ExtRegex,
        true,
        fun(Path, Acc) ->
            BinPath = toBinary(Path),
            case pathMatchesAny(BinPath, IgnoreSet) of
                true -> Acc;
                false ->
                    case file:read_file_info(Path, [{time, posix}]) of
                        {ok, #file_info{mtime = Mtime}} when is_integer(Mtime) ->
                            Acc#{BinPath => Mtime};
                        _ ->
                            Acc
                    end
            end
        end,
        #{}
    ).

%%--------------------------------------------------------------------
%% @doc
%% 从 Changed 路径列表反查所属的 root 子集，只索引有变更的 root。
%% 路径前缀匹配（root 后接分隔符或完全相等），保证 root=`a/b` 不会误命中 `a/bc`。
%% 若所有变更路径都未归属到任何 root（罕见，例如 root 配置变更），返回全部 roots 兜底。
%%
%% @param Changed 变更路径列表（binary 绝对路径）
%% @param Roots   当前监听的 root 列表
%% @return 需要重建索引的 root 子集
%% @end
%%--------------------------------------------------------------------
changedRoots(Changed, Roots) ->
    BinRoots = [{toBinary(R), R} || R <- Roots],
    Matched = lists:filtermap(
        fun({BinRoot, OrigRoot}) ->
            case lists:any(fun(P) -> pathUnderRoot(P, BinRoot) end, Changed) of
                true -> {true, OrigRoot};
                false -> false
            end
        end, BinRoots),
    case Matched of
        [] -> Roots;
        _ -> Matched
    end.

%% 判断路径 P 是否落在 BinRoot 下（含 BinRoot 自身）。
%% 用前缀 + 分隔符避免 `a/b` 误命中 `a/bc`。
pathUnderRoot(P, BinRoot) when is_binary(P), is_binary(BinRoot) ->
    P =:= BinRoot orelse beginsWith(P, <<BinRoot/binary, "/">>)
        orelse beginsWith(P, <<BinRoot/binary, "\\">>);
pathUnderRoot(_, _) ->
    false.

%% P 是否以 Prefix 开头。
beginsWith(P, Prefix) when is_binary(P), is_binary(Prefix) ->
    case binary:match(P, Prefix) of
        {0, _} -> true;
        _ -> false
    end;
beginsWith(_, _) ->
    false.

%%--------------------------------------------------------------------
%% @doc
%% 比较两个快照 map，返回所有变化（新增/修改/删除）的路径列表。
%%
%% @param Old 旧快照
%% @param New 新快照
%% @return [binary()] —— 变化文件的路径列表
%% @end
%%--------------------------------------------------------------------
diffChanged(Old, New) ->
    OldKeys = maps:keys(Old),
    NewKeys = maps:keys(New),
    AddedOrModified = lists:filter(
        fun(K) ->
            case maps:find(K, Old) of
                {ok, V} -> maps:get(K, New) =/= V;
                error -> true
            end
        end,
        NewKeys),
    Removed = OldKeys -- NewKeys,
    AddedOrModified ++ Removed.

%%--------------------------------------------------------------------
%% @doc
%% 将快照 map 转为纯 list-of-tuples 形式，便于测试断言。
%%
%% @param Snap 快照 map
%% @return [{binary(), non_neg_integer()}]
%% @end
%%--------------------------------------------------------------------
snapshotToMap(Snap) ->
    lists:sort(maps:to_list(Snap)).

%%--------------------------------------------------------------------
%% @doc
%% 将逗号分隔的字符串解析为 trimmed binary 列表（小写）。
%%
%% @param Input 输入字符串/binary
%% @return [binary()]
%% @end
%%--------------------------------------------------------------------
parseList(Input) when is_binary(Input) ->
    parseList(binary_to_list(Input));
parseList(Input) when is_list(Input) ->
    Parts = string:split(Input, ",", all),
    [list_to_binary(string:trim(string:lowercase(P))) || P <- Parts, string:trim(P) =/= ""];
parseList(_) ->
    [].

%%--------------------------------------------------------------------
%% @doc 构造 filelib:fold_files 使用的扩展名正则：\\.(erl|hrl|rs)$
%%--------------------------------------------------------------------
extensionRegex(Exts) ->
    Inner = string:join([binary_to_list(string:trim(E)) || E <- Exts], "|"),
    "\\.(" ++ Inner ++ ")$".

%%--------------------------------------------------------------------
%% @doc 检查路径是否匹配任意 ignore 段。
%% 使用路径段匹配而非子串匹配：ignore="src" 只匹配路径段 "src"，
%% 不会误匹配 "binary_src/" 或 "src_legacy/"。路径分隔符统一为 /。
%%--------------------------------------------------------------------
pathMatchesAny(Path, IgnoreSet) ->
    Normalized = normalizePath(Path),
    Segments = pathSegments(Normalized),
    sets:fold(
        fun(_Ignore, true) -> true;
           (Ignore, false) ->
            IgnSeg = normalizePath(Ignore),
            lists:member(IgnSeg, Segments) orelse binary:match(Normalized, <<"/", IgnSeg/binary, "/">>) =/= nomatch
        end,
        false,
        IgnoreSet).

%% 将路径中的反斜杠统一为正斜杠，便于跨平台段匹配。
normalizePath(Bin) when is_binary(Bin) ->
    binary:replace(Bin, <<"\\">>, <<"/">>, [global]).

%% 按正斜杠拆分路径为段列表（去空段）。
pathSegments(Bin) ->
    [Seg || Seg <- binary:split(Bin, <<"/">>, [global, trim_all]), Seg =/= <<>>].

%%--------------------------------------------------------------------
%% @doc 归一化为 binary。
%%--------------------------------------------------------------------
toBinary(Term) when is_binary(Term) -> Term;
toBinary(Term) when is_list(Term) -> list_to_binary(Term);
toBinary(Term) when is_atom(Term) -> atom_to_binary(Term, utf8);
toBinary(_) -> <<>>.
