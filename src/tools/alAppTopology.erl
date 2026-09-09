%%%-------------------------------------------------------------------
%% @doc 检查已加载 application 及其相互依赖图。
%%
%% 使用 `application:loaded_applications/0` 与 `application:get_key/3`
%% 枚举 `applications` / `included_applications` 并构建有向图。
%% 图同时以扁平边列表与以节点为中心的 map 暴露（各 app 的传递父/子）。
%% @end
%%%-------------------------------------------------------------------

-module(alAppTopology).

-export([
    snapshot/0,
    edges/0,
    nodeMap/0,
    roots/0,
    leaves/0,
    cycleReport/0
]).

%%--------------------------------------------------------------------
%% @doc
%% 一次性返回应用拓扑的完整快照：节点、边、汇总统计。
%% 每个节点至少包含 app / name / version / description 字段，
%% 可选 modules / registeredNames / supervisorPid 字段若可获取则填入。
%%
%% @return 拓扑快照 map
%% @end
%%--------------------------------------------------------------------
-spec snapshot() -> map().
snapshot() ->
    Apps = loadedApps(),
    Nodes = [buildNode(App) || App <- Apps],
    Edges = edges(),
    Map = nodeMap(),
    #{
        nodeCount => length(Nodes),
        edgeCount => length(Edges),
        nodes => Nodes,
        edges => Edges,
        parents => maps:get(parents, Map, #{}),
        children => maps:get(children, Map, #{}),
        roots => roots(),
        leaves => leaves(),
        cycles => cycleReport()
    }.

%%--------------------------------------------------------------------
%% @doc
%% 返回 [{From, To}] 形式的应用依赖边。From 依赖 To（From 在 included_applications
%% / applications 中显式引用 To）。每条边保留首次出现的方向。
%%
%% @return 边列表
%% @end
%%--------------------------------------------------------------------
-spec edges() -> [{atom(), atom()}].
edges() ->
    lists:usort([{From, To}
                 || {From, Deps} <- depMap(),
                    To <- Deps,
                    is_atom(From), is_atom(To)]).

%%--------------------------------------------------------------------
%% @doc
%% 返回 #{parents => #{App => [Parent]}, children => #{App => [Child]}}，
%% parents/children 均为直接（一跳）依赖。
%%
%% @return 节点邻接 map
%% @end
%%--------------------------------------------------------------------
-spec nodeMap() -> map().
nodeMap() ->
    Deps = depMap(),
    Parents = maps:from_list([{App, []} || {App, _} <- Deps]),
    Parents1 = lists:foldl(fun({App, Deps0}, Acc) ->
        lists:foldl(fun(Dep, Acc1) ->
            Cur = maps:get(Dep, Acc1, []),
            Acc1#{Dep => lists:usort([App | Cur])}
        end, Acc, Deps0)
    end, Parents, Deps),
    Children = maps:from_list([{App, Deps0} || {App, Deps0} <- Deps]),
    #{parents => Parents1, children => Children}.

%%--------------------------------------------------------------------
%% @doc
%% 返回没有任何 incoming 依赖（没有其它 app 依赖自己）的应用列表。
%% 适合作为发布/裁剪时的"切点"。
%%
%% @return 应用 atom 列表
%% @end
%%--------------------------------------------------------------------
-spec roots() -> [atom()].
roots() ->
    Children = maps:get(children, nodeMap(), #{}),
    All = lists:usort(maps:keys(Children)),
    Parents = maps:get(parents, nodeMap(), #{}),
    WithIncoming = lists:usort([P || {_Child, Ps} <- maps:to_list(Parents),
                                    P <- Ps]),
    All -- WithIncoming.

%%--------------------------------------------------------------------
%% @doc
%% 返回没有任何 outgoing 依赖（自己不依赖任何其它 app）的应用列表。
%% 通常是 kernel / stdlib 这种基础库。
%%
%% @return 应用 atom 列表
%% @end
%%--------------------------------------------------------------------
-spec leaves() -> [atom()].
leaves() ->
    Children = maps:get(children, nodeMap(), #{}),
    [App || {App, []} <- maps:to_list(Children)].

%%--------------------------------------------------------------------
%% @doc
%% 检测拓扑中的循环依赖（DFS 状态机 0/1/2）。
%% 若存在环，返回 [{CyclePath}]；否则返回 []。
%%
%% @return 环路径列表
%% @end
%%--------------------------------------------------------------------
-spec cycleReport() -> [[atom()]].
cycleReport() ->
    Children = maps:get(children, nodeMap(), #{}),
    detectCycles(Children).

%%--------------------------------------------------------------------
%% 内部：从 application controller 提取已加载应用列表。
%%--------------------------------------------------------------------
loadedApps() ->
    case application:loaded_applications() of
        L when is_list(L) -> [App || {App, _, _} <- L];
        Other -> Other
    end.

%%--------------------------------------------------------------------
%% 内部：为单个应用构造节点描述。
%%--------------------------------------------------------------------
buildNode({App, _Vsn, _Desc} = AppT) ->
    {App, _Vsn0, Desc0} = AppT,
    Vsn = case application:get_key(App, vsn) of
        {ok, V} -> V;
        _ -> undefined
    end,
    Desc = case application:get_key(App, description) of
        {ok, D} -> D;
        _ -> Desc0
    end,
    Modules = case application:get_key(App, modules) of
        {ok, Ms} -> Ms;
        _ -> []
    end,
    Reg = case application:get_key(App, registered) of
        {ok, Rs} -> Rs;
        _ -> []
    end,
    #{
        app => App,
        vsn => Vsn,
        description => Desc,
        modules => Modules,
        moduleCount => length(Modules),
        registered => Reg
    };
buildNode(App) when is_atom(App) ->
    buildNode({App, undefined, undefined}).

%%--------------------------------------------------------------------
%% 内部：构造 {App, [Dep]} 列表，Dep 来自 applications + included_applications。
%%--------------------------------------------------------------------
depMap() ->
    lists:map(fun(App) -> {App, depsOf(App)} end, loadedApps()).

depsOf(App) ->
    lists:usort(depsOf(App, []) ++ depsOf(App, included)).

depsOf(App, Key) ->
    case application:get_key(App, Key) of
        {ok, Deps} when is_list(Deps) -> [D || D <- Deps, is_atom(D)];
        _ -> []
    end.

%%--------------------------------------------------------------------
%% 内部：DFS 环检测。状态 0=未访问 1=栈上 2=已访问。
%%--------------------------------------------------------------------
detectCycles(Children) ->
    {_Sorted, _State, Cycles} = dfs(Children, maps:keys(Children), #{}, [], []),
    lists:reverse(Cycles).

dfs(_Children, [], State, Acc, Cycles) ->
    {Acc, State, Cycles};
dfs(Children, [V | Rest], State, Acc, Cycles) ->
    case maps:get(V, State, 0) of
        0 ->
            {Acc1, State1, Cycles1} = visit(Children, V, State, Acc, Cycles, []),
            dfs(Children, Rest, State1, Acc1, Cycles1);
        _ ->
            dfs(Children, Rest, State, Acc, Cycles)
    end.

%% Path 为根→当前的祖先栈（最新在头）。
visit(Children, V, State, Acc, Cycles, Path) ->
    State1 = State#{V => 1},
    Path1 = [V | Path],
    Deps = maps:get(V, Children, []),
    {Acc1, State2, Cycles1} = lists:foldl(
        fun(D, {A, S, C}) ->
            case maps:get(D, S, 0) of
                0 -> visit(Children, D, S, A, C, Path1);
                1 -> {A, S, [extractCycle(D, Path1) | C]};
                2 -> {A, S, C}
            end
        end,
        {Acc, State1, Cycles},
        Deps),
    {[V | Acc1], State2#{V => 2}, Cycles1}.

%% Path=[V,...,D,...,root]（新在前）→ 环 [D,...,V,D]
extractCycle(D, Path) ->
    case lists:splitwith(fun(X) -> X =/= D end, Path) of
        {Before, [D | _]} -> [D | lists:reverse(Before)] ++ [D];
        _ -> [D, D]
    end.
