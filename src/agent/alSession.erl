%%%-------------------------------------------------------------------
%%% @doc 会话持久化模块。
%%%
%%% 将 Agent 内存中的会话（消息历史、创建/更新时间等）序列化为 JSON
%%% 文件保存到 `.al/sessions/` 目录，支持按 ID 加载、删除与列举。
%%% 消息编码兼容 OpenAI 格式（user/assistant/tool 角色及 tool_calls）。
%%% @end
%%%-------------------------------------------------------------------
-module(alSession).

-export([
    sessionDir/0,
    save/2,
    load/1,
    delete/1,
    list/0
]).

-define(SESSION_DIR, ".al/sessions").

%% @doc 返回会话文件存储目录。
%% 优先读取 application 环境 `ali` 的 sessionDir 配置；
%% 未配置时使用项目根目录下的 `.al/sessions`。
%% @returns `{string()}` 目录绝对路径
-spec sessionDir() -> string().
sessionDir() ->
    case application:get_env(ali, sessionDir, undefined) of
        {ok, Dir} -> Dir;
        undefined ->
            Root = alToolProject:findProjectRootFromModule(),
            filename:join(Root, ?SESSION_DIR)
    end.

%% @doc 将会话 map 持久化到磁盘 JSON 文件。
%% @param SessionId 会话标识（binary）
%% @param Session 含 id、messages、createdAt、updatedAt 的会话 map
%% @returns `ok` 或 `{error, term()}`
-spec save(binary(), map()) -> ok | {error, term()}.
save(SessionId, Session) ->
    Dir = sessionDir(),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Path = filename:join(Dir, sessionFileName(SessionId)),
    Payload = #{
        id => maps:get(id, Session),
        messages => encodeMessages(maps:get(messages, Session, [])),
        createdAt => maps:get(createdAt, Session, 0),
        updatedAt => maps:get(updatedAt, Session, 0)
    },
    file:write_file(Path, llmJson:encode(Payload)).

%% @doc 从磁盘加载指定会话。
%% @param SessionId 会话标识（binary）
%% @returns `{ok, map()}` 含 atom key 的会话 map，或 `{error, term()}`
-spec load(binary()) -> {ok, map()} | {error, term()}.
load(SessionId) ->
    Path = filename:join(sessionDir(), sessionFileName(SessionId)),
    case file:read_file(Path) of
        {ok, Bin} ->
            Map = llmJson:decode(Bin),
            {ok, #{
                id => maps:get(<<"id"/utf8>>, Map),
                messages => decodeMessages(maps:get(<<"messages"/utf8>>, Map, [])),
                createdAt => maps:get(<<"createdAt"/utf8>>, Map, 0),
                updatedAt => maps:get(<<"updatedAt"/utf8>>, Map, 0)
            }};
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc 删除磁盘上的会话 JSON 文件。
%% @param SessionId 会话标识（binary）
%% @returns `ok` 或 `{error, term()}`
-spec delete(binary()) -> ok | {error, term()}.
delete(SessionId) ->
    file:delete(filename:join(sessionDir(), sessionFileName(SessionId))).

%% @doc 列举所有已保存的会话 ID。
%% @returns `[binary()]` 会话 ID 列表；目录不存在时返回空列表
-spec list() -> [binary()].
list() ->
    Dir = sessionDir(),
    case filelib:is_dir(Dir) of
        true ->
            Files = filelib:wildcard(filename:join(Dir, "*.json")),
            [sessionIdFromFile(F) || F <- Files];
        false ->
            []
    end.

%% 将会话 ID 转为文件名 `<SessionId>.json`
sessionFileName(SessionId) ->
    binary_to_list(SessionId) ++ ".json".

%% 从文件路径提取会话 ID（去掉 .json 后缀）
sessionIdFromFile(Path) ->
    Base = filename:basename(Path, ".json"),
    list_to_binary(Base).

%% 批量编码消息列表为 JSON 兼容格式
encodeMessages(Messages) ->
    [encodeMessage(M) || M <- Messages].

%% 编码单条消息：支持普通 content、assistant tool_calls、tool 回复等形态
encodeMessage(#{role := Role, content := Content}) ->
    #{<<"role"/utf8>> => atom_to_binary(Role, utf8), <<"content"/utf8>> => toBinary(Content)};
encodeMessage(#{role := Role, tool_calls := Calls}) ->
    #{
        <<"role"/utf8>> => atom_to_binary(Role, utf8),
        <<"tool_calls"/utf8>> => Calls,
        <<"content"/utf8>> => null
    };
encodeMessage(#{role := Role, tool_call_id := Id, content := Content}) ->
    #{
        <<"role"/utf8>> => atom_to_binary(Role, utf8),
        <<"tool_call_id"/utf8>> => toBinary(Id),
        <<"content"/utf8>> => toBinary(Content)
    };
encodeMessage(M) ->
    M.

%% 批量解码 JSON 消息列表为内部 atom role 格式
decodeMessages(List) ->
    [decodeMessage(M) || M <- List].

%% 解码单条消息；未知字段保留 binary key，避免动态创建原子
decodeMessage(#{<<"role"/utf8>> := <<"tool"/utf8>>, <<"tool_call_id"/utf8>> := Id, <<"content"/utf8>> := Content}) ->
    #{role => tool, tool_call_id => Id, content => Content};
decodeMessage(#{<<"role"/utf8>> := Role, <<"content"/utf8>> := Content, <<"tool_calls"/utf8>> := Calls}) ->
    #{role => binary_to_existing_atom(Role, utf8), content => Content, tool_calls => Calls};
decodeMessage(#{<<"role"/utf8>> := Role, <<"content"/utf8>> := Content}) ->
    #{role => binary_to_existing_atom(Role, utf8), content => Content};
decodeMessage(M) when is_map(M) ->
    %% 未知字段保留 binary key，避免动态创建原子导致原子表耗尽
    M.

%% 将任意值转为 binary；null 转为空串，其他非 binary/list 用 ~p 格式化
toBinary(X) when is_binary(X) -> X;
toBinary(X) when is_list(X) -> unicode:characters_to_binary(X);
toBinary(null) -> <<""/utf8>>;
toBinary(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).