%%%-------------------------------------------------------------------
%%% @doc Agent 工具权限策略模块。
%%%
%%% 定义各内置工具的风险等级（只读 / 安全执行 / 高风险执行 / 写操作），
%%% 结合策略 map 与运行模式（ask / edit / exec）判断是否允许调用，
%%% 以及是否需要用户确认。同时提供审计日志用的敏感信息脱敏函数。
%%% @end
%%%-------------------------------------------------------------------
-module(alPolicy).

-export([
    defaultPolicy/0,
    level/1,
    requiresConfirmation/2,
    checkTool/2,
    checkTool/3,
    sanitizeTerm/1
]).

-type level() :: read | executeSafe | executeRisky | write.
-type policy() :: #{
    allowRead => boolean(),
    allowExecuteSafe => boolean(),
    allowExecuteRisky => boolean(),
    allowWrite => boolean(),
    requireWriteConfirmation => boolean(),
    requireRiskyConfirmation => boolean()
}.

-define(DEFAULT_POLICY, #{
    allowRead => true,
    allowExecuteSafe => true,
    allowExecuteRisky => false,
    allowWrite => false,
    requireWriteConfirmation => true,
    requireRiskyConfirmation => true
}).

%% @doc 返回默认权限策略。
%% 默认允许只读与安全执行，禁止高风险执行与写操作；
%% 写操作与高风险操作需用户确认。
%% @returns `{policy()}`
-spec defaultPolicy() -> policy().
defaultPolicy() ->
    ?DEFAULT_POLICY.

%% @doc 查询内置工具的风险等级。
%% 未列出的工具默认归为 executeRisky。
%% @param Tool 工具原子名
%% @returns `{level()}` read | executeSafe | executeRisky | write
-spec level(atom()) -> level().
level(readFile) -> read;
level(listFiles) -> read;
level(searchText) -> read;
level(projectIndex) -> read;
level(codeIndex) -> read;
level(searchCodeIndex) -> read;
level(getFunctionSource) -> read;
level(analyzeCalls) -> read;
level(findCallers) -> read;
level(getBeamAbstract) -> read;
level(analyzeBehaviours) -> read;
level(moduleDependencies) -> read;
level(dependencyGraph) -> read;
level(analyzeCallGraph) -> read;
level(codeQuality) -> read;
level(getAppInfo) -> read;
level(getSupTree) -> read;
level(etopSummary) -> read;
level(loadedApplications) -> read;
level(loadedModules) -> read;
level(moduleExports) -> read;
level(registeredProcesses) -> read;
level(processList) -> read;
level(processInfo) -> read;
level(nodeInfo) -> read;
level(agentConfig) -> read;
level(runtimeSummary) -> read;
level(remoteNodeInfo) -> read;
level(callFunction) -> executeSafe;
level(runEunit) -> executeSafe;
level(runCommonTest) -> executeSafe;
level(generateEunit) -> write;
level(generateCommonTest) -> write;
level(listTestModules) -> read;
level(compileLoad) -> executeRisky;
level(rollbackFile) -> write;
level(listBackups) -> read;
level(writeFile) -> write;
level(patchFile) -> write;
level(formatCode) -> write;
level(_) -> executeRisky.

%% @doc 判断指定工具在当前策略下是否需要用户确认。
%% 写操作看 requireWriteConfirmation，高风险看 requireRiskyConfirmation；
%% 只读与安全执行不需要确认。
%% @param Tool 工具原子名
%% @param Policy 权限策略 map
%% @returns `{boolean()}`
-spec requiresConfirmation(atom(), policy()) -> boolean().
requiresConfirmation(Tool, Policy) ->
    case level(Tool) of
        write ->
            maps:get(requireWriteConfirmation, Policy, true);
        executeRisky ->
            maps:get(requireRiskyConfirmation, Policy, true);
        executeSafe ->
            false;
        read ->
            false
    end.

%% @doc 检查工具是否允许调用（无额外上下文，等同 checkTool/3 传入空 map）。
%% @param Tool 工具原子名
%% @param Policy 权限策略 map
%% @returns `ok` 或 `{error, denied}`
-spec checkTool(atom(), policy()) -> ok | {error, denied}.
checkTool(Tool, Policy) ->
    checkTool(Tool, Policy, #{}).

%% @doc 综合策略、运行模式与确认状态检查工具调用是否被允许。
%% Context 可含 mode（ask/edit/exec）、confirmed（是否已获用户确认）。
%% @param Tool 工具原子名
%% @param Policy 权限策略 map
%% @param Context 运行时上下文 map
%% @returns `ok` | `{error, denied}` | `{error, confirmationRequired}`
-spec checkTool(atom(), policy(), map()) ->
    ok | {error, denied | confirmationRequired}.
checkTool(Tool, Policy, Context) ->
    Mode = maps:get(mode, Context, ask),
    Level = level(Tool),
    case mode_allows(Mode, Level) of
        false -> {error, denied};
        true ->
            Allowed = case Level of
                read -> maps:get(allowRead, Policy, true);
                executeSafe -> maps:get(allowExecuteSafe, Policy, true);
                executeRisky -> maps:get(allowExecuteRisky, Policy, false);
                write -> maps:get(allowWrite, Policy, false)
            end,
            case Allowed of
                false -> {error, denied};
                true ->
                    Confirmed = maps:get(confirmed, Context, false),
                    NeedsConfirm = requiresConfirmation(Tool, Policy),
                    case Confirmed of
                        true -> ok;
                        false when NeedsConfirm -> {error, confirmationRequired};
                        false -> ok
                    end
            end
    end.

%% 判断运行模式是否允许该风险等级的工具（ask 仅只读+安全执行，edit 含写操作等）
mode_allows(ask, read) -> true;
mode_allows(ask, executeSafe) -> true;
mode_allows(ask, _) -> false;
mode_allows(edit, read) -> true;
mode_allows(edit, executeSafe) -> true;
mode_allows(edit, write) -> true;
mode_allows(edit, executeRisky) -> false;
mode_allows(exec, _) -> true;
mode_allows(_, _) -> true.

%% @doc 递归脱敏 term，将含敏感关键字的字符串替换为 `***REDACTED***`。
%% 用于审计日志，避免 api_key、password、token 等泄露。
%% @param Term 任意 Erlang term（map、list、binary 等）
%% @returns 脱敏后的 term，结构与输入相同
-spec sanitizeTerm(term()) -> term().
sanitizeTerm(Term) when is_map(Term) ->
    maps:fold(fun(K, V, Acc) ->
        maps:put(K, sanitizeTerm(V), Acc)
    end, #{}, Term);
sanitizeTerm(Term) when is_list(Term) ->
    case io_lib:printable_unicode_list(Term) of
        true ->
            sanitizeString(unicode:characters_to_binary(Term));
        false ->
            [sanitizeTerm(X) || X <- Term]
    end;
sanitizeTerm(Term) when is_binary(Term) ->
    sanitizeString(Term);
sanitizeTerm(Term) ->
    Term.

%% 对单个二进制字符串检测敏感关键字并脱敏
sanitizeString(Bin) ->
    Lower = string:lowercase(binary_to_list(Bin)),
    case isSensitiveKey(Lower) of
        true -> <<"***REDACTED***"/utf8>>;
        false -> Bin
    end.

%% 判断字符串是否包含 api_key、password、secret、token 等敏感子串
isSensitiveKey(S) ->
    lists:any(fun(Prefix) -> string:str(S, Prefix) > 0 end,
              ["api_key", "apikey", "password", "secret", "token", "authorization"]).