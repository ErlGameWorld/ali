-ifndef(AL_ATTACHMENT_HRL).
-define(AL_ATTACHMENT_HRL, true).

%% Web 图片 MIME（OpenAI / Anthropic / Gemini Vision 常见格式）
-define(AL_IMAGE_MIME_TYPES, [
    <<"image/jpeg"/utf8>>,
    <<"image/png"/utf8>>,
    <<"image/gif"/utf8>>,
    <<"image/webp"/utf8>>
]).

%% Web 文档 MIME（二进制，走 LLM document/file API；当前仅 PDF）
%% OpenAI file、Anthropic document、Gemini inline PDF
-define(AL_DOCUMENT_MIME_TYPES, [
    <<"application/pdf"/utf8>>
]).

-define(AL_DOCUMENT_FILE_EXTENSIONS, [
    ".pdf"
]).

%% Web 文本附件扩展名（注入为 text part；小写，含点）
-define(AL_TEXT_FILE_EXTENSIONS, [
    ".erl", ".hrl", ".md", ".txt", ".json", ".yaml", ".yml", ".cfg", ".conf",
    ".js", ".ts", ".jsx", ".tsx", ".html", ".css", ".xml", ".csv", ".toml",
    ".ini", ".ex", ".exs", ".py", ".go", ".rs", ".java", ".c", ".cpp", ".h",
    ".hpp", ".hh", ".cc", ".cxx", ".sql", ".sh", ".bat", ".ps1", ".src", ".app",
    ".config", ".log", ".rst", ".tex", ".vue", ".svelte", ".kt", ".swift", ".rb",
    ".php", ".lua", ".zig", ".scala", ".clj", ".proto", ".graphql", ".gradle",
    ".properties", ".dockerfile", ".gitignore", ".editorconfig", ".env"
]).

-endif.
