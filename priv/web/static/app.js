const chat = document.getElementById('chat');
const promptEl = document.getElementById('prompt');
const statusText = document.getElementById('statusText');
const modeSelect = document.getElementById('modeSelect');
const sessionSelect = document.getElementById('sessionSelect');
const btnSend = document.getElementById('btnSend');
const btnStop = document.getElementById('btnStop');
const btnAttach = document.getElementById('btnAttach');
const btnSaveSession = document.getElementById('btnSaveSession');
const btnDeleteSession = document.getElementById('btnDeleteSession');
const btnToken = document.getElementById('btnToken');
const btnLlm = document.getElementById('btnLlm');
const llmModal = document.getElementById('llmModal');
const llmUseOwn = document.getElementById('llmUseOwn');
const llmProviderSelect = document.getElementById('llmProviderSelect');
const llmModelSelect = document.getElementById('llmModelSelect');
const llmApiKeyInput = document.getElementById('llmApiKeyInput');
const btnLlmSave = document.getElementById('btnLlmSave');
const btnLlmCancel = document.getElementById('btnLlmCancel');
const fileInput = document.getElementById('fileInput');
const attachPreview = document.getElementById('attachPreview');
const btnClear = document.getElementById('btnClear');
const btnTasks = document.getElementById('btnTasks');
const btnDistill = document.getElementById('btnDistill');
const btnCloseSide = document.getElementById('btnCloseSide');
const sidePanel = document.getElementById('sidePanel');
const tasksList = document.getElementById('tasksList');
const planList = document.getElementById('planList');
const metricsBox = document.getElementById('metricsBox');
const auditList = document.getElementById('auditList');
const toolsList = document.getElementById('toolsList');
const tokenBox = document.getElementById('tokenBox');
const approveBar = document.getElementById('approveBar');
const approveText = document.getElementById('approveText');
const btnApprove = document.getElementById('btnApprove');
const btnDismissApprove = document.getElementById('btnDismissApprove');
const connDot = document.getElementById('connDot');
const filesTree = document.getElementById('filesTree');
const filesRootLabel = document.getElementById('filesRootLabel');
const activeSessionsList = document.getElementById('activeSessionsList');
const savedSessionsList = document.getElementById('savedSessionsList');
const checkpointsList = document.getElementById('checkpointsList');
const btnFilesRefresh = document.getElementById('btnFilesRefresh');
const fileViewer = document.getElementById('fileViewer');
const fileViewerPanel = document.getElementById('fileViewerPanel');
const fileViewerDrag = document.getElementById('fileViewerDrag');
const fileViewerTitle = document.getElementById('fileViewerTitle');
const fileViewerMeta = document.getElementById('fileViewerMeta');
const fileViewerBody = document.getElementById('fileViewerBody');
const fileViewerZoom = document.getElementById('fileViewerZoom');
const btnFvZoomIn = document.getElementById('btnFvZoomIn');
const btnFvZoomOut = document.getElementById('btnFvZoomOut');
const btnFvCopy = document.getElementById('btnFvCopy');
const btnFvCopySel = document.getElementById('btnFvCopySel');
const btnFvInsert = document.getElementById('btnFvInsert');
const btnFvEdit = document.getElementById('btnFvEdit');
const btnFvEditCancel = document.getElementById('btnFvEditCancel');
const fileViewerEditor = document.getElementById('fileViewerEditor');
const btnFvFullscreen = document.getElementById('btnFvFullscreen');
const btnFvPopout = document.getElementById('btnFvPopout');
const btnFvClose = document.getElementById('btnFvClose');
const fileViewerSearch = document.getElementById('fileViewerSearch');
const fileViewerSearchCase = document.getElementById('fileViewerSearchCase');
const fileViewerSearchCount = document.getElementById('fileViewerSearchCount');
const btnFvFindPrev = document.getElementById('btnFvFindPrev');
const btnFvFindNext = document.getElementById('btnFvFindNext');

const thinkingViewer = document.getElementById('thinkingViewer');
const thinkingViewerPanel = document.getElementById('thinkingViewerPanel');
const thinkingViewerDrag = document.getElementById('thinkingViewerDrag');
const thinkingViewerTitle = document.getElementById('thinkingViewerTitle');
const thinkingViewerMeta = document.getElementById('thinkingViewerMeta');
const thinkingViewerBody = document.getElementById('thinkingViewerBody');
const thinkingViewerZoom = document.getElementById('thinkingViewerZoom');
const thinkingViewerSearch = document.getElementById('thinkingViewerSearch');
const thinkingViewerSearchCase = document.getElementById('thinkingViewerSearchCase');
const thinkingViewerSearchCount = document.getElementById('thinkingViewerSearchCount');
const btnTvZoomIn = document.getElementById('btnTvZoomIn');
const btnTvZoomOut = document.getElementById('btnTvZoomOut');
const btnTvCopy = document.getElementById('btnTvCopy');
const btnTvCopySel = document.getElementById('btnTvCopySel');
const btnTvFullscreen = document.getElementById('btnTvFullscreen');
const btnTvPopout = document.getElementById('btnTvPopout');
const btnTvClose = document.getElementById('btnTvClose');
const btnTvFindPrev = document.getElementById('btnTvFindPrev');
const btnTvFindNext = document.getElementById('btnTvFindNext');

let thinkingViewerText = '';
let thinkingViewerZoomPct = 100;
let thinkingViewerClone = null;
let thinkingViewerSourceEl = null;
let tvSearchHits = [];
let tvSearchIndex = -1;
let tvDragState = null;
let tvGeomBeforeFullscreen = null;
let pendingThinkingEl = null;

let selectedFilePath = null;
let fileViewerText = '';
let fileViewerEditing = false;
let fileViewerIsBinary = false;
let fileViewerTruncated = false;
let fileViewerZoomPct = 100;
const FILE_VIEW_MAX_BYTES = 5242880;
const FV_POS_KEY = 'ali.fileViewer.geom.v2';
const FV_SEARCH_MAX_HITS = 2000;
let fvDragState = null;
let fvGeomBeforeFullscreen = null;
let fvSearchHits = [];
let fvSearchIndex = -1;
const btnCheckpointsRefresh = document.getElementById('btnCheckpointsRefresh');

let pendingTaskId = null;
let pendingAttachments = [];
let activeAsk = null;
let activeAskAbort = null;

function setAsking(on) {
  btnSend.disabled = on;
  if (btnStop) btnStop.classList.toggle('hidden', !on);
}

function finishActiveAsk(error, value) {
  if (!activeAsk || activeAsk.finished) return;
  activeAsk.finished = true;
  const { resolve, reject, msgWrap } = activeAsk;
  clearTimeout(activeAsk.timeout);
  if (activeAsk.es) {
    try { activeAsk.es.close(); } catch { /* ignore */ }
  }
  WS.streamHandler = null;
  const streamed = String(activeAsk.full || '').trim();
  const finalForThinking = (error != null && error !== '')
    ? String(typeof error === 'string' ? error : (error.message || error))
    : (value != null && String(value).trim() ? String(value) : streamed);
  finishThinking(finalForThinking, !!(error != null && error !== ''));
  if (msgWrap) msgWrap.classList.remove('streaming', 'pending');
  // 流式结束后：结构化块渲染 + 拆出 grounding 提示（避免正文像被截断）
  if (msgWrap && !error) {
    const msgBody = msgWrap.querySelector('.msg-body');
    const finalText = (value != null && String(value).trim())
      ? String(value)
      : streamed;
    if (msgBody && finalText) applyAgentBody(msgBody, finalText);
  }
  if (!error && value != null && String(value).trim()) {
    appendLocalMessage('agent', String(value));
    persistActiveLocalChat();
  }
  activeAsk = null;
  activeAskAbort = null;
  if (error != null && error !== '') {
    reject(new Error(typeof error === 'string' ? error : String(error)));
  } else {
    resolve(value ?? '');
  }
}

function handleStreamProgress(ev) {
  if (ev.type === 'answer') {
    const text = ev.text || extractModelText(ev.result) || '';
    if (text && activeAsk?.msgWrap) {
      const body = activeAsk.msgWrap.querySelector('.msg-body');
      const textNode = body?.firstChild;
      // Replace, don't append — progress may fire after tokens/answer already shown.
      if (activeAsk.full && (text === activeAsk.full || activeAsk.full.includes(text))) return;
      if (textNode) textNode.nodeValue = text;
      else if (body) body.textContent = text;
      activeAsk.full = text;
    }
    return;
  }
  // thought：只更新下方输出气泡，不在工具框里再贴一份正文、不单独开推理框
  if (ev.type === 'thought') {
    appendThoughtCapture(ev);
    return;
  }
  if (ev.type === 'tool' || ev.type === 'toolStarted') {
    const line = formatEvent(ev);
    if (line && !line.startsWith('{')) addThinkingLine(line);
  }
  if ((ev.type === 'approvalRequired' || ev.type === 'tool_done' || ev.type === 'toolFinished')
      && (ev.status === 'confirmationRequired' || ev.status === 'confirmation_required')) {
    const line = formatEvent(ev);
    if (line && !line.startsWith('{')) addThinkingLine(line);
    const tid = ev.taskId != null ? String(ev.taskId) : (ev.task_id != null ? String(ev.task_id) : null);
    if (tid) {
      const preview = (typeof ev.preview === 'string' && ev.preview)
        || ev.preview?.message
        || `执行 ${ev.tool || 'tool'}${formatToolArgs(ev.args)}`;
      showApproveBar(tid, preview);
    }
    return;
  }
  if ((ev.type === 'toolFinished' || ev.type === 'tool_done') && ev.ok && ev.result) {
    // 工具成功时：记录概要行；搜索类结果额外渲染带 snippet 的列表
    const line = formatEvent(ev);
    if (line && !line.startsWith('{')) addThinkingLine(line);
    renderToolResult(ev);
    return;
  }
  if (ev.type === 'step' || ev.type === 'started') {
    setThinkingStatus(ev.message || formatEvent(ev));
    if (ev.phase === 'heal') {
      renderHealLocations(ev);
    }
    return;
  }
  if (ev.type === 'error') {
    const msg = formatErrorReason(ev.reason);
    addThinkingLine(`! 错误: ${msg}`);
    finishActiveAsk(msg);
    return;
  }
  const line = formatEvent(ev);
  if (line && !line.startsWith('{')) addThinkingLine(line);
}

//==================================================================
// 工具结果渲染（搜索 / 文件读取 / patch 等）
//==================================================================
//
// 搜索类工具（searchCode/searchSymbols/getCallers/getCallees）会返
// 回 ev.result = {ok, data: [{path, score, snippet, line?, lineNumber?}, ...]}
// 在 thinkingBox 中渲染为可点击的 path+snippet 列表，方便 LLM 反馈
// 给用户时即能直观看到命中行。
function renderToolResult(ev) {
  const result = ev.result;
  if (!result || typeof result !== 'object') return;
  if (!thinkingList || !thinkingList.parentNode) return;

  // 调用图 / 依赖图 / 文档：优先渲染 mermaid，并收入侧栏「图」
  if (typeof result.mermaid === 'string' && result.mermaid.trim()) {
    const entry = pushGraphArtifact({
      tool: ev.tool || 'graph',
      mermaid: result.mermaid,
      markdown: result.markdown,
      writePath: result.writePath || result.written?.path,
      title: graphTitleFromResult(ev.tool, result),
      meta: graphMetaFromResult(result),
    });
    const wrap = document.createElement('li');
    wrap.className = 'thinking-graph';
    const title = document.createElement('div');
    title.className = 'thinking-graph-title';
    title.textContent = entry.title + (entry.meta ? ` · ${entry.meta}` : '');
    wrap.appendChild(title);
    wrap.appendChild(renderMermaidBlock(result.mermaid));
    const openBtn = document.createElement('button');
    openBtn.type = 'button';
    openBtn.className = 'btn-muted btn-xs thinking-graph-open';
    openBtn.textContent = '在图窗口打开';
    openBtn.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();
      openGraphViewer(entry.id);
    });
    wrap.appendChild(openBtn);
    if (entry.writePath) {
      const fileBtn = document.createElement('button');
      fileBtn.type = 'button';
      fileBtn.className = 'btn-muted btn-xs thinking-graph-open';
      fileBtn.textContent = '打开文档文件';
      fileBtn.addEventListener('click', (e) => {
        e.preventDefault();
        e.stopPropagation();
        openFileViewer(String(entry.writePath));
      });
      wrap.appendChild(fileBtn);
    }
    thinkingList.appendChild(wrap);
  } else if (typeof result.markdown === 'string' && result.markdown.trim()) {
    pushGraphArtifact({
      tool: ev.tool || 'doc',
      mermaid: '',
      markdown: result.markdown,
      writePath: result.writePath || result.written?.path,
      title: graphTitleFromResult(ev.tool, result),
      meta: 'markdown',
    });
  }

  // 文档 markdown 预览（截断）
  if (typeof result.markdown === 'string' && result.markdown.trim()) {
    const wrap = document.createElement('li');
    wrap.className = 'thinking-doc-preview';
    const pre = document.createElement('pre');
    pre.className = 'thinking-hit-snippet';
    const md = result.markdown;
    pre.textContent = md.length > 1200 ? `${md.slice(0, 1200)}…` : md;
    wrap.appendChild(pre);
    thinkingList.appendChild(wrap);
  }

  const data = Array.isArray(result.data) ? result.data
             : (Array.isArray(result.hits) ? result.hits
             : (Array.isArray(result.results) ? result.results : null));
  if (!data || data.length === 0) return;
  const hasSnippets = data.some((d) => d && (d.snippet || d.snippetLines));
  if (!hasSnippets) return;
  const wrap = document.createElement('li');
  wrap.className = 'thinking-hit-list';
  const max = Math.min(8, data.length);
  for (let i = 0; i < max; i++) {
    const d = data[i] || {};
    const path = d.path || d.file || d.uri || '(unknown)';
    const lineNo = d.lineNumber ?? d.line ?? d.startLine ?? '';
    const score = typeof d.score === 'number' ? d.score.toFixed(3) : '';
    const snippet = d.snippet || d.snippetLines || '';
    const item = document.createElement('div');
    item.className = 'thinking-hit';
    const head = document.createElement('div');
    head.className = 'thinking-hit-head';
    head.innerHTML = `<span class="hit-path">${escapeHtml(path)}</span>${
      lineNo !== '' ? `<span class="hit-line">:${escapeHtml(String(lineNo))}</span>` : ''
    }${score ? `<span class="hit-score">${escapeHtml(score)}</span>` : ''}`;
    item.appendChild(head);
    if (snippet) {
      const pre = document.createElement('pre');
      pre.className = 'thinking-hit-snippet';
      pre.textContent = String(snippet);
      item.appendChild(pre);
    }
    wrap.appendChild(item);
  }
  if (data.length > max) {
    const more = document.createElement('div');
    more.className = 'thinking-hit-more';
    more.textContent = `… 还有 ${data.length - max} 条命中`;
    wrap.appendChild(more);
  }
  thinkingList.appendChild(wrap);
}

//==================================================================
// 侧栏「图」：收集 callGraph / docs Mermaid
//==================================================================
const graphArtifacts = [];
let activeGraphId = null;

function graphTitleFromResult(tool, result) {
  const t = tool || 'graph';
  if (result.module) return `${t}: ${result.module}`;
  if (Array.isArray(result.modules) && result.modules.length) {
    return `${t}: ${result.modules.slice(0, 3).join(',')}`;
  }
  return String(t);
}

function graphMetaFromResult(result) {
  if (result.edgeCount != null) {
    const shown = result.mermaidEdgeCount ?? result.edgeCount;
    const total = result.totalEdgeCount ?? result.edgeCount;
    return `${shown}/${total} edges`;
  }
  if (result.fileCount != null) return `${result.fileCount} files`;
  if (result.written?.path || result.writePath) return 'written';
  if (Array.isArray(result.warnings) && result.warnings.length) return 'degraded';
  return '';
}

function pushGraphArtifact(partial) {
  const entry = {
    id: `g-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`,
    ts: Date.now(),
    tool: partial.tool || 'graph',
    title: partial.title || 'graph',
    meta: partial.meta || '',
    mermaid: partial.mermaid || '',
    markdown: partial.markdown || '',
    writePath: partial.writePath || '',
    edges: Array.isArray(partial.edges) ? partial.edges : [],
    briefs: (partial.briefs && typeof partial.briefs === 'object') ? partial.briefs : {},
    byModule: partial.byModule != null ? partial.byModule : [],
    query: partial.query || null,
  };
  graphArtifacts.unshift(entry);
  if (graphArtifacts.length > 30) graphArtifacts.length = 30;
  renderGraphsList();
  persistActiveLocalChat();
  return entry;
}

function renderGraphsList() {
  const list = document.getElementById('graphsList');
  if (!list) return;
  list.innerHTML = '';
  if (!graphArtifacts.length) {
    const empty = document.createElement('li');
    empty.className = 'muted';
    empty.textContent = '暂无';
    list.appendChild(empty);
    return;
  }
  graphArtifacts.forEach((g) => {
    const li = document.createElement('li');
    li.className = 'graph-item' + (g.id === activeGraphId ? ' active' : '');
    li.innerHTML = `<button type="button" class="graph-item-btn"><strong>${escapeHtml(g.title)}</strong>`
      + (g.meta ? `<span class="muted"> ${escapeHtml(g.meta)}</span>` : '')
      + `</button>`;
    li.querySelector('button').addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();
      openGraphViewer(g.id);
    });
    list.appendChild(li);
  });
}

/** 只切换侧栏 tab 外观，不触发 tabLoaders（避免与 openGraphInSide 递归）。 */
function selectSideTab(name) {
  document.querySelectorAll('.side-tab').forEach((t) => t.classList.toggle('active', t.dataset.tab === name));
  document.getElementById('tabTasks')?.classList.toggle('hidden', name !== 'tasks');
  document.getElementById('tabPlan')?.classList.toggle('hidden', name !== 'plan');
  document.getElementById('tabFiles')?.classList.toggle('hidden', name !== 'files');
  document.getElementById('tabGraphs')?.classList.toggle('hidden', name !== 'graphs');
  document.getElementById('tabSessions')?.classList.toggle('hidden', name !== 'sessions');
  document.getElementById('tabCheckpoints')?.classList.toggle('hidden', name !== 'checkpoints');
  document.getElementById('tabMetrics')?.classList.toggle('hidden', name !== 'metrics');
  document.getElementById('tabAudit')?.classList.toggle('hidden', name !== 'audit');
  document.getElementById('tabTools')?.classList.toggle('hidden', name !== 'tools');
  document.getElementById('tabTokens')?.classList.toggle('hidden', name !== 'tokens');
  document.getElementById('tabMemory')?.classList.toggle('hidden', name !== 'memory');
  document.getElementById('tabKnowledge')?.classList.toggle('hidden', name !== 'knowledge');
  document.getElementById('tabCore')?.classList.toggle('hidden', name !== 'core');
}

function renderGraphView(g) {
  const view = document.getElementById('graphView');
  if (!view || !g) return;
  view.innerHTML = '';
  view.classList.remove('muted');
  const head = document.createElement('div');
  head.className = 'graph-view-head';
  head.textContent = g.title + (g.meta ? ` · ${g.meta}` : '');
  view.appendChild(head);
  const hasMermaid = g.mermaid && String(g.mermaid).trim();
  const hasMd = g.markdown && String(g.markdown).trim();
  if (hasMermaid) {
    const thumb = renderMermaidBlock(g.mermaid);
    thumb.style.maxHeight = '180px';
    thumb.style.overflow = 'hidden';
    view.appendChild(thumb);
  } else if (!hasMd) {
    const empty = document.createElement('div');
    empty.className = 'muted';
    empty.textContent = '该条目没有可渲染的 Mermaid / Markdown 内容';
    view.appendChild(empty);
  }
  if (hasMd) {
    const pre = document.createElement('pre');
    pre.className = 'thinking-hit-snippet';
    pre.textContent = g.markdown.length > 800 ? `${g.markdown.slice(0, 800)}…` : g.markdown;
    view.appendChild(pre);
  }
  const openBtn = document.createElement('button');
  openBtn.type = 'button';
  openBtn.className = 'btn-muted btn-xs graph-view-open-btn';
  openBtn.textContent = '在独立窗口打开（缩放 / 平移）';
  openBtn.addEventListener('click', () => openGraphViewer(g.id));
  view.appendChild(openBtn);
  if (g.writePath) {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'btn-muted btn-xs';
    btn.textContent = `打开 ${g.writePath}`;
    btn.addEventListener('click', () => openFileViewer(String(g.writePath)));
    view.appendChild(btn);
  }
}

function openGraphInSide(id) {
  const g = graphArtifacts.find((x) => x.id === id);
  if (!g) return;
  activeGraphId = id;
  if (sidePanel?.classList.contains('hidden')) sidePanel.classList.remove('hidden');
  selectSideTab('graphs');
  renderGraphsList();
  renderGraphView(g);
  renderGraphDetailSummary(g);
}

function setGraphDetailHint(text) {
  const el = document.getElementById('graphDetail');
  if (el) {
    el.classList.add('muted');
    el.textContent = text
      || '选中图中节点后，这里显示模块 / 函数 / 元数 / 调用行 / 注解';
  }
}

function bindGraphMfaForm() {
  const btn = document.getElementById('btnGraphMfaRun');
  if (!btn || btn.dataset.bound) return;
  btn.dataset.bound = '1';
  btn.addEventListener('click', () => runGraphMfaQuery());
  ['graphMfaModule', 'graphMfaFunction', 'graphMfaArity'].forEach((id) => {
    document.getElementById(id)?.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        runGraphMfaQuery();
      }
    });
  });
}

async function runGraphMfaQuery(opts = {}) {
  const module = (opts.module ?? document.getElementById('graphMfaModule')?.value ?? '').trim();
  const functionName = (opts.function ?? document.getElementById('graphMfaFunction')?.value ?? '').trim();
  const arityRaw = opts.arity ?? document.getElementById('graphMfaArity')?.value;
  const arity = Number(arityRaw);
  const dir = opts.dir ?? document.getElementById('graphMfaDir')?.value ?? 'both';
  const status = document.getElementById('graphMfaStatus');
  if (!functionName || !Number.isFinite(arity)) {
    if (status) status.textContent = '请填写函数名与元数';
    setStatus('请填写函数名与元数');
    return null;
  }
  if (status) status.textContent = '查询中…';
  try {
    const endpoint = dir === 'callees' ? 'callees' : 'callers';
    const data = await api(`/api/core/${endpoint}`, {
      method: 'POST',
      body: JSON.stringify({
        module: module || null,
        function: functionName,
        arity,
        maxEdges: 80,
        direction: dir,
      }),
    });
    if (data.status === 'error') throw new Error(formatErrorReason(data.reason));
    const payload = data.data || data;
    const mfa = payload.mfa || `${module || '?'}:${functionName}/${arity}`;
    const edgeCount = payload.edgeCount ?? (payload.edges || []).length;
    const shown = payload.mermaidEdgeCount ?? (payload.edges || []).length;
    const dirLabel = callGraphDirLabel(dir);
    if (!payload.mermaid || !String(payload.mermaid).trim()) {
      if (status) status.textContent = `${dirLabel} ${mfa} · 0 边`;
      setStatus(`${mfa} 无调用边`);
      return null;
    }
    const entry = pushGraphArtifact({
      tool: dir === 'both' ? 'coreCallFlow' : (dir === 'callers' ? 'coreCallers' : 'coreCallees'),
      title: `${dirLabel}: ${mfa}`,
      meta: `${shown}/${edgeCount} edges`
        + (payload.truncated ? ' · truncated' : '')
        + (payload.briefs && Object.keys(payload.briefs).length
          ? ` · 简述 ${Object.keys(payload.briefs).length}`
          : ''),
      mermaid: payload.mermaid,
      edges: payload.edges || [],
      briefs: payload.briefs || {},
      byModule: payload.byModule || [],
      query: { module, function: functionName, arity, direction: dir, mfa },
    });
    if (status) status.textContent = `${dirLabel} ${mfa} · ${shown}/${edgeCount}`;
    renderGraphView(entry);
    renderGraphDetailSummary(entry);
    openGraphViewer(entry.id);
    setStatus(`已生成 ${dirLabel} 图：${mfa}`);
    return entry;
  } catch (e) {
    if (status) status.textContent = `失败: ${e.message}`;
    setStatus(`调用图失败: ${e.message}`);
    return null;
  }
}

function callGraphDirLabel(dir) {
  if (dir === 'both') return '双向调用链';
  if (dir === 'callees') return '它调用谁';
  return '被谁调用';
}

function flattenByModule(byModule) {
  if (Array.isArray(byModule)) return byModule;
  if (byModule && typeof byModule === 'object') {
    const out = [];
    (byModule.callers || []).forEach((m) => out.push({ ...m, _side: 'callers' }));
    (byModule.callees || []).forEach((m) => out.push({ ...m, _side: 'callees' }));
    return out;
  }
  return [];
}

function renderGraphDetailSummary(g) {
  const el = document.getElementById('graphDetail');
  if (!el || !g) return;
  el.classList.remove('muted');
  const q = g.query || {};
  const mods = flattenByModule(g.byModule).slice(0, 12).map((m) =>
    `<li><strong>${escapeHtml(m.mod)}</strong> · ${m.n} 处`
      + (m._side ? ` · ${m._side === 'callers' ? '调用方' : '被调方'}` : '')
      + (Array.isArray(m.sites) && m.sites.length
        ? `<div class="graph-detail-sites">${escapeHtml(m.sites.slice(0, 8).join(', '))}`
          + (m.sites.length > 8 ? '…' : '')
          + '</div>'
        : '')
      + '</li>').join('');
  const briefCount = g.briefs ? Object.keys(g.briefs).length : 0;
  el.innerHTML = `<div class="graph-detail-head"><strong>${escapeHtml(g.title)}</strong>`
    + (g.meta ? ` <span class="muted">${escapeHtml(g.meta)}</span>` : '')
    + `</div>`
    + (q.mfa ? `<div class="muted">中心 MFA：${escapeHtml(q.mfa)}</div>` : '')
    + (briefCount ? `<div class="muted">源码简述 ${briefCount} 个（有 %% / @doc 才有）</div>` : '')
    + (mods
      ? `<div class="graph-detail-label">按模块</div><ul class="graph-detail-mods">${mods}</ul>`
      : '<div class="muted">无模块聚合</div>')
    + `<div class="muted graph-detail-tip">在独立窗口点击节点查看函数详情</div>`;
}

function parseMfaLabel(text) {
  const t = String(text || '').trim();
  const m = t.match(/^([A-Za-z_?][\w?]*):([A-Za-z_?][\w?]*)\/(\d+|\?)/);
  if (!m) return null;
  return {
    module: m[1] === '?' ? null : m[1],
    function: m[2] === '?' ? null : m[2],
    arity: m[3] === '?' ? null : Number(m[3]),
    label: `${m[1]}:${m[2]}/${m[3]}`,
  };
}

function edgeTouchesMfa(edge, mfa) {
  if (!edge || !mfa) return false;
  const from = `${edge.from_module || '?'}:${edge.from_function || '?'}/${edge.from_arity ?? '?'}`;
  const to = `${edge.to_module || '?'}:${edge.to_function || edge.function || '?'}/${edge.arity ?? '?'}`;
  return from === mfa.label || to === mfa.label;
}

function setGraphViewerDetailHtml(html, isMuted) {
  const body = document.getElementById('graphViewerDetailBody');
  const side = document.getElementById('graphDetail');
  if (body) {
    body.classList.toggle('muted', !!isMuted);
    body.innerHTML = html;
  }
  if (side && !isMuted) {
    side.classList.remove('muted');
    side.innerHTML = html;
  }
}

async function showGraphNodeDetail(g, mfa) {
  if (!mfa) {
    setGraphViewerDetailHtml('无法解析节点标签', true);
    return;
  }
  const related = (g.edges || []).filter((e) => edgeTouchesMfa(e, mfa));
  const lines = related.slice(0, 12).map((e) => {
    const from = `${e.from_module || '?'}:${e.from_function || '?'}/${e.from_arity ?? '?'}`;
    const to = `${e.to_module || '?'}:${e.to_function || e.function || '?'}/${e.arity ?? '?'}`;
    const loc = e.file ? `${e.file}:${e.line || '?'}` : (e.line != null ? `line ${e.line}` : '');
    return `<li><code>${escapeHtml(from)}</code> → <code>${escapeHtml(to)}</code>`
      + (loc ? `<div class="muted">${escapeHtml(loc)}</div>` : '')
      + '</li>';
  }).join('');

  let specHtml = '';
  let fileHtml = '';
  let annHtml = '';
  const briefFromGraph = (g.briefs && mfa.label) ? g.briefs[mfa.label] : null;
  if (briefFromGraph) {
    annHtml = `<div class="graph-detail-label">源码简述</div>`
      + `<pre class="graph-detail-spec">${escapeHtml(String(briefFromGraph))}</pre>`;
  }
  if (mfa.module && mfa.function && mfa.arity != null) {
    try {
      const data = await api('/api/core/module', {
        method: 'POST',
        body: JSON.stringify({ module: mfa.module, maxCalls: 40 }),
      });
      const doc = data.data?.document || data.data || {};
      if (doc.file) fileHtml = `<div>文件：<code>${escapeHtml(doc.file)}</code></div>`;
      const funs = doc.functions || [];
      const hit = funs.find((f) =>
        (f.name === mfa.function || f.function === mfa.function)
          && Number(f.arity ?? f.a) === Number(mfa.arity));
      if (hit) {
        const start = hit.line ?? hit.start_line ?? hit.startLine;
        const end = hit.end_line ?? hit.endLine;
        annHtml += `<div>符号行：${start != null ? start : '?'}`
          + (end != null ? `–${end}` : '')
          + (hit.exported ? ' · exported' : '')
          + '</div>';
      }
      const specs = doc.specs || doc.spec || [];
      const specHit = (Array.isArray(specs) ? specs : []).find((s) =>
        (s.name === mfa.function || s.function === mfa.function)
          && (s.arity == null || Number(s.arity) === Number(mfa.arity)));
      if (specHit) {
        const text = specHit.spec || specHit.text || specHit.source || JSON.stringify(specHit);
        specHtml = `<div class="graph-detail-label">-spec / 类型</div>`
          + `<pre class="graph-detail-spec">${escapeHtml(String(text))}</pre>`;
      }
      const docs = doc.docs || doc.edoc || [];
      const docHit = (Array.isArray(docs) ? docs : []).find((d) =>
        d.name === mfa.function || d.function === mfa.function);
      if ((docHit?.text || docHit?.doc) && !briefFromGraph) {
        annHtml += `<div class="graph-detail-label">注解</div>`
          + `<pre class="graph-detail-spec">${escapeHtml(String(docHit.text || docHit.doc))}</pre>`;
      }
    } catch {
      /* 模块详情可选 */
    }
  }

  const html = `<div class="graph-detail-head"><strong>${escapeHtml(mfa.label)}</strong></div>`
    + `<div>模块：<code>${escapeHtml(mfa.module || '?')}</code></div>`
    + `<div>函数：<code>${escapeHtml(mfa.function || '?')}</code></div>`
    + `<div>元数（参数个数）：<code>${escapeHtml(String(mfa.arity ?? '?'))}</code></div>`
    + fileHtml
    + annHtml
    + specHtml
    + (lines
      ? `<div class="graph-detail-label">相关调用边（${related.length}）</div><ul class="graph-detail-mods">${lines}</ul>`
      : '<div class="muted">当前图中无与该节点直接相关的边详情</div>');
  setGraphViewerDetailHtml(html, false);
}

function bindGraphNodeClicks(g) {
  if (!graphViewerCanvas || !g) return;
  graphViewerCanvas.querySelectorAll('svg .node, svg g.node').forEach((node) => {
    node.style.cursor = 'pointer';
    node.addEventListener('click', (ev) => {
      ev.stopPropagation();
      const label = (node.textContent || '').replace(/\s+/g, ' ').trim();
      const fromTexts = Array.from(node.querySelectorAll('text, span, div'))
        .map((n) => (n.textContent || '').trim())
        .find((t) => t && t.includes(':') && t.includes('/'));
      const mfa = parseMfaLabel(label) || parseMfaLabel(fromTexts || '');
      showGraphNodeDetail(g, mfa);
    });
  });
}

function loadGraphs() {
  renderGraphsList();
  bindGraphMfaForm();
  if (activeGraphId) {
    const g = graphArtifacts.find((x) => x.id === activeGraphId);
    if (g) {
      renderGraphView(g);
      renderGraphDetailSummary(g);
    }
  } else if (!graphArtifacts.length) {
    const view = document.getElementById('graphView');
    if (view) {
      view.classList.add('muted');
      view.textContent = '暂无图表 — 上方输入 MFA 生成调用/被调用图，或运行 callGraph / moduleDeps 后会出现在这里';
    }
    setGraphDetailHint();
  }
}

//==================================================================
// 独立图查看器：缩放 / 平移 / 适配 / 搜索高亮 / 导出
//==================================================================
const graphViewer = document.getElementById('graphViewer');
const graphViewerPanel = document.getElementById('graphViewerPanel');
const graphViewerDrag = document.getElementById('graphViewerDrag');
const graphViewerTitle = document.getElementById('graphViewerTitle');
const graphViewerMeta = document.getElementById('graphViewerMeta');
const graphViewerZoomEl = document.getElementById('graphViewerZoom');
const graphViewerViewport = document.getElementById('graphViewerViewport');
const graphViewerCanvas = document.getElementById('graphViewerCanvas');
const graphViewerSource = document.getElementById('graphViewerSource');
const graphViewerSearch = document.getElementById('graphViewerSearch');
const graphViewerSearchCount = document.getElementById('graphViewerSearchCount');
const btnGvZoomIn = document.getElementById('btnGvZoomIn');
const btnGvZoomOut = document.getElementById('btnGvZoomOut');
const btnGvFit = document.getElementById('btnGvFit');
const btnGvReset = document.getElementById('btnGvReset');
const btnGvCopy = document.getElementById('btnGvCopy');
const btnGvDlSvg = document.getElementById('btnGvDlSvg');
const btnGvDlMmd = document.getElementById('btnGvDlMmd');
const btnGvSource = document.getElementById('btnGvSource');
const btnGvFullscreen = document.getElementById('btnGvFullscreen');
const btnGvPopout = document.getElementById('btnGvPopout');
const btnGvClose = document.getElementById('btnGvClose');
const btnGvPrev = document.getElementById('btnGvPrev');
const btnGvNext = document.getElementById('btnGvNext');

const GV_POS_KEY = 'ali.graphViewer.geom.v2';
const GV_SCALE_MIN = 0.2;
const GV_SCALE_MAX = 12;
let gvActiveId = null;
let gvScale = 1;
let gvTx = 0;
let gvTy = 0;
let gvDragState = null;
let gvPanState = null;
let gvGeomBeforeFullscreen = null;
let gvRenderToken = 0;
let gvFitRetries = 0;

/** 规范化 Mermaid SVG：按真实内容重设 viewBox，去掉固定像素与 max-width 约束。 */
function normalizeGraphSvg(svg) {
  if (!svg) return { w: 800, h: 600 };
  // 清掉 mermaid 可能注入的尺寸限制，否则测量/居中会偏
  svg.style.maxWidth = 'none';
  svg.style.maxHeight = 'none';
  svg.style.width = '';
  svg.style.height = '';
  svg.removeAttribute('width');
  svg.removeAttribute('height');

  let w = 0;
  let h = 0;
  let x = 0;
  let y = 0;
  try {
    const bb = svg.getBBox();
    if (bb && bb.width > 1 && bb.height > 1) {
      const pad = 12;
      x = bb.x - pad;
      y = bb.y - pad;
      w = bb.width + pad * 2;
      h = bb.height + pad * 2;
      svg.setAttribute('viewBox', `${x} ${y} ${w} ${h}`);
    }
  } catch { /* not in DOM yet */ }

  if (!(w > 0 && h > 0)) {
    const vb = svg.viewBox?.baseVal;
    if (vb && vb.width > 0 && vb.height > 0) {
      x = vb.x;
      y = vb.y;
      w = vb.width;
      h = vb.height;
    } else {
      w = 800;
      h = 600;
      svg.setAttribute('viewBox', `0 0 ${w} ${h}`);
    }
  }

  svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');
  svg.dataset.vbW = String(w);
  svg.dataset.vbH = String(h);
  return { w, h };
}

/**
 * 清晰缩放：只改 SVG 的 width/height（矢量重绘），平移用 translate。
 * 避免 CSS transform: scale 把小图位图拉伸导致发糊。
 */
function applyGraphViewerTransform() {
  if (!graphViewerCanvas) return;
  const svg = graphViewerCanvas.querySelector('svg');
  if (svg) {
    const w = parseFloat(svg.dataset.vbW) || 800;
    const h = parseFloat(svg.dataset.vbH) || 600;
    const pxW = Math.max(1, w * gvScale);
    const pxH = Math.max(1, h * gvScale);
    svg.setAttribute('width', String(pxW));
    svg.setAttribute('height', String(pxH));
    svg.style.width = `${pxW}px`;
    svg.style.height = `${pxH}px`;
    svg.style.maxWidth = 'none';
    svg.style.maxHeight = 'none';
  }
  graphViewerCanvas.style.transform = `translate(${gvTx}px, ${gvTy}px)`;
  if (graphViewerZoomEl) graphViewerZoomEl.textContent = `${Math.round(gvScale * 100)}%`;
}

function loadGraphViewerGeom() {
  try {
    const raw = localStorage.getItem(GV_POS_KEY);
    if (!raw) return null;
    const g = JSON.parse(raw);
    return g && typeof g === 'object' ? g : null;
  } catch {
    return null;
  }
}

function defaultGraphViewerGeom() {
  const vw = window.innerWidth;
  const vh = window.innerHeight;
  const margin = 8;
  const width = Math.max(560, Math.min(Math.floor(vw * 0.9), vw - margin * 2));
  const height = Math.max(420, vh - margin * 2);
  return {
    left: Math.max(margin, Math.floor((vw - width) / 2)),
    top: Math.max(margin, Math.floor((vh - height) / 2)),
    width,
    height,
  };
}

function currentGraphViewerGeom() {
  if (!graphViewerPanel) return null;
  const r = graphViewerPanel.getBoundingClientRect();
  return { left: r.left, top: r.top, width: r.width, height: r.height };
}

function saveGraphViewerGeom() {
  if (!graphViewer || !graphViewerPanel) return;
  if (graphViewer.classList.contains('hidden')) return;
  if (graphViewer.classList.contains('is-fullscreen')) return;
  const g = currentGraphViewerGeom();
  if (!g) return;
  try { localStorage.setItem(GV_POS_KEY, JSON.stringify(g)); } catch { /* ignore */ }
}

function applyGraphViewerGeom(geom) {
  if (!graphViewerPanel) return;
  const base = defaultGraphViewerGeom();
  const g = geom && typeof geom === 'object' ? geom : base;
  const vw = window.innerWidth;
  const vh = window.innerHeight;
  let width = Number(g.width);
  let height = Number(g.height);
  if (!Number.isFinite(width) || width <= 0) width = base.width;
  if (!Number.isFinite(height) || height <= 0) height = base.height;
  width = Math.max(360, Math.min(width, vw - 8));
  height = Math.max(280, Math.min(height, vh - 8));
  let left = g.left != null && Number.isFinite(Number(g.left)) ? Number(g.left) : base.left;
  let top = g.top != null && Number.isFinite(Number(g.top)) ? Number(g.top) : base.top;
  left = Math.max(0, Math.min(left, vw - 80));
  top = Math.max(0, Math.min(top, vh - 40));
  graphViewerPanel.style.left = `${left}px`;
  graphViewerPanel.style.top = `${top}px`;
  graphViewerPanel.style.width = `${width}px`;
  graphViewerPanel.style.height = `${height}px`;
}

function closeGraphViewer() {
  if (!graphViewer) return;
  saveGraphViewerGeom();
  graphViewer.classList.add('hidden');
  graphViewer.classList.remove('is-fullscreen');
  if (btnGvFullscreen) btnGvFullscreen.textContent = '全屏';
  gvDragState = null;
  gvPanState = null;
  gvFitRetries = 0;
  if (graphViewerDrag) graphViewerDrag.classList.remove('dragging');
  if (graphViewerViewport) graphViewerViewport.classList.remove('panning');
}

function gvDownloadBlob(filename, blob) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function gvSafeFilename(title) {
  return String(title || 'graph').replace(/[^\w.\-:+]+/g, '_').slice(0, 80);
}

function centerGraphInViewport(contentW, contentH, scale) {
  if (!graphViewerViewport) return { tx: 0, ty: 0 };
  const availW = graphViewerViewport.clientWidth;
  const availH = graphViewerViewport.clientHeight;
  const pxW = contentW * scale;
  const pxH = contentH * scale;
  return {
    tx: (availW - pxW) / 2,
    ty: (availH - pxH) / 2,
  };
}

function fitGraphViewer() {
  if (!graphViewerViewport || !graphViewerCanvas) return;
  const svg = graphViewerCanvas.querySelector('svg');
  if (!svg) return;

  const availW = graphViewerViewport.clientWidth;
  const availH = graphViewerViewport.clientHeight;
  // 面板刚打开时布局可能尚未完成，延迟再适配
  if (availW < 80 || availH < 80) {
    if (gvFitRetries < 30) {
      gvFitRetries += 1;
      requestAnimationFrame(() => fitGraphViewer());
    }
    return;
  }
  gvFitRetries = 0;

  // 先给一个临时尺寸，让 getBBox 可靠
  svg.style.width = '1200px';
  svg.style.height = 'auto';
  const { w: contentW, h: contentH } = normalizeGraphSvg(svg);
  if (!(contentW > 0 && contentH > 0)) return;

  // 留约 8% 边距，铺满并居中
  const scale = Math.min(availW / contentW, availH / contentH) * 0.92;
  gvScale = Math.max(GV_SCALE_MIN, Math.min(GV_SCALE_MAX, scale));
  const { tx, ty } = centerGraphInViewport(contentW, contentH, gvScale);
  gvTx = tx;
  gvTy = ty;
  applyGraphViewerTransform();
}

function resetGraphViewerView() {
  // 「重置」= 重新适配窗口并居中
  fitGraphViewer();
}

function zoomGraphViewer(factor, cx, cy) {
  if (!graphViewerViewport) return;
  const rect = graphViewerViewport.getBoundingClientRect();
  const px = cx != null ? cx - rect.left : rect.width / 2;
  const py = cy != null ? cy - rect.top : rect.height / 2;
  const next = Math.max(GV_SCALE_MIN, Math.min(GV_SCALE_MAX, gvScale * factor));
  if (next === gvScale) return;
  const ratio = next / gvScale;
  gvTx = px - (px - gvTx) * ratio;
  gvTy = py - (py - gvTy) * ratio;
  gvScale = next;
  applyGraphViewerTransform();
}

function panGraphViewer(dx, dy) {
  gvTx += dx;
  gvTy += dy;
  applyGraphViewerTransform();
}

function highlightGraphNodes(query) {
  if (!graphViewerCanvas) return 0;
  const q = String(query || '').trim().toLowerCase();
  const texts = graphViewerCanvas.querySelectorAll('svg text, svg .nodeLabel, svg .label, svg foreignObject div, svg foreignObject span');
  const nodes = graphViewerCanvas.querySelectorAll('svg .node, svg g.node, svg [id^="flowchart-"], svg .cluster');
  nodes.forEach((n) => {
    n.classList.remove('gv-hit', 'gv-dim');
  });
  texts.forEach((t) => {
    t.classList.remove('gv-hit', 'gv-dim');
  });
  if (!q) {
    if (graphViewerSearchCount) graphViewerSearchCount.textContent = '0';
    return 0;
  }
  let hits = 0;
  const hitNodes = new Set();
  texts.forEach((t) => {
    const label = (t.textContent || '').toLowerCase();
    if (label.includes(q)) {
      hits += 1;
      t.classList.add('gv-hit');
      let el = t;
      for (let i = 0; i < 6 && el; i++) {
        if (el.classList?.contains('node') || (el.id && String(el.id).startsWith('flowchart-'))) {
          hitNodes.add(el);
          break;
        }
        el = el.parentElement;
      }
    }
  });
  nodes.forEach((n) => {
    if (hitNodes.has(n) || (n.textContent || '').toLowerCase().includes(q)) {
      n.classList.add('gv-hit');
      hitNodes.add(n);
    } else {
      n.classList.add('gv-dim');
    }
  });
  if (graphViewerSearchCount) graphViewerSearchCount.textContent = String(hits || hitNodes.size);
  return hits || hitNodes.size;
}

async function renderGraphIntoViewer(g) {
  if (!graphViewerCanvas) return;
  const token = ++gvRenderToken;
  graphViewerCanvas.innerHTML = '';
  graphViewerCanvas.style.transform = 'translate(0px, 0px)';
  if (graphViewerSource) {
    graphViewerSource.textContent = g.mermaid || g.markdown || '';
  }
  if (g.mermaid && String(g.mermaid).trim()) {
    if (!window.mermaid) {
      const pre = document.createElement('pre');
      pre.className = 'mermaid-source';
      pre.textContent = g.mermaid;
      graphViewerCanvas.appendChild(pre);
      return;
    }
    const id = `gv-mmd-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    try {
      const { svg } = await window.mermaid.render(id, g.mermaid);
      if (token !== gvRenderToken) return;
      graphViewerCanvas.innerHTML = svg;
      const el = graphViewerCanvas.querySelector('svg');
      if (el) {
        // 临时尺寸便于 getBBox
        el.style.width = '1600px';
        el.style.height = 'auto';
        el.style.maxWidth = 'none';
      }
      gvFitRetries = 0;
      const doFit = () => {
        if (token !== gvRenderToken) return;
        fitGraphViewer();
        if (graphViewerSearch?.value) highlightGraphNodes(graphViewerSearch.value);
      };
      // 双 rAF + 短延迟，确保面板布局与 SVG 度量完成后再居中
      requestAnimationFrame(() => {
        requestAnimationFrame(() => {
          doFit();
          setTimeout(doFit, 50);
          setTimeout(doFit, 200);
        });
      });
      if (document.fonts?.ready) {
        document.fonts.ready.then(doFit).catch(() => {});
      }
      bindGraphNodeClicks(g);
    } catch (err) {
      if (token !== gvRenderToken) return;
      const pre = document.createElement('pre');
      pre.className = 'mermaid-source';
      pre.textContent = `渲染失败: ${err.message || err}\n\n${g.mermaid}`;
      graphViewerCanvas.appendChild(pre);
    }
  } else if (g.markdown) {
    const pre = document.createElement('pre');
    pre.className = 'thinking-hit-snippet';
    pre.textContent = g.markdown;
    graphViewerCanvas.appendChild(pre);
    gvTx = 24;
    gvTy = 24;
    gvScale = 1;
    applyGraphViewerTransform();
  } else {
    graphViewerCanvas.textContent = '无可渲染内容';
  }
}

function openGraphViewer(id) {
  const g = graphArtifacts.find((x) => x.id === id);
  if (!g || !graphViewer) return;
  gvActiveId = id;
  activeGraphId = id;
  if (sidePanel?.classList.contains('hidden') === false) {
    selectSideTab('graphs');
    renderGraphsList();
    renderGraphView(g);
  }
  graphViewer.classList.remove('hidden');
  if (!graphViewer.classList.contains('is-fullscreen')) {
    // 若本地记住的窗口过小，改用更大的默认尺寸
    const saved = loadGraphViewerGeom();
    const base = defaultGraphViewerGeom();
    const geom = saved && saved.width >= 480 && saved.height >= 360 ? saved : base;
    applyGraphViewerGeom(geom);
  }
  if (graphViewerTitle) {
    graphViewerTitle.textContent = g.title + (g.meta ? ` · ${g.meta}` : '');
  }
  if (graphViewerMeta) {
    const parts = [g.tool || 'graph'];
    if (g.query?.mfa) parts.push(`中心 ${g.query.mfa}`);
    if (Array.isArray(g.edges) && g.edges.length) parts.push(`${g.edges.length} 边`);
    if (g.meta) parts.push(g.meta);
    if (g.writePath) parts.push(String(g.writePath));
    graphViewerMeta.textContent = parts.join(' · ');
  }
  if (graphViewerSearch) graphViewerSearch.value = '';
  if (graphViewerSearchCount) graphViewerSearchCount.textContent = '0';
  if (graphViewerSource) graphViewerSource.classList.add('hidden');
  setGraphViewerDetailHtml(
    g.query?.mfa
      ? `中心：<code>${escapeHtml(g.query.mfa)}</code><div class="muted">点击图中节点查看详情</div>`
      : '点击图中节点查看模块 / 函数 / 元数 / 调用点',
    true
  );
  if (g.byModule?.length) renderGraphDetailSummary(g);
  // 先露出面板再渲染，保证 viewport 有真实宽高用于适配
  requestAnimationFrame(() => {
    renderGraphIntoViewer(g);
    graphViewerViewport?.focus?.({ preventScroll: true });
  });
}

function shiftGraphViewer(delta) {
  if (!graphArtifacts.length) return;
  let idx = graphArtifacts.findIndex((x) => x.id === gvActiveId);
  if (idx < 0) idx = 0;
  const next = (idx + delta + graphArtifacts.length) % graphArtifacts.length;
  openGraphViewer(graphArtifacts[next].id);
}

function renderHealLocations(ev) {
  if (!thinkingList || !thinkingList.parentNode) return;
  const locs = [];
  const failures = Array.isArray(ev.failures) ? ev.failures : [];
  const re = /([A-Za-z0-9_./\\-]+\.erl):(\d+)/g;
  for (const f of failures) {
    const s = String(f || '');
    let m;
    while ((m = re.exec(s))) {
      locs.push({ path: m[1].replace(/\\/g, '/'), line: Number(m[2]) });
    }
  }
  // also parse message
  if (typeof ev.message === 'string') {
    let m;
    const re2 = /([A-Za-z0-9_./\\-]+\.erl):(\d+)/g;
    while ((m = re2.exec(ev.message))) {
      locs.push({ path: m[1].replace(/\\/g, '/'), line: Number(m[2]) });
    }
  }
  const uniq = [];
  const seen = new Set();
  for (const loc of locs) {
    const key = `${loc.path}:${loc.line}`;
    if (seen.has(key)) continue;
    seen.add(key);
    uniq.push(loc);
    if (uniq.length >= 12) break;
  }
  if (!uniq.length) return;
  const wrap = document.createElement('li');
  wrap.className = 'thinking-heal-locs';
  const label = document.createElement('div');
  label.className = 'muted';
  label.textContent = '自愈定位（点击打开）：';
  wrap.appendChild(label);
  uniq.forEach((loc) => {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'btn-muted btn-xs heal-loc-btn';
    btn.textContent = `${loc.path}:${loc.line}`;
    btn.title = '在文件查看器中打开';
    btn.addEventListener('click', (e) => {
      e.preventDefault();
      openFileViewer(loc.path, null, loc.line);
    });
    wrap.appendChild(btn);
  });
  thinkingList.appendChild(wrap);
}

document.getElementById('btnGraphsClear')?.addEventListener('click', () => {
  clearGraphArtifactsUi();
});


async function stopAsk() {
  const sid = currentSessionId();
  const stopTaskId = activeAsk?.taskId ? String(activeAsk.taskId) : 'all';
  const partial = activeAsk?.full || '';
  const msgWrap = activeAsk?.msgWrap;
  if (activeAskAbort) {
    activeAskAbort.abort();
    activeAskAbort = null;
  }
  if (activeAsk?.es) {
    try { activeAsk.es.close(); } catch { /* ignore */ }
  }
  // 先结束本轮 UI（摘掉 streamHandler），避免 cancel 回包的 error/done 误判失败
  if (activeAsk) {
    finishActiveAsk(null, partial);
    if (partial) maybeShowApprove(partial);
  }
  if (msgWrap) {
    msgWrap.classList.add('stopped');
    if (!msgWrap.querySelector('.msg-stopped-badge')) {
      const badge = document.createElement('span');
      badge.className = 'msg-stopped-badge';
      badge.textContent = '已停止';
      msgWrap.appendChild(badge);
    }
  }
  try {
    await ctrl('cancelAsk', { sessionId: sid, taskId: stopTaskId }, '/api/ask/cancel', {
      method: 'POST',
      body: JSON.stringify({ sessionId: sid, taskId: stopTaskId }),
    });
  } catch (e) {
    appendMsg('system', `停止失败: ${e.message}`);
    setAsking(false);
    setStatus('就绪');
    return;
  }
  appendMsg('system', partial
    ? '已停止当前回答（已保留已生成内容）'
    : '已停止当前回答');
  setAsking(false);
  setStatus('就绪');
}

/** 服务端 GET / 注入的公开配置（见 alConfig:publicWebConfig/0） */
let attachLimits = {
  maxImages: 16,
  maxFiles: 10,
  maxImageBytes: 20971520,
  maxFileBytes: 5242880,
  maxDocuments: 4,
  maxDocumentBytes: 10485760,
  textFileExtensions: [],
  documentFileExtensions: ['.pdf', '.doc', '.docx', '.xls', '.xlsx', '.xlsm', '.ppt', '.pptx', '.epub'],
  imageMimeTypes: ['image/jpeg', 'image/png', 'image/gif', 'image/webp'],
  documentMimeTypes: [
    'application/pdf',
    'application/msword',
    'application/vnd.ms-excel',
    'application/vnd.ms-powerpoint',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'application/epub+zip',
  ],
  textFileRe: /\.(patch|diff|ipynb|svg)$/i,
  documentFileRe: /\.(pdf|docx?|xlsx?|xlsm|pptx?|epub)$/i,
};

function readEmbeddedConfig() {
  const el = document.getElementById('ali-config');
  if (!el?.textContent?.trim()) return null;
  try {
    return JSON.parse(el.textContent);
  } catch {
    return null;
  }
}

function applyWebConfig(cfg) {
  if (!cfg || typeof cfg !== 'object') return;
  if (cfg.attachmentLimits) applyAttachLimits(cfg.attachmentLimits);
  const mode = cfg.agent?.mode;
  if (mode && modeSelect) modeSelect.value = mode;
  window.__ALI_CONFIG__ = cfg;
  updateLlmLocalInfo();
  updateLlmButtonLabel();
  if (cfg.web?.authEnabled && !apiToken()) {
    setStatus('需要 Token（点击右上角 Token 设置）');
  }
}

function visionSupported() {
  const cfg = window.__ALI_CONFIG__ || {};
  const own = llmUseOwnEnabled();
  // 服务端已按链项 vision 配置算好；自备模型时才用本地启发式。
  if (!own && cfg.llm?.vision === true) return true;
  if (!own && cfg.llm?.vision === false) return false;
  const chain = llmChainInfo();
  const model = String((own
    ? llmStoredModel()
    : (chain.local?.model || chain.cloud?.model || cfg.llm?.model)) || '').toLowerCase();
  if (/embedding|rerank|tts|asr|whisper|speech/.test(model)) return false;
  // auto 兜底：只认模型名，不按厂商写死（云端请配 vision => true/false）
  if (/\.gguf|-vl|vision|llava|minicpm-v|internvl|pixtral|moondream|ornith|glm-4v|deepseek-vl|janus/.test(model)) {
    return true;
  }
  return /gpt-4o|gpt-4-turbo|gpt-4-vision|gpt-4\.1|o[134]/.test(model);
}

let llmProvidersCache = [];

const LLM_LOCAL_PROVIDERS = new Set([
  'ollama', 'llamacpp', 'vllm', 'lmstudio', 'janus', 'local', 'ornith',
]);

function llmChainInfo() {
  return window.__ALI_CONFIG__?.llm?.chain || {};
}

function llmHasLocalChain() {
  const chain = llmChainInfo();
  return chain.enabled === true && chain.local != null;
}

function cloudLlmProviders() {
  return llmProvidersCache.filter((p) => !LLM_LOCAL_PROVIDERS.has(String(p.id || '').toLowerCase()));
}

function defaultCloudProviderId() {
  const chain = llmChainInfo();
  if (chain.cloud?.provider) return String(chain.cloud.provider);
  const cfg = window.__ALI_CONFIG__?.llm || {};
  if (cfg.provider && !LLM_LOCAL_PROVIDERS.has(String(cfg.provider).toLowerCase())) {
    return String(cfg.provider);
  }
  const clouds = cloudLlmProviders();
  return clouds[0]?.id || '';
}

function defaultCloudModelId() {
  const chain = llmChainInfo();
  if (chain.cloud?.model) return String(chain.cloud.model);
  const provider = defaultCloudProviderId();
  const p = cloudLlmProviders().find((x) => x.id === provider);
  return p?.defaultModel || '';
}

function updateLlmLocalInfo() {
  const el = document.getElementById('llmLocalInfo');
  if (!el) return;
  const chain = llmChainInfo();
  if (chain.enabled && chain.local) {
    const p = chain.local.provider || '?';
    const m = chain.local.model || '?';
    el.textContent = `本地模型（服务器配置，优先尝试）：${p} / ${m}`;
    el.classList.remove('hidden');
  } else {
    el.textContent = '';
    el.classList.add('hidden');
  }
}

function llmUseOwnEnabled() {
  return localStorage.getItem('alLlmUseOwn') === '1';
}

function llmStoredProvider() {
  return localStorage.getItem('alLlmProvider') || '';
}

function llmStoredModel() {
  return localStorage.getItem('alLlmModel') || '';
}

function llmStoredApiKey() {
  return localStorage.getItem('alLlmApiKey') || '';
}

function llmPayload() {
  if (!llmUseOwnEnabled()) return {};
  const provider = llmStoredProvider();
  const model = llmStoredModel();
  const apiKey = llmStoredApiKey();
  const llm = {};
  if (provider) llm.provider = provider;
  if (model) llm.model = model;
  if (apiKey) llm.apiKey = apiKey;
  return Object.keys(llm).length ? { llm } : {};
}

function updateLlmButtonLabel() {
  if (!btnLlm) return;
  if (!llmUseOwnEnabled()) {
    btnLlm.textContent = '模型';
    if (llmHasLocalChain()) {
      btnLlm.title = '自定义云模型与 API Key（当前：本地先试 + 服务器默认云端）';
    } else {
      btnLlm.title = '自定义云模型与 API Key（当前：服务器默认）';
    }
    return;
  }
  const p = llmStoredProvider() || '?';
  const m = llmStoredModel() || '?';
  btnLlm.textContent = `${p}`;
  if (llmHasLocalChain()) {
    btnLlm.title = `自定义云：${p} / ${m}（本地仍先试，答不好再升此云模型）`;
  } else {
    btnLlm.title = `自定义云模型：${p} / ${m}`;
  }
}

function appendModelOption(selectEl, id, label) {
  const opt = document.createElement('option');
  opt.value = id;
  // 下拉显示完整 API 型号，避免简写（如 V4 Pro）与真实 model 参数不一致
  opt.textContent = id || label || '';
  selectEl.appendChild(opt);
}

function fillModelSelect(providerId) {
  if (!llmModelSelect) return;
  const p = llmProvidersCache.find((x) => x.id === providerId);
  llmModelSelect.innerHTML = '';
  const groups = p?.modelGroups;
  if (Array.isArray(groups) && groups.length) {
    groups.forEach((g) => {
      const og = document.createElement('optgroup');
      og.label = g.label || '模型';
      (g.models || []).forEach((m) => {
        const id = typeof m === 'string' ? m : m.id;
        const label = typeof m === 'string' ? m : (m.label || m.id);
        if (id) appendModelOption(og, id, label);
      });
      if (og.children.length) llmModelSelect.appendChild(og);
    });
  }
  const flat = p?.models || (p?.defaultModel ? [p.defaultModel] : []);
  if (!llmModelSelect.options.length) {
    flat.forEach((m) => appendModelOption(llmModelSelect, m, m));
  }
}

function llmSelectHasModel(modelId) {
  if (!llmModelSelect || !modelId) return false;
  return [...llmModelSelect.options].some((o) => o.value === modelId);
}

function applyStoredLlmSelection() {
  const cfg = window.__ALI_CONFIG__ || {};
  const providers = cloudLlmProviders();
  const provider = llmStoredProvider()
    || defaultCloudProviderId()
    || providers[0]?.id
    || '';
  if (provider && llmProviderSelect) {
    llmProviderSelect.value = provider;
  }
  fillModelSelect(llmProviderSelect?.value || provider);
  let model = llmStoredModel() || defaultCloudModelId() || '';
  if (!model) {
    const p = providers.find((x) => x.id === (llmProviderSelect?.value || provider));
    model = p?.defaultModel || '';
  }
  if (model && llmModelSelect && !llmSelectHasModel(model)) {
    if (llmStoredModel()) localStorage.removeItem('alLlmModel');
    const p = providers.find((x) => x.id === (llmProviderSelect?.value || provider));
    model = p?.defaultModel || defaultCloudModelId() || '';
  }
  if (model && llmSelectHasModel(model)) {
    llmModelSelect.value = model;
  }
  updateLlmLocalInfo();
}

async function loadLlmProviders() {
  try {
    const data = await api('/api/llm/providers');
    llmProvidersCache = data.providers || [];
    if (!llmProviderSelect) return;
    llmProviderSelect.innerHTML = '';
    cloudLlmProviders().forEach((p) => {
      const opt = document.createElement('option');
      opt.value = p.id;
      opt.textContent = p.name || p.id;
      llmProviderSelect.appendChild(opt);
    });
    applyStoredLlmSelection();
    updateLlmButtonLabel();
  } catch {
    /* ignore */
  }
}

function openLlmModal() {
  if (!llmModal) return;
  if (llmUseOwn) llmUseOwn.checked = llmUseOwnEnabled();
  if (llmApiKeyInput) llmApiKeyInput.value = llmStoredApiKey();
  applyStoredLlmSelection();
  updateLlmLocalInfo();
  llmModal.classList.remove('hidden');
}

function closeLlmModal() {
  llmModal?.classList.add('hidden');
}

function syncLlmToServer() {
  if (!WS.connected || !WS.sock) return;
  const sessionId = currentSessionId();
  if (!llmUseOwnEnabled()) {
    WS.send({ type: 'setLlm', enabled: false, sessionId });
    return;
  }
  const llm = {};
  const provider = llmStoredProvider();
  const model = llmStoredModel();
  const apiKey = llmStoredApiKey();
  if (provider) llm.provider = provider;
  if (model) llm.model = model;
  if (apiKey) llm.apiKey = apiKey;
  WS.send({ type: 'setLlm', enabled: true, sessionId, llm });
}

function handleSetLlmAck(m) {
  if (!m || m.type !== 'setLlm') return;
  if (m.apiKeyIgnored) {
    appendMsg('system',
      '警告：当前服务端仍忽略浏览器 API Key（只覆盖模型）。请热加载/重启节点以启用最新逻辑。');
    return;
  }
  if (m.enabled === false) return;
  // 仅在用户刚保存后提示；重连自动同步不刷屏
  if (!window.__aliLlmSavePending) return;
  window.__aliLlmSavePending = false;
  const p = m.provider || llmStoredProvider() || '?';
  const model = m.model || llmStoredModel() || '?';
  const keyHint = m.hasApiKey ? '已使用你填写的 API Key' : '未收到 Key，使用服务器 cfg 密钥';
  const chainHint = llmHasLocalChain()
    ? '；本地模型仍先试，答不好再升此云模型'
    : '';
  appendMsg('system', `自定义云模型已生效：${p} / ${model}（${keyHint}${chainHint}）`);
}

function saveLlmSettings() {
  const useOwn = !!llmUseOwn?.checked;
  localStorage.setItem('alLlmUseOwn', useOwn ? '1' : '0');
  if (useOwn) {
    if (llmProviderSelect?.value) localStorage.setItem('alLlmProvider', llmProviderSelect.value);
    if (llmModelSelect?.value) localStorage.setItem('alLlmModel', llmModelSelect.value);
    const key = (llmApiKeyInput?.value || '').trim();
    if (key) localStorage.setItem('alLlmApiKey', key);
    else localStorage.removeItem('alLlmApiKey');
  }
  updateLlmButtonLabel();
  window.__aliLlmSavePending = true;
  syncLlmToServer();
  closeLlmModal();
  if (!useOwn) {
    window.__aliLlmSavePending = false;
    appendMsg('system', '已恢复为服务器默认 LLM 配置');
    return;
  }
  const keySaved = !!(llmApiKeyInput?.value || '').trim();
  if (!keySaved) {
    appendMsg('system', '提示：未填写 API Key，将回退使用服务器 cfg 中的密钥（可能无效）');
  }
}

function renderChatFromMessages(messages) {
  chat.innerHTML = '';
  hideApproveBar();
  (messages || []).forEach((m) => {
    const role = m.role || m['role'];
    const content = m.content ?? m['content'] ?? '';
    if (role === 'system' || role === 'tool') return;
    const text = typeof content === 'string' ? content : JSON.stringify(content);
    appendMsg(role === 'user' ? 'user' : 'agent', text);
  });
}

//==================================================================
// 本地历史会话（DeepSeek 风格左侧栏）
// 存 localStorage；问答仍用同一 sessionId 打到服务端以延续上下文。
// 上限：20 条；超过 30 天自动删除。
//==================================================================
const LH_KEY = 'ali.localHistory.v1';
const LH_MAX = 20;
const LH_MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000;
const historyListEl = document.getElementById('historyList');
const btnNewChat = document.getElementById('btnNewChat');
const btnHistory = document.getElementById('btnHistory');
const btnHistoryClose = document.getElementById('btnHistoryClose');
const historyRail = document.getElementById('historyRail');
const historyBackdrop = document.getElementById('historyBackdrop');

let localHistory = { activeId: null, chats: [] };

function lhNewId() {
  return `lc_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
}

function lhTitleFromText(text) {
  const t = String(text || '').replace(/\s+/g, ' ').trim();
  if (!t) return '新对话';
  return t.length > 28 ? `${t.slice(0, 28)}…` : t;
}

function lhLoad() {
  try {
    const raw = localStorage.getItem(LH_KEY);
    if (!raw) return { activeId: null, chats: [] };
    const data = JSON.parse(raw);
    if (!data || !Array.isArray(data.chats)) return { activeId: null, chats: [] };
    return { activeId: data.activeId || null, chats: data.chats };
  } catch {
    return { activeId: null, chats: [] };
  }
}

function lhPrune(chats) {
  const now = Date.now();
  return (chats || [])
    .filter((c) => {
      if (!c || !c.id) return false;
      if ((now - (c.updatedAt || c.createdAt || 0)) > LH_MAX_AGE_MS) return false;
      const hasMsgs = (c.messages || []).length > 0;
      // 无消息的草稿只保留当前激活项，避免刷新刷出一堆「新对话」
      if (!hasMsgs && c.id !== localHistory.activeId) return false;
      return true;
    })
    .sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0))
    .slice(0, LH_MAX);
}

function lhSave() {
  localHistory.chats = lhPrune(localHistory.chats);
  if (localHistory.activeId && !localHistory.chats.some((c) => c.id === localHistory.activeId)) {
    localHistory.activeId = localHistory.chats[0]?.id || null;
  }
  try {
    localStorage.setItem(LH_KEY, JSON.stringify(localHistory));
  } catch { /* quota */ }
  renderHistoryRail();
}

function lhGetActive() {
  return localHistory.chats.find((c) => c.id === localHistory.activeId) || null;
}

function lhEnsureSessionOption(id) {
  if (!sessionSelect) return;
  if (![...sessionSelect.options].some((o) => o.value === id)) {
    const opt = document.createElement('option');
    opt.value = id;
    opt.textContent = id;
    sessionSelect.appendChild(opt);
  }
  sessionSelect.value = id;
}

function currentSessionId() {
  return localHistory.activeId || sessionSelect?.value || 'web';
}

function lhCreateChat({ activate } = { activate: true }) {
  const id = lhNewId();
  const now = Date.now();
  const chat = {
    id,
    title: '新对话',
    messages: [],
    graphs: [],
    createdAt: now,
    updatedAt: now,
  };
  localHistory.chats.unshift(chat);
  if (activate) localHistory.activeId = id;
  lhSave();
  lhEnsureSessionOption(id);
  return chat;
}

function lhGroupLabel(ts) {
  const d = new Date(ts);
  const now = new Date();
  const startToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const start7 = startToday - 6 * 86400000;
  const start30 = startToday - 29 * 86400000;
  if (ts >= startToday) return '今天';
  if (ts >= start7) return '7 天内';
  if (ts >= start30) return '30 天内';
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
}

function renderHistoryRail() {
  if (!historyListEl) return;
  historyListEl.innerHTML = '';
  const chats = lhPrune(localHistory.chats).filter((c) => (c.messages || []).length > 0);
  if (!chats.length) {
    const empty = document.createElement('div');
    empty.className = 'muted';
    empty.style.padding = '12px 8px';
    empty.textContent = '暂无历史，发送一条消息开始';
    historyListEl.appendChild(empty);
    return;
  }
  let lastGroup = '';
  chats.forEach((c) => {
    const group = lhGroupLabel(c.updatedAt || c.createdAt || Date.now());
    if (group !== lastGroup) {
      lastGroup = group;
      const lab = document.createElement('div');
      lab.className = 'history-group-label';
      lab.textContent = group;
      historyListEl.appendChild(lab);
    }
    const row = document.createElement('div');
    row.className = 'history-item' + (c.id === localHistory.activeId ? ' active' : '');
    row.title = c.title || '新对话';
    const title = document.createElement('button');
    title.type = 'button';
    title.className = 'history-item-title';
    title.textContent = c.title || '新对话';
    title.addEventListener('click', () => openLocalChat(c.id));
    const del = document.createElement('button');
    del.type = 'button';
    del.className = 'history-item-del';
    del.title = '删除';
    del.textContent = '×';
    del.addEventListener('click', (e) => {
      e.stopPropagation();
      deleteLocalChat(c.id);
    });
    row.appendChild(title);
    row.appendChild(del);
    historyListEl.appendChild(row);
  });
}

function snapshotGraphsForLocal() {
  return graphArtifacts.slice(0, 12).map((g) => ({
    id: g.id,
    ts: g.ts,
    tool: g.tool,
    title: g.title,
    meta: g.meta,
    mermaid: (g.mermaid || '').slice(0, 100000),
    markdown: (g.markdown || '').slice(0, 6000),
    writePath: g.writePath || '',
    edges: Array.isArray(g.edges) ? g.edges.slice(0, 80) : [],
    byModule: Array.isArray(g.byModule) ? g.byModule.slice(0, 40) : [],
    query: g.query || null,
  }));
}

function restoreGraphsFromLocal(graphs) {
  graphArtifacts.length = 0;
  activeGraphId = null;
  (graphs || []).forEach((g) => {
    graphArtifacts.push({
      id: g.id || `g-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
      ts: g.ts || Date.now(),
      tool: g.tool || 'graph',
      title: g.title || 'graph',
      meta: g.meta || '',
      mermaid: g.mermaid || '',
      markdown: g.markdown || '',
      writePath: g.writePath || '',
      edges: Array.isArray(g.edges) ? g.edges : [],
      byModule: Array.isArray(g.byModule) ? g.byModule : [],
      query: g.query || null,
    });
  });
  renderGraphsList();
  bindGraphMfaForm();
  const view = document.getElementById('graphView');
  if (graphArtifacts[0]) {
    activeGraphId = graphArtifacts[0].id;
    renderGraphView(graphArtifacts[0]);
    renderGraphDetailSummary(graphArtifacts[0]);
  } else if (view) {
    view.classList.add('muted');
    view.textContent = '暂无图表 — 上方输入 MFA 生成调用/被调用图，或运行 callGraph / moduleDeps 后会出现在这里';
    setGraphDetailHint();
  }
}

function persistActiveLocalChat() {
  const c = lhGetActive();
  if (!c) return;
  c.graphs = snapshotGraphsForLocal();
  c.updatedAt = Date.now();
  lhSave();
}

function appendLocalMessage(role, content) {
  let c = lhGetActive();
  if (!c) c = lhCreateChat({ activate: true });
  const text = typeof content === 'string' ? content : JSON.stringify(content ?? '');
  if (role === 'user' || role === 'agent') {
    c.messages.push({ role, content: text, ts: Date.now() });
    if (role === 'user' && (!c.title || c.title === '新对话')) {
      c.title = lhTitleFromText(text);
    }
    c.updatedAt = Date.now();
    // 把当前对话顶到列表前面
    localHistory.chats = [c, ...localHistory.chats.filter((x) => x.id !== c.id)];
    lhSave();
  }
}

function openLocalChat(id) {
  const c = localHistory.chats.find((x) => x.id === id);
  if (!c) return;
  localHistory.activeId = id;
  lhSave();
  lhEnsureSessionOption(id);
  closeGraphViewer();
  renderChatFromMessages(c.messages || []);
  restoreGraphsFromLocal(c.graphs || []);
  setStatus('就绪');
}

async function deleteLocalChat(id) {
  const wasActive = localHistory.activeId === id;
  localHistory.chats = localHistory.chats.filter((c) => c.id !== id);
  if (wasActive) {
    localHistory.activeId = null;
  }
  lhSave();
  try {
    await api('/api/clear', { method: 'POST', body: JSON.stringify({ sessionId: id }) });
  } catch { /* ignore */ }
  if (wasActive) {
    startNewLocalChat();
  }
}

function startNewLocalChat() {
  closeGraphViewer();
  hideApproveBar();
  const cur = lhGetActive();
  if (cur && !(cur.messages || []).length) {
    cur.graphs = [];
    chat.innerHTML = '';
    restoreGraphsFromLocal([]);
    setStatus('就绪');
    renderHistoryRail();
    return;
  }
  graphArtifacts.length = 0;
  activeGraphId = null;
  gvActiveId = null;
  const c = lhCreateChat({ activate: true });
  lhEnsureSessionOption(c.id);
  chat.innerHTML = '';
  restoreGraphsFromLocal([]);
  setStatus('就绪');
}

function initLocalHistory() {
  localHistory = lhLoad();
  localHistory.chats = lhPrune(localHistory.chats);
  // 刷新不自动展开正文：左侧仍有历史，主区开空白新对话
  const c = lhCreateChat({ activate: true });
  lhEnsureSessionOption(c.id);
  chat.innerHTML = '';
  restoreGraphsFromLocal([]);
  renderHistoryRail();
}

function clearGraphArtifactsUi() {
  graphArtifacts.length = 0;
  activeGraphId = null;
  if (typeof gvActiveId !== 'undefined') gvActiveId = null;
  const view = document.getElementById('graphView');
  if (view) {
    view.classList.add('muted');
    view.textContent = '暂无图表 — 调用 callGraph / moduleDeps / generateModuleDoc 后会出现在这里；点击列表在独立窗口打开';
  }
  renderGraphsList();
  if (typeof closeGraphViewer === 'function') closeGraphViewer();
  persistActiveLocalChat();
}

async function promptToken() {
  const cur = apiToken();
  const next = window.prompt('Web API Token（留空则清除）', cur || '');
  if (next === null) return;
  if (next.trim()) localStorage.setItem('alToken', next.trim());
  else localStorage.removeItem('alToken');
  appendMsg('system', next.trim() ? 'Token 已保存，正在重连 WebSocket...' : 'Token 已清除');
  WS.connect();
  setStatus('就绪');
}

function formatBytes(n) {
  if (n >= 1048576) return `${(n / 1048576).toFixed(1)} MB`;
  if (n >= 1024) return `${Math.round(n / 1024)} KB`;
  return `${n} B`;
}

function applyAttachLimits(limits) {
  if (!limits || typeof limits !== 'object') return;
  attachLimits = { ...attachLimits, ...limits };
  const exts = attachLimits.textFileExtensions || [];
  if (exts.length > 0) {
    const inner = exts.map((e) => String(e).replace(/^\./, '').replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|');
    attachLimits.textFileRe = new RegExp(`\\.(${inner})$`, 'i');
  }
  const docExts = attachLimits.documentFileExtensions || [];
  if (docExts.length > 0) {
    const inner = docExts.map((e) => String(e).replace(/^\./, '').replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|');
    attachLimits.documentFileRe = new RegExp(`\\.(${inner})$`, 'i');
  }
}

function isImageFile(file) {
  if (attachLimits.imageMimeTypes?.includes(file.type)) return true;
  return /\.(png|jpe?g|gif|webp)$/i.test(file.name);
}

function isDocumentFile(file) {
  if (attachLimits.documentMimeTypes?.includes(file.type)) return true;
  if (attachLimits.documentFileRe?.test(file.name)) return true;
  return /\.(pdf|docx?|xlsx?|xlsm|pptx?|epub)$/i.test(file.name);
}

function documentChipLabel(name) {
  const n = String(name || '');
  const m = n.match(/\.([a-z0-9]+)$/i);
  const ext = (m ? m[1] : 'DOC').toUpperCase();
  return `${ext} ${n}`.trim();
}

function isTextFile(file) {
  if (isImageFile(file) || isDocumentFile(file)) return false;
  if (file.type.startsWith('text/')) return true;
  if (file.type === 'application/json' || file.type === 'application/xml') return true;
  if (file.type === 'application/javascript') return true;
  if (file.type === 'image/svg+xml') return true;
  if (attachLimits.textFileRe?.test(file.name)) return true;
  return /\.(patch|diff|ipynb|svg)$/i.test(file.name);
}

function countAttachmentsByKind(kind) {
  return pendingAttachments.filter((a) => a.kind === kind).length;
}

applyWebConfig(readEmbeddedConfig());

const COPY_ICON = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v16c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 18H8V7h11v16z"/></svg>`;

function apiToken() {
  return localStorage.getItem('alToken') || '';
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

//==================================================================
// 结构化输出渲染
// 后端/模型常见格式：
//   1) ```lang ... ``` 标准围栏
//   2) ┌─ lang … └─  Unicode 语言伪围栏（lang 仅为标识，开闭行单独成行）
//   3) ┌─ 正文… … └─ 正文…  盒线内容框（开闭行带说明，须整段同框）
//   4) | a | b | / │ a │ b │ 表格
//   5) 裸 JSON / YAML；顶层目录树/调用链
//==================================================================

function hasStructuredContent(text) {
  if (!text) return false;
  const s = String(text);
  if (/(^|\n)\s*(```|~~~)/.test(s)) return true;
  if (/(^|\n)\s*┌─/.test(s)) return true;
  if (/(^|\n)\|.*\|\s*\n\|[\s\-:|]+\|/.test(s)) return true;
  if (/(^|\n)\s*│[^│\n]+│/.test(s) && /[├┼]/.test(s)) return true;
  const lines = s.split('\n');
  for (let i = 0; i < Math.min(lines.length, 400); i += 1) {
    if (tryConsumeBareJson(lines, i)) return true;
    if (tryConsumeBareYaml(lines, i)) return true;
    if (tryConsumeAsciiDiagram(lines, i)) return true;
  }
  return false;
}

function renderStructuredContent(text) {
  const frag = document.createDocumentFragment();
  if (!text) return frag;
  const blocks = parseStructuredBlocks(String(text));
  blocks.forEach((b) => frag.appendChild(renderBlock(b)));
  return frag;
}

/** 是否为「仅语言标签」的伪围栏开行：┌─ text / ┌─ erlang */
function isUnicodeLangFenceOpen(line) {
  return /^\s*┌─\s*[A-Za-z0-9_+]*\s*$/.test(line);
}
/** 是否为伪围栏闭行：仅 └─ */
function isUnicodeLangFenceClose(line) {
  return /^\s*└─\s*$/.test(line);
}

function parseStructuredBlocks(text) {
  const blocks = [];
  const lines = text.split('\n');
  let i = 0;
  let textBuf = [];

  const flushText = () => {
    if (textBuf.length > 0) {
      const t = textBuf.join('\n');
      textBuf = [];
      if (t.trim()) {
        expandPlainEmbedBlocks(t).forEach((b) => blocks.push(b));
      }
    }
  };

  while (i < lines.length) {
    const line = lines[i];

    // 1) 标准围栏 ``` / ~~~
    const fence = line.match(/^\s*(```|~~~)(.*)$/);
    if (fence) {
      flushText();
      const lang = fence[2].trim();
      const body = [];
      i += 1;
      while (i < lines.length && !/^\s*(```|~~~)\s*$/.test(lines[i])) {
        body.push(lines[i]);
        i += 1;
      }
      if (i < lines.length) i += 1;
      pushCodeOrMermaid(blocks, lang, body.join('\n'));
      continue;
    }

    // 2) Unicode 语言伪围栏：┌─ lang  …  └─
    //    开闭行只做标记，不进入展示；内层盒线正文原样保留在同一子框
    if (isUnicodeLangFenceOpen(line)) {
      flushText();
      const lang = (line.match(/^\s*┌─\s*([A-Za-z0-9_+]*)\s*$/) || [])[1] || 'text';
      const body = [];
      i += 1;
      while (i < lines.length && body.length < 400) {
        if (isUnicodeLangFenceClose(lines[i])) {
          i += 1;
          break;
        }
        // 仅当又出现「下一个语言伪围栏」才中止（防止未闭合吞全文）
        if (isUnicodeLangFenceOpen(lines[i]) && body.length > 0) break;
        body.push(lines[i]);
        i += 1;
      }
      pushCodeOrMermaid(blocks, lang, normalizeCodeDisplay(body));
      continue;
    }

    // 3) 盒线内容框：┌─ 接收盟仍在…  …  └─ 接收盟已解散…
    //    用开闭/左边线识别整段，展示时去掉 ┌─ └─ │ 标记，保留标题与树形正文
    if (/^\s*┌─/.test(line)) {
      flushText();
      const raw = [line];
      i += 1;
      while (i < lines.length && raw.length < 160) {
        const L = lines[i];
        raw.push(L);
        i += 1;
        if (/^\s*└─/.test(L)) break;
        if (isUnicodeLangFenceOpen(L)) {
          raw.pop();
          i -= 1;
          break;
        }
      }
      const display = stripBoxFrameMarkers(raw);
      blocks.push({ type: 'code', lang: 'ascii', code: display.join('\n') });
      continue;
    }

    // 4) 标准 Markdown 表
    if (isMdTableHeaderLine(line) && i + 1 < lines.length && isMdTableSepLine(lines[i + 1])) {
      flushText();
      const header = splitPipeTableRow(line);
      i += 2;
      const rows = [];
      while (i < lines.length && isMdTableDataLine(lines[i])) {
        rows.push(splitPipeTableRow(lines[i]));
        i += 1;
      }
      blocks.push({ type: 'table', header, rows });
      continue;
    }

    // 5) 盒线表：│ a │ b │ + ├─…┼…
    if (isBoxTableHeaderLine(line) && i + 1 < lines.length && isBoxTableSepLine(lines[i + 1])) {
      flushText();
      const header = splitBoxTableRow(line);
      i += 2;
      const rows = [];
      while (i < lines.length && isBoxTableDataLine(lines[i])) {
        rows.push(splitBoxTableRow(lines[i]));
        i += 1;
      }
      blocks.push({ type: 'table', header, rows });
      continue;
    }

    textBuf.push(line);
    i += 1;
  }
  flushText();
  return blocks;
}

function pushCodeOrMermaid(blocks, lang, code) {
  if (String(lang || '').toLowerCase() === 'mermaid') {
    blocks.push({ type: 'mermaid', code });
  } else {
    blocks.push({ type: 'code', lang: lang || 'text', code });
  }
}

/**
 * 去掉行首盒线左边线 │ / ┃（仅格式标记，不是正文）。
 */
function stripLeadingBoxMarker(line) {
  return String(line || '').replace(/^(\s*)[│┃]\s?/, '$1');
}

/** 去掉行首内层盒线标记 ┌─ / └─（正文跟在后面的情况） */
function stripInnerBoxMarkers(line) {
  let s = stripLeadingBoxMarker(line);
  if (/^\s*┌─/.test(s)) s = s.replace(/^\s*┌─\s*/, '');
  else if (/^\s*└─/.test(s)) s = s.replace(/^\s*└─\s*/, '');
  return s;
}

/** 代码/流程子框展示：去公共缩进 + 去掉 │ ┌─ └─ 等格式符 */
function normalizeCodeDisplay(rawLines) {
  return stripFenceBodyIndent(rawLines).map(stripInnerBoxMarkers).join('\n');
}

/** 对已拼接文本再做一遍（兜底） */
function normalizeDisplayMarkers(text) {
  return String(text || '').split('\n').map(stripInnerBoxMarkers).join('\n');
}

function isMdNoteLine(line) {
  const t = stripLeadingBoxMarker(line).trim();
  return /^注[：:]/.test(t) || /^⚠/.test(t);
}

/** 去掉伪围栏正文的公共缩进，保留相对对齐 */
function stripFenceBodyIndent(bodyLines) {
  const lines = bodyLines.slice();
  while (lines.length && /^\s*$/.test(lines[0])) lines.shift();
  while (lines.length && /^\s*$/.test(lines[lines.length - 1])) lines.pop();
  let min = Infinity;
  for (const L of lines) {
    if (/^\s*$/.test(L)) continue;
    const m = L.match(/^[ \t]*/);
    min = Math.min(min, m ? m[0].length : 0);
  }
  if (!Number.isFinite(min) || min <= 0) return lines;
  return lines.map((L) => (/^\s*$/.test(L) ? '' : L.slice(min)));
}

/**
 * 盒线内容框展示：去掉格式标记，保留语义文字与内层树。
 *  ┌─ 标题      → 标题
 *  │   ├─ a     →   ├─ a
 *  └─ 结尾说明  → 结尾说明
 */
function stripBoxFrameMarkers(rawLines) {
  const out = rawLines.map((line, idx, arr) => {
    const isFirst = idx === 0;
    const isLast = idx === arr.length - 1;
    let s = line;
    if (isFirst) s = s.replace(/^\s*┌─\s*/, '');
    else if (isLast && /^\s*└─/.test(s)) s = s.replace(/^\s*└─\s*/, '');
    return stripLeadingBoxMarker(s);
  });
  return stripFenceBodyIndent(out);
}

function isMdTableHeaderLine(line) {
  return /^\s*\|.*\|\s*$/.test(line) && (line.match(/\|/g) || []).length >= 2;
}
function isMdTableSepLine(line) {
  return /^\s*\|[\s\-:|]+\|\s*$/.test(line);
}
function isMdTableDataLine(line) {
  return isMdTableHeaderLine(line) && !isMdTableSepLine(line);
}
function splitPipeTableRow(line) {
  const trimmed = line.trim().replace(/^\|/, '').replace(/\|$/, '');
  return trimmed.split('|').map((c) => c.trim());
}

function isBoxTableHeaderLine(line) {
  if (!/^\s*│/.test(line)) return false;
  const cells = splitBoxTableRow(line);
  return cells.length >= 2;
}
function isBoxTableSepLine(line) {
  // ├─────┼────┤ 或含大量 ─/┼ 的分隔行
  if (!/^\s*[├┣]/.test(line)) return false;
  if (!/[┼┬]/.test(line) && !/─{3,}/.test(line)) return false;
  // 分隔行不应有太多「正文」汉字/字母
  const solid = line.replace(/[\s├┣┤┫┼┬┴─━═|\-+]/g, '');
  return solid.length <= 2;
}
function isBoxTableDataLine(line) {
  if (!/^\s*│/.test(line)) return false;
  if (isBoxTableSepLine(line)) return false;
  return splitBoxTableRow(line).length >= 2;
}
function splitBoxTableRow(line) {
  let s = String(line || '').trim();
  s = s.replace(/^[│|]/, '').replace(/[│|┤┫]\s*$/, '');
  return s.split(/[│|]/).map((c) => c.trim());
}

/** 在普通段落中再拆出：裸 JSON / YAML / 真正的调用链树（不含伪围栏碎片） */
function expandPlainEmbedBlocks(text) {
  const lines = String(text || '').split('\n');
  const out = [];
  let i = 0;
  let prose = [];
  const flushProse = () => {
    if (!prose.length) return;
    out.push({ type: 'text', text: prose.join('\n') });
    prose = [];
  };
  while (i < lines.length) {
    const json = tryConsumeBareJson(lines, i);
    if (json) {
      flushProse();
      out.push({ type: 'code', lang: 'json', code: json.text });
      i = json.next;
      continue;
    }
    const yaml = tryConsumeBareYaml(lines, i);
    if (yaml) {
      flushProse();
      out.push({ type: 'code', lang: 'yaml', code: yaml.text });
      i = yaml.next;
      continue;
    }
    const ascii = tryConsumeAsciiDiagram(lines, i);
    if (ascii) {
      flushProse();
      out.push({ type: 'code', lang: 'ascii', code: ascii.text });
      i = ascii.next;
      continue;
    }
    prose.push(lines[i]);
    i += 1;
  }
  flushProse();
  return out;
}

function tryConsumeBareJson(lines, start) {
  const first = lines[start];
  if (!first || !/^\s*[\{\[]/.test(first)) return null;
  if (start > 0) {
    const prev = lines[start - 1];
    if (prev && /[^\s]$/.test(prev) && !/[:：]$/.test(prev.trim())) return null;
  }
  let depth = 0;
  let inStr = false;
  let esc = false;
  const buf = [];
  for (let i = start; i < lines.length && buf.length < 220; i += 1) {
    const L = lines[i];
    for (let k = 0; k < L.length; k += 1) {
      const ch = L[k];
      if (inStr) {
        if (esc) esc = false;
        else if (ch === '\\') esc = true;
        else if (ch === '"') inStr = false;
        continue;
      }
      if (ch === '"') inStr = true;
      else if (ch === '{' || ch === '[') depth += 1;
      else if (ch === '}' || ch === ']') depth -= 1;
    }
    buf.push(L);
    if (depth === 0) {
      const text = buf.join('\n').trimEnd();
      try {
        JSON.parse(text.trim());
      } catch {
        return null;
      }
      if (buf.length < 2 && text.trim().length < 96) return null;
      return { text, next: i + 1 };
    }
    if (depth < 0) return null;
  }
  return null;
}

function isYamlishLine(line) {
  if (/^\s*$/.test(line)) return true;
  if (/^\s*#/.test(line)) return true;
  if (/^\s*-\s+\S/.test(line)) return true;
  if (/^\s*[A-Za-z_][\w.-]*:\s*(?:[|>].*)?$/.test(line)) return true;
  if (/^\s*[A-Za-z_][\w.-]*:\s+\S/.test(line)) return true;
  if (/^\s{2,}\S/.test(line)) return true;
  return false;
}

function tryConsumeBareYaml(lines, start) {
  const first = lines[start];
  if (!first || !/^\s*[A-Za-z_][\w.-]*:\s*(?:\S.*)?$/.test(first)) return null;
  if (/^\s*#{1,6}\s/.test(first) || /^\s*[-*]\s/.test(first)) return null;
  if (start + 1 >= lines.length) return null;
  const second = lines[start + 1];
  const secondOk = /^\s{2,}\S/.test(second)
    || /^\s*-\s+\S/.test(second)
    || /^\s*[A-Za-z_][\w.-]*:\s*/.test(second);
  if (!secondOk) return null;
  const buf = [first];
  let i = start + 1;
  while (i < lines.length && buf.length < 120) {
    const L = lines[i];
    if (/^\s*$/.test(L)) {
      if (i + 1 < lines.length && isYamlishLine(lines[i + 1]) && !/^\s*#{1,6}\s/.test(lines[i + 1])) {
        buf.push(L);
        i += 1;
        continue;
      }
      break;
    }
    if (!isYamlishLine(L) || /^\s*#{1,6}\s/.test(L)) break;
    buf.push(L);
    i += 1;
  }
  while (buf.length && /^\s*$/.test(buf[buf.length - 1])) buf.pop();
  if (buf.length < 3) return null;
  return { text: buf.join('\n'), next: start + buf.length };
}

/** 真目录树 / 箭头调用链；禁止从 │ 续行开框，避免掏空 ┌─…└─ 中间 */
function isAsciiTreeLine(line, loose) {
  if (line == null) return false;
  if (/^\s*[┌└]─/.test(line)) return false;
  if (isBoxTableHeaderLine(line) || isBoxTableSepLine(line) || isBoxTableDataLine(line)) return false;
  if (/^\s*[├└]─/.test(line)) return true;
  if (/^\s*(?:↓|↑|⬇|⬆|→|⟶|->|=>)\s*/.test(line)) return true;
  if (loose && /^\s*[│┃]/.test(line)) return true;
  if (loose && /^\s{2,}[a-zA-Z_][\w]*:/.test(line)) return true;
  if (loose && /^\s*[a-zA-Z_][\w]*:[a-zA-Z_][\w]*(?:\/\d+)?\s*(?:\([^)]*\))?\s*$/.test(line)) return true;
  return false;
}

function tryConsumeAsciiDiagram(lines, start) {
  const first = lines[start];
  // 绝不从盒线续行/开闭行起块
  if (/^\s*[│┃]/.test(first)) return null;
  if (/^\s*[┌└]─/.test(first)) return null;
  if (!/^\s*[├└]─/.test(first)
    && !/^\s*(?:↓|↑|⬇|⬆|→|⟶|->|=>)/.test(first)
    && !/^\s*[a-zA-Z_][\w]*:[a-zA-Z_][\w]*/.test(first)) {
    return null;
  }
  const buf = [];
  let i = start;
  while (i < lines.length && buf.length < 100) {
    const L = lines[i];
    if (/^\s*$/.test(L)) {
      if (i + 1 < lines.length && isAsciiTreeLine(lines[i + 1], true)) {
        buf.push(L);
        i += 1;
        continue;
      }
      break;
    }
    if (/^\s*[┌└]─/.test(L) || isBoxTableHeaderLine(L) || isBoxTableSepLine(L)) break;
    if (!isAsciiTreeLine(L, true)) break;
    buf.push(L);
    i += 1;
  }
  while (buf.length && /^\s*$/.test(buf[buf.length - 1])) buf.pop();
  if (buf.length < 3) return null;
  const joined = buf.join('\n');
  const strong = /^\s*[├└]─/m.test(joined)
    || (/\b[a-zA-Z_][\w]*:[a-zA-Z_][\w]*/.test(joined) && /(?:↓|→|->|=>|\n\s{2,})/.test(joined));
  if (!strong) return null;
  return { text: joined, next: start + buf.length };
}

// 渲染单个块为 DOM 元素。
function renderBlock(b) {
  if (b.type === 'mermaid') return renderMermaidBlock(b.code);
  if (b.type === 'code') return renderCodeBlock(b.lang, b.code);
  if (b.type === 'table') return renderTableBlock(b.header, b.rows);
  return renderMarkdownTextBlock(b.text);
}

/** 轻量 Markdown：标题 / 列表 / 行内代码 / 加粗 / 链接（无外部依赖） */
function renderMarkdownTextBlock(text) {
  const div = document.createElement('div');
  div.className = 'struct-text md-prose';
  div.innerHTML = formatMarkdownLite(text);
  return div;
}

function formatMarkdownLite(text) {
  const lines = String(text || '').split('\n');
  const html = [];
  let inList = false;
  const flushList = () => {
    if (inList) {
      html.push('</ul>');
      inList = false;
    }
  };
  for (const line of lines) {
    const cleaned = stripLeadingBoxMarker(line);
    const h = cleaned.match(/^(#{1,4})\s+(.+)$/);
    if (h) {
      flushList();
      const level = h[1].length;
      html.push(`<h${level} class="md-h">${inlineMarkdownLite(h[2])}</h${level}>`);
      continue;
    }
    const li = cleaned.match(/^[-*]\s+(.+)$/);
    if (li) {
      if (!inList) {
        html.push('<ul class="md-ul">');
        inList = true;
      }
      html.push(`<li>${inlineMarkdownLite(li[1])}</li>`);
      continue;
    }
    flushList();
    if (cleaned.trim() === '') html.push('<div class="md-blank"></div>');
    else if (isMdNoteLine(cleaned)) {
      html.push(`<div class="md-note">${inlineMarkdownLite(cleaned.trim())}</div>`);
    } else html.push(`<div class="md-p">${inlineMarkdownLite(cleaned)}</div>`);
  }
  flushList();
  return html.join('');
}

function inlineMarkdownLite(s) {
  const src = String(s || '');
  let out = '';
  const re = /(`+)([^`]+?)\1|\*\*([^*]+)\*\*|__([^_]+)__|\[([^\]]+)\]\(([^)\s]+)\)/g;
  let last = 0;
  let m;
  while ((m = re.exec(src)) !== null) {
    out += escapeHtml(src.slice(last, m.index));
    if (m[2] != null) out += `<code class="md-inline-code">${escapeHtml(m[2])}</code>`;
    else if (m[3] != null) out += `<strong>${escapeHtml(m[3])}</strong>`;
    else if (m[4] != null) out += `<strong>${escapeHtml(m[4])}</strong>`;
    else if (m[5] != null) {
      const href = String(m[6] || '');
      const safe = /^(https?:|mailto:|\/|\.\/|#)/i.test(href) ? href : '#';
      out += `<a class="md-link" href="${escapeHtml(safe)}" target="_blank" rel="noopener noreferrer">${escapeHtml(m[5])}</a>`;
    }
    last = m.index + m[0].length;
  }
  out += escapeHtml(src.slice(last));
  return out;
}

// 渲染 Mermaid 块：创建容器，异步调用 mermaid API 渲染。
function renderMermaidBlock(code) {
  const wrap = document.createElement('div');
  wrap.className = 'mermaid-wrap';
  const placeholder = document.createElement('div');
  placeholder.className = 'mermaid-placeholder';
  placeholder.textContent = '正在渲染图表...';
  wrap.appendChild(placeholder);
  if (window.mermaid) {
    const id = `mmd-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    try {
      window.mermaid.render(id, code).then(({ svg }) => {
        wrap.innerHTML = svg;
        wrap.classList.add('rendered');
      }).catch((err) => {
        placeholder.textContent = `图表渲染失败: ${err.message || err}`;
        placeholder.classList.add('mermaid-error');
        // 同时显示原始代码便于排查
        const pre = document.createElement('pre');
        pre.className = 'mermaid-source';
        pre.textContent = code;
        wrap.appendChild(pre);
      });
    } catch (err) {
      placeholder.textContent = `图表渲染异常: ${err.message || err}`;
      placeholder.classList.add('mermaid-error');
    }
  } else {
    placeholder.textContent = 'Mermaid 库未加载，显示源码：';
    const pre = document.createElement('pre');
    pre.className = 'mermaid-source';
    pre.textContent = code;
    wrap.appendChild(pre);
  }
  return wrap;
}

// 渲染围栏代码块：带语言标签、语法着色与复制按钮。
function fenceLangToPath(lang) {
  const l = String(lang || '').toLowerCase().trim();
  if (!l || l === 'text' || l === 'plain' || l === 'plaintext') return 'x.txt';
  const aliases = {
    erlang: 'x.erl', erl: 'x.erl',
    javascript: 'x.js', js: 'x.js',
    typescript: 'x.ts', ts: 'x.ts',
    markdown: 'x.md', md: 'x.md',
    shell: 'x.sh', bash: 'x.sh', sh: 'x.sh', zsh: 'x.sh',
    python: 'x.py', py: 'x.py',
    rust: 'x.rs', rs: 'x.rs',
    csharp: 'x.cs', cs: 'x.cs',
    'c++': 'x.cpp', cpp: 'x.cpp',
    c: 'x.c',
    golang: 'x.go', go: 'x.go',
    yaml: 'x.yaml', yml: 'x.yml',
    json: 'x.json',
    html: 'x.html', xml: 'x.xml', css: 'x.css',
    sql: 'x.sql', lua: 'x.lua', ruby: 'x.rb', php: 'x.php',
    toml: 'x.toml', conf: 'x.conf', ini: 'x.ini',
  };
  if (aliases[l]) return aliases[l];
  if (FV_LANG_BY_EXT[l]) return `x.${l}`;
  return `x.${l}`;
}

function renderCodeBlock(lang, code) {
  const displayCode = normalizeDisplayMarkers(code);
  const wrap = document.createElement('div');
  wrap.className = 'code-block';
  const header = document.createElement('div');
  header.className = 'code-header';
  const langSpan = document.createElement('span');
  langSpan.className = 'code-lang';
  const rawLang = String(lang || '').trim();
  const mapped = fenceLangName(rawLang);
  const isAscii = /^ascii$/i.test(rawLang);
  const detected = (!isAscii && (!mapped || mapped === 'text')) ? autoDetectFenceLang(displayCode) : mapped;
  let label;
  if (isAscii) label = 'ascii';
  else if (rawLang && !/^(code|src|source|text|plain|plaintext)$/i.test(rawLang)) label = rawLang;
  else label = detected !== 'text' ? detected : (rawLang || 'text');
  langSpan.textContent = label;
  header.appendChild(langSpan);
  const copyBtn = document.createElement('button');
  copyBtn.className = 'code-copy btn-muted btn-xs';
  copyBtn.type = 'button';
  copyBtn.textContent = '复制';
  copyBtn.addEventListener('click', () => {
    navigator.clipboard.writeText(displayCode).then(() => {
      copyBtn.textContent = '已复制';
      setTimeout(() => { copyBtn.textContent = '复制'; }, 1500);
    });
  });
  header.appendChild(copyBtn);
  wrap.appendChild(header);
  const pre = document.createElement('pre');
  pre.className = 'code-body';
  try {
    const html = highlightFenceCode(rawLang, displayCode);
    if (html) pre.innerHTML = html;
    else pre.textContent = displayCode;
  } catch {
    pre.textContent = displayCode;
  }
  wrap.appendChild(pre);
  return wrap;
}

/** 围栏语言 → 高亮规则名（不依赖 path 猜测，避免漏着色）。 */
function fenceLangName(lang) {
  const l = String(lang || '').toLowerCase().trim();
  if (!l || l === 'text' || l === 'plain' || l === 'plaintext' || l === 'code'
    || l === 'src' || l === 'source' || l === 'ascii' || l === 'diagram') {
    return 'text';
  }
  const map = {
    erlang: 'erlang', erl: 'erlang',
    javascript: 'js', js: 'js', jsx: 'js',
    typescript: 'ts', ts: 'ts', tsx: 'ts',
    markdown: 'md', md: 'md',
    shell: 'shell', bash: 'shell', sh: 'shell', zsh: 'shell',
    python: 'python', py: 'python',
    rust: 'rust', rs: 'rust',
    go: 'go', golang: 'go',
    json: 'json', html: 'html', xml: 'xml', css: 'css',
    yaml: 'yaml', yml: 'yaml', toml: 'toml', sql: 'sql',
    c: 'c', cpp: 'cpp', 'c++': 'cpp', java: 'java',
    ruby: 'ruby', rb: 'ruby', php: 'php', lua: 'lua',
    conf: 'conf', ini: 'conf',
  };
  if (map[l]) return map[l];
  // 扩展名直通
  if (typeof FV_LANG_BY_EXT !== 'undefined' && FV_LANG_BY_EXT[l]) return FV_LANG_BY_EXT[l];
  return 'text';
}

/** 无语言标签 / ```code 时按内容猜测，便于答案区着色。 */
function autoDetectFenceLang(code) {
  const s = String(code || '');
  const head = s.slice(0, 1200);
  if (/\b(?:-module|-export|-record|andalso|orelse)\b/.test(head)
    || /\b[a-z][\w]*:[a-z][\w]*\/\d+\b/.test(head)
    || /\b(?:fun\s*\(|receive\b|gen_server)\b/.test(head)) {
    return 'erlang';
  }
  if (/^\s*[\[{]/.test(s.trim())) {
    try {
      JSON.parse(s.trim());
      return 'json';
    } catch { /* ignore */ }
  }
  if (/^(?:#!\/|\$\s)/m.test(head) || /\b(?:npm|npx|curl|git|rebar3|erl)\s/.test(head)) return 'shell';
  if (/^\s*(?:SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER|DROP)\b/im.test(head)) return 'sql';
  if (/^(?:def |class |import |from \w+ import )/m.test(head)) return 'python';
  if (/^(?:fn |let |use |mod |pub )/m.test(head) || /\bfn\s+main\b/.test(head)) return 'rust';
  if (/^(?:function |const |let |import |export )/m.test(head)) return 'js';
  if (/^#{1,3}\s|\[[^\]]+\]\([^)]+\)/.test(head)) return 'md';
  return 'text';
}

function highlightFenceCode(lang, code) {
  const text = String(code ?? '');
  if (!text) return '';
  const raw = String(lang || '').trim().toLowerCase();
  // ASCII/调用链：用通用规则上色（路径 / MFA / 字符串），但仍保持等宽
  if (raw === 'ascii' || raw === 'diagram') {
    return highlightWithRules(text, fileViewerHighlightRules('generic'));
  }
  let hlLang = fenceLangName(lang);
  if (hlLang === 'text') hlLang = autoDetectFenceLang(text);
  // 仍无法识别语言时，走通用着色，避免答案区代码块一片灰
  if (hlLang === 'text') {
    return highlightWithRules(text, fileViewerHighlightRules('generic'));
  }
  if (typeof fileViewerHighlightRules !== 'function' || typeof highlightWithRules !== 'function') {
    return highlightFileViewerText(text, fenceLangToPath(hlLang === 'erlang' ? 'erl' : hlLang));
  }
  const rules = fileViewerHighlightRules(hlLang);
  if (!rules.length) {
    return highlightWithRules(text, fileViewerHighlightRules('generic'));
  }
  if (typeof FV_HIGHLIGHT_MAX === 'number' && text.length > FV_HIGHLIGHT_MAX) {
    const head = text.slice(0, FV_HIGHLIGHT_MAX);
    const rest = text.slice(FV_HIGHLIGHT_MAX);
    return `${highlightWithRules(head, rules)}${escapeHtml(rest)}`;
  }
  return highlightWithRules(text, rules);
}

// 渲染 Markdown 表格为 HTML table。
function renderTableBlock(header, rows) {
  const wrap = document.createElement('div');
  wrap.className = 'table-wrap';
  const table = document.createElement('table');
  table.className = 'md-table';
  const thead = document.createElement('thead');
  const headRow = document.createElement('tr');
  const colCount = Math.max(header.length, ...rows.map((r) => r.length), 0);
  // 最后一列（多为「说明」）允许换行，其余 nowrap 保对齐
  const wrapIdx = colCount > 2 ? colCount - 1 : -1;
  header.forEach((h, i) => {
    const th = document.createElement('th');
    th.textContent = h;
    if (i === wrapIdx) th.className = 'md-cell-wrap';
    headRow.appendChild(th);
  });
  thead.appendChild(headRow);
  table.appendChild(thead);
  const tbody = document.createElement('tbody');
  rows.forEach((r) => {
    const tr = document.createElement('tr');
    for (let i = 0; i < Math.max(r.length, header.length); i += 1) {
      const td = document.createElement('td');
      td.textContent = r[i] ?? '';
      if (i === wrapIdx) td.className = 'md-cell-wrap';
      tr.appendChild(td);
    }
    tbody.appendChild(tr);
  });
  table.appendChild(tbody);
  wrap.appendChild(table);
  return wrap;
}

// 流式完成后，将 msg-body 的纯文本替换为结构化渲染结果。
// grounding 页脚拆成独立提示条，避免看起来像回答被突然截断。
function splitGroundingFooter(text) {
  const s = String(text || '');
  const marker = '\n\n[grounding]';
  const idx = s.indexOf(marker);
  if (idx < 0) return { body: s, warning: '' };
  return { body: s.slice(0, idx), warning: s.slice(idx + marker.length).replace(/^\n+/, '').trim() };
}

function applyAgentBody(msgBody, text) {
  if (!msgBody || text == null) return;
  const { body, warning } = splitGroundingFooter(text);
  msgBody.dataset.rawText = String(text);
  while (msgBody.firstChild) msgBody.removeChild(msgBody.firstChild);
  // 始终走结构化渲染：表格/代码块/轻量 Markdown（标题、行内代码着色）
  if (body) {
    msgBody.appendChild(renderStructuredContent(body));
  }
  if (warning) {
    const box = document.createElement('div');
    box.className = 'grounding-warn';
    box.setAttribute('role', 'note');
    box.textContent = warning.startsWith('[grounding]')
      ? warning.replace(/^\[grounding\]\s*/, '')
      : warning;
    msgBody.appendChild(box);
  }
}

function finalizeStructuredMessage(msgBody, text) {
  if (!msgBody || !text) return;
  applyAgentBody(msgBody, text);
}

//==================================================================
// WebSocket 客户端（控制面 + 流式问答），失败时回退 REST/SSE
//
// 设计要点：
//  - `send()` 在发送前检查 sock.readyState；非 OPEN 状态会触发一次重连，
//    并把消息暂存到 pendingQueue，待 onopen 后回放，避免用户操作丢失。
//  - `ensureConnected()` 给上层提供一个 async 等待：若已断开则启动一次
//    重连并在超时内等待 OPEN，成功后继续后续操作。
//  - `reconnect()` 在前 6 次按指数退避快速重试；超过 6 次后切换为每 15s
//    一次的低频心跳重连，直到用户再次操作触发主动重连。
//==================================================================
const WS = {
  sock: null,
  connected: false,
  streamHandler: null,
  resolvers: {},
  retry: 0,
  reconnecting: false,
  pendingQueue: [],
  maxPending: 50,
  reconnectTimer: null,
  lastPongAt: Date.now(),

  url() {
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    // 浏览器 WebSocket 无法自定义 Authorization 头；仅能 query（loopback 通常无 token）。
    const token = apiToken();
    const q = token ? `?token=${encodeURIComponent(token)}` : '';
    return `${proto}//${location.host}/ws${q}`;
  },

  connect() {
    // 关闭旧 socket（避免 onclose 重复触发）
    if (this.sock) {
      try { this.sock.onclose = null; this.sock.close(); } catch { /* ignore */ }
      this.sock = null;
    }
    try {
      const sock = new WebSocket(this.url());
      this.sock = sock;
      sock.onopen = () => {
        this.connected = true;
        this.reconnecting = false;
        this.retry = 0;
        this.lastPongAt = Date.now();
        setConn(true);
        // 重连成功后回放暂存的消息，避免用户操作丢失
        if (this.pendingQueue.length > 0) {
          const q = this.pendingQueue;
          this.pendingQueue = [];
          for (const obj of q) {
            try { sock.send(JSON.stringify(obj)); } catch { /* ignore */ }
          }
        }
        syncLlmToServer();
        loadStatus();
      };
      sock.onclose = () => {
        this.connected = false;
        setConn(false);
        this.reconnect();
      };
      sock.onerror = () => {
        this.connected = false;
        setConn(false);
      };
      sock.onmessage = (e) => this.onMessage(e);
    } catch {
      this.connected = false;
      setConn(false);
      this.reconnect();
    }
  },

  reconnect() {
    if (this.reconnectTimer) { clearTimeout(this.reconnectTimer); this.reconnectTimer = null; }
    if (this.retry > 6) {
      // 进入低频重连：每 15s 一次，直到用户主动操作触发 ensureConnected
      this.reconnectTimer = setTimeout(() => {
        this.retry = 0;
        this.connect();
      }, 15000);
      return;
    }
    this.retry += 1;
    const delay = Math.min(1000 * this.retry, 5000);
    this.reconnectTimer = setTimeout(() => this.connect(), delay);
  },

  // 给上层使用的 async 等待：若已断开则发起重连并在超时内等待 OPEN。
  // 成功返回 true；超时或不可重连返回 false。
  ensureConnected(timeoutMs = 3000) {
    return new Promise((resolve) => {
      if (this.sock && this.sock.readyState === WebSocket.OPEN) {
        resolve(true);
        return;
      }
      // 还未发起重连则立刻发起一次
      if (!this.reconnecting && (this.retry === 0 || this.retry > 6)) {
        this.retry = 0;
        this.connect();
      }
      const start = Date.now();
      const tick = () => {
        if (this.sock && this.sock.readyState === WebSocket.OPEN) {
          resolve(true);
          return;
        }
        if (Date.now() - start >= timeoutMs) {
          resolve(false);
          return;
        }
        setTimeout(tick, 100);
      };
      tick();
    });
  },

  enqueuePending(obj) {
    if (this.pendingQueue.length >= this.maxPending) this.pendingQueue.shift();
    this.pendingQueue.push(obj);
  },

  // 发送前检查 readyState；非 OPEN 状态会触发重连并把消息暂存到队列。
  // 返回 true 表示已发出或已暂存；false 表示完全不可重试（如 sock 为 null 且重连被禁用）。
  send(obj) {
    if (!this.sock) {
      // sock 未创建：尝试连接一次，并把消息入队等 onopen 回放
      this.enqueuePending(obj);
      this.connect();
      return true;
    }
    switch (this.sock.readyState) {
      case WebSocket.OPEN:
        this.sock.send(JSON.stringify(obj));
        return true;
      case WebSocket.CONNECTING:
        // 正在握手，暂存到 onopen 回放
        this.enqueuePending(obj);
        return true;
      case WebSocket.CLOSING:
      case WebSocket.CLOSED:
      default:
        // 已断开：触发重连 + 暂存
        this.enqueuePending(obj);
        this.connected = false;
        setConn(false);
        if (!this.reconnectTimer) this.reconnect();
        return true;
    }
  },

  request(type, extra = {}, timeoutMs = 30000) {
    return new Promise((resolve, reject) => {
      (this.resolvers[type] = this.resolvers[type] || []).push(resolve);
      const t = setTimeout(() => reject(new Error('ws timeout')), timeoutMs);
      const q = this.resolvers[type];
      const orig = q[q.length - 1];
      q[q.length - 1] = (m) => { clearTimeout(t); orig(m); };
      // send 会处理 readyState 与重连/暂存；不在此处直接判 connected
      try { this.send({ type, ...extra }); }
      catch (err) { clearTimeout(t); reject(err); }
    });
  },

  onMessage(e) {
    let m;
    try { m = JSON.parse(e.data); } catch { return; }
    // 心跳 pong：刷新最近响应时间
    if (m.type === 'pong') { this.lastPongAt = Date.now(); return; }
    if (m.type === 'setLlm') {
      handleSetLlmAck(m);
      const q = this.resolvers.setLlm;
      if (q && q.length) q.shift()(m);
      return;
    }
    if (['token', 'progress', 'done', 'ack', 'answer', 'error', 'approve', 'resume'].includes(m.type)) {
      if (this.streamHandler) {
        this.streamHandler(m);
        return;
      }
      // No stream handler: ignore stream-only frames; allow approve/resume to fall through to resolvers.
      if (m.type !== 'approve' && m.type !== 'resume') return;
    }
    const q = this.resolvers[m.type];
    if (q && q.length) { q.shift()(m); }
  },
};

function setConn(ok) {
  if (!connDot) return;
  connDot.classList.toggle('online', ok);
  connDot.title = ok ? 'WebSocket 已连接' : '未连接（正在重连…）';
}

// 控制命令：先尝试 WS（必要时自动重连），失败回退 REST。
async function ctrl(type, extra, restPath, restOpts) {
  if (WS.sock && WS.sock.readyState === WebSocket.OPEN) {
    try { return await WS.request(type, extra || {}); }
    catch { /* fall through to REST */ }
  }
  // 主动等待一次轻量重连（最多 2s），减少 REST 回退概率
  const ok = await WS.ensureConnected(2000);
  if (ok) {
    try { return await WS.request(type, extra || {}); }
    catch { /* fall through to REST */ }
  }
  return api(restPath, restOpts || {});
}

//==================================================================
// 复制 / 滚动 / 消息渲染
//==================================================================
async function copyText(text, btn) {
  const value = text || '';
  if (!value.trim()) return;
  try {
    await navigator.clipboard.writeText(value);
  } catch {
    const ta = document.createElement('textarea');
    ta.value = value;
    ta.style.position = 'fixed';
    ta.style.left = '-9999px';
    document.body.appendChild(ta);
    ta.select();
    document.execCommand('copy');
    document.body.removeChild(ta);
  }
  if (btn) {
    btn.classList.add('copied');
    btn.title = '已复制';
    setTimeout(() => { btn.classList.remove('copied'); btn.title = '复制'; }, 1500);
  }
}

function ensureMsgActions(wrap) {
  let actions = wrap.querySelector('.msg-actions');
  if (!actions) {
    actions = document.createElement('div');
    actions.className = 'msg-actions';
    wrap.appendChild(actions);
  }
  return actions;
}

function attachCopyButton(wrap, body) {
  const actions = ensureMsgActions(wrap);
  if (actions.querySelector('.msg-copy')) return actions.querySelector('.msg-copy');
  const btn = document.createElement('button');
  btn.type = 'button';
  btn.className = 'msg-copy';
  btn.title = '复制';
  btn.setAttribute('aria-label', '复制回答');
  btn.innerHTML = COPY_ICON;
  btn.addEventListener('click', (e) => {
    e.stopPropagation();
    // 优先复制结构化渲染前的原始文本，避免把代码块/表格拼成一行
    const raw = body.dataset && body.dataset.rawText;
    copyText(raw != null ? raw : body.textContent, btn);
  });
  actions.appendChild(btn);
  return btn;
}

function isThinkingViewerOpen() {
  return !!(thinkingViewer && !thinkingViewer.classList.contains('hidden'));
}

function syncThinkingButtonState() {
  document.querySelectorAll('.msg-thinking-btn.is-open').forEach((b) => {
    b.classList.remove('is-open');
    b.title = '查看完整思考过程';
    b.setAttribute('aria-pressed', 'false');
  });
  if (!isThinkingViewerOpen() || !thinkingViewerSourceEl) return;
  document.querySelectorAll('.msg.agent').forEach((w) => {
    if (w._thinkingEl !== thinkingViewerSourceEl) return;
    const btn = w.querySelector('.msg-thinking-btn');
    if (!btn) return;
    btn.classList.add('is-open');
    btn.title = '关闭思考过程';
    btn.setAttribute('aria-pressed', 'true');
  });
}

function attachThinkingButton(wrap, thinkingEl) {
  if (!wrap || !thinkingEl) return null;
  const actions = ensureMsgActions(wrap);
  let btn = actions.querySelector('.msg-thinking-btn');
  if (!btn) {
    btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'msg-thinking-btn';
    btn.title = '查看完整思考过程';
    btn.setAttribute('aria-label', '思考过程');
    btn.setAttribute('aria-pressed', 'false');
    btn.textContent = '思考过程';
    // 插到复制按钮左边
    const copyBtn = actions.querySelector('.msg-copy');
    if (copyBtn) actions.insertBefore(btn, copyBtn);
    else actions.appendChild(btn);
  }
  btn.onclick = (e) => {
    e.stopPropagation();
    toggleThinkingViewer(thinkingEl);
  };
  wrap._thinkingEl = thinkingEl;
  return btn;
}

function linkThinkingToAnswer(thinkingEl) {
  if (!thinkingEl) return;
  const agentWrap = (activeAsk && activeAsk.msgWrap)
    || (thinkingEl.nextElementSibling && thinkingEl.nextElementSibling.classList.contains('agent')
      ? thinkingEl.nextElementSibling
      : null);
  if (agentWrap) {
    attachThinkingButton(agentWrap, thinkingEl);
    pendingThinkingEl = null;
  } else {
    pendingThinkingEl = thinkingEl;
  }
  const title = thinkingEl.querySelector('.thinking-title');
  if (title && !title.dataset.tvBound) {
    title.dataset.tvBound = '1';
    title.title = '点击打开/关闭思考过程';
    title.addEventListener('click', (e) => {
      e.stopPropagation();
      toggleThinkingViewer(thinkingEl);
    });
  }
}

function toggleThinkingViewer(sourceEl) {
  if (!sourceEl) return;
  if (isThinkingViewerOpen() && thinkingViewerSourceEl === sourceEl) {
    closeThinkingViewer();
    return;
  }
  openThinkingViewer(sourceEl);
}

let scrollRaf = null;
let stickToBottom = true;

function isNearBottom(el, threshold = 100) {
  return el.scrollHeight - el.scrollTop - el.clientHeight <= threshold;
}

chat.addEventListener('scroll', () => { stickToBottom = isNearBottom(chat); }, { passive: true });

/** 平时滚动条全透明；划过右侧滚动条带显出（答案框同色）；按下拖动才略高亮。 */
(function bindChatScrollbarHotzone() {
  if (!chat) return;
  const EDGE = 12;
  let dragging = false;
  let lastX = 0;
  const nearEdge = (clientX) => {
    const rect = chat.getBoundingClientRect();
    return rect.right - clientX <= EDGE;
  };
  const sync = (clientX) => {
    lastX = clientX;
    chat.classList.toggle('scrollbar-hot', dragging || nearEdge(clientX));
    chat.classList.toggle('scrollbar-active', dragging);
  };
  chat.addEventListener('mousemove', (e) => sync(e.clientX), { passive: true });
  chat.addEventListener('mouseleave', () => {
    if (!dragging) {
      chat.classList.remove('scrollbar-hot', 'scrollbar-active');
    }
  }, { passive: true });
  chat.addEventListener('mousedown', (e) => {
    if (nearEdge(e.clientX)) {
      dragging = true;
      chat.classList.add('scrollbar-hot', 'scrollbar-active');
    }
  }, { passive: true });
  window.addEventListener('mouseup', () => {
    dragging = false;
    chat.classList.remove('scrollbar-active');
    chat.classList.toggle('scrollbar-hot', nearEdge(lastX));
  }, { passive: true });
})();

function scrollChatToBottom(force = false) {
  if (!force && !stickToBottom) return;
  if (scrollRaf) cancelAnimationFrame(scrollRaf);
  scrollRaf = requestAnimationFrame(() => {
    scrollRaf = null;
    chat.scrollTop = chat.scrollHeight;
  });
}

/** 流式期间节流滚动：避免每个 token / 思考行都改 scrollTop 造成整页闪烁。 */
let streamScrollDue = false;
let streamScrollTimer = 0;
function scrollChatStreaming() {
  if (!stickToBottom) return;
  streamScrollDue = true;
  if (streamScrollTimer) return;
  streamScrollTimer = setTimeout(() => {
    streamScrollTimer = 0;
    if (!streamScrollDue) return;
    streamScrollDue = false;
    scrollChatToBottom();
  }, 120);
}

// 只观察节点增删，不观察 characterData：否则流式改 textContent 会每字触发滚动闪烁。
const chatObserver = new MutationObserver(() => scrollChatStreaming());
chatObserver.observe(chat, { childList: true, subtree: true });

function appendMsg(role, text, attachments = []) {
  const wrap = document.createElement('div');
  wrap.className = `msg ${role}`;
  if (role === 'agent') {
    const body = document.createElement('div');
    body.className = 'msg-body';
    // 非流式 agent 消息：结构化块 + 轻量 Markdown + grounding 拆条
    if (text) applyAgentBody(body, text);
    wrap.appendChild(body);
    attachCopyButton(wrap, body);
    if (pendingThinkingEl) {
      attachThinkingButton(wrap, pendingThinkingEl);
      pendingThinkingEl = null;
    }
    chat.appendChild(wrap);
    scrollChatToBottom(true);
    return body;
  }
  if (role === 'user' && attachments.length > 0) {
    const body = document.createElement('div');
    body.className = 'msg-body';
    if (text) {
      const p = document.createElement('div');
      p.className = 'msg-text';
      p.textContent = text;
      body.appendChild(p);
    }
    const attWrap = document.createElement('div');
    attWrap.className = 'msg-attachments';
    attachments.forEach((a) => {
      if (a.kind === 'image') {
        const img = document.createElement('img');
        img.className = 'msg-thumb';
        img.alt = a.name || 'image';
        img.src = `data:${a.mediaType};base64,${a.data}`;
        attWrap.appendChild(img);
      } else {
        const chip = document.createElement('span');
        chip.className = `attach-chip${a.kind === 'document' ? ' attach-doc' : ''}`;
        chip.textContent = a.kind === 'document' ? documentChipLabel(a.name) : (a.name || 'file');
        attWrap.appendChild(chip);
      }
    });
    body.appendChild(attWrap);
    wrap.appendChild(body);
    chat.appendChild(wrap);
    scrollChatToBottom(true);
    return wrap;
  }
  wrap.textContent = text;
  chat.appendChild(wrap);
  scrollChatToBottom(true);
  return wrap;
}

function setStatus(text) { statusText.textContent = text; }

function arrayBufferToBase64(buf) {
  const bytes = new Uint8Array(buf);
  let bin = '';
  for (let i = 0; i < bytes.length; i += 1) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

function guessDocumentMime(name) {
  const lower = String(name || '').toLowerCase();
  if (lower.endsWith('.pdf')) return 'application/pdf';
  if (lower.endsWith('.docx') || lower.endsWith('.dotx')) {
    return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
  }
  if (lower.endsWith('.doc') || lower.endsWith('.dot')) return 'application/msword';
  if (lower.endsWith('.xlsx') || lower.endsWith('.xltx')) {
    return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
  }
  if (lower.endsWith('.xlsm')) return 'application/vnd.ms-excel.sheet.macroEnabled.12';
  if (lower.endsWith('.xls')) return 'application/vnd.ms-excel';
  if (lower.endsWith('.pptx')) {
    return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
  }
  if (lower.endsWith('.ppt')) return 'application/vnd.ms-powerpoint';
  if (lower.endsWith('.epub')) return 'application/epub+zip';
  return 'application/octet-stream';
}

async function readAttachment(file) {
  const buf = await file.arrayBuffer();
  if (isImageFile(file)) {
    if (countAttachmentsByKind('image') >= attachLimits.maxImages) {
      throw new Error(`图片数量已达上限 (${attachLimits.maxImages})`);
    }
    if (buf.byteLength > attachLimits.maxImageBytes) {
      throw new Error(`图片过大: ${file.name}（上限 ${formatBytes(attachLimits.maxImageBytes)}）`);
    }
    const mediaType = file.type || 'image/png';
    return {
      kind: 'image',
      name: file.name,
      mediaType,
      data: arrayBufferToBase64(buf),
    };
  }
  if (isDocumentFile(file)) {
    if (countAttachmentsByKind('document') >= (attachLimits.maxDocuments ?? 4)) {
      throw new Error(`文档数量已达上限 (${attachLimits.maxDocuments ?? 4})`);
    }
    const maxDoc = attachLimits.maxDocumentBytes ?? attachLimits.maxFileBytes;
    if (buf.byteLength > maxDoc) {
      throw new Error(`文档过大: ${file.name}（上限 ${formatBytes(maxDoc)}）`);
    }
    const mediaType = file.type || guessDocumentMime(file.name);
    return {
      kind: 'document',
      name: file.name,
      mediaType,
      data: arrayBufferToBase64(buf),
    };
  }
  if (!isTextFile(file)) throw new Error(`不支持的文件类型: ${file.name}`);
  if (countAttachmentsByKind('file') >= attachLimits.maxFiles) {
    throw new Error(`文件数量已达上限 (${attachLimits.maxFiles})`);
  }
  if (buf.byteLength > attachLimits.maxFileBytes) {
    throw new Error(`文件过大: ${file.name}（上限 ${formatBytes(attachLimits.maxFileBytes)}）`);
  }
  const mediaType = file.type || 'text/plain';
  const text = new TextDecoder('utf-8', { fatal: false }).decode(buf);
  return { kind: 'file', name: file.name, mediaType, data: text };
}

function splitAttachments(list) {
  const images = list
    .filter((a) => a.kind === 'image')
    .map(({ mediaType, data, name }) => ({ mediaType, data, name }));
  const files = list
    .filter((a) => a.kind === 'file')
    .map(({ name, mediaType, data }) => ({ name, mediaType, data }));
  const documents = list
    .filter((a) => a.kind === 'document')
    .map(({ name, mediaType, data }) => ({ name, mediaType, data }));
  return { images, files, documents };
}

async function addAttachmentsFromFiles(files) {
  if (!files?.length) return;
  const hasImage = files.some((f) => isImageFile(f));
  if (hasImage && !visionSupported()) {
    const model = window.__ALI_CONFIG__?.llm?.model || '当前模型';
    appendMsg('system', `${model} 不支持图像识别，图片会以文本说明发送（可切换到 gpt-4o 等视觉模型）。`);
  }
  try {
    for (const file of files) {
      const att = await readAttachment(file);
      pendingAttachments.push(att);
    }
    renderAttachPreview();
  } catch (e) {
    appendMsg('system', `附件错误: ${e.message}`);
  }
}

function clipboardImageFiles(clipboardData) {
  if (!clipboardData) return [];
  const files = [];
  if (clipboardData.files?.length) {
    for (const file of clipboardData.files) {
      if (file.type?.startsWith('image/')) files.push(file);
    }
  }
  if (files.length === 0 && clipboardData.items) {
    for (const item of clipboardData.items) {
      if (item.kind === 'file' && item.type?.startsWith('image/')) {
        const file = item.getAsFile();
        if (file) files.push(file);
      }
    }
  }
  return files;
}

function extensionForImageMime(mime) {
  const map = {
    'image/jpeg': 'jpg',
    'image/png': 'png',
    'image/gif': 'gif',
    'image/webp': 'webp',
  };
  return map[mime] || 'png';
}

function normalizeClipboardImageFile(file, index) {
  const mime = file.type || 'image/png';
  const hasName = file.name && !/^image\d*\.(png|jpe?g|gif|webp)$/i.test(file.name);
  if (hasName) return file;
  const ext = extensionForImageMime(mime);
  const name = `paste-${Date.now()}-${index + 1}.${ext}`;
  return new File([file], name, { type: mime });
}

function insertTextAtCursor(el, text) {
  if (!text) return;
  const start = el.selectionStart ?? el.value.length;
  const end = el.selectionEnd ?? el.value.length;
  el.value = `${el.value.slice(0, start)}${text}${el.value.slice(end)}`;
  const pos = start + text.length;
  el.selectionStart = pos;
  el.selectionEnd = pos;
}

function renderAttachPreview() {
  if (pendingAttachments.length === 0) {
    attachPreview.classList.add('hidden');
    attachPreview.innerHTML = '';
    return;
  }
  attachPreview.classList.remove('hidden');
  attachPreview.innerHTML = '';
  pendingAttachments.forEach((a, idx) => {
    const item = document.createElement('div');
    item.className = 'attach-item';
    if (a.kind === 'image') {
      const img = document.createElement('img');
      img.className = 'attach-thumb';
      img.alt = a.name;
      img.src = `data:${a.mediaType};base64,${a.data}`;
      item.appendChild(img);
    } else {
      const chip = document.createElement('span');
      chip.className = `attach-chip${a.kind === 'document' ? ' attach-doc' : ''}`;
      chip.textContent = a.kind === 'document' ? documentChipLabel(a.name) : a.name;
      item.appendChild(chip);
    }
    const rm = document.createElement('button');
    rm.type = 'button';
    rm.className = 'attach-remove';
    rm.textContent = '×';
    rm.title = '移除';
    rm.addEventListener('click', () => {
      pendingAttachments.splice(idx, 1);
      renderAttachPreview();
    });
    item.appendChild(rm);
    attachPreview.appendChild(item);
  });
}

function clearAttachments() {
  pendingAttachments = [];
  renderAttachPreview();
}

async function api(path, options = {}) {
  const token = apiToken();
  const headers = { 'Content-Type': 'application/json', ...(options.headers || {}) };
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(path, { ...options, headers });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = data.error || data.reason || `HTTP ${res.status}`;
    throw new Error(typeof err === 'string' ? err : JSON.stringify(err));
  }
  return data;
}

function formatToolArgs(args) {
  if (!args || typeof args !== 'object') return '';
  const keyZh = {
    grep: '关键词',
    query: '查询',
    path: '路径',
    limit: '条数',
    offset: '偏移',
    maxBytes: '最大字节',
    root: '根目录',
    ref: '版本',
    days: '天数',
    module: '模块',
    name: '名称',
    arity: '元数',
    pattern: '模式',
    phrase: '短语',
    question: '问题',
    call: '调用',
    sideEffect: '副作用',
    context: '上下文行数',
    includeSource: '附源码',
    glob: 'glob模式',
    maxEntries: '最大条目',
    startLine: '起始行',
    endLine: '结束行',
    lineCount: '行数',
  };
  const parts = Object.keys(args).sort().map((k) => {
    const v = args[k];
    const s = typeof v === 'string' ? v : JSON.stringify(v);
    const t = s.length > 120 ? `${s.slice(0, 120)}...` : s;
    const label = keyZh[k] || k;
    return `${label}=${t}`;
  });
  return parts.length ? ` [${parts.join(', ')}]` : '';
}

function formatEvent(ev) {
  const type = ev.type || '';
  const tool = ev.tool || '';
  const argsSuffix = formatToolArgs(ev.args);
  if (type === 'started') return ev.message || '任务已开始';
  if (type === 'step') {
    const step = ev.step != null ? ` ${ev.step}/${ev.maxSteps}` : '';
    if (ev.phase === 'heal') {
      const n = ev.healAttempt != null ? ` #${ev.healAttempt}` : '';
      const kind = ev.healKind ? `/${ev.healKind}` : '';
      return `[自愈${n}${kind}] ${ev.message || '注入失败上下文并重试'}`;
    }
    if (ev.phase === 'batchPlan') {
      return `[批量重构] ${ev.message || '计划未应用，强制补丁轮'}`;
    }
    return `[步骤${step}] ${ev.message || '思考中'}`;
  }
  if (type === 'tool' || type === 'toolStarted') {
    return `→ 调用工具 ${tool}${argsSuffix}`;
  }
  if (type === 'tool_done' || type === 'toolFinished' || type === 'approvalRequired') {
    const ms = ev.elapsedMs != null ? ` (${ev.elapsedMs}ms)` : '';
    if (ev.ok) return `✓ ${tool} 完成${argsSuffix}${ms}`;
    if (ev.status === 'confirmationRequired' || type === 'approvalRequired') {
      return `⊙ ${tool} 需确认${argsSuffix}${ms}`;
    }
    if (ev.error) {
      const err = typeof ev.error === 'string' ? ev.error : JSON.stringify(ev.error);
      return `✗ ${tool} 失败: ${err}${argsSuffix}${ms}`;
    }
    return `✗ ${tool} 失败${argsSuffix}${ms}`;
  }
  if (type === 'error') return `! 错误: ${formatErrorReason(ev.reason)}`;
  if (type === 'thought') {
    // 全文由 appendThoughtCapture 直接写入日志；此处不生成短摘要行
    return '';
  }
  return JSON.stringify(ev);
}

function formatErrorReason(reason) {
  if (reason == null || reason === '') return 'unknown';
  if (typeof reason === 'string') return reason;
  if (typeof reason === 'object') {
    if (reason.message) return String(reason.message);
    if (reason.error?.message) return String(reason.error.message);
    return JSON.stringify(reason);
  }
  return String(reason);
}

//==================================================================
// 思考过程 UI
//==================================================================
let thinkingBox = null;
let thinkingList = null;
let thinkingStatus = null;

const STATUS_LINE_RE = /^(正在连接|模型思考中|模型回答中|正在请求|准备会话|上下文就绪|任务已开始|worker started|building context|context built|calling)/;

function startThinking(question) {
  thinkingBox = document.createElement('div');
  thinkingBox.className = 'msg thinking';
  // 布局：思考中 = 本框（工具列表）+ 下方一个思考/输出气泡；结束后该气泡即答案。
  // 隐藏区：问题 + 思考过程全文 + 终答，供查看器按固定顺序展示。
  thinkingBox.innerHTML =
    '<div class="thinking-title">思考中...</div>'
    + '<div class="thinking-status">正在连接...</div>'
    + '<ul class="thinking-log"></ul>'
    + '<div class="thinking-capture" hidden aria-hidden="true">'
    +   '<pre class="thinking-capture-question"></pre>'
    +   '<pre class="thinking-capture-thoughts"></pre>'
    +   '<pre class="thinking-capture-final"></pre>'
    + '</div>';
  thinkingList = thinkingBox.querySelector('.thinking-log');
  thinkingStatus = thinkingBox.querySelector('.thinking-status');
  resetThoughtCapture();
  const q = String(question || '').trim();
  if (q) {
    const qPre = thinkingBox.querySelector('.thinking-capture-question');
    if (qPre) qPre.textContent = q;
  }
  chat.appendChild(thinkingBox);
  scrollChatToBottom();
}

function setThinkingStatus(text) {
  if (!thinkingStatus || !text) return;
  thinkingStatus.textContent = String(text).trim();
}

/** 向当前答案气泡追加流式正文。 */
function appendAgentStreamToken(msgBody, t) {
  if (!msgBody || !t) return;
  const node = msgBody.firstChild;
  if (node && node.nodeType === Node.TEXT_NODE) {
    node.appendData(t);
  } else if (!msgBody.textContent) {
    msgBody.textContent = t;
  } else {
    msgBody.textContent += t;
  }
}

function setAgentStreamText(msgBody, text) {
  if (!msgBody) return;
  msgBody.textContent = text || '';
}

/**
 * 「思考过程」隐藏区记录（区段化）：气泡里的流式文本是 reasoning 与
 * 正文混流、且多轮工具循环会重复累计，直接整段快照对比必然前缀失配、
 * 造成大面积重复。这里改为显式区段模型：
 *   - reasoning 流式分片 → 续写当前 reasoning 段；
 *   - thought 进度事件（整轮 reasoning/正文重发）→ 与当前段对齐去重，
 *     对不上才作为新段追加。
 * text 为隐藏区全文；segStart 是当前段在 text 中的起点；lastSeg 是最后
 * 一个已完成段，用于对重复事件去重。
 */
let thoughtCapture = null;

function resetThoughtCapture() {
  const pre = thinkingBox ? thinkingBox.querySelector('.thinking-capture-thoughts') : null;
  thoughtCapture = { pre, text: '', segStart: -1, reasoning: '', lastSeg: '' };
  if (pre) pre.textContent = '';
}

function renderThoughtCapture() {
  if (thoughtCapture && thoughtCapture.pre) {
    thoughtCapture.pre.textContent = thoughtCapture.text;
  }
}

function appendThoughtSegment(text) {
  const st = thoughtCapture;
  st.segStart = -1;
  st.text = st.text ? `${st.text}\n\n${text}` : text;
  st.lastSeg = text;
}

/** reasoning 流式分片：写入/续写当前 reasoning 段。 */
function recordReasoningChunk(text) {
  if (!thoughtCapture) return;
  const t = String(text || '');
  if (!t) return;
  if (thoughtCapture.reasoning) {
    thoughtCapture.reasoning += t;
  } else {
    thoughtCapture.segStart = thoughtCapture.text
      ? thoughtCapture.text.length + 2
      : 0;
    thoughtCapture.reasoning = t;
    thoughtCapture.text = thoughtCapture.text
      ? `${thoughtCapture.text}\n\n${t}`
      : t;
    renderThoughtCapture();
    return;
  }
  thoughtCapture.text = thoughtCapture.text.slice(0, thoughtCapture.segStart)
    + thoughtCapture.reasoning;
  renderThoughtCapture();
}

/** thought 进度事件：整轮 reasoning/正文快照，与已流式内容对齐去重。 */
function recordThoughtSnapshot(text) {
  if (!thoughtCapture) return;
  const msg = String(text || '');
  const mt = msg.trim();
  if (!mt) return;
  const st = thoughtCapture;
  if (st.reasoning) {
    const rt = st.reasoning.trim();
    if (mt === rt) {
      // 与流式内容一致：段收尾，不重复记录
      st.segStart = -1;
      st.reasoning = '';
      st.lastSeg = mt;
      return;
    }
    if (mt.startsWith(rt)) {
      // 事件比流式更完整：用事件全文替换当前段（当前段必为 text 尾部）
      st.text = st.text.slice(0, st.segStart) + msg;
      st.segStart = -1;
      st.reasoning = '';
      st.lastSeg = mt;
      renderThoughtCapture();
      return;
    }
    if (rt.startsWith(mt)) {
      // 流式内容已比事件更全：丢弃事件，段收尾
      st.segStart = -1;
      st.reasoning = '';
      st.lastSeg = rt;
      return;
    }
    // 不同源内容：当前段收尾，事件另起新段
    st.segStart = -1;
    st.reasoning = '';
    appendThoughtSegment(mt);
    renderThoughtCapture();
    return;
  }
  const lt = st.lastSeg.trim();
  if (lt && (mt === lt || lt.includes(mt))) return; // 重复事件
  if (lt && mt.startsWith(lt)) {
    // 同段增长：替换最后一段
    const cut = st.text.length - st.lastSeg.length;
    st.text = st.text.slice(0, cut) + msg;
    st.lastSeg = msg;
    renderThoughtCapture();
    return;
  }
  appendThoughtSegment(mt);
  renderThoughtCapture();
}

/**
 * 流式 reasoning：写入下方输出气泡；分片另续写「思考过程」当前段。
 * 布局：思考中 = 工具列表框 + 一个输出气泡；结束后该气泡即答案框。
 */
function appendReasoningChunk(text) {
  const t = String(text || '');
  if (!t) return;
  setThinkingStatus('模型思考中...');
  recordReasoningChunk(t);
  if (activeAsk?.msgWrap) {
    const body = activeAsk.msgWrap.querySelector('.msg-body');
    if (body) {
      activeAsk.full = (activeAsk.full || '') + t;
      appendAgentStreamToken(body, t);
      activeAsk.sawChunk = true;
      activeAsk.msgWrap.classList.remove('pending');
      return;
    }
  }
}

/**
 * thought 进度：同步到下方唯一输出气泡，并对齐去重后记入「思考过程」。
 * 多轮思考在气泡中依次追加，避免只留下最后一轮。
 */
function appendThoughtCapture(ev) {
  const msg = String(ev.message || '').trim();
  if (!msg) return;
  setThinkingStatus('模型思考中...');
  recordThoughtSnapshot(msg);
  if (!activeAsk?.msgWrap) return;
  const body = activeAsk.msgWrap.querySelector('.msg-body');
  if (!body) return;
  const cur = String(activeAsk.full || '').trim();
  let next = msg;
  if (!cur || cur === msg) {
    next = msg;
  } else if (msg.startsWith(cur)) {
    next = msg;
  } else if (cur.startsWith(msg)) {
    next = cur;
  } else if (cur.includes(msg)) {
    next = cur;
  } else {
    next = `${cur}\n\n${msg}`;
  }
  if (next !== cur) {
    setAgentStreamText(body, next);
    activeAsk.full = next;
  }
  activeAsk.sawChunk = true;
  activeAsk.msgWrap.classList.remove('pending');
}

function isReasoningToken(m) {
  const k = m && (m.kind ?? m.tokenKind);
  return k === 'reasoning' || k === 'thinking';
}

function isStatusLine(line) {
  return STATUS_LINE_RE.test(line) || line.startsWith('[步骤');
}

function addThinkingLine(text) {
  if (!thinkingList || !text) return;
  const line = String(text).trim();
  if (!line) return;
  if (isStatusLine(line)) { setThinkingStatus(line); return; }
  const items = thinkingList.querySelectorAll('li');
  if (items.length > 0 && items[items.length - 1].textContent === line) return;
  const li = document.createElement('li');
  li.textContent = line;
  thinkingList.appendChild(li);
  scrollChatStreaming();
}

function attachFinalAnswerToThinking(text, isError) {
  if (!thinkingBox) return;
  const chunk = String(text || '').trim();
  if (!chunk) return;
  const pre = thinkingBox.querySelector('.thinking-capture-final');
  if (!pre) return;
  pre.textContent = chunk;
  pre.dataset.isError = isError ? '1' : '0';
}

function finishThinking(finalText, isError) {
  if (thinkingBox) {
    // 终答只进「最终答案」，不写入「思考过程」，避免两区重复
    const chunk = finalText != null ? String(finalText).trim() : '';
    if (chunk) attachFinalAnswerToThinking(chunk, !!isError);
    const doneBox = thinkingBox;
    const title = doneBox.querySelector('.thinking-title');
    const count = thinkingList ? thinkingList.children.length : 0;
    if (title) title.textContent = count > 0 ? `思考完成（${count} 步）` : '思考完成';
    if (thinkingStatus) thinkingStatus.textContent = '';
    doneBox.classList.add('thinking-done');
    linkThinkingToAnswer(doneBox);
    thinkingBox = null;
    thinkingList = null;
    thinkingStatus = null;
    thoughtCapture = null;
  }
}

function serializeThinkingBox(el) {
  if (!el) return '';
  const parts = [];
  const title = el.querySelector('.thinking-title');
  if (title?.textContent) parts.push(title.textContent.trim());

  const question = el.querySelector('.thinking-capture-question')?.textContent?.trim();
  if (question) {
    parts.push('');
    parts.push('=== 问题 ===');
    parts.push(question);
  }

  // 与界面所见一致：工具列表时间线（不含重复正文）
  const logParts = [];
  el.querySelectorAll('.thinking-log > li').forEach((li) => {
    if (li.classList.contains('thinking-thought')) return; // 旧会话残留，忽略
    if (li.classList.contains('thinking-graph') || li.classList.contains('thinking-hit-list')
        || li.classList.contains('thinking-doc-preview') || li.classList.contains('thinking-heal-locs')) {
      return;
    }
    const t = (li.textContent || '').trim();
    if (t) logParts.push(t);
  });
  if (logParts.length) {
    parts.push('');
    parts.push('=== 工具调用 ===');
    logParts.forEach((t, i) => parts.push(`${i + 1}. ${t}`));
  }

  el.querySelectorAll('.thinking-graph').forEach((g) => {
    const gt = g.querySelector('.thinking-graph-title')?.textContent?.trim();
    parts.push(gt || '[调用图]');
    const mmd = g.querySelector('.mermaid')?.textContent?.trim()
      || g.querySelector('pre')?.textContent?.trim();
    if (mmd) parts.push(mmd);
  });
  el.querySelectorAll('.thinking-hit').forEach((hit) => {
    const head = hit.querySelector('.thinking-hit-head')?.textContent?.trim();
    const snip = hit.querySelector('.thinking-hit-snippet')?.textContent?.trim();
    if (head) parts.push(head);
    if (snip) parts.push(snip);
  });

  const thoughts = el.querySelector('.thinking-capture-thoughts')?.textContent?.trim();
  if (thoughts) {
    parts.push('');
    parts.push('=== 思考过程 ===');
    parts.push(thoughts);
  }

  const finalBody = el.querySelector('.thinking-capture-final');
  if (finalBody?.textContent?.trim()) {
    parts.push('');
    parts.push(finalBody.dataset.isError === '1' ? '=== 最终结果（错误） ===' : '=== 最终答案 ===');
    parts.push(finalBody.textContent.trim());
  }
  return parts.filter((x, i, arr) => !(x === '' && arr[i - 1] === '')).join('\n');
}

/** 查看器顺序：问题 → 工具调用 → 思考过程 → 最终答案。
 * 思考过程按块懒渲染：首屏只挂前几块，滚动接近底部再追加，避免超长文本一次着色卡死浏览器。
 */
const TV_THOUGHT_CHUNK_CHARS = 3500;
const TV_THOUGHT_INITIAL_CHUNKS = 2;
const TV_THOUGHT_LOAD_CHUNKS = 2;
const TV_COLORIZE_MAX_CHARS = 12000;
const TV_SEARCH_FULL_MAX_CHARS = 80000;
const TV_SEARCH_SNIPPET_PAD = 500;

function splitThinkingTextIntoChunks(text, chunkChars = TV_THOUGHT_CHUNK_CHARS) {
  const src = String(text || '');
  if (!src) return [];
  if (src.length <= chunkChars) return [src];
  const chunks = [];
  let i = 0;
  while (i < src.length) {
    let end = Math.min(src.length, i + chunkChars);
    if (end < src.length) {
      // 尽量在换行处切开，避免把一行拆碎
      const slice = src.slice(i, end);
      const nl = Math.max(slice.lastIndexOf('\n'), slice.lastIndexOf('\r'));
      if (nl > chunkChars * 0.4) end = i + nl + 1;
    }
    chunks.push(src.slice(i, end));
    i = end;
  }
  return chunks;
}

function colorizeThinkingChunkEl(pre) {
  if (!pre || pre.dataset.tvColored === '1') return;
  const text = pre.textContent || '';
  if (!text.trim()) {
    pre.dataset.tvColored = '1';
    return;
  }
  // 超大块只保留纯文本，避免一次 highlight 拖死主线程
  if (text.length > TV_COLORIZE_MAX_CHARS) {
    pre.dataset.tvColored = '1';
    pre.dataset.tvPlain = '1';
    return;
  }
  pre.innerHTML = colorizeThinkingSnippet(text);
  pre.dataset.tvColored = '1';
}

function scheduleColorizeThinkingChunks(root) {
  if (!root) return;
  const pending = Array.from(root.querySelectorAll('pre.thinking-lazy-chunk:not([data-tv-colored="1"])'));
  if (!pending.length) return;
  let idx = 0;
  const pump = () => {
    const start = performance.now();
    while (idx < pending.length && performance.now() - start < 8) {
      colorizeThinkingChunkEl(pending[idx++]);
    }
    if (idx < pending.length) {
      const idle = window.requestIdleCallback || ((cb) => setTimeout(() => cb({}), 16));
      idle(pump, { timeout: 120 });
    }
  };
  pump();
}

function updateThinkingLazyMeta(holder) {
  if (!holder) return;
  const total = (holder._tvChunks || []).length;
  const done = holder._tvRendered || 0;
  let meta = holder.querySelector('.thinking-lazy-meta');
  if (!meta) {
    meta = document.createElement('div');
    meta.className = 'thinking-lazy-meta muted';
    holder.appendChild(meta);
  }
  if (done >= total) {
    meta.textContent = total > 1 ? `已全部加载（${total} 段）` : '';
    meta.hidden = total <= 1;
  } else {
    meta.textContent = `已加载 ${done}/${total} 段 · 向下滚动继续加载`;
    meta.hidden = false;
  }
}

function appendThinkingLazyChunks(holder, count = TV_THOUGHT_LOAD_CHUNKS) {
  if (!holder || !holder._tvChunks) return 0;
  const chunks = holder._tvChunks;
  const start = holder._tvRendered || 0;
  if (start >= chunks.length) {
    updateThinkingLazyMeta(holder);
    return 0;
  }
  const end = Math.min(chunks.length, start + Math.max(1, count));
  const frag = document.createDocumentFragment();
  for (let i = start; i < end; i++) {
    const pre = document.createElement('pre');
    pre.className = 'thinking-hit-snippet thinking-lazy-chunk';
    pre.textContent = chunks[i];
    frag.appendChild(pre);
  }
  const meta = holder.querySelector('.thinking-lazy-meta');
  if (meta) holder.insertBefore(frag, meta);
  else holder.appendChild(frag);
  holder._tvRendered = end;
  updateThinkingLazyMeta(holder);
  scheduleColorizeThinkingChunks(holder);
  return end - start;
}

function createLazyThoughtsBlock(thoughts) {
  const holder = document.createElement('div');
  holder.className = 'thinking-lazy-thoughts';
  holder._tvChunks = splitThinkingTextIntoChunks(thoughts);
  holder._tvRendered = 0;
  appendThinkingLazyChunks(holder, TV_THOUGHT_INITIAL_CHUNKS);
  return holder;
}

function maybeLoadMoreThinkingChunks() {
  if (!thinkingViewerBody || !isThinkingViewerOpen()) return;
  const holder = thinkingViewerBody.querySelector('.thinking-lazy-thoughts');
  if (!holder || !holder._tvChunks) return;
  if ((holder._tvRendered || 0) >= holder._tvChunks.length) return;
  const remain = thinkingViewerBody.scrollHeight - thinkingViewerBody.scrollTop - thinkingViewerBody.clientHeight;
  if (remain > 280) return;
  appendThinkingLazyChunks(holder, TV_THOUGHT_LOAD_CHUNKS);
}

/** 首屏内容不足一屏时继续填充，避免“看起来没内容但还得硬滚” */
function fillThinkingViewerViewport() {
  if (!thinkingViewerBody || !isThinkingViewerOpen()) return;
  let guard = 24;
  while (guard-- > 0) {
    const holder = thinkingViewerBody.querySelector('.thinking-lazy-thoughts');
    if (!holder || !holder._tvChunks) break;
    if ((holder._tvRendered || 0) >= holder._tvChunks.length) break;
    if (thinkingViewerBody.scrollHeight > thinkingViewerBody.clientHeight + 48) break;
    if (!appendThinkingLazyChunks(holder, TV_THOUGHT_LOAD_CHUNKS)) break;
  }
}

/** 查看器顺序：问题 → 工具调用 → 思考过程 → 最终答案。 */
function buildThinkingViewerContent(sourceEl) {
  const wrap = document.createElement('div');
  wrap.className = 'thinking-viewer-content';

  const addSection = (title, nodeOrText) => {
    if (!nodeOrText) return;
    const isNode = typeof nodeOrText !== 'string';
    const text = isNode ? null : String(nodeOrText).trim();
    if (!isNode && !text) return;
    if (isNode && !nodeOrText.childNodes.length && !(nodeOrText.textContent || '').trim()) return;
    const lab = document.createElement('div');
    lab.className = 'thinking-section-label';
    lab.textContent = title;
    wrap.appendChild(lab);
    if (isNode) {
      wrap.appendChild(nodeOrText);
    } else {
      const pre = document.createElement('pre');
      pre.className = 'thinking-hit-snippet';
      pre.textContent = text;
      wrap.appendChild(pre);
    }
  };

  const title = document.createElement('div');
  title.className = 'thinking-title';
  title.textContent = sourceEl.querySelector('.thinking-title')?.textContent?.trim() || '思考过程';
  wrap.appendChild(title);

  const question = sourceEl.querySelector('.thinking-capture-question')?.textContent?.trim();
  if (question) addSection('问题', question);

  const log = sourceEl.querySelector('.thinking-log');
  if (log) {
    const logClone = log.cloneNode(true);
    logClone.querySelectorAll('li.thinking-thought').forEach((n) => n.remove());
    logClone.querySelectorAll('.thinking-graph-open').forEach((btn) => {
      btn.disabled = true;
      btn.title = '请在对话里的图入口打开';
    });
    if (logClone.querySelectorAll('li').length) addSection('工具调用', logClone);
  }

  const thoughts = sourceEl.querySelector('.thinking-capture-thoughts')?.textContent?.trim();
  if (thoughts) {
    const lab = document.createElement('div');
    lab.className = 'thinking-section-label';
    lab.textContent = '思考过程';
    wrap.appendChild(lab);
    wrap.appendChild(createLazyThoughtsBlock(thoughts));
  }

  const finalText = sourceEl.querySelector('.thinking-capture-final')?.textContent?.trim();
  const finalErr = sourceEl.querySelector('.thinking-capture-final')?.dataset?.isError === '1';
  if (finalText) addSection(finalErr ? '最终结果（错误）' : '最终答案', finalText);

  return wrap;
}

function applyThinkingViewerZoom() {
  if (thinkingViewerBody) {
    thinkingViewerBody.style.setProperty('--fv-zoom', String(thinkingViewerZoomPct / 100));
    thinkingViewerBody.style.fontSize = `${(13 * thinkingViewerZoomPct) / 100}px`;
  }
  if (thinkingViewerZoom) thinkingViewerZoom.textContent = `${thinkingViewerZoomPct}%`;
}

function clearThinkingViewerSearch(resetInput) {
  tvSearchHits = [];
  tvSearchIndex = -1;
  if (resetInput && thinkingViewerSearch) thinkingViewerSearch.value = '';
  if (thinkingViewerSearchCount) thinkingViewerSearchCount.textContent = '0/0';
}

/** 思考过程查看器：正文轻量语法着色（复用文件查看器规则）。 */
function colorizeThinkingSnippet(text) {
  const t = String(text || '');
  if (!t) return '';
  const looksErl = /(?:^|[\s`])[a-z_][\w]*:[a-z_][\w]*\s*\//m.test(t)
    || /\b(?:-module|-export|fun\s*\(|end\.)\b/.test(t)
    || /```erlang/i.test(t);
  return highlightFileViewerText(t, looksErl ? 'thinking.erl' : 'thinking.md');
}

function colorizeThinkingViewerTree(root) {
  if (!root) return;
  // 懒加载块走 scheduleColorizeThinkingChunks，这里只处理工具行/短预览
  root.querySelectorAll('pre.thinking-hit-snippet:not(.thinking-lazy-chunk), pre.thinking-reasoning, pre.thinking-thought-body').forEach((el) => {
    colorizeThinkingChunkEl(el);
  });
  root.querySelectorAll('.thinking-log > li').forEach((li) => {
    if (li.dataset.tvColored === '1') return;
    if (li.classList.contains('thinking-graph') || li.classList.contains('thinking-hit-list')
        || li.classList.contains('thinking-doc-preview') || li.classList.contains('thinking-heal-locs')) {
      return;
    }
    const text = li.textContent || '';
    if (!text.trim()) return;
    let html = escapeHtml(text);
    html = html.replace(/^([→✓✗⊙!])\s*/, '<span class="tv-mark">$1</span> ');
    html = html.replace(
      /\b([A-Za-z_][\w]*)\b(?=\s*(?:完成|失败|需确认|\[|$))/g,
      '<span class="tv-tool">$1</span>'
    );
    html = html.replace(
      /\b([a-z_][\w]*):([a-z_][\w]*)\/(\d+)\b/g,
      '<span class="fv-atom">$1</span>:<span class="fv-fn">$2</span>/<span class="fv-num">$3</span>'
    );
    li.innerHTML = html;
    li.dataset.tvColored = '1';
  });
  scheduleColorizeThinkingChunks(root);
}

function renderThinkingSearchSnippets(text, query) {
  if (!thinkingViewerBody) return;
  const hit = tvSearchHits[tvSearchIndex] || tvSearchHits[0];
  if (!hit) {
    thinkingViewerBody.innerHTML = `<pre class="thinking-hit-snippet">${escapeHtml(text.slice(0, 4000))}${text.length > 4000 ? '\n…' : ''}</pre>`;
    return;
  }
  const start = Math.max(0, hit.start - TV_SEARCH_SNIPPET_PAD);
  const end = Math.min(text.length, hit.end + TV_SEARCH_SNIPPET_PAD);
  const before = text.slice(start, hit.start);
  const match = text.slice(hit.start, hit.end);
  const after = text.slice(hit.end, end);
  const prefix = start > 0 ? '…\n' : '';
  const suffix = end < text.length ? '\n…' : '';
  thinkingViewerBody.innerHTML =
    `<div class="thinking-search-note muted">正文过长，搜索仅显示当前匹配附近片段（${tvSearchIndex + 1}/${tvSearchHits.length}）</div>`
    + `<pre class="thinking-hit-snippet">${prefix}${escapeHtml(before)}`
    + `<mark class="fv-hit fv-hit-active">${escapeHtml(match)}</mark>`
    + `${escapeHtml(after)}${suffix}</pre>`;
}

function renderThinkingViewerBody() {
  if (!thinkingViewerBody) return;
  const query = (thinkingViewerSearch?.value || '').trim();
  if (!query) {
    thinkingViewerBody.innerHTML = '';
    if (thinkingViewerSourceEl) {
      thinkingViewerClone = buildThinkingViewerContent(thinkingViewerSourceEl);
      thinkingViewerBody.appendChild(thinkingViewerClone);
      colorizeThinkingViewerTree(thinkingViewerBody);
    } else if (thinkingViewerText) {
      const holder = createLazyThoughtsBlock(thinkingViewerText);
      thinkingViewerBody.appendChild(holder);
    } else {
      thinkingViewerBody.textContent = '（无思考内容）';
    }
    clearThinkingViewerSearch(false);
    requestAnimationFrame(() => fillThinkingViewerViewport());
    return;
  }
  const text = thinkingViewerText || '';
  if (!text) {
    thinkingViewerBody.textContent = '（无思考内容）';
    clearThinkingViewerSearch(false);
    return;
  }
  const caseSensitive = !!(thinkingViewerSearchCase && thinkingViewerSearchCase.checked);
  tvSearchHits = collectFileViewerHits(text, query, caseSensitive);
  if (tvSearchHits.length === 0) {
    thinkingViewerBody.innerHTML =
      `<div class="thinking-search-note muted">未找到匹配</div>`
      + `<pre class="thinking-hit-snippet">${escapeHtml(text.slice(0, 6000))}${text.length > 6000 ? '\n…' : ''}</pre>`;
    tvSearchIndex = -1;
    if (thinkingViewerSearchCount) thinkingViewerSearchCount.textContent = '0/0';
    return;
  }
  if (tvSearchIndex < 0 || tvSearchIndex >= tvSearchHits.length) tvSearchIndex = 0;
  if (thinkingViewerSearchCount) {
    const cur = tvSearchIndex + 1;
    const extra = tvSearchHits.length >= FV_SEARCH_MAX_HITS ? '+' : '';
    thinkingViewerSearchCount.textContent = `${cur}/${tvSearchHits.length}${extra}`;
  }
  // 超长正文：不要把整篇 escape+mark 塞进 DOM
  if (text.length > TV_SEARCH_FULL_MAX_CHARS) {
    renderThinkingSearchSnippets(text, query);
    return;
  }
  let html = '';
  let cursor = 0;
  tvSearchHits.forEach((hit, i) => {
    if (hit.start > cursor) html += escapeHtml(text.slice(cursor, hit.start));
    const cls = i === tvSearchIndex ? 'fv-hit fv-hit-active' : 'fv-hit';
    html += `<mark class="${cls}" data-tv-i="${i}">${escapeHtml(text.slice(hit.start, hit.end))}</mark>`;
    cursor = hit.end;
  });
  if (cursor < text.length) html += escapeHtml(text.slice(cursor));
  thinkingViewerBody.innerHTML = `<pre class="thinking-hit-snippet">${html}</pre>`;
  const active = thinkingViewerBody.querySelector('mark.fv-hit-active');
  active?.scrollIntoView({ block: 'center', behavior: 'smooth' });
}

function openThinkingViewer(sourceEl) {
  if (!thinkingViewer || !sourceEl) return;
  closeFileViewer();
  thinkingViewerSourceEl = sourceEl;
  thinkingViewerText = serializeThinkingBox(sourceEl);
  thinkingViewerClone = null;
  const stepCount = sourceEl.querySelectorAll('.thinking-log > li').length;
  const hasProcess = !!(sourceEl.querySelector('.thinking-log')?.querySelector('li:not(.thinking-thought)'));
  const hasThoughts = !!(sourceEl.querySelector('.thinking-capture-thoughts')?.textContent?.trim());
  const hasFinal = !!(sourceEl.querySelector('.thinking-capture-final')?.textContent?.trim());
  thinkingViewer.classList.remove('hidden');
  thinkingViewer.classList.remove('is-fullscreen');
  if (btnTvFullscreen) btnTvFullscreen.textContent = '全屏';
  applyFileViewerGeomTo(thinkingViewerPanel, loadFileViewerGeom() || defaultFileViewerGeom(), 'tv');
  if (thinkingViewerTitle) {
    thinkingViewerTitle.textContent = sourceEl.querySelector('.thinking-title')?.textContent?.trim() || '思考过程';
  }
  if (thinkingViewerMeta) {
    const bits = [];
    const hasQuestion = !!(sourceEl.querySelector('.thinking-capture-question')?.textContent?.trim());
    if (hasQuestion) bits.push('含问题');
    if (stepCount > 0) bits.push(`${stepCount} 步`);
    if (hasProcess) bits.push('工具调用');
    if (hasThoughts) bits.push('思考过程');
    if (hasFinal) bits.push('最终答案');
    else bits.push('无最终答案');
    const chars = (thinkingViewerText || '').length;
    if (chars > 0) bits.push(`${chars} 字`);
    if (chars > TV_THOUGHT_CHUNK_CHARS * TV_THOUGHT_INITIAL_CHUNKS) bits.push('滚动加载');
    bits.push('可复制整段发给分析');
    thinkingViewerMeta.textContent = bits.join(' · ');
  }
  clearThinkingViewerSearch(true);
  renderThinkingViewerBody();
  requestAnimationFrame(() => fillThinkingViewerViewport());
  syncThinkingButtonState();
  thinkingViewerBody?.focus();
  setStatus('已打开思考过程');
}

function closeThinkingViewer() {
  if (!thinkingViewer) return;
  if (!thinkingViewer.classList.contains('hidden') && !thinkingViewer.classList.contains('is-fullscreen')) {
    saveGeomFromPanel(thinkingViewerPanel, thinkingViewerZoomPct);
  }
  thinkingViewer.classList.add('hidden');
  thinkingViewer.classList.remove('is-fullscreen');
  if (btnTvFullscreen) btnTvFullscreen.textContent = '全屏';
  tvDragState = null;
  thinkingViewerDrag?.classList.remove('dragging');
  clearThinkingViewerSearch(true);
  thinkingViewerClone = null;
  thinkingViewerSourceEl = null;
  thinkingViewerText = '';
  if (thinkingViewerBody) thinkingViewerBody.innerHTML = '';
  syncThinkingButtonState();
}

function applyFileViewerGeomTo(panel, geom, zoomKind) {
  if (!panel) return;
  const base = defaultFileViewerGeom();
  const g = geom && typeof geom === 'object' ? geom : base;
  const vw = window.innerWidth;
  const vh = window.innerHeight;
  let width = Number(g.width);
  let height = Number(g.height);
  if (!Number.isFinite(width) || width <= 0) width = base.width;
  if (!Number.isFinite(height) || height <= 0) height = base.height;
  width = Math.max(280, Math.min(width, vw - 8));
  height = Math.max(240, Math.min(height, vh - 8));
  let left = g.left != null && Number.isFinite(Number(g.left)) ? Number(g.left) : base.left;
  let top = g.top != null && Number.isFinite(Number(g.top)) ? Number(g.top) : base.top;
  left = Math.max(0, Math.min(left, vw - 80));
  top = Math.max(0, Math.min(top, vh - 40));
  panel.style.left = `${left}px`;
  panel.style.top = `${top}px`;
  panel.style.width = `${width}px`;
  panel.style.height = `${height}px`;
  if (typeof g.zoom === 'number' && g.zoom >= 60 && g.zoom <= 240) {
    if (zoomKind === 'tv') thinkingViewerZoomPct = g.zoom;
    else fileViewerZoomPct = g.zoom;
  } else if (!geom) {
    if (zoomKind === 'tv') thinkingViewerZoomPct = 100;
    else fileViewerZoomPct = 100;
  }
  if (zoomKind === 'tv') applyThinkingViewerZoom();
  else applyFileViewerZoom();
}

function saveGeomFromPanel(panel, zoomPct) {
  if (!panel) return;
  const r = panel.getBoundingClientRect();
  try {
    localStorage.setItem(FV_POS_KEY, JSON.stringify({
      left: r.left,
      top: r.top,
      width: r.width,
      height: r.height,
      zoom: zoomPct,
    }));
  } catch { /* ignore */ }
}

function extractModelText(chunk) {
  if (!chunk) return '';
  return String(chunk).split('\n').filter((line) => !line.trim().startsWith('→ 调用工具')).join('\n');
}

function extractTaskId(text) {
  if (!text) return null;
  const m = String(text).match(/TaskId:\s*(\d+)/i);
  return m ? m[1] : null;
}

//==================================================================
// 审批条（仅确认/忽略，不渲染 diff 预览）
//==================================================================
function showApproveBar(taskId, previewText) {
  pendingTaskId = taskId;
  approveText.textContent = previewText || `操作待确认 (TaskId: ${taskId})`;
  approveBar.classList.remove('hidden');
}

function hideApproveBar() {
  pendingTaskId = null;
  approveBar.classList.add('hidden');
}

function maybeShowApprove(fullText) {
  const tid = extractTaskId(fullText);
  if (tid) {
    showApproveBar(tid, fullText.includes('callFunction')
      ? 'Agent 请求执行函数，需批准后继续'
      : 'Agent 请求修改文件，需批准后执行');
  }
}

//==================================================================
// 问答：WS 优先，SSE 回退
//==================================================================
function askViaWS(prompt, sessionId, attachments = []) {
  return new Promise((resolve, reject) => {
    stickToBottom = true;
    scrollChatToBottom(true);
    startThinking(prompt);
    const msgBody = appendMsg('agent', '');
    const textNode = msgBody.firstChild;
    const msgWrap = msgBody.parentElement;
    msgWrap.classList.add('streaming', 'pending');
    let full = '';
    let sawChunk = false;
    let myTaskId = null;
    const timeout = setTimeout(() => finishActiveAsk('流式回答超时'), 1800000);

    activeAsk = { timeout, msgWrap, full: '', resolve, reject, finished: false, taskId: null, sawChunk: false };

    const isMine = (m) => {
      if (myTaskId == null) return true;
      const tid = m.taskId != null ? String(m.taskId) : (m.task_id != null ? String(m.task_id) : null);
      // 无 taskId 的帧（兼容旧服务端）仍接收；有 taskId 则必须匹配本轮
      return tid == null || tid === String(myTaskId);
    };

    WS.streamHandler = (m) => {
      if (m.type === 'ack') {
        if (m.kind === 'ask' || m.kind == null) {
          if (m.taskId != null) {
            myTaskId = String(m.taskId);
            if (activeAsk) activeAsk.taskId = myTaskId;
          }
        }
        return;
      }
      if (!isMine(m)) return;
      if (m.type === 'progress') {
        handleStreamProgress(m.event || {});
        if (activeAsk) full = activeAsk.full || '';
        return;
      }
      if (m.type === 'error') {
        if (!activeAsk) return;
        const text = String(m.error || m.reason || 'unknown error');
        full = text;
        if (activeAsk) activeAsk.full = full;
        msgWrap.classList.remove('pending');
        setAgentStreamText(msgBody, text);
        addThinkingLine(`! 错误: ${text}`);
        finishActiveAsk(text);
        return;
      }
      if (m.type === 'answer') {
        const text = m.text || extractModelText(m.result) || '';
        if (!text) return;
        full = text;
        if (activeAsk) { activeAsk.full = full; activeAsk.sawChunk = true; }
        sawChunk = true;
        msgWrap.classList.remove('pending');
        setThinkingStatus('模型回答中...');
        setAgentStreamText(msgBody, text);
        scrollChatStreaming();
        return;
      }
      if (m.type === 'token') {
        const t = extractModelText(m.data ?? m.text);
        if (!t) return;
        if (isReasoningToken(m)) {
          appendReasoningChunk(t);
          return;
        }
        if (activeAsk) {
          activeAsk.full = (activeAsk.full || '') + t;
          full = activeAsk.full;
          activeAsk.sawChunk = true;
        } else {
          full += t;
        }
        sawChunk = true;
        msgWrap.classList.remove('pending');
        setThinkingStatus('模型回答中...');
        appendAgentStreamToken(msgBody, t);
        scrollChatStreaming();
        return;
      }
      if (m.type === 'done') {
        if (!activeAsk) return;
        full = activeAsk.full || full;
        if (!String(full || '').trim()) {
          // answer/token 可能因发送路径丢帧；优先用 safe 提示，勿当成成功空串
          const hint = '回答为空或请求失败（未收到正文）。若思考框有内容，请热加载/重启节点后重试；也可检查 LLM 网络/API。';
          setAgentStreamText(msgBody, hint);
          msgWrap.classList.remove('pending');
          finishActiveAsk(hint);
          return;
        }
        maybeShowApprove(full);
        finishActiveAsk(null, full);
      }
    };
    try {
      const payload = { type: 'ask', prompt, sessionId, ...llmPayload(), ...splitAttachments(attachments) };
      WS.send(payload);
    } catch (err) {
      finishActiveAsk(err.message || String(err));
    }
  });
}

function askViaSSE(prompt, sessionId = 'web') {
  // 避免 token 进 URL：统一走 POST + Authorization Bearer
  return askViaPostStream(prompt, sessionId, []);
}

function askViaPostStream(prompt, sessionId = 'web', attachments = []) {
  const token = apiToken();
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  const body = JSON.stringify({ prompt, sessionId, ...llmPayload(), ...splitAttachments(attachments) });
  return runSseStream('/api/ask/stream', { method: 'POST', headers, body }, prompt);
}

function runSseStream(url, fetchOptions, question) {
  stickToBottom = true;
  scrollChatToBottom(true);
  startThinking(question);

  return new Promise((resolve, reject) => {
    let fullText = '';
    let sawChunk = false;
    const msgBody = appendMsg('agent', '');
    const textNode = msgBody.firstChild;
    const msgWrap = msgBody.parentElement;
    msgWrap.classList.add('streaming', 'pending');

    const timeout = setTimeout(() => finishActiveAsk('流式回答超时'), 1800000);

    activeAsk = { timeout, msgWrap, full: '', resolve, reject, finished: false };

    const finish = (err) => {
      if (!activeAsk || activeAsk.finished) return;
      activeAsk.full = fullText;
      if (err) finishActiveAsk(err.message || String(err));
      else {
        maybeShowApprove(fullText);
        finishActiveAsk(null, fullText);
      }
    };

    if (fetchOptions) {
      const ac = new AbortController();
      activeAskAbort = ac;
      fetch(url, { ...fetchOptions, signal: ac.signal }).then(async (res) => {
        if (!res.ok) {
          const data = await res.json().catch(() => ({}));
          const detail = data.reason || data.error || `HTTP ${res.status}`;
          finish(new Error(typeof detail === 'string' ? detail : JSON.stringify(detail)));
          return;
        }
        const reader = res.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';
        const pump = () => reader.read().then(({ value, done: streamDone }) => {
          if (streamDone) { finish(); return; }
          buffer += decoder.decode(value, { stream: true });
          const parts = buffer.split('\n\n');
          buffer = parts.pop() || '';
          parts.forEach((block) => {
            const lines = block.split('\n');
            let eventType = 'message';
            let data = '';
            lines.forEach((line) => {
              if (line.startsWith('event:')) eventType = line.slice(6).trim();
              else if (line.startsWith('data:')) data += line.slice(5).trim();
            });
            if (eventType === 'progress') {
              try { handleStreamProgress(JSON.parse(data)); } catch { /* ignore */ }
              if (activeAsk) fullText = activeAsk.full || '';
              return;
            }
            if (eventType === 'done') { finish(); return; }
            const modelText = extractModelText(data);
            if (!modelText) return;
            if (activeAsk) {
              activeAsk.full = (activeAsk.full || '') + modelText;
              fullText = activeAsk.full;
              activeAsk.sawChunk = true;
            } else {
              fullText += modelText;
            }
            sawChunk = true;
            msgWrap.classList.remove('pending');
            setThinkingStatus('模型回答中...');
            appendAgentStreamToken(msgBody, modelText);
            scrollChatStreaming();
          });
          pump();
        }).catch((e) => {
          if (e.name === 'AbortError') finish();
          else finish(e);
        });
        pump();
      }).catch((e) => {
        if (e.name === 'AbortError') finish();
        else finish(e);
      });
      return;
    }

    const es = new EventSource(url);
    activeAsk.es = es;
    es.addEventListener('progress', (e) => {
      try { handleStreamProgress(JSON.parse(e.data)); } catch { /* ignore */ }
      if (activeAsk) fullText = activeAsk.full || '';
    });

    es.onmessage = (e) => {
      const modelText = extractModelText(e.data);
      if (!modelText) return;
      if (activeAsk) {
        activeAsk.full = (activeAsk.full || '') + modelText;
        fullText = activeAsk.full;
        activeAsk.sawChunk = true;
      } else {
        fullText += modelText;
      }
      sawChunk = true;
      msgWrap.classList.remove('pending');
      setThinkingStatus('模型回答中...');
      appendAgentStreamToken(msgBody, modelText);
      scrollChatStreaming();
    };

    es.addEventListener('done', () => {
      es.close();
      finish();
    });

    es.onerror = () => {
      if (!activeAsk || activeAsk.finished) return;
      es.close();
      finish(new Error('SSE 连接错误或中断'));
    };
  });
}

async function ask(prompt, sessionId, attachments = []) {
  // WS 优先；若已断开，先尝试一次轻量重连（最多 3s），成功后走 WS；
  // 重连失败则回退到 POST + fetch 读 SSE。
  if (WS.sock && WS.sock.readyState === WebSocket.OPEN) {
    return askViaWS(prompt, sessionId, attachments);
  }
  const ok = await WS.ensureConnected(3000);
  if (ok) return askViaWS(prompt, sessionId, attachments);
  return askViaPostStream(prompt, sessionId, attachments);
}

//==================================================================
// 状态 / 会话 / 任务 / 规划 / 指标
//==================================================================
async function loadStatus() {
  try {
    const data = await ctrl('status', {}, '/api/status');
    if (data.config) applyWebConfig(data.config);
    else if (data.attachmentLimits) applyAttachLimits(data.attachmentLimits);
    const mode = data.agent?.mode || window.__ALI_CONFIG__?.agent?.mode || 'ask';
    modeSelect.value = mode;
    setStatus(`节点 ${data.node || '-'} | 工具 ${data.agent?.toolCount ?? '-'}`);
  } catch {
    setStatus('无法连接 Agent API');
  }
}

async function loadSessions() {
  try {
    const data = await api('/api/sessions');
    const saved = data.saved || [];
    const cur = currentSessionId();
    sessionSelect.innerHTML = '';
    ['web', ...saved.filter((id) => id !== 'web')].forEach((id) => {
      const opt = document.createElement('option');
      opt.value = id;
      opt.textContent = id === 'web' ? 'web（默认）' : id;
      sessionSelect.appendChild(opt);
    });
    if ([...sessionSelect.options].some((o) => o.value === cur)) {
      sessionSelect.value = cur;
    }
  } catch { /* ignore */ }
}

async function loadTasks() {
  try {
    const data = await ctrl('tasks', {}, '/api/tasks');
    const tasks = data.tasks || [];
    tasksList.innerHTML = '';
    if (tasks.length === 0) { tasksList.innerHTML = '<li class="muted">无任务</li>'; return; }
    tasks.forEach((t) => {
      const li = document.createElement('li');
      const id = t.id || t.taskId || '?';
      const status = t.status || 'unknown';
      li.innerHTML = `<span>${escapeHtml(id)}</span> <span class="muted">${escapeHtml(status)}</span>`;
      if (status === 'running') {
        const btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'btn-muted btn-sm';
        btn.textContent = '停止';
        btn.onclick = async () => {
          try {
            await ctrl('cancelTask', { taskId: id }, '/api/tasks/cancel', {
              method: 'POST',
              body: JSON.stringify({ taskId: id }),
            });
          } catch (e) {
            appendMsg('system', `取消任务失败: ${e.message}`);
          }
          loadTasks();
        };
        li.appendChild(btn);
      }
      tasksList.appendChild(li);
    });
  } catch (e) {
    tasksList.innerHTML = `<li class="muted">加载失败: ${escapeHtml(e.message)}</li>`;
  }
}

const STATUS_LABEL = { pending: '待办', in_progress: '进行中', done: '完成', skipped: '跳过' };

async function loadPlan() {
  try {
    const sid = sessionSelect.value || 'web';
    const data = await ctrl('plan', { sessionId: sid }, `/api/plan?sessionId=${encodeURIComponent(sid)}`);
    const steps = data.steps || data.plan?.steps || [];
    planList.innerHTML = '';
    if (steps.length === 0) { planList.innerHTML = '<li class="muted">暂无规划</li>'; return; }
    steps.forEach((s) => {
      const li = document.createElement('li');
      li.className = `plan-step plan-${s.status || 'pending'}`;
      const label = STATUS_LABEL[s.status] || s.status || '';
      li.innerHTML = `<span class="plan-id">${s.id}</span>` +
        `<span class="plan-title">${escapeHtml(s.title || '')}</span>` +
        `<span class="plan-status">${escapeHtml(label)}</span>`;
      planList.appendChild(li);
    });
  } catch (e) {
    planList.innerHTML = `<li class="muted">加载失败: ${escapeHtml(e.message)}</li>`;
  }
}

async function loadMetrics() {
  try {
    const raw = await ctrl('metrics', {}, '/api/metrics');
    const m = raw.metrics || raw;
    const rows = [
      ['ask 次数', m.askCount ?? m.ask_count ?? 0],
      ['成功', m.okCount ?? m.ok_count ?? 0],
      ['失败', m.errorCount ?? m.error_count ?? 0],
      ['工具调用', m.totalToolCalls ?? m.total_tool_calls ?? 0],
      ['平均耗时', `${m.avgDurationMs ?? m.avg_duration_ms ?? 0} ms`],
      ['总耗时', `${m.totalDurationMs ?? m.total_duration_ms ?? 0} ms`],
    ];
    metricsBox.innerHTML = rows.map(([k, v]) =>
      `<div class="metric-row"><span>${k}</span><strong>${escapeHtml(String(v))}</strong></div>`).join('');
  } catch (e) {
    metricsBox.innerHTML = `<div class="muted">加载失败: ${escapeHtml(e.message)}</div>`;
  }
}

async function loadAudit() {
  if (!auditList) return;
  try {
    const data = await ctrl('audit', {}, '/api/audit');
    const entries = data.entries || [];
    auditList.innerHTML = '';
    if (entries.length === 0) {
      auditList.innerHTML = '<li class="muted">暂无审计记录</li>';
      return;
    }
    entries.forEach((e) => {
      const li = document.createElement('li');
      const tool = e.tool || e.name || '?';
      const ts = e.timestamp || e.ts || '';
      const ok = e.ok === true || e.status === 'ok';
      li.innerHTML = `<span class="audit-tool">${escapeHtml(String(tool))}</span>` +
        `<span class="muted">${escapeHtml(String(ts))}</span>` +
        `<span class="audit-ok">${ok ? '✓' : '✗'}</span>`;
      auditList.appendChild(li);
    });
  } catch (e) {
    auditList.innerHTML = `<li class="muted">加载失败: ${escapeHtml(e.message)}</li>`;
  }
}

async function loadTools() {
  if (!toolsList) return;
  try {
    const data = await ctrl('tools', {}, '/api/tools');
    const tools = data.tools || [];
    toolsList.innerHTML = '';
    if (tools.length === 0) {
      toolsList.innerHTML = '<li class="muted">无工具</li>';
      return;
    }
    tools.forEach((t) => {
      const li = document.createElement('li');
      const name = typeof t === 'string' ? t : (t.name || t.tool || '?');
      li.textContent = name;
      toolsList.appendChild(li);
    });
  } catch (e) {
    toolsList.innerHTML = `<li class="muted">加载失败: ${escapeHtml(e.message)}</li>`;
  }
}

async function loadTokens() {
  if (!tokenBox) return;
  try {
    const s = await ctrl('tokenStats', {}, '/api/tokenStats');
    const rows = [
      ['输入 Token', s.inputTokens ?? s.promptTokens ?? 0],
      ['输出 Token', s.outputTokens ?? s.completionTokens ?? 0],
      ['总计', s.totalTokens ?? 0],
      ['请求次数', s.requestCount ?? s.calls ?? 0],
    ];
    tokenBox.innerHTML = rows.map(([k, v]) =>
      `<div class="metric-row"><span>${k}</span><strong>${escapeHtml(String(v))}</strong></div>`).join('') +
      `<button type="button" class="btn-muted btn-sm" id="btnResetTokens">重置统计</button>`;
    const btn = document.getElementById('btnResetTokens');
    if (btn) {
      btn.onclick = async () => {
        try {
          await ctrl('resetTokenStats', {}, '/api/tokenStats/reset', { method: 'POST', body: '{}' });
          loadTokens();
        } catch (err) {
          tokenBox.insertAdjacentHTML('beforeend', `<div class="muted">${escapeHtml(err.message)}</div>`);
        }
      };
    }
  } catch (e) {
    tokenBox.innerHTML = `<div class="muted">加载失败: ${escapeHtml(e.message)}</div>`;
  }
}

//==================================================================
// 记忆经验面板：.ali/db 白名单表；memories 支持按 kind 筛选/搜索
//==================================================================
let dbTable = 'memories';
let dbTablesCache = [];
let memKind = ''; // ''=全部；lesson/fact/note/preference/agentTurn…

const MEM_KIND_FILTERS = [
  { id: '', label: '全部' },
  { id: 'lesson', label: '经验' },
  { id: 'fact', label: '事实' },
  { id: 'note', label: '笔记' },
  { id: 'preference', label: '偏好' },
  { id: 'agentTurn', label: '对话整理' },
];

const MEM_KIND_LABEL = {
  lesson: '经验',
  fact: '事实',
  note: '笔记',
  preference: '偏好',
  agentTurn: '对话整理',
};

async function loadMemoryTab() {
  const btnRefresh = document.getElementById('btnMemRefresh');
  if (btnRefresh && !btnRefresh.dataset.bound) {
    btnRefresh.dataset.bound = '1';
    btnRefresh.addEventListener('click', () => loadMemoryTab());
  }
  const btnSearch = document.getElementById('btnMemSearch');
  if (btnSearch && !btnSearch.dataset.bound) {
    btnSearch.dataset.bound = '1';
    btnSearch.addEventListener('click', () => runDbRowsQuery());
  }
  const memQ = document.getElementById('memQ');
  if (memQ && !memQ.dataset.bound) {
    memQ.dataset.bound = '1';
    memQ.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') runDbRowsQuery();
    });
  }
  await refreshDbTableTabs();
  renderMemKindTabs();
  await runDbRowsQuery();
}

function renderMemKindTabs() {
  const wrap = document.getElementById('memKindTabs');
  if (!wrap) return;
  if (dbTable !== 'memories') {
    wrap.innerHTML = '';
    wrap.classList.add('hidden');
    return;
  }
  wrap.classList.remove('hidden');
  wrap.innerHTML = MEM_KIND_FILTERS.map((f) => {
    const active = (memKind || '') === f.id ? ' active' : '';
    return `<button type="button" class="btn-muted btn-xs mem-filter${active}" data-mem-kind="${escapeHtml(f.id)}">${escapeHtml(f.label)}</button>`;
  }).join('');
  wrap.querySelectorAll('[data-mem-kind]').forEach((btn) => {
    btn.addEventListener('click', () => {
      memKind = btn.getAttribute('data-mem-kind') || '';
      renderMemKindTabs();
      runDbRowsQuery();
    });
  });
}

async function refreshDbTableTabs() {
  const wrap = document.getElementById('dbTableTabs');
  if (!wrap) return;
  try {
    const data = await api('/api/db');
    if (data.status === 'error') throw new Error(data.reason || 'db list failed');
    dbTablesCache = data.tables || [];
    if (!dbTablesCache.some((t) => t.name === dbTable) && dbTablesCache[0]) {
      dbTable = dbTablesCache[0].name;
    }
    wrap.innerHTML = dbTablesCache.map((t) => {
      const active = t.name === dbTable ? ' active' : '';
      const title = escapeHtml(t.title || t.name);
      const count = t.count ?? 0;
      return `<button type="button" class="btn-muted btn-xs mem-filter${active}" data-db-table="${escapeHtml(t.name)}" title="${escapeHtml(t.why || '')}">${title} ${count}</button>`;
    }).join('');
    wrap.querySelectorAll('[data-db-table]').forEach((btn) => {
      btn.addEventListener('click', () => {
        dbTable = btn.getAttribute('data-db-table') || 'memories';
        memKind = '';
        const qEl = document.getElementById('memQ');
        if (qEl) qEl.value = '';
        refreshDbTableTabs();
        renderMemKindTabs();
        runDbRowsQuery();
      });
    });
    renderMemKindTabs();
  } catch (e) {
    wrap.innerHTML = `<span class="muted">表列表加载失败: ${escapeHtml(e.message)}</span>`;
  }
}

async function runDbRowsQuery() {
  const list = document.getElementById('memList');
  const meta = document.getElementById('memMeta');
  const whyEl = document.getElementById('memWhy');
  if (!list) return;
  list.classList.add('muted');
  list.textContent = '加载中…';
  const q = (document.getElementById('memQ')?.value || '').trim();
  try {
    let data;
    if (dbTable === 'memories') {
      const params = new URLSearchParams({ limit: '80' });
      if (q) params.set('q', q);
      if (memKind) params.set('kind', memKind);
      data = await api(`/api/memory?${params.toString()}`);
      if (data.status === 'error') throw new Error(data.reason || 'load failed');
      data = {
        ...data,
        title: memKind ? `记忆/经验 · ${MEM_KIND_LABEL[memKind] || memKind}` : '记忆/经验',
        why: '自动学习写入 memories：经验(lesson)、蒸馏事实、对话整理等。可用上方类型筛选 + 搜索。',
        name: 'memories',
        count: data.count ?? (data.items || []).length,
      };
    } else {
      const params = new URLSearchParams({ table: dbTable, limit: '80' });
      if (q) params.set('q', q);
      data = await api(`/api/db/rows?${params.toString()}`);
      if (data.status === 'error') throw new Error(data.reason || 'load failed');
    }
    const items = data.items || [];
    const title = data.title || dbTable;
    const total = data.count ?? items.length;
    if (meta) {
      const kindHint = (dbTable === 'memories' && memKind)
        ? ` · 筛选 ${MEM_KIND_LABEL[memKind] || memKind}`
        : '';
      meta.textContent = `${title} · 显示 ${items.length} / 共 ${total}${kindHint}`;
    }
    let why = data.why ? `为何存放：${data.why}` : '';
    if (dbTable === 'sessions' || dbTable === 'session_messages') {
      why += (why ? '。' : '')
        + '网页左侧历史在浏览器 localStorage；服务端活跃会话在内存。'
        + '下方会额外列出这两处，不单靠本表。';
    }
    if (whyEl) whyEl.textContent = why;

    const extraHtml = await renderLiveSessionExtras(dbTable, q);
    if (items.length === 0 && !extraHtml) {
      list.textContent = (dbTable === 'sessions' || dbTable === 'session_messages')
        ? 'SQLite 本表为空；若下方也没有「浏览器/服务端」卡片，说明当前没有可展示的会话。'
        : (dbTable === 'memories'
          ? (memKind ? `暂无「${MEM_KIND_LABEL[memKind] || memKind}」类记录；可换「全部」或改搜索词。` : '暂无记忆/经验。对话多轮后自动蒸馏，或点顶栏「蒸馏」。')
          : '此表暂无数据');
      list.classList.toggle('muted', true);
      if (extraHtml) {
        list.classList.remove('muted');
        list.innerHTML = extraHtml;
      }
      return;
    }
    list.classList.remove('muted');
    const dbCards = items.map((it) => renderDbRowCard(dbTable, it)).join('');
    const sectionLabel = dbTable === 'memories' ? 'SQLite · memories' : `SQLite · ${dbTable}`;
    list.innerHTML = extraHtml + (items.length
      ? `<div class="mem-section muted">${escapeHtml(sectionLabel)}</div>${dbCards}`
      : '');
    list.querySelectorAll('[data-forget-id]').forEach((btn) => {
      btn.addEventListener('click', async () => {
        const id = btn.getAttribute('data-forget-id');
        if (!id || !window.confirm(`删除记忆 #${id}？`)) return;
        try {
          const r = await api('/api/memory/forget', {
            method: 'POST',
            body: JSON.stringify({ id: Number(id) || id }),
          });
          if (r.status === 'error') throw new Error(r.reason || 'forget failed');
          await refreshDbTableTabs();
          await runDbRowsQuery();
        } catch (e) {
          if (meta) meta.textContent = `删除失败: ${e.message}`;
        }
      });
    });
  } catch (e) {
    list.classList.add('muted');
    list.textContent = `加载失败: ${e.message}`;
    if (meta) meta.textContent = '';
  }
}

async function renderLiveSessionExtras(table, q) {
  if (table !== 'sessions' && table !== 'session_messages') return '';
  const blocks = [];
  // 1) 浏览器本地历史（网页真正展示的对话）
  try {
    const chats = (localHistory?.chats || []).slice().sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0));
    const filtered = q
      ? chats.filter((c) => JSON.stringify(c).toLowerCase().includes(q.toLowerCase()))
      : chats;
    if (filtered.length) {
      blocks.push(`<div class="mem-section">浏览器 localStorage · ${filtered.length} 个对话</div>`);
      filtered.slice(0, 40).forEach((c) => {
        const msgs = c.messages || [];
        const preview = msgs.slice(-4).map((m) => `${m.role}: ${String(m.content || '').slice(0, 80)}`).join('\n');
        if (table === 'sessions') {
          blocks.push(renderExtraSessionCard({
            source: 'browser',
            id: c.id,
            title: c.title || '未命名',
            sid: c.sessionId || '-',
            count: msgs.length,
            updatedAt: c.updatedAt,
            preview,
          }));
        } else {
          msgs.slice(-30).forEach((m, i) => {
            blocks.push(renderExtraMessageCard({
              source: 'browser',
              chatId: c.id,
              sid: c.sessionId || '-',
              role: m.role,
              content: m.content,
              idx: i,
            }));
          });
        }
      });
    }
  } catch { /* ignore */ }

  // 2) 服务端活跃会话（内存）
  try {
    const data = await api('/api/sessions');
    const active = data.active || {};
    const ids = Object.keys(active);
    if (ids.length) {
      blocks.push(`<div class="mem-section">服务端内存 · ${ids.length} 个活跃会话</div>`);
      for (const id of ids.slice(0, 20)) {
        const snap = active[id] || {};
        let preview = '';
        let messages = [];
        try {
          const loaded = await api('/api/sessions/load', {
            method: 'POST',
            body: JSON.stringify({ sessionId: id }),
          });
          messages = loaded.messages || [];
          preview = messages.slice(-4).map((m) => `${m.role || '?'}: ${String(m.content || '').slice(0, 80)}`).join('\n');
        } catch { /* ignore */ }
        if (table === 'sessions') {
          blocks.push(renderExtraSessionCard({
            source: 'server',
            id,
            title: id,
            sid: id,
            count: messages.length || snap.messageCount || 0,
            updatedAt: snap.updatedAt,
            preview,
          }));
        } else {
          messages.slice(-30).forEach((m, i) => {
            blocks.push(renderExtraMessageCard({
              source: 'server',
              chatId: id,
              sid: id,
              role: m.role,
              content: m.content,
              idx: i,
            }));
          });
        }
      }
    }
  } catch { /* ignore */ }

  return blocks.join('');
}

function renderExtraSessionCard({ source, id, title, sid, count, updatedAt, preview }) {
  const srcLabel = source === 'browser' ? '浏览器' : '服务端';
  return `<article class="mem-card mem-card-live">
    <div class="mem-card-head">
      <span class="mem-kind">${escapeHtml(srcLabel)}</span>
      <span class="muted">${escapeHtml(String(title))} · sid=${escapeHtml(String(sid))} · ${count} 条消息</span>
      <span class="muted mem-time">${escapeHtml(formatMemoryTime(updatedAt))}</span>
    </div>
    <pre class="mem-body">${escapeHtml(preview || '(无预览)')}</pre>
  </article>`;
}

function renderExtraMessageCard({ source, chatId, sid, role, content, idx }) {
  const srcLabel = source === 'browser' ? '浏览器' : '服务端';
  let body = content;
  if (body != null && typeof body !== 'string') {
    try { body = JSON.stringify(body, null, 2); } catch { body = String(body); }
  }
  body = String(body || '');
  const preview = body.length > 1000 ? `${body.slice(0, 1000)}…` : body;
  return `<article class="mem-card mem-card-live">
    <div class="mem-card-head">
      <span class="mem-kind">${escapeHtml(String(role || 'msg'))}</span>
      <span class="muted">${escapeHtml(srcLabel)} · ${escapeHtml(String(chatId))} · sid=${escapeHtml(String(sid))} · #${idx}</span>
    </div>
    <pre class="mem-body">${escapeHtml(preview)}</pre>
  </article>`;
}

function renderDbRowCard(table, it) {
  if (table === 'memories') return renderMemoryCard(it);
  const id = it.id ?? it.module ?? it.session_id ?? it.hour ?? '';
  const headBits = [];
  if (it.kind != null) headBits.push(String(it.kind));
  if (it.verdict != null) headBits.push(`verdict=${it.verdict}`);
  if (it.status != null) headBits.push(String(it.status));
  if (it.tool != null) headBits.push(String(it.tool));
  if (it.scenario_type != null) headBits.push(String(it.scenario_type));
  if (it.module != null) headBits.push(String(it.module));
  if (it.session_id != null || it.sessionId != null) {
    headBits.push(`sid=${it.session_id ?? it.sessionId}`);
  }
  const ts = formatMemoryTime(it.created_at ?? it.updated_at ?? it.hour ?? it.createdAt ?? it.updatedAt);
  let bodyObj = { ...it };
  // 卡片正文略去已在标题展示的短字段，突出长文本
  ['id'].forEach((k) => { delete bodyObj[k]; });
  let body;
  try { body = JSON.stringify(bodyObj, null, 2); } catch { body = String(it); }
  const preview = body.length > 1600 ? `${body.slice(0, 1600)}…` : body;
  return `<article class="mem-card">
    <div class="mem-card-head">
      <span class="mem-kind">${escapeHtml(headBits[0] || table)}</span>
      <span class="muted">#${escapeHtml(String(id))} ${escapeHtml(headBits.slice(1).join(' · '))}</span>
      <span class="muted mem-time">${escapeHtml(ts)}</span>
    </div>
    <pre class="mem-body">${escapeHtml(preview)}</pre>
  </article>`;
}

function renderMemoryCard(it) {
  const id = it.id ?? it.Id ?? '';
  const kind = String(it.kind || 'note');
  const kindLabel = MEM_KIND_LABEL[kind] || kind;
  const sid = it.session_id ?? it.sessionId ?? '-';
  const tags = Array.isArray(it.tags) ? it.tags : [];
  const scope = it.scope || '';
  const ts = formatMemoryTime(it.created_at ?? it.createdAt);
  let body = it.content;
  if (body != null && typeof body !== 'string') {
    try { body = JSON.stringify(body, null, 2); } catch { body = String(body); }
  }
  body = String(body || '');
  const preview = body.length > 1200 ? `${body.slice(0, 1200)}…` : body;
  const tagHtml = tags.map((t) => `<span class="mem-tag">${escapeHtml(String(t))}</span>`).join('');
  const kindClass = kind === 'lesson' ? ' mem-kind-lesson' : '';
  return `<article class="mem-card${kind === 'lesson' ? ' mem-card-lesson' : ''}">
    <div class="mem-card-head">
      <span class="mem-kind${kindClass}" title="${escapeHtml(kind)}">${escapeHtml(kindLabel)}</span>
      <span class="muted">#${escapeHtml(String(id))} · ${escapeHtml(String(sid))}${scope ? ` · ${escapeHtml(String(scope))}` : ''}</span>
      <span class="muted mem-time">${escapeHtml(ts)}</span>
      <button type="button" class="btn-muted btn-xs" data-forget-id="${escapeHtml(String(id))}">删除</button>
    </div>
    <div class="mem-tags">${tagHtml}</div>
    <pre class="mem-body">${escapeHtml(preview)}</pre>
  </article>`;
}

function formatMemoryTime(ts) {
  if (ts == null || ts === '') return '-';
  const n = Number(ts);
  if (!Number.isFinite(n)) return String(ts);
  const ms = n > 1e12 ? n : n * 1000;
  try {
    return new Date(ms).toLocaleString();
  } catch {
    return String(ts);
  }
}

//==================================================================
// 知识库面板（浏览 / 搜索 .ali/knowledge）
//==================================================================
let knSubView = 'overview';

function loadKnowledgeTab() {
  document.querySelectorAll('.kn-sub').forEach((btn) => {
    btn.classList.toggle('active', btn.dataset.kn === knSubView);
    if (!btn.dataset.bound) {
      btn.dataset.bound = '1';
      btn.addEventListener('click', () => {
        knSubView = btn.dataset.kn || 'overview';
        loadKnowledgeTab();
      });
    }
  });
  renderKnowledgeForm();
  runKnowledgeQuery();
}

function setKnMeta(text) {
  const el = document.getElementById('knMeta');
  if (el) el.textContent = text || '';
}

function setKnResult(htmlOrText, isHtml) {
  const el = document.getElementById('knResult');
  if (!el) return;
  el.classList.remove('muted');
  if (isHtml) el.innerHTML = htmlOrText;
  else el.textContent = htmlOrText;
}

function knEsc(s) {
  return escapeHtml(String(s ?? ''));
}

function renderKnowledgeForm() {
  const form = document.getElementById('knForm');
  if (!form) return;
  const views = {
    overview: () => `<button type="button" class="btn-muted btn-xs" id="btnKnRun">刷新概览</button>
      <button type="button" class="btn-muted btn-xs" id="btnKnRebuild">重建知识库</button>
      <span class="muted">.ali/knowledge 状态</span>`,
    search: () => `<input class="core-q" id="knQ" placeholder="搜索模块 / 动作 / 表 / 摘要…" value="" autocomplete="off">
      <input id="knLimit" placeholder="limit" value="30" style="max-width:64px">
      <button type="button" class="btn-muted btn-xs" id="btnKnRun">搜索</button>`,
    map: () => `<input class="core-q" id="knQ" placeholder="过滤模块名 / 摘要" value="" autocomplete="off">
      <button type="button" class="btn-muted btn-xs" id="btnKnRun">列出模块</button>
      <span class="muted">摘要多为导出函数列表；LLM 摘要需 warmLlm</span>`,
    actions: () => `<input class="core-q" id="knQ" placeholder="过滤短语 / MFA" value="" autocomplete="off">
      <button type="button" class="btn-muted btn-xs" id="btnKnRun">列出动作</button>`,
    data: () => `<input class="core-q" id="knQ" placeholder="过滤表名" value="" autocomplete="off">
      <button type="button" class="btn-muted btn-xs" id="btnKnRun">列出数据表</button>`,
    summaries: () => `<input class="core-q" id="knQ" placeholder="过滤主题" value="" autocomplete="off">
      <button type="button" class="btn-muted btn-xs" id="btnKnRun">列出主题</button>
      <span class="muted">对话验证后 saveKnowledge 写入</span>`,
    agent: () => `<button type="button" class="btn-muted btn-xs" id="btnKnRun">查看提示词</button>
      <span class="muted">agent.json liveData*Keywords</span>`,
  };
  form.innerHTML = (views[knSubView] || views.overview)();
  const run = document.getElementById('btnKnRun');
  if (run) run.addEventListener('click', () => runKnowledgeQuery());
  const q = document.getElementById('knQ');
  if (q) {
    q.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        runKnowledgeQuery();
      }
    });
  }
  const rebuild = document.getElementById('btnKnRebuild');
  if (rebuild) {
    rebuild.addEventListener('click', async () => {
      setKnMeta('重建中…');
      setKnResult('正在构建项目知识库…', false);
      try {
        const data = await api('/api/digest/build', { method: 'POST', body: '{}' });
        if (data.status === 'ok') {
          const m = data.meta || {};
          const n = m.summaryCount ?? m.moduleCount ?? '?';
          const discovered = m.discoveredCount != null ? ` / 发现 ${m.discoveredCount}` : '';
          setKnMeta(`重建完成 · modules ${n}${discovered}`);
          knSubView = 'overview';
          loadKnowledgeTab();
        } else {
          setKnResult(`重建失败: ${JSON.stringify(data.reason || data)}`, false);
        }
      } catch (e) {
        setKnResult(`重建异常: ${e.message || e}`, false);
      }
    });
  }
}

function knHitCard(hit) {
  const kind = hit.kind || hit.layer || 'hit';
  const score = hit.score != null ? ` · score ${hit.score}` : '';
  const title = hit.module || hit.phrase || hit.table || hit.topic || hit.mfa || kind;
  const bits = [];
  if (hit.mfa) bits.push(`MFA ${hit.mfa}`);
  if (hit.phrase && hit.phrase !== title) bits.push(hit.phrase);
  if (hit.summary) bits.push(hit.summary);
  if (hit.file) bits.push(hit.file);
  if (hit.note) bits.push(hit.note);
  if (hit.source) bits.push(`source=${hit.source}`);
  if (hit.exportCount != null) bits.push(`${hit.exportCount} exports`);
  if (hit.callerCount != null) bits.push(`${hit.callerCount} callers`);
  const body = bits.map((b) => knEsc(typeof b === 'string' ? b : JSON.stringify(b))).join('<br>');
  const topicBtn = hit.topic
    ? `<button type="button" class="btn-muted btn-xs kn-open-summary" data-topic="${knEsc(hit.topic)}">打开</button>`
    : '';
  const askBtn = title
    ? `<button type="button" class="btn-muted btn-xs kn-ask" data-q="${knEsc(String(title))}">问助手</button>`
    : '';
  return `<div class="kn-card" data-kind="${knEsc(kind)}">
    <div class="kn-card-head"><span class="kn-kind">${knEsc(kind)}</span>
      <strong>${knEsc(title)}</strong><span class="muted">${knEsc(score)}</span>
      <span class="kn-card-actions">${topicBtn}${askBtn}</span></div>
    <div class="kn-card-body">${body || '<span class="muted">（无更多字段）</span>'}</div>
  </div>`;
}

function bindKnCardActions(root) {
  root?.querySelectorAll('.kn-open-summary').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const topic = btn.dataset.topic;
      if (!topic) return;
      try {
        const data = await api(`/api/digest/summary?topic=${encodeURIComponent(topic)}`);
        if (data.status !== 'ok') {
          setKnResult(`读取失败: ${JSON.stringify(data.reason || data)}`, false);
          return;
        }
        setKnMeta(`摘要 · ${topic} · ${data.bytes || 0} bytes`);
        setKnResult(`<pre class="kn-pre">${knEsc(data.content || '')}</pre>`, true);
      } catch (e) {
        setKnResult(String(e.message || e), false);
      }
    });
  });
  root?.querySelectorAll('.kn-ask').forEach((btn) => {
    btn.addEventListener('click', () => {
      const q = btn.dataset.q;
      if (!q || !promptEl) return;
      promptEl.value = `关于知识库条目「${q}」，请结合 .ali/knowledge 说明含义与相关 MFA`;
      promptEl.focus();
    });
  });
}

async function runKnowledgeQuery() {
  const meta = document.getElementById('knMeta');
  const result = document.getElementById('knResult');
  if (!result) return;
  setKnMeta('加载中…');
  try {
    if (knSubView === 'overview') {
      const data = await api('/api/digest/browse?layer=overview');
      if (data.status === 'error') throw new Error(JSON.stringify(data.reason || data));
      const m = data.meta || {};
      const files = data.files || {};
      setKnMeta(data.ready
        ? `ready · ${data.path || ''} · modules=${m.moduleCount ?? '-'} actions=${m.actionCount ?? '-'} tables=${m.tableCount ?? '-'}`
        : `未构建 · ${data.path || ''} · 可点「重建知识库」`);
      const fileRows = Object.keys(files).map((k) =>
        `<li><code>${knEsc(k)}</code> ${files[k] ? '✓' : '—'}</li>`).join('');
      const kw = (data.agentHints?.liveDataKeywords || []).slice(0, 24).map(knEsc).join(', ');
      const op = (data.agentHints?.liveDataOpKeywords || []).slice(0, 16).map(knEsc).join(', ');
      const modSum = data.moduleSummaryCount ?? data.meta?.summaryCount ?? 0;
      const topicSum = data.topicSummaryCount ?? data.summaryCount ?? 0;
      setKnResult(`<div class="kn-overview">
        <div class="kn-card"><div class="kn-card-head"><strong>状态</strong></div>
          <div class="kn-card-body">ready=${data.ready ? 'true' : 'false'}<br>
          模块摘要=${modSum} · 主题摘要=${topicSum}<br>
          liveDataKeywords=${data.liveDataKeywordCount ?? 0} · ops=${data.liveDataOpKeywordCount ?? 0}</div></div>
        <div class="kn-card"><div class="kn-card-head"><strong>各层含义</strong></div>
          <div class="kn-card-body kn-layer-help">
            <div><b>模块</b> — 每个 .erl 的摘要（默认=导出函数名）</div>
            <div><b>动作</b> — 自然语言短语 → MFA 映射</div>
            <div><b>数据表</b> — ETS/表 与调用方</div>
            <div><b>主题摘要</b> — 对话验证过的业务说明（需 saveKnowledge）</div>
            <div><b>提示词</b> — agent.json 活数据关键词</div>
          </div></div>
        <div class="kn-card"><div class="kn-card-head"><strong>文件</strong></div>
          <div class="kn-card-body"><ul class="kn-file-list">${fileRows || '<li class="muted">无</li>'}</ul></div></div>
        <div class="kn-card"><div class="kn-card-head"><strong>agent 关键词（预览）</strong></div>
          <div class="kn-card-body"><div><b>实体</b> ${kw || '<span class="muted">空</span>'}</div>
          <div style="margin-top:6px"><b>操作</b> ${op || '<span class="muted">空</span>'}</div></div></div>
      </div>`, true);
      return;
    }

    if (knSubView === 'search') {
      const q = document.getElementById('knQ')?.value?.trim() || '';
      const limit = document.getElementById('knLimit')?.value || '30';
      if (!q) {
        setKnMeta('请输入关键词');
        setKnResult('输入业务词 / 模块名 / 表名后搜索', false);
        return;
      }
      const data = await api(`/api/digest/search?q=${encodeURIComponent(q)}&limit=${encodeURIComponent(limit)}`);
      if (data.status === 'error') throw new Error(JSON.stringify(data.reason || data));
      const hits = data.hits || [];
      setKnMeta(`搜索「${q}」· ${hits.length} 条`);
      if (!hits.length) {
        setKnResult('无命中 — 可先重建知识库，或换关键词', false);
        return;
      }
      setKnResult(`<div class="kn-list">${hits.map(knHitCard).join('')}</div>`, true);
      bindKnCardActions(result);
      return;
    }

    if (knSubView === 'agent') {
      const data = await api('/api/digest/browse?layer=agent');
      if (data.status === 'error') throw new Error(JSON.stringify(data.reason || data));
      const ents = (data.liveDataKeywords || []).map((k) => `<li><code>${knEsc(k)}</code></li>`).join('');
      const ops = (data.liveDataOpKeywords || []).map((k) => `<li><code>${knEsc(k)}</code></li>`).join('');
      const emptyHint = (!(data.liveDataKeywords || []).length && !(data.liveDataOpKeywords || []).length)
        ? '<div class="kn-note muted">关键词为空：可编辑 .ali/knowledge/agent.json 手工添加，或参考 priv/examples/knowledge/agent.json.example；重建知识库会合并 ETS 表名等自动候选。</div>'
        : '';
      setKnMeta(`agent.json · ${data.path || ''} · updatedAt=${data.updatedAt ?? '-'}`);
      setKnResult(`<div class="kn-overview">
        <div class="kn-card"><div class="kn-card-head"><strong>liveDataKeywords</strong>
          <span class="muted">${(data.liveDataKeywords || []).length}</span></div>
          <div class="kn-card-body"><ul class="kn-chip-list">${ents || '<li class="muted">空</li>'}</ul></div></div>
        <div class="kn-card"><div class="kn-card-head"><strong>liveDataOpKeywords</strong>
          <span class="muted">${(data.liveDataOpKeywords || []).length}</span></div>
          <div class="kn-card-body"><ul class="kn-chip-list">${ops || '<li class="muted">空</li>'}</ul></div></div>
        <div class="muted kn-note">${knEsc(data.note || '')}</div>
        ${emptyHint}
      </div>`, true);
      return;
    }

    const layer = knSubView;
    const q = document.getElementById('knQ')?.value?.trim() || '';
    const qs = new URLSearchParams({ layer, limit: '100', offset: '0' });
    if (q) qs.set('q', q);
    const data = await api(`/api/digest/browse?${qs.toString()}`);
    if (data.status === 'error') throw new Error(JSON.stringify(data.reason || data));
    const items = data.items || [];
    setKnMeta(`${layer} · 共 ${data.total ?? items.length} · 显示 ${items.length}${q ? ` · 过滤「${q}」` : ''}`);
    if (!items.length) {
      if (layer === 'summaries') {
        setKnResult(
          '暂无主题摘要。这一层不是自动生成的项目文档，而是对话里验证过的业务说明（saveKnowledge 写入 summaries/*.md）。'
          + ' 模块级说明请看「模块」页；重建知识库不会填充此处。',
          false,
        );
      } else {
        setKnResult('暂无条目 — 请先「重建知识库」或调整过滤', false);
      }
      return;
    }
    if (layer === 'summaries') {
      setKnResult(`<div class="kn-list">${items.map((it) => knHitCard({
        kind: 'summary', topic: it.topic, bytes: it.bytes, file: it.path,
      })).join('')}</div>`, true);
      bindKnCardActions(result);
      return;
    }
    if (layer === 'actions') {
      setKnResult(`<div class="kn-list">${items.map((it) => knHitCard({
        kind: 'action', phrase: it.phrase, mfa: it.mfa, note: it.note, source: it.source,
      })).join('')}</div>`, true);
      bindKnCardActions(result);
      return;
    }
    if (layer === 'data') {
      setKnResult(`<div class="kn-list">${items.map((it) => {
        const callers = (it.callers || []).slice(0, 6).map((c) => {
          if (typeof c === 'string') return c;
          return c.mfa || JSON.stringify(c);
        }).join(', ');
        return knHitCard({
          kind: 'data', table: it.table, callerCount: it.callerCount, summary: callers,
        });
      }).join('')}</div>`, true);
      bindKnCardActions(result);
      return;
    }
    // map / api
    setKnResult(`<div class="kn-list">${items.map((it) => knHitCard({
      kind: layer,
      module: it.module,
      summary: it.summary || (it.exportCount != null ? `${it.exportCount} exports` : ''),
      file: it.file,
      exportCount: it.exportCount,
    })).join('')}</div>`, true);
    bindKnCardActions(result);
  } catch (e) {
    const msg = String(e.message || e);
    if (msg === 'notFound') {
      setKnMeta('API 不可用');
      setKnResult(
        '知识库浏览接口未加载（运行中的节点可能是旧代码）。请重启 ali，或在会话中执行 hotReload：alWebHandler、alProjectDigest。',
        false,
      );
    } else {
      setKnMeta('出错');
      setKnResult(msg, false);
    }
  }
}

//==================================================================
// aliCore 数据面板（校验索引 / 符号 / 调用图）
//==================================================================
let coreSubView = 'status';

function loadCoreTab() {
  document.querySelectorAll('.core-sub').forEach((btn) => {
    btn.classList.toggle('active', btn.dataset.core === coreSubView);
    if (!btn.dataset.bound) {
      btn.dataset.bound = '1';
      btn.addEventListener('click', () => {
        coreSubView = btn.dataset.core || 'status';
        loadCoreTab();
      });
    }
  });
  renderCoreForm();
  runCoreQuery();
}

function renderCoreForm() {
  const form = document.getElementById('coreForm');
  if (!form) return;
  const views = {
    status: () => `<button type="button" class="btn-muted btn-xs" id="btnCoreRun">刷新状态</button>
      <button type="button" class="btn-muted btn-xs" id="btnCoreReindex">重解析索引</button>
      <button type="button" class="btn-muted btn-xs" id="btnCoreDigest">重建知识库</button>
      <span class="muted">health / index / knowledge</span>`,
    modules: () => `<input class="core-q" id="coreQ" placeholder="过滤模块名/路径，如 alAgent" value="">
      <button type="button" class="btn-muted btn-xs" id="btnCoreRun">查询模块</button>`,
    search: () => `<input class="core-q" id="coreQ" placeholder="搜索关键词，如 ask" value="">
      <input id="coreLimit" placeholder="limit" value="20" style="max-width:64px">
      <button type="button" class="btn-muted btn-xs" id="btnCoreRun">搜索</button>`,
    module: () => `<input id="coreModule" placeholder="模块 alAgent" value="alAgent">
      <button type="button" class="btn-muted btn-xs" id="btnCoreRun">查符号</button>
      <span class="muted">看 remoteCallCount</span>`,
    callers: () => `<input id="coreModule" placeholder="模块" value="alAgent">
      <input id="coreFunction" placeholder="函数" value="run">
      <input id="coreArity" placeholder="元数" title="arity，参数个数" value="2" style="max-width:56px">
      <select id="coreGraphDir" class="btn-muted btn-xs" title="双向=被调用+调用别人同图">
        <option value="both">双向调用链</option>
        <option value="callers">被谁调用</option>
        <option value="callees">它调用谁</option>
      </select>
      <button type="button" class="btn-muted btn-xs" id="btnCoreRun">查询</button>
      <button type="button" class="btn-muted btn-xs" id="btnCoreOpenGraph" title="在图窗口打开">开图</button>`,
  };
  form.innerHTML = (views[coreSubView] || views.status)();
  const run = document.getElementById('btnCoreRun');
  if (run) run.addEventListener('click', () => runCoreQuery());
  const btnDigest = document.getElementById('btnCoreDigest');
  if (btnDigest) {
    btnDigest.addEventListener('click', async () => {
      setCoreResult('正在构建项目知识库（.ali/knowledge）…', '');
      try {
        const data = await api('/api/digest/build', { method: 'POST', body: '{}' });
        if (data.status === 'ok') {
          setCoreResult('知识库构建完成', JSON.stringify(data.meta || data, null, 2));
        } else {
          setCoreResult('知识库构建失败', JSON.stringify(data, null, 2));
        }
      } catch (e) {
        setCoreResult('知识库构建异常', String(e.message || e));
      }
    });
  }
  const openGraph = document.getElementById('btnCoreOpenGraph');
  if (openGraph) {
    openGraph.addEventListener('click', () => {
      const module = document.getElementById('coreModule')?.value?.trim() || '';
      const functionName = document.getElementById('coreFunction')?.value?.trim() || '';
      const arity = Number(document.getElementById('coreArity')?.value);
      const dir = document.getElementById('coreGraphDir')?.value || 'both';
      // 同步到图页表单
      const gm = document.getElementById('graphMfaModule');
      const gf = document.getElementById('graphMfaFunction');
      const ga = document.getElementById('graphMfaArity');
      const gd = document.getElementById('graphMfaDir');
      if (gm) gm.value = module;
      if (gf) gf.value = functionName;
      if (ga) ga.value = String(arity);
      if (gd) gd.value = dir;
      if (sidePanel?.classList.contains('hidden')) sidePanel.classList.remove('hidden');
      selectSideTab('graphs');
      runGraphMfaQuery({ module, function: functionName, arity, dir });
    });
  }
  const reindex = document.getElementById('btnCoreReindex');
  if (reindex) {
    reindex.addEventListener('click', async () => {
      setCoreResult('正在触发全量重解析索引…', '');
      try {
        const data = await api('/api/index/refresh?force=true', { method: 'POST', body: '{}' });
        setCoreResult(data, data.status === 'ok' ? '已触发 force reparse，请稍后刷新状态' : '触发失败');
      } catch (e) {
        setCoreResult(`错误: ${e.message}`, '失败');
      }
    });
  }
  form.querySelectorAll('input').forEach((inp) => {
    inp.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        runCoreQuery();
      }
    });
  });
}

function setCoreResult(obj, metaText) {
  const el = document.getElementById('coreResult');
  const meta = document.getElementById('coreMeta');
  if (meta) meta.textContent = metaText || '';
  if (!el) return;
  el.classList.remove('core-result-graph');
  if (typeof obj === 'string') {
    el.textContent = obj;
    return;
  }
  el.textContent = JSON.stringify(obj, null, 2);
}

/** Core「调用」：结果区只渲染调用链图，不 dump JSON/mermaid 源码 */
function setCoreCallGraph(payload, metaText) {
  const el = document.getElementById('coreResult');
  const meta = document.getElementById('coreMeta');
  if (meta) meta.textContent = metaText || '';
  if (!el) return;
  el.classList.add('core-result-graph');
  el.textContent = '';
  const mermaid = payload?.mermaid;
  if (!mermaid || !String(mermaid).trim()) {
    el.classList.remove('core-result-graph');
    el.textContent = '无调用边';
    return;
  }
  const wrap = renderMermaidBlock(String(mermaid));
  el.appendChild(wrap);
  // 点击节点时用 briefs/edges 展示简述
  const fakeGraph = {
    mermaid,
    edges: payload.edges || [],
    briefs: payload.briefs || {},
    query: { mfa: payload.mfa, direction: payload.direction },
  };
  wrap.addEventListener('click', (ev) => {
    const node = ev.target.closest?.('svg .node, svg g.node');
    if (!node) return;
    const label = (node.textContent || '').replace(/\s+/g, ' ').trim();
    const fromTexts = Array.from(node.querySelectorAll('text, span, div'))
      .map((n) => (n.textContent || '').trim())
      .find((t) => t && t.includes(':') && t.includes('/'));
    const mfa = parseMfaLabel(label) || parseMfaLabel(fromTexts || '');
    if (!mfa || !meta) return;
    const brief = (fakeGraph.briefs || {})[mfa.label];
    meta.textContent = `${metaText || ''} · 选中 ${mfa.label}${brief ? ` — ${brief}` : ''}`;
  });
}

function summarizeCoreStatus(data) {
  const idx = data.index || {};
  const health = data.health || {};
  const stale = idx.stale_call_extract_docs ?? idx.staleCallExtractDocs;
  const lines = [
    `available=${data.available}`,
    `ready=${idx.ready ?? health.index_ready}`,
    `indexing=${idx.indexing ?? health.indexing}`,
    `phase=${idx.phase || '-'}`,
    `files=${idx.files ?? health.index_files}`,
    `symbols=${idx.symbols ?? health.index_symbols}`,
    `callExtractV=${idx.call_extract_version ?? idx.callExtractVersion ?? '?'}`,
    stale != null ? `staleDocs=${stale}` : null,
    `last_error=${idx.last_error || idx.lastError || '-'}`,
  ].filter(Boolean);
  if (stale > 0) {
    lines.push('⚠ 调用图仍是旧缓存：点「重解析索引」或 /index restart');
  }
  return lines.join(' · ');
}

function summarizeModules(data) {
  const d = data.data || data;
  return `匹配 ${d.total ?? '?'} · 展示 ${(d.modules || []).length}`
    + ` · 调用边 ${d.call_edges_total ?? '?'}`
    + ` · 远程边 ${d.remote_calls_total ?? '?'}`
    + ((d.remote_calls_total === 0 && (d.call_edges_total || 0) > 0)
      ? ' ⚠ 远程调用为 0，索引可能丢了 M:F 模块名'
      : '');
}

async function runCoreQuery() {
  const pre = document.getElementById('coreResult');
  if (pre) {
    pre.classList.remove('core-result-graph');
    pre.textContent = '查询中…';
  }
  try {
    if (coreSubView === 'status') {
      const data = await api('/api/core/status');
      setCoreResult(data, summarizeCoreStatus(data));
      return;
    }
    if (coreSubView === 'modules') {
      const q = document.getElementById('coreQ')?.value?.trim() || '';
      const qs = new URLSearchParams({ limit: '100', offset: '0' });
      if (q) qs.set('q', q);
      const data = await api(`/api/core/modules?${qs}`);
      if (data.status === 'error') throw new Error(formatErrorReason(data.reason));
      setCoreResult(data.data || data, summarizeModules(data));
      return;
    }
    if (coreSubView === 'search') {
      const query = document.getElementById('coreQ')?.value?.trim() || '';
      const limit = Number(document.getElementById('coreLimit')?.value || 20) || 20;
      if (!query) {
        setCoreResult('请输入搜索词');
        return;
      }
      const data = await api('/api/core/search', {
        method: 'POST',
        body: JSON.stringify({ query, limit }),
      });
      if (data.status === 'error') throw new Error(formatErrorReason(data.reason));
      const hits = data.data?.hits || data.hits || [];
      setCoreResult(data.data || data, `命中 ${hits.length} 条`);
      return;
    }
    if (coreSubView === 'module') {
      const module = document.getElementById('coreModule')?.value?.trim() || '';
      if (!module) {
        setCoreResult('请输入模块名');
        return;
      }
      const data = await api('/api/core/module', {
        method: 'POST',
        body: JSON.stringify({ module, maxCalls: 80 }),
      });
      if (data.status === 'error') throw new Error(formatErrorReason(data.reason));
      const doc = data.data?.document || data.data || {};
      const meta = `functions=${(doc.functions || []).length}`
        + ` exports=${(doc.exports || []).length}`
        + ` calls=${doc.callCount ?? (doc.calls || []).length}`
        + ` remote=${doc.remoteCallCount ?? '?'}`
        + (doc.file ? ` · ${doc.file}` : '');
      setCoreResult(data.data || data, meta);
      return;
    }
    if (coreSubView === 'callers') {
      const module = document.getElementById('coreModule')?.value?.trim() || '';
      const functionName = document.getElementById('coreFunction')?.value?.trim() || '';
      const arity = Number(document.getElementById('coreArity')?.value);
      const dir = document.getElementById('coreGraphDir')?.value || 'both';
      if (!functionName || !Number.isFinite(arity)) {
        setCoreResult('请填写 function 与 arity');
        return;
      }
      const endpoint = dir === 'callees' ? 'callees' : 'callers';
      const data = await api(`/api/core/${endpoint}`, {
        method: 'POST',
        body: JSON.stringify({
          module: module || null,
          function: functionName,
          arity,
          maxEdges: 80,
          direction: dir,
        }),
      });
      if (data.status === 'error') throw new Error(formatErrorReason(data.reason));
      const payload = data.data || data;
      const edgeCount = payload.edgeCount ?? (payload.edges || []).length;
      const shown = payload.mermaidEdgeCount ?? (payload.edges || []).length;
      const mfa = payload.mfa || `${module || '?'}:${functionName}/${arity}`;
      const dirLabel = callGraphDirLabel(dir);
      const briefN = payload.briefs ? Object.keys(payload.briefs).length : 0;
      const meta = `${dirLabel} ${mfa} · 边 ${shown}/${edgeCount}`
        + (briefN ? ` · 简述 ${briefN}` : '')
        + (payload.truncated ? ' · 已截断' : '')
        + (edgeCount === 0 && (dir === 'callers' || dir === 'both')
          ? ' ⚠ 空：若刚修过远程调用提取，请重启节点并 /index restart'
          : '');
      setCoreCallGraph(payload, meta);
    }
  } catch (e) {
    setCoreResult(`错误: ${e.message}`, '失败');
  }
}

//==================================================================
// 文件树 / 会话列表 / Checkpoint 恢复
//==================================================================

// 由扁平相对路径列表构建嵌套树节点：{name, path, dir, children}
// listFiles 的 wildcard 可能同时返回目录与文件；若某路径先作为「文件」入树，
// 再出现其子路径时必须提升为目录，否则 cur.children 为 undefined 会炸。
function buildFileTree(entries) {
  const root = { name: '.', path: '', dir: true, children: [] };
  (entries || []).forEach((rel) => {
    const raw = (rel && typeof rel === 'object') ? (rel.path ?? rel.name ?? rel) : rel;
    const relStr = String(raw ?? '').replace(/\\/g, '/').replace(/^\.\//, '').replace(/\/+$/, '');
    if (!relStr || relStr === '.') return;
    const parts = relStr.split('/').filter(Boolean);
    let cur = root;
    let curPath = '';
    parts.forEach((part, idx) => {
      curPath = curPath ? `${curPath}/${part}` : part;
      const isLast = idx === parts.length - 1;
      if (!Array.isArray(cur.children)) cur.children = [];
      let child = cur.children.find((c) => c.name === part);
      if (!child) {
        child = { name: part, path: curPath, dir: !isLast, children: [] };
        cur.children.push(child);
      } else if (!isLast) {
        // 同名节点曾被标成文件：提升为目录以便继续挂载
        child.dir = true;
        if (!Array.isArray(child.children)) child.children = [];
      }
      // 勿把已是目录的节点降级成文件（目录条目后于子文件出现时）
      cur = child;
    });
  });
  const sortChildren = (node) => {
    if (!node.children) return;
    node.children.sort((a, b) => {
      if (a.dir !== b.dir) return a.dir ? -1 : 1;
      return a.name.localeCompare(b.name, 'zh-CN');
    });
    node.children.forEach(sortChildren);
  };
  sortChildren(root);
  return root;
}

// 渲染文件树节点。目录默认折叠，点击目录展开/收起，
// 点击文件打开独立查看器。
function renderFileTree(tree) {
  if (!filesTree) return;
  filesTree.innerHTML = '';
  const rootUl = document.createElement('ul');
  rootUl.className = 'file-tree file-root';
  const renderNode = (node, container, depth, open) => {
    const li = document.createElement('li');
    li.className = 'file-node';
    const row = document.createElement('div');
    row.className = `file-row${node.dir ? ' file-dir' : ' file-file'}`;
    row.style.paddingLeft = `${depth * 14 + 4}px`;
    if (node.dir) {
      row.innerHTML = `<span class="file-caret">${open ? '▾' : '▸'}</span><span class="file-ico">📁</span>`;
      const label = document.createElement('span');
      label.className = 'file-name';
      label.textContent = node.name;
      label.title = node.path;
      row.appendChild(label);
      row.addEventListener('click', () => {
        const childUl = li.querySelector(':scope > ul');
        if (childUl) {
          const isOpen = !childUl.classList.contains('hidden');
          childUl.classList.toggle('hidden', isOpen);
          row.querySelector('.file-caret').textContent = isOpen ? '▸' : '▾';
        }
      });
      li.appendChild(row);
      if (node.children && node.children.length > 0) {
        const childUl = document.createElement('ul');
        childUl.className = `file-tree${open ? '' : ' hidden'}`;
        node.children.forEach((c) => renderNode(c, childUl, depth + 1, false));
        li.appendChild(childUl);
      }
    } else {
      row.innerHTML = '<span class="file-ico">📄</span>';
      const label = document.createElement('span');
      label.className = 'file-name';
      label.textContent = node.name;
      label.title = node.path;
      row.appendChild(label);
      if (selectedFilePath && selectedFilePath === node.path) {
        row.classList.add('selected');
      }
      row.addEventListener('click', () => openFileViewer(node.path, row));
      li.appendChild(row);
    }
    container.appendChild(li);
  };
  (tree.children || []).forEach((c) => renderNode(c, rootUl, 0, false));
  if (!tree.children || tree.children.length === 0) {
    rootUl.innerHTML = '<li class="muted">（空目录）</li>';
  }
  filesTree.appendChild(rootUl);
}

function applyFileViewerZoom() {
  if (fileViewerBody) fileViewerBody.style.fontSize = `${(13 * fileViewerZoomPct) / 100}px`;
  if (fileViewerZoom) fileViewerZoom.textContent = `${fileViewerZoomPct}%`;
}

function loadFileViewerGeom() {
  try {
    const raw = localStorage.getItem(FV_POS_KEY);
    if (!raw) return null;
    const g = JSON.parse(raw);
    if (!g || typeof g !== 'object') return null;
    return g;
  } catch {
    return null;
  }
}

/** 默认：铺满 AI 对话框左侧空白列（与 CSS --chat-max-px 主栏对齐） */
function defaultFileViewerGeom() {
  const vw = window.innerWidth;
  const vh = window.innerHeight;
  const raw = getComputedStyle(document.documentElement).getPropertyValue('--chat-max-px').trim();
  const parsed = Number.parseFloat(raw);
  const chatMax = Number.isFinite(parsed) ? Math.min(parsed, vw - 24) : Math.min(1050, vw - 24);
  const margin = 8;
  const leftGutter = Math.max(0, (vw - chatMax) / 2);
  let width = Math.floor(leftGutter - margin * 2);
  if (width < 300) {
    // 窄屏左侧空档不够时，仍靠左占约 36% 宽
    width = Math.max(280, Math.min(Math.floor(vw * 0.36), 420));
  }
  width = Math.max(280, Math.min(width, vw - margin * 2));
  const height = Math.max(240, vh - margin * 2);
  return {
    left: margin,
    top: margin,
    width,
    height,
    zoom: 100,
  };
}

function currentFileViewerGeom() {
  if (!fileViewerPanel) return null;
  const r = fileViewerPanel.getBoundingClientRect();
  return {
    left: r.left,
    top: r.top,
    width: r.width,
    height: r.height,
    zoom: fileViewerZoomPct,
  };
}

function saveFileViewerGeom() {
  if (!fileViewer || !fileViewerPanel) return;
  if (fileViewer.classList.contains('hidden')) return;
  if (fileViewer.classList.contains('is-fullscreen')) return;
  const g = currentFileViewerGeom();
  if (!g) return;
  try {
    localStorage.setItem(FV_POS_KEY, JSON.stringify(g));
  } catch { /* ignore quota */ }
}

function applyFileViewerGeom(geom) {
  if (!fileViewerPanel) return;
  const base = defaultFileViewerGeom();
  const g = geom && typeof geom === 'object' ? geom : base;
  const vw = window.innerWidth;
  const vh = window.innerHeight;
  let width = Number(g.width);
  let height = Number(g.height);
  if (!Number.isFinite(width) || width <= 0) width = base.width;
  if (!Number.isFinite(height) || height <= 0) height = base.height;
  width = Math.max(280, Math.min(width, vw - 8));
  height = Math.max(240, Math.min(height, vh - 8));
  let left = g.left != null && Number.isFinite(Number(g.left)) ? Number(g.left) : base.left;
  let top = g.top != null && Number.isFinite(Number(g.top)) ? Number(g.top) : base.top;
  left = Math.max(0, Math.min(left, vw - 80));
  top = Math.max(0, Math.min(top, vh - 40));
  fileViewerPanel.style.left = `${left}px`;
  fileViewerPanel.style.top = `${top}px`;
  fileViewerPanel.style.width = `${width}px`;
  fileViewerPanel.style.height = `${height}px`;
  if (typeof g.zoom === 'number' && g.zoom >= 60 && g.zoom <= 240) {
    fileViewerZoomPct = g.zoom;
  } else if (!geom) {
    fileViewerZoomPct = 100;
  }
  applyFileViewerZoom();
}

function enterFileViewerEdit() {
  if (fileViewerEditing) return;
  if (!selectedFilePath) return;
  if (fileViewerIsBinary) { setStatus('二进制文件无法编辑'); return; }
  if (fileViewerTruncated) { setStatus('文件已截断，为避免数据丢失已禁用内联编辑'); return; }
  if (!fileViewerEditor || !fileViewerBody) return;
  fileViewerEditing = true;
  fileViewerEditor.value = fileViewerText;
  fileViewerEditor.classList.remove('hidden');
  fileViewerBody.classList.add('hidden');
  const searchBar = fileViewer?.querySelector('.file-viewer-search');
  if (searchBar) searchBar.classList.add('hidden');
  if (btnFvEdit) { btnFvEdit.textContent = '保存'; btnFvEdit.title = '保存修改（Ctrl+S）'; }
  if (btnFvEditCancel) btnFvEditCancel.classList.remove('hidden');
  fileViewerEditor.focus();
  setStatus(`正在编辑 ${selectedFilePath}`);
}

function exitFileViewerEdit() {
  if (!fileViewerEditing) return;
  fileViewerEditing = false;
  if (fileViewerEditor) fileViewerEditor.classList.add('hidden');
  if (fileViewerBody) fileViewerBody.classList.remove('hidden');
  const searchBar = fileViewer?.querySelector('.file-viewer-search');
  if (searchBar) searchBar.classList.remove('hidden');
  if (btnFvEdit) { btnFvEdit.textContent = '编辑'; btnFvEdit.title = '编辑文件内容'; }
  if (btnFvEditCancel) btnFvEditCancel.classList.add('hidden');
}

async function saveFileViewerEdit() {
  if (!fileViewerEditing || !selectedFilePath) return;
  const path = selectedFilePath;
  const content = fileViewerEditor?.value ?? '';
  if (btnFvEdit) btnFvEdit.disabled = true;
  try {
    const data = await api('/api/file', {
      method: 'PUT',
      body: JSON.stringify({ path, content }),
    });
    if (data?.status === 'error') {
      const reason = data.reason || data.error || '保存失败';
      throw new Error(typeof reason === 'string' ? reason : JSON.stringify(reason));
    }
    fileViewerText = content;
    exitFileViewerEdit();
    renderFileViewerBody();
    setStatus(`已保存 ${path}（${data?.bytes ?? content.length} 字节）`);
  } catch (e) {
    setStatus(`保存失败: ${e.message}`);
  } finally {
    if (btnFvEdit) btnFvEdit.disabled = false;
  }
}

function closeFileViewer() {
  if (!fileViewer) return;
  exitFileViewerEdit();
  saveFileViewerGeom();
  fileViewer.classList.add('hidden');
  fileViewer.classList.remove('is-fullscreen');
  if (btnFvFullscreen) btnFvFullscreen.textContent = '全屏';
  fvDragState = null;
  if (fileViewerDrag) fileViewerDrag.classList.remove('dragging');
  clearFileViewerSearch(true);
}

function clearFileViewerSearch(resetInput) {
  fvSearchHits = [];
  fvSearchIndex = -1;
  if (resetInput && fileViewerSearch) fileViewerSearch.value = '';
  if (fileViewerSearchCount) fileViewerSearchCount.textContent = '0/0';
}

function collectFileViewerHits(text, query, caseSensitive) {
  if (!text || !query) return [];
  const hits = [];
  if (caseSensitive) {
    let from = 0;
    while (from <= text.length) {
      const idx = text.indexOf(query, from);
      if (idx < 0) break;
      hits.push({ start: idx, end: idx + query.length });
      from = idx + Math.max(1, query.length);
      if (hits.length >= FV_SEARCH_MAX_HITS) break;
    }
  } else {
    const src = text.toLowerCase();
    const q = query.toLowerCase();
    let from = 0;
    while (from <= src.length) {
      const idx = src.indexOf(q, from);
      if (idx < 0) break;
      hits.push({ start: idx, end: idx + query.length });
      from = idx + Math.max(1, query.length);
      if (hits.length >= FV_SEARCH_MAX_HITS) break;
    }
  }
  return hits;
}

//==================================================================
// 文件查看器：轻量语法着色（按扩展名，无外部依赖）
//==================================================================

const FV_HIGHLIGHT_MAX = 400000;
const FV_LANG_BY_EXT = {
  erl: 'erlang', hrl: 'erlang',
  js: 'js', mjs: 'js', cjs: 'js', jsx: 'js',
  ts: 'ts', tsx: 'ts',
  json: 'json',
  md: 'md', markdown: 'md',
  html: 'html', htm: 'html', xml: 'xml', svg: 'xml',
  css: 'css', scss: 'css', less: 'css',
  py: 'python',
  rs: 'rust',
  go: 'go',
  java: 'java', kt: 'java',
  c: 'c', h: 'c', cpp: 'cpp', cc: 'cpp', cxx: 'cpp', hpp: 'cpp',
  sh: 'shell', bash: 'shell', zsh: 'shell',
  yaml: 'yaml', yml: 'yaml',
  toml: 'toml',
  sql: 'sql',
  rb: 'ruby',
  php: 'php',
  lua: 'lua',
  conf: 'conf', cfg: 'conf', ini: 'conf',
};

function detectFileViewerLang(path) {
  const m = String(path || '').match(/\.([^.\\/]+)$/);
  return FV_LANG_BY_EXT[(m?.[1] || '').toLowerCase()] || 'text';
}

function fvSpan(cls, text) {
  return `<span class="${cls}">${escapeHtml(text)}</span>`;
}

function highlightWithRules(text, rules) {
  if (!text) return '';
  const re = new RegExp(rules.map((r) => `(${r.re})`).join('|'), 'gm');
  let out = '';
  let last = 0;
  let m;
  while ((m = re.exec(text)) !== null) {
    if (m.index > last) out += escapeHtml(text.slice(last, m.index));
    const matched = m[0];
    let cls = null;
    for (let i = 0; i < rules.length; i++) {
      if (m[i + 1] != null) {
        cls = rules[i].cls;
        break;
      }
    }
    out += cls ? fvSpan(cls, matched) : escapeHtml(matched);
    last = m.index + matched.length;
    if (matched.length === 0) re.lastIndex++;
  }
  if (last < text.length) out += escapeHtml(text.slice(last));
  return out;
}

function fileViewerHighlightRules(lang) {
  const strDq = String.raw`"(?:[^"\\]|\\.)*"`;
  const strSq = String.raw`'(?:[^'\\]|\\.)*'`;
  const strBtRe = '`(?:[^`\\\\]|\\\\.)*`';
  const lineCm = String.raw`//[^\n]*`;
  const blockCm = String.raw`/\*[\s\S]*?\*/`;
  const hashCm = String.raw`#[^\n]*`;
  const num = String.raw`\b(?:0x[0-9a-fA-F]+|\d+\.?\d*(?:[eE][+-]?\d+)?)\b`;

  // 答案区兜底：路径 / MFA / 字符串 / 关键字，保证无语言标签也有颜色
  if (lang === 'generic') {
    return [
      { re: String.raw`%[^\n]*`, cls: 'fv-cm' },
      { re: hashCm, cls: 'fv-cm' },
      { re: lineCm, cls: 'fv-cm' },
      { re: strDq, cls: 'fv-str' },
      { re: strSq, cls: 'fv-str' },
      { re: strBtRe, cls: 'fv-str' },
      { re: String.raw`\b[A-Za-z_][\w]*:[A-Za-z_][\w]*(?:\/\d+)?\b`, cls: 'fv-fn' },
      { re: String.raw`(?:[A-Za-z]:)?(?:[\\/][\w.\-]+)+\.[\w]+\b`, cls: 'fv-meta' },
      { re: String.raw`\b[\w.\-]+\.(?:erl|hrl|js|ts|json|md|yaml|yml|css|html|rs|py|go|sql|toml|cfg|conf)\b`, cls: 'fv-meta' },
      { re: String.raw`\b(?:true|false|null|ok|error|undefined|noreply|stop)\b`, cls: 'fv-kw' },
      { re: String.raw`\b(?:GET|POST|PUT|DELETE|PATCH)\b`, cls: 'fv-kw' },
      { re: num, cls: 'fv-num' },
    ];
  }

  if (lang === 'erlang') {
    return [
      { re: String.raw`%[^\n]*`, cls: 'fv-cm' },
      { re: String.raw`"(?:[^"\\]|\\.)*"`, cls: 'fv-str' },
      { re: String.raw`\$\\?.`, cls: 'fv-str' },
      { re: String.raw`-[a-z][a-zA-Z0-9_]*`, cls: 'fv-meta' },
      { re: String.raw`\b(?:after|and|andalso|band|begin|bnot|bor|bsl|bsr|bxor|case|catch|cond|div|end|fun|if|let|not|of|or|orelse|query|receive|rem|try|when|xor)\b`, cls: 'fv-kw' },
      { re: String.raw`\b(?:true|false|undefined|ok|error|noreply|stop|hibernate)\b`, cls: 'fv-atom' },
      { re: String.raw`\?[A-Z][A-Za-z0-9_]*`, cls: 'fv-macro' },
      { re: String.raw`\b[A-Z_][A-Za-z0-9_]*\b`, cls: 'fv-var' },
      { re: String.raw`\b[a-z][a-zA-Z0-9_]*\b`, cls: 'fv-atom' },
      { re: num, cls: 'fv-num' },
    ];
  }
  if (lang === 'json') {
    return [
      { re: strDq, cls: 'fv-str' },
      { re: String.raw`\b(?:true|false|null)\b`, cls: 'fv-kw' },
      { re: num, cls: 'fv-num' },
    ];
  }
  if (lang === 'md') {
    return [
      { re: String.raw`^#{1,6}[^\n]*`, cls: 'fv-kw' },
      { re: '```[\\s\\S]*?```', cls: 'fv-str' },
      { re: '`[^`\\n]+`', cls: 'fv-str' },
      { re: String.raw`\*\*[^*]+\*\*|__[^_]+__`, cls: 'fv-kw' },
      { re: String.raw`^\s*[-*+]\s+`, cls: 'fv-meta' },
      { re: String.raw`\[(?:[^\]]+)\]\((?:[^)]+)\)`, cls: 'fv-fn' },
    ];
  }
  if (lang === 'html' || lang === 'xml') {
    return [
      { re: String.raw`<!--[\s\S]*?-->`, cls: 'fv-cm' },
      { re: String.raw`</?[a-zA-Z][\w:-]*`, cls: 'fv-kw' },
      { re: String.raw`[a-zA-Z_:][\w:.-]*(?=\s*=)`, cls: 'fv-attr' },
      { re: strDq, cls: 'fv-str' },
      { re: strSq, cls: 'fv-str' },
    ];
  }
  if (lang === 'css') {
    return [
      { re: blockCm, cls: 'fv-cm' },
      { re: strDq, cls: 'fv-str' },
      { re: strSq, cls: 'fv-str' },
      { re: String.raw`#[\w-]+|\.[\w-]+`, cls: 'fv-fn' },
      { re: String.raw`@[\w-]+`, cls: 'fv-meta' },
      { re: String.raw`\b(?:color|background|display|flex|grid|margin|padding|border|font|width|height|position|top|left|right|bottom|z-index|opacity|overflow|align|justify|gap|content)\b`, cls: 'fv-kw' },
      { re: num, cls: 'fv-num' },
    ];
  }
  if (lang === 'yaml' || lang === 'toml' || lang === 'conf') {
    return [
      { re: hashCm, cls: 'fv-cm' },
      { re: strDq, cls: 'fv-str' },
      { re: strSq, cls: 'fv-str' },
      { re: String.raw`^\s*[A-Za-z0-9_.-]+\s*(?=:|=)`, cls: 'fv-attr' },
      { re: String.raw`\b(?:true|false|yes|no|on|off|null)\b`, cls: 'fv-kw' },
      { re: num, cls: 'fv-num' },
    ];
  }
  if (lang === 'shell') {
    return [
      { re: hashCm, cls: 'fv-cm' },
      { re: strDq, cls: 'fv-str' },
      { re: strSq, cls: 'fv-str' },
      { re: String.raw`\$\{?[\w@*#?$!-]+\}?`, cls: 'fv-var' },
      { re: String.raw`\b(?:if|then|else|elif|fi|for|while|do|done|case|esac|function|return|exit|export|local|readonly|source|alias)\b`, cls: 'fv-kw' },
      { re: num, cls: 'fv-num' },
    ];
  }
  if (lang === 'sql') {
    return [
      { re: String.raw`--[^\n]*`, cls: 'fv-cm' },
      { re: blockCm, cls: 'fv-cm' },
      { re: strSq, cls: 'fv-str' },
      { re: strDq, cls: 'fv-str' },
      { re: String.raw`\b(?:SELECT|FROM|WHERE|AND|OR|NOT|INSERT|INTO|VALUES|UPDATE|SET|DELETE|CREATE|TABLE|INDEX|JOIN|LEFT|RIGHT|INNER|OUTER|ON|AS|ORDER|BY|GROUP|HAVING|LIMIT|OFFSET|DISTINCT|NULL|PRIMARY|KEY|FOREIGN|REFERENCES|ALTER|DROP|VIEW|UNION|ALL|IN|IS|BETWEEN|LIKE|EXISTS|CASE|WHEN|THEN|ELSE|END)\b`, cls: 'fv-kw' },
      { re: num, cls: 'fv-num' },
    ];
  }

  const kwMaps = {
    js: String.raw`\b(?:async|await|break|case|catch|class|const|continue|debugger|default|delete|do|else|export|extends|finally|for|function|if|import|in|instanceof|let|new|of|return|static|super|switch|this|throw|try|typeof|var|void|while|with|yield|true|false|null|undefined)\b`,
    ts: String.raw`\b(?:async|await|break|case|catch|class|const|continue|debugger|default|delete|do|else|export|extends|finally|for|function|if|import|in|instanceof|interface|type|enum|implements|private|public|protected|readonly|let|new|of|return|static|super|switch|this|throw|try|typeof|var|void|while|with|yield|true|false|null|undefined|as|from|keyof|infer|never|unknown|any|string|number|boolean)\b`,
    python: String.raw`\b(?:and|as|assert|async|await|break|class|continue|def|del|elif|else|except|False|finally|for|from|global|if|import|in|is|lambda|None|nonlocal|not|or|pass|raise|return|True|try|while|with|yield)\b`,
    rust: String.raw`\b(?:as|async|await|break|const|continue|crate|dyn|else|enum|extern|false|fn|for|if|impl|in|let|loop|match|mod|move|mut|pub|ref|return|self|Self|static|struct|super|trait|true|type|unsafe|use|where|while)\b`,
    go: String.raw`\b(?:break|case|chan|const|continue|default|defer|else|fallthrough|for|func|go|goto|if|import|interface|map|package|range|return|select|struct|switch|type|var|true|false|nil|iota)\b`,
    java: String.raw`\b(?:abstract|assert|boolean|break|byte|case|catch|char|class|const|continue|default|do|double|else|enum|extends|final|finally|float|for|goto|if|implements|import|instanceof|int|interface|long|native|new|package|private|protected|public|return|short|static|strictfp|super|switch|synchronized|this|throw|throws|transient|try|void|volatile|while|true|false|null)\b`,
    c: String.raw`\b(?:auto|break|case|char|const|continue|default|do|double|else|enum|extern|float|for|goto|if|inline|int|long|register|restrict|return|short|signed|sizeof|static|struct|switch|typedef|union|unsigned|void|volatile|while)\b`,
    cpp: String.raw`\b(?:alignas|alignof|and|and_eq|asm|auto|bitand|bitor|bool|break|case|catch|char|class|compl|const|constexpr|continue|decltype|default|delete|do|double|else|enum|explicit|export|extern|false|float|for|friend|goto|if|inline|int|long|mutable|namespace|new|noexcept|not|not_eq|nullptr|operator|or|or_eq|private|protected|public|register|reinterpret_cast|return|short|signed|sizeof|static|static_cast|struct|switch|template|this|throw|true|try|typedef|typeid|typename|union|unsigned|using|virtual|void|volatile|wchar_t|while|xor|xor_eq)\b`,
    ruby: String.raw`\b(?:alias|and|begin|break|case|class|def|defined|do|else|elsif|end|ensure|false|for|if|in|module|next|nil|not|or|redo|rescue|retry|return|self|super|then|true|undef|unless|until|when|while|yield)\b`,
    php: String.raw`\b(?:abstract|and|array|as|break|callable|case|catch|class|clone|const|continue|declare|default|do|echo|else|elseif|empty|enddeclare|endfor|endforeach|endif|endswitch|endwhile|eval|exit|extends|final|finally|fn|for|foreach|function|global|goto|if|implements|include|include_once|instanceof|insteadof|interface|isset|list|match|namespace|new|or|print|private|protected|public|readonly|require|require_once|return|static|throw|trait|try|unset|use|var|while|xor|yield|true|false|null)\b`,
    lua: String.raw`\b(?:and|break|do|else|elseif|end|false|for|function|goto|if|in|local|nil|not|or|repeat|return|then|true|until|while)\b`,
  };

  const kw = kwMaps[lang] || kwMaps.js;
  const useHash = lang === 'python' || lang === 'ruby';
  const rules = [];
  if (useHash) rules.push({ re: hashCm, cls: 'fv-cm' });
  rules.push({ re: blockCm, cls: 'fv-cm' });
  rules.push({ re: lineCm, cls: 'fv-cm' });
  rules.push({ re: strBtRe, cls: 'fv-str' });
  rules.push({ re: strDq, cls: 'fv-str' });
  rules.push({ re: strSq, cls: 'fv-str' });
  rules.push({ re: kw, cls: 'fv-kw' });
  rules.push({ re: num, cls: 'fv-num' });
  return rules;
}

function highlightFileViewerText(text, path) {
  const lang = detectFileViewerLang(path);
  if (lang === 'text' || !text) return escapeHtml(text || '');
  const rules = fileViewerHighlightRules(lang);
  if (!rules.length) return escapeHtml(text);
  if (text.length <= FV_HIGHLIGHT_MAX) {
    return highlightWithRules(text, rules);
  }
  const head = text.slice(0, FV_HIGHLIGHT_MAX);
  const rest = text.slice(FV_HIGHLIGHT_MAX);
  return `${highlightWithRules(head, rules)}${escapeHtml(rest)}`;
}

/** 带行号的文件 HTML（主窗 / 弹出窗共用）。hits 为全文偏移搜索结果。 */
function buildFileViewerLinedHtml(text, path, hits) {
  const raw = String(text ?? '');
  const lines = raw.split('\n');
  const useHits = Array.isArray(hits) && hits.length > 0;
  let offset = 0;
  let html = '<div class="fv-code">';
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const n = i + 1;
    const lineStart = offset;
    let content;
    if (useHits) content = renderFileViewerLineWithHits(line, lineStart, hits);
    else content = highlightFileViewerText(line, path);
    if (!content) content = ' ';
    html += `<div class="fv-line" data-line="${n}"><span class="fv-lc">${content}</span></div>`;
    offset = lineStart + line.length + 1;
  }
  html += '</div>';
  return { html, lineCount: lines.length };
}

function renderFileViewerLineWithHits(line, lineStart, hits) {
  const lineEnd = lineStart + line.length;
  let html = '';
  let cursor = 0;
  let touched = false;
  hits.forEach((hit, i) => {
    if (hit.end <= lineStart || hit.start >= lineEnd) return;
    touched = true;
    const hs = Math.max(0, hit.start - lineStart);
    const he = Math.min(line.length, hit.end - lineStart);
    if (hs > cursor) html += escapeHtml(line.slice(cursor, hs));
    const cls = i === fvSearchIndex ? 'fv-hit fv-hit-active' : 'fv-hit';
    html += `<mark class="${cls}" data-fv-i="${i}">${escapeHtml(line.slice(hs, he))}</mark>`;
    cursor = he;
  });
  if (!touched) return escapeHtml(line) || ' ';
  if (cursor < line.length) html += escapeHtml(line.slice(cursor));
  return html || ' ';
}

function countFileViewerLines(text) {
  if (text == null || text === '') return 0;
  return String(text).split('\n').length;
}

function renderFileViewerBody() {
  if (!fileViewerBody) return;
  const text = fileViewerText;
  const query = (fileViewerSearch?.value || '').trim();
  if (!text) {
    fileViewerBody.textContent = '（空文件）';
    clearFileViewerSearch(false);
    return;
  }
  if (!query) {
    const { html } = buildFileViewerLinedHtml(text, selectedFilePath, null);
    fileViewerBody.innerHTML = html;
    fvSearchHits = [];
    fvSearchIndex = -1;
    if (fileViewerSearchCount) fileViewerSearchCount.textContent = '0/0';
    return;
  }
  const caseSensitive = !!(fileViewerSearchCase && fileViewerSearchCase.checked);
  fvSearchHits = collectFileViewerHits(text, query, caseSensitive);
  if (fvSearchIndex < 0 || fvSearchIndex >= fvSearchHits.length) fvSearchIndex = 0;
  const { html } = buildFileViewerLinedHtml(text, selectedFilePath, fvSearchHits);
  fileViewerBody.innerHTML = html;
  if (fvSearchHits.length === 0) {
    fvSearchIndex = -1;
    if (fileViewerSearchCount) fileViewerSearchCount.textContent = '0/0';
    return;
  }
  updateFileViewerSearchCount();
  scrollFileViewerHitIntoView();
}

function updateFileViewerSearchCount() {
  if (!fileViewerSearchCount) return;
  if (!fvSearchHits.length) {
    fileViewerSearchCount.textContent = '0/0';
    return;
  }
  const cur = fvSearchIndex + 1;
  const extra = fvSearchHits.length >= FV_SEARCH_MAX_HITS ? '+' : '';
  fileViewerSearchCount.textContent = `${cur}/${fvSearchHits.length}${extra}`;
}

function scrollFileViewerHitIntoView() {
  if (!fileViewerBody || fvSearchIndex < 0) return;
  const el = fileViewerBody.querySelector(`mark.fv-hit[data-fv-i="${fvSearchIndex}"]`);
  if (el) el.scrollIntoView({ block: 'center', inline: 'nearest' });
}

function stepFileViewerSearch(delta) {
  if (!fvSearchHits.length) {
    renderFileViewerBody();
    if (!fvSearchHits.length) return;
  }
  fvSearchIndex = (fvSearchIndex + delta + fvSearchHits.length) % fvSearchHits.length;
  // 只更新 active class，避免大文件每次整页重绘
  fileViewerBody?.querySelectorAll('mark.fv-hit').forEach((m) => {
    const i = Number(m.getAttribute('data-fv-i'));
    m.classList.toggle('fv-hit-active', i === fvSearchIndex);
  });
  updateFileViewerSearchCount();
  scrollFileViewerHitIntoView();
}

function runFileViewerSearch() {
  fvSearchIndex = 0;
  renderFileViewerBody();
}

async function copyTextToClipboard(text) {
  const value = text ?? '';
  if (!value) throw new Error('无内容可复制');
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(value);
    return;
  }
  const ta = document.createElement('textarea');
  ta.value = value;
  ta.style.position = 'fixed';
  ta.style.opacity = '0';
  document.body.appendChild(ta);
  ta.select();
  document.execCommand('copy');
  ta.remove();
}

function normalizeFilePayload(data, relPath) {
  if (data?.result && (data.result.content != null || data.result.binary != null)) {
    return normalizeFilePayload(data.result, relPath);
  }
  const content = data?.content ?? '';
  return {
    path: data?.path || relPath,
    content: typeof content === 'string' ? content : String(content ?? ''),
    binary: !!data?.binary,
    truncated: !!data?.truncated,
    totalBytes: data?.totalBytes,
  };
}

async function fetchFileContent(relPath) {
  const q = `path=${encodeURIComponent(relPath)}&maxBytes=${FILE_VIEW_MAX_BYTES}`;
  const attempts = [
    async () => api(`/api/files?content=true&${q}`),
    async () => api(`/api/file?${q}`),
    async () => api('/tool', {
      method: 'POST',
      body: JSON.stringify({
        tool: 'readFile',
        args: { path: relPath, maxBytes: FILE_VIEW_MAX_BYTES },
      }),
    }),
  ];
  let lastErr = null;
  for (const run of attempts) {
    try {
      const data = await run();
      if (data?.status === 'error') {
        lastErr = new Error(
          typeof data.reason === 'string' ? data.reason : JSON.stringify(data.reason || data.error || 'error')
        );
        continue;
      }
      if (data && (data.content != null || data.binary || data.result)) {
        return normalizeFilePayload(data, relPath);
      }
    } catch (e) {
      lastErr = e;
    }
  }
  throw lastErr || new Error('无法读取文件');
}

async function openFileViewer(relPath, rowEl, lineNo) {
  selectedFilePath = relPath;
  closeThinkingViewer();
  if (filesTree) {
    filesTree.querySelectorAll('.file-row.selected').forEach((el) => el.classList.remove('selected'));
  }
  if (rowEl) rowEl.classList.add('selected');
  if (!fileViewer) return;

  fileViewer.classList.remove('hidden');
  fileViewer.classList.remove('is-fullscreen');
  if (btnFvFullscreen) btnFvFullscreen.textContent = '全屏';
  applyFileViewerGeom(loadFileViewerGeom() || defaultFileViewerGeom());
  if (fileViewerTitle) {
    fileViewerTitle.textContent = lineNo ? `${relPath}:${lineNo}` : relPath;
    fileViewerTitle.title = relPath;
  }
  if (fileViewerMeta) fileViewerMeta.textContent = '加载中…';
  if (fileViewerBody) fileViewerBody.textContent = '加载中…';
  fileViewerText = '';
  fileViewerIsBinary = false;
  fileViewerTruncated = false;
  clearFileViewerSearch(true);
  fileViewerBody?.focus();

  try {
    const data = await fetchFileContent(relPath);
    fileViewerIsBinary = !!data.binary;
    fileViewerTruncated = !!data.truncated;
    if (data.binary) {
      const size = data.totalBytes != null ? `${data.totalBytes} bytes` : '';
      fileViewerText = '';
      if (fileViewerBody) fileViewerBody.textContent = `（二进制文件，无法以文本预览）${size ? ` ${size}` : ''}`;
      if (fileViewerMeta) fileViewerMeta.textContent = size || 'binary';
      setStatus(`已打开 ${relPath}（二进制）`);
      return;
    }
    let text = data.content || '';
    const lineCount = countFileViewerLines(text);
    const bits = [];
    bits.push(`${lineCount} 行`);
    if (data.totalBytes != null) bits.push(`${data.totalBytes} bytes`);
    const lang = detectFileViewerLang(relPath);
    if (lang && lang !== 'text') bits.push(lang);
    if (data.truncated) bits.push('已截断至 5MB');
    if (lineNo) bits.push(`定位 L${lineNo}`);
    if (fileViewerMeta) fileViewerMeta.textContent = bits.join(' · ') || '就绪';
    if (data.truncated) text += `\n\n…（已截断，最大预览 5MB）`;
    fileViewerText = text;
    renderFileViewerBody();
    if (lineNo) scrollFileViewerToLine(lineNo);
    setStatus(`已打开 ${relPath}`);
  } catch (e) {
    fileViewerText = '';
    if (fileViewerBody) fileViewerBody.textContent = `加载失败: ${e.message}`;
    if (fileViewerMeta) fileViewerMeta.textContent = '错误';
    setStatus(`打开失败: ${e.message}`);
  }
}

function scrollFileViewerToLine(lineNo) {
  const n = Number(lineNo);
  if (!fileViewerBody || !Number.isFinite(n) || n < 1) return;
  fileViewerBody.querySelectorAll('.fv-line.fv-line-target').forEach((el) => {
    el.classList.remove('fv-line-target');
  });
  const el = fileViewerBody.querySelector(`.fv-line[data-line="${n}"]`);
  if (el) {
    el.classList.add('fv-line-target');
    el.scrollIntoView({ block: 'center', behavior: 'smooth' });
    return;
  }
  const lh = Math.max(12, (13 * fileViewerZoomPct) / 100 * 1.5);
  fileViewerBody.scrollTop = Math.max(0, (n - 1) * lh - 48);
}

async function loadFiles() {
  if (!filesTree) return;
  try {
    const data = await api('/api/files?path=.&recursive=true');
    const entries = data.entries || [];
    const rootShown = data.projectRoot || '.';
    if (filesRootLabel) {
      filesRootLabel.textContent = `根: ${rootShown}  (agent.projectRoot)`;
    }
    if (data.truncated) {
      renderFileTree(buildFileTree(entries));
      const note = document.createElement('div');
      note.className = 'muted side-note';
      note.textContent = `条目过多，仅显示前 ${entries.length} 个`;
      filesTree.appendChild(note);
    } else {
      renderFileTree(buildFileTree(entries));
    }
    if (entries.length === 0) {
      const hint = document.createElement('div');
      hint.className = 'muted side-note';
      hint.textContent =
        `无可列文件。当前根=${rootShown}；已忽略 _build/.git/.ali 等。` +
        `请改 aliCfg.cfg 的 agent.projectRoot 后 alConfig:load() 再刷新。`;
      filesTree.appendChild(hint);
    }
  } catch (e) {
    if (filesRootLabel) filesRootLabel.textContent = '';
    filesTree.innerHTML = `<div class="muted">加载失败: ${escapeHtml(e.message)}</div>`;
  }
}

// 会话列表：活跃 worker + 已保存快照。点击切换会话（复用 sessionSelect 逻辑）。
async function loadSessionsList() {
  if (!activeSessionsList || !savedSessionsList) return;
  const renderList = (ul, items, { active = false } = {}) => {
    ul.innerHTML = '';
    if (!items || items.length === 0) {
      ul.innerHTML = '<li class="muted">（无）</li>';
      return;
    }
    items.forEach((id) => {
      const li = document.createElement('li');
      li.className = 'session-item';
      const label = document.createElement('span');
      label.className = `session-name${id === currentSessionId() ? ' session-current' : ''}`;
      label.textContent = id;
      label.title = id;
      if (active) label.textContent += '（活跃）';
      li.appendChild(label);
      if (id !== currentSessionId()) {
        const btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'btn-muted btn-xs';
        btn.textContent = '切换';
        btn.onclick = () => switchSession(id);
        li.appendChild(btn);
      }
      ul.appendChild(li);
    });
  };
  try {
    const data = await api('/api/sessions');
    // active 为 {SessionId => snapshot} 映射（服务端 alServer:sessions/0）
    const activeIds = Array.isArray(data.active) ? data.active : Object.keys(data.active || {});
    renderList(activeSessionsList, activeIds, { active: true });
    renderList(savedSessionsList, data.saved || []);
  } catch (e) {
    activeSessionsList.innerHTML = `<li class="muted">加载失败: ${escapeHtml(e.message)}</li>`;
    savedSessionsList.innerHTML = '';
  }
}

async function switchSession(sid) {
  if (!sid || sid === currentSessionId()) return;
  const existing = localHistory.chats.find((c) => c.id === sid);
  if (existing) {
    openLocalChat(sid);
  } else {
    const now = Date.now();
    localHistory.chats.unshift({
      id: sid,
      title: sid,
      messages: [],
      graphs: [],
      createdAt: now,
      updatedAt: now,
    });
    localHistory.activeId = sid;
    lhSave();
    lhEnsureSessionOption(sid);
    closeGraphViewer();
    chat.innerHTML = '';
    restoreGraphsFromLocal([]);
    setStatus('就绪');
  }
  setTimeout(() => loadSessionsList(), 500);
}

function formatSavedAt(ts) {
  if (!ts) return '';
  const d = new Date(Number(ts));
  if (Number.isNaN(d.getTime())) return '';
  const pad = (n) => String(n).padStart(2, '0');
  return `${d.getMonth() + 1}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

// 待恢复 checkpoint 列表：显示任务 id、pending 工具与参数摘要，支持恢复/删除。
async function loadCheckpoints() {
  if (!checkpointsList) return;
  try {
    const data = await api('/api/checkpoints');
    const items = data.checkpoints || [];
    checkpointsList.innerHTML = '';
    if (items.length === 0) {
      checkpointsList.innerHTML = '<li class="muted">无可恢复任务</li>';
      return;
    }
    items.forEach((c) => {
      const li = document.createElement('li');
      li.className = 'checkpoint-item';
      const head = document.createElement('div');
      head.className = 'checkpoint-head';
      const idSpan = document.createElement('span');
      idSpan.className = 'checkpoint-id';
      idSpan.textContent = c.taskId || '?';
      idSpan.title = c.taskId || '';
      head.appendChild(idSpan);
      const ts = formatSavedAt(c.savedAt);
      if (ts) {
        const tsSpan = document.createElement('span');
        tsSpan.className = 'checkpoint-ts';
        tsSpan.textContent = ts;
        head.appendChild(tsSpan);
      }
      li.appendChild(head);
      if (c.tool) {
        const tool = document.createElement('div');
        tool.className = 'checkpoint-tool';
        const args = Array.isArray(c.args) ? c.args.join(' ') : '';
        tool.textContent = `${c.tool}${args ? ` ${args}` : ''}`;
        tool.title = `${c.tool} ${args}`;
        li.appendChild(tool);
      }
      const actions = document.createElement('div');
      actions.className = 'checkpoint-actions';
      const btnResume = document.createElement('button');
      btnResume.type = 'button';
      btnResume.className = 'btn-sm';
      btnResume.textContent = '恢复';
      btnResume.onclick = () => resumeCheckpoint(c.taskId, btnResume);
      actions.appendChild(btnResume);
      const btnDel = document.createElement('button');
      btnDel.type = 'button';
      btnDel.className = 'btn-muted btn-sm';
      btnDel.textContent = '删除';
      btnDel.onclick = () => deleteCheckpoint(c.taskId, btnDel);
      actions.appendChild(btnDel);
      li.appendChild(actions);
      checkpointsList.appendChild(li);
    });
  } catch (e) {
    checkpointsList.innerHTML = `<li class="muted">加载失败: ${escapeHtml(e.message)}</li>`;
  }
}

async function resumeCheckpoint(taskId, btn) {
  if (!taskId) return;
  btn.disabled = true;
  btn.textContent = '恢复中...';
  setStatus(`正在恢复任务 ${taskId}...`);
  startThinking(`（恢复 checkpoint: ${taskId}）`);
  setAsking(true);
  try {
    const wsReady = (WS.sock && WS.sock.readyState === WebSocket.OPEN)
      || await WS.ensureConnected(2000);
    if (wsReady) {
      const answer = await continueViaWS('resume', { taskId });
      appendMsg('system', `已从 checkpoint 恢复任务 ${taskId}`);
      if (answer) appendMsg('agent', answer);
    } else {
      const m = await api('/api/checkpoints/resume', {
        method: 'POST',
        body: JSON.stringify({ taskId }),
      });
      if (m.status === 'error') throw new Error(formatResumeError(m.reason || m.error || 'resume failed'));
      appendMsg('system', `已从 checkpoint 恢复任务 ${taskId}`);
      const result = m.result || m;
      const answer = result.answer;
      if (answer) appendMsg('agent', typeof answer === 'string' ? answer : JSON.stringify(answer, null, 2).slice(0, 4000));
      else if (result.suspended) appendMsg('system', '任务已挂起，等待确认');
    }
    loadCheckpoints();
    setStatus('就绪');
  } catch (e) {
    appendMsg('system', `恢复失败: ${formatResumeError(e.message)}`);
    setStatus('出错');
  } finally {
    setAsking(false);
    btn.disabled = false;
    btn.textContent = '恢复';
  }
}

/** approve / resume：与 ask 一样走 streamHandler，重挂 streamCaller 后收 token。 */
function continueViaWS(type, extra = {}) {
  return new Promise(async (resolve, reject) => {
    const msgBody = appendMsg('agent', '');
    const textNode = msgBody.firstChild;
    const msgWrap = msgBody.parentElement;
    msgWrap.classList.add('streaming', 'pending');
    let full = '';
    let sawChunk = false;
    let finalPayload = null;
    const timeout = setTimeout(() => finishContinue('操作超时'), 1800000);

    function finishContinue(error, value) {
      clearTimeout(timeout);
      WS.streamHandler = null;
      msgWrap.classList.remove('streaming', 'pending');
      if (error != null && error !== '') reject(new Error(typeof error === 'string' ? error : String(error)));
      else resolve(value ?? full ?? '');
    }

    activeAsk = { timeout, msgWrap, full: '', resolve, reject, finished: false, taskId: extra.taskId || null };

    const myTaskId = extra.taskId != null ? String(extra.taskId) : null;
    const isMine = (m) => {
      if (myTaskId == null) return true;
      const tid = m.taskId != null ? String(m.taskId) : (m.task_id != null ? String(m.task_id) : null);
      return tid == null || tid === myTaskId;
    };

    WS.streamHandler = (m) => {
      if (m.type === 'ack') return;
      if (!isMine(m)) return;
      if (m.type === 'progress') {
        handleStreamProgress(m.event || {});
        if (activeAsk) full = activeAsk.full || '';
        return;
      }
      if (m.type === 'error') {
        const text = String(m.error || m.reason || 'unknown error');
        full = text;
        setAgentStreamText(msgBody, text);
        addThinkingLine(`! 错误: ${text}`);
        finishContinue(text);
        return;
      }
      if (m.type === 'token') {
        const t = extractModelText(m.data ?? m.text);
        if (!t) return;
        if (isReasoningToken(m)) {
          appendReasoningChunk(t);
          return;
        }
        if (activeAsk) {
          activeAsk.full = (activeAsk.full || '') + t;
          full = activeAsk.full;
          activeAsk.sawChunk = true;
        } else {
          full += t;
        }
        sawChunk = true;
        msgWrap.classList.remove('pending');
        setThinkingStatus('模型回答中...');
        appendAgentStreamToken(msgBody, t);
        scrollChatStreaming();
        return;
      }
      if (m.type === 'answer') {
        const text = m.text || extractModelText(m.result) || '';
        if (!text) return;
        full = text;
        if (activeAsk) { activeAsk.full = full; activeAsk.sawChunk = true; }
        sawChunk = true;
        msgWrap.classList.remove('pending');
        setAgentStreamText(msgBody, text);
        scrollChatStreaming();
        return;
      }
      if (m.type === type) {
        finalPayload = m;
        if (m.ok === false) {
          finishContinue(formatResumeError(m.error || `${type} failed`));
          return;
        }
        const ans = m.answer || m.result?.answer;
        if (ans && typeof ans === 'string' && !full) {
          full = ans;
          if (textNode) textNode.nodeValue = ans;
          else msgBody.textContent = ans;
        }
        return;
      }
      if (m.type === 'done') {
        const out = full || finalPayload?.answer || '';
        maybeShowApprove(out);
        finishActiveAsk(null, out);
        finishContinue(null, out);
      }
    };

    try {
      WS.send({ type, ...extra });
    } catch (err) {
      finishContinue(err.message || String(err));
    }
  });
}

function formatResumeError(err) {
  const s = typeof err === 'string' ? err : (err != null ? JSON.stringify(err) : '');
  const lower = s.toLowerCase();
  if (lower.includes('401') || lower.includes('authentication') || lower.includes('api key')
      || (lower.includes('invalid') && lower.includes('key'))) {
    return 'LLM 鉴权失败：请到「模型」检查 API Key 是否有效。密钥无效时旧任务也无法恢复，修好密钥后请重新提问';
  }
  if (lower.includes('reasoning_content')) {
    return 'thinking 模式缺推理字段：请重启/热加载节点后再试新对话；更早保存且未带 reasoning 的 checkpoint 可能无法恢复，建议重新提问';
  }
  return s || '未知错误';
}

async function deleteCheckpoint(taskId, btn) {
  if (!taskId) return;
  if (!window.confirm(`删除 checkpoint「${taskId}」？`)) return;
  btn.disabled = true;
  try {
    await api('/api/checkpoints/delete', {
      method: 'POST',
      body: JSON.stringify({ taskId }),
    });
    appendMsg('system', `已删除 checkpoint: ${taskId}`);
    loadCheckpoints();
  } catch (e) {
    appendMsg('system', `删除失败: ${e.message}`);
  } finally {
    btn.disabled = false;
  }
}

//==================================================================
// 面板切换
//==================================================================
const tabLoaders = {
  tasks: loadTasks, plan: loadPlan, files: loadFiles, graphs: loadGraphs,
  sessions: loadSessionsList, checkpoints: loadCheckpoints,
  metrics: loadMetrics, audit: loadAudit, tools: loadTools, tokens: loadTokens,
  memory: loadMemoryTab, knowledge: loadKnowledgeTab, core: loadCoreTab,
};

function showTab(name) {
  selectSideTab(name);
  if (tabLoaders[name]) tabLoaders[name]();
}

document.querySelectorAll('.side-tab').forEach((t) => {
  t.addEventListener('click', () => showTab(t.dataset.tab));
});

//==================================================================
// 事件绑定
//==================================================================
btnSend.addEventListener('click', async () => {
  const prompt = promptEl.value.trim();
  const attachments = pendingAttachments.slice();
  if (!prompt && attachments.length === 0) return;
  promptEl.value = '';
  clearAttachments();
  stickToBottom = true;
  if (!lhGetActive()) lhCreateChat({ activate: true });
  const sid = currentSessionId();
  lhEnsureSessionOption(sid);
  appendMsg('user', prompt, attachments);
  appendLocalMessage('user', prompt || '（附件）');
  setAsking(true);
  setStatus('思考中...');
  try {
    await ask(prompt, sid, attachments);
    setStatus('就绪');
    if (!sidePanel.classList.contains('hidden')) showTab(document.querySelector('.side-tab.active').dataset.tab);
  } catch (e) {
    if (e.name !== 'AbortError') appendMsg('system', `错误: ${e.message}`);
    setStatus('出错');
  } finally {
    setAsking(false);
  }
});

if (btnStop) btnStop.addEventListener('click', () => { stopAsk(); });

btnAttach.addEventListener('click', () => fileInput.click());

fileInput.addEventListener('change', async () => {
  const files = Array.from(fileInput.files || []);
  fileInput.value = '';
  await addAttachmentsFromFiles(files);
});

promptEl.addEventListener('paste', async (e) => {
  const images = clipboardImageFiles(e.clipboardData);
  if (images.length === 0) return;
  e.preventDefault();
  const text = e.clipboardData?.getData('text/plain');
  if (text) insertTextAtCursor(promptEl, text);
  const normalized = images.map((file, idx) => normalizeClipboardImageFile(file, idx));
  await addAttachmentsFromFiles(normalized);
});

promptEl.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); btnSend.click(); }
});

modeSelect.addEventListener('change', async () => {
  try {
    await ctrl('mode', { mode: modeSelect.value }, '/api/mode', { method: 'POST', body: JSON.stringify({ mode: modeSelect.value }) });
    appendMsg('system', `已切换模式: ${modeSelect.value}`);
  } catch (e) {
    appendMsg('system', `切换模式失败: ${e.message}`);
  }
});

sessionSelect.addEventListener('change', () => {
  const sid = sessionSelect.value;
  if (!sid) return;
  if (localHistory.chats.some((c) => c.id === sid)) {
    openLocalChat(sid);
  } else {
    localHistory.activeId = sid;
    lhEnsureSessionOption(sid);
  }
});

if (btnSaveSession) btnSaveSession.addEventListener('click', async () => {
  const sid = currentSessionId();
  try {
    await ctrl('saveSession', { sessionId: sid }, '/api/sessions/save', {
      method: 'POST',
      body: JSON.stringify({ sessionId: sid }),
    });
    persistActiveLocalChat();
    appendMsg('system', `会话已保存: ${sid}`);
    await loadSessions();
  } catch (e) {
    appendMsg('system', `保存失败: ${e.message}`);
  }
});

if (btnDeleteSession) btnDeleteSession.addEventListener('click', async () => {
  const sid = currentSessionId();
  if (!sid) return;
  if (!window.confirm(`删除会话「${sid}」？`)) return;
  await deleteLocalChat(sid);
  try {
    await ctrl('deleteSession', { sessionId: sid }, '/api/sessions/delete', {
      method: 'POST',
      body: JSON.stringify({ sessionId: sid }),
    });
  } catch { /* 本地已删即可 */ }
});

btnClear.addEventListener('click', async () => {
  const sid = currentSessionId();
  if (!window.confirm(`清空当前对话？此操作不可恢复。`)) return;
  try {
    await api('/api/clear', { method: 'POST', body: JSON.stringify({ sessionId: sid }) });
    const c = lhGetActive();
    if (c) {
      c.messages = [];
      c.graphs = [];
      c.title = '新对话';
      c.updatedAt = Date.now();
      lhSave();
    }
    chat.innerHTML = '';
    hideApproveBar();
    clearGraphArtifactsUi();
    appendMsg('system', '当前对话已清空');
  } catch (e) {
    appendMsg('system', `清空失败: ${e.message}`);
  }
});

function isHistoryOpen() {
  return historyRail && !historyRail.hasAttribute('hidden');
}

function setHistoryOpen(open) {
  if (!historyRail) return;
  if (open) {
    historyRail.removeAttribute('hidden');
  } else {
    historyRail.setAttribute('hidden', '');
  }
  historyBackdrop?.classList.add('hidden');
  if (btnHistory) {
    btnHistory.setAttribute('aria-pressed', open ? 'true' : 'false');
  }
}

function toggleHistoryPanel() {
  setHistoryOpen(!isHistoryOpen());
}

btnNewChat?.addEventListener('click', () => startNewLocalChat());
btnHistory?.addEventListener('click', () => toggleHistoryPanel());
btnHistoryClose?.addEventListener('click', () => setHistoryOpen(false));

if (btnDistill) btnDistill.addEventListener('click', async () => {
  const sid = currentSessionId();
  const active = typeof lhGetActive === 'function' ? lhGetActive() : null;
  const localMsgs = (active?.messages || []).filter((m) => m && (m.role === 'user' || m.role === 'agent'));
  if (localMsgs.length === 0) {
    appendMsg('system', '当前对话没有可蒸馏的消息，请先问答几轮再试');
    return;
  }
  setStatus('蒸馏中...');
  try {
    // 本地历史为准：把消息一并带上，避免仅靠服务端 session（刷新/切历史后可能为空）
    const messages = localMsgs.map((m) => ({
      role: m.role === 'agent' ? 'assistant' : m.role,
      content: typeof m.content === 'string' ? m.content : JSON.stringify(m.content ?? ''),
    }));
    const data = await api('/api/memory/distill', {
      method: 'POST',
      body: JSON.stringify({ sessionId: sid, messages }),
    });
    if (data.status === 'ok') {
      const n = data.saved ?? 0;
      appendMsg('system', n > 0
        ? `已蒸馏 ${n} 条事实到长期记忆（侧栏「记忆经验」→ 事实/全部 可查看）`
        : '蒸馏完成，但未提取到可保存的事实（对话可能过短或无持久信息）');
      if (n > 0 && document.querySelector('.side-tab.active')?.dataset?.tab === 'memory') {
        loadMemoryTab();
      }
    } else {
      appendMsg('system', `蒸馏失败: ${data.reason || '未知原因'}`);
    }
    setStatus('就绪');
  } catch (e) {
    appendMsg('system', `蒸馏异常: ${e.message}`);
    setStatus('出错');
  }
});

btnApprove.addEventListener('click', async () => {
  if (!pendingTaskId) return;
  btnApprove.disabled = true;
  const tid = pendingTaskId;
  hideApproveBar();
  startThinking(`（批准执行: ${tid}）`);
  setAsking(true);
  setStatus(`正在批准执行 ${tid}...`);
  try {
    const wsReady = (WS.sock && WS.sock.readyState === WebSocket.OPEN)
      || await WS.ensureConnected(2000);
    if (wsReady) {
      appendMsg('system', `已批准执行 (TaskId: ${tid})`);
      const answer = await continueViaWS('approve', { taskId: tid });
      if (answer) { /* already streamed into agent bubble */ }
    } else {
      const payload = await api('/api/approve', { method: 'POST', body: JSON.stringify({ taskId: tid }) });
      appendMsg('system', `已批准执行 (TaskId: ${tid})`);
      const answer = payload.answer || payload.result?.answer;
      if (answer) appendMsg('agent', typeof answer === 'string' ? answer : JSON.stringify(answer, null, 2).slice(0, 4000));
      else if (payload.result) appendMsg('agent', JSON.stringify(payload.result, null, 2).slice(0, 4000));
    }
    setStatus('就绪');
  } catch (e) {
    appendMsg('system', `批准失败: ${e.message}`);
    setStatus('出错');
  } finally {
    setAsking(false);
    btnApprove.disabled = false;
  }
});

btnDismissApprove.addEventListener('click', async () => {
  if (!pendingTaskId) { hideApproveBar(); return; }
  const tid = pendingTaskId;
  try {
    let payload;
    const wsReady = (WS.sock && WS.sock.readyState === WebSocket.OPEN)
      || await WS.ensureConnected(2000);
    if (wsReady) {
      const m = await WS.request('dismiss', { taskId: tid });
      if (m.ok === false) throw new Error(m.error || 'dismiss failed');
      payload = m;
    } else {
      payload = await api('/api/dismiss', { method: 'POST', body: JSON.stringify({ taskId: tid }) });
    }
    appendMsg('system', `已拒绝操作 (TaskId: ${tid})`);
    if (payload.answer) appendMsg('agent', payload.answer);
    hideApproveBar();
  } catch (e) {
    appendMsg('system', `拒绝失败: ${e.message}`);
  }
});

if (btnToken) btnToken.addEventListener('click', () => { promptToken(); });
if (btnLlm) btnLlm.addEventListener('click', () => { openLlmModal(); });
if (btnLlmSave) btnLlmSave.addEventListener('click', () => { saveLlmSettings(); });
if (btnLlmCancel) btnLlmCancel.addEventListener('click', () => { closeLlmModal(); });
if (llmProviderSelect) {
  llmProviderSelect.addEventListener('change', () => {
    fillModelSelect(llmProviderSelect.value);
    const p = llmProvidersCache.find((x) => x.id === llmProviderSelect.value);
    if (p?.defaultModel && llmModelSelect) llmModelSelect.value = p.defaultModel;
  });
}
if (llmModal) {
  llmModal.addEventListener('click', (e) => {
    if (e.target === llmModal) closeLlmModal();
  });
}

loadLlmProviders();

btnTasks.addEventListener('click', () => {
  sidePanel.classList.toggle('hidden');
  if (!sidePanel.classList.contains('hidden')) {
    const active = document.querySelector('.side-tab.active');
    showTab(active ? active.dataset.tab : 'tasks');
  }
});

btnCloseSide.addEventListener('click', () => sidePanel.classList.add('hidden'));

if (btnFilesRefresh) btnFilesRefresh.addEventListener('click', () => loadFiles());

if (btnFvClose) btnFvClose.addEventListener('click', () => closeFileViewer());
if (btnTvClose) btnTvClose.addEventListener('click', () => closeThinkingViewer());
if (btnTvZoomIn) {
  btnTvZoomIn.addEventListener('click', () => {
    thinkingViewerZoomPct = Math.min(240, thinkingViewerZoomPct + 10);
    applyThinkingViewerZoom();
    saveGeomFromPanel(thinkingViewerPanel, thinkingViewerZoomPct);
  });
}
if (btnTvZoomOut) {
  btnTvZoomOut.addEventListener('click', () => {
    thinkingViewerZoomPct = Math.max(60, thinkingViewerZoomPct - 10);
    applyThinkingViewerZoom();
    saveGeomFromPanel(thinkingViewerPanel, thinkingViewerZoomPct);
  });
}
if (btnTvCopy) {
  btnTvCopy.addEventListener('click', async () => {
    try {
      await copyTextToClipboard(thinkingViewerText || thinkingViewerBody?.textContent || '');
      setStatus('已复制全部思考内容');
    } catch (e) {
      setStatus(`复制失败: ${e.message}`);
    }
  });
}
if (btnTvCopySel) {
  btnTvCopySel.addEventListener('click', async () => {
    try {
      const sel = window.getSelection()?.toString() || '';
      if (!sel) {
        setStatus('请先选中文本');
        return;
      }
      await copyTextToClipboard(sel);
      setStatus('已复制选中内容');
    } catch (e) {
      setStatus(`复制失败: ${e.message}`);
    }
  });
}
if (btnTvFullscreen) {
  btnTvFullscreen.addEventListener('click', () => {
    if (!thinkingViewer) return;
    if (thinkingViewer.classList.contains('is-fullscreen')) {
      thinkingViewer.classList.remove('is-fullscreen');
      btnTvFullscreen.textContent = '全屏';
      applyFileViewerGeomTo(
        thinkingViewerPanel,
        tvGeomBeforeFullscreen || loadFileViewerGeom() || defaultFileViewerGeom(),
        'tv'
      );
      tvGeomBeforeFullscreen = null;
    } else {
      if (thinkingViewerPanel) {
        const r = thinkingViewerPanel.getBoundingClientRect();
        tvGeomBeforeFullscreen = {
          left: r.left, top: r.top, width: r.width, height: r.height, zoom: thinkingViewerZoomPct,
        };
      }
      saveGeomFromPanel(thinkingViewerPanel, thinkingViewerZoomPct);
      thinkingViewer.classList.add('is-fullscreen');
      btnTvFullscreen.textContent = '退出全屏';
    }
  });
}
if (thinkingViewerDrag && thinkingViewerPanel) {
  thinkingViewerDrag.addEventListener('pointerdown', (ev) => {
    if (ev.button !== 0) return;
    if (ev.target.closest('button')) return;
    if (thinkingViewer?.classList.contains('is-fullscreen')) return;
    const rect = thinkingViewerPanel.getBoundingClientRect();
    tvDragState = {
      pointerId: ev.pointerId,
      ox: ev.clientX - rect.left,
      oy: ev.clientY - rect.top,
    };
    thinkingViewerDrag.classList.add('dragging');
    try { thinkingViewerDrag.setPointerCapture(ev.pointerId); } catch { /* ignore */ }
    ev.preventDefault();
  });
  thinkingViewerDrag.addEventListener('pointermove', (ev) => {
    if (!tvDragState || tvDragState.pointerId !== ev.pointerId) return;
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const width = thinkingViewerPanel.offsetWidth;
    let left = ev.clientX - tvDragState.ox;
    let top = ev.clientY - tvDragState.oy;
    left = Math.max(0, Math.min(left, vw - Math.min(width, 80)));
    top = Math.max(0, Math.min(top, vh - 40));
    thinkingViewerPanel.style.left = `${left}px`;
    thinkingViewerPanel.style.top = `${top}px`;
  });
  const endTvDrag = (ev) => {
    if (!tvDragState || (ev && tvDragState.pointerId !== ev.pointerId)) return;
    tvDragState = null;
    thinkingViewerDrag.classList.remove('dragging');
    saveGeomFromPanel(thinkingViewerPanel, thinkingViewerZoomPct);
  };
  thinkingViewerDrag.addEventListener('pointerup', endTvDrag);
  thinkingViewerDrag.addEventListener('pointercancel', endTvDrag);
}
if (thinkingViewerBody) {
  let tvScrollTimer = null;
  thinkingViewerBody.addEventListener('scroll', () => {
    if (tvScrollTimer) return;
    tvScrollTimer = setTimeout(() => {
      tvScrollTimer = null;
      maybeLoadMoreThinkingChunks();
    }, 50);
  }, { passive: true });
}
if (thinkingViewerSearch) {
  let tvSearchTimer = null;
  thinkingViewerSearch.addEventListener('input', () => {
    clearTimeout(tvSearchTimer);
    tvSearchTimer = setTimeout(() => renderThinkingViewerBody(), 120);
  });
  thinkingViewerSearch.addEventListener('keydown', (ev) => {
    if (ev.key === 'Enter') {
      ev.preventDefault();
      if (!tvSearchHits.length) {
        renderThinkingViewerBody();
        return;
      }
      if (ev.shiftKey) {
        tvSearchIndex = (tvSearchIndex - 1 + tvSearchHits.length) % tvSearchHits.length;
      } else {
        tvSearchIndex = (tvSearchIndex + 1) % tvSearchHits.length;
      }
      renderThinkingViewerBody();
    }
  });
}
if (thinkingViewerSearchCase) {
  thinkingViewerSearchCase.addEventListener('change', () => renderThinkingViewerBody());
}
if (btnTvFindPrev) {
  btnTvFindPrev.addEventListener('click', () => {
    if (!tvSearchHits.length) {
      renderThinkingViewerBody();
      return;
    }
    tvSearchIndex = (tvSearchIndex - 1 + tvSearchHits.length) % tvSearchHits.length;
    renderThinkingViewerBody();
  });
}
if (btnTvFindNext) {
  btnTvFindNext.addEventListener('click', () => {
    if (!tvSearchHits.length) {
      renderThinkingViewerBody();
      return;
    }
    tvSearchIndex = (tvSearchIndex + 1) % tvSearchHits.length;
    renderThinkingViewerBody();
  });
}

if (btnFvZoomIn) {
  btnFvZoomIn.addEventListener('click', () => {
    fileViewerZoomPct = Math.min(240, fileViewerZoomPct + 10);
    applyFileViewerZoom();
    saveFileViewerGeom();
  });
}
if (btnFvZoomOut) {
  btnFvZoomOut.addEventListener('click', () => {
    fileViewerZoomPct = Math.max(60, fileViewerZoomPct - 10);
    applyFileViewerZoom();
    saveFileViewerGeom();
  });
}
if (btnFvCopy) {
  btnFvCopy.addEventListener('click', async () => {
    try {
      await copyTextToClipboard(fileViewerText || fileViewerBody?.textContent || '');
      setStatus('已复制全部内容');
    } catch (e) {
      setStatus(`复制失败: ${e.message}`);
    }
  });
}
if (btnFvCopySel) {
  btnFvCopySel.addEventListener('click', async () => {
    try {
      const sel = window.getSelection()?.toString() || '';
      if (!sel) {
        setStatus('请先选中文本');
        return;
      }
      await copyTextToClipboard(sel);
      setStatus('已复制选中内容');
    } catch (e) {
      setStatus(`复制失败: ${e.message}`);
    }
  });
}
if (btnFvInsert) {
  btnFvInsert.addEventListener('click', () => {
    if (!selectedFilePath) return;
    insertTextAtCursor(promptEl, `@${selectedFilePath} `);
    promptEl.focus();
    setStatus(`已引用 ${selectedFilePath}`);
  });
}
if (btnFvEdit) {
  btnFvEdit.addEventListener('click', () => {
    if (fileViewerEditing) saveFileViewerEdit();
    else enterFileViewerEdit();
  });
}
if (btnFvEditCancel) {
  btnFvEditCancel.addEventListener('click', () => {
    if (!fileViewerEditing) return;
    exitFileViewerEdit();
    renderFileViewerBody();
    setStatus('已放弃编辑');
  });
}
if (fileViewerEditor) {
  fileViewerEditor.addEventListener('keydown', (ev) => {
    if ((ev.ctrlKey || ev.metaKey) && ev.key.toLowerCase() === 's') {
      ev.preventDefault();
      saveFileViewerEdit();
    } else if (ev.key === 'Escape') {
      ev.preventDefault();
      exitFileViewerEdit();
      renderFileViewerBody();
      setStatus('已放弃编辑');
    }
  });
}
if (btnFvFullscreen) {
  btnFvFullscreen.addEventListener('click', () => {
    if (!fileViewer) return;
    if (fileViewer.classList.contains('is-fullscreen')) {
      fileViewer.classList.remove('is-fullscreen');
      btnFvFullscreen.textContent = '全屏';
      applyFileViewerGeom(fvGeomBeforeFullscreen || loadFileViewerGeom() || defaultFileViewerGeom());
      fvGeomBeforeFullscreen = null;
    } else {
      fvGeomBeforeFullscreen = currentFileViewerGeom();
      saveFileViewerGeom();
      fileViewer.classList.add('is-fullscreen');
      btnFvFullscreen.textContent = '退出全屏';
    }
  });
}
if (btnFvPopout) {
  btnFvPopout.addEventListener('click', () => {
    popOutFileViewer();
  });
}
if (btnTvPopout) {
  btnTvPopout.addEventListener('click', () => {
    popOutThinkingViewer();
  });
}
if (btnGvPopout) {
  btnGvPopout.addEventListener('click', () => {
    popOutGraphViewer();
  });
}

//==================================================================
// 弹出独立窗口：真正拖出主页面（可放到另一块屏），不挡聊天
// 弹出页 /static/popout.html 复刻原窗口搜索/缩放/复制/图操作等能力
//==================================================================
const popoutWins = { file: null, thinking: null, graph: null };
window.__aliPopout = window.__aliPopout || {};

window.__aliGetPopoutPayload = function __aliGetPopoutPayload(kind) {
  return (window.__aliPopout && window.__aliPopout[kind]) || null;
};

window.addEventListener('message', (ev) => {
  if (ev.origin !== location.origin) return;
  const msg = ev.data;
  if (!msg || msg.source !== 'ali-popout') return;
  if (msg.type === 'ali-popout-insert' && msg.path) {
    if (promptEl) {
      insertTextAtCursor(promptEl, `@${msg.path} `);
      promptEl.focus();
      setStatus(`已引用 ${msg.path}`);
    }
  } else if ((msg.type === 'ali-popout-focus-file' || msg.type === 'ali-popout-open-file') && msg.path) {
    try { window.focus(); } catch { /* ignore */ }
    openFileViewer(msg.path, null, msg.line != null ? Number(msg.line) : null);
    setStatus(`已在主窗打开 ${msg.path}`);
  } else if (msg.type === 'ali-popout-closed' && msg.kind) {
    if (popoutWins[msg.kind] && popoutWins[msg.kind].closed) {
      popoutWins[msg.kind] = null;
    }
  }
});

function openAliPopoutPage(kind) {
  const name = `ali-${kind}-viewer`;
  const features = 'popup=yes,width=1100,height=800,menubar=no,toolbar=no,location=no,status=no,resizable=yes,scrollbars=yes';
  let w = popoutWins[kind];
  try {
    if (!w || w.closed) {
      w = window.open(`/static/popout.html?kind=${encodeURIComponent(kind)}`, name, features);
      popoutWins[kind] = w;
    } else {
      try {
        w.location.href = `/static/popout.html?kind=${encodeURIComponent(kind)}&t=${Date.now()}`;
      } catch {
        w = window.open(`/static/popout.html?kind=${encodeURIComponent(kind)}`, name, features);
        popoutWins[kind] = w;
      }
    }
  } catch {
    w = null;
  }
  if (!w) {
    setStatus('弹出被浏览器拦截，请允许本站弹窗后再点「弹出」');
    return null;
  }
  try { w.focus(); } catch { /* ignore */ }
  return w;
}

function popOutFileViewer() {
  if (!fileViewer || fileViewer.classList.contains('hidden')) {
    setStatus('请先打开文件');
    return;
  }
  const title = fileViewerTitle?.textContent || selectedFilePath || '文件';
  const text = fileViewerText || fileViewerBody?.innerText || '';
  const lineCount = countFileViewerLines(text);
  let html = '';
  try {
    html = buildFileViewerLinedHtml(text, selectedFilePath || title, null).html;
  } catch {
    html = fileViewerBody?.innerHTML || '';
  }
  let lineNo = null;
  const m = String(title).match(/:(\d+)\s*$/);
  if (m) lineNo = Number(m[1]);
  const metaBits = [];
  if (fileViewerMeta?.textContent) metaBits.push(fileViewerMeta.textContent);
  else {
    metaBits.push(`${lineCount} 行`);
  }
  window.__aliPopout.file = {
    title,
    meta: metaBits.join(' · '),
    text,
    html,
    path: selectedFilePath || '',
    zoom: fileViewerZoomPct || 100,
    lineNo,
    lineCount,
  };
  if (openAliPopoutPage('file')) {
    closeFileViewer();
    setStatus('文件已弹出（含搜索/缩放/复制/引用）');
  }
}

function popOutThinkingViewer() {
  if (!thinkingViewer || thinkingViewer.classList.contains('hidden')) {
    setStatus('请先打开思考过程');
    return;
  }
  const title = thinkingViewerTitle?.textContent || '思考过程';
  const meta = thinkingViewerMeta?.textContent || '';
  const text = thinkingViewerText || thinkingViewerBody?.innerText || '';
  const html = thinkingViewerBody?.innerHTML || '';
  window.__aliPopout.thinking = {
    title,
    meta,
    text,
    html,
    zoom: thinkingViewerZoomPct || 100,
  };
  if (openAliPopoutPage('thinking')) {
    closeThinkingViewer();
    setStatus('思考过程已弹出（含搜索/缩放/复制）');
  }
}

function popOutGraphViewer() {
  if (!graphViewer || graphViewer.classList.contains('hidden')) {
    setStatus('请先打开图');
    return;
  }
  const title = graphViewerTitle?.textContent || '调用图';
  const meta = graphViewerMeta?.textContent || '';
  const svg = graphViewerCanvas?.querySelector('svg');
  const mermaidSrc = (graphViewerSource?.textContent || '').trim();
  const list = Array.isArray(graphArtifacts) ? graphArtifacts : [];
  const artifacts = list.map((g) => ({
    id: g.id,
    title: g.title || g.kind || '图',
    meta: [
      g.tool || '',
      g.meta || '',
      (g.mermaidEdgeCount != null ? `${g.mermaidEdgeCount} edges` : ''),
      (Array.isArray(g.edges) ? `${g.edges.length} edges` : ''),
    ].filter(Boolean).join(' · '),
    mermaid: g.mermaid || '',
    markdown: g.markdown || '',
    edges: Array.isArray(g.edges) ? g.edges : [],
    briefs: (g.briefs && typeof g.briefs === 'object') ? g.briefs : {},
    byModule: g.byModule != null ? g.byModule : [],
    query: g.query || null,
    writePath: g.writePath || '',
    svgHtml: (g.id === gvActiveId && svg) ? svg.outerHTML : '',
  }));
  if (!artifacts.length) {
    artifacts.push({
      id: gvActiveId || 'g0',
      title,
      meta,
      mermaid: mermaidSrc,
      markdown: '',
      edges: [],
      briefs: {},
      byModule: [],
      query: null,
      svgHtml: svg ? svg.outerHTML : '',
    });
  }
  window.__aliPopout.graph = {
    title,
    meta,
    mermaid: mermaidSrc,
    svgHtml: svg ? svg.outerHTML : '',
    artifacts,
    activeId: gvActiveId || artifacts[0].id,
  };
  if (openAliPopoutPage('graph')) {
    closeGraphViewer();
    setStatus('图已弹出（含缩放/适配/翻页/下载/节点详情）');
  }
}

if (fileViewerDrag && fileViewerPanel) {
  fileViewerDrag.addEventListener('pointerdown', (ev) => {
    if (ev.button !== 0) return;
    if (ev.target.closest('button')) return;
    if (fileViewer?.classList.contains('is-fullscreen')) return;
    const rect = fileViewerPanel.getBoundingClientRect();
    fvDragState = {
      pointerId: ev.pointerId,
      ox: ev.clientX - rect.left,
      oy: ev.clientY - rect.top,
    };
    fileViewerDrag.classList.add('dragging');
    try { fileViewerDrag.setPointerCapture(ev.pointerId); } catch { /* ignore */ }
    ev.preventDefault();
  });
  fileViewerDrag.addEventListener('pointermove', (ev) => {
    if (!fvDragState || fvDragState.pointerId !== ev.pointerId) return;
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const width = fileViewerPanel.offsetWidth;
    const height = fileViewerPanel.offsetHeight;
    let left = ev.clientX - fvDragState.ox;
    let top = ev.clientY - fvDragState.oy;
    left = Math.max(0, Math.min(left, vw - Math.min(width, 80)));
    top = Math.max(0, Math.min(top, vh - 40));
    fileViewerPanel.style.left = `${left}px`;
    fileViewerPanel.style.top = `${top}px`;
  });
  const endDrag = (ev) => {
    if (!fvDragState || (ev && fvDragState.pointerId !== ev.pointerId)) return;
    fvDragState = null;
    fileViewerDrag.classList.remove('dragging');
    saveFileViewerGeom();
  };
  fileViewerDrag.addEventListener('pointerup', endDrag);
  fileViewerDrag.addEventListener('pointercancel', endDrag);
}
if (fileViewerPanel) {
  // 右下角 resize 后松手时记尺寸（pointerup 冒泡到 document）
  document.addEventListener('pointerup', () => {
    if (!fileViewer || fileViewer.classList.contains('hidden')) return;
    if (fileViewer.classList.contains('is-fullscreen')) return;
    saveFileViewerGeom();
  });
}
document.addEventListener('keydown', (ev) => {
  const tvOpen = thinkingViewer && !thinkingViewer.classList.contains('hidden');
  const fvOpen = fileViewer && !fileViewer.classList.contains('hidden');
  if (!tvOpen && !fvOpen) return;
  if ((ev.ctrlKey || ev.metaKey) && (ev.key === 'f' || ev.key === 'F')) {
    ev.preventDefault();
    if (tvOpen) {
      thinkingViewerSearch?.focus();
      thinkingViewerSearch?.select();
    } else {
      fileViewerSearch?.focus();
      fileViewerSearch?.select();
    }
    return;
  }
  if (ev.key === 'Escape') {
    if (tvOpen) {
      if (document.activeElement === thinkingViewerSearch && thinkingViewerSearch.value) {
        clearThinkingViewerSearch(true);
        renderThinkingViewerBody();
        return;
      }
      if (thinkingViewer.classList.contains('is-fullscreen')) {
        thinkingViewer.classList.remove('is-fullscreen');
        if (btnTvFullscreen) btnTvFullscreen.textContent = '全屏';
        applyFileViewerGeomTo(
          thinkingViewerPanel,
          tvGeomBeforeFullscreen || loadFileViewerGeom() || defaultFileViewerGeom(),
          'tv'
        );
        tvGeomBeforeFullscreen = null;
      }
      return;
    }
    // Esc 只清搜索 / 退出全屏，不关闭查看器（仅 × 关闭）
    if (document.activeElement === fileViewerSearch && fileViewerSearch.value) {
      clearFileViewerSearch(true);
      renderFileViewerBody();
      return;
    }
    if (fileViewer.classList.contains('is-fullscreen')) {
      fileViewer.classList.remove('is-fullscreen');
      if (btnFvFullscreen) btnFvFullscreen.textContent = '全屏';
      applyFileViewerGeom(fvGeomBeforeFullscreen || loadFileViewerGeom() || defaultFileViewerGeom());
      fvGeomBeforeFullscreen = null;
    }
  }
});

if (fileViewerSearch) {
  let searchTimer = null;
  fileViewerSearch.addEventListener('input', () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => runFileViewerSearch(), 120);
  });
  fileViewerSearch.addEventListener('keydown', (ev) => {
    if (ev.key === 'Enter') {
      ev.preventDefault();
      if (!fvSearchHits.length) runFileViewerSearch();
      else stepFileViewerSearch(ev.shiftKey ? -1 : 1);
    }
  });
}
if (fileViewerSearchCase) {
  fileViewerSearchCase.addEventListener('change', () => runFileViewerSearch());
}
if (btnFvFindNext) btnFvFindNext.addEventListener('click', () => stepFileViewerSearch(1));
if (btnFvFindPrev) btnFvFindPrev.addEventListener('click', () => stepFileViewerSearch(-1));

window.addEventListener('resize', () => {
  if (!fileViewer || fileViewer.classList.contains('hidden')) return;
  if (fileViewer.classList.contains('is-fullscreen')) return;
  applyFileViewerGeom(currentFileViewerGeom());
});
if (btnCheckpointsRefresh) btnCheckpointsRefresh.addEventListener('click', () => loadCheckpoints());

//==================================================================
// 图查看器事件
//==================================================================
if (btnGvClose) btnGvClose.addEventListener('click', () => closeGraphViewer());
if (btnGvZoomIn) btnGvZoomIn.addEventListener('click', () => zoomGraphViewer(1.2));
if (btnGvZoomOut) btnGvZoomOut.addEventListener('click', () => zoomGraphViewer(1 / 1.2));
if (btnGvFit) btnGvFit.addEventListener('click', () => fitGraphViewer());
if (btnGvReset) btnGvReset.addEventListener('click', () => resetGraphViewerView());
if (btnGvPrev) btnGvPrev.addEventListener('click', () => shiftGraphViewer(1));
if (btnGvNext) btnGvNext.addEventListener('click', () => shiftGraphViewer(-1));
if (btnGvCopy) {
  btnGvCopy.addEventListener('click', async () => {
    const g = graphArtifacts.find((x) => x.id === gvActiveId);
    const text = g?.mermaid || g?.markdown || '';
    if (!text) return;
    try {
      await navigator.clipboard.writeText(text);
      setStatus('已复制 Mermaid 源码');
    } catch {
      setStatus('复制失败');
    }
  });
}
if (btnGvDlSvg) {
  btnGvDlSvg.addEventListener('click', () => {
    const svg = graphViewerCanvas?.querySelector('svg');
    if (!svg) {
      setStatus('当前无 SVG');
      return;
    }
    const g = graphArtifacts.find((x) => x.id === gvActiveId);
    const xml = new XMLSerializer().serializeToString(svg);
    gvDownloadBlob(`${gvSafeFilename(g?.title)}.svg`, new Blob([xml], { type: 'image/svg+xml' }));
  });
}
if (btnGvDlMmd) {
  btnGvDlMmd.addEventListener('click', () => {
    const g = graphArtifacts.find((x) => x.id === gvActiveId);
    const text = g?.mermaid || '';
    if (!text) {
      setStatus('当前无 Mermaid 源码');
      return;
    }
    gvDownloadBlob(`${gvSafeFilename(g?.title)}.mmd`, new Blob([text], { type: 'text/plain' }));
  });
}
if (btnGvSource) {
  btnGvSource.addEventListener('click', () => {
    graphViewerSource?.classList.toggle('hidden');
  });
}
if (btnGvFullscreen) {
  btnGvFullscreen.addEventListener('click', () => {
    if (!graphViewer) return;
    if (graphViewer.classList.contains('is-fullscreen')) {
      graphViewer.classList.remove('is-fullscreen');
      btnGvFullscreen.textContent = '全屏';
      applyGraphViewerGeom(gvGeomBeforeFullscreen || loadGraphViewerGeom() || defaultGraphViewerGeom());
      gvGeomBeforeFullscreen = null;
      requestAnimationFrame(() => fitGraphViewer());
    } else {
      gvGeomBeforeFullscreen = currentGraphViewerGeom();
      saveGraphViewerGeom();
      graphViewer.classList.add('is-fullscreen');
      btnGvFullscreen.textContent = '退出全屏';
      requestAnimationFrame(() => fitGraphViewer());
    }
  });
}
if (graphViewerDrag && graphViewerPanel) {
  graphViewerDrag.addEventListener('pointerdown', (ev) => {
    if (ev.button !== 0) return;
    if (ev.target.closest('button')) return;
    if (graphViewer?.classList.contains('is-fullscreen')) return;
    const rect = graphViewerPanel.getBoundingClientRect();
    gvDragState = {
      pointerId: ev.pointerId,
      ox: ev.clientX - rect.left,
      oy: ev.clientY - rect.top,
    };
    graphViewerDrag.classList.add('dragging');
    try { graphViewerDrag.setPointerCapture(ev.pointerId); } catch { /* ignore */ }
    ev.preventDefault();
  });
  graphViewerDrag.addEventListener('pointermove', (ev) => {
    if (!gvDragState || gvDragState.pointerId !== ev.pointerId) return;
    const vw = window.innerWidth;
    const width = graphViewerPanel.offsetWidth;
    let left = ev.clientX - gvDragState.ox;
    let top = ev.clientY - gvDragState.oy;
    left = Math.max(0, Math.min(left, vw - Math.min(width, 80)));
    top = Math.max(0, Math.min(top, window.innerHeight - 40));
    graphViewerPanel.style.left = `${left}px`;
    graphViewerPanel.style.top = `${top}px`;
  });
  const endGvWinDrag = (ev) => {
    if (!gvDragState || (ev && gvDragState.pointerId !== ev.pointerId)) return;
    gvDragState = null;
    graphViewerDrag.classList.remove('dragging');
    saveGraphViewerGeom();
  };
  graphViewerDrag.addEventListener('pointerup', endGvWinDrag);
  graphViewerDrag.addEventListener('pointercancel', endGvWinDrag);
}
if (graphViewerViewport) {
  graphViewerViewport.addEventListener('wheel', (ev) => {
    if (!graphViewer || graphViewer.classList.contains('hidden')) return;
    ev.preventDefault();
    const factor = ev.deltaY < 0 ? 1.12 : 1 / 1.12;
    zoomGraphViewer(factor, ev.clientX, ev.clientY);
  }, { passive: false });

  graphViewerViewport.addEventListener('pointerdown', (ev) => {
    if (ev.button !== 0) return;
    if (ev.target.closest('button')) return;
    gvPanState = { pointerId: ev.pointerId, x: ev.clientX, y: ev.clientY };
    graphViewerViewport.classList.add('panning');
    try { graphViewerViewport.setPointerCapture(ev.pointerId); } catch { /* ignore */ }
    ev.preventDefault();
  });
  graphViewerViewport.addEventListener('pointermove', (ev) => {
    if (!gvPanState || gvPanState.pointerId !== ev.pointerId) return;
    panGraphViewer(ev.clientX - gvPanState.x, ev.clientY - gvPanState.y);
    gvPanState.x = ev.clientX;
    gvPanState.y = ev.clientY;
  });
  const endPan = (ev) => {
    if (!gvPanState || (ev && gvPanState.pointerId !== ev.pointerId)) return;
    gvPanState = null;
    graphViewerViewport.classList.remove('panning');
  };
  graphViewerViewport.addEventListener('pointerup', endPan);
  graphViewerViewport.addEventListener('pointercancel', endPan);
  graphViewerViewport.addEventListener('dblclick', (ev) => {
    ev.preventDefault();
    fitGraphViewer();
  });
}
if (graphViewerSearch) {
  let gvSearchTimer = null;
  graphViewerSearch.addEventListener('input', () => {
    clearTimeout(gvSearchTimer);
    gvSearchTimer = setTimeout(() => highlightGraphNodes(graphViewerSearch.value), 100);
  });
}
document.addEventListener('pointerup', () => {
  if (!graphViewer || graphViewer.classList.contains('hidden')) return;
  if (graphViewer.classList.contains('is-fullscreen')) return;
  saveGraphViewerGeom();
});
document.addEventListener('keydown', (ev) => {
  if (!graphViewer || graphViewer.classList.contains('hidden')) return;
  if (ev.target && (ev.target.tagName === 'INPUT' || ev.target.tagName === 'TEXTAREA')) {
    if (ev.key === 'Escape') {
      if (graphViewerSearch && document.activeElement === graphViewerSearch && graphViewerSearch.value) {
        graphViewerSearch.value = '';
        highlightGraphNodes('');
        ev.preventDefault();
      }
    }
    return;
  }
  if (ev.key === 'Escape') {
    if (graphViewer.classList.contains('is-fullscreen')) {
      graphViewer.classList.remove('is-fullscreen');
      if (btnGvFullscreen) btnGvFullscreen.textContent = '全屏';
      applyGraphViewerGeom(gvGeomBeforeFullscreen || loadGraphViewerGeom() || defaultGraphViewerGeom());
      gvGeomBeforeFullscreen = null;
      requestAnimationFrame(() => fitGraphViewer());
    } else {
      closeGraphViewer();
    }
    ev.preventDefault();
    return;
  }
  if (ev.key === '+' || ev.key === '=') { zoomGraphViewer(1.15); ev.preventDefault(); }
  else if (ev.key === '-' || ev.key === '_') { zoomGraphViewer(1 / 1.15); ev.preventDefault(); }
  else if (ev.key === '0') { fitGraphViewer(); ev.preventDefault(); }
  else if (ev.key === 'ArrowLeft') { panGraphViewer(40, 0); ev.preventDefault(); }
  else if (ev.key === 'ArrowRight') { panGraphViewer(-40, 0); ev.preventDefault(); }
  else if (ev.key === 'ArrowUp') { panGraphViewer(0, 40); ev.preventDefault(); }
  else if (ev.key === 'ArrowDown') { panGraphViewer(0, -40); ev.preventDefault(); }
  else if (ev.key === '[' ) { shiftGraphViewer(1); ev.preventDefault(); }
  else if (ev.key === ']' ) { shiftGraphViewer(-1); ev.preventDefault(); }
});
window.addEventListener('resize', () => {
  if (!graphViewer || graphViewer.classList.contains('hidden')) return;
  if (graphViewer.classList.contains('is-fullscreen')) {
    requestAnimationFrame(() => fitGraphViewer());
    return;
  }
  applyGraphViewerGeom(currentGraphViewerGeom());
});

//==================================================================
// 启动
//==================================================================
WS.connect();
loadStatus();
initLocalHistory();
loadSessions();
