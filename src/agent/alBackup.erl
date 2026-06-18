%%%-------------------------------------------------------------------
%%% @doc 文件备份与恢复模块。
%%%
%%% 在修改项目文件前自动创建时间戳快照，备份存放于
%%% {@code .al/backups/<毫秒时间戳>/} 目录，并附带 JSON 元数据
%%% （原始路径、备份路径、时间戳等）。支持按文件列出备份、
%%% 恢复到指定或最新版本，以及按文件分组清理超出上限的旧备份。
%%% @end
%%%-------------------------------------------------------------------
-module(alBackup).

-include_lib("kernel/include/file.hrl").

-export([
    backup_dir/0,
    backup_file/1,
    backup_file/2,
    list_backups/1,
    restore/1,
    restore_latest/1,
    cleanup/0,
    cleanup/1
]).

%% 每个原始文件最多保留的备份份数
-define(MAX_BACKUPS_PER_FILE, 50).

%% @doc 返回备份根目录路径。
%% 基于项目根目录下的 `.al/backups`，若目录不存在则自动创建。
%% @returns {string()} 备份目录的绝对路径
-spec backup_dir() -> string().
backup_dir() ->
    Root = alToolProject:findProjectRootFromModule(),
    Dir = filename:join(Root, ".al/backups"),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.

%% @doc 备份指定文件（无额外元数据）。
%% @param AbsPath 待备份文件的绝对路径
%% @returns `{ok, map()}` 成功时返回含 original/backup/timestamp 等字段的元数据；
%%          `{error, term()}` 文件不存在、非普通文件或复制失败
-spec backup_file(string()) -> {ok, map()} | {error, term()}.
backup_file(AbsPath) ->
    backup_file(AbsPath, #{}).

%% @doc 备份指定文件并合并自定义元数据。
%% 以当前毫秒时间戳创建子目录，复制文件并写入 `<文件名>.meta` JSON 文件。
%% @param AbsPath 待备份文件的绝对路径
%% @param Meta 附加元数据 map，会与系统字段合并写入 .meta 文件
%% @returns 同 backup_file/1
-spec backup_file(string(), map()) -> {ok, map()} | {error, term()}.
backup_file(AbsPath, Meta) ->
    case file:read_file_info(AbsPath) of
        {ok, #file_info{type = regular}} ->
            Ts = integer_to_binary(erlang:system_time(millisecond)),
            Base = filename:basename(AbsPath),
            DestDir = filename:join(backup_dir(), Ts),
            ok = filelib:ensure_dir(filename:join(DestDir, "x")),
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
                    ok = file:write_file(MetaPath, llmJson:encode(Payload)),
                    {ok, Payload};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason};
        {ok, _} ->
            {error, not_a_file}
    end.

%% @doc 列出指定原始文件的所有备份记录，按时间戳降序排列。
%% @param AbsPath 原始文件的绝对路径（用于匹配 basename 与 meta 中的 original）
%% @returns `[map()]` 每项含 timestamp、backupPath、original、meta 字段
-spec list_backups(string()) -> [map()].
list_backups(AbsPath) ->
    Dir = backup_dir(),
    case filelib:is_dir(Dir) of
        false -> [];
        true ->
            TsDirs = filelib:wildcard(filename:join(Dir, "*")),
            Base = filename:basename(AbsPath),
            lists:sort(fun(A, B) ->
                maps:get(timestamp, A, <<>>) >= maps:get(timestamp, B, <<>>)
            end, lists:filtermap(fun(D) ->
                case backup_entry(D, Base, AbsPath) of
                    undefined -> false;
                    E -> {true, E}
                end
            end, TsDirs))
    end.

%% 从时间戳目录中解析单条备份记录；文件不存在时返回 undefined
backup_entry(TsDir, Base, AbsPath) ->
    File = filename:join(TsDir, Base),
    MetaFile = File ++ ".meta",
    case filelib:is_file(File) of
        true ->
            Meta = read_meta(MetaFile),
            #{
                timestamp => filename:basename(TsDir),
                backupPath => File,
                original => AbsPath,
                meta => Meta
            };
        false ->
            undefined
    end.

%% 读取 .meta JSON 文件；解析失败或文件缺失时返回空 map
read_meta(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            try llmJson:decode(Bin) catch _:_ -> #{} end;
        _ -> #{}
    end.

%% @doc 将备份文件复制回 meta 中记录的原始路径。
%% @param BackupPath 备份文件路径（binary 或 string）
%% @returns `ok` 或 `{error, missingOriginal | term()}`
-spec restore(binary() | string()) -> ok | {error, term()}.
restore(BackupPath) ->
    Path = to_list(BackupPath),
    MetaPath = Path ++ ".meta",
    Meta = read_meta(MetaPath),
    Original = maps:get(<<"original"/utf8>>, Meta, maps:get(original, Meta, undefined)),
    case Original of
        undefined -> {error, missingOriginal};
        Orig ->
            OrigStr = to_list(Orig),
            case file:copy(Path, OrigStr) of
                {ok, _} -> ok;
                {error, Reason} -> {error, Reason}
            end
    end.

%% @doc 恢复指定原始文件的最新一份备份。
%% @param AbsPath 原始文件绝对路径
%% @returns `ok` 或 `{error, no_backup | term()}`
-spec restore_latest(string()) -> ok | {error, term()}.
restore_latest(AbsPath) ->
    case list_backups(AbsPath) of
        [#{backupPath := P} | _] -> restore(P);
        [] -> {error, no_backup}
    end.

%% @doc 清理所有超出默认上限（50 份/文件）的旧备份。
%% @returns `ok`
-spec cleanup() -> ok.
cleanup() ->
    cleanup(?MAX_BACKUPS_PER_FILE).

%% 清理所有超出上限的旧备份
%% @doc 按原始文件分组，每组仅保留最新的 MaxPerFile 份备份，删除其余时间戳目录。
%% @param MaxPerFile 每个原始文件允许保留的最大备份数
%% @returns `ok`
-spec cleanup(non_neg_integer()) -> ok.
cleanup(MaxPerFile) ->
    Dir = backup_dir(),
    case filelib:is_dir(Dir) of
        true ->
            Files = list_all_backup_files(Dir),
            Grouped = group_by_original(Files),
            lists:foreach(fun({_Original, Backups}) ->
                Sorted = lists:sort(fun(A, B) ->
                    maps:get(timestamp, A, 0) >= maps:get(timestamp, B, 0)
                end, Backups),
                {_Keep, Delete} = lists:split(min(MaxPerFile, length(Sorted)), Sorted),
                lists:foreach(fun(#{dir := TsDir}) ->
                    delete_dir(TsDir)
                end, Delete)
            end, Grouped),
            ok;
        false ->
            ok
    end.

%% 扫描备份根目录下所有时间戳子目录，收集含 meta 的备份条目
list_all_backup_files(Dir) ->
    TsDirs = filelib:wildcard(filename:join(Dir, "*")),
    lists:filtermap(fun(TsDir) ->
        case filelib:is_dir(TsDir) of
            true ->
                MetaFiles = filelib:wildcard(filename:join(TsDir, "*.meta")),
                case MetaFiles of
                    [] -> false;
                    [MF | _] ->
                        _Base = filename:basename(MF, ".meta"),
                        Meta = read_meta(MF),
                        Original = maps:get(<<"original"/utf8>>, Meta,
                            maps:get(original, Meta, undefined)),
                        {true, #{
                            dir => TsDir,
                            original => to_list(Original),
                            timestamp => try list_to_integer(filename:basename(TsDir))
                                catch _:_ -> 0 end
                        }}
                end;
            false ->
                false
        end
    end, TsDirs).

%% 按 original 路径将备份条目分组为 `{Original, [Entry]}` 列表
group_by_original(Files) ->
    lists:foldl(fun(#{original := Orig} = F, Acc) ->
        maps:update_with(Orig, fun(V) -> [F | V] end, [F], Acc)
    end, #{}, Files).

%% 递归删除时间戳目录内的所有文件后移除目录本身
delete_dir(Dir) ->
    case filelib:is_dir(Dir) of
        true ->
            lists:foreach(fun(F) -> file:delete(filename:join(Dir, F)) end,
                filelib:wildcard(filename:join(Dir, "*"))),
            file:del_dir(Dir);
        false ->
            ok
    end.

%% 将 binary 或 list 统一转为 string
to_list(X) when is_list(X) -> X;
to_list(X) when is_binary(X) -> binary_to_list(X).