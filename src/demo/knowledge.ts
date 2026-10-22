/* eslint-disable @typescript-eslint/no-explicit-any */
/**
 * Demo parity for migration 0010 (knowledge base). Same rules as the SQL functions:
 * public read returns only public+active+non-archived entries of the branch (or org-wide),
 * writes need owner/manager/supervisor (org-wide entries need manager), updates need the
 * expected version, archive needs a reason, unanswered questions are de-duplicated by their
 * normalized text with digits masked.
 */
import { normalizeArabic } from "../../supabase/functions/_shared/guardrails";
import { uid, nowISO, ORG, BRANCH_A, type Row } from "./data";

export const DEMO_ZERO_BRANCH = "00000000-0000-0000-0000-000000000000";

const normKeyword = (k: string) => normalizeArabic(String(k ?? ""));

export function seedKnowledge(T: (t: string) => Row[], staffId: string) {
  const mk = (c: string, q: string, k: string[], a: string, p: number, used = 0): Row => ({
    id: uid(), organization_id: ORG, branch_id: BRANCH_A, category: c, question: q, keywords: k.map(normKeyword), answer: a, answer_en: null,
    is_public: true, is_active: true, priority: p, used_count: used, last_used_at: used ? nowISO() : null, version: 1,
    archived_at: null, archived_by: null, archive_reason: null, created_by: staffId, created_at: nowISO(), updated_by: staffId, updated_at: nowISO(),
  });
  T("knowledge_entries").push(
    mk("facilities", "هل يوجد مسبح؟", ["مسبح", "سباحه", "pool"], "نعم، يوجد مسبح خارجي مشترك يعمل يوميًا من 8 صباحًا حتى 10 مساءً، والدخول مجاني لنزلاء المنشأة. يُمنع نزول الأطفال دون مرافق.", 5, 14),
    mk("services", "هل تقدمون الإفطار؟", ["افطار", "فطور", "breakfast", "وجبه"], "لا يُقدَّم إفطار داخل المنشأة، لكن كل وحدة مزودة بمطبخ صغير، وتتوفر مطاعم ومخابز على بُعد دقائق سيرًا.", 4, 9),
    mk("facilities", "هل يوجد مصلى؟", ["مصلى", "صلاه", "مسجد"], "يوجد مصلى للرجال في الدور الأرضي بجوار الاستقبال، وأقرب مسجد على بُعد 200 متر.", 3, 3),
    mk("services", "هل توجد خدمة غسيل ملابس؟", ["غسيل", "ملابس", "مغسله", "laundry", "غساله"], "تتوفر غسالة ملابس في وحدات الغرفتين، وخدمة مغسلة خارجية بطلب من الاستقبال (رسوم بحسب القطعة، تُضاف على الحجز).", 3, 5),
    mk("stay", "هل يُسمح بالحيوانات الأليفة؟", ["حيوان", "حيوانات", "قطه", "كلب", "pet", "pets"], "نعتذر، لا يُسمح باصطحاب الحيوانات الأليفة داخل الوحدات حفاظًا على راحة بقية النزلاء.", 2, 2),
    mk("stay", "هل يمكن إضافة سرير إضافي؟", ["سرير اضافي", "سرير", "مهد", "طفل رضيع", "extra bed"], "يتوفر سرير إضافي قابل للطي ومهد للأطفال بطلب مسبق، بحسب سعة الوحدة؛ يُضاف الطلب على الحجز ويؤكده الاستقبال.", 2, 4),
    mk("payment", "ما طرق الدفع المتاحة؟", ["دفع", "بطاقه", "مدى", "تحويل", "كاش", "نقد", "visa", "mada", "apple pay"], "يُقبل الدفع بمدى وبطاقات الائتمان والتحويل البنكي والنقد عند الاستقبال. لا يُطلب منك إرسال بيانات بطاقتك عبر المحادثة أبدًا.", 2, 7),
    mk("services", "هل يوجد تنظيف يومي للوحدة؟", ["تنظيف يومي", "تنظيف", "نظافه", "تغيير المناشف", "مناشف", "housekeeping"], "تنظيف الوحدة يتم قبل كل وصول، ويتوفر تنظيف دوري كل 3 أيام للإقامات الطويلة، وتُستبدل المناشف عند الطلب عبر الاستقبال.", 2, 1),
    mk("location", "ما أقرب الأماكن للتسوق والمطاعم؟", ["تسوق", "مول", "مطاعم", "مطعم", "سوبرماركت", "بقاله", "قريب"], "يبعد مركز التسوق الرئيسي 5 دقائق بالسيارة، وتوجد بقالة ومطاعم عائلية على بُعد دقائق سيرًا من المبنى.", 1, 2),
    mk("stay", "هل يوجد مواقف ذوي الإعاقة أو وحدات مهيأة؟", ["اعاقه", "ذوي", "كرسي متحرك", "مصعد", "مهياه", "accessible"], "المبنى مزود بمصعد، وتتوفر وحدة مهيأة في الدور الأرضي بطلب مسبق، مع موقف قريب من المدخل.", 1, 0),
  );
  const uq = (q: string, n: number, daysAgo: number): Row => {
    const d = new Date(); d.setDate(d.getDate() - daysAgo);
    return { id: uid(), organization_id: ORG, branch_id: BRANCH_A, question: q, normalized: normalizeArabic(q.replace(/\d{4,}/g, "#")), asked_count: n, first_asked_at: d.toISOString(), last_asked_at: nowISO(), status: "open", knowledge_entry_id: null, last_conversation_id: null, resolved_by: null, resolved_at: null, resolve_note: null };
  };
  T("unanswered_questions").push(uq("هل يوجد جاكوزي في الوحدة؟", 3, 2), uq("هل عندكم خدمة توصيل من المطار؟", 2, 1), uq("هل الوحدات فيها شاشة نتفلكس؟", 1, 0));
}

/** Returns the RPC implementations; `ctx` gives access to the store and the auth helpers of client.ts. */
export function knowledgeRpcs(ctx: {
  T: (t: string) => Row[];
  byId: (t: string, id: string) => Row | undefined;
  me: () => Row | null;
  myBranches: () => string[];
  hasRole: (...r: string[]) => boolean;
  requireRole: (...r: string[]) => void;
  requireBranch: (b: string | null | undefined) => void;
  checkVersion: (cur: number, exp: number | null | undefined) => void;
  audit: (branch: string | null, action: string, entity: string, id: string, details: Row) => void;
  emit: (t: string) => void;
  staffId: () => string | null;
}): Record<string, (a: any) => any> {
  const { T, byId, me, myBranches, hasRole, requireRole, requireBranch, checkVersion, audit, emit, staffId } = ctx;
  const publicRows = (branch: string) => T("knowledge_entries").filter((k) => k.organization_id === byId("branches", branch)?.organization_id && k.is_public && k.is_active && !k.archived_at && (k.branch_id == null || k.branch_id === branch))
    .sort((a, b) => b.priority - a.priority || b.used_count - a.used_count || String(a.created_at).localeCompare(String(b.created_at)));
  const pick = (k: Row) => ({ id: k.id, category: k.category, question: k.question, keywords: k.keywords, answer: k.answer, priority: k.priority });
  return {
    fn_public_knowledge: ({ p_branch }) => publicRows(p_branch).map(pick),
    fn_staff_knowledge: ({ p_branch }) => { const m = me(); if (!m || !myBranches().includes(p_branch)) return []; return T("knowledge_entries").filter((k) => k.organization_id === m.organization_id && k.is_active && !k.archived_at && (k.branch_id == null || k.branch_id === p_branch)).map((k) => ({ ...pick(k), is_public: k.is_public })); },
    fn_admin_upsert_knowledge: ({ p }) => {
      requireRole("owner", "manager", "supervisor");
      const m = me()!; const branch = p.branch_id || null;
      if (branch) requireBranch(branch); else if (!hasRole("owner", "manager")) throw new Error("FORBIDDEN: org-wide entries require manager");
      const q = String(p.question ?? "").trim(), a = String(p.answer ?? "").trim();
      if (q.length < 3) throw new Error("VALIDATION: question"); if (a.length < 2) throw new Error("VALIDATION: answer");
      const kw = [...new Set((p.keywords ?? []).map(normKeyword).filter((w: string) => w.length >= 2))].sort();
      let k: Row;
      if (!p.id) {
        k = { id: uid(), organization_id: m.organization_id, branch_id: branch, category: p.category ?? "general", question: q, keywords: kw, answer: a, answer_en: p.answer_en?.trim() || null, is_public: p.is_public ?? true, is_active: p.is_active ?? true, priority: p.priority ?? 0, used_count: 0, last_used_at: null, version: 1, archived_at: null, archived_by: null, archive_reason: null, created_by: staffId(), created_at: nowISO(), updated_by: staffId(), updated_at: nowISO() };
        T("knowledge_entries").push(k);
        audit(branch, "knowledge.created", "knowledge_entry", k.id, { after: { question: k.question, keywords: k.keywords, is_public: k.is_public } });
      } else {
        k = byId("knowledge_entries", p.id)!; if (!k || k.organization_id !== m.organization_id) throw new Error("NOT_FOUND");
        if (k.branch_id) requireBranch(k.branch_id);
        if (p.version == null) throw new Error("VERSION_REQUIRED");
        checkVersion(k.version, p.version);
        const before = { question: k.question, answer: k.answer, keywords: k.keywords, is_public: k.is_public, is_active: k.is_active, category: k.category, branch_id: k.branch_id };
        Object.assign(k, { branch_id: "branch_id" in p ? branch : k.branch_id, category: p.category ?? k.category, question: q, keywords: kw, answer: a, answer_en: "answer_en" in p ? (p.answer_en?.trim() || null) : k.answer_en, is_public: p.is_public ?? k.is_public, is_active: p.is_active ?? k.is_active, priority: p.priority ?? k.priority, version: k.version + 1, updated_by: staffId(), updated_at: nowISO() });
        audit(k.branch_id, "knowledge.updated", "knowledge_entry", k.id, { before, after: { question: k.question, answer: k.answer, keywords: k.keywords, is_public: k.is_public, is_active: k.is_active, category: k.category, branch_id: k.branch_id }, reason: p.reason ?? null });
      }
      if (p.unanswered_id) { const u = byId("unanswered_questions", p.unanswered_id); if (u && u.organization_id === m.organization_id) Object.assign(u, { status: "answered", knowledge_entry_id: k.id, resolved_by: staffId(), resolved_at: nowISO() }); emit("unanswered_questions"); }
      emit("knowledge_entries");
      return { ok: true, id: k.id, version: k.version };
    },
    fn_admin_archive_knowledge: ({ p_id, p_reason, p_archive = true }) => {
      requireRole("owner", "manager", "supervisor");
      const k = byId("knowledge_entries", p_id); if (!k || k.organization_id !== me()!.organization_id) throw new Error("NOT_FOUND");
      if (k.branch_id) requireBranch(k.branch_id);
      if (p_archive) { if (!String(p_reason ?? "").trim()) throw new Error("VALIDATION: reason"); Object.assign(k, { archived_at: nowISO(), archived_by: staffId(), archive_reason: p_reason, is_active: false, version: k.version + 1, updated_at: nowISO() }); }
      else Object.assign(k, { archived_at: null, archived_by: null, archive_reason: null, is_active: true, version: k.version + 1, updated_at: nowISO() });
      audit(k.branch_id, p_archive ? "knowledge.archived" : "knowledge.restored", "knowledge_entry", k.id, { reason: p_reason ?? null });
      emit("knowledge_entries"); return { ok: true };
    },
    fn_admin_resolve_unanswered: ({ p_id, p_status, p_note }) => {
      requireRole("owner", "manager", "supervisor");
      if (!["open", "ignored"].includes(p_status)) throw new Error("VALIDATION: status");
      const u = byId("unanswered_questions", p_id); if (!u || u.organization_id !== me()!.organization_id) throw new Error("NOT_FOUND");
      if (u.branch_id) requireBranch(u.branch_id);
      const before = u.status;
      Object.assign(u, { status: p_status, resolved_by: p_status === "open" ? null : staffId(), resolved_at: p_status === "open" ? null : nowISO(), resolve_note: p_note ?? null });
      audit(u.branch_id, "unanswered." + p_status, "unanswered_question", u.id, { before, after: p_status, reason: p_note ?? null });
      emit("unanswered_questions"); return { ok: true };
    },
    // service-role hooks (the demo's invoke() calls them directly, as the edge function would)
    fn_record_unanswered: ({ p_branch, p_question, p_conversation }) => {
      const b = byId("branches", p_branch); if (!b) return { ok: false, error: "BRANCH_NOT_FOUND" };
      const masked = String(p_question ?? "").replace(/\d{4,}/g, "#").slice(0, 300);
      const norm = normalizeArabic(masked).slice(0, 200); if (norm.length < 3) return { ok: false, error: "TOO_SHORT" };
      let u = T("unanswered_questions").find((x) => (x.branch_id ?? DEMO_ZERO_BRANCH) === (p_branch ?? DEMO_ZERO_BRANCH) && x.normalized === norm);
      if (u) Object.assign(u, { asked_count: u.asked_count + 1, last_asked_at: nowISO(), last_conversation_id: p_conversation ?? null, status: u.status === "answered" ? "answered" : "open" });
      else { u = { id: uid(), organization_id: b.organization_id, branch_id: p_branch, question: masked, normalized: norm, asked_count: 1, first_asked_at: nowISO(), last_asked_at: nowISO(), status: "open", knowledge_entry_id: null, last_conversation_id: p_conversation ?? null, resolved_by: null, resolved_at: null, resolve_note: null }; T("unanswered_questions").unshift(u); }
      emit("unanswered_questions"); return { ok: true, id: u.id };
    },
    fn_knowledge_usage_bump: ({ p_entry }) => { const k = byId("knowledge_entries", p_entry); if (k) { k.used_count++; k.last_used_at = nowISO(); emit("knowledge_entries"); } return null; },
  };
}
