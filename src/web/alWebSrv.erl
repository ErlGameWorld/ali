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

-export([startLink/0, startWeb/0, stop/0, port/0, running/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, alWebSrv).
-define(DEFAULT_PORT, 8088).

%% @doc 启动 gen_server（通常由 supervisor 调用，勿直接调用）。
-spec startLink() -> {ok, pid()} | {error, term()}.
startLink() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc 启动 HTTP 监听；若进程未运行则先向 ali_sup 注册子进程。
%% @returns `{ok, Port}' 或 `{error, Reason}'
-spec startWeb() -> {ok, non_neg_integer()} | {error, term()}.
startWeb() ->
    try callStartWeb() of
        Result -> Result
    catch
        exit:{noproc, _} ->
            {error, webSrvNotRunning};
        exit:{{shutdown, Reason}, _} ->
            {error, {webSrvCrashed, Reason}};
        exit:Reason ->
            {error, {webSrvExit, Reason}}
    end.

callStartWeb() ->
    case whereis(?SERVER) of
        undefined ->
            {error, webSrvNotRunning};
        _ ->
            gen_server:call(?SERVER, startWeb, 30000)
    end.

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
%% 在此创建速率限制 ETS 表，使其归属本长生命周期进程。
init([]) ->
    alWebSec:ensureStarted(),
    {ok, #{port => undefined, enabled => false}}.

%% @doc 处理同步调用：startWeb / stop / port 查询。
handle_call(startWeb, _From, State) ->
    Port = webPort(),
    case maps:get(enabled, State, false) of
        true ->
            {reply, {ok, maps:get(port, State)}, State};
        false ->
            case startHttp(Port) of
                ok ->
                    {reply, {ok, Port}, State#{port => Port, enabled => true}};
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end
    end;
handle_call(stop, _From, State) ->
    stopHttp(maps:get(port, State, undefined)),
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
startHttp(Port) ->
    case ensureApps() of
        ok ->
            _ = ensureEwsrvStarted(),
            WsOpts = [
                {wsMod, alWebHer},
                {wsSupName, alWebConnSup},
                {chunkedSupp, true}
            ],
            case eWSrv:openSrv(Port, WsOpts) of
                {ok, _} -> ok;
                {error, OpenReason} -> {error, OpenReason};
                ok -> ok
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% 确保 eWSrv 与 parse_trans 依赖已启动。
ensureApps() ->
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
ensureEwsrvStarted() ->
    try eWSrv:start() of
        {ok, _} -> ok;
        ok -> ok;
        {error, {already_started, _}} -> ok;
        {error, StartReason} -> {error, StartReason};
        Other when Other =:= already_started -> ok
    catch
        _:_ -> ok
    end.

%% @doc 关闭指定端口的 HTTP 监听。
stopHttp(undefined) ->
    ok;
stopHttp(Port) ->
    try eWSrv:closeSrv(Port) catch _:_ -> ok end,
    ok.

%% @doc 从 aliCfg.cfg 读取 webPort，默认 8088。
webPort() ->
    case alConfig:val(webPort) of
        P when is_integer(P) -> P;
        _ -> ?DEFAULT_PORT
    end.