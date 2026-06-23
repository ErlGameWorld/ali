-ifndef(AL_LIMITS_HRL).
-define(AL_LIMITS_HRL, true).

%%===================================================================
%% Web 多模态附件（config: limits.webMax*，校验模块 alAttachments）
%% 用于 POST/WS 问答时用户上传的图片、文本文件与 PDF 文档，非 readFile 工具读盘。
%% 图片默认 20 MiB/张；文本 5 MiB/个；PDF 10 MiB/个（对齐 OpenAI / Anthropic / Gemini）。
%%===================================================================

%% 单次问答请求允许附带的图片张数上限
-define(DEFAULT_WEB_MAX_IMAGES, 16).
%% 单次问答请求允许附带的文本文件个数上限
-define(DEFAULT_WEB_MAX_FILES, 10).
%% 单张图片解码后体积上限（字节）
-define(DEFAULT_WEB_MAX_IMAGE_BYTES, 20971520).
%% 单个文本附件解码后体积上限（字节）
-define(DEFAULT_WEB_MAX_FILE_BYTES, 5242880).
%% 单次问答请求允许附带的文档个数上限（如 PDF）
-define(DEFAULT_WEB_MAX_DOCUMENTS, 4).
%% 单个文档（PDF 等）解码后体积上限（字节，默认 10 MiB）
-define(DEFAULT_WEB_MAX_DOCUMENT_BYTES, 10485760).

%%===================================================================
%% readFile / listFiles / 代码分析读盘（config: limits.tool* / analyze*）
%%===================================================================

%% readFile 工具未传 maxBytes 时的默认读取上限（字节，超出则截断）
-define(DEFAULT_TOOL_READ_FILE_MAX_BYTES, 262144).
%% listFiles 工具未传 maxResults 时的默认返回条数上限
-define(DEFAULT_TOOL_LIST_FILES_MAX_RESULTS, 50).
%% getFunctionSource 等分析工具读源文件时的体积上限（字节）
-define(DEFAULT_ANALYZE_READ_MAX_BYTES, 262144).
%% getFunctionSource 返回的最大行数
-define(DEFAULT_ANALYZE_MAX_SOURCE_LINES, 200).
%% getBeamAbstract 等格式化输出的最大字符数（字节）
-define(DEFAULT_ANALYZE_MAX_ABSTRACT, 12000).

%%===================================================================
%% 工具 stdout/结果截断（config: limits.toolMaxOutput 等）
%% git/svn/eunit/ct 等 shell 输出、callFunction 返回值预览
%%===================================================================

-define(DEFAULT_TOOL_MAX_OUTPUT, 12000).
-define(DEFAULT_TOOL_EVAL_MAX_OUTPUT, 8192).
-define(DEFAULT_TOOL_RUNTIME_MAX_OUTPUT, 8192).

%%===================================================================
%% Agent 推理循环（config: limits.maxToolContent）
%% 单次工具结果写入 LLM 上下文前的 JSON 体积上限（字节）
%%===================================================================

-define(DEFAULT_MAX_TOOL_CONTENT, 8000).

%%===================================================================
%% OTP 监督树工具 getSupTree（config: limits.otpMax*）
%%===================================================================

-define(DEFAULT_OTP_MAX_DEPTH, 6).
-define(DEFAULT_OTP_MAX_CHILDREN, 50).

%%===================================================================
%% 内存表容量（config: limits.auditMaxEntries / progressMaxEvents / backupMaxPerFile）
%%===================================================================

-define(DEFAULT_AUDIT_MAX_ENTRIES, 500).
-define(DEFAULT_PROGRESS_MAX_EVENTS, 500).
-define(DEFAULT_BACKUP_MAX_PER_FILE, 50).

%%===================================================================
%% 外部命令 git/svn（config: limits.shellCmd*）
%%===================================================================

-define(DEFAULT_SHELL_CMD_MAX_OUTPUT, 12000).
-define(DEFAULT_SHELL_CMD_TIMEOUT, 30000).

%%===================================================================
%% 工具执行超时（config: limits.toolTimeout）
%% callFunction 与自定义工具默认超时（毫秒）
%%===================================================================

-define(DEFAULT_TOOL_TIMEOUT, 60000).

%%===================================================================
%% 路径安全（config: limits.symlinkMaxDepth）
%% listFiles/readFile 解析符号链接时的最大递归深度
%%===================================================================

-define(DEFAULT_SYMLINK_MAX_DEPTH, 20).

-endif.
