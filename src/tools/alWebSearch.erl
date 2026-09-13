%%%-------------------------------------------------------------------
%% @doc LLM agent 的网络搜索工具。
%%
%% 返回查询结果列表（title/url/snippet/index），供 agent 引用后结合
%% fetchUrl 读取正文。后端（engine）可配置：
%%   - `duckduckgo'：DuckDuckGo Instant Answer API，无需 key
%%   - `duckduckgo_html'：DuckDuckGo HTML 端点，通用网页结果，无需 key
%%   - `wikipedia'：Wikipedia 搜索 API，无需 key（language 可配）
%%   - `bing'：Bing Web Search API，需配置 apiKey
%%   - `auto'（默认）：duckduckgo → duckduckgo_html → [bing] → wikipedia 逐级回退
%%     （配置了 bingApiKey 时在 Wikipedia 前插入 Bing；空结果与错误均回退）
%%
%% 可靠性设计：
%%   - 每条结果带 1-based `index'，配合系统提示词要求 LLM 用 [n] 标注引用
%%   - 同引擎限流（minIntervalMs）：两次请求最小间隔，防 DuckDuckGo 封禁
%%   - 结果缓存（cacheTtlMs）：相同 {engine,query,limit,offset,freshness}
%%     在 TTL 内直接复用，0 关闭
%%   - `freshness' 时间范围过滤（day/week/month/year）：
%%     ddg_html 用 df 参数，bing 用 freshness 参数；其余引擎忽略
%%   - `offset' 翻页：ddg_html(s) / wikipedia(sroffset) / bing(offset)
%%
%% 另提供：
%%   - {@link extractMainContent/1}：轻量 readability 正文提取（纯函数），
%%     供 fetchUrl / fetchUrlPage 去除 HTML 噪音
%%   - {@link webQa/1}：搜索→抓取→LLM 汇总的一站式网络问答工具
%%
%% 配置（alConfig:get(webSearch, #{})）：
%%   - `engine'      默认引擎（默认 auto）
%%   - `maxResults'  默认结果数（默认 5，上限 10）
%%   - `timeoutMs'   请求超时（默认 10000）
%%   - `bingApiKey'  Bing 订阅密钥（engine=bing 时必填）
%%   - `language'    Wikipedia 语言代码（默认 zh）
%%   - `enabled'     总开关（默认 true，false 时返回 disabled）
%%   - `minIntervalMs' 同引擎最小请求间隔（默认 1100，0 关闭）
%%   - `cacheTtlMs'  结果缓存 TTL（默认 300000，0 关闭）
%%
%% 端点全部为固定 https 域名，无用户可控 URL，不受 SSRF 影响。
%% @end
%%%-------------------------------------------------------------------
-module(alWebSearch).

-export([search/1, webQa/1, status/0, probe/0]).
%% Test helpers: 纯解析 / 参数归一
-export([parseDuckDuckGo/1, parseDuckDuckGoHtml/1, parseWikipedia/1, parseBing/1,
         clampLimit/1, stripHtml/1, engineList/0, autoEngineChain/1,
         extractMainContent/1, normalizeFreshness/1, freshnessParam/2,
         addResultIndexes/1, decodeEntities/1, buildWebQaMessages/2,
         snippetDigest/1, sourcesWithPages/2]).

-define(DefaultMaxResults, 5).
-define(MaxResults, 10).
-define(DefaultTimeoutMs, 10000).
-define(DefaultMinIntervalMs, 1100).
-define(DefaultCacheTtlMs, 300000).
-define(SearchCache, alWebSearchCache).
-define(SearchCacheMax, 64).
-define(ThrottleTable, alWebSearchThrottle).
%% webQa：每页正文截取上限
-define(WebQaPageBytes, 3000).

%%--------------------------------------------------------------------
%% @doc
%% 执行一次 web 搜索。Args 支持 `query'（必填）与可选 `limit'、`engine'、
%% `freshness'、`offset'。
%%
%% @param Args 参数 map
%% @return `{ok, #{query, engine, count, results => [#{index, title, url, snippet}]}}'
%%         | `{error, #{reason, ...}}'
%% @end
%%--------------------------------------------------------------------
search(#{query := Query} = Args) when is_binary(Query), Query =/= <<>> ->
    case enabled() of
        false ->
            {error, #{reason => disabled}};
        true ->
            Engine = normalizeEngine(maps:get(engine, Args, configuredEngine())),
            Limit = clampLimit(maps:get(limit, Args, configuredMaxResults())),
            Offset = clampOffset(maps:get(offset, Args, 0)),
            Freshness = normalizeFreshness(maps:get(freshness, Args, undefined)),
            Timeout = configuredTimeout(),
            case cachedSearch(Engine, Query, Limit, Offset, Freshness) of
                {ok, Results} ->
                    {ok, resultPacket(Query, Engine, Results)};
                miss ->
                    case doSearch(Engine, Query, Limit, Offset, Freshness, Timeout) of
                        {ok, Results} ->
                            cacheSearch(Engine, Query, Limit, Offset, Freshness, Results),
                            {ok, resultPacket(Query, Engine, Results)};
                        {error, _} = E ->
                            E
                    end
            end
    end;
search(_) ->
    {error, #{reason => missingQuery}}.

resultPacket(Query, Engine, Results0) ->
    Results = addResultIndexes(Results0),
    Base = #{query => Query, engine => Engine,
             count => length(Results), results => Results},
    case Results of
        [] ->
            Base#{note => <<"未找到相关结果；可换关键词，或在 webSearch.bingApiKey 配置 Bing 以增强 auto 链"/utf8>>};
        _ ->
            Base
    end.

%% 为结果列表添加 1-based index，供 LLM [n] 引用标注。
addResultIndexes(Results) when is_list(Results) ->
    {Indexed, _} =
        lists:mapfoldl(fun(R, I) -> {R#{index => I}, I + 1} end, 1, Results),
    Indexed;
addResultIndexes(Other) ->
    Other.

%%%===================================================================
%%% Engines
%%%===================================================================

%% auto：Instant Answer → HTML → [Bing] → Wikipedia（空结果与错误均回退）。
doSearch(auto, Query, Limit, Offset, Freshness, Timeout) ->
    searchChain(autoEngineChain(), Query, Limit, Offset, Freshness, Timeout);
doSearch(Engine, Query, Limit, Offset, Freshness, Timeout) when Engine =:= duckduckgo ->
    searchChain([duckduckgo, duckduckgo_html],
                Query, Limit, Offset, Freshness, Timeout);
doSearch(Engine, Query, Limit, Offset, Freshness, Timeout) when Engine =:= duckduckgo_html;
                                                                Engine =:= wikipedia;
                                                                Engine =:= bing ->
    searchEngine(Engine, Query, Limit, Offset, Freshness, Timeout);
doSearch(Engine, _Query, _Limit, _Offset, _Freshness, _Timeout) ->
    {error, #{reason => unknownEngine, engine => Engine}}.

autoEngineChain() ->
    autoEngineChain(configuredBingKey()).

autoEngineChain(undefined) ->
    [duckduckgo, duckduckgo_html, wikipedia];
autoEngineChain(_Key) ->
    [duckduckgo, duckduckgo_html, bing, wikipedia].

%% 依序尝试引擎：非空结果即返回；空/错误继续，全失败返回最后错误（含 triedEngines）。
searchChain(Engines, Query, Limit, Offset, Freshness, Timeout) ->
    searchChain(Engines, Query, Limit, Offset, Freshness, Timeout, undefined, []).
searchChain([], _Query, _Limit, _Offset, _Freshness, _Timeout, LastError, Tried) ->
    case LastError of
        undefined -> {ok, []};
        E -> {error, enrichSearchError(E, Tried)}
    end;
searchChain([Engine | Rest], Query, Limit, Offset, Freshness, Timeout, LastError, Tried) ->
    case searchEngine(Engine, Query, Limit, Offset, Freshness, Timeout) of
        {ok, [_ | _] = Results} ->
            {ok, lists:sublist(Results, Limit)};
        {ok, []} ->
            searchChain(Rest, Query, Limit, Offset, Freshness, Timeout,
                        LastError, [Engine | Tried]);
        {error, _} = E ->
            searchChain(Rest, Query, Limit, Offset, Freshness, Timeout,
                        E, [Engine | Tried])
    end.

enrichSearchError(E, Tried) when is_map(E) ->
    E#{triedEngines => lists:reverse(Tried)};
enrichSearchError(E, Tried) ->
    #{reason => E, triedEngines => lists:reverse(Tried)}.

searchEngine(duckduckgo, Query, Limit, Offset, Freshness, Timeout)
  when Offset =:= 0; Offset =:= undefined ->
    %% Instant Answer 无翻页/时间过滤参数
    _ = Freshness,
    Url = <<"https://api.duckduckgo.com/?",
            (uri_string:compose_query(
                [{<<"q">>, Query}, {<<"format">>, <<"json">>},
                 {<<"no_html">>, <<"1">>}, {<<"skip_disambig">>, <<"1">>}]))/binary>>,
    case fetchJson(Url, jsonHeaders(), Timeout) of
        {ok, Bin} ->
            case parseDuckDuckGo(Bin) of
                {ok, Results} -> {ok, lists:sublist(Results, Limit)};
                {error, _} = E -> E
            end;
        {error, _} = E -> E
    end;
searchEngine(duckduckgo, _Query, _Limit, _Offset, _Freshness, _Timeout) ->
    %% Instant Answer 不支持 offset > 0，直接交由上层回退处理
    {ok, []};
searchEngine(duckduckgo_html, Query, Limit, Offset, Freshness, Timeout) ->
    throttleEngine(),
    Url = <<"https://html.duckduckgo.com/html/">>,
    Params0 = [{<<"q">>, Query}],
    Params1 = case Offset of N when is_integer(N), N > 0 -> [{<<"s">>, integer_to_binary(N)} | Params0]; _ -> Params0 end,
    Params = case freshnessParam(duckduckgo_html, Freshness) of
        undefined -> Params1;
        DF -> [{<<"df">>, DF} | Params1]
    end,
    Body = uri_string:compose_query(Params),
    Headers = [{<<"content-type">>, <<"application/x-www-form-urlencoded">>}
               | browserHeaders()],
    case fetchPost(Url, Headers, Body, Timeout) of
        {ok, Html} ->
            case parseDuckDuckGoHtml(Html) of
                {ok, Results} -> {ok, lists:sublist(Results, Limit)};
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end;
searchEngine(wikipedia, Query, Limit, Offset, _Freshness, Timeout) ->
    throttleEngine(),
    Lang = configuredLanguage(),
    Params = [{<<"action">>, <<"query">>}, {<<"list">>, <<"search">>},
              {<<"format">>, <<"json">>}, {<<"srsearch">>, Query},
              {<<"srlimit">>, integer_to_binary(Limit)}]
        ++ case Offset of N when is_integer(N), N > 0 -> [{<<"sroffset">>, integer_to_binary(N)}]; _ -> [] end,
    Url = <<"https://", Lang/binary, ".wikipedia.org/w/api.php?",
            (uri_string:compose_query(Params))/binary>>,
    case fetchJson(Url, jsonHeaders(), Timeout) of
        {ok, Bin} -> parseWikipedia(Bin);
        {error, _} = E -> E
    end;
searchEngine(bing, Query, Limit, Offset, Freshness, Timeout) ->
    case configuredBingKey() of
        undefined ->
            {error, #{reason => missingApiKey,
                      detail => <<"webSearch.bingApiKey not configured">>}};
        Key ->
            Params0 = [{<<"q">>, Query}, {<<"count">>, integer_to_binary(Limit)}],
            Params1 = case Offset of N when is_integer(N), N > 0 -> [{<<"offset">>, integer_to_binary(N)} | Params0]; _ -> Params0 end,
            Params = case freshnessParam(bing, Freshness) of
                undefined -> Params1;
                F -> [{<<"freshness">>, F} | Params1]
            end,
            Url = <<"https://api.bing.microsoft.com/v7.0/search?",
                    (uri_string:compose_query(Params))/binary>>,
            Headers = [{<<"Ocp-Apim-Subscription-Key">>, Key}],
            case fetchJson(Url, Headers, Timeout) of
                {ok, Bin} -> parseBing(Bin);
                {error, _} = E -> E
            end
    end.

%%%===================================================================
%%% webQa：搜索 → 抓取 → LLM 汇总
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 一站式网络问答：搜索问题 → 并发抓取前 N 条结果正文 → LLM 汇总，
%% 返回带引用编号的 answer 与 sources。
%%
%% @param Args 含 `question'（必填）与可选 `searchLimit'、`fetchLimit'、
%%        `freshness'
%% @return `{ok, #{question, answer, sources => [#{index,title,url}]}}'
%%         | `{error, #{reason, ...}}'
%% @end
%%--------------------------------------------------------------------
webQa(#{question := Q} = Args) when is_binary(Q), Q =/= <<>> ->
    case enabled() of
        false ->
            {error, #{reason => disabled}};
        true ->
            SearchLimit = clampLimit(maps:get(searchLimit, Args, ?DefaultMaxResults)),
            FetchLimit = clampFetchLimit(maps:get(fetchLimit, Args, 3)),
            Freshness = normalizeFreshness(maps:get(freshness, Args, undefined)),
            Timeout = configuredTimeout(),
            case search(#{query => Q, limit => SearchLimit, freshness => Freshness}) of
                {ok, #{results := Results}} ->
                    answerFromResults(Q, Results, FetchLimit, Timeout);
                {error, _} = E ->
                    E
            end
    end;
webQa(_) ->
    {error, #{reason => missingQuestion}}.

answerFromResults(Q, Results, FetchLimit, Timeout) ->
    Urls = [Url || #{url := Url} <- Results,
                  is_binary(Url), Url =/= <<>>,
                 %% 仅抓 http/https 链接
                  begin
                      case binary:match(Url, <<"http">>) of
                          {0, _} -> true;
                          _ -> false
                      end
                  end],
    Pages = fetchConcurrent(lists:sublist(Urls, FetchLimit), Timeout),
    Sources = sourcesWithPages(Results, Pages),
    Note = case Pages of
               [] -> <<"正文抓取全部失败，改用搜索摘要汇总"/utf8>>;
               _ -> undefined
           end,
    case summarizeAnswer(Q, Sources) of
        {ok, Answer} ->
            Reply = Answer#{question => Q, sources => Sources},
            case Note of
                undefined -> {ok, Reply};
                N -> {ok, Reply#{note => N}}
            end;
        {error, _} ->
            Digest = snippetDigest(Sources),
            case Digest of
                <<>> ->
                    {ok, #{question => Q, answer => <<>>, sources => Sources,
                           note => <<"检索摘要为空且 LLM 汇总失败"/utf8>>}};
                _ ->
                    {ok, #{question => Q, answer => Digest, sources => Sources,
                           note => <<"LLM 汇总失败，answer 为搜索摘要拼接"/utf8>>}}
            end
    end.

summarizeAnswer(Q, Sources) ->
    case Sources of
        [] ->
            {error, noSources};
        _ ->
            Messages = buildWebQaMessages(Q, Sources),
            case alLlmClient:chat(Messages, #{llmRole => aux}) of
                {ok, #{content := Content}} when is_binary(Content), Content =/= <<>> ->
                    {ok, #{answer => Content}};
                {ok, _} ->
                    {error, summarizeEmpty};
                {error, _} = E ->
                    E
            end
    end.

snippetDigest(Sources) ->
    iolist_to_binary([
        [begin
             Snip = case maps:get(pageText, S, undefined) of
                        undefined -> maps:get(snippet, S, <<>>);
                        Text -> Text
                    end,
             [<<"[", (intToBin(maps:get(index, S, I)))/binary, "] ",
               (maps:get(title, S, <<>>))/binary, "：",
               Snip/binary, "\n\n">>]
         end || {I, S} <- enumerate(Sources)]
    ]).

%% 抓取页正文与搜索结果合并：按 url 关联，命中页带 pageText。
sourcesWithPages(Results, Pages) ->
    PageMap = maps:from_list([{Url, Text} || {Url, _Title, Text} <- Pages]),
    [begin
        Src0 = #{index => maps:get(index, R, I), title => maps:get(title, R, <<>>),
                 url => maps:get(url, R, <<>>),
                 %% 抓取失败以及 fetchLimit 之外的结果仍保留搜索摘要，
                 %% 供汇总和无 LLM 降级答案使用。
                 snippet => maps:get(snippet, R, <<>>)},
        case maps:find(Url, PageMap) of
            {ok, Text} -> Src0#{pageText => Text};
            error -> Src0
        end
     end || {I, R} <- enumerate(Results), #{url := Url} <- [R]].

enumerate(L) ->
    {Indexed, _} = lists:mapfoldl(fun(X, I) -> {{I, X}, I + 1} end, 1, L),
    Indexed.

%% 并发抓取多个 URL，超时自动放弃（demonitor+flush 防孤儿 DOWN 消息），
%% 返回成功页 [{Url, Title, TextHead}]。
fetchConcurrent([], _Timeout) ->
    [];
fetchConcurrent(Urls, Timeout) ->
    Started = [{U, spawn_monitor(fun() ->
        Res = alToolsExt:fetchUrl(#{url => U, timeout => Timeout}),
        exit({fetched, U, Res})
    end)} || U <- Urls],
    Monitors = [{U, Pid, Ref} || {U, {Pid, Ref}} <- Started],
    Deadline = erlang:monotonic_time(millisecond) + Timeout + 5000,
    collectFetched(Monitors, Deadline, []).

collectFetched(Monitors, Deadline, Acc) ->
    Left = Deadline - erlang:monotonic_time(millisecond),
    case Left =< 0 of
        true ->
            finishCollect(Monitors, Acc);
        false ->
            receive
                {'DOWN', Ref, process, _Pid, {fetched, Url, {ok, R}}} ->
                    case lists:keydelete(Ref, 3, Monitors) of
                        Monitors ->
                            collectFetched(Monitors, Deadline, Acc);
                        Rest ->
                            Entry = {Url, maps:get(title, R, <<>>),
                                     capBinary(maps:get(body, R, <<>>), ?WebQaPageBytes)},
                            collectFetched(Rest, Deadline, [Entry | Acc])
                    end;
                {'DOWN', Ref, process, _Pid, _Other} ->
                    case lists:keydelete(Ref, 3, Monitors) of
                        Monitors -> collectFetched(Monitors, Deadline, Acc);
                        Rest -> collectFetched(Rest, Deadline, Acc)
                    end
            after Left ->
                finishCollect(Monitors, Acc)
            end
    end.

finishCollect(Monitors, Acc) ->
    _ = [erlang:demonitor(Ref, [flush]) || {_, _, Ref} <- Monitors],
    lists:reverse(Acc).

capBinary(B, Max) when is_binary(B), byte_size(B) > Max ->
    binary:part(B, 0, Max);
capBinary(B, _Max) when is_binary(B) ->
    B;
capBinary(_, _) ->
    <<>>.

%% 构造 webQa 的 LLM 消息（system 指令 + 资料 + 问题）。
buildWebQaMessages(Question, Sources) ->
    User = iolist_to_binary([
        <<"问题："/utf8>>, Question, <<"\n\n资料：\n"/utf8>>,
        [begin
             EvidenceKind = case maps:get(pageText, S, undefined) of
                 undefined -> <<"搜索摘要"/utf8>>;
                 _ -> <<"网页正文"/utf8>>
             end,
             [<<"[", (intToBin(maps:get(index, S, I)))/binary, "] ",
               (maps:get(title, S, <<>>))/binary, "\n",
               (maps:get(url, S, <<>>))/binary, "\n",
               "证据类型："/utf8, EvidenceKind/binary, "\n",
               (case maps:get(pageText, S, undefined) of
                    undefined -> maps:get(snippet, S, <<>>);
                    Text -> Text
                end)/binary, "\n\n">>]
         end || {I, S} <- enumerate(Sources)]
    ]),
    [
        #{role => <<"system">>,
          content => <<"你是严谨的网络检索助手。只依据给定资料回答问题；"
                       "每个可核验的事实性结论都要在句末标注 [n]，编号只能来自资料；"
                       "引用必须真正支持紧邻的结论，不能用只有标题或无内容的来源作证；"
                       "优先采用网页正文，搜索摘要只作为低置信补充；资料冲突时明确指出；"
                       "回答末尾输出 Sources 列表（每行：[n] 标题 — URL）。"
                       "Sources 中的标题和 URL 必须逐字复制资料，不得生成新链接。"
                       "资料不足以回答时如实说明，禁止编造。回答语言与问题一致。"/utf8>>},
        #{role => <<"user">>, content => User}
    ].

intToBin(I) when is_integer(I) -> integer_to_binary(I);
intToBin(B) when is_binary(B) -> B;
intToBin(_) -> <<"1">>.

%%%===================================================================
%% HTML readability 正文提取（纯函数，供 fetchUrl/fetchUrlPage 使用）
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 轻量 readability 正文提取：去除 script/style/nav/aside 等噪音块，
%% 优先取 `<article>' / `<main>' 内容，块级标签转换行，剥离内联标签
%% 并解码实体，最后压缩连续空行。
%%
%% @param Html HTML binary
%% @return `{Title, Text}'：Title 为 `<title>' 文本（无则 <<>>），
%%         Text 为提取后的正文纯文本
%% @end
%%--------------------------------------------------------------------
extractMainContent(Html) when is_binary(Html) ->
    Title = pageTitle(Html),
    Cleaned = stripNoiseBlocks(Html),
    Body = pickMainBlock(Cleaned),
    Text = blockTagsToNewlines(Body),
    NoTags = stripHtml(Text),
    {Title, collapseBlankLines(NoTags)};
extractMainContent(_) ->
    {<<>>, <<>>}.

pageTitle(Html) ->
    case re:run(Html, "(?is)<title[^>]*>(.*?)</title>",
                [{capture, all_but_first, binary}]) of
        {match, [T]} -> trimWhitespace(decodeEntities(T));
        nomatch -> <<>>
    end.

%% 整块移除的噪音元素。
stripNoiseBlocks(Html) ->
    Patterns = ["(?is)<script[^>]*>.*?</script\\s*>",
                "(?is)<style[^>]*>.*?</style\\s*>",
                "(?is)<noscript[^>]*>.*?</noscript\\s*>",
                "(?is)<svg[^>]*>.*?</svg\\s*>",
                "(?is)<iframe[^>]*>.*?</iframe\\s*>",
                "(?is)<form[^>]*>.*?</form\\s*>",
                "(?is)<nav[^>]*>.*?</nav\\s*>",
                "(?is)<aside[^>]*>.*?</aside\\s*>",
                "(?is)<header[^>]*>.*?</header\\s*>",
                "(?is)<footer[^>]*>.*?</footer\\s*>",
                "(?s)<!--.*?-->"],
    lists:foldl(fun(P, Acc) ->
        re:replace(Acc, P, " ", [global, {return, binary}])
    end, Html, Patterns).

%% 优先 article（内容 ≥ 400 字节），其次 main，否则整个文档。
pickMainBlock(Html) ->
    case largestBlock(Html, "(?is)<article[^>]*>(.*?)</article\\s*>") of
        {ok, Art} when byte_size(Art) >= 400 -> Art;
        _ ->
            case re:run(Html, "(?is)<main[^>]*>(.*?)</main\\s*>",
                        [{capture, all_but_first, binary}]) of
                {match, [Main]} when byte_size(Main) >= 200 -> Main;
                _ -> Html
            end
    end.

%% 多个同名块取最大者（article 可能多个）。
largestBlock(Html, Pattern) ->
    case re:run(Html, Pattern, [global, {capture, all_but_first, binary}]) of
        {match, Matches} ->
            case [B || [B] <- Matches] of
                [] -> error;
                Blocks ->
                    {Max, _} = lists:foldl(fun(B, {Best, Sz}) ->
                        case byte_size(B) > Sz of
                            true -> {B, byte_size(B)};
                            false -> {Best, Sz}
                        end
                    end, {<<>>, 0}, Blocks),
                    {ok, Max}
            end;
        nomatch ->
            error
    end.

%% 块级标签闭合处转换行，保证正文段落结构。
blockTagsToNewlines(Html) ->
    re:replace(Html,
               "(?i)</?(p|div|br|li|ul|ol|tr|table|section|article|main|"
               "h[1-6]|blockquote|pre|dd|dt|dl)[^>]*>",
               "\n",
               [global, {return, binary}]).

trimWhitespace(Bin) ->
    re:replace(Bin, "^[\\s\\t]+|[\\s\\t]+$", "", [global, {return, binary}]).

%% 压缩连续空白行为单个空行。
collapseBlankLines(Bin) ->
    Replaced = re:replace(Bin, "^[ \\t]+", "", [global, multiline, {return, binary}]),
    re:replace(Replaced, "\\n[ \\t]*\\n([ \\t]*\\n)+", "\n\n",
               [global, {return, binary}]).

%%%===================================================================
%%% Parsers（纯函数，便于测试）
%%%===================================================================

%% DuckDuckGo HTML lite：result__a / result__snippet。
parseDuckDuckGoHtml(Bin) when is_binary(Bin) ->
    Pattern = "class=\"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>([^<]*)</a>",
    case re:run(Bin, Pattern, [global, {capture, all_but_first, binary}]) of
        {match, Matches} ->
            Snippets = ddgHtmlSnippets(Bin),
            Results = lists:zipwith(fun([Url, Title], Snippet) ->
                #{
                    title => stripHtml(Title),
                    url => normalizeDdgUrl(Url),
                    snippet => trimSnippet(Snippet)
                }
            end, Matches, padSnippets(Snippets, length(Matches))),
            {ok, dedupe(Results)};
        nomatch ->
            {ok, []}
    end;
parseDuckDuckGoHtml(_) ->
    {ok, []}.

ddgHtmlSnippets(Bin) ->
    Pat = "class=\"result__snippet\"[^>]*>([^<]*)</a>",
    case re:run(Bin, Pat, [global, {capture, all_but_first, binary}]) of
        {match, Matches} -> [stripHtml(S) || [S] <- Matches];
        nomatch -> []
    end.

padSnippets(Snippets, N) ->
    case length(Snippets) >= N of
        true -> lists:sublist(Snippets, N);
        false -> Snippets ++ lists:duplicate(N - length(Snippets), <<>>)
    end.

normalizeDdgUrl(<<"/l/?", _/binary>> = Url) ->
    case uri_string:dissect_query(unicode:characters_to_list(Url)) of
        Params when is_list(Params) ->
            case proplists:get_value("uddg", Params) of
                Uddg when is_list(Uddg), Uddg =/= "" ->
                    unicode:characters_to_binary(Uddg);
                _ ->
                    Url
            end;
        _ ->
            Url
    end;
normalizeDdgUrl(Url) ->
    Url.

%% DuckDuckGo Instant Answer：AbstractText + RelatedTopics（含嵌套）。
parseDuckDuckGo(Bin) ->
    try alJson:decode(Bin) of
        Decoded when is_map(Decoded) ->
            Abstract = case maps:get(<<"AbstractText">>, Decoded, <<>>) of
                Text when is_binary(Text), Text =/= <<>> ->
                    [#{title => maps:get(<<"Heading">>, Decoded, <<>>),
                       url => maps:get(<<"AbstractURL">>, Decoded, <<>>),
                       snippet => trimSnippet(Text)}];
                _ -> []
            end,
            Topics = parseDdgTopics(maps:get(<<"RelatedTopics">>, Decoded, [])),
            {ok, dedupe(Abstract ++ Topics)};
        _ ->
            {ok, []}
    catch
        _:_ -> {error, #{reason => badJson}}
    end.

parseDdgTopics(Topics) when is_list(Topics) ->
    lists:append([parseDdgTopic(T) || T <- Topics]);
parseDdgTopics(_) ->
    [].

parseDdgTopic(#{<<"Topics">> := Nested}) when is_list(Nested) ->
    parseDdgTopics(Nested);
parseDdgTopic(#{<<"Text">> := Text, <<"FirstURL">> := Url}) when is_binary(Text) ->
    [#{title => <<>>, url => Url, snippet => trimSnippet(Text)}];
parseDdgTopic(_) ->
    [].

%% Wikipedia：query.search[].title/snippet（snippet 含 HTML 高亮标签）。
parseWikipedia(Bin) ->
    try alJson:decode(Bin) of
        #{<<"query">> := #{<<"search">> := Items}} when is_list(Items) ->
            Results = [begin
                Title = maps:get(<<"title">>, I, <<>>),
                Snippet = stripHtml(maps:get(<<"snippet">>, I, <<>>)),
                #{title => Title,
                  url => <<"https://", (configuredLanguage())/binary,
                           ".wikipedia.org/wiki/", (uri_string:quote(Title))/binary>>,
                  snippet => trimSnippet(Snippet)}
            end || I <- Items, is_map(I)],
            {ok, dedupe(Results)};
        _ ->
            {ok, []}
    catch
        _:_ -> {error, #{reason => badJson}}
    end.

%% Bing：webPages.value[].name/url/snippet。
parseBing(Bin) ->
    try alJson:decode(Bin) of
        #{<<"webPages">> := #{<<"value">> := Items}} when is_list(Items) ->
            Results = [#{title => maps:get(<<"name">>, I, <<>>),
                         url => maps:get(<<"url">>, I, <<>>),
                         snippet => trimSnippet(maps:get(<<"snippet">>, I, <<>>))}
                       || I <- Items, is_map(I)],
            {ok, dedupe(Results)};
        _ ->
            {ok, []}
    catch
        _:_ -> {error, #{reason => badJson}}
    end.

%%%===================================================================
%%% Helpers
%%%===================================================================

%% 按 url 去重，并裁剪 snippet 到 300 字符。
dedupe(Results) ->
    dedupe(Results, #{}, []).
dedupe([], _Seen, Acc) ->
    lists:reverse(Acc);
dedupe([#{url := Url} = R | Rest], Seen, Acc) ->
    case is_map_key(Url, Seen) of
        true -> dedupe(Rest, Seen, Acc);
        false -> dedupe(Rest, Seen#{Url => true}, [R | Acc])
    end.

trimSnippet(Bin) when is_binary(Bin) ->
    case byte_size(Bin) > 300 of
        true -> <<(binary:part(Bin, 0, 300))/binary, "...">>;
        false -> Bin
    end;
trimSnippet(_) ->
    <<>>.

%% 去除 HTML 标签并解码常见实体（含数字实体）。
stripHtml(Bin) when is_binary(Bin) ->
    NoTags = re:replace(Bin, "<[^>]*>", "", [global, {return, binary}]),
    decodeEntities(NoTags);
stripHtml(_) ->
    <<>>.

decodeEntities(Bin) when is_binary(Bin) ->
    Named = decodeNumericEntities(Bin),
    %% 非 ASCII 实体用显式 UTF-8 字节，避免源码编码差异
    Pairs = [{<<"&amp;">>, <<"&">>}, {<<"&lt;">>, <<"<">>},
             {<<"&gt;">>, <<">">>}, {<<"&quot;">>, <<"\"">>},
             {<<"&#39;">>, <<"'">>}, {<<"&apos;">>, <<"'">>},
             {<<"&nbsp;">>, <<" ">>},
             {<<"&hellip;">>, <<226, 128, 166>>},
             {<<"&mdash;">>, <<226, 128, 148>>},
             {<<"&ndash;">>, <<226, 128, 147>>},
             {<<"&middot;">>, <<194, 183>>},
             {<<"&laquo;">>, <<194, 171>>},
             {<<"&raquo;">>, <<194, 187>>}],
    lists:foldl(fun({From, To}, Acc) ->
        binary:replace(Acc, From, To, [global])
    end, Named, Pairs);
decodeEntities(Other) ->
    Other.

%% 十六/十进制数字实体 &#N; / &#xH; → UTF-8（合法码点才替换）。
decodeNumericEntities(Bin) ->
    case re:run(Bin, <<"&#(x[0-9a-fA-F]+|[0-9]+);">>,
                [global, {capture, all_but_first, binary}]) of
        {match, Groups} ->
            lists:foldl(fun([G], Acc) ->
                Cp = case G of
                    <<"x", Hex/binary>> -> binary_to_integer(Hex, 16);
                    _ -> binary_to_integer(G)
                end,
                case validCodepoint(Cp) of
                    true ->
                        Entity = <<"&#", G/binary, ";">>,
                        binary:replace(Acc, Entity,
                                       unicode:characters_to_binary([Cp]), [global]);
                    false ->
                        Acc
                end
            end, Bin, Groups);
        nomatch ->
            Bin
    end.

validCodepoint(Cp) when Cp >= 32, Cp =< 16#D7FF -> true;
validCodepoint(Cp) when Cp >= 16#E000, Cp =< 16#10FFFF -> true;
validCodepoint(_) -> false.

clampLimit(N) when is_integer(N) -> min(max(N, 1), ?MaxResults);
clampLimit(_) -> ?DefaultMaxResults.

clampFetchLimit(N) when is_integer(N) -> min(max(N, 1), 5);
clampFetchLimit(_) -> 3.

clampOffset(N) when is_integer(N), N >= 0 -> N;
clampOffset(_) -> 0.

engineList() ->
    [auto, duckduckgo, duckduckgo_html, wikipedia, bing].

%% 将 engine 参数归一为 atom（LLM 从 JSON 传入时为 binary）。
normalizeEngine(E) when is_atom(E) -> E;
normalizeEngine(E) when is_binary(E) ->
    try binary_to_existing_atom(E, utf8) catch _:_ -> E end;
normalizeEngine(E) -> E.

%% freshness 归一：day|week|month|year（atom/binary 均可），非法返回 undefined。
normalizeFreshness(F) when F =:= undefined; F =:= null -> undefined;
normalizeFreshness(F) when is_atom(F) ->
    case lists:member(F, [day, week, month, year]) of true -> F; _ -> undefined end;
normalizeFreshness(F) when is_binary(F) ->
    normalizeFreshness(try binary_to_existing_atom(F, utf8) catch _:_ -> F end);
normalizeFreshness(_) -> undefined.

%% 各引擎的 freshness 参数值：ddg_html→df(d/w/m/y)，bing→Day/Week/Month；
%% 不支持的引擎返回 undefined。
freshnessParam(duckduckgo_html, day) -> <<"d">>;
freshnessParam(duckduckgo_html, week) -> <<"w">>;
freshnessParam(duckduckgo_html, month) -> <<"m">>;
freshnessParam(duckduckgo_html, year) -> <<"y">>;
freshnessParam(bing, day) -> <<"Day">>;
freshnessParam(bing, week) -> <<"Week">>;
freshnessParam(bing, month) -> <<"Month">>;
freshnessParam(bing, year) -> <<"Month">>;
freshnessParam(_, _) -> undefined.

%%%===================================================================
%%% 限流（同引擎最小间隔）
%%%===================================================================

throttleEngine() ->
    MinIv = configuredMinInterval(),
    case MinIv > 0 of
        false -> ok;
        true ->
            Key = engineThrottleKey(),
            Now = erlang:monotonic_time(millisecond),
            Last = case throttleLookup(Key) of
                {ok, L} -> L;
                error -> Now
            end,
            Wait = Last + MinIv - Now,
            case Wait > 0 of
                true -> timer:sleep(min(Wait, 3000));
                false -> ok
            end,
            throttleStore(Key, erlang:monotonic_time(millisecond))
    end.

engineThrottleKey() ->
    %% 按 BEAM 节点全局限流即可：所有引擎共用表，key 用固定 atom
    webSearchEngine.

throttleLookup(Key) ->
    ensureThrottleTable(),
    try ets:lookup(?ThrottleTable, Key) of
        [{Key, At}] -> {ok, At};
        [] -> error
    catch _:_ -> error end.

throttleStore(Key, At) ->
    ensureThrottleTable(),
    try ets:insert(?ThrottleTable, {Key, At}) catch _:_ -> ok end.

ensureThrottleTable() ->
    case ets:whereis(?ThrottleTable) of
        undefined ->
            try ets:new(?ThrottleTable,
                        [named_table, public, set,
                         {read_concurrency, true}, {write_concurrency, true}])
            catch _:_ -> ok end;
        _ -> ok
    end.

%%%===================================================================
%%% 结果缓存
%%%===================================================================

cachedSearch(Engine, Query, Limit, Offset, Freshness) ->
    case configuredCacheTtl() > 0 of
        false -> miss;
        true ->
            Key = {Engine, Query, Limit, Offset, Freshness},
            case cacheLookup(Key) of
                {ok, Results} -> {ok, Results};
                miss -> miss
            end
    end.

cacheSearch(_Engine, _Query, _Limit, _Offset, _Freshness, []) ->
    %% 空结果不缓存，便于换引擎/等待新内容
    ok;
cacheSearch(Engine, Query, Limit, Offset, Freshness, Results) ->
    case configuredCacheTtl() > 0 of
        false -> ok;
        true ->
            Key = {Engine, Query, Limit, Offset, Freshness},
            cacheStore(Key, Results)
    end.

cacheLookup(Key) ->
    ensureCacheTable(),
    try ets:lookup(?SearchCache, Key) of
        [{Key, Results, _Seq, StoredAt}] ->
            Now = erlang:system_time(millisecond),
            case Now - StoredAt =< configuredCacheTtl() of
                true -> {ok, Results};
                false ->
                    ets:delete(?SearchCache, Key),
                    miss
            end;
        [] ->
            miss
    catch _:_ -> miss end.

cacheStore(Key, Results) ->
    ensureCacheTable(),
    try
        Seq = erlang:unique_integer([positive, monotonic]),
        ets:insert(?SearchCache, {Key, Results, Seq, erlang:system_time(millisecond)}),
        evictCache()
    catch _:_ -> ok end.

%% 超 capacity 时按插入序号淘汰最旧条目（select 只投影 Seq，避免拷贝结果）。
evictCache() ->
    case ets:info(?SearchCache, size) of
        N when N > ?SearchCacheMax ->
            MS = [{{'$1', '_', '$2', '_'}, [], [{{'$2', '$1'}}]}],
            case ets:select(?SearchCache, MS) of
                [] -> ok;
                Entries ->
                    {_MinSeq, Key} = lists:min(Entries),
                    ets:delete(?SearchCache, Key),
                    evictCache()
            end;
        _ ->
            ok
    end.

ensureCacheTable() ->
    case ets:whereis(?SearchCache) of
        undefined ->
            try ets:new(?SearchCache,
                        [named_table, public, set,
                         {read_concurrency, true}, {write_concurrency, true}])
            catch _:_ -> ok end;
        _ -> ok
    end.

%%%===================================================================
%%% HTTP（带浏览器头，anti-bot 基础处理）
%%%===================================================================

%% 类 Chrome 请求头：DDG/多数站点对无 UA 请求直接拒绝或出验证页。
browserHeaders() ->
    [
        {<<"user-agent">>, configuredUserAgent()},
        {<<"accept">>, <<"text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8">>},
        {<<"accept-language">>, <<"zh-CN,zh;q=0.9,en;q=0.8">>}
    ].

jsonHeaders() ->
    [
        {<<"user-agent">>, configuredUserAgent()},
        {<<"accept">>, <<"application/json,text/plain,*/*;q=0.8">>}
    ].

configuredUserAgent() ->
    case maps:get(userAgent, webSearchCfg(), undefined) of
        UA when is_binary(UA), UA =/= <<>> -> UA;
        _ ->
            <<"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36">>
    end.

%% 发起 GET 并读取完整 JSON 正文；非 200 或解码失败返回 error。
fetchJson(Url, Headers, Timeout) ->
    Options = #{recvTimeout => Timeout, connectTimeout => Timeout},
    case alHttp:get(Url, Headers, Options) of
        {ok, Status, _RespHeaders, Body} when Status >= 200, Status < 300 ->
            {ok, Body};
        {ok, Status, _RespHeaders, _Body} ->
            {error, #{reason => httpError, status => Status}};
        {error, Reason} ->
            {error, #{reason => fetchFailed, detail => Reason}}
    end.

fetchPost(Url, Headers, Body, Timeout) ->
    Options = #{recvTimeout => Timeout, connectTimeout => Timeout},
    case alHttp:post(Url, Headers, Body, Options) of
        {ok, Status, _RespHeaders, RespBody} when Status >= 200, Status < 300 ->
            {ok, RespBody};
        {ok, Status, _RespHeaders, _RespBody} ->
            {error, #{reason => httpError, status => Status}};
        {error, Reason} ->
            {error, #{reason => fetchFailed, detail => Reason}}
    end.

%%%===================================================================
%%% Status / probe
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc 返回联网搜索配置快照（不发网络请求）。
%% @end
%%--------------------------------------------------------------------
status() ->
    case enabled() of
        false ->
            #{enabled => false, status => disabled};
        true ->
            #{enabled => true, status => configured,
              engine => configuredEngine(),
              chain => autoEngineChain(),
              language => configuredLanguage(),
              bingConfigured => configuredBingKey() =/= undefined}
    end.

%%--------------------------------------------------------------------
%% @doc 探测 auto 链上各引擎连通性（会发真实 HTTP 请求）。
%% @end
%%--------------------------------------------------------------------
probe() ->
    case enabled() of
        false ->
            #{enabled => false, status => disabled};
        true ->
            Timeout = min(configuredTimeout(), 8000),
            Chain = autoEngineChain(),
            EngineResults = [engineProbe(E, Timeout) || E <- Chain],
            Working = [E || {E, ok} <- EngineResults],
            Status = case Working of
                         [] -> degraded;
                         _ -> ok
                     end,
            #{enabled => true, status => Status,
              engine => configuredEngine(),
              chain => Chain,
              engines => maps:from_list(EngineResults),
              working => Working}
    end.

engineProbe(Engine, Timeout) ->
    Query = probeQuery(Engine),
    case searchEngine(Engine, Query, 1, 0, undefined, Timeout) of
        {ok, [_ | _]} -> {Engine, ok};
        {ok, []} -> {Engine, empty};
        {error, Reason} -> {Engine, {error, probeReason(Reason)}}
    end.

probeQuery(wikipedia) ->
    <<"Erlang">>;
probeQuery(_) ->
    <<"test">>.

probeReason(Reason) when is_map(Reason) ->
    maps:get(reason, Reason, Reason);
probeReason(Other) ->
    Other.

%%%===================================================================
%%% Config
%%%===================================================================

webSearchCfg() ->
    alConfig:get(webSearch, #{}).

enabled() ->
    maps:get(enabled, webSearchCfg(), true) =:= true.

configuredEngine() ->
    Engine = maps:get(engine, webSearchCfg(), auto),
    case lists:member(Engine, engineList()) of
        true -> Engine;
        false -> auto
    end.

configuredMaxResults() ->
    clampLimit(maps:get(maxResults, webSearchCfg(), ?DefaultMaxResults)).

configuredTimeout() ->
    case maps:get(timeoutMs, webSearchCfg(), ?DefaultTimeoutMs) of
        N when is_integer(N), N >= 1000 -> min(N, 60000);
        _ -> ?DefaultTimeoutMs
    end.

configuredLanguage() ->
    case maps:get(language, webSearchCfg(), <<"zh">>) of
        L when is_binary(L), L =/= <<>> -> L;
        _ -> <<"zh">>
    end.

configuredBingKey() ->
    case maps:get(bingApiKey, webSearchCfg(), undefined) of
        K when is_binary(K), K =/= <<>> -> K;
        _ -> undefined
    end.

configuredMinInterval() ->
    case maps:get(minIntervalMs, webSearchCfg(), ?DefaultMinIntervalMs) of
        N when is_integer(N), N >= 0 -> min(N, 10000);
        _ -> ?DefaultMinIntervalMs
    end.

configuredCacheTtl() ->
    case maps:get(cacheTtlMs, webSearchCfg(), ?DefaultCacheTtlMs) of
        N when is_integer(N), N >= 0 -> min(N, 3600000);
        _ -> ?DefaultCacheTtlMs
    end.
