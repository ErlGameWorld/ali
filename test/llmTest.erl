%%%-------------------------------------------------------------------
%%% @doc LLM 客户端示例与演示代码。
%%%
%%% 本模块仅供学习与手动验证，非生产路径。各函数演示 llmCli 的
%%% 典型用法（基础对话、流式、重试、批量等），需配置有效 API Key 后运行。
%%%
%%% 一键运行全部示例：{@link runAllExamples/0}。
%%% @end
%%%-------------------------------------------------------------------
-module(llmTest).
-export([
    basicChat/0,
    chatWithOptions/0,
    chatWithContext/0,
    streamingChat/0,
    customProvider/0,
    anthropicChat/0,
    retryMechanism/0,
    batchProcessing/0,
    asyncProcessing/0,
    configFromEnv/0,
    errorHandling/0,
    runAllExamples/0
]).

%% @doc 基础单轮对话示例。
basicChat() ->
    io:format("=== 基础对话示例 ===~n"),
    llmCli:setConfig(api_key, "your-api-key-here"),
    llmCli:setConfig(provider, openai),
    
    Messages = [
        llmCli:userMessage("Hello, how are you?")
    ],
    
    case llmCli:chat(<<"gpt-3.5-turbo"/utf8>>, Messages) of
        {ok, Response} ->
            io:format("Response: ~s~n", [Response]);
        {error, Reason} ->
            io:format("Error: ~p~n", [Reason])
    end.

%% @doc 带 temperature、max_tokens 等参数的对话示例。
chatWithOptions() ->
    io:format("=== 带参数的对话示例 ===~n"),
    llmCli:setConfig(api_key, "your-api-key-here"),
    llmCli:setConfig(provider, openai),
    
    Messages = [
        llmCli:userMessage("Write a short poem about programming")
    ],
    
    Options = [
        {temperature, 0.8},
        {max_tokens, 100},
        {top_p, 0.9}
    ],
    
    case llmCli:chat(<<"gpt-3.5-turbo"/utf8>>, Messages, Options) of
        {ok, Response} ->
            io:format("Poem: ~s~n", [Response]);
        {error, Reason} ->
            io:format("Error: ~p~n", [Reason])
    end.

%% @doc 多轮上下文对话示例（system + 历史消息）。
chatWithContext() ->
    io:format("=== 带上下文的对话示例 ===~n"),
    llmCli:setConfig(api_key, "your-api-key-here"),
    llmCli:setConfig(provider, openai),
    
    Messages = [
        llmCli:systemMessage("You are a helpful programming assistant."),
        llmCli:userMessage("What is Erlang?"),
        llmCli:assistantMessage("Erlang is a functional programming language designed for building scalable, fault-tolerant systems."),
        llmCli:userMessage("What are its main features?")
    ],
    
    case llmCli:chat(<<"gpt-3.5-turbo"/utf8>>, Messages) of
        {ok, Response} ->
            io:format("Response: ~s~n", [Response]);
        {error, Reason} ->
            io:format("Error: ~p~n", [Reason])
    end.

%% @doc 流式响应示例；通过 receive 循环接收分块。
streamingChat() ->
    io:format("=== 流式响应示例 ===~n"),
    llmCli:setConfig(api_key, "your-api-key-here"),
    llmCli:setConfig(provider, openai),
    
    Messages = [
        llmCli:userMessage("Tell me a short story about a robot")
    ],
    
    io:format("Streaming response:~n"),

    llmCli:chatStream(<<"gpt-3.5-turbo"/utf8>>, Messages),
    streamingLoop().

%% 流式接收循环：打印每个 chunk 直至 done。
streamingLoop() ->
    receive
        {stream_chunk, Chunk} when Chunk =/= done ->
            io:format("~s", [Chunk]),
            streamingLoop();
        {stream_chunk, done} ->
            io:format("~n=== 流式响应完成 ===~n"),
            ok
    end.

%% @doc 自定义 API 端点（provider=custom）示例。
customProvider() ->
    io:format("=== 自定义提供商示例 ===~n"),
    llmCli:setConfig(api_key, "your-custom-api-key"),
    llmCli:setConfig(provider, custom),
    llmCli:setConfig(base_url, "https://your-custom-api.com/v1"),
    
    Messages = [
        llmCli:userMessage("Hello from custom provider!")
    ],
    
    case llmCli:chat(<<"your-model-name"/utf8>>, Messages) of
        {ok, Response} ->
            io:format("Response: ~s~n", [Response]);
        {error, Reason} ->
            io:format("Error: ~p~n", [Reason])
    end.

%% @doc Anthropic Claude 提供商示例。
anthropicChat() ->
    io:format("=== Anthropic Claude 示例 ===~n"),
    llmCli:setConfig(api_key, "your-anthropic-api-key"),
    llmCli:setConfig(provider, anthropic),
    
    Messages = [
        llmCli:userMessage("What is the meaning of life?")
    ],
    
    case llmCli:chat(<<"claude-3-opus-20240229"/utf8>>, Messages) of
        {ok, Response} ->
            io:format("Response: ~s~n", [Response]);
        {error, Reason} ->
            io:format("Error: ~p~n", [Reason])
    end.

%% @doc 遇 429/5xx 时指数退避重试示例。
retryMechanism() ->
    io:format("=== 重试机制示例 ===~n"),
    llmCli:setConfig(api_key, "your-api-key-here"),
    llmCli:setConfig(provider, openai),
    
    Messages = [
        llmCli:userMessage("Hello!")
    ],
    
    case llmCli:chatWithRetry(<<"gpt-3.5-turbo"/utf8>>, Messages, 3) of
        {ok, Response} ->
            io:format("Success after retry: ~s~n", [Response]);
        {error, Reason} ->
            io:format("Failed after retries: ~p~n", [Reason])
    end.

%% @doc 对多组消息批量发起聊天请求示例。
batchProcessing() ->
    io:format("=== 批量处理示例 ===~n"),
    llmCli:setConfig(api_key, "your-api-key-here"),
    llmCli:setConfig(provider, openai),
    
    MessageList = [
        [llmCli:userMessage("What is 2+2?")],
        [llmCli:userMessage("What is the capital of France?")],
        [llmCli:userMessage("Tell me a joke.")]
    ],
    
    Results = llmCli:batchChat(<<"gpt-3.5-turbo"/utf8>>, MessageList),
    
    lists:foreach(fun({Index, Result}) ->
        io:format("Query ~p: ~p~n", [Index, Result])
    end, lists:zip(lists:seq(1, length(Results)), Results)).

%% @doc 异步并发聊天示例；通过 `{chat_result, _}' 接收结果。
asyncProcessing() ->
    io:format("=== 异步处理示例 ===~n"),
    llmCli:setConfig(api_key, "your-api-key-here"),
    llmCli:setConfig(provider, openai),
    
    Messages1 = [llmCli:userMessage("What is Erlang?")],
    Messages2 = [llmCli:userMessage("What is Elixir?")],
    
    Parent = self(),
    
    llmCli:asyncChat(<<"gpt-3.5-turbo"/utf8>>, Messages1, Parent),
    llmCli:asyncChat(<<"gpt-3.5-turbo"/utf8>>, Messages2, Parent),
    
    receive
        {chat_result, Result1} ->
            io:format("Result 1: ~p~n", [Result1])
    end,
    
    receive
        {chat_result, Result2} ->
            io:format("Result 2: ~p~n", [Result2])
    end,
    
    io:format("=== 异步处理完成 ===~n").

%% @doc 从环境变量 LLM_* 加载配置并发起请求示例。
configFromEnv() ->
    io:format("=== 从环境变量加载配置示例 ===~n"),
    
    llmCli:loadConfig(),
    
    Messages = [
        llmCli:userMessage("Hello from environment config!")
    ],
    
    case llmCli:chat(<<"gpt-3.5-turbo"/utf8>>, Messages) of
        {ok, Response} ->
            io:format("Response: ~s~n", [Response]);
        {error, Reason} ->
            io:format("Error: ~p~n", [Reason])
    end.

%% @doc 各类 HTTP 与 API 错误的分类处理示例。
errorHandling() ->
    io:format("=== 错误处理示例 ===~n"),
    llmCli:setConfig(api_key, "invalid-key"),
    llmCli:setConfig(provider, openai),
    
    Messages = [
        llmCli:userMessage("Hello!")
    ],
    
    case llmCli:chat(<<"gpt-3.5-turbo"/utf8>>, Messages) of
        {ok, Response} ->
            io:format("Success: ~s~n", [Response]);
        {error, {http_error, 401, _}} ->
            io:format("Authentication failed. Check your API key.~n");
        {error, {http_error, 429, _}} ->
            io:format("Rate limit exceeded. Please try again later.~n");
        {error, {http_error, StatusCode, ErrorBody}} ->
            io:format("HTTP error ~p: ~p~n", [StatusCode, ErrorBody]);
        {error, invalid_response} ->
            io:format("Invalid response format.~n");
        {error, Reason} ->
            io:format("Error: ~p~n", [Reason])
    end.

%% @doc 依次运行本模块全部示例函数。
runAllExamples() ->
    io:format("~n=== 运行所有示例 ===~n~n"),
    
    basicChat(),
    io:format("~n"),
    
    chatWithOptions(),
    io:format("~n"),
    
    chatWithContext(),
    io:format("~n"),
    
    streamingChat(),
    io:format("~n"),
    
    anthropicChat(),
    io:format("~n"),
    
    retryMechanism(),
    io:format("~n"),
    
    batchProcessing(),
    io:format("~n"),
    
    asyncProcessing(),
    io:format("~n"),
    
    configFromEnv(),
    io:format("~n"),
    
    errorHandling(),
    io:format("~n"),
    
    io:format("=== 所有示例运行完成 ===~n").