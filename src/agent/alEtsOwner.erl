%%%-------------------------------------------------------------------
%% @doc 公共 ETS 表的专职属主进程（supervisor 监管）。
%%
%% 背景：`alPlan' / `alTokenStats' / `alPatchManager' 等模块历史上采用
%% 「首次调用者建表」模式（lazy `ensureStarted'）。调用方通常是短命的
%% agent worker——一旦该 worker 退出，它持有的 ETS 表随之销毁，导致
%% 计划、token 统计、补丁事务（回滚依赖）等状态静默丢失。
%%
%% 本模块作为一个长生命周期的 gen_server，在 init 阶段统一预建全部
%% 公共命名表。因为这些 `ets:new/2' 由本进程调用，表的 owner 即为
%% 本进程；只要本进程存活，表就不会因短命 worker 退出而消失。若本
%% 进程崩溃，supervisor 会重启它并重新建表（数据清空但功能恢复）。
%%
%% 复用各模块自身的 `ensureStarted/0'（幂等）来建表，从而共享其原有
%% 的表选项与初始化逻辑（例如 alMetrics 的计数器初值）；短命 worker
%% 后续调用 `ensureStarted/0' 时会发现表已存在而直接返回。
%% @end
%%%-------------------------------------------------------------------

-module(alEtsOwner).

-behaviour(gen_server).

-export([start_link/0, ensureAll/0, tables/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

%%--------------------------------------------------------------------
%% @doc
%% 启动属主进程并注册为本地名 ?SERVER。
%%
%% @return {ok, Pid} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% @doc
%% 幂等地确保所有公共 ETS 表已建立。由本进程调用时表由本进程持有。
%%
%% @return ok
%% @end
%%--------------------------------------------------------------------
-spec ensureAll() -> ok.
ensureAll() ->
    _ = alPlan:ensureStarted(),
    _ = alTokenStats:ensureStarted(),
    _ = alPatchManager:ensureStarted(),
    _ = alAudit:ensureStarted(),
    _ = alMetrics:ensureStarted(),
    _ = alProgress:ensureStarted(),
    _ = alTask:ensureStarted(),
    %% 工具结果缓存表：并行 tool worker 高频读写，必须由长生命周期进程持有，
    %% 否则首个建表的 worker 退出即销毁全表（缓存击穿 + badarg 竞态）。
    _ = alToolCache:ensureStarted(),
    %% 查询/摘要/Git 缓存表：必须由长生命周期进程持有，避免 whereis 误用 + 短命建表
    _ = ensureNamedCache(alQueryRewriteCache),
    _ = ensureNamedCache(alQueryDecomposeCache),
    _ = ensureNamedCache(alModuleSummaryCache),
    _ = ensureNamedCache(alGitRecentCache),
    ok.

ensureNamedCache(Table) ->
    case ets:whereis(Table) of
        undefined ->
            try
                ets:new(Table, [named_table, set, public,
                                {read_concurrency, true},
                                {write_concurrency, true}]),
                ok
            catch
                _:_ -> ok
            end;
        _ ->
            ok
    end.

%%--------------------------------------------------------------------
%% @doc
%% 返回本进程所纳管的公共表名列表（供诊断/测试使用）。
%%
%% @return [atom()]
%% @end
%%--------------------------------------------------------------------
-spec tables() -> [atom()].
tables() ->
    [alPlan, alTokenStats, ali_patch_transactions, alAudit,
     alMetrics, ali_tool_metrics, ali_metrics_latency, alProgress, alTasks,
     alToolCache,
     alQueryRewriteCache, alQueryDecomposeCache, alModuleSummaryCache, alGitRecentCache].

%%--------------------------------------------------------------------
%% @doc
%% gen_server 初始化：预建全部公共 ETS 表，使其 owner 为本长生命周期进程。
%%
%% @end
%%--------------------------------------------------------------------
init([]) ->
    ok = ensureAll(),
    {ok, #{}}.

%% 兜底处理未知 call。
handle_call(_Req, _From, State) ->
    {reply, {error, badRequest}, State}.

%% 兜底处理未知 cast。
handle_cast(_Msg, State) ->
    {noreply, State}.

%% 兜底处理未知 info。
handle_info(_Info, State) ->
    {noreply, State}.

%% 终止回调：表随进程消亡由 supervisor 重启后重建，无需额外清理。
terminate(_Reason, _State) ->
    ok.

%% 热代码升级回调，保留状态。
code_change(_Old, State, _Extra) ->
    {ok, State}.
