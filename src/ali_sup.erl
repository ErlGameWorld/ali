%%%-------------------------------------------------------------------
%% @doc ali 顶层 supervisor。
%% @end
%%%-------------------------------------------------------------------

-module(ali_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

%%--------------------------------------------------------------------
%% @doc
%% 创建并链接顶层 supervisor 进程，注册为本地名 ?SERVER。
%%
%% @return {ok, Pid} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%--------------------------------------------------------------------
%% @doc
%% supervisor 初始化回调：定义重启策略（one_for_one，5 次/10 秒）
%% 与所有子进程规格。启动顺序：alQdrant → alLocalDb →
%% alSessionMgr → alCoreClient → alServer →
%% alWebSup。Web 子系统最后启动，确保其依赖的 session_mgr
%% 与 alServer 已就绪。
%%
%% @param [] 初始参数（空）
%% @return {ok, {SupFlags, ChildSpecs}}
%% @end
%%--------------------------------------------------------------------
%% sup_flags() = #{strategy => strategy(),         % optional
%%                 intensity => non_neg_integer(), % optional
%%                 period => pos_integer()}        % optional
%% child_spec() = #{id => child_id(),       % mandatory
%%                  start => mfargs(),      % mandatory
%%                  restart => restart(),   % optional
%%                  shutdown => shutdown(), % optional
%%                  type => worker(),       % optional
%%                  modules => modules()}   % optional
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },
    %% alEtsOwner 最先启动：作为公共 ETS 表（plan/token/patch 事务/
    %% audit/metrics/progress/task）的长生命周期属主，避免短命 agent
    %% worker 建表后退出导致这些表被销毁、状态静默丢失。
    %% Web 最后启动：HTTP/WS 依赖 session_mgr + alServer。
    ChildSpecs = [
        #{
            id => alEtsOwner,
            start => {alEtsOwner, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [alEtsOwner]
        },
        #{
            id => alQdrant,
            start => {alQdrant, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [alQdrant]
        },
        #{
            id => alLocalDb,
            start => {alLocalDb, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [alLocalDb]
        },
        #{
            id => alSessionMgr,
            start => {alSessionMgr, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [alSessionMgr]
        },
        #{
            id => alCoreClient,
            start => {alCoreClient, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [alCoreClient]
        },
        %% alFileWatcher 默认 ignore（fileWatchEnabled=false 时）；
        %% 启用时监听源文件 mtime 变化，触发异步重索引。
        #{
            id => alFileWatcher,
            start => {alFileWatcher, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [alFileWatcher]
        },
        #{
            id => alSessionSup,
            start => {alSessionSup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [alSessionSup]
        },
        #{
            id => alPending,
            start => {alPending, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [alPending]
        },
        #{
            id => alServer,
            start => {alServer, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [alServer]
        },
        #{
            id => alArchiver,
            start => {alArchiver, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [alArchiver]
        },
        #{
            id => alWebSup,
            start => {alWebSup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [alWebSup]
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.

%% internal functions
