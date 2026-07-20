import type { PipelineConfig } from "../pipeline/runner.js";
import { PipelineRunner } from "../pipeline/runner.js";
import type { FrameworkModuleCallOptions } from "./contracts.js";
import type { FrameworkDiagnostics } from "./diagnostics.js";
import { FrameworkKernel } from "./kernel.js";
import type { FrameworkModule } from "./module-registry.js";

export const INKOS_MODULE_ID = "inkos.pipeline";

export type FrameworkCallOptions = FrameworkModuleCallOptions;

/** Direct service created by the built-in module. */
export interface InkOSModuleService {
  readonly pipeline: PipelineRunner;
  initBook: PipelineRunner["initBook"];
  writeNextChapter: PipelineRunner["writeNextChapter"];
  repairChapterState: PipelineRunner["repairChapterState"];
  resyncChapterArtifacts: PipelineRunner["resyncChapterArtifacts"];
  writeDraft: PipelineRunner["writeDraft"];
  planChapter: PipelineRunner["planChapter"];
  composeChapter: PipelineRunner["composeChapter"];
  auditDraft: PipelineRunner["auditDraft"];
  reviseDraft: PipelineRunner["reviseDraft"];
  rewriteChapter: PipelineRunner["reviseDraft"];
  approveChapter: PipelineRunner["approveChapter"];
  rejectChapter: PipelineRunner["rejectChapter"];
  importChapters: PipelineRunner["importChapters"];
  getBookStatus: PipelineRunner["getBookStatus"];
}

/** Fault-isolated port consumed by CLI and other framework modules. */
export interface InkOSModulePort {
  readonly pipeline: PipelineRunner;
  initBook(
    book: Parameters<PipelineRunner["initBook"]>[0],
    initOptions?: Parameters<PipelineRunner["initBook"]>[1],
    options?: FrameworkCallOptions,
  ): ReturnType<PipelineRunner["initBook"]>;
  writeNextChapter(
    bookId: string,
    wordCount?: number,
    temperatureOverride?: number,
    options?: FrameworkCallOptions,
  ): ReturnType<PipelineRunner["writeNextChapter"]>;
  repairChapterState(
    bookId: string,
    chapterNumber?: number,
    options?: FrameworkCallOptions,
  ): ReturnType<PipelineRunner["repairChapterState"]>;
  resyncChapterArtifacts(
    bookId: string,
    chapterNumber?: number,
    options?: FrameworkCallOptions,
  ): ReturnType<PipelineRunner["resyncChapterArtifacts"]>;
  writeDraft(
    bookId: string,
    context?: string,
    wordCount?: number,
    options?: FrameworkCallOptions,
  ): ReturnType<PipelineRunner["writeDraft"]>;
  planChapter(
    bookId: string,
    context?: string,
    options?: FrameworkCallOptions,
  ): ReturnType<PipelineRunner["planChapter"]>;
  composeChapter(
    bookId: string,
    context?: string,
    options?: FrameworkCallOptions,
  ): ReturnType<PipelineRunner["composeChapter"]>;
  auditDraft(
    bookId: string,
    chapterNumber?: number,
    options?: FrameworkCallOptions,
  ): ReturnType<PipelineRunner["auditDraft"]>;
  reviseDraft(
    bookId: string,
    chapterNumber?: number,
    mode?: Parameters<PipelineRunner["reviseDraft"]>[2],
    options?: FrameworkCallOptions,
  ): ReturnType<PipelineRunner["reviseDraft"]>;
  rewriteChapter(
    bookId: string,
    chapterNumber: number,
    options?: FrameworkCallOptions,
  ): ReturnType<PipelineRunner["reviseDraft"]>;
  approveChapter(
    bookId: string,
    chapterNumber: number,
    options?: FrameworkCallOptions,
  ): ReturnType<PipelineRunner["approveChapter"]>;
  rejectChapter(
    bookId: string,
    chapterNumber: number,
    rejectOptions?: Parameters<PipelineRunner["rejectChapter"]>[2],
    options?: FrameworkCallOptions,
  ): ReturnType<PipelineRunner["rejectChapter"]>;
  importChapters(
    input: Parameters<PipelineRunner["importChapters"]>[0],
    options?: FrameworkCallOptions,
  ): ReturnType<PipelineRunner["importChapters"]>;
  getBookStatus(
    bookId: string,
    options?: FrameworkCallOptions,
  ): ReturnType<PipelineRunner["getBookStatus"]>;
}

export interface InkOSRuntime {
  readonly kernel: FrameworkKernel;
  readonly pipeline: PipelineRunner;
  readonly inkos: InkOSModulePort;
}

/** InkOS remains source code in core; this manifest only controls lifecycle. */
export function createInkOSModule(pipeline: PipelineRunner): FrameworkModule<InkOSModuleService> {
  return {
    id: INKOS_MODULE_ID,
    version: "1.0.0",
    create: () => ({
      pipeline,
      initBook: pipeline.initBook.bind(pipeline),
      writeNextChapter: pipeline.writeNextChapter.bind(pipeline),
      repairChapterState: pipeline.repairChapterState.bind(pipeline),
      resyncChapterArtifacts: pipeline.resyncChapterArtifacts.bind(pipeline),
      writeDraft: pipeline.writeDraft.bind(pipeline),
      planChapter: pipeline.planChapter.bind(pipeline),
      composeChapter: pipeline.composeChapter.bind(pipeline),
      auditDraft: pipeline.auditDraft.bind(pipeline),
      reviseDraft: pipeline.reviseDraft.bind(pipeline),
      rewriteChapter: pipeline.reviseDraft.bind(pipeline),
      approveChapter: pipeline.approveChapter.bind(pipeline),
      rejectChapter: pipeline.rejectChapter.bind(pipeline),
      importChapters: pipeline.importChapters.bind(pipeline),
      getBookStatus: pipeline.getBookStatus.bind(pipeline),
    }),
  };
}

/**
 * Composition entry point for new CLI paths. Existing callers can keep using
 * PipelineRunner while commands migrate one by one to the governed port.
 */
export function createInkOSRuntime(
  config: PipelineConfig,
  options: {
    readonly kernel?: FrameworkKernel;
    readonly diagnostics?: FrameworkDiagnostics;
  } = {},
): InkOSRuntime {
  const kernel = options.kernel ?? new FrameworkKernel({ diagnostics: options.diagnostics });
  const pipeline = new PipelineRunner(config);
  kernel.register(createInkOSModule(pipeline));

  const invoke = <T>(
    operation: string,
    call: (service: InkOSModuleService) => Promise<T>,
    callOptions: FrameworkCallOptions | undefined,
    bookId: string,
    chapterNumber?: number,
  ): Promise<T> => {
    const operationKind = operation === "book.status" ? "read" : "mutation";
    return kernel.modules.invoke<InkOSModuleService, T>(
      INKOS_MODULE_ID,
      operation,
      (service, signal) => pipeline.runInOperationContext(
        { signal },
        () => call(service),
      ),
      { ...callOptions, bookId, chapterNumber, operationKind },
    );
  };

  const inkos: InkOSModulePort = {
    pipeline,
    initBook: (book, initOptions, callOptions) => invoke(
      "book.init",
      (service) => service.initBook(book, initOptions),
      callOptions,
      book.id,
    ),
    writeNextChapter: (bookId, wordCount, temperatureOverride, callOptions) => invoke(
      "write.next",
      (service) => service.writeNextChapter(bookId, wordCount, temperatureOverride),
      callOptions,
      bookId,
    ),
    repairChapterState: (bookId, chapterNumber, callOptions) => invoke(
      "write.repair-state",
      (service) => service.repairChapterState(bookId, chapterNumber),
      callOptions,
      bookId,
      chapterNumber,
    ),
    resyncChapterArtifacts: (bookId, chapterNumber, callOptions) => invoke(
      "write.resync",
      (service) => service.resyncChapterArtifacts(bookId, chapterNumber),
      callOptions,
      bookId,
      chapterNumber,
    ),
    writeDraft: (bookId, context, wordCount, callOptions) => invoke(
      "write.draft",
      (service) => service.writeDraft(bookId, context, wordCount),
      callOptions,
      bookId,
    ),
    planChapter: (bookId, context, callOptions) => invoke(
      "plan.chapter",
      (service) => service.planChapter(bookId, context),
      callOptions,
      bookId,
    ),
    composeChapter: (bookId, context, callOptions) => invoke(
      "compose.chapter",
      (service) => service.composeChapter(bookId, context),
      callOptions,
      bookId,
    ),
    auditDraft: (bookId, chapterNumber, callOptions) => invoke(
      "audit.draft",
      (service) => service.auditDraft(bookId, chapterNumber),
      callOptions,
      bookId,
      chapterNumber,
    ),
    reviseDraft: (bookId, chapterNumber, mode, callOptions) => invoke(
      "revise.draft",
      (service) => service.reviseDraft(bookId, chapterNumber, mode),
      callOptions,
      bookId,
      chapterNumber,
    ),
    rewriteChapter: (bookId, chapterNumber, callOptions) => invoke(
      "write.rewrite",
      (service) => service.rewriteChapter(bookId, chapterNumber, "rewrite", { force: true }),
      callOptions,
      bookId,
      chapterNumber,
    ),
    approveChapter: (bookId, chapterNumber, callOptions) => invoke(
      "review.approve",
      (service) => service.approveChapter(bookId, chapterNumber),
      callOptions,
      bookId,
      chapterNumber,
    ),
    rejectChapter: (bookId, chapterNumber, rejectOptions, callOptions) => invoke(
      "review.reject",
      (service) => service.rejectChapter(bookId, chapterNumber, rejectOptions),
      callOptions,
      bookId,
      chapterNumber,
    ),
    importChapters: (input, callOptions) => invoke(
      "import.chapters",
      (service) => service.importChapters(input),
      callOptions,
      input.bookId,
    ),
    getBookStatus: (bookId, callOptions) => invoke(
      "book.status",
      (service) => service.getBookStatus(bookId),
      callOptions,
      bookId,
    ),
  };

  return { kernel, pipeline, inkos };
}
