%%%-------------------------------------------------------------------
%%% @doc 只读 Git 集成工具。
%%%
%%% 在项目根目录执行只读 git 命令（status / diff / log / branch），
%%% 便于 Agent 审查改动、生成提交信息或理解历史。输出统一截断，
%%% 不修改仓库状态。命令通过 `git -C <projectRoot>` 定位仓库。
%%%
%%% 安全说明：使用 `open_port({spawn_executable, ...})` 直接调用 git
%%% 可执行文件并传参，绕过 shell，避免命令注入。`gitDiff` 的 `path`
%%% 参数经 `alToolProject:resolvePathForEdit` 沙箱校验，确保不越界。
%%% @end
%%%-------------------------------------------------------------------
-module(alToolGit).

-export([
    gitStatus/2,
    gitDiff/2,
    gitLog/2,
    gitBranch/2
]).

-define(MAX_OUTPUT, 12000).
-define(GIT_TIMEOUT, 30000).

%% @doc 工作区状态（精简格式，含分支信息）。
-spec gitStatus(map(), map()) -> {ok, map()} | {error, term()}.
gitStatus(_Args, Config) ->
    run(["status", "--short", "--branch"], Config).

%% @doc 显示改动 diff。可选 `path`（限定文件）、`staged`（查看已暂存改动）。
%% `path` 经沙箱校验确保位于项目根目录内，防止路径越界。
-spec gitDiff(map(), map()) -> {ok, map()} | {error, term()}.
gitDiff(Args, Config) ->
    Staged = case truthy(maps:get(staged, Args, false)) of
        true -> ["--cached"];
        false -> []
    end,
    case maps:get(path, Args, undefined) of
        undefined ->
            run(["diff", "--stat"] ++ Staged, Config);
        P ->
            Root = projectRoot(Config),
            case alToolProject:resolvePathForEdit(Root, toList(P)) of
                {ok, AbsPath} ->
                    run(["diff", "--stat"] ++ Staged ++ ["--", AbsPath], Config);
                {error, Reason} ->
                    {error, #{path => toList(P), reason => Reason}}
            end
    end.

%% @doc 最近提交日志（单行）。可选 `limit`（默认 20）。
-spec gitLog(map(), map()) -> {ok, map()} | {error, term()}.
gitLog(Args, Config) ->
    N = integer_to_list(maps:get(limit, Args, 20)),
    run(["log", "--oneline", "--decorate", "-n", N], Config).

%% @doc 列出本地与远程分支及其跟踪信息。
-spec gitBranch(map(), map()) -> {ok, map()} | {error, term()}.
gitBranch(_Args, Config) ->
    run(["branch", "-vv", "--all"], Config).

%%%===================================================================
%%% 内部
%%%===================================================================

%% 在项目根目录执行只读 git 命令并返回截断后的输出。
%% 使用 open_port({spawn_executable, ...}) 直接调用 git，绕过 shell，
%% 避免命令注入风险。
run(Args, Config) ->
    Root = projectRoot(Config),
    GitArgs = ["-C", Root] ++ Args,
    case os:find_executable("git") of
        false ->
            {error, #{git => <<"git executable not found"/utf8>>}};
        GitExe ->
            case run_executable(GitExe, GitArgs, Root) of
                {ok, Output} ->
                    Bin = unicode:characters_to_binary(Output),
                    case isGitError(Output) of
                        true ->
                            {error, #{git => trim(Bin)}};
                        false ->
                            {Truncated, Body} = truncate(Bin),
                            CmdDisplay = iolist_to_binary(["git" | [[" ", A] || A <- Args]]),
                            {ok, #{
                                command => CmdDisplay,
                                output => Body,
                                truncated => Truncated
                            }}
                    end;
                {error, Reason} ->
                    {error, #{git => trim(unicode:characters_to_binary(Reason))}}
            end
    end.

%% 通过 open_port 直接执行 git 可执行文件，收集输出。
run_executable(GitExe, Args, Cwd) ->
    Port = open_port({spawn_executable, GitExe}, [
        stream,
        exit_status,
        stderr_to_stdout,
        binary,
        {args, Args},
        {cd, Cwd}
    ]),
    collect_port(Port, <<>>, ?GIT_TIMEOUT).

%% 按截止时间从 port 收集输出直至 exit_status 或超时。
collect_port(Port, Acc, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    collect_port_deadline(Port, Acc, Deadline).

collect_port_deadline(Port, Acc, Deadline) ->
    Now = erlang:monotonic_time(millisecond),
    case Deadline > Now of
        false ->
            port_close(Port),
            {error, <<"git command timeout"/utf8>>};
        true ->
            Remaining = Deadline - Now,
            receive
                {Port, {data, Data}} ->
                    collect_port_deadline(Port, <<Acc/binary, Data/binary>>, Deadline);
                {Port, {exit_status, Code}} when Code =:= 0 ->
                    {ok, Acc};
                {Port, {exit_status, _Code}} ->
                    {ok, Acc}
            after Remaining ->
                port_close(Port),
                {error, <<"git command timeout"/utf8>>}
            end
    end.

%% 判断 git 输出是否为致命错误（非仓库 / 未安装）。
isGitError(Output) when is_binary(Output) ->
    isGitError(binary_to_list(Output));
isGitError(Output) ->
    Lower = string:lowercase(Output),
    lists:any(fun(S) -> string:str(Lower, S) > 0 end,
              ["not a git repository",
               "fatal: ",
               "is not recognized",
               "command not found",
               "no such file or directory"]).

%% 截断过长输出。
truncate(Bin) ->
    case byte_size(Bin) > ?MAX_OUTPUT of
        true -> {true, binary:part(Bin, 0, ?MAX_OUTPUT)};
        false -> {false, Bin}
    end.

%% 去除首尾空白。
trim(Bin) ->
    re:replace(Bin, "^\\s+|\\s+$", "", [global, {return, binary}]).

truthy(true) -> true;
truthy(<<"true"/utf8>>) -> true;
truthy("true") -> true;
truthy(_) -> false.

%% 从配置解析项目根（绝对路径）。
projectRoot(Config) ->
    case maps:get(projectRoot, Config, undefined) of
        undefined -> alToolProject:findProjectRootFromModule();
        Root when is_binary(Root) -> binary_to_list(Root);
        Root when is_list(Root) -> Root
    end.

toList(X) when is_binary(X) -> binary_to_list(X);
toList(X) when is_list(X) -> X;
toList(X) when is_atom(X) -> atom_to_list(X).
