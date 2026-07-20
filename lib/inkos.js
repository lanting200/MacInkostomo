import { readFileSync, readdirSync, existsSync, statSync } from 'fs';
import { join } from 'path';
import { assertBookId, bookPath, PATHS } from './paths.js';
import { verifyMemoryCoverage, backfillChapterSummary } from './story-memory.js';
import { runInkos, spawnInkos } from './inkos-runner.js';
import { wordCount } from './status.js';


const BOOKS_DIR = PATHS.BOOKS_DIR;
const WIKI_SOURCES_DIR = PATHS.WIKI_SOURCES_DIR;
const WORKSPACE_DIR = PATHS.WORKSPACE_DIR;
const MEMORY_FILE = PATHS.MEMORY_FILE;
const MEMORY_DIR = PATHS.MEMORY_DIR;
const INKOS_WRITER_TEXT_PREFIX = '@@INKOS_TEXT@@';

const INKOS_WRITE_PROGRESS_STAGES = [
  {
    stage: 'prepare',
    test: /(?:阶段：)?准备章节输入/,
    label: '准备章节输入',
    detail: '整合分卷约束、故事状态与章节记忆',
  },
  {
    stage: 'draft',
    test: /(?:阶段：撰写章节草稿|阶段 1：创作正文)/,
    label: '请求：创作章节正文',
    detail: '由写作模型生成本章正文',
  },
  {
    stage: 'settle',
    test: /阶段 2：状态结算/,
    label: '请求：结算故事状态',
    detail: '核对人物、资源和剧情推进',
  },
  {
    stage: 'facts',
    test: /阶段 2a：提取.*事实/,
    label: '请求：提取章节事实',
    detail: '识别本章发生的可持续剧情变化',
  },
  {
    stage: 'truth',
    test: /阶段 2b：把观察结果回写到真相文件/,
    label: '写入：更新故事状态',
    detail: '将已确认事实回写到故事状态文件',
  },
  {
    stage: 'normalize',
    test: /审计前字数归一化/,
    label: '校准：整理章节长度',
    detail: '在自审前统一正文长度与段落结构',
  },
  {
    stage: 'audit',
    test: /阶段：审计草稿/,
    label: '请求：InkOS 自审',
    detail: '检查连续性、设定、节奏和文本质量',
  },
  {
    stage: 'repair',
    test: /修复轮次/,
    label: '请求：修复自审问题',
    detail: '根据自审结果修订本章；无问题时会自动跳过',
  },
  {
    stage: 'persist',
    test: /阶段：落盘最终章节/,
    label: '写入：保存最终章节',
    detail: '正在写入正文和章节索引',
  },
  {
    stage: 'final_truth',
    test: /阶段：生成最终真相文件/,
    label: '写入：生成最终故事状态',
    detail: '生成供下一章使用的状态文件',
  },
  {
    stage: 'validate_truth',
    test: /阶段：校验真相文件变更/,
    label: '校验：验证故事状态',
    detail: '检查新增事实与既有设定是否一致',
  },
  {
    stage: 'memory_index',
    test: /阶段：同步记忆索引/,
    label: '同步：更新章节记忆',
    detail: '同步后续续写所需的记忆索引',
  },
];

function createInkosWriteProgressReporter(onProgress) {
  let pending = '';
  let lastEventKey = '';

  const emitLine = (line) => {
    const normalized = line.replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, '').trim();
    if (!normalized) return;
    const matched = INKOS_WRITE_PROGRESS_STAGES.find(item => item.test.test(normalized));
    if (!matched) return;
    const repairRound = normalized.match(/修复轮次\s+(\d+\/\d+)/)?.[1];
    const eventKey = repairRound ? `${matched.stage}:${repairRound}` : matched.stage;
    if (eventKey === lastEventKey) return;
    lastEventKey = eventKey;
    try {
      onProgress({
        stage: matched.stage,
        eventKey,
        label: repairRound ? `${matched.label}（第${repairRound}轮）` : matched.label,
        detail: matched.detail,
      });
    } catch (err) {
      console.warn(`[inkos-progress] callback failed: ${err.message}`);
    }
  };

  return {
    push(text) {
      if (typeof onProgress !== 'function') return;
      const lines = `${pending}${text}`.split(/\r?\n/);
      pending = lines.pop() || '';
      lines.forEach(emitLine);
    },
    flush() {
      emitLine(pending);
      pending = '';
    },
  };
}

function createInkosWriterTextReporter(onTextDelta) {
  let pending = '';

  const emitLine = (line) => {
    const markerAt = line.indexOf(INKOS_WRITER_TEXT_PREFIX);
    if (markerAt < 0) return;
    try {
      const payload = JSON.parse(line.slice(markerAt + INKOS_WRITER_TEXT_PREFIX.length));
      if (payload?.type !== 'writer_delta' || typeof payload.text !== 'string' || !payload.text) return;
      onTextDelta(payload.text);
    } catch (err) {
      console.warn(`[inkos-stream] 无法解析正文流式片段: ${err.message}`);
    }
  };

  return {
    push(text) {
      if (typeof onTextDelta !== 'function') return;
      const lines = `${pending}${text}`.split(/\r?\n/);
      pending = lines.pop() || '';
      lines.forEach(emitLine);
    },
    flush() {
      if (typeof onTextDelta === 'function') emitLine(pending);
      pending = '';
    },
  };
}

function parseInkosJsonOutput(stdout, stderr = '') {
  const cleanStdout = String(stdout || '')
    .split(/\r?\n/)
    .filter(line => !line.includes(INKOS_WRITER_TEXT_PREFIX))
    .join('\n')
    .trim();
  try {
    return JSON.parse(cleanStdout);
  } catch {
    return { raw: cleanStdout, ...(stderr ? { stderr } : {}) };
  }
}

function runInkosStreaming(args, opts = {}) {
  const {
    cwd = BOOKS_DIR,
    timeout = 600000,
    label = 'inkos',
    onOutput,
    env,
  } = opts;
  return new Promise((resolve, reject) => {
    const child = spawnInkos(args, {
      cwd,
      env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    let timedOut = false;
    let settled = false;
    const maxBuffer = 20 * 1024 * 1024;
    const append = (current, chunk) => {
      const next = current + chunk;
      return next.length > maxBuffer ? next.slice(next.length - maxBuffer) : next;
    };
    const logChunk = (stream, chunk) => {
      const text = chunk.toString();
      const trimmed = text
        .split(/\r?\n/)
        .filter(line => !line.startsWith(INKOS_WRITER_TEXT_PREFIX))
        .join('\n')
        .trimEnd();
      if (trimmed) console.log(`[${label}:${stream}] ${trimmed}`);
      if (typeof onOutput === 'function') {
        try {
          onOutput({ stream, text });
        } catch (err) {
          console.warn(`[${label}] output callback failed: ${err.message}`);
        }
      }
      return text;
    };
    const timer = setTimeout(() => {
      timedOut = true;
      console.warn(`[${label}] timeout after ${timeout}ms; killing inkos ${args.join(' ')}`);
      child.kill('SIGTERM');
      setTimeout(() => {
        if (!settled) child.kill('SIGKILL');
      }, 5000).unref();
    }, timeout);
    child.stdout.on('data', chunk => {
      stdout = append(stdout, logChunk('stdout', chunk));
    });
    child.stderr.on('data', chunk => {
      stderr = append(stderr, logChunk('stderr', chunk));
    });
    child.on('error', err => {
      clearTimeout(timer);
      settled = true;
      err.stdout = stdout;
      err.stderr = stderr;
      reject(err);
    });
    child.on('close', (code, signal) => {
      clearTimeout(timer);
      settled = true;
      if (code === 0 && !timedOut) {
        resolve({ stdout, stderr, code, signal });
        return;
      }
      const err = new Error(
        timedOut
          ? `inkos ${args.join(' ')} timed out after ${timeout}ms`
          : `inkos ${args.join(' ')} exited with ${code ?? signal}`
      );
      err.stdout = stdout;
      err.stderr = stderr;
      err.code = code;
      err.signal = signal;
      err.timedOut = timedOut;
      reject(err);
    });
  });
}

// --- Unified domain term table ----------------------------------------------
// Previously buildSearchQueries and extractKeywords each maintained their own
// overlapping-but-divergent regex list. Add new terms here once.
const DOMAIN_TERMS = [
  // dynasties
  /唐朝/g, /唐代/g, /宋朝/g, /宋代/g, /明朝/g, /明代/g, /汉朝/g, /汉代/g, /清朝/g, /清末/g,
  /春秋/g, /战国/g, /南北朝/g, /五代/g, /隋唐/g, /先秦/g, /殷商/g, /西周/g, /东周/g, /唐宋/g, /元朝/g,
  // classics
  /《[^》]+》/g, /道德经/g, /庄子/g, /老子/g, /易经/g, /周易/g, /黄帝内经/g, /山海经/g, /抱朴子/g,
  /黄庭经/g, /参同契/g, /悟真篇/g, /清静经/g, /阴符经/g, /度人经/g,
  // figures
  /张道陵/g, /葛洪/g, /陶弘景/g, /孙思邈/g, /陈抟/g, /王重阳/g, /丘处机/g, /张三丰/g, /吕洞宾/g, /钟离权/g, /魏伯阳/g,
  // daoist practice
  /符箓/g, /符咒/g, /引魂符/g, /镇煞符/g, /清心符/g, /驱邪/g, /画符/g, /掐诀/g,
  /黄表纸/g, /朱砂/g, /丹田/g, /气海/g, /命门/g, /炼丹/g, /内丹/g, /外丹/g, /周天/g, /经脉/g,
  /斋醮/g, /科仪/g, /禹步/g, /步罡/g, /踏斗/g, /引魂/g, /镇煞/g, /清心/g,
  // cosmology
  /青龙/g, /白虎/g, /朱雀/g, /玄武/g, /天蓬/g, /天芮/g, /天冲/g, /天辅/g, /天禽/g, /天心/g, /天柱/g, /天任/g, /天英/g, /天蓬星/g,
  /五行/g, /天干/g, /地支/g, /甲子/g, /纳音/g, /六十甲子/g, /天乙/g, /太乙/g, /紫微/g, /七政/g, /四余/g,
];
const KEYWORD_CHARS = ['符', '魂', '煞', '丹', '卦', '爻', '宫', '星', '门'];

// --- mtime-based file content cache -----------------------------------------
// Avoids re-reading all 196 wiki sources + memory files on every /revise.
const fileCache = new Map(); // path -> { mtimeMs, content }

function readWithCache(filePath) {
  let st;
  try {
    st = statSync(filePath);
  } catch (err) {
    return null; // missing or unreadable
  }
  const cached = fileCache.get(filePath);
  if (cached && cached.mtimeMs === st.mtimeMs) {
    return cached.content;
  }
  let content;
  try {
    content = readFileSync(filePath, 'utf-8');
  } catch (err) {
    console.error(`[inkos] 读取文件失败 ${filePath}:`, err.message);
    return null;
  }
  fileCache.set(filePath, { mtimeMs: st.mtimeMs, content });
  return content;
}

/**
 * Retrieve relevant knowledge from OpenClaw memory + wiki sources (196 ancient texts).
 */
// Retrieve knowledge-base context for a chapter.
// opts.maxHits     — cap number of hits (default: 8, from deduplicateAndRank)
// opts.maxCharsPerHit — truncate each hit's text to this many chars (default: off).
//   revise injects full-text (LLM needs the detail for targeted edits); rewrite
//   passes a small cap so the --brief stays focused — InkOS only needs the
//   *gist + source* of each reference to keep 术法/数术 terminology consistent
//   across hundreds of chapters, not the full primary source.
export function retrieveKnowledge(chapterContent, revisionNote, opts = {}) {
  const { maxHits = 8, maxCharsPerHit = 0 } = opts;
  const queries = buildSearchQueries(chapterContent, revisionNote);
  const allResults = [];

  for (const query of queries) {
    try {
      const result = searchAllSources(query);
      if (result && result.length > 0) {
        allResults.push({ query, hits: result });
      }
    } catch (err) {
      console.error(`[inkos] Knowledge search failed for query "${query}":`, err.message);
    }
  }

  let knowledge = deduplicateAndRank(allResults);
  if (maxHits && maxHits < knowledge.length) knowledge = knowledge.slice(0, maxHits);
  if (knowledge.length === 0) return null;

  const formatted = knowledge.map((k, i) => {
    const body = (maxCharsPerHit && k.text.length > maxCharsPerHit)
      ? k.text.slice(0, maxCharsPerHit) + '…'
      : k.text;
    return `[${i + 1}] ${body}\n    (来源: ${k.source || '知识库'})`;
  }).join('\n\n');

  return formatted;
}

function extractDomainTerms(text) {
  const found = new Set();
  for (const pattern of DOMAIN_TERMS) {
    const matches = text.match(pattern);
    if (matches) for (const m of matches) found.add(m);
  }
  return [...found];
}

function buildSearchQueries(content, note) {
  const queries = [];

  // 1. Keywords from revision note
  if (note) {
    const noteKeywords = extractDomainTerms(note);
    // also add 2-4 char tokens between delimiters
    const tokens = note.replace(/[，。！？、；：""''（）【】《》\n\r\t]/g, ' ')
      .split(/\s+/).filter(t => t.length >= 2 && t.length <= 4);
    for (const t of tokens) if (!noteKeywords.includes(t)) noteKeywords.push(t);
    if (noteKeywords.length > 0) {
      queries.push(noteKeywords.slice(0, 3).join(' '));
    }
  }

  // 2. Domain terms found in chapter content
  const contentTerms = extractDomainTerms(content);
  for (const m of contentTerms.slice(0, 6)) {
    queries.push(m);
  }

  // 3. Important single chars present in content
  for (const ch of KEYWORD_CHARS) {
    if (content.includes(ch)) queries.push(ch);
  }

  // 4. General context (intro)
  const intro = content.substring(0, 100).replace(/\n/g, ' ');
  if (intro.length > 20) {
    queries.push(intro);
  }

  return queries.slice(0, 6);
}

function searchAllSources(query) {
  const keywords = query.split(/\s+/).filter(q => q.length >= 1);
  if (keywords.length === 0) return [];
  const results = [];

  // 1. Search wiki sources (196 ancient texts)
  if (existsSync(WIKI_SOURCES_DIR)) {
    let files;
    try {
      files = readdirSync(WIKI_SOURCES_DIR).filter(f => f.endsWith('.md'));
    } catch (err) {
      console.error('[inkos] 无法读取 wiki sources 目录:', err.message);
      files = [];
    }
    for (const file of files) {
      const filePath = join(WIKI_SOURCES_DIR, file);
      const content = readWithCache(filePath);
      if (content === null) continue;
      const lines = content.split('\n');
      const matchData = []; // {idx, keywordCount}
      lines.forEach((line, idx) => {
        let kc = 0;
        for (const q of keywords) {
          if (q.length >= 2 && line.includes(q)) kc++;
          else if (q.length === 1 && line.includes(q)) kc += 0.3; // single char = weak match
        }
        if (kc > 0) matchData.push({ idx, kc, line });
      });
      if (matchData.length > 0) {
        // Sort matches by keyword count descending, take top 3
        matchData.sort((a, b) => b.kc - a.kc);
        const contextLines = [];
        for (let i = 0; i < matchData.length && i < 3; i++) {
          const idx = matchData[i].idx;
          const start = Math.max(0, idx - 1);
          const end = Math.min(lines.length, idx + 3);
          contextLines.push(lines.slice(start, end).join('\n'));
        }
        // Score: keyword relevance + file name bonus
        const totalKc = matchData.reduce((s, m) => s + m.kc, 0);
        const nameBonus = keywords.some(q => file.includes(q)) ? 0.3 : 0;
        results.push({
          text: contextLines.join('\n---\n'),
          source: `wiki/sources/${file}`,
          score: 0.5 + Math.min(totalKc * 0.1, 0.5) + nameBonus,
        });
      }
    }
  }

  // 2. Search MEMORY.md
  if (existsSync(MEMORY_FILE)) {
    const content = readWithCache(MEMORY_FILE);
    if (content !== null) {
      const lines = content.split('\n');
      const matches = lines.filter(l => keywords.some(q => q.length >= 2 && l.includes(q)));
      if (matches.length > 0) {
        results.push({ text: matches.slice(0, 3).join('\n'), source: 'MEMORY.md', score: 0.5 });
      }
    }
  }

  // 3. Search memory/ directory
  if (existsSync(MEMORY_DIR)) {
    let files;
    try {
      files = readdirSync(MEMORY_DIR, { recursive: true });
    } catch (err) {
      console.error('[inkos] 无法读取 memory 目录:', err.message);
      files = [];
    }
    for (const file of files) {
      if (typeof file !== 'string' || !file.endsWith('.md')) continue;
      const filePath = join(MEMORY_DIR, file);
      if (!existsSync(filePath)) continue;
      const content = readWithCache(filePath);
      if (content === null) continue;
      const lines = content.split('\n');
      const matches = lines.filter(l => keywords.some(q => q.length >= 2 && l.includes(q)));
      if (matches.length > 0) {
        results.push({ text: matches.slice(0, 5).join('\n'), source: `memory/${file}`, score: 0.4 });
      }
    }
  }

  return results;
}

function deduplicateAndRank(allResults) {
  const seen = new Set();
  const deduped = [];

  for (const group of allResults) {
    for (const hit of group.hits) {
      const key = hit.text.substring(0, 100);
      if (!seen.has(key) && hit.text.length > 10) {
        seen.add(key);
        deduped.push(hit);
      }
    }
  }

  deduped.sort((a, b) => (b.score || 0) - (a.score || 0));
  return deduped.slice(0, 8);
}

function buildActionableRevisionNote(revisionNote, chapterContent) {
  const note = String(revisionNote || '').trim();
  const additions = [
    '【执行要求】',
    '1. 这是前端审核打回修改，必须真实改写章节正文并写回章节 Markdown 文件；不能只解释、只计划或只刷新 runtime/audit 文件。',
    '2. 只修改本章，不生成新章节，不修改其他章节。',
    '3. 保持章节标题、人物状态、资源账本、上一章衔接和既有伏笔连续。',
  ];

  const explicitRange = note.match(/(\d{3,5})\s*[-—~到至]\s*(\d{3,5})\s*字?/);
  if (/压字数|字数|精简|删减|压缩|控制在/.test(note) || explicitRange) {
    additions.push('4. 长度说明：审核意见中的字数或精简要求仅作编辑参考，不作为硬性验收条件；优先完成内容修改，保留必要情节和上下文，不要把完整章节缩成摘要。');
  }

  if (/(?:不|不要|禁止)(?:新增|添加).{0,12}伏笔|合并.{0,30}(?:伏笔|证据链)/.test(note)) {
    additions.push('5. 伏笔验收：只更新既有伏笔条目，白牙、白屑、黑汁等证据必须并入已有主线；不得新增 new-hook、额外伏笔行或独立谜团。');
  }

  if (/朱砂/.test(note) && /弱化|术法|法术|镇煞|排斥|强防御|防护/.test(note)) {
    additions.push('5. 朱砂验收：必须弱化朱砂效果，只能写轻微迟滞、不适、犹豫；不得写成正式法术、防护罩、强驱邪能力；正文和注释中避免“镇煞”“排斥作用”等强化表述。');
  }

  if (/月光|月亮/.test(note)) {
    additions.push('6. 夜空验收：不得出现“月光”“月亮”字样；用灰蒙蒙光晕、暗紫天光、树冠缝隙灰光等替代。');
  }

  if (/用土|糊上/.test(note)) {
    additions.push('7. 连续性验收：不得保留“老陈让张道用土糊伤口”等上一章未发生的动作。');
  }

  return `${note}\n\n${additions.join('\n')}`;
}

/**
 * Main revision function: retrieves knowledge, then calls InkOS with enriched context.
 * Uses async execFile so the Node event loop is not blocked during the (long) InkOS call.
 */
export async function reviseChapter(bookId, chapterNum, chapterTitle, revisionNote, chapterContent, preferredMode = 'auto', opts = {}) {
  console.log(`[reviseChapter] Retrieving knowledge for chapter ${chapterNum}...`);
  const actionableRevisionNote = buildActionableRevisionNote(revisionNote, chapterContent);
  // Compact references (mirrors rewriteChapter): cap hits + per-hit chars so the
  // --brief stays focused on the edit, not full primary sources that drift the
  // LLM into a 术法 showcase.
  const knowledge = retrieveKnowledge(
    chapterContent || '',
    actionableRevisionNote,
    { maxHits: 5, maxCharsPerHit: 250 },
  );

  let brief;
  if (knowledge) {
    brief = `修改第${chapterNum}章「${chapterTitle}」。参考资料（仅校准术法/数术术语，勿为展示术法新增剧情/道具）：\n${knowledge}\n\n修改要求：${actionableRevisionNote}`;
    console.log(`[reviseChapter] Compact knowledge injected (${knowledge.length} chars)`);
  } else {
    brief = `修改第${chapterNum}章「${chapterTitle}」。修改要求：${actionableRevisionNote}`;
    console.log(`[reviseChapter] No knowledge found, plain brief`);
  }

  // 主路径：inkos revise --mode spot-fix（直接管道命令，保证写章节文件）。
  // 如果 spot-fix 没有实际改写文件，升级到 rework。人工审核反馈常包含
  // 连续性/字数/注释等非 audit issue，spot-fix 可能判定无需动手。
  // A chapter revision can include an InkOS pass, correction pass, and a
  // follow-up review. Keep its single-call allowance aligned with chapter
  // generation so the Publisher does not abandon a real edit at 15 minutes.
  const reviseTimeout = Number(process.env.PUBLISHER_REVISE_TIMEOUT_MS || '2700000');
  const reportProgress = createInkosWriteProgressReporter(opts.onProgress);
  const reportWriterText = createInkosWriterTextReporter(opts.onTextDelta);
  const streamWriterText = typeof opts.onTextDelta === 'function';
  const reportRevisionProgress = (progress) => {
    if (typeof opts.onProgress !== 'function') return;
    try {
      opts.onProgress(progress);
    } catch (err) {
      console.warn(`[inkos-progress] revision callback failed: ${err.message}`);
    }
  };
  const runRevisionInkos = async (args, progress) => {
    reportRevisionProgress(progress);
    // Project config stays non-streaming by default, but an active Publisher
    // request has an SSE consumer. Make the CLI override explicit so the
    // project .env cannot suppress visible writer chunks.
    const commandArgs = streamWriterText ? ['--stream', ...args] : args;
    try {
      const result = await runInkosStreaming(commandArgs, {
        cwd: BOOKS_DIR,
        timeout: reviseTimeout,
        label: `inkos-revise:${bookId}:${chapterNum}`,
        env: streamWriterText
          ? { PUBLISHER_FORCE_LLM_STREAM: 'true', INKOS_EMIT_WRITER_TEXT: 'true' }
          : undefined,
        onOutput: ({ text }) => {
          reportProgress.push(text);
          reportWriterText.push(text);
        },
      });
      reportProgress.flush();
      reportWriterText.flush();
      return result;
    } catch (err) {
      reportProgress.flush();
      reportWriterText.flush();
      throw err;
    }
  };
  const tryRevise = async (mode) => {
    const { stdout, stderr } = await runRevisionInkos(['revise', bookId, String(chapterNum), '--mode', mode, '--brief', brief, '--json'], {
      stage: 'revision_revise',
      eventKey: `revision_revise:${mode}`,
      label: '请求：InkOS 修改正文',
      detail: '正在根据本次反馈改写章节，并保留完整正文结构',
    });
    return parseInkosJsonOutput(stdout, stderr);
  };

  // 回退：inkos interact（agent 会话）。用于 revise 因无 audit issues 拒绝时。
  // interact 不保证写文件——下游靠 reReadChapter 比对内容检测是否真改，未改
  // 则报 noChange 不误报成功。
  const tryInteract = async () => {
    const { stdout, stderr } = await runRevisionInkos(['interact', '--json', '--book', bookId, '--message', brief], {
      stage: 'revision_interact',
      eventKey: 'revision_interact',
      label: '请求：InkOS 辅助修订',
      detail: '当前修订模式未落盘，正在切换到辅助修订流程',
    });
    return parseInkosJsonOutput(stdout, stderr);
  };

  // 最终兜底：InkOS natural-language agent。revise 在某些情况下只刷新
  // runtime/audit artifacts，不写章节文件；agent 明确要求使用 InkOS 工具把
  // 修订后的正文写回章节文件，随后仍以 reReadChapter 检测是否真的落盘。
  const tryAgent = async () => {
    const instruction = [
      `请直接修改《${bookId}》第${chapterNum}章「${chapterTitle}」，并把修订后的完整章节正文写回该章 Markdown 文件。`,
      `只修改第${chapterNum}章，不要生成新章节，不要改其他章节。`,
      `必须保持章节标题和故事连续性；完成后确保 books/${bookId}/chapters/ 中第${String(chapterNum).padStart(4, '0')} 章文件内容已经变化。`,
      `修改要求：${actionableRevisionNote}`,
    ].join('\n');
    const result = await runRevisionInkos(['agent', '--book', bookId, '--json', instruction], {
      stage: 'revision_agent',
      eventKey: 'revision_agent',
      label: '请求：InkOS 深度修订',
      detail: '正在根据完整反馈重写章节并写回原文件',
    });
    return parseInkosJsonOutput(result.stdout, result.stderr);
  };

  let response;
  let usedFallback = false;
  let usedMode = 'spot-fix';
  const requestedMode = (preferredMode || '').toLowerCase();
  if ((preferredMode || '').toLowerCase() === 'agent') {
    try {
      usedMode = 'agent';
      response = await tryAgent();
    } catch (err) {
      return { success: false, error: `InkOS agent 修订失败: ${err.message}`, stdout: err.stdout, stderr: err.stderr, reviseMode: usedMode, knowledgeInjected: knowledge ? knowledge.length : 0 };
    }
    const agentContent = reReadChapter(bookId, chapterNum);
    if (agentContent === null) {
      console.error(`[reviseChapter] reReadChapter returned null after agent for chapter ${chapterNum} (book ${bookId})`);
      return { success: false, reReadFailed: true, response, error: 'InkOS agent 已执行但重读章节文件失败', reviseMode: usedMode, knowledgeInjected: knowledge ? knowledge.length : 0 };
    }
    if (agentContent === chapterContent) {
      console.log(`[reviseChapter] 章节正文未变化（InkOS agent 无改动），不报成功`);
      return { success: false, noChange: true, response, reviseMode: usedMode, error: 'InkOS agent 未产生改动', knowledgeInjected: knowledge ? knowledge.length : 0 };
    }
    return { success: true, response, newContent: agentContent, reviseMode: usedMode, knowledgeInjected: knowledge ? knowledge.length : 0 };
  }

  try {
    if (['spot-fix', 'polish', 'rewrite', 'rework', 'anti-detect'].includes(requestedMode)) {
      usedMode = requestedMode;
    }
    response = await tryRevise(usedMode);
  } catch (err) {
    const msg = (err.message || '') + ' ' + (err.stderr || '');
    if (/audit|no.*issue|nothing.*revise|没有.*审计|无.*问题/i.test(msg)) {
      console.log(`[reviseChapter] revise 无 audit issues，回退 interact: ${msg.slice(0, 120)}`);
      usedFallback = true;
      usedMode = 'interact';
      response = await tryInteract();
    } else {
      return { success: false, error: err.message, stdout: err.stdout, stderr: err.stderr, knowledgeInjected: knowledge ? knowledge.length : 0 };
    }
  }

  // 检测是否真改了文件（避免 interact 未调写作工具时误报成功）。
  const newContent = reReadChapter(bookId, chapterNum);
  if (newContent === null) {
    console.error(`[reviseChapter] reReadChapter returned null for chapter ${chapterNum} (book ${bookId})`);
    return { success: false, reReadFailed: true, response, error: 'InkOS 已执行但重读章节文件失败', knowledgeInjected: knowledge ? knowledge.length : 0 };
  }
  if (newContent === chapterContent) {
    if (!usedFallback && usedMode === 'spot-fix') {
      console.log(`[reviseChapter] spot-fix 未改写章节文件，升级到 rework`);
      try {
        usedMode = 'rework';
        response = await tryRevise(usedMode);
      } catch (err) {
        return { success: false, error: `InkOS revise rework 失败: ${err.message}`, stdout: err.stdout, stderr: err.stderr, knowledgeInjected: knowledge ? knowledge.length : 0 };
      }
      const reworkedContent = reReadChapter(bookId, chapterNum);
      if (reworkedContent === null) {
        console.error(`[reviseChapter] reReadChapter returned null after rework for chapter ${chapterNum} (book ${bookId})`);
        return { success: false, reReadFailed: true, response, error: 'InkOS rework 已执行但重读章节文件失败', knowledgeInjected: knowledge ? knowledge.length : 0 };
      }
      if (reworkedContent !== chapterContent) {
        return { success: true, response, newContent: reworkedContent, reviseMode: usedMode, knowledgeInjected: knowledge ? knowledge.length : 0 };
      }
    }
    if (usedMode !== 'agent') {
      console.log(`[reviseChapter] InkOS ${usedMode} 未改写章节文件，升级到 agent`);
      try {
        usedMode = 'agent';
        response = await tryAgent();
      } catch (err) {
        return { success: false, error: `InkOS agent 修订失败: ${err.message}`, stdout: err.stdout, stderr: err.stderr, reviseMode: usedMode, knowledgeInjected: knowledge ? knowledge.length : 0 };
      }
      const agentContent = reReadChapter(bookId, chapterNum);
      if (agentContent === null) {
        console.error(`[reviseChapter] reReadChapter returned null after agent for chapter ${chapterNum} (book ${bookId})`);
        return { success: false, reReadFailed: true, response, error: 'InkOS agent 已执行但重读章节文件失败', reviseMode: usedMode, knowledgeInjected: knowledge ? knowledge.length : 0 };
      }
      if (agentContent !== chapterContent) {
        return { success: true, response, newContent: agentContent, reviseMode: usedMode, knowledgeInjected: knowledge ? knowledge.length : 0 };
      }
    }
    console.log(`[reviseChapter] 章节正文未变化（${usedFallback ? 'interact 未改文件' : `InkOS ${usedMode} 无改动`}），不报成功`);
    return { success: false, noChange: true, response, reviseMode: usedMode, error: usedFallback ? 'InkOS interact 未修改章节文件（LLM 未调用写作工具）' : `InkOS ${usedMode} 未产生改动`, knowledgeInjected: knowledge ? knowledge.length : 0 };
  }
  return { success: true, response, newContent, reviseMode: usedMode, knowledgeInjected: knowledge ? knowledge.length : 0 };
}

/**
 * Rewrite (re-generate) an existing chapter with InkOS (`inkos write rewrite`).
 *
 * LIMITED TO THE LAST CHAPTER: InkOS write rewrite <N> is destructive — it
 * deletes chapters N..M + downstream snapshots + memory.db, restores state
 * from snapshot N-1, regenerates chapter N. Downstream chapters are GONE and
 * must be re-written with `write next`. Cascade-updating downstream is an
 * unimplemented InkOS roadmap item, so rewriting a non-final chapter would
 * tear coherence. The /rewrite route enforces "last chapter only" upstream.
 *
 * brief hard-injects the previous chapter's tail as anchor text + a must-keep
 * constraint block, because InkOS's story/ summaries drop detail and a
 * rewrite can otherwise invent items/contradict established facts.
 *
 * prevTail = previous chapter's tail text (server reads from state.json).
 * nextHead is NOT injected: this is the last chapter, there is no next chapter.
 */
export async function rewriteChapter(bookId, chapterNum, chapterTitle, brief, chapterContent, prevTail = null, nextHead = null) {
  console.log(`[rewriteChapter] Retrieving knowledge for chapter ${chapterNum}...`);
  const knowledge = retrieveKnowledge(
    chapterContent || '',
    brief || `重写第${chapterNum}章`,
    { maxHits: 5, maxCharsPerHit: 250 },
  );

  const parts = [];
  parts.push(`重写第${chapterNum}章「${chapterTitle}」。这是对已存在章节的重写，必须与相邻章节严格衔接，不得破坏既定设定。`);

  if (prevTail) {
    parts.push(`【上一章（第${chapterNum - 1}章）结尾原文，本章必须紧接此情节续写，承接其场景、人物状态、所处位置】：\n${prevTail}`);
  }
  // nextHead intentionally not used: rewrite is last-chapter-only, no downstream.
  void nextHead;

  const constraint = [
    '【硬约束 — 必须遵守】：',
    '1. 不得新增上一章未出现过的道具、法器、人物能力。主角的家当以相邻章原文为准。',
    '2. 不得否定相邻章已确立的事实（物品已用完/已丢失、人物受伤部位与来源、时间线）。',
    '3. 不得重启上一章已结束的遭遇/战斗；本章应从上一章结尾的状态自然推进。',
    '4. 保持与相邻章一致的叙事节奏与段落长度，避免短句堆砌。',
  ].join('\n');
  parts.push(constraint);

  if (knowledge) {
    parts.push(`【知识库参考资料（重写涉及术法/数术时术语请与之一致，勿自行编造；但不得为展示术法而新增剧情或道具）】：\n${knowledge}`);
    console.log(`[rewriteChapter] Compact knowledge injected (${knowledge.length} chars), calling inkos write rewrite...`);
  } else {
    console.log(`[rewriteChapter] No knowledge found, calling inkos write rewrite with plain brief...`);
  }
  if (brief) parts.push(`【创作指导】：${brief}`);

  const briefText = parts.join('\n\n');

  try {
    const { stdout } = await runInkos(['write', 'rewrite', bookId, String(chapterNum), '--force', '--brief', briefText, '--json'], {
      cwd: BOOKS_DIR,
      timeout: 600000,
      encoding: 'utf-8',
      maxBuffer: 20 * 1024 * 1024,
    });

    let response;
    try { response = JSON.parse(stdout); } catch { response = { raw: stdout }; }

    const newContent = reReadChapter(bookId, chapterNum);
    if (newContent === null) {
      console.error(`[rewriteChapter] InkOS rewrite succeeded but reReadChapter returned null for chapter ${chapterNum} (book ${bookId})`);
      return { success: false, reReadFailed: true, response, error: 'InkOS 已执行但重读章节文件失败，请检查文件是否被移动或重命名', knowledgeInjected: knowledge ? knowledge.length : 0 };
    }
    return { success: true, response, newContent, knowledgeInjected: knowledge ? knowledge.length : 0 };
  } catch (err) {
    return {
      success: false,
      error: err.message,
      stdout: err.stdout,
      stderr: err.stderr,
      knowledgeInjected: knowledge ? knowledge.length : 0,
    };
  }
}

// Read chapters/index.json for a book. Returns the array (each item has
// number/title/status/wordCount/...). Used to detect the new chapter number
// after `inkos write next` appends one, and to reconcile chapter-publisher's
// state.json against InkOS's chapters/index.json after a destructive rewrite.
export function parseChapterIndex(raw) {
  const entries = JSON.parse(String(raw));
  if (!Array.isArray(entries)) throw new Error('索引根节点必须是数组');
  const seen = new Set();
  for (const entry of entries) {
    const number = entry?.number;
    if (!Number.isSafeInteger(number) || number < 1) {
      throw new Error(`章节号无效: ${String(number)}`);
    }
    if (seen.has(number)) throw new Error(`章节号重复: ${number}`);
    seen.add(number);
  }
  return entries;
}

export function readChapterIndex(bookId, options = {}) {
  const safeBookId = assertBookId(bookId);
  const idxPath = bookPath(safeBookId, 'chapters', 'index.json');
  try {
    if (!existsSync(idxPath)) return [];
    return parseChapterIndex(readFileSync(idxPath, 'utf-8'));
  } catch (err) {
    const wrapped = new Error(`InkOS 章节索引损坏 (${safeBookId}): ${err.message}`);
    wrapped.code = 'INKOS_INDEX_INVALID';
    wrapped.statusCode = 503;
    wrapped.cause = err;
    console.error(`[inkos] readChapterIndex 失败 ${idxPath}:`, err.message);
    if (options.strict) throw wrapped;
    return [];
  }
}

// InkOS write rewrite <N> requires story/snapshots/<N-1>/ to exist (it
// restores state from that snapshot before regenerating chapter N). Missing
// it throws "Cannot rewrite chapter N: missing snapshot for chapter N-1"
// AFTER we've already mutated state — so check up front. Returns the dir
// path if present, null otherwise.
export function snapshotExistsFor(bookId, chapterNum) {
  if (chapterNum < 1) return null;
  const dir = bookPath(bookId, 'story', 'snapshots', String(chapterNum));
  return existsSync(dir) ? dir : null;
}

/**
 * Generate a brand-new chapter with InkOS.
 *
 * Production mode uses `inkos write next` so InkOS owns the full planning,
 * writing, audit, memory, and pacing pipeline. `draft` remains available as an
 * explicit diagnostic fallback via PUBLISHER_GENERATE_MODE=draft.
 */
export async function generateChapter(bookId, guidance, opts = {}) {
  const mode = (process.env.PUBLISHER_GENERATE_MODE || 'write').toLowerCase();
  console.log(`[generateChapter] inkos ${mode === 'draft' ? 'draft' : 'write next'} for ${bookId}...`);
  const oldIndex = readChapterIndex(bookId, { strict: true });
  const oldLen = oldIndex.length;
  const reportProgress = createInkosWriteProgressReporter(opts.onProgress);
  const reportWriterText = createInkosWriterTextReporter(opts.onTextDelta);

  // Story-memory coherence guard (pre-check): warn if InkOS's
  // chapter_summaries.md has fallen behind the actual chapter count.
  // Non-blocking — just makes drift visible in server logs before a run.
  try {
    verifyMemoryCoverage(bookId);
  } catch (err) {
    console.warn(`[generateChapter] story-memory 校验异常(忽略): ${err.message}`);
  }

  const args = mode === 'draft' ? ['draft', bookId] : ['write', 'next', bookId];
  const words = process.env.PUBLISHER_GENERATE_WORDS || process.env.PUBLISHER_DRAFT_WORDS;
  if (words) args.push('--words', words);
  if (guidance) args.push('--context', guidance);

  let stdout = '';
  let stderr = '';
  let lastError = null;
  // A full InkOS write can legitimately spend 15+ minutes across draft,
  // settlement, audit, revision, and final truth-file generation. Do not
  // retry by default: retrying after a total-timeout starts the same chapter
  // from scratch and can waste a completed-but-not-yet-indexed run.
  const attempts = Number(process.env.PUBLISHER_GENERATE_RETRIES || process.env.PUBLISHER_DRAFT_RETRIES || '0') + 1;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      console.log(`[generateChapter] attempt ${attempt}/${attempts}: inkos ${args.join(' ')}`);
      const commandArgs = typeof opts.onTextDelta === 'function' ? ['--stream', ...args] : args;
      const result = await runInkosStreaming(commandArgs, {
        cwd: BOOKS_DIR,
        timeout: Number(process.env.PUBLISHER_GENERATE_TIMEOUT_MS || process.env.PUBLISHER_DRAFT_TIMEOUT_MS || '2700000'),
        label: `inkos-generate:${bookId}:try${attempt}`,
        // Enable token streaming for this one Publisher request only. The
        // project config remains no-thinking and can keep stream:false for
        // other InkOS commands.
        env: typeof opts.onTextDelta === 'function'
          ? { PUBLISHER_FORCE_LLM_STREAM: 'true', INKOS_EMIT_WRITER_TEXT: 'true' }
          : undefined,
        onOutput: ({ text }) => {
          reportProgress.push(text);
          reportWriterText.push(text);
        },
      });
      reportProgress.flush();
      reportWriterText.flush();
      stdout += result.stdout || '';
      stderr += result.stderr || '';
    } catch (err) {
      reportProgress.flush();
      reportWriterText.flush();
      lastError = err;
      stdout += err.stdout || '';
      stderr += err.stderr || '';
      console.log(`[generateChapter] attempt ${attempt}/${attempts} failed: ${err.message.slice(0, 200)}`);
      if (err.timedOut) break;
    }

    const currentIndex = readChapterIndex(bookId, { strict: true });
    if (currentIndex.length > oldLen) break;
    if (attempt < attempts) {
      console.warn(`[generateChapter] attempt ${attempt} produced no new chapter; retrying...`);
    }
  }

  // 不管进程返回什么，以磁盘为准：读 index.json 检测新章节
  const newIndex = readChapterIndex(bookId, { strict: true });
  if (newIndex.length > oldLen) {
    const newEntry = newIndex[oldLen];
    const num = newEntry.number;
    const title = newEntry.title || '';
    const newContent = reReadChapter(bookId, num);
    if (newContent === null) {
      return { success: false, reReadFailed: true, error: 'InkOS 生成了章节但重读文件失败', newChapterNum: num, title };
    }
    // Story-memory coherence guard (post-write backfill): if InkOS did not
    // record the new chapter in chapter_summaries.md, publisher appends a
    // heuristic row so the summaries table never falls behind the chapters.
    // This is the direct fix for the "chapter 7 summary missing → chapters
    // 8-9 lost continuity" failure mode.
    try {
      backfillChapterSummary(bookId, num, title, newContent);
    } catch (err) {
      console.warn(`[generateChapter] story-memory 补写异常(忽略): ${err.message}`);
    }
    return { success: true, newChapterNum: num, title, newContent, response: { stdout, stderr } };
  }

  // 尝试从 stdout/stderr 中解析 JSON 获取错误信息
  let resp;
  const combined = (stdout + stderr).split('\n').filter(l => l.trim().startsWith('{')).join('\n');
  try { resp = JSON.parse(combined); } catch {
    try { resp = JSON.parse(stdout); } catch { resp = { raw: (stdout || stderr).slice(0, 500) }; }
  }
  const stderrTail = stderr ? stderr.slice(-1200).trim() : '';
  const stdoutTail = !stderrTail && stdout ? stdout.slice(-1200).trim() : '';
  const detail = stderrTail || stdoutTail;
  const error = lastError
    ? `InkOS 未生成新章节（index.json 未增长）: ${lastError.message}${detail ? `；InkOS 输出：${detail}` : ''}`
    : `InkOS 未生成新章节（index.json 未增长）${detail ? `；InkOS 输出：${detail}` : ''}`;
  return { success: false, error, response: resp };
}


export function reReadChapter(bookId, chapterNum) {
  const chaptersDir = join(BOOKS_DIR, 'books', bookId, 'chapters');
  const paddedNum = String(chapterNum).padStart(4, '0');

  try {
    const files = readdirSync(chaptersDir).filter(f => f.startsWith(paddedNum));
    if (files.length === 0) {
      console.warn(`[inkos] reReadChapter: 未找到前缀为 ${paddedNum} 的章节文件 (目录 ${chaptersDir})`);
      return null;
    }

    const content = readFileSync(join(chaptersDir, files[0]), 'utf-8');
    const lines = content.split('\n');
    if (lines[0] && /^#\s*第.*?章/.test(lines[0].trim())) {
      return lines.slice(1).join('\n').replace(/^\n+/, '');
    }
    return content;
  } catch (err) {
    console.error(`[inkos] reReadChapter 读取失败 (目录 ${chaptersDir}):`, err.message);
    return null;
  }
}
