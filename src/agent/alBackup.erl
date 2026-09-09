%%%-------------------------------------------------------------------
%% @doc 文件备份与恢复模块。
%%
%% 修改前快照：备份位于 `.ali/backups/<millisecond_timestamp>/`，
%% 同级有 `<name>.meta` JSON 元数据（原路径、备份路径、时间戳、可选
%% session id）。支持按文件 list/restore、会话级回滚，以及上限清理旧备份。
%%
%% 自 v1 alBackup 适配：项目根来自 {@link alConfig}（可用 `backupDir'
%% 配置），JSON I/O 经 {@link alJson}。
%% @end
%%%-------------------------------------------------------------------

-module(alBackup).

-include_lib("kernel/include/file.hrl").

-export([
    backupDir/0,
    backupFile/1,
    backupFile/2,
    listBackups/1,
    listSessionBackups/1,
    restore/1,
    restoreLatest/1,
    restoreSession/1,
    cleanup/0,
    cleanup/1,
    cleanupExpired/0,
    cleanupExpired/1
]).

-define(MaxBackupsPerFile, 50).
%% 默认 TTL：30 天前的备份视为过期，启动时清理。
-define(DefaultBackupTtlMs, 30 * 24 * 60 * 60 * 1000).

%%--------------------------------------------------------------------
%% @doc
%% 返回配置的备份根目录（默认 `<dataDir>/backups`），若不存在则创建。
%%
%% @return 备份目录字符串
%% @end
%%--------------------------------------------------------------------
-spec backupDir() -> string().
backupDir() ->
    Agent = alConfig:get(agent, #{}),
    Dir = case maps:get(backupDir, Agent, undefined) of
        undefined ->
            case alConfig:get(backupDir, undefined) of
                undefined -> alConfig:dataPath("backups");
                Sub -> resolveBackupPath(Sub)
            end;
        Sub ->
            resolveBackupPath(Sub)
    end,
    case filelib:ensure_dir(filename:join(Dir, "x")) of
        ok -> ok;
        {error, Reason} ->
            logger:warning("alBackup ensure_dir failed for ~p: ~p", [Dir, Reason])
    end,
    Dir.

%% 绝对路径原样；相对路径落到 dataDir 下（兼容旧的 `.ali/backups`）。
resolveBackupPath(Path) when is_binary(Path) ->
    resolveBackupPath(unicode:characters_to_list(Path));
resolveBackupPath(Path) when is_list(Path) ->
    case filename:pathtype(Path) of
        relative ->
            case Path =:= ".ali/backups" orelse lists:prefix(".ali/", Path) of
                true -> alConfig:resolvePath(alConfig:root(), Path);
                false -> alConfig:dataPath(Path)
            end;
        _ ->
            filename:absname(Path)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 备份文件（不带额外元数据）。等价于传入空 Meta 调用 {@link backupFile/2}。
%%
%% @param AbsPath 文件绝对路径
%% @return `{ok, MetaMap}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
-spec backupFile(string()) -> {ok, map()} | {error, term()}.
backupFile(AbsPath) ->
    backupFile(AbsPath, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 备份文件并将自定义元数据合并写入 .meta JSON。
%% 备份以时间戳目录组织：`<backupDir>/<timestamp>/<basename>'，
%% 同时写入 `<basename>.meta' 记录原路径、时间戳等元数据。
%%
%% @param AbsPath 文件绝对路径
%% @param Meta 额外元数据 map
%% @return `{ok, MetaMap}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
-spec backupFile(string(), map()) -> {ok, map()} | {error, term()}.
backupFile(AbsPath, Meta) ->
    case file:read_file_info(AbsPath) of
        {ok, #file_info{type = regular}} ->
            Ts = tsName(),
            Base = filename:basename(AbsPath),
            DestDir = filename:join(backupDir(), Ts),
            case filelib:ensure_dir(filename:join(DestDir, "x")) of
                ok ->
                    Dest = filename:join(DestDir, Base),
                    case file:copy(AbsPath, Dest) of
                        {ok, _} ->
                            MetaPath = filename:join(DestDir, Base ++ ".meta"),
                            Payload = Meta#{
                                original => AbsPath,
                                backup => Dest,
                                timestamp => Ts,
                                at => erlang:system_time(millisecond)
                            },
                            case file:write_file(MetaPath, alJson:encode(Payload)) of
                                ok ->
                                    {ok, Payload};
                                {error, Reason} ->
                                    _ = file:delete(Dest),
                                    {error, {metaWriteFailed, Reason}}
                            end;
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason};
        {ok, _} ->
            {error, notAFile}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 列出指定文件的所有备份条目，按时间戳从新到旧排序。
%%
%% @param AbsPath 文件绝对路径
%% @return 备份条目 map 列表（新→旧）
%% @end
%%--------------------------------------------------------------------
-spec listBackups(string()) -> [map()].
listBackups(AbsPath) ->
    Dir = backupDir(),
    case filelib:is_dir(Dir) of
        false -> [];
        true ->
            TsDirs = filelib:wildcard(filename:join(Dir, "*")),
            Base = filename:basename(AbsPath),
            Sorted = lists:sort(fun(A, B) ->
                maps:get(timestamp, A, <<>>) >= maps:get(timestamp, B, <<>>)
            end, lists:filtermap(fun(D) ->
                case backupEntry(D, Base, AbsPath) of
                    undefined -> false;
                    E -> {true, E}
                end
            end, TsDirs)),
            Sorted
    end.

%%--------------------------------------------------------------------
%% @doc
%% 检查时间戳目录中是否存在指定文件的备份，存在则返回备份条目 map（含时间戳、
%% 备份路径、原路径与元数据），否则返回 undefined。
%%
%% @param TsDir 时间戳目录
%% @param Base 文件名
%% @param AbsPath 原文件绝对路径
%% @return map() | undefined
%% @end
%%--------------------------------------------------------------------
backupEntry(TsDir, Base, AbsPath) ->
    File = filename:join(TsDir, Base),
    MetaFile = File ++ ".meta",
    case filelib:is_file(File) of
        true ->
            Meta = readMeta(MetaFile),
            #{
                timestamp => filename:basename(TsDir),
                backupPath => File,
                original => AbsPath,
                meta => Meta
            };
        false ->
            undefined
    end.

%%--------------------------------------------------------------------
%% @doc
%% 读取并解析 .meta 元数据 JSON 文件；读取或解析失败时返回空 map。
%%
%% @param Path .meta 文件路径
%% @return map()
%% @end
%%--------------------------------------------------------------------
readMeta(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            try alJson:decode(Bin) of
                Map when is_map(Map) -> Map;
                _ -> #{}
            catch _:_ -> #{}
            end;
        _ -> #{}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 将备份文件还原到 .meta 中记录的原路径。
%%
%% @param BackupPath 备份文件路径（binary 或 string）
%% @return `ok' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
-spec restore(binary() | string()) -> ok | {error, term()}.
restore(BackupPath) ->
    Path = toList(BackupPath),
    %% 纵深防御：备份文件路径必须落在备份目录之内，拒绝任意路径/穿越。
    case isWithinBackupDir(Path) of
        false -> {error, forbidden};
        true -> restore1(Path)
    end.

%% 判断路径规范化后是否位于备份目录内（拒绝 `..` 与目录外绝对路径）。
isWithinBackupDir(Path) ->
    Root = filename:absname(backupDir()),
    Full = filename:absname(Path),
    RootParts = filename:split(Root),
    FullParts = filename:split(Full),
    not lists:member("..", FullParts)
        andalso length(FullParts) >= length(RootParts)
        andalso lists:sublist(FullParts, length(RootParts)) =:= RootParts.

restore1(Path) ->
    MetaPath = Path ++ ".meta",
    Meta = readMeta(MetaPath),
    Original = maps:get(<<"original">>, Meta, maps:get(original, Meta, undefined)),
    case Original of
        undefined -> {error, missingOriginal};
        Orig ->
            OrigStr = toList(Orig),
            %% 纵深防御：.meta 中记录的 original 路径必须位于项目根内，
            %% 防止被篡改的 .meta 把备份内容写到任意路径（任意文件覆盖）。
            case isWithinProjectRoot(OrigStr) of
                false -> {error, forbidden};
                true ->
                    case file:copy(Path, OrigStr) of
                        {ok, _} -> ok;
                        {error, Reason} -> {error, Reason}
                    end
            end
    end.

%% 判断路径规范化后是否位于项目根内（拒绝 `..` 与目录外绝对路径）。
isWithinProjectRoot(Path) ->
    Root = filename:absname(alConfig:root()),
    Full = filename:absname(Path),
    RootParts = filename:split(Root),
    FullParts = filename:split(Full),
    not lists:member("..", FullParts)
        andalso length(FullParts) >= length(RootParts)
        andalso lists:sublist(FullParts, length(RootParts)) =:= RootParts.

%%--------------------------------------------------------------------
%% @doc
%% 还原指定文件的最新一次备份。无备份时返回 `{error, noBackup}'。
%%
%% @param AbsPath 文件绝对路径
%% @return `ok' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
-spec restoreLatest(string()) -> ok | {error, term()}.
restoreLatest(AbsPath) ->
    case listBackups(AbsPath) of
        [#{backupPath := P} | _] -> restore(P);
        [] -> {error, noBackup}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 列出标记了指定 session id 的备份条目，按时间戳从旧到新排序
%% （会话级回滚需 earliest 优先）。
%%
%% @param SessionId 会话 ID（binary 或 string）
%% @return 备份条目 map 列表（旧→新）
%% @end
%%--------------------------------------------------------------------
-spec listSessionBackups(binary() | string()) -> [map()].
listSessionBackups(SessionId) ->
    SidBin = toBinary(SessionId),
    Dir = backupDir(),
    case filelib:is_dir(Dir) of
        false -> [];
        true ->
            TsDirs = filelib:wildcard(filename:join(Dir, "*")),
            lists:sort(fun(A, B) ->
                maps:get(timestamp, A, <<>>) =< maps:get(timestamp, B, <<>>)
            end, lists:filtermap(fun(D) ->
                case sessionBackupEntry(D, SidBin) of
                    undefined -> false;
                    E -> {true, E}
                end
            end, TsDirs))
    end.

%%--------------------------------------------------------------------
%% @doc
%% 检查时间戳目录中的 .meta 是否属于指定 session：sessionId 匹配则返回备份条目 map，
%% 否则返回 undefined。一个目录只取首个 .meta 判定。
%%
%% @param TsDir 时间戳目录
%% @param SidBin 会话 ID（binary）
%% @return map() | undefined
%% @end
%%--------------------------------------------------------------------
sessionBackupEntry(TsDir, SidBin) ->
    MetaFiles = filelib:wildcard(filename:join(TsDir, "*.meta")),
    case MetaFiles of
        [] -> undefined;
        [MF | _] ->
            Meta = readMeta(MF),
            MetaSid = maps:get(<<"sessionId">>, Meta, maps:get(sessionId, Meta, undefined)),
            case MetaSid =:= SidBin of
                true ->
                    Base = filename:basename(MF, ".meta"),
                    File = filename:join(TsDir, Base),
                    Original = maps:get(<<"original">>, Meta,
                        maps:get(original, Meta, undefined)),
                    case Original of
                        undefined ->
                            undefined;
                        _ ->
                            #{
                                timestamp => filename:basename(TsDir),
                                backupPath => File,
                                original => toList(Original),
                                meta => Meta
                            }
                    end;
                false ->
                    undefined
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 会话级回滚：对每个不同的原文件，还原该会话期间产生的最早一次备份
%% （即会话首次编辑前的快照）。
%%
%% 返回 map 含 `restored'（已还原路径列表）、`errors'（失败项）、
%% `sessionId' 与 `fileCount'。无备份时返回空列表与提示。
%%
%% @param SessionId 会话 ID
%% @return `{ok, ResultMap}'
%% @end
%%--------------------------------------------------------------------
-spec restoreSession(binary() | string()) -> {ok, map()} | {error, term()}.
restoreSession(SessionId) ->
    Backups = listSessionBackups(SessionId),
    case Backups of
        [] ->
            {ok, #{restored => [], errors => [], fileCount => 0,
                   message => <<"No backups found for this session">>}};
        _ ->
            Grouped = lists:foldl(fun(B, Acc) ->
                Orig = maps:get(original, B),
                maps:update_with(Orig, fun(V) -> V ++ [B] end, [B], Acc)
            end, #{}, Backups),
            {Restored, Errors} = maps:fold(fun(Orig, BList, {RAcc, EAcc}) ->
                case BList of
                    [Earliest | _] ->
                        BP = maps:get(backupPath, Earliest),
                        case isWithinProjectRoot(Orig) of
                            false ->
                                {RAcc, [#{path => Orig, error => forbidden} | EAcc]};
                            true ->
                                case file:copy(BP, Orig) of
                                    {ok, _} -> {[Orig | RAcc], EAcc};
                                    {error, Reason} ->
                                        {RAcc, [#{path => Orig, error => Reason} | EAcc]}
                                end
                        end
                end
            end, {[], []}, Grouped),
            {ok, #{
                restored => lists:reverse(Restored),
                errors => lists:reverse(Errors),
                sessionId => toBinary(SessionId),
                fileCount => length(Restored)
            }}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 按默认上限（每文件 50 份）清理旧备份。
%%
%% @return `ok'
%% @end
%%--------------------------------------------------------------------
-spec cleanup() -> ok.
cleanup() ->
    cleanup(?MaxBackupsPerFile).

%%--------------------------------------------------------------------
%% @doc
%% 按原文件分组，仅保留每组最新的 MaxPerFile 份备份，其余删除。
%%
%% @param MaxPerFile 每文件保留的备份数上限
%% @return `ok'
%% @end
%%--------------------------------------------------------------------
-spec cleanup(non_neg_integer()) -> ok.
cleanup(MaxPerFile) ->
    Dir = backupDir(),
    case filelib:is_dir(Dir) of
        true ->
            Files = listAllBackupFiles(Dir),
            Grouped = groupByOriginal(Files),
            lists:foreach(fun({_Original, Backups}) ->
                Sorted = lists:sort(fun(A, B) ->
                    maps:get(timestamp, A, 0) >= maps:get(timestamp, B, 0)
                end, Backups),
                {_Keep, Delete} = lists:split(min(MaxPerFile, length(Sorted)), Sorted),
                lists:foreach(fun(#{dir := TsDir}) ->
                    deleteDir(TsDir)
                end, Delete)
            end, Grouped),
            ok;
        false ->
            ok
    end.

%%--------------------------------------------------------------------
%% @doc
%% 按默认 TTL（30 天）清理过期备份。返回被清理的目录数。
%%
%% @return `{ok, integer()}'
%% @end
%%--------------------------------------------------------------------
-spec cleanupExpired() -> {ok, non_neg_integer()}.
cleanupExpired() ->
    cleanupExpired(?DefaultBackupTtlMs).

%%--------------------------------------------------------------------
%% @doc
%% 按指定 TTL（毫秒）清理过期备份：扫描 backupDir 下所有时间戳目录，
%% 凡 .meta 中 `at` 字段（毫秒时间戳）距今超过 TTL 的目录整目录删除。
%% 同时配合默认 cleanup/0 按文件份数封顶，避免长期运行堆积。
%%
%% @param TtlMs TTL（毫秒）
%% @return `{ok, DeletedCount}'
%% @end
%%--------------------------------------------------------------------
-spec cleanupExpired(non_neg_integer()) -> {ok, non_neg_integer()}.
cleanupExpired(TtlMs) when is_integer(TtlMs), TtlMs >= 0 ->
    Dir = backupDir(),
    case filelib:is_dir(Dir) of
        false -> {ok, 0};
        true ->
            TsDirs = filelib:wildcard(filename:join(Dir, "*")),
            NowMs = erlang:system_time(millisecond),
            Threshold = NowMs - TtlMs,
            Deleted = lists:foldl(fun(TsDir, Acc) ->
                case isTsExpired(TsDir, Threshold) of
                    true ->
                        deleteDir(TsDir),
                        Acc + 1;
                    false ->
                        Acc
                end
            end, 0, TsDirs),
            {ok, Deleted}
    end.

%% 判断时间戳目录是否过期：优先读 .meta 中的 `at` 毫秒时间戳；
%% 失败时回退到目录名前缀的毫秒时间戳；都失败则视为未过期（保守不删）。
isTsExpired(TsDir, Threshold) ->
    MetaFiles = filelib:wildcard(filename:join(TsDir, "*.meta")),
    case MetaFiles of
        [] ->
            %% 无 .meta 时退化为目录名时间戳
            tsExpired(parseTs(filename:basename(TsDir)), Threshold);
        [MF | _] ->
            Meta = readMeta(MF),
            At = maps:get(<<"at">>, Meta, maps:get(at, Meta, undefined)),
            case is_integer(At) of
                true -> At < Threshold;
                false -> tsExpired(parseTs(filename:basename(TsDir)), Threshold)
            end
    end.

%% parseTs 解析失败返回 0，此时保守视为未过期（不删），避免误删无 .meta 目录。
tsExpired(0, _Threshold) -> false;
tsExpired(Ts, Threshold) -> Ts < Threshold.

%%--------------------------------------------------------------------
%% @doc
%% 列出备份根目录下所有备份条目（含目录路径、原文件路径、时间戳整数），
%% 用于 cleanup 时按原文件分组。无 .meta 的目录被跳过。
%%
%% @param Dir 备份根目录
%% @return [map()]
%% @end
%%--------------------------------------------------------------------
listAllBackupFiles(Dir) ->
    TsDirs = filelib:wildcard(filename:join(Dir, "*")),
    lists:filtermap(fun(TsDir) ->
        case filelib:is_dir(TsDir) of
            true ->
                MetaFiles = filelib:wildcard(filename:join(TsDir, "*.meta")),
                case MetaFiles of
                    [] -> false;
                    [MF | _] ->
                        Meta = readMeta(MF),
                        Original = maps:get(<<"original">>, Meta,
                            maps:get(original, Meta, undefined)),
                        case Original of
                            undefined ->
                                false;
                            _ ->
                                {true, #{
                                    dir => TsDir,
                                    original => toList(Original),
                                    timestamp => parseTs(filename:basename(TsDir))
                                }}
                        end
                end;
            false ->
                false
        end
    end, TsDirs).

%%--------------------------------------------------------------------
%% @doc
%% 将备份条目按 original 字段分组，返回 [{Original, [Backup]}] 列表。
%%
%% @param Files listAllBackupFiles 的输出
%% @return [{Original, [BackupMap]}]
%% @end
%%--------------------------------------------------------------------
groupByOriginal(Files) ->
    Grouped = lists:foldl(fun(#{original := Orig} = F, Acc) ->
        maps:update_with(Orig, fun(V) -> [F | V] end, [F], Acc)
    end, #{}, Files),
    maps:to_list(Grouped).

%%--------------------------------------------------------------------
%% @doc
%% 删除一个备份时间戳目录：先删除目录内所有文件，再删除空目录。
%% 非目录时直接返回 ok。
%%
%% @param Dir 待删除的目录
%% @return ok
%% @end
%%--------------------------------------------------------------------
deleteDir(Dir) ->
    case filelib:is_dir(Dir) of
        true ->
            lists:foreach(fun(F) -> file:delete(filename:join(Dir, F)) end,
                filelib:wildcard(filename:join(Dir, "*"))),
            file:del_dir(Dir);
        false ->
            ok
    end.

%%--------------------------------------------------------------------
%% @doc
%% 将 list 原样返回、binary 转 list，用于统一路径表示。
%%
%% @return list()
%% @end
%%--------------------------------------------------------------------
toList(X) when is_list(X) -> X;
toList(X) when is_binary(X) -> unicode:characters_to_list(X).

%%--------------------------------------------------------------------
%% @doc
%% 生成备份目录名：`<毫秒时间戳>-<单调唯一整数>'。附加单调整数避免
%% 同毫秒多次备份互相覆盖（{@link backupFile/2} 在并发或快速连续调用时
%% 可能产生相同的毫秒时间戳）。
%%
%% @return binary()
%% @end
%%--------------------------------------------------------------------
tsName() ->
    MsBin = integer_to_binary(erlang:system_time(millisecond)),
    UniqBin = integer_to_binary(erlang:unique_integer([monotonic])),
    <<MsBin/binary, "-", UniqBin/binary>>.

%%--------------------------------------------------------------------
%% @doc
%% 从时间戳目录名中解析毫秒时间戳前缀，用于 cleanup 排序。解析失败返回 0。
%%
%% @param Name 目录名（list 或 binary）
%% @return 非负整数
%% @end
%%--------------------------------------------------------------------
parseTs(Name) ->
    Bin = toBinary(Name),
    case binary:split(Bin, <<"-">>) of
        [TsPart | _] ->
            try binary_to_integer(TsPart) catch _:_ -> 0 end;
        _ ->
            0
    end.

%%--------------------------------------------------------------------
%% @doc
%% 将 binary / list / atom 统一转换为 binary。
%%
%% @return binary()
%% @end
%%--------------------------------------------------------------------
toBinary(X) when is_binary(X) -> X;
toBinary(X) when is_list(X) -> unicode:characters_to_binary(X);
toBinary(X) when is_atom(X) -> atom_to_binary(X, utf8).
