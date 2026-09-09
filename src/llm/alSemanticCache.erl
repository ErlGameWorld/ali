%%%-------------------------------------------------------------------
%% @doc 语义缓存：重复问题零 LLM 调用直接返回缓存答案。
%%
%% 设计（优先级 0 的"免费模型"，排在本地模型链之前）：
%% <ul>
%%   <li>键：规范化问题指纹（小写、去标点、去停用词、token 排序 sha1）
%%       —— 换措辞但核心关键词相同的问题可命中</li>
%%   <li>失效：put 时记录答案引用文件的 mtime 指纹；lookup 命中后校验
%%       这些文件未变更，变更则 miss（代码变了旧答案不可信）</li>
%%   <li>存储：ETS 热表 + dataDir/semantic_cache.jsonl 全量持久化，
%%       重启懒加载；TTL 7 天；上限 ?MaxEntries 条按 LRU 淘汰</li>
%%   <li>安全阀：写意图问题 / 挂起审批轮次不缓存（依赖实时状态）</li>
%% </ul>
%%
%% 刻意不走 Qdrant 相似度：embedding 查询要过 Port + 外部 API（百毫秒级），
%% 对"重复问题秒回"场景得不偿失；指纹匹配零成本且覆盖主要复现场景。
%% @end
%%%-------------------------------------------------------------------

-module(alSemanticCache).

-include_lib("kernel/include/file.hrl").

-export([lookup/1, put/3, reset/0, ensureStarted/0, enabled/0]).
%% Test exports — pure helpers
-export([questionFingerprint/1, normalizeQuestion/1, isCacheableQuestion/1,
         filesFingerprint/1, entryValid/3]).

-define(Table, ali_semantic_cache).
-define(File, <<"semantic_cache.jsonl">>).
-define(TtlSeconds, 7 * 86400).
-define(MaxEntries, 2000).
-define(EvictBatch, 400).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc 是否启用语义缓存（agent.semanticCacheEnabled，默认 true）。
%% @end
%%--------------------------------------------------------------------
-spec enabled() -> boolean().
enabled() ->
    Agent = alConfig:get(agent, #{}),
    maps:get(semanticCacheEnabled, Agent, true) =/= false.

%%--------------------------------------------------------------------
%% @doc 确保 ETS 就绪（懒加载 JSONL 重建）。
%% @end
%%--------------------------------------------------------------------
-spec ensureStarted() -> ok.
ensureStarted() ->
    ensureLoaded().

%%--------------------------------------------------------------------
%% @doc
%% 查缓存：问题指纹命中 + 未过期 + 引用文件 mtime 未变 → {ok, Answer}。
%% 命中同时刷新 hits/lastHitAt（热度保活）。
%%
%% @param Question 用户问题
%% @return `{ok, Answer}' | miss
%% @end
%%--------------------------------------------------------------------
-spec lookup(binary() | list()) -> {ok, binary()} | miss.
lookup(Question) ->
    case enabled() of
        false -> miss;
        true ->
            Fp = questionFingerprint(Question),
            case Fp of
                <<>> -> miss;
                _ ->
                    ensureLoaded(),
                    case ets:lookup(?Table, Fp) of
                        [{_, Entry}] ->
                            case entryValid(Entry, filesFingerprint(
                                     maps:get(files, Entry, [])),
                                     erlang:system_time(second)) of
                                true ->
                                    touch(Fp, Entry),
                                    {ok, maps:get(answer, Entry, <<>>)};
                                false ->
                                    ets:delete(?Table, Fp),
                                    miss
                            end;
                        [] ->
                            miss
                    end
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 写缓存：critic pass 的答案 + 其引用文件列表。写后触发容量淘汰与落盘。
%% 不可缓存（写意图问题 / 空答案 / 无引用文件）时静默跳过——无引用文件
%% 的答案通常与代码无关（闲聊），缓存价值低且无失效锚点。
%%
%% @param Question 用户问题
%% @param Answer   最终答案（binary）
%% @param Files    答案引用的文件路径列表（用于 mtime 失效校验）
%% @return ok
%% @end
%%--------------------------------------------------------------------
-spec put(binary() | list(), binary(), [binary()]) -> ok.
put(Question, Answer, Files) when is_binary(Answer), is_list(Files) ->
    case enabled() andalso isCacheableQuestion(Question)
         andalso byte_size(Answer) >= 32 andalso Files =/= [] of
        false -> ok;
        true ->
            Fp = questionFingerprint(Question),
            case Fp of
                <<>> -> ok;
                _ ->
                    ensureLoaded(),
                    Now = erlang:system_time(second),
                    Entry = #{
                        answer => Answer,
                        files => lists:sublist(Files, 10),
                        filesFp => filesFingerprint(Files),
                        hits => 0,
                        createdAt => Now,
                        lastHitAt => Now
                    },
                    ets:insert(?Table, {Fp, Entry}),
                    maybeEvict(),
                    persist()
            end
    end;
put(_, _, _) ->
    ok.

%%--------------------------------------------------------------------
%% @doc 清空缓存（ETS + 文件）。
%% @end
%%--------------------------------------------------------------------
-spec reset() -> ok.
reset() ->
    case ets:whereis(?Table) of
        undefined -> ok;
        _ -> ets:delete_all_objects(?Table)
    end,
    _ = file:delete(filePath()),
    ok.

%%%===================================================================
%%% Pure helpers (test exports)
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 问题规范化：小写、去标点/空白、去停用词、token 排序去重。
%% "怎么调用 alSearch？" 与 "alSearch，怎么调用" 规范化后 token 集相同
%% （词序/标点/停用词不敏感；整句换措辞需语义相似度，刻意不做）。
%% @end
%%--------------------------------------------------------------------
-spec normalizeQuestion(binary() | list()) -> [binary()].
normalizeQuestion(Question) ->
    Bin = toBinary(Question),
    Lower = try string:lowercase(Bin) catch _:_ -> Bin end,
    %% PCRE 用 \x{...} 表示 BMP 码点（\u 不被 re 支持）；unicode 选项
    %% 让 \x{4e00}-\x{9fff} 按 UTF-8 解码而非按字节匹配。
    Parts = case re:split(Lower, <<"[^a-z0-9\\x{4e00}-\\x{9fff}]+">>,
                          [unicode, {return, binary}, trim]) of
        Tokens when is_list(Tokens) -> Tokens;
        _ -> []
    end,
    [P || P <- Parts, byte_size(P) >= 2, not isStopWord(P)].

%%--------------------------------------------------------------------
%% @doc 规范化 token 排序拼接后的 sha1 前 12 hex；无有效 token 返回 <<>>。
%% @end
%%--------------------------------------------------------------------
-spec questionFingerprint(binary() | list()) -> binary().
questionFingerprint(Question) ->
    Tokens = normalizeQuestion(Question),
    case Tokens of
        [] -> <<>>;
        _ ->
            Sorted = lists:usort(Tokens),
            Joined = iolist_to_binary(lists:join(<<"+">>, Sorted)),
            <<Hex:12/binary, _/binary>> = toHex(crypto:hash(sha, Joined)),
            Hex
    end.

%%--------------------------------------------------------------------
%% @doc
%% 写意图判定：问题含改/删/写/建/重命名等动作词时不缓存——这类答案
%% 依赖实时状态，且缓存跳过工具循环有安全风险。
%% @end
%%--------------------------------------------------------------------
-spec isCacheableQuestion(binary() | list()) -> boolean().
isCacheableQuestion(Question) ->
    Bin = toBinary(Question),
    Lower = try string:lowercase(Bin) catch _:_ -> Bin end,
    WriteCues = [
        <<"applypatch">>, <<"apply_patch">>, <<"删除"/utf8>>, <<"删掉"/utf8>>,
        <<"修改"/utf8>>, <<"改成"/utf8>>, <<"新建"/utf8>>, <<"创建"/utf8>>,
        <<"重命名"/utf8>>, <<"回滚"/utf8>>, <<"drop table">>, <<"delete from">>,
        <<"写入"/utf8>>, <<"覆盖"/utf8>>, <<"上线"/utf8>>, <<"发布"/utf8>>
    ],
    not lists:any(fun(C) -> binary:match(Lower, C) =/= nomatch end, WriteCues).

%%--------------------------------------------------------------------
%% @doc
%% 文件列表的 mtime 指纹：各文件 mtime（秒）排序拼接后 sha1 前 12 hex。
%% 文件不存在时该文件以 missing 计入（删除/重命名也算"变了"）。
%% @end
%%--------------------------------------------------------------------
-spec filesFingerprint([binary() | list()]) -> binary().
filesFingerprint(Files) when is_list(Files) ->
    Stamps = [fileStamp(F) || F <- Files, F =/= <<>>, F =/= undefined, F =/= []],
    case Stamps of
        [] -> <<>>;
        _ ->
            Joined = iolist_to_binary(lists:join(<<",">>, lists:sort(Stamps))),
            <<Hex:12/binary, _/binary>> = toHex(crypto:hash(sha, Joined)),
            Hex
    end;
filesFingerprint(_) ->
    <<>>.

fileStamp(File) ->
    Path = toBinary(File),
    %% file:read_file_info 返回 #file_info record 而非 map——必须用 record 取 mtime。
    try file:read_file_info(Path) of
        {ok, #file_info{mtime = {{Y, Mo, D}, {H, Mi, S}}}} ->
            <<Path/binary, "@", (integer_to_binary(Y))/binary, "-",
              (integer_to_binary(Mo))/binary, "-", (integer_to_binary(D))/binary,
              "T", (integer_to_binary(H))/binary, ":", (integer_to_binary(Mi))/binary,
              ":", (integer_to_binary(S))/binary>>;
        _ ->
            <<Path/binary, "@missing">>
    catch _:_ -> <<Path/binary, "@missing">> end.

%%--------------------------------------------------------------------
%% @doc
%% 缓存条目有效性：未超 TTL 且引用文件当前 mtime 指纹与写入时一致。
%% files 为空（历史脏数据）视为无效。
%% @end
%%--------------------------------------------------------------------
-spec entryValid(map(), binary(), integer()) -> boolean().
entryValid(Entry, CurrentFp, Now) when is_map(Entry) ->
    Files = maps:get(files, Entry, []),
    CreatedAt = maps:get(createdAt, Entry, 0),
    StoredFp = maps:get(filesFp, Entry, <<>>),
    Now - CreatedAt =< ?TtlSeconds
        andalso Files =/= []
        andalso CurrentFp =/= <<>>
        andalso CurrentFp =:= StoredFp;
entryValid(_, _, _) ->
    false.

%%%===================================================================
%%% 内部 — ETS + JSONL 持久化
%%%===================================================================

%% 懒加载：ETS 不存在则创建并从 JSONL 重建。
ensureLoaded() ->
    case ets:whereis(?Table) of
        undefined ->
            try ets:new(?Table, [named_table, public, set,
                                 {read_concurrency, true},
                                 {write_concurrency, true}]) of
                _ -> loadFile()
            catch _:_ -> ok end;
        _ ->
            ok
    end.

%% 从 dataDir/semantic_cache.jsonl 加载条目到 ETS。
loadFile() ->
    case file:read_file(filePath()) of
        {ok, Bin} when byte_size(Bin) > 0 ->
            Lines = binary:split(Bin, <<"\n">>, [global, trim_all]),
            lists:foreach(fun(Line) ->
                try alJson:decode(Line) of
                    #{<<"fingerprint">> := Fp} = M when is_binary(Fp) ->
                        %% JSON 解出的 key 是 binary，而 lookup/touch 用 atom key
                        %% 取值——不规范化会导致重启后缓存条目全部失效。
                        ets:insert(?Table, {Fp, normalizeLoadedEntry(M)});
                    _ -> ok
                catch _:_ -> ok end
            end, Lines);
        _ ->
            ok
    end.

%% 把 JSONL 解出的 binary-key map 规范化为内存条目的 atom-key map。
normalizeLoadedEntry(M) ->
    #{
        answer => toBinary(maps:get(<<"answer">>, M, <<>>)),
        files => filesFromJson(maps:get(<<"files">>, M, [])),
        filesFp => toBinary(maps:get(<<"filesFp">>, M, <<>>)),
        hits => intFromJson(maps:get(<<"hits">>, M, 0)),
        createdAt => intFromJson(maps:get(<<"createdAt">>, M, 0)),
        lastHitAt => intFromJson(maps:get(<<"lastHitAt">>, M, 0))
    }.

filesFromJson(L) when is_list(L) ->
    [toBinary(F) || F <- L, is_binary(F) orelse is_list(F)];
filesFromJson(_) ->
    [].

intFromJson(N) when is_integer(N) -> N;
intFromJson(_) -> 0.

%% 命中时更新 hits 与 lastHitAt（不写盘）。
touch(Fp, Entry) ->
    Now = erlang:system_time(second),
    try ets:update_element(?Table, Fp,
        [{2, Entry#{hits => maps:get(hits, Entry, 0) + 1, lastHitAt => Now}}])
    catch _:_ -> ok end,
    %% 命中不落盘：hits 只是热度参考，崩溃丢一点热度计数无伤大雅。
    ok.

%% 容量淘汰：超过上限时按（hits 升序, lastHitAt 升序）淘汰最冷 ?EvictBatch 条。
maybeEvict() ->
    try
        Size = ets:info(?Table, size),
        case Size > ?MaxEntries of
            true ->
                All = ets:tab2list(?Table),
                Sorted = lists:sort(fun({_, A}, {_, B}) ->
                    Ha = maps:get(hits, A, 0), Hb = maps:get(hits, B, 0),
                    case Ha =:= Hb of
                        true -> maps:get(lastHitAt, A, 0) =< maps:get(lastHitAt, B, 0);
                        false -> Ha < Hb
                    end
                end, All),
                [ets:delete(?Table, Fp) || {Fp, _} <- lists:sublist(Sorted, ?EvictBatch)],
                ok;
            false ->
                ok
        end
    catch _:_ -> ok end.

%% 全量 ETS 条目序列化为 JSONL 落盘。
persist() ->
    try
        Rows = ets:tab2list(?Table),
        Lines = [alJson:encode(maps:merge(#{<<"fingerprint">> => Fp}, Entry))
                 || {Fp, Entry} <- Rows],
        _ = file:write_file(filePath(),
                            iolist_to_binary([[L, $\n] || L <- Lines])),
        ok
    catch _:_ -> ok end.

filePath() ->
    try alConfig:dataPath(?File)
    catch _:_ -> ?File end.

%% 中英文停用词过滤（规范化分词用）。
isStopWord(P) ->
    lists:member(P, [
        <<"the">>, <<"and">>, <<"for">>, <<"with">>, <<"this">>, <<"that">>,
        <<"what">>, <<"how">>, <<"why">>, <<"when">>, <<"where">>, <<"which">>,
        <<"is">>, <<"are">>, <<"do">>, <<"does">>, <<"can">>, <<"could">>,
        <<"you">>, <<"me">>, <<"my">>, <<"it">>, <<"of">>, <<"to">>, <<"in">>,
        <<"on">>, <<"a">>, <<"an">>, <<"请">>, <<"帮">>, <<"我">>, <<"你">>,
        <<"的">>, <<"了">>, <<"吗">>, <<"呢">>, <<"啊">>, <<"怎么">>,
        <<"如何">>, <<"什么">>, <<"哪些">>, <<"一下">>, <<"看看">>
    ]).

toHex(Bin) ->
    list_to_binary(lists:flatten([io_lib:format("~2.16.0b", [B]) || <<B>> <= Bin])).

toBinary(B) when is_binary(B) -> B;
toBinary(A) when is_atom(A) -> atom_to_binary(A, utf8);
toBinary(L) when is_list(L) -> unicode:characters_to_binary(L);
toBinary(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).
