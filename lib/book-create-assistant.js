import { getEffectiveInkosConfig, getInkosConfig, getReviewModelConfig } from './inkos-config.js';
import { fetchJsonWithTimeout } from './request-timeout.js';

function parseJsonObject(text) {
  const raw = String(text || '').trim();
  if (!raw) throw new Error('LLM 未返回内容');
  try { return JSON.parse(raw); } catch {}
  const fenced = raw.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fenced) {
    try { return JSON.parse(fenced[1]); } catch {}
  }
  const first = raw.indexOf('{');
  const last = raw.lastIndexOf('}');
  if (first >= 0 && last > first) {
    return JSON.parse(raw.slice(first, last + 1));
  }
  throw new Error('LLM 返回的不是有效 JSON');
}

function coerceNumber(value, fallback, min = 1) {
  const n = Number(value);
  return Number.isFinite(n) && n >= min ? Math.round(n) : fallback;
}

function parseWordCount(value) {
  if (Number.isSafeInteger(value)) return value;
  const text = String(value ?? '').trim().replace(/[,_，\s]/g, '');
  const match = text.match(/(\d+(?:\.\d+)?)\s*(万|亿)?/);
  if (!match) return 0;
  const multiplier = match[2] === '亿' ? 100_000_000 : match[2] === '万' ? 10_000 : 1;
  const number = Number(match[1]) * multiplier;
  return Number.isSafeInteger(number) ? number : 0;
}

function inferVolumeCount(value) {
  const matches = String(value || '').match(/第\s*[零一二两三四五六七八九十百千\d]+\s*卷/g) || [];
  return new Set(matches.map(item => item.replace(/\s/g, ''))).size;
}

function normalizeSpecialConstraints(data) {
  const raw = Array.isArray(data.specialConstraints) && data.specialConstraints.length > 0
    ? data.specialConstraints
    : [data.specialConstraints, data.constraints];
  const values = Array.from(new Set(raw
    .flatMap(value => String(value || '').split(/[\r\n;；]+/))
    .map(value => value.trim())
    .filter(Boolean)));
  const bounded = [];
  let totalChars = 0;
  for (const value of values.slice(0, 100)) {
    const item = value.slice(0, Math.min(2_000, 20_000 - totalChars));
    if (!item) break;
    bounded.push(item);
    totalChars += item.length;
    if (totalChars >= 20_000) break;
  }
  return bounded.length > 0 ? bounded : ['保持角色设定、世界规则与时间线前后一致'];
}

export function normalizeCreateBookPayload(input, requirements = '') {
  const data = input && typeof input === 'object' ? input : {};
  const targetChapterWords = Math.min(20_000, Math.max(500, coerceNumber(
    data.targetChapterWords ?? data.chapterWords,
    3000,
    500,
  )));
  const requestedChapters = coerceNumber(data.targetChapters, 200);
  const requestedTotal = parseWordCount(data.targetTotalWords ?? data.totalWordCount ?? data.targetWords ?? data.totalWords);
  const targetTotalWords = Math.min(
    3_000_000,
    Math.max(1_000, requestedTotal || requestedChapters * targetChapterWords),
  );
  const targetChapters = Math.max(1, Math.round(targetTotalWords / targetChapterWords));
  const volumeCount = Math.min(targetChapters, 100, Math.max(1, coerceNumber(
    data.volumeCount,
    inferVolumeCount(data.volumePlan) || 1,
  )));
  const chapterWordTolerance = Math.min(50, Math.max(0, coerceNumber(
    data.chapterWordTolerance ?? data.chapterWordTolerancePercent,
    15,
    0,
  )));
  const specialConstraints = normalizeSpecialConstraints(data);
  return {
    title: String(data.title || '').trim(),
    language: data.language === 'en' ? 'en' : 'zh',
    genre: String(data.genre || 'xuanhuan').trim(),
    platform: String(data.platform || 'tomato').trim(),
    targetChapters,
    chapterWords: targetChapterWords,
    targetTotalWords,
    totalWordCount: targetTotalWords,
    totalWords: String(targetTotalWords),
    volumeCount,
    targetChapterWords,
    chapterWordTolerance,
    specialConstraints,
    premise: String(data.premise || requirements || '').trim(),
    characters: String(data.characters || '').trim(),
    worldbuilding: String(data.worldbuilding || '').trim(),
    outline: String(data.outline || '').trim(),
    volumePlan: String(data.volumePlan || '').trim(),
    pacing: String(data.pacing || '').trim(),
    style: String(data.style || '').trim(),
    constraints: specialConstraints.join('\n'),
  };
}

function buildPrompt(requirements) {
  return [
    '你是 InkOS 小说项目架构师。用户只给了简易需求，你要把它扩写成可直接创建 InkOS 小说的完整设定表单。',
    '只返回一个 JSON 对象，不要 Markdown，不要解释，不要思考过程。',
    'JSON 字段必须完整：',
    '{',
    '  "title": "书名",',
    '  "language": "zh",',
    '  "genre": "xuanhuan|urban|fantasy|sci-fi|fanfic|other",',
    '  "platform": "tomato|qidian|jjwxc|royalroad|other",',
    '  "targetChapters": 200,',
    '  "chapterWords": 3000,',
    '  "targetTotalWords": 600000,',
    '  "volumeCount": 6,',
    '  "targetChapterWords": 3000,',
    '  "chapterWordTolerance": 15,',
    '  "specialConstraints": ["保持角色、世界规则和时间线一致"],',
    '  "totalWords": "例如：60万字",',
    '  "premise": "核心创意/卖点",',
    '  "characters": "主角、配角、反派、关系和成长线",',
    '  "worldbuilding": "世界观、力量体系、规则、禁忌",',
    '  "outline": "开局、阶段目标、中段转折、终局方向",',
    '  "volumePlan": "按卷列出章节范围、卷名、目标、关键转折",',
    '  "pacing": "章节节奏、高潮间隔、前几章钩子",',
    '  "style": "叙事视角、文风、氛围、对话比例",',
    '  "constraints": "禁忌、边界、必须保持的设定"',
    '}',
    '要求：字段内容要能直接喂给 InkOS book create 的 brief；如果用户没有指定字数，默认番茄男频节奏：200章、单章3000字；分卷规划必须与总章数匹配。',
    '',
    `用户简易需求：\n${requirements}`,
  ].join('\n');
}

export async function generateCreateBookPayload(requirements) {
  const userText = String(requirements || '').trim();
  if (!userText) throw new Error('requirements required');

  const stored = getInkosConfig();
  const effective = getEffectiveInkosConfig();
  const cfg = getReviewModelConfig(stored, effective);
  const apiKey = cfg.apiKey;
  const baseUrl = cfg.baseUrl;
  const model = cfg.model;
  if (!apiKey) throw new Error('缺少设定/审核模型 API Key，请先在设置里配置');

  const url = `${baseUrl.replace(/\/$/, '')}/chat/completions`;
  const body = {
    model,
    stream: false,
    temperature: 0.2,
    response_format: { type: 'json_object' },
    messages: [
      { role: 'system', content: '你只输出可解析 JSON。你不展示推理过程。' },
      { role: 'user', content: buildPrompt(userText) },
    ],
  };

  const { response: res, data } = await fetchJsonWithTimeout(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify(body),
  }, Number(process.env.PUBLISHER_CREATE_ASSIST_TIMEOUT_MS || '300000'), {
    label: '设定生成请求',
  });
  if (!res.ok) {
    const msg = data?.error?.message || data?.message || `${res.status} ${res.statusText}`;
    throw new Error(`LLM 生成失败: ${msg}`);
  }
  const content = data?.choices?.[0]?.message?.content || '';
  return {
    model,
    baseUrl,
    payload: normalizeCreateBookPayload(parseJsonObject(content), userText),
  };
}
