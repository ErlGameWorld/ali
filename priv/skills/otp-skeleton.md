---
name: otp-skeleton
triggers: ["gen_server", "gen_statem", "supervisor", "骨架", "skeleton", "行为模式", "behaviour", "otp 模板"]
tools: [writeFile, getSymbolSource, verifyCompile, moduleExports, applyPatch]
---

## 技能：OTP 行为模式骨架生成

当用户要求生成或重构 `gen_server` / `gen_statem` / `supervisor` / `gen_event` 骨架时，严格按以下步骤。

### 工作流

1. **确认行为模式**：明确目标是哪种 behaviour，确认模块名与回调模式。
2. **读现有代码**（如重构）：用 `getSymbolSource` 看现有实现，保留业务逻辑。
3. **生成骨架**：按下方规范模板生成，包含所有必需回调 + 常用可选回调（新建用 `writeFile`，增量改用 `applyPatch`）。
4. **编译验证**：`verifyCompile` 确认无语法/警告。
5. **核对 exports**：`moduleExports` 确认回调齐全。

### gen_server 规范

```erlang
-module(Name).
-behaviour(gen_server).

%% API
-export([start_link/0, start_link/1]).
-export([stop/1]).
%% 按需导出业务 API

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {}).
-type state() :: #state{}.

%%% API
start_link() -> start_link([]).
start_link(Args) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

stop(Pid) -> gen_server:stop(Pid).

%%% gen_server callbacks
init(Args) -> {ok, #state{}}.

handle_call(_Request, _From, State) -> {reply, ok, State}.
handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.
```

### supervisor 规范

```erlang
-module(Name_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init(_Args) ->
    SupFlags = #{strategy => one_for_one, intensity => 10, period => 60},
    Children = [
        %% #{id => Id, start => {M, F, A}, restart => permanent,
        %%   shutdown => 5000, type => worker, modules => [M]}
    ],
    {ok, {SupFlags, Children}}.
```

### gen_statem 规范

```erlang
-module(Name).
-behaviour(gen_statem).

-export([start_link/0]).
-export([callback_mode/0, init/1, handle_event/4]).

start_link() -> gen_statem:start_link({local, ?MODULE}, ?MODULE, [], []).

callback_mode() -> state_functions.  %% 或 handle_event_function

init(_Args) -> {ok, state_name, #{}}.

%% state_functions 模式：每个状态一个函数
%% state_name(EventType, EventData, StateData) -> ...
handle_event(_EventType, _EventData, _StateName, StateData) ->
    {next_state, _StateName, StateData}.
```

### 检查清单

- [ ] `-behaviour(...)` 声明存在
- [ ] 所有必需回调已导出且实现
- [ ] `init/1` 返回值格式正确（`{ok, State}` / `{ok, State, Timeout}` / `ignore` / `{stop, Reason}`）
- [ ] `handle_call/3` 每个 clause 有明确返回（`{reply,_,_}` / `{noreply,_}` / `{stop,_,_,_}`）
- [ ] supervisor 的 `child_spec` 含 `id`/`start`/`restart`/`shutdown`/`type`
- [ ] 编译无 `missing_callback` 警告
