import { describe, expect, it } from "vitest";
import { buildSettlerSystemPrompt, buildSettlerUserPrompt } from "../agents/settler-prompts.js";
import type { BookConfig } from "../models/book.js";
import type { GenreProfile } from "../models/genre-profile.js";

const BOOK: BookConfig = {
  id: "settler-book",
  title: "Settler Book",
  platform: "tomato",
  genre: "other",
  status: "active",
  targetChapters: 20,
  chapterWordCount: 3000,
  createdAt: "2026-07-20T00:00:00.000Z",
  updatedAt: "2026-07-20T00:00:00.000Z",
};

const GENRE: GenreProfile = {
  id: "other",
  name: "General",
  language: "en",
  chapterTypes: ["mainline"],
  fatigueWords: [],
  numericalSystem: false,
  powerScaling: false,
  eraResearch: false,
  pacingRule: "",
  satisfactionTypes: [],
  auditDimensions: [],
};

describe("buildSettlerUserPrompt", () => {
  it("includes the persistent object ledger in settlement context", () => {
    const prompt = buildSettlerUserPrompt({
      chapterNumber: 20,
      title: "旧令重现",
      content: "玄微摸出镇妖司旧令牌，木质边缘仍有那道缺口。",
      currentState: "# 当前状态",
      ledger: "# 资源账本",
      objectLedger: [
        "# 持久对象账本",
        "| object_id | 名称 | 材质 | 刻字 |",
        "| xuanwei-token | 镇妖司旧令牌 | 木质 | 镇妖司 |",
      ].join("\n"),
      hooks: "# 伏笔池",
      chapterSummaries: "(文件尚未创建)",
      subplotBoard: "(文件尚未创建)",
      emotionalArcs: "(文件尚未创建)",
      characterMatrix: "(文件尚未创建)",
      volumeOutline: "# 卷纲",
    });

    expect(prompt).toContain("当前持久对象账本（跨章硬事实）");
    expect(prompt).toContain("xuanwei-token");
    expect(prompt).toContain("木质");
    expect(prompt).toContain("玄微摸出镇妖司旧令牌");
  });

  it("emits English long-form delta rules for English books", () => {
    const prompt = buildSettlerSystemPrompt(BOOK, GENRE, null, "en");
    expect(prompt).toContain("Long-form consistency delta");
    expect(prompt).toContain("write every body-supported change to longFormConsistency");
    expect(prompt).toContain('"longFormConsistency"');
    expect(prompt).not.toContain("长篇连续性增量");
  });
});
