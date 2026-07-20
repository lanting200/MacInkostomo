import { join } from 'path';
import { dirname } from 'path';
import { fileURLToPath } from 'url';

// Centralized filesystem paths. Previously each module hardcoded its own copy,
// which led to drift (e.g. importer pointed at .../books while inkos/publisher
// pointed at the parent .../Book). Update here only.
const HOME = process.env.HOME;
const __dirname = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = join(__dirname, '..');
const BOOKS_SUBDIR = join(PROJECT_ROOT, 'book', 'books');

export function assertBookId(bookId) {
  const id = String(bookId ?? '');
  if (!id.trim() || id === '.' || id === '..' || /[\\/\u0000-\u001f]/.test(id)) {
    const err = new Error('非法书籍 ID');
    err.code = 'INVALID_BOOK_ID';
    err.statusCode = 400;
    throw err;
  }
  return id;
}

export function bookPath(bookId, ...segments) {
  return join(BOOKS_SUBDIR, assertBookId(bookId), ...segments);
}

export const PATHS = {
  // InkOS book workspace. Book source files live under <BOOKS_DIR>/books/<bookId>/chapters/.
  BOOKS_DIR: join(PROJECT_ROOT, 'book'),
  BOOKS_SUBDIR,
  // Per-book story memory dir (InkOS-maintained coherence files:
  // chapter_summaries.md, pending_hooks.md, current_state.md, particle_ledger.md, etc.).
  // Path: <BOOKS_DIR>/books/<bookId>/story/
  STORY_DIR: (bookId) => bookPath(bookId, 'story'),
  // Knowledge corpus (196 ancient texts).
  WIKI_SOURCES_DIR: join(HOME, '.openclaw', 'wiki', 'main', 'sources'),
  // OpenClaw workspace memory.
  WORKSPACE_DIR: join(HOME, 'Desktop', 'openclaw-workspace'),
  MEMORY_FILE: join(HOME, 'Desktop', 'openclaw-workspace', 'MEMORY.md'),
  MEMORY_DIR: join(HOME, 'Desktop', 'openclaw-workspace', 'memory'),
  // Sibling publishing tool.
  FANQIE_DIR: join(HOME, 'Desktop', 'openclaw-workspace', 'fanqie_auto_publish'),
  // Playwright storage_state (cookies+localStorage) for 番茄 writer backend.
  FANQIE_STATE_FILE: join(HOME, 'Desktop', 'openclaw-workspace', 'fanqie_auto_publish', 'state.json'),
};
