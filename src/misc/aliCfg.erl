%%%-------------------------------------------------------------------
%%% @doc aliCfg 配置存取模块（运行时由 {@link alKvsToBeam} 从 aliCfg.cfg 生成）。
%%%
%%% 启动前为占位实现；{@link alConfig:load/0} 成功后
%%% {@link aliCfg:getV/1} 由生成的 beam 提供。
%%% @end
%%%-------------------------------------------------------------------
-module(aliCfg).

-export([getV/1]).

-spec getV(term()) -> term().
getV(_Key) ->
    undefined.
