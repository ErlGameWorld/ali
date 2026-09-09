-ifndef(__ali_attachment_hrl_).
-define(__ali_attachment_hrl_, true).

%% Web 图片 MIME（OpenAI / Anthropic / Gemini Vision 常见格式）
-define(ImageMimeTypes, [
    <<"image/jpeg">>,
    <<"image/png">>,
    <<"image/gif">>,
    <<"image/webp">>
]).

%% Web 文档 MIME：
%% - PDF：原样走 LLM file/document API
%% - Office：服务端抽文本后注入为 text part（多数模型不直接解析 xlsx/docx）
-define(DocMimeTypes, [
    <<"application/pdf">>,
    <<"application/msword">>,
    <<"application/vnd.ms-excel">>,
    <<"application/vnd.ms-powerpoint">>,
    <<"application/vnd.openxmlformats-officedocument.wordprocessingml.document">>,
    <<"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet">>,
    <<"application/vnd.openxmlformats-officedocument.presentationml.presentation">>,
    <<"application/vnd.ms-excel.sheet.macroEnabled.12">>,
    <<"application/vnd.ms-word.document.macroEnabled.12">>,
    <<"application/epub+zip">>
]).

-define(DocFileExtensions, [
    ".pdf",
    ".doc", ".docx", ".dot", ".dotx",
    ".xls", ".xlsx", ".xlsm", ".xltx",
    ".ppt", ".pptx",
    ".epub"
]).

%% Web 文本附件扩展名（注入为 text part；小写，含点）
-define(TextFileExtensions, [
    ".erl", ".hrl", ".md", ".txt", ".json", ".yaml", ".yml", ".cfg", ".conf",
    ".js", ".ts", ".jsx", ".tsx", ".html", ".css", ".xml", ".csv", ".toml",
    ".ini", ".ex", ".exs", ".py", ".go", ".rs", ".java", ".c", ".cpp", ".h",
    ".hpp", ".hh", ".cc", ".cxx", ".sql", ".sh", ".bat", ".ps1", ".src", ".app",
    ".config", ".log", ".rst", ".tex", ".vue", ".svelte", ".kt", ".swift", ".rb",
    ".php", ".lua", ".zig", ".scala", ".clj", ".proto", ".graphql", ".gradle",
    ".properties", ".dockerfile", ".gitignore", ".editorconfig", ".env",
    ".patch", ".diff", ".ipynb", ".svg"
]).

-endif.
