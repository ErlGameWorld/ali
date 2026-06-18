%%%-------------------------------------------------------------------
%%% @doc ali 应用的顶层监督者。
%%%
%%% 监督策略：`one_for_one`，子进程互不影响。
%%%
%%% 默认子进程：
%%% <ul>
%%%   <li>{@link alCodeIndexer} — 项目 .erl 代码索引</li>
%%%   <li>{@link alServer} — Agent 核心 gen_server</li>
%%% </ul>
%%%
%%% {@link alWebSrv} 不在此处静态启动，由 {@link alWebSrv:start_web/0}
%%% 按需动态添加为临时子进程。
%%% @end
%%%-------------------------------------------------------------------
-module(ali_sup).

-behaviour(supervisor).

-export([start_link/0, start_indexer/0, init/1]).

-define(SERVER, ?MODULE).

%% @doc 启动监督者，注册名为 `ali_sup`。
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% @doc 动态添加代码索引器子进程（索引器通常已在 init/1 中启动，本函数供按需扩容）。
-spec start_indexer() -> supervisor:startchild_ret().
start_indexer() ->
    supervisor:start_child(?SERVER, #{
        id => alCodeIndexer,
        start => {alCodeIndexer, start_link, []},
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
            start => {alCodeIndexer, start_link, []},
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
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.