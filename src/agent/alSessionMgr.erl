%%%-------------------------------------------------------------------
%% @doc 带 SQLite 持久化的会话管理器。
%%      消息双写到 DB；重启后首次访问时惰性从 DB 重载。
%%      DB 层不可用时退化为仅内存。
%% @end
%%%-------------------------------------------------------------------

-module(alSessionMgr).

-behaviour(gen_server).

-export([start_link/0, createSession/1, getContext/1, appendMessage/2,
         ensureSession/2, clearMessages/1,
         exportSession/1, importSession/1, saveSession/1, loadSessionFile/1,
         listSavedSessions/0, sessionsDir/0, sessionFilePath/1,
         setSummary/2, appendToolTrace/2, appendToolTraces/2, addTokenUsage/2,
         appendCritique/2, getSessionFull/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
%% Test exports — pure helpers
-export([resolveSession/2, encodeMessage/1, encodeKey/1, encodeValue/1,
         decodeMessage/1, normalizeMessage/1, normalizeKey/1, normalizeValue/1,
         normalizeToolTraceEntry/1, toBinary/1]).

-define(SERVER, ?MODULE).

%% 会话读写的默认 gen_server 调用超时。
%% 与 alLocalDb 的 120s 落盘预算对齐：会话写路径最终会把整批 artifacts
%% 落到文件后端，慢盘/大 JSONL 下可能远超默认的 5s。若沿用隐式 5s，
%% 调用方（agent 收尾记录）会先超时退出，而服务端仍在继续写——
%% 表现为「回答成功但 agent 崩溃」。
-define(DefaultCallTimeoutMs, 60000).

%% 读接口同样显式给超时，避免默认 5s 在 DB 回读（loadSession）时被击穿。
call(Req) ->
    gen_server:call(?SERVER, Req, callTimeoutMs()).

callTimeoutMs() ->
    case application:get_env(ali, sessionCallTimeoutMs, ?DefaultCallTimeoutMs) of
        N when is_integer(N), N > 0 -> N;
        _ -> ?DefaultCallTimeoutMs
    end.

%%--------------------------------------------------------------------
%% @doc
%% 启动 alSessionMgr gen_server，并注册为本地名称 ?SERVER
%%
%% @return gen_server:start_link/4 的结果
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% @doc
%% 为指定用户创建新的会话，并持久化到 DB
%%
%% @param User 用户标识
%% @return {ok, SessionId}
%% @end
%%--------------------------------------------------------------------
createSession(User) ->
    call({eCreateSession, User}).

%%--------------------------------------------------------------------
%% @doc
%% 获取指定会话的上下文；内存未命中时尝试从 DB 加载
%%
%% @param SessionId 会话 ID
%% @return {ok, Session} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
getContext(SessionId) ->
    call({eGetContext, SessionId}).

%%--------------------------------------------------------------------
%% @doc
%% 向指定会话追加一条消息，更新 seq 与时间戳，并持久化
%%
%% @param SessionId 会话 ID
%% @param Message 消息映射
%% @return {ok, UpdatedSession} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
appendMessage(SessionId, Message) ->
    call({eAppendMessage, SessionId, Message}).

%%--------------------------------------------------------------------
%% @doc
%% 确保指定会话存在：存在则直接返回；不存在时尝试从 DB 加载，
%% 仍不存在则创建新会话
%%
%% @param SessionId 会话 ID
%% @param User 用户标识
%% @return {ok, SessionId}
%% @end
%%--------------------------------------------------------------------
ensureSession(SessionId, User) ->
    call({eEnsureSession, SessionId, User}).

%%--------------------------------------------------------------------
%% @doc
%% 清空指定会话的所有消息（内存与 DB）
%%
%% @param SessionId 会话 ID
%% @return ok
%% @end
%%--------------------------------------------------------------------
clearMessages(SessionId) ->
    call({eClearMessages, SessionId}).

%%--------------------------------------------------------------------
%% @doc
%% 将会话（meta + messages）序列化为 JSON 二进制，用于离线存储或传输。
%% 会话在内存和 DB 中均不存在时返回 {error, notFound}
%%
%% @param SessionId 会话 ID
%% @return {ok, JsonBin} 或 {error, notFound}
%% @end
%%--------------------------------------------------------------------
-spec exportSession(term()) -> {ok, binary()} | {error, term()}.
exportSession(SessionId) ->
    call({eExportSession, SessionId}).

%%--------------------------------------------------------------------
%% @doc
%% 从 exportSession/1 产生的 JSON 二进制恢复会话；
%% 会话注册到内存，消息回写到 DB 以保证后续重启后可加载
%%
%% @param JsonBin 会话 JSON 二进制
%% @return {ok, SessionId} 或 {error, badJson}
%% @end
%%--------------------------------------------------------------------
-spec importSession(binary()) -> {ok, term()} | {error, term()}.
importSession(JsonBin) when is_binary(JsonBin) ->
    call({eImportSession, JsonBin}).

%%--------------------------------------------------------------------
%% @doc
%% 写入会话级 summary（agent 最终回答 / 状态摘要 / 用户元信息），
%% 用于 exportSession 持久化时一并输出。
%%
%% @param SessionId 会话 ID
%% @param Summary   summary map
%% @return ok | {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec setSummary(term(), map()) -> ok | {error, term()}.
setSummary(SessionId, Summary) when is_map(Summary) ->
    call({eSetSummary, SessionId, Summary}).

%%--------------------------------------------------------------------
%% @doc
%% 追加一条工具 trace 记录到会话（最近 100 条，新在前），便于
%% 重放与审计。Entry 建议是含 tool/args/result/ok/step 的 map。
%%
%% @param SessionId 会话 ID
%% @param Entry    工具调用条目（map 或 router trace 二元组）
%% @return ok | {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec appendToolTrace(term(), term()) -> ok | {error, term()}.
appendToolTrace(SessionId, Entry) ->
    call({
        eAppendToolTrace,
        SessionId,
        normalizeToolTraceEntry(Entry)
    }).

%%--------------------------------------------------------------------
%% @doc
%% 批量追加多条工具 trace：一次 gen_server 调用写入整批条目，避免
%% 逐条 appendToolTrace/2 产生 N 次串行调用与 N 次 artifacts 落盘。
%% 入参按调用顺序给出（Entries 头为最早的一条），内部保持时间顺序
%% 追加（新在前，最近 100 条）。
%%
%% @param SessionId 会话 ID
%% @param Entries   工具调用条目列表（每项可为 map 或 router trace 二元组）
%% @return ok | {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec appendToolTraces(term(), [term()]) -> ok | {error, term()}.
appendToolTraces(_SessionId, []) ->
    ok;
appendToolTraces(SessionId, Entries) when is_list(Entries) ->
    Normalized = [normalizeToolTraceEntry(E) || E <- Entries],
    call({eAppendToolTraces, SessionId, Normalized}).

%% alToolRouter 的 trace 使用紧凑二元组；会话持久化层统一转成
%% JSON-safe map，避免 appendToolTrace/2 因 function_clause 杀死 agent。
normalizeToolTraceEntry(Entry) when is_map(Entry) ->
    Entry;
normalizeToolTraceEntry({step, Step}) ->
    #{type => step, step => Step};
normalizeToolTraceEntry({tool_calls, Calls}) ->
    #{type => toolCalls, calls => Calls};
normalizeToolTraceEntry({results, Results}) ->
    #{type => results, results => Results};
normalizeToolTraceEntry({suspended, TaskId}) ->
    #{type => suspended, taskId => TaskId};
normalizeToolTraceEntry({Tag, Value}) when is_atom(Tag) ->
    #{type => Tag, value => Value};
normalizeToolTraceEntry(Other) ->
    #{type => event, value => toBinary(io_lib:format("~p", [Other]))}.

%%--------------------------------------------------------------------
%% @doc
%% 把 LLM 返回的 usage 累加到会话级 tokenUsage 字段。多次调用会
%% 按 promptTokens / completionTokens / totalTokens 累加。
%%
%% @param SessionId 会话 ID
%% @param Usage     含 promptTokens / completionTokens / totalTokens 的 map
%% @return ok | {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec addTokenUsage(term(), map()) -> ok | {error, term()}.
addTokenUsage(SessionId, Usage) when is_map(Usage) ->
    call({eAddTokenUsage, SessionId, Usage}).

%%--------------------------------------------------------------------
%% @doc
%% 追加一轮 critic 评审结果到会话（最近 10 轮）。
%%
%% @param SessionId 会话 ID
%% @param Critique  含 verdict / reason / suggestions 的 map
%% @return ok | {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec appendCritique(term(), map()) -> ok | {error, term()}.
appendCritique(SessionId, Critique) when is_map(Critique) ->
    call({eAppendCritique, SessionId, Critique}).

%%--------------------------------------------------------------------
%% @doc
%% 读取完整会话（含 summary / toolTrace / tokenUsage / critiques）。
%% 与 getContext/1 不同：返回底层 map 便于 replay / checkpoint。
%%
%% @param SessionId 会话 ID
%% @return {ok, Session} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec getSessionFull(term()) -> {ok, map()} | {error, term()}.
getSessionFull(SessionId) ->
    call({eGetSessionFull, SessionId}).

%%--------------------------------------------------------------------
%% @doc
%% 将会话快照持久化到 `.ali/sessions/<id>.json` 文件
%%
%% @param SessionId 会话 ID
%% @return {ok, Path} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec saveSession(term()) -> {ok, file:filename()} | {error, term()}.
saveSession(SessionId) ->
    case exportSession(SessionId) of
        {ok, JsonBin} ->
            Path = sessionFilePath(SessionId),
            case filelib:ensure_dir(Path) of
                ok ->
                    case file:write_file(Path, JsonBin) of
                        ok -> {ok, Path};
                        {error, _} = E -> E
                    end;
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

%%--------------------------------------------------------------------
%% @doc
%% 从 `.ali/sessions/<id>.json` 文件加载会话并注册到内存
%%
%% @param SessionId 会话 ID
%% @return {ok, SessionId} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec loadSessionFile(term()) -> {ok, term()} | {error, term()}.
loadSessionFile(SessionId) ->
    Path = sessionFilePath(SessionId),
    case file:read_file(Path) of
        {ok, JsonBin} -> importSession(JsonBin);
        {error, _} = E -> E
    end.

%%--------------------------------------------------------------------
%% @doc
%% 列出磁盘上存在快照文件的所有会话 ID
%%
%% @return 会话 ID 列表
%% @end
%%--------------------------------------------------------------------
-spec listSavedSessions() -> [term()].
listSavedSessions() ->
    Dir = sessionsDir(),
    case filelib:is_dir(Dir) of
        false -> [];
        true ->
            Files = filelib:wildcard(filename:join(Dir, "*.json")),
            lists:foldl(fun(F, Acc) ->
                Base = filename:basename(F, ".json"),
                case parseSessionId(Base) of
                    {ok, Id} -> [Id | Acc];
                    error -> Acc
                end
            end, [], Files)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 返回会话快照存放目录路径（<dataDir>/sessions，默认 .ali/sessions）
%%
%% @return 目录路径
%% @end
%%--------------------------------------------------------------------
-spec sessionsDir() -> file:filename().
sessionsDir() ->
    alConfig:dataPath("sessions").

%%--------------------------------------------------------------------
%% @doc
%% 根据会话 ID 拼接快照文件路径 `<dir>/<id>.json`
%%
%% @param SessionId 会话 ID
%% @return 文件路径
%% @end
%%--------------------------------------------------------------------
sessionFilePath(SessionId) ->
    filename:join(sessionsDir(), sessionFileName(SessionId)).

%% 生成安全的会话快照文件名：整数原样；其它先转字符串再净化，仅保留
%% 安全字符（字母/数字/`._-`）并去除路径分隔符与连续点，杜绝路径穿越。
sessionFileName(SessionId) when is_integer(SessionId) ->
    integer_to_list(SessionId) ++ ".json";
sessionFileName(SessionId) ->
    sanitizeSessionBase(sessionIdToString(SessionId)) ++ ".json".

%% 将会话 ID 转为字符串表示（binary/list/atom 直取内容，其它退回 ~w）。
sessionIdToString(SessionId) when is_binary(SessionId) ->
    unicode:characters_to_list(SessionId);
sessionIdToString(SessionId) when is_atom(SessionId) ->
    atom_to_list(SessionId);
sessionIdToString(SessionId) when is_list(SessionId) ->
    case io_lib:printable_unicode_list(SessionId) of
        true -> SessionId;
        false -> lists:flatten(io_lib:format("~w", [SessionId]))
    end;
sessionIdToString(SessionId) ->
    lists:flatten(io_lib:format("~w", [SessionId])).

%% 仅保留安全字符并折叠连续的 `.`，空结果回退为 "session"，防止穿越/空名。
sanitizeSessionBase(Str) ->
    Filtered = [safeSessionChar(C) || C <- Str],
    Collapsed = collapseDots(Filtered, []),
    case string:trim(Collapsed, both, "._-") of
        "" -> "session";
        Clean -> Clean
    end.

safeSessionChar(C) when C >= $a, C =< $z -> C;
safeSessionChar(C) when C >= $A, C =< $Z -> C;
safeSessionChar(C) when C >= $0, C =< $9 -> C;
safeSessionChar($_) -> $_;
safeSessionChar($-) -> $-;
safeSessionChar($.) -> $.;
safeSessionChar(_) -> $_.

%% 将连续的点折叠为单个点，避免出现 ".." 等穿越序列。
collapseDots([], Acc) -> lists:reverse(Acc);
collapseDots([$., $. | Rest], Acc) -> collapseDots([$. | Rest], Acc);
collapseDots([C | Rest], Acc) -> collapseDots(Rest, [C | Acc]).

%%--------------------------------------------------------------------
%% @doc
%% 解析快照文件名（去掉 .json 后缀）为会话 ID；
%% 整数字符串转为整数，其他形式保留为字符串
%%
%% @param Base 文件名（不含扩展名）
%% @return {ok, Id} 或 error
%% @end
%%--------------------------------------------------------------------
parseSessionId(Base) ->
    %% SessionId is an integer in our tests; the file name is "<int>.json".
    try list_to_integer(Base) of
        N -> {ok, N}
    catch _:_ ->
        %% Fall back to the raw string for non-integer ids.
        {ok, Base}
    end.

%%--------------------------------------------------------------------
%% @doc
%% gen_server 初始化：创建空会话映射
%%
%% @param [] 启动参数
%% @return {ok, #{sessions => #{}}}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    {ok, #{sessions => #{}}}.

%%--------------------------------------------------------------------
%% @doc
%% gen_server handle_call：处理 createSession、getContext、appendMessage、
%% ensureSession、clearMessages、exportSession、importSession 等请求
%% @end
%%--------------------------------------------------------------------
handle_call({eCreateSession, User}, _From, State = #{sessions := Sessions}) ->
    SessionId = erlang:unique_integer([positive]),
    Now = erlang:system_time(second),
    Session = #{id => SessionId, user => User, createdAt => Now, updatedAt => Now, messages => [], seq => 0},
    _ = persistSession(SessionId, User, Now),
    {reply, {ok, SessionId}, State#{sessions => Sessions#{SessionId => Session}}};
handle_call({eGetContext, SessionId}, _From, State = #{sessions := Sessions}) ->
    case maps:find(SessionId, Sessions) of
        {ok, Session} ->
            {reply, {ok, Session}, State};
        error ->
            case loadSession(SessionId) of
                {ok, Session} ->
                    {reply, {ok, Session}, State#{sessions => Sessions#{SessionId => Session}}};
                {error, _} = Err ->
                    {reply, Err, State}
            end
    end;
handle_call({eAppendMessage, SessionId, Message}, _From, State = #{sessions := Sessions}) ->
    case resolveSession(SessionId, Sessions) of
        {ok, Session = #{seq := Seq, messages := Messages}} ->
            NextSeq = Seq + 1,
            Now = erlang:system_time(second),
            _ = persistMessage(SessionId, Message, NextSeq),
            _ = touchSession(SessionId, Now),
            NewMessages = trimMessages(Messages ++ [Message]),
            Updated = Session#{messages => NewMessages, seq => NextSeq, updatedAt => Now},
            {reply, {ok, Updated}, State#{sessions => Sessions#{SessionId => Updated}}};
        {error, _} = Err ->
            {reply, Err, State}
    end;
handle_call({eEnsureSession, SessionId, User}, _From, State = #{sessions := Sessions}) ->
    case maps:is_key(SessionId, Sessions) of
        true ->
            {reply, {ok, SessionId}, State};
        false ->
            case loadSession(SessionId) of
                {ok, Session} ->
                    {reply, {ok, SessionId}, State#{sessions => Sessions#{SessionId => Session}}};
                {error, _} ->
                    Now = erlang:system_time(second),
                    Session = #{
                        id => SessionId,
                        user => User,
                        createdAt => Now,
                        updatedAt => Now,
                        messages => [],
                        seq => 0
                    },
                    _ = persistSession(SessionId, User, Now),
                    {reply, {ok, SessionId}, State#{sessions => Sessions#{SessionId => Session}}}
            end
    end;
handle_call({eClearMessages, SessionId}, _From, State = #{sessions := Sessions}) ->
    Now = erlang:system_time(second),
    _ = clearSessionMessagesDb(SessionId),
    %% clear 同步清除派生 artifacts（summary/toolTrace/tokenUsage/critiques），
    %% 否则清空消息后旧摘要/工具轨迹仍残留在内存与 DB，导致状态不一致。
    _ = clearSessionArtifactsDb(SessionId),
    case maps:find(SessionId, Sessions) of
        {ok, Session} ->
            Cleared = Session#{
                messages => [], seq => 0, updatedAt => Now,
                summary => #{}, toolTrace => [], tokenUsage => #{}, critiques => []
            },
            {reply, ok, State#{sessions => Sessions#{SessionId => Cleared}}};
        error ->
            {reply, ok, State}
    end;
handle_call({eExportSession, SessionId}, _From, State = #{sessions := Sessions}) ->
    case resolveSession(SessionId, Sessions) of
        {ok, Session} ->
            Payload = #{
                id => SessionId,
                user => maps:get(user, Session, undefined),
                createdAt => maps:get(createdAt, Session, 0),
                updatedAt => maps:get(updatedAt, Session, 0),
                summary => maps:get(summary, Session, #{}),
                toolTrace => maps:get(toolTrace, Session, []),
                tokenUsage => maps:get(tokenUsage, Session, #{}),
                critiques => maps:get(critiques, Session, []),
                messages => [encodeMessage(M) || M <- maps:get(messages, Session, [])]
            },
            {reply, {ok, alJson:encode(Payload)}, State};
        {error, _} = Err ->
            {reply, Err, State}
    end;
handle_call({eImportSession, JsonBin}, _From, State = #{sessions := Sessions}) ->
    case decodeSessionJson(JsonBin) of
        {ok, #{<<"id">> := SessionId} = Decoded} ->
            RawMsgs = maps:get(<<"messages">>, Decoded, []),
            MessagesFlat = case is_list(RawMsgs) of
                true -> [decodeMessage(M) || M <- RawMsgs];
                false -> []
            end,
            Now = erlang:system_time(second),
            Meta = #{
                id => SessionId,
                user => maps:get(<<"user">>, Decoded, undefined),
                createdAt => maps:get(<<"createdAt">>, Decoded, 0),
                updatedAt => Now,
                summary => decodeMap(maps:get(<<"summary">>, Decoded, #{})),
                toolTrace => decodeList(maps:get(<<"toolTrace">>, Decoded, [])),
                tokenUsage => decodeMap(maps:get(<<"tokenUsage">>, Decoded, #{})),
                critiques => decodeList(maps:get(<<"critiques">>, Decoded, [])),
                messages => MessagesFlat,
                seq => length(MessagesFlat)
            },
            %% 导入前先清空该会话已有的 DB 消息，避免与重新持久化的消息
            %% 叠加导致重复行（同一 SessionId 重复导入 / 覆盖旧会话时）。
            _ = clearSessionMessagesDb(SessionId),
            %% Re-persist messages so DB-backed loads survive a restart.
            lists:foreach(fun({Seq, M}) ->
                _ = persistMessage(SessionId, M, Seq)
            end, lists:enumerate(MessagesFlat)),
            %% 同步持久化派生 artifacts，使重启后 loadSession 能回读。
            persistArtifacts(SessionId, Meta),
            {reply, {ok, SessionId}, State#{sessions => Sessions#{SessionId => Meta}}};
        {ok, _} ->
            %% Decoded but missing required id field.
            {reply, {error, badJson}, State};
        {error, _} ->
            {reply, {error, badJson}, State}
    end;
handle_call({eSetSummary, SessionId, Summary}, _From, State = #{sessions := Sessions}) ->
    case resolveSession(SessionId, Sessions) of
        {ok, Session} ->
            Updated = Session#{summary => Summary, updatedAt => erlang:system_time(second)},
            persistArtifacts(SessionId, Updated),
            {reply, ok, State#{sessions => Sessions#{SessionId => Updated}}};
        {error, _} = Err ->
            {reply, Err, State}
    end;
handle_call({eAppendToolTrace, SessionId, Entry}, _From, State = #{sessions := Sessions}) ->
    case resolveSession(SessionId, Sessions) of
        {ok, Session} ->
            Trace = maps:get(toolTrace, Session, []),
            NewTrace = [Entry | lists:sublist(Trace, 99)],
            Updated = Session#{toolTrace => NewTrace, updatedAt => erlang:system_time(second)},
            persistArtifacts(SessionId, Updated),
            {reply, ok, State#{sessions => Sessions#{SessionId => Updated}}};
        {error, _} = Err ->
            {reply, Err, State}
    end;
handle_call({eAppendToolTraces, SessionId, Entries}, _From, State = #{sessions := Sessions}) ->
    case resolveSession(SessionId, Sessions) of
        {ok, Session} ->
            Trace = maps:get(toolTrace, Session, []),
            %% Entries 按时间正序（旧->新）给出；反转后逐条压栈，使
            %% 最终列表与逐条 appendToolTrace 语义一致（新在前）。
            NewTrace0 = lists:foldl(fun(E, Acc) -> [E | Acc] end, Trace, Entries),
            NewTrace = lists:sublist(NewTrace0, 100),
            Updated = Session#{toolTrace => NewTrace, updatedAt => erlang:system_time(second)},
            persistArtifacts(SessionId, Updated),
            {reply, ok, State#{sessions => Sessions#{SessionId => Updated}}};
        {error, _} = Err ->
            {reply, Err, State}
    end;
handle_call({eAddTokenUsage, SessionId, Usage}, _From, State = #{sessions := Sessions}) ->
    case resolveSession(SessionId, Sessions) of
        {ok, Session} ->
            Cur = maps:get(tokenUsage, Session, #{}),
            Merged = mergeTokenUsage(Cur, Usage),
            Updated = Session#{tokenUsage => Merged, updatedAt => erlang:system_time(second)},
            persistArtifacts(SessionId, Updated),
            {reply, ok, State#{sessions => Sessions#{SessionId => Updated}}};
        {error, _} = Err ->
            {reply, Err, State}
    end;
handle_call({eAppendCritique, SessionId, Critique}, _From, State = #{sessions := Sessions}) ->
    case resolveSession(SessionId, Sessions) of
        {ok, Session} ->
            Cur = maps:get(critiques, Session, []),
            New = [Critique | lists:sublist(Cur, 9)],
            Updated = Session#{critiques => New, updatedAt => erlang:system_time(second)},
            persistArtifacts(SessionId, Updated),
            {reply, ok, State#{sessions => Sessions#{SessionId => Updated}}};
        {error, _} = Err ->
            {reply, Err, State}
    end;
handle_call({eGetSessionFull, SessionId}, _From, State = #{sessions := Sessions}) ->
    case resolveSession(SessionId, Sessions) of
        {ok, Session} ->
            {reply, {ok, Session}, State};
        {error, _} = Err ->
            {reply, Err, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, badRequest}, State}.

%% gen_server handle_cast：忽略所有 cast 消息
handle_cast(_Msg, State) ->
    {noreply, State}.

%% gen_server handle_info：忽略所有 info 消息
handle_info(_Info, State) ->
    {noreply, State}.

%% gen_server terminate：无需特殊清理
terminate(_Reason, _State) ->
    ok.

%% gen_server code_change：直接保留原状态
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% @doc
%% 限制内存中消息列表长度，超过上限时丢弃最旧的消息，保留尾部最新消息，
%% 避免 O(n²) 追加退化。消息列表按时间正序（旧在前、新在后），因此裁剪
%% 时应保留末尾 ?MaxInMemoryMessages 条。
%%
%% @param Messages 正向消息列表（旧 -> 新）
%% @return 裁剪后的正向消息列表（保留最新的若干条）
%% @end
%%--------------------------------------------------------------------
-define(MaxInMemoryMessages, 2000).

trimMessages(Messages) ->
    Len = length(Messages),
    case Len > ?MaxInMemoryMessages of
        true ->
            lists:nthtail(Len - ?MaxInMemoryMessages, Messages);
        false ->
            Messages
    end.

%%--------------------------------------------------------------------
%% @doc
%% 解析会话：内存命中直接返回，否则尝试从 DB 加载
%%
%% @param SessionId 会话 ID
%% @param Sessions 当前内存会话映射
%% @return {ok, Session} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
resolveSession(SessionId, Sessions) ->
    case maps:find(SessionId, Sessions) of
        {ok, Session} ->
            {ok, Session};
        error ->
            loadSession(SessionId)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 解码会话 JSON 二进制；jiffy 在输入非法时会抛异常，包裹 try 防止服务器崩溃
%%
%% @param JsonBin JSON 二进制
%% @return {ok, Map} | {ok, Other} | {error, badJson}
%% @end
%%--------------------------------------------------------------------
%% Decode a session JSON blob, returning {ok, Map} | {ok, Other} | {error, _}.
%% jiffy throws on malformed input, so wrap the call to keep the server alive.
decodeSessionJson(JsonBin) ->
    try alJson:decode(JsonBin) of
        Map when is_map(Map) -> {ok, Map};
        Other -> {ok, Other}
    catch
        _:_ -> {error, badJson}
    end.

%%%===================================================================
%%% DB helpers — best effort: failures are logged but never crash the server.
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 向 DB sessions 表插入一条会话元数据记录（best effort）
%%
%% @param SessionId 会话 ID
%% @param User 用户标识
%% @param Now 创建时间戳
%% @return ok
%% @end
%%--------------------------------------------------------------------
persistSession(SessionId, User, Now) ->
    %% INSERT OR IGNORE：已存在则只 touch，避免重复主键把 best-effort 写库静默失败
    _ = safeExecute(
        "INSERT OR IGNORE INTO sessions (id, user, created_at, updated_at) VALUES (?, ?, ?, ?)",
        [SessionId, toBinary(User), Now, Now]),
    safeExecute(
        "UPDATE sessions SET updated_at = ?, user = ? WHERE id = ?",
        [Now, toBinary(User), SessionId]).

%%--------------------------------------------------------------------
%% @doc
%% 向 DB session_messages 表插入一条消息记录（best effort）
%%
%% @param SessionId 会话 ID
%% @param Message 消息映射
%% @param Seq 消息序号
%% @return ok
%% @end
%%--------------------------------------------------------------------
persistMessage(SessionId, Message, Seq) ->
    %% 确保 sessions 行存在，否则仅有 messages 时「会话」表仍为 0，Web 数据页会误以为没会话
    Now = erlang:system_time(second),
    _ = persistSession(SessionId, web, Now),
    Sql = "INSERT INTO session_messages (session_id, seq, message, created_at) VALUES (?, ?, ?, ?)",
    safeExecute(Sql, [SessionId, Seq, alJson:encode(encodeMessage(Message)), Now]).

%% Persist summary/toolTrace/critiques/tokenUsage into session_artifacts.
persistArtifacts(SessionId, Session) when is_map(Session) ->
    Now = erlang:system_time(second),
    _ = persistSession(SessionId, maps:get(user, Session, web), Now),
    Sql = "INSERT OR REPLACE INTO session_artifacts "
          "(session_id, summary, tool_trace, critiques, token_usage, plan, updated_at) "
          "VALUES (?, ?, ?, ?, ?, ?, ?)",
    Params = [
        SessionId,
        alJson:encode(maps:get(summary, Session, #{})),
        alJson:encode(maps:get(toolTrace, Session, [])),
        alJson:encode(maps:get(critiques, Session, [])),
        alJson:encode(maps:get(tokenUsage, Session, #{})),
        alJson:encode(maps:get(plan, Session, #{})),
        Now
    ],
    safeExecute(Sql, Params);
persistArtifacts(_, _) ->
    ok.

%%--------------------------------------------------------------------
%% @doc
%% 更新 DB sessions 表中指定会话的 updatedAt 时间戳（best effort）
%%
%% @param SessionId 会话 ID
%% @param Now 当前时间戳
%% @return ok
%% @end
%%--------------------------------------------------------------------
touchSession(SessionId, Now) ->
    Sql = "UPDATE sessions SET updated_at = ? WHERE id = ?",
    safeExecute(Sql, [Now, SessionId]).

%%--------------------------------------------------------------------
%% @doc
%% 删除 DB 中指定会话的所有消息（best effort，失败不抛异常）
%%
%% @param SessionId 会话 ID
%% @return ok
%% @end
%%--------------------------------------------------------------------
clearSessionMessagesDb(SessionId) ->
    Sql = "DELETE FROM session_messages WHERE session_id = ?",
    try alLocalDb:execute(Sql, [SessionId]) of
        {ok, _} -> ok;
        {error, Reason} ->
            logDbMiss("session clear messages failed", Reason, Sql),
            ok
    catch
        C:R ->
            logDbMiss("session clear messages crashed", {C, R}, Sql),
            ok
    end.

%%--------------------------------------------------------------------
%% @doc
%% 删除 DB 中指定会话的派生 artifacts 行（best effort，失败不抛异常）
%%
%% @param SessionId 会话 ID
%% @return ok
%% @end
%%--------------------------------------------------------------------
clearSessionArtifactsDb(SessionId) ->
    Sql = "DELETE FROM session_artifacts WHERE session_id = ?",
    try alLocalDb:execute(Sql, [SessionId]) of
        {ok, _} -> ok;
        {error, Reason} ->
            logDbMiss("session clear artifacts failed", Reason, Sql),
            ok
    catch
        C:R ->
            logDbMiss("session clear artifacts crashed", {C, R}, Sql),
            ok
    end.

%%--------------------------------------------------------------------
%% @doc
%% 从 DB 加载指定会话：先读取所有消息（按 seq 排序），再加载元数据；
%% 元数据加载失败时使用默认值
%%
%% @param SessionId 会话 ID
%% @return {ok, Session} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
loadSession(SessionId) ->
    Sql = "SELECT message FROM session_messages WHERE session_id = ? ORDER BY seq",
    try alLocalDb:query(Sql, [SessionId]) of
        {ok, Rows} ->
            Messages = [decodeMessage(maps:get(message, Row, <<>>)) || Row <- Rows],
            Artifacts = loadArtifacts(SessionId),
            Base = case loadSessionMeta(SessionId) of
                {ok, Meta} ->
                    Meta;
                {error, _} ->
                    #{id => SessionId, user => undefined, createdAt => 0, updatedAt => 0}
            end,
            %% 回读 artifacts（summary/toolTrace/tokenUsage/critiques），
            %% 使从 DB 恢复的会话不丢失派生状态。
            {ok, maps:merge(Base, Artifacts#{messages => Messages, seq => length(Messages)})};
        {error, _} = Err ->
            Err
    catch
        %% DB 层崩溃（未启动/noproc 等）不连带会话进程崩溃，降级为错误。
        _:_ -> {error, dbUnavailable}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 从 session_artifacts 表回读派生状态；不可用或不存在时返回空 map。
%%
%% @param SessionId 会话 ID
%% @return #{summary => _, toolTrace => _, tokenUsage => _, critiques => _}
%% @end
%%--------------------------------------------------------------------
loadArtifacts(SessionId) ->
    Sql = "SELECT summary, tool_trace, critiques, token_usage FROM session_artifacts WHERE session_id = ?",
    try alLocalDb:query(Sql, [SessionId]) of
        {ok, [Row | _]} ->
            #{
                summary => decodeArtifactMap(maps:get(summary, Row, <<>>)),
                toolTrace => decodeArtifactList(maps:get(tool_trace, Row, <<>>)),
                critiques => decodeArtifactList(maps:get(critiques, Row, <<>>)),
                tokenUsage => decodeArtifactMap(maps:get(token_usage, Row, <<>>))
            };
        _ ->
            #{}
    catch
        _:_ -> #{}
    end.

%% 解码 artifacts 中的 JSON map 字段（binary 键转 atom 键）；失败返回空 map。
decodeArtifactMap(Bin) when is_binary(Bin), Bin =/= <<>> ->
    try decodeMap(alJson:decode(Bin)) catch _:_ -> #{} end;
decodeArtifactMap(M) when is_map(M) -> decodeMap(M);
decodeArtifactMap(_) -> #{}.

%% 解码 artifacts 中的 JSON list 字段；失败返回空 list。
decodeArtifactList(Bin) when is_binary(Bin), Bin =/= <<>> ->
    try decodeList(alJson:decode(Bin)) catch _:_ -> [] end;
decodeArtifactList(L) when is_list(L) -> L;
decodeArtifactList(_) -> [].

%%--------------------------------------------------------------------
%% @doc
%% 从 DB sessions 表加载会话元数据（user、createdAt、updatedAt）
%%
%% @param SessionId 会话 ID
%% @return {ok, Meta}、{error, notFound} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
loadSessionMeta(SessionId) ->
    Sql = "SELECT user, created_at, updated_at FROM sessions WHERE id = ?",
    try alLocalDb:query(Sql, [SessionId]) of
        {ok, [Row | _]} ->
            {ok, #{id => SessionId,
                   user => maps:get(user, Row, undefined),
                   createdAt => maps:get(created_at, Row, 0),
                   updatedAt => maps:get(updated_at, Row, 0)}};
        {ok, []} ->
            {error, notFound};
        {error, _} = Err ->
            Err
    catch
        %% DB 层崩溃时降级为错误，避免连带会话进程崩溃（与 loadArtifacts 一致）。
        _:_ -> {error, dbUnavailable}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 安全执行 INSERT/UPDATE：捕获异常和错误，失败时仅记录日志
%%
%% @param Sql SQL 语句
%% @param Params 参数列表
%% @return ok
%% @end
%%--------------------------------------------------------------------
%% INSERT/UPDATE/DELETE 统一走 execute；原先 UPDATE 误走 insert 会静默失败。
safeExecute(Sql, Params) ->
    try alLocalDb:execute(Sql, Params) of
        {ok, _} ->
            ok;
        {error, Reason} ->
            logDbMiss("session persist failed", Reason, Sql),
            ok
    catch
        C:R ->
            logDbMiss("session persist crashed", {C, R}, Sql),
            ok
    end.

%%--------------------------------------------------------------------
%% @doc
%% 记录 DB 操作失败：DB 不可用时降级为 debug 日志，
%% 其他失败记录为 warning 日志
%%
%% @param Label 日志标签
%% @param Reason 失败原因
%% @param Sql SQL 语句
%% @end
%%--------------------------------------------------------------------
%% DB is optional: in-memory sessions work when alLocalDb is down.
%% noproc is expected degrade, not a warning.
logDbMiss(Label, Reason, Sql) ->
    case isDbUnavailable(Reason) of
        true ->
            logger:debug("~s (db unavailable): ~p", [Label, Sql]);
        false ->
            logger:warning("~s: ~p sql=~p", [Label, Reason, Sql])
    end.

%%--------------------------------------------------------------------
%% @doc
%% 判断失败原因是否表示 DB 不可用（noproc 等多种形式）
%%
%% @param Reason 失败原因
%% @return boolean()
%% @end
%%--------------------------------------------------------------------
isDbUnavailable({error, noproc}) -> true;
isDbUnavailable({noproc, _}) -> true;
isDbUnavailable({exit, {noproc, _}}) -> true;
isDbUnavailable({exit, noproc}) -> true;
isDbUnavailable(noproc) -> true;
isDbUnavailable(_) -> false.

%%--------------------------------------------------------------------
%% @doc
%% 将消息编码为 JSON 兼容形式：递归将原子键和原子值转换为二进制
%%
%% @param Message 消息映射或其他值
%% @return 编码后的值
%% @end
%%--------------------------------------------------------------------
encodeMessage(Message) when is_map(Message) ->
    maps:from_list([{encodeKey(K), encodeValue(V)} || {K, V} <- maps:to_list(Message)]);
encodeMessage(Value) ->
    Value.

%% 将键编码为 JSON 兼容形式：原子转二进制，其他原样返回
encodeKey(K) when is_atom(K) ->
    atom_to_binary(K, utf8);
encodeKey(K) ->
    K.

%%--------------------------------------------------------------------
%% @doc
%% 将值编码为 JSON 兼容形式：
%% - 原子转二进制
%% - 字符列表转二进制，其他列表递归编码
%% - map 递归调用 encodeMessage
%% - 其他原样返回
%%
%% @param V 输入值
%% @return 编码后的值
%% @end
%%--------------------------------------------------------------------
encodeValue(V) when is_atom(V) ->
    atom_to_binary(V, utf8);
encodeValue(V) when is_list(V) ->
    case io_lib:char_list(V) of
        true -> unicode:characters_to_binary(V);
        false -> [encodeValue(Item) || Item <- V]
    end;
encodeValue(V) when is_map(V) ->
    encodeMessage(V);
encodeValue(V) ->
    V.

%%--------------------------------------------------------------------
%% @doc
%% 将二进制解码为消息 map；解码失败或非 map 时包装为
%% #{role => unknown, content => Bin/Other}
%%
%% @param Bin 二进制或其他值
%% @return 消息 map
%% @end
%%--------------------------------------------------------------------
decodeMessage(Bin) when is_binary(Bin) ->
    try alJson:decode(Bin) of
        Map when is_map(Map) ->
            normalizeMessage(Map);
        _ ->
            #{role => unknown, content => Bin}
    catch
        _:_ ->
            #{role => unknown, content => Bin}
    end;
decodeMessage(Other) ->
    #{role => unknown, content => Other}.

%%--------------------------------------------------------------------
%% @doc
%% 递归归一化消息：将 map 的二进制键转换为已存在原子，
%% 列表逐项归一化，其他值原样返回
%%
%% @param Map|Value 输入值
%% @return 归一化后的值
%% @end
%%--------------------------------------------------------------------
normalizeMessage(Map) when is_map(Map) ->
    Norm = maps:from_list([{normalizeKey(K), normalizeValue(V)} || {K, V} <- maps:to_list(Map)]),
    case maps:get(role, Norm, undefined) of
        undefined -> Norm;
        Role -> Norm#{role => normalizeRoleValue(Role)}
    end;
normalizeMessage(Value) ->
    Value.

normalizeRoleValue(system) -> system;
normalizeRoleValue(<<"system">>) -> system;
normalizeRoleValue(user) -> user;
normalizeRoleValue(<<"user">>) -> user;
normalizeRoleValue(assistant) -> assistant;
normalizeRoleValue(<<"assistant">>) -> assistant;
normalizeRoleValue(tool) -> tool;
normalizeRoleValue(<<"tool">>) -> tool;
normalizeRoleValue(Other) -> Other.

%% 将二进制键转换为已存在的原子；不存在时保留二进制
normalizeKey(K) when is_binary(K) ->
    try binary_to_existing_atom(K, utf8) catch _:_ -> K end;
normalizeKey(K) ->
    K.

%%--------------------------------------------------------------------
%% @doc
%% 递归归一化值：map 调用 normalizeMessage，列表逐项归一化，其他原样返回
%%
%% @param V 输入值
%% @return 归一化后的值
%% @end
%%--------------------------------------------------------------------
normalizeValue(V) when is_map(V) ->
    normalizeMessage(V);
normalizeValue(V) when is_list(V) ->
    [normalizeValue(Item) || Item <- V];
normalizeValue(V) ->
    V.

%%--------------------------------------------------------------------
%% @doc
%% 将值转换为二进制：二进制原样、原子转 UTF-8、列表转码、其他用 ~p 格式化
%%
%% @param V 输入值
%% @return 二进制
%% @end
%%--------------------------------------------------------------------
toBinary(V) when is_binary(V) ->
    V;
toBinary(V) when is_atom(V) ->
    atom_to_binary(V, utf8);
toBinary(V) when is_list(V) ->
    unicode:characters_to_binary(V);
toBinary(V) ->
    unicode:characters_to_binary(io_lib:format("~p", [V])).

%%--------------------------------------------------------------------
%% @doc
%% 合并两次 tokenUsage 记录：把数值字段累加，其余字段用新值覆盖。
%%
%% @param A 已有 usage（可能为 undefined）
%% @param B 新增 usage
%% @return 合并后的 usage map
%% @end
%%--------------------------------------------------------------------
mergeTokenUsage(undefined, B) when is_map(B) -> B;
mergeTokenUsage(A, B) when is_map(A), is_map(B) ->
    maps:fold(fun(K, V, Acc) ->
        Existing = maps:get(K, Acc, 0),
        case is_number(V) andalso is_number(Existing) of
            true -> Acc#{K => Existing + V};
            false -> Acc#{K => V}
        end
    end, A, B);
mergeTokenUsage(A, _) -> A.

%%--------------------------------------------------------------------
%% @doc
%% 把 JSON 解析出的 map（binary keys）转换为 atom keys，便于
%% Erlang 侧处理。值非 atom 的 key 保持 binary。
%%
%% @param M map | undefined
%% @return map
%% @end
%%--------------------------------------------------------------------
decodeMap(undefined) -> #{};
decodeMap(M) when is_map(M) ->
    maps:from_list([{decodeKey(K), V} || {K, V} <- maps:to_list(M)]);
decodeMap(_) -> #{}.

decodeKey(K) when is_binary(K) ->
    try binary_to_existing_atom(K, utf8) catch _:_ -> K end;
decodeKey(K) -> K.

decodeList(undefined) -> [];
decodeList(L) when is_list(L) -> L;
decodeList(_) -> [].
