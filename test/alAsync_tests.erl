-module(alAsync_tests).

-include_lib("eunit/include/eunit.hrl").

run_executes_job_test() ->
    Parent = self(),
    Pid = alAsync:run(testSuccess, fun() -> Parent ! asyncDone end),
    ?assert(is_pid(Pid)),
    receive
        asyncDone -> ok
    after 1000 ->
        ?assert(false)
    end.

run_contains_all_exception_classes_test() ->
    %% 这三条异常是测试输入，不应污染整套 EUnit 输出；过滤器只匹配
    %% 指定测试 label，生产任务以及其他测试的真实告警不受影响。
    FilterId = alAsyncExpectedCrashTest,
    ok = logger:add_primary_filter(
        FilterId, {fun suppressExpectedCrashLog/2, undefined}),
    try
        lists:foreach(fun({Label, Fun}) ->
            Pid = alAsync:run(Label, Fun),
            Ref = erlang:monitor(process, Pid),
            receive
                {'DOWN', Ref, process, Pid, normal} -> ok;
                {'DOWN', Ref, process, Pid, Reason} ->
                    ?assertEqual(normal, Reason)
            after 1000 ->
                ?assert(false)
            end
        end, [
            {asyncError, fun() -> erlang:error(testError) end},
            {asyncExit, fun() -> exit(testExit) end},
            {asyncThrow, fun() -> throw(testThrow) end}
        ])
    after
        ok = logger:remove_primary_filter(FilterId)
    end.

suppressExpectedCrashLog(#{meta := Meta}, _Extra) ->
    case maps:get(asyncJob, Meta, undefined) of
        Label when Label =:= asyncError; Label =:= asyncExit; Label =:= asyncThrow -> stop;
        _ -> ignore
    end;
suppressExpectedCrashLog(_Event, _Extra) ->
    ignore.
