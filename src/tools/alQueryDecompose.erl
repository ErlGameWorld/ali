%%%-------------------------------------------------------------------
%% @doc 查询分解器：将复杂问题拆分为多个独立子查询，并行检索后合并。
%%
%% 大型项目里用户常提复合问题，如"对比 alMemory 和 alQueryRewrite 的缓存策略"
%% 或"为什么 X 模块超时，而 Y 模块正常"。单次 BM25 检索难以同时命中两个主题。
%% 本模块用 LLM 把复合问题拆成 N 个子查询（每组关键词），每个独立检索后合并去重。
%%
%% 流程：
%% <ul>
%% <li>{@link needsDecompose/1}：启发式判断是否需要分解（连接词/长度），
%%     简单问题直接返回 `[]' 省一次 LLM 调用。</li>
%% <li>{@link decompose/1}：LLM 拆分为子查询关键词组，ETS 缓存。</li>
%% <li>{@link dedupHits/1}：合并多路命中，按 file+module 去重，score 取最大。</li>
%% </ul>
%%
%% 与 {@link alQueryRewrite} 正交：分解是"意图拆分"，改写是"关键词扩展"。
%% 分解后每个子查询已是 LLM 提炼的精准关键词组，不再二次调改写，控制成本。
%% @end
%%%-------------------------------------------------------------------

-module(alQueryDecompose).

-export([decompose/1, decompose/2, clearCache/0]).
%% 测试导出 — 纯辅助函数
-export([
    needsDecompose/1,
    hasConnector/1,
    decomposePrompt/1,
    parseSubQueries/1,
    dedupHits/1,
    mergeHit/2,
    cacheKey/1,
    storeCache/2
]).

-define(DecomposeTimeoutMs, 5000).
-define(CacheTtlMs, 300000).
-define(CacheTable, alQueryDecomposeCache).
-define(MaxSubQueries, 4).

%%--------------------------------------------------------------------
%% @doc
%% 查询分解简化入口：使用默认选项调用 {@link decompose/2}。
%%
%% @param Query 自然语言查询
%% @return [[binary()]] 子查询关键词组列表（简单问题返回 `[]'）
%% @end
%%--------------------------------------------------------------------
decompose(Query) ->
    decompose(Query, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 将复合问题分解为多个子查询关键词组。
%%
%% 流程：
%% 1. {@link needsDecompose/1} 判断是否需要分解，不需要返回 `[]'
%% 2. 查 ETS 缓存，命中直接返回
%% 3. 调 LLM 分解（带超时），解析嵌套 JSON 数组
%% 4. LLM 失败/超时返回 `[]'（降级为单查询流程）
%% 5. 写缓存后返回
%%
%% @param Query 自然语言查询
%% @param Opts 选项（timeoutMs、useCache）
%% @return [[binary()]] 子查询关键词组列表（最多 ?MaxSubQueries 个）
%% @end
%%--------------------------------------------------------------------
decompose(Query, Opts) ->
    BinQuery = toBinary(Query),
    case BinQuery of
        <<>> ->
            [];
        _ ->
            case needsDecompose(BinQuery) of
                false ->
                    [];
                true ->
                    UseCache = maps:get(useCache, Opts, true),
                    case UseCache andalso lookupCache(BinQuery) of
                        {ok, SubQueries} ->
                            SubQueries;
                        false ->
                            Timeout = maps:get(timeoutMs, Opts, ?DecomposeTimeoutMs),
                            SubQueries = doDecompose(BinQuery, Timeout),
                            case UseCache of
                                true -> storeCache(BinQuery, SubQueries);
                                false -> ok
                            end,
                            SubQueries
                    end
            end
    end.

%%--------------------------------------------------------------------
%% @doc 清空分解缓存。
%% @end
%%--------------------------------------------------------------------
clearCache() ->
    case ets:whereis(?CacheTable) of
        undefined -> ok;
        _ -> ets:match_delete(?CacheTable, {'_', '_', '_'})
    end.

%%--------------------------------------------------------------------
%% @doc
%% 启发式判断是否需要分解：含连接/对比词，或长度超过阈值。
%%
%% 简单问题（如"start_link 在哪"）不分解，省一次 LLM 调用。
%% 复合问题（如"对比 A 和 B"）才触发分解。
%%
%% @param Query 查询 binary
%% @return boolean()
%% @end
%%--------------------------------------------------------------------
%% 启发式判断是否需要分解：须有连接/对比意图，且问题足够长。
%% 注意：不要用 byte_size——中文 UTF-8 下短句也很容易 >30 字节，会无谓多调一次 LLM。
needsDecompose(Query) when is_binary(Query) ->
    CharLen = try string:length(unicode:characters_to_list(Query))
              catch _:_ -> byte_size(Query) end,
    %% 有连接/对比词才分解；不再单靠长度（中文短句 byte_size 易超标导致误触发 LLM）
    hasConnector(Query) andalso CharLen >= 6;
needsDecompose(_) ->
    false.

%%--------------------------------------------------------------------
%% @doc
%% 检测连接/对比词：中英文连接词暗示复合意图。
%% @end
%%--------------------------------------------------------------------
hasConnector(Query) when is_binary(Query) ->
    Patterns = [
        <<"和"/utf8>>, <<"以及"/utf8>>, <<"同时"/utf8>>, <<"对比"/utf8>>, <<"分别"/utf8>>,
        <<"还是"/utf8>>, <<"为什么"/utf8>>, <<"而"/utf8>>, <<"区别"/utf8>>,
        <<"vs">>, <<"versus">>, <<"compare">>, <<"difference">>,
        <<"and">>, <<"between">>
    ],
    Lower = toLower(Query),
    lists:any(fun(P) -> binary:match(Lower, toLower(P)) =/= nomatch end, Patterns);
hasConnector(_) ->
    false.

%%--------------------------------------------------------------------
%% @doc
%% 构造分解 LLM 的系统提示。要求返回嵌套 JSON 数组，每项一组关键词。
%% @end
%%--------------------------------------------------------------------
decomposePrompt(_Query) ->
    <<"你是代码搜索查询分解器。若用户问题含多个独立子问题，拆成互不依赖的子查询。\n\n"
      "规则：\n"
      "- 返回 JSON 数组的数组。每个内层数组是某一子查询的 2-5 个搜索关键词。\n"
      "- 非英文译成适合搜代码的英文关键词。\n"
      "- 相关时给出 snake_case 与 camelCase 变体。\n"
      "- 若问题只有一个意图，返回空数组 []。\n"
      "- 最多 4 个子查询。\n"
      "- 只返回 JSON，不要解释。\n\n"
      "示例：\n"
      "\"how does caching work and where is session saved\" => "
      "[[\"cache\",\"caching\",\"lookup\"],[\"session\",\"save\",\"persist\"]]\n"
      "\"对比 alMemory 和 alQueryRewrite 的缓存\" => "
      "[[\"alMemory\",\"cache\",\"ets\"],[\"alQueryRewrite\",\"cache\",\"ets\"]]\n"
      "\"simple question\" => []"/utf8>>.

%%--------------------------------------------------------------------
%% @doc
%% 解析 LLM 返回的嵌套 JSON 数组为子查询关键词组列表。
%% 容忍 code fence 包裹；非法/空返回 `[]'。
%% @end
%%--------------------------------------------------------------------
parseSubQueries(Content) when is_binary(Content) ->
    Trimmed = extractJsonArray(Content),
    case Trimmed of
        <<>> ->
            [];
        _ ->
            try alJson:decode(Trimmed) of
                List when is_list(List) ->
                    [parseKwGroup(Item) || Item <- List, is_list(Item) orelse is_binary(Item)];
                _ ->
                    []
            catch
                _:_ ->
                    []
            end
    end;
parseSubQueries(_) ->
    [].

%% 解析单个关键词组：[binary()] | binary -> [binary()]
parseKwGroup(Item) when is_list(Item) ->
    [toBinary(K) || K <- Item, is_binary(K) orelse is_list(K)];
parseKwGroup(Item) when is_binary(Item) ->
    [Item];
parseKwGroup(_) ->
    [].

%%--------------------------------------------------------------------
%% @doc
%% 合并多路检索命中：按 file+module 去重，score 取最大，functions 取并集。
%%
%% @param Hits 多路检索的命中列表（可能含重复）
%% @return 去重后的命中列表
%% @end
%%--------------------------------------------------------------------
dedupHits(Hits) when is_list(Hits) ->
    Merged = lists:foldl(fun mergeHit/2, #{}, Hits),
    maps:values(Merged);
dedupHits(_) ->
    [].

%%--------------------------------------------------------------------
%% @doc
%% 将单个命中合并进累积 map：键为 {File, Module}，值取 score 较大者，
%% functions 取并集。纯函数，便于测试。
%% @end
%%--------------------------------------------------------------------
mergeHit(Hit, Acc) when is_map(Hit) ->
    File = maps:get(file, Hit, undefined),
    Module = maps:get(module, Hit, undefined),
    Key = {File, Module},
    case maps:get(Key, Acc, undefined) of
        undefined ->
            Acc#{Key => Hit};
        Existing ->
            MergedScore = max(maps:get(score, Existing, 0), maps:get(score, Hit, 0)),
            ExistingFuns = maps:get(functions, Existing, []),
            HitFuns = maps:get(functions, Hit, []),
            MergedFuns = dedupFunctions(ExistingFuns ++ HitFuns),
            Acc#{Key => Existing#{score => MergedScore, functions => MergedFuns}}
    end;
mergeHit(_, Acc) ->
    Acc.

%% 函数去重：按 {name, arity} 去重。
dedupFunctions(Funs) when is_list(Funs) ->
    Seen = sets:new([{version, 2}]),
    {Result, _} = lists:foldl(fun(F, {Acc, S0}) ->
        Key = funKey(F),
        case sets:is_element(Key, S0) of
            true -> {Acc, S0};
            false -> {[F | Acc], sets:add_element(Key, S0)}
        end
    end, {[], Seen}, Funs),
    lists:reverse(Result);
dedupFunctions(_) ->
    [].

funKey(F) when is_map(F) ->
    {maps:get(name, F, undefined), maps:get(arity, F, undefined)};
funKey(F) ->
    F.

%%%===================================================================
%%% Internal helpers
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 实际执行 LLM 分解：构造消息、调用 chat（带超时）、解析结果。
%% 失败/超时返回 `[]'（降级为单查询流程）。
%% @end
%%--------------------------------------------------------------------
doDecompose(Query, TimeoutMs) ->
    Messages = [
        #{role => system, content => decomposePrompt(Query)},
        #{role => user, content => Query}
    ],
    Opts = #{
        execTimeout => TimeoutMs,
        llmRecvTimeout => TimeoutMs,
        llmConnectTimeout => min(5000, TimeoutMs),
        llmMaxRetries => 0,
        %% 查询分解属廉价辅助任务：链路由时优先 aux 角色（本地模型）。
        llmRole => aux
    },
    case alLlmClient:chat(Messages, Opts) of
        {ok, Reply} ->
            Content = maps:get(content, Reply, <<>>),
            SubQueries = parseSubQueries(Content),
            lists:sublist(SubQueries, ?MaxSubQueries);
        {error, _Reason} ->
            []
    end.

%% 从可能含 markdown fence 的响应中提取 JSON 数组段。
%% 取第一个 [ 到最后一个 ]，支持嵌套数组 [[...],[...]]。
extractJsonArray(Content) ->
    case binary:match(Content, <<"[">>) of
        nomatch -> <<>>;
        {Start, _} ->
            case binary:matches(Content, <<"]">>) of
                [] -> <<>>;
                Matches ->
                    {End, _} = lists:last(Matches),
                    binary:part(Content, Start, End - Start + 1)
            end
    end.

%%--------------------------------------------------------------------
%% @doc 计算缓存 key（查询文本 binary 本身，无 phash2）。
%%--------------------------------------------------------------------
cacheKey(Query) ->
    toBinary(Query).

%%%===================================================================
%%% ETS cache
%%%===================================================================

ensureCacheTable() ->
    case ets:whereis(?CacheTable) of
        undefined ->
            try
                ets:new(?CacheTable, [named_table, set, public,
                                      {read_concurrency, true},
                                      {write_concurrency, true}]),
                ok
            catch
                _:_ -> ok
            end;
        _ ->
            ok
    end.

lookupCache(Query) ->
    case ets:whereis(?CacheTable) of
        undefined -> false;
        _ ->
            Key = toBinary(Query),
            case ets:lookup(?CacheTable, Key) of
                [{_, SubQueries, Expiry}] when is_integer(Expiry) ->
                    case erlang:system_time(millisecond) < Expiry of
                        true -> {ok, SubQueries};
                        false -> false
                    end;
                _ ->
                    false
            end
    end.

storeCache(Query, SubQueries) ->
    ensureCacheTable(),
    Key = toBinary(Query),
    Expiry = erlang:system_time(millisecond) + ?CacheTtlMs,
    ets:insert(?CacheTable, {Key, SubQueries, Expiry}),
    ok.

%%%===================================================================
%%% Pure helpers
%%%===================================================================

toBinary(V) when is_binary(V) -> V;
toBinary(V) when is_list(V) -> list_to_binary(V);
toBinary(V) when is_atom(V) -> atom_to_binary(V, utf8);
toBinary(_) -> <<>>.

%% 二进制小写化（ASCII），用于大小写不敏感的连接词匹配。
%% 用 list comprehension 避免 binary comprehension 在多字节字符上的 badarg。
toLower(Bin) when is_binary(Bin) ->
    List = binary_to_list(Bin),
    LowerList = [if C >= $A andalso C =< $Z -> C + 32; true -> C end || C <- List],
    list_to_binary(LowerList).
