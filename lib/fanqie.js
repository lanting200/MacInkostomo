import { spawn } from 'child_process';
import { PATHS } from './paths.js';
import { signalProcessGroup, terminateProcessGroup } from './process-lifecycle.js';

// Long enough for Playwright launch + navigation + DOM ops + a publish flow.
const OP_TIMEOUT_MS = 600000;
const STARTUP_TIMEOUT_MS = 90000;

// ---------------------------------------------------------------------------
// Persistent Playwright process (fanqie_ops.py --server).
//
// Previously each op was a fresh `execFile` call that launched a browser,
// ran one op, then closed the whole browser — so "view chapter content"
// shut the browser (and any open editor) the moment the op returned.
//
// Now we keep one Python child alive with a persistent browser context.
// Node sends JSON request lines on stdin; Python prints JSON response lines
// on stdout. Requests carry an `id` so responses can be routed back even if
// the child emits stray lines. Playwright logs go to stderr.
//
// Constraints (from探查):
//  - Playwright sync_api is single-threaded → the child processes commands
//    serially. Node side MUST also serialize, so we wrap runOp in a queue.
//  - Chromium forks subprocesses; killing child.pid alone leaves browsers
//    alive → spawn detached and kill the whole process group (-pid).
//  - needRelogin → the storage_state is stale, kill the child so the next
//    call re-spawns after the user re-runs login.py.
// ---------------------------------------------------------------------------

let child = null;
let nextId = 1;
const pending = new Map(); // id -> {resolve, reject, timer, owner}
let crashCount = 0;
let lifecycleVersion = 0;
// Serialize all ops: sync_api can't run two at once, and a serial queue
// also guarantees responses can't interleave on the Node side.
let chain = Promise.resolve();

function killProcess(proc, signal = 'SIGTERM') {
  if (!proc) return false;
  if (child === proc) child = null;
  return signal === 'SIGTERM'
    ? terminateProcessGroup(proc)
    : signalProcessGroup(proc, signal);
}

function failPendingFor(owner, msg) {
  for (const [id, p] of pending) {
    if (p.owner !== owner) continue;
    pending.delete(id);
    clearTimeout(p.timer);
    p.reject(new Error(msg));
  }
}

function takePending(id, owner) {
  const waiter = pending.get(id);
  if (!waiter || waiter.owner !== owner) return null;
  pending.delete(id);
  clearTimeout(waiter.timer);
  return waiter;
}

function handleLine(line, owner) {
  let obj;
  try { obj = JSON.parse(line); } catch { return; } // not JSON, ignore stray output
  // Startup handshake: {"ready": true|false}
  if (obj.ready !== undefined) {
    const waiter = takePending('startup', owner);
    if (!waiter) return;
    if (obj.ready) {
      crashCount = 0;
      waiter.resolve(true);
    } else {
      // Authentication failure is not a process crash. Dispose this browser so
      // a later call can load the newly-written storage state after login.
      crashCount = 0;
      killProcess(owner);
      waiter.reject(Object.assign(new Error(obj.error || '番茄登录态失效'), { needRelogin: true }));
    }
    return;
  }
  const id = obj.id;
  const waiter = takePending(id, owner);
  if (!waiter) return; // stale response for an already-timed-out/cancelled request
  if (obj.needRelogin) {
    // context is stale — kill so next call re-spawns after re-login.
    killProcess(owner);
    waiter.reject(Object.assign(new Error(obj.error || 'LOGIN_EXPIRED'), { needRelogin: true }));
    return;
  }
  if (obj.ok) {
    waiter.resolve(obj.data);
  } else {
    waiter.reject(new Error(obj.error || '番茄操作失败'));
  }
}

function ensureChild() {
  if (child && child.exitCode === null && !child.killed) return Promise.resolve();
  child = null;
  crashCount++;
  if (crashCount > 5) {
    return Promise.reject(new Error('番茄浏览器进程连续崩溃，请检查 Playwright 环境或重新登录'));
  }
  const proc = spawn('python3', ['fanqie_ops.py', '--server'], {
    cwd: PATHS.FANQIE_DIR,
    stdio: ['pipe', 'pipe', 'inherit'], // stderr → parent console for debug
    env: { ...process.env, HEADLESS: '1' }, // 无头模式，不弹浏览器窗口
    detached: true,
  });
  child = proc;
  let stdoutBuf = '';

  proc.stdout.on('data', (chunk) => {
    stdoutBuf += chunk.toString('utf-8');
    let idx;
    while ((idx = stdoutBuf.indexOf('\n')) >= 0) {
      const line = stdoutBuf.slice(0, idx).trim();
      stdoutBuf = stdoutBuf.slice(idx + 1);
      if (line) handleLine(line, proc);
    }
  });

  proc.on('exit', (code, signal) => {
    if (child === proc) child = null;
    // Only reject work owned by this process. A delayed exit from an old
    // browser must not clear a replacement process or its requests.
    failPendingFor(proc, `番茄浏览器进程退出 (code=${code} signal=${signal})，请重试`);
  });
  proc.on('error', (err) => {
    if (child === proc) child = null;
    failPendingFor(proc, `番茄进程启动失败: ${err.message}`);
  });

  // Wait for the ready handshake.
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      const waiter = pending.get('startup');
      if (!waiter || waiter.owner !== proc) return;
      pending.delete('startup');
      killProcess(proc);
      reject(new Error('番茄浏览器启动超时'));
    }, STARTUP_TIMEOUT_MS);
    pending.set('startup', { resolve, reject, timer, owner: proc });
  });
}

function sendOp(op, args = []) {
  return ensureChild().then(() => new Promise((resolve, reject) => {
    const owner = child;
    if (!owner || owner.exitCode !== null || owner.killed || !owner.stdin?.writable) {
      reject(new Error('番茄浏览器进程未就绪'));
      return;
    }
    const id = nextId++;
    const timer = setTimeout(() => {
      const waiter = pending.get(id);
      if (!waiter || waiter.owner !== owner) return;
      pending.delete(id);
      killProcess(owner);
      reject(new Error(`番茄操作超时: ${op}`));
    }, OP_TIMEOUT_MS);
    pending.set(id, { resolve, reject, timer, owner });
    const failWrite = (err) => {
      if (!err) return;
      const waiter = takePending(id, owner);
      if (!waiter) return;
      killProcess(owner);
      waiter.reject(new Error(`番茄请求发送失败: ${err.message}`));
    };
    try {
      owner.stdin.write(JSON.stringify({ id, op, args }) + '\n', failWrite);
    } catch (err) {
      failWrite(err);
    }
  }));
}

// Serialized: queue every op so sync_api never sees two at once.
function runOp(op, args = []) {
  const queuedVersion = lifecycleVersion;
  const run = () => {
    if (queuedVersion !== lifecycleVersion) {
      throw new Error('番茄请求所属的浏览器会话已结束');
    }
    return sendOp(op, args);
  };
  chain = chain.then(run, run); // proceed even if previous rejected
  return chain;
}

export const listBooks = () => runOp('list_books');

export const listChapters = (bookId, bookTitle) =>
  runOp('list_chapters', [bookId, bookTitle]);

export const getFanqieChapter = (bookId, chapterId) =>
  runOp('get_chapter', [bookId, chapterId]);

export function shutdownFanqie() {
  lifecycleVersion++;
  const owner = child;
  if (!owner) {
    crashCount = 0;
    return false;
  }
  failPendingFor(owner, '番茄浏览器进程已关闭');
  const killed = killProcess(owner);
  crashCount = 0;
  return killed;
}

// The exit hook also runs after Node's default SIGINT/SIGTERM handling. Do not
// register signal listeners here: doing so prevents Node from exiting unless a
// listener explicitly terminates the process.
process.on('exit', () => { shutdownFanqie(); });
