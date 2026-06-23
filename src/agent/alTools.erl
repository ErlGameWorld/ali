%%%-------------------------------------------------------------------
%%% @doc Agent 工具注册表与执行调度。
%%%
%%% 维护所有可用工具（读文件、AST 分析、OTP 树、Eunit 等）的元数据，
%%% 导出 OpenAI function-calling schema，并在策略 {@link alPolicy} 校验后
%%% 分发到各 `alTool*` 实现模块执行。
%%% @end
%%%-------------------------------------------------------------------
-module(alTools).

-export([
    listTools/0,
    toolDescriptions/0,
    openAiTools/0,
    execute/4,
    execute/5,
    toolModule/1,
    registerTool/1,
    unregisterTool/1,
    registeredTools/0,
    customToolLevel/1,
    emitProgress/2
]).

-define(CUSTOM_TOOLS_KEY, {?MODULE, customTools}).
-define(BUILTIN_LIST_KEY, {?MODULE, builtinList}).
-define(BUILTIN_INDEX_KEY, {?MODULE, builtinIndex}).
-define(DEFAULT_TOOL_TIMEOUT, 60000).

-type toolDef() :: #{
    name := atom(),
    description := binary(),
    parameters := binary(),
    module := module(),
    function := atom(),
    preview => atom()
}.

-spec listTools() -> [atom()].
%% @doc 返回所有已注册工具的名称列表。
listTools() ->
    [maps:get(name, T) || T <- allTools()].

-spec toolDescriptions() -> binary().
%% @doc 生成供系统提示词使用的工具说明文本（纯文本列表）。
toolDescriptions() ->
    Lines = [formatTool(T) || T <- allTools()],
    iolist_to_binary(string:join(Lines, "\n")).

-spec openAiTools() -> [map()].
%% @doc 导出 OpenAI function-calling 格式的工具 schema 列表。
openAiTools() ->
    [toOpenAiTool(T) || T <- allTools()].

toOpenAiTool(#{name := Name, description := Desc, parameters := Params}) ->
    Schema = decodeSchema(Params),
    #{
        <<"type"/utf8>> => <<"function"/utf8>>,
        <<"function"/utf8>> => #{
            <<"name"/utf8>> => atom_to_binary(Name, utf8),
            <<"description"/utf8>> => Desc,
            <<"parameters"/utf8>> => Schema
        }
    }.

decodeSchema(Params) ->
    try
        Map = llmJson:decode(Params),
        case maps:is_key(<<"type"/utf8>>, Map) of
            true ->
                Map;
            false ->
                Props = maps:fold(fun(K, V, Acc) ->
                    maps:put(K, #{<<"type"/utf8>> => schemaType(V)}, Acc)
                end, #{}, Map),
                #{<<"type"/utf8>> => <<"object"/utf8>>, <<"properties"/utf8>> => Props}
        end
    catch
        _:_ ->
            #{<<"type"/utf8>> => <<"object"/utf8>>, <<"properties"/utf8>> => #{}}
    end.

schemaType(V) when is_binary(V) -> <<"string"/utf8>>;
schemaType(V) when is_integer(V) -> <<"integer"/utf8>>;
schemaType(V) when is_boolean(V) -> <<"boolean"/utf8>>;
schemaType(V) when is_list(V) -> <<"array"/utf8>>;
schemaType(_) -> <<"string"/utf8>>.

-spec execute(atom(), map(), map(), binary()) -> {ok, map()} | {error, term()}.
%% @doc 执行工具（策略校验 + 审计日志），无额外上下文。
execute(Tool, Args, Config, SessionId) ->
    execute(Tool, Args, Config, SessionId, #{}).

-spec execute(atom(), map(), map(), binary(), map()) ->
    {ok, map()} | {error, term()} | {pending, map()}.
%% @doc 执行工具；需写确认时返回 `{pending, PreviewMap}'。
execute(Tool, Args, Config, SessionId, Context) ->
    Policy = maps:get(policy, Config, alPolicy:defaultPolicy()),
    Mode = maps:get(mode, Config, ask),
    Ctx = maps:merge(Context, #{mode => Mode}),
    case alPolicy:checkTool(Tool, Policy, Ctx) of
        ok ->
            doExecute(Tool, Args, Config, SessionId, Context);
        {error, confirmationRequired} ->
            case previewTool(Tool, Args, Config) of
                {ok, Preview} ->
                    TaskId = createTaskId(),
                    Pending = Preview#{
                        taskId => TaskId,
                        tool => Tool,
                        args => Args,
                        sessionId => SessionId
                    },
                    {pending, Pending};
                {error, Reason} ->
                    logAndError(SessionId, Tool, Args, #{ok => false, error => Reason}),
                    {error, Reason}
            end;
        {error, denied} ->
            logAndError(SessionId, Tool, Args, #{ok => false, error => denied}),
            {error, denied}
    end.

%% 策略通过后实际调用 alTool* 模块执行。
%% 使用 spawn + monitor 实现超时保护，防止慢工具（如读超大文件、慢 git）
%% 阻塞 Agent 循环。默认超时 60s，可通过 Config 的 toolTimeout 覆盖。
doExecute(Tool, Args, Config, SessionId, _Context) ->
    case findTool(Tool) of
        {ok, #{module := Mod, function := Fun}} ->
            Started = erlang:monotonic_time(millisecond),
            ToolConfig = Config#{sessionId => SessionId, toolName => Tool},
            Timeout = maps:get(toolTimeout, Config, ?DEFAULT_TOOL_TIMEOUT),
            Result = callWithTimeout(Mod, Fun, Args, ToolConfig, Timeout, Config),
            Elapsed = erlang:monotonic_time(millisecond) - Started,
            Out = formatToolResult(Result, Elapsed),
            alAudit:log(SessionId, Tool, Args, Out),
            %% 工具级指标采集
            alMetrics:recordTool(#{
                tool => Tool,
                durationMs => Elapsed,
                ok => maps:get(ok, Out, true)
            }),
            alMetrics:emitTelemetry([ali, tool, exec],
                #{durationMs => Elapsed},
                #{tool => Tool, ok => maps:get(ok, Out, true), sessionId => SessionId}),
            case Result of
                {ok, Data} -> {ok, Data#{elapsedMs => Elapsed}};
                {error, Reason} -> {error, Reason}
            end;
        error ->
            {error, unknownTool}
    end.

%% 在独立进程中执行工具调用，超时返回 {error, toolTimeout}。
%% 工具进程可通过 alTools:emitProgress(ToolConfig, Event) 发送流式进度事件，
%% 调用方会转发到 alProgress，实现工具执行的流式反馈。
callWithTimeout(Mod, Fun, Args, ToolConfig, Timeout, Config) ->
    Caller = self(),
    Ref = make_ref(),
    %% 注入 callerPid 与 toolRef，供工具调用 emitProgress
    ToolConfigWithCaller = ToolConfig#{callerPid => Caller, toolRef => Ref},
    {Pid, MonRef} = spawn_monitor(fun() ->
        Result = try Mod:Fun(Args, ToolConfigWithCaller) catch
            Class:Reason:Stack ->
                {error, #{class => Class, reason => Reason, stack => lists:sublist(Stack, 5)}}
        end,
        Caller ! {toolResult, Ref, Result}
    end),
    collectToolMessages(Pid, MonRef, Ref, Config, Timeout).

%% 收集工具进程的进度消息与最终结果，超时则杀进程。
collectToolMessages(Pid, MonRef, Ref, Config, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    collectToolMessagesLoop(Pid, MonRef, Ref, Config, Deadline).

collectToolMessagesLoop(Pid, MonRef, Ref, Config, Deadline) ->
    Now = erlang:monotonic_time(millisecond),
    Remaining = max(0, Deadline - Now),
    receive
        {toolProgress, Ref, Event} ->
            emitToolProgress(Config, Event),
            collectToolMessagesLoop(Pid, MonRef, Ref, Config, Deadline);
        {toolResult, Ref, Result} ->
            erlang:demonitor(MonRef, [flush]),
            Result;
        {'DOWN', MonRef, process, Pid, Reason} ->
            {error, #{class => processCrash, reason => Reason}}
    after Remaining ->
        erlang:demonitor(MonRef, [flush]),
        exit(Pid, kill),
        {error, toolTimeout}
    end.

%% 将工具进程的进度事件转发到 alProgress（若配置了 progressId）。
emitToolProgress(Config, Event) ->
    case maps:get(progressId, Config, undefined) of
        undefined -> ok;
        _ProgressId ->
            %% 复用 alLoop 的 emit_progress 机制：通过进程字典或直接调用
            %% 这里直接调用 alProgress:emit，保持与 alLoop 一致的事件流
            alProgress:emit(maps:get(progressId, Config), Event)
    end.

%% @doc 工具实现可调用此函数向调用方发送流式进度事件。
%% 工具在独立进程中执行，通过 ToolConfig 中的 callerPid 与 toolRef
%% 发送 {toolProgress, Ref, Event} 消息，由调度器转发到 alProgress。
%% 若 ToolConfig 中缺少 callerPid/toolRef（如直接调用），则忽略。
-spec emitProgress(map(), map()) -> ok.
emitProgress(ToolConfig, Event) ->
    case {maps:get(callerPid, ToolConfig, undefined),
          maps:get(toolRef, ToolConfig, undefined)} of
        {Pid, Ref} when is_pid(Pid), is_reference(Ref) ->
            Pid ! {toolProgress, Ref, Event},
            ok;
        _ ->
            ok
    end.

%% 写操作类工具：生成预览供用户确认
previewTool(writeFile, Args, Config) ->
    alToolEdit:previewWrite(Args, Config);
previewTool(patchFile, Args, Config) ->
    alToolEdit:previewPatch(Args, Config);
previewTool(compileLoad, Args, Config) ->
    alToolEdit:previewCompileLoad(Args, Config);
previewTool(formatCode, Args, Config) ->
    previewFormatCode(Args, Config);
previewTool(Tool, _Args, _Config) ->
    {ok, #{
        tool => Tool,
        requiresConfirmation => true,
        message => <<"This tool requires confirmation before execution"/utf8>>
    }}.

%% formatCode 预览：返回将格式化的文件路径与当前内容摘要。
previewFormatCode(Args, Config) ->
    Path = maps:get(path, Args, undefined),
    case Path of
        undefined ->
            {ok, #{tool => formatCode, requiresConfirmation => true,
                   message => <<"missing path"/utf8>>}};
        _ ->
            Root = case maps:get(projectRoot, Config, undefined) of
                undefined -> alToolProject:findProjectRootFromModule();
                R when is_binary(R) -> binary_to_list(R);
                R when is_list(R) -> R
            end,
            case alToolProject:resolvePathForEdit(Root, Path) of
                {ok, AbsPath} ->
                    {ok, #{
                        tool => formatCode,
                        action => formatCode,
                        path => AbsPath,
                        exists => filelib:is_file(AbsPath),
                        requiresConfirmation => true,
                        message => <<"Will format this .erl file in place using erl_tidy"/utf8>>
                    }};
                {error, Reason} ->
                    {ok, #{tool => formatCode, requiresConfirmation => true,
                           error => Reason}}
            end
    end.

%% 统一工具返回结果为审计日志格式
formatToolResult({ok, Data}, Elapsed) ->
    #{ok => true, result => Data, elapsedMs => Elapsed};
formatToolResult({error, Reason}, Elapsed) ->
    #{ok => false, error => Reason, elapsedMs => Elapsed}.

%% 记录审计并返回（用于拒绝/错误路径）
logAndError(SessionId, Tool, Args, Out) ->
    alAudit:log(SessionId, Tool, Args, Out),
    ok.

%% 按名称查找工具定义：先查内置索引（O(1) map），再查自定义注册表（O(1)）。
findTool(Name) ->
    case maps:find(Name, builtinIndex()) of
        {ok, T} -> {ok, T};
        error ->
            case maps:get(Name, customRegistry(), undefined) of
                undefined -> error;
                Def -> {ok, maps:without([level], Def)}
            end
    end.

%% @doc 返回工具对应的实现模块名。
-spec toolModule(atom()) -> module() | undefined.
toolModule(Tool) ->
    case findTool(Tool) of
        {ok, #{module := Mod}} -> Mod;
        error -> undefined
    end.

formatTool(#{name := Name, description := Desc, parameters := Params}) ->
    io_lib:format("- ~s: ~s~n  params: ~s", [atom_to_list(Name), Desc, Params]).

createTaskId() ->
    integer_to_binary(erlang:unique_integer([positive, monotonic])).

%% @doc 运行时注册自定义工具，无需修改源码即可扩展 Agent 能力。
%%
%% Def 需含 `name`(atom)、`description`(binary)、`parameters`(JSON binary)、
%% `module`、`function`；可选 `level`（read/executeSafe/executeRisky/write，默认 executeRisky）。
%% 同名工具将被覆盖。内置工具不可被覆盖（返回 `{error, builtinConflict}`）。
-spec registerTool(map()) -> ok | {error, term()}.
registerTool(Def) when is_map(Def) ->
    Required = [name, description, parameters, module, function],
    case lists:all(fun(K) -> maps:is_key(K, Def) end, Required) of
        false ->
            {error, {missingKeys, [K || K <- Required, not maps:is_key(K, Def)]}};
        true ->
            Name = maps:get(name, Def),
            case isBuiltin(Name) of
                true -> {error, builtinConflict};
                false ->
                    Level = maps:get(level, Def, executeRisky),
                    Custom = customRegistry(),
                    persistent_term:put(?CUSTOM_TOOLS_KEY,
                        Custom#{Name => Def#{level => Level}}),
                    ok
            end
    end;
registerTool(_) ->
    {error, invalidToolDef}.

%% @doc 注销自定义工具。
-spec unregisterTool(atom()) -> ok.
unregisterTool(Name) ->
    Custom = customRegistry(),
    persistent_term:put(?CUSTOM_TOOLS_KEY, maps:remove(Name, Custom)),
    ok.

%% @doc 返回所有已注册的自定义工具定义列表。
-spec registeredTools() -> [map()].
registeredTools() ->
    maps:values(customRegistry()).

%% @doc 查询自定义工具的权限级别；未注册返回默认 executeRisky。
-spec customToolLevel(atom()) -> atom().
customToolLevel(Name) ->
    case maps:get(Name, customRegistry(), undefined) of
        #{level := Level} -> Level;
        _ -> executeRisky
    end.

%% 读取自定义工具注册表（persistent_term 持久化于节点内）。
customRegistry() ->
    persistent_term:get(?CUSTOM_TOOLS_KEY, #{}).

%% 判断是否为内置工具名（O(1)，走缓存索引）。
isBuiltin(Name) ->
    maps:is_key(Name, builtinIndex()).

%% @doc 全部工具 = 内置工具 + 运行时注册的自定义工具。
-spec allTools() -> [toolDef()].
allTools() ->
    Customs = [maps:without([level], D) || D <- registeredTools()],
    cachedBuiltins() ++ Customs.

%% 内置工具列表缓存：builtinTools/0 是静态字面量，只构建一次存入 persistent_term。
cachedBuiltins() ->
    case persistent_term:get(?BUILTIN_LIST_KEY, undefined) of
        undefined ->
            L = builtinTools(),
            persistent_term:put(?BUILTIN_LIST_KEY, L),
            L;
        L ->
            L
    end.

%% 内置工具名称→定义索引（O(1) 查找），同样只构建一次。
builtinIndex() ->
    case persistent_term:get(?BUILTIN_INDEX_KEY, undefined) of
        undefined ->
            Index = maps:from_list([{maps:get(name, T), T} || T <- cachedBuiltins()]),
            persistent_term:put(?BUILTIN_INDEX_KEY, Index),
            Index;
        Index ->
            Index
    end.

-spec builtinTools() -> [toolDef()].
builtinTools() ->
    [
        #{
            name => readFile,
            description => <<"Read a project file by relative path"/utf8>>,
            parameters => <<"{\"path\": \"relative/path\"}"/utf8>>,
            module => alToolProject,
            function => readFile
        },
        #{
            name => listFiles,
            description => <<"List files in a project directory"/utf8>>,
            parameters => <<"{\"path\": \".\", \"pattern\": \"*\"}"/utf8>>,
            module => alToolProject,
            function => listFiles
        },
        #{
            name => searchText,
            description => <<"Search text across project source files"/utf8>>,
            parameters => <<"{\"query\": \"search term\"}"/utf8>>,
            module => alToolProject,
            function => searchText
        },
        #{
            name => projectIndex,
            description => <<"Build Erlang module index for the project (legacy scan)"/utf8>>,
            parameters => <<"{}"/utf8>>,
            module => alToolProject,
            function => projectIndex
        },
        #{
            name => codeIndex,
            description => <<"Refresh persistent code index (modules, exports, behaviours, functions)"/utf8>>,
            parameters => <<"{\"force\": false}"/utf8>>,
            module => alToolAnalyze,
            function => codeIndex
        },
        #{
            name => searchCodeIndex,
            description => <<"Search module and function names in code index (fuzzy substring)"/utf8>>,
            parameters => <<"{\"query\": \"chat\", \"maxResults\": 30}"/utf8>>,
            module => alToolAnalyze,
            function => searchCodeIndex
        },
        #{
            name => getFunctionSource,
            description => <<"Get source code for a module function with line numbers"/utf8>>,
            parameters => <<"{\"module\": \"llmCli\", \"function\": \"chat\", \"arity\": 3}"/utf8>>,
            module => alToolAnalyze,
            function => getFunctionSource
        },
        #{
            name => analyzeCalls,
            description => <<"AST-based outbound function calls from a module function (regex fallback)"/utf8>>,
            parameters => <<"{\"module\": \"llmCli\", \"function\": \"chat\"}"/utf8>>,
            module => alToolAnalyze,
            function => analyzeCalls
        },
        #{
            name => findCallers,
            description => <<"AST-based search for modules calling a given function"/utf8>>,
            parameters => <<"{\"module\": \"llmCli\", \"function\": \"chat\"}"/utf8>>,
            module => alToolAnalyze,
            function => findCallers
        },
        #{
            name => getBeamAbstract,
            description => <<"Get abstract code from loaded module beam file"/utf8>>,
            parameters => <<"{\"module\": \"llmCli\"}"/utf8>>,
            module => alToolAnalyze,
            function => getBeamAbstract
        },
        #{
            name => analyzeBehaviours,
            description => <<"List OTP behaviours used by module(s)"/utf8>>,
            parameters => <<"{\"module\": \"alServer\"}"/utf8>>,
            module => alToolAnalyze,
            function => analyzeBehaviours
        },
        #{
            name => moduleDependencies,
            description => <<"List module import dependencies"/utf8>>,
            parameters => <<"{\"module\": \"llmCli\"}"/utf8>>,
            module => alToolAnalyze,
            function => moduleDependencies
        },
        #{
            name => dependencyGraph,
            description => <<"Build module dependency graph with Mermaid output"/utf8>>,
            parameters => <<"{}"/utf8>>,
            module => alToolAnalyze,
            function => dependencyGraph
        },
        #{
            name => analyzeCallGraph,
            description => <<"AST-based outbound call graph for a module"/utf8>>,
            parameters => <<"{\"module\": \"llmCli\"}"/utf8>>,
            module => alToolAnalyze,
            function => analyzeCallGraph
        },
        #{
            name => codeQuality,
            description => <<"Basic static quality checks (exports, specs, etc.)"/utf8>>,
            parameters => <<"{\"module\": \"llmCli\"}"/utf8>>,
            module => alToolAnalyze,
            function => codeQuality
        },
        #{
            name => getAppInfo,
            description => <<"Get OTP application metadata and env keys"/utf8>>,
            parameters => <<"{\"application\": \"ali\"}"/utf8>>,
            module => alToolOtp,
            function => getAppInfo
        },
        #{
            name => getSupTree,
            description => <<"Get supervisor tree for application(s)"/utf8>>,
            parameters => <<"{\"application\": \"ali\", \"maxDepth\": 4}"/utf8>>,
            module => alToolOtp,
            function => getSupTree
        },
        #{
            name => etopSummary,
            description => <<"Top processes by memory (etop-like summary)"/utf8>>,
            parameters => <<"{\"limit\": 15}"/utf8>>,
            module => alToolOtp,
            function => etopSummary
        },
        #{
            name => loadedApplications,
            description => <<"List loaded OTP applications on this node"/utf8>>,
            parameters => <<"{}"/utf8>>,
            module => alToolRuntime,
            function => loadedApplications
        },
        #{
            name => loadedModules,
            description => <<"List loaded Erlang modules"/utf8>>,
            parameters => <<"{\"limit\": 200}"/utf8>>,
            module => alToolRuntime,
            function => loadedModules
        },
        #{
            name => moduleExports,
            description => <<"List exported functions of a module"/utf8>>,
            parameters => <<"{\"module\": \"llmCli\"}"/utf8>>,
            module => alToolRuntime,
            function => moduleExports
        },
        #{
            name => registeredProcesses,
            description => <<"List registered process names"/utf8>>,
            parameters => <<"{}"/utf8>>,
            module => alToolRuntime,
            function => registeredProcesses
        },
        #{
            name => processList,
            description => <<"Summarize running processes"/utf8>>,
            parameters => <<"{\"limit\": 50}"/utf8>>,
            module => alToolRuntime,
            function => processList
        },
        #{
            name => processInfo,
            description => <<"Get info for a process by pid or registered name"/utf8>>,
            parameters => <<"{\"name\": \"alServer\"} or {\"pid\": \"<0.123.0>\"}"/utf8>>,
            module => alToolRuntime,
            function => processInfo
        },
        #{
            name => nodeInfo,
            description => <<"Get Erlang node runtime summary"/utf8>>,
            parameters => <<"{}"/utf8>>,
            module => alToolRuntime,
            function => nodeInfo
        },
        #{
            name => agentConfig,
            description => <<"Get current Agent configuration (model, maxSteps, policy, etc.)"/utf8>>,
            parameters => <<"{}"/utf8>>,
            module => alToolRuntime,
            function => agentConfig
        },
        #{
            name => runtimeSummary,
            description => <<"Get combined node runtime overview (node, memory, apps, processes) in one call"/utf8>>,
            parameters => <<"{\"processLimit\": 10}"/utf8>>,
            module => alToolRuntime,
            function => runtimeSummary
        },
        #{
            name => remoteNodeInfo,
            description => <<"Get runtime summary from a remote Erlang node"/utf8>>,
            parameters => <<"{\"node\": \"node@host\"}"/utf8>>,
            module => alToolRuntime,
            function => remoteNodeInfo
        },
        #{
            name => topProcesses,
            description => <<"Top processes by metric: memory | reductions | message_queue_len (find hotspots)"/utf8>>,
            parameters => <<"{\"by\": \"memory\", \"limit\": 10}"/utf8>>,
            module => alToolRuntime,
            function => topProcesses
        },
        #{
            name => schedulerInfo,
            description => <<"Scheduler, run queue, reductions and memory overview"/utf8>>,
            parameters => <<"{}"/utf8>>,
            module => alToolRuntime,
            function => schedulerInfo
        },
        #{
            name => etsTables,
            description => <<"List ETS tables with size/memory/type (sorted by memory desc)"/utf8>>,
            parameters => <<"{\"limit\": 100}"/utf8>>,
            module => alToolRuntime,
            function => etsTables
        },
        #{
            name => gitStatus,
            description => <<"Show git working tree status (read-only)"/utf8>>,
            parameters => <<"{}"/utf8>>,
            module => alToolGit,
            function => gitStatus
        },
        #{
            name => gitDiff,
            description => <<"Show git diff stat; optional path/staged (read-only)"/utf8>>,
            parameters => <<"{\"path\": \"src/x.erl\", \"staged\": false}"/utf8>>,
            module => alToolGit,
            function => gitDiff
        },
        #{
            name => gitLog,
            description => <<"Show recent git commits (read-only)"/utf8>>,
            parameters => <<"{\"limit\": 20}"/utf8>>,
            module => alToolGit,
            function => gitLog
        },
        #{
            name => gitBranch,
            description => <<"List git branches with tracking info (read-only)"/utf8>>,
            parameters => <<"{}"/utf8>>,
            module => alToolGit,
            function => gitBranch
        },
        #{
            name => svnStatus,
            description => <<"Show SVN working copy status (read-only)"/utf8>>,
            parameters => <<"{\"showUpdates\": false}"/utf8>>,
            module => alToolSvn,
            function => svnStatus
        },
        #{
            name => svnDiff,
            description => <<"Show SVN diff; optional path/revision (read-only)"/utf8>>,
            parameters => <<"{\"path\": \"src/x.erl\", \"revision\": \"BASE:HEAD\"}"/utf8>>,
            module => alToolSvn,
            function => svnDiff
        },
        #{
            name => svnLog,
            description => <<"Show recent SVN commits (read-only)"/utf8>>,
            parameters => <<"{\"limit\": 20}"/utf8>>,
            module => alToolSvn,
            function => svnLog
        },
        #{
            name => svnInfo,
            description => <<"Show SVN working copy info: URL, revision, root (read-only)"/utf8>>,
            parameters => <<"{}"/utf8>>,
            module => alToolSvn,
            function => svnInfo
        },
        #{
            name => searchCode,
            description => <<"Semantic/keyword search over the codebase; returns most relevant function snippets"/utf8>>,
            parameters => <<"{\"query\": \"how are tools dispatched\", \"limit\": 5}"/utf8>>,
            module => alToolAnalyze,
            function => searchCode
        },
        #{
            name => semanticSearch,
            description => <<"Vector semantic search (hybrid: embeddings + TF-IDF); best for natural-language queries. Falls back to TF-IDF when embeddings unavailable"/utf8>>,
            parameters => <<"{\"query\": \"where authentication is handled\", \"limit\": 5, \"vectorWeight\": 0.6, \"tfidfWeight\": 0.4}"/utf8>>,
            module => alToolAnalyze,
            function => semanticSearch
        },
        #{
            name => planSet,
            description => <<"Create/replace the task plan for a multi-step request (array of step titles)"/utf8>>,
            parameters => <<"{\"steps\": [\"Investigate X\", \"Implement Y\", \"Verify with tests\"]}"/utf8>>,
            module => alPlan,
            function => planSet
        },
        #{
            name => planUpdate,
            description => <<"Update a plan step status (pending|in_progress|done|skipped) and optional note"/utf8>>,
            parameters => <<"{\"id\": 1, \"status\": \"done\", \"note\": \"...\"}"/utf8>>,
            module => alPlan,
            function => planUpdate
        },
        #{
            name => planGet,
            description => <<"Get the current task plan and progress"/utf8>>,
            parameters => <<"{}"/utf8>>,
            module => alPlan,
            function => planGet
        },
        #{
            name => callFunction,
            description => <<"Call an Erlang function (blocked if on execBlacklist). String args auto-coerce to atom/pid/number when appropriate (e.g. ets:info/1)."/utf8>>,
            parameters => <<"{\"module\": \"ets\", \"function\": \"info\", \"args\": [\"alMetrics\"]}"/utf8>>,
            module => alToolEval,
            function => callFunction
        },
        #{
            name => writeFile,
            description => <<"Write content to a project file (requires confirmation)"/utf8>>,
            parameters => <<"{\"path\": \"src/example.erl\", \"content\": \"...\"}"/utf8>>,
            module => alToolEdit,
            function => writeFile
        },
        #{
            name => patchFile,
            description => <<"Replace text in a project file; oldText must match uniquely unless replaceAll=true (requires confirmation)"/utf8>>,
            parameters => <<"{\"path\": \"src/example.erl\", \"oldText\": \"...\", \"newText\": \"...\", \"replaceAll\": false}"/utf8>>,
            module => alToolEdit,
            function => patchFile
        },
        #{
            name => compileLoad,
            description => <<"Compile .erl file and hot-load module into runtime (requires confirmation)"/utf8>>,
            parameters => <<"{\"path\": \"src/example.erl\"}"/utf8>>,
            module => alToolEdit,
            function => compileLoad
        },
        #{
            name => rollbackFile,
            description => <<"Restore file from latest backup"/utf8>>,
            parameters => <<"{\"path\": \"src/example.erl\", \"backupId\": \"latest\"}"/utf8>>,
            module => alToolEdit,
            function => rollbackFile
        },
        #{
            name => listBackups,
            description => <<"List all backups for a project file (read-only)"/utf8>>,
            parameters => <<"{\"path\": \"src/example.erl\"}"/utf8>>,
            module => alToolEdit,
            function => listBackups
        },
        #{
            name => sessionUndo,
            description => <<"Undo all file changes made in the current session (restores to pre-session state)"/utf8>>,
            parameters => <<"{}"/utf8>>,
            module => alToolEdit,
            function => sessionUndo
        },
        #{
            name => formatCode,
            description => <<"Format an Erlang .erl file in place using erl_tidy (requires confirmation)"/utf8>>,
            parameters => <<"{\"path\": \"src/example.erl\", \"backup\": true}"/utf8>>,
            module => alToolEdit,
            function => formatCode
        },
        #{
            name => runEunit,
            description => <<"Run EUnit tests via rebar3 eunit (module=all or specific module)"/utf8>>,
            parameters => <<"{\"module\": \"all\", \"timeout\": 120000}"/utf8>>,
            module => alToolTest,
            function => runEunit
        },
        #{
            name => generateEunit,
            description => <<"Generate a basic smoke EUnit test module for target module"/utf8>>,
            parameters => <<"{\"module\": \"llmCli\"}"/utf8>>,
            module => alToolTest,
            function => generateEunit
        },
        #{
            name => listTestModules,
            description => <<"List *_test.erl modules in project test/ directory"/utf8>>,
            parameters => <<"{}"/utf8>>,
            module => alToolTest,
            function => listTestModules
        },
        #{
            name => runCommonTest,
            description => <<"Run Common Test via rebar3 ct (suite=all or specific)"/utf8>>,
            parameters => <<"{\"suite\": \"all\", \"timeout\": 300000}"/utf8>>,
            module => alToolTest,
            function => runCommonTest
        },
        #{
            name => generateCommonTest,
            description => <<"Generate a basic Common Test suite skeleton for target module"/utf8>>,
            parameters => <<"{\"module\": \"llmCli\"}"/utf8>>,
            module => alToolTest,
            function => generateCommonTest
        }
    ].