/* eslint-disable @typescript-eslint/no-explicit-any */
/**
 * Demo parity for migration 0149: hotel-level policies and knowledge base inherited by the branches.
 * Same rules, names, errors and shapes as the SQL (preview names branches and fields, apply needs the preview's token,
 * a branch's own fields are kept unless the branch is chosen explicitly, revert gives the hotel text back, all audited).
 */
import { uid, nowISO, type Row } from "./data";
import { normalizeArabic } from "../../supabase/functions/_shared/guardrails";

const POLICY_FIELDS = ["title", "content_ar", "content_en", "is_public"] as const;
const TOPICS = ["checkin", "cancellation", "wifi", "parking", "location", "children", "contact", "stay", "privacy", "other"];
const TOKEN_TTL_S = 900;

export interface InheritanceCtx {
  T: (t: string) => Row[];
  byId: (t: string, id: string) => Row | undefined;
  me: () => Row | null;
  myBranches: () => string[];
  hasRole: (...r: string[]) => boolean;
  requireCap: (code: string) => void;
  can: (code: string) => boolean;
  requireBranch: (b: string | null | undefined) => void;
  checkVersion: (cur: number, exp: number | null | undefined) => void;
  audit: (branch: string | null, action: string, entity: string, id: string, details: Row) => void;
  emit: (t: string) => void;
  staffId: () => string | null;
}

const same = (a: unknown, b: unknown) => (a ?? null) === (b ?? null);
const hash = (s: string) => { let h = 5381; for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) >>> 0; return h.toString(16).padStart(8, "0"); };

/** The old screen edits a linked row directly: the changed fields become the branch's own (trg_policy_inherit). */
export function inheritPolicyEdit(old: Row, next: Row): void {
  if (!old.master_id) { next.override_fields = []; next.master_id = null; return; }
  next.master_id = old.master_id; next.master_version = old.master_version;
  const changed = POLICY_FIELDS.filter((f) => !same(old[f], next[f]));
  next.override_fields = [...new Set([...(old.override_fields ?? []), ...changed])].sort();
}

export function inheritanceRpcs(ctx: InheritanceCtx): Record<string, (a: any) => any> {
  const { T, byId, me, myBranches, hasRole, requireCap, can, requireBranch, checkVersion, audit, emit, staffId } = ctx;
  const org = () => me()!.organization_id as string;
  const hotelBranches = () => T("branches").filter((b) => b.organization_id === org() && !b.archived_at).sort((a, b) => String(a.name_ar).localeCompare(String(b.name_ar)) || String(a.id).localeCompare(String(b.id)));
  const masters = () => T("policy_masters").filter((m) => m.organization_id === org());
  const needMe = () => { if (!me()) throw new Error("FORBIDDEN"); };

  const policyGate = (action: "add" | "edit") => {
    needMe();
    if (!hasRole("owner", "manager")) throw new Error("FORBIDDEN: hotel-level policies are for the owner or manager");
    if (!can("policies")) throw new Error("FORBIDDEN: policies");
    void action;
    if (hotelBranches().some((b) => !myBranches().includes(b.id))) throw new Error("FORBIDDEN: hotel-level policies need access to every branch");
  };
  const knowledgeGate = () => { needMe(); requireCap("knowledge"); if (!hasRole("owner", "manager")) throw new Error("FORBIDDEN: org-wide entries require manager"); };

  const token = (kind: string, expiry: number, body: string) => `${expiry}.${hash(kind + "|" + org() + "|" + staffId() + "|" + expiry + "|" + body)}${hash(body + kind)}`;
  const tokenOk = (kind: string, t: unknown, body: string) => {
    const m = /^(\d{1,12})\.([0-9a-f]+)$/.exec(String(t ?? "")); if (!m) return false;
    const exp = Number(m[1]); if (exp < Math.floor(Date.now() / 1000)) throw new Error("PREVIEW_EXPIRED");
    return token(kind, exp, body) === t;
  };
  const newExpiry = () => Math.floor(Date.now() / 1000) + TOKEN_TTL_S;

  const masterInput = (p: Row) => {
    const old = p.id ? masters().find((m) => m.id === p.id) : undefined;
    if (p.id && !old && p.version != null) throw new Error("NOT_FOUND");
    const topic = old?.topic ?? p.topic;
    if (!TOPICS.includes(topic)) throw new Error("VALIDATION: policy_topic");
    const title = String(p.title ?? "").trim(), ar = String(p.content_ar ?? "").trim();
    const en = String(p.content_en ?? "").trim() || null; let label = String(p.topic_label ?? "").trim() || null;
    if (!title || !ar) throw new Error("VALIDATION: policy_required");
    if (title.length > 120 || ar.length > 4000) throw new Error("VALIDATION: policy_length");
    if (topic !== "other") label = null; else if (label && label.length > 60) throw new Error("VALIDATION: topic_label");
    if (topic !== "other" && !old && masters().some((m) => m.topic === topic && !m.archived_at)) throw new Error("VALIDATION: policy_topic_exists");
    return { id: p.id ?? uid(), topic, topic_label: label, title, content_ar: ar, content_en: en, is_public: p.is_public ?? old?.is_public ?? true, sort_order: p.sort_order ?? old?.sort_order ?? 0, version: (old?.version ?? 0) + 1, archived_at: null as string | null };
  };

  const policyPlan = (m: Row) => hotelBranches().map((b) => {
    let r = T("property_policies").find((x) => x.branch_id === b.id && x.master_id === m.id);
    let upd: string[] = [], action: string; const keep: string[] = [], over: string[] = [];
    if (r) {
      if (r.archived_at) action = "skip_archived";
      else {
        for (const f of POLICY_FIELDS) if (!same(r[f] === "" ? null : r[f], m[f])) { if ((r.override_fields ?? []).includes(f)) { keep.push(f); over.push(f); } else upd.push(f); }
        action = upd.length ? "update" : keep.length ? "keep_override" : "unchanged";
      }
    } else {
      r = m.topic !== "other" ? T("property_policies").find((x) => x.branch_id === b.id && !x.master_id && x.topic === m.topic && !x.archived_at) : undefined;
      if (r) { for (const f of POLICY_FIELDS) if (!same(r[f], m[f])) { keep.push(f); over.push(f); } action = "link_existing"; }
      else { action = "create"; upd = [...POLICY_FIELDS]; }
    }
    return { branch_id: b.id, branch_name: b.name_ar, policy_id: r?.id ?? null, action, update_fields: upd, kept_fields: keep, overwritable_fields: over };
  });
  const policyBody = (m: Row, plan: unknown) => JSON.stringify([{ ...m, version: undefined }, plan, masters().find((x) => x.id === m.id)?.version ?? 0]);

  // ---- knowledge
  const sharedEntry = (id: string) => { const k = byId("knowledge_entries", id); if (!k || k.organization_id !== org() || k.branch_id != null || k.archived_at) throw new Error("NOT_FOUND"); return k; };
  const activeOverride = (entryId: string, branch: string) => T("knowledge_entries").find((o) => o.overrides_entry_id === entryId && o.branch_id === branch && !o.archived_at);
  const kwOf = (a: unknown[]) => [...new Set(a.map((x) => normalizeArabic(String(x ?? ""))).filter((w) => w.length >= 2))].sort();
  const knowledgePlan = (k: Row, p: Row) => {
    const ch: string[] = [];
    if ("question" in p && String(p.question).trim() !== k.question) ch.push("question");
    if ("answer" in p && String(p.answer).trim() !== k.answer) ch.push("answer");
    if ("answer_en" in p && (String(p.answer_en ?? "").trim() || null) !== (k.answer_en ?? null)) ch.push("answer_en");
    if ("category" in p && p.category !== k.category) ch.push("category");
    if ("is_public" in p && !!p.is_public !== k.is_public) ch.push("is_public");
    if ("is_active" in p && !!p.is_active !== k.is_active) ch.push("is_active");
    if ("priority" in p && Number(p.priority) !== k.priority) ch.push("priority");
    if ("keywords" in p && JSON.stringify(kwOf(p.keywords)) !== JSON.stringify(k.keywords)) ch.push("keywords");
    return {
      entry_id: k.id, version: k.version, changed_fields: ch,
      branches: hotelBranches().map((b) => { const o = activeOverride(k.id, b.id);
        return { branch_id: b.id, branch_name: b.name_ar, override_id: o?.id ?? null, action: !ch.length ? "unchanged" : o ? "keep_override" : "inherits", changed_fields: o ? [] : ch, overwritable_fields: o ? ch : [] }; }),
    };
  };
  const kBody = (id: string, plan: unknown, p: Row) => id + JSON.stringify(plan) + JSON.stringify(p);

  return {
    fn_policy_masters_list: () => {
      needMe(); if (!can("policies")) throw new Error("FORBIDDEN: policies");
      return { masters: masters().filter((m) => !m.archived_at).sort((a, b) => a.sort_order - b.sort_order || String(a.title).localeCompare(String(b.title)))
        .map((m) => ({ ...m, branches: T("property_policies").filter((p) => p.master_id === m.id && myBranches().includes(p.branch_id)).map((p) => ({ branch_id: p.branch_id, policy_id: p.id, override_fields: p.override_fields ?? [], master_version: p.master_version ?? null, archived: !!p.archived_at })) })) };
    },
    fn_policy_master_preview: ({ p }) => {
      policyGate(p.version == null ? "add" : "edit");
      const m = masterInput(p), plan = policyPlan(m); const { version: _v, ...master } = m; void _v;
      return { master, is_new: p.version == null, branches: plan, token: token("policy", newExpiry(), policyBody(m, plan)) };
    },
    fn_policy_master_apply: ({ p }) => {
      policyGate(p.version == null ? "add" : "edit");
      const m = masterInput(p), plan = policyPlan(m);
      if (!tokenOk("policy", p.token, policyBody(m, plan))) throw new Error("PREVIEW_STALE");
      const cur = masters().find((x) => x.id === m.id);
      if (cur) { if (p.version == null) throw new Error("VERSION_REQUIRED"); checkVersion(cur.version, p.version); }
      const ow: string[] = p.overwrite_branches ?? [];
      if (ow.some((b) => !plan.some((e) => e.branch_id === b && e.overwritable_fields.length))) throw new Error("VALIDATION: overwrite_not_overridden");
      const before = cur ? { ...cur } : null;
      if (cur) Object.assign(cur, m, { updated_at: nowISO() }); else T("policy_masters").push({ ...m, organization_id: org(), created_at: nowISO(), updated_at: nowISO() });
      let created = 0, updated = 0, overwritten = 0, keptOwn = 0;
      for (const e of plan) {
        const fields: string[] = [...e.update_fields];
        if (e.action === "create") {
          const r: Row = { id: uid(), organization_id: org(), branch_id: e.branch_id, topic: m.topic, topic_label: m.topic_label, title: m.title, content_ar: m.content_ar, content_en: m.content_en, is_public: m.is_public, sort_order: m.sort_order, master_id: m.id, master_version: m.version, override_fields: [], updated_by: staffId(), updated_at: nowISO(), created_at: nowISO(), archived_at: null };
          T("property_policies").push(r); created++;
          audit(e.branch_id, "policy.inherited_created", "property_policy", r.id, { master_id: m.id, after: { title: r.title, content_ar: r.content_ar, is_public: r.is_public } });
        } else if (e.action === "link_existing") {
          const r = byId("property_policies", e.policy_id)!; Object.assign(r, { master_id: m.id, master_version: m.version, override_fields: [...e.kept_fields] });
          if (e.kept_fields.length) keptOwn++;
          audit(e.branch_id, "policy.linked_to_master", "property_policy", r.id, { master_id: m.id, kept_own_fields: e.kept_fields });
        } else if (e.action === "update" || e.action === "keep_override") {
          const r = byId("property_policies", e.policy_id)!; const ex = ow.includes(e.branch_id); if (ex) fields.push(...e.overwritable_fields);
          if (!fields.length) { if (e.kept_fields.length) keptOwn++; continue; }
          const b4 = { title: r.title, content_ar: r.content_ar, content_en: r.content_en, is_public: r.is_public, override_fields: r.override_fields };
          for (const f of fields) r[f] = (m as any)[f];
          r.override_fields = (r.override_fields ?? []).filter((f: string) => !fields.includes(f)); Object.assign(r, { master_version: m.version, updated_by: staffId(), updated_at: nowISO() });
          audit(e.branch_id, ex && e.overwritable_fields.length ? "policy.master_overwrote_branch" : "policy.master_broadcast", "property_policy", r.id, { master_id: m.id, fields, before: b4, after: { title: r.title, content_ar: r.content_ar, content_en: r.content_en, is_public: r.is_public }, reason: p.reason ?? null });
          if (ex) overwritten++; else updated++;
        } else if (e.action === "unchanged" && e.kept_fields.length) keptOwn++;
      }
      audit(null, cur ? "policy.master_updated" : "policy.master_created", "organization", org(), { master_id: m.id, before, after: m, reason: p.reason ?? null, branches_created: created, branches_updated: updated, branches_overwritten: overwritten, branches_kept_own: keptOwn });
      emit("property_policies"); emit("policy_masters");
      return { ok: true, id: m.id, version: m.version, created, updated, overwritten, kept_own: keptOwn };
    },
    fn_policy_branch_revert: ({ p_policy_id, p_fields, p_reason }) => {
      needMe();
      const r = byId("property_policies", p_policy_id); if (!r || r.organization_id !== org()) throw new Error("NOT_FOUND");
      if (!myBranches().includes(r.branch_id) || !can("policies")) throw new Error("FORBIDDEN: policies");
      if (!r.master_id) throw new Error("VALIDATION: not_inherited");
      const m = masters().find((x) => x.id === r.master_id && !x.archived_at); if (!m) throw new Error("NOT_FOUND");
      const f: string[] = (p_fields ?? r.override_fields ?? []).filter((x: string) => (r.override_fields ?? []).includes(x));
      if (!f.length) return { ok: true, reverted: [] };
      const b4 = { title: r.title, content_ar: r.content_ar, content_en: r.content_en, is_public: r.is_public, override_fields: r.override_fields };
      for (const x of f) r[x] = (m as any)[x];
      r.override_fields = (r.override_fields ?? []).filter((x: string) => !f.includes(x)); Object.assign(r, { master_version: m.version, updated_by: staffId(), updated_at: nowISO() });
      audit(r.branch_id, "policy.branch_reverted", "property_policy", r.id, { master_id: r.master_id, fields: f, before: b4, reason: p_reason ?? null });
      emit("property_policies"); return { ok: true, reverted: f };
    },
    fn_knowledge_main_preview: ({ p_entry, p }) => {
      knowledgeGate(); const k = sharedEntry(p_entry); const plan = knowledgePlan(k, p ?? {});
      const vis = (id: string) => myBranches().includes(id);
      const hid = plan.branches.filter((e) => !vis(e.branch_id));
      return { entry_id: plan.entry_id, version: plan.version, changed_fields: plan.changed_fields, branches: plan.branches.filter((e) => vis(e.branch_id)),
        hidden_branches: { inherits: hid.filter((e) => e.action === "inherits").length, keep_override: hid.filter((e) => e.action === "keep_override").length },
        token: token("knowledge", newExpiry(), kBody(p_entry, plan, p ?? {})) };
    },
    fn_knowledge_main_apply: ({ p_entry, p }) => {
      knowledgeGate(); const k = sharedEntry(p_entry); const plan = knowledgePlan(k, p ?? {});
      const { token: t, overwrite_branches, ...edit } = p ?? {};
      if (!tokenOk("knowledge", t, kBody(p_entry, plan, edit))) throw new Error("PREVIEW_STALE");
      const ow: string[] = overwrite_branches ?? [];
      if (ow.some((b) => !plan.branches.some((e) => e.branch_id === b && e.action === "keep_override"))) throw new Error("VALIDATION: overwrite_not_overridden");
      if (edit.version == null) throw new Error("VERSION_REQUIRED"); checkVersion(k.version, edit.version);
      const b4 = { question: k.question, answer: k.answer, keywords: k.keywords, is_public: k.is_public, is_active: k.is_active, category: k.category, branch_id: k.branch_id };
      Object.assign(k, { question: "question" in edit ? String(edit.question).trim() : k.question, answer: "answer" in edit ? String(edit.answer).trim() : k.answer, answer_en: "answer_en" in edit ? (String(edit.answer_en ?? "").trim() || null) : k.answer_en,
        keywords: "keywords" in edit ? kwOf(edit.keywords) : k.keywords, category: edit.category ?? k.category, is_public: edit.is_public ?? k.is_public, is_active: edit.is_active ?? k.is_active, priority: edit.priority ?? k.priority, version: k.version + 1, updated_by: staffId(), updated_at: nowISO() });
      audit(null, "knowledge.updated", "knowledge_entry", k.id, { before: b4, after: { question: k.question, answer: k.answer, keywords: k.keywords }, reason: edit.reason ?? null });
      let n = 0;
      for (const e of plan.branches) if (ow.includes(e.branch_id)) {
        requireBranch(e.branch_id); const o = byId("knowledge_entries", e.override_id!)!;
        Object.assign(o, { archived_at: nowISO(), archived_by: staffId(), archive_reason: "overwritten by hotel-level update", version: o.version + 1, updated_at: nowISO() });
        audit(o.branch_id, "knowledge.master_overwrote_branch", "knowledge_entry", o.id, { master_id: k.id, before: { question: o.question, answer: o.answer, keywords: o.keywords }, fields: e.overwritable_fields, reason: edit.reason ?? null }); n++;
      }
      audit(null, "knowledge.master_broadcast", "knowledge_entry", k.id, { fields: plan.changed_fields, branches: plan.branches, overwritten: n, reason: edit.reason ?? null });
      emit("knowledge_entries"); return { ok: true, id: k.id, version: k.version, overwritten: n };
    },
    fn_knowledge_branch_override: ({ p_entry, p_branch, p = {} }) => {
      requireCap("knowledge"); requireBranch(p_branch); const k = sharedEntry(p_entry);
      if (!hotelBranches().some((b) => b.id === p_branch)) throw new Error("NOT_FOUND");
      const ex = activeOverride(k.id, p_branch); if (ex) return { ok: true, id: ex.id, version: ex.version, existing: true };
      const o: Row = { ...k, id: uid(), branch_id: p_branch, overrides_entry_id: k.id, question: String(p.question ?? "").trim() || k.question, answer: String(p.answer ?? "").trim() || k.answer,
        answer_en: "answer_en" in p ? (String(p.answer_en ?? "").trim() || null) : k.answer_en, keywords: p.keywords ? kwOf(p.keywords) : k.keywords, is_public: p.is_public ?? k.is_public,
        used_count: 0, last_used_at: null, version: 1, archived_at: null, archived_by: null, archive_reason: null, created_by: staffId(), updated_by: staffId(), created_at: nowISO(), updated_at: nowISO() };
      T("knowledge_entries").push(o);
      audit(p_branch, "knowledge.branch_override_created", "knowledge_entry", o.id, { overrides: k.id, after: { question: o.question, answer: o.answer } });
      emit("knowledge_entries"); return { ok: true, id: o.id, version: o.version, existing: false };
    },
    fn_knowledge_revert_override: ({ p_override, p_reason }) => {
      requireCap("knowledge"); const o = byId("knowledge_entries", p_override);
      if (!o || o.organization_id !== org() || !o.overrides_entry_id || o.archived_at) throw new Error("NOT_FOUND");
      requireBranch(o.branch_id);
      Object.assign(o, { archived_at: nowISO(), archived_by: staffId(), archive_reason: String(p_reason ?? "").trim() || "reverted to the hotel-level entry", version: o.version + 1, updated_at: nowISO() });
      audit(o.branch_id, "knowledge.branch_override_reverted", "knowledge_entry", o.id, { overrides: o.overrides_entry_id, before: { question: o.question, answer: o.answer, keywords: o.keywords }, reason: p_reason ?? null });
      emit("knowledge_entries"); return { ok: true };
    },
    fn_knowledge_effective: ({ p_branch }) => {
      requireCap("knowledge"); requireBranch(p_branch);
      return T("knowledge_entries").filter((k) => k.organization_id === org() && !k.archived_at && (k.branch_id == null || k.branch_id === p_branch) && !(k.branch_id == null && activeOverride(k.id, p_branch)))
        .sort((a, b) => b.priority - a.priority || b.used_count - a.used_count || String(a.created_at).localeCompare(String(b.created_at)))
        .map((k) => ({ id: k.id, branch_id: k.branch_id, origin: k.branch_id == null ? "hotel" : k.overrides_entry_id ? "branch_override" : "branch_only", overrides_entry_id: k.overrides_entry_id ?? null, category: k.category, question: k.question, keywords: k.keywords, answer: k.answer, answer_en: k.answer_en, is_public: k.is_public, is_active: k.is_active, priority: k.priority, version: k.version }));
    },
  };
}
