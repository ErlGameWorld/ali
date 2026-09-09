%%%-------------------------------------------------------------------
%% @doc 预设技能（工作流模板）。
%%
%% 每个 skill = #{name, desc, promptExtra, mode, planTemplate,
%% triggers?, tools?}。`match/1' 按触发关键词打分并返回前
%% `maxActiveSkills' 个名称；`inject/2' 将 `promptExtra' 追加到
%% 基础系统提示。
%%
%% 外部技能从 `priv/skills/*.md' 加载（YAML frontmatter + Markdown 正文，
%% 由 `splitFrontmatter/1' 解析）。
%% @end
%%%-------------------------------------------------------------------

-module(alSkill).

-export([
    list/0,
    lookup/1,
    match/1,
    match/2,
    inject/2,
    load/1,
    splitFrontmatter/1,
    builtin/0,
    cacheClear/0,
    globMatch/2,
    compareVersions/2,
    aliVersion/0
]).

-define(DefaultSkillsDir, "priv/skills").
-define(DefaultMaxActive, 2).
-define(CacheKey, {?MODULE, allSkills}).

-type skill_name() :: atom() | binary().

-type skill() :: #{
    name := skill_name(),
    desc := binary(),
    promptExtra := binary(),
    mode := ask | edit | exec,
    planTemplate := [binary()],
    triggers => [binary()],
    tools => [atom()],
    version => binary(),
    minAliVersion => binary(),
    requires => [skill_name()],
    conflicts => [skill_name()],
    globs => [binary()]
}.

-export_type([skill/0]).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 列出所有技能（内置 + 外部）的名称与简短描述。
%%
%% @return [{Name, Desc}] 名称与描述二元组列表
%% @end
%%--------------------------------------------------------------------
-spec list() -> [{skill_name(), binary()}].
list() ->
    [{Name, maps:get(desc, S, <<>>)} || {Name, S} <- allSkills()].

%%--------------------------------------------------------------------
%% @doc
%% 按名称查找技能。
%%
%% @param Name 技能名称（atom/binary/list）
%% @return {ok, Skill} 找到时返回技能 map；{error, notFound} 未找到
%% @end
%%--------------------------------------------------------------------
-spec lookup(term()) -> {ok, skill()} | {error, notFound}.
lookup(Name0) ->
    Name = normalizeSkillName(Name0),
    case lists:filter(fun({SkillName, _}) -> skillNamesEqual(Name, SkillName) end, allSkills()) of
        [{_, S} | _] ->
            {ok, S};
        [] -> {error, notFound}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 对查询按触发词/glob 命中打分，返回得分>0 且排名前 maxActiveSkills
%% 的技能名称。自动从查询文本提取路径；过滤不兼容的 minAliVersion/requires。
%%
%% @param Query 用户查询文本（binary）
%% @return [skill_name()] 命中技能名称列表，按得分降序
%% @end
%%--------------------------------------------------------------------
-spec match(binary()) -> [skill_name()].
match(Query) when is_binary(Query) ->
    match(Query, #{});
match(Query) ->
    match(toBinary(Query), #{}).

%%--------------------------------------------------------------------
%% @doc
%% 带选项的匹配。Opts 可含：
%% - `paths`：已知文件路径列表（@path / 工作上下文）
%% - `aliVersion`：覆盖本机版本（测试用）
%% @end
%%--------------------------------------------------------------------
-spec match(binary(), map()) -> [skill_name()].
match(Query, Opts) when is_binary(Query), is_map(Opts) ->
    Paths = lists:usort(
        [toBinary(P) || P <- maps:get(paths, Opts, []) ++ extractPaths(Query),
                        toBinary(P) =/= <<>>]),
    AliVer = maps:get(aliVersion, Opts, aliVersion()),
    All0 = allSkills(),
    All = [{N, S} || {N, S} <- All0, isCompatible(S, AliVer, All0)],
    Scored = [{Name, score(Query, Paths, Skill)} || {Name, Skill} <- All],
    Matched = [{Name, S} || {Name, S} <- Scored, S > 0],
    Sorted = lists:sort(fun({_, A}, {_, B}) -> A >= B end, Matched),
    Picked = pickWithoutConflicts(Sorted, All, []),
    lists:sublist(Picked, maxActive()).

%%--------------------------------------------------------------------
%% @doc 当前 ali 应用版本（`ali.app` vsn），读失败回退 `<<"0.0.0">>`。
%% @end
%%--------------------------------------------------------------------
-spec aliVersion() -> binary().
aliVersion() ->
    try
        case application:get_key(ali, vsn) of
            {ok, V} -> toBinary(V);
            _ -> <<"0.1.0">>
        end
    catch
        _:_ -> <<"0.1.0">>
    end.

%%--------------------------------------------------------------------
%% @doc
%% 比较语义化版本：V1>V2→1，相等→0，V1<V2→-1。非法段按 0。
%% @end
%%--------------------------------------------------------------------
-spec compareVersions(binary() | string(), binary() | string()) -> -1 | 0 | 1.
compareVersions(A, B) ->
    PA = versionParts(A),
    PB = versionParts(B),
    compareParts(PA, PB).

%%--------------------------------------------------------------------
%% @doc
%% 简易 glob 匹配：支持 `*`（非路径分隔）、`**`（跨目录）、`?`。
%% 路径统一为正斜杠、小写比较。
%% @end
%%--------------------------------------------------------------------
-spec globMatch(binary() | string(), binary() | string()) -> boolean().
globMatch(Glob, Path) ->
    G = normalizePath(Glob),
    P = normalizePath(Path),
    case globToRe(G) of
        {ok, Re} ->
            try re:run(P, Re, [{capture, none}, unicode]) =/= nomatch
            catch _:_ -> false
            end;
        error ->
            false
    end.

%%--------------------------------------------------------------------
%% @doc
%% 将指定技能的 promptExtra 内容追加到基础 system prompt 之后。
%% 多个技能段落以空行分隔；空技能列表时原样返回基础 prompt。
%%
%% @param BasePrompt 基础 system prompt
%% @param SkillNames 待注入的技能名称列表
%% @return binary() 合并后的 system prompt
%% @end
%%--------------------------------------------------------------------
-spec inject(binary(), [skill_name()]) -> binary().
inject(BasePrompt, SkillNames) ->
    Sections = [Body || Name <- SkillNames,
                        Name =/= undefined,
                        begin Body = skillBody(Name), Body =/= <<>> end],
    case Sections of
        [] -> BasePrompt;
        _ ->
            Joined = lists:foldl(fun(Body, Acc) ->
                case Acc of
                    <<>> -> Body;
                    _ -> <<Acc/binary, "\n\n", Body/binary>>
                end
            end, <<>>, Sections),
            <<BasePrompt/binary, Joined/binary>>
    end.

%%--------------------------------------------------------------------
%% @doc
%% 从 skills 目录加载单个 Markdown 技能文件并解析为 skill map。
%%
%% @param Name 技能名称（对应文件 <Name>.md）
%% @return {ok, Skill} | {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec load(skill_name()) -> {ok, skill()} | {error, term()}.
load(Name0) ->
    Name = normalizeSkillName(Name0),
    Dir = skillsDir(),
    Path = filename:join(Dir, skillFileName(Name) ++ ".md"),
    case file:read_file(Path) of
        {ok, Bin} -> {ok, parseSkillMd(Name, Bin)};
        {error, _} = E -> E
    end.

%%%===================================================================
%%% Internal: aggregation
%%%===================================================================

%% 汇总所有技能：内置技能 + 从 skills 目录加载的外部技能。
%% 结果通过 persistent_term 缓存，避免每次调用都重读文件系统。
%% 调用 {@link cacheClear/0} 可强制刷新。
allSkills() ->
    case persistent_term:get(?CacheKey, undefined) of
        undefined ->
            All = builtin() ++ loadExternal(),
            persistent_term:put(?CacheKey, All),
            All;
        Cached ->
            Cached
    end.

%%--------------------------------------------------------------------
%% @doc
%% 清除缓存的技能列表，下次 {@link allSkills/0} 调用会重新加载。
%%
%% @return `ok'
%% @end
%%--------------------------------------------------------------------
-spec cacheClear() -> ok.
cacheClear() ->
    persistent_term:erase(?CacheKey),
    ok.

%% 扫描 skills 目录下所有 .md 文件并加载。
%% 对外部技能名只复用已存在原子；否则保留为 binary，避免创建新原子。
loadExternal() ->
    Dir = skillsDir(),
    case file:list_dir(Dir) of
        {ok, Entries} ->
            MdFiles = [F || F <- Entries, filename:extension(F) =:= ".md"],
            lists:foldl(fun(F, Acc) ->
                Name = normalizeSkillName(filename:rootname(F)),
                case load(Name) of
                    {ok, S} -> [{Name, S} | Acc];
                    _ -> Acc
                end
            end, [], MdFiles);
        _ ->
            []
    end.

%% 将 Markdown 文件内容解析为 skill map：拆分 frontmatter 与正文，
%% 提取 desc/triggers/tools/mode/version/globs/requires 等字段。
parseSkillMd(Name, Bin) ->
    {Meta, Body} = splitFrontmatter(Bin),
    Triggers = proplists:get_value(triggers, Meta, []),
    Tools = proplists:get_value(tools, Meta, []),
    Globs = firstMetaList(Meta, [globs, glob]),
    Requires = firstMetaList(Meta, [requires, require]),
    Conflicts = firstMetaList(Meta, [conflicts, conflict]),
    Mode = case proplists:get_value(mode, Meta, ask) of
        <<"edit">> -> edit;
        <<"exec">> -> exec;
        edit -> edit;
        exec -> exec;
        _ -> ask
    end,
    Base = #{
        name => Name,
        desc => toBinary(proplists:get_value(desc, Meta, <<>>)),
        promptExtra => Body,
        mode => Mode,
        planTemplate => [],
        triggers => [toBinary(T) || T <- ensureList(Triggers)],
        tools => [toAtom(T) || T <- ensureList(Tools)],
        globs => [toBinary(G) || G <- ensureList(Globs)],
        requires => [normalizeSkillName(R) || R <- ensureList(Requires)],
        conflicts => [normalizeSkillName(C) || C <- ensureList(Conflicts)]
    },
    Base1 = case metaGet(Meta, version) of
        [] -> Base;
        <<>> -> Base;
        undefined -> Base;
        V when is_binary(V); is_list(V); is_atom(V) -> Base#{version => toBinary(V)};
        _ -> Base
    end,
    case metaGet(Meta, minAliVersion) of
        [] -> Base1;
        <<>> -> Base1;
        undefined -> Base1;
        Min when is_binary(Min); is_list(Min); is_atom(Min) ->
            Base1#{minAliVersion => toBinary(Min)};
        _ -> Base1
    end.

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

%%--------------------------------------------------------------------
%% @doc
%% 将带 YAML frontmatter 的 Markdown 拆分为元数据 proplists 和正文 binary。
%% frontmatter 以 "---\n" 包裹，无 frontmatter 时返回空元数据与原文。
%%
%% @param Bin 文件二进制内容
%% @return {MetaList, Body}
%% @end
%%--------------------------------------------------------------------
-spec splitFrontmatter(binary()) -> {[{atom(), term()}], binary()}.
splitFrontmatter(Bin) ->
    Lf = binary:replace(Bin, <<"\r\n">>, <<"\n">>, [global]),
    case binary:split(Lf, <<"---\n">>) of
        [<<>>, Rest] ->
            case binary:split(Rest, <<"---\n">>) of
                [MetaBin, Body] -> {parseYamlMeta(MetaBin), Body};
                _ -> {[], Bin}
            end;
        _ -> {[], Bin}
    end.

%% 将 frontmatter 文本按行解析为 key-value proplists。
parseYamlMeta(Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global, trim]),
    lists:flatmap(fun parseYamlLine/1, Lines).

%% 解析单行 YAML：支持简单 "key: value" 与 "key: [a, b, c]" 数组形式。
%% 无冒号的行被忽略。
parseYamlLine(Line) ->
    case binary:split(Line, <<":">>) of
        [K, V] ->
            Key = try binary_to_existing_atom(string:trim(K), utf8) catch _:_ -> string:trim(K) end,
            Val = string:trim(V),
            case Val of
                <<"[", _/binary>> ->
                    Inner = binary:replace(Val, [<<"[">>, <<"]">>, <<"\"">>], <<>>, [global]),
                    RawItems = [string:trim(I)
                                || I <- binary:split(Inner, <<",">>, [global, trim]),
                                   byte_size(I) > 0],
                    [{Key, RawItems}];
                _ ->
                    [{Key, case Val of <<>> -> <<>>; _ -> Val end}]
            end;
        _ -> []
    end.

%% 计算查询命中技能触发词 + glob 的得分（大小写不敏感）。
%% 触发词命中 +1；任一 glob 命中路径 +2（便于「当前文件」场景自动挂载）。
score(Query, Paths, Skill) ->
    Q = safeLower(Query),
    Triggers = maps:get(triggers, Skill, []),
    TriggerScore = lists:foldl(fun(T, Acc) ->
        Needle = safeLower(T),
        try
            case binary:match(Q, Needle) of
                nomatch -> Acc;
                _ -> Acc + 1
            end
        catch
            _:_ -> Acc
        end
    end, 0, Triggers),
    Globs = maps:get(globs, Skill, []),
    GlobScore = case Globs of
        [] -> 0;
        _ when Paths =:= [] -> 0;
        _ ->
            case lists:any(fun(G) ->
                lists:any(fun(P) -> globMatch(G, P) end, Paths)
            end, Globs) of
                true -> 2;
                false -> 0
            end
    end,
    TriggerScore + GlobScore.

%% 版本 / requires 兼容过滤。
isCompatible(Skill, AliVer, AllSkills) ->
    MinOk = case maps:get(minAliVersion, Skill, undefined) of
        undefined -> true;
        Min -> compareVersions(AliVer, Min) >= 0
    end,
    ReqOk = case maps:get(requires, Skill, []) of
        [] -> true;
        Reqs ->
            Names = [N || {N, _} <- AllSkills],
            lists:all(fun(R) ->
                lists:any(fun(N) -> skillNamesEqual(R, N) end, Names)
            end, Reqs)
    end,
    MinOk andalso ReqOk.

%% 按得分挑选，跳过与已选技能 conflicts 的项。
pickWithoutConflicts([], _All, Acc) ->
    lists:reverse(Acc);
pickWithoutConflicts([{Name, _Score} | Rest], All, Acc) ->
    Skill = case lists:keyfind(Name, 1, All) of
        {_, S} -> S;
        false -> #{}
    end,
    Conflicts = maps:get(conflicts, Skill, []),
    Clash = lists:any(fun(C) ->
        lists:any(fun(Picked) -> skillNamesEqual(C, Picked) end, Acc)
    end, Conflicts)
        orelse lists:any(fun(Picked) ->
            case lists:keyfind(Picked, 1, All) of
                {_, PS} ->
                    lists:any(fun(C) -> skillNamesEqual(C, Name) end,
                              maps:get(conflicts, PS, []));
                false -> false
            end
        end, Acc),
    case Clash of
        true -> pickWithoutConflicts(Rest, All, Acc);
        false -> pickWithoutConflicts(Rest, All, [Name | Acc])
    end.

%% 从查询提取路径：@path xxx、裸 *.erl / 含 / 的相对路径。
extractPaths(Query) when is_binary(Query) ->
    Q = Query,
    %% 注意：global + {capture, all_list, _} 在 OTP 会 badarg；用 all。
    FromAt = case re:run(Q, <<"@path\\s+(\\S+)">>,
                         [global, {capture, all, binary}]) of
        {match, Rows} -> [P || [_, P] <- Rows];
        _ -> []
    end,
    FromErl = case re:run(Q, <<"([A-Za-z0-9_./\\\\-]+\\.erl)">>,
                          [global, {capture, all, binary}]) of
        {match, Rows2} -> [P || [_, P] <- Rows2];
        _ -> []
    end,
    FromAt ++ FromErl;
extractPaths(_) ->
    [].

normalizePath(P) ->
    B0 = safeLower(toBinary(P)),
    binary:replace(B0, <<"\\">>, <<"/">>, [global]).

%% glob → 锚定正则。逐字符转换，避免 `*` 替换误伤 `(?:.*/)?`。
globToRe(Glob) when is_binary(Glob) ->
    Body = iolist_to_binary(globChars(unicode:characters_to_list(Glob))),
    Pat = case Glob of
        <<$/, _/binary>> -> <<"^", Body/binary, "$">>;
        _ -> <<"^(?:.*/)?", Body/binary, "$">>
    end,
    {ok, Pat};
globToRe(_) ->
    error.

globChars([]) -> [];
globChars([$*, $* | Rest]) ->
    case Rest of
        [$/ | Rest2] -> [<<"(?:.*/)?">> | globChars(Rest2)];
        _ -> [<<".*">> | globChars(Rest)]
    end;
globChars([$* | Rest]) -> [<<"[^/]*">> | globChars(Rest)];
globChars([$? | Rest]) -> [<<".">> | globChars(Rest)];
globChars([C | Rest]) ->
    [escapeGlobChar(C) | globChars(Rest)].

escapeGlobChar(C) when C =:= $.; C =:= $^; C =:= $$; C =:= $+; C =:= $|;
                       C =:= $(; C =:= $); C =:= ${; C =:= $}; C =:= $[;
                       C =:= $]; C =:= $\\ ->
    [$\\, C];
escapeGlobChar(C) ->
    [C].

versionParts(V) ->
    Bin = toBinary(V),
    %% 去掉前缀 v
    Bin1 = case Bin of
        <<"v", Rest/binary>> -> Rest;
        <<"V", Rest/binary>> -> Rest;
        _ -> Bin
    end,
    Parts = binary:split(Bin1, <<".">>, [global]),
    [try binary_to_integer(P) catch _:_ -> 0 end || P <- Parts].

compareParts([], []) -> 0;
compareParts([A | RA], [B | RB]) when A =:= B -> compareParts(RA, RB);
compareParts([A | _], [B | _]) when A > B -> 1;
compareParts([A | _], [B | _]) when A < B -> -1;
compareParts([], [_ | _]) -> -1;
compareParts([_ | _], []) -> 1.

safeLower(V) ->
    B = toBinary(V),
    try string:lowercase(B)
    catch _:_ -> B
    end.

%% 取技能的 promptExtra 正文；不存在或为空时返回 <<>>。
skillBody(Name) ->
    case lookup(Name) of
        {ok, #{promptExtra := Body}} when is_binary(Body), Body =/= <<>> -> Body;
        _ -> <<>>
    end.

%% 读取配置中允许同时激活的最大技能数，默认 ?DefaultMaxActive，非法值回退默认。
maxActive() ->
    Agent = alConfig:get(agent, #{}),
    case maps:get(maxActiveSkills, Agent, ?DefaultMaxActive) of
        N when is_integer(N), N > 0 -> N;
        _ -> ?DefaultMaxActive
    end.

%% 读取配置中的 skills 目录，相对项目根目录解析，默认 ?DefaultSkillsDir。
skillsDir() ->
    Agent = alConfig:get(agent, #{}),
    Dir = maps:get(skillsDir, Agent, ?DefaultSkillsDir),
    filename:join(alConfig:root(), Dir).

skillFileName(Name) when is_atom(Name) -> atom_to_list(Name);
skillFileName(Name) when is_binary(Name) -> binary_to_list(Name).

normalizeSkillName(Name) when is_atom(Name) ->
    Name;
normalizeSkillName(Name) when is_binary(Name) ->
    try binary_to_existing_atom(Name, utf8) catch _:_ -> Name end;
normalizeSkillName(Name) when is_list(Name) ->
    normalizeSkillName(unicode:characters_to_binary(Name));
normalizeSkillName(Name) ->
    normalizeSkillName(toBinary(Name)).

skillNamesEqual(A, B) ->
    normalizeSkillName(A) =:= normalizeSkillName(B).

%% binary 原样返回。
toBinary(B) when is_binary(B) -> B;
%% list 转 binary。
toBinary(L) when is_list(L) -> unicode:characters_to_binary(L);
%% atom 转 binary。
toBinary(A) when is_atom(A) -> atom_to_binary(A, utf8);
%% 其它类型用 ~p 格式化为 binary。
toBinary(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).

%% binary 转 existing atom，失败保留 binary 原值。
toAtom(B) when is_binary(B) ->
    try binary_to_existing_atom(B, utf8) catch _:_ -> B end;
%% atom 原样返回。
toAtom(A) when is_atom(A) -> A;
%% list 转 existing atom，失败保留 list 原值。
toAtom(L) when is_list(L) ->
    try list_to_existing_atom(L) catch _:_ -> L end.

%%%===================================================================
%%% Built-in skill definitions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 返回内置技能定义列表：debug（调试）、refactor（重构）、explain（解释）。
%% 每个技能包含描述、模式、触发词、promptExtra 与 planTemplate。
%%
%% @return [{Name, Skill}] 内置技能名称与定义的二元组列表
%% @end
%%--------------------------------------------------------------------
-spec builtin() -> [{atom(), skill()}].
builtin() ->
    [
        {debug, #{
            name => debug,
            desc => <<"调试：复现、定位根因、修复并验证"/utf8>>,
            mode => exec,
            triggers => [<<"debug">>, <<"crash">>, <<"stacktrace">>,
                         <<"error">>, <<"fail">>, <<"调试"/utf8>>, <<"崩溃"/utf8>>],
            promptExtra => <<
                "\n## Debug：调试\n"
                "流程：\n"
                "1. 复现问题。\n"
                "2. 读代码定位根因。\n"
                "3. 最小修复（避免顺手大重构）。\n"
                "4. 验证修复。\n"
                "汇报：根因 → 改动 → 验证结果。"/utf8>>,
            planTemplate => [
                <<"复现问题"/utf8>>,
                <<"定位根因"/utf8>>,
                <<"最小修复"/utf8>>,
                <<"验证"/utf8>>
            ]
        }},
        {refactor, #{
            name => refactor,
            desc => <<"重构：先理解，再分步改，每步可编译"/utf8>>,
            mode => edit,
            triggers => [<<"refactor">>, <<"restructure">>, <<"extract">>,
                         <<"cleanup">>, <<"simplify">>, <<"重构"/utf8>>],
            promptExtra => <<
                "\n## 当前任务：重构\n"
                "原则：\n"
                "- 先用 findCallers 摸清调用关系。\n"
                "- 分步改，每步可编译。\n"
                "- 保持对外行为不变。\n"
                "- 每步后用 eunit 验证。\n"
                "汇报：动机 → 改动摘要 → 验证。"/utf8>>,
            planTemplate => [
                <<"分析现状"/utf8>>,
                <<"设计重构方案"/utf8>>,
                <<"分步重构"/utf8>>,
                <<"编译 + 测试验证"/utf8>>
            ]
        }},
        {explain, #{
            name => explain,
            desc => <<"解释：只读问答，讲清代码意图与设计"/utf8>>,
            mode => ask,
            triggers => [<<"explain">>, <<"what is">>, <<"how does">>,
                         <<"why">>, <<"understand">>, <<"解释"/utf8>>, <<"为什么"/utf8>>,
                         <<"怎么回事"/utf8>>, <<"含义"/utf8>>],
            promptExtra => <<
                "\n## 当前任务：解释\n"
                "只读回答代码相关问题，简洁：\n"
                "- 猜测前优先 gotoDef/resolveModule/searchCode。\n"
                "- 先给位置（file:line / MFA），再给关键引用。\n"
                "- 尊重 @module/@path/@mfa 锚点与 anchorSnippets。\n"
                "- 不要整文件粘贴源码。\n"
                "- 不确定就说明并再调工具。"/utf8>>,
            planTemplate => []
        }}
    ].
