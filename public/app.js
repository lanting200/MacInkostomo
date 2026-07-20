// ====== State ======
let currentBook = null;
let currentChapter = null;
let currentChapterNum = null;
let currentChapterBookId = null;
let booksCache = [];
let booksLoadedSuccessfully = false;
let currentVolumes = [];
let generationEventSource = null;
let generationStreamKey = '';
let liveGenerationJob = null;
let booksRequestSequence = 0;
let chaptersRequestSequence = 0;
let chapterRequestSequence = 0;
let modalRequestSequence = 0;
let importRequestSequence = 0;
let headerUserRequestSequence = 0;
let fanqieAccountRequestSequence = 0;
let modalPreviousFocus = null;
let importModalPreviousFocus = null;
let loadingPreviousFocus = null;
let activeGenerationResumePromise = null;

const GENERATION_LIVE_TEXT_MAX_CHARS = 16 * 1024;

const CREATE_BOOK_DRAFT_KEY = 'chapterPublisher.createBookDraft.v1';
const CREATE_BOOK_ACTIVE_JOB_KEY = 'chapterPublisher.activeCreateJob.v1';
const ACTIVE_GENERATION_JOB_KEY = 'chapterPublisher.activeGenerationJob.v1';
let createBookAssistPromise = null;
let createBookAssistAbort = null;
let createBookAssistLastPayload = null;
let settingsInitPromise = null;
let activeSettingsPane = 'book';
let settingsBookId = '';
let settingsBookFiles = [];
let settingsBookGroups = [];
let settingsSelectedFilePath = '';
let settingsSelectedFileContent = '';
let settingsFileLoadSequence = 0;
let settingsLongFormPlan = null;
let settingsLongFormChapters = [];
let settingsLongFormInputSnapshot = '';
let settingsLongFormLoadError = '';
let settingsWorkspaceRequestSequence = 0;
const settingsModelCatalogs = {
  chapter: { models: [], tests: new Map(), loading: false, batchTesting: false, batchProgress: null, message: '', selected: '', endpointVersion: 0, catalogRequestId: 0, testRequestId: 0 },
  review: { models: [], tests: new Map(), loading: false, batchTesting: false, batchProgress: null, message: '', selected: '', endpointVersion: 0, catalogRequestId: 0, testRequestId: 0 },
};
let settingsCredentialState = {
  reviewUsesChapterKey: true,
};
let debugEventsCache = [];
let debugJobsSnapshot = { generationJobs: [], creationJobs: [], debug: null };
let debugFilesSnapshot = [];
let debugCursorSnapshot = null;
let debugLoaded = false;
let debugRequestSequence = 0;
let debugEventSource = null;
let debugStreamReconnectTimer = null;
let debugJobsRefreshTimer = null;

// ====== API ======
const API = '/api';

async function api(path, opts = {}) {
  const res = await fetch(API + path, {
    headers: { 'Content-Type': 'application/json' },
    ...opts,
  });
  const raw = await res.text();
  let data = {};
  if (raw) {
    try {
      data = JSON.parse(raw);
    } catch {
      data = { error: raw };
    }
  }
  if (!res.ok) {
    const error = new Error(data.error || `HTTP ${res.status}`);
    error.httpStatus = res.status;
    error.data = data;
    if (data && typeof data === 'object') {
      Object.entries(data).forEach(([key, value]) => {
        if (key !== 'error' && !(key in error)) error[key] = value;
      });
    }
    throw error;
  }
  return data;
}

function readLocalJson(key, fallback = null) {
  try {
    const raw = localStorage.getItem(key);
    return raw ? JSON.parse(raw) : fallback;
  } catch {
    return fallback;
  }
}

function writeLocalJson(key, value) {
  try {
    localStorage.setItem(key, JSON.stringify(value));
    return true;
  } catch (err) {
    console.warn(`[storage] ${key} 保存失败:`, err.message);
    return false;
  }
}

function removeLocalValue(key) {
  try {
    localStorage.removeItem(key);
  } catch (err) {
    console.warn(`[storage] ${key} 清理失败:`, err.message);
  }
}

function llmReviewLabel(review) {
  if (!review) return '';
  const map = {
    inkos_writing: '生成中',
    inkos_revising: '修改中',
    inkos_failed: '待修改',
    reviewing: '审核中',
    fixing: '修改中',
    passed: '初审通过',
    failed: '初审未过',
    error: '审核异常',
  };
  return map[review.status] || review.status || '';
}

function reviewStatusClass(review) {
  if (!review) return 'neutral';
  if (review.status === 'passed') return 'success';
  if (isLlmReviewBusy(review)) return 'processing';
  if (review.status === 'failed') return 'warning';
  return 'danger';
}

function reviewStatusHint(review) {
  if (!review) return '';
  const map = {
    inkos_writing: 'InkOS 正在生成并完成基础校验，请稍候。',
    inkos_revising: 'InkOS 正在根据修改意见处理正文，请稍候。',
    inkos_failed: '章节未通过基础校验，请按问题修改后再提交。',
    reviewing: '章节正在进行初审，请稍候。',
    fixing: '初审未过，已进入修改流程。',
    passed: '章节符合设定与阶段目标，可提交人工终审。',
    failed: '章节存在需要处理的问题，请查看下方说明。',
    error: '审核流程异常，请查看下方说明。',
  };
  return map[review.status] || '';
}

function isLlmReviewBusy(review) {
  return ['inkos_writing', 'inkos_revising', 'reviewing', 'fixing'].includes(review?.status);
}

function isLlmReviewTerminal(review) {
  return ['passed', 'failed', 'error', 'inkos_failed'].includes(review?.status);
}

function reviewIssueLevel(issue) {
  const match = String(issue || '').match(/^\s*\[(critical|warning|info|error)\]/i);
  const level = match?.[1]?.toLowerCase() || 'critical';
  if (level === 'warning') return 'suggestion';
  if (level === 'info') return 'optional';
  return 'required';
}

function cleanReviewIssue(issue) {
  return String(issue || '')
    .replace(/\r\n?/g, '\n')
    .split('\n')
    .map(line => line
      .replace(/^\s*\[(critical|warning|info|error)\]\s*/i, '')
      .replace(/\s+/g, ' ')
      .trim())
    .filter(Boolean)
    .join('\n');
}

function customerFacingReviewAction(issue) {
  const text = cleanReviewIssue(issue);
  if (!text) return '';

  if (/木心/.test(text) && /阴煞|养阳|净煞/.test(text)) {
    return '补足雷阳木心的代价与限制：明确木心已沾染阴煞，须由玄微封存并养阳、净煞后才能使用；改掉会让读者误以为木心可直接制符或无代价使用的表述。';
  }
  if (/正文出现.*高频反应表达/.test(text)) {
    return '替换重复出现的高频反应表达，改用贴合人物状态和场景动作的具体描写。';
  }
  const hooks = [...new Set(text.match(/hook-\d+/gi) || [])];
  if (/确定性关键词检查没有找到.*落点/.test(text) && hooks.length) {
    return `补写 ${hooks.join('、')} 的明确推进或回收，必须在正文中出现实际事件或结果，不能只在大纲中标记。`;
  }
  if (/当前有\s*\d+\s*个活跃伏笔/.test(text)) {
    return '本章不要继续新增伏笔，优先推进或收束已有线索，避免待回收伏笔继续积压。';
  }
  if (/这些伏笔.*没有真正处理/.test(text) && hooks.length) {
    return `在正文中实际推进或回收 ${hooks.join('、')}，给出具体事件、信息或人物选择的落点。`;
  }
  if (/连续出现\s*\d+\s*个不足\s*\d+\s*字的短段/.test(text)) {
    return '合并或扩写连续短段，避免短句堆砌，同时保留场景节奏。';
  }
  return text;
}

function reviewGuidanceDuplicatesIssues(guidance, issues) {
  const normalizedGuidance = cleanReviewIssue(guidance).toLowerCase();
  const normalizedIssues = issues.map(cleanReviewIssue).filter(Boolean);
  if (!normalizedGuidance || !normalizedIssues.length) return false;
  return normalizedIssues.every(issue => normalizedGuidance.includes(issue.toLowerCase().slice(0, 80)));
}

function buildReviewRevisionFeedback(review) {
  const issues = Array.isArray(review?.issues) ? review.issues.filter(Boolean) : [];
  const guidance = cleanReviewIssue(review?.revisionGuidance);
  const useGuidance = guidance
    && !reviewGuidanceDuplicatesIssues(guidance, issues)
    && !/^请修复以下问题[：:]*$/u.test(guidance);
  const source = useGuidance
    ? [{ text: guidance, level: 'required' }]
    : issues.map(issue => ({ text: customerFacingReviewAction(issue), level: reviewIssueLevel(issue) }));
  const seen = new Set();
  const required = [];
  const suggestions = [];
  let optionalCount = 0;

  for (const item of source) {
    const text = String(item.text || '').trim();
    const key = text.replace(/\s+/g, ' ').toLowerCase();
    if (!text || seen.has(key)) continue;
    seen.add(key);
    if (item.level === 'optional') {
      optionalCount += 1;
    } else if (item.level === 'suggestion') {
      suggestions.push(text);
    } else {
      required.push(text);
    }
  }

  return { required, suggestions, optionalCount };
}

function isActionableReviewFailure(review) {
  return ['failed', 'inkos_failed'].includes(review?.status);
}

function reviewDisplaySummary(review, feedback) {
  if (review?.status === 'error') {
    return '审核流程未完成，暂未生成可提交的修改建议。';
  }
  if (review?.status === 'inkos_failed' || /^InkOS 未完成本次修订：/.test(String(review?.summary || ''))) {
    const parts = [];
    if (feedback.required.length) parts.push(`${feedback.required.length} 项必须修改`);
    if (feedback.suggestions.length) parts.push(`${feedback.suggestions.length} 项建议优化`);
    return parts.length ? `本章有${parts.join('，')}，处理后可直接提交修改。` : '本章未通过审核，请根据修改建议处理后再提交。';
  }
  return review?.summary || reviewStatusHint(review) || (isLlmReviewBusy(review) ? '请稍候，系统流程尚未结束。' : '');
}

function buildCopyableRevisionGuidance(chapter, review) {
  const feedback = buildReviewRevisionFeedback(review);
  if (!feedback.required.length && !feedback.suggestions.length) return '';

  const title = chapter?.title ? `《${chapter.title}》` : '本章';
  const lines = [
    `请修改第${chapter?.number || ''}章${title}。`,
    '只修改本章正文，保持已成立的剧情、人物关系、设定和前后章衔接；完成后输出完整正文，不要输出修改说明。',
  ];
  if (feedback.required.length) {
    lines.push('', '必须处理：', ...feedback.required.map((text, index) => `${index + 1}. ${text}`));
  }
  if (feedback.suggestions.length) {
    lines.push('', '建议优化：', ...feedback.suggestions.map((text, index) => `${index + 1}. ${text}`));
  }
  return lines.join('\n');
}

function reviewRevisionGuideCard(chapter, review) {
  if (!isActionableReviewFailure(review)) return '';
  const feedback = buildReviewRevisionFeedback(review);
  if (!feedback.required.length && !feedback.suggestions.length) return '';
  const required = feedback.required.length
    ? `<div class="review-revision-section-title">必须修改</div><ol class="review-revision-list required">${feedback.required.map(text => `<li>${escapeHtml(text)}</li>`).join('')}</ol>`
    : '';
  const suggestions = feedback.suggestions.length
    ? `<div class="review-revision-section-title">建议优化</div><ol class="review-revision-list">${feedback.suggestions.map(text => `<li>${escapeHtml(text)}</li>`).join('')}</ol>`
    : '';
  const optional = feedback.optionalCount ? `<div class="review-revision-optional">另有 ${feedback.optionalCount} 项可选润色未列入提交建议。</div>` : '';
  return `<section class="review-revision-guide">
    <div class="review-revision-guide-head">
      <strong>可提交的修改建议</strong>
      <div class="review-revision-guide-actions">
        <button class="btn btn-outline btn-sm" type="button" onclick="copyReviewRevisionGuidance()">复制建议</button>
        <button class="btn btn-warning btn-sm" type="button" onclick="fillReviewRevisionGuidance()">填入修改框</button>
      </div>
    </div>
    ${required}
    ${suggestions}
    ${optional}
  </section>`;
}

function isInkosReviewableStatus(status) {
  return ['ready-for-review', 'audit-passed', 'drafted'].includes(status);
}

function isInkosFailedStatus(status) {
  return ['audit-failed', 'state-degraded', 'rejected'].includes(status);
}

function isInkosBusyStatus(status) {
  return ['card-generated', 'drafting', 'auditing', 'revising'].includes(status);
}

function chapterStatusUi(status) {
  const map = {
    'card-generated': { dot: 'revision', tag: 'revision', text: '建卡中' },
    'drafting': { dot: 'revision', tag: 'revision', text: '写作中' },
    'drafted': { dot: 'pending', tag: 'pending', text: '待审' },
    'auditing': { dot: 'revision', tag: 'revision', text: 'InkOS自审中' },
    'audit-passed': { dot: 'pending', tag: 'pending', text: '待审' },
    'ready-for-review': { dot: 'pending', tag: 'pending', text: '待审' },
    'audit-failed': { dot: 'failed', tag: 'failed', text: 'LLM审核未过' },
    'state-degraded': { dot: 'failed', tag: 'failed', text: '状态待修' },
    'revising': { dot: 'revision', tag: 'revision', text: '修改中' },
    'approved': { dot: 'approved', tag: 'approved', text: '已通过' },
    'rejected': { dot: 'rejected', tag: 'rejected', text: '待修改' },
    'published': { dot: 'published', tag: 'published', text: '已发布' },
    'imported': { dot: 'pending', tag: 'pending', text: '已导入' },
    // Legacy publisher-only statuses. Kept only for old fallback data when
    // InkOS index.json is absent.
    'pending_review': { dot: 'pending', tag: 'pending', text: '待审' },
    'revision_requested': { dot: 'revision', tag: 'revision', text: '修改中' },
    'revision_failed': { dot: 'failed', tag: 'failed', text: '修改失败' },
  };
  return map[status] || map['ready-for-review'];
}

function resetCurrentChapterSelection({ hasBook = Boolean(currentBook), message = '从左侧选择章节开始审批' } = {}) {
  chapterRequestSequence += 1;
  currentChapter = null;
  currentChapterNum = null;
  currentChapterBookId = null;
  document.querySelectorAll('.chapter-list-item.active').forEach(item => {
    item.classList.remove('active');
    item.removeAttribute('aria-current');
  });
  document.getElementById('chapterTitle').innerHTML = hasBook
    ? '请选择章节<span class="meta"></span>'
    : '欢迎使用 InkOS 小说工作台<span class="meta"></span>';
  const reviewWrap = document.getElementById('reviewStatusWrap');
  reviewWrap.style.display = 'none';
  reviewWrap.innerHTML = '';
  document.getElementById('mainContent').innerHTML = `<div class="main-body-empty"><h3>${escapeHtml(message)}</h3></div>`;
  const actionBar = document.getElementById('actionBar');
  actionBar.style.display = hasBook ? 'block' : 'none';
  document.getElementById('approveBtn').style.display = 'none';
  document.getElementById('rejectBtn').style.display = 'none';
  document.getElementById('copyFanqieBtn').style.display = 'none';
  document.getElementById('historyBtn').style.display = 'none';
  document.getElementById('generateBtn').style.display = hasBook ? '' : 'none';
  document.getElementById('revisionForm').classList.remove('active');
  document.getElementById('revisionHistory').classList.remove('active');
}

// ====== Init ======
async function init() {
  document.getElementById('createBookBtn').onclick = openCreateBookModal;
  document.getElementById('deleteBookBtn').onclick = deleteCurrentBook;
  document.getElementById('importBtn').onclick = openImportModal;
  // 头部导航 tab 切换
  document.querySelectorAll('.header-nav-item').forEach(btn => {
    btn.onclick = () => switchTab(btn.dataset.tab);
  });
  // 头部用户区域点击跳转设置
  document.getElementById('headerUser').onclick = () => switchTab('settings');
  await loadBooks();
  const generationResumed = await resumeActiveGenerationJob();
  if (!generationResumed && !readActiveGenerationJob()) resumeActiveBookCreationJob();
  // 后台静默拉取番茄数据
  fqBackgroundPrefetch();
  // 尝试加载番茄账号信息显示在 header
  loadHeaderUser();
}

async function loadHeaderUser() {
  const requestSequence = ++headerUserRequestSequence;
  try {
    const info = await api('/fanqie/account');
    if (requestSequence !== headerUserRequestSequence) return;
    if (info.loggedIn) {
      document.getElementById('headerUserName').textContent = info.authorName || '已登录';
      document.getElementById('headerAvatar').textContent = (info.authorName || '?')[0];
    } else {
      document.getElementById('headerUserName').textContent = '未登录';
      document.getElementById('headerAvatar').textContent = '?';
    }
  } catch {}
}

function switchTab(which) {
  const localApp = document.getElementById('localApp');
  const views = ['fanqieView', 'settingsView'];
  // Header nav active
  document.querySelectorAll('.header-nav-item').forEach(b => {
    b.classList.toggle('active', b.dataset.tab === which);
  });
  if (which === 'local') {
    localApp.classList.remove('hidden');
  } else {
    localApp.classList.add('hidden');
  }
  views.forEach(v => document.getElementById(v).classList.add('hidden'));
  if (which === 'fanqie') {
    document.getElementById('fanqieView').classList.remove('hidden');
    fqInit();
  } else if (which === 'settings') {
    document.getElementById('settingsView').classList.remove('hidden');
    settingsInit();
  }
}

// ====== Books ======
async function loadBooks() {
  const requestSequence = ++booksRequestSequence;
  try {
    const books = await api('/books');
    if (requestSequence !== booksRequestSequence) return;
    booksLoadedSuccessfully = true;
    booksCache = books;
    const selector = document.getElementById('bookSelector');
    const previous = currentBook || selector.value;
    selector.innerHTML = '<option value="">选择书籍...</option>';
    books.forEach(b => {
      const opt = document.createElement('option');
      opt.value = b.id;
      opt.textContent = `${b.title} (${b.chapterCount}章)`;
      selector.appendChild(opt);
    });
    if (books.length > 0) {
      const selected = books.find(b => b.id === previous)?.id || books[0].id;
      selector.value = selected;
      if (currentChapterBookId !== selected) {
        resetCurrentChapterSelection({ hasBook: true });
      }
      currentBook = selected;
      await loadChapters(selected);
      if (requestSequence !== booksRequestSequence) return;
    } else {
      currentBook = null;
      currentChapter = null;
      currentChapterNum = null;
      currentChapterBookId = null;
      document.getElementById('chapterList').innerHTML = '<div class="main-body-empty" style="height:200px;"><p style="font-size:12px;">暂无小说，请新建或导入书籍</p></div>';
      document.getElementById('sidebarStats').innerHTML = '';
      document.getElementById('chapterTitle').innerHTML = '欢迎使用 InkOS 小说工作台<span class="meta"></span>';
      document.getElementById('reviewStatusWrap').style.display = 'none';
      document.getElementById('reviewStatusWrap').innerHTML = '';
      document.getElementById('mainContent').innerHTML = `<div class="main-body-empty">
        <h3>暂无小说</h3><p>点击右上角“新建小说”，按 InkOS 需要的信息创建设定、大纲、分卷和字数节奏。</p>
      </div>`;
      document.getElementById('actionBar').style.display = 'none';
    }
    document.getElementById('deleteBookBtn').disabled = !currentBook;
    selector.onchange = async (e) => {
      const bookId = e.target.value;
      currentBook = bookId || null;
      resetCurrentChapterSelection({ hasBook: Boolean(bookId) });
      document.getElementById('deleteBookBtn').disabled = !currentBook;
      if (bookId) {
        await loadChapters(bookId);
      } else {
        document.getElementById('chapterList').innerHTML = '<div class="main-body-empty" style="height:200px;"><p style="font-size:12px;">请选择小说</p></div>';
        document.getElementById('sidebarStats').innerHTML = '';
      }
    };
    if (requestSequence !== booksRequestSequence) return;
  } catch (err) {
    if (requestSequence !== booksRequestSequence) return;
    booksLoadedSuccessfully = false;
    console.error('Failed to load books:', err);
    document.getElementById('mainContent').innerHTML = `<div class="main-body-empty">
      <h3>本地服务连接失败</h3>
      <p>${escapeHtml(err.message)}</p>
      <button class="btn btn-outline" type="button" onclick="retryLoadBooks()">重新连接</button>
    </div>`;
  }
}

async function retryLoadBooks() {
  await loadBooks();
  const generationResumed = await resumeActiveGenerationJob();
  if (!generationResumed && !readActiveGenerationJob()) resumeActiveBookCreationJob();
}

// ====== Chapters ======
async function loadChapters(bookId) {
  const requestSequence = ++chaptersRequestSequence;
  try {
    const data = await api(`/books/${encodeURIComponent(bookId)}/chapters`);
    if (requestSequence !== chaptersRequestSequence || currentBook !== bookId) return null;
    currentBook = bookId;
    currentVolumes = data.volumes || [];

    // Update sidebar stats with volume info
    const stats = document.getElementById('sidebarStats');
    const pending = data.chapters.filter(c => isInkosReviewableStatus(c.status) || c.status === 'pending_review').length;
    const approved = data.chapters.filter(c => c.status === 'approved').length;
    const published = data.chapters.filter(c => c.status === 'published').length;
    const revision = data.chapters.filter(c => isInkosBusyStatus(c.status) || c.status === 'revision_requested').length;
    const rejected = data.chapters.filter(c => isInkosFailedStatus(c.status) || ['rejected', 'revision_failed'].includes(c.status)).length;

    // 分卷进度
    let volumeBar = '';
    if (data.volumes && data.currentVolume) {
      const cv = data.currentVolume;
      const total = data.chapters.length;
      volumeBar = `<div style="margin-top:6px;font-size:11px;color:#8b949e;border-top:1px solid #30363d;padding-top:6px;">
        卷${escapeHtml(cv.num)}：${escapeHtml(cv.title)}·${escapeHtml(cv.subtitle)} | 共${escapeHtml(total)}章
      </div>`;
      // 分卷分隔标记
      data.volumes.forEach(v => {
        const inVol = data.chapters.filter(c => c.number >= v.start && c.number <= v.end).length;
        if (inVol > 0) {
          volumeBar += `<div style="font-size:10px;color:#58a6ff;margin-top:2px;"><svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="vertical-align:middle;"><path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20"/><path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z"/></svg> ${escapeHtml(v.title)}·${escapeHtml(v.subtitle)} (${escapeHtml(v.start)}-${escapeHtml(v.end)}): ${escapeHtml(inVol)}章</div>`;
        }
      });
    }

    stats.innerHTML = `
      <div class="stat"><div class="status-dot pending"></div>待审 ${escapeHtml(pending)}</div>
      <div class="stat"><div class="status-dot approved"></div>已通过 ${escapeHtml(approved)}</div>
      <div class="stat"><div class="status-dot rejected"></div>待修改 ${escapeHtml(rejected)}</div>
      <div class="stat"><div class="status-dot revision"></div>修改中 ${escapeHtml(revision)}</div>
      <div class="stat"><div class="status-dot published"></div>已发布 ${escapeHtml(published)}</div>
      ${volumeBar}
    `;

    // Render chapter list with volume dividers
    const list = document.getElementById('chapterList');
    if (data.chapters.length === 0) {
      currentChapter = null;
      currentChapterNum = null;
      currentChapterBookId = null;
      list.innerHTML = '<div class="empty-state" style="height: 200px;"><p style="font-size: 13px;">暂无章节</p></div>';
      document.getElementById('chapterTitle').innerHTML = '新书已创建<span class="meta">0章</span>';
      document.getElementById('reviewStatusWrap').style.display = 'none';
      document.getElementById('reviewStatusWrap').innerHTML = '';
      document.getElementById('mainContent').innerHTML = `<div class="main-body-empty">
        <h3>还没有章节</h3>
        <p>点击下方“生成新章节”开始创作第1章。</p>
      </div>`;
      const actionBar = document.getElementById('actionBar');
      actionBar.style.display = 'block';
      document.getElementById('approveBtn').style.display = 'none';
      document.getElementById('rejectBtn').style.display = 'none';
      document.getElementById('copyFanqieBtn').style.display = 'none';
      document.getElementById('historyBtn').style.display = 'none';
      document.getElementById('generateBtn').style.display = '';
      document.getElementById('revisionForm').classList.remove('active');
      document.getElementById('revisionHistory').classList.remove('active');
      return;
    }

    const selectedChapterStillExists = currentChapterBookId === bookId
      && data.chapters.some(chapter => chapter.number === currentChapterNum);
    if (!selectedChapterStillExists) {
      resetCurrentChapterSelection({ hasBook: true });
    }

    list.innerHTML = '';
    let lastVolume = null;
    data.chapters.forEach(ch => {
      // 分卷分隔线：章节进入新卷时插入标记
      if (ch.volume && ch.volume !== lastVolume) {
        lastVolume = ch.volume;
        const volInfo = data.volumes?.find(v => v.num === ch.volume);
        const divider = document.createElement('div');
        divider.className = 'volume-divider';
        divider.textContent = `卷${ch.volume}：${volInfo?.title || ch.volumeTitle || ''}·${volInfo?.subtitle || ''}`;
        list.appendChild(divider);
      }

      const item = document.createElement('button');
      item.type = 'button';
      item.className = 'chapter-list-item';
      if (currentChapterBookId === bookId && ch.number === currentChapterNum) {
        item.classList.add('active');
        item.setAttribute('aria-current', 'true');
      }
      item.setAttribute('aria-label', `第${ch.number}章 ${ch.title}，${chapterStatusUi(ch.status).text}`);

      const st = chapterStatusUi(ch.status);

      item.innerHTML = `
        <span class="status-dot ${st.dot}"></span>
        <span class="info">
          <span class="title">第${escapeHtml(ch.number)}章 ${escapeHtml(ch.title)}</span>
          <span class="meta">${escapeHtml(ch.wordCount)}字${ch.revisionCount > 0 ? ' · 改' + escapeHtml(ch.revisionCount) : ''}${ch.llmReview ? ' · ' + escapeHtml(llmReviewLabel(ch.llmReview)) : ''}</span>
        </span>
        <span class="status-tag ${st.tag}">${escapeHtml(st.text)}</span>
      `;
      item.onclick = () => loadChapter(bookId, ch.number);
      list.appendChild(item);
    });
    return data;
  } catch (err) {
    if (requestSequence !== chaptersRequestSequence || currentBook !== bookId) return null;
    console.error('Failed to load chapters:', err);
    document.getElementById('chapterList').innerHTML = `<div class="main-body-empty" style="height:200px;"><p style="font-size:12px;">章节加载失败：${escapeHtml(err.message)}</p></div>`;
    return null;
  }
}

// ====== Chapter Detail ======
async function loadChapter(bookId, num) {
  const requestSequence = ++chapterRequestSequence;
  try {
    const ch = await api(`/books/${encodeURIComponent(bookId)}/chapters/${num}`);
    if (requestSequence !== chapterRequestSequence || currentBook !== bookId) return;
    currentChapterNum = num;
    currentChapter = ch;
    currentChapterBookId = bookId;

    // Update header
    document.getElementById('chapterTitle').innerHTML = `第${escapeHtml(ch.number)}章 ${escapeHtml(ch.title)}<span class="meta">${escapeHtml(ch.wordCount)}字</span>`;

    // Update content - use card style
    const content = document.getElementById('mainContent');
    const reviewWrap = document.getElementById('reviewStatusWrap');
    const review = ch.llmReview || null;
    const reviewClass = reviewStatusClass(review);
    const feedback = buildReviewRevisionFeedback(review);
    const reviewCard = review ? `<div class="review-status-card ${reviewClass}">
      <div class="review-status-head">
        <div class="review-status-title">审核状态</div>
        <span class="review-status-badge">${escapeHtml(llmReviewLabel(review))}</span>
      </div>
      <div class="review-status-summary">${escapeHtml(reviewDisplaySummary(review, feedback))}</div>
      ${review.autoFixed ? '<div class="review-status-note">已根据初审意见自动处理过一次</div>' : ''}
      ${reviewRevisionGuideCard(ch, review)}
    </div>` : '';
    reviewWrap.innerHTML = reviewCard;
    reviewWrap.style.display = review ? 'block' : 'none';
    content.innerHTML = `<div class="content-card"><div class="chapter-text">${escapeHtml(ch.content)}</div></div>`;
    content.scrollTop = 0;

    // Update action bar
    const actionBar = document.getElementById('actionBar');
    actionBar.style.display = 'block';

    // Show/hide buttons based on status
    const approveBtn = document.getElementById('approveBtn');
    const rejectBtn = document.getElementById('rejectBtn');
    const copyFanqieBtn = document.getElementById('copyFanqieBtn');
    const historyBtn = document.getElementById('historyBtn');

    // 通过/不通过 对 待审/修改失败/历史待修改 均可用。提交不通过后会直接调用 InkOS revise，
    // 修改完成回到 pending_review 再二审。
    const reviewBusy = isLlmReviewBusy(review);
    const canApprove = isInkosReviewableStatus(ch.status) && review?.status === 'passed';
    const canReject = !reviewBusy && (isInkosReviewableStatus(ch.status) || isInkosFailedStatus(ch.status) || ['pending_review', 'revision_failed', 'rejected'].includes(ch.status));
    const canCopyFanqie = ['approved', 'published'].includes(ch.status);
    approveBtn.style.display = canApprove ? '' : 'none';
    rejectBtn.style.display = canReject ? '' : 'none';
    copyFanqieBtn.style.display = canCopyFanqie ? '' : 'none';
    historyBtn.style.display = (ch.revisionHistory && ch.revisionHistory.length > 0) ? '' : 'none';
    document.getElementById('generateBtn').style.display = '';

    // Hide revision form
    document.getElementById('revisionForm').classList.remove('active');
    document.getElementById('revisionHistory').classList.remove('active');

    // Reload chapter list to update active state
    if (requestSequence === chapterRequestSequence && currentBook === bookId) {
      await loadChapters(bookId);
    }
  } catch (err) {
    if (requestSequence !== chapterRequestSequence || currentBook !== bookId) return;
    console.error('Failed to load chapter:', err);
    alert('加载章节失败: ' + err.message);
  }
}

// ====== Approve ======
async function approveChapter() {
  if (!currentBook || !currentChapterNum || currentChapterBookId !== currentBook) return;
  const bookId = currentBook;
  const chapterNum = currentChapterNum;
  const button = document.getElementById('approveBtn');
  button.disabled = true;
  try {
    await api(`/books/${encodeURIComponent(bookId)}/chapters/${chapterNum}`, {
      method: 'PATCH',
      body: JSON.stringify({ status: 'approved' }),
    });
    if (currentBook === bookId) await loadChapter(bookId, chapterNum);
  } catch (err) {
    alert('操作失败: ' + err.message);
  } finally {
    button.disabled = false;
  }
}

function formatChapterForFanqie(chapter) {
  const title = `第${chapter.number}章 ${chapter.title || ''}`.trim();
  const body = String(chapter.content || '')
    .replace(/\r\n/g, '\n')
    .replace(/\r/g, '\n')
    .replace(/^\s*#\s*第.*?章.*\n+/, '')
    .split(/\n+/)
    .map(line => line.trim())
    .filter(Boolean)
    .join('\n\n');
  return `${title}\n\n${body}`.trim() + '\n';
}

async function copyTextToClipboard(text) {
  if (navigator.clipboard && window.isSecureContext) {
    try {
      await navigator.clipboard.writeText(text);
      return;
    } catch {
      // WKWebView may expose Clipboard API while denying a specific write.
    }
  }
  const ta = document.createElement('textarea');
  ta.value = text;
  ta.style.position = 'fixed';
  ta.style.left = '-9999px';
  ta.style.top = '0';
  document.body.appendChild(ta);
  ta.focus();
  ta.select();
  const ok = document.execCommand('copy');
  document.body.removeChild(ta);
  if (!ok) throw new Error('execCommand copy failed');
}

async function copyApprovedChapterForFanqie() {
  if (!currentChapter) return;
  if (!['approved', 'published'].includes(currentChapter.status)) {
    alert('只有人工通过后的章节才能复制给番茄上传。');
    return;
  }
  const text = formatChapterForFanqie(currentChapter);
  try {
    await copyTextToClipboard(text);
    alert(`已复制第${currentChapter.number}章番茄格式：标题 + 正文，段落以空行分隔。`);
  } catch {
    openModal('复制番茄格式', `<textarea class="form-textarea" style="min-height:420px;">${escapeHtml(text)}</textarea><p style="font-size:12px;color:#8b949e;margin-top:8px;">自动复制失败，请手动全选复制。</p>`, false);
  }
}

async function copyReviewRevisionGuidance() {
  const text = buildCopyableRevisionGuidance(currentChapter, currentChapter?.llmReview);
  if (!text) {
    alert('当前审核没有可复制的修改建议。');
    return;
  }
  try {
    await copyTextToClipboard(text);
    alert('修改建议已复制，可直接粘贴到“提交修改”。');
  } catch {
    openModal('复制修改建议', `<textarea class="form-textarea" style="min-height:320px;">${escapeHtml(text)}</textarea>`, false);
  }
}

function fillReviewRevisionGuidance() {
  const text = buildCopyableRevisionGuidance(currentChapter, currentChapter?.llmReview);
  if (!text) {
    alert('当前审核没有可提交的修改建议。');
    return;
  }
  const form = document.getElementById('revisionForm');
  const input = document.getElementById('revisionNote');
  form.classList.add('active');
  input.value = text;
  document.getElementById('actionBar').scrollIntoView({ behavior: 'smooth', block: 'end' });
  requestAnimationFrame(() => {
    input.focus();
    input.setSelectionRange(input.value.length, input.value.length);
  });
}

// ====== Revision Form (不通过 + 反馈) ======
function toggleRevisionForm() {
  const form = document.getElementById('revisionForm');
  form.classList.toggle('active');
  if (form.classList.contains('active')) {
    document.getElementById('revisionNote').focus();
  }
}

function readActiveGenerationJob() {
  const active = readLocalJson(ACTIVE_GENERATION_JOB_KEY, null);
  if (!active?.bookId || !Number.isInteger(Number(active.chapterNum))) return null;
  return { ...active, chapterNum: Number(active.chapterNum) };
}

function persistActiveGenerationJob({ bookId, chapterNum, mode, startedAt }) {
  writeLocalJson(ACTIVE_GENERATION_JOB_KEY, {
    bookId,
    chapterNum: Number(chapterNum),
    mode: mode === 'revision' ? 'revision' : 'generate',
    startedAt: startedAt || new Date().toISOString(),
  });
}

function clearActiveGenerationJob(bookId, chapterNum) {
  const active = readActiveGenerationJob();
  if (!active) return;
  if (bookId && active.bookId !== bookId) return;
  if (chapterNum && active.chapterNum !== Number(chapterNum)) return;
  removeLocalValue(ACTIVE_GENERATION_JOB_KEY);
}

async function resumeActiveGenerationJob() {
  const active = readActiveGenerationJob();
  if (!active || activeGenerationResumePromise) return Boolean(activeGenerationResumePromise);
  if (!booksLoadedSuccessfully) return false;
  if (!booksCache.some(book => book.id === active.bookId)) {
    removeLocalValue(ACTIVE_GENERATION_JOB_KEY);
    return false;
  }

  if (currentBook !== active.bookId) {
    currentBook = active.bookId;
    document.getElementById('bookSelector').value = active.bookId;
    resetCurrentChapterSelection({ hasBook: true, message: '正在恢复上次任务...' });
    await loadChapters(active.bookId);
  }

  const initialJob = {
    bookId: active.bookId,
    chapterNum: active.chapterNum,
    phase: active.mode === 'revision' ? 'inkos_revising' : 'inkos_writing',
    startedAt: active.startedAt,
    message: active.mode === 'revision' ? '正在恢复章节修改任务' : '正在恢复章节生成任务',
    progress: [],
  };
  liveGenerationJob = initialJob;
  startGenerationEventStream(active.bookId, active.chapterNum);
  showGenerationProgress(initialJob, active.chapterNum);
  const waiter = active.mode === 'revision'
    ? waitForRevision(active.bookId, active.chapterNum)
    : waitForNewChapter(active.bookId, active.chapterNum);
  activeGenerationResumePromise = waiter.catch(err => {
    closeGenerationEventStream(active.bookId, active.chapterNum);
    hideLoading();
    console.warn('[generation] 恢复监听失败:', err);
    alert(`恢复任务监听时出现错误：${err.message}。刷新页面后会继续读取任务状态。`);
  }).finally(() => {
    activeGenerationResumePromise = null;
    if (!readActiveGenerationJob()) resumeActiveBookCreationJob();
  });
  return true;
}

// 不通过：提交修改意见给后端 /revise，由 InkOS 修改章节文件，完成后回 pending_review。
async function submitReject() {
  if (!currentBook || !currentChapterNum || currentChapterBookId !== currentBook) return;
  const note = document.getElementById('revisionNote').value.trim();
  if (!note) { alert('请写修改意见'); return; }
  const bookId = currentBook;
  const chapterNum = currentChapterNum;
  const submitButton = document.getElementById('revisionSubmitBtn');
  if (submitButton?.disabled) return;
  if (submitButton) submitButton.disabled = true;

  try {
    const queuedAt = new Date().toISOString();
    const initialJob = {
      bookId,
      chapterNum,
      phase: 'inkos_revising',
      currentStage: 'revision_queued',
      startedAt: queuedAt,
      message: '正在提交修改请求',
      progress: [{
        stage: 'revision_queued',
        eventKey: 'revision_queued',
        label: '正在提交修改请求',
        detail: '正在检索上下文并启动 InkOS 修订流程',
        at: queuedAt,
      }],
    };
    liveGenerationJob = initialJob;
    persistActiveGenerationJob({ bookId, chapterNum, mode: 'revision', startedAt: queuedAt });
    startGenerationEventStream(bookId, chapterNum);
    showGenerationProgress(initialJob, chapterNum);
    const r = await api(`/books/${encodeURIComponent(bookId)}/chapters/${chapterNum}/revise`, {
      method: 'POST',
      body: JSON.stringify({ revisionNote: note, revisionMode: 'rewrite' }),
    });
    document.getElementById('revisionForm').classList.remove('active');
    document.getElementById('revisionNote').value = '';
    await loadChapter(bookId, chapterNum);
    if (r.status === 'processing') {
      await waitForRevision(bookId, chapterNum);
    } else {
      closeGenerationEventStream(bookId, chapterNum);
      hideLoading();
      clearActiveGenerationJob(bookId, chapterNum);
      await loadChapter(bookId, chapterNum);
    }
  } catch (err) {
    closeGenerationEventStream(bookId, chapterNum);
    hideLoading();
    clearActiveGenerationJob(bookId, chapterNum);
    alert('提交失败: ' + err.message);
  } finally {
    if (submitButton) submitButton.disabled = false;
  }
}

function getVolumeInfo(chapterNum) {
  const vol = currentVolumes.find(v => chapterNum >= v.start && chapterNum <= v.end);
  if (!vol) return { label: '规划外', description: '', num: 0, currentChapter: chapterNum };
  const progress = Math.round((chapterNum - vol.start + 1) / (vol.end - vol.start + 1) * 100);
  return {
    label: `卷${vol.num}：${vol.title}${vol.subtitle ? '·' + vol.subtitle : ''}（${progress}%）`,
    description: `${vol.context || ''} | 第${vol.start}-${vol.end}章`,
    num: vol.num,
    title: vol.title,
    subtitle: vol.subtitle,
    start: vol.start,
    end: vol.end,
    progress,
    currentChapter: chapterNum,
    isTransition: chapterNum === vol.start,
    isEndApproaching: chapterNum >= vol.end - 20,
  };
}

// ====== Generate New Chapter ======
// 调用后端 /api/books/:bookId/generate，后端异步执行 inkos write next
async function openGenerateModal() {
  if (!currentBook) return;
  const bookId = currentBook;
  // 找到当前书的最后一章编号
  let data;
  try {
    data = await api(`/books/${encodeURIComponent(bookId)}/chapters`);
  } catch (err) {
    alert('读取生成信息失败: ' + err.message);
    return;
  }
  if (currentBook !== bookId) {
    alert('当前小说已切换，请在目标小说中重新点击“生成新章节”。');
    return;
  }
  currentVolumes = data.volumes || currentVolumes || [];
  const chapters = data.chapters || [];
  const maxNum = chapters.length > 0 ? Math.max(...chapters.map(c => c.number)) : 0;
  const nextNum = Number(data.nextChapterNum) || maxNum + 1;

  // 判断当前所在分卷
  const volumeInfo = getVolumeInfo(nextNum);

  openModal(`生成新章节（第${nextNum}章）`,
    `<div style="margin-bottom:12px;padding:10px 14px;background:#F5F6F7;border-radius:8px;display:flex;align-items:center;gap:8px;">
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#F44B39" stroke-width="2"><path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20"/><path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z"/></svg>
      <span style="font-size:13px;color:#1A1A1A;font-weight:500;">${escapeHtml(volumeInfo.label)}</span>
      <span style="font-size:12px;color:#999DA5;">${escapeHtml(volumeInfo.description)}</span>
    </div>
     <p style="font-size:12px;color:#FF8F1F;margin-bottom:8px;">生成方向仅作参考，不影响已设定的分卷大纲、人物设定和节奏控制。留空则按当前分卷节奏正常续写。</p>
     <label class="sr-only" for="generateGuidance">生成方向</label>
     <textarea class="form-textarea form-textarea-sm" id="generateGuidance" aria-label="生成方向" placeholder="生成方向（可选）：例如「本章希望推进XXX情节」「需要引入XXX新角色」「侧重幽默对话」等。InkOS 会在不偏离设定和大纲的前提下参考此方向……"></textarea>`,
    true);
  const submitButton = document.getElementById('fqModalSubmit');
  submitButton.textContent = '开始生成';
  submitButton.onclick = async () => {
    if (submitButton.disabled) return;
    submitButton.disabled = true;
    const guidance = document.getElementById('generateGuidance').value.trim();
    closeModal({ restoreFocus: false });
    const queuedAt = new Date().toISOString();
    const initialJob = {
      bookId,
      chapterNum: nextNum,
      phase: 'inkos_writing',
      currentStage: 'queued',
      message: '正在提交生成请求',
      progress: [{
        stage: 'queued',
        eventKey: 'queued',
        label: '正在提交生成请求',
        detail: '正在启动 InkOS 写作流程',
        at: queuedAt,
      }],
      startedAt: queuedAt,
    };
    liveGenerationJob = initialJob;
    persistActiveGenerationJob({ bookId, chapterNum: nextNum, mode: 'generate', startedAt: queuedAt });
    startGenerationEventStream(bookId, nextNum);
    showGenerationProgress(initialJob, nextNum);
    try {
      const r = await api(`/books/${encodeURIComponent(bookId)}/generate`, {
        method: 'POST',
        body: JSON.stringify({ guidance: guidance || undefined }),
      });
      if (r.status === 'processing') {
        await waitForNewChapter(bookId, nextNum);
      } else {
        closeGenerationEventStream(bookId, nextNum);
        hideLoading();
        clearActiveGenerationJob(bookId, nextNum);
        await loadChapters(bookId);
      }
    } catch (err) {
      closeGenerationEventStream(bookId, nextNum);
      hideLoading();
      clearActiveGenerationJob(bookId, nextNum);
      alert('生成失败: ' + err.message);
    } finally {
      submitButton.disabled = false;
    }
  };
}

// 轮询等待新章节写入 state.json（InkOS 异步生成后后端会写入）
function isGenerationJobTerminal(job) {
  return Boolean(job?.finishedAt)
    || ['failed', 'error', 'complete_passed', 'complete_needs_review', 'complete_inkos_failed'].includes(job?.phase);
}

function generationJobLabel(job, fallbackNum) {
  if (!job) return `第${fallbackNum}章生成中...`;
  if (job.message && ['inkos_writing', 'inkos_revising', 'llm_reviewing', 'llm_fixing'].includes(job.phase)) {
    return job.message;
  }
  const map = {
    inkos_writing: 'InkOS 正在生成并自审章节，请勿关闭页面...',
    inkos_revising: 'InkOS 正在修改章节，请勿关闭页面...',
    llm_reviewing: '系统 LLM 初审中...',
    llm_fixing: 'LLM 初审未通过，正在打回 InkOS 修改...',
    complete_passed: '初审通过，正在刷新章节列表...',
    complete_needs_review: '章节需要复核，正在刷新章节列表...',
    complete_inkos_failed: 'InkOS 自审未通过，正在刷新章节列表...',
    failed: 'InkOS 生成失败',
    error: 'InkOS 生成异常',
  };
  return map[job.phase] || job.message || `第${job.chapterNum || fallbackNum}章生成中...`;
}

const GENERATION_PHASE_PROGRESS = {
  inkos_revising: {
    stage: 'revision',
    eventKey: 'revision',
    label: '请求：InkOS 修订章节',
    detail: '正在根据修改意见重写正文并校验连续性',
  },
  llm_reviewing: {
    stage: 'llm_review',
    eventKey: 'llm_review',
    label: '请求：系统 LLM 初审',
    detail: '使用设定模型检查章节是否符合本书规则',
  },
  llm_fixing: {
    stage: 'llm_fix',
    eventKey: 'llm_fix',
    label: '请求：根据初审意见修订',
    detail: 'InkOS 正在根据系统初审意见修改正文',
  },
  complete_passed: {
    stage: 'complete',
    eventKey: 'complete_passed',
    label: '初审通过',
    detail: '章节已进入人工审批队列',
  },
  complete_needs_review: {
    stage: 'complete',
    eventKey: 'complete_needs_review',
    label: '初审需要复核',
    detail: '章节已生成，请查看审核结论',
  },
  complete_inkos_failed: {
    stage: 'inkos_failed',
    eventKey: 'complete_inkos_failed',
    label: 'InkOS 自审未通过',
    detail: '正文已保留，请查看自审问题后再决定如何处理',
  },
  failed: {
    stage: 'failed',
    eventKey: 'failed',
    label: '生成失败',
    detail: 'InkOS 未完成本次章节生成',
  },
  error: {
    stage: 'failed',
    eventKey: 'error',
    label: '生成异常',
    detail: '服务端生成流程异常结束',
  },
};

function generationProgressEvents(job, fallbackNum) {
  const progress = Array.isArray(job?.progress) ? job.progress.map(item => ({ ...item })) : [];
  const phaseEvent = GENERATION_PHASE_PROGRESS[job?.phase];
  if (phaseEvent && !progress.some(item => item.eventKey === phaseEvent.eventKey)) {
    progress.push({ ...phaseEvent, at: job.updatedAt || new Date().toISOString() });
  }
  if (progress.length > 0) return progress;
  return [{
    stage: 'queued',
    eventKey: 'queued',
    label: `第${fallbackNum}章生成请求已提交`,
    detail: '正在等待 InkOS 返回首个阶段状态',
    at: job?.startedAt || new Date().toISOString(),
  }];
}

function formatGenerationTime(value) {
  const time = Date.parse(value || '');
  if (!Number.isFinite(time)) return '';
  return new Date(time).toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' });
}

function generationElapsed(startedAt) {
  const started = Date.parse(startedAt || '');
  if (!Number.isFinite(started)) return '';
  const seconds = Math.max(0, Math.floor((Date.now() - started) / 1000));
  const minutes = Math.floor(seconds / 60);
  return minutes > 0 ? `已进行 ${minutes} 分 ${seconds % 60} 秒` : `已进行 ${seconds} 秒`;
}

function generationStreamId(bookId, chapterNum) {
  return `${bookId}#${chapterNum}`;
}

function closeGenerationEventStream(bookId, chapterNum) {
  const target = bookId && chapterNum ? generationStreamId(bookId, chapterNum) : '';
  if (!generationEventSource || (target && generationStreamKey !== target)) return;
  generationEventSource.close();
  generationEventSource = null;
  generationStreamKey = '';
}

function retainLiveGenerationText(text) {
  return text.length > GENERATION_LIVE_TEXT_MAX_CHARS
    ? text.slice(-GENERATION_LIVE_TEXT_MAX_CHARS)
    : text;
}

function rememberGenerationJob(job, fallbackNum) {
  if (!job) return null;
  const previous = liveGenerationJob;
  const next = { ...job };
  const target = generationStreamId(next.bookId || '', next.chapterNum || fallbackNum);
  const previousTarget = previous
    ? generationStreamId(previous.bookId || '', previous.chapterNum || fallbackNum)
    : '';
  if (!Object.prototype.hasOwnProperty.call(next, 'liveText') && previous?.liveText && target === previousTarget) {
    next.liveText = previous.liveText;
    next.liveTextTruncated = previous.liveTextTruncated;
  }
  liveGenerationJob = next;
  return next;
}

function appendLiveGenerationText(bookId, chapterNum, text) {
  if (typeof text !== 'string' || !text) return;
  const target = generationStreamId(bookId, chapterNum);
  const currentTarget = liveGenerationJob
    ? generationStreamId(liveGenerationJob.bookId || '', liveGenerationJob.chapterNum || chapterNum)
    : '';
  const base = currentTarget === target
    ? liveGenerationJob
    : {
        bookId,
        chapterNum,
        phase: 'inkos_writing',
        startedAt: new Date().toISOString(),
        progress: [],
      };
  const combined = `${base.liveText || ''}${text}`;
  liveGenerationJob = {
    ...base,
    liveText: retainLiveGenerationText(combined),
    liveTextTruncated: Boolean(base.liveTextTruncated || combined.length > GENERATION_LIVE_TEXT_MAX_CHARS),
    liveTextUpdatedAt: new Date().toISOString(),
  };
  showGenerationProgress(liveGenerationJob, chapterNum);
}

function startGenerationEventStream(bookId, chapterNum) {
  if (!window.EventSource) return;
  const target = generationStreamId(bookId, chapterNum);
  if (generationEventSource && generationStreamKey === target) return;
  closeGenerationEventStream();

  const source = new EventSource(`${API}/books/${encodeURIComponent(bookId)}/generation/${chapterNum}/events`);
  generationEventSource = source;
  generationStreamKey = target;

  source.addEventListener('job', (event) => {
    try {
      const payload = JSON.parse(event.data);
      if (!payload.job || generationStreamKey !== target) return;
      const job = rememberGenerationJob(payload.job, chapterNum);
      showGenerationProgress(job, chapterNum);
    } catch {
      // Keep polling as the fallback if one SSE message is malformed.
    }
  });
  source.addEventListener('delta', (event) => {
    try {
      const payload = JSON.parse(event.data);
      if (generationStreamKey !== target) return;
      appendLiveGenerationText(bookId, chapterNum, payload.text);
    } catch {
      // Keep the existing panel intact and wait for the next valid event.
    }
  });
}

function showGenerationProgress(job, fallbackNum) {
  const overlay = document.getElementById('loadingOverlay');
  const wasActive = overlay.classList.contains('active');
  if (!wasActive && !loadingPreviousFocus) loadingPreviousFocus = document.activeElement;
  const basic = document.getElementById('loadingBasic');
  const panel = document.getElementById('generationProgress');
  const events = generationProgressEvents(job, fallbackNum);
  const terminal = isGenerationJobTerminal(job);
  const failed = ['failed', 'error', 'complete_inkos_failed'].includes(job?.phase);
  const activeIndex = terminal ? -1 : events.length - 1;
  const current = events[events.length - 1];
  const chapterNum = job?.chapterNum || fallbackNum;
  const liveText = typeof job?.liveText === 'string' ? job.liveText : '';
  const preview = liveText
    ? `<section class="generation-live-preview">
        <div class="generation-live-preview-head">
          <strong>LLM 实时输出</strong>
          <span>${job.liveTextTruncated ? '仅显示最新片段' : '未审核'}</span>
        </div>
        <pre class="generation-live-preview-text">${escapeHtml(liveText)}</pre>
      </section>`
    : '';

  panel.innerHTML = `
    <div class="generation-progress-head">
      <div>
        <div class="generation-progress-kicker">第${escapeHtml(chapterNum)}章</div>
        <div class="generation-progress-current">${escapeHtml(current.label)}</div>
      </div>
      <div class="generation-progress-elapsed">${escapeHtml(generationElapsed(job?.startedAt))}</div>
    </div>
    <ol class="generation-progress-list">
      ${events.map((event, index) => {
        const state = terminal
          ? (index === events.length - 1 && failed ? 'failed' : 'done')
          : (index < activeIndex ? 'done' : index === activeIndex ? 'active' : 'waiting');
        const marker = state === 'done' ? '&check;' : state === 'failed' ? '!' : index + 1;
        return `<li class="generation-progress-step ${state}">
          <span class="generation-progress-marker">${marker}</span>
          <span class="generation-progress-copy"><strong>${escapeHtml(event.label)}</strong><small>${escapeHtml(event.detail || '')}</small></span>
          <time>${escapeHtml(formatGenerationTime(event.at))}</time>
        </li>`;
      }).join('')}
    </ol>
    ${preview}`;

  basic.hidden = true;
  panel.hidden = false;
  overlay.classList.add('generation-progress-active', 'active');
  overlay.setAttribute('aria-busy', 'true');
  if (!wasActive) requestAnimationFrame(() => overlay.focus({ preventScroll: true }));

  const livePreview = panel.querySelector('.generation-live-preview-text');
  if (livePreview) {
    requestAnimationFrame(() => {
      livePreview.scrollTop = livePreview.scrollHeight;
    });
  }
}

async function readGenerationJob(bookId, expectedNum) {
  try {
    const result = await api(`/books/${encodeURIComponent(bookId)}/generation/${expectedNum}`);
    return result.job || null;
  } catch {
    return null;
  }
}

async function finishNewChapterWait(bookId, found, expectedNum = found.number) {
  closeGenerationEventStream(bookId, expectedNum);
  hideLoading();
  clearActiveGenerationJob(bookId, expectedNum);
  await loadChapters(bookId);
  await loadChapter(bookId, found.number);
  if (found.llmReview?.status === 'passed') {
    alert(`第${found.number}章「${found.title}」已生成，初审通过，请人工审批！`);
  } else {
    alert(`第${found.number}章「${found.title}」已生成，但初审未通过或异常，请查看原因。`);
  }
}

async function waitForNewChapter(bookId, expectedNum, timeoutMs = 1800000) {
  let deadline = Date.now() + timeoutMs;
  let lastJobStartedAt = '';
  while (Date.now() < deadline) {
    await new Promise(r => setTimeout(r, 5000));
    let found = null;
    try {
      const data = await api(`/books/${encodeURIComponent(bookId)}/chapters`);
      found = (data.chapters || []).find(c => c.number >= expectedNum) || null;
    } catch { /* 继续轮询 */ }

    const job = rememberGenerationJob(await readGenerationJob(bookId, expectedNum), expectedNum);
    if (job) {
      if (job.startedAt && job.startedAt !== lastJobStartedAt) {
        lastJobStartedAt = job.startedAt;
        const serverStartedAt = Date.parse(job.startedAt);
        if (Number.isFinite(serverStartedAt)) {
          deadline = Math.max(deadline, serverStartedAt + timeoutMs);
        }
      }
      showGenerationProgress(job, expectedNum);
    }

    if (found) {
      if (isLlmReviewBusy(found.llmReview)) {
        showGenerationProgress(job || {
          chapterNum: found.number,
          phase: found.llmReview?.status === 'fixing' ? 'llm_fixing' : 'llm_reviewing',
          message: llmReviewLabel(found.llmReview) || '系统 LLM 初审中',
          startedAt: found.updatedAt,
        }, found.number);
        continue;
      }
      if (isLlmReviewTerminal(found.llmReview) || (job && isGenerationJobTerminal(job))) {
        await finishNewChapterWait(bookId, found, expectedNum);
        return;
      }
      showGenerationProgress(job || {
        chapterNum: found.number,
        phase: 'llm_reviewing',
        message: '系统 LLM 初审中',
        startedAt: found.updatedAt,
      }, found.number);
      continue;
    }

    if (job) {
      if (isGenerationJobTerminal(job)) {
        try {
          const latest = await api(`/books/${encodeURIComponent(bookId)}/chapters`);
          const found = (latest.chapters || []).find(c => c.number >= expectedNum);
          if (found && (!found.llmReview || isLlmReviewTerminal(found.llmReview))) {
            await finishNewChapterWait(bookId, found, expectedNum);
            return;
          }
        } catch {}
        if (['failed', 'error'].includes(job.phase)) {
          closeGenerationEventStream(bookId, expectedNum);
          hideLoading();
          clearActiveGenerationJob(bookId, expectedNum);
          await loadChapters(bookId);
          alert(`生成失败：${job.error || generationJobLabel(job, expectedNum)}`);
          return;
        }
      }
    }
  }
  closeGenerationEventStream(bookId, expectedNum);
  hideLoading();
  // 超时边界再强制查一次，避免 InkOS 刚好在前端 timeout 后落盘，
  // 导致页面显示超时但新章节已经进入待审。
  try {
    const latest = await api(`/books/${encodeURIComponent(bookId)}/chapters`);
    const found = (latest.chapters || []).find(c => c.number >= expectedNum);
    if (found) {
      await finishNewChapterWait(bookId, found, expectedNum);
      return;
    }
    await loadChapters(bookId);
  } catch {}
  alert('等待超时（30分钟）。InkOS 可能还在运行；已尝试刷新章节列表，请稍后再刷新页面查看。');
}

// 修订可以经历 InkOS 改写、自动验收和系统初审，不能按一个 16 分钟前端计时器
// 直接报失败。优先相信服务端任务终态；任务仍活跃时持续监听。
async function waitForRevision(bookId, num, timeoutMs = 45 * 60 * 1000) {
  let deadline = Date.now() + timeoutMs;
  let lastJobStartedAt = '';

  while (true) {
    await new Promise(r => setTimeout(r, 5000));
    const job = rememberGenerationJob(await readGenerationJob(bookId, num), num);
    const jobStillActive = Boolean(job && !isGenerationJobTerminal(job));
    if (job) {
      if (job.startedAt && job.startedAt !== lastJobStartedAt) {
        lastJobStartedAt = job.startedAt;
        const serverStartedAt = Date.parse(job.startedAt);
        if (Number.isFinite(serverStartedAt)) {
          deadline = Math.max(deadline, serverStartedAt + timeoutMs);
        }
      }
      showGenerationProgress(job, num);
      if (['failed', 'error', 'complete_inkos_failed'].includes(job.phase)) {
        closeGenerationEventStream(bookId, num);
        hideLoading();
        clearActiveGenerationJob(bookId, num);
        await loadChapters(bookId);
        await loadChapter(bookId, num);
        alert(`修改失败：${job.error || job.llmReview?.summary || generationJobLabel(job, num)}`);
        return;
      }
      if (job.phase === 'complete_needs_review') {
        closeGenerationEventStream(bookId, num);
        hideLoading();
        clearActiveGenerationJob(bookId, num);
        await loadChapters(bookId);
        await loadChapter(bookId, num);
        alert(`第${num}章已修改完成，但 LLM 初审有待处理项，已显示审核意见。`);
        return;
      }
    }

    let chapter = null;
    try {
      chapter = await api(`/books/${encodeURIComponent(bookId)}/chapters/${num}`);
    } catch {
      // A transient refresh failure must not turn a long InkOS task into a
      // false client-side crash. The next job/SSE update will recover the view.
    }

    if (chapter) {
      if (isLlmReviewBusy(chapter.llmReview)) {
        showGenerationProgress(job || {
          bookId,
          chapterNum: num,
          phase: chapter.llmReview?.status === 'reviewing' ? 'llm_reviewing' : 'inkos_revising',
          message: llmReviewLabel(chapter.llmReview) || 'InkOS 正在修改章节',
          startedAt: chapter.updatedAt,
        }, num);
      } else if (!jobStillActive && (isInkosReviewableStatus(chapter.status) || chapter.status === 'pending_review') && chapter.llmReview?.status === 'passed') {
        closeGenerationEventStream(bookId, num);
        hideLoading();
        clearActiveGenerationJob(bookId, num);
        await loadChapters(bookId);
        await loadChapter(bookId, num);
        alert(`第${num}章已修改完成，初审通过，请重新审批！`);
        return;
      } else if (!jobStillActive && (isInkosFailedStatus(chapter.status) || chapter.status === 'revision_failed')) {
        closeGenerationEventStream(bookId, num);
        hideLoading();
        clearActiveGenerationJob(bookId, num);
        await loadChapters(bookId);
        await loadChapter(bookId, num);
        const latestRevision = (chapter.revisionHistory || []).at(-1);
        alert(latestRevision?.success
          ? '修改已完成，但 LLM 初审未通过，已显示审核意见。'
          : (chapter.llmReview?.status === 'failed' ? '初审未通过，已显示原因。' : '修改失败，请查看修改历史。'));
        return;
      }
    }

    if (Date.now() >= deadline) {
      const serverStillWorking = jobStillActive;
      const chapterStillWorking = isLlmReviewBusy(chapter?.llmReview);
      if (serverStillWorking || chapterStillWorking) {
        deadline = Date.now() + timeoutMs;
        continue;
      }
      closeGenerationEventStream(bookId, num);
      hideLoading();
      clearActiveGenerationJob(bookId, num);
      await loadChapters(bookId);
      alert('修改任务超过 45 分钟仍未返回状态；服务端没有活跃任务，请查看修改历史后再决定是否重试。');
      return;
    }
  }
}
async function toggleHistory() {
  const hist = document.getElementById('revisionHistory');
  hist.classList.toggle('active');
  if (hist.classList.contains('active') && currentChapter) {
    const history = currentChapter.revisionHistory || [];
    if (history.length === 0) {
      hist.innerHTML = '<p style="color: var(--text-muted); font-size: 12px;">暂无修改记录</p>';
      return;
    }
    hist.innerHTML = history.map(h => `
      <div class="revision-entry">
        <span class="rev-time">${escapeHtml(new Date(h.time).toLocaleString('zh-CN'))}</span>
        <div class="rev-note">${escapeHtml(h.note)}</div>
        ${h.success !== undefined
          ? (h.success
            ? `<span class="rev-success">修改成功 (${escapeHtml(h.oldContentLength)} - ${escapeHtml(h.newContentLength)} 字)</span>`
            : `<span class="rev-failed">修改失败: ${escapeHtml(h.error || '未知错误')}</span>`)
          : ''}
      </div>
    `).join('');
  }
}

// ====== Import Modal ======
async function openImportModal() {
  const requestSequence = ++importRequestSequence;
  const modal = document.getElementById('importModal');
  importModalPreviousFocus = document.activeElement;
  modal.classList.add('active');
  modal.setAttribute('aria-hidden', 'false');
  document.getElementById('availableBooks').innerHTML = '<div style="text-align:center;padding:20px;"><div class="spin"><div class="spin-dot spin-dot-sm"></div><span class="spin-tip" style="font-size:12px;">加载中...</span></div></div>';
  focusModal(modal);
  try {
    const books = await api('/books/available');
    if (requestSequence !== importRequestSequence || !modal.classList.contains('active')) return;
    const list = document.getElementById('availableBooks');
    if (books.length === 0) {
      list.innerHTML = '<p style="color: var(--text-muted); font-size: 13px;">没有可导入的书籍</p>';
      return;
    }
    list.innerHTML = '';
    books.forEach(b => {
      const item = document.createElement('button');
      item.type = 'button';
      item.className = 'modal-book-item';
      item.textContent = b;
      item.onclick = async () => {
        if (item.disabled) return;
        item.disabled = true;
        closeImportModal({ restoreFocus: false });
        showLoading('正在导入章节...');
        try {
          const result = await api('/books/import', {
            method: 'POST',
            body: JSON.stringify({ bookId: b }),
          });
          hideLoading();
          alert(`导入成功！${result.imported.length} 章`);
          await loadBooks();
        } catch (err) {
          hideLoading();
          alert('导入失败: ' + err.message);
        } finally {
          item.disabled = false;
        }
      };
      list.appendChild(item);
    });
  } catch (err) {
    if (requestSequence !== importRequestSequence || !modal.classList.contains('active')) return;
    document.getElementById('availableBooks').innerHTML = `<p style="color: var(--red); font-size: 13px;">加载失败: ${escapeHtml(err.message)}</p>`;
  }
}

function closeImportModal({ restoreFocus = true } = {}) {
  importRequestSequence += 1;
  const modal = document.getElementById('importModal');
  modal.classList.remove('active');
  modal.setAttribute('aria-hidden', 'true');
  if (restoreFocus) restoreModalFocus(importModalPreviousFocus);
  else loadingPreviousFocus = importModalPreviousFocus;
  importModalPreviousFocus = null;
}

// ====== Create / Delete Book ======
const MAX_LONG_FORM_WORDS = 3_000_000;
const DEFAULT_LONG_FORM_WORDS = 600_000;

const CREATE_BOOK_FORM_FIELDS = [
  'cbSimpleRequirement', 'cbTitle', 'cbLanguage', 'cbGenre', 'cbPlatform',
  'cbTargetChapters', 'cbChapterWords', 'cbTotalWords', 'cbVolumeCount',
  'cbChapterWordTolerance', 'cbPacing',
  'cbPremise', 'cbCharacters', 'cbWorldbuilding', 'cbOutline', 'cbVolumePlan',
  'cbStyle', 'cbConstraints',
];

function parseLongFormWordCount(value) {
  if (Number.isSafeInteger(value)) return value;
  const raw = String(value ?? '').trim().replace(/[,，\s]/g, '');
  if (!raw) return null;
  const match = raw.match(/^(\d+(?:\.\d+)?)(万|萬|亿|億)?(?:字)?$/);
  if (!match) return null;
  const multiplier = match[2] === '万' || match[2] === '萬'
    ? 10_000
    : match[2] === '亿' || match[2] === '億'
      ? 100_000_000
      : 1;
  const words = Math.round(Number(match[1]) * multiplier);
  return Number.isSafeInteger(words) ? words : null;
}

function normalizeSpecialConstraints(value) {
  const entries = Array.isArray(value) ? value : String(value || '').split(/[\n；;]+/);
  return [...new Set(entries.map(item => String(item || '').trim()).filter(Boolean))];
}

function inferVolumeCount(payload = {}) {
  const explicit = Number(payload.volumeCount);
  if (Number.isInteger(explicit) && explicit > 0) return explicit;
  const plan = String(payload.volumePlan || '');
  const markers = plan.match(/(?:^|\n)\s*(?:第?\s*[一二三四五六七八九十百\d]+\s*卷|卷\s*[一二三四五六七八九十百\d]+)/g);
  return Math.max(1, markers?.length || 6);
}

function longFormBudgetFromCreateForm() {
  const targetTotalWords = parseLongFormWordCount(document.getElementById('cbTotalWords')?.value);
  const volumeCount = Number(document.getElementById('cbVolumeCount')?.value);
  const targetChapterWords = Number(document.getElementById('cbChapterWords')?.value);
  const chapterWordTolerance = Number(document.getElementById('cbChapterWordTolerance')?.value);
  const targetChapters = Number.isFinite(targetTotalWords) && Number.isFinite(targetChapterWords) && targetChapterWords > 0
    ? Math.max(1, Math.round(targetTotalWords / targetChapterWords))
    : null;
  return { targetTotalWords, volumeCount, targetChapterWords, chapterWordTolerance, targetChapters };
}

function renderCreateBookBudgetSummary() {
  const summary = document.getElementById('cbBudgetSummary');
  if (!summary) return;
  const budget = longFormBudgetFromCreateForm();
  const valid = Number.isInteger(budget.targetTotalWords)
    && budget.targetTotalWords > 0
    && budget.targetTotalWords <= MAX_LONG_FORM_WORDS
    && Number.isInteger(budget.volumeCount)
    && budget.volumeCount > 0
    && Number.isInteger(budget.targetChapterWords)
    && budget.targetChapterWords >= 500
    && Number.isInteger(budget.chapterWordTolerance)
    && budget.chapterWordTolerance >= 0
    && budget.chapterWordTolerance <= 50;
  const derivedInput = document.getElementById('cbTargetChapters');
  if (derivedInput) derivedInput.value = budget.targetChapters || '';
  const minWords = valid ? Math.max(1, Math.round(budget.targetChapterWords * (1 - budget.chapterWordTolerance / 100))) : null;
  const maxWords = valid ? Math.round(budget.targetChapterWords * (1 + budget.chapterWordTolerance / 100)) : null;
  const averageVolumeWords = valid ? Math.round(budget.targetTotalWords / budget.volumeCount) : null;
  summary.classList.toggle('invalid', !valid);
  summary.innerHTML = [
    ['推导章数', budget.targetChapters ? `${budget.targetChapters.toLocaleString('zh-CN')} 章` : '待填写'],
    ['单章范围', minWords ? `${minWords.toLocaleString('zh-CN')}-${maxWords.toLocaleString('zh-CN')} 字` : '待填写'],
    ['平均每卷', averageVolumeWords ? `${averageVolumeWords.toLocaleString('zh-CN')} 字` : '待填写'],
    ['总字数上限', valid ? `${budget.targetTotalWords.toLocaleString('zh-CN')} / ${MAX_LONG_FORM_WORDS.toLocaleString('zh-CN')}` : '检查输入'],
  ].map(([label, value]) => `<div class="create-book-budget-metric"><span>${label}</span><strong>${value}</strong></div>`).join('');
}

function readCreateBookDraft() {
  return readLocalJson(CREATE_BOOK_DRAFT_KEY, {}) || {};
}

function saveCreateBookDraft(patch = {}) {
  const next = { ...readCreateBookDraft(), ...patch, updatedAt: new Date().toISOString() };
  writeLocalJson(CREATE_BOOK_DRAFT_KEY, next);
  return next;
}

function collectCreateBookFormDraft() {
  const draft = {};
  CREATE_BOOK_FORM_FIELDS.forEach(id => {
    const el = document.getElementById(id);
    if (el) draft[id] = el.value;
  });
  return draft;
}

function saveCreateBookFormDraft() {
  saveCreateBookDraft({ fields: collectCreateBookFormDraft() });
}

function restoreCreateBookFormDraft() {
  const draft = readCreateBookDraft();
  const fields = draft.fields || {};
  Object.entries(fields).forEach(([id, value]) => setFormValue(id, value));
  const status = document.getElementById('cbAssistStatus');
  if (status && draft.assistCompletedAt) {
    status.textContent = `已恢复上次 AI 生成结果（${new Date(draft.assistCompletedAt).toLocaleTimeString()}）`;
  }
  if (status && createBookAssistPromise) {
    status.textContent = 'AI 仍在后台生成设定；可以先关闭，完成后会自动保存。';
    const btn = document.getElementById('cbAssistBtn');
    if (btn) btn.disabled = true;
  }
}

function bindCreateBookDraftAutosave() {
  CREATE_BOOK_FORM_FIELDS.forEach(id => {
    const el = document.getElementById(id);
    if (!el) return;
    const handleChange = () => {
      saveCreateBookFormDraft();
      renderCreateBookBudgetSummary();
    };
    el.addEventListener('input', handleChange);
    el.addEventListener('change', handleChange);
  });
}

function applyCreateBookPayloadToForm(p = {}) {
  const targetTotalWords = parseLongFormWordCount(
    p.targetTotalWords ?? p.totalWordCount ?? p.targetWords ?? p.totalWords,
  ) || DEFAULT_LONG_FORM_WORDS;
  const targetChapterWords = Number(p.targetChapterWords || p.chapterWords || 3000);
  const specialConstraints = normalizeSpecialConstraints(p.specialConstraints || p.constraints);
  setFormValue('cbTitle', p.title);
  setFormValue('cbLanguage', p.language || 'zh');
  setFormValue('cbGenre', p.genre || 'xuanhuan');
  setFormValue('cbPlatform', p.platform || 'tomato');
  setFormValue('cbChapterWords', targetChapterWords);
  setFormValue('cbTotalWords', targetTotalWords);
  setFormValue('cbVolumeCount', inferVolumeCount(p));
  setFormValue('cbChapterWordTolerance', p.chapterWordTolerance ?? p.chapterWordTolerancePercent ?? 15);
  setFormValue('cbPremise', p.premise);
  setFormValue('cbCharacters', p.characters);
  setFormValue('cbWorldbuilding', p.worldbuilding);
  setFormValue('cbOutline', p.outline);
  setFormValue('cbVolumePlan', p.volumePlan);
  setFormValue('cbPacing', p.pacing);
  setFormValue('cbStyle', p.style);
  setFormValue('cbConstraints', specialConstraints.join('\n'));
  renderCreateBookBudgetSummary();
}

function resumeActiveBookCreationJob() {
  const active = readLocalJson(CREATE_BOOK_ACTIVE_JOB_KEY, null);
  if (!active?.jobId) return false;
  showLoading(`正在恢复监听「${active.title || '新书'}」创建任务...`);
  waitForBookCreation(active.jobId, active.title || '新书').catch(err => {
    hideLoading();
    console.warn('[book-create] 恢复监听失败:', err);
    alert(`恢复创建任务监听时出现错误：${err.message}`);
  });
  return true;
}

function openCreateBookModal() {
  openModal('新建小说（InkOS 本地项目）',
    `<div style="padding:12px;border:1px solid #E5E6EB;border-radius:8px;margin-bottom:14px;background:#FAFAFA;">
      <div class="form-group" style="margin-bottom:8px;">
        <label for="cbSimpleRequirement">简易创建：输入你的小说需求</label>
        <textarea class="form-textarea form-textarea-sm" id="cbSimpleRequirement" placeholder="例如：我要写一本番茄玄幻，主角是落魄符师，靠修复禁忌古符破局，整体 200 章，每章 3000 字，前三章要强钩子……"></textarea>
      </div>
      <button class="btn btn-outline btn-sm" id="cbAssistBtn" type="button">AI 自动生成并填入下方 InkOS 设定</button>
      <span id="cbAssistStatus" style="font-size:12px;color:#8b949e;margin-left:8px;">模型：gpt-5.6-terra（不输出思考过程）</span>
    </div>
    <div class="create-book-two-column">
      <div class="form-group"><label for="cbTitle">书名 *</label><input class="form-input" id="cbTitle" placeholder="例如：道衍封诡录"></div>
      <div class="form-group"><label for="cbLanguage">语言</label><select class="form-select" id="cbLanguage"><option value="zh">中文</option><option value="en">English</option></select></div>
      <div class="form-group"><label for="cbGenre">类型</label><input class="form-input" id="cbGenre" value="xuanhuan" placeholder="xuanhuan / urban / fanfic..."></div>
      <div class="form-group"><label for="cbPlatform">平台</label><input class="form-input" id="cbPlatform" value="tomato" placeholder="tomato / qidian / other"></div>
      <div class="form-group"><label for="cbTotalWords">目标总字数 *</label><input class="form-input" id="cbTotalWords" type="number" min="1000" max="3000000" step="1000" value="600000"></div>
      <div class="form-group"><label for="cbVolumeCount">分卷数 *</label><input class="form-input" id="cbVolumeCount" type="number" min="1" max="100" step="1" value="6"></div>
      <div class="form-group"><label for="cbChapterWords">目标单章字数 *</label><input class="form-input" id="cbChapterWords" type="number" min="500" max="20000" step="100" value="3000"></div>
      <div class="form-group"><label for="cbChapterWordTolerance">单章字数容差（%）*</label><input class="form-input" id="cbChapterWordTolerance" type="number" min="0" max="50" step="1" value="15"></div>
      <div class="form-group"><label for="cbTargetChapters">推导目标章数</label><input class="form-input" id="cbTargetChapters" type="number" min="1" step="1" value="200" readonly></div>
      <div class="form-group"><label for="cbPacing">节奏要求</label><input class="form-input" id="cbPacing" placeholder="例如：前三章强钩子，20章一小高潮"></div>
    </div>
    <div class="create-book-budget-summary" id="cbBudgetSummary" aria-live="polite"></div>
    <div class="form-group"><label for="cbPremise">核心创意 / 卖点 *</label><textarea class="form-textarea form-textarea-sm" id="cbPremise" placeholder="一句话设定、主冲突、爽点、差异化卖点"></textarea></div>
    <div class="form-group"><label for="cbCharacters">主角与主要人物 *</label><textarea class="form-textarea form-textarea-sm" id="cbCharacters" placeholder="主角身份、目标、弱点、金手指；重要配角/反派关系"></textarea></div>
    <div class="form-group"><label for="cbWorldbuilding">世界观与规则 *</label><textarea class="form-textarea form-textarea-sm" id="cbWorldbuilding" placeholder="力量体系、禁忌、组织、地域、核心规则"></textarea></div>
    <div class="form-group"><label for="cbOutline">主线大纲 *</label><textarea class="form-textarea" id="cbOutline" placeholder="开局、阶段目标、中段转折、终局方向"></textarea></div>
    <div class="form-group"><label for="cbVolumePlan">分卷规划 *</label><textarea class="form-textarea form-textarea-sm" id="cbVolumePlan" placeholder="卷1：1-50章，目标...&#10;卷2：51-120章，目标..."></textarea></div>
    <div class="create-book-two-column">
      <div class="form-group"><label for="cbStyle">文风要求</label><textarea class="form-textarea form-textarea-sm" id="cbStyle" placeholder="叙事视角、语言质感、对话比例、氛围"></textarea></div>
      <div class="form-group"><label for="cbConstraints">特殊约束 *（每行一条）</label><textarea class="form-textarea form-textarea-sm" id="cbConstraints" placeholder="主角不能无代价越级&#10;已确认的世界规则不可被随机设定覆盖&#10;人物只能使用当前知识边界内的信息"></textarea></div>
    </div>
    <p style="font-size:12px;color:#8b949e;">创建后会在 <code>./book/books/</code> 生成 InkOS 小说目录，并自动加入本系统书籍列表。</p>`,
    true);
  const submitButton = document.getElementById('fqModalSubmit');
  submitButton.disabled = false;
  submitButton.textContent = '开始创建';
  submitButton.onclick = createBookFromModal;
  document.getElementById('cbAssistBtn').onclick = assistFillCreateBookForm;
  restoreCreateBookFormDraft();
  bindCreateBookDraftAutosave();
  renderCreateBookBudgetSummary();
}

function setFormValue(id, value) {
  const el = document.getElementById(id);
  if (el && value !== undefined && value !== null) el.value = value;
}

async function assistFillCreateBookForm() {
  const requirements = document.getElementById('cbSimpleRequirement').value.trim();
  if (!requirements) {
    alert('请先输入简易小说需求');
    return;
  }
  saveCreateBookFormDraft();
  if (createBookAssistPromise) {
    alert('AI 设定生成已经在进行中；可以关闭窗口，完成后会自动保存，重新打开新建小说即可看到结果。');
    return;
  }

  const btn = document.getElementById('cbAssistBtn');
  const status = document.getElementById('cbAssistStatus');
  if (btn) btn.disabled = true;
  if (status) status.textContent = '正在调用 gpt-5.6-terra 生成 InkOS 设定...（关闭窗口也不会丢，完成后自动保存）';

  createBookAssistAbort = new AbortController();
  createBookAssistPromise = api('/books/create/assist', {
    method: 'POST',
    body: JSON.stringify({ requirements }),
    signal: createBookAssistAbort.signal,
  });

  try {
    const r = await createBookAssistPromise;
    const p = r.payload || {};
    createBookAssistLastPayload = p;
    if (document.getElementById('cbTitle')) {
      applyCreateBookPayloadToForm(p);
      const liveStatus = document.getElementById('cbAssistStatus');
      if (liveStatus) liveStatus.textContent = `已生成并填入（${r.model || 'gpt-5.6-terra'}）`;
      saveCreateBookFormDraft();
    } else {
      saveCreateBookDraft({
        fields: { ...readCreateBookDraft().fields, ...payloadToCreateBookFields(p), cbSimpleRequirement: requirements },
        assistCompletedAt: new Date().toISOString(),
      });
    }
  } catch (err) {
    const liveStatus = document.getElementById('cbAssistStatus');
    if (liveStatus) liveStatus.textContent = '生成失败';
    if (err.name !== 'AbortError') alert('AI 自动填写失败: ' + err.message);
  } finally {
    createBookAssistPromise = null;
    createBookAssistAbort = null;
    const liveBtn = document.getElementById('cbAssistBtn');
    if (liveBtn) liveBtn.disabled = false;
  }
}

function payloadToCreateBookFields(p = {}) {
  const targetTotalWords = parseLongFormWordCount(
    p.targetTotalWords ?? p.totalWordCount ?? p.targetWords ?? p.totalWords,
  ) || DEFAULT_LONG_FORM_WORDS;
  const targetChapterWords = Number(p.targetChapterWords || p.chapterWords || 3000);
  const targetChapters = Math.max(1, Math.round(targetTotalWords / targetChapterWords));
  return {
    cbTitle: p.title || '',
    cbLanguage: p.language || 'zh',
    cbGenre: p.genre || 'xuanhuan',
    cbPlatform: p.platform || 'tomato',
    cbTargetChapters: targetChapters,
    cbChapterWords: targetChapterWords,
    cbTotalWords: targetTotalWords,
    cbVolumeCount: inferVolumeCount(p),
    cbChapterWordTolerance: p.chapterWordTolerance ?? p.chapterWordTolerancePercent ?? 15,
    cbPremise: p.premise || '',
    cbCharacters: p.characters || '',
    cbWorldbuilding: p.worldbuilding || '',
    cbOutline: p.outline || '',
    cbVolumePlan: p.volumePlan || '',
    cbPacing: p.pacing || '',
    cbStyle: p.style || '',
    cbConstraints: normalizeSpecialConstraints(p.specialConstraints || p.constraints).join('\n'),
  };
}

function requiredValue(id, label) {
  const value = document.getElementById(id).value.trim();
  if (!value) throw new Error(`请填写${label}`);
  return value;
}

async function createBookFromModal() {
  const submitButton = document.getElementById('fqModalSubmit');
  if (submitButton.disabled) return;
  let payload;
  try {
    const budget = longFormBudgetFromCreateForm();
    const targetChapters = budget.targetChapters;
    const chapterWords = budget.targetChapterWords;
    const specialConstraints = normalizeSpecialConstraints(document.getElementById('cbConstraints').value);
    if (!Number.isInteger(budget.targetTotalWords) || budget.targetTotalWords < 1000 || budget.targetTotalWords > MAX_LONG_FORM_WORDS) {
      throw new Error(`目标总字数必须是 1,000-${MAX_LONG_FORM_WORDS.toLocaleString('zh-CN')} 的整数`);
    }
    if (!Number.isInteger(budget.volumeCount) || budget.volumeCount < 1 || budget.volumeCount > 100) {
      throw new Error('分卷数必须是 1-100 的整数');
    }
    if (!Number.isInteger(targetChapters) || targetChapters < 1) throw new Error('目标章数必须是大于 0 的整数');
    if (!Number.isInteger(chapterWords) || chapterWords < 500 || chapterWords > 20000) throw new Error('目标单章字数必须是 500-20,000 的整数');
    if (!Number.isInteger(budget.chapterWordTolerance) || budget.chapterWordTolerance < 0 || budget.chapterWordTolerance > 50) {
      throw new Error('单章字数容差必须是 0-50 的整数百分比');
    }
    if (specialConstraints.length === 0) throw new Error('请至少填写一条特殊约束');
    payload = {
      title: requiredValue('cbTitle', '书名'),
      language: document.getElementById('cbLanguage').value,
      genre: document.getElementById('cbGenre').value.trim() || 'xuanhuan',
      platform: document.getElementById('cbPlatform').value.trim() || 'tomato',
      targetChapters,
      chapterWords,
      totalWords: String(budget.targetTotalWords),
      targetTotalWords: budget.targetTotalWords,
      volumeCount: budget.volumeCount,
      targetChapterWords: chapterWords,
      chapterWordTolerance: budget.chapterWordTolerance,
      specialConstraints,
      premise: requiredValue('cbPremise', '核心创意 / 卖点'),
      characters: requiredValue('cbCharacters', '主角与主要人物'),
      worldbuilding: requiredValue('cbWorldbuilding', '世界观与规则'),
      outline: requiredValue('cbOutline', '主线大纲'),
      volumePlan: requiredValue('cbVolumePlan', '分卷规划'),
      pacing: document.getElementById('cbPacing').value.trim(),
      style: document.getElementById('cbStyle').value.trim(),
      constraints: specialConstraints.join('\n'),
    };
  } catch (err) {
    alert(err.message);
    return;
  }

  submitButton.disabled = true;
  saveCreateBookFormDraft();
  closeModal({ restoreFocus: false });
  showLoading('InkOS 正在创建小说设定、大纲和本地工程...');
  try {
    const r = await api('/books/create', {
      method: 'POST',
      body: JSON.stringify(payload),
    });
    writeLocalJson(CREATE_BOOK_ACTIVE_JOB_KEY, { jobId: r.jobId, title: payload.title, startedAt: new Date().toISOString() });
    await waitForBookCreation(r.jobId, payload.title);
  } catch (err) {
    hideLoading();
    alert('创建失败: ' + err.message);
  } finally {
    submitButton.disabled = false;
  }
}

async function waitForBookCreation(jobId, title, timeoutMs = 960000) {
  const start = Date.now();
  let transientFailures = 0;
  let missingFailures = 0;
  while (Date.now() - start < timeoutMs) {
    await new Promise(r => setTimeout(r, 5000));
    let job;
    try {
      job = await api(`/books/create/${encodeURIComponent(jobId)}`);
      transientFailures = 0;
      missingFailures = 0;
    } catch (err) {
      transientFailures += 1;
      missingFailures = err.httpStatus === 404 ? missingFailures + 1 : 0;
      if (missingFailures >= 6) {
        hideLoading();
        removeLocalValue(CREATE_BOOK_ACTIVE_JOB_KEY);
        alert('创建任务状态已失效，请检查书籍列表后再决定是否重新创建。');
        return;
      }
      showLoading(`创建任务连接暂时中断，正在重试（${transientFailures}）...`);
      continue;
    }
    if (job.status === 'success') {
      hideLoading();
      currentBook = job.bookId;
      await loadBooks();
      document.getElementById('bookSelector').value = job.bookId;
      await loadChapters(job.bookId);
      removeLocalValue(CREATE_BOOK_ACTIVE_JOB_KEY);
      removeLocalValue(CREATE_BOOK_DRAFT_KEY);
      alert(`小说「${job.title || title}」创建成功，可以开始生成第一章。`);
      return;
    }
    if (job.status === 'failed') {
      hideLoading();
      removeLocalValue(CREATE_BOOK_ACTIVE_JOB_KEY);
      alert(`创建失败: ${job.error || '未知错误'}`);
      return;
    }
    showLoading(`InkOS 正在创建「${title}」... 当前状态：${job.status}`);
  }
  hideLoading();
  alert('等待超时（16分钟）。InkOS 可能仍在运行；本页会保留任务号，刷新后会继续尝试监听。');
}

async function deleteCurrentBook() {
  if (!currentBook) return;
  const bookId = currentBook;
  const book = booksCache.find(b => b.id === bookId);
  const label = book ? `${book.title} (${book.id})` : bookId;
  if (!confirm(`确认删除小说「${label}」？\n\n会从当前系统移除，并把 ./book/books/${bookId} 移到废纸篓。`)) return;
  showLoading('正在删除小说并移动到废纸篓...');
  try {
    const r = await api(`/books/${encodeURIComponent(bookId)}`, { method: 'DELETE' });
    hideLoading();
    if (currentBook === bookId) {
      currentBook = null;
      resetCurrentChapterSelection({ hasBook: false });
    }
    await loadBooks();
    alert(`已删除，备份位置：${r.trashedTo}`);
  } catch (err) {
    hideLoading();
    alert('删除失败: ' + err.message);
  }
}

// ====== Utils ======
function showLoading(text = '正在处理...') {
  const overlay = document.getElementById('loadingOverlay');
  const wasActive = overlay.classList.contains('active');
  if (!wasActive && !loadingPreviousFocus) loadingPreviousFocus = document.activeElement;
  document.getElementById('loadingText').textContent = text;
  document.getElementById('loadingBasic').hidden = false;
  document.getElementById('generationProgress').hidden = true;
  overlay.classList.remove('generation-progress-active');
  overlay.classList.add('active');
  overlay.setAttribute('aria-busy', 'true');
  if (!wasActive) requestAnimationFrame(() => overlay.focus({ preventScroll: true }));
}

function hideLoading() {
  const overlay = document.getElementById('loadingOverlay');
  overlay.classList.remove('active', 'generation-progress-active');
  overlay.setAttribute('aria-busy', 'false');
  if (document.activeElement === overlay) restoreModalFocus(loadingPreviousFocus);
  loadingPreviousFocus = null;
}

function escapeHtml(str) {
  if (str == null) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

function modalFocusableElements(modal) {
  return [...modal.querySelectorAll('button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [href], [tabindex]:not([tabindex="-1"])')]
    .filter(element => element.getClientRects().length > 0);
}

function focusModal(modal) {
  requestAnimationFrame(() => {
    if (!modal.classList.contains('active')) return;
    const preferred = modal.querySelector('input:not([disabled]), textarea:not([disabled]), select:not([disabled])');
    const target = preferred || modalFocusableElements(modal)[0] || modal.querySelector('.modal-content');
    target?.focus({ preventScroll: true });
  });
}

function restoreModalFocus(element) {
  if (!element?.isConnected || typeof element.focus !== 'function') return;
  requestAnimationFrame(() => element.focus({ preventScroll: true }));
}

function trapModalFocus(event, modal) {
  const focusable = modalFocusableElements(modal);
  if (!focusable.length) {
    event.preventDefault();
    modal.querySelector('.modal-content')?.focus();
    return;
  }
  const first = focusable[0];
  const last = focusable[focusable.length - 1];
  if (event.shiftKey && (document.activeElement === first || !modal.contains(document.activeElement))) {
    event.preventDefault();
    last.focus();
  } else if (!event.shiftKey && (document.activeElement === last || !modal.contains(document.activeElement))) {
    event.preventDefault();
    first.focus();
  }
}

document.addEventListener('keydown', event => {
  const sharedModal = document.getElementById('fqModal');
  const importModal = document.getElementById('importModal');
  const activeModal = sharedModal.classList.contains('active')
    ? sharedModal
    : importModal.classList.contains('active') ? importModal : null;
  if (!activeModal) return;
  if (event.key === 'Escape') {
    event.preventDefault();
    activeModal === sharedModal ? closeModal() : closeImportModal();
  } else if (event.key === 'Tab') {
    trapModalFocus(event, activeModal);
  }
});

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState !== 'visible' || generationEventSource) return;
  const active = readActiveGenerationJob();
  if (active) startGenerationEventStream(active.bookId, active.chapterNum);
});

window.addEventListener('beforeunload', event => {
  if (!hasUnsavedBookSettingsChanges()) return;
  event.preventDefault();
  event.returnValue = '';
});
window.addEventListener('beforeunload', () => closeDebugStream());

// Close modal on backdrop click
document.getElementById('importModal').addEventListener('click', (e) => {
  if (e.target.id === 'importModal') closeImportModal();
});

// ====== 番茄在线视图（后台静默拉取，不阻塞用户操作） ======
// 番茄书 bookId / chapterId / title 在视图间传递的状态
let fqCurrentBook = null;   // {bookId, title, status}
// 后台缓存：避免重复拉取阻塞UI
let fqBooksCache = null;       // {books, loggedIn, error, loadedAt}
let fqChaptersCache = {};      // {[bookId]: {chapters, error, loadedAt}}
let fqBackgroundStarted = false;
let fqBackgroundPromise = null;
let fqBackgroundPromiseVersion = 0;
let fqCacheVersion = 0;

function fqResolvedChapterCount(book) {
  const cached = fqChaptersCache[book.bookId];
  if (cached && !cached.error) return (cached.chapters || []).length;
  return Number(book.chapterCount || 0);
}

function fqUpdateBookChapterCount(bookId, count) {
  if (fqBooksCache?.books) {
    fqBooksCache.books = fqBooksCache.books.map(b =>
      b.bookId === bookId ? { ...b, chapterCount: count } : b
    );
  }
  if (fqCurrentBook?.bookId === bookId) {
    fqCurrentBook = { ...fqCurrentBook, chapterCount: count };
  }
  document.querySelectorAll('#fqBookList .fq-card').forEach(card => {
    if (card.dataset.bookId !== String(bookId)) return;
    const countEl = card.querySelector('[data-role="chapter-count"]');
    if (countEl) countEl.textContent = `${count} 章`;
  });
}

// 应用启动时后台静默拉取番茄数据（不阻塞用户操作）
function fqResetCache() {
  fqCacheVersion += 1;
  fqBooksCache = null;
  fqChaptersCache = {};
  fqCurrentBook = null;
  fqBackgroundStarted = false;
}

async function fqBackgroundPrefetch(force = false) {
  const cacheVersion = fqCacheVersion;
  if (fqBackgroundPromise && fqBackgroundPromiseVersion === cacheVersion) return fqBackgroundPromise;
  if (fqBackgroundStarted && !force) return;
  fqBackgroundStarted = true;
  const promise = (async () => {
    try {
      const st = await api('/fanqie/login-state');
      if (cacheVersion !== fqCacheVersion) return;
      if (!st.loggedIn) {
        fqBooksCache = { books: [], loggedIn: false, error: st.reason, loadedAt: Date.now() };
        return;
      }
      const data = await api('/fanqie/books');
      if (cacheVersion !== fqCacheVersion) return;
      fqBooksCache = { books: data.books || [], loggedIn: true, error: null, loadedAt: Date.now() };
    } catch (err) {
      if (cacheVersion !== fqCacheVersion) return;
      fqBooksCache = { books: [], loggedIn: false, error: err.message, loadedAt: Date.now() };
    }
  })().finally(() => {
    if (fqBackgroundPromise === promise) fqBackgroundPromise = null;
  });
  fqBackgroundPromise = promise;
  fqBackgroundPromiseVersion = cacheVersion;
  return promise;
}

async function fqInit() {
  const cacheStale = !fqBooksCache
    || !fqBooksCache.loggedIn
    || Date.now() - Number(fqBooksCache.loadedAt || 0) > 60000;
  if (!fqBackgroundStarted || cacheStale) {
    await fqBackgroundPrefetch(cacheStale);
  }
  await fqShowBooks();
  loadHeaderUser();
}

async function fqShowBooks() {
  const list = document.getElementById('fqBookList');

  // 如果缓存还没到，显示加载动画
  if (!fqBooksCache) {
    list.innerHTML = '<div class="fq-empty"><div class="spin"><div class="spin-dot"></div><span class="spin-tip">加载中...</span></div></div>';
    await new Promise(r => requestAnimationFrame(r));
    for (let i = 0; i < 60 && !fqBooksCache; i++) {
      await new Promise(r => setTimeout(r, 500));
    }
    if (!fqBooksCache) {
      list.innerHTML = '<p class="fq-empty">番茄数据加载超时，请刷新页面重试</p>';
      return;
    }
  }

  if (!fqBooksCache.loggedIn) {
    list.innerHTML = `<div class="fq-empty"><svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#F44B39" stroke-width="2"><circle cx="12" cy="12" r="10"/><path d="M12 8v4m0 4h.01"/></svg><p style="margin-top:8px;color:#F44B39;">${escapeHtml(fqBooksCache.error || '登录态失效')}</p><p style="font-size:11px;margin-top:4px;">请在 fanqie_auto_publish 目录运行 python3 login.py 重新登录</p></div>`;
    return;
  }

  const books = fqBooksCache.books;
  if (books.length === 0) {
    list.innerHTML = '<p class="fq-empty">暂无作品</p>';
    return;
  }

  if (!books.some(book => book.bookId === fqCurrentBook?.bookId)) {
    fqCurrentBook = null;
  }

  list.innerHTML = '';
  books.forEach(b => {
    const card = document.createElement('button');
    card.type = 'button';
    card.className = 'fq-card';
    card.dataset.bookId = String(b.bookId);
    const isActive = fqCurrentBook && fqCurrentBook.bookId === b.bookId;
    if (isActive) {
      card.style.borderColor = '#F44B39';
      card.setAttribute('aria-pressed', 'true');
    } else {
      card.setAttribute('aria-pressed', 'false');
    }
    card.innerHTML = `
      <span class="fq-card-title">${escapeHtml(b.title)}</span>
      <span class="fq-card-meta">
        <span class="fq-badge">${escapeHtml(b.status || '未知')}</span>
        <span data-role="chapter-count">${escapeHtml(fqResolvedChapterCount(b))} 章</span>
        <span>${escapeHtml(b.wordCount || '')}</span>
      </span>
    `;
    card.onclick = () => {
      fqCurrentBook = b;
      fqShowChapters();
      // 高亮选中
      list.querySelectorAll('.fq-card').forEach(c => {
        c.style.borderColor = '';
        c.setAttribute('aria-pressed', 'false');
      });
      card.style.borderColor = '#F44B39';
      card.setAttribute('aria-pressed', 'true');
    };
    list.appendChild(card);
  });

  // 如果有作品且还没选，默认选第一本并加载章节
  if (!fqCurrentBook) {
    fqCurrentBook = books[0];
    const firstCard = list.querySelector('.fq-card');
    firstCard.style.borderColor = '#F44B39';
    firstCard.setAttribute('aria-pressed', 'true');
    fqShowChapters();
  }
}

// 后台预取某书的章节列表（不阻塞UI）
async function fqPrefetchChapters(bookId, bookTitle) {
  if (fqChaptersCache[bookId]) return;
  try {
    const data = await api(`/fanqie/books/${encodeURIComponent(bookId)}/chapters?title=${encodeURIComponent(bookTitle)}`);
    fqChaptersCache[bookId] = { chapters: data.chapters || [], error: null, loadedAt: Date.now() };
    fqUpdateBookChapterCount(bookId, fqChaptersCache[bookId].chapters.length);
  } catch (err) {
    fqChaptersCache[bookId] = { chapters: [], error: err.message, loadedAt: Date.now() };
  }
}

async function fqShowChapters() {
  if (!fqCurrentBook) return;
  const selectedBook = { ...fqCurrentBook };
  const bookId = selectedBook.bookId;
  document.getElementById('fqChapterTitle').textContent =
    `${selectedBook.title} - 章节列表`;
  const tbody = document.getElementById('fqChapterList');

  // 后台预取（如果缓存未命中）
  if (!fqChaptersCache[bookId]) {
    tbody.innerHTML = '<tr><td colspan="4"><div class="fq-empty"><div class="spin"><div class="spin-dot spin-dot-sm"></div><span class="spin-tip" style="font-size:12px;">加载中...</span></div></div></td></tr>';
    fqPrefetchChapters(bookId, selectedBook.title);
    // 等一帧让浏览器渲染
    await new Promise(r => requestAnimationFrame(r));
    // 轮询等待缓存
    for (let i = 0; i < 60 && !fqChaptersCache[bookId]; i++) {
      await new Promise(r => setTimeout(r, 500));
    }
    if (fqCurrentBook?.bookId !== bookId) return;
    if (!fqChaptersCache[bookId]) {
      tbody.innerHTML = '<tr><td colspan="4" class="fq-empty">章节数据加载超时</td></tr>';
      return;
    }
  }

  if (fqCurrentBook?.bookId !== bookId) return;
  const cached = fqChaptersCache[bookId];
  if (cached.error) {
    tbody.innerHTML = `<tr><td colspan="4" class="fq-empty">加载失败: ${escapeHtml(cached.error)}</td></tr>`;
    return;
  }

  const chapters = cached.chapters;
  fqUpdateBookChapterCount(bookId, chapters.length);
  if (chapters.length === 0) {
    tbody.innerHTML = '<tr><td colspan="4" class="fq-empty">暂无章节</td></tr>';
    return;
  }
  tbody.innerHTML = '';
  chapters.forEach(ch => {
    const tr = document.createElement('tr');
    tr.innerHTML = `
      <td>第${escapeHtml(ch.number)}章 ${escapeHtml(ch.title)}</td>
      <td><span class="fq-badge">${escapeHtml(ch.status)}</span></td>
      <td>${escapeHtml(ch.updatedAt || '')}</td>
      <td><div class="fq-ch-actions">
        <button class="fq-action-btn" data-act="view" data-cid="${escapeHtml(ch.chapterId)}" data-num="${escapeHtml(ch.number)}" data-title="${escapeHtml(ch.title)}">
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12Z"/><circle cx="12" cy="12" r="3"/></svg>
          查看正文
        </button>
        </div></td>
      `;
      tr.querySelectorAll('button').forEach(btn => {
        btn.onclick = () => {
          if (btn.dataset.act === 'view') {
            fqViewChapter(btn.dataset.cid, btn.dataset.num, btn.dataset.title);
          }
        };
      });
      tbody.appendChild(tr);
    });
}

// 只读查看番茄章节正文：调用只读 API（绝不发布），在模态框内显示。
async function fqViewChapter(chapterId, num, title) {
  if (!fqCurrentBook) return;
  const bookId = fqCurrentBook.bookId;
  const requestSequence = openModal(`第${num}章 ${title}`, '<div class="fq-empty"><div class="spin"><div class="spin-dot"></div><span class="spin-tip">加载中...</span></div></div>', false);
  try {
    const data = await api(`/fanqie/books/${encodeURIComponent(bookId)}/chapters/${encodeURIComponent(chapterId)}/content`);
    if (requestSequence !== modalRequestSequence || !document.getElementById('fqModal').classList.contains('active')) return;
    const content = (data && data.content) || '';
    const body = document.getElementById('fqModalBody');
    if (!content.trim()) {
      body.innerHTML = '<p class="fq-empty">（该章无正文，或番茄侧为空）</p>';
      return;
    }
    body.innerHTML = `<div class="fq-readonly-content">${escapeHtml(content)}</div>`;
  } catch (err) {
    if (requestSequence !== modalRequestSequence || !document.getElementById('fqModal').classList.contains('active')) return;
    document.getElementById('fqModalBody').innerHTML =
      `<p class="fq-empty">加载失败: ${escapeHtml(err.message)}${err.needRelogin ? '<br>请在 fanqie_auto_publish 目录运行 <code>python3 login.py</code> 重新登录' : ''}</p>`;
  }
}

function openModal(title, bodyHtml, showSubmit) {
  const modal = document.getElementById('fqModal');
  const wasActive = modal.classList.contains('active');
  const requestSequence = ++modalRequestSequence;
  if (!wasActive) modalPreviousFocus = document.activeElement;
  document.getElementById('fqModalTitle').textContent = title;
  document.getElementById('fqModalBody').innerHTML = bodyHtml;
  const submitButton = document.getElementById('fqModalSubmit');
  submitButton.disabled = false;
  submitButton.style.display = showSubmit ? '' : 'none';
  modal.classList.add('active');
  modal.setAttribute('aria-hidden', 'false');
  focusModal(modal);
  return requestSequence;
}
function closeModal({ restoreFocus = true } = {}) {
  modalRequestSequence += 1;
  if (document.getElementById('cbTitle')) saveCreateBookFormDraft();
  const modal = document.getElementById('fqModal');
  modal.classList.remove('active');
  modal.setAttribute('aria-hidden', 'true');
  if (restoreFocus) restoreModalFocus(modalPreviousFocus);
  else loadingPreviousFocus = modalPreviousFocus;
  modalPreviousFocus = null;
}
document.getElementById('fqModal').addEventListener('click', (e) => {
  if (e.target.id === 'fqModal') closeModal();
});

// ====== 设置视图 ======
async function settingsInit() {
  if (!settingsInitPromise) {
    settingsInitPromise = initializeSettings().catch(err => {
      console.error('设置初始化失败', err);
      settingsInitPromise = null;
    });
  }
  await settingsInitPromise;
}

async function initializeSettings() {
  await Promise.all([loadSettingsLlmConfig(), loadSettingsBooks()]);
  loadFanqieAccount();
}

function switchSettingsPane(pane) {
  activeSettingsPane = pane;
  document.querySelectorAll('.settings-tab').forEach(tab => {
    const active = tab.dataset.settingsPane === pane;
    tab.classList.toggle('active', active);
    tab.setAttribute('aria-selected', String(active));
    tab.tabIndex = active ? 0 : -1;
  });
  document.querySelectorAll('.settings-pane').forEach(item => {
    item.classList.remove('active');
    item.hidden = true;
  });
  const target = document.getElementById(`settings${pane[0].toUpperCase()}${pane.slice(1)}Pane`);
  if (target) {
    target.classList.add('active');
    target.hidden = false;
  }
  if (pane === 'utility') {
    loadFanqieAccount();
    if (!debugLoaded) loadDebugPanel();
  }
}

document.querySelector('.settings-tabs')?.addEventListener('keydown', event => {
  if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
  const tabs = [...document.querySelectorAll('.settings-tab')];
  const currentIndex = tabs.indexOf(document.activeElement);
  if (currentIndex < 0) return;
  event.preventDefault();
  let nextIndex = currentIndex;
  if (event.key === 'ArrowLeft') nextIndex = (currentIndex - 1 + tabs.length) % tabs.length;
  if (event.key === 'ArrowRight') nextIndex = (currentIndex + 1) % tabs.length;
  if (event.key === 'Home') nextIndex = 0;
  if (event.key === 'End') nextIndex = tabs.length - 1;
  const nextTab = tabs[nextIndex];
  switchSettingsPane(nextTab.dataset.settingsPane);
  nextTab.focus();
});

async function loadSettingsLlmConfig() {
  try {
    const cfg = await api('/inkos/config');
    document.getElementById('cfgBaseUrl').value = cfg.baseUrl || '';
    document.getElementById('cfgReviewBaseUrl').value = cfg.reviewBaseUrl || '';
    const apiKeyInput = document.getElementById('cfgApiKey');
    apiKeyInput.value = '';
    apiKeyInput.placeholder = cfg.hasApiKey
      ? `已保存 ${cfg.apiKeyPreview || 'API Key'}；留空表示不修改`
      : 'sk-...';
    const reviewApiKeyInput = document.getElementById('cfgReviewApiKey');
    reviewApiKeyInput.value = '';
    reviewApiKeyInput.placeholder = cfg.hasReviewApiKey
      ? `已保存 ${cfg.reviewApiKeyPreview || 'API Key'}；留空表示不修改`
      : '留空则沿用章节生成 API Key';
    settingsCredentialState = {
      reviewUsesChapterKey: !cfg.hasReviewApiKey
        || !cfg.reviewApiKeyPreview
        || cfg.reviewApiKeyPreview === cfg.apiKeyPreview,
    };
    document.getElementById('cfgTemperature').value = cfg.temperature ?? '';
    for (const role of ['chapter', 'review']) {
      const state = modelCatalogState(role);
      state.endpointVersion += 1;
      state.catalogRequestId += 1;
      state.testRequestId += 1;
      state.models = [];
      state.tests = new Map();
      state.loading = false;
      state.batchTesting = false;
      state.batchProgress = null;
    }
    settingsModelCatalogs.chapter.selected = cfg.model || '';
    settingsModelCatalogs.review.selected = cfg.reviewModel || 'gpt-5.6-terra';
    populateModelSelect('chapter');
    populateModelSelect('review');
    await Promise.allSettled([refreshModelCatalog('chapter'), refreshModelCatalog('review')]);
  } catch (err) {
    console.error('加载 LLM 配置失败', err);
  }
}

async function loadSettingsBooks() {
  const sel = document.getElementById('settingsBookSelector');
  try {
    const localBooks = await api('/books');
    const previous = settingsBookId || sel.value || currentBook;
    sel.innerHTML = '<option value="">选择书籍...</option>';
    localBooks.forEach(b => {
      const opt = document.createElement('option');
      opt.value = b.id; opt.textContent = b.title;
      sel.appendChild(opt);
    });
    const next = localBooks.find(book => book.id === previous)?.id || localBooks[0]?.id || '';
    if (next) {
      sel.value = next;
      await loadBookSettingsWorkspace();
    }
  } catch (err) {
    console.error('加载书籍设定列表失败', err);
  }
}

// ====== 番茄账号 ======
async function loadFanqieAccount() {
  const requestSequence = ++fanqieAccountRequestSequence;
  const card = document.getElementById('fanqieAccountCard');
  try {
    const info = await api('/fanqie/account');
    if (requestSequence !== fanqieAccountRequestSequence) return;
    if (!info.loggedIn) {
      card.innerHTML = `
        <div style="display:flex;align-items:center;gap:12px;margin-bottom:12px;">
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#F44B39" stroke-width="2"><circle cx="12" cy="12" r="10"/><path d="M12 8v4m0 4h.01"/></svg>
          <span style="font-size:14px;font-weight:600;color:#F44B39;">未登录</span>
          <span style="font-size:12px;color:#999DA5;">${escapeHtml(info.reason || '')}</span>
        </div>
        <button class="btn btn-primary btn-sm" onclick="fanqieGoLogin()">前往登录</button>
        <p style="font-size:11px;color:#999DA5;margin-top:8px;">登录完成后在 fanqie_auto_publish 目录运行 python3 login.py 保存状态</p>`;
      return;
    }
    card.innerHTML = `
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:14px;">
        <div style="display:flex;align-items:center;gap:10px;">
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#00B578" stroke-width="2"><circle cx="12" cy="12" r="10"/><path d="m8 12 3 3 5-5"/></svg>
          <span style="font-size:14px;font-weight:600;color:#1A1A1A;">已登录</span>
          ${info.authorName ? `<span style="font-size:12px;color:#999DA5;">${escapeHtml(info.authorName)}</span>` : ''}
        </div>
        <div style="display:flex;gap:8px;">
          <button class="btn btn-sm" onclick="fanqieGoLogin()">
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M1 4v6h6M23 20v-6h-6"/><path d="M20.49 9A9 9 0 0 0 5.64 5.64L1 10m22 4-4.64 4.36A9 9 0 0 1 3.51 15"/></svg>
            重新登录
          </button>
          <button class="btn btn-danger btn-sm" onclick="fanqieLogout()">
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16,17 21,12 16,7"/><line x1="21" y1="12" x2="9" y2="12"/></svg>
            退出
          </button>
        </div>
      </div>
      <div style="display:grid;gap:6px;">
        <div class="account-row"><span class="k">会话</span><span class="v">${escapeHtml(info.sessionId || '?')}</span></div>
        <div class="account-row"><span class="k">过期</span><span class="v">${escapeHtml(new Date(info.sessionExpires).toLocaleDateString('zh-CN'))}</span></div>
        <div class="account-row"><span class="k">文件</span><span class="v" style="font-size:11px;">fanqie_auto_publish/state.json</span></div>
      </div>`;
  } catch (err) {
    if (requestSequence !== fanqieAccountRequestSequence) return;
    card.innerHTML = `<div style="display:flex;align-items:center;gap:8px;color:#F44B39;font-size:13px;"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><path d="M12 8v4m0 4h.01"/></svg>加载失败: ${escapeHtml(err.message)}</div>`;
  }
}

async function fanqieGoLogin() {
  try {
    const info = await api('/fanqie/login-url');
    window.open(info.url, '_blank');
    fqResetCache();
    alert(`已在浏览器中打开番茄作家后台。\n\n${info.instructions}`);
  } catch (err) {
    alert('获取登录地址失败: ' + err.message);
  }
}

async function fanqieLogout() {
  if (!confirm('确定退出番茄账号？退出后需重新运行 python3 login.py 登录。')) return;
  showLoading('正在退出...');
  try {
    await api('/fanqie/logout', { method: 'POST' });
    hideLoading();
    alert('已退出。请重新登录。');
    await loadFanqieAccount();
    fqResetCache();
    await fqBackgroundPrefetch(true);
    loadHeaderUser();
  } catch (err) { hideLoading(); alert('退出失败: ' + err.message); }
}

// ====== 书籍设定工作区 ======
function formatPlanWords(value) {
  const words = Number(value);
  return Number.isFinite(words) ? `${Math.round(words).toLocaleString('zh-CN')} 字` : '-';
}

function longFormPlanInputValues() {
  return {
    targetTotalWords: Number(document.getElementById('lfTargetTotalWords')?.value),
    volumeCount: Number(document.getElementById('lfVolumeCount')?.value),
    targetChapterWords: Number(document.getElementById('lfTargetChapterWords')?.value),
    chapterWordTolerance: Number(document.getElementById('lfChapterWordTolerance')?.value),
    specialConstraints: normalizeSpecialConstraints(document.getElementById('lfSpecialConstraints')?.value),
  };
}

function serializeLongFormPlanInputs(values = longFormPlanInputValues()) {
  return JSON.stringify(values);
}

function hasUnsavedLongFormPlanChanges() {
  return Boolean(settingsLongFormPlan && document.getElementById('lfTargetTotalWords'))
    && serializeLongFormPlanInputs() !== settingsLongFormInputSnapshot;
}

function markLongFormPlanDirty() {
  const status = document.getElementById('longFormPlanStatus');
  if (status) status.textContent = hasUnsavedLongFormPlanChanges() ? '有未保存的长篇计划修改。' : '计划未修改。';
}

function renderLongFormPlanPanel() {
  const panel = document.getElementById('longFormPlanPanel');
  if (!panel) return;
  if (!settingsBookId) {
    panel.innerHTML = '<div class="long-form-plan-empty">选择书籍后加载长篇计划。</div>';
    return;
  }
  if (!settingsLongFormPlan) {
    panel.innerHTML = `<div class="long-form-plan-empty">${escapeHtml(settingsLongFormLoadError || '正在读取长篇计划...')}</div>`;
    return;
  }

  const plan = settingsLongFormPlan;
  const constraints = plan.constraints || {};
  const budget = plan.plan || {};
  const volumes = Array.isArray(budget.volumes) ? budget.volumes : [];
  const chapters = Array.isArray(settingsLongFormChapters) ? settingsLongFormChapters : [];
  const writtenWords = chapters.reduce((sum, chapter) => sum + (Number(chapter.wordCount) || 0), 0);
  const writtenChapterNumbers = new Set(chapters.map(chapter => Number(chapter.number)).filter(Number.isFinite));
  const targetTotalWords = Number(constraints.targetTotalWords) || 0;
  const wordProgress = targetTotalWords > 0 ? Math.min(100, Math.round(writtenWords / targetTotalWords * 100)) : 0;
  const nextChapter = writtenChapterNumbers.size > 0 ? Math.max(...writtenChapterNumbers) + 1 : 1;
  const activeVolume = volumes.find(volume => nextChapter >= volume.startChapter && nextChapter <= volume.endChapter)
    || volumes.at(-1)
    || null;
  const sourceMap = { created: '创建计划', migrated: '旧书迁移', updated: '已更新' };

  panel.innerHTML = `
    <div class="long-form-plan-head">
      <div><h3 id="longFormPlanTitle">长篇字数与分卷计划</h3><span>${escapeHtml(sourceMap[plan.source] || plan.source || '结构化计划')} · revision ${escapeHtml(plan.revision || 1)}</span></div>
      <button class="btn btn-primary btn-sm" id="saveLongFormPlanBtn" type="button" onclick="saveLongFormPlan()">保存计划</button>
    </div>
    <div class="long-form-plan-fields">
      <div class="form-group"><label for="lfTargetTotalWords">目标总字数</label><input class="form-input" id="lfTargetTotalWords" type="number" min="1000" max="3000000" step="1000" value="${escapeHtml(constraints.targetTotalWords || '')}"></div>
      <div class="form-group"><label for="lfVolumeCount">分卷数</label><input class="form-input" id="lfVolumeCount" type="number" min="1" max="100" step="1" value="${escapeHtml(constraints.volumeCount || '')}"></div>
      <div class="form-group"><label for="lfTargetChapterWords">目标单章字数</label><input class="form-input" id="lfTargetChapterWords" type="number" min="500" max="20000" step="100" value="${escapeHtml(constraints.targetChapterWords || '')}"></div>
      <div class="form-group"><label for="lfChapterWordTolerance">单章容差（%）</label><input class="form-input" id="lfChapterWordTolerance" type="number" min="0" max="50" step="1" value="${escapeHtml(constraints.chapterWordTolerance ?? '')}"></div>
      <div class="form-group long-form-plan-constraints"><label for="lfSpecialConstraints">特殊约束（每行一条）</label><textarea class="form-textarea" id="lfSpecialConstraints">${escapeHtml(normalizeSpecialConstraints(constraints.specialConstraints).join('\n'))}</textarea></div>
    </div>
    <div class="long-form-plan-metrics">
      <div class="long-form-plan-metric"><span>全书预算</span><strong>${formatPlanWords(targetTotalWords)}</strong></div>
      <div class="long-form-plan-metric"><span>章节进度</span><strong>${chapters.length.toLocaleString('zh-CN')} / ${Number(budget.targetChapters || 0).toLocaleString('zh-CN')}</strong></div>
      <div class="long-form-plan-metric"><span>累计正文</span><strong>${formatPlanWords(writtenWords)} · ${wordProgress}%</strong></div>
      <div class="long-form-plan-metric"><span>当前分卷</span><strong>${activeVolume ? `第 ${activeVolume.number} 卷` : '-'}</strong></div>
    </div>
    <div class="long-form-volume-list">
      ${volumes.map(volume => {
        const volumeChapters = chapters.filter(chapter => chapter.number >= volume.startChapter && chapter.number <= volume.endChapter);
        const volumeWords = volumeChapters.reduce((sum, chapter) => sum + (Number(chapter.wordCount) || 0), 0);
        const progress = volume.targetWords > 0 ? Math.min(100, Math.round(volumeWords / volume.targetWords * 100)) : 0;
        return `<div class="long-form-volume-row">
          <strong>第 ${escapeHtml(volume.number)} 卷</strong>
          <span>第 ${escapeHtml(volume.startChapter)}-${escapeHtml(volume.endChapter)} 章 · ${escapeHtml(volume.chapterCount)} 章</span>
          <span><span>${formatPlanWords(volumeWords)} / ${formatPlanWords(volume.targetWords)}</span><span class="long-form-progress-track"><span style="width:${progress}%"></span></span></span>
        </div>`;
      }).join('') || '<div class="long-form-plan-empty">计划没有分卷预算。</div>'}
    </div>
    <div class="long-form-plan-foot"><div class="long-form-plan-status" id="longFormPlanStatus">计划由后端重新分配逐章与逐卷预算，保存后 revision 自动递增。</div></div>`;

  panel.querySelectorAll('input, textarea').forEach(input => {
    input.addEventListener('input', markLongFormPlanDirty);
    input.addEventListener('change', markLongFormPlanDirty);
  });
  settingsLongFormInputSnapshot = serializeLongFormPlanInputs();
}

function validateLongFormPlanInputs(values) {
  if (!Number.isInteger(values.targetTotalWords) || values.targetTotalWords < 1000 || values.targetTotalWords > MAX_LONG_FORM_WORDS) {
    throw new Error(`目标总字数必须是 1,000-${MAX_LONG_FORM_WORDS.toLocaleString('zh-CN')} 的整数`);
  }
  if (!Number.isInteger(values.volumeCount) || values.volumeCount < 1 || values.volumeCount > 100) throw new Error('分卷数必须是 1-100 的整数');
  if (!Number.isInteger(values.targetChapterWords) || values.targetChapterWords < 500 || values.targetChapterWords > 20000) throw new Error('目标单章字数必须是 500-20,000 的整数');
  if (!Number.isInteger(values.chapterWordTolerance) || values.chapterWordTolerance < 0 || values.chapterWordTolerance > 50) throw new Error('单章容差必须是 0-50 的整数百分比');
  if (values.specialConstraints.length === 0) throw new Error('请至少保留一条特殊约束');
}

async function saveLongFormPlan() {
  if (!settingsBookId || !settingsLongFormPlan) return;
  const values = longFormPlanInputValues();
  try {
    validateLongFormPlanInputs(values);
  } catch (err) {
    alert(err.message);
    return;
  }
  if (!hasUnsavedLongFormPlanChanges()) {
    markLongFormPlanDirty();
    return;
  }
  const bookId = settingsBookId;
  const expectedRevision = settingsLongFormPlan.revision;
  const button = document.getElementById('saveLongFormPlanBtn');
  const status = document.getElementById('longFormPlanStatus');
  if (button) button.disabled = true;
  if (status) status.textContent = '正在保存长篇计划...';
  try {
    const updated = await api(`/books/${encodeURIComponent(bookId)}/long-form-plan`, {
      method: 'PATCH',
      body: JSON.stringify({ expectedRevision, constraints: values }),
    });
    if (settingsBookId !== bookId) return;
    settingsLongFormPlan = updated;
    renderLongFormPlanPanel();
    const liveStatus = document.getElementById('longFormPlanStatus');
    if (liveStatus) liveStatus.textContent = `已保存 revision ${updated.revision}。`;
  } catch (err) {
    if (status) status.textContent = `保存失败：${err.message}`;
    if (err.httpStatus === 409) {
      alert('计划已被其他任务更新，正在重新加载最新 revision。');
      await loadBookSettingsWorkspace({ discardChanges: true });
    } else {
      alert('长篇计划保存失败：' + err.message);
    }
  } finally {
    const liveButton = document.getElementById('saveLongFormPlanBtn');
    if (liveButton) liveButton.disabled = false;
  }
}

function settingsFileUrl(bookId, relPath) {
  const encodedPath = String(relPath || '').split('/').map(encodeURIComponent).join('/');
  return `${API}/books/${encodeURIComponent(bookId)}/settings/${encodedPath}`;
}

function selectedBookSettingsFile() {
  return settingsBookFiles.find(file => file.path === settingsSelectedFilePath) || null;
}

function clearBookSettingsWorkspace(message = '选择书籍后，可查看用途并直接编辑。', { clearPlan = false } = {}) {
  settingsBookFiles = [];
  settingsBookGroups = [];
  settingsSelectedFilePath = '';
  settingsSelectedFileContent = '';
  const list = document.getElementById('settingsFileList');
  const editor = document.getElementById('settingsEditorSurface');
  if (list) list.innerHTML = '';
  if (editor) editor.innerHTML = `<div class="settings-editor-empty">${escapeHtml(message)}</div>`;
  if (clearPlan) {
    settingsLongFormPlan = null;
    settingsLongFormChapters = [];
    settingsLongFormInputSnapshot = '';
    settingsLongFormLoadError = '';
    renderLongFormPlanPanel();
  }
}

function hasUnsavedBookSettingsChanges() {
  const textarea = document.getElementById('settingsFileEditor');
  return Boolean(textarea && textarea.value !== settingsSelectedFileContent);
}

function confirmDiscardBookSettingsChanges() {
  return (!hasUnsavedBookSettingsChanges() && !hasUnsavedLongFormPlanChanges())
    || confirm('当前设定或长篇计划有未保存的修改，确定放弃这些修改吗？');
}

async function loadBookSettingsWorkspace(options = {}) {
  const requestSequence = ++settingsWorkspaceRequestSequence;
  const selector = document.getElementById('settingsBookSelector');
  const bookId = selector?.value || '';
  if (!options.discardChanges && bookId !== settingsBookId && settingsBookId && !confirmDiscardBookSettingsChanges()) {
    if (selector) selector.value = settingsBookId;
    return;
  }
  if (!bookId) {
    settingsBookId = '';
    clearBookSettingsWorkspace('选择书籍后，可查看用途并直接编辑。', { clearPlan: true });
    return;
  }

  const bookChanged = settingsBookId !== bookId;
  settingsBookId = bookId;
  if (bookChanged) {
    settingsFileLoadSequence += 1;
    settingsSelectedFilePath = '';
    settingsSelectedFileContent = '';
  }
  settingsLongFormPlan = null;
  settingsLongFormChapters = [];
  settingsLongFormInputSnapshot = '';
  settingsLongFormLoadError = '';
  renderLongFormPlanPanel();
  const list = document.getElementById('settingsFileList');
  const editor = document.getElementById('settingsEditorSurface');
  if (list) list.innerHTML = '<div class="fq-empty" style="padding:16px 8px;font-size:12px;">加载设定文件...</div>';
  if (editor) editor.innerHTML = '<div class="settings-editor-empty">正在读取书籍设定...</div>';

  try {
    const [data, planResult, chaptersResult] = await Promise.all([
      api(`/books/${encodeURIComponent(bookId)}/settings`),
      api(`/books/${encodeURIComponent(bookId)}/long-form-plan`)
        .then(value => ({ value }))
        .catch(error => ({ error })),
      api(`/books/${encodeURIComponent(bookId)}/chapters`)
        .then(value => ({ value }))
        .catch(error => ({ error })),
    ]);
    if (requestSequence !== settingsWorkspaceRequestSequence || settingsBookId !== bookId) return;
    settingsLongFormPlan = planResult.value || null;
    settingsLongFormLoadError = planResult.error ? `长篇计划加载失败：${planResult.error.message}` : '';
    settingsLongFormChapters = Array.isArray(chaptersResult.value?.chapters) ? chaptersResult.value.chapters : [];
    renderLongFormPlanPanel();
    settingsBookFiles = Array.isArray(data.files) ? data.files : [];
    settingsBookGroups = Array.isArray(data.groups) ? data.groups : [];
    if (!settingsBookFiles.length) {
      clearBookSettingsWorkspace('该书没有可维护的设定文件。');
      return;
    }
    const stillSelected = settingsBookFiles.some(file => file.path === settingsSelectedFilePath);
    if (!stillSelected) settingsSelectedFilePath = settingsBookFiles[0].path;
    renderBookSettingsFileList();
    await selectBookSettingsFile(settingsSelectedFilePath);
  } catch (err) {
    clearBookSettingsWorkspace(`设定文件加载失败：${err.message}`);
  }
}

// Kept as an alias for older callers while the settings page uses the workspace.
async function loadBookSettingsSummary() {
  await loadBookSettingsWorkspace();
}

function sortedBookSettingsFiles() {
  const sort = document.getElementById('settingsFileSort')?.value || 'recommended';
  const query = document.getElementById('settingsFileSearch')?.value.trim().toLowerCase() || '';
  const files = [...settingsBookFiles].filter(file => {
    if (!query) return true;
    return [file.title, file.description, file.path, file.groupTitle].some(value => String(value || '').toLowerCase().includes(query));
  });
  if (sort === 'path') files.sort((a, b) => a.path.localeCompare(b.path, 'zh-CN'));
  return files;
}

function renderBookSettingsFileList() {
  const list = document.getElementById('settingsFileList');
  if (!list) return;
  const files = sortedBookSettingsFiles();
  if (!files.length) {
    list.innerHTML = '<div class="fq-empty" style="padding:16px 8px;font-size:12px;">没有匹配的设定文件</div>';
    return;
  }

  const groups = new Map();
  for (const file of files) {
    const key = file.group || 'other';
    if (!groups.has(key)) groups.set(key, { title: file.groupTitle || '其他设定', files: [] });
    groups.get(key).files.push(file);
  }
  list.innerHTML = [...groups.values()].map(group => `
    <section class="settings-file-group">
      <div class="settings-file-group-title">${escapeHtml(group.title)}</div>
      ${group.files.map(file => `
        <button class="settings-file-item ${file.path === settingsSelectedFilePath ? 'active' : ''}" type="button" data-settings-file="${escapeHtml(file.path)}">
          <span class="settings-file-item-title"><span>${escapeHtml(file.title || file.path)}</span>${file.managed ? '<span class="settings-managed-badge">自动维护</span>' : ''}</span>
          <span class="settings-file-item-path">${escapeHtml(file.path)}</span>
        </button>`).join('')}
    </section>`).join('');
  list.querySelectorAll('[data-settings-file]').forEach(button => {
    button.addEventListener('click', () => selectBookSettingsFile(button.dataset.settingsFile));
  });
}

async function selectBookSettingsFile(relPath, options = {}) {
  if (!settingsBookId || !relPath) return;
  const bookId = settingsBookId;
  const file = settingsBookFiles.find(item => item.path === relPath);
  if (!file) return;
  if (!options.discardChanges && relPath !== settingsSelectedFilePath && !confirmDiscardBookSettingsChanges()) return;
  settingsSelectedFilePath = relPath;
  settingsSelectedFileContent = '';
  const loadSequence = ++settingsFileLoadSequence;
  renderBookSettingsFileList();
  const editor = document.getElementById('settingsEditorSurface');
  editor.innerHTML = `<div class="settings-editor-empty">正在读取「${escapeHtml(file.title || file.path)}」...</div>`;
  try {
    const response = await fetch(settingsFileUrl(bookId, relPath));
    if (!response.ok) {
      const data = await response.json().catch(() => ({}));
      throw new Error(data.error || `HTTP ${response.status}`);
    }
    const content = await response.text();
    if (loadSequence !== settingsFileLoadSequence || bookId !== settingsBookId || relPath !== settingsSelectedFilePath) return;
    settingsSelectedFileContent = content;
    renderBookSettingsEditor();
  } catch (err) {
    if (loadSequence !== settingsFileLoadSequence || bookId !== settingsBookId || relPath !== settingsSelectedFilePath) return;
    editor.innerHTML = `<div class="settings-editor-empty">读取失败：${escapeHtml(err.message)}</div>`;
  }
}

function renderBookSettingsEditor() {
  const editor = document.getElementById('settingsEditorSurface');
  const file = selectedBookSettingsFile();
  if (!file) {
    editor.innerHTML = '<div class="settings-editor-empty">选择左侧文件后，可查看用途并直接编辑。</div>';
    return;
  }
  editor.innerHTML = `
    <div class="settings-editor-head">
      <div>
        <h3>${escapeHtml(file.title || file.path)}${file.managed ? ' <span class="settings-managed-badge">自动维护</span>' : ''}</h3>
        <div class="settings-editor-path">${escapeHtml(file.path)}</div>
        <div class="settings-editor-description">${escapeHtml(file.description || '此文件会参与后续章节的上下文。')}</div>
      </div>
    </div>
    <div class="settings-editor-body"><textarea class="form-textarea" id="settingsFileEditor" spellcheck="false">${escapeHtml(settingsSelectedFileContent)}</textarea></div>
    <div class="settings-editor-foot">
      <div class="settings-editor-status" id="settingsEditorStatus">保存时会自动备份整个 story 目录，失败会尝试还原。</div>
      <div class="settings-editor-actions">
        <button class="btn btn-outline" type="button" onclick="reloadSelectedBookSetting()">重新加载</button>
        <button class="btn btn-primary" type="button" onclick="saveSelectedBookSetting()">保存修改</button>
      </div>
    </div>`;
}

function reloadSelectedBookSetting() {
  if (!settingsSelectedFilePath || !confirmDiscardBookSettingsChanges()) return;
  selectBookSettingsFile(settingsSelectedFilePath, { discardChanges: true });
}

async function saveSelectedBookSetting() {
  const file = selectedBookSettingsFile();
  const textarea = document.getElementById('settingsFileEditor');
  const status = document.getElementById('settingsEditorStatus');
  if (!file || !textarea || !settingsBookId) return;
  const bookId = settingsBookId;
  const filePath = file.path;
  const content = textarea.value;
  if (content === settingsSelectedFileContent) {
    if (status) status.textContent = '没有需要保存的改动。';
    return;
  }
  const buttons = document.querySelectorAll('.settings-editor-actions .btn');
  buttons.forEach(button => { button.disabled = true; });
  if (status) status.textContent = '正在备份并保存...';
  try {
    const result = await api(`/books/${encodeURIComponent(bookId)}/settings/safe-edit`, {
      method: 'POST',
      body: JSON.stringify({ file: filePath, content }),
    });
    if (bookId === settingsBookId && filePath === settingsSelectedFilePath) {
      settingsSelectedFileContent = content;
      if (status) status.textContent = result.ok ? '已保存，并已创建可还原备份。' : '保存完成。';
    }
  } catch (err) {
    if (status) status.textContent = `保存失败：${err.message}`;
  } finally {
    buttons.forEach(button => { button.disabled = false; });
  }
}

function debugFilterValues() {
  const level = document.getElementById('debugLevel')?.value.trim() || '';
  const component = document.getElementById('debugComponent')?.value.trim() || '';
  const traceId = document.getElementById('debugTraceId')?.value.trim() || '';
  const bookId = document.getElementById('debugBookId')?.value.trim() || '';
  const chapterNumber = document.getElementById('debugChapterNumber')?.value.trim() || '';
  const text = document.getElementById('debugText')?.value.trim() || '';
  const requestedLimit = Number(document.getElementById('debugLimit')?.value || 100);
  return {
    level,
    component,
    traceId,
    bookId,
    chapterNumber: chapterNumber && Number.isInteger(Number(chapterNumber)) ? chapterNumber : '',
    text,
    limit: Math.min(5000, Math.max(1, Number.isInteger(requestedLimit) ? requestedLimit : 100)),
  };
}

function debugQueryString(values = debugFilterValues(), format = '') {
  const params = new URLSearchParams();
  for (const key of ['level', 'component', 'traceId', 'bookId', 'chapterNumber', 'text']) {
    if (values[key]) params.set(key, values[key]);
  }
  if (values.limit) params.set('limit', String(values.limit));
  if (format) params.set('format', format);
  return params.toString();
}

function debugEventMatches(event, values = debugFilterValues()) {
  if (values.level && event.level !== values.level) return false;
  if (values.component && event.component !== values.component && event.scope !== values.component) return false;
  if (values.traceId && event.traceId !== values.traceId) return false;
  if (values.bookId && event.bookId !== values.bookId) return false;
  if (values.chapterNumber && Number(event.chapterNumber) !== Number(values.chapterNumber)) return false;
  if (values.text) {
    const haystack = `${event.message || ''} ${JSON.stringify(event.data || {})}`.toLowerCase();
    if (!haystack.includes(values.text.toLowerCase())) return false;
  }
  return true;
}

function debugTimestamp(value) {
  const date = new Date(value || '');
  return Number.isNaN(date.getTime()) ? String(value || '-') : date.toLocaleString('zh-CN', { hour12: false });
}

function debugJson(value) {
  try { return JSON.stringify(value, null, 2); } catch { return String(value || ''); }
}

function debugEventDetails(event) {
  const details = {
    ...(event.data ? { data: event.data } : {}),
    ...(event.error ? { error: event.error } : {}),
  };
  return Object.keys(details).length > 0
    ? `<details class="debug-event-details"><summary>查看结构化数据</summary><pre>${escapeHtml(debugJson(details))}</pre></details>`
    : '';
}

function renderDebugEvents(events = debugEventsCache) {
  const panel = document.getElementById('debugPanel');
  const count = document.getElementById('debugEventCount');
  if (!panel) return;
  if (count) count.textContent = String(events.length);
  if (!events.length) {
    panel.innerHTML = '<div class="debug-empty">没有符合当前筛选条件的事件。</div>';
    return;
  }
  panel.innerHTML = events.slice().sort((left, right) => Number(left.sequence || 0) - Number(right.sequence || 0)).reverse().map(event => {
    const level = ['debug', 'info', 'warn', 'error'].includes(event.level) ? event.level : 'info';
    const context = [
      event.operation ? `<span>操作 <code>${escapeHtml(event.operation)}</code></span>` : '',
      event.phase ? `<span>阶段 ${escapeHtml(event.phase)}</span>` : '',
      event.traceId ? `<span>Trace <code>${escapeHtml(event.traceId)}</code></span>` : '',
      event.bookId ? `<span>书籍 <code>${escapeHtml(event.bookId)}</code></span>` : '',
      Number.isSafeInteger(Number(event.chapterNumber)) ? `<span>第${escapeHtml(event.chapterNumber)}章</span>` : '',
      event.durationMs !== undefined ? `<span>${escapeHtml(event.durationMs)} ms</span>` : '',
    ].filter(Boolean).join('');
    return `<article class="debug-event-row" data-sequence="${escapeHtml(event.sequence)}">
      <div class="debug-event-meta"><span class="debug-event-sequence">#${escapeHtml(event.sequence)}</span><span>${escapeHtml(debugTimestamp(event.ts || event.timestamp))}</span><span class="debug-event-badge level-${level}">${level}</span><span class="debug-event-badge">${escapeHtml(event.component || event.scope || 'debug')}</span><span class="debug-event-id">${escapeHtml(event.eventId || '')}</span></div>
      <div class="debug-event-message">${escapeHtml(event.message || event.operation || '未命名事件')}</div>
      ${context ? `<div class="debug-event-context">${context}</div>` : ''}
      ${debugEventDetails(event)}
    </article>`;
  }).join('');
}

function renderDebugComponentOptions(events = debugEventsCache) {
  const list = document.getElementById('debugComponentOptions');
  if (!list) return;
  const components = [...new Set(events.map(event => event.component || event.scope).filter(Boolean))].sort();
  list.innerHTML = components.map(component => `<option value="${escapeHtml(component)}"></option>`).join('');
}

function renderDebugJobs(jobs = debugJobsSnapshot) {
  const list = document.getElementById('debugJobsList');
  const count = document.getElementById('debugJobCount');
  if (!list) return;
  const entries = [
    ...(jobs.generationJobs || []).map(job => ({ ...job, kind: '生成', title: `${job.bookId || '-'} · 第${job.chapterNum || '-'}章`, state: job.phase || 'queued' })),
    ...(jobs.creationJobs || []).map(job => ({ ...job, kind: '创建', title: job.title || job.jobId || '-', state: job.status || 'queued' })),
  ].sort((left, right) => String(right.updatedAt || right.createdAt || '').localeCompare(String(left.updatedAt || left.createdAt || '')));
  if (count) count.textContent = String(entries.length);
  if (!entries.length) {
    list.innerHTML = '<div class="debug-empty">暂无任务</div>';
    return;
  }
  list.innerHTML = entries.slice(0, 40).map(job => `<div class="debug-job-row"><div class="debug-job-title">${escapeHtml(job.kind)} · ${escapeHtml(job.title)}</div><div class="debug-job-meta">${escapeHtml(job.state)} · ${escapeHtml(debugTimestamp(job.updatedAt || job.createdAt))}</div></div>`).join('');
}

function renderDebugFiles(files = debugFilesSnapshot) {
  const list = document.getElementById('debugFilesList');
  const count = document.getElementById('debugFileCount');
  if (!list) return;
  files = Array.isArray(files) ? files : [];
  if (count) count.textContent = String(files.length);
  if (!files.length) {
    list.innerHTML = '<div class="debug-empty">暂无文件</div>';
    return;
  }
  list.innerHTML = files.map(file => `<div class="debug-file-row"><div class="debug-file-name">${escapeHtml(file.name || '')}</div><div class="debug-file-meta">${escapeHtml(file.size || 0)} bytes · ${escapeHtml(debugTimestamp(file.mtime))}</div></div>`).join('');
}

function updateDebugSummary(result = {}) {
  const meta = document.getElementById('debugResultMeta');
  const health = document.getElementById('debugHealthMeta');
  if (meta) {
    const cursor = result.cursor || debugCursorSnapshot || {};
    meta.textContent = `${debugEventsCache.length} 条事件 · 最新序号 ${cursor.newestSequence || '-'}${result.hasMore ? ' · 还有更早事件' : ''}`;
  }
  if (health) {
    const debug = result.debug || debugJobsSnapshot.debug || {};
    const fileCount = Array.isArray(debug.files) ? debug.files.length : debugFilesSnapshot.length;
    health.textContent = `诊断目录 ${fileCount} 个文件 · 序号 ${debug.currentSequence || '-'}${debugHealthState ? ` · ${debugHealthState}` : ''}`;
  }
}

let debugHealthState = '';

function setDebugStatus(message, state = '') {
  const status = document.getElementById('debugPanelStatus');
  const connection = document.getElementById('debugStreamStatus');
  if (status) status.textContent = message || '';
  if (connection) {
    connection.textContent = state === 'connected' ? '实时已连接' : state === 'connecting' ? '正在连接实时事件' : state === 'failed' ? '实时连接异常，浏览器将重试' : '实时未开启';
    connection.className = `debug-connection-status ${state}`.trim();
  }
}

async function loadDebugPanel({ restartStream = true } = {}) {
  const panel = document.getElementById('debugPanel');
  if (!panel) return;
  const requestId = ++debugRequestSequence;
  const shouldResumeStream = restartStream && Boolean(debugEventSource);
  if (shouldResumeStream) closeDebugStream();
  panel.innerHTML = '<div class="debug-empty">加载中...</div>';
  setDebugStatus('正在读取调试事件…');
  const values = debugFilterValues();
  try {
    const query = debugQueryString(values);
    const [jobs, events, health] = await Promise.all([
      api('/debug/jobs'),
      api(`/debug/events?${query}`),
      api('/debug/health').catch(error => ({ status: 'failed', error: error.message })),
    ]);
    if (requestId !== debugRequestSequence) return;
    debugEventsCache = Array.isArray(events.events) ? events.events : [];
    debugJobsSnapshot = jobs || { generationJobs: [], creationJobs: [], debug: null };
    const fileInfo = events.files || jobs.debug || {};
    debugFilesSnapshot = Array.isArray(fileInfo) ? fileInfo : (Array.isArray(fileInfo.files) ? fileInfo.files : []);
    debugCursorSnapshot = events.cursor || null;
    debugHealthState = health?.status || 'unknown';
    debugLoaded = true;
    renderDebugEvents();
    renderDebugComponentOptions();
    renderDebugJobs();
    renderDebugFiles();
    updateDebugSummary({ ...events, debug: events.files || jobs.debug });
    setDebugStatus(`已更新 ${debugEventsCache.length} 条事件`, debugEventSource ? 'connected' : '');
    if (shouldResumeStream || document.getElementById('debugLiveToggle')?.checked) startDebugStream();
  } catch (err) {
    if (requestId !== debugRequestSequence) return;
    debugLoaded = false;
    panel.innerHTML = `<div class="debug-empty">读取失败：${escapeHtml(err.message)}</div>`;
    setDebugStatus(`Debug 加载失败：${err.message}`, 'failed');
  }
}

function closeDebugStream() {
  if (debugEventSource) {
    debugEventSource.close();
    debugEventSource = null;
  }
  if (debugStreamReconnectTimer) {
    clearTimeout(debugStreamReconnectTimer);
    debugStreamReconnectTimer = null;
  }
  if (debugJobsRefreshTimer) {
    clearInterval(debugJobsRefreshTimer);
    debugJobsRefreshTimer = null;
  }
  if (document.getElementById('debugLiveToggle')?.checked) setDebugStatus('实时已关闭');
}

function startDebugStream() {
  if (!window.EventSource) {
    setDebugStatus('当前浏览器不支持实时事件', 'failed');
    return;
  }
  closeDebugStream();
  const values = debugFilterValues();
  const latest = debugEventsCache.reduce((max, event) => Math.max(max, Number(event.sequence) || 0), 0);
  const params = debugQueryString(values);
  const streamParams = new URLSearchParams(params);
  if (latest > 0) streamParams.set('after', String(latest));
  debugEventSource = new EventSource(`${API}/debug/stream?${streamParams.toString()}`);
  setDebugStatus('正在连接实时事件…', 'connecting');
  const handleEvent = message => {
    try {
      const event = JSON.parse(message.data || '{}');
      const currentValues = debugFilterValues();
      if (!debugEventMatches(event, currentValues)) return;
      if (debugEventsCache.some(item => Number(item.sequence) === Number(event.sequence))) return;
      debugEventsCache = [...debugEventsCache, event].sort((left, right) => Number(left.sequence || 0) - Number(right.sequence || 0)).slice(-currentValues.limit);
      debugCursorSnapshot = { ...(debugCursorSnapshot || {}), newestSequence: event.sequence, nextAfter: event.sequence };
      renderDebugEvents();
      renderDebugComponentOptions();
      updateDebugSummary({ cursor: debugCursorSnapshot });
    } catch {
      setDebugStatus('收到无法解析的实时事件', 'failed');
    }
  };
  debugEventSource.addEventListener('diagnostic', handleEvent);
  debugEventSource.onmessage = handleEvent;
  debugEventSource.onopen = () => setDebugStatus('实时已连接', 'connected');
  const source = debugEventSource;
  debugEventSource.onerror = () => {
    if (debugEventSource !== source) return;
    source.close();
    debugEventSource = null;
    if (debugJobsRefreshTimer) {
      clearInterval(debugJobsRefreshTimer);
      debugJobsRefreshTimer = null;
    }
    setDebugStatus('实时连接异常，正在重试', 'failed');
    if (document.getElementById('debugLiveToggle')?.checked) {
      debugStreamReconnectTimer = setTimeout(startDebugStream, 1500);
    }
  };
  debugJobsRefreshTimer = setInterval(async () => {
    try {
      debugJobsSnapshot = await api('/debug/jobs');
      debugFilesSnapshot = debugJobsSnapshot.debug?.files || debugFilesSnapshot;
      renderDebugJobs();
      renderDebugFiles();
    } catch {}
  }, 10_000);
}

async function toggleDebugStream(enabled) {
  if (!enabled) {
    closeDebugStream();
    setDebugStatus('实时已关闭');
    return;
  }
  if (!debugLoaded) {
    await loadDebugPanel({ restartStream: false });
    return;
  }
  if (document.getElementById('debugLiveToggle')?.checked) startDebugStream();
}

function resetDebugFilters() {
  ['debugComponent', 'debugTraceId', 'debugBookId', 'debugChapterNumber', 'debugText'].forEach(id => {
    const input = document.getElementById(id);
    if (input) input.value = '';
  });
  const level = document.getElementById('debugLevel');
  if (level) level.value = '';
  const limit = document.getElementById('debugLimit');
  if (limit) limit.value = '100';
  loadDebugPanel();
}

function debugSummaryText() {
  const generationJobs = debugJobsSnapshot.generationJobs || [];
  const creationJobs = debugJobsSnapshot.creationJobs || [];
  const lines = [
    `Debug events: ${debugEventsCache.length}`,
    `Health: ${debugHealthState || 'unknown'}`,
    `Generation jobs: ${generationJobs.length}`,
    `Creation jobs: ${creationJobs.length}`,
    `Log files: ${debugFilesSnapshot.length}`,
  ];
  for (const event of debugEventsCache.slice().reverse()) {
    lines.push(`${event.ts || event.timestamp || ''} [${event.level || 'info'}] ${event.component || event.scope || 'debug'} ${event.operation || ''} ${event.message || ''}${event.traceId ? ` trace=${event.traceId}` : ''}${event.bookId ? ` book=${event.bookId}` : ''}`.trim());
  }
  return lines.join('\n');
}

async function copyDebugSummary() {
  if (!debugLoaded) await loadDebugPanel();
  try {
    await copyTextToClipboard(debugSummaryText());
    setDebugStatus('Debug 摘要已复制');
  } catch {
    alert('复制失败，请检查浏览器剪贴板权限');
  }
}

async function downloadDebugJsonl() {
  const query = debugQueryString(debugFilterValues(), 'jsonl');
  try {
    const response = await fetch(`${API}/debug/events?${query}`, { headers: { Accept: 'application/x-ndjson' } });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const blob = await response.blob();
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement('a');
    anchor.href = url;
    anchor.download = `debug-events-${new Date().toISOString().replace(/[:.]/g, '-')}.jsonl`;
    document.body.appendChild(anchor);
    anchor.click();
    anchor.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    setDebugStatus('JSONL 已开始下载');
  } catch (err) {
    setDebugStatus(`JSONL 下载失败：${err.message}`, 'failed');
  }
}

// ====== OpenAI 模型发现与测速 ======
function modelRoleIds(role) {
  return role === 'review'
    ? { select: 'cfgReviewModel', health: 'cfgReviewModelHealth', catalog: 'reviewModelCatalog' }
    : { select: 'cfgModel', health: 'cfgModelHealth', catalog: 'chapterModelCatalog' };
}

function modelCatalogState(role) {
  return settingsModelCatalogs[role === 'review' ? 'review' : 'chapter'];
}

function selectedModelForRole(role) {
  const ids = modelRoleIds(role);
  return document.getElementById(ids.select)?.value.trim() || modelCatalogState(role).selected || '';
}

function modelEndpointPayload(role) {
  const chapterBaseUrl = document.getElementById('cfgBaseUrl')?.value.trim() || '';
  const chapterApiKey = document.getElementById('cfgApiKey')?.value.trim() || '';
  const reviewBaseUrl = document.getElementById('cfgReviewBaseUrl')?.value.trim() || '';
  const reviewApiKey = document.getElementById('cfgReviewApiKey')?.value.trim() || '';
  const effectiveReviewApiKey = reviewApiKey
    || (settingsCredentialState.reviewUsesChapterKey ? chapterApiKey : '');
  return role === 'review'
    ? { role, baseUrl: reviewBaseUrl || chapterBaseUrl, apiKey: effectiveReviewApiKey }
    : { role, baseUrl: chapterBaseUrl, apiKey: chapterApiKey };
}

function modelEndpointFingerprint(role, payload = modelEndpointPayload(role)) {
  const source = `${payload.baseUrl || '[stored-url]'}\n${payload.apiKey || '[stored-key]'}`;
  let hash = 2166136261;
  for (let index = 0; index < source.length; index += 1) {
    hash ^= source.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return `${role}:${(hash >>> 0).toString(16)}`;
}

function modelsForRole(role) {
  const state = modelCatalogState(role);
  const selected = selectedModelForRole(role);
  const models = [...state.models];
  if (selected && !models.some(model => model.id === selected)) {
    models.unshift({ id: selected, ownedBy: '当前配置' });
  }
  return models;
}

function formatModelLatency(latencyMs) {
  const value = Number(latencyMs);
  if (!Number.isFinite(value)) return '';
  return value >= 1000 ? `${(value / 1000).toFixed(1)} 秒` : `${Math.round(value)} ms`;
}

function populateModelSelect(role) {
  const ids = modelRoleIds(role);
  const select = document.getElementById(ids.select);
  if (!select) return;
  const state = modelCatalogState(role);
  const desired = state.selected || select.value || '';
  const models = modelsForRole(role);
  select.innerHTML = '<option value="">请选择模型</option>';
  models.forEach(model => {
    const result = state.tests.get(model.id);
    const option = document.createElement('option');
    option.value = model.id;
    option.textContent = result?.ok === false ? `${model.id}（测速失败）` : model.id;
    option.disabled = Boolean(result && !result.ok && !result.testing && model.id !== desired);
    select.appendChild(option);
  });
  if (desired && [...select.options].some(option => option.value === desired)) select.value = desired;
  state.selected = select.value || desired;
  renderModelHealth(role);
}

function renderModelHealth(role) {
  const ids = modelRoleIds(role);
  const target = document.getElementById(ids.health);
  if (!target) return;
  const model = selectedModelForRole(role);
  const storedResult = model ? modelCatalogState(role).tests.get(model) : null;
  const result = storedResult?.endpointFingerprint === modelEndpointFingerprint(role) ? storedResult : null;
  target.className = 'llm-model-health';
  target.removeAttribute('title');
  if (!model) {
    target.textContent = '请选择模型后再测速。';
    return;
  }
  if (!result) {
    target.textContent = '未测速。可先测速所选模型，或批量测速全部模型。';
    return;
  }
  if (result.testing) {
    target.classList.add('testing');
    target.textContent = '正在测速...';
    return;
  }
  if (result.ok) {
    target.classList.add('ok');
    target.textContent = `可用，响应 ${formatModelLatency(result.latencyMs)}。`;
    return;
  }
  target.classList.add('failed');
  target.textContent = '测速失败，不能作为有效模型保存。';
  target.title = result.error || '模型未通过 OpenAI Chat Completions 测试';
}

function modelTestBadge(result) {
  if (!result) return { text: '未测速', className: '' };
  if (result.testing) return { text: '测速中', className: 'testing' };
  if (result.ok) return { text: formatModelLatency(result.latencyMs), className: 'ok' };
  return { text: '不可用', className: 'failed' };
}

function renderModelCatalog(role) {
  const ids = modelRoleIds(role);
  const target = document.getElementById(ids.catalog);
  if (!target) return;
  const state = modelCatalogState(role);
  const models = modelsForRole(role);
  populateModelSelect(role);
  if (state.loading) {
    target.innerHTML = '<div class="model-catalog-head">正在读取 OpenAI /models...</div>';
    return;
  }
  if (!models.length) {
    target.innerHTML = `<div class="model-catalog-head">${escapeHtml(state.message || '尚未读取模型列表。')}</div>`;
    return;
  }
  const progress = state.batchProgress
    ? `测速 ${state.batchProgress.done}/${state.batchProgress.total}`
    : `已发现 ${models.length} 个模型`;
  target.innerHTML = `
    <div class="model-catalog-head">
      <span>${escapeHtml(state.message || progress)}</span>
      <button class="btn btn-outline btn-sm" type="button" data-benchmark-role="${role}" ${state.batchTesting ? 'disabled' : ''}>${state.batchTesting ? progress : '批量测速'}</button>
    </div>
    <div class="model-speed-list">
      ${models.map(model => {
        const result = state.tests.get(model.id);
        const badge = modelTestBadge(result);
        const title = result?.error ? ` title="${escapeHtml(result.error)}"` : '';
        return `<div class="model-speed-row">
          <div><span class="model-speed-name" title="${escapeHtml(model.id)}">${escapeHtml(model.id)}</span>${model.ownedBy ? `<span class="model-speed-owner">${escapeHtml(model.ownedBy)}</span>` : ''}</div>
          <span class="model-speed-result ${badge.className}"${title}>${escapeHtml(badge.text)}</span>
          <button class="btn btn-outline btn-sm" type="button" data-model-speed-role="${role}" data-model-id="${escapeHtml(model.id)}" ${result?.testing ? 'disabled' : ''}>测速</button>
        </div>`;
      }).join('')}
    </div>`;
  target.querySelector('[data-benchmark-role]')?.addEventListener('click', () => benchmarkModels(role));
  target.querySelectorAll('[data-model-speed-role]').forEach(button => {
    button.addEventListener('click', () => testOpenAiModel(role, button.dataset.modelId));
  });
}

function onModelSelectionChange(role) {
  const state = modelCatalogState(role);
  state.selected = selectedModelForRole(role);
  renderModelHealth(role);
}

function markModelCatalogStale(role) {
  const state = modelCatalogState(role);
  state.selected = selectedModelForRole(role);
  state.endpointVersion += 1;
  state.catalogRequestId += 1;
  state.testRequestId += 1;
  state.models = [];
  state.tests = new Map();
  state.loading = false;
  state.batchTesting = false;
  state.batchProgress = null;
  state.message = 'URL 或 API Key 已变更，请刷新模型列表。';
  renderModelCatalog(role);
}

function markSharedModelCatalogsStale() {
  markModelCatalogStale('chapter');
  markModelCatalogStale('review');
}

async function refreshModelCatalog(role) {
  const state = modelCatalogState(role);
  if (state.loading || state.batchTesting) return;
  const endpointVersion = state.endpointVersion;
  const requestId = ++state.catalogRequestId;
  const endpointPayload = modelEndpointPayload(role);
  const endpointFingerprint = modelEndpointFingerprint(role, endpointPayload);
  state.selected = selectedModelForRole(role);
  state.loading = true;
  state.message = '正在读取 OpenAI /models...';
  renderModelCatalog(role);
  try {
    const result = await api('/inkos/models/list', {
      method: 'POST',
      body: JSON.stringify(endpointPayload),
    });
    if (state.endpointVersion !== endpointVersion
      || state.catalogRequestId !== requestId
      || modelEndpointFingerprint(role) !== endpointFingerprint) return;
    state.models = Array.isArray(result.models) ? result.models : [];
    state.tests = new Map();
    state.message = state.models.length ? `已发现 ${state.models.length} 个模型` : '接口未返回可选模型。';
  } catch (err) {
    if (state.endpointVersion !== endpointVersion
      || state.catalogRequestId !== requestId
      || modelEndpointFingerprint(role) !== endpointFingerprint) return;
    state.models = [];
    state.tests = new Map();
    state.message = `读取失败：${err.message}`;
  } finally {
    if (state.endpointVersion !== endpointVersion || state.catalogRequestId !== requestId) return;
    state.loading = false;
    renderModelCatalog(role);
  }
}

async function testOpenAiModel(role, model) {
  if (!model) return null;
  const state = modelCatalogState(role);
  if (state.tests.get(model)?.testing) return null;
  const endpointVersion = state.endpointVersion;
  const endpointPayload = modelEndpointPayload(role);
  const endpointFingerprint = modelEndpointFingerprint(role, endpointPayload);
  const requestId = ++state.testRequestId;
  state.tests.set(model, { testing: true, endpointFingerprint, requestId });
  renderModelCatalog(role);
  try {
    const result = await api('/inkos/models/test', {
      method: 'POST',
      body: JSON.stringify({ ...endpointPayload, model }),
    });
    if (state.endpointVersion !== endpointVersion
      || modelEndpointFingerprint(role) !== endpointFingerprint
      || state.tests.get(model)?.requestId !== requestId) return { ...result, stale: true };
    const currentResult = { ...result, endpointFingerprint, requestId };
    state.tests.set(model, currentResult);
    return currentResult;
  } catch (err) {
    const result = { ok: false, model, error: err.message, endpointFingerprint, requestId };
    if (state.endpointVersion !== endpointVersion
      || modelEndpointFingerprint(role) !== endpointFingerprint
      || state.tests.get(model)?.requestId !== requestId) return { ...result, stale: true };
    state.tests.set(model, result);
    return result;
  } finally {
    if (state.endpointVersion === endpointVersion) renderModelCatalog(role);
  }
}

async function testSelectedModel(role) {
  const model = selectedModelForRole(role);
  if (!model) {
    alert('请先选择模型。');
    return;
  }
  await testOpenAiModel(role, model);
}

async function benchmarkModels(role) {
  const state = modelCatalogState(role);
  if (state.batchTesting) return;
  if (!state.models.length) {
    await refreshModelCatalog(role);
    if (!state.models.length) return;
  }
  const endpointVersion = state.endpointVersion;
  const endpointFingerprint = modelEndpointFingerprint(role);
  const models = [...state.models];
  state.batchTesting = true;
  state.batchProgress = { done: 0, total: models.length };
  renderModelCatalog(role);
  try {
    for (const model of models) {
      await testOpenAiModel(role, model.id);
      if (state.endpointVersion !== endpointVersion
        || modelEndpointFingerprint(role) !== endpointFingerprint
        || !state.batchProgress) return;
      state.batchProgress.done += 1;
      renderModelCatalog(role);
    }
    if (state.endpointVersion === endpointVersion) state.message = `已完成 ${models.length} 个模型测速`;
  } finally {
    if (state.endpointVersion !== endpointVersion) return;
    state.batchTesting = false;
    state.batchProgress = null;
    renderModelCatalog(role);
  }
}

async function saveInkosConfig() {
  const saveButton = document.getElementById('saveInkosConfigBtn');
  if (saveButton.disabled) return;
  const chapterModel = selectedModelForRole('chapter');
  const reviewModel = selectedModelForRole('review');
  const temperatureText = document.getElementById('cfgTemperature').value.trim();
  if (temperatureText && !Number.isFinite(Number(temperatureText))) {
    alert('Temperature 必须是有效数字，或留空使用默认值。');
    return;
  }
  if (!chapterModel || !reviewModel) {
    alert('请分别选择章节生成模型和设定/初审模型。');
    return;
  }
  for (const [role, model] of [['chapter', chapterModel], ['review', reviewModel]]) {
    const result = modelCatalogState(role).tests.get(model);
    if (result?.testing) {
      alert('所选模型仍在测速，请等待测速完成。');
      return;
    }
    if (!result || result.endpointFingerprint !== modelEndpointFingerprint(role)) {
      alert(`请先测速所选${role === 'chapter' ? '章节生成' : '设定/初审'}模型，并确认当前 URL 与密钥可用。`);
      return;
    }
    if (!result.ok) {
      alert(`所选${role === 'chapter' ? '章节生成' : '设定/初审'}模型测速失败，请选择可用模型。`);
      return;
    }
  }
  const cfg = {
    provider: 'openai',
    apiFormat: 'chat',
    model: chapterModel,
    reviewModel,
    baseUrl: document.getElementById('cfgBaseUrl').value.trim(),
    reviewBaseUrl: document.getElementById('cfgReviewBaseUrl').value.trim(),
    apiKey: document.getElementById('cfgApiKey').value.trim(),
    reviewApiKey: document.getElementById('cfgReviewApiKey').value.trim(),
    stream: false,
    thinkingBudget: 0,
    temperature: temperatureText || null,
  };
  saveButton.disabled = true;
  showLoading('正在应用配置到 inkos...');
  try {
    const r = await api('/inkos/config', { method: 'POST', body: JSON.stringify(cfg) });
    hideLoading();
    alert(`已应用 ${r.applied} 项${r.errors.length ? '，错误: ' + r.errors.join('; ') : ''}`);
  } catch (err) {
    hideLoading();
    alert('保存失败: ' + err.message);
  } finally {
    saveButton.disabled = false;
  }
}

// Start
init();
