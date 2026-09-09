%%%-------------------------------------------------------------------
%%% @doc Erlang port 的 OS 进程辅助（尤其 Windows 清理）。
%%%
%%% 在 Windows 上，`erlang:port_close/1` 往往**不会**结束已派生可执行文件；
%%% `aliCore.exe` / `qdrant.exe` 等可能残留。本模块先关 port，必要时再按
%%% OS PID 强制杀掉。
%%% @end
%%%-------------------------------------------------------------------
-module(alOsProc).

-export([
    osPid/1,
    closePort/1,
    closeAndKill/1,
    closeAndKill/2,
    forceKill/1
]).

%%--------------------------------------------------------------------
%% @doc Read OS process id of a port, or `undefined'.
%% @end
%%--------------------------------------------------------------------
-spec osPid(port() | term()) -> pos_integer() | undefined.
osPid(Port) when is_port(Port) ->
    try erlang:port_info(Port, os_pid) of
        {os_pid, Pid} when is_integer(Pid), Pid > 0 -> Pid;
        _ -> undefined
    catch
        _:_ -> undefined
    end;
osPid(_) ->
    undefined.

%%--------------------------------------------------------------------
%% @doc Close an Erlang port (ignore errors). Does not guarantee OS exit.
%% @end
%%--------------------------------------------------------------------
-spec closePort(port() | term()) -> ok.
closePort(Port) when is_port(Port) ->
    try erlang:port_close(Port) catch _:_ -> ok end,
    ok;
closePort(_) ->
    ok.

%%--------------------------------------------------------------------
%% @doc Close port and force-kill its OS process (process tree on Windows).
%% @end
%%--------------------------------------------------------------------
-spec closeAndKill(port() | term()) -> ok.
closeAndKill(Port) when is_port(Port) ->
    closeAndKill(Port, osPid(Port));
closeAndKill(_) ->
    ok.

%%--------------------------------------------------------------------
%% @doc Close port; force-kill only when needed.
%% Unix: port_close → stdin EOF is enough; no SIGTERM on the hot path.
%% Windows: orphans are common, so force-kill after a short grace.
%% @end
%%--------------------------------------------------------------------
-spec closeAndKill(port() | undefined | term(), pos_integer() | undefined) -> ok.
closeAndKill(Port, OsPid) ->
    closePort(Port),
    case {os:type(), OsPid} of
        {{win32, _}, Pid} when is_integer(Pid), Pid > 0 ->
            timer:sleep(150),
            forceKill(Pid);
        {_, Pid} when is_integer(Pid), Pid > 0 ->
            %% Unix: wait briefly for EOF exit; only kill if still alive.
            timer:sleep(300),
            case isAlive(Pid) of
                true -> forceKill(Pid);
                false -> ok
            end;
        _ ->
            ok
    end.

%% Best-effort: is OS pid still running?
isAlive(Pid) when is_integer(Pid), Pid > 0 ->
    case os:type() of
        {win32, _} ->
            %% tasklist is heavy; assume alive and let forceKill no-op if gone.
            true;
        _ ->
            %% kill -0 returns success if process exists
            Cmd = lists:flatten(io_lib:format("kill -0 ~w 2>/dev/null", [Pid])),
            try
                Port = open_port({spawn, "/bin/sh -c \"" ++ Cmd ++ "\""}, [exit_status]),
                receive
                    {Port, {exit_status, 0}} -> true;
                    {Port, {exit_status, _}} -> false
                after 1000 ->
                    try erlang:port_close(Port) catch _:_ -> ok end,
                    true
                end
            catch
                _:_ -> true
            end
    end;
isAlive(_) ->
    false.

%%--------------------------------------------------------------------
%% @doc Force-kill an OS process. Windows uses `taskkill /F /T` (tree).
%% @end
%%--------------------------------------------------------------------
-spec forceKill(pos_integer() | undefined) -> ok.
forceKill(Pid) when is_integer(Pid), Pid > 0 ->
    case os:type() of
        {win32, _} ->
            %% Avoid os:cmd/1 — it can hang on some Windows setups.
            Cmd = lists:flatten(io_lib:format(
                "cmd /c taskkill /F /T /PID ~w", [Pid])),
            try
                Port = open_port({spawn, Cmd}, [hide, exit_status]),
                receive
                    {Port, {exit_status, _}} -> ok
                after 3000 ->
                    try erlang:port_close(Port) catch _:_ -> ok end,
                    ok
                end
            catch
                _:_ -> ok
            end;
        _ ->
            Cmd = lists:flatten(io_lib:format(
                "kill -TERM ~w 2>/dev/null; sleep 0.15; "
                "kill -KILL ~w 2>/dev/null", [Pid, Pid])),
            try
                Port = open_port({spawn, "/bin/sh -c \"" ++ Cmd ++ "\""},
                                 [exit_status]),
                receive
                    {Port, {exit_status, _}} -> ok
                after 3000 ->
                    try erlang:port_close(Port) catch _:_ -> ok end,
                    ok
                end
            catch
                _:_ -> ok
            end
    end;
forceKill(_) ->
    ok.
