import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { composeInkosChildEnv, readLegacyEnvSecrets, withoutLegacyEnvApiKey, withoutLegacyProjectApiKey } from '../lib/inkos-runner.js';
import { readPublisherLlmSecrets } from '../lib/llm-secret-store.js';
import { hardenPrivateFile, writePrivateFile } from '../lib/private-file.js';
import { fetchJsonWithTimeout } from '../lib/request-timeout.js';
import { buildDigest } from '../lib/story-memory.js';
import { parseChapterIndex } from '../lib/inkos.js';
import { assertBookId } from '../lib/paths.js';
import { replaceDirectoryFromBackup } from '../lib/directory-restore.js';
import { mergeBookChapterSnapshot } from '../lib/store.js';
import { loadWorkflowJobs, retainWorkflowJobs, saveWorkflowJobs } from '../lib/workflow-jobs.js';
import { normalizeLlmBaseUrl } from '../lib/llm-endpoint.js';
import { signalProcessGroup, terminateProcessGroup } from '../lib/process-lifecycle.js';
import { assertInkosProjectConfig } from '../lib/inkos-config.js';

function withTempDir(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'chapter-publisher-test-'));
  try {
    return fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test('private file helpers enforce mode 0600 for new and existing files', () => {
  withTempDir(dir => {
    const file = join(dir, 'secret.json');
    writeFileSync(file, '{}', { mode: 0o644 });
    chmodSync(file, 0o644);
    assert.equal(hardenPrivateFile(file), true);
    assert.equal(statSync(file).mode & 0o777, 0o600);

    writePrivateFile(file, '{"key":"value"}');
    assert.equal(readFileSync(file, 'utf-8'), '{"key":"value"}');
    assert.equal(statSync(file).mode & 0o777, 0o600);
  });
});

test('directory restore exactly replaces a damaged tree and removes new artifacts', () => {
  withTempDir(dir => {
    const source = join(dir, 'book');
    const backup = join(dir, 'backup');
    mkdirSync(join(source, 'story'), { recursive: true });
    mkdirSync(join(backup, 'story'), { recursive: true });
    writeFileSync(join(source, 'story', 'chapter.md'), 'damaged');
    writeFileSync(join(source, 'new-artifact.json'), '{}');
    writeFileSync(join(backup, 'story', 'chapter.md'), 'original');

    const result = replaceDirectoryFromBackup(source, backup, 'test', { requireFiles: true });

    assert.equal(result.restoredCount, 1);
    assert.equal(readFileSync(join(source, 'story', 'chapter.md'), 'utf-8'), 'original');
    assert.equal(existsSync(join(source, 'new-artifact.json')), false);
  });
});

test('required non-empty restore leaves the current tree untouched for an empty backup', () => {
  withTempDir(dir => {
    const source = join(dir, 'book');
    const backup = join(dir, 'backup');
    mkdirSync(source, { recursive: true });
    mkdirSync(backup, { recursive: true });
    writeFileSync(join(source, 'chapter.md'), 'current');

    assert.throws(
      () => replaceDirectoryFromBackup(source, backup, 'test', { requireFiles: true }),
      /备份目录为空/,
    );
    assert.equal(readFileSync(join(source, 'chapter.md'), 'utf-8'), 'current');
  });
});

test('chapter snapshot commits preserve concurrent changes outside the target chapter', () => {
  const latestBook = {
    updatedAt: 'latest-book-time',
    chapters: [
      { number: 1, status: 'approved', updatedAt: 'reconciled-later' },
      { number: 2, status: 'inkos_revising', content: 'old' },
      { number: 3, status: 'pending_review' },
      { number: 4, status: 'approved', updatedAt: 'approved-concurrently' },
    ],
  };
  const workflowSnapshot = {
    updatedAt: 'workflow-finished',
    chapters: [
      { number: 1, status: 'pending_review', updatedAt: 'stale-snapshot' },
      { number: 2, status: 'pending_review', content: 'revised' },
    ],
  };

  mergeBookChapterSnapshot(latestBook, workflowSnapshot, {
    chapterNumbers: [2],
    removeChapterNumbers: [3, 4],
  });

  assert.deepEqual(latestBook.chapters, [
    { number: 1, status: 'approved', updatedAt: 'reconciled-later' },
    { number: 2, status: 'pending_review', content: 'revised' },
    { number: 4, status: 'approved', updatedAt: 'approved-concurrently' },
  ]);
  assert.equal(latestBook.updatedAt, 'workflow-finished');
});

test('corrupt workflow jobs are backed up and surfaced without replacing the source', () => {
  withTempDir(dir => {
    const file = join(dir, 'workflow-jobs.json');
    writeFileSync(file, '{broken', { mode: 0o644 });

    assert.throws(
      () => loadWorkflowJobs(file),
      err => err.code === 'WORKFLOW_JOBS_INVALID' && err.statusCode === 503,
    );
    assert.equal(readFileSync(file, 'utf-8'), '{broken');
    const backups = readdirSync(dir).filter(name => name.startsWith('workflow-jobs.json.corrupt-'));
    assert.equal(backups.length, 1);
    assert.equal(readFileSync(join(dir, backups[0]), 'utf-8'), '{broken');
    assert.equal(statSync(join(dir, backups[0])).mode & 0o777, 0o600);
  });
});

test('workflow retention keeps active jobs and only the newest 200 terminal jobs', () => {
  const now = Date.now();
  const active = { jobId: 'active' };
  const terminal = Array.from({ length: 205 }, (_, index) => ({
    jobId: `terminal-${index}`,
    finishedAt: new Date(now - index * 1000).toISOString(),
  }));
  const expired = { jobId: 'expired', finishedAt: new Date(now - 8 * 24 * 60 * 60 * 1000).toISOString() };
  const retained = retainWorkflowJobs([active, ...terminal, expired], now);

  assert.equal(retained.length, 201);
  assert.equal(retained[0], active);
  assert.equal(retained.some(job => job.jobId === 'terminal-199'), true);
  assert.equal(retained.some(job => job.jobId === 'terminal-200'), false);
  assert.equal(retained.some(job => job.jobId === 'expired'), false);
});

test('workflow job saves are private, atomic, and return the retained payload', () => {
  withTempDir(dir => {
    const file = join(dir, 'workflow-jobs.json');
    const payload = saveWorkflowJobs([{ bookId: 'book', chapterNum: 1 }], [{ jobId: 'create' }], file);
    assert.equal(payload.generationJobs.length, 1);
    assert.equal(payload.creationJobs.length, 1);
    assert.equal(statSync(file).mode & 0o777, 0o600);
    assert.deepEqual(loadWorkflowJobs(file), {
      generationJobs: payload.generationJobs,
      creationJobs: payload.creationJobs,
    });
    assert.equal(readdirSync(dir).some(name => name.includes('.tmp-')), false);
  });
});

test('secret store reads distinct keys and hardens its source file', () => {
  withTempDir(dir => {
    const file = join(dir, 'config.json');
    writeFileSync(file, JSON.stringify({ apiKey: 'PRIMARY', reviewApiKey: 'REVIEW' }), { mode: 0o644 });
    chmodSync(file, 0o644);

    assert.deepEqual(readPublisherLlmSecrets(file), { apiKey: 'PRIMARY', reviewApiKey: 'REVIEW' });
    assert.equal(statSync(file).mode & 0o777, 0o600);
  });
});

test('InkOS child env consistently prefers private primary and review keys', () => {
  const env = composeInkosChildEnv({
    inherited: {
      INKOS_LLM_MODEL: 'GLOBAL_MODEL',
      INKOS_LLM_API_KEY: 'GLOBAL_KEY',
      PUBLISHER_REVIEW_API_KEY: 'GLOBAL_REVIEW_KEY',
    },
    extra: { PUBLISHER_FORCE_LLM_STREAM: 'true' },
    project: { INKOS_LLM_MODEL: 'PROJECT_MODEL', INKOS_LLM_STREAM: 'false' },
    secrets: { apiKey: 'PRIMARY', reviewApiKey: 'REVIEW' },
  });

  assert.equal(env.INKOS_LLM_MODEL, 'PROJECT_MODEL');
  assert.equal(env.INKOS_LLM_API_KEY, 'PRIMARY');
  assert.equal(env.PUBLISHER_REVIEW_API_KEY, 'REVIEW');
  assert.equal(env.INKOS_LLM_STREAM, 'true');
});

test('InkOS child env falls back to the primary key for review roles', () => {
  const env = composeInkosChildEnv({ secrets: { apiKey: 'PRIMARY', reviewApiKey: '' } });
  assert.equal(env.INKOS_LLM_API_KEY, 'PRIMARY');
  assert.equal(env.PUBLISHER_REVIEW_API_KEY, 'PRIMARY');
});

test('legacy project and dotenv key copies are removed without touching other settings', () => {
  const project = withoutLegacyProjectApiKey({
    name: 'fixture',
    llm: { model: 'MODEL', apiKey: 'LEGACY' },
  });
  assert.equal(project.changed, true);
  assert.deepEqual(project.config, { name: 'fixture', llm: { model: 'MODEL' } });

  const env = withoutLegacyEnvApiKey([
    'INKOS_LLM_MODEL="MODEL"',
    'INKOS_LLM_API_KEY="LEGACY"',
    'PUBLISHER_REVIEW_API_KEY="KEEP"',
    '',
  ].join('\n'));
  assert.equal(env.changed, true);
  assert.equal(env.content.includes('INKOS_LLM_API_KEY'), false);
  assert.equal(env.content.includes('PUBLISHER_REVIEW_API_KEY'), false);
});

test('legacy dotenv migration can preserve a distinct review key until it is secured', () => {
  const raw = [
    'INKOS_LLM_MODEL="MODEL"',
    'INKOS_LLM_API_KEY="PRIMARY"',
    'PUBLISHER_REVIEW_API_KEY="DISTINCT_REVIEW"',
    '',
  ].join('\n');
  assert.deepEqual(readLegacyEnvSecrets(raw), {
    apiKey: 'PRIMARY',
    reviewApiKey: 'DISTINCT_REVIEW',
  });

  const primaryOnly = withoutLegacyEnvApiKey(raw, { removePrimary: true, removeReview: false });
  assert.equal(primaryOnly.content.includes('INKOS_LLM_API_KEY'), false);
  assert.equal(primaryOnly.content.includes('PUBLISHER_REVIEW_API_KEY="DISTINCT_REVIEW"'), true);
});

test('LLM endpoints require HTTPS except for loopback or an explicit opt-in', () => {
  assert.equal(normalizeLlmBaseUrl('https://TARGET.invalid/v1/'), 'https://target.invalid/v1');
  assert.equal(normalizeLlmBaseUrl('http://127.0.0.1:8000/v1'), 'http://127.0.0.1:8000/v1');
  assert.equal(
    normalizeLlmBaseUrl('http://TARGET.invalid/v1', { allowInsecureHttp: true }),
    'http://target.invalid/v1',
  );
  assert.throws(() => normalizeLlmBaseUrl('http://TARGET.invalid/v1', { allowInsecureHttp: false }), /必须使用 HTTPS/);
  assert.throws(() => normalizeLlmBaseUrl('https://TOKEN@TARGET.invalid/v1'), /不能包含账号/);
  assert.throws(() => normalizeLlmBaseUrl('https://TARGET.invalid/v1?token=TOKEN'), /查询参数/);
});

test('InkOS project config requires object roots and object config sections', () => {
  assert.equal(assertInkosProjectConfig({ llm: {}, modelOverrides: {} }).llm != null, true);
  assert.throws(() => assertInkosProjectConfig([]), /根节点必须是对象/);
  assert.throws(() => assertInkosProjectConfig({ llm: [] }), /llm 必须是对象/);
  assert.throws(() => assertInkosProjectConfig({ modelOverrides: [] }), /modelOverrides 必须是对象/);
});

test('process-group termination escalates hung children and cancels escalation after exit', async () => {
  const hung = new EventEmitter();
  Object.assign(hung, { pid: 12345, exitCode: null, signalCode: null, kill: () => true });
  const hungSignals = [];
  assert.equal(terminateProcessGroup(hung, {
    graceMs: 5,
    killImpl: (pid, signal) => hungSignals.push([pid, signal]),
  }), true);
  await new Promise(resolve => setTimeout(resolve, 15));
  assert.deepEqual(hungSignals, [[-12345, 'SIGTERM'], [-12345, 'SIGKILL']]);

  const exited = new EventEmitter();
  Object.assign(exited, { pid: 23456, exitCode: null, signalCode: null, kill: () => true });
  const exitedSignals = [];
  assert.equal(terminateProcessGroup(exited, {
    graceMs: 10,
    killImpl: (pid, signal) => exitedSignals.push([pid, signal]),
  }), true);
  exited.exitCode = 0;
  exited.emit('exit', 0, null);
  await new Promise(resolve => setTimeout(resolve, 15));
  assert.deepEqual(exitedSignals, [[-23456, 'SIGTERM']]);

  const fallbackSignals = [];
  const fallback = { pid: 34567, kill: signal => fallbackSignals.push(signal) };
  assert.equal(signalProcessGroup(fallback, 'SIGTERM', () => { throw new Error('no group'); }), true);
  assert.deepEqual(fallbackSignals, ['SIGTERM']);
});

test('fetchJsonWithTimeout aborts a stalled request', async () => {
  const fetchImpl = async (url, options) => new Promise((resolve, reject) => {
    options.signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true });
  });

  await assert.rejects(
    fetchJsonWithTimeout('http://fixture.invalid', {}, 10, { fetchImpl, label: 'fixture request' }),
    err => err.code === 'ETIMEDOUT' && err.timeoutMs === 10,
  );
});

test('fetchJsonWithTimeout returns parsed response data', async () => {
  const response = { ok: true, status: 200, json: async () => ({ value: 42 }) };
  const result = await fetchJsonWithTimeout('http://fixture.invalid', {}, 100, {
    fetchImpl: async () => response,
  });
  assert.equal(result.response, response);
  assert.deepEqual(result.data, { value: 42 });
});

test('story-memory fallback does not inject a book-specific protagonist', () => {
  const digest = buildDigest('A Different Book', 'ROLE_A enters the room.\n\nROLE_B closes the door.');
  assert.equal(digest.characters, '\uff08\u5f85 InkOS \u7ec6\u5316\uff09');
  assert.equal(digest.characters.includes('\u5f20\u9053'), false);
});

test('book IDs reject traversal while preserving valid Chinese IDs', () => {
  assert.equal(assertBookId('天师后人-测试'), '天师后人-测试');
  for (const value of ['', '.', '..', '../TARGET', 'A/B', 'A\\B', 'A\0B']) {
    assert.throws(() => assertBookId(value), err => err.code === 'INVALID_BOOK_ID');
  }
});

test('chapter indexes must be arrays of unique positive integer chapters', () => {
  assert.deepEqual(parseChapterIndex('[{"number":1},{"number":2}]').map(x => x.number), [1, 2]);
  assert.throws(() => parseChapterIndex('{"number":1}'), /必须是数组/);
  assert.throws(() => parseChapterIndex('[{"number":0}]'), /章节号无效/);
  assert.throws(() => parseChapterIndex('[{"number":1},{"number":1}]'), /章节号重复/);
  assert.throws(() => parseChapterIndex('[{"number":1}'), SyntaxError);
});
