import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { createStudioServer } from "../api/server.js";

describe("Studio skill endpoints", () => {
  let root: string;

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), "inkos-studio-skills-"));
  });

  afterEach(async () => {
    await rm(root, { recursive: true, force: true });
  });

  it("lists built-in skills and project-local skills", async () => {
    await mkdir(join(root, ".inkos", "skills", "detective-play"), { recursive: true });
    await writeFile(
      join(root, ".inkos", "skills", "detective-play", "SKILL.md"),
      [
        "---",
        "id: detective-play",
        "name: Detective Play",
        "description: Evidence-chain play skill.",
        "whenToUse: Use for detective play.",
        "triggers: [detective]",
        "sessionKinds: [play]",
        "---",
        "Track evidence before twists.",
      ].join("\n"),
      { flag: "w" },
    );

    const app = createStudioServer({} as never, root);
    const res = await app.request("/api/v1/skills");
    const json = await res.json() as { skills: Array<{ id: string; source: string; editable: boolean; body?: string }> };

    expect(res.status).toBe(200);
    expect(json.skills.map((skill) => skill.id)).toContain("open-world-play");
    expect(json.skills).toContainEqual(expect.objectContaining({
      id: "detective-play",
      source: "project",
      editable: true,
      body: "Track evidence before twists.",
    }));
  });

  it("creates, updates, and deletes project skills as SKILL.md files", async () => {
    const app = createStudioServer({} as never, root);

    const createRes = await app.request("/api/v1/skills", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        id: "romance-play",
        name: "Romance Play",
        description: "Relationship-focused play skill.",
        whenToUse: "Use for romance interactions.",
        triggers: ["romance"],
        sessionKinds: ["play"],
        body: "Keep emotional continuity visible.",
      }),
    });
    expect(createRes.status).toBe(200);
    const created = await createRes.json() as { skill: { id: string; editable: boolean } };
    expect(created.skill).toMatchObject({ id: "romance-play", editable: true });
    expect(await readFile(join(root, ".inkos", "skills", "romance-play", "SKILL.md"), "utf-8"))
      .toContain("Keep emotional continuity visible.");

    const updateRes = await app.request("/api/v1/skills/romance-play", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        name: "Romance Play",
        description: "Relationship-focused play skill.",
        whenToUse: "Use for romance interactions.",
        triggers: ["romance", "date"],
        sessionKinds: ["play"],
        body: "Track longing, avoidance, and revealed care.",
      }),
    });
    expect(updateRes.status).toBe(200);
    expect(await readFile(join(root, ".inkos", "skills", "romance-play", "SKILL.md"), "utf-8"))
      .toContain("Track longing, avoidance, and revealed care.");

    const deleteRes = await app.request("/api/v1/skills/romance-play", { method: "DELETE" });
    expect(deleteRes.status).toBe(200);
    expect((await app.request("/api/v1/skills")).status).toBe(200);
    const list = await (await app.request("/api/v1/skills")).json() as { skills: Array<{ id: string }> };
    expect(list.skills.map((skill) => skill.id)).not.toContain("romance-play");
  });

  it("defaults optional project skill text fields when the Studio quick form leaves them blank", async () => {
    const app = createStudioServer({} as never, root);

    const res = await app.request("/api/v1/skills", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        id: "quick-skill",
        name: "",
        description: "",
        whenToUse: "",
        body: "Use the quick skill.",
      }),
    });

    expect(res.status).toBe(200);
    const json = await res.json() as { skill: { id: string; name: string; description: string; whenToUse: string } };
    expect(json.skill).toMatchObject({
      id: "quick-skill",
      name: "quick-skill",
      description: "Project runtime skill.",
      whenToUse: "Use when explicitly selected by the user.",
    });
  });
});
