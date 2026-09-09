%%%-------------------------------------------------------------------
%% @doc 每会话执行 worker 的动态 supervisor。
%%%-------------------------------------------------------------------
-module(alSessionSup).

-behaviour(supervisor).

-export([start_link/0, ensure_worker/2, stop_worker/1, workers/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

ensure_worker(SessionId, InitOpts) ->
    ChildId = {session, SessionId},
    case child_pid(ChildId) of
        {ok, Pid} ->
            {ok, Pid};
        error ->
            Spec = #{
                id => ChildId,
                start => {alSessionWorker, start_link, [SessionId, InitOpts]},
                restart => transient,
                shutdown => 5000,
                type => worker,
                modules => [alSessionWorker]
            },
            case supervisor:start_child(?MODULE, Spec) of
                {ok, Pid} -> {ok, Pid};
                {ok, Pid, _Info} -> {ok, Pid};
                {error, {already_started, Pid}} -> {ok, Pid};
                {error, already_present} ->
                    _ = supervisor:restart_child(?MODULE, ChildId),
                    child_pid(ChildId);
                Error -> Error
            end
    end.

stop_worker(SessionId) ->
    ChildId = {session, SessionId},
    _ = supervisor:terminate_child(?MODULE, ChildId),
    supervisor:delete_child(?MODULE, ChildId).

workers() ->
    [{SessionId, Pid} ||
        {{session, SessionId}, Pid, worker, _} <- supervisor:which_children(?MODULE),
        is_pid(Pid)].

init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 10, period => 30}, []}}.

child_pid(ChildId) ->
    case lists:keyfind(ChildId, 1, supervisor:which_children(?MODULE)) of
        {ChildId, Pid, worker, _} when is_pid(Pid) -> {ok, Pid};
        _ -> error
    end.
