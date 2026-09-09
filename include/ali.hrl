-ifndef(__ali_h__).
-define(__ali_h__, true).

%% IF-DO表达式
-define(If(IFTure, DoThat), (IFTure) andalso (DoThat)).

%% 三目元算符
-define(Case(Cond, Then, That), case Cond of true -> Then; _ -> That end).
-define(Case(Expr, Expect, Then, ExprRet, That), case Expr of Expect -> Then; ExprRet -> That end).

-define(alErr(Format, Args), logger:error(Format, Args)).
-define(alWarn(Format, Args), logger:warning(Format, Args)).
-define(alInfo(Format, Args), logger:info(Format, Args)).

-endif.
