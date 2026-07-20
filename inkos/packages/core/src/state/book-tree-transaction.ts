import { randomUUID } from "node:crypto";
import { constants as fsConstants } from "node:fs";
import { cp, mkdir, readFile, readdir, rename, rm, rmdir, writeFile } from "node:fs/promises";
import { basename, dirname, join, sep } from "node:path";

const TRANSACTION_ROOT = ".inkos-book-transactions";
const MANIFEST_FILE = "manifest.json";
const BACKUP_DIR = "book";

type TransactionStatus = "preparing" | "prepared" | "committed" | "rolled-back";

interface BookTreeManifest {
  readonly version: 1;
  readonly transactionId: string;
  readonly bookName: string;
  readonly createdAt: string;
  readonly status: TransactionStatus;
}

/** Durable whole-book journal for rare destructive operations such as import and rollback. */
export class BookTreeTransaction {
  private finished = false;

  private constructor(
    private readonly bookDir: string,
    private readonly transactionDir: string,
    private manifest: BookTreeManifest,
  ) {}

  static async begin(bookDir: string): Promise<BookTreeTransaction> {
    const bookName = basename(bookDir);
    if (!bookName || bookName === "." || bookName === "..") {
      throw new Error(`Invalid book transaction directory: ${bookDir}`);
    }
    const transactionId = `book-${randomUUID()}`;
    const transactionDir = join(transactionRootFor(bookDir), transactionId);
    const backupDir = join(transactionDir, BACKUP_DIR);
    await mkdir(transactionDir, { recursive: true });

    let manifest: BookTreeManifest = {
      version: 1,
      transactionId,
      bookName,
      createdAt: new Date().toISOString(),
      status: "preparing",
    };
    await writeManifest(transactionDir, manifest);
    try {
      await cp(bookDir, backupDir, {
        recursive: true,
        force: false,
        errorOnExist: true,
        mode: fsConstants.COPYFILE_FICLONE,
        filter: (source) => shouldBackupPath(bookDir, source),
      });
      manifest = { ...manifest, status: "prepared" };
      await writeManifest(transactionDir, manifest);
      return new BookTreeTransaction(bookDir, transactionDir, manifest);
    } catch (error) {
      await rm(transactionDir, { recursive: true, force: true }).catch(() => undefined);
      throw error;
    }
  }

  async commit(): Promise<void> {
    if (this.finished) return;
    const committed = { ...this.manifest, status: "committed" } as const;
    await writeManifest(this.transactionDir, committed);
    this.manifest = committed;
    this.finished = true;
    await cleanupTransaction(this.bookDir, this.transactionDir);
  }

  async rollback(): Promise<void> {
    if (this.finished) return;
    await restorePreparedBook(this.bookDir, this.transactionDir, this.manifest);
    const rolledBack = { ...this.manifest, status: "rolled-back" } as const;
    await writeManifest(this.transactionDir, rolledBack);
    this.manifest = rolledBack;
    this.finished = true;
    await cleanupTransaction(this.bookDir, this.transactionDir);
  }
}

export async function withBookTreeTransaction<TResult>(
  bookDir: string,
  operation: () => Promise<TResult>,
): Promise<TResult> {
  const transaction = await BookTreeTransaction.begin(bookDir);
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
        `Book tree mutation failed and rollback did not complete for ${bookDir}`,
      );
    }
    throw error;
  }
}

/** Restore an interrupted whole-book mutation. Call while holding the book lock. */
export async function recoverPendingBookTreeTransactions(bookDir: string): Promise<void> {
  const root = transactionRootFor(bookDir);
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
    const manifest = await readManifest(transactionDir, bookDir);
    if (manifest.status === "prepared") {
      await restorePreparedBook(bookDir, transactionDir, manifest);
      await writeManifest(transactionDir, { ...manifest, status: "rolled-back" });
    }
    await rm(transactionDir, { recursive: true, force: true });
  }
  await removeEmptyTransactionParents(bookDir);
}

function transactionRootFor(bookDir: string): string {
  return join(dirname(bookDir), TRANSACTION_ROOT, basename(bookDir));
}

function shouldBackupPath(bookDir: string, source: string): boolean {
  if (source === bookDir) return true;
  const excludedPaths = [
    join(bookDir, ".write.lock"),
    join(bookDir, ".inkos-transactions"),
  ];
  return !excludedPaths.some((excluded) => (
    source === excluded || source.startsWith(`${excluded}${sep}`)
  ));
}

async function restorePreparedBook(
  bookDir: string,
  transactionDir: string,
  manifest: BookTreeManifest,
): Promise<void> {
  if (manifest.status !== "prepared") return;
  await mkdir(bookDir, { recursive: true });
  const entries = await readdir(bookDir);
  for (const entry of entries) {
    if (entry === ".write.lock") continue;
    await rm(join(bookDir, entry), { recursive: true, force: true });
  }
  await cp(join(transactionDir, BACKUP_DIR), bookDir, {
    recursive: true,
    force: true,
    mode: fsConstants.COPYFILE_FICLONE,
  });
}

async function readManifest(transactionDir: string, bookDir: string): Promise<BookTreeManifest> {
  const path = join(transactionDir, MANIFEST_FILE);
  let value: unknown;
  try {
    value = JSON.parse(await readFile(path, "utf-8"));
  } catch (error) {
    throw new Error(`Invalid book transaction manifest at ${path}: ${String(error)}`);
  }
  if (!isManifest(value, basename(transactionDir), basename(bookDir))) {
    throw new Error(`Invalid book transaction manifest at ${path}`);
  }
  return value;
}

async function writeManifest(transactionDir: string, manifest: BookTreeManifest): Promise<void> {
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

function isManifest(
  value: unknown,
  expectedTransactionId: string,
  expectedBookName: string,
): value is BookTreeManifest {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const candidate = value as Partial<BookTreeManifest>;
  return candidate.version === 1
    && candidate.transactionId === expectedTransactionId
    && candidate.bookName === expectedBookName
    && typeof candidate.createdAt === "string"
    && ["preparing", "prepared", "committed", "rolled-back"].includes(candidate.status as string);
}

async function cleanupTransaction(bookDir: string, transactionDir: string): Promise<void> {
  await rm(transactionDir, { recursive: true, force: true }).catch(() => undefined);
  await removeEmptyTransactionParents(bookDir);
}

async function removeEmptyTransactionParents(bookDir: string): Promise<void> {
  const root = transactionRootFor(bookDir);
  await rmdir(root).catch(() => undefined);
  await rmdir(dirname(root)).catch(() => undefined);
}

function isMissing(error: unknown): boolean {
  return (error as NodeJS.ErrnoException | undefined)?.code === "ENOENT";
}
