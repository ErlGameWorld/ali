%%%-------------------------------------------------------------------
%% @doc 托管式 Qdrant 向量数据库子进程管理（Port 生命周期）。
%%
%% 当 `{qdrant, #{enabled => true}}' 且未配置外部 `{qdrant_url, ...}' 时，
%% 通过 {@link open_port/2} 拉起 `priv/qdrant'，监听 stdout/stderr，
%% 并对外暴露 {@link url/0} 供 {@link alCoreClient} 使用。
%% @end
%%%-------------------------------------------------------------------

-module(alQdrant).

-behaviour(gen_server).

-export([
    start_link/0,
    enabled/0,
    managed/0,
    url/0,
    status/0,
    childOsPid/0
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
%% Test exports — 内部纯逻辑辅助
-export([scheduleReconnect/1]).

-define(SERVER, ?MODULE).
-define(ReadyPollMs, 200).
-define(ReadyAttempts, 75).
-define(ReconnectMs, 3000).

%%--------------------------------------------------------------------
%% @doc
%% 启动并注册本地的 alQdrant gen_server，负责管理 Qdrant 子进程生命周期。
%%
%% @return {ok, Pid} | ignore | {error, Reason} 标准 gen_server 启动返回值
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% @doc
%% 判断 Qdrant 是否可用：服务未启动时按是否配置了外部 URL 决定；
%% 服务已启动时按其 status 中的 enabled 字段，并兜底外部 URL 配置。
%%
%% @return boolean()
%% @end
%%--------------------------------------------------------------------
enabled() ->
    case whereis(?SERVER) of
        undefined ->
            alConfig:qdrantServiceUrl() =/= undefined;
        Pid ->
            case gen_server:call(Pid, status, 5000) of
                #{enabled := true} -> true;
                _ -> alConfig:qdrantServiceUrl() =/= undefined
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 是否由本模块托管 Qdrant 子进程（而非使用外部 URL）。
%%
%% @return boolean()
%% @end
%%--------------------------------------------------------------------
managed() ->
    alConfig:qdrantManaged().

%%--------------------------------------------------------------------
%% @doc
%% 返回 Qdrant 服务的 HTTP URL（来自配置）。
%%
%% @return string() | undefined
%% @end
%%--------------------------------------------------------------------
url() ->
    alConfig:qdrantServiceUrl().

%%--------------------------------------------------------------------
%% @doc
%% 查询当前 Qdrant 服务状态。服务未启动时返回 notStarted 的状态 map。
%%
%% @return 包含 enabled/managed/mode/url/httpPort/storagePath/reason 的状态 map
%% @end
%%--------------------------------------------------------------------
status() ->
    try gen_server:call(?SERVER, status, 5000) of
        Reply -> Reply
    catch
        exit:{noproc, _} ->
            #{enabled => false, mode => notStarted, url => url()}
    end.

%%--------------------------------------------------------------------
%% @doc 当前托管的 qdrant OS 进程 PID（停止前用于兜底杀进程）。
%% @end
%%--------------------------------------------------------------------
childOsPid() ->
    try gen_server:call(?SERVER, eChildOsPid, 2000) of
        Pid -> Pid
    catch
        _:_ -> undefined
    end.

%%--------------------------------------------------------------------
%% @doc
%% gen_server 初始化：托管模式下不阻塞等待 Qdrant 就绪，而是先返回 starting
%% 状态，再通过 {@link handle_info/2} 异步完成启动。避免阻塞 supervisor 启动。
%%
%% @return {ok, State}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    process_flag(trap_exit, true),
    case managed() of
        false ->
            {ok, baseState(#{mode => external, enabled => url() =/= undefined})};
        true ->
            %% 异步触发启动，不阻塞 init。
            self() ! eStartManaged,
            {ok, baseState(#{mode => starting, enabled => false})}
    end.

%% 处理 status 同步调用：返回当前状态 map。
handle_call(status, _From, State) ->
  {reply, statusMap(State), State};
handle_call(eChildOsPid, _From, State) ->
    Pid = case maps:get(port, State, undefined) of
        Port when is_port(Port) -> alOsProc:osPid(Port);
        _ -> maps:get(os_pid, State, undefined)
    end,
    {reply, Pid, State};
%% 未识别的同步调用返回 {error, unsupported}。
handle_call(_Request, _From, State) ->
  {reply, {error, unsupported}, State}.

%% 默认 handle_cast：忽略所有异步消息。
handle_cast(_Msg, State) ->
  {noreply, State}.

%% 接收 port 的 stdout/stderr 数据，按行打印到 logger debug。
handle_info({Port, {data, Data}}, State = #{port := Port}) ->
    case is_binary(Data) of
        true ->
            Line = string:trim(binary_to_list(Data)),
            case Line of
                "" -> ok;
                _ -> logger:debug("qdrant: ~s", [Line])
            end;
        false ->
            ok
    end,
    {noreply, State};
%% port 关闭：警告并调度重连。
handle_info({Port, closed}, State = #{port := Port}) ->
    logger:warning("qdrant port closed"),
    {noreply, scheduleReconnect(closePort(State))};
%% port 进程退出：警告并调度重连。
handle_info({'EXIT', Port, Reason}, State = #{port := Port}) ->
    logger:warning("qdrant port exited: ~p", [Reason]),
    {noreply, scheduleReconnect(closePort(State))};
%% port 退出状态：警告并调度重连。
handle_info({Port, {exit_status, Status}}, State = #{port := Port}) ->
    logger:warning("qdrant exit_status=~p", [Status]),
    {noreply, scheduleReconnect(closePort(State))};
%% 重连定时器触发：托管或失败模式下尝试重新启动 Qdrant，失败则再次调度重连。
handle_info(eReconnectPort, State) when is_map_key(port, State) ->
    case startManaged() of
        {ok, NewState} ->
            {noreply, maps:merge(State, NewState)};
        {error, Reason} ->
            logger:debug("qdrant reconnect failed: ~p", [Reason]),
            {noreply, scheduleReconnect(State#{enabled => false, reason => Reason})}
    end;
%% 异步启动 Qdrant 子进程并等待就绪。成功时切换到 managed 模式；
%% 失败时进入 failed 模式并调度重连。这样 supervisor 启动不会被阻塞。
handle_info(eStartManaged, State) ->
    case startManaged() of
        {ok, NewState} ->
            {noreply, maps:merge(State, NewState)};
        {error, Reason} ->
            logger:warning("alQdrant managed start failed: ~p", [Reason]),
            NewState = State#{mode => failed, enabled => false, reason => Reason},
            erlang:send_after(?ReconnectMs, self(), eReconnectPort),
            {noreply, NewState}
    end;
%% 默认 handle_info：忽略其它消息。
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @doc
%% gen_server terminate 回调：若仍持有 port 句柄则尝试关闭，吞掉异常。
%%
%% @return ok
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, State) when is_map(State) ->
    Port = maps:get(port, State, undefined),
    OsPid = case Port of
        P when is_port(P) -> alOsProc:osPid(P);
        _ -> maps:get(os_pid, State, undefined)
    end,
    alOsProc:closeAndKill(Port, OsPid),
    ok;
terminate(_Reason, _State) ->
    ok.

%% code_change 回调：热更时直接保留原 state。
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

%% 构造基础状态 map，再用 Extra 覆盖默认字段。
baseState(Extra) ->
    maps:merge(#{
        enabled => false,
        mode => disabled,
        port => undefined,
        url => url(),
        httpPort => httpPort(),
        storagePath => storagePath()
    }, Extra).

%%--------------------------------------------------------------------
%% @doc
%% 托管启动 Qdrant：检查二进制是否存在、准备 storage 目录、open_port 启动子进程，
%% 然后轮询 /healthz 直到就绪或耗尽尝试次数。失败时关闭 port 并返回 {error, Reason}。
%%
%% @return {ok, State} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
startManaged() ->
    Bin = qdrantBinary(),
    case filelib:is_file(Bin) of
        false ->
            {error, {binaryMissing, Bin}};
        true ->
            Storage = storagePath(),
            ok = filelib:ensure_dir(filename:join(Storage, "placeholder")),
            Port = open_port(
                {spawn_executable, Bin},
                [
                    stream,
                    stderr_to_stdout,
                    binary,
                    exit_status,
                    {env, portEnv(Storage)}
                ]
            ),
            case awaitReady(url(), ?ReadyAttempts) of
                ok ->
                    logger:info("qdrant ready at ~s (storage ~s)", [url(), Storage]),
                    {ok, baseState(#{
                        enabled => true,
                        mode => managed,
                        port => Port,
                        os_pid => alOsProc:osPid(Port)
                    })};
                {error, _Reason} = Error ->
                    alOsProc:closeAndKill(Port),
                    Error
            end
    end.

%% 构造 Qdrant 子进程的环境变量：HTTP/gRPC 端口和 storage 路径。
portEnv(Storage) ->
    Http = integer_to_list(httpPort()),
    Grpc = integer_to_list(grpcPort()),
    [
        {"QDRANT__SERVICE__HTTP_PORT", Http},
        {"QDRANT__SERVICE__GRPC_PORT", Grpc},
        {"QDRANT__STORAGE__STORAGE_PATH", Storage}
    ].

%%--------------------------------------------------------------------
%% @doc
%% 轮询 Qdrant /healthz 直到就绪或耗尽尝试次数。
%%
%% @return ok | {error, notReady}
%% @end
%%--------------------------------------------------------------------
awaitReady(_Url, 0) ->
    {error, notReady};
awaitReady(Url, Attempts) ->
    case healthCheck(Url) of
        ok ->
            ok;
        {error, _} ->
            timer:sleep(?ReadyPollMs),
            awaitReady(Url, Attempts - 1)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 调用 Qdrant 的 /healthz 健康检查端点，200/204 视为健康。
%%
%% @return ok | {error, Other}
%% @end
%%--------------------------------------------------------------------
healthCheck(Url) ->
    HealthUrl = trimTrailingSlash(Url) ++ "/healthz",
    case alHttp:get(HealthUrl, [], #{recvTimeout => 2000, connectTimeout => 2000}) of
        {ok, Status, _, _} when Status =:= 200; Status =:= 204 ->
            ok;
        Other ->
            {error, Other}
    end.

%% 托管或失败模式下：定时发送 eReconnectPort 消息并先关闭当前 port；
%% 其它模式（external/starting/disabled 等）直接返回原状态。
scheduleReconnect(State = #{mode := Mode}) when Mode =:= managed; Mode =:= failed ->
    erlang:send_after(?ReconnectMs, self(), eReconnectPort),
    closePort(State);
scheduleReconnect(State) ->
    State.

%% 关闭 port 句柄（吞掉异常）并将状态中的 port 置为 undefined、enabled 置为 false。
closePort(State = #{port := Port}) when is_port(Port) ->
    try erlang:port_close(Port) catch _:_ -> ok end,
    State#{port => undefined, enabled => false};
%% 无 port 句柄时仅清空 port 字段。
closePort(State) ->
    State#{port => undefined}.

%% 解析配置得到 Qdrant 二进制路径：经 code:priv_dir(ali) 定位 priv 根目录下的文件名。
qdrantBinary() ->
    Qdrant = alConfig:get(qdrant, #{}),
    Bin = maps:get(binary, Qdrant, qdrantBinaryName()),
    alConfig:resolvePrivBinary(Bin).

%% 根据操作系统返回 Qdrant 二进制文件名（Windows 为 qdrant.exe，其它为 qdrant）。
qdrantBinaryName() ->
    case os:type() of
        {win32, _} -> "qdrant.exe";
        _ -> "qdrant"
    end.

%% 解析配置得到 Qdrant storage 目录的绝对路径，默认 `<dataDir>/qdrant/storage`。
storagePath() ->
    Qdrant = alConfig:get(qdrant, #{}),
    case maps:get(storagePath, Qdrant, undefined) of
        undefined -> alConfig:dataPath("qdrant/storage");
        Path when is_list(Path); is_binary(Path) ->
            case filename:pathtype(toList(Path)) of
                relative -> alConfig:dataPath(Path);
                _ -> filename:absname(toList(Path))
            end
    end.

toList(V) when is_list(V) -> V;
toList(V) when is_binary(V) -> unicode:characters_to_list(V);
toList(V) -> lists:flatten(io_lib:format("~p", [V])).

%% 读取配置中的 Qdrant HTTP 端口，默认 6333。
httpPort() ->
    maps:get(httpPort, alConfig:get(qdrant, #{}), 6333).

%% 读取配置中的 Qdrant gRPC 端口，默认 6334。
grpcPort() ->
    maps:get(grpcPort, alConfig:get(qdrant, #{}), 6334).

%%--------------------------------------------------------------------
%% @doc
%% 将内部状态 map 转换为对外的状态描述 map（含 enabled/managed/mode/url 等）。
%%
%% @return 状态描述 map
%% @end
%%--------------------------------------------------------------------
statusMap(State) ->
    #{
        enabled => maps:get(enabled, State, false),
        managed => maps:get(mode, State, disabled) =:= managed,
        mode => maps:get(mode, State, disabled),
        url => maps:get(url, State, undefined),
        httpPort => maps:get(httpPort, State, undefined),
        storagePath => maps:get(storagePath, State, undefined),
        reason => maps:get(reason, State, undefined)
    }.

%% 去掉 URL 末尾的一个或多个斜杠。
trimTrailingSlash(Url) ->
    re:replace(Url, "/+$", "", [{return, list}, unicode]).
