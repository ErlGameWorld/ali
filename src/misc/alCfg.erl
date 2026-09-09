%%%-------------------------------------------------------------------
%%% @doc alCfg 配置存取模块（运行时由 {@link alKvsToBeam} 从 aliCfg.cfg 生成）。
%%%
%%% 启动前为占位实现；{@link alConfig:load/0} 成功后
%%% {@link alCfg:getV/1} 由生成的 beam 提供。
%%% 加载前回退到 persistent_term 中的 KVs，避免早期启动查询返回 undefined。
%%% @end
%%%-------------------------------------------------------------------
-module(alCfg).

-export([getV/1]).

-spec getV(term()) -> term().
getV(Key) ->
    case persistent_term:get({alConfig, kvs}, undefined) of
        undefined -> undefined;
        KVs -> proplists:get_value(Key, KVs, undefined)
    end.
