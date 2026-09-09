%%%-------------------------------------------------------------------
%% @doc Ask/Web 错误诊断：保证能在终端看到，并落盘到 dataDir/logs。
%% 打印前会压缩过长 binary（如 tool content），避免刷屏。
%% @end
%%%-------------------------------------------------------------------

-module(alAskDiag).

-export([report/3, report/4, formatDetail/3, sanitize/1]).

-define(MaxBinBytes, 240).
-define(MaxListItems, 20).
-define(MaxMapDepth, 8).

%%--------------------------------------------------------------------
%% @doc 记录 ask 失败：io:format 打到终端 + 写 `.ali/logs/ask_errors.log`。
%% @end
%%--------------------------------------------------------------------
-spec report(term(), term(), list()) -> ok.
report(Class, Reason, Stack) ->
    report(Class, Reason, Stack, #{}).

-spec report(term(), term(), list(), map()) -> ok.
report(Class, Reason, Stack, Ctx) when is_map(Ctx) ->
    Stack1 = lists:sublist(Stack, 12),
    Reason1 = sanitize(Reason),
    Ctx1 = sanitize(Ctx),
    Line = io_lib:format(
        "[~s] alAskDiag ~p:~p~n  ctx=~p~n  stack=~p~n",
        [timestamp(), Class, Reason1, Ctx1, Stack1]
    ),
    %% 终端必打（不依赖 logger 级别）
    io:format(standard_error, "~s", [Line]),
    io:format("~s", [Line]),
    _ = logger:error("alAskDiag ~p:~p ctx=~p stack=~p",
                     [Class, Reason1, Ctx1, Stack1]),
    appendFile(Line),
    ok.

%% 给网页/CLI 用的可读详情（含堆栈前几帧）。
-spec formatDetail(term(), term(), list()) -> binary().
formatDetail(Class, Reason, Stack) ->
    Stack1 = lists:sublist(Stack, 8),
    Reason1 = sanitize(Reason),
    unicode:characters_to_binary(
        io_lib:format(
            "内部错误 ~p:~p~n堆栈: ~p~n详情已写入 .ali/logs/ask_errors.log 与终端",
            [Class, Reason1, Stack1]
        )
    ).

%% 递归压缩大 binary / 过长列表，供日志打印。
-spec sanitize(term()) -> term().
sanitize(Term) ->
    sanitize(Term, 0).

sanitize(Bin, _Depth) when is_binary(Bin) ->
    case byte_size(Bin) > ?MaxBinBytes of
        false -> Bin;
        true ->
            Head = binary:part(Bin, 0, ?MaxBinBytes),
            <<Head/binary, "...[", (integer_to_binary(byte_size(Bin)))/binary, "B]">>
    end;
sanitize(List, Depth) when is_list(List), Depth < ?MaxMapDepth ->
    case io_lib:char_list(List) of
        true ->
            Bin = unicode:characters_to_binary(List),
            case is_binary(Bin) of
                true -> sanitize(Bin, Depth);
                false -> List
            end;
        false ->
            {Keep, Rest} = lists:split(min(length(List), ?MaxListItems), List),
            Kept = [sanitize(X, Depth + 1) || X <- Keep],
            case Rest of
                [] -> Kept;
                _ -> Kept ++ [{truncated, length(Rest)}]
            end
    end;
sanitize(Map, Depth) when is_map(Map), Depth < ?MaxMapDepth ->
    maps:map(fun(_K, V) -> sanitize(V, Depth + 1) end, Map);
sanitize(Tuple, Depth) when is_tuple(Tuple), Depth < ?MaxMapDepth ->
    list_to_tuple([sanitize(X, Depth + 1) || X <- tuple_to_list(Tuple)]);
sanitize(Other, _Depth) ->
    Other.

timestamp() ->
    {{Y, M, D}, {H, Mi, S}} = calendar:local_time(),
    io_lib:format("~4..0w-~2..0w-~2..0w ~2..0w:~2..0w:~2..0w",
                  [Y, M, D, H, Mi, S]).

appendFile(Line) ->
    try
        Dir = filename:join(alConfig:dataDir(), "logs"),
        ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
        Path = filename:join(Dir, "ask_errors.log"),
        ok = file:write_file(Path, Line, [append]),
        ok
    catch
        _:_ -> ok
    end.
