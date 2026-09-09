%%%-------------------------------------------------------------------
%% @doc 每小时周期性归档器。
%%
%% 挂在 ali_sup 下。每小时调用 {@link alArchive:archiveNow/0} 并重设定时器。
%% 首次归档在启动后 60 秒，以便系统完成启动。
%% @end
%%%-------------------------------------------------------------------

-module(alArchiver).

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(IntervalMs, 60 * 60 * 1000).
-define(FirstDelayMs, 60 * 1000).
-define(SERVER, ?MODULE).

%%--------------------------------------------------------------------
%% @doc
%% 启动归档定时进程，注册本地名 ?SERVER。
%%
%% @return {ok, Pid} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% @doc
%% gen_server 初始化：建表（幂等）并安排首次归档。
%% @end
%%--------------------------------------------------------------------
init([]) ->
    process_flag(trap_exit, true),
    ok = alArchive:ensureSchema(),
    erlang:send_after(?FirstDelayMs, self(), archive),
    {ok, #{}}.

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @doc
%% 收到 `archive` 消息后执行一次归档并重新排队下一次。
%% @end
%%--------------------------------------------------------------------
handle_info(archive, State) ->
    case alArchive:archiveNow() of
        {ok, _} -> ok;
        {error, Reason} -> logger:warning("alArchiver: archive failed: ~p", [Reason])
    end,
    erlang:send_after(?IntervalMs, self(), archive),
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
