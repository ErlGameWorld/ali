%%%-------------------------------------------------------------------
%% @doc 最小安全补丁管理器。
%%      编辑形态：#{file => File, replace => #{old => Old, new => New}}、
%%      `old => Old, new => New`、`hunks => [...]`、或 `diff/unified` 形态。
%%      操作形态（op）：#{op => create, file => F, content => C}、
%%      #{op => delete, file => F}、#{op => rename, file => F, to => T}。
%%      create/delete/rename 同样走 validate → dryRun → apply → 事务回滚链路。
%% @end
%%%-------------------------------------------------------------------

-module(alPatchManager).

-include_lib("kernel/include/file.hrl").

-export([validate/1, dryRun/1, applyPatch/1, applyPatch/2, applyBatch/1, applyBatch/2,
         rollbackLast/0, rollback/1, listTransactions/0, ensureStarted/0,
         verifyCompile/1]).
%% Test exports — pure helpers
-export([normalizePatch/1, normalizeOp/1, occurrenceCount/2, replaceOnce/3, toBinary/1,
         stripBackupSuffix/1, normalizePath/1, backupPath/1, matchesPattern/2,
         patchPathDenied/1, wildcard_to_regex/1, suggestSimilarSnippets/2,
         suggestSimilarSnippets/3]).

-define(TxTable, ali_patch_transactions).

%%--------------------------------------------------------------------
%% @doc
%% 校验补丁格式合法性：规范化补丁 → 校验路径、文本唯一性、可编译性。
%%
%% @param Patch 补丁 map（支持原子键或二进制键）
%% @return `{ok, Validation}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
validate(Patch) ->
    case normalizePatch(Patch) of
        {ok, Normalized} ->
            validateNormalized(Normalized);
        {error, Reason} ->
            {error, Reason}
    end.

%% 分派校验：多 hunk 形态逐个 hunk 校验，单 old/new 形态走 validateReplace。
validateNormalized(#{op := create, file := File, content := Content}) ->
    validateCreate(File, Content);
validateNormalized(#{op := delete, file := File}) ->
    validateDelete(File);
validateNormalized(#{op := rename, file := File, to := To}) ->
    validateRename(File, To);
validateNormalized(#{file := File, hunks := Hunks}) ->
    validateHunks(File, Hunks);
validateNormalized(#{file := File, old := Old, new := New}) ->
    validateReplace(File, Old, New).

%%--------------------------------------------------------------------
%% @doc
%% 干跑模式：执行完整校验流程但不写文件，并预览变更大小。
%%
%% @param Patch 补丁 map
%% @return `{ok, Validation#{dryRun => true, patch => Normalized, preview => Preview}}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
dryRun(Patch) ->
    case normalizePatch(Patch) of
        {ok, Normalized = #{op := create, file := File, content := Content}} ->
            wrapDryRun(Normalized, validateCreate(File, Content), previewCreate(File, Content));
        {ok, Normalized = #{op := delete, file := File}} ->
            wrapDryRun(Normalized, validateDelete(File), previewDelete(File));
        {ok, Normalized = #{op := rename, file := File, to := To}} ->
            wrapDryRun(Normalized, validateRename(File, To), previewRename(File, To));
        {ok, Normalized = #{file := File, hunks := Hunks}} ->
            case validateHunks(File, Hunks) of
                {ok, Validation} ->
                    {ok, Validation#{
                        dryRun => true,
                        patch => Normalized,
                        preview => previewHunks(File, Hunks)
                    }};
                Error ->
                    Error
            end;
        {ok, Normalized = #{file := File, old := Old, new := New}} ->
            case validateReplace(File, Old, New) of
                {ok, Validation} ->
                    {ok, Validation#{
                        dryRun => true,
                        patch => Normalized,
                        preview => previewChange(File, Old, New)
                    }};
                Error ->
                    Error
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% op 型 dryRun：校验通过则附加 dryRun/patch/preview。
wrapDryRun(Normalized, {ok, Validation}, Preview) ->
    {ok, Validation#{dryRun => true, patch => Normalized, preview => Preview}};
wrapDryRun(_Normalized, Error, _Preview) ->
    Error.

previewCreate(File0, Content) ->
    #{op => create, file => normalizePath(File0), contentBytes => byte_size(toBinary(Content))}.

previewDelete(File0) ->
    File = normalizePath(File0),
    case file:read_file_info(File) of
        {ok, #file_info{size = Size}} -> #{op => delete, file => File, fileBytesBefore => Size};
        _ -> #{op => delete, file => File}
    end.

previewRename(File0, To0) ->
    #{op => rename, file => normalizePath(File0), to => normalizePath(To0)}.

%%--------------------------------------------------------------------
%% @doc
%% 应用单条补丁：校验通过后写入文件，原内容备份到 `.ali.bak.<ts>'。
%%
%% @param Patch 补丁 map
%% @return `{ok, Validation#{applied => true, backup => Backup, patch => Normalized}}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
applyPatch(Patch) ->
    applyPatch(Patch, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 应用补丁并支持写后验证：默认行为同 applyPatchImpl/1。
%% Opts:
%%   - verifyCompile :: boolean()（默认从 cfg.patch.verifyCompileAfterPatch 读）
%%   - compileCommand :: binary() | string()（默认从 cfg.patch.compileCommand）
%%   - compileTimeoutMs :: integer()（默认从 cfg.patch.compileTimeoutMs）
%%   - rollbackOnFailure :: boolean()（默认 true，失败自动回滚）
%% 验证失败返回 `{error, #{reason => compileFailed, output => ...}}'，
%% 且若 rollbackOnFailure=true，自动 rollback。
%%
%% @param Patch 补丁
%% @param Opts  选项
%% @return `{ok, Validation}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
applyPatch(Patch, Opts) when is_map(Opts) ->
    case applyPatchImpl(Patch) of
        {ok, Result0} ->
            Result = recordSingleTransaction(Result0),
            case shouldVerifyCompile(Opts) of
                false ->
                    {ok, Result};
                true ->
                    case verifyCompile(Opts) of
                        {ok, Verify} ->
                            {ok, Result#{compile => Verify}};
                        {error, Reason} ->
                            _ = try alExperience:recordBuildFailure(maps:merge(Reason, #{
                                file => maps:get(file, Result, <<>>)
                            })) catch _:_ -> ok end,
                            Backup = maps:get(backup, Result, undefined),
                            _ = case maps:get(rollbackOnFailure, Opts, true) of
                                true when Backup =/= undefined ->
                                    restoreFromBackup(Backup);
                                _ -> ok
                            end,
                            {error, maps:merge(Reason, #{patch => Result, rolledBack => maps:get(rollbackOnFailure, Opts, true)})}
                    end
            end;
        {error, _} = Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% @doc
%% 单条 patch 实际写入实现：规范化 → 校验 → 备份 → 替换 → 写文件。
%% 抽出此函数供 applyPatch/1 与 applyPatch/2 共用，避免后者在验证
%% 失败时重复触发 patch 内嵌的 compile:file/2。
%%
%% @param Patch 补丁 map
%% @return `{ok, Validation#{applied => true, backup => Backup, patch => Normalized}}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
applyPatchImpl(Patch) ->
    case normalizePatch(Patch) of
        {ok, #{op := create, file := File, content := Content}} ->
            applyCreateImpl(File, Content);
        {ok, #{op := delete, file := File}} ->
            applyDeleteImpl(File);
        {ok, #{op := rename, file := File, to := To}} ->
            applyRenameImpl(File, To);
        {ok, Normalized = #{file := File, hunks := Hunks}} ->
            case validateHunks(File, Hunks) of
                {ok, Validation} ->
                    case ensureWritable(File) of
                        ok ->
                            case file:read_file(File) of
                                {ok, Original} ->
                                    case alBackup:backupFile(File, #{source => patchManager}) of
                                        {ok, _} ->
                                            case applyHunks(Original, Hunks) of
                                                {ok, Updated} ->
                                                    Backup = backupPath(File),
                                                    case file:write_file(Backup, Original) of
                                                        ok ->
                                                            case file:write_file(File, Updated) of
                                                                ok ->
                                                                    {ok, Validation#{applied => true, backup => Backup, patch => Normalized}};
                                                                {error, Reason} ->
                                                                    %% 写入失败：尝试从内存中的 Original 回滚，避免留下空文件
                                                                    _ = file:write_file(File, Original),
                                                                    {error, #{reason => Reason, backup => Backup}}
                                                            end;
                                                        {error, Reason} ->
                                                            {error, #{reason => Reason, backup => Backup}}
                                                    end;
                                                {error, Reason} ->
                                                    {error, Reason}
                                            end;
                                        {error, Reason} ->
                                            {error, #{reason => Reason}}
                                    end;
                                {error, Reason} ->
                                    {error, #{reason => Reason}}
                            end;
                        {error, PermissionReason} ->
                            {error, PermissionReason}
                    end;
                Error ->
                    Error
            end;
        {ok, Normalized = #{file := File, old := Old, new := New}} ->
            case validateReplace(File, Old, New) of
                {ok, Validation} ->
                    case ensureWritable(File) of
                        ok ->
                            case file:read_file(File) of
                                {ok, Original} ->
                                    case alBackup:backupFile(File, #{source => patchManager}) of
                                        {ok, _} ->
                                            Updated = replaceOnce(Original, toBinary(Old), toBinary(New)),
                                            Backup = backupPath(File),
                                            case file:write_file(Backup, Original) of
                                                ok ->
                                                    case file:write_file(File, Updated) of
                                                        ok ->
                                                            {ok, Validation#{applied => true, backup => Backup, patch => Normalized}};
                                                        {error, Reason} ->
                                                            _ = file:write_file(File, Original),
                                                            {error, #{reason => Reason, backup => Backup}}
                                                    end;
                                                {error, Reason} ->
                                                    {error, #{reason => Reason, backup => Backup}}
                                            end;
                                        {error, Reason} ->
                                            {error, #{reason => Reason}}
                                    end;
                                {error, Reason} ->
                                    {error, #{reason => Reason}}
                            end;
                        {error, PermissionReason} ->
                            {error, PermissionReason}
                    end;
                Error ->
                    Error
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 创建新文件：校验路径白名单与不存在性后写入，父目录缺失时自动创建。
%% 回滚动作 = unlink（删除新文件）。
%% @end
%%--------------------------------------------------------------------
applyCreateImpl(File0, Content) ->
    File = normalizePath(File0),
    case validateCreate(File, Content) of
        {ok, Validation} ->
            case ensureParentDir(File) of
                ok ->
                    case file:write_file(File, Content) of
                        ok ->
                            {ok, Validation#{
                                applied => true, backup => undefined,
                                patch => #{op => create, file => File, content => Content},
                                undo => #{type => unlink, target => File}}};
                        {error, Reason} ->
                            {error, #{reason => Reason, file => File}}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% @doc
%% 删除文件：备份原内容后删除。回滚动作 = restore（读备份写回原路径）。
%% @end
%%--------------------------------------------------------------------
applyDeleteImpl(File0) ->
    File = normalizePath(File0),
    case validateDelete(File) of
        {ok, Validation} ->
            case file:read_file(File) of
                {ok, Original} ->
                    Backup = backupPath(File),
                    case file:write_file(Backup, Original) of
                        ok ->
                            case file:delete(File) of
                                ok ->
                                    {ok, Validation#{
                                        applied => true, backup => Backup,
                                        patch => #{op => delete, file => File},
                                        undo => #{type => restore, backup => Backup, target => File}}};
                                {error, Reason} ->
                                    _ = file:delete(Backup),
                                    {error, #{reason => Reason, file => File}}
                            end;
                        {error, Reason} ->
                            {error, #{reason => Reason, file => File}}
                    end;
                {error, Reason} ->
                    {error, #{reason => Reason, file => File}}
            end;
        Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% @doc
%% 重命名/移动文件：备份原内容后 rename 到新路径。
%% 回滚动作 = moveBack（删新路径 + 还原旧路径内容）。
%% @end
%%--------------------------------------------------------------------
applyRenameImpl(File0, To0) ->
    File = normalizePath(File0),
    To = normalizePath(To0),
    case validateRename(File, To) of
        {ok, Validation} ->
            case file:read_file(File) of
                {ok, Original} ->
                    Backup = backupPath(File),
                    case file:write_file(Backup, Original) of
                        ok ->
                            case file:rename(File, To) of
                                ok ->
                                    {ok, Validation#{
                                        applied => true, backup => Backup,
                                        patch => #{op => rename, file => File, to => To},
                                        undo => #{type => moveBack, backup => Backup,
                                                  from => File, to => To}}};
                                {error, Reason} ->
                                    _ = file:delete(Backup),
                                    {error, #{reason => Reason, file => File, to => To}}
                            end;
                        {error, Reason} ->
                            {error, #{reason => Reason, file => File}}
                    end;
                {error, Reason} ->
                    {error, #{reason => Reason, file => File}}
            end;
        Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% @doc
%% 创建校验：路径白名单 → 目标不存在 →（.erl 时）编译校验。
%% @end
%%--------------------------------------------------------------------
validateCreate(File0, Content) ->
    File = normalizePath(File0),
    case patchPathAllowed(File) of
        false ->
            {error, #{reason => patchPathNotAllowed, file => File}};
        true ->
            case file:read_file_info(File) of
                {ok, _} ->
                    {error, #{reason => fileExists, file => File,
                              hint => <<"use replace/hunks to edit an existing file, or file a different path"/utf8>>}};
                {error, enoent} ->
                    validateCompilation(File, Content);
                {error, Reason} ->
                    {error, #{reason => Reason, file => File}}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 删除校验：路径白名单 → 目标为普通文件存在。不编译（文件删除无独立编译）。
%% @end
%%--------------------------------------------------------------------
validateDelete(File0) ->
    File = normalizePath(File0),
    case patchPathAllowed(File) of
        false ->
            {error, #{reason => patchPathNotAllowed, file => File}};
        true ->
            case file:read_file_info(File) of
                {ok, #file_info{type = regular}} ->
                    {ok, #{file => File, compile => skipped}};
                {ok, #file_info{type = Other}} ->
                    {error, #{reason => notAFile, type => Other, file => File}};
                {error, enoent} ->
                    {error, #{reason => notFound, file => File}};
                {error, Reason} ->
                    {error, #{reason => Reason, file => File}}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 重命名校验：双路径白名单 → 源为普通文件存在 → 目标不存在（避免覆盖）。
%% @end
%%--------------------------------------------------------------------
validateRename(File0, To0) ->
    File = normalizePath(File0),
    To = normalizePath(To0),
    case patchPathAllowed(File) andalso patchPathAllowed(To) of
        false ->
            {error, #{reason => patchPathNotAllowed, file => File, to => To}};
        true ->
            case file:read_file_info(File) of
                {ok, #file_info{type = regular}} ->
                    case file:read_file_info(To) of
                        {error, enoent} ->
                            {ok, #{file => File, to => To, compile => skipped}};
                        {ok, _} ->
                            {error, #{reason => targetExists, file => File, to => To}};
                        {error, Reason} ->
                            {error, #{reason => Reason, to => To}}
                    end;
                {ok, #file_info{type = Other}} ->
                    {error, #{reason => notAFile, type => Other, file => File}};
                {error, enoent} ->
                    {error, #{reason => notFound, file => File}};
                {error, Reason} ->
                    {error, #{reason => Reason, file => File}}
            end
    end.

%% 确保目标文件的父目录存在（create 写入新路径前调用）。
ensureParentDir(File) ->
    case filelib:ensure_dir(File) of
        ok -> ok;
        {error, Reason} -> {error, #{reason => Reason, dir => filename:dirname(File)}}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 写入前文件权限预检：检查目标文件存在且可写，避免在备份后才因
%% eacces 失败留下半完成状态。Windows 上 access 校验语义有限，故
%% 退化为 file:open(File, [append]) 的只打开不写入探针，任何打开错误
%% 在此提前暴露。
%%
%% @param File 目标文件路径
%% @return `ok' | `{error, map()}'
%% @end
%%--------------------------------------------------------------------
ensureWritable(File) ->
    case file:read_file_info(File) of
        {ok, #file_info{type = regular, access = A}} when A =:= read_write;
                                                          A =:= write ->
            ok;
        {ok, #file_info{type = regular}} ->
            %% 权限标识不是 read_write/write：尝试临时写入探针。
            %% Windows 下 file:read_file_info 返回的 access 总是 read_write，
            %% 但 Linux 下可能为 read_only；这里做一次原子性探针。
            probeWritable(File);
        {ok, #file_info{type = Other}} ->
            {error, #{reason => notAFile, type => Other}};
        {error, enoent} ->
            {error, #{reason => notFound}};
        {error, Reason} ->
            {error, #{reason => Reason}}
    end.

%% 用一次 append-open 做权限探针：只打开不写内容，避免「读-写回」窗口内
%% 覆盖其它写者的并发改动。成功打开说明文件可写，立即关闭返回 ok。
%% 失败时返回 {error, ...}，调用方据此中止后续 patch 流程。
probeWritable(File) ->
    case file:open(File, [append]) of
        {ok, IoDevice} ->
            _ = file:close(IoDevice),
            ok;
        {error, eacces} -> {error, #{reason => permissionDenied}};
        {error, Reason} -> {error, #{reason => Reason}}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 解析是否需要写后编译验证：Opts 优先，其次 cfg.patch.verifyCompileAfterPatch。
%%
%% @param Opts 选项
%% @return boolean()
%% @end
%%--------------------------------------------------------------------
shouldVerifyCompile(Opts) ->
    case maps:get(verifyCompile, Opts, undefined) of
        V when is_boolean(V) -> V;
        undefined ->
            case alConfig:get(patch, #{}) of
                #{verifyCompileAfterPatch := V2} when is_boolean(V2) -> V2;
                _ -> true
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 执行写后编译验证：通过 os:cmd 调用 patch.compileCommand 命令，
%% 在 patch.allowedRoots 推断的项目根下执行，stdout/stderr 一并
%% 返回。超时返回 `{error, {compileTimeout, _}}'。
%%
%% @param Opts 选项（可选覆盖 compileCommand / compileTimeoutMs）
%% @return `{ok, #{output => _, exitCode => 0}}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
verifyCompile(Opts) ->
    Patch = alConfig:get(patch, #{}),
    Cmd0 = firstDefined([maps:get(compileCommand, Opts, undefined),
                         maps:get(compileCommand, Patch, undefined),
                         <<"rebar3 compile">>]),
    Timeout = firstDefined([maps:get(compileTimeoutMs, Opts, undefined),
                            maps:get(compileTimeoutMs, Patch, undefined),
                            120000]),
    {Program, Args} = splitCompileCommand(Cmd0),
    case alToolsExt:runProgram(Program, Args, Timeout) of
        {ok, #{success := true, output := Out, exitCode := 0} = R} ->
            {ok, #{output => Out, exitCode => 0, command => Cmd0,
                   root => alConfig:root(), timeoutMs => Timeout,
                   durationMs => maps:get(durationMs, R, 0)}};
        {ok, #{output := Out, exitCode := Code}} ->
            {error, #{reason => compileFailed, output => Out, exitCode => Code,
                      command => Cmd0, root => alConfig:root(), timeoutMs => Timeout}};
        {error, #{reason := portTimeout} = E} ->
            {error, maps:merge(#{reason => compileTimeout, command => Cmd0,
                                 root => alConfig:root(), timeoutMs => Timeout}, E)};
        {error, Reason} ->
            {error, #{reason => compileFailed, detail => Reason, command => Cmd0,
                      root => alConfig:root(), timeoutMs => Timeout}}
    end.

%% "rebar3 compile" → {"rebar3", ["compile"]}；自定义命令按空白切分。
splitCompileCommand(Cmd) when is_binary(Cmd); is_list(Cmd) ->
    Parts = [P || P <- binary:split(toBinary(Cmd), <<" ">>, [global]), P =/= <<>>],
    case Parts of
        [Prog | Rest] -> {binary_to_list(Prog), [binary_to_list(A) || A <- Rest]};
        [] -> {"rebar3", ["compile"]}
    end;
splitCompileCommand(_) ->
    {"rebar3", ["compile"]}.

%%--------------------------------------------------------------------
%% @doc
%% 按事务 ID 回滚（rollbackTransaction 的公开别名）。
%%
%% @param TxId 事务 ID（integer 或 binary）
%% @return `{ok, #{transactionId => _, restored => N}}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
rollback(TxId) when is_integer(TxId) ->
    rollbackTransaction(TxId);
rollback(TxId) when is_binary(TxId) ->
    case re:run(TxId, "^-?\\d+$", [{capture, none}]) of
        match -> rollbackTransaction(binary_to_integer(TxId));
        nomatch -> {error, {invalidTxId, TxId}}
    end;
rollback(TxId) ->
    {error, {invalidTxId, TxId}}.

%% 从备份路径恢复文件原内容；恢复失败返回 error。
restoreFromBackup(Backup) when is_list(Backup) orelse is_binary(Backup) ->
    BackupStr = toBinary(Backup),
    Source = stripBackupSuffix(BackupStr),
    case file:read_file(BackupStr) of
        {ok, Original} ->
            case file:write_file(Source, Original) of
                ok -> {ok, Source};
                {error, Reason} -> {error, {restoreFailed, Source, Reason}}
            end;
        {error, Reason} ->
            {error, {backupReadFailed, BackupStr, Reason}}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 批量应用补丁入口：分配事务 ID 后逐条应用，全成功才提交事务。
%%
%% @param Patches 补丁列表
%% @return `{ok, #{transactionId => TxId, applied => N, results => Results}}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
applyBatch(Patches) when is_list(Patches) ->
    applyBatch(Patches, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 批量应用补丁（带选项）：Opts 支持 verifyCompile（事务提交后
%% 跑一次全量编译）。
%%
%% @param Patches 补丁列表
%% @param Opts    选项
%% @return `{ok, Result}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
applyBatch(Patches, Opts) when is_list(Patches), is_map(Opts) ->
    ensureTxTable(),
    TxId = erlang:unique_integer([positive, monotonic]),
    case applyBatchIter(Patches, TxId, [], []) of
        {ok, Res = #{transactionId := TxId}} ->
            case shouldVerifyCompile(Opts) of
                false ->
                    {ok, Res};
                true ->
                    case verifyCompile(Opts) of
                        {ok, Verify} ->
                            {ok, Res#{compile => Verify}};
                        {error, Reason} ->
                            File = case maps:get(results, Res, []) of
                                [First | _] -> maps:get(file, First, <<>>);
                                _ -> <<>>
                            end,
                            _ = try alExperience:recordBuildFailure(maps:merge(Reason, #{
                                file => File
                            })) catch _:_ -> ok end,
                            _ = rollbackTransaction(TxId),
                            {error, maps:merge(Reason, #{transactionId => TxId, rolledBack => true})}
                    end
            end;
        {error, _} = Err ->
            Err
    end.

%% 批量应用递归终止：记录事务并返回成功汇总。
applyBatchIter([], TxId, Backups, Results) ->
    recordTransaction(TxId, Backups, Results),
    {ok, #{transactionId => TxId, applied => length(Results), results => lists:reverse(Results)}};
%% 批量应用递归：逐条 apply，失败则回滚所有已应用的备份。
applyBatchIter([Patch | Rest], TxId, Backups, Results) ->
    case applyPatchImpl(Patch) of
        {ok, Result} ->
            Undo = undoInstruction(Result),
            applyBatchIter(Rest, TxId, [Undo | Backups], [Result | Results]);
        {error, Reason} ->
            rollbackFiles(Backups),
            {error, #{transactionId => TxId, reason => Reason, rolledBack => length(Backups)}}
    end.

%% 从 apply 结果提取回滚指令：优先 `undo' 动作，缺省回退到 `backup' 路径
%% （旧式 replace 语义：读备份写回原路径）。
undoInstruction(Result) ->
    case maps:get(undo, Result, undefined) of
        undefined -> maps:get(backup, Result, undefined);
        Undo -> Undo
    end.

%%--------------------------------------------------------------------
%% @doc
%% 回滚最近一次批量事务：从事务表中取 `last' 并调用 {@link rollbackTransaction/1}。
%%
%% @return `{ok, #{transactionId => TxId, restored => N}}' | `{error, noTransactions}'
%% @end
%%--------------------------------------------------------------------
rollbackLast() ->
    ensureTxTable(),
    case ets:lookup(?TxTable, last) of
        [{last, TxId}] ->
            rollbackTransaction(TxId);
        [] ->
            {error, noTransactions}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 列出所有已记录的事务（过滤掉 `last' 指针项）。
%%
%% @return 事务 map 列表
%% @end
%%--------------------------------------------------------------------
listTransactions() ->
    ensureTxTable(),
    [Tx || {Key, Tx} <- ets:tab2list(?TxTable), is_integer(Key)].

%%--------------------------------------------------------------------
%% @doc
%% 按 ID 回滚指定事务：从备份恢复文件并删除该事务记录。
%%
%% @param TxId 事务 ID
%% @return `{ok, #{transactionId => TxId, restored => N}}' | `{error, {transactionNotFound, TxId}}'
%% @end
%%--------------------------------------------------------------------
rollbackTransaction(TxId) ->
    case ets:lookup(?TxTable, TxId) of
        [{TxId, #{backups := Backups}}] ->
            rollbackFiles(Backups),
            ets:delete(?TxTable, TxId),
            {ok, #{transactionId => TxId, restored => length(Backups)}};
        [] ->
            {error, {transactionNotFound, TxId}}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 校验单条替换：路径白名单 → 文件可读 → old 文本唯一存在 → 编译校验。
%%
%% @param File0 文件路径
%% @param Old0 待替换文本
%% @param New0 新文本
%% @return `{ok, Validation}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
validateReplace(File0, Old0, New0) ->
    File = normalizePath(File0),
    case patchPathAllowed(File) of
        false ->
            {error, #{reason => patchPathNotAllowed, file => File}};
        true ->
            Old = toBinary(Old0),
            New = toBinary(New0),
            case file:read_file(File) of
                {ok, Original} ->
                    Count = occurrenceCount(Original, Old),
                    case Count of
                        1 -> validateCompilation(File, replaceOnce(Original, Old, New));
                        0 ->
                            {error, #{reason => oldTextNotFound, file => File,
                                      suggestions => suggestSimilarSnippets(Original, Old)}};
                        _ ->
                            {error, #{reason => oldTextNotUnique, file => File, count => Count,
                                      hint => <<"Make old text unique with more surrounding context, or split into hunks.">>}}
                    end;
                {error, Reason} ->
                    {error, #{reason => Reason, file => File}}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 编译校验：对 `.erl' 文件写入临时文件并编译，非 Erlang 文件跳过。
%%
%% @param File 文件路径
%% @param Updated 替换后的文件内容
%% @return `{ok, #{file => File, compile => ok | skipped, warnings => Warnings}}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
validateCompilation(File, Updated) ->
    case filename:extension(File) of
        ".erl" ->
            Temp = tempPath(File),
            ok = file:write_file(Temp, Updated),
            Result = compile:file(Temp, [binary, return_errors, return_warnings]),
            file:delete(Temp),
            case Result of
                {ok, _Module, _Beam} ->
                    {ok, #{file => File, compile => ok}};
                {ok, _Module, _Beam, Warnings} ->
                    {ok, #{file => File, compile => ok, warnings => Warnings}};
                error ->
                    {error, #{reason => compileFailed, file => File}};
                {error, Errors, Warnings} ->
                    {error, #{reason => compileFailed, file => File, errors => Errors, warnings => Warnings}}
            end;
        _ ->
            {ok, #{file => File, compile => skipped}}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 规范化补丁格式（多子句）：
%%  - 支持 `{file, replace => {old, new}}' 结构（原子键）
%%  - 支持 JSON 二进制键版本
%%  - 支持扁平 `{file, old, new}' 结构
%%  - 其它格式返回 `{error, badPatchFormat}'
%%
%% @param Patch 补丁 map
%% @return `{ok, #{file => Path, old => Old, new => New}}' | `{error, badPatchFormat}'
%% @end
%%--------------------------------------------------------------------
normalizePatch(#{file := File, replace := #{old := Old, new := New}}) ->
    {ok, #{file => normalizePath(File), old => Old, new => New}};
normalizePatch(#{<<"file">> := File, <<"replace">> := #{<<"old">> := Old, <<"new">> := New}}) ->
    {ok, #{file => normalizePath(File), old => Old, new => New}};
normalizePatch(#{file := File, old := Old, new := New}) ->
    {ok, #{file => normalizePath(File), old => Old, new => New}};
%% Unified diff form: #{file => Path, diff => <<"@@ ...\\n-old\\n+new\\n">>}
%% or #{file => Path, unified => DiffBin}. Converts unique context hunks into
%% a single old/new replace when the hunk is unambiguous.
normalizePatch(#{file := File, diff := Diff}) ->
    unifiedToReplace(File, Diff);
normalizePatch(#{file := File, unified := Diff}) ->
    unifiedToReplace(File, Diff);
normalizePatch(#{<<"file">> := File, <<"diff">> := Diff}) ->
    unifiedToReplace(File, Diff);
normalizePatch(#{<<"file">> := File, <<"unified">> := Diff}) ->
    unifiedToReplace(File, Diff);
%% Op-based forms: create / rename（带额外字段，必须置于 delete 兜底前）。
normalizePatch(#{op := Op, file := File, content := Content}) ->
    case normalizeOp(Op) of
        create -> {ok, #{op => create, file => normalizePath(File), content => toBinary(Content)}};
        rename -> {ok, #{op => rename, file => normalizePath(File), content => toBinary(Content)}};
        _ -> {error, badPatchFormat}
    end;
normalizePatch(#{<<"op">> := Op, <<"file">> := File, <<"content">> := Content}) ->
    case normalizeOp(Op) of
        create -> {ok, #{op => create, file => normalizePath(File), content => toBinary(Content)}};
        rename -> {ok, #{op => rename, file => normalizePath(File), content => toBinary(Content)}};
        _ -> {error, badPatchFormat}
    end;
normalizePatch(#{op := Op, file := File, to := To}) ->
    case normalizeOp(Op) of
        rename -> {ok, #{op => rename, file => normalizePath(File), to => normalizePath(To)}};
        _ -> {error, badPatchFormat}
    end;
normalizePatch(#{<<"op">> := Op, <<"file">> := File, <<"to">> := To}) ->
    case normalizeOp(Op) of
        rename -> {ok, #{op => rename, file => normalizePath(File), to => normalizePath(To)}};
        _ -> {error, badPatchFormat}
    end;
normalizePatch(#{op := Op, file := File}) ->
    case normalizeOp(Op) of
        delete -> {ok, #{op => delete, file => normalizePath(File)}};
        create -> {error, #{reason => missingContent}};
        rename -> {error, #{reason => missingTarget}};
        _ -> {error, badPatchFormat}
    end;
normalizePatch(#{<<"op">> := Op, <<"file">> := File}) ->
    case normalizeOp(Op) of
        delete -> {ok, #{op => delete, file => normalizePath(File)}};
        create -> {error, #{reason => missingContent}};
        rename -> {error, #{reason => missingTarget}};
        _ -> {error, badPatchFormat}
    end;
normalizePatch(_) ->
    {error, badPatchFormat}.

%% op 值归一：原子 create/delete/rename 或对应 binary。
normalizeOp(create) -> create;
normalizeOp(delete) -> delete;
normalizeOp(rename) -> rename;
normalizeOp(<<"create">>) -> create;
normalizeOp(<<"delete">>) -> delete;
normalizeOp(<<"rename">>) -> rename;
normalizeOp(_) -> unknown.

%% 将 unified diff 转换为可应用的替换：单 hunk 折叠为一对 old/new；
%% 多 hunk（多个 @@ 段）拆成有序的 [#{old, new}] 列表，逐个 hunk 独立
%% 定位替换（每个 hunk 的 old 在当轮内容中必须唯一），避免各 hunk 间
%% 未变更代码被错误拼接。
unifiedToReplace(File, Diff0) ->
    Diff = toBinary(Diff0),
    Lines = binary:split(Diff, <<"\n">>, [global]),
    Hunks = parseHunks(Lines),
    case Hunks of
        [] ->
            {error, emptyUnifiedDiff};
        [#{old := <<>>, new := <<>>}] ->
            {error, emptyUnifiedDiff};
        [#{old := Old, new := New}] ->
            {ok, #{file => normalizePath(File), old => Old, new => New}};
        _ ->
            {ok, #{file => normalizePath(File), hunks => Hunks}}
    end.

%% 将 diff 各行按 @@ 头切分为多个 hunk，逐个转成 #{old, new}。
%% 无 @@ 头时整段视为单个 hunk（兼容裸 diff 片段）。忽略 ---/+++ 文件头行。
parseHunks(Lines) ->
    Groups = groupByHunk(Lines, [], []),
    [hunkFromLines(G) || G <- Groups, G =/= []].

%% 按 @@ 头把行分组：Cur 反向累积当前组，遇到 @@ 压入并开新组。
groupByHunk([], Cur, Acc) ->
    lists:reverse(pushGroup(Cur, Acc));
groupByHunk([<<"@@", _/binary>> | Rest], Cur, Acc) ->
    groupByHunk(Rest, [], pushGroup(Cur, Acc));
groupByHunk([<<"---", _/binary>> | Rest], Cur, Acc) ->
    groupByHunk(Rest, Cur, Acc);
groupByHunk([<<"+++", _/binary>> | Rest], Cur, Acc) ->
    groupByHunk(Rest, Cur, Acc);
groupByHunk([Line | Rest], Cur, Acc) ->
    groupByHunk(Rest, [Line | Cur], Acc).

%% 把反向累积的当前组还原顺序后压入结果（空组丢弃）。
pushGroup([], Acc) -> Acc;
pushGroup(Cur, Acc) -> [lists:reverse(Cur) | Acc].

%% 将一个 hunk 的行折叠为 #{old, new}：`-'→old，`+'→new，` '(上下文)→两者。
hunkFromLines(Lines) ->
    {OldLines, NewLines} = lists:foldl(fun
        (<<"-", Rest/binary>>, {Old, New}) -> {[Rest | Old], New};
        (<<"+", Rest/binary>>, {Old, New}) -> {Old, [Rest | New]};
        (<<" ", Rest/binary>>, {Old, New}) -> {[Rest | Old], [Rest | New]};
        (_, Acc) -> Acc
    end, {[], []}, Lines),
    #{old => joinLines(lists:reverse(OldLines)),
      new => joinLines(lists:reverse(NewLines))}.

%%--------------------------------------------------------------------
%% @doc
%% 逐个 hunk 校验多 hunk 补丁：在渐进更新的内容上依次应用每个 hunk，
%% 每个 hunk 的 old 文本在当轮内容中必须唯一存在，最终对结果做编译校验。
%%
%% @param File0 文件路径
%% @param Hunks [#{old, new}] 有序 hunk 列表
%% @return `{ok, Validation}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
validateHunks(File0, Hunks) ->
    File = normalizePath(File0),
    case patchPathAllowed(File) of
        false ->
            {error, #{reason => patchPathNotAllowed, file => File}};
        true ->
            case file:read_file(File) of
                {ok, Original} ->
                    case applyHunks(Original, Hunks) of
                        {ok, Updated} ->
                            validateCompilation(File, Updated);
                        {error, Reason} ->
                            {error, Reason#{file => File}}
                    end;
                {error, Reason} ->
                    {error, #{reason => Reason, file => File}}
            end
    end.

%% 在内容上依次应用各 hunk：每个 hunk 的 old 必须唯一出现，否则报错。
applyHunks(Content, []) ->
    {ok, Content};
applyHunks(Content, [#{old := Old0, new := New0} | Rest]) ->
    Old = toBinary(Old0),
    New = toBinary(New0),
    case occurrenceCount(Content, Old) of
        1 -> applyHunks(replaceOnce(Content, Old, New), Rest);
        0 ->
            {error, #{reason => oldTextNotFound, hunk => Old,
                      suggestions => suggestSimilarSnippets(Content, Old)}};
        Count ->
            {error, #{reason => oldTextNotUnique, hunk => Old, count => Count,
                      hint => <<"Add more unique context lines to this hunk.">>}}
    end.

%%--------------------------------------------------------------------
%% @doc
%% When old text is missing, suggest nearby source windows that look similar
%% (shared non-trivial tokens / first-line fuzzy match). Helps LLM rewrite hunks.
%% @end
%%--------------------------------------------------------------------
suggestSimilarSnippets(Content, Needle) ->
    suggestSimilarSnippets(Content, Needle, 3).

suggestSimilarSnippets(Content0, Needle0, Max) when is_integer(Max), Max > 0 ->
    Content = toBinary(Content0),
    Needle = toBinary(Needle0),
    case Needle of
        <<>> -> [];
        _ ->
            NeedleLines = [L || L <- binary:split(Needle, <<"\n">>, [global]), L =/= <<>>],
            Win = max(1, min(12, length(NeedleLines))),
            ContentLines = binary:split(Content, <<"\n">>, [global]),
            NeedleToks = tokensOf(Needle),
            Scored = scoreWindows(ContentLines, Win, NeedleToks, NeedleLines, 1, []),
            Top = lists:sublist(lists:reverse(lists:keysort(1, Scored)), Max),
            [#{startLine => Line, score => Score, snippet => Snip}
             || {Score, Line, Snip} <- Top, Score > 0.15]
    end;
suggestSimilarSnippets(_, _, _) ->
    [].

scoreWindows(Lines, Win, _NeedleToks, _NeedleLines, _LineNo, Acc) when length(Lines) < Win ->
    Acc;
scoreWindows(Lines, Win, NeedleToks, NeedleLines, LineNo, Acc) ->
    Window = lists:sublist(Lines, Win),
    Text = joinLines(Window),
    Score = similarityScore(NeedleToks, NeedleLines, Text, Window),
    Rest = tl(Lines),
    scoreWindows(Rest, Win, NeedleToks, NeedleLines, LineNo + 1,
                 [{Score, LineNo, truncateBin(Text, 400)} | Acc]).

similarityScore(NeedleToks, NeedleLines, WindowText, WindowLines) ->
    WinToks = tokensOf(WindowText),
    Jac = jaccard(NeedleToks, WinToks),
    FirstNeedle = case NeedleLines of
        [L | _] -> L;
        [] -> <<>>
    end,
    FirstWin = case WindowLines of
        [L2 | _] -> L2;
        [] -> <<>>
    end,
    Prefix = case {FirstNeedle, FirstWin} of
        {<<>>, _} -> 0.0;
        {_, <<>>} -> 0.0;
        {A, B} ->
            case binary:longest_common_prefix([A, B]) of
                N when N >= 8 -> min(1.0, N / max(byte_size(A), 1));
                _ -> 0.0
            end
    end,
    Jac * 0.7 + Prefix * 0.3.

tokensOf(Bin) ->
    Parts = re:split(Bin, <<"[^A-Za-z0-9_]+">>, [{return, binary}]),
    lists:usort([P || P <- Parts, byte_size(P) >= 3]).

jaccard([], _) -> 0.0;
jaccard(_, []) -> 0.0;
jaccard(A, B) ->
    SA = sets:from_list(A),
    SB = sets:from_list(B),
    Inter = sets:size(sets:intersection(SA, SB)),
    Union = sets:size(sets:union(SA, SB)),
    case Union of
        0 -> 0.0;
        _ -> Inter / Union
    end.

truncateBin(Bin, Max) when is_binary(Bin), byte_size(Bin) =< Max -> Bin;
truncateBin(Bin, Max) when is_binary(Bin) ->
    <<(binary:part(Bin, 0, Max))/binary, "…"/utf8>>;
truncateBin(Other, Max) ->
    truncateBin(toBinary(Other), Max).

%% 多 hunk 补丁的变更预览：返回 hunk 数与变更前后文件大小。
previewHunks(File0, Hunks) ->
    Path = normalizePath(File0),
    case file:read_file(Path) of
        {ok, Original} ->
            case applyHunks(Original, Hunks) of
                {ok, Updated} ->
                    #{
                        file => Path,
                        hunks => length(Hunks),
                        fileBytesBefore => byte_size(Original),
                        fileBytesAfter => byte_size(Updated)
                    };
                {error, Reason} ->
                    #{file => Path, hunks => length(Hunks), error => Reason}
            end;
        {error, Reason} ->
            #{file => Path, error => Reason}
    end.

joinLines([]) -> <<>>;
joinLines([L]) -> L;
joinLines([L | Rest]) ->
    iolist_to_binary([L, $\n, joinLines(Rest)]).

%% 空字符串视为 0 次出现。
occurrenceCount(_Text, <<>>) ->
    0;
%% 计数入口：调用三参数递归版本。
occurrenceCount(Text, Needle) ->
    occurrenceCount(Text, Needle, 0).

%% 递归统计 Needle 在 Text 中出现次数（重叠不计）。
occurrenceCount(Text, Needle, Count) ->
    case binary:match(Text, Needle) of
        nomatch ->
            Count;
        {Start, Len} ->
            NextStart = Start + Len,
            occurrenceCount(binary:part(Text, NextStart, byte_size(Text) - NextStart), Needle, Count + 1)
    end.

%% 替换 Text 中首次出现的 Old 为 New（jiffy 风格 binary:replace 默认全局，这里靠调用方语义保证唯一）。
replaceOnce(Text, Old, New) ->
    binary:replace(Text, Old, New, []).

%%--------------------------------------------------------------------
%% @doc
%% 生成变更预览：返回文件路径、old/new 字节数及变更前后文件大小。
%%
%% @param File0 文件路径
%% @param Old0 待替换文本
%% @param New0 新文本
%% @return 包含变更统计的 map（出错时附 `error' 字段）
%% @end
%%--------------------------------------------------------------------
previewChange(File0, Old0, New0) ->
    Path = normalizePath(File0),
    Old = toBinary(Old0),
    New = toBinary(New0),
    case file:read_file(Path) of
        {ok, Original} ->
            Updated = replaceOnce(Original, Old, New),
            #{
                file => Path,
                oldBytes => byte_size(Old),
                newBytes => byte_size(New),
                fileBytesBefore => byte_size(Original),
                fileBytesAfter => byte_size(Updated)
            };
        {error, Reason} ->
            #{file => Path, error => Reason}
    end.

%% 根据文件路径与当前秒级时间戳生成备份文件路径。
backupPath(File) ->
    File ++ ".ali.bak." ++ integer_to_list(erlang:system_time(second))
         ++ "." ++ integer_to_list(erlang:unique_integer([monotonic])).

%% 生成与目标文件同目录的临时文件路径，用于编译校验。
tempPath(File) ->
    filename:join(filename:dirname(File), ".ali_patch_" ++ integer_to_list(erlang:unique_integer([positive])) ++ filename:basename(File)).

%%--------------------------------------------------------------------
%% @doc
%% 将路径规范化为绝对路径（多子句）：binary 先转 list 再取绝对路径，list 直接取绝对路径。
%%
%% @param Path 路径
%% @return 绝对路径字符串
%% @end
%%--------------------------------------------------------------------
normalizePath(Path) when is_binary(Path) ->
    flattenPath(filename:absname(unicode:characters_to_list(Path)));
normalizePath(Path) when is_list(Path) ->
    flattenPath(filename:absname(Path)).

%% 解析 .. 和 . 符号链接，防止路径遍历。`filename:absname' 已把相对路径
%% 解析为绝对路径，这里只需对绝对路径分量做 .. / . 折叠。
flattenPath(AbsPath) ->
    Comps = filename:split(AbsPath),
    flattenComps([], Comps).

flattenComps(Acc, []) ->
    filename:join(lists:reverse(Acc));
flattenComps(Acc, [".." | Rest]) ->
    case Acc of
        [_ | AccTail] -> flattenComps(AccTail, Rest);
        [] -> flattenComps([], Rest)
    end;
flattenComps(Acc, ["." | Rest]) ->
    flattenComps(Acc, Rest);
flattenComps(Acc, [Comp | Rest]) ->
    flattenComps([Comp | Acc], Rest).

%%--------------------------------------------------------------------
%% @doc
%% 检查文件是否位于补丁白名单根目录下（基于路径分量比较，防止前缀绕过）。
%%
%% @param File 文件绝对路径
%% @return `true' | `false'
%% @end
%%--------------------------------------------------------------------
%% 检查文件是否在允许根目录内，且不命中任何被禁模式。
patchPathAllowed(File) ->
    Allowed = patchAllowedRoots(),
    AbsFile = normalizePath(File),
    UnderAllowedRoot = lists:any(fun(Root) ->
        AbsRoot = normalizePath(Root),
        Comps = filename:split(AbsFile),
        RootComps = filename:split(AbsRoot),
        length(Comps) >= length(RootComps)
          andalso lists:prefix(RootComps, Comps)
    end, Allowed),
    UnderAllowedRoot andalso not patchPathDenied(AbsFile).

%% 检查绝对路径是否命中内置或配置中的禁止模式。
%% 内置模式覆盖敏感目录与备份/构建产物，配置可追加。
patchPathDenied(AbsFile) ->
    Comps = filename:split(AbsFile),
    Builtin = [
        ".git", "_build", "node_modules", ".rebar3",
        "priv", "c_src", "rebar3.crashdump", "erts",
        "log", "logs", ".ali.bak"
    ],
    Denied = case alConfig:get(patch, undefined) of
        undefined -> [];
        PatchCfg when is_map(PatchCfg) ->
            maps:get(deniedPatterns, PatchCfg, []);
        _ -> []
    end,
    Hit = lists:any(fun(Seg) -> lists:member(Seg, Comps) end, Builtin) orelse
          lists:any(fun(Pat) -> matchesPattern(Pat, AbsFile) end, Denied),
    Hit.

%% 简易 glob 匹配：仅支持 `*`（任意非分隔符序列）。
matchesPattern(Pat, Str) when is_list(Pat) ->
    matchesPattern(list_to_binary(Pat), Str);
matchesPattern(Pat, Str) when is_binary(Pat) ->
    Re = wildcard_to_regex(Pat),
    case re:run(Str, Re, [dotall]) of
        {match, _} -> true;
        nomatch -> false
    end;
matchesPattern(_, _) -> false.

%% 把 `*.ali.bak` 之类的 glob 编译成正则。
wildcard_to_regex(Pat) ->
    Escaped = re:replace(Pat, "([\\.\\^\\$\\|\\(\\)\\[\\]\\{\\}\\+\\?\\\\])", "\\\\&",
        [global, {return, binary}]),
    Starred = re:replace(Escaped, "\\*", ".*", [global, {return, binary}]),
    <<"^", Starred/binary, "$">>.

%%--------------------------------------------------------------------
%% @doc
%% 读取允许补丁的根目录列表：优先取配置 `patch.allowedRoots'，否则默认 `<root>/src'。
%%
%% @return 绝对路径列表
%% @end
%%--------------------------------------------------------------------
patchAllowedRoots() ->
    Root = alConfig:root(),
    case alConfig:get(patch, #{}) of
        #{allowedRoots := Roots} when is_list(Roots) ->
            [filename:absname(filename:join(Root, R)) || R <- Roots];
        _ ->
            [filename:absname(filename:join(Root, "src"))]
    end.

%%--------------------------------------------------------------------
%% @doc
%% 将值转换为 binary（多子句）：binary 原样、list 转 UTF-8、其它用 `~p' 格式化后转换。
%%
%% @param Value 任意值
%% @return binary
%% @end
%%--------------------------------------------------------------------
toBinary(Value) when is_binary(Value) ->
    Value;
toBinary(Value) when is_list(Value) ->
    unicode:characters_to_binary(Value);
toBinary(Value) ->
    unicode:characters_to_binary(io_lib:format("~p", [Value])).

%% 列表中第一个非 undefined 元素；列表为空返回 undefined。
firstDefined([]) -> undefined;
firstDefined([undefined | Rest]) -> firstDefined(Rest);
firstDefined([H | _]) -> H.

%%--------------------------------------------------------------------
%% @doc
%% 确保事务 ETS 表存在；若已存在则原样返回。
%%
%% @return 表名原子
%% @end
%%--------------------------------------------------------------------
ensureTxTable() ->
    try ets:new(?TxTable, [named_table, public, {read_concurrency, true}])
    catch error:badarg -> ?TxTable
    end.

%%--------------------------------------------------------------------
%% @doc
%% 幂等地确保补丁事务表已建立。供 {@link alEtsOwner} 在启动时以
%% 长生命周期属主身份预建该表，避免短命调用者建表后退出导致事务
%% （及其回滚能力）静默丢失。
%%
%% @return ok
%% @end
%%--------------------------------------------------------------------
-spec ensureStarted() -> ok.
ensureStarted() ->
    _ = ensureTxTable(),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% 记录一次批量事务：写入 backups/results/timestamp，并更新 `last' 指针。
%%
%% @param TxId 事务 ID
%% @param Backups 备份文件路径列表
%% @param Results 每条补丁的结果列表
%% @return `ok'
%% @end
%%--------------------------------------------------------------------
recordTransaction(TxId, Backups, Results) ->
    ensureTxTable(),
    ets:insert(?TxTable, {TxId, #{backups => Backups, results => Results, at => erlang:system_time(second)}}),
    ets:insert(?TxTable, {last, TxId}),
    ok.

%% 单次 apply 也记入事务表，使 rollbackLast / rollbackPatch 可用。
%% 回滚项 = undo 动作（map）或旧式 backup 路径（string），经 undoInstruction 归一。
recordSingleTransaction(Result) ->
    case undoInstruction(Result) of
        undefined ->
            Result;
        Undo ->
            TxId = erlang:unique_integer([positive, monotonic]),
            recordTransaction(TxId, [Undo], [Result]),
            Result#{transactionId => TxId}
    end.

%% 依次回滚所有备份项（undo 动作或备份路径）；任一失败记录错误日志并聚合返回。
rollbackFiles(Backups) ->
    Results = [rollbackFile(Backup) || Backup <- Backups],
    Errors = [E || {error, _} = E <- Results],
    case Errors of
        [] -> ok;
        _ ->
            logger:error("[alPatchManager] rollback failed for ~p", [Errors]),
            {error, Errors}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 执行单条回滚：支持 op 动作 map（unlink/restore/moveBack）与
%% 旧式 backup 路径（读备份写回 strip 后缀后的原路径）。
%%
%% @param Undo 回滚动作 map 或备份路径 string/binary
%% @return `ok' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
rollbackFile(#{type := unlink, target := Target}) ->
    rollbackUnlink(Target);
rollbackFile(#{type := restore, backup := Backup, target := Target}) ->
    rollbackRestore(Backup, Target);
rollbackFile(#{type := moveBack, backup := Backup, from := From, to := To}) ->
    case file:delete(To) of
        ok -> rollbackRestore(Backup, From);
        {error, Reason} -> {error, {unlinkFailed, To, Reason}}
    end;
rollbackFile(Backup) when is_list(Backup) orelse is_binary(Backup) ->
    BackupStr = backupToList(Backup),
    Original = stripBackupSuffix(BackupStr),
    rollbackRestore(BackupStr, Original).

%% 删除新建文件（create 回滚）；已不存在视为已回滚。
rollbackUnlink(Target) ->
    case file:delete(Target) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, Reason} ->
            logger:error("[alPatchManager] rollback unlink failed ~p: ~p", [Target, Reason]),
            {error, Reason}
    end.

%% 从备份文件恢复目标路径内容。
rollbackRestore(Backup, Target) ->
    case file:read_file(Backup) of
        {ok, Content} ->
            case file:write_file(Target, Content) of
                ok ->
                    ok;
                {error, Reason} ->
                    logger:error("[alPatchManager] rollbackFile write failed ~p -> ~p: ~p",
                                 [Backup, Target, Reason]),
                    {error, Reason}
            end;
        {error, Reason} ->
            logger:error("[alPatchManager] rollbackFile read failed ~p: ~p", [Backup, Reason]),
            {error, Reason}
    end.

%% 备份路径统一为 string（stripBackupSuffix 依赖 string）。
backupToList(B) when is_binary(B) -> unicode:characters_to_list(B);
backupToList(B) when is_list(B) -> B.

%%--------------------------------------------------------------------
%% @doc
%% 去除备份路径中的 `.ali.bak.<ts>' 后缀，恢复原文件路径。
%%
%% @param Backup 备份文件路径
%% @return 原文件路径；若无后缀则原样返回
%% @end
%%--------------------------------------------------------------------
stripBackupSuffix(Backup) ->
    case string:split(Backup, ".ali.bak.", trailing) of
        [Original, _Ts] -> Original;
        _ -> Backup
    end.
