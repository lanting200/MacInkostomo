import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

test('structured diagnostics redact secrets and support cursor filters', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'macingkostomo-debug-'));
  const previous = process.env.PUBLISHER_DEBUG_DIR;
  process.env.PUBLISHER_DEBUG_DIR = directory;
  try {
    const debug = await import(`../lib/debug-log.js?test=${Date.now()}`);
    const first = debug.debugEvent(
      'generation',
      'started',
      { token: 'TOP_SECRET', value: 1 },
      'info',
      { traceId: 'trace-a', spanId: 'span-a', operation: 'chapter.generate', phase: 'start', bookId: 'book-a' },
    );
    const second = debug.ingestDebugEvent({
      component: 'inkos.writer',
      operation: 'draft',
      phase: 'success',
      message: 'finished Authorization: Bearer MESSAGE_SECRET api_key=KEY_SECRET sk-1234567890ABCDEF',
      level: 'info',
      traceId: 'trace-a',
      spanId: 'span-b',
      bookId: 'book-a',
      chapterNumber: 2,
      data: { authorization: 'Bearer SHOULD_HIDE', words: 3000 },
    });

    assert.ok(second);
    assert.equal(second.sequence, first.sequence + 1);
    const filtered = debug.queryDebugEvents({ after: first.sequence, traceId: 'trace-a', limit: 10 });
    assert.equal(filtered.events.length, 1);
    assert.equal(filtered.events[0].component, 'inkos.writer');
    assert.equal(filtered.events[0].data.authorization, '[redacted]');
    assert.doesNotMatch(filtered.events[0].message, /MESSAGE_SECRET|KEY_SECRET|sk-1234567890ABCDEF/);
    assert.match(filtered.events[0].message, /\[redacted/);
    assert.equal(filtered.cursor.nextAfter, second.sequence);
    assert.equal(debug.debugSchema().cursor, 'sequence');
    assert.equal(statSync(join(directory, 'events.jsonl')).mode & 0o777, 0o600);
    assert.doesNotMatch(
      readFileSync(join(directory, 'events.jsonl'), 'utf-8'),
      /TOP_SECRET|SHOULD_HIDE|MESSAGE_SECRET|KEY_SECRET|sk-1234567890ABCDEF/,
    );
  } finally {
    if (previous === undefined) delete process.env.PUBLISHER_DEBUG_DIR;
    else process.env.PUBLISHER_DEBUG_DIR = previous;
    rmSync(directory, { recursive: true, force: true });
  }
});

test('legacy JSONL queries keep cursor and event IDs stable without consuming sequence numbers', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'macingkostomo-debug-legacy-'));
  const previous = process.env.PUBLISHER_DEBUG_DIR;
  process.env.PUBLISHER_DEBUG_DIR = directory;
  try {
    writeFileSync(join(directory, 'events.jsonl'), [
      JSON.stringify({ ts: '2026-01-01T00:00:00.000Z', scope: 'legacy', message: 'first' }),
      JSON.stringify({ timestamp: '2026-01-01T00:00:01.000Z', component: 'legacy', message: 'second' }),
      JSON.stringify({ sequence: 7, ts: '2026-01-01T00:00:02.000Z', scope: 'current', message: 'third' }),
      '',
    ].join('\n'), { mode: 0o600 });

    const debug = await import(`../lib/debug-log.js?legacy=${Date.now()}`);
    const first = debug.queryDebugEvents({ limit: 10 });
    const second = debug.queryDebugEvents({ limit: 10 });

    assert.deepEqual(
      second.events.map(event => ({ sequence: event.sequence, eventId: event.eventId })),
      first.events.map(event => ({ sequence: event.sequence, eventId: event.eventId })),
    );
    assert.deepEqual(second.cursor, first.cursor);
    assert.equal(first.cursor.newestSequence, 7);
    assert.ok(first.events[0].sequence < 0);
    assert.deepEqual(
      debug.queryDebugEvents({ after: first.events[0].sequence, limit: 10 }).events.map(event => event.message),
      ['second', 'third'],
    );
    assert.equal(debug.debugFileInfo().currentSequence, 7);

    const appended = debug.debugEvent('current', 'fourth');
    assert.equal(appended.sequence, 8);
  } finally {
    if (previous === undefined) delete process.env.PUBLISHER_DEBUG_DIR;
    else process.env.PUBLISHER_DEBUG_DIR = previous;
    rmSync(directory, { recursive: true, force: true });
  }
});
