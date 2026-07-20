import type { CapabilitySkillManifest, SkillContextNeed } from "./types.js";

export interface SkillContextPlanInput {
  readonly skills: ReadonlyArray<CapabilitySkillManifest>;
  readonly appliesTo?: string;
}

export interface SkillContextPlan {
  readonly usedSkillIds: ReadonlyArray<string>;
  readonly promptPackIds: ReadonlyArray<string>;
  readonly contextNeeds: ReadonlyArray<SkillContextNeed>;
  readonly contextNeedIds: ReadonlyArray<string>;
  readonly protectedNeeds: ReadonlyArray<SkillContextNeed>;
  readonly compressibleNeeds: ReadonlyArray<SkillContextNeed>;
}

export function buildSkillContextPlan(input: SkillContextPlanInput): SkillContextPlan {
  const appliesTo = input.appliesTo?.trim().toLowerCase();
  const usedSkillIds = dedupe(input.skills.map((skill) => skill.id));
  const promptPackIds = dedupe(input.skills.flatMap((skill) => skill.promptPacks));
  const contextNeeds = dedupeNeeds(input.skills.flatMap((skill) =>
    skill.contextNeeds.filter((need) => appliesToNeed(need, appliesTo)),
  ));

  return {
    usedSkillIds,
    promptPackIds,
    contextNeeds,
    contextNeedIds: contextNeeds.map((need) => need.id),
    protectedNeeds: contextNeeds.filter((need) => need.tier === "protected"),
    compressibleNeeds: contextNeeds.filter((need) => need.tier === "compressible"),
  };
}

export function contextNeedById(
  plan: SkillContextPlan,
  id: string,
): SkillContextNeed | undefined {
  return plan.contextNeeds.find((need) => need.id === id);
}

export function contextNeedPurpose(
  plan: SkillContextPlan,
  id: string,
  fallback: string,
): string {
  return contextNeedById(plan, id)?.purpose ?? fallback;
}

function appliesToNeed(need: SkillContextNeed, appliesTo: string | undefined): boolean {
  if (!appliesTo || need.appliesTo.length === 0) return true;
  return need.appliesTo.some((value) => value.trim().toLowerCase() === appliesTo);
}

function dedupe(values: ReadonlyArray<string>): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  for (const value of values) {
    if (!value || seen.has(value)) continue;
    seen.add(value);
    out.push(value);
  }
  return out;
}

function dedupeNeeds(needs: ReadonlyArray<SkillContextNeed>): SkillContextNeed[] {
  const out: SkillContextNeed[] = [];
  const seen = new Set<string>();
  for (const need of needs) {
    if (seen.has(need.id)) continue;
    seen.add(need.id);
    out.push(need);
  }
  return out;
}
