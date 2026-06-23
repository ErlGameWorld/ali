%%%-------------------------------------------------------------------
%%% @doc Web HTTP/WebSocket 连接监督者。
%%%
%%% eWSrv 在 `wsSupName` 指定本监督者时，每个 TCP 连接以
%%% {@link wsHttp} worker 动态挂在其下（`simple_one_for_one`）。
%%% @end
%%%-------------------------------------------------------------------
-module(alWebConnSup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

-define(SERVER, ?MODULE).

%% @doc 启动连接监督者，注册名为 `alWebConnSup`。
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% @doc 初始化 `simple_one_for_one` 监督树，子进程模板为 wsHttp。
-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
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
