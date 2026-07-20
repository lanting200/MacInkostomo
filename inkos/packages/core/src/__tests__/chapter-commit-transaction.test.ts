import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import {
  ChapterCommitTransaction,
  recoverPendingChapterTransactions,
  withChapterCommitTransaction,
} from "../state/chapter-commit-transaction.js";
import { StateManager } from "../state/manager.js";

const roots: string[] = [];
const BOOK_ID = "transaction-fixture";
const CHAPTER_NUMBER = 3;

const BASELINE_FILES = {
  "book.json": "baseline book metadata\n",
  "chapters/index.json": "baseline chapter index\n",
  "chapters/0003_Old_Title.md": "baseline chapter body\n",
  "story/current_state.md": "baseline current state\n",
  "story/particle_ledger.md": "baseline ledger\n",
  "story/pending_hooks.md": "baseline hooks\n",
  "story/subplot_board.md": "baseline subplot board\n",
  "story/state/manifest.json": "baseline runtime manifest\n",
  "story/state/long-form-state.json": "baseline long-form state\n",
  "story/snapshots/3/current_state.md": "baseline snapshot\n",
  "story/canon_checkpoints/volume-0001.json": "baseline canon checkpoint\n",
} as const;

const FAILURE_STAGES = [
  { name: "chapter body", paths: [] },
  {
    name: "truth files",
    paths: ["story/current_state.md", "story/particle_ledger.md", "story/pending_hooks.md", "story/subplot_board.md", "story/memory.db"],
  },
  { name: "chapter index", paths: ["chapters/index.json"] },
  { name: "book metadata", paths: ["book.json"] },
  {
    name: "runtime state",
    paths: ["story/state/manifest.json", "story/state/new-runtime-file.json"],
  },
  {
    name: "long-form state",
    paths: ["story/state/long-form-state.json", "story/canon_checkpoints/volume-0001.json", "story/canon_checkpoints/volume-0002.json"],
  },
  {
    name: "chapter snapshot",
    paths: ["story/snapshots/3/current_state.md", "story/snapshots/3/new-snapshot-file.md"],
  },
] as const;

afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("ChapterCommitTransaction", () => {
  for (const [stageIndex, stage] of FAILURE_STAGES.entries()) {
    it(`restores every durable artifact when ${stage.name} persistence fails`, async () => {
      const { bookDir } = await createFixture();

      await expect(withChapterCommitTransaction(bookDir, CHAPTER_NUMBER, async () => {
        await writeFixtureFile(bookDir, "chapters/0003_New_Title.md", "new chapter body\n");
        await rm(join(bookDir, "chapters", "0003_Old_Title.md"));

        const paths = FAILURE_STAGES
          .slice(0, stageIndex + 1)
          .flatMap((candidate) => candidate.paths);
        for (const relativePath of paths) {
          await writeFixtureFile(bookDir, relativePath, `changed during ${stage.name}\n`);
        }
        throw new Error(`injected ${stage.name} failure`);
      })).rejects.toThrow(`injected ${stage.name} failure`);

      await expectBaselineRestored(bookDir);
      expect(await readdir(join(bookDir, ".inkos-transactions"))).toEqual([]);
    });
  }

  it("recovers a prepared journal when the next process acquires the book lock", async () => {
    const { projectRoot, bookDir } = await createFixture();
    await ChapterCommitTransaction.begin(bookDir, CHAPTER_NUMBER);
    await writeFixtureFile(bookDir, "chapters/0003_New_Title.md", "interrupted chapter body\n");
    await rm(join(bookDir, "chapters", "0003_Old_Title.md"));
    await writeFixtureFile(bookDir, "story/state/long-form-state.json", "interrupted state\n");
    await writeFixtureFile(bookDir, "story/snapshots/3/new-snapshot-file.md", "interrupted snapshot\n");

    const state = new StateManager(projectRoot);
    const release = await state.acquireBookLock(BOOK_ID);
    try {
      await expectBaselineRestored(bookDir);
      await expect(readFile(join(bookDir, ".write.lock"), "utf-8")).resolves.toContain(`pid:${process.pid}`);
    } finally {
      await release();
    }
    await expect(readFile(join(bookDir, ".write.lock"), "utf-8"))
      .rejects.toMatchObject({ code: "ENOENT" });
  });

  it("rolls back when writing the committed manifest fails", async () => {
    const { bookDir } = await createFixture();
    const transactionPrototype = ChapterCommitTransaction.prototype as unknown as {
      persistManifest(manifest: { readonly status: string }): Promise<void>;
    };
    const persistManifest = vi.spyOn(transactionPrototype, "persistManifest");
    persistManifest.mockRejectedValueOnce(new Error("injected committed manifest write failure"));

    await expect(withChapterCommitTransaction(bookDir, CHAPTER_NUMBER, async () => {
      await writeFixtureFile(bookDir, "chapters/0003_New_Title.md", "new chapter body\n");
      await rm(join(bookDir, "chapters", "0003_Old_Title.md"));
      await writeFixtureFile(bookDir, "story/current_state.md", "new current state\n");
      await writeFixtureFile(bookDir, "chapters/index.json", "new chapter index\n");
    })).rejects.toThrow("injected committed manifest write failure");

    expect(persistManifest.mock.calls.map(([manifest]) => manifest.status)).toEqual([
      "committed",
      "rolled-back",
    ]);
    await expectBaselineRestored(bookDir);
  });

  it.each([
    ["a traversal entry", (manifest: MutableManifest) => {
      manifest.entries[0]!.relativePath = "../../outside.txt";
    }],
    ["a duplicate entry", (manifest: MutableManifest) => {
      manifest.entries[0]!.relativePath = manifest.entries[1]!.relativePath;
    }],
    ["a traversal chapter file", (manifest: MutableManifest) => {
      manifest.chapterFiles = ["../0003_Evil.md"];
    }],
    ["a mismatched transaction id", (manifest: MutableManifest) => {
      manifest.transactionId = "different-transaction";
    }],
    ["an invalid chapter number", (manifest: MutableManifest) => {
      manifest.chapterNumber = 0;
    }],
  ])("rejects a prepared manifest containing %s before touching book-external files", async (_name, mutate) => {
    const { projectRoot, bookDir } = await createFixture();
    const outsidePath = join(projectRoot, "outside.txt");
    await writeFile(outsidePath, "outside must remain unchanged\n", "utf-8");
    await ChapterCommitTransaction.begin(bookDir, CHAPTER_NUMBER);
    const transactionRoot = join(bookDir, ".inkos-transactions");
    const [transactionId] = await readdir(transactionRoot);
    if (!transactionId) throw new Error("expected prepared transaction");
    const manifestPath = join(transactionRoot, transactionId, "manifest.json");
    const manifest = JSON.parse(await readFile(manifestPath, "utf-8")) as MutableManifest;
    mutate(manifest);
    await writeFile(manifestPath, JSON.stringify(manifest), "utf-8");

    await expect(recoverPendingChapterTransactions(bookDir))
      .rejects.toThrow("Invalid chapter transaction manifest");
    await expect(readFile(outsidePath, "utf-8"))
      .resolves.toBe("outside must remain unchanged\n");
    await expect(readFile(join(bookDir, "chapters", "0003_Old_Title.md"), "utf-8"))
      .resolves.toBe(BASELINE_FILES["chapters/0003_Old_Title.md"]);
  });
});

interface MutableManifest {
  transactionId: string;
  chapterNumber: number;
  chapterFiles: string[];
  entries: Array<{ relativePath: string; kind: string }>;
}

async function createFixture(): Promise<{ readonly projectRoot: string; readonly bookDir: string }> {
  const projectRoot = await mkdtemp(join(tmpdir(), "inkos-chapter-transaction-"));
  roots.push(projectRoot);
  const bookDir = join(projectRoot, "books", BOOK_ID);
  for (const [relativePath, content] of Object.entries(BASELINE_FILES)) {
    await writeFixtureFile(bookDir, relativePath, content);
  }
  await writeFixtureFile(bookDir, "story/memory.db", "derived memory database\n");
  return { projectRoot, bookDir };
}

async function writeFixtureFile(bookDir: string, relativePath: string, content: string): Promise<void> {
  const path = join(bookDir, relativePath);
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, content, "utf-8");
}

async function expectBaselineRestored(bookDir: string): Promise<void> {
  for (const [relativePath, content] of Object.entries(BASELINE_FILES)) {
    await expect(readFile(join(bookDir, relativePath), "utf-8")).resolves.toBe(content);
  }
  expect((await readdir(join(bookDir, "chapters"))).sort()).toEqual([
    "0003_Old_Title.md",
    "index.json",
  ]);
  for (const relativePath of [
    "story/state/new-runtime-file.json",
    "story/canon_checkpoints/volume-0002.json",
    "story/snapshots/3/new-snapshot-file.md",
    "story/memory.db",
  ]) {
    await expect(readFile(join(bookDir, relativePath), "utf-8"))
      .rejects.toMatchObject({ code: "ENOENT" });
  }
}
