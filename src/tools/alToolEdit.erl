%%%-------------------------------------------------------------------
%%% @doc 文件编辑与编译加载工具集。
%%%
%%% 提供写文件、文本补丁、编译加载、回滚及对应预览（diff）操作。
%%% 写操作前可选备份，成功后异步刷新代码索引。路径解析与沙箱校验
%%% 委托 {@link alToolProject}。
%%% @end
%%%-------------------------------------------------------------------
-module(alToolEdit).

-export([
    writeFile/2,
    patchFile/2,
    compileLoad/2,
    rollbackFile/2,
    formatCode/2,
    listBackups/2,
    sessionUndo/2,
    previewWrite/2,
    previewPatch/2,
    previewCompileLoad/2
]).

%% @doc 将内容写入项目内文件；`backup` 默认为 true 时先备份原文件。
-spec writeFile(map(), map()) -> {ok, map()} | {error, term()}.
writeFile(Args, Config) ->
    Path = maps:get(path, Args, undefined),
    Content = maps:get(content, Args, undefined),
    Backup = maps:get(backup, Args, true),
    case {Path, Content} of
        {undefined, _} -> {error, missingPath};
        {_, undefined} -> {error, missingContent};
        _ ->
            case alToolProject:resolvePathForEdit(projectRoot(Config), Path) of
                {ok, AbsPath} ->
                    maybe_backup(AbsPath, Backup, Config),
                    case file:write_file(AbsPath, toBinary(Content)) of
                        ok ->
                            _ = maybe_reindex(Config),
                            {ok, #{
                                path => AbsPath,
                                bytesWritten => byte_size(toBinary(Content)),
                                action => write,
                                backedUp => Backup
                            }};
                        {error, Reason} -> {error, Reason}
                    end;
                {error, Reason} -> {error, Reason}
            end
    end.

%% @doc 在文件中替换 `oldText` 为 `newText` 后写回。
%%
%% 默认要求 `oldText` 在文件中唯一匹配：若出现多次，返回
%% `{error, #{reason => ambiguousMatch, ...}}'，提示补充上下文，
%% 避免误伤其它同名文本。传入 `replaceAll => true' 可强制全局替换。
-spec patchFile(map(), map()) -> {ok, map()} | {error, term()}.
patchFile(Args, Config) ->
    Path = maps:get(path, Args, undefined),
    OldText = maps:get(oldText, Args, undefined),
    NewText = maps:get(newText, Args, undefined),
    Backup = maps:get(backup, Args, true),
    ReplaceAll = maps:get(replaceAll, Args, false),
    case {Path, OldText, NewText} of
        {undefined, _, _} -> {error, missingPath};
        {_, undefined, _} -> {error, missingOldText};
        {_, _, undefined} -> {error, missingNewText};
        _ ->
            case alToolProject:readFile(#{path => Path}, Config) of
                {ok, #{content := Content}} ->
                    OldBin = toBinary(OldText),
                    NewBin = toBinary(NewText),
                    case binary:match(Content, OldBin) of
                        nomatch -> {error, oldTextNotFound};
                        _ ->
                            Count = countOccurrences(Content, OldBin),
                            case Count > 1 andalso ReplaceAll =/= true of
                                true ->
                                    {error, #{
                                        reason => ambiguousMatch,
                                        matchCount => Count,
                                        hint => <<"oldText 在文件中出现多次；请补充上下文使其唯一，或传入 replaceAll=true 强制全部替换"/utf8>>
                                    }};
                                false ->
                                    Patched = binary:replace(Content, OldBin, NewBin, [global]),
                                    case writeFile(#{path => Path, content => Patched, backup => Backup}, Config) of
                                        {ok, R} -> {ok, R#{action => patch, replacements => Count}};
                                        Err -> Err
                                    end
                            end
                    end;
                {error, Reason} -> {error, Reason}
            end
    end.

%% @doc 编译指定路径或已加载模块的源码并热加载到运行时。
-spec compileLoad(map(), map()) -> {ok, map()} | {error, term()}.
compileLoad(Args, Config) ->
    Path = maps:get(path, Args, undefined),
    Module = maps:get(module, Args, undefined),
    case Path of
        undefined -> compile_by_module(Module, Config);
        _ -> compile_by_path(Path, Module, Config)
    end.

%% 按绝对路径编译 .erl 并加载生成的 beam。
compile_by_path(Path, Module, Config) ->
    case alToolProject:resolvePathForEdit(projectRoot(Config), Path) of
        {ok, AbsPath} ->
            Mod = resolve_module(Module, AbsPath),
            OutDir = outdir_for(AbsPath, Config),
            ok = filelib:ensure_dir(filename:join(OutDir, "x")),
            Opts = [return, report_errors, debug_info, {outdir, OutDir}],
            case filelib:is_file(AbsPath) of
                false -> {error, fileNotFound};
                true ->
                    case compile:file(AbsPath, Opts) of
                        {ok, Mod} ->
                            load_compiled_module(Mod, OutDir);
                        {ok, Mod, _Warnings} ->
                            load_compiled_module(Mod, OutDir);
                        {error, Errors, _Warnings} ->
                            {error, #{compileErrors => format_errors(Errors)}}
                    end
            end;
        {error, Reason} -> {error, Reason}
    end.

%% 根据已加载模块反查源码路径再编译。
compile_by_module(undefined, _Config) ->
    {error, missingPathOrModule};
compile_by_module(Module, Config) ->
    Mod = to_atom(Module),
    case code:which(Mod) of
        Beam when is_list(Beam) ->
            Src = beam_to_src(Beam, Mod),
            case Src of
                {ok, SrcPath} ->
                    compile_by_path(SrcPath, Mod, Config);
                _ -> {error, sourceNotFound}
            end;
        _ -> {error, moduleNotLoaded}
    end.

%% purge 后从 outdir 或 code path 加载编译结果。
load_compiled_module(Mod, OutDir) ->
    Beam = filename:join(OutDir, atom_to_list(Mod) ++ ".beam"),
    case filelib:is_file(Beam) of
        true ->
            code:purge(Mod),
            case code:load_abs(filename:join(OutDir, atom_to_list(Mod))) of
                {module, Mod} ->
                    {ok, #{
                        module => Mod,
                        beam => Beam,
                        loaded => true,
                        action => compileLoad
                    }};
                {error, Reason} ->
                    {error, Reason}
            end;
        false ->
            code:purge(Mod),
            case code:load_file(Mod) of
                {module, Mod} ->
                    {ok, #{module => Mod, loaded => true, action => compileLoad}};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

%% @doc 从备份恢复文件；`backupId` 为 latest 时恢复最近一次备份。
-spec rollbackFile(map(), map()) -> {ok, map()} | {error, term()}.
rollbackFile(Args, Config) ->
    Path = maps:get(path, Args, undefined),
    BackupId = maps:get(backupId, Args, latest),
    case Path of
        undefined -> {error, missingPath};
        _ ->
            case alToolProject:resolvePathForEdit(projectRoot(Config), Path) of
                {ok, AbsPath} ->
                    case BackupId of
                        latest ->
                            case alBackup:restore_latest(AbsPath) of
                                ok -> {ok, #{path => AbsPath, restored => latest}};
                                {error, R} -> {error, R}
                            end;
                        Id ->
                            Backups = alBackup:list_backups(AbsPath),
                            case find_backup(Backups, Id) of
                                {ok, BP} ->
                                    case alBackup:restore(BP) of
                                        ok -> {ok, #{path => AbsPath, restored => Id}};
                                        {error, R} -> {error, R}
                                    end;
                                {error, R} -> {error, R}
                            end
                    end;
                {error, Reason} -> {error, Reason}
            end
    end.

%% @doc 格式化项目内源码文件（原地覆盖，可选备份）。
%% `.erl'/`.hrl' 用 erl_tidy；`.ex'/`.exs' 用 `mix format'；其他扩展名返回 {error, unsupportedFileType}。
-spec formatCode(map(), map()) -> {ok, map()} | {error, term()}.
formatCode(Args, Config) ->
    Path = maps:get(path, Args, undefined),
    Backup = maps:get(backup, Args, true),
    case Path of
        undefined -> {error, missingPath};
        _ ->
            case filename:extension(toList(Path)) of
                Ext when Ext =:= ".erl"; Ext =:= ".hrl" ->
                    format_erl_file(Path, Backup, Config);
                Ext when Ext =:= ".ex"; Ext =:= ".exs" ->
                    format_ex_file(Path, Backup, Config);
                _ ->
                    {error, unsupportedFileType}
            end
    end.

%% 使用 `mix format` 格式化 Elixir 文件（原地覆盖，可选备份）。
%% 需要环境中存在 mix；不可用时返回 {error, mixUnavailable}。
format_ex_file(Path, Backup, Config) ->
    case alToolProject:resolvePathForEdit(projectRoot(Config), Path) of
        {ok, AbsPath} ->
            case filelib:is_file(AbsPath) of
                false -> {error, fileNotFound};
                true ->
                    case os:find_executable("mix") of
                        false ->
                            {error, mixUnavailable};
                        Mix ->
                            maybe_backup(AbsPath, Backup, Config),
                            run_mix_format(Mix, AbsPath, Backup, Config)
                    end
            end;
        {error, Reason} -> {error, Reason}
    end.

run_mix_format(Mix, AbsPath, Backup, Config) ->
    Port = open_port({spawn_executable, Mix},
        [binary, exit_status, hide, stream,
         {args, ["format", AbsPath]},
         {cd, binary_to_list(iolist_to_binary(projectRoot(Config)))}]),
    case collect_port(Port, <<>>) of
        {0, _Out} ->
            _ = maybe_reindex(Config),
            {ok, #{path => AbsPath, action => formatCode, backedUp => Backup, formatter => <<"mix format"/utf8>>}};
        {Code, Out} ->
            {error, #{reason => mixFormatFailed, exitCode => Code, output => Out}}
    end.

%% 收集端口输出直至进程退出，返回 {ExitCode, Output}。
collect_port(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect_port(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, Code}} -> {Code, Acc}
    after 60000 ->
        try port_close(Port) catch _:_ -> ok end,
        {timeout, Acc}
    end.

%% 实际执行 erl_tidy 格式化并写回文件。
format_erl_file(Path, Backup, Config) ->
    case alToolProject:resolvePathForEdit(projectRoot(Config), Path) of
        {ok, AbsPath} ->
            case filelib:is_file(AbsPath) of
                false -> {error, fileNotFound};
                true ->
                    maybe_backup(AbsPath, Backup, Config),
                    case do_format_erl(AbsPath) of
                        {ok, Formatter} ->
                            _ = maybe_reindex(Config),
                            {ok, #{
                                path => AbsPath,
                                action => formatCode,
                                backedUp => Backup,
                                formatter => Formatter
                            }};
                        {error, Reason} ->
                            {error, Reason}
                    end
            end;
        {error, Reason} -> {error, Reason}
    end.

%% 格式化 .erl 文件（原地覆盖）。优先使用 erlfmt（社区主流，OTP 28+ 唯一可用）；
%% 若 erlfmt 不可用（极老环境）则回退 erl_tidy（OTP 27 及以前）。
do_format_erl(AbsPath) ->
    case code:ensure_loaded(erlfmt) of
        {module, erlfmt} -> format_with_erlfmt(AbsPath);
        _ -> format_with_erl_tidy(AbsPath)
    end.

%% 使用 erlfmt 格式化：format_file/2 返回格式化后的 chardata，需自行写回。
format_with_erlfmt(AbsPath) ->
    try erlfmt:format_file(AbsPath, []) of
        {ok, Formatted, _Warnings} ->
            case file:write_file(AbsPath, unicode:characters_to_binary(Formatted)) of
                ok -> {ok, <<"erlfmt"/utf8>>};
                {error, WErr} -> {error, #{reason => writeFailed, detail => WErr}}
            end;
        {skip, _Raw} ->
            {ok, <<"erlfmt (skipped)"/utf8>>};
        {error, Err} ->
            {error, #{reason => erlfmtFailed, detail => formatErlfmtError(Err)}}
    catch
        Class:CReason ->
            {error, #{reason => erlfmtFailed, class => Class, detail => CReason}}
    end.

%% 将 erlfmt 的 error_info（{File, Loc, Mod, Reason}）转为可读 binary。
formatErlfmtError({_File, Loc, Mod, Reason}) ->
    unicode:characters_to_binary(
        io_lib:format("~p at ~p: ~p", [Mod, Loc, Reason]));
formatErlfmtError(Other) ->
    unicode:characters_to_binary(io_lib:format("~p", [Other])).

%% 旧环境回退：erl_tidy（OTP 28 起已从 syntax_tools 移除）。
format_with_erl_tidy(AbsPath) ->
    case application:ensure_all_started(syntax_tools) of
        {ok, _} ->
            try erl_tidy:file(AbsPath, [{backups, false}, {io, none}]) of
                ok -> {ok, <<"erl_tidy"/utf8>>};
                {error, Reason} -> {error, Reason}
            catch
                Class:Reason ->
                    {error, #{class => Class, reason => Reason}}
            end;
        {error, Reason} ->
            {error, {erlFormatterUnavailable, Reason}}
    end.

%% @doc 列出指定项目文件的所有备份记录（按时间降序）。
%% 用于审计与回滚前的版本选择；只读操作。
-spec listBackups(map(), map()) -> {ok, map()} | {error, term()}.
listBackups(Args, Config) ->
    Path = maps:get(path, Args, undefined),
    case Path of
        undefined -> {error, missingPath};
        _ ->
            case alToolProject:resolvePathForEdit(projectRoot(Config), Path) of
                {ok, AbsPath} ->
                    Backups = alBackup:list_backups(AbsPath),
                    Summary = [#{timestamp => maps:get(timestamp, B, <<>>),
                                 backupPath => maps:get(backupPath, B, <<>>),
                                 original => maps:get(original, B, AbsPath)}
                               || B <- Backups],
                    {ok, #{
                        path => AbsPath,
                        count => length(Summary),
                        backups => Summary
                    }};
                {error, Reason} -> {error, Reason}
            end
    end.

%% @doc 会话级回滚：将当前会话中修改的所有文件恢复到会话开始前的状态。
%% sessionId 从 Config 中获取（默认 "default"）。
-spec sessionUndo(map(), map()) -> {ok, map()} | {error, term()}.
sessionUndo(_Args, Config) ->
    SessionId = maps:get(sessionId, Config, <<"default"/utf8>>),
    alBackup:restore_session(SessionId).

%% @doc 预览写文件操作的 diff，不实际修改磁盘。
-spec previewWrite(map(), map()) -> {ok, map()} | {error, term()}.
previewWrite(Args, Config) ->
    Path = maps:get(path, Args, undefined),
    Content = maps:get(content, Args, undefined),
    case alToolProject:resolvePathForEdit(projectRoot(Config), Path) of
        {ok, AbsPath} ->
            Exists = filelib:is_file(AbsPath),
            OldContent = case Exists of
                true ->
                    case file:read_file(AbsPath) of
                        {ok, B} -> B;
                        _ -> <<>>
                    end;
                false -> <<>>
            end,
            NewContent = toBinary(Content),
            {ok, #{
                action => write,
                path => AbsPath,
                exists => Exists,
                newBytes => byte_size(NewContent),
                diff => alDiff:format(OldContent, NewContent),
                requiresConfirmation => true
            }};
        {error, Reason} -> {error, Reason}
    end.

%% @doc 预览文本替换补丁的匹配次数与 diff。
-spec previewPatch(map(), map()) -> {ok, map()} | {error, term()}.
previewPatch(Args, Config) ->
    Path = maps:get(path, Args, undefined),
    OldText = maps:get(oldText, Args, undefined),
    NewText = maps:get(newText, Args, undefined),
    case alToolProject:readFile(#{path => Path}, Config) of
        {ok, #{content := Content}} ->
            OldBin = toBinary(OldText),
            NewBin = toBinary(NewText),
            Count = countOccurrences(Content, OldBin),
            Patched = binary:replace(Content, OldBin, NewBin, [global]),
            {ok, #{
                action => patch,
                path => Path,
                matchCount => Count,
                diff => alDiff:format(Content, Patched),
                requiresConfirmation => true
            }};
        {error, Reason} -> {error, Reason}
    end.

%% @doc 预览编译加载将使用的路径、模块名与输出目录。
-spec previewCompileLoad(map(), map()) -> {ok, map()} | {error, term()}.
previewCompileLoad(Args, Config) ->
    Path = maps:get(path, Args, undefined),
    case Path of
        undefined -> {ok, #{action => compileLoad, requiresConfirmation => true}};
        _ ->
            case alToolProject:resolvePathForEdit(projectRoot(Config), Path) of
                {ok, AbsPath} ->
                    Mod = resolve_module(maps:get(module, Args, undefined), AbsPath),
                    {ok, #{
                        action => compileLoad,
                        path => AbsPath,
                        module => Mod,
                        outdir => outdir_for(AbsPath, Config),
                        requiresConfirmation => true
                    }};
                {error, Reason} -> {error, Reason}
            end
    end.

%% 编辑前按需创建备份，附带 sessionId 便于会话级回滚。
maybe_backup(AbsPath, true, Config) ->
    case filelib:is_file(AbsPath) of
        true ->
            SessionId = maps:get(sessionId, Config, <<"default"/utf8>>),
            Meta = #{reason => <<"pre_edit"/utf8>>, sessionId => toBinary(SessionId)},
            alBackup:backup_file(AbsPath, Meta);
        false -> ok
    end;
maybe_backup(_, _, _) -> ok.

%% 异步触发代码索引刷新。
maybe_reindex(Config) ->
    alCodeIndexer:refreshAsync(Config),
    ok.

%% 从参数或文件头 -module 解析模块名。
resolve_module(undefined, AbsPath) ->
    case file:read_file(AbsPath) of
        {ok, Content} ->
            case re:run(Content, <<"-module\\((\\w+)"/utf8>>, [{capture, all_but_first, binary}]) of
                {match, [M]} -> binary_to_atom(M, utf8);
                nomatch -> undefined
            end;
        _ -> undefined
    end;
resolve_module(Mod, _Abs) -> to_atom(Mod).

%% 根据源文件是否在 test 目录选择 rebar3 ebin 输出路径。
outdir_for(AbsPath, Config) ->
    Root = projectRoot(Config),
    case string:str(AbsPath, "/test/") > 0 orelse string:str(AbsPath, "\\test\\") > 0 of
        true -> filename:join(Root, "_build/test/lib/ali/ebin");
        false -> filename:join(Root, "_build/default/lib/ali/ebin")
    end.

%% 从项目根候选路径查找模块对应 .erl 源文件。
beam_to_src(_Beam, Mod) ->
    SrcName = atom_to_list(Mod) ++ ".erl",
    Root = alToolProject:findProjectRootFromModule(),
    Candidates = [
        filename:join([Root, "src", SrcName]),
        filename:join([Root, SrcName])
    ],
    case [P || P <- Candidates, filelib:is_file(P)] of
        [P | _] -> {ok, P};
        [] -> {error, not_found}
    end.

%% 将 compile 错误列表格式化为 binary 列表。
format_errors(Errors) ->
    [list_to_binary(io_lib:format("~p", [E])) || E <- Errors].

%% 按时间戳 ID 在备份列表中查找备份路径。
find_backup(Backups, Id) ->
    IdBin = to_binary(Id),
    case lists:filter(fun(B) ->
        maps:get(timestamp, B, <<>>) =:= IdBin
    end, Backups) of
        [#{backupPath := P} | _] -> {ok, P};
        [] -> {error, backupNotFound}
    end.

%% 统计子串在二进制中的出现次数。
countOccurrences(Haystack, Needle) ->
    countOccurrences(Haystack, Needle, 0).

countOccurrences(Haystack, Needle, Count) ->
    case binary:match(Haystack, Needle) of
        nomatch -> Count;
        {Start, Len} ->
            Rest = binary:part(Haystack, Start + Len, byte_size(Haystack) - Start - Len),
            countOccurrences(Rest, Needle, Count + 1)
    end.

%% 从配置或当前工作目录解析项目根路径。
projectRoot(Config) ->
    case maps:get(projectRoot, Config, undefined) of
        undefined ->
            case file:get_cwd() of
                {ok, Cwd} -> filename:absname(Cwd);
                {error, _} -> "."
            end;
        Root -> filename:absname(toList(Root))
    end.

%% 将多种类型转为 binary。
toBinary(X) when is_binary(X) -> X;
toBinary(X) when is_list(X) -> unicode:characters_to_binary(X);
toBinary(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).

toList(X) when is_binary(X) -> binary_to_list(X);
toList(X) when is_list(X) -> X.

to_atom(X) when is_atom(X) -> X;
to_atom(X) when is_binary(X) -> binary_to_atom(X, utf8);
to_atom(X) when is_list(X) -> list_to_atom(X).

to_binary(X) when is_binary(X) -> X;
to_binary(X) -> unicode:characters_to_binary(toList(X)).