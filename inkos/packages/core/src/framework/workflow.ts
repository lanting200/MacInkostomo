import { randomUUID } from "node:crypto";
import {
  FrameworkFault,
  type FrameworkExecutionScope,
} from "./contracts.js";
import type { FrameworkDiagnostics } from "./diagnostics.js";
import type { FrameworkModuleRegistry } from "./module-registry.js";

export interface FrameworkWorkflowContext<TInput> {
  readonly input: TInput;
  readonly outputs: ReadonlyMap<string, unknown>;
  readonly modules: FrameworkModuleRegistry;
  readonly diagnostics: FrameworkDiagnostics;
  readonly traceId: string;
  readonly signal?: AbortSignal;
  output<T = unknown>(stepId: string): T | undefined;
}

export interface FrameworkWorkflowRetryPolicy {
  readonly maxAttempts: number;
  readonly delayMs?: number;
  readonly shouldRetry?: (fault: FrameworkFault, attempt: number) => boolean;
}

export interface FrameworkWorkflowStep<TInput, TOutput = unknown> {
  readonly id: string;
  readonly moduleId?: string;
  /** Non-critical failures are recorded and the next step still runs. */
  readonly critical?: boolean;
  readonly retry?: FrameworkWorkflowRetryPolicy;
  run(context: FrameworkWorkflowContext<TInput>): TOutput | Promise<TOutput>;
  compensate?(context: FrameworkWorkflowContext<TInput>, output: TOutput): void | Promise<void>;
}

export interface FrameworkWorkflowDefinition<TInput> {
  readonly id: string;
  readonly steps: ReadonlyArray<FrameworkWorkflowStep<TInput, unknown>>;
}

export interface FrameworkWorkflowResult<TOutput = unknown> {
  readonly ok: boolean;
  readonly status: "succeeded" | "degraded" | "failed";
  readonly traceId: string;
  readonly output?: TOutput;
  readonly outputs: ReadonlyMap<string, unknown>;
  readonly completedSteps: ReadonlyArray<string>;
  readonly failedSteps: ReadonlyArray<string>;
  readonly error?: FrameworkFault;
  readonly compensationErrors: ReadonlyArray<FrameworkFault>;
}

interface CompletedStep<TInput> {
  readonly step: FrameworkWorkflowStep<TInput, unknown>;
  readonly output: unknown;
}

/**
 * Sequential saga executor used for mutation-heavy book workflows. A critical
 * failure stops the workflow and compensates completed steps in reverse order;
 * compensation errors are retained without hiding the original fault.
 */
export class FrameworkWorkflowEngine {
  constructor(
    readonly modules: FrameworkModuleRegistry,
    readonly diagnostics: FrameworkDiagnostics,
  ) {}

  async run<TInput, TOutput = unknown>(
    definition: FrameworkWorkflowDefinition<TInput>,
    input: TInput,
    scope: FrameworkExecutionScope = {},
    signal?: AbortSignal,
  ): Promise<FrameworkWorkflowResult<TOutput>> {
    const traceId = scope.traceId ?? randomUUID();
    const outputs = new Map<string, unknown>();
    const completed: CompletedStep<TInput>[] = [];
    const failedSteps: string[] = [];
    const workflowStartedAt = performance.now();
    const context: FrameworkWorkflowContext<TInput> = {
      input,
      outputs,
      modules: this.modules,
      diagnostics: this.diagnostics,
      traceId,
      signal,
      output: <T>(stepId: string) => outputs.get(stepId) as T | undefined,
    };

    await this.emit({
      type: "framework.workflow",
      level: "info",
      status: "started",
      traceId,
      component: "framework.workflow",
      workflow: definition.id,
      data: { stepCount: definition.steps.length, ...scope.data },
    }, scope);

    for (const step of definition.steps) {
      if (signal?.aborted) {
        const fault = new FrameworkFault("Workflow aborted", {
          code: "FRAMEWORK_WORKFLOW_ABORTED",
          details: { workflow: definition.id, step: step.id },
        });
        return this.fail(definition.id, traceId, context, completed, failedSteps, fault, scope, workflowStartedAt);
      }

      const result = await this.runStep(definition.id, step, context, scope);
      if (result.ok) {
        outputs.set(step.id, result.output);
        completed.push({ step, output: result.output });
        continue;
      }

      failedSteps.push(step.id);
      if (step.critical === false) continue;
      return this.fail(
        definition.id,
        traceId,
        context,
        completed,
        failedSteps,
        result.error,
        scope,
        workflowStartedAt,
      );
    }

    const status = failedSteps.length > 0 ? "degraded" as const : "succeeded" as const;
    await this.emit({
      type: "framework.workflow",
      level: status === "degraded" ? "warn" : "info",
      status: status === "degraded" ? "degraded" : "succeeded",
      traceId,
      component: "framework.workflow",
      workflow: definition.id,
      durationMs: performance.now() - workflowStartedAt,
      data: { completedSteps: completed.map((entry) => entry.step.id), failedSteps },
    }, scope);
    return {
      ok: true,
      status,
      traceId,
      output: completed.at(-1)?.output as TOutput | undefined,
      outputs,
      completedSteps: completed.map((entry) => entry.step.id),
      failedSteps,
      compensationErrors: [],
    };
  }

  async runOrThrow<TInput, TOutput = unknown>(
    definition: FrameworkWorkflowDefinition<TInput>,
    input: TInput,
    scope: FrameworkExecutionScope = {},
    signal?: AbortSignal,
  ): Promise<TOutput> {
    const result = await this.run<TInput, TOutput>(definition, input, scope, signal);
    if (!result.ok) throw result.error;
    return result.output as TOutput;
  }

  private async runStep<TInput>(
    workflow: string,
    step: FrameworkWorkflowStep<TInput, unknown>,
    context: FrameworkWorkflowContext<TInput>,
    scope: FrameworkExecutionScope,
  ): Promise<{ ok: true; output: unknown } | { ok: false; error: FrameworkFault }> {
    const maxAttempts = Math.max(1, Math.trunc(step.retry?.maxAttempts ?? 1));
    for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
      const startedAt = performance.now();
      const spanId = randomUUID();
      await this.emit({
        type: "framework.workflow.step",
        level: "info",
        status: "started",
        traceId: context.traceId,
        spanId,
        parentSpanId: scope.parentSpanId,
        component: "framework.workflow",
        moduleId: step.moduleId,
        workflow,
        stage: step.id,
        attempt,
      }, scope);
      try {
        const output = await step.run(context);
        await this.emit({
          type: "framework.workflow.step",
          level: "info",
          status: "succeeded",
          traceId: context.traceId,
          spanId,
          parentSpanId: scope.parentSpanId,
          component: "framework.workflow",
          moduleId: step.moduleId,
          workflow,
          stage: step.id,
          attempt,
          durationMs: performance.now() - startedAt,
        }, scope);
        return { ok: true, output };
      } catch (error) {
        const fault = FrameworkFault.from(error, {
          code: "FRAMEWORK_WORKFLOW_STEP_FAILED",
          details: { workflow, step: step.id, attempt },
        });
        const retry = attempt < maxAttempts
          && (step.retry?.shouldRetry?.(fault, attempt) ?? fault.retryable);
        await this.emit({
          type: "framework.workflow.step",
          level: retry ? "warn" : "error",
          status: retry ? "retrying" : "failed",
          traceId: context.traceId,
          spanId,
          parentSpanId: scope.parentSpanId,
          component: "framework.workflow",
          moduleId: step.moduleId,
          workflow,
          stage: step.id,
          attempt,
          durationMs: performance.now() - startedAt,
          error: fault.toDiagnosticData(),
        }, scope);
        if (!retry) return { ok: false, error: fault };
        if ((step.retry?.delayMs ?? 0) > 0) await delay(step.retry!.delayMs!, context.signal);
      }
    }
    return {
      ok: false,
      error: new FrameworkFault(`Workflow step exhausted attempts: ${step.id}`, {
        code: "FRAMEWORK_WORKFLOW_RETRIES_EXHAUSTED",
      }),
    };
  }

  private async fail<TInput, TOutput>(
    workflow: string,
    traceId: string,
    context: FrameworkWorkflowContext<TInput>,
    completed: ReadonlyArray<CompletedStep<TInput>>,
    failedSteps: ReadonlyArray<string>,
    error: FrameworkFault,
    scope: FrameworkExecutionScope,
    workflowStartedAt: number,
  ): Promise<FrameworkWorkflowResult<TOutput>> {
    const compensationErrors: FrameworkFault[] = [];
    for (const entry of [...completed].reverse()) {
      if (!entry.step.compensate) continue;
      await this.emit({
        type: "framework.workflow.compensation",
        level: "warn",
        status: "compensating",
        traceId,
        component: "framework.workflow",
        moduleId: entry.step.moduleId,
        workflow,
        stage: entry.step.id,
      }, scope);
      try {
        await entry.step.compensate(context, entry.output);
        await this.emit({
          type: "framework.workflow.compensation",
          level: "info",
          status: "compensated",
          traceId,
          component: "framework.workflow",
          moduleId: entry.step.moduleId,
          workflow,
          stage: entry.step.id,
        }, scope);
      } catch (compensationError) {
        const fault = FrameworkFault.from(compensationError, {
          code: "FRAMEWORK_WORKFLOW_COMPENSATION_FAILED",
          details: { workflow, step: entry.step.id },
        });
        compensationErrors.push(fault);
        await this.emit({
          type: "framework.workflow.compensation",
          level: "error",
          status: "failed",
          traceId,
          component: "framework.workflow",
          moduleId: entry.step.moduleId,
          workflow,
          stage: entry.step.id,
          error: fault.toDiagnosticData(),
        }, scope);
      }
    }

    await this.emit({
      type: "framework.workflow",
      level: "error",
      status: "failed",
      traceId,
      component: "framework.workflow",
      workflow,
      durationMs: performance.now() - workflowStartedAt,
      data: {
        completedSteps: completed.map((entry) => entry.step.id),
        failedSteps,
        compensationErrorCount: compensationErrors.length,
      },
      error: error.toDiagnosticData(),
    }, scope);
    return {
      ok: false,
      status: "failed",
      traceId,
      outputs: context.outputs,
      completedSteps: completed.map((entry) => entry.step.id),
      failedSteps,
      error,
      compensationErrors,
    };
  }

  private emit(
    input: Parameters<FrameworkDiagnostics["emit"]>[0],
    scope: FrameworkExecutionScope,
  ): Promise<unknown> {
    return this.diagnostics.emit({
      ...input,
      bookId: input.bookId ?? scope.bookId,
      chapterNumber: input.chapterNumber ?? scope.chapterNumber,
      jobId: input.jobId ?? scope.jobId,
    });
  }
}

function delay(milliseconds: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(new FrameworkFault("Workflow aborted", { code: "FRAMEWORK_WORKFLOW_ABORTED" }));
      return;
    }
    const timer = setTimeout(resolve, milliseconds);
    signal?.addEventListener("abort", () => {
      clearTimeout(timer);
      reject(new FrameworkFault("Workflow aborted", { code: "FRAMEWORK_WORKFLOW_ABORTED" }));
    }, { once: true });
  });
}
