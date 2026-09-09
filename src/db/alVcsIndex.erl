%%%-------------------------------------------------------------------
%% @doc 统一版本控制抽象层：自动检测 git/svn，委托给对应后端。
%%
%% 调用方（如 {@link alChangeImpact}、{@link alContextEngine}）只依赖本模块，
%% 无需关心底层是 git 还是 svn。检测结果缓存在 `persistent_term'，避免
%% 每次操作都 shell out `git rev-parse' / `svn info'。
%%
%% 后端：
%% <ul>
%% <li>git → {@link alGitIndex}</li>
%% <li>svn → {@link alSvnIndex}</li>
%% </ul>
%%
%% 检测优先级：git 优先（git 仓库里可能有 svn:ignore 属性但仍是 git），
%% 其次 svn。
%%
%% 重要：git/svn 通过本进程 Erlang `open_port({spawn_executable, ...})` 启动，
%% **不经过** `runMfa`，也不受 `runMfaBlacklist`（含 open_port）影响。
%% @end
%%%-------------------------------------------------------------------

-module(alVcsIndex).

-export([
    vcsType/0,
    diagnose/0,
    isVcsRepo/1,
    incrementalIndex/0,
    incrementalIndex/1,
    recentCommits/0,
    recentCommits/1,
    recentCommits/2,
    listCommits/1,
    searchCommits/1,
    commitFiles/1,
    commitDiff/1,
    recentFiles/0,
    recentFiles/1,
    recentFiles/2,
    vcsFileFilter/1,
    clearRecentCache/0,
    clearTypeCache/0,
    normalizePath/1
]).

-define(TypeCacheKey, {?MODULE, vcsType}).
-define(VcsHint,
        <<"VCS 工具在本进程内 open_port 启动 git/svn，与 runMfa 黑名单无关。"
          "请确认：1) PATH 有 git 或 svn；2) projectRoot 指向检出目录；"
          "3) 网络盘/权限允许执行。若仍报 dubious ownership，可手动："
          "git config --global --add safe.directory <仓库路径>"/utf8>>).

-define(DubiousHint(Root),
        iolist_to_binary(io_lib:format(
            "Git 拒绝「所有者可疑」的仓库（NFS/多用户常见）。"
            "ali 已对本进程注入 safe.directory；若仍失败请在该机执行：~n"
            "  git config --global --add safe.directory ~ts",
            [Root]))).

%%%===================================================================
%%% 类型检测
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 检测当前项目根的版本控制类型：git 优先，其次 svn，都不匹配返回 unknown。
%% 结果缓存在 persistent_term，测试时调 {@link clearTypeCache/0} 重置。
%%
%% @return git | svn | unknown
%% @end
%%--------------------------------------------------------------------
vcsType() ->
    case persistent_term:get(?TypeCacheKey, undefined) of
        undefined ->
            refreshType();
        {unknown, _Ts} ->
            %% unknown 不长期缓存：修好 PATH/safe.directory 后应立刻可重试
            refreshType();
        {Cached, Ts} ->
            case erlang:system_time(second) - Ts > 300 of
                true -> refreshType();
                false -> Cached
            end
    end.

refreshType() ->
    {Type, _} = detectTypeDetail(),
    persistent_term:put(?TypeCacheKey, {Type, erlang:system_time(second)}),
    Type.

%%--------------------------------------------------------------------
%% @doc
%% 诊断当前 VCS 可用性（含失败原因），供工具/UI 展示，不吞错。
%% @end
%%--------------------------------------------------------------------
-spec diagnose() -> map().
diagnose() ->
    Root = projectRoot(),
    {Type, Detail} = detectTypeDetail(),
    Base = #{
        root => unicode:characters_to_binary(Root),
        type => Type,
        hint => hintFor(Detail, Root)
    },
    case Type of
        unknown -> Base#{ok => false, detail => Detail};
        _ -> Base#{ok => true, detail => Detail}
    end.

hintFor(#{git := {dubiousOwnership, _, _}}, Root) ->
    ?DubiousHint(Root);
hintFor(#{git := {gitExit, _, Out}}, Root) ->
    case is_list(Out) andalso string:find(Out, "dubious ownership") =/= nomatch of
        true -> ?DubiousHint(Root);
        false -> ?VcsHint
    end;
hintFor(_, _) ->
    ?VcsHint.

%%--------------------------------------------------------------------
%% @doc 清除类型检测缓存（测试/切换仓库时用）。
%% @end
%%--------------------------------------------------------------------
clearTypeCache() ->
    persistent_term:erase(?TypeCacheKey),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% 检测指定目录是否为版本控制仓库（git 或 svn）。
%% @end
%%--------------------------------------------------------------------
isVcsRepo(Root) ->
    alGitIndex:isGitRepo(Root) orelse alSvnIndex:isSvnRepo(Root).

%%--------------------------------------------------------------------
%% @doc
%% 统一增量索引：自动选 git/svn 后端，汇总变更后触发 Rust `/index`。
%% 工具入口用 {@link incrementalIndex/1}；无参版用 projectRoot。
%% @end
%%--------------------------------------------------------------------
-spec incrementalIndex() -> {ok, map()} | {error, term()}.
incrementalIndex() ->
    incrementalIndex(projectRoot()).

-spec incrementalIndex(file:filename()) -> {ok, map()} | {error, term()}.
incrementalIndex(Root) ->
    R = unicode:characters_to_list(Root),
    case detectBackend(R) of
        git ->
            case alGitIndex:incrementalIndex(R) of
                {ok, Map} -> {ok, Map#{backend => git}};
                Err -> Err
            end;
        svn ->
            alSvnIndex:incrementalIndex(R);
        unknown ->
            Diag = diagnose(),
            {error, #{
                reason => notVcsRepo,
                detail => maps:get(detail, Diag, undefined),
                root => unicode:characters_to_binary(R),
                hint => maps:get(hint, Diag, ?VcsHint)
            }}
    end.

%% 按指定根目录探测后端（不经 persistent_term 缓存，便于工具传自定义 root）。
detectBackend(Root) ->
    case alGitIndex:probeRepo(Root) of
        {ok, git} -> git;
        _ ->
            case alSvnIndex:probeRepo(Root) of
                {ok, svn} -> svn;
                _ -> unknown
            end
    end.

%%--------------------------------------------------------------------
%% @doc 路径归一化：委托 alGitIndex（git/svn 通用）。
%% @end
%%--------------------------------------------------------------------
normalizePath(Path) ->
    alGitIndex:normalizePath(Path).

%%%===================================================================
%%% 委托 API — 提交历史与 diff
%%%===================================================================

recentCommits() ->
    delegate(recentCommits, []).

recentCommits(N) ->
    delegate(recentCommits, [N]).

recentCommits(N, Days) ->
    delegate(recentCommits, [N, Days]).

%%--------------------------------------------------------------------
%% @doc 按 Opts 列提交（limit/days/grep/author/path/withFiles）。
%% @end
%%--------------------------------------------------------------------
listCommits(Opts) when is_map(Opts) ->
    delegate(listCommits, [Opts]).

%%--------------------------------------------------------------------
%% @doc 按提交说明搜索（git --grep / svn --search）。
%% @end
%%--------------------------------------------------------------------
searchCommits(Opts) when is_map(Opts) ->
    delegate(searchCommits, [Opts]).

commitFiles(Ref) ->
    delegate(commitFiles, [Ref]).

commitDiff(Ref) ->
    delegate(commitDiff, [Ref]).

%%%===================================================================
%%% 委托 API — 最近变更文件（加权用）
%%%===================================================================

recentFiles() ->
    delegate(recentFiles, []).

recentFiles(Root) ->
    delegate(recentFiles, [Root]).

recentFiles(Root, Days) ->
    delegate(recentFiles, [Root, Days]).

%%--------------------------------------------------------------------
%% @doc
%% 统一 VCS 文件过滤：按仓库类型委托 git/svn 后端。
%% `Opts' 可含 `modifiedSince' / `author' / `vcsStatus' / `root'。
%% @end
%%--------------------------------------------------------------------
-spec vcsFileFilter(map()) -> map().
vcsFileFilter(Opts) when is_map(Opts) ->
    Root0 = case maps:get(root, Opts, undefined) of
        undefined -> unicode:characters_to_list(projectRoot());
        R -> unicode:characters_to_list(R)
    end,
    case detectBackend(Root0) of
        git -> alGitIndex:vcsFileFilter(Opts);
        svn -> alSvnIndex:vcsFileFilter(Opts);
        unknown -> #{files => [], count => 0, reason => noVcs}
    end.

clearRecentCache() ->
    alGitIndex:clearRecentCache(),
    ok.

%%%===================================================================
%%% Internal
%%%===================================================================

projectRoot() ->
    try alConfig:projectRoot() catch _:_ -> "." end.

%% 实际检测：git 优先；返回 {Type, Detail}。
detectTypeDetail() ->
    Root = projectRoot(),
    try
        case alGitIndex:probeRepo(Root) of
            {ok, git} ->
                {git, #{backend => git, probe => ok}};
            {error, GitErr} ->
                case alSvnIndex:probeRepo(Root) of
                    {ok, svn} ->
                        {svn, #{backend => svn, probe => ok, gitProbe => GitErr}};
                    {error, SvnErr} ->
                        {unknown, #{git => GitErr, svn => SvnErr}}
                end
        end
    catch
        Class:Reason ->
            {unknown, #{exception => {Class, Reason}}}
    end.

%% 按检测到的类型委托给对应后端。
delegate(Fun, Args) ->
    case vcsType() of
        git -> apply(alGitIndex, Fun, Args);
        svn -> apply(alSvnIndex, Fun, Args);
        unknown -> wrapUnknown(Fun, Args)
    end.

wrapUnknown(recentFiles, _) ->
    ordsets:new();
wrapUnknown(_Fun, _Args) ->
    Diag = diagnose(),
    {error, #{
        reason => notVcsRepo,
        detail => maps:get(detail, Diag, undefined),
        root => maps:get(root, Diag, <<".">>),
        hint => maps:get(hint, Diag, ?VcsHint)
    }}.
