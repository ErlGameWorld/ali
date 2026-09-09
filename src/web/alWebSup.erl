%%%-------------------------------------------------------------------
%% @doc Web 子系统 supervisor。
%%
%% 管理 alWebConnSup（HTTP/WS 连接 worker）与 alHttpGateway（eWSrv 监听）。
%% 任一子进程崩溃会独立重启，不影响其他 ali 顶层服务。
%% @end
%%%-------------------------------------------------------------------

-module(alWebSup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

-define(SERVER, ?MODULE).

%%--------------------------------------------------------------------
%% @doc
%% 创建并链接 Web 子系统 supervisor，注册为本地名 ?SERVER。
%%
%% @return {ok, Pid} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%--------------------------------------------------------------------
%% @doc
%% supervisor 初始化回调：管理两个子进程——alWebConnSup
%% （HTTP/WS 连接 supervisor）与 alHttpGateway（eWSrv 监听器）。
%% 采用 one_for_one 策略，任一子进程崩溃不会影响另一个，可被
%% 独立重启。
%%
%% @param [] 初始参数（空）
%% @return {ok, {SupFlags, ChildSpecs}}
%% @end
%%--------------------------------------------------------------------
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
            id => alHttpGateway,
            start => {alHttpGateway, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [alHttpGateway]
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.
