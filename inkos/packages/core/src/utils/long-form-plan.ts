import { createHash, randomUUID } from "node:crypto";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import type { LengthSpec } from "../models/length-governance.js";
import {
  CanonCheckpointSchema,
  LongFormConsistencyDeltaSchema,
  LongFormContinuityExtensionSchema,
  LongFormContinuityStateSchema,
  LongFormPlanSchema,
  NormalizedLongFormPlanSchema,
  type CanonCheckpoint,
  type LongFormConsistencyDelta,
  type LongFormContinuityExtension,
  type LongFormContinuityState,
  type LongFormChapterBudget,
  type LongFormVolumeBudget,
  type NormalizedLongFormPlan,
  type PublisherLongFormPlan,
} from "../models/long-form.js";
import type { RuntimeStateDelta } from "../models/runtime-state.js";
import type { RuntimeStateSnapshot } from "../state/state-reducer.js";
import { resolveLengthCountingMode, type LengthLanguage } from "./length-metrics.js";
import { parsePendingHooksMarkdown } from "./story-markdown.js";

export const LONG_FORM_PLAN_FILE = "long-form-plan.json";
export const LONG_FORM_STATE_FILE = "long_form_state.json";
export const DEFAULT_LONG_FORM_CONTEXT_MAX_CHARS = 12_000;

const LEGACY_PLAN_PATHS = [
  "long_form_plan.json",
  join("story", "long-form-plan.json"),
  join("story", "long_form_plan.json"),
] as const;

export interface LoadedLongFormPlan {
  readonly path: string;
  readonly publisher: PublisherLongFormPlan;
  readonly plan: NormalizedLongFormPlan;
  readonly fingerprint: string;
}

export interface LongFormValidationIssue {
  readonly severity: "critical" | "warning";
  readonly code: string;
  readonly message: string;
}

export interface LongFormValidationResult {
  readonly issues: ReadonlyArray<LongFormValidationIssue>;
  readonly nextState: LongFormContinuityState;
  readonly volume: LongFormVolumeBudget | null;
  readonly volumeEnded: boolean;
}

export interface LongFormContextHook {
  readonly hookId: string;
  readonly status: string;
  readonly lastAdvancedChapter: number;
  readonly expectedPayoff?: string;
}

export interface LongFormContextFact {
  readonly subject: string;
  readonly predicate: string;
  readonly object: string;
  readonly sourceChapter?: number;
}

export interface ChapterProgressRecord {
  readonly number: number;
  readonly wordCount: number;
}

function distributeInteger(total: number, count: number): number[] {
  const quotient = Math.floor(total / count);
  const remainder = total % count;
  return Array.from({ length: count }, (_, index) => quotient + (index < remainder ? 1 : 0));
}

export interface PublisherLongFormPlanOptions {
  readonly bookId: string;
  readonly targetTotalWords: number;
  readonly targetChapterWords: number;
  readonly volumeCount?: number;
  readonly chapterWordTolerance?: number;
  readonly specialConstraints?: ReadonlyArray<string>;
  readonly source?: "created" | "migrated" | "updated";
  readonly revision?: number;
  readonly createdAt?: string;
  readonly updatedAt?: string;
}

/**
 * Build the on-disk Publisher contract for callers that create books directly
 * through the embedded core (the Web Publisher may provide a richer plan).
 * Keeping this constructor in core prevents the CLI and the macOS app from
 * silently creating books outside long-form governance.
 */
export function createPublisherLongFormPlan(
  options: PublisherLongFormPlanOptions,
): PublisherLongFormPlan {
  const bookId = options.bookId.trim();
  const targetTotalWords = options.targetTotalWords;
  const targetChapterWords = options.targetChapterWords;
  const tolerance = options.chapterWordTolerance ?? 15;
  if (!bookId) throw new Error("Long-form plan bookId is required.");
  if (!Number.isInteger(targetTotalWords) || targetTotalWords < 1_000 || targetTotalWords > 3_000_000) {
    throw new Error("Long-form targetTotalWords must be an integer between 1000 and 3000000.");
  }
  if (!Number.isInteger(targetChapterWords) || targetChapterWords < 500 || targetChapterWords > 20_000) {
    throw new Error("Long-form targetChapterWords must be an integer between 500 and 20000.");
  }
  if (!Number.isInteger(tolerance) || tolerance < 0 || tolerance > 50) {
    throw new Error("Long-form chapterWordTolerance must be an integer between 0 and 50.");
  }
  const targetChapters = Math.round(targetTotalWords / targetChapterWords);
  if (targetChapters < 1 || targetChapters > 10_000) {
    throw new Error("Long-form target chapter count is outside 1-10000.");
  }
  const minWords = Math.max(1, Math.round(targetChapterWords * (1 - tolerance / 100)));
  const maxWords = Math.round(targetChapterWords * (1 + tolerance / 100));
  const chaptersPerVolume = Math.max(1, Math.ceil(targetChapters / Math.min(100, Math.max(1, options.volumeCount ?? 1))));
  const volumeCount = Math.min(
    100,
    targetChapters,
    Math.max(1, options.volumeCount ?? Math.ceil(targetChapters / chaptersPerVolume)),
  );
  const chapterTargets = distributeInteger(targetTotalWords, targetChapters);
  const volumeChapterCounts = distributeInteger(targetChapters, volumeCount);
  const chapters: LongFormChapterBudget[] = [];
  const volumes: LongFormVolumeBudget[] = [];
  let chapterNumber = 1;
  for (let volumeNumber = 1; volumeNumber <= volumeCount; volumeNumber += 1) {
    const chapterCount = volumeChapterCounts[volumeNumber - 1]!;
    const startChapter = chapterNumber;
    let targetWords = 0;
    for (let offset = 0; offset < chapterCount; offset += 1) {
      const words = chapterTargets[chapterNumber - 1]!;
      chapters.push({
        number: chapterNumber,
        volumeNumber,
        targetWords: words,
        minWords,
        maxWords,
      });
      targetWords += words;
      chapterNumber += 1;
    }
    volumes.push({
      number: volumeNumber,
      startChapter,
      endChapter: chapterNumber - 1,
      chapterCount,
      targetWords,
    });
  }
  const now = options.updatedAt ?? new Date().toISOString();
  const continuity = LongFormContinuityExtensionSchema.parse({
    policy: {
      requireContinuousVolumes: true,
      allowUnplannedEntities: true,
      requireConsistencyDelta: true,
      checkpointAtVolumeEnd: true,
    },
  });
  return LongFormPlanSchema.parse({
    version: 1,
    revision: options.revision ?? 1,
    bookId,
    constraints: {
      targetTotalWords,
      volumeCount,
      targetChapterWords,
      chapterWordTolerance: tolerance,
      specialConstraints: [...(options.specialConstraints ?? [
        "保持人物、世界规则、时间线与跨卷设定一致。",
      ])],
    },
    plan: {
      targetChapters,
      chapterWordRange: { min: minWords, max: maxWords },
      volumes,
      chapters,
    },
    source: options.source ?? "created",
    continuity,
    createdAt: options.createdAt ?? now,
    updatedAt: now,
  });
}

/** Foundation facts that can be promoted without another LLM call. */
export interface LongFormFoundationSeed {
  readonly roles?: ReadonlyArray<{ readonly name: string; readonly content?: string }>;
  readonly bookRules?: string;
  readonly pendingHooks?: string;
}

function nextNumberedSeedId(prefix: string, usedIds: Set<string>, startAt: number): string {
  let number = Math.max(1, startAt);
  while (usedIds.has(`${prefix}-${number}`)) number += 1;
  const id = `${prefix}-${number}`;
  usedIds.add(id);
  return id;
}

function uniqueTruncatedSeedId(raw: string, usedIds: Set<string>, maxLength = 160): string {
  const base = raw.trim().slice(0, maxLength);
  if (!usedIds.has(base)) {
    usedIds.add(base);
    return base;
  }
  let number = 2;
  while (true) {
    const suffix = `-${number}`;
    const candidate = `${base.slice(0, maxLength - suffix.length)}${suffix}`;
    if (!usedIds.has(candidate)) {
      usedIds.add(candidate);
      return candidate;
    }
    number += 1;
  }
}

/**
 * Promote explicit foundation artifacts into the structured continuity seed.
 * This is deliberately conservative: only named roles, Markdown rule bullets,
 * and already-tabulated hooks are copied. Prose is never guessed into canon.
 */
export function seedPublisherLongFormPlanFromFoundation(
  value: PublisherLongFormPlan,
  seed: LongFormFoundationSeed,
): PublisherLongFormPlan {
  const plan = LongFormPlanSchema.parse(value);
  const continuity = LongFormContinuityExtensionSchema.parse(plan.continuity ?? {});
  const entities = [...continuity.entities];
  const entityNames = new Set(entities.map((entity) => entity.name));
  const entityIds = new Set(entities.map((entity) => entity.id));
  for (const role of seed.roles ?? []) {
    const name = role.name.trim();
    if (!name || entityNames.has(name)) continue;
    const stateMatch = role.content?.match(/##\s*(?:Current_State|当前现状)[^\n]*\n([\s\S]*?)(?=\n##|$)/i);
    const initialState = stateMatch?.[1]?.replace(/\s+/g, " ").trim().slice(0, 1_000);
    entities.push({
      id: nextNumberedSeedId("foundation-character", entityIds, entities.length + 1),
      name,
      type: "character",
      attributes: initialState ? { initialState } : {},
      immutableOwner: false,
      immutableLocation: false,
      immutableAttributes: [],
    });
    entityNames.add(name);
  }

  const worldRules = [...continuity.worldRules];
  const ruleStatements = new Set(worldRules.map((rule) => rule.statement));
  const ruleIds = new Set(worldRules.map((rule) => rule.id));
  for (const line of String(seed.bookRules ?? "").split(/\r?\n/)) {
    const match = line.trim().match(/^[-*]\s+(.+)$/);
    const statement = match?.[1]?.trim();
    if (!statement || statement.includes("<") || ruleStatements.has(statement)) continue;
    worldRules.push({
      id: nextNumberedSeedId("foundation-rule", ruleIds, worldRules.length + 1),
      statement: statement.slice(0, 2_000),
      immutable: true,
    });
    ruleStatements.add(statement);
  }

  const hooks = [...continuity.hooks];
  const hookIds = new Set(hooks.map((hook) => hook.hookId));
  const sourceHookIds = new Set<string>();
  for (const hook of parsePendingHooksMarkdown(String(seed.pendingHooks ?? ""))) {
    const sourceHookId = hook.hookId.trim();
    if (!sourceHookId || sourceHookIds.has(sourceHookId)) continue;
    sourceHookIds.add(sourceHookId);
    if (sourceHookId.length <= 160 && hookIds.has(sourceHookId)) continue;
    const description = (hook.expectedPayoff || hook.notes || hook.type || hook.hookId).trim();
    if (!description) continue;
    hooks.push({
      hookId: uniqueTruncatedSeedId(sourceHookId, hookIds),
      description: description.slice(0, 2_000),
      openFromChapter: Math.max(1, hook.startChapter || 1),
      requiredVolumeNumber: undefined,
    });
  }

  return LongFormPlanSchema.parse({
    ...plan,
    continuity: {
      ...continuity,
      entities,
      worldRules,
      hooks,
    },
  });
}

export function adaptPublisherLongFormPlan(value: unknown): NormalizedLongFormPlan {
  const publisher = LongFormPlanSchema.parse(value);
  const continuity = extractContinuityExtension(publisher);
  validateContinuityExtension(continuity, publisher.plan.targetChapters, publisher.plan.volumes.length);

  return NormalizedLongFormPlanSchema.parse({
    version: publisher.version,
    revision: publisher.revision,
    bookId: publisher.bookId,
    source: publisher.source,
    createdAt: publisher.createdAt,
    updatedAt: publisher.updatedAt,
    targetChapters: publisher.plan.targetChapters,
    targetWords: publisher.constraints.targetTotalWords,
    chapterWordTarget: publisher.constraints.targetChapterWords,
    chapterWordTolerancePercent: publisher.constraints.chapterWordTolerance,
    chapterWordRange: publisher.plan.chapterWordRange,
    specialConstraints: publisher.constraints.specialConstraints,
    volumes: publisher.plan.volumes,
    chapters: publisher.plan.chapters,
    ...continuity,
  });
}

export async function loadLongFormPlan(bookDir: string): Promise<LoadedLongFormPlan | null> {
  const candidates = [LONG_FORM_PLAN_FILE, ...LEGACY_PLAN_PATHS];
  for (const relativePath of candidates) {
    const path = join(bookDir, relativePath);
    let raw: string;
    try {
      raw = await readFile(path, "utf-8");
    } catch (error) {
      if (isMissingFileError(error)) continue;
      throw new Error(`Failed to read long-form plan at ${path}: ${String(error)}`);
    }

    try {
      const publisher = LongFormPlanSchema.parse(JSON.parse(raw));
      const plan = adaptPublisherLongFormPlan(publisher);
      return {
        path,
        publisher,
        plan,
        fingerprint: fingerprintLongFormPlan(plan),
      };
    } catch (error) {
      throw new Error(`Invalid long-form plan at ${path}: ${formatValidationError(error)}`);
    }
  }
  return null;
}

export function fingerprintLongFormPlan(plan: NormalizedLongFormPlan): string {
  const stable = {
    version: plan.version,
    revision: plan.revision,
    bookId: plan.bookId,
    targetChapters: plan.targetChapters,
    targetWords: plan.targetWords,
    chapterWordTarget: plan.chapterWordTarget,
    chapterWordTolerancePercent: plan.chapterWordTolerancePercent,
    chapterWordRange: plan.chapterWordRange,
    specialConstraints: plan.specialConstraints,
    volumes: plan.volumes,
    chapters: plan.chapters,
    immutableCanon: plan.immutableCanon,
    worldRules: plan.worldRules,
    entities: plan.entities,
    knowledgeBoundaries: plan.knowledgeBoundaries,
    timeline: plan.timeline,
    hooks: plan.hooks,
    policy: plan.policy,
  };
  return createHash("sha256").update(JSON.stringify(stable)).digest("hex");
}

export function resolveLongFormVolume(
  plan: NormalizedLongFormPlan,
  chapterNumber: number,
): LongFormVolumeBudget | null {
  return plan.volumes.find((volume) => (
    chapterNumber >= volume.startChapter && chapterNumber <= volume.endChapter
  )) ?? null;
}

export function resolvePlanVolumeBoundaries(
  plan: NormalizedLongFormPlan,
): ReadonlyArray<{ name: string; startCh: number; endCh: number; number: number }> {
  return plan.volumes.map((volume) => ({
    name: volume.title ?? `Volume ${volume.number}`,
    startCh: volume.startChapter,
    endCh: volume.endChapter,
    number: volume.number,
  }));
}

export function hasCompleteChapterRange(
  boundary: { readonly startCh: number; readonly endCh: number },
  chapters: ReadonlyArray<number>,
): boolean {
  const present = new Set(chapters);
  for (let chapter = boundary.startCh; chapter <= boundary.endCh; chapter += 1) {
    if (!present.has(chapter)) return false;
  }
  return true;
}

export function buildLongFormLengthSpec(
  plan: NormalizedLongFormPlan,
  chapterNumber: number,
  language: LengthLanguage,
  targetOverride?: number,
): LengthSpec | null {
  const chapter = plan.chapters[chapterNumber - 1];
  if (!chapter || chapter.number !== chapterNumber) return null;
  const target = targetOverride ?? chapter.targetWords;
  if (!Number.isInteger(target) || target < chapter.minWords || target > chapter.maxWords) {
    throw new Error(
      `Chapter ${chapterNumber} target ${String(target)} is outside authoritative range ${chapter.minWords}-${chapter.maxWords}.`,
    );
  }
  return {
    target,
    softMin: chapter.minWords,
    softMax: chapter.maxWords,
    hardMin: chapter.minWords,
    hardMax: chapter.maxWords,
    countingMode: resolveLengthCountingMode(language),
    normalizeMode: "none",
  };
}

export function createInitialLongFormState(fingerprint: string): LongFormContinuityState {
  return LongFormContinuityStateSchema.parse({
    schemaVersion: 1,
    planFingerprint: fingerprint,
    firstObservedChapter: 0,
    lastAppliedChapter: 0,
    lastAppliedWordCount: 0,
    totalWordCount: 0,
    volumeWordCounts: {},
    timelineEvents: {},
    entityStates: {},
    knowledge: {},
    settingValues: {},
    hookStates: {},
  });
}

export async function loadLongFormContinuityState(
  bookDir: string,
  fingerprint: string,
  plan?: NormalizedLongFormPlan,
): Promise<LongFormContinuityState> {
  const path = longFormStatePath(bookDir);
  let raw: string;
  try {
    raw = await readFile(path, "utf-8");
  } catch (error) {
    if (isMissingFileError(error)) return createInitialLongFormState(fingerprint);
    throw new Error(`Failed to read long-form continuity state at ${path}: ${String(error)}`);
  }

  try {
    const state = LongFormContinuityStateSchema.parse(JSON.parse(raw));
    if (state.planFingerprint === fingerprint) return state;
    if (!plan) {
      throw new Error("replay-baseline-required: long-form plan fingerprint changed");
    }
    return rebaseLongFormContinuityState(plan, state, fingerprint);
  } catch (error) {
    throw new Error(`Invalid long-form continuity state at ${path}: ${formatValidationError(error)}`);
  }
}

export async function loadLongFormContinuityStateAt(
  bookDir: string,
  fingerprint: string,
  chapterNumber: number,
  plan?: NormalizedLongFormPlan,
): Promise<LongFormContinuityState | null> {
  const path = join(
    bookDir,
    "story",
    "snapshots",
    String(chapterNumber),
    "state",
    LONG_FORM_STATE_FILE,
  );
  let raw: string;
  try {
    raw = await readFile(path, "utf-8");
  } catch (error) {
    if (isMissingFileError(error)) return null;
    throw new Error(`Failed to read long-form snapshot at ${path}: ${String(error)}`);
  }
  try {
    const state = LongFormContinuityStateSchema.parse(JSON.parse(raw));
    if (state.planFingerprint === fingerprint) return state;
    if (!plan) {
      throw new Error("replay-baseline-required: long-form snapshot fingerprint changed");
    }
    return rebaseLongFormContinuityState(plan, state, fingerprint);
  } catch (error) {
    throw new Error(`Invalid long-form snapshot at ${path}: ${formatValidationError(error)}`);
  }
}

/**
 * Rebase historical state after an explicitly validated plan revision. Facts
 * already established by written chapters remain authoritative, but a new plan
 * may not silently invalidate their timeline, locks, knowledge, or canon.
 */
export function rebaseLongFormContinuityState(
  plan: NormalizedLongFormPlan,
  value: LongFormContinuityState,
  fingerprint = fingerprintLongFormPlan(plan),
): LongFormContinuityState {
  const state = LongFormContinuityStateSchema.parse(value);
  const incompatible = (detail: string): never => {
    throw new Error(`replay-baseline-required: plan revision ${plan.revision} conflicts with persisted continuity state: ${detail}`);
  };
  if (state.firstObservedChapter > state.lastAppliedChapter) {
    incompatible("firstObservedChapter is after lastAppliedChapter");
  }
  if (state.lastAppliedChapter > plan.targetChapters) {
    incompatible(`state reaches chapter ${state.lastAppliedChapter}, beyond target ${plan.targetChapters}`);
  }
  if ((state.lastAppliedVolumeNumber ?? 0) > plan.volumes.length) {
    incompatible(`state references volume ${state.lastAppliedVolumeNumber}`);
  }

  for (const [eventId, event] of Object.entries(state.timelineEvents)) {
    const milestone = plan.timeline.find((candidate) => candidate.id === eventId)
      ?? incompatible(`timeline event ${eventId} no longer exists`);
    if (event.chapter > state.lastAppliedChapter) {
      incompatible(`timeline event ${eventId} is ahead of applied chapter ${state.lastAppliedChapter}`);
    }
    if (event.chapter < milestone.earliestChapter || event.chapter > milestone.latestChapter) {
      incompatible(`timeline event ${eventId} at chapter ${event.chapter} is outside its new window`);
    }
  }

  for (const [entityId, current] of Object.entries(state.entityStates)) {
    const entity = plan.entities.find((candidate) => candidate.id === entityId);
    if (!entity) {
      if (!plan.policy.allowUnplannedEntities) incompatible(`entity ${entityId} is no longer allowed`);
      continue;
    }
    if (entity.immutableOwner && entity.owner !== undefined && current.owner !== entity.owner) {
      incompatible(`entity ${entityId} conflicts with immutable owner ${entity.owner}`);
    }
    if (entity.immutableLocation && entity.location !== undefined && current.location !== entity.location) {
      incompatible(`entity ${entityId} conflicts with immutable location ${entity.location}`);
    }
    for (const attribute of entity.immutableAttributes) {
      const plannedValue = entity.attributes[attribute];
      if (plannedValue !== undefined && current.attributes[attribute] !== plannedValue) {
        incompatible(`entity ${entityId} conflicts with immutable attribute ${attribute}`);
      }
    }
  }

  for (const [characterId, factIds] of Object.entries(state.knowledge)) {
    for (const factId of factIds) {
      const boundary = plan.knowledgeBoundaries.find((candidate) => candidate.factId === factId);
      // Unplanned knowledge is retained because chapter validation records it
      // as a warning rather than a critical failure.
      if (!boundary) continue;
      if (state.lastAppliedChapter < boundary.availableFromChapter) {
        incompatible(`${characterId} knows ${factId} before chapter ${boundary.availableFromChapter}`);
      }
      if (boundary.forbiddenKnowers.includes(characterId)) {
        incompatible(`${characterId} is forbidden from knowing ${factId}`);
      }
      if (boundary.allowedKnowers.length > 0 && !boundary.allowedKnowers.includes(characterId)) {
        incompatible(`${characterId} is outside allowed knowers for ${factId}`);
      }
    }
  }

  for (const [path, currentValue] of Object.entries(state.settingValues)) {
    const canon = plan.immutableCanon.find((item) => item.id === path || item.aliases.includes(path));
    if (canon?.value !== undefined && canon.value !== currentValue) {
      incompatible(`setting ${path} conflicts with immutable canon ${canon.id}`);
    }
  }

  for (const [hookId, current] of Object.entries(state.hookStates)) {
    const hook = plan.hooks.find((candidate) => candidate.hookId === hookId);
    if (!hook) continue;
    if (current.lastAdvancedChapter > 0 && current.lastAdvancedChapter < hook.openFromChapter) {
      incompatible(`hook ${hookId} advanced before chapter ${hook.openFromChapter}`);
    }
    if (hook.resolveByChapter && state.lastAppliedChapter > hook.resolveByChapter
      && !isResolvedHookStatus(current.status)) {
      incompatible(`hook ${hookId} remains open after chapter ${hook.resolveByChapter}`);
    }
  }

  return LongFormContinuityStateSchema.parse({ ...state, planFingerprint: fingerprint });
}

export function reconcileLongFormProgress(
  plan: NormalizedLongFormPlan,
  state: LongFormContinuityState,
  chapters: ReadonlyArray<ChapterProgressRecord>,
): LongFormContinuityState {
  if (chapters.length === 0) return state;
  const sorted = [...chapters]
    .filter((chapter) => Number.isInteger(chapter.number) && chapter.number >= 1 && chapter.number <= plan.targetChapters)
    .sort((left, right) => left.number - right.number);
  if (sorted.length === 0) return state;

  const volumeWordCounts: Record<string, number> = {};
  let totalWordCount = 0;
  for (const chapter of sorted) {
    const words = Math.max(0, Math.trunc(chapter.wordCount));
    const volume = resolveLongFormVolume(plan, chapter.number);
    if (!volume) continue;
    totalWordCount += words;
    const key = String(volume.number);
    volumeWordCounts[key] = (volumeWordCounts[key] ?? 0) + words;
  }
  const latest = sorted.at(-1)!;
  const latestVolume = resolveLongFormVolume(plan, latest.number);
  return LongFormContinuityStateSchema.parse({
    ...state,
    firstObservedChapter: state.firstObservedChapter || sorted[0]!.number,
    lastAppliedChapter: latest.number,
    lastAppliedWordCount: latest.wordCount,
    lastAppliedVolumeNumber: latestVolume?.number,
    totalWordCount,
    volumeWordCounts,
  });
}

export function reconcileLongFormRuntimeSnapshot(
  state: LongFormContinuityState,
  runtimeSnapshot: RuntimeStateSnapshot,
): LongFormContinuityState {
  const entityStates = { ...state.entityStates };
  for (const object of runtimeSnapshot.objects?.objects ?? []) {
    entityStates[object.objectId] = {
      owner: object.owner || entityStates[object.objectId]?.owner,
      location: object.location || entityStates[object.objectId]?.location,
      attributes: {
        ...(entityStates[object.objectId]?.attributes ?? {}),
        material: object.material,
        inscription: object.inscription,
        appearance: object.appearance,
        status: object.status,
      },
      lastChangedChapter: object.lastSeenChapter,
    };
  }
  return LongFormContinuityStateSchema.parse({
    ...state,
    entityStates,
    hookStates: Object.fromEntries(runtimeSnapshot.hooks.hooks.map((hook) => [
      hook.hookId,
      { status: hook.status, lastAdvancedChapter: hook.lastAdvancedChapter },
    ])),
  });
}

export function buildLongFormChapterContext(params: {
  readonly plan: NormalizedLongFormPlan;
  readonly state: LongFormContinuityState;
  readonly chapterNumber: number;
  readonly hooks?: ReadonlyArray<LongFormContextHook>;
  readonly facts?: ReadonlyArray<LongFormContextFact>;
  readonly targetWords?: number;
  readonly maxChars?: number;
}): string {
  const { plan, state, chapterNumber } = params;
  const chapter = plan.chapters[chapterNumber - 1];
  const volume = resolveLongFormVolume(plan, chapterNumber);
  if (!chapter || chapter.number !== chapterNumber || !volume) {
    throw new Error(`Chapter ${chapterNumber} is outside long-form plan ${plan.bookId}`);
  }
  const targetWords = params.targetWords ?? chapter.targetWords;
  if (!Number.isInteger(targetWords) || targetWords < chapter.minWords || targetWords > chapter.maxWords) {
    throw new Error(`Chapter ${chapterNumber} target ${String(targetWords)} is outside authoritative range ${chapter.minWords}-${chapter.maxWords}.`);
  }

  const maxChars = Math.max(1_000, params.maxChars ?? DEFAULT_LONG_FORM_CONTEXT_MAX_CHARS);
  const openHooks = (params.hooks ?? [])
    .filter((hook) => !isResolvedHookStatus(hook.status))
    .sort((left, right) => left.lastAdvancedChapter - right.lastAdvancedChapter || left.hookId.localeCompare(right.hookId))
    .slice(0, 32);
  const relevantKnowledge = [...plan.knowledgeBoundaries]
    .sort((left, right) => (
      Math.abs(left.availableFromChapter - chapterNumber) - Math.abs(right.availableFromChapter - chapterNumber)
      || left.factId.localeCompare(right.factId)
    ))
    .slice(0, 32);
  const relevantTimeline = [...plan.timeline]
    .sort((left, right) => (
      Math.abs((left.earliestChapter + left.latestChapter) / 2 - chapterNumber)
      - Math.abs((right.earliestChapter + right.latestChapter) / 2 - chapterNumber)
      || left.order - right.order
    ))
    .slice(0, 32);
  const relevantPlannedHooks = [...plan.hooks]
    .filter((hook) => hook.openFromChapter <= chapterNumber + 1 && (!hook.resolveByChapter || hook.resolveByChapter >= chapterNumber))
    .sort((left, right) => left.openFromChapter - right.openFromChapter || left.hookId.localeCompare(right.hookId))
    .slice(0, 32);
  const relevantEntities = [...plan.entities]
    .sort((left, right) => {
      const leftState = state.entityStates[left.id];
      const rightState = state.entityStates[right.id];
      return (rightState?.lastChangedChapter ?? 0) - (leftState?.lastChangedChapter ?? 0)
        || left.id.localeCompare(right.id);
    })
    .slice(0, 32);
  const plannedEntityIds = new Set(plan.entities.map((entity) => entity.id));
  const unplannedEntityIds = Object.keys(state.entityStates)
    .filter((id) => !plannedEntityIds.has(id))
    .sort()
    .slice(0, 32);
  const currentTimeline = Object.entries(state.timelineEvents)
    .sort(([, left], [, right]) => right.chapter - left.chapter)
    .slice(0, 32)
    .map(([id, event]) => `${id}: ${event.status} at ch.${event.chapter}${event.detail ? `; ${event.detail}` : ""}`);
  const currentEntities = relevantEntities
    .map((entity) => {
      const current = state.entityStates[entity.id];
      if (!current) return `${entity.id}: planned ${entity.name} (${entity.type}); owner=${entity.owner ?? "unset"}; location=${entity.location ?? "unset"}`;
      const attributes = Object.entries(current.attributes).map(([key, value]) => `${key}=${value}`).join(", ");
      return `${entity.id}: ${entity.name}; owner=${current.owner ?? "unset"}; location=${current.location ?? "unset"}; ${attributes || "no attributes"}; changed ch.${current.lastChangedChapter}`;
    });
  for (const entityId of unplannedEntityIds) {
    const current = state.entityStates[entityId];
    if (!current) continue;
    const attributes = Object.entries(current.attributes).map(([key, value]) => `${key}=${value}`).join(", ");
    currentEntities.push(`${entityId}: unplanned tracked entity; owner=${current.owner ?? "unset"}; location=${current.location ?? "unset"}; ${attributes || "no attributes"}; changed ch.${current.lastChangedChapter}`);
  }
  const currentKnowledge = Object.entries(state.knowledge)
    .sort(([left], [right]) => left.localeCompare(right))
    .slice(0, 32)
    .map(([character, facts]) => `${character}: knows [${facts.join(", ")}]`);
  const currentSettings = Object.entries(state.settingValues)
    .sort(([left], [right]) => left.localeCompare(right))
    .slice(0, 32)
    .map(([path, value]) => `${path}=${value}`);
  const currentVolumeWords = state.volumeWordCounts[String(volume.number)] ?? 0;
  const lines = [
    "## Authoritative Long-Form Governance",
    `Plan revision: ${plan.revision}; chapter ${chapterNumber}/${plan.targetChapters}; book progress ${state.totalWordCount}/${plan.targetWords} words.`,
    `Current volume: ${volume.number} (chapters ${volume.startChapter}-${volume.endChapter}); progress ${currentVolumeWords}/${volume.targetWords} words.`,
    `Chapter budget: target ${targetWords}; allowed ${chapter.minWords}-${chapter.maxWords}; Publisher tolerance ${plan.chapterWordTolerancePercent}%.`,
    targetWords !== chapter.targetWords ? `Planned chapter target ${chapter.targetWords} was dynamically adjusted to the remaining volume budget.` : "",
    ...sectionLines("Special constraints (protected)", plan.specialConstraints.slice(0, 32)),
    `Continuity policy: require delta=${plan.policy.requireConsistencyDelta}; allow unplanned entities=${plan.policy.allowUnplannedEntities}; volume checkpoints=${plan.policy.checkpointAtVolumeEnd}.`,
    ...sectionLines("Planned timeline milestones", relevantTimeline.map((item) => (
      `${item.id}: order ${item.order}; chapters ${item.earliestChapter}-${item.latestChapter}; ${item.label}`
    ))),
    ...sectionLines("Planned hooks", relevantPlannedHooks.map((hook) => (
      `${hook.hookId}: opens ch.${hook.openFromChapter}; resolves by ch.${hook.resolveByChapter ?? "unspecified"}; ${hook.description}`
    ))),
    ...sectionLines("Planned entities and current state", currentEntities),
    ...sectionLines("Applied timeline events", currentTimeline),
    ...sectionLines("Current knowledge state", currentKnowledge),
    ...sectionLines("Current setting values", currentSettings),
    ...sectionLines("Open hooks", openHooks.map((hook) => (
      `${hook.hookId}: ${hook.status}; last advanced ch.${hook.lastAdvancedChapter}; ${hook.expectedPayoff ?? "payoff unspecified"}`
    ))),
    ...sectionLines("Character knowledge boundaries", relevantKnowledge.map((boundary) => (
      `${boundary.factId}: available ch.${boundary.availableFromChapter}; allowed=[${boundary.allowedKnowers.join(",")}]; forbidden=[${boundary.forbiddenKnowers.join(",")}]; ${boundary.statement}`
    ))),
    ...sectionLines("Immutable canon", plan.immutableCanon.slice(0, 12).map((item) => `${item.id}: ${item.statement}`)),
    ...sectionLines("World rules", plan.worldRules.slice(0, 16).map((item) => `${item.id}: ${item.statement}`)),
    ...sectionLines("Current hard facts", (params.facts ?? []).slice(-24).map((fact) => (
      `${fact.subject} / ${fact.predicate} / ${fact.object}${fact.sourceChapter ? ` (ch.${fact.sourceChapter})` : ""}`
    ))),
    "These constraints are protected and must not be overridden by temporary chapter guidance.",
  ];
  return capContext(lines.join("\n"), maxChars);
}

export function validateAndApplyLongFormChapter(params: {
  readonly plan: NormalizedLongFormPlan;
  readonly fingerprint: string;
  readonly state: LongFormContinuityState;
  readonly chapterNumber: number;
  readonly wordCount: number;
  readonly runtimeDelta?: RuntimeStateDelta;
  readonly consistencyDelta?: LongFormConsistencyDelta;
  readonly allowReapply?: boolean;
}): LongFormValidationResult {
  const { plan, chapterNumber } = params;
  const issues: LongFormValidationIssue[] = [];
  const volume = resolveLongFormVolume(plan, chapterNumber);
  const chapter = plan.chapters[chapterNumber - 1];
  let next = LongFormContinuityStateSchema.parse({
    ...params.state,
    planFingerprint: params.fingerprint,
    volumeWordCounts: { ...params.state.volumeWordCounts },
    timelineEvents: { ...params.state.timelineEvents },
    entityStates: { ...params.state.entityStates },
    knowledge: Object.fromEntries(Object.entries(params.state.knowledge).map(([key, value]) => [key, [...value]])),
    settingValues: { ...params.state.settingValues },
    hookStates: { ...params.state.hookStates },
  });

  if (!chapter || chapter.number !== chapterNumber || !volume) {
    addValidationIssue(issues, "critical", "chapter-outside-plan", `Chapter ${chapterNumber} is outside the authoritative plan.`);
    return { issues, nextState: next, volume: null, volumeEnded: false };
  }
  if (!Number.isInteger(params.wordCount) || params.wordCount < 0) {
    addValidationIssue(issues, "critical", "invalid-word-count", `Chapter ${chapterNumber} has an invalid word count.`);
    return { issues, nextState: next, volume, volumeEnded: chapterNumber === volume.endChapter };
  }
  if (params.runtimeDelta && params.runtimeDelta.chapter !== chapterNumber) {
    addValidationIssue(issues, "critical", "delta-chapter-mismatch", `Runtime delta chapter ${params.runtimeDelta.chapter} does not match ${chapterNumber}.`);
  }

  const reapplying = params.allowReapply === true && chapterNumber === next.lastAppliedChapter;
  if (reapplying) {
    addValidationIssue(
      issues,
      "critical",
      "replay-baseline-required",
      `Chapter ${chapterNumber} must be replayed from snapshot ${Math.max(0, chapterNumber - 1)}; aggregate continuity state cannot safely remove superseded facts.`,
    );
    return { issues, nextState: next, volume, volumeEnded: chapterNumber === volume.endChapter };
  }
  if (!reapplying && next.lastAppliedChapter > 0 && chapterNumber !== next.lastAppliedChapter + 1) {
    addValidationIssue(issues, "critical", "chapter-sequence-gap", `Chapter ${chapterNumber} does not follow continuity state chapter ${next.lastAppliedChapter}.`);
  }
  if (chapterNumber < next.lastAppliedChapter || (chapterNumber === next.lastAppliedChapter && !reapplying)) {
    addValidationIssue(issues, "critical", "chapter-sequence-regression", `Chapter ${chapterNumber} would regress long-form continuity state.`);
  }
  if (params.wordCount < chapter.minWords || params.wordCount > chapter.maxWords) {
    addValidationIssue(
      issues,
      "critical",
      "chapter-length-drift",
      `Chapter ${chapterNumber} has ${params.wordCount} words; authoritative range is ${chapter.minWords}-${chapter.maxWords}.`,
    );
  }

  const delta = params.consistencyDelta
    ? LongFormConsistencyDeltaSchema.parse(params.consistencyDelta)
    : params.runtimeDelta?.longFormConsistency
      ? LongFormConsistencyDeltaSchema.parse(params.runtimeDelta.longFormConsistency)
      : LongFormConsistencyDeltaSchema.parse({});
  if (plan.policy.requireConsistencyDelta && !params.consistencyDelta && !params.runtimeDelta?.longFormConsistency) {
    addValidationIssue(issues, "critical", "missing-consistency-delta", `Chapter ${chapterNumber} did not emit longFormConsistency.`);
  }

  const previousWords = reapplying ? next.lastAppliedWordCount : 0;
  const volumeKey = String(volume.number);
  next = {
    ...next,
    firstObservedChapter: next.firstObservedChapter || chapterNumber,
    lastAppliedChapter: Math.max(next.lastAppliedChapter, chapterNumber),
    lastAppliedWordCount: params.wordCount,
    lastAppliedVolumeNumber: volume.number,
    totalWordCount: Math.max(0, next.totalWordCount - previousWords + params.wordCount),
    volumeWordCounts: {
      ...next.volumeWordCounts,
      [volumeKey]: Math.max(0, (next.volumeWordCounts[volumeKey] ?? 0) - previousWords + params.wordCount),
    },
  };

  next = applyTimelineDelta(plan, next, delta, chapterNumber, issues);
  next = applyEntityDelta(plan, next, delta, params.runtimeDelta, chapterNumber, issues);
  next = applyKnowledgeDelta(plan, next, delta, chapterNumber, issues);
  next = applyWorldRuleDelta(plan, next, delta, issues);
  next = applySettingDelta(plan, next, delta, issues);
  next = applyHookDelta(plan, next, params.runtimeDelta, chapterNumber, issues);

  const volumeEnded = chapterNumber === volume.endChapter;
  if (volumeEnded) {
    const budgets = plan.chapters.slice(volume.startChapter - 1, volume.endChapter);
    const minWords = budgets.reduce((sum, item) => sum + item.minWords, 0);
    const maxWords = budgets.reduce((sum, item) => sum + item.maxWords, 0);
    const actualWords = next.volumeWordCounts[volumeKey] ?? 0;
    if (actualWords < minWords || actualWords > maxWords) {
      addValidationIssue(
        issues,
        "critical",
        "volume-length-drift",
        `Volume ${volume.number} has ${actualWords} words; aggregate range is ${minWords}-${maxWords}.`,
      );
    }
  }
  if (chapterNumber === plan.targetChapters) {
    const minWords = plan.chapters.reduce((sum, item) => sum + item.minWords, 0);
    const maxWords = plan.chapters.reduce((sum, item) => sum + item.maxWords, 0);
    if (next.totalWordCount < minWords || next.totalWordCount > maxWords) {
      addValidationIssue(issues, "critical", "book-length-drift", `Book total ${next.totalWordCount} is outside ${minWords}-${maxWords}.`);
    }
  }

  return {
    issues,
    nextState: LongFormContinuityStateSchema.parse(next),
    volume,
    volumeEnded,
  };
}

export async function persistLongFormContinuityState(
  bookDir: string,
  state: LongFormContinuityState,
): Promise<void> {
  await writeAtomicJson(longFormStatePath(bookDir), LongFormContinuityStateSchema.parse(state));
}

export function buildCanonCheckpoint(params: {
  readonly plan: NormalizedLongFormPlan;
  readonly fingerprint: string;
  readonly state: LongFormContinuityState;
  readonly volume: LongFormVolumeBudget;
  readonly runtimeSnapshot?: RuntimeStateSnapshot;
  readonly generatedAt?: string;
}): CanonCheckpoint {
  const { plan, state, volume, runtimeSnapshot } = params;
  const nextVolume = plan.volumes.find((candidate) => candidate.number === volume.number + 1);
  const activeFacts = (runtimeSnapshot?.currentState.facts ?? [])
    .filter((fact) => fact.validUntilChapter === null)
    .slice(-128)
    .map((fact) => ({
      subject: fact.subject,
      predicate: fact.predicate,
      object: fact.object,
      sourceChapter: fact.sourceChapter,
    }));
  const openHooks = (runtimeSnapshot?.hooks.hooks ?? [])
    .filter((hook) => !isResolvedHookStatus(hook.status))
    .slice(0, 128)
    .map((hook) => ({
      hookId: hook.hookId,
      status: hook.status,
      lastAdvancedChapter: hook.lastAdvancedChapter,
      expectedPayoff: hook.expectedPayoff,
    }));

  return CanonCheckpointSchema.parse({
    schemaVersion: 1,
    planFingerprint: params.fingerprint,
    volume: {
      number: volume.number,
      startChapter: volume.startChapter,
      endChapter: volume.endChapter,
      actualWords: state.volumeWordCounts[String(volume.number)] ?? 0,
      targetWords: volume.targetWords,
    },
    completedAtChapter: volume.endChapter,
    generatedAt: params.generatedAt ?? new Date().toISOString(),
    immutableCanon: plan.immutableCanon.slice(0, 128).map((item) => ({ id: item.id, statement: item.statement })),
    activeFacts,
    openHooks,
    entities: Object.entries(state.entityStates).slice(0, 128).map(([entityId, entity]) => ({
      entityId,
      owner: entity.owner,
      location: entity.location,
      attributes: entity.attributes,
    })),
    knowledge: state.knowledge,
    completedTimelineEventIds: Object.entries(state.timelineEvents)
      .filter(([, event]) => event.status === "occurred")
      .map(([eventId]) => eventId),
    nextVolumeNumber: nextVolume?.number,
  });
}

export async function persistCanonCheckpoint(bookDir: string, checkpoint: CanonCheckpoint): Promise<string> {
  const parsed = CanonCheckpointSchema.parse(checkpoint);
  const path = join(
    bookDir,
    "story",
    "canon_checkpoints",
    `volume-${String(parsed.volume.number).padStart(4, "0")}.json`,
  );
  try {
    const existing = CanonCheckpointSchema.parse(JSON.parse(await readFile(path, "utf-8")));
    if (
      existing.planFingerprint === parsed.planFingerprint
      && existing.completedAtChapter === parsed.completedAtChapter
      && existing.volume.actualWords === parsed.volume.actualWords
    ) {
      return path;
    }
  } catch (error) {
    if (!isMissingFileError(error)) {
      // A corrupt or stale checkpoint is replaced atomically below.
    }
  }
  await writeAtomicJson(path, parsed);
  return path;
}

export async function writeAtomicJson(path: string, value: unknown): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const tempPath = join(dirname(path), `.${basename(path)}.${process.pid}.${randomUUID()}.tmp`);
  try {
    await writeFile(tempPath, `${JSON.stringify(value, null, 2)}\n`, { encoding: "utf-8", mode: 0o600 });
    await rename(tempPath, path);
  } catch (error) {
    await rm(tempPath, { force: true }).catch(() => undefined);
    throw error;
  }
}

function extractContinuityExtension(publisher: PublisherLongFormPlan): LongFormContinuityExtension {
  const root = publisher as PublisherLongFormPlan & Record<string, unknown>;
  const extensions = isRecord(root.extensions) ? root.extensions : null;
  const planBody = isRecord(root.plan) ? root.plan : null;
  const planExtensions = planBody && isRecord(planBody.extensions) ? planBody.extensions : null;
  const candidates = [
    hasContinuityKeys(root) ? root : undefined,
    planExtensions?.continuity,
    planBody?.continuity,
    extensions?.continuity,
    root.continuity,
  ].filter(isRecord);
  const merged = Object.assign({}, ...candidates);
  const mergedPolicy = Object.assign(
    {},
    ...candidates.map((candidate) => candidate.policy).filter(isRecord),
  );
  if (Object.keys(mergedPolicy).length > 0) merged.policy = mergedPolicy;
  return LongFormContinuityExtensionSchema.parse(merged);
}

function validateContinuityExtension(
  extension: LongFormContinuityExtension,
  targetChapters: number,
  volumeCount: number,
): void {
  assertUnique(extension.immutableCanon.map((item) => item.id), "immutable canon id");
  assertUnique(extension.worldRules.map((item) => item.id), "world rule id");
  assertUnique(extension.entities.map((item) => item.id), "entity id");
  assertUnique(extension.knowledgeBoundaries.map((item) => item.factId), "knowledge fact id");
  assertUnique(extension.timeline.map((item) => item.id), "timeline id");
  assertUnique(extension.timeline.map((item) => String(item.order)), "timeline order");
  assertUnique(extension.hooks.map((item) => item.hookId), "hook id");
  for (const item of extension.timeline) {
    if (item.earliestChapter > item.latestChapter || item.latestChapter > targetChapters) {
      throw new Error(`timeline ${item.id} has invalid chapter boundaries`);
    }
  }
  for (const boundary of extension.knowledgeBoundaries) {
    if (boundary.availableFromChapter > targetChapters || (boundary.revealByChapter ?? 0) > targetChapters) {
      throw new Error(`knowledge boundary ${boundary.factId} exceeds targetChapters`);
    }
    if (boundary.revealByChapter && boundary.revealByChapter < boundary.availableFromChapter) {
      throw new Error(`knowledge boundary ${boundary.factId} revealByChapter precedes availability`);
    }
    const allowed = new Set(boundary.allowedKnowers);
    const conflictingKnower = boundary.forbiddenKnowers.find((characterId) => allowed.has(characterId));
    if (conflictingKnower) {
      throw new Error(
        `knowledge boundary ${boundary.factId} lists ${conflictingKnower} as both allowed and forbidden`,
      );
    }
  }
  for (const hook of extension.hooks) {
    if (hook.openFromChapter > targetChapters || (hook.resolveByChapter ?? 0) > targetChapters) {
      throw new Error(`hook ${hook.hookId} exceeds targetChapters`);
    }
    if (hook.resolveByChapter && hook.resolveByChapter < hook.openFromChapter) {
      throw new Error(`hook ${hook.hookId} resolves before it opens`);
    }
    if (hook.requiredVolumeNumber && hook.requiredVolumeNumber > volumeCount) {
      throw new Error(`hook ${hook.hookId} references unknown volume ${hook.requiredVolumeNumber}`);
    }
  }
}

function applyTimelineDelta(
  plan: NormalizedLongFormPlan,
  state: LongFormContinuityState,
  delta: LongFormConsistencyDelta,
  chapterNumber: number,
  issues: LongFormValidationIssue[],
): LongFormContinuityState {
  const events = { ...state.timelineEvents };
  for (const event of delta.timelineEvents) {
    const milestone = plan.timeline.find((item) => item.id === event.eventId);
    if (!milestone) {
      addValidationIssue(issues, "warning", "unplanned-timeline-event", `Timeline event ${event.eventId} is not in the plan.`);
      continue;
    }
    if (chapterNumber < milestone.earliestChapter || chapterNumber > milestone.latestChapter) {
      addValidationIssue(issues, "critical", "timeline-boundary-conflict", `Timeline event ${event.eventId} occurred outside chapters ${milestone.earliestChapter}-${milestone.latestChapter}.`);
    }
    const missingEarlier = plan.timeline.some((candidate) => (
      candidate.order < milestone.order
      && candidate.immutable
      && !events[candidate.id]
    ));
    if (event.status === "occurred" && missingEarlier) {
      addValidationIssue(issues, "critical", "timeline-order-conflict", `Timeline event ${event.eventId} occurred before an earlier immutable milestone.`);
    }
    events[event.eventId] = { chapter: chapterNumber, status: event.status, detail: event.detail };
  }
  for (const milestone of plan.timeline) {
    if (milestone.immutable && chapterNumber >= milestone.latestChapter && !events[milestone.id]) {
      addValidationIssue(issues, "critical", "timeline-milestone-missed", `Timeline event ${milestone.id} was not completed by chapter ${milestone.latestChapter}.`);
    }
  }
  return { ...state, timelineEvents: events };
}

function applyEntityDelta(
  plan: NormalizedLongFormPlan,
  state: LongFormContinuityState,
  delta: LongFormConsistencyDelta,
  runtimeDelta: RuntimeStateDelta | undefined,
  chapterNumber: number,
  issues: LongFormValidationIssue[],
): LongFormContinuityState {
  const entityStates = { ...state.entityStates };
  const objectOps: Array<{
    entityId: string;
    owner?: string;
    location?: string;
    attributes: Record<string, string>;
    changeReason?: string;
  }> = (runtimeDelta?.objectOps?.upsert ?? []).map((object) => ({
    entityId: object.objectId,
    owner: object.owner || undefined,
    location: object.location || undefined,
    attributes: {
      material: object.material,
      inscription: object.inscription,
      appearance: object.appearance,
      status: object.status,
    },
    changeReason: object.attributeChangeReason,
  }));
  for (const operation of [...delta.entityOps, ...objectOps]) {
    const planned = plan.entities.find((entity) => entity.id === operation.entityId);
    if (!planned && !plan.policy.allowUnplannedEntities) {
      addValidationIssue(issues, "critical", "unplanned-entity", `Entity ${operation.entityId} is not allowed by the plan.`);
      continue;
    }
    const current = entityStates[operation.entityId] ?? (planned ? {
      owner: planned.owner,
      location: planned.location,
      attributes: planned.attributes,
      lastChangedChapter: 0,
    } : { attributes: {}, lastChangedChapter: 0 });
    if (planned?.immutableOwner && operation.owner !== undefined && current.owner !== undefined && operation.owner !== current.owner) {
      addValidationIssue(issues, "critical", "entity-owner-conflict", `Entity ${operation.entityId} owner changed from ${current.owner} to ${operation.owner}.`);
    }
    if (planned?.immutableLocation && operation.location !== undefined && current.location !== undefined && operation.location !== current.location) {
      addValidationIssue(issues, "critical", "entity-location-conflict", `Entity ${operation.entityId} location changed from ${current.location} to ${operation.location}.`);
    }
    for (const attribute of planned?.immutableAttributes ?? []) {
      const before = current.attributes[attribute];
      const after = operation.attributes[attribute];
      if (before !== undefined && after !== undefined && after.trim().length > 0 && before !== after) {
        addValidationIssue(issues, "critical", "entity-attribute-conflict", `Entity ${operation.entityId} immutable ${attribute} changed from ${before} to ${after}.`);
      }
    }
    entityStates[operation.entityId] = {
      owner: operation.owner ?? current.owner,
      location: operation.location ?? current.location,
      attributes: { ...current.attributes, ...operation.attributes },
      lastChangedChapter: chapterNumber,
    };
  }
  return { ...state, entityStates };
}

function applyKnowledgeDelta(
  plan: NormalizedLongFormPlan,
  state: LongFormContinuityState,
  delta: LongFormConsistencyDelta,
  chapterNumber: number,
  issues: LongFormValidationIssue[],
): LongFormContinuityState {
  const knowledge = Object.fromEntries(Object.entries(state.knowledge).map(([key, value]) => [key, [...value]]));
  for (const claim of delta.knowledgeClaims) {
    const boundary = plan.knowledgeBoundaries.find((item) => item.factId === claim.factId);
    if (!boundary) {
      addValidationIssue(issues, "warning", "unplanned-knowledge", `Knowledge fact ${claim.factId} is not in the plan.`);
      continue;
    }
    if (claim.action === "guesses") continue;
    if (chapterNumber < boundary.availableFromChapter) {
      addValidationIssue(issues, "critical", "knowledge-too-early", `${claim.characterId} learned ${claim.factId} before chapter ${boundary.availableFromChapter}.`);
    }
    if (boundary.forbiddenKnowers.includes(claim.characterId)) {
      addValidationIssue(issues, "critical", "knowledge-forbidden", `${claim.characterId} is forbidden from knowing ${claim.factId}.`);
    }
    if (boundary.allowedKnowers.length > 0 && !boundary.allowedKnowers.includes(claim.characterId)) {
      addValidationIssue(issues, "critical", "knowledge-not-allowed", `${claim.characterId} is outside the allowed knowers for ${claim.factId}.`);
    }
    knowledge[claim.characterId] = [...new Set([...(knowledge[claim.characterId] ?? []), claim.factId])];
  }
  return { ...state, knowledge };
}

function applyWorldRuleDelta(
  plan: NormalizedLongFormPlan,
  state: LongFormContinuityState,
  delta: LongFormConsistencyDelta,
  issues: LongFormValidationIssue[],
): LongFormContinuityState {
  for (const assertion of delta.worldRuleAssertions) {
    const rule = plan.worldRules.find((item) => item.id === assertion.ruleId);
    if (!rule) {
      addValidationIssue(issues, "warning", "unplanned-world-rule", `World rule ${assertion.ruleId} is not in the plan.`);
    } else if (rule.immutable && assertion.status !== "honored") {
      addValidationIssue(issues, "critical", "world-rule-conflict", `Immutable world rule ${assertion.ruleId} was ${assertion.status}.`);
    }
  }
  return state;
}

function applySettingDelta(
  plan: NormalizedLongFormPlan,
  state: LongFormContinuityState,
  delta: LongFormConsistencyDelta,
  issues: LongFormValidationIssue[],
): LongFormContinuityState {
  const settingValues = { ...state.settingValues };
  for (const setting of delta.settingDeltas) {
    const canon = setting.canonId
      ? plan.immutableCanon.find((item) => item.id === setting.canonId)
      : plan.immutableCanon.find((item) => item.id === setting.path || item.aliases.includes(setting.path));
    const current = settingValues[setting.path];
    if (setting.previousValue !== undefined && current !== undefined && setting.previousValue !== current) {
      addValidationIssue(issues, "critical", "setting-stale-write", `Setting ${setting.path} expected ${setting.previousValue}, but continuity state has ${current}.`);
    }
    const canonValue = canon?.value ?? canon?.statement;
    if (canonValue !== undefined && setting.nextValue !== canonValue) {
      addValidationIssue(issues, "critical", "immutable-canon-conflict", `Setting ${setting.path} conflicts with immutable canon ${canon?.id ?? setting.canonId ?? setting.path}.`);
    }
    if (current !== undefined && current !== setting.nextValue && !setting.reason?.trim()) {
      addValidationIssue(issues, "critical", "setting-random-delta", `Setting ${setting.path} changed from ${current} to ${setting.nextValue} without an in-story reason.`);
    }
    if (setting.introduced && canonValue !== undefined && canonValue !== setting.nextValue) {
      addValidationIssue(issues, "critical", "setting-introduction-conflict", `New setting ${setting.path} contradicts canon ${canon?.id ?? setting.canonId ?? setting.path}.`);
    }
    settingValues[setting.path] = setting.nextValue;
  }
  return { ...state, settingValues };
}

function applyHookDelta(
  plan: NormalizedLongFormPlan,
  state: LongFormContinuityState,
  runtimeDelta: RuntimeStateDelta | undefined,
  chapterNumber: number,
  issues: LongFormValidationIssue[],
): LongFormContinuityState {
  const hookStates = { ...state.hookStates };
  const hookOps = runtimeDelta?.hookOps;
  for (const hook of hookOps?.upsert ?? []) {
    hookStates[hook.hookId] = { status: hook.status, lastAdvancedChapter: hook.lastAdvancedChapter };
  }
  for (const hookId of hookOps?.resolve ?? []) {
    hookStates[hookId] = { status: "resolved", lastAdvancedChapter: chapterNumber };
  }
  for (const hookId of hookOps?.defer ?? []) {
    hookStates[hookId] = { status: "deferred", lastAdvancedChapter: chapterNumber };
  }
  for (const planned of plan.hooks) {
    const current = hookStates[planned.hookId];
    if (chapterNumber < planned.openFromChapter && current && !isResolvedHookStatus(current.status)) {
      addValidationIssue(issues, "critical", "hook-opened-too-early", `Hook ${planned.hookId} opened before chapter ${planned.openFromChapter}.`);
    }
    if (planned.resolveByChapter && chapterNumber >= planned.resolveByChapter && !isResolvedHookStatus(current?.status ?? "open")) {
      addValidationIssue(issues, "critical", "hook-overdue", `Hook ${planned.hookId} was not resolved by chapter ${planned.resolveByChapter}.`);
    }
  }
  return { ...state, hookStates };
}

function longFormStatePath(bookDir: string): string {
  return join(bookDir, "story", "state", LONG_FORM_STATE_FILE);
}

function sectionLines(title: string, values: ReadonlyArray<string>): string[] {
  if (values.length === 0) return [];
  return [`### ${title}`, ...values.map((value) => `- ${compactText(value, 360)}`)];
}

function compactText(value: string, maxChars: number): string {
  const compact = value.replace(/\s+/g, " ").trim();
  return compact.length <= maxChars ? compact : `${compact.slice(0, maxChars - 3)}...`;
}

function capContext(value: string, maxChars: number): string {
  if (value.length <= maxChars) return value;
  const marker = "\n[Long-form context truncated at fixed budget]\n";
  const head = Math.max(1, maxChars - marker.length);
  return `${value.slice(0, head).trimEnd()}${marker}`.slice(0, maxChars);
}

function addValidationIssue(
  issues: LongFormValidationIssue[],
  severity: LongFormValidationIssue["severity"],
  code: string,
  message: string,
): void {
  if (!issues.some((issue) => issue.code === code && issue.message === message)) {
    issues.push({ severity, code, message });
  }
}

function isResolvedHookStatus(status: string): boolean {
  return /^(?:resolved|closed|done|已回收|已解决)$/i.test(status.trim());
}

function isMissingFileError(error: unknown): boolean {
  return isRecord(error) && error.code === "ENOENT";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasContinuityKeys(value: Record<string, unknown>): boolean {
  return ["immutableCanon", "worldRules", "entities", "knowledgeBoundaries", "timeline", "hooks", "policy"]
    .some((key) => value[key] !== undefined);
}

function assertUnique(values: ReadonlyArray<string>, label: string): void {
  const seen = new Set<string>();
  for (const value of values) {
    if (seen.has(value)) throw new Error(`duplicate ${label}: ${value}`);
    seen.add(value);
  }
}

function formatValidationError(error: unknown): string {
  if (isRecord(error) && Array.isArray(error.issues)) {
    return error.issues
      .slice(0, 8)
      .map((issue) => isRecord(issue) ? `${String(issue.path ?? "")}: ${String(issue.message ?? issue)}` : String(issue))
      .join("; ");
  }
  return error instanceof Error ? error.message : String(error);
}
