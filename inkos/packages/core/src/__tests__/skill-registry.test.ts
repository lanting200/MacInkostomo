import { describe, expect, it } from "vitest";
import {
  createSkillRegistry,
  BUILTIN_CAPABILITY_SKILLS,
} from "../skills/index.js";

describe("capability skill registry", () => {
  it("ships the first built-in writing/play/film skills with context needs", () => {
    const registry = createSkillRegistry();
    const ids = registry.listSkills().map((skill) => skill.id).sort();

    expect(ids).toEqual([
      "interactive-film-authoring",
      "longform-writing",
      "open-world-play",
    ]);
    for (const skill of registry.listSkills()) {
      expect(skill.contextNeeds.length).toBeGreaterThan(0);
      expect(skill.promptPacks.length).toBeGreaterThan(0);
    }
  });

  it("resolves forced skills even when the instruction would not auto-select them", () => {
    const registry = createSkillRegistry();

    const result = registry.resolveSkills({
      requestedSkills: ["interactive-film-authoring"],
      sessionKind: "chat",
      instruction: "随便聊聊这个故事标题",
    });

    expect(result.usedSkills.map((skill) => skill.id)).toEqual(["interactive-film-authoring"]);
    expect(result.forcedSkillIds).toEqual(["interactive-film-authoring"]);
    expect(result.missingSkillIds).toEqual([]);
  });

  it("reports unknown forced skills instead of silently dropping them", () => {
    const registry = createSkillRegistry();

    const result = registry.resolveSkills({
      requestedSkills: ["not-a-skill", "longform-writing"],
      instruction: "继续写下一章",
    });

    expect(result.usedSkills.map((skill) => skill.id)).toEqual(["longform-writing"]);
    expect(result.missingSkillIds).toEqual(["not-a-skill"]);
  });

  it("excludes disabled skills from automatic selection", () => {
    const registry = createSkillRegistry();

    const result = registry.resolveSkills({
      disabledSkills: ["interactive-film-authoring"],
      instruction: "把这个小说改成互动影游，做变量旗标和多结局",
    });

    expect(result.autoSkillIds).not.toContain("interactive-film-authoring");
    expect(result.usedSkills.map((skill) => skill.id)).not.toContain("interactive-film-authoring");
    expect(result.disabledSkillIds).toEqual(["interactive-film-authoring"]);
  });

  it("auto-selects skill candidates from session kind and natural-language instruction", () => {
    const registry = createSkillRegistry();

    expect(registry.resolveSkills({
      sessionKind: "play",
      instruction: "我走进旧图书馆，查看桌上的信",
    }).usedSkills.map((skill) => skill.id)).toEqual(["open-world-play"]);

    expect(registry.resolveSkills({
      sessionKind: "chat",
      instruction: "做一个互动影游，需要分支剧情、变量旗标和两个结局",
    }).usedSkills.map((skill) => skill.id)).toEqual(["interactive-film-authoring"]);

    expect(registry.resolveSkills({
      sessionKind: "book",
      instruction: "继续写下一章，注意伏笔一致性",
    }).usedSkills.map((skill) => skill.id)).toEqual(["longform-writing"]);
  });

  it("keeps built-in manifests schema-valid at module load time", () => {
    expect(BUILTIN_CAPABILITY_SKILLS).toHaveLength(3);
  });
});
