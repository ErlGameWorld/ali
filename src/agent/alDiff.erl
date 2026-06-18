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
%% 构建 LCS 动态规划表：Table[I][J] 表示 OldLines 前 I 行与 NewLines 前 J 行的 LCS 长度
build_lcs_table([], _) -> [[]];
build_lcs_table(_, []) -> [[]];
build_lcs_table(OldLines, NewLines) ->
    N = length(NewLines),
    InitRow = lists:duplicate(N + 1, 0),
    {_, Table} = lists:foldl(fun(OL, {PrevRow, Acc}) ->
        Row = build_row(OL, NewLines, PrevRow, [0]),
        {Row, [Row | Acc]}
    end, {InitRow, []}, OldLines),
    lists:reverse([InitRow | Table]).

%% 计算 DP 表中单行的各列 LCS 长度值
build_row(_OL, [], _PrevRow, Acc) ->
    lists:reverse(Acc);
build_row(OL, [NL | Ns], [Above | AboveRest] = _PrevRow, [Diag | _] = Acc) ->
    Val = case OL =:= NL of
        true -> Diag + 1;
        false -> max(hd(Acc), Above)
    end,
    build_row(OL, Ns, AboveRest, [Val | Acc]).

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

%% 读取 DP 表中 (I, J) 位置的 LCS 长度；越界返回 0
cell(Table, I, J) ->
    case I < 1 orelse J < 1 of
        true -> 0;
        false -> lists:nth(J, lists:nth(I, Table))
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