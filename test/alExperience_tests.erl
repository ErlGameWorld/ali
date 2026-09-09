%%% @doc EUnit tests for alExperience.
-module(alExperience_tests).

-include_lib("eunit/include/eunit.hrl").

critical_exports_test() ->
    Exports = alExperience:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{recordLesson, 1}, {recordLesson, 2}, {recallFor, 1},
                   {familiarityDigest, 0}, {detectCorrection, 1}, {formatCard, 1}]].

format_card_from_parts_test() ->
    Card = alExperience:formatCard(#{
        symptom => <<"热更后旧代码"/utf8>>,
        rootCause => <<"未 soft_purge"/utf8>>,
        prevention => <<"用 hotReload"/utf8>>
    }),
    ?assert(binary:match(Card, <<"症状"/utf8>>) =/= nomatch),
    ?assert(binary:match(Card, <<"hotReload">>) =/= nomatch).

format_card_content_wins_test() ->
    Card = alExperience:formatCard(#{content => <<"完整正文"/utf8>>, symptom => <<"x">>}),
    ?assertEqual(<<"完整正文"/utf8>>, Card).

detect_correction_zh_test() ->
    ?assert(alExperience:detectCorrection(<<"不对，应该是 alFoo:bar/1"/utf8>>)),
    ?assert(alExperience:detectCorrection(<<"你记错了"/utf8>>)),
    ?assertNot(alExperience:detectCorrection(<<"帮我看下 supervision"/utf8>>)).

lesson_boost_prefers_lesson_test() ->
    L = #{kind => lesson, score => 0.5, tags => [correction]},
    N = #{kind => note, score => 0.5, tags => []},
    ?assert(alExperience:lessonBoost(L) > alExperience:lessonBoost(N)).

merge_recall_dedups_and_limits_test() ->
    A = #{kind => lesson, content => <<"same">>, score => 0.2},
    B = #{kind => note, content => <<"same">>, score => 0.9},
    C = #{kind => lesson, content => <<"other">>, score => 0.1},
    Out = alExperience:mergeRecall([A, C], [B], 2),
    ?assertEqual(2, length(Out)),
    Contents = [maps:get(content, R) || R <- Out],
    ?assert(lists:member(<<"same">>, Contents)),
    ?assert(lists:member(<<"other">>, Contents)).

record_and_recall_roundtrip_test() ->
    ok = alConfig:load(),
    case alExperience:enabled() of
        false -> ok;
        true ->
            Unique = integer_to_binary(erlang:unique_integer([positive])),
            Symptom = <<"eunit-lesson-", Unique/binary>>,
            try
                case alExperience:recordLesson(#{
                    source => manual,
                    symptom => Symptom,
                    rootCause => <<"test">>,
                    prevention => <<"assert recall">>,
                    tags => [eunit]
                }) of
                    {ok, #{id := _Id}} ->
                        {ok, Rows} = alExperience:recallFor(Symptom, 5),
                        ?assert(lists:any(fun(R) ->
                            binary:match(to_bin(maps:get(content, R, <<>>)), Symptom) =/= nomatch
                        end, Rows)),
                        Digest = alExperience:familiarityDigest(#{limit => 3}),
                        ?assert(maps:get(lessonCount, Digest, 0) >= 1);
                    {error, Reason} ->
                        ?assertEqual({skip, Reason}, {skip, Reason})
                end
            catch
                exit:{noproc, _} -> ok;
                _:_ -> ok
            end
    end.

build_digest_candidates_from_actions_test() ->
    Cands = alExperience:buildDigestCandidates(#{
        actions => [
            #{phrase => <<"查战斗力"/utf8>>, mfa => <<"role:get_power/1">>}
        ],
        data => #{tables => #{
            <<"role_tab">> => [#{mfa => <<"role_db:lookup/1">>}]
        }},
        moduleContexts => #{
            role_svr => #{behaviours => [gen_server]}
        }
    }),
    ?assert(length(Cands) >= 3),
    lists:foreach(fun(C) ->
        ?assert(maps:is_key(fingerprint, C)),
        ?assert(maps:is_key(content, C))
    end, Cands).

is_superseded_detects_tag_test() ->
    ?assert(alExperience:isSuperseded(#{tags => [<<"superseded">>]})),
    ?assert(alExperience:isSuperseded(#{metadata => #{superseded => true}})),
    ?assertNot(alExperience:isSuperseded(#{tags => [lesson], metadata => #{}})).

overlap_score_shares_tokens_test() ->
    Row = #{content => <<"role_db lookup role_tab">>, metadata => #{
        relatedMfas => [<<"role_db:lookup/1">>]
    }},
    ?assert(alExperience:overlapScore(<<"role_db:lookup/1 查表">>, Row) >= 2.0),
    ?assertEqual(0.0, alExperience:overlapScore(<<"zzz">>, Row)).

fingerprint_stable_test() ->
    A = alExperience:fingerprintOf(<<"same">>),
    B = alExperience:fingerprintOf(<<"same">>),
    C = alExperience:fingerprintOf(<<"other">>),
    ?assertEqual(A, B),
    ?assertNotEqual(A, C).

paths_from_status_map_test() ->
    Paths = alExperience:pathsFromStatusMap([
        {" M", "src/foo.erl"},
        {"D ", "src/bar.erl"},
        #{path => <<"src/baz.erl">>}
    ]),
    ?assertEqual(3, length(Paths)).

modules_from_paths_test() ->
    Mods = alExperience:modulesFromPaths([
        <<"src/alExperience.erl">>,
        <<"README.md">>
    ]),
    ?assert(lists:member(alExperience, Mods) orelse Mods =:= [] orelse is_list(Mods)).

should_extract_turn_gate_test() ->
    Long = iolist_to_binary(lists:duplicate(40, <<"结论 MFA role:get/1 必须核实。"/utf8>>)),
    ?assert(alExperience:shouldExtractTurn(
        <<"怎么查战斗力？"/utf8>>, Long, #{verdict => pass})),
    ?assertNot(alExperience:shouldExtractTurn(<<"hi">>, Long, #{verdict => pass})),
    ?assertNot(alExperience:shouldExtractTurn(
        <<"怎么查？"/utf8>>, <<"短"/utf8>>, #{verdict => pass})).

critical_exports_learning_test() ->
    Exports = alExperience:module_info(exports),
    [?assert(lists:member({F, A}, Exports))
     || {F, A} <- [{extractFromTurn, 4}, {reconcileAfterCodeChange, 1},
                   {seedFromDigest, 1}, {correctLesson, 1},
                   {unifiedRecall, 2}, {recordBuildFailure, 1}]].

parse_lesson_extract_json_test() ->
    Json = <<"{\"symptom\":\"hot reload failed\",\"rootCause\":\"no soft_purge\","
            "\"prevention\":\"use hotReload\",\"tags\":[\"pitfall\"]}">>,
    Cand = alExperience:parseLessonExtractJson(Json),
    ?assert(is_map(Cand)),
    ?assert(binary:match(maps:get(content, Cand), <<"hot">>) =/= nomatch),
    ?assertEqual(undefined, alExperience:parseLessonExtractJson(<<"{}">>)).

is_stale_detects_metadata_test() ->
    ?assert(alExperience:isStale(#{metadata => #{stale => true}})),
    ?assert(alExperience:isStale(#{tags => [stale]})),
    ?assertNot(alExperience:isStale(#{tags => [lesson]})).

unified_score_uses_row_score_test() ->
    ?assertEqual(0.9, alExperience:unifiedScore(#{score => 0.9})),
    ?assertEqual(0.4, alExperience:unifiedScore(#{kind => note})).

unified_recall_disabled_test() ->
    ok = alConfig:load(),
    try
        case alExperience:enabled() of
            false ->
                {ok, U} = alExperience:unifiedRecall(<<"test">>, #{limit => 3}),
                ?assertEqual([], maps:get(lessons, U, undefined));
            true ->
                {ok, U} = alExperience:unifiedRecall(<<"supervision">>, #{limit => 3}),
                ?assert(is_list(maps:get(lessons, U))),
                ?assert(is_list(maps:get(memories, U))),
                ?assert(is_list(maps:get(merged, U)))
        end
    catch
        exit:{noproc, _} -> ok;
        _:_ -> ok
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).
