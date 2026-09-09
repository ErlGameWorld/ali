%%%-------------------------------------------------------------------
%% @doc 工具选择学习：问题意图指纹 → 高频工具统计，回流到检索 hint。
%%
%% 闭环：
%% <ul>
%%   <li>记录：agent 轮结束（critic pass/warn）时 {@link noteTurn/2}
%%       把本轮问题指纹 × 实际使用的工具累加进 ETS</li>
%%   <li>召回：{@link alContextEngine} 构建上下文时 {@link suggestTools/1}
%%       取同指纹 top 工具注入 hint，引导 LLM 优先用历史上顺手的工具</li>
%% </ul>
%%
%% 存储：ETS（`ali_tool_patterns'）热聚合 + dataDir/tool_patterns.jsonl
%% 全量持久化（数据量小：指纹 × 工具组合有限），重启懒加载重建。
%% 刻意不走 alLocalDb：文件后端按参数个数猜表，3 参数 INSERT 会被
%% 误路由到 memories.jsonl。
%% @end
%%%-------------------------------------------------------------------

-module(alToolLearn).

-export([noteTurn/2, suggestTools/1, suggestTools/2, reset/0, ensureStarted/0]).
%% Test exports — pure helpers
-export([typeFingerprint/1, toolsFromTrace/1, topTools/2, mergeHits/2,
         normalizeToolName/1]).

-define(Table, ali_tool_patterns).
-define(File, <<"tool_patterns.jsonl">>).
-define(DefaultSuggestLimit, 3).
-define(MaxPatterns, 20000).
-define(MaxToolsPerTurn, 12).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc 确保 ETS 与已加载数据就绪（懒加载：首次调用读 JSONL 重建 ETS）。
%% @end
%%--------------------------------------------------------------------
-spec ensureStarted() -> ok.
ensureStarted() ->
    ensureLoaded().

%%--------------------------------------------------------------------
%% @doc
%% 记录一轮成功问答的工具使用：问题指纹 × trace 中实际使用的每个工具各 +1，
%% 随后全量持久化到 JSONL。空工具序列 / 学习表满时静默跳过。
%%
%% @param Question 用户问题
%% @param Trace    工具循环 trace（含 {tool_calls, [...]} 条目）
%% @return ok
%% @end
%%--------------------------------------------------------------------
-spec noteTurn(binary() | list(), list()) -> ok.
noteTurn(Question, Trace) when is_list(Trace) ->
    case toolsFromTrace(Trace) of
        [] ->
            ok;
        Tools ->
            Fp = typeFingerprint(Question),
            case Fp of
                <<>> -> ok;
                _ ->
                    ensureLoaded(),
                    lists:foreach(fun(Tool) -> bump(Fp, Tool) end, Tools),
                    persist()
            end
    end;
noteTurn(_, _) ->
    ok.

%%--------------------------------------------------------------------
%% @doc
%% 按问题指纹取历史上高频的工具名（top-N，hits 降序）。
%%
%% @param Question 用户问题
%% @return [binary()] 工具名列表（无历史时为 []）
%% @end
%%--------------------------------------------------------------------
-spec suggestTools(binary() | list()) -> [binary()].
suggestTools(Question) ->
    suggestTools(Question, ?DefaultSuggestLimit).

-spec suggestTools(binary() | list(), pos_integer()) -> [binary()].
suggestTools(Question, Limit) when is_integer(Limit), Limit > 0 ->
    Fp = typeFingerprint(Question),
    case Fp of
        <<>> -> [];
        _ ->
            ensureLoaded(),
            topTools(Fp, Limit)
    end;
suggestTools(_, _) ->
    [].

%%--------------------------------------------------------------------
%% @doc 清空学习数据（ETS + 文件）。测试 / 用户重置用。
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
%% 问题意图指纹：小写分词 → 去停用词 → 前 5 个 token 排序拼接 → sha1 前 10 hex。
%% 同类问题（共享主要关键词）映射到同指纹；无法提取有效 token 时返回 <<>>。
%% @end
%%--------------------------------------------------------------------
-spec typeFingerprint(binary() | list()) -> binary().
typeFingerprint(Question) ->
    Tokens = significantTokens(Question),
    case Tokens of
        [] -> <<>>;
        _ ->
            Sorted = lists:usort(lists:sublist(Tokens, 5)),
            Joined = iolist_to_binary(lists:join(<<"+">>, Sorted)),
            <<Hex:10/binary, _/binary>> = toHex(crypto:hash(sha, Joined)),
            Hex
    end.

%%--------------------------------------------------------------------
%% @doc
%% 从工具循环 trace 提取实际使用的去重工具名（保序，上限 ?MaxToolsPerTurn）。
%% trace 条目形如 {tool_calls, [#{name => Tool, args => ...}]}。
%% @end
%%--------------------------------------------------------------------
-spec toolsFromTrace(list()) -> [binary()].
toolsFromTrace(Trace) when is_list(Trace) ->
    Raw = lists:flatmap(fun
        ({tool_calls, Calls}) when is_list(Calls) ->
            [normalizeToolName(maps:get(name, C, undefined))
             || C <- Calls, is_map(C)];
        ({directExec, Module, Function, _Arity}) ->
            [normalizeToolName(iolist_to_binary(io_lib:format("~p:~p", [Module, Function])))];
        ({directProbe, Tool}) ->
            [normalizeToolName(Tool)];
        (_) ->
            []
    end, Trace),
    dedupPreserveOrder([T || T <- Raw, T =/= <<>>, T =/= undefined]);
toolsFromTrace(_) ->
    [].

%%--------------------------------------------------------------------
%% @doc
%% 纯函数：从 {{Fp, Tool} → Hits} 映射取指定指纹的 top-N 工具（hits 降序、同分按名稳定）。
%% @end
%%--------------------------------------------------------------------
-spec topTools(binary(), pos_integer()) -> [binary()].
topTools(Fp, Limit) when is_binary(Fp), is_integer(Limit), Limit > 0 ->
    Hits = [{{Fp, Tool}, N} || {{K, Tool}, N} <- etsHits(), K =:= Fp],
    Sorted = lists:sort(fun({{_, A}, Na}, {{_, B}, Nb}) ->
        if
            Nb =/= Na -> Na > Nb;
            true -> A =< B
        end
    end, Hits),
    [Tool || {{_, Tool}, _} <- lists:sublist(Sorted, Limit)];
topTools(_, _) ->
    [].

%%--------------------------------------------------------------------
%% @doc 纯函数：合并两份 {Tool → Hits} 计数（后者覆盖前者数值时相加）。
%% @end
%%--------------------------------------------------------------------
-spec mergeHits(map(), map()) -> map().
mergeHits(A, B) when is_map(A), is_map(B) ->
    maps:fold(fun(Tool, N, Acc) ->
        Acc#{Tool => N + maps:get(Tool, Acc, 0)}
    end, A, B).

%% 工具名规范化：binary 小写；atom 转 binary；非法值转 <<>>（被过滤）。
normalizeToolName(T) when is_binary(T) ->
    case string:lowercase(T) of
        Lower when byte_size(Lower) > 0, byte_size(Lower) =< 64 -> Lower;
        _ -> <<>>
    end;
normalizeToolName(T) when is_atom(T) ->
    normalizeToolName(atom_to_binary(T, utf8));
normalizeToolName(T) when is_list(T) ->
    normalizeToolName(unicode:characters_to_binary(T));
normalizeToolName(_) ->
    <<>>.

%%%===================================================================
%%% Internal — ETS + JSONL persistence
%%%===================================================================

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

loadFile() ->
    case file:read_file(filePath()) of
        {ok, Bin} when byte_size(Bin) > 0 ->
            Lines = binary:split(Bin, <<"\n">>, [global, trim_all]),
            lists:foreach(fun(Line) ->
                try alJson:decode(Line) of
                    #{<<"fingerprint">> := Fp, <<"tool">> := Tool, <<"hits">> := N}
                            when is_binary(Fp), is_binary(Tool), is_number(N) ->
                        ets:insert(?Table, {{Fp, Tool}, trunc(N)});
                    _ -> ok
                catch _:_ -> ok end
            end, Lines);
        _ ->
            ok
    end.

etsHits() ->
    case ets:whereis(?Table) of
        undefined -> [];
        _ -> ets:tab2list(?Table)
    end.

bump(Fp, Tool) ->
    try ets:update_counter(?Table, {Fp, Tool}, 1, {{Fp, Tool}, 0})
    catch _:_ -> ok end.

persist() ->
    try
        Rows = ets:tab2list(?Table),
        case length(Rows) > ?MaxPatterns of
            true -> ok;  %% 防御性上限：学习数据异常膨胀时停止写盘
            false ->
                Lines = [alJson:encode(#{
                    <<"fingerprint">> => Fp,
                    <<"tool">> => Tool,
                    <<"hits">> => Hits
                }) || {{Fp, Tool}, Hits} <- Rows],
                _ = file:write_file(filePath(),
                                    iolist_to_binary([[L, $\n] || L <- Lines])),
                ok
        end
    catch _:_ -> ok end.

filePath() ->
    try alConfig:dataPath(?File)
    catch _:_ -> ?File end.

significantTokens(Question) ->
    Bin = toBinary(Question),
    Lower = try string:lowercase(Bin) catch _:_ -> Bin end,
    Parts = re:split(Lower, <<"[\\s,;:|/\\\\<>\\[\\](){}\"'，。；：、？！]+"/utf8>>,
                     [{return, binary}, trim]),
    [P || P <- Parts, byte_size(P) >= 2,
          not isStopWord(P)].

isStopWord(P) ->
    lists:member(P, [
        <<"the">>, <<"and">>, <<"for">>, <<"with">>, <<"this">>, <<"that">>,
        <<"what">>, <<"how">>, <<"why">>, <<"when">>, <<"where">>, <<"which">>,
        <<"is">>, <<"are">>, <<"do">>, <<"does">>, <<"can">>, <<"could">>,
        <<"you">>, <<"me">>, <<"my">>, <<"it">>, <<"of">>, <<"to">>, <<"in">>,
        <<"on">>, <<"a">>, <<"an">>, <<"的">>, <<"了">>, <<"是">>, <<"我">>,
        <<"你">>, <<"在">>, <<"吗">>, <<"什么">>, <<"怎么">>, <<"如何">>,
        <<"请">>, <<"帮">>, <<"看">>, <<"下">>, <<"一下">>, <<"有没有">>
    ]).

toHex(Bin) ->
    list_to_binary(lists:flatten([io_lib:format("~2.16.0b", [B]) || <<B>> <= Bin])).

dedupPreserveOrder(Items) ->
    {_, Out} = lists:foldl(fun(I, {Seen, Acc}) ->
        case maps:is_key(I, Seen) of
            true -> {Seen, Acc};
            false -> {Seen#{I => true}, [I | Acc]}
        end
    end, {#{}, []}, Items),
    lists:sublist(lists:reverse(Out), ?MaxToolsPerTurn).

toBinary(B) when is_binary(B) -> B;
toBinary(A) when is_atom(A) -> atom_to_binary(A, utf8);
toBinary(L) when is_list(L) -> unicode:characters_to_binary(L);
toBinary(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).
