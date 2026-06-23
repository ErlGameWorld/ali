-module(alConfig).

-export([
	load/0,
	load/1,
	val/1,
	val/2,
	listProviders/0,
	getProvider/1,
	getAgentConfig/0,
	formatAgentConfig/0,
	publicWebConfig/0,
	resolvedLlm/0,
	get/1,
	get/2,
	web/0
]).

-include("common.hrl").
-include("al_limits.hrl").
-include("al_attachment.hrl").

-define(ROOT_CFG, "aliCfg.cfg").
-define(CONFIG_DIR_CFG, "config/aliCfg.cfg").

-define(AGENT_KEYS, [
	model, projectRoot, maxSteps, maxMessages, maxTokens, mode, policy, modelOptions,
	execTimeout, llmMaxRetries, systemPromptExtra, historyCompaction, limits
]).

-type limit_key() :: atom().
-type providerInfo() :: #{name := binary(), baseUrl := binary(), defaultModel := binary()}.

%%%===================================================================
%%% aliCfg.cfg
%%%===================================================================

-spec load() -> ok | {error, term()}.
load() ->
	Root = alToolProject:findProjectRootFromModule(),
	loadFirstExisting([
		filename:join(Root, ?ROOT_CFG),
		filename:join(Root, ?CONFIG_DIR_CFG)
	]).

loadFirstExisting([]) ->
	installConfig(defaultKVs());
loadFirstExisting([Path | Rest]) ->
	case file:read_file_info(filename:absname(Path)) of
		{ok, _} -> loadFile(Path);
		{error, enoent} -> loadFirstExisting(Rest);
		{error, Reason} -> {error, Reason}
	end.

-spec load(string()) -> ok | {error, term()}.
load(FilePath) ->
	loadFile(FilePath).

loadFile(FilePath) ->
	AbsPath = filename:absname(FilePath),
	case file:consult(AbsPath) of
		{ok, Terms} ->
			FileKVs = [{K, cfgTerms(K, V)} || {K, V} <- Terms, is_atom(K)],
			installConfig(mergeKVs(defaultKVs(), FileKVs));
		{error, {Err, _Line, Reason}} ->
			{error, {Err, Reason}};
		{error, Reason} ->
			{error, Reason}
	end.

installConfig(KVs) ->
	alKvsToBeam:load(aliCfg, KVs, undefined),
	notifyServerConfigReload(),
	ok.

notifyServerConfigReload() ->
	case whereis(alServer) of
		Pid when is_pid(Pid) ->
			gen_server:cast(Pid, refreshConfig);
		_ ->
			ok
	end.

-spec val(atom()) -> term().
val(Key) ->
	case aliCfg:getV(Key) of
		undefined -> defaultValue(Key);
		V -> V
	end.

-spec val(atom(), term()) -> term().
val(Key, Default) ->
	case val(Key) of
		undefined -> Default;
		V -> V
	end.

defaultValue(Key) ->
	proplists:get_value(Key, defaultKVs(), undefined).

-spec resolvedLlm() -> #{
provider := atom(),
api_key := binary(),
base_url := binary(),
model := binary()
}.
resolvedLlm() ->
	#{
		provider => val(provider),
		api_key => val(api_key),
		base_url => resolveBaseUrl(val(base_url)),
		model => resolveModel(val(model))
	}.

-spec listProviders() -> [atom()].
listProviders() ->
	maps:keys(providerTable()).

-spec getProvider(atom() | binary() | string()) -> {ok, providerInfo()} | {error, unknownProvider}.
getProvider(Provider) ->
	Atom = providerAtom(Provider),
	case maps:get(Atom, providerTable(), undefined) of
		undefined -> {error, unknownProvider};
		Info -> {ok, Info}
	end.

-spec getAgentConfig() -> map().
getAgentConfig() ->
	maps:from_list([{Key, val(Key)} || Key <- ?AGENT_KEYS]).

-spec publicWebConfig() -> map().
publicWebConfig() ->
	Agent = getAgentConfig(),
	#{
		attachmentLimits => web(),
		limits => maps:get(limits, Agent),
		agent => publicAgentConfig(Agent),
		llm => publicLlmConfig(),
		policy => publicPolicyMap(maps:get(policy, Agent)),
		web => publicWebSettings(),
		mcp => publicMcpServers(val(mcpServers))
	}.

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

%%%===================================================================
%%% limits
%%%===================================================================

-spec get(limit_key()) -> non_neg_integer() | pos_integer().
get(Key) ->
	maps:get(Key, limitsMap()).

-spec get(limit_key(), term()) -> term().
get(Key, Default) ->
	maps:get(Key, limitsMap(), Default).

limitsMap() ->
	case val(limits) of
		L when is_map(L) -> L;
		_ -> limitDefaults()
	end.

-spec web() -> #{
maxImages := non_neg_integer(),
maxFiles := non_neg_integer(),
maxImageBytes := non_neg_integer(),
maxFileBytes := non_neg_integer(),
maxDocuments := non_neg_integer(),
maxDocumentBytes := non_neg_integer(),
textFileExtensions := [binary()],
documentFileExtensions := [binary()],
imageMimeTypes := [binary()],
documentMimeTypes := [binary()]
}.
web() ->
	#{
		maxImages => ?MODULE:get(webMaxImages),
		maxFiles => ?MODULE:get(webMaxFiles),
		maxImageBytes => ?MODULE:get(webMaxImageBytes),
		maxFileBytes => ?MODULE:get(webMaxFileBytes),
		maxDocuments => ?MODULE:get(webMaxDocuments),
		maxDocumentBytes => ?MODULE:get(webMaxDocumentBytes),
		textFileExtensions => [list_to_binary(Ext) || Ext <- ?AL_TEXT_FILE_EXTENSIONS],
		documentFileExtensions => [list_to_binary(Ext) || Ext <- ?AL_DOCUMENT_FILE_EXTENSIONS],
		imageMimeTypes => ?AL_IMAGE_MIME_TYPES,
		documentMimeTypes => ?AL_DOCUMENT_MIME_TYPES
	}.

%%%===================================================================
%%% Internal
%%%===================================================================

defaultKVs() ->
	[
		{provider, openai},
		{api_key, <<>>},
		{base_url, <<>>},
		{model, <<>>},
		{projectRoot, <<"."/utf8>>},
		{maxSteps, 25},
		{maxMessages, 40},
		{maxTokens, 32000},
		{modelOptions, [{temperature, 0.2}]},
		{policy, alPolicy:defaultPolicy()},
		{mode, ask},
		{backupBeforeEdit, true},
		{execBlacklist, []},
		{execTimeout, 60000},
		{llmMaxRetries, 2},
		{indexExclude, []},
		{systemPromptExtra, <<>>},
		{historyCompaction, true},
		{ragMode, auto},
		{embeddingModel, <<>>},
		{webPort, 8088},
		{webEnabled, false},
		{webApiToken, <<>>},
		{webAllowOrigin, <<>>},
		{webRateLimit, 240},
		{webRateWindowMs, 60000},
		{webAllowRemoteWrites, false},
		{limits, limitDefaults()},
		{mcpServers, []}
	].

limitDefaults() ->
	#{
		webMaxImages => ?DEFAULT_WEB_MAX_IMAGES,
		webMaxFiles => ?DEFAULT_WEB_MAX_FILES,
		webMaxImageBytes => ?DEFAULT_WEB_MAX_IMAGE_BYTES,
		webMaxFileBytes => ?DEFAULT_WEB_MAX_FILE_BYTES,
		webMaxDocuments => ?DEFAULT_WEB_MAX_DOCUMENTS,
		webMaxDocumentBytes => ?DEFAULT_WEB_MAX_DOCUMENT_BYTES,
		toolReadFileMaxBytes => ?DEFAULT_TOOL_READ_FILE_MAX_BYTES,
		toolListFilesMaxResults => ?DEFAULT_TOOL_LIST_FILES_MAX_RESULTS,
		analyzeReadMaxBytes => ?DEFAULT_ANALYZE_READ_MAX_BYTES,
		analyzeMaxSourceLines => ?DEFAULT_ANALYZE_MAX_SOURCE_LINES,
		analyzeMaxAbstract => ?DEFAULT_ANALYZE_MAX_ABSTRACT,
		toolMaxOutput => ?DEFAULT_TOOL_MAX_OUTPUT,
		toolEvalMaxOutput => ?DEFAULT_TOOL_EVAL_MAX_OUTPUT,
		toolRuntimeMaxOutput => ?DEFAULT_TOOL_RUNTIME_MAX_OUTPUT,
		maxToolContent => ?DEFAULT_MAX_TOOL_CONTENT,
		otpMaxDepth => ?DEFAULT_OTP_MAX_DEPTH,
		otpMaxChildren => ?DEFAULT_OTP_MAX_CHILDREN,
		auditMaxEntries => ?DEFAULT_AUDIT_MAX_ENTRIES,
		progressMaxEvents => ?DEFAULT_PROGRESS_MAX_EVENTS,
		backupMaxPerFile => ?DEFAULT_BACKUP_MAX_PER_FILE,
		shellCmdMaxOutput => ?DEFAULT_SHELL_CMD_MAX_OUTPUT,
		shellCmdTimeout => ?DEFAULT_SHELL_CMD_TIMEOUT,
		toolTimeout => ?DEFAULT_TOOL_TIMEOUT,
		symlinkMaxDepth => ?DEFAULT_SYMLINK_MAX_DEPTH
	}.

mergeKVs(DefaultKVs, FileKVs) ->
	DefaultMap = maps:from_list(DefaultKVs),
	FileMap = maps:from_list(FileKVs),
	maps:to_list(maps:fold(fun mergeConfigKey/3, DefaultMap, FileMap)).

mergeConfigKey(Key, FileVal, Acc) ->
	DefaultVal = maps:get(Key, Acc, undefined),
	maps:put(Key, mergeConfigValue(Key, DefaultVal, FileVal), Acc).

mergeConfigValue(limits, Default, User) when is_map(Default), is_map(User) ->
	maps:merge(Default, User);
mergeConfigValue(policy, Default, User) when is_map(Default), is_map(User) ->
	maps:merge(Default, User);
mergeConfigValue(_Key, _Default, FileVal) ->
	FileVal.

%% ? policy/limits ????? proplist ?? map?modelOptions ??? proplist?
cfgTerms(_Key, Value) when is_map(Value) ->
	maps:map(fun(K, V) -> cfgTerms(K, V) end, Value);
cfgTerms(Key, Value) when is_list(Value) ->
	case isProplist(Value) of
		false ->
			case textConfigKey(Key) of
				true -> toTextBinary(Value);
				false -> [cfgTerms(Key, V) || V <- Value]
			end;
		true when Value =:= [] ->
			[];
		true when Key =:= limits; Key =:= policy ->
			maps:from_list([{K, cfgTerms(K, V)} || {K, V} <- Value]);
		true ->
			[{K, cfgTerms(K, V)} || {K, V} <- Value]
	end;
cfgTerms(Key, Value) ->
	asTextConfig(Key, Value).

textConfigKey(api_key) -> true;
textConfigKey(base_url) -> true;
textConfigKey(model) -> true;
textConfigKey(projectRoot) -> true;
textConfigKey(systemPromptExtra) -> true;
textConfigKey(embeddingModel) -> true;
textConfigKey(webApiToken) -> true;
textConfigKey(webAllowOrigin) -> true;
textConfigKey(_) -> false.

asTextConfig(Key, Value) ->
	case textConfigKey(Key) of
		true -> toTextBinary(Value);
		false -> Value
	end.

toTextBinary(B) when is_binary(B) -> B;
toTextBinary(L) when is_list(L) -> unicode:characters_to_binary(L);
toTextBinary(A) when is_atom(A) -> atom_to_binary(A, utf8);
toTextBinary(V) ->
	V.

isProplist([]) -> true;
isProplist([{K, _} | Rest]) when is_atom(K) -> isProplist(Rest);
isProplist(_) -> false.

publicAgentConfig(Agent) ->
	Keys = [maxSteps, maxMessages, maxTokens, mode, model, projectRoot,
		historyCompaction, backupBeforeEdit, llmMaxRetries, modelOptions],
	pickKeys(Agent, Keys).

publicLlmConfig() ->
	R = resolvedLlm(),
	#{
		provider => maps:get(provider, R),
		model => maps:get(model, R),
		baseUrl => maps:get(base_url, R)
	}.

publicPolicyMap(Policy) when is_map(Policy) ->
	Keys = [allowRead, allowExecuteSafe, allowExecuteRisky, allowWrite,
		requireWriteConfirmation, requireRiskyConfirmation],
	pickKeys(Policy, Keys);
publicPolicyMap(_) ->
	#{}.

publicWebSettings() ->
	Token = val(webApiToken),
	#{
		webPort => val(webPort),
		webEnabled => val(webEnabled),
		webRateLimit => val(webRateLimit),
		webRateWindowMs => val(webRateWindowMs),
		webAllowRemoteWrites => val(webAllowRemoteWrites),
		authEnabled => Token =/= <<>>
	}.

publicMcpServers(Servers) when is_list(Servers) ->
	[publicMcpSpec(S) || S <- Servers, is_map(S)];
publicMcpServers(_) ->
	[].

publicMcpSpec(S) ->
	#{
		name => maps:get(name, S, unknown),
		level => maps:get(level, S, executeRisky),
		transport => maps:get(transport, S, stdio)
	}.

pickKeys(Map, Keys) ->
	maps:from_list([{K, maps:get(K, Map)} || K <- Keys, maps:is_key(K, Map)]).

formatLine(Key, undefined) ->
	unicode:characters_to_binary(io_lib:format("~s: (???)", [atom_to_list(Key)]));
formatLine(Key, Value) ->
	unicode:characters_to_binary(io_lib:format("~s: ~ts", [atom_to_list(Key), formatValue(Value)])).

formatValue(V) when is_binary(V) -> V;
formatValue(V) when is_atom(V) -> atom_to_binary(V, utf8);
formatValue(V) when is_number(V); is_boolean(V) ->
	unicode:characters_to_binary(io_lib:format("~w", [V]));
formatValue(V) ->
	unicode:characters_to_binary(io_lib:format("~p", [V])).

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
		qwen => #{
			name => <<"???? (DashScope)"/utf8>>,
			baseUrl => <<"https://dashscope.aliyuncs.com/compatible-mode/v1"/utf8>>,
			defaultModel => <<"qwen-plus"/utf8>>
		},
		kimi => #{
			name => <<"Kimi (Moonshot)"/utf8>>,
			baseUrl => <<"https://api.moonshot.cn/v1"/utf8>>,
			defaultModel => <<"moonshot-v1-8k"/utf8>>
		},
		zhipu => #{
			name => <<"?? GLM"/utf8>>,
			baseUrl => <<"https://open.bigmodel.cn/api/paas/v4"/utf8>>,
			defaultModel => <<"glm-4-flash"/utf8>>
		},
		ernie => #{
			name => <<"???? (??)"/utf8>>,
			baseUrl => <<"https://qianfan.baidubce.com/v2"/utf8>>,
			defaultModel => <<"ernie-4.0-8k"/utf8>>
		},
		doubao => #{
			name => <<"?? (????)"/utf8>>,
			baseUrl => <<"https://ark.cn-beijing.volces.com/api/v3"/utf8>>,
			defaultModel => <<"doubao-pro-32k"/utf8>>
		},
		openrouter => #{
			name => <<"OpenRouter"/utf8>>,
			baseUrl => <<"https://openrouter.ai/api/v1"/utf8>>,
			defaultModel => <<"openai/gpt-4o-mini"/utf8>>
		},
		custom => #{
			name => <<"Custom"/utf8>>,
			baseUrl => <<>>,
			defaultModel => <<>>
		}
	}.

resolveBaseUrl(Url) when Url =:= <<>>; Url =:= ""; Url =:= [] ->
	presetBaseUrl(val(provider));
resolveBaseUrl(Url) ->
	toTextBinary(Url).

resolveModel(Model) when Model =:= <<>>; Model =:= ""; Model =:= [] ->
	presetModel(val(provider));
resolveModel(Model) ->
	toTextBinary(Model).

presetBaseUrl(Provider) ->
	case getProvider(Provider) of
		{ok, #{baseUrl := Preset}} -> Preset;
		_ -> <<>>
	end.

presetModel(Provider) ->
	case getProvider(Provider) of
		{ok, #{defaultModel := Default}} -> Default;
		_ -> <<"gpt-4o-mini"/utf8>>
	end.

providerAtom(P) when is_atom(P) -> P;
providerAtom(P) ->
	binary_to_existing_atom(string:lowercase(unicode:characters_to_binary(P)), utf8).
