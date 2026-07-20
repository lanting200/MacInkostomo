function invalidEndpoint(message) {
  const err = new Error(message);
  err.code = 'INVALID_LLM_BASE_URL';
  err.statusCode = 400;
  return err;
}

export function normalizeLlmBaseUrl(value, options = {}) {
  const raw = String(value || '').trim();
  if (!raw) {
    if (options.allowEmpty) return '';
    throw invalidEndpoint('请先填写 OpenAI Base URL');
  }

  let parsed;
  try {
    parsed = new URL(raw);
  } catch {
    throw invalidEndpoint('OpenAI Base URL 格式不正确');
  }
  if (!['http:', 'https:'].includes(parsed.protocol)) {
    throw invalidEndpoint('OpenAI Base URL 仅支持 http 或 https');
  }
  if (parsed.username || parsed.password || parsed.search || parsed.hash) {
    throw invalidEndpoint('OpenAI Base URL 不能包含账号、密码、查询参数或片段');
  }

  const hostname = parsed.hostname.toLowerCase();
  const loopback = hostname === 'localhost'
    || hostname === '[::1]'
    || hostname === '::1'
    || /^127(?:\.\d{1,3}){3}$/.test(hostname);
  const allowInsecureHttp = options.allowInsecureHttp
    ?? process.env.PUBLISHER_ALLOW_INSECURE_LLM_HTTP === 'true';
  if (parsed.protocol === 'http:' && !loopback && !allowInsecureHttp) {
    throw invalidEndpoint('远程 OpenAI Base URL 必须使用 HTTPS；HTTP 仅允许本机回环地址');
  }
  return parsed.toString().replace(/\/+$/, '');
}
