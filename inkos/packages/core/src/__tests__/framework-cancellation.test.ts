import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdtemp, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Api, Model } from "@mariozechner/pi-ai";
import { BaseAgent } from "../agents/base.js";
import { WriterAgent } from "../agents/writer.js";
import { createInkOSRuntime } from "../framework/inkos-module.js";
import { FrameworkDiagnostics, MemoryDiagnosticSink } from "../framework/diagnostics.js";
import type { LLMClient } from "../llm/provider.js";
import { PipelineRunner } from "../pipeline/runner.js";
import { StateManager } from "../state/manager.js";

const roots: string[] = [];

afterEach(async () => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

class CancellationProbeAgent extends BaseAgent {
  get name(): string {
    return "cancellation-probe";
  }

  run() {
    return this.chat([{ role: "user", content: "wait for cancellation" }]);
  }
}

const PI_MODEL: Model<Api> = {
  id: "test-model",
  name: "test-model",
  api: "openai-completions",
  provider: "openai",
  baseUrl: "https://gateway.example/v1",
  reasoning: false,
  input: ["text"],
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
  contextWindow: 128_000,
  maxTokens: 8_192,
};

function nativeClient(): LLMClient {
  return {
    provider: "openai",
    service: "custom",
    configSource: "studio",
    apiFormat: "chat",
    stream: false,
    _piModel: PI_MODEL,
    _apiKey: "test-key",
    defaults: {
      temperature: 0.7,
      maxTokens: 512,
      thinkingBudget: 0,
      extra: {},
    },
  };
}

function installHangingFetch() {
  let observedSignal: AbortSignal | undefined;
  let markStarted!: () => void;
  let markAborted!: () => void;
  const started = new Promise<void>((resolve) => { markStarted = resolve; });
  const aborted = new Promise<void>((resolve) => { markAborted = resolve; });
  const fetchMock = vi.fn((_input: Parameters<typeof fetch>[0], init?: RequestInit) => {
    observedSignal = init?.signal ?? undefined;
    markStarted();
    return new Promise<Response>((_resolve, reject) => {
      const abort = () => {
        markAborted();
        reject(observedSignal?.reason instanceof Error
          ? observedSignal.reason
          : new Error("request aborted"));
      };
      if (observedSignal?.aborted) abort();
      else observedSignal?.addEventListener("abort", abort, { once: true });
    });
  });
  vi.stubGlobal("fetch", fetchMock);
  return {
    fetchMock,
    started,
    aborted,
    signal: () => observedSignal,
  };
}

function mockPlanChapterWithLLMProbe(): void {
  vi.spyOn(PipelineRunner.prototype, "planChapter").mockImplementation(async function (
    this: PipelineRunner,
    bookId: string,
  ) {
    const response = await new CancellationProbeAgent(
      this.createAgentContext("cancellation-probe", bookId),
    ).run();
    return {
      bookId,
      chapterNumber: 1,
      intentPath: "intent.md",
      goal: response.content,
      conflicts: [],
    };
  });
}

function mockImportChaptersWithLLMProbe(): void {
  vi.spyOn(PipelineRunner.prototype, "importChapters").mockImplementation(async function (
    this: PipelineRunner,
    input,
  ) {
    await new CancellationProbeAgent(
      this.createAgentContext("cancellation-probe", input.bookId),
    ).run();
    return {
      bookId: input.bookId,
      importedCount: 0,
      totalWords: 0,
      nextChapter: 1,
    };
  });
}

describe("framework LLM cancellation propagation", () => {
  it("does not reinterpret a completed mutation as failed after a late abort", async () => {
    const controller = new AbortController();
    const pipeline = new PipelineRunner({
      client: nativeClient(),
      model: "test-model",
      projectRoot: tmpdir(),
    });

    await expect(pipeline.runInOperationContext(
      { signal: controller.signal },
      async () => {
        controller.abort(new Error("deadline arrived after commit"));
        return "committed";
      },
    )).resolves.toBe("committed");
  });

  it("aborts the underlying native LLM fetch when a module call times out", async () => {
    const root = await mkdtemp(join(tmpdir(), "inkos-framework-timeout-"));
    roots.push(root);
    const pendingFetch = installHangingFetch();
    mockPlanChapterWithLLMProbe();
    const runtime = createInkOSRuntime({
      client: nativeClient(),
      model: "test-model",
      projectRoot: root,
    });

    try {
      const call = runtime.inkos.planChapter("timeout-book", undefined, {
        timeoutMs: 25,
        cancellationGraceMs: 100,
        operationKind: "read",
      });
      const rejection = expect(call).rejects.toMatchObject({
        code: "FRAMEWORK_MODULE_MUTATION_ABORTED",
        retryable: false,
      });
      await pendingFetch.started;
      await rejection;
      await pendingFetch.aborted;

      expect(pendingFetch.signal()?.aborted).toBe(true);
      expect(pendingFetch.fetchMock).toHaveBeenCalledTimes(1);
    } finally {
      await runtime.kernel.shutdown();
    }
  });

  it("aborts the underlying native LLM fetch when the caller cancels", async () => {
    const root = await mkdtemp(join(tmpdir(), "inkos-framework-cancel-"));
    roots.push(root);
    const pendingFetch = installHangingFetch();
    mockPlanChapterWithLLMProbe();
    const runtime = createInkOSRuntime({
      client: nativeClient(),
      model: "test-model",
      projectRoot: root,
    });
    const controller = new AbortController();

    try {
      const call = runtime.inkos.planChapter("cancel-book", undefined, {
        timeoutMs: 5_000,
        cancellationGraceMs: 100,
        signal: controller.signal,
      });
      const rejection = expect(call).rejects.toMatchObject({
        code: "FRAMEWORK_MODULE_MUTATION_ABORTED",
        retryable: false,
      });
      await pendingFetch.started;
      controller.abort(new Error("caller cancelled"));
      await rejection;
      await pendingFetch.aborted;

      expect(pendingFetch.signal()?.aborted).toBe(true);
      expect(pendingFetch.fetchMock).toHaveBeenCalledTimes(1);
    } finally {
      await runtime.kernel.shutdown();
    }
  });

  it("does not persist a draft when cancellation arrives after the LLM step", async () => {
    const root = await mkdtemp(join(tmpdir(), "inkos-framework-persist-gate-"));
    roots.push(root);
    const state = new StateManager(root);
    const bookId = "persist-gate-book";
    const now = new Date().toISOString();
    await state.saveBookConfig(bookId, {
      id: bookId,
      title: "Persist Gate Book",
      platform: "other",
      genre: "xuanhuan",
      status: "active",
      targetChapters: 5,
      chapterWordCount: 500,
      language: "zh",
      createdAt: now,
      updatedAt: now,
    });
    const controller = new AbortController();
    const body = "正文".repeat(250);
    vi.spyOn(WriterAgent.prototype, "writeChapter").mockImplementation(async () => {
      controller.abort(new Error("deadline reached after generation"));
      return {
        chapterNumber: 1,
        title: "Cancelled Draft",
        content: body,
        wordCount: body.length,
        preWriteCheck: "",
        postSettlement: "",
        updatedState: "state",
        updatedLedger: "",
        updatedHooks: "hooks",
        chapterSummary: "",
        updatedSubplots: "",
        updatedEmotionalArcs: "",
        updatedCharacterMatrix: "",
        postWriteErrors: [],
        postWriteWarnings: [],
      };
    });
    const saveChapter = vi.spyOn(WriterAgent.prototype, "saveChapter");
    const pipeline = new PipelineRunner({
      client: nativeClient(),
      model: "test-model",
      projectRoot: root,
      inputGovernanceMode: "legacy",
    });

    await expect(pipeline.runInOperationContext(
      { signal: controller.signal },
      () => pipeline.writeDraft(bookId),
    )).rejects.toThrow("deadline reached after generation");

    const chapterFiles = await readdir(join(state.bookDir(bookId), "chapters")).catch(() => []);
    expect(chapterFiles.filter((file) => file.endsWith(".md"))).toEqual([]);
    expect(saveChapter).not.toHaveBeenCalled();
    await expect(state.loadChapterIndex(bookId)).resolves.toEqual([]);
  });

  it("propagates caller cancellation through the import module port", async () => {
    const root = await mkdtemp(join(tmpdir(), "inkos-framework-import-cancel-"));
    roots.push(root);
    const pendingFetch = installHangingFetch();
    mockImportChaptersWithLLMProbe();
    const runtime = createInkOSRuntime({
      client: nativeClient(),
      model: "test-model",
      projectRoot: root,
    });
    const controller = new AbortController();

    try {
      const call = runtime.inkos.importChapters({
        bookId: "cancel-import-book",
        chapters: [],
      }, {
        timeoutMs: 5_000,
        cancellationGraceMs: 100,
        signal: controller.signal,
      });
      const rejection = expect(call).rejects.toMatchObject({
        code: "FRAMEWORK_MODULE_MUTATION_ABORTED",
        retryable: false,
      });
      await pendingFetch.started;
      controller.abort(new Error("cancel import"));
      await rejection;
      await pendingFetch.aborted;
      expect(pendingFetch.signal()?.aborted).toBe(true);
    } finally {
      await runtime.kernel.shutdown();
    }
  });

  it("emits structured diagnostics when import fails through the module port", async () => {
    const root = await mkdtemp(join(tmpdir(), "inkos-framework-import-diagnostic-"));
    roots.push(root);
    const sink = new MemoryDiagnosticSink();
    const diagnostics = new FrameworkDiagnostics([sink]);
    vi.spyOn(PipelineRunner.prototype, "importChapters")
      .mockRejectedValue(new Error("injected import failure"));
    const runtime = createInkOSRuntime({
      client: nativeClient(),
      model: "test-model",
      projectRoot: root,
    }, { diagnostics });

    try {
      await expect(runtime.inkos.importChapters({
        bookId: "failed-import-book",
        chapters: [],
      })).rejects.toMatchObject({ code: "FRAMEWORK_MODULE_CALL_FAILED" });

      expect(sink.events).toContainEqual(expect.objectContaining({
        type: "framework.module.call",
        status: "failed",
        stage: "import.chapters",
        bookId: "failed-import-book",
        error: expect.objectContaining({ code: "FRAMEWORK_MODULE_CALL_FAILED" }),
      }));
    } finally {
      await runtime.kernel.shutdown();
    }
  });
});
