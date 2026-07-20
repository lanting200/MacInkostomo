import { randomUUID } from "node:crypto";
import { constants as fsConstants } from "node:fs";
import {
  copyFile,
  cp,
  lstat,
  mkdir,
  readFile,
  readdir,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import { basename, dirname, join } from "node:path";

const TRANSACTION_ROOT = ".inkos-transactions";
const MANIFEST_FILE = "manifest.json";

type TransactionStatus = "preparing" | "prepared" | "committed" | "rolled-back";
type SnapshotKind = "missing" | "file" | "directory" | "discard";

interface SnapshotEntry {
  readonly relativePath: string;
  readonly kind: SnapshotKind;
}

interface ChapterCommitManifest {
  readonly version: 1;
  readonly transactionId: string;
  readonly chapterNumber: number;
  readonly createdAt: string;
  readonly chapterFiles: ReadonlyArray<string>;
  readonly entries: ReadonlyArray<SnapshotEntry>;
  readonly status: TransactionStatus;
}

const MUTABLE_BOOK_PATHS = [
  "book.json",
  "chapters/index.json",
  "story/current_state.md",
  "story/particle_ledger.md",
  "story/object_ledger.md",
  "story/pending_hooks.md",
  "story/chapter_summaries.md",
  "story/subplot_board.md",
  "story/emotional_arcs.md",
  "story/character_matrix.md",
  "story/audit_drift.md",
  "story/state",
  "story/canon_checkpoints",
  "story/memory.db",
  "story/memory.db-shm",
  "story/memory.db-wal",
  "story/memory.db-journal",
] as const;

const DERIVED_MUTABLE_PATHS = new Set<string>([
  "story/memory.db",
  "story/memory.db-shm",
  "story/memory.db-wal",
  "story/memory.db-journal",
]);

/** Durable, book-scoped rollback journal for one chapter commit. */
export class ChapterCommitTransaction {
  private finished = false;

  private constructor(
    private readonly bookDir: string,
    private readonly transactionDir: string,
    private manifest: ChapterCommitManifest,
  ) {}

  static async begin(bookDir: string, chapterNumber: number): Promise<ChapterCommitTransaction> {
    if (!Number.isSafeInteger(chapterNumber) || chapterNumber < 1) {
      throw new Error(`Invalid chapter transaction number: ${String(chapterNumber)}`);
    }
    const transactionId = `chapter-${String(chapterNumber).padStart(4, "0")}-${randomUUID()}`;
    const transactionDir = join(bookDir, TRANSACTION_ROOT, transactionId);
    const backupDir = join(transactionDir, "backup");
    await mkdir(backupDir, { recursive: true });

    let manifest: ChapterCommitManifest = {
      version: 1,
      transactionId,
      chapterNumber,
      createdAt: new Date().toISOString(),
      chapterFiles: [],
      entries: [],
      status: "preparing",
    };
    await writeManifest(transactionDir, manifest);

    try {
      const relativePaths = expectedMutablePaths(chapterNumber);
      const entries: SnapshotEntry[] = [];
      for (const relativePath of relativePaths) {
        entries.push(await snapshotPath(bookDir, backupDir, relativePath));
      }
      const chapterFiles = await snapshotChapterFiles(
        bookDir,
        backupDir,
        chapterNumber,
      );
      manifest = { ...manifest, entries, chapterFiles, status: "prepared" };
      await writeManifest(transactionDir, manifest);
      return new ChapterCommitTransaction(bookDir, transactionDir, manifest);
    } catch (error) {
      await rm(transactionDir, { recursive: true, force: true }).catch(() => undefined);
      throw error;
    }
  }

  async commit(): Promise<void> {
    if (this.finished) return;
    const committedManifest = { ...this.manifest, status: "committed" } as const;
    await this.persistManifest(committedManifest);
    this.manifest = committedManifest;
    this.finished = true;
    await rm(this.transactionDir, { recursive: true, force: true }).catch(() => undefined);
  }

  async rollback(): Promise<void> {
    if (this.finished) return;
    await restorePreparedTransaction(this.bookDir, this.transactionDir, this.manifest);
    const rolledBackManifest = { ...this.manifest, status: "rolled-back" } as const;
    await this.persistManifest(rolledBackManifest);
    this.manifest = rolledBackManifest;
    this.finished = true;
    await rm(this.transactionDir, { recursive: true, force: true }).catch(() => undefined);
  }

  private persistManifest(manifest: ChapterCommitManifest): Promise<void> {
    return writeManifest(this.transactionDir, manifest);
  }
}

export async function withChapterCommitTransaction<TResult>(
  bookDir: string,
  chapterNumber: number,
  operation: () => Promise<TResult>,
): Promise<TResult> {
  const transaction = await ChapterCommitTransaction.begin(bookDir, chapterNumber);
  try {
    const result = await operation();
    await transaction.commit();
    return result;
  } catch (error) {
    try {
      await transaction.rollback();
    } catch (rollbackError) {
      throw new AggregateError(
        [error, rollbackError],
        `Chapter ${chapterNumber} commit failed and rollback did not complete`,
      );
    }
    throw error;
  }
}

/** Restores transactions left prepared by a terminated process. Call under the book lock. */
export async function recoverPendingChapterTransactions(bookDir: string): Promise<void> {
  const root = join(bookDir, TRANSACTION_ROOT);
  let directories: string[];
  try {
    directories = (await readdir(root, { withFileTypes: true }))
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .sort();
  } catch (error) {
    if (isMissing(error)) return;
    throw error;
  }

  for (const directory of directories) {
    const transactionDir = join(root, directory);
    const manifest = await readManifest(transactionDir);
    if (manifest.status === "preparing"
      || manifest.status === "committed"
      || manifest.status === "rolled-back") {
      await rm(transactionDir, { recursive: true, force: true });
      continue;
    }
    await restorePreparedTransaction(bookDir, transactionDir, manifest);
    await writeManifest(transactionDir, { ...manifest, status: "rolled-back" });
    await rm(transactionDir, { recursive: true, force: true });
  }

  await rm(root, { recursive: false, force: true }).catch(() => undefined);
}

async function snapshotPath(
  bookDir: string,
  backupDir: string,
  relativePath: string,
): Promise<SnapshotEntry> {
  if (DERIVED_MUTABLE_PATHS.has(relativePath)) {
    return { relativePath, kind: "discard" };
  }
  const source = join(bookDir, relativePath);
  const info = await lstat(source).catch((error: unknown) => {
    if (isMissing(error)) return null;
    throw error;
  });
  if (!info) return { relativePath, kind: "missing" };

  const destination = join(backupDir, relativePath);
  await mkdir(dirname(destination), { recursive: true });
  if (info.isDirectory()) {
    await cp(source, destination, {
      recursive: true,
      force: false,
      errorOnExist: true,
      mode: fsConstants.COPYFILE_FICLONE,
    });
    return { relativePath, kind: "directory" };
  }
  if (!info.isFile()) {
    throw new Error(`Unsupported chapter transaction path type: ${relativePath}`);
  }
  await copyFile(source, destination, fsConstants.COPYFILE_FICLONE);
  return { relativePath, kind: "file" };
}

async function snapshotChapterFiles(
  bookDir: string,
  backupDir: string,
  chapterNumber: number,
): Promise<ReadonlyArray<string>> {
  const chaptersDir = join(bookDir, "chapters");
  let files: string[];
  try {
    files = await readdir(chaptersDir);
  } catch (error) {
    if (isMissing(error)) return [];
    throw error;
  }
  const prefix = String(chapterNumber).padStart(4, "0");
  const chapterFiles = files
    .filter((file) => isChapterFile(file, prefix))
    .sort();
  const destinationDir = join(backupDir, "chapter-files");
  await mkdir(destinationDir, { recursive: true });
  for (const file of chapterFiles) {
    await copyFile(
      join(chaptersDir, file),
      join(destinationDir, file),
      fsConstants.COPYFILE_FICLONE,
    );
  }
  return chapterFiles;
}

async function restorePreparedTransaction(
  bookDir: string,
  transactionDir: string,
  manifest: ChapterCommitManifest,
): Promise<void> {
  if (manifest.status !== "prepared") return;
  const backupDir = join(transactionDir, "backup");
  for (const entry of manifest.entries) {
    const destination = join(bookDir, entry.relativePath);
    await rm(destination, { recursive: true, force: true });
    if (entry.kind === "missing" || entry.kind === "discard") continue;
    const source = join(backupDir, entry.relativePath);
    await mkdir(dirname(destination), { recursive: true });
    if (entry.kind === "directory") {
      await cp(source, destination, {
        recursive: true,
        force: false,
        errorOnExist: true,
        mode: fsConstants.COPYFILE_FICLONE,
      });
    } else {
      await copyFile(source, destination, fsConstants.COPYFILE_FICLONE);
    }
  }

  const chaptersDir = join(bookDir, "chapters");
  await mkdir(chaptersDir, { recursive: true });
  const prefix = String(manifest.chapterNumber).padStart(4, "0");
  const currentFiles = await readdir(chaptersDir);
  for (const file of currentFiles.filter((candidate) => isChapterFile(candidate, prefix))) {
    await rm(join(chaptersDir, file), { force: true });
  }
  const chapterBackupDir = join(backupDir, "chapter-files");
  for (const file of manifest.chapterFiles) {
    await copyFile(
      join(chapterBackupDir, file),
      join(chaptersDir, file),
      fsConstants.COPYFILE_FICLONE,
    );
  }
}

async function readManifest(transactionDir: string): Promise<ChapterCommitManifest> {
  const path = join(transactionDir, MANIFEST_FILE);
  let value: unknown;
  try {
    value = JSON.parse(await readFile(path, "utf-8"));
  } catch (error) {
    throw new Error(`Invalid chapter transaction manifest at ${path}: ${String(error)}`);
  }
  if (!isManifest(value, basename(transactionDir))) {
    throw new Error(`Invalid chapter transaction manifest at ${path}`);
  }
  return value;
}

async function writeManifest(
  transactionDir: string,
  manifest: ChapterCommitManifest,
): Promise<void> {
  await mkdir(transactionDir, { recursive: true });
  const path = join(transactionDir, MANIFEST_FILE);
  const tempPath = join(transactionDir, `.${MANIFEST_FILE}.${randomUUID()}.tmp`);
  try {
    await writeFile(tempPath, `${JSON.stringify(manifest, null, 2)}\n`, {
      encoding: "utf-8",
      mode: 0o600,
    });
    await rename(tempPath, path);
  } catch (error) {
    await rm(tempPath, { force: true }).catch(() => undefined);
    throw error;
  }
}

function isChapterFile(file: string, paddedChapter: string): boolean {
  return file.endsWith(".md")
    && (file.startsWith(`${paddedChapter}_`) || file.startsWith(`${paddedChapter}-`));
}

function isManifest(
  value: unknown,
  expectedTransactionId: string,
): value is ChapterCommitManifest {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const candidate = value as Partial<ChapterCommitManifest>;
  if (candidate.version !== 1
    || candidate.transactionId !== expectedTransactionId
    || !Number.isSafeInteger(candidate.chapterNumber)
    || (candidate.chapterNumber ?? 0) < 1
    || typeof candidate.createdAt !== "string"
    || !Array.isArray(candidate.chapterFiles)
    || !Array.isArray(candidate.entries)
    || !["preparing", "prepared", "committed", "rolled-back"].includes(candidate.status as string)) {
    return false;
  }

  const chapterNumber = candidate.chapterNumber!;
  const paddedChapter = String(chapterNumber).padStart(4, "0");
  const chapterFiles = candidate.chapterFiles;
  const uniqueChapterFiles = new Set(chapterFiles);
  if (uniqueChapterFiles.size !== chapterFiles.length
    || chapterFiles.some((file) => (
      typeof file !== "string"
      || basename(file) !== file
      || !isChapterFile(file, paddedChapter)
    ))) {
    return false;
  }

  const expectedPaths = expectedMutablePaths(chapterNumber);
  const expectedPathSet = new Set<string>(expectedPaths);
  const seenPaths = new Set<string>();
  if (candidate.entries.length !== expectedPaths.length) return false;
  for (const entry of candidate.entries) {
    if (!entry
      || typeof entry.relativePath !== "string"
      || !expectedPathSet.has(entry.relativePath)
      || seenPaths.has(entry.relativePath)
      || !["missing", "file", "directory", "discard"].includes(entry.kind)
      || (DERIVED_MUTABLE_PATHS.has(entry.relativePath) !== (entry.kind === "discard"))) {
      return false;
    }
    seenPaths.add(entry.relativePath);
  }
  return seenPaths.size === expectedPathSet.size;
}

function expectedMutablePaths(chapterNumber: number): ReadonlyArray<string> {
  return [
    ...MUTABLE_BOOK_PATHS,
    `story/snapshots/${chapterNumber}`,
  ];
}

function isMissing(error: unknown): boolean {
  return (error as NodeJS.ErrnoException | undefined)?.code === "ENOENT";
}
