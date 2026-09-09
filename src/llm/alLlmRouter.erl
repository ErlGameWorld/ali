%%%-------------------------------------------------------------------
%%% @doc 本地 + 云端多模型优先级链路由器。
%%%
%%% 职责：
%%% <ul>
%%%   <li><b>链构建</b>：读取 `llm.chain' 配置（链项 map 列表），按 priority
%%%       升序构建模型链；缺 baseUrl/model 的项自动剔除，本地 provider 允许
%%%       缺 apiKey（占位 none）。注意：`llm.models' 是 alLlmCatalog 的候选
%%%       模型名列表（字符串），与本段的 chain 语义不同。</li>
%%%   <li><b>任务分级</b>：simple / medium / complex 三级；任何分级都先从链首
%%%       （本地弱模型）尝试解答，答不好/没把握时再升级云端 —— 模拟人脑
%%%       “先自己试、试不动再请教”。</li>
%%%   <li><b>升级决策</b>：硬失败升级（重试耗尽换链上下一个）与质量升级
%%%       （规则筛可疑 + critic 抽查，由 alToolRouter 触发）。</li>
%%%   <li><b>经验路由</b>：升级事件沉淀为 kind=routingNote 的记忆（TTL + 模型指纹），
%%%       相似问题下次直接从更强的模型开始；换本地模型名后旧记录自动失效。</li>
%%% </ul>
%%%
%%% 配置示例（aliCfg.cfg 的 llm 段）：
%%%
%%% ```
%%% {llm, #{
%%%   chain => [
%%%     #{id => local, provider => ollama,
%%%       baseUrl => "http://127.0.0.1:11434/v1", model => "qwen3:14b",
%%%       priority => 1, roles => [main, aux],
%%%       maxRetries => 1, execTimeout => 60000},
%%%     #{id => cloud, provider => qwen,
%%%       baseUrl => "https://dashscope.aliyuncs.com/compatible-mode/v1",
%%%       model => "qwen3.8-max", apiKey => "${ENV:ALI_LLM_API_KEY}",
%%%       priority => 2, roles => [main, critic]}
%%%   ],
%%%   routing => #{ttlDays => 30, criticThreshold => 0.5}
%%% }}
%%% '''
%%%
%%% 未配置 chain 时链为空，全部调用走原有单模型路径（完全向后兼容）。
%%% 任意一项缺失时用另一项独跑：只配本地则全走本地，只配云端则全走云端。
%%% routingNote 不写入 kind=lesson，避免污染 alExperience 的项目经验召回。
%%% @end
%%%-------------------------------------------------------------------

-module(alLlmRouter).

-export([modelChain/0, chainEnabled/0, entryForRole/1, nextEntry/1,
         routeFor/2, resolveEntry/3, mergeEntryOpts/2, classifyTask/2,
         suspiciousReason/1, criticThreshold/0, noteLocalFailure/3,
         modelFingerprint/1, isLocalProvider/1, isLocalBaseUrl/1,
         questionFromMessages/1, applyCloudOverride/2, chainPublicInfo/0,
         chainDisplayIdentity/0, chainApiKey/0]).
%% Test exports — pure helpers
-export([normalizeEntries/1, entryValid/1, firstNonLocalEntry/0,
         routingCfg/0, ttlSeconds/0, refusalPatternHit/1,
         routingRowMatches/3, questionSimilar/2, tokenize/2,
         bypassFromFingerprints/2, cloudProviderBaseUrl/1]).

-define(DefaultTtlDays, 30).
-define(DefaultCriticThreshold, 0.5).
-define(MaxSymptomBytes, 200).
-define(ShortAnswerBytes, 240).
-define(RecentNoteWindowSecs, 86400).
-define(LocalProviders, [ollama, llamaCpp, llamacpp, vllm, lmstudio, lmStudio, janus, local]).

%%%===================================================================
%%% 模型链
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 构建模型链：读取 `llm.chain'（链项 map 列表），归一化后按
%% {priority, 配置顺序} 升序。缺 baseUrl/model 的项剔除；
%% 本地项 apiKey 缺省补 <<"none">>。
%%
%% @return 归一化后的模型项列表（可能为空）
%% @end
%%--------------------------------------------------------------------
-spec modelChain() -> [map()].
modelChain() ->
    Env = alConfig:get(llm, #{}),
    case maps:get(chain, Env, undefined) of
        List when is_list(List), List =/= [] ->
            normalizeEntries(List);
        _ ->
            []
    end.

%%--------------------------------------------------------------------
%% @doc 是否配置了模型链（未配置时全部走单模型路径）。
%% @end
%%--------------------------------------------------------------------
-spec chainEnabled() -> boolean().
chainEnabled() ->
    modelChain() =/= [].

%%--------------------------------------------------------------------
%% @doc
%% 归一化原始配置项列表：每项补齐 id/provider/apiKey/priority/roles 等
%% 字段并标注 local 标志；无效项（缺 baseUrl/model）剔除后按
%% {priority, 配置顺序} 稳定排序。
%%
%% @param RawEntries 原始配置项列表
%% @return 归一化后的有效项列表
%% @end
%%--------------------------------------------------------------------
-spec normalizeEntries(list()) -> [map()].
normalizeEntries(RawEntries) ->
    Indexed = lists:zip(lists:seq(1, length(RawEntries)), RawEntries),
    Normalized = [normalizeEntry(Index, Raw)
                  || {Index, Raw} <- Indexed, is_map(Raw)],
    Valid = [Entry || Entry <- Normalized, entryValid(Entry)],
    lists:sort(fun(EntryA, EntryB) ->
        SortA = {maps:get(priority, EntryA), maps:get(order, EntryA)},
        SortB = {maps:get(priority, EntryB), maps:get(order, EntryB)},
        SortA =< SortB
    end, Valid).

normalizeEntry(Order, Raw) ->
    Id = toBinary(firstDefined([
        maps:get(id, Raw, maps:get(<<"id">>, Raw, undefined)),
        integer_to_binary(Order)
    ])),
    Provider = toAtom(firstDefined([
        maps:get(provider, Raw, maps:get(<<"provider">>, Raw, undefined))
    ])),
    BaseUrl = toBinary(firstDefined([
        maps:get(baseUrl, Raw, maps:get(<<"baseUrl">>, Raw, undefined))
    ])),
    Model = toBinary(firstDefined([
        maps:get(model, Raw, maps:get(<<"model">>, Raw, undefined))
    ])),
    Local = maps:get(local, Raw, maps:get(<<"local">>, Raw, false)) =:= true
        orelse isLocalProvider(Provider)
        orelse isLocalBaseUrl(BaseUrl),
    ApiKey0 = firstDefined([
        maps:get(apiKey, Raw, maps:get(<<"apiKey">>, Raw, undefined))
    ]),
    ApiKey = case isEmptyish(ApiKey0) of
        true when Local -> <<"none">>;
        true -> undefined;
        false -> toBinary(ApiKey0)
    end,
    Priority = case maps:get(priority, Raw, maps:get(<<"priority">>, Raw, undefined)) of
        N when is_integer(N), N > 0 -> N;
        _ -> Order
    end,
    Roles = normalizeRoles(firstDefined([
        maps:get(roles, Raw, maps:get(<<"roles">>, Raw, undefined))
    ])),
    #{
        id => Id,
        order => Order,
        provider => Provider,
        apiKey => ApiKey,
        baseUrl => BaseUrl,
        model => Model,
        priority => Priority,
        roles => Roles,
        local => Local,
        maxRetries => firstDefined([
            maps:get(maxRetries, Raw, maps:get(<<"maxRetries">>, Raw, undefined))
        ]),
        execTimeout => firstDefined([
            maps:get(execTimeout, Raw, maps:get(<<"execTimeout">>, Raw, undefined))
        ]),
        extra => extraOpts(Raw)
    }.

%% 链项额外字段（白名单）：随链项透传给 LLM 调用（如本地小模型禁
%% thinking、指定 vision 策略）。mergeEntryOpts 时覆盖 Base 同名字段。
extraOpts(Raw) ->
    Keys = [thinking, vision, fastModel, temperature, topP, maxTokens,
            allowThinking, presencePenalty, frequencyPenalty],
    maps:from_list([{K, V} || K <- Keys,
                              V <- [firstDefined([maps:get(K, Raw, undefined),
                                                  maps:get(binKey(K), Raw, undefined)])],
                              V =/= undefined]).

binKey(thinking) -> <<"thinking">>;
binKey(vision) -> <<"vision">>;
binKey(fastModel) -> <<"fastModel">>;
binKey(temperature) -> <<"temperature">>;
binKey(topP) -> <<"topP">>;
binKey(maxTokens) -> <<"maxTokens">>;
binKey(allowThinking) -> <<"allowThinking">>;
binKey(presencePenalty) -> <<"presencePenalty">>;
binKey(frequencyPenalty) -> <<"frequencyPenalty">>;
binKey(_) -> undefined.

%% 有效项：baseUrl 与 model 非空；非本地项还要求 apiKey 已配置。
entryValid(#{baseUrl := BaseUrl, model := Model, local := Local, apiKey := ApiKey}) ->
    BaseOk = BaseUrl =/= <<>> andalso Model =/= <<>>,
    KeyOk = Local orelse (ApiKey =/= undefined andalso ApiKey =/= <<>>),
    BaseOk andalso KeyOk;
entryValid(_) ->
    false.

normalizeRoles(undefined) -> [main];
normalizeRoles(Roles) when is_list(Roles) ->
    Parsed = [toAtom(R) || R <- Roles],
    case [R || R <- Parsed, R =/= undefined] of
        [] -> [main];
        List -> List
    end;
normalizeRoles(Role) ->
    case toAtom(Role) of
        undefined -> [main];
        Atom -> [Atom]
    end.

%%--------------------------------------------------------------------
%% @doc
%% 取承担指定角色的首个链项（priority 最小者优先）。
%% 无任何项声明该角色时回退到链首。
%%
%% @param Role 角色原子（main | aux | critic | ...）
%% @return `{ok, Entry}' | `undefined'（链为空）
%% @end
%%--------------------------------------------------------------------
-spec entryForRole(atom()) -> {ok, map()} | undefined.
entryForRole(Role) ->
    Chain = modelChain(),
    case Chain of
        [] -> undefined;
        _ ->
            Matched = [Entry || Entry <- Chain,
                                lists:member(Role, maps:get(roles, Entry, [main]))],
            case Matched of
                [Entry | _] -> {ok, Entry};
                [] -> {ok, hd(Chain)}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 取链上指定 id 的下一个模型项（升级目标）。
%%
%% @param EntryId 模型项 id（atom 或 binary）
%% @return `{ok, NextEntry}' | `none'（已是链尾或未命中）
%% @end
%%--------------------------------------------------------------------
-spec nextEntry(term()) -> {ok, map()} | none.
nextEntry(EntryId) ->
    nextAfter(modelChain(), toBinary(EntryId)).

nextAfter([], _Id) -> none;
nextAfter([Entry | Rest], Id) ->
    case maps:get(id, Entry) =:= Id of
        true ->
            case Rest of
                [] -> none;
                [Next | _] -> {ok, Next}
            end;
        false ->
            nextAfter(Rest, Id)
    end.

%%--------------------------------------------------------------------
%% @doc 链上第一个非本地（云端）项；全部为本地时返回 none。
%% @end
%%--------------------------------------------------------------------
-spec firstNonLocalEntry() -> {ok, map()} | none.
firstNonLocalEntry() ->
    case [Entry || Entry <- modelChain(), not maps:get(local, Entry, false)] of
        [Entry | _] -> {ok, Entry};
        [] -> none
    end.

%%%===================================================================
%%% 路由决策
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 会话级路由入口（alToolRouter 每次问答调用一次）：
%%% 先查经验路由（本地失败史命中 → 直接从下一个模型开始），
%%% 再按任务分级决策起始模型。任何分级都先从链首（本地）尝试。
%%
%% @param Question 用户问题
%% @param HasTools 本次问答是否启用工具循环
%% @return `{ok, Entry, Info}' | `disabled'（链未配置）
%% @end
%%--------------------------------------------------------------------
-spec routeFor(binary(), boolean()) -> {ok, map(), map()} | disabled.
routeFor(Question, HasTools) ->
    case chainEnabled() of
        false -> disabled;
        true ->
            case routingEnabled() andalso recallEscalationBypass(Question) of
                {ok, Entry} ->
                    {ok, Entry, #{reason => experience}};
                _ ->
                    Grade = classifyText(toBinary(Question), HasTools),
                    {ok, gradedStart(Grade), #{grade => Grade}}
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 单次调用级路由入口（alLlmClient 每次调用调用一次）：
%%% Opts.modelEntry 已 pin 时直接使用（会话路由/升级结果）；
%%% Opts.llmPin=true 时禁用链路由（子代理等需完全固定单模型时）；
%%% Opts.llmOverride 在链启用时仅覆盖云端链项，本地仍走 chain 路由规则；
%%% Opts.llmRole 指定时按角色取（aux 廉价任务 / critic 复审）；
%%% 否则按任务分级决策。
%%
%% @param Messages 消息列表
%% @param Tools   工具规格列表
%% @param Opts    调用选项
%% @return `{ok, Entry}' | `disabled'
%% @end
%%--------------------------------------------------------------------
-spec resolveEntry([map()], [map()], map()) -> {ok, map()} | disabled.
resolveEntry(Messages, Tools, Opts) ->
    case chainEnabled() of
        false -> disabled;
        true ->
            case maps:get(modelEntry, Opts, undefined) of
                Entry when is_map(Entry) -> {ok, Entry};
                _ ->
                    case maps:get(llmPin, Opts, false) of
                        true -> disabled;
                        _ ->
                            case maps:get(llmRole, Opts, undefined) of
                                Role when Role =/= undefined -> entryForRole(Role);
                                _ ->
                                    Grade = classifyTask(Messages, Tools),
                                    {ok, gradedStart(Grade)}
                            end
                    end
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% 从消息列表提取用户问题文本（最后一条 user 消息），供硬失败升级时
%%% 记录 routingNote 使用。
%%
%% @param Messages 消息列表
%% @return 问题文本 binary（无 user 消息时为 <<>>）
%% @end
%%--------------------------------------------------------------------
-spec questionFromMessages([map()]) -> binary().
questionFromMessages(Messages) ->
    lastUserText(Messages).

gradedStart(_Grade) ->
    %% 模拟人脑：任何问题都先从链首（通常是本地弱模型）尝试解答，
    %% 不再因 complex 直上云端；答不好/没把握时由质量升级兜底换云。
    hd(modelChain()).

%%--------------------------------------------------------------------
%% @doc
%% 任务分级（消息列表形式）：
%%% - complex：命中代码/调试关键词，或最后一条用户消息 >= 480 字节
%%% - simple：无工具 + 消息 < 120 字节 + 无代码关键词
%%% - medium：其余
%%
%% @param Messages 消息列表
%% @param Tools   工具规格列表
%% @return simple | medium | complex
%% @end
%%--------------------------------------------------------------------
-spec classifyTask([map()], [map()]) -> simple | medium | complex.
classifyTask(Messages, Tools) ->
    HasTools = is_list(Tools) andalso Tools =/= [],
    classifyText(lastUserText(Messages), HasTools).

classifyText(Text, HasTools) ->
    case Text of
        <<>> -> medium;
        _ ->
            case hasCodeKeywords(Text) orelse byte_size(Text) >= 480 of
                true -> complex;
                false ->
                    case (not HasTools) andalso byte_size(Text) < 120 of
                        true -> simple;
                        false -> medium
                    end
            end
    end.

%% 提取消息列表中最后一条 user 消息的文本内容。
lastUserText(Messages) when is_list(Messages) ->
    case lists:foldl(fun
        (#{role := user, content := Content}, _Acc) ->
            contentToText(Content);
        (_, Acc) ->
            Acc
    end, <<>>, Messages) of
        Text when is_binary(Text) -> Text;
        _ -> <<>>
    end;
lastUserText(_) ->
    <<>>.

contentToText(Content) when is_binary(Content) -> Content;
contentToText(Content) when is_list(Content) ->
    try unicode:characters_to_binary(Content) catch _:_ -> <<>> end;
contentToText(Content) when is_map(Content) ->
    case maps:get(text, Content, undefined) of
        Text when is_binary(Text) -> Text;
        _ -> <<>>
    end;
contentToText(_) ->
    <<>>.

%% 代码/调试相关关键词（中英文）。与 alLlmClient 保持一致的判定口径。
hasCodeKeywords(Text) ->
    Lower = string:lowercase(Text),
    Keywords = [<<"code">>, <<"function">>, <<"module">>, <<"error">>, <<"debug">>,
                <<"implement">>, <<"refactor">>, <<"patch">>, <<"search">>,
                <<"代码"/utf8>>, <<"函数"/utf8>>, <<"模块"/utf8>>, <<"错误"/utf8>>, <<"调试"/utf8>>,
                <<"实现"/utf8>>, <<"重构"/utf8>>, <<"搜索"/utf8>>, <<"分析"/utf8>>],
    lists:any(fun(K) -> binary:match(Lower, K) =/= nomatch end, Keywords).

%%--------------------------------------------------------------------
%% @doc
%% 把链项字段合并进调用 Opts（provider/apiKey/baseUrl/model +
%%% 项级 maxRetries / execTimeout / extra 白名单字段覆盖）。
%%
%% @param Entry 链项
%% @param Opts  调用选项
%% @return 合并后的 Opts
%% @end
%%--------------------------------------------------------------------
-spec mergeEntryOpts(map(), map()) -> map().
mergeEntryOpts(Entry, Opts) when is_map(Entry), is_map(Opts) ->
    Opts1 = Opts#{
        provider => maps:get(provider, Entry, undefined),
        apiKey => maps:get(apiKey, Entry, undefined),
        baseUrl => maps:get(baseUrl, Entry, undefined),
        model => maps:get(model, Entry, undefined)
    },
    Opts2 = case maps:get(maxRetries, Entry, undefined) of
        undefined -> Opts1;
        N when is_integer(N), N >= 0 -> Opts1#{llmMaxRetries => N};
        _ -> Opts1
    end,
    Opts3 = case maps:get(execTimeout, Entry, undefined) of
        T when is_integer(T), T > 0 ->
            Opts2#{execTimeout => T, llmTimeout => T};
        _ ->
            Opts2
    end,
    case maps:get(extra, Entry, #{}) of
        Extra when is_map(Extra), map_size(Extra) > 0 ->
            %% extra 覆盖 Base 同名字段（链项配置优先于全局 llm 段）。
            %% 例外：调用方本调用把 thinking/allowThinking **收紧**为关时
            %% 以调用方为准——工具轮强制 thinking=>disabled 不能被链项
            %% extra（thinking=>enabled）覆盖回去，否则强制关思考永不生效。
            Merged = maps:merge(Opts3, Extra),
            maps:merge(Merged, restrictThinkingOpts(Opts));
        _ ->
            Opts3
    end.

%% 提取调用方对 thinking 的「收紧」设置（仅 disabled/false 生效）。
restrictThinkingOpts(Opts) ->
    maps:filter(fun
        (thinking, V) -> V =:= disabled orelse V =:= false;
        (allowThinking, V) -> V =:= false;
        (_, _) -> false
    end, Opts).

%%--------------------------------------------------------------------
%% @doc
%% 链启用时，Web llmOverride 仅覆盖非本地（云端）链项的 provider/model/apiKey；
%% 本地链项或未配链时原样返回 Entry。
%%
%% @param Entry    链项
%% @param Override 会话级 override（provider/model/apiKey）
%% @return  patched Entry
%% @end
%%--------------------------------------------------------------------
-spec applyCloudOverride(map(), map() | undefined) -> map().
applyCloudOverride(Entry, _Override) when not is_map(Entry) ->
    Entry;
applyCloudOverride(Entry, undefined) ->
    Entry;
applyCloudOverride(Entry, Override) when is_map(Override) ->
    case chainEnabled() andalso maps:get(local, Entry, false) =:= false of
        false ->
            Entry;
        true ->
            patchCloudEntry(Entry, Override)
    end.

patchCloudEntry(Entry, Override) ->
    Patched = lists:foldl(fun(Key, Acc) ->
        case maps:get(Key, Override, undefined) of
            undefined -> Acc;
            Val when Key =:= provider ->
                Acc#{provider => Val, baseUrl => cloudProviderBaseUrl(Val, Acc)};
            Val when Key =:= model ->
                Acc#{model => toBinary(Val)};
            Val when Key =:= apiKey ->
                Acc#{apiKey => toBinary(Val)};
            _ ->
                Acc
        end
    end, Entry, [provider, model, apiKey]),
    Patched.

cloudProviderBaseUrl(Provider, Entry) ->
    case cloudProviderBaseUrl(Provider) of
        undefined ->
            maps:get(baseUrl, Entry, <<>>);
        Url ->
            Url
    end.

-spec cloudProviderBaseUrl(atom() | binary()) -> binary() | undefined.
cloudProviderBaseUrl(Provider) when is_atom(Provider) ->
    cloudProviderBaseUrl(atom_to_binary(Provider, utf8));
cloudProviderBaseUrl(Provider) when is_binary(Provider) ->
    case string:lowercase(Provider) of
        <<"deepseek">> -> <<"https://api.deepseek.com">>;
        <<"qwen">> -> <<"https://dashscope.aliyuncs.com/compatible-mode/v1">>;
        <<"dashscope">> -> <<"https://dashscope.aliyuncs.com/compatible-mode/v1">>;
        <<"openai">> -> <<"https://api.openai.com/v1">>;
        <<"anthropic">> -> <<"https://api.anthropic.com">>;
        _ -> undefined
    end;
cloudProviderBaseUrl(_) ->
    undefined.

%%--------------------------------------------------------------------
%% @doc 供 Web 展示：链是否启用、本地/云端链项摘要（不含 apiKey）。
%% @end
%%--------------------------------------------------------------------
-spec chainPublicInfo() -> map().
chainPublicInfo() ->
    Chain = modelChain(),
    Local = [summaryEntry(E) || E <- Chain, maps:get(local, E, false)],
    Cloud = [summaryEntry(E) || E <- Chain, not maps:get(local, E, false)],
    #{
        enabled => Chain =/= [],
        local => firstOrNull(Local),
        cloud => firstOrNull(Cloud)
    }.

summaryEntry(Entry) ->
    #{
        id => maps:get(id, Entry, <<>>),
        provider => maps:get(provider, Entry, undefined),
        model => maps:get(model, Entry, <<>>)
    }.

firstOrNull([]) -> null;
firstOrNull([H | _]) -> H.

%%--------------------------------------------------------------------
%% @doc 链上用于展示/embedding inherit 的主身份：优先云端项，否则链首。
%% @end
%%--------------------------------------------------------------------
-spec chainDisplayIdentity() -> map().
chainDisplayIdentity() ->
    Entry = case firstNonLocalEntry() of
        {ok, Cloud} -> Cloud;
        none ->
            case modelChain() of
                [Head | _] -> Head;
                [] -> undefined
            end
    end,
    case Entry of
        undefined -> #{};
        E ->
            #{
                provider => maps:get(provider, E, undefined),
                model => maps:get(model, E, undefined),
                apiKey => maps:get(apiKey, E, undefined)
            }
    end.

%%--------------------------------------------------------------------
%% @doc 供 embedding/rerank `inherit` 使用的 API Key（优先云端链项）。
%% @end
%%--------------------------------------------------------------------
-spec chainApiKey() -> binary() | undefined.
chainApiKey() ->
    case maps:get(apiKey, chainDisplayIdentity(), undefined) of
        K when is_binary(K), K =/= <<>> -> K;
        _ -> undefined
    end.

%%%===================================================================
%%% 质量升级判定
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 规则筛可疑答案：空答案，或短答案（<= 240 字节）命中拒答模式。
%%% 可疑答案再交 critic 抽查（由 alToolRouter 触发），避免误杀。
%%
%% @param Answer 最终答案（binary 或含 content 的 map）
%% @return `ok' | `{reason, emptyAnswer | refusal}'
%% @end
%%--------------------------------------------------------------------
-spec suspiciousReason(term()) -> ok | {reason, atom()}.
suspiciousReason(Answer) ->
    Bin = answerToBinary(Answer),
    Trimmed = string:trim(Bin),
    case Trimmed of
        <<>> ->
            {reason, emptyAnswer};
        _ ->
            case byte_size(Trimmed) =< ?ShortAnswerBytes
                andalso refusalPatternHit(Trimmed) of
                true -> {reason, refusal};
                false -> ok
            end
    end.

answerToBinary(Answer) when is_binary(Answer) -> Answer;
answerToBinary(Answer) when is_map(Answer) ->
    toBinary(firstDefined([maps:get(content, Answer, undefined),
                           maps:get(answer, Answer, undefined)]));
answerToBinary(Answer) ->
    toBinary(Answer).

%% 短答案内的拒答模式命中（小写化后匹配；中文不受 lowercase 影响）。
refusalPatternHit(Text) ->
    Lower = string:lowercase(toBinary(Text)),
    lists:any(fun(Pattern) -> binary:match(Lower, Pattern) =/= nomatch end,
              refusalPatterns()).

refusalPatterns() ->
    [
        <<"无法回答"/utf8>>, <<"无法确定"/utf8>>, <<"我不知道"/utf8>>,
        <<"无法解决"/utf8>>, <<"没有相关信息"/utf8>>, <<"抱歉，"/utf8>>,
        <<"对不起，"/utf8>>, <<"作为一个小模型"/utf8>>, <<"作为本地模型"/utf8>>,
        <<"超出我的能力"/utf8>>, <<"超出能力范围"/utf8>>, <<"能力有限"/utf8>>,
        <<"我无法处理"/utf8>>, <<"我处理不了"/utf8>>, <<"我不会"/utf8>>,
        <<"需要更强大的模型"/utf8>>, <<"需要更强的模型"/utf8>>,
        <<"我无法胜任"/utf8>>, <<"超过我的知识范围"/utf8>>,
        <<"cannot answer">>, <<"i don't know">>, <<"i don't know how">>,
        <<"unable to answer">>, <<"i am unable">>, <<"i'm unable">>,
        <<"no idea">>, <<"beyond my">>, <<"out of my">>
    ].

%%--------------------------------------------------------------------
%% @doc 质量升级的 critic 打分阈值（llm.routing.criticThreshold，默认 0.5）。
%% @end
%%--------------------------------------------------------------------
-spec criticThreshold() -> float().
criticThreshold() ->
    case maps:get(criticThreshold, routingCfg(), ?DefaultCriticThreshold) of
        Threshold when is_number(Threshold) -> Threshold;
        _ -> ?DefaultCriticThreshold
    end.

%%%===================================================================
%%% 经验路由（routingNote 记忆）
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 记录「某模型未能处理该问题」的路由记忆（kind=routingNote）。
%%% 24 小时内同问题 + 同模型不重复记录；写库失败静默忽略。
%% 下次相似问题将直接从下一个模型开始（见 routeFor/2）。
%%
%% @param Question 用户问题
%% @param Entry    失败的链项
%% @param Reason   失败原因（硬失败错误或 {quality, Why}）
%% @return ok
%% @end
%%--------------------------------------------------------------------
-spec noteLocalFailure(binary(), map(), term()) -> ok.
noteLocalFailure(Question, Entry, Reason) ->
    try
        case routingEnabled() of
            false -> ok;
            true ->
                Q = toBinary(Question),
                case Q of
                    <<>> -> ok;
                    _ -> maybeWriteRoutingNote(Q, Entry, Reason)
                end
        end
    catch
        _:_ -> ok
    end.

maybeWriteRoutingNote(Question, Entry, Reason) ->
    Fingerprint = modelFingerprint(Entry),
    Now = os:system_time(second),
    case recentRoutingNote(Question, Fingerprint, Now) of
        true -> ok;
        false ->
            Symptom = truncateBinary(Question, ?MaxSymptomBytes),
            ReasonBin = reasonBinary(Reason),
            Card = iolist_to_binary([
                <<"模型升级记录："/utf8>>, Fingerprint,
                <<" 未能处理该问题，已升级更强模型。问题："/utf8>>, Symptom,
                <<" 原因："/utf8>>, ReasonBin
            ]),
            _ = alMemory:remember(undefined, routingNote, Card, #{
                tags => [<<"llmRouting">>, <<"escalated">>],
                metadata => #{
                    routing => true,
                    modelFingerprint => Fingerprint,
                    outcome => failed,
                    symptom => Symptom,
                    reason => ReasonBin,
                    recordedAt => Now
                },
                scope => project
            }),
            ok
    end.

%% 24 小时内同问题 + 同模型指纹已有记录则跳过（防重复刷屏）。
recentRoutingNote(Question, Fingerprint, Now) ->
    lists:any(fun(Row) ->
        case routingRowMatches(Row, Now, Question) of
            {true, RowFp} ->
                RowFp =:= Fingerprint
                    andalso (Now - rowCreatedAt(Row)) =< ?RecentNoteWindowSecs;
            false ->
                false
        end
    end, fetchRoutingRows()).

%%--------------------------------------------------------------------
%% @doc
%% 经验路由查询：近期（TTL 内）相似问题上有失败史的模型，
%%% 返回其链上下一个模型作为本次起始模型。
%%%
%%% @param Question 用户问题
%%% @return `{ok, Entry}' | `none'
%% @end
%%--------------------------------------------------------------------
-spec recallEscalationBypass(binary()) -> {ok, map()} | none.
recallEscalationBypass(Question) ->
    case routingEnabled() of
        false -> none;
        true ->
            Q = toBinary(Question),
            case Q of
                <<>> -> none;
                _ ->
                    Rows = fetchRoutingRows(),
                    Now = os:system_time(second),
                    Fingerprints = [Fingerprint
                                    || Row <- Rows,
                                       {true, Fingerprint} <- [routingRowMatches(Row, Now, Q)]],
                    bypassFromFingerprints(Fingerprints, modelChain())
            end
    end.

fetchRoutingRows() ->
    try alMemory:list(#{kind => routingNote, tag => <<"llmRouting">>, limit => 20}) of
        {ok, Rows} when is_list(Rows) -> Rows;
        _ -> []
    catch
        _:_ -> []
    end.

%%--------------------------------------------------------------------
%% @doc
%% 纯函数：给定失败指纹集合与模型链，返回应起始的模型
%%% （被失败覆盖的最靠后链项的下一个）。
%%%
%%% @param Fingerprints 失败模型指纹集合
%%% @param Chain        模型链
%%% @return `{ok, Entry}' | `none'
%% @end
%%--------------------------------------------------------------------
-spec bypassFromFingerprints([binary()], [map()]) -> {ok, map()} | none.
bypassFromFingerprints(Fingerprints, Chain) ->
    Failed = [Entry || Entry <- Chain,
                       lists:member(modelFingerprint(Entry), Fingerprints)],
    case Failed of
        [] -> none;
        _ ->
            Last = lists:last(Failed),
            nextAfter(Chain, maps:get(id, Last))
    end.

%%--------------------------------------------------------------------
%% @doc
%% 纯函数：判断一行记忆是否为有效的路由失败记录
%%% （routing 标记 + TTL 内 + 带模型指纹；Question 非空时还要求问题相似）。
%%%
%%% @param Row      记忆行（alMemory:list 返回形式）
%%% @param Now      当前 Unix 秒
%%% @param Question 用户问题（<<>> 表示跳过相似性检查）
%%% @return `{true, Fingerprint}' | `false'
%% @end
%%--------------------------------------------------------------------
-spec routingRowMatches(map(), integer(), binary()) -> {true, binary()} | false.
routingRowMatches(Row, Now, Question) ->
    case is_map(Row) of
        false -> false;
        true ->
            case routingRowValid(Row, Now) of
                {true, Fingerprint} ->
                    case Question of
                        <<>> -> {true, Fingerprint};
                        _ ->
                            case questionSimilar(Question, symptomOf(Row)) of
                                true -> {true, Fingerprint};
                                false -> false
                            end
                    end;
                false ->
                    false
            end
    end.

routingRowValid(Row, Now) ->
    Meta = rowMetadata(Row),
    Routing = is_map(Meta) andalso firstDefined([
        maps:get(routing, Meta, maps:get(<<"routing">>, Meta, false))
    ]) =:= true,
    case Routing of
        false -> false;
        true ->
            Created = rowCreatedAt(Row),
            case is_integer(Created) andalso Created > 0
                andalso (Now - Created) =< ttlSeconds() of
                false -> false;
                true ->
                    Fingerprint = firstDefined([
                        maps:get(modelFingerprint, Meta,
                                 maps:get(<<"modelFingerprint">>, Meta, undefined))
                    ]),
                    case toBinary(Fingerprint) of
                        <<>> -> false;
                        Fp -> {true, Fp}
                    end
            end
    end.

rowMetadata(Row) ->
    Meta0 = firstDefined([
        maps:get(metadata, Row, maps:get(<<"metadata">>, Row, undefined))
    ]),
    case Meta0 of
        Bin when is_binary(Bin) ->
            try alJson:decode(Bin) catch _:_ -> #{} end;
        Map when is_map(Map) -> Map;
        _ -> #{}
    end.

rowCreatedAt(Row) ->
    case firstDefined([
        maps:get(created_at, Row, maps:get(<<"created_at">>, Row, undefined))
    ]) of
        N when is_integer(N) -> N;
        Bin when is_binary(Bin) ->
            try binary_to_integer(Bin) catch _:_ -> 0 end;
        _ -> 0
    end.

symptomOf(Row) ->
    Meta = rowMetadata(Row),
    toBinary(firstDefined([
        maps:get(symptom, Meta, maps:get(<<"symptom">>, Meta, undefined)),
        maps:get(content, Row, maps:get(<<"content">>, Row, undefined))
    ])).

%%%===================================================================
%%% 工具函数
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc 模型指纹：`Provider:Model'。换模型名后指纹变化，旧失败史自动失效。
%% @end
%%--------------------------------------------------------------------
-spec modelFingerprint(map()) -> binary().
modelFingerprint(Entry) when is_map(Entry) ->
    Provider = toBinary(firstDefined([maps:get(provider, Entry, undefined)])),
    Model = toBinary(firstDefined([maps:get(model, Entry, undefined)])),
    <<Provider/binary, ":", Model/binary>>;
modelFingerprint(_) ->
    <<>>.

%%--------------------------------------------------------------------
%% @doc 是否为本地推理服务 provider（ollama / llama.cpp / vllm / lmstudio 等）。
%% @end
%%--------------------------------------------------------------------
-spec isLocalProvider(atom() | binary()) -> boolean().
isLocalProvider(Provider) when is_atom(Provider) ->
    lists:member(Provider, ?LocalProviders);
isLocalProvider(Provider) when is_binary(Provider) ->
    isLocalProvider(toAtom(Provider));
isLocalProvider(_) ->
    false.

%%--------------------------------------------------------------------
%% @doc
%% 是否为本地地址：取 URL 的 host[:port] 段判断
%%% （localhost / 127.* / 0.0.0.0 / [::1]，或 10. / 192.168. 前缀私网地址）。
%%% 私网前缀只作用于 host 段，避免 path/query 中的数字误命中。
%% @end
%%--------------------------------------------------------------------
-spec isLocalBaseUrl(binary() | string()) -> boolean().
isLocalBaseUrl(Url) ->
    HostPort = urlHostPort(string:lowercase(toBinary(Url))),
    binary:match(HostPort, <<"localhost">>) =/= nomatch
        orelse startsWith(HostPort, <<"127.">>)
        orelse startsWith(HostPort, <<"0.0.0.0">>)
        orelse startsWith(HostPort, <<"[::1]">>)
        orelse startsWith(HostPort, <<"10.">>)
        orelse startsWith(HostPort, <<"192.168.">>).

%% 取 URL 的 host[:port] 段：去掉 scheme（// 之前）与 path（首个 / 之后）。
urlHostPort(Url) ->
    NoScheme = case binary:split(Url, <<"//">>) of
        [_, Rest] -> Rest;
        [Rest] -> Rest
    end,
    hd(binary:split(NoScheme, <<"/">>)).

startsWith(Bin, Prefix) ->
    binary:longest_common_prefix([Bin, Prefix]) =:= byte_size(Prefix).

%%--------------------------------------------------------------------
%% @doc 路由配置段（llm.routing；缺省为空 map，各项取默认值）。
%% @end
%%--------------------------------------------------------------------
-spec routingCfg() -> map().
routingCfg() ->
    Env = alConfig:get(llm, #{}),
    case maps:get(routing, Env, undefined) of
        Cfg when is_map(Cfg) -> Cfg;
        _ -> #{}
    end.

routingEnabled() ->
    maps:get(enabled, routingCfg(), true) =/= false.

%%--------------------------------------------------------------------
%% @doc 失败史 TTL（llm.routing.ttlDays，默认 30 天）。
%% @end
%%--------------------------------------------------------------------
-spec ttlSeconds() -> non_neg_integer().
ttlSeconds() ->
    Days = case maps:get(ttlDays, routingCfg(), undefined) of
        N when is_integer(N), N > 0 -> N;
        _ -> ?DefaultTtlDays
    end,
    Days * 86400.

%%--------------------------------------------------------------------
%% @doc
%% 纯函数：两个问题文本是否相似（token 重叠 >= 2，
%%% 或共享一个 >= 8 字节的显著 token）。拉丁词 + 中文 bigram 混合切分。
%%
%% @param QuestionA 问题 A
%% @param QuestionB 问题 B
%% @return boolean()
%% @end
%%--------------------------------------------------------------------
-spec questionSimilar(binary(), binary()) -> boolean().
questionSimilar(QuestionA, QuestionB) ->
    TokensA = sets:from_list(tokenize(QuestionA, latin)),
    TokensB = sets:from_list(tokenize(QuestionB, latin)),
    Shared = sets:to_list(sets:intersection(TokensA, TokensB)),
    case length(Shared) >= 2 of
        true -> true;
        false ->
            lists:any(fun(Token) -> byte_size(Token) >= 8 end, Shared)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 纯函数：文本切分。拉丁字母数字词（>= 2 字符）原样保留，
%%% CJK 连续段切为 bigram（单字符段保留单字）。
%%
%% @param Text  文本
%% @param Unused 预留参数（保持签名稳定）
%% @return token 二进制列表
%% @end
%%--------------------------------------------------------------------
-spec tokenize(binary(), term()) -> [binary()].
tokenize(Text, _Unused) ->
    Bin = toBinary(Text),
    case Bin of
        <<>> -> [];
        _ ->
            Lower = string:lowercase(Bin),
            %% 两个独立正则各取整体匹配：交替分支中未参与的捕获组在
            %% re:run 返回里会被省略（尾部组）或置 <<>>（中部组），
            %% 按组位置解析不可靠，故不依赖捕获组。
            Latin = matchAll(Lower, <<"[a-z0-9]{2,}">>),
            CjkRuns = matchAll(Lower, <<"[\\x{4e00}-\\x{9fff}]+">>),
            Latin ++ lists:flatmap(fun cjkBigrams/1, CjkRuns)
    end.

matchAll(Subject, Pattern) ->
    case re:run(Subject, Pattern, [global, unicode, {capture, first, binary}]) of
        {match, Groups} -> [G || [G] <- Groups];
        nomatch -> []
    end.

cjkBigrams(Run) ->
    Chars = unicode:characters_to_list(Run),
    case length(Chars) of
        1 -> [Run];
        N ->
            [unicode:characters_to_binary(lists:sublist(Chars, Index, 2))
             || Index <- lists:seq(1, N - 1)]
    end.

reasonBinary(Reason) ->
    Bin = try iolist_to_binary(io_lib:format("~p", [Reason])) catch _:_ -> <<"unknown">> end,
    truncateBinary(Bin, 120).

truncateBinary(Bin, MaxBytes) ->
    case byte_size(Bin) =< MaxBytes of
        true -> Bin;
        false -> binary:part(Bin, 0, MaxBytes)
    end.

toBinary(Value) when is_binary(Value) -> Value;
toBinary(Value) when is_atom(Value) ->
    case Value of
        undefined -> <<>>;
        _ -> atom_to_binary(Value, utf8)
    end;
toBinary(Value) when is_list(Value) ->
    try unicode:characters_to_binary(Value) catch _:_ -> <<>> end;
toBinary(Value) when is_integer(Value) -> integer_to_binary(Value);
toBinary(_) -> <<>>.

toAtom(Value) when is_atom(Value) -> Value;
toAtom(Value) when is_binary(Value) ->
    try binary_to_existing_atom(Value, utf8)
    catch _:_ -> binary_to_atom(Value, utf8) end;
toAtom(Value) when is_list(Value) ->
    toAtom(unicode:characters_to_binary(Value));
toAtom(_) -> undefined.

isEmptyish(undefined) -> true;
isEmptyish(<<>>) -> true;
isEmptyish("") -> true;
isEmptyish(_) -> false.

firstDefined(Values) ->
    case lists:dropwhile(fun(V) -> V =:= undefined end, Values) of
        [V | _] -> V;
        [] -> undefined
    end.
