import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PipelineRunner } from "../pipeline/runner.js";
import { StateManager } from "../state/manager.js";
import { ContinuityAuditor } from "../agents/continuity.js";
import { ReviserAgent } from "../agents/reviser.js";
import { WriterAgent } from "../agents/writer.js";
import { StateValidatorAgent } from "../agents/state-validator.js";
import {
  createInitialLongFormState,
  loadLongFormPlan,
  persistLongFormContinuityState,
} from "../utils/long-form-plan.js";
import {
  buildRuntimeStateArtifacts,
  saveRuntimeStateSnapshot,
} from "../state/runtime-state-store.js";
import {
  renderChapterSummariesProjection,
  renderCurrentStateProjection,
  renderHooksProjection,
  renderObjectLedgerProjection,
} from "../state/state-projections.js";
import type { RuntimeStateDelta } from "../models/runtime-state.js";

const roots: string[] = [];

afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

function plan(bookId: string): Record<string, unknown> {
  return {
    version: 1,
    revision: 1,
    bookId,
    constraints: {
      targetTotalWords: 1_000,
      volumeCount: 1,
      targetChapterWords: 500,
      chapterWordTolerance: 50,
      specialConstraints: ["Keep continuity strict."],
    },
    plan: {
      targetChapters: 2,
      chapterWordRange: { min: 250, max: 750 },
      volumes: [{ number: 1, startChapter: 1, endChapter: 2, chapterCount: 2, targetWords: 1_000 }],
      chapters: [1, 2].map((number) => ({
        number,
        volumeNumber: 1,
        targetWords: 500,
        minWords: 250,
        maxWords: 750,
      })),
    },
    continuity: {
      entities: [{
        id: "seal",
        name: "Royal seal",
        type: "object",
        owner: "ROLE_A",
        immutableOwner: true,
      }],
    },
    source: "created",
    createdAt: "2026-07-20T00:00:00.000Z",
    updatedAt: "2026-07-20T00:00:00.000Z",
  };
}

describe("long-form revision settlement gate", () => {
  it("re-settles revised prose and keeps old truth when an entity conflict is critical", async () => {
    const root = await mkdtemp(join(tmpdir(), "inkos-long-form-revision-"));
    roots.push(root);
    const state = new StateManager(root);
    const bookId = "revision-plan-book";
    const bookDir = state.bookDir(bookId);
    const storyDir = join(bookDir, "story");
    const chaptersDir = join(bookDir, "chapters");
    await mkdir(storyDir, { recursive: true });
    await mkdir(chaptersDir, { recursive: true });
    await state.saveBookConfig(bookId, {
      id: bookId,
      title: "Revision Plan Book",
      platform: "tomato",
      genre: "xuanhuan",
      status: "active",
      targetChapters: 2,
      chapterWordCount: 500,
      createdAt: "2026-07-20T00:00:00.000Z",
      updatedAt: "2026-07-20T00:00:00.000Z",
    });
    await writeFile(join(bookDir, "long-form-plan.json"), JSON.stringify(plan(bookId)), "utf-8");
    const originalBody = "原始正文".repeat(130);
    const revisedBody = "修订正文".repeat(130);
    const oldState = "OLD_STATE";
    await writeFile(join(chaptersDir, "0001_Chapter.md"), `# 第1章 Chapter\n\n${originalBody}`, "utf-8");
    await writeFile(join(storyDir, "current_state.md"), oldState, "utf-8");
    await writeFile(join(storyDir, "pending_hooks.md"), "# Pending Hooks\n", "utf-8");
    await state.saveChapterIndex(bookId, [{
      number: 1,
      title: "Chapter",
      status: "audit-failed",
      wordCount: originalBody.length,
      createdAt: "2026-07-20T00:00:00.000Z",
      updatedAt: "2026-07-20T00:00:00.000Z",
      auditIssues: ["[warning] needs revision"],
      lengthWarnings: [],
    }]);

    vi.spyOn(ContinuityAuditor.prototype, "auditChapter")
      .mockResolvedValueOnce({ passed: false, issues: [{ severity: "warning", category: "pacing", description: "tighten", suggestion: "tighten" }], summary: "needs revision" })
      .mockResolvedValueOnce({ passed: true, issues: [], summary: "clean" });
    vi.spyOn(ReviserAgent.prototype, "reviseChapter").mockResolvedValue({
      revisedContent: revisedBody,
      wordCount: revisedBody.length,
      fixedIssues: ["tightened"],
      updatedState: "SHOULD_NOT_BE_SAVED",
      updatedLedger: "",
      updatedHooks: "# Pending Hooks\n",
    });
    const settle = vi.spyOn(WriterAgent.prototype, "settleChapterState").mockResolvedValue({
      chapterNumber: 1,
      title: "Chapter",
      content: revisedBody,
      wordCount: revisedBody.length,
      preWriteCheck: "",
      postSettlement: "",
      runtimeStateDelta: {
        chapter: 1,
        hookOps: { upsert: [], mention: [], resolve: [], defer: [] },
        newHookCandidates: [],
        subplotOps: [],
        emotionalArcOps: [],
        characterMatrixOps: [],
        longFormConsistency: {
          timelineEvents: [],
          entityOps: [{ entityId: "seal", owner: "ROLE_B", attributes: {} }],
          knowledgeClaims: [],
          worldRuleAssertions: [],
          settingDeltas: [],
        },
        notes: [],
      },
      updatedState: "SHOULD_NOT_BE_SAVED",
      updatedLedger: "",
      updatedHooks: "# Pending Hooks\n",
      chapterSummary: "",
      updatedSubplots: "",
      updatedEmotionalArcs: "",
      updatedCharacterMatrix: "",
      postWriteErrors: [],
      postWriteWarnings: [],
    });
    vi.spyOn(StateValidatorAgent.prototype, "validate").mockResolvedValue({ passed: true, warnings: [] });

    const runner = new PipelineRunner({
      client: {
        provider: "openai",
        apiFormat: "chat",
        stream: false,
        defaults: { temperature: 0.7, maxTokens: 4096, thinkingBudget: 0 },
      } as ConstructorParameters<typeof PipelineRunner>[0]["client"],
      model: "test-model",
      projectRoot: root,
      inputGovernanceMode: "legacy",
    });

    const result = await runner.reviseDraft(bookId, 1);
    expect(result.status).toBe("state-degraded");
    expect(result.applied).toBe(true);
    expect(settle).toHaveBeenCalledWith(expect.objectContaining({ allowReapply: false, chapterNumber: 1 }));
    expect(await readFile(join(storyDir, "current_state.md"), "utf-8")).toBe(oldState);
    expect(await readFile(join(chaptersDir, "0001_Chapter.md"), "utf-8")).toContain(revisedBody);
  });

  it("replays chapter N from snapshot N-1 and removes superseded aggregate settings", async () => {
    const root = await mkdtemp(join(tmpdir(), "inkos-long-form-replay-"));
    roots.push(root);
    const state = new StateManager(root);
    const bookId = "revision-replay-book";
    const bookDir = state.bookDir(bookId);
    const storyDir = join(bookDir, "story");
    const chaptersDir = join(bookDir, "chapters");
    await mkdir(storyDir, { recursive: true });
    await mkdir(chaptersDir, { recursive: true });
    await state.saveBookConfig(bookId, {
      id: bookId,
      title: "Revision Replay Book",
      platform: "tomato",
      genre: "xuanhuan",
      status: "active",
      targetChapters: 2,
      chapterWordCount: 500,
      createdAt: "2026-07-20T00:00:00.000Z",
      updatedAt: "2026-07-20T00:00:00.000Z",
    });
    await writeFile(join(bookDir, "long-form-plan.json"), JSON.stringify(plan(bookId)), "utf-8");

    const loaded = await loadLongFormPlan(bookDir);
    if (!loaded) throw new Error("expected long-form plan");
    const baseLongFormState = {
      ...createInitialLongFormState(loaded.fingerprint),
      firstObservedChapter: 1,
      lastAppliedChapter: 1,
      lastAppliedWordCount: 500,
      lastAppliedVolumeNumber: 1,
      totalWordCount: 500,
      volumeWordCounts: { "1": 500 },
      settingValues: { "world.weather": "A" },
    };
    const baseRuntimeSnapshot = {
      manifest: {
        schemaVersion: 2 as const,
        language: "zh" as const,
        lastAppliedChapter: 1,
        projectionVersion: 1,
        migrationWarnings: [],
      },
      currentState: {
        chapter: 1,
        facts: [{
          subject: "world.weather",
          predicate: "value",
          object: "A",
          validFromChapter: 1,
          validUntilChapter: null,
          sourceChapter: 1,
        }],
      },
      hooks: { hooks: [] },
      chapterSummaries: { rows: [] },
      objects: { objects: [] },
    };
    await persistLongFormContinuityState(bookDir, baseLongFormState);
    await saveRuntimeStateSnapshot(bookDir, baseRuntimeSnapshot);
    await writeFile(join(storyDir, "current_state.md"), "BASE_STATE_A", "utf-8");
    await writeFile(join(storyDir, "pending_hooks.md"), "# Pending Hooks\n", "utf-8");
    await state.snapshotState(bookId, 1);

    await persistLongFormContinuityState(bookDir, {
      ...baseLongFormState,
      lastAppliedChapter: 2,
      totalWordCount: 1_000,
      volumeWordCounts: { "1": 1_000 },
      settingValues: { "world.weather": "B" },
    });
    await saveRuntimeStateSnapshot(bookDir, {
      ...baseRuntimeSnapshot,
      manifest: { ...baseRuntimeSnapshot.manifest, lastAppliedChapter: 2 },
      currentState: {
        chapter: 2,
        facts: [{
          subject: "world.weather",
          predicate: "value",
          object: "B",
          validFromChapter: 2,
          validUntilChapter: null,
          sourceChapter: 2,
        }],
      },
    });

    const chapterOneBody = "第一章正文".repeat(100);
    const originalBody = "第二章原稿".repeat(100);
    const revisedBody = "第二章修订".repeat(100);
    await writeFile(join(chaptersDir, "0001_First.md"), `# 第1章 First\n\n${chapterOneBody}`, "utf-8");
    await writeFile(join(chaptersDir, "0002_Second.md"), `# 第2章 Second\n\n${originalBody}`, "utf-8");
    await state.saveChapterIndex(bookId, [
      {
        number: 1,
        title: "First",
        status: "approved",
        wordCount: 500,
        createdAt: "2026-07-20T00:00:00.000Z",
        updatedAt: "2026-07-20T00:00:00.000Z",
        auditIssues: [],
        lengthWarnings: [],
      },
      {
        number: 2,
        title: "Second",
        status: "audit-failed",
        wordCount: originalBody.length,
        createdAt: "2026-07-20T00:00:00.000Z",
        updatedAt: "2026-07-20T00:00:00.000Z",
        auditIssues: ["[warning] needs revision"],
        lengthWarnings: [],
      },
    ]);

    vi.spyOn(ContinuityAuditor.prototype, "auditChapter")
      .mockResolvedValueOnce({
        passed: false,
        issues: [{ severity: "warning", category: "pacing", description: "tighten", suggestion: "tighten" }],
        summary: "needs revision",
      })
      .mockResolvedValueOnce({ passed: true, issues: [], summary: "clean" });
    vi.spyOn(ReviserAgent.prototype, "reviseChapter").mockResolvedValue({
      revisedContent: revisedBody,
      wordCount: revisedBody.length,
      fixedIssues: ["tightened"],
      updatedState: "(状态卡未更新)",
      updatedLedger: "(账本未更新)",
      updatedHooks: "(伏笔池未更新)",
    });
    const settle = vi.spyOn(WriterAgent.prototype, "settleChapterState").mockImplementation(async (input) => {
      if (!input.runtimeStateBaseSnapshot) throw new Error("expected replay runtime baseline");
      const runtimeStateDelta = {
        chapter: 2,
        hookOps: { upsert: [], mention: [], resolve: [], defer: [] },
        newHookCandidates: [],
        subplotOps: [],
        emotionalArcOps: [],
        characterMatrixOps: [],
        longFormConsistency: {
          timelineEvents: [],
          entityOps: [],
          knowledgeClaims: [],
          worldRuleAssertions: [],
          settingDeltas: [],
        },
        notes: [],
      };
      const artifacts = await buildRuntimeStateArtifacts({
        bookDir,
        delta: runtimeStateDelta,
        language: "zh",
        allowReapply: input.allowReapply,
        baseSnapshot: input.runtimeStateBaseSnapshot,
      });
      return {
        chapterNumber: 2,
        title: "Second",
        content: revisedBody,
        wordCount: revisedBody.length,
        preWriteCheck: "",
        postSettlement: "",
        runtimeStateDelta: artifacts.resolvedDelta,
        runtimeStateSnapshot: artifacts.snapshot,
        updatedState: artifacts.currentStateMarkdown,
        updatedLedger: "",
        updatedHooks: artifacts.hooksMarkdown,
        chapterSummary: "",
        updatedChapterSummaries: artifacts.chapterSummariesMarkdown,
        updatedSubplots: "",
        updatedEmotionalArcs: "",
        updatedCharacterMatrix: "",
        postWriteErrors: [],
        postWriteWarnings: [],
      };
    });
    vi.spyOn(StateValidatorAgent.prototype, "validate").mockResolvedValue({ passed: true, warnings: [] });

    const runner = new PipelineRunner({
      client: {
        provider: "openai",
        apiFormat: "chat",
        stream: false,
        defaults: { temperature: 0.7, maxTokens: 4096, thinkingBudget: 0 },
      } as ConstructorParameters<typeof PipelineRunner>[0]["client"],
      model: "test-model",
      projectRoot: root,
      inputGovernanceMode: "legacy",
    });

    const result = await runner.reviseDraft(bookId, 2);
    expect(result.status).toBe("ready-for-review");
    expect(result.applied).toBe(true);
    expect(settle.mock.calls[0]?.[0]).toMatchObject({
      chapterNumber: 2,
      allowReapply: false,
      runtimeStateBaseSnapshot: {
        manifest: { lastAppliedChapter: 1 },
      },
    });

    const persistedLongForm = JSON.parse(
      await readFile(join(storyDir, "state", "long_form_state.json"), "utf-8"),
    ) as { settingValues: Record<string, string> };
    expect(persistedLongForm.settingValues).toEqual({ "world.weather": "A" });

    const persistedRuntime = JSON.parse(
      await readFile(join(storyDir, "state", "current_state.json"), "utf-8"),
    ) as { chapter: number; facts: Array<{ object: string }> };
    expect(persistedRuntime.chapter).toBe(2);
    expect(persistedRuntime.facts.map((fact) => fact.object)).toEqual(["A"]);
  });

  it("rebuilds a legacy revision from snapshot N-1 and drops superseded event, fact, hook, and object state", async () => {
    const root = await mkdtemp(join(tmpdir(), "inkos-legacy-revision-replay-"));
    roots.push(root);
    const state = new StateManager(root);
    const bookId = "legacy-revision-replay-book";
    const bookDir = state.bookDir(bookId);
    const storyDir = join(bookDir, "story");
    const chaptersDir = join(bookDir, "chapters");
    await mkdir(storyDir, { recursive: true });
    await mkdir(chaptersDir, { recursive: true });
    await state.saveBookConfig(bookId, {
      id: bookId,
      title: "Legacy Revision Replay Book",
      platform: "tomato",
      genre: "xuanhuan",
      language: "zh",
      status: "active",
      targetChapters: 2,
      chapterWordCount: 500,
      createdAt: "2026-07-20T00:00:00.000Z",
      updatedAt: "2026-07-20T00:00:00.000Z",
    });

    const baseRuntimeSnapshot = {
      manifest: {
        schemaVersion: 2 as const,
        language: "zh" as const,
        lastAppliedChapter: 1,
        projectionVersion: 1,
        migrationWarnings: [],
      },
      currentState: {
        chapter: 1,
        facts: [{
          subject: "plot",
          predicate: "基础事实",
          object: "BASE_FACT",
          validFromChapter: 1,
          validUntilChapter: null,
          sourceChapter: 1,
        }],
      },
      hooks: {
        hooks: [{
          hookId: "base-hook",
          startChapter: 1,
          type: "mystery",
          status: "open" as const,
          lastAdvancedChapter: 1,
          expectedPayoff: "BASE_PAYOFF",
          notes: "BASE_HOOK",
        }],
      },
      chapterSummaries: {
        rows: [{
          chapter: 1,
          title: "First",
          characters: "ROLE_A",
          events: "BASE_EVENT",
          stateChanges: "BASE_STATE",
          hookActivity: "BASE_HOOK",
          mood: "tense",
          chapterType: "setup",
        }],
      },
      objects: {
        objects: [{
          objectId: "base-object",
          name: "Base Object",
          aliases: [],
          material: "iron",
          inscription: "BASE_MARK",
          appearance: "dark",
          owner: "ROLE_A",
          location: "BASE_ROOM",
          status: "held",
          firstSeenChapter: 1,
          lastSeenChapter: 1,
          linkedHookIds: ["base-hook"],
          notes: "BASE_OBJECT",
        }],
      },
    };
    await saveRuntimeStateSnapshot(bookDir, baseRuntimeSnapshot);
    await Promise.all([
      writeFile(
        join(storyDir, "current_state.md"),
        renderCurrentStateProjection(baseRuntimeSnapshot.currentState, "zh"),
        "utf-8",
      ),
      writeFile(join(storyDir, "particle_ledger.md"), "BASE_LEDGER\n", "utf-8"),
      writeFile(
        join(storyDir, "object_ledger.md"),
        renderObjectLedgerProjection(baseRuntimeSnapshot.objects, "zh"),
        "utf-8",
      ),
      writeFile(
        join(storyDir, "pending_hooks.md"),
        renderHooksProjection(baseRuntimeSnapshot.hooks, "zh"),
        "utf-8",
      ),
      writeFile(
        join(storyDir, "chapter_summaries.md"),
        renderChapterSummariesProjection(baseRuntimeSnapshot.chapterSummaries, "zh"),
        "utf-8",
      ),
      writeFile(join(storyDir, "subplot_board.md"), "BASE_SUBPLOT\n", "utf-8"),
      writeFile(join(storyDir, "emotional_arcs.md"), "BASE_EMOTION\n", "utf-8"),
      writeFile(join(storyDir, "character_matrix.md"), "BASE_MATRIX\n", "utf-8"),
    ]);
    await state.snapshotState(bookId, 1);
    // Exercise the legacy migration path: only Markdown truth remains in N-1.
    await rm(join(storyDir, "snapshots", "1", "state"), { recursive: true, force: true });

    const liveRuntimeSnapshot = {
      ...baseRuntimeSnapshot,
      manifest: { ...baseRuntimeSnapshot.manifest, lastAppliedChapter: 2 },
      currentState: {
        chapter: 2,
        facts: [
          ...baseRuntimeSnapshot.currentState.facts,
          {
            subject: "plot",
            predicate: "旧章事实",
            object: "OLD_FACT",
            validFromChapter: 2,
            validUntilChapter: null,
            sourceChapter: 2,
          },
        ],
      },
      hooks: {
        hooks: [
          ...baseRuntimeSnapshot.hooks.hooks,
          {
            hookId: "old-hook",
            startChapter: 2,
            type: "mystery",
            status: "open" as const,
            lastAdvancedChapter: 2,
            expectedPayoff: "OLD_PAYOFF",
            notes: "OLD_HOOK",
          },
        ],
      },
      chapterSummaries: {
        rows: [
          ...baseRuntimeSnapshot.chapterSummaries.rows,
          {
            chapter: 2,
            title: "Second",
            characters: "ROLE_A",
            events: "OLD_EVENT",
            stateChanges: "OLD_STATE",
            hookActivity: "OLD_HOOK",
            mood: "grim",
            chapterType: "turn",
          },
        ],
      },
      objects: {
        objects: [
          ...baseRuntimeSnapshot.objects.objects,
          {
            objectId: "old-object",
            name: "Old Object",
            aliases: [],
            material: "glass",
            inscription: "OLD_MARK",
            appearance: "bright",
            owner: "ROLE_A",
            location: "OLD_ROOM",
            status: "lost",
            firstSeenChapter: 2,
            lastSeenChapter: 2,
            linkedHookIds: ["old-hook"],
            notes: "OLD_OBJECT",
          },
        ],
      },
    };
    await saveRuntimeStateSnapshot(bookDir, liveRuntimeSnapshot);
    await Promise.all([
      writeFile(
        join(storyDir, "current_state.md"),
        renderCurrentStateProjection(liveRuntimeSnapshot.currentState, "zh"),
        "utf-8",
      ),
      writeFile(join(storyDir, "particle_ledger.md"), "LIVE_LEDGER_WITH_OLD_EVENT\n", "utf-8"),
      writeFile(
        join(storyDir, "object_ledger.md"),
        renderObjectLedgerProjection(liveRuntimeSnapshot.objects, "zh"),
        "utf-8",
      ),
      writeFile(
        join(storyDir, "pending_hooks.md"),
        renderHooksProjection(liveRuntimeSnapshot.hooks, "zh"),
        "utf-8",
      ),
      writeFile(
        join(storyDir, "chapter_summaries.md"),
        renderChapterSummariesProjection(liveRuntimeSnapshot.chapterSummaries, "zh"),
        "utf-8",
      ),
      writeFile(join(storyDir, "subplot_board.md"), "LIVE_SUBPLOT_WITH_OLD_EVENT\n", "utf-8"),
      writeFile(join(storyDir, "emotional_arcs.md"), "LIVE_EMOTION_WITH_OLD_EVENT\n", "utf-8"),
      writeFile(join(storyDir, "character_matrix.md"), "LIVE_MATRIX_WITH_OLD_EVENT\n", "utf-8"),
    ]);

    const firstBody = "第一章正文".repeat(100);
    const originalBody = "第二章旧稿".repeat(100);
    const revisedBody = "第二章新稿".repeat(100);
    await writeFile(join(chaptersDir, "0001_First.md"), `# 第1章 First\n\n${firstBody}`, "utf-8");
    await writeFile(join(chaptersDir, "0002_Second.md"), `# 第2章 Second\n\n${originalBody}`, "utf-8");
    await state.saveChapterIndex(bookId, [
      {
        number: 1,
        title: "First",
        status: "approved",
        wordCount: firstBody.length,
        createdAt: "2026-07-20T00:00:00.000Z",
        updatedAt: "2026-07-20T00:00:00.000Z",
        auditIssues: [],
        lengthWarnings: [],
      },
      {
        number: 2,
        title: "Second",
        status: "audit-failed",
        wordCount: originalBody.length,
        createdAt: "2026-07-20T00:00:00.000Z",
        updatedAt: "2026-07-20T00:00:00.000Z",
        auditIssues: ["[warning] needs revision"],
        lengthWarnings: [],
      },
    ]);

    vi.spyOn(ContinuityAuditor.prototype, "auditChapter")
      .mockResolvedValueOnce({
        passed: false,
        issues: [{ severity: "warning", category: "pacing", description: "tighten", suggestion: "tighten" }],
        summary: "needs revision",
      })
      .mockResolvedValueOnce({ passed: true, issues: [], summary: "clean" });
    vi.spyOn(ReviserAgent.prototype, "reviseChapter").mockResolvedValue({
      revisedContent: revisedBody,
      wordCount: revisedBody.length,
      fixedIssues: ["tightened"],
      updatedState: "(状态卡未更新)",
      updatedLedger: "(账本未更新)",
      updatedHooks: "(伏笔池未更新)",
    });
    const settle = vi.spyOn(WriterAgent.prototype, "settleChapterState").mockImplementation(async (input) => {
      expect(await readdir(join(bookDir, ".inkos-transactions"))).toHaveLength(1);
      expect(input.runtimeStateBaseSnapshot?.manifest.lastAppliedChapter).toBe(1);
      expect(input.runtimeStateBaseSnapshot?.currentState.facts.map((fact) => fact.object)).toEqual(["BASE_FACT"]);
      expect(input.runtimeStateBaseSnapshot?.hooks.hooks.map((hook) => hook.hookId)).toEqual(["base-hook"]);
      expect(input.runtimeStateBaseSnapshot?.objects?.objects.map((object) => object.objectId)).toEqual(["base-object"]);
      expect(input.truthFileBaseSnapshot).toMatchObject({
        ledger: "BASE_LEDGER\n",
        subplotBoard: "BASE_SUBPLOT\n",
        emotionalArcs: "BASE_EMOTION\n",
        characterMatrix: "BASE_MATRIX\n",
      });

      const runtimeStateDelta: RuntimeStateDelta = {
        chapter: 2,
        currentStatePatch: { currentGoal: "REVISED_GOAL" },
        hookOps: {
          upsert: [],
          mention: [],
          resolve: [],
          defer: [],
        },
        newHookCandidates: [],
        chapterSummary: {
          chapter: 2,
          title: "Second",
          characters: "ROLE_A",
          events: "REVISED_EVENT",
          stateChanges: "REVISED_STATE",
          hookActivity: "REVISED_HOOK",
          mood: "focused",
          chapterType: "turn",
        },
        subplotOps: [],
        emotionalArcOps: [],
        characterMatrixOps: [],
        objectOps: {
          upsert: [{
            objectId: "revised-object",
            name: "Revised Object",
            aliases: [],
            material: "wood",
            inscription: "REVISED_MARK",
            appearance: "plain",
            owner: "ROLE_A",
            location: "NEW_ROOM",
            status: "held",
            firstSeenChapter: 2,
            lastSeenChapter: 2,
            linkedHookIds: [],
            notes: "REVISED_OBJECT",
          }],
        },
        notes: [],
      };
      const artifacts = await buildRuntimeStateArtifacts({
        bookDir,
        delta: runtimeStateDelta,
        language: "zh",
        allowReapply: input.allowReapply,
        baseSnapshot: input.runtimeStateBaseSnapshot,
      });
      return {
        chapterNumber: 2,
        title: "Second",
        content: revisedBody,
        wordCount: revisedBody.length,
        preWriteCheck: "",
        postSettlement: "",
        runtimeStateDelta: artifacts.resolvedDelta,
        runtimeStateSnapshot: artifacts.snapshot,
        updatedState: artifacts.currentStateMarkdown,
        updatedLedger: "BASE_LEDGER\nREVISED_LEDGER\n",
        updatedHooks: artifacts.hooksMarkdown,
        chapterSummary: "",
        updatedChapterSummaries: artifacts.chapterSummariesMarkdown,
        updatedSubplots: "BASE_SUBPLOT\nREVISED_SUBPLOT\n",
        updatedEmotionalArcs: "BASE_EMOTION\nREVISED_EMOTION\n",
        updatedCharacterMatrix: "BASE_MATRIX\nREVISED_MATRIX\n",
        postWriteErrors: [],
        postWriteWarnings: [],
      };
    });
    const validate = vi.spyOn(StateValidatorAgent.prototype, "validate")
      .mockResolvedValue({ passed: true, warnings: [] });

    const runner = new PipelineRunner({
      client: {
        provider: "openai",
        apiFormat: "chat",
        stream: false,
        defaults: { temperature: 0.7, maxTokens: 4096, thinkingBudget: 0 },
      } as ConstructorParameters<typeof PipelineRunner>[0]["client"],
      model: "test-model",
      projectRoot: root,
      inputGovernanceMode: "legacy",
    });

    const result = await runner.reviseDraft(bookId, 2);
    expect(result).toMatchObject({ applied: true, status: "ready-for-review" });
    expect(settle.mock.calls[0]?.[0]).toMatchObject({
      chapterNumber: 2,
      allowReapply: false,
    });
    expect(validate.mock.calls[0]?.[2]).toContain("BASE_FACT");
    expect(validate.mock.calls[0]?.[2]).not.toContain("OLD_FACT");
    expect(validate.mock.calls[0]?.[4]).toContain("base-hook");
    expect(validate.mock.calls[0]?.[4]).not.toContain("old-hook");

    const persistedState = JSON.parse(
      await readFile(join(storyDir, "state", "current_state.json"), "utf-8"),
    ) as { facts: Array<{ object: string }> };
    const persistedSummaries = JSON.parse(
      await readFile(join(storyDir, "state", "chapter_summaries.json"), "utf-8"),
    ) as { rows: Array<{ events: string }> };
    const persistedHooks = JSON.parse(
      await readFile(join(storyDir, "state", "hooks.json"), "utf-8"),
    ) as { hooks: Array<{ hookId: string }> };
    const persistedObjects = JSON.parse(
      await readFile(join(storyDir, "state", "objects.json"), "utf-8"),
    ) as { objects: Array<{ objectId: string }> };
    expect(persistedState.facts.map((fact) => fact.object)).toEqual(["BASE_FACT", "REVISED_GOAL"]);
    expect(persistedSummaries.rows.map((summary) => summary.events)).toEqual(["BASE_EVENT", "REVISED_EVENT"]);
    expect(persistedHooks.hooks.map((hook) => hook.hookId)).toEqual(["base-hook"]);
    expect(persistedObjects.objects.map((object) => object.objectId)).toEqual(["base-object", "revised-object"]);
    expect(JSON.stringify({
      persistedState,
      persistedSummaries,
      persistedHooks,
      persistedObjects,
    })).not.toMatch(/OLD_(?:EVENT|FACT|HOOK|OBJECT)/);
  });
});
