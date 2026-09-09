%%% @doc Embed lifecycle API smoke tests (addPaths / start opts helpers).
-module(ali_embed_tests).

-include_lib("eunit/include/eunit.hrl").

addPathsMissing_test() ->
    ?assertMatch({error, {noEbinDirs, _}}, ali:addPaths("H:/__ali_missing_release__")).

addPathsOk_test() ->
    Rel = filename:join(["_build", "default", "lib"]),
    case filelib:is_dir(Rel) of
        false ->
            ok;
        true ->
            %% addPaths expects release layout: Root/lib/*/ebin
            %% _build/default is close: use parent of lib
            Root = filename:absname("_build/default"),
            case ali:addPaths(Root) of
                {ok, Paths} ->
                    ?assert(length(Paths) > 0),
                    ?assert(lists:any(fun(P) -> string:find(P, "ali") =/= nomatch end, Paths));
                {error, {noEbinDirs, _}} ->
                    ok
            end
    end.

readyMap_test() ->
    ok = alConfig:load(),
    M = ali:ready(),
    ?assert(is_map(M)),
    ?assert(maps:is_key(ready, M)),
    ?assert(maps:is_key(codeRoots, M)),
    ?assert(maps:is_key(indexReady, M)).
