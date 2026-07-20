import { mkdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import {
  ChapterSummariesStateSchema,
  CurrentStateStateSchema,
  HooksStateSchema,
  PersistentObjectRecordSchema,
  PersistentObjectsStateSchema,
  StateManifestSchema,
  type RuntimeStateDelta,
} from "../models/runtime-state.js";
import type { Fact, StoredHook, StoredSummary } from "./memory-db.js";
import {
  bootstrapStructuredStateFromMarkdown,
  parseChapterSummariesMarkdown,
  parseCurrentStateFacts,
  parsePendingHooksMarkdown,
} from "./state-bootstrap.js";
import { inferFactSubject, parseMarkdownTableRows } from "../utils/story-markdown.js";
import { renderChapterSummariesProjection, renderCurrentStateProjection, renderHooksProjection, renderObjectLedgerProjection } from "./state-projections.js";
import { applyRuntimeStateDelta, type RuntimeStateSnapshot } from "./state-reducer.js";
import { validateRuntimeState } from "./state-validator.js";
import { arbitrateRuntimeStateDeltaHooks } from "../utils/hook-arbiter.js";
import { writeAtomicJson } from "../utils/long-form-plan.js";

export interface RuntimeStateArtifacts {
  readonly snapshot: RuntimeStateSnapshot;
  readonly resolvedDelta: RuntimeStateDelta;
  readonly currentStateMarkdown: string;
  readonly hooksMarkdown: string;
  readonly chapterSummariesMarkdown: string;
  readonly objectLedgerMarkdown: string;
}

export interface NarrativeMemorySeed {
  readonly summaries: ReadonlyArray<StoredSummary>;
  readonly hooks: ReadonlyArray<StoredHook>;
}

export interface RuntimeTruthFileSnapshot {
  readonly currentState: string;
  readonly ledger: string;
  readonly objectLedger: string;
  readonly hooks: string;
  readonly chapterSummaries: string;
  readonly subplotBoard: string;
  readonly emotionalArcs: string;
  readonly characterMatrix: string;
}

export interface RuntimeStateReplayBaseline {
  readonly snapshot: RuntimeStateSnapshot;
  readonly truthFiles: RuntimeTruthFileSnapshot;
}

export async function loadRuntimeStateSnapshot(bookDir: string): Promise<RuntimeStateSnapshot> {
  await bootstrapStructuredStateFromMarkdown({ bookDir });
  const stateDir = join(bookDir, "story", "state");

  const [manifest, currentState, hooks, chapterSummaries, objects] = await Promise.all([
    readJson(join(stateDir, "manifest.json"), StateManifestSchema),
    readJson(join(stateDir, "current_state.json"), CurrentStateStateSchema),
    readJson(join(stateDir, "hooks.json"), HooksStateSchema),
    readJson(join(stateDir, "chapter_summaries.json"), ChapterSummariesStateSchema),
    readJsonOrNull(join(stateDir, "objects.json"), PersistentObjectsStateSchema)
      .then((value) => value ?? { objects: [] }),
  ]);

  const snapshot = {
    manifest,
    currentState,
    hooks,
    chapterSummaries,
    objects,
  };

  const issues = validateRuntimeState(snapshot);
  if (issues.length > 0) {
    const summary = issues
      .map((issue) => `${issue.code}${issue.path ? `@${issue.path}` : ""}`)
      .join(", ");
    throw new Error(`Invalid persisted runtime state: ${summary}`);
  }

  return snapshot;
}

export async function loadRuntimeStateSnapshotAt(
  bookDir: string,
  chapterNumber: number,
): Promise<RuntimeStateSnapshot | null> {
  const stateDir = join(bookDir, "story", "snapshots", String(chapterNumber), "state");
  const [manifest, currentState, hooks, chapterSummaries, objects] = await Promise.all([
    readJsonOrNull(join(stateDir, "manifest.json"), StateManifestSchema),
    readJsonOrNull(join(stateDir, "current_state.json"), CurrentStateStateSchema),
    readJsonOrNull(join(stateDir, "hooks.json"), HooksStateSchema),
    readJsonOrNull(join(stateDir, "chapter_summaries.json"), ChapterSummariesStateSchema),
    readJsonOrNull(join(stateDir, "objects.json"), PersistentObjectsStateSchema),
  ]);
  if (!manifest || !currentState || !hooks || !chapterSummaries) return null;
  const snapshot: RuntimeStateSnapshot = {
    manifest,
    currentState,
    hooks,
    chapterSummaries,
    objects: objects ?? { objects: [] },
  };
  const issues = validateRuntimeState(snapshot);
  if (issues.length > 0) {
    throw new Error(`Invalid runtime snapshot for chapter ${chapterNumber}: ${issues.map((issue) => issue.code).join(", ")}`);
  }
  return snapshot;
}

/** Loads an immutable pre-chapter baseline without consulting live aggregate truth. */
export async function loadRuntimeStateReplayBaseline(
  bookDir: string,
  chapterNumber: number,
  language: "zh" | "en",
): Promise<RuntimeStateReplayBaseline> {
  const snapshotDir = join(bookDir, "story", "snapshots", String(chapterNumber));
  const truthFiles = await loadSnapshotTruthFiles(snapshotDir, chapterNumber);
  const persistedSnapshot = await loadRuntimeStateSnapshotAt(bookDir, chapterNumber);
  const snapshot = persistedSnapshot ?? buildRuntimeSnapshotFromTruthFiles({
    chapterNumber,
    language,
    truthFiles,
  });

  return { snapshot, truthFiles };
}

export async function buildRuntimeStateArtifacts(params: {
  readonly bookDir: string;
  readonly delta: RuntimeStateDelta;
  readonly language: "zh" | "en";
  readonly allowReapply?: boolean;
  readonly baseSnapshot?: RuntimeStateSnapshot;
}): Promise<RuntimeStateArtifacts> {
  const snapshot = params.baseSnapshot ?? await loadRuntimeStateSnapshot(params.bookDir);
  const { resolvedDelta } = arbitrateRuntimeStateDeltaHooks({
    hooks: snapshot.hooks.hooks,
    delta: params.delta,
  });
  const next = applyRuntimeStateDelta({
    snapshot,
    delta: resolvedDelta,
    allowReapply: params.allowReapply,
  });

  return {
    snapshot: next,
    resolvedDelta,
    currentStateMarkdown: renderCurrentStateProjection(next.currentState, params.language),
    // Pass the chapter number so the projection can tag stale / blocked hooks.
    hooksMarkdown: renderHooksProjection(next.hooks, params.language, {
      currentChapter: resolvedDelta.chapter,
    }),
    chapterSummariesMarkdown: renderChapterSummariesProjection(next.chapterSummaries, params.language),
    objectLedgerMarkdown: renderObjectLedgerProjection(next.objects ?? { objects: [] }, params.language),
  };
}

export async function saveRuntimeStateSnapshot(
  bookDir: string,
  snapshot: RuntimeStateSnapshot,
): Promise<void> {
  const stateDir = join(bookDir, "story", "state");
  await mkdir(stateDir, { recursive: true });

  const entries: ReadonlyArray<readonly [string, unknown]> = [
    ["manifest.json", snapshot.manifest],
    ["current_state.json", snapshot.currentState],
    ["hooks.json", snapshot.hooks],
    ["chapter_summaries.json", snapshot.chapterSummaries],
    ["objects.json", snapshot.objects ?? { objects: [] }],
  ];
  for (const [fileName, value] of entries) {
    await writeAtomicJson(join(stateDir, fileName), value);
  }
}

export async function loadNarrativeMemorySeed(bookDir: string): Promise<NarrativeMemorySeed> {
  const snapshot = await loadRuntimeStateSnapshot(bookDir);

  return {
    summaries: snapshot.chapterSummaries.rows.map((row) => ({
      chapter: row.chapter,
      title: row.title,
      characters: row.characters,
      events: row.events,
      stateChanges: row.stateChanges,
      hookActivity: row.hookActivity,
      mood: row.mood,
      chapterType: row.chapterType,
    })),
      hooks: snapshot.hooks.hooks.map((hook) => ({
        hookId: hook.hookId,
        startChapter: hook.startChapter,
        type: hook.type,
        status: hook.status,
        lastAdvancedChapter: hook.lastAdvancedChapter,
        expectedPayoff: hook.expectedPayoff,
        payoffTiming: hook.payoffTiming,
        notes: hook.notes,
      })),
  };
}

export async function loadSnapshotCurrentStateFacts(
  bookDir: string,
  chapterNumber: number,
): Promise<ReadonlyArray<Fact>> {
  const snapshotDir = join(bookDir, "story", "snapshots", String(chapterNumber));
  const structuredState = await readJsonOrNull(
    join(snapshotDir, "state", "current_state.json"),
    CurrentStateStateSchema,
  );
  if (structuredState) {
    return structuredState.facts;
  }

  const markdown = await readFile(join(snapshotDir, "current_state.md"), "utf-8").catch(() => "");
  return parseCurrentStateFacts(markdown, chapterNumber);
}

async function readJson<T>(
  path: string,
  schema: { parse(value: unknown): T },
): Promise<T> {
  const raw = await readFile(path, "utf-8");
  return schema.parse(JSON.parse(raw));
}

async function readJsonOrNull<T>(
  path: string,
  schema: { parse(value: unknown): T },
): Promise<T | null> {
  try {
    return await readJson(path, schema);
  } catch {
    return null;
  }
}

async function loadSnapshotTruthFiles(
  snapshotDir: string,
  chapterNumber: number,
): Promise<RuntimeTruthFileSnapshot> {
  const readRequired = async (fileName: string): Promise<string> => {
    try {
      return await readFile(join(snapshotDir, fileName), "utf-8");
    } catch (error) {
      if (chapterNumber === 0
        && (error as NodeJS.ErrnoException | undefined)?.code === "ENOENT") {
        return "";
      }
      throw new Error(
        `Revision replay baseline is missing snapshot for chapter ${chapterNumber}: `
        + `${fileName} (${String(error)})`,
      );
    }
  };
  const readOptional = async (fileName: string): Promise<string> => {
    try {
      return await readFile(join(snapshotDir, fileName), "utf-8");
    } catch (error) {
      if ((error as NodeJS.ErrnoException | undefined)?.code === "ENOENT") return "";
      throw error;
    }
  };

  const [
    currentState,
    ledger,
    objectLedger,
    hooks,
    chapterSummaries,
    subplotBoard,
    emotionalArcs,
    characterMatrix,
  ] = await Promise.all([
    readRequired("current_state.md"),
    readOptional("particle_ledger.md"),
    readOptional("object_ledger.md"),
    readRequired("pending_hooks.md"),
    readOptional("chapter_summaries.md"),
    readOptional("subplot_board.md"),
    readOptional("emotional_arcs.md"),
    readOptional("character_matrix.md"),
  ]);

  return {
    currentState,
    ledger,
    objectLedger,
    hooks,
    chapterSummaries,
    subplotBoard,
    emotionalArcs,
    characterMatrix,
  };
}

function buildRuntimeSnapshotFromTruthFiles(params: {
  readonly chapterNumber: number;
  readonly language: "zh" | "en";
  readonly truthFiles: RuntimeTruthFileSnapshot;
}): RuntimeStateSnapshot {
  const facts = parseReplayCurrentStateFacts(
    params.truthFiles.currentState,
    params.chapterNumber,
  );
  const hooks = parsePendingHooksMarkdown(params.truthFiles.hooks).map((hook) => ({
    ...hook,
    type: hook.type.trim() || "unspecified",
    status: normalizeReplayHookStatus(hook.status),
  }));
  const summaries = parseChapterSummariesMarkdown(params.truthFiles.chapterSummaries)
    .filter((summary) => summary.chapter <= params.chapterNumber && summary.title.trim().length > 0);
  const objects = parsePersistentObjectsMarkdown(
    params.truthFiles.objectLedger,
    params.chapterNumber,
  );

  const snapshot: RuntimeStateSnapshot = {
    manifest: StateManifestSchema.parse({
      schemaVersion: 2,
      language: params.language,
      lastAppliedChapter: params.chapterNumber,
      projectionVersion: 1,
      migrationWarnings: [
        `structured replay baseline rebuilt from snapshot ${params.chapterNumber} markdown`,
      ],
    }),
    currentState: CurrentStateStateSchema.parse({
      chapter: params.chapterNumber,
      facts,
    }),
    hooks: HooksStateSchema.parse({ hooks }),
    chapterSummaries: ChapterSummariesStateSchema.parse({ rows: summaries }),
    objects: PersistentObjectsStateSchema.parse({ objects }),
  };
  const issues = validateRuntimeState(snapshot);
  if (issues.length > 0) {
    throw new Error(
      `Invalid reconstructed runtime snapshot for chapter ${params.chapterNumber}: `
      + issues.map((issue) => issue.code).join(", "),
    );
  }
  return snapshot;
}

function normalizeReplayHookStatus(value: string): "open" | "progressing" | "deferred" | "resolved" {
  const normalized = value.trim().toLowerCase().split(/[\s(]/u, 1)[0] ?? "";
  if (normalized === "progressing" || normalized === "deferred" || normalized === "resolved") {
    return normalized;
  }
  return "open";
}

function parseReplayCurrentStateFacts(
  markdown: string,
  chapterNumber: number,
): ReadonlyArray<Fact> {
  const placeholderValues = new Set(["(not set)", "（未设定）", "(文件尚未创建)"]);
  const tableFacts = parseCurrentStateFacts(markdown, chapterNumber)
    .filter((fact) => fact.sourceChapter <= chapterNumber)
    .filter((fact) => !placeholderValues.has(fact.object.trim().toLowerCase()));
  const additionalSection = markdown.match(/(?:^|\n)##\s*(?:Additional State|其他状态)\s*\n([\s\S]*)$/iu)?.[1] ?? "";
  const additionalFacts = additionalSection
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.startsWith("-"))
    .map((line) => line.replace(/^-\s*/u, "").trim())
    .filter(Boolean)
    .map((entry, index): Fact => {
      const separator = entry.search(/[:：]/u);
      const predicate = separator > 0
        ? entry.slice(0, separator).trim()
        : `note_${index + 1}`;
      const object = separator > 0
        ? entry.slice(separator + 1).trim()
        : entry;
      return {
        subject: inferFactSubject(predicate),
        predicate,
        object,
        validFromChapter: chapterNumber,
        validUntilChapter: null,
        sourceChapter: chapterNumber,
      };
    })
    .filter((fact) => fact.predicate.length > 0 && fact.object.length > 0);
  const byPredicate = new Map<string, Fact>();
  for (const fact of [...tableFacts, ...additionalFacts]) {
    byPredicate.set(fact.predicate.trim().toLowerCase(), fact);
  }
  return [...byPredicate.values()];
}

function parsePersistentObjectsMarkdown(
  markdown: string,
  chapterNumber: number,
) {
  return parseMarkdownTableRows(markdown)
    .filter((row) => (row[0] ?? "").trim().toLowerCase() !== "object_id")
    .flatMap((row) => {
      const firstSeenChapter = Number.parseInt(row[8] ?? "", 10);
      const lastSeenChapter = Number.parseInt(row[9] ?? "", 10);
      if (!Number.isSafeInteger(firstSeenChapter)
        || firstSeenChapter < 1
        || firstSeenChapter > chapterNumber) {
        return [];
      }
      const names = (row[1] ?? "")
        .split(/\s*\/\s*/u)
        .map((value) => value.trim())
        .filter(Boolean);
      const parsed = PersistentObjectRecordSchema.safeParse({
        objectId: (row[0] ?? "").trim(),
        name: names[0] ?? "",
        aliases: names.slice(1),
        material: row[2] ?? "",
        inscription: row[3] ?? "",
        appearance: row[4] ?? "",
        owner: row[5] ?? "",
        location: row[6] ?? "",
        status: row[7] ?? "",
        firstSeenChapter,
        lastSeenChapter: Number.isSafeInteger(lastSeenChapter)
          ? Math.max(firstSeenChapter, Math.min(lastSeenChapter, chapterNumber))
          : firstSeenChapter,
        linkedHookIds: (row[10] ?? "")
          .split(/[,，、]+/u)
          .map((value) => value.trim())
          .filter(Boolean),
        notes: row[11] ?? "",
      });
      return parsed.success ? [parsed.data] : [];
    });
}
