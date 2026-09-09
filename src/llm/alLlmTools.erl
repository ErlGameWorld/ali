%%%-------------------------------------------------------------------
%% @doc OpenAI function-calling 工具 schema 与参数解码。
%%
%% 工具定义由 {@link alToolCatalog} 统一管理；本模块负责 LLM 返回参数的
%% JSON 解码与键名归一化（binary → 已存在 atom）。
%% @end
%%%-------------------------------------------------------------------

-module(alLlmTools).

-export([definitions/0, decodeArgs/1, toolAtom/1]).

%%--------------------------------------------------------------------
%% @doc
%% 返回所有可供 LLM function-calling 使用的工具定义列表。
%% 实际转发给 alToolCatalog 模块统一管理。
%%
%% @return 工具定义列表（OpenAI function-calling schema 格式）
%% @end
%%--------------------------------------------------------------------
definitions() ->
    alToolCatalog:llmDefinitions().

%%--------------------------------------------------------------------
%% @doc
%% 解码 LLM 返回的工具调用参数，并把所有二进制键归一化为
%% 已存在的原子键，方便后续模式匹配。支持二进制 JSON 字符串、
%% 已解码的 map 两种输入。
%%
%% @param ArgsBin 参数（binary 为 JSON 文本，map 为已解码结构）
%% @return {ok, Map} | {error, invalidArguments | invalidJson}
%% @end
%%--------------------------------------------------------------------
decodeArgs(ArgsBin) when is_binary(ArgsBin) ->
  try alJson:decode(ArgsBin) of
      Map when is_map(Map) -> {ok, normalizeMap(Map)};
      _ -> {error, invalidArguments}
  catch
      _:_ -> {error, invalidJson}
  end;
decodeArgs(Map) when is_map(Map) ->
    {ok, normalizeMap(Map)};
decodeArgs(_) ->
    {error, invalidArguments}.

%% 递归地把 map 中所有键和值归一化：键转原子，值递归处理 map/list。
normalizeMap(Map) ->
    maps:from_list([
        {normalizeKey(Key), normalizeValue(Value)} || {Key, Value} <- maps:to_list(Map)
    ]).

%% 把二进制键转为已存在的原子；若原子不存在则保留原二进制，避免内存泄漏。
normalizeKey(Key) when is_binary(Key) ->
    try binary_to_existing_atom(Key, utf8) catch _:_ -> Key end;
normalizeKey(Key) ->
    Key.

%% 递归归一化值：map 走 normalizeMap，list 逐项递归，其余原样返回。
normalizeValue(Value) when is_map(Value) ->
    normalizeMap(Value);
normalizeValue(Value) when is_list(Value) ->
    [normalizeValue(Item) || Item <- Value];
normalizeValue(Value) ->
    Value.

%%--------------------------------------------------------------------
%% @doc
%% 把工具名（二进制或原子）转换为已存在的原子；若原子不存在
%% 则原样返回（避免动态创建原子）。
%%
%% @param NameBin 工具名（binary 或 atom）
%% @return atom | binary（输入为原子则原样返回）
%% @end
%%--------------------------------------------------------------------
-spec toolAtom(atom() | binary()) -> atom() | binary().
toolAtom(NameBin) when is_binary(NameBin) ->
    try binary_to_existing_atom(NameBin, utf8) catch _:_ -> NameBin end;
toolAtom(Name) when is_atom(Name) ->
    Name.
