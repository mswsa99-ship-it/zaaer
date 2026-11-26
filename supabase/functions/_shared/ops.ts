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
import { routeMapText, type PageAccess } from "./route_map.ts";
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

/**
 * READ-ONLY (the owner, 25 Nov 2026 14:15: the AI knows all the routes and files, "لا ينفذ ولكن مطلع"). The staff assistant
 * has NO write path: propose_action is dormant source, not offered to the model, refused by the validator and the executor.
 * Restoring it is a code change plus review, never a setting.
 */
export const OPS_READ_ONLY = true as const;
const ALL_OPS_TOOL_DECLARATIONS_DORMANT: ToolDeclaration[] = [
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
  { name: "get_finance_report", description: "تقرير مالي مشتق لفترة [من، إلى]: المقبوض والمسترد والتأمينات والمصروفات وطرق الدفع. قراءة فقط، وتحكمه صلاحيات المستخدم المالية.",
    parameters: { type: "object", properties: { from: { type: "string" }, to: { type: "string" } }, required: ["from", "to"] } },
  { name: "list_vouchers", description: "سجل السندات (قبض وصرف) لفترة [من، إلى] مع الأرقام والمبالغ والطرق. قراءة فقط، وتحكمه صلاحيات المستخدم المالية.",
    parameters: { type: "object", properties: { from: { type: "string" }, to: { type: "string" }, kind: { type: "string" } }, required: ["from", "to"] } },
  { name: "get_stay_followups", description: "متابعات الإقامات في الفرع: المتأخرون عن السداد، والمغادرون بإجراءات مفتوحة، والمتأخرون عن وقت المغادرة. قراءة فقط، وتحكمه صلاحيات المستخدم.",
    parameters: { type: "object", properties: {} } },
  { name: "get_day_summary", description: "ملخص يوم واحد: ما قبضه كل موظف وما ردّه حسب الطريقة. قراءة فقط، وتحكمه صلاحيات المستخدم (المشرف يرى حركته فقط).",
    parameters: { type: "object", properties: { date: { type: "string" } }, required: ["date"] } },
  { name: "propose_action", description: "يقترح إجراءً تشغيليًا يتطلب تأكيد الموظف قبل التنفيذ. لا ينفذ شيئًا بنفسه. الإجراءات: create_task{room_id|facility_id,task_type_id,priority,assignee_id,description}, complete_task{task_id,note}, assign_task{task_id,assignee_id}, set_cleanliness{room_id,state:clean|dirty,reason}, amend_stay{reservation_id,new_check_out,pricing_mode:keep_rate|reprice,reason}, switch_room{reservation_id,room_id,effective,reason}, cancel_reservation{reservation_id,reason}, no_show{reservation_id,reason}, create_receipt{reservation_id,amount_halalas,method:cash|pos|bank_transfer|ota_deferred,reference}, create_deposit{reservation_id,amount_halalas,method:cash|pos|bank_transfer,reference} (رقم العملية إلزامي للشبكة والتحويل؛ يُقيَّد السند في الصندوق أو الحساب الافتراضي للفرع), add_service{reservation_id,service_id,quantity}, create_invoice{reservation_id}.",
    parameters: { type: "object", properties: { action: { type: "string", enum: [...OPS_ACTIONS] }, args: { type: "object", description: "وسائط الإجراء؛ اكتب منها ما يخص الإجراء المختار فقط", properties: OPS_ACTION_ARG_PROPERTIES }, summary: { type: "string", description: "وصف عربي قصير لما سيحدث وأثره" } }, required: ["action", "args", "summary"] } },
];

export const OPS_TOOL_DECLARATIONS: ToolDeclaration[] = ALL_OPS_TOOL_DECLARATIONS_DORMANT.filter((t) => !(OPS_READ_ONLY && t.name === "propose_action"));

export function isOpsTool(name: string): boolean { return OPS_TOOL_DECLARATIONS.some((t) => t.name === name); }

// ---------------------------------------------------------------------------
// 6.12 (U5 سرعة المساعد): a simple question goes to the fastest approved model
// ---------------------------------------------------------------------------
/** Imperative words that make a message an action request, never a "simple question". Misreading one toward
 *  "simple" would route a write-intent to the weakest model, so the list is strict; a miss only keeps the
 *  question on the regular (stronger) chain, which is the safe direction. */
const OPS_ACTION_INTENT = /(أنشئ|انشئ|أضف|اضف|نفذ|نفّذ|مدد|مدّد|بدل|بدّل|ألغ|الغِ|الغي|سجل|سجّل|غيّر|اقبض|أكمل|اكمل|أصدر|اصدر|احجز|سوّي|سوي|أسند|اسند|أرسل|ارسل|سند|قبض|فاتور|تأمين|تمديد|تبديل|إيداع|ايداع|تحويل|خصم|مهمة|مهمّة)/;
const SIMPLE_QUESTION_MAX_CHARS = 120;

/** A short status question with no action intent (the copilot's own suggestions are the model). */
export function isSimpleOpsQuestion(message: string): boolean {
  const m = (message ?? "").trim();
  if (!m || m.length > SIMPLE_QUESTION_MAX_CHARS) return false;
  return !OPS_ACTION_INTENT.test(m);
}

/**
 * The model chain for one message: the configured model then the owner's fallbacks (llm.ts order). A simple
 * question starts from the fastest approved model — the flash-lite in the chain — with the whole chain still
 * behind it, so a slow/unavailable fast model costs one attempt, not the answer. Nothing is routed away when
 * the chain holds no flash-lite.
 */
export function opsModelOrder(message: string, configured: string, fallbacks: string[]): string[] {
  const chain = [...new Set([configured, ...(Array.isArray(fallbacks) ? fallbacks : [])].map((m) => String(m ?? "").trim()).filter(Boolean))];
  if (!isSimpleOpsQuestion(message)) return chain;
  const fast = chain.find((m) => /flash-lite/i.test(m));
  if (!fast || fast === chain[0]) return chain;
  return [fast, ...chain.filter((m) => m !== fast)];
}

export function validateOpsArgs(name: string, args: Record<string, unknown>): Record<string, unknown> {
  const a = args ?? {};
  const str = (k: string, re?: RegExp) => { const v = a[k]; if (v == null) return undefined; if (typeof v !== "string" || (re && !re.test(v))) throw new Error(`INVALID_ARG: ${k}`); return v; };
  switch (name) {
    case "get_operations_context": return { date: str("date", DATE_RE) };
    case "find_reservation": { const q = str("query"); if (!q || q.length < 2 || q.length > 60) throw new Error("INVALID_ARG: query"); return { query: q }; }
    case "get_reservation_finance": return { reservation_id: str("reservation_id", UUID_RE) };
    case "list_available_rooms": return { from: str("from", DATE_RE), to: str("to", DATE_RE), category_id: str("category_id", UUID_RE), exclude_reservation_id: str("exclude_reservation_id", UUID_RE) };
    case "list_units_board": return {};
    case "get_stay_followups": return {};
    case "get_day_summary": { const d = str("date", DATE_RE); if (!d) throw new Error("INVALID_ARG: date"); return { date: d }; }
    case "get_finance_report": { const f = str("from", DATE_RE), t = str("to", DATE_RE); if (!f || !t) throw new Error("INVALID_ARG: period"); return { from: f, to: t }; }
    case "list_vouchers": { const f = str("from", DATE_RE), t = str("to", DATE_RE); if (!f || !t) throw new Error("INVALID_ARG: period"); return { from: f, to: t, kind: str("kind", /^[a-z_]{1,30}$/) }; }
    case "propose_action": {
      if (OPS_READ_ONLY) throw new Error("READ_ONLY: the operations assistant cannot propose or execute actions");
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
    case "get_stay_followups": return await call("fn_stay_followups", { p_branch: ctx.branchId });
    case "get_day_summary": return await call("fn_staff_day_summary", { p_branch: ctx.branchId, p_date: args.date });
    case "get_finance_report": return await call("fn_reports_finance", { p_branch: ctx.branchId, p_from: args.from, p_to: args.to, p_filters: {} });
    case "list_vouchers": return await call("fn_voucher_list", { p: { branch_id: ctx.branchId, from: args.from, to: args.to, ...(args.kind ? { kind: args.kind } : {}), limit: 50 } });
    case "propose_action": if (OPS_READ_ONLY) throw new Error("READ_ONLY: the operations assistant cannot propose or execute actions"); return await call("fn_ai_ops_propose", { p_conversation: ctx.conversationId, p_action: args.action, p_args: args.args, p_summary: args.summary });
    default: throw new Error("UNKNOWN_TOOL");
  }
}

/** Branch-local calendar day (moved to dates.ts, shared with ai-reception). */
import { localDay } from "./dates.ts";
export { localDay };

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
/** The pages this role may open by default (from the app's own page table). Guidance for "where do I do X", never an authority: the server decides. */
function routeBlock(role: string, access?: PageAccess | null): string {
  const t = routeMapText(role, access);
  return t ? "صفحات التطبيق المتاحة لهذا الموظف (للإرشاد إلى مكان الإجراء فقط؛ الخادم هو من يقرر الصلاحية الفعلية، ولا تذكر صفحة غير مدرجة هنا):\n" + t : "";
}
export function buildOpsSystemPrompt(o: { propertyName: string; branchName: string; staffName: string; role: string; today: string; extra?: string | null; access?: PageAccess | null }): string {
  return [
    `أنت «مساعد العمليات» في ${o.propertyName} — فرع ${o.branchName}. تتحدث مع ${o.staffName} (الدور: ${o.role}). التاريخ اليوم ${o.today}.`,
    "مهمتك: مساعدة فريق التشغيل على فهم حالة اليوم واتخاذ القرار بسرعة: الوصول والمغادرة، الوحدات والنظافة والجاهزية، المهام، الأرصدة والتأمينات، التمديد والتبديل والإلغاء.",
    "قواعد غير قابلة للتجاوز:",
    "1) لا تختلق أي رقم أو حالة. كل حقيقة تأتي من أداة. إن لم تجد البيانات قل ذلك.",
    "2) أنت للقراءة والاطلاع فقط: لا تنفذ ولا تقترح تنفيذ أي إجراء، ولا يوجد لديك أي أداة كتابة. إن طلب الموظف تغييرًا فاشرح له أين يجريه بنفسه في التطبيق وما أثره (مثال: التمديد يغير المغادرة والسعر؛ الإلغاء لا يسترد المال تلقائيًا؛ إتمام التنظيف لا يحرر وحدة مؤجرة).",
    "3) لا تطلب ولا تذكر رموز الدخول أو أرقام الوثائق أو أرقام الجوال الكاملة أو أي سر.",
    "4) المال بالريال في النص (الهلالة ÷ 100). فرّق دائمًا بين المتبقي على الإقامة ورصيد التأمين.",
    "5) الحالات: النشاط والنظافة والإشغال وجاهزية الدخول مستقلة؛ «نظيفة» لا تعني «خالية» ولا «جاهزة للدخول».",
    "6) أجب بالعربية، بإيجاز وبترتيب الأولوية (الأعلى خطورة أولًا). استخدم قوائم قصيرة عند تعدد العناصر. بدون عناوين Markdown.",
    "7) إن كان السؤال خارج تشغيل المنشأة، اعتذر باختصار وأعد التوجيه.",
    routeBlock(o.role, o.access),
    o.extra ? `تعليمات إضافية من الإدارة: ${o.extra}` : "",
  ].filter(Boolean).join("\n");
}

// ---------------------------------------------------------------------------
// Deterministic briefing + fallback (no provider required)
// ---------------------------------------------------------------------------
const sar = (h: unknown) => (Number(h ?? 0) / 100).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + " ر.س";
const n = (v: unknown) => Number(v ?? 0);
/** COPY-11: an Arabic count by the CLDR rules (1, 2, 3–10, 11–99, 100…), as arabicCount does in the app. */
function ar(k: number, [one, two, few, many]: [string, string, string, string]): string {
  if (k === 1) return one;
  if (k === 2) return two;
  const m = Math.abs(k) % 100;
  if (m >= 3 && m <= 10) return `${k} ${few}`;
  if (m >= 11 && m <= 99) return `${k} ${many}`;
  return `${k} ${many.replace(/ً?ا$|ً$/, "")}`;
}
const DAYS: [string, string, string, string] = ["يوم واحد", "يومان", "أيام", "يومًا"];
const UNITS: [string, string, string, string] = ["وحدة واحدة", "وحدتان", "وحدات", "وحدة"];

export interface BriefingItem { level: "critical" | "warning" | "info"; text: string; link?: string; area?: "coordination"; why?: string; horizon?: "now" | "upcoming" | "info" | "unavailable"; key?: string }

export function buildBriefing(ctx: Record<string, any>, nowMs: number = Date.now(), tz?: string | null): { headline: string; items: BriefingItem[]; text: string } { // deno-lint-ignore no-explicit-any
  const s = ctx?.summary ?? {}; const u = s.units ?? {}; const av = s.arrivals ?? {}; const dp = s.departures ?? {}; const hk = s.housekeeping ?? {}; const f = s.finance ?? {};
  const money = !!s.finance;   // PERM-08: a role without money gets no money sentence (not a false zero)
  const items: BriefingItem[] = [];
  const overstays = (ctx.overstays ?? []) as any[]; // deno-lint-ignore no-explicit-any
  const overdue = (ctx.overdue_arrivals ?? []) as any[]; // deno-lint-ignore no-explicit-any
  if (overstays.length) items.push({ level: "critical", horizon: "now", key: "overstay:" + overstays.map((o) => o.ref).sort().join(","), text: `${ar(overstays.length, ["إقامة واحدة تجاوزت", "إقامتان تجاوزتا", "إقامات تجاوزت", "إقامة تجاوزت"])} موعد المغادرة: ${overstays.slice(0, 5).map((o) => `${o.ref} (وحدة ${o.room ?? "—"}، ${ar(n(o.days_over), DAYS)})`).join("، ")}`, link: "/staff/reservations", why: "الدليل: إقامات حالتها «مقيم» وتاريخ مغادرتها قبل اليوم، من قائمة التجاوزات" });
  if (overdue.length) items.push({ level: "warning", horizon: "now", key: "overdue_arrival:" + overdue.map((o) => o.ref).sort().join(","), text: `وصول متأخر لم يُسجَّل ولم يُعلَن عدم حضوره (${overdue.length}): ${overdue.slice(0, 5).map((o) => o.ref).join("، ")}`, link: "/staff/arrivals", why: "الدليل: حجوزات مؤكدة وقت وصولها فات ولم تُسجَّل ولم يُعلَن عدم حضورها" });
  if (n(av.expected)) items.push({ level: "info", text: `الوصول اليوم: المتوقع ${av.expected}، وصل ${av.arrived}، بانتظار مطابقة الهوية ${av.pending_identity}${money ? `، عليهم متبقٍ ${av.unpaid}` : ""}`, link: "/staff/arrivals" });
  if (n(dp.expected)) items.push({ level: money && n(dp.with_balance) ? "warning" : "info", text: `المغادرة اليوم: المتوقع ${dp.expected}، تمت ${dp.done}${money ? `، عليها رصيد متبقٍ ${dp.with_balance}` : ""}`, horizon: "now", key: "departures_balance", why: "الدليل: مغادرات اليوم المتوقعة وعليها رصيد مفتوح، والموعد اليوم", link: "/staff/reservations" });
  const unitsAttn = (ctx.units_needing_attention ?? []) as any[]; // deno-lint-ignore no-explicit-any
  const arrivingDirty = unitsAttn.filter((x) => x.next_arrival && x.next_arrival <= s.date && x.status !== "maintenance");   // a unit in maintenance is the coordination alert below, not a second "not ready" line
  if (arrivingDirty.length) items.push({ level: "critical", horizon: "now", key: "arrival_not_ready:" + arrivingDirty.map((x) => x.room).sort().join(","), text: `${ar(arrivingDirty.length, ["وحدة واحدة عليها", "وحدتان عليهما", "وحدات عليها", "وحدة عليها"])} وصول اليوم وليست جاهزة: ${arrivingDirty.map((x) => x.room).join("، ")}`, link: "/staff/housekeeping", why: "الدليل: وحدات في قائمة الانتباه (غير نظيفة أو مهام مفتوحة) وفيها وصول اليوم" });
  // coordination: a read-only cross-check between the front desk and the units — an arrival today on a unit that is under maintenance
  const maintArrival = unitsAttn.filter((x) => x.status === "maintenance" && x.next_arrival && x.next_arrival <= s.date);
  if (maintArrival.length) items.push({ level: "critical", horizon: "now", key: "maint_arrival:" + maintArrival.map((x) => x.room).sort().join(","), area: "coordination", text: `وصول اليوم على وحدة في الصيانة: ${maintArrival.slice(0, 5).map((x) => "وحدة " + x.room).join("، ")} — يحتاج استقبالًا وصيانة قرارًا مشتركًا`, link: "/staff/tickets", why: "الدليل: حالة الوحدة «صيانة» ولها وصول مؤكد اليوم أو قبله، فلا يكفي قرار الاستقبال وحده" });
  // upcoming risk: a unit in maintenance with a LATER arrival. Not an alert today (no deadline yet), but listed with the date so the lead time is visible. The cut-off is the user's/ops' call, so none is invented here.
  const maintLater = unitsAttn.filter((x) => x.status === "maintenance" && x.next_arrival && x.next_arrival > s.date).sort((a, b) => String(a.next_arrival).localeCompare(String(b.next_arrival)));
  if (maintLater.length) items.push({ level: "info", horizon: "upcoming", key: "maint_later:" + maintLater.map((x) => x.room + "@" + x.next_arrival).join(","), area: "coordination", text: `قادم: ${maintLater.slice(0, 5).map((x) => `وحدة ${x.room} في الصيانة ووصولها ${x.next_arrival}`).join("، ")}`, why: "الدليل: حالة الوحدة «صيانة» ولها وصول مؤكد بعد اليوم؛ تُراجع مدة الإصلاح قبل ذلك الموعد", link: "/staff/tickets" });
  if (n(u.dirty)) items.push({ level: "info", why: "الدليل: عدد الوحدات غير النظيفة ومهام التنظيف؛ يصبح عاجلًا فقط إن كان على الوحدة وصول اليوم (بند منفصل)", horizon: "info", key: "dirty_units", text: `تحتاج تنظيفًا: ${ar(n(u.dirty), UNITS)} — مهام غير مسندة ${n(hk.unassigned)}، قيد التنفيذ ${n(hk.in_progress)}، أُنجزت اليوم ${n(hk.completed_today)}`, link: "/staff/housekeeping" });
  if (n(u.maintenance)) items.push({ level: "info", horizon: "info", key: "maintenance_units", text: `في الصيانة: ${ar(n(u.maintenance), UNITS)}`, link: "/staff/tickets" });
  if (n(f.outstanding_in_house)) items.push({ level: "info", horizon: "info", key: "in_house_balance", text: `متبقٍ على النزلاء المقيمين: ${sar(f.outstanding_in_house)}`, link: "/staff/payments" });
  // 0033: a stay's deposit goes back after the departure's inspection; «متابعة الإقامات» lists the departures not closed
  if (n(f.deposit_to_settle_after_checkout)) items.push({ level: "info", horizon: "info", key: "deposit_to_settle", text: `تأمينات لم تُسوَّ بعد المغادرة: ${sar(f.deposit_to_settle_after_checkout)} — تحتاج فحص المغادرة ثم ردًا أو رسم ضرر بسبب`, link: "/staff/followups" });
  if (n(s.tickets_open)) items.push({ level: "warning", horizon: "now", why: "الدليل: طلبات تحويل مفتوحة من المساعد لم يستلمها مشرف", key: "tickets_open", text: `طلبات تحويل لموظف مفتوحة من المساعد الذكي تحتاج مشرفًا: ${s.tickets_open}`, link: "/staff/tickets" });
  items.push({ level: "info", text: `الإشغال ${s.occupancy_pct ?? 0}% — مؤجرة ${n(u.occupied)} من ${n(u.active)} عاملة، جاهزة للتسليم ${n(u.ready)}، محجوزة ${n(u.reserved)}، خارج الخدمة ${n(u.out_of_service)}.${money ? ` تحصيل اليوم ${sar(f.received_today)}، تأمينات محتجزة ${sar(f.deposits_held)}.` : ""}` });
  // uncertainty: no summary means we could not read today's data. That is never "a quiet day".
  if (!ctx?.summary) items.push({ level: "warning", horizon: "unavailable", key: "no_summary", text: "تعذّر قراءة بيانات اليوم، فلا يمكن القول إن اليوم هادئ. أعد التحديث أو راجع الصفحات مباشرة", why: "الدليل: لم تصل بيانات الملخص" });
  // freshness, by the BRANCH day (not an hour count): the reading must have been taken on the briefing's day, and the briefing's day must be today there; a future stamp is not valid either. The reading time stays in the footer.
  const gen = Date.parse(String(ctx?.generated_at ?? ""));
  const genDay = Number.isFinite(gen) ? localDay(tz, new Date(gen)) : null;
  if (ctx?.summary && ((genDay && genDay !== ctx.summary.date) || ctx.summary.date !== localDay(tz, new Date(nowMs)) || (Number.isFinite(gen) && gen - nowMs > 5 * 60 * 1000))) items.push({ level: "info", horizon: "unavailable", key: "stale_reading", text: "هذه القراءة ليست لليوم الحالي في توقيت الفرع؛ حدّث الإحاطة قبل الاعتماد عليها", why: "الدليل: يوم القراءة أو يوم الإحاطة يختلف عن اليوم الحالي للفرع" });
  // scope unknown: a check whose input was not delivered is reported as unavailable, never as "nothing found"
  if (ctx?.summary && ctx.units_needing_attention === undefined) items.push({ level: "info", horizon: "unavailable", key: "units_unavailable", text: "فحص الوحدات المتأثرة بالوصول غير متاح الآن، فغياب التنبيه عنها لا يعني سلامتها", why: "الدليل: قائمة الوحدات لم تصل" });
  if (ctx?.summary && ctx.overstays === undefined) items.push({ level: "info", horizon: "unavailable", key: "overstays_unavailable", text: "فحص تجاوز موعد المغادرة غير متاح الآن", why: "الدليل: قائمة التجاوزات لم تصل" });
  const crit = items.filter((i) => i.level === "critical").length; const warn = items.filter((i) => i.level === "warning").length;
  const ALERTS: [string, string, string, string] = ["تنبيه واحد", "تنبيهان", "تنبيهات", "تنبيهًا"];
  const headline = crit ? `${ar(crit, ["أمر عاجل واحد", "أمران عاجلان", "أمور عاجلة", "أمرًا عاجلًا"])}${warn ? ` و${ar(warn, ALERTS)}` : ""} — تحتاج انتباهك اليوم` : warn ? `لا أمور عاجلة — ${ar(warn, ALERTS)} للمتابعة` : items.some((i) => i.horizon === "unavailable") ? "لا تنبيهات الآن، لكن بعض الفحوص غير متاحة" : "اليوم هادئ — لا تنبيهات تشغيلية";
  const text = [headline, ...items.map((i) => (i.level === "critical" ? "🔴 " : i.level === "warning" ? "🟠 " : "🔵 ") + i.text)].join("\n");
  return { headline, items, text };
}

/** Keyword-driven fallback: answers the most common ops questions from the context without a model. */
export function fallbackOpsReply(message: string, ctx: Record<string, any>): string { // deno-lint-ignore no-explicit-any
  // OWNER-20: a question about every branch is told plainly that this answer is for the selected branch only
  if (/(كل الفروع|جميع الفروع|الفرعين|all branches|every branch)/i.test(message)) {
    return `أستطيع الإجابة عن الفرع المختار فقط${ctx.branch?.name ? ` (${ctx.branch.name})` : ""}. أرقام كل الفروع في «لوحة الإدارة» ← «الفروع اليوم».\n\n` + fallbackOpsReply(message.replace(/(كل الفروع|جميع الفروع|الفرعين|all branches|every branch)/gi, ""), ctx);
  }
  const m = message.toLowerCase();
  const list = (rows: any[], f: (r: any) => string, empty: string) => rows.length ? rows.slice(0, 12).map((r, i) => `${i + 1}. ${f(r)}`).join("\n") : empty; // deno-lint-ignore no-explicit-any
  if (/(وصول|قادم|يوصل|arrival)/.test(m)) return "وصول اليوم:\n" + list(ctx.arrivals ?? [], (r) => `${r.ref} — ${r.guest ?? "—"} — ${r.room ? "وحدة " + r.room : r.category ?? ""} — ${r.status === "checked_in" ? "وصل" : "لم يصل"} — هوية: ${r.identity_status} ${r.balance_due === undefined ? "" : `— متبقٍ ${sar(r.balance_due)}`}`, "لا يوجد وصول متوقع اليوم.");
  if (/(مغادر|يغادر|departure|checkout)/.test(m)) return "مغادرة اليوم:\n" + list(ctx.departures ?? [], (r) => `${r.ref} — ${r.guest ?? "—"} — وحدة ${r.room ?? "—"} ${r.balance_due === undefined ? "" : `— متبقٍ ${sar(r.balance_due)}`} ${r.deposit_balance === undefined ? "" : `— تأمين ${sar(r.deposit_balance)}`}`.trimEnd(), "لا توجد مغادرات متوقعة اليوم.") + ((ctx.overstays ?? []).length ? "\n\nتجاوزوا موعد المغادرة:\n" + list(ctx.overstays, (r) => `${r.ref} — وحدة ${r.room ?? "—"} — ${ar(n(r.days_over), DAYS)}`, "") : "");
  if (/(نظاف|متسخ|تنظيف|dirty|clean|مهم|task)/.test(m)) return "الوحدات التي تحتاج انتباهًا:\n" + list(ctx.units_needing_attention ?? [], (r) => `وحدة ${r.room} — ${r.cleanliness === "clean" ? "نظيفة" : r.cleanliness === "dirty" ? "متسخة" : "قيد التنظيف"} — حالة ${r.status} — مهام مفتوحة ${r.open_tasks}${r.next_arrival ? " — وصول قادم " + r.next_arrival : ""}`, "كل الوحدات نظيفة.") + "\n\nالمهام المفتوحة:\n" + list(ctx.open_tasks ?? [], (t) => `${t.target} — ${t.type} — ${t.priority} — ${t.assignee ?? "غير مسندة"}`, "لا مهام مفتوحة.");
  // a role without money gets no balance lists in its context: say so, never "no debts" (an omitted list is not an empty one)
  if (/(متبقي|رصيد|مديون|دفع|تأمين|balance|deposit|مال)/.test(m) && ctx.in_house_with_balance === undefined && ctx.checked_out_with_deposit === undefined) return "الأرصدة والتأمينات غير متاحة لصلاحيتك؛ يراجعها من له صلاحية المال.";
  if (/(متبقي|رصيد|مديون|دفع|تأمين|balance|deposit|مال)/.test(m)) return "المقيمون وعليهم متبقٍ:\n" + list(ctx.in_house_with_balance ?? [], (r) => `${r.ref} — وحدة ${r.room ?? "—"} — ${sar(r.balance_due)}`, "لا مديونيات على المقيمين.") + "\n\nتأمينات بعد المغادرة لم تُسوَّ:\n" + list(ctx.checked_out_with_deposit ?? [], (r) => `${r.ref} — ${sar(r.deposit_balance)}`, "لا تأمينات معلقة.");
  if (/(متاح|فاضي|خالي|available|توفر)/.test(m)) { const u = ctx.summary?.units ?? {}; return `الوحدات: ${u.ready} جاهزة للدخول، ${u.reserved} محجوزة، ${u.occupied} مؤجرة، ${u.dirty} تحتاج تنظيفًا، ${u.maintenance} صيانة. للتحقق من توفر فترة محددة استخدم شاشة «حجز جديد» أو اسأل بصيغة: المتاح من YYYY-MM-DD إلى YYYY-MM-DD.`; }
  return buildBriefing(ctx).text + "\n\n(المحرك الذكي غير مفعّل حاليًا؛ هذه إجابة مبنية مباشرة على بيانات النظام. يمكنك السؤال عن: الوصول، المغادرة، النظافة والمهام، الأرصدة والتأمينات.)";
}

// ---------------------------------------------------------------------------
// 6.13 (U6): the assistant's honesty guards, deterministic and independent of the model
// ---------------------------------------------------------------------------
/**
 * The staff member's own note, exactly as typed: «ملاحظة: …» to the end of the message, or a quoted text after the word
 * «ملاحظة». Returns null when the message carries no note. The note is never reworded by the model (see applyVerbatimNote).
 */
export function extractStaffNote(message: string): string | null {
  const m = (message ?? "").trim();
  const colon = m.match(/(?:^|[\s.،؛])(?:ملاحظ[ةتي]\S*|note)\s*[:：]\s*([\s\S]+)$/i);
  if (colon) { const t = colon[1].trim().replace(/^[«"“]([\s\S]*)[»"”]$/, "$1").trim(); return t || null; }
  const quoted = m.match(/ملاحظ\S*[^«"“\n]{0,40}[«"“]([^»"”]+)[»"”]/);
  return quoted ? quoted[1].trim() || null : null;
}

/** A proposal's `note` argument is the staff member's own words when they gave one: the model's version is replaced, never merged. */
export function applyVerbatimNote(args: Record<string, unknown>, staffMessage: string): Record<string, unknown> {
  if (args.action === undefined || !args.args || typeof args.args !== "object") return args;
  const note = extractStaffNote(staffMessage);
  if (note == null) return args;
  if (note.length > 300) throw new Error("INVALID_ARG: note_too_long");
  return { ...args, args: { ...(args.args as Record<string, unknown>), note } };
}

export interface AnomalySummary { count: number; kinds?: Record<string, number> }
const FIGURES_RE = /(\d[\d.,٫٬]*\s*(?:ر\.?\s?س|ريال|%)|المتبقي|الإجمالي|رصيد|المقبوض|الإشغال)/;
const ANOMALY_WORD_RE = /(شذوذ|بنود المراجعة|بند مراجعة|بنود شاذة|تنبيه مالي)/;

/**
 * When a reply shows figures and the branch has open anomaly items (rules of 4.6), the reply says so: the numbers are never
 * shown clean beside unreviewed anomalies. Adds one line only when the reply does not already mention them.
 */
export function withAnomalyNotice(reply: string, anomalies: AnomalySummary | null | undefined): string {
  const count = Number(anomalies?.count ?? 0);
  if (!(count > 0) || !FIGURES_RE.test(reply) || ANOMALY_WORD_RE.test(reply)) return reply;
  return `${reply}\n\nتنبيه: يوجد ${count} بند شذوذ مفتوح في المراجعة، وقد تتأثر الأرقام أعلاه بها؛ راجعها قبل الاعتماد عليها.`;
}


/** Cross-day read-only dedupe, pure: compares two readings by each item's stable key. «persistent» stays shown (an unresolved risk is never hidden for repeating); only a new or escalated item is «new». Nothing is stored here: the caller decides whether keeping the previous reading is allowed. */
export function diffBriefing(prev: BriefingItem[], cur: BriefingItem[]): { key: string; state: "new" | "escalated" | "persistent" | "changed"; level: BriefingItem["level"] }[] {
  const rank = { info: 0, warning: 1, critical: 2 } as const; const before = new Map(prev.filter((i) => i.key).map((i) => [i.key!, i]));
  return cur.filter((i) => i.key).map((i) => { const o = before.get(i.key!); return { key: i.key!, level: i.level, state: !o ? "new" : rank[i.level] > rank[o.level] ? "escalated" : o.text !== i.text ? "changed" : "persistent" }; });
}
