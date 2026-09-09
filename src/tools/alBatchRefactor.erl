%%%-------------------------------------------------------------------
%% @doc 项目级批量重构框架。
%%
%% <ul>
%% <li>{@link plan/1}: 从 modules / commit / files 计算影响范围 → Mermaid 报告</li>
%% <li>{@link apply/2}: 事务性多文件补丁 + verifyCompile + 回滚</li>
%% <li>{@link run/2}: plan | apply | planAndApply 的工具 API 分发</li>
%% </ul>
%%
%% 生成补丁的正确性由 LLM 负责；本模块保证编排、校验与可操作报告。
%% @end
%%%-------------------------------------------------------------------

-module(alBatchRefactor).

-compile({no_auto_import, [apply/2]}).

-export([run/1, run/2, plan/1, apply/1, apply/2]).

%% Test helpers
-export([normalizeAction/1, mermaidPlan/1, filesFromModules/1]).

%%--------------------------------------------------------------------
run(Args) ->
    run(Args, #{}).

run(Args, Opts) when is_map(Args), is_map(Opts) ->
    Action = normalizeAction(maps:get(action, Args,
                               maps:get(<<"action">>, Args, plan))),
    case Action of
        plan ->
            plan(Args);
        apply ->
            apply(Args, Opts);
        planAndApply ->
            case plan(Args) of
                {ok, Plan} ->
                    case maps:get(patches, Args, maps:get(<<"patches">>, Args, undefined)) of
                        undefined ->
                            {ok, Plan#{
                                status => planOnly,
                                hint => <<"Provide patches to apply; plan completed.">>
                            }};
                        Patches ->
                            case apply(Args#{patches => Patches}, Opts) of
                                {ok, Applied} ->
                                    {ok, maps:merge(Plan, Applied#{status => applied})};
                                {error, Reason} ->
                                    {error, #{reason => Reason, plan => Plan, status => applyFailed}}
                            end
                    end;
                {error, _} = E ->
                    E
            end;
        _ ->
            {error, #{reason => badAction, action => Action,
                      hint => <<"Use plan | apply | planAndApply">>}}
    end.

normalizeAction(plan) -> plan;
normalizeAction(apply) -> apply;
normalizeAction(planAndApply) -> planAndApply;
normalizeAction(<<"plan">>) -> plan;
normalizeAction(<<"apply">>) -> apply;
normalizeAction(<<"planAndApply">>) -> planAndApply;
normalizeAction(<<"plan_and_apply">>) -> planAndApply;
normalizeAction(Other) when is_list(Other) ->
    normalizeAction(list_to_binary(Other));
normalizeAction(Other) when is_atom(Other) ->
    normalizeAction(atom_to_binary(Other, utf8));
normalizeAction(_) ->
    unknown.

%%--------------------------------------------------------------------
%% @doc Build an impact plan without writing files.
%% @end
%%--------------------------------------------------------------------
plan(Args) when is_map(Args) ->
    Intent = maps:get(intent, Args, maps:get(<<"intent">>, Args, undefined)),
    Commit = maps:get(commit, Args, maps:get(<<"commit">>, Args, undefined)),
    Modules0 = maps:get(modules, Args, maps:get(<<"modules">>, Args, [])),
    Files0 = maps:get(files, Args, maps:get(<<"files">>, Args, [])),
    Modules = [toAtomSafe(M) || M <- ensureList(Modules0), toAtomSafe(M) =/= undefined],
    FilesExplicit = [toBin(F) || F <- ensureList(Files0)],
    {ok, Impact} = case Commit of
        undefined ->
            {ok, undefined};
        Ref ->
            case alChangeImpact:analyze(Ref) of
                {ok, R} -> {ok, R};
                {error, Reason} ->
                    {ok, #{error => Reason, commit => Ref}}
            end
    end,
    FilesFromCommit = case Impact of
        #{files := Fs} when is_list(Fs) -> [toBin(F) || F <- Fs];
        _ -> []
    end,
    FilesFromMods = filesFromModules(Modules),
    DepEdges = moduleDepEdges(Modules),
    AllFiles = lists:usort(FilesExplicit ++ FilesFromCommit ++ FilesFromMods),
    Mermaid = mermaidPlan(#{
        modules => Modules,
        files => AllFiles,
        deps => DepEdges,
        intent => Intent
    }),
    Summary = iolist_to_binary(io_lib:format(
        "~b modules, ~b files in scope",
        [length(Modules), length(AllFiles)])),
    Forced = forcedPlanWorkflow(AllFiles),
    {ok, #{
        action => plan,
        intent => Intent,
        modules => Modules,
        files => AllFiles,
        fileCount => length(AllFiles),
        moduleDeps => DepEdges,
        impact => Impact,
        mermaid => Mermaid,
        summary => Summary,
        markdown => planMarkdown(Intent, Modules, AllFiles, Mermaid),
        mustCoverFiles => AllFiles,
        forcedWorkflow => Forced,
        next => Forced
    }}.

forcedPlanWorkflow(Files) ->
    N = integer_to_binary(length(Files)),
    unicode:characters_to_binary([
        <<"Forced next steps after this plan:\n">>,
        <<"1) readFile each of the ">>, N, <<" files in `files`/`mustCoverFiles`\n">>,
        <<"2) craft hunks patches covering ALL of them (no silent skips)\n">>,
        <<"3) batchRefactor action=apply with patches=[...] + verifyCompile\n">>,
        <<"4) do not give a final answer until apply succeeds\n">>
    ]).

%%--------------------------------------------------------------------
apply(Args) ->
    apply(Args, #{}).

apply(Args, Opts) when is_map(Args), is_map(Opts) ->
    case maps:get(patches, Args, maps:get(<<"patches">>, Args, undefined)) of
        undefined ->
            {error, #{reason => missingPatches}};
        Patches0 ->
            Patches = ensureList(Patches0),
            case Patches of
                [] ->
                    {error, #{reason => emptyPatches}};
                _ ->
                    Verify = case maps:get(verifyCompile, Args,
                                    maps:get(<<"verifyCompile">>, Args, undefined)) of
                        undefined -> maps:get(verifyCompile, Opts, true);
                        V -> V =/= false
                    end,
                    BatchOpts = maps:merge(
                        maps:with([compileCommand, compileTimeoutMs], Opts),
                        #{verifyCompile => Verify}),
                    Started = erlang:monotonic_time(millisecond),
                    case alPatchManager:applyBatch(Patches, BatchOpts) of
                        {ok, Res} ->
                            Elapsed = erlang:monotonic_time(millisecond) - Started,
                            Files = [patchFile(P) || P <- Patches],
                            ReportMd = applyMarkdown(ok, Res, Files, Elapsed),
                            Mermaid = mermaidApply(ok, Files),
                            {ok, Res#{
                                action => apply,
                                files => Files,
                                elapsedMs => Elapsed,
                                mermaid => Mermaid,
                                markdown => ReportMd,
                                summary => <<"applied ", (integer_to_binary(length(Files)))/binary,
                                             " patches">>
                            }};
                        {error, Reason} ->
                            Elapsed = erlang:monotonic_time(millisecond) - Started,
                            Files = [patchFile(P) || P <- Patches],
                            ReportMd = applyMarkdown(error, Reason, Files, Elapsed),
                            {error, #{
                                action => apply,
                                reason => Reason,
                                files => Files,
                                elapsedMs => Elapsed,
                                mermaid => mermaidApply(error, Files),
                                markdown => ReportMd,
                                rolledBack => maps:get(rolledBack, Reason, true)
                            }}
                    end
            end
    end.

%%--------------------------------------------------------------------
filesFromModules(Modules) ->
    lists:usort(lists:flatmap(fun moduleSourceFiles/1, Modules)).

moduleSourceFiles(Mod) when is_atom(Mod) ->
    case code:which(Mod) of
        Path when is_list(Path) ->
            case filename:extension(Path) of
                ".beam" ->
                    case guessErl(Mod, Path) of
                        undefined -> [];
                        Erl -> [unicode:characters_to_binary(Erl)]
                    end;
                _ -> []
            end;
        _ ->
            case guessErl(Mod, undefined) of
                undefined -> [];
                Erl -> [unicode:characters_to_binary(Erl)]
            end
    end;
moduleSourceFiles(_) ->
    [].

guessErl(Mod, BeamPath) ->
    %% Reuse docgen path resolution when available.
    try alDocGen:generateModuleDoc(Mod, #{includeDeps => false, includeMarkdown => false}) of
        {ok, #{sourcePath := Src}} when is_list(Src) -> Src;
        _ ->
            fallbackGuess(Mod, BeamPath)
    catch _:_ ->
        fallbackGuess(Mod, BeamPath)
    end.

fallbackGuess(Mod, BeamPath) when is_list(BeamPath) ->
    Erl = filename:rootname(BeamPath) ++ ".erl",
    case filelib:is_regular(Erl) of
        true -> Erl;
        false ->
            Base = atom_to_list(Mod) ++ ".erl",
            firstExisting([
                filename:join(["src", Base]),
                filename:join(["src", "tools", Base]),
                filename:join(["src", "agent", Base])
            ])
    end;
fallbackGuess(Mod, _) ->
    Base = atom_to_list(Mod) ++ ".erl",
    firstExisting([
        filename:join(["src", Base]),
        filename:join(["src", "tools", Base]),
        filename:join(["src", "agent", Base])
    ]).

firstExisting([]) -> undefined;
firstExisting([P | Rest]) ->
    case filelib:is_regular(P) of
        true -> P;
        false -> firstExisting(Rest)
    end.

moduleDepEdges(Modules) ->
    lists:flatmap(fun(Mod) ->
        try alCoreClient:unwrap(alCoreClient:moduleDeps(Mod)) of
            {ok, Res} when is_map(Res) ->
                Deps = maps:get(deps, Res, maps:get(<<"deps">>, Res, [])),
                [{Mod, D} || D <- lists:sublist(Deps, 20)];
            _ ->
                []
        catch
            _:_ -> []
        end
    end, Modules).

mermaidPlan(#{modules := Mods, files := Files, deps := Deps} = M) ->
    Intent = maps:get(intent, M, undefined),
    Title = case Intent of
        undefined -> <<"flowchart TB">>;
        I ->
            IntentId = sanitize(I),
            <<"flowchart TB\n  intent[", (truncate(toBin(I), 40))/binary, "]\n  intent --> scope_", IntentId/binary>>
    end,
    ModLines = [begin
                    Mid = sanitize(Mod),
                    <<"  ", Mid/binary, "[", (toBin(Mod))/binary, "]">>
                end || Mod <- lists:sublist(Mods, 30)],
    DepLines = [begin
                    A = sanitize(From),
                    B = sanitize(To),
                    <<"  ", A/binary, " --> ", B/binary>>
                end || {From, To} <- lists:sublist(Deps, 40)],
    FileNote = case Files of
        [] -> [];
        _ ->
            [<<"  files((", (integer_to_binary(length(Files)))/binary, " files))">>]
    end,
    unicode:characters_to_binary(lists:join(<<"\n">>, [Title] ++ ModLines ++ DepLines ++ FileNote)).

mermaidApply(ok, Files) ->
    N = integer_to_binary(length(Files)),
    Lines = [<<"flowchart LR">>, <<"  ok[applied ", N/binary, " files]">> |
             [begin
                  Id = sanitize(F),
                  <<"  ok --> ", Id/binary, "[", (truncate(toBin(F), 48))/binary, "]">>
              end || F <- lists:sublist(Files, 20)]],
    unicode:characters_to_binary(lists:join(<<"\n">>, Lines));
mermaidApply(error, Files) ->
    N = integer_to_binary(length(Files)),
    Lines = [<<"flowchart LR">>, <<"  fail[rolled back ", N/binary, " files]">> |
             [begin
                  Id = sanitize(F),
                  <<"  fail -.-> ", Id/binary, "[", (truncate(toBin(F), 48))/binary, "]">>
              end || F <- lists:sublist(Files, 20)]],
    unicode:characters_to_binary(lists:join(<<"\n">>, Lines)).

planMarkdown(Intent, Modules, Files, Mermaid) ->
    unicode:characters_to_binary([
        <<"# Batch refactor plan\n\n">>,
        case Intent of
            undefined -> <<>>;
            I -> [<<"**Intent:** ", (toBin(I))/binary, "\n\n">>]
        end,
        <<"## Modules (">>, integer_to_binary(length(Modules)), <<")\n">>,
        [[<<"- `">>, toBin(M), <<"`\n">>] || M <- Modules],
        <<"\n## Files (">>, integer_to_binary(length(Files)), <<")\n">>,
        [[<<"- `">>, toBin(F), <<"`\n">>] || F <- lists:sublist(Files, 80)],
        case length(Files) > 80 of
            true -> <<"\n_…truncated_\n"/utf8>>;
            false -> <<>>
        end,
        <<"\n## Graph\n\n```mermaid\n">>, Mermaid, <<"\n```\n">>
    ]).

applyMarkdown(ok, Res, Files, Elapsed) ->
    Tx = maps:get(transactionId, Res, undefined),
    unicode:characters_to_binary([
        <<"# Batch refactor apply — OK\n\n"/utf8>>,
        <<"- files: ">>, integer_to_binary(length(Files)), <<"\n">>,
        <<"- elapsedMs: ">>, integer_to_binary(Elapsed), <<"\n">>,
        case Tx of
            undefined -> <<>>;
            T -> [<<"- transactionId: ">>, toBin(T), <<"\n">>]
        end,
        <<"\n## Files\n">>,
        [[<<"- `">>, toBin(F), <<"`\n">>] || F <- Files]
    ]);
applyMarkdown(error, Reason, Files, Elapsed) ->
    unicode:characters_to_binary([
        <<"# Batch refactor apply — FAILED (rolled back)\n\n"/utf8>>,
        <<"- elapsedMs: ">>, integer_to_binary(Elapsed), <<"\n">>,
        <<"- reason: `">>, truncate(toBin(Reason), 500), <<"`\n">>,
        <<"\n## Attempted files\n">>,
        [[<<"- `">>, toBin(F), <<"`\n">>] || F <- Files]
    ]).

patchFile(#{file := F}) -> toBin(F);
patchFile(#{<<"file">> := F}) -> toBin(F);
patchFile(_) -> <<"?">>.

ensureList(L) when is_list(L) -> L;
ensureList(undefined) -> [];
ensureList(Other) -> [Other].

toAtomSafe(A) when is_atom(A) -> A;
toAtomSafe(B) when is_binary(B) ->
    try binary_to_existing_atom(B, utf8) catch _:_ -> undefined end;
toAtomSafe(L) when is_list(L) -> toAtomSafe(list_to_binary(L));
toAtomSafe(_) -> undefined.

toBin(A) when is_atom(A) -> atom_to_binary(A, utf8);
toBin(B) when is_binary(B) -> B;
toBin(L) when is_list(L) -> unicode:characters_to_binary(L);
toBin(N) when is_integer(N) -> integer_to_binary(N);
toBin(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

sanitize(Term) ->
    re:replace(toBin(Term), <<"[^A-Za-z0-9_]">>, <<"_">>, [global, {return, binary}]).

truncate(Bin, Max) when is_binary(Bin), byte_size(Bin) =< Max -> Bin;
truncate(Bin, Max) when is_binary(Bin) ->
    <<(truncateUtf8(Bin, Max))/binary, "…"/utf8>>;
truncate(Other, Max) ->
    truncate(toBin(Other), Max).

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
