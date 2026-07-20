import { afterEach, describe, expect, it } from "vitest";
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import {
  BookTreeTransaction,
  withBookTreeTransaction,
} from "../state/book-tree-transaction.js";
import { StateManager } from "../state/manager.js";

const roots: string[] = [];
const BOOK_ID = "whole-book-fixture";
const BASELINE = {
  "book.json": "baseline metadata\n",
  "chapters/index.json": "baseline index\n",
  "chapters/0001_First.md": "baseline first chapter\n",
  "chapters/0002_Second.md": "baseline second chapter\n",
  "story/current_state.md": "baseline truth\n",
  "story/state/manifest.json": "baseline runtime state\n",
  "story/snapshots/1/current_state.md": "baseline snapshot one\n",
  "story/snapshots/2/current_state.md": "baseline snapshot two\n",
  "story/runtime/chapter-0002.json": "baseline runtime artifact\n",
} as const;

afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("BookTreeTransaction", () => {
  it("restores the complete book tree when a destructive operation fails", async () => {
    const { bookDir } = await createFixture();

    await expect(withBookTreeTransaction(bookDir, async () => {
      await rm(join(bookDir, "chapters", "0001_First.md"));
      await rm(join(bookDir, "story", "snapshots"), { recursive: true });
      await writeFixtureFile(bookDir, "chapters/0003_New.md", "partial import\n");
      await writeFixtureFile(bookDir, "story/current_state.md", "partial truth\n");
      throw new Error("injected whole-book mutation failure");
    })).rejects.toThrow("injected whole-book mutation failure");

    await expectBaseline(bookDir);
    await expect(readFile(join(bookDir, "chapters", "0003_New.md"), "utf-8"))
      .rejects.toMatchObject({ code: "ENOENT" });
  });

  it("recovers a prepared whole-book journal on the next book-lock acquisition", async () => {
    const { projectRoot, bookDir } = await createFixture();
    const state = new StateManager(projectRoot);
    const firstRelease = await state.acquireBookLock(BOOK_ID);
    await BookTreeTransaction.begin(bookDir);
    await rm(join(bookDir, "chapters", "0002_Second.md"));
    await writeFixtureFile(bookDir, "story/current_state.md", "interrupted import truth\n");
    await writeFixtureFile(bookDir, "chapters/0003_New.md", "interrupted import body\n");
    await firstRelease();

    const secondRelease = await state.acquireBookLock(BOOK_ID);
    try {
      await expectBaseline(bookDir);
      await expect(readFile(join(bookDir, ".write.lock"), "utf-8"))
        .resolves.toContain(`pid:${process.pid}`);
    } finally {
      await secondRelease();
    }
    await expect(readFile(join(bookDir, ".write.lock"), "utf-8"))
      .rejects.toMatchObject({ code: "ENOENT" });
  });
});

async function createFixture(): Promise<{ readonly projectRoot: string; readonly bookDir: string }> {
  const projectRoot = await mkdtemp(join(tmpdir(), "inkos-book-tree-transaction-"));
  roots.push(projectRoot);
  const bookDir = join(projectRoot, "books", BOOK_ID);
  for (const [relativePath, content] of Object.entries(BASELINE)) {
    await writeFixtureFile(bookDir, relativePath, content);
  }
  return { projectRoot, bookDir };
}

async function writeFixtureFile(bookDir: string, relativePath: string, content: string): Promise<void> {
  const path = join(bookDir, relativePath);
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, content, "utf-8");
}

async function expectBaseline(bookDir: string): Promise<void> {
  for (const [relativePath, content] of Object.entries(BASELINE)) {
    await expect(readFile(join(bookDir, relativePath), "utf-8")).resolves.toBe(content);
  }
  expect((await readdir(join(bookDir, "chapters"))).sort()).toEqual([
    "0001_First.md",
    "0002_Second.md",
    "index.json",
  ]);
}
