%%% @doc EUnit tests for alHttp (eWCli wrapper helpers).
-module(alHttp_tests).

-include_lib("eunit/include/eunit.hrl").

truncate_utf8_test() ->
    ?assertEqual(<<"abc">>, alHttp:truncateUtf8(<<"abcdef">>, 3)),
    ?assertEqual(<<"abcdef">>, alHttp:truncateUtf8(<<"abcdef">>, 10)).

find_header_test() ->
    Hs = [{<<"Content-Type">>, <<"text/plain">>}, {"location", "/x"}],
    ?assertEqual({ok, <<"text/plain">>}, alHttp:findHeader(<<"content-type">>, Hs)),
    ?assertEqual({ok, <<"/x">>}, alHttp:findHeader(<<"location">>, Hs)),
    ?assertEqual(error, alHttp:findHeader(<<"missing">>, Hs)).

normalize_follow_redirect_test() ->
    %% 通过 request 失败路径间接验证 opts 归一化不崩溃
    alHttp:ensureStarted(),
    ?assertMatch({error, _},
                 alHttp:request(get, <<"http://127.0.0.1:1/">>, [], <<>>,
                                [{recv_timeout, 200}, {connect_timeout, 200},
                                 {follow_redirect, false}])).

%% 关键回归：llama.cpp 等服务对 HTTP 方法名大小写敏感（post 小写会 400），
%% alHttp 必须把方法名转为大写 `POST` 再发给 eWCli。
uppercase_method_test() ->
    ?assertEqual(<<"POST">>, alHttp:uppercaseMethod(post)),
    ?assertEqual(<<"GET">>, alHttp:uppercaseMethod(get)),
    ?assertEqual(<<"PUT">>, alHttp:uppercaseMethod(<<"put">>)),
    ?assertEqual(<<"POST">>, alHttp:uppercaseMethod(<<"Post">>)),
    ?assertEqual(<<"DELETE">>, alHttp:uppercaseMethod("delete")).
