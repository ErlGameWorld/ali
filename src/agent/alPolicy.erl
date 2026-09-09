%%%-------------------------------------------------------------------
%% @doc 工具执行的风险分级与策略强制。
%%
%% 四级风险：read | executeSafe | executeRisky | write。
%% 模式矩阵：ask（read+executeSafe+executeRisky）、edit（+write）、exec（全部）、
%% plan（仅 read+executeSafe；强制用 todo/plan 规划，禁写与高风险执行）。
%% {@link sanitizeTerm/1} 会脱敏敏感键（apiKey/password 等）。
%% @end
%%%-------------------------------------------------------------------

-module(alPolicy).

-export([defaultPolicy/0, policyForMode/1, level/1, effectiveLevel/2, modeAllows/2,
         checkTool/3, requiresConfirmation/2, requiresConfirmation/3, sanitizeTerm/1,
         isRunMfaWrite/1]).

-export_type([level/0, mode/0]).
-type level() :: read | executeSafe | executeRisky | write | denied.
-type mode() :: ask | edit | exec | plan.

-define(REDACTED, <<"***REDACTED***">>).

%%--------------------------------------------------------------------
%% @doc
%% 返回默认策略：对话可执行白名单/策略允许的 MFA（查业务数据、进程等）；
%% 写文件仍默认关闭。默认不弹二次确认（网页审批已关掉）；需要时可在 cfg 打开。
defaultPolicy() ->
    #{
        allowRead => true,
        allowExecuteSafe => true,
        allowExecuteRisky => true,
        allowWrite => false,
        %% 默认关闭审批闸门：写类工具（含 runMfa 写意图）直接执行
        requireConfirmationWrite => false,
        requireConfirmationRisky => false
    }.

%%--------------------------------------------------------------------
%% @doc
%% 按会话模式合成策略：ask 保持默认；edit 开放写文件；exec 再确保可跑 risky；
%% plan 仅允许读 + 安全执行（todo/plan），禁止写与高风险执行。
%% @end
%%--------------------------------------------------------------------
-spec policyForMode(mode()) -> map().
policyForMode(ask) ->
    defaultPolicy();
policyForMode(edit) ->
    maps:merge(defaultPolicy(), #{allowWrite => true});
policyForMode(exec) ->
    maps:merge(defaultPolicy(), #{
        allowWrite => true,
        allowExecuteRisky => true
    });
policyForMode(plan) ->
    maps:merge(defaultPolicy(), #{
        allowWrite => false,
        allowExecuteRisky => false,
        allowExecuteSafe => true,
        allowRead => true
    });
policyForMode(_) ->
    defaultPolicy().

%%%===================================================================
%%% Risk level classification
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 将工具名映射到风险等级（read | executeSafe | executeRisky | write | denied）。
%% 未知工具默认归为 denied（defense in depth：alToolRouter 应已拒绝未注册工具，
%% 这里兜底防止未知工具名穿透到执行路径）。
%%
%% @param Tool 工具名原子
%% @return 风险等级原子
%% @end
%%--------------------------------------------------------------------
level(indexCode) -> read;
level(projectDigest) -> executeSafe;
level(searchKnowledge) -> read;
level(saveKnowledge) -> write;
level(saveAction) -> write;
level(lookupAction) -> read;
level(digestStatus) -> read;
level(searchCode) -> read;
level(searchText) -> read;
level(getSymbol) -> read;
level(coreHealth) -> read;
level(coreStatus) -> read;
level(findCallers) -> read;
level(findCallees) -> read;
level(getCallers) -> read;
level(getCallees) -> read;
level(traceDataQuery) -> read;
level(dataSources) -> read;
level(dataSourceCallers) -> read;
level(paramSources) -> read;
level(traceDataFlow) -> read;
level(callGraph) -> read;
level(moduleDeps) -> read;
level(generateModuleDoc) -> read;
level(batchRefactor) -> write;
level(embeddingSchema) -> read;
level(moduleSymbols) -> read;
level(resolveModule) -> read;
level(gotoDef) -> read;
level(findRefs) -> read;
level(getSymbolSource) -> read;
level(getBeamAbstract) -> read;
level(moduleExports) -> read;
level(semanticSearch) -> read;
level(getRuntime) -> read;
level(supervisorTree) -> read;
level(getProcesses) -> read;
level(processInfo) -> read;
level(etsLookup) -> read;
level(getEts) -> read;
level(recall) -> read;
level(recallSemantic) -> read;
level(searchMemory) -> read;
level(remember) -> write;
level(saveLesson) -> write;
level(correctLesson) -> write;
level(recallExperience) -> read;
level(dbQuery) -> read;
level(simulate) -> executeSafe;
level(dryRunPatch) -> executeSafe;
level(validatePatch) -> read;
level(verifyCompile) -> executeSafe;
level(genTest) -> read;
level(webSearch) -> read;
level(functionHistory) -> read;
level(lastCommit) -> read;
level(commitDiff) -> read;
level(commitFiles) -> read;
level(searchCommits) -> read;
level(dailyReview) -> read;
level(recentCommits) -> read;
level(gitIndex) -> executeSafe;
level(vcsIndex) -> executeSafe;
level(hotReload) -> executeRisky;
level(refactor) -> write;
level(getOldCodeProcesses) -> read;
level(getModuleTypes) -> read;
level(reviewPackage) -> read;
level(reviewChangeImpact) -> executeRisky;
level(rollbackPatch) -> write;
level(applyPatchBatch) -> write;
level(planSet) -> executeSafe;
level(planGet) -> read;
level(planUpdate) -> executeSafe;
level(planClear) -> executeSafe;
level(todoWrite) -> executeSafe;
level(todoRead) -> read;
level(todoUpdate) -> executeSafe;
level(todoClear) -> executeSafe;
level(delegateTo) -> executeSafe;
level(useSkill) -> read;
level(fetchUrl) -> executeSafe;
level(subagent) -> executeSafe;
level(readFile) -> read;
level(listFiles) -> read;
level(search) -> read;
level(formatCode) -> read;
level(runEunit) -> executeSafe;
level(runDialyzer) -> executeSafe;
level(indexStatus) -> read;
level(searchUnified) -> read;
level(applyPatch) -> write;
level(writeFile) -> write;
level(runMfa) -> executeRisky;
level(evalErl) -> executeRisky;
level(execute) -> executeRisky;
level(refreshIndex) -> executeSafe;
level(saveMemory) -> write;
%% 以下工具曾依赖 catch-all（executeRisky）隐式放行；改 catch-all 为 denied
%% 前必须显式归类，否则会在 ask 模式下被误拒。
level(appTopology) -> read;
level(contextPreview) -> read;
level(memoryDistill) -> write;
level(specIndex) -> read;
level(specSearch) -> read;
level(runTestsForPatch) -> executeSafe;
level(_) -> denied.

%%--------------------------------------------------------------------
%% @doc
%% 计算工具在给定参数下的实际风险等级。
%%
%% dbQuery 的风险等级基于 **SQL 语句内容** 判定，而非 LLM 自报的 mode：
%% 只读语句（SELECT/EXPLAIN/PRAGMA 等）归为 read，其余（含写/DDL/多语句/
%% WITH...DELETE）一律提升为 write。这样即使模型谎报 `mode => read`，
%% 写语句仍会走 write 审批路径。
%%
%% @param Tool 工具名
%% @param Args 参数映射
%% @return 风险等级原子
%% @end
%%--------------------------------------------------------------------
effectiveLevel(dbQuery, Args) when is_map(Args) ->
    case sqlIsReadOnly(extractSql(Args)) of
        true -> read;
        false -> write
    end;
effectiveLevel(Tool, _Args) -> level(Tool).

%%--------------------------------------------------------------------
%% @doc
%% 判断 runMfa 是否为写意图。不信任 LLM 自报的 sideEffect=read（易被绕过）：
%% 仅当函数名明确匹配只读前缀（get/lookup/query/count/list/find/fetch/read/is_）
%% 才视为 read（false）；否则一律视为 write（true）。
%% @end
%%--------------------------------------------------------------------
-spec isRunMfaWrite(map()) -> boolean().
isRunMfaWrite(Args) when is_map(Args) ->
    Fun = runMfaFunName(Args),
    case looksLikeReadFun(Fun) of
        true -> false;
        false -> true
    end;
isRunMfaWrite(_) -> false.

%% 只读前缀匹配：函数名以这些前缀开头视为只读查询。
looksLikeReadFun(<<>>) -> false;
looksLikeReadFun(Fun) when is_binary(Fun) ->
    Prefixes = [
        <<"get">>, <<"lookup">>, <<"query">>, <<"count">>,
        <<"list">>, <<"find">>, <<"fetch">>, <<"read">>, <<"is_">>
    ],
    lists:any(fun(P) -> string:prefix(Fun, P) =/= nomatch end, Prefixes);
looksLikeReadFun(_) -> false.

runMfaFunName(Args) ->
    case maps:get(function, Args, maps:get(<<"function">>, Args, undefined)) of
        undefined ->
            case maps:get(call, Args, maps:get(<<"call">>, Args, <<>>)) of
                Call when is_binary(Call); is_list(Call) ->
                    extractFunFromCall(toBinLower(Call));
                _ -> <<>>
            end;
        Fun -> toBinLower(Fun)
    end.

extractFunFromCall(Call) ->
    %% "Mod:Fun(...)" or "Fun(...)"
    case re:run(Call, <<"(?:^|:)([a-zA-Z_][a-zA-Z0-9_]*)\\s*\\(">>,
                [{capture, [1], binary}]) of
        {match, [Fun]} -> string:lowercase(Fun);
        _ -> <<>>
    end.

toBinLower(A) when is_atom(A) -> string:lowercase(atom_to_binary(A, utf8));
toBinLower(B) when is_binary(B) -> string:lowercase(B);
toBinLower(L) when is_list(L) -> string:lowercase(unicode:characters_to_binary(L));
toBinLower(_) -> <<>>.

%% 从 dbQuery 参数中提取 SQL 文本，兼容 atom / binary 键。
extractSql(Args) ->
    case maps:get(sql, Args, maps:get(<<"sql">>, Args, undefined)) of
        undefined -> undefined;
        Sql -> Sql
    end.

%% 判断 SQL 是否为纯只读语句：无 SQL 或非文本时保守视为写（false）。
%% 去除注释后要求：单条语句、以只读关键字开头、且不含写关键字（防
%% WITH ... DELETE 这类以 with 开头却夹带写操作的语句）。
sqlIsReadOnly(undefined) -> false;
sqlIsReadOnly(Sql) when is_binary(Sql); is_list(Sql) ->
    Norm = normalizeSqlText(Sql),
    case Norm of
        <<>> -> false;
        _ ->
            isSingleStatement(Norm)
                andalso startsWithReadKeyword(Norm)
                andalso (not containsWriteKeyword(Norm))
    end;
sqlIsReadOnly(_) -> false.

%% 归一化 SQL 文本：转 binary、小写、去除行注释、压缩空白并去首尾空白。
normalizeSqlText(Sql) ->
    Bin = case Sql of
        B when is_binary(B) -> B;
        L when is_list(L) -> unicode:characters_to_binary(L)
    end,
    Lower = string:lowercase(Bin),
    NoComments = stripSqlComments(Lower),
    Collapsed = re:replace(NoComments, <<"\\s+">>, <<" ">>, [global, {return, binary}]),
    string:trim(Collapsed).

%% 去除 SQL 行注释（-- 到行尾）；块注释用空格替换以免拼接出新关键字。
stripSqlComments(Bin) ->
    NoLine = re:replace(Bin, <<"--[^\\n]*">>, <<" ">>, [global, {return, binary}]),
    re:replace(NoLine, <<"/\\*.*?\\*/">>, <<" ">>, [global, dotall, {return, binary}]).

%% 判断是否为单条语句：去掉末尾分号后，中间不应再出现分号。
isSingleStatement(Bin) ->
    Trimmed = string:trim(Bin, trailing, ";"),
    Trimmed2 = string:trim(Trimmed),
    binary:match(Trimmed2, <<";">>) =:= nomatch.

%% 是否以只读关键字开头。
startsWithReadKeyword(Bin) ->
    lists:any(
        fun(Prefix) -> string:prefix(Bin, Prefix) =/= nomatch end,
        [<<"select ">>, <<"select\t">>, <<"select(">>,
         <<"explain">>, <<"pragma">>, <<"with ">>, <<"values ">>, <<"show ">>]
    ).

%% 是否含任一写/DDL 关键字（按词边界匹配，避免误伤列名如 updated_at）。
containsWriteKeyword(Bin) ->
    lists:any(
        fun(Kw) ->
            re:run(Bin, <<"\\b", Kw/binary, "\\b">>, [{capture, none}]) =:= match
        end,
        [<<"insert">>, <<"update">>, <<"delete">>, <<"drop">>,
         <<"alter">>, <<"create">>, <<"replace">>, <<"truncate">>,
         <<"merge">>, <<"grant">>, <<"revoke">>, <<"attach">>, <<"detach">>]
    ).

%%%===================================================================
%%% Mode matrix
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 判断当前模式（ask | edit | exec | plan）是否允许执行指定风险等级。
%%
%% @param Mode 模式原子
%% @param Level 风险等级
%% @return boolean()
%% @end
%%--------------------------------------------------------------------
modeAllows(ask, read) -> true;
modeAllows(ask, executeSafe) -> true;
%% ask 允许发起 risky 执行（仍受 allowExecuteRisky / 确认策略约束），
%% 否则对话里无法 runMfa 查业务数据/跑只读 MFA。
modeAllows(ask, executeRisky) -> true;
modeAllows(ask, write) -> false;
modeAllows(edit, read) -> true;
modeAllows(edit, executeSafe) -> true;
modeAllows(edit, executeRisky) -> true;
modeAllows(edit, write) -> true;
modeAllows(exec, _) -> true;
modeAllows(plan, read) -> true;
modeAllows(plan, executeSafe) -> true;
modeAllows(plan, executeRisky) -> false;
modeAllows(plan, write) -> false;
modeAllows(_, _) -> false.

%%%===================================================================
%%% Policy check
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 综合模式、策略与确认状态检查工具是否可执行。
%%
%% @param Tool 工具名
%% @param Policy 策略映射；非映射时使用 defaultPolicy/0
%% @param Context 上下文映射（含 args、mode、confirmed）
%% @return ok | {error, denied} | {error, confirmationRequired}
%% @end
%%--------------------------------------------------------------------
checkTool(Tool, Policy, Context) when is_map(Policy), is_map(Context) ->
    Args = maps:get(args, Context, #{}),
    Level = effectiveLevel(Tool, Args),
    Mode = maps:get(mode, Context, ask),
    case modeAllows(Mode, Level) of
        false ->
            {error, denied};
        true ->
            case policyAllows(Level, Policy) of
                false ->
                    {error, denied};
                true ->
                    case requiresConfirmation(Tool, Policy, Args) andalso
                         not maps:get(confirmed, Context, false) of
                        true ->
                            {error, confirmationRequired};
                        false ->
                            ok
                    end
            end
    end;
checkTool(Tool, _Policy, Context) ->
    checkTool(Tool, defaultPolicy(), Context).

%% 判断策略是否允许执行指定风险等级。
policyAllows(read, #{allowRead := true}) -> true;
policyAllows(executeSafe, #{allowExecuteSafe := true}) -> true;
policyAllows(executeRisky, #{allowExecuteRisky := true}) -> true;
policyAllows(write, #{allowWrite := true}) -> true;
policyAllows(_, _) -> false.

%%--------------------------------------------------------------------
%% @doc
%% 判断工具是否需要用户确认（无参数版本，使用空参数映射）。
%%
%% @param Tool 工具名
%% @param Policy 策略映射
%% @return boolean()
%% @end
%%--------------------------------------------------------------------
requiresConfirmation(Tool, Policy) ->
    requiresConfirmation(Tool, Policy, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 判断工具在给定参数下是否需要用户确认：write 看 requireConfirmationWrite，
%% executeRisky 看 requireConfirmationRisky，其他默认 false。
%%
%% @param Tool 工具名
%% @param Policy 策略映射
%% @param Args 参数映射
%% @return boolean()
%% @end
%%--------------------------------------------------------------------
requiresConfirmation(runMfa, Policy, Args) ->
    %% 查询免确认；写意图仅当策略显式打开 requireConfirmationWrite
    case isRunMfaWrite(Args) of
        true -> maps:get(requireConfirmationWrite, Policy, false);
        false -> false
    end;
requiresConfirmation(Tool, Policy, Args) ->
    Level = effectiveLevel(Tool, Args),
    case Level of
        write -> maps:get(requireConfirmationWrite, Policy, false);
        executeRisky -> maps:get(requireConfirmationRisky, Policy, false);
        _ -> false
    end.

%%%===================================================================
%%% Sanitize sensitive terms
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 递归对映射/列表中的敏感字段（apiKey、password 等）进行脱敏。
%%
%% @param Term 任意 Erlang 项
%% @return 脱敏后的项
%% @end
%%--------------------------------------------------------------------
sanitizeTerm(Term) when is_map(Term) ->
    maps:from_list([{K, sanitizeValue(K, V)} || {K, V} <- maps:to_list(Term)]);
sanitizeTerm(Term) when is_list(Term) ->
    [sanitizeTerm(T) || T <- Term];
sanitizeTerm(Term) ->
    Term.

%% 将键统一转换为小写 binary，并去掉 `_`/`-`，使 `prompt_tokens` 与白名单
%% `prompttokens` 对齐，避免误伤用量/预算类业务键。
sanitizeKey(K) when is_binary(K) -> stripKeyNoise(string:lowercase(K));
sanitizeKey(K) when is_atom(K) -> stripKeyNoise(string:lowercase(atom_to_binary(K, utf8)));
sanitizeKey(K) when is_list(K) ->
    stripKeyNoise(string:lowercase(unicode:characters_to_binary(K)));
sanitizeKey(_) -> <<>>.

stripKeyNoise(Bin) when is_binary(Bin) ->
    << <<C>> || <<C>> <= Bin, C =/= $_, C =/= $- >>.

%% 采用子串匹配：键名（小写后）只要含 key/token/secret/password/
%% credential/auth 任一敏感词即打码。为防误伤，先用白名单排除已知安全键
%% （如 keyboard 含 "key"），命中白名单则不打码。
sanitizeTermKey(K) ->
    Str = sanitizeKey(K),
    case lists:member(Str, safeKeyAllowlist()) of
        true -> false;
        false ->
            lists:any(
                fun(Word) -> binary:match(Str, Word) =/= nomatch end,
                sensitiveKeyWords())
    end.

%% 敏感子串词表：命中即打码。
sensitiveKeyWords() ->
    [<<"key">>, <<"token">>, <<"secret">>,
     <<"password">>, <<"passwd">>, <<"credential">>, <<"auth">>].

%% 安全键白名单：这些键含敏感子串但语义无关，避免误伤。
safeKeyAllowlist() ->
    [<<"keyboard">>, <<"monkey">>, <<"donkey">>, <<"turnkey">>,
     <<"tokenusage">>, <<"maxtokensbudget">>, <<"maxtokens">>,
     <<"prompttokens">>, <<"completiontokens">>, <<"totaltokens">>,
     <<"tokencount">>, <<"tokens">>].

%% 当键为敏感键时返回 ?REDACTED，否则递归脱敏值。
sanitizeValue(K, V) ->
    case sanitizeTermKey(K) of
        true -> ?REDACTED;
        false -> sanitizeTerm(V)
    end.
