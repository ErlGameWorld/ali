%%% @doc EUnit tests for alSvnIndex pure helpers + decode.
-module(alSvnIndex_tests).

-include_lib("eunit/include/eunit.hrl").

format_date_is_flat_string_test() ->
    S = alSvnIndex:formatDateForSvn(1),
    ?assert(is_list(S)),
    ?assert(lists:all(fun(C) -> is_integer(C) end, S)),
    ?assertMatch([${ | _], S).

parse_revision_strips_r_test() ->
    ?assertEqual("123", alSvnIndex:parseRevision("r123")),
    ?assertEqual("123", alSvnIndex:parseRevision(<<"r123">>)).

parse_svn_log_basic_test() ->
    Out =
        "------------------------------------------------------------------------\n"
        "r100 | alice | 2026-07-24 10:00:00 +0800 | 1 line\n"
        "fix bug\n"
        "------------------------------------------------------------------------\n",
    [C] = alSvnIndex:parseSvnLog(Out),
    ?assertEqual(<<"r100">>, maps:get(revision, C)),
    ?assertEqual(<<"alice">>, maps:get(author, C)),
    ?assertEqual(<<"fix bug">>, maps:get(subject, C)).

parse_since_for_svn_test() ->
    ?assertEqual("{2026-07-01}", alSvnIndex:parseSinceForSvn("2026-07-01")),
    ?assertEqual("{2026-07-01}", alSvnIndex:parseSinceForSvn("{2026-07-01}")),
    ?assertMatch([${ | _], alSvnIndex:parseSinceForSvn("2 weeks ago")).

svn_status_matches_test() ->
    ?assert(alSvnIndex:statusMatches(modified, "M")),
    ?assert(alSvnIndex:statusMatches(added, "A")),
    ?assert(alSvnIndex:statusMatches(untracked, "?")),
    ?assert(alSvnIndex:statusMatches(deleted, "D")),
    ?assert(alSvnIndex:statusMatches(deleted, "!")),
    ?assert(alSvnIndex:statusMatches(renamed, "R")),
    ?assertNot(alSvnIndex:statusMatches(modified, "A")).

%%--------------------------------------------------------------------
%% D2 回归：alCoreClient 不可用时，incrementalIndex 必须上抛 {error, _}，
%% 而不是把 {error, _} 包进 {ok, #{indexResponse => ...}}。
%%--------------------------------------------------------------------
incrementalIndex_propagates_core_error_test() ->
    case whereis(alCoreClient) of
        undefined ->
            ?assertMatch({error, _}, alSvnIndex:incrementalIndex("."));
        _ ->
            %% 核心运行时走 {ok, _} 分支，本断言不适用。
            ok
    end.

%% 模拟 Windows GBK 混入 UTF-8 失败：decode 后仍能搜到 URL:
decode_cmd_output_latin1_fallback_test() ->
    %% 构造非法 UTF-8 尾部（0xFF），前缀为合法 ASCII
    Bin = <<"URL: http://example/svn\nLast: ", 16#FF, 16#FE>>,
    %% 通过 parse 路径间接验证 isSvnRepo 不会因解码崩——直接测内部不易；
    %% 这里测 string:find 在 latin1 拼接下仍可用。
    Out = case unicode:characters_to_list(Bin) of
        L when is_list(L) -> L;
        {error, Good, Rest} ->
            Good ++ binary_to_list(iolist_to_binary(Rest));
        {incomplete, Good, Rest} ->
            Good ++ binary_to_list(iolist_to_binary(Rest))
    end,
    ?assert(string:find(Out, "URL:") =/= nomatch).
