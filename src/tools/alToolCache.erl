%%%-------------------------------------------------------------------
%% @doc 工具结果缓存：白名单 + TTL + LRU 淘汰。
%%
%% ETS ordered_set，key = {{Seq, ExpireAt, {Tool, ArgsHash}}} 形式。
%% 仅缓存白名单内的只读幂等工具；写操作会使全部条目失效。
%%
%% ordered_set 按 key 自然升序——Seq 自增单调，因此表头即最久未访问条目，
%% LRU 淘汰只需取头部 N 个，避免原 set + tab2list + keysort 的全表扫描。
%% @end
%%%-------------------------------------------------------------------

-module(alToolCache).

-export([lookup/2, store/3, invalidateForWrite/0, invalidateForWrite/1, isCacheable/1,
         stats/0, whitelist/0, ensureStarted/0]).
%% Test exports — pure helpers
-export([normalizeCachePath/1, shouldInvalidate/3]).

-define(Table, alToolCache).
-define(DefaultTtlMs, 300000).
-define(DefaultMaxSize, 256).

%%--------------------------------------------------------------------
%% @doc
%% 确保 ETS 缓存表已创建：已存在则直接返回 ok；
%% 不存在则创建一个 named_table、public、ordered_set 类型的 ETS 表，
%% 启用读写并发；创建异常吞掉返回 ok
%%
%% @return ok
%% @end
%%--------------------------------------------------------------------
ensureStarted() ->
    case ets:whereis(?Table) of
        undefined ->
            try ets:new(?Table, [named_table, public, ordered_set,
                                 {read_concurrency, true},
                                 {write_concurrency, true}]) of
                _ -> ok
            catch _:_ -> ok end;
        _ ->
            ok
    end.

%%%===================================================================
%%% Whitelist
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 返回允许缓存的结果白名单：仅包含只读、幂等的工具
%%
%% @return 工具名称列表
%% @end
%%--------------------------------------------------------------------
whitelist() ->
    [
        indexCode,
        searchCode,
        getSymbol,
        findCallers,
        findCallees,
        readFile,
        readFilePage,
        listFiles,
        searchText,
        searchMemory,
        search,
        coreHealth,
        coreStatus,
        formatCode
    ].

%%--------------------------------------------------------------------
%% @doc
%% 判断指定工具的结果是否可缓存（是否在白名单中）
%%
%% @param Tool 工具名称
%% @return boolean()
%% @end
%%--------------------------------------------------------------------
isCacheable(Tool) ->
    lists:member(Tool, whitelist()).

%%%===================================================================
%%% Lookup
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 查询缓存：工具不可缓存直接 miss；命中且未过期返回 {ok, Result}；
%% 过期则删除条目并返回 miss。命中时会更新存储序号以延长生命周期
%% （真正的 LRU 语义，避免热条目被淘汰）。
%%
%% @param Tool 工具名称
%% @param Args 调用参数
%% @return {ok, Result} 或 miss
%% @end
%%--------------------------------------------------------------------
lookup(Tool, Args) ->
    case isCacheable(Tool) of
        false -> miss;
        true ->
            ensureStarted(),
            Key = makeKey(Tool, Args),
            case ets:lookup(?Table, Key) of
                [{Key, Result, ExpireAt, _StoredAt}] ->
                    Now = erlang:system_time(millisecond),
                    case Now < ExpireAt of
                        true ->
                            %% 更新访问序号实现真正 LRU。
                            Seq = erlang:unique_integer([positive, monotonic]),
                            ets:insert(?Table, {Key, Result, ExpireAt, Seq}),
                            {ok, Result};
                        false ->
                            ets:delete(?Table, Key),
                            miss
                    end;
                [] ->
                    miss
            end
    end.

%%%===================================================================
%%% Store
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 存储工具结果到缓存：不可缓存的工具直接返回 ok；
%% 否则写入带过期时间和序号的条目，并按需触发 LRU 淘汰
%%
%% @param Tool 工具名称
%% @param Args 调用参数
%% @param Result 工具执行结果
%% @return ok
%% @end
%%--------------------------------------------------------------------
store(Tool, Args, Result) ->
    case isCacheable(Tool) of
        false -> ok;
        true ->
            ensureStarted(),
            Key = makeKey(Tool, Args),
            Ttl = ttlMs(),
            Now = erlang:system_time(millisecond),
            Seq = erlang:unique_integer([positive, monotonic]),
            ets:insert(?Table, {Key, Result, Now + Ttl, Seq}),
            maybeEvict(),
            ok
    end.

%%--------------------------------------------------------------------
%% @doc
%% 生成缓存键：{Tool, ArgsBin}。使用完整 `term_to_binary(Args)` 避免
%% `phash2` 32 位碰撞导致返回错误工具结果。
%%
%% @param Tool 工具名称
%% @param Args 调用参数
%% @return 缓存键元组
%% @end
%%--------------------------------------------------------------------
makeKey(Tool, Args) ->
    {Tool, term_to_binary(Args)}.

%%--------------------------------------------------------------------
%% @doc
%% 获取缓存 TTL（毫秒），从 agent 配置读取，默认 300000ms
%%
%% @return TTL 毫秒
%% @end
%%--------------------------------------------------------------------
ttlMs() ->
    Agent = alConfig:get(agent, #{}),
    case maps:get(toolCacheTtl, Agent, ?DefaultTtlMs) of
        N when is_integer(N), N > 0 -> N;
        _ -> ?DefaultTtlMs
    end.

%%--------------------------------------------------------------------
%% @doc
%% 获取缓存最大条目数，从 agent 配置读取，默认 256
%%
%% @return 最大条目数
%% @end
%%--------------------------------------------------------------------
maxSize() ->
    Agent = alConfig:get(agent, #{}),
    case maps:get(toolCacheMaxSize, Agent, ?DefaultMaxSize) of
        N when is_integer(N), N > 0 -> N;
        _ -> ?DefaultMaxSize
    end.

%%--------------------------------------------------------------------
%% @doc
%% 必要时执行 LRU 淘汰：当前条目数超过 maxSize 时，
%% 按存储序号（第 4 字段）升序排序，删除最早的若干条目
%%
%% @return ok
%% @end
%%--------------------------------------------------------------------
maybeEvict() ->
    Size = ets:info(?Table, size),
    Max = maxSize(),
    case Size > Max of
        true ->
            All = ets:tab2list(?Table),
            Sorted = lists:keysort(4, All),
            Excess = Size - Max,
            ToEvict = lists:sublist(Sorted, Excess),
            [ets:delete(?Table, element(1, E)) || E <- ToEvict],
            ok;
        false ->
            ok
    end.

%%%===================================================================
%%% Invalidation
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 写操作失效：清空缓存表所有条目（写操作可能使读结果失效）
%%
%% @return ok
%% @end
%%--------------------------------------------------------------------
invalidateForWrite() ->
    ensureStarted(),
    ets:delete_all_objects(?Table),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% 精确写失效：已知被写路径时只失效相关条目，保留无关文件缓存。
%% <ul>
%%   <li>readFile/readFilePage：仅当缓存条目的 path 命中被写路径时删除
%%       （连续编辑会话「读A → 改B → 再读A」中 A 的缓存得以保留）</li>
%%   <li>其余缓存工具（searchCode/getSymbol/findCallers 等索引依赖）：
%%       写后索引已变，全部失效</li>
%% </ul>
%% 路径匹配先经 {@link normalizeCachePath/1} 归一化（大小写/斜杠方向/./前缀）。
%%
%% @param Paths 被写文件路径列表；空列表退化为全表清空
%% @return ok
%% @end
%%--------------------------------------------------------------------
invalidateForWrite(Paths) when is_list(Paths), Paths =/= [] ->
    ensureStarted(),
    Written = [normalizeCachePath(P) || P <- Paths, isBinaryPath(P)],
    _ = [ets:delete(?Table, Key)
         || {{Tool, ArgsBin} = Key, _, _, _} <- ets:tab2list(?Table),
            shouldInvalidate(Tool, ArgsBin, Written)],
    ok;
invalidateForWrite(_) ->
    invalidateForWrite().

%% 工具条目是否应失效（true = 删除）：
%% 文件读类仅当 path 命中被写集合时删除，无关文件保留；其余工具全失效。
shouldInvalidate(Tool, ArgsBin, Written) ->
    case Tool =:= readFile orelse Tool =:= readFilePage of
        true ->
            case cachedPath(ArgsBin) of
                undefined -> true;
                P -> lists:member(normalizeCachePath(P), Written)
            end;
        false ->
            true
    end.

%% 从缓存键的参数二进制中提取 path（二进制或字符串键，缺失返回 undefined）。
cachedPath(ArgsBin) ->
    try binary_to_term(ArgsBin) of
        Args when is_map(Args) ->
            case maps:get(path, Args, maps:get(<<"path">>, Args, undefined)) of
                P when is_binary(P); is_list(P) -> P;
                _ -> undefined
            end;
        _ ->
            undefined
    catch
        _:_ -> undefined
    end.

isBinaryPath(P) -> is_binary(P) orelse is_list(P).

%% 路径归一化：binary、小写、反斜杠转正斜杠、去 "./" 前缀。
normalizeCachePath(P) ->
    Bin = case P of
        B when is_binary(B) -> B;
        L when is_list(L) -> unicode:characters_to_binary(L)
    end,
    Fwd = binary:replace(Bin, <<"\\">>, <<"/">>, [global]),
    Lower = try string:lowercase(Fwd) catch _:_ -> Fwd end,
    case Fwd of
        <<"./", Rest/binary>> -> string:lowercase(Rest);
        _ -> Lower
    end.

%%%===================================================================
%%% Stats
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 获取缓存统计信息：当前条目数、最大条目数、TTL、白名单
%%
%% @return 包含 size、maxSize、ttlMs、whitelist 字段的映射
%% @end
%%--------------------------------------------------------------------
stats() ->
    ensureStarted(),
    #{
        size => ets:info(?Table, size),
        maxSize => maxSize(),
        ttlMs => ttlMs(),
        whitelist => whitelist()
    }.
