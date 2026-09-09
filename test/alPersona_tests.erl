%%% @doc EUnit tests for alPersona.
-module(alPersona_tests).

-include_lib("eunit/include/eunit.hrl").

-define(setup, begin ok = alConfig:load(), ok = alPersona:cacheClear() end).

critical_exports_test() ->
    Exports = alPersona:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{list, 0}, {lookup, 1}, {resolve, 2}, {inject, 2},
                   {recommendedSkills, 1}, {rubric, 1}, {defaultIdentity, 0}]].

default_identity_mentions_erlang_test() ->
    Id = alPersona:defaultIdentity(),
    ?assert(binary:match(Id, <<"Erlang"/utf8>>) =/= nomatch).

inject_builtin_prefixes_discipline_test() ->
    Hard = <<"HARD_RULES">>,
    Out = alPersona:inject(Hard, builtin),
    ?assert(binary:match(Out, <<"HARD_RULES">>) =/= nomatch),
    ?assert(binary:match(Out, <<"Erlang"/utf8>>) =/= nomatch).

lookup_erlang_expert_test() ->
    ?setup,
    case alPersona:lookup(erlang_expert) of
        {ok, P} ->
            ?assert(is_map(P)),
            ?assert(byte_size(maps:get(promptExtra, P, <<>>)) > 20),
            ?assert(alPersona:recommendedSkills(P) =/= []);
        {error, notFound} ->
            %% priv/personas 未同步到 code:priv_dir 时跳过
            ok
    end.

resolve_default_test() ->
    ?setup,
    Cfg = #{personasEnabled => true, defaultPersona => erlang_expert,
            personasAutoMatch => false},
    case alPersona:resolve(<<"hello">>, #{agentCfg => Cfg}) of
        {ok, builtin} -> ok;
        {ok, P} when is_map(P) ->
            ?assertEqual(erlang_expert, maps:get(name, P))
    end.

resolve_disabled_builtin_test() ->
    ?setup,
    Cfg = #{personasEnabled => false},
    ?assertEqual({ok, builtin},
                 alPersona:resolve(<<"otp supervisor">>, #{agentCfg => Cfg})).

resolve_explicit_persona_test() ->
    ?setup,
    Cfg = #{personasEnabled => true, personasAutoMatch => true,
            defaultPersona => erlang_expert},
    case alPersona:lookup(<<"otp-architect">>) of
        {ok, _} ->
            {ok, P} = alPersona:resolve(<<"x">>, #{
                agentCfg => Cfg,
                persona => <<"otp-architect">>
            }),
            ?assert(is_map(P)),
            Name = maps:get(name, P),
            ?assert(alPersona:normalizeName(Name) =:= alPersona:normalizeName(otp_architect)
                    orelse Name =:= <<"otp_architect">>
                    orelse Name =:= otp_architect);
        {error, notFound} ->
            ok
    end.

score_triggers_test() ->
    P = #{triggers => [<<"supervisor">>, <<"otp">>]},
    ?assert(alPersona:score(<<"fix supervisor tree">>, P) >= 1),
    ?assertEqual(0, alPersona:score(<<"unrelated">>, P)).

build_system_prompt_includes_persona_or_identity_test() ->
    ?setup,
    Cfg = #{skillsEnabled => false, personasEnabled => true,
            defaultPersona => erlang_expert, personasAutoMatch => false},
    P = alContext:buildSystemPrompt(<<"q">>, #{agentCfg => Cfg}),
    ?assert(is_binary(P)),
    ?assert(byte_size(P) > 100),
    %% 硬纪律仍在（措辞与 alContext 的 ?HardDiscipline 保持同步）
    ?assert(binary:match(P, <<"语言：与用户同语"/utf8>>) =/= nomatch),
    %% 身份层存在（persona 文件或 builtin）
    ?assert(binary:match(P, <<"Erlang"/utf8>>) =/= nomatch).
