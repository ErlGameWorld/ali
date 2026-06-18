%%%-------------------------------------------------------------------
%%% @doc OTP 应用与监督树检查工具。
%%%
%%% 查询 application 元数据、递归遍历 supervisor 子进程树，
%%% 以及类似 etop 的进程内存/消息队列 Top-N 摘要。
%%% @end
%%%-------------------------------------------------------------------
-module(alToolOtp).

-export([
    getAppInfo/2,
    getSupTree/2,
    etopSummary/2
]).

-define(MAX_DEPTH, 6).
-define(MAX_CHILDREN, 50).

%% @doc 返回已加载 application 列表或单个应用的加载/启动状态与元数据。
-spec getAppInfo(map(), map()) -> {ok, map()}.
getAppInfo(Args, _Config) ->
    AppArg = maps:get(application, Args, undefined),
    case AppArg of
        undefined ->
            Apps = application:loaded_applications(),
            Infos = [app_info(A) || {A, _, _} <- Apps],
            {ok, #{count => length(Infos), applications => Infos}};
        _ ->
            App = to_atom(AppArg),
            {ok, app_info(App)}
    end.

%% 收集单个 application 的 description、env、mod 等键值。
app_info(App) ->
    Loaded = lists:keymember(App, 1, application:loaded_applications()),
    Started = lists:keymember(App, 1, application:which_applications()),
    Keys = [description, vsn, modules, registered, applications, env, mod],
    Meta = maps:from_list([
        {K, V} || K <- Keys, {ok, V} <- [application:get_key(App, K)]
    ]),
    #{
        application => App,
        loaded => Loaded,
        started => Started,
        meta => Meta,
        envKeys => env_keys(App)
    }.

%% 列出 application 环境变量键名（不含值，避免泄露敏感配置）。
env_keys(App) ->
    case application:get_all_env(App) of
        Env when is_list(Env) -> [K || {K, _} <- Env];
        _ -> []
    end.

%% @doc 从 application 主模块 supervisor 递归构建监督树（深度与子节点数受限）。
-spec getSupTree(map(), map()) -> {ok, map()} | {error, term()}.
getSupTree(Args, _Config) ->
    Depth = maps:get(maxDepth, Args, 4),
    case maps:get(application, Args, undefined) of
        undefined ->
            Started = application:which_applications(),
            Trees = [sup_tree_for_app(App, Depth) || {App, _, _} <- Started],
            {ok, #{applicationCount => length(Trees), trees => Trees}};
        AppArg ->
            App = to_atom(AppArg),
            {ok, sup_tree_for_app(App, Depth)}
    end.

%% 定位 application mod 启动的顶层 supervisor 并遍历。
sup_tree_for_app(App, Depth) ->
    case application:get_key(App, mod) of
        {ok, {Mod, _StartArgs}} ->
            case whereis(Mod) of
                undefined ->
                    #{application => App, module => Mod, status => not_running};
                Pid ->
                    #{
                        application => App,
                        module => Mod,
                        root => walk_sup(Pid, 0, Depth)
                    }
            end;
        _ ->
            #{application => App, status => unknown}
    end.

%% 递归遍历 supervisor 子进程；达到最大深度时截断。
walk_sup(Pid, Depth, MaxDepth) when Depth >= MaxDepth ->
    #{pid => format_pid(Pid), depth => Depth, truncated => true};
walk_sup(Pid, Depth, MaxDepth) ->
    Info = #{
        pid => format_pid(Pid),
        registered => registered_name(Pid),
        depth => Depth,
        type => process_type(Pid)
    },
    case is_supervisor(Pid) of
        true ->
            Children = safe_which_children(Pid),
            Limited = lists:sublist(Children, ?MAX_CHILDREN),
            Info#{
                childCount => length(Children),
                truncatedChildren => length(Children) > ?MAX_CHILDREN,
                children => [child_node(C, Depth + 1, MaxDepth) || C <- Limited]
            };
        false ->
            Info
    end.

%% 将 supervisor:which_children 单项转为树节点。
child_node({Id, P, Type, _Mods}, Depth, MaxDepth) when is_pid(P) ->
    #{
        id => sanitize_id(Id),
        type => Type,
        node => walk_sup(P, Depth, MaxDepth)
    };
child_node({Id, P, Type, Mods}, Depth, MaxDepth) ->
    #{
        id => sanitize_id(Id),
        type => Type,
        modules => Mods,
        node => case is_pid(P) of true -> walk_sup(P, Depth, MaxDepth); false -> #{pid => P} end
    }.

%% 安全调用 which_children，异常时返回空列表。
safe_which_children(Pid) ->
    try supervisor:which_children(Pid) of
        Kids when is_list(Kids) -> Kids;
        _ -> []
    catch
        _:_ -> []
    end.

%% 根据 current_function 或 initial_call 判断是否为 supervisor 进程。
is_supervisor(Pid) ->
    case erlang:process_info(Pid, current_function) of
        {current_function, {supervisor, _, _}} -> true;
        _ ->
            case erlang:process_info(Pid, initial_call) of
                {initial_call, {supervisor, _, _}} -> true;
                _ -> false
            end
    end.

%% 推断进程类型：supervisor、gen_server、gen_statem、gen_event 或普通 process。
process_type(Pid) ->
    case is_supervisor(Pid) of
        true -> supervisor;
        false ->
            case erlang:process_info(Pid, current_function) of
                {current_function, {gen_server, _, _}} -> gen_server;
                {current_function, {gen_statem, _, _}} -> gen_statem;
                {current_function, {gen_event, _, _}} -> gen_event;
                _ -> process
            end
    end.

%% 获取进程注册名，未注册则 undefined。
registered_name(Pid) ->
    case erlang:process_info(Pid, registered_name) of
        {registered_name, Name} -> Name;
        _ -> undefined
    end.

%% 将 pid 格式化为便于 JSON 输出的 binary。
format_pid(Pid) when is_pid(Pid) -> list_to_binary(pid_to_list(Pid));
format_pid(X) -> X.

%% 规范化 supervisor 子节点 id 为可序列化类型。
sanitize_id(X) when is_atom(X); is_binary(X); is_integer(X) -> X;
sanitize_id(X) when is_pid(X) -> format_pid(X);
sanitize_id(X) -> list_to_binary(io_lib:format("~p", [X])).

%% @doc 按内存占用排序返回 Top-N 进程及系统 memory 摘要。
-spec etopSummary(map(), map()) -> {ok, map()}.
etopSummary(Args, _Config) ->
    Limit = maps:get(limit, Args, 15),
    Mem = erlang:memory(),
    Pids = erlang:processes(),
    Infos = lists:foldl(fun(Pid, Acc) ->
        case erlang:process_info(Pid, [memory, message_queue_len, registered_name, current_function]) of
            undefined -> Acc;
            Info ->
                [maps:merge(#{pid => format_pid(Pid)}, maps:from_list(Info)) | Acc]
        end
    end, [], Pids),
    Sorted = lists:sort(fun(A, B) ->
        maps:get(memory, A, 0) >= maps:get(memory, B, 0)
    end, Infos),
    Top = lists:sublist(Sorted, Limit),
    {ok, #{
        processCount => length(Pids),
        memory => [{K, V} || {K, V} <- Mem],
        topProcesses => Top
    }}.

to_atom(X) when is_atom(X) -> X;
to_atom(X) when is_binary(X) -> binary_to_atom(X, utf8);
to_atom(X) when is_list(X) -> list_to_atom(X).