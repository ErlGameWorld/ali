%%%-------------------------------------------------------------------
%% @doc 轻量后台任务启动器。
%%
%% fire-and-forget 任务不能把异常静默丢掉。所有 error/exit/throw 都在
%% 子进程边界记录，调用方仍立即获得 pid，不被后台失败拖垮。
%% @end
%%%-------------------------------------------------------------------
-module(alAsync).

-export([run/1, run/2]).

-spec run(fun(() -> term())) -> pid().
run(Fun) ->
    run(backgroundJob, Fun).

-spec run(term(), fun(() -> term())) -> pid().
run(Label, Fun) when is_function(Fun, 0) ->
    spawn(fun() ->
        try
            _ = Fun(),
            ok
        catch
            Class:Reason:Stack ->
                logger:warning(
                    "background job ~p crashed: ~p:~p stack=~p",
                    [Label, Class, Reason, lists:sublist(Stack, 8)],
                    #{domain => [ali, async], asyncJob => Label})
        end
    end).
