export interface StudioSkill {
  readonly id: string;
  readonly name: string;
  readonly description?: string;
  readonly whenToUse?: string;
  readonly triggers?: ReadonlyArray<string>;
  readonly sessionKinds?: ReadonlyArray<string>;
  readonly promptPacks?: ReadonlyArray<string>;
  readonly toolHints?: ReadonlyArray<string>;
  readonly contextNeeds?: ReadonlyArray<string>;
  readonly body?: string;
  readonly source?: string;
  readonly editable?: boolean;
  readonly path?: string;
}

export interface SkillDraft {
  readonly id: string;
  readonly name: string;
  readonly description: string;
  readonly whenToUse: string;
  readonly triggers: string;
  readonly sessionKinds: string;
  readonly body: string;
}

export interface SkillPayload {
  readonly id?: string;
  readonly name?: string;
  readonly description?: string;
  readonly whenToUse?: string;
  readonly triggers?: string[];
  readonly sessionKinds?: string[];
  readonly body?: string;
}

export function createEmptySkillDraft(): SkillDraft {
  return {
    id: "",
    name: "",
    description: "",
    whenToUse: "",
    triggers: "",
    sessionKinds: "chat,book,short,play",
    body: "",
  };
}

export function normalizeSkillId(value: string): string {
  return value.trim().toLowerCase().replace(/[^a-z0-9-]+/g, "-").replace(/^-+|-+$/g, "");
}

export function splitSkillList(value: string): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  for (const part of value.split(/[,，\n]/)) {
    const item = part.trim();
    if (!item || seen.has(item)) continue;
    seen.add(item);
    out.push(item);
  }
  return out;
}

export function toggleSelectedSkillIds(selected: ReadonlyArray<string>, skillId: string): string[] {
  const id = normalizeSkillId(skillId);
  if (!id) return [...selected];
  if (selected.includes(id)) return selected.filter((item) => item !== id);
  return [...selected, id];
}

export function selectedSkillIdsForSend(selected: ReadonlyArray<string>): string[] | undefined {
  const ids = Array.from(new Set(selected.map(normalizeSkillId).filter(Boolean)));
  return ids.length > 0 ? ids : undefined;
}

export function skillDraftFromSkill(skill: StudioSkill): SkillDraft {
  return {
    id: skill.id,
    name: skill.name,
    description: skill.description ?? "",
    whenToUse: skill.whenToUse ?? "",
    triggers: (skill.triggers ?? []).join(", "),
    sessionKinds: (skill.sessionKinds ?? []).join(", "),
    body: skill.body ?? "",
  };
}

export function skillDraftToPayload(draft: SkillDraft, includeId = true): SkillPayload {
  const id = normalizeSkillId(draft.id);
  return {
    ...(includeId && id ? { id } : {}),
    name: draft.name.trim() || id,
    description: draft.description.trim(),
    whenToUse: draft.whenToUse.trim(),
    triggers: splitSkillList(draft.triggers),
    sessionKinds: splitSkillList(draft.sessionKinds),
    body: draft.body.trim(),
  };
}
