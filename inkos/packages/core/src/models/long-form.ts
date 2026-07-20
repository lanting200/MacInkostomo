import { z } from "zod";

const IdentifierSchema = z.string().trim().min(1).max(160);
const DetailTextSchema = z.string().trim().min(1).max(2_000);

/** The JSON contract written by chapter-publisher/lib/long-form-plan.js. */
export const LongFormConstraintsSchema = z.object({
  targetTotalWords: z.number().int().min(1_000).max(3_000_000),
  volumeCount: z.number().int().min(1).max(100),
  targetChapterWords: z.number().int().min(500).max(20_000),
  // Publisher stores this as an integer percentage, not a ratio.
  chapterWordTolerance: z.number().int().min(0).max(50),
  specialConstraints: z.array(z.string().trim().min(1).max(2_000)).max(100),
}).superRefine((value, ctx) => {
  const totalChars = value.specialConstraints.reduce((sum, item) => sum + item.length, 0);
  if (totalChars > 20_000) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["specialConstraints"], message: "specialConstraints exceeds 20000 characters" });
  }
});
export type LongFormConstraints = z.infer<typeof LongFormConstraintsSchema>;

export const LongFormChapterBudgetSchema = z.object({
  number: z.number().int().min(1),
  volumeNumber: z.number().int().min(1),
  targetWords: z.number().int().min(1),
  minWords: z.number().int().min(1),
  maxWords: z.number().int().min(1),
});
export type LongFormChapterBudget = z.infer<typeof LongFormChapterBudgetSchema>;

export const LongFormVolumeBudgetSchema = z.object({
  number: z.number().int().min(1),
  startChapter: z.number().int().min(1),
  endChapter: z.number().int().min(1),
  chapterCount: z.number().int().min(1),
  targetWords: z.number().int().min(1),
  title: z.string().trim().min(1).max(500).optional(),
});
export type LongFormVolumeBudget = z.infer<typeof LongFormVolumeBudgetSchema>;

export const LongFormPlanBodySchema = z.object({
  targetChapters: z.number().int().min(1).max(10_000),
  chapterWordRange: z.object({
    min: z.number().int().min(1),
    max: z.number().int().min(1),
  }),
  volumes: z.array(LongFormVolumeBudgetSchema).min(1).max(10_000),
  chapters: z.array(LongFormChapterBudgetSchema).min(1).max(10_000),
}).passthrough();
export type LongFormPlanBody = z.infer<typeof LongFormPlanBodySchema>;

export const LongFormPlanSchema = z.object({
  version: z.literal(1),
  revision: z.number().int().min(1),
  bookId: IdentifierSchema,
  constraints: LongFormConstraintsSchema,
  plan: LongFormPlanBodySchema,
  source: z.enum(["created", "migrated", "updated"]),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
  // Publisher currently does not emit these fields. Passthrough keeps a
  // future continuity extension readable without weakening the budget checks.
  continuity: z.unknown().optional(),
  extensions: z.unknown().optional(),
}).passthrough().superRefine((value, ctx) => {
  const { constraints, plan } = value;
  const expectedChapters = Math.round(constraints.targetTotalWords / constraints.targetChapterWords);
  if (plan.targetChapters !== expectedChapters) {
    addIssue(ctx, ["plan", "targetChapters"], "targetChapters does not match the total/chapter budget");
  }
  if (constraints.volumeCount !== plan.volumes.length) {
    addIssue(ctx, ["plan", "volumes"], "volume count does not match constraints.volumeCount");
  }
  const expectedMin = Math.max(1, Math.round(
    constraints.targetChapterWords * (1 - constraints.chapterWordTolerance / 100),
  ));
  const expectedMax = Math.round(
    constraints.targetChapterWords * (1 + constraints.chapterWordTolerance / 100),
  );
  if (plan.chapterWordRange.min !== expectedMin || plan.chapterWordRange.max !== expectedMax) {
    addIssue(ctx, ["plan", "chapterWordRange"], "chapterWordRange does not match constraints");
  }
  if (plan.chapters.length !== plan.targetChapters) {
    addIssue(ctx, ["plan", "chapters"], "chapter budget length does not match targetChapters");
  }
  const seenChapters = new Set<number>();
  let chapterWordSum = 0;
  for (const chapter of plan.chapters) {
    if (seenChapters.has(chapter.number)) addIssue(ctx, ["plan", "chapters"], `duplicate chapter ${chapter.number}`);
    seenChapters.add(chapter.number);
    if (chapter.number !== seenChapters.size) {
      addIssue(ctx, ["plan", "chapters"], "chapter budgets must be contiguous from 1");
    }
    if (chapter.minWords !== expectedMin || chapter.maxWords !== expectedMax) {
      addIssue(ctx, ["plan", "chapters"], `chapter ${chapter.number} range does not match constraints`);
    }
    if (chapter.targetWords < chapter.minWords || chapter.targetWords > chapter.maxWords) {
      addIssue(ctx, ["plan", "chapters"], `chapter ${chapter.number} target is outside its range`);
    }
    if (chapter.volumeNumber < 1 || chapter.volumeNumber > plan.volumes.length) {
      addIssue(ctx, ["plan", "chapters"], `chapter ${chapter.number} has an invalid volume`);
    }
    chapterWordSum += chapter.targetWords;
  }
  if (chapterWordSum !== constraints.targetTotalWords) {
    addIssue(ctx, ["plan", "chapters"], "chapter budgets do not sum to targetTotalWords");
  }

  let nextStart = 1;
  let volumeWordSum = 0;
  for (const volume of plan.volumes) {
    if (volume.number !== plan.volumes.indexOf(volume) + 1) {
      addIssue(ctx, ["plan", "volumes"], "volume numbers must be contiguous from 1");
    }
    if (volume.startChapter !== nextStart || volume.endChapter < volume.startChapter) {
      addIssue(ctx, ["plan", "volumes"], `volume ${volume.number} boundaries are not contiguous`);
    }
    const expectedCount = volume.endChapter - volume.startChapter + 1;
    if (volume.chapterCount !== expectedCount) {
      addIssue(ctx, ["plan", "volumes"], `volume ${volume.number} chapterCount is inconsistent`);
    }
    const chapterSlice = plan.chapters.slice(volume.startChapter - 1, volume.endChapter);
    if (chapterSlice.length !== expectedCount || chapterSlice.some((chapter) => chapter.volumeNumber !== volume.number)) {
      addIssue(ctx, ["plan", "volumes"], `volume ${volume.number} does not match chapter ownership`);
    }
    const expectedWords = chapterSlice.reduce((sum, chapter) => sum + chapter.targetWords, 0);
    if (volume.targetWords !== expectedWords) {
      addIssue(ctx, ["plan", "volumes"], `volume ${volume.number} targetWords is inconsistent`);
    }
    volumeWordSum += volume.targetWords;
    nextStart = volume.endChapter + 1;
  }
  if (nextStart !== plan.targetChapters + 1) addIssue(ctx, ["plan", "volumes"], "volumes do not cover all chapters");
  if (volumeWordSum !== constraints.targetTotalWords) addIssue(ctx, ["plan", "volumes"], "volumes do not sum to targetTotalWords");
});
export type PublisherLongFormPlan = z.infer<typeof LongFormPlanSchema>;

export const LongFormPlanPolicySchema = z.object({
  requireContinuousVolumes: z.boolean().default(true),
  allowUnplannedEntities: z.boolean().default(true),
  requireConsistencyDelta: z.boolean().default(false),
  checkpointAtVolumeEnd: z.boolean().default(true),
});
export type LongFormPlanPolicy = z.infer<typeof LongFormPlanPolicySchema>;

export const LongFormImmutableCanonSchema = z.object({
  id: IdentifierSchema,
  category: z.enum(["character", "world", "timeline", "entity", "object", "knowledge", "other"]).default("other"),
  statement: DetailTextSchema,
  value: z.string().max(1_000).optional(),
  aliases: z.array(z.string().trim().min(1).max(160)).max(32).default([]),
});
export type LongFormImmutableCanon = z.infer<typeof LongFormImmutableCanonSchema>;

export const LongFormWorldRuleSchema = z.object({
  id: IdentifierSchema,
  statement: DetailTextSchema,
  immutable: z.boolean().default(true),
});
export type LongFormWorldRule = z.infer<typeof LongFormWorldRuleSchema>;

export const LongFormEntitySchema = z.object({
  id: IdentifierSchema,
  name: z.string().trim().min(1).max(500),
  type: z.enum(["character", "object", "location", "faction", "concept"]),
  owner: z.string().max(500).optional(),
  location: z.string().max(500).optional(),
  attributes: z.record(z.string().max(1_000)).default({}),
  immutableOwner: z.boolean().default(false),
  immutableLocation: z.boolean().default(false),
  immutableAttributes: z.array(z.string().trim().min(1).max(160)).max(64).default([]),
});
export type LongFormEntity = z.infer<typeof LongFormEntitySchema>;

export const LongFormKnowledgeBoundarySchema = z.object({
  factId: IdentifierSchema,
  statement: DetailTextSchema,
  allowedKnowers: z.array(IdentifierSchema).max(128).default([]),
  forbiddenKnowers: z.array(IdentifierSchema).max(128).default([]),
  availableFromChapter: z.number().int().min(1).default(1),
  revealByChapter: z.number().int().min(1).optional(),
  markers: z.array(z.string().trim().min(1).max(160)).max(32).default([]),
});
export type LongFormKnowledgeBoundary = z.infer<typeof LongFormKnowledgeBoundarySchema>;

export const LongFormTimelineMilestoneSchema = z.object({
  id: IdentifierSchema,
  order: z.number().int().min(0),
  label: DetailTextSchema,
  earliestChapter: z.number().int().min(1),
  latestChapter: z.number().int().min(1),
  immutable: z.boolean().default(true),
});
export type LongFormTimelineMilestone = z.infer<typeof LongFormTimelineMilestoneSchema>;

export const LongFormHookPlanSchema = z.object({
  hookId: IdentifierSchema,
  description: DetailTextSchema,
  openFromChapter: z.number().int().min(1),
  resolveByChapter: z.number().int().min(1).optional(),
  requiredVolumeNumber: z.number().int().min(1).optional(),
});
export type LongFormHookPlan = z.infer<typeof LongFormHookPlanSchema>;

export const LongFormContinuityExtensionSchema = z.object({
  immutableCanon: z.array(LongFormImmutableCanonSchema).max(5_000).default([]),
  worldRules: z.array(LongFormWorldRuleSchema).max(5_000).default([]),
  entities: z.array(LongFormEntitySchema).max(10_000).default([]),
  knowledgeBoundaries: z.array(LongFormKnowledgeBoundarySchema).max(10_000).default([]),
  timeline: z.array(LongFormTimelineMilestoneSchema).max(10_000).default([]),
  hooks: z.array(LongFormHookPlanSchema).max(10_000).default([]),
  policy: LongFormPlanPolicySchema.default({
    requireContinuousVolumes: true,
    allowUnplannedEntities: true,
    requireConsistencyDelta: false,
    checkpointAtVolumeEnd: true,
  }),
}).default({
  immutableCanon: [],
  worldRules: [],
  entities: [],
  knowledgeBoundaries: [],
  timeline: [],
  hooks: [],
  policy: {
    requireContinuousVolumes: true,
    allowUnplannedEntities: true,
    requireConsistencyDelta: false,
    checkpointAtVolumeEnd: true,
  },
});
export type LongFormContinuityExtension = z.infer<typeof LongFormContinuityExtensionSchema>;

/** Internal normalized representation used by context assembly and validators. */
export const NormalizedLongFormPlanSchema = z.object({
  version: z.literal(1),
  revision: z.number().int().min(1),
  bookId: IdentifierSchema,
  source: z.enum(["created", "migrated", "updated"]),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
  targetChapters: z.number().int().min(1),
  targetWords: z.number().int().min(1),
  chapterWordTarget: z.number().int().min(1),
  chapterWordTolerancePercent: z.number().int().min(0).max(50),
  chapterWordRange: z.object({ min: z.number().int().min(1), max: z.number().int().min(1) }),
  specialConstraints: z.array(z.string()).max(256),
  volumes: z.array(LongFormVolumeBudgetSchema),
  chapters: z.array(LongFormChapterBudgetSchema),
  immutableCanon: z.array(LongFormImmutableCanonSchema),
  worldRules: z.array(LongFormWorldRuleSchema),
  entities: z.array(LongFormEntitySchema),
  knowledgeBoundaries: z.array(LongFormKnowledgeBoundarySchema),
  timeline: z.array(LongFormTimelineMilestoneSchema),
  hooks: z.array(LongFormHookPlanSchema),
  policy: LongFormPlanPolicySchema,
});
export type NormalizedLongFormPlan = z.infer<typeof NormalizedLongFormPlanSchema>;

export const LongFormTimelineEventSchema = z.object({
  eventId: IdentifierSchema,
  status: z.enum(["occurred", "advanced", "referenced"]),
  detail: z.string().max(2_000).default(""),
});
export type LongFormTimelineEvent = z.infer<typeof LongFormTimelineEventSchema>;

export const LongFormEntityOpSchema = z.object({
  entityId: IdentifierSchema,
  owner: z.string().max(500).optional(),
  location: z.string().max(500).optional(),
  attributes: z.record(z.string().max(1_000)).default({}),
  changeReason: z.string().max(2_000).optional(),
});
export type LongFormEntityOp = z.infer<typeof LongFormEntityOpSchema>;

export const LongFormKnowledgeClaimSchema = z.object({
  characterId: IdentifierSchema,
  factId: IdentifierSchema,
  action: z.enum(["knows", "learns", "reveals", "guesses"]),
  source: z.string().max(2_000).optional(),
});
export type LongFormKnowledgeClaim = z.infer<typeof LongFormKnowledgeClaimSchema>;

export const LongFormWorldRuleAssertionSchema = z.object({
  ruleId: IdentifierSchema,
  status: z.enum(["honored", "changed", "violated"]),
  detail: z.string().max(2_000).default(""),
  changeReason: z.string().max(2_000).optional(),
});
export type LongFormWorldRuleAssertion = z.infer<typeof LongFormWorldRuleAssertionSchema>;

export const LongFormSettingDeltaSchema = z.object({
  canonId: IdentifierSchema.optional(),
  path: IdentifierSchema,
  previousValue: z.string().max(2_000).optional(),
  nextValue: z.string().max(2_000),
  introduced: z.boolean().default(false),
  reason: z.string().max(2_000).optional(),
});
export type LongFormSettingDelta = z.infer<typeof LongFormSettingDeltaSchema>;

export const LongFormConsistencyDeltaSchema = z.object({
  timelineEvents: z.array(LongFormTimelineEventSchema).max(256).default([]),
  entityOps: z.array(LongFormEntityOpSchema).max(512).default([]),
  knowledgeClaims: z.array(LongFormKnowledgeClaimSchema).max(512).default([]),
  worldRuleAssertions: z.array(LongFormWorldRuleAssertionSchema).max(256).default([]),
  settingDeltas: z.array(LongFormSettingDeltaSchema).max(512).default([]),
});
export type LongFormConsistencyDelta = z.infer<typeof LongFormConsistencyDeltaSchema>;

export const LongFormContinuityStateSchema = z.object({
  schemaVersion: z.literal(1).default(1),
  planFingerprint: z.string().min(1),
  firstObservedChapter: z.number().int().min(0),
  lastAppliedChapter: z.number().int().min(0),
  lastAppliedWordCount: z.number().int().min(0).default(0),
  lastAppliedVolumeNumber: z.number().int().min(0).optional(),
  totalWordCount: z.number().int().min(0),
  volumeWordCounts: z.record(z.number().int().min(0)).default({}),
  timelineEvents: z.record(z.object({
    chapter: z.number().int().min(1),
    status: z.enum(["occurred", "advanced", "referenced"]),
    detail: z.string().max(2_000).default(""),
  })).default({}),
  entityStates: z.record(z.object({
    owner: z.string().max(500).optional(),
    location: z.string().max(500).optional(),
    attributes: z.record(z.string().max(1_000)).default({}),
    lastChangedChapter: z.number().int().min(0),
  })).default({}),
  knowledge: z.record(z.array(IdentifierSchema).max(10_000)).default({}),
  settingValues: z.record(z.string().max(2_000)).default({}),
  hookStates: z.record(z.object({
    status: z.string().max(160),
    lastAdvancedChapter: z.number().int().min(0),
  })).default({}),
});
export type LongFormContinuityState = z.infer<typeof LongFormContinuityStateSchema>;

export const CanonCheckpointSchema = z.object({
  schemaVersion: z.literal(1),
  planFingerprint: z.string().min(1),
  volume: z.object({
    number: z.number().int().min(1),
    startChapter: z.number().int().min(1),
    endChapter: z.number().int().min(1),
    actualWords: z.number().int().min(0),
    targetWords: z.number().int().min(0),
  }),
  completedAtChapter: z.number().int().min(1),
  generatedAt: z.string().datetime(),
  immutableCanon: z.array(z.object({ id: IdentifierSchema, statement: DetailTextSchema })).max(128),
  activeFacts: z.array(z.object({
    subject: z.string().max(500),
    predicate: z.string().max(500),
    object: z.string().max(2_000),
    sourceChapter: z.number().int().min(0),
  })).max(128),
  openHooks: z.array(z.object({
    hookId: IdentifierSchema,
    status: z.string().max(160),
    lastAdvancedChapter: z.number().int().min(0),
    expectedPayoff: z.string().max(2_000),
  })).max(128),
  entities: z.array(z.object({
    entityId: IdentifierSchema,
    owner: z.string().max(500).optional(),
    location: z.string().max(500).optional(),
    attributes: z.record(z.string().max(1_000)),
  })).max(128),
  knowledge: z.record(z.array(IdentifierSchema).max(10_000)),
  completedTimelineEventIds: z.array(IdentifierSchema).max(10_000),
  nextVolumeNumber: z.number().int().min(1).optional(),
});
export type CanonCheckpoint = z.infer<typeof CanonCheckpointSchema>;

function addIssue(ctx: z.RefinementCtx, path: Array<string | number>, message: string): void {
  ctx.addIssue({ code: z.ZodIssueCode.custom, path, message });
}
