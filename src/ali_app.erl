%%%-------------------------------------------------------------------
%%% @doc ali OTP 应用回调模块。
%%%
%%% 在 {@code rebar3 shell} 或 {@code application:ensure_all_started(ali)}
%%% 时由 OTP 框架调用，负责：
%%% <ol>
%%%   <li>加载 {@code config.cfg}（{@link llmCliConfig:load/0}）</li>
%%%   <li>启动顶层监督者 {@link ali_sup}</li>
%%%   <li>若配置了 {@code webEnabled => true}，自动启动 Web UI</li>
%%% </ol>
%%%
%%% 对外 API 请使用 {@link ali} 模块，不要直接调用本模块。
%%% @end
%%%-------------------------------------------------------------------
-module(ali_app).

-behaviour(application).

-export([start/2, stop/1]).

%% @doc OTP 应用启动回调。
-spec start(application:start_type(), any()) -> {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    llmCliConfig:load(),
    case ali_sup:start_link() of
        {ok, _} = Ok ->
            maybe_start_web(),
            Ok;
        Other ->
            Other
    end.

%% 若 config.cfg 中 webEnabled 为 true，启动 HTTP 服务
maybe_start_web() ->
    case application:get_env(ali, webEnabled) of
        {ok, true} ->
            _ = alWebSrv:start_web(),
            ok;
        _ ->
            ok
    end.

%% @doc OTP 应用停止回调。
-spec stop(any()) -> ok.
stop(_State) ->
    ok.