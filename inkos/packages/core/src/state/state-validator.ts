import {
  ChapterSummariesStateSchema,
  CurrentStateStateSchema,
  HooksStateSchema,
  PersistentObjectsStateSchema,
  StateManifestSchema,
} from "../models/runtime-state.js";

export interface RuntimeStateValidationIssue {
  readonly code: string;
  readonly message: string;
  readonly path?: string;
}

export function validateRuntimeState(input: {
  readonly manifest: unknown;
  readonly currentState: unknown;
  readonly hooks: unknown;
  readonly chapterSummaries: unknown;
  readonly objects?: unknown;
}): RuntimeStateValidationIssue[] {
  try {
    const issues: RuntimeStateValidationIssue[] = [];

    const manifest = parseOrIssue(
      StateManifestSchema,
      input.manifest,
      issues,
      "invalid_manifest",
      "manifest",
    );
    const currentState = parseOrIssue(
      CurrentStateStateSchema,
      input.currentState,
      issues,
      "invalid_current_state",
      "currentState",
    );
    const hooks = parseOrIssue(
      HooksStateSchema,
      input.hooks,
      issues,
      "invalid_hooks_state",
      "hooks",
    );
    const chapterSummaries = parseOrIssue(
      ChapterSummariesStateSchema,
      input.chapterSummaries,
      issues,
      "invalid_chapter_summaries_state",
      "chapterSummaries",
    );
    const objects = parseOrIssue(
      PersistentObjectsStateSchema,
      input.objects ?? { objects: [] },
      issues,
      "invalid_objects_state",
      "objects",
    );

    if (hooks) {
      const seen = new Set<string>();
      for (const hook of hooks.hooks) {
        if (seen.has(hook.hookId)) {
          issues.push({
            code: "duplicate_hook_id",
            message: `duplicate hook id: ${hook.hookId}`,
            path: `hooks.${hook.hookId}`,
          });
        }
        seen.add(hook.hookId);
      }
    }

    if (chapterSummaries) {
      const seen = new Set<number>();
      for (const row of chapterSummaries.rows) {
        if (seen.has(row.chapter)) {
          issues.push({
            code: "duplicate_summary_chapter",
            message: `duplicate summary chapter: ${row.chapter}`,
            path: `chapterSummaries.${row.chapter}`,
          });
        }
        seen.add(row.chapter);
      }
    }

    if (objects) {
      const seen = new Set<string>();
      for (const object of objects.objects) {
        if (seen.has(object.objectId)) {
          issues.push({
            code: "duplicate_object_id",
            message: `duplicate persistent object id: ${object.objectId}`,
            path: `objects.${object.objectId}`,
          });
        }
        seen.add(object.objectId);
      }
    }

    if (manifest && currentState && currentState.chapter > manifest.lastAppliedChapter) {
      issues.push({
        code: "current_state_ahead_of_manifest",
        message: `current state chapter ${currentState.chapter} exceeds manifest ${manifest.lastAppliedChapter}`,
        path: "currentState.chapter",
      });
    }

    return issues;
  } catch (error) {
    return [
      {
        code: "validator_crash",
        message: String(error),
        path: "",
      },
    ];
  }
}

function parseOrIssue<T>(
  schema: { parse(value: unknown): T },
  value: unknown,
  issues: RuntimeStateValidationIssue[],
  code: string,
  path: string,
): T | undefined {
  try {
    return schema.parse(value);
  } catch (error) {
    issues.push({
      code,
      message: String(error),
      path,
    });
    return undefined;
  }
}
