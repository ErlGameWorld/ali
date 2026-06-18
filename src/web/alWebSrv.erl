%%%-------------------------------------------------------------------
%%% @doc Web UI HTTP 服务管理进程。
%%%
%%% 封装 eWSrv 的启动/停止，将 HTTP 请求路由到 {@link alWebHer}。
%%% 由 {@link ali_sup} 按需动态添加为子进程（restart => transient）。
%%%
%%% 端口读取 `config.cfg` 的 `webPort`，默认 {@code 8088}。
%%% @end
%%%-------------------------------------------------------------------
-module(alWebSrv).

-behaviour(gen_server).

-export([start_link/0, start_web/0, stop/0, port/0, running/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, alWebSrv).
-define(DEFAULT_PORT, 8088).

%% @doc 启动 gen_server（通常由 supervisor 调用，勿直接调用）。
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc 启动 HTTP 监听；若进程未运行则先向 ali_sup 注册子进程。
%% @returns `{ok, Port}' 或 `{error, Reason}'
-spec start_web() -> {ok, non_neg_integer()} | {error, term()}.
start_web() ->
    try call_start_web() of
        Result -> Result
    catch
        exit:{noproc, _} ->
            {error, webSrvNotRunning};
        exit:{{shutdown, Reason}, _} ->
            {error, {webSrvCrashed, Reason}};
        exit:Reason ->
            {error, {webSrvExit, Reason}}
    end.

call_start_web() ->
    case whereis(?SERVER) of
        undefined ->
            case supervisor:start_child(ali_sup, web_child_spec()) of
                {ok, _} -> gen_server:call(?SERVER, start_web, 30000);
                {error, {already_started, _}} -> gen_server:call(?SERVER, start_web, 30000);
                {error, Reason} -> {error, Reason}
            end;
        _ ->
            gen_server:call(?SERVER, start_web, 30000)
    end.

%% @doc 构造 alWebSrv 的 supervisor child_spec。
web_child_spec() ->
    #{
        id => alWebSrv,
        start => {alWebSrv, start_link, []},
        restart => transient,
        shutdown => 5000,
        type => worker,
        modules => [alWebSrv]
    }.

%% @doc 停止 HTTP 监听并关闭 gen_server。
-spec stop() -> ok.
stop() ->
    case whereis(?SERVER) of
        undefined -> ok;
        Pid -> gen_server:call(Pid, stop)
    end.

%% @doc 返回当前监听端口，未启动时返回 undefined。
-spec port() -> non_neg_integer() | undefined.
port() ->
    case whereis(?SERVER) of
        undefined -> undefined;
        _ -> gen_server:call(?SERVER, port)
    end.

%% @doc 检查 HTTP 服务进程是否在运行。
-spec running() -> boolean().
running() ->
    whereis(?SERVER) =/= undefined.

%% @doc gen_server 初始化；HTTP 尚未启动。
init([]) ->
    {ok, #{port => undefined, enabled => false}}.

%% @doc 处理同步调用：start_web / stop / port 查询。
handle_call(start_web, _From, State) ->
    Port = web_port(),
    case maps:get(enabled, State, false) of
        true ->
            {reply, {ok, maps:get(port, State)}, State};
        false ->
            case start_http(Port) of
                ok ->
                    {reply, {ok, Port}, State#{port => Port, enabled => true}};
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end
    end;
handle_call(stop, _From, State) ->
    stop_http(maps:get(port, State, undefined)),
    {stop, normal, ok, State#{enabled => false, port => undefined}};
handle_call(port, _From, State) ->
    {reply, maps:get(port, State, undefined), State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

%% @doc 处理异步消息（当前无 cast 处理逻辑）。
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @doc 处理系统消息（当前无 info 处理逻辑）。
handle_info(_Info, State) ->
    {noreply, State}.

%%%===================================================================
%%% HTTP 启动与停止
%%%===================================================================

%% @doc 启动 eWSrv HTTP 监听，请求路由至 alWebHer。
start_http(Port) ->
    case ensure_apps() of
        ok ->
            _ = ensure_ewsrv_started(),
            case eWSrv:openSrv(Port, [{wsMod, alWebHer}]) of
                {ok, _} -> ok;
                {error, OpenReason} -> {error, OpenReason};
                ok -> ok
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% 确保 eWSrv 与 parse_trans 依赖已启动。
ensure_apps() ->
    case application:ensure_all_started(eWSrv) of
        {ok, _} ->
            case application:ensure_all_started(parse_trans) of
                {ok, _} -> ok;
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% 确保 eWSrv 应用进程已运行。
ensure_ewsrv_started() ->
    case catch eWSrv:start() of
        {ok, _} -> ok;
        ok -> ok;
        {error, {already_started, _}} -> ok;
        {error, StartReason} -> {error, StartReason};
        Other when Other =:= already_started -> ok;
        {'EXIT', _} -> ok
    end.

%% @doc 关闭指定端口的 HTTP 监听。
stop_http(undefined) ->
    ok;
stop_http(Port) ->
    catch eWSrv:closeSrv(Port),
    ok.

%% @doc 从应用环境读取 webPort，默认 8088。
web_port() ->
    case application:get_env(ali, webPort) of
        {ok, P} when is_integer(P) -> P;
        undefined -> ?DEFAULT_PORT
    end.