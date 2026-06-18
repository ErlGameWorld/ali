const chat = document.getElementById('chat');
const promptEl = document.getElementById('prompt');
const statusText = document.getElementById('statusText');
const modeSelect = document.getElementById('modeSelect');
const sessionSelect = document.getElementById('sessionSelect');
const btnSend = document.getElementById('btnSend');
const btnClear = document.getElementById('btnClear');
const btnRefreshIndex = document.getElementById('btnRefreshIndex');
const btnEunit = document.getElementById('btnEunit');
const btnTasks = document.getElementById('btnTasks');
const btnCloseTasks = document.getElementById('btnCloseTasks');
const tasksPanel = document.getElementById('tasksPanel');
const tasksList = document.getElementById('tasksList');
const approveBar = document.getElementById('approveBar');
const approveText = document.getElementById('approveText');
const btnApprove = document.getElementById('btnApprove');
const btnDismissApprove = document.getElementById('btnDismissApprove');

let pendingTaskId = null;

const COPY_ICON = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v16c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 18H8V7h11v16z"/></svg>`;

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
    setTimeout(() => {
      btn.classList.remove('copied');
      btn.title = '复制';
    }, 1500);
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
    copyText(body.textContent, btn);
  });
  wrap.appendChild(btn);
  return btn;
}

let scrollRaf = null;
let stickToBottom = true;

function isNearBottom(el, threshold = 100) {
  return el.scrollHeight - el.scrollTop - el.clientHeight <= threshold;
}

chat.addEventListener('scroll', () => {
  stickToBottom = isNearBottom(chat);
}, { passive: true });

function scrollChatToBottom(force = false) {
  if (!force && !stickToBottom) return;
  if (scrollRaf) cancelAnimationFrame(scrollRaf);
  scrollRaf = requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      scrollRaf = null;
      chat.scrollTop = chat.scrollHeight;
    });
  });
}

const chatObserver = new MutationObserver(() => scrollChatToBottom());
chatObserver.observe(chat, { childList: true, subtree: true, characterData: true });

function appendMsg(role, text) {
  const wrap = document.createElement('div');
  wrap.className = `msg ${role}`;

  if (role === 'agent') {
    const body = document.createElement('div');
    body.className = 'msg-body';
    const textNode = document.createTextNode(text);
    body.appendChild(textNode);
    wrap.appendChild(body);
    attachCopyButton(wrap, body);
    chat.appendChild(wrap);
    scrollChatToBottom(true);
    return body;
  }

  wrap.textContent = text;
  chat.appendChild(wrap);
  scrollChatToBottom(true);
  return wrap;
}

function setStatus(text) {
  statusText.textContent = text;
}

function apiToken() {
  return localStorage.getItem('alToken') || '';
}

async function api(path, options = {}) {
  const token = apiToken();
  const headers = { 'Content-Type': 'application/json', ...(options.headers || {}) };
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }
  const sep = path.includes('?') ? '&' : '?';
  const url = token && !headers.Authorization
    ? `${path}${sep}token=${encodeURIComponent(token)}`
    : path;
  const res = await fetch(url, { ...options, headers });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(data.error || `HTTP ${res.status}`);
  }
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
  if (type === 'error') return `! 错误: ${ev.reason || 'unknown'}`;
  return JSON.stringify(ev);
}

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
  if (isStatusLine(line)) {
    setThinkingStatus(line);
    return;
  }
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
    if (title) {
      title.textContent = count > 0 ? `思考完成（${count} 步）` : '思考完成';
    }
    if (thinkingStatus) thinkingStatus.textContent = '';
    thinkingBox.classList.add('thinking-done');
    thinkingBox = null;
    thinkingList = null;
    thinkingStatus = null;
  }
}

function extractModelText(chunk) {
  if (!chunk) return '';
  return String(chunk)
    .split('\n')
    .filter((line) => !line.trim().startsWith('→ 调用工具'))
    .join('\n');
}

function extractTaskId(text) {
  if (!text) return null;
  const m = String(text).match(/TaskId:\s*(\d+)/i);
  return m ? m[1] : null;
}

function showApproveBar(taskId, previewText) {
  pendingTaskId = taskId;
  approveText.textContent = previewText || `操作待确认 (TaskId: ${taskId})`;
  approveBar.classList.remove('hidden');
}

function hideApproveBar() {
  pendingTaskId = null;
  approveBar.classList.add('hidden');
}

async function askWithProgress(prompt, sessionId = 'web') {
  const token = apiToken();
  const params = new URLSearchParams({ prompt, sessionId });
  if (token) params.set('token', token);
  const url = `/api/ask/stream?${params.toString()}`;
  stickToBottom = true;
  scrollChatToBottom(true);
  startThinking();

  return new Promise((resolve, reject) => {
    let done = false;
    let fullText = '';
    let sawChunk = false;
    const msgBody = appendMsg('agent', '');
    const textNode = msgBody.firstChild;
    const msgWrap = msgBody.parentElement;
    msgWrap.classList.add('streaming', 'pending');
    let statusRaf = null;

    const es = new EventSource(url);
    const timeout = setTimeout(() => {
      if (!done) {
        es.close();
        finishThinking();
        msgWrap.classList.remove('streaming');
        reject(new Error('流式回答超时'));
      }
    }, 600000);

    es.addEventListener('progress', (e) => {
      try {
        const ev = JSON.parse(e.data);
        if (ev.type === 'answer') return;
        if (ev.type === 'step' || ev.type === 'started') {
          setThinkingStatus(ev.message || formatEvent(ev));
          return;
        }
        const line = formatEvent(ev);
        if (line && !line.startsWith('{')) addThinkingLine(line);
      } catch {
        /* ignore */
      }
    });

    es.onmessage = (e) => {
      const modelText = extractModelText(e.data);
      if (!modelText) return;
      fullText += modelText;
      if (!sawChunk) {
        sawChunk = true;
        msgWrap.classList.remove('pending');
        setThinkingStatus('模型回答中...');
      }
      if (textNode) {
        textNode.appendData(modelText);
      } else {
        msgBody.textContent = fullText;
      }
      if (!statusRaf) {
        statusRaf = requestAnimationFrame(() => {
          statusRaf = null;
          setStatus('接收回答中...');
        });
      }
      scrollChatToBottom();
    };

    es.addEventListener('done', () => {
      done = true;
      clearTimeout(timeout);
      es.close();
      finishThinking();
      msgWrap.classList.remove('streaming');
      const tid = extractTaskId(fullText);
      if (tid) showApproveBar(tid, 'Agent 请求修改文件，需批准后执行');
      resolve(fullText);
    });

    es.onerror = () => {
      if (!done) {
        clearTimeout(timeout);
        es.close();
        finishThinking();
        msgWrap.classList.remove('streaming');
        reject(new Error('SSE 连接错误或中断'));
      }
    };
  });
}

async function loadStatus() {
  try {
    const data = await api('/api/status');
    const mode = data.agent?.mode || 'ask';
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
    sessionSelect.innerHTML = '<option value="">当前会话</option>';
    saved.forEach((id) => {
      const opt = document.createElement('option');
      opt.value = id;
      opt.textContent = id;
      sessionSelect.appendChild(opt);
    });
  } catch {
    /* ignore */
  }
}

async function loadTasks() {
  try {
    const data = await api('/api/tasks');
    const tasks = data.tasks || [];
    tasksList.innerHTML = '';
    if (tasks.length === 0) {
      tasksList.innerHTML = '<li class="muted">无任务</li>';
      return;
    }
    tasks.forEach((t) => {
      const li = document.createElement('li');
      const id = t.id || t.taskId || '?';
      const status = t.status || 'unknown';
      li.innerHTML = `<span>${id}</span> <span class="muted">${status}</span>`;
      if (status === 'running') {
        const btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'btn-muted btn-sm';
        btn.textContent = '取消';
        btn.onclick = async () => {
          await api('/api/tasks/cancel', {
            method: 'POST',
            body: JSON.stringify({ taskId: id }),
          });
          loadTasks();
        };
        li.appendChild(btn);
      }
      tasksList.appendChild(li);
    });
  } catch (e) {
    tasksList.innerHTML = `<li class="muted">加载失败: ${e.message}</li>`;
  }
}

btnSend.addEventListener('click', async () => {
  const prompt = promptEl.value.trim();
  if (!prompt) return;
  promptEl.value = '';
  stickToBottom = true;
  appendMsg('user', prompt);
  btnSend.disabled = true;
  setStatus('思考中...');
  try {
    await askWithProgress(prompt, sessionSelect.value || 'web');
    setStatus('就绪');
  } catch (e) {
    appendMsg('system', `错误: ${e.message}`);
    setStatus('出错');
  } finally {
    btnSend.disabled = false;
  }
});

promptEl.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    btnSend.click();
  }
});

modeSelect.addEventListener('change', async () => {
  try {
    await api('/api/mode', {
      method: 'POST',
      body: JSON.stringify({ mode: modeSelect.value }),
    });
    appendMsg('system', `已切换模式: ${modeSelect.value}`);
  } catch (e) {
    appendMsg('system', `切换模式失败: ${e.message}`);
  }
});

sessionSelect.addEventListener('change', async () => {
  const sid = sessionSelect.value;
  if (!sid) return;
  try {
    await api('/api/sessions/load', {
      method: 'POST',
      body: JSON.stringify({ sessionId: sid }),
    });
    appendMsg('system', `已加载会话: ${sid}`);
  } catch (e) {
    appendMsg('system', `加载会话失败: ${e.message}`);
  }
});

btnClear.addEventListener('click', async () => {
  try {
    await api('/api/clear', { method: 'POST', body: '{}' });
    chat.innerHTML = '';
    hideApproveBar();
    appendMsg('system', '会话已清空');
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
  try {
    const data = await api('/api/approve', {
      method: 'POST',
      body: JSON.stringify({ taskId: pendingTaskId }),
    });
    appendMsg('system', `已批准执行 (TaskId: ${pendingTaskId})`);
    if (data.result) {
      appendMsg('agent', JSON.stringify(data.result, null, 2).slice(0, 4000));
    }
    hideApproveBar();
  } catch (e) {
    appendMsg('system', `批准失败: ${e.message}`);
  } finally {
    btnApprove.disabled = false;
  }
});

btnDismissApprove.addEventListener('click', () => hideApproveBar());

btnTasks.addEventListener('click', async () => {
  tasksPanel.classList.toggle('hidden');
  if (!tasksPanel.classList.contains('hidden')) {
    await loadTasks();
  }
});

btnCloseTasks.addEventListener('click', () => tasksPanel.classList.add('hidden'));

loadStatus();
loadSessions();
