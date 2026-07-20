import { describe, expect, it } from "vitest";
import { ChapterTraceSchema } from "../models/input-governance.js";
import {
  buildSkillContextPlan,
  createSkillRegistry,
} from "../skills/index.js";

describe("skill context planner", () => {
  it("turns longform-writing context needs into protected/compressible planning metadata", () => {
    const registry = createSkillRegistry();
    const skill = registry.getSkill("longform-writing");
    expect(skill).toBeDefined();

    const plan = buildSkillContextPlan({
      skills: [skill!],
      appliesTo: "composer",
    });

    expect(plan.usedSkillIds).toEqual(["longform-writing"]);
    expect(plan.promptPackIds).toContain("longform.writer");
    expect(plan.contextNeedIds).toContain("author-intent");
    expect(plan.contextNeedIds).toContain("current-focus");
    expect(plan.protectedNeeds.map((need) => need.id)).toContain("active-hooks");
    expect(plan.compressibleNeeds.map((need) => need.id)).toContain("episodic-memory");
  });

  it("filters context needs by consumer while preserving skill metadata", () => {
    const registry = createSkillRegistry();
    const skill = registry.getSkill("interactive-film-authoring");
    expect(skill).toBeDefined();

    const plan = buildSkillContextPlan({
      skills: [skill!],
      appliesTo: "image",
    });

    expect(plan.usedSkillIds).toEqual(["interactive-film-authoring"]);
    expect(plan.contextNeedIds).toContain("visual-style");
    expect(plan.contextNeedIds).not.toContain("previous-node-summaries");
  });

  it("extends chapter trace with skill provenance", () => {
    const parsed = ChapterTraceSchema.parse({
      chapter: 1,
      plannerInputs: [],
      composerInputs: [],
      selectedSources: [],
      usedSkills: ["longform-writing"],
      promptPacks: ["longform.writer"],
      contextNeeds: ["author-intent"],
    });

    expect(parsed.usedSkills).toEqual(["longform-writing"]);
    expect(parsed.promptPacks).toEqual(["longform.writer"]);
    expect(parsed.contextNeeds).toEqual(["author-intent"]);
  });
});
