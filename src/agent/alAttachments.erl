%%%-------------------------------------------------------------------
%% @doc Web/API 附件解析、校验与 LLM 多模态 content parts 构建。
%%
%% 支持图片、文本文件（含 .hrl/.h 等头文件）、PDF / Office 文档。
%% Office（doc/docx/xls/xlsx 等）服务端抽文本后注入；PDF 走 file API。
%% MIME/扩展名白名单见 {@code include/ali_attachment.hrl}。
%% @end
%%%-------------------------------------------------------------------

-module(alAttachments).

-include("ali_attachment.hrl").

-export([
    optsFromBody/1,
    mergeOpts/2,
    buildUserContent/2,
    userMessage/1,
    userMessage/2,
    isContentParts/1,
    downgradeAttachments/1,
    normalize/1,
    extractText/1,
    maxImages/0
]).

-type attachmentOpts() :: #{
    images => [map()],
    files => [map()],
    documents => [map()]
}.

%%--------------------------------------------------------------------
%% @doc
%% 从已解码 JSON map 解析附件，返回可写入 ask Opts 的 map。
%% 会按顺序校验 images、files、documents，任一类型校验失败即返回错误。
%%
%% @param Body 已解码的 JSON map，可含 images/files/documents 字段
%% @return {ok, Opts} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec optsFromBody(map()) -> {ok, attachmentOpts() | #{}} | {error, binary()}.
optsFromBody(Body) when is_map(Body) ->
    ImagesRaw = maps:get(<<"images">>, Body, maps:get(images, Body, [])),
    FilesRaw = maps:get(<<"files">>, Body, maps:get(files, Body, [])),
    DocsRaw = maps:get(<<"documents">>, Body, maps:get(documents, Body, [])),
    case parseImages(ImagesRaw) of
        {ok, Images} ->
            case parseFiles(FilesRaw) of
                {ok, Files} ->
                    case parseDocuments(DocsRaw) of
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

%%--------------------------------------------------------------------
%% @doc
%% 将附件 opts 合并进 ask/agent opts；附件为空时直接返回原 ask opts
%%
%% @param AskOpts 原始 ask/agent 选项
%% @param AttachOpts 附件选项
%% @return 合并后的选项映射
%% @end
%%--------------------------------------------------------------------
-spec mergeOpts(map(), map()) -> map().
mergeOpts(AskOpts, AttachOpts) when map_size(AttachOpts) =:= 0 ->
    AskOpts;
mergeOpts(AskOpts, AttachOpts) ->
    maps:merge(AskOpts, AttachOpts).

%%--------------------------------------------------------------------
%% @doc
%% 根据用户 Prompt 与附件构建 LLM 用户消息内容；
%% 无附件时直接返回 Prompt 二进制，有附件时返回 content parts 列表
%%
%% @param Prompt 用户的文本提示
%% @param Attachments 附件映射，可含 images/files/documents
%% @return 二进制文本或 content parts 列表
%% @end
%%--------------------------------------------------------------------
-spec buildUserContent(binary(), map()) -> binary() | [map()].
buildUserContent(Prompt, Attachments) when is_map(Attachments) ->
    Images = maps:get(images, Attachments, []),
    Files = maps:get(files, Attachments, []),
    Documents = maps:get(documents, Attachments, []),
    case Images =:= [] andalso Files =:= [] andalso Documents =:= [] of
        true ->
            Prompt;
        false ->
            buildUserContentParts(Prompt, Images, Files, Documents)
    end.

%%--------------------------------------------------------------------
%% @doc
%% 构造无附件的 user 消息映射
%%
%% @param Content 消息内容
%% @return #{role => user, content => Content}
%% @end
%%--------------------------------------------------------------------
-spec userMessage(binary()) -> map().
userMessage(Content) ->
    #{role => user, content => Content}.

%%--------------------------------------------------------------------
%% @doc
%% 构造带附件的 user 消息映射，附件会被转换为 content parts
%%
%% @param Content 文本提示
%% @param Attachments 附件映射
%% @return 含 content parts 的 user 消息映射
%% @end
%%--------------------------------------------------------------------
-spec userMessage(binary(), map()) -> map().
userMessage(Content, Attachments) when is_map(Attachments) ->
    #{role => user, content => buildUserContent(Content, Attachments)}.

%%--------------------------------------------------------------------
%% @doc
%% 判断输入是否为合法的 content parts 列表（每个元素都是 content part）
%%
%% @param Parts 待判断项
%% @return true | false
%% @end
%%--------------------------------------------------------------------
-spec isContentParts(term()) -> boolean().
isContentParts(Parts) when is_list(Parts) ->
    lists:all(fun isContentPart/1, Parts);
isContentParts(_) ->
    false.

%% 判断单个项是否为 content part（含二进制或原子 type 字段）
isContentPart(#{<<"type">> := Type}) when is_binary(Type) ->
    true;
isContentPart(#{type := Type}) when is_atom(Type) ->
    true;
isContentPart(_) ->
    false.

%%--------------------------------------------------------------------
%% @doc
%% 将消息中的多模态附件降级为纯文本占位符，
%% 用于不支持多模态的 LLM 后端
%%
%% @param Msg 原始消息映射
%% @return 降级后的消息映射
%% @end
%%--------------------------------------------------------------------
-spec downgradeAttachments(map()) -> map().
downgradeAttachments(#{role := user, content := Parts} = Msg) when is_list(Parts) ->
    case isContentParts(Parts) of
        true ->
            Msg#{content => [downgradePart(P) || P <- Parts]};
        false ->
            Msg
    end;
downgradeAttachments(Msg) ->
    Msg.

%%--------------------------------------------------------------------
%% @doc
%% 将单个附件或附件列表归一化为附件 map 列表
%%
%% @param List 单个附件或附件列表
%% @return 归一化后的附件 map 列表
%% @end
%%--------------------------------------------------------------------
normalize(List) when is_list(List) ->
    [normalizeOne(A) || A <- List];
normalize(Other) ->
    [normalizeOne(Other)].

%%--------------------------------------------------------------------
%% @doc
%% 将单个附件项归一化为标准 map：
%% - 含 path 时从文件系统读取并按扩展名分类
%% - 已是 map 时原样返回
%% - 二进制时包装为 text/plain 文本
%% - 其他类型转为 unknown 二进制
%%
%% @param A 单个附件项
%% @return 归一化后的附件 map
%% @end
%%--------------------------------------------------------------------
normalizeOne(#{path := Path}) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            Ext = string:lowercase(unicode:characters_to_list(filename:extension(Path))),
            case lists:member(Ext, ?DocFileExtensions) of
                true ->
                    #{<<"name">> => filename:basename(Path),
                      <<"mediaType">> => guessDocumentType(Path),
                      <<"data">> => base64:encode(Bin)};
                false ->
                    #{<<"name">> => filename:basename(Path),
                      <<"mediaType">> => guessTextType(Path),
                      <<"data">> => Bin}
            end;
        {error, Reason} ->
            #{type => error, path => Path, error => Reason}
    end;
normalizeOne(Item) when is_map(Item) ->
    Item;
normalizeOne(Bin) when is_binary(Bin) ->
    #{<<"name">> => <<"text">>, <<"data">> => Bin, <<"mediaType">> => <<"text/plain">>};
normalizeOne(Other) ->
    #{<<"name">> => <<"unknown">>, <<"data">> => toBinary(Other)}.

%%--------------------------------------------------------------------
%% @doc
%% 从附件中抽取纯文本内容（用于本地日志、记忆等场景）
%%
%% @param Attachments 附件映射或列表
%% @return 所有文本类型的 part 拼接后的二进制
%% @end
%%--------------------------------------------------------------------
extractText(Attachments) ->
    Opts = case Attachments of
        #{images := _} -> Attachments;
        [#{path := _} | _] = List ->
            case parseFiles(normalize(List)) of
                {ok, Files} -> #{files => Files};
                _ -> #{}
            end;
        List when is_list(List) ->
            #{files => List};
        _ ->
            #{}
    end,
    Content = buildUserContent(<<>>, maps:merge(#{images => [], documents => []}, Opts)),
    case Content of
        Bin when is_binary(Bin) -> Bin;
        Parts when is_list(Parts) ->
            iolist_to_binary([
                maps:get(<<"text">>, P, maps:get(text, P, <<>>))
                || P <- Parts,
                   maps:get(<<"type">>, P, maps:get(type, P, undefined)) =:= <<"text">>
                      orelse maps:get(type, P, undefined) =:= text
            ])
    end.

%%--------------------------------------------------------------------
%% @doc
%% 获取配置中允许的最大图片数量上限
%%
%% @return 最大图片数（默认 24）
%% @end
%%--------------------------------------------------------------------
maxImages() ->
    limitInt(webMaxImages, 24).

%%%===================================================================
%%% Internal: parse API payloads
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 解析图片列表入口：空列表直接返回，列表过长返回错误，
%% 否则逐项归一化
%%
%% @param List 原始图片列表
%% @return {ok, Images} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
parseImages([]) ->
    {ok, []};
parseImages(List) when is_list(List) ->
    Max = maxImages(),
    case length(List) > Max of
        true -> {error, <<"too many images">>};
        false -> parseImages(List, [])
    end;
parseImages(_) ->
    {error, <<"images must be an array">>}.

%% 递归归一化图片列表，逐项调用 normalizeImage
parseImages([], Acc) ->
    {ok, lists:reverse(Acc)};
parseImages([Item | Rest], Acc) when is_map(Item) ->
    case normalizeImage(Item) of
        {ok, Norm} -> parseImages(Rest, [Norm | Acc]);
        {error, Reason} -> {error, Reason}
    end;
parseImages(_, _) ->
    {error, <<"invalid image entry">>}.

%%--------------------------------------------------------------------
%% @doc
%% 将单个图片项归一化为标准 map：校验 MIME 类型与字节数，
%% 成功后返回包含 mediaType、data、name 的 map
%%
%% @param Item 原始图片项（支持二进制键和原子键）
%% @return {ok, NormImg} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
normalizeImage(#{<<"mediaType">> := MT, <<"data">> := Data} = Item) ->
    normalizeImage(#{
        mediaType => MT,
        data => Data,
        name => maps:get(<<"name">>, Item, maps:get(name, Item, <<"image">>))
    });
normalizeImage(#{mediaType := MT, data := Data} = Item) ->
    MaxBytes = limitInt(webMaxImageBytes, 4 * 1024 * 1024),
    case allowedImageType(MT) of
        true ->
            case payloadSize(Data) of
                Sz when Sz =< MaxBytes ->
                    {ok, #{
                        <<"mediaType">> => toBinary(MT),
                        <<"data">> => normalizePayload(Data),
                        <<"name">> => toBinary(maps:get(name, Item, <<"image">>))
                    }};
                _ ->
                    {error, <<"image too large">>}
            end;
        false ->
            {error, <<"unsupported image type">>}
    end;
normalizeImage(_) ->
    {error, <<"image requires mediaType and data">>}.

%%--------------------------------------------------------------------
%% @doc
%% 解析文本文件列表入口：空列表直接返回，列表过长返回错误，
%% 否则逐项归一化
%%
%% @param List 原始文件列表
%% @return {ok, Files} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
parseFiles([]) ->
    {ok, []};
parseFiles(List) when is_list(List) ->
    Max = limitInt(webMaxFiles, 12),
    case length(List) > Max of
        true -> {error, <<"too many files">>};
        false -> parseFiles(List, [])
    end;
parseFiles(_) ->
    {error, <<"files must be an array">>}.

%% 递归归一化文件列表，逐项调用 normalizeFile
parseFiles([], Acc) ->
    {ok, lists:reverse(Acc)};
parseFiles([Item | Rest], Acc) when is_map(Item) ->
    case normalizeFile(Item) of
        {ok, Norm} -> parseFiles(Rest, [Norm | Acc]);
        {error, Reason} -> {error, Reason}
    end;
parseFiles(_, _) ->
    {error, <<"invalid file entry">>}.

%%--------------------------------------------------------------------
%% @doc
%% 将单个文件项归一化为标准 map：校验 MIME/扩展名、解码 base64、
%% 校验字节数，成功后返回包含 name、mediaType、data 的 map
%%
%% @param Item 原始文件项（支持二进制键和原子键）
%% @return {ok, NormFile} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
normalizeFile(#{<<"name">> := Name, <<"data">> := Data} = Item) ->
    normalizeFile(#{
        name => Name,
        data => Data,
        mediaType => maps:get(<<"mediaType">>, Item, maps:get(mediaType, Item, undefined)),
        encoding => maps:get(<<"encoding">>, Item, maps:get(encoding, Item, undefined))
    });
normalizeFile(#{name := Name, data := Data} = Item) ->
    MaxBytes = limitInt(webMaxFileBytes, 512 * 1024),
    MT = case maps:get(mediaType, Item, undefined) of
        undefined -> guessTextType(Name);
        Other -> toBinary(Other)
    end,
    case allowedTextFile(Name, MT) of
        true ->
            Raw = case maps:get(encoding, Item, undefined) of
                <<"base64">> ->
                    case decodeBase64Payload(Data) of
                        {ok, Decoded} -> Decoded;
                        error -> toBinary(Data)
                    end;
                base64 ->
                    case decodeBase64Payload(Data) of
                        {ok, Decoded} -> Decoded;
                        error -> toBinary(Data)
                    end;
                _ ->
                    toBinary(Data)
            end,
            case byte_size(Raw) =< MaxBytes of
                true ->
                    {ok, #{
                        <<"name">> => toBinary(Name),
                        <<"mediaType">> => MT,
                        <<"data">> => Raw
                    }};
                false ->
                    {error, <<"file too large">>}
            end;
        false ->
            {error, <<"unsupported file type">>}
    end;
normalizeFile(_) ->
    {error, <<"file requires name and data">>}.

%%--------------------------------------------------------------------
%% @doc
%% 解析文档列表入口：空列表直接返回，列表过长返回错误，
%% 否则逐项归一化
%%
%% @param List 原始文档列表
%% @return {ok, Documents} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
parseDocuments([]) ->
    {ok, []};
parseDocuments(List) when is_list(List) ->
    Max = limitInt(webMaxDocuments, 4),
    case length(List) > Max of
        true -> {error, <<"too many documents">>};
        false -> parseDocuments(List, [])
    end;
parseDocuments(_) ->
    {error, <<"documents must be an array">>}.

%% 递归归一化文档列表，逐项调用 normalizeDocument
parseDocuments([], Acc) ->
    {ok, lists:reverse(Acc)};
parseDocuments([Item | Rest], Acc) when is_map(Item) ->
    case normalizeDocument(Item) of
        {ok, Norm} -> parseDocuments(Rest, [Norm | Acc]);
        {error, Reason} -> {error, Reason}
    end;
parseDocuments(_, _) ->
    {error, <<"invalid document entry">>}.

%%--------------------------------------------------------------------
%% @doc
%% 将单个文档项归一化为标准 map：校验 MIME/扩展名与字节数，
%% 成功后返回包含 name、mediaType、data 的 map（data 为 base64）
%%
%% @param Item 原始文档项（支持二进制键和原子键）
%% @return {ok, NormDoc} 或 {error, Reason}
%% @end
%%--------------------------------------------------------------------
normalizeDocument(#{<<"name">> := Name, <<"data">> := Data} = Item) ->
    normalizeDocument(#{
        name => Name,
        data => Data,
        mediaType => maps:get(<<"mediaType">>, Item, maps:get(mediaType, Item, undefined))
    });
normalizeDocument(#{name := Name, data := Data} = Item) ->
    MaxBytes = limitInt(webMaxDocumentBytes, 10 * 1024 * 1024),
    MT = case maps:get(mediaType, Item, undefined) of
        undefined -> guessDocumentType(Name);
        Other -> toBinary(Other)
    end,
    case allowedDocumentType(Name, MT) of
        true ->
            B64 = normalizePayload(Data),
            case payloadSize(B64) of
                Sz when Sz =< MaxBytes ->
                    {ok, #{
                        <<"name">> => toBinary(Name),
                        <<"mediaType">> => MT,
                        <<"data">> => B64
                    }};
                _ ->
                    {error, <<"document too large">>}
            end;
        false ->
            {error, <<"unsupported document type">>}
    end;
normalizeDocument(_) ->
    {error, <<"document requires name and data">>}.

%%%===================================================================
%%% Internal: LLM content parts
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 拼装 LLM 多模态 content parts：文本 + 文件 + 文档 + 图片，
%% 顺序为 TextParts、FileParts、DocParts、ImageParts
%%
%% @param Prompt 文本提示（为空时不产生 text part）
%% @param Images 图片附件列表
%% @param Files 文本文件附件列表
%% @param Documents 文档附件列表
%% @return content parts 列表
%% @end
%%--------------------------------------------------------------------
buildUserContentParts(Prompt, Images, Files, Documents) ->
    TextParts = case Prompt of
        <<>> -> [];
        _ -> [#{<<"type">> => <<"text">>, <<"text">> => Prompt}]
    end,
    FileParts = [fileAttachmentPart(F) || F <- Files],
    DocParts = [documentAttachmentPart(D) || D <- Documents],
    ImageParts = [imageAttachmentPart(I) || I <- Images],
    TextParts ++ FileParts ++ DocParts ++ ImageParts.

%%--------------------------------------------------------------------
%% @doc
%% 将单个文本文件附件构造成 text part，使用代码块包裹内容
%%
%% @param File 含 name 和 data 的文件 map
%% @return text content part
%% @end
%%--------------------------------------------------------------------
fileAttachmentPart(#{<<"name">> := Name, <<"data">> := Data}) ->
    Header = iolist_to_binary([<<"[附件: "/utf8>>, Name, <<"]\n```\n">>]),
    Footer = <<"\n```">>,
    #{
        <<"type">> => <<"text">>,
        <<"text">> => <<Header/binary, Data/binary, Footer/binary>>
    };
fileAttachmentPart(#{name := Name, data := Data}) ->
    fileAttachmentPart(#{
        <<"name">> => toBinary(Name),
        <<"data">> => toBinary(Data)
    }).

%%--------------------------------------------------------------------
%% @doc
%% 将单个文档附件构造成 content part：
%% - Office（doc/docx/xls/xlsx/ppt/pptx）：抽文本后注入为 text part
%% - PDF 等：保持 file part（data URL base64）供多模态 API
%%
%% @param Doc 含 name、mediaType、data 的文档 map
%% @return text 或 file content part
%% @end
%%--------------------------------------------------------------------
documentAttachmentPart(#{<<"name">> := Name, <<"mediaType">> := MT, <<"data">> := Data}) ->
    case shouldExtractOffice(Name, MT) of
        true ->
            case decodeBase64Payload(Data) of
                {ok, Raw} ->
                    case alOfficeExtract:toText(Name, Raw) of
                        {ok, Text} ->
                            fileAttachmentPart(#{<<"name">> => Name, <<"data">> => Text});
                        {error, Reason} ->
                            #{
                                <<"type">> => <<"text">>,
                                <<"text">> => iolist_to_binary([
                                    <<"[附件: "/utf8>>, Name,
                                    <<" 解析失败: "/utf8>>, toBinary(Reason), <<"]">>
                                ])
                            }
                    end;
                error ->
                    #{
                        <<"type">> => <<"text">>,
                        <<"text">> => iolist_to_binary([
                            <<"[附件: "/utf8>>, Name, <<" base64 解码失败]"/utf8>>
                        ])
                    }
            end;
        false ->
            B64 = stripDataUrl(Data),
            FileData = iolist_to_binary([<<"data:">>, MT, <<";base64,">>, B64]),
            #{
                <<"type">> => <<"file">>,
                <<"file">> => #{
                    <<"filename">> => Name,
                    <<"file_data">> => FileData
                }
            }
    end;
documentAttachmentPart(#{name := Name, mediaType := MT, data := Data}) ->
    documentAttachmentPart(#{
        <<"name">> => toBinary(Name),
        <<"mediaType">> => toBinary(MT),
        <<"data">> => toBinary(Data)
    }).

shouldExtractOffice(Name, MT) ->
    alOfficeExtract:isOfficeName(Name) orelse alOfficeExtract:isOfficeMime(MT).

%%--------------------------------------------------------------------
%% @doc
%% 将单个图片附件构造成 image_url part，使用 data URL 形式
%%
%% @param Image 含 mediaType、data 的图片 map
%% @return image_url content part
%% @end
%%--------------------------------------------------------------------
imageAttachmentPart(#{<<"mediaType">> := MT, <<"data">> := Data}) ->
    B64 = stripDataUrl(Data),
    Url = iolist_to_binary([<<"data:">>, MT, <<";base64,">>, B64]),
    #{
        <<"type">> => <<"image_url">>,
        <<"image_url">> => #{
            <<"url">> => Url,
            <<"detail">> => <<"auto">>
        }
    };
imageAttachmentPart(#{mediaType := MT, data := Data}) ->
    imageAttachmentPart(#{
        <<"mediaType">> => toBinary(MT),
        <<"data">> => toBinary(Data)
    }).

%%--------------------------------------------------------------------
%% @doc
%% 将单个 content part 降级为纯文本占位符；
%% 图片和文档附件会被替换为提示性文本，文本 part 原样返回
%%
%% @param Part 原始 content part
%% @return 降级后的 content part
%% @end
%%--------------------------------------------------------------------
downgradePart(#{<<"type">> := <<"image_url">>}) ->
    #{<<"type">> => <<"text">>, <<"text">> => <<"[图片已省略]"/utf8>>};
downgradePart(#{<<"type">> := <<"file">>}) ->
    #{<<"type">> => <<"text">>, <<"text">> => <<"[文档附件已省略]"/utf8>>};
downgradePart(Part) ->
    Part.

%%%===================================================================
%%% Internal: validation helpers
%%%===================================================================

%% 判断 MIME 类型是否在允许的图片白名单中
allowedImageType(MT) ->
    lists:member(toBinary(MT), ?ImageMimeTypes).

%% 判断文档 MIME 类型是否允许，或文件名是否具有允许的文档扩展名
allowedDocumentType(Name, MT) ->
    lists:member(toBinary(MT), ?DocMimeTypes)
        orelse hasDocumentExtension(Name).

%% 判断文本文件是否允许（按 MIME 或扩展名）
allowedTextFile(Name, MT) ->
    allowedTextMime(MT)
        orelse hasTextExtension(Name).

%% 判断 MIME 是否属于允许的文本类型（text/* 或若干 application/* 类型）
allowedTextMime(<<"text/", _/binary>>) -> true;
allowedTextMime(<<"application/json">>) -> true;
allowedTextMime(<<"application/xml">>) -> true;
allowedTextMime(<<"application/javascript">>) -> true;
allowedTextMime(<<"application/x-erlang-source">>) -> true;
allowedTextMime(<<"image/svg+xml">>) -> true;
allowedTextMime(<<>>) -> false;
allowedTextMime(_) -> false.

%% 判断文件名是否具有允许的文本文件扩展名
hasTextExtension(Name) ->
    hasExtension(Name, ?TextFileExtensions).

%% 判断文件名是否具有允许的文档扩展名
hasDocumentExtension(Name) ->
    hasExtension(Name, ?DocFileExtensions).

%% 通用扩展名检查：文件名后缀是否在给定扩展名列表中（大小写不敏感）
hasExtension(Name, Exts) ->
    Ext = filename:extension(toBinary(Name)),
    lists:member(string:lowercase(unicode:characters_to_list(Ext)), Exts).

%%--------------------------------------------------------------------
%% @doc
%% 根据文件名扩展名猜测文本 MIME 类型
%%
%% @param Name 文件名
%% @return 对应的 MIME 类型二进制
%% @end
%%--------------------------------------------------------------------
guessTextType(Name) ->
    case string:lowercase(unicode:characters_to_list(filename:extension(toBinary(Name)))) of
        ".json" -> <<"application/json">>;
        ".ipynb" -> <<"application/json">>;
        ".xml" -> <<"application/xml">>;
        ".svg" -> <<"image/svg+xml">>;
        ".md" -> <<"text/markdown">>;
        ".html" -> <<"text/html">>;
        ".css" -> <<"text/css">>;
        ".js" -> <<"application/javascript">>;
        ".hrl" -> <<"application/x-erlang-source">>;
        ".erl" -> <<"application/x-erlang-source">>;
        ".patch" -> <<"text/x-diff">>;
        ".diff" -> <<"text/x-diff">>;
        ".h" -> <<"text/plain">>;
        ".hpp" -> <<"text/plain">>;
        ".hh" -> <<"text/plain">>;
        _ -> <<"text/plain">>
    end.

%%--------------------------------------------------------------------
%% @doc
%% 根据文件名扩展名猜测文档 MIME 类型，默认返回 octet-stream
%%
%% @param Name 文件名
%% @return 对应的 MIME 类型二进制
%% @end
%%--------------------------------------------------------------------
guessDocumentType(Name) ->
    case string:lowercase(unicode:characters_to_list(filename:extension(toBinary(Name)))) of
        ".pdf" -> <<"application/pdf">>;
        ".docx" -> <<"application/vnd.openxmlformats-officedocument.wordprocessingml.document">>;
        ".doc" -> <<"application/msword">>;
        ".dotx" -> <<"application/vnd.openxmlformats-officedocument.wordprocessingml.document">>;
        ".dot" -> <<"application/msword">>;
        ".xlsx" -> <<"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet">>;
        ".xlsm" -> <<"application/vnd.ms-excel.sheet.macroEnabled.12">>;
        ".xltx" -> <<"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet">>;
        ".xls" -> <<"application/vnd.ms-excel">>;
        ".pptx" -> <<"application/vnd.openxmlformats-officedocument.presentationml.presentation">>;
        ".ppt" -> <<"application/vnd.ms-powerpoint">>;
        ".epub" -> <<"application/epub+zip">>;
        _ -> <<"application/octet-stream">>
    end.

%%--------------------------------------------------------------------
%% @doc
%% 估算 base64 数据负载的字节数（去掉 data URL 前缀后按 3/4 比例换算）
%%
%% @param Data base64 数据（可能带 data URL 前缀）
%% @return 估算的字节数
%% @end
%%--------------------------------------------------------------------
payloadSize(Data) when is_binary(Data) ->
    Raw = stripDataUrl(Data),
    byte_size(Raw) * 3 div 4;
payloadSize(_) ->
    0.

%%--------------------------------------------------------------------
%% @doc
%% 解码 base64 数据负载（去掉 data URL 前缀后用 loose 模式解码）
%%
%% @param Bin base64 数据
%% @return {ok, Decoded} 或 error
%% @end
%%--------------------------------------------------------------------
decodeBase64Payload(Bin) when is_binary(Bin) ->
    Raw = stripDataUrl(Bin),
    try base64:decode(Raw, #{mode => loose}) of
        Decoded when is_binary(Decoded) -> {ok, Decoded};
        _ -> error
    catch
        _:_ -> error
    end;
decodeBase64Payload(_) ->
    error.

%%--------------------------------------------------------------------
%% @doc
%% 将负载归一化为二进制：去掉 data URL 前缀，列表先转二进制
%%
%% @param Bin 原始负载
%% @return 去除前缀后的二进制
%% @end
%%--------------------------------------------------------------------
normalizePayload(Bin) when is_binary(Bin) ->
    stripDataUrl(Bin);
normalizePayload(Bin) when is_list(Bin) ->
    normalizePayload(toBinary(Bin));
normalizePayload(_) ->
    <<>>.

%%--------------------------------------------------------------------
%% @doc
%% 去除 base64 数据的 data URL 前缀（如 data:image/png;base64,）
%%
%% @param Bin 原始数据
%% @return 去除前缀后的二进制
%% @end
%%--------------------------------------------------------------------
stripDataUrl(Bin) when is_binary(Bin) ->
    case binary:split(Bin, <<";base64,">>) of
        [_Prefix, Data] -> Data;
        _ -> Bin
    end;
stripDataUrl(Bin) when is_list(Bin) ->
    stripDataUrl(toBinary(Bin));
stripDataUrl(_) ->
    <<>>.

%%--------------------------------------------------------------------
%% @doc
%% 从配置中读取整型限制值，失败或非法时返回默认值
%%
%% @param Key 配置键
%% @param Default 默认值
%% @return 配置值或默认值
%% @end
%%--------------------------------------------------------------------
limitInt(Key, Default) ->
    try alConfig:limit(Key) of
        N when is_integer(N), N > 0 -> N;
        _ -> Default
    catch
        _:_ -> Default
    end.

%%--------------------------------------------------------------------
%% @doc
%% 将多种类型转换为二进制：二进制原样、列表转码、原子转 UTF-8、整数转字符串
%%
%% @param B 输入值
%% @return 二进制结果
%% @end
%%--------------------------------------------------------------------
toBinary(B) when is_binary(B) -> B;
toBinary(L) when is_list(L) -> unicode:characters_to_binary(L);
toBinary(A) when is_atom(A) -> atom_to_binary(A, utf8);
toBinary(I) when is_integer(I) -> integer_to_binary(I).
