%%%-------------------------------------------------------------------
%% @doc 专家身份（Persona）：可配置、可切换的身份叙述，与 skill 同构加载。
%%
%% 身份可换；硬纪律工作流仍由 {@link alContext} 固定注入。
%% 文件：`priv/personas/<name>.md`（YAML frontmatter + Markdown 正文）。
%% @end
%%%-------------------------------------------------------------------

-module(alPersona).

-export([
    list/0,
    lookup/1,
    load/1,
    resolve/1,
    resolve/2,
    inject/2,
    recommendedSkills/1,
    recommendedTools/1,
    rubric/1,
    cacheClear/0,
    defaultIdentity/0
]).

%% Test helpers
-export([
    parsePersonaMd/2,
    score/2,
    normalizeName/1
]).

-define(DefaultPersonasDir, "personas").
-define(CacheKey, {?MODULE, allPersonas}).
-define(DefaultPersonaName, erlang_expert).

-type persona_name() :: atom() | binary().

-type persona() :: #{
    name := persona_name(),
    desc := binary(),
    promptExtra := binary(),
    triggers => [binary()],
    recommendedSkills => [atom() | binary()],
    recommendedTools => [atom()],
    rubric => binary()
}.

-export_type([persona/0, persona_name/0]).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc 列出所有 persona：`[{Name, Desc}]`。
%% @end
%%--------------------------------------------------------------------
-spec list() -> [{persona_name(), binary()}].
list() ->
    [{Name, maps:get(desc, P, <<>>)} || {Name, P} <- allPersonas()].

%%--------------------------------------------------------------------
%% @doc 按名称查找 persona。
%% @end
%%--------------------------------------------------------------------
-spec lookup(term()) -> {ok, persona()} | {error, notFound}.
lookup(Name0) ->
    Name = normalizeName(Name0),
    case lists:filter(fun({N, _}) -> namesEqual(Name, N) end, allPersonas()) of
        [{_, P} | _] -> {ok, P};
        [] -> {error, notFound}
    end.

%%--------------------------------------------------------------------
%% @doc 从 personas 目录加载单个 Markdown 文件。
%% @end
%%--------------------------------------------------------------------
-spec load(persona_name()) -> {ok, persona()} | {error, term()}.
load(Name0) ->
    Name = normalizeName(Name0),
    Path = filename:join(personasDir(), fileStem(Name) ++ ".md"),
    case file:read_file(Path) of
        {ok, Bin} -> {ok, parsePersonaMd(Name, Bin)};
        {error, _} = E -> E
    end.

%%--------------------------------------------------------------------
%% @doc 解析问题与配置，选出当前应注入的 persona。
%% 优先级：Opts.persona / agentCfg.persona → 触发词匹配 → defaultPersona → 内置回退。
%% @end
%%--------------------------------------------------------------------
-spec resolve(map()) -> {ok, persona()} | {ok, builtin}.
resolve(Opts) when is_map(Opts) ->
    resolve(<<>>, Opts).

-spec resolve(binary(), map()) -> {ok, persona()} | {ok, builtin}.
resolve(Question, Opts) when is_map(Opts) ->
    AgentCfg = maps:get(agentCfg, Opts, alConfig:getAgentCfg()),
    Enabled = maps:get(personasEnabled, AgentCfg, true),
    case Enabled of
        false ->
            {ok, builtin};
        _ ->
            Explicit = firstDefined([
                maps:get(persona, Opts, undefined),
                maps:get(persona, AgentCfg, undefined)
            ]),
            case Explicit of
                undefined ->
                    Auto = maps:get(personasAutoMatch, AgentCfg, true),
                    Matched = case Auto of
                        true -> matchOne(Question);
                        _ -> undefined
                    end,
                    case Matched of
                        undefined ->
                            Default = maps:get(defaultPersona, AgentCfg, ?DefaultPersonaName),
                            case lookup(Default) of
                                {ok, P} -> {ok, P};
                                {error, notFound} -> {ok, builtin}
                            end;
                        Name ->
                            case lookup(Name) of
                                {ok, P} -> {ok, P};
                                {error, notFound} -> {ok, builtin}
                            end
                    end;
                Name ->
                    case lookup(Name) of
                        {ok, P} -> {ok, P};
                        {error, notFound} -> {ok, builtin}
                    end
            end
    end.

%%--------------------------------------------------------------------
%% @doc 将 persona 身份叙述接到基础提示前；builtin 用 {@link defaultIdentity/0}。
%% @end
%%--------------------------------------------------------------------
-spec inject(binary(), {ok, persona()} | {ok, builtin} | persona() | builtin) -> binary().
inject(HardDiscipline, {ok, P}) ->
    inject(HardDiscipline, P);
inject(HardDiscipline, builtin) ->
    Id = defaultIdentity(),
    <<Id/binary, "\n\n", HardDiscipline/binary>>;
inject(HardDiscipline, Persona) when is_map(Persona) ->
    Body0 = maps:get(promptExtra, Persona, <<>>),
    Body = string:trim(Body0),
    Name = toBinary(maps:get(name, Persona, <<"persona">>)),
    Desc = maps:get(desc, Persona, <<>>),
    Header = case Desc of
        <<>> ->
            iolist_to_binary([<<"## 专家身份（"/utf8>>, Name, <<"）\n"/utf8>>]);
        _ ->
            iolist_to_binary([
                <<"## 专家身份（"/utf8>>, Name, <<"）\n"/utf8>>,
                Desc, <<"\n\n"/utf8>>
            ])
    end,
    Section = case Body of
        <<>> -> <<Header/binary, (defaultIdentity())/binary>>;
        _ -> <<Header/binary, Body/binary>>
    end,
    <<Section/binary, "\n\n", HardDiscipline/binary>>;
inject(HardDiscipline, _) ->
    inject(HardDiscipline, builtin).

%%--------------------------------------------------------------------
%% @doc persona 推荐技能名列表（可能为空）。
%% @end
%%--------------------------------------------------------------------
-spec recommendedSkills(persona() | {ok, persona()} | {ok, builtin} | builtin) -> [atom() | binary()].
recommendedSkills({ok, P}) -> recommendedSkills(P);
recommendedSkills(builtin) -> [];
recommendedSkills(P) when is_map(P) -> maps:get(recommendedSkills, P, []);
recommendedSkills(_) -> [].

%%--------------------------------------------------------------------
%% @doc persona 推荐工具名列表（可能为空）。
%% @end
%%--------------------------------------------------------------------
-spec recommendedTools(persona() | {ok, persona()} | {ok, builtin} | builtin) -> [atom()].
recommendedTools({ok, P}) -> recommendedTools(P);
recommendedTools(builtin) -> [];
recommendedTools(P) when is_map(P) -> maps:get(recommendedTools, P, []);
recommendedTools(_) -> [].

%%--------------------------------------------------------------------
%% @doc persona 评审 rubric（供 critic 追加；可空）。
%% @end
%%--------------------------------------------------------------------
-spec rubric(persona() | {ok, persona()} | {ok, builtin} | builtin) -> binary().
rubric({ok, P}) -> rubric(P);
rubric(builtin) -> <<>>;
rubric(P) when is_map(P) -> maps:get(rubric, P, <<>>);
rubric(_) -> <<>>.

%%--------------------------------------------------------------------
%% @doc 清除 persona 缓存。
%% @end
%%--------------------------------------------------------------------
-spec cacheClear() -> ok.
cacheClear() ->
    persistent_term:erase(?CacheKey),
    ok.

%%--------------------------------------------------------------------
%% @doc 无 persona 文件时的内置身份（保持与旧 BasePrompt 同级定位）。
%% @end
%%--------------------------------------------------------------------
-spec defaultIdentity() -> binary().
defaultIdentity() ->
    <<"你是嵌入在本项目中的 Erlang 专家助手（资深 Erlang/OTP 开发者）。\n"
      "以工程证据作答：索引命中、源码、调用图与运行时工具结果优先于训练记忆；"
      "结论须可引用 file:line / MFA / 工具字段。"/utf8>>.

%%%===================================================================
%%% Parse / match
%%%===================================================================

parsePersonaMd(Name, Bin) ->
    {Meta, Body} = alSkill:splitFrontmatter(Bin),
    Triggers = proplists:get_value(triggers, Meta, []),
    Skills = firstMetaList(Meta, [recommendedSkills, skills]),
    Tools = firstMetaList(Meta, [recommendedTools, tools]),
    Desc = toBinary(proplists:get_value(desc, Meta, <<>>)),
    Rubric = toBinary(proplists:get_value(rubric, Meta, <<>>)),
    #{
        name => Name,
        desc => Desc,
        promptExtra => Body,
        triggers => [toBinary(T) || T <- ensureList(Triggers)],
        recommendedSkills => [normalizeSkillRef(S) || S <- ensureList(Skills)],
        recommendedTools => [toAtomSafe(T) || T <- ensureList(Tools)],
        rubric => Rubric
    }.

matchOne(Question) when is_binary(Question), Question =/= <<>> ->
    Scored = [{Name, score(Question, P)} || {Name, P} <- allPersonas()],
    Positive = [{N, S} || {N, S} <- Scored, S > 0],
    case lists:sort(fun({_, A}, {_, B}) -> A >= B end, Positive) of
        [{Name, _} | _] -> Name;
        [] -> undefined
    end;
matchOne(_) ->
    undefined.

score(Query, Persona) ->
    Q = safeLower(Query),
    lists:foldl(fun(T, Acc) ->
        Needle = safeLower(T),
        try
            case binary:match(Q, Needle) of
                nomatch -> Acc;
                _ -> Acc + 1
            end
        catch
            _:_ -> Acc
        end
    end, 0, maps:get(triggers, Persona, [])).

%%%===================================================================
%%% Internal
%%%===================================================================

allPersonas() ->
    case persistent_term:get(?CacheKey, undefined) of
        undefined ->
            All = loadExternal(),
            persistent_term:put(?CacheKey, All),
            All;
        Cached ->
            Cached
    end.

loadExternal() ->
    Dir = personasDir(),
    case file:list_dir(Dir) of
        {ok, Entries} ->
            MdFiles = [F || F <- Entries, filename:extension(F) =:= ".md"],
            lists:foldl(fun(F, Acc) ->
                Name = normalizeName(filename:rootname(F)),
                case load(Name) of
                    {ok, P} -> [{Name, P} | Acc];
                    _ -> Acc
                end
            end, [], MdFiles);
        _ ->
            []
    end.

personasDir() ->
    Agent = alConfig:get(agent, #{}),
    case maps:get(personasDir, Agent, undefined) of
        undefined ->
            filename:join(alConfig:privDir(), ?DefaultPersonasDir);
        Path ->
            List = toList(Path),
            case filename:pathtype(List) of
                absolute -> List;
                _ -> filename:join(alConfig:privDir(), List)
            end
    end.

firstDefined([undefined | Rest]) -> firstDefined(Rest);
firstDefined([<<>> | Rest]) -> firstDefined(Rest);
firstDefined(["" | Rest]) -> firstDefined(Rest);
firstDefined([V | _]) -> V;
firstDefined([]) -> undefined.

firstMetaList(Meta, Keys) ->
    lists:foldl(fun(K, Acc) ->
        case Acc of
            [] ->
                V = metaGet(Meta, K),
                ensureList(V);
            _ -> Acc
        end
    end, [], Keys).

metaGet(Meta, Key) when is_atom(Key) ->
    case proplists:get_value(Key, Meta, undefined) of
        undefined ->
            proplists:get_value(atom_to_binary(Key, utf8), Meta, []);
        V -> V
    end;
metaGet(Meta, Key) ->
    proplists:get_value(Key, Meta, []).

ensureList(L) when is_list(L) -> L;
ensureList(B) when is_binary(B), B =/= <<>> -> [B];
ensureList(A) when is_atom(A) -> [A];
ensureList(_) -> [].

normalizeName(N) when is_atom(N) -> N;
normalizeName(N) when is_binary(N) ->
    %% erlang-expert.md → erlang_expert atom when exists, else keep binary
    Stem = binary:replace(string:trim(N), <<"-">>, <<"_">>, [global]),
    try binary_to_existing_atom(Stem, utf8)
    catch _:_ ->
        try binary_to_existing_atom(string:trim(N), utf8)
        catch _:_ -> Stem
        end
    end;
normalizeName(N) when is_list(N) ->
    normalizeName(unicode:characters_to_binary(N));
normalizeName(N) ->
    normalizeName(toBinary(N)).

normalizeSkillRef(S) when is_atom(S) -> S;
normalizeSkillRef(S) ->
    B = toBinary(S),
    try binary_to_existing_atom(B, utf8)
    catch _:_ -> B
    end.

fileStem(Name) when is_atom(Name) ->
    %% erlang_expert → erlang-expert.md
    lists:flatten(string:replace(atom_to_list(Name), "_", "-", all));
fileStem(Name) when is_binary(Name) ->
    unicode:characters_to_list(
        binary:replace(Name, <<"_">>, <<"-">>, [global]));
fileStem(Name) ->
    fileStem(toBinary(Name)).

namesEqual(A, B) ->
    normalizeName(A) =:= normalizeName(B)
        orelse toBinary(A) =:= toBinary(B)
        orelse fileStem(A) =:= fileStem(B).

toAtomSafe(A) when is_atom(A) -> A;
toAtomSafe(B) when is_binary(B) ->
    try binary_to_existing_atom(B, utf8) catch _:_ -> undefined end;
toAtomSafe(L) when is_list(L) ->
    toAtomSafe(unicode:characters_to_binary(L));
toAtomSafe(_) -> undefined.

toBinary(B) when is_binary(B) -> B;
toBinary(A) when is_atom(A) -> atom_to_binary(A, utf8);
toBinary(L) when is_list(L) -> unicode:characters_to_binary(L);
toBinary(I) when is_integer(I) -> integer_to_binary(I);
toBinary(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

toList(B) when is_binary(B) -> unicode:characters_to_list(B);
toList(L) when is_list(L) -> L;
toList(A) when is_atom(A) -> atom_to_list(A);
toList(Other) -> lists:flatten(io_lib:format("~p", [Other])).

safeLower(V) ->
    B = toBinary(V),
    try string:lowercase(B)
    catch _:_ -> B
    end.
