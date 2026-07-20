import { readdirSync, readFileSync, existsSync } from 'fs';
import { join } from 'path';
import { upsertChapterInMemory, saveState } from './store.js';
import { assertBookId, PATHS } from './paths.js';

const BOOKS_DIR = PATHS.BOOKS_SUBDIR;

export function listAvailableBooks() {
  if (!existsSync(BOOKS_DIR)) return [];
  return readdirSync(BOOKS_DIR, { withFileTypes: true })
    .filter(d => d.isDirectory())
    .map(d => d.name)
    .filter(name => {
      try { assertBookId(name); return true; } catch { return false; }
    });
}

export function importBook(state, bookId) {
  const safeBookId = assertBookId(bookId);
  const bookPath = join(BOOKS_DIR, safeBookId);
  if (!existsSync(bookPath)) throw new Error(`书籍目录不存在: ${bookPath}`);

  // Read book.json
  const bookJsonPath = join(bookPath, 'book.json');
  let bookTitle = safeBookId;
  if (existsSync(bookJsonPath)) {
    const bookJson = JSON.parse(readFileSync(bookJsonPath, 'utf-8'));
    bookTitle = bookJson.title || safeBookId;
  }

  // Read chapters
  const chaptersDir = join(bookPath, 'chapters');
  if (!existsSync(chaptersDir)) throw new Error(`章节目录不存在: ${chaptersDir}`);

  // Read index.json if exists
  const indexPath = join(chaptersDir, 'index.json');
  let indexData = [];
  if (existsSync(indexPath)) {
    indexData = JSON.parse(readFileSync(indexPath, 'utf-8'));
    if (!Array.isArray(indexData)) throw new Error(`章节索引格式错误: ${indexPath}`);
  }

  const files = readdirSync(chaptersDir)
    .filter(f => f.endsWith('.md') || f.endsWith('.txt'))
    .sort();
  const records = files.map(file => ({
    file,
    content: readFileSync(join(chaptersDir, file), 'utf-8'),
  }));
  const reservedNums = new Set(indexData.map(entry => entry?.number).filter(Number.isSafeInteger));
  for (const { file, content } of records) {
    const fileNum = file.match(/^(\d+)_/)?.[1];
    const headerNum = content.match(/^#\s*第(\d+)章/m)?.[1];
    const parsed = Number(fileNum || headerNum);
    if (Number.isSafeInteger(parsed) && parsed > 0) reservedNums.add(parsed);
  }
  let nextFallbackNum = reservedNums.size > 0 ? Math.max(...reservedNums) + 1 : 1;

  const imported = [];
  const importedNums = new Set();
  for (const { file, content } of records) {

    // Parse chapter number and title from filename: 0001_香灭之后.md
    const match = file.match(/^(\d+)_(.+?)\.(md|txt)$/);
    let num, title;
    if (match) {
      num = parseInt(match[1], 10);
      title = match[2];
    } else {
      // Try to parse from content first line: # 第1章 香灭之后
      const lineMatch = content.match(/^#\s*第(\d+)章\s*(.*)/m);
      if (lineMatch) {
        num = parseInt(lineMatch[1], 10);
        title = lineMatch[2].trim();
      } else {
        // Filename and content header both failed to yield a number.
        // Pick max(existing parsed numbers, already-imported) + 1 so we never
        // collide with and overwrite a previously parsed chapter.
        while (reservedNums.has(nextFallbackNum) || importedNums.has(nextFallbackNum)) nextFallbackNum += 1;
        num = nextFallbackNum;
        reservedNums.add(num);
        nextFallbackNum += 1;
        title = file.replace(/\.(md|txt)$/, '');
        console.warn(`[importBook] 无法从文件名或内容解析章节号，文件 "${file}" 分配为第 ${num} 章`);
      }
    }

    if (importedNums.has(num)) {
      throw new Error(`发现重复章节号 ${num}，请先修正文件名或章节标题: ${file}`);
    }
    importedNums.add(num);

    // Also try to extract title from index.json
    const indexEntry = indexData.find(e => e.number === num);
    if (indexEntry && indexEntry.title) {
      title = indexEntry.title;
    }

    // Strip the first line if it's a markdown header with chapter info
    let bodyContent = content;
    const lines = content.split('\n');
    if (lines[0] && /^#\s*第.*?章/.test(lines[0].trim())) {
      bodyContent = lines.slice(1).join('\n').replace(/^\n+/, '');
    }

    const chapter = upsertChapterInMemory(state, safeBookId, {
      number: num,
      title,
      content: bodyContent,
      bookTitle
    });
    imported.push({ number: num, title, wordCount: chapter.wordCount });
  }

  // Single atomic write for the whole import (was: one write per chapter).
  saveState(state);
  return { bookId: safeBookId, bookTitle, imported };
}
