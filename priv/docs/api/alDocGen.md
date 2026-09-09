# alDocGen

从 BEAM abstract forms + edoc 注释生成模块 API 文档。
合并来源：
<ul>
<li>abstract_code 中的 `-moduledoc` / `-doc` / `-spec`（OTP 27+）</li>
<li>对应 `.erl` 源中的 `%% @doc` edoc 块</li>
<li>可选的 Mermaid 依赖图（{@link alCoreClient:moduleDeps/1}）</li>
</ul>
输出为适合聊天中 Mermaid 渲染的 Markdown。
%-------------------------------------------------------------------

## Functions

### `arityOk/3`

### `attachDeps/2`

### `beamToErl/1`

### `briefDocsFromEdges/1`

### `briefFromCommentLines/1`


_…truncated: showing first functions only._
