import { createRequire } from "node:module";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { MemoryDB, type StoredSummary } from "../state/memory-db.js";

const require = createRequire(import.meta.url);
const sqliteIt = (() => {
  try {
    require("node:sqlite");
    return it;
  } catch {
    return it.skip;
  }
})();
const roots: string[] = [];

afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("MemoryDB transactions", () => {
  sqliteIt("restores summaries when replacement fails after DELETE and a partial insert", async () => {
    const bookDir = await createBookDir();
    const db = new MemoryDB(bookDir);
    const original = [summary(1, "Original one"), summary(2, "Original two")];
    db.replaceSummaries(original);
    const upsert = db.upsertSummary.bind(db);
    let inserts = 0;
    vi.spyOn(db, "upsertSummary").mockImplementation((value) => {
      inserts += 1;
      if (inserts === 2) throw new Error("injected summary insert failure");
      upsert(value);
    });

    expect(() => db.replaceSummaries([
      summary(1, "Replacement one"),
      summary(2, "Replacement two"),
    ])).toThrow("injected summary insert failure");
    expect(db.getSummaries(1, 2).map((value) => value.title)).toEqual([
      "Original one",
      "Original two",
    ]);
    db.close();
  });

  sqliteIt("rolls back an asynchronous fact-history rebuild failure", async () => {
    const bookDir = await createBookDir();
    const db = new MemoryDB(bookDir);
    db.addFact({
      subject: "ROLE_A",
      predicate: "location",
      object: "Old city",
      validFromChapter: 1,
      validUntilChapter: null,
      sourceChapter: 1,
    });

    await expect(db.transactionAsync(async () => {
      db.resetFacts();
      db.addFact({
        subject: "ROLE_A",
        predicate: "location",
        object: "Partial city",
        validFromChapter: 2,
        validUntilChapter: null,
        sourceChapter: 2,
      });
      throw new Error("injected fact rebuild failure");
    })).rejects.toThrow("injected fact rebuild failure");
    expect(db.getCurrentFacts()).toEqual([
      expect.objectContaining({ object: "Old city", sourceChapter: 1 }),
    ]);
    db.close();
  });
});

async function createBookDir(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "inkos-memory-transaction-"));
  roots.push(root);
  const bookDir = join(root, "book");
  await mkdir(join(bookDir, "story"), { recursive: true });
  return bookDir;
}

function summary(chapter: number, title: string): StoredSummary {
  return {
    chapter,
    title,
    characters: "ROLE_A",
    events: "event",
    stateChanges: "change",
    hookActivity: "hook",
    mood: "tense",
    chapterType: "progress",
  };
}
