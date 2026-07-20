import { readFile, readdir, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { delimiter, isAbsolute, join } from "node:path";
import yaml from "js-yaml";
import {
  CapabilitySkillManifestSchema,
  type CapabilitySkillManifest,
} from "./types.js";

export interface LoadExternalCapabilitySkillsInput {
  readonly externalDirs: ReadonlyArray<string>;
}

export interface ExternalSkillDiagnostic {
  readonly path: string;
  readonly message: string;
}

export interface LoadExternalCapabilitySkillsResult {
  readonly skills: ReadonlyArray<CapabilitySkillManifest>;
  readonly diagnostics: ReadonlyArray<ExternalSkillDiagnostic>;
}

export interface LoadConfiguredCapabilitySkillsInput {
  readonly projectRoot: string;
  readonly env?: NodeJS.ProcessEnv | Record<string, string | undefined>;
  readonly userRoot?: string;
}

export async function loadExternalCapabilitySkills(
  input: LoadExternalCapabilitySkillsInput,
): Promise<LoadExternalCapabilitySkillsResult> {
  const skillDirs = await discoverSkillDirs(input.externalDirs);
  const skills: CapabilitySkillManifest[] = [];
  const diagnostics: ExternalSkillDiagnostic[] = [];

  for (const dir of skillDirs) {
    const skillPath = join(dir, "SKILL.md");
    try {
      skills.push(await loadSkillManifest(skillPath));
    } catch (error) {
      diagnostics.push({
        path: skillPath,
        message: error instanceof Error ? error.message : String(error),
      });
    }
  }

  return { skills, diagnostics };
}

export async function loadConfiguredCapabilitySkills(
  input: LoadConfiguredCapabilitySkillsInput,
): Promise<LoadExternalCapabilitySkillsResult> {
  const candidates = configuredSkillDirs(input);
  const skills: CapabilitySkillManifest[] = [];
  const diagnostics: ExternalSkillDiagnostic[] = [];

  for (const candidate of candidates) {
    try {
      const result = await loadExternalCapabilitySkills({ externalDirs: [candidate.path] });
      skills.push(...result.skills);
      diagnostics.push(...result.diagnostics);
    } catch (error) {
      if (!candidate.explicit && isMissingPathError(error)) continue;
      diagnostics.push({
        path: candidate.path,
        message: error instanceof Error ? error.message : String(error),
      });
    }
  }

  return { skills, diagnostics };
}

interface ConfiguredSkillDir {
  readonly path: string;
  readonly explicit: boolean;
}

function configuredSkillDirs(input: LoadConfiguredCapabilitySkillsInput): ConfiguredSkillDir[] {
  const env = input.env ?? process.env;
  const envDirs = (env.INKOS_SKILL_DIRS ?? "")
    .split(delimiter)
    .map((value) => value.trim())
    .filter(Boolean);
  const userRoot = input.userRoot ?? join(homedir(), ".inkos");
  return [
    { path: join(input.projectRoot, ".inkos", "skills"), explicit: false },
    { path: join(userRoot, "skills"), explicit: false },
    ...envDirs.map((path) => ({ path, explicit: true })),
  ];
}

function isMissingPathError(error: unknown): boolean {
  return typeof error === "object"
    && error !== null
    && "code" in error
    && (error as { code?: unknown }).code === "ENOENT";
}

async function discoverSkillDirs(externalDirs: ReadonlyArray<string>): Promise<string[]> {
  const dirs: string[] = [];
  for (const dir of externalDirs) {
    if (!isAbsolute(dir)) {
      throw new Error(`External skill directory must be absolute: ${dir}`);
    }
    const info = await stat(dir);
    if (!info.isDirectory()) {
      throw new Error(`External skill path is not a directory: ${dir}`);
    }
    if (await hasSkillManifest(dir)) {
      dirs.push(dir);
      continue;
    }

    const entries = await readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const child = join(dir, entry.name);
      if (await hasSkillManifest(child)) dirs.push(child);
    }
  }
  return [...new Set(dirs)].sort();
}

async function hasSkillManifest(dir: string): Promise<boolean> {
  try {
    const info = await stat(join(dir, "SKILL.md"));
    return info.isFile();
  } catch {
    return false;
  }
}

async function loadSkillManifest(skillPath: string): Promise<CapabilitySkillManifest> {
  const raw = await readFile(skillPath, "utf-8");
  const parsed = parseFrontmatter(raw);
  if (!parsed.data || typeof parsed.data !== "object" || Array.isArray(parsed.data)) {
    throw new Error("SKILL.md frontmatter must be a YAML object.");
  }
  return CapabilitySkillManifestSchema.parse({
    ...(parsed.data as Record<string, unknown>),
    body: parsed.body.trim(),
    source: "external",
  });
}

function parseFrontmatter(raw: string): { readonly data: unknown; readonly body: string } {
  const normalized = raw.replace(/^\uFEFF/, "");
  if (!normalized.startsWith("---\n")) {
    throw new Error("SKILL.md must start with YAML frontmatter delimiters.");
  }
  const end = normalized.indexOf("\n---", 4);
  if (end < 0) {
    throw new Error("SKILL.md is missing closing YAML frontmatter delimiter.");
  }
  const frontmatter = normalized.slice(4, end).trim();
  const body = normalized.slice(end + "\n---".length).replace(/^\r?\n/, "");
  return {
    data: yaml.load(frontmatter),
    body,
  };
}
