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
const fileInput = document.getElementById('fileInput');
const attachPreview = document.getElementById('attachPreview');
const btnClear = document.getElementById('btnClear');
const btnRefreshIndex = document.getElementById('btnRefreshIndex');
const btnEunit = document.getElementById('btnEunit');
const btnTasks = document.getElementById('btnTasks');
const btnCloseSide = document.getElementById('btnCloseSide');
const sidePanel = document.getElementById('sidePanel');
const tasksList = document.getElementById('tasksList');
const planList = document.getElementById('planList');
const metricsBox = document.getElementById('metricsBox');
const approveBar = document.getElementById('approveBar');
const approveText = document.getElementById('approveText');
const approveDiff = document.getElementById('approveDiff');
const btnApprove = document.getElementById('btnApprove');
const btnDismissApprove = document.getElementById('btnDismissApprove');
const connDot = document.getElementById('connDot');

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
  finishThinking();
  if (msgWrap) msgWrap.classList.remove('streaming', 'pending');
  // 流式结束后，若回答含结构化块，重新渲染消息体
  if (msgWrap && !error) {
    const msgBody = msgWrap.querySelector('.msg-body');
    if (msgBody && value) finalizeStructuredMessage(msgBody, value);
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
  if (ev.type === 'answer') return;
  if (ev.type === 'step' || ev.type === 'started') {
    setThinkingStatus(ev.message || formatEvent(ev));
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

async function stopAsk() {
  const sid = sessionSelect.value || 'web';
  if (activeAskAbort) {
    activeAskAbort.abort();
    activeAskAbort = null;
  }
  if (activeAsk?.es) {
    try { activeAsk.es.close(); } catch { /* ignore */ }
  }
  try {
    await ctrl('cancelAsk', { sessionId: sid }, '/api/ask/cancel', {
      method: 'POST',
      body: JSON.stringify({ sessionId: sid }),
    });
  } catch (e) {
    appendMsg('system', `停止失败: ${e.message}`);
    setAsking(false);
    setStatus('就绪');
    return;
  }
  if (activeAsk) {
    const partial = activeAsk.full || '';
    finishActiveAsk(null, partial);
    if (partial) maybeShowApprove(partial);
  }
  appendMsg('system', '已停止当前回答');
  setAsking(false);
  setStatus('就绪');
}

/** 服务端 GET / 注入的公开配置（见 alConfig:publicWebConfig/0） */
let attachLimits = {
  maxImages: 16,
  maxFiles: 10,
  maxImageBytes: 20971520,
  maxFileBytes: 5242880,
  textFileExtensions: [],
  imageMimeTypes: ['image/jpeg', 'image/png', 'image/gif', 'image/webp'],
  textFileRe: null,
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
  if (cfg.web?.authEnabled && !apiToken()) {
    setStatus('需要 Token（点击右上角 Token 设置）');
  }
}

function currentSessionId() {
  return sessionSelect.value || 'web';
}

function visionSupported() {
  const cfg = window.__ALI_CONFIG__ || {};
  const provider = String(cfg.llm?.provider || '').toLowerCase();
  const model = String(cfg.llm?.model || '').toLowerCase();
  if (provider === 'anthropic') return true;
  if (provider === 'deepseek') return false;
  return /gpt-4o|gpt-4-turbo|gpt-4-vision|gpt-4\.1|o[134]/.test(model);
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
  return /\.pdf$/i.test(file.name);
}

function isTextFile(file) {
  if (isImageFile(file) || isDocumentFile(file)) return false;
  if (file.type.startsWith('text/')) return true;
  if (file.type === 'application/json' || file.type === 'application/xml') return true;
  if (file.type === 'application/javascript') return true;
  return attachLimits.textFileRe ? attachLimits.textFileRe.test(file.name) : false;
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
    .replace(/>/g, '&gt;');
}

//==================================================================
// 结构化输出渲染：Mermaid 图表 / Markdown 表格 / 围栏代码块
//==================================================================

// 判断文本是否包含结构化块（围栏代码块或 Markdown 表格）。
function hasStructuredContent(text) {
  if (!text) return false;
  return /(^|\n)```/.test(text) || /(^|\n)\|.*\|\s*\n\|[\s\-:|]+\|/.test(text);
}

// 将 agent 文本渲染为结构化 DOM 片段。
// 解析顺序：围栏代码块（含 mermaid）→ Markdown 表格 → 普通文本。
function renderStructuredContent(text) {
  const frag = document.createDocumentFragment();
  if (!text) return frag;
  const blocks = parseStructuredBlocks(String(text));
  blocks.forEach((b) => frag.appendChild(renderBlock(b)));
  return frag;
}

// 解析文本为块列表：{type:'text'|'mermaid'|'code'|'table', ...}
function parseStructuredBlocks(text) {
  const blocks = [];
  const lines = text.split('\n');
  let i = 0;
  let textBuf = [];

  const flushText = () => {
    if (textBuf.length > 0) {
      blocks.push({ type: 'text', text: textBuf.join('\n') });
      textBuf = [];
    }
  };

  while (i < lines.length) {
    const line = lines[i];
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
      i += 1; // 跳过闭合围栏
      const code = body.join('\n');
      if (lang.toLowerCase() === 'mermaid') {
        blocks.push({ type: 'mermaid', code });
      } else {
        blocks.push({ type: 'code', lang, code });
      }
      continue;
    }
    // 表格检测：当前行是 |...|，下一行是 |---|---|
    if (/^\s*\|.*\|\s*$/.test(line) && i + 1 < lines.length && /^\s*\|[\s\-:|]+\|\s*$/.test(lines[i + 1])) {
      flushText();
      const header = splitTableRow(line);
      i += 2; // 跳过分隔行
      const rows = [];
      while (i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i])) {
        rows.push(splitTableRow(lines[i]));
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

function splitTableRow(line) {
  const trimmed = line.trim().replace(/^\|/, '').replace(/\|$/, '');
  return trimmed.split('|').map((c) => c.trim());
}

// 渲染单个块为 DOM 元素。
function renderBlock(b) {
  if (b.type === 'mermaid') return renderMermaidBlock(b.code);
  if (b.type === 'code') return renderCodeBlock(b.lang, b.code);
  if (b.type === 'table') return renderTableBlock(b.header, b.rows);
  // text 块：保留换行
  const div = document.createElement('div');
  div.className = 'struct-text';
  div.textContent = b.text;
  return div;
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

// 渲染围栏代码块：带语言标签与复制按钮。
function renderCodeBlock(lang, code) {
  const wrap = document.createElement('div');
  wrap.className = 'code-block';
  const header = document.createElement('div');
  header.className = 'code-header';
  const langSpan = document.createElement('span');
  langSpan.className = 'code-lang';
  langSpan.textContent = lang || 'text';
  header.appendChild(langSpan);
  const copyBtn = document.createElement('button');
  copyBtn.className = 'code-copy btn-muted btn-xs';
  copyBtn.type = 'button';
  copyBtn.textContent = '复制';
  copyBtn.addEventListener('click', () => {
    navigator.clipboard.writeText(code).then(() => {
      copyBtn.textContent = '已复制';
      setTimeout(() => { copyBtn.textContent = '复制'; }, 1500);
    });
  });
  header.appendChild(copyBtn);
  wrap.appendChild(header);
  const pre = document.createElement('pre');
  pre.className = 'code-body';
  pre.textContent = code;
  wrap.appendChild(pre);
  return wrap;
}

// 渲染 Markdown 表格为 HTML table。
function renderTableBlock(header, rows) {
  const wrap = document.createElement('div');
  wrap.className = 'table-wrap';
  const table = document.createElement('table');
  table.className = 'md-table';
  const thead = document.createElement('thead');
  const headRow = document.createElement('tr');
  header.forEach((h) => {
    const th = document.createElement('th');
    th.textContent = h;
    headRow.appendChild(th);
  });
  thead.appendChild(headRow);
  table.appendChild(thead);
  const tbody = document.createElement('tbody');
  rows.forEach((r) => {
    const tr = document.createElement('tr');
    r.forEach((c) => {
      const td = document.createElement('td');
      td.textContent = c;
      tr.appendChild(td);
    });
    tbody.appendChild(tr);
  });
  table.appendChild(tbody);
  wrap.appendChild(table);
  return wrap;
}

// 流式完成后，将 msg-body 的纯文本替换为结构化渲染结果。
function finalizeStructuredMessage(msgBody, text) {
  if (!msgBody || !text || !hasStructuredContent(text)) return;
  // 保留原始文本用于复制
  msgBody.dataset.rawText = text;
  // 清空现有文本节点
  while (msgBody.firstChild) msgBody.removeChild(msgBody.firstChild);
  msgBody.appendChild(renderStructuredContent(text));
}

//==================================================================
// WebSocket 客户端（控制面 + 流式问答），失败时回退 REST/SSE
//==================================================================
const WS = {
  sock: null,
  connected: false,
  streamHandler: null,
  resolvers: {},
  retry: 0,

  url() {
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const token = apiToken();
    const q = token ? `?token=${encodeURIComponent(token)}` : '';
    return `${proto}//${location.host}/ws${q}`;
  },

  connect() {
    try {
      const sock = new WebSocket(this.url());
      this.sock = sock;
      sock.onopen = () => {
        this.connected = true;
        this.retry = 0;
        setConn(true);
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
    }
  },

  reconnect() {
    if (this.retry > 6) return;
    this.retry += 1;
    setTimeout(() => this.connect(), Math.min(1000 * this.retry, 5000));
  },

  send(obj) {
    this.sock.send(JSON.stringify(obj));
  },

  request(type, extra = {}, timeoutMs = 30000) {
    return new Promise((resolve, reject) => {
      if (!this.connected) return reject(new Error('ws not connected'));
      (this.resolvers[type] = this.resolvers[type] || []).push(resolve);
      const t = setTimeout(() => reject(new Error('ws timeout')), timeoutMs);
      const q = this.resolvers[type];
      const orig = q[q.length - 1];
      q[q.length - 1] = (m) => { clearTimeout(t); orig(m); };
      try { this.send({ type, ...extra }); }
      catch (err) { clearTimeout(t); reject(err); }
    });
  },

  onMessage(e) {
    let m;
    try { m = JSON.parse(e.data); } catch { return; }
    if (['token', 'progress', 'done', 'ack'].includes(m.type)) {
      if (this.streamHandler) this.streamHandler(m);
      return;
    }
    const q = this.resolvers[m.type];
    if (q && q.length) { q.shift()(m); }
  },
};

function setConn(ok) {
  if (!connDot) return;
  connDot.classList.toggle('online', ok);
  connDot.title = ok ? 'WebSocket 已连接' : '未连接（使用 HTTP 回退）';
}

// 控制命令：优先走 WS，未连接时回退 REST。
async function ctrl(type, extra, restPath, restOpts) {
  if (WS.connected) {
    return WS.request(type, extra || {});
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

function attachCopyButton(wrap, body) {
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
  wrap.appendChild(btn);
  return btn;
}

let scrollRaf = null;
let stickToBottom = true;

function isNearBottom(el, threshold = 100) {
  return el.scrollHeight - el.scrollTop - el.clientHeight <= threshold;
}

chat.addEventListener('scroll', () => { stickToBottom = isNearBottom(chat); }, { passive: true });

function scrollChatToBottom(force = false) {
  if (!force && !stickToBottom) return;
  if (scrollRaf) cancelAnimationFrame(scrollRaf);
  scrollRaf = requestAnimationFrame(() => {
    requestAnimationFrame(() => { scrollRaf = null; chat.scrollTop = chat.scrollHeight; });
  });
}

const chatObserver = new MutationObserver(() => scrollChatToBottom());
chatObserver.observe(chat, { childList: true, subtree: true, characterData: true });

function appendMsg(role, text, attachments = []) {
  const wrap = document.createElement('div');
  wrap.className = `msg ${role}`;
  if (role === 'agent') {
    const body = document.createElement('div');
    body.className = 'msg-body';
    // 非流式 agent 消息：若含结构化块则渲染，否则纯文本
    if (text && hasStructuredContent(text)) {
      body.dataset.rawText = text;
      body.appendChild(renderStructuredContent(text));
    } else {
      body.appendChild(document.createTextNode(text));
    }
    wrap.appendChild(body);
    attachCopyButton(wrap, body);
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
        chip.textContent = a.kind === 'document' ? `PDF ${a.name || ''}`.trim() : (a.name || 'file');
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
    const mediaType = file.type || 'application/pdf';
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
      chip.textContent = a.kind === 'document' ? `PDF ${a.name || ''}`.trim() : a.name;
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
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}

function formatEvent(ev) {
  const type = ev.type || '';
  const tool = ev.tool || '';
  if (type === 'started') return ev.message || '任务已开始';
  if (type === 'step') {
    const step = ev.step != null ? ` ${ev.step}/${ev.maxSteps}` : '';
    return `[步骤${step}] ${ev.message || '思考中'}`;
  }
  if (type === 'tool') {
    const args = ev.args ? ` ${JSON.stringify(ev.args)}` : '';
    return `→ 调用工具 ${tool}${args}`;
  }
  if (type === 'tool_done') {
    const ms = ev.elapsedMs != null ? ` (${ev.elapsedMs}ms)` : '';
    if (ev.ok) return `✓ ${tool} 完成${ms}`;
    if (ev.status === 'confirmationRequired') return `⊙ ${tool} 需确认`;
    if (ev.error) return `✗ ${tool} 失败: ${typeof ev.error === 'string' ? ev.error : JSON.stringify(ev.error)}${ms}`;
    return `✗ ${tool} 失败${ms}`;
  }
  if (type === 'error') return `! 错误: ${formatErrorReason(ev.reason)}`;
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

const STATUS_LINE_RE = /^(正在连接|模型回答中|正在请求|准备会话|上下文就绪|任务已开始)/;

function startThinking() {
  thinkingBox = document.createElement('div');
  thinkingBox.className = 'msg thinking';
  thinkingBox.innerHTML =
    '<div class="thinking-title">思考中...</div><div class="thinking-status">正在连接...</div><ul class="thinking-log"></ul>';
  thinkingList = thinkingBox.querySelector('.thinking-log');
  thinkingStatus = thinkingBox.querySelector('.thinking-status');
  chat.appendChild(thinkingBox);
  scrollChatToBottom();
}

function setThinkingStatus(text) {
  if (!thinkingStatus || !text) return;
  thinkingStatus.textContent = String(text).trim();
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
  scrollChatToBottom();
}

function finishThinking() {
  if (thinkingBox) {
    const title = thinkingBox.querySelector('.thinking-title');
    const count = thinkingList ? thinkingList.children.length : 0;
    if (title) title.textContent = count > 0 ? `思考完成（${count} 步）` : '思考完成';
    if (thinkingStatus) thinkingStatus.textContent = '';
    thinkingBox.classList.add('thinking-done');
    thinkingBox = null;
    thinkingList = null;
    thinkingStatus = null;
  }
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
// 审批 + 可视化 diff
//==================================================================
function renderDiff(diffText) {
  if (!diffText) { approveDiff.classList.add('hidden'); return; }
  const html = String(diffText).split('\n').map((line) => {
    let cls = 'diff-ctx';
    if (line.startsWith('+') && !line.startsWith('+++')) cls = 'diff-add';
    else if (line.startsWith('-') && !line.startsWith('---')) cls = 'diff-del';
    else if (line.startsWith('@@')) cls = 'diff-hunk';
    return `<span class="${cls}">${escapeHtml(line)}</span>`;
  }).join('\n');
  approveDiff.innerHTML = html;
  approveDiff.classList.remove('hidden');
}

async function getPending(taskId) {
  if (WS.connected) {
    const m = await WS.request('pending', { taskId });
    if (m.ok === false) throw new Error(m.error || 'pending not found');
    return m;
  }
  return api(`/api/pending/${encodeURIComponent(taskId)}`);
}

async function showApproveBar(taskId, previewText) {
  pendingTaskId = taskId;
  approveText.textContent = previewText || `操作待确认 (TaskId: ${taskId})`;
  approveBar.classList.remove('hidden');
  approveDiff.classList.add('hidden');
  try {
    const p = await getPending(taskId);
    if (p && p.diff) renderDiff(p.diff);
  } catch { /* 无 diff 时忽略 */ }
}

function hideApproveBar() {
  pendingTaskId = null;
  approveBar.classList.add('hidden');
  approveDiff.classList.add('hidden');
}

function maybeShowApprove(fullText) {
  const tid = extractTaskId(fullText);
  if (tid) showApproveBar(tid, 'Agent 请求修改文件，需批准后执行');
}

//==================================================================
// 问答：WS 优先，SSE 回退
//==================================================================
function askViaWS(prompt, sessionId, attachments = []) {
  return new Promise((resolve, reject) => {
    stickToBottom = true;
    scrollChatToBottom(true);
    startThinking();
    const msgBody = appendMsg('agent', '');
    const textNode = msgBody.firstChild;
    const msgWrap = msgBody.parentElement;
    msgWrap.classList.add('streaming', 'pending');
    let full = '';
    let sawChunk = false;
    const timeout = setTimeout(() => finishActiveAsk('流式回答超时'), 600000);

    activeAsk = { timeout, msgWrap, full: '', resolve, reject, finished: false };

    WS.streamHandler = (m) => {
      if (m.type === 'ack') return;
      if (m.type === 'progress') {
        handleStreamProgress(m.event || {});
        return;
      }
      if (m.type === 'token') {
        const t = extractModelText(m.data);
        if (!t) return;
        full += t;
        if (activeAsk) activeAsk.full = full;
        if (!sawChunk) { sawChunk = true; msgWrap.classList.remove('pending'); setThinkingStatus('模型回答中...'); }
        textNode.appendData(t);
        scrollChatToBottom();
        return;
      }
      if (m.type === 'done') {
        if (!activeAsk) return;
        maybeShowApprove(full);
        finishActiveAsk(null, full);
      }
    };
    try {
      const payload = { type: 'ask', prompt, sessionId, ...splitAttachments(attachments) };
      WS.send(payload);
    } catch (err) {
      finishActiveAsk(err.message || String(err));
    }
  });
}

function askViaSSE(prompt, sessionId = 'web') {
  const token = apiToken();
  const params = new URLSearchParams({ prompt, sessionId });
  if (token) params.set('token', token);
  const url = `/api/ask/stream?${params.toString()}`;
  return runSseStream(url, null);
}

function askViaPostStream(prompt, sessionId = 'web', attachments = []) {
  const token = apiToken();
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  const body = JSON.stringify({ prompt, sessionId, ...splitAttachments(attachments) });
  return runSseStream('/api/ask/stream', { method: 'POST', headers, body });
}

function runSseStream(url, fetchOptions) {
  stickToBottom = true;
  scrollChatToBottom(true);
  startThinking();

  return new Promise((resolve, reject) => {
    let fullText = '';
    let sawChunk = false;
    const msgBody = appendMsg('agent', '');
    const textNode = msgBody.firstChild;
    const msgWrap = msgBody.parentElement;
    msgWrap.classList.add('streaming', 'pending');

    const timeout = setTimeout(() => finishActiveAsk('流式回答超时'), 600000);

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
          finish(new Error(data.error || `HTTP ${res.status}`));
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
              return;
            }
            if (eventType === 'done') { finish(); return; }
            const modelText = extractModelText(data);
            if (!modelText) return;
            fullText += modelText;
            if (activeAsk) activeAsk.full = fullText;
            if (!sawChunk) { sawChunk = true; msgWrap.classList.remove('pending'); setThinkingStatus('模型回答中...'); }
            if (textNode) textNode.appendData(modelText); else msgBody.textContent = fullText;
            scrollChatToBottom();
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
    });

    es.onmessage = (e) => {
      const modelText = extractModelText(e.data);
      if (!modelText) return;
      fullText += modelText;
      if (activeAsk) activeAsk.full = fullText;
      if (!sawChunk) { sawChunk = true; msgWrap.classList.remove('pending'); setThinkingStatus('模型回答中...'); }
      if (textNode) textNode.appendData(modelText); else msgBody.textContent = fullText;
      scrollChatToBottom();
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

function ask(prompt, sessionId, attachments = []) {
  if (attachments.length > 0 && !WS.connected) {
    return askViaPostStream(prompt, sessionId, attachments);
  }
  return WS.connected ? askViaWS(prompt, sessionId, attachments) : askViaSSE(prompt, sessionId);
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
    const steps = data.steps || [];
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
    const m = await ctrl('metrics', {}, '/api/metrics');
    const rows = [
      ['ask 次数', m.askCount ?? 0],
      ['成功', m.okCount ?? 0],
      ['失败', m.errorCount ?? 0],
      ['工具调用', m.totalToolCalls ?? 0],
      ['平均耗时', `${m.avgDurationMs ?? 0} ms`],
      ['总耗时', `${m.totalDurationMs ?? 0} ms`],
    ];
    metricsBox.innerHTML = rows.map(([k, v]) =>
      `<div class="metric-row"><span>${k}</span><strong>${escapeHtml(String(v))}</strong></div>`).join('');
  } catch (e) {
    metricsBox.innerHTML = `<div class="muted">加载失败: ${escapeHtml(e.message)}</div>`;
  }
}

//==================================================================
// 面板切换
//==================================================================
const tabLoaders = { tasks: loadTasks, plan: loadPlan, metrics: loadMetrics };

function showTab(name) {
  document.querySelectorAll('.side-tab').forEach((t) => t.classList.toggle('active', t.dataset.tab === name));
  document.getElementById('tabTasks').classList.toggle('hidden', name !== 'tasks');
  document.getElementById('tabPlan').classList.toggle('hidden', name !== 'plan');
  document.getElementById('tabMetrics').classList.toggle('hidden', name !== 'metrics');
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
  appendMsg('user', prompt, attachments);
  setAsking(true);
  setStatus('思考中...');
  try {
    await ask(prompt, sessionSelect.value || 'web', attachments);
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

sessionSelect.addEventListener('change', async () => {
  const sid = sessionSelect.value;
  if (!sid) return;
  try {
    const data = await api('/api/sessions/load', { method: 'POST', body: JSON.stringify({ sessionId: sid }) });
    renderChatFromMessages(data.messages || []);
    appendMsg('system', `已加载会话: ${sid}（${(data.messages || []).length} 条消息）`);
  } catch (e) {
    appendMsg('system', `加载会话失败: ${e.message}`);
  }
});

if (btnSaveSession) btnSaveSession.addEventListener('click', async () => {
  const sid = currentSessionId();
  try {
    await ctrl('saveSession', { sessionId: sid }, '/api/sessions/save', {
      method: 'POST',
      body: JSON.stringify({ sessionId: sid }),
    });
    appendMsg('system', `会话已保存: ${sid}`);
    await loadSessions();
  } catch (e) {
    appendMsg('system', `保存失败: ${e.message}`);
  }
});

if (btnDeleteSession) btnDeleteSession.addEventListener('click', async () => {
  const sid = currentSessionId();
  if (!sid || sid === 'web') {
    appendMsg('system', '不能删除默认 web 会话文件');
    return;
  }
  if (!window.confirm(`删除已保存的会话「${sid}」？`)) return;
  try {
    await ctrl('deleteSession', { sessionId: sid }, '/api/sessions/delete', {
      method: 'POST',
      body: JSON.stringify({ sessionId: sid }),
    });
    appendMsg('system', `已删除会话: ${sid}`);
    sessionSelect.value = 'web';
    await loadSessions();
  } catch (e) {
    appendMsg('system', `删除失败: ${e.message}`);
  }
});

btnClear.addEventListener('click', async () => {
  const sid = currentSessionId();
  try {
    await api('/api/clear', { method: 'POST', body: JSON.stringify({ sessionId: sid }) });
    chat.innerHTML = '';
    hideApproveBar();
    appendMsg('system', `会话已清空: ${sid}`);
  } catch (e) {
    appendMsg('system', `清空失败: ${e.message}`);
  }
});

btnRefreshIndex.addEventListener('click', async () => {
  setStatus('刷新索引...');
  try {
    const data = await api('/api/index/refresh', { method: 'POST', body: '{}' });
    appendMsg('system', `索引已刷新: ${data.moduleCount ?? data.indexed ?? '-'} 模块`);
    setStatus('就绪');
  } catch (e) {
    appendMsg('system', `索引刷新失败: ${e.message}`);
    setStatus('出错');
  }
});

btnEunit.addEventListener('click', async () => {
  setStatus('运行 EUnit...');
  btnEunit.disabled = true;
  try {
    const data = await api('/api/eunit/run', { method: 'POST', body: '{"module":"all"}' });
    const ok = data.success ? '通过' : '失败';
    appendMsg('system', `EUnit ${ok} (exit=${data.exitCode})\n${(data.output || '').slice(0, 2000)}`);
    setStatus('就绪');
  } catch (e) {
    appendMsg('system', `EUnit 失败: ${e.message}`);
    setStatus('出错');
  } finally {
    btnEunit.disabled = false;
  }
});

btnApprove.addEventListener('click', async () => {
  if (!pendingTaskId) return;
  btnApprove.disabled = true;
  const tid = pendingTaskId;
  try {
    let payload;
    if (WS.connected) {
      const m = await WS.request('approve', { taskId: tid });
      if (m.ok === false) throw new Error(m.error || 'approve failed');
      payload = m;
    } else {
      payload = await api('/api/approve', { method: 'POST', body: JSON.stringify({ taskId: tid }) });
    }
    appendMsg('system', `已批准执行 (TaskId: ${tid})`);
    if (payload.answer) appendMsg('agent', payload.answer);
    else if (payload.result) appendMsg('agent', JSON.stringify(payload.result, null, 2).slice(0, 4000));
    hideApproveBar();
  } catch (e) {
    appendMsg('system', `批准失败: ${e.message}`);
  } finally {
    btnApprove.disabled = false;
  }
});

btnDismissApprove.addEventListener('click', async () => {
  if (!pendingTaskId) { hideApproveBar(); return; }
  const tid = pendingTaskId;
  try {
    let payload;
    if (WS.connected) {
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

btnTasks.addEventListener('click', () => {
  sidePanel.classList.toggle('hidden');
  if (!sidePanel.classList.contains('hidden')) {
    const active = document.querySelector('.side-tab.active');
    showTab(active ? active.dataset.tab : 'tasks');
  }
});

btnCloseSide.addEventListener('click', () => sidePanel.classList.add('hidden'));

//==================================================================
// 启动
//==================================================================
WS.connect();
loadStatus();
loadSessions();
