%%%-------------------------------------------------------------------
%%% @doc 配置文件加载与解析（config.cfg）。
%%%
%%% 负责读取 Erlang term 格式的配置文件，写入 {@code ali} 应用环境，
%%% 并同步 LLM 连接参数到 {@link llmCli}。
%%%
%%% 对外查询请优先使用 {@link ali:getAgentConfig/0}、{@link ali:llmLoadConfig/0}。
%%% @end
%%%-------------------------------------------------------------------
-module(llmCliConfig).

-export([
    load/0,
    load/1,
    defaultPath/0,
    listProviders/0,
    getProvider/1,
    applyConfig/1,
    getAgentConfig/0,
    formatAgentConfig/0
]).

-define(CONFIG_DIR, "config").
-define(DEFAULT_CONFIG_FILE, "config/config.cfg").
-define(FALLBACK_CONFIG_FILE, "config/config.example.cfg").
-define(LEGACY_CONFIG_FILE, "config.cfg").
-define(LEGACY_FALLBACK_FILE, "config.example.cfg").
-define(ENV_CONFIG_FILE, "LLM_CONFIG_FILE").

-type providerInfo() :: #{
    name := binary(),
    baseUrl := binary(),
    defaultModel := binary()
}.

%% @doc 默认配置文件路径（环境变量 LLM_CONFIG_FILE 可覆盖）。
-spec defaultPath() -> string().
defaultPath() ->
    case os:getenv(?ENV_CONFIG_FILE) of
        false -> ?DEFAULT_CONFIG_FILE;
        Path -> Path
    end.

%% @doc 按优先级尝试加载配置文件。
%% 顺序：显式路径 → config/config.cfg → config/config.example.cfg → 根目录遗留路径。
-spec load() -> ok | {error, term()}.
load() ->
    loadFirstExisting([
        defaultPath(),
        ?DEFAULT_CONFIG_FILE,
        ?FALLBACK_CONFIG_FILE,
        ?LEGACY_CONFIG_FILE,
        ?LEGACY_FALLBACK_FILE
    ]).

%% 依次尝试候选路径，跳过不存在的文件。
loadFirstExisting([]) ->
    {error, enoent};
loadFirstExisting([Path | Rest]) ->
    Abs = filename:absname(Path),
    case file:read_file_info(Abs) of
        {ok, _} -> loadFile(Path);
        {error, enoent} -> loadFirstExisting(Rest);
        {error, Reason} -> {error, Reason}
    end.

%% @doc 从指定路径加载配置文件。
-spec load(string()) -> ok | {error, term()}.
load(FilePath) ->
    loadFile(FilePath).

%% 读取并解析 Erlang term 格式配置文件，写入应用环境。
loadFile(FilePath) ->
    AbsPath = filename:absname(FilePath),
    case file:consult(AbsPath) of
        {ok, Terms} ->
            Config = termsToMap(Terms),
            applyConfig(Config),
            llmCli:loadConfigFromEnv(),
            ok;
        {error, {Err, _Line, Reason}} ->
            {error, {Err, Reason}};
        {error, Reason} ->
            {error, Reason}
    end.

%% 将 file:consult 返回的 term 列表转为 map。
termsToMap(Terms) when is_list(Terms) ->
    maps:from_list([normalizeEntry(T) || T <- Terms, isConfigEntry(T)]).

%% 判断是否为合法的 `{Key, Value}' 配置项。
isConfigEntry({Key, _Value}) when is_atom(Key) ->
    true;
isConfigEntry(_) ->
    false.

%% 规范化单条配置项的键值。
normalizeEntry({Key, Value}) ->
    {Key, normalizeValue(Value)}.

%% 递归规范化配置值（map、proplist、字符串等）。
normalizeValue(Value) when is_map(Value) ->
    maps:map(fun(_, V) -> normalizeValue(V) end, Value);
normalizeValue(Value) when is_list(Value) ->
    case isProplist(Value) of
        true ->
            maps:from_list([{K, normalizeValue(V)} || {K, V} <- Value]);
        false ->
            case io_lib:printable_unicode_list(Value) of
                true -> toBinary(Value);
                false -> Value
            end
    end;
normalizeValue(Value) when is_binary(Value); is_integer(Value); is_boolean(Value);
                         is_float(Value); is_atom(Value) ->
    Value;
normalizeValue(Value) ->
    Value.

%% 判断列表是否为 atom 键的 proplist。
isProplist([]) ->
    true;
isProplist([{K, _} | Rest]) when is_atom(K) ->
    isProplist(Rest);
isProplist(_) ->
    false.

%% @doc 返回所有已注册的 LLM 提供商原子名列表。
-spec listProviders() -> [atom()].
listProviders() ->
    maps:keys(providerTable()).

%% @doc 查询指定提供商的预设信息（名称、URL、默认模型）。
-spec getProvider(atom() | binary() | string()) -> {ok, providerInfo()} | {error, unknownProvider}.
getProvider(Provider) ->
    Atom = toProviderAtom(Provider),
    case maps:get(Atom, providerTable(), undefined) of
        undefined -> {error, unknownProvider};
        Info -> {ok, Info}
    end.

%% @doc 将配置 map 写入 llmCli 与应用环境（含 Agent 相关项）。
-spec applyConfig(map()) -> ok.
applyConfig(Config) ->
    Provider = maps:get(provider, Config, openai),
    ApiKey = toBinary(maps:get(api_key, Config, <<>>)),
    BaseUrl = resolveBaseUrl(Config, Provider),
    Model = resolveModel(Config, Provider),

    llmCli:setConfig(api_key, ApiKey),
    llmCli:setConfig(provider, Provider),
    llmCli:setConfig(base_url, BaseUrl),
    llmCli:setConfig(model, Model),

    applyAgentConfig(Config),
    ok.

%% @doc 读取当前 Agent 相关配置子集。
-spec getAgentConfig() -> map().
getAgentConfig() ->
    AgentKeys = [model, projectRoot, maxSteps, maxMessages, maxTokens, policy, modelOptions, execTimeout],
    maps:from_list([
        {Key, Value} ||
        Key <- AgentKeys,
        {ok, Value} <- [application:get_env(ali, Key)]
    ]).

%% @doc 将 Agent 配置格式化为多行可读文本。
-spec formatAgentConfig() -> binary().
formatAgentConfig() ->
    C = getAgentConfig(),
    Lines = [
        formatLine(model, maps:get(model, C, undefined)),
        formatLine(projectRoot, maps:get(projectRoot, C, undefined)),
        formatLine(maxSteps, maps:get(maxSteps, C, undefined)),
        formatLine(maxMessages, maps:get(maxMessages, C, undefined)),
        formatLine(policy, maps:get(policy, C, undefined)),
        formatLine(modelOptions, maps:get(modelOptions, C, undefined))
    ],
    unicode:characters_to_binary(lists:join(<<"\n"/utf8>>, Lines)).

%% 格式化单行配置输出。
formatLine(Key, undefined) ->
    unicode:characters_to_binary(io_lib:format("~s: (未设置)", [atom_to_list(Key)]));
formatLine(Key, Value) ->
    unicode:characters_to_binary(io_lib:format("~s: ~ts", [atom_to_list(Key), formatValue(Value)])).

%% 将配置值转为可打印字符串。
formatValue(V) when is_binary(V) -> V;
formatValue(V) when is_atom(V) -> atom_to_binary(V, utf8);
formatValue(V) when is_integer(V); is_float(V); is_boolean(V) ->
    unicode:characters_to_binary(io_lib:format("~w", [V]));
formatValue(V) when is_list(V) ->
    unicode:characters_to_binary(io_lib:format("~p", [V]));
formatValue(V) when is_map(V) ->
    unicode:characters_to_binary(io_lib:format("~p", [V]));
formatValue(V) ->
    unicode:characters_to_binary(io_lib:format("~p", [V])).

%% 内置 LLM 提供商预设表（URL 与默认模型）。
-spec providerTable() -> #{atom() => providerInfo()}.
providerTable() ->
    #{
        openai => #{
            name => <<"OpenAI"/utf8>>,
            baseUrl => <<"https://api.openai.com/v1"/utf8>>,
            defaultModel => <<"gpt-4o-mini"/utf8>>
        },
        deepseek => #{
            name => <<"DeepSeek"/utf8>>,
            baseUrl => <<"https://api.deepseek.com"/utf8>>,
            defaultModel => <<"deepseek-v4-flash"/utf8>>
        },
        anthropic => #{
            name => <<"Anthropic"/utf8>>,
            baseUrl => <<"https://api.anthropic.com/v1"/utf8>>,
            defaultModel => <<"claude-3-5-sonnet-20241022"/utf8>>
        },
        custom => #{
            name => <<"Custom"/utf8>>,
            baseUrl => <<>>,
            defaultModel => <<>>
        }
    }.

%% 解析 base_url：空值时回退到提供商预设。
resolveBaseUrl(Config, Provider) ->
    case maps:get(base_url, Config, undefined) of
        Url when Url =:= <<>>; Url =:= "" -> presetBaseUrl(Provider);
        Url -> toBinary(Url)
    end.

%% 解析 model：空值时回退到提供商默认模型。
resolveModel(Config, Provider) ->
    case maps:get(model, Config, undefined) of
        Model when Model =:= <<>>; Model =:= "" -> presetModel(Provider);
        Model -> toBinary(Model)
    end.

%% 从提供商预设获取 base_url。
presetBaseUrl(Provider) ->
    case getProvider(Provider) of
        {ok, #{baseUrl := Preset}} -> Preset;
        _ -> <<>>
    end.

%% 从提供商预设获取默认模型。
presetModel(Provider) ->
    case getProvider(Provider) of
        {ok, #{defaultModel := Default}} -> Default;
        _ -> <<"gpt-4o-mini"/utf8>>
    end.

%% 将 Agent、Web、策略等扩展配置写入应用环境。
applyAgentConfig(Config) ->
    maps:foreach(fun(Key, Value) ->
        case Key of
            model ->
                setAgentEnv(model, toBinary(Value));
            projectRoot ->
                setAgentEnv(projectRoot, toBinary(Value));
            maxSteps when is_integer(Value) ->
                setAgentEnv(maxSteps, Value);
            maxMessages when is_integer(Value) ->
                setAgentEnv(maxMessages, Value);
            policy when is_map(Value) ->
                setAgentEnv(policy, normalizePolicy(Value));
            modelOptions when is_list(Value) ->
                setAgentEnv(modelOptions, Value);
            mode when Value =:= ask; Value =:= edit; Value =:= exec ->
                setAgentEnv(mode, Value);
            execBlacklist when is_list(Value) ->
                setAgentEnv(execBlacklist, Value);
            execTimeout when is_integer(Value), Value > 0 ->
                setAgentEnv(execTimeout, Value);
            maxTokens when is_integer(Value), Value > 0 ->
                setAgentEnv(maxTokens, Value);
            backupBeforeEdit when is_boolean(Value) ->
                setAgentEnv(backupBeforeEdit, Value);
            indexExclude when is_list(Value) ->
                setAgentEnv(indexExclude, Value);
            webPort when is_integer(Value) ->
                setAgentEnv(webPort, Value);
            webEnabled when is_boolean(Value) ->
                setAgentEnv(webEnabled, Value);
            webApiToken ->
                setAgentEnv(webApiToken, toBinary(Value));
            _ ->
                ok
        end
    end, Config),
    ok.

%% 合并用户策略与默认策略。
normalizePolicy(Policy) ->
    maps:merge(alPolicy:defaultPolicy(), Policy).

%% 写入单条 Agent 环境变量。
setAgentEnv(Key, Value) ->
    application:set_env(ali, Key, Value).

%% 将提供商标识统一转为原子。
toProviderAtom(Provider) when is_atom(Provider) ->
    Provider;
toProviderAtom(Provider) ->
    list_to_atom(string:lowercase(toList(Provider))).

%% 多类型转字符串列表。
toList(X) when is_binary(X) -> binary_to_list(X);
toList(X) when is_list(X) -> X;
toList(X) when is_atom(X) -> atom_to_list(X).

%% 多类型转 UTF-8 二进制。
toBinary(X) when is_binary(X) -> X;
toBinary(X) when is_list(X) -> unicode:characters_to_binary(X);
toBinary(X) when is_atom(X) -> atom_to_binary(X, utf8);
toBinary(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).