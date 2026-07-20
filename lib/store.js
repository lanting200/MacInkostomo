import { chmodSync, readFileSync, writeFileSync, existsSync, mkdirSync, renameSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { STATUS, wordCount } from './status.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const DATA_DIR = join(__dirname, '..', 'data');
const STATE_FILE = join(DATA_DIR, 'state.json');

function ensureDirs() {
  if (!existsSync(DATA_DIR)) mkdirSync(DATA_DIR, { recursive: true });
}

function emptyState() {
  return { books: {}, fanqieMap: {} };
}

function stateDataError(message, cause) {
  const err = new Error(message);
  err.code = 'STATE_DATA_INVALID';
  err.cause = cause;
  return err;
}

function backUpInvalidState(raw) {
  try {
    writeFileSync(STATE_FILE + '.corrupt-' + Date.now(), raw, { encoding: 'utf-8', mode: 0o600 });
  } catch { /* preserve the original even if the extra backup fails */ }
}

// Missing state initializes cleanly. Damaged state is backed up and surfaced as
// an error so a later mutation never replaces user data with an empty object.
export function loadState() {
  ensureDirs();
  if (!existsSync(STATE_FILE)) {
    const empty = emptyState();
    saveState(empty);
    return empty;
  }
  let raw;
  try {
    chmodSync(STATE_FILE, 0o600);
    raw = readFileSync(STATE_FILE, 'utf-8');
  } catch (err) {
    console.error('[store] 无法读取 state.json:', err.message);
    throw stateDataError(`无法读取状态文件，请检查 data/state.json: ${err.message}`, err);
  }
  try {
    const parsed = JSON.parse(raw);
    // Defensive: ensure the expected shape so downstream Object.entries etc. don't throw.
    if (!parsed || typeof parsed !== 'object' || !parsed.books || typeof parsed.books !== 'object') {
      backUpInvalidState(raw);
      throw stateDataError('状态文件结构异常：缺少 books 对象');
    }
    // Backfill fanqieMap for older states that predate the 番茄 online view.
    if (!parsed.fanqieMap || typeof parsed.fanqieMap !== 'object') {
      parsed.fanqieMap = {};
    }
    return parsed;
  } catch (err) {
    if (err?.code === 'STATE_DATA_INVALID') throw err;
    console.error('[store] state.json 解析失败，已备份并停止写入:', err.message);
    backUpInvalidState(raw);
    throw stateDataError(`状态文件解析失败，请从备份恢复 data/state.json: ${err.message}`, err);
  }
}

// Atomic save: write to a temp file then rename. A crash mid-write leaves the
// temp file (not state.json) truncated, so the last good state survives.
export function saveState(state) {
  ensureDirs();
  const tmp = STATE_FILE + '.tmp';
  writeFileSync(tmp, JSON.stringify(state, null, 2), { encoding: 'utf-8', mode: 0o600 });
  renameSync(tmp, STATE_FILE);
}

export function getBook(state, bookId) {
  if (!state.books[bookId]) return null;
  return state.books[bookId];
}

export function ensureBook(state, bookId, title) {
  if (!state.books[bookId]) {
    state.books[bookId] = { title, chapters: [] };
  }
  return state.books[bookId];
}

export function getChapter(book, num) {
  return book.chapters.find(c => c.number === num) || null;
}

export function mergeBookChapterSnapshot(latestBook, sourceBook, options = {}) {
  if (!latestBook || !sourceBook) throw new Error('合并章节状态时缺少书籍快照');
  const chapterNumbers = Array.from(new Set(options.chapterNumbers || []));
  if (chapterNumbers.length === 0) throw new Error('合并章节状态时未指定目标章节');

  latestBook.chapters = Array.isArray(latestBook.chapters) ? latestBook.chapters : [];
  for (const chapterNum of chapterNumbers) {
    const sourceChapter = getChapter(sourceBook, chapterNum);
    if (!sourceChapter) throw new Error(`合并章节状态时第${chapterNum}章已不存在`);
    const index = latestBook.chapters.findIndex(chapter => chapter.number === chapterNum);
    if (index >= 0) latestBook.chapters[index] = sourceChapter;
    else latestBook.chapters.push(sourceChapter);
  }

  const removeChapterNumbers = new Set(options.removeChapterNumbers || []);
  if (removeChapterNumbers.size > 0) {
    latestBook.chapters = latestBook.chapters.filter(chapter => {
      if (!removeChapterNumbers.has(chapter.number)) return true;
      return chapter.status === STATUS.APPROVED || chapter.status === STATUS.PUBLISHED;
    });
  }
  latestBook.chapters.sort((a, b) => a.number - b.number);
  if (sourceBook.updatedAt) latestBook.updatedAt = sourceBook.updatedAt;
  return latestBook;
}

// In-memory upsert (no disk write). Callers that batch many updates (e.g.
// importer looping over hundreds of chapters) should use this and saveState
// once at the end, instead of writing the whole file N times.
export function upsertChapterInMemory(state, bookId, chapterData) {
  const book = ensureBook(state, bookId, chapterData.bookTitle || bookId);
  const existing = book.chapters.find(c => c.number === chapterData.number);
  if (existing) {
    existing.title = chapterData.title;
    if (chapterData.content !== undefined && existing.content !== chapterData.content) {
      existing.content = chapterData.content;
      existing.wordCount = wordCount(chapterData.content);
      existing.status = STATUS.PENDING_REVIEW;
      existing.publishedAt = null;
    }
    existing.updatedAt = new Date().toISOString();
  } else {
    book.chapters.push({
      number: chapterData.number,
      title: chapterData.title,
      content: chapterData.content || '',
      status: STATUS.PENDING_REVIEW,
      reviewNotes: '',
      revisionHistory: [],
      publishedAt: null,
      wordCount: wordCount(chapterData.content || ''),
      volume: chapterData.volume || null,
      volumeTitle: chapterData.volumeTitle || null,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString()
    });
  }
  return getChapter(book, chapterData.number);
}

export function upsertChapter(state, bookId, chapterData) {
  const result = upsertChapterInMemory(state, bookId, chapterData);
  saveState(state);
  return result;
}
