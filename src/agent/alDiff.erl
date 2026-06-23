%%%-------------------------------------------------------------------
%%% @doc 文本差异格式化模块。
%%%
%%% 基于动态规划最长公共子序列（LCS）算法，对两段二进制文本
%%% 按行计算增删差异，输出带行号前缀的 unified 风格文本
%%% （`+N: ...` 表示新增，`-N: ...` 表示删除），供写文件前预览变更。
%%% @end
%%%-------------------------------------------------------------------
-module(alDiff).

-export([format/2]).

%% @doc 比较两段文本并返回格式化的 diff 结果。
%% 内部将输入按换行符拆分为行列表，经 LCS 回溯得到编辑序列后格式化输出。
%% DP 表使用 `array:array(array:array(integer()))` 实现 O(1) 随机访问，
%% 避免原 `lists:nth` 的 O(N³) 级回溯复杂度。
%% @param Old 修改前的文件内容（binary）
%% @param New 修改后的文件内容（binary）
%% @returns `{binary()}` 每行一条 diff，以换行符连接
-spec format(binary(), binary()) -> binary().
format(Old, New) ->
    OldLines = split_lines(Old),
    NewLines = split_lines(New),
    Diff = lcs_diff(OldLines, NewLines),
    unicode:characters_to_binary(string:join(Diff, "\n")).

%% 将二进制内容按 `\n` 拆分为行列表；空内容返回空列表
split_lines(Bin) ->
    case Bin of
        <<>> -> [];
        _ -> binary:split(Bin, <<"\n"/utf8>>, [global])
    end.

%% 基于动态规划 LCS 的 diff 算法
%% DP LCS 构建 + 回溯 → 编辑序列并直接格式化输出
lcs_diff(OldLines, NewLines) ->
    Table = build_lcs_table(OldLines, NewLines),
    Edits = backtrack(Table, OldLines, NewLines, length(OldLines), length(NewLines), []),
    lists:reverse(format_edits(Edits, [])).

%% ===== DP LCS table =====
%% 构建 LCS 动态规划表：每行为 `array:array(integer())`，Table 是 `list(array)`。
%% Table[I] 为第 I 行（I 从 1 开始），Table[I][J] 表示 OldLines 前 I 行与
%% NewLines 前 J 行的 LCS 长度（J 列从 0 开始，0 列均为 0）。
build_lcs_table([], _NewLines) -> [];
build_lcs_table(_OldLines, []) -> [];
build_lcs_table(OldLines, NewLines) ->
    N = length(NewLines),
    InitRow = array:new(N + 1, {default, 0}),
    {_, TableList} = lists:foldl(fun(OL, {PrevRow, Acc}) ->
        Row = build_row_array(OL, NewLines, PrevRow, N),
        {Row, [Row | Acc]}
    end, {InitRow, []}, OldLines),
    %% Table 按行索引 I=1..M，每行含列 J=0..N；0 列始终为 0
    [InitRow | lists:reverse(TableList)].

%% 用 array 构建 DP 表的单行：Row[J] = LCS(OldLines[1..I], NewLines[1..J])
%% 遍历 NewLines 各列（J 从 1 开始），用前一行 (Above) 与本行前一列 (Left) 及对角线值计算
build_row_array(_OL, _NewLines, _PrevRow, 0) ->
    %% N=0 时仅一行 0 列
    array:new(1, {default, 0});
build_row_array(OL, NewLines, PrevRow, N) ->
    NewLineList = lists:reverse(NewLines),
    {_, Row} = lists:foldl(fun(NL, {J, Arr}) ->
        Diag = array:get(J - 1, PrevRow),
        Above = array:get(J, PrevRow),
        Left = array:get(J - 1, Arr),
        Val = case OL =:= NL of
            true -> Diag + 1;
            false -> max(Left, Above)
        end,
        {J + 1, array:set(J, Val, Arr)}
    end, {1, array:set(0, 0, array:new(N + 1, {default, 0}))}, NewLineList),
    Row.

%% 读取 DP 表中 (I, J) 位置的 LCS 长度；越界返回 0。
%% Table[I] 为第 I 行 array，索引 J 从该行取值。
cell([_InitRow | _Rows], _I, J) when J < 1 -> 0;
cell([_InitRow | _Rows], I, _J) when I < 1 -> 0;
cell([_InitRow | Rows], I, J) ->
    case I > length(Rows) orelse J > array:size(hd(Rows)) - 1 of
        true -> 0;
        false ->
            Row = lists:nth(I, Rows),
            array:get(J, Row)
    end.

%% ===== Backtrack =====
%% 从 DP 表右下角回溯，生成 `{add, LineNo, Line}` 或 `{del, LineNo, Line}` 编辑序列
backtrack(_Table, [], [], _I, _J, Acc) -> Acc;
backtrack(_Table, RestO, [], _I, _J, Acc) ->
    add_all_del(lists:reverse(RestO), 1, Acc);
backtrack(_Table, [], RestN, _I, _J, Acc) ->
    add_all_add(lists:reverse(RestN), 1, Acc);
backtrack(Table, [OL | RestO], [NL | RestN], I, J, Acc) ->
    case OL =:= NL of
        true ->
            backtrack(Table, RestO, RestN, I - 1, J - 1, Acc);
        false ->
            Diag = cell(Table, I - 1, J - 1),
            Up = cell(Table, I - 1, J),
            Left = cell(Table, I, J - 1),
            if Up >= Left, Up >= Diag ->
                backtrack(Table, RestO, [NL | RestN], I - 1, J,
                    [{del, I, OL} | Acc]);
               true ->
                backtrack(Table, [OL | RestO], RestN, I, J - 1,
                    [{add, J, NL} | Acc])
            end
    end.

%% 将剩余旧行全部标记为删除编辑
add_all_del([], _N, Acc) -> Acc;
add_all_del([L | Rest], N, Acc) ->
    add_all_del(Rest, N + 1, [{del, N, L} | Acc]).

%% 将剩余新行全部标记为新增编辑
add_all_add([], _N, Acc) -> Acc;
add_all_add([L | Rest], N, Acc) ->
    add_all_add(Rest, N + 1, [{add, N, L} | Acc]).

%% ===== Format =====
%% 将编辑序列转换为带 `+`/`-` 前缀和行号的字符串列表
format_edits([], Acc) -> Acc;
format_edits([{add, N, L} | Rest], Acc) ->
    format_edits(Rest, [line(<<"+"/utf8>>, N, L) | Acc]);
format_edits([{del, N, L} | Rest], Acc) ->
    format_edits(Rest, [line(<<"-"/utf8>>, N, L) | Acc]).

%% 格式化单行 diff：`PrefixLineNo: Text`
line(Prefix, Num, Text) ->
    binary_to_list(Prefix) ++ integer_to_list(Num) ++ ": " ++ binary_to_list(Text).