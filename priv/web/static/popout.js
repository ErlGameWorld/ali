(() => {
  const params = new URLSearchParams(location.search);
  const kind = params.get('kind') || 'file';

  const $ = (id) => document.getElementById(id);
  const titleEl = $('title');
  const metaEl = $('meta');
  const actionsEl = $('actions');
  const statusEl = $('status');
  const searchRow = $('searchRow');
  const searchInput = $('searchInput');
  const searchCase = $('searchCase');
  const searchCount = $('searchCount');
  const btnFindPrev = $('btnFindPrev');
  const btnFindNext = $('btnFindNext');
  const fileBody = $('fileBody');
  const thinkingBody = $('thinkingBody');
  const graphBody = $('graphBody');
  const graphSearchRow = $('graphSearchRow');
  const graphSearch = $('graphSearch');
  const graphSearchCount = $('graphSearchCount');
  const graphViewport = $('graphViewport');
  const graphCanvas = $('graphCanvas');
  const graphDetailBody = $('graphDetailBody');
  const graphSource = $('graphSource');

  let payload = null;
  let zoomPct = 100;
  let searchHits = [];
  let searchIndex = -1;
  let textContent = '';

  // graph state
  let gvScale = 1;
  let gvTx = 0;
  let gvTy = 0;
  let panState = null;
  let showSource = false;
  let artifactIndex = 0;
  let artifacts = [];
  let activeGraph = null;

  function setStatus(msg) {
    if (statusEl) statusEl.textContent = msg || '';
  }

  function btn(label, title, onClick) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'btn';
    b.textContent = label;
    if (title) b.title = title;
    b.addEventListener('click', onClick);
    return b;
  }

  function loadPayload() {
    try {
      if (window.opener && typeof window.opener.__aliGetPopoutPayload === 'function') {
        return window.opener.__aliGetPopoutPayload(kind);
      }
      if (window.opener && window.opener.__aliPopout) {
        return window.opener.__aliPopout[kind] || null;
      }
    } catch (e) {
      setStatus(`无法读取主窗口数据: ${e.message || e}`);
    }
    return null;
  }

  function postToOpener(msg) {
    try {
      if (window.opener && !window.opener.closed) {
        window.opener.postMessage({ ...msg, source: 'ali-popout' }, location.origin);
      }
    } catch { /* ignore */ }
  }

  function applyZoom(el) {
    if (!el) return;
    el.style.fontSize = `${(12 * zoomPct) / 100}px`;
  }

  function updateZoomLabel() {
    const z = actionsEl.querySelector('[data-zoom]');
    if (z) z.textContent = `${zoomPct}%`;
  }

  function addZoomControls(onChange) {
    actionsEl.appendChild(btn('A−', '缩小', () => {
      zoomPct = Math.max(60, zoomPct - 10);
      updateZoomLabel();
      onChange();
    }));
    const z = document.createElement('span');
    z.className = 'zoom-label muted';
    z.dataset.zoom = '1';
    z.textContent = `${zoomPct}%`;
    actionsEl.appendChild(z);
    actionsEl.appendChild(btn('A+', '放大', () => {
      zoomPct = Math.min(240, zoomPct + 10);
      updateZoomLabel();
      onChange();
    }));
  }

  function copyText(text) {
    const t = String(text || '');
    if (!t) {
      setStatus('无可复制内容');
      return;
    }
    navigator.clipboard.writeText(t).then(
      () => setStatus('已复制'),
      () => setStatus('复制失败'),
    );
  }

  function copySelection(root) {
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed || !root.contains(sel.anchorNode)) {
      setStatus('请先选中文本');
      return;
    }
    copyText(sel.toString());
  }

  // -------- text search (file / thinking) --------
  function clearSearchMarks(root) {
    if (!root) return;
    root.querySelectorAll('mark.po-hit').forEach((m) => {
      const parent = m.parentNode;
      parent.replaceChild(document.createTextNode(m.textContent || ''), m);
      parent.normalize();
    });
    searchHits = [];
    searchIndex = -1;
    if (searchCount) searchCount.textContent = '0/0';
  }

  function walkTextNodes(root, fn) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    const nodes = [];
    let n;
    while ((n = walker.nextNode())) nodes.push(n);
    nodes.forEach(fn);
  }

  function runSearch(root, opts) {
    clearSearchMarks(root);
    const q = (searchInput?.value || '').trim();
    if (!q || !root) return;
    const caseSensitive = !!(searchCase && searchCase.checked);
    const needle = caseSensitive ? q : q.toLowerCase();
    const scopes = opts?.rootSelector
      ? Array.from(root.querySelectorAll(opts.rootSelector))
      : [root];
    scopes.forEach((scope) => {
      walkTextNodes(scope, (textNode) => {
        const raw = textNode.nodeValue || '';
        const hay = caseSensitive ? raw : raw.toLowerCase();
        let start = 0;
        const parts = [];
        let found = false;
        while (start < hay.length) {
          const idx = hay.indexOf(needle, start);
          if (idx < 0) {
            parts.push(document.createTextNode(raw.slice(start)));
            break;
          }
          found = true;
          if (idx > start) parts.push(document.createTextNode(raw.slice(start, idx)));
          const mark = document.createElement('mark');
          mark.className = 'po-hit';
          mark.textContent = raw.slice(idx, idx + q.length);
          parts.push(mark);
          start = idx + q.length;
        }
        if (found && parts.length) {
          const frag = document.createDocumentFragment();
          parts.forEach((p) => frag.appendChild(p));
          textNode.parentNode.replaceChild(frag, textNode);
        }
      });
    });
    searchHits = Array.from(root.querySelectorAll('mark.po-hit'));
    searchIndex = searchHits.length ? 0 : -1;
    highlightActive();
  }

  function highlightActive() {
    searchHits.forEach((m, i) => m.classList.toggle('po-hit-active', i === searchIndex));
    if (searchCount) {
      searchCount.textContent = searchHits.length
        ? `${searchIndex + 1}/${searchHits.length}`
        : '0/0';
    }
    const active = searchHits[searchIndex];
    active?.scrollIntoView({ block: 'center', behavior: 'smooth' });
  }

  function stepSearch(dir) {
    if (!searchHits.length) return;
    searchIndex = (searchIndex + dir + searchHits.length) % searchHits.length;
    highlightActive();
  }

  function bindTextSearch(root, opts) {
    searchRow.classList.remove('hidden');
    const go = () => runSearch(root, opts);
    searchInput?.addEventListener('input', go);
    searchCase?.addEventListener('change', go);
    searchInput?.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        stepSearch(e.shiftKey ? -1 : 1);
      }
    });
    btnFindPrev?.addEventListener('click', () => stepSearch(-1));
    btnFindNext?.addEventListener('click', () => stepSearch(1));
    document.addEventListener('keydown', (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'f') {
        e.preventDefault();
        searchInput?.focus();
        searchInput?.select();
      }
    });
  }

  // -------- file --------
  function buildLinedHtml(text) {
    const lines = String(text ?? '').split('\n');
    let html = '<div class="fv-code">';
    for (let i = 0; i < lines.length; i++) {
      const content = escapeHtml(lines[i]) || ' ';
      html += `<div class="fv-line" data-line="${i + 1}"><span class="fv-lc">${content}</span></div>`;
    }
    html += '</div>';
    return { html, lineCount: lines.length };
  }

  function initFile() {
    document.title = payload.title || '文件';
    titleEl.textContent = payload.title || '文件';
    fileBody.classList.remove('hidden');
    textContent = payload.text || '';
    zoomPct = payload.zoom || 100;
    const lineCount = payload.lineCount
      || (textContent ? textContent.split('\n').length : 0);
    const metaBits = [];
    if (payload.meta) metaBits.push(payload.meta);
    if (lineCount && !(payload.meta || '').includes('行')) metaBits.push(`${lineCount} 行`);
    metaEl.textContent = metaBits.filter(Boolean).join(' · ');

    if (payload.html && String(payload.html).includes('fv-line')) {
      fileBody.innerHTML = payload.html;
    } else if (payload.html && !textContent) {
      fileBody.innerHTML = payload.html;
    } else {
      fileBody.innerHTML = buildLinedHtml(textContent).html;
    }
    applyZoom(fileBody);

    addZoomControls(() => applyZoom(fileBody));
    actionsEl.appendChild(btn('复制', '复制全部', () => copyText(textContent || fileBody.innerText)));
    actionsEl.appendChild(btn('复制选中', '复制选中', () => copySelection(fileBody)));
    if (payload.path) {
      actionsEl.appendChild(btn('引用', '插入 @path 到主窗口输入框', () => {
        postToOpener({ type: 'ali-popout-insert', path: payload.path });
        setStatus(`已请求主窗口引用 @${payload.path}`);
      }));
    }
    actionsEl.appendChild(btn('在主窗打开', '回到主窗口并打开该文件', () => {
      postToOpener({ type: 'ali-popout-focus-file', path: payload.path });
      setStatus('已通知主窗口');
    }));
    // 搜索只扫代码列，避免行号伪元素无关
    bindTextSearch(fileBody, { rootSelector: '.fv-lc' });
    if (payload.lineNo) {
      const line = fileBody.querySelector(`.fv-line[data-line="${payload.lineNo}"]`);
      if (line) {
        line.classList.add('fv-line-target');
        line.scrollIntoView({ block: 'center' });
      }
    }
    setStatus(`文件弹出窗就绪 · ${lineCount} 行`);
  }

  // -------- thinking --------
  function initThinking() {
    document.title = payload.title || '思考过程';
    titleEl.textContent = payload.title || '思考过程';
    metaEl.textContent = payload.meta || '';
    thinkingBody.classList.remove('hidden');
    textContent = payload.text || '';
    zoomPct = payload.zoom || 100;
    if (payload.html) thinkingBody.innerHTML = payload.html;
    else thinkingBody.innerHTML = `<pre>${escapeHtml(textContent)}</pre>`;
    applyZoom(thinkingBody);

    addZoomControls(() => applyZoom(thinkingBody));
    actionsEl.appendChild(btn('复制', '复制全部', () => copyText(textContent || thinkingBody.innerText)));
    actionsEl.appendChild(btn('复制选中', '复制选中', () => copySelection(thinkingBody)));
    bindTextSearch(thinkingBody);
    setStatus('思考过程弹出窗就绪');
  }

  function escapeHtml(s) {
    return String(s ?? '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  // -------- graph --------
  function applyGraphTransform() {
    graphCanvas.style.transform = `translate(${gvTx}px, ${gvTy}px) scale(${gvScale})`;
    const z = actionsEl.querySelector('[data-gvzoom]');
    if (z) z.textContent = `${Math.round(gvScale * 100)}%`;
  }

  function fitGraph() {
    const svg = graphCanvas.querySelector('svg');
    if (!svg || !graphViewport) return;
    try {
      // 与主窗一致：按内容重设 viewBox，避免 mermaid 固定尺寸导致居中偏
      svg.style.maxWidth = 'none';
      svg.style.maxHeight = 'none';
      svg.removeAttribute('width');
      svg.removeAttribute('height');
      const bb = svg.getBBox();
      if (bb && bb.width > 1 && bb.height > 1) {
        const pad = 12;
        svg.setAttribute('viewBox', `${bb.x - pad} ${bb.y - pad} ${bb.width + pad * 2} ${bb.height + pad * 2}`);
      }
      svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');
      const vb = svg.viewBox?.baseVal;
      const contentW = (vb && vb.width > 0) ? vb.width : Math.max(bb.width || 800, 1);
      const contentH = (vb && vb.height > 0) ? vb.height : Math.max(bb.height || 600, 1);
      const vw = graphViewport.clientWidth || 800;
      const vh = graphViewport.clientHeight || 600;
      if (vw < 80 || vh < 80) return;
      const scale = Math.min(vw / contentW, vh / contentH) * 0.92;
      gvScale = Math.max(0.2, Math.min(12, scale));
      // viewBox 已归一化到内容，画布原点对齐内容；整图居中
      const pxW = contentW * gvScale;
      const pxH = contentH * gvScale;
      gvTx = (vw - pxW) / 2;
      gvTy = (vh - pxH) / 2;
      // 矢量清晰缩放：改 SVG 像素尺寸，平移仍用 translate（scale 保持 1 时更清晰）
      // 这里仍用 canvas scale 以兼容现有滚轮逻辑；同步写 width 便于测量
      svg.style.width = `${contentW}px`;
      svg.style.height = `${contentH}px`;
      applyGraphTransform();
    } catch {
      gvScale = 1;
      gvTx = 24;
      gvTy = 24;
      applyGraphTransform();
    }
  }

  function nodeLabelText(node) {
    return (node.textContent || '').replace(/\s+/g, ' ').trim();
  }

  function findGraphNodes(q0) {
    const q = String(q0 || '').trim().toLowerCase();
    if (!q) return [];
    const nodes = Array.from(graphCanvas.querySelectorAll('svg .node, svg g.node, svg [id^="flowchart-"]'));
    const exact = [];
    const partial = [];
    nodes.forEach((n) => {
      const t = nodeLabelText(n).toLowerCase();
      if (!t) return;
      if (t === q || t.startsWith(`${q} `) || t.includes(` ${q}`)) exact.push(n);
      else if (t.includes(q)) partial.push(n);
    });
    return exact.length ? exact : partial;
  }

  /** 把指定节点平移到视口正中央（保持当前缩放） */
  function centerOnNode(el) {
    if (!el || !graphViewport) return false;
    const nodeRect = el.getBoundingClientRect();
    const vpRect = graphViewport.getBoundingClientRect();
    if (!(nodeRect.width > 0 || nodeRect.height > 0)) return false;
    const nodeCx = nodeRect.left + nodeRect.width / 2;
    const nodeCy = nodeRect.top + nodeRect.height / 2;
    const vpCx = vpRect.left + vpRect.width / 2;
    const vpCy = vpRect.top + vpRect.height / 2;
    gvTx += vpCx - nodeCx;
    gvTy += vpCy - nodeCy;
    applyGraphTransform();
    return true;
  }

  /** 高亮并居中指定函数（优先精确 MFA） */
  function centerOnQuery(q0, opts) {
    const q = String(q0 || '').trim();
    if (!q) return false;
    highlightGraphNodes(q);
    const hits = findGraphNodes(q);
    if (!hits.length) {
      setStatus(`未找到节点：${q}`);
      return false;
    }
    const ok = centerOnNode(hits[0]);
    if (ok) {
      const mfa = parseMfaLabel(nodeLabelText(hits[0]));
      if (mfa && !(opts && opts.skipDetail)) {
        showGraphNodeDetail(activeGraph || {}, mfa);
      }
      setStatus(`已居中：${nodeLabelText(hits[0])}` + (hits.length > 1 ? `（另有 ${hits.length - 1} 个匹配）` : ''));
    }
    return ok;
  }

  function centerMfaOfActive() {
    const mfa = activeGraph?.query?.mfa || payload?.query?.mfa || '';
    const q = (graphSearch?.value || '').trim() || mfa;
    if (!q) {
      setStatus('无指定中心函数（生成图时的 MFA 或搜索框）');
      return;
    }
    if (graphSearch && !graphSearch.value.trim() && mfa) graphSearch.value = mfa;
    // 先适配再居中，保证节点已布局
    fitGraph();
    requestAnimationFrame(() => centerOnQuery(q));
  }

  function highlightGraphNodes(q0) {
    const q = String(q0 || '').trim().toLowerCase();
    const nodes = graphCanvas.querySelectorAll('svg .node, svg g.node, svg [id^="flowchart-"]');
    let hits = 0;
    nodes.forEach((n) => {
      n.classList.remove('gv-hit', 'gv-dim');
      if (!q) return;
      const t = nodeLabelText(n).toLowerCase();
      if (t.includes(q)) {
        n.classList.add('gv-hit');
        hits += 1;
      } else {
        n.classList.add('gv-dim');
      }
    });
    if (graphSearchCount) graphSearchCount.textContent = q ? String(hits) : '0';
    return hits;
  }

  function afterGraphReady(g) {
    bindGraphNodeClicks(g);
    const mfa = g?.query?.mfa || '';
    if (mfa && graphSearch && !graphSearch.value.trim()) {
      graphSearch.value = mfa;
    }
    const q = (graphSearch?.value || '').trim() || mfa;
    if (graphDetailBody && mfa && !q) {
      graphDetailBody.classList.add('muted');
      graphDetailBody.innerHTML = `中心：<code>${escapeHtml(mfa)}</code><div class="muted">点击图中节点查看详情</div>`;
    }
    // 等布局完成：适配整图，再把指定函数放到窗口中央
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        fitGraph();
        setTimeout(() => {
          fitGraph();
          if (!q) return;
          highlightGraphNodes(q);
          const hits = findGraphNodes(q);
          if (hits[0]) centerOnNode(hits[0]);
        }, 60);
        setTimeout(() => {
          fitGraph();
          if (q) centerOnQuery(q);
        }, 200);
      });
    });
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

  async function showGraphNodeDetail(g, mfa) {
    if (!graphDetailBody) return;
    if (!mfa) {
      graphDetailBody.classList.add('muted');
      graphDetailBody.textContent = '无法解析节点标签';
      return;
    }
    graphDetailBody.classList.remove('muted');
    graphDetailBody.innerHTML = `<div class="graph-detail-head"><strong>${escapeHtml(mfa.label)}</strong></div>`
      + '<div class="muted">加载详情…</div>';

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
    let openPath = null;
    let openLine = null;
    const briefFromGraph = (g.briefs && mfa.label) ? g.briefs[mfa.label] : null;
    if (briefFromGraph) {
      annHtml = `<div class="graph-detail-label">源码简述</div>`
        + `<pre class="graph-detail-spec">${escapeHtml(String(briefFromGraph))}</pre>`;
    }
    if (mfa.module && mfa.function && mfa.arity != null) {
      try {
        const res = await fetch('/api/core/module', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ module: mfa.module, maxCalls: 40 }),
        });
        const data = await res.json();
        const doc = data.data?.document || data.data || {};
        if (doc.file) {
          openPath = doc.file;
          fileHtml = `<div>文件：<code>${escapeHtml(doc.file)}</code></div>`;
        }
        const funs = doc.functions || [];
        const hit = funs.find((f) =>
          (f.name === mfa.function || f.function === mfa.function)
            && Number(f.arity ?? f.a) === Number(mfa.arity));
        if (hit) {
          const start = hit.line ?? hit.start_line ?? hit.startLine;
          const end = hit.end_line ?? hit.endLine;
          if (start != null) openLine = Number(start);
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

    let openBtn = '';
    if (openPath) {
      openBtn = `<div style="margin:8px 0"><button type="button" class="btn" id="poOpenFile">在主窗打开文件</button></div>`;
    }

    graphDetailBody.innerHTML = `<div class="graph-detail-head"><strong>${escapeHtml(mfa.label)}</strong></div>`
      + `<div>模块：<code>${escapeHtml(mfa.module || '?')}</code></div>`
      + `<div>函数：<code>${escapeHtml(mfa.function || '?')}</code></div>`
      + `<div>元数（参数个数）：<code>${escapeHtml(String(mfa.arity ?? '?'))}</code></div>`
      + fileHtml
      + openBtn
      + annHtml
      + specHtml
      + (lines
        ? `<div class="graph-detail-label">相关调用边（${related.length}）</div><ul class="graph-detail-mods">${lines}</ul>`
        : '<div class="muted">当前图中无与该节点直接相关的边详情</div>');

    const openBtnEl = graphDetailBody.querySelector('#poOpenFile');
    if (openBtnEl && openPath) {
      openBtnEl.addEventListener('click', () => {
        postToOpener({ type: 'ali-popout-open-file', path: openPath, line: openLine });
        setStatus(`已请求主窗口打开 ${openPath}`);
      });
    }
  }

  function bindGraphNodeClicks(g) {
    graphCanvas.querySelectorAll('svg .node, svg g.node').forEach((node) => {
      node.style.cursor = 'pointer';
      node.addEventListener('click', (e) => {
        e.stopPropagation();
        const label = nodeLabelText(node);
        const fromTexts = Array.from(node.querySelectorAll('text, span, div'))
          .map((n) => (n.textContent || '').trim())
          .find((t) => t && t.includes(':') && t.includes('/'));
        const mfa = parseMfaLabel(label) || parseMfaLabel(fromTexts || '');
        showGraphNodeDetail(g || activeGraph || {}, mfa);
      });
    });
  }

  async function renderActiveGraph() {
    const g = activeGraph || {};
    metaEl.textContent = g.meta || payload.meta || '';
    titleEl.textContent = g.title || payload.title || '图';
    document.title = titleEl.textContent;
    graphSource.textContent = g.mermaid || g.markdown || '';
    graphCanvas.innerHTML = '';
    gvScale = 1;
    gvTx = 0;
    gvTy = 0;
    applyGraphTransform();

    if (g.mermaid && String(g.mermaid).trim() && window.mermaid) {
      const id = `po-mmd-${Date.now()}`;
      try {
        const { svg } = await window.mermaid.render(id, g.mermaid);
        graphCanvas.innerHTML = svg;
        const el = graphCanvas.querySelector('svg');
        if (el) {
          el.style.width = '1600px';
          el.style.height = 'auto';
          el.style.maxWidth = 'none';
        }
        afterGraphReady(g);
      } catch (err) {
        graphCanvas.innerHTML = `<pre>${escapeHtml(`渲染失败: ${err.message || err}\n\n${g.mermaid}`)}</pre>`;
      }
    } else if (g.svgHtml) {
      graphCanvas.innerHTML = g.svgHtml;
      afterGraphReady(g);
    } else if (g.markdown) {
      graphCanvas.innerHTML = `<pre>${escapeHtml(g.markdown)}</pre>`;
    } else {
      graphCanvas.textContent = '无可渲染内容';
    }
  }

  function downloadBlob(filename, mime, data) {
    const blob = new Blob([data], { type: mime });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = filename;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  }

  function initGraph() {
    graphBody.classList.remove('hidden');
    graphSearchRow.classList.remove('hidden');
    artifacts = Array.isArray(payload.artifacts) && payload.artifacts.length
      ? payload.artifacts
      : [{
          id: payload.activeId || 'g0',
          title: payload.title || '图',
          meta: payload.meta || '',
          mermaid: payload.mermaid || '',
          markdown: payload.markdown || '',
          svgHtml: payload.svgHtml || '',
        }];
    const idx = artifacts.findIndex((x) => x.id === payload.activeId);
    artifactIndex = idx >= 0 ? idx : 0;
    activeGraph = artifacts[artifactIndex];

    actionsEl.appendChild(btn('‹', '上一张图', async () => {
      if (artifacts.length < 2) return;
      artifactIndex = (artifactIndex - 1 + artifacts.length) % artifacts.length;
      activeGraph = artifacts[artifactIndex];
      await renderActiveGraph();
    }));
    actionsEl.appendChild(btn('›', '下一张图', async () => {
      if (artifacts.length < 2) return;
      artifactIndex = (artifactIndex + 1) % artifacts.length;
      activeGraph = artifacts[artifactIndex];
      await renderActiveGraph();
    }));

    actionsEl.appendChild(btn('−', '缩小', () => {
      gvScale = Math.max(0.2, gvScale * 0.9);
      applyGraphTransform();
    }));
    const z = document.createElement('span');
    z.className = 'zoom-label muted';
    z.dataset.gvzoom = '1';
    z.textContent = '100%';
    actionsEl.appendChild(z);
    actionsEl.appendChild(btn('+', '放大', () => {
      gvScale = Math.min(12, gvScale * 1.1);
      applyGraphTransform();
    }));
    actionsEl.appendChild(btn('适配', '适配窗口', () => fitGraph()));
    actionsEl.appendChild(btn('居中', '把指定函数（搜索框 / 生成图 MFA）放到窗口中央', () => centerMfaOfActive()));
    actionsEl.appendChild(btn('重置', '重置视图', () => {
      fitGraph();
      const mfa = activeGraph?.query?.mfa || '';
      if (mfa) {
        if (graphSearch) graphSearch.value = mfa;
        requestAnimationFrame(() => centerOnQuery(mfa));
      }
    }));
    actionsEl.appendChild(btn('复制源码', '复制 Mermaid', () => {
      copyText(activeGraph?.mermaid || graphSource.textContent || '');
    }));
    actionsEl.appendChild(btn('SVG', '下载 SVG', () => {
      const svg = graphCanvas.querySelector('svg');
      if (!svg) {
        setStatus('当前无 SVG');
        return;
      }
      downloadBlob(`${(activeGraph?.title || 'graph').replace(/\s+/g, '_')}.svg`, 'image/svg+xml', svg.outerHTML);
      setStatus('已下载 SVG');
    }));
    actionsEl.appendChild(btn('MMD', '下载 .mmd', () => {
      const src = activeGraph?.mermaid || '';
      if (!src) {
        setStatus('无 Mermaid 源码');
        return;
      }
      downloadBlob(`${(activeGraph?.title || 'graph').replace(/\s+/g, '_')}.mmd`, 'text/plain', src);
      setStatus('已下载 MMD');
    }));
    actionsEl.appendChild(btn('源码', '显示/隐藏源码', () => {
      showSource = !showSource;
      graphSource.classList.toggle('hidden', !showSource);
    }));

    graphViewport.addEventListener('wheel', (e) => {
      e.preventDefault();
      const factor = e.deltaY < 0 ? 1.1 : 0.9;
      const prev = gvScale;
      gvScale = Math.max(0.2, Math.min(12, gvScale * factor));
      const rect = graphViewport.getBoundingClientRect();
      const cx = e.clientX - rect.left;
      const cy = e.clientY - rect.top;
      gvTx = cx - ((cx - gvTx) * (gvScale / prev));
      gvTy = cy - ((cy - gvTy) * (gvScale / prev));
      applyGraphTransform();
    }, { passive: false });

    graphViewport.addEventListener('pointerdown', (e) => {
      if (e.button !== 0) return;
      if (e.target.closest('.node, g.node')) return;
      panState = { id: e.pointerId, x: e.clientX, y: e.clientY, tx: gvTx, ty: gvTy };
      try { graphViewport.setPointerCapture(e.pointerId); } catch { /* ignore */ }
    });
    graphViewport.addEventListener('pointermove', (e) => {
      if (!panState || panState.id !== e.pointerId) return;
      gvTx = panState.tx + (e.clientX - panState.x);
      gvTy = panState.ty + (e.clientY - panState.y);
      applyGraphTransform();
    });
    const endPan = (e) => {
      if (!panState || (e && panState.id !== e.pointerId)) return;
      panState = null;
    };
    graphViewport.addEventListener('pointerup', endPan);
    graphViewport.addEventListener('pointercancel', endPan);

    graphSearch?.addEventListener('input', () => highlightGraphNodes(graphSearch.value));
    graphSearch?.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        centerOnQuery(graphSearch.value);
      }
    });
    renderActiveGraph();
    setStatus(artifacts.length > 1 ? `图弹出窗就绪 · 共 ${artifacts.length} 张` : '图弹出窗就绪');
  }

  // -------- boot --------
  payload = loadPayload();
  if (!payload) {
    titleEl.textContent = '无法加载内容';
    setStatus('请从主窗口点击「弹出」打开（不要直接访问本页）');
    return;
  }
  zoomPct = payload.zoom || 100;

  if (kind === 'file') initFile();
  else if (kind === 'thinking') initThinking();
  else if (kind === 'graph') initGraph();
  else {
    titleEl.textContent = `未知类型: ${kind}`;
  }

  window.addEventListener('beforeunload', () => {
    postToOpener({ type: 'ali-popout-closed', kind });
  });
})();
