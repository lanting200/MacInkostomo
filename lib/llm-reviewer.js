import { readFileSync, existsSync, readdirSync } from 'fs';
import { join } from 'path';
import { getEffectiveInkosConfig, getInkosConfig, getReviewModelConfig } from './inkos-config.js';
import { PATHS } from './paths.js';
import { fetchJsonWithTimeout } from './request-timeout.js';

function parseJsonObject(raw) {
  const text = String(raw || '').trim();
  try { return JSON.parse(text); } catch {}
  const first = text.indexOf('{');
  const last = text.lastIndexOf('}');
  if (first >= 0 && last > first) {
    try { return JSON.parse(text.slice(first, last + 1)); } catch {}
  }
  return null;
}

function readStoryFile(bookId, rel, max = 5000) {
  try {
    const p = join(PATHS.STORY_DIR(bookId), rel);
    if (!existsSync(p)) return '';
    return readFileSync(p, 'utf-8').slice(0, max);
  } catch {
    return '';
  }
}

function readPreviousChapter(bookId, chapterNum, max = 24000) {
  if (!Number.isInteger(chapterNum) || chapterNum <= 1) return '';
  try {
    const chaptersDir = join(PATHS.BOOKS_SUBDIR, bookId, 'chapters');
    const prefix = String(chapterNum - 1).padStart(4, '0');
    const file = readdirSync(chaptersDir)
      .filter(name => name.startsWith(prefix) && name.endsWith('.md'))
      .sort()[0];
    if (!file) return '';
    return readFileSync(join(chaptersDir, file), 'utf-8').slice(0, max);
  } catch {
    return '';
  }
}

export function buildChapterReviewPrompt({ bookId, chapterNum, title, content }) {
  const storyFrame = readStoryFile(bookId, 'outline/story_frame.md', 4500);
  const volumeMap = readStoryFile(bookId, 'outline/volume_map.md', 5500);
  const bookRules = readStoryFile(bookId, 'book_rules.md', 2500);
  const currentState = readStoryFile(bookId, 'current_state.md', 5000);
  const particleLedger = readStoryFile(bookId, 'particle_ledger.md', 6000);
  const objectLedger = readStoryFile(bookId, 'object_ledger.md', 10000);
  const pendingHooks = readStoryFile(bookId, 'pending_hooks.md', 5000);
  const chapterSummaries = readStoryFile(bookId, 'chapter_summaries.md', 9000);
  const characterMatrix = readStoryFile(bookId, 'character_matrix.md', 6000);
  const previousChapter = readPreviousChapter(bookId, chapterNum);

  return `你是小说章节初审编辑。请审核刚生成的章节是否可以交给人类终审。

审核顺序（必须执行）：
1. 先做相邻章硬连续性核对：时间、地点、伤势、人物已知信息、持有物和数量是否自然承接。
2. 再做持久物品核对：按持有者、用途、独特损痕、关联伏笔和上下文识别同一物品。对照持久对象账本，检查材质、刻字/纹样、形状、数量、持有者、位置、损坏和状态。无正文解释的变化属于严重设定冲突，必须 pass=false。
3. 检查跨多章伏笔物品。物品隔了很多章没出现也不能改变稳定属性；不要因为都叫“令牌/戒指/剑/钥匙”就把不同物品混为一件。
4. 检查基础设定、角色弧线、分卷推进、book_rules、金手指代价、信息边界。
5. 检查断章、乱码、重复、空洞大纲、未完成正文，以及没有推进/冲突/章末钩子的严重节奏问题。

发现同一物品冲突时，issues 必须同时写明“既有事实”和“本章冲突事实”，不能只写笼统的“注意连续性”。任何硬连续性冲突都不得通过。

只输出 JSON，不要 Markdown，不要解释。格式：
{
  "pass": true/false,
  "summary": "一句话审核结论",
  "issues": ["问题1", "问题2"],
  "revisionGuidance": "如果不通过，给作者可直接提交的 2-6 条修改指令；写清改什么、保留什么和完成标准，不要写审核日志、标签或思考过程；通过则为空字符串"
}

【story_frame 摘要】
${storyFrame}

【volume_map 摘要】
${volumeMap}

【book_rules】
${bookRules}

【当前状态】
${currentState}

【资源账本】
${particleLedger}

【持久对象账本：跨章硬事实】
${objectLedger}

【pending_hooks】
${pendingHooks}

【章节摘要】
${chapterSummaries}

【人物与信息边界】
${characterMatrix}

【上一章全文：相邻章硬连续性】
${previousChapter || '（第一章，无前文）'}

【待审章节】
第${chapterNum}章 ${title}

${String(content || '').slice(0, 24000)}`;
}

function normalizeReview(data, fallbackText) {
  const issues = Array.isArray(data?.issues) ? data.issues.map(x => String(x).trim()).filter(Boolean) : [];
  const revisionGuidance = String(data?.revisionGuidance || '').trim();
  const pass = Boolean(data?.pass) && issues.length === 0;
  return {
    pass,
    summary: String(data?.summary || fallbackText || '').trim().slice(0, 1000),
    issues,
    revisionGuidance: revisionGuidance || (issues.length ? `请修复以下问题：\n${issues.map((x, i) => `${i + 1}. ${x}`).join('\n')}` : ''),
  };
}

export async function reviewGeneratedChapter({ bookId, chapterNum, title, content }) {
  const stored = getInkosConfig();
  const effective = getEffectiveInkosConfig();
  const cfg = getReviewModelConfig(stored, effective);
  if (!cfg.apiKey) throw new Error('缺少设定/审核模型 API Key，请先在设置里配置');
  if (!cfg.model) throw new Error('缺少设定/审核模型，请先在设置里配置');

  const prompt = buildChapterReviewPrompt({ bookId, chapterNum, title, content });

  const url = `${cfg.baseUrl.replace(/\/$/, '')}/chat/completions`;
  const body = {
    model: cfg.model,
    stream: false,
    temperature: 0.1,
    response_format: { type: 'json_object' },
    messages: [
      { role: 'system', content: '你只输出严格 JSON。你不展示推理过程。' },
      { role: 'user', content: prompt },
    ],
  };

  const { response: res, data } = await fetchJsonWithTimeout(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${cfg.apiKey}` },
    body: JSON.stringify(body),
  }, Number(process.env.PUBLISHER_REVIEW_TIMEOUT_MS || '300000'), {
    label: '章节初审请求',
  });
  if (!res.ok) {
    const msg = data?.error?.message || data?.message || `${res.status} ${res.statusText}`;
    throw new Error(`LLM 初审失败: ${msg}`);
  }
  const contentText = data?.choices?.[0]?.message?.content || '';
  const parsed = parseJsonObject(contentText) || { pass: false, summary: '审核模型未返回可解析 JSON', issues: ['审核模型未返回可解析 JSON'], revisionGuidance: contentText.slice(0, 1000) };
  return {
    ...normalizeReview(parsed, contentText),
    model: cfg.model,
    baseUrl: cfg.baseUrl,
    reviewedAt: new Date().toISOString(),
  };
}
