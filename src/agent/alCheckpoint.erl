%%%-------------------------------------------------------------------
%% @doc Agent 检查点 / 续跑持久化。
%%
%% 每次 agent 主循环产生新一步时，把 "continuation"（messages + opts +
%% context + step + trace）持久化到 .ali/checkpoints/<taskId>.json，
%% 进程崩溃 / 用户取消 / 重启后可通过 load/1 取出再喂给
%% alToolRouter:resumeToolLoop/2 续跑。
%% @end
%%%-------------------------------------------------------------------

-module(alCheckpoint).

-export([save/2, load/1, list/0, delete/1, path/1]).

%%--------------------------------------------------------------------
%% @doc
%% 保存一个 checkpoint。TaskId 必须是 binary；Continuation 是
%% alToolRouter:runWithTools 在收到 pending 时返回的完整上下文。
%% 写入前会做轻量校验（必含 messages/opts/step），失败返回 error。
%%
%% @param TaskId       任务 ID（binary）
%% @param Continuation 续跑上下文 map
%% @return {ok, Path} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
save(TaskId, Continuation) when is_binary(TaskId), is_map(Continuation) ->
    case validateContinuation(Continuation) of
        ok ->
            case path(TaskId) of
                {error, _} = E ->
                    E;
                Path ->
                    case filelib:ensure_dir(filename:join(filename:dirname(Path), "dummy")) of
                        ok ->
                            %% 落盘前深度脱敏：对续跑上下文（messages/opts/context 等）按敏感键
                            %% 递归打码，避免凭据明文写入 .ali/checkpoints。
                            Sanitized = alPolicy:sanitizeTerm(Continuation),
                            Payload = Sanitized#{<<"savedAt">> => erlang:system_time(millisecond),
                                                 <<"version">> => 1},
                            Bin = alJson:encode(Payload),
                            case file:write_file(Path, Bin) of
                                ok -> {ok, Path};
                                {error, _} = E2 -> E2
                            end;
                        {error, _} = E3 ->
                            E3
                    end
            end;
        {error, _} = E -> E
    end;
save(_, _) ->
    {error, badArgs}.

%%--------------------------------------------------------------------
%% @doc
%% 加载指定 TaskId 的 checkpoint，并把 binary keys 还原为 atom keys。
%%
%% @param TaskId 任务 ID
%% @return {ok, Continuation} | {error, notFound | badJson}
%% @end
%%--------------------------------------------------------------------
load(TaskId) when is_binary(TaskId); is_list(TaskId) ->
    case path(TaskId) of
        {error, _} = E -> E;
        Path ->
            case file:read_file(Path) of
                {ok, Bin} ->
                    try alJson:decode(Bin) of
                        Decoded when is_map(Decoded) ->
                            {ok, normalizeContinuation(Decoded)};
                        _ ->
                            {error, badJson}
                    catch
                        _:_ -> {error, badJson}
                    end;
                {error, _} = E2 -> E2
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 列出所有已保存的 checkpoint ID（按文件 mtime 倒序）。
%%
%% @return [TaskId]
%% @end
%%--------------------------------------------------------------------
list() ->
    Dir = checkpointDir(),
    case file:list_dir(Dir) of
        {ok, Files} ->
            JsonFiles = [F || F <- Files, filename:extension(F) =:= ".json"],
            WithStat = lists:filtermap(fun(F) ->
                Full = filename:join(Dir, F),
                case file:read_file_info(Full) of
                    {ok, Info} -> {true, {F, Info}};
                    _ -> false
                end
            end, JsonFiles),
            Sorted = lists:sort(fun({_, A}, {_, B}) ->
                element(7, A) >= element(7, B)
            end, WithStat),
            [filename:basename(F, ".json") || {F, _} <- Sorted];
        {error, _} -> []
    end.

%%--------------------------------------------------------------------
%% @doc
%% 删除指定 TaskId 的 checkpoint。
%%
%% @param TaskId 任务 ID
%% @return ok | {error, Reason}
%% @end
%%--------------------------------------------------------------------
delete(TaskId) when is_binary(TaskId); is_list(TaskId) ->
    case path(TaskId) of
        {error, _} = E -> E;
        Path ->
            case file:delete(Path) of
                ok -> ok;
                {error, enoent} -> ok;
                {error, _} = E2 -> E2
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 计算 checkpoint 文件路径：<dataDir>/checkpoints/<taskId>.json。
%%
%% @param TaskId 任务 ID
%% @return 绝对路径（list） | {error, invalidTaskId}
%% @end
%%--------------------------------------------------------------------
path(TaskId) when is_binary(TaskId) ->
    path(unicode:characters_to_list(TaskId));
path(TaskId) when is_list(TaskId) ->
    case sanitizeSegment(TaskId) of
        {error, _} = E -> E;
        Clean -> filename:join(checkpointDir(), Clean ++ ".json")
    end.

%%--------------------------------------------------------------------
%% @doc
%% 净化 checkpoint 段：仅保留字母/数字/下划线/连字符/点，折叠连续的点，
%% 去除首尾的 . _ -，防止路径穿越（..、/、\）与空名。借鉴
%% alSessionMgr:sanitizeSessionBase 的逻辑；净化后为空（纯 . _ - 或空串）
%% 返回 {error, invalidTaskId}。
%%
%% @end
%%--------------------------------------------------------------------
sanitizeSegment(TaskId) when is_binary(TaskId) ->
    sanitizeSegment(unicode:characters_to_list(TaskId));
sanitizeSegment(TaskId) when is_list(TaskId) ->
    Filtered = [safeCheckpointChar(C) || C <- TaskId],
    Collapsed = collapseDots(Filtered, []),
    case string:trim(Collapsed, both, "._-") of
        "" -> {error, invalidTaskId};
        Clean -> Clean
    end.

safeCheckpointChar(C) when C >= $a, C =< $z -> C;
safeCheckpointChar(C) when C >= $A, C =< $Z -> C;
safeCheckpointChar(C) when C >= $0, C =< $9 -> C;
safeCheckpointChar($_) -> $_;
safeCheckpointChar($-) -> $-;
safeCheckpointChar($.) -> $.;
safeCheckpointChar(_) -> $_.

%% 将连续的点折叠为单个点，避免出现 ".." 等穿越序列。
collapseDots([], Acc) -> lists:reverse(Acc);
collapseDots([$., $. | Rest], Acc) -> collapseDots([$. | Rest], Acc);
collapseDots([C | Rest], Acc) -> collapseDots(Rest, [C | Acc]).

%% 文件路径统一为 Unicode charlist，避免 binary 与 `++` 混用。
checkpointDir() ->
    case alConfig:dataPath("checkpoints") of
        Dir when is_binary(Dir) -> unicode:characters_to_list(Dir);
        Dir when is_list(Dir) -> Dir
    end.

%%--------------------------------------------------------------------
%% @doc
%% 轻量校验 Continuation 必含 messages/opts/step，避免空文件误导
%% resume 流程。其它字段不做强制，由调用方控制。
%%
%% @param Continuation 续跑上下文
%% @return ok | {error, Reason}
%% @end
%%--------------------------------------------------------------------
validateContinuation(#{messages := Msgs, opts := _Opts, step := Step})
        when is_list(Msgs), is_integer(Step) ->
    ok;
validateContinuation(#{<<"messages">> := Msgs, <<"opts">> := _, <<"step">> := Step})
        when is_list(Msgs), is_integer(Step) ->
    ok;
validateContinuation(_) ->
    {error, badContinuation}.

%% 把 JSON 解出的 binary-key map 还原为 atom-key（与 resumeToolLoop
%% 期望的形状对齐）。messages 中的 role 统一为 atom。
normalizeContinuation(M) when is_map(M) ->
    Norm = maps:from_list([{normalizeCk(K), normalizeCv(V)} || {K, V} <- maps:to_list(M)]),
    case maps:get(messages, Norm, undefined) of
        Msgs when is_list(Msgs) ->
            Norm#{messages => [normalizeCkMessage(Msg) || Msg <- Msgs]};
        _ ->
            Norm
    end.

normalizeCkMessage(Msg) when is_map(Msg) ->
    alSessionMgr:normalizeMessage(Msg);
normalizeCkMessage(Msg) ->
    Msg.

normalizeCk(K) when is_binary(K) ->
    try binary_to_existing_atom(K, utf8) catch _:_ -> K end;
normalizeCk(K) -> K.

normalizeCv(V) when is_map(V) ->
    maps:from_list([{normalizeCk(K2), normalizeCv(V2)} || {K2, V2} <- maps:to_list(V)]);
normalizeCv(V) when is_list(V) ->
    [normalizeCv(I) || I <- V];
normalizeCv(V) -> V.
