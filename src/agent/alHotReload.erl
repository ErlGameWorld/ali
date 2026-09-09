%%%-------------------------------------------------------------------
%%% @doc 安全热加载：soft_purge → load_file → export diff → 可选 smoke。
%%%
%%% 专为 agent 工具 {@code hotReload} 提供护栏，避免 skill 靠多轮裸
%%% {@code runMfa} 调 {@code code:purge}/{@code code:load_file}：
%%% <ul>
%%% <li>默认仅 {@link code:soft_purge/1}；旧代码仍被进程占用时拒绝，
%%%     除非显式 {@code force=true}（才会 {@link code:purge/1}）。</li>
%%% <li>加载后对比 exports，提示增减 / 回调签名风险。</li>
%%% <li>默认 smoke：{@code Module:module_info(module)}；可选 arity-0 导出。</li>
%%% </ul>
%%% 本模块直接调 `code` BIF，不经 {@code runMfa}，不受 MFA 黑名单影响。
%%% @end
%%%-------------------------------------------------------------------

-module(alHotReload).

-export([reload/1]).
%% 测试导出
-export([exportDiff/2, ensureModule/1, parseSmoke/1]).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 热加载模块。Args：
%%   - module（必填）
%%   - force（可选，默认 false）：soft_purge 失败时是否硬 purge
%%   - smoke（可选）：`"fun/0"` 或 `<<"fun/0">>`，仅允许本模块 arity 0 导出；
%%     缺省跑 `module_info(module)`
%% @end
%%--------------------------------------------------------------------
-spec reload(map()) -> {ok, map()} | {error, map()}.
reload(Args) when is_map(Args) ->
    case ensureModule(maps:get(module, Args, undefined)) of
        {ok, Mod} ->
            doReload(Mod, Args);
        {error, Reason} ->
            {error, #{reason => Reason, module => maps:get(module, Args, undefined)}}
    end;
reload(_) ->
    {error, #{reason => invalidArgs}}.

%%%===================================================================
%%% Internal
%%%===================================================================

doReload(Mod, Args) ->
    Force = truthy(maps:get(force, Args, false)),
    OldExports = safeExports(Mod),
    OldWhich = code:which(Mod),
    OldMd5 = safeMd5(Mod),
    case softPurge(Mod, Force) of
        {ok, PurgeInfo} ->
            case code:load_file(Mod) of
                {module, Mod} ->
                    NewExports = safeExports(Mod),
                    Diff = exportDiff(OldExports, NewExports),
                    Smoke = runSmoke(Mod, maps:get(smoke, Args, undefined)),
                    {ok, #{
                        module => Mod,
                        loaded => true,
                        beam => formatWhich(code:which(Mod)),
                        previousBeam => formatWhich(OldWhich),
                        softPurge => PurgeInfo,
                        force => Force,
                        oldMd5 => formatMd5(OldMd5),
                        newMd5 => formatMd5(safeMd5(Mod)),
                        exportDiff => Diff,
                        smoke => Smoke,
                        warnings => warningsFor(Diff, Mod)
                    }};
                {error, LoadReason} ->
                    {error, #{
                        reason => loadFailed,
                        detail => LoadReason,
                        module => Mod,
                        softPurge => PurgeInfo,
                        hint => <<"load_file failed — check ebin path / compile first "
                                  "(verifyCompile), then retry hotReload."/utf8>>
                    }}
            end;
        {error, _} = Err ->
            Err
    end.

softPurge(Mod, Force) ->
    case code:soft_purge(Mod) of
        true ->
            {ok, #{method => soft_purge, ok => true}};
        false when Force ->
            _ = code:purge(Mod),
            {ok, #{method => purge, ok => true, forced => true,
                   warning => <<"Hard purge used; processes holding old code may have been killed.">>}};
        false ->
            {error, #{
                reason => softPurgeDenied,
                module => Mod,
                hint => <<"Old code still referenced by live processes. "
                          "Drain callers / upgrade carefully, or pass force=true "
                          "(hard purge — may kill processes)."/utf8>>
            }}
    end.

runSmoke(Mod, undefined) ->
    try
        V = Mod:module_info(module),
        #{ok => true, call => {Mod, module_info, 1}, result => V}
    catch C:R ->
        #{ok => false, call => {Mod, module_info, 1}, error => {C, R}}
    end;
runSmoke(Mod, Smoke) ->
    case parseSmoke(Smoke) of
        {ok, Fun, 0} ->
            case lists:member({Fun, 0}, safeExports(Mod)) of
                true ->
                    try
                        V = Mod:Fun(),
                        #{ok => true, call => {Mod, Fun, 0},
                          result => truncateTerm(V)}
                    catch C:R ->
                        #{ok => false, call => {Mod, Fun, 0}, error => {C, R}}
                    end;
                false ->
                    #{ok => false, reason => smokeNotExported,
                      call => {Mod, Fun, 0},
                      hint => <<"smoke MFA must be an exported arity-0 function">>}
            end;
        {error, Why} ->
            #{ok => false, reason => Why,
              hint => <<"smoke must look like fun/0 (arity 0 only)">>}
    end.

%%--------------------------------------------------------------------
%% @doc exports 差分：added / removed（{Fun,Arity} 列表）。
%% @end
%%--------------------------------------------------------------------
exportDiff(Old, New) when is_list(Old), is_list(New) ->
    OldS = lists:usort(Old),
    NewS = lists:usort(New),
    #{
        added => NewS -- OldS,
        removed => OldS -- NewS,
        unchangedCount => length([X || X <- NewS, lists:member(X, OldS)])
    }.

warningsFor(#{added := Added, removed := Removed}, Mod) ->
    Cb = [CB || CB <- Removed ++ Added, isCallbackExport(CB)],
    Base = case Removed of
        [] -> [];
        _ -> [<<"Exports removed — callers may crash if still using old MFA."/utf8>>]
    end,
    Base2 = case Cb of
        [] -> Base;
        _ ->
            [<<"OTP callback exports changed (handle_call/cast/info/init). "
               "Running processes may be incompatible; supervisor restart may be required.">>
             | Base]
    end,
    case code:is_sticky(Mod) of
        true -> [<<"Module is sticky (OTP/system); reload may be restricted.">> | Base2];
        false -> Base2
    end.

isCallbackExport({init, 1}) -> true;
isCallbackExport({handle_call, 3}) -> true;
isCallbackExport({handle_cast, 2}) -> true;
isCallbackExport({handle_info, 2}) -> true;
isCallbackExport({terminate, 2}) -> true;
isCallbackExport({code_change, 3}) -> true;
isCallbackExport(_) -> false.

safeExports(Mod) ->
    try
        [{F, A} || {F, A} <- Mod:module_info(exports), F =/= module_info]
    catch
        _:_ -> []
    end.

safeMd5(Mod) ->
    try Mod:module_info(md5) catch _:_ -> undefined end.

formatMd5(undefined) -> undefined;
formatMd5(Bin) when is_binary(Bin) ->
    iolist_to_binary([io_lib:format("~2.16.0b", [B]) || <<B>> <= Bin]);
formatMd5(Other) -> Other.

formatWhich(non_existing) -> non_existing;
formatWhich(preloaded) -> preloaded;
formatWhich(Path) when is_list(Path) -> unicode:characters_to_binary(Path);
formatWhich(Other) -> Other.

%% smoke: "foo/0" | <<"foo/0">> | #{function => foo, arity => 0}
parseSmoke(#{function := F, arity := 0}) ->
    parseSmokeFun(F, 0);
parseSmoke(#{<<"function">> := F, <<"arity">> := 0}) ->
    parseSmokeFun(F, 0);
parseSmoke(Bin) when is_binary(Bin) ->
    parseSmoke(unicode:characters_to_list(Bin));
parseSmoke(Str) when is_list(Str) ->
    case string:split(string:trim(Str), "/") of
        [FunStr, "0"] ->
            case toFunAtom(FunStr) of
                {ok, Fun} -> {ok, Fun, 0};
                error -> {error, invalidSmoke}
            end;
        _ ->
            {error, smokeArityMustBe0}
    end;
parseSmoke(_) ->
    {error, invalidSmoke}.

parseSmokeFun(F, 0) when is_atom(F) -> {ok, F, 0};
parseSmokeFun(F, 0) ->
    case toFunAtom(F) of
        {ok, Fun} -> {ok, Fun, 0};
        error -> {error, invalidSmoke}
    end;
parseSmokeFun(_, _) -> {error, smokeArityMustBe0}.

toFunAtom(A) when is_atom(A) -> {ok, A};
toFunAtom(B) when is_binary(B) ->
    try binary_to_existing_atom(B, utf8) of
        A -> {ok, A}
    catch
        _:_ -> error
    end;
toFunAtom(L) when is_list(L) ->
    try list_to_existing_atom(L) of
        A -> {ok, A}
    catch
        _:_ -> error
    end;
toFunAtom(_) -> error.

ensureModule(undefined) -> {error, missingModule};
ensureModule(M) when is_atom(M) -> {ok, M};
ensureModule(M) when is_binary(M) ->
    try binary_to_existing_atom(M, utf8) of
        A -> {ok, A}
    catch
        _:_ -> {error, unknownModule}
    end;
ensureModule(M) when is_list(M) ->
    try list_to_existing_atom(M) of
        A -> {ok, A}
    catch
        _:_ -> {error, unknownModule}
    end;
ensureModule(M) -> {error, {invalidModule, M}}.

truthy(true) -> true;
truthy(<<"true">>) -> true;
truthy("true") -> true;
truthy(1) -> true;
truthy(_) -> false.

truncateTerm(V) ->
    Bin = unicode:characters_to_binary(io_lib:format("~p", [V])),
    case byte_size(Bin) > 500 of
        true -> <<(binary:part(Bin, 0, 500))/binary, "...">>;
        false -> Bin
    end.
