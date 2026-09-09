%%% @doc EUnit tests for alLlmCatalog.
-module(alLlmCatalog_tests).

-include_lib("eunit/include/eunit.hrl").

-define(setup, begin ok = alConfig:load(), ok = alLlmCatalog:cache_clear() end).

providers_not_empty_test() ->
    ?setup,
    Providers = alLlmCatalog:providers_for_web(),
    ?assert(length(Providers) >= 2).

deepseek_in_catalog_test() ->
    ?setup,
    Providers = alLlmCatalog:providers_for_web(),
    Deepseek = lists:keyfind(<<"deepseek">>, 1,
        [{maps:get(id, P), P} || P <- Providers]),
    ?assertMatch({<<"deepseek">>, _}, Deepseek),
    #{models := Models} = element(2, Deepseek),
    ?assert(lists:member(<<"deepseek-v4-flash">>, Models)).

no_openai_compatible_alias_test() ->
    ?setup,
    Ids = [maps:get(id, P) || P <- alLlmCatalog:providers_for_web()],
    ?assertNot(lists:member(<<"openai_compatible">>, Ids)),
    ?assert(lists:member(<<"openai">>, Ids)).

model_groups_shape_test() ->
    ?setup,
    [OpenAI | _] = [
        P || P <- alLlmCatalog:providers_for_web(), maps:get(id, P) =:= <<"openai">>
    ],
    ?assertMatch(#{modelGroups := [_ | _]}, OpenAI),
    #{modelGroups := [Group | _]} = OpenAI,
    ?assertMatch(#{label := _, models := [_ | _]}, Group).

active_provider_first_test() ->
    ?setup,
    Llm = alConfig:get(llm, #{}),
    case maps:get(provider, Llm, undefined) of
        undefined ->
            ok;
        Prov ->
            Ids = [maps:get(id, P) || P <- alLlmCatalog:providers_for_web()],
            case lists:member(atom_to_binary(Prov, utf8), Ids) of
                true ->
                    [First | _] = alLlmCatalog:providers_for_web(),
                    ?assertEqual(atom_to_binary(Prov, utf8), maps:get(id, First));
                %% 自定义 provider（如本地 ornith）不在目录中时无从置顶，跳过
                false ->
                    ok
            end
    end.
