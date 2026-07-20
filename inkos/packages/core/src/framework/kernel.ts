import type { FrameworkExecutionScope } from "./contracts.js";
import {
  FrameworkDiagnostics,
  type FrameworkDiagnosticSink,
  type FrameworkDiagnosticSinkFunction,
} from "./diagnostics.js";
import {
  FrameworkModuleRegistry,
  type FrameworkModule,
} from "./module-registry.js";
import {
  FrameworkWorkflowEngine,
  type FrameworkWorkflowDefinition,
  type FrameworkWorkflowResult,
} from "./workflow.js";

export interface FrameworkKernelOptions {
  readonly diagnostics?: FrameworkDiagnostics;
  readonly diagnosticSinks?: ReadonlyArray<FrameworkDiagnosticSink | FrameworkDiagnosticSinkFunction>;
  readonly modules?: ReadonlyArray<FrameworkModule<unknown>>;
}

/**
 * Small composition root for built-in InkOS modules. It owns lifecycle,
 * diagnostics, and mutation workflows without knowing any novel-writing logic.
 */
export class FrameworkKernel {
  readonly diagnostics: FrameworkDiagnostics;
  readonly modules: FrameworkModuleRegistry;
  readonly workflows: FrameworkWorkflowEngine;

  constructor(options: FrameworkKernelOptions = {}) {
    this.diagnostics = options.diagnostics ?? new FrameworkDiagnostics(options.diagnosticSinks);
    this.modules = new FrameworkModuleRegistry(this.diagnostics);
    this.workflows = new FrameworkWorkflowEngine(this.modules, this.diagnostics);
    for (const module of options.modules ?? []) this.modules.register(module);
  }

  register<TService>(module: FrameworkModule<TService>): this {
    this.modules.register(module);
    return this;
  }

  run<TInput, TOutput = unknown>(
    definition: FrameworkWorkflowDefinition<TInput>,
    input: TInput,
    scope: FrameworkExecutionScope = {},
    signal?: AbortSignal,
  ): Promise<FrameworkWorkflowResult<TOutput>> {
    return this.workflows.run<TInput, TOutput>(definition, input, scope, signal);
  }

  runOrThrow<TInput, TOutput = unknown>(
    definition: FrameworkWorkflowDefinition<TInput>,
    input: TInput,
    scope: FrameworkExecutionScope = {},
    signal?: AbortSignal,
  ): Promise<TOutput> {
    return this.workflows.runOrThrow<TInput, TOutput>(definition, input, scope, signal);
  }

  initialize(): Promise<void> {
    return this.modules.initializeAll();
  }

  shutdown(): Promise<ReadonlyArray<import("./contracts.js").FrameworkFault>> {
    return this.modules.disposeAll();
  }
}

export function createFrameworkKernel(options: FrameworkKernelOptions = {}): FrameworkKernel {
  return new FrameworkKernel(options);
}
