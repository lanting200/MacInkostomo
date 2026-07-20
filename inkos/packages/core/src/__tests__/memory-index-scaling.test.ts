import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

interface FakeFact {
  id: number;
  subject: string;
  predicate: string;
  object: string;
  validFromChapter: number;
  validUntilChapter: number | null;
  sourceChapter: number;
}

class CountingMemoryDB {
  static facts: FakeFact[] = [];
  static metadata = new Map<string, string>();
  static nextId = 1;
  static resets = 0;
  static adds = 0;
  static invalidations = 0;

  static reset(): void {
    this.facts = [];
    this.metadata.clear();
    this.nextId = 1;
    this.resets = 0;
    this.adds = 0;
    this.invalidations = 0;
  }

  close(): void {}
  transaction<TResult>(operation: () => TResult): TResult { return operation(); }
  transactionAsync<TResult>(operation: () => Promise<TResult>): Promise<TResult> { return operation(); }
  getMetadata(key: string): string | undefined { return CountingMemoryDB.metadata.get(key); }
  setMetadata(key: string, value: string): void { CountingMemoryDB.metadata.set(key, value); }
  getCurrentFacts(): FakeFact[] { return CountingMemoryDB.facts.filter((fact) => fact.validUntilChapter === null); }
  resetFacts(): void {
    CountingMemoryDB.resets += 1;
    CountingMemoryDB.facts = [];
    CountingMemoryDB.nextId = 1;
  }
  addFact(fact: Omit<FakeFact, "id">): number {
    CountingMemoryDB.adds += 1;
    const id = CountingMemoryDB.nextId++;
    CountingMemoryDB.facts.push({ id, ...fact });
    return id;
  }
  invalidateFact(id: number, chapter: number): void {
    CountingMemoryDB.invalidations += 1;
    const fact = CountingMemoryDB.facts.find((candidate) => candidate.id === id);
    if (fact) fact.validUntilChapter = chapter;
  }
}

const roots: string[] = [];

afterEach(async () => {
  vi.resetModules();
  vi.doUnmock("../state/memory-db.js");
  CountingMemoryDB.reset();
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("long-form memory index scaling", () => {
  it("keeps fact-history database operations linear from 1000 to 2000 chapters", async () => {
    vi.doMock("../state/memory-db.js", () => ({ MemoryDB: CountingMemoryDB }));
    const { PipelineRunner } = await import("../pipeline/runner.js");
    const root = await mkdtemp(join(tmpdir(), "inkos-memory-scaling-"));
    roots.push(root);
    const bookId = "two-thousand-chapters";
    const bookDir = join(root, "books", bookId);
    const runner = new PipelineRunner({
      client: {} as ConstructorParameters<typeof PipelineRunner>[0]["client"],
      model: "no-llm",
      projectRoot: root,
    });
    const syncFacts = (
      runner as unknown as {
        syncCurrentStateFactHistory(id: string, chapter: number): Promise<void>;
      }
    ).syncCurrentStateFactHistory.bind(runner);

    let serializedBytes = 0;
    let operationsAt1000 = 0;
    for (let chapter = 1; chapter <= 2_000; chapter += 1) {
      const snapshotDir = join(bookDir, "story", "snapshots", String(chapter), "state");
      await mkdir(snapshotDir, { recursive: true });
      const snapshot = JSON.stringify({
        chapter,
        facts: [{
          subject: "ROLE_A",
          predicate: "location",
          object: `location-${chapter}`,
          validFromChapter: chapter,
          validUntilChapter: null,
          sourceChapter: chapter,
        }],
      });
      serializedBytes += Buffer.byteLength(snapshot);
      await writeFile(join(snapshotDir, "current_state.json"), snapshot, "utf-8");
      await syncFacts(bookId, chapter);
      if (chapter === 1_000) {
        operationsAt1000 = CountingMemoryDB.adds + CountingMemoryDB.invalidations + CountingMemoryDB.resets;
      }
    }

    const operationsAt2000 = CountingMemoryDB.adds
      + CountingMemoryDB.invalidations
      + CountingMemoryDB.resets;
    expect(CountingMemoryDB.resets).toBe(1);
    expect(operationsAt1000).toBeLessThanOrEqual(2_001);
    expect(operationsAt2000 - operationsAt1000).toBeLessThanOrEqual(2_001);
    expect(operationsAt2000).toBeLessThanOrEqual(operationsAt1000 * 2 + 2);
    expect(serializedBytes).toBeLessThan(1_000_000);
  }, 30_000);
});
