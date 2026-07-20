import { randomUUID } from "node:crypto";
import { mkdir, rename, rm, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import yaml from "js-yaml";
import type {
  ChapterTrace,
  ContextPackage,
  RuleStack,
} from "../models/input-governance.js";

export interface RuntimeArtifactWriteResult {
  readonly contextPath: string;
  readonly ruleStackPath: string;
  readonly tracePath: string;
}

export async function writeGovernedRuntimeArtifacts(params: {
  readonly runtimeDir: string;
  readonly chapterNumber: number;
  readonly contextPackage: ContextPackage;
  readonly ruleStack: RuleStack;
  readonly trace: ChapterTrace;
}): Promise<RuntimeArtifactWriteResult> {
  await mkdir(params.runtimeDir, { recursive: true });

  const chapterSlug = `chapter-${String(params.chapterNumber).padStart(4, "0")}`;
  const contextPath = join(params.runtimeDir, `${chapterSlug}.context.json`);
  const ruleStackPath = join(params.runtimeDir, `${chapterSlug}.rule-stack.yaml`);
  const tracePath = join(params.runtimeDir, `${chapterSlug}.trace.json`);

  await writeAtomicText(contextPath, `${JSON.stringify(params.contextPackage, null, 2)}\n`);
  await writeAtomicText(ruleStackPath, yaml.dump(params.ruleStack, { lineWidth: 120 }));
  await writeAtomicText(tracePath, `${JSON.stringify(params.trace, null, 2)}\n`);

  return {
    contextPath,
    ruleStackPath,
    tracePath,
  };
}

export async function writeAtomicText(path: string, content: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const tempPath = join(dirname(path), `.${basename(path)}.${process.pid}.${randomUUID()}.tmp`);
  try {
    await writeFile(tempPath, content, "utf-8");
    await rename(tempPath, path);
  } catch (error) {
    await rm(tempPath, { force: true }).catch(() => undefined);
    throw error;
  }
}
