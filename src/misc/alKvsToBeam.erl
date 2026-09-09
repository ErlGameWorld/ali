%%%-------------------------------------------------------------------
%%% @doc 运行时键值表 → beam 编译器。
%%%
%%% 把 `{Key, Value}' 列表编译为指定 Module 的 `getV/1' 函数，
%%% 运行时加载该 beam 即可 O(1) 查询。用于把 `aliCfg.cfg' 动态
%%% 生成为 {@link alCfg} 模块，避免每次读 ETS 或文件。
%%%
%%% 生成结构：
%%% ```
%%% -module(Module).
%%% -export([getV/1]).
%%% getV(Key1) -> Value1;
%%% ...
%%% getV(_) -> DefValue.   %% DefValue = undefined 时返回 undefined
%%% '''
%%%
%%% 注意：map 类型不能作为函数子句的匹配 key。
%%% @end
%%%-------------------------------------------------------------------
-module(alKvsToBeam).

-export([
	load/2
	, load/3
]).

%% 注意 map类型的数据不能当做key
-type key() :: atom() | binary() | bitstring() | float() | integer() | list() | tuple().
-type value() :: atom() | binary() | bitstring() | float() | integer() | list() | tuple() | map().

%%--------------------------------------------------------------------
%% @doc
%% 编译 KVs 为 Module 的 getV/1 函数并加载，未命中键返回 undefined。
%%
%% @param Module 目标模块名（atom）
%% @param KVs    {Key, Value} 列表
%% @return ok
%% @end
%%--------------------------------------------------------------------
-spec load(term(), [{key(), value()}]) -> ok.
load(Module, KVs) ->
	load(Module, KVs, undefined).

%%--------------------------------------------------------------------
%% @doc
%% 编译 KVs 为 Module 的 getV/1 函数并加载，未命中键返回 DefValue。
%% 流程：构造 Erlang 抽象语法形式 → 编译为 beam 二进制 →
%% 软清除旧版本 → 加载新版本。
%%
%% @param Module   目标模块名（atom）
%% @param KVs      {Key, Value} 列表
%% @param DefValue 未命中键时的默认返回值
%% @return ok
%% @end
%%--------------------------------------------------------------------
-spec load(term(), [{key(), value()}], term()) -> ok.
load(Module, KVs, DefValue) ->
	%% EUnit/NFS 冷启动时 compile:forms 会先拉起整个 compiler app，可能很慢。
	_ = application:ensure_all_started(compiler),
	Forms = forms(Module, KVs, DefValue),
	{ok, Module, Bin} = compile:forms(Forms),
	code:soft_purge(Module),
	{module, Module} = code:load_binary(Module, [], Bin),
	ok.

%%--------------------------------------------------------------------
%% @doc
%% 构造目标模块的抽象语法形式：包含 -module 属性、-export 属性
%% 以及 getV/1 函数定义（每个键对应一条子句，最后追加兜底子句）。
%%
%% @param Module   模块名
%% @param KVs      键值列表
%% @param DefValue 兜底默认值
%% @return erl_syntax 已 revert 的语法形式列表
%% @end
%%--------------------------------------------------------------------
forms(Module, KVs, DefValue) ->
	%% -module(Module).
	Mod = erl_syntax:attribute(erl_syntax:atom(module), [erl_syntax:atom(Module)]),
	%% -export([getV/1]).
	ExportList = [erl_syntax:arity_qualifier(erl_syntax:atom(getV), erl_syntax:integer(1))],
	Export = erl_syntax:attribute(erl_syntax:atom(export), [erl_syntax:list(ExportList)]),
	%% getV(K) -> V
	Function = erl_syntax:function(erl_syntax:atom(getV), lookupClauses(KVs, DefValue, [])),
	[erl_syntax:revert(X) || X <- [Mod, Export, Function]].

%% 构造一条匹配指定 Key 的函数子句：getV(Key) -> Value.
lookupClause(Key, Value) ->
	Var = erl_syntax:abstract(Key),
	Body = erl_syntax:abstract(Value),
	erl_syntax:clause([Var], [], [Body]).

%% 构造兜底子句：getV(_) -> DefValue.
lookupClauseAnon(DefValue) ->
	Var = erl_syntax:variable("_"),
	Body = erl_syntax:abstract(DefValue),
	erl_syntax:clause([Var], [], [Body]).

%%--------------------------------------------------------------------
%% @doc
%% 把 KVs 转换为 getV/1 的子句列表，并在末尾追加兜底子句。
%% 使用累加器收集子句，最后反转并 flatten。
%%
%% @param KVs      待处理的键值列表
%% @param DefValue 兜底默认值
%% @param Acc      已收集的子句累加器
%% @return erl_syntax clause 列表
%% @end
%%--------------------------------------------------------------------
lookupClauses([], DefValue, Acc) ->
	lists:reverse(lists:flatten([lookupClauseAnon(DefValue) | Acc]));
lookupClauses([{Key, Value} | T], DefValue, Acc) ->
	lookupClauses(T, DefValue, [lookupClause(Key, Value) | Acc]).
