import type { LLMClient, OnStreamProgress } from "../llm/provider.js";
import { chatCompletion, createLLMClient } from "../llm/provider.js";
import type { Logger } from "../utils/logger.js";
import type { BookConfig, FanficMode } from "../models/book.js";
import type { ChapterMeta } from "../models/chapter.js";
import type { NotifyChannel, LLMConfig, AgentLLMOverride, InputGovernanceMode } from "../models/project.js";
import type { GenreProfile } from "../models/genre-profile.js";
import { ArchitectAgent, type ArchitectOutput } from "../agents/architect.js";
import { FoundationReviewerAgent } from "../agents/foundation-reviewer.js";
import { PlannerAgent, type PlanChapterOutput } from "../agents/planner.js";
import { ComposerAgent, composeGovernedChapter, contextBudgetFromClient, type ComposeChapterOutput } from "../agents/composer.js";
import { WriterAgent, type WriteChapterInput, type WriteChapterOutput } from "../agents/writer.js";
import { LengthNormalizerAgent } from "../agents/length-normalizer.js";
import { ChapterAnalyzerAgent } from "../agents/chapter-analyzer.js";
import { ContinuityAuditor } from "../agents/continuity.js";
import { ReviserAgent, DEFAULT_REVISE_MODE, type ReviseMode } from "../agents/reviser.js";
import { StateValidatorAgent, type ValidationResult, type ValidationWarning } from "../agents/state-validator.js";
import { RadarAgent } from "../agents/radar.js";
import type { RadarSource } from "../agents/radar-source.js";
import { readGenreProfile } from "../agents/rules-reader.js";
import { analyzeAITells } from "../agents/ai-tells.js";
import { analyzeSensitiveWords } from "../agents/sensitive-words.js";
import { StateManager } from "../state/manager.js";
import { withBookTreeTransaction } from "../state/book-tree-transaction.js";
import { MemoryDB, type Fact } from "../state/memory-db.js";
import { dispatchNotification, dispatchWebhookEvent } from "../notify/dispatcher.js";
import type { WebhookEvent } from "../notify/webhook.js";
import type { AgentContext } from "../agents/base.js";
import type { AuditResult, AuditIssue } from "../agents/continuity.js";
import type { RadarResult } from "../agents/radar.js";
import type { LengthSpec, LengthTelemetry } from "../models/length-governance.js";
import type { ChapterMemo, ContextPackage, RuleStack } from "../models/input-governance.js";
import type { ContextCompressionCallback } from "../models/context-compression.js";
import { buildLengthSpec, countChapterLength, formatLengthCount, isOutsideHardRange, resolveLengthCountingMode, type LengthLanguage } from "../utils/length-metrics.js";
import { analyzeLongSpanFatigue } from "../utils/long-span-fatigue.js";
import { buildWritingMethodologySection } from "../utils/writing-methodology.js";
import {
  isNewLayoutBook,
  readCharacterContext,
  readStoryFrame,
  readVolumeMap,
} from "../utils/outline-paths.js";
import {
  loadNarrativeMemorySeed,
  loadRuntimeStateReplayBaseline,
  loadRuntimeStateSnapshot,
  loadRuntimeStateSnapshotAt,
  loadSnapshotCurrentStateFacts,
} from "../state/runtime-state-store.js";
import type { RuntimeStateSnapshot } from "../state/state-reducer.js";
import { rewriteStructuredStateFromMarkdown } from "../state/state-bootstrap.js";
import { AsyncLocalStorage } from "node:async_hooks";
import { readFile, readdir, writeFile, mkdir, rename, rm, stat } from "node:fs/promises";
import { join } from "node:path";
import {
  buildStateDegradedReviewNote,
  buildStateDegradedPersistenceOutput,
  parseStateDegradedReviewNote,
  resolveStateDegradedBaseStatus,
  retrySettlementAfterValidationFailure,
} from "./chapter-state-recovery.js";
import { persistChapterArtifacts, persistChapterTransaction } from "./chapter-persistence.js";
import { runChapterReviewCycle } from "./chapter-review-cycle.js";
import { validateChapterTruthPersistence } from "./chapter-truth-validation.js";
import { loadPersistedPlan, relativeToBookDir, savePersistedPlan } from "./persisted-governed-plan.js";
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
  loadLongFormContinuityStateAt,
  loadLongFormPlan,
  persistCanonCheckpoint,
  persistLongFormContinuityState,
  reconcileLongFormProgress,
  reconcileLongFormRuntimeSnapshot,
  seedPublisherLongFormPlanFromFoundation,
  validateAndApplyLongFormChapter,
  writeAtomicJson,
  type LoadedLongFormPlan,
  type LongFormValidationResult,
} from "../utils/long-form-plan.js";
import type { LongFormContinuityState } from "../models/long-form.js";
import type { PublisherLongFormPlan } from "../models/long-form.js";

const SEQUENCE_LEVEL_CATEGORIES = new Set([
  "Pacing Monotony", "节奏单调",
  "Mood Monotony", "情绪单调",
  "Title Collapse", "标题重复",
  "Title Clustering", "标题聚集",
  "Opening Pattern Repetition", "开头同构",
  "Ending Pattern Repetition", "结尾同构",
]);

function isSequenceLevelCategory(category: string): boolean {
  return SEQUENCE_LEVEL_CATEGORIES.has(category);
}

interface ImportFoundationSourceOptions {
  readonly maxFullTextChars?: number;
  readonly chapterExcerptChars?: number;
  readonly titleCatalogChars?: number;
  readonly edgeChapterCount?: number;
  readonly middleAnchorCount?: number;
}

interface ActiveLongFormGovernance {
  readonly loaded: LoadedLongFormPlan;
  readonly state: LongFormContinuityState;
  readonly context: string;
  readonly runtimeSnapshot?: RuntimeStateSnapshot;
  readonly runtimeBaseSnapshot?: RuntimeStateSnapshot;
}

interface GovernedArtifactOptions {
  readonly reuseExistingIntentWhenContextMissing?: boolean;
  readonly longFormGovernance?: ActiveLongFormGovernance | null;
}

const DEFAULT_IMPORT_FOUNDATION_MAX_FULL_TEXT_CHARS = 80_000;
const DEFAULT_IMPORT_CHAPTER_EXCERPT_CHARS = 6_000;
const DEFAULT_IMPORT_TITLE_CATALOG_CHARS = 24_000;
const DEFAULT_IMPORT_EDGE_CHAPTER_COUNT = 4;
const DEFAULT_IMPORT_MIDDLE_ANCHOR_COUNT = 8;

function formatImportedChapter(
  chapter: { readonly title: string; readonly content: string },
  index: number,
  language: LengthLanguage,
  content = chapter.content,
): string {
  return language === "en"
    ? `Chapter ${index + 1}: ${chapter.title}\n\n${content}`
    : `第${index + 1}章 ${chapter.title}\n\n${content}`;
}

function estimateImportFullTextLength(
  chapters: ReadonlyArray<{ readonly title: string; readonly content: string }>,
): number {
  return chapters.reduce((total, chapter) => total + chapter.title.length + chapter.content.length + 24, 0);
}

function excerptHeadTail(text: string, maxChars: number, language: LengthLanguage): string {
  const clean = text.trim();
  if (clean.length <= maxChars) return clean;
  const headChars = Math.max(200, Math.floor(maxChars * 0.6));
  const tailChars = Math.max(200, maxChars - headChars);
  const omitted = clean.length - headChars - tailChars;
  const marker = language === "en"
    ? `\n\n[... ${omitted} chars omitted for import-context budget ...]\n\n`
    : `\n\n【中间省略 ${omitted} 字，用于控制导入上下文预算】\n\n`;
  return `${clean.slice(0, headChars).trimEnd()}${marker}${clean.slice(-tailChars).trimStart()}`;
}

function pickImportAnchorIndexes(
  chapterCount: number,
  edgeChapterCount: number,
  middleAnchorCount: number,
): ReadonlyArray<number> {
  const selected = new Set<number>();
  for (let i = 0; i < Math.min(edgeChapterCount, chapterCount); i++) selected.add(i);
  for (let i = Math.max(0, chapterCount - edgeChapterCount); i < chapterCount; i++) selected.add(i);

  const middleStart = Math.min(edgeChapterCount, chapterCount);
  const middleEnd = Math.max(middleStart, chapterCount - edgeChapterCount);
  const middleSize = middleEnd - middleStart;
  const anchors = Math.min(middleAnchorCount, middleSize);
  for (let i = 0; i < anchors; i++) {
    const offset = Math.floor(((i + 1) * middleSize) / (anchors + 1));
    selected.add(Math.min(chapterCount - 1, middleStart + offset));
  }

  return [...selected].sort((a, b) => a - b);
}

function buildTitleCatalog(
  chapters: ReadonlyArray<{ readonly title: string; readonly content: string }>,
  language: LengthLanguage,
  maxChars: number,
): string {
  const lines = chapters.map((chapter, index) =>
    language === "en"
      ? `- Chapter ${index + 1}: ${chapter.title} (${chapter.content.length} chars)`
      : `- 第${index + 1}章：${chapter.title}（${chapter.content.length}字）`,
  );
  const joined = lines.join("\n");
  if (joined.length <= maxChars) return joined;

  const headBudget = Math.floor(maxChars * 0.55);
  const tailBudget = maxChars - headBudget;
  const head: string[] = [];
  const tail: string[] = [];
  let headChars = 0;
  let tailChars = 0;
  for (const line of lines) {
    if (headChars + line.length + 1 > headBudget) break;
    head.push(line);
    headChars += line.length + 1;
  }
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i]!;
    if (tailChars + line.length + 1 > tailBudget) break;
    tail.unshift(line);
    tailChars += line.length + 1;
  }
  const omitted = lines.length - head.length - tail.length;
  const marker = language === "en"
    ? `- ... ${omitted} chapter titles omitted ...`
    : `- ……中间 ${omitted} 个章节标题省略……`;
  return [...head, marker, ...tail].join("\n");
}

/**
 * Build the architect external-context for a side-story (番外) foundation: frame
 * it as a companion work that reuses the parent canon's cast/world but tells an
 * independent side plot, and attach the parent canon as reference material.
 */
export function buildSpinoffFoundationContext(
  parentCanon: string,
  direction: string | undefined,
  language: "zh" | "en",
): string {
  const dir = direction?.trim();
  if (language === "en") {
    return [
      "## This is a SIDE-STORY (番外)",
      "Reuse the established characters, world, and rules from the parent canon below. Tell an INDEPENDENT side plot — a bonus arc, a character backstory, or a what-if — that does NOT advance or contradict the parent work's main storyline.",
      dir ? `\n## Side-story direction\n${dir}` : "",
      `\n## Parent canon (reuse these characters and settings)\n${parentCanon}`,
    ].filter(Boolean).join("\n");
  }
  return [
    "## 这是一部番外",
    "复用下方正传正典里已确立的角色、世界观与规则。讲一个独立的侧篇故事——支线、角色前传或 what-if——不要推进或违背正传的主线剧情。",
    dir ? `\n## 番外方向\n${dir}` : "",
    `\n## 正传正典（复用以下角色与设定）\n${parentCanon}`,
  ].filter(Boolean).join("\n");
}

export function buildImportFoundationSource(
  chapters: ReadonlyArray<{ readonly title: string; readonly content: string }>,
  language: LengthLanguage,
  options: ImportFoundationSourceOptions = {},
): string {
  const maxFullTextChars = options.maxFullTextChars ?? DEFAULT_IMPORT_FOUNDATION_MAX_FULL_TEXT_CHARS;
  const chapterExcerptChars = options.chapterExcerptChars ?? DEFAULT_IMPORT_CHAPTER_EXCERPT_CHARS;
  const titleCatalogChars = options.titleCatalogChars ?? DEFAULT_IMPORT_TITLE_CATALOG_CHARS;
  const edgeChapterCount = options.edgeChapterCount ?? DEFAULT_IMPORT_EDGE_CHAPTER_COUNT;
  const middleAnchorCount = options.middleAnchorCount ?? DEFAULT_IMPORT_MIDDLE_ANCHOR_COUNT;

  if (estimateImportFullTextLength(chapters) <= maxFullTextChars) {
    return chapters.map((chapter, index) => formatImportedChapter(chapter, index, language)).join("\n\n---\n\n");
  }

  const anchorIndexes = pickImportAnchorIndexes(chapters.length, edgeChapterCount, middleAnchorCount);
  const header = language === "en"
    ? [
        "## Import foundation source package",
        "",
        `The imported book has ${chapters.length} chapters. To avoid overflowing the LLM context, this package keeps the opening chapters, ending/continuation point, selected middle anchors, and a capped title catalog. Full chapters will still be replayed sequentially after foundation generation to rebuild truth files.`,
      ].join("\n")
    : [
        "## 导入基础设定压缩资料包",
        "",
        `本次导入共 ${chapters.length} 章。为避免超出 LLM 上下文，这里保留开篇、结尾续写点、少量中段锚点和标题目录；完整章节将在后续顺序回放中逐章分析并沉淀 truth files。`,
      ].join("\n");
  const catalogTitle = language === "en" ? "## Capped chapter title catalog" : "## 章节标题目录（截断）";
  const anchorsTitle = language === "en" ? "## Source excerpts for architecture" : "## 用于反推基础设定的正文摘录";
  const anchorText = anchorIndexes
    .map((index) => {
      const chapter = chapters[index]!;
      return formatImportedChapter(
        chapter,
        index,
        language,
        excerptHeadTail(chapter.content, chapterExcerptChars, language),
      );
    })
    .join("\n\n---\n\n");

  return [
    header,
    "",
    catalogTitle,
    buildTitleCatalog(chapters, language, titleCatalogChars),
    "",
    anchorsTitle,
    anchorText,
  ].join("\n");
}

export interface PipelineConfig {
  readonly client: LLMClient;
  readonly model: string;
  readonly projectRoot: string;
  readonly defaultLLMConfig?: LLMConfig;
  readonly foundationReviewRetries?: number;
  readonly writingReviewRetries?: number;
  /**
   * "auto" (default): writeNextChapter runs the audit→revise loop inline.
   * "manual": stop right after the draft (no auto audit/revise) so review/revise
   * become explicit, user-driven checkpoint actions — chapter write stays fast.
   */
  readonly chapterReviewMode?: "auto" | "manual";
  readonly notifyChannels?: ReadonlyArray<NotifyChannel>;
  readonly radarSources?: ReadonlyArray<RadarSource>;
  readonly externalContext?: string;
  readonly modelOverrides?: Record<string, string | AgentLLMOverride>;
  /** Runtime-only secrets for agent overrides; never persisted in project JSON. */
  readonly modelOverrideApiKeys?: Readonly<Record<string, string>>;
  readonly inputGovernanceMode?: InputGovernanceMode;
  readonly logger?: Logger;
  readonly onStreamProgress?: OnStreamProgress;
  /** Optional public draft stream. Only the writer's creative pass receives it. */
  readonly onWriterTextDelta?: (text: string) => void;
  readonly onContextCompression?: ContextCompressionCallback;
}

export interface TokenUsageSummary {
  readonly promptTokens: number;
  readonly completionTokens: number;
  readonly totalTokens: number;
}

export interface ChapterPipelineResult {
  readonly chapterNumber: number;
  readonly title: string;
  readonly wordCount: number;
  readonly auditResult: AuditResult;
  readonly revised: boolean;
  readonly status: "ready-for-review" | "audit-failed" | "state-degraded";
  readonly lengthWarnings?: ReadonlyArray<string>;
  readonly lengthTelemetry?: LengthTelemetry;
  readonly tokenUsage?: TokenUsageSummary;
}

// Atomic operation results
export interface DraftResult {
  readonly chapterNumber: number;
  readonly title: string;
  readonly wordCount: number;
  readonly filePath: string;
  readonly lengthWarnings?: ReadonlyArray<string>;
  readonly lengthTelemetry?: LengthTelemetry;
  readonly tokenUsage?: TokenUsageSummary;
}

export interface PlanChapterResult {
  readonly bookId: string;
  readonly chapterNumber: number;
  readonly intentPath: string;
  readonly goal: string;
  readonly conflicts: ReadonlyArray<string>;
}

export interface ComposeChapterResult extends PlanChapterResult {
  readonly contextPath: string;
  readonly ruleStackPath: string;
  readonly tracePath: string;
}

export interface ReviseResult {
  readonly chapterNumber: number;
  readonly wordCount: number;
  readonly fixedIssues: ReadonlyArray<string>;
  readonly applied: boolean;
  readonly status: "unchanged" | "ready-for-review" | "audit-failed" | "state-degraded";
  readonly skippedReason?: string;
  readonly lengthWarnings?: ReadonlyArray<string>;
  readonly lengthTelemetry?: LengthTelemetry;
}

export interface RevisionBehaviorOptions {
  /** Apply a full rewrite even when the current audit has no blocking issue. */
  readonly force?: boolean;
}

export interface ReviewMutationResult {
  readonly bookId: string;
  readonly chapterNumber: number;
  readonly status: "approved" | "rejected";
  readonly discarded: ReadonlyArray<number>;
  readonly rolledBackTo?: number;
  readonly reason?: string;
}

export interface TruthFiles {
  readonly currentState: string;
  readonly particleLedger: string;
  readonly pendingHooks: string;
  readonly storyBible: string;
  readonly volumeOutline: string;
  readonly bookRules: string;
}

export interface BookStatusInfo {
  readonly bookId: string;
  readonly title: string;
  readonly genre: string;
  readonly platform: string;
  readonly status: string;
  readonly chaptersWritten: number;
  readonly totalWords: number;
  readonly nextChapter: number;
  readonly chapters: ReadonlyArray<ChapterMeta>;
}

interface MergedAuditEvaluation {
  readonly auditResult: AuditResult;
  readonly aiTellCount: number;
  readonly blockingCount: number;
  readonly criticalCount: number;
  readonly revisionBlockingIssues: ReadonlyArray<AuditIssue>;
}

export interface ImportChaptersInput {
  readonly bookId: string;
  readonly chapters: ReadonlyArray<{ readonly title: string; readonly content: string }>;
  readonly resumeFrom?: number;
  /** "continuation" (default) = pick up where the text left off, no new spacetime.
   *  "series" = shared universe but independent new story, requires new spacetime. */
  readonly importMode?: "continuation" | "series";
}

export interface ImportChaptersResult {
  readonly bookId: string;
  readonly importedCount: number;
  readonly totalWords: number;
  readonly nextChapter: number;
}

export interface InitBookOptions {
  readonly externalContext?: string;
  readonly authorIntent?: string;
  readonly currentFocus?: string;
  /** Optional Publisher plan persisted atomically with the new book. */
  readonly longFormPlan?: PublisherLongFormPlan;
}

export interface PipelineOperationContext {
  readonly signal?: AbortSignal;
}

export class PipelineRunner {
  private readonly state: StateManager;
  private readonly config: PipelineConfig;
  private readonly agentClients = new Map<string, LLMClient>();
  private readonly operationContext = new AsyncLocalStorage<PipelineOperationContext>();
  private memoryIndexFallbackWarned = false;

  constructor(config: PipelineConfig) {
    this.config = config;
    this.state = new StateManager(config.projectRoot);
  }

  /** Runs one public pipeline operation with request-scoped cancellation. */
  public runInOperationContext<T>(
    context: PipelineOperationContext,
    operation: () => T | Promise<T>,
  ): Promise<T> {
    return this.operationContext.run(context, async () => {
      this.throwIfOperationAborted();
      // Mutation ports reconcile timeout with the real operation settlement.
      // A late abort must not turn an already committed result into a failure.
      return await operation();
    });
  }

  private currentOperationSignal(): AbortSignal | undefined {
    return this.operationContext.getStore()?.signal;
  }

  private throwIfOperationAborted(): void {
    const signal = this.currentOperationSignal();
    if (!signal?.aborted) return;
    if (signal.reason instanceof Error) throw signal.reason;
    throw new Error(signal.reason === undefined ? "Pipeline operation aborted" : String(signal.reason));
  }

  private localize(language: LengthLanguage, messages: { zh: string; en: string }): string {
    return language === "en" ? messages.en : messages.zh;
  }

  private async resolveBookLanguage(
    book: Pick<BookConfig, "genre" | "language">,
  ): Promise<LengthLanguage> {
    if (book.language) {
      return book.language;
    }

    try {
      const { profile } = await this.loadGenreProfile(book.genre);
      return profile.language;
    } catch {
      return "zh";
    }
  }

  private async resolveBookLanguageById(bookId: string): Promise<LengthLanguage> {
    try {
      const book = await this.state.loadBookConfig(bookId);
      return await this.resolveBookLanguage(book);
    } catch {
      return "zh";
    }
  }

  private languageFromLengthSpec(lengthSpec: Pick<LengthSpec, "countingMode">): LengthLanguage {
    return lengthSpec.countingMode === "en_words" ? "en" : "zh";
  }

  private logStage(language: LengthLanguage, message: { zh: string; en: string }): void {
    this.config.logger?.info(
      `${this.localize(language, { zh: "阶段：", en: "Stage: " })}${this.localize(language, message)}`,
    );
  }

  private logInfo(language: LengthLanguage, message: { zh: string; en: string }): void {
    this.config.logger?.info(this.localize(language, message));
  }

  private logWarn(language: LengthLanguage, message: { zh: string; en: string }): void {
    this.config.logger?.warn(this.localize(language, message));
  }

  private async tryGenerateStyleGuide(
    bookId: string,
    referenceText: string,
    sourceName: string | undefined,
    language?: LengthLanguage,
  ): Promise<void> {
    try {
      await this.generateStyleGuide(bookId, referenceText, sourceName);
    } catch (error) {
      this.throwIfOperationAborted();
      const resolvedLanguage = language ?? await this.resolveBookLanguageById(bookId);
      const detail = error instanceof Error ? error.message : String(error);
      this.logWarn(resolvedLanguage, {
        zh: `风格指纹提取失败，已跳过：${detail}`,
        en: `Style fingerprint extraction failed and was skipped: ${detail}`,
      });
    }
  }

  private async generateAndReviewFoundation(params: {
    readonly generate: (reviewFeedback?: string) => Promise<ArchitectOutput>;
    readonly reviewer: FoundationReviewerAgent;
    readonly mode: "original" | "fanfic" | "series";
    readonly sourceCanon?: string;
    readonly styleGuide?: string;
    readonly language: "zh" | "en";
    readonly stageLanguage: LengthLanguage;
    readonly targetChapters?: number;
    readonly maxRetries?: number;
  }): Promise<ArchitectOutput> {
    const maxRetries = params.maxRetries ?? this.config.foundationReviewRetries ?? 2;
    let foundation = await params.generate();

    for (let attempt = 0; attempt < maxRetries; attempt++) {
      this.logStage(params.stageLanguage, {
        zh: `审核基础设定（第${attempt + 1}轮）`,
        en: `reviewing foundation (round ${attempt + 1})`,
      });

      const review = await params.reviewer.review({
        foundation,
        mode: params.mode,
        sourceCanon: params.sourceCanon,
        styleGuide: params.styleGuide,
        language: params.language,
        targetChapters: params.targetChapters,
      });

      this.config.logger?.info(
        `Foundation review: ${review.totalScore}/100 ${review.passed ? "PASSED" : "REJECTED"}`,
      );
      for (const dim of review.dimensions) {
        this.config.logger?.info(`  [${dim.score}] ${dim.name.slice(0, 40)}`);
      }

      if (review.passed) {
        return foundation;
      }

      this.logWarn(params.stageLanguage, {
        zh: `基础设定未通过审核（${review.totalScore}分），正在重新生成...`,
        en: `Foundation rejected (${review.totalScore}/100), regenerating...`,
      });

      foundation = await params.generate(this.buildFoundationReviewFeedback(review, params.language));
    }

    // Final review
    const finalReview = await params.reviewer.review({
      foundation,
      mode: params.mode,
      sourceCanon: params.sourceCanon,
      styleGuide: params.styleGuide,
      language: params.language,
      targetChapters: params.targetChapters,
    });
    this.config.logger?.info(
      `Foundation final review: ${finalReview.totalScore}/100 ${finalReview.passed ? "PASSED" : "ACCEPTED (max retries)"}`,
    );

    return foundation;
  }

  private buildFoundationReviewFeedback(
    review: {
      readonly dimensions: ReadonlyArray<{
        readonly name: string;
        readonly score: number;
        readonly feedback: string;
      }>;
      readonly overallFeedback: string;
    },
    language: "zh" | "en",
  ): string {
    const dimensionLines = review.dimensions
      .map((dimension) => (
        language === "en"
          ? `- ${dimension.name} [${dimension.score}]: ${dimension.feedback}`
          : `- ${dimension.name}（${dimension.score}分）：${dimension.feedback}`
      ))
      .join("\n");

    return language === "en"
      ? [
          "## Overall Feedback",
          review.overallFeedback,
          "",
          "## Dimension Notes",
          dimensionLines || "- none",
        ].join("\n")
      : [
          "## 总评",
          review.overallFeedback,
          "",
          "## 分项问题",
          dimensionLines || "- 无",
        ].join("\n");
  }

  private agentCtx(bookId?: string): AgentContext {
    return {
      client: this.config.client,
      model: this.config.model,
      projectRoot: this.config.projectRoot,
      bookId,
      logger: this.config.logger,
      onStreamProgress: this.config.onStreamProgress,
      signal: this.currentOperationSignal(),
    };
  }

  private resolveOverride(agentName: string): { model: string; client: LLMClient } {
    const override = this.config.modelOverrides?.[agentName];
    if (!override) {
      return { model: this.config.model, client: this.config.client };
    }
    if (typeof override === "string") {
      return { model: override, client: this.config.client };
    }
    // Full override — needs its own client if baseUrl differs
    if (!override.baseUrl) {
      return { model: override.model, client: this.config.client };
    }
    const base = this.config.defaultLLMConfig;
    const provider = override.provider ?? base?.provider ?? "custom";
    const resolvedApiKey = this.config.modelOverrideApiKeys?.[agentName];
    const apiKeySource = resolvedApiKey
      ? `runtime:${agentName}`
      : override.apiKeyEnv
      ? `env:${override.apiKeyEnv}`
      : `base:${base?.apiKey ?? ""}`;
    const stream = override.stream ?? base?.stream ?? true;
    const apiFormat = base?.apiFormat ?? "chat";
    const cacheKey = [
      provider,
      override.baseUrl,
      apiKeySource,
      `stream:${stream}`,
      `format:${apiFormat}`,
    ].join("|");
    let client = this.agentClients.get(cacheKey);
    if (!client) {
      const apiKey = resolvedApiKey ?? (override.apiKeyEnv
        ? process.env[override.apiKeyEnv] ?? ""
        : base?.apiKey ?? "");
      client = createLLMClient({
        provider,
        service: base?.service ?? "custom",
        configSource: base?.configSource ?? "env",
        baseUrl: override.baseUrl,
        apiKey,
        model: override.model,
        temperature: base?.temperature ?? 0.7,
        thinkingBudget: base?.thinkingBudget ?? 0,
        apiFormat,
        stream,
      });
      this.agentClients.set(cacheKey, client);
    }
    return { model: override.model, client };
  }

  private agentCtxFor(agent: string, bookId?: string): AgentContext {
    const { model, client } = this.resolveOverride(agent);
    return {
      client,
      model,
      projectRoot: this.config.projectRoot,
      bookId,
      logger: this.config.logger?.child(agent),
      onStreamProgress: this.config.onStreamProgress,
      onTextDelta: agent === "writer" || agent === "reviser"
        ? this.config.onWriterTextDelta
        : undefined,
      signal: this.currentOperationSignal(),
    };
  }

  public createAgentContext(agent: string, bookId?: string): AgentContext {
    return this.agentCtxFor(agent, bookId);
  }

  private async pathExists(path: string): Promise<boolean> {
    try {
      await stat(path);
      return true;
    } catch {
      return false;
    }
  }

  private async loadGenreProfile(genre: string): Promise<{ profile: GenreProfile }> {
    const parsed = await readGenreProfile(this.config.projectRoot, genre);
    return { profile: parsed.profile };
  }

  private async initializeLongFormGovernanceAt(
    bookDir: string,
    book: BookConfig,
    foundation: Pick<ArchitectOutput, "roles" | "bookRules" | "pendingHooks">,
    language: LengthLanguage,
    suppliedPlan?: PublisherLongFormPlan,
  ): Promise<void> {
    const basePlan = suppliedPlan ?? createPublisherLongFormPlan({
      bookId: book.id,
      targetTotalWords: book.targetChapters * book.chapterWordCount,
      targetChapterWords: book.chapterWordCount,
      volumeCount: Math.min(100, Math.max(1, Math.ceil(book.targetChapters / 50))),
      specialConstraints: [language === "en"
        ? "Preserve character, world-rule, timeline, and cross-volume continuity."
        : "保持人物、世界规则、时间线与跨卷设定一致。"],
      createdAt: book.createdAt,
      updatedAt: book.updatedAt,
    });
    const longFormPlan = seedPublisherLongFormPlanFromFoundation(basePlan, {
      roles: foundation.roles,
      bookRules: foundation.bookRules,
      pendingHooks: foundation.pendingHooks,
    });
    if (longFormPlan.bookId !== book.id) {
      throw new Error(`Long-form plan bookId ${longFormPlan.bookId} does not match ${book.id}.`);
    }

    await writeAtomicJson(join(bookDir, "long-form-plan.json"), longFormPlan);
    const normalizedLongFormPlan = adaptPublisherLongFormPlan(longFormPlan);
    // Snapshot 0 must contain a complete structured baseline. A partial state
    // directory would leave later chapter facts behind on rollback.
    await loadRuntimeStateSnapshot(bookDir);
    await persistLongFormContinuityState(
      bookDir,
      createInitialLongFormState(fingerprintLongFormPlan(normalizedLongFormPlan)),
    );
  }

  // ---------------------------------------------------------------------------
  // Atomic operations (composable by OpenClaw or agent mode)
  // ---------------------------------------------------------------------------

  async runRadar(): Promise<RadarResult> {
    const radar = new RadarAgent(this.agentCtxFor("radar"), this.config.radarSources);
    return radar.scan();
  }

  async initBook(book: BookConfig, options: InitBookOptions = {}): Promise<void> {
    const architect = new ArchitectAgent(this.agentCtxFor("architect", book.id));
    const bookDir = this.state.bookDir(book.id);
    if (await this.pathExists(bookDir)) {
      if (await this.state.isCompleteBookDirectory(bookDir)) {
        throw new Error(`Book "${book.id}" already exists at books/${book.id}/. Use a different title or delete the existing book first.`);
      }
      throw new Error(
        `Incomplete book directory already exists at books/${book.id}/. `
        + "Move it to a recovery location or remove it explicitly before creating this title.",
      );
    }
    const stagingBookDir = join(
      this.state.booksDir,
      `.tmp-book-create-${book.id}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`,
    );
    const stageLanguage = await this.resolveBookLanguage(book);
    const effectiveExternalContext = options.externalContext ?? this.config.externalContext;

    this.logStage(stageLanguage, { zh: "生成基础设定", en: "generating foundation" });
    const { profile: gp } = await this.loadGenreProfile(book.genre);
    const reviewer = new FoundationReviewerAgent(this.agentCtxFor("foundation-reviewer", book.id));
    const resolvedLanguage = (book.language ?? gp.language) === "en" ? "en" as const : "zh" as const;
    const foundation = await this.generateAndReviewFoundation({
      generate: (reviewFeedback) => architect.generateFoundation(
        book,
        effectiveExternalContext,
        reviewFeedback,
      ),
      reviewer,
      mode: "original",
      language: resolvedLanguage,
      stageLanguage,
      targetChapters: book.targetChapters,
    });
    try {
      this.logStage(stageLanguage, { zh: "保存书籍配置", en: "saving book config" });
      await this.state.saveBookConfigAt(stagingBookDir, book);

      this.logStage(stageLanguage, { zh: "写入基础设定文件", en: "writing foundation files" });
      await architect.writeFoundationFiles(
        stagingBookDir,
        foundation,
        gp.numericalSystem,
        book.language ?? gp.language,
      );

      if (effectiveExternalContext && effectiveExternalContext.trim().length > 0) {
        const storyDir = join(stagingBookDir, "story");
        await mkdir(storyDir, { recursive: true });
        await writeFile(join(storyDir, "brief.md"), effectiveExternalContext, "utf-8");
      }

      this.logStage(stageLanguage, { zh: "初始化控制文档", en: "initializing control documents" });
      await this.state.ensureControlDocumentsAt(
        stagingBookDir,
        book.language ?? gp.language,
        options.authorIntent ?? effectiveExternalContext,
      );
      if (options.currentFocus?.trim()) {
        await writeFile(
          join(stagingBookDir, "story", "current_focus.md"),
          options.currentFocus.trimEnd() + "\n",
          "utf-8",
        );
      }

      await this.initializeLongFormGovernanceAt(
        stagingBookDir,
        book,
        foundation,
        resolvedLanguage,
        options.longFormPlan,
      );

      await this.state.saveChapterIndexAt(stagingBookDir, []);

      this.logStage(stageLanguage, { zh: "创建初始快照", en: "creating initial snapshot" });
      await this.state.snapshotStateAt(stagingBookDir, 0);

      if (await this.pathExists(bookDir)) {
        if (await this.state.isCompleteBookDirectory(bookDir)) {
          throw new Error(`Book "${book.id}" already exists at books/${book.id}/. Use a different title or delete the existing book first.`);
        }
        throw new Error(
          `Incomplete book directory appeared at books/${book.id}/ while creation was running; `
          + "the staged book was kept out of the destination to preserve both copies.",
        );
      }

      await rename(stagingBookDir, bookDir);
    } catch (error) {
      await rm(stagingBookDir, { recursive: true, force: true }).catch(() => undefined);
      throw error;
    }
  }

  /**
   * Revise an existing book foundation without touching runtime chapter state.
   *
   * Legacy books read the flat foundation files as source. Phase 5+ books read
   * the authoritative outline/ and roles/ files instead of the compatibility
   * shims, otherwise large role/story details can be lost during rewrite.
   */
  async reviseFoundation(bookId: string, feedback: string): Promise<void> {
    const releaseLock = await this.state.acquireBookLock(bookId);
    try {
      await this._reviseFoundationLocked(bookId, feedback);
    } finally {
      await releaseLock();
    }
  }

  private async _reviseFoundationLocked(bookId: string, feedback: string): Promise<void> {
    const bookDir = this.state.bookDir(bookId);
    const storyDir = join(bookDir, "story");
    const isPhase5 = await isNewLayoutBook(bookDir);

    const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
    const backupTag = isPhase5 ? "phase5" : "phase4";
    const backupDir = join(storyDir, `.backup-${backupTag}-${timestamp}`);
    await mkdir(backupDir, { recursive: true });

    const flatFiles = ["story_bible.md", "volume_outline.md", "book_rules.md", "character_matrix.md"];
    for (const fileName of flatFiles) {
      try {
        const content = await readFile(join(storyDir, fileName), "utf-8");
        await writeFile(join(backupDir, fileName), content, "utf-8");
      } catch {
        // Missing legacy shim files are fine for partially migrated books.
      }
    }

    if (isPhase5) {
      await this.copyDirShallow(join(storyDir, "outline"), join(backupDir, "outline"));
      await this.copyDirRecursive(join(storyDir, "roles"), join(backupDir, "roles"));
    }

    const book = await this.state.loadBookConfig(bookId);
    let oldStoryBible: string;
    let oldVolumeOutline: string;
    let oldBookRules: string;
    let oldCharacterMatrix: string;

    if (isPhase5) {
      [oldStoryBible, oldVolumeOutline, oldCharacterMatrix] = await Promise.all([
        readStoryFrame(bookDir),
        readVolumeMap(bookDir),
        readCharacterContext(bookDir),
      ]);
      oldBookRules = await readFile(join(storyDir, "book_rules.md"), "utf-8").catch(() => "");
    } else {
      [oldStoryBible, oldVolumeOutline, oldBookRules, oldCharacterMatrix] = await Promise.all([
        readFile(join(storyDir, "story_bible.md"), "utf-8").catch(() => ""),
        readFile(join(storyDir, "volume_outline.md"), "utf-8").catch(() => ""),
        readFile(join(storyDir, "book_rules.md"), "utf-8").catch(() => ""),
        readFile(join(storyDir, "character_matrix.md"), "utf-8").catch(() => ""),
      ]);
    }

    const architect = new ArchitectAgent(this.agentCtxFor("architect", bookId));
    const foundation = await architect.generateFoundation(book, undefined, undefined, {
      reviseFrom: {
        storyBible: oldStoryBible,
        volumeOutline: oldVolumeOutline,
        bookRules: oldBookRules,
        characterMatrix: oldCharacterMatrix,
        userFeedback: feedback,
      },
    });

    const reviewer = new FoundationReviewerAgent(this.agentCtxFor("foundation-reviewer", bookId));
    const resolvedLanguage = (book.language ?? "zh") === "en" ? "en" as const : "zh" as const;
    try {
      const review = await reviewer.review({
        foundation,
        mode: "original",
        language: resolvedLanguage,
        targetChapters: book.targetChapters,
      } as Parameters<FoundationReviewerAgent["review"]>[0]);
      if (!review.passed) {
        this.config.logger?.warn?.(
          `[reviseFoundation] Foundation review did not pass; accepting rewrite. Feedback: ${review.overallFeedback ?? ""}`,
        );
      }
    } catch (error) {
      this.throwIfOperationAborted();
      this.config.logger?.warn?.(
        `[reviseFoundation] Foundation review failed and was skipped: ${error instanceof Error ? error.message : String(error)}`,
      );
    }

    const outlineDir = join(storyDir, "outline");
    await mkdir(outlineDir, { recursive: true });
    await mkdir(join(storyDir, "roles", "主要角色"), { recursive: true });
    await mkdir(join(storyDir, "roles", "次要角色"), { recursive: true });

    const { profile: gp } = await this.loadGenreProfile(book.genre);
    this.throwIfOperationAborted();
    await withBookTreeTransaction(bookDir, () => architect.writeFoundationFiles(
        bookDir,
        foundation,
        gp.numericalSystem,
        book.language ?? gp.language,
        "revise",
      ));
  }

  private async copyDirShallow(src: string, dest: string): Promise<void> {
    try {
      await mkdir(dest, { recursive: true });
      const entries = await readdir(src);
      await Promise.all(entries.map(async (entry) => {
        try {
          const content = await readFile(join(src, entry), "utf-8");
          await writeFile(join(dest, entry), content, "utf-8");
        } catch {
          // Skip unreadable files.
        }
      }));
    } catch {
      // Source directory does not exist.
    }
  }

  private async copyDirRecursive(src: string, dest: string): Promise<void> {
    try {
      await mkdir(dest, { recursive: true });
      const entries = await readdir(src, { withFileTypes: true });
      for (const entry of entries) {
        const srcPath = join(src, entry.name);
        const destPath = join(dest, entry.name);
        if (entry.isDirectory()) {
          await this.copyDirRecursive(srcPath, destPath);
        } else if (entry.isFile()) {
          try {
            const content = await readFile(srcPath, "utf-8");
            await writeFile(destPath, content, "utf-8");
          } catch {
            // Skip unreadable files.
          }
        }
      }
    } catch {
      // Source directory does not exist.
    }
  }

  /** Import external source material and generate fanfic_canon.md */
  async importFanficCanon(
    bookId: string,
    sourceText: string,
    sourceName: string,
    fanficMode: FanficMode,
  ): Promise<string> {
    const { FanficCanonImporter } = await import("../agents/fanfic-canon-importer.js");
    const importer = new FanficCanonImporter(this.agentCtxFor("fanfic-canon-importer", bookId));
    const result = await importer.importFromText(sourceText, sourceName, fanficMode);

    const bookDir = this.state.bookDir(bookId);
    const storyDir = join(bookDir, "story");
    await mkdir(storyDir, { recursive: true });
    await writeFile(join(storyDir, "fanfic_canon.md"), result.fullDocument, "utf-8");

    return result.fullDocument;
  }

  /** One-step fanfic book creation: create book + import canon + generate foundation */
  async initFanficBook(
    book: BookConfig,
    sourceText: string,
    sourceName: string,
    fanficMode: FanficMode,
  ): Promise<void> {
    const bookDir = this.state.bookDir(book.id);
    const stageLanguage = await this.resolveBookLanguage(book);

    this.logStage(stageLanguage, { zh: "保存书籍配置", en: "saving book config" });
    await this.state.saveBookConfig(book.id, book);

    // Step 1: Import source material → fanfic_canon.md
    this.logStage(stageLanguage, { zh: "导入同人正典", en: "importing fanfic canon" });
    const fanficCanon = await this.importFanficCanon(book.id, sourceText, sourceName, fanficMode);

    // Step 2: Generate foundation with review loop
    const architect = new ArchitectAgent(this.agentCtxFor("architect", book.id));
    const reviewer = new FoundationReviewerAgent(this.agentCtxFor("foundation-reviewer", book.id));
    this.logStage(stageLanguage, { zh: "生成同人基础设定", en: "generating fanfic foundation" });
    const { profile: gp } = await this.loadGenreProfile(book.genre);
    const resolvedLanguage = (book.language ?? gp.language) === "en" ? "en" as const : "zh" as const;
    const foundation = await this.generateAndReviewFoundation({
      generate: (reviewFeedback) => architect.generateFanficFoundation(
        book,
        fanficCanon,
        fanficMode,
        reviewFeedback,
      ),
      reviewer,
      mode: "fanfic",
      sourceCanon: fanficCanon,
      language: resolvedLanguage,
      stageLanguage,
      targetChapters: book.targetChapters,
    });
    this.logStage(stageLanguage, { zh: "写入基础设定文件", en: "writing foundation files" });
    await architect.writeFoundationFiles(
      bookDir,
      foundation,
      gp.numericalSystem,
      book.language ?? gp.language,
    );
    this.logStage(stageLanguage, { zh: "初始化控制文档", en: "initializing control documents" });
    await this.state.ensureControlDocuments(book.id, this.config.externalContext);

    // Step 3: Generate style guide from source material
    if (sourceText.length >= 500) {
      this.logStage(stageLanguage, { zh: "提取原作风格指纹", en: "extracting source style fingerprint" });
      await this.tryGenerateStyleGuide(book.id, sourceText, sourceName, stageLanguage);
    }

    await this.initializeLongFormGovernanceAt(bookDir, book, foundation, resolvedLanguage);

    // Step 4: Initialize chapters directory + snapshot
    this.logStage(stageLanguage, { zh: "创建初始快照", en: "creating initial snapshot" });
    await mkdir(join(bookDir, "chapters"), { recursive: true });
    await this.state.saveChapterIndex(book.id, []);
    await this.state.snapshotState(book.id, 0);
  }

  /**
   * Create a side-story (番外) book: a standalone companion that inherits a
   * parent book's world/characters via parent_canon.md, but tells an INDEPENDENT
   * side plot that does not advance or contradict the parent's main-line state.
   * Reuses importCanon (which already builds the parent-canon reference for
   * side-story writing) + the standard original-foundation architect path.
   */
  async initSpinoffBook(book: BookConfig, parentBookId: string, direction?: string): Promise<void> {
    const bookDir = this.state.bookDir(book.id);
    const stageLanguage = await this.resolveBookLanguage(book);

    this.logStage(stageLanguage, { zh: "保存书籍配置", en: "saving book config" });
    await this.state.saveBookConfig(book.id, book);

    this.logStage(stageLanguage, { zh: "导入正传正典参照", en: "importing parent canon" });
    const parentCanon = await this.importCanon(book.id, parentBookId);

    const architect = new ArchitectAgent(this.agentCtxFor("architect", book.id));
    const reviewer = new FoundationReviewerAgent(this.agentCtxFor("foundation-reviewer", book.id));
    const { profile: gp } = await this.loadGenreProfile(book.genre);
    const resolvedLanguage = (book.language ?? gp.language) === "en" ? "en" as const : "zh" as const;
    const spinoffContext = buildSpinoffFoundationContext(parentCanon, direction, resolvedLanguage);

    this.logStage(stageLanguage, { zh: "生成番外基础设定", en: "generating side-story foundation" });
    const foundation = await this.generateAndReviewFoundation({
      generate: (reviewFeedback) => architect.generateFoundation(book, spinoffContext, reviewFeedback),
      reviewer,
      mode: "original",
      language: resolvedLanguage,
      stageLanguage,
      targetChapters: book.targetChapters,
    });

    this.logStage(stageLanguage, { zh: "写入基础设定文件", en: "writing foundation files" });
    await architect.writeFoundationFiles(bookDir, foundation, gp.numericalSystem, book.language ?? gp.language);

    this.logStage(stageLanguage, { zh: "初始化控制文档", en: "initializing control documents" });
    await this.state.ensureControlDocuments(book.id, direction?.trim() || this.config.externalContext);

    await this.initializeLongFormGovernanceAt(bookDir, book, foundation, resolvedLanguage);

    this.logStage(stageLanguage, { zh: "创建初始快照", en: "creating initial snapshot" });
    await mkdir(join(bookDir, "chapters"), { recursive: true });
    await this.state.saveChapterIndex(book.id, []);
    await this.state.snapshotState(book.id, 0);
  }

  /**
   * Create an imitation (仿写) book: an ORIGINAL story whose prose imitates the
   * voice of a reference work. The architect builds an original foundation from
   * the user's story idea; the reference text becomes the book's style_guide.md
   * so the writer mimics its style. The style guide is mandatory here (imitation
   * is the whole point), so a failure to generate it surfaces rather than being
   * silently skipped.
   */
  async initImitationBook(
    book: BookConfig,
    referenceText: string,
    storyIdea: string,
    sourceName?: string,
  ): Promise<void> {
    await this.initBook(book, { externalContext: storyIdea });
    const stageLanguage = await this.resolveBookLanguage(book);
    this.logStage(stageLanguage, { zh: "提取参考作品风格指纹", en: "extracting reference style fingerprint" });
    await this.generateStyleGuide(book.id, referenceText, sourceName?.trim() || "reference");
  }

  /** Write a single draft chapter. Saves chapter file + truth files + index + snapshot. */
  async writeDraft(bookId: string, context?: string, wordCount?: number): Promise<DraftResult> {
    const releaseLock = await this.state.acquireBookLock(bookId);
    try {
      await this.state.ensureControlDocuments(bookId);
      const book = await this.state.loadBookConfig(bookId);
      const bookDir = this.state.bookDir(bookId);
      await this.assertNoPendingStateRepair(bookId);
      const chapterNumber = await this.state.getNextChapterNumber(bookId);
      const longFormGovernance = await this.loadActiveLongFormGovernance(book, bookDir, chapterNumber, wordCount);
      const stageLanguage = await this.resolveBookLanguage(book);
      this.logStage(stageLanguage, { zh: "准备章节输入", en: "preparing chapter inputs" });
      const writeInput = await this.prepareWriteInput(
        book,
        bookDir,
        chapterNumber,
        context ?? this.config.externalContext,
        longFormGovernance,
      );

      const { profile: gp } = await this.loadGenreProfile(book.genre);
      const draftLanguage = book.language ?? gp.language;
      const lengthSpec = longFormGovernance
        ? buildLongFormLengthSpec(
            longFormGovernance.loaded.plan,
            chapterNumber,
            draftLanguage,
            wordCount,
          ) ?? buildLengthSpec(wordCount ?? book.chapterWordCount, draftLanguage)
        : buildLengthSpec(wordCount ?? book.chapterWordCount, draftLanguage);

      const writer = new WriterAgent(this.agentCtxFor("writer", bookId));
      this.logStage(stageLanguage, { zh: "撰写章节草稿", en: "writing chapter draft" });
      const output = await writer.writeChapter({
        book,
        bookDir,
        chapterNumber,
        ...writeInput,
        lengthSpec,
        ...(wordCount !== undefined ? { wordCountOverride: wordCount } : {}),
      });
      const writerCount = countChapterLength(output.content, lengthSpec.countingMode);
      let totalUsage: TokenUsageSummary = output.tokenUsage ?? {
        promptTokens: 0,
        completionTokens: 0,
        totalTokens: 0,
      };
      const normalizedDraft = await this.normalizeDraftLengthIfNeeded({
        bookId,
        chapterNumber,
        chapterContent: output.content,
        lengthSpec,
        chapterIntent: writeInput.chapterIntent,
      });
      totalUsage = PipelineRunner.addUsage(totalUsage, normalizedDraft.tokenUsage);
      const draftOutput: WriteChapterOutput = {
        ...output,
        chapterNumber,
        content: normalizedDraft.content,
        wordCount: normalizedDraft.wordCount,
        tokenUsage: totalUsage,
      };
      const draftLongFormValidation = longFormGovernance
        ? validateAndApplyLongFormChapter({
            plan: longFormGovernance.loaded.plan,
            fingerprint: longFormGovernance.loaded.fingerprint,
            state: longFormGovernance.state,
            chapterNumber,
            wordCount: draftOutput.wordCount,
            runtimeDelta: draftOutput.runtimeStateDelta,
          })
        : null;
      if (draftLongFormValidation) {
        const critical = this.toLongFormAuditIssues(draftLongFormValidation, draftLanguage)
          .filter((issue) => issue.severity === "critical");
        if (critical.length > 0) {
          throw new Error(critical.map((issue) => issue.description).join("; "));
        }
      }
      const lengthWarnings = this.buildLengthWarnings(
        chapterNumber,
        draftOutput.wordCount,
        lengthSpec,
      );
      const lengthTelemetry = this.buildLengthTelemetry({
        lengthSpec,
        writerCount,
        postWriterNormalizeCount: normalizedDraft.wordCount,
        postReviseCount: 0,
        finalCount: draftOutput.wordCount,
        normalizeApplied: normalizedDraft.applied,
        lengthWarning: lengthWarnings.length > 0,
      });
      this.logLengthWarnings(lengthWarnings);

      // Save chapter file
      const chaptersDir = join(bookDir, "chapters");
      const paddedNum = String(chapterNumber).padStart(4, "0");
      const sanitized = draftOutput.title.replace(/[/\\?%*:|"<>]/g, "").replace(/\s+/g, "_").slice(0, 50);
      const filename = `${paddedNum}_${sanitized}.md`;
      const filePath = join(chaptersDir, filename);

      const resolvedLang = book.language ?? gp.language;
      await persistChapterTransaction({
        bookDir,
        chapterNumber,
        commit: async () => {
          // Save truth files
          this.logStage(stageLanguage, { zh: "落盘草稿与真相文件", en: "persisting draft and truth files" });
          this.throwIfOperationAborted();
          await writer.saveChapter(bookDir, draftOutput, gp.numericalSystem, resolvedLang);
          await writer.saveNewTruthFiles(bookDir, draftOutput, resolvedLang);

          // Update index
          const existingIndex = await this.state.loadChapterIndex(bookId);
          const now = new Date().toISOString();
          const newEntry: ChapterMeta = {
            number: chapterNumber,
            title: draftOutput.title,
            status: "drafted",
            wordCount: draftOutput.wordCount,
            createdAt: now,
            updatedAt: now,
            auditIssues: [],
            lengthWarnings,
            lengthTelemetry,
            ...(draftOutput.tokenUsage ? { tokenUsage: draftOutput.tokenUsage } : {}),
          };
          const existingIdx = existingIndex.findIndex((e) => e.number === chapterNumber);
          const updatedIndex = existingIdx >= 0
            ? existingIndex.map((e, i) => i === existingIdx ? newEntry : e)
            : [...existingIndex, newEntry];
          this.throwIfOperationAborted();
          await this.state.saveChapterIndex(bookId, updatedIndex);
          await this.markBookActiveIfNeeded(bookId);
          await this.syncLegacyStructuredStateFromMarkdown(bookDir, chapterNumber, draftOutput);
          await this.syncNarrativeMemoryIndex(bookId, chapterNumber);

          // Snapshot
          this.logStage(stageLanguage, { zh: "更新章节索引与快照", en: "updating chapter index and snapshots" });
          this.throwIfOperationAborted();
          if (longFormGovernance && draftLongFormValidation) {
            await this.persistLongFormCommit({
              bookDir,
              governance: longFormGovernance,
              validation: draftLongFormValidation,
              chapterNumbers: updatedIndex.map((chapter) => chapter.number),
              runtimeSnapshot: draftOutput.runtimeStateSnapshot,
            });
          }
          await this.state.snapshotState(bookId, chapterNumber);
          await this.syncCurrentStateFactHistory(bookId, chapterNumber);
        },
      });

      this.schedulePostCommitEffect("chapter-complete webhook", () =>
        this.emitWebhook("chapter-complete", bookId, chapterNumber, {
          title: draftOutput.title,
          wordCount: draftOutput.wordCount,
        }));

      return {
        chapterNumber,
        title: draftOutput.title,
        wordCount: draftOutput.wordCount,
        filePath,
        lengthWarnings,
        lengthTelemetry,
        tokenUsage: draftOutput.tokenUsage,
      };
    } finally {
      await releaseLock();
    }
  }

  async planChapter(bookId: string, context?: string): Promise<PlanChapterResult> {
    const releaseLock = await this.state.acquireBookLock(bookId);
    try {
      return await this._planChapterLocked(bookId, context);
    } finally {
      await releaseLock();
    }
  }

  private async _planChapterLocked(bookId: string, context?: string): Promise<PlanChapterResult> {
    await this.state.ensureControlDocuments(bookId);
    const book = await this.state.loadBookConfig(bookId);
    const bookDir = this.state.bookDir(bookId);
    const chapterNumber = await this.state.getNextChapterNumber(bookId);
    const stageLanguage = await this.resolveBookLanguage(book);
    this.logStage(stageLanguage, { zh: "规划下一章意图", en: "planning next chapter intent" });
    const { plan } = await this.createGovernedArtifacts(
      book,
      bookDir,
      chapterNumber,
      context ?? this.config.externalContext,
      { reuseExistingIntentWhenContextMissing: false },
    );

    return {
      bookId,
      chapterNumber,
      intentPath: relativeToBookDir(bookDir, plan.runtimePath),
      goal: plan.intent.goal,
      conflicts: [],
    };
  }

  async composeChapter(bookId: string, context?: string): Promise<ComposeChapterResult> {
    const releaseLock = await this.state.acquireBookLock(bookId);
    try {
      return await this._composeChapterLocked(bookId, context);
    } finally {
      await releaseLock();
    }
  }

  private async _composeChapterLocked(bookId: string, context?: string): Promise<ComposeChapterResult> {
    await this.state.ensureControlDocuments(bookId);
    const book = await this.state.loadBookConfig(bookId);
    const bookDir = this.state.bookDir(bookId);
    const chapterNumber = await this.state.getNextChapterNumber(bookId);
    const stageLanguage = await this.resolveBookLanguage(book);
    this.logStage(stageLanguage, { zh: "组装章节运行时上下文", en: "composing chapter runtime context" });
    const { plan, composed } = await this.createGovernedArtifacts(
      book,
      bookDir,
      chapterNumber,
      context ?? this.config.externalContext,
      { reuseExistingIntentWhenContextMissing: true },
    );

    return {
      bookId,
      chapterNumber,
      intentPath: relativeToBookDir(bookDir, plan.runtimePath),
      goal: plan.intent.goal,
      conflicts: [],
      contextPath: relativeToBookDir(bookDir, composed.contextPath),
      ruleStackPath: relativeToBookDir(bookDir, composed.ruleStackPath),
      tracePath: relativeToBookDir(bookDir, composed.tracePath),
    };
  }

  /** Audit the latest (or specified) chapter and atomically persist review metadata. */
  async auditDraft(bookId: string, chapterNumber?: number): Promise<AuditResult & { readonly chapterNumber: number }> {
    const releaseLock = await this.state.acquireBookLock(bookId);
    try {
      return await this._auditDraftLocked(bookId, chapterNumber);
    } finally {
      await releaseLock();
    }
  }

  private async _auditDraftLocked(
    bookId: string,
    chapterNumber?: number,
  ): Promise<AuditResult & { readonly chapterNumber: number }> {
    const book = await this.state.loadBookConfig(bookId);
    const bookDir = this.state.bookDir(bookId);
    const targetChapter = chapterNumber ?? (await this.state.getNextChapterNumber(bookId)) - 1;
    if (targetChapter < 1) {
      throw new Error(`No chapters to audit for "${bookId}"`);
    }
    const index = await this.state.loadChapterIndex(bookId);
    const targetMeta = index.find((chapter) => chapter.number === targetChapter);
    if (targetMeta?.status === "state-degraded") {
      throw new Error(
        `Chapter ${targetChapter} is state-degraded and must be repaired or rewritten before audit.`,
      );
    }
    if (targetMeta?.status === "rejected") {
      throw new Error(
        `Chapter ${targetChapter} is rejected and must be rewritten/rebased or rolled back before audit.`,
      );
    }

    const content = await this.readChapterContent(bookDir, targetChapter);
    const auditor = new ContinuityAuditor(this.agentCtxFor("auditor", bookId));
    const { profile: gp } = await this.loadGenreProfile(book.genre);
    const language = book.language ?? gp.language;
    this.logStage(language, {
      zh: `审计第${targetChapter}章`,
      en: `auditing chapter ${targetChapter}`,
    });
    const evaluation = await this.evaluateMergedAudit({
      auditor,
      book,
      bookDir,
      chapterContent: content,
      chapterNumber: targetChapter,
      language,
    });
    const result = evaluation.auditResult;

    // Update index with audit result
    const updated = index.map((ch) =>
      ch.number === targetChapter
        ? {
            ...ch,
            status: (result.passed ? "ready-for-review" : "audit-failed") as ChapterMeta["status"],
            updatedAt: new Date().toISOString(),
            auditIssues: result.issues.map((i) => `[${i.severity}] ${i.description}`),
          }
        : ch,
    );
    const latestChapter = index.length > 0 ? Math.max(...index.map((chapter) => chapter.number)) : targetChapter;
    await persistChapterTransaction({
      bookDir,
      chapterNumber: targetChapter,
      commit: async () => {
        this.throwIfOperationAborted();
        await this.state.saveChapterIndex(bookId, updated);
        if (targetChapter === latestChapter) {
          await this.persistAuditDriftGuidance({
            bookDir,
            chapterNumber: targetChapter,
            issues: result.issues.filter((issue) => issue.severity === "critical" || issue.severity === "warning"),
            language,
          });
        }
      },
    });

    this.schedulePostCommitEffect("audit webhook", () => this.emitWebhook(
        result.passed ? "audit-passed" : "audit-failed",
        bookId,
        targetChapter,
        { summary: result.summary, issueCount: result.issues.length },
      ));

    return { ...result, chapterNumber: targetChapter };
  }

  /** Revise the latest (or specified) chapter based on audit issues. */
  async reviseDraft(
    bookId: string,
    chapterNumber?: number,
    mode: ReviseMode = DEFAULT_REVISE_MODE,
    behavior: RevisionBehaviorOptions = {},
  ): Promise<ReviseResult> {
    const releaseLock = await this.state.acquireBookLock(bookId);
    try {
      const book = await this.state.loadBookConfig(bookId);
      const bookDir = this.state.bookDir(bookId);
      const targetChapter = chapterNumber ?? (await this.state.getNextChapterNumber(bookId)) - 1;
      if (targetChapter < 1) {
        throw new Error(`No chapters to revise for "${bookId}"`);
      }

      const stageLanguage = await this.resolveBookLanguage(book);
      // Read the current audit issues from index
      this.logStage(stageLanguage, {
        zh: `加载第${targetChapter}章修订上下文`,
        en: `loading revision context for chapter ${targetChapter}`,
      });
      const index = await this.state.loadChapterIndex(bookId);
      const chapterMeta = index.find((ch) => ch.number === targetChapter);
      if (!chapterMeta) {
        throw new Error(`Chapter ${targetChapter} not found in index`);
      }
      const latestIndexedChapter = Math.max(...index.map((chapter) => chapter.number));
      if (targetChapter !== latestIndexedChapter) {
        throw new Error(
          `Revisions are limited to the latest chapter (${latestIndexedChapter}); `
          + `chapter ${targetChapter} requires replay through every later chapter.`,
        );
      }
      const earlierRejectedChapter = [...index]
        .sort((left, right) => left.number - right.number)
        .find((chapter) => chapter.number < targetChapter && chapter.status === "rejected");
      if (earlierRejectedChapter) {
        throw new Error(
          `Chapter ${earlierRejectedChapter.number} is rejected. Roll back or rebase it before revising chapter ${targetChapter}.`,
        );
      }
      const longFormGovernance = await this.loadLongFormReplayGovernance(book, bookDir, targetChapter);
      // Fail before auditor/reviser calls when a clean replay baseline is unavailable.
      await loadRuntimeStateReplayBaseline(
        bookDir,
        Math.max(0, targetChapter - 1),
        stageLanguage,
      );

      // Re-audit to get structured issues (index only stores strings)
      const content = await this.readChapterContent(bookDir, targetChapter);
      const auditor = new ContinuityAuditor(this.agentCtxFor("auditor", bookId));
      const { profile: gp } = await this.loadGenreProfile(book.genre);
      const language = book.language ?? gp.language;
      const countingMode = resolveLengthCountingMode(language);
      const reviseControlInput = (this.config.inputGovernanceMode ?? "v2") === "legacy"
        ? undefined
        : await this.createGovernedArtifacts(
          book,
          bookDir,
          targetChapter,
          this.config.externalContext,
          { reuseExistingIntentWhenContextMissing: true, longFormGovernance },
        );
      const preRevision = await this.evaluateMergedAudit({
        auditor,
        book,
        bookDir,
        chapterContent: content,
        chapterNumber: targetChapter,
        language,
        auditOptions: reviseControlInput
          ? {
              chapterIntent: reviseControlInput.plan.intentMarkdown,
              chapterMemo: reviseControlInput.plan.memo,
              contextPackage: reviseControlInput.composed.contextPackage,
              ruleStack: reviseControlInput.composed.ruleStack,
            }
          : undefined,
      });

      if (!behavior.force && preRevision.blockingCount === 0 && preRevision.aiTellCount === 0) {
        return {
          chapterNumber: targetChapter,
          wordCount: countChapterLength(content, countingMode),
          fixedIssues: [],
          applied: false,
          status: "unchanged",
          skippedReason: "No warning, critical, or AI-tell issues to fix.",
        };
      }

      const chapterLengthTarget = chapterMeta.lengthTelemetry?.target ?? book.chapterWordCount;
      const lengthLanguage = chapterMeta.lengthTelemetry?.countingMode === "en_words"
        ? "en"
        : language;
      const lengthSpec = longFormGovernance
        ? buildLongFormLengthSpec(
            longFormGovernance.loaded.plan,
            targetChapter,
            lengthLanguage,
            chapterLengthTarget,
          ) ?? buildLengthSpec(chapterLengthTarget, lengthLanguage)
        : buildLengthSpec(chapterLengthTarget, lengthLanguage);

      const reviser = new ReviserAgent(this.agentCtxFor("reviser", bookId));
      this.logStage(stageLanguage, {
        zh: `修订第${targetChapter}章`,
        en: `revising chapter ${targetChapter}`,
      });
      const reviseOutput = await reviser.reviseChapter(
        bookDir,
        content,
        targetChapter,
        preRevision.auditResult.issues,
        mode,
        book.genre,
        reviseControlInput
          ? {
              chapterIntent: reviseControlInput.plan.intentMarkdown,
              chapterMemo: reviseControlInput.plan.memo,
              chapterIntentData: reviseControlInput.plan.intent,
              contextPackage: reviseControlInput.composed.contextPackage,
              ruleStack: reviseControlInput.composed.ruleStack,
              lengthSpec,
            }
          : { lengthSpec },
      );

      if (reviseOutput.revisedContent.length === 0) {
        throw new Error("Reviser returned empty content");
      }
      // Revision acceptance is content-based. Do not spend another LLM call
      // compressing or expanding an otherwise valid revision to a target count.
      const normalizedRevision = {
        content: reviseOutput.revisedContent,
        wordCount: countChapterLength(reviseOutput.revisedContent, lengthSpec.countingMode),
        applied: false,
      };
      const postRevision = await this.evaluateMergedAudit({
        auditor,
        book,
        bookDir,
        chapterContent: normalizedRevision.content,
        chapterNumber: targetChapter,
        language,
        auditOptions: reviseControlInput
          ? {
              temperature: 0,
              chapterIntent: reviseControlInput.plan.intentMarkdown,
              chapterMemo: reviseControlInput.plan.memo,
              contextPackage: reviseControlInput.composed.contextPackage,
              ruleStack: reviseControlInput.composed.ruleStack,
              truthFileOverrides: {
                currentState: reviseOutput.updatedState !== "(状态卡未更新)" ? reviseOutput.updatedState : undefined,
                ledger: reviseOutput.updatedLedger !== "(账本未更新)" ? reviseOutput.updatedLedger : undefined,
                hooks: reviseOutput.updatedHooks !== "(伏笔池未更新)" ? reviseOutput.updatedHooks : undefined,
              },
            }
          : {
              temperature: 0,
              truthFileOverrides: {
                currentState: reviseOutput.updatedState !== "(状态卡未更新)" ? reviseOutput.updatedState : undefined,
                ledger: reviseOutput.updatedLedger !== "(账本未更新)" ? reviseOutput.updatedLedger : undefined,
                hooks: reviseOutput.updatedHooks !== "(伏笔池未更新)" ? reviseOutput.updatedHooks : undefined,
              },
            },
      });
      const effectivePostRevision = this.restoreActionableAuditIfLost(
        preRevision,
        postRevision,
      );
      let revisionAuditResult = effectivePostRevision.auditResult;
      let revisionReadyForReview = this.isRevisionReadyForHumanReview(
        effectivePostRevision.auditResult,
      );
      const revisionBaseCount = countChapterLength(content, lengthSpec.countingMode);
      const lengthWarnings: string[] = [];
      const lengthTelemetry = this.buildLengthTelemetry({
        lengthSpec,
        writerCount: revisionBaseCount,
        postWriterNormalizeCount: 0,
        postReviseCount: normalizedRevision.wordCount,
        finalCount: normalizedRevision.wordCount,
        normalizeApplied: normalizedRevision.applied,
        lengthWarning: lengthWarnings.length > 0,
      });

      const improvedBlocking = effectivePostRevision.blockingCount < preRevision.blockingCount;
      const improvedAITells = effectivePostRevision.aiTellCount < preRevision.aiTellCount;
      const blockingDidNotWorsen = effectivePostRevision.blockingCount <= preRevision.blockingCount;
      const criticalDidNotWorsen = effectivePostRevision.criticalCount <= preRevision.criticalCount;
      const aiDidNotWorsen = effectivePostRevision.aiTellCount <= preRevision.aiTellCount;
      const shouldApplyRevision = blockingDidNotWorsen
        && criticalDidNotWorsen
        && aiDidNotWorsen
        && (behavior.force || improvedBlocking || improvedAITells);

      if (!shouldApplyRevision) {
        return {
          chapterNumber: targetChapter,
          wordCount: revisionBaseCount,
          fixedIssues: [],
          applied: false,
          status: "unchanged",
          skippedReason: "Manual revision did not improve merged audit or AI-tell metrics; kept original chapter.",
        };
      }

      const revisionWriter = new WriterAgent(this.agentCtxFor("writer", bookId));
      const reviseLang = book.language ?? gp.language;
      const revisionOutcome = await persistChapterTransaction({
        bookDir,
        chapterNumber: targetChapter,
        commit: async () => {
          this.throwIfOperationAborted();
          const revisionBaseline = await loadRuntimeStateReplayBaseline(
            bookDir,
            Math.max(0, targetChapter - 1),
            reviseLang,
          );
          const rawRevisionSettlement = await revisionWriter.settleChapterState({
            book,
            bookDir,
            chapterNumber: targetChapter,
            title: chapterMeta.title,
            content: normalizedRevision.content,
            allowReapply: false,
            runtimeStateBaseSnapshot: revisionBaseline.snapshot,
            truthFileBaseSnapshot: revisionBaseline.truthFiles,
            chapterIntent: reviseControlInput?.plan.intentMarkdown,
            contextPackage: reviseControlInput?.composed.contextPackage,
            ruleStack: reviseControlInput?.composed.ruleStack,
          });
          const revisionSettlement: WriteChapterOutput = {
            ...rawRevisionSettlement,
            chapterNumber: targetChapter,
            title: chapterMeta.title,
            content: normalizedRevision.content,
            wordCount: normalizedRevision.wordCount,
          };
          const revisionStateValidation = await new StateValidatorAgent(
            this.agentCtxFor("state-validator", bookId),
          ).validate(
            normalizedRevision.content,
            targetChapter,
            revisionBaseline.truthFiles.currentState,
            revisionSettlement.updatedState,
            revisionBaseline.truthFiles.hooks,
            revisionSettlement.updatedHooks,
            language,
          );
          if (!revisionStateValidation.passed) {
            throw new Error(
              revisionStateValidation.warnings[0]?.description
              ?? `Revision state settlement failed for chapter ${targetChapter}.`,
            );
          }

          let committedAuditResult = revisionAuditResult;
          let committedReadyForReview = revisionReadyForReview;
          let revisionLongFormValidation: LongFormValidationResult | null = null;
          let revisionStateDegraded = false;
          if (longFormGovernance) {
            revisionLongFormValidation = validateAndApplyLongFormChapter({
              plan: longFormGovernance.loaded.plan,
              fingerprint: longFormGovernance.loaded.fingerprint,
              state: longFormGovernance.state,
              chapterNumber: targetChapter,
              wordCount: normalizedRevision.wordCount,
              runtimeDelta: revisionSettlement.runtimeStateDelta,
              allowReapply: false,
            });
            const longFormIssues = this.toLongFormAuditIssues(revisionLongFormValidation, language);
            if (longFormIssues.length > 0) {
              committedAuditResult = {
                ...committedAuditResult,
                passed: longFormIssues.some((issue) => issue.severity === "critical")
                  ? false
                  : committedAuditResult.passed,
                issues: [...committedAuditResult.issues, ...longFormIssues],
              };
            }
            revisionStateDegraded = longFormIssues.some((issue) => issue.severity === "critical");
            committedReadyForReview = this.isRevisionReadyForHumanReview(committedAuditResult);
          }
          this.logLengthWarnings(lengthWarnings);

          this.logStage(stageLanguage, {
            zh: `落盘第${targetChapter}章修订结果`,
            en: `persisting revision for chapter ${targetChapter}`,
          });
          const chaptersDir = join(bookDir, "chapters");
          const files = await readdir(chaptersDir);
          const paddedNum = String(targetChapter).padStart(4, "0");
          const existingFile = files.find((file) => file.startsWith(paddedNum) && file.endsWith(".md"));
          if (!existingFile) {
            throw new Error(
              `Chapter ${targetChapter} file not found in ${chaptersDir} `
              + `(expected filename starting with ${paddedNum})`,
            );
          }
          const reviseHeading = reviseLang === "en"
            ? `# Chapter ${targetChapter}: ${chapterMeta.title}`
            : `# 第${targetChapter}章 ${chapterMeta.title}`;
          this.throwIfOperationAborted();
          await writeFile(
            join(chaptersDir, existingFile),
            `${reviseHeading}\n\n${normalizedRevision.content}`,
            "utf-8",
          );

          // Persist the same structured settlement that passed long-form checks.
          // A critical keeps the revised body but leaves previous truth untouched.
          this.throwIfOperationAborted();
          if (!revisionStateDegraded) {
            await revisionWriter.saveChapter(bookDir, revisionSettlement, gp.numericalSystem, reviseLang);
            await revisionWriter.saveNewTruthFiles(bookDir, revisionSettlement, reviseLang);
            await this.syncLegacyStructuredStateFromMarkdown(bookDir, targetChapter, revisionSettlement);
          }

          const updatedIndex = index.map((chapter) =>
            chapter.number === targetChapter
              ? {
                  ...chapter,
                  status: (revisionStateDegraded
                    ? "state-degraded"
                    : committedReadyForReview ? "ready-for-review" : "audit-failed") as ChapterMeta["status"],
                  wordCount: normalizedRevision.wordCount,
                  updatedAt: new Date().toISOString(),
                  auditIssues: committedAuditResult.issues.map((issue) => `[${issue.severity}] ${issue.description}`),
                  lengthWarnings,
                  lengthTelemetry,
                  reviewNote: revisionStateDegraded
                    ? buildStateDegradedReviewNote(
                        committedReadyForReview ? "ready-for-review" : "audit-failed",
                        committedAuditResult.issues.filter((issue) => issue.category.startsWith("long-form/")),
                      )
                    : undefined,
                }
              : chapter,
          );
          this.throwIfOperationAborted();
          await this.state.saveChapterIndex(bookId, updatedIndex);
          const latestChapter = index.length > 0
            ? Math.max(...index.map((chapter) => chapter.number))
            : targetChapter;
          if (targetChapter === latestChapter) {
            await this.persistAuditDriftGuidance({
              bookDir,
              chapterNumber: targetChapter,
              issues: committedAuditResult.issues.filter(
                (issue) => issue.severity === "critical" || issue.severity === "warning",
              ),
              language,
            });
          }

          this.logStage(stageLanguage, {
            zh: `更新第${targetChapter}章索引与快照`,
            en: `updating chapter index and snapshots for chapter ${targetChapter}`,
          });
          this.throwIfOperationAborted();
          if (longFormGovernance && revisionLongFormValidation && !revisionStateDegraded) {
            await this.persistLongFormCommit({
              bookDir,
              governance: longFormGovernance,
              validation: revisionLongFormValidation,
              chapterNumbers: index.map((chapter) => chapter.number),
              runtimeSnapshot: revisionSettlement.runtimeStateSnapshot,
            });
          }
          if (!revisionStateDegraded) {
            await this.state.snapshotState(bookId, targetChapter);
            await this.syncNarrativeMemoryIndex(bookId, targetChapter);
            await this.syncCurrentStateFactHistory(bookId, targetChapter);
          }
          return {
            auditResult: committedAuditResult,
            readyForReview: committedReadyForReview,
            stateDegraded: revisionStateDegraded,
          };
        },
      });

      this.schedulePostCommitEffect("revision-complete webhook", () =>
        this.emitWebhook("revision-complete", bookId, targetChapter, {
          wordCount: normalizedRevision.wordCount,
          fixedCount: reviseOutput.fixedIssues.length,
        }));

      return {
        chapterNumber: targetChapter,
        wordCount: normalizedRevision.wordCount,
        fixedIssues: reviseOutput.fixedIssues,
        applied: true,
        status: revisionOutcome.stateDegraded
          ? "state-degraded"
          : revisionOutcome.readyForReview ? "ready-for-review" : "audit-failed",
        lengthWarnings,
        lengthTelemetry,
      };
    } finally {
      await releaseLock();
    }
  }

  /** Read all truth files for a book. */
  async readTruthFiles(bookId: string): Promise<TruthFiles> {
    const bookDir = this.state.bookDir(bookId);
    const storyDir = join(bookDir, "story");
    const readSafe = async (path: string): Promise<string> => {
      try {
        return await readFile(path, "utf-8");
      } catch {
        return "(文件不存在)";
      }
    };

    // Phase 5: prefer the new prose outline files; fall back to legacy paths.
    const readOutline = async (newRel: string, legacyRel: string): Promise<string> => {
      const preferred = await readSafe(join(storyDir, newRel));
      if (preferred.trim() && preferred !== "(文件不存在)") return preferred;
      return readSafe(join(storyDir, legacyRel));
    };

    const [currentState, particleLedger, pendingHooks, storyBible, volumeOutline, bookRules] =
      await Promise.all([
        readSafe(join(storyDir, "current_state.md")),
        readSafe(join(storyDir, "particle_ledger.md")),
        readSafe(join(storyDir, "pending_hooks.md")),
        readOutline("outline/story_frame.md", "story_bible.md"),
        readOutline("outline/volume_map.md", "volume_outline.md"),
        readSafe(join(storyDir, "book_rules.md")),
      ]);

    return { currentState, particleLedger, pendingHooks, storyBible, volumeOutline, bookRules };
  }

  /** Get book status overview. */
  async getBookStatus(bookId: string): Promise<BookStatusInfo> {
    const book = await this.state.loadBookConfig(bookId);
    const chapters = await this.state.loadChapterIndex(bookId);
    const nextChapter = await this.state.getNextChapterNumber(bookId);
    const totalWords = chapters.reduce((sum, ch) => sum + ch.wordCount, 0);

    return {
      bookId,
      title: book.title,
      genre: book.genre,
      platform: book.platform,
      status: book.status,
      chaptersWritten: chapters.length,
      totalWords,
      nextChapter,
      chapters: [...chapters],
    };
  }

  /** Commit a reviewable chapter through the same state boundary as writes. */
  async approveChapter(bookId: string, chapterNumber: number): Promise<ReviewMutationResult> {
    const releaseLock = await this.state.acquireBookLock(bookId);
    try {
      const index = [...(await this.state.loadChapterIndex(bookId))];
      const targetIndex = index.findIndex((chapter) => chapter.number === chapterNumber);
      if (targetIndex < 0) throw new Error(`Chapter ${chapterNumber} not found in "${bookId}"`);
      const target = index[targetIndex]!;
      if (target.status === "state-degraded") {
        throw new Error(
          `Chapter ${chapterNumber} is state-degraded and must be repaired or rewritten before approval.`,
        );
      }
      if (target.status === "rejected") {
        throw new Error(
          `Chapter ${chapterNumber} is rejected and must be rewritten/rebased or rolled back before approval.`,
        );
      }
      if (target.status !== "approved") {
        index[targetIndex] = {
          ...target,
          status: "approved",
          updatedAt: new Date().toISOString(),
        };
        this.throwIfOperationAborted();
        await this.state.saveChapterIndex(bookId, index);
      }
      return {
        bookId,
        chapterNumber,
        status: "approved",
        discarded: [],
      };
    } finally {
      await releaseLock();
    }
  }

  /**
   * Reject a chapter inside core. The default rolls the book back to the
   * previous snapshot; keepSubsequent is reserved for Publisher's review gate
   * when later chapters are intentionally retained as independent drafts.
   */
  async rejectChapter(
    bookId: string,
    chapterNumber: number,
    options: { readonly keepSubsequent?: boolean; readonly reason?: string } = {},
  ): Promise<ReviewMutationResult> {
    const releaseLock = await this.state.acquireBookLock(bookId);
    try {
      const index = await this.state.loadChapterIndex(bookId);
      const targetIndex = index.findIndex((chapter) => chapter.number === chapterNumber);
      if (targetIndex < 0) throw new Error(`Chapter ${chapterNumber} not found in "${bookId}"`);
      const reason = options.reason?.trim() || "Rejected without reason";
      if (options.keepSubsequent) {
        if (index[targetIndex]!.status === "state-degraded") {
          throw new Error(
            `Chapter ${chapterNumber} is state-degraded; reject it with rollback or repair/rewrite it first.`,
          );
        }
        const updatedAt = new Date().toISOString();
        const updated = index.map((chapter) => chapter.number < chapterNumber
          ? chapter
          : {
              ...chapter,
              status: "rejected" as const,
              reviewNote: chapter.number === chapterNumber
                ? reason
                : `Stale after rejection of chapter ${chapterNumber}: ${reason}`,
              updatedAt,
            });
        this.throwIfOperationAborted();
        await this.state.saveChapterIndex(bookId, updated);
        return { bookId, chapterNumber, status: "rejected", discarded: [], reason };
      }

      const rollbackTarget = chapterNumber - 1;
      this.throwIfOperationAborted();
      const discarded = await withBookTreeTransaction(
        this.state.bookDir(bookId),
        () => this.state.rollbackToChapter(bookId, rollbackTarget),
      );
      return {
        bookId,
        chapterNumber,
        status: "rejected",
        discarded,
        rolledBackTo: rollbackTarget,
        reason,
      };
    } finally {
      await releaseLock();
    }
  }

  // ---------------------------------------------------------------------------
  // Full pipeline (convenience — runs draft + audit + revise in one shot)
  // ---------------------------------------------------------------------------

  async writeNextChapter(bookId: string, wordCount?: number, temperatureOverride?: number): Promise<ChapterPipelineResult> {
    const releaseLock = await this.state.acquireBookLock(bookId);
    try {
      return await this._writeNextChapterLocked(bookId, wordCount, temperatureOverride, this.config.externalContext);
    } finally {
      await releaseLock();
    }
  }

  async repairChapterState(bookId: string, chapterNumber?: number): Promise<ChapterPipelineResult> {
    const releaseLock = await this.state.acquireBookLock(bookId);
    try {
      return await this._repairChapterStateLocked(bookId, chapterNumber);
    } finally {
      await releaseLock();
    }
  }

  async resyncChapterArtifacts(bookId: string, chapterNumber?: number): Promise<ChapterPipelineResult> {
    const releaseLock = await this.state.acquireBookLock(bookId);
    try {
      return await this._resyncChapterArtifactsLocked(bookId, chapterNumber);
    } finally {
      await releaseLock();
    }
  }

  private async _writeNextChapterLocked(
    bookId: string,
    wordCount?: number,
    temperatureOverride?: number,
    externalContext?: string,
  ): Promise<ChapterPipelineResult> {
    await this.state.ensureControlDocuments(bookId);
    const book = await this.state.loadBookConfig(bookId);
    const bookDir = this.state.bookDir(bookId);
    await this.assertNoPendingStateRepair(bookId);
    const chapterNumber = await this.state.getNextChapterNumber(bookId);
    const longFormGovernance = await this.loadActiveLongFormGovernance(book, bookDir, chapterNumber, wordCount);
    const stageLanguage = await this.resolveBookLanguage(book);
    this.logStage(stageLanguage, { zh: "准备章节输入", en: "preparing chapter inputs" });
    const writeInput = await this.prepareWriteInput(
      book,
      bookDir,
      chapterNumber,
      externalContext,
      longFormGovernance,
    );
    const reducedControlInput = writeInput.chapterIntent && writeInput.contextPackage && writeInput.ruleStack
      ? {
          chapterIntent: writeInput.chapterIntent,
          chapterMemo: writeInput.chapterMemo,
          chapterIntentData: writeInput.chapterIntentData,
          contextPackage: writeInput.contextPackage,
          ruleStack: writeInput.ruleStack,
        }
      : undefined;
    const { profile: gp } = await this.loadGenreProfile(book.genre);
    const pipelineLang = book.language ?? gp.language;
    const lengthSpec = longFormGovernance
      ? buildLongFormLengthSpec(
          longFormGovernance.loaded.plan,
          chapterNumber,
          pipelineLang,
          wordCount,
        ) ?? buildLengthSpec(wordCount ?? book.chapterWordCount, pipelineLang)
      : buildLengthSpec(wordCount ?? book.chapterWordCount, pipelineLang);
    const {
      detectTemporalContinuityBreak,
      normalizePostWriteSurface,
      validatePostWrite: postWriteValidate,
    } = await import("../agents/post-write-validator.js");
    const { validateHookLedger } = await import("../utils/hook-ledger-validator.js");
    const { readBookRules } = await import("../agents/rules-reader.js");
    const parsedBookRules = (await readBookRules(bookDir))?.rules ?? null;
    const recentChaptersForValidation = await this.loadRecentChapterTextForValidation(bookDir, 1);

    // 1. Write chapter
    const writer = new WriterAgent(this.agentCtxFor("writer", bookId));
    this.logStage(stageLanguage, { zh: "撰写章节草稿", en: "writing chapter draft" });
    const output = await writer.writeChapter({
      book,
      bookDir,
      chapterNumber,
      ...writeInput,
      lengthSpec,
      ...(wordCount !== undefined ? { wordCountOverride: wordCount } : {}),
      ...(temperatureOverride ? { temperatureOverride } : {}),
    });
    const writerCount = countChapterLength(output.content, lengthSpec.countingMode);

    // Token usage accumulator
    let totalUsage: TokenUsageSummary = output.tokenUsage ?? { promptTokens: 0, completionTokens: 0, totalTokens: 0 };
    let finalContent: string;
    let finalWordCount: number;
    let revised: boolean;
    let auditResult: AuditResult;
    let postReviseCount: number;
    let normalizeApplied: boolean;
    let preAuditNormalizedWordCount: number | undefined;

    if ((this.config.chapterReviewMode ?? "auto") === "manual") {
      // C4a: write-only checkpoint. Stop right after the draft — skip the
      // automatic audit→revise loop (which silently doubled chapter time when it
      // fired). The user drives review / revise / accept afterwards.
      this.logStage(stageLanguage, { zh: "写完即停（手动审查模式）", en: "draft written — stopping for manual review" });
      finalContent = normalizePostWriteSurface(output.content, pipelineLang);
      this.assertChapterContentNotEmpty(finalContent, chapterNumber, "manual write");
      finalWordCount = countChapterLength(finalContent, lengthSpec.countingMode);
      revised = false;
      postReviseCount = 0;
      normalizeApplied = finalContent !== output.content;
      preAuditNormalizedWordCount = writerCount;
      auditResult = {
        passed: false,
        issues: [],
        summary: pipelineLang === "en"
          ? "Not reviewed yet (manual mode: stopped after writing — run review when ready)."
          : "尚未审查（手动模式：写完即停，需要时点“审查”）。",
      };
    } else {
      const auditor = new ContinuityAuditor(this.agentCtxFor("auditor", bookId));
      const reviewResult = await runChapterReviewCycle({
        book: { genre: book.genre },
        bookDir,
        chapterNumber,
        initialOutput: output,
        reducedControlInput,
        lengthSpec,
        initialUsage: totalUsage,
        createReviser: () => new ReviserAgent(this.agentCtxFor("reviser", bookId)),
        auditor,
        normalizeDraftLengthIfNeeded: (chapterContent) => this.normalizeDraftLengthIfNeeded({
          bookId,
          chapterNumber,
          chapterContent,
          lengthSpec,
          chapterIntent: writeInput.chapterIntent,
        }),
        normalizePostWriteSurface: (chapterContent) =>
          normalizePostWriteSurface(chapterContent, pipelineLang),
        assertChapterContentNotEmpty: (content, stage) =>
          this.assertChapterContentNotEmpty(content, chapterNumber, stage),
        addUsage: PipelineRunner.addUsage,
        analyzeAITells: (content) => analyzeAITells(content, pipelineLang),
        analyzeSensitiveWords: (content) => analyzeSensitiveWords(content, undefined, pipelineLang),
        runPostWriteChecks: (content) => {
          const baseIssues = [
            ...postWriteValidate(content, gp, parsedBookRules, pipelineLang),
            ...detectTemporalContinuityBreak(content, recentChaptersForValidation, pipelineLang),
          ]
            .filter((v) => v.severity === "error")
            .map((v) => ({
              severity: "critical" as const,
              category: v.rule,
              description: v.description,
              suggestion: v.suggestion,
            }));
          // Phase 9-3: verify the draft acts on every hook the memo committed to.
          const memoBody = writeInput.chapterMemo?.body ?? "";
          const ledgerIssues = memoBody
            ? validateHookLedger(memoBody, content)
            : [];
          return [...baseIssues, ...ledgerIssues];
        },
        maxReviewIterations: this.config.writingReviewRetries,
        logWarn: (message) => this.logWarn(pipelineLang, message),
        logStage: (message) => this.logStage(stageLanguage, message),
      });
      totalUsage = reviewResult.totalUsage;
      finalContent = reviewResult.finalContent;
      finalWordCount = reviewResult.finalWordCount;
      revised = reviewResult.revised;
      auditResult = reviewResult.auditResult;
      postReviseCount = reviewResult.postReviseCount;
      normalizeApplied = reviewResult.normalizeApplied;
      preAuditNormalizedWordCount = reviewResult.preAuditNormalizedWordCount;
    }

    // 4. Save the final chapter and truth files from a single persistence source
    this.logStage(stageLanguage, { zh: "落盘最终章节", en: "persisting final chapter" });
    this.logStage(stageLanguage, { zh: "生成最终真相文件", en: "rebuilding final truth files" });
    const chapterIndexBeforePersist = await this.state.loadChapterIndex(bookId);
    const { resolveDuplicateTitle } = await import("../agents/post-write-validator.js");
    const initialTitleResolution = resolveDuplicateTitle(
      output.title,
      chapterIndexBeforePersist.map((chapter) => chapter.title),
      pipelineLang,
      { content: finalContent },
    );
    let persistenceOutput = await this.buildPersistenceOutput(
      bookId,
      book,
      bookDir,
      chapterNumber,
      initialTitleResolution.title === output.title
        ? output
        : { ...output, title: initialTitleResolution.title },
      finalContent,
      lengthSpec.countingMode,
      reducedControlInput,
    );
    persistenceOutput = { ...persistenceOutput, chapterNumber };
    const finalTitleResolution = resolveDuplicateTitle(
      persistenceOutput.title,
      chapterIndexBeforePersist.map((chapter) => chapter.title),
      pipelineLang,
      { content: finalContent },
    );
    if (finalTitleResolution.title !== persistenceOutput.title) {
      persistenceOutput = {
        ...persistenceOutput,
        title: finalTitleResolution.title,
      };
    }
    if (persistenceOutput.title !== output.title) {
      const description = pipelineLang === "en"
        ? `Chapter title "${output.title}" was auto-adjusted to "${persistenceOutput.title}".`
        : `章节标题"${output.title}"已自动调整为"${persistenceOutput.title}"。`;
      this.config.logger?.warn(`[title] ${description}`);
      auditResult = {
        ...auditResult,
        issues: [...auditResult.issues, {
          severity: "warning",
          category: "title-dedup",
          description,
          suggestion: pipelineLang === "en"
            ? "If the auto-renamed title is weak, revise the chapter title manually."
            : "如果自动改名不理想，可以在后续手动修订章节标题。",
        }],
      };
    }
    const longSpanFatigue = await analyzeLongSpanFatigue({
      bookDir,
      chapterNumber,
      chapterContent: finalContent,
      chapterSummary: persistenceOutput.chapterSummary,
      language: pipelineLang,
    });
    auditResult = {
      ...auditResult,
      issues: [
        ...auditResult.issues,
        ...longSpanFatigue.issues,
        ...(persistenceOutput.hookHealthIssues ?? []),
      ],
    };
    finalWordCount = persistenceOutput.wordCount;
    const lengthWarnings = this.buildLengthWarnings(
      chapterNumber,
      finalWordCount,
      lengthSpec,
    );
    const lengthTelemetry = this.buildLengthTelemetry({
      lengthSpec,
      writerCount,
      postWriterNormalizeCount: preAuditNormalizedWordCount,
      postReviseCount,
      finalCount: finalWordCount,
      normalizeApplied,
      lengthWarning: lengthWarnings.length > 0,
    });
    this.logLengthWarnings(lengthWarnings);

    // 4.1 Validate settler output before writing
    this.logStage(stageLanguage, { zh: "校验真相文件变更", en: "validating truth file updates" });
    const storyDir = join(bookDir, "story");
    const [oldState, oldHooks, oldLedger, authorityStoryFrame, authorityBookRules, authorityChapterSummaries] = await Promise.all([
      readFile(join(storyDir, "current_state.md"), "utf-8").catch(() => ""),
      readFile(join(storyDir, "pending_hooks.md"), "utf-8").catch(() => ""),
      readFile(join(storyDir, "particle_ledger.md"), "utf-8").catch(() => ""),
      readStoryFrame(bookDir).catch(() => ""),
      readFile(join(storyDir, "book_rules.md"), "utf-8").catch(() => ""),
      readFile(join(storyDir, "chapter_summaries.md"), "utf-8").catch(() => ""),
    ]);
    const validator = new StateValidatorAgent(this.agentCtxFor("state-validator", bookId));
    const truthValidation = await validateChapterTruthPersistence({
      writer,
      validator,
      book,
      bookDir,
      chapterNumber,
      title: persistenceOutput.title,
      content: finalContent,
      persistenceOutput,
      auditResult,
      previousTruth: {
        oldState,
        oldHooks,
        oldLedger,
      },
      authorityContext: {
        storyFrame: authorityStoryFrame,
        bookRules: authorityBookRules,
        chapterSummaries: authorityChapterSummaries,
      },
      reducedControlInput,
      language: pipelineLang,
      logWarn: (message) => this.logWarn(pipelineLang, message),
      logger: this.config.logger,
    });
    let chapterStatus: ChapterPipelineResult["status"] | null = truthValidation.chapterStatus;
    let degradedIssues: ReadonlyArray<AuditIssue> = truthValidation.degradedIssues;
    persistenceOutput = truthValidation.persistenceOutput;
    auditResult = truthValidation.auditResult;

    // 4.2 Final paragraph shape check on persisted content (post-normalize, post-revise)
    {
      const {
        detectParagraphLengthDrift,
        detectParagraphShapeWarnings,
      } = await import("../agents/post-write-validator.js");
      const chapDir = join(bookDir, "chapters");
      const recentFiles = (await readdir(chapDir).catch(() => [] as string[]))
        .filter((f) => f.endsWith(".md") && /^\d{4}/.test(f))
        .sort()
        .slice(-5);
      const recentContent = (await Promise.all(
        recentFiles.map((f) => readFile(join(chapDir, f), "utf-8").catch(() => "")),
      )).join("\n\n");
      const paragraphIssues = [
        ...detectParagraphShapeWarnings(finalContent, pipelineLang),
        ...detectParagraphLengthDrift(finalContent, recentContent, pipelineLang),
      ];
      if (paragraphIssues.length > 0) {
        for (const issue of paragraphIssues) {
          this.config.logger?.warn(`[paragraph] ${issue.description}`);
        }
        auditResult = {
          ...auditResult,
          issues: [...auditResult.issues, ...paragraphIssues.map((v) => ({
            severity: v.severity as "warning",
            category: "paragraph-shape",
            description: v.description,
            suggestion: v.suggestion,
          }))],
        };
      }
    }

    let longFormValidation: LongFormValidationResult | null = null;
    if (longFormGovernance) {
      longFormValidation = validateAndApplyLongFormChapter({
        plan: longFormGovernance.loaded.plan,
        fingerprint: longFormGovernance.loaded.fingerprint,
        state: longFormGovernance.state,
        chapterNumber,
        wordCount: finalWordCount,
        runtimeDelta: persistenceOutput.runtimeStateDelta,
      });
      const longFormAuditIssues = this.toLongFormAuditIssues(longFormValidation, pipelineLang);
      const criticalLongFormIssues = longFormAuditIssues.filter((issue) => issue.severity === "critical");
      if (longFormAuditIssues.length > 0) {
        auditResult = {
          ...auditResult,
          passed: criticalLongFormIssues.length > 0 ? false : auditResult.passed,
          issues: [...auditResult.issues, ...longFormAuditIssues],
        };
      }
      if (criticalLongFormIssues.length > 0) {
        chapterStatus = "state-degraded";
        degradedIssues = [...degradedIssues, ...criticalLongFormIssues];
        persistenceOutput = buildStateDegradedPersistenceOutput({
          output: persistenceOutput,
          oldState,
          oldHooks,
          oldLedger,
        });
      }
    }

    const resolvedStatus = chapterStatus ?? (auditResult.passed ? "ready-for-review" : "audit-failed");
    this.throwIfOperationAborted();
    await persistChapterTransaction({
      bookDir,
      chapterNumber,
      commit: async () => {
        await persistChapterArtifacts({
          chapterNumber,
          chapterTitle: persistenceOutput.title,
          status: resolvedStatus,
          auditResult,
          finalWordCount,
          lengthWarnings,
          lengthTelemetry,
          degradedIssues,
          tokenUsage: totalUsage,
          loadChapterIndex: () => this.state.loadChapterIndex(bookId),
          saveChapter: () => {
            this.throwIfOperationAborted();
            return writer.saveChapter(bookDir, persistenceOutput, gp.numericalSystem, pipelineLang);
          },
          saveTruthFiles: async () => {
            this.throwIfOperationAborted();
            await writer.saveNewTruthFiles(bookDir, persistenceOutput, pipelineLang);
            await this.promotePersistedHooks(bookDir, chapterNumber);
          },
          saveChapterIndex: (index) => {
            this.throwIfOperationAborted();
            return this.state.saveChapterIndex(bookId, index);
          },
          markBookActiveIfNeeded: async () => {
            this.throwIfOperationAborted();
            await this.markBookActiveIfNeeded(bookId);
            if (resolvedStatus !== "state-degraded") {
              await this.syncLegacyStructuredStateFromMarkdown(bookDir, chapterNumber, persistenceOutput);
              this.logStage(stageLanguage, { zh: "同步记忆索引", en: "syncing memory indexes" });
              await this.syncNarrativeMemoryIndex(bookId, chapterNumber);
            }
          },
          persistAuditDriftGuidance: (issues) => {
            this.throwIfOperationAborted();
            return this.persistAuditDriftGuidance({
              bookDir,
              chapterNumber,
              issues,
              language: stageLanguage,
            });
          },
          snapshotState: () => {
            this.throwIfOperationAborted();
            return longFormGovernance && resolvedStatus !== "state-degraded"
              ? Promise.resolve()
              : this.state.snapshotState(bookId, chapterNumber);
          },
          syncCurrentStateFactHistory: () => {
            this.throwIfOperationAborted();
            return longFormGovernance && resolvedStatus !== "state-degraded"
              ? Promise.resolve()
              : this.syncCurrentStateFactHistory(bookId, chapterNumber);
          },
          logSnapshotStage: () =>
            this.logStage(stageLanguage, { zh: "更新章节索引与快照", en: "updating chapter index and snapshots" }),
        });

        this.throwIfOperationAborted();
        if (longFormGovernance && longFormValidation && resolvedStatus !== "state-degraded") {
          await this.persistLongFormCommit({
            bookDir,
            governance: longFormGovernance,
            validation: longFormValidation,
            chapterNumbers: [...chapterIndexBeforePersist.map((chapter) => chapter.number), chapterNumber],
            runtimeSnapshot: persistenceOutput.runtimeStateSnapshot,
          });
          await this.state.snapshotState(bookId, chapterNumber);
          await this.syncCurrentStateFactHistory(bookId, chapterNumber);
        }
      },
    });

    // 6. Send notification
    if (this.config.notifyChannels && this.config.notifyChannels.length > 0) {
      const statusEmoji = resolvedStatus === "state-degraded"
        ? "🧯"
        : auditResult.passed ? "✅" : "⚠️";
      const chapterLength = formatLengthCount(finalWordCount, lengthSpec.countingMode);
      this.schedulePostCommitEffect("chapter notification", () =>
        dispatchNotification(this.config.notifyChannels!, {
          title: `${statusEmoji} ${book.title} 第${chapterNumber}章`,
          body: [
            `**${persistenceOutput.title}** | ${chapterLength}`,
            revised ? "📝 已自动修正" : "",
            resolvedStatus === "state-degraded"
              ? "状态结算: 已降级保存，需先修复 state 再继续"
              : `审稿: ${auditResult.passed ? "通过" : "需人工审核"}`,
            ...auditResult.issues
              .filter((i) => i.severity !== "info")
              .map((i) => `- [${i.severity}] ${i.description}`),
          ]
            .filter(Boolean)
            .join("\n"),
        }));
    }

    this.schedulePostCommitEffect("pipeline-complete webhook", () =>
      this.emitWebhook("pipeline-complete", bookId, chapterNumber, {
        title: persistenceOutput.title,
        wordCount: finalWordCount,
        passed: auditResult.passed,
        revised,
        status: resolvedStatus,
      }));

    return {
      chapterNumber,
      title: persistenceOutput.title,
      wordCount: finalWordCount,
      auditResult,
      revised,
      status: resolvedStatus,
      lengthWarnings,
      lengthTelemetry,
      tokenUsage: totalUsage,
    };
  }

  private async _repairChapterStateLocked(bookId: string, chapterNumber?: number): Promise<ChapterPipelineResult> {
    const book = await this.state.loadBookConfig(bookId);
    const bookDir = this.state.bookDir(bookId);
    const stageLanguage = await this.resolveBookLanguage(book);
    const index = [...(await this.state.loadChapterIndex(bookId))];
    if (index.length === 0) {
      throw new Error(`Book "${bookId}" has no persisted chapters to repair.`);
    }

    const targetChapter = chapterNumber ?? index[index.length - 1]!.number;
    const targetIndex = index.findIndex((chapter) => chapter.number === targetChapter);
    if (targetIndex < 0) {
      throw new Error(`Chapter ${targetChapter} not found in "${bookId}".`);
    }
    const targetMeta = index[targetIndex]!;
    const latestChapter = Math.max(...index.map((chapter) => chapter.number));
    if (targetMeta.status !== "state-degraded") {
      throw new Error(`Chapter ${targetChapter} is not state-degraded.`);
    }
    if (targetChapter !== latestChapter) {
      throw new Error(`Only the latest state-degraded chapter can be repaired safely (latest is ${latestChapter}).`);
    }
    const longFormGovernance = await this.loadLongFormReplayGovernance(book, bookDir, targetChapter);

    this.logStage(stageLanguage, { zh: "修复章节状态结算", en: "repairing chapter state settlement" });
    const { profile: gp } = await this.loadGenreProfile(book.genre);
    const pipelineLang = book.language ?? gp.language;
    const content = await this.readChapterContent(bookDir, targetChapter);
    const storyDir = join(bookDir, "story");
    const [oldState, oldHooks] = await Promise.all([
      readFile(join(storyDir, "current_state.md"), "utf-8").catch(() => ""),
      readFile(join(storyDir, "pending_hooks.md"), "utf-8").catch(() => ""),
    ]);

    const writer = new WriterAgent(this.agentCtxFor("writer", bookId));
    let repairedOutput = await writer.settleChapterState({
      book,
      bookDir,
      chapterNumber: targetChapter,
      title: targetMeta.title,
      content,
      allowReapply: !longFormGovernance,
      runtimeStateBaseSnapshot: longFormGovernance?.runtimeBaseSnapshot,
    });
    const validator = new StateValidatorAgent(this.agentCtxFor("state-validator", bookId));
    let validation = await validator.validate(
      content,
      targetChapter,
      oldState,
      repairedOutput.updatedState,
      oldHooks,
      repairedOutput.updatedHooks,
      pipelineLang,
    );

    if (!validation.passed) {
      const recovery = await retrySettlementAfterValidationFailure({
        writer,
        validator,
        book,
        bookDir,
        chapterNumber: targetChapter,
        title: targetMeta.title,
        content,
        oldState,
        oldHooks,
        originalValidation: validation,
        language: pipelineLang,
        logWarn: (message) => this.logWarn(pipelineLang, message),
        logger: this.config.logger,
        runtimeStateBaseSnapshot: longFormGovernance?.runtimeBaseSnapshot,
        allowReapply: !longFormGovernance,
      });
      if (recovery.kind !== "recovered") {
        throw new Error(
          recovery.issues[0]?.description
            ?? `State repair still failed for chapter ${targetChapter}.`,
        );
      }
      repairedOutput = recovery.output;
      validation = recovery.validation;
    }

    if (!validation.passed) {
      throw new Error(`State repair still failed for chapter ${targetChapter}.`);
    }

    const longFormValidation = longFormGovernance
      ? validateAndApplyLongFormChapter({
          plan: longFormGovernance.loaded.plan,
          fingerprint: longFormGovernance.loaded.fingerprint,
          state: longFormGovernance.state,
          chapterNumber: targetChapter,
          wordCount: targetMeta.wordCount,
          runtimeDelta: repairedOutput.runtimeStateDelta,
          allowReapply: false,
        })
      : null;
    if (longFormValidation) {
      const longFormCritical = this.toLongFormAuditIssues(longFormValidation, pipelineLang)
        .filter((issue) => issue.severity === "critical");
      if (longFormCritical.length > 0) {
        throw new Error(longFormCritical.map((issue) => issue.description).join("; "));
      }
    }

    const baseStatus = resolveStateDegradedBaseStatus(targetMeta);
    await persistChapterTransaction({
      bookDir,
      chapterNumber: targetChapter,
      commit: async () => {
        this.throwIfOperationAborted();
        await writer.saveChapter(bookDir, repairedOutput, gp.numericalSystem, pipelineLang);
        await writer.saveNewTruthFiles(bookDir, repairedOutput, pipelineLang);
        await this.syncLegacyStructuredStateFromMarkdown(bookDir, targetChapter, repairedOutput);
        await this.syncNarrativeMemoryIndex(bookId, targetChapter);
        this.throwIfOperationAborted();
        if (longFormGovernance && longFormValidation) {
          await this.persistLongFormCommit({
            bookDir,
            governance: longFormGovernance,
            validation: longFormValidation,
            chapterNumbers: index.map((chapter) => chapter.number),
            runtimeSnapshot: repairedOutput.runtimeStateSnapshot,
          });
        }
        await this.state.snapshotState(bookId, targetChapter);
        await this.syncCurrentStateFactHistory(bookId, targetChapter);

        const degradedMetadata = parseStateDegradedReviewNote(targetMeta.reviewNote);
        const injectedIssues = new Set(degradedMetadata?.injectedIssues ?? []);
        index[targetIndex] = {
          ...targetMeta,
          status: baseStatus,
          updatedAt: new Date().toISOString(),
          auditIssues: targetMeta.auditIssues.filter((issue) => !injectedIssues.has(issue)),
          reviewNote: undefined,
        };
        this.throwIfOperationAborted();
        await this.state.saveChapterIndex(bookId, index);
      },
    });
    const repairedPassesAudit = baseStatus !== "audit-failed";
    return {
      chapterNumber: targetChapter,
      title: targetMeta.title,
      wordCount: targetMeta.wordCount,
      auditResult: {
        passed: repairedPassesAudit,
        issues: [],
        summary: repairedPassesAudit ? "state repaired" : "state repaired but chapter still needs review",
      },
      revised: false,
      status: baseStatus,
      lengthWarnings: targetMeta.lengthWarnings,
      lengthTelemetry: targetMeta.lengthTelemetry,
      tokenUsage: targetMeta.tokenUsage,
    };
  }

  private async _resyncChapterArtifactsLocked(bookId: string, chapterNumber?: number): Promise<ChapterPipelineResult> {
    const book = await this.state.loadBookConfig(bookId);
    const bookDir = this.state.bookDir(bookId);
    const stageLanguage = await this.resolveBookLanguage(book);
    const index = [...(await this.state.loadChapterIndex(bookId))];
    if (index.length === 0) {
      throw new Error(`Book "${bookId}" has no persisted chapters to sync.`);
    }

    const targetChapter = chapterNumber ?? index[index.length - 1]!.number;
    const targetIndex = index.findIndex((chapter) => chapter.number === targetChapter);
    if (targetIndex < 0) {
      throw new Error(`Chapter ${targetChapter} not found in "${bookId}".`);
    }

    const targetMeta = index[targetIndex]!;
    const latestChapter = Math.max(...index.map((chapter) => chapter.number));
    if (targetChapter !== latestChapter) {
      throw new Error(`Only the latest persisted chapter can be synced safely (latest is ${latestChapter}).`);
    }
    const longFormGovernance = await this.loadLongFormReplayGovernance(book, bookDir, targetChapter);

    this.logStage(stageLanguage, { zh: "根据已编辑正文同步真相文件与索引", en: "syncing truth files and indexes from edited chapter body" });
    const { profile: gp } = await this.loadGenreProfile(book.genre);
    const pipelineLang = book.language ?? gp.language;
    const content = await this.readChapterContent(bookDir, targetChapter);
    const storyDir = join(bookDir, "story");
    const [oldState, oldHooks] = await Promise.all([
      readFile(join(storyDir, "current_state.md"), "utf-8").catch(() => ""),
      readFile(join(storyDir, "pending_hooks.md"), "utf-8").catch(() => ""),
    ]);

    const reducedControlInput = (this.config.inputGovernanceMode ?? "v2") === "legacy"
      ? undefined
      : await this.createGovernedArtifacts(
        book,
        bookDir,
        targetChapter,
        this.config.externalContext,
        { reuseExistingIntentWhenContextMissing: true, longFormGovernance },
      );

    const writer = new WriterAgent(this.agentCtxFor("writer", bookId));
    let syncedOutput = await writer.settleChapterState({
      book,
      bookDir,
      chapterNumber: targetChapter,
      title: targetMeta.title,
      content,
      chapterIntent: reducedControlInput?.plan.intentMarkdown,
      contextPackage: reducedControlInput?.composed.contextPackage,
      ruleStack: reducedControlInput?.composed.ruleStack,
      allowReapply: !longFormGovernance,
      runtimeStateBaseSnapshot: longFormGovernance?.runtimeBaseSnapshot,
    });
    const validator = new StateValidatorAgent(this.agentCtxFor("state-validator", bookId));
    let validation = await validator.validate(
      content,
      targetChapter,
      oldState,
      syncedOutput.updatedState,
      oldHooks,
      syncedOutput.updatedHooks,
      pipelineLang,
    );

    if (!validation.passed) {
      const recovery = await retrySettlementAfterValidationFailure({
        writer,
        validator,
        book,
        bookDir,
        chapterNumber: targetChapter,
        title: targetMeta.title,
        content,
        reducedControlInput: reducedControlInput
          ? {
              chapterIntent: reducedControlInput.plan.intentMarkdown,
              contextPackage: reducedControlInput.composed.contextPackage,
              ruleStack: reducedControlInput.composed.ruleStack,
            }
          : undefined,
        oldState,
        oldHooks,
        originalValidation: validation,
        language: pipelineLang,
        logWarn: (message) => this.logWarn(pipelineLang, message),
        logger: this.config.logger,
        runtimeStateBaseSnapshot: longFormGovernance?.runtimeBaseSnapshot,
        allowReapply: !longFormGovernance,
      });
      if (recovery.kind !== "recovered") {
        throw new Error(
          recovery.issues[0]?.description
            ?? `Chapter sync still failed for chapter ${targetChapter}.`,
        );
      }
      syncedOutput = recovery.output;
      validation = recovery.validation;
    }

    if (!validation.passed) {
      throw new Error(`Chapter sync still failed for chapter ${targetChapter}.`);
    }

    const syncedWordCount = countChapterLength(content, resolveLengthCountingMode(pipelineLang));
    const longFormValidation = longFormGovernance
      ? validateAndApplyLongFormChapter({
          plan: longFormGovernance.loaded.plan,
          fingerprint: longFormGovernance.loaded.fingerprint,
          state: longFormGovernance.state,
          chapterNumber: targetChapter,
          wordCount: syncedWordCount,
          runtimeDelta: syncedOutput.runtimeStateDelta,
          allowReapply: false,
        })
      : null;
    const longFormAuditIssues = longFormValidation
      ? this.toLongFormAuditIssues(longFormValidation, pipelineLang)
      : [];
    const longFormCritical = longFormAuditIssues.filter((issue) => issue.severity === "critical");
    this.throwIfOperationAborted();
    if (longFormCritical.length > 0) {
      const baseStatus = targetMeta.status === "state-degraded"
        ? resolveStateDegradedBaseStatus(targetMeta)
        : targetMeta.status === "audit-failed" ? "audit-failed" : "ready-for-review";
      index[targetIndex] = {
        ...targetMeta,
        status: "state-degraded",
        wordCount: syncedWordCount,
        updatedAt: new Date().toISOString(),
        auditIssues: [
          ...targetMeta.auditIssues,
          ...longFormCritical.map((issue) => `[${issue.severity}] ${issue.description}`),
        ],
        reviewNote: buildStateDegradedReviewNote(baseStatus, longFormCritical),
      };
      await this.state.saveChapterIndex(bookId, index);
      return {
        chapterNumber: targetChapter,
        title: targetMeta.title,
        wordCount: syncedWordCount,
        auditResult: {
          passed: false,
          issues: longFormAuditIssues,
          summary: "edited body retained; truth state blocked by authoritative long-form validation",
        },
        revised: false,
        status: "state-degraded",
        lengthWarnings: targetMeta.lengthWarnings,
        lengthTelemetry: targetMeta.lengthTelemetry,
        tokenUsage: targetMeta.tokenUsage,
      };
    }

    const finalStatus: "ready-for-review" | "audit-failed" = targetMeta.status === "state-degraded"
      ? resolveStateDegradedBaseStatus(targetMeta)
      : "ready-for-review";
    await persistChapterTransaction({
      bookDir,
      chapterNumber: targetChapter,
      commit: async () => {
        await writer.saveChapter(bookDir, syncedOutput, gp.numericalSystem, pipelineLang);
        await writer.saveNewTruthFiles(bookDir, syncedOutput, pipelineLang);
        await this.syncLegacyStructuredStateFromMarkdown(bookDir, targetChapter, syncedOutput);
        await this.syncNarrativeMemoryIndex(bookId, targetChapter);
        this.throwIfOperationAborted();
        if (longFormGovernance && longFormValidation) {
          await this.persistLongFormCommit({
            bookDir,
            governance: longFormGovernance,
            validation: longFormValidation,
            chapterNumbers: index.map((chapter) => chapter.number),
            runtimeSnapshot: syncedOutput.runtimeStateSnapshot,
          });
        }
        await this.state.snapshotState(bookId, targetChapter);
        await this.syncCurrentStateFactHistory(bookId, targetChapter);

        if (targetMeta.status === "state-degraded") {
          const degradedMetadata = parseStateDegradedReviewNote(targetMeta.reviewNote);
          const injectedIssues = new Set(degradedMetadata?.injectedIssues ?? []);
          index[targetIndex] = {
            ...targetMeta,
            status: finalStatus,
            wordCount: syncedWordCount,
            updatedAt: new Date().toISOString(),
            auditIssues: targetMeta.auditIssues.filter((issue) => !injectedIssues.has(issue)),
            reviewNote: undefined,
          };
        } else {
          index[targetIndex] = {
            ...targetMeta,
            status: "ready-for-review",
            wordCount: syncedWordCount,
            updatedAt: new Date().toISOString(),
          };
        }
        this.throwIfOperationAborted();
        await this.state.saveChapterIndex(bookId, index);
      },
    });
    return {
      chapterNumber: targetChapter,
      title: targetMeta.title,
      wordCount: syncedWordCount,
      auditResult: {
        passed: finalStatus !== "audit-failed",
        issues: longFormAuditIssues,
        summary: finalStatus === "audit-failed"
          ? "chapter truth/state resynced from edited body, but chapter still needs audit fixes"
          : "chapter truth/state resynced from edited body",
      },
      revised: false,
      status: finalStatus,
      lengthWarnings: targetMeta.lengthWarnings,
      lengthTelemetry: targetMeta.lengthTelemetry,
      tokenUsage: targetMeta.tokenUsage,
    };
  }

  // ---------------------------------------------------------------------------
  // Import operations (style imitation + canon for spinoff)
  // ---------------------------------------------------------------------------

  /**
   * Generate a qualitative style guide from reference text via LLM.
   * Also saves the statistical style_profile.json.
   */
  async generateStyleGuide(bookId: string, referenceText: string, sourceName?: string): Promise<string> {
    const sample = referenceText.trim();
    if (!sample) {
      throw new Error("Reference text is required for style extraction.");
    }

    const { analyzeStyle } = await import("../agents/style-analyzer.js");
    const bookDir = this.state.bookDir(bookId);
    const storyDir = join(bookDir, "story");
    await mkdir(storyDir, { recursive: true });

    const book = await this.state.loadBookConfig(bookId);
    const { profile: gp } = await this.loadGenreProfile(book.genre);
    const lang = (book.language ?? gp.language) === "en" ? "en" as const : "zh" as const;

    // Statistical fingerprint (language-aware: words for en, characters for zh)
    const profile = analyzeStyle(sample, sourceName, lang);
    await writeFile(join(storyDir, "style_profile.json"), JSON.stringify(profile, null, 2), "utf-8");

    let qualitativeGuide: string;
    if (sample.length < 500) {
      qualitativeGuide = this.buildDeterministicStyleGuide(profile, {
        language: lang,
        reason: lang === "en"
          ? `The sample is short (${sample.length} chars), so this guide uses the statistical fingerprint instead of LLM qualitative extraction.`
          : `样本文本较短（${sample.length}字），本次先使用统计指纹生成文风指南，不强行调用 LLM 做定性拆解。`,
      });
    } else {
      try {
        // LLM qualitative extraction (language-aware prompt)
        const styleSystemPrompt = lang === "en"
          ? `You are a literary style analyst. Analyze the writing style of the reference text and extract qualitative, imitable features.

Output format (Markdown):
## Narrative Voice & Tone
(detached / fervent / ironic / warm / ..., with 1-2 quoted lines from the text)

## Dialogue Style
(shared traits in how characters speak: sentence length, verbal tics, dialect markers, dialogue rhythm)

## Scene Description
(sensory preferences, choice of imagery, description density, how setting ties to emotion)

## Transitions & Connective Technique
(how scenes switch, how time jumps are handled, paragraph-to-paragraph transitions)

## Pacing
(distribution of long vs short sentences, paragraph-length preference, how climaxes and lulls alternate)

## Diction
(signature high-frequency word choices, figurative/rhetorical tendencies, degree of colloquialism)

## Emotional Expression
(direct lyricism vs externalized action, frequency and style of interior monologue)

## Distinctive Habits
(any personal writing habits worth imitating)

Base the analysis on the text's actual features, not generalities. Support each section with 1-2 quoted lines from the original.`
          : `你是一位文学风格分析专家。分析参考文本的写作风格，提取可供模仿的定性特征。

输出格式（Markdown）：
## 叙事声音与语气
（冷峻/热烈/讽刺/温情/...，附1-2个原文例句）

## 对话风格
（角色说话的共性特征：句子长短、口头禅倾向、方言痕迹、对话节奏）

## 场景描写特征
（五感偏好、意象选择、描写密度、环境与情绪的关联方式）

## 转折与衔接手法
（场景如何切换、时间跳跃的处理方式、段落间的过渡特征）

## 节奏特征
（长短句分布、段落长度偏好、高潮/舒缓的交替方式）

## 词汇偏好
（高频特色用词、比喻/修辞倾向、口语化程度）

## 情绪表达方式
（直白抒情 vs 动作外化、内心独白的频率和风格）

## 独特习惯
（任何值得模仿的个人写作习惯）

分析必须基于原文实际特征，不要泛泛而谈。每个部分用1-2个原文例句佐证。`;
        const styleUserPrompt = lang === "en"
          ? `Analyze the writing style of the following reference text:\n\n${sample}`
          : `分析以下参考文本的写作风格：\n\n${sample}`;
        const response = await chatCompletion(this.config.client, this.config.model, [
          { role: "system", content: styleSystemPrompt },
          { role: "user", content: styleUserPrompt },
        ], { temperature: 0.3, signal: this.currentOperationSignal() });
        qualitativeGuide = response.content.trim()
          ? response.content
          : this.buildDeterministicStyleGuide(profile, {
              language: lang,
              reason: lang === "en"
                ? "The LLM returned empty style analysis; using the statistical fingerprint fallback."
                : "LLM 未返回有效文风分析，本次使用统计指纹兜底生成文风指南。",
            });
      } catch (error) {
        this.throwIfOperationAborted();
        qualitativeGuide = this.buildDeterministicStyleGuide(profile, {
          language: lang,
          reason: lang === "en"
            ? `LLM qualitative extraction failed: ${error instanceof Error ? error.message : String(error)}. Using the statistical fingerprint fallback.`
            : `LLM 定性拆解失败：${error instanceof Error ? error.message : String(error)}。本次使用统计指纹兜底生成文风指南。`,
        });
      }
    }

    const craftMethodology = buildWritingMethodologySection(lang);
    const fullStyleGuide = `${qualitativeGuide}\n\n${craftMethodology}`;
    this.throwIfOperationAborted();
    await writeFile(join(storyDir, "style_guide.md"), fullStyleGuide, "utf-8");
    return fullStyleGuide;
  }

  private buildDeterministicStyleGuide(
    profile: {
      readonly avgSentenceLength: number;
      readonly sentenceLengthStdDev: number;
      readonly avgParagraphLength: number;
      readonly vocabularyDiversity: number;
      readonly topPatterns: ReadonlyArray<string>;
      readonly rhetoricalFeatures: ReadonlyArray<string>;
      readonly sourceName?: string;
    },
    options: { readonly language: "zh" | "en"; readonly reason: string },
  ): string {
    if (options.language === "en") {
      return [
        "# Style Guide",
        "",
        `> ${options.reason}`,
        "",
        "## Statistical Fingerprint",
        `- Source: ${profile.sourceName ?? "unknown"}`,
        `- Average sentence length: ${profile.avgSentenceLength}`,
        `- Sentence length variance: ${profile.sentenceLengthStdDev}`,
        `- Average paragraph length: ${profile.avgParagraphLength}`,
        `- Vocabulary diversity: ${Math.round(profile.vocabularyDiversity * 100)}%`,
        profile.topPatterns.length > 0 ? `- Repeated openings: ${profile.topPatterns.join(", ")}` : "- Repeated openings: none obvious in this sample",
        profile.rhetoricalFeatures.length > 0 ? `- Rhetorical features: ${profile.rhetoricalFeatures.join(", ")}` : "- Rhetorical features: none obvious in this sample",
        "",
        "## How To Use",
        "- Treat this as a lightweight style fingerprint, not a full imitation bible.",
        "- Keep sentence and paragraph rhythm close to the sample when drafting.",
        "- If this guide feels too thin, import a longer excerpt later; the file will be replaced.",
      ].join("\n");
    }

    return [
      "# 文风指南",
      "",
      `> ${options.reason}`,
      "",
      "## 统计风格指纹",
      `- 来源：${profile.sourceName ?? "unknown"}`,
      `- 平均句长：${profile.avgSentenceLength}`,
      `- 句长波动：${profile.sentenceLengthStdDev}`,
      `- 平均段落长度：${profile.avgParagraphLength}`,
      `- 词汇多样性：${Math.round(profile.vocabularyDiversity * 100)}%`,
      profile.topPatterns.length > 0 ? `- 高频句首/模式：${profile.topPatterns.join("、")}` : "- 高频句首/模式：样本内不明显",
      profile.rhetoricalFeatures.length > 0 ? `- 修辞特征：${profile.rhetoricalFeatures.join("、")}` : "- 修辞特征：样本内不明显",
      "",
      "## 使用方式",
      "- 这是一份轻量文风指纹，不是完整仿写圣经。",
      "- 后续写作优先参考句长、段落长度、节奏波动和可见修辞。",
      "- 如果想得到更稳定的定性拆解，后续可以导入更长片段覆盖本文件。",
    ].join("\n");
  }

  /**
   * Import canon from parent book for spinoff writing.
   * Reads parent's truth files, uses LLM to generate parent_canon.md in target book.
   */
  async importCanon(targetBookId: string, parentBookId: string): Promise<string> {
    // Validate both books exist
    const bookIds = await this.state.listBooks();
    if (!bookIds.includes(parentBookId)) {
      throw new Error(`Parent book "${parentBookId}" not found. Available: ${bookIds.join(", ") || "(none)"}`);
    }
    if (!bookIds.includes(targetBookId)) {
      throw new Error(`Target book "${targetBookId}" not found. Available: ${bookIds.join(", ") || "(none)"}`);
    }

    const parentDir = this.state.bookDir(parentBookId);
    const targetDir = this.state.bookDir(targetBookId);
    const releaseLock = await this.state.acquireBookLock(targetBookId);
    try {
      const storyDir = join(targetDir, "story");

      const readSafe = async (path: string): Promise<string> => {
        try { return await readFile(path, "utf-8"); } catch { return "(无)"; }
      };

      const parentBook = await this.state.loadBookConfig(parentBookId);

      // Phase 5: parent book may be on the new prose layout; prefer outline/.
      const readParentOutline = async (newRel: string, legacyRel: string): Promise<string> => {
        const preferred = await readSafe(join(parentDir, "story", newRel));
        if (preferred.trim() && preferred !== "(无)") return preferred;
        return readSafe(join(parentDir, "story", legacyRel));
      };

      const [storyBible, currentState, ledger, hooks, summaries, subplots, emotions, matrix] =
        await Promise.all([
          readParentOutline("outline/story_frame.md", "story_bible.md"),
          readSafe(join(parentDir, "story/current_state.md")),
          readSafe(join(parentDir, "story/particle_ledger.md")),
          readSafe(join(parentDir, "story/pending_hooks.md")),
          readSafe(join(parentDir, "story/chapter_summaries.md")),
          readSafe(join(parentDir, "story/subplot_board.md")),
          readSafe(join(parentDir, "story/emotional_arcs.md")),
          readSafe(join(parentDir, "story/character_matrix.md")),
        ]);

      const response = await chatCompletion(this.config.client, this.config.model, [
        {
          role: "system",
          content: `你是一位网络小说架构师。基于正传的全部设定和状态文件，生成一份完整的"正传正典参照"文档，供番外写作和审计使用。

输出格式（Markdown）：
# 正传正典（《{正传书名}》）

## 世界规则（完整，来自正传设定）
（力量体系、地理设定、阵营关系、核心规则——完整复制，不压缩）

## 正典约束（不可违反的事实）
| 约束ID | 类型 | 约束内容 | 严重性 |
|---|---|---|---|
| C01 | 人物存亡 | ... | critical |
（列出所有硬性约束：谁活着、谁死了、什么事件已经发生、什么规则不可违反）

## 角色快照
| 角色 | 当前状态 | 性格底色 | 对话特征 | 已知信息 | 未知信息 |
|---|---|---|---|---|---|
（从状态卡和角色矩阵中提取每个重要角色的完整快照）

## 角色双态处理原则
- 未来会变强的角色：写潜力暗示
- 未来会黑化的角色：写微小裂痕
- 未来会死的角色：写导致死亡的性格底色

## 关键事件时间线
| 章节 | 事件 | 涉及角色 | 对番外的约束 |
|---|---|---|---|
（从章节摘要中提取关键事件）

## 伏笔状态
| Hook ID | 类型 | 状态 | 内容 | 预期回收 |
|---|---|---|---|---|

## 资源账本快照
（当前资源状态）

---
meta:
  parentBookId: "{parentBookId}"
  parentTitle: "{正传书名}"
  generatedAt: "{ISO timestamp}"

要求：
1. 世界规则完整复制，不压缩——准确性优先
2. 正典约束必须穷尽，遗漏会导致番外与正传矛盾
3. 角色快照必须包含信息边界（已知/未知），防止番外中角色引用不该知道的信息`,
        },
        {
          role: "user",
          content: `正传书名：${parentBook.title}
正传ID：${parentBookId}

## 正传世界设定
${storyBible}

## 正传当前状态卡
${currentState}

## 正传资源账本
${ledger}

## 正传伏笔池
${hooks}

## 正传章节摘要
${summaries}

## 正传支线进度
${subplots}

## 正传情感弧线
${emotions}

## 正传角色矩阵
${matrix}`,
        },
      ], { temperature: 0.3, signal: this.currentOperationSignal() });

      // Append deterministic meta block (LLM may hallucinate timestamps)
      const metaBlock = [
        "",
        "---",
        "meta:",
        `  parentBookId: "${parentBookId}"`,
        `  parentTitle: "${parentBook.title}"`,
        `  generatedAt: "${new Date().toISOString()}"`,
      ].join("\n");
      const canon = response.content + metaBlock;

      const parentChaptersDir = join(parentDir, "chapters");
      const parentChapterText = await this.readParentChapterSample(parentChaptersDir);
      this.throwIfOperationAborted();
      await withBookTreeTransaction(targetDir, async () => {
        await mkdir(storyDir, { recursive: true });
        await writeFile(join(storyDir, "parent_canon.md"), canon, "utf-8");
        if (parentChapterText.length >= 500) {
          await this.generateStyleGuide(targetBookId, parentChapterText, parentBook.title);
        }
        this.throwIfOperationAborted();
      });

      return canon;
    } finally {
      await releaseLock();
    }
  }

  private async readParentChapterSample(chaptersDir: string): Promise<string> {
    try {
      const entries = await readdir(chaptersDir);
      const mdFiles = entries
        .filter((file) => file.endsWith(".md"))
        .sort()
        .slice(0, 5);
      const chunks: string[] = [];
      let totalLength = 0;
      for (const file of mdFiles) {
        if (totalLength >= 20000) break;
        const content = await readFile(join(chaptersDir, file), "utf-8");
        chunks.push(content);
        totalLength += content.length;
      }
      return chunks.join("\n\n---\n\n");
    } catch {
      return "";
    }
  }

  // ---------------------------------------------------------------------------
  // Chapter import (for continuation writing from existing chapters)
  // ---------------------------------------------------------------------------

  /**
   * Import existing chapters into a book. Reverse-engineers all truth files
   * via sequential replay so the Writer and Auditor can continue naturally.
   *
   * Step 1: Generate foundation (story_frame, volume_map, book_rules) from all chapters.
   * Step 2: Sequentially replay each chapter through ChapterAnalyzer to build truth files.
   */
  async importChapters(input: ImportChaptersInput): Promise<ImportChaptersResult> {
    const releaseLock = await this.state.acquireBookLock(input.bookId);
    try {
      const book = await this.state.loadBookConfig(input.bookId);
      const bookDir = this.state.bookDir(input.bookId);
      const { profile: gp } = await this.loadGenreProfile(book.genre);
      const resolvedLanguage = book.language ?? gp.language;

      const startFrom = input.resumeFrom ?? 1;

      const log = this.config.logger?.child("import");

      // Step 1: Generate foundation on first run (not on resume)
      if (startFrom === 1) {
        log?.info(this.localize(resolvedLanguage, {
          zh: `步骤 1：从 ${input.chapters.length} 章生成基础设定...`,
          en: `Step 1: Generating foundation from ${input.chapters.length} chapters...`,
        }));
        const foundationSource = buildImportFoundationSource(input.chapters, resolvedLanguage);

        const architect = new ArchitectAgent(this.agentCtxFor("architect", input.bookId));
        const isSeries = input.importMode === "series";
        const foundation = isSeries
          ? await this.generateAndReviewFoundation({
              generate: (reviewFeedback) => architect.generateFoundationFromImport(book, foundationSource, undefined, reviewFeedback, { importMode: "series" }),
              reviewer: new FoundationReviewerAgent(this.agentCtxFor("foundation-reviewer", input.bookId)),
              mode: "series",
              language: resolvedLanguage === "en" ? "en" : "zh",
              stageLanguage: resolvedLanguage,
              targetChapters: book.targetChapters,
            })
          : await architect.generateFoundationFromImport(book, foundationSource);
        await withBookTreeTransaction(bookDir, async () => {
          await architect.writeFoundationFiles(
            bookDir,
            foundation,
            gp.numericalSystem,
            resolvedLanguage,
          );
          await this.resetImportReplayTruthFiles(bookDir, resolvedLanguage);
          await this.state.saveChapterIndex(input.bookId, []);
          await this.state.snapshotState(input.bookId, 0);
        });

        // Generate style guide from imported chapters
        if (foundationSource.length >= 500) {
          log?.info(this.localize(resolvedLanguage, {
            zh: "提取原文风格指纹...",
            en: "Extracting source style fingerprint...",
          }));
          await this.tryGenerateStyleGuide(input.bookId, foundationSource, book.title, resolvedLanguage);
        }

        log?.info(this.localize(resolvedLanguage, {
          zh: "基础设定已生成。",
          en: "Foundation generated.",
        }));
      }

      // Step 2: Sequential replay
      log?.info(this.localize(resolvedLanguage, {
        zh: `步骤 2：从第 ${startFrom} 章开始顺序回放...`,
        en: `Step 2: Sequential replay from chapter ${startFrom}...`,
      }));
      const analyzer = new ChapterAnalyzerAgent(this.agentCtxFor("chapter-analyzer", input.bookId));
      const writer = new WriterAgent(this.agentCtxFor("writer", input.bookId));
      const countingMode = resolveLengthCountingMode(book.language ?? gp.language);
      let totalWords = 0;
      let importedCount = 0;

      for (let i = startFrom - 1; i < input.chapters.length; i++) {
        const ch = input.chapters[i]!;
        const chapterNumber = i + 1;
        const governedInput = await this.prepareWriteInput(book, bookDir, chapterNumber);

        log?.info(this.localize(resolvedLanguage, {
          zh: `分析章节 ${chapterNumber}/${input.chapters.length}：${ch.title}...`,
          en: `Analyzing chapter ${chapterNumber}/${input.chapters.length}: ${ch.title}...`,
        }));

        // Analyze chapter to get truth file updates
        const output = await analyzer.analyzeChapter({
          book,
          bookDir,
          chapterNumber,
          chapterContent: ch.content,
          chapterTitle: ch.title,
          chapterIntent: governedInput.chapterIntent,
          contextPackage: governedInput.contextPackage,
          ruleStack: governedInput.ruleStack,
        });

        const chapterWordCount = countChapterLength(ch.content, countingMode);
        const persistedOutput: WriteChapterOutput = {
          ...output,
          chapterNumber,
          title: ch.title,
          content: ch.content,
          wordCount: chapterWordCount,
          postWriteErrors: [],
          postWriteWarnings: [],
        };

        await persistChapterTransaction({
          bookDir,
          chapterNumber,
          commit: async () => {
            // Save chapter file + core truth files (state, ledger, hooks)
            this.throwIfOperationAborted();
            await writer.saveChapter(bookDir, persistedOutput, gp.numericalSystem, resolvedLanguage);

            // Save extended truth files (summaries, subplots, emotional arcs, character matrix)
            await writer.saveNewTruthFiles(bookDir, {
              ...persistedOutput,
              postWriteErrors: [],
              postWriteWarnings: [],
            }, resolvedLanguage);

            // Update chapter index
            const existingIndex = await this.state.loadChapterIndex(input.bookId);
            const now = new Date().toISOString();
            const newEntry: ChapterMeta = {
              number: chapterNumber,
              title: persistedOutput.title,
              status: "imported",
              wordCount: chapterWordCount,
              createdAt: now,
              updatedAt: now,
              auditIssues: [],
              lengthWarnings: [],
            };
            // Replace if exists (resume case), otherwise append
            const existingIdx = existingIndex.findIndex((e) => e.number === chapterNumber);
            const updatedIndex = existingIdx >= 0
              ? existingIndex.map((e, idx) => idx === existingIdx ? newEntry : e)
              : [...existingIndex, newEntry];
            await this.state.saveChapterIndex(input.bookId, updatedIndex);
            await this.syncLegacyStructuredStateFromMarkdown(bookDir, chapterNumber, persistedOutput);
            await this.syncNarrativeMemoryIndex(input.bookId, chapterNumber);

            // Imported chapters are historical evidence rather than newly
            // generated prose: reconcile their bounded word totals without
            // inventing consistency deltas or rejecting a legacy book mid-replay.
            const importedLongForm = await this.loadActiveLongFormGovernance(book, bookDir, chapterNumber);
            if (importedLongForm) {
              const importedVolume = importedLongForm.loaded.plan.chapters[chapterNumber - 1]
                ? importedLongForm.loaded.plan.volumes.find((volume) => (
                    chapterNumber >= volume.startChapter && chapterNumber <= volume.endChapter
                  ))
                : undefined;
              await persistLongFormContinuityState(bookDir, importedLongForm.state);
              if (importedVolume && chapterNumber === importedVolume.endChapter) {
                const checkpoint = buildCanonCheckpoint({
                  plan: importedLongForm.loaded.plan,
                  fingerprint: importedLongForm.loaded.fingerprint,
                  state: importedLongForm.state,
                  volume: importedVolume,
                  runtimeSnapshot: importedLongForm.runtimeSnapshot,
                });
                await persistCanonCheckpoint(bookDir, checkpoint);
              }
            }

            // Snapshot state after each chapter for rollback + resume support.
            await this.state.snapshotState(input.bookId, chapterNumber);
            await this.markBookActiveIfNeeded(input.bookId);
            await this.syncCurrentStateFactHistory(input.bookId, chapterNumber);
          },
        });

        importedCount++;
        totalWords += chapterWordCount;
      }

      const nextChapter = input.chapters.length + 1;
      log?.info(this.localize(resolvedLanguage, {
        zh: `完成。已导入 ${importedCount} 章，共 ${formatLengthCount(totalWords, countingMode)}。下一章：${nextChapter}`,
        en: `Done. ${importedCount} chapters imported, ${formatLengthCount(totalWords, countingMode)}. Next chapter: ${nextChapter}`,
      }));

      return {
        bookId: input.bookId,
        importedCount,
        totalWords,
        nextChapter,
      };
    } finally {
      await releaseLock();
    }
  }

  private static addUsage(
    a: TokenUsageSummary,
    b?: { readonly promptTokens: number; readonly completionTokens: number; readonly totalTokens: number },
  ): TokenUsageSummary {
    if (!b) return a;
    return {
      promptTokens: a.promptTokens + b.promptTokens,
      completionTokens: a.completionTokens + b.completionTokens,
      totalTokens: a.totalTokens + b.totalTokens,
    };
  }

  private async buildPersistenceOutput(
    bookId: string,
    book: BookConfig,
    bookDir: string,
    chapterNumber: number,
    output: WriteChapterOutput,
    finalContent: string,
    countingMode: Parameters<typeof countChapterLength>[1],
    reducedControlInput?: {
      chapterIntent: string;
      contextPackage: ContextPackage;
      ruleStack: RuleStack;
    },
  ): Promise<WriteChapterOutput> {
    if (finalContent === output.content) {
      return output;
    }

    const analyzer = new ChapterAnalyzerAgent(this.agentCtxFor("chapter-analyzer", bookId));
    const analyzed = await analyzer.analyzeChapter({
      book,
      bookDir,
      chapterNumber,
      chapterContent: finalContent,
      chapterTitle: output.title,
      chapterIntent: reducedControlInput?.chapterIntent,
      contextPackage: reducedControlInput?.contextPackage,
      ruleStack: reducedControlInput?.ruleStack,
    });

    return {
      ...analyzed,
      content: finalContent,
      wordCount: countChapterLength(finalContent, countingMode),
      postWriteErrors: [],
      postWriteWarnings: [],
      hookHealthIssues: output.hookHealthIssues,
      tokenUsage: output.tokenUsage,
    };
  }

  private async assertNoPendingStateRepair(bookId: string): Promise<void> {
    const existingIndex = await this.state.loadChapterIndex(bookId);
    const orderedChapters = [...existingIndex].sort((left, right) => left.number - right.number);
    const firstRejectedChapter = orderedChapters.find((chapter) => chapter.status === "rejected");
    if (firstRejectedChapter) {
      throw new Error(
        `Chapter ${firstRejectedChapter.number} is rejected. Rewrite/rebase it or roll back before continuing.`,
      );
    }

    const latestChapter = orderedChapters.at(-1);
    if (latestChapter?.status !== "state-degraded") return;

    throw new Error(
      `Latest chapter ${latestChapter.number} is state-degraded. Repair state or rewrite that chapter before continuing.`,
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  private async prepareWriteInput(
    book: BookConfig,
    bookDir: string,
    chapterNumber: number,
    externalContext?: string,
    longFormGovernance?: ActiveLongFormGovernance | null,
  ): Promise<Pick<WriteChapterInput, "externalContext" | "chapterIntent" | "chapterMemo" | "chapterIntentData" | "contextPackage" | "ruleStack">> {
    if ((this.config.inputGovernanceMode ?? "v2") === "legacy") {
      return { externalContext };
    }

    const { plan, composed } = await this.createGovernedArtifacts(
      book,
      bookDir,
      chapterNumber,
      externalContext,
      { reuseExistingIntentWhenContextMissing: true, longFormGovernance },
    );

    return {
      externalContext,
      chapterIntent: plan.intentMarkdown,
      chapterMemo: plan.memo,
      chapterIntentData: plan.intent,
      contextPackage: composed.contextPackage,
      ruleStack: composed.ruleStack,
    };
  }

  private async resetImportReplayTruthFiles(
    bookDir: string,
    language: LengthLanguage,
  ): Promise<void> {
    const storyDir = join(bookDir, "story");
    await writeFile(
      join(storyDir, "current_state.md"),
      this.buildImportReplayStateSeed(language),
      "utf-8",
    );
    await writeFile(
      join(storyDir, "pending_hooks.md"),
      this.buildImportReplayHooksSeed(language),
      "utf-8",
    );
    for (const relativePath of [
      "chapter_summaries.md",
      "subplot_board.md",
      "emotional_arcs.md",
      "character_matrix.md",
      "volume_summaries.md",
      "particle_ledger.md",
      "memory.db",
      "memory.db-shm",
      "memory.db-wal",
    ]) {
      await rm(join(storyDir, relativePath), { force: true });
    }
    await rm(join(storyDir, "state"), { recursive: true, force: true });
    await rm(join(storyDir, "snapshots"), { recursive: true, force: true });

    const chaptersDir = join(bookDir, "chapters");
    const chapterFiles = await readdir(chaptersDir).catch(() => [] as string[]);
    for (const file of chapterFiles) {
      if (/^\d{4}[_-].*\.md$/.test(file)) {
        await rm(join(chaptersDir, file), { force: true });
      }
    }
  }

  /** Promote hooks only after final truth is written so the change shares the chapter transaction. */
  private async promotePersistedHooks(bookDir: string, chapterNumber: number): Promise<void> {
    const { rerunPromotionPass } = await import("../utils/hook-promotion.js");
    const { parsePendingHooksMarkdown, renderHookSnapshot } = await import("../utils/story-markdown.js");
    const storyDir = join(bookDir, "story");
    const ledgerPath = join(storyDir, "pending_hooks.md");
    const ledgerRaw = await readFile(ledgerPath, "utf-8").catch(() => "");
    if (!ledgerRaw.trim()) return;

    const hooks = parsePendingHooksMarkdown(ledgerRaw);
    if (hooks.length === 0) return;
    const summariesRaw = await readFile(join(storyDir, "chapter_summaries.md"), "utf-8").catch(() => "");
    const promotionResult = rerunPromotionPass(hooks, summariesRaw);
    if (!promotionResult.updated) return;

    const ledgerLang: "zh" | "en" = /[\u4e00-\u9fff]/.test(ledgerRaw) ? "zh" : "en";
    await writeFile(ledgerPath, renderHookSnapshot([...promotionResult.hooks], ledgerLang), "utf-8");
    this.config.logger?.info(
      `[promotion] ${promotionResult.flippedCount} hook(s) promoted after chapter ${chapterNumber}`,
    );
  }

  private buildImportReplayStateSeed(language: LengthLanguage): string {
    if (language === "en") {
      return [
        "# Current State",
        "",
        "| Field | Value |",
        "| --- | --- |",
        "| Current Chapter | 0 |",
        "| Current Location | (not set) |",
        "| Protagonist State | (not set) |",
        "| Current Goal | (not set) |",
        "| Current Constraint | (not set) |",
        "| Current Alliances | (not set) |",
        "| Current Conflict | (not set) |",
        "",
      ].join("\n");
    }

    return [
      "# 当前状态",
      "",
      "| 字段 | 值 |",
      "| --- | --- |",
      "| 当前章节 | 0 |",
      "| 当前位置 | （未设定） |",
      "| 主角状态 | （未设定） |",
      "| 当前目标 | （未设定） |",
      "| 当前限制 | （未设定） |",
      "| 当前敌我 | （未设定） |",
      "| 当前冲突 | （未设定） |",
      "",
    ].join("\n");
  }

  private buildImportReplayHooksSeed(language: LengthLanguage): string {
    if (language === "en") {
      return [
        "# Pending Hooks",
        "",
        "| hook_id | start_chapter | type | status | last_advanced_chapter | expected_payoff | notes |",
        "| --- | --- | --- | --- | --- | --- | --- |",
        "",
      ].join("\n");
    }

    return [
      "# 伏笔池",
      "",
      "| hook_id | 起始章节 | 类型 | 状态 | 最近推进 | 预期回收 | 备注 |",
      "| --- | --- | --- | --- | --- | --- | --- |",
      "",
    ].join("\n");
  }

  private async normalizeDraftLengthIfNeeded(params: {
    bookId: string;
    chapterNumber: number;
    chapterContent: string;
    lengthSpec: LengthSpec;
    chapterIntent?: string;
  }): Promise<{
    content: string;
    wordCount: number;
    applied: boolean;
    tokenUsage?: TokenUsageSummary;
  }> {
    const writerCount = countChapterLength(
      params.chapterContent,
      params.lengthSpec.countingMode,
    );
    if (!isOutsideHardRange(writerCount, params.lengthSpec)) {
      return {
        content: params.chapterContent,
        wordCount: writerCount,
        applied: false,
      };
    }

    const normalizer = new LengthNormalizerAgent(
      this.agentCtxFor("length-normalizer", params.bookId),
    );
    const normalized = await normalizer.normalizeChapter({
      chapterContent: params.chapterContent,
      lengthSpec: params.lengthSpec,
      chapterIntent: params.chapterIntent,
    });

    // Safety net: if normalizer output is less than 25% of original, it was too destructive.
    // Reject and keep original content.
    if (normalized.finalCount < writerCount * 0.25) {
      this.logWarn(this.languageFromLengthSpec(params.lengthSpec), {
        zh: `字数归一化被拒绝：第${params.chapterNumber}章 ${writerCount} -> ${normalized.finalCount}（砍了${Math.round((1 - normalized.finalCount / writerCount) * 100)}%，超过安全阈值）`,
        en: `Length normalization rejected for chapter ${params.chapterNumber}: ${writerCount} -> ${normalized.finalCount} (cut ${Math.round((1 - normalized.finalCount / writerCount) * 100)}%, exceeds safety threshold)`,
      });
      return {
        content: params.chapterContent,
        wordCount: writerCount,
        applied: false,
      };
    }

    this.logInfo(this.languageFromLengthSpec(params.lengthSpec), {
      zh: `审计前字数归一化：第${params.chapterNumber}章 ${writerCount} -> ${normalized.finalCount}`,
      en: `Length normalization before audit for chapter ${params.chapterNumber}: ${writerCount} -> ${normalized.finalCount}`,
    });

    return {
      content: normalized.normalizedContent,
      wordCount: normalized.finalCount,
      applied: normalized.applied,
      tokenUsage: normalized.tokenUsage,
    };
  }

  private assertChapterContentNotEmpty(content: string, chapterNumber: number, stage: string): void {
    if (content.trim().length > 0) return;
    throw new Error(`Chapter ${chapterNumber} has empty chapter content after ${stage}`);
  }

  private async syncCurrentStateFactHistory(bookId: string, uptoChapter: number): Promise<void> {
    const bookDir = this.state.bookDir(bookId);
    try {
      await this.updateCurrentStateFactHistory(bookDir, uptoChapter);
    } catch (error) {
      if (this.isMemoryIndexUnavailableError(error)) {
        if (this.canOpenMemoryIndex(bookDir)) {
          try {
            await this.updateCurrentStateFactHistory(bookDir, uptoChapter);
            return;
          } catch (retryError) {
            error = retryError;
          }
        } else {
          if (!this.memoryIndexFallbackWarned) {
            this.memoryIndexFallbackWarned = true;
            this.logWarn(await this.resolveBookLanguageById(bookId), {
              zh: "当前 Node 运行时不支持 SQLite 记忆索引，继续使用 Markdown 回退方案。",
              en: "SQLite memory index unavailable on this Node runtime; continuing with markdown fallback.",
            });
            await this.logMemoryIndexDebugInfo(bookId, error);
          }
          return;
        }
      }
      throw error;
    }
  }

  private async syncLegacyStructuredStateFromMarkdown(
    bookDir: string,
    chapterNumber: number,
    output?: {
      readonly runtimeStateDelta?: WriteChapterOutput["runtimeStateDelta"];
      readonly runtimeStateSnapshot?: WriteChapterOutput["runtimeStateSnapshot"];
    },
  ): Promise<void> {
    if (output?.runtimeStateDelta || output?.runtimeStateSnapshot) {
      return;
    }

    await rewriteStructuredStateFromMarkdown({
      bookDir,
      fallbackChapter: chapterNumber,
    });
  }

  private async syncNarrativeMemoryIndex(bookId: string, chapterNumber?: number): Promise<void> {
    const bookDir = this.state.bookDir(bookId);
    try {
      await this.updateNarrativeMemoryIndex(bookDir, chapterNumber);
    } catch (error) {
      if (this.isMemoryIndexUnavailableError(error)) {
        if (this.canOpenMemoryIndex(bookDir)) {
          try {
            await this.updateNarrativeMemoryIndex(bookDir, chapterNumber);
            return;
          } catch (retryError) {
            error = retryError;
          }
        } else {
          if (!this.memoryIndexFallbackWarned) {
            this.memoryIndexFallbackWarned = true;
            this.logWarn(await this.resolveBookLanguageById(bookId), {
              zh: "当前 Node 运行时不支持 SQLite 记忆索引，继续使用 Markdown 回退方案。",
              en: "SQLite memory index unavailable on this Node runtime; continuing with markdown fallback.",
            });
            await this.logMemoryIndexDebugInfo(bookId, error);
          }
          return;
        }
      }
      throw error;
    }
  }

  private async updateCurrentStateFactHistory(bookDir: string, chapterNumber: number): Promise<void> {
    const snapshotFacts = await loadSnapshotCurrentStateFacts(bookDir, chapterNumber);
    const memoryDb = await this.withMemoryIndexRetry(() => new MemoryDB(bookDir));
    try {
      const cursorRaw = memoryDb.getMetadata("fact_history_chapter");
      const cursor = cursorRaw === undefined ? undefined : Number.parseInt(cursorRaw, 10);
      if (cursor !== chapterNumber - 1) {
        memoryDb.close();
        await this.rebuildCurrentStateFactHistory(bookDir, chapterNumber);
        return;
      }

      memoryDb.transaction(() => {
        const currentFacts = new Map(
          memoryDb.getCurrentFacts().map((fact) => [this.factKey(fact), fact]),
        );
        const nextFacts = new Map(snapshotFacts.map((fact) => [this.factKey(fact), fact]));
        for (const [key, current] of currentFacts) {
          const next = nextFacts.get(key);
          if (!next || next.object !== current.object) {
            if (current.id === undefined) throw new Error(`Memory fact ${key} has no id`);
            memoryDb.invalidateFact(current.id, chapterNumber);
          }
        }
        for (const [key, next] of nextFacts) {
          const current = currentFacts.get(key);
          if (current?.object === next.object) continue;
          memoryDb.addFact({
            subject: next.subject,
            predicate: next.predicate,
            object: next.object,
            validFromChapter: chapterNumber,
            validUntilChapter: null,
            sourceChapter: next.sourceChapter,
          });
        }
        memoryDb.setMetadata("fact_history_chapter", String(chapterNumber));
      });
    } finally {
      // updateCurrentStateFactHistory may close before a one-time rebuild.
      try {
        memoryDb.close();
      } catch {
        // already closed
      }
    }
  }

  private async rebuildCurrentStateFactHistory(bookDir: string, uptoChapter: number): Promise<void> {
    const memoryDb = await this.withMemoryIndexRetry(async () => {
      const db = new MemoryDB(bookDir);
      try {
        await db.transactionAsync(async () => {
          db.resetFacts();
          const activeFacts = new Map<string, { id: number; object: string }>();

          for (let chapter = 0; chapter <= uptoChapter; chapter++) {
            const snapshotFacts = await loadSnapshotCurrentStateFacts(bookDir, chapter);
            if (snapshotFacts.length === 0) continue;
            const nextFacts = new Map<string, Omit<Fact, "id">>();

            for (const fact of snapshotFacts) {
              nextFacts.set(this.factKey(fact), {
                subject: fact.subject,
                predicate: fact.predicate,
                object: fact.object,
                validFromChapter: chapter,
                validUntilChapter: null,
                sourceChapter: chapter,
              });
            }

            for (const [key, previous] of activeFacts.entries()) {
              const next = nextFacts.get(key);
              if (!next || next.object !== previous.object) {
                db.invalidateFact(previous.id, chapter);
                activeFacts.delete(key);
              }
            }

            for (const [key, fact] of nextFacts.entries()) {
              if (activeFacts.has(key)) continue;
              const id = db.addFact(fact);
              activeFacts.set(key, { id, object: fact.object });
            }
          }
          db.setMetadata("fact_history_chapter", String(uptoChapter));
        });

        return db;
      } catch (error) {
        db.close();
        throw error;
      }
    });

    try {
      // No-op: keep the db open only for the duration of the rebuild.
    } finally {
      memoryDb.close();
    }
  }

  private async rebuildNarrativeMemoryIndex(bookDir: string): Promise<void> {
    const memorySeed = await loadNarrativeMemorySeed(bookDir);

    const memoryDb = await this.withMemoryIndexRetry(() => {
      const db = new MemoryDB(bookDir);
      try {
        db.transaction(() => {
          db.replaceSummaries(memorySeed.summaries);
          db.replaceHooks(memorySeed.hooks);
        });
        return db;
      } catch (error) {
        db.close();
        throw error;
      }
    });

    try {
      // No-op: keep the db open only for the duration of the rebuild.
    } finally {
      memoryDb.close();
    }
  }

  private async updateNarrativeMemoryIndex(
    bookDir: string,
    chapterNumber?: number,
  ): Promise<void> {
    if (chapterNumber === undefined) {
      await this.rebuildNarrativeMemoryIndex(bookDir);
      return;
    }
    const snapshot = await loadRuntimeStateSnapshot(bookDir);
    const summary = snapshot.chapterSummaries.rows.find((row) => row.chapter === chapterNumber);
    const memoryDb = await this.withMemoryIndexRetry(() => new MemoryDB(bookDir));
    try {
      memoryDb.transaction(() => {
        if (summary) memoryDb.upsertSummary(summary);
        else memoryDb.deleteSummary(chapterNumber);
        memoryDb.replaceHooks(snapshot.hooks.hooks);
      });
    } finally {
      memoryDb.close();
    }
  }

  private canOpenMemoryIndex(bookDir: string): boolean {
    let memoryDb: MemoryDB | null = null;
    try {
      memoryDb = new MemoryDB(bookDir);
      return true;
    } catch {
      return false;
    } finally {
      memoryDb?.close();
    }
  }

  private async logMemoryIndexDebugInfo(bookId: string, error: unknown): Promise<void> {
    if (process.env.INKOS_DEBUG_SQLITE_MEMORY !== "1") {
      return;
    }

    const code = typeof error === "object" && error !== null && "code" in error
      ? String((error as { code?: unknown }).code ?? "")
      : "";
    const message = error instanceof Error
      ? error.message
      : String(error);

    this.logWarn(await this.resolveBookLanguageById(bookId), {
      zh: `SQLite 记忆索引调试：node=${process.version}; execArgv=${JSON.stringify(process.execArgv)}; code=${code || "(none)"}; message=${message}`,
      en: `SQLite memory debug: node=${process.version}; execArgv=${JSON.stringify(process.execArgv)}; code=${code || "(none)"}; message=${message}`,
    });
  }

  private async withMemoryIndexRetry<T>(operation: () => Promise<T> | T): Promise<T> {
    const retryDelaysMs = [0, 25, 75];
    let lastError: unknown;

    for (let attempt = 0; attempt < retryDelaysMs.length; attempt += 1) {
      try {
        return await operation();
      } catch (error) {
        lastError = error;
        if (!this.isMemoryIndexBusyError(error) || attempt === retryDelaysMs.length - 1) {
          throw error;
        }
        await new Promise((resolve) => setTimeout(resolve, retryDelaysMs[attempt + 1]!));
      }
    }

    throw lastError;
  }

  private isMemoryIndexUnavailableError(error: unknown): boolean {
    if (!error) return false;

    const code = typeof error === "object" && error !== null && "code" in error
      ? String((error as { code?: unknown }).code ?? "")
      : "";
    const message = error instanceof Error
      ? error.message
      : String(error);
    const normalizedMessage = message.trim();

    return /^No such built-in module:\s*node:sqlite$/i.test(normalizedMessage)
      || /^Cannot find module ['"]node:sqlite['"]$/i.test(normalizedMessage)
      || (code === "ERR_UNKNOWN_BUILTIN_MODULE" && /\bnode:sqlite\b/i.test(normalizedMessage));
  }

  private isMemoryIndexBusyError(error: unknown): boolean {
    if (!error) return false;

    const code = typeof error === "object" && error !== null && "code" in error
      ? String((error as { code?: unknown }).code ?? "")
      : "";
    const message = error instanceof Error
      ? error.message
      : String(error);

    return code === "SQLITE_BUSY"
      || code === "SQLITE_LOCKED"
      || /\bSQLITE_BUSY\b/i.test(message)
      || /\bSQLITE_LOCKED\b/i.test(message)
      || /database is locked/i.test(message)
      || /database is busy/i.test(message);
  }

  private factKey(fact: Pick<Fact, "subject" | "predicate">): string {
    return `${fact.subject}::${fact.predicate}`;
  }

  private buildLengthWarnings(
    chapterNumber: number,
    finalCount: number,
    lengthSpec: LengthSpec,
  ): string[] {
    if (!isOutsideHardRange(finalCount, lengthSpec)) {
      return [];
    }
    return [
      this.localize(this.languageFromLengthSpec(lengthSpec), {
        zh: `第${chapterNumber}章经过一次字数归一化后仍超出硬区间（${lengthSpec.hardMin}-${lengthSpec.hardMax}，实际 ${finalCount}）。`,
        en: `Chapter ${chapterNumber} remains outside hard range (${lengthSpec.hardMin}-${lengthSpec.hardMax}, actual ${finalCount}) after a single normalization pass.`,
      }),
    ];
  }

  private async loadRecentChapterTextForValidation(bookDir: string, count: number): Promise<string> {
    const chaptersDir = join(bookDir, "chapters");
    try {
      const files = (await readdir(chaptersDir))
        .filter((file) => file.endsWith(".md") && /^\d{4}/.test(file))
        .sort()
        .slice(-Math.max(1, count));
      const contents = await Promise.all(
        files.map((file) => readFile(join(chaptersDir, file), "utf-8").catch(() => "")),
      );
      return contents.filter(Boolean).join("\n\n---\n\n");
    } catch {
      return "";
    }
  }

  private buildLengthTelemetry(params: {
    lengthSpec: LengthSpec;
    writerCount: number;
    postWriterNormalizeCount: number;
    postReviseCount: number;
    finalCount: number;
    normalizeApplied: boolean;
    lengthWarning: boolean;
  }): LengthTelemetry {
    return {
      target: params.lengthSpec.target,
      softMin: params.lengthSpec.softMin,
      softMax: params.lengthSpec.softMax,
      hardMin: params.lengthSpec.hardMin,
      hardMax: params.lengthSpec.hardMax,
      countingMode: params.lengthSpec.countingMode,
      writerCount: params.writerCount,
      postWriterNormalizeCount: params.postWriterNormalizeCount,
      postReviseCount: params.postReviseCount,
      finalCount: params.finalCount,
      normalizeApplied: params.normalizeApplied,
      lengthWarning: params.lengthWarning,
    };
  }

  private async persistAuditDriftGuidance(params: {
    readonly bookDir: string;
    readonly chapterNumber: number;
    readonly issues: ReadonlyArray<AuditIssue>;
    readonly language: LengthLanguage;
  }): Promise<void> {
    const storyDir = join(params.bookDir, "story");
    const driftPath = join(storyDir, "audit_drift.md");
    const statePath = join(storyDir, "current_state.md");
    const currentState = await readFile(statePath, "utf-8").catch(() => "");
    const sanitizedState = this.stripAuditDriftCorrectionBlock(currentState).trimEnd();

    if (sanitizedState !== currentState) {
      await writeFile(statePath, sanitizedState, "utf-8");
    }

    if (params.issues.length === 0) {
      await rm(driftPath, { force: true });
      return;
    }

    const block = [
      this.localize(params.language, {
        zh: "# 审计纠偏",
        en: "# Audit Drift",
      }),
      "",
      this.localize(params.language, {
        zh: "## 审计纠偏（自动生成，下一章写作前参照）",
        en: "## Audit Drift Correction",
      }),
      "",
      this.localize(params.language, {
        zh: `> 第${params.chapterNumber}章审计发现以下问题，下一章写作时必须避免：`,
        en: `> Chapter ${params.chapterNumber} audit found the following issues to avoid in the next chapter:`,
      }),
      ...params.issues.map((issue) => `> - [${issue.severity}] ${issue.category}: ${issue.description}`),
      "",
    ].join("\n");

    await writeFile(driftPath, block, "utf-8");
  }

  private stripAuditDriftCorrectionBlock(currentState: string): string {
    const headers = [
      "## 审计纠偏（自动生成，下一章写作前参照）",
      "## Audit Drift Correction",
      "# 审计纠偏",
      "# Audit Drift",
    ];

    let cutIndex = -1;
    for (const header of headers) {
      const index = currentState.indexOf(header);
      if (index >= 0 && (cutIndex < 0 || index < cutIndex)) {
        cutIndex = index;
      }
    }

    if (cutIndex < 0) {
      return currentState;
    }

    return currentState.slice(0, cutIndex).trimEnd();
  }

  private logLengthWarnings(lengthWarnings: ReadonlyArray<string>): void {
    for (const warning of lengthWarnings) {
      this.config.logger?.warn(warning);
    }
  }

  private restoreLostAuditIssues(previous: AuditResult, next: AuditResult): AuditResult {
    if (next.passed || next.issues.length > 0 || previous.issues.length === 0) {
      return next;
    }

    return {
      ...next,
      issues: previous.issues,
      summary: next.summary || previous.summary,
    };
  }

  private restoreActionableAuditIfLost(
    previous: {
      auditResult: AuditResult;
      aiTellCount: number;
      blockingCount: number;
      criticalCount: number;
      revisionBlockingIssues: ReadonlyArray<AuditIssue>;
    },
    next: {
      auditResult: AuditResult;
      aiTellCount: number;
      blockingCount: number;
      criticalCount: number;
      revisionBlockingIssues: ReadonlyArray<AuditIssue>;
    },
  ): MergedAuditEvaluation {
    const auditResult = this.restoreLostAuditIssues(previous.auditResult, next.auditResult);
    if (auditResult === next.auditResult) {
      return next;
    }

    return {
      ...next,
      auditResult,
      revisionBlockingIssues: previous.revisionBlockingIssues,
      blockingCount: previous.blockingCount,
      criticalCount: previous.criticalCount,
    };
  }

  private async evaluateMergedAudit(params: {
    auditor: ContinuityAuditor;
    book: BookConfig;
    bookDir: string;
    chapterContent: string;
    chapterNumber: number;
    language: LengthLanguage;
    auditOptions?: {
      temperature?: number;
      chapterIntent?: string;
      chapterMemo?: ChapterMemo;
      contextPackage?: ContextPackage;
      ruleStack?: RuleStack;
      truthFileOverrides?: {
        currentState?: string;
        ledger?: string;
        hooks?: string;
      };
    };
  }): Promise<MergedAuditEvaluation> {
    const llmAudit = await params.auditor.auditChapter(
      params.bookDir,
      params.chapterContent,
      params.chapterNumber,
      params.book.genre,
      params.auditOptions,
    );
    const aiTells = analyzeAITells(params.chapterContent, params.language);
    const sensitiveResult = analyzeSensitiveWords(params.chapterContent, undefined, params.language);
    const longSpanFatigue = await analyzeLongSpanFatigue({
      bookDir: params.bookDir,
      chapterNumber: params.chapterNumber,
      chapterContent: params.chapterContent,
      language: params.language,
    });
    const hasBlockedWords = sensitiveResult.found.some((f) => f.severity === "block");
    const issues: ReadonlyArray<AuditIssue> = [
      ...llmAudit.issues,
      ...aiTells.issues,
      ...sensitiveResult.issues,
      ...longSpanFatigue.issues,
    ];
    // revisionBlockingIssues excludes long-span-fatigue issues by
    // construction (not by category name) so that an LLM-reported issue
    // sharing a category label with a long-span issue is still counted.
    const revisionBlockingIssues: ReadonlyArray<AuditIssue> = [
      ...llmAudit.issues,
      ...aiTells.issues,
      ...sensitiveResult.issues,
    ];

    return {
      auditResult: {
        passed: hasBlockedWords ? false : llmAudit.passed,
        issues,
        summary: llmAudit.summary,
        tokenUsage: llmAudit.tokenUsage,
      },
      aiTellCount: aiTells.issues.length,
      blockingCount: revisionBlockingIssues.filter((issue) => issue.severity === "warning" || issue.severity === "critical").length,
      criticalCount: revisionBlockingIssues.filter((issue) => issue.severity === "critical").length,
      revisionBlockingIssues,
    };
  }

  private isRevisionReadyForHumanReview(auditResult: AuditResult): boolean {
    if (auditResult.passed) return true;

    return !auditResult.issues.some((issue) => {
      if (issue.severity !== "critical") return false;
      const text = `${issue.category}\n${issue.description}\n${issue.suggestion}`;
      return !/(不计入(?:结构)?评分|不计入审核|仅作(?:文风|编辑|长度)?提示|仅供参考|non[- ]blocking|does not count(?: toward)? (?:the )?(?:score|review))/i.test(text);
    });
  }

  private async markBookActiveIfNeeded(bookId: string): Promise<void> {
    const book = await this.state.loadBookConfig(bookId);
    if (book.status !== "outlining") return;

    await this.state.saveBookConfig(bookId, {
      ...book,
      status: "active",
      updatedAt: new Date().toISOString(),
    });
  }

  private async createGovernedArtifacts(
    book: BookConfig,
    bookDir: string,
    chapterNumber: number,
    externalContext?: string,
    options?: GovernedArtifactOptions,
  ): Promise<{
    plan: PlanChapterOutput;
    composed: ComposeChapterOutput;
  }> {
    const longFormGovernance = options?.longFormGovernance === undefined
      ? await this.loadActiveLongFormGovernance(book, bookDir, chapterNumber)
      : options.longFormGovernance;
    const plan = await this.resolveGovernedPlan(
      book,
      bookDir,
      chapterNumber,
      externalContext,
      options,
      longFormGovernance?.context,
    );
    const composerCtx = this.agentCtxFor("composer", book.id);
    const composer = new ComposerAgent(composerCtx);
    const composed = await composeGovernedChapter({
      book,
      bookDir,
      chapterNumber,
      plan,
      contextBudget: contextBudgetFromClient(composerCtx.client),
      compressibleContextCompiler: (request) => composer.compileCompressibleContext(request),
      onContextCompression: this.config.onContextCompression,
      longFormContext: longFormGovernance?.context,
      beforePersist: () => this.throwIfOperationAborted(),
    });

    return { plan, composed };
  }

  private async resolveGovernedPlan(
    book: BookConfig,
    bookDir: string,
    chapterNumber: number,
    externalContext?: string,
    options?: GovernedArtifactOptions,
    longFormContext?: string,
  ): Promise<PlanChapterOutput> {
    if (
      options?.reuseExistingIntentWhenContextMissing &&
      (!externalContext || externalContext.trim().length === 0)
    ) {
      const persisted = await loadPersistedPlan(bookDir, chapterNumber);
      if (persisted) return persisted;
    }

    const planner = new PlannerAgent(this.agentCtxFor("planner", book.id));
    const plan = await planner.planChapter({
      book,
      bookDir,
      chapterNumber,
      externalContext,
      longFormContext,
    });
    // Persist in the new memo format so subsequent compose/write phases can
    // skip the planner LLM call when no new context is supplied.
    this.throwIfOperationAborted();
    await savePersistedPlan(bookDir, plan);
    return plan;
  }

  private async loadActiveLongFormGovernance(
    book: BookConfig,
    bookDir: string,
    chapterNumber: number,
    targetWords?: number,
  ): Promise<ActiveLongFormGovernance | null> {
    const loaded = await loadLongFormPlan(bookDir);
    if (!loaded) return null;
    if (loaded.plan.bookId !== book.id) {
      throw new Error(`Long-form plan bookId ${loaded.plan.bookId} does not match ${book.id}.`);
    }

    const [persistedState, chapterIndex, runtimeSnapshot] = await Promise.all([
      loadLongFormContinuityState(bookDir, loaded.fingerprint, loaded.plan),
      this.state.loadChapterIndex(book.id),
      loadRuntimeStateSnapshot(bookDir),
    ]);
    const state = reconcileLongFormRuntimeSnapshot(
      reconcileLongFormProgress(loaded.plan, persistedState, chapterIndex),
      runtimeSnapshot,
    );
    const context = buildLongFormChapterContext({
      plan: loaded.plan,
      state,
      chapterNumber,
      targetWords,
      hooks: runtimeSnapshot.hooks.hooks,
      facts: runtimeSnapshot.currentState.facts
        .filter((fact) => fact.validUntilChapter === null),
    });
    return { loaded, state, context, runtimeSnapshot };
  }

  private async loadLongFormReplayGovernance(
    book: BookConfig,
    bookDir: string,
    chapterNumber: number,
    targetWords?: number,
    loadedOverride?: LoadedLongFormPlan | null,
  ): Promise<ActiveLongFormGovernance | null> {
    const loaded = loadedOverride === undefined
      ? await loadLongFormPlan(bookDir)
      : loadedOverride;
    if (!loaded) return null;
    if (loaded.plan.bookId !== book.id) {
      throw new Error(`Long-form plan bookId ${loaded.plan.bookId} does not match ${book.id}.`);
    }
    const baseChapter = Math.max(0, chapterNumber - 1);
    const [currentRuntimeSnapshot, baseRuntimeSnapshot, baseState, chapterIndex] = await Promise.all([
      loadRuntimeStateSnapshot(bookDir),
      loadRuntimeStateSnapshotAt(bookDir, baseChapter),
      loadLongFormContinuityStateAt(bookDir, loaded.fingerprint, baseChapter, loaded.plan),
      this.state.loadChapterIndex(book.id),
    ]);
    if (chapterNumber > 1 && (!baseRuntimeSnapshot || !baseState)) {
      throw new Error(
        `Long-form replay baseline for chapter ${chapterNumber} is missing snapshot ${baseChapter}; `
        + "repair or replay from the previous chapter before rewriting.",
      );
    }
    const baselineState = baseState ?? createInitialLongFormState(loaded.fingerprint);
    const state = reconcileLongFormProgress(
      loaded.plan,
      baselineState,
      chapterIndex.filter((chapter) => chapter.number < chapterNumber),
    );
    const contextSnapshot = baseRuntimeSnapshot ?? currentRuntimeSnapshot;
    const context = buildLongFormChapterContext({
      plan: loaded.plan,
      state,
      chapterNumber,
      targetWords,
      hooks: contextSnapshot.hooks.hooks,
      facts: contextSnapshot.currentState.facts
        .filter((fact) => fact.validUntilChapter === null),
    });
    const runtimeBaseSnapshot = baseRuntimeSnapshot ?? {
      manifest: {
        ...currentRuntimeSnapshot.manifest,
        lastAppliedChapter: 0,
      },
      currentState: { chapter: 0, facts: [] },
      hooks: { hooks: [] },
      chapterSummaries: { rows: [] },
      objects: { objects: [] },
    } satisfies RuntimeStateSnapshot;
    return {
      loaded,
      state,
      context,
      runtimeSnapshot: currentRuntimeSnapshot,
      runtimeBaseSnapshot,
    };
  }

  private toLongFormAuditIssues(
    validation: LongFormValidationResult,
    language: LengthLanguage,
  ): ReadonlyArray<AuditIssue> {
    return validation.issues.map((issue) => ({
      severity: issue.severity,
      category: `long-form/${issue.code}`,
      description: issue.message,
      suggestion: language === "en"
        ? "Repair the chapter body or settlement delta against the authoritative long-form plan before continuing."
        : "请按权威长篇计划修正正文或结算增量后再继续。",
      repairScope: "structural",
    }));
  }

  private async persistLongFormCommit(params: {
    readonly bookDir: string;
    readonly governance: ActiveLongFormGovernance;
    readonly validation: LongFormValidationResult;
    readonly chapterNumbers: ReadonlyArray<number>;
    readonly runtimeSnapshot?: RuntimeStateSnapshot;
  }): Promise<void> {
    this.throwIfOperationAborted();
    await persistLongFormContinuityState(params.bookDir, params.validation.nextState);
    const volume = params.validation.volume;
    if (!volume || !params.validation.volumeEnded) return;
    if (!hasCompleteChapterRange(
      { startCh: volume.startChapter, endCh: volume.endChapter },
      [...new Set(params.chapterNumbers)],
    )) return;

    const runtimeSnapshot = params.runtimeSnapshot ?? await loadRuntimeStateSnapshot(params.bookDir);
    const checkpoint = buildCanonCheckpoint({
      plan: params.governance.loaded.plan,
      fingerprint: params.governance.loaded.fingerprint,
      state: params.validation.nextState,
      volume,
      runtimeSnapshot,
    });
    await persistCanonCheckpoint(params.bookDir, checkpoint);
  }

  private async emitWebhook(
    event: WebhookEvent,
    bookId: string,
    chapterNumber?: number,
    data?: Record<string, unknown>,
  ): Promise<void> {
    if (!this.config.notifyChannels || this.config.notifyChannels.length === 0) return;
    await dispatchWebhookEvent(this.config.notifyChannels, {
      event,
      bookId,
      chapterNumber,
      timestamp: new Date().toISOString(),
      data,
    });
  }

  private schedulePostCommitEffect(label: string, operation: () => Promise<void>): void {
    void Promise.resolve()
      .then(operation)
      .catch((error) => {
        this.config.logger?.warn?.(
          `[post-commit] ${label} failed: ${error instanceof Error ? error.message : String(error)}`,
        );
      });
  }

  private async readChapterContent(bookDir: string, chapterNumber: number): Promise<string> {
    const chaptersDir = join(bookDir, "chapters");
    const files = await readdir(chaptersDir);
    const paddedNum = String(chapterNumber).padStart(4, "0");
    const chapterFile = files.find((f) => f.startsWith(paddedNum) && f.endsWith(".md"));
    if (!chapterFile) {
      throw new Error(`Chapter ${chapterNumber} file not found in ${chaptersDir}`);
    }
    const raw = await readFile(join(chaptersDir, chapterFile), "utf-8");
    // Strip the title line
    const lines = raw.split("\n");
    const contentStart = lines.findIndex((l, i) => i > 0 && l.trim().length > 0);
    return contentStart >= 0 ? lines.slice(contentStart).join("\n") : raw;
  }
}
