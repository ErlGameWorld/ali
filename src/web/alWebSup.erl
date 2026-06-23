%%%-------------------------------------------------------------------
%%% @doc Web 子系统监督者。
%%%
%%% 统一管理 {@link alWebConnSup}（HTTP/WS 连接 worker）与
%%% {@link alWebSrv}（HTTP 监听管理）。任一子进程崩溃时由本监督者
%%% 按 `one_for_one` 策略独立重启，不影响 ali 顶层其它服务。
%%% @end
%%%-------------------------------------------------------------------
-module(alWebSup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

-define(SERVER, ?MODULE).

%% @doc 启动 Web 监督者，注册名为 `alWebSup`。
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% @doc 初始化 Web 监督树。
-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 60
    },
    ChildSpecs = [
        #{
            id => alWebConnSup,
            start => {alWebConnSup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [alWebConnSup]
        },
        #{
            id => alWebSrv,
            start => {alWebSrv, startLink, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [alWebSrv]
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.
