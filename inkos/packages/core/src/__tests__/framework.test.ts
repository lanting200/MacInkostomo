import { describe, expect, it } from "vitest";
import {
  FrameworkDiagnostics,
  FrameworkFault,
  FrameworkKernel,
  FrameworkModuleRegistry,
  FrameworkWorkflowEngine,
  MemoryDiagnosticSink,
  createProcessDiagnosticSink,
  sanitizeDiagnosticData,
} from "../index.js";

describe("framework diagnostics", () => {
  it("redacts secrets and isolates a broken sink", async () => {
    const memory = new MemoryDiagnosticSink();
    let processOutput = "";
    const diagnostics = new FrameworkDiagnostics([
      memory,
      createProcessDiagnosticSink((line) => { processOutput += line; }),
      () => {
        throw new Error("telemetry is down");
      },
    ]);

    await diagnostics.emit({
      type: "test.event",
      level: "info",
      component: "test",
      message: "failed Authorization: Bearer MESSAGE_SECRET api_key=KEY_SECRET sk-1234567890ABCDEF",
      data: {
        apiKey: "secret-value",
        nested: { authorization: "Bearer secret", visible: "ok" },
        note: "token=DATA_SECRET xai-1234567890ABCDEF",
      },
      error: {
        code: "TEST_FAILURE",
        message: "password=ERROR_SECRET",
        retryable: false,
        stack: "Error: secret=STACK_SECRET",
        details: { cookie: "COOKIE_SECRET" },
      },
    });

    expect(diagnostics.sinkFailures).toBe(1);
    expect(memory.events).toHaveLength(1);
    expect(memory.events[0]?.data).toMatchObject({
      apiKey: "[REDACTED]",
      nested: { authorization: "[REDACTED]", visible: "ok" },
    });
    expect(memory.events[0]?.eventId).toMatch(/^[0-9a-f-]{36}$/);
    expect(memory.events[0]?.error).toMatchObject({
      code: "TEST_FAILURE",
      retryable: false,
      message: "password=[REDACTED]",
      stack: "Error: secret=[REDACTED]",
      details: { cookie: "[REDACTED]" },
    });
    expect(JSON.stringify(memory.events[0])).not.toMatch(
      /MESSAGE_SECRET|KEY_SECRET|DATA_SECRET|ERROR_SECRET|STACK_SECRET|COOKIE_SECRET|sk-1234567890ABCDEF|xai-1234567890ABCDEF/,
    );
    expect(processOutput).not.toMatch(
      /MESSAGE_SECRET|KEY_SECRET|DATA_SECRET|ERROR_SECRET|STACK_SECRET|COOKIE_SECRET|sk-1234567890ABCDEF|xai-1234567890ABCDEF/,
    );
  });

  it("bounds oversized diagnostic values", () => {
    const sanitized = sanitizeDiagnosticData({
      text: "x".repeat(30_000),
      values: Array.from({ length: 300 }, (_, index) => index),
    });
    expect(String(sanitized.text)).toContain("[truncated]");
    expect((sanitized.values as unknown[]).length).toBe(200);
  });
});

describe("framework module registry", () => {
  it("initializes dependencies once and disposes in reverse order", async () => {
    const diagnostics = new FrameworkDiagnostics();
    const registry = new FrameworkModuleRegistry(diagnostics);
    const calls: string[] = [];
    registry
      .register({
        id: "foundation",
        version: "1",
        create: () => {
          calls.push("create:foundation");
          return "foundation-service";
        },
        dispose: () => { calls.push("dispose:foundation"); },
      })
      .register({
        id: "writer",
        version: "1",
        dependencies: ["foundation"],
        create: ({ registry: modules }) => {
          calls.push(`create:writer:${modules.stateOf("foundation")}`);
          return "writer-service";
        },
        dispose: () => { calls.push("dispose:writer"); },
      });

    await expect(registry.resolve("writer")).resolves.toBe("writer-service");
    await registry.initializeAll();
    await registry.disposeAll();
    expect(calls).toEqual([
      "create:foundation",
      "create:writer:ready",
      "dispose:writer",
      "dispose:foundation",
    ]);
  });

  it("rejects dependency cycles before exposing a service", async () => {
    const registry = new FrameworkModuleRegistry(new FrameworkDiagnostics());
    registry
      .register({ id: "alpha", version: "1", dependencies: ["beta"], create: () => "a" })
      .register({ id: "beta", version: "1", dependencies: ["alpha"], create: () => "b" });

    await expect(registry.resolve("alpha")).rejects.toMatchObject({
      code: "FRAMEWORK_MODULE_DEPENDENCY_CYCLE",
    });
    expect(registry.stateOf("alpha")).toBe("failed");
  });

  it("shares one lazy initialization across concurrent first calls", async () => {
    const registry = new FrameworkModuleRegistry(new FrameworkDiagnostics());
    let creates = 0;
    registry.register({
      id: "slow-module",
      version: "1",
      create: async () => {
        creates += 1;
        await new Promise((resolve) => setTimeout(resolve, 10));
        return { ready: true };
      },
    });

    const [first, second] = await Promise.all([
      registry.resolve<{ ready: boolean }>("slow-module"),
      registry.resolve<{ ready: boolean }>("slow-module"),
    ]);

    expect(first).toBe(second);
    expect(first.ready).toBe(true);
    expect(creates).toBe(1);
  });

  it("keeps a timed-out call in the bulkhead until its underlying operation settles", async () => {
    const registry = new FrameworkModuleRegistry({
      defaultTimeoutMs: 20,
      maxConcurrency: 1,
    });
    registry.registerValue("bounded", { ready: true });
    let settleFirst!: () => void;
    const firstOperation = new Promise<void>((resolve) => { settleFirst = resolve; });
    let secondStarted = false;

    const first = registry.invoke("bounded", "first", async () => {
      await firstOperation;
      return "first";
    });
    await expect(first).rejects.toMatchObject({ code: "FRAMEWORK_MODULE_TIMEOUT" });

    const second = registry.invoke("bounded", "second", () => {
      secondStarted = true;
      return "second";
    }, { timeoutMs: 1_000 });
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(secondStarted).toBe(false);

    settleFirst();
    await expect(second).resolves.toBe("second");
    expect(secondStarted).toBe(true);
  });

  it("applies the call timeout while waiting in the bulkhead queue", async () => {
    const registry = new FrameworkModuleRegistry({
      defaultTimeoutMs: 20,
      maxConcurrency: 1,
    });
    registry.registerValue("queued-timeout", { ready: true });
    let settleFirst!: () => void;
    const firstOperation = new Promise<void>((resolve) => { settleFirst = resolve; });
    let secondStarted = false;

    const first = registry.invoke("queued-timeout", "first", async () => {
      await firstOperation;
      return "first";
    }, { operationKind: "read" });
    await expect(first).rejects.toMatchObject({
      code: "FRAMEWORK_MODULE_TIMEOUT",
      retryable: true,
    });

    const second = registry.invoke("queued-timeout", "second", () => {
      secondStarted = true;
      return "second";
    }, { operationKind: "read", timeoutMs: 20 });
    await expect(second).rejects.toMatchObject({
      code: "FRAMEWORK_MODULE_TIMEOUT",
      retryable: true,
    });
    expect(secondStarted).toBe(false);

    settleFirst();
    await new Promise((resolve) => setTimeout(resolve, 0));
    await expect(registry.invoke(
      "queued-timeout",
      "third",
      () => "third",
      { operationKind: "read", timeoutMs: 100 },
    )).resolves.toBe("third");
  });

  it("returns a successful mutation that settles inside the cancellation grace period", async () => {
    const registry = new FrameworkModuleRegistry({ defaultTimeoutMs: 10 });
    registry.registerValue("late-success", { ready: true });

    await expect(registry.invoke("late-success", "commit", async (_service, signal) => {
      await new Promise<void>((resolve) => {
        signal.addEventListener("abort", () => setTimeout(resolve, 5), { once: true });
      });
      return "committed";
    }, {
      operationKind: "mutation",
      cancellationGraceMs: 100,
    })).resolves.toBe("committed");
  });

  it("returns non-retryable faults for cancelled mutations without a known success", async () => {
    const registry = new FrameworkModuleRegistry({ defaultTimeoutMs: 10, maxConcurrency: 1 });
    registry.registerValue("uncertain-mutation", { ready: true });

    await expect(registry.invoke("uncertain-mutation", "reject", async (_service, signal) => {
      await new Promise<void>((resolve) => {
        signal.addEventListener("abort", () => resolve(), { once: true });
      });
      throw new Error("mutation stopped after cancellation");
    }, {
      operationKind: "mutation",
      cancellationGraceMs: 100,
    })).rejects.toMatchObject({
      code: "FRAMEWORK_MODULE_MUTATION_ABORTED",
      retryable: false,
    });

    let settleUnknown!: () => void;
    const unresolved = new Promise<void>((resolve) => { settleUnknown = resolve; });
    let outcomeUnknownNotified = false;
    let underlyingMutationSettled = false;
    const unknown = registry.invoke("uncertain-mutation", "unknown", async () => {
      await unresolved;
      return "eventual success";
    }, {
      operationKind: "mutation",
      timeoutMs: 10,
      cancellationGraceMs: 15,
      onOutcomeUnknown: (settlement) => {
        outcomeUnknownNotified = true;
        void settlement.then(() => { underlyingMutationSettled = true; });
      },
    });
    await expect(unknown).rejects.toMatchObject({
      code: "FRAMEWORK_MODULE_OUTCOME_UNKNOWN",
      retryable: false,
    });
    expect(outcomeUnknownNotified).toBe(true);
    expect(underlyingMutationSettled).toBe(false);
    let queuedStarted = false;
    await expect(registry.invoke("uncertain-mutation", "queued", () => {
      queuedStarted = true;
      return "queued";
    }, {
      operationKind: "read",
      timeoutMs: 15,
    })).rejects.toMatchObject({
      code: "FRAMEWORK_MODULE_TIMEOUT",
      retryable: true,
    });
    expect(queuedStarted).toBe(false);
    settleUnknown();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(underlyingMutationSettled).toBe(true);
  });
});

describe("framework workflow engine", () => {
  it("retries retryable steps and compensates on a later critical failure", async () => {
    const memory = new MemoryDiagnosticSink();
    const diagnostics = new FrameworkDiagnostics([memory]);
    const kernel = new FrameworkKernel({ diagnostics });
    const engine = new FrameworkWorkflowEngine(kernel.modules, diagnostics);
    const calls: string[] = [];
    let attempts = 0;
    const result = await engine.run(
      {
        id: "book.write",
        steps: [
          {
            id: "reserve",
            run: () => {
              calls.push("reserve");
              return "reservation";
            },
            compensate: () => { calls.push("release"); },
          },
          {
            id: "generate",
            retry: { maxAttempts: 2 },
            run: () => {
              attempts += 1;
              calls.push(`generate:${attempts}`);
              if (attempts === 1) throw new FrameworkFault("provider busy", { retryable: true });
              return "draft";
            },
            compensate: () => { calls.push("discard"); },
          },
          {
            id: "persist",
            run: () => {
              calls.push("persist");
              throw new Error("disk full");
            },
          },
        ],
      },
      { bookId: "demo" },
    );

    expect(result.ok).toBe(false);
    expect(result.error?.code).toBe("FRAMEWORK_WORKFLOW_STEP_FAILED");
    expect(result.compensationErrors).toHaveLength(0);
    expect(calls).toEqual(["reserve", "generate:1", "generate:2", "persist", "discard", "release"]);
    expect(memory.events.some((event) => event.status === "retrying")).toBe(true);
    expect(memory.events.at(-1)?.status).toBe("failed");
  });

  it("records non-critical failures as degraded while continuing", async () => {
    const diagnostics = new FrameworkDiagnostics();
    const engine = new FrameworkWorkflowEngine(
      new FrameworkModuleRegistry(diagnostics),
      diagnostics,
    );
    const result = await engine.run({
      id: "book.read",
      steps: [
        { id: "optional-index", critical: false, run: () => { throw new Error("index unavailable"); } },
        { id: "fallback", run: () => "fallback-result" },
      ],
    }, {});

    expect(result.ok).toBe(true);
    expect(result.status).toBe("degraded");
    expect(result.output).toBe("fallback-result");
    expect(result.failedSteps).toEqual(["optional-index"]);
  });

  it("does not let compensation failure hide the primary failure", async () => {
    const diagnostics = new FrameworkDiagnostics();
    const engine = new FrameworkWorkflowEngine(
      new FrameworkModuleRegistry(diagnostics),
      diagnostics,
    );
    const result = await engine.run({
      id: "book.commit",
      steps: [
        {
          id: "prepare",
          run: () => "prepared",
          compensate: () => { throw new Error("rollback failed"); },
        },
        { id: "commit", run: () => { throw new Error("commit failed"); } },
      ],
    }, {});

    expect(result.error?.message).toBe("commit failed");
    expect(result.compensationErrors[0]?.code).toBe("FRAMEWORK_WORKFLOW_COMPENSATION_FAILED");
  });
});
