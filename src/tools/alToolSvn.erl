%%%-------------------------------------------------------------------
%%% @doc 只读 SVN 集成工具。
%%%
%%% 在项目根目录执行只读 svn 命令（status / diff / log / info），
%%% 便于 Agent 审查改动、理解历史与工作副本信息。输出统一截断，
%%% 不修改仓库状态。命令在工作副本根目录（`projectRoot`）下执行。
%%%
%%% 安全说明：使用 `open_port({spawn_executable, ...})` 直接调用 svn
%%% 可执行文件并传参，绕过 shell，避免命令注入。`svnDiff` 的 `path`
%%% 参数经 `alToolProject:resolvePathForEdit` 沙箱校验；`revision`
%%% 仅允许数字与 SVN 修订关键字（BASE/HEAD 等）。
%%% @end
%%%-------------------------------------------------------------------
-module(alToolSvn).

-export([
    svnStatus/2,
    svnDiff/2,
    svnLog/2,
    svnInfo/2
]).

-define(MAX_OUTPUT, 12000).
-define(SVN_TIMEOUT, 30000).

%% @doc 工作副本状态。可选 `showUpdates`（true 时加 `-u` 显示服务器修订）。
-spec svnStatus(map(), map()) -> {ok, map()} | {error, term()}.
svnStatus(Args, Config) ->
    Extra = case truthy(maps:get(showUpdates, Args, false)) of
        true -> ["-u"];
        false -> []
    end,
    run(["status" | Extra], Config).

%% @doc 显示改动 diff。可选 `path`（限定路径）、`revision`（如 `123` 或 `BASE:HEAD`）。
-spec svnDiff(map(), map()) -> {ok, map()} | {error, term()}.
svnDiff(Args, Config) ->
    case revisionArgs(maps:get(revision, Args, undefined)) of
        {error, Reason} ->
            {error, Reason};
        RevArgs ->
            case maps:get(path, Args, undefined) of
                undefined ->
                    run(["diff"] ++ RevArgs, Config);
                P ->
                    Root = projectRoot(Config),
                    case alToolProject:resolvePathForEdit(Root, toList(P)) of
                        {ok, AbsPath} ->
                            run(["diff"] ++ RevArgs ++ [AbsPath], Config);
                        {error, Reason} ->
                            {error, #{path => toList(P), reason => Reason}}
                    end
            end
    end.

%% @doc 最近提交日志。可选 `limit`（默认 20）。
-spec svnLog(map(), map()) -> {ok, map()} | {error, term()}.
svnLog(Args, Config) ->
    N = integer_to_list(maps:get(limit, Args, 20)),
    run(["log", "-l", N], Config).

%% @doc 工作副本与仓库 URL、当前修订等元信息（对应 SVN 的「在哪、什么版本」）。
-spec svnInfo(map(), map()) -> {ok, map()} | {error, term()}.
svnInfo(_Args, Config) ->
    run(["info"], Config).

%%%===================================================================
%%% 内部
%%%===================================================================

revisionArgs(undefined) ->
    [];
revisionArgs(Rev) when is_integer(Rev), Rev >= 0 ->
    ["-r", integer_to_list(Rev)];
revisionArgs(Rev) ->
    case validateRevision(toList(Rev)) of
        {ok, S} -> ["-r", S];
        error -> {error, invalidRevision}
    end.

%% 仅允许 SVN 修订语法：数字、冒号、常见关键字。
validateRevision(S) ->
    case re:run(S, <<"^[0-9A-Za-z:_]+$"/utf8>>) of
        {match, _} -> {ok, S};
        nomatch -> error
    end.

run(Args, Config) ->
    Root = projectRoot(Config),
    case os:find_executable("svn") of
        false ->
            {error, #{svn => <<"svn executable not found"/utf8>>}};
        SvnExe ->
            case run_executable(SvnExe, Args, Root) of
                {ok, Output} ->
                    Bin = unicode:characters_to_binary(Output),
                    case isSvnError(Output) of
                        true ->
                            {error, #{svn => trim(Bin)}};
                        false ->
                            {Truncated, Body} = truncate(Bin),
                            CmdDisplay = iolist_to_binary(["svn" | [[" ", A] || A <- Args]]),
                            {ok, #{
                                command => CmdDisplay,
                                output => Body,
                                truncated => Truncated
                            }}
                    end;
                {error, Reason} ->
                    {error, #{svn => trim(unicode:characters_to_binary(Reason))}}
            end
    end.

run_executable(SvnExe, Args, Cwd) ->
    Port = open_port({spawn_executable, SvnExe}, [
        stream,
        exit_status,
        stderr_to_stdout,
        binary,
        {args, Args},
        {cd, Cwd}
    ]),
    collect_port(Port, <<>>, ?SVN_TIMEOUT).

collect_port(Port, Acc, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    collect_port_deadline(Port, Acc, Deadline).

collect_port_deadline(Port, Acc, Deadline) ->
    Now = erlang:monotonic_time(millisecond),
    case Deadline > Now of
        false ->
            port_close(Port),
            {error, <<"svn command timeout"/utf8>>};
        true ->
            Remaining = Deadline - Now,
            receive
                {Port, {data, Data}} ->
                    collect_port_deadline(Port, <<Acc/binary, Data/binary>>, Deadline);
                {Port, {exit_status, _Code}} ->
                    {ok, Acc}
            after Remaining ->
                port_close(Port),
                {error, <<"svn command timeout"/utf8>>}
            end
    end.

isSvnError(Output) when is_binary(Output) ->
    isSvnError(binary_to_list(Output));
isSvnError(Output) ->
    Lower = string:lowercase(Output),
    lists:any(fun(S) -> string:str(Lower, S) > 0 end,
              ["is not a working copy",
               "not a versioned resource",
               "svn: e",
               "svn: warning: w155010",
               "is not recognized",
               "command not found",
               "no such file or directory",
               "unable to open an ra_"]).

truncate(Bin) ->
    case byte_size(Bin) > ?MAX_OUTPUT of
        true -> {true, binary:part(Bin, 0, ?MAX_OUTPUT)};
        false -> {false, Bin}
    end.

trim(Bin) ->
    re:replace(Bin, "^\\s+|\\s+$", "", [global, {return, binary}]).

truthy(true) -> true;
truthy(<<"true"/utf8>>) -> true;
truthy("true") -> true;
truthy(_) -> false.

projectRoot(Config) ->
    case maps:get(projectRoot, Config, undefined) of
        undefined -> alToolProject:findProjectRootFromModule();
        Root when is_binary(Root) -> binary_to_list(Root);
        Root when is_list(Root) -> Root
    end.

toList(X) when is_binary(X) -> binary_to_list(X);
toList(X) when is_list(X) -> X;
toList(X) when is_atom(X) -> atom_to_list(X).
