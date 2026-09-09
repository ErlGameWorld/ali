%%% @doc EUnit tests for alOsProc helpers.
-module(alOsProc_tests).

-include_lib("eunit/include/eunit.hrl").

os_pid_non_port_test() ->
    ?assertEqual(undefined, alOsProc:osPid(undefined)),
    ?assertEqual(undefined, alOsProc:osPid(not_a_port)).

close_port_non_port_test() ->
    ?assertEqual(ok, alOsProc:closePort(undefined)),
    ?assertEqual(ok, alOsProc:closeAndKill(undefined)),
    ?assertEqual(ok, alOsProc:forceKill(undefined)).

force_kill_invalid_pid_test() ->
    %% Only assert the undefined clause; do not taskkill random system PIDs.
    ?assertEqual(ok, alOsProc:forceKill(undefined)),
    ?assertEqual(ok, alOsProc:forceKill(0)).
