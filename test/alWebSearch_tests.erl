%%% @doc EUnit tests for alWebSearch: pure parsers + argument validation.
-module(alWebSearch_tests).

-include_lib("eunit/include/eunit.hrl").

-define(setup, begin ok = alConfig:load() end).

%%%===================================================================
%%% search/1 参数校验
%%%===================================================================

search_missing_query_test() ->
    ?assertMatch({error, #{reason := missingQuery}}, alWebSearch:search(#{})),
    ?assertMatch({error, #{reason := missingQuery}}, alWebSearch:search(#{limit => 3})).

search_empty_query_test() ->
    ?assertMatch({error, #{reason := missingQuery}}, alWebSearch:search(#{query => <<>>})).

search_unknown_engine_test() ->
    ?setup,
    ?assertMatch({error, #{reason := unknownEngine}},
                 alWebSearch:search(#{query => <<"x">>, engine => bogus})).

%%%===================================================================
%%% auto 链 / 摘要保底
%%%===================================================================

auto_engine_chain_no_bing_test() ->
    ?assertEqual([duckduckgo, duckduckgo_html, wikipedia],
                 alWebSearch:autoEngineChain(undefined)).

auto_engine_chain_with_bing_test() ->
    ?assertEqual([duckduckgo, duckduckgo_html, bing, wikipedia],
                 alWebSearch:autoEngineChain(<<"key">>)).

snippet_digest_test() ->
    Sources = [#{index => 1, title => <<"A">>, snippet => <<"foo">>},
               #{index => 2, title => <<"B">>, pageText => <<"bar">>}],
    Digest = alWebSearch:snippetDigest(Sources),
    ?assertMatch(<<_/binary>>, Digest),
    ?assertNotEqual(Digest, <<>>),
    ?assert(binary:match(Digest, <<"foo">>) =/= nomatch),
    ?assert(binary:match(Digest, <<"bar">>) =/= nomatch).

status_disabled_test() ->
    ?setup,
    ?assertMatch(#{enabled := true, status := configured},
                 alWebSearch:status()).

ddg_empty_response_test() ->
    {ok, []} = alWebSearch:parseDuckDuckGo(<<"{}">>),
    {ok, []} = alWebSearch:parseDuckDuckGo(<<"{\"RelatedTopics\":[]}">>),
    Empty = <<"{\"Abstract\":\"\",\"AbstractSource\":\"\",\"AbstractText\":\"\","
               "\"RelatedTopics\":[],\"Results\":[],\"Type\":\"\"}">>,
    {ok, []} = alWebSearch:parseDuckDuckGo(Empty).

ddg_html_parse_test() ->
    Html = <<"<a class=\"result__a\" href=\"https://example.com/a\">Free LLM API</a>"
              "<a class=\"result__snippet\" href=\"https://example.com/a\">OpenRouter free tier</a>">>,
    {ok, [R | _]} = alWebSearch:parseDuckDuckGoHtml(Html),
    ?assertEqual(<<"Free LLM API">>, maps:get(title, R)),
    ?assertEqual(<<"https://example.com/a">>, maps:get(url, R)),
    ?assertEqual(<<"OpenRouter free tier">>, maps:get(snippet, R)).

ddg_abstract_test() ->
    Bin = <<"{\"Heading\":\"Erlang (programming language)\","
            "\"AbstractText\":\"Erlang is a general-purpose functional language.\","
            "\"AbstractURL\":\"https://en.wikipedia.org/wiki/Erlang\","
            "\"RelatedTopics\":[]}">>,
    {ok, [R | _]} = alWebSearch:parseDuckDuckGo(Bin),
    ?assertEqual(<<"Erlang (programming language)">>, maps:get(title, R)),
    ?assertEqual(<<"https://en.wikipedia.org/wiki/Erlang">>, maps:get(url, R)).

ddg_related_topics_test() ->
    Bin = <<"{\"RelatedTopics\":["
            "{\"Text\":\"Erlang - Wikipedia\",\"FirstURL\":\"https://en.wikipedia.org/wiki/Erlang\"},"
            "{\"Topics\":[{\"Text\":\"OTP 27 - Docs\",\"FirstURL\":\"https://www.erlang.org/docs\"}]}"
            "]}">>,
    {ok, Results} = alWebSearch:parseDuckDuckGo(Bin),
    ?assertEqual(2, length(Results)),
    ?assertEqual(<<"https://en.wikipedia.org/wiki/Erlang">>,
                 maps:get(url, lists:nth(1, Results))).

ddg_bad_json_test() ->
    ?assertMatch({error, #{reason := badJson}}, alWebSearch:parseDuckDuckGo(<<"not json">>)).

%%%===================================================================
%%% Wikipedia 解析
%%%===================================================================

wikipedia_results_test() ->
    Bin = <<"{\"query\":{\"search\":["
            "{\"title\":\"Erlang (programming language)\","
            " \"snippet\":\"<span class=\\\"searchmatch\\\">Erlang</span> is a functional language\"}]}}">>,
    {ok, [R | _]} = alWebSearch:parseWikipedia(Bin),
    ?assertEqual(<<"Erlang (programming language)">>, maps:get(title, R)),
    %% HTML 标签应被剥离，实体解码
    Snippet = maps:get(snippet, R),
    ?assert(binary:match(Snippet, <<"<span">>) =:= nomatch),
    ?assert(binary:match(Snippet, <<"Erlang is a functional">>) =/= nomatch),
    %% url 应指向语言配置对应的 wiki 页面
    Url = maps:get(url, R),
    ?assert(binary:match(Url, <<"https://zh.wikipedia.org/wiki/">>) =/= nomatch).

wikipedia_empty_test() ->
    {ok, []} = alWebSearch:parseWikipedia(<<"{\"query\":{\"search\":[]}}">>),
    {ok, []} = alWebSearch:parseWikipedia(<<"{}">>).

%%%===================================================================
%%% Bing 解析
%%%===================================================================

bing_results_test() ->
    Bin = <<"{\"webPages\":{\"value\":["
            "{\"name\":\"Erlang docs\",\"url\":\"https://www.erlang.org\","
            " \"snippet\":\"Official documentation\"}]}}">>,
    {ok, [R | _]} = alWebSearch:parseBing(Bin),
    ?assertEqual(<<"Erlang docs">>, maps:get(title, R)),
    ?assertEqual(<<"https://www.erlang.org">>, maps:get(url, R)).

bing_empty_test() ->
    {ok, []} = alWebSearch:parseBing(<<"{}">>).

%%%===================================================================
%%% stripHtml / clampLimit
%%%===================================================================

strip_html_test() ->
    ?assertEqual(<<"hello world">>,
                 alWebSearch:stripHtml(<<"<b>hello</b> <i>world</i>">>)),
    ?assertEqual(<<"a & b">>, alWebSearch:stripHtml(<<"a &amp; b">>)),
    ?assertEqual(<<"'x'">>, alWebSearch:stripHtml(<<"&#39;x&#39;">>)).

clamp_limit_test() ->
    ?assertEqual(5, alWebSearch:clampLimit(5)),
    ?assertEqual(1, alWebSearch:clampLimit(0)),
    ?assertEqual(1, alWebSearch:clampLimit(-3)),
    ?assertEqual(10, alWebSearch:clampLimit(99)),
    ?assertEqual(5, alWebSearch:clampLimit(undefined)).

%%%===================================================================
%%% extractMainContent（readability 正文提取）
%%%===================================================================

extract_title_test() ->
    Html = <<"<html><head><title>My Page</title></head>"
             "<body><p>hello</p></body></html>">>,
    {Title, _} = alWebSearch:extractMainContent(Html),
    ?assertEqual(<<"My Page">>, Title).

extract_strips_noise_test() ->
    Html = <<"<html><head><title>T</title>"
             "<script>var x=1; while(true){}</script>"
             "<style>.a{color:red}</style></head>"
             "<body><nav><a href=\"/x\">nav1</a></nav>"
             "<p>Real content here</p></body></html>">>,
    {_Title, Text} = alWebSearch:extractMainContent(Html),
    ?assert(binary:match(Text, <<"Real content here">>) =/= nomatch),
    ?assert(binary:match(Text, <<"var x=1">>) =:= nomatch),
    ?assert(binary:match(Text, <<"color:red">>) =:= nomatch),
    ?assert(binary:match(Text, <<"nav1">>) =:= nomatch).

extract_prefers_article_test() ->
    %% article 内容 ≥ 400 字节时应优先于外围内容
    Long = binary:copy(<<"Erlang OTP release notes content. ">>, 20),
    Html = <<"<html><body><div>sidebar junk</div>"
             "<article>", Long/binary, "</article></body></html>">>,
    {_Title, Text} = alWebSearch:extractMainContent(Html),
    ?assert(binary:match(Text, <<"Erlang OTP release notes">>) =/= nomatch),
    ?assert(binary:match(Text, <<"sidebar junk">>) =:= nomatch).

extract_decodes_entities_test() ->
    Html = <<"<p>a &amp; b &#39;c&#39; &#8212; done</p>">>,
    {_Title, Text} = alWebSearch:extractMainContent(Html),
    ?assert(binary:match(Text, <<"a & b">>) =/= nomatch),
    %% &#39; → '；&#8212; → em dash（UTF-8 E2 80 94，用显式字节避免源码编码差异）
    ?assert(binary:match(Text, <<39>>) =/= nomatch),
    ?assert(binary:match(Text, <<226, 128, 148>>) =/= nomatch).

extract_paragraph_newlines_test() ->
    Html = <<"<p>one</p><p>two</p>">>,
    {_Title, Text} = alWebSearch:extractMainContent(Html),
    %% <p> 开闭各转换行 → 段落间以空行分隔
    ?assert(binary:match(Text, <<"one\n\ntwo">>) =/= nomatch).

extract_non_binary_test() ->
    ?assertEqual({<<>>, <<>>}, alWebSearch:extractMainContent(not_html)).

%%%===================================================================
%%% freshness / index / webQa 消息
%%%===================================================================

normalize_freshness_test() ->
    ?assertEqual(day, alWebSearch:normalizeFreshness(<<"day">>)),
    ?assertEqual(year, alWebSearch:normalizeFreshness(year)),
    ?assertEqual(undefined, alWebSearch:normalizeFreshness(<<"bogus">>)),
    ?assertEqual(undefined, alWebSearch:normalizeFreshness(undefined)),
    ?assertEqual(undefined, alWebSearch:normalizeFreshness(null)).

freshness_param_test() ->
    ?assertEqual(<<"d">>, alWebSearch:freshnessParam(duckduckgo_html, day)),
    ?assertEqual(<<"y">>, alWebSearch:freshnessParam(duckduckgo_html, year)),
    ?assertEqual(<<"Week">>, alWebSearch:freshnessParam(bing, week)),
    %% 不支持的引擎忽略
    ?assertEqual(undefined, alWebSearch:freshnessParam(wikipedia, day)),
    ?assertEqual(undefined, alWebSearch:freshnessParam(bing, undefined)).

add_result_indexes_test() ->
    Indexed = alWebSearch:addResultIndexes(
        [#{title => <<"a">>, url => <<"u1">>}, #{title => <<"b">>, url => <<"u2">>}]),
    ?assertEqual([1, 2], [maps:get(index, R) || R <- Indexed]).

build_web_qa_messages_test() ->
    Sources = [#{index => 1, title => <<"T1">>, url => <<"https://a.com">>,
                 pageText => <<"body of a"/utf8>>},
               #{index => 2, title => <<"T2">>, url => <<"https://b.com">>,
                 snippet => <<"snip"/utf8>>}],
    Msgs = alWebSearch:buildWebQaMessages(<<"q1"/utf8>>, Sources),
    ?assertEqual(2, length(Msgs)),
    [Sys, User] = Msgs,
    ?assertEqual(<<"system">>, maps:get(role, Sys)),
    ?assertEqual(<<"user">>, maps:get(role, User)),
    ?assert(binary:match(maps:get(content, User), <<"[1] T1">>) =/= nomatch),
    ?assert(binary:match(maps:get(content, User), <<"body of a">>) =/= nomatch),
    %% 无 pageText 的来源回退 snippet
    ?assert(binary:match(maps:get(content, User), <<"snip">>) =/= nomatch).
