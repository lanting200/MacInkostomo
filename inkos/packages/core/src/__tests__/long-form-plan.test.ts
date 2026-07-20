import { afterEach, describe, expect, it } from "vitest";
import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { RuntimeStateSnapshot } from "../state/state-reducer.js";
import { StateManager } from "../state/manager.js";
import {
  adaptPublisherLongFormPlan,
  buildCanonCheckpoint,
  buildLongFormChapterContext,
  buildLongFormLengthSpec,
  createPublisherLongFormPlan,
  createInitialLongFormState,
  fingerprintLongFormPlan,
  hasCompleteChapterRange,
  loadLongFormContinuityState,
  loadLongFormPlan,
  persistCanonCheckpoint,
  persistLongFormContinuityState,
  reconcileLongFormProgress,
  seedPublisherLongFormPlanFromFoundation,
  validateAndApplyLongFormChapter,
} from "../utils/long-form-plan.js";

const roots: string[] = [];

afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

function publisherPlan(params: {
  bookId?: string;
  targetChapters?: number;
  chapterWords?: number;
  volumeCount?: number;
  tolerance?: number;
  continuity?: Record<string, unknown>;
} = {}): Record<string, unknown> {
  const bookId = params.bookId ?? "publisher-fixture";
  const targetChapters = params.targetChapters ?? 6;
  const chapterWords = params.chapterWords ?? 1_000;
  const volumeCount = params.volumeCount ?? 2;
  const tolerance = params.tolerance ?? 15;
  const minWords = Math.max(1, Math.round(chapterWords * (1 - tolerance / 100)));
  const maxWords = Math.round(chapterWords * (1 + tolerance / 100));
  const chapterCounts = distribute(targetChapters, volumeCount);
  const chapters: Array<Record<string, number>> = [];
  const volumes: Array<Record<string, number>> = [];
  let chapterNumber = 1;
  for (let volumeIndex = 0; volumeIndex < chapterCounts.length; volumeIndex += 1) {
    const count = chapterCounts[volumeIndex]!;
    const startChapter = chapterNumber;
    for (let offset = 0; offset < count; offset += 1) {
      chapters.push({
        number: chapterNumber,
        volumeNumber: volumeIndex + 1,
        targetWords: chapterWords,
        minWords,
        maxWords,
      });
      chapterNumber += 1;
    }
    volumes.push({
      number: volumeIndex + 1,
      startChapter,
      endChapter: chapterNumber - 1,
      chapterCount: count,
      targetWords: count * chapterWords,
    });
  }
  return {
    version: 1,
    revision: 3,
    bookId,
    constraints: {
      targetTotalWords: targetChapters * chapterWords,
      volumeCount,
      targetChapterWords: chapterWords,
      chapterWordTolerance: tolerance,
      specialConstraints: ["Keep point of view stable."],
    },
    plan: {
      targetChapters,
      chapterWordRange: { min: minWords, max: maxWords },
      volumes,
      chapters,
    },
    source: "updated",
    createdAt: "2026-07-20T00:00:00.000Z",
    updatedAt: "2026-07-20T01:00:00.000Z",
    ...(params.continuity ? { continuity: params.continuity } : {}),
  };
}

function distribute(total: number, count: number): number[] {
  const base = Math.floor(total / count);
  const remainder = total % count;
  return Array.from({ length: count }, (_, index) => base + (index < remainder ? 1 : 0));
}

async function tempBook(bookId = "publisher-fixture"): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "inkos-long-form-"));
  roots.push(root);
  const bookDir = join(root, bookId);
  await mkdir(join(bookDir, "story", "state"), { recursive: true });
  return bookDir;
}

function extensionFixture(): Record<string, unknown> {
  return {
    immutableCanon: [{ id: "sky-color", category: "world", statement: "The sky is blue.", value: "blue" }],
    worldRules: [{ id: "magic-cost", statement: "Magic always consumes memory.", immutable: true }],
    entities: [{
      id: "seal",
      name: "Royal seal",
      type: "object",
      owner: "ROLE_A",
      immutableOwner: true,
      immutableAttributes: ["material"],
      attributes: { material: "jade" },
    }],
    knowledgeBoundaries: [{
      factId: "hidden-heir",
      statement: "ROLE_A is the hidden heir.",
      allowedKnowers: ["ROLE_A"],
      forbiddenKnowers: ["ROLE_B"],
      availableFromChapter: 3,
    }],
    timeline: [{
      id: "coronation",
      order: 1,
      label: "The coronation occurs.",
      earliestChapter: 3,
      latestChapter: 4,
      immutable: true,
    }],
    hooks: [{ hookId: "missing-crown", description: "Find the crown.", openFromChapter: 1, resolveByChapter: 2 }],
  };
}

describe("Publisher long-form plan adapter", () => {
  it("builds an exact strict plan for direct embedded-core creation", () => {
    const value = createPublisherLongFormPlan({
      bookId: "three-million-book",
      targetTotalWords: 3_000_000,
      targetChapterWords: 3_000,
      volumeCount: 20,
      chapterWordTolerance: 15,
      specialConstraints: ["Keep the point of view stable."],
      createdAt: "2026-07-20T00:00:00.000Z",
      updatedAt: "2026-07-20T00:00:00.000Z",
    });
    const plan = adaptPublisherLongFormPlan(value);

    expect(plan.targetChapters).toBe(1_000);
    expect(plan.volumes).toHaveLength(20);
    expect(plan.chapters.reduce((sum, chapter) => sum + chapter.targetWords, 0)).toBe(3_000_000);
    expect(plan.policy.requireConsistencyDelta).toBe(true);
  });

  it("seeds explicit roles, rule bullets, and hook rows without guessing prose", () => {
    const value = createPublisherLongFormPlan({
      bookId: "seed-book",
      targetTotalWords: 10_000,
      targetChapterWords: 1_000,
      volumeCount: 2,
      createdAt: "2026-07-20T00:00:00.000Z",
      updatedAt: "2026-07-20T00:00:00.000Z",
    });
    const seeded = seedPublisherLongFormPlanFromFoundation(value, {
      roles: [{
        name: "Lin Yue",
        content: "## Current_State\nWaiting at the harbor gate.\n\n## Inner_Driver\nFind the mentor.",
      }],
      bookRules: "# Rules\n- The seal cannot be forged.\n- <placeholder rule>",
      pendingHooks: [
        "| hook_id | start_chapter | type | status | last_advanced_chapter | expected_payoff | payoff_timing | notes |",
        "| --- | --- | --- | --- | --- | --- | --- | --- |",
        "| H001 | 0 | identity | deferred | 0 | Reveal the mentor debt | slow-burn | The torn seal |",
      ].join("\n"),
    });
    const plan = adaptPublisherLongFormPlan(seeded);

    expect(plan.entities).toEqual(expect.arrayContaining([
      expect.objectContaining({
        name: "Lin Yue",
        attributes: { initialState: "Waiting at the harbor gate." },
      }),
    ]));
    expect(plan.worldRules).toEqual([
      expect.objectContaining({ statement: "The seal cannot be forged.", immutable: true }),
    ]);
    expect(plan.hooks).toEqual([
      expect.objectContaining({
        hookId: "H001",
        description: "Reveal the mentor debt",
        openFromChapter: 1,
      }),
    ]);
  });

  it("allocates collision-free IDs for existing seed prefixes and truncated hooks", () => {
    const firstLongHook = `HOOK-${"x".repeat(170)}-one`;
    const secondLongHook = `HOOK-${"x".repeat(170)}-two`;
    const value = createPublisherLongFormPlan({
      bookId: "collision-book",
      targetTotalWords: 10_000,
      targetChapterWords: 1_000,
      volumeCount: 2,
      createdAt: "2026-07-20T00:00:00.000Z",
      updatedAt: "2026-07-20T00:00:00.000Z",
    });
    const withExisting = {
      ...value,
      continuity: {
        ...(value.continuity as Record<string, unknown>),
        entities: [{
          id: "foundation-character-2",
          name: "Existing",
          type: "character" as const,
          attributes: {},
          immutableOwner: false,
          immutableLocation: false,
          immutableAttributes: [],
        }],
        worldRules: [{ id: "foundation-rule-2", statement: "Existing rule.", immutable: true }],
      },
    };
    const seeded = seedPublisherLongFormPlanFromFoundation(withExisting, {
      roles: [{ name: "New Role" }],
      bookRules: "- New rule.",
      pendingHooks: [
        "| hook_id | start_chapter | type | status | last_advanced_chapter | expected_payoff | payoff_timing | notes |",
        "| --- | --- | --- | --- | --- | --- | --- | --- |",
        `| ${firstLongHook} | 1 | clue | planted | 1 | First payoff | later | first |`,
        `| ${secondLongHook} | 1 | clue | planted | 1 | Second payoff | later | second |`,
      ].join("\n"),
    });
    const plan = adaptPublisherLongFormPlan(seeded);

    expect(new Set(plan.entities.map((entity) => entity.id)).size).toBe(plan.entities.length);
    expect(new Set(plan.worldRules.map((rule) => rule.id)).size).toBe(plan.worldRules.length);
    expect(new Set(plan.hooks.map((hook) => hook.hookId)).size).toBe(plan.hooks.length);
    expect(plan.hooks.every((hook) => hook.hookId.length <= 160)).toBe(true);
  });

  it("reads the canonical root file and preserves integer-percent and absolute ranges", async () => {
    const bookDir = await tempBook();
    await writeFile(join(bookDir, "long-form-plan.json"), JSON.stringify(publisherPlan()), "utf-8");

    const loaded = await loadLongFormPlan(bookDir);
    expect(loaded?.path).toBe(join(bookDir, "long-form-plan.json"));
    expect(loaded?.plan.chapterWordTolerancePercent).toBe(15);
    expect(loaded?.plan.chapterWordRange).toEqual({ min: 850, max: 1150 });
    expect(loaded?.plan.chapters[0]).toMatchObject({ targetWords: 1000, minWords: 850, maxWords: 1150 });
  });

  it("returns null for old books and rejects a malformed existing plan", async () => {
    const missingBook = await tempBook("old-book");
    expect(await loadLongFormPlan(missingBook)).toBeNull();

    const brokenBook = await tempBook("broken-book");
    await writeFile(join(brokenBook, "long-form-plan.json"), "{broken", "utf-8");
    await expect(loadLongFormPlan(brokenBook)).rejects.toThrow(/Invalid long-form plan/);
  });

  it("enforces Publisher input bounds", () => {
    expect(() => adaptPublisherLongFormPlan({
      ...publisherPlan(),
      constraints: { ...(publisherPlan().constraints as object), targetTotalWords: 999 },
    })).toThrow();
    expect(() => adaptPublisherLongFormPlan({
      ...publisherPlan(),
      constraints: { ...(publisherPlan().constraints as object), targetChapterWords: 499 },
    })).toThrow();
    expect(() => adaptPublisherLongFormPlan({
      ...publisherPlan(),
      constraints: { ...(publisherPlan().constraints as object), volumeCount: 101 },
    })).toThrow();
    expect(() => adaptPublisherLongFormPlan({
      ...publisherPlan(),
      constraints: {
        ...(publisherPlan().constraints as object),
        specialConstraints: Array.from({ length: 101 }, (_, index) => `rule-${index}`),
      },
    })).toThrow();
    expect(() => adaptPublisherLongFormPlan({
      ...publisherPlan(),
      constraints: {
        ...(publisherPlan().constraints as object),
        specialConstraints: Array.from({ length: 100 }, () => "x".repeat(201)),
      },
    })).toThrow(/20000/);
    expect(() => adaptPublisherLongFormPlan({
      ...publisherPlan(),
      continuity: {
        knowledgeBoundaries: [{
          factId: "secret",
          statement: "The vault location.",
          allowedKnowers: ["ROLE_A"],
          forbiddenKnowers: ["ROLE_A"],
          availableFromChapter: 1,
        }],
      },
    })).toThrow(/both allowed and forbidden/);
  });

  it("uses a dynamic target inside Publisher hard bounds and rejects an out-of-range target", () => {
    const plan = adaptPublisherLongFormPlan(publisherPlan());
    expect(buildLongFormLengthSpec(plan, 1, "zh", 900)).toEqual({
      target: 900,
      softMin: 850,
      softMax: 1150,
      hardMin: 850,
      hardMax: 1150,
      countingMode: "zh_chars",
      normalizeMode: "none",
    });
    expect(() => buildLongFormLengthSpec(plan, 1, "zh", 849)).toThrow(/outside authoritative range/);
  });

  it("merges Publisher continuity and extensions while defaulting optional canon metadata", () => {
    const raw = publisherPlan();
    raw.continuity = { immutableCanon: [{ id: "hero-name", statement: "The hero name stays fixed." }] };
    raw.extensions = { continuity: { policy: { checkpointAtVolumeEnd: false } } };
    const plan = adaptPublisherLongFormPlan(raw);
    expect(plan.immutableCanon[0]).toMatchObject({ id: "hero-name", category: "other" });
    expect(plan.policy.checkpointAtVolumeEnd).toBe(false);
  });
});

describe("long-form context and validation", () => {
  it("injects progress, volume budget, canon, hooks, and knowledge under a fixed cap", () => {
    const largeCanon = Array.from({ length: 80 }, (_, index) => ({
      id: `canon-${index}`,
      category: "world",
      statement: `Rule ${index} ${"x".repeat(300)}`,
    }));
    const plan = adaptPublisherLongFormPlan(publisherPlan({
      continuity: { ...extensionFixture(), immutableCanon: largeCanon },
    }));
    const fingerprint = fingerprintLongFormPlan(plan);
    const state = reconcileLongFormProgress(plan, createInitialLongFormState(fingerprint), [
      { number: 1, wordCount: 990 },
    ]);
    const context = buildLongFormChapterContext({
      plan,
      state,
      chapterNumber: 2,
      hooks: [{ hookId: "missing-crown", status: "open", lastAdvancedChapter: 1, expectedPayoff: "Find it" }],
      facts: [{ subject: "ROLE_A", predicate: "location", object: "palace", sourceChapter: 1 }],
      maxChars: 2_000,
    });

    expect(context.length).toBeLessThanOrEqual(2_000);
    expect(context).toContain("chapter 2/6");
    expect(context).toContain("Current volume: 1");
    expect(context).toContain("missing-crown");
    expect(context).toContain("Character knowledge boundaries");
  });

  it("keeps protected constraints and continuity identifiers ahead of truncation", () => {
    const plan = adaptPublisherLongFormPlan(publisherPlan({
      continuity: {
        ...extensionFixture(),
        entities: Array.from({ length: 200 }, (_, index) => ({
          id: "entity-" + index,
          name: "Entity " + index,
          type: "object",
          attributes: { detail: "x".repeat(300) },
        })),
      },
    }));
    const context = buildLongFormChapterContext({
      plan,
      state: createInitialLongFormState(fingerprintLongFormPlan(plan)),
      chapterNumber: 2,
      maxChars: 2_000,
    });
    expect(context).toContain("Special constraints (protected)");
    expect(context).toContain("Keep point of view stable.");
    expect(context).toContain("Planned timeline milestones");
    expect(context.length).toBeLessThanOrEqual(2_000);
  });

  it("detects length, timeline, ownership, knowledge, world-rule, hook, and canon conflicts", () => {
    const plan = adaptPublisherLongFormPlan(publisherPlan({ continuity: extensionFixture() }));
    const fingerprint = fingerprintLongFormPlan(plan);
    const state = reconcileLongFormProgress(plan, createInitialLongFormState(fingerprint), [
      { number: 1, wordCount: 1_000 },
    ]);
    const result = validateAndApplyLongFormChapter({
      plan,
      fingerprint,
      state,
      chapterNumber: 2,
      wordCount: 700,
      runtimeDelta: {
        chapter: 2,
        hookOps: { upsert: [], mention: [], resolve: [], defer: [] },
        newHookCandidates: [],
        subplotOps: [],
        emotionalArcOps: [],
        characterMatrixOps: [],
        notes: [],
        longFormConsistency: {
          timelineEvents: [{ eventId: "coronation", status: "occurred", detail: "too early" }],
          entityOps: [{ entityId: "seal", owner: "ROLE_B", attributes: {} }],
          knowledgeClaims: [{ characterId: "ROLE_B", factId: "hidden-heir", action: "learns" }],
          worldRuleAssertions: [{ ruleId: "magic-cost", status: "violated", detail: "free spell" }],
          settingDeltas: [{ canonId: "sky-color", path: "sky", nextValue: "red", introduced: false }],
        },
      },
    });
    const codes = result.issues.map((issue) => issue.code);
    expect(codes).toEqual(expect.arrayContaining([
      "chapter-length-drift",
      "timeline-boundary-conflict",
      "entity-owner-conflict",
      "knowledge-too-early",
      "knowledge-forbidden",
      "knowledge-not-allowed",
      "world-rule-conflict",
      "immutable-canon-conflict",
      "hook-overdue",
    ]));
    expect(result.issues.every((issue) => issue.severity === "critical")).toBe(true);
  });

  it("rejects stale and unexplained setting mutations", () => {
    const plan = adaptPublisherLongFormPlan(publisherPlan());
    const fingerprint = fingerprintLongFormPlan(plan);
    const state = {
      ...reconcileLongFormProgress(plan, createInitialLongFormState(fingerprint), [{ number: 1, wordCount: 1_000 }]),
      settingValues: { weather: "rain" },
    };
    const result = validateAndApplyLongFormChapter({
      plan,
      fingerprint,
      state,
      chapterNumber: 2,
      wordCount: 1_000,
      consistencyDelta: {
        timelineEvents: [],
        entityOps: [],
        knowledgeClaims: [],
        worldRuleAssertions: [],
        settingDeltas: [{ path: "weather", previousValue: "sun", nextValue: "snow", introduced: false }],
      },
    });
    expect(result.issues.map((issue) => issue.code)).toEqual(expect.arrayContaining([
      "setting-stale-write",
      "setting-random-delta",
    ]));
  });

  it("rejects aggregate-state reapply so a removed setting cannot survive revision", () => {
    const plan = adaptPublisherLongFormPlan(publisherPlan());
    const fingerprint = fingerprintLongFormPlan(plan);
    const first = validateAndApplyLongFormChapter({
      plan,
      fingerprint,
      state: createInitialLongFormState(fingerprint),
      chapterNumber: 1,
      wordCount: 1_000,
      consistencyDelta: {
        timelineEvents: [],
        entityOps: [],
        knowledgeClaims: [],
        worldRuleAssertions: [],
        settingDeltas: [{ path: "world.seal.color", nextValue: "B", introduced: true }],
      },
    });
    expect(first.nextState.settingValues["world.seal.color"]).toBe("B");

    const unsafe = validateAndApplyLongFormChapter({
      plan,
      fingerprint,
      state: first.nextState,
      chapterNumber: 1,
      wordCount: 1_000,
      consistencyDelta: {
        timelineEvents: [],
        entityOps: [],
        knowledgeClaims: [],
        worldRuleAssertions: [],
        settingDeltas: [],
      },
      allowReapply: true,
    });

    expect(unsafe.issues).toContainEqual(expect.objectContaining({
      severity: "critical",
      code: "replay-baseline-required",
    }));
  });

  it("requires every chapter in a volume before treating the range as complete", () => {
    expect(hasCompleteChapterRange({ startCh: 1, endCh: 3 }, [1, 3])).toBe(false);
    expect(hasCompleteChapterRange({ startCh: 1, endCh: 3 }, [3, 1, 2])).toBe(true);
  });
});

describe("long-form atomic persistence and scale", () => {
  it("writes state atomically and creates an idempotent volume checkpoint", async () => {
    const bookDir = await tempBook();
    const plan = adaptPublisherLongFormPlan(publisherPlan());
    const fingerprint = fingerprintLongFormPlan(plan);
    const state = reconcileLongFormProgress(plan, createInitialLongFormState(fingerprint), [
      { number: 1, wordCount: 1_000 },
      { number: 2, wordCount: 1_000 },
      { number: 3, wordCount: 1_000 },
    ]);
    await persistLongFormContinuityState(bookDir, state);
    const loadedState = await loadLongFormContinuityState(bookDir, fingerprint);
    expect(loadedState.totalWordCount).toBe(3_000);

    const runtimeSnapshot: RuntimeStateSnapshot = {
      manifest: { schemaVersion: 2, language: "en", lastAppliedChapter: 3, projectionVersion: 1, migrationWarnings: [] },
      currentState: { chapter: 3, facts: [] },
      hooks: { hooks: [] },
      chapterSummaries: { rows: [] },
      objects: { objects: [] },
    };
    const first = buildCanonCheckpoint({
      plan,
      fingerprint,
      state,
      volume: plan.volumes[0]!,
      runtimeSnapshot,
      generatedAt: "2026-07-20T02:00:00.000Z",
    });
    const path = await persistCanonCheckpoint(bookDir, first);
    const second = buildCanonCheckpoint({
      plan,
      fingerprint,
      state,
      volume: plan.volumes[0]!,
      runtimeSnapshot,
      generatedAt: "2026-07-20T03:00:00.000Z",
    });
    await persistCanonCheckpoint(bookDir, second);
    const persisted = JSON.parse(await readFile(path, "utf-8")) as { generatedAt: string };
    expect(persisted.generatedAt).toBe("2026-07-20T02:00:00.000Z");
    expect((await readdir(join(bookDir, "story", "state"))).some((name) => name.endsWith(".tmp"))).toBe(false);
  });

  it("rebases compatible historical state but rejects a conflicting plan fingerprint", async () => {
    const bookDir = await tempBook("fingerprint-rebase");
    const plan = adaptPublisherLongFormPlan(publisherPlan({
      bookId: "fingerprint-rebase",
      continuity: extensionFixture(),
    }));
    const oldFingerprint = fingerprintLongFormPlan(plan);
    const state = {
      ...reconcileLongFormProgress(plan, createInitialLongFormState(oldFingerprint), [
        { number: 1, wordCount: 1_000 },
        { number: 2, wordCount: 1_000 },
        { number: 3, wordCount: 1_000 },
      ]),
      settingValues: { weather: "rain" },
      timelineEvents: {
        coronation: { chapter: 3, status: "occurred" as const, detail: "The crown was placed." },
      },
    };
    await persistLongFormContinuityState(bookDir, state);

    const compatiblePlan = { ...plan, revision: plan.revision + 1 };
    const compatibleFingerprint = fingerprintLongFormPlan(compatiblePlan);
    const rebased = await loadLongFormContinuityState(
      bookDir,
      compatibleFingerprint,
      compatiblePlan,
    );
    expect(rebased.planFingerprint).toBe(compatibleFingerprint);
    expect(rebased.settingValues.weather).toBe("rain");

    const conflictingPlan = { ...compatiblePlan, revision: compatiblePlan.revision + 1, timeline: [] };
    const conflictingFingerprint = fingerprintLongFormPlan(conflictingPlan);
    await expect(loadLongFormContinuityState(
      bookDir,
      conflictingFingerprint,
      conflictingPlan,
    )).rejects.toThrow(/replay-baseline-required.*coronation/);
  });

  it("keeps long-form state inside the chapter snapshot for rollback/restore", async () => {
    const root = await mkdtemp(join(tmpdir(), "inkos-long-form-snapshot-"));
    roots.push(root);
    const manager = new StateManager(root);
    const bookId = "snapshot-plan-book";
    await manager.saveBookConfig(bookId, {
      id: bookId,
      title: "Snapshot Plan Book",
      platform: "tomato",
      genre: "other",
      status: "active",
      targetChapters: 2,
      chapterWordCount: 500,
      createdAt: "2026-07-20T00:00:00.000Z",
      updatedAt: "2026-07-20T00:00:00.000Z",
    });
    const bookDir = manager.bookDir(bookId);
    await mkdir(join(bookDir, "story"), { recursive: true });
    const plan = adaptPublisherLongFormPlan(publisherPlan({ bookId }));
    const state = reconcileLongFormProgress(plan, createInitialLongFormState(fingerprintLongFormPlan(plan)), [
      { number: 1, wordCount: 1_000 },
    ]);
    await persistLongFormContinuityState(bookDir, state);
    await manager.snapshotState(bookId, 1);
    const snapshot = JSON.parse(await readFile(
      join(bookDir, "story", "snapshots", "1", "state", "long_form_state.json"),
      "utf-8",
    )) as { lastAppliedChapter: number };
    expect(snapshot.lastAppliedChapter).toBe(1);
  });

  it("simulates 3,000,000 words without LLM calls or growing chapter context", () => {
    const raw = publisherPlan({ targetChapters: 1_000, chapterWords: 3_000, volumeCount: 10 });
    const plan = adaptPublisherLongFormPlan(raw);
    const fingerprint = fingerprintLongFormPlan(plan);
    let state = createInitialLongFormState(fingerprint);
    let maxContext = 0;
    let minContext = Number.POSITIVE_INFINITY;
    let llmCalls = 0;

    for (let chapter = 1; chapter <= 1_000; chapter += 1) {
      const context = buildLongFormChapterContext({
        plan,
        state,
        chapterNumber: chapter,
        hooks: [],
        facts: [],
        maxChars: 2_000,
      });
      maxContext = Math.max(maxContext, context.length);
      minContext = Math.min(minContext, context.length);
      const result = validateAndApplyLongFormChapter({
        plan,
        fingerprint,
        state,
        chapterNumber: chapter,
        wordCount: 3_000,
      });
      expect(result.issues).toEqual([]);
      state = result.nextState;
    }

    expect(state.totalWordCount).toBe(3_000_000);
    expect(state.lastAppliedChapter).toBe(1_000);
    expect(maxContext).toBeLessThanOrEqual(2_000);
    expect(maxContext - minContext).toBeLessThan(400);
    expect(llmCalls).toBe(0);
  });
});
