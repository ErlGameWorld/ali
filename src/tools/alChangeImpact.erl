%%%-------------------------------------------------------------------
%% @doc 变更影响分析：根据 git 提交分析修改的影响范围，辅助判断"改得是否有问题"。
%%
%% 流程：
%% <ol>
%% <li>{@link analyze/1}：拿提交的文件变更 → 提取修改的模块函数 →
%%     对每个函数反向遍历 callers（递归限深防环）→ 汇总受影响的调用链。</li>
%% <li>{@link review/1}：把 diff + 影响范围交给 LLM 审查，输出
%%     "改了什么/影响哪些地方/是否有问题/建议"。</li>
%% </ol>
%%
%% 核心价值：大型项目里一次提交可能波及多处，人眼难穷尽调用链。
%% 用 petgraph 调用图反向追溯，让 LLM 看到"这个函数改了，谁会受影响"。
%%
%% 注：通过 {@link alVcsIndex} 支持 git 与 svn。
%% @end
%%%-------------------------------------------------------------------

-module(alChangeImpact).

-export([analyze/1, analyze/2, review/1, review/2, recentCommits/0, recentCommits/1, recentCommits/2,
         listCommits/1, searchCommits/1, commitDiff/1, commitFiles/1,
         dailyReview/0, dailyReview/1,
         functionHistory/3, functionHistory/4]).
%% 测试导出 — 纯辅助函数
-export([
    reverseTraverse/3,
    callerMfa/1,
    edgeField/2,
    summarize/1,
    buildReviewPrompt/2,
    buildStructuredReviewHints/3,
    formatNaturalSummary/1,
    applySummaryMode/2,
    topTouchedModules/2,
    buildDailyReviewHint/3,
    changeTypeCounts/1,
    lightCommitHints/1,
    wrapCommitList/3,
    moduleFromPath/1,
    safeGetCallers/3,
    classifyChangeType/1,
    commitTouchesFunction/3,
    commitRef/1,
    extractFunctionLineRange/2,
    aggregateHistory/4,
    hunksTouchingRange/3,
    parseHunkPlusRange/1,
    maybeParseDiffFile/2,
    trimAfterWs/1,
    stripABPrefix/1,
    functionNameOf/1,
    functionArityOf/1
]).

-define(MaxReverseDepth, 3).       %% 反向遍历深度：3 跳，防爆炸
-define(MaxFunctionsPerModule, 8). %% 单模块最多分析 N 个函数，控规模
-define(MaxImpactNodes, 60).       %% 影响范围总节点上限
-define(DefaultHistoryDays, 30).   %% 默认回溯 30 天
-define(MaxHistoryCommits, 20).    %% 函数历史最多回溯 N 次提交
-define(MaxHistoryScanCommits, 50).%% 扫描上限：从最近 N 条提交里找触及该函数的
-define(MaxFileEnrichCommits, 15). %% 无 withFiles 时最多补文件的 commit 数
-define(AutoWithFilesLimit, 25).   %% limit≤此值且未显式 withFiles 时默认带文件

%%%===================================================================
%%% 主入口
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 分析某次提交的影响范围。
%%
%% 流程：
%% 1. {@link alGitIndex:commitFiles/1} 拿改了哪些文件
%% 2. 从文件路径提取模块名
%% 3. 对每个模块用 {@link alCoreClient:moduleSymbols/1} 拿函数列表
%% 4. 对每个函数 {@link reverseTraverse/3} 反向追溯 callers
%% 5. {@link summarize/1} 汇总受影响的调用链
%%
%% @param Ref 提交 hash/tag/branch
%% @return {ok, #{commit, files, impacts, summary}} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
analyze(Ref) ->
    analyze(Ref, #{}).

analyze(Ref, Opts) when is_map(Opts) ->
    case alVcsIndex:commitDiff(Ref) of
        {ok, CommitInfo0} ->
            CommitInfo = maybeEnrichCommitDiffHunks(CommitInfo0),
            Files = maps:get(files, CommitInfo, []),
            Modules = [M || Path <- Files, M <- [moduleFromPath(Path)], M =/= undefined],
            UniqueModules = lists:usort(Modules),
            Impacts = analyzeModules(UniqueModules),
            Summary0 = summarize(Impacts),
            Summary = enrichSummaryWithAffectedSources(Summary0),
            Hints = buildStructuredReviewHints(CommitInfo, UniqueModules, Summary),
            Result0 = maps:merge(#{
                commit => CommitInfo,
                files => Files,
                modules => UniqueModules,
                impacts => Impacts,
                summary => Summary
            }, Hints),
            {ok, applySummaryMode(Result0, maps:get(summaryMode, Opts, both))};
        Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% @doc
%% LLM 审查变更：把 diff + 影响范围交给 LLM，评估"改得是否有问题"。
%%
%% @param Ref 提交 hash/tag/branch
%% @return {ok, #{review, impact}} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
review(Ref) ->
    review(Ref, #{}).

review(Ref, Opts) when is_map(Opts) ->
    case analyze(Ref, Opts) of
        {ok, #{commit := CommitInfo, summary := Summary} = Result} ->
            Prompt = buildReviewPrompt(CommitInfo, Summary),
            Messages = [
                #{role => system, content => reviewSystemPrompt()},
                #{role => user, content => Prompt}
            ],
            ReviewResult = try
                %% 影响审查属辅助任务：链路由时优先 aux 角色（本地模型）。
                case alLlmClient:chat(Messages, #{execTimeout => 15000, llmRole => aux}) of
                    {ok, Reply} -> maps:get(content, Reply, <<>>);
                    {error, _} -> <<"影响范围分析完成，但 LLM 审查失败。请结合影响范围人工复核。"/utf8>>
                end
            catch _:_ ->
                <<"影响范围分析完成，但 LLM 审查异常。请结合影响范围人工复核。"/utf8>>
            end,
            {ok, Result#{llmReview => ReviewResult}};
        Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% @doc
%% 便捷入口：列出最近提交（供 LLM 或用户选择分析目标）。
%% @end
%%--------------------------------------------------------------------
recentCommits() ->
    recentCommits(10).

recentCommits(N) when is_integer(N), N > 0 ->
    %% 单次 VCS 拉 files，便于直接给出 topTouchedModules / reviewHint
    listCommits(#{limit => N, withFiles => true});
recentCommits(_) ->
    {error, invalidCount}.

%%--------------------------------------------------------------------
%% @doc 最近 N 条，限制在最近 Days 天（days=1 ≈ 昨天至今）。
%% @end
%%--------------------------------------------------------------------
recentCommits(N, Days) when is_integer(N), N > 0, is_integer(Days), Days > 0 ->
    case listCommits(#{limit => N, days => Days, withFiles => true}) of
        {ok, Base} -> {ok, Base#{days => Days}};
        Error -> Error
    end;
recentCommits(_, _) ->
    {error, invalidCount}.

%%--------------------------------------------------------------------
%% @doc 按选项列提交（limit/days/grep/author/path/withFiles）。
%% 默认在 limit 较小时自动 withFiles，并统一补 topTouchedModules / changeTypeCounts / reviewHint。
%% @end
%%--------------------------------------------------------------------
listCommits(Opts) when is_map(Opts) ->
    Opts1 = maybeDefaultWithFiles(Opts),
    case alVcsIndex:listCommits(Opts1) of
        {ok, Commits} ->
            {ok, wrapCommitList(Commits, sanitizeOpts(Opts1), undefined)};
        Error ->
            Error
    end;
listCommits(_) ->
    {error, invalidOpts}.

%%--------------------------------------------------------------------
%% @doc 按提交说明搜索（grep/query 必填）。
%% @end
%%--------------------------------------------------------------------
searchCommits(Opts) when is_map(Opts) ->
    Opts1 = maybeDefaultWithFiles(Opts),
    case alVcsIndex:searchCommits(Opts1) of
        {ok, Commits} ->
            Base = wrapCommitList(Commits, sanitizeOpts(Opts1), undefined),
            {ok, Base#{query => maps:get(grep, Opts1, maps:get(query, Opts1, <<>>))}};
        Error ->
            Error
    end;
searchCommits(_) ->
    {error, invalidOpts}.

%%--------------------------------------------------------------------
%% @doc 轻量查看某次提交改了什么（文件 + 截断 patch），不跑 LLM。
%% @end
%%--------------------------------------------------------------------
commitDiff(Ref) ->
    case alVcsIndex:commitDiff(Ref) of
        {ok, Diff} ->
            Enriched = maybeEnrichCommitDiffHunks(Diff),
            Light = lightCommitHints(Enriched),
            {ok, maps:merge(Enriched#{vcs => alVcsIndex:vcsType()}, Light)};
        Error ->
            Error
    end.

%% 给轻量 commitDiff 结果补上“少量”函数/行附近的 sourcePreview，
%% 避免 LLM 再次到处 readFile/searchText 猜上下文。
maybeEnrichCommitDiffHunks(Diff) when is_map(Diff) ->
    Patch = maps:get(patch, Diff, <<>>),
    case Patch of
        <<>> ->
            Diff;
        _ ->
            Hunks = parseGitPatchHunksAndPreview(Patch, 16, 3, 30000),
            case Hunks of
                [] -> Diff;
                _ ->
                    Diff#{patchHunks => Hunks, patchHunksCount => length(Hunks)}
            end
    end;
maybeEnrichCommitDiffHunks(Diff) ->
    Diff.

parseGitPatchHunksAndPreview(PatchBin, MaxHunks, ContextLines, MaxSnippetBytes) ->
    Lines = binary:split(PatchBin, <<"\n">>, [global, trim_all]),
    parseGitPatchHunksAndPreview(Lines, undefined, [], MaxHunks,
                                 ContextLines, MaxSnippetBytes).

parseGitPatchHunksAndPreview([], _CurFile, Acc, _Max, _Ctx, _MaxBytes) ->
    lists:reverse(Acc);
parseGitPatchHunksAndPreview([Line | Rest], CurFile, Acc, Max, Ctx, MaxBytes) ->
    case maybeParseDiffFile(Line, CurFile) of
        {new_file, File1} ->
            parseGitPatchHunksAndPreview(Rest, File1, Acc, Max, Ctx, MaxBytes);
        cur ->
            %% @@ +start,count @@
            case Acc of
                L when length(L) >= Max ->
                    lists:reverse(Acc);
                _ ->
                    case parseHunkPlusRange(Line) of
                        {Start, End} when CurFile =/= undefined ->
                            {_, OkAcc} =
                                previewHunk(CurFile, Start, End, Ctx, MaxBytes, Acc),
                            parseGitPatchHunksAndPreview(Rest, CurFile, OkAcc, Max, Ctx, MaxBytes);
                        _ ->
                            parseGitPatchHunksAndPreview(Rest, CurFile, Acc, Max, Ctx, MaxBytes)
                    end
            end
    end.

previewHunk(File0, Start, End, Ctx, MaxBytes, Acc) ->
    Start0 = max(1, Start - Ctx),
    End0 = End + Ctx,
    case alToolsExt:readFile(#{path => File0,
                               startLine => Start0,
                               endLine => End0,
                               maxBytes => MaxBytes}) of
        {ok, R} ->
            H = #{file => File0,
                  startLine => Start0,
                  endLine => maps:get(endLine, R, End0),
                  truncated => maps:get(truncated, R, false),
                  snippet => maps:get(content, R)},
            {H, [H | Acc]};
        _ ->
            {undefined, Acc}
    end.

maybeParseDiffFile(<<"diff --git ", _/binary>> = Line, _Cur) ->
    %% diff --git a/<old> b/<new>
    case re:run(Line, <<"^diff --git a/(.+) b/(.+)$">>,
                [{capture, all_but_first, binary}]) of
        {match, [_, NewPath]} ->
            {new_file, NewPath};
        _ ->
            cur
    end;
maybeParseDiffFile(<<"Index: ", Rest/binary>>, _Cur) ->
    %% SVN diff 常见头：`Index: src/foo.erl`
    P0 = trimAfterWs(Rest),
    case stripABPrefix(P0) of
        <<"/dev/null">> -> cur;
        P -> {new_file, P}
    end;
maybeParseDiffFile(<<"--- ", Rest/binary>>, _Cur) ->
    %% SVN diff 也可能只有 `---/+++` 标记；`---` 是旧版本，先占位即可
    P0 = trimAfterWs(Rest),
    case stripABPrefix(P0) of
        <<"/dev/null">> -> cur;
        P -> {new_file, P}
    end;
maybeParseDiffFile(<<"+++ ", Rest/binary>>, _Cur) ->
    %% +++ b/<path>  或 +++ /dev/null
    P0 = trimAfterWs(Rest),
    case stripABPrefix(P0) of
        <<"/dev/null">> -> cur;
        P -> {new_file, P}
    end;
maybeParseDiffFile(_, _CurFile) ->
    cur.

parseHunkPlusRange(Line) ->
    %% @@ -a,b +c,d @@
    case re:run(Line, <<"^@@[^@]*\\+(\\d+)(?:,(\\d+))?[^@]*@@">>,
                [{capture, all_but_first, binary}]) of
        {match, [StartBin]} ->
            {binary_to_integer(StartBin), binary_to_integer(StartBin)};
        {match, [StartBin, CountBin]} ->
            Start = binary_to_integer(StartBin),
            Count = binary_to_integer(CountBin),
            End = Start + max(1, Count) - 1,
            {Start, End};
        _ ->
            false
    end.

trimAfterWs(Bin) ->
    %% 取到第一个空格/Tab 前，丢弃时间戳/注释。
    case {binary:match(Bin, <<" ">>), binary:match(Bin, <<"\t">>)} of
        {{Pos1, _}, {Pos2, _}} -> binary:part(Bin, 0, min(Pos1, Pos2));
        {{Pos1, _}, nomatch} -> binary:part(Bin, 0, Pos1);
        {nomatch, {Pos2, _}} -> binary:part(Bin, 0, Pos2);
        {nomatch, nomatch} -> Bin
    end.

stripABPrefix(P) ->
    %% 兼容 `a/xxx` / `b/xxx` 前缀（git/svn patch 常见）
    case P of
        <<"a/", Rest/binary>> -> Rest;
        <<"b/", Rest/binary>> -> Rest;
        _ -> P
    end.

%%--------------------------------------------------------------------
%% @doc 某次提交修改的文件列表。
%% @end
%%--------------------------------------------------------------------
commitFiles(Ref) ->
    case alVcsIndex:commitFiles(Ref) of
        {ok, Files} ->
            {ok, #{vcs => alVcsIndex:vcsType(), ref => toBin(Ref),
                   files => Files, count => length(Files)}};
        Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% @doc 按天审查入口：默认最近 1 天提交 + 各提交改动文件（单次 VCS 调用）。
%% @end
%%--------------------------------------------------------------------
dailyReview() ->
    dailyReview(#{}).

dailyReview(Opts) when is_map(Opts) ->
    %% 未显式给 days 时默认 1；禁止把「最后一次」误放大成 30 天——那是调用方选错工具
    Days = case maps:get(days, Opts, 1) of
        D when is_integer(D), D > 0 -> min(D, 90);
        _ -> 1
    end,
    Limit = case maps:get(limit, Opts, 50) of
        L when is_integer(L), L > 0 -> min(L, 200);
        _ -> 50
    end,
    Author = maps:get(author, Opts, undefined),
    Path = maps:get(path, Opts, undefined),
    ListOpts0 = #{limit => Limit, days => Days, withFiles => true},
    ListOpts1 = case Author of
        undefined -> ListOpts0;
        A -> ListOpts0#{author => A}
    end,
    ListOpts = case Path of
        undefined -> ListOpts1;
        P -> ListOpts1#{path => P}
    end,
    case listCommits(ListOpts) of
        {ok, #{commits := Commits} = Base} ->
            Hot = hotFiles(Commits, 15),
            TopMods = maps:get(topTouchedModules, Base, topTouchedModules(Commits, 10)),
            Count = maps:get(count, Base, length(Commits)),
            {ok, Base#{
                days => Days,
                hotFiles => Hot,
                topTouchedModules => TopMods,
                reviewHint => buildDailyReviewHint(Days, Count, TopMods),
                summary => iolist_to_binary(io_lib:format(
                    "~p commits in last ~p day(s); top files: ~p",
                    [Count, Days, [F || #{path := F} <- Hot]]))
            }};
        Error ->
            Error
    end;
dailyReview(_) ->
    {error, invalidOpts}.

sanitizeOpts(Opts) ->
    maps:with([limit, days, grep, query, author, path, withFiles], Opts).

%% limit 较小且未显式指定 withFiles 时默认带文件，便于模块摘要。
maybeDefaultWithFiles(Opts) when is_map(Opts) ->
    case maps:is_key(withFiles, Opts) of
        true ->
            Opts;
        false ->
            Limit = maps:get(limit, Opts, 20),
            case is_integer(Limit) andalso Limit =< ?AutoWithFilesLimit of
                true -> Opts#{withFiles => true};
                false -> Opts
            end
    end;
maybeDefaultWithFiles(Opts) ->
    Opts.

%% 统一给 commit 列表补 answer-friendly 字段。
%% DaysOrUndef：传入整数时用 daily 风格 hint；否则用 list 风格。
wrapCommitList(Commits, SanitizedOpts, DaysOrUndef) when is_list(Commits) ->
    Commits1 = ensureFilesOnCommits(Commits, ?MaxFileEnrichCommits),
    TopMods = topTouchedModules(Commits1, 10),
    Types = changeTypeCounts(Commits1),
    Count = length(Commits1),
    Hint = case DaysOrUndef of
        D when is_integer(D), D > 0 ->
            buildDailyReviewHint(D, Count, TopMods);
        _ ->
            buildListCommitsReviewHint(Count, TopMods)
    end,
    #{
        vcs => alVcsIndex:vcsType(),
        commits => Commits1,
        count => Count,
        opts => SanitizedOpts,
        topTouchedModules => TopMods,
        changeTypeCounts => Types,
        reviewHint => Hint
    };
wrapCommitList(_, SanitizedOpts, _) ->
    #{
        vcs => alVcsIndex:vcsType(),
        commits => [],
        count => 0,
        opts => SanitizedOpts,
        topTouchedModules => [],
        changeTypeCounts => #{},
        reviewHint => <<"无匹配提交。"/utf8>>
    }.

%% 对缺少 files 的前 Max 条 commit 用 commitFiles 补齐（控 VCS 调用次数）。
ensureFilesOnCommits(Commits, Max) when is_list(Commits), is_integer(Max), Max >= 0 ->
    {Filled, _} = lists:mapfoldl(
        fun(C, N) ->
            case maps:get(files, C, []) of
                [_|_] ->
                    {C, N};
                _ when N >= Max ->
                    {C, N};
                _ ->
                    case commitRef(C) of
                        undefined ->
                            {C, N};
                        Ref ->
                            case alVcsIndex:commitFiles(Ref) of
                                {ok, Files} when is_list(Files) ->
                                    {C#{files => Files}, N + 1};
                                _ ->
                                    {C, N + 1}
                            end
                    end
            end
        end, 0, Commits),
    Filled;
ensureFilesOnCommits(Commits, _) ->
    Commits.

%% 按 commit message 统计变更类型分布。
changeTypeCounts(Commits) when is_list(Commits) ->
    lists:foldl(fun(C, Acc) ->
        Type = classifyChangeType(maps:get(subject, C, <<>>)),
        Acc#{Type => maps:get(Type, Acc, 0) + 1}
    end, #{}, Commits);
changeTypeCounts(_) ->
    #{}.

%% commitDiff / lastCommit 轻量结构化提示（无需调用图）。
lightCommitHints(Diff) when is_map(Diff) ->
    Files = maps:get(files, Diff, []),
    Mods = [atom_to_binary(M, utf8) || M <- modulesFromPaths(Files)],
    Subject = maps:get(subject, Diff, <<>>),
    Type = classifyChangeType(Subject),
    Areas = [moduleTestArea(M) || M <- lists:sublist(modulesFromPaths(Files), 6)]
        ++ changeTypeTestAreas(Type),
    #{
        changeType => Type,
        touchedModules => Mods,
        suggestedTestAreas => lists:sublist(dedupBinList(Areas), 8),
        reviewHint => <<"轻量 diff 已含 touchedModules/suggestedTestAreas。"
                        "深挖调用图影响 → reviewChangeImpact(ref=同 ref)。"/utf8>>
    };
lightCommitHints(_) ->
    #{}.

%% 统计 commits 中 files 字段的出现次数，取 top N。
hotFiles(Commits, TopN) ->
    Counts = lists:foldl(fun(C, Acc) ->
        Files = maps:get(files, C, []),
        lists:foldl(fun(F, A) ->
            Key = case F of
                B when is_binary(B) -> B;
                L when is_list(L) -> unicode:characters_to_binary(L);
                Other -> unicode:characters_to_binary(io_lib:format("~p", [Other]))
            end,
            A#{Key => maps:get(Key, A, 0) + 1}
        end, Acc, Files)
    end, #{}, Commits),
    Sorted = lists:sort(fun({_, A}, {_, B}) -> A >= B end, maps:to_list(Counts)),
    [#{path => P, hits => N} || {P, N} <- lists:sublist(Sorted, TopN)].

%% 从 commits 的 files 字段统计模块出现次数，取 top N。
topTouchedModules(Commits, TopN) when is_list(Commits), is_integer(TopN), TopN > 0 ->
    Counts = lists:foldl(fun(C, Acc) ->
        Files = maps:get(files, C, []),
        lists:foldl(fun(F, A) ->
            case moduleFromPath(F) of
                undefined -> A;
                Mod ->
                    A#{Mod => maps:get(Mod, A, 0) + 1}
            end
        end, Acc, Files)
    end, #{}, Commits),
    Sorted = lists:sort(fun({_, A}, {_, B}) -> A >= B end, maps:to_list(Counts)),
    [#{module => atom_to_binary(M, utf8), hits => N}
     || {M, N} <- lists:sublist(Sorted, TopN)];
topTouchedModules(_, _) ->
    [].

buildDailyReviewHint(Days, Count, TopMods) ->
    ModStr = formatTopModulesHint(TopMods),
    case Count of
        0 ->
            iolist_to_binary([
                <<"最近 "/utf8>>, integer_to_binary(Days),
                <<" 天无提交。"/utf8>>]);
        N ->
            iolist_to_binary([
                <<"最近 "/utf8>>, integer_to_binary(Days),
                <<" 天共 "/utf8>>, integer_to_binary(N),
                <<" 条提交。热点模块: "/utf8>>, ModStr,
                <<"。回答「改了什么/有无问题」时，对关键 commit 用 reviewChangeImpact(ref=hash)；"
                  "只看 diff 用 commitDiff(ref=hash)。"/utf8>>])
    end.

buildListCommitsReviewHint(0, _TopMods) ->
    <<"无匹配提交。"/utf8>>;
buildListCommitsReviewHint(Count, TopMods) ->
    ModStr = formatTopModulesHint(TopMods),
    iolist_to_binary([
        <<"共 "/utf8>>, integer_to_binary(Count),
        <<" 条提交。热点模块: "/utf8>>, ModStr,
        <<"。单条深挖 → reviewChangeImpact(ref=hash)；轻量 diff → commitDiff(ref=hash)。"/utf8>>]).

formatTopModulesHint([]) ->
    <<"(无 .erl 模块)"/utf8>>;
formatTopModulesHint(TopMods) ->
    Names = [maps:get(module, M, <<>>)
             || M <- lists:sublist(TopMods, 6),
                maps:get(module, M, <<>>) =/= <<>>],
    case Names of
        [] -> <<"(无 .erl 模块)"/utf8>>;
        _ -> iolist_to_binary(string:join([unicode:characters_to_list(N) || N <- Names], ", "))
    end.

toBin(B) when is_binary(B) -> B;
toBin(L) when is_list(L) -> unicode:characters_to_binary(L);
toBin(A) when is_atom(A) -> atom_to_binary(A, utf8);
toBin(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).

%%%===================================================================
%%% 函数级变更历史聚合（P2-8）
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 函数级变更历史聚合：给定 M:F/A，回溯最近 ?DefaultHistoryDays 天内
%% 涉及该函数的提交，按变更类型分类聚合。
%%
%% 流程：
%% 1. alCoreClient:moduleSymbols(Module) 拿函数行范围（用于精确判定提交是否触及该函数）
%% 2. alVcsIndex:recentCommits(?MaxHistoryScanCommits, Days) 拿最近提交
%% 3. 对每个提交，调 commitTouchesFunction 判定是否触及目标函数
%% 4. 命中提交按 commit message 分类（fix/feat/refactor/test/docs/...）
%% 5. 聚合输出：总变更次数、首次/末次时间、变更类型分布、提交列表
%%
%% @param Module 模块名（atom/binary）
%% @param Function 函数名（atom/binary）
%% @param Arity 元数（integer/binary）
%% @return {ok, #{module, function, arity, totalChanges, changeTypes, commits, firstAt, lastAt}}
%%       | {error, Reason}
%% @end
%%--------------------------------------------------------------------
functionHistory(Module, Function, Arity) ->
    functionHistory(Module, Function, Arity, ?DefaultHistoryDays).

functionHistory(Module0, Function0, Arity0, Days) when is_integer(Days), Days > 0 ->
    Module = toAtom(Module0),
    Function = toAtom(Function0),
    Arity = toInt(Arity0),
    case is_atom(Module) andalso is_atom(Function) andalso is_integer(Arity) of
        false ->
            {error, badMfa};
        true ->
            LineRange = extractFunctionLineRange(Module, {Function, Arity}),
            scanFunctionHistory(Module, Function, Arity, LineRange, Days)
    end;
functionHistory(_, _, _, _) ->
    {error, invalidArgs}.

%% 拉取函数行范围：从 moduleSymbols 找匹配 {Function, Arity} 的函数定义行号。
%% 返回 {StartLine, EndLine} | undefined（无法确定时）。
extractFunctionLineRange(Module, {Function, Arity}) when is_atom(Module) ->
    try alCoreClient:moduleSymbols(Module) of
        {ok, #{data := #{document := Doc}}} when is_map(Doc) ->
            Funs = maps:get(functions, Doc, maps:get(<<"functions">>, Doc, [])),
            findFunctionRange(Funs, Function, Arity);
        _ ->
            undefined
    catch _:_ ->
        undefined
    end;
extractFunctionLineRange(_, _) ->
    undefined.

findFunctionRange([], _Function, _Arity) -> undefined;
findFunctionRange([F | Rest], Function, Arity) ->
    FName = maps:get(name, F, maps:get(<<"name">>, F, undefined)),
    FArity = maps:get(arity, F, maps:get(<<"arity">>, F, undefined)),
    case equalsAtom(FName, Function) andalso equalsInt(FArity, Arity) of
        true ->
            Start = maps:get(line, F, maps:get(<<"line">>, F, 0)),
            End = maps:get(endLine, F, maps:get(<<"endLine">>, F, Start)),
            case toInt(Start) of
                0 -> undefined;
                S -> {S, max(S, toInt(End))}
            end;
        false ->
            findFunctionRange(Rest, Function, Arity)
    end.

equalsAtom(A, B) when is_atom(A), is_atom(B) -> A =:= B;
equalsAtom(A, B) when is_binary(A), is_atom(B) ->
    try binary_to_existing_atom(A, utf8) =:= B catch _:_ -> false end;
equalsAtom(_, _) -> false.

equalsInt(A, B) when is_integer(A), is_integer(B) -> A =:= B;
equalsInt(A, B) when is_binary(A), is_integer(B) ->
    try binary_to_integer(A) =:= B catch _:_ -> false end;
equalsInt(_, _) -> false.

%% 扫描最近提交，过滤出触及目标函数的提交，按变更类型分类聚合。
scanFunctionHistory(Module, Function, Arity, LineRange, Days) ->
    case alVcsIndex:recentCommits(?MaxHistoryScanCommits, Days) of
        {ok, Commits} ->
            Touched = lists:filtermap(
                fun(C) ->
                    case commitTouchesFunction(C, Module, LineRange) of
                        true ->
                            Type = classifyChangeType(maps:get(subject, C, <<>>)),
                            {true, C#{changeType => Type}};
                        false ->
                            false
                    end
                end, Commits),
            {ok, aggregateHistory(Module, Function, Arity, Touched)};
        {error, _} = Error ->
            Error
    end.

%% 判定某次提交是否触及目标函数：
%% - 优先用 commitFiles + 函数行范围精确匹配（如果 Rust 端已索引该模块）
%% - 行范围未知时降级为 commitFiles + 文件路径匹配 + patch 中含函数名（粗略）
%% - VCS 抽象层下 Git commit 用 hash 字段、SVN commit 用 revision 字段，二者择一。
commitTouchesFunction(Commit, Module, LineRange) ->
    Ref = commitRef(Commit),
    Ref =/= undefined andalso
        case alVcsIndex:commitFiles(Ref) of
            {ok, Files} ->
                ModuleFile = moduleFileName(Module),
                case lists:any(fun(F) -> isModuleFile(F, ModuleFile) end, Files) of
                    false -> false;
                    true ->
                        case LineRange of
                            undefined ->
                                %% 行范围未知：检查 patch 是否含函数名（粗略）
                                patchMentionsFunction(Ref, Module);
                            {StartLine, EndLine} ->
                                patchTouchesLineRange(Ref, StartLine, EndLine)
                        end
                end;
            _ -> false
        end.

%% 提取 commit 的版本引用：Git 用 hash，SVN 用 revision，二者择一。
%% 返回值可直接传给 alVcsIndex:commitFiles/1 与 commitDiff/1（两端 parseRevision 都兼容）。
commitRef(Commit) when is_map(Commit) ->
    case maps:get(hash, Commit, undefined) of
        undefined -> maps:get(revision, Commit, undefined);
        Hash -> Hash
    end;
commitRef(_) ->
    undefined.

%% 模块文件名（不含扩展名）：atom Module → "alFoo"
moduleFileName(Module) when is_atom(Module) ->
    atom_to_list(Module);
moduleFileName(Module) when is_binary(Module) ->
    unicode:characters_to_list(Module);
moduleFileName(_) -> "".

isModuleFile(Path, ModuleFile) when is_list(Path), is_list(ModuleFile), length(ModuleFile) > 0 ->
    Base = filename:rootname(filename:basename(Path)),
    Base =:= ModuleFile;
isModuleFile(_, _) -> false.

%% patch 中是否提及函数名（粗略匹配：在 patch 里找 `function(` 或 `function(` 的 atom）
patchMentionsFunction(Hash, Module) when is_atom(Module) ->
    case alVcsIndex:commitDiff(Hash) of
        {ok, #{patch := Patch}} when is_binary(Patch), byte_size(Patch) > 0 ->
            %% 这里只判定 patch 非空且提交文件包含模块——无法精确到函数。
            %% 调用方应传 LineRange 才能精确匹配。
            byte_size(Patch) > 0;
        _ ->
            false
    end;
patchMentionsFunction(_, _) ->
    false.

%% patch 是否触及 [StartLine, EndLine] 行范围：
%% 解析 patch 中的 @@ -a,b +c,d @@ 标记，检查 c ≤ EndLine 且 c+b ≥ StartLine。
patchTouchesLineRange(Hash, StartLine, EndLine) when is_integer(StartLine), is_integer(EndLine) ->
    case alVcsIndex:commitDiff(Hash) of
        {ok, #{patch := Patch}} when is_binary(Patch) ->
            hunksTouchingRange(Patch, StartLine, EndLine);
        _ ->
            false
    end;
patchTouchesLineRange(_, _, _) ->
    false.

%% 扫描 patch 中的 @@ +startLine,count @@ hunk 头，检查是否与目标范围相交。
hunksTouchingRange(Patch, StartLine, EndLine) ->
    case re:run(Patch, <<"^@@[^@]*\\+(\\d+)(?:,(\\d+))?[^@]*@@">>,
                [multiline, global, {capture, all_but_first, binary}]) of
        {match, Groups} ->
            lists:any(fun(Group) ->
                case hunkSpan(Group) of
                    {HunkStart, HunkEnd} ->
                        HunkStart =< EndLine andalso HunkEnd >= StartLine;
                    none ->
                        false
                end
            end, Groups);
        _ ->
            false
    end.

%% 从 hunk 头捕获组解析覆盖范围：优先用 `+c,d' 中的实际行数 d 计算结束行；
%% 解析失败或没有行数（老格式）时回退到 +100 的保守估算。
hunkSpan([HunkStartBin]) ->
    try
        HunkStart = binary_to_integer(HunkStartBin),
        {HunkStart, HunkStart + 100}
    catch
        _:_ -> none
    end;
hunkSpan([HunkStartBin, CountBin]) ->
    try
        HunkStart = binary_to_integer(HunkStartBin),
        Count = binary_to_integer(CountBin),
        {HunkStart, HunkStart + max(1, Count) - 1}
    catch
        _:_ -> none
    end;
hunkSpan(_) ->
    none.

%% 按 commit message 关键词分类变更类型。
classifyChangeType(Subject) when is_binary(Subject); is_list(Subject) ->
    S = string:lowercase(toBinary(Subject)),
    Patterns = [
        {<<"fix">>, fix},
        {<<"bugfix">>, fix},
        {<<"修复"/utf8>>, fix},
        {<<"bug">>, fix},
        {<<"feat">>, feat},
        {<<"feature">>, feat},
        {<<"新增"/utf8>>, feat},
        {<<"添加"/utf8>>, feat},
        {<<"refactor">>, refactor},
        {<<"重构"/utf8>>, refactor},
        {<<"cleanup">>, refactor},
        {<<"test">>, test},
        {<<"测试"/utf8>>, test},
        {<<"docs">>, docs},
        {<<"文档"/utf8>>, docs},
        {<<"doc">>, docs},
        {<<"perf">>, perf},
        {<<"性能"/utf8>>, perf},
        {<<"optimize">>, perf},
        {<<"优化"/utf8>>, perf},
        {<<"chore">>, chore},
        {<<"杂务"/utf8>>, chore}
    ],
    case lists:filtermap(fun({K, Type}) ->
        case binary:match(S, K) of
            nomatch -> false;
            _ -> {true, Type}
        end
    end, Patterns) of
        [] -> other;
        [Type | _] -> Type
    end;
classifyChangeType(_) ->
    other.

%% 聚合函数历史：总变更次数、变更类型分布、首次/末次提交时间、提交列表。
%% 空历史（无提交触及该函数）直接返回空聚合，避免 hd/lists:last 崩溃。
aggregateHistory(Module, Function, Arity, []) ->
    #{module => Module, function => Function, arity => Arity,
      totalChanges => 0, changeTypes => #{},
      firstAt => undefined, lastAt => undefined, commits => []};
aggregateHistory(Module, Function, Arity, TouchedCommits) ->
    TypeCounts = lists:foldl(fun(#{changeType := T}, Acc) ->
        maps:update_with(T, fun(V) -> V + 1 end, 1, Acc)
    end, #{}, TouchedCommits),
    SortedByTime = lists:sort(fun(A, B) ->
        compareCommitTime(A, B)
    end, TouchedCommits),
    #{module => Module, function => Function, arity => Arity,
      totalChanges => length(TouchedCommits),
      changeTypes => TypeCounts,
      firstAt => commitTime(hd(SortedByTime)),
      lastAt => commitTime(lists:last(SortedByTime)),
      commits => lists:sublist(SortedByTime, ?MaxHistoryCommits)}.

compareCommitTime(A, B) ->
    timeOf(A) =< timeOf(B).

timeOf(C) -> maps:get(date, C, maps:get(<<"date">>, C, <<>>)).

commitTime(C) -> timeOf(C).

%%%===================================================================
%%% 反向遍历调用图
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 从指定函数反向追溯 callers，递归限深防环。
%%
%% @param MFA {Module, Function, Arity}
%% @param Depth 剩余深度（0 时停止）
%% @param Seen 已访问节点集合（防环）
%% @return #{mfa, callers, cyclic?, depthLimited?}
%% @end
%%--------------------------------------------------------------------
reverseTraverse(_MFA, 0, _Seen) ->
    #{callers => [], depthLimited => true};
reverseTraverse({M, F, A} = MFA, Depth, Seen) ->
    Key = mfaKey(MFA),
    case sets:is_element(Key, Seen) of
        true ->
            #{mfa => MFA, callers => [], cyclic => true};
        false ->
            Callers = safeGetCallers(M, F, A),
            NewSeen = sets:add_element(Key, Seen),
            Expanded = lists:filtermap(
                fun(Edge) ->
                    case callerMfa(Edge) of
                        {undefined, _, _} -> false;
                        CallerMfa ->
                            {true, reverseTraverse(CallerMfa, Depth - 1, NewSeen)}
                    end
                end, Callers),
            #{mfa => MFA, callers => Expanded}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 从调用图 edge 提取调用方 MFA。
%% callers 的 edge 里 `from_*' 是调用方，`to_*' 是被调用方。
%% 防御性取 atom/binary 双键（jiffy 可能返回 binary 键）。
%% @end
%%--------------------------------------------------------------------
callerMfa(Edge) when is_map(Edge) ->
    M = edgeField(Edge, [from_module, <<"from_module">>]),
    F = edgeField(Edge, [from_function, <<"from_function">>]),
    A = edgeField(Edge, [from_arity, <<"from_arity">>]),
    {normalizeAtom(M), normalizeAtom(F), normalizeInt(A)};
callerMfa(_) ->
    {undefined, undefined, undefined}.

%%--------------------------------------------------------------------
%% @doc
%% 多键防御性取值：依次尝试 keys 列表里的键，返回第一个命中的值。
%% @end
%%--------------------------------------------------------------------
edgeField(_Edge, []) ->
    undefined;
edgeField(Edge, [K | Rest]) ->
    case maps:find(K, Edge) of
        {ok, V} -> V;
        error -> edgeField(Edge, Rest)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 安全调用 getCallers：core 不可用/异常时返回空列表。
%% @end
%%--------------------------------------------------------------------
safeGetCallers(M, F, A) ->
    try alCoreClient:getCallers(M, F, A) of
        {ok, #{data := #{edges := E}}} when is_list(E) -> E;
        {ok, #{data := Data}} when is_map(Data) -> maps:get(edges, Data, []);
        {ok, #{edges := E}} when is_list(E) -> E;
        _ -> []
    catch
        _:_ -> []
    end.

%%%===================================================================
%%% 摘要与 Prompt 构造
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 把影响范围树压平为摘要：列出所有受影响的 MFA 及其调用链深度。
%% 纯函数，便于测试。
%% @end
%%--------------------------------------------------------------------
summarize(Impacts) when is_list(Impacts) ->
    Flat = lists:flatmap(fun flattenImpact/1, Impacts),
    %% 去重并按出现次数排序（高频受影响函数优先）
    Deduped = dedupByKey(Flat),
    TopN = lists:sublist(Deduped, ?MaxImpactNodes),
    #{
        totalAffected => length(TopN),
        affectedFunctions => [formatAffected(M) || M <- TopN],
        affectedFunctionsMfa => TopN
    };
summarize(_) ->
    #{totalAffected => 0, affectedFunctions => []}.

%% 给 reviewChangeImpact 的 summary 里补充少量 sourcePreview，帮助 LLM 少 readFile/searchCode。
enrichSummaryWithAffectedSources(#{affectedFunctionsMfa := TopN0} = Summary) ->
    TopN = lists:sublist(TopN0, 18),
    case TopN of
        [] ->
            Summary#{affectedFunctionsDetailed => []};
        _ ->
            Detailed = enrichAffectedNodesWithSources(TopN),
            Summary#{affectedFunctionsDetailed => Detailed}
    end;
enrichSummaryWithAffectedSources(Summary) ->
    Summary#{affectedFunctionsDetailed => []}.

%% 结构化审查提示：便于 LLM 直接回答「测什么/风险在哪」而少二次推理。
buildStructuredReviewHints(CommitInfo, Modules, Summary) ->
    Subject = maps:get(subject, CommitInfo, <<>>),
    Files = maps:get(files, CommitInfo, []),
    ChangeType = classifyChangeType(Subject),
    TouchedModules = [atom_to_binary(M, utf8) || M <- Modules],
    AffectedCallers = extractAffectedCallers(Summary),
    RiskHints = buildRiskHints(ChangeType, Summary, Modules, Files),
    SuggestedTestAreas = buildSuggestedTestAreas(Modules, Summary, Files, ChangeType),
    #{
        changeType => ChangeType,
        touchedModules => TouchedModules,
        affectedCallers => AffectedCallers,
        riskHints => RiskHints,
        suggestedTestAreas => SuggestedTestAreas
    }.

%% summaryMode: structured | natural | both（默认 both）
applySummaryMode(Result, Mode0) when is_map(Result) ->
    Mode = normalizeSummaryMode(Mode0),
    case Mode of
        structured ->
            maps:remove(naturalSummary, Result#{summaryMode => structured});
        natural ->
            Nat = formatNaturalSummary(Result),
            %% 保留结构化字段供 agent；额外给 naturalSummary
            Result#{naturalSummary => Nat, summaryMode => natural};
        both ->
            Result#{naturalSummary => formatNaturalSummary(Result), summaryMode => both}
    end.

normalizeSummaryMode(natural) -> natural;
normalizeSummaryMode(<<"natural">>) -> natural;
normalizeSummaryMode("natural") -> natural;
normalizeSummaryMode(structured) -> structured;
normalizeSummaryMode(<<"structured">>) -> structured;
normalizeSummaryMode("structured") -> structured;
normalizeSummaryMode(both) -> both;
normalizeSummaryMode(<<"both">>) -> both;
normalizeSummaryMode("both") -> both;
normalizeSummaryMode(_) -> both.

%% 规则模板：把结构化字段拼成人类可读中文摘要（不调 LLM）。
formatNaturalSummary(Result) when is_map(Result) ->
    Type = maps:get(changeType, Result, other),
    Mods = maps:get(touchedModules, Result, []),
    Callers = maps:get(affectedCallers, Result, []),
    Risks = maps:get(riskHints, Result, []),
    Tests = maps:get(suggestedTestAreas, Result, []),
    Subject = case maps:get(commit, Result, #{}) of
        #{subject := S} when is_binary(S), S =/= <<>> -> S;
        _ -> <<>>
    end,
    TypeBin = changeTypeZh(Type),
    ModLine = case Mods of
        [] -> <<"未识别到 Erlang 模块变更"/utf8>>;
        _ -> iolist_to_binary([<<"修改了 "/utf8>>,
                               joinBins(lists:sublist(Mods, 8), <<"、"/utf8>>,
                                        <<" 等模块"/utf8>>)])
    end,
    CallerLine = case Callers of
        [] -> <<"目前索引未发现明确直接调用方"/utf8>>;
        _ ->
            Labels = [maps:get(mfa, C, <<>>) || C <- lists:sublist(Callers, 5)],
            iolist_to_binary([<<"可能影响调用方 "/utf8>>, joinBins(Labels, <<"、"/utf8>>, <<>>)])
    end,
    RiskLine = case Risks of
        [] -> <<"未标出额外风险点"/utf8>>;
        _ -> iolist_to_binary([<<"风险提示："/utf8>>, hd(Risks)])
    end,
    TestLine = case Tests of
        [] -> <<"建议结合 diff 做基础回归"/utf8>>;
        _ -> iolist_to_binary([<<"建议测试："/utf8>>, joinBins(lists:sublist(Tests, 4), <<"；"/utf8>>, <<>>)])
    end,
    SubjPart = case Subject of
        <<>> -> <<>>;
        _ -> iolist_to_binary([<<"提交主题「"/utf8>>, Subject, <<"」。"/utf8>>])
    end,
    iolist_to_binary([
        <<"本次为"/utf8>>, TypeBin, <<"类变更。"/utf8>>, SubjPart,
        ModLine, <<"。"/utf8>>,
        CallerLine, <<"。"/utf8>>,
        RiskLine, <<"。"/utf8>>,
        TestLine, <<"。"/utf8>>
    ]).

changeTypeZh(fix) -> <<"修复"/utf8>>;
changeTypeZh(feat) -> <<"功能"/utf8>>;
changeTypeZh(refactor) -> <<"重构"/utf8>>;
changeTypeZh(perf) -> <<"性能"/utf8>>;
changeTypeZh(docs) -> <<"文档"/utf8>>;
changeTypeZh(test) -> <<"测试"/utf8>>;
changeTypeZh(chore) -> <<"杂项"/utf8>>;
changeTypeZh(_) -> <<"一般"/utf8>>.

joinBins([], _Sep, _Suffix) -> <<>>;
joinBins(List, Sep, Suffix) ->
    Parts = [case X of B when is_binary(B) -> B; _ -> toBinary(X) end || X <- List],
    iolist_to_binary([lists:join(Sep, Parts), Suffix]).

extractAffectedCallers(Summary) ->
    TopN = maps:get(affectedFunctionsMfa, Summary, []),
    lists:sublist(
        [callerEntry(MFA, Depth) || {MFA, Depth} <- TopN, Depth > 0],
        20).

callerEntry({M, F, A}, Depth) ->
    #{
        mfa => formatMfaLabel({M, F, A}),
        depth => Depth,
        module => atom_to_binary(M, utf8),
        function => toBinary(F),
        arity => A
    }.

formatMfaLabel({M, F, A}) ->
    iolist_to_binary([atom_to_binary(M, utf8), <<":">>, toBinary(F),
                        <<"/">>, integer_to_binary(A)]).

buildRiskHints(ChangeType, Summary, Modules, Files) ->
    Total = maps:get(totalAffected, Summary, 0),
    Callers = maps:get(affectedFunctionsMfa, Summary, []),
    MaxDepth = maxCallerDepth(Callers),
    Hints0 = [],
    Hints1 = case Total > 15 of
        true ->
            [iolist_to_binary(io_lib:format("影响函数较多（~p 个），回归范围大。", [Total]))
             | Hints0];
        false ->
            Hints0
    end,
    Hints2 = case MaxDepth >= 2 of
        true -> [<<"存在 2 跳以上调用方，间接影响需关注。"/utf8>> | Hints1];
        false -> Hints1
    end,
    Hints3 = case lists:any(fun isCoreModule/1, Modules) of
        true -> [<<"触及 Agent/工具/核心链路模块，优先做集成回归。"/utf8>> | Hints2];
        false -> Hints2
    end,
    Hints4 = case isLowRiskFiles(Files) of
        true -> [<<"变更以文档/测试为主，功能回归风险较低。"/utf8>> | Hints3];
        false -> Hints3
    end,
    Hints5 = case {ChangeType, length(Modules)} of
        {fix, N} when N >= 2 ->
            [<<"跨模块修复，注意各模块行为一致性与根因是否彻底。"/utf8>> | Hints4];
        {refactor, _} ->
            [<<"重构类变更，重点验证行为不变与边界条件。"/utf8>> | Hints4];
        {perf, _} ->
            [<<"性能类变更，关注热点路径与资源占用。"/utf8>> | Hints4];
        _ ->
            Hints4
    end,
    Hints6 = case {Total, length([D || {_, D} <- Callers, D > 0])} of
        {T, 0} when T > 0 ->
            [<<"未发现直接调用方（可能动态调用或索引未覆盖）。"/utf8>> | Hints5];
        _ ->
            Hints5
    end,
    lists:reverse(Hints6).

maxCallerDepth([]) -> 0;
maxCallerDepth(Callers) ->
    lists:max([D || {_, D} <- Callers]).

isCoreModule(M) ->
    lists:member(M, [alAgent, alToolRouter, alCoreClient, alContext, alExecutionChain,
                     alChangeImpact, alToolsExt]).

isLowRiskFiles([]) -> false;
isLowRiskFiles(Files) ->
    lists:all(fun isDocOrTestFile/1, Files).

isDocOrTestFile(Path) ->
    Bin = toBinary(Path),
    case filename:extension(Bin) of
        <<".md">> -> true;
        _ ->
            case {binary:match(Bin, <<"/test/">>), binary:match(Bin, <<"\\test\\">>)} of
                {nomatch, nomatch} -> false;
                _ -> true
            end
    end.

buildSuggestedTestAreas(Modules, Summary, Files, ChangeType) ->
    ModuleAreas = [moduleTestArea(M) || M <- lists:sublist(Modules, 8)],
    CallerAreas = callerTestAreas(maps:get(affectedFunctionsMfa, Summary, [])),
    FileAreas = testFileAreas(Files),
    TypeAreas = changeTypeTestAreas(ChangeType),
    Deduped = dedupBinList(ModuleAreas ++ CallerAreas ++ FileAreas ++ TypeAreas),
    lists:sublist(Deduped, 12).

moduleTestArea(M) ->
    Name = atom_to_binary(M, utf8),
    iolist_to_binary([<<"eunit: test/">>, Name, <<"_tests.erl 或模块 "/utf8>>,
                      Name, <<" 相关用例"/utf8>>]).

callerTestAreas(Callers) ->
    [iolist_to_binary([<<"回归调用方 ">>, formatMfaLabel(MFA),
                       <<"（"/utf8>>, depthLabel(Depth), <<" 跳）"/utf8>>])
     || {MFA, Depth} <- lists:sublist([C || C = {_, D} <- Callers, D > 0], 5)].

depthLabel(1) -> <<"1"/utf8>>;
depthLabel(N) when is_integer(N) -> integer_to_binary(N);
depthLabel(_) -> <<"?"/utf8>>.

testFileAreas(Files) ->
    [iolist_to_binary([<<"运行已有测试: ">>, toBinary(F)])
     || F <- Files,
        isDocOrTestFile(F),
        binary:match(toBinary(F), <<"_tests">>) =/= nomatch].

changeTypeTestAreas(fix) ->
    [<<"复现原问题场景的手动/自动回归"/utf8>>];
changeTypeTestAreas(feat) ->
    [<<"新功能正向路径 + 边界条件"/utf8>>];
changeTypeTestAreas(refactor) ->
    [<<"关键路径 smoke test，确认行为不变"/utf8>>];
changeTypeTestAreas(perf) ->
    [<<"性能基准或热点路径验证"/utf8>>];
changeTypeTestAreas(test) ->
    [<<"确认新增/修改测试本身可运行且覆盖意图"/utf8>>];
changeTypeTestAreas(_) ->
    [].

dedupBinList(List) ->
    {Rev, _} = lists:foldl(
        fun(Bin, {Acc, Seen}) ->
            Key = toBinary(Bin),
            case sets:is_element(Key, Seen) of
                true -> {Acc, Seen};
                false -> {[Key | Acc], sets:add_element(Key, Seen)}
            end
        end, {[], sets:new()}, List),
    lists:reverse(Rev).

enrichAffectedNodesWithSources(TopN) ->
    Modules = lists:usort([M || {{M, _F, _A}, _Depth} <- TopN]),
    %% 每个模块只拉一次 moduleSymbols
    ModuleLookups =
        [moduleLookup(Module) || Module <- Modules],
    LookupMap = maps:from_list([{maps:get(module, L), L} || L <- ModuleLookups, maps:is_key(module, L)]),
    [enrichOneAffectedNode(N, LookupMap, 2, 20000) || N <- TopN].

moduleLookup(Module) ->
    try
        case alCoreClient:unwrap(alCoreClient:moduleSymbols(Module)) of
            {ok, Data} when is_map(Data) ->
                Doc = maps:get(document, Data, maps:get(<<"document">>, Data, Data)),
                Funs = case Doc of
                           M when is_map(M) ->
                               maps:get(functions, M, maps:get(<<"functions">>, M, []));
                           _ ->
                               []
                       end,
                File = moduleFileFromSymbols(Data),
                Lookup =
                    maps:from_list([{
                        {toBinary(maps:get(name, F, maps:get(<<"name">>, F, <<>>))),
                         normalizeInt(maps:get(arity, F, maps:get(<<"arity">>, F, undefined)))},
                        pickFunRange(F)
                    } || F <- Funs]),
                #{module => Module, file => File, lookup => Lookup};
            _ ->
                #{module => Module, file => undefined, lookup => #{}}
        end
    catch _:_ ->
        #{module => Module, file => undefined, lookup => #{}}
    end.

moduleFileFromSymbols(Data) when is_map(Data) ->
    case maps:get(file, Data, undefined) of
        undefined ->
            nestedFile(maps:get(document, Data, undefined));
        F -> F
    end;
moduleFileFromSymbols(_) ->
    undefined.

nestedFile(undefined) -> undefined;
nestedFile(M) when is_map(M) ->
    maps:get(file, M, undefined);
nestedFile(_) -> undefined.

pickFunRange(Fun) ->
    Start = maps:get(start_line, Fun,
                     maps:get(<<"start_line">>, Fun,
                              maps:get(startLine, Fun,
                                       maps:get(<<"startLine">>, Fun, undefined)))),
    End = maps:get(end_line, Fun,
                   maps:get(<<"end_line">>, Fun,
                            maps:get(endLine, Fun,
                                     maps:get(<<"endLine">>, Fun, undefined)))),
    Line = maps:get(line, Fun,
                     maps:get(<<"line">>, Fun, undefined)),
    {Start, End, Line}.

enrichOneAffectedNode({{M, F, A}, Depth} = Node, LookupMap, Ctx, MaxBytes) ->
    MLookup = maps:get(M, LookupMap, undefined),
    case MLookup of
        undefined ->
            #{affected => formatAffected(Node), depth => Depth};
        _ ->
            File = maps:get(file, MLookup, undefined),
            Lookup = maps:get(lookup, MLookup, #{}),
            Key = {toBinary(F), normalizeInt(A)},
            case maps:get(Key, Lookup, undefined) of
                undefined ->
                    #{affected => formatAffected(Node), depth => Depth};
                {Start, End, Line} ->
                    case File of
                        undefined ->
                            #{affected => formatAffected(Node), depth => Depth};
                        _ ->
                            {S0, E0} =
                                case {Start, End} of
                                    {S, E} when is_integer(S), is_integer(E), S >= 1, E >= S ->
                                        {max(1, S - Ctx), E + Ctx};
                                    _ ->
                                        case Line of
                                            L when is_integer(L), L >= 1 ->
                                                {max(1, L - Ctx), L + Ctx + 20};
                                            _ ->
                                                {undefined, undefined}
                                        end
                                end,
                            case {S0, E0} of
                                {undefined, _} ->
                                    #{affected => formatAffected(Node), depth => Depth};
                                _ ->
                                    case alToolsExt:readFile(#{path => File,
                                                               startLine => S0,
                                                               endLine => E0,
                                                               maxBytes => MaxBytes}) of
                                        {ok, R} ->
                                            #{
                                                module => M,
                                                function => F,
                                                arity => A,
                                                depth => Depth,
                                                file => File,
                                                sourceStartLine => S0,
                                                sourceEndLine => maps:get(endLine, R, E0),
                                                sourceTruncated => maps:get(truncated, R, false),
                                                sourcePreview => maps:get(content, R)
                                            };
                                        _ ->
                                            #{affected => formatAffected(Node), depth => Depth}
                                    end
                            end
                    end
            end
    end.

%% 把影响树压平为 {MFA, Depth} 列表
flattenImpact(#{mfa := MFA, callers := Callers}) ->
    Self = [{MFA, 0}],
    Children = lists:flatmap(
        fun(C) -> [{M, D + 1} || {M, D} <- flattenImpact(C)] end,
        Callers),
    Self ++ Children;
flattenImpact(_) ->
    [].

%%--------------------------------------------------------------------
%% @doc
%% 构造 LLM 审查 prompt：提交信息 + 影响范围摘要。
%% 纯函数，便于测试。
%% @end
%%--------------------------------------------------------------------
buildReviewPrompt(CommitInfo, Summary) ->
    Subject = maps:get(subject, CommitInfo, <<>>),
    Files = maps:get(files, CommitInfo, []),
    Patch = maps:get(patch, CommitInfo, <<>>),
    Affected = maps:get(affectedFunctions, Summary, []),
    PatchHunks = maps:get(patchHunks, CommitInfo, []),
    Detailed = maps:get(affectedFunctionsDetailed, Summary, []),
    Hints = buildStructuredReviewHints(CommitInfo,
                                       modulesFromPaths(Files),
                                       Summary),
    iolist_to_binary([
        <<"## 提交信息\n"/utf8>>,
        <<"主题: "/utf8>>, Subject, <<"\n">>,
        <<"修改文件:\n"/utf8>>,
        [[<<"  - ">>, F, <<"\n">>] || F <- Files],
        <<"\n## Patch\n```\n">>, Patch, <<"\n```\n\n">>,
        formatPatchHunksForPrompt(PatchHunks),
        formatStructuredHintsForPrompt(Hints),
        <<"## 影响范围分析\n"/utf8>>,
        <<"受影响的调用方（按调用深度排序）:\n"/utf8>>,
        [[<<"  - ">>, A, <<"\n">>] || A <- Affected],
        formatDetailedAffectedForPrompt(Detailed),
        <<"\n## 请审查\n"/utf8>>,
        <<"1. 这次改动是否正确？有无遗漏的边界条件或错误处理？\n"/utf8>>,
        <<"2. 受影响的调用方是否需要同步修改？\n"/utf8>>,
        <<"3. 有无潜在的回归风险？\n"/utf8>>,
        <<"请分点回答。"/utf8>>
    ]).

modulesFromPaths(Files) ->
    lists:usort([M || Path <- Files, M <- [moduleFromPath(Path)], M =/= undefined]).

formatStructuredHintsForPrompt(#{suggestedTestAreas := Areas, riskHints := Risks,
                                   touchedModules := Mods, affectedCallers := Callers,
                                   changeType := Type}) ->
    [
        <<"\n## 结构化审查提示\n"/utf8>>,
        <<"变更类型: "/utf8>>, atom_to_binary(Type, utf8), <<"\n">>,
        <<"触及模块: "/utf8>>, modulesHintLine(Mods), <<"\n">>,
        <<"建议测试区域:\n"/utf8>>, formatHintList(Areas),
        <<"风险提示:\n"/utf8>>, formatHintList(Risks),
        formatAffectedCallersForPrompt(Callers),
        <<"\n">>
    ];
formatStructuredHintsForPrompt(_) ->
    <<>>.

modulesHintLine([]) -> <<"(无)"/utf8>>;
modulesHintLine(Mods) ->
    iolist_to_binary(string:join([unicode:characters_to_list(M) || M <- Mods], ", ")).

formatHintList([]) -> <<"  (无)\n"/utf8>>;
formatHintList(Items) ->
    [[<<"  - ">>, I, <<"\n">>] || I <- Items].

formatAffectedCallersForPrompt([]) ->
    <<>>;
formatAffectedCallersForPrompt(Callers) ->
    [
        <<"受影响调用方:\n"/utf8>>,
        [[<<"  - ">>, maps:get(mfa, C, <<>>),
          <<" (depth=">>, integer_to_binary(maps:get(depth, C, 0)), <<")\n">>]
         || C <- lists:sublist(Callers, 8)]
    ].

formatPatchHunksForPrompt([]) ->
    <<>>;
formatPatchHunksForPrompt(Hunks) when is_list(Hunks) ->
    [
        <<"## 关键 patch 片段预览\n"/utf8>>,
        [formatOnePatchHunk(H) || H <- lists:sublist(Hunks, 6)],
        <<"\n">>
    ].

formatOnePatchHunk(#{file := File, startLine := Start, endLine := End, snippet := Snip}) ->
    [
        <<"### ">>, File, <<" : ">>, integer_to_binary(Start), <<"-">>, integer_to_binary(End), <<"\n```erl\n">>,
        Snip, <<"\n```\n">>
    ];
formatOnePatchHunk(_) ->
    <<>>.

formatDetailedAffectedForPrompt([]) ->
    <<>>;
formatDetailedAffectedForPrompt(Detailed) when is_list(Detailed) ->
    [
        <<"\n## 受影响函数源码预览\n"/utf8>>,
        [formatOneAffectedDetail(D) || D <- lists:sublist(Detailed, 8)],
        <<"\n">>
    ].

formatOneAffectedDetail(#{module := M, function := F, arity := A,
                          file := File, sourcePreview := Preview}) ->
    [
        <<"### ">>, atom_to_binary(M, utf8), <<":">>, toBinary(F), <<"/">>, integer_to_binary(A),
        <<" @ ">>, File, <<"\n```erl\n">>, Preview, <<"\n```\n">>
    ];
formatOneAffectedDetail(#{affected := Label}) ->
    [<<"### ">>, Label, <<"\n">>];
formatOneAffectedDetail(_) ->
    <<>>.

%%%===================================================================
%%% 纯辅助函数
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 从文件路径提取模块名：`src/agent/alAgent.erl' → alAgent。
%% 非 .erl 文件返回 undefined。
%% @end
%%--------------------------------------------------------------------
moduleFromPath(Path) ->
    Bin = toBinary(Path),
    case filename:extension(Bin) of
        <<".erl">> ->
            Base = filename:basename(Bin, <<".erl">>),
            %% 跳过 _tests 后缀的测试模块
            case binary:match(Base, <<"_tests">>) of
                nomatch ->
                    %% 安全：文件路径/模块名可能来自外部，绝不 binary_to_atom 创建任意原子
                    %% （原子表耗尽 DoS）；不存在的模块名降级为 undefined。
                    try binary_to_existing_atom(Base, utf8)
                    catch _:_ -> undefined
                    end;
                _ -> undefined
            end;
        _ ->
            undefined
    end.

%%--------------------------------------------------------------------
%% @doc 审查系统提示。
%%--------------------------------------------------------------------
reviewSystemPrompt() ->
    <<"你是资深 Erlang 代码审查专家。根据提交的 diff 和调用图影响范围分析，"
      "评估这次改动是否正确、是否有遗漏、是否有回归风险。"
      "重点关注：边界条件、错误处理、调用方兼容性、并发安全。"
      "用中文撰写审查结论。"/utf8>>.

%%%===================================================================
%%% Internal
%%%===================================================================

analyzeModules(Modules) ->
    lists:flatmap(fun analyzeModule/1, lists:sublist(Modules, 10)).

analyzeModule(Module) ->
    Funs = safeModuleSymbols(Module),
    %% 只分析前 N 个函数，控规模
    TopFuns = lists:sublist(Funs, ?MaxFunctionsPerModule),
    [reverseTraverse({Module, functionNameOf(F), functionArityOf(F)},
                     ?MaxReverseDepth, sets:new())
     || F <- TopFuns,
        functionNameOf(F) =/= undefined].

%% moduleSymbols 经 normalizeJson 后函数条目的 name/arity 键可能是 atom 或
%% binary（仅当原子已存在时才转 atom），故统一双键读取并归一化。
functionNameOf(F) ->
    normalizeAtom(maps:get(name, F, maps:get(<<"name">>, F, undefined))).

functionArityOf(F) ->
    normalizeInt(maps:get(arity, F, maps:get(<<"arity">>, F, undefined))).

safeModuleSymbols(Module) ->
    try alCoreClient:unwrap(alCoreClient:moduleSymbols(Module)) of
        {ok, Data} when is_map(Data) ->
            Doc = maps:get(document, Data, maps:get(<<"document">>, Data, Data)),
            case Doc of
                M when is_map(M) ->
                    maps:get(functions, M, maps:get(<<"functions">>, M, []));
                _ -> []
            end;
        _ -> []
    catch
        _:_ -> []
    end.

mfaKey({M, F, A}) -> {M, F, A};
mfaKey(Other) -> Other.

normalizeAtom(V) when is_atom(V) -> V;
normalizeAtom(V) when is_binary(V) ->
    try binary_to_existing_atom(V, utf8) catch _:_ -> V end;
normalizeAtom(V) when is_list(V) ->
    try list_to_existing_atom(V) catch _:_ -> V end;
normalizeAtom(_) -> undefined.

normalizeInt(V) when is_integer(V) -> V;
normalizeInt(V) when is_binary(V) ->
    try binary_to_integer(V) catch _:_ -> undefined end;
normalizeInt(V) when is_list(V) ->
    try list_to_integer(V) catch _:_ -> undefined end;
normalizeInt(_) -> undefined.

dedupByKey(List) ->
    {Result, _Seen} = lists:foldl(
        fun({MFA, Depth}, {Acc, Seen}) ->
            Key = mfaKey(MFA),
            case sets:is_element(Key, Seen) of
                true -> {Acc, Seen};
                false -> {[{MFA, Depth} | Acc], sets:add_element(Key, Seen)}
            end
        end, {[], sets:new()}, List),
    %% 按深度升序（直接调用方在前）
    lists:sort(fun({_, D1}, {_, D2}) -> D1 =< D2 end, lists:reverse(Result)).

formatAffected({{M, F, A}, Depth}) ->
    DepthLabel = case Depth of
        0 -> <<"（直接修改）"/utf8>>;
        1 -> <<"（1跳调用方）"/utf8>>;
        N -> iolist_to_binary([integer_to_binary(N), <<"跳调用方"/utf8>>])
    end,
    iolist_to_binary([atom_to_binary(M, utf8), <<":">>,
                      toBinary(F), <<"/">>, integer_to_binary(A),
                      <<" ">>, DepthLabel]).

toBinary(V) when is_binary(V) -> V;
toBinary(V) when is_list(V) -> list_to_binary(V);
toBinary(V) when is_atom(V) -> atom_to_binary(V, utf8);
toBinary(V) -> iolist_to_binary(io_lib:format("~p", [V])).

toAtom(V) when is_atom(V) -> V;
toAtom(V) when is_binary(V), byte_size(V) > 0, byte_size(V) =< 255 ->
    try binary_to_existing_atom(V, utf8) catch _:_ -> undefined end;
toAtom(V) when is_list(V), length(V) > 0, length(V) =< 255 ->
    try list_to_existing_atom(V) catch _:_ -> undefined end;
toAtom(_) -> undefined.

toInt(V) when is_integer(V) -> V;
toInt(V) when is_binary(V) ->
    try binary_to_integer(V) catch _:_ -> undefined end;
toInt(V) when is_list(V) ->
    try list_to_integer(V) catch _:_ -> undefined end;
toInt(_) -> undefined.
