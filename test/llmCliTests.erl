%%%-------------------------------------------------------------------
%%% @doc LLM ???? JSON ??? EUnit ????
%%%
%%% ???? schema ??? Unicode ??
%%% JSON ? Agent ??????
%%% @end
%%%-------------------------------------------------------------------
-module(llmCliTests).

-include_lib("eunit/include/eunit.hrl").

%% tool ???? role?tool_call_id ??
messageFormat_test() ->
    Msg = llmCli:toolMessage(<<"call-1"/utf8>>, <<"{\"ok\":true}"/utf8>>),
    #{role := tool, tool_call_id := <<"call-1"/utf8>>} = Msg.

%% assistant tool_calls ?? calls ??
assistantToolCalls_test() ->
    Calls = [#{<<"id"/utf8>> => <<"1"/utf8>>, <<"type"/utf8>> => <<"function"/utf8>>}],
    #{role := assistant, tool_calls := Calls} = llmCli:assistantToolCallsMessage(Calls).

%% OpenAI tools schema ???????
openAiTools_test() ->
    Tools = alTools:openAiTools(),
    ?assert(length(Tools) >= 28),
    [#{<<"type"/utf8>> := <<"function"/utf8>>, <<"function"/utf8>> := #{<<"name"/utf8>> := Name}} | _] = Tools,
    ?assert(is_binary(Name)).

%% ?? listFiles ?? .erl ??
listFilesRecursive_test() ->
    {ok, #{count := Count}} =
        alToolProject:listFiles(#{pattern => <<"*.erl"/utf8>>, recursive => true}, #{}),
    ?assert(Count >= 1).

%% ?? prompt ??? UTF-8 ??
unicodePrompt_test() ->
    Msg = llmCli:userMessage("??"),
    #{content := Content} = Msg,
    ?assertEqual(unicode:characters_to_binary("??"), Content).

%% ?? + ???? OpenAI content parts
userMessageAttachments_test() ->
    File = #{
        <<"name"/utf8>> => <<"demo.erl"/utf8>>,
        <<"data"/utf8>> => <<"-module(demo).\n"/utf8>>
    },
    Image = #{
        <<"mediaType"/utf8>> => <<"image/png"/utf8>>,
        <<"data"/utf8>> => <<"aGVsbG8="/utf8>>
    },
    Pdf = #{
        <<"name"/utf8>> => <<"spec.pdf"/utf8>>,
        <<"mediaType"/utf8>> => <<"application/pdf"/utf8>>,
        <<"data"/utf8>> => <<"JVBERi0="/utf8>>
    },
    Msg = llmCli:userMessage(<<"????"/utf8>>, #{
        files => [File], images => [Image], documents => [Pdf]
    }),
    #{content := Parts} = Msg,
    ?assert(llmCli:isContentParts(Parts)),
    ?assertEqual(4, length(Parts)),
    ?assert(lists:any(fun(#{<<"type"/utf8>> := T}) -> T =:= <<"file"/utf8>> end, Parts)).

attachmentsParse_pdf_test() ->
    Body = #{
        <<"documents"/utf8>> => [
            #{<<"name"/utf8>> => <<"a.pdf"/utf8>>,
              <<"mediaType"/utf8>> => <<"application/pdf"/utf8>>,
              <<"data"/utf8>> => <<"JVBERi0xLjQK"/utf8>>}
        ]
    },
    {ok, #{documents := [_]}} = alAttachments:optsFromBody(Body).

%% ?? content ? token ???????
estimateContentTokens_test() ->
    Parts = [
        #{<<"type"/utf8>> => <<"text"/utf8>>, <<"text"/utf8>> => <<"hello world"/utf8>>},
        #{<<"type"/utf8>> => <<"image_url"/utf8>>,
          <<"image_url"/utf8>> => #{<<"url"/utf8>> => <<"data:image/png;base64,x"/utf8>>}}
    ],
    ?assert(llmCli:estimateContentTokens(Parts) >= 766).

%% Web ?? JSON ??
attachmentsParse_test() ->
    Body = #{
        <<"images"/utf8>> => [
            #{<<"mediaType"/utf8>> => <<"image/png"/utf8>>, <<"data"/utf8>> => <<"aGVsbG8="/utf8>>}
        ],
        <<"files"/utf8>> => [
            #{<<"name"/utf8>> => <<"a.erl"/utf8>>, <<"data"/utf8>> => <<"-module(a).\n"/utf8>>}
        ]
    },
    {ok, #{images := [_], files := [_]}} = alAttachments:optsFromBody(Body).

%% ??????? base64 ??
%% "-module(demo).\n" ? loose base64 ???????
attachmentsTextNotDecoded_test() ->
    ErlSource = <<"-module(demo).\n-export([f/0]).\nf() -> ok.\n"/utf8>>,
    Body = #{<<"files"/utf8>> => [
        #{<<"name"/utf8>> => <<"demo.erl"/utf8>>, <<"data"/utf8>> => ErlSource}
    ]},
    {ok, #{files := [#{<<"data"/utf8>> := Data}]}} = alAttachments:optsFromBody(Body),
    ?assertEqual(ErlSource, Data).

%% ?? encoding=base64 ?????
attachmentsTextBase64Explicit_test() ->
    Body = #{<<"files"/utf8>> => [
        #{<<"name"/utf8>> => <<"a.txt"/utf8>>,
          <<"data"/utf8>> => <<"aGVsbG8="/utf8>>,
          <<"encoding"/utf8>> => <<"base64"/utf8>>}
    ]},
    {ok, #{files := [#{<<"data"/utf8>> := Data}]}} = alAttachments:optsFromBody(Body),
    ?assertEqual(<<"hello">>, Data).

%% DeepSeek ????????? image_url parts
deepseekStripsImageParts_test() ->
    Msg = llmCli:userMessage(<<"??????"/utf8>>, #{
        images => [#{<<"mediaType"/utf8>> => <<"image/png"/utf8>>,
                     <<"data"/utf8>> => <<"aGVsbG8="/utf8>>}]
    }),
    Body = llmCli:buildRequestBody(
        <<"deepseek-v4-flash"/utf8>>, [Msg], [], false, deepseek
    ),
    [#{<<"role"/utf8>> := <<"user"/utf8>>, <<"content"/utf8>> := Content}] =
        maps:get(<<"messages"/utf8>>, Body),
    ?assert(llmCli:isContentParts(Content)),
    ?assertNot(lists:any(
        fun(P) -> maps:get(<<"type"/utf8>>, P, undefined) =:= <<"image_url"/utf8>> end,
        Content
    )),
    ?assert(lists:any(
        fun(P) -> maps:get(<<"type"/utf8>>, P, undefined) =:= <<"text"/utf8>> end,
        Content
    )),
    ?assertEqual(false, llmCli:supportsVision(deepseek, <<"deepseek-v4-flash"/utf8>>)),
    ?assertEqual(true, llmCli:supportsVision(openai, <<"gpt-4o-mini"/utf8>>)).

%% ????/??/?? ?????????
conversationHistoryDowngrade_test() ->
    UserMsg = llmCli:userMessage(<<"????"/utf8>>, #{
        images => [#{<<"mediaType"/utf8>> => <<"image/png"/utf8>>,
                     <<"data"/utf8>> => <<"aGVsbG8="/utf8>>}]
    }),
    AssistantMsg = llmCli:assistantMessage(<<"???????"/utf8>>),
    History = alContext:conversationHistory([UserMsg, AssistantMsg]),
    [SavedUser, _SavedAssistant] = History,
    #{content := SavedParts} = SavedUser,
    %% ?? part ?????????????? image_url
    ?assertNot(lists:any(fun(P) -> maps:get(<<"type"/utf8>>, P, undefined) =:= <<"image_url"/utf8>> end, SavedParts)),
    ?assert(lists:any(fun(P) -> maps:get(<<"text"/utf8>>, P, undefined) =:= <<"[?????]"/utf8>> end, SavedParts)).

coalesceSystemMessages_test() ->
    Msgs = [
        llmCli:systemMessage(<<"sys-a"/utf8>>),
        llmCli:systemMessage(<<"sys-b"/utf8>>),
        llmCli:userMessage(<<"hi"/utf8>>)
    ],
    [Sys, User] = llmCli:coalesceSystemMessages(Msgs),
    ?assertEqual(system, maps:get(role, Sys)),
    ?assertEqual(user, maps:get(role, User)),
    ?assertEqual(<<"sys-a\n\nsys-b"/utf8>>, maps:get(content, Sys)).

%% Web ?? API ???????
attachmentLimitsApi_test() ->
    Web = alConfig:web(),
    ?assert(maps:get(maxImageBytes, Web) >= 1048576),
    ?assert(is_list(maps:get(textFileExtensions, Web))),
    ?assert(length(maps:get(textFileExtensions, Web)) > 0).

%% ?? Web ????
publicWebConfig_test() ->
    C = alConfig:publicWebConfig(),
    ?assert(maps:is_key(attachmentLimits, C)),
    ?assert(maps:is_key(limits, C)),
    ?assertNot(maps:is_key(api_key, C)),
    ?assertNot(maps:is_key(webApiToken, C)),
    Web = maps:get(web, C),
    ?assert(maps:is_key(authEnabled, Web)),
    ?assertNot(maps:is_key(token, Web)).

%% JSON encode/decode ????
jsonRoundtrip_test() ->
    Payload = #{<<"ok"/utf8>> => true, <<"msg"/utf8>> => <<"??"/utf8>>},
    ?assertEqual(Payload, llmJson:decode(llmJson:encode(Payload))).

%% ? UTF-8 ??? encodeStrict
encodeStrict_invalidUtf8_test() ->
    Bad = #{<<"content"/utf8>> => <<16#FF, 16#FE, "ok"/utf8>>},
    {ok, Bin} = llmJson:encodeStrict(Bad),
    ?assert(byte_size(Bin) > 0).

%% text/1 ????? UTF-8
text_utf8_test() ->
    ?assertEqual(<<"??"/utf8>>, llmJson:text("??")),
    ?assertEqual(<<"ok"/utf8>>, llmJson:text(<<16#FF, 16#FE, "ok"/utf8>>)).

%% buildRequestBody ??? messages ?? encodeStrict
buildRequestBody_hasMessages_test() ->
    Tools = alTools:openAiTools(),
    Body = llmCli:buildRequestBody(
        <<"deepseek-v4-flash"/utf8>>,
        [llmCli:systemMessage(<<"sys"/utf8>>), llmCli:userMessage(<<"hi"/utf8>>)],
        [{tools, Tools}, {tool_choice, <<"auto"/utf8>>}, {temperature, 0.2}],
        true,
        deepseek
    ),
    ?assert(maps:is_key(<<"messages"/utf8>>, Body)),
    {ok, _} = llmJson:encodeStrict(Body).

%% ?????? MFA ???? JSON ??
toolResultEncode_test() ->
    Result = #{exports => [{start, 0}, {stop, 0}, {module_info, 0}]},
    Bin = llmJson:encode(#{ok => true, result => Result}),
    ?assert(byte_size(Bin) > 0),
    ?assert(binary:match(Bin, <<"start/0"/utf8>>) =/= nomatch).

%% erlang:memory/0 ????? JSON ??
memoryEncode_test() ->
    Bin = llmJson:encode(#{memory => erlang:memory()}),
    ?assert(byte_size(Bin) > 0).

%% application:loaded_applications/0 ????? JSON ??
loadedAppsEncode_test() ->
    Apps = application:loaded_applications(),
    Bin = llmJson:encode(#{applications => Apps}),
    ?assert(byte_size(Bin) > 0).

%% ? config/aliCfg.example.cfg ?? provider/model ??
configLoad_test() ->
    ok = alConfig:load("config/aliCfg.example.cfg"),
    {ok, deepseek} = llmCli:getConfig(provider),
    {ok, Model} = llmCli:getConfig(model),
    ?assert(is_binary(Model)).

%% formatAgentConfig ?? model ??
formatAgentConfig_test() ->
    ok = alConfig:load("config/aliCfg.example.cfg"),
    Bin = alConfig:formatAgentConfig(),
    ?assert(byte_size(Bin) > 0),
    ?assert(binary:match(Bin, <<"model:"/utf8>>) =/= nomatch).

%% agentConfig ?????????
agentConfigTool_test() ->
    ok = alConfig:load("config/aliCfg.example.cfg"),
    {ok, #{formatted := Fmt}} = alToolRuntime:agentConfig(#{}, #{}),
    ?assert(byte_size(Fmt) > 0).

%% ?? tool ??? trimHistorySafe ????
trimHistorySafe_test() ->
    Orphan = [
        llmCli:toolMessage(<<"id-1"/utf8>>, <<"{\"ok\":true}"/utf8>>),
        llmCli:assistantMessage(<<"answer"/utf8>>)
    ],
    Trimmed = alContext:trimHistorySafe(Orphan, 10),
    ?assertEqual([llmCli:assistantMessage(<<"answer"/utf8>>)], Trimmed).

%% ? token ??????????
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

%% nodeInfo ???????
nodeInfo_test() ->
    {ok, #{node := N}} = alToolRuntime:nodeInfo(#{}, #{}),
    ?assertEqual(node(), N).

charlistCfgStrings_test() ->
    Tmp = filename:join(
        filename:absname("_build"),
        "ali_cfg_test_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".cfg"
    ),
    Cfg = [
        "{provider, deepseek}.",
        "{api_key, \"sk-test\"}.",
        "{base_url, \"https://api.deepseek.com\"}.",
        "{model, \"deepseek-v4-flash\"}.",
        "{modelOptions, [{temperature, 0.2}]}."
    ],
    ok = file:write_file(Tmp, unicode:characters_to_binary(string:join(Cfg, "\n"))),
    ok = alConfig:load(Tmp),
    R = alConfig:resolvedLlm(),
    ?assertEqual(deepseek, maps:get(provider, R)),
    ?assert(is_binary(maps:get(base_url, R))),
    ?assert(is_binary(maps:get(model, R))),
    ?assert(is_binary(maps:get(api_key, R))),
    Agent = alConfig:getAgentConfig(),
    ?assertEqual([{temperature, 0.2}], maps:get(modelOptions, Agent)),
    ok = file:delete(Tmp).