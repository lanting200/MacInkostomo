export class RequestTimeoutError extends Error {
  constructor(label, timeoutMs) {
    super(`${label}超时（${Math.ceil(timeoutMs / 1000)} 秒）`);
    this.name = 'RequestTimeoutError';
    this.code = 'ETIMEDOUT';
    this.timeoutMs = timeoutMs;
  }
}

function normalizedTimeout(timeoutMs, fallbackMs = 300000) {
  const value = Number(timeoutMs);
  return Number.isFinite(value) && value > 0 ? value : fallbackMs;
}

export async function fetchJsonWithTimeout(url, options = {}, timeoutMs = 300000, config = {}) {
  const duration = normalizedTimeout(timeoutMs);
  const label = config.label || 'request';
  const fetchImpl = config.fetchImpl || globalThis.fetch;
  const controller = new AbortController();
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, duration);

  try {
    const response = await fetchImpl(url, { ...options, signal: controller.signal });
    const data = await response.json().catch(() => ({}));
    if (timedOut) throw new RequestTimeoutError(label, duration);
    return { response, data };
  } catch (err) {
    if (timedOut) throw new RequestTimeoutError(label, duration);
    throw err;
  } finally {
    clearTimeout(timer);
  }
}
