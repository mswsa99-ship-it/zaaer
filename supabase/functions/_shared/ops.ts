/**
 * Staff operations assistant ("copilot") — shared logic.
 *
 *  - READ tools call branch-scoped SQL functions AS THE STAFF USER (RLS + role checks apply).
 *  - The only WRITE tool is `propose_action`, which records a proposal that a human must
 *    confirm in the UI; confirmation runs the normal RPCs under that person's role.
 *  - Deterministic replies (no provider) and the daily briefing are built from the same
 *    context, so the assistant is useful with zero AI credentials.
 *  - Output is PII-redacted; the context never contains access codes or document numbers.
 */
import type { ToolDeclaration } from "./llm.ts";
import { redactPII, normalizeDigits } from "./guardrails.ts";

export interface OpsDb { rpc(fn: string, args?: Record<string, unknown>): any } // deno-lint-ignore no-explicit-any

export interface OpsContext {
  db: OpsDb;             // user-scoped client (Authorization: Bearer <staff jwt>)
  branchId: string;
  conversationId: string;
  today: string;         // YYYY-MM-DD in branch timezone
}

export const OPS_ACTIONS = ["create_task","complete_task","set_cleanliness","amend_stay","switch_room","cancel_reservation","no_show","create_receipt","create_deposit","add_service","create_invoice","assign_task"] as const;
export type OpsAction = (typeof OPS_ACTIONS)[number];

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

/** Every argument any proposable action takes (validateOpsArgs keeps only primitives; the RPC behind each action
 *  validates its own). Listed explicitly: model APIs reject an OBJECT schema without properties. */
const S = (description: string) => ({ type: "string", description });
const OPS_ACTION_ARG_PROPERTIES: Record<string, unknown> = {
  reservation_id: S("معرّف الحجز (uuid)"), room_id: S("معرّف الوحدة (uuid)"), facility_id: S("معرّف المرفق (uuid)"),
  task_id: S("معرّف المهمة (uuid)"), task_type_id: S("معرّف نوع المهمة (uuid)"), assignee_id: S("معرّف الموظف المسند إليه (uuid)"),
  service_id: S("معرّف الخدمة (uuid)"), priority: S("أولوية المهمة"), description: S("وصف المهمة"), note: S("ملاحظة"),
  state: S("clean أو dirty"), reason: S("سبب الإجراء"), new_check_out: S("تاريخ المغادرة الجديد YYYY-MM-DD"),
  pricing_mode: S("keep_rate أو reprice"), effective: S("تاريخ سريان التبديل YYYY-MM-DD"), method: S("طريقة الدفع: cash أو pos (شبكة) أو bank_transfer أو ota_deferred (آجل عبر المنصة)"),
  reference: S("رقم العملية — إلزامي للشبكة والتحويل البنكي"), amount_halalas: { type: "integer", description: "المبلغ بالهللات (موجب)" },
  quantity: { type: "integer", description: "الكمية" },
};

export const OPS_TOOL_DECLARATIONS: ToolDeclaration[] = [
  { name: "get_operations_context", description: "الصورة التشغيلية الكاملة لليوم: ملخص الوحدات والإشغال، الوصول والمغادرة، المتأخرون، الأرصدة، التأمينات، الوحدات التي تحتاج انتباهًا، المهام المفتوحة، الموظفون. استخدمها أولًا لأي سؤال تشغيلي.",
    parameters: { type: "object", properties: { date: { type: "string", description: "YYYY-MM-DD (افتراضي: اليوم)" } } } },
  { name: "find_reservation", description: "البحث عن حجز برقمه الداخلي أو الخارجي أو اسم الضيف أو رقم الوحدة. يعيد الحالة والتواريخ والأرصدة ومعرّف الحجز.",
    parameters: { type: "object", properties: { query: { type: "string" } }, required: ["query"] } },
  { name: "get_reservation_finance", description: "الملخص المالي المشتق لحجز: الرسوم، المقبوض، المسترد، المتبقي، رصيد التأمين.",
    parameters: { type: "object", properties: { reservation_id: { type: "string" } }, required: ["reservation_id"] } },
  { name: "list_available_rooms", description: "الوحدات المتاحة فعليًا لفترة [من، إلى) ونوع اختياري، مع حالة النظافة.",
    parameters: { type: "object", properties: { from: { type: "string" }, to: { type: "string" }, category_id: { type: "string" }, exclude_reservation_id: { type: "string" } }, required: ["from", "to"] } },
  { name: "list_units_board", description: "لوحة الوحدات: لكل وحدة الحالة والنظافة والإقامة الحالية والوصول القادم والمهام المفتوحة.",
    parameters: { type: "object", properties: {} } },
  { name: "propose_action", description: "يقترح إجراءً تشغيليًا يتطلب تأكيد الموظف قبل التنفيذ. لا ينفذ شيئًا بنفسه. الإجراءات: create_task{room_id|facility_id,task_type_id,priority,assignee_id,description}, complete_task{task_id,note}, assign_task{task_id,assignee_id}, set_cleanliness{room_id,state:clean|dirty,reason}, amend_stay{reservation_id,new_check_out,pricing_mode:keep_rate|reprice,reason}, switch_room{reservation_id,room_id,effective,reason}, cancel_reservation{reservation_id,reason}, no_show{reservation_id,reason}, create_receipt{reservation_id,amount_halalas,method:cash|pos|bank_transfer|ota_deferred,reference}, create_deposit{reservation_id,amount_halalas,method:cash|pos|bank_transfer,reference} (رقم العملية إلزامي للشبكة والتحويل؛ يُقيَّد السند في الصندوق أو الحساب الافتراضي للفرع), add_service{reservation_id,service_id,quantity}, create_invoice{reservation_id}.",
    parameters: { type: "object", properties: { action: { type: "string", enum: [...OPS_ACTIONS] }, args: { type: "object", description: "وسائط الإجراء؛ اكتب منها ما يخص الإجراء المختار فقط", properties: OPS_ACTION_ARG_PROPERTIES }, summary: { type: "string", description: "وصف عربي قصير لما سيحدث وأثره" } }, required: ["action", "args", "summary"] } },
];

export function isOpsTool(name: string): boolean { return OPS_TOOL_DECLARATIONS.some((t) => t.name === name); }

export function validateOpsArgs(name: string, args: Record<string, unknown>): Record<string, unknown> {
  const a = args ?? {};
  const str = (k: string, re?: RegExp) => { const v = a[k]; if (v == null) return undefined; if (typeof v !== "string" || (re && !re.test(v))) throw new Error(`INVALID_ARG: ${k}`); return v; };
  switch (name) {
    case "get_operations_context": return { date: str("date", DATE_RE) };
    case "find_reservation": { const q = str("query"); if (!q || q.length < 2 || q.length > 60) throw new Error("INVALID_ARG: query"); return { query: q }; }
    case "get_reservation_finance": return { reservation_id: str("reservation_id", UUID_RE) };
    case "list_available_rooms": return { from: str("from", DATE_RE), to: str("to", DATE_RE), category_id: str("category_id", UUID_RE), exclude_reservation_id: str("exclude_reservation_id", UUID_RE) };
    case "list_units_board": return {};
    case "propose_action": {
      const action = str("action");
      if (!action || !(OPS_ACTIONS as readonly string[]).includes(action)) throw new Error("INVALID_ARG: action");
      const summary = str("summary"); if (!summary || summary.length < 5) throw new Error("INVALID_ARG: summary");
      const raw = (a.args ?? {}) as Record<string, unknown>;
      const out: Record<string, unknown> = {};
      for (const [k, v] of Object.entries(raw)) {
        if (typeof v === "string" && v.length <= 300) out[k] = v;
        else if (typeof v === "number" && Number.isFinite(v)) out[k] = Math.round(v);
        else if (typeof v === "boolean") out[k] = v;
      }
      if ("amount_halalas" in out && (typeof out.amount_halalas !== "number" || (out.amount_halalas as number) <= 0)) throw new Error("INVALID_ARG: amount_halalas");
      return { action, args: out, summary: redactPII(summary).text.slice(0, 400) };
    }
    default: throw new Error("UNKNOWN_TOOL");
  }
}

export async function executeOpsTool(name: string, args: Record<string, unknown>, ctx: OpsContext): Promise<unknown> {
  const { db } = ctx;
  const call = async (fn: string, a: Record<string, unknown>) => { const { data, error } = await db.rpc(fn, a); if (error) throw new Error(error.message); return data; };
  switch (name) {
    case "get_operations_context": return await call("fn_ai_ops_context", { p_branch: ctx.branchId, p_date: args.date ?? ctx.today });
    case "find_reservation": return await call("fn_ai_ops_find_reservation", { p_branch: ctx.branchId, p_query: args.query });
    case "get_reservation_finance": return await call("fn_reservation_finance", { p_reservation: args.reservation_id });
    case "list_available_rooms": return await call("fn_available_rooms", { p_branch: ctx.branchId, p_from: args.from, p_to: args.to, p_category: args.category_id ?? null, p_exclude_reservation: args.exclude_reservation_id ?? null });
    case "list_units_board": return await call("fn_ops_units_board", { p_branch: ctx.branchId });
    case "propose_action": return await call("fn_ai_ops_propose", { p_conversation: ctx.conversationId, p_action: args.action, p_args: args.args, p_summary: args.summary });
    default: throw new Error("UNKNOWN_TOOL");
  }
}

/** Branch-local calendar day (moved to dates.ts, shared with ai-reception). */
export { localDay } from "./dates.ts";

/** Model-supplied arguments are logged for audit, but never with guest names / references in clear text. */
const SAFE_ARG_KEYS = new Set(["action", "state", "priority", "pricing_mode", "method", "kind", "date", "from", "to", "effective", "new_check_out", "quantity", "amount_halalas"]);
export function redactArgs(args: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(args ?? {})) {
    if (typeof v === "string") {
      const structural = /^[0-9a-f-]{36}$/i.test(v) || /^\d{4}-\d{2}-\d{2}$/.test(v) || (SAFE_ARG_KEYS.has(k) && v.length <= 24);
      out[k] = structural ? v : `${redactPII(v).text.slice(0, 1)}…(${v.length})`;   // free text (names, references, notes) is never stored in clear
    } else if (v && typeof v === "object") out[k] = redactArgs(v as Record<string, unknown>);
    else out[k] = v;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Output gate for staff replies: redact PII, strip secrets/provider talk, cap length
// ---------------------------------------------------------------------------
export function gateOpsOutput(raw: string, maxChars = 1800): { ok: boolean; text: string; violations: string[] } {
  const violations: string[] = [];
  let text = normalizeDigits((raw ?? "").toString()).replace(/```[\s\S]*?```/g, "").replace(/\*\*/g, "").trim();
  if (!text) return { ok: false, text: "", violations: ["empty"] };
  const r = redactPII(text); if (r.found.length) { violations.push(...r.found); text = r.text; }
  if (/(api[_ ]?key|secret|token)\s*[:=]/i.test(text)) return { ok: false, text: "", violations: ["secret_leak"] };
  if (/(system prompt|تعليمات النظام|البرومبت)/i.test(text)) return { ok: false, text: "", violations: ["prompt_echo"] };
  text = text.replace(/\b(openai|google ai|gemini|anthropic|claude|chatgpt)\b/gi, "مساعد العمليات");
  if (text.length > maxChars) { text = text.slice(0, maxChars).replace(/\s\S*$/, "") + "…"; violations.push("truncated"); }
  return { ok: true, text, violations };
}

// ---------------------------------------------------------------------------
// System prompt
// ---------------------------------------------------------------------------
export function buildOpsSystemPrompt(o: { propertyName: string; branchName: string; staffName: string; role: string; today: string; extra?: string | null }): string {
  return [
    `أنت «مساعد العمليات» في ${o.propertyName} — فرع ${o.branchName}. تتحدث مع ${o.staffName} (الدور: ${o.role}). التاريخ اليوم ${o.today}.`,
    "مهمتك: مساعدة فريق التشغيل على فهم حالة اليوم واتخاذ القرار بسرعة: الوصول والمغادرة، الوحدات والنظافة والجاهزية، المهام، الأرصدة والتأمينات، التمديد والتبديل والإلغاء.",
    "قواعد غير قابلة للتجاوز:",
    "1) لا تختلق أي رقم أو حالة. كل حقيقة تأتي من أداة. إن لم تجد البيانات قل ذلك.",
    "2) لا تنفذ أي تغيير بنفسك. أي إجراء تشغيلي يتم عبر propose_action ثم يؤكده الموظف من الواجهة. اشرح أثر الإجراء قبل اقتراحه (مثال: التمديد يغير المغادرة والسعر؛ الإلغاء لا يسترد المال تلقائيًا؛ إتمام التنظيف لا يحرر وحدة مؤجرة).",
    "3) لا تطلب ولا تذكر رموز الدخول أو أرقام الوثائق أو أرقام الجوال الكاملة أو أي سر.",
    "4) المال بالريال في النص (الهلالة ÷ 100). فرّق دائمًا بين المتبقي على الإقامة ورصيد التأمين.",
    "5) الحالات: النشاط والنظافة والإشغال وجاهزية الدخول مستقلة؛ «نظيفة» لا تعني «خالية» ولا «جاهزة للدخول».",
    "6) أجب بالعربية، بإيجاز وبترتيب الأولوية (الأعلى خطورة أولًا). استخدم قوائم قصيرة عند تعدد العناصر. بدون عناوين Markdown.",
    "7) إن كان السؤال خارج تشغيل المنشأة، اعتذر باختصار وأعد التوجيه.",
    o.extra ? `تعليمات إضافية من الإدارة: ${o.extra}` : "",
  ].filter(Boolean).join("\n");
}

// ---------------------------------------------------------------------------
// Deterministic briefing + fallback (no provider required)
// ---------------------------------------------------------------------------
const sar = (h: unknown) => (Number(h ?? 0) / 100).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + " ر.س";
const n = (v: unknown) => Number(v ?? 0);

export interface BriefingItem { level: "critical" | "warning" | "info"; text: string; link?: string }

export function buildBriefing(ctx: Record<string, any>): { headline: string; items: BriefingItem[]; text: string } { // deno-lint-ignore no-explicit-any
  const s = ctx?.summary ?? {}; const u = s.units ?? {}; const ar = s.arrivals ?? {}; const dp = s.departures ?? {}; const hk = s.housekeeping ?? {}; const f = s.finance ?? {};
  const items: BriefingItem[] = [];
  const overstays = (ctx.overstays ?? []) as any[]; // deno-lint-ignore no-explicit-any
  const overdue = (ctx.overdue_arrivals ?? []) as any[]; // deno-lint-ignore no-explicit-any
  if (overstays.length) items.push({ level: "critical", text: `${overstays.length} إقامة تجاوزت موعد المغادرة: ${overstays.slice(0, 5).map((o) => `${o.ref} (وحدة ${o.room ?? "—"}، ${o.days_over} يوم)`).join("، ")}`, link: "/staff/reservations" });
  if (overdue.length) items.push({ level: "warning", text: `${overdue.length} وصول متأخر لم يُسجَّل ولم يُعلَن عدم حضور: ${overdue.slice(0, 5).map((o) => o.ref).join("، ")}`, link: "/staff/arrivals" });
  if (n(ar.expected)) items.push({ level: "info", text: `الوصول اليوم: ${ar.expected} متوقع، ${ar.arrived} وصل، ${ar.pending_identity} بانتظار مطابقة الهوية، ${ar.unpaid} عليه متبقٍ`, link: "/staff/arrivals" });
  if (n(dp.expected)) items.push({ level: n(dp.with_balance) ? "warning" : "info", text: `المغادرة اليوم: ${dp.expected} متوقعة، ${dp.done} تمت، ${dp.with_balance} عليها رصيد متبقٍ`, link: "/staff/reservations" });
  const unitsAttn = (ctx.units_needing_attention ?? []) as any[]; // deno-lint-ignore no-explicit-any
  const arrivingDirty = unitsAttn.filter((x) => x.next_arrival && x.next_arrival <= s.date);
  if (arrivingDirty.length) items.push({ level: "critical", text: `${arrivingDirty.length} وحدة عليها وصول اليوم وليست جاهزة: ${arrivingDirty.map((x) => x.room).join("، ")}`, link: "/staff/housekeeping" });
  if (n(u.dirty)) items.push({ level: "warning", text: `${u.dirty} وحدة تحتاج تنظيفًا، ${hk.unassigned} مهمة غير مسندة، ${hk.in_progress} قيد التنفيذ، ${hk.completed_today} أُنجزت اليوم`, link: "/staff/housekeeping" });
  if (n(u.maintenance)) items.push({ level: "warning", text: `${u.maintenance} وحدة في الصيانة`, link: "/staff/tickets" });
  if (n(f.outstanding_in_house)) items.push({ level: "warning", text: `متبقٍ على النزلاء المقيمين: ${sar(f.outstanding_in_house)}`, link: "/staff/payments" });
  // 0033: a stay's deposit goes back after the departure's inspection; «متابعة الإقامات» lists the departures not closed
  if (n(f.deposit_to_settle_after_checkout)) items.push({ level: "warning", text: `تأمينات لم تُسوَّ بعد المغادرة: ${sar(f.deposit_to_settle_after_checkout)} — تحتاج فحص المغادرة ثم ردًا أو رسم ضرر بسبب`, link: "/staff/followups" });
  if (n(s.tickets_open)) items.push({ level: "warning", text: `${s.tickets_open} تذكرة مفتوحة من المساعد الذكي تحتاج مشرفًا`, link: "/staff/tickets" });
  items.push({ level: "info", text: `الإشغال ${s.occupancy_pct ?? 0}% — ${u.occupied} مؤجرة من ${u.active} فعالة، ${u.ready} جاهزة للدخول، ${u.reserved} محجوزة، ${u.out_of_service} خارج الخدمة. تحصيل اليوم ${sar(f.received_today)}، تأمينات محتجزة ${sar(f.deposits_held)}.` });
  const crit = items.filter((i) => i.level === "critical").length; const warn = items.filter((i) => i.level === "warning").length;
  const headline = crit ? `${crit} أمر عاجل و${warn} تنبيه يحتاج انتباهك اليوم` : warn ? `لا أمور عاجلة — ${warn} تنبيه للمتابعة` : "اليوم هادئ — لا تنبيهات تشغيلية";
  const text = [headline, ...items.map((i) => (i.level === "critical" ? "🔴 " : i.level === "warning" ? "🟠 " : "🔵 ") + i.text)].join("\n");
  return { headline, items, text };
}

/** Keyword-driven fallback: answers the most common ops questions from the context without a model. */
export function fallbackOpsReply(message: string, ctx: Record<string, any>): string { // deno-lint-ignore no-explicit-any
  const m = message.toLowerCase();
  const list = (rows: any[], f: (r: any) => string, empty: string) => rows.length ? rows.slice(0, 12).map((r, i) => `${i + 1}. ${f(r)}`).join("\n") : empty; // deno-lint-ignore no-explicit-any
  if (/(وصول|قادم|يوصل|arrival)/.test(m)) return "وصول اليوم:\n" + list(ctx.arrivals ?? [], (r) => `${r.ref} — ${r.guest ?? "—"} — ${r.room ? "وحدة " + r.room : r.category ?? ""} — ${r.status === "checked_in" ? "وصل" : "لم يصل"} — هوية: ${r.identity_status} — متبقٍ ${sar(r.balance_due)}`, "لا يوجد وصول متوقع اليوم.");
  if (/(مغادر|يغادر|departure|checkout)/.test(m)) return "مغادرة اليوم:\n" + list(ctx.departures ?? [], (r) => `${r.ref} — ${r.guest ?? "—"} — وحدة ${r.room ?? "—"} — متبقٍ ${sar(r.balance_due)} — تأمين ${sar(r.deposit_balance)}`, "لا توجد مغادرات متوقعة اليوم.") + ((ctx.overstays ?? []).length ? "\n\nتجاوزوا موعد المغادرة:\n" + list(ctx.overstays, (r) => `${r.ref} — وحدة ${r.room ?? "—"} — ${r.days_over} يوم`, "") : "");
  if (/(نظاف|متسخ|تنظيف|dirty|clean|مهم|task)/.test(m)) return "الوحدات التي تحتاج انتباهًا:\n" + list(ctx.units_needing_attention ?? [], (r) => `وحدة ${r.room} — ${r.cleanliness === "clean" ? "نظيفة" : r.cleanliness === "dirty" ? "متسخة" : "قيد التنظيف"} — حالة ${r.status} — مهام مفتوحة ${r.open_tasks}${r.next_arrival ? " — وصول قادم " + r.next_arrival : ""}`, "كل الوحدات نظيفة.") + "\n\nالمهام المفتوحة:\n" + list(ctx.open_tasks ?? [], (t) => `${t.target} — ${t.type} — ${t.priority} — ${t.assignee ?? "غير مسندة"}`, "لا مهام مفتوحة.");
  if (/(متبقي|رصيد|مديون|دفع|تأمين|balance|deposit|مال)/.test(m)) return "المقيمون وعليهم متبقٍ:\n" + list(ctx.in_house_with_balance ?? [], (r) => `${r.ref} — وحدة ${r.room ?? "—"} — ${sar(r.balance_due)}`, "لا مديونيات على المقيمين.") + "\n\nتأمينات بعد المغادرة لم تُسوَّ:\n" + list(ctx.checked_out_with_deposit ?? [], (r) => `${r.ref} — ${sar(r.deposit_balance)}`, "لا تأمينات معلقة.");
  if (/(متاح|فاضي|خالي|available|توفر)/.test(m)) { const u = ctx.summary?.units ?? {}; return `الوحدات: ${u.ready} جاهزة للدخول، ${u.reserved} محجوزة، ${u.occupied} مؤجرة، ${u.dirty} تحتاج تنظيفًا، ${u.maintenance} صيانة. للتحقق من توفر فترة محددة استخدم شاشة «حجز جديد» أو اسأل بصيغة: المتاح من YYYY-MM-DD إلى YYYY-MM-DD.`; }
  return buildBriefing(ctx).text + "\n\n(المحرك الذكي غير مفعّل حاليًا؛ هذه إجابة مبنية مباشرة على بيانات النظام. يمكنك السؤال عن: الوصول، المغادرة، النظافة والمهام، الأرصدة والتأمينات.)";
}
