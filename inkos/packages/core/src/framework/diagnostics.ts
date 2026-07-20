import { randomUUID } from "node:crypto";
import {
  FrameworkDiagnosticEventSchema,
  type FrameworkDiagnosticEvent,
  type FrameworkDiagnosticEventInput,
} from "./contracts.js";

export const FRAMEWORK_EVENT_PREFIX = "@@INKOS_EVENT@@";

export interface FrameworkDiagnosticSink {
  emit(event: FrameworkDiagnosticEvent): void | Promise<void>;
}

export type FrameworkDiagnosticSinkFunction = (
  event: FrameworkDiagnosticEvent,
) => void | Promise<void>;

const SECRET_KEY = /(?:api[-_]?key|authorization|cookie|password|secret|token)/i;
const MAX_DIAGNOSTIC_DEPTH = 8;
const MAX_DIAGNOSTIC_ARRAY_ITEMS = 200;
const MAX_DIAGNOSTIC_STRING_CHARS = 20_000;

/** Redact credentials embedded in free-form messages before any sink sees them. */
export function sanitizeDiagnosticText(value: string): string {
  const redacted = value
    .replace(
      /(api[-_ ]?key|token|authorization|cookie|password|secret)\s*[:=]\s*(?:"[^"]*"|'[^']*'|Bearer\s+[^\s,;]+|[^\s,;]+)/gi,
      "$1=[REDACTED]",
    )
    .replace(/Bearer\s+[A-Za-z0-9._~-]+/gi, "Bearer [REDACTED]")
    .replace(/\b(?:sk|xai)-[A-Za-z0-9_-]{12,}\b/gi, "[REDACTED_KEY]");
  return redacted.length <= MAX_DIAGNOSTIC_STRING_CHARS
    ? redacted
    : `${redacted.slice(0, MAX_DIAGNOSTIC_STRING_CHARS)}...[truncated]`;
}

/** Bounded redaction prevents diagnostics from becoming a prompt/key store. */
export function sanitizeDiagnosticData(
  value: Readonly<Record<string, unknown>>,
): Record<string, unknown> {
  return sanitizeRecord(value, 0);
}

function sanitizeRecord(
  value: Readonly<Record<string, unknown>>,
  depth: number,
): Record<string, unknown> {
  if (depth >= MAX_DIAGNOSTIC_DEPTH) return { truncated: true };
  return Object.fromEntries(Object.entries(value).map(([key, item]) => [
    key,
    SECRET_KEY.test(key) ? "[REDACTED]" : sanitizeValue(item, depth + 1),
  ]));
}

function sanitizeValue(value: unknown, depth: number): unknown {
  if (value === null || value === undefined || typeof value === "number" || typeof value === "boolean") {
    return value;
  }
  if (typeof value === "string") {
    return sanitizeDiagnosticText(value);
  }
  if (value instanceof Error) {
    return {
      name: value.name,
      message: sanitizeDiagnosticText(value.message),
      stack: value.stack ? sanitizeDiagnosticText(value.stack) : undefined,
    };
  }
  if (Array.isArray(value)) {
    if (depth >= MAX_DIAGNOSTIC_DEPTH) return ["[truncated]"];
    return value
      .slice(0, MAX_DIAGNOSTIC_ARRAY_ITEMS)
      .map((item) => sanitizeValue(item, depth + 1));
  }
  if (typeof value === "object") {
    return sanitizeRecord(value as Readonly<Record<string, unknown>>, depth);
  }
  return sanitizeDiagnosticText(String(value));
}

function asSink(sink: FrameworkDiagnosticSink | FrameworkDiagnosticSinkFunction): FrameworkDiagnosticSink {
  return typeof sink === "function" ? { emit: sink } : sink;
}

/** Diagnostic fan-out is intentionally isolated from business failures. */
export class FrameworkDiagnostics {
  private readonly sinks = new Set<FrameworkDiagnosticSink>();
  private failures = 0;

  constructor(sinks: ReadonlyArray<FrameworkDiagnosticSink | FrameworkDiagnosticSinkFunction> = []) {
    for (const sink of sinks) this.sinks.add(asSink(sink));
  }

  get sinkFailures(): number {
    return this.failures;
  }

  addSink(sink: FrameworkDiagnosticSink | FrameworkDiagnosticSinkFunction): () => void {
    const normalized = asSink(sink);
    this.sinks.add(normalized);
    return () => this.sinks.delete(normalized);
  }

  async emit(input: FrameworkDiagnosticEventInput): Promise<FrameworkDiagnosticEvent> {
    const event = FrameworkDiagnosticEventSchema.parse({
      ...input,
      schemaVersion: 2,
      eventId: input.eventId ?? randomUUID(),
      timestamp: input.timestamp ?? new Date().toISOString(),
      traceId: input.traceId ?? randomUUID(),
      spanId: input.spanId ?? randomUUID(),
      operation: sanitizeDiagnosticText(input.operation ?? input.stage ?? input.type),
      phase: input.phase ?? phaseForStatus(input.status),
      message: sanitizeDiagnosticText(
        input.message ?? `${input.stage ?? input.type}${input.status ? ` ${input.status}` : ""}`,
      ),
      data: sanitizeDiagnosticData(input.data ?? {}),
      error: input.error
        ? {
            ...input.error,
            message: sanitizeDiagnosticText(input.error.message),
            stack: input.error.stack ? sanitizeDiagnosticText(input.error.stack) : undefined,
            details: sanitizeDiagnosticData(input.error.details ?? {}),
          }
        : undefined,
    });
    const deliveries = await Promise.allSettled(
      [...this.sinks].map(async (sink) => sink.emit(event)),
    );
    this.failures += deliveries.filter((delivery) => delivery.status === "rejected").length;
    return event;
  }
}

function phaseForStatus(status: FrameworkDiagnosticEventInput["status"]): FrameworkDiagnosticEvent["phase"] {
  if (status === "started") return "start";
  if (status === "succeeded" || status === "compensated") return "success";
  if (status === "failed") return "failure";
  if (status === "retrying" || status === "compensating") return "progress";
  return "diagnostic";
}

export class MemoryDiagnosticSink implements FrameworkDiagnosticSink {
  readonly events: FrameworkDiagnosticEvent[] = [];

  emit(event: FrameworkDiagnosticEvent): void {
    this.events.push(event);
  }
}

/** Emits the same structured envelope through a process text channel. */
export function createProcessDiagnosticSink(
  write: (line: string) => void = (line) => process.stderr.write(line),
): FrameworkDiagnosticSink {
  return {
    emit: (event) => write(`${FRAMEWORK_EVENT_PREFIX}${JSON.stringify(event)}\n`),
  };
}
