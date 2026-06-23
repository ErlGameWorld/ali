%%%-------------------------------------------------------------------
%%% @doc 向量嵌入与相似度检索。
%%%
%%% 在 {@link alRag} 的词法 TF-IDF 检索之上，提供基于向量 embedding 的
%%% 语义召回能力。默认调用 {@link llmCli:embeddings/2,3} 获取向量，
%%% 无 API key 或 provider 不支持时自动降级为 TF-IDF。
%%%
%%% 设计要点：
%%% <ul>
%%%   <li>向量缓存：相同文本不重复请求 embedding API（ETS）</li>
%%%   <li>批量嵌入：单次 API 调用处理多个文本，降低延迟与费用</li>
%%%   <li>余弦相似度：纯 Erlang 实现，无需 NIF</li>
%%%   <li>可注入 embedder：测试时可 {@link setEmbedder/1} 替换为 mock</li>
%%%   <li>降级安全：embedding 不可用时，调用方应回退到 TF-IDF</li>
%%% </ul>
%%% @end
%%%-------------------------------------------------------------------
-module(alEmbedding).

-export([
    embed/1,
    embed/2,
    embedBatch/2,
    cosine/2,
    store/3,
    lookup/1,
    search/2,
    clear/0,
    reset/0,
    stats/0,
    setEmbedder/1,
    getEmbedder/0,
    isAvailable/0
]).

-define(VECTORS, alEmbeddingVectors).
-define(CACHE, alEmbeddingCache).
-define(EMBEDDER_KEY, {?MODULE, embedder}).

-type vector() :: [number()].
-type chunk_id() :: binary().
-type metadata() :: map().

%%%===================================================================
%%% 配置与可用性
%%%===================================================================

%% @doc 注入自定义 embedder 函数（主要用于测试）。
%% Fun 签名：`fun((Input, Opts) -> {ok, Vector} | {ok, [Vector]} | {error, Reason})'
%% 其中 Input 为 binary() 或 [binary()]。
-spec setEmbedder(fun()) -> ok.
setEmbedder(Fun) when is_function(Fun) ->
    ensureTables(),
    ets:insert(?CACHE, {?EMBEDDER_KEY, Fun}),
    ok.

%% @doc 取出当前 embedder；未注入时返回默认的 llmCli embedder。
-spec getEmbedder() -> fun().
getEmbedder() ->
    ensureTables(),
    case ets:lookup(?CACHE, ?EMBEDDER_KEY) of
        [{?EMBEDDER_KEY, Fun}] when is_function(Fun) -> Fun;
        _ -> fun defaultEmbedder/2
    end.

%% @doc 判断向量 embedding 是否可用（有 API key 且 provider 支持）。
-spec isAvailable() -> boolean().
isAvailable() ->
    case llmCli:getConfig(provider, openai) of
        anthropic -> false;
        _ ->
            ApiKey = llmCli:getConfig(api_key, ""),
            case ApiKey of
                "" -> false;
                <<>> -> false;
                _ -> true
            end
    end.

%%%===================================================================
%%% 嵌入接口
%%%===================================================================

%% @doc 获取单条文本的向量嵌入（带缓存）。
-spec embed(binary() | string()) -> {ok, vector()} | {error, term()}.
embed(Text) ->
    embed(Text, #{}).

%% @doc 获取单条文本的向量嵌入，可传入 Opts（model 等）。
-spec embed(binary() | string(), map()) -> {ok, vector()} | {error, term()}.
embed(Text, Opts) ->
    Bin = toBinary(Text),
    ensureTables(),
    case ets:lookup(?CACHE, Bin) of
        [{Bin, Vector}] when is_list(Vector) ->
            {ok, Vector};
        _ ->
            Embedder = getEmbedder(),
            case Embedder(Bin, Opts) of
                {ok, Vector} when is_list(Vector) ->
                    ets:insert(?CACHE, {Bin, Vector}),
                    {ok, Vector};
                {ok, Other} ->
                    {error, {invalid_vector, Other}};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

%% @doc 批量嵌入：一次 API 调用处理多条文本，未命中缓存的才请求。
%% 返回的向量顺序与输入文本顺序一致。
-spec embedBatch([binary() | string()], map()) -> {ok, [vector()]} | {error, term()}.
embedBatch(Texts, Opts) ->
    Bins = [toBinary(T) || T <- Texts],
    ensureTables(),
    %% 先查缓存，记录每个位置的结果与未命中的 bin
    {Results, MissBins} = lists:foldl(fun(Bin, {ResAcc, MissAcc}) ->
        case ets:lookup(?CACHE, Bin) of
            [{Bin, Vector}] -> {[Vector | ResAcc], MissAcc};
            _ -> {[undefined | ResAcc], [Bin | MissAcc]}
        end
    end, {[], []}, Bins),
    ResultsRev = lists:reverse(Results),
    MissBinsRev = lists:reverse(MissBins),
    case MissBinsRev of
        [] ->
            {ok, ResultsRev};
        _ ->
            Embedder = getEmbedder(),
            case Embedder(MissBinsRev, Opts) of
                {ok, NewVectors} when is_list(NewVectors), length(NewVectors) =:= length(MissBinsRev) ->
                    %% 写入缓存
                    lists:foreach(fun({B, V}) -> ets:insert(?CACHE, {B, V}) end,
                                  lists:zip(MissBinsRev, NewVectors)),
                    %% 用 Bins + 缓存 map 重建完整结果
                    CacheMap = maps:from_list(lists:zip(MissBinsRev, NewVectors)),
                    Filled = [case R of
                                  undefined -> maps:get(B, CacheMap, []);
                                  _ -> R
                              end || {B, R} <- lists:zip(Bins, ResultsRev)],
                    {ok, Filled};
                {ok, Single} when is_list(Single), length(MissBinsRev) =:= 1 ->
                    ets:insert(?CACHE, {hd(MissBinsRev), Single}),
                    CacheMap = #{hd(MissBinsRev) => Single},
                    Filled = [case R of
                                  undefined -> maps:get(B, CacheMap, []);
                                  _ -> R
                              end || {B, R} <- lists:zip(Bins, ResultsRev)],
                    {ok, Filled};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

%%%===================================================================
%%% 相似度计算
%%%===================================================================

%% @doc 计算两个向量的余弦相似度（范围 [-1, 1]）。
%% 空向量或零向量返回 0.0。
-spec cosine(vector(), vector()) -> float().
cosine([], _) -> 0.0;
cosine(_, []) -> 0.0;
cosine(A, B) when length(A) =/= length(B) ->
    %% 维度不一致时按较短的截断（容错）
    Len = min(length(A), length(B)),
    {A1, _} = lists:split(Len, A),
    {B1, _} = lists:split(Len, B),
    cosineSame(A1, B1);
cosine(A, B) ->
    cosineSame(A, B).

cosineSame(A, B) ->
    {Dot, NA, NB} = lists:foldl(fun({X, Y}, {D, Na, Nb}) ->
        {D + X * Y, Na + X * X, Nb + Y * Y}
    end, {0.0, 0.0, 0.0}, lists:zip(A, B)),
    case abs(NA) < 1.0e-12 orelse abs(NB) < 1.0e-12 of
        true -> 0.0;
        false -> Dot / (math:sqrt(NA) * math:sqrt(NB))
    end.

%%%===================================================================
%%% 向量存储与检索
%%%===================================================================

%% @doc 存储一个 chunk 的向量与元数据。
-spec store(chunk_id(), vector(), metadata()) -> ok.
store(ChunkId, Vector, Meta) when is_binary(ChunkId), is_list(Vector), is_map(Meta) ->
    ensureTables(),
    ets:insert(?VECTORS, {ChunkId, Vector, Meta}),
    ok.

%% @doc 按 chunk ID 查询向量与元数据。
-spec lookup(chunk_id()) -> {ok, {vector(), metadata()}} | error.
lookup(ChunkId) when is_binary(ChunkId) ->
    ensureTables(),
    case ets:lookup(?VECTORS, ChunkId) of
        [{ChunkId, Vector, Meta}] -> {ok, {Vector, Meta}};
        [] -> error
    end.

%% @doc 用查询向量检索最相似的 chunk（返回 Top-N）。
%% 返回 `[{Score, ChunkId, Meta}]'，按相似度降序。
%% 使用固定容量的前 K 插入，避免对整张表构建完整列表后再排序。
-spec search(vector(), pos_integer()) -> [{float(), chunk_id(), metadata()}].
search(QueryVector, Limit) when is_list(QueryVector), is_integer(Limit), Limit > 0 ->
    ensureTables(),
    MaxSize = Limit * 2,
    Top = ets:foldl(fun
        ({ChunkId, Vector, Meta}, Acc) ->
            Score = cosine(QueryVector, Vector),
            case abs(Score) < 1.0e-12 of
                true -> Acc;
                false -> topKInsert({Score, ChunkId, Meta}, Acc, MaxSize)
            end
    end, [], ?VECTORS),
    lists:sublist(Top, Limit).

%% 将新元素插入容量为 MaxSize 的降序列表；得分过低时直接丢弃。
topKInsert(Item, Acc, MaxSize) when length(Acc) < MaxSize ->
    insertDesc(Item, Acc);
topKInsert({Score, _, _} = Item, Acc, _MaxSize) ->
    {MinScore, _, _} = lists:last(Acc),
    case Score > MinScore of
        true -> insertDesc(Item, lists:droplast(Acc));
        false -> Acc
    end.

insertDesc(Item, []) -> [Item];
insertDesc({Score, _, _} = Item, [{S, _, _} | _] = Acc) when Score >= S -> [Item | Acc];
insertDesc(Item, [H | T]) -> [H | insertDesc(Item, T)].

%%%===================================================================
%%% 维护
%%%===================================================================

%% @doc 清空所有存储的向量与缓存（保留 embedder 注入）。
-spec clear() -> ok.
clear() ->
    ensureTables(),
    ets:delete_all_objects(?VECTORS),
    ok.

%% @doc 完全重置：清空向量、缓存与注入的 embedder。
-spec reset() -> ok.
reset() ->
    ensureTables(),
    ets:delete_all_objects(?VECTORS),
    ets:delete_all_objects(?CACHE),
    ok.

%% @doc 返回当前向量存储与缓存统计。
-spec stats() -> map().
stats() ->
    ensureTables(),
    #{
        vectors => ets:info(?VECTORS, size),
        cachedEmbeddings => ets:info(?CACHE, size) - hasEmbedder(),
        available => isAvailable()
    }.

hasEmbedder() ->
    case ets:lookup(?CACHE, ?EMBEDDER_KEY) of
        [{?EMBEDDER_KEY, _}] -> 1;
        _ -> 0
    end.

%%%===================================================================
%%% 内部工具
%%%===================================================================

%% 默认 embedder：调用 llmCli:embeddings/2,3。
%% 若配置了 embeddingModel 则使用之，否则用 provider 默认模型。
defaultEmbedder(Input, Opts) ->
    Opts1 = case aliCfg:getV(embeddingModel) of
        undefined -> Opts;
        Model -> Opts#{model => Model}
    end,
    llmCli:embeddings(Input, Opts1).

%% 确保两张 ETS 表存在。
ensureTables() ->
    case ets:info(?VECTORS) of
        undefined ->
            ets:new(?VECTORS, [named_table, public, set, {read_concurrency, true}]);
        _ -> ok
    end,
    case ets:info(?CACHE) of
        undefined ->
            ets:new(?CACHE, [named_table, public, set, {read_concurrency, true}]);
        _ -> ok
    end,
    ok.

%% 多类型转 UTF-8 二进制。
toBinary(B) when is_binary(B) -> B;
toBinary(L) when is_list(L) -> unicode:characters_to_binary(L);
toBinary(A) when is_atom(A) -> atom_to_binary(A, utf8);
toBinary(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).
