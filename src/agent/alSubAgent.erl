%%%-------------------------------------------------------------------
%% @doc 内置专科子 agent。
%%
%% 每个 agentDef = #{name, role, tools, mode, model?, maxSteps?}。
%% 复用 {@link alAgent}:run/2，并自定义系统提示与工具白名单。
%% 子 agent 上下文隔离：结果返回给调用方，不写入父会话。
%%
%% runAgents/2 对只读（ask 模式）agent 用 spawn_monitor + 60s 超时并行。
%% @end
%%%-------------------------------------------------------------------

-module(alSubAgent).

-export([
    list/0,
    lookup/1,
    run/2,
    run/3,
    runAgents/1,
    runAgents/2
]).
%% Test exports — pure helpers
-export([checkReadOnly/1]).

-define(SubSessionPrefix, <<"subagent::">>).
-define(DefaultTimeoutMs, 60000).

-type agentDef() :: #{
    name := atom(),
    role := binary(),
    tools := [atom()],
    mode := ask | edit | exec,
    model => binary() | undefined,
    maxSteps => non_neg_integer()
}.

-type runOpts() :: #{
    parentSession => binary(),
    progressId => binary(),
    model => binary(),
    maxSteps => non_neg_integer()
}.

-export_type([agentDef/0, runOpts/0]).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 列出所有内置子 Agent 的名称与角色描述。
%%
%% @return [{Name, Role}] 列表
%% @end
%%--------------------------------------------------------------------
-spec list() -> [{atom(), binary()}].
list() ->
    [{Name, maps:get(role, Def)} || {Name, Def} <- builtin()].

%%--------------------------------------------------------------------
%% @doc
%% 按名称查找内置子 Agent 定义。
%%
%% @param Name 子 Agent 名称原子
%% @return {ok, agentDef()} | {error, notFound}
%% @end
%%--------------------------------------------------------------------
-spec lookup(atom()) -> {ok, agentDef()} | {error, notFound}.
lookup(Name) ->
    case lists:keyfind(Name, 1, builtin()) of
        {Name, Def} -> {ok, Def};
        false -> {error, notFound}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 运行指定子 Agent 处理任务（使用空选项）。
%%
%% @param Name 子 Agent 名称
%% @param Task 任务描述
%% @return {ok, Summary, Meta} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec run(atom(), binary()) -> {ok, binary(), map()} | {error, term()}.
run(Name, Task) ->
    run(Name, Task, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 运行指定子 Agent 处理任务，可携带 model / maxSteps / parentSession 等选项。
%% 查找失败立即返回 {error, notFound}。
%%
%% @param Name 子 Agent 名称
%% @param Task 任务描述
%% @param Opts 运行选项
%% @return {ok, Summary, Meta} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec run(atom(), binary(), runOpts()) -> {ok, binary(), map()} | {error, term()}.
run(Name, Task, Opts) ->
    case lookup(Name) of
        {ok, Def} -> doRun(Def, Task, Opts);
        {error, _} = E -> E
    end.

%%--------------------------------------------------------------------
%% @doc
%% 并行运行多个子 Agent（使用空选项）。仅允许 ask 模式的只读 Agent。
%%
%% @param Tasks [{Name, Task}] 任务列表
%% @return {ok, [{Name, Result}]} | {error, {notReadOnly, Name}}
%% @end
%%--------------------------------------------------------------------
-spec runAgents([{atom(), binary()}]) ->
    {ok, [{atom(), {ok, binary()} | {error, term()}}]} | {error, {notReadOnly, atom()}}.
runAgents(Tasks) ->
    runAgents(Tasks, #{}).

%%--------------------------------------------------------------------
%% @doc
%% 并行运行多个子 Agent。先校验全部为 ask 模式只读 Agent，再并行调度，
%% 任意一个非只读则返回 {error, {notReadOnly, Name}}。
%%
%% @param Tasks [{Name, Task}] 任务列表
%% @param Opts 运行选项
%% @return {ok, [{Name, Result}]} | {error, {notReadOnly, Name}}
%% @end
%%--------------------------------------------------------------------
-spec runAgents([{atom(), binary()}], runOpts()) ->
    {ok, [{atom(), {ok, binary()} | {error, term()}}]} | {error, {notReadOnly, atom()}}.
runAgents(Tasks, Opts) ->
    case checkReadOnly(Tasks) of
        ok -> runAgentsParallel(Tasks, Opts);
        {error, _} = E -> E
    end.

%%%===================================================================
%%% Internal: parallel execution
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 校验所有任务对应的子 Agent 均为 ask 模式只读 Agent。
%% 返回 ok 或第一个非只读的 Agent 名称。
%%
%% @end
%%--------------------------------------------------------------------
checkReadOnly(Tasks) ->
    Bad = [Name || {Name, _} <- Tasks,
                   case lookup(Name) of
                       {ok, #{mode := M}} -> M =/= ask;
                       _ -> true
                   end],
    case Bad of
        [] -> ok;
        [N | _] -> {error, {notReadOnly, N}}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 并行执行：为每个任务 spawn_monitor 一个进程，主进程按完成顺序收集结果。
%% 单一 deadline（Now + ?DefaultTimeoutMs）：循环 receive {Ref, Result} after Remain，
%% 每收到一个就记录并从待办集合移除，直到全部收到或 deadline 到达。
%% 因此总最坏耗时 ≈ ?DefaultTimeoutMs（max），而非 N × timeout。
%% 崩溃（DOWN）与超时均归为对应错误，超时时 kill 仍存活子进程并清邮箱。
%% 最终按输入顺序返回结果列表。
%%
%% @end
%%--------------------------------------------------------------------
runAgentsParallel(Tasks, Opts) ->
    Parent = self(),
    Pairs = [begin
                 Ref = make_ref(),
                 {Pid, MonRef} = spawn_monitor(fun() -> runOne(Name, Task, Parent, Ref, Opts) end),
                 {Ref, MonRef, Pid, Name}
             end || {Name, Task} <- Tasks],
    Pending = maps:from_list([{Ref, Name} || {Ref, _, _, Name} <- Pairs]),
    MonByRef = maps:from_list([{Ref, MonRef} || {Ref, MonRef, _, _} <- Pairs]),
    PidByRef = maps:from_list([{Ref, Pid} || {Ref, _, Pid, _} <- Pairs]),
    RefByMon = maps:from_list([{MonRef, Ref} || {Ref, MonRef, _, _} <- Pairs]),
    Deadline = erlang:monotonic_time(millisecond) + ?DefaultTimeoutMs,
    Results = collectParallel(Pending, MonByRef, PidByRef, RefByMon, Deadline, []),
    Ordered = [{Name, proplists:get_value(Name, Results, {error, noResult})}
               || {Name, _} <- Tasks],
    {ok, Ordered}.

%% 单一 deadline 循环收集：每收到一个结果/崩溃就从 Pending 移除，
%% 直到 Pending 为空或 deadline 到达。deadline 到达时 kill 所有剩余
%% 子进程并标记 timeout。
collectParallel(Pending, MonByRef, PidByRef, RefByMon, Deadline, Acc) ->
    case map_size(Pending) =:= 0 of
        true ->
            Acc;
        false ->
            Remain = max(0, Deadline - erlang:monotonic_time(millisecond)),
            receive
                {eResult, Ref, Result} ->
                    case maps:take(Ref, Pending) of
                        {Name, Pending1} ->
                            case maps:get(Ref, MonByRef, undefined) of
                                undefined -> ok;
                                MonRef -> erlang:demonitor(MonRef, [flush])
                            end,
                            collectParallel(Pending1, MonByRef, PidByRef, RefByMon, Deadline,
                                            [{Name, Result} | Acc]);
                        error ->
                            %% 已处理过或陌生 Ref：忽略，避免阻塞其它任务。
                            collectParallel(Pending, MonByRef, PidByRef, RefByMon, Deadline, Acc)
                    end;
                {'DOWN', MonRef, process, _Pid, Reason} ->
                    case maps:get(MonRef, RefByMon, undefined) of
                        undefined ->
                            collectParallel(Pending, MonByRef, PidByRef, RefByMon, Deadline, Acc);
                        Ref ->
                            case maps:take(Ref, Pending) of
                                {Name, Pending1} ->
                                    collectParallel(Pending1, MonByRef, PidByRef, RefByMon, Deadline,
                                                    [{Name, {error, {crash, Reason}}} | Acc]);
                                error ->
                                    collectParallel(Pending, MonByRef, PidByRef, RefByMon, Deadline, Acc)
                            end
                    end
            after Remain ->
                %% deadline 到达：kill 仍存活的子进程并标记 timeout。
                maps:foreach(fun(Ref, _Name) ->
                    Pid = maps:get(Ref, PidByRef),
                    M = maps:get(Ref, MonByRef),
                    exit(Pid, kill),
                    erlang:demonitor(M, [flush])
                end, Pending),
                TimeoutResults = [{Name, {error, timeout}}
                                  || {_Ref, Name} <- maps:to_list(Pending)],
                Acc ++ TimeoutResults
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 子进程入口：执行单个子 Agent 任务，将结果（仅 Summary）回传给父进程。
%%
%% @end
%%--------------------------------------------------------------------
runOne(Name, Task, Parent, Ref, Opts) ->
    Result = case run(Name, Task, Opts) of
        {ok, Summary, _Meta} -> {ok, Summary};
        {error, _} = E -> E
    end,
    Parent ! {eResult, Ref, Result}.

%%%===================================================================
%%% Internal: single agent run
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 单个子 Agent 执行主体：构造独立的子会话 SessionId、组装 Opts（模式、工具白名单、
%% 策略、可选 model 覆盖）、写入审计日志，调用 alAgent:run 并按结果记录指标与审计，
%% 返回 {ok, Answer, Meta} 或 {error, Reason}。
%%
%% @end
%%--------------------------------------------------------------------
doRun(#{name := Name, role := Role} = Def, Task, Opts) ->
    %% 每个子 agent 实例用唯一 SessionId，避免并发子 agent 共享同一会话。
    Unique = integer_to_binary(erlang:unique_integer([positive])),
    SessionId = <<?SubSessionPrefix/binary, (atom_to_binary(Name, utf8))/binary,
                 "-", Unique/binary>>,
    Started = erlang:monotonic_time(millisecond),
    AliOpts0 = #{
        sessionId => SessionId,
        persistMemory => false,
        agentCfg => alConfig:getAgentCfg(),
        maxToolSteps => maps:get(maxSteps, Def, maps:get(maxSteps, Opts, 10)),
        mode => maps:get(mode, Def, ask),
        toolsAllowlist => maps:get(tools, Def, all),
        policy => policyForMode(maps:get(mode, Def, ask))
    },
    AliOpts1 = case maps:is_key(model, Def) of
        false -> AliOpts0;
        true -> AliOpts0#{llmOverride => #{model => maps:get(model, Def)}}
    end,
    AliOpts = case maps:is_key(model, Opts) of
        false -> AliOpts1;
        true -> AliOpts1#{llmOverride => #{model => maps:get(model, Opts)}}
    end,
    alAudit:log(#{
        session => SessionId,
        tool => subagent,
        ok => true,
        args => #{agent => Name, task => Task}
    }),
    Question = <<Role/binary, "\n\nTask: ", Task/binary>>,
    case alAgent:run(Question, AliOpts) of
        {ok, Result} ->
            Elapsed = erlang:monotonic_time(millisecond) - Started,
            Answer = case Result of
                #{answer := A} when is_binary(A) -> A;
                #{answer := A} -> toBinary(A);
                _ -> toBinary(Result)
            end,
            Meta = #{agent => Name, sessionId => SessionId, ms => Elapsed},
            alMetrics:recordAsk(#{durationMs => Elapsed, status => ok}),
            alAudit:log(#{
                session => SessionId,
                tool => subagent,
                ok => true,
                ms => Elapsed,
                result => #{summary => Answer}
            }),
            {ok, Answer, Meta};
        {error, Reason} ->
            Elapsed = erlang:monotonic_time(millisecond) - Started,
            alMetrics:recordAsk(#{durationMs => Elapsed, status => error}),
            alAudit:log(#{
                session => SessionId,
                tool => subagent,
                ok => false,
                ms => Elapsed,
                error => Reason
            }),
            {error, Reason}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 将输入转为 binary：支持 binary / list / atom 及其它任意 term（用 ~p 格式化）。
%%
%% @end
%%--------------------------------------------------------------------
toBinary(B) when is_binary(B) -> B;
toBinary(L) when is_list(L) -> unicode:characters_to_binary(L);
toBinary(A) when is_atom(A) -> atom_to_binary(A, utf8);
toBinary(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).

%%--------------------------------------------------------------------
%% @doc
%% 按模式返回对应策略 map：ask 使用默认只读策略；edit 开放 allowWrite；
%% exec 进一步开放 allowExecuteRisky；未知模式回退为默认策略。
%%
%% @end
%%--------------------------------------------------------------------
policyForMode(Mode) ->
    alPolicy:policyForMode(Mode).

%%--------------------------------------------------------------------
%% @doc
%% 返回内置子 Agent 定义列表。每个 Agent 包含 name、role、tools、mode、maxSteps，
%% 涵盖 explorer / codeReviewer / testAuthor / debugger / refactorer /
%% docWriter / planner / migrationAgent / releaseManager 等角色。
%%
%% @end
%%--------------------------------------------------------------------
builtin() ->
    [
        {explorer, #{
            name => explorer,
            role => <<
                "你是只读代码探索助手。定位代码并回答「X 在哪 / 怎么工作」。"
                "只用读工具。先给位置，再给关键代码引用。找不到就明确说找不到。"
                "回复与用户同语言（用户中文则全程中文）。"/utf8>>,
            tools => [searchCode, semanticSearch, readFile, getSymbolSource,
                      findCallers, findCallees],
            mode => ask,
            maxSteps => 10
        }},
        {codeReviewer, #{
            name => codeReviewer,
            role => <<
                "你是代码审查员。读 diff 与源码，给结构化反馈。"
                "检查：结构、正确性、风格、性能。"
                "按严重级别（Blocker/Major/Minor/Nit）输出，带 file:line 与建议。"
                "与用户同语言。"/utf8>>,
            tools => [searchCode, getSymbolSource, findCallers,
                      findCallees, readFile],
            mode => ask,
            maxSteps => 12
        }},
        {testAuthor, #{
            name => testAuthor,
            role => <<
                "你是测试工程师。为指定模块写 eunit。"
                "覆盖：正常路径、边界、错误输入。测试放在 test/，后缀 _test。"
                "说明文字与用户同语言。"/utf8>>,
            tools => [getSymbolSource, writeFile, applyPatch, readFile],
            mode => edit,
            maxSteps => 15
        }},
        {debugger, #{
            name => debugger,
            role => <<
                "你是运行时调试助手。定位问题（内存/消息堆积/异常进程）。"
                "流程：查进程树、找热点、给根因假设与验证方法。"
                "与用户同语言。"/utf8>>,
            tools => [searchCode, readFile, findCallers, findCallees,
                      getSymbolSource],
            mode => ask,
            maxSteps => 12
        }},
        {refactorer, #{
            name => refactorer,
            role => <<
                "你是重构助手。多文件改造并编译验证。"
                "原则：先 findCallers，每步可编译，保持对外行为。"
                "与用户同语言。"/utf8>>,
            tools => [readFile, applyPatch, writeFile, findCallers,
                      findCallees, getSymbolSource],
            mode => edit,
            maxSteps => 20
        }},
        {docWriter, #{
            name => docWriter,
            role => <<
                "你是文档助手。读代码写注释/文档。"
                "写 -doc/edoc，覆盖模块职责与关键函数。不改业务逻辑，只加注释。"
                "与用户同语言。"/utf8>>,
            tools => [getSymbolSource, writeFile, applyPatch, readFile],
            mode => edit,
            maxSteps => 12
        }},
        {planner, #{
            name => planner,
            role => <<
                "你是协调者。拆解大任务并委派子 agent。"
                "流程：订计划、把子任务分给最合适的 agent、汇总、给最终摘要。"
                "与用户同语言。"/utf8>>,
            tools => [readFile, searchCode, getSymbolSource, planSet, planGet,
                      planUpdate, planClear, delegateTo],
            mode => ask,
            maxSteps => 25
        }},
        {migrationAgent, #{
            name => migrationAgent,
            role => <<
                "你是迁移专家。跨 OTP/依赖升级。"
                "流程：扫破坏性变更关键词，用 applyPatch 换新 API，eunit 验证。"
                "与用户同语言。"/utf8>>,
            tools => [searchCode, applyPatch, readFile, getSymbolSource],
            mode => edit,
            maxSteps => 20
        }},
        {releaseManager, #{
            name => releaseManager,
            role => <<
                "你是发布经理。生成 changelog / release notes。"
                "流程：收集提交、确认关键变更、生成 CHANGELOG 段落。"
                "按 conventional commits 分类（feat/fix/refactor/docs）。"
                "与用户同语言。"/utf8>>,
            tools => [searchCode, readFile, writeFile],
            mode => edit,
            maxSteps => 10
        }}
    ].
