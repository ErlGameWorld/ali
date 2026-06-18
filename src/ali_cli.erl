%%%-------------------------------------------------------------------
%%% @doc ali 命令行入口（escript）。
%%%
%%% 用法：
%%%   rebar3 escriptize && ./_build/default/bin/ali ask "问题"
%%%   ali chat
%%%   ali status
%%% @end
%%%-------------------------------------------------------------------
-module(ali_cli).

-export([main/1]).

main([]) ->
    usage(),
    halt(1);
main(["help" | _]) ->
    usage(),
    halt(0);
main(["ask", Prompt]) ->
    with_app(fun() ->
        case ali:ask(Prompt) of
            {ok, Answer} ->
                io:format("~ts~n", [Answer]),
                halt(0);
            {error, Reason} ->
                io:format(standard_error, "error: ~p~n", [Reason]),
                halt(1)
        end
    end);
main(["ask", Prompt | Rest]) ->
    Opts = parse_opts(Rest, #{}),
    with_app(fun() ->
        case ali:ask(Prompt, Opts) of
            {ok, Answer} ->
                io:format("~ts~n", [Answer]),
                halt(0);
            {error, Reason} ->
                io:format(standard_error, "error: ~p~n", [Reason]),
                halt(1)
        end
    end);
main(["chat" | Rest]) ->
    Opts = parse_opts(Rest, #{}),
    with_app(fun() ->
        case ali:chat(Opts) of
            ok -> halt(0);
            {error, Reason} ->
                io:format(standard_error, "error: ~p~n", [Reason]),
                halt(1)
        end
    end);
main(["approve", TaskId]) ->
    with_app(fun() ->
        case ali:approve(TaskId) of
            {ok, Result} ->
                io:format("~p~n", [Result]),
                halt(0);
            {error, Reason} ->
                io:format(standard_error, "error: ~p~n", [Reason]),
                halt(1)
        end
    end);
main(["status"]) ->
    with_app(fun() ->
        io:format("~p~n", [ali:status()]),
        halt(0)
    end);
main(["tools"]) ->
    with_app(fun() ->
        io:format("~p~n", [ali:tools()]),
        halt(0)
    end);
main(["tasks"]) ->
    with_app(fun() ->
        io:format("~p~n", [ali:tasks()]),
        halt(0)
    end);
main(["config"]) ->
    with_app(fun() ->
        io:format("~ts~n", [ali:formatAgentConfig()]),
        halt(0)
    end);
main(["refresh"]) ->
    with_app(fun() ->
        case ali:refreshIndex() of
            {ok, R} ->
                io:format("索引已刷新: ~p~n", [R]),
                halt(0);
            {error, Reason} ->
                io:format(standard_error, "refresh failed: ~p~n", [Reason]),
                halt(1)
        end
    end);
main(["sessions"]) ->
    with_app(fun() ->
        case ali:savedSessions() of
            Sessions when is_list(Sessions) ->
                io:format("已保存的会话 (~p):~n", [length(Sessions)]),
                lists:foreach(fun(S) -> io:format("  - ~ts~n", [S]) end, Sessions),
                halt(0);
            {error, Reason} ->
                io:format(standard_error, "error: ~p~n", [Reason]),
                halt(1)
        end
    end);
main(["web"]) ->
    with_app(fun() ->
        case ali:startWeb() of
            {ok, Port} ->
                io:format("Web UI 已启动: http://127.0.0.1:~p/~n", [Port]),
                halt(0);
            {error, Reason} ->
                io:format(standard_error, "web start failed: ~p~n", [Reason]),
                halt(1)
        end
    end);
main(["web", "stop"]) ->
    with_app(fun() ->
        ok = ali:stopWeb(),
        io:format("Web UI 已停止。~n"),
        halt(0)
    end);
main(["health"]) ->
    with_app(fun() ->
        io:format("~p~n", [ali:health()]),
        halt(0)
    end);
main(_) ->
    usage(),
    halt(1).

with_app(Fun) ->
    application:ensure_all_started(ali),
    ali:llmLoadConfig(),
    ali:loadConfigFromEnv(),
    case ali:start() of
        {ok, _} -> Fun();
        {error, Reason} ->
            io:format(standard_error, "start failed: ~p~n", [Reason]),
            halt(1)
    end.

parse_opts([], Acc) -> Acc;
parse_opts(["--session", Sid | Rest], Acc) ->
    parse_opts(Rest, Acc#{sessionId => list_to_binary(Sid)});
parse_opts(["--mode", Mode | Rest], Acc) ->
    parse_opts(Rest, Acc#{mode => list_to_existing_atom(Mode)});
parse_opts([_ | Rest], Acc) ->
    parse_opts(Rest, Acc).

usage() ->
    io:format(
        "ali — Erlang 节点内 AI 开发助手~n~n"
        "用法:~n"
        "  ali ask \"问题\" [--session ID] [--mode ask|edit|exec]~n"
        "  ali chat [--session ID] [--mode ask|edit|exec]~n"
        "  ali approve <taskId>~n"
        "  ali status | tools | tasks | config | health~n"
        "  ali refresh            刷新代码索引~n"
        "  ali sessions           列出已保存会话~n"
        "  ali web [stop]         启动/停止 Web UI~n"
        "  ali help~n"
    ).