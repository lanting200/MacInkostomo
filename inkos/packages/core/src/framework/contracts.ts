import { z } from "zod";

/**
 * Stable diagnostic envelope shared by framework modules, PipelineRunner, and
 * CLI entry points. Payloads are extensible; routing fields stay versioned.
 */
export const FrameworkDiagnosticLevelSchema = z.enum([
  "debug",
  "info",
  "warn",
  "error",
]);
export type FrameworkDiagnosticLevel = z.infer<typeof FrameworkDiagnosticLevelSchema>;

export const FrameworkDiagnosticStatusSchema = z.enum([
  "started",
  "succeeded",
  "failed",
  "retrying",
  "compensating",
  "compensated",
  "degraded",
]);
export type FrameworkDiagnosticStatus = z.infer<typeof FrameworkDiagnosticStatusSchema>;

export const FrameworkFaultDataSchema = z.object({
  code: z.string().trim().min(1).max(160),
  message: z.string().max(20_000),
  retryable: z.boolean().default(false),
  stack: z.string().max(40_000).optional(),
  details: z.record(z.unknown()).default({}),
});
export type FrameworkFaultData = z.infer<typeof FrameworkFaultDataSchema>;

export const FrameworkDiagnosticEventSchema = z.object({
  schemaVersion: z.literal(2),
  eventId: z.string().uuid(),
  timestamp: z.string().datetime(),
  type: z.string().trim().min(1).max(200),
  operation: z.string().trim().min(1).max(200),
  phase: z.enum(["start", "progress", "success", "failure", "diagnostic"]),
  message: z.string().max(20_000),
  level: FrameworkDiagnosticLevelSchema,
  status: FrameworkDiagnosticStatusSchema.optional(),
  traceId: z.string().trim().min(1).max(200),
  spanId: z.string().trim().min(1).max(200),
  parentSpanId: z.string().trim().min(1).max(200).optional(),
  component: z.string().trim().min(1).max(200),
  moduleId: z.string().trim().min(1).max(200).optional(),
  workflow: z.string().trim().min(1).max(200).optional(),
  stage: z.string().trim().min(1).max(200).optional(),
  bookId: z.string().trim().min(1).max(500).optional(),
  chapterNumber: z.number().int().min(1).optional(),
  jobId: z.string().trim().min(1).max(500).optional(),
  attempt: z.number().int().min(1).optional(),
  durationMs: z.number().finite().min(0).optional(),
  data: z.record(z.unknown()).default({}),
  error: FrameworkFaultDataSchema.optional(),
});
export type FrameworkDiagnosticEvent = z.infer<typeof FrameworkDiagnosticEventSchema>;

export type FrameworkDiagnosticEventInput = Omit<
  FrameworkDiagnosticEvent,
  "schemaVersion" | "eventId" | "timestamp" | "traceId" | "spanId" | "data" |
  "operation" | "phase" | "message"
> & {
  readonly eventId?: string;
  readonly timestamp?: string;
  readonly traceId?: string;
  readonly spanId?: string;
  readonly data?: Readonly<Record<string, unknown>>;
  readonly operation?: string;
  readonly phase?: FrameworkDiagnosticEvent["phase"];
  readonly message?: string;
};

export interface FrameworkFaultOptions {
  readonly code?: string;
  readonly retryable?: boolean;
  readonly details?: Readonly<Record<string, unknown>>;
  readonly cause?: unknown;
}

/** Error type crossing framework module and workflow boundaries. */
export class FrameworkFault extends Error {
  readonly code: string;
  readonly retryable: boolean;
  readonly details: Readonly<Record<string, unknown>>;

  constructor(message: string, options: FrameworkFaultOptions = {}) {
    super(message, options.cause === undefined ? undefined : { cause: options.cause });
    this.name = "FrameworkFault";
    this.code = options.code ?? "FRAMEWORK_OPERATION_FAILED";
    this.retryable = options.retryable ?? false;
    this.details = options.details ?? {};
  }

  static from(error: unknown, defaults: FrameworkFaultOptions = {}): FrameworkFault {
    if (error instanceof FrameworkFault) return error;
    const message = error instanceof Error ? error.message : String(error);
    return new FrameworkFault(message, {
      ...defaults,
      cause: defaults.cause ?? error,
    });
  }

  toDiagnosticData(): FrameworkFaultData {
    return FrameworkFaultDataSchema.parse({
      code: this.code,
      message: this.message,
      retryable: this.retryable,
      stack: this.stack,
      details: this.details,
    });
  }
}

export interface FrameworkExecutionScope {
  readonly traceId?: string;
  readonly parentSpanId?: string;
  readonly bookId?: string;
  readonly chapterNumber?: number;
  readonly jobId?: string;
  readonly data?: Readonly<Record<string, unknown>>;
}

export interface FrameworkModuleCallOptions extends FrameworkExecutionScope {
  readonly timeoutMs?: number;
  /** Maximum time to observe a mutating operation after cancellation. */
  readonly cancellationGraceMs?: number;
  /** Read calls may fail fast; mutations must first establish their final outcome. */
  readonly operationKind?: "read" | "mutation";
  /**
   * Called only when a mutation outlives its cancellation grace period. The
   * promise settles when the underlying work has actually finished, regardless
   * of whether it committed or failed.
   */
  readonly onOutcomeUnknown?: (settlement: Promise<void>) => void;
  readonly signal?: AbortSignal;
}
