import {
  appendFileSync,
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  statSync,
  unlinkSync,
} from 'fs';
import { dirname, join, resolve } from 'path';
import { fileURLToPath } from 'url';
import { EventEmitter } from 'events';

const __dirname = dirname(fileURLToPath(import.meta.url));
const DEBUG_DIR = process.env.PUBLISHER_DEBUG_DIR
  ? resolve(process.env.PUBLISHER_DEBUG_DIR)
  : join(__dirname, '..', 'data', 'debug');
const EVENTS_FILE = join(DEBUG_DIR, 'events.jsonl');
const EVENT_FILE_PREFIX = 'events.';
const EVENT_FILE_SUFFIX = '.jsonl';
const MAX_EVENT_FILE_BYTES = 16 * 1024 * 1024;
const MAX_ROTATED_FILES = 5;
const MAX_QUERY_LIMIT = 5_000;
const EVENT_SCHEMA_VERSION = 2;
const LEGACY_SEQUENCE_SCALE = 1_024;

let sequence = null;
export const debugEvents = new EventEmitter();
debugEvents.setMaxListeners(0);

function ensureDebugDir() {
  if (!existsSync(DEBUG_DIR)) mkdirSync(DEBUG_DIR, { recursive: true, mode: 0o700 });
}

/**
 * Append one redacted, versioned event. This function is synchronous on
 * purpose: sequence order must match the order visible to the running job.
 * A failed diagnostic write never interrupts the business workflow.
 */
export function debugEvent(scope, message, data = {}, level = 'info', context = {}) {
  const event = normalizeEvent({
    ...context,
    scope,
    component: context.component || scope,
    message,
    data,
    level,
    phase: context.phase || 'diagnostic',
    ts: new Date().toISOString(),
  });
  appendEvent(event);
  return event;
}

/** Ingest an event emitted by the built-in InkOS framework child process. */
export function ingestDebugEvent(raw, defaults = {}) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const event = normalizeEvent({
    ...defaults,
    ...raw,
    scope: raw.scope || raw.component || defaults.scope || 'inkos',
    component: raw.component || raw.scope || defaults.component || 'inkos',
    message: raw.message || `${raw.operation || 'event'} ${raw.phase || ''}`.trim(),
    level: raw.level || 'info',
    ts: raw.ts || raw.timestamp || new Date().toISOString(),
  });
  appendEvent(event);
  return event;
}

/**
 * Query a bounded window. `afterSequence` and `beforeSequence` make this
 * suitable for an agent polling loop without repeatedly downloading history.
 */
export function queryDebugEvents(options = {}) {
  ensureDebugDir();
  const limit = Math.min(Math.max(Number(options.limit) || 300, 1), MAX_QUERY_LIMIT);
  const afterSequence = parseCursor(options.afterSequence ?? options.after);
  const beforeSequence = parseCursor(options.beforeSequence ?? options.before);
  const files = eventFiles();
  const all = [];
  for (const file of files) {
    if (!existsSync(file)) continue;
    const raw = readBoundedFile(file);
    const lines = raw.split(/\r?\n/);
    for (const [lineIndex, line] of lines.entries()) {
      if (!line.trim()) continue;
      try {
        const event = normalizeEvent(JSON.parse(line), {
          allocateSequence: false,
          legacyKey: `${lineIndex}:${line}`,
        });
        if (afterSequence !== null && event.sequence <= afterSequence) continue;
        if (beforeSequence !== null && event.sequence >= beforeSequence) continue;
        if (!matchesEvent(event, options)) continue;
        all.push(event);
      } catch {
        const invalidSequence = legacySequenceNumber({}, `${lineIndex}:${line}`);
        all.push({
          schemaVersion: EVENT_SCHEMA_VERSION,
          eventId: `invalid-${Math.abs(stableHash(`${lineIndex}:${line}`))}`,
          sequence: invalidSequence,
          ts: '',
          timestamp: '',
          level: 'error',
          scope: 'debug',
          component: 'debug',
          operation: 'parse',
          phase: 'failure',
          message: 'invalid JSONL event',
          data: { source: file },
        });
      }
    }
  }
  all.sort((left, right) => left.sequence - right.sequence || left.ts.localeCompare(right.ts));
  const selected = beforeSequence !== null
    ? all.slice(Math.max(0, all.length - limit))
    : all.slice(-limit);
  const oldestSequence = all[0]?.sequence ?? null;
  const newestSequence = all.at(-1)?.sequence ?? null;
  return {
    events: selected,
    cursor: {
      oldestSequence,
      newestSequence,
      nextAfter: selected.at(-1)?.sequence ?? newestSequence,
      nextBefore: selected[0]?.sequence ?? oldestSequence,
    },
    hasMore: beforeSequence !== null
      ? all.length > selected.length
      : Boolean(afterSequence !== null && selected.length === limit && newestSequence !== selected.at(-1)?.sequence),
  };
}

export function readDebugEvents(limit = 200) {
  return queryDebugEvents({ limit }).events;
}

export function debugFileInfo() {
  ensureDebugDir();
  const files = readdirSync(DEBUG_DIR).map(name => {
    const path = join(DEBUG_DIR, name);
    const stat = statSync(path);
    return { name, size: stat.size, mtime: stat.mtime.toISOString() };
  }).sort((a, b) => b.mtime.localeCompare(a.mtime));
  return {
    dir: DEBUG_DIR,
    eventsFile: EVENTS_FILE,
    schemaVersion: EVENT_SCHEMA_VERSION,
    maxEventFileBytes: MAX_EVENT_FILE_BYTES,
    maxRotatedFiles: MAX_ROTATED_FILES,
    currentSequence: currentSequence(),
    files,
  };
}

export function debugSchema() {
  return {
    schemaVersion: EVENT_SCHEMA_VERSION,
    cursor: 'sequence',
    fields: {
      sequence: 'monotonic integer',
      eventId: 'unique string',
      ts: 'ISO-8601 timestamp',
      level: ['debug', 'info', 'warn', 'error'],
      scope: 'legacy-compatible component name',
      component: 'framework component',
      operation: 'stable operation id',
      phase: ['start', 'progress', 'success', 'failure', 'diagnostic'],
      traceId: 'workflow trace id',
      spanId: 'operation span id',
      parentSpanId: 'optional parent span id',
      bookId: 'optional book id',
      chapterNumber: 'optional positive integer',
      durationMs: 'optional elapsed milliseconds',
      data: 'redacted structured payload',
      error: 'redacted serializable error',
    },
    limits: { maxQueryLimit: MAX_QUERY_LIMIT, maxEventFileBytes: MAX_EVENT_FILE_BYTES },
  };
}

export function debugHealth() {
  try {
    ensureDebugDir();
    const info = debugFileInfo();
    return { status: 'healthy', writable: true, sequence: info.currentSequence, files: info.files.length };
  } catch (error) {
    return { status: 'failed', writable: false, error: String(error?.message || error) };
  }
}

function appendEvent(event) {
  try {
    ensureDebugDir();
    rotateIfNeeded();
    appendFileSync(EVENTS_FILE, `${JSON.stringify(event)}\n`, { encoding: 'utf-8', mode: 0o600 });
    chmodSync(EVENTS_FILE, 0o600);
    debugEvents.emit('event', event);
  } catch (error) {
    // Keep the old console signal for operators, but do not throw into a job.
    console.warn('[debug] 写入失败:', error.message);
  }
}

function normalizeEvent(raw, options = {}) {
  const ts = String(raw.ts || raw.timestamp || new Date().toISOString());
  const nextSequence = raw.sequence ?? raw.seq;
  const numericSequence = Number(nextSequence);
  const normalizedSequence = Number.isSafeInteger(numericSequence) && numericSequence > 0
    ? numericSequence
    : options.allocateSequence === false
      ? legacySequenceNumber(raw, options.legacyKey)
      : nextSequenceNumber();
  if (options.allocateSequence !== false && (sequence === null || normalizedSequence > sequence)) {
    sequence = normalizedSequence;
  }
  const scope = String(raw.scope || raw.component || 'debug');
  const component = String(raw.component || scope);
  const rawLevel = String(raw.level || 'info').toLowerCase();
  const level = rawLevel === 'warning' ? 'warn' : rawLevel === 'critical' ? 'error'
    : ['debug', 'info', 'warn', 'error'].includes(rawLevel) ? rawLevel : 'info';
  const rawPhase = String(raw.phase || raw.status || '').toLowerCase();
  const phase = rawPhase === 'started' ? 'start'
    : rawPhase === 'succeeded' || rawPhase === 'compensated' ? 'success'
      : rawPhase === 'failed' ? 'failure'
        : ['retrying', 'compensating', 'degraded'].includes(rawPhase) ? 'progress'
          : ['start', 'progress', 'success', 'failure', 'diagnostic'].includes(rawPhase) ? rawPhase : 'diagnostic';
  const diagnosticData = {
    ...(raw.data && typeof raw.data === 'object' && !Array.isArray(raw.data) ? raw.data : {}),
    ...(raw.moduleId ? { moduleId: raw.moduleId } : {}),
    ...(raw.workflow ? { workflow: raw.workflow } : {}),
    ...(raw.stage ? { stage: raw.stage } : {}),
    ...(raw.jobId ? { jobId: raw.jobId } : {}),
    ...(raw.status ? { frameworkStatus: raw.status } : {}),
    ...(raw.attempt ? { attempt: raw.attempt } : {}),
  };
  const data = Object.keys(diagnosticData).length > 0 ? sanitizeValue(diagnosticData, 0) : undefined;
  const message = sanitizeValue(String(raw.message || ''), 0);
  const operation = sanitizeValue(String(raw.operation || raw.stage || raw.type || message || 'event'), 0);
  return {
    schemaVersion: EVENT_SCHEMA_VERSION,
    eventId: String(raw.eventId || raw.id || (options.allocateSequence === false
      ? `legacy-${normalizedSequence}-${Math.abs(stableHash(options.legacyKey || JSON.stringify(raw)))}`
      : `event-${normalizedSequence}-${Date.now().toString(36)}`)),
    sequence: normalizedSequence,
    ts,
    timestamp: String(raw.timestamp || ts),
    level,
    scope,
    component,
    operation,
    phase,
    message,
    ...(raw.traceId ? { traceId: String(raw.traceId) } : {}),
    ...(raw.spanId ? { spanId: String(raw.spanId) } : {}),
    ...(raw.parentSpanId ? { parentSpanId: String(raw.parentSpanId) } : {}),
    ...(raw.bookId ? { bookId: String(raw.bookId) } : {}),
    ...(Number.isSafeInteger(Number(raw.chapterNumber)) ? { chapterNumber: Number(raw.chapterNumber) } : {}),
    ...(Number.isFinite(Number(raw.durationMs)) ? { durationMs: Number(raw.durationMs) } : {}),
    ...(data ? { data } : {}),
    ...(raw.error ? { error: sanitizeValue(raw.error, 0) } : {}),
  };
}

function nextSequenceNumber() {
  if (sequence === null) sequence = discoverLastSequence();
  sequence += 1;
  return sequence;
}

function currentSequence() {
  if (sequence === null) sequence = discoverLastSequence();
  return sequence || 0;
}

function discoverLastSequence() {
  let latest = 0;
  for (const file of eventFiles()) {
    try {
      const lines = readBoundedFile(file).trim().split(/\r?\n/).reverse();
      for (const line of lines) {
        if (!line) continue;
        const parsed = JSON.parse(line);
        const value = Number(parsed.sequence ?? parsed.seq);
        if (Number.isSafeInteger(value) && value > 0) {
          latest = Math.max(latest, value);
          break;
        }
      }
    } catch {
      // A damaged line is surfaced by query; it must not stop new logging.
    }
  }
  return latest;
}

function rotateIfNeeded() {
  if (!existsSync(EVENTS_FILE)) return;
  if (statSync(EVENTS_FILE).size < MAX_EVENT_FILE_BYTES) return;
  const rotated = join(DEBUG_DIR, `${EVENT_FILE_PREFIX}${Date.now()}${EVENT_FILE_SUFFIX}`);
  renameSync(EVENTS_FILE, rotated);
  const rotatedFiles = readdirSync(DEBUG_DIR)
    .filter(name => name.startsWith(EVENT_FILE_PREFIX) && name.endsWith(EVENT_FILE_SUFFIX) && name !== 'events.jsonl')
    .sort()
    .reverse();
  for (const name of rotatedFiles.slice(MAX_ROTATED_FILES)) {
    try { unlinkSync(join(DEBUG_DIR, name)); } catch {}
  }
}

function eventFiles() {
  ensureDebugDir();
  const rotated = readdirSync(DEBUG_DIR)
    .filter(name => name.startsWith(EVENT_FILE_PREFIX) && name.endsWith(EVENT_FILE_SUFFIX) && name !== 'events.jsonl')
    .sort()
    .map(name => join(DEBUG_DIR, name));
  return [...rotated, EVENTS_FILE];
}

function readBoundedFile(file) {
  const stat = statSync(file);
  const maxBytes = MAX_EVENT_FILE_BYTES + 1024;
  if (stat.size <= maxBytes) return readFileSync(file, 'utf-8');
  return readFileSync(file, 'utf-8').slice(-maxBytes);
}

function matchesEvent(event, options) {
  const levels = options.level || options.levels;
  if (levels) {
    const accepted = Array.isArray(levels) ? levels : String(levels).split(',');
    if (!accepted.includes(event.level)) return false;
  }
  const component = options.component || options.scope;
  if (component && event.component !== String(component)) return false;
  if (options.operation && event.operation !== String(options.operation)) return false;
  if (options.traceId && event.traceId !== String(options.traceId)) return false;
  if (options.bookId && event.bookId !== String(options.bookId)) return false;
  if (options.chapterNumber !== undefined && event.chapterNumber !== Number(options.chapterNumber)) return false;
  if (options.text) {
    const haystack = `${event.message} ${JSON.stringify(event.data || {})}`.toLowerCase();
    if (!haystack.includes(String(options.text).toLowerCase())) return false;
  }
  return true;
}

function parseCursor(value) {
  if (value === undefined || value === null || value === '') return null;
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) ? parsed : null;
}

function legacySequenceNumber(raw, key = '') {
  const timestamp = Date.parse(String(raw?.ts || raw?.timestamp || ''));
  const tieBreaker = Math.abs(stableHash(key || JSON.stringify(raw))) % LEGACY_SEQUENCE_SCALE;
  if (Number.isSafeInteger(timestamp)) {
    const candidate = Number.MIN_SAFE_INTEGER + timestamp * LEGACY_SEQUENCE_SCALE + tieBreaker;
    if (Number.isSafeInteger(candidate) && candidate < 0) return candidate;
  }
  return Number.MIN_SAFE_INTEGER + tieBreaker;
}

function stableHash(value) {
  let hash = 0x811c9dc5;
  for (const char of String(value)) {
    hash ^= char.codePointAt(0);
    hash = Math.imul(hash, 0x01000193);
  }
  return hash | 0;
}

function sanitizeValue(value, depth) {
  if (depth > 5) return '[depth-limit]';
  if (typeof value === 'string') {
    const redacted = value
      .replace(
        /(api[-_ ]?key|token|authorization|cookie|password|secret)\s*[:=]\s*(?:"[^"]*"|'[^']*'|Bearer\s+[^\s,;]+|[^\s,;]+)/gi,
        '$1=[redacted]',
      )
      .replace(/Bearer\s+[A-Za-z0-9._~-]+/gi, 'Bearer [redacted]')
      .replace(/\b(?:sk|xai)-[A-Za-z0-9_-]{12,}\b/gi, '[redacted-key]');
    return redacted.length > 8_000 ? `${redacted.slice(0, 8_000)}...[truncated]` : redacted;
  }
  if (value === null || typeof value === 'number' || typeof value === 'boolean') return value;
  if (typeof value === 'bigint') return String(value);
  if (Array.isArray(value)) return value.slice(0, 256).map(item => sanitizeValue(item, depth + 1));
  if (typeof value === 'object') {
    const result = {};
    for (const [key, child] of Object.entries(value).slice(0, 256)) {
      result[key] = /api[-_ ]?key|token|authorization|cookie|password|secret/i.test(key)
        ? '[redacted]'
        : sanitizeValue(child, depth + 1);
    }
    return result;
  }
  return String(value);
}
