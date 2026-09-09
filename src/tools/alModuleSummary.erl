%%%-------------------------------------------------------------------
%% @doc 模块级摘要的按需生成与缓存。
%%
%% 大型项目里"先搜摘要再钻代码"比直接搜代码更准。本模块在首次请求时
%% 用 {@link alCoreClient:moduleSymbols/1} + LLM 生成模块的一句话摘要，
%% 存入 SQLite（`module_summaries' 表）与 ETS 缓存。
%%
%% 流程：
%% <ul>
%% <li>{@link getOrGenerate/1}：查 ETS → SQLite，未命中则异步 spawn 生成，
%%     首次请求返回 `undefined'，下次命中。</li>
%% <li>{@link generate/1}：拉符号 → 构造 prompt → LLM → 解析 → 存库 + 缓存。</li>
%% <li>{@link search/1}：BM25 风格 LIKE 检索摘要文本，定位相关模块。</li>
%% <li>{@link invalidate/1}：文件变更时失效 ETS（不删 SQLite，下次覆盖）。</li>
%% </ul>
%%
%% LLM 失败/超时降级为 {@link fallbackSummary/1}（函数名拼接），
%% 保证摘要层永远可用。生成用 `fastModel' 或 `memoryDistillModel' 降本。
%% @end
%%%-------------------------------------------------------------------

-module(alModuleSummary).

%% get/1 与 BIF erlang:get/1（进程字典）冲突，禁用自动导入。
-compile({no_auto_import, [get/1]}).

-export([
    get/1,
    getOrGenerate/1,
    generate/1,
    search/1, search/2,
    invalidate/1,
    invalidateAll/0,
    clearCache/0
]).
%% 测试导出 — 纯辅助函数
-export([
    summaryPrompt/2,
    parseSummary/1,
    fallbackSummary/1,
    cacheKey/1,
    ensureCacheTable/0
]).

-define(CacheTable, alModuleSummaryCache).
-define(GenerateTimeoutMs, 8000).
-define(MaxFunctionsInPrompt, 30).
-define(MaxSummaryBytes, 600).
-define(DefaultSearchLimit, 8).

%%--------------------------------------------------------------------
%% @doc
%% 取模块摘要：ETS 缓存 → SQLite，未命中返回 `undefined'。
%%
%% @param Module 模块名（atom/binary/list）
%% @return `{ok, Summary}' | `undefined'
%% @end
%%--------------------------------------------------------------------
get(Module) ->
    Key = cacheKey(Module),
    case lookupCache(Key) of
        {ok, Summary} ->
            {ok, Summary};
        miss ->
            case fetchFromDb(Module) of
                {ok, Summary} ->
                    storeCache(Key, Summary),
                    {ok, Summary};
                undefined ->
                    undefined
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 取或异步生成：命中直接返回；未命中 spawn 异步生成（不阻塞调用方），
%% 首次请求返回 `undefined'，下次请求时生成完成即可命中。
%%
%% 异步生成避免 LLM 延迟（8s 超时）拖慢主响应；失败仅记日志。
%%
%% @param Module 模块名
%% @return `{ok, Summary}' | `undefined'
%% @end
%%--------------------------------------------------------------------
getOrGenerate(Module) ->
    case get(Module) of
        {ok, Summary} ->
            {ok, Summary};
        undefined ->
            spawn(fun() ->
                try
                    case generate(Module) of
                        {ok, _} -> ok;
                        {error, GenErr} ->
                            logger:debug("alModuleSummary generate failed for ~p: ~p",
                                         [Module, GenErr])
                    end
                catch
                    Class:CrashErr ->
                        logger:debug("alModuleSummary generate crashed: ~p:~p",
                                     [Class, CrashErr])
                end
            end),
            undefined
    end.

%%--------------------------------------------------------------------
%% @doc
%% 强制重新生成模块摘要：拉符号 → LLM → 存 SQLite + ETS。
%%
%% @param Module 模块名
%% @return `{ok, Summary}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
generate(Module) ->
    case fetchModuleSymbols(Module) of
        {ok, Doc} ->
            Summary = generateSummary(Module, Doc),
            File = maps:get(file, Doc, maps:get(<<"file">>, Doc, undefined)),
            Funs = maps:get(functions, Doc, maps:get(<<"functions">>, Doc, [])),
            LineCount = estimateLineCount(Funs),
            ok = saveSummary(Module, Summary, Funs, File, LineCount),
            storeCache(cacheKey(Module), Summary),
            {ok, Summary};
        {error, Reason} ->
            {error, Reason}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 按关键词检索模块摘要（SQL LIKE，按更新时间倒序）。
%%
%% @param Query 查询字符串
%% @return `{ok, [#{module, summary}]}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
search(Query) ->
    search(Query, ?DefaultSearchLimit).

%%--------------------------------------------------------------------
%% @doc
%% 按关键词检索模块摘要，限制返回条数。
%%
%% @param Query 查询字符串
%% @param Limit 返回上限
%% @return `{ok, [Row]}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
search(Query, Limit) ->
    Pattern = "%" ++ escapeLike(toList(Query)) ++ "%",
    Sql =
        "SELECT module, summary FROM module_summaries "
        "WHERE summary LIKE ? ESCAPE '\\' OR module LIKE ? ESCAPE '\\' "
        "ORDER BY updated_at DESC LIMIT ?",
    case alLocalDb:query(Sql, [Pattern, Pattern, Limit]) of
        {ok, Rows} ->
            {ok, [normalizeSearchRow(Row) || Row <- Rows]};
        Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% @doc
%% 失效模块摘要的 ETS 缓存（文件变更时调用）。
%% 不删 SQLite，下次 {@link getOrGenerate/1} 会重新生成并覆盖。
%%
%% @param Module 模块名
%% @return ok
%% @end
%%--------------------------------------------------------------------
invalidate(Module) ->
    Key = cacheKey(Module),
    case ets:whereis(?CacheTable) of
        undefined -> ok;
        _ -> ets:delete(?CacheTable, Key), ok
    end,
    deleteFromDb(Module).

%%--------------------------------------------------------------------
%% @doc 清空全部摘要：ETS + SQLite（文件监视器用，避免 stale 回填）。
%%--------------------------------------------------------------------
invalidateAll() ->
    clearCache(),
    try alLocalDb:execute("DELETE FROM module_summaries", []) of
        {ok, _} -> ok;
        {error, _} -> ok
    catch
        _:_ -> ok
    end.

%% 删除 SQLite 中指定模块的摘要行。
deleteFromDb(Module) ->
    Sql = "DELETE FROM module_summaries WHERE module = ?",
    try alLocalDb:execute(Sql, [toBinary(Module)]) of
        {ok, _} -> ok;
        {error, _} -> ok
    catch
        _:_ -> ok
    end.

%%--------------------------------------------------------------------
%% @doc 清空全部摘要缓存（不删 SQLite）。
%% @end
%%--------------------------------------------------------------------
clearCache() ->
    case ets:whereis(?CacheTable) of
        undefined -> ok;
        _ -> ets:match_delete(?CacheTable, '_'), ok
    end.

%%%===================================================================
%%% Internal helpers
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 构造摘要生成的 LLM 系统提示：要求一句话描述模块职责，不列函数。
%% @end
%%--------------------------------------------------------------------
summaryPrompt(Module, Funs) ->
    FunList = funList(Funs),
    iolist_to_binary([
        <<"你是 Erlang 代码摘要器。用一段话（2-4 句，约不超过 80 个英文词或等价中文量）">>,
        <<"概括模块职责、关键行为，以及从函数名可见的重要依赖。不要罗列函数；">>,
        <<"具体描述用途。用中文写摘要。\n\n">>,
        <<"模块: ">>, toBinary(Module), <<"\n">>,
        <<"函数: ">>, FunList
    ]).

%%--------------------------------------------------------------------
%% @doc
%% 解析 LLM 返回的摘要文本：trim、限长、非法输入返回空 binary。
%% @end
%%--------------------------------------------------------------------
parseSummary(Content) when is_binary(Content) ->
    Trimmed = string:trim(Content),
    case byte_size(Trimmed) > ?MaxSummaryBytes of
        true -> truncateUtf8(Trimmed, ?MaxSummaryBytes);
        false -> Trimmed
    end;
parseSummary(_) ->
    <<>>.

%% 按 UTF-8 码点边界截断，避免切断多字节字符（如中文）产生非法 UTF-8。
truncateUtf8(Bin, Max) when is_binary(Bin), byte_size(Bin) =< Max ->
    Bin;
truncateUtf8(Bin, Max) when is_binary(Bin) ->
    binary:part(Bin, 0, truncateUtf8Len(Bin, min(Max, byte_size(Bin))));
truncateUtf8(_Bin, _Max) ->
    <<>>.

truncateUtf8Len(_Bin, Len) when Len =< 0 ->
    0;
truncateUtf8Len(Bin, Len) ->
    truncateUtf8Len(Bin, Len, 0).

truncateUtf8Len(_Bin, 0, _Back) ->
    0;
truncateUtf8Len(Bin, Len, Back) when Back < 3 ->
    <<_:Len/binary, Byte, _/binary>> = Bin,
    case (Byte band 16#C0) =:= 16#80 of
        true -> truncateUtf8Len(Bin, Len - 1, Back + 1);
        false -> Len
    end;
truncateUtf8Len(_Bin, Len, _Back) ->
    Len.

%%--------------------------------------------------------------------
%% @doc
%% LLM 不可用/超时时的降级摘要：函数名拼接，保证摘要层永远可用。
%% @end
%%--------------------------------------------------------------------
fallbackSummary(Module) ->
    case fetchModuleSymbols(Module) of
        {ok, Doc} ->
            Funs = maps:get(functions, Doc, maps:get(<<"functions">>, Doc, [])),
            Names = [funName(F) || F <- lists:sublist(Funs, ?MaxFunctionsInPrompt)],
            iolist_to_binary([
                <<"Module ">>, toBinary(Module),
                <<" exports: ">>, lists:join(<<", ">>, Names), <<".">>
            ]);
        {error, _} ->
            <<"Module ", (toBinary(Module))/binary, ".">>
    end.

%%--------------------------------------------------------------------
%% @doc 计算缓存 key（模块名归一化为 binary）。
%%--------------------------------------------------------------------
cacheKey(Module) -> toBinary(Module).

%%--------------------------------------------------------------------
%% @doc 确保 ETS 缓存表存在（lazy 建表，幂等）。
%%--------------------------------------------------------------------
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

%%%===================================================================
%%% ETS cache
%%%===================================================================

lookupCache(Key) ->
    case ets:whereis(?CacheTable) of
        undefined -> miss;
        _ ->
            case ets:lookup(?CacheTable, Key) of
                [{_, Summary}] -> {ok, Summary};
                _ -> miss
            end
    end.

storeCache(Key, Summary) ->
    ensureCacheTable(),
    ets:insert(?CacheTable, {Key, Summary}),
    ok.

%%%===================================================================
%%% SQLite persistence
%%%===================================================================

%% 从 SQLite 拉取模块摘要。
fetchFromDb(Module) ->
    Sql = "SELECT summary FROM module_summaries WHERE module = ? LIMIT 1",
    try alLocalDb:query(Sql, [toBinary(Module)]) of
        {ok, [#{summary := Summary} | _]} when is_binary(Summary) ->
            {ok, Summary};
        {ok, [_ | _]} ->
            undefined;
        {ok, []} ->
            undefined;
        {error, _} ->
            undefined
    catch
        _:_ ->
            undefined
    end.

%% Upsert 摘要到 SQLite（INSERT OR REPLACE）。
saveSummary(Module, Summary, Funs, File, LineCount) ->
    Sql =
        "INSERT OR REPLACE INTO module_summaries "
        "(module, summary, functions, file, line_count, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
    Params = [
        toBinary(Module),
        toBinary(Summary),
        alJson:encode([funName(F) || F <- Funs]),
        toBinary(File),
        LineCount,
        erlang:system_time(second)
    ],
    case alLocalDb:execute(Sql, Params) of
        {ok, _} -> ok;
        {error, Reason} ->
            logger:debug("alModuleSummary save failed: ~p", [Reason]),
            ok
    end.

%% 规范化搜索结果行（module/summary 字段统一为 binary）。
normalizeSearchRow(Row) when is_map(Row) ->
    #{
        module => toBinary(maps:get(module, Row, <<>>)),
        summary => toBinary(maps:get(summary, Row, <<>>))
    };
normalizeSearchRow(Row) ->
    Row.

%%%===================================================================
%%% Module symbols fetch + LLM summary
%%%===================================================================

%% 拉取模块符号（core 出错时返回 error）。
fetchModuleSymbols(Module) ->
    try alCoreClient:moduleSymbols(Module) of
        {ok, #{data := #{document := Doc}}} when is_map(Doc) ->
            {ok, Doc};
        {ok, #{data := Doc}} when is_map(Doc) ->
            {ok, Doc};
        {ok, #{document := Doc}} when is_map(Doc) ->
            {ok, Doc};
        _ ->
            {error, noSymbols}
    catch
        Class:Reason ->
            {error, {Class, Reason}}
    end.

%% 调 LLM 生成摘要；失败降级为 fallbackSummary。
generateSummary(Module, Doc) ->
    Funs = maps:get(functions, Doc, maps:get(<<"functions">>, Doc, [])),
    Prompt = summaryPrompt(Module, Funs),
    Messages = [
        #{role => system, content => Prompt},
        #{role => user, content => <<"Summarize this module.">>}
    ],
    Opts = llmOptsForSummary(),
    case alLlmClient:chat(Messages, Opts) of
        {ok, #{content := Content}} ->
            parseSummary(Content);
        {ok, Reply} ->
            parseSummary(maps:get(content, Reply, <<>>));
        {error, Reason} ->
            logger:debug("alModuleSummary LLM failed, using fallback: ~p", [Reason]),
            fallbackSummary(Module)
    end.

%% 摘要生成用的 LLM 选项：优先用 fastModel/memoryDistillModel 降本；
%% 链路由时按 aux 角色（本地廉价模型）。
llmOptsForSummary() ->
    AgentCfg = alConfig:getAgentCfg(),
    Llm = maps:get(llm, AgentCfg, #{}),
    Override = case maps:get(memoryDistillModel, AgentCfg, undefined) of
        undefined -> maps:get(fastModel, Llm, undefined);
        DistillModel -> DistillModel
    end,
    Opts = case Override of
        undefined -> Llm;
        Model -> Llm#{model => Model}
    end,
    Opts#{llmRole => aux}.

%%%===================================================================
%%% Pure helpers
%%%===================================================================

%% 从函数列表提取签名串（用于 prompt 与存储）。
funList(Funs) when is_list(Funs) ->
    Names = [funSignature(F) || F <- lists:sublist(Funs, ?MaxFunctionsInPrompt)],
    lists:join(<<", ">>, Names);
funList(_) ->
    <<>>.

funSignature(F) when is_map(F) ->
    Name = funName(F),
    Arity = maps:get(arity, F, maps:get(<<"arity">>, F, <<>>)),
    <<Name/binary, "/", (toBinary(Arity))/binary>>;
funSignature(F) ->
    toBinary(F).

funName(F) when is_map(F) ->
    toBinary(maps:get(name, F, maps:get(<<"name">>, F, <<>>)));
funName(F) ->
    toBinary(F).

%% 粗略估算模块行数（函数数 * 15，仅用于排序参考）。
estimateLineCount(Funs) when is_list(Funs) ->
    max(1, length(Funs)) * 15;
estimateLineCount(_) ->
    0.

%% 转义 LIKE 通配符（与 alMemory 一致）。
escapeLike(Str) ->
    lists:flatmap(fun(C) ->
        case C of
            $% -> [$\\, $%];
            $_ -> [$\\, $_];
            $\\ -> [$\\, $\\];
            _ -> [C]
        end
    end, Str).

%%--------------------------------------------------------------------
%% @doc 归一化为 binary。
%% @end
%%--------------------------------------------------------------------
toBinary(V) when is_binary(V) -> V;
toBinary(V) when is_atom(V) -> atom_to_binary(V, utf8);
toBinary(V) when is_list(V) -> unicode:characters_to_binary(V);
toBinary(V) -> unicode:characters_to_binary(io_lib:format("~p", [V])).

%%--------------------------------------------------------------------
%% @doc 归一化为 list。
%% @end
%%--------------------------------------------------------------------
toList(V) when is_list(V) -> V;
toList(V) when is_binary(V) -> unicode:characters_to_list(V);
toList(V) when is_atom(V) -> atom_to_list(V);
toList(V) -> io_lib:format("~p", [V]).
