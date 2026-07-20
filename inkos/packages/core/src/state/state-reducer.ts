import {
  ChapterSummariesStateSchema,
  CurrentStateStateSchema,
  HooksStateSchema,
  PersistentObjectsStateSchema,
  RuntimeStateDeltaSchema,
  StateManifestSchema,
  type HookRecord,
  type ChapterSummariesState,
  type CurrentStateState,
  type HooksState,
  type PersistentObjectRecord,
  type PersistentObjectsState,
  type RuntimeStateDelta,
  type StateManifest,
} from "../models/runtime-state.js";
import { evaluateHookAdmission } from "../utils/hook-governance.js";
import { resolveHookPayoffTiming } from "../utils/hook-lifecycle.js";
import { validateRuntimeState } from "./state-validator.js";

export interface RuntimeStateSnapshot {
  readonly manifest: StateManifest;
  readonly currentState: CurrentStateState;
  readonly hooks: HooksState;
  readonly chapterSummaries: ChapterSummariesState;
  readonly objects?: PersistentObjectsState;
}

export function applyRuntimeStateDelta(params: {
  readonly snapshot: RuntimeStateSnapshot;
  readonly delta: RuntimeStateDelta;
  readonly allowReapply?: boolean;
}): RuntimeStateSnapshot {
  const snapshot = {
    manifest: StateManifestSchema.parse(params.snapshot.manifest),
    currentState: CurrentStateStateSchema.parse(params.snapshot.currentState),
    hooks: HooksStateSchema.parse(params.snapshot.hooks),
    chapterSummaries: ChapterSummariesStateSchema.parse(params.snapshot.chapterSummaries),
    objects: PersistentObjectsStateSchema.parse(params.snapshot.objects ?? { objects: [] }),
  };
  const delta = RuntimeStateDeltaSchema.parse(params.delta);
  const allowReapply = params.allowReapply ?? false;

  if (allowReapply ? delta.chapter < snapshot.manifest.lastAppliedChapter : delta.chapter <= snapshot.manifest.lastAppliedChapter) {
    throw new Error(`delta chapter ${delta.chapter} goes backwards`);
  }

  if (delta.chapterSummary && delta.chapterSummary.chapter !== delta.chapter) {
    throw new Error(`chapter summary ${delta.chapterSummary.chapter} does not match delta chapter ${delta.chapter}`);
  }

  if (
    delta.chapterSummary
    && snapshot.chapterSummaries.rows.some((row) => row.chapter === delta.chapterSummary?.chapter)
    && !allowReapply
  ) {
    throw new Error(`duplicate summary row for chapter ${delta.chapterSummary.chapter}`);
  }

  const hooks = applyHookOps(snapshot.hooks, delta);
  const currentState = applyCurrentStatePatch(
    snapshot.currentState,
    snapshot.manifest.language,
    delta,
  );
  const chapterSummaries = applySummaryDelta(snapshot.chapterSummaries, delta, allowReapply);
  const objects = applyObjectOps(snapshot.objects, delta);

  const next: RuntimeStateSnapshot = {
    manifest: {
      ...snapshot.manifest,
      lastAppliedChapter: delta.chapter,
    },
    currentState,
    hooks,
    chapterSummaries,
    objects,
  };

  const issues = validateRuntimeState(next);
  if (issues.length > 0) {
    throw new Error(issues.map((issue) => `${issue.code}: ${issue.message}`).join("; "));
  }

  return next;
}

function applyObjectOps(objectsState: PersistentObjectsState, delta: RuntimeStateDelta): PersistentObjectsState {
  const objectsById = new Map(objectsState.objects.map((object) => [object.objectId, { ...object }]));

  for (const incoming of delta.objectOps?.upsert ?? []) {
    const existing = objectsById.get(incoming.objectId);
    if (!existing) {
      objectsById.set(incoming.objectId, { ...incoming });
      continue;
    }

    assertStableObjectAttribute(existing, incoming, "material");
    assertStableObjectAttribute(existing, incoming, "inscription");
    objectsById.set(incoming.objectId, mergeObjectRecord(existing, incoming));
  }

  return {
    objects: [...objectsById.values()].sort((left, right) => (
      left.firstSeenChapter - right.firstSeenChapter
      || left.objectId.localeCompare(right.objectId)
    )),
  };
}

function assertStableObjectAttribute(
  existing: PersistentObjectRecord,
  incoming: PersistentObjectRecord,
  field: "material" | "inscription",
): void {
  const before = existing[field].trim();
  const after = incoming[field].trim();
  if (!before || !after || normalizeStableObjectAttribute(before, field) === normalizeStableObjectAttribute(after, field)) return;
  if (incoming.attributeChangeReason?.trim()) return;
  throw new Error(
    `persistent object ${incoming.objectId} ${field} conflict: ${before} -> ${after} without an explicit in-story change reason`,
  );
}

function normalizeStableObjectAttribute(
  value: string,
  field: "material" | "inscription",
): string {
  const compact = value.replace(/[\s“”"'《》【】（）()，,。；;：:]/g, "").toLowerCase();
  if (field === "material") {
    return compact.replace(/(?:材质|制成|打造|制作|制|质)$/u, "");
  }
  return compact
    .replace(/^(?:刻有|刻着|刻|写有|写着)/u, "")
    .replace(/(?:三个字|两个字|四个字|二字|字样|文字)$/u, "");
}

function mergeObjectRecord(
  existing: PersistentObjectRecord,
  incoming: PersistentObjectRecord,
): PersistentObjectRecord {
  const preferIncoming = (before: string, after: string): string => after.trim() || before;
  return {
    ...existing,
    ...incoming,
    name: preferIncoming(existing.name, incoming.name),
    aliases: [...new Set([...existing.aliases, ...incoming.aliases])],
    material: preferIncoming(existing.material, incoming.material),
    inscription: preferIncoming(existing.inscription, incoming.inscription),
    appearance: preferIncoming(existing.appearance, incoming.appearance),
    owner: preferIncoming(existing.owner, incoming.owner),
    location: preferIncoming(existing.location, incoming.location),
    status: preferIncoming(existing.status, incoming.status),
    firstSeenChapter: Math.min(existing.firstSeenChapter, incoming.firstSeenChapter),
    lastSeenChapter: Math.max(existing.lastSeenChapter, incoming.lastSeenChapter),
    linkedHookIds: [...new Set([...existing.linkedHookIds, ...incoming.linkedHookIds])],
    notes: preferRicherText(existing.notes, incoming.notes),
  };
}

function applyHookOps(hooksState: HooksState, delta: RuntimeStateDelta): HooksState {
  const hooksById = new Map(hooksState.hooks.map((hook) => [hook.hookId, { ...hook }]));

  for (const hook of delta.hookOps.upsert) {
    const sameHook = hooksById.get(hook.hookId);
    if (sameHook) {
      hooksById.set(sameHook.hookId, mergeHookRecord(sameHook, hook));
      continue;
    }

    const admission = evaluateHookAdmission({
      candidate: {
        type: hook.type,
        expectedPayoff: hook.expectedPayoff,
        notes: hook.notes,
      },
      activeHooks: [...hooksById.values()].filter((candidate) => candidate.status !== "resolved"),
    });

    if (!admission.admit && admission.reason === "duplicate_family") {
      const matchedHookId = admission.matchedHookId;
      const existing = matchedHookId ? hooksById.get(matchedHookId) : undefined;
      if (!existing) {
        throw new Error(`duplicate active hook family: ${hook.hookId} overlaps ${admission.matchedHookId}`);
      }
      hooksById.set(existing.hookId, mergeDuplicateHookFamily(existing, hook));
      continue;
    }

    hooksById.set(hook.hookId, { ...hook });
  }

  for (const hookId of delta.hookOps.resolve) {
    const existing = hooksById.get(hookId);
    if (!existing) {
      // Hook may have been cleared by a previous settlement or not yet created — skip gracefully
      continue;
    }
    hooksById.set(hookId, {
      ...existing,
      status: "resolved",
      lastAdvancedChapter: Math.max(existing.lastAdvancedChapter, delta.chapter),
    });
  }

  for (const hookId of delta.hookOps.defer) {
    const existing = hooksById.get(hookId);
    if (!existing) {
      continue;
    }
    hooksById.set(hookId, {
      ...existing,
      status: "deferred",
      lastAdvancedChapter: Math.max(existing.lastAdvancedChapter, delta.chapter),
    });
  }

  return {
    hooks: [...hooksById.values()].sort((left, right) => (
      left.startChapter - right.startChapter
      || left.lastAdvancedChapter - right.lastAdvancedChapter
      || left.hookId.localeCompare(right.hookId)
    )),
  };
}

function mergeDuplicateHookFamily(existing: HookRecord, incoming: HookRecord): HookRecord {
  return mergeHookRecord(existing, incoming);
}

function mergeHookRecord(existing: HookRecord, incoming: HookRecord): HookRecord {
  const expectedPayoff = preferRicherText(existing.expectedPayoff, incoming.expectedPayoff);
  const notes = preferRicherText(existing.notes, incoming.notes);
  const advanced = Math.max(existing.lastAdvancedChapter, incoming.lastAdvancedChapter);
  const progressed = advanced > existing.lastAdvancedChapter;

  return {
    ...existing,
    startChapter: Math.min(existing.startChapter, incoming.startChapter),
    type: preferRicherText(existing.type, incoming.type),
    status: mergeHookStatus(existing.status, incoming.status, progressed),
    lastAdvancedChapter: advanced,
    expectedPayoff,
    payoffTiming: resolveHookPayoffTiming({
      payoffTiming: incoming.payoffTiming ?? existing.payoffTiming,
      expectedPayoff,
      notes,
    }),
    notes,
  };
}

function mergeHookStatus(
  existing: HookRecord["status"],
  incoming: HookRecord["status"],
  progressed: boolean,
): HookRecord["status"] {
  if (existing === "resolved" || incoming === "resolved") return "resolved";
  if (progressed || existing === "progressing" || incoming === "progressing") return "progressing";
  return existing;
}

function preferRicherText(primary: string, fallback: string): string {
  const left = primary.trim();
  const right = fallback.trim();

  if (!left) return right;
  if (!right) return left;
  if (left === right) return left;
  return right.length > left.length ? right : left;
}

function applyCurrentStatePatch(
  currentState: CurrentStateState,
  language: "zh" | "en",
  delta: RuntimeStateDelta,
): CurrentStateState {
  if (!delta.currentStatePatch) {
    return {
      chapter: delta.chapter,
      facts: [...currentState.facts],
    };
  }

  const nextFacts = [...currentState.facts];
  const labels = language === "en"
    ? {
      currentLocation: ["Current Location", "当前位置"],
      protagonistState: ["Protagonist State", "主角状态"],
      currentGoal: ["Current Goal", "当前目标"],
      currentConstraint: ["Current Constraint", "当前限制"],
      currentAlliances: ["Current Alliances", "Current Relationships", "当前敌我"],
      currentConflict: ["Current Conflict", "当前冲突"],
    }
    : {
      currentLocation: ["当前位置", "Current Location"],
      protagonistState: ["主角状态", "Protagonist State"],
      currentGoal: ["当前目标", "Current Goal"],
      currentConstraint: ["当前限制", "Current Constraint"],
      currentAlliances: ["当前敌我", "Current Alliances", "Current Relationships"],
      currentConflict: ["当前冲突", "Current Conflict"],
    };

  for (const [patchKey, aliases] of Object.entries(labels) as Array<[
    keyof typeof labels,
    string[],
  ]>) {
    const value = delta.currentStatePatch[patchKey];
    if (value === undefined) continue;

    for (let index = nextFacts.length - 1; index >= 0; index -= 1) {
      const predicate = nextFacts[index]?.predicate ?? "";
      if (aliases.some((alias) => alias.toLowerCase() === predicate.toLowerCase())) {
        nextFacts.splice(index, 1);
      }
    }

    nextFacts.push({
      subject: "protagonist",
      predicate: aliases[0]!,
      object: value,
      validFromChapter: delta.chapter,
      validUntilChapter: null,
      sourceChapter: delta.chapter,
    });
  }

  return {
    chapter: delta.chapter,
    facts: nextFacts.sort((left, right) => (
      left.predicate.localeCompare(right.predicate)
      || left.object.localeCompare(right.object)
    )),
  };
}

function applySummaryDelta(
  state: ChapterSummariesState,
  delta: RuntimeStateDelta,
  allowReapply = false,
): ChapterSummariesState {
  if (!delta.chapterSummary) {
    return {
      rows: [...state.rows].sort((left, right) => left.chapter - right.chapter),
    };
  }

  return {
    rows: [
      ...(allowReapply ? state.rows.filter((row) => row.chapter !== delta.chapterSummary!.chapter) : state.rows),
      delta.chapterSummary,
    ].sort((left, right) => left.chapter - right.chapter),
  };
}
