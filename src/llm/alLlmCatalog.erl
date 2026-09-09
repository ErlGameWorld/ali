%%%-------------------------------------------------------------------
%%% @doc LLM 提供商 / 模型目录（Web UI 与 CLI 选型提示）。
%%%
%%% 默认数据来自 `priv/catalog/llm_providers.json`（不在 Erlang 或前端
%%% 硬编码）。可选 cfg 键 `llmCatalog` 覆盖：
%%%
%%% <ul>
%%%   <li>`file' —  alternate catalog JSON（相对 priv/ 或绝对路径）</li>
%%%   <li>`exclude' — 要隐藏的 provider id 列表</li>
%%%   <li>`providers' — map `ProviderId => #{name, defaultModel, models, modelGroups}'</li>
%%% </ul>
%%%
%%% 当前激活的 `{llm, #{provider, model, models, fastModel}}' 会合并进
%%% 对应 provider，并将该 provider 排到列表首位。
%%% @end
%%%-------------------------------------------------------------------
-module(alLlmCatalog).

-include_lib("kernel/include/file.hrl").

-export([providers_for_web/0, load/0, cache_clear/0]).

-define(CatalogKey, {?MODULE, catalog}).
-define(DefaultRel, "catalog/llm_providers.json").

%%--------------------------------------------------------------------
%% @doc `GET /api/llm/providers` 的 API 响应载荷。
%% @end
%%--------------------------------------------------------------------
-spec providers_for_web() -> [map()].
providers_for_web() ->
    [format_provider(P) || P <- merged_providers()].

%%--------------------------------------------------------------------
%% @doc 原始合并后的 provider map 列表（内部形态，键可为 atom/string）。
%% @end
%%--------------------------------------------------------------------
-spec load() -> [map()].
load() ->
    merged_providers().

%%--------------------------------------------------------------------
%% @doc 清除 persistent_term 缓存，下次访问时重建。
%% @end
%%--------------------------------------------------------------------
-spec cache_clear() -> ok.
cache_clear() ->
    persistent_term:erase(?CatalogKey),
    ok.

%% 从缓存取合并目录；签名变化（cfg/文件 mtime）时自动刷新。
merged_providers() ->
    case persistent_term:get(?CatalogKey, undefined) of
        {Providers, Sig} ->
            case catalog_signature() =:= Sig of
                true -> Providers;
                false -> refresh_cache()
            end;
        undefined ->
            refresh_cache()
    end.

%% 重建并写入 persistent_term 缓存。
refresh_cache() ->
    Providers = build_merged(),
    persistent_term:put(?CatalogKey, {Providers, catalog_signature()}),
    Providers.

%% 缓存失效签名：catalog 文件 mtime + llm/llmCatalog 配置快照。
catalog_signature() ->
    {file_mtime(catalog_path()), alConfig:get(llm, #{}), alConfig:get(llmCatalog, #{})}.

%% JSON 目录 + cfg 覆盖 + exclude + 运行时 llm 段合并。
build_merged() ->
    Base = load_json_catalog(),
    CatalogCfg = alConfig:get(llmCatalog, #{}),
    Excluded = exclude_set(CatalogCfg),
    WithOverrides = apply_catalog_overrides(Base, maps:get(providers, CatalogCfg, #{})),
    Filtered = [P || P <- WithOverrides, maps:get(id, P, <<>>) =/= <<>>],
    Visible = [P || P <- Filtered,
                    not sets:is_element(to_binary(maps:get(id, P)), Excluded)],
    apply_llm_runtime(Visible, alConfig:get(llm, #{})).

%% 读取 priv/catalog/llm_providers.json（或 cfg 指定路径）。
load_json_catalog() ->
    Path = catalog_path(),
    case file:read_file(Path) of
        {ok, Bin} ->
            parse_catalog_json(Bin);
        {error, Reason} ->
            error_logger:warning_msg(
                "alLlmCatalog: failed to read ~s (~p), using empty catalog~n",
                [Path, Reason]
            ),
            []
    end.

%% 解析 catalog 文件路径（默认 priv/catalog/llm_providers.json）。
catalog_path() ->
    CatalogCfg = alConfig:get(llmCatalog, #{}),
    case maps:get(file, CatalogCfg, undefined) of
        undefined ->
            alConfig:privFile(?DefaultRel);
        Rel when is_list(Rel) ->
            resolve_catalog_path(Rel);
        Bin when is_binary(Bin) ->
            resolve_catalog_path(binary_to_list(Bin))
    end.

%% 相对路径基于 priv/，绝对路径原样使用。
resolve_catalog_path(Path) ->
    case filename:pathtype(Path) of
        absolute -> Path;
        _ -> alConfig:privFile(Path)
    end.

%% 解析 JSON 中 providers 数组为内部 map 列表。
parse_catalog_json(Bin) ->
    try alJson:decode(Bin) of
        #{<<"providers">> := Providers} when is_list(Providers) ->
            [normalize_provider(P) || P <- Providers, is_map(P)];
        #{providers := Providers} when is_list(Providers) ->
            [normalize_provider(P) || P <- Providers, is_map(P)];
        _ ->
            error_logger:warning_msg("alLlmCatalog: invalid catalog JSON~n"),
            []
    catch
        _:_ ->
            error_logger:warning_msg("alLlmCatalog: invalid catalog JSON~n"),
            []
    end.

%% 单条 provider JSON → 内部 #{id,name,defaultModel,models,modelGroups}。
normalize_provider(P) ->
    Id = to_binary(maps:get(<<"id">>, P, maps:get(id, P, <<>>))),
    Name = to_binary(maps:get(<<"name">>, P, maps:get(name, P, Id))),
    DefaultModel = to_binary(maps:get(<<"defaultModel">>, P,
        maps:get(defaultModel, P, <<>>))),
    ModelGroups = normalize_model_groups(
        maps:get(<<"modelGroups">>, P, maps:get(modelGroups, P, undefined))
    ),
    Models = case ModelGroups of
        [] ->
            flat_models(maps:get(<<"models">>, P, maps:get(models, P, [])));
        Groups ->
            models_from_groups(Groups)
    end,
    #{
        id => Id,
        name => Name,
        defaultModel => first_non_empty([DefaultModel | Models]),
        models => Models,
        modelGroups => ModelGroups
    }.

%% modelGroups 列表归一化；非法项过滤。
normalize_model_groups(undefined) ->
    [];
normalize_model_groups(Groups) when is_list(Groups) ->
    lists:filtermap(fun normalize_model_group/1, Groups);
normalize_model_groups(_) ->
    [].

%% 单组 {label, models} 归一化。
normalize_model_group(#{<<"label">> := Label} = G) ->
    normalize_model_group(#{label => Label, models => maps:get(<<"models">>, G, [])});
normalize_model_group(#{label := Label} = G) when is_map(G) ->
    RawModels = maps:get(models, G, maps:get(<<"models">>, G, [])),
    Models = [normalize_model_entry(M) || M <- RawModels, normalize_model_entry(M) =/= undefined],
    case Models of
        [] -> false;
        _ -> {true, #{label => to_binary(Label), models => Models}}
    end;
normalize_model_group(_) ->
    false.

%% 单条模型条目 {id, label}；空 id 丢弃。
normalize_model_entry(#{<<"id">> := Id} = M) ->
    normalize_model_entry(#{id => Id, label => maps:get(<<"label">>, M, Id)});
normalize_model_entry(#{id := Id} = M) when is_map(M) ->
    BinId = to_binary(Id),
    case BinId of
        <<>> -> undefined;
        _ ->
            Label = to_binary(maps:get(label, M, maps:get(<<"label">>, M, BinId))),
            #{id => BinId, label => Label}
    end;
normalize_model_entry(Id) when is_binary(Id); is_list(Id) ->
    BinId = to_binary(Id),
    case BinId of
        <<>> -> undefined;
        _ -> #{id => BinId, label => BinId}
    end;
normalize_model_entry(_) ->
    undefined.

%% 从分组列表扁平化出全部 model id。
models_from_groups(Groups) ->
    unique_bins([maps:get(id, M) || #{models := Ms} <- Groups, M <- Ms]).

%% cfg providers 覆盖合并进 JSON 目录（保留 JSON 顺序，cfg-only 项追加到末尾）。
apply_catalog_overrides(Providers, Overrides) when map_size(Overrides) =:= 0 ->
    Providers;
apply_catalog_overrides(Providers, Overrides) when is_map(Overrides) ->
    Index = maps:from_list([{maps:get(id, P), P} || P <- Providers]),
    MergedIndex = maps:fold(fun(ProvKey, Override, Acc) ->
        Id = to_binary(ProvKey),
        Base = maps:get(Id, Acc, #{id => Id, name => Id, defaultModel => <<>>,
                                    models => [], modelGroups => []}),
        maps:put(Id, merge_provider(Base, Override), Acc)
    end, Index, Overrides),
    %% Preserve JSON order, append cfg-only providers at end
    Known = sets:from_list([maps:get(id, P) || P <- Providers]),
    Ordered = [maps:get(maps:get(id, P), MergedIndex, P) || P <- Providers],
    Extra = [maps:get(K, MergedIndex)
             || K <- maps:keys(MergedIndex),
                not sets:is_element(K, Known)],
    Ordered ++ Extra.

%% 单 provider 与 cfg override map 合并。
merge_provider(Base, Override) when is_map(Override) ->
    Id = maps:get(id, Base),
    Name = pick_bin(name, Override, maps:get(name, Base)),
    DefaultModel = pick_bin(defaultModel, Override, maps:get(defaultModel, Base)),
    ModelGroups = case maps:get(modelGroups, Override,
        maps:get(<<"modelGroups">>, Override, undefined)) of
        undefined ->
            maps:get(modelGroups, Base, []);
        G ->
            normalize_model_groups(G)
    end,
    ExtraModels = flat_models(maps:get(models, Override,
        maps:get(<<"models">>, Override, []))),
    BaseModels = maps:get(models, Base, []),
    Models = case {ModelGroups, ExtraModels} of
        {[], []} -> BaseModels;
        {[], _} -> unique_bins(ExtraModels ++ BaseModels);
        {Groups, _} ->
            unique_bins(ExtraModels ++ models_from_groups(Groups) ++ BaseModels)
    end,
    FinalGroups = if
        ModelGroups =:= [] -> maps:get(modelGroups, Base, []);
        true -> ModelGroups
    end,
    #{
        id => Id,
        name => Name,
        defaultModel => first_non_empty([DefaultModel | Models]),
        models => Models,
        modelGroups => FinalGroups
    }.

%% 将当前 llm 配置中的 provider/model/models 合并进对应项并排首位。
apply_llm_runtime(Providers, Llm) when is_map(Llm) ->
    Identity = alLlmRouter:chainDisplayIdentity(),
    ActiveProv = identityOrCfg(Identity, provider, Llm),
    DefaultModel = identityOrCfg(Identity, model, Llm),
    FastModel = to_binary(maps:get(fastModel, Llm, <<>>)),
    CfgModels = flat_models(maps:get(models, Llm, [])),
    ExtraModels = unique_bins([DefaultModel, FastModel | CfgModels]),
    Updated = lists:map(fun(P) ->
        case maps:get(id, P) =:= ActiveProv of
            true ->
                Models = unique_bins(ExtraModels ++ maps:get(models, P, [])),
                Def = first_non_empty([DefaultModel, maps:get(defaultModel, P)]),
                P#{models => Models, defaultModel => Def};
            false ->
                P
        end
    end, Providers),
    reorder_active(Updated, ActiveProv).

%% 激活 provider 排到列表最前。
reorder_active(Providers, <<>>) ->
    Providers;
reorder_active(Providers, ActiveProv) ->
    case lists:splitwith(fun(P) -> maps:get(id, P) =/= ActiveProv end, Providers) of
        {All, []} -> All;
        {Before, [Active | Rest]} -> [Active | Before ++ Rest]
    end.

%% 内部 map → Web API 响应 map（含可选 modelGroups）。
format_provider(P) ->
    Base = #{
        id => maps:get(id, P),
        name => maps:get(name, P),
        defaultModel => maps:get(defaultModel, P),
        models => maps:get(models, P, [])
    },
    case maps:get(modelGroups, P, []) of
        [] -> Base;
        Groups ->
            Base#{
                modelGroups => [
                    #{
                        label => maps:get(label, G),
                        models => [
                            #{id => maps:get(id, M), label => maps:get(label, M)}
                            || M <- maps:get(models, G)
                        ]
                    }
                    || G <- Groups
                ]
            }
    end.

%% exclude 列表 → set。
exclude_set(CatalogCfg) ->
    Raw = maps:get(exclude, CatalogCfg, maps:get(<<"exclude">>, CatalogCfg, [])),
    lists:foldl(fun(E, Acc) ->
        sets:add_element(to_binary(E), Acc)
    end, sets:new(), ensure_list(Raw)).

%% 模型名列表扁平化并去重。
flat_models(undefined) -> [];
flat_models(L) when is_list(L) ->
    unique_bins([to_binary(M) || M <- L, M =/= undefined, M =/= <<>>, M =/= ""]);
flat_models(_) ->
    [].

%% binary 列表去重（保序）。
unique_bins(List) ->
    lists:reverse(lists:foldl(fun
        (<<>>, Acc) -> Acc;
        (B, Acc) ->
            case lists:member(B, Acc) of
                true -> Acc;
                false -> [B | Acc]
            end
    end, [], List)).

%% chain 身份字段优先，否则回退 llm 段（向后兼容旧 cfg）。
identityOrCfg(Identity, Key, Llm) ->
    to_binary(first_non_empty([
        to_binary(maps:get(Key, Identity, <<>>)),
        to_binary(maps:get(Key, Llm, <<>>))
    ])).

%% 取列表中第一个非空值。
first_non_empty([]) -> <<>>;
first_non_empty([<<>> | Rest]) -> first_non_empty(Rest);
first_non_empty(["" | Rest]) -> first_non_empty(Rest);
first_non_empty([undefined | Rest]) -> first_non_empty(Rest);
first_non_empty([H | _]) -> to_binary(H).

%% override map 中按 atom/binary 键取值。
pick_bin(Key, Override, Default) ->
    case maps:get(Key, Override, maps:get(to_binary(Key), Override, undefined)) of
        undefined -> Default;
        V -> to_binary(V)
    end.

%% 安全转为 binary。
to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_list(V) -> list_to_binary(V);
to_binary(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_binary(V) when is_integer(V) -> integer_to_binary(V);
to_binary(_) -> <<>>.

ensure_list(L) when is_list(L) -> L;
ensure_list(X) -> [X].

%% catalog 文件 mtime（读失败返回 undefined）。
file_mtime(Path) ->
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, #file_info{mtime = Mtime}} -> Mtime;
        {error, _} -> undefined
    end.
