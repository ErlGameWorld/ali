%%% @doc Checkpoint path and persistence regression tests.
-module(alCheckpoint_tests).

-include_lib("eunit/include/eunit.hrl").

binary_task_id_path_test() ->
    ok = alConfig:load(),
    Path = alCheckpoint:path(<<"7">>),
    ?assert(is_list(Path)),
    ?assertEqual(".json", filename:extension(Path)),
    ?assertEqual("7.json", filename:basename(Path)).

list_task_id_path_test() ->
    ok = alConfig:load(),
    Path = alCheckpoint:path("task-abc"),
    ?assert(is_list(Path)),
    ?assertEqual("task-abc.json", filename:basename(Path)).

save_load_delete_binary_task_id_test() ->
    ok = alConfig:load(),
    TaskId = <<"eunit-checkpoint-path-regression">>,
    Continuation = #{
        messages => [#{role => user, content => <<"hello">>}],
        opts => #{},
        step => 1
    },
    ok = alCheckpoint:delete(TaskId),
    try
        {ok, Path} = alCheckpoint:save(TaskId, Continuation),
        ?assert(is_list(Path)),
        ?assert(filelib:is_regular(Path)),
        {ok, Loaded} = alCheckpoint:load(TaskId),
        ?assertEqual(1, maps:get(step, Loaded)),
        ?assertEqual([], maps:get(trace, Loaded, []))
    after
        ok = alCheckpoint:delete(TaskId)
    end.

%%%===================================================================
%%% 4: 恶意 taskId 路径净化（穿越防护）
%%%===================================================================

malicious_task_id_path_is_sanitized_test() ->
    ok = alConfig:load(),
    %% ../.. 与 / 均被净化，最终落在 checkpoints 目录内的安全文件名。
    Path = alCheckpoint:path(<<"../../evil">>),
    ?assert(is_list(Path)),
    ?assertEqual("evil.json", filename:basename(Path)),
    %% 净化结果不得包含任何 ".." 段
    ?assertNot(lists:member("..", filename:split(Path))).

dot_only_task_id_rejected_test() ->
    ok = alConfig:load(),
    %% 纯点/横线等净化后为空 → {error, invalidTaskId}，不写任何文件
    ?assertEqual({error, invalidTaskId}, alCheckpoint:path(<<"....">>)),
    ?assertEqual({error, invalidTaskId}, alCheckpoint:path(<<"">>)),
    ?assertEqual({error, invalidTaskId}, alCheckpoint:save(<<"....">>, #{
        messages => [], opts => #{}, step => 1})),
    ?assertEqual({error, invalidTaskId}, alCheckpoint:delete(<<"....">>)).

malicious_task_id_does_not_write_outside_dir_test() ->
    ok = alConfig:load(),
    Dir = alCheckpoint:path(<<"legit-eunit-base">>),
    _ = file:delete(Dir),
    ?assertEqual({error, enoent}, file:read_file(filename:join(
        filename:dirname(filename:dirname(Dir)), "evil.json"))),
    %% save 恶意 id：净化后只可能写 checkpoints/evil.json（合法文件），
    %% 不越界写父目录，且不抛异常。
    ok = alCheckpoint:delete(<<"../../evil">>),
    try
        {ok, P} = alCheckpoint:save(<<"../../evil">>, #{
            messages => [], opts => #{}, step => 1}),
        ?assertEqual("evil.json", filename:basename(P))
    after
        ok = alCheckpoint:delete(<<"../../evil">>)
    end.
