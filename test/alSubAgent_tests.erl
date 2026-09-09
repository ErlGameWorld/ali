%%%-------------------------------------------------------------------
%% @doc Tests for alSubAgent.
%% @end
%%%-------------------------------------------------------------------

-module(alSubAgent_tests).

-include_lib("eunit/include/eunit.hrl").

list_returns_known_agents_test() ->
    List = alSubAgent:list(),
    Names = [Name || {Name, _} <- List],
    ?assert(lists:member(explorer, Names)),
    ?assert(lists:member(codeReviewer, Names)),
    ?assert(lists:member(testAuthor, Names)),
    ?assert(lists:member(planner, Names)),
    ?assertEqual(9, length(List)).

lookup_existing_agent_test() ->
    {ok, Def} = alSubAgent:lookup(explorer),
    ?assertEqual(explorer, maps:get(name, Def)),
    ?assertEqual(ask, maps:get(mode, Def)),
    ?assert(maps:is_key(role, Def)),
    ?assert(maps:is_key(tools, Def)).

lookup_unknown_agent_test() ->
    ?assertEqual({error, notFound}, alSubAgent:lookup(nonsense_agent)).

list_returns_role_per_agent_test() ->
    List = alSubAgent:list(),
    lists:foreach(fun({_, Role}) ->
        ?assert(is_binary(Role)),
        ?assert(byte_size(Role) > 0)
    end, List).

run_agents_rejects_non_read_only_test() ->
    Tasks = [{testAuthor, <<"write some tests">>}],
    Result = alSubAgent:runAgents(Tasks),
    ?assertMatch({error, {notReadOnly, testAuthor}}, Result).

run_agents_accepts_read_only_only_test() ->
    Tasks = [{explorer, <<"find foo">>}, {codeReviewer, <<"review bar">>}],
    %% 只验证只读门禁；不要真跑 runAgents（会打 LLM，eunit 易超时）。
    lists:foreach(fun({Name, _}) ->
        {ok, #{mode := ask}} = alSubAgent:lookup(Name)
    end, Tasks),
    ?assertEqual(ok, alSubAgent:checkReadOnly(Tasks)).

lookup_returns_agent_with_tools_list_test() ->
    {ok, Def} = alSubAgent:lookup(refactorer),
    Tools = maps:get(tools, Def),
    ?assert(is_list(Tools)),
    ?assert(length(Tools) > 0),
    lists:foreach(fun(T) -> ?assert(is_atom(T)) end, Tools).

lookup_returns_max_steps_test() ->
    {ok, Def} = alSubAgent:lookup(explorer),
    ?assert(maps:is_key(maxSteps, Def)),
    ?assert(is_integer(maps:get(maxSteps, Def))).

all_built_in_agents_have_required_fields_test() ->
    List = alSubAgent:list(),
    lists:foreach(fun({Name, _}) ->
        {ok, Def} = alSubAgent:lookup(Name),
        ?assertEqual(Name, maps:get(name, Def)),
        ?assert(maps:is_key(role, Def)),
        ?assert(maps:is_key(tools, Def)),
        ?assert(maps:is_key(mode, Def)),
        Mode = maps:get(mode, Def),
        ?assert(lists:member(Mode, [ask, edit, exec]))
    end, List).

run_unknown_returns_error_test() ->
    ?assertMatch({error, notFound}, alSubAgent:run(no_such, <<"task">>)).
