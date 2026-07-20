import { describe, expect, it } from "vitest";
import { buildSettlerUserPrompt } from "../agents/settler-prompts.js";

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
});
