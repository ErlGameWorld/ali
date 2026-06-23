%%%-------------------------------------------------------------------
%%% @doc ali 应用的顶层监督者。
%%%
%%% 监督策略：`one_for_one`，子进程互不影响。
%%%
%%% 默认子进程：
%%% <ul>
%%%   <li>{@link alCodeIndexer} — 项目 .erl 代码索引</li>
%%%   <li>{@link alServer} — Agent 核心 gen_server</li>
%%%   <li>{@link alWebSup} — Web 子系统（连接监督 + HTTP 服务）</li>
%%% </ul>
%%%
%%% {@link alWebSrv} 在 {@link alWebSup} 下常驻启动；HTTP 监听仍由
%%% {@link alWebSrv:startWeb/0} 按需开启。
%%% @end
%%%-------------------------------------------------------------------
-module(ali_sup).

-behaviour(supervisor).

-export([start_link/0, startIndexer/0, init/1]).

-define(SERVER, ?MODULE).

%% @doc 启动监督者，注册名为 `ali_sup`。
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% @doc 动态添加代码索引器子进程（索引器通常已在 init/1 中启动，本函数供按需扩容）。
-spec startIndexer() -> supervisor:startchild_ret().
startIndexer() ->
    supervisor:start_child(?SERVER, #{
        id => alCodeIndexer,
        start => {alCodeIndexer, startLink, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [alCodeIndexer]
    }).

%% @doc 初始化监督树与子进程规格。
-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 60
    },
    ChildSpecs = [
        #{
            id => alCodeIndexer,
            start => {alCodeIndexer, startLink, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [alCodeIndexer]
        },
        #{
            id => alServer,
            start => {alServer, startLink, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [alServer]
        },
        #{
            id => alMcp,
            start => {alMcp, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [alMcp]
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