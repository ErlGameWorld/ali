%%% @doc EUnit tests for alAttachments.
-module(alAttachments_tests).

-include_lib("eunit/include/eunit.hrl").

ensureConfig() ->
    case alConfig:load() of
        ok -> ok;
        _ -> ok
    end.

optsFromBodyEmpty_test() ->
    ensureConfig(),
    ?assertEqual({ok, #{}}, alAttachments:optsFromBody(#{<<"question">> => <<"hi">>})).

parseHrlFile_test() ->
    ensureConfig(),
    Body = #{
        <<"files">> => [
            #{
                <<"name">> => <<"ali_sup.hrl">>,
                <<"data">> => <<"-define(X, 1).">>
            }
        ]
    },
    {ok, #{files := [File]}} = alAttachments:optsFromBody(Body),
    ?assertEqual(<<"ali_sup.hrl">>, maps:get(<<"name">>, File)),
    ?assertEqual(<<"-define(X, 1).">>, maps:get(<<"data">>, File)).

parsePdfDocument_test() ->
    ensureConfig(),
    B64 = base64:encode(<<"%PDF-1.4 test">>),
    Body = #{
        <<"documents">> => [
            #{
                <<"name">> => <<"spec.pdf">>,
                <<"mediaType">> => <<"application/pdf">>,
                <<"data">> => B64
            }
        ]
    },
    {ok, #{documents := [Doc]}} = alAttachments:optsFromBody(Body),
    ?assertEqual(<<"application/pdf">>, maps:get(<<"mediaType">>, Doc)).

parseDocxDocument_test() ->
    ensureConfig(),
    Xml = <<"<?xml version=\"1.0\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
            "<w:body><w:p><w:r><w:t>策划案标题</w:t></w:r></w:p>"
            "<w:p><w:r><w:t>技能冷却 3 秒</w:t></w:r></w:p>"
            "</w:body></w:document>"/utf8>>,
    {ok, {"memo.docx", ZipBin}} = zip:create("memo.docx", [{"word/document.xml", Xml}], [memory]),
    Body = #{
        <<"documents">> => [
            #{
                <<"name">> => <<"memo.docx">>,
                <<"mediaType">> => <<"application/vnd.openxmlformats-officedocument.wordprocessingml.document">>,
                <<"data">> => base64:encode(ZipBin)
            }
        ]
    },
    {ok, #{documents := [Doc]}} = alAttachments:optsFromBody(Body),
    Parts = alAttachments:buildUserContent(<<"看看策划"/utf8>>, #{documents => [Doc]}),
    Text = iolist_to_binary([maps:get(<<"text">>, P, <<>>) || P <- Parts,
                              maps:get(<<"type">>, P, <<>>) =:= <<"text">>]),
    ?assert(binary:match(Text, <<"策划案标题"/utf8>>) =/= nomatch),
    ?assert(binary:match(Text, <<"技能冷却"/utf8>>) =/= nomatch).

parseXlsxDocument_test() ->
    ensureConfig(),
    Ss = <<"<?xml version=\"1.0\"?><sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" count=\"2\" uniqueCount=\"2\">"
           "<si><t>item_id</t></si><si><t>sword</t></si></sst>">>,
    Sheet = <<"<?xml version=\"1.0\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
              "<sheetData>"
              "<row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c><c r=\"B1\" t=\"s\"><v>1</v></c></row>"
              "<row r=\"2\"><c r=\"A2\"><v>1001</v></c><c r=\"B2\" t=\"s\"><v>1</v></c></row>"
              "</sheetData></worksheet>">>,
    {ok, {"cfg.xlsx", ZipBin}} = zip:create(
        "cfg.xlsx",
        [{"xl/sharedStrings.xml", Ss}, {"xl/worksheets/sheet1.xml", Sheet}],
        [memory]),
    Body = #{
        <<"documents">> => [
            #{
                <<"name">> => <<"cfg.xlsx">>,
                <<"data">> => base64:encode(ZipBin)
            }
        ]
    },
    {ok, #{documents := [Doc]}} = alAttachments:optsFromBody(Body),
    Parts = alAttachments:buildUserContent(<<"配置表"/utf8>>, #{documents => [Doc]}),
    Text = iolist_to_binary([maps:get(<<"text">>, P, <<>>) || P <- Parts,
                              maps:get(<<"type">>, P, <<>>) =:= <<"text">>]),
    ?assert(binary:match(Text, <<"item_id">>) =/= nomatch),
    ?assert(binary:match(Text, <<"sword">>) =/= nomatch),
    ?assert(binary:match(Text, <<"1001">>) =/= nomatch).

officeExtractDocx_test() ->
    Xml = <<"<w:document><w:t>hello office</w:t></w:document>">>,
    {ok, {_, ZipBin}} = zip:create("a.docx", [{"word/document.xml", Xml}], [memory]),
    {ok, Text} = alOfficeExtract:toText(<<"a.docx">>, ZipBin),
    ?assert(binary:match(Text, <<"hello office">>) =/= nomatch).

parsePatchFile_test() ->
    ensureConfig(),
    Body = #{
        <<"files">> => [
            #{
                <<"name">> => <<"fix.patch">>,
                <<"data">> => <<"--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n">>
            }
        ]
    },
    {ok, #{files := [File]}} = alAttachments:optsFromBody(Body),
    ?assertEqual(<<"fix.patch">>, maps:get(<<"name">>, File)).

parseSvgFile_test() ->
    ensureConfig(),
    Body = #{
        <<"files">> => [
            #{
                <<"name">> => <<"icon.svg">>,
                <<"mediaType">> => <<"image/svg+xml">>,
                <<"data">> => <<"<svg xmlns=\"http://www.w3.org/2000/svg\"/>">> 
            }
        ]
    },
    {ok, #{files := [File]}} = alAttachments:optsFromBody(Body),
    ?assertEqual(<<"icon.svg">>, maps:get(<<"name">>, File)).

extractEpub_test() ->
    Html = <<"<html><body><h1>Chapter</h1><p>Hello epub</p></body></html>">>,
    {ok, {_, ZipBin}} = zip:create("b.epub", [{"OPS/chapter1.xhtml", Html}], [memory]),
    {ok, Text} = alOfficeExtract:toText(<<"b.epub">>, ZipBin),
    ?assert(binary:match(Text, <<"Hello epub">>) =/= nomatch).

buildUserContentWithHrl_test() ->
    Attach = #{
        files => [
            #{
                <<"name">> => <<"include/foo.hrl">>,
                <<"data">> => <<"-define(FOO, bar).">>
            }
        ]
    },
    Parts = alAttachments:buildUserContent(<<"explain">>, Attach),
    ?assert(alAttachments:isContentParts(Parts)),
    ?assert(length(Parts) >= 2).

imageRejectedBadMime_test() ->
    ensureConfig(),
    Body = #{
        <<"images">> => [
            #{<<"mediaType">> => <<"image/bmp">>, <<"data">> => <<"abc">>}
        ]
    },
    ?assertMatch({error, _}, alAttachments:optsFromBody(Body)).

downgradeAttachments_test() ->
    Msg = #{
        role => user,
        content => [
            #{<<"type">> => <<"image_url">>, <<"image_url">> => #{<<"url">> => <<"data:...">>}}
        ]
    },
    Down = alAttachments:downgradeAttachments(Msg),
    [#{<<"type">> := <<"text">>}] = maps:get(content, Down).
