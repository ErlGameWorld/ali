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
    toolModule/1
]).

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

%% 策略通过后实际调用 alTool* 模块执行
doExecute(Tool, Args, Config, SessionId, _Context) ->
    case findTool(Tool) of
        {ok, #{module := Mod, function := Fun}} ->
            Started = erlang:monotonic_time(millisecond),
            Result = try Mod:Fun(Args, Config) catch
                Class:ToolReason:Stack ->
                    {error, #{class => Class, reason => ToolReason, stack => lists:sublist(Stack, 5)}}
            end,
            Elapsed = erlang:monotonic_time(millisecond) - Started,
            Out = formatToolResult(Result, Elapsed),
            alAudit:log(SessionId, Tool, Args, Out),
            case Result of
                {ok, Data} -> {ok, Data#{elapsedMs => Elapsed}};
                {error, Reason} -> {error, Reason}
            end;
        error ->
            {error, unknownTool}
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

%% 按名称查找工具定义
findTool(Name) ->
    case lists:filter(fun(T) -> maps:get(name, T) =:= Name end, allTools()) of
        [T | _] -> {ok, T};
        [] -> error
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

-spec allTools() -> [toolDef()].
allTools() ->
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
            name => callFunction,
            description => <<"Call an Erlang function (blocked if on execBlacklist)"/utf8>>,
            parameters => <<"{\"module\": \"llmCli\", \"function\": \"estimateTokens\", \"args\": [\"hello\"]}"/utf8>>,
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
            description => <<"Replace text in a project file (requires confirmation)"/utf8>>,
            parameters => <<"{\"path\": \"src/example.erl\", \"oldText\": \"...\", \"newText\": \"...\"}"/utf8>>,
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