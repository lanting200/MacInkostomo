import { existsSync, readFileSync, statSync, unlinkSync } from 'fs';
import { join } from 'path';
import { assertBookId, PATHS } from './paths.js';
import { writePrivateFile } from './private-file.js';

export const LONG_FORM_PLAN_VERSION = 1;
export const MIN_TARGET_TOTAL_WORDS = 1_000;
export const MAX_TARGET_TOTAL_WORDS = 3_000_000;
export const MIN_TARGET_CHAPTER_WORDS = 500;
export const MAX_TARGET_CHAPTER_WORDS = 20_000;

const DEFAULT_TARGET_CHAPTERS = 200;
const DEFAULT_TARGET_CHAPTER_WORDS = 3000;
const DEFAULT_CHAPTER_WORD_TOLERANCE_PERCENT = 15;
const MAX_PLANNED_CHAPTERS = 10_000;
const MAX_VOLUME_COUNT = 100;
const SOURCES = new Set(['created', 'migrated', 'updated']);
const CONSTRAINT_KEYS = [
  'targetTotalWords',
  'volumeCount',
  'targetChapterWords',
  'chapterWordTolerance',
  'specialConstraints',
];
const CONTINUITY_ARRAY_KEYS = [
  'immutableCanon',
  'worldRules',
  'entities',
  'knowledgeBoundaries',
  'timeline',
  'hooks',
];
const CONTINUITY_POLICY_KEYS = [
  'requireContinuousVolumes',
  'allowUnplannedEntities',
  'requireConsistencyDelta',
  'checkpointAtVolumeEnd',
];

function defaultContinuity(source) {
  return {
    immutableCanon: [],
    worldRules: [],
    entities: [],
    knowledgeBoundaries: [],
    timeline: [],
    hooks: [],
    policy: {
      requireContinuousVolumes: true,
      allowUnplannedEntities: true,
      // Existing books may not yet emit the structured consistency delta.
      // New books opt into the strict gate from their first chapter.
      requireConsistencyDelta: source !== 'migrated',
      checkpointAtVolumeEnd: true,
    },
  };
}

function planError(message, statusCode = 400, cause) {
  const err = new Error(message);
  err.code = 'LONG_FORM_PLAN_INVALID';
  err.statusCode = statusCode;
  err.cause = cause;
  return err;
}

function own(object, key) {
  return Object.prototype.hasOwnProperty.call(object || {}, key);
}

function firstDefined(...values) {
  return values.find(value => value !== undefined && value !== null && value !== '');
}

function requireInteger(value, label, { min = 0, max = Number.MAX_SAFE_INTEGER } = {}) {
  const number = typeof value === 'string' && value.trim() !== '' ? Number(value) : value;
  if (!Number.isSafeInteger(number) || number < min || number > max) {
    throw planError(`${label}必须是 ${min}-${max} 范围内的整数`);
  }
  return number;
}

export function parseTargetTotalWords(value) {
  if (Number.isSafeInteger(value)) return value;
  const text = String(value ?? '').trim().replace(/[,_，\s]/g, '');
  if (!text) return null;
  const match = text.match(/(-?\d+(?:\.\d+)?)\s*(万|亿)?/);
  if (!match) return null;
  const multiplier = match[2] === '亿' ? 100_000_000 : match[2] === '万' ? 10_000 : 1;
  const parsed = Number(match[1]) * multiplier;
  return Number.isSafeInteger(parsed) ? parsed : null;
}

function chineseInteger(raw) {
  const text = String(raw || '').trim();
  if (/^\d+$/.test(text)) return Number(text);
  const digits = { 零: 0, 一: 1, 二: 2, 两: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9 };
  const units = { 十: 10, 百: 100, 千: 1000 };
  let section = 0;
  let digit = 0;
  for (const char of text) {
    if (own(digits, char)) {
      digit = digits[char];
      continue;
    }
    const unit = units[char];
    if (!unit) return null;
    section += (digit || 1) * unit;
    digit = 0;
  }
  const value = section + digit;
  return value > 0 ? value : null;
}

export function countVolumesFromText(value) {
  const text = String(value || '');
  if (!text.trim()) return 0;
  const numbers = new Set();
  const patterns = [
    /第\s*([零一二两三四五六七八九十百千\d]+)\s*卷/g,
    /(?:^|[\n\r;；])\s*[-*]?\s*卷\s*([零一二两三四五六七八九十百千\d]+)/g,
  ];
  for (const pattern of patterns) {
    let match;
    while ((match = pattern.exec(text))) {
      const number = chineseInteger(match[1]);
      if (Number.isSafeInteger(number) && number > 0) numbers.add(number);
    }
  }
  if (numbers.size > 0) return numbers.size;
  const total = text.match(/(?:全书)?共\s*([零一二两三四五六七八九十百千\d]+)\s*卷/);
  return total ? (chineseInteger(total[1]) || 0) : 0;
}

function normalizeSpecialConstraints(value) {
  const entries = Array.isArray(value)
    ? value
    : value === undefined || value === null
      ? []
      : [value];
  const flattened = entries.flatMap(entry => String(entry || '').split(/[\r\n;；]+/));
  const normalized = Array.from(new Set(flattened.map(entry => entry.trim()).filter(Boolean)));
  if (normalized.some(entry => entry.length > 2_000)) throw planError('单条特殊约束不能超过 2000 个字符');
  if (normalized.length > 100) throw planError('特殊约束不能超过 100 条');
  if (normalized.reduce((sum, entry) => sum + entry.length, 0) > 20_000) {
    throw planError('特殊约束总长度不能超过 20000 个字符');
  }
  return normalized;
}

function structuredConstraintSource(input) {
  if (input?.longFormPlan?.constraints && typeof input.longFormPlan.constraints === 'object') {
    return input.longFormPlan.constraints;
  }
  if (input?.longFormConstraints && typeof input.longFormConstraints === 'object') {
    return input.longFormConstraints;
  }
  if (input?.constraints && typeof input.constraints === 'object' && !Array.isArray(input.constraints)) {
    return input.constraints;
  }
  return {};
}

function inferredVolumeCount(input) {
  if (Array.isArray(input?.volumes) && input.volumes.length > 0) return input.volumes.length;
  return countVolumesFromText(input?.volumePlan);
}

export function normalizeLongFormConstraints(input = {}, fallback = {}, options = {}) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    throw planError('长篇规划约束必须是对象');
  }
  const structured = structuredConstraintSource(input);
  const targetChapterWordsRaw = firstDefined(
    structured.targetChapterWords,
    input.targetChapterWords,
    input.chapterWords,
    fallback.targetChapterWords,
    DEFAULT_TARGET_CHAPTER_WORDS,
  );
  const targetChapterWords = requireInteger(targetChapterWordsRaw, '目标单章字数', {
    min: MIN_TARGET_CHAPTER_WORDS,
    max: MAX_TARGET_CHAPTER_WORDS,
  });

  const explicitTotal = firstDefined(structured.targetTotalWords, input.targetTotalWords, input.totalWords);
  const fallbackTotal = fallback.targetTotalWords;
  const legacyTargetChapters = firstDefined(input.targetChapters, fallback.targetChapters, DEFAULT_TARGET_CHAPTERS);
  let targetTotalWordsRaw;
  if (explicitTotal !== undefined) {
    targetTotalWordsRaw = parseTargetTotalWords(explicitTotal);
  } else if (fallbackTotal !== undefined) {
    targetTotalWordsRaw = parseTargetTotalWords(fallbackTotal);
  } else {
    targetTotalWordsRaw = requireInteger(legacyTargetChapters, '目标章数', {
      min: 1,
      max: MAX_PLANNED_CHAPTERS,
    }) * targetChapterWords;
  }
  const targetTotalWords = requireInteger(targetTotalWordsRaw, '目标总字数', {
    min: MIN_TARGET_TOTAL_WORDS,
    max: MAX_TARGET_TOTAL_WORDS,
  });

  const targetChapters = Math.round(targetTotalWords / targetChapterWords);
  if (targetChapters < 1) {
    throw planError('目标总字数不足以形成一章，请降低目标单章字数');
  }
  if (targetChapters > MAX_PLANNED_CHAPTERS) {
    throw planError(`规划章节数不能超过 ${MAX_PLANNED_CHAPTERS} 章`);
  }

  const inferredVolumes = inferredVolumeCount(input);
  const volumeCountRaw = firstDefined(
    structured.volumeCount,
    input.volumeCount,
    inferredVolumes || undefined,
    fallback.volumeCount,
    1,
  );
  const volumeCount = requireInteger(volumeCountRaw, '分卷数', { min: 1, max: Math.min(MAX_VOLUME_COUNT, targetChapters) });

  const toleranceRaw = firstDefined(
    structured.chapterWordTolerance,
    input.chapterWordTolerance,
    fallback.chapterWordTolerance,
    DEFAULT_CHAPTER_WORD_TOLERANCE_PERCENT,
  );
  const chapterWordTolerance = requireInteger(toleranceRaw, '单章字数容差百分比', {
    min: 0,
    max: 50,
  });

  let specialValue = firstDefined(
    structured.specialConstraints,
    input.specialConstraints,
    fallback.specialConstraints,
  );
  if (specialValue === undefined && (typeof input.constraints === 'string' || Array.isArray(input.constraints))) {
    specialValue = input.constraints;
  }
  if (specialValue === undefined && typeof input.notes === 'string') specialValue = input.notes;

  const normalized = {
    targetTotalWords,
    volumeCount,
    targetChapterWords,
    chapterWordTolerance,
    specialConstraints: normalizeSpecialConstraints(specialValue),
  };
  if (options.requireSpecialConstraints && normalized.specialConstraints.length === 0) {
    throw planError('新建小说必须至少填写一条特殊约束');
  }
  return normalized;
}

function distribute(total, count) {
  const quotient = Math.floor(total / count);
  const remainder = total % count;
  return Array.from({ length: count }, (_, index) => quotient + (index < remainder ? 1 : 0));
}

function isoTimestamp(value, label) {
  const timestamp = value instanceof Date ? value.toISOString() : String(value || '');
  if (!timestamp || Number.isNaN(Date.parse(timestamp))) throw planError(`${label}不是有效时间`);
  return timestamp;
}

export function buildLongFormPlan(bookId, rawConstraints, options = {}) {
  const safeBookId = assertBookId(bookId);
  const constraints = normalizeLongFormConstraints(rawConstraints);
  const targetChapters = Math.round(constraints.targetTotalWords / constraints.targetChapterWords);
  if (constraints.volumeCount > targetChapters || constraints.volumeCount > MAX_VOLUME_COUNT) {
    throw planError('分卷数不能超过目标章数');
  }

  const minWords = Math.max(1, Math.round(
    constraints.targetChapterWords * (1 - constraints.chapterWordTolerance / 100),
  ));
  const maxWords = Math.round(
    constraints.targetChapterWords * (1 + constraints.chapterWordTolerance / 100),
  );
  const chapterTargets = distribute(constraints.targetTotalWords, targetChapters);
  const incompatible = chapterTargets.find(words => words < minWords || words > maxWords);
  if (incompatible !== undefined) {
    throw planError(`总字数与单章目标不相容：精确章节预算 ${incompatible} 字超出 ${minWords}-${maxWords} 字范围`);
  }

  const volumeChapterCounts = distribute(targetChapters, constraints.volumeCount);
  const chapters = [];
  const volumes = [];
  let chapterIndex = 0;
  for (let volumeIndex = 0; volumeIndex < volumeChapterCounts.length; volumeIndex += 1) {
    const chapterCount = volumeChapterCounts[volumeIndex];
    const startChapter = chapterIndex + 1;
    let volumeWords = 0;
    for (let offset = 0; offset < chapterCount; offset += 1) {
      const number = chapterIndex + 1;
      const targetWords = chapterTargets[chapterIndex];
      chapters.push({
        number,
        volumeNumber: volumeIndex + 1,
        targetWords,
        minWords,
        maxWords,
      });
      volumeWords += targetWords;
      chapterIndex += 1;
    }
    volumes.push({
      number: volumeIndex + 1,
      startChapter,
      endChapter: chapterIndex,
      chapterCount,
      targetWords: volumeWords,
    });
  }

  const now = isoTimestamp(options.now || new Date(), '更新时间');
  const source = SOURCES.has(options.source) ? options.source : 'created';
  const plan = {
    version: LONG_FORM_PLAN_VERSION,
    revision: requireInteger(options.revision ?? 1, '规划修订号', { min: 1 }),
    bookId: safeBookId,
    constraints,
    plan: {
      targetChapters,
      chapterWordRange: { min: minWords, max: maxWords },
      volumes,
      chapters,
    },
    source,
    continuity: defaultContinuity(source),
    createdAt: isoTimestamp(options.createdAt || now, '创建时间'),
    updatedAt: now,
  };
  return validateLongFormPlan(plan, { bookId: safeBookId });
}

function assertObject(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw planError(`${label}必须是对象`);
  return value;
}

function continuityString(value, label, max = 2_000, required = true) {
  if (typeof value !== 'string') throw planError(label + '必须是字符串');
  const text = value.trim();
  if (required && !text) throw planError(label + '不能为空');
  if (text.length > max) throw planError(label + '不能超过 ' + max + ' 个字符');
  return text;
}

function continuityArray(value, label, max) {
  if (!Array.isArray(value)) throw planError(label + '必须是数组');
  if (value.length > max) throw planError(label + '不能超过 ' + max + ' 条');
  return value;
}

function uniqueContinuityIds(items, key, label) {
  const seen = new Set();
  for (const item of items) {
    const id = continuityString(item?.[key], label + '.' + key, 160);
    if (seen.has(id)) throw planError(label + '存在重复 ' + key + ': ' + id);
    seen.add(id);
  }
}

export function validateLongFormPlan(value, options = {}) {
  const root = assertObject(value, '长篇规划');
  if (root.version !== LONG_FORM_PLAN_VERSION) throw planError(`不支持的长篇规划版本: ${String(root.version)}`);
  requireInteger(root.revision, '规划修订号', { min: 1 });
  const safeBookId = assertBookId(root.bookId);
  if (options.bookId !== undefined && safeBookId !== assertBookId(options.bookId)) {
    throw planError('长篇规划的 bookId 与目录不一致');
  }
  if (!SOURCES.has(root.source)) throw planError('长篇规划 source 无效');
  isoTimestamp(root.createdAt, '创建时间');
  isoTimestamp(root.updatedAt, '更新时间');

  const constraints = normalizeLongFormConstraints(assertObject(root.constraints, 'constraints'));
  for (const key of CONSTRAINT_KEYS) {
    if (!own(root.constraints, key)) throw planError(`constraints 缺少 ${key}`);
  }
  for (const key of CONSTRAINT_KEYS) {
    const actual = root.constraints[key];
    const normalized = constraints[key];
    const matches = Array.isArray(normalized)
      ? Array.isArray(actual) && actual.length === normalized.length && actual.every((item, index) => item === normalized[index])
      : actual === normalized;
    if (!matches) throw planError(`constraints.${key} 包含未归一化的值`);
  }

  const plan = assertObject(root.plan, 'plan');
  const targetChapters = requireInteger(plan.targetChapters, '目标章数', { min: 1, max: MAX_PLANNED_CHAPTERS });
  const derivedTargetChapters = Math.round(constraints.targetTotalWords / constraints.targetChapterWords);
  if (targetChapters !== derivedTargetChapters) throw planError('目标章数与总字数/单章目标不一致');
  if (constraints.volumeCount > targetChapters || constraints.volumeCount > MAX_VOLUME_COUNT) throw planError('分卷数不能超过目标章数或 100 卷');

  const wordRange = assertObject(plan.chapterWordRange, 'chapterWordRange');
  const expectedMin = Math.max(1, Math.round(
    constraints.targetChapterWords * (1 - constraints.chapterWordTolerance / 100),
  ));
  const expectedMax = Math.round(
    constraints.targetChapterWords * (1 + constraints.chapterWordTolerance / 100),
  );
  if (wordRange.min !== expectedMin || wordRange.max !== expectedMax) {
    throw planError('章节字数范围与约束不一致');
  }
  if (!Array.isArray(plan.chapters) || plan.chapters.length !== targetChapters) {
    throw planError('逐章预算数量与目标章数不一致');
  }
  if (!Array.isArray(plan.volumes) || plan.volumes.length !== constraints.volumeCount) {
    throw planError('分卷预算数量与分卷数不一致');
  }

  let chapterWordSum = 0;
  let expectedChapter = 1;
  for (const chapter of plan.chapters) {
    assertObject(chapter, `第${expectedChapter}章预算`);
    if (chapter.number !== expectedChapter) throw planError('逐章预算的章节号必须从 1 连续递增');
    requireInteger(chapter.volumeNumber, `第${expectedChapter}章分卷号`, { min: 1, max: constraints.volumeCount });
    requireInteger(chapter.targetWords, `第${expectedChapter}章目标字数`, { min: expectedMin, max: expectedMax });
    if (chapter.minWords !== expectedMin || chapter.maxWords !== expectedMax) {
      throw planError(`第${expectedChapter}章字数范围与全局约束不一致`);
    }
    chapterWordSum += chapter.targetWords;
    expectedChapter += 1;
  }
  if (chapterWordSum !== constraints.targetTotalWords) throw planError('逐章预算总和与目标总字数不一致');

  let volumeWordSum = 0;
  let nextStart = 1;
  for (let index = 0; index < plan.volumes.length; index += 1) {
    const volume = assertObject(plan.volumes[index], `第${index + 1}卷预算`);
    if (volume.number !== index + 1) throw planError('分卷号必须从 1 连续递增');
    if (volume.startChapter !== nextStart) throw planError('分卷章节范围必须连续且无重叠');
    requireInteger(volume.endChapter, `第${index + 1}卷结束章`, { min: volume.startChapter, max: targetChapters });
    const chapterCount = volume.endChapter - volume.startChapter + 1;
    if (volume.chapterCount !== chapterCount) throw planError(`第${index + 1}卷章数与范围不一致`);
    const slice = plan.chapters.slice(volume.startChapter - 1, volume.endChapter);
    if (slice.some(chapter => chapter.volumeNumber !== volume.number)) {
      throw planError(`第${index + 1}卷与逐章分卷归属不一致`);
    }
    const targetWords = slice.reduce((sum, chapter) => sum + chapter.targetWords, 0);
    if (volume.targetWords !== targetWords) throw planError(`第${index + 1}卷字数与逐章预算不一致`);
    volumeWordSum += volume.targetWords;
    nextStart = volume.endChapter + 1;
  }
  if (nextStart !== targetChapters + 1) throw planError('分卷范围未覆盖全部章节');
  if (volumeWordSum !== constraints.targetTotalWords) throw planError('分卷预算总和与目标总字数不一致');
  validateContinuityExtension(root.continuity, { targetChapters, volumeCount: constraints.volumeCount, label: 'continuity' });
  validateContinuityExtension(root.extensions?.continuity, { targetChapters, volumeCount: constraints.volumeCount, label: 'extensions.continuity' });
  validateContinuityExtension(plan.continuity, { targetChapters, volumeCount: constraints.volumeCount, label: 'plan.continuity' });
  validateContinuityExtension(plan.extensions?.continuity, { targetChapters, volumeCount: constraints.volumeCount, label: 'plan.extensions.continuity' });
  return root;
}

export function longFormPlanPath(bookId, options = {}) {
  const booksDir = options.booksDir || PATHS.BOOKS_SUBDIR;
  return join(booksDir, assertBookId(bookId), 'long-form-plan.json');
}

export function writeLongFormPlan(bookId, plan, options = {}) {
  const safeBookId = assertBookId(bookId);
  const validated = validateLongFormPlan(plan, { bookId: safeBookId });
  const bookDir = join(options.booksDir || PATHS.BOOKS_SUBDIR, safeBookId);
  if (!existsSync(bookDir) || !statSync(bookDir).isDirectory()) {
    throw planError(`书籍目录不存在: ${bookDir}`, 404);
  }
  const file = longFormPlanPath(safeBookId, options);
  writePrivateFile(file, `${JSON.stringify(validated, null, 2)}\n`);
  return validated;
}

/**
 * Keep continuity facts produced by embedded core while rebasing its default
 * budget onto the authoritative constraints submitted by Publisher.
 */
export function preserveLongFormSeed(requestedPlan, seededPlan) {
  const requested = structuredClone(validateLongFormPlan(requestedPlan, {
    bookId: requestedPlan?.bookId,
  }));
  const seeded = validateLongFormPlan(seededPlan, { bookId: requested.bookId });

  for (const key of ['continuity', 'extensions']) {
    if (own(seeded, key)) requested[key] = structuredClone(seeded[key]);
    if (own(seeded.plan, key)) requested.plan[key] = structuredClone(seeded.plan[key]);
  }
  return validateLongFormPlan(requested, { bookId: requested.bookId });
}

export function readLongFormPlan(bookId, options = {}) {
  const safeBookId = assertBookId(bookId);
  const file = longFormPlanPath(safeBookId, options);
  if (!existsSync(file)) return null;
  try {
    const parsed = JSON.parse(readFileSync(file, 'utf-8'));
    return validateLongFormPlan(parsed, { bookId: safeBookId });
  } catch (err) {
    throw planError(`长篇规划文件损坏: ${file}: ${err.message}`, 503, err);
  }
}

function readLegacyVolumeCount(bookDir) {
  const file = join(bookDir, 'story', 'outline', 'volume_map.md');
  if (!existsSync(file)) return 0;
  try {
    return countVolumesFromText(readFileSync(file, 'utf-8'));
  } catch {
    return 0;
  }
}

export function migrateLegacyLongFormPlan(bookId, options = {}) {
  const safeBookId = assertBookId(bookId);
  const bookDir = join(options.booksDir || PATHS.BOOKS_SUBDIR, safeBookId);
  const metadataFile = join(bookDir, 'book.json');
  if (!existsSync(bookDir) || !statSync(bookDir).isDirectory()) {
    throw planError(`书籍目录不存在: ${bookDir}`, 404);
  }
  let metadata = null;
  if (existsSync(metadataFile)) {
    try {
      metadata = JSON.parse(readFileSync(metadataFile, 'utf-8'));
    } catch (err) {
      throw planError(`书籍元数据损坏: ${metadataFile}: ${err.message}`, 503, err);
    }
  } else if (options.legacyBook && typeof options.legacyBook === 'object') {
    metadata = options.legacyBook;
  } else {
    throw planError(`书籍缺少 book.json，且 Publisher state 中没有可用于迁移的书籍元数据: ${metadataFile}`, 503);
  }

  const stateBook = options.legacyBook && typeof options.legacyBook === 'object' ? options.legacyBook : {};
  const stateChapters = Array.isArray(stateBook.chapters) ? stateBook.chapters : [];
  let diskChapters = [];
  const indexFile = join(bookDir, 'chapters', 'index.json');
  if (existsSync(indexFile)) {
    try {
      const parsed = JSON.parse(readFileSync(indexFile, 'utf-8'));
      if (Array.isArray(parsed)) diskChapters = parsed;
    } catch {
      // The strict chapter-index reader will report this separately. Migration
      // can still use Publisher state without replacing the damaged index.
    }
  }
  const maxWrittenChapter = [...stateChapters, ...diskChapters].reduce((max, chapter) => (
    Number.isSafeInteger(chapter?.number) ? Math.max(max, chapter.number) : max
  ), 0);
  const rawTargetChapterWords = Number(firstDefined(
    metadata.chapterWordCount,
    metadata.chapterWords,
    metadata.inkos?.chapterWordCount,
    stateBook.inkos?.chapterWordCount,
    DEFAULT_TARGET_CHAPTER_WORDS,
  ));
  const targetChapterWords = Math.min(
    MAX_TARGET_CHAPTER_WORDS,
    Math.max(MIN_TARGET_CHAPTER_WORDS, Math.round(rawTargetChapterWords || DEFAULT_TARGET_CHAPTER_WORDS)),
  );
  const configuredTargetChapters = Number(firstDefined(
    metadata.targetChapters,
    metadata.inkos?.targetChapters,
    stateBook.inkos?.targetChapters,
    DEFAULT_TARGET_CHAPTERS,
  ));
  const targetChapters = Math.max(
    maxWrittenChapter,
    Number.isSafeInteger(configuredTargetChapters) && configuredTargetChapters > 0
      ? configuredTargetChapters
      : DEFAULT_TARGET_CHAPTERS,
  );
  const detectedVolumes = firstDefined(
    metadata.volumeCount,
    Array.isArray(metadata.volumes) && metadata.volumes.length > 0 ? metadata.volumes.length : undefined,
    readLegacyVolumeCount(bookDir) || undefined,
    stateChapters.reduce((max, chapter) => Number.isSafeInteger(chapter?.volume) ? Math.max(max, chapter.volume) : max, 0) || undefined,
    1,
  );
  const legacySpecialConstraints = firstDefined(
    metadata.specialConstraints,
    metadata.creation?.payload?.longFormConstraints?.specialConstraints,
    metadata.creation?.payload?.specialConstraints,
    typeof metadata.creation?.payload?.constraints === 'string' ? metadata.creation.payload.constraints : undefined,
    [],
  );
  let constraints;
  try {
    constraints = normalizeLongFormConstraints({
      targetTotalWords: Number(targetChapters) * Number(targetChapterWords),
      targetChapterWords,
      volumeCount: Math.min(100, Number(detectedVolumes), Number(targetChapters)),
      specialConstraints: legacySpecialConstraints,
    });
  } catch (err) {
    throw planError(`旧书长篇规划迁移失败: ${err.message}`, 503, err);
  }
  try {
    const plan = buildLongFormPlan(safeBookId, constraints, {
      source: 'migrated',
      createdAt: metadata.createdAt || options.now || new Date(),
      now: options.now || new Date(),
    });
    return writeLongFormPlan(safeBookId, plan, options);
  } catch (err) {
    throw planError(`旧书长篇规划迁移失败: ${err.message}`, 503, err);
  }
}

export function loadOrMigrateLongFormPlan(bookId, options = {}) {
  return readLongFormPlan(bookId, options) || migrateLegacyLongFormPlan(bookId, options);
}

function restoreFile(file, existed, content) {
  if (existed) writePrivateFile(file, content);
  else if (existsSync(file)) unlinkSync(file);
}

export function commitLongFormPlanUpdate(bookId, plan, state, options = {}) {
  const safeBookId = assertBookId(bookId);
  const validated = validateLongFormPlan(plan, { bookId: safeBookId });
  if (!state?.books?.[safeBookId]) throw planError('同步长篇规划时 Publisher state 中找不到书籍', 404);
  if (typeof options.saveState !== 'function') throw planError('同步长篇规划时缺少 state 保存函数', 500);

  const booksDir = options.booksDir || PATHS.BOOKS_SUBDIR;
  const metadataFile = join(booksDir, safeBookId, 'book.json');
  const planFile = longFormPlanPath(safeBookId, { booksDir });
  const metadataExisted = existsSync(metadataFile);
  const planExisted = existsSync(planFile);
  const oldMetadataRaw = metadataExisted ? readFileSync(metadataFile, 'utf-8') : '';
  const oldPlanRaw = planExisted ? readFileSync(planFile, 'utf-8') : '';
  const oldState = structuredClone(state);
  let metadata = {};
  if (metadataExisted) {
    try {
      metadata = JSON.parse(oldMetadataRaw);
    } catch (err) {
      throw planError(`书籍元数据损坏: ${metadataFile}: ${err.message}`, 503, err);
    }
  }

  const nextState = structuredClone(state);
  const nextBook = nextState.books[safeBookId];
  const updatedAt = validated.updatedAt;
  nextBook.inkos = {
    ...(nextBook.inkos || {}),
    bookId: safeBookId,
    targetChapters: validated.plan.targetChapters,
    chapterWordCount: validated.constraints.targetChapterWords,
  };
  nextBook.updatedAt = updatedAt;
  const nextMetadata = {
    id: metadata.id || safeBookId,
    title: metadata.title || nextBook.title || safeBookId,
    ...metadata,
    targetChapters: validated.plan.targetChapters,
    chapterWordCount: validated.constraints.targetChapterWords,
    updatedAt,
  };

  try {
    writePrivateFile(metadataFile, `${JSON.stringify(nextMetadata, null, 2)}\n`);
    writeLongFormPlan(safeBookId, validated, { booksDir });
    options.saveState(nextState);
    return { state: nextState, metadata: nextMetadata, plan: validated };
  } catch (err) {
    const rollbackErrors = [];
    try { restoreFile(planFile, planExisted, oldPlanRaw); } catch (rollbackErr) { rollbackErrors.push(rollbackErr.message); }
    try { restoreFile(metadataFile, metadataExisted, oldMetadataRaw); } catch (rollbackErr) { rollbackErrors.push(rollbackErr.message); }
    try { options.saveState(oldState); } catch (rollbackErr) { rollbackErrors.push(rollbackErr.message); }
    const suffix = rollbackErrors.length > 0 ? `；回滚异常：${rollbackErrors.join('；')}` : '；已回滚全部元数据';
    throw planError(`长篇规划同步失败：${err.message}${suffix}`, 500, err);
  }
}

export function updateLongFormPlan(current, patch = {}, options = {}) {
  const validated = validateLongFormPlan(current, { bookId: current?.bookId });
  if (!patch || typeof patch !== 'object' || Array.isArray(patch)) throw planError('PATCH body 必须是对象');
  if (own(patch, 'constraints')
    && (!patch.constraints || typeof patch.constraints !== 'object' || Array.isArray(patch.constraints))) {
    throw planError('constraints 必须是对象');
  }
  const source = own(patch, 'constraints') ? patch.constraints : patch;
  const providedKeys = CONSTRAINT_KEYS.filter(key => own(source, key));
  let continuityPatch = null;
  let continuityKeys = [];
  let policyKeys = [];
  if (own(patch, 'continuity')) {
    continuityPatch = assertObject(patch.continuity, 'continuity');
    const unknownKeys = Object.keys(continuityPatch)
      .filter(key => !CONTINUITY_ARRAY_KEYS.includes(key) && key !== 'policy');
    if (unknownKeys.length > 0) throw planError(`continuity 包含未知字段: ${unknownKeys.join(', ')}`);
    continuityKeys = CONTINUITY_ARRAY_KEYS.filter(key => own(continuityPatch, key));
    if (own(continuityPatch, 'policy')) {
      const policy = assertObject(continuityPatch.policy, 'continuity.policy');
      const unknownPolicyKeys = Object.keys(policy).filter(key => !CONTINUITY_POLICY_KEYS.includes(key));
      if (unknownPolicyKeys.length > 0) {
        throw planError(`continuity.policy 包含未知字段: ${unknownPolicyKeys.join(', ')}`);
      }
      policyKeys = CONTINUITY_POLICY_KEYS.filter(key => own(policy, key));
    }
  }
  if (providedKeys.length === 0 && continuityKeys.length === 0 && policyKeys.length === 0) {
    throw planError('PATCH 至少需要一个 constraints 或 continuity 字段');
  }
  const merged = { ...validated.constraints };
  for (const key of providedKeys) merged[key] = source[key];
  const constraints = normalizeLongFormConstraints(merged);
  if (validated.constraints.specialConstraints.length > 0 && constraints.specialConstraints.length === 0) {
    throw planError('已有特殊约束不能清空');
  }
  const next = buildLongFormPlan(validated.bookId, constraints, {
    revision: validated.revision + 1,
    source: 'updated',
    createdAt: validated.createdAt,
    now: options.now || new Date(),
  });
  // Arrays are independently replaceable while policy is a shallow patch.
  // Budget-only edits preserve the exact legacy representation, including a
  // missing or partial continuity extension.
  if (!continuityPatch) {
    next.continuity = own(validated, 'continuity')
      ? structuredClone(validated.continuity)
      : defaultContinuity('migrated');
  } else {
    const currentContinuity = validated.continuity
      && typeof validated.continuity === 'object'
      && !Array.isArray(validated.continuity)
      ? structuredClone(validated.continuity)
      : defaultContinuity('migrated');
    next.continuity = currentContinuity;
    for (const key of continuityKeys) next.continuity[key] = structuredClone(continuityPatch[key]);
    if (policyKeys.length > 0) {
      next.continuity.policy = {
        ...(currentContinuity.policy || {}),
      };
      for (const key of policyKeys) next.continuity.policy[key] = continuityPatch.policy[key];
    }
  }
  if (own(validated, 'extensions')) next.extensions = structuredClone(validated.extensions);
  return validateLongFormPlan(next, { bookId: validated.bookId });
}

export function renderLongFormChapterContext(plan, chapterNumber, options = {}) {
  const validated = validateLongFormPlan(plan, { bookId: plan?.bookId });
  const number = requireInteger(chapterNumber, '章节号', { min: 1, max: validated.plan.targetChapters });
  const chapter = validated.plan.chapters[number - 1];
  const volume = validated.plan.volumes[chapter.volumeNumber - 1];
  const special = validated.constraints.specialConstraints;
  const targetWords = options.targetWords === undefined
    ? chapter.targetWords
    : requireInteger(options.targetWords, '本章动态目标字数', { min: chapter.minWords, max: chapter.maxWords });
  const minWords = options.minWords === undefined
    ? chapter.minWords
    : requireInteger(options.minWords, '本章动态最小字数', { min: chapter.minWords, max: chapter.maxWords });
  const maxWords = options.maxWords === undefined
    ? chapter.maxWords
    : requireInteger(options.maxWords, '本章动态最大字数', { min: chapter.minWords, max: chapter.maxWords });
  if (minWords > maxWords || targetWords < minWords || targetWords > maxWords) {
    throw planError(`本章动态预算无效：目标 ${targetWords} 不在 ${minWords}-${maxWords} 范围内`);
  }
  return [
    '【结构化长篇预算（权威约束）】',
    `全书目标：${validated.constraints.targetTotalWords} 字，共 ${validated.plan.targetChapters} 章、${validated.constraints.volumeCount} 卷。`,
    `当前章节：第 ${number} 章，归属第 ${volume.number} 卷（第 ${volume.startChapter}-${volume.endChapter} 章）。`,
    `本章目标：${targetWords} 字；当前可行范围：${minWords}-${maxWords} 字（全局容差 ±${validated.constraints.chapterWordTolerance}%）。`,
    minWords !== chapter.minWords || maxWords !== chapter.maxWords
      ? `为保证本卷剩余 ${volume.chapterCount - (number - volume.startChapter)} 章仍能完成精确预算，本章范围已动态收紧。`
      : '',
    targetWords !== chapter.targetWords ? `原始逐章预算为 ${chapter.targetWords} 字；已按本卷实际累计字数动态校正。` : '',
    `本卷目标：${volume.targetWords} 字，共 ${volume.chapterCount} 章。`,
    special.length > 0 ? `特别约束：\n${special.map((item, index) => `${index + 1}. ${item}`).join('\n')}` : '',
    '本预算不可由临时写作指导覆盖；正文应在允许字数范围内完成当前章节目标。',
  ].filter(Boolean).join('\n');
}

// Keep creation briefs readable even when the authoritative plan contains
// thousands of chapter records. The complete array remains in JSON on disk.
export function summarizeChapterBudgets(plan) {
  const validated = validateLongFormPlan(plan, { bookId: plan?.bookId });
  const summaries = [];
  let run = null;
  for (const chapter of validated.plan.chapters) {
    const key = `${chapter.volumeNumber}:${chapter.targetWords}:${chapter.minWords}:${chapter.maxWords}`;
    if (!run || run.key !== key) {
      if (run) summaries.push(run);
      run = { key, volumeNumber: chapter.volumeNumber, start: chapter.number, end: chapter.number, targetWords: chapter.targetWords, minWords: chapter.minWords, maxWords: chapter.maxWords };
    } else {
      run.end = chapter.number;
    }
  }
  if (run) summaries.push(run);
  return summaries.map(item => {
    const range = item.start === item.end ? `第${item.start}章` : `第${item.start}-${item.end}章`;
    return `- ${range}：第${item.volumeNumber}卷，目标${item.targetWords}字，允许${item.minWords}-${item.maxWords}字`;
  });
}

export function assertLongFormHistoryPreserved(current, next, writtenChapters = []) {
  const previous = validateLongFormPlan(current, { bookId: current?.bookId });
  const candidate = validateLongFormPlan(next, { bookId: previous.bookId });
  const records = Array.from(new Map((writtenChapters || [])
    .filter(record => Number.isSafeInteger(record?.number) && record.number > 0)
    .map(record => [record.number, record])).values())
    .sort((left, right) => left.number - right.number);
  if (records.length === 0) return candidate;

  const maxWrittenChapter = records.at(-1).number;
  const writtenNumbers = new Set(records.map(record => record.number));
  for (let number = 1; number <= maxWrittenChapter; number += 1) {
    if (!writtenNumbers.has(number)) throw planError(`已写章节记录不连续：缺少第 ${number} 章`);
  }
  assertContinuityHistoryPreserved(previous.continuity, candidate.continuity, maxWrittenChapter);
  if (candidate.plan.targetChapters < maxWrittenChapter) {
    throw planError(`目标章数不能小于已写到的第 ${maxWrittenChapter} 章`);
  }
  const actualWrittenWords = records.reduce((sum, record) => {
    const words = Number(record.wordCount);
    return sum + (Number.isSafeInteger(words) && words > 0 ? words : 0);
  }, 0);
  if (candidate.constraints.targetTotalWords < actualWrittenWords) {
    throw planError(`目标总字数不能小于已写正文 ${actualWrittenWords} 字`);
  }

  for (const record of records) {
    const oldChapter = previous.plan.chapters[record.number - 1];
    const newChapter = candidate.plan.chapters[record.number - 1];
    if (!oldChapter || !newChapter) {
      throw planError(`第 ${record.number} 章超出原规划或新规划范围`);
    }
    if (record.wordCount < newChapter.minWords || record.wordCount > newChapter.maxWords) {
      throw planError(`第 ${record.number} 章实际字数 ${record.wordCount} 不在新规划 ${newChapter.minWords}-${newChapter.maxWords} 范围内`);
    }
    const oldVolume = previous.plan.volumes[oldChapter.volumeNumber - 1];
    const newVolume = candidate.plan.volumes[newChapter.volumeNumber - 1];
    if (oldChapter.volumeNumber !== newChapter.volumeNumber
      || oldVolume.startChapter !== newVolume.startChapter
      || oldVolume.endChapter !== newVolume.endChapter) {
      throw planError(`第 ${record.number} 章已经写出，所属分卷及卷边界不能变化`);
    }
  }

  const remainingTotalWords = candidate.constraints.targetTotalWords - actualWrittenWords;
  let remainingChapterCount = candidate.plan.targetChapters - records.length;
  if (remainingChapterCount < 0) remainingChapterCount = 0;
  const globalMinPossible = remainingChapterCount * candidate.plan.chapterWordRange.min;
  const globalMaxPossible = remainingChapterCount * candidate.plan.chapterWordRange.max;
  if (remainingTotalWords < globalMinPossible || remainingTotalWords > globalMaxPossible) {
    throw planError('全书剩余字数无法由剩余章节在新规划范围内完成');
  }
  for (const volume of candidate.plan.volumes) {
    const volumeRecords = records.filter(record => record.number >= volume.startChapter && record.number <= volume.endChapter);
    const volumeActualWords = volumeRecords.reduce((sum, record) => sum + Number(record.wordCount || 0), 0);
    const volumeRemainingCount = volume.chapterCount - volumeRecords.length;
    const volumeRemainingWords = volume.targetWords - volumeActualWords;
    const volumeMinPossible = volumeRemainingCount * candidate.plan.chapterWordRange.min;
    const volumeMaxPossible = volumeRemainingCount * candidate.plan.chapterWordRange.max;
    if (volumeRemainingCount === 0) {
      if (volumeRemainingWords !== 0) throw planError(`第 ${volume.number} 卷已写完但实际字数与新规划不一致`);
    } else if (volumeRemainingWords < volumeMinPossible || volumeRemainingWords > volumeMaxPossible) {
      throw planError(`第 ${volume.number} 卷剩余字数无法由剩余章节在新规划范围内完成`);
    }
  }
  return candidate;
}

function continuityItems(continuity, key) {
  return Array.isArray(continuity?.[key]) ? continuity[key] : [];
}

function itemsById(continuity, key, idKey) {
  return new Map(continuityItems(continuity, key).map(item => [item[idKey], item]));
}

function sameStringSet(left, right) {
  const leftValues = Array.isArray(left) ? [...left].sort() : [];
  const rightValues = Array.isArray(right) ? [...right].sort() : [];
  return leftValues.length === rightValues.length
    && leftValues.every((value, index) => value === rightValues[index]);
}

function sameImmutableCanon(left, right) {
  return Boolean(right)
    && left.statement === right.statement
    && (left.category || 'other') === (right.category || 'other')
    && left.value === right.value
    && sameStringSet(left.aliases, right.aliases);
}

function sameWorldRule(left, right) {
  return Boolean(right)
    && left.statement === right.statement
    && (left.immutable !== false) === (right.immutable !== false);
}

function sameTimelineMilestone(left, right) {
  return Boolean(right)
    && left.order === right.order
    && left.label === right.label
    && left.earliestChapter === right.earliestChapter
    && left.latestChapter === right.latestChapter
    && (left.immutable !== false) === (right.immutable !== false);
}

function sameKnowledgeBoundary(left, right) {
  return Boolean(right)
    && left.statement === right.statement
    && left.availableFromChapter === right.availableFromChapter
    && left.revealByChapter === right.revealByChapter
    && sameStringSet(left.allowedKnowers, right.allowedKnowers)
    && sameStringSet(left.forbiddenKnowers, right.forbiddenKnowers)
    && sameStringSet(left.markers, right.markers);
}

function sameHookPlan(left, right) {
  return Boolean(right)
    && left.description === right.description
    && left.openFromChapter === right.openFromChapter
    && left.resolveByChapter === right.resolveByChapter
    && left.requiredVolumeNumber === right.requiredVolumeNumber;
}

function assertContinuityHistoryPreserved(previous, candidate, maxWrittenChapter) {
  const nextCanon = itemsById(candidate, 'immutableCanon', 'id');
  for (const item of continuityItems(previous, 'immutableCanon')) {
    if (!sameImmutableCanon(item, nextCanon.get(item.id))) {
      throw planError(`已有正文，immutable canon ${item.id} 不能删除或修改`);
    }
  }

  const nextRules = itemsById(candidate, 'worldRules', 'id');
  for (const rule of continuityItems(previous, 'worldRules')) {
    if (rule.immutable !== false && !sameWorldRule(rule, nextRules.get(rule.id))) {
      throw planError(`已有正文，不可变世界规则 ${rule.id} 不能删除或修改`);
    }
  }

  const nextEntities = itemsById(candidate, 'entities', 'id');
  for (const entity of continuityItems(previous, 'entities')) {
    const lockedAttributes = Array.isArray(entity.immutableAttributes) ? entity.immutableAttributes : [];
    const hasLocks = entity.immutableOwner === true
      || entity.immutableLocation === true
      || lockedAttributes.length > 0;
    if (!hasLocks) continue;
    const nextEntity = nextEntities.get(entity.id);
    if (!nextEntity || nextEntity.name !== entity.name || nextEntity.type !== entity.type) {
      throw planError(`已有正文，实体 ${entity.id} 的锁定身份不能删除或修改`);
    }
    if (entity.immutableOwner === true
      && (nextEntity.immutableOwner !== true || nextEntity.owner !== entity.owner)) {
      throw planError(`已有正文，实体 ${entity.id} 的锁定归属不能修改`);
    }
    if (entity.immutableLocation === true
      && (nextEntity.immutableLocation !== true || nextEntity.location !== entity.location)) {
      throw planError(`已有正文，实体 ${entity.id} 的锁定位置不能修改`);
    }
    const nextLockedAttributes = Array.isArray(nextEntity.immutableAttributes)
      ? nextEntity.immutableAttributes
      : [];
    for (const attribute of lockedAttributes) {
      if (!nextLockedAttributes.includes(attribute)
        || nextEntity.attributes?.[attribute] !== entity.attributes?.[attribute]) {
        throw planError(`已有正文，实体 ${entity.id} 的锁定属性 ${attribute} 不能修改`);
      }
    }
  }

  const nextTimeline = itemsById(candidate, 'timeline', 'id');
  for (const milestone of continuityItems(previous, 'timeline')) {
    if (milestone.earliestChapter <= maxWrittenChapter
      && !sameTimelineMilestone(milestone, nextTimeline.get(milestone.id))) {
      throw planError(`时间线 ${milestone.id} 已在正文中生效，不能删除或修改`);
    }
  }

  const nextKnowledge = itemsById(candidate, 'knowledgeBoundaries', 'factId');
  for (const boundary of continuityItems(previous, 'knowledgeBoundaries')) {
    if (boundary.availableFromChapter <= maxWrittenChapter
      && !sameKnowledgeBoundary(boundary, nextKnowledge.get(boundary.factId))) {
      throw planError(`知识边界 ${boundary.factId} 已在正文中生效，不能删除或修改`);
    }
  }

  const nextHooks = itemsById(candidate, 'hooks', 'hookId');
  for (const hook of continuityItems(previous, 'hooks')) {
    if (hook.openFromChapter <= maxWrittenChapter
      && !sameHookPlan(hook, nextHooks.get(hook.hookId))) {
      throw planError(`伏笔 ${hook.hookId} 已在正文中生效，不能删除或修改`);
    }
  }
}

export function resolveAdaptiveChapterBudget(plan, chapterNumber, writtenChapters = []) {
  const validated = validateLongFormPlan(plan, { bookId: plan?.bookId });
  const number = requireInteger(chapterNumber, '章节号', { min: 1, max: validated.plan.targetChapters });
  const chapter = validated.plan.chapters[number - 1];
  const volume = validated.plan.volumes[chapter.volumeNumber - 1];
  const actualByNumber = new Map((writtenChapters || [])
    .filter(record => Number.isSafeInteger(record?.number)
      && Number.isSafeInteger(Number(record?.wordCount))
      && record.trusted !== false)
    .map(record => [record.number, Number(record.wordCount)]));
  for (let current = 1; current < number; current += 1) {
    const record = (writtenChapters || []).find(item => item?.number === current);
    if (!record || record.trusted === false || !Number.isSafeInteger(Number(record.wordCount))) {
      throw planError(`生成第 ${number} 章前缺少第 ${current} 章可信字数记录`, 409);
    }
  }
  let actualWrittenWords = 0;
  for (let current = volume.startChapter; current < number; current += 1) {
    actualWrittenWords += Math.max(0, actualByNumber.get(current) || 0);
  }
  const remainingChapters = volume.endChapter - number + 1;
  const remainingWords = volume.targetWords - actualWrittenWords;
  const minPossibleWords = remainingChapters * chapter.minWords;
  const maxPossibleWords = remainingChapters * chapter.maxWords;
  if (remainingWords < minPossibleWords || remainingWords > maxPossibleWords) {
    throw planError(
      `第 ${volume.number} 卷剩余预算 ${remainingWords} 字不能由 ${remainingChapters} 章在 ${chapter.minWords}-${chapter.maxWords} 字范围内完成`,
      409,
    );
  }
  // A chapter may be inside the global tolerance and still consume so much of
  // the remaining volume budget that the final chapters become impossible.
  // Narrow this chapter's gate to the interval that leaves every later chapter
  // feasible, preserving the exact volume total instead of freezing mid-volume.
  const futureChapters = remainingChapters - 1;
  const feasibleMinWords = Math.max(
    chapter.minWords,
    remainingWords - futureChapters * chapter.maxWords,
  );
  const feasibleMaxWords = Math.min(
    chapter.maxWords,
    remainingWords - futureChapters * chapter.minWords,
  );
  if (feasibleMinWords > feasibleMaxWords) {
    throw planError(
      `第 ${volume.number} 卷当前章节没有可行字数区间：${feasibleMinWords}-${feasibleMaxWords}`,
      409,
    );
  }
  const averageTarget = Math.ceil(remainingWords / remainingChapters);
  const targetWords = Math.min(feasibleMaxWords, Math.max(feasibleMinWords, averageTarget));
  return {
    targetWords,
    plannedTargetWords: chapter.targetWords,
    minWords: feasibleMinWords,
    maxWords: feasibleMaxWords,
    globalMinWords: chapter.minWords,
    globalMaxWords: chapter.maxWords,
    volumeNumber: volume.number,
    volumeTargetWords: volume.targetWords,
    actualWrittenWords,
    remainingWords,
    remainingChapters,
  };
}
function validateContinuityExtension(value, { targetChapters, volumeCount, label = 'continuity' } = {}) {
  if (value === undefined || value === null) return;
  const extension = assertObject(value, label);
  if (own(extension, 'immutableCanon')) {
    const items = continuityArray(extension.immutableCanon, label + '.immutableCanon', 5_000);
    uniqueContinuityIds(items, 'id', label + '.immutableCanon');
    for (const item of items) {
      continuityString(item?.id, label + '.immutableCanon.id', 160);
      continuityString(item?.statement, label + '.immutableCanon.statement');
      if (item.value !== undefined) continuityString(item.value, label + '.immutableCanon.value', 1_000, false);
      if (item.aliases !== undefined) {
        const aliases = continuityArray(item.aliases, label + '.immutableCanon.aliases', 32);
        aliases.forEach((alias) => continuityString(alias, label + '.immutableCanon.alias', 160));
      }
    }
  }
  if (own(extension, 'worldRules')) {
    const items = continuityArray(extension.worldRules, label + '.worldRules', 5_000);
    uniqueContinuityIds(items, 'id', label + '.worldRules');
    for (const item of items) {
      continuityString(item?.id, label + '.worldRules.id', 160);
      continuityString(item?.statement, label + '.worldRules.statement');
      if (item.immutable !== undefined && typeof item.immutable !== 'boolean') throw planError(label + '.worldRules.immutable必须是布尔值');
    }
  }
  if (own(extension, 'entities')) {
    const items = continuityArray(extension.entities, label + '.entities', 10_000);
    uniqueContinuityIds(items, 'id', label + '.entities');
    const types = new Set(['character', 'object', 'location', 'faction', 'concept']);
    for (const item of items) {
      continuityString(item?.id, label + '.entities.id', 160);
      continuityString(item?.name, label + '.entities.name', 500);
      if (!types.has(item?.type)) throw planError(label + '.entities.type无效');
      if (item.owner !== undefined) continuityString(item.owner, label + '.entities.owner', 500, false);
      if (item.location !== undefined) continuityString(item.location, label + '.entities.location', 500, false);
      if (item.attributes !== undefined) {
        const attributes = assertObject(item.attributes, label + '.entities.attributes');
        for (const [key, value] of Object.entries(attributes)) {
          continuityString(key, label + '.entities.attributes键', 160);
          continuityString(value, label + '.entities.attributes.' + key, 1_000, false);
        }
      }
      if (item.immutableOwner !== undefined && typeof item.immutableOwner !== 'boolean') throw planError(label + '.entities.immutableOwner必须是布尔值');
      if (item.immutableLocation !== undefined && typeof item.immutableLocation !== 'boolean') throw planError(label + '.entities.immutableLocation必须是布尔值');
      if (item.immutableAttributes !== undefined) {
        const attributes = continuityArray(item.immutableAttributes, label + '.entities.immutableAttributes', 64);
        attributes.forEach((attribute) => continuityString(attribute, label + '.entities.immutableAttribute', 160));
      }
    }
  }
  if (own(extension, 'knowledgeBoundaries')) {
    const items = continuityArray(extension.knowledgeBoundaries, label + '.knowledgeBoundaries', 10_000);
    uniqueContinuityIds(items, 'factId', label + '.knowledgeBoundaries');
    for (const item of items) {
      continuityString(item?.factId, label + '.knowledgeBoundaries.factId', 160);
      continuityString(item?.statement, label + '.knowledgeBoundaries.statement');
      const available = requireInteger(item?.availableFromChapter, label + '.knowledgeBoundaries.availableFromChapter', { min: 1, max: targetChapters || MAX_PLANNED_CHAPTERS });
      if (item.revealByChapter !== undefined) {
        const reveal = requireInteger(item.revealByChapter, label + '.knowledgeBoundaries.revealByChapter', { min: 1, max: targetChapters || MAX_PLANNED_CHAPTERS });
        if (reveal < available) throw planError(label + '.knowledgeBoundaries.revealByChapter不能早于availableFromChapter');
      }
      for (const key of ['allowedKnowers', 'forbiddenKnowers', 'markers']) {
        if (item[key] === undefined) continue;
        const values = continuityArray(item[key], label + '.knowledgeBoundaries.' + key, key === 'markers' ? 32 : 128);
        values.forEach((entry) => continuityString(entry, label + '.knowledgeBoundaries.' + key, 160));
      }
      const allowed = new Set((item.allowedKnowers || []).map(entry => String(entry).trim()));
      const overlap = (item.forbiddenKnowers || [])
        .map(entry => String(entry).trim())
        .find(entry => allowed.has(entry));
      if (overlap) {
        throw planError(label + `.knowledgeBoundaries中 ${overlap} 不能同时出现在允许与禁止知情列表`);
      }
    }
  }
  if (own(extension, 'timeline')) {
    const items = continuityArray(extension.timeline, label + '.timeline', 10_000);
    uniqueContinuityIds(items, 'id', label + '.timeline');
    const orders = new Set();
    for (const item of items) {
      continuityString(item?.id, label + '.timeline.id', 160);
      continuityString(item?.label, label + '.timeline.label');
      const order = requireInteger(item?.order, label + '.timeline.order', { min: 0 });
      if (orders.has(order)) throw planError(label + '.timeline存在重复 order: ' + order);
      orders.add(order);
      const earliest = requireInteger(item?.earliestChapter, label + '.timeline.earliestChapter', { min: 1, max: targetChapters || MAX_PLANNED_CHAPTERS });
      const latest = requireInteger(item?.latestChapter, label + '.timeline.latestChapter', { min: 1, max: targetChapters || MAX_PLANNED_CHAPTERS });
      if (earliest > latest) throw planError(label + '.timeline章节窗口无效');
      if (item.immutable !== undefined && typeof item.immutable !== 'boolean') throw planError(label + '.timeline.immutable必须是布尔值');
    }
  }
  if (own(extension, 'hooks')) {
    const items = continuityArray(extension.hooks, label + '.hooks', 10_000);
    uniqueContinuityIds(items, 'hookId', label + '.hooks');
    for (const item of items) {
      continuityString(item?.hookId, label + '.hooks.hookId', 160);
      continuityString(item?.description, label + '.hooks.description');
      const open = requireInteger(item?.openFromChapter, label + '.hooks.openFromChapter', { min: 1, max: targetChapters || MAX_PLANNED_CHAPTERS });
      if (item.resolveByChapter !== undefined) {
        const resolve = requireInteger(item.resolveByChapter, label + '.hooks.resolveByChapter', { min: 1, max: targetChapters || MAX_PLANNED_CHAPTERS });
        if (resolve < open) throw planError(label + '.hooks.resolveByChapter不能早于openFromChapter');
      }
      if (item.requiredVolumeNumber !== undefined) requireInteger(item.requiredVolumeNumber, label + '.hooks.requiredVolumeNumber', { min: 1, max: volumeCount || MAX_VOLUME_COUNT });
    }
  }
  if (own(extension, 'policy')) {
    const policy = assertObject(extension.policy, label + '.policy');
    for (const key of ['requireContinuousVolumes', 'allowUnplannedEntities', 'requireConsistencyDelta', 'checkpointAtVolumeEnd']) {
      if (policy[key] !== undefined && typeof policy[key] !== 'boolean') throw planError(label + '.policy.' + key + '必须是布尔值');
    }
  }
}
