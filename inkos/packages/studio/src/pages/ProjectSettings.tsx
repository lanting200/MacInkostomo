import { useEffect, useState } from "react";
import { Bell, Bot, Radar, Settings2, Plus, Trash2 } from "lucide-react";
import { fetchJson, postApi, putApi, useApi } from "../hooks/use-api";
import type { Theme } from "../hooks/use-theme";
import type { TFunction } from "../hooks/use-i18n";
import { useColors } from "../hooks/use-colors";
import {
  buildDetectionConfig,
  buildNotifyChannel,
  DEFAULT_DETECTION,
  detectionDraftFromConfig,
  notifyDraftFromChannel,
  NOTIFY_TYPES,
  type DetectionDraft,
  type NotifyChannelDraft,
  type NotifyType,
  type OverrideRow,
} from "./project-settings-model";
import {
  createEmptySkillDraft,
  skillDraftFromSkill,
  skillDraftToPayload,
  type SkillDraft,
  type StudioSkill,
} from "./skill-ui-state";

interface Nav {
  toDashboard: () => void;
  toServices: () => void;
}

type NoticeTone = "success" | "error" | "info";

interface SkillsResponse {
  readonly skills: ReadonlyArray<StudioSkill>;
  readonly diagnostics?: ReadonlyArray<{ readonly path?: string; readonly message?: string }>;
}

// Smooth open/close via grid-template-rows (same trick as the sidebar).
function Collapse({ open, children }: { open: boolean; children: React.ReactNode }) {
  return (
    <div className={`grid transition-[grid-template-rows] duration-200 ease-out ${open ? "grid-rows-[1fr]" : "grid-rows-[0fr]"}`}>
      <div className="overflow-hidden">{children}</div>
    </div>
  );
}

function SettingsCard({
  title,
  description,
  icon,
  children,
}: {
  title: string;
  description: string;
  icon: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <section className="rounded-2xl border border-border/50 bg-card/70 p-5 shadow-sm space-y-4">
      <div className="flex items-start gap-3">
        <div className="mt-0.5 rounded-xl bg-primary/10 p-2 text-primary">{icon}</div>
        <div>
          <h2 className="text-base font-bold">{title}</h2>
          <p className="mt-1 text-sm text-muted-foreground leading-relaxed">{description}</p>
        </div>
      </div>
      {children}
    </section>
  );
}

const fieldClass = "w-full rounded-lg border border-border bg-secondary/30 px-3 py-2 text-sm outline-none focus:border-primary/50";

export function ProjectSettings({ nav, theme, t }: { nav: Nav; theme: Theme; t: TFunction }) {
  const c = useColors(theme);
  const isZh = t("nav.connected") === "\u5DF2\u8FDE\u63A5";
  const { data: overridesData, refetch: refetchOverrides } = useApi<{ overrides: Record<string, unknown> }>("/project/model-overrides");
  const { data: defaultModelData, refetch: refetchDefaultModel } = useApi<{ service: string | null; defaultModel: string | null }>("/project/default-model");
  const { data: notifyData, refetch: refetchNotify } = useApi<{ channels: unknown[] }>("/project/notify");
  const { data: modeData, refetch: refetchMode } = useApi<{ mode: "legacy" | "v2" }>("/project/input-governance-mode");
  const { data: detectionData, refetch: refetchDetection } = useApi<{ detection: unknown | null }>("/project/detection");
  const { data: skillsData, refetch: refetchSkills } = useApi<SkillsResponse>("/skills");
  const [mode, setMode] = useState<"legacy" | "v2">("v2");
  const [defaultService, setDefaultService] = useState("");
  const [defaultModel, setDefaultModel] = useState("");
  const [overrideRows, setOverrideRows] = useState<OverrideRow[]>([]);
  const [notifyChannels, setNotifyChannels] = useState<NotifyChannelDraft[]>([]);
  const [det, setDet] = useState<DetectionDraft>({ ...DEFAULT_DETECTION });
  const [skillDraft, setSkillDraft] = useState<SkillDraft>(() => createEmptySkillDraft());
  const [editingSkillId, setEditingSkillId] = useState<string | null>(null);
  const [notice, setNotice] = useState<{ tone: NoticeTone; message: string } | null>(null);
  const [saving, setSaving] = useState<string | null>(null);
  const skills = skillsData?.skills ?? [];

  useEffect(() => {
    if (modeData?.mode) setMode(modeData.mode);
  }, [modeData]);

  useEffect(() => {
    if (!overridesData) return;
    setOverrideRows(Object.entries(overridesData.overrides ?? {}).map(([agent, val]) => {
      if (typeof val === "string") return { agent, model: val };
      const { model, ...rest } = (val ?? {}) as { model?: string };
      return { agent, model: model ?? "", rest };
    }));
  }, [overridesData]);

  useEffect(() => {
    if (!defaultModelData) return;
    setDefaultService(defaultModelData.service ?? "");
    setDefaultModel(defaultModelData.defaultModel ?? "");
  }, [defaultModelData]);

  useEffect(() => {
    if (!notifyData) return;
    setNotifyChannels((notifyData.channels ?? []).map(notifyDraftFromChannel));
  }, [notifyData]);

  useEffect(() => {
    if (!detectionData) return;
    setDet(detectionDraftFromConfig(detectionData.detection));
  }, [detectionData]);

  const runSave = async (key: string, work: () => Promise<void>, success: string) => {
    setSaving(key);
    setNotice(null);
    try {
      await work();
      setNotice({ tone: "success", message: success });
    } catch (e) {
      setNotice({ tone: "error", message: e instanceof Error ? e.message : String(e) });
    } finally {
      setSaving(null);
    }
  };

  const updateChannel = (index: number, patch: Partial<NotifyChannelDraft>) => {
    setNotifyChannels((prev) => prev.map((ch, i) => (i === index ? { ...ch, ...patch } : ch)));
  };

  return (
    <div className="space-y-8">
      <div className="flex items-center gap-2 text-sm text-muted-foreground">
        <button onClick={nav.toDashboard} className={c.link}>{t("bread.home")}</button>
        <span className="text-border">/</span>
        <span>{t("settings.title")}</span>
      </div>

      <div className="space-y-2">
        <h1 className="font-serif text-3xl flex items-center gap-3">
          <Settings2 size={28} className="text-primary" />
          {t("settings.title")}
        </h1>
        <p className="text-sm text-muted-foreground">{t("settings.subtitle")}</p>
      </div>

      {notice && (
        <div
          className={`rounded-xl px-4 py-3 text-sm ${
            notice.tone === "error"
              ? "bg-destructive/10 text-destructive"
              : notice.tone === "info"
                ? "bg-secondary text-muted-foreground"
                : "bg-emerald-500/10 text-emerald-600"
          }`}
        >
          {notice.message}
        </div>
      )}

      <SettingsCard title={t("settings.inputGovernance")} description={t("settings.inputGovernanceHint")} icon={<Radar size={18} />}>
        <div className="flex flex-wrap items-center gap-3">
          <select
            value={mode}
            onChange={(e) => setMode(e.target.value === "legacy" ? "legacy" : "v2")}
            className="rounded-lg border border-border bg-secondary/30 px-3 py-2 text-sm outline-none"
          >
            <option value="v2">v2</option>
            <option value="legacy">legacy</option>
          </select>
          <button
            onClick={() => runSave("mode", async () => {
              await putApi("/project/input-governance-mode", { mode });
              await refetchMode();
            }, t("settings.saved"))}
            disabled={saving === "mode"}
            className={`rounded-lg px-4 py-2 text-sm font-bold ${c.btnPrimary} disabled:opacity-40`}
          >
            {saving === "mode" ? t("config.saving") : t("config.save")}
          </button>
        </div>
      </SettingsCard>

      <SettingsCard
        title={isZh ? "运行时 Skill" : "Runtime skills"}
        description={isZh ? "把可复用的专业能力保存到项目，Chat 可以自主使用，也可以在输入框用 + 号强制启用。" : "Save reusable expertise in the project. Chat can choose skills automatically, or you can force one from the + menu."}
        icon={<Bot size={18} />}
      >
        <div className="space-y-3">
          {skills.length === 0 ? (
            <p className="text-xs text-muted-foreground italic">{isZh ? "还没有 Skill。" : "No skills yet."}</p>
          ) : (
            <div className="grid gap-2 md:grid-cols-2">
              {skills.map((skill) => (
                <div key={skill.id} className="rounded-xl border border-border/60 bg-secondary/20 p-3">
                  <div className="flex items-start gap-2">
                    <div className="min-w-0 flex-1">
                      <div className="flex items-center gap-2">
                        <div className="truncate text-sm font-semibold">{skill.name}</div>
                        <span className="rounded-full bg-background px-2 py-0.5 text-[10px] uppercase tracking-wide text-muted-foreground">
                          {skill.source ?? "skill"}
                        </span>
                      </div>
                      <div className="mt-0.5 font-mono text-[11px] text-muted-foreground/70">@{skill.id}</div>
                      <p className="mt-1 text-xs leading-5 text-muted-foreground">{skill.whenToUse || skill.description || (isZh ? "无说明" : "No description")}</p>
                    </div>
                    {skill.editable ? (
                      <div className="flex shrink-0 gap-1">
                        <button
                          type="button"
                          onClick={() => {
                            setEditingSkillId(skill.id);
                            setSkillDraft(skillDraftFromSkill(skill));
                          }}
                          className="rounded-lg px-2 py-1 text-xs font-medium text-muted-foreground hover:bg-primary/10 hover:text-primary"
                        >
                          {isZh ? "编辑" : "Edit"}
                        </button>
                        <button
                          type="button"
                          onClick={() => runSave(`delete-skill:${skill.id}`, async () => {
                            await fetchJson(`/skills/${encodeURIComponent(skill.id)}`, { method: "DELETE" });
                            if (editingSkillId === skill.id) {
                              setEditingSkillId(null);
                              setSkillDraft(createEmptySkillDraft());
                            }
                            await refetchSkills();
                          }, isZh ? "Skill 已删除" : "Skill deleted")}
                          className="rounded-lg p-1.5 text-muted-foreground hover:bg-destructive/10 hover:text-destructive transition-colors"
                          aria-label={isZh ? `删除 ${skill.name}` : `Delete ${skill.name}`}
                        >
                          <Trash2 size={14} />
                        </button>
                      </div>
                    ) : null}
                  </div>
                </div>
              ))}
            </div>
          )}

          <div className="rounded-xl border border-border/60 bg-secondary/20 p-3 space-y-2">
            <div className="flex items-center justify-between gap-2">
              <div>
                <div className="text-sm font-semibold">
                  {editingSkillId ? (isZh ? "编辑项目 Skill" : "Edit project skill") : (isZh ? "新增项目 Skill" : "Add project skill")}
                </div>
                <p className="mt-1 text-xs text-muted-foreground">
                  {isZh ? "这些文件会保存到 .inkos/skills/<id>/SKILL.md。" : "Saved to .inkos/skills/<id>/SKILL.md."}
                </p>
              </div>
              {editingSkillId ? (
                <button
                  type="button"
                  onClick={() => {
                    setEditingSkillId(null);
                    setSkillDraft(createEmptySkillDraft());
                  }}
                  className="rounded-lg px-3 py-1.5 text-xs font-semibold text-muted-foreground hover:bg-secondary"
                >
                  {isZh ? "取消编辑" : "Cancel"}
                </button>
              ) : null}
            </div>
            <div className="grid gap-2 md:grid-cols-2">
              <input
                value={skillDraft.id}
                onChange={(e) => setSkillDraft((draft) => ({ ...draft, id: e.target.value }))}
                disabled={Boolean(editingSkillId)}
                placeholder="skill-id"
                className={`${fieldClass} font-mono disabled:opacity-50`}
              />
              <input
                value={skillDraft.name}
                onChange={(e) => setSkillDraft((draft) => ({ ...draft, name: e.target.value }))}
                placeholder={isZh ? "Skill 名称" : "Skill name"}
                className={fieldClass}
              />
              <input
                value={skillDraft.whenToUse}
                onChange={(e) => setSkillDraft((draft) => ({ ...draft, whenToUse: e.target.value }))}
                placeholder={isZh ? "什么时候使用" : "When to use"}
                className={`${fieldClass} md:col-span-2`}
              />
              <input
                value={skillDraft.triggers}
                onChange={(e) => setSkillDraft((draft) => ({ ...draft, triggers: e.target.value }))}
                placeholder={isZh ? "触发词，用逗号分隔" : "Triggers, comma separated"}
                className={fieldClass}
              />
              <input
                value={skillDraft.sessionKinds}
                onChange={(e) => setSkillDraft((draft) => ({ ...draft, sessionKinds: e.target.value }))}
                placeholder="chat,book,short,play"
                className={fieldClass}
              />
              <textarea
                value={skillDraft.body}
                onChange={(e) => setSkillDraft((draft) => ({ ...draft, body: e.target.value }))}
                placeholder={isZh ? "写给模型的专业能力说明..." : "Instructions for the model..."}
                rows={5}
                className={`${fieldClass} leading-6 md:col-span-2`}
              />
            </div>
            <div className="flex justify-end">
              <button
                onClick={() => runSave("skill", async () => {
                  const payload = skillDraftToPayload(skillDraft, !editingSkillId);
                  if (editingSkillId) {
                    await putApi(`/skills/${encodeURIComponent(editingSkillId)}`, payload);
                  } else {
                    await postApi("/skills", payload);
                  }
                  await refetchSkills();
                  setEditingSkillId(null);
                  setSkillDraft(createEmptySkillDraft());
                }, isZh ? "Skill 已保存" : "Skill saved")}
                disabled={saving === "skill" || !skillDraft.body.trim() || !skillDraftToPayload(skillDraft).id}
                className={`rounded-lg px-4 py-2 text-sm font-bold ${c.btnPrimary} disabled:opacity-40`}
              >
                {saving === "skill" ? t("config.saving") : t("config.save")}
              </button>
            </div>
          </div>
        </div>
      </SettingsCard>

      {/* Model routing — per-agent model overrides */}
      <SettingsCard title={t("settings.modelOverrides")} description={t("settings.modelOverridesHint")} icon={<Bot size={18} />}>
        <div className="rounded-xl border border-border/60 bg-secondary/20 p-3 space-y-2">
          <div>
            <div className="text-sm font-semibold">{t("settings.globalDefaultModel")}</div>
            <p className="mt-1 text-xs text-muted-foreground">{t("settings.globalDefaultModelHint")}</p>
          </div>
          <div className="grid gap-2 md:grid-cols-[minmax(0,0.8fr)_minmax(0,1.2fr)_auto]">
            <input
              value={defaultService}
              onChange={(e) => setDefaultService(e.target.value)}
              placeholder={t("settings.serviceId")}
              className={`${fieldClass} font-mono`}
            />
            <input
              value={defaultModel}
              onChange={(e) => setDefaultModel(e.target.value)}
              placeholder={t("settings.modelId")}
              className={`${fieldClass} font-mono`}
            />
            <button
              onClick={() => runSave("default-model", async () => {
                await putApi("/project/default-model", {
                  service: defaultService.trim() || undefined,
                  defaultModel: defaultModel.trim(),
                });
                await refetchDefaultModel();
              }, t("settings.saved"))}
              disabled={saving === "default-model" || !defaultModel.trim()}
              className={`rounded-lg px-4 py-2 text-sm font-bold ${c.btnPrimary} disabled:opacity-40`}
            >
              {saving === "default-model" ? t("config.saving") : t("config.save")}
            </button>
          </div>
        </div>
        <div className="space-y-2">
          {overrideRows.length === 0 && (
            <p className="text-xs text-muted-foreground italic">{t("settings.noOverrides")}</p>
          )}
          {overrideRows.map((row, i) => (
            <div key={i} className="flex items-center gap-2">
              <input
                value={row.agent}
                onChange={(e) => setOverrideRows((prev) => prev.map((r, j) => (j === i ? { ...r, agent: e.target.value } : r)))}
                placeholder={t("settings.agentName")}
                className={`${fieldClass} flex-1`}
              />
              <span className="text-muted-foreground">→</span>
              <input
                value={row.model}
                onChange={(e) => setOverrideRows((prev) => prev.map((r, j) => (j === i ? { ...r, model: e.target.value } : r)))}
                placeholder={t("settings.modelId")}
                className={`${fieldClass} flex-1 font-mono`}
              />
              <button
                onClick={() => setOverrideRows((prev) => prev.filter((_, j) => j !== i))}
                className="shrink-0 rounded-lg p-2 text-muted-foreground hover:bg-destructive/10 hover:text-destructive transition-colors"
                aria-label="remove"
              >
                <Trash2 size={15} />
              </button>
            </div>
          ))}
        </div>
        <div className="flex flex-wrap gap-2">
          <button
            onClick={() => setOverrideRows((prev) => [...prev, { agent: "", model: "" }])}
            className={`flex items-center gap-1.5 rounded-lg px-3 py-2 text-sm font-medium ${c.btnSecondary}`}
          >
            <Plus size={14} /> {t("settings.addOverride")}
          </button>
          <button
            onClick={() => runSave("overrides", async () => {
              const overrides: Record<string, unknown> = {};
              for (const r of overrideRows) {
                const agent = r.agent.trim();
                const model = r.model.trim();
                if (!agent || !model) continue;
                overrides[agent] = r.rest && Object.keys(r.rest).length > 0 ? { ...r.rest, model } : model;
              }
              await putApi("/project/model-overrides", { overrides });
              await refetchOverrides();
            }, t("settings.saved"))}
            disabled={saving === "overrides"}
            className={`rounded-lg px-4 py-2 text-sm font-bold ${c.btnPrimary} disabled:opacity-40`}
          >
            {saving === "overrides" ? t("config.saving") : t("config.save")}
          </button>
          <button onClick={nav.toServices} className={`rounded-lg px-4 py-2 text-sm font-bold ${c.btnSecondary}`}>
            {t("settings.openModelConfig")}
          </button>
        </div>
      </SettingsCard>

      {/* Notification channels */}
      <SettingsCard title={t("settings.notify")} description={t("settings.notifyHint")} icon={<Bell size={18} />}>
        <div className="space-y-3">
          {notifyChannels.length === 0 && (
            <p className="text-xs text-muted-foreground italic">{t("settings.noChannels")}</p>
          )}
          {notifyChannels.map((ch, i) => (
            <div key={i} className="rounded-xl border border-border/60 bg-secondary/20 p-3 space-y-2">
              <div className="flex items-center gap-2">
                <select
                  value={ch.type}
                  onChange={(e) => updateChannel(i, { type: e.target.value as NotifyType })}
                  className="rounded-lg border border-border bg-background px-3 py-1.5 text-sm outline-none"
                >
                  {NOTIFY_TYPES.map((nt) => <option key={nt.value} value={nt.value}>{nt.label}</option>)}
                </select>
                <div className="flex-1" />
                <button
                  onClick={() => setNotifyChannels((prev) => prev.filter((_, j) => j !== i))}
                  className="rounded-lg p-1.5 text-muted-foreground hover:bg-destructive/10 hover:text-destructive transition-colors"
                  aria-label="remove"
                >
                  <Trash2 size={15} />
                </button>
              </div>
              {ch.type === "telegram" && (
                <div className="grid grid-cols-2 gap-2">
                  <input value={ch.botToken ?? ""} onChange={(e) => updateChannel(i, { botToken: e.target.value })} placeholder="botToken" className={`${fieldClass} font-mono`} />
                  <input value={ch.chatId ?? ""} onChange={(e) => updateChannel(i, { chatId: e.target.value })} placeholder="chatId" className={`${fieldClass} font-mono`} />
                </div>
              )}
              {(ch.type === "feishu" || ch.type === "wechat-work") && (
                <input value={ch.webhookUrl ?? ""} onChange={(e) => updateChannel(i, { webhookUrl: e.target.value })} placeholder="webhookUrl" className={`${fieldClass} font-mono`} />
              )}
              {ch.type === "webhook" && (
                <div className="grid grid-cols-2 gap-2">
                  <input value={ch.url ?? ""} onChange={(e) => updateChannel(i, { url: e.target.value })} placeholder="url" className={`${fieldClass} font-mono`} />
                  <input value={ch.secret ?? ""} onChange={(e) => updateChannel(i, { secret: e.target.value })} placeholder="secret (可选)" className={`${fieldClass} font-mono`} />
                </div>
              )}
            </div>
          ))}
        </div>
        <div className="flex gap-2">
          <button
            onClick={() => setNotifyChannels((prev) => [...prev, { type: "feishu" }])}
            className={`flex items-center gap-1.5 rounded-lg px-3 py-2 text-sm font-medium ${c.btnSecondary}`}
          >
            <Plus size={14} /> {t("settings.addChannel")}
          </button>
          <button
            onClick={() => runSave("notify", async () => {
              await putApi("/project/notify", { channels: notifyChannels.map(buildNotifyChannel) });
              await refetchNotify();
            }, t("settings.saved"))}
            disabled={saving === "notify"}
            className={`rounded-lg px-4 py-2 text-sm font-bold ${c.btnPrimary} disabled:opacity-40`}
          >
            {saving === "notify" ? t("config.saving") : t("config.save")}
          </button>
        </div>
      </SettingsCard>

      {/* AIGC detection */}
      <SettingsCard title={t("settings.detection")} description={t("settings.detectionHint")} icon={<Radar size={18} />}>
        <label className="flex items-center gap-2 text-sm">
          <input type="checkbox" checked={det.enabled} onChange={(e) => setDet((d) => ({ ...d, enabled: e.target.checked }))} />
          {t("settings.detectionEnable")}
        </label>
        <Collapse open={det.enabled}>
          <div className="space-y-2 pt-1">
            <div className="grid grid-cols-2 gap-2">
              <label className="text-xs text-muted-foreground space-y-1">
                <span>{t("settings.detectionProvider")}</span>
                <select value={det.provider} onChange={(e) => setDet((d) => ({ ...d, provider: e.target.value }))} className={fieldClass}>
                  <option value="custom">custom</option>
                  <option value="gptzero">gptzero</option>
                  <option value="originality">originality</option>
                </select>
              </label>
              <label className="text-xs text-muted-foreground space-y-1">
                <span>{t("settings.detectionApiKeyEnv")}</span>
                <input value={det.apiKeyEnv} onChange={(e) => setDet((d) => ({ ...d, apiKeyEnv: e.target.value }))} placeholder="DETECTOR_API_KEY" className={`${fieldClass} font-mono`} />
              </label>
            </div>
            <label className="text-xs text-muted-foreground space-y-1 block">
              <span>{t("settings.detectionApiUrl")}</span>
              <input value={det.apiUrl} onChange={(e) => setDet((d) => ({ ...d, apiUrl: e.target.value }))} placeholder="https://..." className={`${fieldClass} font-mono`} />
            </label>
            <div className="grid grid-cols-2 gap-2">
              <label className="text-xs text-muted-foreground space-y-1">
                <span>{t("settings.detectionThreshold")} (0–1)</span>
                <input type="number" min={0} max={1} step={0.05} value={det.threshold} onChange={(e) => setDet((d) => ({ ...d, threshold: Number(e.target.value) }))} className={fieldClass} />
              </label>
              <label className="text-xs text-muted-foreground space-y-1">
                <span>{t("settings.detectionMaxRetries")} (1–10)</span>
                <input type="number" min={1} max={10} step={1} value={det.maxRetries} onChange={(e) => setDet((d) => ({ ...d, maxRetries: Number(e.target.value) }))} className={fieldClass} />
              </label>
            </div>
            <label className="flex items-center gap-2 text-sm">
              <input type="checkbox" checked={det.autoRewrite} onChange={(e) => setDet((d) => ({ ...d, autoRewrite: e.target.checked }))} />
              {t("settings.detectionAutoRewrite")}
            </label>
          </div>
        </Collapse>
        <button
          onClick={() => runSave("detection", async () => {
            const payload = { detection: buildDetectionConfig(det) };
            await fetchJson("/project/detection", {
              method: "PUT",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify(payload),
            });
            await refetchDetection();
          }, t("settings.saved"))}
          disabled={saving === "detection"}
          className={`rounded-lg px-4 py-2 text-sm font-bold ${c.btnPrimary} disabled:opacity-40`}
        >
          {saving === "detection" ? t("config.saving") : t("config.save")}
        </button>
      </SettingsCard>
    </div>
  );
}
