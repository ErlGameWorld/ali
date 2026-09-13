%%%-------------------------------------------------------------------
%% @doc 待审批工具调用：原子状态机 + 持久化。
%%
%% 状态：pending -> approved | dismissed | expired
%% 归属：命名 gen_server 串行化转移；ETS 为热缓存。
%% 持久化：.ali/pending/<taskId>.json，带 TTL 清理。
%% @end
%%%-------------------------------------------------------------------

-module(alPending).

-behaviour(gen_server).

-compile({no_auto_import, [get/1]}).

-export([
    start_link/0,
    put/5,
    get/1,
    list/0,
    list/1,
    approve/1,
    claimApprove/1,
    executeApproved/1,
    dismiss/1,
    attachContinuation/2,
    ensureStarted/0,
    purgeExpired/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% Test helpers reused by alPending_tests / alWebHandler diffs.
-export([buildDiff/2, toBinary/1, persist/1, deletePersisted/1]).

-ifdef(TEST).
-export([callTimeoutMs/0]).
-endif.

-define(SERVER, ?MODULE).
-define(TABLE, alPending).
-define(DEFAULT_TTL_MS, 3600000).
-define(CLEAN_INTERVAL_MS, 60000).
-define(DEFAULT_CALL_TIMEOUT_MS, 30000).

-record(state, {timer :: reference() | undefined}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

ensureStarted() ->
    case whereis(?SERVER) of
        undefined ->
            case start_link() of
                {ok, _} -> ok;
                {error, {already_started, _}} -> ok;
                {error, _} ->
                    %% Fallback ETS-only for tests that never start the app tree.
                    ensureTable(),
                    ok
            end;
        _ ->
            ok
    end.

put(TaskId, SessionId, Tool, Args, Opts) ->
    ensureStarted(),
    call({put, TaskId, SessionId, Tool, Args, Opts}).

get(TaskId) ->
    ensureStarted(),
    call({get, TaskId}).

list() ->
    ensureStarted(),
    call(list).

list(SessionId) ->
    case list() of
        Entries when is_list(Entries) ->
            [E || E <- Entries, maps:get(sessionId, E, undefined) =:= SessionId];
        {error, _} = Error ->
            Error
    end.

%% Claim + execute outside the gen_server so resume/put cannot deadlock.
approve(TaskId) ->
    case claimApprove(TaskId) of
        {ok, Spec} -> executeApproved(Spec);
        {error, _} = E -> E
    end.

%% Atomic claim only — caller must run executeApproved/1 outside the server.
claimApprove(TaskId) ->
    ensureStarted(),
    call({claimApprove, TaskId}).

%% Run the approved tool / resume continuation (never inside gen_server).
executeApproved(#{tool := Tool, args := Args, opts := Opts} = Spec) ->
    Started = erlang:monotonic_time(millisecond),
    Result = case maps:get(continuation, Spec, undefined) of
        undefined ->
            alToolRouter:callTool(Tool, Args, Opts);
        Continuation ->
            ToolContent = executeApprovedTool(Tool, Args, Opts),
            alAgent:resumeAfterApproval(Continuation, ToolContent, Opts)
    end,
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    case isOk(Result) of
        true ->
            deleteCheckpoint(maps:get(taskId, Spec, undefined));
        false ->
            ok
    end,
    alAudit:log(#{
        session => maps:get(sessionId, Spec, undefined),
        tool => Tool,
        ok => isOk(Result),
        ms => Elapsed,
        args => Args,
        result => Result,
        approved => true
    }),
    Result;
executeApproved(_) ->
    {error, badSpec}.

dismiss(TaskId) ->
    ensureStarted(),
    call({dismiss, TaskId}).

attachContinuation(TaskId, Continuation) when is_map(Continuation) ->
    ensureStarted(),
    call({attachContinuation, TaskId, Continuation}).

purgeExpired() ->
    ensureStarted(),
    call(purgeExpired).

call(Req) ->
    case whereis(?SERVER) of
        undefined ->
            %% Tests / degraded: operate on ETS directly with take semantics.
            directCall(Req);
        _ ->
            try gen_server:call(?SERVER, Req, callTimeoutMs()) of
                Reply -> Reply
            catch
                exit:{timeout, _} ->
                    logger:warning("alPending call timed out: ~p", [requestTag(Req)]),
                    {error, pendingCallTimeout};
                exit:Reason ->
                    logger:warning("alPending call exited: ~p reason=~p",
                                   [requestTag(Req), Reason]),
                    {error, {pendingCallExit, Reason}}
            end
    end.

requestTag({Tag, _, _, _, _, _}) -> Tag;
requestTag({Tag, _, _}) -> Tag;
requestTag({Tag, _}) -> Tag;
requestTag(Tag) when is_atom(Tag) -> Tag;
requestTag(_) -> unknown.

callTimeoutMs() ->
    case application:get_env(ali, pendingCallTimeoutMs,
                             ?DEFAULT_CALL_TIMEOUT_MS) of
        N when is_integer(N), N > 0 -> N;
        _ -> ?DEFAULT_CALL_TIMEOUT_MS
    end.

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    ensureTable(),
    loadFromDisk(),
    Timer = erlang:send_after(?CLEAN_INTERVAL_MS, self(), purgeExpired),
    {ok, #state{timer = Timer}}.

handle_call({put, TaskId, SessionId, Tool, Args, Opts}, _From, State) ->
    {reply, doPut(TaskId, SessionId, Tool, Args, Opts), State};
handle_call({get, TaskId}, _From, State) ->
    {reply, doGet(TaskId), State};
handle_call(list, _From, State) ->
    {reply, doList(), State};
handle_call({claimApprove, TaskId}, _From, State) ->
    {reply, doClaimApprove(TaskId), State};
handle_call({approve, TaskId}, _From, State) ->
    %% Legacy path: claim only; executeApproved runs after call returns.
    {reply, doClaimApprove(TaskId), State};
handle_call({dismiss, TaskId}, _From, State) ->
    {reply, doDismiss(TaskId), State};
handle_call({attachContinuation, TaskId, Continuation}, _From, State) ->
    {reply, doAttach(TaskId, Continuation), State};
handle_call(purgeExpired, _From, State) ->
    {reply, doPurge(), State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknownRequest}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(purgeExpired, State) ->
    _ = doPurge(),
    Timer = erlang:send_after(?CLEAN_INTERVAL_MS, self(), purgeExpired),
    {noreply, State#state{timer = Timer}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{timer = Timer}) ->
    cancelTimer(Timer),
    ok.

code_change(_Old, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Core transitions
%%%===================================================================

doPut(TaskId, SessionId, Tool, Args, Opts) ->
    Now = erlang:system_time(millisecond),
    Ttl = maps:get(pendingTtlMs, Opts, ?DEFAULT_TTL_MS),
    BaseEntry = #{
        id => toBinary(TaskId),
        sessionId => SessionId,
        tool => Tool,
        args => Args,
        opts => Opts,
        status => pending,
        createdAt => Now,
        expiresAt => Now + Ttl
    },
    Entry = case buildDiff(Tool, Args) of
        "" -> BaseEntry;
        Diff -> BaseEntry#{diff => Diff}
    end,
    ets:insert(?TABLE, {toBinary(TaskId), Entry}),
    persist(Entry),
    {ok, Entry}.

doGet(TaskId) ->
    case ets:lookup(?TABLE, toBinary(TaskId)) of
        [{_, #{status := pending, expiresAt := Exp} = Entry}] ->
            case erlang:system_time(millisecond) > Exp of
                true ->
                    _ = doExpire(TaskId),
                    {error, expired};
                false ->
                    {ok, Entry}
            end;
        [{_, #{status := Status}}] when Status =/= pending ->
            {error, {badStatus, Status}};
        [] ->
            {error, notFound}
    end.

doList() ->
    Now = erlang:system_time(millisecond),
    [E || {_, #{status := pending, expiresAt := Exp} = E} <- ets:tab2list(?TABLE),
          Exp >= Now].

doAttach(TaskId, Continuation) ->
    BinId = toBinary(TaskId),
    case ets:lookup(?TABLE, BinId) of
        [{_, #{status := pending} = Entry}] ->
            New = Entry#{continuation => Continuation},
            ets:insert(?TABLE, {BinId, New}),
            persist(New),
            ok;
        [{_, _}] ->
            {error, badStatus};
        [] ->
            {error, notFound}
    end.

%% Atomic claim via ets:take — only one approve/dismiss wins.
%% Does NOT execute tools or resume; caller runs executeApproved/1 outside.
doClaimApprove(TaskId) ->
    BinId = toBinary(TaskId),
    case ets:take(?TABLE, BinId) of
        [{_, #{status := pending, tool := Tool, args := Args, opts := Opts} = Entry}] ->
            deletePersisted(BinId),
            %% checkpoint 保留到 executeApproved 成功后再删，失败仍可 resume。
            ConfirmedOpts = maps:merge(Opts, #{confirmed => true}),
            {ok, #{
                tool => Tool,
                args => Args,
                opts => ConfirmedOpts,
                continuation => maps:get(continuation, Entry, undefined),
                sessionId => maps:get(sessionId, Entry, undefined),
                taskId => BinId
            }};
        [{_, #{status := Status}}] ->
            {error, {badStatus, Status}};
        [] ->
            {error, notFound}
    end.

doDismiss(TaskId) ->
    BinId = toBinary(TaskId),
    case ets:take(?TABLE, BinId) of
        [{_, Entry}] ->
            deletePersisted(BinId),
            deleteCheckpoint(BinId),
            alAudit:log(#{
                session => maps:get(sessionId, Entry, undefined),
                tool => maps:get(tool, Entry, unknown),
                ok => false,
                dismissed => true
            }),
            ok;
        [] ->
            {error, notFound}
    end.

doExpire(TaskId) ->
    BinId = toBinary(TaskId),
    case ets:take(?TABLE, BinId) of
        [{_, Entry}] ->
            deletePersisted(BinId),
            deleteCheckpoint(BinId),
            alAudit:log(#{
                session => maps:get(sessionId, Entry, undefined),
                tool => maps:get(tool, Entry, unknown),
                ok => false,
                expired => true
            }),
            ok;
        [] ->
            ok
    end.

doPurge() ->
    Now = erlang:system_time(millisecond),
    Expired = [Id || {Id, #{status := pending, expiresAt := Exp}} <- ets:tab2list(?TABLE),
                     Exp < Now],
    lists:foreach(fun(Id) -> doExpire(Id) end, Expired),
    {ok, length(Expired)}.

%%%===================================================================
%%% Persistence
%%%===================================================================

pendingDir() ->
    filename:join(alConfig:dataDir(), "pending").

persist(#{id := Id} = Entry) ->
    Dir = pendingDir(),
    Seg = sanitizePendingId(Id),
    case filelib:ensure_dir(filename:join(Dir, "dummy")) of
        ok ->
            Path = filename:join(Dir, Seg ++ ".json"),
            %% Keep a trimmed opts map (needed for resume); strip live pids/funs.
            SafeOpts = maps:with(
                [mode, confirmed, sessionId, taskId, progressId, pendingTtlMs, persistMemory],
                maps:get(opts, Entry, #{})),
            Safe0 = Entry#{opts => SafeOpts},
            Safe1 = case maps:get(continuation, Safe0, undefined) of
                undefined -> Safe0;
                Cont when is_map(Cont) ->
                    Safe0#{continuation => sanitizeContinuation(Cont)};
                _ -> maps:remove(continuation, Safe0)
            end,
            Safe2 = maps:map(fun(_K, V) -> sanitizePersistValue(V) end, Safe1),
            %% 落盘前深度脱敏：对整个条目按敏感键递归打码，避免 args / continuation
            %% 中夹带的凭据（apiKey/token/password 等）落到 .ali/pending 明文文件。
            Safe = alPolicy:sanitizeTerm(Safe2),
            %% 落盘失败时内存条目已保留，但返回 error 让调用方感知持久化降级。
            case file:write_file(Path, alJson:encode(Safe)) of
                ok -> ok;
                {error, Reason} ->
                    logger:error("[alPending] persist write failed for ~p: ~p", [Id, Reason]),
                    {error, Reason}
            end;
        {error, Reason} ->
            logger:error("[alPending] ensure_dir failed for ~p: ~p", [Id, Reason]),
            {error, ensureDirFailed}
    end.

sanitizeContinuation(Cont) ->
    maps:map(fun
        (opts, Opts) when is_map(Opts) ->
            maps:with([mode, confirmed, sessionId, taskId, progressId, persistMemory], Opts);
        (_K, V) -> sanitizePersistValue(V)
    end, Cont).

sanitizePersistValue(V) when is_pid(V); is_reference(V); is_function(V) ->
    null;
sanitizePersistValue(V) when is_map(V) ->
    maps:map(fun(_K, X) -> sanitizePersistValue(X) end, V);
sanitizePersistValue(V) when is_list(V) ->
    case io_lib:char_list(V) of
        true -> V;
        false -> [sanitizePersistValue(I) || I <- V]
    end;
sanitizePersistValue(V) ->
    V.

deletePersisted(Id) ->
    Seg = sanitizePendingId(Id),
    Path = filename:join(pendingDir(), Seg ++ ".json"),
    _ = file:delete(Path),
    ok.

%% 净化 pending 文件名段：仅保留字母/数字/下划线/连字符/点，折叠连续的点，
%% 去除首尾的 . _ -，防止 Id 路径穿越（..、/、\）；净化后为空回退 "pending"。
sanitizePendingId(Id) when is_binary(Id) ->
    sanitizePendingId(binary_to_list(Id));
sanitizePendingId(Id) when is_list(Id) ->
    Filtered = [safePendingChar(C) || C <- Id],
    Collapsed = collapsePendingDots(Filtered, []),
    case string:trim(Collapsed, both, "._-") of
        "" -> "pending";
        Clean -> Clean
    end;
sanitizePendingId(Id) ->
    sanitizePendingId(toBinary(Id)).

safePendingChar(C) when C >= $a, C =< $z -> C;
safePendingChar(C) when C >= $A, C =< $Z -> C;
safePendingChar(C) when C >= $0, C =< $9 -> C;
safePendingChar($_) -> $_;
safePendingChar($-) -> $-;
safePendingChar($.) -> $.;
safePendingChar(_) -> $_.

%% 将连续的点折叠为单个点，避免出现 ".." 等穿越序列。
collapsePendingDots([], Acc) -> lists:reverse(Acc);
collapsePendingDots([$., $. | Rest], Acc) -> collapsePendingDots([$. | Rest], Acc);
collapsePendingDots([C | Rest], Acc) -> collapsePendingDots(Rest, [C | Acc]).

%% 任务结束（受理/驳回/过期）时同步删除同名 checkpoint，保持
%% ".ali/checkpoints = 未完成任务" 语义。失败静默（文件可能不存在）。
deleteCheckpoint(Id) ->
    try alCheckpoint:delete(toBinary(Id)) catch _:_ -> ok end.

loadFromDisk() ->
    Dir = pendingDir(),
    Now = erlang:system_time(millisecond),
    case file:list_dir(Dir) of
        {ok, Files} ->
            lists:foreach(fun(F) ->
                case filename:extension(F) of
                    ".json" ->
                        Path = filename:join(Dir, F),
                        loadOneFromDisk(Path, Now);
                    _ -> ok
                end
            end, Files);
        _ -> ok
    end.

%% 加载单个 pending 文件；TTL 已过期的条目直接删除文件、不载入 ETS。
loadOneFromDisk(Path, Now) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            try alJson:decode(Bin) of
                Map when is_map(Map) ->
                    Entry = normalizeLoaded(Map),
                    Id = maps:get(id, Entry, undefined),
                    Exp = maps:get(expiresAt, Entry, 0),
                    case Id of
                        undefined -> ok;
                        _ when is_integer(Exp), Exp < Now ->
                            %% 过期文件 TTL 清理：删除磁盘残留。
                            _ = file:delete(Path),
                            ok;
                        _ ->
                            ets:insert(?TABLE, {toBinary(Id), Entry})
                    end;
                _ -> ok
            catch _:_ -> ok
            end;
        _ -> ok
    end.

normalizeLoaded(Map) ->
    Folded = maps:fold(fun(K, V, Acc) ->
        Key = case K of
            B when is_binary(B) ->
                try binary_to_existing_atom(B, utf8) catch _:_ -> B end;
            A -> A
        end,
        Acc#{Key => normalizeLoadedValue(Key, V)}
    end, #{}, Map),
    maps:merge(#{status => pending}, Folded).

normalizeLoadedValue(status, V) -> normalizeStatus(V);
normalizeLoadedValue(continuation, V) when is_map(V) ->
    normalizeContinuationMap(V);
normalizeLoadedValue(opts, V) when is_map(V) ->
    maps:fold(fun(K, Val, Acc) ->
        Key = case K of
            B when is_binary(B) ->
                try binary_to_existing_atom(B, utf8) catch _:_ -> B end;
            A -> A
        end,
        Acc#{Key => Val}
    end, #{}, V);
normalizeLoadedValue(_Key, V) ->
    V.

normalizeStatus(pending) -> pending;
normalizeStatus(<<"pending">>) -> pending;
normalizeStatus(approved) -> approved;
normalizeStatus(<<"approved">>) -> approved;
normalizeStatus(dismissed) -> dismissed;
normalizeStatus(<<"dismissed">>) -> dismissed;
normalizeStatus(expired) -> expired;
normalizeStatus(<<"expired">>) -> expired;
normalizeStatus(Other) -> Other.

normalizeContinuationMap(Map) ->
    maps:fold(fun(K, V, Acc) ->
        Key = case K of
            B when is_binary(B) ->
                try binary_to_existing_atom(B, utf8) catch _:_ -> B end;
            A -> A
        end,
        Acc#{Key => case Key of
            messages when is_list(V) -> [normalizeLoadedMessage(M) || M <- V];
            opts when is_map(V) -> normalizeLoadedValue(opts, V);
            _ -> V
        end}
    end, #{}, Map).

normalizeLoadedMessage(M) when is_map(M) ->
    alSessionMgr:normalizeMessage(M);
normalizeLoadedMessage(M) ->
    M.

%%%===================================================================
%%% Diff helpers (public for tests)
%%%===================================================================

buildDiff(applyPatch, Args) ->
    buildPatchDiff(Args);
buildDiff(applyPatchBatch, Args) ->
    Patches = maps:get(patches, Args, []),
    Parts = [begin
        File = maps:get(file, Patch, <<"(unknown)">>),
        Header = iolist_to_binary([<<"--- a/">>, toBin(File), $\n,
                                   <<"+++ b/">>, toBin(File), $\n]),
        Diff = buildPatchDiff(Patch),
        case Diff of
            "" -> Header;
            _ -> <<Header/binary, Diff/binary>>
        end
     end || Patch <- Patches, is_map(Patch)],
    iolist_to_binary(Parts);
buildDiff(writeFile, Args) ->
    Path = maps:get(path, Args, undefined),
    New = maps:get(content, Args, undefined),
    if
        is_list(Path) orelse is_binary(Path),
        is_binary(New) orelse is_list(New) ->
            buildWriteDiff(Path, New);
        true ->
            ""
    end;
buildDiff(runMfa, Args) ->
    buildRunMfaDiff(Args);
buildDiff(_, _) ->
    "".

buildRunMfaDiff(Args) when is_map(Args) ->
    Mod = maps:get(module, Args, maps:get(<<"module">>, Args, <<>>)),
    Fun = maps:get(function, Args, maps:get(<<"function">>, Args, <<>>)),
    Call = maps:get(call, Args, maps:get(<<"call">>, Args, undefined)),
    ArgsList = maps:get(args, Args, maps:get(<<"args">>, Args, [])),
    Side = maps:get(sideEffect, Args, maps:get(<<"sideEffect">>, Args, write)),
    Verify = maps:get(verifyRead, Args, maps:get(<<"verifyRead">>, Args, undefined)),
    Target = case Call of
        undefined ->
            iolist_to_binary([toBin(Mod), <<":">>, toBin(Fun),
                              <<"/">>, integer_to_binary(length(ensureList(ArgsList)))]);
        C -> toBin(C)
    end,
    ArgPreview = try alJson:encodeSafe(ArgsList) catch _:_ -> <<"[]">> end,
    VerifyBin = try alJson:encodeSafe(Verify) catch _:_ -> <<"null">> end,
    iolist_to_binary([
        <<"### runMfa (live node write)\n">>,
        <<"sideEffect: ">>, toBin(Side), <<"\n">>,
        <<"target: ">>, Target, <<"\n">>,
        <<"args: ">>, ArgPreview, <<"\n">>,
        <<"verifyRead: ">>, VerifyBin, <<"\n">>,
        <<"Flow: before-snapshot (verifyRead) → approve → write → after-snapshot.\n"/utf8>>
    ]);
buildRunMfaDiff(_) ->
    "".

ensureList(L) when is_list(L) -> L;
ensureList(_) -> [].

buildPatchDiff(Args) ->
    case alPatchManager:normalizePatch(Args) of
        {ok, #{file := File, old := Old, new := New}} ->
            case file:read_file(File) of
                {ok, Original} ->
                    OldBin = toBin(Old),
                    NewBin = toBin(New),
                    case alPatchManager:occurrenceCount(Original, OldBin) of
                        1 -> renderUnifiedDiff(File, Original, OldBin, NewBin);
                        _ -> ""
                    end;
                {error, _} ->
                    ""
            end;
        _ ->
            ""
    end.

buildWriteDiff(Path, New) ->
    NewBin = toBin(New),
    OldBin = case file:read_file(Path) of
        {ok, B} -> B;
        {error, _} -> <<>>
    end,
    renderUnifiedDiff(Path, OldBin, <<>>, NewBin).

renderUnifiedDiff(File, _Original, Old, New) ->
    OldLines = case Old of
        <<>> -> [];
        _ -> binary:split(Old, <<"\n">>, [global, trim_all])
    end,
    NewLines = binary:split(New, <<"\n">>, [global, trim_all]),
    Header = iolist_to_binary([<<"--- a/">>, toBin(File), $\n,
                               <<"+++ b/">>, toBin(File), $\n]),
    Body = renderLineDiff(OldLines, NewLines),
    iolist_to_binary([Header, Body]).

renderLineDiff([], NewLines) ->
    iolist_to_binary([<<"+ ", L/binary, $\n>> || L <- NewLines]);
renderLineDiff(OldLines, NewLines) ->
    Del = [<<"- ", L/binary, $\n>> || L <- OldLines],
    Add = [<<"+ ", L/binary, $\n>> || L <- NewLines],
    iolist_to_binary([
        <<"@@ -1,", (integer_to_binary(length(OldLines)))/binary, " +1,",
                    (integer_to_binary(length(NewLines)))/binary, " @@\n">>,
        Del, Add
    ]).

executeApprovedTool(Tool, Args, Opts) ->
    case alToolRouter:callTool(Tool, Args, Opts) of
        {ok, Value} -> #{status => ok, result => Value};
        {error, Reason} -> #{status => error, reason => Reason}
    end.

isOk({ok, _}) -> true;
isOk(_) -> false.

toBinary(X) when is_binary(X) -> X;
toBinary(X) when is_list(X) -> unicode:characters_to_binary(X);
toBinary(X) when is_integer(X) -> integer_to_binary(X);
toBinary(X) when is_atom(X) -> atom_to_binary(X, utf8).

toBin(X) -> toBinary(X).

ensureTable() ->
    case ets:whereis(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, public, set, {read_concurrency, true}]),
            ok;
        _ ->
            ok
    end.

cancelTimer(undefined) -> ok;
cancelTimer(Ref) -> erlang:cancel_timer(Ref, [{async, true}, {info, false}]).

%% Degraded path when gen_server is not running (unit tests).
directCall({put, TaskId, SessionId, Tool, Args, Opts}) ->
    ensureTable(),
    doPut(TaskId, SessionId, Tool, Args, Opts);
directCall({get, TaskId}) ->
    ensureTable(),
    doGet(TaskId);
directCall(list) ->
    ensureTable(),
    doList();
directCall({claimApprove, TaskId}) ->
    ensureTable(),
    doClaimApprove(TaskId);
directCall({approve, TaskId}) ->
    ensureTable(),
    doClaimApprove(TaskId);
directCall({dismiss, TaskId}) ->
    ensureTable(),
    doDismiss(TaskId);
directCall({attachContinuation, TaskId, Continuation}) ->
    ensureTable(),
    doAttach(TaskId, Continuation);
directCall(purgeExpired) ->
    ensureTable(),
    doPurge().
