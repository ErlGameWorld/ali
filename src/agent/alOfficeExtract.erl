%%%-------------------------------------------------------------------
%% @doc 从 Office / OOXML 附件抽取纯文本，供 Web 附件注入 LLM。
%%
%% 支持：
%% - `.docx` / `.pptx`：读 zip 内 XML 文本节点
%% - `.xlsx` / `.xlsm`：sharedStrings + 各 sheet 拼成 TSV
%% - `.epub`：zip 内 xhtml/html 去标签抽文本
%% - 旧版 `.doc` / `.xls` / `.ppt`：若实为 OOXML（PK 头）按新格式处理，
%%   否则做启发式可打印串提取（质量有限，建议另存为 docx/xlsx）
%% @end
%%%-------------------------------------------------------------------

-module(alOfficeExtract).

-export([
    toText/2,
    isOfficeName/1,
    isOfficeMime/1,
    maxExtractBytes/0
]).

-define(DefaultMaxExtract, 200 * 1024).

%%%===================================================================
%%% API
%%%===================================================================

-spec isOfficeName(term()) -> boolean().
isOfficeName(Name) ->
    Ext = string:lowercase(unicode:characters_to_list(filename:extension(toBinary(Name)))),
    lists:member(Ext, [".doc", ".docx", ".dot", ".dotx", ".xls", ".xlsx", ".xlsm",
                        ".xltx", ".ppt", ".pptx", ".epub"]).

-spec isOfficeMime(term()) -> boolean().
isOfficeMime(MT0) ->
    MT = toBinary(MT0),
    lists:member(MT, [
        <<"application/msword">>,
        <<"application/vnd.ms-excel">>,
        <<"application/vnd.ms-powerpoint">>,
        <<"application/vnd.openxmlformats-officedocument.wordprocessingml.document">>,
        <<"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet">>,
        <<"application/vnd.openxmlformats-officedocument.presentationml.presentation">>,
        <<"application/vnd.ms-excel.sheet.macroEnabled.12">>,
        <<"application/vnd.ms-word.document.macroEnabled.12">>,
        <<"application/epub+zip">>
    ]).

-spec maxExtractBytes() -> pos_integer().
maxExtractBytes() ->
    try alConfig:limit(webMaxOfficeExtractBytes) of
        N when is_integer(N), N > 0 -> N;
        _ -> ?DefaultMaxExtract
    catch
        _:_ -> ?DefaultMaxExtract
    end.

%%--------------------------------------------------------------------
%% @doc 从文件名 + 原始字节抽取文本。
%% @end
%%--------------------------------------------------------------------
-spec toText(term(), binary()) -> {ok, binary()} | {error, binary()}.
toText(Name, Bin) when is_binary(Bin) ->
    Ext = string:lowercase(unicode:characters_to_list(filename:extension(toBinary(Name)))),
    case extractByExt(Ext, Bin) of
        {ok, Text0} ->
            Text = trimExtract(Text0),
            case Text of
                <<>> -> {error, <<"office extract empty">>};
                _ -> {ok, Text}
            end;
        {error, _} = E ->
            E
    end;
toText(Name, Data) ->
    toText(Name, toBinary(Data)).

%%%===================================================================
%%% Internal
%%%===================================================================

extractByExt(".docx", Bin) -> extractDocx(Bin);
extractByExt(".dotx", Bin) -> extractDocx(Bin);
extractByExt(".xlsx", Bin) -> extractXlsx(Bin);
extractByExt(".xlsm", Bin) -> extractXlsx(Bin);
extractByExt(".xltx", Bin) -> extractXlsx(Bin);
extractByExt(".pptx", Bin) -> extractPptx(Bin);
extractByExt(".epub", Bin) -> extractEpub(Bin);
extractByExt(".doc", Bin) -> extractLegacyOrOoxml(Bin, fun extractDocx/1, <<"doc">>);
extractByExt(".dot", Bin) -> extractLegacyOrOoxml(Bin, fun extractDocx/1, <<"doc">>);
extractByExt(".xls", Bin) -> extractLegacyOrOoxml(Bin, fun extractXlsx/1, <<"xls">>);
extractByExt(".ppt", Bin) -> extractLegacyOrOoxml(Bin, fun extractPptx/1, <<"ppt">>);
extractByExt(_, _) -> {error, <<"unsupported office type">>}.

extractLegacyOrOoxml(Bin, OoxmlFun, Kind) ->
    case isZipMagic(Bin) of
        true -> OoxmlFun(Bin);
        false ->
            case heuristicStrings(Bin) of
                <<>> ->
                    {error, iolist_to_binary([
                        <<"无法解析旧版 .">>, Kind,
                        <<"，请另存为 .docx/.xlsx 后再上传"/utf8>>
                    ])};
                Text ->
                    Note = iolist_to_binary([
                        <<"[注意：旧版 .">>, Kind,
                        <<" 仅做启发式提取，建议另存为 OOXML 以获得完整表格/段落]\n"/utf8>>
                    ]),
                    {ok, <<Note/binary, Text/binary>>}
            end
    end.

isZipMagic(<<"PK", _/binary>>) -> true;
isZipMagic(_) -> false.

%% ---- epub ----

extractEpub(Bin) ->
    case unzipMem(Bin) of
        {ok, Files} ->
            Htmls = lists:sort([
                {Name, Data} || {Name, Data} <- Files,
                                isEpubHtmlName(Name)
            ]),
            Blocks = lists:map(fun({Name, Xml}) ->
                Body = stripHtmlToText(Xml),
                iolist_to_binary([<<"## ">>, Name, <<"\n">>, Body])
            end, Htmls),
            case Blocks of
                [] -> {error, <<"epub has no html content">>};
                _ -> {ok, joinBlocks(Blocks)}
            end;
        {error, _} = E ->
            E
    end.

isEpubHtmlName(Name) ->
    Lower = string:lowercase(Name),
    lists:suffix(".xhtml", Lower)
        orelse lists:suffix(".html", Lower)
        orelse lists:suffix(".htm", Lower).

stripHtmlToText(Xml) when is_binary(Xml) ->
    %% 去掉 script/style
    B1 = re:replace(Xml, <<"<(script|style)[\\s>][\\s\\S]*?</\\1>">>, <<>>,
                    [global, {return, binary}, caseless]),
    B2 = re:replace(B1, <<"<[^>]+>">>, <<" ">>, [global, {return, binary}]),
    B3 = decodeXmlEntities(B2),
    re:replace(B3, <<"[ \\t\\r\\n]+">>, <<" ">>, [global, {return, binary}]);
stripHtmlToText(Other) ->
    stripHtmlToText(toBinary(Other)).

%% ---- docx ----

extractDocx(Bin) ->
    case unzipMem(Bin) of
        {ok, Files} ->
            case findEntry(Files, "word/document.xml") of
                {ok, Xml} ->
                    Paras = xmlTagTexts(Xml, <<"w:t">>),
                    {ok, joinLines(Paras)};
                error ->
                    {error, <<"docx missing word/document.xml">>}
            end;
        {error, _} = E ->
            E
    end.

%% ---- pptx ----

extractPptx(Bin) ->
    case unzipMem(Bin) of
        {ok, Files} ->
            Slides = lists:sort([
                {Name, Data} || {Name, Data} <- Files,
                                isPrefix("ppt/slides/slide", Name),
                                lists:suffix(".xml", Name)
            ]),
            Texts = lists:map(fun({Name, Xml}) ->
                Body = joinLines(xmlTagTexts(Xml, <<"a:t">>)),
                iolist_to_binary([<<"## ">>, Name, <<"\n">>, Body])
            end, Slides),
            case Texts of
                [] -> {error, <<"pptx has no slides">>};
                _ -> {ok, joinBlocks(Texts)}
            end;
        {error, _} = E ->
            E
    end.

%% ---- xlsx ----

extractXlsx(Bin) ->
    case unzipMem(Bin) of
        {ok, Files} ->
            Shared = case findEntry(Files, "xl/sharedStrings.xml") of
                {ok, SsXml} -> parseSharedStrings(SsXml);
                error -> []
            end,
            Sheets = lists:sort([
                {Name, Data} || {Name, Data} <- Files,
                                isPrefix("xl/worksheets/sheet", Name),
                                lists:suffix(".xml", Name)
            ]),
            Blocks = lists:map(fun({Name, Xml}) ->
                Rows = parseSheetRows(Xml, Shared),
                iolist_to_binary([<<"## ">>, Name, <<"\n">>, Rows])
            end, Sheets),
            case Blocks of
                [] -> {error, <<"xlsx has no worksheets">>};
                _ -> {ok, joinBlocks(Blocks)}
            end;
        {error, _} = E ->
            E
    end.

parseSharedStrings(Xml) ->
    %% 每个 <si>...</si> 内可能有多个 <t>
    case re:run(Xml, <<"<si[\\s>][\\s\\S]*?</si>">>, [global, {capture, all, binary}]) of
        {match, Sis} ->
            [joinInline(xmlTagTexts(Si, <<"t">>)) || [Si] <- Sis];
        _ ->
            xmlTagTexts(Xml, <<"t">>)
    end.

parseSheetRows(Xml, Shared) ->
    case re:run(Xml, <<"<row[\\s>][\\s\\S]*?</row>">>, [global, {capture, all, binary}]) of
        {match, Rows} ->
            Lines = [formatRow(Row, Shared) || [Row] <- Rows],
            joinLines([L || L <- Lines, L =/= <<>>]);
        _ ->
            <<>>
    end.

formatRow(RowXml, Shared) ->
    case re:run(RowXml, <<"<c[\\s>][\\s\\S]*?</c>">>, [global, {capture, all, binary}]) of
        {match, Cells} ->
            Vals = [cellValueLoose(C, Shared) || [C] <- Cells],
            joinTabs(Vals);
        _ ->
            <<>>
    end.

%% `<c ...>...</c>` 整段
cellValueLoose(CellXml, Shared) ->
    IsShared = binary:match(CellXml, <<" t=\"s\"">>) =/= nomatch
        orelse binary:match(CellXml, <<" t='s'">>) =/= nomatch,
    Vs = xmlTagTexts(CellXml, <<"v">>),
    Raw = case Vs of
        [V | _] -> V;
        [] ->
            case xmlTagTexts(CellXml, <<"t">>) of
                [T | _] -> T;
                [] -> <<>>
            end
    end,
    case IsShared of
        true -> sharedAt(Shared, Raw);
        false -> decodeXmlEntities(Raw)
    end.

sharedAt(Shared, IdxBin) ->
    try binary_to_integer(string:trim(IdxBin)) of
        Idx when Idx >= 0, Idx < length(Shared) ->
            decodeXmlEntities(lists:nth(Idx + 1, Shared));
        _ ->
            IdxBin
    catch
        _:_ -> IdxBin
    end.

%% ---- zip / xml helpers ----

unzipMem(Bin) ->
    Tmp = tmpZipPath(),
    case file:write_file(Tmp, Bin) of
        ok ->
            try zip:unzip(Tmp, [memory]) of
                {ok, Files} ->
                    Norm = [{normalizeEntryName(N), D} || {N, D} <- Files],
                    {ok, Norm};
                {error, Reason} ->
                    {error, iolist_to_binary(io_lib:format("unzip failed: ~p", [Reason]))}
            after
                _ = file:delete(Tmp)
            end;
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("write temp zip failed: ~p", [Reason]))}
    end.

tmpZipPath() ->
    Name = lists:flatten(io_lib:format("ali_office_~p_~p.zip", [erlang:unique_integer([positive]), erlang:system_time(microsecond)])),
    filename:join(tmpdir(), Name).

tmpdir() ->
    case os:getenv("TEMP") of
        false ->
            case os:getenv("TMP") of
                false -> ".";
                T -> T
            end;
        T -> T
    end.

normalizeEntryName(N) when is_list(N) -> N;
normalizeEntryName(N) when is_binary(N) -> unicode:characters_to_list(N);
normalizeEntryName(N) -> lists:flatten(io_lib:format("~p", [N])).

findEntry(Files, Want) ->
    case lists:keyfind(Want, 1, Files) of
        {_, Data} when is_binary(Data) -> {ok, Data};
        false ->
            %% 容错：偶发带前导目录
            case [D || {N, D} <- Files, lists:suffix(Want, N)] of
                [Data | _] -> {ok, Data};
                [] -> error
            end
    end.

isPrefix(Prefix, Name) ->
    lists:prefix(Prefix, Name).

xmlTagTexts(Xml, Tag) when is_binary(Tag) ->
    %% 匹配 <tag ...>text</tag> 与 <tag>text</tag>
    Pat = iolist_to_binary([<<"<", Tag/binary, "(?:\\s[^>]*)?>([\\s\\S]*?)</", Tag/binary, ">">>]),
    case re:run(Xml, Pat, [global, {capture, all, binary}]) of
        {match, Rows} ->
            [decodeXmlEntities(Inner) || [_Full, Inner] <- Rows, Inner =/= <<>>];
        _ ->
            []
    end.

decodeXmlEntities(Bin) when is_binary(Bin) ->
    B1 = binary:replace(Bin, <<"&lt;">>, <<"<">>, [global]),
    B2 = binary:replace(B1, <<"&gt;">>, <<">">>, [global]),
    B3 = binary:replace(B2, <<"&quot;">>, <<"\"">>, [global]),
    B4 = binary:replace(B3, <<"&apos;">>, <<"'">>, [global]),
    B5 = binary:replace(B4, <<"&amp;">>, <<"&">>, [global]),
    %% 去掉残留简单标签
    case re:run(B5, <<"<[^>]+>">>, [global, {capture, none}]) of
        match ->
            re:replace(B5, <<"<[^>]+>">>, <<>>, [global, {return, binary}]);
        _ ->
            B5
    end;
decodeXmlEntities(Other) ->
    decodeXmlEntities(toBinary(Other)).

%% ---- legacy heuristic ----

heuristicStrings(Bin) ->
    Ascii = extractAsciiRuns(Bin, 6),
    Utf16 = extractUtf16LeRuns(Bin, 4),
    joinBlocks([Ascii, Utf16]).

extractAsciiRuns(Bin, MinLen) ->
    extractRuns(Bin, MinLen, fun isPrintableAscii/1, 1).

extractUtf16LeRuns(Bin, MinLen) ->
    %% 逐两字节取样：低字节可打印且高字节为 0
    Sz = byte_size(Bin),
    collectUtf16(Bin, 0, Sz, MinLen, [], []).

collectUtf16(_Bin, Off, Sz, Min, AccRun, AccAll) when Off + 1 >= Sz ->
    Acc2 = case length(AccRun) >= Min of
        true -> [lists:reverse(AccRun) | AccAll];
        false -> AccAll
    end,
    joinLines([unicode:characters_to_binary(R) || R <- lists:reverse(Acc2), R =/= []]);
collectUtf16(Bin, Off, Sz, Min, AccRun, AccAll) ->
    <<_:Off/binary, Lo, Hi, _/binary>> = Bin,
    case Hi =:= 0 andalso isPrintableAscii(Lo) of
        true ->
            collectUtf16(Bin, Off + 2, Sz, Min, [Lo | AccRun], AccAll);
        false ->
            AccAll2 = case length(AccRun) >= Min of
                true -> [lists:reverse(AccRun) | AccAll];
                false -> AccAll
            end,
            collectUtf16(Bin, Off + 2, Sz, Min, [], AccAll2)
    end.

extractRuns(Bin, MinLen, Pred, Step) ->
    Sz = byte_size(Bin),
    collectBytes(Bin, 0, Sz, MinLen, Pred, Step, [], []).

collectBytes(_Bin, Off, Sz, Min, _Pred, _Step, AccRun, AccAll) when Off >= Sz ->
    Acc2 = flushRun(AccRun, Min, AccAll),
    joinLines([list_to_binary(lists:reverse(R)) || R <- lists:reverse(Acc2)]);
collectBytes(Bin, Off, Sz, Min, Pred, Step, AccRun, AccAll) ->
    <<_:Off/binary, B, _/binary>> = Bin,
    case Pred(B) of
        true ->
            collectBytes(Bin, Off + Step, Sz, Min, Pred, Step, [B | AccRun], AccAll);
        false ->
            collectBytes(Bin, Off + Step, Sz, Min, Pred, Step, [], flushRun(AccRun, Min, AccAll))
    end.

flushRun(AccRun, Min, AccAll) ->
    case length(AccRun) >= Min of
        true -> [AccRun | AccAll];
        false -> AccAll
    end.

isPrintableAscii(C) when C >= 32, C =< 126 -> true;
isPrintableAscii(C) when C =:= 9; C =:= 10; C =:= 13 -> true;
isPrintableAscii(_) -> false.

%% ---- join / trim ----

joinLines([]) -> <<>>;
joinLines(Parts) ->
    iolist_to_binary(lists:join(<<"\n">>, [P || P <- Parts, P =/= <<>>])).

joinBlocks([]) -> <<>>;
joinBlocks(Parts) ->
    iolist_to_binary(lists:join(<<"\n\n">>, [P || P <- Parts, P =/= <<>>])).

joinInline([]) -> <<>>;
joinInline(Parts) ->
    iolist_to_binary(lists:join(<<>>, Parts)).

joinTabs([]) -> <<>>;
joinTabs(Parts) ->
    iolist_to_binary(lists:join(<<"\t">>, Parts)).

trimExtract(Text) ->
    Max = maxExtractBytes(),
    case byte_size(Text) > Max of
        true ->
            <<Keep:Max/binary, _/binary>> = Text,
            <<Keep/binary, "\n…[office extract truncated]">>;
        false ->
            Text
    end.

toBinary(B) when is_binary(B) -> B;
toBinary(L) when is_list(L) -> unicode:characters_to_binary(L);
toBinary(A) when is_atom(A) -> atom_to_binary(A, utf8);
toBinary(I) when is_integer(I) -> integer_to_binary(I);
toBinary(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).
