import { describe, expect, it } from "vitest";
import { applyRuntimeStateDelta } from "../state/state-reducer.js";
import { RuntimeStateDeltaSchema } from "../models/runtime-state.js";

describe("applyRuntimeStateDelta", () => {
  const persistentToken = {
    objectId: "xuanwei-demon-office-token",
    name: "玄微的镇妖司旧令牌",
    aliases: ["旧令牌", "镇妖司令牌"],
    material: "木质",
    inscription: "镇妖司",
    appearance: "边角磨损",
    owner: "玄微",
    location: "玄微随身行囊",
    status: "完好",
    firstSeenChapter: 1,
    lastSeenChapter: 1,
    linkedHookIds: ["old-token-origin"],
    notes: "第一章留下的身份伏笔。",
  };

  it("applies a chapter-local delta into structured state", () => {
    const result = applyRuntimeStateDelta({
      snapshot: {
        manifest: {
          schemaVersion: 2,
          language: "en",
          lastAppliedChapter: 11,
          projectionVersion: 1,
          migrationWarnings: [],
        },
        currentState: {
          chapter: 11,
          facts: [],
        },
        hooks: {
          hooks: [
            {
              hookId: "mentor-debt",
              startChapter: 1,
              type: "relationship",
              status: "open",
              lastAdvancedChapter: 11,
              expectedPayoff: "Reveal the debt.",
              notes: "Still unresolved.",
            },
          ],
        },
        chapterSummaries: {
          rows: [
            {
              chapter: 11,
              title: "Old Ledger",
              characters: "Lin Yue",
              events: "Lin Yue finds the old ledger.",
              stateChanges: "The debt trail tightens.",
              hookActivity: "mentor-debt advanced",
              mood: "tense",
              chapterType: "mainline",
            },
          ],
        },
      },
      delta: RuntimeStateDeltaSchema.parse({
        chapter: 12,
        currentStatePatch: {
          currentGoal: "Trace the debt through the river-port ledger.",
        },
        hookOps: {
          upsert: [
            {
              hookId: "mentor-debt",
              startChapter: 1,
              type: "relationship",
              status: "progressing",
              lastAdvancedChapter: 12,
              expectedPayoff: "Reveal the debt.",
              notes: "The river-port ledger sharpens the clue.",
            },
          ],
          resolve: [],
          defer: [],
        },
        chapterSummary: {
          chapter: 12,
          title: "River-Port Ledger",
          characters: "Lin Yue",
          events: "Lin Yue cross-checks the river-port ledger.",
          stateChanges: "The debt trail narrows.",
          hookActivity: "mentor-debt advanced",
          mood: "tight",
          chapterType: "investigation",
        },
        notes: [],
      }),
    });

    expect(result.manifest.lastAppliedChapter).toBe(12);
    expect(result.currentState.chapter).toBe(12);
    expect(result.currentState.facts).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          predicate: "Current Goal",
          object: "Trace the debt through the river-port ledger.",
          sourceChapter: 12,
        }),
      ]),
    );
    expect(result.hooks.hooks).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          hookId: "mentor-debt",
          status: "progressing",
          lastAdvancedChapter: 12,
        }),
      ]),
    );
    expect(result.chapterSummaries.rows.map((row) => row.chapter)).toEqual([11, 12]);
  });

  it("rejects duplicate summary rows for the same chapter", () => {
    expect(() =>
      applyRuntimeStateDelta({
        snapshot: {
          manifest: {
            schemaVersion: 2,
            language: "zh",
            lastAppliedChapter: 11,
            projectionVersion: 1,
            migrationWarnings: [],
          },
          currentState: {
            chapter: 11,
            facts: [],
          },
          hooks: {
            hooks: [],
          },
          chapterSummaries: {
            rows: [
              {
                chapter: 12,
                title: "河埠对账",
                characters: "林月",
                events: "林月核对货单。",
                stateChanges: "师债线索收束。",
                hookActivity: "mentor-debt 推进",
                mood: "紧绷",
                chapterType: "主线推进",
              },
            ],
          },
        },
        delta: RuntimeStateDeltaSchema.parse({
          chapter: 12,
          hookOps: {
            upsert: [],
            resolve: [],
            defer: [],
          },
          chapterSummary: {
            chapter: 12,
            title: "再写一版河埠对账",
            characters: "林月",
            events: "重复写入。",
            stateChanges: "重复写入。",
            hookActivity: "mentor-debt 推进",
            mood: "紧绷",
            chapterType: "主线推进",
          },
          notes: [],
        }),
      }),
    ).toThrow(/duplicate summary/i);
  });

  it("allows reapplying the same chapter when explicitly enabled", () => {
    const result = applyRuntimeStateDelta({
      snapshot: {
        manifest: {
          schemaVersion: 2,
          language: "zh",
          lastAppliedChapter: 12,
          projectionVersion: 1,
          migrationWarnings: [],
        },
        currentState: {
          chapter: 12,
          facts: [],
        },
        hooks: {
          hooks: [],
        },
        chapterSummaries: {
          rows: [
            {
              chapter: 12,
              title: "旧版河埠对账",
              characters: "林月",
              events: "旧摘要。",
              stateChanges: "旧变化。",
              hookActivity: "旧钩子",
              mood: "紧绷",
              chapterType: "主线推进",
            },
          ],
        },
      },
      delta: RuntimeStateDeltaSchema.parse({
        chapter: 12,
        hookOps: {
          upsert: [],
          resolve: [],
          defer: [],
        },
        chapterSummary: {
          chapter: 12,
          title: "新版河埠对账",
          characters: "林月",
          events: "新摘要。",
          stateChanges: "新变化。",
          hookActivity: "新钩子",
          mood: "压抑",
          chapterType: "修订",
        },
        notes: [],
      }),
      allowReapply: true,
    });

    expect(result.manifest.lastAppliedChapter).toBe(12);
    expect(result.chapterSummaries.rows).toEqual([
      expect.objectContaining({
        chapter: 12,
        title: "新版河埠对账",
        events: "新摘要。",
      }),
    ]);
  });

  it("ignores resolve and defer operations for unknown hooks", () => {
    const result = applyRuntimeStateDelta({
      snapshot: {
        manifest: {
          schemaVersion: 2,
          language: "en",
          lastAppliedChapter: 11,
          projectionVersion: 1,
          migrationWarnings: [],
        },
        currentState: {
          chapter: 11,
          facts: [],
        },
        hooks: {
          hooks: [],
        },
        chapterSummaries: {
          rows: [],
        },
      },
      delta: RuntimeStateDeltaSchema.parse({
        chapter: 12,
        hookOps: {
          upsert: [],
          resolve: ["mentor-debt"],
          defer: ["mentor-debt-later"],
        },
        notes: [],
      }),
    });

    expect(result.manifest.lastAppliedChapter).toBe(12);
    expect(result.hooks.hooks).toEqual([]);
  });

  it("rejects an unexplained stable-attribute change when an object returns many chapters later", () => {
    expect(() => applyRuntimeStateDelta({
      snapshot: {
        manifest: {
          schemaVersion: 2,
          language: "zh",
          lastAppliedChapter: 19,
          projectionVersion: 1,
          migrationWarnings: [],
        },
        currentState: { chapter: 19, facts: [] },
        hooks: { hooks: [] },
        chapterSummaries: { rows: [] },
        objects: { objects: [persistentToken] },
      },
      delta: RuntimeStateDeltaSchema.parse({
        chapter: 20,
        hookOps: { upsert: [], resolve: [], defer: [] },
        objectOps: {
          upsert: [{
            ...persistentToken,
            material: "铜质",
            inscription: "镇妖",
            lastSeenChapter: 20,
          }],
        },
        notes: [],
      }),
    })).toThrow(/persistent object .* (material|inscription) conflict/i);
  });

  it("allows a stable-attribute change only when the story supplies an explicit reason", () => {
    const result = applyRuntimeStateDelta({
      snapshot: {
        manifest: {
          schemaVersion: 2,
          language: "zh",
          lastAppliedChapter: 19,
          projectionVersion: 1,
          migrationWarnings: [],
        },
        currentState: { chapter: 19, facts: [] },
        hooks: { hooks: [] },
        chapterSummaries: { rows: [] },
        objects: { objects: [persistentToken] },
      },
      delta: RuntimeStateDeltaSchema.parse({
        chapter: 20,
        hookOps: { upsert: [], resolve: [], defer: [] },
        objectOps: {
          upsert: [{
            ...persistentToken,
            material: "铜包木",
            lastSeenChapter: 20,
            attributeChangeReason: "第20章正文明确写明玄微请匠人给旧木令牌包覆铜壳。",
          }],
        },
        notes: [],
      }),
    });

    expect(result.objects?.objects).toEqual([
      expect.objectContaining({
        objectId: persistentToken.objectId,
        material: "铜包木",
        firstSeenChapter: 1,
        lastSeenChapter: 20,
      }),
    ]);
  });

  it("keeps similarly named objects separate when their stable ids differ", () => {
    const result = applyRuntimeStateDelta({
      snapshot: {
        manifest: {
          schemaVersion: 2,
          language: "zh",
          lastAppliedChapter: 2,
          projectionVersion: 1,
          migrationWarnings: [],
        },
        currentState: { chapter: 2, facts: [] },
        hooks: { hooks: [] },
        chapterSummaries: { rows: [] },
        objects: { objects: [persistentToken] },
      },
      delta: RuntimeStateDeltaSchema.parse({
        chapter: 3,
        hookOps: { upsert: [], resolve: [], defer: [] },
        objectOps: {
          upsert: [{
            ...persistentToken,
            objectId: "purification-talisman-plaque",
            name: "净煞符木牌",
            aliases: ["木牌", "令牌"],
            inscription: "净煞符",
            owner: "林月",
            firstSeenChapter: 3,
            lastSeenChapter: 3,
            linkedHookIds: [],
            notes: "与玄微旧令牌不是同一物。",
          }],
        },
        notes: [],
      }),
    });

    expect(result.objects?.objects.map((object) => object.objectId)).toEqual([
      "xuanwei-demon-office-token",
      "purification-talisman-plaque",
    ]);
  });

  it("keeps mention-only hooks from mutating lastAdvancedChapter", () => {
    const result = applyRuntimeStateDelta({
      snapshot: {
        manifest: {
          schemaVersion: 2,
          language: "en",
          lastAppliedChapter: 11,
          projectionVersion: 1,
          migrationWarnings: [],
        },
        currentState: {
          chapter: 11,
          facts: [],
        },
        hooks: {
          hooks: [
            {
              hookId: "mentor-debt",
              startChapter: 1,
              type: "relationship",
              status: "open",
              lastAdvancedChapter: 8,
              expectedPayoff: "Reveal the debt.",
              notes: "Still unresolved.",
            },
          ],
        },
        chapterSummaries: {
          rows: [],
        },
      },
      delta: RuntimeStateDeltaSchema.parse({
        chapter: 12,
        hookOps: {
          upsert: [],
          mention: ["mentor-debt"],
          resolve: [],
          defer: [],
        },
        notes: [],
      }),
    });

    expect(result.hooks.hooks).toEqual([
      expect.objectContaining({
        hookId: "mentor-debt",
        lastAdvancedChapter: 8,
        status: "open",
      }),
    ]);
  });

  it("does not downgrade an existing progressed hook when the next delta restates it as open", () => {
    const result = applyRuntimeStateDelta({
      snapshot: {
        manifest: {
          schemaVersion: 2,
          language: "zh",
          lastAppliedChapter: 2,
          projectionVersion: 1,
          migrationWarnings: [],
        },
        currentState: {
          chapter: 2,
          facts: [],
        },
        hooks: {
          hooks: [
            {
              hookId: "pressure-record",
              startChapter: 1,
              type: "evidence",
              status: "progressing",
              lastAdvancedChapter: 2,
              expectedPayoff: "公开一号泵房压力异常的签字漏洞。",
              notes: "第2章已让主角拿到压力曲线。",
            },
          ],
        },
        chapterSummaries: {
          rows: [],
        },
      },
      delta: RuntimeStateDeltaSchema.parse({
        chapter: 3,
        hookOps: {
          upsert: [
            {
              hookId: "pressure-record",
              startChapter: 1,
              type: "evidence",
              status: "open",
              lastAdvancedChapter: 2,
              expectedPayoff: "公开一号泵房压力异常的签字漏洞。",
              notes: "第3章再次提到压力曲线，但没有新推进。",
            },
          ],
          mention: [],
          resolve: [],
          defer: [],
        },
        notes: [],
      }),
    });

    expect(result.hooks.hooks).toEqual([
      expect.objectContaining({
        hookId: "pressure-record",
        status: "progressing",
        lastAdvancedChapter: 2,
      }),
    ]);
  });

  it("does not resurrect a resolved hook when the next delta restates it as open", () => {
    const result = applyRuntimeStateDelta({
      snapshot: {
        manifest: {
          schemaVersion: 2,
          language: "zh",
          lastAppliedChapter: 8,
          projectionVersion: 1,
          migrationWarnings: [],
        },
        currentState: {
          chapter: 8,
          facts: [],
        },
        hooks: {
          hooks: [
            {
              hookId: "sealed-toolbox",
              startChapter: 1,
              type: "evidence",
              status: "resolved",
              lastAdvancedChapter: 8,
              expectedPayoff: "揭开红色封条是谁重新贴上的。",
              notes: "第8章已兑现封条来源。",
            },
          ],
        },
        chapterSummaries: {
          rows: [],
        },
      },
      delta: RuntimeStateDeltaSchema.parse({
        chapter: 9,
        hookOps: {
          upsert: [
            {
              hookId: "sealed-toolbox",
              startChapter: 1,
              type: "evidence",
              status: "open",
              lastAdvancedChapter: 8,
              expectedPayoff: "揭开红色封条是谁重新贴上的。",
              notes: "第9章回看封条，不应重开已兑现钩子。",
            },
          ],
          mention: [],
          resolve: [],
          defer: [],
        },
        notes: [],
      }),
    });

    expect(result.hooks.hooks).toEqual([
      expect.objectContaining({
        hookId: "sealed-toolbox",
        status: "resolved",
        lastAdvancedChapter: 8,
      }),
    ]);
  });

  it("merges duplicate restated hook families into the matched active hook", () => {
    const result = applyRuntimeStateDelta({
      snapshot: {
        manifest: {
          schemaVersion: 2,
          language: "en",
          lastAppliedChapter: 11,
          projectionVersion: 1,
          migrationWarnings: [],
        },
        currentState: {
          chapter: 11,
          facts: [],
        },
        hooks: {
          hooks: [
            {
              hookId: "anonymous-source-scope",
              startChapter: 3,
              type: "source-risk",
              status: "open",
              lastAdvancedChapter: 8,
              expectedPayoff: "Reveal how much the anonymous source already knew about the route and address.",
              notes: "Still unresolved anonymous source knowledge question.",
            },
          ],
        },
        chapterSummaries: {
          rows: [],
        },
      },
      delta: RuntimeStateDeltaSchema.parse({
        chapter: 12,
        hookOps: {
          upsert: [
            {
              hookId: "anonymous-source-restated",
              startChapter: 12,
              type: "source-risk",
              status: "open",
              lastAdvancedChapter: 12,
              expectedPayoff: "Reveal how much the anonymous source already knew about the route.",
              notes: "Anonymous source knowledge question restated with slightly different wording.",
            },
          ],
          mention: [],
          resolve: [],
          defer: [],
        },
        notes: [],
      }),
    });

    expect(result.hooks.hooks).toHaveLength(1);
    expect(result.hooks.hooks[0]).toEqual(expect.objectContaining({
      hookId: "anonymous-source-scope",
      lastAdvancedChapter: 12,
    }));
  });
});
