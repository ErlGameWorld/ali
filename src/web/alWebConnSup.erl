%%%-------------------------------------------------------------------
%% @doc HTTP/WebSocket 连接 supervisor。
%%
%% eWSrv 通过 wsSupName 选项使用本 supervisor，为每个入站 TCP 连接
%% 派生一个 wsHttp worker。worker 为 temporary——退出后不重启。
%% @end
%%%-------------------------------------------------------------------

-module(alWebConnSup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

-define(SERVER, ?MODULE).

%%--------------------------------------------------------------------
%% @doc
%% 创建并链接 HTTP/WebSocket 连接 supervisor，注册为本地名 ?SERVER。
%%
%% @return {ok, Pid} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%--------------------------------------------------------------------
%% @doc
%% supervisor 初始化回调：使用 simple_one_for_one 策略，为每个
%% 接入的 TCP 连接动态启动一个 wsHttp worker。worker 为 temporary
%% 类型，退出后不重启；intensity=100/period=3600 防止连接风暴时
%% 触发 supervisor 自身终止。
%%
%% @param [] 初始参数（空）
%% @return {ok, {SupFlags, ChildSpecs}}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 100,
        period => 3600
    },
    ChildSpecs = [
        #{
            id => wsHttp,
            start => {wsHttp, start_link, []},
            restart => temporary,
            shutdown => brutal_kill,
            type => worker,
            modules => [wsHttp]
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.
