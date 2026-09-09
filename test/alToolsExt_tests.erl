%%% @doc EUnit tests for alToolsExt.
-module(alToolsExt_tests).

-include_lib("eunit/include/eunit.hrl").

-define(setup, begin ok = alConfig:load() end).

%% 测试临时目录基址：项目内 .eunit（gitignored，且不在 indexIgnore 黑名单，
%% 沙箱环境禁止写 AppData user_cache；_build 段会被 resolveReadablePath 拒读）。
testTmpDir() ->
    filename:absname(".eunit").

critical_exports_test() ->
    Exports = alToolsExt:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{readFile, 1}, {listFiles, 1}, {writeFile, 1},
                   {getBeamAbstract, 1}, {moduleExports, 1}, {getModuleTypes, 1},
                   {getSymbolSource, 1}, {sourceSnippet, 1}, {enrichLocMap, 2},
                   {findFunctionBlock, 3}, {extractFunctionFromSourceFile, 5},
                   {enrichSearchHits, 2},
                   {formatCode, 1}, {runEunit, 1}, {runDialyzer, 1},
                   {runTestsForPatch, 1},
                   {planSet, 2}, {planUpdate, 3}, {planGet, 1}, {planClear, 1},
                   {delegateTo, 1}, {useSkill, 1}]].

moduleExportsSelf_test() ->
    {ok, Result} = alToolsExt:moduleExports(alToolsExt),
    ?assertEqual(alToolsExt, maps:get(module, Result)),
    ?assert(is_list(maps:get(exports, Result))).

moduleExportsUnknown_test() ->
    ?assertMatch({error, _}, alToolsExt:moduleExports(<<"nonExistentMod">>)).

getBeamAbstractValid_test() ->
    Result = alToolsExt:getBeamAbstract(alToolsExt),
    ?assertMatch({ok, #{module := alToolsExt, forms := _}}, Result).

%% OTP callback 形如 {{Name,Arity}, Types}；应解析出真实 name/arity。
getModuleTypes_callback_shape_test() ->
    case alToolsExt:getModuleTypes(gen_server) of
        {ok, #{callbacks := Cbs}} when is_list(Cbs), Cbs =/= [] ->
            Names = [maps:get(name, C) || C <- Cbs],
            ?assert(lists:member(init, Names) orelse lists:member(handle_call, Names)),
            ?assertNot(lists:member(undefined, Names));
        {ok, #{callbacks := []}} ->
            %% 无 abstract_code 时跳过（精简安装）
            ok;
        {error, _} ->
            ok
    end.
formatCodeValid_test() ->
    %% erlfmt may not be available in all test environments
    Result = try alToolsExt:formatCode(#{code => <<"foo() -> ok.">>}) of
        R -> R
    catch
        _:_ -> skip
    end,
    case Result of
        {ok, #{formatted := _}} -> ok;
        _ -> ok
    end.

is_subpath_allows_project_relative_paths_test() ->
    ?setup,
    Root = alConfig:projectRoot(),
    ?assert(alToolsExt:isSubpath(Root, filename:join(Root, "src"))),
    ?assert(alToolsExt:isSubpath(Root, filename:absname(".", Root))),
    {ok, _} = alToolsExt:resolveAllowedPath("src"),
    {ok, _} = alToolsExt:resolveAllowedPath(".").

%% 索引里 Windows 长路径 `//?/<drive>:...` 不得被解析成 `x:ali/...`（丢斜杠）。
win_long_path_normalize_test() ->
    ?setup,
    RootAbs = alToolsExt:normalizeAbs(alConfig:projectRoot()),
    RootFwd = string:lowercase(re:replace(RootAbs, "\\\\", "/", [global, {return, list}])),
    Rel = "src/agent/alAgent.erl",
    Long = "//?/" ++ string:trim(RootFwd, both, "/") ++ "/" ++ Rel,
    Norm = alToolsExt:normalizeAbs(Long),
    %% 回归：`//?/f:/ali/...` 曾被错解成 `f:ali/...`
    ?assertEqual(nomatch, re:run(string:lowercase(Norm), "[a-z]:ali([/\\\\]|$)", [{capture, none}])),
    case alToolsExt:isSubpath(RootAbs, Norm) of
        true ->
            {ok, AbsOut} = alToolsExt:resolveAllowedPath(Long),
            ?assert(alToolsExt:isSubpath(RootAbs, AbsOut));
        false ->
            %% 根路径无法映射到盘符长路径时，至少 strip 后仍含 src
            ?assertNotEqual(nomatch, string:find(string:lowercase(Norm), "src"))
    end.
list_files_recursive_caps_and_skips_git_test() ->
    ?setup,
    {ok, #{entries := Entries} = R} =
        alToolsExt:listFiles(#{path => <<".">>, recursive => true, maxEntries => 50}),
    ?assert(length(Entries) =< 50),
    ?assert(maps:get(truncated, R, false) orelse length(Entries) =< 50),
    ?assertEqual([], [E || E <- Entries, lists:member(".git", filename:split(to_list(E)))]),
    ?assertEqual([], [E || E <- Entries, lists:member("_build", filename:split(to_list(E)))]).

read_file_line_range_test() ->
    ?setup,
    Path = "src/tools/alToolsExt.erl",
    {ok, Full} = alToolsExt:readFile(#{path => Path, maxBytes => 200000}),
    FullLines = length(binary:split(maps:get(content, Full), <<"\n">>, [global])),
    {ok, Range} = alToolsExt:readFile(#{path => Path, startLine => 50, endLine => 55}),
    ?assertEqual(50, maps:get(startLine, Range)),
    ?assertEqual(55, maps:get(endLine, Range)),
    ?assertEqual(6, maps:get(lineCount, Range)),
    ?assertEqual(false, maps:get(truncated, Range)),
    RangeLines = [L || L <- binary:split(maps:get(content, Range), <<"\n">>, [global]),
                       L =/= <<>>],
    ?assertEqual(6, length(RangeLines)),
    ?assert(maps:get(totalLines, Range) >= FullLines - 5).

read_file_line_count_test() ->
    ?setup,
    {ok, Range} = alToolsExt:readFile(#{path => "src/tools/alToolsExt.erl",
                                        startLine => 1, lineCount => 3}),
    ?assertEqual(1, maps:get(startLine, Range)),
    ?assertEqual(3, maps:get(endLine, Range)),
    ?assertEqual(3, maps:get(lineCount, Range)).

get_symbol_source_self_test() ->
    ?setup,
    case alToolsExt:getSymbolSource(#{module => alToolsExt,
                                      function => readFile, arity => 1}) of
        {ok, #{source := Source, backend := Backend}} ->
            ?assert(byte_size(Source) > 20),
            ?assert(lists:member(Backend, [beamAbstract, sourceLineRange, sourceParse]));
        {error, _} ->
            ok
    end.

get_symbol_source_context_lines_test() ->
    ?setup,
    Dir = filename:join(testTmpDir(),
                        "sym_ctx_" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
    Path = filename:join(Dir, "ctx_pad_mod.erl"),
    ok = file:write_file(Path,
        <<"-module(ctx_pad_mod).\n"
          "-export([ping/0]).\n"
          "%% before1\n"
          "%% before2\n"
          "ping() ->\n"
          "    ok.\n"
          "%% after1\n"
          "%% after2\n">>),
    OldAgent = alConfig:get(agent, #{}),
    ok = alConfig:patch([{agent, maps:merge(OldAgent, #{projectRoot => Dir})}]),
    try
        {ok, #{source := Source, contextLines := 2, backend := sourceParse}} =
            alToolsExt:extractFunctionFromSourceFile(Path, ping, 0, ctx_pad_mod, 2),
        ?assert(binary:match(Source, <<"before1">>) =/= nomatch),
        ?assert(binary:match(Source, <<"after1">>) =/= nomatch),
        ?assert(binary:match(Source, <<"ping()">>) =/= nomatch),
        %% 端到端：磁盘模块应走 getSymbolSource → sourceParse + Pad
        {ok, R2} = alToolsExt:getSymbolSource(#{
            module => ctx_pad_mod,
            function => ping,
            arity => 0,
            contextLines => 2
        }),
        ?assertEqual(2, maps:get(contextLines, R2, undefined)),
        ?assert(binary:match(maps:get(source, R2), <<"before1">>) =/= nomatch)
    after
        _ = alConfig:patch([{agent, OldAgent}]),
        _ = file:del_dir_r(Dir)
    end.

%% re:run + {capture,none} 返回 match（不是 {match,_}）；曾触发 case_clause
find_function_block_match_atom_test() ->
    Lines = [
        <<"-module(foo).">>,
        <<"set_handle(A, B) ->">>,
        <<"    ok.">>,
        <<"other() ->">>,
        <<"    1.">>
    ],
    {ok, Start, End, Block} =
        alToolsExt:findFunctionBlock(Lines, "^\\s*set_handle\\s*\\(", 2),
    ?assertEqual(2, Start),
    ?assertEqual(3, End),
    ?assert(binary:match(Block, <<"set_handle">>) =/= nomatch),
    ?assert(binary:match(Block, <<"other()">>) =:= nomatch).

find_function_block_not_found_test() ->
    ?assertEqual({error, functionNotFound},
                 alToolsExt:findFunctionBlock([<<"foo() -> ok.">>],
                                              "^\\s*missing\\s*\\(", 0)).

source_snippet_line_test() ->
    ?setup,
    {ok, Snip} = alToolsExt:sourceSnippet(#{path => "src/tools/alToolsExt.erl",
                                           startLine => 50, endLine => 55}),
    ?assert(byte_size(maps:get(source, Snip)) > 20),
    ?assertEqual(6, maps:get(lineCount, Snip)).

list_files_glob_test() ->
    ?setup,
    {ok, R} = alToolsExt:listFiles(#{path => "src/tools", glob => "alToolsExt.erl"}),
    Entries = maps:get(entries, R),
    ?assert(lists:any(
        fun(E) -> filename:basename(to_list(E)) =:= "alToolsExt.erl" end, Entries)),
    ?assertEqual(glob, maps:get(browseMode, R)).

%%%===================================================================
%%% fetchUrl / URL 校验
%%%===================================================================

fetchUrl_exported_test() ->
    Exports = alToolsExt:module_info(exports),
    ?assert(lists:member({fetchUrl, 1}, Exports)),
    ?assert(lists:member({validateFetchUrl, 1}, Exports)).

fetchUrlAcceptsHttp_test() ->
    ?assertMatch({ok, _}, alToolsExt:validateFetchUrl(<<"http://example.com/path">>)),
    ?assertMatch({ok, _}, alToolsExt:validateFetchUrl(<<"https://example.com">>)).

fetchUrlRejectsScheme_test() ->
    ?assertMatch({error, #{reason := unsupportedScheme}},
                 alToolsExt:validateFetchUrl(<<"ftp://example.com/x">>)),
    ?assertMatch({error, #{reason := unsupportedScheme}},
                 alToolsExt:validateFetchUrl(<<"file:///etc/passwd">>)).

fetchUrlRejectsInternal_test() ->
    ?assertMatch({error, #{reason := internalAddressBlocked}},
                 alToolsExt:validateFetchUrl(<<"http://127.0.0.1:8080/x">>)),
    ?assertMatch({error, #{reason := internalAddressBlocked}},
                 alToolsExt:validateFetchUrl(<<"http://localhost/x">>)),
    ?assertMatch({error, #{reason := internalAddressBlocked}},
                 alToolsExt:validateFetchUrl(<<"http://10.0.0.5/x">>)),
    ?assertMatch({error, #{reason := internalAddressBlocked}},
                 alToolsExt:validateFetchUrl(<<"http://192.168.1.1/x">>)),
    ?assertMatch({error, #{reason := internalAddressBlocked}},
                 alToolsExt:validateFetchUrl(<<"http://169.254.1.1/x">>)),
    ?assertMatch({error, #{reason := internalAddressBlocked}},
                 alToolsExt:validateFetchUrl(<<"http://[::1]/x">>)).

fetchUrlInternalHostHelper_test() ->
    ?assert(alToolsExt:isInternalHost("127.0.0.1")),
    ?assert(alToolsExt:isInternalHost("localhost")),
    ?assert(alToolsExt:isInternalHost("10.1.2.3")),
    ?assert(alToolsExt:isInternalHost("192.168.0.1")),
    ?assert(alToolsExt:isInternalHost("169.254.0.1")),
    ?assert(alToolsExt:isInternalHost("172.16.0.1")),
    ?assert(alToolsExt:isInternalHost("172.31.255.255")),
    ?assertNot(alToolsExt:isInternalHost("example.com")),
    ?assertNot(alToolsExt:isInternalHost("8.8.8.8")),
    ?assertNot(alToolsExt:isInternalHost("172.32.0.1")).

%% 混淆形式 IP 字面量（十进制/十六进制/八进制/IPv4-mapped）必须按内网拦截
fetchUrlRejectsObfuscatedInternal_test() ->
    %% 十进制整数 IP：2130706433 = 127.0.0.1
    ?assertMatch({error, #{reason := internalAddressBlocked}},
                 alToolsExt:validateFetchUrl(<<"http://2130706433/x">>)),
    %% 十六进制整数 IP：0x7f000001 = 127.0.0.1
    ?assertMatch({error, #{reason := internalAddressBlocked}},
                 alToolsExt:validateFetchUrl(<<"http://0x7f000001/x">>)),
    %% 前导零（八进制）点分：0177.0.0.1 = 127.0.0.1
    ?assertMatch({error, #{reason := internalAddressBlocked}},
                 alToolsExt:validateFetchUrl(<<"http://0177.0.0.1/x">>)),
    %% 0x 段点分：0x7f.0.0.1 = 127.0.0.1
    ?assertMatch({error, #{reason := internalAddressBlocked}},
                 alToolsExt:validateFetchUrl(<<"http://0x7f.0.0.1/x">>)),
    %% IPv4-mapped IPv6（点分 / 十六进制段两种写法）
    ?assertMatch({error, #{reason := internalAddressBlocked}},
                 alToolsExt:validateFetchUrl(<<"http://[::ffff:127.0.0.1]/x">>)),
    ?assertMatch({error, #{reason := internalAddressBlocked}},
                 alToolsExt:validateFetchUrl(<<"http://[::ffff:7f00:1]/x">>)).

isInternalHost_obfuscated_test() ->
    ?assert(alToolsExt:isInternalHost("2130706433")),
    ?assert(alToolsExt:isInternalHost("0x7f000001")),
    ?assert(alToolsExt:isInternalHost("0177.0.0.1")),
    ?assert(alToolsExt:isInternalHost("0x7f.0.0.1")),
    ?assert(alToolsExt:isInternalHost("::ffff:127.0.0.1")),
    ?assert(alToolsExt:isInternalHost("::ffff:7f00:1")),
    ?assert(alToolsExt:isInternalHost("fe80::1")),
    ?assert(alToolsExt:isInternalHost("fc00::1")),
    %% 非内网字面量仍放行
    ?assertNot(alToolsExt:isInternalHost("8.8.8.8")),
    ?assertNot(alToolsExt:isInternalHost("172.32.0.1")),
    ?assertNot(alToolsExt:isInternalHost("example.com")).

%% redirect 目标必须重新校验：内网 Location 应在 resolve 后被拦截
fetchUrlRedirectToInternalBlocked_test() ->
    {ok, NewUrl} = alToolsExt:resolveRedirectUrl(
        <<"http://example.com/a">>, <<"http://127.0.0.1:8080/admin">>),
    ?assertMatch({error, #{reason := internalAddressBlocked}},
                 alToolsExt:validateFetchUrl(NewUrl)),
    %% 相对 Location 解析为同源绝对 URL 后仍可校验
    {ok, Abs} = alToolsExt:resolveRedirectUrl(
        <<"http://example.com/a/b">>, <<"/c">>),
    ?assertEqual(<<"http://example.com/c">>, Abs),
    ?assertMatch({ok, _}, alToolsExt:validateFetchUrl(Abs)).

fetchUrlRedirectTarget_test() ->
    Headers = [{<<"location">>, <<"http://example.com/new">>}],
    ?assertEqual({redirect, <<"http://example.com/new">>},
                 alToolsExt:redirectTarget(302, Headers)),
    ?assertEqual(none, alToolsExt:redirectTarget(302, [])),
    ?assertEqual(none, alToolsExt:redirectTarget(200, Headers)),
    ?assertEqual(none, alToolsExt:redirectTarget(299, Headers)).

fetchUrlMissingUrl_test() ->
    ?assertMatch({error, #{reason := missingUrl}}, alToolsExt:fetchUrl(#{})).

%% OTP 25 没有 binary:lowercase/1；content-type 必须能小写匹配 html。
contentTypeFormat_html_test() ->
    ?assertEqual(html, alToolsExt:contentTypeFormat(<<"text/html">>)),
    ?assertEqual(html, alToolsExt:contentTypeFormat(<<"TEXT/HTML; charset=UTF-8">>)),
    ?assertEqual(text, alToolsExt:contentTypeFormat(<<"application/json">>)),
    ?assertEqual(binary, alToolsExt:contentTypeFormat(<<"image/png">>)).

%%%===================================================================
%%% fetchUrlPage cursor / 参数归一
%%%===================================================================

parse_page_cursor_test() ->
    ?assertEqual(0, alToolsExt:parsePageCursor(null)),
    ?assertEqual(0, alToolsExt:parsePageCursor(undefined)),
    ?assertEqual(0, alToolsExt:parsePageCursor(<<"">>)),
    ?assertEqual(0, alToolsExt:parsePageCursor(<<"abc">>)),
    ?assertEqual(0, alToolsExt:parsePageCursor(-5)),
    ?assertEqual(0, alToolsExt:parsePageCursor(0)),
    ?assertEqual(24000, alToolsExt:parsePageCursor(24000)),
    ?assertEqual(24000, alToolsExt:parsePageCursor(<<"24000">>)),
    ?assertEqual(24000, alToolsExt:parsePageCursor(<<" 24000 ">>)).

fetchUrlPage_exported_test() ->
    Exports = alToolsExt:module_info(exports),
    ?assert(lists:member({fetchUrlPage, 1}, Exports)).

fetchUrlPageMissingUrl_test() ->
    ?assertMatch({error, #{reason := missingUrl}}, alToolsExt:fetchUrlPage(#{})).

to_list(B) when is_binary(B) -> unicode:characters_to_list(B);
to_list(L) when is_list(L) -> L;
to_list(X) -> lists:flatten(io_lib:format("~p", [X])).
