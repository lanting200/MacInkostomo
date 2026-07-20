import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const html = readFileSync(join(ROOT, 'public', 'index.html'), 'utf-8');
const app = readFileSync(join(ROOT, 'public', 'app.js'), 'utf-8');
const server = readFileSync(join(ROOT, 'server.js'), 'utf-8');

test('debug workbench exposes all query controls and structured result regions', () => {
  for (const id of [
    'debugLevel',
    'debugComponent',
    'debugTraceId',
    'debugBookId',
    'debugChapterNumber',
    'debugLimit',
    'debugLiveToggle',
    'debugPanel',
    'debugJobsList',
    'debugFilesList',
  ]) {
    assert.equal((html.match(new RegExp(`id="${id}"`, 'g')) || []).length, 1, `${id} should exist once`);
  }
  assert.match(html, /role="log"/);
  assert.match(app, /<article class="debug-event-row"/);
  assert.match(app, /debug-event-details/);
});

test('debug workbench maps filters to HTTP, SSE, and JSONL contracts', () => {
  for (const key of ['level', 'component', 'traceId', 'bookId', 'chapterNumber', 'text']) {
    assert.match(app, new RegExp(`['"]${key}['"]`));
  }
  assert.match(app, /new EventSource\(`\$\{API\}\/debug\/stream/);
  assert.match(app, /addEventListener\('diagnostic'/);
  assert.match(app, /format', format/);
  assert.match(app, /application\/x-ndjson/);
  assert.match(server, /app\.get\('\/api\/debug\/stream'/);
  assert.match(server, /req\.query\.format === 'jsonl'/);
});

test('debug stream has explicit lifecycle and bounded event retention', () => {
  assert.match(app, /function closeDebugStream\(\)/);
  assert.match(app, /debugEventSource\.close\(\)/);
  assert.match(app, /slice\(-currentValues\.limit\)/);
  assert.match(app, /setTimeout\(startDebugStream, 1500\)/);
});
