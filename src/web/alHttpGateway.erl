%%%-------------------------------------------------------------------
%% @doc 基于 eWSrv 的 HTTP gateway；路由由 alWebHandler 处理。
%%
%% Web UI 与工具 gateway 共用一个监听端口。当 `gateway.enabled' 或
%% `web.enabled' 任一为 true 时启动。启用 Web UI 时优先 `web.port'，
%% 否则用 `gateway.port'。
%%
%% eWSrv 在 eNet 下接受 socket，随后 `wsHttp:newConn/2' 调用
%% `supervisor:start_child(alWebConnSup, ...)'。打开监听前必须先
%% 注册连接 supervisor。
%% @end
%%%-------------------------------------------------------------------

-module(alHttpGateway).

-behaviour(gen_server).

-export([start_link/0, port/0, enabled/0, status/0, ensureListening/0, restart/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

%%--------------------------------------------------------------------
%% @doc
%% gen_server 启动入口：以本地注册名 `?SERVER' 启动 HTTP 网关进程。
%%
%% @return `{ok, Pid}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Configured listen port (web.port when web.enabled, else gateway.port).
%% 中文：返回配置的监听端口（web 启用时取 web.port，否则取 gateway.port）。
port() ->
    listenPort().

%%--------------------------------------------------------------------
%% @doc
%% 判断网关是否启用：gateway 或 web 任一启用即为 true。
%%
%% @return `true' | `false'
%% @end
%%--------------------------------------------------------------------
enabled() ->
    gatewayEnabled() orelse webEnabled().

%%--------------------------------------------------------------------
%% @doc
%% 确保 HTTP 正在监听。若配置启用但未监听（例如上次 eaddrinuse 失败后
%% 进程仍活着、或 already_started 未重试），尝试重新打开端口。
%%
%% @return #{ok => true|false, ...status fields}
%% @end
%%--------------------------------------------------------------------
-spec ensureListening() -> map().
ensureListening() ->
    case enabled() of
        false ->
            #{ok => false, reason => disabled, port => listenPort()};
        true ->
            case status() of
                #{enabled := true, port := P} = St ->
                    case portListening(P) of
                        true -> St#{ok => true};
                        false ->
                            io:format("ali HTTP 端口 ~p 未在监听，尝试重启网关...~n", [P]),
                            restart()
                    end;
                #{enabled := false, port := P, error := Err} ->
                    io:format(
                        "ali HTTP 未监听 ~p（上次错误: ~p）。正在重试...~n"
                        "若仍失败请关掉其它 rebar3 shell / erl 进程后执行 ali:stop(), ali:start().~n",
                        [P, Err]
                    ),
                    restart();
                #{enabled := false, port := P} ->
                    io:format("ali HTTP 未启用监听 ~p，正在重试打开...~n", [P]),
                    restart();
                _ ->
                    restart()
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 重启 HTTP 网关子进程并重新绑定端口。
%% @end
%%--------------------------------------------------------------------
-spec restart() -> map().
restart() ->
    case whereis(alWebSup) of
        undefined ->
            Msg = <<"alWebSup not running; call ali:start() first">>,
            io:format("~ts~n", [Msg]),
            #{ok => false, reason => noWebSup};
        _ ->
            _ = supervisor:terminate_child(alWebSup, alHttpGateway),
            case supervisor:restart_child(alWebSup, alHttpGateway) of
                {ok, _} ->
                    timer:sleep(100),
                    St = status(),
                    case St of
                        #{enabled := true, port := P} ->
                            io:format("ali HTTP 已监听 http://127.0.0.1:~p/~n", [P]),
                            St#{ok => true};
                        #{error := Err, port := P} ->
                            io:format(
                                "ali HTTP 仍无法打开 ~p: ~p~n"
                                "请结束占用端口的旧 erl/rebar3（Windows: netstat -ano | findstr :~p）后重试。~n",
                                [P, Err, P]
                            ),
                            St#{ok => false};
                        Other ->
                            Other#{ok => false}
                    end;
                {error, Reason} ->
                    io:format("ali HTTP 重启失败: ~p~n", [Reason]),
                    #{ok => false, reason => Reason}
            end
    end.

%% 粗测本机端口是否已有监听（不保证一定是本进程）。
portListening(P) when is_integer(P) ->
    case gen_tcp:connect({127, 0, 0, 1}, P, [binary, {active, false}], 500) of
        {ok, Sock} ->
            gen_tcp:close(Sock),
            true;
        {error, _} ->
            false
    end;
portListening(_) ->
    false.

%%--------------------------------------------------------------------
%% @doc
%% 查询网关运行状态（监听端口、是否启用、连接 sup pid 等）。
%% 进程未启动时返回 notStarted 兜底 map，不抛异常。
%% @end
%%--------------------------------------------------------------------
status() ->
    try gen_server:call(?SERVER, status, 5000) of
        Reply -> Reply
    catch
        exit:{noproc, _} ->
            #{
                enabled => false,
                mode => notStarted,
                port => listenPort(),
                connSup => whereis(alWebConnSup)
            }
    end.

%%--------------------------------------------------------------------
%% @doc
%% gen_server init 回调：先确保 web 安全模块启动，再按 enabled 标志决定
%% 是直接返回关闭状态还是启动监听器。
%%
%% @return `{ok, State}'
%% @end
%%--------------------------------------------------------------------
init([]) ->
    alWebSec:ensureStarted(),
    case enabled() of
        false ->
            {ok, #{enabled => false, port => listenPort()}};
        true ->
            startListener(listenPort())
    end.

%%--------------------------------------------------------------------
%% @doc
%% gen_server handle_call 回调（多子句）：
%%  - `status'：返回当前状态（附带连接 sup pid）
%%  - 其它请求：返回 ok
%%
%% @return `{reply, Reply, State}'
%% @end
%%--------------------------------------------------------------------
handle_call(status, _From, State) ->
    Reply = State#{connSup => whereis(alWebConnSup)},
    {reply, Reply, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

%%--------------------------------------------------------------------
%% @doc
%% gen_server handle_cast 回调：忽略所有 cast 消息。
%%
%% @return `{noreply, State}'
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @doc
%% gen_server handle_info 回调：忽略所有 info 消息。
%%
%% @return `{noreply, State}'
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @doc
%% gen_server terminate 回调（多子句）：
%%  - 启用状态下关闭 eWSrv 监听器
%%  - 其它状态直接返回
%%
%% @param _Reason 终止原因
%% @param State 当前状态
%% @return `ok'
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, #{port := P, enabled := true}) ->
    try eWSrv:closeSrv(P) catch _:_ -> ok end,
    ok;
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @doc
%% gen_server code_change 回调：热升级时直接保留原状态。
%%
%% @return `{ok, State}'
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @doc
%% 启动 HTTP 监听器：依次确保 eWSrv 启动、连接 sup 存在、端口可打开。
%%
%% 任一环节失败都不抛异常，而是返回 `enabled => false' 的状态，以保证
%% ali_sup 中其它核心服务（session_mgr/server）继续运行。
%%
%% @param P 监听端口
%% @return `{ok, State}'
%% @end
%%--------------------------------------------------------------------
startListener(P) ->
    case ensureEwsrvStarted() of
        ok ->
            case ensureConnSup() of
                ok ->
                    case openHttpPort(P) of
                        ok ->
                            io:format("ali HTTP (Web UI + gateway) listening on http://127.0.0.1:~p/~n", [P]),
                            logger:info("ali HTTP (Web UI + gateway) listening on port ~p", [P]),
                            {ok, #{enabled => true, port => P}};
                        {error, Reason} ->
                            io:format(
                                "ali HTTP 打开端口 ~p 失败: ~p~n"
                                "常见原因: 旧 rebar3 shell / erl 仍占用端口。~n"
                                "处理: 关掉其它 Erlang 窗口，或执行 ali:httpRestart().~n",
                                [P, Reason]
                            ),
                            logger:warning(
                                "ali HTTP failed to open ~p: ~p (kill old erl/rebar3 shell if eaddrinuse)",
                                [P, Reason]
                            ),
                            %% Never crash ali_sup — core (session_mgr/server) must stay up.
                            {ok, #{enabled => false, port => P, error => Reason}}
                    end;
                {error, Reason} ->
                    logger:error("alWebConnSup unavailable: ~p", [Reason]),
                    {ok, #{enabled => false, port => P, error => {connSup, Reason}}}
            end;
        {error, Reason} ->
            logger:error("eWSrv failed to start: ~p", [Reason]),
            {ok, #{enabled => false, port => P, error => {ewsrv, Reason}}}
    end.

%% eWSrv:openSrv/2 uses `{ok, _} = eNet:openTcp(...)` and throws on bind failure.
%%--------------------------------------------------------------------
%% @doc
%% 打开 HTTP 端口：先关闭可能的旧监听，再尝试 openSrv。
%%
%% 遇到 `eaddrinuse' 时等待 200ms 后再试一次，其它错误直接返回。
%%
%% @param P 监听端口
%% @return `ok' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
openHttpPort(P) ->
    try eWSrv:closeSrv(P) catch _:_ -> ok end,
    case tryOpenSrv(P) of
        ok ->
            ok;
        {error, eaddrinuse} ->
            timer:sleep(200),
            try eWSrv:closeSrv(P) catch _:_ -> ok end,
            tryOpenSrv(P);
        {error, _} = Err ->
            Err
    end.

%%--------------------------------------------------------------------
%% @doc
%% 实际调用 `eWSrv:openSrv/2' 打开监听，捕获 badmatch 与其它异常并转为 `{error, Reason}'。
%%
%% @param P 监听端口
%% @return `ok' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
tryOpenSrv(P) ->
    Opts = [
        {wsMod, alWebHandler},
        {wsSupName, alWebConnSup},
        {chunkedSupp, true},
        %% 单次可接收的最大字节数上限（HTTP body / WS 帧），防止超大请求 DoS。
        {maxSize, maxRequestBytes()}
    ] ++ bindOpts(),
    try eWSrv:openSrv(P, Opts) of
        {ok, _} ->
            ok;
        {error, Reason} ->
            {error, Reason};
        Other ->
            {error, Other}
    catch
        error:{badmatch, {error, Reason}} ->
            {error, Reason};
        error:{badmatch, Reason} ->
            {error, Reason};
        Class:Reason ->
            {error, {Class, Reason}}
    end.

%% eWSrv requires a registered simple_one_for_one supervisor named
%% alWebConnSup; without it every accept crashes with noproc.
%%--------------------------------------------------------------------
%% @doc
%% 确保 `alWebConnSup' 已注册运行；缺失时尝试启动，已存在则返回 ok。
%%
%% @return `ok' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
ensureConnSup() ->
    case whereis(alWebConnSup) of
        Pid when is_pid(Pid) ->
            ok;
        undefined ->
            case alWebConnSup:start_link() of
                {ok, _Pid} ->
                    logger:warning("alWebConnSup was not running; started it for eWSrv"),
                    ok;
                {error, {already_started, _Pid}} ->
                    ok;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

%% 确保 eWSrv 应用及其依赖已全部启动。
ensureEwsrvStarted() ->
    case application:ensure_all_started(eWSrv) of
        {ok, _} -> ok;
        {error, Reason} -> {error, Reason}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 计算监听端口：web 启用时优先取 web.port（默认 8787），否则取 gateway.port（默认 8787）。
%%
%% @return 端口号
%% @end
%%--------------------------------------------------------------------
listenPort() ->
    case webEnabled() of
        true ->
            maps:get(port, webConfig(), maps:get(port, gatewayConfig(), 8787));
        false ->
            maps:get(port, gatewayConfig(), 8787)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 计算监听器绑定选项。默认显式绑定 `web.bindAddress'（缺省 `127.0.0.1'），
%% 只监听本机回环，除非配置明确改为 `0.0.0.0'/`::' 等对外地址。
%% 解析失败时回退到 127.0.0.1，绝不静默监听全网。
%%
%% @return `[{tcpOpts, [{ip, Addr}]}]' | `[]'
%% @end
%%--------------------------------------------------------------------
bindOpts() ->
    Addr = maps:get(bindAddress, webConfig(), "127.0.0.1"),
    case parseAddress(Addr) of
        {ok, Ip} -> [{tcpOpts, [{ip, Ip}]}];
        error -> [{tcpOpts, [{ip, {127, 0, 0, 1}}]}]
    end.

%% 解析绑定地址字符串/binary 为 inet 地址元组。
parseAddress(Addr) when is_binary(Addr) ->
    parseAddress(binary_to_list(Addr));
parseAddress(Addr) when is_tuple(Addr) ->
    {ok, Addr};
parseAddress(Addr) when is_list(Addr) ->
    case inet:parse_address(Addr) of
        {ok, Ip} -> {ok, Ip};
        {error, _} -> error
    end;
parseAddress(_) ->
    error.

%% 单次接收的最大字节数（web.maxRequestBytes，默认 16MB）。
maxRequestBytes() ->
    maps:get(maxRequestBytes, webConfig(), 16 * 1024 * 1024).

%% 读取 gateway.enabled 配置项（默认 false）。
gatewayEnabled() ->
    maps:get(enabled, gatewayConfig(), false) =:= true.

%% 读取 web.enabled 配置项（默认 false）。
webEnabled() ->
    maps:get(enabled, webConfig(), false) =:= true.

%% 从 alConfig 读取 gateway 配置 map（默认空 map）。
gatewayConfig() ->
    alConfig:get(gateway, #{}).

%% 从 alConfig 读取 web 配置 map（默认空 map）。
webConfig() ->
    alConfig:get(web, #{}).
