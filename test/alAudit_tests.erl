%%% @doc EUnit tests for alAudit.
-module(alAudit_tests).

-include_lib("eunit/include/eunit.hrl").

-define(setup, begin ok = alConfig:load(), alAudit:clear() end).

%%%===================================================================
%%% log/1 + list/0
%%%===================================================================

log_and_list_test() ->
    ?setup,
    ok = alAudit:log(#{tool => searchCode, args => #{query => "hello"}, result => #{hits => []}}),
    Entries = alAudit:list(),
    ?assertEqual(1, length(Entries)),
    [Entry] = Entries,
    ?assertEqual(searchCode, maps:get(tool, Entry)),
    ?assertMatch(#{query := _}, maps:get(args, Entry)).

log_multiple_test() ->
    ?setup,
    ok = alAudit:log(#{tool => indexCode, args => #{}}),
    ok = alAudit:log(#{tool => searchCode, args => #{}}),
    ok = alAudit:log(#{tool => readFile, args => #{}}),
    Entries = alAudit:list(),
    ?assertEqual(3, length(Entries)).

list_with_limit_test() ->
    ?setup,
    ok = alAudit:log(#{tool => indexCode, args => #{}}),
    ok = alAudit:log(#{tool => searchCode, args => #{}}),
    ok = alAudit:log(#{tool => readFile, args => #{}}),
    Entries = alAudit:list(2),
    ?assertEqual(2, length(Entries)).

%%%===================================================================
%%% sanitize on log
%%%===================================================================

log_sanitizes_sensitive_args_test() ->
    ?setup,
    ok = alAudit:log(#{tool => runMfa, args => #{apiKey => <<"sk-secret">>}, result => ok}),
    [Entry] = alAudit:list(),
    Args = maps:get(args, Entry),
    ?assertEqual(<<"***REDACTED***">>, maps:get(apiKey, Args)).

log_sanitizes_sensitive_result_test() ->
    ?setup,
    ok = alAudit:log(#{tool => searchCode, args => #{}, result => #{token => <<"abc">>}}),
    [Entry] = alAudit:list(),
    Result = maps:get(result, Entry),
    ?assertEqual(<<"***REDACTED***">>, maps:get(token, Result)).

log_accepts_unicode_charlist_path_test() ->
    ?setup,
    Path = "f:/ali/.trae/documents/ali-项目说明-纲-20260701.md",
    ok = alAudit:log(#{
        tool => readFile,
        args => #{path => Path},
        result => #{files => [Path]}
    }),
    [Entry] = alAudit:list(),
    Args = maps:get(args, Entry),
    ?assertEqual(unicode:characters_to_binary(Path), maps:get(path, Args)),
    Result = maps:get(result, Entry),
    ?assertEqual(
        [unicode:characters_to_binary(Path)],
        maps:get(files, Result)
    ).

deep_redact_keeps_integer_date_tuples_test() ->
    Date = {2026, 7, 19},
    ?assertEqual(Date, alAudit:deepRedact(Date)),
    Nested = #{at => Date, path => "f:/ali/源码/a.erl"},
    Out = alAudit:deepRedact(Nested),
    ?assertEqual(Date, maps:get(at, Out)),
    ?assert(is_binary(maps:get(path, Out))).

log_survives_runtime_tuple_payload_test() ->
    ?setup,
    ok = alAudit:log(#{
        tool => getRuntime,
        args => #{},
        result => #{now => {2026, 7, 19}, pid => self()}
    }),
    ?assertEqual(1, length(alAudit:list())).

%%%===================================================================
%%% clear/0
%%%===================================================================

clear_empties_table_test() ->
    ?setup,
    ok = alAudit:log(#{tool => indexCode, args => #{}}),
    ?assertEqual(1, length(alAudit:list())),
    alAudit:clear(),
    ?assertEqual(0, length(alAudit:list())).

%%%===================================================================
%%% trim (max 500 entries)
%%%===================================================================

log_beyond_max_trims_test() ->
    ?setup,
    [alAudit:log(#{tool => indexCode, args => #{seq => I}}) || I <- lists:seq(1, 510)],
    Entries = alAudit:list(),
    ?assertEqual(500, length(Entries)).
