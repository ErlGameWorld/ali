%%%-------------------------------------------------------------------
%%% @doc 自定义工具插件 behaviour 定义。
%%%
%%% 实现本 behaviour 的模块可作为 Agent 工具注册到 {@link alTools}，
%%% 供 LLM 通过 function calling 或文本 `<tool_call>` 调用。
%%% 每个回调对应工具的元数据与执行入口。
%%% @end
%%%-------------------------------------------------------------------
-module(alTool).

%% 工具插件 behaviour（供未来扩展自定义工具）

%% @doc 返回工具的唯一原子标识，与 LLM 调用时的工具名一致。
-callback name() -> atom().

%% @doc 返回工具的人类可读描述，注入 LLM 系统提示或工具列表。
-callback description() -> binary().

%% @doc 返回工具参数的 JSON Schema 描述（binary 格式），供 LLM 构造调用参数。
-callback parameters() -> binary().

%% @doc 执行工具逻辑。
%% @param Args LLM 传入的参数字典（map）
%% @param Config 当前 Agent 配置 map（含 projectRoot、policy 等）
%% @returns `{ok, map()}` 成功结果，或 `{error, term()}` 失败原因
-callback execute(map(), map()) -> {ok, map()} | {error, term()}.

-optional_callbacks([]).