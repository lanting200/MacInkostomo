import { existsSync, readFileSync } from 'fs';
import { AsyncLocalStorage } from 'async_hooks';
import { createHash } from 'crypto';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { PATHS } from './paths.js';
import { getInkosConfig } from './inkos-config.js';
import { readPublisherLlmSecrets } from './llm-secret-store.js';
import { ensureLocalInkosProject } from './inkos-runner.js';
import { debugEvent, ingestDebugEvent } from './debug-log.js';
import { ReloadableRuntime } from './reloadable-runtime.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const CORE_ENTRY = join(__dirname, '..', 'inkos', 'packages', 'core', 'dist', 'index.js');
let corePromise;
const operationContext = new AsyncLocalStorage();
const sharedRuntime = new ReloadableRuntime({ dispose: closePublisherInkOSRuntime });
const activeOperationControllers = new Set();

/**
 * Load the bundled core once. Publisher jobs use this entry point instead of
 * launching the InkOS CLI, so the same framework module registry owns the
 * operation and its diagnostics stay in the current process.
 */
async function loadCore() {
  if (!corePromise) {
    if (!existsSync(CORE_ENTRY)) {
      throw new Error(`内置 InkOS core 未构建：${CORE_ENTRY}。请先运行 inkos/packages/core 的 build。`);
    }
    corePromise = import(CORE_ENTRY);
  }
  return corePromise;
}

function readProjectConfig() {
  ensureLocalInkosProject();
  const path = join(PATHS.BOOKS_DIR, 'inkos.json');
  try {
    const value = JSON.parse(readFileSync(path, 'utf-8'));
    if (!value || typeof value !== 'object' || Array.isArray(value)) {
      throw new Error('项目配置根节点必须是对象');
    }
    return value;
  } catch (error) {
    throw new Error(`无法读取项目 InkOS 配置 ${path}: ${error.message}`, { cause: error });
  }
}

function asFiniteNumber(value, fallback) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function buildLlmConfig(projectConfig, secrets, stored = getInkosConfig()) {
  const llm = projectConfig.llm && typeof projectConfig.llm === 'object'
    ? projectConfig.llm
    : {};
  const baseUrl = String(llm.baseUrl || stored.baseUrl || 'https://api.openai.com/v1').trim();
  const model = String(llm.model || stored.model || 'gpt-5.6-terra').trim();
  return {
    provider: llm.provider === 'anthropic' ? 'anthropic' : 'openai',
    service: String(llm.service || 'custom'),
    configSource: 'studio',
    baseUrl,
    apiKey: String(secrets.apiKey || stored.apiKey || llm.apiKey || ''),
    model,
    temperature: asFiniteNumber(llm.temperature ?? stored.temperature, 0.7),
    thinkingBudget: 0,
    extra: llm.extra && typeof llm.extra === 'object' ? llm.extra : {},
    apiFormat: llm.apiFormat === 'responses' ? 'responses' : 'chat',
    stream: llm.stream === true || stored.stream === true,
  };
}

function currentOptions(fallback) {
  return operationContext.getStore() || fallback;
}

function makeLogger(core, options) {
  const sink = core.createJsonLineSink
    ? core.createJsonLineSink({
        write(value) {
          const text = String(value || '').trim();
          if (!text) return;
          try {
            const entry = JSON.parse(text);
            const context = currentOptions(options);
            debugEvent('inkos.log', entry.message || 'InkOS log', entry.ctx || {}, entry.level || 'info', {
              traceId: context.traceId,
              bookId: context.bookId,
              chapterNumber: context.chapterNumber,
              component: 'inkos.pipeline',
              operation: 'inkos.log',
              phase: entry.level === 'error' ? 'failure' : 'progress',
            });
          } catch {
            const context = currentOptions(options);
            debugEvent('inkos.log', text.slice(0, 8_000), {}, 'info', {
              traceId: context.traceId,
              bookId: context.bookId,
              chapterNumber: context.chapterNumber,
              component: 'inkos.pipeline',
              operation: 'inkos.log',
              phase: 'progress',
            });
          }
        },
      })
    : null;
  if (core.createLogger && sink) return core.createLogger({ tag: 'inkos', sinks: [sink] });
  const emit = (level, message, data) => {
    const context = currentOptions(options);
    debugEvent('inkos.log', message, data || {}, level, {
      traceId: context.traceId,
      bookId: context.bookId,
      chapterNumber: context.chapterNumber,
      component: 'inkos.pipeline',
      operation: 'inkos.log',
      phase: level === 'error' ? 'failure' : 'progress',
    });
  };
  return {
    debug: (message, data) => emit('debug', message, data),
    info: (message, data) => emit('info', message, data),
    warn: (message, data) => emit('warn', message, data),
    error: (message, data) => emit('error', message, data),
    child: () => makeLogger(core, options),
  };
}

function makeDiagnosticSink(options) {
  return (event) => {
    const context = currentOptions(options);
    ingestDebugEvent(event, {
      traceId: context.traceId,
      bookId: context.bookId,
      chapterNumber: context.chapterNumber,
      component: 'inkos.framework',
    });
  };
}

function readRuntimeInputs() {
  const projectConfig = readProjectConfig();
  const stored = getInkosConfig();
  const secrets = readPublisherLlmSecrets();
  const llm = buildLlmConfig(projectConfig, secrets, stored);
  const signature = createHash('sha256').update(JSON.stringify({
    projectConfig,
    stored,
    secrets,
  })).digest('hex');
  return { projectConfig, secrets, llm, signature };
}

async function createRuntimeFromInputs(inputs, options) {
  const core = await loadCore();
  const { projectConfig, secrets, llm } = inputs;
  const logger = makeLogger(core, options);
  const modelOverrideApiKeys = Object.fromEntries(
    Object.entries(projectConfig.modelOverrides || {})
      .filter(([, override]) => override && typeof override === 'object'
        && override.apiKeyEnv === 'PUBLISHER_REVIEW_API_KEY'
        && secrets.reviewApiKey)
      .map(([agent]) => [agent, secrets.reviewApiKey]),
  );
  const pipelineConfig = {
    client: core.createLLMClient(llm),
    model: llm.model,
    projectRoot: PATHS.BOOKS_DIR,
    defaultLLMConfig: llm,
    foundationReviewRetries: projectConfig.foundation?.reviewRetries,
    writingReviewRetries: projectConfig.writing?.reviewRetries ?? 1,
    modelOverrides: projectConfig.modelOverrides,
    modelOverrideApiKeys,
    inputGovernanceMode: projectConfig.inputGovernanceMode || 'v2',
    notifyChannels: projectConfig.notify || [],
    logger,
    get externalContext() {
      return currentOptions(options).externalContext;
    },
    onWriterTextDelta(text) {
      currentOptions(options).callbacks?.onTextDelta?.(text);
    },
    onStreamProgress(progress) {
      currentOptions(options).callbacks?.onStreamProgress?.(progress);
    },
  };
  const diagnostics = new core.FrameworkDiagnostics([makeDiagnosticSink(options)]);
  return core.createInkOSRuntime(pipelineConfig, { diagnostics });
}

/** Create an independent framework runtime for embedding and focused tests. */
export async function createPublisherInkOSRuntime(options = {}) {
  return createRuntimeFromInputs(readRuntimeInputs(), options);
}

export async function runPublisherInkOS(operation, bookId, options = {}) {
  const inputs = readRuntimeInputs();
  const lease = await sharedRuntime.acquire(
    inputs.signature,
    () => createRuntimeFromInputs(inputs, {}),
  );
  const runtime = lease.runtime;
  const operationController = new AbortController();
  activeOperationControllers.add(operationController);
  const signal = options.signal
    ? AbortSignal.any([options.signal, operationController.signal])
    : operationController.signal;
  const callOptions = {
    traceId: options.traceId,
    bookId,
    chapterNumber: options.chapterNumber,
    jobId: options.jobId,
    timeoutMs: options.timeoutMs,
    signal,
    data: options.data,
  };
  try {
    return await operationContext.run({ ...options, bookId }, async () => {
      if (operation === 'book.init') {
        return runtime.inkos.initBook(options.book, options.initOptions, callOptions);
      }
      if (operation === 'write.next') {
        return runtime.inkos.writeNextChapter(bookId, options.wordCount, options.temperature, callOptions);
      }
      if (operation === 'write.revise') {
        return runtime.inkos.reviseDraft(bookId, options.chapterNumber, options.mode, callOptions);
      }
      if (operation === 'write.rewrite') {
        return runtime.inkos.rewriteChapter(bookId, options.chapterNumber, callOptions);
      }
      if (operation === 'review.approve') {
        return runtime.inkos.approveChapter(bookId, options.chapterNumber, callOptions);
      }
      if (operation === 'review.reject') {
        return runtime.inkos.rejectChapter(
          bookId,
          options.chapterNumber,
          { keepSubsequent: options.keepSubsequent, reason: options.reason },
          callOptions,
        );
      }
      if (operation === 'write.sync') {
        return runtime.inkos.resyncChapterArtifacts(bookId, options.chapterNumber, callOptions);
      }
      if (operation === 'write.repair-state') {
        return runtime.inkos.repairChapterState(bookId, options.chapterNumber, callOptions);
      }
      if (operation === 'book.status') {
        return runtime.inkos.getBookStatus(bookId, callOptions);
      }
      throw new Error(`未知的内置 InkOS operation: ${operation}`);
    });
  } finally {
    activeOperationControllers.delete(operationController);
    await lease.release();
  }
}

/** Rotate the process runtime after a configuration update. */
export async function invalidatePublisherInkOSRuntime() {
  await sharedRuntime.invalidate();
}

/** Retire the process runtime during Publisher shutdown. */
export async function shutdownPublisherInkOSRuntime(options = {}) {
  const reason = new Error('Publisher runtime is shutting down');
  for (const controller of activeOperationControllers) controller.abort(reason);
  await sharedRuntime.shutdown(options);
}

export async function closePublisherInkOSRuntime(runtime) {
  await runtime?.kernel?.shutdown?.();
}
