%%% @doc EUnit tests for ali public API exports.
-module(al_tests).

-include_lib("eunit/include/eunit.hrl").

critical_exports_test() ->
    Exports = ali:module_info(exports),
    Critical = [
        {ask, 1}, {ask, 2},
        {askStream, 1}, {askStream, 2},
        {askAsync, 1}, {askAsync, 2},
        {agent, 1}, {agent, 2},
        {approve, 1}, {dismiss, 1},
        {pendingTask, 1}, {pendingList, 0},
        {createSession, 1}, {getSession, 1},
        {saveSession, 1}, {loadSession, 1},
        {sessionMessages, 1}, {cancelAsk, 0},
        {taskStatus, 1}, {cancelTask, 1}, {tasks, 0},
        {serverStatus, 0}, {serverSessions, 0},
        {getConfig, 0}, {setConfig, 2},
        {getMode, 0}, {setMode, 1},
        {health, 0},
        {index, 1}, {search, 1}, {search, 2},
        {callTool, 2},
        {validatePatch, 1}, {dryRunPatch, 1},
        {applyPatch, 1}, {applyPatchBatch, 1}, {rollbackPatch, 0},
        {dbQuery, 1}, {dbStatus, 0},
        {remember, 3}, {recall, 1}, {recallSemantic, 1},
        {runtime, 0}, {coreHealth, 0}, {coreStatus, 0},
        {processes, 1}, {etsTables, 1},
        {tools, 0}, {toolSpec, 1},
        {metrics, 0}, {auditLog, 0},
        {simulate, 1}, {supervisorTree, 0}
    ],
    [?assert(lists:member(MFA, Exports)) || MFA <- Critical].
