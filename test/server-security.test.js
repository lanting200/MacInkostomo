import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import net from 'node:net';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const STATE_FILE = join(ROOT, 'data', 'state.json');
const PRIVATE_CONFIG_FILES = [
  join(ROOT, 'data', 'inkos-config.json'),
  join(ROOT, 'book', 'inkos.json'),
  join(ROOT, 'book', '.env'),
];
const CREATE_BRIEFS_DIR = join(ROOT, 'data', 'create-briefs');
const MISSING_FILE = '<missing>';

function fileHash(file) {
  return createHash('sha256').update(readFileSync(file)).digest('hex');
}

function fileSnapshot(file) {
  return existsSync(file) ? fileHash(file) : MISSING_FILE;
}

const stateSnapshot = () => fileSnapshot(STATE_FILE);

async function reservePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(err => err ? reject(err) : resolve(port));
    });
  });
}

async function waitForHealth(baseUrl, child, output) {
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error(`server exited early: ${output.join('')}`);
    try {
      const response = await fetch(`${baseUrl}/api/health`);
      if (response.ok) return response.json();
    } catch {}
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error(`server readiness timed out: ${output.join('')}`);
}

test('server rejects cross-origin and path/key relay probes without changing state', async t => {
  const stateBeforeStartup = stateSnapshot();
  const briefsBefore = existsSync(CREATE_BRIEFS_DIR) ? readdirSync(CREATE_BRIEFS_DIR).sort() : [];
  const privateConfigBeforeStartup = PRIVATE_CONFIG_FILES.map(fileSnapshot);
  const port = await reservePort();
  const baseUrl = `http://127.0.0.1:${port}`;
  const output = [];
  const child = spawn(process.execPath, ['server.js'], {
    cwd: ROOT,
    env: { ...process.env, PORT: String(port) },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stdout.on('data', chunk => output.push(chunk.toString()));
  child.stderr.on('data', chunk => output.push(chunk.toString()));
  t.after(async () => {
    if (child.exitCode !== null) return;
    child.kill('SIGTERM');
    await new Promise(resolve => child.once('exit', resolve));
  });

  const health = await waitForHealth(baseUrl, child, output);
  assert.equal(health.service, 'chapter-publisher');
  assert.equal(health.port, port);

  // A clean checkout has no state.json. Prime the read-only state path before
  // taking the mutation baseline so its expected empty-file initialization is
  // not attributed to one of the hostile requests below.
  const books = await fetch(`${baseUrl}/api/books`);
  assert.equal(books.status, 200);
  assert.ok(Array.isArray(await books.json()));
  const before = stateBeforeStartup === MISSING_FILE ? stateSnapshot() : stateBeforeStartup;
  assert.notEqual(before, MISSING_FILE);
  const privateConfigBefore = privateConfigBeforeStartup.map((snapshot, index) => (
    snapshot === MISSING_FILE ? fileSnapshot(PRIVATE_CONFIG_FILES[index]) : snapshot
  ));

  const hostile = await fetch(`${baseUrl}/api/health`, { headers: { Origin: 'https://TARGET.invalid' } });
  assert.equal(hostile.status, 403);
  assert.equal(hostile.headers.get('access-control-allow-origin'), null);

  const allowedOrigin = `http://localhost:${port}`;
  const allowed = await fetch(`${baseUrl}/api/health`, { headers: { Origin: allowedOrigin } });
  assert.equal(allowed.status, 200);
  assert.equal(allowed.headers.get('access-control-allow-origin'), allowedOrigin);

  const relay = await fetch(`${baseUrl}/api/inkos/models/list`, {
    method: 'POST',
    headers: { Origin: allowedOrigin, 'Content-Type': 'application/json' },
    body: JSON.stringify({ role: 'chapter', baseUrl: 'http://127.0.0.1:9' }),
  });
  assert.equal(relay.status, 502);
  assert.match((await relay.json()).error, /必须重新输入对应的 API Key|请先填写或保存 OpenAI API Key/);

  const insecureRemote = await fetch(`${baseUrl}/api/inkos/models/list`, {
    method: 'POST',
    headers: { Origin: allowedOrigin, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      role: 'chapter',
      baseUrl: 'http://TARGET.invalid/v1',
      apiKey: 'TOKEN',
    }),
  });
  assert.equal(insecureRemote.status, 502);
  assert.match((await insecureRemote.json()).error, /必须使用 HTTPS/);

  const insecureSave = await fetch(`${baseUrl}/api/inkos/config`, {
    method: 'POST',
    headers: { Origin: allowedOrigin, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      baseUrl: 'http://TARGET.invalid/v1',
      model: 'MODEL',
      apiKey: 'TOKEN',
    }),
  });
  assert.equal(insecureSave.status, 400);
  assert.match((await insecureSave.json()).error, /必须使用 HTTPS/);

  const traversalImport = await fetch(`${baseUrl}/api/books/import`, {
    method: 'POST',
    headers: { Origin: allowedOrigin, 'Content-Type': 'application/json' },
    body: JSON.stringify({ bookId: '../TARGET' }),
  });
  assert.equal(traversalImport.status, 400);

  const invalidChapter = await fetch(`${baseUrl}/api/books/${encodeURIComponent('天师后人-我在古代斩妖封僵')}/chapters/1abc`);
  assert.equal(invalidChapter.status, 400);

  const encodedTraversal = await fetch(`${baseUrl}/api/books/%2e%2e%2fTARGET/settings`);
  assert.ok(encodedTraversal.status >= 400);

  const invalidCreate = await fetch(`${baseUrl}/api/books/create`, {
    method: 'POST',
    headers: { Origin: allowedOrigin, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      title: 'Boundary Fixture',
      targetTotalWords: 999,
      targetChapterWords: 500,
      volumeCount: 1,
      chapterWordTolerance: 15,
      specialConstraints: ['保持时间线'],
    }),
  });
  assert.equal(invalidCreate.status, 400);

  const missingSpecialConstraints = await fetch(`${baseUrl}/api/books/create`, {
    method: 'POST',
    headers: { Origin: allowedOrigin, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      title: 'Boundary Fixture',
      targetTotalWords: 5000,
      targetChapterWords: 500,
      volumeCount: 1,
      chapterWordTolerance: 15,
      specialConstraints: [],
    }),
  });
  assert.equal(missingSpecialConstraints.status, 400);

  const firstBookId = Object.keys(JSON.parse(readFileSync(STATE_FILE, 'utf-8')).books || {})[0];
  if (firstBookId) {
    const invalidPatch = await fetch(`${baseUrl}/api/books/${encodeURIComponent(firstBookId)}/long-form-plan`, {
      method: 'PATCH',
      headers: { Origin: allowedOrigin, 'Content-Type': 'application/json' },
      body: JSON.stringify({ expectedRevision: 0, constraints: { targetTotalWords: 5000 } }),
    });
    assert.equal(invalidPatch.status, 400);
  }

  assert.equal(stateSnapshot(), before);
  assert.deepEqual(existsSync(CREATE_BRIEFS_DIR) ? readdirSync(CREATE_BRIEFS_DIR).sort() : [], briefsBefore);
  assert.deepEqual(PRIVATE_CONFIG_FILES.map(fileSnapshot), privateConfigBefore);
});
