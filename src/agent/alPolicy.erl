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
level(topProcesses) -> read;
level(schedulerInfo) -> read;
level(etsTables) -> read;
level(gitStatus) -> read;
level(gitDiff) -> read;
level(gitLog) -> read;
level(gitBranch) -> read;
level(svnStatus) -> read;
level(svnDiff) -> read;
level(svnLog) -> read;
level(svnInfo) -> read;
level(searchCode) -> read;
level(semanticSearch) -> read;
level(planSet) -> read;
level(planUpdate) -> read;
level(planGet) -> read;
level(callFunction) -> executeRisky;
level(runEunit) -> executeSafe;
level(runCommonTest) -> executeSafe;
level(generateEunit) -> write;
level(generateCommonTest) -> write;
level(listTestModules) -> read;
level(compileLoad) -> write;
level(rollbackFile) -> write;
level(sessionUndo) -> write;
level(listBackups) -> read;
level(writeFile) -> write;
level(patchFile) -> write;
level(formatCode) -> write;
%% 未列出的工具：先查自定义工具注册表，缺省按高风险处理。
level(Tool) -> alTools:customToolLevel(Tool).

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

%% @doc 递归脱敏 term：仅根据<b>键名</b>判断是否脱敏值，
%% 不扫描 value 内容，避免误杀含 "token" 等普通关键词的合法数据。
%% 用于审计日志，避免 api_key、password、token 等泄露。
%% @param Term 任意 Erlang term（map、list、binary 等）
%% @returns 脱敏后的 term，结构与输入相同
-spec sanitizeTerm(term()) -> term().
sanitizeTerm(Term) when is_map(Term) ->
    maps:fold(fun(K, V, Acc) ->
        case isSensitiveKeyName(K) of
            true ->
                %% 键名匹配到敏感词 → 值整体脱敏（不递归进入）
                maps:put(K, <<"***REDACTED***"/utf8>>, Acc);
            false ->
                %% 键名安全 → 递归处理嵌套结构
                maps:put(K, sanitizeTerm(V), Acc)
        end
    end, #{}, Term);
sanitizeTerm(Term) when is_list(Term) ->
    case io_lib:printable_unicode_list(Term) of
        true ->
            %% 纯文本列表（如 JSON 字符串值）：键名已在 map fold 环节判断，
            %% 此处从键名安全进入，不扫描内容
            unicode:characters_to_binary(Term);
        false ->
            [sanitizeTerm(X) || X <- Term]
    end;
sanitizeTerm(Term) ->
    Term.

%% 判断 map 的键名（atom 或 binary）是否为敏感字段名。
%% 匹配 api_key、password、secret、token、authorization 及其变体。
isSensitiveKeyName(K) when is_atom(K) ->
    Lower = string:lowercase(atom_to_list(K)),
    lists:any(fun(Prefix) -> string:str(Lower, Prefix) > 0 end,
              ["api_key", "apikey", "password", "secret", "token", "authorization"]);
isSensitiveKeyName(K) when is_binary(K) ->
    Lower = string:lowercase(binary_to_list(K)),
    lists:any(fun(Prefix) -> string:str(Lower, Prefix) > 0 end,
              ["api_key", "apikey", "password", "secret", "token", "authorization"]);
isSensitiveKeyName(_) ->
    false.