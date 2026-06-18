%%%-------------------------------------------------------------------
%%% @doc Erlang 运行时自省工具。
%%%
%%% 查询已加载 application/模块、注册进程、进程详情、节点信息、
%%% Agent 配置及运行时综合摘要；支持通过 RPC 查询远程已连接节点。
%%% @end
%%%-------------------------------------------------------------------
-module(alToolRuntime).

-export([
    loadedApplications/2,
    loadedModules/2,
    moduleExports/2,
    registeredProcesses/2,
    processList/2,
    processInfo/2,
    nodeInfo/2,
    remoteNodeInfo/2,
    runtimeSummary/2,
    agentConfig/2,
    nodeSummary/1
]).

-define(MAX_OUTPUT, 8192).

%% @doc 返回当前节点已加载的 application 列表及数量。
-spec loadedApplications(map(), map()) -> {ok, map()}.
loadedApplications(_Args, _Config) ->
    Apps = application:loaded_applications(),
    Summary = [{App, Desc, Vsn} || {App, Desc, Vsn} <- Apps],
    {ok, #{applications => Summary, count => length(Summary)}}.

%% @doc 返回已加载模块名列表（可按 limit 截断）。
-spec loadedModules(map(), map()) -> {ok, map()}.
loadedModules(Args, _Config) ->
    Limit = maps:get(limit, Args, 200),
    All = code:all_loaded(),
    Modules = [Mod || {Mod, _} <- All],
    Sorted = lists:sort(Modules),
    Truncated = lists:sublist(Sorted, Limit),
    {ok, #{
        count => length(Sorted),
        truncated => length(Sorted) > Limit,
        modules => Truncated
    }}.

%% @doc 返回指定模块的导出函数列表（排除 module_info/0,1）。
-spec moduleExports(map(), map()) -> {ok, map()} | {error, term()}.
moduleExports(Args, _Config) ->
    Module = maps:get(module, Args, undefined),
    case Module of
        undefined ->
            {error, missingModule};
        _ ->
            Mod = toAtom(Module),
            case code:ensure_loaded(Mod) of
                {module, Mod} ->
                    Exports = Mod:module_info(exports),
                    Filtered = [{F, A} || {F, A} <- Exports, F =/= module_info],
                    {ok, #{module => Mod, exports => Filtered}};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

%% @doc 返回当前节点 registered() 名称列表。
-spec registeredProcesses(map(), map()) -> {ok, map()}.
registeredProcesses(_Args, _Config) ->
    Names = registered(),
    {ok, #{count => length(Names), names => Names}}.

%% @doc 采样返回进程列表的简要信息（内存、当前函数等）。
-spec processList(map(), map()) -> {ok, map()}.
processList(Args, _Config) ->
    Limit = maps:get(limit, Args, 50),
    Pids = erlang:processes(),
    Infos = [summarizeProcess(Pid) || Pid <- lists:sublist(Pids, Limit)],
    {ok, #{
        count => length(Pids),
        truncated => length(Pids) > Limit,
        processes => Infos
    }}.

%% @doc 按 pid 字符串、原子名或 pid 查询单个进程详细信息。
-spec processInfo(map(), map()) -> {ok, map()} | {error, term()}.
processInfo(Args, _Config) ->
    case maps:get(pid, Args, maps:get(name, Args, undefined)) of
        undefined ->
            {error, missingPidOrName};
        Name when is_atom(Name) ->
            case whereis(Name) of
                undefined -> {error, notFound};
                Pid -> fetchProcessInfo(Pid)
            end;
        PidStr when is_binary(PidStr); is_list(PidStr) ->
            case parsePid(PidStr) of
                {ok, Pid} -> fetchProcessInfo(Pid);
                {error, Reason} -> {error, Reason}
            end;
        Pid when is_pid(Pid) ->
            fetchProcessInfo(Pid)
    end.

%% @doc 返回本地节点的 OTP 版本、调度器、内存等摘要。
-spec nodeInfo(map(), map()) -> {ok, map()}.
nodeInfo(_Args, _Config) ->
    {ok, nodeSummary(node())}.

%% @doc 返回 Agent LLM 配置（经 sanitize）及格式化文本。
-spec agentConfig(map(), map()) -> {ok, map()}.
agentConfig(_Args, _Config) ->
    C = llmCliConfig:getAgentConfig(),
    {ok, #{
        config => llmJson:sanitize(C),
        formatted => llmCliConfig:formatAgentConfig()
    }}.

%% @doc 聚合节点、应用、进程采样、注册名与 memory 的运行时总览。
-spec runtimeSummary(map(), map()) -> {ok, map()}.
runtimeSummary(Args, Config) ->
    Limit = maps:get(processLimit, Args, 10),
    {ok, Node} = nodeInfo(#{}, Config),
    {ok, Apps} = loadedApplications(#{}, Config),
    {ok, Procs} = processList(#{limit => Limit}, Config),
    {ok, Regs} = registeredProcesses(#{}, Config),
    Mem = [{K, V} || {K, V} <- erlang:memory()],
    {ok, maps:merge(Node, #{
        applicationCount => maps:get(count, Apps),
        applications => lists:sublist(maps:get(applications, Apps), 20),
        processCount => maps:get(count, Procs),
        sampleProcesses => maps:get(processes, Procs),
        registeredCount => maps:get(count, Regs),
        registeredNames => lists:sublist(maps:get(names, Regs), 30),
        memory => Mem
    })}.

%% @doc 通过 RPC 获取已连接远程节点的 nodeSummary。
-spec remoteNodeInfo(map(), map()) -> {ok, map()} | {error, term()}.
remoteNodeInfo(Args, _Config) ->
    case maps:get(node, Args, undefined) of
        undefined ->
            {error, missingNode};
        NodeArg ->
            Node = toAtom(NodeArg),
            case Node =:= node() of
                true ->
                    {ok, nodeSummary(Node)};
                false ->
                    case lists:member(Node, [node() | nodes()]) of
                        false ->
                            {error, nodeNotConnected};
                        true ->
                            case rpc:call(Node, erlang, node, []) of
                                {badrpc, Reason} ->
                                    {error, Reason};
                                _ ->
                                    Summary = rpc:call(Node, ?MODULE, nodeSummary, [Node]),
                                    case Summary of
                                        {badrpc, Reason} -> {error, Reason};
                                        Map when is_map(Map) -> {ok, Map#{connected => true}}
                                    end
                            end
                    end
            end
    end.

%% @doc 构建节点级系统信息 map（供本地与 RPC 复用）。
-spec nodeSummary(atom()) -> map().
nodeSummary(Node) ->
    #{
        node => Node,
        otpRelease => erlang:system_info(otp_release),
        version => erlang:system_info(version),
        processCount => erlang:system_info(process_count),
        processLimit => erlang:system_info(process_limit),
        memoryTotal => erlang:memory(total),
        schedulers => erlang:system_info(schedulers_online)
    }.

%% 读取进程关键 process_info 字段并截断过大结果。
fetchProcessInfo(Pid) ->
    case erlang:process_info(Pid, [
        current_function, initial_call, message_queue_len,
        memory, registered_name, status
    ]) of
        undefined ->
            {error, notFound};
        Info ->
            {ok, truncateMap(Info)}
    end.

%% 构建进程列表项的轻量摘要。
summarizeProcess(Pid) ->
    case erlang:process_info(Pid, [registered_name, current_function, message_queue_len, memory]) of
        undefined ->
            #{pid => Pid, status => dead};
        Info ->
            maps:merge(#{pid => Pid}, maps:from_list(Info))
    end.

%% 对过大的 map 打印结果做预览截断。
truncateMap(Map) ->
    Bin = list_to_binary(io_lib:format("~p", [Map])),
    case byte_size(Bin) > ?MAX_OUTPUT of
        true ->
            #{truncated => true, preview => binary:part(Bin, 0, ?MAX_OUTPUT)};
        false ->
            Map
    end.

%% 将字符串解析为 Erlang pid。
parsePid(Str) ->
    try
        {ok, list_to_pid(toList(Str))}
    catch
        _:_ -> {error, invalidPid}
    end.

toAtom(X) when is_atom(X) -> X;
toAtom(X) when is_binary(X) -> binary_to_atom(X, utf8);
toAtom(X) when is_list(X) -> list_to_atom(X).

toList(X) when is_binary(X) -> binary_to_list(X);
toList(X) when is_list(X) -> X.