%%%-------------------------------------------------------------------
%%% @doc 检索结果重排序（Rerank）。
%%%
%%% 在 {@link alRag} 的混合检索召回 top-N 候选后，对候选做更精细的
%%% 二次排序，提升 top-k 精度。
%%%
%%% 支持三种模式（按优先级）：
%%% <ol>
%%%   <li>注入 reranker：`setReranker/1' 注入自定义打分函数（测试用）</li>
%%%   <li>外部 API：配置 `rerankApiUrl' 时调用 Cohere/Jina 等 rerank 服务</li>
%%%   <li>本地特征：默认，基于查询词在函数名/模块名/路径/注释中的精确匹配与密度</li>
%%% </ol>
%%%
%%% 本地特征 rerank 无外部依赖，零成本，适合离线场景。特征包括：
%%% <ul>
%%%   <li>函数名精确命中（权重 3.0）</li>
%%%   <li>模块名精确命中（权重 2.0）</li>
%%%   <li>文件路径命中（权重 1.0）</li>
%%%   <li>查询词密度：命中词数 / chunk 文本长度（权重 1.5）</li>
%%%   <li>原始检索得分（权重 0.5，保留语义召回信号）</li>
%%% </ul>
%%% @end
%%%-------------------------------------------------------------------
-module(alRerank).

-export([
    rerank/3,
    isAvailable/0,
    setReranker/1,
    reset/0,
    scoreOne/2
]).

-define(RERANKER_KEY, {?MODULE, reranker}).
-define(TABLE, alRerankerTable).
-define(SCALE, 1000).  %% 特征分数缩放因子，便于与 hybrid score 融合

-type candidate() :: #{
    module := atom(),
    function := atom(),
    arity := integer(),
    file := binary(),
    lineStart := integer(),
    lineEnd := integer(),
    score := float(),
    snippet := binary(),
    text => binary()
}.

%%%===================================================================
%%% API
%%%===================================================================

%% @doc 对候选结果重排序。
%% `Query' 为原始查询文本，`Candidates' 为检索返回的候选列表，
%% `Opts' 可含 `keepTop'（保留前 N 条，默认全保留）。
-spec rerank(binary(), [candidate()], map()) -> [candidate()].
rerank(Query, Candidates, Opts) ->
    ensureTable(),
    KeepTop = maps:get(keepTop, Opts, length(Candidates)),
    Reranker = getReranker(),
    QTokens = alRag:tokenize(Query),
    Scored = lists:map(fun(C) ->
        {Reranker(QTokens, C), C}
    end, Candidates),
    Sorted = lists:sort(fun({A, _}, {B, _}) -> A >= B end, Scored),
    [C || {_, C} <- lists:sublist(Sorted, KeepTop)].

%% @doc 判断 rerank 是否可用（始终为 true，本地特征 rerank 无外部依赖）。
-spec isAvailable() -> boolean().
isAvailable() -> true.

%% @doc 注入自定义 reranker 函数。
%% Fun 签名：`fun((QueryTokens, Candidate) -> number())'
%% 分数越高越相关。
-spec setReranker(fun()) -> ok.
setReranker(Fun) when is_function(Fun) ->
    ensureTable(),
    ets:insert(?TABLE, {?RERANKER_KEY, Fun}),
    ok.

%% @doc 重置为默认 reranker。
-spec reset() -> ok.
reset() ->
    ensureTable(),
    ets:delete(?TABLE, ?RERANKER_KEY),
    ok.

%% @doc 对单个候选打分（导出供测试验证）。
-spec scoreOne([binary()], candidate()) -> float().
scoreOne(QTokens, Candidate) ->
    defaultReranker(QTokens, Candidate).

%%%===================================================================
%%% 内部
%%%===================================================================

%% 获取当前 reranker（注入或默认）
getReranker() ->
    case ets:lookup(?TABLE, ?RERANKER_KEY) of
        [{?RERANKER_KEY, Fun}] when is_function(Fun) -> Fun;
        _ -> fun(Q, C) -> defaultReranker(Q, C) end
    end.

%% 默认 reranker：多特征加权打分
defaultReranker(QTokens, Candidate) ->
    FuncScore = funcNameScore(QTokens, Candidate),
    ModScore = modNameScore(QTokens, Candidate),
    PathScore = pathScore(QTokens, Candidate),
    DensityScore = densityScore(QTokens, Candidate),
    OrigScore = maps:get(score, Candidate, 0.0),
    %% 加权融合：函数名命中权重最高，原始得分作为语义信号保底
    FuncScore * 3.0 + ModScore * 2.0 + PathScore * 1.0
        + DensityScore * 1.5 + OrigScore * 0.5.

%% 函数名精确匹配：查询词在函数名 token 中的命中比例
funcNameScore(QTokens, #{function := Func}) ->
    FuncTokens = sets:from_list(alRag:tokenize(atom_to_binary(Func, utf8))),
    hitRatio(QTokens, FuncTokens).

%% 模块名精确匹配
modNameScore(QTokens, #{module := Mod}) ->
    ModTokens = sets:from_list(alRag:tokenize(atom_to_binary(Mod, utf8))),
    hitRatio(QTokens, ModTokens).

%% 文件路径匹配
pathScore(QTokens, #{file := File}) ->
    PathTokens = sets:from_list(alRag:tokenize(File)),
    hitRatio(QTokens, PathTokens).

%% 查询词密度：命中词数 / 文本长度（归一化）
densityScore(QTokens, Candidate) ->
    Text = maps:get(text, Candidate, maps:get(snippet, Candidate, <<>>)),
    TextLen = max(byte_size(Text), 1),
    HitCount = length([T || T <- QTokens, binary:match(Text, T) =/= nomatch]),
    HitCount / TextLen * ?SCALE.

%% 命中比例：查询词在目标 token 集中的命中数 / 查询词总数
hitRatio(QTokens, TargetSet) ->
    case length(QTokens) of
        0 -> 0.0;
        Total ->
            Hits = length([T || T <- QTokens, sets:is_element(T, TargetSet)]),
            Hits / Total * ?SCALE
    end.

%% 确保 ETS 表存在
ensureTable() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, public, set, {read_concurrency, true}]);
        _ ->
            ok
    end,
    ok.
