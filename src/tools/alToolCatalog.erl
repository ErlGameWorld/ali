%%%-------------------------------------------------------------------
%% @doc LLM、MCP 与 HTTP gateway 的权威工具注册表。
%%
%% 工具定义由 {@link builtinTools/0} 数据驱动；列表只构建一次，
%% 缓存在 `persistent_term' 中并按名称建索引以实现 O(1) 查找。
%% 需要带超时调用时使用 {@link callWithTimeout/6}。
%% @end
%%%-------------------------------------------------------------------

-module(alToolCatalog).

%% Registry API
-export([
    builtinTools/0,
    allTools/0,
    llmSafeTools/0,
    nonLlmSafeTools/0,
    toolSpec/1,
    llmDefinitions/0,
    definitionsForMode/1,
    invoke/2,
    invoke/3,
    callWithTimeout/6,
    resolveToolName/1
]).

%% MCP API
-export([
    mcpTools/0,
    mcpResources/0,
    mcpResourceRead/1,
    mcpPrompts/0,
    mcpPromptGet/2
]).

%% Test exports — cache introspection
-export([cacheClear/0, builtinIndex/0]).

-define(BuiltinListKey, {?MODULE, builtinList}).
-define(BuiltinIndexKey, {?MODULE, builtinIndex}).

%%%===================================================================
%%% Registry: data-driven builtin definitions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 静态内置工具定义列表。每条 entry 为
%% `#{name, description, inputSchema, llmSafe}'。仅构建一次并通过
%% {@link cachedBuiltins/0} 缓存。
%%
%% @return 工具定义 map 列表
%% @end
%%--------------------------------------------------------------------
-spec builtinTools() -> [map()].
builtinTools() ->
    [
        toolDef(indexCode, <<"索引指定路径下的 Erlang 源码（默认路径见 codeRoots / projectRoot）"/utf8>>,
            objectSchema(#{
                path => stringProp(<<"待索引目录（绝对或相对路径）"/utf8>>)
            }, [<<"path">>]),
            llmSafe),
        toolDef(projectDigest,
            <<"构建/刷新 .ali/knowledge 分层知识库（map/api/data/actions/modules）。"
              "建议 /index 之后运行。"/utf8>>,
            objectSchema(#{
                maxModules => integerProp(<<"可选截断模块数；默认不限制（全量建库）"/utf8>>),
                maxSummaryWarm => integerProp(<<"warmLlm 时异步 LLM 摘要数（默认 80；不影响落盘）"/utf8>>),
                warmLlm => #{type => boolean, description => <<"为 Top 模块异步生成 LLM 摘要"/utf8>>},
                updateAgentHints => #{type => boolean,
                    description => <<"是否根据表名/动作短语软合并 agent.json（默认 true）"/utf8>>},
                pruneStaleActions => #{type => boolean,
                    description => <<"是否剔除 api 中已不存在的 auto 动作（默认 true）"/utf8>>}
            }, []),
            llmSafe),
        toolDef(searchKnowledge,
            <<"搜索 digest 与 saveKnowledge 摘要。需先 projectDigest。"/utf8>>,
            objectSchema(#{
                query => stringProp(<<"关键词 / 业务名词"/utf8>>),
                limit => integerProp(<<"最大命中数"/utf8>>)
            }, [<<"query">>]),
            llmSafe),
        toolDef(saveKnowledge,
            <<"写入已核实主题摘要，供 searchKnowledge 召回。勿写未验证猜测。"/utf8>>,
            objectSchema(#{
                topic => stringProp(<<"主题名（如 order-status / 数据查询口径）"/utf8>>),
                content => stringProp(<<"Markdown 正文"/utf8>>),
                source => stringProp(<<"来源标记（可选，默认 manual）"/utf8>>)
            }, [<<"topic">>, <<"content">>]),
            write),
        toolDef(saveAction,
            <<"固化 NL→MFA 到 actions.json（同 phrase 覆盖为手工条目）。"/utf8>>,
            objectSchema(#{
                phrase => stringProp(<<"自然语言短语，如 查订单状态"/utf8>>),
                mfa => stringProp(<<"目标 MFA，如 order_db:lookup/1"/utf8>>),
                note => stringProp(<<"备注（可选）"/utf8>>)
            }, [<<"phrase">>, <<"mfa">>]),
            write),
        toolDef(lookupAction,
            <<"查询 NL 动作词典短语 → 建议 MFA（来自 knowledge/actions.json）"/utf8>>,
            objectSchema(#{
                phrase => stringProp(<<"自然语言短语，如 查订单状态"/utf8>>)
            }, [<<"phrase">>]),
            llmSafe),
        toolDef(digestStatus,
            <<".ali/knowledge 项目知识 digest 状态"/utf8>>,
            emptySchema(),
            llmSafe),
        toolDef(searchCode, <<"搜索 Erlang 源码（bm25/vector/regex/hybrid）。"
              "命中附 sourcePreview。关键词用英文标识符。"/utf8>>,
            searchCodeSchema(),
            llmSafe),
        toolDef(coreHealth, <<"检查 Rust core 健康状态"/utf8>>,
            emptySchema(),
            llmSafe),
        toolDef(coreStatus, <<"Rust core 状态"/utf8>>,
            emptySchema(),
            llmSafe),
        toolDef(indexStatus, <<"索引构建状态（aliCore）"/utf8>>,
            emptySchema(),
            llmSafe),
        toolDef(searchUnified, <<"统一 BM25+向量搜索，可选 regex/VCS 过滤。"/utf8>>,
            objectSchema(#{
                query => stringProp(<<"搜索 query"/utf8>>),
                limit => integerProp(<<"最大命中数"/utf8>>),
                mode => stringProp(<<"bm25|vector|regex|hybrid（默认 hybrid）"/utf8>>),
                modifiedSince => stringProp(<<"VCS 时间，如 2 weeks ago"/utf8>>),
                author => stringProp(<<"VCS 作者"/utf8>>),
                vcsStatus => stringProp(<<"modified|added|untracked|deleted|renamed"/utf8>>)
            }, [<<"query">>]),
            llmSafe),
        toolDef(getSymbol, <<"按 MFA 取符号源码，默认附 source 预览。"/utf8>>,
            faSchema(),
            llmSafe),
        toolDef(moduleSymbols, <<"列出模块符号及索引源码路径"/utf8>>,
            objectSchema(#{
                module => stringProp(<<"模块名"/utf8>>)
            }, [<<"module">>]),
            llmSafe),
        toolDef(resolveModule,
            <<"模块名→真实源码路径（index/code:which/磁盘）。断言缺失前必调；勿编造路径。"/utf8>>,
            objectSchema(#{
                module => stringProp(<<"模块名，如 alAgent 或 alAgent.erl"/utf8>>)
            }, [<<"module">>]),
            llmSafe),
        toolDef(gotoDef,
            <<"跳转到 MFA 定义：file/行号 + 函数体预览。"/utf8>>,
            faSchema(),
            llmSafe),
        toolDef(findRefs,
            <<"查找 MFA 引用（byModule 摘要）。直接作答，勿逐文件复核。原始列表 format=edges。"/utf8>>,
            faSchema(),
            llmSafe),
        toolDef(callGraph,
            <<"模块级 Mermaid 调用图样本。查「谁调用某函数」请用 getCallers/findRefs，不要用本工具顶替。"/utf8>>,
            objectSchema(#{
                module => stringProp(<<"筛选涉及该 module 的边"/utf8>>),
                function => stringProp(<<"筛选涉及该 function 名的边"/utf8>>),
                arity => integerProp(<<"配合 function 按元数筛选"/utf8>>),
                maxEdges => integerProp(<<"Mermaid 最大边数（默认 60）"/utf8>>)
            }, []),
            llmSafe),
        toolDef(moduleDeps,
            <<"获取指定模块依赖的模块（经调用边）。含 Mermaid。"/utf8>>,
            objectSchema(#{
                module => stringProp(<<"模块名"/utf8>>)
            }, [<<"module">>]),
            llmSafe),
        toolDef(generateModuleDoc,
            <<"从 BEAM forms + edoc 生成模块 Markdown API 文档。writePath=auto 写入 priv/docs/api。"/utf8>>,
            objectSchema(#{
                module => stringProp(<<"模块名"/utf8>>),
                maxFunctions => integerProp(<<"最大包含函数数（默认 80）"/utf8>>),
                includeDeps => #{type => boolean,
                                 description => <<"包含 Mermaid 模块依赖图（默认 true）"/utf8>>},
                includeMarkdown => #{type => boolean,
                                     description => <<"包含 markdown 字段（默认 true）"/utf8>>},
                writePath => stringProp(<<"写入路径，或 \"auto\" 表示 priv/docs/api/<Module>.md"/utf8>>)
            }, [<<"module">>]),
            llmSafe),
        toolDef(batchRefactor,
            <<"批量重构：plan 分析影响；apply 事务性打补丁（失败回滚）；planAndApply 两者。"/utf8>>,
            objectSchema(#{
                action => stringProp(<<"plan | apply | planAndApply（默认 plan）"/utf8>>),
                modules => #{type => array, items => #{type => string},
                             description => <<"待分析影响的模块"/utf8>>},
                commit => stringProp(<<"Git/SVN ref，用于变更影响分析"/utf8>>),
                files => #{type => array, items => #{type => string},
                           description => <<"显式范围内的文件路径"/utf8>>},
                patches => #{type => array, description => <<"apply 用 patch（同 applyPatch schema）"/utf8>>,
                             items => #{type => object}},
                verifyCompile => #{type => boolean,
                                   description => <<"apply 后编译（默认 true）"/utf8>>},
                intent => stringProp(<<"可选：报告用的人类意图说明"/utf8>>)
            }, []),
            write),
        toolDef(refactor,
            <<"AST 重构生成 hunk：extract|rename|signature|spec。输出供 batchRefactor apply。"/utf8>>,
            objectSchema(#{
                action => stringProp(<<"extract | rename | signature | spec"/utf8>>),
                module => stringProp(<<"模块名"/utf8>>),
                function => stringProp(<<"函数名"/utf8>>),
                arity => integerProp(<<"元数"/utf8>>),
                newName => stringProp(<<"新函数名（extract/rename）"/utf8>>),
                newArgs => #{type => array, items => #{type => string},
                             description => <<"新参数名（extract/signature）"/utf8>>},
                startLine => integerProp(<<"提取起始行（extract）"/utf8>>),
                endLine => integerProp(<<"提取结束行（extract）"/utf8>>),
                spec => stringProp(<<"spec 正文或 \"auto\"（spec）"/utf8>>),
                scope => stringProp(<<"module | project（rename，默认 module）"/utf8>>)
            }, [<<"action">>, <<"module">>, <<"function">>, <<"arity">>]),
            write),
        toolDef(embeddingSchema, <<"Embedding 分块 schema"/utf8>>,
            emptySchema(),
            llmSafe),
        toolDef(getCallers,
            <<"谁调用了 MFA。一次返回 byModule 摘要，直接作答，勿逐文件复核。"
              "默认不带源码。原始边 format=edges。"/utf8>>,
            faSchema(),
            llmSafe),
        toolDef(getCallees,
            <<"MFA 调用了谁。本地聚合摘要；默认紧凑。"/utf8>>,
            faSchema(),
            llmSafe),
        toolDef(traceDataQuery,
            <<"从自然语言推断数据查询调用链。勿猜 get*/query* 名。低置信返回 clarifyPrompt。"/utf8>>,
            objectSchema(#{
                question => stringProp(<<"自然语言数据查询"/utf8>>),
                maxDepth => integerProp(<<"最大数据流深度（默认 5）"/utf8>>),
                maxNodes => integerProp(<<"最大 DAG 节点数（默认 50）"/utf8>>)
            }, [<<"question">>]),
            llmSafe),
        toolDef(dataSources,
            <<"列出项目中所有已索引的 ets/mnesia/sql 数据源调用点"/utf8>>,
            emptySchema(),
            llmSafe),
        toolDef(dataSourceCallers,
            <<"查询哪些函数读/写指定 ets/mnesia/sql 表"/utf8>>,
            objectSchema(#{
                table => stringProp(<<"表名（不区分大小写）"/utf8>>)
            }, [<<"table">>]),
            llmSafe),
        toolDef(paramSources,
            <<"过程内 use-def：函数参数/局部变量从何而来"/utf8>>,
            faSchema(),
            llmSafe),
        toolDef(traceDataFlow,
            <<"从目标 MFA 参数反向追踪至源的跨过程数据流 DAG"/utf8>>,
            objectSchema(#{
                module => stringProp(<<"模块名"/utf8>>),
                function => stringProp(<<"函数名"/utf8>>),
                arity => integerProp(<<"元数"/utf8>>),
                paramIndex => integerProp(<<"待追踪参数索引，从 1 起（默认 1）"/utf8>>),
                maxDepth => integerProp(<<"最大深度"/utf8>>),
                maxNodes => integerProp(<<"最大节点数"/utf8>>)
            }, [<<"function">>, <<"arity">>]),
            llmSafe),
        toolDef(getRuntime, <<"节点运行时快照：进程/内存/ETS/supervisor/oldCode。"/utf8>>,
            emptySchema(),
            llmSafe),
        toolDef(supervisorTree, <<"获取 supervisor 树（根：ali_sup 及/或 cfg supervisorRoots）"/utf8>>,
            objectSchema(#{
                roots => #{type => array, items => #{type => string},
                           description => <<"已注册 supervisor 名（默认 ali_sup + cfg）"/utf8>>},
                maxDepth => integerProp(<<"最大树深度（默认 8）"/utf8>>)
            }, []),
            llmSafe),
        toolDef(getProcesses, <<"列出进程"/utf8>>,
            objectSchema(#{
                limit => integerProp(<<"最大进程数"/utf8>>),
                sortBy => stringProp(<<"memory|messageQueueLen|reductions"/utf8>>),
                minMessageQueueLen => integerProp(<<"仅保留消息队列长度 ≥ N 的进程"/utf8>>)
            }, []),
            llmSafe),
        toolDef(processInfo,
            <<"深度 process_info：pid 字符串或注册名。"/utf8>>,
            objectSchema(#{
                pid => stringProp(<<"Pid 字符串如 <0.123.0> 或注册名"/utf8>>)
            }, [<<"pid">>]),
            llmSafe),
        toolDef(getOldCodeProcesses,
            <<"列出仍持有旧代码引用的进程（热更后可能崩溃）。"/utf8>>,
            objectSchema(#{
                limit => integerProp(<<"最大进程数（默认 50）"/utf8>>)
            }, []),
            llmSafe),
        toolDef(etsLookup,
            <<"按 key 查 ETS。有业务 MFA 时优先 runMfa。"/utf8>>,
            objectSchema(#{
                table => stringProp(<<"ETS 表名/atom"/utf8>>),
                key => #{description => <<"查询 key（JSON 值）"/utf8>>},
                limit => integerProp(<<"最大行数（默认 20，上限 200）"/utf8>>)
            }, [<<"table">>, <<"key">>]),
            llmSafe),
        toolDef(appTopology, <<"已加载 application 及其依赖图"/utf8>>,
            emptySchema(),
            llmSafe),
        toolDef(contextPreview, <<"预览历史压缩影响（不实际修改）"/utf8>>,
            objectSchema(#{
                messages => #{type => array, items => #{type => object}},
                sessionId => integerProp(<<"可选 session id"/utf8>>)
            }, []),
            llmSafe),
        toolDef(memoryDistill, <<"从 session 提取持久事实并写入长期记忆"/utf8>>,
            objectSchema(#{
                sessionId => integerProp(<<"Session id（从 session 加载消息）"/utf8>>),
                messages => #{type => array, items => #{type => object}, description => <<"内联消息（覆盖 sessionId）"/utf8>>}
            }, []),
            llmSafe),
        toolDef(gitIndex, <<"vcsIndex 别名。优先 vcsIndex（自动 git/svn）。"/utf8>>,
            objectSchema(#{
                root => stringProp(<<"仓库根目录（默认 projectRoot）"/utf8>>)
            }, []),
            llmSafe),
        toolDef(vcsIndex, <<"VCS 变更文件增量重索引（自动 git/svn）。"/utf8>>,
            objectSchema(#{
                root => stringProp(<<"仓库根目录（默认 projectRoot）"/utf8>>)
            }, []),
            llmSafe),
        toolDef(hotReload,
            <<"本节点热更：soft_purge→load→exportDiff→smoke。"
              "优先于 raw purge。soft_purge 失败除非 force=true。先 verifyCompile。"/utf8>>,
            objectSchema(#{
                module => stringProp(<<"待重载模块 atom/名"/utf8>>),
                force => #{type => boolean,
                           description => <<"soft_purge 失败时硬 purge（危险）"/utf8>>},
                smoke => stringProp(<<"可选：导出的元数 0 smoke，如 ping/0；"
                                      "默认 module_info(module)"/utf8>>)
            }, [<<"module">>]),
            llmSafe),
        toolDef(specIndex, <<"反向类型搜索：列出 -spec 引用指定类型的函数"/utf8>>,
            objectSchema(#{
                type => stringProp(<<"待查类型名（atom）"/utf8>>),
                root => stringProp(<<"项目根（默认 .）"/utf8>>),
                limit => integerProp(<<"最大结果数（默认 200）"/utf8>>)
            }, [<<"type">>]),
            llmSafe),
        toolDef(specSearch, <<"对项目中所有 -spec 声明做 regex 搜索"/utf8>>,
            objectSchema(#{
                pattern => stringProp(<<"Erlang regex（按需转义）"/utf8>>),
                root => stringProp(<<"项目根（默认 .）"/utf8>>),
                limit => integerProp(<<"最大结果数（默认 200）"/utf8>>)
            }, [<<"pattern">>]),
            llmSafe),
        toolDef(getEts, <<"列出 ETS 表"/utf8>>,
            objectSchema(#{
                limit => integerProp(<<"最大表数"/utf8>>)
            }, []),
            llmSafe),
        toolDef(runMfa,
            <<"在本 live 节点执行**单个**已导出 MFA。用户已给出明确 Mod:Fun(Args)，"
              "或本轮工具已命中唯一 MFA 时用本工具。MFA 须来自本轮工具或 @mfa，勿编造。"
              "notExported 用 exportsSample。写操 sideEffect=write。非 dbQuery。"
              "已知 MFA 优先 call= 简写。"
              "自然语言多步（修建筑+加钱等）不要连调多次 runMfa 硬凑，改用 evalErl 拼装。"/utf8>>,
            objectSchema(#{
                module => stringProp(<<"模块 atom（call= 或默认 module 时可省略）"/utf8>>),
                function => stringProp(<<"函数 atom"/utf8>>),
                args => #{type => array, items => #{},
                          description => <<"JSON 解码参数（允许 string/number/object/list）"/utf8>>},
                call => stringProp(<<"简写，如 order_db:lookup(Id) 或 user_default:ping()"/utf8>>),
                sideEffect => #{type => string, enum => [<<"read">>, <<"write">>],
                                description => <<"read=查询；write=修改"/utf8>>},
                verifyRead => #{
                    type => object,
                    description => <<"写操作可选：读 MFA 做前后快照"/utf8>>,
                    properties => #{
                        module => stringProp(<<"模块"/utf8>>),
                        function => stringProp(<<"函数"/utf8>>),
                        args => #{type => array},
                        call => stringProp(<<"简写 Mod:Fun(...)"/utf8>>)
                    }
                },
                timeout => integerProp(<<"超时 ms（默认 5000；重操作可调高）"/utf8>>)
            }, []),
            llmSafe),
        toolDef(evalErl,
            <<"把自然语言业务一次性落到本节点：先检索真实 MFA，再拼 Erlang 表达式或匿名 fun，"
              "校验后隔离执行。远程调用策略同 runMfa（须已导出、非黑名单）。"
              "适用：修建筑+加资源、组合写玩家数据、多 MFA 才能完成的运营指令。"
              "流程：searchCode/getSymbol → 写出 code → 可选 dryRun=true → 再执行。"
              "单次明确 MFA 仍用 runMfa。禁止编造 MFA 名。"/utf8>>,
            objectSchema(#{
                code => stringProp(<<"Erlang 源码：表达式（如 1+2. 或 Mod:Fun(A).）"
                                     "或匿名 fun（如 fun(X) -> X+1 end.）"/utf8>>),
                args => #{type => array, items => #{},
                          description => <<"fun 入参列表；表达式模式忽略"/utf8>>},
                dryRun => #{type => boolean,
                            description => <<"仅校验+试编译，不执行"/utf8>>},
                timeout => integerProp(<<"超时 ms（默认 5000）"/utf8>>),
                bindings => #{type => object,
                              description => <<"可选变量绑定，键须为 Erlang 变量名（如 X）"/utf8>>}
            }, [<<"code">>]),
            llmSafe),
        toolDef(dbQuery,
            <<"仅 ali 内嵌 SQLite。业务/运行时数据用 runMfa。"/utf8>>,
            objectSchema(#{
                sql => stringProp(<<"SQL 语句"/utf8>>),
                params => #{type => array},
                mode => #{type => string, enum => [<<"read">>, <<"write">>, <<"insert">>]}
            }, [<<"sql">>]),
            llmSafe),
        toolDef(remember, <<"写入长期记忆"/utf8>>,
            objectSchema(#{
                sessionId => integerProp(<<"Session id"/utf8>>),
                kind => stringProp(<<"记忆类型（note/preference/lesson/...）"/utf8>>),
                content => stringProp(<<"内容"/utf8>>),
                tags => #{type => array, items => #{type => string}},
                importance => #{type => number,
                                description => <<"重要性 0..1（默认 0.5；越高召回排序越靠前）"/utf8>>}
            }, [<<"content">>]),
            llmSafe),
        toolDef(saveLesson,
            <<"沉淀踩坑/纠正教训（symptom/rootCause/prevention 或 content）。"/utf8>>,
            objectSchema(#{
                symptom => stringProp(<<"症状 / 现象"/utf8>>),
                rootCause => stringProp(<<"根因"/utf8>>),
                prevention => stringProp(<<"规避 / 正确做法"/utf8>>),
                content => stringProp(<<"完整教训正文（可选）"/utf8>>),
                source => stringProp(<<"failure|correction|insight|manual"/utf8>>),
                tags => #{type => array, items => #{type => string}}
            }, []),
            write),
        toolDef(correctLesson,
            <<"纠正旧经验：相关 lesson 标 superseded 并写入新版。"/utf8>>,
            objectSchema(#{
                content => stringProp(<<"纠正后的正确结论"/utf8>>),
                symptom => stringProp(<<"原错误症状 / 主题"/utf8>>),
                rootCause => stringProp(<<"为何旧经验错了"/utf8>>),
                prevention => stringProp(<<"正确做法"/utf8>>),
                relatedIds => #{type => array, items => #{type => integer},
                                description => <<"显式废止的记忆 id（可选）"/utf8>>},
                relatedMfas => #{type => array, items => #{type => string}}
            }, []),
            write),
        toolDef(recallExperience,
            <<"召回本仓 lesson（过滤已废止）+ 熟悉度摘要。"/utf8>>,
            objectSchema(#{
                query => stringProp(<<"问题 / 关键词"/utf8>>),
                limit => integerProp(<<"最大教训条数（默认 5）"/utf8>>)
            }, []),
            llmSafe),
        toolDef(recall, <<"关键词召回记忆"/utf8>>,
            objectSchema(#{
                query => stringProp(<<"搜索文本"/utf8>>),
                limit => integerProp(<<"最大结果数"/utf8>>)
            }, [<<"query">>]),
            llmSafe),
        toolDef(recallSemantic, <<"语义向量召回记忆"/utf8>>,
            objectSchema(#{
                query => stringProp(<<"搜索文本"/utf8>>),
                limit => integerProp(<<"最大结果数"/utf8>>)
            }, [<<"query">>]),
            llmSafe),
        toolDef(searchMemory, <<"recallSemantic 别名"/utf8>>,
            objectSchema(#{
                query => stringProp(<<"搜索文本"/utf8>>),
                limit => integerProp(<<"最大结果数"/utf8>>)
            }, [<<"query">>]),
            llmSafe),
        toolDef(simulate,
            <<"沙箱：patch|compile|askDry 安全；mfa 仅 DRY-RUN。live MFA 用 runMfa。"/utf8>>,
            objectSchema(#{
                type => stringProp(<<"场景类型：mfa、patch、compile、askDry"/utf8>>),
                question => stringProp(<<"askDry 用问题"/utf8>>),
                module => stringProp(<<"mfa 用模块"/utf8>>),
                function => stringProp(<<"mfa 用函数"/utf8>>),
                args => #{type => array},
                patch => patchSchema()
            }, [<<"type">>]),
            llmSafe),
        toolDef(validatePatch, <<"校验源码 patch（edit 或 create/delete/rename）"/utf8>>,
            patchSchema(),
            llmSafe),
        toolDef(dryRunPatch, <<"干跑源码 patch（edit 或 create/delete/rename），不写文件"/utf8>>,
            patchSchema(),
            llmSafe),
        toolDef(applyPatch, <<"应用已校验 patch（写文件）。edit 默认；op=create 新建文件、"
              "delete 删文件、rename 重命名/移动。均走校验+备份+可回滚。"/utf8>>,
            patchSchema(),
            write),
        toolDef(applyPatchBatch, <<"事务性应用多个 patch"/utf8>>,
            objectSchema(#{
                patches => #{type => array, items => patchSchema()}
            }, [<<"patches">>]),
            write),
        toolDef(rollbackPatch, <<"回滚最近一次 patch 事务"/utf8>>,
            emptySchema(),
            write),
        toolDef(readFile,
            <<"读项目文件。大文件传 startLine+endLine。path 须来自工具命中，勿猜。"/utf8>>,
            objectSchema(#{
                path => stringProp(<<"工具返回的相对路径，勿猜测"/utf8>>),
                maxBytes => integerProp(<<"最大读取字节数（行区间模式也生效）"/utf8>>),
                startLine => integerProp(<<"起始行（1-based，与 endLine/lineCount 联用）"/utf8>>),
                endLine => integerProp(<<"结束行（含）"/utf8>>),
                lineCount => integerProp(<<"从 startLine 起读取行数（与 endLine 二选一）"/utf8>>)
            }, [<<"path">>]),
            llmSafe),
        toolDef(readFilePage,
            <<"分页读大文件：cursor 首次 null，随后传 nextCursor。勿反复加大 maxBytes。"/utf8>>,
            objectSchema(#{
                path => stringProp(<<"工具返回的相对路径"/utf8>>),
                cursor => stringProp(<<"续读游标（首次传 null；后续传上次返回的 nextCursor）"/utf8>>),
                pageSize => integerProp(<<"每页行数（默认 200）"/utf8>>)
            }, [<<"path">>]),
            llmSafe),
        toolDef(listFiles,
            <<"列目录；glob 按模式匹配（如 **/foo.erl）。"/utf8>>,
            objectSchema(#{
                path => stringProp(<<"目录路径"/utf8>>),
                recursive => #{type => boolean},
                glob => stringProp(<<"glob 模式（如 src/**/point_server.erl）"/utf8>>),
                maxEntries => integerProp(<<"最大条目数（默认 5000）"/utf8>>)
            }, [<<"path">>]),
            llmSafe),
        toolDef(searchText,
            <<"ripgrep 全文搜索；须收窄 path。读函数体优先 gotoDef/getSymbolSource。"/utf8>>,
            objectSchema(#{
                query => stringProp(<<"搜索文本（支持 rg 正则）"/utf8>>),
                path => stringProp(<<"须收窄：目录或单文件"/utf8>>),
                limit => integerProp(<<"最大匹配数"/utf8>>),
                context => integerProp(<<"每条命中附加的上下文行数（默认 3，最大 10）"/utf8>>)
            }, [<<"query">>]),
            llmSafe),
        toolDef(writeFile, <<"写入项目文件内容"/utf8>>,
            objectSchema(#{
                path => stringProp(<<"文件路径"/utf8>>),
                content => stringProp(<<"文件内容"/utf8>>)
            }, [<<"path">>, <<"content">>]),
            write),
        toolDef(getBeamAbstract, <<"从 BEAM 获取模块 abstract forms"/utf8>>,
            objectSchema(#{
                module => stringProp(<<"模块名"/utf8>>)
            }, [<<"module">>]),
            llmSafe),
        toolDef(moduleExports, <<"列出模块导出"/utf8>>,
            objectSchema(#{
                module => stringProp(<<"模块名"/utf8>>)
            }, [<<"module">>]),
            llmSafe),
        toolDef(getModuleTypes,
            <<"列出模块 -type/-opaque/-callback/-record/-spec。"/utf8>>,
            objectSchema(#{
                module => stringProp(<<"模块名"/utf8>>)
            }, [<<"module">>]),
            llmSafe),
        toolDef(getSymbolSource,
            <<"读单函数源码（默认前后各 5 行）。勿对大文件整文件 readFile。"/utf8>>,
            objectSchema(#{
                module => stringProp(<<"模块名"/utf8>>),
                function => stringProp(<<"函数名"/utf8>>),
                arity => integerProp(<<"元数"/utf8>>),
                contextLines => integerProp(<<"函数体前后扩展行数（默认 5，0–50）"/utf8>>)
            }, [<<"function">>, <<"arity">>]),
            llmSafe),
        toolDef(formatCode, <<"格式化代码片段或文件"/utf8>>,
            objectSchema(#{
                code => stringProp(<<"代码文本"/utf8>>),
                path => stringProp(<<"可选文件路径"/utf8>>)
            }, []),
            llmSafe),
        toolDef(runEunit, <<"经 rebar3 运行 EUnit 测试"/utf8>>,
            objectSchema(#{
                module => stringProp(<<"模块名或 all"/utf8>>),
                timeout => integerProp(<<"超时 ms"/utf8>>)
            }, []),
            write),
        toolDef(runDialyzer, <<"经 rebar3 运行 dialyzer"/utf8>>,
            objectSchema(#{
                command => stringProp(<<"Shell 命令（默认 rebar3 dialyzer）"/utf8>>),
                timeout => integerProp(<<"超时 ms"/utf8>>)
            }, []),
            write),
        toolDef(runTestsForPatch, <<"编译并运行 patch 涉及文件的 eunit"/utf8>>,
            objectSchema(#{
                file => stringProp(<<"单个 patch 文件"/utf8>>),
                files => #{type => array, items => #{type => string}},
                patches => #{type => array, items => #{type => object}},
                timeout => integerProp(<<"超时 ms"/utf8>>)
            }, []),
            write),
        toolDef(semanticSearch, <<"语义/向量代码搜索"/utf8>>,
            searchCodeSchema(),
            llmSafe),
        toolDef(findCallers, <<"getCallers 别名"/utf8>>,
            faSchema(),
            llmSafe),
        toolDef(findCallees, <<"getCallees 别名"/utf8>>,
            faSchema(),
            llmSafe),
        toolDef(planSet, <<"为 session 创建结构化任务计划"/utf8>>,
            objectSchema(#{
                sessionId => integerProp(<<"Session id"/utf8>>),
                steps => #{type => array, items => #{type => string}}
            }, [<<"steps">>]),
            llmSafe),
        toolDef(planGet, <<"获取当前 session 计划"/utf8>>,
            objectSchema(#{
                sessionId => integerProp(<<"Session id"/utf8>>)
            }, []),
            llmSafe),
        toolDef(planUpdate, <<"更新计划步骤状态/备注"/utf8>>,
            objectSchema(#{
                sessionId => integerProp(<<"Session id"/utf8>>),
                stepId => integerProp(<<"步骤 id"/utf8>>),
                status => stringProp(<<"pending|inProgress|done|skipped"/utf8>>),
                note => stringProp(<<"可选备注"/utf8>>)
            }, [<<"stepId">>]),
            llmSafe),
        toolDef(planClear, <<"清除 session 计划"/utf8>>,
            objectSchema(#{
                sessionId => integerProp(<<"Session id"/utf8>>)
            }, []),
            llmSafe),
        toolDef(todoWrite, <<"写入/替换多步 todo（planSet 别名）。"/utf8>>,
            objectSchema(#{
                sessionId => integerProp(<<"Session id（可省略，用当前会话）"/utf8>>),
                steps => #{type => array, items => #{type => string},
                           description => <<"步骤标题列表"/utf8>>},
                todos => #{type => array, items => #{type => string},
                           description => <<"steps 别名"/utf8>>}
            }, []),
            llmSafe),
        toolDef(todoRead, <<"planGet 别名：读取当前 session 的 todo/计划"/utf8>>,
            objectSchema(#{
                sessionId => integerProp(<<"Session id（可省略）"/utf8>>)
            }, []),
            llmSafe),
        toolDef(todoUpdate, <<"planUpdate 别名：更新某步 status/note"/utf8>>,
            objectSchema(#{
                sessionId => integerProp(<<"Session id（可省略）"/utf8>>),
                stepId => integerProp(<<"步骤 id"/utf8>>),
                id => integerProp(<<"stepId 别名"/utf8>>),
                status => stringProp(<<"pending|inProgress|done|skipped|failed"/utf8>>),
                note => stringProp(<<"可选备注"/utf8>>)
            }, []),
            llmSafe),
        toolDef(todoClear, <<"planClear 别名：清除 session todo"/utf8>>,
            objectSchema(#{
                sessionId => integerProp(<<"Session id（可省略）"/utf8>>)
            }, []),
            llmSafe),
        toolDef(delegateTo, <<"委派任务给内置子 agent"/utf8>>,
            objectSchema(#{
                agent => stringProp(<<"子 agent 名"/utf8>>),
                task => stringProp(<<"任务描述"/utf8>>)
            }, [<<"agent">>, <<"task">>]),
            llmSafe),
        toolDef(useSkill, <<"加载 skill 定义"/utf8>>,
            objectSchema(#{
                skill => stringProp(<<"Skill 名"/utf8>>)
            }, [<<"skill">>]),
            llmSafe),
        toolDef(fetchUrl,
            <<"抓取 http/https（拦内网）。HTML 抽正文 extracted=true。长文用 fetchUrlPage。"/utf8>>,
            objectSchema(#{
                url => stringProp(<<"绝对 http/https URL"/utf8>>),
                maxBytes => integerProp(<<"最大 body 字节（默认 50KB）"/utf8>>),
                timeout => integerProp(<<"超时 ms（默认 15000）"/utf8>>)
            }, [<<"url">>]),
            llmSafe),
        toolDef(fetchUrlPage,
            <<"分页读网页正文：cursor 首次 null。勿反复 fetchUrl 加大 maxBytes。"/utf8>>,
            objectSchema(#{
                url => stringProp(<<"绝对 http/https URL"/utf8>>),
                cursor => stringProp(<<"续读游标（首次传 null；后续传上次返回的 nextCursor）"/utf8>>),
                chunkBytes => integerProp(<<"每页字节（默认 24000，2000-48000）"/utf8>>),
                timeout => integerProp(<<"超时 ms（默认 15000）"/utf8>>)
            }, [<<"url">>]),
            llmSafe),
        toolDef(webQa,
            <<"搜索+抓取+汇总，返 answer 与 sources（[n]=sources[].index）。"
              "需精细控制检索时改用 webSearch+fetchUrl。"/utf8>>,
            objectSchema(#{
                question => stringProp(<<"问题（同时作为搜索 query）"/utf8>>),
                searchLimit => integerProp(<<"搜索结果数（1-10，默认 5）"/utf8>>),
                fetchLimit => integerProp(<<"抓取正文页数（1-5，默认 3）"/utf8>>),
                freshness => #{type => string,
                               enum => [<<"day">>, <<"week">>, <<"month">>, <<"year">>],
                               description => <<"时间范围过滤（可选）"/utf8>>}
            }, [<<"question">>]),
            llmSafe),
        toolDef(reviewChangeImpact, <<"深评单个 commit 的调用图影响。"
              "仅在已有 ref 后用。最后一次先 lastCommit/commitDiff。"/utf8>>,
            objectSchema(#{
                ref => stringProp(<<"Commit hash/tag/branch/revision（如 HEAD、a1b2c3d、r123）"/utf8>>),
                summaryMode => stringProp(<<"structured|natural|both（默认 both）"/utf8>>)
            }, [<<"ref">>]),
            llmSafe),
        toolDef(lastCommit,
            <<"仅最新一次 commit。问最后一次/上一笔用本工具，勿 dailyReview。"/utf8>>,
            objectSchema(#{}, []),
            llmSafe),
        toolDef(commitDiff,
            <<"单个 commit 变更（files/patch）。最后一次优先 lastCommit；深挖→reviewChangeImpact。"/utf8>>,
            objectSchema(#{
                ref => stringProp(<<"Commit hash/tag/branch/revision"/utf8>>)
            }, [<<"ref">>]),
            llmSafe),
        toolDef(commitFiles,
            <<"列出单个 commit 变更文件。"/utf8>>,
            objectSchema(#{
                ref => stringProp(<<"Commit hash/tag/branch/revision"/utf8>>)
            }, [<<"ref">>]),
            llmSafe),
        toolDef(searchCommits,
            <<"按提交信息子串搜 commit（git --grep / svn --search）。"/utf8>>,
            objectSchema(#{
                query => stringProp(<<"提交信息子串"/utf8>>),
                grep => stringProp(<<"query 别名"/utf8>>),
                limit => integerProp(<<"最大 commit 数（默认 20）"/utf8>>),
                days => integerProp(<<"仅最近 N 天内"/utf8>>),
                author => stringProp(<<"按作者过滤（git）"/utf8>>),
                path => stringProp(<<"仅涉及该路径的 commit（git）"/utf8>>),
                withFiles => #{type => boolean,
                               description => <<"每条 commit 含变更文件"/utf8>>}
            }, []),
            llmSafe),
        toolDef(dailyReview,
            <<"多日 commit 汇总。仅当用户问按天/昨天。默认 days=1。最后一次用 lastCommit。"/utf8>>,
            objectSchema(#{
                days => integerProp(<<"回溯天数；默认 1。用户未要求勿设大值。"/utf8>>),
                limit => integerProp(<<"最大 commit 数（默认 50）"/utf8>>),
                author => stringProp(<<"可选作者过滤（git）"/utf8>>),
                path => stringProp(<<"可选路径过滤（git）"/utf8>>)
            }, []),
            llmSafe),
        toolDef(reviewPackage,
            <<"结构化代码评审包（启发式发现 + 可选 VCS 影响）。提出 patch 前用。"/utf8>>,
            objectSchema(#{
                ref => stringProp(<<"可选 commit ref，含变更影响与变更文件"/utf8>>),
                files => #{type => array, items => #{type => string},
                           description => <<"待扫描源文件"/utf8>>},
                modules => #{type => array, items => #{type => string},
                             description => <<"模块名，解析为 .erl"/utf8>>},
                maxFindings => integerProp(<<"发现上限（默认 80）"/utf8>>)
            }, []),
            llmSafe),
        toolDef(recentCommits,
            <<"最近 N 条 commit。最后一次优先 lastCommit；按天汇总用 dailyReview。"/utf8>>,
            objectSchema(#{
                limit => integerProp(<<"最大 commit 数（默认 10）"/utf8>>),
                days => integerProp(<<"可选时间窗；用户未要求则省略"/utf8>>),
                author => stringProp(<<"按作者过滤（git）"/utf8>>),
                path => stringProp(<<"仅涉及路径的 commit（git）"/utf8>>),
                grep => stringProp(<<"可选提交信息过滤"/utf8>>),
                withFiles => #{type => boolean,
                               description => <<"每条 commit 含变更文件"/utf8>>}
            }, []),
            llmSafe),
        toolDef(functionHistory,
            <<"查询触及某函数的 commit 历史。"/utf8>>,
            objectSchema(#{
                module => stringProp(<<"模块名"/utf8>>),
                function => stringProp(<<"函数名"/utf8>>),
                arity => integerProp(<<"元数"/utf8>>),
                days => integerProp(<<"回溯天数（默认 90）"/utf8>>)
            }, [<<"module">>, <<"function">>, <<"arity">>]),
            llmSafe),
        toolDef(verifyCompile,
            <<"运行项目编译（rebar3）以在 patch 后验证。不写源码。"/utf8>>,
            objectSchema(#{
                compileCommand => stringProp(<<"覆盖编译命令（默认 rebar3 compile）"/utf8>>),
                compileTimeoutMs => integerProp(<<"超时 ms（默认 120000）"/utf8>>)
            }, []),
            llmSafe),
        toolDef(genTest,
            <<"为已加载模块生成 EUnit 骨架（只读，配合 writeFile 保存）。"/utf8>>,
            objectSchema(#{
                module => stringProp(<<"已加载模块名（atom 或 binary）"/utf8>>),
                exclude => #{type => array, items => #{type => string},
                             description => <<"跳过的函数名（可选）"/utf8>>}
            }, [<<"module">>]),
            llmSafe),
        toolDef(webSearch,
            <<"网页搜索。引用句末 [n]（results[].index），文末列 Sources。"
              "详情 fetchUrl/fetchUrlPage，或 webQa 一步汇总。"/utf8>>,
            objectSchema(#{
                query => stringProp(<<"搜索 query"/utf8>>),
                limit => integerProp(<<"最大结果数（1-10，默认 5）"/utf8>>),
                offset => integerProp(<<"结果偏移（翻页，默认 0）"/utf8>>),
                engine => #{type => string,
                            enum => [<<"auto">>, <<"duckduckgo">>, <<"duckduckgo_html">>,
                                     <<"wikipedia">>, <<"bing">>],
                            description => <<"搜索后端（默认 auto）"/utf8>>},
                freshness => #{type => string,
                               enum => [<<"day">>, <<"week">>, <<"month">>, <<"year">>],
                               description => <<"时间范围（仅 duckduckgo_html/bing）"/utf8>>}
            }, [<<"query">>]),
            llmSafe)
    ].

%%--------------------------------------------------------------------
%% @doc
%% 构造一条工具定义记录（map 形式）。
%%
%% @param Name 工具名（atom）
%% @param Desc 工具描述（binary）
%% @param Schema 输入参数的 JSON Schema
%% @param Safety 安全级别（llmSafe 或 write）
%% @return 工具定义 map，包含 name/description/inputSchema/llmSafe 字段
%% @end
%%--------------------------------------------------------------------
toolDef(Name, Desc, Schema, Safety) ->
    #{
        name => Name,
        description => Desc,
        inputSchema => Schema,
        llmSafe => Safety =:= llmSafe
    }.

%%--------------------------------------------------------------------
%% @doc
%% 缓存的内置工具列表（每个节点仅构建一次，存于 persistent_term）。
%%
%% @return 工具定义 map 列表
%% @end
%%--------------------------------------------------------------------
-spec cachedBuiltins() -> [map()].
cachedBuiltins() ->
    case persistent_term:get(?BuiltinListKey, undefined) of
        undefined ->
            L = builtinTools(),
            persistent_term:put(?BuiltinListKey, L),
            L;
        L ->
            L
    end.

%%--------------------------------------------------------------------
%% @doc
%% 缓存的 name → def 索引，用于 O(1) 查找（存于 persistent_term）。
%%
%% @return 工具名到定义的 map
%% @end
%%--------------------------------------------------------------------
-spec builtinIndex() -> map().
builtinIndex() ->
    case persistent_term:get(?BuiltinIndexKey, undefined) of
        undefined ->
            Index = maps:from_list([{maps:get(name, T), T} || T <- cachedBuiltins()]),
            persistent_term:put(?BuiltinIndexKey, Index),
            Index;
        Index ->
            Index
    end.

%%--------------------------------------------------------------------
%% @doc
%% 清除缓存的内置工具列表与索引（测试辅助函数）。
%%
%% @return `ok'
%% @end
%%--------------------------------------------------------------------
cacheClear() ->
    persistent_term:erase(?BuiltinListKey),
    persistent_term:erase(?BuiltinIndexKey),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% 返回所有已注册的工具名（内置 + 未来可能的自定义工具）。
%%
%% @return 工具名 atom 列表
%% @end
%%--------------------------------------------------------------------
-spec allTools() -> [atom()].
allTools() ->
    [maps:get(name, T) || T <- cachedBuiltins()].

%%--------------------------------------------------------------------
%% @doc
%% 返回被视为"LLM 可直接调用安全"的工具名列表
%% （即 `llmSafe = true' 的工具）。
%%
%% @return 工具名 atom 列表
%% @end
%%--------------------------------------------------------------------
-spec llmSafeTools() -> [atom()].
llmSafeTools() ->
    [maps:get(name, T) || T <- cachedBuiltins(), maps:get(llmSafe, T, false)].

%%--------------------------------------------------------------------
%% @doc 返回 catalog 中非 LLM-safe（默认不进 ask 模式 LLM）的工具名。
%% 旧名 `writeTools/0' 语义不准（其中也含 executeRisky 类工具，不止 write），
%% 重命名为 `nonLlmSafeTools/0' 更贴合实际过滤条件（llmSafe = false）。
%% @end
%%--------------------------------------------------------------------
-spec nonLlmSafeTools() -> [atom()].
nonLlmSafeTools() ->
    [maps:get(name, T) || T <- cachedBuiltins(), maps:get(llmSafe, T, false) =:= false].

%%--------------------------------------------------------------------
%% @doc
%% 按名称获取工具规格（spec）。未知名回退为 stub 定义。
%%
%% @param Name 工具名 atom
%% @return 工具规格 map
%% @end
%%--------------------------------------------------------------------
-spec toolSpec(atom()) -> map().
toolSpec(Name) ->
    case maps:find(Name, builtinIndex()) of
        {ok, Def} ->
            #{
                name => Name,
                description => maps:get(description, Def),
                inputSchema => maps:get(inputSchema, Def)
            };
        error ->
            #{
                name => Name,
                description => <<"Unknown tool"/utf8>>,
                inputSchema => emptySchema(),
                llmSafe => false
            }
    end.

%%--------------------------------------------------------------------
%% @doc
%% 返回 OpenAI 风格的 tool 定义列表，供 LLM API 使用
%% （仅含 `llmSafe = true' 的工具）。
%%
%% @return OpenAI tools API 兼容的 function 定义 map 列表
%% @end
%%--------------------------------------------------------------------
-spec llmDefinitions() -> [map()].
llmDefinitions() ->
    [llmToolDef(T) || T <- cachedBuiltins(), maps:get(llmSafe, T, false)].

%%--------------------------------------------------------------------
%% @doc
%% 按会话模式返回工具定义：ask 仅 llmSafe；edit/exec 额外包含 write 级工具
%% （applyPatch / writeFile / rollback 等），以便改码闭环。
%% @end
%%--------------------------------------------------------------------
-spec definitionsForMode(ask | edit | exec | term()) -> [map()].
definitionsForMode(Mode) when Mode =:= edit; Mode =:= exec ->
    [llmToolDef(T) || T <- cachedBuiltins()] ++ dynamicLlmDefs();
definitionsForMode(_) ->
    llmDefinitions() ++ dynamicLlmDefs().

%% 外部 MCP 动态工具 → OpenAI function 定义（name 保持 `"conn:tool"` binary）。
dynamicLlmDefs() ->
    [dynamicLlmDef(E) || E <- alMcpClient:dynamicTools()].

dynamicLlmDef(#{name := NameBin, spec := Spec}) when is_binary(NameBin), is_map(Spec) ->
    Desc = maps:get(description, Spec, maps:get(<<"description">>, Spec,
                   <<"外部 MCP 工具"/utf8>>)),
    Schema = maps:get(inputSchema, Spec, maps:get(<<"inputSchema">>, Spec,
                     #{<<"type">> => <<"object">>, <<"properties">> => #{}})),
    DescBin = case Desc of
        B when is_binary(B) -> B;
        A when is_atom(A) -> atom_to_binary(A, utf8);
        L when is_list(L) -> unicode:characters_to_binary(L);
        _ -> <<"外部 MCP 工具"/utf8>>
    end,
    SchemaMap = case Schema of
        M when is_map(M) -> M;
        _ -> #{<<"type">> => <<"object">>, <<"properties">> => #{}}
    end,
    #{
        type => <<"function">>,
        function => #{
            name => NameBin,
            description => DescBin,
            parameters => SchemaMap
        }
    };
dynamicLlmDef(_) ->
    #{type => <<"function">>,
      function => #{name => <<"unknown">>, description => <<>>,
                    parameters => #{<<"type">> => <<"object">>, <<"properties">> => #{}}}}.

%%--------------------------------------------------------------------
%% @doc
%% 将一条工具定义转换为 OpenAI 风格的 function tool 定义。
%%
%% @param T 工具定义 map，需含 name/description/inputSchema
%% @return OpenAI tools API 兼容的 function 定义 map
%% @end
%%--------------------------------------------------------------------
llmToolDef(#{name := Name, description := Desc, inputSchema := Schema}) ->
    #{
        type => <<"function">>,
        function => #{
            name => atom_to_binary(Name, utf8),
            description => Desc,
            parameters => compactLlmSchema(Schema)
        }
    }.

%% 发给 LLM 的 schema 去掉同义反复的 property description（MCP/HTTP 仍用原文）。
%% 只保留 enum / 默认值 / 勿/禁止/简写 等约束句。
compactLlmSchema(Schema) when is_map(Schema) ->
    S0 = dropEmptyRequired(Schema),
    S1 = compactMapField(properties, S0),
    S2 = compactMapField(items, S1),
    compactMapField(additionalProperties, S2);
compactLlmSchema(Other) ->
    Other.

dropEmptyRequired(Schema) ->
    case maps:get(required, Schema, maps:get(<<"required">>, Schema, undefined)) of
        [] -> maps:remove(required, maps:remove(<<"required">>, Schema));
        _ -> Schema
    end.

compactMapField(AtomKey, Schema) ->
    BinKey = atom_to_binary(AtomKey, utf8),
    case maps:is_key(AtomKey, Schema) of
        true ->
            Schema#{AtomKey => compactLlmField(AtomKey, maps:get(AtomKey, Schema))};
        false ->
            case maps:is_key(BinKey, Schema) of
                true ->
                    Schema#{BinKey => compactLlmField(AtomKey, maps:get(BinKey, Schema))};
                false ->
                    Schema
            end
    end.

compactLlmField(properties, Props) when is_map(Props) ->
    maps:from_list([{K, compactLlmProp(V)} || {K, V} <- maps:to_list(Props)]);
compactLlmField(_, Nested) when is_map(Nested) ->
    compactLlmSchema(Nested);
compactLlmField(_, Other) ->
    Other.

compactLlmProp(Prop) when is_map(Prop) ->
    Nested = compactLlmSchema(Prop),
    case keepLlmPropDesc(Nested) of
        true -> Nested;
        false -> maps:remove(description, maps:remove(<<"description">>, Nested))
    end;
compactLlmProp(Prop) ->
    Prop.

keepLlmPropDesc(Prop) ->
    HasEnum = maps:is_key(enum, Prop) orelse maps:is_key(<<"enum">>, Prop),
    Desc = case maps:get(description, Prop, undefined) of
        undefined -> maps:get(<<"description">>, Prop, undefined);
        D -> D
    end,
    HasEnum orelse usefulLlmDesc(Desc).

usefulLlmDesc(undefined) -> true;
usefulLlmDesc(Desc) when is_binary(Desc) ->
    llmDescHasHint(Desc);
usefulLlmDesc(_) -> true.

llmDescHasHint(Desc) ->
    Hints = [
        <<"勿"/utf8>>, <<"禁止"/utf8>>, <<"简写"/utf8>>,
        <<"别名"/utf8>>, <<"|">>, <<"危险"/utf8>>, <<"1-based">>,
        <<"read="/utf8>>, <<"write="/utf8>>, <<"仅"/utf8>>,
        <<"非"/utf8>>, <<"上限"/utf8>>, <<"必须"/utf8>>,
        <<"auto">>, <<"null">>, <<"nextCursor">>, <<"HEAD">>
    ],
    lists:any(fun(H) -> binary:match(Desc, H) =/= nomatch end, Hints).

%%%===================================================================
%%% Invocation
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 调用一个注册的工具，自动注入策略选项（mode/confirmed/policy）。
%% Args 中可带 mode/confirmed/policy；MCP 等应优先用 invoke/3。
%% @end
%%--------------------------------------------------------------------
-spec invoke(atom() | binary(), map()) -> {ok, term()} | {error, term()}.
invoke(Tool, Args) when is_map(Args) ->
    Mode = maps:get(mode, Args, mcpDefaultMode()),
    invoke(Tool, maps:without([mode, confirmed, policy], Args), #{
        mode => Mode,
        confirmed => maps:get(confirmed, Args, false),
        policy => maps:get(policy, Args, alPolicy:defaultPolicy())
    }).

%%--------------------------------------------------------------------
%% @doc 带显式 Opts 的工具调用（mode / policy / confirmed）。
%% @end
%%--------------------------------------------------------------------
-spec invoke(atom() | binary(), map(), map()) -> {ok, term()} | {error, term()}.
invoke(Tool, Args, Opts) when is_atom(Tool), is_map(Args), is_map(Opts) ->
    Mode = maps:get(mode, Opts, ask),
    BasePolicy = maps:get(policy, Opts, alPolicy:defaultPolicy()),
    Policy = maps:merge(BasePolicy, alPolicy:policyForMode(Mode)),
    CallOpts = #{
        enforcePolicy => maps:get(enforcePolicy, Opts, true),
        mode => Mode,
        confirmed => maps:get(confirmed, Opts, false),
        policy => Policy
    },
    alToolRouter:callTool(Tool, maps:without([mode, confirmed, policy], Args), CallOpts);
invoke(ToolBin, Args, Opts) when is_binary(ToolBin) ->
    case resolveToolName(ToolBin) of
        {ok, Atom} -> invoke(Atom, Args, Opts);
        error -> {error, {unknownTool, ToolBin}}
    end.

mcpDefaultMode() ->
    case alConfig:get(mcp, #{}) of
        #{defaultMode := Mode} when Mode =:= ask; Mode =:= edit; Mode =:= exec -> Mode;
        #{<<"defaultMode">> := <<"edit">>} -> edit;
        #{<<"defaultMode">> := <<"exec">>} -> exec;
        _ -> ask
    end.

%% Protocol boundaries accept both canonical camelCase and conventional
%% snake_case without creating atoms from untrusted input.
resolveToolName(Name) when is_binary(Name) ->
    Normalized = normalizeToolName(Name),
    case [Tool || Tool <- maps:keys(builtinIndex()),
                  normalizeToolName(atom_to_binary(Tool, utf8)) =:= Normalized] of
        [Tool | _] -> {ok, Tool};
        [] -> error
    end.

normalizeToolName(Name) ->
    Lower = string:lowercase(Name),
    binary:replace(Lower, <<"_">>, <<>>, [global]).

%%--------------------------------------------------------------------
%% @doc
%% 在受监控的 worker 中调用工具，带硬超时。
%%
%% `Caller' 与 `Ref' 一路透传，使调用方能将进度事件
%% (`{eToolProgress, Ref, Event}') 与最终结果
%% (`{eToolResult, Ref, Result}') 关联起来。
%%
%% 成功时返回 worker 的 `{ok, _}' / `{error, _}' 结果；
%% 失败时返回 `{error, toolTimeout}' 或 `{error, {crash, Reason}}'。
%%
%% @param Tool 工具名 atom
%% @param Args 参数 map
%% @param Opts 选项 map
%% @param Caller 调用方 pid
%% @param Ref 调用方用于关联事件的引用
%% @param Timeout 超时毫秒
%% @return `{ok, Value}' | `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
-spec callWithTimeout(atom(), map(), map(), pid(), reference(), non_neg_integer()) ->
    {ok, term()} | {error, term()}.
callWithTimeout(Tool, Args, Opts, _Caller, Ref, Timeout) when is_atom(Tool), is_map(Args) ->
    Parent = self(),
    CallOpts = case is_map(Opts) of true -> Opts; false -> #{} end,
    {Pid, MonRef} = spawn_monitor(fun() ->
        Result = try invoke(Tool, Args, CallOpts) of
            R -> R
        catch
            Class:Reason:Stack ->
                {error, #{class => Class, reason => Reason,
                          stack => lists:sublist(Stack, 5)}}
        end,
        Parent ! {eToolResult, Ref, Result}
    end),
    receive
        {eToolResult, Ref, Result} ->
            erlang:demonitor(MonRef, [flush]),
            Result;
        {'DOWN', MonRef, process, Pid, Reason} ->
            {error, {crash, Reason}}
    after Timeout ->
        erlang:demonitor(MonRef, [flush]),
        exit(Pid, kill),
        flushResult(Ref),
        {error, toolTimeout}
    end;
callWithTimeout(ToolBin, Args, Opts, Caller, Ref, Timeout) when is_binary(ToolBin) ->
    case resolveToolName(ToolBin) of
        error ->
            flushResult(Ref),
            {error, {unknownTool, ToolBin}};
        {ok, Atom} ->
            callWithTimeout(Atom, Args, Opts, Caller, Ref, Timeout)
    end.

%% 清空信箱中可能残留的对应 Ref 的 eToolResult 消息（避免污染下次调用）。
flushResult(Ref) ->
    receive
        {eToolResult, Ref, _} -> ok
    after 0 ->
        ok
    end.

%%%===================================================================
%%% MCP tools
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% 返回 MCP 协议格式的工具列表（含 name/description/inputSchema）。
%%
%% @return MCP tools 列表
%% @end
%%--------------------------------------------------------------------
-spec mcpTools() -> [map()].
mcpTools() ->
    [#{
        name => atom_to_binary(Name, utf8),
        description => maps:get(description, toolSpec(Name)),
        inputSchema => maps:get(inputSchema, toolSpec(Name))
    } || Name <- allTools()].

%%-------------------------------------------------------------------
%% MCP resources (静态资源列表 + read)
%%-------------------------------------------------------------------

-define(McpResources, [
    #{uri => <<"ali://config">>,
      name => <<"ali config">>,
      description => <<"当前 ali 配置（脱敏）"/utf8>>,
      mimeType => <<"application/json">>},
    #{uri => <<"ali://schema/sql">>,
      name => <<"sql schema">>,
      description => <<"priv/db/schema.sql 内容"/utf8>>,
      mimeType => <<"text/plain">>},
    #{uri => <<"ali://tools">>,
      name => <<"tool catalog">>,
      description => <<"已注册的全部工具列表"/utf8>>,
      mimeType => <<"application/json">>}
]).

%%--------------------------------------------------------------------
%% @doc
%% 返回 MCP 协议的静态资源列表（config / schema / tools 等）。
%%
%% @return MCP resources 列表
%% @end
%%--------------------------------------------------------------------
mcpResources() ->
    ?McpResources.

%%--------------------------------------------------------------------
%% @doc
%% 读取指定 URI 的 MCP 资源内容，支持 config / schema/sql / tools 三种。
%%
%% @param Uri 资源 URI（binary）
%% @return `{ok, #{uri, mimeType, text}}' 或 `{error, Reason}'
%% @end
%%--------------------------------------------------------------------
mcpResourceRead(<<"ali://config">>) ->
    Config = alConfig:root(),
    SafeConfig = redactConfig(Config),
    {ok, #{uri => <<"ali://config">>, mimeType => <<"application/json">>,
           text => alJson:encode(SafeConfig)}};
mcpResourceRead(<<"ali://schema/sql">>) ->
    Path = schemaSqlPath(),
    case file:read_file(Path) of
        {ok, Bin} ->
            {ok, #{uri => <<"ali://schema/sql">>, mimeType => <<"text/plain">>,
                   text => Bin}};
        {error, Reason} ->
            {error, Reason}
    end;
mcpResourceRead(<<"ali://tools">>) ->
    Tools = [#{name => atom_to_binary(N, utf8),
               description => maps:get(description, toolSpec(N)),
               inputSchema => maps:get(inputSchema, toolSpec(N))} || N <- allTools()],
    Body = #{tools => Tools, count => length(Tools)},
    Text = try erlang:iolist_to_binary(alJson:encode(encodeJsonable(Body)))
           catch _:_ -> erlang:iolist_to_binary(io_lib:format("~p", [Body]))
           end,
    {ok, #{uri => <<"ali://tools">>, mimeType => <<"application/json">>, text => Text}};
mcpResourceRead(_Unknown) ->
    {error, unknownResource}.

%% 递归地对 config 列表中的敏感字段进行脱敏处理。
redactConfig(Config) when is_list(Config) ->
    [{K, redactValue(K, V)} || {K, V} <- Config];
redactConfig(Other) ->
    Other.

%% 对 llm 配置中的 apiKey 字段做掩码脱敏（其他字段保留原值）。
redactValue(llm, V) when is_map(V) ->
    maps:update_with(apiKey, fun(_) -> <<"***">> end, V);
redactValue(_K, V) ->
    V.

%% 计算 schema.sql 文件路径（打包资产，始终在 priv 下）。
schemaSqlPath() ->
    alConfig:privFile("db/schema.sql").
%%-------------------------------------------------------------------
%% MCP prompts（预置模板 + get 渲染）
%%-------------------------------------------------------------------

-define(McpPrompts, [
    #{name => <<"explain_module">>,
      description => <<"解释指定模块的职责与关键函数"/utf8>>,
      arguments => [#{name => <<"module">>, description => <<"模块名"/utf8>>, required => true}]},
    #{name => <<"trace_callers">>,
      description => <<"追踪函数被谁调用（callers）"/utf8>>,
      arguments => [#{name => <<"module">>, description => <<"模块名"/utf8>>, required => true},
                    #{name => <<"function">>, description => <<"函数名"/utf8>>, required => true},
                    #{name => <<"arity">>, description => <<"元数，可选"/utf8>>, required => false}]},
    #{name => <<"find_bottleneck">>,
      description => <<"分析运行时瓶颈（CPU/内存/消息队列）"/utf8>>,
      arguments => [#{name => <<"symptom">>, description => <<"症状描述，如 CPU 飙高、内存上涨"/utf8>>, required => true}]},
    #{name => <<"review_patch">>,
      description => <<"评审一份 patch 的安全性"/utf8>>,
      arguments => [#{name => <<"patch_json">>, description => <<"patch JSON 字符串"/utf8>>, required => true}]},
    #{name => <<"draft_refactor">>,
      description => <<"起草重构方案"/utf8>>,
      arguments => [#{name => <<"target">>, description => <<"重构目标（模块/函数/特性）"/utf8>>, required => true}]}
]).

%%--------------------------------------------------------------------
%% @doc
%% 返回 MCP 协议的预置 prompt 模板列表。
%%
%% @return MCP prompts 列表
%% @end
%%--------------------------------------------------------------------
mcpPrompts() ->
    ?McpPrompts.

%%--------------------------------------------------------------------
%% @doc
%% 根据名称和参数渲染一个 MCP prompt，返回 system+user 消息列表。
%%
%% @param Name prompt 名称（binary）
%% @param Args 参数 map
%% @return `{ok, #{description, messages}}' 或 `{error, unknownPrompt}'
%% @end
%%--------------------------------------------------------------------
mcpPromptGet(Name, Args) when is_binary(Name) ->
    case [P || #{name := N} = P <- ?McpPrompts, N =:= Name] of
        [Spec] ->
            Messages = renderPrompt(Name, Args, Spec),
            {ok, #{description => maps:get(description, Spec), messages => Messages}};
        [] ->
            {error, unknownPrompt}
    end.

%%--------------------------------------------------------------------
%% @doc
%% 渲染指定名称的 MCP prompt 为消息列表（system + user）。
%% 支持的名称：explain_module / trace_callers / find_bottleneck /
%% review_patch / draft_refactor。未知名称返回空列表。
%%
%% @param Name prompt 名称
%% @param Args 参数 map
%% @param Spec prompt 规格 map（保留参数）
%% @return 消息 map 列表，可能为空
%% @end
%%--------------------------------------------------------------------
renderPrompt(<<"explain_module">>, Args, _Spec) ->
    Mod = maps:get(<<"module">>, Args, <<"未知模块"/utf8>>),
    [
        #{role => <<"system">>, content => #{type => <<"text">>,
            text => u(<<"你是 Erlang 代码分析助手。先调用 moduleSymbols 工具拿到模块符号表，再用 searchCode 找关键调用，最后给出该模块的职责总结。"/utf8>>)}},
        #{role => <<"user">>, content => #{type => <<"text">>,
            text => u([<<"请解释模块 "/utf8>>, Mod, <<" 的职责与关键函数。"/utf8>>])}}
    ];
%% 渲染 trace_callers prompt：追踪函数被谁调用。
renderPrompt(<<"trace_callers">>, Args, _Spec) ->
    Mod = maps:get(<<"module">>, Args, <<"未知"/utf8>>),
    Fun = maps:get(<<"function">>, Args, <<"未知"/utf8>>),
    ArityBin = case maps:get(<<"arity">>, Args, undefined) of
        undefined -> <<"（任意元数）"/utf8>>;
        A when is_integer(A) -> integer_to_binary(A);
        A when is_binary(A) -> A
    end,
    [
        #{role => <<"system">>, content => #{type => <<"text">>,
            text => u(<<"你是 Erlang 调用链分析助手。调用 getCallers 工具，回答该函数被谁调用、调用上下文是什么。"/utf8>>)}},
        #{role => <<"user">>, content => #{type => <<"text">>,
            text => u([Mod, <<":">>, Fun, <<"/">>, ArityBin, <<" 的调用者是谁？"/utf8>>])}}
    ];
%% 渲染 find_bottleneck prompt：分析运行时瓶颈。
renderPrompt(<<"find_bottleneck">>, Args, _Spec) ->
    Symptom = maps:get(<<"symptom">>, Args, <<"运行时异常"/utf8>>),
    [
        #{role => <<"system">>, content => #{type => <<"text">>,
            text => u(<<"你是 Erlang 运行时分析助手。依次调用 getRuntime / getProcesses / getEts / supervisorTree，定位瓶颈来源。"/utf8>>)}},
        #{role => <<"user">>, content => #{type => <<"text">>,
            text => u([<<"症状："/utf8>>, Symptom, <<"。请定位瓶颈。"/utf8>>])}}
    ];
%% 渲染 review_patch prompt：评审 patch 安全性。
renderPrompt(<<"review_patch">>, Args, _Spec) ->
    Patch = maps:get(<<"patch_json">>, Args, <<"{}">>),
    [
        #{role => <<"system">>, content => #{type => <<"text">>,
            text => u(<<"你是 Erlang patch 安全审查员。先 validatePatch，再 dryRunPatch，最后给出风险评分与是否建议 apply。"/utf8>>)}},
        #{role => <<"user">>, content => #{type => <<"text">>,
            text => u([<<"请审查此 patch："/utf8>>, Patch])}}
    ];
%% 渲染 draft_refactor prompt：起草重构方案。
renderPrompt(<<"draft_refactor">>, Args, _Spec) ->
    Target = maps:get(<<"target">>, Args, <<"未知目标"/utf8>>),
    [
        #{role => <<"system">>, content => #{type => <<"text">>,
            text => u(<<"你是 Erlang 重构顾问。结合 searchCode、getCallers、getCallees、moduleSymbols，给出分步骤的重构方案（含 patch 草案）。"/utf8>>)}},
        #{role => <<"user">>, content => #{type => <<"text">>,
            text => u([<<"请起草 "/utf8>>, Target, <<" 的重构方案。"/utf8>>])}}
    ];
%% 未知 prompt 名称时返回空消息列表。
renderPrompt(_Unknown, _Args, _Spec) ->
    [].

%% 将 iolist/term 转为 binary，已为 binary 时原样返回。
-spec u(term()) -> binary().
u(Bin) when is_binary(Bin) -> Bin;
u(IoList) -> erlang:iolist_to_binary(IoList).

%% 递归将 term 转为 JSON 可序列化结构：map/list/atom -> binary/string。
encodeJsonable(V) when is_map(V) ->
    maps:from_list([{encodeKey(K), encodeJsonable(Val)} || {K, Val} <- maps:to_list(V)]);
encodeJsonable(V) when is_list(V) ->
    [encodeJsonable(I) || I <- V];
encodeJsonable(V) when is_atom(V) ->
    atom_to_binary(V, utf8);
encodeJsonable(V) ->
    V.

%% 将 map key 转为 JSON 安全形式（atom -> binary）。
encodeKey(K) when is_atom(K) -> atom_to_binary(K, utf8);
encodeKey(K) -> K.

%%%===================================================================
%%% Schema helpers
%%%===================================================================

%% 返回无参数对象的 JSON Schema。
emptySchema() ->
    #{type => object, properties => #{}}.

%% 构造带 required 字段的对象 JSON Schema。
objectSchema(Props, Required) ->
    #{
        type => object,
        properties => Props,
        required => Required
    }.

%% 代码搜索工具的输入 schema：query/limit/module/function/mode + VCS 过滤。
searchCodeSchema() ->
    objectSchema(maps:merge(#{
        query => stringProp(<<"搜索 query"/utf8>>),
        limit => integerProp(<<"最大命中数"/utf8>>),
        module => stringProp(<<"按 module 过滤"/utf8>>),
        function => stringProp(<<"按 function 过滤"/utf8>>),
        mode => stringProp(<<"bm25|vector|regex|hybrid（默认 bm25）"/utf8>>),
        modifiedSince => stringProp(<<"VCS 时间，如 2 weeks ago"/utf8>>),
        author => stringProp(<<"Git 作者"/utf8>>),
        vcsStatus => stringProp(<<"modified|added|untracked|deleted|renamed"/utf8>>)
    }, sourceEnrichProps()), [<<"query">>]).

%% 函数定位（module/function/arity）的输入 schema。
faSchema() ->
    objectSchema(maps:merge(#{
        module => stringProp(<<"模块名"/utf8>>),
        function => stringProp(<<"函数名"/utf8>>),
        arity => integerProp(<<"元数"/utf8>>)
    }, sourceEnrichProps()), [<<"function">>, <<"arity">>]).

sourceEnrichProps() ->
    #{
        context => integerProp(<<"附源码上下文行数（默认 2）"/utf8>>),
        includeSource => #{
            type => boolean,
            description => <<"附源码（默认 false；边>12 强制跳过）"/utf8>>
        },
        includeMermaid => #{
            type => boolean,
            description => <<"附 Mermaid（默认 false）"/utf8>>
        },
        format => stringProp(<<"summary（默认）|edges"/utf8>>),
        limit => integerProp(<<"format=edges 上限（默认 80）"/utf8>>),
        offset => integerProp(<<"format=edges 偏移（默认 0）"/utf8>>)
    }.

%% patch 工具的输入 schema：支持 old/new、replace、hunks、unified。
patchSchema() ->
    objectSchema(#{
        op => #{type => string,
                enum => [<<"create">>, <<"delete">>, <<"rename">>],
                description => <<"可选操作类型；缺省为 replace 编辑。create 需 content；"
                                 "delete 删 file；rename 需 to。"/utf8>>},
        file => stringProp(<<"文件路径"/utf8>>),
        old => stringProp(<<"待替换文本（单段）"/utf8>>),
        new => stringProp(<<"替换文本"/utf8>>),
        content => stringProp(<<"op=create 时新文件的完整内容"/utf8>>),
        to => stringProp(<<"op=rename 时的目标路径"/utf8>>),
        replace => #{
            type => object,
            properties => #{
                old => stringProp(<<"待替换文本"/utf8>>),
                new => stringProp(<<"替换文本"/utf8>>)
            }
        },
        hunks => #{
            type => array,
            description => <<"单文件多处编辑 hunk（多处修改时优先）"/utf8>>,
            items => #{
                type => object,
                properties => #{
                    old => stringProp(<<"精确旧文本片段（建议唯一上下文）"/utf8>>),
                    new => stringProp(<<"该 hunk 的替换文本"/utf8>>),
                    startLine => integerProp(<<"可选：1-based 起始行提示"/utf8>>),
                    endLine => integerProp(<<"可选：1-based 结束行提示"/utf8>>)
                },
                required => [<<"old">>, <<"new">>]
            }
        },
        unified => stringProp(<<"该文件的 unified diff 正文（@@ hunks）"/utf8>>)
    }, [<<"file">>]).

%% 构造 string 类型属性 schema，附带描述。
stringProp(Desc) ->
    #{type => string, description => Desc}.

%% 构造 integer 类型属性 schema，附带描述。
integerProp(Desc) ->
    #{type => integer, description => Desc}.
