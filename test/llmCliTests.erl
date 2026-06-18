%%%-------------------------------------------------------------------
%%% @doc LLM 客户端与 JSON 编码 EUnit 测试套件。
%%%
%%% 覆盖消息格式、工具 schema、配置加载、Unicode 处理、
%%% JSON 往返及 Agent 上下文修剪等场景。
%%% @end
%%%-------------------------------------------------------------------
-module(llmCliTests).

-include_lib("eunit/include/eunit.hrl").

%% tool 消息应包含 role、tool_call_id 字段。
messageFormat_test() ->
    Msg = llmCli:toolMessage(<<"call-1"/utf8>>, <<"{\"ok\":true}"/utf8>>),
    #{role := tool, tool_call_id := <<"call-1"/utf8>>} = Msg.

%% assistant tool_calls 消息应保留 calls 列表。
assistantToolCalls_test() ->
    Calls = [#{<<"id"/utf8>> => <<"1"/utf8>>, <<"type"/utf8>> => <<"function"/utf8>>}],
    #{role := assistant, tool_calls := Calls} = llmCli:assistantToolCallsMessage(Calls).

%% OpenAI tools schema 应包含足够数量的函数定义。
openAiTools_test() ->
    Tools = alTools:openAiTools(),
    ?assert(length(Tools) >= 28),
    [#{<<"type"/utf8>> := <<"function"/utf8>>, <<"function"/utf8>> := #{<<"name"/utf8>> := Name}} | _] = Tools,
    ?assert(is_binary(Name)).

%% 递归 listFiles 应能找到 .erl 源文件。
listFilesRecursive_test() ->
    {ok, #{count := Count}} =
        alToolProject:listFiles(#{pattern => <<"*.erl"/utf8>>, recursive => true}, #{}),
    ?assert(Count >= 1).

%% 中文 prompt 应正确编码为 UTF-8 二进制。
unicodePrompt_test() ->
    Msg = llmCli:userMessage("你好"),
    #{content := Content} = Msg,
    ?assertEqual(unicode:characters_to_binary("你好"), Content).

%% JSON encode/decode 应无损往返。
jsonRoundtrip_test() ->
    Payload = #{<<"ok"/utf8>> => true, <<"msg"/utf8>> => <<"你好"/utf8>>},
    ?assertEqual(Payload, llmJson:decode(llmJson:encode(Payload))).

%% 工具结果中的 MFA 元组应编码为可读字符串。
toolResultEncode_test() ->
    Result = #{exports => [{start, 0}, {stop, 0}, {module_info, 0}]},
    Bin = llmJson:encode(#{ok => true, result => Result}),
    ?assert(byte_size(Bin) > 0),
    ?assert(binary:match(Bin, <<"start/0"/utf8>>) =/= nomatch).

%% erlang:memory/0 等不透明结构应能安全编码。
memoryEncode_test() ->
    Bin = llmJson:encode(#{memory => erlang:memory()}),
    ?assert(byte_size(Bin) > 0).

%% application:loaded_applications/0 结果应能 JSON 编码。
loadedAppsEncode_test() ->
    Apps = application:loaded_applications(),
    Bin = llmJson:encode(#{applications => Apps}),
    ?assert(byte_size(Bin) > 0).

%% 从 config/config.example.cfg 加载后 provider/model 应正确设置。
configLoad_test() ->
    ok = llmCliConfig:load("config/config.example.cfg"),
    {ok, deepseek} = llmCli:getConfig(provider),
    {ok, Model} = llmCli:getConfig(model),
    ?assert(is_binary(Model)).

%% formatAgentConfig 应输出含 model 字段的可读文本。
formatAgentConfig_test() ->
    ok = llmCliConfig:load("config/config.example.cfg"),
    Bin = llmCliConfig:formatAgentConfig(),
    ?assert(byte_size(Bin) > 0),
    ?assert(binary:match(Bin, <<"model:"/utf8>>) =/= nomatch).

%% agentConfig 工具应返回格式化后的配置文本。
agentConfigTool_test() ->
    ok = llmCliConfig:load("config/config.example.cfg"),
    {ok, #{formatted := Fmt}} = alToolRuntime:agentConfig(#{}, #{}),
    ?assert(byte_size(Fmt) > 0).

%% 孤立 tool 消息应在 trimHistorySafe 中被移除。
trimHistorySafe_test() ->
    Orphan = [
        llmCli:toolMessage(<<"id-1"/utf8>>, <<"{\"ok\":true}"/utf8>>),
        llmCli:assistantMessage(<<"answer"/utf8>>)
    ],
    Trimmed = alContext:trimHistorySafe(Orphan, 10),
    ?assertEqual([llmCli:assistantMessage(<<"answer"/utf8>>)], Trimmed).

%% 按 token 预算裁剪历史（保留最近消息）。
trimHistoryByTokens_test() ->
    History = [
        llmCli:userMessage(<<"a"/utf8>>),
        llmCli:assistantMessage(<<"b"/utf8>>),
        llmCli:userMessage(<<"c"/utf8>>),
        llmCli:assistantMessage(<<"d"/utf8>>)
    ],
    Trimmed = alContext:trimHistoryByTokens(History, 50),
    ?assert(length(Trimmed) >= 1),
    ?assert(length(Trimmed) =< length(History)).

%% nodeInfo 工具应返回当前节点名。
nodeInfo_test() ->
    {ok, #{node := N}} = alToolRuntime:nodeInfo(#{}, #{}),
    ?assertEqual(node(), N).