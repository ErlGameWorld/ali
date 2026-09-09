%%%-------------------------------------------------------------------
%% @doc 结构化代码审查包（reviewPackage）。
%%
%% 产出可执行 findings（非答案 Critic）：文件/行/规则/严重度 + 可选 patch 提示。
%% 可叠加提交影响分析（ref）与本地源码启发式扫描。
%% @end
%%%-------------------------------------------------------------------

-module(alReviewPackage).

-export([build/1, buildFromRef/1, buildFromFiles/1, scanSource/2]).

%% Test exports
-export([scanLines/2, summarizeFindings/1, isCodePath/1]).

-define(MaxFiles, 24).
-define(MaxFindings, 80).
-define(MaxFileBytes, 200000).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 构建审查包。Opts：
%% - `ref` — VCS 提交，附带 change impact
%% - `files` — 相对/绝对路径列表
%% - `modules` — 模块名列表（解析为源文件）
%% - `maxFindings` — 上限（默认 80）
%% @end
%%--------------------------------------------------------------------
-spec build(map()) -> {ok, map()} | {error, term()}.
build(Opts) when is_map(Opts) ->
    try
        MaxF = maps:get(maxFindings, Opts, ?MaxFindings),
        Files0 = collectFiles(Opts),
        Files = lists:sublist(Files0, ?MaxFiles),
        Findings0 = lists:flatmap(fun(Path) ->
            case scanFile(Path) of
                {ok, Fs} -> Fs;
                {error, _} -> []
            end
        end, Files),
        Impact = maybeImpact(Opts),
        Findings1 = lists:sublist(Findings0, MaxF),
        Summary = summarizeFindings(Findings1),
        Actions = suggestedActions(Findings1),
        {ok, #{
            version => 1,
            files => [toBinary(F) || F <- Files],
            findings => Findings1,
            summary => Summary,
            suggestedActions => Actions,
            impact => Impact,
            nextSteps => nextSteps(Summary, Impact)
        }}
    catch
        Class:Reason:Stack ->
            {error, #{reason => reviewPackageFailed, class => Class,
                      detail => Reason, stack => lists:sublist(Stack, 6)}}
    end.

buildFromRef(Ref) ->
    build(#{ref => Ref}).

buildFromFiles(Files) when is_list(Files) ->
    build(#{files => Files}).

%%%===================================================================
%%% Collect targets
%%%===================================================================

collectFiles(Opts) ->
    FromFiles = [normalizePath(F) || F <- ensureList(maps:get(files, Opts, [])),
                                     isCodePath(normalizePath(F))],
    FromMods = lists:filtermap(fun(M) ->
        case resolveModuleFile(M) of
            {ok, P} -> {true, P};
            _ -> false
        end
    end, ensureList(maps:get(modules, Opts, []))),
    FromRef = case maps:get(ref, Opts, undefined) of
        undefined -> [];
        Ref ->
            case alVcsIndex:commitDiff(Ref) of
                {ok, Commit} ->
                    [normalizePath(P) || P <- maps:get(files, Commit, []),
                                        isCodePath(normalizePath(P))];
                _ -> []
            end
    end,
    lists:usort(FromFiles ++ FromMods ++ FromRef).

resolveModuleFile(Mod0) ->
    Mod = toAtom(Mod0),
    case is_atom(Mod) of
        false -> {error, badModule};
        true ->
            case code:which(Mod) of
                non_existing ->
                    %% 尝试 project 下 src/Mod.erl
                    Guess = filename:join(["src", atom_to_list(Mod) ++ ".erl"]),
                    case filelib:is_file(Guess) of
                        true -> {ok, filename:absname(Guess)};
                        false -> {error, notFound}
                    end;
                Path when is_list(Path) ->
                    %% beam 旁猜测 .erl
                    Src = filename:rootname(Path) ++ ".erl",
                    case filelib:is_file(Src) of
                        true -> {ok, Src};
                        false ->
                            Guess = filename:join(["src", atom_to_list(Mod) ++ ".erl"]),
                            case filelib:is_file(Guess) of
                                true -> {ok, filename:absname(Guess)};
                                false -> {error, notFound}
                            end
                    end;
                _ -> {error, notFound}
            end
    end.

maybeImpact(Opts) ->
    case maps:get(ref, Opts, undefined) of
        undefined -> undefined;
        Ref ->
            case alChangeImpact:analyze(Ref) of
                {ok, Impact} ->
                    #{
                        ref => toBinary(Ref),
                        modules => maps:get(modules, Impact, []),
                        summary => maps:get(summary, Impact, #{})
                    };
                {error, Reason} ->
                    #{error => Reason}
            end
    end.

%%%===================================================================
%%% Scan
%%%===================================================================

scanFile(Path) ->
    case file:read_file(Path) of
        {ok, Bin} when byte_size(Bin) > ?MaxFileBytes ->
            {ok, [#{
                file => toBinary(Path),
                line => 1,
                severity => minor,
                rule => fileTooLarge,
                message => <<"File skipped for line scan (too large)">>,
                suggestion => <<"Review manually or split module">>
            }]};
        {ok, Bin} ->
            {ok, scanSource(Path, Bin)};
        {error, Reason} ->
            {error, Reason}
    end.

%%--------------------------------------------------------------------
%% @doc 对源码文本做启发式扫描（供测试与 build 复用）。
%% @end
%%--------------------------------------------------------------------
scanSource(Path, Bin) when is_binary(Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global]),
    scanLines(toBinary(Path), Lines).

scanLines(File, Lines) when is_list(Lines) ->
    {Findings, _} = lists:foldl(fun(Line, {Acc, N}) ->
        Hits = ruleHits(File, N, Line),
        {Hits ++ Acc, N + 1}
    end, {[], 1}, Lines),
    lists:reverse(Findings).

ruleHits(File, LineNo, Line0) ->
    Line = toBinary(Line0),
    Trim = string:trim(Line),
    %% 跳过纯注释行
    case Trim of
        <<"%", _/binary>> -> [];
        _ ->
            Rules = [
                {swallowCatch, blocker,
                 <<"catch _">>, <<"Avoid bare catch _; log or match specific errors">>,
                 fun() -> binary:match(Line, <<"catch _">>) =/= nomatch
                              orelse binary:match(Line, <<"catch _:">>) =/= nomatch end},
                {osCmd, blocker,
                 <<"os:cmd">>, <<"Prefer port/runProgram over os:cmd">>,
                 fun() -> binary:match(Line, <<"os:cmd">>) =/= nomatch end},
                {timerSleep, major,
                 <<"timer:sleep">>, <<"Avoid sleep polling; use messages/timeouts">>,
                 fun() -> binary:match(Line, <<"timer:sleep">>) =/= nomatch end},
                {spawnBare, major,
                 <<"spawn(">>, <<"Prefer spawn_link/monitor for critical processes">>,
                 fun() -> binary:match(Line, <<"spawn(">>) =/= nomatch
                              andalso binary:match(Line, <<"spawn_link">>) =:= nomatch
                              andalso binary:match(Line, <<"spawn_monitor">>) =:= nomatch end},
                {listAppendAcc, major,
                 <<"++">>, <<"Avoid Acc ++ [X] in recursion; prefer [X|Acc] + reverse">>,
                 fun() -> binary:match(Line, <<"++ [">>) =/= nomatch
                              orelse binary:match(Line, <<"++[">>) =/= nomatch end},
                {receiveNoTimeout, minor,
                 <<"receive">>, <<"receive without after may hang">>,
                 fun() ->
                     binary:match(Line, <<"receive">>) =/= nomatch
                         andalso binary:match(Line, <<"after">>) =:= nomatch
                         andalso byte_size(Trim) < 40
                 end}
            ],
            lists:filtermap(fun({Id, Sev, Snip, Sug, Pred}) ->
                case Pred() of
                    true ->
                        {true, #{
                            file => File,
                            line => LineNo,
                            severity => Sev,
                            rule => Id,
                            message => Snip,
                            snippet => string:trim(Line),
                            suggestion => Sug,
                            suggestedPatch => patchHint(File, LineNo, Id, Line)
                        }};
                    false -> false
                end
            end, Rules)
    end.

patchHint(File, Line, swallowCatch, _LineText) ->
    #{
        note => <<"Replace bare catch with typed catch or try/catch logging">>,
        file => File,
        line => Line,
        tool => validatePatch
    };
patchHint(File, Line, osCmd, _) ->
    #{note => <<"Rewrite to alToolsExt:runProgram/3 or open_port">>, file => File, line => Line};
patchHint(File, Line, listAppendAcc, _) ->
    #{note => <<"Change Acc ++ [X] to [X | Acc]">>, file => File, line => Line, tool => dryRunPatch};
patchHint(File, Line, _, _) ->
    #{file => File, line => Line, tool => readFile}.

%%%===================================================================
%%% Summarize / actions
%%%===================================================================

summarizeFindings(Findings) ->
    Count = fun(Sev) ->
        length([F || F <- Findings, maps:get(severity, F, minor) =:= Sev])
    end,
    #{
        total => length(Findings),
        blocker => Count(blocker),
        major => Count(major),
        minor => Count(minor)
    }.

suggestedActions(Findings) ->
    lists:sublist(
        [#{
            severity => maps:get(severity, F),
            rule => maps:get(rule, F),
            file => maps:get(file, F),
            line => maps:get(line, F),
            action => maps:get(suggestion, F),
            patchHint => maps:get(suggestedPatch, F, #{})
          } || F <- Findings],
        20).

nextSteps(Summary, Impact) ->
    Blockers = maps:get(blocker, Summary, 0),
    Base0 = case Blockers > 0 of
        true -> [<<"1. Fix blockers first before other cleanup">>];
        false -> [<<"1. Triage majors/minors in findings">>]
    end,
    Base = Base0 ++ [
        <<"2. For each fix: validatePatch → dryRunPatch → applyPatch (mode=edit)"/utf8>>,
        <<"3. verifyCompile / runEunit after apply">>
    ],
    case Impact of
        undefined -> Base;
        #{error := _} -> Base;
        _ -> [<<"0. Review change-impact summary for callers">> | Base]
    end.

%%%===================================================================
%%% Helpers
%%%===================================================================

isCodePath(Path) ->
    Ext = string:lowercase(toBinary(filename:extension(Path))),
    lists:member(Ext, [<<".erl">>, <<".hrl">>, <<".escript">>]).

normalizePath(P) when is_binary(P) -> unicode:characters_to_list(P);
normalizePath(P) when is_list(P) -> P;
normalizePath(P) -> unicode:characters_to_list(io_lib:format("~p", [P])).

ensureList(L) when is_list(L) -> L;
ensureList(_) -> [].

toBinary(B) when is_binary(B) -> B;
toBinary(A) when is_atom(A) -> atom_to_binary(A, utf8);
toBinary(L) when is_list(L) -> unicode:characters_to_binary(L);
toBinary(I) when is_integer(I) -> integer_to_binary(I);
toBinary(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).

toAtom(A) when is_atom(A) -> A;
toAtom(B) when is_binary(B) ->
    try binary_to_existing_atom(B, utf8) catch _:_ -> undefined end;
toAtom(L) when is_list(L) ->
    try list_to_existing_atom(L) catch _:_ -> undefined end;
toAtom(_) -> undefined.
