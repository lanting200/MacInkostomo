import express from 'express';
import { dirname, join, relative, resolve, sep } from 'path';
import { fileURLToPath } from 'url';
import { loadState, saveState, getBook, getChapter, mergeBookChapterSnapshot, upsertChapterInMemory } from './lib/store.js';
import { listAvailableBooks, importBook } from './lib/importer.js';
import { reviseChapter, retrieveKnowledge, generateChapter, rewriteChapter, readChapterIndex, snapshotExistsFor, reReadChapter } from './lib/inkos.js';
import { listBooks, listChapters, getFanqieChapter, shutdownFanqie } from './lib/fanqie.js';
import { chmodSync, existsSync, readFileSync, writeFileSync, mkdirSync, readdirSync, renameSync, unlinkSync } from 'fs';
import { EventEmitter } from 'events';
import { randomUUID } from 'crypto';
import { assertBookId, bookPath, PATHS } from './lib/paths.js';
import { runInkos, ensureLocalInkosProject, shutdownInkos } from './lib/inkos-runner.js';
import {
  invalidatePublisherInkOSRuntime,
  runPublisherInkOS,
  shutdownPublisherInkOSRuntime,
} from './lib/inkos-runtime.js';
import { chapterLength, STATUS, wordCount } from './lib/status.js';
import { generateCreateBookPayload } from './lib/book-create-assistant.js';
import { reviewGeneratedChapter } from './lib/llm-reviewer.js';
import {
  debugEvent,
  debugEvents,
  debugFileInfo,
  debugHealth,
  debugSchema,
  queryDebugEvents,
} from './lib/debug-log.js';
import { loadWorkflowJobs, saveWorkflowJobs } from './lib/workflow-jobs.js';
import { copyDirectoryStrict, replaceDirectoryFromBackup } from './lib/directory-restore.js';
import { normalizeLlmBaseUrl } from './lib/llm-endpoint.js';
import { writePrivateFile } from './lib/private-file.js';
import {
  assertLongFormHistoryPreserved,
  buildLongFormPlan,
  commitLongFormPlanUpdate,
  loadOrMigrateLongFormPlan,
  normalizeLongFormConstraints,
  preserveLongFormSeed,
  readLongFormPlan,
  renderLongFormChapterContext,
  resolveAdaptiveChapterBudget,
  summarizeChapterBudgets,
  updateLongFormPlan,
  writeLongFormPlan,
} from './lib/long-form-plan.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const app = express();
const requestedPort = Number(process.env.PORT ?? 3456);
const PORT = Number.isInteger(requestedPort) && requestedPort > 0 && requestedPort <= 65535 ? requestedPort : 3456;
const persistedJobs = loadWorkflowJobs();
const creationJobs = new Map(persistedJobs.creationJobs.filter(job => job?.jobId).map(job => [job.jobId, job]));
const generationJobs = new Map(persistedJobs.generationJobs
  .filter(job => job?.bookId && Number.isSafeInteger(job?.chapterNum))
  .map(job => [`${job.bookId}#${job.chapterNum}`, job]));
const generationEvents = new EventEmitter();
const GENERATION_LIVE_TEXT_MAX_CHARS = 16 * 1024;

generationEvents.setMaxListeners(0);

try {
  ensureLocalInkosProject();
} catch (err) {
  console.error('[startup] 项目 InkOS 配置初始化失败:', err.message);
}

function persistWorkflowJobs() {
  try {
    const retained = saveWorkflowJobs(generationJobs.values(), creationJobs.values());
    generationJobs.clear();
    for (const job of retained.generationJobs) {
      if (job?.bookId && Number.isSafeInteger(job?.chapterNum)) {
        generationJobs.set(generationKey(job.bookId, job.chapterNum), job);
      }
    }
    creationJobs.clear();
    for (const job of retained.creationJobs) {
      if (job?.jobId) creationJobs.set(job.jobId, job);
    }
  } catch (err) {
    console.warn('[jobs] 保存任务状态失败:', err.message);
  }
}

function creationRecovery(bookId) {
  if (!bookId) return null;
  let safeBookId;
  try {
    safeBookId = assertBookId(bookId);
  } catch {
    return null;
  }
  if (!existsSync(bookPath(safeBookId))) return null;
  const importable = existsSync(bookPath(safeBookId, 'chapters'));
  return {
    recoverable: true,
    recovery: {
      action: importable ? 'import' : 'inspect',
      bookId: safeBookId,
      relativePath: `book/books/${safeBookId}`,
      importable,
    },
  };
}

function markInterruptedStartupJobs() {
  const now = new Date().toISOString();
  for (const job of generationJobs.values()) {
    if (job.finishedAt) continue;
    Object.assign(job, {
      phase: 'error',
      error: '服务已重启，上一轮任务已中断；请检查 InkOS 磁盘产物后再决定是否重试。',
      message: '服务重启后任务中断',
      updatedAt: now,
      finishedAt: now,
    });
  }
  for (const job of creationJobs.values()) {
    if (job.finishedAt) continue;
    const recovery = creationRecovery(job.bookId || job.expectedBookId);
    Object.assign(job, {
      status: 'failed',
      error: recovery?.recovery.importable
        ? '服务已重启，上一轮创建任务已中断；检测到已保留的 InkOS 产物，可通过“导入现有小说”恢复 Publisher 登记。'
        : '服务已重启，上一轮创建任务已中断；请检查 book/books 中的恢复产物后再决定如何处理。',
      ...(recovery || { recoverable: false }),
      updatedAt: now,
      finishedAt: now,
    });
  }
  persistWorkflowJobs();
}

markInterruptedStartupJobs();

function activeBookJob(bookId) {
  return Array.from(generationJobs.values()).find(job => job.bookId === bookId && !job.finishedAt) || null;
}

function activeWorkflowJob() {
  const generation = Array.from(generationJobs.values()).find(job => !job.finishedAt);
  if (generation) return { type: 'generation', ...generation };
  const creation = Array.from(creationJobs.values()).find(job => !job.finishedAt);
  return creation ? { type: 'creation', ...creation } : null;
}

function rejectActiveBookMutation(res, bookId, action = '修改') {
  const job = activeBookJob(bookId);
  if (!job) return false;
  res.status(409).json({
    error: `该书有生成、修改或审核任务正在运行，请等待任务结束后再${action}。`,
    job,
  });
  return true;
}

function commitBookFromSnapshot(snapshot, bookId, options = {}) {
  const sourceBook = getBook(snapshot, bookId);
  if (!sourceBook) throw new Error('提交状态时书籍已不存在');
  const latest = loadState();
  const latestBook = getBook(latest, bookId);
  if (!latestBook) throw new Error('提交状态时书籍已被删除');
  mergeBookChapterSnapshot(latestBook, sourceBook, options);
  saveState(latest);
  return latestBook;
}

function asyncRoute(handler) {
  return (req, res, next) => Promise.resolve(handler(req, res, next)).catch(next);
}

function generationKey(bookId, chapterNum) {
  return `${bookId}#${chapterNum}`;
}

function readPersistedTerminalGenerationJob(bookId, chapterNum) {
  const state = loadState();
  const book = getBook(state, bookId);
  const chapter = book ? getChapter(book, chapterNum) : null;
  if (!chapter || chapter.status !== STATUS.REVISION_FAILED) return null;

  const revisions = Array.isArray(chapter.revisionHistory) ? chapter.revisionHistory : [];
  const lastRevision = revisions[revisions.length - 1] || null;
  if (lastRevision?.success !== false) return null;
  const finishedAt = chapter.updatedAt || lastRevision?.time || new Date().toISOString();
  const error = lastRevision?.error || chapter.llmReview?.summary || 'InkOS 未产生可接受的修订正文';
  return {
    bookId,
    chapterNum,
    title: chapter.title || '',
    startedAt: lastRevision?.time || finishedAt,
    phase: 'complete_inkos_failed',
    message: '修改未通过，已保留原稿',
    currentStage: 'revision_failed',
    stageStartedAt: finishedAt,
    progress: [{
      stage: 'revision_failed',
      eventKey: 'revision_failed',
      label: '修改未通过，已保留原稿',
      detail: error,
      at: finishedAt,
    }],
    updatedAt: finishedAt,
    finishedAt,
    error,
    llmReview: chapter.llmReview || null,
  };
}

function publishGenerationEvent(bookId, chapterNum, event) {
  generationEvents.emit(generationKey(bookId, chapterNum), event);
}

function setGenerationJob(bookId, chapterNum, patch = {}) {
  const key = generationKey(bookId, chapterNum);
  const prev = generationJobs.get(key);
  const now = new Date().toISOString();
  const isFreshRun = (patch.phase === 'inkos_writing' || patch.phase === 'inkos_revising') && prev?.finishedAt;
  const base = isFreshRun || !prev ? { bookId, chapterNum, startedAt: now } : prev;
  const next = { ...base, ...patch, updatedAt: now };
  if (isFreshRun) {
    delete next.finishedAt;
    delete next.error;
    delete next.llmReview;
    delete next.review;
    delete next.attempts;
  }
  if (patch.phase && String(patch.phase).startsWith('complete') && !patch.error) {
    delete next.error;
  }
  generationJobs.set(key, next);
  persistWorkflowJobs();
  debugEvent('generation', patch.phase || 'update', { bookId, chapterNum, ...patch }, 'info', {
    traceId: next.traceId,
    operation: 'chapter.workflow',
    phase: next.finishedAt ? (next.error ? 'failure' : 'success') : 'progress',
    bookId,
    chapterNumber: chapterNum,
  });
  publishGenerationEvent(bookId, chapterNum, { type: 'job', job: next });
  return next;
}

function finishGenerationJob(bookId, chapterNum, patch = {}) {
  return setGenerationJob(bookId, chapterNum, { ...patch, finishedAt: new Date().toISOString() });
}

function appendGenerationProgress(bookId, chapterNum, progress, patch = {}) {
  const current = generationJobs.get(generationKey(bookId, chapterNum));
  const previous = Array.isArray(current?.progress) ? current.progress : [];
  const event = {
    stage: progress.stage || 'processing',
    eventKey: progress.eventKey || progress.stage || 'processing',
    label: progress.label || '正在处理',
    detail: progress.detail || '',
    at: new Date().toISOString(),
  };
  const latest = previous[previous.length - 1];
  if (latest?.eventKey === event.eventKey) return current;
  return setGenerationJob(bookId, chapterNum, {
    ...patch,
    progress: [...previous, event].slice(-16),
    currentStage: event.stage,
    stageStartedAt: event.at,
    message: event.label,
  });
}

function appendGenerationText(bookId, chapterNum, text) {
  if (typeof text !== 'string' || !text) return null;
  const key = generationKey(bookId, chapterNum);
  const current = generationJobs.get(key);
  if (!current) return null;

  const combined = `${current.liveText || ''}${text}`;
  const truncated = combined.length > GENERATION_LIVE_TEXT_MAX_CHARS;
  const now = new Date().toISOString();
  const next = {
    ...current,
    liveText: truncated ? combined.slice(-GENERATION_LIVE_TEXT_MAX_CHARS) : combined,
    liveTextTruncated: Boolean(current.liveTextTruncated || truncated),
    liveTextUpdatedAt: now,
    updatedAt: now,
  };
  generationJobs.set(key, next);
  // Draft deltas are frequent. Keep them out of the persistent debug log and
  // send them only to clients currently watching this generation.
  publishGenerationEvent(bookId, chapterNum, { type: 'delta', text, at: now });
  return next;
}

function generationInkosCallbacks(bookId, chapterNum, phase) {
  return {
    onProgress: progress => appendGenerationProgress(bookId, chapterNum, progress, { phase }),
    onTextDelta: text => appendGenerationText(bookId, chapterNum, text),
  };
}

function reportRevisionRecovery(bookId, chapterNum, detail) {
  return appendGenerationProgress(bookId, chapterNum, {
    stage: 'revision_restore',
    eventKey: 'revision_restore',
    label: '恢复：正在保留原稿',
    detail: detail || '本次改稿未通过验收，正在恢复正文并同步 InkOS 审核状态',
  }, { phase: 'inkos_revising' });
}

function reportRevisionArtifactSync(bookId, chapterNum) {
  return appendGenerationProgress(bookId, chapterNum, {
    stage: 'revision_sync',
    eventKey: 'revision_sync',
    label: '同步：更新 InkOS 状态',
    detail: '正文已处理，正在同步章节索引和审核状态',
  }, { phase: 'inkos_revising' });
}

function activeReviewFor(bookId, chapterNum) {
  const job = generationJobs.get(generationKey(bookId, chapterNum));
  if (!job || job.finishedAt) return null;
  if (job.phase === 'inkos_writing') {
    return { status: 'inkos_writing', summary: job.message || 'InkOS 正在生成并自审章节', reviewedAt: job.updatedAt, attempts: [] };
  }
  if (job.phase === 'inkos_revising') {
    return { status: 'inkos_revising', summary: 'InkOS 正在根据修改意见重写/修订章节', reviewedAt: job.updatedAt, attempts: [] };
  }
  if (job.phase === 'llm_reviewing') {
    return { status: 'reviewing', model: job.reviewModel || '', summary: '系统 LLM 初审中', reviewedAt: job.updatedAt, attempts: job.attempts || [] };
  }
  if (job.phase === 'llm_fixing') {
    return {
      status: 'fixing',
      model: job.review?.model || job.reviewModel || '',
      summary: job.review?.summary || 'LLM 初审未通过，正在打回 InkOS 修改',
      issues: job.review?.issues || [],
      revisionGuidance: job.review?.revisionGuidance || '',
      reviewedAt: job.updatedAt,
      attempts: job.attempts || [],
    };
  }
  return null;
}

function decorateChapterForClient(bookId, chapter) {
  const active = activeReviewFor(bookId, chapter.number);
  return active ? { ...chapter, llmReview: active } : chapter;
}

function isSystemReviewPassed(chapter) {
  return chapter?.llmReview?.status === 'passed';
}

function isSystemReviewFailed(chapter) {
  return ['failed', 'error', 'inkos_failed'].includes(chapter?.llmReview?.status);
}

function getInkosChapterEntry(bookId, num) {
  return readChapterIndex(bookId, { strict: true }).find(entry => entry.number === num) || null;
}

const INKOS_APPROVABLE_STATUSES = new Set(['drafted', 'audit-passed', 'ready-for-review']);
const INKOS_COMMITTED_STATUSES = new Set(['approved', 'published']);
const INKOS_FAILED_STATUSES = new Set(['audit-failed', 'state-degraded', 'rejected']);

function isInkosApprovable(entry) {
  return entry && INKOS_APPROVABLE_STATUSES.has(entry.status);
}

function isInkosCommitted(entry) {
  return entry && INKOS_COMMITTED_STATUSES.has(entry.status);
}

function isInkosAuditFailed(entry) {
  return entry && INKOS_FAILED_STATUSES.has(entry.status);
}

function isOnlyPublisherStaleAudit(entry) {
  const issues = entry?.auditIssues || [];
  return issues.length > 0 && issues.every(isPublisherStaleAuditNote);
}

function isPublisherStaleAuditNote(note) {
  return /Publisher 自动验收失败|Manual text edit requires review/.test(String(note || ''));
}

function visibleInkosReviewNote(entry) {
  const note = String(entry?.reviewNote || '');
  return isPublisherStaleAuditNote(note) ? '' : note;
}

function inkosAuditFailedReview(entry) {
  const degraded = entry?.status === 'state-degraded';
  const rejected = entry?.status === 'rejected';
  const auditIssues = (entry?.auditIssues || []).filter(issue => !isPublisherStaleAuditNote(issue));
  const reviewNote = visibleInkosReviewNote(entry);
  return {
    status: 'inkos_failed',
    model: 'InkOS',
    summary: rejected
      ? 'InkOS 已拒绝本次修订并保留原稿，请查看修改历史中的原因。'
      : degraded
      ? 'InkOS 状态同步降级，已拦截系统 LLM 通过/人工通过。请先按 InkOS 提示修复状态或打回 InkOS 修改。'
      : 'InkOS 自审未通过，已拦截系统 LLM 通过/人工通过。请按下列 InkOS 审核问题打回修改。',
    issues: [...auditIssues, ...(reviewNote ? [reviewNote] : [])],
    revisionGuidance: [...auditIssues, reviewNote].filter(Boolean).join('\n'),
    reviewedAt: entry?.updatedAt || new Date().toISOString(),
    attempts: [],
  };
}

function mergeInkosChapterForClient(bookId, book, diskEntry) {
  if (!diskEntry) return null;
  const meta = getChapter(book, diskEntry.number) || {};
  const content = reReadChapter(bookId, diskEntry.number);
  const active = activeReviewFor(bookId, diskEntry.number);
  const inkosFailureReview = isInkosAuditFailed(diskEntry) ? inkosAuditFailedReview(diskEntry) : null;
  const llmReview = active || inkosFailureReview || meta.llmReview || null;
  const reviewNote = visibleInkosReviewNote(diskEntry);
  const clientStatus = isInkosApprovable(diskEntry) && ['failed', 'error', 'inkos_failed'].includes(llmReview?.status)
    ? STATUS.REVISION_FAILED
    : diskEntry.status;
  return {
    ...meta,
    number: diskEntry.number,
    title: diskEntry.title || meta.title || '',
    content: content ?? meta.content ?? '',
    status: clientStatus,
    inkosStatus: diskEntry.status,
    publisherStatus: meta.status || null,
    wordCount: diskEntry.wordCount ?? wordCount(content ?? meta.content ?? ''),
    auditIssues: diskEntry.auditIssues || [],
    lengthWarnings: diskEntry.lengthWarnings || [],
    reviewNote,
    reviewNotes: meta.reviewNotes || reviewNote || (diskEntry.auditIssues || []).join('\n'),
    revisionHistory: meta.revisionHistory || [],
    publishedAt: meta.publishedAt || null,
    volume: meta.volume || getVolumeForChapter(diskEntry.number, bookId, book)?.num || null,
    volumeTitle: meta.volumeTitle || (() => {
      const v = getVolumeForChapter(diskEntry.number, bookId, book);
      return v ? `${v.title}·${v.subtitle}` : null;
    })(),
    createdAt: diskEntry.createdAt || meta.createdAt,
    updatedAt: diskEntry.updatedAt || meta.updatedAt,
    llmReview,
  };
}

function listInkosChaptersForClient(bookId, book) {
  const diskIndex = readChapterIndex(bookId, { strict: true })
    .filter(entry => entry?.number)
    .sort((a, b) => a.number - b.number);
  if (diskIndex.length > 0) {
    return diskIndex.map(entry => mergeInkosChapterForClient(bookId, book, entry)).filter(Boolean);
  }
  // Empty new books have no index entries yet. Keep a conservative fallback for
  // legacy imports with missing index.json, but never treat it as authoritative
  // when InkOS index exists.
  return (book?.chapters || []).map(ch => decorateChapterForClient(bookId, ch));
}

function enforceInkosAuditGate(bookId, book) {
  let changed = false;
  for (const ch of book?.chapters || []) {
    if (ch.status === STATUS.APPROVED || ch.status === STATUS.PUBLISHED) continue;
    if (activeReviewFor(bookId, ch.number)) continue;
    const diskEntry = getInkosChapterEntry(bookId, ch.number);
    if (!isInkosAuditFailed(diskEntry)) continue;
    const revisions = Array.isArray(ch.revisionHistory) ? ch.revisionHistory : [];
    const latestRevisionApplied = revisions[revisions.length - 1]?.success === true;
    const nextStatus = latestRevisionApplied ? STATUS.PENDING_REVIEW : STATUS.REVISION_FAILED;
    const nextReview = inkosAuditFailedReview(diskEntry);
    const alreadyMarked = ch.status === nextStatus
      && ch.llmReview?.status === nextReview.status
      && ch.reviewNotes === nextReview.revisionGuidance;
    if (alreadyMarked) continue;
    ch.status = nextStatus;
    ch.llmReview = nextReview;
    ch.reviewNotes = nextReview.revisionGuidance;
    ch.updatedAt = new Date().toISOString();
    if (!alreadyMarked) {
      debugEvent('review_gate', 'inkos_audit_failed_blocked', {
        bookId,
        chapterNum: ch.number,
        title: ch.title,
        issueCount: diskEntry.auditIssues?.length || 0,
      }, 'warn');
    }
    changed = true;
  }
  return changed;
}

function enforceLlmReviewGate(book) {
  let changed = false;
  for (const ch of book?.chapters || []) {
    if (ch.status === STATUS.APPROVED || ch.status === STATUS.PUBLISHED) continue;
    if (ch.llmReview?.status === 'failed' || ch.llmReview?.status === 'error') {
      if (ch.status !== STATUS.REVISION_FAILED) {
        ch.status = STATUS.REVISION_FAILED;
        ch.updatedAt = new Date().toISOString();
        changed = true;
      }
    }
  }
  return changed;
}

app.disable('x-powered-by');

const allowedBrowserOrigins = new Set([
  `http://127.0.0.1:${PORT}`,
  `http://localhost:${PORT}`,
]);

app.use((req, res, next) => {
  const origin = req.get('Origin');
  if (origin && !allowedBrowserOrigins.has(origin)) {
    return res.status(403).json({ error: 'Cross-origin request rejected' });
  }
  if (origin) {
    res.set('Access-Control-Allow-Origin', origin);
    res.set('Vary', 'Origin');
  }
  if (req.method === 'OPTIONS') {
    res.set('Access-Control-Allow-Methods', 'GET, POST, PATCH, DELETE, OPTIONS');
    res.set('Access-Control-Allow-Headers', 'Content-Type');
    return res.sendStatus(204);
  }
  next();
});
app.use(express.json({ limit: '10mb' }));
app.use(express.static(__dirname + '/public'));

app.use((req, res, next) => {
  const incoming = String(req.get('X-Trace-Id') || '').trim();
  req.traceId = /^[A-Za-z0-9._:-]{8,200}$/.test(incoming) ? incoming : randomUUID();
  res.set('X-Trace-Id', req.traceId);
  next();
});

app.param('bookId', (req, res, next, value) => {
  try {
    req.params.bookId = assertBookId(value);
    next();
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

app.use((req, res, next) => {
  const startedAt = Date.now();
  res.on('finish', () => {
    if (req.method !== 'GET' || res.statusCode >= 400) {
      debugEvent('http', `${req.method} ${req.path}`, {
        statusCode: res.statusCode,
        durationMs: Date.now() - startedAt,
      }, res.statusCode >= 400 ? 'warn' : 'info', {
        traceId: req.traceId,
        operation: 'http.request',
        phase: res.statusCode >= 400 ? 'failure' : 'success',
        durationMs: Date.now() - startedAt,
      });
    }
  });
  next();
});

// ============ API ============

app.get('/api/health', (req, res) => {
  res.json({
    ok: true,
    service: 'chapter-publisher',
    pid: process.pid,
    port: PORT,
    uptimeSeconds: Math.round(process.uptime()),
  });
});

// Parse :num route param into a positive integer; null if invalid.
function parseChapterNum(raw) {
  const text = String(raw ?? '');
  if (!/^[1-9]\d*$/.test(text)) return null;
  const n = Number(text);
  return Number.isSafeInteger(n) ? n : null;
}

function containsNear(text, left, right, distance = 120) {
  const source = String(text || '');
  const pattern = new RegExp(`${left}[\\s\\S]{0,${distance}}${right}|${right}[\\s\\S]{0,${distance}}${left}`);
  return pattern.test(source);
}

function readStoryMemoryFile(bookId, fileName) {
  try {
    const file = join(PATHS.BOOKS_SUBDIR, bookId, 'story', fileName);
    return existsSync(file) ? readFileSync(file, 'utf-8') : '';
  } catch {
    return '';
  }
}

function getChapterMarkdownPath(bookId, num) {
  const chaptersDir = join(PATHS.BOOKS_DIR, 'books', bookId, 'chapters');
  const prefix = String(num).padStart(4, '0') + '_';
  try {
    const file = readdirSync(chaptersDir).find(name => name.startsWith(prefix) && name.endsWith('.md'));
    return file ? join(chaptersDir, file) : null;
  } catch {
    return null;
  }
}

async function syncInkosChapterArtifacts(bookId, num, brief, options = {}) {
  if (process.env.PUBLISHER_INKOS_RUNTIME !== 'subprocess') {
    try {
      const result = await runPublisherInkOS('write.sync', bookId, {
        chapterNumber: num,
        externalContext: brief,
        traceId: options.traceId,
        timeoutMs: Number(options.timeout || process.env.PUBLISHER_INKOS_SYNC_TIMEOUT_MS || '60000'),
        callbacks: {
          onTextDelta: options.onTextDelta,
          onStreamProgress: options.onStreamProgress,
        },
      });
      return {
        synced: result?.status !== 'state-degraded',
        runtime: 'framework',
        result,
      };
    } catch (err) {
      if (!/内置 InkOS core 未构建|Cannot find module|ERR_MODULE_NOT_FOUND|core 未就绪/i.test(String(err?.message || err))) {
        console.warn(`[inkos-sync] 内置框架同步失败: ${err.message}`);
        return { synced: false, runtime: 'framework', reason: err.message };
      }
      console.warn(`[inkos-sync] 内置 core 未就绪，回退 CLI：${err.message}`);
    }
  }
  try {
    await runInkos(['write', 'sync', bookId, String(num), '--brief', brief || 'Publisher compatibility sync after chapter body update', '--json'], {
      cwd: PATHS.BOOKS_DIR,
      timeout: Number(options.timeout || process.env.PUBLISHER_INKOS_SYNC_TIMEOUT_MS || '60000'),
      maxBuffer: 10 * 1024 * 1024,
    });
    return { synced: true };
  } catch (err) {
    console.warn(`[inkos-sync] 第${num}章同步 InkOS 产物失败: ${err.message}`);
    return { synced: false, reason: err.message };
  }
}

async function rejectInkosChapterKeepSubsequent(bookId, num, reason) {
  if (process.env.PUBLISHER_INKOS_RUNTIME !== 'subprocess') {
    try {
      const result = await runPublisherInkOS('review.reject', bookId, {
        chapterNumber: num,
        keepSubsequent: true,
        reason: reason || 'Publisher validation failed',
        timeoutMs: 30000,
      });
      return { rejected: true, runtime: 'framework', result };
    } catch (err) {
      if (!isEmbeddedCoreUnavailable(err)) {
        console.warn(`[inkos-review] 第${num}章内置模块标记 rejected 失败: ${err.message}`);
        return { rejected: false, runtime: 'framework', reason: err.message };
      }
      console.warn(`[inkos-review] 内置 core 未就绪，回退 CLI：${err.message}`);
    }
  }
  try {
    await runInkos(['review', 'reject', bookId, String(num), '--keep-subsequent', '--reason', reason || 'Publisher validation failed', '--json'], {
      cwd: PATHS.BOOKS_DIR,
      timeout: 30000,
      maxBuffer: 1024 * 1024,
    });
    return { rejected: true, runtime: 'cli' };
  } catch (err) {
    console.warn(`[inkos-review] 第${num}章标记 rejected 失败: ${err.message}`);
    return { rejected: false, reason: err.message };
  }
}

async function restoreChapterAfterFailedRevision(bookId, num, restoreContent, reason, options = {}) {
  const file = getChapterMarkdownPath(bookId, num);
  if (!file) {
    return { restored: false, reason: 'chapter markdown not found' };
  }
  try {
    writeFileSync(file, restoreContent || '', 'utf-8');
    try {
      options.onSync?.();
    } catch (err) {
      console.warn(`[inkos-sync] 第${num}章同步进度回调失败: ${err.message}`);
    }
    const sync = await syncInkosChapterArtifacts(
      bookId,
      num,
      `Publisher 自动验收失败，恢复修订前正文。原因：${reason}`,
      { timeout: Number(process.env.PUBLISHER_RECOVERY_SYNC_TIMEOUT_MS || '60000') },
    );
    const reject = await rejectInkosChapterKeepSubsequent(bookId, num, `Publisher 自动验收失败，已恢复修订前正文。原因：${reason}`);
    return { restored: true, file, wordCount: wordCount(restoreContent || ''), sync, reject };
  } catch (err) {
    return { restored: false, reason: err.message, file };
  }
}

async function writeChapterMarkdownContent(bookId, num, content, status = 'ready-for-review') {
  const file = getChapterMarkdownPath(bookId, num);
  if (!file) {
    return { written: false, reason: 'chapter markdown not found' };
  }
  try {
    writeFileSync(file, content || '', 'utf-8');
    const sync = await syncInkosChapterArtifacts(bookId, num, `Publisher normalized chapter body; desired review status: ${status}`);
    return { written: true, file, sync };
  } catch (err) {
    return { written: false, reason: err.message, file };
  }
}

function inkosRevisionFailureReview(error) {
  const detail = String(error || 'InkOS 未产生可接受的修订正文').slice(0, 1600);
  return {
    status: 'failed',
    model: 'InkOS',
    summary: `InkOS 未完成本次修订：${detail}`,
    issues: [detail],
    reviewedAt: new Date().toISOString(),
    attempts: [],
  };
}

function validateRevisionResult(note, oldContent, newContent, options = {}) {
  const issues = [];
  const revisionNote = String(note || '');
  const oldWords = wordCount(oldContent || '');
  const newWords = wordCount(newContent || '');
  const oldText = String(oldContent || '');
  const newText = String(newContent || '');
  const chapterSummary = options.bookId
    ? readStoryMemoryFile(options.bookId, 'chapter_summaries.md')
    : '';

  if (/朱砂/.test(revisionNote) && /弱化|术法|法术|镇煞|排斥|强防御|防护/.test(revisionNote)) {
    const banned = ['正式法术', '强防御', '防护罩', '镇煞', '排斥作用'];
    const found = banned.filter(term => newText.includes(term));
    if (found.length > 0) {
      issues.push(`朱砂表述仍偏强：残留 ${found.join('、')}`);
    }
  }

  if (/月光|月亮/.test(revisionNote) && /月光|月亮/.test(newText)) {
    issues.push('夜空设定未修净：仍残留“月光/月亮”');
  }

  if (/用土|糊上/.test(revisionNote) && /用土|糊上/.test(newText)) {
    issues.push('连续性问题未修净：仍残留“用土/糊上”相关表述');
  }

  if (/镇压/.test(revisionNote) && /删除|替换|移除|去掉|避开|不要|禁止/.test(revisionNote) && /镇压/.test(newText)) {
    issues.push('指定禁词未修净：仍残留“镇压”');
  }

  if (
    /不是[\s\S]{0,30}而是|不是……而是|不是.*而是/.test(revisionNote) &&
    /删除|替换|移除|去掉|避开|不要|禁止/.test(revisionNote) &&
    /不是[^，。！？\n]{0,80}[，,]?\s*而是/.test(newText)
  ) {
    issues.push('指定禁用句式未修净：仍残留“不是……而是……”');
  }

  if (/猛地/.test(revisionNote) && /降低|减少|替换|移除|去掉|避免/.test(revisionNote)) {
    const count = (newText.match(/猛地/g) || []).length;
    if (count > 1) {
      issues.push(`疲劳词未充分降低：仍残留“猛地”${count}次`);
    }
  }

  if (/注释/.test(revisionNote) && !/##\s*注释|注释/.test(newText)) {
    issues.push('缺少要求的章末注释');
  }

  if (oldWords > 1000 && newWords < 500) {
    issues.push(`疑似占位/截断正文：修订前 ${oldWords} 字，修订后仅 ${newWords} 字`);
  }

  const establishedLaoZhouHunter =
    containsNear(oldText, '老周', '猎诡人') ||
    containsNear(chapterSummary, '老周', '猎诡人');
  const revisedLaoZhouSealer =
    containsNear(newText, '老周', '封诡师') ||
    /封诡师，不是猎诡人|他是封诡师/.test(newText);
  if (establishedLaoZhouHunter && revisedLaoZhouSealer) {
    issues.push('连续性冲突：老周已建立为猎诡人，修订后被改成封诡师');
  }

  const addedEarlyContractRule =
    !/契约一旦失控|变成自己契约过的那东西|昨晚听老陈提过一嘴/.test(oldText) &&
    /契约一旦失控|变成自己契约过的那东西|昨晚听老陈提过一嘴/.test(newText);
  if (addedEarlyContractRule) {
    issues.push('信息超前：新增“契约失控铁律/昨晚已听过”等前文未建立知识');
  }

  return issues;
}

function buildRevisionValidationRetryNote(originalNote, validationIssues, currentContent, attempt) {
  const currentWords = wordCount(currentContent || '');
  const isTruncated = validationIssues.some(issue => /疑似占位|截断/.test(issue));
  const lengthAction = isTruncated
    ? '当前稿过短：必须在保留已修正逻辑的基础上补回必要场景、人物反应、环境压迫和过渡段，严禁只写摘要或继续删减。'
    : '当前稿存在自动验收问题：只修正列出的失败项，不要引入新设定或新冲突。';

  return [
    originalNote,
    '',
    `【系统自动验收未通过：第 ${attempt} 次继续修订】`,
    `当前修订稿约 ${currentWords} 字。长度仅供参考，不作为自动验收条件。`,
    `未通过项：${validationIssues.join('；')}`,
    lengthAction,
    '必须继续基于当前修订稿写回完整章节 Markdown 正文；不要恢复已经删除的违规线索，不要输出说明、计划或占位文本。',
  ].join('\n');
}

async function retryRevisionUntilValid(bookId, num, title, originalNote, oldContent, initialResult, initialIssues, maxAttempts, reviseOptions = {}) {
  let finalResult = initialResult;
  let validationIssues = [...initialIssues];
  const attempts = [];

  for (let attempt = 1; validationIssues.length > 0 && attempt <= maxAttempts; attempt += 1) {
    const currentContent = finalResult?.newContent || reReadChapter(bookId, num);
    if (!currentContent) break;
    const retryNote = buildRevisionValidationRetryNote(originalNote, validationIssues, currentContent, attempt);
    console.warn(`[revise] ${bookId} 第${num}章 agent 第${attempt}次自动纠偏: ${validationIssues.join('；')}`);
    const retryResult = await reviseChapter(bookId, num, title, retryNote, currentContent, 'agent', reviseOptions);
    attempts.push({
      attempt,
      baseWordCount: wordCount(currentContent),
      issues: validationIssues,
      success: !!retryResult.success,
      reviseMode: retryResult.reviseMode || 'agent',
      newWordCount: retryResult.newContent ? wordCount(retryResult.newContent) : null,
      error: retryResult.error || null,
    });

    if (retryResult.success && retryResult.newContent) {
      finalResult = retryResult;
      validationIssues = validateRevisionResult(originalNote, oldContent, finalResult.newContent, {
        bookId,
        chapterNum: num,
      });
    } else {
      validationIssues = [...validationIssues, retryResult.error || 'agent 自动纠偏未产生有效改动'];
      break;
    }
  }

  return { finalResult, validationIssues, attempts };
}

function isEmbeddedCoreUnavailable(error) {
  return /内置 InkOS core 未构建|Cannot find module|ERR_MODULE_NOT_FOUND|core 未就绪/i
    .test(String(error?.message || error));
}

async function approveInkosChapterIfReviewable(bookId, num) {
  const diskChapter = readChapterIndex(bookId, { strict: true }).find(c => c.number === num);
  if (!diskChapter || diskChapter.status === 'approved') {
    return { synced: false, reason: diskChapter ? 'already approved' : 'missing on disk' };
  }
  if (isInkosAuditFailed(diskChapter)) {
    return { synced: false, reason: `InkOS ${diskChapter.status}` };
  }
  if (!isInkosApprovable(diskChapter)) {
    return { synced: false, reason: `not reviewable: ${diskChapter.status || 'unknown'}` };
  }
  if (process.env.PUBLISHER_INKOS_RUNTIME !== 'subprocess') {
    try {
      const result = await runPublisherInkOS('review.approve', bookId, {
        chapterNumber: num,
        timeoutMs: 30000,
      });
      return { synced: true, reason: 'approved', runtime: 'framework', result };
    } catch (err) {
      if (!isEmbeddedCoreUnavailable(err)) throw err;
      console.warn(`[inkos-review] 内置 core 未就绪，回退 CLI：${err.message}`);
    }
  }
  await runInkos(['review', 'approve', bookId, String(num), '--json'], {
    cwd: PATHS.BOOKS_DIR,
    timeout: 30000,
    maxBuffer: 1024 * 1024,
  });
  return { synced: true, reason: 'approved', runtime: 'cli' };
}

async function syncApprovedChaptersToInkos(bookId, book) {
  const results = [];
  for (const ch of book.chapters) {
    if (ch.status !== STATUS.APPROVED) continue;
    try {
      const result = await approveInkosChapterIfReviewable(bookId, ch.number);
      if (result.synced) console.log(`[inkos-review] 已同步 InkOS 通过: ${bookId} 第${ch.number}章`);
      results.push({ number: ch.number, ...result });
    } catch (err) {
      console.warn(`[inkos-review] 同步第${ch.number}章通过状态失败: ${err.message}`);
      results.push({ number: ch.number, synced: false, reason: err.message });
    }
  }
  return results;
}

function applyInkosReviewStateToPublisherChapter(chapter, diskEntry) {
  if (!chapter || !diskEntry) return;
  if (isInkosAuditFailed(diskEntry)) {
    chapter.status = STATUS.REVISION_FAILED;
    chapter.reviewNotes = [...(diskEntry.auditIssues || []), diskEntry.reviewNote].filter(Boolean).join('\n');
  } else if (['drafted', 'ready-for-review'].includes(diskEntry.status)) {
    chapter.status = isSystemReviewFailed(chapter)
      ? STATUS.REVISION_FAILED
      : STATUS.PENDING_REVIEW;
  } else if (diskEntry.status === 'approved') {
    chapter.status = STATUS.APPROVED;
  } else if (diskEntry.status === 'published') {
    chapter.status = STATUS.PUBLISHED;
  } else if (diskEntry.status === 'rejected') {
    chapter.status = STATUS.REJECTED;
  }
}

// List all books in the system
app.get('/api/books', (req, res) => {
  const state = loadState();
  const booksObj = (state && state.books) || {};
  const books = Object.entries(booksObj).map(([id, book]) => {
    const runningJob = activeBookJob(id);
    const diskIndex = runningJob ? [] : readChapterIndex(id, { strict: true });
    const authoritative = runningJob
      ? (book.chapters || []).map(chapter => decorateChapterForClient(id, chapter))
      : diskIndex.length > 0
      ? diskIndex.map(entry => {
          const meta = getChapter(book, entry.number) || {};
          const active = activeReviewFor(id, entry.number);
          const inkosFailureReview = isInkosAuditFailed(entry) ? inkosAuditFailedReview(entry) : null;
          const llmReview = active || inkosFailureReview || meta.llmReview || null;
          const status = isInkosApprovable(entry) && ['failed', 'error', 'inkos_failed'].includes(llmReview?.status)
            ? STATUS.REVISION_FAILED
            : entry.status;
          return { ...entry, status };
        })
      : (book.chapters || []);
    return {
      id,
      title: book.title,
      chapterCount: authoritative.length,
      pendingReview: authoritative.filter(c => c.status === 'ready-for-review' || c.status === STATUS.PENDING_REVIEW).length,
      approved: authoritative.filter(c => c.status === 'approved').length,
      published: authoritative.filter(c => c.status === 'published').length,
      revisionRequested: authoritative.filter(c => ['drafting', 'auditing', 'revising', STATUS.REVISION_REQUESTED].includes(c.status)).length,
      rejected: authoritative.filter(c => ['audit-failed', 'state-degraded', 'rejected', STATUS.REJECTED, STATUS.REVISION_FAILED].includes(c.status)).length,
    };
  });
  res.json(books);
});

// List available books from InkOS directory (not yet imported)
app.get('/api/books/available', (req, res) => {
  const books = listAvailableBooks();
  res.json(books);
});

// Import a book from InkOS directory
app.post('/api/books/import', (req, res) => {
  try {
    const bookId = assertBookId(req.body?.bookId);
    const runningJob = activeBookJob(bookId);
    if (runningJob) {
      return res.status(409).json({ error: '该书有生成、修改或审核任务正在运行，请等待任务结束后再导入。', job: runningJob });
    }

    const state = loadState();
    const result = importBook(state, bookId);
    res.json(result);
  } catch (err) {
    res.status(err?.statusCode || 500).json({ error: err.message });
  }
});

app.get('/api/books/:bookId/long-form-plan', (req, res) => {
  try {
    const bookId = assertBookId(req.params.bookId);
    const state = loadState();
    if (!getBook(state, bookId)) return res.status(404).json({ error: 'Book not found' });
    res.json(loadOrMigrateLongFormPlan(bookId, { legacyBook: getBook(state, bookId) }));
  } catch (err) {
    res.status(err?.statusCode || 500).json({ error: err.message });
  }
});

app.patch('/api/books/:bookId/long-form-plan', (req, res) => {
  try {
    const bookId = assertBookId(req.params.bookId);
    const state = loadState();
    if (!getBook(state, bookId)) return res.status(404).json({ error: 'Book not found' });
    if (rejectActiveBookMutation(res, bookId, '修改长篇规划')) return;

    const body = req.body || {};
    if (!body || typeof body !== 'object' || Array.isArray(body)) {
      return res.status(400).json({ error: 'PATCH body 必须是对象' });
    }
    if (body.expectedRevision !== undefined
      && (!Number.isSafeInteger(body.expectedRevision) || body.expectedRevision < 1)) {
      return res.status(400).json({ error: 'expectedRevision 必须是大于 0 的整数' });
    }

    const current = loadOrMigrateLongFormPlan(bookId, { legacyBook: getBook(state, bookId) });
    if (body.expectedRevision !== undefined && body.expectedRevision !== current.revision) {
      return res.status(409).json({
        error: `长篇规划已更新，当前 revision 为 ${current.revision}`,
        currentRevision: current.revision,
      });
    }
    const next = updateLongFormPlan(current, body);
    const diskIndex = readChapterIndex(bookId, { strict: true });
    const writtenChapters = collectWrittenChapterMetrics(bookId, getBook(state, bookId), diskIndex);
    assertLongFormHistoryPreserved(current, next, writtenChapters);
    const committed = commitLongFormPlanUpdate(bookId, next, state, { saveState });
    // Keep the in-memory object used by this request aligned with the committed
    // snapshot; subsequent routes load state from disk again.
    Object.assign(state, committed.state);
    res.json(next);
  } catch (err) {
    res.status(err?.statusCode || 500).json({ error: err.message });
  }
});

function safeSlug(input) {
  return String(input || '')
    .trim()
    .replace(/[\\/:*?"<>|\u0000-\u001f]/g, '-')
    .replace(/\s+/g, '-')
    .slice(0, 80) || `book-${Date.now().toString(36)}`;
}

function resolveBookLanguage(bookId, book) {
  const fromState = book?.inkos?.language || book?.language || book?.creation?.payload?.language;
  if (fromState === 'en' || fromState === 'zh') return fromState;
  try {
    const metadata = JSON.parse(readFileSync(bookPath(bookId, 'book.json'), 'utf-8'));
    return metadata.language === 'en' ? 'en' : 'zh';
  } catch {
    return 'zh';
  }
}

function collectWrittenChapterMetrics(bookId, book, diskIndex = null) {
  const language = resolveBookLanguage(bookId, book);
  const metrics = new Map();
  for (const chapter of book?.chapters || []) {
    const number = Number(chapter?.number);
    if (!Number.isSafeInteger(number) || number < 1) continue;
    const words = Number(chapter.wordCount);
    metrics.set(number, {
      number,
      wordCount: Number.isSafeInteger(words) && words >= 0 ? words : chapterLength(chapter.content || '', language),
      source: 'state',
      trusted: (Number.isSafeInteger(words) && words > 0) || Boolean(chapter.content),
    });
  }
  for (const entry of Array.isArray(diskIndex) ? diskIndex : readChapterIndex(bookId, { strict: true })) {
    const number = Number(entry?.number);
    if (!Number.isSafeInteger(number) || number < 1) continue;
    const words = Number(entry.wordCount);
    let actualWords = Number.isSafeInteger(words) && words >= 0 ? words : null;
    if (actualWords === null) {
      const content = reReadChapter(bookId, number);
      if (content !== null) actualWords = chapterLength(content, language);
    }
    const previous = metrics.get(number);
    metrics.set(number, {
      number,
      wordCount: actualWords === null ? (previous?.wordCount || 0) : actualWords,
      source: 'disk',
      trusted: actualWords !== null && actualWords > 0,
    });
  }
  return Array.from(metrics.values()).sort((left, right) => left.number - right.number);
}

function buildBookCreationBrief(payload = {}, longFormPlan) {
  const volumes = Array.isArray(payload.volumes) ? payload.volumes : [];
  const volumeText = volumes.length > 0
    ? volumes.map((v, i) => `- 卷${v.num || i + 1}：${v.title || ''}${v.subtitle ? '·' + v.subtitle : ''}，章节 ${v.start || ''}-${v.end || ''}，目标：${v.summary || v.context || ''}`).join('\n')
    : String(payload.volumePlan || '').trim();
  const constraints = longFormPlan?.constraints;
  const plan = longFormPlan?.plan;
  const specialConstraints = constraints?.specialConstraints || (
    Array.isArray(payload.constraints) ? payload.constraints : [payload.constraints || payload.notes || '']
  );
  const structuredBudget = plan ? [
    '## 结构化长篇预算（权威）',
    `- 精确目标总字数：${constraints.targetTotalWords}`,
    `- 目标章数：${plan.targetChapters}`,
    `- 分卷数：${constraints.volumeCount}`,
    `- 目标单章字数：${constraints.targetChapterWords}`,
    `- 单章字数容差：±${constraints.chapterWordTolerance}%`,
    `- 单章允许范围：${plan.chapterWordRange.min}-${plan.chapterWordRange.max}`,
    '',
    '### 分卷预算',
    ...plan.volumes.map(volume => `- 第${volume.number}卷：第${volume.startChapter}-${volume.endChapter}章，共${volume.chapterCount}章，精确预算${volume.targetWords}字`),
    '',
    '### 逐章预算摘要',
    ...summarizeChapterBudgets(longFormPlan),
    '',
    '完整逐章预算数组已写入 long-form-plan.json；上述结构化预算不可被自由文本大纲覆盖。',
  ] : [];
  return [
    `# ${payload.title || '未命名小说'} 创作简报`,
    '',
    `## 基础信息`,
    `- 书名：${payload.title || ''}`,
    `- 类型：${payload.genre || 'xuanhuan'}`,
    `- 平台：${payload.platform || 'tomato'}`,
    `- 总章数：${plan?.targetChapters || payload.targetChapters || ''}`,
    `- 单章字数：${constraints?.targetChapterWords || payload.chapterWords || ''}`,
    `- 总字数：${constraints?.targetTotalWords || payload.totalWords || ''}`,
    '',
    ...structuredBudget,
    '',
    `## 核心创意`,
    payload.premise || '',
    '',
    `## 主角与主要人物`,
    payload.characters || payload.protagonist || '',
    '',
    `## 世界观与规则`,
    payload.worldbuilding || '',
    '',
    `## 主线大纲`,
    payload.outline || '',
    '',
    `## 分卷规划`,
    volumeText || '',
    '',
    `## 节奏与风格要求`,
    payload.pacing || '',
    payload.style || '',
    '',
    `## 禁忌与特别要求`,
    ...specialConstraints.map(value => String(value || '').trim()).filter(Boolean),
  ].join('\n').trim() + '\n';
}

function parseMaybeJson(text) {
  const raw = String(text || '').trim();
  if (!raw) return {};
  try { return JSON.parse(raw); } catch {}
  const first = raw.indexOf('{');
  const last = raw.lastIndexOf('}');
  if (first >= 0 && last > first) {
    try { return JSON.parse(raw.slice(first, last + 1)); } catch {}
  }
  return { raw };
}

function registerCreatedBookInPublisherState({ bookId, title, payload, briefPath, longFormPlan }) {
  const state = loadState();
  const now = new Date().toISOString();
  if (!state.books[bookId]) {
    state.books[bookId] = {
      title,
      chapters: [],
      createdAt: now,
      updatedAt: now,
      inkos: {
        bookId,
        genre: payload.genre || 'xuanhuan',
        platform: payload.platform || 'tomato',
        language: payload.language === 'en' ? 'en' : 'zh',
        targetChapters: longFormPlan.plan.targetChapters,
        chapterWordCount: longFormPlan.constraints.targetChapterWords,
      },
      creation: {
        success: true,
        briefPath,
        payload,
        longFormPlanRevision: longFormPlan.revision,
      },
    };
  } else {
    const existingBook = state.books[bookId];
    existingBook.title = existingBook.title || title;
    existingBook.inkos = {
      ...(existingBook.inkos || {}),
      bookId,
      genre: payload.genre || existingBook.inkos?.genre || 'xuanhuan',
      platform: payload.platform || existingBook.inkos?.platform || 'tomato',
      language: payload.language === 'en' ? 'en' : 'zh',
      targetChapters: longFormPlan.plan.targetChapters,
      chapterWordCount: longFormPlan.constraints.targetChapterWords,
    };
    existingBook.creation = {
      success: true,
      briefPath,
      payload,
      longFormPlanRevision: longFormPlan.revision,
    };
    existingBook.updatedAt = now;
  }
  saveState(state);
}

async function runCreateBookJob(jobId, payload, briefPath, planTemplate) {
  const job = creationJobs.get(jobId);
  if (!job) return;
  const title = String(payload.title || '').trim();
  let commandStdout = '';
  let commandStderr = '';
  let createdBookId = '';
  let committedLongFormPlan = null;
  const expectedBookId = assertBookId(safeSlug(title));
  try {
    job.status = 'running';
    job.updatedAt = new Date().toISOString();
    persistWorkflowJobs();
    const args = [
      'book', 'create',
      '--title', title,
      '--genre', payload.genre || 'xuanhuan',
      '--platform', payload.platform || 'tomato',
      '--target-chapters', String(planTemplate.plan.targetChapters),
      '--chapter-words', String(planTemplate.constraints.targetChapterWords),
      '--brief', briefPath,
      '--lang', payload.language || 'zh',
      '--json',
    ];
    job.args = args;
    let parsed;
    let frameworkPlan = null;
    if (process.env.PUBLISHER_INKOS_RUNTIME !== 'subprocess') {
      try {
        const bookId = expectedBookId;
        const requestedLongFormPlan = buildLongFormPlan(bookId, planTemplate.constraints, {
          source: 'created',
          createdAt: planTemplate.createdAt,
          now: planTemplate.updatedAt,
        });
        const now = new Date().toISOString();
        const book = {
          id: bookId,
          title,
          platform: payload.platform || 'tomato',
          genre: payload.genre || 'xuanhuan',
          status: 'outlining',
          targetChapters: planTemplate.plan.targetChapters,
          chapterWordCount: planTemplate.constraints.targetChapterWords,
          language: payload.language === 'en' ? 'en' : 'zh',
          createdAt: now,
          updatedAt: now,
        };
        const brief = readFileSync(briefPath, 'utf-8');
        await runPublisherInkOS('book.init', bookId, {
          book,
          initOptions: { externalContext: brief, longFormPlan: requestedLongFormPlan },
          traceId: job.traceId,
          timeoutMs: Number(process.env.PUBLISHER_CREATE_BOOK_TIMEOUT_MS || '900000'),
        });
        frameworkPlan = readLongFormPlan(bookId);
        parsed = { bookId, title: book.title, runtime: 'framework' };
      } catch (error) {
        if (!/内置 InkOS core 未构建|Cannot find module|ERR_MODULE_NOT_FOUND|core 未就绪/i.test(String(error?.message || error))) {
          throw error;
        }
        console.warn(`[book-create] 内置 core 未就绪，回退 CLI：${error.message}`);
      }
    }
    if (!parsed) {
      const storedCfg = getInkosConfig();
      const { stdout, stderr } = await runInkos(args, {
        cwd: PATHS.BOOKS_DIR,
        timeout: Number(process.env.PUBLISHER_CREATE_BOOK_TIMEOUT_MS || '900000'),
        maxBuffer: 20 * 1024 * 1024,
        traceId: job.traceId,
        env: {
          ...(storedCfg.reviewApiKey ? { PUBLISHER_REVIEW_API_KEY: storedCfg.reviewApiKey } : {}),
          ...(job.traceId ? { MACINKOSTOMO_TRACE_ID: job.traceId } : {}),
          INKOS_FRAMEWORK_EVENTS: '1',
        },
      });
      commandStdout = stdout;
      commandStderr = stderr;
      parsed = parseMaybeJson(stdout);
    }
    if (parsed.error) throw new Error(parsed.error);
    const bookId = assertBookId(parsed.bookId || safeSlug(title));
    createdBookId = bookId;
    job.bookId = bookId;
    job.updatedAt = new Date().toISOString();
    persistWorkflowJobs();

    let longFormPlan = frameworkPlan;
    try {
      if (!longFormPlan) {
        const requestedPlan = buildLongFormPlan(bookId, planTemplate.constraints, {
          source: 'created',
          createdAt: planTemplate.createdAt,
        });
        const seededPlan = readLongFormPlan(bookId);
        longFormPlan = writeLongFormPlan(
          bookId,
          seededPlan ? preserveLongFormSeed(requestedPlan, seededPlan) : requestedPlan,
        );
      }
    } catch (err) {
      throw new Error(`InkOS 已创建书籍 ${bookId}，但长篇规划保存失败：${err.message}`, { cause: err });
    }
    committedLongFormPlan = longFormPlan;
    registerCreatedBookInPublisherState({ bookId, title, payload, briefPath, longFormPlan });
    Object.assign(job, {
      status: 'success',
      bookId,
      title,
      stdout: String(commandStdout || '').slice(-4000),
      stderr: String(commandStderr || '').slice(-4000),
      longFormPlanRevision: longFormPlan.revision,
      finishedAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    });
    persistWorkflowJobs();
    console.log(`[book-create] 已创建 ${title} (${bookId})`);
  } catch (err) {
    if (createdBookId && committedLongFormPlan) {
      try {
        registerCreatedBookInPublisherState({
          bookId: createdBookId,
          title,
          payload,
          briefPath,
          longFormPlan: committedLongFormPlan,
        });
        Object.assign(job, {
          status: 'success',
          bookId: createdBookId,
          title,
          warning: `Publisher 状态首次登记失败，重试后已恢复：${err.message}`,
          recoveredStateCommit: true,
          longFormPlanRevision: committedLongFormPlan.revision,
          stdout: String(commandStdout || '').slice(-4000),
          stderr: String(commandStderr || '').slice(-4000),
          finishedAt: new Date().toISOString(),
          updatedAt: new Date().toISOString(),
        });
        persistWorkflowJobs();
        debugEvent('book-create', 'Publisher state commit recovered', {
          initialError: err.message,
          longFormPlanRevision: committedLongFormPlan.revision,
        }, 'warn', {
          traceId: job.traceId,
          operation: 'book.create',
          phase: 'success',
          bookId: createdBookId,
        });
        return;
      } catch (recoveryError) {
        err = new Error(`${err.message}；Publisher 状态重试仍失败：${recoveryError.message}`, { cause: recoveryError });
      }
    }
    const parsed = parseMaybeJson(err.stdout);
    const recoveryBookId = createdBookId || expectedBookId;
    const recovery = creationRecovery(recoveryBookId);
    const recoveryMessage = recovery?.recovery.importable
      ? '；InkOS 产物已保留，可通过“导入现有小说”恢复 Publisher 登记。'
      : recovery
        ? '；InkOS 中间产物已保留，请检查恢复目录后再处理。'
        : '';
    Object.assign(job, {
      status: 'failed',
      error: `${parsed.error || err.message}${recoveryMessage}`,
      bookId: createdBookId || job.bookId || (recovery ? recoveryBookId : undefined),
      ...(recovery || { recoverable: false }),
      stdout: String(err.stdout || commandStdout || '').slice(-4000),
      stderr: String(err.stderr || commandStderr || '').slice(-4000),
      finishedAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    });
    persistWorkflowJobs();
    console.error(`[book-create] 创建失败 ${title}:`, job.error);
  }
}

// Create a new InkOS book inside the bundled project-local workspace: ./book/books/<bookId>.
app.post('/api/books/create', asyncRoute(async (req, res) => {
  const payload = req.body || {};
  const title = String(payload.title || '').trim();
  if (!title) return res.status(400).json({ error: 'title required' });
  const constraints = normalizeLongFormConstraints(payload, {}, { requireSpecialConstraints: true });
  const expectedBookId = assertBookId(safeSlug(title));
  const duplicateJob = Array.from(creationJobs.values()).find(job => (
    !job.finishedAt && (job.expectedBookId === expectedBookId || job.bookId === expectedBookId)
  ));
  if (duplicateJob) {
    return res.status(409).json({ error: '同名小说的创建任务正在运行，请等待当前任务结束。', job: duplicateJob });
  }
  const diskRecovery = creationRecovery(expectedBookId);
  if (diskRecovery) {
    return res.status(409).json({
      error: diskRecovery.recovery.importable
        ? '同名 InkOS 小说目录已存在。为保护现有数据，请改用其他书名，或通过“导入现有小说”恢复 Publisher 登记。'
        : '同名 InkOS 恢复目录已存在。为保护中间产物，请先检查该目录或改用其他书名。',
      bookId: expectedBookId,
      ...diskRecovery,
    });
  }
  const state = loadState();
  if (getBook(state, expectedBookId)) {
    return res.status(409).json({
      error: 'Publisher 中已存在同 ID 小说。为保护现有章节状态，请先处理该小说或改用其他书名。',
      bookId: expectedBookId,
    });
  }
  const planCreatedAt = new Date().toISOString();
  const planTemplate = buildLongFormPlan(expectedBookId, constraints, {
    source: 'created',
    createdAt: planCreatedAt,
    now: planCreatedAt,
  });
  const normalizedPayload = {
    ...payload,
    targetChapters: planTemplate.plan.targetChapters,
    chapterWords: planTemplate.constraints.targetChapterWords,
    totalWords: planTemplate.constraints.targetTotalWords,
    longFormConstraints: planTemplate.constraints,
  };

  ensureLocalInkosProject();
  const briefDir = join(__dirname, 'data', 'create-briefs');
  mkdirSync(briefDir, { recursive: true });
  const briefPath = join(briefDir, `${Date.now()}-${safeSlug(title)}.md`);
  writePrivateFile(briefPath, buildBookCreationBrief(normalizedPayload, planTemplate));

  const jobId = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
  creationJobs.set(jobId, {
    jobId,
    status: 'queued',
    title,
    expectedBookId,
    briefPath,
    longFormConstraints: planTemplate.constraints,
    traceId: req.traceId,
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
  });
  persistWorkflowJobs();
  res.json({
    message: 'InkOS 正在创建小说设定与大纲...',
    status: 'processing',
    jobId,
    title,
    traceId: req.traceId,
    longFormPlan: {
      version: planTemplate.version,
      revision: planTemplate.revision,
      constraints: planTemplate.constraints,
      plan: {
        targetChapters: planTemplate.plan.targetChapters,
        chapterWordRange: planTemplate.plan.chapterWordRange,
      },
    },
  });
  runCreateBookJob(jobId, normalizedPayload, briefPath, planTemplate);
}));

app.post('/api/books/create/assist', asyncRoute(async (req, res) => {
  const startedAt = Date.now();
  try {
    const requirements = String(req.body?.requirements || '').trim();
    if (!requirements) return res.status(400).json({ error: 'requirements required' });
    console.log(`[book-create-assist] 开始生成设定，输入 ${requirements.length} 字`);
    const result = await generateCreateBookPayload(requirements);
    console.log(`[book-create-assist] 生成完成，耗时 ${Math.round((Date.now() - startedAt) / 1000)}s`);
    res.json({ ok: true, ...result });
  } catch (err) {
    console.error(`[book-create-assist] 生成失败，耗时 ${Math.round((Date.now() - startedAt) / 1000)}s:`, err.message);
    res.status(500).json({ error: err.message });
  }
}));

app.get('/api/books/create/:jobId', (req, res) => {
  const job = creationJobs.get(req.params.jobId);
  if (!job) return res.status(404).json({ error: 'creation job not found' });
  res.json(job);
});

function pruneDanglingBookMaps(state) {
  const activeBookIds = new Set(Object.keys(state.books || {}));
  for (const mapName of ['fanqieMap', 'fanqieBookMap']) {
    if (!state[mapName] || typeof state[mapName] !== 'object') continue;
    for (const [k, v] of Object.entries(state[mapName])) {
      if (activeBookIds.has(k) || activeBookIds.has(v)) continue;
      delete state[mapName][k];
    }
  }
}

app.delete('/api/books/:bookId', (req, res) => {
  const { bookId } = req.params;
  const runningJob = activeBookJob(bookId);
  if (runningJob) {
    return res.status(409).json({ error: '该书有生成、修改或审核任务正在运行，任务结束前不能删除。', job: runningJob });
  }
  const state = loadState();
  const book = getBook(state, bookId);
  if (!book) return res.status(404).json({ error: 'Book not found' });
  const stamp = new Date().toISOString().replace(/[-:T.]/g, '').slice(0, 14);
  const trashDir = join(process.env.HOME, '.Trash', `chapter-publisher-book-delete-${stamp}`);
  mkdirSync(trashDir, { recursive: true });
  const bookDir = join(PATHS.BOOKS_SUBDIR, bookId);
  if (existsSync(bookDir)) {
    renameSync(bookDir, join(trashDir, bookId));
  }
  delete state.books[bookId];
  for (const mapName of ['fanqieMap', 'fanqieBookMap']) {
    if (!state[mapName]) continue;
    for (const [k, v] of Object.entries(state[mapName])) {
      if (k === bookId || v === bookId) delete state[mapName][k];
    }
  }
  pruneDanglingBookMaps(state);
  saveState(state);
  res.json({ deleted: bookId, trashedTo: trashDir });
});

// Get chapters list for a book (includes volume info)
app.get('/api/books/:bookId/chapters', (req, res) => {
  const state = loadState();
  const runningJob = activeBookJob(req.params.bookId);
  // 磁盘对账:若 InkOS 的 index.json 有 state.json 未记录的章节(手动生成/崩溃落盘/
  // 上一会话漏 upsert 等),自动同步进来,避免前端漏显示已存在的章节。
  // 长任务运行时 InkOS 可能正在原子替换索引或章节文件。此时只读稳定的
  // Publisher 快照，待任务提交后再对账，避免 GET 把中间产物写回 state.json。
  const book = runningJob ? getBook(state, req.params.bookId) : reconcileWithDisk(state, req.params.bookId);
  if (!book) return res.status(404).json({ error: 'Book not found' });
  let gateChanged = false;
  if (!runningJob) {
    gateChanged = enforceInkosAuditGate(req.params.bookId, book) || gateChanged;
    gateChanged = enforceLlmReviewGate(book) || gateChanged;
  }
  if (gateChanged) saveState(state);

  const stableChapters = runningJob
    ? (book.chapters || []).map(chapter => decorateChapterForClient(req.params.bookId, chapter))
    : listInkosChaptersForClient(req.params.bookId, book);
  const chapters = stableChapters.map(c => {
    return {
    number: c.number,
    title: c.title,
    status: c.status,
    inkosStatus: c.inkosStatus || c.status,
    publisherStatus: c.publisherStatus || null,
    auditIssues: c.auditIssues || [],
    reviewNote: c.reviewNote || '',
    wordCount: c.wordCount,
    publishedAt: c.publishedAt,
    revisionCount: c.revisionHistory?.length || 0,
    updatedAt: c.updatedAt,
    volume: c.volume || null,
    volumeTitle: c.volumeTitle || null,
    llmReview: c.llmReview || null,
  };
  });
  // 附上分卷信息
  const maxNum = chapters.length > 0 ? Math.max(...chapters.map(c => c.number)) : 0;
  const nextChapterNum = maxNum + 1;
  const volumes = getVolumesForBook(req.params.bookId, book);
  const currentVolume = getVolumeForChapter(maxNum > 0 ? maxNum : 1, req.params.bookId, book);
  res.json({
    bookId: req.params.bookId,
    bookTitle: book.title,
    chapters,
    volumes: volumes.map(v => {
      const inVol = chapters.filter(c => c.number >= v.start && c.number <= v.end).length;
      const nextInVol = nextChapterNum >= v.start && nextChapterNum <= v.end;
      return {
        num: v.num, title: v.title, subtitle: v.subtitle,
        start: v.start, end: v.end,
        context: v.context || '',
        targetWords: v.targetWords || null,
        chapterCount: v.chapterCount || (v.end - v.start + 1),
        structured: Boolean(v.structured),
        chaptersInVolume: inVol,
        isCurrent: currentVolume && currentVolume.num === v.num,
        progress: maxNum > 0
          ? Math.min(100, Math.max(0, Math.round((inVol) / (v.end - v.start + 1) * 100)))
          : 0,
      };
    }),
    currentVolume: currentVolume ? { num: currentVolume.num, title: currentVolume.title, subtitle: currentVolume.subtitle, start: currentVolume.start, end: currentVolume.end } : null,
    nextChapterNum,
  });
});

// Get chapter detail with content
app.get('/api/books/:bookId/chapters/:num', (req, res) => {
  const num = parseChapterNum(req.params.num);
  if (!num) return res.status(400).json({ error: 'Invalid chapter number' });
  const state = loadState();
  const runningJob = activeBookJob(req.params.bookId);
  const book = runningJob ? getBook(state, req.params.bookId) : reconcileWithDisk(state, req.params.bookId);
  if (!book) return res.status(404).json({ error: 'Book not found' });

  let gateChanged = false;
  if (!runningJob) {
    gateChanged = enforceInkosAuditGate(req.params.bookId, book) || gateChanged;
    gateChanged = enforceLlmReviewGate(book) || gateChanged;
  }
  if (gateChanged) saveState(state);
  const diskEntry = runningJob ? null : getInkosChapterEntry(req.params.bookId, num);
  const chapter = diskEntry ? mergeInkosChapterForClient(req.params.bookId, book, diskEntry) : getChapter(book, num);
  if (!chapter) return res.status(404).json({ error: 'Chapter not found' });

  res.json(decorateChapterForClient(req.params.bookId, chapter));
});

// Update chapter status. Normal rejection/revision uses POST /revise; this PATCH
// route remains for approval and compatibility with manual content updates.
app.patch('/api/books/:bookId/chapters/:num', asyncRoute(async (req, res) => {
  const num = parseChapterNum(req.params.num);
  if (!num) return res.status(400).json({ error: 'Invalid chapter number' });
  const state = loadState();
  const { bookId } = req.params;
  const book = reconcileWithDisk(state, bookId);
  if (!book) return res.status(404).json({ error: 'Book not found' });

  const chapter = getChapter(book, num);
  if (!chapter) return res.status(404).json({ error: 'Chapter not found' });

  const { status, reviewNotes, content } = req.body;
  const runningJob = activeBookJob(bookId);
  if (runningJob) {
    return res.status(409).json({ error: '该书有生成、修改或审核任务正在运行，请等待任务结束后再审批。', job: runningJob });
  }
  if (content !== undefined) {
    return res.status(400).json({
      error: '章节正文必须通过 InkOS revise / write rewrite / write sync 修改，Publisher 不再直接写 Markdown 或 state.json 正文。',
    });
  }
  if (status !== undefined && status !== STATUS.APPROVED) {
    return res.status(400).json({ error: `不支持的章节状态变更: ${String(status)}` });
  }
  if (status === STATUS.APPROVED) {
    const diskEntry = getInkosChapterEntry(bookId, num);
    if (!diskEntry) {
      return res.status(409).json({ error: 'InkOS 章节索引缺失，不能人工通过。请先重新同步或重新生成。' });
    }
    if (isInkosAuditFailed(diskEntry)) {
      return res.status(409).json({
        error: 'InkOS 自审未通过，不能人工通过。请先打回 InkOS 修改。',
        auditIssues: diskEntry.auditIssues || [],
      });
    }
    if (!isInkosApprovable(diskEntry) && diskEntry.status !== 'approved') {
      return res.status(409).json({ error: `InkOS 状态为 ${diskEntry.status}，不是可人工通过状态。` });
    }
  }
  if (status === STATUS.APPROVED && !isSystemReviewPassed(chapter)) {
    return res.status(409).json({ error: '系统 LLM 初审未通过，不能人工通过。请等待系统自审通过或重新修改。' });
  }

  let approveSync = null;
  if (status === STATUS.APPROVED) {
    try {
      approveSync = await approveInkosChapterIfReviewable(bookId, num);
      if (approveSync.synced) console.log(`[inkos-review] 前端通过后同步 InkOS: ${bookId} 第${num}章`);
    } catch (err) {
      console.warn(`[inkos-review] 前端通过第${num}章后同步 InkOS 失败: ${err.message}`);
      return res.status(500).json({ error: `InkOS approve 失败：${err.message}` });
    }
  }

  if (status) chapter.status = status;
  if (reviewNotes !== undefined) {
    chapter.reviewNotes = reviewNotes;
    // 记录到 revisionHistory（不通过反馈也是一次"修改意见"）
    chapter.revisionHistory = chapter.revisionHistory || [];
    chapter.revisionHistory.push({
      time: new Date().toISOString(),
      note: reviewNotes,
      type: status === 'rejected' ? 'reject' : 'note',
      oldContentLength: (chapter.content || '').length,
    });
  }
  chapter.updatedAt = new Date().toISOString();

  if (status === STATUS.APPROVED) {
    chapter.inkosReviewSync = approveSync || { synced: false, reason: 'already approved' };
  }

  saveState(state);
  const diskEntry = getInkosChapterEntry(bookId, num);
  res.json(diskEntry ? mergeInkosChapterForClient(bookId, book, diskEntry) : chapter);
}));

// Preview knowledge retrieval for a chapter
app.post('/api/books/:bookId/chapters/:num/knowledge', asyncRoute(async (req, res) => {
  const state = loadState();
  const book = getBook(state, req.params.bookId);
  if (!book) return res.status(404).json({ error: 'Book not found' });

  const num = parseChapterNum(req.params.num);
  if (!num) return res.status(400).json({ error: 'Invalid chapter number' });
  const chapter = getChapter(book, num);
  if (!chapter) return res.status(404).json({ error: 'Chapter not found' });

  const { revisionNote, revisionMode } = req.body;
  try {
    const knowledge = await retrieveKnowledge(chapter.content || '', revisionNote || '');
    res.json({ knowledge, hasKnowledge: !!knowledge });
  } catch (err) {
    res.json({ knowledge: null, hasKnowledge: false, error: err.message });
  }
}));

// Submit revision request -> calls InkOS with knowledge injection
app.post('/api/books/:bookId/chapters/:num/revise', asyncRoute(async (req, res) => {
  const state = loadState();
  const book = getBook(state, req.params.bookId);
  if (!book) return res.status(404).json({ error: 'Book not found' });

  const num = parseChapterNum(req.params.num);
  if (!num) return res.status(400).json({ error: 'Invalid chapter number' });
  const chapter = getChapter(book, num);
  if (!chapter) return res.status(404).json({ error: 'Chapter not found' });

  const { revisionNote, revisionMode } = req.body;
  if (!revisionNote) return res.status(400).json({ error: 'revisionNote required' });
  // A human-submitted revision must end with a clear result. Re-running a
  // failed edit behind the same loading state turns one click into several
  // expensive LLM requests and makes the outcome hard to understand.
  const allowAutoRevisionCorrection = process.env.PUBLISHER_REVISE_AUTO_CORRECTION === 'true';

  const activeJob = activeBookJob(req.params.bookId);
  if (activeJob && !activeJob.finishedAt) {
    return res.status(409).json({
      error: `第${num}章已经在修改或审核中，请等待当前流程结束。`,
      job: activeJob,
    });
  }

  // Save old content to revision history
  const oldContent = chapter.content;
  const restoreContent = reReadChapter(req.params.bookId, num) || oldContent;
  chapter.status = STATUS.REVISION_REQUESTED;
  chapter.reviewNotes = revisionNote;
  chapter.revisionHistory = chapter.revisionHistory || [];
  chapter.revisionHistory.push({
    time: new Date().toISOString(),
    note: revisionNote,
    oldContentLength: oldContent.length,
    knowledgeInjected: false, // will update after
  });
  chapter.llmReview = {
    status: 'inkos_revising',
    summary: 'InkOS 正在根据修改意见修订章节',
    reviewedAt: new Date().toISOString(),
    attempts: [],
  };
  chapter.updatedAt = new Date().toISOString();
  saveState(state);
  const queuedAt = new Date().toISOString();
  setGenerationJob(req.params.bookId, num, {
    phase: 'inkos_revising',
    title: chapter.title,
    message: 'InkOS 正在根据反馈修订章节',
    currentStage: 'revision_queued',
    stageStartedAt: queuedAt,
    progress: [{
      stage: 'revision_queued',
      eventKey: 'revision_queued',
      label: '已提交修改请求',
      detail: '正在检索上下文并启动 InkOS 修订流程',
      at: queuedAt,
    }],
  });

  res.json({ message: '修改请求已提交，正在检索知识库并调用 InkOS...', status: 'processing' });
  const recoveryOptions = {
    onSync: () => reportRevisionArtifactSync(req.params.bookId, num),
  };
  let terminalJobPatch = null;

  // Step 1: Retrieve knowledge from OpenClaw
  // Step 2: Call InkOS with enriched context
  try {
    const reviseOptions = generationInkosCallbacks(req.params.bookId, num, 'inkos_revising');
    const result = await reviseChapter(req.params.bookId, num, chapter.title, revisionNote, oldContent, revisionMode, reviseOptions);

    // Reload state (it may have changed during the long InkOS call)
    const freshState = loadState();
    const freshBook = getBook(freshState, req.params.bookId);
    const freshChapter = freshBook ? getChapter(freshBook, num) : null;

    if (!freshChapter) {
      terminalJobPatch = {
        phase: 'error',
        error: 'InkOS 修订结束后无法重新读取章节状态',
      };
      return;
    }

    const lastRev = freshChapter.revisionHistory[freshChapter.revisionHistory.length - 1];

    if (result.success && result.newContent) {
      appendGenerationProgress(req.params.bookId, num, {
        stage: 'revision_validate',
        eventKey: 'revision_validate',
        label: '校验：验收修订正文',
        detail: '检查改动是否完整满足本次修改意见',
      }, { phase: 'inkos_revising' });
      // InkOS succeeded and we re-read the rewritten content.
      let finalResult = result;
      let validationIssues = validateRevisionResult(revisionNote, oldContent, finalResult.newContent, {
        bookId: req.params.bookId,
        chapterNum: num,
      });

      if (allowAutoRevisionCorrection && validationIssues.length > 0 && finalResult.reviseMode !== 'agent') {
        console.warn(`[revise] ${req.params.bookId} 第${num}章 ${finalResult.reviseMode} 未通过验收，升级 agent: ${validationIssues.join('；')}`);
        const shouldRestoreBeforeCorrection = validationIssues.some(issue => /疑似占位|截断/.test(issue));
        let correctiveBaseContent = finalResult.newContent;
        const correctiveContext = [];
        if (shouldRestoreBeforeCorrection) {
          reportRevisionRecovery(req.params.bookId, num, '上一轮改稿疑似截断，正在恢复完整原稿后再继续修订');
          const preCorrectionRestore = await restoreChapterAfterFailedRevision(
            req.params.bookId,
            num,
            restoreContent,
            `上一轮 ${finalResult.reviseMode || 'revise'} 产物过短/疑似截断：${validationIssues.join('；')}`,
            recoveryOptions,
          );
          correctiveBaseContent = restoreContent;
          correctiveContext.push(
            preCorrectionRestore.restored
              ? '上一轮修订产物过短或疑似截断，系统已先恢复修订前完整正文。请基于恢复后的完整正文重新修订，不要基于短版续写。'
              : `上一轮修订产物过短或疑似截断，但恢复修订前正文失败：${preCorrectionRestore.reason || 'unknown'}。仍需输出完整正文。`
          );
        }
        const correctiveNote = [
          revisionNote,
          '',
          `上一轮 ${finalResult.reviseMode || 'revise'} 修订已写回但未通过自动验收：${validationIssues.join('；')}`,
          ...correctiveContext,
          '请基于当前章节继续修订，必须满足这些验收条件后再写回。',
        ].join('\n');
        const correctiveResult = await reviseChapter(req.params.bookId, num, chapter.title, correctiveNote, correctiveBaseContent, 'agent', reviseOptions);
        if (correctiveResult.success && correctiveResult.newContent) {
          finalResult = correctiveResult;
          validationIssues = validateRevisionResult(revisionNote, oldContent, finalResult.newContent, {
            bookId: req.params.bookId,
            chapterNum: num,
          });
        } else {
          validationIssues.push(correctiveResult.error || 'agent 纠偏未产生有效改动');
        }
      }

      if (allowAutoRevisionCorrection && validationIssues.length > 0) {
        const maxValidationRetries = Number(process.env.PUBLISHER_REVISE_VALIDATION_RETRIES || '1');
        const retryResult = await retryRevisionUntilValid(
          req.params.bookId,
          num,
          chapter.title,
          revisionNote,
          oldContent,
          finalResult,
          validationIssues,
          maxValidationRetries,
          reviseOptions,
        );
        finalResult = retryResult.finalResult;
        validationIssues = retryResult.validationIssues;
        if (retryResult.attempts.length > 0) {
          lastRev.validationRetryAttempts = retryResult.attempts;
        }
      }

      const acceptedContent = validationIssues.length > 0 ? restoreContent : finalResult.newContent;
      let restoreResult = null;
      if (validationIssues.length > 0) {
        reportRevisionRecovery(req.params.bookId, num);
        restoreResult = await restoreChapterAfterFailedRevision(
          req.params.bookId,
          num,
          restoreContent,
          validationIssues.join('；'),
          recoveryOptions,
        );
        if (!restoreResult.restored) {
          validationIssues.push(`恢复修订前正文失败：${restoreResult.reason || 'unknown'}`);
        }
      }

      let reviewedContent = acceptedContent;
      let llmReview = null;
      if (validationIssues.length === 0) {
        let inkosEntryBeforeSystemReview = getInkosChapterEntry(req.params.bookId, num);
        // If the only remaining InkOS index failures were injected by the
        // publisher's previous hard-rule validation, and the current content
        // now passes that validation, they are stale. Ask InkOS to resync the
        // chapter artifacts instead of manually editing chapters/index.json.
        if (isInkosAuditFailed(inkosEntryBeforeSystemReview) && isOnlyPublisherStaleAudit(inkosEntryBeforeSystemReview)) {
          reportRevisionArtifactSync(req.params.bookId, num);
          await syncInkosChapterArtifacts(req.params.bookId, num, '清理 Publisher 旧验收标记并重新按 InkOS 规则同步章节产物');
          debugEvent('review_gate', 'cleared_stale_publisher_audit', {
            bookId: req.params.bookId,
            chapterNum: num,
            title: chapter.title,
          });
          inkosEntryBeforeSystemReview = getInkosChapterEntry(req.params.bookId, num);
        }
        if (isInkosAuditFailed(inkosEntryBeforeSystemReview)) {
          llmReview = inkosAuditFailedReview(inkosEntryBeforeSystemReview);
          debugEvent('review_gate', 'skip_system_llm_after_inkos_failed', {
            bookId: req.params.bookId,
            chapterNum: num,
            title: chapter.title,
            issueCount: inkosEntryBeforeSystemReview.auditIssues?.length || 0,
          }, 'warn');
        } else {
          try {
            const reviewResult = await runLlmInitialReviewAndAutoFix(
              req.params.bookId,
              num,
              chapter.title,
              acceptedContent,
              freshBook || book,
              Number(process.env.PUBLISHER_LLM_REVIEW_FIXES || '1'),
            );
            reviewedContent = reviewResult.content || acceptedContent;
            llmReview = {
              status: reviewResult.pass ? 'passed' : 'failed',
              model: reviewResult.review?.model || '',
              summary: reviewResult.review?.summary || '',
              issues: reviewResult.review?.issues || [],
              revisionGuidance: reviewResult.review?.revisionGuidance || '',
              reviewedAt: reviewResult.review?.reviewedAt || new Date().toISOString(),
              autoFixed: Boolean(reviewResult.fixed),
              attempts: reviewResult.reviews || [],
            };
            const inkosEntryAfterSystemReview = getInkosChapterEntry(req.params.bookId, num);
            if (isInkosAuditFailed(inkosEntryAfterSystemReview)) {
              llmReview = inkosAuditFailedReview(inkosEntryAfterSystemReview);
              reviewedContent = reReadChapter(req.params.bookId, num) || reviewedContent;
              debugEvent('review_gate', 'system_llm_fix_left_inkos_failed', {
                bookId: req.params.bookId,
                chapterNum: num,
                title: chapter.title,
                issueCount: inkosEntryAfterSystemReview.auditIssues?.length || 0,
              }, 'warn');
            }
          } catch (reviewErr) {
            llmReview = {
              status: 'error',
              model: '',
              summary: `LLM 初审异常：${reviewErr.message}`,
              issues: [reviewErr.message],
              reviewedAt: new Date().toISOString(),
              attempts: [],
            };
          }
        }
      }

      freshChapter.content = reviewedContent;
      freshChapter.wordCount = wordCount(reviewedContent);
      freshChapter.llmReview = llmReview || freshChapter.llmReview || null;
      freshChapter.status = validationIssues.length > 0 ? STATUS.REVISION_FAILED : STATUS.PENDING_REVIEW;
      if (validationIssues.length === 0 && llmReview?.status === 'passed') {
        reportRevisionArtifactSync(req.params.bookId, num);
        await syncInkosChapterArtifacts(req.params.bookId, num, '系统 LLM 初审通过后，按 InkOS 规则同步章节产物，等待人工 approve');
      }
      lastRev.newContentLength = finalResult.newContent.length;
      lastRev.success = validationIssues.length === 0;
      lastRev.reviseMode = finalResult.reviseMode || 'unknown';
      if (validationIssues.length > 0) {
        lastRev.error = `修订后未通过自动验收：${validationIssues.join('；')}`;
        llmReview = inkosRevisionFailureReview(lastRev.error);
        freshChapter.llmReview = llmReview;
        lastRev.validationIssues = validationIssues;
        lastRev.restoredOnFailure = !!restoreResult?.restored;
        lastRev.restoredContentLength = restoreContent.length;
      }
      lastRev.knowledgeInjected = finalResult.knowledgeInjected > 0;
      lastRev.knowledgeChars = finalResult.knowledgeInjected;
    } else if (result.reReadFailed) {
      // InkOS executed but we could not re-read the rewritten chapter file.
      // Restore disk/state to pre-revision text; surface for manual fix.
      reportRevisionRecovery(req.params.bookId, num, 'InkOS 写回后无法读取正文，正在恢复原稿并同步审核状态');
      const restoreResult = await restoreChapterAfterFailedRevision(req.params.bookId, num, restoreContent, result.error || '重读章节文件失败', recoveryOptions);
      freshChapter.content = restoreContent;
      freshChapter.wordCount = wordCount(restoreContent);
      freshChapter.status = STATUS.REVISION_FAILED;
      lastRev.success = false;
      lastRev.reReadFailed = true;
      lastRev.error = `${result.error || 'InkOS 已执行但重读章节文件失败'}${restoreResult.restored ? '；已恢复修订前正文' : `；恢复修订前正文失败：${restoreResult.reason || 'unknown'}`}`;
      lastRev.reviseMode = result.reviseMode || 'unknown';
      lastRev.restoredOnFailure = !!restoreResult.restored;
      lastRev.restoredContentLength = restoreContent.length;
      lastRev.knowledgeInjected = result.knowledgeInjected > 0;
      lastRev.knowledgeChars = result.knowledgeInjected;
      freshChapter.llmReview = inkosRevisionFailureReview(lastRev.error);
    } else {
      reportRevisionRecovery(req.params.bookId, num, 'InkOS 未产生可接受改稿，正在恢复原稿并同步审核状态');
      const restoreResult = await restoreChapterAfterFailedRevision(req.params.bookId, num, restoreContent, result.error || 'InkOS 未产生有效修订', recoveryOptions);
      freshChapter.content = restoreContent;
      freshChapter.wordCount = wordCount(restoreContent);
      freshChapter.status = STATUS.REVISION_FAILED;
      lastRev.success = false;
      lastRev.error = `${result.error || 'InkOS 未产生有效修订'}${restoreResult.restored ? '；已恢复修订前正文' : `；恢复修订前正文失败：${restoreResult.reason || 'unknown'}`}`;
      lastRev.reviseMode = result.reviseMode || 'unknown';
      lastRev.restoredOnFailure = !!restoreResult.restored;
      lastRev.restoredContentLength = restoreResult.restored ? restoreContent.length : 0;
      lastRev.knowledgeInjected = result.knowledgeInjected > 0;
      lastRev.knowledgeChars = result.knowledgeInjected;
      freshChapter.llmReview = inkosRevisionFailureReview(lastRev.error);
    }
    freshChapter.updatedAt = new Date().toISOString();
    commitBookFromSnapshot(freshState, req.params.bookId, { chapterNumbers: [num] });
    const revisionFailed = lastRev?.success === false;
    const terminalPhase = revisionFailed
      ? 'complete_inkos_failed'
      : freshChapter.llmReview?.status === 'passed' ? 'complete_passed' : 'complete_needs_review';
    if (revisionFailed) {
      appendGenerationProgress(req.params.bookId, num, {
        stage: 'revision_failed',
        eventKey: 'revision_failed',
        label: '修改未通过，已保留原稿',
        detail: lastRev?.error || 'InkOS 未产生可接受的修订正文',
      }, { phase: terminalPhase });
    }
    terminalJobPatch = {
      phase: terminalPhase,
      ...(revisionFailed ? { currentStage: 'revision_failed', message: '修改未通过，已保留原稿' } : {}),
      ...(revisionFailed ? { error: lastRev?.error || 'InkOS 未产生可接受的修订正文' } : {}),
      llmReview: freshChapter.llmReview || null,
    };
  } catch (err) {
    terminalJobPatch = { phase: 'error', error: err.message };
    try {
      const freshState = loadState();
      const freshBook = getBook(freshState, req.params.bookId);
      const freshChapter = freshBook ? getChapter(freshBook, num) : null;
      if (freshChapter) {
        reportRevisionRecovery(req.params.bookId, num, '修订流程异常结束，正在恢复原稿并同步审核状态');
        const restoreResult = await restoreChapterAfterFailedRevision(req.params.bookId, num, restoreContent, err.message, recoveryOptions);
        freshChapter.content = restoreContent;
        freshChapter.wordCount = wordCount(restoreContent);
        freshChapter.status = STATUS.REVISION_FAILED;
        freshChapter.updatedAt = new Date().toISOString();
        const lastRev = freshChapter.revisionHistory[freshChapter.revisionHistory.length - 1];
        if (lastRev) {
          lastRev.success = false;
          lastRev.error = `${err.message}${restoreResult.restored ? '；已恢复修订前正文' : `；恢复修订前正文失败：${restoreResult.reason || 'unknown'}`}`;
          lastRev.restoredOnFailure = !!restoreResult.restored;
          lastRev.restoredContentLength = restoreContent.length;
        }
        freshChapter.llmReview = inkosRevisionFailureReview(lastRev?.error || err.message);
        terminalJobPatch.error = lastRev?.error || err.message;
        terminalJobPatch.llmReview = freshChapter.llmReview;
        commitBookFromSnapshot(freshState, req.params.bookId, { chapterNumbers: [num] });
      }
    } catch (recoveryErr) {
      terminalJobPatch.error = `${err.message}；异常恢复失败：${recoveryErr.message}`;
      console.error(`[revise] ${req.params.bookId} 第${num}章异常恢复失败:`, recoveryErr);
    }
  } finally {
    const currentJob = generationJobs.get(generationKey(req.params.bookId, num));
    if (!currentJob?.finishedAt) {
      try {
        finishGenerationJob(req.params.bookId, num, terminalJobPatch || {
          phase: 'error',
          error: '修订流程异常结束，未记录终态',
        });
      } catch (finishErr) {
        console.error(`[revise] ${req.params.bookId} 第${num}章任务终态保存失败:`, finishErr);
      }
    }
  }
}));

const REWRITE_BACKUP_DIR = join(__dirname, 'data', 'rewrite-backups');

function backupBookBeforeRewrite(bookId, chapterNum) {
  const timestamp = Date.now();
  const source = bookPath(bookId);
  if (!existsSync(source)) throw new Error(`书籍目录不存在: ${source}`);
  const destination = join(REWRITE_BACKUP_DIR, assertBookId(bookId), `${timestamp}-chapter-${chapterNum}`);
  const files = [];
  copyDirectoryStrict(source, destination, files);
  if (files.length === 0) throw new Error('书籍目录为空，未生成有效备份');
  return { backupDir: destination, fileCount: files.length, timestamp };
}

function restoreBookAfterFailedRewrite(bookId, backupDir) {
  return replaceDirectoryFromBackup(bookPath(bookId), backupDir, 'rewrite-restore', { requireFiles: true });
}

// InkOS 重构本章（write rewrite）→ 写入 state 为 pending_review。
// 长任务，跟随 /revise 的"立即返回+异步"模式：先返回 processing，完成后状态写入。
app.post('/api/books/:bookId/chapters/:num/rewrite', asyncRoute(async (req, res) => {
  const state = loadState();
  const book = getBook(state, req.params.bookId);
  if (!book) return res.status(404).json({ error: 'Book not found' });

  const num = parseChapterNum(req.params.num);
  if (!num) return res.status(400).json({ error: 'Invalid chapter number' });
  const chapter = getChapter(book, num);
  if (!chapter) return res.status(404).json({ error: 'Chapter not found' });

  const activeJob = activeBookJob(req.params.bookId);
  if (activeJob) {
    return res.status(409).json({
      error: `该书已有第${activeJob.chapterNum}章生成、修改或审核任务，请等待当前流程结束。`,
      job: activeJob,
    });
  }

  // 前置校验1：rewrite 只允许用于末章。InkOS write rewrite <N> 是破坏性的——
  // 它会删除 N 之后所有章节文件 + 截断 index.json + 清 memory.db（这是 InkOS
  // 设计行为，级联更新下游是官方 roadmap 未实现项）。对非末章 rewrite 必然
  // 撕裂下游且本端 state.json 会残留幽灵章节。要改中间章请用 revise（局部
  // 修改）或接受下游全删后用 write next 重生成。
  let diskIndex;
  try {
    diskIndex = readChapterIndex(req.params.bookId, { strict: true });
  } catch (err) {
    return res.status(503).json({ error: err.message });
  }
  const diskChapter = diskIndex.find(c => c.number === num);
  if (!diskChapter) {
    return res.status(409).json({ error: `InkOS 索引中不存在第${num}章，不能执行破坏性重构。` });
  }
  const isLastChapter = !diskIndex.some(c => c.number > num);
  if (!isLastChapter) {
    return res.status(409).json({
      error: `第${num}章不是末章，无法重构。InkOS write rewrite 会删除其后所有章节（这是 InkOS 的设计行为，不可绕过）。要修改本章请用"打回修改"(revise 局部修改)；若确需整章重构，请从最后一章开始，或接受下游章节被删后用"生成新章节"重新续写。`,
    });
  }

  // 前置校验2：InkOS rewrite <N> 需 story/snapshots/<N-1>/ 存在（从该快照恢复
  // 状态）。缺失时 InkOS 立即失败，但本端此时已写了 revision_requested——
  // 所以提前检查，缺失就直接拒绝，不污染 state。
  if (num > 1 && !snapshotExistsFor(req.params.bookId, num - 1)) {
    return res.status(409).json({
      error: `无法重构第${num}章：缺少第${num - 1}章的 InkOS 快照（story/snapshots/${num - 1}/）。write rewrite 需从前章快照恢复状态。请先用"生成新章节"补齐到第${num - 1}章后再重构。`,
    });
  }

  const { brief } = req.body || {};
  let rewriteBackup;
  try {
    rewriteBackup = backupBookBeforeRewrite(req.params.bookId, num);
  } catch (err) {
    return res.status(500).json({ error: `创建重构前备份失败，已停止重构: ${err.message}` });
  }

  // Save old content to revision history
  const oldContent = chapter.content;
  chapter.status = STATUS.REVISION_REQUESTED;
  chapter.llmReview = {
    status: 'inkos_revising',
    summary: 'InkOS 正在整章重构',
    reviewedAt: new Date().toISOString(),
    attempts: [],
  };
  chapter.reviewNotes = brief || 'InkOS 整章重构';
  chapter.revisionHistory = chapter.revisionHistory || [];
  chapter.revisionHistory.push({
    time: new Date().toISOString(),
    note: `[重构] ${brief || 'InkOS 整章重构'}`,
    oldContentLength: oldContent.length,
    knowledgeInjected: false,
    backupDir: rewriteBackup.backupDir,
    backupFileCount: rewriteBackup.fileCount,
  });
  chapter.updatedAt = new Date().toISOString();
  saveState(state);
  setGenerationJob(req.params.bookId, num, { phase: 'inkos_revising', title: chapter.title, message: 'InkOS write rewrite running' });

  res.json({ message: 'InkOS 正在重构本章（检索知识库 + write rewrite）...', status: 'processing' });

  let terminalJobPatch = null;
  let removedChapterNumbers = [];
  let rewriteRestored = false;
  try {
    // 取相邻章正文作为硬约束锚点（从 state.json，不依赖 InkOS chapters/ 目录
    // ——后者可能被前次 rewrite 破坏）。前章末段 / 后章首段，各截 ~600 字。
    const prevCh = num > 1 ? getChapter(book, num - 1) : null;
    const nextCh = getChapter(book, num + 1);
    const prevTail = prevCh && prevCh.content ? prevCh.content.slice(-600) : null;
    const nextHead = nextCh && nextCh.content ? nextCh.content.slice(0, 600) : null;

    const result = await rewriteChapter(req.params.bookId, num, chapter.title, brief, oldContent, prevTail, nextHead);

    const freshState = loadState();
    const freshBook = getBook(freshState, req.params.bookId);
    const freshChapter = freshBook ? getChapter(freshBook, num) : null;
    if (!freshChapter) {
      terminalJobPatch = { phase: 'error', error: '重构结束后书籍或章节状态不存在' };
      return;
    }

    const lastRev = freshChapter.revisionHistory[freshChapter.revisionHistory.length - 1];

    if (result.success && result.newContent) {
      let reviewedContent = result.newContent;
      let llmReview = null;
      let inkosEntryBeforeSystemReview = getInkosChapterEntry(req.params.bookId, num);
      if (isInkosAuditFailed(inkosEntryBeforeSystemReview) && isOnlyPublisherStaleAudit(inkosEntryBeforeSystemReview)) {
        await syncInkosChapterArtifacts(req.params.bookId, num, '清理 Publisher 旧验收标记并重新按 InkOS 规则同步重构章节产物');
        debugEvent('review_gate', 'cleared_stale_publisher_audit', {
          bookId: req.params.bookId,
          chapterNum: num,
          title: chapter.title,
        });
        inkosEntryBeforeSystemReview = getInkosChapterEntry(req.params.bookId, num);
      }
      if (isInkosAuditFailed(inkosEntryBeforeSystemReview)) {
        llmReview = inkosAuditFailedReview(inkosEntryBeforeSystemReview);
        debugEvent('review_gate', 'skip_system_llm_after_inkos_failed', {
          bookId: req.params.bookId,
          chapterNum: num,
          title: chapter.title,
          issueCount: inkosEntryBeforeSystemReview.auditIssues?.length || 0,
        }, 'warn');
      } else {
        try {
          const reviewResult = await runLlmInitialReviewAndAutoFix(
            req.params.bookId,
            num,
            chapter.title,
            result.newContent,
            freshBook || book,
            Number(process.env.PUBLISHER_LLM_REVIEW_FIXES || '1'),
          );
          reviewedContent = reviewResult.content || result.newContent;
          llmReview = {
            status: reviewResult.pass ? 'passed' : 'failed',
            model: reviewResult.review?.model || '',
            summary: reviewResult.review?.summary || '',
            issues: reviewResult.review?.issues || [],
            revisionGuidance: reviewResult.review?.revisionGuidance || '',
            reviewedAt: reviewResult.review?.reviewedAt || new Date().toISOString(),
            autoFixed: Boolean(reviewResult.fixed),
            attempts: reviewResult.reviews || [],
          };
          const inkosEntryAfterSystemReview = getInkosChapterEntry(req.params.bookId, num);
          if (isInkosAuditFailed(inkosEntryAfterSystemReview)) {
            llmReview = inkosAuditFailedReview(inkosEntryAfterSystemReview);
            reviewedContent = reReadChapter(req.params.bookId, num) || reviewedContent;
            debugEvent('review_gate', 'system_llm_fix_left_inkos_failed', {
              bookId: req.params.bookId,
              chapterNum: num,
              title: chapter.title,
              issueCount: inkosEntryAfterSystemReview.auditIssues?.length || 0,
            }, 'warn');
          }
        } catch (reviewErr) {
          llmReview = {
            status: 'error',
            model: '',
            summary: `LLM 初审异常：${reviewErr.message}`,
            issues: [reviewErr.message],
            reviewedAt: new Date().toISOString(),
            attempts: [],
          };
        }
      }
      freshChapter.content = reviewedContent;
      freshChapter.wordCount = wordCount(reviewedContent);
      freshChapter.llmReview = llmReview;
      freshChapter.status = llmReview?.status === 'passed' ? STATUS.PENDING_REVIEW : STATUS.REVISION_FAILED;
      lastRev.newContentLength = reviewedContent.length;
      lastRev.success = llmReview?.status === 'passed';
      lastRev.llmReview = llmReview;
      lastRev.knowledgeInjected = result.knowledgeInjected > 0;
      lastRev.knowledgeChars = result.knowledgeInjected;
    } else if (result.reReadFailed) {
      const restored = restoreBookAfterFailedRewrite(req.params.bookId, rewriteBackup.backupDir);
      rewriteRestored = true;
      const failureMessage = `${result.error || 'InkOS 重构后无法重读正文'}；已从重构前备份恢复 ${restored.restoredCount} 个文件${restored.cleanupWarning ? `；${restored.cleanupWarning}` : ''}`;
      freshChapter.content = oldContent;
      freshChapter.wordCount = wordCount(oldContent);
      freshChapter.status = STATUS.REVISION_FAILED;
      lastRev.success = false;
      lastRev.reReadFailed = true;
      lastRev.error = failureMessage;
      lastRev.restoredOnFailure = true;
      lastRev.knowledgeInjected = result.knowledgeInjected > 0;
      lastRev.knowledgeChars = result.knowledgeInjected;
      freshChapter.llmReview = inkosRevisionFailureReview(failureMessage);
      freshChapter.reviewNotes = failureMessage;
    } else {
      const restored = restoreBookAfterFailedRewrite(req.params.bookId, rewriteBackup.backupDir);
      rewriteRestored = true;
      const failureMessage = `${result.error || 'InkOS 重构失败'}；已从重构前备份恢复 ${restored.restoredCount} 个文件${restored.cleanupWarning ? `；${restored.cleanupWarning}` : ''}`;
      freshChapter.content = oldContent;
      freshChapter.wordCount = wordCount(oldContent);
      freshChapter.status = STATUS.REVISION_FAILED;
      lastRev.success = false;
      lastRev.error = failureMessage;
      lastRev.restoredOnFailure = true;
      lastRev.knowledgeInjected = result.knowledgeInjected > 0;
      lastRev.knowledgeChars = result.knowledgeInjected;
      freshChapter.llmReview = inkosRevisionFailureReview(failureMessage);
      freshChapter.reviewNotes = failureMessage;
    }
    // 对账：InkOS rewrite 截断 chapters/index.json（保留 number<=N + 新N）。
    // 读 InkOS 真实 index.json，清除本端 state.json 里 InkOS 已不持有的下游
    // 幽灵章节（防御性——末章 rewrite 理论无下游，但防状态漂移）。
    if (result.success) {
      const inkosIndex = readChapterIndex(req.params.bookId, { strict: true });
      if (inkosIndex.length > 0) {
        const inkosNums = new Set(inkosIndex.map(c => c.number));
        const previousNumbers = freshBook.chapters.map(c => c.number);
        const before = freshBook.chapters.length;
        freshBook.chapters = freshBook.chapters.filter(c => inkosNums.has(c.number));
        removedChapterNumbers = previousNumbers.filter(chapterNum => !inkosNums.has(chapterNum));
        const removed = before - freshBook.chapters.length;
        if (removed > 0) console.log(`[rewrite] 对账：清除 ${removed} 个 InkOS 已删的幽灵章节`);
      }
    }
    freshChapter.updatedAt = new Date().toISOString();
    commitBookFromSnapshot(freshState, req.params.bookId, {
      chapterNumbers: [num],
      removeChapterNumbers: removedChapterNumbers,
    });
    terminalJobPatch = {
      phase: rewriteRestored
        ? 'complete_inkos_failed'
        : freshChapter.status === STATUS.PENDING_REVIEW ? 'complete_passed' : 'complete_needs_review',
      ...(rewriteRestored ? { error: lastRev?.error || 'InkOS 重构失败，已恢复原稿' } : {}),
      llmReview: freshChapter.llmReview || null,
    };
  } catch (err) {
    let restoreError = '';
    try {
      const restored = restoreBookAfterFailedRewrite(req.params.bookId, rewriteBackup.backupDir);
      restoreError = `；已从重构前备份恢复 ${restored.restoredCount} 个文件${restored.cleanupWarning ? `；${restored.cleanupWarning}` : ''}`;
    } catch (restoreErr) {
      restoreError = `；自动恢复失败: ${restoreErr.message}`;
    }
    const failureMessage = `${err.message}${restoreError}`;
    terminalJobPatch = { phase: 'error', error: failureMessage };
    try {
      const freshState = loadState();
      const freshBook = getBook(freshState, req.params.bookId);
      const freshChapter = freshBook ? getChapter(freshBook, num) : null;
      if (freshChapter) {
        freshChapter.content = oldContent;
        freshChapter.wordCount = wordCount(oldContent);
        freshChapter.status = STATUS.REVISION_FAILED;
        freshChapter.updatedAt = new Date().toISOString();
        const lastRev = freshChapter.revisionHistory[freshChapter.revisionHistory.length - 1];
        if (lastRev) {
          lastRev.success = false;
          lastRev.error = failureMessage;
          lastRev.restoredOnFailure = !restoreError.includes('自动恢复失败');
        }
        freshChapter.llmReview = inkosRevisionFailureReview(failureMessage);
        freshChapter.reviewNotes = failureMessage;
        terminalJobPatch.llmReview = freshChapter.llmReview;
        commitBookFromSnapshot(freshState, req.params.bookId, { chapterNumbers: [num] });
      }
    } catch (recoveryErr) {
      terminalJobPatch.error = `${failureMessage}；状态恢复失败：${recoveryErr.message}`;
      console.error(`[rewrite] ${req.params.bookId} 第${num}章状态恢复失败:`, recoveryErr);
    }
  } finally {
    const currentJob = generationJobs.get(generationKey(req.params.bookId, num));
    if (!currentJob?.finishedAt) {
      try {
        finishGenerationJob(req.params.bookId, num, terminalJobPatch || {
          phase: 'error',
          error: '重构流程异常结束，未记录终态',
        });
      } catch (finishErr) {
        console.error(`[rewrite] ${req.params.bookId} 第${num}章任务终态保存失败:`, finishErr);
      }
    }
  }
}));

// Get revision history / diff
app.get('/api/books/:bookId/chapters/:num/diff', (req, res) => {
  const state = loadState();
  const book = getBook(state, req.params.bookId);
  if (!book) return res.status(404).json({ error: 'Book not found' });

  const num = parseChapterNum(req.params.num);
  if (!num) return res.status(400).json({ error: 'Invalid chapter number' });
  const chapter = getChapter(book, num);
  if (!chapter) return res.status(404).json({ error: 'Chapter not found' });

  res.json({
    currentContent: chapter.content,
    revisionHistory: chapter.revisionHistory || [],
    reviewNotes: chapter.reviewNotes,
  });
});

// ============ 分卷管理 ============
// InkOS is authoritative. Publisher reads story/outline/volume_map.md and only
// derives display/guidance from that file; no book-specific volume map should
// be hardcoded here.
const CN_NUM = {
  一: 1, 二: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9, 十: 10,
  十一: 11, 十二: 12, 十三: 13, 十四: 14, 十五: 15, 十六: 16, 十七: 17, 十八: 18, 十九: 19, 二十: 20,
};

function parseVolumeNum(raw, fallback) {
  const s = String(raw || '').trim();
  if (/^\d+$/.test(s)) return Number(s);
  return CN_NUM[s] || fallback;
}

function getLegacyVolumesForBook(bookId) {
  const file = join(PATHS.BOOKS_SUBDIR, bookId, 'story', 'outline', 'volume_map.md');
  if (!existsSync(file)) return [];
  const text = readFileSync(file, 'utf-8');
  const volumes = [];
  const seen = new Set();
  const patterns = [
    /第([一二三四五六七八九十\d]+)卷[“"《]?([^”"》\n（(]{1,40})[”"》]?[\s\S]{0,24}?[（(]第\s*(\d+)\s*[-—~到至]\s*(\d+)\s*章[）)]([^。\n]{0,80})/g,
    /\*\*第([一二三四五六七八九十\d]+)卷[:：]?([^（\n*]{1,40})[（(]第\s*(\d+)\s*[-—~到至]\s*(\d+)\s*章[）)]\*\*/g,
  ];
  for (const pattern of patterns) {
    let m;
    while ((m = pattern.exec(text))) {
      const start = Number(m[3]);
      const end = Number(m[4]);
      if (!Number.isFinite(start) || !Number.isFinite(end)) continue;
      const key = `${start}-${end}`;
      if (seen.has(key)) continue;
      seen.add(key);
      const num = parseVolumeNum(m[1], volumes.length + 1);
      const title = String(m[2] || `第${num}卷`).trim().replace(/[：:，,。]+$/g, '');
      const tail = String(m[5] || '').trim();
      const theme = tail.match(/主题是?[“"]?([^”"，,。]+)[”"]?/)?.[1] || '';
      volumes.push({
        num,
        title,
        subtitle: theme,
        start,
        end,
        context: `${title}${theme ? `，主题“${theme}”` : ''}，章节 ${start}-${end}。${tail}`.trim(),
      });
    }
  }
  return volumes.sort((a, b) => a.start - b.start);
}

function getVolumesForBook(bookId, legacyBook = null) {
  const legacyVolumes = getLegacyVolumesForBook(bookId);
  // Ordinary chapter reads are intentionally side-effect free. A missing plan
  // stays on the Markdown legacy fallback; GET /long-form-plan or generation
  // performs the explicit migration and atomic write.
  const plan = readLongFormPlan(bookId);
  if (!plan) return legacyVolumes;
  const structuredByNumber = new Map(legacyVolumes.map(volume => [volume.num, volume]));
  return plan.plan.volumes.map(volume => {
    const legacy = structuredByNumber.get(volume.number) || {};
    return {
      num: volume.number,
      title: legacy.title || `第${volume.number}卷`,
      subtitle: legacy.subtitle || '',
      start: volume.startChapter,
      end: volume.endChapter,
      context: legacy.context || `结构化预算：${volume.targetWords}字，共${volume.chapterCount}章。`,
      targetWords: volume.targetWords,
      chapterCount: volume.chapterCount,
      structured: true,
    };
  });
}

function getVolumeForChapter(chapterNum, bookId = null, legacyBook = null) {
  const volumes = bookId ? getVolumesForBook(bookId, legacyBook) : [];
  return volumes.find(v => chapterNum >= v.start && chapterNum <= v.end) || null;
}

/**
 * Keep publisher state aligned with InkOS disk state.
 *
 * Disk can be ahead of state when a manual `inkos write next` succeeds but the
 * publisher process crashes before upsert. State can also be ahead of disk when
 * a destructive InkOS rewrite is interrupted/deletes the target chapter before
 * the publisher records the final result. Because InkOS is authoritative for
 * chapter generation/revision, active non-approved publisher chapters that are
 * missing from InkOS index.json are ghosts and must not block/drive the next
 * generation.
 *
 * Rules:
 *   - append disk chapters missing from state as pending_review;
 *   - prune state-only chapters when they are not approved/published;
 *   - keep approved/published state-only chapters visible and log loudly, since
 *     silently dropping shipped history is riskier than surfacing drift.
 */
function reconcileWithDisk(state, bookId) {
  const book = getBook(state, bookId);
  if (!book) return null;

  const indexPath = join(PATHS.BOOKS_SUBDIR, bookId, 'chapters', 'index.json');
  const hasIndex = existsSync(indexPath);
  let diskIndex;
  try {
    diskIndex = readChapterIndex(bookId, { strict: true });
  } catch (err) {
    err.statusCode = 503;
    debugEvent('reconcile', 'invalid_inkos_index', { bookId, error: err.message }, 'error');
    throw err;
  }
  let changed = false;

  // Only prune when index.json exists and parsed to an array. If the whole
  // InkOS index is temporarily unreadable/missing, avoid mass-deleting state.
  if (hasIndex && Array.isArray(diskIndex)) {
    const diskNums = new Set(diskIndex.map(c => c.number).filter(Boolean));
    const pruned = [];
    book.chapters = book.chapters.filter(ch => {
      if (diskNums.has(ch.number)) return true;
      if (ch.status === STATUS.APPROVED || ch.status === STATUS.PUBLISHED) {
        console.warn(`[reconcile] 第${ch.number}章在 state.json 为 ${ch.status}，但 InkOS index 缺失；保留并等待人工处理`);
        debugEvent('reconcile', 'approved_or_published_missing_on_disk', {
          bookId,
          chapterNum: ch.number,
          status: ch.status,
          title: ch.title,
        }, 'warn');
        return true;
      }
      pruned.push({
        number: ch.number,
        title: ch.title,
        status: ch.status,
        llmReviewStatus: ch.llmReview?.status || null,
      });
      return false;
    });
    if (pruned.length > 0) {
      changed = true;
      console.warn(`[reconcile] 已清理 ${pruned.length} 个 InkOS 磁盘不存在的未发布章节: ${pruned.map(c => `第${c.number}章`).join('、')}`);
      debugEvent('reconcile', 'pruned_state_only_chapters', { bookId, pruned }, 'warn');
    }
  }

  const haveNums = new Set(book.chapters.map(c => c.number));
  for (const entry of diskIndex) {
    const existing = getChapter(book, entry.number);
    if (!existing) continue;
    const before = existing.status;
    const diskContent = reReadChapter(bookId, entry.number);
    if (diskContent !== null && diskContent !== existing.content) {
      existing.content = diskContent;
      existing.wordCount = wordCount(diskContent);
      if (!isInkosCommitted(entry)) existing.llmReview = null;
      existing.updatedAt = entry.updatedAt || new Date().toISOString();
      changed = true;
      debugEvent('reconcile', 'refreshed_chapter_content_from_inkos', {
        bookId,
        chapterNum: entry.number,
        wordCount: existing.wordCount,
      });
    }
    if (entry.title && entry.title !== existing.title) {
      existing.title = entry.title;
      existing.updatedAt = entry.updatedAt || new Date().toISOString();
      changed = true;
    }
    applyInkosReviewStateToPublisherChapter(existing, entry);
    if (existing.status !== before) {
      existing.updatedAt = new Date().toISOString();
      changed = true;
      debugEvent('reconcile', 'synced_existing_chapter_status_from_inkos', {
        bookId,
        chapterNum: entry.number,
        from: before,
        to: existing.status,
        inkosStatus: entry.status,
      });
    }
  }

  const missing = diskIndex.filter(c => c.number && !haveNums.has(c.number));
  for (const entry of missing) {
    const content = reReadChapter(bookId, entry.number);
    if (content === null) {
      console.warn(`[reconcile] 第${entry.number}章在 index.json 但文件读不到,跳过`);
      continue;
    }
    upsertChapterInMemory(state, bookId, {
      number: entry.number,
      title: entry.title || '',
      content,
      bookTitle: book.title,
    });
    // 标注分卷（与 /generate 一致）
    const v = getVolumeForChapter(entry.number, bookId, book);
    const ch = getChapter(getBook(state, bookId), entry.number);
    if (ch && v) {
      ch.volume = v.num;
      ch.volumeTitle = `${v.title}·${v.subtitle}`;
    }
    applyInkosReviewStateToPublisherChapter(ch, entry);
    changed = true;
    console.log(`[reconcile] 同步磁盘第${entry.number}章「${entry.title || ''}」→ state.json (pending_review)`);
    debugEvent('reconcile', 'imported_disk_chapter', { bookId, chapterNum: entry.number, title: entry.title || '' });
  }

  if (changed) saveState(state);
  return getBook(state, bookId);
}


async function runLlmInitialReviewAndAutoFix(bookId, num, title, content, book, maxFixes = 1) {
  let currentContent = content || '';
  const reviews = [];
  for (let attempt = 0; attempt <= maxFixes; attempt += 1) {
    setGenerationJob(bookId, num, { phase: 'llm_reviewing', attempt: attempt + 1, attempts: reviews });
    const review = await reviewGeneratedChapter({ bookId, chapterNum: num, title, content: currentContent });
    reviews.push({ ...review, attempt: attempt + 1 });
    setGenerationJob(bookId, num, { phase: 'llm_reviewing', attempt: attempt + 1, reviewModel: review.model, attempts: reviews });
    if (review.pass) {
      return { pass: true, content: currentContent, review, reviews, fixed: attempt > 0 };
    }
    if (attempt >= maxFixes) {
      return { pass: false, content: currentContent, review, reviews, fixed: attempt > 0 };
    }
    const prevCh = num > 1 ? getChapter(book, num - 1) : null;
    const prevTail = prevCh?.content ? prevCh.content.slice(-1200) : null;
    const guidance = [
      'LLM 初审未通过，请按以下意见重写本章。重写后必须输出完整章节正文，不要输出说明。',
      `初审结论：${review.summary || '未通过'}`,
      review.issues?.length ? `问题：\n${review.issues.map((x, i) => `${i + 1}. ${x}`).join('\n')}` : '',
      review.revisionGuidance ? `修改意见：\n${review.revisionGuidance}` : '',
    ].filter(Boolean).join('\n\n');
    console.log(`[llm-review] 第${num}章初审未通过，调用 InkOS revise 自动修改: ${review.summary || review.issues?.join('；') || 'no summary'}`);
    setGenerationJob(bookId, num, { phase: 'llm_fixing', review, attempts: reviews });
    const fix = await reviseChapter(
      bookId,
      num,
      title,
      guidance,
      currentContent,
      'agent',
      generationInkosCallbacks(bookId, num, 'llm_fixing'),
    );
    if (!fix.success || !fix.newContent) {
      return {
        pass: false,
        content: currentContent,
        review: { ...review, rewriteError: fix.error || 'InkOS revise 未返回正文' },
        reviews,
        fixed: attempt > 0,
      };
    }
    currentContent = fix.newContent;
  }
  return { pass: false, content: currentContent, review: reviews[reviews.length - 1] || null, reviews, fixed: false };
}

// 生成新章节（inkos write next）→ 写入 state 为 pending_review。
// 自动注入分卷上下文：卷首章注入新卷主题+道藏解锁提示，卷尾章提示收束。
app.post('/api/books/:bookId/generate', asyncRoute(async (req, res) => {
  try {
    const { bookId } = req.params;
    const state = loadState();
    const book = getBook(state, bookId);
    if (!book) return res.status(404).json({ error: 'Book not found' });

    const { guidance } = req.body || {};
    const runningJob = activeBookJob(bookId);
    if (runningJob) {
      return res.status(409).json({
        error: `该书已有第${runningJob.chapterNum}章生成、修改或审核任务，请等待当前流程结束。`,
        job: runningJob,
      });
    }

    const bookLanguage = resolveBookLanguage(bookId, book);
    const longFormPlan = loadOrMigrateLongFormPlan(bookId, { legacyBook: book });

    let diskIndex;
    try {
      diskIndex = readChapterIndex(bookId, { strict: true });
    } catch (err) {
      return res.status(503).json({ error: err.message });
    }
    if (diskIndex.length === 0 && book.chapters.length > 0) {
      return res.status(503).json({ error: 'InkOS 章节索引缺失，但 Publisher 仍有章节记录；为避免覆盖现有章节，已停止生成。' });
    }

    await syncApprovedChaptersToInkos(bookId, book);
    diskIndex = readChapterIndex(bookId, { strict: true });
    const blockingChapter = diskIndex.find(ch => !isInkosCommitted(ch));
    if (blockingChapter) {
      return res.status(409).json({
        error: `第${blockingChapter.number}章 InkOS 状态为 ${blockingChapter.status}，不能继续生成新章节。请先完成 InkOS 自审、系统 LLM 初审和人工通过。`,
      });
    }

    // 计算下一个章节号并确定分卷上下文
    const maxNum = diskIndex.length > 0
      ? Math.max(...diskIndex.map(c => c.number).filter(Boolean))
      : (book.chapters.length > 0 ? Math.max(...book.chapters.map(c => c.number)) : 0);
    const nextNum = maxNum + 1;
    if (nextNum > longFormPlan.plan.targetChapters) {
      return res.status(409).json({
        error: `全书规划共 ${longFormPlan.plan.targetChapters} 章，已到达结构化长篇规划上限。请先更新长篇规划。`,
        targetChapters: longFormPlan.plan.targetChapters,
        revision: longFormPlan.revision,
      });
    }
    const chapterBudget = longFormPlan.plan.chapters[nextNum - 1];
    const writtenMetrics = collectWrittenChapterMetrics(bookId, book, diskIndex);
    let adaptiveBudget;
    try {
      adaptiveBudget = resolveAdaptiveChapterBudget(longFormPlan, nextNum, writtenMetrics);
    } catch (err) {
      return res.status(err?.statusCode || 409).json({ error: err.message });
    }
    const structuredGuidance = renderLongFormChapterContext(longFormPlan, nextNum, {
      targetWords: adaptiveBudget.targetWords,
      minWords: adaptiveBudget.minWords,
      maxWords: adaptiveBudget.maxWords,
    });
    const vol = getVolumeForChapter(nextNum, bookId, book);
    const queuedAt = new Date().toISOString();
    setGenerationJob(bookId, nextNum, {
      phase: 'inkos_writing',
      title: '',
      currentStage: 'queued',
      stageStartedAt: queuedAt,
      message: '已提交生成请求',
      liveText: '',
      liveTextTruncated: false,
      longFormPlanRevision: longFormPlan.revision,
      targetWords: adaptiveBudget.targetWords,
      plannedTargetWords: chapterBudget.targetWords,
      adaptiveBudget,
      wordRange: { min: adaptiveBudget.minWords, max: adaptiveBudget.maxWords },
      traceId: req.traceId,
      progress: [{
        stage: 'queued',
        eventKey: 'queued',
        label: '已提交生成请求',
        detail: '正在启动 InkOS 写作流程',
        at: queuedAt,
      }],
    });

    // 构建分卷感知的 guidance。结构化计划提供权威边界，旧版
    // volume_map.md 只补充卷名和语义说明。
    let volumeGuidance = '';
    if (vol) {
      const volumeName = `${vol.title}${vol.subtitle ? '·' + vol.subtitle : ''}`;
      const progress = Math.max(0, Math.min(100, Math.round((nextNum - vol.start + 1) / (vol.end - vol.start + 1) * 100)));
      const baseLines = [
        `【当前分卷约束：第${vol.num}卷「${volumeName}」】`,
        `章节范围：第${vol.start}-${vol.end}章；当前要写第${nextNum}章，卷内进度约 ${progress}%。`,
        `本卷设定：${vol.context || volumeName}`,
        '必须服务当前卷目标和情绪曲线；不得提前跳到后续卷主线大事件，不得把本卷无限延长成整本书。',
      ];
      if (nextNum === vol.start) {
        // 卷首章：注入新卷上下文
        volumeGuidance = [
          ...baseLines,
          '这是新卷的第1章，请建立本卷基调、初始场景和阶段目标，并自然承接前一卷余波。',
        ].join('\n');
      } else if (nextNum >= vol.end - 30) {
        // 卷尾临近：提示收束
        const nextVol = getVolumesForBook(bookId, book).find(v => v.num === vol.num + 1);
        volumeGuidance = [
          ...baseLines,
          `本章处于卷尾收束阶段，距卷末还有 ${vol.end - nextNum + 1} 章。`,
          `请逐步回收本卷线索，并为下一卷「${nextVol ? nextVol.title + (nextVol.subtitle ? '·' + nextVol.subtitle : '') : '终局'}」埋设过渡伏笔。`,
        ].join('\n');
      } else {
        // 卷中章：每章仍给 InkOS 明确的卷边界，防止上下文超长后漂移。
        volumeGuidance = [
          ...baseLines,
          '本章属于卷中推进：保持当前卷的案件/成长/情绪节奏，推进阶段目标，不做跨卷跳跃。',
        ].join('\n');
      }
    }

    // 结构化预算是权威约束；自由文本分卷与用户指导只能补充情节目标。
    const finalGuidance = [structuredGuidance, volumeGuidance, guidance].filter(Boolean).join('\n\n') || undefined;

    res.json({ message: 'InkOS 正在生成新章节...', status: 'processing', traceId: req.traceId });

    let trackedChapterNum = nextNum;
    let generatedVolume = vol;
    let effectiveGenerationBudget = adaptiveBudget;
    try {
      const result = await generateChapter(bookId, finalGuidance, {
        targetWords: adaptiveBudget.targetWords,
        traceId: req.traceId,
        onProgress: progress => appendGenerationProgress(bookId, nextNum, progress, { phase: 'inkos_writing' }),
        onTextDelta: text => appendGenerationText(bookId, nextNum, text),
      });
      if (result.success && result.newContent !== undefined) {
        const actualChapterNum = Number(result.newChapterNum);
        if (!Number.isSafeInteger(actualChapterNum) || actualChapterNum < 1) {
          throw new Error(`InkOS 返回了无效章节号: ${String(result.newChapterNum)}`);
        }
        if (actualChapterNum > longFormPlan.plan.targetChapters) {
          throw new Error(`InkOS 生成了超出结构化规划上限的第${actualChapterNum}章`);
        }
        result.newChapterNum = actualChapterNum;
        if (actualChapterNum !== nextNum) {
          const postGenerationIndex = readChapterIndex(bookId, { strict: true });
          const postGenerationMetrics = collectWrittenChapterMetrics(bookId, book, postGenerationIndex);
          effectiveGenerationBudget = resolveAdaptiveChapterBudget(
            longFormPlan,
            actualChapterNum,
            postGenerationMetrics,
          );
          finishGenerationJob(bookId, nextNum, {
            phase: 'complete_retargeted',
            message: `InkOS 实际生成第${actualChapterNum}章，任务已转移`,
            actualChapterNum,
          });
          trackedChapterNum = actualChapterNum;
          generatedVolume = getVolumeForChapter(actualChapterNum, bookId, book);
          setGenerationJob(bookId, actualChapterNum, {
            phase: 'inkos_writing',
            title: result.title || '',
            message: `已接收 InkOS 实际生成的第${actualChapterNum}章`,
            traceId: req.traceId,
            targetWords: effectiveGenerationBudget.targetWords,
            plannedTargetWords: effectiveGenerationBudget.plannedTargetWords,
            adaptiveBudget: effectiveGenerationBudget,
            wordRange: {
              min: effectiveGenerationBudget.minWords,
              max: effectiveGenerationBudget.maxWords,
            },
          });
        }
      }
      const freshState = loadState();
      const freshBook = getBook(freshState, bookId);
      if (!freshBook) {
        finishGenerationJob(bookId, trackedChapterNum, { phase: 'error', error: '生成结束后书籍状态不存在' });
        return;
      }
      if (result.success && result.newContent !== undefined) {
        const firstDiskEntry = getInkosChapterEntry(bookId, result.newChapterNum);
        if (isInkosAuditFailed(firstDiskEntry)) {
          const inkosReview = inkosAuditFailedReview(firstDiskEntry);
          upsertChapterInMemory(freshState, bookId, {
            number: result.newChapterNum,
            title: result.title || '',
            content: result.newContent,
            bookTitle: book.title,
          });
          const ch = getChapter(freshBook, result.newChapterNum);
          if (ch) {
            ch.volume = generatedVolume ? generatedVolume.num : null;
            ch.volumeTitle = generatedVolume ? `${generatedVolume.title}·${generatedVolume.subtitle}` : null;
            ch.status = STATUS.REVISION_FAILED;
            ch.llmReview = inkosReview;
            ch.reviewNotes = inkosReview.revisionGuidance;
          }
          commitBookFromSnapshot(freshState, bookId, { chapterNumbers: [result.newChapterNum] });
          const actualWords = chapterLength(result.newContent, bookLanguage);
          finishGenerationJob(bookId, trackedChapterNum, {
            phase: 'complete_inkos_failed',
            llmReview: inkosReview,
            actualWords,
            wordDrift: actualWords - effectiveGenerationBudget.targetWords,
            targetWords: effectiveGenerationBudget.targetWords,
            wordRange: { min: effectiveGenerationBudget.minWords, max: effectiveGenerationBudget.maxWords },
          });
          console.warn(`[generate] 第 ${result.newChapterNum} 章 InkOS 自审未通过，已拦截系统 LLM 初审`);
          return;
        }

        setGenerationJob(bookId, result.newChapterNum, { phase: 'llm_reviewing', title: result.title || '', message: 'system LLM review running' });
        let finalContent = result.newContent;
        let llmReview = null;
        try {
          const reviewResult = await runLlmInitialReviewAndAutoFix(
            bookId,
            result.newChapterNum,
            result.title || '',
            result.newContent,
            freshBook || book,
            Number(process.env.PUBLISHER_LLM_REVIEW_FIXES || '1'),
          );
          finalContent = reviewResult.content || result.newContent;
          llmReview = {
            status: reviewResult.pass ? 'passed' : 'failed',
            model: reviewResult.review?.model || '',
            summary: reviewResult.review?.summary || '',
            issues: reviewResult.review?.issues || [],
            revisionGuidance: reviewResult.review?.revisionGuidance || '',
            reviewedAt: reviewResult.review?.reviewedAt || new Date().toISOString(),
            autoFixed: Boolean(reviewResult.fixed),
            attempts: reviewResult.reviews || [],
          };
          console.log(`[llm-review] 第${result.newChapterNum}章 ${reviewResult.pass ? '初审通过' : '初审未通过'}${reviewResult.fixed ? '（已自动修改）' : ''}`);
        } catch (reviewErr) {
          llmReview = {
            status: 'error',
            model: '',
            summary: `LLM 初审异常：${reviewErr.message}`,
            issues: [reviewErr.message],
            reviewedAt: new Date().toISOString(),
            attempts: [],
          };
          console.error(`[llm-review] 第${result.newChapterNum}章初审异常:`, reviewErr);
        }

        let artifactSync = null;
        if (finalContent !== result.newContent) {
          artifactSync = await syncInkosChapterArtifacts(
            bookId,
            result.newChapterNum,
            'Publisher 初审修订后的正文同步',
          );
          if (!artifactSync.synced) {
            const syncIssue = `修订正文未能同步到 InkOS truth/index：${artifactSync.reason || '未知原因'}`;
            llmReview = {
              ...(llmReview || {}),
              status: 'failed',
              model: llmReview?.model || '',
              summary: `${llmReview?.summary ? `${llmReview.summary}；` : ''}${syncIssue}`,
              issues: [...(llmReview?.issues || []), syncIssue],
              revisionGuidance: [llmReview?.revisionGuidance, syncIssue].filter(Boolean).join('\n'),
              reviewedAt: llmReview?.reviewedAt || new Date().toISOString(),
              attempts: llmReview?.attempts || [],
            };
          }
        }

        const actualWords = chapterLength(finalContent, bookLanguage);
        const actualBudget = effectiveGenerationBudget;
        let wordGate = {
          passed: !artifactSync || artifactSync.synced,
          actualWords,
          minWords: actualBudget.minWords,
          maxWords: actualBudget.maxWords,
          artifactSync,
        };
        if (actualWords < actualBudget.minWords || actualWords > actualBudget.maxWords) {
          const driftIssue = `机器字数门禁未通过：实际 ${actualWords} 字，允许 ${actualBudget.minWords}-${actualBudget.maxWords} 字`;
          llmReview = {
            ...(llmReview || {}),
            status: 'failed',
            model: llmReview?.model || '',
            summary: `${llmReview?.summary ? `${llmReview.summary}；` : ''}${driftIssue}`,
            issues: [...(llmReview?.issues || []), driftIssue],
            revisionGuidance: [llmReview?.revisionGuidance, driftIssue].filter(Boolean).join('\n'),
            reviewedAt: llmReview?.reviewedAt || new Date().toISOString(),
            attempts: llmReview?.attempts || [],
          };
          const sync = await syncInkosChapterArtifacts(bookId, result.newChapterNum, driftIssue);
          const reject = await rejectInkosChapterKeepSubsequent(bookId, result.newChapterNum, driftIssue);
          wordGate = { ...wordGate, passed: false, issue: driftIssue, sync, reject };
          console.warn(`[generate] 第${result.newChapterNum}章字数门禁失败：${actualWords}，允许 ${actualBudget.minWords}-${actualBudget.maxWords}`);
        }

        upsertChapterInMemory(freshState, bookId, {
          number: result.newChapterNum,
          title: result.title || '',
          content: finalContent,
          bookTitle: book.title,
        });
        // 标注分卷归属
        const ch = getChapter(freshBook, result.newChapterNum);
        if (ch) {
          ch.volume = generatedVolume ? generatedVolume.num : null;
          ch.volumeTitle = generatedVolume ? `${generatedVolume.title}·${generatedVolume.subtitle}` : null;
          const finalDiskEntry = getInkosChapterEntry(bookId, result.newChapterNum);
          if (isInkosAuditFailed(finalDiskEntry)) {
            llmReview = inkosAuditFailedReview(finalDiskEntry);
          }
          ch.llmReview = llmReview;
          const diskEntry = readChapterIndex(bookId, { strict: true }).find(entry => entry.number === result.newChapterNum);
          applyInkosReviewStateToPublisherChapter(ch, diskEntry);
          ch.status = llmReview?.status === 'passed' ? STATUS.PENDING_REVIEW : STATUS.REVISION_FAILED;
        }
        commitBookFromSnapshot(freshState, bookId, { chapterNumbers: [result.newChapterNum] });
        finishGenerationJob(bookId, trackedChapterNum, {
          phase: llmReview?.status === 'passed' ? 'complete_passed' : 'complete_needs_review',
          llmReview,
          wordGate,
          actualWords,
          wordDrift: actualWords - effectiveGenerationBudget.targetWords,
          targetWords: effectiveGenerationBudget.targetWords,
          wordRange: { min: actualBudget.minWords, max: actualBudget.maxWords },
        });
        console.log(`[generate] 第 ${result.newChapterNum} 章 生成成功 (${generatedVolume ? '卷' + generatedVolume.num + '·' + generatedVolume.title : '规划外'})`);
      } else {
        finishGenerationJob(bookId, trackedChapterNum, { phase: 'failed', error: result.error });
        console.error(`[generate] 生成失败:`, result.error);
      }
    } catch (err) {
      finishGenerationJob(bookId, trackedChapterNum, { phase: 'error', error: err.message });
      console.error('[generate] 异常:', err);
    }
  } catch (err) {
    res.status(err?.statusCode || 500).json({ error: err.message });
  }
}));


// ============ Debug ============
app.get('/api/books/:bookId/generation/:chapterNum/events', (req, res) => {
  const chapterNum = Number(req.params.chapterNum);
  if (!Number.isInteger(chapterNum) || chapterNum < 1) {
    return res.status(400).json({ error: 'Invalid chapter number' });
  }

  const key = generationKey(req.params.bookId, chapterNum);
  res.status(200).set({
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  res.flushHeaders?.();

  const send = (event, payload) => {
    if (res.writableEnded) return;
    res.write(`event: ${event}\ndata: ${JSON.stringify(payload)}\n\n`);
  };
  const listener = (event) => send(event.type, event);
  generationEvents.on(key, listener);
  send('job', { type: 'job', job: generationJobs.get(key) || readPersistedTerminalGenerationJob(req.params.bookId, chapterNum) });

  const heartbeat = setInterval(() => {
    if (!res.writableEnded) res.write(': keepalive\n\n');
  }, 15000);
  const close = () => {
    clearInterval(heartbeat);
    generationEvents.off(key, listener);
  };
  req.once('close', close);
});

app.get('/api/books/:bookId/generation/:chapterNum', (req, res) => {
  const chapterNum = Number(req.params.chapterNum);
  if (!Number.isInteger(chapterNum) || chapterNum < 1) {
    return res.status(400).json({ error: 'Invalid chapter number' });
  }
  res.json({ job: generationJobs.get(generationKey(req.params.bookId, chapterNum)) || readPersistedTerminalGenerationJob(req.params.bookId, chapterNum) });
});

app.get('/api/debug/events', (req, res) => {
  const result = queryDebugEvents({
    limit: req.query.limit || 300,
    after: req.query.after,
    before: req.query.before,
    level: req.query.level,
    component: req.query.component || req.query.scope,
    operation: req.query.operation,
    traceId: req.query.traceId,
    bookId: req.query.bookId,
    chapterNumber: req.query.chapterNumber,
    text: req.query.text,
  });
  if (req.query.format === 'jsonl' || req.accepts(['json', 'application/x-ndjson']) === 'application/x-ndjson') {
    res.type('application/x-ndjson');
    return res.send(result.events.map(event => JSON.stringify(event)).join('\n') + (result.events.length ? '\n' : ''));
  }
  res.json({ ...result, files: debugFileInfo() });
});

app.get('/api/debug/schema', (req, res) => {
  res.json(debugSchema());
});

app.get('/api/debug/health', (req, res) => {
  const health = debugHealth();
  res.status(health.status === 'healthy' ? 200 : 503).json(health);
});

app.get('/api/debug/stream', (req, res) => {
  res.set({
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  res.flushHeaders?.();
  const send = event => {
    if (req.query.traceId && event.traceId !== String(req.query.traceId)) return;
    if (req.query.component && event.component !== String(req.query.component)) return;
    if (req.query.bookId && event.bookId !== String(req.query.bookId)) return;
    if (req.query.chapterNumber && event.chapterNumber !== Number(req.query.chapterNumber)) return;
    res.write(`id: ${event.sequence}\nevent: diagnostic\ndata: ${JSON.stringify(event)}\n\n`);
  };
  const backlog = queryDebugEvents({
    limit: req.query.limit || 200,
    after: req.query.after || req.get('Last-Event-ID'),
    traceId: req.query.traceId,
    component: req.query.component,
    bookId: req.query.bookId,
    chapterNumber: req.query.chapterNumber,
  });
  backlog.events.forEach(send);
  debugEvents.on('event', send);
  const heartbeat = setInterval(() => {
    if (!res.writableEnded) res.write(': keepalive\n\n');
  }, 15_000);
  req.once('close', () => {
    clearInterval(heartbeat);
    debugEvents.off('event', send);
  });
});

app.get('/api/debug/jobs', (req, res) => {
  res.json({
    generationJobs: Array.from(generationJobs.values()),
    creationJobs: Array.from(creationJobs.values()).map(job => ({ ...job, stdout: job.stdout ? `${job.stdout.slice(0, 500)}...` : '', stderr: job.stderr ? `${job.stderr.slice(0, 500)}...` : '' })),
    debug: debugFileInfo(),
  });
});

// ============ 番茄在线（只读 + 账号管理） ============
// 只读访问番茄作家后台，通过 Playwright 子进程。每个 op 慢（~10-30s，起浏览器）。
// 失败时 fanqie_ops 返 {needRelogin:true} → 路由返 401 让前端提示重登。
// 上传/编辑/发布/同步功能已移除——本段仅保留读取 + 账号管理。

// 检查番茄登录态：state.json 是否存在 + cookie 是否全过期。
function fanqieLoginState() {
  if (!existsSync(PATHS.FANQIE_STATE_FILE)) {
    return { loggedIn: false, needRelogin: true, reason: 'state.json 不存在，请先运行 python3 login.py' };
  }
  // best-effort: 读 state.json 检查 cookie 过期时间
  try {
    const raw = readFileSync(PATHS.FANQIE_STATE_FILE, 'utf-8');
    const s = JSON.parse(raw);
    const cookies = (s && s.cookies) || [];
    const sessionid = cookies.find(c => c.name === 'sessionid');
    const now = Date.now();
    // 无 expires 或已过期 → 仍可能有效（番茄可能用其他机制），只作弱提示
    if (sessionid && sessionid.expires && sessionid.expires * 1000 < now) {
      return { loggedIn: false, needRelogin: true, reason: 'sessionid cookie 已过期' };
    }
    return { loggedIn: true, needRelogin: false };
  } catch {
    return { loggedIn: true, needRelogin: false };
  }
}

app.get('/api/fanqie/login-state', (req, res) => {
  res.json(fanqieLoginState());
});

// 番茄账号信息（从 state.json + 实时拉取作品中提取作者名）
app.get('/api/fanqie/account', asyncRoute(async (req, res) => {
  const login = fanqieLoginState();
  if (!login.loggedIn) {
    return res.json({ loggedIn: false, reason: login.reason });
  }
  try {
    // 读 state.json 获取 cookie 中的账号线索
    let cookieInfo = {};
    try {
      const raw = readFileSync(PATHS.FANQIE_STATE_FILE, 'utf-8');
      const s = JSON.parse(raw);
      const cookies = (s && s.cookies) || [];
      const sid = cookies.find(c => c.name === 'sessionid');
      if (sid) {
        cookieInfo.sessionId = sid.value.slice(0, 8) + '...';
        cookieInfo.expires = sid.expires ? new Date(sid.expires * 1000).toISOString() : '未知';
      }
      // 尝试从 localStorage 提取用户名
      for (const origin of (s.origins || [])) {
        for (const item of (origin.localStorage || [])) {
          if (item.name === 'user_name' || item.name === 'author_name' || item.name === 'nickname') {
            cookieInfo.authorName = item.value;
          }
        }
      }
    } catch {}

    // 尝试从已缓存的作品列表中获取作者名（从番茄 API 返回）
    let authorName = cookieInfo.authorName || null;
    try {
      const books = await listBooks();
      // 番茄 API 作品列表通常不含作者名——但我们可以从 state.json 的 fanqieMap 关联
    } catch {}

    res.json({
      loggedIn: true,
      sessionId: cookieInfo.sessionId || '未知',
      sessionExpires: cookieInfo.expires || '未知',
      authorName,
      stateFile: PATHS.FANQIE_STATE_FILE,
    });
  } catch (err) {
    res.json({ loggedIn: true, sessionId: '未知', error: err.message });
  }
}));

// 退出番茄账号（删除 state.json，强制重新登录）
app.post('/api/fanqie/logout', (req, res) => {
  try {
    shutdownFanqie();
    let backupFile = '';
    if (existsSync(PATHS.FANQIE_STATE_FILE)) {
      const bak = PATHS.FANQIE_STATE_FILE + '.bak-' + Date.now();
      writeFileSync(bak, readFileSync(PATHS.FANQIE_STATE_FILE), { mode: 0o600 });
      chmodSync(bak, 0o600);
      backupFile = bak;
      // 真正删除 state.json，让 fanqieLoginState 返回未登录
      unlinkSync(PATHS.FANQIE_STATE_FILE);
    }
    res.json({
      ok: true,
      backupFile,
      message: backupFile
        ? '已退出。state.json 已删除，备份保存为仅当前用户可读的 .bak 文件。请重新运行 python3 login.py 登录。'
        : '已退出。当前没有保存的番茄登录状态。请重新运行 python3 login.py 登录。',
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 获取登录跳转地址（番茄作家后台）
app.get('/api/fanqie/login-url', (req, res) => {
  res.json({
    url: 'https://fanqienovel.com/main/writer/?enter_from=author_zone',
    instructions: '在浏览器中打开此地址扫码/密码登录，然后运行 python3 login.py 保存状态',
  });
});

// fanqie ops now resolve to data directly, or throw (with err.needRelogin
// when the 番茄 session is stale). Centralize the error → response mapping.
function fanqieErrorResponse(res, err) {
  if (err && err.needRelogin) {
    return res.status(401).json({ error: err.message || 'LOGIN_EXPIRED', needRelogin: true });
  }
  return res.status(500).json({ error: err.message });
}

// 番茄作品列表（只读）
app.get('/api/fanqie/books', asyncRoute(async (req, res) => {
  try {
    const books = await listBooks();
    res.json({ books: books || [] });
  } catch (err) {
    fanqieErrorResponse(res, err);
  }
}));

// 番茄某书的章节列表。bookId 走 param，bookTitle 走 query（避中文编码问题）
app.get('/api/fanqie/books/:bookId/chapters', asyncRoute(async (req, res) => {
  try {
    const { bookId } = req.params;
    const bookTitle = req.query.title;
    if (!bookTitle) return res.status(400).json({ error: '需要 ?title=书名 参数' });
    const chapters = await listChapters(bookId, bookTitle);
    res.json({ chapters: chapters || [] });
  } catch (err) {
    fanqieErrorResponse(res, err);
  }
}));

// 读某章正文（只读，绝不发布）
app.get('/api/fanqie/books/:bookId/chapters/:chapterId/content', asyncRoute(async (req, res) => {
  try {
    const { bookId, chapterId } = req.params;
    const data = await getFanqieChapter(bookId, chapterId);
    res.json(data);
  } catch (err) {
    fanqieErrorResponse(res, err);
  }
}));

// ============ InkOS LLM 配置 ============
import { DEFAULT_LLM_MODEL, getEffectiveInkosConfig, getInkosConfig, applyInkosConfig } from './lib/inkos-config.js';
import { getBookSettings, getBookSetting, saveBookSetting } from './lib/book-settings.js';

function maskSecret(value) {
  if (!value) return '';
  if (value.length <= 8) return '••••';
  return `${value.slice(0, 5)}...${value.slice(-4)}`;
}

function normalizeOpenAiBaseUrl(value) {
  return normalizeLlmBaseUrl(value);
}

function openAiProviderError(status, statusText, bodyText) {
  let data = null;
  try { data = JSON.parse(bodyText); } catch { /* non-JSON provider error */ }
  const message = data?.error?.message || data?.message || `${status} ${statusText}`;
  return String(message || 'OpenAI 接口返回异常').replace(/\s+/g, ' ').trim().slice(0, 500);
}

function canonicalBaseUrlForComparison(value) {
  try {
    return new URL(String(value || '').trim()).toString().replace(/\/+$/, '');
  } catch {
    return '';
  }
}

function resolveOpenAiModelEndpoint(incoming = {}) {
  const stored = getInkosConfig();
  const effective = getEffectiveInkosConfig();
  const isReview = incoming.role === 'review';
  const fallbackBaseUrl = isReview
    ? (stored.reviewBaseUrl || stored.baseUrl || effective.baseUrl || process.env.OPENAI_BASE_URL || '')
    : (stored.baseUrl || effective.baseUrl || process.env.OPENAI_BASE_URL || '');
  const fallbackApiKey = isReview
    ? (stored.reviewApiKey || stored.apiKey || effective.apiKey || process.env.OPENAI_API_KEY || '')
    : (stored.apiKey || effective.apiKey || process.env.OPENAI_API_KEY || '');
  const requestedBaseUrl = String(incoming.baseUrl || '').trim();
  const baseUrl = normalizeOpenAiBaseUrl(requestedBaseUrl || fallbackBaseUrl);
  const explicitApiKey = String(incoming.apiKey || '').trim();
  let apiKey = explicitApiKey;
  if (!apiKey && fallbackApiKey) {
    const trustedBaseUrl = canonicalBaseUrlForComparison(fallbackBaseUrl);
    if (requestedBaseUrl && baseUrl !== trustedBaseUrl) {
      throw new Error('切换 OpenAI Base URL 时必须重新输入对应的 API Key');
    }
    apiKey = String(fallbackApiKey).trim();
  }
  if (!apiKey) throw new Error('请先填写或保存 OpenAI API Key');
  return { baseUrl, apiKey };
}

function openAiHeaders(apiKey) {
  return {
    'Content-Type': 'application/json',
    Authorization: `Bearer ${apiKey}`,
  };
}

async function fetchOpenAiWithTimeout(url, options, timeoutMs = 25000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

// 读当前生效配置（项目本地 ./book/inkos.json）
app.get('/api/inkos/config', (req, res) => {
  try {
    const effective = getEffectiveInkosConfig();
    const stored = getInkosConfig(); // 面板存的镜像（含 apiKey）
    const apiKey = stored.apiKey || effective.apiKey || '';
    const reviewApiKey = stored.reviewApiKey || stored.apiKey || effective.apiKey || '';
    res.json({
      ...effective,
      provider: 'openai',
      apiFormat: 'chat',
      model: effective.model || stored.model || DEFAULT_LLM_MODEL,
      reviewModel: stored.reviewModel || DEFAULT_LLM_MODEL,
      reviewBaseUrl: stored.reviewBaseUrl || '',
      apiKey: '',
      reviewApiKey: '',
      hasApiKey: Boolean(apiKey),
      apiKeyPreview: maskSecret(apiKey),
      hasReviewApiKey: Boolean(reviewApiKey),
      reviewApiKeyPreview: maskSecret(reviewApiKey),
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 保存并应用配置（直接写入项目本地 ./book/inkos.json，InkOS 由项目内源码局部运行）
app.post('/api/inkos/config', asyncRoute(async (req, res) => {
  try {
    const runningJob = activeWorkflowJob();
    if (runningJob) {
      return res.status(409).json({
        error: '有书籍创建、生成、修改或审核任务正在运行，请等待任务结束后再切换模型配置。',
        job: runningJob,
      });
    }
    const incoming = req.body || {};
    const stored = getInkosConfig();
    const normalizedIncoming = { ...incoming };
    for (const field of ['baseUrl', 'reviewBaseUrl']) {
      const candidate = Object.prototype.hasOwnProperty.call(incoming, field)
        ? String(incoming[field] || '').trim()
        : String(stored[field] || '').trim();
      normalizedIncoming[field] = candidate ? normalizeOpenAiBaseUrl(candidate) : '';
    }
    // Empty API key means "keep the existing key"; users only type here when
    // rotating the secret. This lets GET stay redacted without making Save
    // accidentally wipe the configured InkOS key.
    const cfg = {
      ...normalizedIncoming,
      provider: 'openai',
      apiFormat: 'chat',
      apiKey: incoming.apiKey ? incoming.apiKey : (stored.apiKey || ''),
      reviewApiKey: incoming.reviewApiKey ? incoming.reviewApiKey : (stored.reviewApiKey || ''),
    };
    const result = await applyInkosConfig(cfg);
    await invalidatePublisherInkOSRuntime();
    res.json({ ok: true, ...result });
  } catch (err) {
    res.status(err?.statusCode || 500).json({ error: err.message });
  }
}));

// OpenAI-compatible model discovery. Keys are resolved on the server so the
// settings page never needs a readable stored secret.
app.post('/api/inkos/models/list', asyncRoute(async (req, res) => {
  let endpoint;
  try {
    endpoint = resolveOpenAiModelEndpoint(req.body || {});
    const response = await fetchOpenAiWithTimeout(`${endpoint.baseUrl}/models`, {
      method: 'GET',
      headers: openAiHeaders(endpoint.apiKey),
    });
    const text = await response.text();
    if (!response.ok) {
      return res.status(502).json({ error: `模型列表获取失败：${openAiProviderError(response.status, response.statusText, text)}` });
    }
    let payload;
    try {
      payload = JSON.parse(text);
    } catch {
      return res.status(502).json({ error: '模型列表接口未返回 OpenAI 格式 JSON' });
    }
    if (!Array.isArray(payload?.data)) {
      return res.status(502).json({ error: '模型列表接口未返回 OpenAI /models 的 data 数组' });
    }
    const seen = new Set();
    const models = payload.data
      .map(item => ({
        id: String(item?.id || '').trim(),
        ownedBy: String(item?.owned_by || '').trim(),
      }))
      .filter(item => item.id && !seen.has(item.id) && seen.add(item.id))
      .sort((a, b) => a.id.localeCompare(b.id, 'en'));
    res.json({ ok: true, baseUrl: endpoint.baseUrl, models });
  } catch (err) {
    const timedOut = err?.name === 'AbortError';
    res.status(502).json({ error: timedOut ? '模型列表请求超时' : `模型列表获取失败：${err.message}` });
  }
}));

// A chat-completions probe distinguishes a listed model from one that can
// actually serve chapter writing and review requests.
app.post('/api/inkos/models/test', asyncRoute(async (req, res) => {
  const model = String(req.body?.model || '').trim();
  if (!model) return res.status(400).json({ error: '需要 model' });

  let endpoint;
  try {
    endpoint = resolveOpenAiModelEndpoint(req.body || {});
  } catch (err) {
    return res.status(400).json({ error: err.message });
  }

  const startedAt = Date.now();
  try {
    const response = await fetchOpenAiWithTimeout(`${endpoint.baseUrl}/chat/completions`, {
      method: 'POST',
      headers: openAiHeaders(endpoint.apiKey),
      body: JSON.stringify({
        model,
        stream: false,
        max_tokens: 4,
        messages: [{ role: 'user', content: 'Reply with OK.' }],
      }),
    });
    const latencyMs = Date.now() - startedAt;
    const text = await response.text();
    if (!response.ok) {
      return res.json({
        ok: false,
        model,
        latencyMs,
        status: response.status,
        error: openAiProviderError(response.status, response.statusText, text),
      });
    }
    let payload;
    try {
      payload = JSON.parse(text);
    } catch {
      return res.json({ ok: false, model, latencyMs, status: response.status, error: '模型未返回 OpenAI Chat Completions JSON' });
    }
    if (!Array.isArray(payload?.choices)) {
      return res.json({ ok: false, model, latencyMs, status: response.status, error: '模型未返回 Chat Completions choices，不能用于章节写作' });
    }
    res.json({ ok: true, model, latencyMs, status: response.status });
  } catch (err) {
    const latencyMs = Date.now() - startedAt;
    res.json({
      ok: false,
      model,
      latencyMs,
      error: err?.name === 'AbortError' ? '请求超时（25 秒）' : String(err?.message || '请求失败').slice(0, 500),
    });
  }
}));

// ============ 书设定（读写 InkOS story/ 文件 + 备份/还原） ============

// 备份目录
const SETTINGS_BACKUP_DIR = join(__dirname, 'data', 'settings-backups');

function ensureSettingsBackupDir() {
  if (!existsSync(SETTINGS_BACKUP_DIR)) mkdirSync(SETTINGS_BACKUP_DIR, { recursive: true });
}

function settingsBackupRoot(bookId) {
  return resolve(SETTINGS_BACKUP_DIR, assertBookId(bookId));
}

function resolveSettingsBackupDir(bookId, backupRef) {
  const root = settingsBackupRoot(bookId);
  const raw = String(backupRef || '').trim();
  if (!raw) throw new Error('需要 backupId');
  const candidate = /^\d+$/.test(raw) ? resolve(root, raw) : resolve(raw);
  const rel = relative(root, candidate);
  if (!/^\d+$/.test(rel) || rel.includes(sep)) {
    throw new Error('备份目录不属于当前书籍');
  }
  return candidate;
}

// 备份书设定到 data/settings-backups/<bookId>/<timestamp>/
function backupBookSettings(bookId) {
  const safeBookId = assertBookId(bookId);
  ensureSettingsBackupDir();
  const root = settingsBackupRoot(safeBookId);
  let ts = Date.now();
  while (existsSync(join(root, String(ts)))) ts += 1;
  const backupDir = join(root, String(ts));
  mkdirSync(backupDir, { recursive: true });

  const storyDir = bookPath(safeBookId, 'story');
  const files = [];
  if (existsSync(storyDir)) {
    copyDirectoryStrict(storyDir, backupDir, files);
  }
  return { backupDir, fileCount: files.length, timestamp: ts };
}

// 从备份还原书设定
function restoreBookSettings(bookId, backupDir) {
  const safeBackupDir = resolveSettingsBackupDir(bookId, backupDir);
  if (!existsSync(safeBackupDir)) throw new Error(`备份目录不存在: ${safeBackupDir}`);
  const storyDir = bookPath(bookId, 'story');
  return replaceDirectoryFromBackup(storyDir, safeBackupDir, 'settings-restore', { requireFiles: true });
}

// 保存并备份：先备份 → 写入新内容 → 失败则还原
app.post('/api/books/:bookId/settings/safe-edit', (req, res) => {
  const { bookId } = req.params;
  if (rejectActiveBookMutation(res, bookId, '修改设定')) return;
  const { file, content } = req.body || {};
  if (typeof file !== 'string' || content === undefined) {
    return res.status(400).json({ error: '需要 file（文件相对路径）和 content（新内容）' });
  }

  try {
    const existing = getBookSetting(bookId, file);
    if (existing === null) return res.status(404).json({ error: '设定文件不存在或已被移除' });
  } catch (err) {
    return res.status(400).json({ error: err.message });
  }

  let backup = null;
  try {
    // Step 1: 备份整个 story/ 目录
    backup = backupBookSettings(bookId);
    console.log(`[settings] 已备份 ${backup.fileCount} 个文件到 ${backup.backupDir}`);
    // Step 2: 写入新内容
    const result = saveBookSetting(bookId, file, content);

    res.json({
      ok: true,
      path: file,
      size: result.size,
      backupDir: backup.backupDir,
      message: `已保存。备份位于 ${backup.backupDir}`,
    });
  } catch (err) {
    if (!backup) {
      return res.status(500).json({ error: `创建设定备份失败，未写入新内容: ${err.message}` });
    }
    // Step 3: 写入失败 → 还原备份
    console.error(`[settings] 修改失败，还原备份: ${err.message}`);
    try {
      restoreBookSettings(bookId, backup.backupDir);
      res.status(500).json({ error: `修改失败，已自动还原备份: ${err.message}`, restored: true });
    } catch (restoreErr) {
      res.status(500).json({ error: `修改失败且还原备份亦失败: ${restoreErr.message}。备份位于 ${backup.backupDir}，请手动恢复。` });
    }
  }
});

// 手动还原到指定备份
app.post('/api/books/:bookId/settings/restore', (req, res) => {
  const { bookId } = req.params;
  if (rejectActiveBookMutation(res, bookId, '还原设定')) return;
  const { backupId, backupDir } = req.body || {};
  const requestedBackup = backupId || backupDir;
  if (!requestedBackup) {
    // 列出可用备份
    ensureSettingsBackupDir();
    const bookBackupDir = settingsBackupRoot(bookId);
    if (!existsSync(bookBackupDir)) return res.json({ backups: [] });
    const backups = readdirSync(bookBackupDir, { withFileTypes: true })
      .filter(e => e.isDirectory() && /^\d+$/.test(e.name))
      .map(e => ({ backupId: e.name, timestamp: Number(e.name), dir: join(bookBackupDir, e.name), time: new Date(Number(e.name)).toISOString() }))
      .sort((a, b) => b.timestamp - a.timestamp);
    return res.json({ backups });
  }
  try {
    const r = restoreBookSettings(bookId, requestedBackup);
    res.json({ ok: true, restoredCount: r.restoredCount });
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

// 列出所有备份
app.get('/api/books/:bookId/settings/backups', (req, res) => {
  const { bookId } = req.params;
  ensureSettingsBackupDir();
  const bookBackupDir = settingsBackupRoot(bookId);
  if (!existsSync(bookBackupDir)) return res.json({ backups: [] });
  const backups = readdirSync(bookBackupDir, { withFileTypes: true })
    .filter(e => e.isDirectory() && /^\d+$/.test(e.name))
    .map(e => ({
      backupId: e.name,
      timestamp: Number(e.name),
      dir: join(bookBackupDir, e.name),
      time: new Date(Number(e.name)).toISOString(),
    }))
    .sort((a, b) => b.timestamp - a.timestamp);
  res.json({ backups });
});

// 列出某书 story/ 下的设定文件
app.get('/api/books/:bookId/settings', (req, res) => {
  try {
    const { bookId } = req.params;
    res.json(getBookSettings(bookId));
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

// 读单个设定文件内容
app.get('/api/books/:bookId/settings/*', (req, res) => {
  try {
    const { bookId } = req.params;
    const relPath = req.params[0];
    const content = getBookSetting(bookId, relPath);
    if (content === null) return res.status(404).json({ error: '文件不存在' });
    res.type('text/plain').send(content);
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

// 写单个设定文件。body: { content }
app.post('/api/books/:bookId/settings/*', (req, res) => {
  const { bookId } = req.params;
  if (rejectActiveBookMutation(res, bookId, '修改设定')) return;
  const relPath = req.params[0];
  const { content } = req.body || {};
  if (content === undefined) return res.status(400).json({ error: '需要 content' });
  try {
    if (getBookSetting(bookId, relPath) === null) {
      return res.status(404).json({ error: '设定文件不存在或已被移除' });
    }
  } catch (err) {
    return res.status(400).json({ error: err.message });
  }

  let backup = null;
  try {
    backup = backupBookSettings(bookId);
    const result = saveBookSetting(bookId, relPath, content);
    res.json({ ...result, backupDir: backup.backupDir });
  } catch (err) {
    if (!backup) {
      return res.status(500).json({ error: `创建设定备份失败，未写入新内容: ${err.message}` });
    }
    try {
      restoreBookSettings(bookId, backup.backupDir);
      res.status(500).json({ error: `修改失败，已自动还原备份: ${err.message}`, restored: true });
    } catch (restoreErr) {
      res.status(500).json({ error: `修改失败且还原备份亦失败: ${restoreErr.message}。备份位于 ${backup.backupDir}，请手动恢复。` });
    }
  }
});

// ============ Start Server ============

app.use((err, req, res, next) => {
  if (res.headersSent) return next(err);
  const status = Number(err?.statusCode) || (err?.code === 'STATE_DATA_INVALID' ? 503 : 500);
  console.error(`[http] ${req.method} ${req.path}:`, err);
  res.status(status).json({ error: err?.message || '服务器内部错误' });
});

// Bind to localhost only — this service has no auth and drives shell/CLI tools.
const server = app.listen(PORT, '127.0.0.1', () => {
  console.log(`📖 章节审批发布系统已启动: http://localhost:${PORT}`);
});

let shuttingDown = false;
function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`[server] ${signal}，正在关闭本地服务`);
  const now = new Date().toISOString();
  for (const job of generationJobs.values()) {
    if (job.finishedAt) continue;
    Object.assign(job, { phase: 'error', error: `${signal} 导致任务中断`, message: '服务关闭，任务中断', updatedAt: now, finishedAt: now });
  }
  for (const job of creationJobs.values()) {
    if (job.finishedAt) continue;
    Object.assign(job, { status: 'failed', error: `${signal} 导致任务中断`, updatedAt: now, finishedAt: now });
  }
  persistWorkflowJobs();
  const terminatedChildren = Number(shutdownFanqie()) + shutdownInkos();
  const runtimeShutdown = shutdownPublisherInkOSRuntime({ waitForActive: true }).catch(err => {
    console.warn('[server] 内置 InkOS 运行时关闭异常:', err.message);
  });
  server.close(async () => {
    await runtimeShutdown;
    if (terminatedChildren > 0) {
      setTimeout(() => process.exit(0), 1800);
    } else {
      process.exit(0);
    }
  });
  setTimeout(() => process.exit(1), 5000).unref();
}

process.once('SIGTERM', () => shutdown('SIGTERM'));
process.once('SIGINT', () => shutdown('SIGINT'));
