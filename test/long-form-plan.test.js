import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { chapterLength } from '../lib/status.js';
import { normalizeCreateBookPayload } from '../lib/book-create-assistant.js';
import {
  buildLongFormPlan,
  assertLongFormHistoryPreserved,
  commitLongFormPlanUpdate,
  countVolumesFromText,
  loadOrMigrateLongFormPlan,
  normalizeLongFormConstraints,
  preserveLongFormSeed,
  readLongFormPlan,
  renderLongFormChapterContext,
  resolveAdaptiveChapterBudget,
  summarizeChapterBudgets,
  updateLongFormPlan,
  validateLongFormPlan,
  writeLongFormPlan,
} from '../lib/long-form-plan.js';

const NOW = '2026-01-01T00:00:00.000Z';

function withTempBooks(fn) {
  const root = mkdtempSync(join(tmpdir(), 'chapter-publisher-plan-'));
  const booksDir = join(root, 'books');
  mkdirSync(booksDir, { recursive: true });
  try {
    return fn({ root, booksDir });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

test('normalizes legacy aliases and Chinese volume headings', () => {
  const constraints = normalizeLongFormConstraints({
    totalWords: '1.2万字',
    chapterWords: 1000,
    volumePlan: '第一卷（第1-6章）\n第二卷（第7-12章）',
    constraints: '保持第一人称',
  });
  assert.deepEqual(constraints, {
    targetTotalWords: 12000,
    volumeCount: 2,
    targetChapterWords: 1000,
    chapterWordTolerance: 15,
    specialConstraints: ['保持第一人称'],
  });
  assert.equal(countVolumesFromText('第一卷\n第二卷\n第二卷回顾'), 2);
  assert.deepEqual(
    normalizeLongFormConstraints({
      targetTotalWords: 5000,
      targetChapterWords: 500,
      volumeCount: 2,
      constraints: '保持第一人称；不得改名\n保持第一人称',
    }).specialConstraints,
    ['保持第一人称', '不得改名'],
  );
  assert.deepEqual(
    normalizeLongFormConstraints({
      targetTotalWords: 5000,
      targetChapterWords: 500,
      volumeCount: 1,
      constraints: ['保持第一人称', '不得改名'],
    }).specialConstraints,
    ['保持第一人称', '不得改名'],
  );
  assert.throws(
    () => normalizeLongFormConstraints({}, {}, { requireSpecialConstraints: true }),
    /特殊约束/,
  );
});

test('normalizes assistant output into the canonical creation fields', () => {
  const payload = normalizeCreateBookPayload({
    totalWords: '400万字',
    chapterWords: 3000,
    targetChapters: 2000,
    volumePlan: '第一卷\n第二卷',
    constraints: '',
  }, '写一部长篇小说');
  assert.equal(payload.targetTotalWords, 3_000_000);
  assert.equal(payload.targetChapterWords, 3000);
  assert.equal(payload.targetChapters, 1000);
  assert.equal(payload.volumeCount, 2);
  assert.equal(payload.chapterWordTolerance, 15);
  assert.ok(payload.specialConstraints.length > 0);
});

test('builds exact chapter and volume budgets with quotient/remainder distribution', () => {
  const plan = buildLongFormPlan('fixture', {
    targetTotalWords: 5003,
    targetChapterWords: 500,
    chapterWordTolerance: 1,
    volumeCount: 3,
  }, { now: NOW });

  assert.equal(plan.plan.targetChapters, 10);
  assert.deepEqual(plan.plan.chapters.slice(0, 4).map(chapter => chapter.targetWords), [501, 501, 501, 500]);
  assert.deepEqual(plan.plan.volumes.map(volume => [volume.startChapter, volume.endChapter, volume.targetWords]), [
    [1, 4, 2003],
    [5, 7, 1500],
    [8, 10, 1500],
  ]);
  assert.equal(plan.plan.chapters.reduce((sum, chapter) => sum + chapter.targetWords, 0), 5003);
  assert.equal(plan.plan.chapterWordRange.min, 495);
  assert.equal(plan.plan.chapterWordRange.max, 505);
  assert.deepEqual(plan.continuity.policy, {
    requireContinuousVolumes: true,
    allowUnplannedEntities: true,
    requireConsistencyDelta: true,
    checkpointAtVolumeEnd: true,
  });
  assert.doesNotThrow(() => validateLongFormPlan(plan));
});

test('rebases a CLI-created continuity seed onto Publisher constraints', () => {
  const seeded = buildLongFormPlan('fixture', {
    targetTotalWords: 10_000,
    targetChapterWords: 1_000,
    chapterWordTolerance: 15,
    volumeCount: 1,
    specialConstraints: ['default'],
  }, { now: NOW });
  seeded.continuity.entities.push({
    id: 'foundation-character-1',
    name: '林月',
    type: 'character',
    attributes: {},
    immutableOwner: false,
    immutableLocation: false,
    immutableAttributes: [],
  });
  const requested = buildLongFormPlan('fixture', {
    targetTotalWords: 12_000,
    targetChapterWords: 1_000,
    chapterWordTolerance: 10,
    volumeCount: 3,
    specialConstraints: ['保持第一人称'],
  }, { now: NOW });

  const rebased = preserveLongFormSeed(requested, seeded);
  assert.equal(rebased.constraints.targetTotalWords, 12_000);
  assert.equal(rebased.constraints.volumeCount, 3);
  assert.equal(rebased.constraints.chapterWordTolerance, 10);
  assert.deepEqual(rebased.constraints.specialConstraints, ['保持第一人称']);
  assert.deepEqual(rebased.continuity.entities, seeded.continuity.entities);
});

test('rejects exact budgets outside the configured percentage tolerance', () => {
  assert.throws(
    () => buildLongFormPlan('fixture', {
      targetTotalWords: 5001,
      targetChapterWords: 500,
      chapterWordTolerance: 0,
      volumeCount: 1,
    }, { now: NOW }),
    /不相容|超出/,
  );
});

test('persists and lazily migrates a legacy InkOS book atomically', () => {
  withTempBooks(({ booksDir }) => {
    const bookDir = join(booksDir, 'legacy');
    mkdirSync(join(bookDir, 'story', 'outline'), { recursive: true });
    writeFileSync(join(bookDir, 'book.json'), JSON.stringify({
      id: 'legacy',
      title: 'Legacy',
      targetChapters: 10,
      chapterWordCount: 500,
      createdAt: NOW,
    }));
    writeFileSync(join(bookDir, 'story', 'outline', 'volume_map.md'), '第一卷（第1-4章）\n第二卷（第5-10章）');

    const plan = loadOrMigrateLongFormPlan('legacy', { booksDir, now: NOW });
    assert.equal(plan.source, 'migrated');
    assert.equal(plan.continuity.policy.requireConsistencyDelta, false);
    assert.equal(plan.constraints.volumeCount, 2);
    assert.equal(plan.plan.targetChapters, 10);
    assert.equal(statSync(join(bookDir, 'long-form-plan.json')).mode & 0o777, 0o600);
    assert.deepEqual(readLongFormPlan('legacy', { booksDir }), plan);

    const updated = updateLongFormPlan(plan, { constraints: { targetTotalWords: 5100 } }, { now: NOW });
    writeLongFormPlan('legacy', updated, { booksDir });
    assert.equal(readLongFormPlan('legacy', { booksDir }).revision, 2);
  });
});

test('migrates a state-only legacy book when book.json is absent', () => {
  withTempBooks(({ booksDir }) => {
    const bookDir = join(booksDir, 'state-only');
    mkdirSync(join(bookDir, 'chapters'), { recursive: true });
    const plan = loadOrMigrateLongFormPlan('state-only', {
      booksDir,
      now: NOW,
      legacyBook: {
        title: 'State Only',
        inkos: { targetChapters: 4, chapterWordCount: 500 },
        chapters: [{ number: 1, volume: 1, wordCount: 500 }],
      },
    });
    assert.equal(plan.source, 'migrated');
    assert.equal(plan.plan.targetChapters, 4);
    assert.equal(plan.constraints.targetChapterWords, 500);
  });
});

test('detects a corrupted persisted plan without replacing it', () => {
  withTempBooks(({ booksDir }) => {
    const bookDir = join(booksDir, 'broken');
    mkdirSync(bookDir, { recursive: true });
    const file = join(bookDir, 'long-form-plan.json');
    writeFileSync(file, '{broken');
    assert.throws(() => readLongFormPlan('broken', { booksDir }), err => err.statusCode === 503);
    assert.equal(readFileSync(file, 'utf8'), '{broken');
  });
});

test('renders authoritative context for the exact next chapter', () => {
  const plan = buildLongFormPlan('fixture', {
    targetTotalWords: 5000,
    targetChapterWords: 500,
    chapterWordTolerance: 15,
    volumeCount: 2,
    specialConstraints: ['不得改变主角姓名'],
  }, { now: NOW });
  const context = renderLongFormChapterContext(plan, 1);
  assert.match(context, /第 1 章/);
  assert.match(context, /目标：500 字/);
  assert.match(context, /容差 ±15%/);
  assert.match(context, /不得改变主角姓名/);
});

test('keeps a 6000-chapter creation summary compact', () => {
  const plan = buildLongFormPlan('stress', {
    targetTotalWords: 3_000_000,
    targetChapterWords: 500,
    chapterWordTolerance: 15,
    volumeCount: 100,
  }, { now: NOW });
  assert.equal(plan.plan.chapters.length, 6000);
  const summary = summarizeChapterBudgets(plan).join('\n');
  assert.ok(summary.length < 20_000);
  assert.equal(summary.split('\n').length, 100);
});

test('protects written chapter volume boundaries and actual word totals', () => {
  const current = buildLongFormPlan('fixture', {
    targetTotalWords: 5000,
    targetChapterWords: 500,
    chapterWordTolerance: 15,
    volumeCount: 2,
    specialConstraints: ['保持时间线'],
  }, { now: NOW });
  const shifted = updateLongFormPlan(current, { constraints: { targetTotalWords: 5500 } }, { now: NOW });
  assert.throws(
    () => assertLongFormHistoryPreserved(current, shifted, [{ number: 1, wordCount: 500 }]),
    /卷边界不能变化/,
  );
  const sameBoundaries = updateLongFormPlan(current, { constraints: { targetTotalWords: 5100 } }, { now: NOW });
  assert.doesNotThrow(() => assertLongFormHistoryPreserved(current, sameBoundaries, [{ number: 1, wordCount: 500 }]));
  assert.throws(
    () => assertLongFormHistoryPreserved(current, sameBoundaries, [{ number: 1, wordCount: 6000 }]),
    /不能小于已写正文/,
  );
  assert.throws(
    () => assertLongFormHistoryPreserved(current, sameBoundaries, [{ number: 1, wordCount: 700 }]),
    /不在新规划/,
  );
});

test('adapts the next target to remaining volume words and rejects impossible drift', () => {
  const plan = buildLongFormPlan('fixture', {
    targetTotalWords: 5000,
    targetChapterWords: 500,
    chapterWordTolerance: 15,
    volumeCount: 2,
  }, { now: NOW });
  const adaptive = resolveAdaptiveChapterBudget(plan, 2, [{ number: 1, wordCount: 600 }]);
  assert.equal(adaptive.targetWords, 475);
  assert.equal(adaptive.remainingWords, 1900);
  assert.throws(
    () => resolveAdaptiveChapterBudget(plan, 2, [{ number: 1, wordCount: 1000 }]),
    err => err.statusCode === 409,
  );
  assert.throws(
    () => resolveAdaptiveChapterBudget(plan, 3, [{ number: 2, wordCount: 500 }]),
    /缺少第 1 章可信字数记录/,
  );
});

test('narrows each chapter gate so an exact volume total remains feasible', () => {
  const plan = buildLongFormPlan('fixture', {
    targetTotalWords: 1500,
    targetChapterWords: 500,
    chapterWordTolerance: 50,
    volumeCount: 1,
  }, { now: NOW });

  const first = resolveAdaptiveChapterBudget(plan, 1, []);
  assert.deepEqual(
    { minWords: first.minWords, maxWords: first.maxWords, targetWords: first.targetWords },
    { minWords: 250, maxWords: 750, targetWords: 500 },
  );

  const second = resolveAdaptiveChapterBudget(plan, 2, [{ number: 1, wordCount: 750 }]);
  assert.deepEqual(
    { minWords: second.minWords, maxWords: second.maxWords, targetWords: second.targetWords },
    { minWords: 250, maxWords: 500, targetWords: 375 },
  );
  assert.match(renderLongFormChapterContext(plan, 2, second), /当前可行范围：250-500/);
  assert.match(renderLongFormChapterContext(plan, 2, second), /动态收紧/);
  assert.equal(750 > second.maxWords, true, '第 2 章 750 字必须被动态门禁拦截');

  const third = resolveAdaptiveChapterBudget(plan, 3, [
    { number: 1, wordCount: 750 },
    { number: 2, wordCount: second.maxWords },
  ]);
  assert.deepEqual(
    { minWords: third.minWords, maxWords: third.maxWords, targetWords: third.targetWords },
    { minWords: 250, maxWords: 250, targetWords: 250 },
  );
  assert.equal(750 + second.maxWords + third.targetWords, plan.constraints.targetTotalWords);
});

test('preserves continuity extensions across plan revisions', () => {
  const current = buildLongFormPlan('fixture', {
    targetTotalWords: 5000,
    targetChapterWords: 500,
    chapterWordTolerance: 15,
    volumeCount: 2,
    specialConstraints: ['保持时间线'],
  }, { now: NOW });
  current.continuity = { immutableCanon: [{ id: 'hero-name', statement: 'Name stays fixed' }] };
  current.extensions = { continuity: { policy: { checkpointAtVolumeEnd: true } } };
  const updated = updateLongFormPlan(current, { constraints: { targetTotalWords: 5100 } }, { now: NOW });
  assert.deepEqual(updated.continuity, current.continuity);
  assert.deepEqual(updated.extensions, current.extensions);
});

test('patches continuity arrays and policy independently without requiring a budget edit', () => {
  const current = buildLongFormPlan('fixture', {
    targetTotalWords: 5000,
    targetChapterWords: 500,
    chapterWordTolerance: 15,
    volumeCount: 2,
    specialConstraints: ['保持时间线'],
  }, { now: NOW });
  current.continuity.worldRules = [{ id: 'magic-cost', statement: '施法必有代价', immutable: true }];
  current.continuity.entities = [{
    id: 'hero',
    name: '主角',
    type: 'character',
    attributes: { age: '20' },
    immutableAttributes: ['age'],
  }];

  const updated = updateLongFormPlan(current, {
    continuity: {
      immutableCanon: [{ id: 'hero-name', category: 'character', statement: '主角名为林川' }],
      policy: { allowUnplannedEntities: false },
    },
  }, { now: '2026-01-02T00:00:00.000Z' });

  assert.deepEqual(updated.constraints, current.constraints);
  assert.deepEqual(updated.continuity.immutableCanon, [
    { id: 'hero-name', category: 'character', statement: '主角名为林川' },
  ]);
  assert.deepEqual(updated.continuity.worldRules, current.continuity.worldRules);
  assert.deepEqual(updated.continuity.entities, current.continuity.entities);
  assert.equal(updated.continuity.policy.allowUnplannedEntities, false);
  assert.equal(updated.continuity.policy.requireConsistencyDelta, true);
  assert.equal(updated.revision, current.revision + 1);
  assert.equal(updated.source, 'updated');

  const policyOnly = updateLongFormPlan(updated, {
    continuity: { policy: { checkpointAtVolumeEnd: false } },
  }, { now: '2026-01-03T00:00:00.000Z' });
  assert.deepEqual(policyOnly.continuity.immutableCanon, updated.continuity.immutableCanon);
  assert.deepEqual(policyOnly.continuity.worldRules, updated.continuity.worldRules);
  assert.equal(policyOnly.continuity.policy.allowUnplannedEntities, false);
  assert.equal(policyOnly.continuity.policy.checkpointAtVolumeEnd, false);
});

test('rejects empty or unknown continuity patches', () => {
  const current = buildLongFormPlan('fixture', {
    targetTotalWords: 5000,
    targetChapterWords: 500,
    chapterWordTolerance: 15,
    volumeCount: 1,
  }, { now: NOW });
  assert.throws(() => updateLongFormPlan(current, { continuity: {} }), /至少需要/);
  assert.throws(
    () => updateLongFormPlan(current, { continuity: { unknownLedger: [] } }),
    /未知字段/,
  );
  assert.throws(
    () => updateLongFormPlan(current, { continuity: { policy: { unknownGate: true } } }),
    /未知字段/,
  );
});

test('protects continuity facts that already affect written chapters', () => {
  const current = buildLongFormPlan('fixture', {
    targetTotalWords: 5000,
    targetChapterWords: 500,
    chapterWordTolerance: 15,
    volumeCount: 1,
  }, { now: NOW });
  current.continuity = {
    ...current.continuity,
    immutableCanon: [{ id: 'hero-name', category: 'character', statement: '主角名为林川', aliases: ['林川'] }],
    worldRules: [
      { id: 'magic-cost', statement: '施法必有代价', immutable: true },
      { id: 'weather', statement: '开篇下雨', immutable: false },
    ],
    entities: [{
      id: 'sword',
      name: '青锋剑',
      type: 'object',
      owner: 'hero',
      location: 'inn',
      attributes: { material: '玄铁', condition: '完好' },
      immutableOwner: true,
      immutableLocation: true,
      immutableAttributes: ['material'],
    }],
    timeline: [
      { id: 'arrival', order: 1, label: '抵达城中', earliestChapter: 1, latestChapter: 3, immutable: true },
      { id: 'departure', order: 2, label: '离开城中', earliestChapter: 7, latestChapter: 8, immutable: true },
    ],
    knowledgeBoundaries: [
      { factId: 'identity', statement: '反派身份', availableFromChapter: 1, revealByChapter: 3 },
      { factId: 'treasure', statement: '宝藏位置', availableFromChapter: 7, revealByChapter: 8 },
    ],
    hooks: [
      { hookId: 'scar', description: '旧伤来历', openFromChapter: 1, resolveByChapter: 3 },
      { hookId: 'letter', description: '密信来源', openFromChapter: 7, resolveByChapter: 8 },
    ],
  };
  const written = [1, 2, 3].map(number => ({ number, wordCount: 500 }));
  const replacementCases = [
    ['immutableCanon', [], /immutable canon/],
    ['worldRules', current.continuity.worldRules.slice(1), /世界规则/],
    ['entities', [{ ...current.continuity.entities[0], owner: 'villain' }], /锁定归属/],
    ['entities', [{
      ...current.continuity.entities[0],
      attributes: { ...current.continuity.entities[0].attributes, material: '凡铁' },
    }], /锁定属性/],
    ['timeline', current.continuity.timeline.slice(1), /时间线/],
    ['knowledgeBoundaries', current.continuity.knowledgeBoundaries.slice(1), /知识边界/],
    ['hooks', current.continuity.hooks.slice(1), /伏笔/],
  ];
  for (const [key, value, expected] of replacementCases) {
    const next = updateLongFormPlan(current, { continuity: { [key]: value } }, { now: NOW });
    assert.throws(() => assertLongFormHistoryPreserved(current, next, written), expected);
  }

  const futureEdit = updateLongFormPlan(current, {
    continuity: {
      worldRules: [current.continuity.worldRules[0], { id: 'weather', statement: '开篇放晴', immutable: false }],
      timeline: [current.continuity.timeline[0], { ...current.continuity.timeline[1], label: '乘船离城' }],
      knowledgeBoundaries: [
        current.continuity.knowledgeBoundaries[0],
        { ...current.continuity.knowledgeBoundaries[1], statement: '宝藏的新位置' },
      ],
      hooks: [current.continuity.hooks[0], { ...current.continuity.hooks[1], description: '密信真正来源' }],
    },
  }, { now: NOW });
  assert.doesNotThrow(() => assertLongFormHistoryPreserved(current, futureEdit, written));
});

test('does not turn a pre-continuity plan strict during a budget-only edit', () => {
  const legacy = buildLongFormPlan('legacy-plan', {
    targetTotalWords: 5000,
    targetChapterWords: 500,
    chapterWordTolerance: 15,
    volumeCount: 1,
  }, { now: NOW });
  delete legacy.continuity;
  const updated = updateLongFormPlan(legacy, { constraints: { targetTotalWords: 5100 } }, { now: NOW });
  assert.equal(updated.continuity.policy.requireConsistencyDelta, false);
});

test('rejects malformed continuity extensions before InkOS consumes a plan', () => {
  const plan = buildLongFormPlan('continuity-validation', {
    targetTotalWords: 5000,
    targetChapterWords: 500,
    chapterWordTolerance: 15,
    volumeCount: 1,
  }, { now: NOW });
  assert.throws(() => validateLongFormPlan({
    ...plan,
    continuity: {
      ...plan.continuity,
      entities: [{ id: 'seal', name: 'Seal', type: 'invalid' }],
    },
  }), /entities.type/);
  assert.throws(() => validateLongFormPlan({
    ...plan,
    continuity: {
      ...plan.continuity,
      timeline: [
        { id: 'a', order: 1, label: 'A', earliestChapter: 1, latestChapter: 2 },
        { id: 'b', order: 1, label: 'B', earliestChapter: 2, latestChapter: 3 },
      ],
    },
  }), /重复 order/);
  assert.throws(() => validateLongFormPlan({
    ...plan,
    continuity: {
      ...plan.continuity,
      knowledgeBoundaries: [{
        factId: 'secret',
        statement: '密钥位置',
        allowedKnowers: ['hero'],
        forbiddenKnowers: ['hero'],
        availableFromChapter: 1,
      }],
    },
  }), /同时出现在允许与禁止/);
  assert.throws(() => validateLongFormPlan({
    ...plan,
    continuity: {
      ...plan.continuity,
      entities: [{
        id: 'seal',
        name: '官印',
        type: 'object',
        attributes: { material: 42 },
      }],
    },
  }), /attributes\.material必须是字符串/);
});

test('matches InkOS English word counting for fallback content metrics', () => {
  assert.equal(chapterLength('# Chapter 1\nHello, world! It\'s me.\n```json\nignored words\n```', 'en'), 4);
  assert.equal(chapterLength('# 第一章\n天地 玄黄', 'zh'), 4);
});

test('commits plan, book metadata, and Publisher state together and rolls back failures', () => {
  withTempBooks(({ booksDir }) => {
    const bookDir = join(booksDir, 'fixture');
    mkdirSync(bookDir, { recursive: true });
    const current = buildLongFormPlan('fixture', {
      targetTotalWords: 5000,
      targetChapterWords: 500,
      chapterWordTolerance: 15,
      volumeCount: 2,
      specialConstraints: ['保持时间线'],
    }, { now: NOW });
    writeLongFormPlan('fixture', current, { booksDir });
    writeFileSync(join(bookDir, 'book.json'), JSON.stringify({ id: 'fixture', title: 'Fixture', targetChapters: 10, chapterWordCount: 500 }));
    const state = { books: { fixture: { title: 'Fixture', chapters: [], inkos: { targetChapters: 10, chapterWordCount: 500 } } } };
    const next = updateLongFormPlan(current, { constraints: { targetTotalWords: 5100 } }, { now: '2026-01-02T00:00:00.000Z' });
    let savedState = null;
    commitLongFormPlanUpdate('fixture', next, state, { booksDir, saveState: value => { savedState = value; } });
    assert.equal(JSON.parse(readFileSync(join(bookDir, 'book.json'))).targetChapters, 10);
    assert.equal(readLongFormPlan('fixture', { booksDir }).revision, 2);
    assert.equal(savedState.books.fixture.inkos.chapterWordCount, 500);

    const beforeMetadata = readFileSync(join(bookDir, 'book.json'), 'utf8');
    const beforePlan = readFileSync(join(bookDir, 'long-form-plan.json'), 'utf8');
    const failed = updateLongFormPlan(next, { constraints: { targetTotalWords: 5200 } }, { now: '2026-01-03T00:00:00.000Z' });
    let calls = 0;
    assert.throws(() => commitLongFormPlanUpdate('fixture', failed, savedState, {
      booksDir,
      saveState: () => {
        calls += 1;
        if (calls === 1) throw new Error('injected state failure');
      },
    }), /已回滚全部元数据/);
    assert.equal(readFileSync(join(bookDir, 'book.json'), 'utf8'), beforeMetadata);
    assert.equal(readFileSync(join(bookDir, 'long-form-plan.json'), 'utf8'), beforePlan);
  });
});
