/**
 * Story-memory coherence guard.
 *
 * InkOS maintains a set of "memory" files under <bookId>/story/ that the
 * `inkos write next` pipeline reads as context for the next chapter:
 *   - chapter_summaries.md  (per-chapter one-line digest in a table)
 *   - pending_hooks.md      (open/resolved plot hooks)
 *   - current_state.md      (protagonist status / location / time)
 *   - particle_ledger.md    (item/resource ledger)
 *
 * InkOS's own maintenance of these files is unreliable in practice: chapters
 * get skipped in the summaries table, state cards drift, hooks go stale.
 * When that happens, later chapters lose continuity with earlier ones
 * (contradictions in item locations, duplicated hooks, retconned facts).
 *
 * This module is chapter-publisher's safety net — it does NOT replace
 * InkOS's memory writes, only:
 *   1. verifyMemoryCoverage() — log a warning when the summaries table has
 *      fallen behind the actual chapter count (observable, non-blocking),
 *      so drift is visible in server logs before it silently corrupts a run.
 *   2. backfillChapterSummary() — after a successful `write next`, if InkOS
 *      did not record the new chapter in chapter_summaries.md, publisher
 *      appends a heuristic one-line row so the table never falls behind.
 *
 * The backfill is deliberately conservative: it never overwrites InkOS's own
 * rows, only appends where a chapter number is missing. The digest is built
 * from the chapter text via simple heuristics (no LLM call — keeps this
 * synchronous, cheap, and immune to the API hangs that plague the generate
 * path). A machine-written marker distinguishes backfill rows from InkOS's
 * own so a later InkOS run can recognize and refine them.
 */

import { readFileSync, writeFileSync, existsSync, statSync } from 'fs';
import { join } from 'path';
import { PATHS } from './paths.js';

const BOOKS_DIR = PATHS.BOOKS_DIR;

function storyDir(bookId) {
  return join(BOOKS_DIR, 'books', bookId, 'story');
}

function summariesPath(bookId) {
  return join(storyDir(bookId), 'chapter_summaries.md');
}

// Escape a cell for a markdown table: newlines/pipes become spaces.
function cell(s) {
  return String(s == null ? '' : s).replace(/[\r\n|]/g, ' ').trim();
}

// Truncate to a soft budget, cutting at the last punctuation boundary within it.
function clip(s, max) {
  if (!s) return '';
  if (s.length <= max) return s;
  const slice = s.slice(0, max);
  const cut = Math.max(
    slice.lastIndexOf('。'),
    slice.lastIndexOf('！'),
    slice.lastIndexOf('？'),
    slice.lastIndexOf('；'),
    slice.lastIndexOf(',')
  );
  return (cut > max * 0.5 ? slice.slice(0, cut) : slice).trim();
}

/**
 * Parse chapter_summaries.md and return the set of chapter numbers present
 * plus the max. Returns { nums: Set<number>, max: number, exists: boolean }.
 */
export function getSummaryCoverage(bookId) {
  const p = summariesPath(bookId);
  if (!existsSync(p)) return { nums: new Set(), max: 0, exists: false };
  let text;
  try {
    text = readFileSync(p, 'utf-8');
  } catch {
    return { nums: new Set(), max: 0, exists: false };
  }
  const nums = new Set();
  // Table rows start with "| <number> |". Rows that are separators ("| --- |")
  // or the header are skipped by requiring the first cell to be a pure integer.
  for (const line of text.split('\n')) {
    const m = line.match(/^\|\s*(\d+)\s*\|/);
    if (m) nums.add(Number(m[1]));
  }
  let max = 0;
  for (const n of nums) if (n > max) max = n;
  return { nums, max, exists: true };
}

/**
 * Read the book's chapters/index.json (source of truth for chapter count).
 */
function readIndex(bookId) {
  const p = join(BOOKS_DIR, 'books', bookId, 'chapters', 'index.json');
  if (!existsSync(p)) return [];
  try {
    return JSON.parse(readFileSync(p, 'utf-8'));
  } catch {
    return [];
  }
}

/**
 * Pre-generate check: warn if chapter_summaries.md has fallen behind the
 * actual chapter count. Logs only — does not block generation.
 * Returns { summaryMax, indexMax, gaps: number[] }.
 */
export function verifyMemoryCoverage(bookId) {
  const cov = getSummaryCoverage(bookId);
  const idx = readIndex(bookId);
  const indexMax = idx.reduce((m, c) => Math.max(m, c.number || 0), 0);
  const gaps = [];
  for (const c of idx) {
    if (c.number && !cov.nums.has(c.number)) gaps.push(c.number);
  }
  if (gaps.length > 0) {
    console.warn(
      `[story-memory] ⚠ ${bookId}: chapter_summaries.md 落后于正文。` +
        `正文到第${indexMax}章,摘要覆盖到第${cov.max}章,缺失章节: ${gaps.join(',')}。` +
        `InkOS 生成下一章时上下文可能不完整,留意连贯性。`
    );
  }
  return { summaryMax: cov.max, indexMax, gaps };
}

/**
 * Build a heuristic one-line digest of a chapter's content for the summaries
 * table. No LLM — pulls from first paragraph + last paragraph + title.
 * Returns { characters, keyEvent, stateChange, hooks, mood, type }.
 */
export function buildDigest(title, content) {
  // Strip the markdown "# 第N章 ..." header if present, like importer does.
  let body = content;
  const lines = body.split('\n');
  if (lines[0] && /^#\s*第.*?章/.test(lines[0].trim())) {
    body = lines.slice(1).join('\n').replace(/^\n+/, '');
  }
  // First non-empty prose paragraph as the "what happened" anchor.
  const paras = body.split(/\n\s*\n/).map((p) => p.trim()).filter(Boolean);
  const first = paras[0] || '';
  const last = paras[paras.length - 1] || '';
  // Key event: lead with title + first paragraph's opening.
  const keyEvent = clip(`${title ? title + '——' : ''}${first}`, 140);
  // State change: end paragraph (how the chapter closes) clipped.
  const stateChange = clip(last, 60) || '（待补）';
  // Crude mood/type detection by keyword — good enough to seed the row.
  const full = (title + ' ' + body).slice(0, 4000);
  let mood = '待补';
  if (/笑|自嘲|吐槽|嘀咕/.test(full)) mood = '务实·冷幽默';
  else if (/紧|危|死|险|惧/.test(full)) mood = '紧张·危机';
  let type = '剧情章';
  if (/修炼|周天|胎息|内气|画符/.test(full)) type = '修炼章';
  else if (/探|查|寻|入|进后山|石室/.test(full)) type = '探索章';
  else if (/战|斗|击退|杀|攻/.test(full)) type = '战斗章';
  return {
    characters: '（待 InkOS 细化）',
    keyEvent: keyEvent || '（待补）',
    stateChange,
    hooks: 'publisher自动补写,待InkOS细化',
    mood,
    type,
  };
}

/**
 * Post-generate backfill: if chapter `num` is missing from
 * chapter_summaries.md, append a heuristic row. Idempotent — if the row
 * already exists (InkOS wrote it, or a previous backfill did), no-op.
 *
 * @returns { backfilled: boolean, reason: string }
 */
export function backfillChapterSummary(bookId, num, title, content) {
  const p = summariesPath(bookId);
  const cov = getSummaryCoverage(bookId);
  if (cov.nums.has(num)) {
    return { backfilled: false, reason: 'already present' };
  }
  // If the file doesn't exist at all, InkOS's project structure is broken —
  // create a minimal table so the row has somewhere to live.
  if (!cov.exists) {
    const header =
      '# 章节摘要\n\n' +
      '| 章节 | 标题 | 出场人物 | 关键事件 | 状态变化 | 伏笔动态 | 情绪基调 | 章节类型 |\n' +
      '| --- | --- | --- | --- | --- | --- | --- | --- |\n';
    try {
      writeFileSync(p, header, 'utf-8');
    } catch (err) {
      return { backfilled: false, reason: `create failed: ${err.message}` };
    }
  }
  const d = buildDigest(title, content);
  const row =
    `| ${num} | ${cell(title)} | ${cell(d.characters)} | ${cell(d.keyEvent)} | ` +
    `${cell(d.stateChange)} | ${cell(d.hooks)} | ${cell(d.mood)} | ${cell(d.type)} |\n`;
  try {
    const prev = existsSync(p) ? readFileSync(p, 'utf-8') : '';
    // Ensure file ends with a newline before appending.
    const sep = prev && !prev.endsWith('\n') ? '\n' : '';
    writeFileSync(p, prev + sep + row, 'utf-8');
  } catch (err) {
    return { backfilled: false, reason: `append failed: ${err.message}` };
  }
  console.log(
    `[story-memory] ✓ ${bookId}: InkOS 未记录第${num}章摘要,publisher 已补写一行(机器摘要,待细化)。`
  );
  return { backfilled: true, reason: 'appended' };
}
