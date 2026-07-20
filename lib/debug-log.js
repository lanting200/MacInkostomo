import { appendFileSync, existsSync, mkdirSync, readFileSync, readdirSync, statSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const DEBUG_DIR = join(__dirname, '..', 'data', 'debug');
const EVENTS_FILE = join(DEBUG_DIR, 'events.jsonl');

function ensureDebugDir() {
  if (!existsSync(DEBUG_DIR)) mkdirSync(DEBUG_DIR, { recursive: true });
}

export function debugEvent(scope, message, data = {}, level = 'info') {
  ensureDebugDir();
  const event = {
    ts: new Date().toISOString(),
    level,
    scope,
    message,
    data,
  };
  try {
    appendFileSync(EVENTS_FILE, JSON.stringify(event) + '\n', 'utf-8');
  } catch (err) {
    console.warn('[debug] 写入失败:', err.message);
  }
  return event;
}

export function readDebugEvents(limit = 200) {
  ensureDebugDir();
  if (!existsSync(EVENTS_FILE)) return [];
  const max = Math.min(Math.max(Number(limit) || 200, 1), 2000);
  const raw = readFileSync(EVENTS_FILE, 'utf-8');
  return raw.trim().split('\n').filter(Boolean).slice(-max).map(line => {
    try { return JSON.parse(line); } catch { return { ts: '', level: 'error', scope: 'debug', message: 'bad jsonl', data: { line } }; }
  });
}

export function debugFileInfo() {
  ensureDebugDir();
  const files = readdirSync(DEBUG_DIR).map(name => {
    const p = join(DEBUG_DIR, name);
    const st = statSync(p);
    return { name, size: st.size, mtime: st.mtime.toISOString() };
  }).sort((a, b) => b.mtime.localeCompare(a.mtime));
  return { dir: DEBUG_DIR, eventsFile: EVENTS_FILE, files };
}
