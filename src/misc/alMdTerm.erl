%%%-------------------------------------------------------------------
%% @doc 面向终端的 Markdown 渲染，供 ali:chat() 使用。
%%      镜像 priv/web 的表格/代码块解析，使 CLI 答案更接近 Web UI（无 HTML）。
%% @end
%%%-------------------------------------------------------------------

-module(alMdTerm).

-export([format/1]).

%%--------------------------------------------------------------------
%% @doc Format Markdown-ish answer text for a monospace terminal.
%% @end
%%--------------------------------------------------------------------
-spec format(binary() | list() | term()) -> binary().
format(Text0) ->
    Text = toBin(Text0),
    case Text of
        <<>> -> <<>>;
        _ ->
            Blocks = parseBlocks(Text),
            Rendered = [renderBlock(B) || B <- Blocks],
            collapseBlank(iolist_to_binary(lists:join(<<"\n\n">>,
                [B || B <- Rendered, B =/= <<>>])))
    end.

%% 压缩连续空行，避免 CLI 回答中间大片空白。
collapseBlank(Bin) ->
    re:replace(Bin, <<"(\n){3,}">>, <<"\n\n">>, [global, {return, binary}]).

%%%===================================================================
%%% Parse (aligned with priv/web/static/app.js parseStructuredBlocks)
%%%===================================================================

parseBlocks(Text) ->
    Lines = binary:split(Text, <<"\n">>, [global]),
    parseLines(Lines, [], []).

parseLines([], TextBuf, Acc) ->
    lists:reverse(flushText(TextBuf, Acc));
parseLines([Line | Rest], TextBuf, Acc) ->
    case fenceMatch(Line) of
        {ok, Lang} ->
            {Body, Rest1} = takeFence(Rest, []),
            Acc1 = flushText(TextBuf, Acc),
            parseLines(Rest1, [], [{code, Lang, joinLines(Body)} | Acc1]);
        false ->
            case isTableStart(Line, Rest) of
                true ->
                    Header = splitTableRow(Line),
                    %% skip separator
                    Rest1 = case Rest of
                        [_Sep | R] -> R;
                        R -> R
                    end,
                    {Rows, Rest2} = takeTableRows(Rest1, []),
                    Acc1 = flushText(TextBuf, Acc),
                    parseLines(Rest2, [], [{table, Header, Rows} | Acc1]);
                false ->
                    parseLines(Rest, [Line | TextBuf], Acc)
            end
    end.

flushText([], Acc) -> Acc;
flushText(Buf, Acc) ->
    Text = joinLines(lists:reverse(Buf)),
    case string:trim(Text) of
        <<>> -> Acc;
        _ -> [{text, Text} | Acc]
    end.

fenceMatch(Line) ->
    Trim = trimBin(Line),
    case Trim of
        <<"```", Rest/binary>> -> {ok, firstToken(Rest)};
        <<"~~~", Rest/binary>> -> {ok, firstToken(Rest)};
        _ -> false
    end.

takeFence([], Acc) -> {lists:reverse(Acc), []};
takeFence([Line | Rest], Acc) ->
    Trim = trimBin(Line),
    case Trim of
        <<"```">> -> {lists:reverse(Acc), Rest};
        <<"~~~">> -> {lists:reverse(Acc), Rest};
        <<"```", _/binary>> -> {lists:reverse(Acc), Rest};
        <<"~~~", _/binary>> -> {lists:reverse(Acc), Rest};
        _ -> takeFence(Rest, [Line | Acc])
    end.

isTableStart(Line, [Next | _]) ->
    isPipeRow(Line) andalso isSepRow(Next);
isTableStart(_, _) ->
    false.

isPipeRow(Line) ->
    T = trimBin(Line),
    byte_size(T) >= 3 andalso binary:first(T) =:= $| andalso binary:last(T) =:= $|.

isSepRow(Line) ->
    T = trimBin(Line),
    isPipeRow(Line) andalso
        lists:all(fun(C) -> lists:member(C, " \t|:-") end, binary_to_list(T)).

takeTableRows([], Acc) -> {lists:reverse(Acc), []};
takeTableRows([Line | Rest], Acc) ->
    case isPipeRow(Line) of
        true -> takeTableRows(Rest, [splitTableRow(Line) | Acc]);
        false -> {lists:reverse(Acc), [Line | Rest]}
    end.

splitTableRow(Line) ->
    T0 = trimBin(Line),
    T1 = case T0 of
        <<"|", R/binary>> -> R;
        R -> R
    end,
    T2 = case byte_size(T1) > 0 andalso binary:last(T1) =:= $| of
        true -> binary:part(T1, 0, byte_size(T1) - 1);
        false -> T1
    end,
    [trimBin(C) || C <- binary:split(T2, <<"|">>, [global])].

%%%===================================================================
%%% Render
%%%===================================================================

renderBlock({text, Text}) ->
    formatText(Text);
renderBlock({code, Lang, Code}) ->
    Label = case Lang of
        <<>> -> <<"code">>;
        L -> L
    end,
    [
        <<"┌─ "/utf8>>, Label, <<"\n">>,
        indentCode(Code),
        <<"\n└─"/utf8>>
    ];
renderBlock({table, Header, Rows}) ->
    formatTable(Header, Rows).

formatText(Text) ->
    Lines = binary:split(Text, <<"\n">>, [global]),
    Out = [formatTextLine(L) || L <- Lines],
    joinLines(Out).

formatTextLine(<<"######", Rest/binary>>) -> headerLine(Rest, 6);
formatTextLine(<<"#####", Rest/binary>>) -> headerLine(Rest, 5);
formatTextLine(<<"####", Rest/binary>>) -> headerLine(Rest, 4);
formatTextLine(<<"###", Rest/binary>>) -> headerLine(Rest, 3);
formatTextLine(<<"##", Rest/binary>>) -> headerLine(Rest, 2);
formatTextLine(<<"#", Rest/binary>>) -> headerLine(Rest, 1);
formatTextLine(<<"---">>) -> <<"────────────────────────────────"/utf8>>;
formatTextLine(<<"***">>) -> <<"────────────────────────────────"/utf8>>;
formatTextLine(<<"___">>) -> <<"────────────────────────────────"/utf8>>;
formatTextLine(<<"> ", Rest/binary>>) -> <<"  │ "/utf8, (inlineMd(Rest))/binary>>;
formatTextLine(<<"- [ ] ", Rest/binary>>) -> <<"  ☐ "/utf8, (inlineMd(Rest))/binary>>;
formatTextLine(<<"- [x] ", Rest/binary>>) -> <<"  ☑ "/utf8, (inlineMd(Rest))/binary>>;
formatTextLine(<<"- [X] ", Rest/binary>>) -> <<"  ☑ "/utf8, (inlineMd(Rest))/binary>>;
formatTextLine(<<"- ", Rest/binary>>) -> <<"  • "/utf8, (inlineMd(Rest))/binary>>;
formatTextLine(<<"* ", Rest/binary>>) -> <<"  • "/utf8, (inlineMd(Rest))/binary>>;
formatTextLine(Line) ->
    case Line of
        <<N, ". ", Rest/binary>> when N >= $1, N =< $9 ->
            <<N, ". ", (inlineMd(Rest))/binary>>;
        _ ->
            inlineMd(Line)
    end.

headerLine(Rest, Level) ->
    Title = inlineMd(trimBin(Rest)),
    case Level of
        1 -> <<$\n, "══ "/utf8, Title/binary, " ══"/utf8>>;
        2 -> <<$\n, "── "/utf8, Title/binary, " ──"/utf8>>;
        _ -> <<$\n, Title/binary>>
    end.

%% Strip common inline markdown markers for cleaner terminal reading.
inlineMd(Bin) ->
    B1 = binary:replace(Bin, <<"**">>, <<>>, [global]),
    B2 = binary:replace(B1, <<"__">>, <<>>, [global]),
    %% keep single backticks as quotes around tokens
    binary:replace(B2, <<"`">>, <<>>, [global]).

indentCode(Code) ->
    Lines = binary:split(Code, <<"\n">>, [global]),
    joinLines([<<"  ", L/binary>> || L <- Lines]).

formatTable(Header, Rows) ->
    All = [Header | Rows],
    Cols = lists:max([length(R) || R <- All] ++ [0]),
    Norm = [padRow(R, Cols) || R <- All],
    Widths = colWidths(Norm, Cols),
    Sep = sepLine(Widths),
    case Norm of
        [H | Body] ->
            iolist_to_binary([
                rowLine(H, Widths), <<"\n">>,
                Sep, <<"\n">>,
                lists:join(<<"\n">>, [rowLine(R, Widths) || R <- Body])
            ]);
        [] ->
            <<>>
    end.

padRow(Row, Cols) ->
    Row ++ lists:duplicate(max(0, Cols - length(Row)), <<>>).

colWidths(Rows, Cols) ->
    [colWidth(Rows, I) || I <- lists:seq(0, Cols - 1)].

colWidth(Rows, I) ->
    lists:max([displayWidth(lists:nth(I + 1, R)) || R <- Rows] ++ [1]).

rowLine(Cells, Widths) ->
    Parts = lists:zipwith(fun(C, W) -> padCell(C, W) end, Cells, Widths),
    iolist_to_binary([<<"│ "/utf8>>, lists:join(<<" │ "/utf8>>, Parts), <<" │"/utf8>>]).

sepLine(Widths) ->
    Parts = [lists:duplicate(W, $-) || W <- Widths],
    iolist_to_binary([<<"├─"/utf8>>, lists:join(<<"─┼─"/utf8>>, Parts), <<"─┤"/utf8>>]).

padCell(Cell, Width) ->
    Disp = inlineMd(toBin(Cell)),
    Pad = max(0, Width - displayWidth(Disp)),
    <<Disp/binary, (list_to_binary(lists:duplicate(Pad, $\s)))/binary>>.

%% Approximate terminal width: CJK / fullwidth ≈ 2 columns.
displayWidth(Bin) when is_binary(Bin) ->
    try
        lists:sum([charWidth(C) || C <- unicode:characters_to_list(Bin, utf8)])
    catch
        _:_ -> byte_size(Bin)
    end;
displayWidth(_) ->
    0.

charWidth(C) when C < 16#1100 -> 1;
charWidth(C) when C >= 16#2E80, C =< 16#A4CF -> 2;
charWidth(C) when C >= 16#AC00, C =< 16#D7A3 -> 2;
charWidth(C) when C >= 16#F900, C =< 16#FAFF -> 2;
charWidth(C) when C >= 16#FE10, C =< 16#FE6F -> 2;
charWidth(C) when C >= 16#FF00, C =< 16#FF60 -> 2;
charWidth(C) when C >= 16#FFE0, C =< 16#FFE6 -> 2;
charWidth(C) when C >= 16#20000, C =< 16#3FFFD -> 2;
charWidth(_) -> 1.

%%%===================================================================
%%% Helpers
%%%===================================================================

joinLines([]) -> <<>>;
joinLines(Lines) ->
    iolist_to_binary(lists:join(<<"\n">>, [toBin(L) || L <- Lines])).

firstToken(Bin) ->
    case binary:split(trimBin(Bin), <<" ">>) of
        [T | _] -> T;
        _ -> <<>>
    end.

trimBin(Bin) when is_binary(Bin) ->
    try unicode:characters_to_binary(string:trim(unicode:characters_to_list(Bin)))
    catch _:_ -> Bin
    end;
trimBin(Other) ->
    toBin(Other).

toBin(V) when is_binary(V) -> V;
toBin(V) when is_list(V) -> unicode:characters_to_binary(V);
toBin(V) when is_atom(V) -> atom_to_binary(V, utf8);
toBin(V) -> unicode:characters_to_binary(io_lib:format("~p", [V])).
