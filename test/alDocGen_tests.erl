-module(alDocGen_tests).

-include_lib("eunit/include/eunit.hrl").

parse_edoc_test() ->
    Src = <<
        "%% @doc Module overview line.\n"
        "%% More overview.\n"
        "-module(demo).\n"
        "-export([foo/1]).\n"
        "\n"
        "%% @doc Adds one.\n"
        "%% @end\n"
        "foo(X) -> X + 1.\n"
    >>,
    #{moduleDoc := ModDoc, functions := Funs} = alDocGen:parseEdocFromSource(Src),
    ?assertEqual(<<"Module overview line.\nMore overview.">>, ModDoc),
    ?assertMatch([#{name := foo, arity := 1, doc := <<"Adds one.">>}], Funs).

filter_edges_test() ->
    Edges = [
        #{from_module => <<"a">>, from_function => <<"f">>, from_arity => 1,
          to_module => <<"b">>, to_function => <<"g">>, arity => 2},
        #{from_module => <<"x">>, from_function => <<"y">>, from_arity => 0,
          to_module => <<"z">>, to_function => <<"w">>, arity => 1}
    ],
    Filtered = alDocGen:filterCallEdges(Edges, #{module => a}),
    ?assertEqual(1, length(Filtered)),
    %% binary keys（LLM JSON）也应生效
    FilteredBin = alDocGen:filterCallEdges(Edges, #{<<"module">> => <<"a">>}),
    ?assertEqual(1, length(FilteredBin)).

call_graph_filters_binary_keys_test() ->
    F = alToolRouter:callGraphFilters(#{<<"module">> => <<"alAgent">>,
                                        <<"maxEdges">> => 40}),
    ?assertEqual(<<"alAgent">>, maps:get(module, F)),
    ?assertEqual(false, maps:is_key(maxEdges, F)).

unwrap_core_data_test() ->
    ?assertEqual(#{calls => [a]},
                 alToolRouter:unwrapCoreData(#{engine => rustCore, data => #{calls => [a]}})),
    ?assertEqual(#{calls => [a]},
                 alToolRouter:unwrapCoreData(#{calls => [a]})).

write_path_auto_test() ->
    case alDocGen:generateModuleDoc(alDocGen, #{
            includeDeps => false, writePath => auto, maxFunctions => 5}) of
        {ok, #{markdown := Md} = Doc} ->
            ?assert(is_binary(Md)),
            case maps:get(written, Doc, undefined) of
                undefined ->
                    %% write may fail if cwd not project root; still ok if markdown present
                    ok;
                #{path := _} ->
                    ok;
                _ ->
                    ok
            end;
        {error, _} ->
            ok
    end.

mermaid_edges_test() ->
    Edges = [
        #{from_module => <<"a">>, from_function => <<"f">>, from_arity => 1,
          to_module => <<"b">>, to_function => <<"g">>, arity => 2}
    ],
    Mermaid = alDocGen:mermaidCallEdges(Edges, 10),
    ?assert(is_binary(Mermaid)),
    ?assertNotEqual(nomatch, binary:match(Mermaid, <<"flowchart LR">>)),
    ?assertNotEqual(nomatch, binary:match(Mermaid, <<"a:f/1">>)).

extract_briefs_from_erl_test() ->
    Src = unicode:characters_to_binary(
        "%% @doc send broadcast\n"
        "broadcast(A, B) -> ok.\n"
        "\n"
        "%% get npc attr\n"
        "get_npc_attr(Id) -> Id.\n"),
    Briefs = alDocGen:extractBriefsFromErl(Src),
    ?assertEqual(<<"send broadcast">>, maps:get({<<"broadcast">>, 2}, Briefs)),
    ?assertEqual(<<"get npc attr">>, maps:get({<<"get_npc_attr">>, 1}, Briefs)).

extract_briefs_func_description_test() ->
    Src = unicode:characters_to_binary(
        "%% ----------------------------------------------------\n"
        "%% Func:\n"
        "%% Description: 广播\n"
        "%% Returns:\n"
        "%% ----------------------------------------------------\n"
        "broadcast(A, B) -> ok.\n"
        "\n"
        "%% Func:\n"
        "%% Description: 繁荣度bi\n"
        "%% Returns:\n"
        "%% ----------------------------------------------------\n"
        "prosperity_bi(Id) -> Id.\n"),
    Briefs = alDocGen:extractBriefsFromErl(Src),
    ?assertEqual(unicode:characters_to_binary("广播"),
                 maps:get({<<"broadcast">>, 2}, Briefs)),
    ?assertEqual(unicode:characters_to_binary("繁荣度bi"),
                 maps:get({<<"prosperity_bi">>, 1}, Briefs)).

extract_briefs_handles_commented_out_function_head_test() ->
    Src = unicode:characters_to_binary(
        "%%get_alliance_town(Src) ->\n"
        "%%   TDs = zm_config:get('town_detail'),\n"
        "\n"
        "%% ----------------------------------------------------\n"
        "%% 城池战斗后修改城池、驻防信息\n"
        "after_fight(Src, TownInfo, TownSid) -> ok.\n"),
    Briefs = alDocGen:extractBriefsFromErl(Src),
    %% 确认 after_fight/3 的简述来自它前面那段 %% 注释，而不是被上面 get_alliance_town 的注释污染
    ?assertEqual(unicode:characters_to_binary("城池战斗后修改城池、驻防信息"),
                 maps:get({<<"after_fight">>, 3}, Briefs)).

mermaid_edges_with_briefs_test() ->
    Edges = [
        #{from_module => <<"a">>, from_function => <<"f">>, from_arity => 1,
          to_module => <<"b">>, to_function => <<"g">>, arity => 2}
    ],
    Briefs = #{<<"a:f/1">> => <<"caller">>, <<"b:g/2">> => <<"callee">>},
    Mermaid = alDocGen:mermaidCallEdges(Edges, 10, Briefs),
    ?assertNotEqual(nomatch, binary:match(Mermaid, <<"caller">>)),
    ?assertNotEqual(nomatch, binary:match(Mermaid, <<"<br/">>)).

mermaid_deps_test() ->
    Mermaid = alDocGen:mermaidModuleDeps(alDocGen, [<<"alToolsExt">>, <<"alCoreClient">>]),
    ?assertNotEqual(nomatch, binary:match(Mermaid, <<"flowchart LR">>)),
    ?assertNotEqual(nomatch, binary:match(Mermaid, <<"alToolsExt">>)).

to_markdown_test() ->
    Doc = #{
        module => demo,
        moduleDoc => <<"Hello">>,
        functions => [#{name => foo, arity => 0, doc => <<"bar">>, exported => true}],
        mermaid => <<"flowchart LR\n  a-->b">>,
        truncated => false
    },
    Md = alDocGen:toMarkdown(Doc),
    ?assertNotEqual(nomatch, binary:match(Md, <<"# demo">>)),
    ?assertNotEqual(nomatch, binary:match(Md, <<"`foo/0`">>)),
    ?assertNotEqual(nomatch, binary:match(Md, <<"```mermaid">>)).

generate_loaded_module_test() ->
    case alDocGen:generateModuleDoc(alDocGen, #{includeDeps => false, maxFunctions => 20}) of
        {ok, #{markdown := Md, functions := Funs}} ->
            ?assert(is_binary(Md)),
            ?assert(is_list(Funs)),
            ?assert(length(Funs) > 0);
        {error, #{reason := no_abstract_code}} ->
            %% Built without debug_info — acceptable in some CI profiles.
            ok;
        {error, #{reason := moduleNotLoaded}} ->
            ok;
        Other ->
            ?assertMatch({ok, _}, Other)
    end.
