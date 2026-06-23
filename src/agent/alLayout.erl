%%%-------------------------------------------------------------------
%%% @doc 结构化输出解析与版面布局。
%%%
%%% 从 Agent 的文本回答中提取结构化块（Mermaid 图表、Markdown 表格、
%%% 围栏代码块），并提供安全渲染所需的中间表示。
%%%
%%% 支持的结构化形式：
%%% <ul>
%%%   <li>Mermaid 图表：````mermaid ... ``` ` 围栏块</li>
%%%   <li>表格：Markdown pipe 表格（`| col | col |`）</li>
%%%   <li>代码块：带语言标签的围栏代码块</li>
%%% </ul>
%%%
%%% 该模块为纯函数模块，无副作用，便于测试与复用。
%%% @end
%%%-------------------------------------------------------------------
-module(alLayout).

-export([
    parse/1,
    extractMermaid/1,
    hasStructured/1,
    mermaidHint/0
]).

-type block() ::
    #{type => text, text => binary()} |
    #{type => mermaid, code => binary()} |
    #{type => code, lang => binary(), code => binary()} |
    #{type => table, header => [binary()], rows => [[binary()]]}.

%% @doc 解析文本为结构化块列表。
%% 按行扫描，识别围栏代码块（含 mermaid）与 Markdown 表格，
%% 其余文本作为 text 块保留。
-spec parse(binary() | string()) -> [block()].
parse(Text) when is_list(Text) ->
    parse(unicode:characters_to_binary(Text));
parse(Text) when is_binary(Text) ->
    Lines = binary:split(Text, <<"\n"/utf8>>, [global]),
    parseLines(Lines, []).

%% @doc 仅提取 Mermaid 图表代码（用于校验或单独导出）。
-spec extractMermaid(binary() | string()) -> [binary()].
extractMermaid(Text) ->
    [Code || #{type := mermaid, code := Code} <- parse(Text)].

%% @doc 判断文本是否包含任何结构化块。
-spec hasStructured(binary() | string()) -> boolean().
hasStructured(Text) ->
    lists:any(fun
        (#{type := text}) -> false;
        (_) -> true
    end, parse(Text)).

%% @doc 返回告知模型可使用结构化输出的提示词片段。
-spec mermaidHint() -> binary().
mermaidHint() ->
    <<"结构化输出规则：\n"
      "- 流程图/时序图/类图等可用 Mermaid 语法，放在 ```mermaid 围栏块中。\n"
      "- 对比数据、属性列表等可用 Markdown 表格（| 列 | 列 |）。\n"
      "- 代码示例用带语言标签的围栏代码块（```erlang ... ```）。\n"
      "- 不要把 Mermaid 与表格嵌套在代码块内；保持结构清晰。\n"/utf8>>.

%%%===================================================================
%%% 内部解析
%%%===================================================================

parseLines([], Acc) ->
    lists:reverse(lists:flatten(Acc));
parseLines(Lines, Acc) ->
    case takeFencedBlock(Lines) of
        {ok, Block, Rest} ->
            parseLines(Rest, [Block | Acc]);
        not_fenced ->
            case takeTable(Lines) of
                {ok, Block, Rest} ->
                    parseLines(Rest, [Block | Acc]);
                not_table ->
                    case takeText(Lines, []) of
                        {ok, Block, Rest} ->
                            parseLines(Rest, [Block | Acc]);
                        empty ->
                            lists:reverse(lists:flatten(Acc))
                    end
            end
    end.

%% 尝试从行首取一个围栏代码块（```lang ... ```）。
%% 若开头不是围栏，返回 not_fenced。
takeFencedBlock([Line | Rest]) ->
    case parseFenceOpen(Line) of
        {ok, Lang} ->
            takeFenceBody(Rest, Lang, []);
        not_fenced ->
            not_fenced
    end;
takeFencedBlock([]) ->
    not_fenced.

%% 解析围栏开头：```lang 或 ~~~lang
parseFenceOpen(Line) ->
    Trimmed = string:trim(Line, both),
    case Trimmed of
        <<"```", Rest/binary>> ->
            {ok, string:trim(Rest)};
        <<"~~~", Rest/binary>> ->
            {ok, string:trim(Rest)};
        _ ->
            not_fenced
    end.

%% 收集围栏体直到闭合围栏。
takeFenceBody([], Lang, Acc) ->
    %% 未闭合：把已收集内容作为代码块返回
    Code = iolist_to_binary(lists:join(<<"\n"/utf8>>, lists:reverse(Acc))),
    {ok, fenceBlock(Lang, Code), []};
takeFenceBody([Line | Rest], Lang, Acc) ->
    case isFenceClose(Line) of
        true ->
            Code = iolist_to_binary(lists:join(<<"\n"/utf8>>, lists:reverse(Acc))),
            {ok, fenceBlock(Lang, Code), Rest};
        false ->
            takeFenceBody(Rest, Lang, [Line | Acc])
    end.

isFenceClose(Line) ->
    Trimmed = string:trim(Line, both),
    Trimmed =:= <<"```"/utf8>> orelse Trimmed =:= <<"~~~"/utf8>>.

%% 按语言标签生成对应块类型。
fenceBlock(Lang, Code) ->
    case string:lowercase(string:trim(Lang)) of
        <<"mermaid"/utf8>> ->
            #{type => mermaid, code => Code};
        _ ->
            #{type => code, lang => Lang, code => Code}
    end.

%% 尝试从行首取一个 Markdown 表格。
%% 表格定义：首行为 `| ... |`，次行为 `|---|---|` 分隔线，之后若干 `| ... |` 行。
takeTable([Line1, Line2 | Rest]) ->
    case isTableRow(Line1) andalso isTableSeparator(Line2) of
        true ->
            Header = parseRow(Line1),
            {Rows, Rest2} = takeTableRows(Rest, []),
            case Header =:= [] of
                true -> not_table;
                false -> {ok, #{type => table, header => Header, rows => Rows}, Rest2}
            end;
        false ->
            not_table
    end;
takeTable(_) ->
    not_table.

isTableRow(Line) ->
    Trimmed = string:trim(Line, both),
    byte_size(Trimmed) > 0 andalso binary:at(Trimmed, 0) =:= $|.

isTableSeparator(Line) ->
    Trimmed = string:trim(Line, both),
    case Trimmed of
        <<$|, Rest/binary>> ->
            %% 仅含 -、:、|、空格
            lists:all(fun(C) -> C =:= $- orelse C =:= $: orelse C =:= $| orelse C =:= $\s end,
                      binary_to_list(Rest)) andalso binary:match(Rest, <<"-">>) =/= nomatch;
        _ ->
            false
    end.

parseRow(Line) ->
    Trimmed = string:trim(Line, both),
    %% 去掉首尾的 |
    Inner = case Trimmed of
        <<$|, R/binary>> ->
            case byte_size(R) > 0 andalso binary:at(R, byte_size(R) - 1) of
                $| -> binary:part(R, 0, byte_size(R) - 1);
                _ -> R
            end;
        _ ->
            Trimmed
    end,
    Cells = binary:split(Inner, <<"|"/utf8>>, [global]),
    [string:trim(C) || C <- Cells].

takeTableRows([], Acc) ->
    {lists:reverse(Acc), []};
takeTableRows([Line | Rest] = Lines, Acc) ->
    case isTableRow(Line) of
        true -> takeTableRows(Rest, [parseRow(Line) | Acc]);
        false -> {lists:reverse(Acc), Lines}
    end.

%% 收集普通文本直到遇到围栏或表格开头。
takeText([], Acc) ->
    case Acc of
        [] -> empty;
        _ -> {ok, #{type => text, text => iolist_to_binary(lists:join(<<"\n"/utf8>>, lists:reverse(Acc)))}, []}
    end;
takeText([Line | Rest] = Lines, Acc) ->
    case isFenceLine(Line) orelse (isTableRow(Line) andalso isTableStart(Lines)) of
        true ->
            case Acc of
                [] -> empty;
                _ -> {ok, #{type => text, text => iolist_to_binary(lists:join(<<"\n"/utf8>>, lists:reverse(Acc)))}, Lines}
            end;
        false ->
            takeText(Rest, [Line | Acc])
    end.

%% 判断一行是否为围栏代码块开头（``` 或 ~~~）。
isFenceLine(Line) ->
    case parseFenceOpen(Line) of
        {ok, _} -> true;
        not_fenced -> false
    end.

isTableStart([_, Line2 | _]) ->
    isTableRow(Line2) andalso isTableSeparator(Line2);
isTableStart(_) ->
    false.
