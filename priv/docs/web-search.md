# ali 网络搜索与网页阅读

ali 的联网能力由 4 个 LLM 工具组成，覆盖「搜索 → 读正文 → 续读 → 一站式问答」全链路：

| 工具 | 用途 | 实现模块 |
|------|------|----------|
| `webSearch` | 搜索 Web，返回带 `index` 的结果列表 | [alWebSearch.erl](../src/tools/alWebSearch.erl) |
| `fetchUrl` | 抓取单个 URL，自动提取正文纯文本 | [alToolsExt.erl](../src/tools/alToolsExt.erl) |
| `fetchUrlPage` | 分页续读长网页正文（cursor 断点） | [alToolsExt.erl](../src/tools/alToolsExt.erl) |
| `webQa` | 搜索→并发抓取→LLM 汇总，一站式问答 | [alWebSearch.erl](../src/tools/alWebSearch.erl) |

工具定义见 [alToolCatalog.erl](../src/tools/alToolCatalog.erl)，路由与结果预算见 [alToolRouter.erl](../src/tools/alToolRouter.erl)，引用纪律注入见 [alContext.erl](../src/agent/alContext.erl)。

## webSearch

```
webSearch(query, limit?, offset?, engine?, freshness?)
→ {ok, #{query, engine, count, results => [#{index, title, url, snippet}]}}
```

- `query` 必填；`limit` 1-10（默认 5）；`offset` 翻页；`engine` 见下表；`freshness` 时间范围。
- 每条结果带 1-based `index`，供 LLM 用 `[n]` 标注引用。

### 引擎与回退

| engine | 说明 | key | 翻页 | freshness |
|--------|------|-----|------|-----------|
| `duckduckgo` | Instant Answer API | 无 | 不支持（自动回退） | 不支持 |
| `duckduckgo_html` | DDG HTML 端点，通用网页结果 | 无 | `s` 参数 | `df` 参数 |
| `wikipedia` | Wikipedia 搜索 API | 无 | `sroffset` | 不支持 |
| `bing` | Bing Web Search API | `webSearch.bingApiKey` | `offset` | `freshness` |
| `auto`（默认） | Instant Answer → DDG HTML → Wikipedia 逐级回退 | — | — | — |

回退规则：结果为空或请求出错均回退到下一引擎；全失败返回最后一个错误。

`freshness` 取值 `day / week / month / year`，仅 `duckduckgo_html` 与 `bing` 生效，其余引擎忽略。

## fetchUrl / fetchUrlPage

```
fetchUrl(url, maxBytes?, timeout?)
→ {ok, #{url, status, headers, body, bytes, truncated, format,
        extracted, title, charset}}
```

- 仅允许 http/https；默认拒绝内网地址（SSRF 防护，`fetchUrl.allowInternal` 可放开）。
- 请求带类 Chrome 的 UA/Accept 头（anti-bot 基础处理）；同域名限速 `fetchUrl.perHostMinIntervalMs`。
- HTML 自动做 readability 正文提取：`extracted => true` 时 `body` 为纯文本并附 `title`；提取失败回退原始 HTML。
- 正文默认最多 50KB。

```
fetchUrlPage(url, cursor?, chunkBytes?, timeout?)
→ {ok, #{url, offset, content, bytes, totalBytes, hasMore, nextCursor, cached}}
```

- 长网页分页续读：首次不传 `cursor`，之后传上次返回的 `nextCursor`（已读字节偏移）。
- 正文提取结果缓存 10 分钟，续读不重复抓取；`chunkBytes` 默认 24000。

## webQa

```
webQa(question, searchLimit?, fetchLimit?, freshness?)
→ {ok, #{question, answer, sources => [#{index, title, url, pageText?}]}}
```

流程：搜索 → 并发抓取前 `fetchLimit`（默认 3）条正文（每页截取 3KB）→ LLM 汇总出带 `[n]` 引用的 `answer`。

- 全部正文抓取失败时降级：返回空 `answer` + 搜索摘要 `sources`，由 agent 决定重试或换引擎。
- 汇总失败返回 `{error, summarizeFailed, sources}`，保留已抓来源供追溯。

## 引用标注机制

- `webSearch` / `webQa` 结果均带 1-based `index`。
- 系统提示词（alContext）注入联网检索纪律：回答句末用 `[n]` 标注引用，文末列 `Sources: [n] 标题 — URL`；搜索为空/抓取失败须如实说明，禁止编造来源。

## 配置（config/aliCfg.cfg）

```erlang
{webSearch, #{
    enabled => true,
    engine => auto,              %% auto|duckduckgo|duckduckgo_html|wikipedia|bing
    maxResults => 5,
    timeoutMs => 10000,
    language => <<"zh">>,        %% Wikipedia 语言
    bingApiKey => undefined,     %% engine=bing 时必填
    minIntervalMs => 1100,       %% 同引擎最小请求间隔（防 DDG 封禁，0=不限）
    cacheTtlMs => 300000         %% 相同查询缓存 TTL（0=关闭）
}},
{fetchUrl, #{
    allowInternal => false,          %% true=允许内网地址（SSRF 防护）
    perHostMinIntervalMs => 1000,    %% 同域名最小请求间隔
    userAgent => undefined,          %% 自定义 UA（默认类 Chrome）
    rememberWebPages => true         %% 正文入长期记忆 kind=webPage
}},
```

## 可靠性与安全

- **SSRF**：搜索端点全部为固定 https 域名；`fetchUrl` 校验 scheme + 解析后 IP，默认拒绝内网/环回/链路本地地址，含十进制/十六进制 IP 混淆绕过检测，重定向目标同样校验。
- **限流**：同引擎两次请求最小间隔（`minIntervalMs`）；同域名抓取最小间隔（`perHostMinIntervalMs`）。
- **缓存**：搜索结果按 `{engine,query,limit,offset,freshness}` 缓存（LRU 64 条）；网页正文提取结果缓存 10 分钟。
- **记忆**：`fetchUrl.rememberWebPages => true` 时抓取正文存入 alMemory（`kind=webPage`，project 范围），供后续会话召回。

## 测试

```powershell
rebar3 eunit -m alWebSearch_tests   # 解析器/参数校验/正文提取/freshness/引用索引/webQa 消息
rebar3 eunit -m alToolsExt_tests    # fetchUrlPage cursor、SSRF 校验、正文提取
```

注：`get_symbol_source_context_lines_test` 需写用户缓存目录（`AppData\Local\ali\Cache`），在受限沙箱下会因 eacces 失败，属环境限制。
