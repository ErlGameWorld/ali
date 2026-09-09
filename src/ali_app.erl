%%%-------------------------------------------------------------------
%% @doc ali 应用入口（OTP application 回调）。
%% @end
%%%-------------------------------------------------------------------

-module(ali_app).

-behaviour(application).

-export([start/2, stop/1]).

%%--------------------------------------------------------------------
%% @doc
%% 应用启动入口：加载配置后启动 application。
%% 配置查找顺序：application env `cfg` → 环境变量 `ALI_CFG` →
%% `./config/aliCfg.cfg` → `./aliCfg.cfg`。
%%
%% @param _StartType 启动类型（normal | takeover | failover，未使用）
%% @param _StartArgs 启动参数（未使用）
%% @return {ok, Pid} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
start(_StartType, _StartArgs) ->
    case alConfig:load() of
        ok ->
            startApp();
        {error, Reason} ->
            logger:error("alConfig load failed: ~p", [Reason]),
            {error, Reason}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 启动顶层 supervisor 并完成必要的初始化（核心客户端、数据库、后台索引）。
%%
%% @return {ok, Pid} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
startApp() ->
    %% EUnit 等场景可能先手工 start_link 了 alLocalDb，再启应用会 already_started。
    _ = alLocalDb:stopIfOrphan(),
    case ali_sup:start_link() of
        {ok, _Pid} = Ok ->
            _ = alCoreClient:ensureAvailable(),
            _ = alHttp:ensureStarted(),
            _ = alDbAdapter:ensureStarted(),
            _ = maybeCleanupBackups(),
            _ = maybeIndexBackground(),
            _ = alProjectDigest:maybeBuildOnStartup(),
            Ok;
        Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% @doc
%% 启动时清理过期备份：先按默认 TTL（30 天）删除过期备份，再按
%% 每文件 50 份封顶，避免长期运行导致磁盘膨胀。失败不阻塞启动。
%%
%% @return ok
%% @end
%%--------------------------------------------------------------------
maybeCleanupBackups() ->
    try
        {ok, Expired} = alBackup:cleanupExpired(),
        ok = alBackup:cleanup(),
        case Expired of
            0 -> ok;
            _ -> logger:info("[ali_app] cleaned up ~p expired backup dirs", [Expired])
        end
    catch
        Class:Reason ->
            logger:warning("[ali_app] backup cleanup failed: ~p:~p", [Class, Reason]),
            ok
    end.

%%--------------------------------------------------------------------
%% @doc
%% 根据配置决定是否在后台为全部 codeRoots 建立代码索引。
%% 通过 alCoreClient 走异步索引；core 不可用时跳过并告警。
%%
%% @return ok
%% @end
%%--------------------------------------------------------------------
maybeIndexBackground() ->
    Core = alConfig:get(core, #{}),
    case maps:get(indexBackground, Core, false) of
        true ->
            Roots = alConfig:codeRoots(),
            case alCoreClient:available() of
                true ->
                    logger:info("aliCore background index for ~p", [Roots]),
                    _ = alCoreClient:indexAsyncRoots(Roots),
                    ok;
                false ->
                    logger:warning("aliCore unavailable, skip background index. "
                                   "Ensure aliCore.exe is built and core.enabled=true."),
                    ok
            end;
        false ->
            ok
    end.

%%--------------------------------------------------------------------
%% @doc
%% 应用停止回调：当前无需清理资源，直接返回 ok。
%% （子进程 terminate 会关闭 aliCore / qdrant port。）
%%
%% @param _State 应用停止时的状态（未使用）
%% @return ok
%% @end
%%--------------------------------------------------------------------
stop(_State) ->
    ok.
