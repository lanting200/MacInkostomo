import { spawn, execFile, execFileSync } from 'child_process';
import { existsSync, mkdirSync, readFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { promisify } from 'util';
import { PATHS } from './paths.js';
import { PUBLISHER_LLM_CONFIG_FILE, readPublisherLlmSecrets } from './llm-secret-store.js';
import { hardenPrivateFile, writePrivateFile } from './private-file.js';
import { normalizeLlmBaseUrl } from './llm-endpoint.js';
import { terminateProcessGroup } from './process-lifecycle.js';
import { debugEvent, ingestDebugEvent } from './debug-log.js';

const execFileP = promisify(execFile);
const __dirname = dirname(fileURLToPath(import.meta.url));
const activeInkosChildren = new Set();

export const INKOS_ROOT = join(__dirname, '..', 'inkos');
export const INKOS_CLI = join(INKOS_ROOT, 'packages', 'cli', 'dist', 'index.js');
export const INKOS_PROJECT_DIR = PATHS.BOOKS_DIR;

function trackInkosChild(child) {
  if (!child) return child;
  activeInkosChildren.add(child);
  const forget = () => activeInkosChildren.delete(child);
  child.once('exit', forget);
  child.once('error', forget);
  return child;
}

export function shutdownInkos() {
  let terminated = 0;
  for (const child of activeInkosChildren) {
    if (terminateProcessGroup(child)) terminated += 1;
  }
  return terminated;
}

export function withoutLegacyProjectApiKey(config) {
  if (!config?.llm || !Object.prototype.hasOwnProperty.call(config.llm, 'apiKey')) {
    return { config, changed: false };
  }
  const next = { ...config, llm: { ...config.llm } };
  delete next.llm.apiKey;
  return { config: next, changed: true };
}

export function withoutLegacyEnvApiKey(raw, options = {}) {
  const removePrimary = options.removePrimary ?? true;
  const removeReview = options.removeReview ?? true;
  const lines = String(raw || '').split(/\r?\n/);
  const filtered = lines.filter(line => {
    if (removePrimary && /^\s*(?:export\s+)?INKOS_LLM_API_KEY\s*=/.test(line)) return false;
    if (removeReview && /^\s*(?:export\s+)?PUBLISHER_REVIEW_API_KEY\s*=/.test(line)) return false;
    return true;
  });
  return {
    content: filtered.join('\n').replace(/\n*$/, '\n'),
    changed: filtered.length !== lines.length,
  };
}

function legacyEnvValue(raw, key) {
  const escapedKey = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = String(raw || '').match(new RegExp(`^\\s*(?:export\\s+)?${escapedKey}\\s*=\\s*(.*)$`, 'm'));
  if (!match) return '';
  const value = match[1].trim();
  if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
    return value.slice(1, -1).replace(/\\n/g, '\n').replace(/\\r/g, '\r').replace(/\\"/g, '"').replace(/\\\\/g, '\\');
  }
  return value;
}

export function readLegacyEnvSecrets(raw) {
  return {
    apiKey: legacyEnvValue(raw, 'INKOS_LLM_API_KEY'),
    reviewApiKey: legacyEnvValue(raw, 'PUBLISHER_REVIEW_API_KEY'),
  };
}

function saveMigratedPublisherSecrets(secrets) {
  mkdirSync(dirname(PUBLISHER_LLM_CONFIG_FILE), { recursive: true });
  let current = {};
  if (existsSync(PUBLISHER_LLM_CONFIG_FILE)) {
    const parsed = JSON.parse(readFileSync(PUBLISHER_LLM_CONFIG_FILE, 'utf-8'));
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new Error('Publisher LLM 私密配置根节点必须是对象');
    }
    current = parsed;
  }
  writePrivateFile(PUBLISHER_LLM_CONFIG_FILE, JSON.stringify({
    ...current,
    apiKey: secrets.apiKey || '',
    reviewApiKey: secrets.reviewApiKey || '',
  }, null, 2));
}

function migrateLegacyProjectSecrets(configPath) {
  let projectConfig = null;
  let projectApiKey = '';
  try {
    projectConfig = JSON.parse(readFileSync(configPath, 'utf-8'));
    projectApiKey = typeof projectConfig?.llm?.apiKey === 'string' ? projectConfig.llm.apiKey.trim() : '';
  } catch {
    // Keep malformed project config untouched for explicit recovery.
  }

  const envPath = join(INKOS_PROJECT_DIR, '.env');
  let envRaw = '';
  let envSecrets = { apiKey: '', reviewApiKey: '' };
  if (existsSync(envPath)) {
    try {
      envRaw = readFileSync(envPath, 'utf-8');
      envSecrets = readLegacyEnvSecrets(envRaw);
    } catch {
      hardenPrivateFile(envPath);
    }
  }

  let secured = readPublisherLlmSecrets();
  const next = {
    apiKey: secured.apiKey || projectApiKey || envSecrets.apiKey || '',
    reviewApiKey: secured.reviewApiKey || '',
  };
  if (!next.reviewApiKey && envSecrets.reviewApiKey && envSecrets.reviewApiKey !== next.apiKey) {
    next.reviewApiKey = envSecrets.reviewApiKey;
  }
  if (next.apiKey !== secured.apiKey || next.reviewApiKey !== secured.reviewApiKey) {
    try {
      saveMigratedPublisherSecrets(next);
      secured = readPublisherLlmSecrets();
    } catch {
      // Do not delete a legacy source unless its value reached the private store.
    }
  }

  if (projectConfig && (!projectApiKey || projectApiKey === secured.apiKey)) {
    const result = withoutLegacyProjectApiKey(projectConfig);
    if (result.changed) {
      writePrivateFile(configPath, JSON.stringify(result.config, null, 2) + '\n');
    }
  }

  if (envRaw) {
    const removePrimary = !envSecrets.apiKey || envSecrets.apiKey === secured.apiKey;
    const removeReview = !envSecrets.reviewApiKey
      || envSecrets.reviewApiKey === secured.reviewApiKey
      || (!secured.reviewApiKey && envSecrets.reviewApiKey === secured.apiKey);
    const result = withoutLegacyEnvApiKey(envRaw, { removePrimary, removeReview });
    if (result.changed) {
      writePrivateFile(envPath, result.content);
    }
  }
}

export function ensureLocalInkosProject() {
  mkdirSync(join(INKOS_PROJECT_DIR, 'books'), { recursive: true });
  const configPath = join(INKOS_PROJECT_DIR, 'inkos.json');
  if (!existsSync(configPath)) {
    const bundledConfig = join(INKOS_ROOT, 'inkos.json');
    let config = {
      name: 'chapter-publisher-books',
      version: '0.1.0',
      language: 'zh',
      llm: { provider: 'openai', service: 'custom', configSource: 'studio', baseUrl: '', model: '', apiFormat: 'chat', stream: true },
      notify: [],
      inputGovernanceMode: 'v2',
    };
    try {
      config = JSON.parse(readFileSync(bundledConfig, 'utf-8'));
      config.name = 'chapter-publisher-books';
    } catch {}
    writePrivateFile(configPath, JSON.stringify(config, null, 2) + '\n');
  } else {
    hardenPrivateFile(configPath);
  }
  migrateLegacyProjectSecrets(configPath);
  hardenPrivateFile(join(INKOS_PROJECT_DIR, '.env'));
  return INKOS_PROJECT_DIR;
}

export function inkosCommand() {
  if (!existsSync(INKOS_CLI)) {
    throw new Error(`项目内 InkOS CLI 不存在: ${INKOS_CLI}`);
  }
  ensureLocalInkosProject();
  return { command: process.execPath, prefixArgs: [INKOS_CLI] };
}

function projectLocalLlmEnv() {
  ensureLocalInkosProject();
  const configPath = join(INKOS_PROJECT_DIR, 'inkos.json');
  try {
    const config = JSON.parse(readFileSync(configPath, 'utf-8'));
    if (!config || typeof config !== 'object' || Array.isArray(config)) {
      throw new Error('配置根节点必须是对象');
    }
    if (config.llm != null && (typeof config.llm !== 'object' || Array.isArray(config.llm))) {
      throw new Error('llm 必须是对象');
    }
    const llm = config.llm || {};
    const env = {};
    // InkOS merges ~/.inkos/.env, project .env, then process.env. The user's
    // global ~/.inkos/.env may point at an old DeepSeek model, so force the
    // project-local ./book/inkos.json values into process.env for every bundled
    // InkOS child. This keeps chapter write/revise aligned with the settings UI.
    if (llm.provider) env.INKOS_LLM_PROVIDER = String(llm.provider);
    if (llm.service) env.INKOS_LLM_SERVICE = String(llm.service);
    if (llm.baseUrl) env.INKOS_LLM_BASE_URL = normalizeLlmBaseUrl(llm.baseUrl);
    if (llm.model) env.INKOS_LLM_MODEL = String(llm.model);
    if (llm.apiKey) env.INKOS_LLM_API_KEY = String(llm.apiKey);
    if (llm.apiFormat) env.INKOS_LLM_API_FORMAT = String(llm.apiFormat);
    if (llm.stream !== undefined) env.INKOS_LLM_STREAM = String(Boolean(llm.stream));
    env.INKOS_LLM_THINKING_BUDGET = String(llm.thinkingBudget ?? 0);
    if (llm.temperature !== undefined) env.INKOS_LLM_TEMPERATURE = String(llm.temperature);
    return env;
  } catch (err) {
    const wrapped = new Error(`无法读取项目 InkOS 配置 ${configPath}: ${err.message}`);
    wrapped.code = 'CONFIG_DATA_INVALID';
    wrapped.cause = err;
    throw wrapped;
  }
}

export function composeInkosChildEnv({ inherited = {}, extra = {}, project = {}, secrets = {} } = {}) {
  // Project-local InkOS settings must win over inherited/global env.
  // ~/.inkos/.env may still point to an old model; if process.env/extra is
  // applied last, write next can silently route to that stale model.
  const forcePublisherStream = extra.PUBLISHER_FORCE_LLM_STREAM === 'true';
  const apiKey = String(secrets.apiKey || project.INKOS_LLM_API_KEY || '').trim();
  const reviewApiKey = String(secrets.reviewApiKey || apiKey || '').trim();
  const env = {
    ...inherited,
    ...extra,
    ...project,
    ...(apiKey ? { INKOS_LLM_API_KEY: apiKey } : {}),
    ...(reviewApiKey ? { PUBLISHER_REVIEW_API_KEY: reviewApiKey } : {}),
    // The Publisher can opt into visible draft streaming for one generation
    // without changing the saved project setting or re-enabling reasoning.
    ...(forcePublisherStream ? { INKOS_LLM_STREAM: 'true' } : {}),
    INKOS_FRAMEWORK_EVENTS: extra.INKOS_FRAMEWORK_EVENTS ?? inherited.INKOS_FRAMEWORK_EVENTS ?? '1',
  };
  if (env.INKOS_LLM_BASE_URL) {
    env.INKOS_LLM_BASE_URL = normalizeLlmBaseUrl(env.INKOS_LLM_BASE_URL);
  }
  return env;
}

function inkosChildEnv(extra = {}) {
  return composeInkosChildEnv({
    inherited: process.env,
    extra,
    project: projectLocalLlmEnv(),
    secrets: readPublisherLlmSecrets(),
  });
}

export function spawnInkos(args, opts = {}) {
  const { command, prefixArgs } = inkosCommand();
  return trackInkosChild(spawn(command, [...prefixArgs, ...args], {
    cwd: opts.cwd || INKOS_PROJECT_DIR,
    env: inkosChildEnv(opts.env || {}),
    stdio: opts.stdio || ['ignore', 'pipe', 'pipe'],
    detached: true,
  }));
}

export async function runInkos(args, opts = {}) {
  const { command, prefixArgs } = inkosCommand();
  const traceId = opts.traceId || opts.env?.MACINKOSTOMO_TRACE_ID;
  const startedAt = Date.now();
  debugEvent('inkos.runtime', 'command started', {
    command: commandLabel(args),
  }, 'debug', {
    traceId,
    operation: 'inkos.command',
    phase: 'start',
    bookId: inferBookId(args),
  });
  const execution = execFileP(command, [...prefixArgs, ...args], {
    cwd: opts.cwd || INKOS_PROJECT_DIR,
    env: inkosChildEnv(opts.env || {}),
    timeout: opts.timeout ?? 600000,
    encoding: opts.encoding || 'utf-8',
    maxBuffer: opts.maxBuffer || 20 * 1024 * 1024,
    detached: true,
  });
  trackInkosChild(execution.child);
  try {
    const result = await execution;
    const filtered = ingestFrameworkEvents(result.stderr, {
      traceId,
      bookId: inferBookId(args),
      component: 'inkos',
    });
    captureInkosOutput(filtered, { traceId, bookId: inferBookId(args), command: commandLabel(args) });
    debugEvent('inkos.runtime', 'command completed', {
      command: commandLabel(args),
      durationMs: Date.now() - startedAt,
    }, 'info', {
      traceId,
      operation: 'inkos.command',
      phase: 'success',
      bookId: inferBookId(args),
      durationMs: Date.now() - startedAt,
    });
    return { ...result, stderr: filtered };
  } catch (error) {
    if (typeof error?.stderr === 'string') {
      error.stderr = ingestFrameworkEvents(error.stderr, {
        traceId,
        bookId: inferBookId(args),
        component: 'inkos',
      });
      captureInkosOutput(error.stderr, { traceId, bookId: inferBookId(args), command: commandLabel(args) });
    }
    debugEvent('inkos.runtime', 'command failed', {
      command: commandLabel(args),
      error: error?.message || String(error),
      durationMs: Date.now() - startedAt,
    }, 'error', {
      traceId,
      operation: 'inkos.command',
      phase: 'failure',
      bookId: inferBookId(args),
      durationMs: Date.now() - startedAt,
    });
    throw error;
  }
}

export function runInkosSync(args, opts = {}) {
  const { command, prefixArgs } = inkosCommand();
  return execFileSync(command, [...prefixArgs, ...args], {
    cwd: opts.cwd || INKOS_PROJECT_DIR,
    env: inkosChildEnv(opts.env || {}),
    timeout: opts.timeout ?? 600000,
    encoding: opts.encoding || 'utf-8',
    maxBuffer: opts.maxBuffer || 20 * 1024 * 1024,
  });
}

const FRAMEWORK_EVENT_PREFIX = '@@INKOS_EVENT@@';

function ingestFrameworkEvents(text, defaults = {}) {
  const lines = String(text || '').split(/\r?\n/);
  const visible = [];
  for (const line of lines) {
    const markerAt = line.indexOf(FRAMEWORK_EVENT_PREFIX);
    if (markerAt < 0) {
      visible.push(line);
      continue;
    }
    try {
      ingestDebugEvent(JSON.parse(line.slice(markerAt + FRAMEWORK_EVENT_PREFIX.length)), defaults);
    } catch (error) {
      debugEvent('inkos.runtime', 'invalid framework event', {
        error: error.message,
        line: line.slice(markerAt, markerAt + 2_000),
      }, 'warn', {
        traceId: defaults.traceId,
        operation: 'inkos.event.parse',
        phase: 'failure',
        bookId: defaults.bookId,
      });
    }
  }
  return visible.join('\n').trimEnd();
}

function commandLabel(args) {
  return args.slice(0, 2).map(value => String(value)).join(' ');
}

function captureInkosOutput(text, context) {
  for (const line of String(text || '').split(/\r?\n/).map(value => value.trim()).filter(Boolean).slice(-500)) {
    const isError = /^(?:ERROR|FATAL)|\berror\b|失败|异常/i.test(line);
    const isWarning = /^(?:WARN|WARNING)|\bwarn(?:ing)?\b|警告/i.test(line);
    debugEvent('inkos.log', line.slice(0, 8_000), {
      command: context.command,
    }, isError ? 'error' : isWarning ? 'warn' : 'info', {
      traceId: context.traceId,
      operation: 'inkos.log',
      phase: isError ? 'failure' : 'progress',
      bookId: context.bookId,
    });
  }
}

function inferBookId(args) {
  const command = String(args[0] || '');
  if (command === 'book') return undefined;
  const candidate = command === 'write' || command === 'review' ? args[2] : args[1];
  return typeof candidate === 'string' && candidate && !candidate.startsWith('-') ? candidate : undefined;
}
