%%%-------------------------------------------------------------------
%%% @doc MCP（Model Context Protocol）Server 模式。
%%%
%%% 将 ali 的 50+ 内置工具通过 JSON-RPC 2.0 over stdio 对外暴露，
%%% 供 Cursor / Claude Desktop 等 MCP 客户端调用。
%%%
%%% 使用方式（在客户端配置中指定命令与参数）：
%%% ```
%%% {
%%%   "mcpServers": {
%%%     "ali": {
%%%       "command": "erl",
%%%       "args": ["-noshell", "-eval", "ali:start(), alMcpServer:stdio()",
%%%                "-s", "init", "stop"]
%%%     }
%%%   }
%%% }
%%% ```
%%%
%%% 支持的 JSON-RPC 方法：
%%% <ul>
%%%   <li>`initialize' — 返回 Server 能力声明（tools）</li>
%%%   <li>`notifications/initialized' — 客户端就绪通知（无响应）</li>
%%%   <li>`tools/list' — 返回 ali 全部内置工具的 MCP 定义</li>
%%%   <li>`tools/call' — 执行指定工具（read 级，只读策略）</li>
%%%   <li>`ping' — 心跳检测</li>
%%% </ul>
%%%
%%% 安全约束：tool/call 一律采用只读策略（ask 模式），不执行写文件、
%%% 编译加载或 callFunction。如需更宽松的策略，可通过环境变量覆写。
%%% @end
%%%-------------------------------------------------------------------
-module(alMcpServer).

-export([
    stdio/0
]).

-define(PROTOCOL_VERSION, <<"2024-11-05"/utf8>>).
-define(SERVER_NAME, <<"ali"/utf8>>).
-define(SERVER_VERSION, <<"0.1.0"/utf8>>).

%% @doc 启动 stdio 模式 MCP Server（阻塞当前进程）。
%% 从标准输入逐行读取 JSON-RPC 请求，将响应写入标准输出。
%% 进程持续运行直至 stdin 关闭或收到 exit 信号。
-spec stdio() -> no_return().
stdio() ->
    io:setopts(standard_io, [binary]),
    io:format(standard_error, "[alMcpServer] started on stdio~n", []),
    serverLoop().

%%%===================================================================
%%% Server Loop
%%%===================================================================

serverLoop() ->
    case io:get_line(standard_io, <<>>) of
        eof ->
            io:format(standard_error, "[alMcpServer] stdin closed, exiting~n", []),
            halt(0);
        {error, _} ->
            halt(0);
        Line ->
            processLine(string:trim(unicode:characters_to_list(Line))),
            serverLoop()
    end.

processLine("") ->
    ok;
processLine(Line) ->
    try llmJson:decode(Line) of
        #{<<"jsonrpc"/utf8>> := <<"2.0"/utf8>>} = Req ->
            case maps:find(<<"id"/utf8>>, Req) of
                {ok, Id} ->
                    Response = handleRequest(Id, Req),
                    emitResponse(Response);
                error ->
                    %% 通知（无 id）：不回复
                    handleNotification(Req)
            end;
        _ ->
            emitError(null, -32600, <<"Invalid Request"/utf8>>)
    catch
        _:_ ->
            emitError(null, -32700, <<"Parse error"/utf8>>)
    end.

%%%===================================================================
%%% Request Handlers
%%%===================================================================

handleRequest(Id, #{<<"method"/utf8>> := <<"initialize"/utf8>>, <<"params"/utf8>> := _Params}) ->
    Result = #{
        <<"protocolVersion"/utf8>> => ?PROTOCOL_VERSION,
        <<"serverInfo"/utf8>> => #{
            <<"name"/utf8>> => ?SERVER_NAME,
            <<"version"/utf8>> => ?SERVER_VERSION
        },
        <<"capabilities"/utf8>> => #{
            <<"tools"/utf8>> => #{}
        }
    },
    jsonResponse(Id, Result);

handleRequest(Id, #{<<"method"/utf8>> := <<"tools/list"/utf8>>}) ->
    Tools = alTools:openAiTools(),
    McpTools = [toMcpTool(T) || T <- Tools],
    jsonResponse(Id, #{<<"tools"/utf8>> => McpTools});

handleRequest(Id, #{<<"method"/utf8>> := <<"tools/call"/utf8>>, <<"params"/utf8>> := Params}) ->
    ToolName = maps:get(<<"name"/utf8>>, Params, <<>>),
    ToolArgs = maps:get(<<"arguments"/utf8>>, Params, #{}),
    case safeExecute(unicode:characters_to_list(ToolName), ToolArgs) of
        {ok, ResultData} ->
            Content = formatToolResult(ResultData),
            jsonResponse(Id, #{
                <<"content"/utf8>> => [#{
                    <<"type"/utf8>> => <<"text"/utf8>>,
                    <<"text"/utf8>> => Content
                }]
            });
        {error, Reason} ->
            Content = formatToolError(Reason),
            jsonResponse(Id, #{
                <<"content"/utf8>> => [#{
                    <<"type"/utf8>> => <<"text"/utf8>>,
                    <<"text"/utf8>> => Content
                }],
                <<"isError"/utf8>> => true
            })
    end;

handleRequest(Id, #{<<"method"/utf8>> := <<"ping"/utf8>>}) ->
    jsonResponse(Id, #{});

handleRequest(Id, _Req) ->
    emitError(Id, -32601, <<"Method not found"/utf8>>).

%%%===================================================================
%%% Notification Handlers (no response)
%%%===================================================================

handleNotification(#{<<"method"/utf8>> := <<"notifications/initialized"/utf8>>}) ->
    ok;
handleNotification(_) ->
    ok.

%%%===================================================================
%%% Tool Execution
%%%===================================================================

%% 以只读策略安全执行工具（ask 模式，拒绝写操作与高风险执行）。
safeExecute(ToolName, Args) ->
    ToolAtom = list_to_atom(ToolName),
    Policy = alPolicy:defaultPolicy(),
    SessionId = <<"mcp-server"/utf8>>,
    Config = #{policy => Policy, mode => ask, projectRoot => <<"."/utf8>>},
    case alTools:execute(ToolAtom, normalizeArgs(Args), Config, SessionId) of
        {ok, Data} ->
            {ok, Data};
        {pending, _} ->
            %% 写操作被拦截：返回错误而非挂起
            {error, <<"Tool requires confirmation; only read-only tools are available via MCP"/utf8>>};
        {error, Reason} ->
            {error, Reason}
    end.

%% 将 binary key 的 args map 转为 atom key map（ali 工具期望 atom key）。
normalizeArgs(Args) when is_map(Args) ->
    maps:fold(fun(K, V, Acc) ->
        AtomK = case K of
            K when is_binary(K) ->
                try binary_to_existing_atom(K, utf8)
                catch _:_ -> binary_to_atom(K, utf8)
                end;
            K -> K
        end,
        maps:put(AtomK, V, Acc)
    end, #{}, Args);
normalizeArgs(Args) ->
    Args.

%%%===================================================================
%%% Formatting
%%%===================================================================

toMcpTool(#{<<"type"/utf8>> := <<"function"/utf8>>, <<"function"/utf8>> := Fun}) ->
    #{
        <<"name"/utf8>> => maps:get(<<"name"/utf8>>, Fun, <<>>),
        <<"description"/utf8>> => maps:get(<<"description"/utf8>>, Fun, <<>>),
        <<"inputSchema"/utf8>> => maps:get(<<"parameters"/utf8>>, Fun, #{})
    };
toMcpTool(_) ->
    #{}.

formatToolResult(Data) when is_map(Data) ->
    llmJson:encode(maps:without([elapsedMs], Data));
formatToolResult(Data) ->
    unicode:characters_to_binary(io_lib:format("~p", [Data])).

formatToolError(Reason) ->
    case Reason of
        R when is_binary(R) -> R;
        R -> unicode:characters_to_binary(io_lib:format("~p", [R]))
    end.

%%%===================================================================
%%% JSON-RPC Response Helpers
%%%===================================================================

jsonResponse(Id, Result) ->
    #{
        <<"jsonrpc"/utf8>> => <<"2.0"/utf8>>,
        <<"id"/utf8>> => Id,
        <<"result"/utf8>> => Result
    }.

emitResponse(Map) ->
    Json = llmJson:encode(Map),
    io:fwrite(standard_io, "~s~n", [Json]).

emitError(Id, Code, Message) ->
    Error = #{
        <<"jsonrpc"/utf8>> => <<"2.0"/utf8>>,
        <<"id"/utf8>> => Id,
        <<"error"/utf8>> => #{
            <<"code"/utf8>> => Code,
            <<"message"/utf8>> => Message
        }
    },
    emitResponse(Error).
