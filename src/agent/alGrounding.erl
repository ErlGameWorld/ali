%%%-------------------------------------------------------------------
%% @doc 代码问答的轻量 grounded-answer 校验。
%%      检测最终答案中的 MFA / .erl 路径断言，要求其出现在
%%      retrieved_context 或 tool-trace 证据中。
%% @end
%%%-------------------------------------------------------------------

-module(alGrounding).

-export([
    check/3,
    extractClaims/1,
    evidenceTokens/2,
    fixupMessage/1,
    warningText/1,
    appendWarning/2
]).

%% Test exports
-export([shouldCheck/1, claimKey/1, isCovered/2, isBuiltinMfa/1]).

-define(MaxEvidenceChars, 20000).

%%--------------------------------------------------------------------
%% @doc
%% 检查答案是否被 Context / Trace 证据支撑。
%% @return `ok' | `{ungrounded, [Claim]}'
%% @end
%%--------------------------------------------------------------------
-spec check(term(), map(), list()) -> ok | {ungrounded, [map()]}.
check(Answer, Context, Trace) ->
    case shouldCheck(Context) of
        false ->
            ok;
        true ->
            Claims = extractClaims(Answer),
            case Claims of
                [] ->
                    ok;
                _ ->
                    Evidence = evidenceTokens(Context, Trace),
                    Ungrounded = [C || C <- Claims, not isCovered(C, Evidence)],
                    case Ungrounded of
                        [] -> ok;
                        _ -> {ungrounded, lists:sublist(Ungrounded, 8)}
                    end
            end
    end.

%% 仅在有代码上下文时启用（避免闲聊误伤）。
shouldCheck(Context) when is_map(Context) ->
    Anchors = maps:get(anchors, Context, #{}),
    HasAnchors = case Anchors of
        M when is_map(M) ->
            maps:get(modules, M, []) =/= []
                orelse maps:get(paths, M, []) =/= []
                orelse maps:get(mfas, M, []) =/= [];
        _ -> false
    end,
    HasHits = maps:get(codeHits, Context, []) =/= []
        orelse maps:get(modules, Context, []) =/= []
        orelse maps:get(modulePaths, Context, []) =/= []
        orelse maps:get(anchorSnippets, Context, []) =/= [],
    HasAnchors orelse HasHits;
shouldCheck(_) ->
    false.

%%--------------------------------------------------------------------
%% @doc 从答案文本提取 MFA 与 .erl 路径声明。
%% @end
%%--------------------------------------------------------------------
extractClaims(Answer) ->
    Text = toBinary(Answer),
    Mfas = collect(Text,
        "([a-z][a-zA-Z0-9_]*)\\s*:\\s*([a-z][a-zA-Z0-9_]*)\\s*/\\s*(\\d+)",
        fun([M, F, A]) ->
            #{type => mfa, module => list_to_binary(M),
              function => list_to_binary(F), arity => list_to_integer(A)}
        end),
    Paths = collect(Text,
        "([A-Za-z0-9_./\\\\-]+\\.erl)(?::(\\d+))?",
        fun
            ([P, L]) when L =/= "" ->
                #{type => path, path => unicode:characters_to_binary(P),
                  line => list_to_integer(L)};
            ([P]) ->
                #{type => path, path => unicode:characters_to_binary(P)};
            ([P, _]) ->
                #{type => path, path => unicode:characters_to_binary(P)}
        end),
    %% OTP/stdlib MFA 属于语言常识，不要求项目工具证据（否则会误伤「讲原理」类回答）
    ProjectMfas = [C || C <- Mfas, not isBuiltinMfa(C)],
    dedupClaims(ProjectMfas ++ Paths).

%% OTP / 标准库模块：讨论语言机制时常见，不应触发 grounding 重试或末尾警告。
isBuiltinMfa(#{type := mfa, module := M}) ->
    lists:member(string:lowercase(toList(M)), builtinModules());
isBuiltinMfa(_) ->
    false.

builtinModules() ->
    ["erlang", "lists", "maps", "ets", "gb_trees", "gb_sets", "dict", "orddict",
     "sets", "ordsets", "queue", "array", "proplists", "string", "binary", "unicode",
     "timer", "calendar", "io", "io_lib", "file", "filename", "filelib", "code",
     "application", "gen_server", "gen_statem", "gen_event", "gen_fsm", "supervisor",
     "supervisor_bridge", "proc_lib", "sys", "rpc", "global", "pg", "net_kernel",
     "inet", "gen_tcp", "gen_udp", "ssl", "httpc", "public_key", "crypto", "re",
     "rand", "math", "os", "init", "persistent_term", "atomics", "counters",
     "zlib", "base64", "uri_string", "logger", "error_logger", "c", "shell",
     "erl_parse", "erl_scan", "erl_pp", "digraph", "digraph_utils"].

collect(Bin, Pattern, Fun) ->
    case re:run(Bin, Pattern, [global, {capture, all_but_first, list}]) of
        {match, Caps} ->
            lists:filtermap(fun(Parts) ->
                try {true, Fun(Parts)} catch _:_ -> false end
            end, Caps);
        nomatch ->
            []
    end.

dedupClaims(Claims) ->
    maps:values(maps:from_list([{claimKey(C), C} || C <- Claims])).

claimKey(#{type := mfa, module := M, function := F, arity := A}) ->
    {mfa, M, F, A};
claimKey(#{type := path, path := P}) ->
    {path, normPath(P)};
claimKey(_) ->
    {other, erlang:unique_integer()}.

%%--------------------------------------------------------------------
%% @doc 从 context + tool trace 收集证据 token（小写 string）。
%% @end
%%--------------------------------------------------------------------
evidenceTokens(Context, Trace) ->
    Parts = [
        iolist_to_binary(io_lib:format("~p", [Context])),
        iolist_to_binary(io_lib:format("~p", [Trace]))
    ],
    Blob = string:lowercase(unicode:characters_to_list(iolist_to_binary(Parts))),
    %% 额外抽出结构化字段，避免 ~p 截断
    Extra = lists:flatmap(fun(X) -> evidenceFromTerm(X) end, [
        maps:get(anchors, Context, #{}),
        maps:get(modulePaths, Context, []),
        maps:get(codeHits, Context, []),
        maps:get(anchorSnippets, Context, []),
        maps:get(modules, Context, [])
    ]),
    ordsets:from_list([Blob | Extra]).

evidenceFromTerm(Term) ->
    Text = string:lowercase(unicode:characters_to_list(
        iolist_to_binary(io_lib:format("~p", [Term])))),
    [truncateEvidence(Text)].

%% 证据 token 仅用于字符串匹配，控制单条长度避免 ~p 展开超大 term 撑爆内存。
truncateEvidence(Text) when length(Text) > ?MaxEvidenceChars ->
    lists:sublist(Text, ?MaxEvidenceChars);
truncateEvidence(Text) ->
    Text.

isCovered(#{type := mfa, module := M, function := F}, Evidence) ->
    ML = string:lowercase(toList(M)),
    FL = string:lowercase(toList(F)),
    lists:any(fun(E) ->
        string:find(E, ML) =/= nomatch andalso string:find(E, FL) =/= nomatch
    end, Evidence);
isCovered(#{type := path, path := P}, Evidence) ->
    Full = normPath(P),
    lists:any(fun(E) ->
        string:find(E, Full) =/= nomatch
    end, Evidence);
isCovered(_, _) ->
    true.

%%--------------------------------------------------------------------
%% @doc 注入下一轮 tool loop 的用户纠正消息。
%% @end
%%--------------------------------------------------------------------
fixupMessage(Claims) ->
    Lines = [formatClaim(C) || C <- Claims],
    Body = iolist_to_binary([
        <<"上一轮回答引用的符号/路径未被工具结果或 retrieved_context "
          "（anchors/modulePaths/codeHits/anchorSnippets）支撑：\n"/utf8>>,
        [[<<"- ">>, L, <<"\n">>] || L <- Lines],
        <<"请对每一项调用 gotoDef 和/或 readFile，再用 file:line 引用改写答案。"
          "禁止臆造路径。"/utf8>>
    ]),
    #{role => user, content => Body}.

warningText(Claims) ->
    Lines = [formatClaim(C) || C <- Claims],
    iolist_to_binary([
        <<"\n\n[grounding]\n">>,
        <<"以下项目符号/路径未经工具或检索上下文核实（上文结论仍供参考）：\n"/utf8>>,
        [[<<"- ">>, L, <<"\n">>] || L <- Lines]
    ]).

appendWarning(Answer, Warning) when is_binary(Answer) ->
    <<Answer/binary, Warning/binary>>;
appendWarning(Answer, Warning) when is_map(Answer) ->
    Content = maps:get(content, Answer, <<>>),
    Answer#{content => <<(toBinary(Content))/binary, Warning/binary>>,
            groundingWarning => true};
appendWarning(Answer, Warning) ->
    <<(toBinary(Answer))/binary, Warning/binary>>.

formatClaim(#{type := mfa, module := M, function := F, arity := A}) ->
    iolist_to_binary([M, <<":">>, F, <<"/">>, integer_to_binary(A)]);
formatClaim(#{type := path, path := P, line := L}) ->
    iolist_to_binary([P, <<":">>, integer_to_binary(L)]);
formatClaim(#{type := path, path := P}) ->
    toBinary(P);
formatClaim(Other) ->
    toBinary(Other).

toBinary(V) when is_binary(V) -> V;
toBinary(V) when is_list(V) -> unicode:characters_to_binary(V);
toBinary(V) when is_atom(V) -> atom_to_binary(V, utf8);
toBinary(V) when is_integer(V) -> integer_to_binary(V);
toBinary(V) -> unicode:characters_to_binary(io_lib:format("~p", [V])).

toList(V) when is_list(V) -> V;
toList(V) when is_binary(V) -> unicode:characters_to_list(V);
toList(V) when is_atom(V) -> atom_to_list(V);
toList(V) -> lists:flatten(io_lib:format("~p", [V])).

%% 统一路径表示：转 list、反斜杠归一、小写，用于 path claim 去重与匹配。
normPath(P) ->
    string:lowercase(lists:map(fun($\\) -> $/; (C) -> C end, toList(P))).
