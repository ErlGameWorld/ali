%%%-------------------------------------------------------------------
%% @doc LLM token 用量跟踪，含 CJK 感知估算。
%%
%% 提供：
%% <ul>
%%   <li>{@link estimate/1} — 对文本缓冲区做 CJK 感知 token 估算
%%     （ASCII ≈ 4 字符/token，CJK ≈ 1.5 字符/token）。</li>
%%   <li>{@link estimateMessages/1} — 对消息列表求和。</li>
%%   <li>{@link track/3} — 按模型记录一次 API 调用的输入/输出 token
%%     （经 {@link estimate/1} 估算）。</li>
%%   <li>{@link trackUsage/2} — 从 provider 的 `usage' 对象记录
%%     （精确计数，不估算）。</li>
%%   <li>{@link stats/0} — 汇总总量 + 按模型分解 + 基于
%%     {@link pricing/0} 的预估 USD 费用。</li>
%%   <li>{@link reset/0} — 清空全部计数。</li>
%% </ul>
%%
%% 计数存放在公开 ETS 表（每模型一行），跨进程存活但不跨节点重启。
%% @end
%%%-------------------------------------------------------------------

-module(alTokenStats).

-export([
    estimate/1,
    estimateMessages/1,
    track/3,
    trackUsage/2,
    stats/0,
    reset/0,
    pricing/0,
    modelCost/3,
    ensureStarted/0
]).

-define(Table, alTokenStats).

%%%===================================================================
%%% Estimation
%%%===================================================================

%% @doc CJK-aware token estimate for a text buffer.
%% ASCII ≈ 4 chars/token, CJK and other wide chars ≈ 1.5 chars/token.
%% Falls back to byte_size/4 if the buffer is not valid UTF-8.
%% 中文：基于字符类型的 token 估算（ASCII ≈ 4 字符/token，CJK ≈ 1.5 字符/token）。
-spec estimate(binary() | string()) -> non_neg_integer().
estimate(Text) when is_binary(Text) ->
    case unicode:characters_to_list(Text) of
        L when is_list(L) -> estimateFromChars(L);
        _ -> max(0, round(byte_size(Text) / 4))
    end;
estimate(Text) when is_list(Text) ->
    try estimateFromChars(Text)
    catch _:_ -> max(0, round(length(Text) / 4))
    end;
estimate(_) ->
    0.

%%--------------------------------------------------------------------
%% @doc
%% 基于字符列表估算 token 数：分别统计 ASCII 与宽字符后按比例求和。
%%
%% @param Chars 字符列表
%% @return 非负整数 token 估算值
%% @end
%%--------------------------------------------------------------------
estimateFromChars(Chars) ->
    {Ascii, Wide} = lists:foldl(fun
        (C, {A, W}) when is_integer(C), C =< 127 -> {A + 1, W};
        (C, {A, W}) when is_integer(C) -> {A, W + 1};
        (_, Acc) -> Acc
    end, {0, 0}, Chars),
    max(0, round(Ascii / 4 + Wide / 1.5)).

%% @doc Estimate total tokens across a list of messages.
%% Recognises the `content' field as binary, list, or map (serialized
%% to JSON before estimation).
%% 中文：估算消息列表中所有 `content' 字段的 token 总数（支持 binary/list/map）。
-spec estimateMessages([map()]) -> non_neg_integer().
estimateMessages(Messages) when is_list(Messages) ->
    lists:foldl(fun(Msg, Acc) ->
        case maps:get(content, Msg, undefined) of
            undefined -> Acc;
            null -> Acc;
            V when is_binary(V) -> Acc + estimate(V);
            V when is_list(V) -> Acc + estimate(V);
            V when is_map(V) -> Acc + estimate(alJson:encode(V));
            _ -> Acc
        end
    end, 0, Messages);
estimateMessages(_) ->
    0.

%%%===================================================================
%%% Tracking
%%%===================================================================

%% @doc Record an API call's input/output tokens by estimating from the
%% raw request/response text. Prefer {@link trackUsage/2} when the
%% provider returns exact token counts.
%% 中文：通过估算请求/响应文本来记录 API 调用的 token 用量（精度不如 trackUsage/2）。
-spec track(binary(), binary() | string(), binary() | string()) -> ok.
track(Model, InputText, OutputText) ->
    ensureStarted(),
    ModelKey = toBinary(Model),
    InEst = estimate(InputText),
    OutEst = estimate(OutputText),
    updateRow(ModelKey, #{input_tokens => InEst, output_tokens => OutEst, apiCalls => 1}),
    ok.

%% @doc Record an API call using the provider's `usage' object.
%% Accepts either atom-keyed (`input_tokens', `output_tokens') or
%% binary-keyed (`<<"input_tokens">>') maps, with OpenAI-style
%% `prompt_tokens' / `completion_tokens' as a fallback.
%% 中文：使用供应商返回的 `usage' 对象记录精确 token 用量（支持 atom/binary 键及 OpenAI 风格字段）。
-spec trackUsage(binary(), map()) -> ok.
trackUsage(Model, Usage) when is_map(Usage) ->
    ensureStarted(),
    ModelKey = toBinary(Model),
    In = pickCount(Usage, [input_tokens, prompt_tokens, <<"input_tokens">>, <<"prompt_tokens">>]),
    Out = pickCount(Usage, [output_tokens, completion_tokens, <<"output_tokens">>, <<"completion_tokens">>]),
    updateRow(ModelKey, #{input_tokens => In, output_tokens => Out, apiCalls => 1}),
    ok;
trackUsage(_, _) ->
    ok.

%%--------------------------------------------------------------------
%% @doc
%% 按候选键优先级从 usage map 中挑选 token 计数；找不到则返回 0。
%%
%% @param Usage 供应商返回的 usage map
%% @param Keys 候选键列表（按优先级排序）
%% @return 第一个匹配的非负整数，或 `0'
%% @end
%%--------------------------------------------------------------------
pickCount(Usage, Keys) ->
    case [V || K <- Keys, V <- [maps:get(K, Usage, undefined)], is_integer(V), V >= 0] of
        [V | _] -> V;
        [] -> 0
    end.

%%--------------------------------------------------------------------
%% @doc
%% 累加更新某模型的 token 统计行：读取现有数据 → 累加新值 → 写回 ETS。
%%
%% @param ModelKey 模型名 binary
%% @param Delta 包含 input_tokens/output_tokens/apiCalls 的增量 map
%% @return `ok'
%% @end
%%--------------------------------------------------------------------
updateRow(ModelKey, #{input_tokens := In, output_tokens := Out, apiCalls := Calls}) ->
    %% 用 update_counter 原子更新，避免并发 read-modify-write 丢失更新
    case ets:insert_new(?Table, {ModelKey, 0, 0, 0}) of
        true -> ok;
        false -> ok
    end,
    ets:update_counter(?Table, ModelKey, [{2, In}, {3, Out}, {4, Calls}]),
    ok.

%%%===================================================================
%%% Aggregation
%%%===================================================================

%% @doc Aggregated token usage across all models, with estimated cost.
%% 中文：聚合所有模型的 token 用量与估算 USD 成本（含 per-model 明细）。
-spec stats() -> map().
stats() ->
    ensureStarted(),
    case ets:tab2list(?Table) of
        [] ->
            defaultStats();
        List ->
            TotalIn = lists:sum([In || {_, In, _, _} <- List]),
            TotalOut = lists:sum([Out || {_, _, Out, _} <- List]),
            TotalCalls = lists:sum([Calls || {_, _, _, Calls} <- List]),
            ByModel = maps:from_list([
                {Model, withCost(Model, #{input_tokens => In, output_tokens => Out, apiCalls => Calls})}
                || {Model, In, Out, Calls} <- List
            ]),
            TotalCost = lists:sum([
                modelCost(Model, In, Out)
                || {Model, In, Out, _} <- List
            ]),
            #{
                input_tokens => TotalIn,
                output_tokens => TotalOut,
                totalTokens => TotalIn + TotalOut,
                apiCalls => TotalCalls,
                estimatedCostUsd => roundCost(TotalCost),
                byModel => ByModel
            }
    end.

%%--------------------------------------------------------------------
%% @doc
%% 为单模型统计 map 附加 `estimatedCostUsd' 字段。
%%
%% @param Model 模型名
%% @param Stats 该模型的 token 统计 map
%% @return 含成本估算的统计 map
%% @end
%%--------------------------------------------------------------------
withCost(Model, Stats) ->
    In = maps:get(input_tokens, Stats, 0),
    Out = maps:get(output_tokens, Stats, 0),
    Stats#{estimatedCostUsd => roundCost(modelCost(Model, In, Out))}.

%% @doc Reset all counters.
%% 中文：清空所有 token 计数器。
-spec reset() -> ok.
reset() ->
    ensureStarted(),
    true = ets:delete_all_objects(?Table),
    ok.

%%%===================================================================
%%% Pricing
%%%===================================================================

%% @doc Per-1M-token USD pricing for known models: `{input, output}'.
%% Unknown models default to `{0.0, 0.0}' (free, no cost recorded).
%% 中文：已知模型的每百万 token USD 单价表 `{input, output}'，未知模型默认免费。
-spec pricing() -> #{binary() => {number(), number()}}.
pricing() ->
    #{
        <<"gpt-4o">> => {2.5, 10.0},
        <<"gpt-4o-mini">> => {0.15, 0.6},
        <<"gpt-4.1">> => {2.0, 8.0},
        <<"gpt-4.1-mini">> => {0.4, 1.6},
        <<"gpt-4.1-nano">> => {0.1, 0.4},
        <<"o3-mini">> => {1.1, 4.4},
        <<"deepseek-chat">> => {0.27, 1.1},
        <<"deepseek-reasoner">> => {0.55, 2.19},
        <<"deepseek-v4-flash">> => {0.1, 0.3},
        <<"claude-3-5-sonnet-20241022">> => {3.0, 15.0},
        <<"claude-3-5-haiku-20241022">> => {0.8, 4.0},
        <<"claude-3-7-sonnet-20250219">> => {3.0, 15.0}
    }.

%% @doc Compute estimated USD cost for a single model's token counts.
%% 中文：根据模型单价计算单次输入/输出 token 的 USD 成本（按每百万 token 计价）。
-spec modelCost(binary(), non_neg_integer(), non_neg_integer()) -> float().
modelCost(Model, InputTokens, OutputTokens) ->
    {PriceIn, PriceOut} = maps:get(toBinary(Model), pricing(), {0.0, 0.0}),
    (InputTokens * PriceIn + OutputTokens * PriceOut) / 1000000.

%% 将成本四舍五入到小数点后 6 位，避免浮点误差。
roundCost(Cost) ->
    erlang:round(Cost * 1000000) / 1000000.

%%%===================================================================
%%% Internal
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 确保统计 ETS 表已创建（已存在则直接返回 ok）。并发创建时容忍失败。
%%
%% @return `ok'
%% @end
%%--------------------------------------------------------------------
-spec ensureStarted() -> ok.
ensureStarted() ->
    case ets:info(?Table) of
        undefined ->
            try ets:new(?Table, [named_table, public, set, {read_concurrency, true}]) of
                _ -> ok
            catch
                _:_ -> ok
            end;
        _ ->
            ok
    end.

%% 返回空统计 map（无任何模型记录时的默认 stats 结果）。
defaultStats() ->
    #{input_tokens => 0, output_tokens => 0, totalTokens => 0,
      apiCalls => 0, estimatedCostUsd => 0.0, byModel => #{}}.

%%--------------------------------------------------------------------
%% @doc
%% 将值转换为 binary（多子句）：binary 原样、list 转 UTF-8、atom 转为 UTF-8 binary。
%%
%% @param Value 任意值
%% @return binary
%% @end
%%--------------------------------------------------------------------
toBinary(Value) when is_binary(Value) -> Value;
toBinary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
toBinary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8).
