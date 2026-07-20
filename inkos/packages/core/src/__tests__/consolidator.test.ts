import { describe, expect, it } from "vitest";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ConsolidatorAgent } from "../agents/consolidator.js";

describe("ConsolidatorAgent", () => {
  it("parses Chinese volume boundaries with full-width parentheses and chapter ranges", () => {
    const agent = new ConsolidatorAgent({
      client: {} as ConstructorParameters<typeof ConsolidatorAgent>[0]["client"],
      model: "test-model",
      projectRoot: "/tmp",
    });

    const outline = [
      "# Volume Outline",
      "",
      "### 第一卷：死而复生的实习期（1-20章）",
      "- 主角重返公司，卷入第一起异常事故",
      "",
      "### 第二卷：时间线上的猎手（21-60章）",
      "- 追查时间裂隙背后的操控者",
      "",
    ].join("\n");

    const boundaries = (agent as unknown as {
      parseVolumeBoundaries: (input: string) => Array<{ name: string; startCh: number; endCh: number }>;
    }).parseVolumeBoundaries(outline);

    expect(boundaries).toEqual([
      { name: "第一卷：死而复生的实习期", startCh: 1, endCh: 20 },
      { name: "第二卷：时间线上的猎手", startCh: 21, endCh: 60 },
    ]);
  });

  it("prefers structured Publisher boundaries and does not complete a volume with a missing chapter", async () => {
    const bookDir = await mkdtemp(join(tmpdir(), "inkos-consolidator-plan-"));
    const storyDir = join(bookDir, "story");
    await mkdir(join(storyDir, "outline"), { recursive: true });
    try {
      await writeFile(join(storyDir, "outline", "volume_map.md"), "# Volume 1 (Chapters 1-1)\n", "utf-8");
      await writeFile(join(storyDir, "chapter_summaries.md"), [
        "| Chapter | Title | Characters | Events | State Changes | Hook Activity | Mood | Chapter Type |",
        "| --- | --- | --- | --- | --- | --- | --- | --- |",
        "| 1 | One | A | E1 | S1 | H1 | tense | setup |",
        "| 3 | Three | A | E3 | S3 | H3 | tense | payoff |",
      ].join("\n"), "utf-8");
      await writeFile(join(bookDir, "long-form-plan.json"), JSON.stringify({
        version: 1,
        revision: 1,
        bookId: "structured-boundary-book",
        constraints: {
          targetTotalWords: 3000,
          volumeCount: 1,
          targetChapterWords: 1000,
          chapterWordTolerance: 15,
          specialConstraints: [],
        },
        plan: {
          targetChapters: 3,
          chapterWordRange: { min: 850, max: 1150 },
          volumes: [{ number: 1, startChapter: 1, endChapter: 3, chapterCount: 3, targetWords: 3000 }],
          chapters: [1, 2, 3].map((number) => ({
            number,
            volumeNumber: 1,
            targetWords: 1000,
            minWords: 850,
            maxWords: 1150,
          })),
        },
        source: "created",
        createdAt: "2026-07-20T00:00:00.000Z",
        updatedAt: "2026-07-20T00:00:00.000Z",
      }), "utf-8");

      const agent = new ConsolidatorAgent({
        client: {} as ConstructorParameters<typeof ConsolidatorAgent>[0]["client"],
        model: "test-model",
        projectRoot: bookDir,
      });
      const result = await agent.consolidate(bookDir);
      expect(result.archivedVolumes).toBe(0);
      expect(result.retainedChapters).toBe(2);
    } finally {
      await rm(bookDir, { recursive: true, force: true });
    }
  });
});
