import { BUILTIN_CAPABILITY_SKILLS } from "./builtin.js";
import type {
  CapabilitySkillManifest,
  SkillRegistry,
  SkillResolutionInput,
  SkillResolutionResult,
} from "./types.js";

export interface CreateSkillRegistryOptions {
  readonly skills?: ReadonlyArray<CapabilitySkillManifest>;
}

export function createSkillRegistry(options: CreateSkillRegistryOptions = {}): SkillRegistry {
  const skills = dedupeSkills([
    ...BUILTIN_CAPABILITY_SKILLS,
    ...(options.skills ?? []),
  ]);
  const byId = new Map(skills.map((skill) => [skill.id, skill]));

  return {
    listSkills() {
      return skills;
    },
    getSkill(id: string) {
      return byId.get(normalizeSkillId(id));
    },
    resolveSkills(input: SkillResolutionInput) {
      const disabled = new Set(normalizeIdList(input.disabledSkills));
      const requested = normalizeIdList(input.requestedSkills);
      const candidates = normalizeIdList(input.candidateSkills);
      const missingSkillIds: string[] = [];
      const disabledSkillIds = [...disabled].filter((id) => byId.has(id));
      const used = new Map<string, CapabilitySkillManifest>();
      const forcedSkillIds: string[] = [];

      for (const id of requested) {
        const skill = byId.get(id);
        if (!skill) {
          missingSkillIds.push(id);
          continue;
        }
        if (disabled.has(id)) continue;
        used.set(id, skill);
        forcedSkillIds.push(id);
      }

      const autoSkillIds: string[] = [];
      for (const id of candidates) {
        const skill = byId.get(id);
        if (!skill || disabled.has(id) || used.has(id)) continue;
        used.set(id, skill);
        autoSkillIds.push(id);
      }

      for (const skill of skills) {
        if (disabled.has(skill.id) || used.has(skill.id)) continue;
        if (!matchesSkill(skill, input)) continue;
        used.set(skill.id, skill);
        autoSkillIds.push(skill.id);
      }

      return {
        usedSkills: [...used.values()],
        forcedSkillIds,
        autoSkillIds,
        missingSkillIds: dedupeStrings(missingSkillIds),
        disabledSkillIds,
        availableSkillIds: skills.map((skill) => skill.id),
      } satisfies SkillResolutionResult;
    },
  };
}

function dedupeSkills(skills: ReadonlyArray<CapabilitySkillManifest>): CapabilitySkillManifest[] {
  const byId = new Map<string, CapabilitySkillManifest>();
  for (const skill of skills) {
    byId.set(normalizeSkillId(skill.id), {
      ...skill,
      id: normalizeSkillId(skill.id),
    });
  }
  return [...byId.values()].sort((left, right) => left.id.localeCompare(right.id));
}

function normalizeIdList(values: ReadonlyArray<string> | undefined): string[] {
  return dedupeStrings((values ?? []).map(normalizeSkillId).filter(Boolean));
}

function normalizeSkillId(value: string): string {
  return value.trim().toLowerCase();
}

function dedupeStrings(values: ReadonlyArray<string>): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  for (const value of values) {
    if (!value || seen.has(value)) continue;
    seen.add(value);
    out.push(value);
  }
  return out;
}

function matchesSkill(skill: CapabilitySkillManifest, input: SkillResolutionInput): boolean {
  const sessionKind = input.sessionKind?.trim().toLowerCase();
  if (sessionKind && skill.sessionKinds.some((kind) => kind.toLowerCase() === sessionKind)) {
    return true;
  }

  const instruction = input.instruction?.trim().toLowerCase();
  if (!instruction) return false;

  return skill.triggers.some((trigger) => {
    const normalized = trigger.trim().toLowerCase();
    return normalized.length > 0 && instruction.includes(normalized);
  });
}
