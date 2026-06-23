%%%-------------------------------------------------------------------
%%% @doc Web/API 附件解析与校验（图片 + 文本文件 + 文档如 PDF）。
%%%
%%% 限制值来自 config.cfg `{limits, ...}`（见 {@link alConfig}），
%%% MIME/扩展名白名单见 {@code include/al_attachment.hrl}。
%%% @end
%%%-------------------------------------------------------------------
-module(alAttachments).

-export([optsFromBody/1]).

-include("al_attachment.hrl").

-type attachment_opts() :: #{
    images => [map()],
    files => [map()],
    documents => [map()]
}.

%% @doc 从已解码 JSON map 解析附件，返回可写入 ask Opts 的 map。
-spec optsFromBody(map()) -> {ok, attachment_opts() | #{}} | {error, binary()}.
optsFromBody(Body) when is_map(Body) ->
    ImagesRaw = maps:get(<<"images"/utf8>>, Body, []),
    FilesRaw = maps:get(<<"files"/utf8>>, Body, []),
    DocsRaw = maps:get(<<"documents"/utf8>>, Body, []),
    case parse_images(ImagesRaw) of
        {ok, Images} ->
            case parse_files(FilesRaw) of
                {ok, Files} ->
                    case parse_documents(DocsRaw) of
                        {ok, Documents} ->
                            case {Images, Files, Documents} of
                                {[], [], []} ->
                                    {ok, #{}};
                                _ ->
                                    Opts = #{images => Images, files => Files, documents => Documents},
                                    {ok, maps:filter(fun(_, V) -> V =/= [] end, Opts)}
                            end;
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end;
optsFromBody(_) ->
    {ok, #{}}.

parse_images(List) when is_list(List) ->
    Max = alConfig:get(webMaxImages),
    case length(List) > Max of
        true -> {error, <<"too many images"/utf8>>};
        false -> parse_images(List, [])
    end;
parse_images(_) ->
    {error, <<"images must be an array"/utf8>>}.

parse_images([], Acc) ->
    {ok, lists:reverse(Acc)};
parse_images([Item | Rest], Acc) when is_map(Item) ->
    case normalize_image(Item) of
        {ok, Norm} -> parse_images(Rest, [Norm | Acc]);
        {error, Reason} -> {error, Reason}
    end;
parse_images(_, _) ->
    {error, <<"invalid image entry"/utf8>>}.

normalize_image(#{<<"mediaType"/utf8>> := MT, <<"data"/utf8>> := Data} = Item) ->
    MaxBytes = alConfig:get(webMaxImageBytes),
    case allowed_image_type(MT) of
        true ->
            case payload_size(Data) of
                Sz when Sz =< MaxBytes ->
                    Name = maps:get(<<"name"/utf8>>, Item, <<"image"/utf8>>),
                    {ok, #{
                        <<"mediaType"/utf8>> => MT,
                        <<"data"/utf8>> => normalize_payload(Data),
                        <<"name"/utf8>> => to_binary(Name)
                    }};
                _ ->
                    {error, <<"image too large"/utf8>>}
            end;
        false ->
            {error, <<"unsupported image type"/utf8>>}
    end;
normalize_image(_) ->
    {error, <<"image requires mediaType and data"/utf8>>}.

parse_files(List) when is_list(List) ->
    Max = alConfig:get(webMaxFiles),
    case length(List) > Max of
        true -> {error, <<"too many files"/utf8>>};
        false -> parse_files(List, [])
    end;
parse_files(_) ->
    {error, <<"files must be an array"/utf8>>}.

parse_files([], Acc) ->
    {ok, lists:reverse(Acc)};
parse_files([Item | Rest], Acc) when is_map(Item) ->
    case normalize_file(Item) of
        {ok, Norm} -> parse_files(Rest, [Norm | Acc]);
        {error, Reason} -> {error, Reason}
    end;
parse_files(_, _) ->
    {error, <<"invalid file entry"/utf8>>}.

normalize_file(#{<<"name"/utf8>> := Name, <<"data"/utf8>> := Data} = Item) ->
    MaxBytes = alConfig:get(webMaxFileBytes),
    MT = maps:get(<<"mediaType"/utf8>>, Item, guess_text_type(Name)),
    case allowed_text_file(Name, MT) of
        true ->
            %% 仅当客户端显式声明 encoding=base64 时才解码；
            %% 前端 app.js 对文本文件发送原始文本，不应尝试 base64 解码
            %% （否则源码中恰好合法的 base64 字符会被误解码为乱码）。
            Raw = case maps:get(<<"encoding"/utf8>>, Item, undefined) of
                <<"base64"/utf8>> ->
                    case decode_base64_payload(Data) of
                        {ok, Decoded} -> Decoded;
                        error -> to_binary(Data)
                    end;
                _ -> to_binary(Data)
            end,
            case byte_size(Raw) =< MaxBytes of
                true ->
                    {ok, #{
                        <<"name"/utf8>> => to_binary(Name),
                        <<"mediaType"/utf8>> => MT,
                        <<"data"/utf8>> => Raw
                    }};
                false ->
                    {error, <<"file too large"/utf8>>}
            end;
        false ->
            {error, <<"unsupported file type"/utf8>>}
    end;
normalize_file(_) ->
    {error, <<"file requires name and data"/utf8>>}.

parse_documents(List) when is_list(List) ->
    Max = alConfig:get(webMaxDocuments),
    case length(List) > Max of
        true -> {error, <<"too many documents"/utf8>>};
        false -> parse_documents(List, [])
    end;
parse_documents(_) ->
    {error, <<"documents must be an array"/utf8>>}.

parse_documents([], Acc) ->
    {ok, lists:reverse(Acc)};
parse_documents([Item | Rest], Acc) when is_map(Item) ->
    case normalize_document(Item) of
        {ok, Norm} -> parse_documents(Rest, [Norm | Acc]);
        {error, Reason} -> {error, Reason}
    end;
parse_documents(_, _) ->
    {error, <<"invalid document entry"/utf8>>}.

normalize_document(#{<<"name"/utf8>> := Name, <<"data"/utf8>> := Data} = Item) ->
    MaxBytes = alConfig:get(webMaxDocumentBytes),
    MT = maps:get(<<"mediaType"/utf8>>, Item, guess_document_type(Name)),
    case allowed_document_type(Name, MT) of
        true ->
            B64 = normalize_payload(Data),
            case payload_size(B64) of
                Sz when Sz =< MaxBytes ->
                    {ok, #{
                        <<"name"/utf8>> => to_binary(Name),
                        <<"mediaType"/utf8>> => MT,
                        <<"data"/utf8>> => B64
                    }};
                _ ->
                    {error, <<"document too large"/utf8>>}
            end;
        false ->
            {error, <<"unsupported document type"/utf8>>}
    end;
normalize_document(_) ->
    {error, <<"document requires name and data"/utf8>>}.

allowed_image_type(MT) ->
    lists:member(MT, ?AL_IMAGE_MIME_TYPES).

allowed_document_type(Name, MT) ->
    lists:member(MT, ?AL_DOCUMENT_MIME_TYPES)
    orelse has_document_extension(Name).

allowed_text_file(Name, MT) ->
    allowed_text_mime(MT)
    orelse has_text_extension(Name).

allowed_text_mime(<<"text/", _/binary>>) -> true;
allowed_text_mime(<<"application/json"/utf8>>) -> true;
allowed_text_mime(<<"application/xml"/utf8>>) -> true;
allowed_text_mime(<<"application/javascript"/utf8>>) -> true;
allowed_text_mime(<<"application/x-erlang-source"/utf8>>) -> true;
allowed_text_mime(<<>>) -> true;
allowed_text_mime(_) -> false.

has_text_extension(Name) ->
    has_extension(Name, ?AL_TEXT_FILE_EXTENSIONS).

has_document_extension(Name) ->
    has_extension(Name, ?AL_DOCUMENT_FILE_EXTENSIONS).

has_extension(Name, Exts) ->
    Ext = filename:extension(to_binary(Name)),
    lists:member(string:lowercase(binary_to_list(Ext)), Exts).

guess_text_type(Name) ->
    case filename:extension(to_binary(Name)) of
        <<".json"/utf8>> -> <<"application/json"/utf8>>;
        <<".xml"/utf8>> -> <<"application/xml"/utf8>>;
        <<".md"/utf8>> -> <<"text/markdown"/utf8>>;
        <<".html"/utf8>> -> <<"text/html"/utf8>>;
        <<".css"/utf8>> -> <<"text/css"/utf8>>;
        <<".js"/utf8>> -> <<"application/javascript"/utf8>>;
        _ -> <<"text/plain"/utf8>>
    end.

guess_document_type(Name) ->
    case filename:extension(to_binary(Name)) of
        <<".pdf"/utf8>> -> <<"application/pdf"/utf8>>;
        _ -> <<"application/octet-stream"/utf8>>
    end.

payload_size(Data) when is_binary(Data) ->
    %% 估算解码后体积，避免完整解码占用双倍内存。
    %% base64 编码体积约为原始体积的 4/3，故 Raw * 3 div 4。
    Raw = strip_data_url(Data),
    byte_size(Raw) * 3 div 4;
payload_size(_) ->
    0.

decode_base64_payload(Bin) when is_binary(Bin) ->
    Raw = strip_data_url(Bin),
    try base64:decode(Raw, #{mode => loose}) of
        Decoded when is_binary(Decoded) ->
            {ok, Decoded}
    catch
        _:_ ->
            error
    end;
decode_base64_payload(_) ->
    error.

normalize_payload(Bin) when is_binary(Bin) ->
    strip_data_url(Bin);
normalize_payload(Bin) when is_list(Bin) ->
    normalize_payload(llmJson:text(Bin));
normalize_payload(_) ->
    <<>>.

strip_data_url(Bin) when is_binary(Bin) ->
    case binary:split(Bin, <<";base64,">>) of
        [_Prefix, Data] -> Data;
        _ -> Bin
    end;
strip_data_url(Bin) when is_list(Bin) ->
    strip_data_url(llmJson:text(Bin));
strip_data_url(_) ->
    <<>>.

to_binary(B) when is_binary(B) -> llmJson:text(B);
to_binary(L) when is_list(L) -> llmJson:text(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(I) when is_integer(I) -> integer_to_binary(I).
