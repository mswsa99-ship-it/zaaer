/**
 * Tool definitions exposed to the model + their SERVER-SIDE executors.
 *
 * Executors run with the service-role client but are deliberately narrow:
 *  - every query is scoped to the conversation's branch / verified token
 *  - no executor can read keybox codes, document numbers, or other guests
 *  - no executor mutates identity / payment / access approval state
 *  - results are shaped for the model and contain only public-safe fields
 */
import type { ToolDeclaration } from "./llm.ts";
import { VERIFIED_ONLY_TOOLS, matchKnowledge, type KnowledgeEntry, type ToolName } from "./guardrails.ts";

// Minimal structural type so this module stays SDK-agnostic for tests
export interface DbClient {
  from(table: string): any; // deno-lint-ignore no-explicit-any
  rpc(fn: string, args?: Record<string, unknown>): any; // deno-lint-ignore no-explicit-any
}

export interface ToolContext {
  db: DbClient;
  organizationId: string;
  branchId: string;
  conversationId: string;
  guestToken: string | null;      // present only after secure verification
  appBaseUrl: string;             // e.g. https://reception.example.sa
  propertyName: string;
}

export const TOOL_DECLARATIONS: ToolDeclaration[] = [
  // decision 23: a new booking, a price or an availability question → the branch's platform link; nothing is shown here
  { name: "get_booking_link", description: "رابط منصة الحجز المعتمدة للفرع: الطريقة الوحيدة لحجز جديد ولمعرفة الأسعار والتوفر. لا يعرض أسعارًا ولا توفرًا.", parameters: { type: "object", properties: {} } },
  { name: "request_booking_verification", description: "يعيد رابط الصفحة الآمنة للتحقق من ملكية حجز سابق برقمه. لا يكشف أي بيانات.",
    parameters: { type: "object", properties: { external_ref: { type: "string" } }, required: ["external_ref"] } },
  { name: "get_verified_booking_summary", description: "ملخص محدود للحجز المتحقق منه في هذه الجلسة (الحالات والتواريخ).", parameters: { type: "object", properties: {} } },
  { name: "create_registration_session", description: "رابط نموذج تسجيل بيانات النزلاء الآمن للحجز المتحقق منه.", parameters: { type: "object", properties: {} } },
  { name: "get_registration_progress", description: "عدد النزلاء الذين اكتملت بياناتهم من المطلوب.", parameters: { type: "object", properties: {} } },
  { name: "create_payment_request", description: "يطلب رابط دفع أو يوضح طريقة السداد المتاحة والمبلغ المتبقي.", parameters: { type: "object", properties: {} } },
  { name: "get_payment_status", description: "حالة السداد الحالية للحجز المتحقق منه.", parameters: { type: "object", properties: {} } },
  { name: "submit_checkin_request", description: "يُبلغ المشرف بوصول النزيل وينشئ طلب اعتماد دخول.", parameters: { type: "object", properties: {} } },
  { name: "get_public_property_policies", description: "سياسات ومعلومات المنشأة: مواعيد الوصول/المغادرة، الإلغاء، الواي فاي، المواقف، الموقع، الأطفال.",
    parameters: { type: "object", properties: { topic: { type: "string", enum: ["general", "checkin", "cancellation", "wifi", "parking", "location", "children", "contact"] } } } },
  { name: "search_knowledge_base", description: "يبحث في قاعدة معرفة المنشأة المعتمدة (أسئلة وأجوبة يديرها الاستقبال: خدمات، مرافق، دفع، أماكن قريبة…). يعيد الإجابة المعتمدة فقط؛ لا تخترع إجابة إن لم توجد.",
    parameters: { type: "object", properties: { query: { type: "string", description: "سؤال النزيل بصياغته" } }, required: ["query"] } },
  { name: "open_supervisor_ticket", description: "فتح تذكرة للمشرف لطلب خارج صلاحيات المساعد (استثناء، شكوى، مشكلة).",
    parameters: { type: "object", properties: { reason: { type: "string" } }, required: ["reason"] } },
  { name: "request_human_assistance", description: "تحويل المحادثة إلى مشرف بشري.",
    parameters: { type: "object", properties: { reason: { type: "string" } }, required: ["reason"] } },
];

const halalasToSar = (h: number) => (Number(h || 0) / 100).toFixed(2);   // the guest's own balance only; never a price list

export async function executeTool(name: ToolName, args: Record<string, unknown>, ctx: ToolContext): Promise<unknown> {
  if (VERIFIED_ONLY_TOOLS.has(name) && !ctx.guestToken) {
    return { denied: true, reason: "يتطلب التحقق من ملكية الحجز أولًا عبر الصفحة الآمنة.", link: `${ctx.appBaseUrl}/booking/lookup` };
  }

  switch (name) {
    case "get_booking_link": {
      const { data } = await ctx.db.rpc("fn_public_branch", { p_branch: ctx.branchId });
      const link = (data as { booking_platform_url?: string | null } | null)?.booking_platform_url ?? null;
      if (!link) return { link: null, instruction: "لا يوجد رابط منصة حجز مضبوط لهذا الفرع. أخبر النزيل أن الحجز الجديد عبر منصات الحجز المعتمدة واعرض عليه موظف الاستقبال ليوجّهه. لا تذكر أسعارًا ولا توفرًا." };
      return { link, instruction: "أرسل الرابط كما هو. الأسعار والتوفر والحجز في المنصة فقط؛ لا تذكرها هنا. بعد الحجز يعود النزيل برقم حجزه إلى «حجوزاتي»." };
    }
    case "request_booking_verification": {
      const ref = String(args.external_ref ?? "");
      return { instruction: "وجّه النزيل إلى «حجوزاتي»: يكتب رقم جواله الذي حجز به فتظهر حجوزاته بعد خطوة تحقق قصيرة. لا تطلب منه رقم الجوال في المحادثة.", link: `${ctx.appBaseUrl}/booking/lookup?ref=${encodeURIComponent(ref)}` };
    }
    case "get_verified_booking_summary": {
      const s = await session(ctx);
      if (!s) return { error: "انتهت صلاحية جلسة التحقق" };
      const r = s.reservation;
      return {
        internal_ref: r.internal_ref, status: r.status, check_in: r.check_in, check_out: r.check_out,
        category: r.category_name, room_number: r.room_number ?? null,
        identity_status: r.identity_status, payment_status: r.payment_status,
        government_registration: r.government_registration, access_status: r.access_status,
        balance_due_sar: halalasToSar((r.total_halalas ?? 0) - (r.paid_halalas ?? 0)),
        pending_requirements: s.access?.reasons ?? [],
        status_link: `${ctx.appBaseUrl}/booking/status/${ctx.guestToken}`,
      };
    }
    case "create_registration_session": {
      const s = await session(ctx);
      if (!s) return { error: "انتهت صلاحية جلسة التحقق" };
      return { link: `${ctx.appBaseUrl}/booking/registration/${ctx.guestToken}`, expires_at: s.expires_at, note: "لا تطلب أرقام الوثائق في المحادثة؛ تُدخل في النموذج الآمن فقط." };
    }
    case "get_registration_progress": {
      const s = await session(ctx);
      if (!s) return { error: "انتهت صلاحية جلسة التحقق" };
      const required = (s.reservation.adults ?? 1) + (s.reservation.companions ?? 0);
      const submitted = (s.guests ?? []).filter((g: Record<string, unknown>) => g.data_submitted).length;
      return { required, submitted, complete: submitted >= required, identity_status: s.reservation.identity_status };
    }
    case "create_payment_request": {
      const s = await session(ctx);
      if (!s) return { error: "انتهت صلاحية جلسة التحقق" };
      const due = (s.reservation.total_halalas ?? 0) - (s.reservation.paid_halalas ?? 0);
      if (due <= 0) return { status: "paid", balance_due_sar: "0.00" };
      // Payment-link provider adapter not configured → honest status (no fake link)
      return {
        status: "awaiting_provider",
        balance_due_sar: halalasToSar(due),
        instruction: "لا يتوفر رابط دفع إلكتروني حاليًا. يمكن السداد عبر منصة الحجز أو جهاز نقاط البيع لدى الاستقبال، ويعتمد المشرف السداد بعد التحقق.",
      };
    }
    case "get_payment_status": {
      const s = await session(ctx);
      if (!s) return { error: "انتهت صلاحية جلسة التحقق" };
      return { payment_status: s.reservation.payment_status, balance_due_sar: halalasToSar((s.reservation.total_halalas ?? 0) - (s.reservation.paid_halalas ?? 0)) };
    }
    case "submit_checkin_request": {
      const { data, error } = await ctx.db.rpc("fn_guest_submit_checkin", { p_token: ctx.guestToken });
      if (error) return { error: "تعذر إرسال طلب الوصول" };
      return { ok: true, access_status: data?.access_status, note: "سيراجع المشرف الطلب؛ يظهر الرمز في صفحة الحجز بعد الاعتماد." };
    }
    case "get_public_property_policies": {
      const topic = String(args.topic ?? "general");
      const { data: b } = await ctx.db.from("branches").select("name_ar, address, map_url, phone, email, check_in_time, check_out_time").eq("id", ctx.branchId).maybeSingle();
      const { data: pol } = await ctx.db.from("property_policies").select("topic, title, content_ar").eq("branch_id", ctx.branchId).eq("is_public", true);
      const policies = (pol ?? []).filter((p: Record<string, string>) => topic === "general" || p.topic === topic);
      return {
        // decision 31: the map link goes to the guest as it is
        branch: b ? { name: b.name_ar, address: b.address, map_url: b.map_url, phone: b.phone, check_in_time: b.check_in_time, check_out_time: b.check_out_time } : null,
        policies,
      };
    }
    case "search_knowledge_base": {
      // public + active entries of this branch only (fn_public_knowledge filters staff-only rows server-side)
      const { data } = await ctx.db.rpc("fn_public_knowledge", { p_branch: ctx.branchId });
      const entries = (data ?? []) as KnowledgeEntry[];
      const m = matchKnowledge(String(args.query ?? ""), entries);
      if (!m) {
        await ctx.db.rpc("fn_record_unanswered", { p_branch: ctx.branchId, p_question: String(args.query ?? "").slice(0, 300), p_conversation: ctx.conversationId });
        return { found: false, note: "لا توجد إجابة معتمدة لهذا السؤال. أخبر النزيل أن المعلومة غير متوفرة لديك وأنها سُجّلت لفريق الاستقبال." };
      }
      await ctx.db.rpc("fn_knowledge_usage_bump", { p_entry: m.entry.id });
      return { found: true, question: m.entry.question, answer: m.entry.answer, confidence: m.strong ? "high" : "low" };
    }
    case "open_supervisor_ticket":
    case "request_human_assistance": {
      const kind = name === "request_human_assistance" ? "assistance" : "escalation";
      await ctx.db.from("human_handoff_tickets").insert({
        organization_id: ctx.organizationId, branch_id: ctx.branchId, conversation_id: ctx.conversationId,
        kind, details: { reason: args.reason ?? "", verified: !!ctx.guestToken },
      });
      if (kind === "assistance") {
        await ctx.db.from("conversations").update({ status: "handed_off", handed_off_at: new Date().toISOString(), handoff_reason: String(args.reason ?? "") }).eq("id", ctx.conversationId);
      }
      await ctx.db.from("notifications").insert({ branch_id: ctx.branchId, audience: "supervisor", title: kind === "assistance" ? "طلب مساعدة بشرية" : "تذكرة من مساعد الاستقبال", body: String(args.reason ?? "").slice(0, 200), link: "/staff/inbox" });
      return { ok: true, handed_off: kind === "assistance" };
    }
    default:
      return { denied: true, reason: "tool not allowed" };
  }
}

async function session(ctx: ToolContext): Promise<any | null> { // deno-lint-ignore no-explicit-any
  if (!ctx.guestToken) return null;
  const { data, error } = await ctx.db.rpc("fn_guest_session", { p_token: ctx.guestToken });
  if (error || !data) return null;
  return data;
}
