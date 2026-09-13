%%%-------------------------------------------------------------------
%% @doc 当前 Erlang 节点的运行时数据采集。
%% @end
%%%-------------------------------------------------------------------

-module(alRuntimeProbe).

-export([snapshot/0, processes/1, etsTables/1, runMfa/4, runMfa/5,
         checkMfaAllowed/3, runApplySafe/4,
         supervisorTree/0, supervisorTree/1,
         processInfo/1, etsLookup/2, etsLookup/3,
         discoverSupervisorRoots/0, isSupervisorName/1,
         oldCodeProcesses/1, oldCodeSummary/0]).

%% MFA 白名单运行时管理 API
-export([
    reloadWhitelist/0,
    addWhitelist/1,
    addWhitelist/3,
    removeWhitelist/1,
    removeWhitelist/3,
    listWhitelist/0,
    clearRuntimeWhitelist/0
]).

-define(RuntimeWlKey, {?MODULE, runtimeWhitelist}).

%%--------------------------------------------------------------------
%% @doc
%% 采集当前 Erlang 节点的运行时快照，包含节点名、进程数、调度器数、内存、
%% reductions、run queue，以及 top N 进程 / ETS 表和 supervisor 树。
%%
%% @return 包含节点运行时各项指标的 map
%% @end
%%--------------------------------------------------------------------
snapshot() ->
    #{
        node => node(),
        processCount => erlang:system_info(process_count),
        processLimit => erlang:system_info(process_limit),
        schedulerCount => erlang:system_info(schedulers_online),
        memory => erlang:memory(),
        reductions => element(1, erlang:statistics(reductions)),
        runQueue => erlang:statistics(run_queue),
        processesTop => processes(10),
        messageQueueTop10 => processes(#{limit => 10, sortBy => messageQueueLen}),
        memoryTop10 => processes(#{limit => 10, sortBy => memory}),
        oldCodeSummary => oldCodeSummary(),
        etsTop => etsTables(10),
        supervisorTree => supervisorTree()
    }.

%%--------------------------------------------------------------------
%% @doc
%% 构建监督树。无参时优先 `ali_sup`，并附带 cfg `supervisorRoots` 中的其它根。
%% @end
%%--------------------------------------------------------------------
supervisorTree() ->
    Extra = case alConfig:get(supervisorRoots, []) of
        L when is_list(L) -> L;
        _ -> []
    end,
    Discovered = discoverSupervisorRoots(),
    Roots0 = lists:usort([ali_sup | Extra ++ Discovered]),
    supervisorTree(#{roots => Roots0}).

%% 自动发现已注册且名为 *_sup / *_supervisor 的监督器。
discoverSupervisorRoots() ->
    try
        [Name || Name <- erlang:registered(),
                 is_atom(Name),
                 isSupervisorName(Name),
                 begin
                     Pid = whereis(Name),
                     Pid =/= undefined andalso isSupervisorPid(Pid)
                 end]
    catch _:_ ->
        []
    end.

isSupervisorName(Name) when is_atom(Name) ->
    S = atom_to_list(Name),
    lists:suffix("_sup", S)
        orelse lists:suffix("_supervisor", S)
        orelse Name =:= ali_sup;
isSupervisorName(_) -> false.

%%--------------------------------------------------------------------
%% @doc
%% 按选项构建监督树。
%% Opts：
%% - `roots` :: [atom()|binary()] 注册名列表；缺省 `[ali_sup]`
%% - `maxDepth` :: non_neg_integer()（默认 8）
%% @end
%%--------------------------------------------------------------------
supervisorTree(Opts) when is_map(Opts) ->
    RootNames = case maps:get(roots, Opts, maps:get(<<"roots">>, Opts, [ali_sup])) of
        L when is_list(L), L =/= [] -> L;
        _ -> [ali_sup]
    end,
    MaxDepth = max(1, toInteger(maps:get(maxDepth, Opts, maps:get(<<"maxDepth">>, Opts, 8)), 8)),
    Trees = lists:filtermap(fun(Name0) ->
        case normalizeAtom(Name0) of
            Name when is_atom(Name) ->
                case whereis(Name) of
                    undefined -> false;
                    Pid -> {true, buildTree(Pid, 0, MaxDepth)}
                end;
            _ -> false
        end
    end, RootNames),
    TreesWithHealth = [T#{health => healthSummary(T)} || T <- Trees],
    Combined = mergeHealth([maps:get(health, T) || T <- TreesWithHealth]),
    #{roots => TreesWithHealth, health => Combined};
supervisorTree(Root) when is_atom(Root); is_binary(Root); is_list(Root) ->
    supervisorTree(#{roots => [Root]}).

%% 兼容入口：默认深度 8
buildTree(Pid, Depth, MaxDepth) when Depth >= MaxDepth ->
    Info = processSnapshot(Pid),
    Status = maps:get(status, Info, undefined),
    #{
        pid => maps:get(pid, Info),
        registeredName => maps:get(registeredName, Info, undefined),
        depth => Depth,
        status => Status,
        children => [],
        nodeCount => 1,
        abnormalCount => abnormalSelf(Status),
        truncated => true
    };
buildTree(Pid, Depth, MaxDepth) ->
    Info = processSnapshot(Pid),
    Status = maps:get(status, Info, undefined),
    Children = [buildTree(Child, Depth + 1, MaxDepth) || Child <- supervisorChildren(Pid)],
    #{
        pid => maps:get(pid, Info),
        registeredName => maps:get(registeredName, Info, undefined),
        depth => Depth,
        status => Status,
        children => Children,
        nodeCount => 1 + lists:sum([maps:get(nodeCount, C, 1) || C <- Children]),
        abnormalCount => abnormalSelf(Status) +
            lists:sum([maps:get(abnormalCount, C, 0) || C <- Children])
    }.

mergeHealth([]) -> emptyHealth();
mergeHealth(List) ->
    lists:foldl(fun(H, Acc) ->
        #{
            totalNodes => maps:get(totalNodes, Acc, 0) + maps:get(totalNodes, H, 0),
            abnormalNodes => maps:get(abnormalNodes, Acc, 0) + maps:get(abnormalNodes, H, 0),
            abnormalPids => maps:get(abnormalPids, Acc, []) ++ maps:get(abnormalPids, H, []),
            healthy => maps:get(healthy, Acc, true) andalso maps:get(healthy, H, true)
        }
    end, emptyHealth(), List).

%%--------------------------------------------------------------------
%% @doc
%% 深潜单个进程：支持 pid 字符串 / 注册名。含 links/monitors/heap 等。
%% @end
%%--------------------------------------------------------------------
processInfo(Target) ->
    case resolvePid(Target) of
        {ok, Pid} ->
            Keys = [registered_name, current_function, initial_call, status,
                    message_queue_len, memory, reductions, heap_size, stack_size,
                    total_heap_size, links, monitors, monitored_by, trap_exit,
                    priority, group_leader, dictionary],
            Info0 = maps:from_list([{Key, valueOrUndefined(process_info(Pid, Key))} || Key <- Keys]),
            Dict = maps:get(dictionary, Info0, []),
            SafeDict = case is_list(Dict) of
                true -> lists:sublist([{K, inspect(V)} || {K, V} <- Dict], 40);
                false -> []
            end,
            {ok, Info0#{
                pid => pid_to_list(Pid),
                links => [pid_to_list(P) || P <- ensureList(maps:get(links, Info0, [])), is_pid(P)],
                monitors => inspect(maps:get(monitors, Info0, [])),
                monitoredBy => [pid_to_list(P) || P <- ensureList(maps:get(monitored_by, Info0, [])), is_pid(P)],
                dictionary => SafeDict,
                dictionaryTruncated => is_list(Dict) andalso length(Dict) > 40
            }};
        {error, Reason} ->
            {error, Reason}
    end.

%%--------------------------------------------------------------------
%% @doc ETS 表 lookup（限条数），表可为 atom/tid。
%% @end
%%--------------------------------------------------------------------
etsLookup(Table, Key) ->
    etsLookup(Table, Key, 20).

etsLookup(Table0, Key, Limit0) ->
    Limit = max(1, min(200, toInteger(Limit0, 20))),
    case resolveEtsTable(Table0) of
        {error, _} = E -> E;
        {ok, Tab} ->
            case etsBlocked(Tab) of
                true -> {error, #{reason => etsBlocked, table => inspect(Tab)}};
                false ->
                    try
                        Rows = case ets:lookup(Tab, Key) of
                            L when is_list(L) -> lists:sublist(L, Limit);
                            Other -> [Other]
                        end,
                        {ok, #{
                            table => etsSnapshot(Tab),
                            key => inspect(Key),
                            count => length(Rows),
                            rows => [inspect(R) || R <- Rows],
                            truncated => length(Rows) >= Limit
                        }}
                    catch
                        Class:Reason:Stack ->
                            {error, #{reason => etsLookupFailed, class => Class,
                                      detail => Reason, stack => lists:sublist(Stack, 4)}}
                    end
            end
    end.

resolvePid(Pid) when is_pid(Pid) -> {ok, Pid};
resolvePid(List) when is_list(List) ->
    try list_to_pid(List) of
        Pid -> {ok, Pid}
    catch _:_ ->
        case whereis(list_to_existing_atom_safe(List)) of
            undefined -> {error, #{reason => badPid, input => List}};
            Pid -> {ok, Pid}
        end
    end;
resolvePid(Bin) when is_binary(Bin) ->
    resolvePid(binary_to_list(Bin));
resolvePid(Name) when is_atom(Name) ->
    case whereis(Name) of
        undefined -> {error, #{reason => notRegistered, name => Name}};
        Pid -> {ok, Pid}
    end;
resolvePid(Other) ->
    {error, #{reason => badPid, input => inspect(Other)}}.

list_to_existing_atom_safe(List) ->
    %% 绝不 list_to_atom：LLM/外部输入可耗尽原子表
    try list_to_existing_atom(List) catch _:_ -> undefined end.

resolveEtsTable(Tab) when is_atom(Tab); is_reference(Tab); is_integer(Tab) ->
    case ets:info(Tab, name) of
        undefined -> {error, #{reason => etsNotFound, table => Tab}};
        _ -> {ok, Tab}
    end;
resolveEtsTable(Name) when is_binary(Name); is_list(Name) ->
    Atom = normalizeAtom(Name),
    case is_atom(Atom) andalso ets:info(Atom, name) =/= undefined of
        true -> {ok, Atom};
        false -> {error, #{reason => etsNotFound, table => Name}}
    end;
resolveEtsTable(Other) ->
    {error, #{reason => badEtsTable, table => inspect(Other)}}.

ensureList(L) when is_list(L) -> L;
ensureList(_) -> [].

%% 自身状态是否记为异常（用于聚合）：running / waiting 视为正常。
abnormalSelf(running) -> 0;
abnormalSelf(waiting) -> 0;
abnormalSelf(_) -> 1.

%% 把整棵树的健康概况压缩为单层 map，供 UI 一眼看出异常节点。
healthSummary(Root) ->
    Abnormals = collectAbnormals(Root, []),
    #{
        totalNodes => maps:get(nodeCount, Root, 1),
        abnormalNodes => maps:get(abnormalCount, Root, 0),
        abnormalPids => Abnormals,
        healthy => Abnormals =:= []
    }.

%% 深度优先收集 status 异常节点（注册名 + 状态 + pid）。
collectAbnormals(Node, Acc) ->
    Status = maps:get(status, Node, undefined),
    Self = case abnormalSelf(Status) of
        1 ->
            [#{
                pid => maps:get(pid, Node),
                registeredName => maps:get(registeredName, Node, undefined),
                status => Status
            } | Acc];
        _ -> Acc
    end,
    Children = maps:get(children, Node, []),
    lists:foldl(fun collectAbnormals/2, Self, Children).

%% 空树占位的 health summary。
emptyHealth() ->
    #{totalNodes => 0, abnormalNodes => 0, abnormalPids => [], healthy => true}.

%% 获取监督器的子进程 pid 列表：非监督器返回 []；监督器调用 which_children 并提取 pid。
supervisorChildren(Pid) ->
    case isSupervisorPid(Pid) of
        false ->
            [];
        true ->
            try supervisor:which_children(Pid) of
                Children when is_list(Children) ->
                    [ChildPid || {_Id, ChildPid, _Type, _Modules} <- Children, is_pid(ChildPid)];
                _ ->
                    []
            catch
                _:_ -> []
            end
    end.

%% Avoid sending which_children to plain gen_servers (crashes them).
%% 判断 pid 是否为 supervisor 进程：通过进程字典的 $initial_call 或 initial_call 判断，
%% 避免向普通 gen_server 发送 which_children 导致崩溃。
isSupervisorPid(Pid) when is_pid(Pid) ->
    case erlang:process_info(Pid, dictionary) of
        {dictionary, Dict} ->
            case lists:keyfind('$initial_call', 1, Dict) of
                {'$initial_call', {supervisor, _, _}} -> true;
                {'$initial_call', {supervisor3, _, _}} -> true;
                _ ->
                    case erlang:process_info(Pid, initial_call) of
                        {initial_call, {supervisor, _, _}} -> true;
                        _ -> false
                    end
            end;
        _ ->
            false
    end;
%% 非 pid 输入一律视为非监督器。
isSupervisorPid(_) ->
    false.

%%--------------------------------------------------------------------
%% @doc
%% 列出当前节点进程快照。
%%  - Limit0 = 整数/binary/list：按内存降序返回前 Limit 个（兼容旧调用）。
%%  - Limit0 = map：支持 sortBy / minMessageQueueLen / limit 选项。
%%    sortBy: memory | messageQueueLen | reductions （默认 memory）
%%    minMessageQueueLen: 进程消息队列长度下限（默认 0，0 表示不过滤）
%%    limit: 返回数量上限（默认 20）
%%
%% @param Limit0 数量上限或选项 map
%% @return 进程信息 map 的列表（按指定键降序）
%% @end
%%--------------------------------------------------------------------
processes(Limit0) when is_integer(Limit0) ->
    processesOpts(#{limit => Limit0});
processes(Limit0) when is_map(Limit0) ->
    processesOpts(Limit0);
processes(Limit0) ->
    processesOpts(#{limit => Limit0}).

processesOpts(Opts) ->
    Limit = max(1, toInteger(maps:get(limit, Opts, 20), 20)),
    SortKey = normalizeSortKey(maps:get(sortBy, Opts, memory)),
    MinQLen = max(0, toInteger(maps:get(minMessageQueueLen, Opts, 0), 0)),
    All = [processSnapshot(Pid) || Pid <- erlang:processes()],
    Filtered = case MinQLen of
        0 -> All;
        _ -> [Info || Info <- All,
                     maps:get(messageQueueLen, Info, 0) >= MinQLen]
    end,
    lists:sublist(sortBy(SortKey, Filtered), Limit).

%% 归一化排序键：仅允许 memory/messageQueueLen/reductions，其它回退 memory。
normalizeSortKey(memory) -> memory;
normalizeSortKey(messageQueueLen) -> messageQueueLen;
normalizeSortKey(reductions) -> reductions;
normalizeSortKey(<<"memory">>) -> memory;
normalizeSortKey(<<"messageQueueLen">>) -> messageQueueLen;
normalizeSortKey(<<"reductions">>) -> reductions;
normalizeSortKey(<<"message_queue_len">>) -> messageQueueLen;
normalizeSortKey(_) -> memory.

%%--------------------------------------------------------------------
%% @doc
%% 列出当前节点按内存降序排列的前 Limit 个 ETS 表快照（排除被屏蔽的表）。
%%
%% @param Limit0 数量上限（可为整数、binary 或 list，默认 20）
%% @return 前 Limit 个 ETS 表信息 map 的列表
%% @end
%%--------------------------------------------------------------------
etsTables(Limit0) ->
    Limit = max(1, toInteger(Limit0, 20)),
    Infos = [etsSnapshot(Tab) || Tab <- ets:all(), not etsBlocked(Tab)],
    lists:sublist(sortBy(memory, Infos), Limit).

%%--------------------------------------------------------------------
%% @doc
%% 列出持有旧代码（已被热加载替换但仍有进程引用旧版本）的进程。
%% 遍历所有进程，取 `current_function' / `initial_call' 关联模块，
%% 用 `code:is_module_old/1' 判断；按内存降序返回前 Limit 个。
%%
%% @param Opts0 含 `limit'（默认 50）的 map 或整数
%% @return 进程信息 map 的列表
%% @end
%%--------------------------------------------------------------------
oldCodeProcesses(Opts0) when is_map(Opts0) ->
    Limit = max(1, toInteger(maps:get(limit, Opts0, 50), 50)),
    All = lists:filtermap(fun oldCodeEntry/1, erlang:processes()),
    lists:sublist(sortBy(memory, All), Limit);
oldCodeProcesses(Limit0) ->
    oldCodeProcesses(#{limit => toInteger(Limit0, 50)}).

%%--------------------------------------------------------------------
%% @doc
%% 持有旧代码进程的汇总：总数 + Top 20（按内存降序）。
%% @end
%%--------------------------------------------------------------------
oldCodeSummary() ->
    All = lists:filtermap(fun oldCodeEntry/1, erlang:processes()),
    Sorted = sortBy(memory, All),
    #{
        count => length(Sorted),
        topProcesses => lists:sublist(Sorted, 20)
    }.

%% 单个进程的旧代码 entry：current_function / initial_call 关联模块为旧代码时返回 entry map。
oldCodeEntry(Pid) ->
    case process_info(Pid, [current_function, initial_call,
                            message_queue_len, memory, registered_name]) of
        undefined ->
            false;
        Info ->
            Mods = oldCodeModules(Pid, Info),
            case Mods of
                [] ->
                    false;
                _ ->
                    {ok, #{
                        pid => pid_to_list(Pid),
                        registeredName => proplists:get_value(registered_name, Info, undefined),
                        oldModules => Mods,
                        currentFunction => formatMfa(proplists:get_value(current_function, Info, undefined)),
                        initialCall => formatMfa(proplists:get_value(initial_call, Info, undefined)),
                        messageQueueLen => valueOrZero(proplists:get_value(message_queue_len, Info, 0)),
                        memory => valueOrZero(proplists:get_value(memory, Info, 0))
                    }}
            end
    end.

%% 从进程信息中提取关联模块，过滤出该进程仍引用其旧代码的模块。
%% code:is_module_old/1 为 OTP 23 前的内部 API（已移除）；改用官方
%% erlang:check_process_code/2 判定进程是否持有模块旧代码的引用。
oldCodeModules(Pid, Info) ->
    Raw = [proplists:lookup(current_function, Info),
           proplists:lookup(initial_call, Info)],
    Candidates = [M || {_, {M, _, _}} <- Raw, is_atom(M)],
    [M || M <- lists:usort(Candidates), isOldModule(Pid, M)].

isOldModule(Pid, M) when is_pid(Pid), is_atom(M) ->
    try erlang:check_process_code(Pid, M) catch _:_ -> false end;
isOldModule(_, _) ->
    false.

formatMfa({M, F, A}) when is_atom(M), is_atom(F), is_integer(A) ->
    #{module => M, function => F, arity => A};
formatMfa(Other) ->
    Other.

%%--------------------------------------------------------------------
%% @doc
%% 在白名单允许的前提下，以 interactive 调用者身份在独立进程中执行 MFA，
%% 超时返回 {error, timeout}，异常被捕获为 {error, #{class, reason, stacktrace}}。
%%
%% @param Module0 模块（atom / binary / list）
%% @param Function0 函数（atom / binary / list）
%% @param Args0 参数（list 或单个值）
%% @param Timeout0 超时毫秒（默认 5000）
%% @return {ok, Value} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
runMfa(Module0, Function0, Args0, Timeout0) ->
    runMfa(Module0, Function0, Args0, Timeout0, interactive).

%%--------------------------------------------------------------------
%% @doc
%% runMfa/4 的扩展版本，可显式指定调用者身份。会先做白名单校验、写审计日志，
%% 再检查函数是否已导出，最后才在独立进程中执行。
%%
%% @param Caller0 调用者标识（atom / binary / list，默认 unknown）
%% @return {ok, Value} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
runMfa(Module0, Function0, Args0, Timeout0, Caller0) ->
    Module = normalizeAtom(Module0),
    Function = normalizeAtom(Function0),
    Args = styleArgs(normalizeArgs(Args0)),
    Timeout = max(1, toInteger(Timeout0, 5000)),
    Caller = normalizeCaller(Caller0),
    Arity = length(Args),
    case checkMfaAllowed(Module, Function, Arity) of
        ok ->
            auditMfa(Module, Function, Args, Caller),
            runMfaSafe(Module, Function, Args, Timeout);
        {error, Reason} ->
            {error, Reason}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 校验 MFA 是否允许执行（黑/白名单、已加载、已导出），不实际 apply。
%% 供 runMfa / evalErl AST 远程调用复用。
%% @end
%%--------------------------------------------------------------------
-spec checkMfaAllowed(term(), term(), non_neg_integer()) -> ok | {error, map()}.
checkMfaAllowed(Module0, Function0, Arity0) ->
    Module = normalizeAtom(Module0),
    Function = normalizeAtom(Function0),
    Arity = toInteger(Arity0, -1),
    Policy = normalizeMfaPolicy(alConfig:get(runMfaPolicy, blacklist)),
    case is_atom(Module) andalso is_atom(Function) andalso Arity >= 0 of
        false ->
            {error, #{reason => badMfa, module => Module0, function => Function0, arity => Arity0,
                      hint => <<"Provide real module/function atoms from searchCode or moduleExports.">>}};
        true ->
            Blacklisted = (Policy =/= allowExported) andalso mfaBlacklisted(Module, Function, Arity),
            case Blacklisted of
                true ->
                    {error, #{reason => mfaNotAllowed, module => Module, function => Function,
                              arity => Arity,
                              hint => <<"Blocked by runMfaBlacklist. Use another MFA or dedicated tool.">>}};
                false ->
                    case ensureLoaded(Module) of
                        false ->
                            {error, #{reason => moduleNotLoaded, module => Module, function => Function,
                                      arity => Arity,
                                      hint => <<"Module not loaded. resolveModule/searchCode for the real name; do not invent MFA.">>}};
                        true ->
                            case mfaPolicyAllows(Policy, Module, Function, Arity) of
                                false ->
                                    {error, #{reason => mfaNotAllowed, module => Module, function => Function,
                                              arity => Arity,
                                              hint => <<"Policy denied this MFA. Check runMfaPolicy / whitelist.">>}};
                                true ->
                                    case erlang:function_exported(Module, Function, Arity) of
                                        true -> ok;
                                        false -> {error, notExportedError(Module, Function, Arity)}
                                    end
                            end
                    end
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 在隔离进程中 apply(Mod, Fun, Args)，带超时（供 evalErl 临时模块调用）。
%% @end
%%--------------------------------------------------------------------
-spec runApplySafe(atom(), atom(), list(), pos_integer()) -> {ok, term()} | {error, term()}.
runApplySafe(Module, Function, Args, Timeout)
  when is_atom(Module), is_atom(Function), is_list(Args) ->
    runMfaSafe(Module, Function, Args, max(1, toInteger(Timeout, 5000))).

%% 未导出时附带 exports，阻止模型继续瞎猜相近函数名。
notExportedError(Module, Function, Arity) ->
    Exports0 = try Module:module_info(exports) catch _:_ -> [] end,
    Exports = [{F, A} || {F, A} <- Exports0, F =/= module_info],
    FunBin = atom_to_binary(Function, utf8),
    Similar = lists:filter(fun({F, _A}) ->
        FBin = atom_to_binary(F, utf8),
        binary:longest_common_prefix([FBin, FunBin]) >= 3
            orelse (byte_size(FunBin) >= 3 andalso string:find(FBin, FunBin) =/= nomatch)
            orelse (byte_size(FBin) >= 3 andalso string:find(FunBin, FBin) =/= nomatch)
    end, Exports),
    SameName = [{F, A} || {F, A} <- Exports, F =:= Function],
    #{
        reason => notExported,
        module => Module,
        function => Function,
        arity => Arity,
        sameNameArities => SameName,
        similarExports => lists:sublist(Similar, 20),
        exportsSample => lists:sublist(Exports, 50),
        hint => <<"Not exported at this arity. Use sameNameArities/similarExports/exportsSample "
                  "or searchCode — do NOT invent another MFA name."/utf8>>
    }.

%% MFA 放行策略（cfg: runMfaPolicy）：
%%   blacklist     — 默认：已导出 MFA 均可跑，仅拒绝 runMfaBlacklist（导出在调用处再查）
%%   whitelist     — 仅静态/运行时白名单
%%   allowModules  — 仅 runMfaAllowModules 中的模块（仍须已导出）
%%   allowExported — 同 blacklist 但忽略黑名单（兼容旧配置）
mfaPolicyAllows(Policy, Module, Function, Arity)
  when is_atom(Module), is_atom(Function), is_integer(Arity) ->
    case Policy of
        blacklist -> true;
        allowExported -> true;
        allowModules -> lists:member(Module, allowModules());
        whitelist -> mfaWhitelisted(Module, Function, Arity);
        _ -> false
    end;
mfaPolicyAllows(_, _, _, _) ->
    false.

%% 黑名单命中：支持 M | {M,F} | {M,F,A}
mfaBlacklisted(Module, Function, Arity) ->
    lists:any(fun(Entry) -> mfaBlacklistMatch(Entry, Module, Function, Arity) end,
              mfaBlacklistEntries()).

mfaBlacklistEntries() ->
    case alConfig:get(runMfaBlacklist, undefined) of
        undefined -> defaultMfaBlacklist();
        L when is_list(L) -> L;
        _ -> defaultMfaBlacklist()
    end.

%% 默认黑名单：危险原语 + 可泄密读路径整模块。
%% 业务查询类 MFA 不在此列；需要更严可设 runMfaPolicy=whitelist。
defaultMfaBlacklist() ->
    [
        file,          %% 含 read_file / consult 等任意路径读
        alConfig,      %% 配置含 apiKey
        application,   %% get_env 可取密钥
        init,
        os,
        %% 具体危险原语（兼容旧条目）
        {os, cmd},
        {os, putenv},
        {os, unsetenv},
        {erlang, halt},
        {erlang, open_port},
        {erlang, disconnect_node},
        {init, stop},
        {init, reboot},
        {file, write_file},
        {file, read_file},
        {file, consult},
        {file, delete},
        {file, rename},
        {file, copy},
        {code, purge},
        {code, delete},
        {code, load_binary},
        {code, load_abs},
        {code, load_file},
        {rpc, call},
        {rpc, cast},
        {rpc, multicall},
        {erpc, call},
        {erpc, cast},
        {erpc, multicall},
        {slave, start},
        {net_kernel, connect_node},
        {httpc, request},
        {hackney, request},
        {eWCli, request},
        {eWCli, post},
        {eWCli, get},
        {eWCli, postStream},
        {eWCli, stream},
        {alHttp, request},
        {alHttp, post},
        {alHttp, get}
    ].

mfaBlacklistMatch({M, F, A}, Module, Function, Arity)
  when is_atom(M), is_atom(F), is_integer(A) ->
    M =:= Module andalso F =:= Function andalso A =:= Arity;
mfaBlacklistMatch({M, F}, Module, Function, _Arity)
  when is_atom(M), is_atom(F) ->
    M =:= Module andalso F =:= Function;
mfaBlacklistMatch(M, Module, _Function, _Arity) when is_atom(M) ->
    M =:= Module;
mfaBlacklistMatch(_, _, _, _) ->
    false.

mfaWhitelisted(Module, Function, Arity) ->
    StaticCfg = alConfig:get(runMfaWhitelist, undefined),
    Static = case StaticCfg of
        undefined -> [];
        WL when is_list(WL) -> WL;
        _ -> []
    end,
    Runtime = getRuntimeWhitelist(),
    case {StaticCfg =:= undefined, Runtime} of
        {true, []} ->
            defaultMfaAllowed(Module, Function, Arity);
        _ ->
            Combined = Static ++ Runtime,
            lists:any(fun
                ({M, F, A}) when is_atom(M), is_atom(F), is_integer(A) ->
                    M =:= Module andalso F =:= Function andalso A =:= Arity;
                (_) ->
                    false
            end, Combined)
    end.

normalizeMfaPolicy(blacklist) -> blacklist;
normalizeMfaPolicy(<<"blacklist">>) -> blacklist;
normalizeMfaPolicy(allowExported) -> allowExported;
normalizeMfaPolicy(<<"allowExported">>) -> allowExported;
normalizeMfaPolicy(allow_modules) -> allowModules;
normalizeMfaPolicy(allowModules) -> allowModules;
normalizeMfaPolicy(<<"allowModules">>) -> allowModules;
normalizeMfaPolicy(whitelist) -> whitelist;
normalizeMfaPolicy(<<"whitelist">>) -> whitelist;
%% 未识别时默认黑名单（放行大多数）
normalizeMfaPolicy(_) -> blacklist.

allowModules() ->
    case alConfig:get(runMfaAllowModules, []) of
        L when is_list(L) ->
            lists:filtermap(fun(M0) ->
                case normalizeAtom(M0) of
                    M when is_atom(M) -> {true, M};
                    _ -> false
                end
            end, L);
        _ ->
            []
    end.

ensureLoaded(Module) when is_atom(Module) ->
    case code:is_loaded(Module) of
        {file, _} -> true;
        false ->
            case code:ensure_loaded(Module) of
                {module, Module} -> true;
                _ -> false
            end
    end;
ensureLoaded(_) ->
    false.

%%--------------------------------------------------------------------
%% @doc
%% 热加载白名单：仅清空 persistent_term 上的运行时条目，重新从配置读取。
%% 若要重新读取 cfg 文件请调用 `alConfig:load/0`。
%%
%% @return ok
%% @end
%%--------------------------------------------------------------------
-spec reloadWhitelist() -> ok.
reloadWhitelist() ->
    %% 配置文件层 alConfig:get 已直接读 cfg，无需重启；仅刷新运行时层。
    clearRuntimeWhitelist(),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% 添加一条 MFA 白名单（支持 `Mod`、`{Mod,Fun}`、`{Mod,Fun,Arity}`）。
%% 写入 persistent_term 以便跨进程立即生效。重复项自动去重。
%%
%% @return ok
%% @end
%%--------------------------------------------------------------------
-spec addWhitelist(term()) -> ok.
addWhitelist(Mfa) ->
    Cur = getRuntimeWhitelist(),
    persistent_term:put(?RuntimeWlKey, lists:usort([normalizeMfa(Mfa) | Cur])),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% 三元组形式的便捷入口。
%%
%% @end
%%--------------------------------------------------------------------
-spec addWhitelist(atom(), atom(), non_neg_integer()) -> ok.
addWhitelist(M, F, A) when is_atom(M), is_atom(F), is_integer(A), A >= 0 ->
    addWhitelist({M, F, A}).

%%--------------------------------------------------------------------
%% @doc
%% 移除单条白名单；不存在时静默忽略。
%% @end
%%--------------------------------------------------------------------
-spec removeWhitelist(term()) -> ok.
removeWhitelist(Mfa) ->
    Cur = getRuntimeWhitelist(),
    Target = normalizeMfa(Mfa),
    persistent_term:put(?RuntimeWlKey, [E || E <- Cur, E =/= Target]),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% 三元组形式的便捷入口。
%% @end
%%--------------------------------------------------------------------
-spec removeWhitelist(atom(), atom(), non_neg_integer()) -> ok.
removeWhitelist(M, F, A) ->
    removeWhitelist({M, F, A}).

%%--------------------------------------------------------------------
%% @doc
%% 列出当前生效的 MFA 白名单：cfg 静态 + 运行时动态。
%% 返回 #{static => [...], runtime => [...], combined => [...]}。
%% @end
%%--------------------------------------------------------------------
-spec listWhitelist() -> map().
listWhitelist() ->
    Static = case alConfig:get(runMfaWhitelist, undefined) of
        WL when is_list(WL) -> WL;
        _ -> []
    end,
    Runtime = getRuntimeWhitelist(),
    #{
        static => Static,
        runtime => Runtime,
        combined => lists:usort(Static ++ Runtime)
    }.

%%--------------------------------------------------------------------
%% @doc
%% 清除所有运行时动态白名单（不影响 cfg 静态白名单）。
%% @end
%%--------------------------------------------------------------------
-spec clearRuntimeWhitelist() -> ok.
clearRuntimeWhitelist() ->
    _ = persistent_term:erase(?RuntimeWlKey),
    ok.

%% 读取运行时白名单；未设置时返回 []。
getRuntimeWhitelist() ->
    case persistent_term:get(?RuntimeWlKey, undefined) of
        WL when is_list(WL) -> WL;
        _ -> []
    end.

%% 归一化 MFA 形态：atom 保留，tuple 保留，其它原样（运行时校验会丢弃）。
normalizeMfa({M, F, A}) when is_atom(M), is_atom(F), is_integer(A) -> {M, F, A};
normalizeMfa({M, F}) when is_atom(M), is_atom(F) -> {M, F};
normalizeMfa(M) when is_atom(M) -> M;
normalizeMfa(Other) -> Other.

%% 默认放行的安全只读 MFA：erlang:system_info/1、erlang:memory/0、erlang:processes/0。
defaultMfaAllowed(erlang, system_info, 1) -> true;
defaultMfaAllowed(erlang, memory, 0) -> true;
defaultMfaAllowed(erlang, processes, 0) -> true;
%% 其它 MFA 默认拒绝。
defaultMfaAllowed(_, _, _) -> false.

%% 判断某个 ETS 表是否被屏蔽：表名匹配 blockedEtsNames 中任一模式即被屏蔽。
etsBlocked(Tab) ->
    Name = valueOrUndefined(ets:info(Tab, name)),
    Blocked = blockedEtsNames(),
    lists:any(fun(Pattern) -> etsNameMatch(Name, Pattern) end, Blocked).

%% atom 表名与 atom 模式直接比较。
etsNameMatch(Name, Pattern) when is_atom(Name), is_atom(Pattern) ->
    Name =:= Pattern;
%% atom 表名与 list 模式：尝试把 list 转为 existing atom 后比较。
etsNameMatch(Name, Pattern) when is_atom(Name), is_list(Pattern) ->
    Name =:= try list_to_existing_atom(Pattern) catch _:_ -> undefined end;
%% 其它类型组合一律不匹配。
etsNameMatch(_Name, _Pattern) ->
    false.

%% 读取被屏蔽的 ETS 表名列表，默认屏蔽补丁事务表和 SSL/OAuth 缓存。
blockedEtsNames() ->
    alConfig:get(etsBlockedNames, [ali_patch_transactions, ssl_pem_cache, oauth_cache]).

%% 写审计日志：构造审计条目，logger 打印 INFO，并异步落库到 simulation_runs 表。
auditMfa(Module, Function, Args, Caller) ->
    Entry = #{
        module => Module,
        function => Function,
        arity => length(Args),
        caller => Caller,
        node => node(),
        at => erlang:system_time(second)
    },
    logger:info("ali runMfa audit ~p", [Entry]),
    _ = alAsync:run(runMfaAuditPersist, fun() -> persistAudit(Entry) end),
    ok.

%% 异步将审计条目写入本地数据库的 simulation_runs 表；插入失败记录日志。
persistAudit(Entry) ->
    Sql =
        "INSERT INTO simulation_runs (scenario_type, input, output, status, created_at) "
        "VALUES (?, ?, ?, ?, ?)",
    Params = [
        <<"runMfaAudit">>,
        alJson:encode(Entry),
        <<"{}">>,
        <<"audit">>,
        maps:get(at, Entry)
    ],
    case alLocalDb:insert(Sql, Params) of
        {ok, _} ->
            ok;
        Other ->
            logger:warning("runMfa audit persist failed: ~p", [Other]),
            ok
    end.

%% atom 调用者原样返回。
normalizeCaller(Value) when is_atom(Value) -> Value;
%% binary 调用者尝试转 existing atom，失败保留原值。
normalizeCaller(Value) when is_binary(Value) ->
    try binary_to_existing_atom(Value, utf8) catch _:_ -> Value end;
%% list 调用者尝试转 existing atom，失败保留原值。
normalizeCaller(Value) when is_list(Value) ->
    try list_to_existing_atom(Value) catch _:_ -> Value end;
%% 其它类型一律标记为 unknown。
normalizeCaller(_) -> unknown.

%% 在独立进程中执行 MFA 并带超时：捕获任何异常为 {error, #{class, reason, stacktrace}}，
%% 超时则 kill 子进程并返回 {error, timeout}。
runMfaSafe(Module, Function, Args, Timeout) ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, MonRef} = spawn_monitor(fun() ->
        Result = try apply(Module, Function, Args) of
            Value -> {ok, Value}
        catch
            Class:Reason:Stacktrace -> {error, #{class => Class, reason => Reason, stacktrace => Stacktrace}}
        end,
        Parent ! {Ref, Result}
    end),
    receive
        {Ref, Result} ->
            erlang:demonitor(MonRef, [flush]),
            Result;
        {'DOWN', MonRef, process, Pid, Reason} ->
            {error, #{reason => childExit, detail => Reason}}
    after Timeout ->
        erlang:demonitor(MonRef, [flush]),
        exit(Pid, kill),
        flushRunMfaResult(Ref),
        {error, timeout}
    end.

%% 超时 kill 后清掉可能已投递的结果消息，避免残留污染调用方邮箱。
flushRunMfaResult(Ref) ->
    receive
        {Ref, _Result} -> ok
    after 0 ->
        ok
    end.

%% 采集单个进程的关键信息快照：注册名、当前函数、初始调用、状态、消息队列长度、内存、reductions。
processSnapshot(Pid) ->
    Keys = [registered_name, current_function, initial_call, status, message_queue_len, memory, reductions],
    Info = maps:from_list([{Key, valueOrUndefined(process_info(Pid, Key))} || Key <- Keys]),
    Info#{pid => pid_to_list(Pid)}.

%% 采集单个 ETS 表的关键信息快照：id、name、owner、size、memory、type、protection。
etsSnapshot(Tab) ->
    Name = valueOrUndefined(ets:info(Tab, name)),
    #{
        id => inspect(Tab),
        name => Name,
        owner => ownerToList(valueOrUndefined(ets:info(Tab, owner))),
        size => valueOrZero(ets:info(Tab, size)),
        memory => valueOrZero(ets:info(Tab, memory)),
        type => valueOrUndefined(ets:info(Tab, type)),
        protection => valueOrUndefined(ets:info(Tab, protection))
    }.

%% 按 map 中指定 Key 的值降序排序。
sortBy(Key, Items) ->
    lists:sort(fun(A, B) -> maps:get(Key, A, 0) >= maps:get(Key, B, 0) end, Items).

%% 将 process_info 返回的 undefined / {Key, Value} / 裸值统一提取为值。
valueOrUndefined(undefined) ->
    undefined;
valueOrUndefined({_, Value}) ->
    Value;
valueOrUndefined(Value) ->
    Value.

%% 将 undefined 转为 0，其它值原样返回（用于数值类字段）。
valueOrZero(undefined) ->
    0;
valueOrZero(Value) ->
    Value.

%% 将 pid owner 转为 list 形式，便于序列化。
ownerToList(Pid) when is_pid(Pid) ->
    pid_to_list(Pid);
ownerToList(Other) ->
    Other.

%% 用 ~p 格式化任意 term 为扁平 list（用于 ETS 表 id 等不可直接序列化的值）。
inspect(Term) ->
    lists:flatten(io_lib:format("~p", [Term])).

%% atom 原样返回。
normalizeAtom(Value) when is_atom(Value) ->
    Value;
%% binary：只允许已存在的 atom，绝不 binary_to_atom 创建永久 atom
%% （原子表耗尽 DoS）；失败返回 {error, unknownAtom}。
normalizeAtom(Value) when is_binary(Value), byte_size(Value) > 0, byte_size(Value) =< 255 ->
    try binary_to_existing_atom(Value, utf8)
    catch _:_ -> {error, unknownAtom}
    end;
normalizeAtom(Value) when is_list(Value) ->
    try list_to_existing_atom(Value)
    catch _:_ -> {error, unknownAtom}
    end;
normalizeAtom(_) ->
    {error, unknownAtom}.

%% list 参数原样返回。
normalizeArgs(Args) when is_list(Args) ->
    Args;
%% 非 list 参数包装为单元素 list。
normalizeArgs(Args) ->
    [Args].

%% JSON 字符串常为 binary；游戏侧 MFA 多要 Erlang string(list)。
styleArgs(Args) ->
    case alConfig:get(runMfaArgStyle, list) of
        binary -> [styleArg(A, binary) || A <- Args];
        asIs -> Args;
        <<"binary">> -> [styleArg(A, binary) || A <- Args];
        <<"asIs">> -> Args;
        _ -> [styleArg(A, list) || A <- Args]
    end.

styleArg(V, list) when is_binary(V) -> unicode:characters_to_list(V);
styleArg(V, binary) when is_list(V) ->
    case io_lib:printable_unicode_list(V) of
        true -> unicode:characters_to_binary(V);
        false -> V
    end;
styleArg(V, _) -> V.

%% 整数原样返回。
toInteger(Value, _Default) when is_integer(Value) ->
    Value;
%% binary 先转 list 再解析。
toInteger(Value, Default) when is_binary(Value) ->
    toInteger(binary_to_list(Value), Default);
%% list 用 string:to_integer 解析，失败返回默认值。
toInteger(Value, Default) when is_list(Value) ->
    case string:to_integer(Value) of
        {Int, _} when is_integer(Int) -> Int;
        _ -> Default
    end;
%% 其它类型一律返回默认值。
toInteger(_Value, Default) ->
    Default.
