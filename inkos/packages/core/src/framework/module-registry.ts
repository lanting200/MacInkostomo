import { randomUUID } from "node:crypto";
import {
  FrameworkFault,
  type FrameworkModuleCallOptions,
} from "./contracts.js";
import { FrameworkDiagnostics } from "./diagnostics.js";

export interface FrameworkModuleContext {
  readonly registry: FrameworkModuleRegistry;
  readonly diagnostics: FrameworkDiagnostics;
}

/** A built-in source module. `create` returns the service exposed to peers. */
export interface FrameworkModule<TService = unknown> {
  readonly id: string;
  readonly version: string;
  readonly dependencies?: ReadonlyArray<string>;
  create(context: FrameworkModuleContext): TService | Promise<TService>;
  dispose?(service: TService, context: FrameworkModuleContext): void | Promise<void>;
}

export interface FrameworkModuleRegistryOptions {
  readonly diagnostics?: FrameworkDiagnostics;
  readonly defaultTimeoutMs?: number;
  readonly maxConcurrency?: number;
  readonly failureThreshold?: number;
  readonly cooldownMs?: number;
}

interface ModuleRecord<TService = unknown> {
  readonly definition: FrameworkModule<TService>;
  service?: TService;
  initialization?: Promise<TService>;
  state: "registered" | "initializing" | "ready" | "failed" | "disposed";
  consecutiveFailures: number;
  circuitOpenedAt?: number;
  inFlight: number;
  readonly queue: Array<() => void>;
}

type OperationSettlement<TResult> =
  | { readonly kind: "fulfilled"; readonly value: TResult }
  | { readonly kind: "rejected"; readonly error: unknown };

interface OperationAbort {
  readonly kind: "aborted";
  readonly reason: unknown;
}

const MODULE_ID = /^[a-z0-9](?:[a-z0-9._-]{0,198}[a-z0-9])?$/i;

/**
 * Lazy dependency registry plus an in-process failure boundary. Each module
 * gets a bounded concurrency bulkhead, timeout, and circuit breaker. This is
 * intentionally inside core: modules are source components, not subprocess
 * adapters.
 */
export class FrameworkModuleRegistry {
  private readonly records = new Map<string, ModuleRecord>();
  private readonly initializationOrder: string[] = [];
  readonly diagnostics: FrameworkDiagnostics;
  private readonly defaultTimeoutMs: number;
  private readonly maxConcurrency: number;
  private readonly failureThreshold: number;
  private readonly cooldownMs: number;

  constructor(options: FrameworkDiagnostics | FrameworkModuleRegistryOptions = {}) {
    const normalized = options instanceof FrameworkDiagnostics
      ? { diagnostics: options }
      : options;
    this.diagnostics = normalized.diagnostics ?? new FrameworkDiagnostics();
    this.defaultTimeoutMs = Math.max(1, normalized.defaultTimeoutMs ?? 30 * 60 * 1000);
    this.maxConcurrency = Math.max(1, Math.trunc(normalized.maxConcurrency ?? 4));
    this.failureThreshold = Math.max(1, Math.trunc(normalized.failureThreshold ?? 3));
    this.cooldownMs = Math.max(1, normalized.cooldownMs ?? 30_000);
  }

  register<TService>(definition: FrameworkModule<TService>): this {
    if (!MODULE_ID.test(definition.id)) {
      throw new FrameworkFault(`Invalid framework module id: ${definition.id}`, {
        code: "FRAMEWORK_MODULE_ID_INVALID",
      });
    }
    if (!definition.version.trim()) {
      throw new FrameworkFault(`Framework module ${definition.id} has no version`, {
        code: "FRAMEWORK_MODULE_VERSION_MISSING",
      });
    }
    if (this.records.has(definition.id)) {
      throw new FrameworkFault(`Framework module already registered: ${definition.id}`, {
        code: "FRAMEWORK_MODULE_DUPLICATE",
      });
    }
    this.records.set(definition.id, {
      definition: definition as FrameworkModule<unknown>,
      state: "registered",
      consecutiveFailures: 0,
      inFlight: 0,
      queue: [],
    });
    return this;
  }

  registerValue<TService>(id: string, service: TService, version = "1"): this {
    return this.register({ id, version, create: () => service });
  }

  has(id: string): boolean {
    return this.records.has(id);
  }

  stateOf(id: string): ModuleRecord["state"] | "missing" {
    return this.records.get(id)?.state ?? "missing";
  }

  async resolve<TService>(id: string): Promise<TService> {
    return this.initialize<TService>(id, []);
  }

  async initializeAll(): Promise<void> {
    for (const id of this.records.keys()) await this.resolve(id);
  }

  /**
   * Calls one service through the module bulkhead. The callback receives a
   * signal aborted by either caller cancellation or the module timeout.
   */
  async invoke<TService, TResult>(
    id: string,
    operation: string,
    call: (service: TService, signal: AbortSignal) => TResult | Promise<TResult>,
    options: FrameworkModuleCallOptions = {},
  ): Promise<TResult> {
    const service = await this.resolve<TService>(id);
    const record = this.requiredRecord(id);
    this.assertCircuitAvailable(id, record);
    const traceId = options.traceId ?? randomUUID();
    const spanId = randomUUID();
    const startedAt = performance.now();
    const controller = new AbortController();
    let abortSource: "caller" | "timeout" | undefined;
    const relayAbort = () => {
      if (controller.signal.aborted) return;
      abortSource = "caller";
      controller.abort(options.signal?.reason);
    };
    options.signal?.addEventListener("abort", relayAbort, { once: true });
    if (options.signal?.aborted) relayAbort();
    const timeoutMs = Math.max(1, options.timeoutMs ?? this.defaultTimeoutMs);
    const cancellationGraceMs = Math.max(1, options.cancellationGraceMs ?? 30_000);
    const operationKind = options.operationKind ?? "read";
    const timeout = setTimeout(() => {
      if (controller.signal.aborted) return;
      abortSource = "timeout";
      controller.abort(new FrameworkFault(
        `Framework module ${id}.${operation} timed out after ${timeoutMs}ms`,
        { code: "FRAMEWORK_MODULE_TIMEOUT", retryable: true, details: { id, operation, timeoutMs } },
      ));
    }, timeoutMs);
    let acquired = false;
    let operationStarted = false;

    try {
      await this.acquire(record, controller.signal);
      acquired = true;
      await this.diagnostics.emit({
        type: "framework.module.call",
        level: "info",
        status: "started",
        traceId,
        spanId,
        parentSpanId: options.parentSpanId,
        component: "framework.module-registry",
        moduleId: id,
        stage: operation,
        bookId: options.bookId,
        chapterNumber: options.chapterNumber,
        jobId: options.jobId,
        data: options.data,
      });

      const operationPromise = Promise.resolve()
        .then(() => call(service, controller.signal))
        .finally(() => this.release(record));
      operationStarted = true;
      const settlementPromise = settleOperation(operationPromise);
      const first = await Promise.race([
        settlementPromise,
        operationAbort(controller.signal),
      ]);
      let settlement: OperationSettlement<TResult>;

      if (first.kind === "aborted") {
        if (operationKind === "read") throw abortReason(first.reason);
        const observed = await observeSettlement(
          settlementPromise,
          cancellationGraceMs,
        );
        if (!observed) {
          // Hosts may own resources whose lifetime must extend through an
          // uncertain mutation. Notify them before returning to the caller.
          try {
            options.onOutcomeUnknown?.(settlementPromise.then(() => undefined));
          } catch {
            // An observer must not replace the framework's outcome-unknown fault.
          }
          throw new FrameworkFault(
            `Framework module mutation ${id}.${operation} did not settle within ${cancellationGraceMs}ms after cancellation`,
            {
              code: "FRAMEWORK_MODULE_OUTCOME_UNKNOWN",
              retryable: false,
              details: { id, operation, timeoutMs, cancellationGraceMs },
              cause: abortReason(first.reason),
            },
          );
        }
        if (observed.kind === "rejected") {
          throw new FrameworkFault(
            `Framework module mutation ${id}.${operation} was cancelled before a successful outcome was established`,
            {
              code: "FRAMEWORK_MODULE_MUTATION_ABORTED",
              retryable: false,
              details: { id, operation, timeoutMs, cancellationGraceMs },
              cause: observed.error,
            },
          );
        }
        settlement = observed;
      } else {
        settlement = first;
      }

      if (settlement.kind === "rejected") throw settlement.error;
      record.consecutiveFailures = 0;
      record.circuitOpenedAt = undefined;
      await this.diagnostics.emit({
        type: "framework.module.call",
        level: "info",
        status: "succeeded",
        traceId,
        spanId,
        parentSpanId: options.parentSpanId,
        component: "framework.module-registry",
        moduleId: id,
        stage: operation,
        bookId: options.bookId,
        chapterNumber: options.chapterNumber,
        jobId: options.jobId,
        durationMs: performance.now() - startedAt,
      });
      return settlement.value;
    } catch (error) {
      const callerAborted = abortSource === "caller";
      const fault = !acquired && controller.signal.aborted
        ? new FrameworkFault(
            callerAborted
              ? `Framework module ${id}.${operation} was cancelled before execution`
              : `Framework module ${id}.${operation} timed out before execution`,
            {
              code: callerAborted ? "FRAMEWORK_MODULE_CALL_ABORTED" : "FRAMEWORK_MODULE_TIMEOUT",
              retryable: !callerAborted,
              details: { id, operation, timeoutMs },
              cause: error,
            },
          )
        : operationKind === "mutation" && operationStarted && controller.signal.aborted
          ? error instanceof FrameworkFault && (
              error.code === "FRAMEWORK_MODULE_OUTCOME_UNKNOWN"
              || error.code === "FRAMEWORK_MODULE_MUTATION_ABORTED"
            )
            ? error
            : new FrameworkFault(
                `Framework module mutation ${id}.${operation} ended after cancellation`,
                {
                  code: "FRAMEWORK_MODULE_MUTATION_ABORTED",
                  retryable: false,
                  details: { id, operation, timeoutMs, cancellationGraceMs },
                  cause: error,
                },
              )
          : FrameworkFault.from(error, {
              code: controller.signal.aborted
                ? callerAborted ? "FRAMEWORK_MODULE_CALL_ABORTED" : "FRAMEWORK_MODULE_TIMEOUT"
                : "FRAMEWORK_MODULE_CALL_FAILED",
              retryable: controller.signal.aborted && !callerAborted,
              details: { id, operation },
            });
      if (operationStarted && !callerAborted) {
        record.consecutiveFailures += 1;
        if (record.consecutiveFailures >= this.failureThreshold) record.circuitOpenedAt = Date.now();
      }
      await this.diagnostics.emit({
        type: "framework.module.call",
        level: "error",
        status: "failed",
        traceId,
        spanId,
        parentSpanId: options.parentSpanId,
        component: "framework.module-registry",
        moduleId: id,
        stage: operation,
        bookId: options.bookId,
        chapterNumber: options.chapterNumber,
        jobId: options.jobId,
        durationMs: performance.now() - startedAt,
        data: { consecutiveFailures: record.consecutiveFailures },
        error: fault.toDiagnosticData(),
      });
      throw fault;
    } finally {
      if (acquired && !operationStarted) this.release(record);
      clearTimeout(timeout);
      options.signal?.removeEventListener("abort", relayAbort);
    }
  }

  private async initialize<TService>(id: string, ancestry: ReadonlyArray<string>): Promise<TService> {
    const record = this.requiredRecord(id);
    if (record.state === "ready") return record.service as TService;
    if (ancestry.includes(id)) {
      throw new FrameworkFault(`Framework module dependency cycle: ${[...ancestry, id].join(" -> ")}`, {
        code: "FRAMEWORK_MODULE_DEPENDENCY_CYCLE",
        details: { modules: [...ancestry, id] },
      });
    }
    if (record.state === "initializing" && record.initialization) {
      return record.initialization as Promise<TService>;
    }
    if (record.state === "failed" || record.state === "disposed") {
      throw new FrameworkFault(`Framework module ${id} is ${record.state}`, {
        code: "FRAMEWORK_MODULE_UNAVAILABLE",
        details: { id, state: record.state },
      });
    }

    record.state = "initializing";
    record.initialization = (async () => {
      const traceId = `module:${id}`;
      await this.diagnostics.emit({
        type: "framework.module.initialize",
        level: "info",
        status: "started",
        traceId,
        component: "framework.module-registry",
        moduleId: id,
        data: { version: record.definition.version },
      });
      try {
        for (const dependency of record.definition.dependencies ?? []) {
          await this.initialize(dependency, [...ancestry, id]);
        }
        const service = await record.definition.create({ registry: this, diagnostics: this.diagnostics });
        record.service = service;
        record.state = "ready";
        this.initializationOrder.push(id);
        await this.diagnostics.emit({
          type: "framework.module.initialize",
          level: "info",
          status: "succeeded",
          traceId,
          component: "framework.module-registry",
          moduleId: id,
          data: { version: record.definition.version },
        });
        return service;
      } catch (error) {
        record.state = "failed";
        const fault = FrameworkFault.from(error, {
          code: "FRAMEWORK_MODULE_INITIALIZATION_FAILED",
          details: { id },
        });
        await this.diagnostics.emit({
          type: "framework.module.initialize",
          level: "error",
          status: "failed",
          traceId,
          component: "framework.module-registry",
          moduleId: id,
          error: fault.toDiagnosticData(),
        });
        throw fault;
      }
    })();
    return record.initialization as Promise<TService>;
  }

  async disposeAll(): Promise<ReadonlyArray<FrameworkFault>> {
    const faults: FrameworkFault[] = [];
    for (const id of [...this.initializationOrder].reverse()) {
      const record = this.records.get(id);
      if (!record || record.state !== "ready") continue;
      try {
        await record.definition.dispose?.(
          record.service,
          { registry: this, diagnostics: this.diagnostics },
        );
        record.state = "disposed";
      } catch (error) {
        const fault = FrameworkFault.from(error, {
          code: "FRAMEWORK_MODULE_DISPOSE_FAILED",
          details: { id },
        });
        faults.push(fault);
        await this.diagnostics.emit({
          type: "framework.module.dispose",
          level: "error",
          status: "failed",
          traceId: `module:${id}`,
          component: "framework.module-registry",
          moduleId: id,
          error: fault.toDiagnosticData(),
        });
      }
    }
    return faults;
  }

  private requiredRecord(id: string): ModuleRecord {
    const record = this.records.get(id);
    if (!record) {
      throw new FrameworkFault(`Framework module not found: ${id}`, {
        code: "FRAMEWORK_MODULE_NOT_FOUND",
        details: { id },
      });
    }
    return record;
  }

  private assertCircuitAvailable(id: string, record: ModuleRecord): void {
    if (record.circuitOpenedAt === undefined) return;
    const elapsed = Date.now() - record.circuitOpenedAt;
    if (elapsed < this.cooldownMs) {
      throw new FrameworkFault(`Framework module circuit is open: ${id}`, {
        code: "FRAMEWORK_MODULE_CIRCUIT_OPEN",
        retryable: true,
        details: { id, retryAfterMs: this.cooldownMs - elapsed },
      });
    }
    record.circuitOpenedAt = undefined;
    record.consecutiveFailures = 0;
  }

  private async acquire(record: ModuleRecord, signal?: AbortSignal): Promise<void> {
    if (signal?.aborted) {
      throw new FrameworkFault("Framework module call aborted before execution", {
        code: "FRAMEWORK_MODULE_CALL_ABORTED",
      });
    }
    if (record.inFlight < this.maxConcurrency) {
      record.inFlight += 1;
      return;
    }
    await new Promise<void>((resolve, reject) => {
      const grant = () => {
        signal?.removeEventListener("abort", abort);
        record.inFlight += 1;
        resolve();
      };
      const abort = () => {
        const index = record.queue.indexOf(grant);
        if (index >= 0) record.queue.splice(index, 1);
        reject(new FrameworkFault("Framework module call aborted while queued", {
          code: "FRAMEWORK_MODULE_QUEUE_ABORTED",
        }));
      };
      if (signal?.aborted) {
        abort();
        return;
      }
      record.queue.push(grant);
      signal?.addEventListener("abort", abort, { once: true });
    });
  }

  private release(record: ModuleRecord): void {
    record.inFlight = Math.max(0, record.inFlight - 1);
    record.queue.shift()?.();
  }
}

function settleOperation<TResult>(operation: Promise<TResult>): Promise<OperationSettlement<TResult>> {
  return operation.then(
    (value) => ({ kind: "fulfilled", value }),
    (error: unknown) => ({ kind: "rejected", error }),
  );
}

function operationAbort(signal: AbortSignal): Promise<OperationAbort> {
  return new Promise((resolve) => {
    const abort = () => resolve({ kind: "aborted", reason: signal.reason });
    if (signal.aborted) abort();
    else signal.addEventListener("abort", abort, { once: true });
  });
}

function observeSettlement<TResult>(
  settlement: Promise<OperationSettlement<TResult>>,
  graceMs: number,
): Promise<OperationSettlement<TResult> | null> {
  return new Promise((resolve) => {
    const timeout = setTimeout(() => resolve(null), graceMs);
    void settlement.then((result) => {
      clearTimeout(timeout);
      resolve(result);
    });
  });
}

function abortReason(reason: unknown): Error {
  if (reason instanceof Error) return reason;
  return new FrameworkFault("Framework module call aborted", {
    code: "FRAMEWORK_MODULE_CALL_ABORTED",
  });
}
