%%%-------------------------------------------------------------------
%% @doc 搜索查询改写器：将自然语言查询转为代码搜索关键词。
%%
%% 用户提问如"如何处理错误"难以直接用 ripgrep 命中 `try/catch` 代码。
%% 本模块用 LLM 将自然语言查询改写为 3-6 个搜索关键词（含 snake_case /
%% camelCase 变体），大幅提升代码搜索召回率。
%%
%% 改写结果带 ETS 缓存（按查询文本哈希），同一查询在会话内不重复调用 LLM。
%% LLM 不可用或超时时降级为原始查询的空格分词。
%% @end
%%%-------------------------------------------------------------------

-module(alQueryRewrite).

-export([rewrite/1, rewrite/2, clearCache/0]).
%% 测试导出 —— 纯辅助函数
-export([rewritePrompt/1, parseTerms/1, fallbackTerms/1, cacheKey/1]).
%% 缓存写入（测试导出：验证缓存键为查询文本 binary）
-export([storeCache/2]).

-define(RewriteTimeoutMs, 4000).
-define(CacheTtlMs, 300000).
-define(CacheTable, alQueryRewriteCache).

%%--------------------------------------------------------------------
%% @doc
%% 改写查询的简化入口：使用默认选项调用 {@link rewrite/2}。
%%
%% @param Query 自然语言查询
%% @return [binary()] 搜索关键词列表
%% @end
%%--------------------------------------------------------------------
rewrite(Query) ->
    rewrite(Query, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 将自然语言查询改写为代码搜索关键词列表。
%%
%% 流程：
%% 1. 查 ETS 缓存，命中则直接返回
%% 2. 调用 LLM 改写（带超时），解析 JSON 数组
%% 3. LLM 失败/超时时降级为原始查询分词
%% 4. 写入缓存后返回
%%
%% @param Query 自然语言查询
%% @param Opts 选项（timeoutMs、useCache）
%% @return [binary()] 搜索关键词列表（至少 1 个）
%% @end
%%--------------------------------------------------------------------
rewrite(Query, Opts) ->
    BinQuery = toBinary(Query),
    case BinQuery of
        <<>> -> [<<>>];
        _ ->
            UseCache = maps:get(useCache, Opts, true),
            case UseCache andalso lookupCache(BinQuery) of
                {ok, Terms} ->
                    Terms;
                false ->
                    Timeout = maps:get(timeoutMs, Opts, ?RewriteTimeoutMs),
                    Terms = doRewrite(BinQuery, Timeout),
                    case UseCache of
                        true -> storeCache(BinQuery, Terms);
                        false -> ok
                    end,
                    Terms
            end
    end.

%%--------------------------------------------------------------------
%% @doc 清空改写缓存。
%% @end
%%--------------------------------------------------------------------
clearCache() ->
    case ets:whereis(?CacheTable) of
        undefined -> ok;
        _ -> ets:match_delete(?CacheTable, {'_', '_', '_'})
    end.

%%%===================================================================
%%% Internal helpers
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 实际执行 LLM 改写：构造消息、调用 chat（带超时）、解析结果。
%% 失败时降级为 fallbackTerms。
%% @end
%%--------------------------------------------------------------------
doRewrite(Query, TimeoutMs) ->
    Messages = [
        #{role => system, content => rewritePrompt(Query)},
        #{role => user, content => Query}
    ],
    Opts = #{
        execTimeout => TimeoutMs,
        llmRecvTimeout => TimeoutMs,
        llmConnectTimeout => min(5000, TimeoutMs),
        llmMaxRetries => 0,
        %% 查询改写属廉价辅助任务：链路由时优先 aux 角色（本地模型）。
        llmRole => aux
    },
    case alLlmClient:chat(Messages, Opts) of
        {ok, Reply} ->
            Content = maps:get(content, Reply, <<>>),
            case parseTerms(Content) of
                [] -> fallbackTerms(Query);
                Terms -> Terms
            end;
        {error, _Reason} ->
            fallbackTerms(Query)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 构造改写 LLM 的系统提示。要求 LLM 返回纯 JSON 数组，包含
%% 翻译后的英文关键词及 snake_case/camelCase 变体。
%% @end
%%--------------------------------------------------------------------
rewritePrompt(_Query) ->
    <<"你是代码搜索查询优化器。从用户问题中提取 3-6 个能命中代码库的搜索词。\n\n"
      "规则：\n"
      "- 非英文问题要译成适合搜代码的英文关键词（标识符、API 名）\n"
      "- 同时包含概念词与可能的实现名\n"
      "- 相关时给出 snake_case 与 camelCase 变体\n"
      "- 优先具体标识符，少用泛词\n"
      "- 只返回 JSON array（字符串数组），不要解释\n\n"
      "示例：\n"
      "\"how to handle errors\" => [\"try\", \"catch\", \"error_handler\", \"handle_error\"]\n"
      "\"如何处理错误\" => [\"try\", \"catch\", \"error_handler\", \"handle_error\"]\n"
      "\"where is session saved\" => [\"session\", \"save\", \"persist\", \"write_session\"]"/utf8>>.

%%--------------------------------------------------------------------
%% @doc
%% 解析 LLM 返回的 JSON 数组为关键词列表。
%% 容忍前后多余文本、code fence 包裹等。
%% @end
%%--------------------------------------------------------------------
parseTerms(Content) when is_binary(Content) ->
    Trimmed = extractJsonArray(Content),
    try alJson:decode(Trimmed) of
        Terms when is_list(Terms) ->
            [toBinary(T) || T <- Terms, is_binary(T) orelse is_list(T)];
        _ ->
            []
    catch
        _:_ ->
            []
    end.

%% 从可能含 markdown fence 或解释文本的响应中提取 JSON 数组段。
extractJsonArray(Content) ->
    case binary:match(Content, <<"[">>) of
        nomatch -> <<>>;
        {Start, _} ->
            case binary:match(Content, <<"]">>) of
                nomatch -> <<>>;
                {End, _} ->
                    binary:part(Content, Start, End - Start + 1)
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 降级分词：LLM 不可用时，按空格/标点拆分原始查询。
%% 中文查询无法分词时原样返回。
%% @end
%%--------------------------------------------------------------------
fallbackTerms(Query) ->
    %% 按空格拆分；若无空格（如纯中文），返回原始查询
    Parts = binary:split(Query, [<<" ">>, <<"\t">>], [global, trim_all]),
    case [P || P <- Parts, P =/= <<>>] of
        [] -> [Query];
        [Query] -> [Query];
        List -> List
    end.

%%--------------------------------------------------------------------
%% @doc 计算缓存 key（查询文本 binary 本身，无 phash2）。
%%--------------------------------------------------------------------
cacheKey(Query) ->
    toBinary(Query).

%%%===================================================================
%%% ETS cache
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc 确保 ETS 表存在（由 alEtsOwner 持有，这里只 ensure）。
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

lookupCache(Query) ->
    case ets:whereis(?CacheTable) of
        undefined -> false;
        _ ->
            Key = toBinary(Query),
            case ets:lookup(?CacheTable, Key) of
                [{_, Terms, Expiry}] when is_integer(Expiry) ->
                    case erlang:system_time(millisecond) < Expiry of
                        true -> {ok, Terms};
                        false -> false
                    end;
                _ ->
                    false
            end
    end.

storeCache(Query, Terms) ->
    ensureCacheTable(),
    Key = toBinary(Query),
    Expiry = erlang:system_time(millisecond) + ?CacheTtlMs,
    ets:insert(?CacheTable, {Key, Terms, Expiry}),
    ok.

%%--------------------------------------------------------------------
%% @doc 归一化为 binary。
%%--------------------------------------------------------------------
toBinary(Term) when is_binary(Term) -> Term;
toBinary(Term) when is_list(Term) -> list_to_binary(Term);
toBinary(Term) when is_atom(Term) -> atom_to_binary(Term, utf8);
toBinary(_) -> <<>>.
