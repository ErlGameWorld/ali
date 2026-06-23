-ifndef(__common_h__).
-define(__common_h__, true).

%% IF-DO表达式
-define(If(IFTure, DoThat), (IFTure) andalso (DoThat)).

%% 三目元算符
-define(Case(Cond, Then, That), case Cond of true -> Then; _ -> That end).
-define(Case(Expr, Expect, Then, ExprRet, That), case Expr of Expect -> Then; ExprRet -> That end).


-endif.
