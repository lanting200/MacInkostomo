import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createInkOSRuntime } from "../framework/inkos-module.js";
import type { LLMClient } from "../llm/provider.js";
import type { BookConfig } from "../models/book.js";
import type { ChapterMeta } from "../models/chapter.js";
import { PipelineRunner } from "../pipeline/runner.js";
import { StateManager } from "../state/manager.js";

const roots: string[] = [];

afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("built-in InkOS review module", () => {
  it("routes a full rewrite through forced replay-aware revision", async () => {
    const root = await mkdtemp(join(tmpdir(), "inkos-framework-rewrite-"));
    roots.push(root);
    const revise = vi.spyOn(PipelineRunner.prototype, "reviseDraft").mockResolvedValue({
      chapterNumber: 2,
      wordCount: 2_000,
      fixedIssues: [],
      applied: true,
      status: "ready-for-review",
    });
    const runtime = createInkOSRuntime({
      client: {} as LLMClient,
      model: "test",
      projectRoot: root,
    });

    await runtime.inkos.rewriteChapter("review-book", 2);

    expect(revise).toHaveBeenCalledWith("review-book", 2, "rewrite", { force: true });
    await runtime.kernel.shutdown();
  });

  it("commits approve and keep-subsequent reject mutations through the framework port", async () => {
    const root = await mkdtemp(join(tmpdir(), "inkos-framework-review-"));
    roots.push(root);
    const state = new StateManager(root);
    const now = new Date().toISOString();
    const book: BookConfig = {
      id: "review-book",
      title: "Review Book",
      platform: "other",
      genre: "xuanhuan",
      status: "active",
      targetChapters: 10,
      chapterWordCount: 2_000,
      language: "en",
      createdAt: now,
      updatedAt: now,
    };
    const chapters: ChapterMeta[] = [
      {
        number: 1,
        title: "One",
        status: "ready-for-review",
        wordCount: 2_000,
        createdAt: now,
        updatedAt: now,
        auditIssues: [],
        lengthWarnings: [],
      },
      {
        number: 2,
        title: "Two",
        status: "audit-failed",
        wordCount: 2_000,
        createdAt: now,
        updatedAt: now,
        auditIssues: ["continuity"],
        lengthWarnings: [],
      },
      {
        number: 3,
        title: "Three",
        status: "ready-for-review",
        wordCount: 2_000,
        createdAt: now,
        updatedAt: now,
        auditIssues: [],
        lengthWarnings: [],
      },
    ];
    await state.saveBookConfig(book.id, book);
    await state.saveChapterIndex(book.id, chapters);

    const runtime = createInkOSRuntime({
      client: {} as LLMClient,
      model: "test",
      projectRoot: root,
    });
    const approved = await runtime.inkos.approveChapter(book.id, 1);
    const rejected = await runtime.inkos.rejectChapter(book.id, 2, {
      keepSubsequent: true,
      reason: "Needs continuity repair",
    });

    expect(approved).toMatchObject({ status: "approved", discarded: [] });
    expect(rejected).toMatchObject({ status: "rejected", discarded: [] });
    const persisted = await state.loadChapterIndex(book.id);
    expect(persisted[0]?.status).toBe("approved");
    expect(persisted[1]).toMatchObject({
      status: "rejected",
      reviewNote: "Needs continuity repair",
    });
    expect(persisted[2]).toMatchObject({
      status: "rejected",
      reviewNote: "Stale after rejection of chapter 2: Needs continuity repair",
    });
    await expect(runtime.inkos.writeNextChapter(book.id))
      .rejects.toThrow(/Chapter 2 is rejected/i);
    await expect(runtime.inkos.rewriteChapter(book.id, 3))
      .rejects.toThrow(/Chapter 2 is rejected.*before revising chapter 3/i);

    const reviewGuardRuntime = createInkOSRuntime({
      client: {} as LLMClient,
      model: "test",
      projectRoot: root,
    });
    await expect(reviewGuardRuntime.inkos.approveChapter(book.id, 2))
      .rejects.toThrow(/Chapter 2 is rejected/i);
    await expect(reviewGuardRuntime.inkos.auditDraft(book.id, 2))
      .rejects.toThrow(/Chapter 2 is rejected/i);
    await reviewGuardRuntime.kernel.shutdown();
    await runtime.kernel.shutdown();
  });

  it("blocks approval and keep-subsequent rejection for state-degraded chapters", async () => {
    const root = await mkdtemp(join(tmpdir(), "inkos-framework-degraded-review-"));
    roots.push(root);
    const state = new StateManager(root);
    const now = new Date().toISOString();
    const bookId = "degraded-review-book";
    await state.saveBookConfig(bookId, {
      id: bookId,
      title: "Degraded Review Book",
      platform: "other",
      genre: "xuanhuan",
      status: "active",
      targetChapters: 10,
      chapterWordCount: 2_000,
      createdAt: now,
      updatedAt: now,
    });
    await state.saveChapterIndex(bookId, [{
      number: 1,
      title: "Broken State",
      status: "state-degraded",
      wordCount: 2_000,
      createdAt: now,
      updatedAt: now,
      auditIssues: ["[critical] truth did not settle"],
      lengthWarnings: [],
    }]);
    const runtime = createInkOSRuntime({
      client: {} as LLMClient,
      model: "test",
      projectRoot: root,
    });

    await expect(runtime.inkos.approveChapter(bookId, 1))
      .rejects.toThrow(/state-degraded.*repaired or rewritten/i);
    await expect(runtime.inkos.rejectChapter(bookId, 1, { keepSubsequent: true }))
      .rejects.toThrow(/state-degraded.*rollback or repair/i);
    await expect(runtime.inkos.auditDraft(bookId, 1))
      .rejects.toThrow(/state-degraded.*repaired or rewritten/i);
    expect((await state.loadChapterIndex(bookId))[0]?.status).toBe("state-degraded");
    await runtime.kernel.shutdown();
  });
});
