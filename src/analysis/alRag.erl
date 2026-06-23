%%%-------------------------------------------------------------------
%%% @doc 代码语义检索 / 轻量 RAG。
%%%
%%% 以 {@link alCodeIndexer} 提供的函数级元数据为基础，将每个函数体
%%% 切分为「代码块（chunk）」，对标识符做大小写/下划线感知分词，建立
%%% TF-IDF 向量，支持自然语言/关键词查询返回最相关的函数片段。
%%%
%%% 默认采用确定性的词法 TF-IDF 排序（离线、零成本、可复现）；当
%%% {@link alEmbedding:isAvailable/0} 为真（即配置了 API key 且 provider
%%% 支持 embedding）时，{@link search/3} 自动升级为「混合检索」：
%%% 同时跑 TF-IDF 与向量余弦相似度，按加权融合排序。可通过配置
%%% `ragMode'（auto|tfidf|hybrid）强制指定模式。
%%% @end
%%%-------------------------------------------------------------------
-module(alRag).

-export([
    index/1,
    search/2,
    search/3,
    searchHybrid/3,
    stats/0,
    clear/0,
    tokenize/1,
    mode/0
]).

-define(CHUNKS, alRagChunks).
-define(IDF_KEY, {?MODULE, idf}).
-define(COUNT_KEY, {?MODULE, chunkCount}).
-define(MTIME_KEY, {?MODULE, mtimes}).
-define(SNIPPET_LINES, 4).

%% Erlang 关键字与极常见低区分度词，分词时剔除。
-define(STOPWORDS, [
    <<"the">>, <<"and">>, <<"for">>, <<"fun">>, <<"end">>, <<"case">>,
    <<"of">>, <<"if">>, <<"when">>, <<"ok">>, <<"error">>, <<"begin">>,
    <<"receive">>, <<"after">>, <<"try">>, <<"catch">>, <<"do">>,
    <<"is">>, <<"to">>, <<"in">>, <<"on">>, <<"at">>
]).

%% @doc 构建/重建检索语料库。若代码索引为空会先触发一次刷新。
%% 当 embedding 可用时，会批量向量化每个 chunk 并存入 {@link alEmbedding}。
%% 增量优化：若所有模块文件 mtime 与上次索引一致，跳过重建。
-spec index(map()) -> {ok, map()}.
index(Config) ->
    ensureTable(),
    alCodeIndexer:ensureStarted(),
    case maps:get(moduleCount, alCodeIndexer:getStats(), 0) of
        0 -> alCodeIndexer:refresh(Config);
        _ -> ok
    end,
    %% 增量检查：若所有模块 mtime 未变且已有索引，跳过重建
    CurrentMtimes = collectMtimes(),
    CachedMtimes = persistent_term:get(?MTIME_KEY, #{}),
    case CurrentMtimes =/= #{} andalso CurrentMtimes =:= CachedMtimes
         andalso persistent_term:get(?COUNT_KEY, 0) > 0 of
        true ->
            {ok, #{chunks => persistent_term:get(?COUNT_KEY, 0),
                   terms => maps:size(persistent_term:get(?IDF_KEY, #{})),
                   embeddings => #{enabled => alEmbedding:isAvailable(), skipped => true},
                   skipped => true}};
        false ->
            doIndex(Config, CurrentMtimes)
    end.

%% 全量重建索引并更新 mtime 缓存。
doIndex(Config, CurrentMtimes) ->
    ets:delete_all_objects(?CHUNKS),
    alEmbedding:clear(),
    Chunks = lists:flatmap(fun chunksForModule/1, alCodeIndexer:allModules()),
    %% 写入 chunk 并累计文档频率（df）
    Df = lists:foldl(fun(Chunk, DfAcc) ->
        ets:insert(?CHUNKS, {maps:get(id, Chunk), Chunk}),
        Terms = maps:keys(maps:get(tf, Chunk)),
        lists:foldl(fun(T, A) -> maps:update_with(T, fun(C) -> C + 1 end, 1, A) end, DfAcc, Terms)
    end, #{}, Chunks),
    N = length(Chunks),
    Idf = maps:map(fun(_T, DocFreq) ->
        math:log(1 + N / max(DocFreq, 1))
    end, Df),
    persistent_term:put(?IDF_KEY, Idf),
    persistent_term:put(?COUNT_KEY, N),
    persistent_term:put(?MTIME_KEY, CurrentMtimes),
    %% 当 embedding 可用时，批量向量化 chunk 并存入向量库
    EmbeddingStats = maybeBuildEmbeddings(Chunks, Config),
    {ok, #{chunks => N, terms => maps:size(Idf), embeddings => EmbeddingStats, skipped => false}}.

%% 收集所有模块文件的 mtime，用于增量索引判断。
collectMtimes() ->
    lists:foldl(fun(Mod, Acc) ->
        case alCodeIndexer:getModule(Mod) of
            {ok, Entry} ->
                AbsPath = maps:get(absPath, Entry, undefined),
                Mtime = maps:get(mtime, Entry, undefined),
                case AbsPath =:= undefined orelse Mtime =:= undefined of
                    true -> Acc;
                    false -> maps:put(AbsPath, Mtime, Acc)
                end;
            _ ->
                Acc
        end
    end, #{}, alCodeIndexer:allModules()).

%% 当 embedding 可用时，批量向量化所有 chunk 并存入 alEmbedding。
%% 失败时静默降级（不影响 TF-IDF 检索），返回状态 map。
maybeBuildEmbeddings(Chunks, _Config) ->
    case alEmbedding:isAvailable() of
        false ->
            #{enabled => false, reason => unavailable};
        true ->
            %% 取前 N 行摘要作为 embedding 输入（避免超长文本）
            Inputs = [chunkEmbeddingText(C) || C <- Chunks],
            Opts = #{},
            case alEmbedding:embedBatch(Inputs, Opts) of
                {ok, Vectors} ->
                    lists:foreach(fun({Chunk, Vec}) ->
                        Meta = #{
                            module => maps:get(module, Chunk),
                            function => maps:get(function, Chunk),
                            arity => maps:get(arity, Chunk),
                            file => maps:get(file, Chunk),
                            lineStart => maps:get(lineStart, Chunk),
                            lineEnd => maps:get(lineEnd, Chunk)
                        },
                        alEmbedding:store(maps:get(id, Chunk), Vec, Meta)
                    end, lists:zip(Chunks, Vectors)),
                    #{enabled => true, count => length(Vectors)};
                {error, Reason} ->
                    #{enabled => false, reason => Reason}
            end
    end.

%% 取 chunk 的可嵌入文本：函数签名 + 前 8 行代码（控制长度与成本）。
chunkEmbeddingText(Chunk) ->
    Sig = iolist_to_binary([atom_to_binary(maps:get(module, Chunk), utf8), <<":">>,
                            atom_to_binary(maps:get(function, Chunk), utf8), <<"/">>,
                            integer_to_binary(maps:get(arity, Chunk, 0))]),
    Text = maps:get(text, Chunk, <<>>),
    Lines = binary:split(Text, <<"\n"/utf8>>, [global]),
    Head = lists:sublist(Lines, 8),
    iolist_to_binary([Sig, <<"\n"/utf8>>, lists:join(<<"\n"/utf8>>, Head)]).

%% @doc 当前 RAG 检索模式（auto|tfidf|hybrid）。
%% auto：embedding 可用时用 hybrid，否则 tfidf。
-spec mode() -> tfidf | hybrid.
mode() ->
    Configured = alConfig:val(ragMode),
    case Configured of
        tfidf -> tfidf;
        hybrid -> hybrid;
        auto ->
            case alEmbedding:isAvailable() of
                true -> hybrid;
                false -> tfidf
            end
    end.

%% @doc 检索与查询最相关的代码片段（默认返回 5 条）。
-spec search(binary() | string(), map()) -> {ok, [map()]}.
search(Query, Config) ->
    search(Query, #{}, Config).

%% @doc 检索，Opts 支持 `limit`（默认 5）。
%% 按 {@link mode/0} 自动选择 TF-IDF 或混合检索。
-spec search(binary() | string(), map(), map()) -> {ok, [map()]}.
search(Query, Opts, Config) ->
    ensureIndexed(Config),
    case mode() of
        tfidf -> searchTfidf(Query, Opts);
        hybrid ->
            case searchHybrid(Query, Opts, Config) of
                {ok, Results} when Results =/= [] -> {ok, Results};
                %% 向量检索失败或空结果时回退到 TF-IDF
                _ -> searchTfidf(Query, Opts)
            end
    end.

%% @doc 混合检索：融合 TF-IDF 与向量余弦相似度，并对 top-N 候选做 rerank。
%% 权重：向量 0.6，TF-IDF 0.4（向量更能捕捉语义，TF-IDF 精确匹配关键词）。
%% Opts 可传 `vectorWeight' 与 `tfidfWeight' 覆盖默认权重；
%% `rerank'（默认 true）控制是否对候选做二次重排序。
-spec searchHybrid(binary() | string(), map(), map()) -> {ok, [map()]}.
searchHybrid(Query, Opts, Config) ->
    ensureIndexed(Config),
    Limit = maps:get(limit, Opts, 5),
    VecWeight = maps:get(vectorWeight, Opts, 0.6),
    TfWeight = maps:get(tfidfWeight, Opts, 0.4),
    UseRerank = maps:get(rerank, Opts, true),
    %% 召回扩大到 Limit*4，为 rerank 留足候选池
    Recall = Limit * 4,
    %% TF-IDF 得分
    TfidfResults = searchTfidfRaw(Query, #{limit => Recall}),
    TfidfMap = maps:from_list([{maps:get(id, R), maps:get(score, R)} || R <- TfidfResults]),
    %% 向量得分
    VectorResults = case alEmbedding:embed(toBinary(Query), #{}) of
        {ok, QueryVec} ->
            Hits = alEmbedding:search(QueryVec, Recall),
            [{alEmbeddingScoreNormalize(Score), Id} || {Score, Id, _Meta} <- Hits];
        {error, _} ->
            []
    end,
    VectorMap = maps:from_list(VectorResults),
    %% 合并候选 ID 并加权融合
    AllIds = sets:to_list(sets:union([sets:from_list(maps:keys(TfidfMap)),
                                       sets:from_list(maps:keys(VectorMap))])),
    Fused = lists:map(fun(Id) ->
        TfScore = maps:get(Id, TfidfMap, 0.0),
        VecScore = maps:get(Id, VectorMap, 0.0),
        {VecWeight * VecScore + TfWeight * TfScore, Id}
    end, AllIds),
    Sorted = lists:sort(fun({A, _}, {B, _}) -> A >= B end, Fused),
    %% 取 top-Recall 候选，补全展示信息
    Candidates = [presentHybrid(Score, Id) || {Score, Id} <- lists:sublist(Sorted, Recall)],
    %% 可选 rerank：对候选做二次精排，取 top-Limit
    Final = case UseRerank andalso alRerank:isAvailable() of
        true ->
            alRerank:rerank(toBinary(Query), Candidates, #{keepTop => Limit});
        false ->
            lists:sublist(Candidates, Limit)
    end,
    {ok, Final}.

%% 将 embedding 余弦相似度（[-1,1]）归一化到 [0,1] 便于与 TF-IDF 融合。
alEmbeddingScoreNormalize(Score) ->
    max(0.0, (Score + 1.0) / 2.0).

%% 混合检索结果展示：优先从 chunk 表取 snippet，向量库 meta 兜底。
presentHybrid(FusedScore, Id) ->
    case ets:lookup(?CHUNKS, Id) of
        [{Id, Chunk}] ->
            presentChunk(FusedScore, Chunk);
        [] ->
            case alEmbedding:lookup(Id) of
                {ok, {_Vec, Meta}} ->
                    Meta#{score => round3(FusedScore), snippet => <<>>};
                error ->
                    #{id => Id, score => round3(FusedScore), snippet => <<>>}
            end
    end.

%% 纯 TF-IDF 检索（内部，返回原始 chunk map 列表，含 id/score）。
searchTfidfRaw(Query, Opts) ->
    Limit = maps:get(limit, Opts, 5),
    QTokens = lists:usort(tokenize(Query)),
    Idf = persistent_term:get(?IDF_KEY, #{}),
    Scored = ets:foldl(fun({_Id, Chunk}, Acc) ->
        case scoreChunk(Chunk, QTokens, Idf) of
            +0.0 -> Acc;
            Score -> [{Score, Chunk} | Acc]
        end
    end, [], ?CHUNKS),
    Sorted = lists:sort(fun({A, _}, {B, _}) -> A >= B end, Scored),
    [Chunk#{score => Score} || {Score, Chunk} <- lists:sublist(Sorted, Limit)].

%% 纯 TF-IDF 检索（对外展示格式）。
searchTfidf(Query, Opts) ->
    Raw = searchTfidfRaw(Query, Opts),
    Limit = maps:get(limit, Opts, 5),
    Top = [presentChunk(maps:get(score, R, 0.0), maps:remove(score, R)) || R <- lists:sublist(Raw, Limit)],
    {ok, Top}.

%% @doc 语料库统计。
-spec stats() -> map().
stats() ->
    ensureTable(),
    #{
        chunks => persistent_term:get(?COUNT_KEY, 0),
        terms => maps:size(persistent_term:get(?IDF_KEY, #{})),
        mode => mode(),
        embeddings => alEmbedding:stats()
    }.

%% @doc 清空语料库。
-spec clear() -> ok.
clear() ->
    ensureTable(),
    ets:delete_all_objects(?CHUNKS),
    alEmbedding:clear(),
    persistent_term:put(?IDF_KEY, #{}),
    persistent_term:put(?COUNT_KEY, 0),
    persistent_term:erase(?MTIME_KEY),
    ok.

%%%===================================================================
%%% 评分 / 检索
%%%===================================================================

%% 计算单个 chunk 对查询词集合的 TF-IDF 得分（含函数/模块名加权）。
scoreChunk(Chunk, QTokens, Idf) ->
    Tf = maps:get(tf, Chunk),
    NameTokens = maps:get(nameTokens, Chunk, []),
    lists:foldl(fun(T, Acc) ->
        case maps:get(T, Tf, 0) of
            0 -> Acc;
            Count ->
                TermIdf = maps:get(T, Idf, 0.0),
                Weight = (1 + math:log(Count)) * TermIdf,
                %% 命中函数名/模块名给予额外权重（更贴合检索意图）
                Bonus = case lists:member(T, NameTokens) of
                    true -> Weight * 1.5;
                    false -> 0.0
                end,
                Acc + Weight + Bonus
        end
    end, 0.0, QTokens).

%% 组装对外返回的检索结果项。
presentChunk(Score, Chunk) ->
    #{
        module => maps:get(module, Chunk),
        function => maps:get(function, Chunk),
        arity => maps:get(arity, Chunk),
        file => maps:get(file, Chunk),
        lineStart => maps:get(lineStart, Chunk),
        lineEnd => maps:get(lineEnd, Chunk),
        score => round3(Score),
        snippet => snippet(maps:get(text, Chunk))
    }.

%%%===================================================================
%%% 语料构建
%%%===================================================================

%% 为单个模块的每个函数生成 chunk。
%% 会向前扫描函数定义上方的 `-spec` 与 `%%` 注释行，作为 spec/docstring
%% 拼接到 chunk 文本前，提升检索与 embedding 的语义信号。
chunksForModule(Mod) ->
    case alCodeIndexer:getModule(Mod) of
        {ok, Entry} ->
            AbsPath = maps:get(absPath, Entry, undefined),
            Funs = maps:get(functions, Entry, []),
            File = maps:get(file, Entry, <<>>),
            case readLines(AbsPath) of
                {ok, Lines} ->
                    Total = length(Lines),
                    ModTokens = tokenize(atom_to_binary(Mod, utf8)),
                    [buildChunk(Mod, File, ModTokens, Lines, Total, F) || F <- Funs];
                error ->
                    []
            end;
        _ ->
            []
    end.

%% 从函数行号范围切片源码并构建 chunk（含 tf 向量与名称分词）。
%% 会向前扫描 `-spec` 与 `%%` 注释，拼接到 text 前以增强语义。
buildChunk(Mod, File, ModTokens, Lines, Total, Fun) ->
    Name = maps:get(name, Fun),
    Arity = maps:get(arity, Fun, 0),
    Start = maps:get(line_start, Fun, 1),
    End0 = maps:get(line_end, Fun, 0),
    End = case End0 >= Start of true -> End0; false -> Total end,
    SpecDoc = extractSpecDoc(Lines, Start),
    BodyText = sliceLines(Lines, Start, End),
    Text = case SpecDoc of
        <<>> -> BodyText;
        _ -> <<SpecDoc/binary, "\n"/utf8, BodyText/binary>>
    end,
    NameTokens = tokenize(atom_to_binary(Name, utf8)) ++ ModTokens,
    Tokens = tokenize(Text) ++ NameTokens,
    Tf = termFreq(Tokens),
    Id = iolist_to_binary([atom_to_binary(Mod, utf8), <<":">>,
                           atom_to_binary(Name, utf8), <<"/">>,
                           integer_to_binary(Arity)]),
    #{
        id => Id,
        module => Mod,
        function => Name,
        arity => Arity,
        file => File,
        lineStart => Start,
        lineEnd => End,
        text => Text,
        nameTokens => lists:usort(NameTokens),
        tf => Tf
    }.

%% 向前扫描函数定义上方的 `-spec` 与 `%%`/`%` 注释行，拼为 spec/docstring。
%% 遇到空行或非注释行即停止，避免误纳入上一个函数的代码。
extractSpecDoc(Lines, FunStart) ->
    extractSpecDoc(Lines, FunStart - 1, []).

extractSpecDoc(_Lines, N, Acc) when N < 1 ->
    joinSpecDoc(Acc);
extractSpecDoc(Lines, N, Acc) ->
    Line = lists:nth(N, Lines),
    Trimmed = string:trim(Line),
    case classifyLine(Trimmed) of
        spec -> extractSpecDoc(Lines, N - 1, [Trimmed | Acc]);
        comment -> extractSpecDoc(Lines, N - 1, [Trimmed | Acc]);
        blank -> extractSpecDoc(Lines, N - 1, Acc);
        other -> joinSpecDoc(Acc)
    end.

%% 判断行类型：-spec / %% 注释 / 空行 / 其他。
classifyLine(<<"-spec", _/binary>>) -> spec;
classifyLine(<<"%%", _/binary>>) -> comment;
classifyLine(<<"%", _/binary>>) -> comment;
classifyLine(<<>>) -> blank;
classifyLine(_Other) -> other.

%% 拼接 spec/docstring 行。
joinSpecDoc([]) -> <<>>;
joinSpecDoc(Lines) ->
    iolist_to_binary(lists:join(<<"\n"/utf8>>, Lines)).

%% 统计词频。
termFreq(Tokens) ->
    lists:foldl(fun(T, Acc) ->
        maps:update_with(T, fun(C) -> C + 1 end, 1, Acc)
    end, #{}, Tokens).

%%%===================================================================
%%% 分词
%%%===================================================================

%% @doc 标识符感知分词：拆分 camelCase / snake_case / 非字母数字，
%% 统一小写，剔除停用词与过短 token。
-spec tokenize(binary() | string() | atom()) -> [binary()].
tokenize(Text) when is_atom(Text) -> tokenize(atom_to_binary(Text, utf8));
tokenize(Text) when is_list(Text) -> tokenize(unicode:characters_to_binary(Text));
tokenize(Text) when is_binary(Text) ->
    %% 在小写/大写边界插入空格以拆分 camelCase
    Split1 = re:replace(Text, <<"([a-z0-9])([A-Z])"/utf8>>, <<"\\1 \\2"/utf8>>,
                        [global, {return, binary}]),
    Lower = string:lowercase(Split1),
    Raw = re:split(Lower, <<"[^a-z0-9]+"/utf8>>, [{return, binary}, trim]),
    [T || T <- Raw, byte_size(T) >= 2, not lists:member(T, ?STOPWORDS)].

%%%===================================================================
%%% 工具函数
%%%===================================================================

%% 读取文件并按行切分。
readLines(undefined) -> error;
readLines(AbsPath) ->
    case file:read_file(AbsPath) of
        {ok, Content} -> {ok, binary:split(Content, <<"\n"/utf8>>, [global])};
        _ -> error
    end.

%% 取 [Start, End]（1-based，含端点）行并以换行拼接。
sliceLines(Lines, Start, End) ->
    Len = max(End - Start + 1, 1),
    Selected = lists:sublist(Lines, Start, Len),
    iolist_to_binary(lists:join(<<"\n"/utf8>>, Selected)).

%% 取前若干非空行作为预览片段。
snippet(Text) ->
    Lines = binary:split(Text, <<"\n"/utf8>>, [global]),
    NonEmpty = [L || L <- Lines, string:trim(L) =/= <<>>],
    Head = lists:sublist(NonEmpty, ?SNIPPET_LINES),
    iolist_to_binary(lists:join(<<"\n"/utf8>>, Head)).

%% 保留三位小数。
round3(F) -> round(F * 1000) / 1000.

%% 多类型转 UTF-8 二进制。
toBinary(B) when is_binary(B) -> B;
toBinary(L) when is_list(L) -> unicode:characters_to_binary(L);
toBinary(A) when is_atom(A) -> atom_to_binary(A, utf8);
toBinary(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).

%% 确保 chunk ETS 表存在。
ensureTable() ->
    case ets:info(?CHUNKS) of
        undefined ->
            ets:new(?CHUNKS, [named_table, public, set, {read_concurrency, true}]);
        _ ->
            ok
    end,
    ok.

%% 确保语料库已建立（懒加载）。
ensureIndexed(Config) ->
    ensureTable(),
    case persistent_term:get(?COUNT_KEY, 0) of
        0 -> index(Config);
        _ -> ok
    end.
