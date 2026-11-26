/* eslint-disable @typescript-eslint/no-explicit-any */
/**
 * Demo parity for migrations 0070–0072 — the guest journey after the stay (plan «خطة تصحيح ملاحظات التجربة», م٤):
 *   W3 the check-out options at 10 AM and the extension (a night, or hours after 1 PM at 5 riyals each, a part of an
 *      hour counted whole, up to the next guest less the cleaning hour; held while the guest pays, given back when not),
 *   W4 the departure («غادرت وسلّمت المفتاح» after the instructions), the deposit's countdown from the confirmed
 *      check-out and its receipt once the return is recorded,
 *   W5 one invitation to review after 60 minutes (an overall mark asked on its own, six aspects; under 9 alerts the owner),
 *   W6 the alert rules (who, which channel, after how long, to whom it climbs), W7 the unit's way in and out (approved
 *      photos only), and the trial data's overview (0072).
 * The same rules, error codes and shapes as the SQL functions. The journey's clock runs whenever the reception computer
 * asks for its messages (the WhatsApp simulator) or a member of staff's screen looks («رحلة الضيف»).
 */
import { uid, nowISO, ORG, addDays, type Row } from "./data";

export interface JourneyCtx {
  T: (t: string) => Row[];
  byId: (t: string, id: string | null | undefined) => Row | undefined;
  requireCap: (code: string) => void;
  requireBranch: (b: string | null | undefined) => void;
  hasRole: (...roles: string[]) => boolean;
  staffId: () => string | null;
  audit: (branch: string | null, action: string, entity: string, entityId: string, details: Row) => void;
  emit: (table: string) => void;
  /** fn_check_version_strict */
  checkVersion: (cur: number, exp?: number | null) => void;
  branchToday: (b: string) => string;
  recompute: (resId: string) => any;
  /** fn_add_charge (rent and its adjustments carry the rent's tax, the rest the services'); returns the line's id */
  addCharge: (resId: string, kind: string, description: string, qty: number, unit: number, taxable: boolean, reason: string | null, serviceId: string | null, from: string | null, to: string | null) => string;
  /** fn_charge_tax: the tax of the policy the stay was made under */
  chargeTax: (resId: string, category: "rent" | "services" | "products", amount: number, taxable: boolean) => { net: number; tax: number };
  /** fn_amend_stay_internal */
  amendStay: (resId: string, newCheckOut: string, mode: "keep_rate" | "reprice", reason: string, staffRules: boolean) => any;
  /** fn_room_free_internal: the room's allocations and an overstay, whoever asks */
  roomFree: (roomId: string, from: string, to: string, exclude: string) => boolean;
  overdueBlocked: (resId: string) => boolean;
  sarText: (h: number) => string;
  normPhone: (p: unknown) => string | null;
  /** a stay's page key (registration_sessions) */
  newToken: (resId: string) => string;
  validHttpsUrl: (u: string) => boolean;
  /** fn_sees_money: the permissions' matrix gives the caller a money operation */
  seesMoney: () => boolean;
}

export const ALERT_EVENTS = ["guest_departed", "deposit_overdue", "review_low", "extension_requested", "extension_unpaid", "product_order", "guest_handoff", "message_failed"] as const;
export const ALERT_LABELS: Record<string, string> = {
  guest_departed: "غادر النزيل — بانتظار التحقق", deposit_overdue: "تأخر رد التأمين عن مهلته", review_low: "تقييم أقل من الحد",
  extension_requested: "طلب تمديد أو خروج متأخر", extension_unpaid: "تمديد لم يُدفع في مهلته", product_order: "طلب منتجات بانتظار الدفع",
  guest_handoff: "طلب النزيل موظفًا", message_failed: "تعذّر إرسال رسالة للنزيل",
};
const RULE_DEFAULTS: Array<[string, string[], string, number | null]> = [
  ["guest_departed", ["responsible"], "both", 30], ["deposit_overdue", ["responsible"], "both", 30], ["review_low", ["owner"], "both", null],
  ["extension_requested", ["responsible"], "both", 15], ["extension_unpaid", ["responsible"], "app", 30], ["product_order", ["responsible"], "app", 30],
  ["guest_handoff", ["responsible"], "both", 10], ["message_failed", ["responsible"], "app", null],
];
const RECIPIENTS = ["responsible", "fallback", "owner", "manager", "supervisor"];
export const REVIEW_ASPECTS = [
  { key: "staff", label: "تعامل الموظفين" }, { key: "cleanliness", label: "النظافة" }, { key: "comfort", label: "الراحة" },
  { key: "facilities", label: "المرافق" }, { key: "value", label: "القيمة مقابل السعر" }, { key: "location", label: "الموقع" },
];
const MARKS = ["overall", "staff", "cleanliness", "comfort", "facilities", "value", "location"];
const DEFAULTS = {
  journey_enabled: true, checkout_message_time: "10:00", free_checkout_until: "13:00", late_hour_price_halalas: 500, cleaning_buffer_minutes: 60,
  hold_minutes: 30, checkout_instructions: null, deposit_refund_hours: 3, review_delay_minutes: 60, review_alert_below: 9,
  responsible_staff_id: null, fallback_staff_id: null, version: 1,
};
const UUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const HHMM = /^([01][0-9]|2[0-3]):[0-5][0-9]$/;

/** "HH:MM[:SS]" → minutes since midnight */
const toMin = (t: unknown) => { const m = /^(\d{1,2}):(\d{2})/.exec(String(t ?? "")); return m ? Number(m[1]) * 60 + Number(m[2]) : 0; };
const hm = (min: number) => (min >= 1440 ? "24:00" : `${String(Math.floor(min / 60)).padStart(2, "0")}:${String(min % 60).padStart(2, "0")}`);
/** fn_ar_hours */
export const arHours = (n: number) => (n === 1 ? "ساعة واحدة" : n === 2 ? "ساعتان" : n >= 3 && n <= 10 ? `${n} ساعات` : `${n} ساعة`);
/** fn_late_until: the hour late hours end at (midnight is 24:00, the end of the day of departure) */
const lateUntil = (fromMin: number, hours: number) => (fromMin + hours * 60 >= 1440 ? "24:00" : hm(fromMin + hours * 60));
/** fn_ar_hm / fn_ar_period / fn_ar_window / fn_ar_range: a clock time as the guest reads it, and the free hour's window */
export const arHm = (min: number) => { const h = Math.floor(min / 60), m = min % 60; return String(((h + 11) % 12) + 1) + (m > 0 ? ":" + String(m).padStart(2, "0") : ""); };
export const arPeriod = (min: number) => (min === 0 || min >= 1440 ? "منتصف الليل" : min < 720 ? "صباحًا" : min < 900 ? "ظهرًا" : min < 1080 ? "عصرًا" : "مساءً");
export const arWindow = (a: number, b: number) => (arPeriod(a) === arPeriod(b) ? `بين ${arHm(a)} و${arHm(b)} ${arPeriod(b)}` : `بين ${arHm(a)} ${arPeriod(a)} و${arHm(b)} ${arPeriod(b)}`);
export const arRange = (a: number, b: number) => `${arHm(a)}–${arHm(b)}`;
/** fn_alert_is_mine: named to this person in the system (when told, or when it climbed), or named to nobody at all */
export const alertIsMine = (notified: unknown, escalated: unknown, staff: string | null) => {
  const n = Array.isArray(notified) ? notified : [], e = Array.isArray(escalated) ? escalated : [];
  return [...n, ...e].some((x: any) => !!staff && x?.staff_id === staff && !!x?.app) || (n.length === 0 && e.length === 0);
};
/** fn_journey_keycap */
const keycap = (n: number) => (n >= 0 && n <= 9 ? `${n}\u{FE0F}\u{20E3}` : n === 10 ? "\u{1F51F}" : `${n}.`);
/** the date and the minute of a moment on a branch's clock */
function local(at: number, tz: string) {
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(new Date(at));
  const g = (t: string) => parts.find((x) => x.type === t)?.value ?? "00";
  return { date: `${g("year")}-${g("month")}-${g("day")}`, min: (Number(g("hour")) % 24) * 60 + Number(g("minute")) };
}
/** a review's page key is kept only as its hash (the demo's hash is not cryptographic; the server's is sha-256) */
export function hashToken(t: string) {
  let a = 0x811c9dc5, b = 0x9e3779b9;
  for (let i = 0; i < t.length; i++) { const c = t.charCodeAt(i); a = Math.imul(a ^ c, 16777619) >>> 0; b = Math.imul(b + c, 2246822519) >>> 0; }
  return a.toString(16).padStart(8, "0") + b.toString(16).padStart(8, "0") + t.length.toString(16);
}
function randomHex(bytes: number) {
  const a = new Uint8Array(bytes);
  try { crypto.getRandomValues(a); } catch { for (let i = 0; i < bytes; i++) a[i] = Math.floor(Math.random() * 256); }
  return Array.from(a, (x) => x.toString(16).padStart(2, "0")).join("");
}
/** the guests' pages of the demo open inside the demo itself (HashRouter) */
const demoSite = () => (typeof window !== "undefined" ? window.location.href.split("#")[0] + "#" : "");

/** a few answered reviews for the demo (the reviews' tab and its averages), one under the alert's mark with its alert */
export function seedJourney(T: (t: string) => Row[]) {
  // older stays (past the invitation's two days): the recent ones get their invitation live, from the journey's clock
  const done = T("reservations").filter((r) => ["checked_out", "closed"].includes(r.status) && r.actual_check_out && Date.parse(r.actual_check_out) < Date.now() - 2 * 86400_000)
    .sort((a, b) => (a.actual_check_out < b.actual_check_out ? 1 : -1));
  const marks: Array<[number, number[], string | null]> = [
    [10, [10, 10, 9, 9, 10, 10], "إقامة ممتازة والاستقبال متعاون."],
    [9, [9, 10, 9, 8, 9, 10], null],
    [7, [8, 6, 7, 7, 8, 9], "الغرفة احتاجت تنظيفًا أفضل عند الوصول."],
  ];
  done.slice(0, 3).forEach((r, i) => {
    const [overall, a, comment] = marks[i];
    const at = new Date(Date.parse(r.actual_check_out) + 75 * 60_000).toISOString();
    const g = { id: uid(), organization_id: ORG, branch_id: r.branch_id, reservation_id: r.id, token_hash: hashToken(randomHex(18)), invited_at: at, invite_status: "queued",
      submitted_at: new Date(Date.parse(at) + 20 * 60_000).toISOString(), overall, staff: a[0], cleanliness: a[1], comfort: a[2], facilities: a[3], value: a[4], location: a[5],
      comment, reply: null, replied_by: null, replied_at: null, version: 2 };
    T("guest_reviews").push(g);
    if (overall < 9) {
      const room = T("rooms").find((x) => x.id === r.room_id)?.room_number ?? "";
      T("alert_events").push({ id: uid(), organization_id: ORG, branch_id: r.branch_id, event: "review_low", ref_key: "review:" + g.id, reservation_id: r.id,
        title: `تقييم ${overall} من 10 — غرفة ${room}`, body: comment ?? "بلا تعليق", link: "/staff/journey", created_at: g.submitted_at, notify_at: g.submitted_at,
        notified_at: g.submitted_at, notified_to: [], escalated_at: null, escalated_to: null, resolved_at: null, resolved_by: null, resolved_how: null });
    }
  });
}

export function journeyRpcs(ctx: JourneyCtx) {
  const { T, byId, requireCap, requireBranch, hasRole, staffId, audit, emit } = ctx;
  const tzOf = (branch: string) => byId("branches", branch)?.timezone || "Asia/Riyadh";
  const roomNo = (roomId: string | null | undefined) => (roomId ? byId("rooms", roomId)?.room_number ?? null : null);
  const channelReady = (branch: string) => T("branch_whatsapp_channels").some((c) => c.branch_id === branch && c.mode === "web_bridge" && c.enabled && c.has_bridge_key);
  const sar = ctx.sarText;

  /** the branch's journey settings (a row for every branch, as the SQL's trigger makes one) */
  const settings = (branch: string): Row => {
    let s = T("branch_journey_settings").find((x) => x.branch_id === branch);
    // the demo's second branch (Jeddah) runs its own morning message, free-checkout hour and refund time, so merged views can prove they never blur two branches' rules
    const own = branch === "00000000-0000-0000-0000-000000000012" ? { checkout_message_time: "11:00", free_checkout_until: "14:00", deposit_refund_hours: 5 } : {};
    if (!s) { s = { branch_id: branch, organization_id: ORG, ...DEFAULTS, ...own, updated_by: null, updated_at: nowISO() }; T("branch_journey_settings").push(s); }
    return s;
  };
  /** the organisation's rules (the defaults are seeded with it) */
  const rules = (): Row[] => {
    const rs = T("alert_rules");
    for (const [event, recipients, channel, esc] of RULE_DEFAULTS) if (!rs.some((r) => r.event === event)) rs.push({ organization_id: ORG, event, enabled: true, recipients, channel, delay_minutes: 0, escalate_after_minutes: esc, escalate_to: "fallback", version: 1, updated_by: null, updated_at: nowISO() });
    return rs;
  };
  const rule = (event: string) => rules().find((r) => r.event === event);
  const staffName = (id: string | null | undefined) => (id ? byId("staff_profiles", id)?.full_name ?? null : null);

  // ---------------------------------------------------------------------------------------------------------------
  // W6 — the alerts
  // ---------------------------------------------------------------------------------------------------------------
  /** fn_alert_people: the branch's responsible (or its supervisors), its fallback (or the owners), the owners, a role */
  const alertPeople = (branch: string, recipients: string[]): Row[] => {
    const s = settings(branch);
    const works = T("staff_profiles").filter((sp) => sp.organization_id === ORG && sp.is_active
      && (sp.role === "owner" || T("branch_memberships").some((m) => m.staff_id === sp.id && m.branch_id === branch && !m.removed_at)));
    const ids = new Set<string>();
    if (recipients.includes("responsible")) {
      if (s.responsible_staff_id) { if (works.some((w) => w.id === s.responsible_staff_id)) ids.add(s.responsible_staff_id); }
      else works.filter((w) => w.role === "supervisor").forEach((w) => ids.add(w.id));
    }
    if (recipients.includes("fallback")) {
      if (s.fallback_staff_id) { const f = T("staff_profiles").find((sp) => sp.id === s.fallback_staff_id && sp.is_active && sp.organization_id === ORG); if (f) ids.add(f.id); }
      else works.filter((w) => w.role === "owner").forEach((w) => ids.add(w.id));
    }
    works.filter((w) => ["owner", "manager", "supervisor"].includes(w.role) && recipients.includes(w.role)).forEach((w) => ids.add(w.id));
    return T("staff_profiles").filter((sp) => ids.has(sp.id)).sort((a, b) => String(a.full_name).localeCompare(String(b.full_name), "ar"));
  };
  /** fn_staff_whatsapp: a closed conversation of its own on the reception computer, never mixed with the guests' */
  const staffWhatsapp = (branch: string, phone: unknown, text: string): string => {
    const ph = ctx.normPhone(phone);
    if (!ph) return "no_phone";
    if (!channelReady(branch)) return "channel_unavailable";
    let cv = T("conversations").filter((c) => c.branch_id === branch && c.wa_contact === ph && c.status === "closed" && c.handoff_reason === "تنبيهات الموظفين")
      .sort((a, b) => (a.created_at < b.created_at ? 1 : -1))[0];
    if (!cv) {
      cv = { id: uid(), branch_id: branch, reservation_id: null, channel: "whatsapp", status: "closed", guest_token: null, wa_contact: ph, wa_chat_id: ph + "@c.us",
        client_fingerprint: null, created_at: nowISO(), last_message_at: nowISO(), handed_off_at: null, handoff_reason: "تنبيهات الموظفين", human_active_until: null, wa_menu: null };
      T("conversations").push(cv); emit("conversations");
    }
    const m = { id: uid(), conversation_id: cv.id, sender: "assistant", content: text, meta: { mode: "staff_alert", channel: "whatsapp", delivery: "queued" }, created_at: nowISO() };
    T("conversation_messages").push(m);
    T("whatsapp_outbox").push({ id: uid(), branch_id: branch, message_id: m.id, status: "pending", attempts: 0, wa_id: null, error: null, created_at: nowISO(), picked_at: null, finished_at: null, body: null });
    emit("conversation_messages"); emit("whatsapp_outbox");
    return "queued";
  };
  /** fn_alert_notify */
  const alertNotify = (id: string, escalation: boolean) => {
    const a = T("alert_events").find((x) => x.id === id);
    if (!a || a.resolved_at) return;
    const rl = rule(a.event);
    if (!rl) return;
    const txt = (escalation ? "تصعيد — لم يُعالَج بعد: " : "") + a.title + (a.body ? "\n" + a.body : "");
    const app = ["app", "both"].includes(rl.channel), wa = ["whatsapp", "both"].includes(rl.channel);
    // in the system: the alert counts in the badge of each person it names (and of one WhatsApp could not reach)
    const who = alertPeople(a.branch_id, escalation ? [rl.escalate_to] : rl.recipients).map((p) => {
      const sent = wa ? staffWhatsapp(a.branch_id, p.phone, "🔔 " + txt) : null;
      return { staff_id: p.id, name: p.full_name, app: app || sent !== "queued", whatsapp: sent };
    });
    if (escalation) Object.assign(a, { escalated_at: nowISO(), escalated_to: who }); else Object.assign(a, { notified_at: nowISO(), notified_to: who });
    emit("alert_events");
  };
  /** fn_alert_raise: once per event and thing, by its rule (nothing when the rule is off) */
  const alertRaise = (branch: string, event: string, ref: string, title: string, body: string | null, link: string | null, resId: string | null = null): string | null => {
    if (!byId("branches", branch)) return null;
    const rl = rule(event);
    if (!rl || !rl.enabled) return null;
    if (T("alert_events").some((x) => x.event === event && x.ref_key === ref)) return null;
    const a = { id: uid(), organization_id: ORG, branch_id: branch, event, ref_key: ref, reservation_id: resId, title: title.slice(0, 200), body: body == null ? null : body.slice(0, 1000), link,
      created_at: nowISO(), notify_at: new Date(Date.now() + Number(rl.delay_minutes) * 60_000).toISOString(), notified_at: null, notified_to: null, escalated_at: null, escalated_to: null,
      resolved_at: null, resolved_by: null, resolved_how: null };
    T("alert_events").push(a); emit("alert_events");
    if (Number(rl.delay_minutes) === 0) alertNotify(a.id, false);
    return a.id;
  };
  /** fn_alert_resolve */
  const alertResolve = (event: string, ref: string) => {
    for (const a of T("alert_events")) if (a.event === event && a.ref_key === ref && !a.resolved_at) Object.assign(a, { resolved_at: nowISO(), resolved_how: "auto" });
    emit("alert_events");
  };

  // ---------------------------------------------------------------------------------------------------------------
  // The journey's messages to the guest (each kind once per stay and thing)
  // ---------------------------------------------------------------------------------------------------------------
  /** fn_journey_render: the text as the reception computer types it, and the menu the guest's answer is read against */
  const render = (body: string, options: Array<{ id: string; title: string }> | null) => {
    if (!options?.length) return { text: body, menu: null as Row | null };
    return {
      text: body + "\n\n" + options.map((o, i) => `${keycap(i + 1)} ${o.title}`).join("\n") + "\n\nأرسل رقم الخيار.",
      menu: { at: nowISO(), options: options.map((o, i) => ({ n: i + 1, id: o.id, title: o.title })) },
    };
  };
  /** fn_reservation_guest_phone */
  const guestPhone = (resId: string): string | null => {
    const gs = T("reservation_guests").filter((g) => g.reservation_id === resId).sort((a, b) => Number(!!b.is_primary) - Number(!!a.is_primary) || (a.created_at < b.created_at ? -1 : 1));
    for (const g of gs) {
      const raw = String(g.phone ?? "").trim() || (g.guest_profile_id ? byId("guest_profiles", g.guest_profile_id)?.phone : null);
      if (raw) return ctx.normPhone(raw);
    }
    return null;
  };
  /** fn_journey_send */
  const journeySend = (resId: string, kind: string, ref: string | null, body: string, options: Array<{ id: string; title: string }> | null = null, typed: string | null = null): string => {
    const r = byId("reservations", resId);
    if (!r) return "not_found";
    const key = ref ?? "";
    if (T("journey_messages").some((m) => m.reservation_id === r.id && m.kind === kind && m.ref_key === key)) return "already";
    const s = settings(r.branch_id);
    const phone = guestPhone(r.id);
    const why = !s.journey_enabled ? "journey_off" : !channelReady(r.branch_id) ? "channel_unavailable" : !phone ? "no_phone" : null;
    if (why) {
      T("journey_messages").push({ id: uid(), organization_id: ORG, branch_id: r.branch_id, reservation_id: r.id, kind, ref_key: key, status: "skipped", reason: why, conversation_id: null, message_id: null, created_at: nowISO() });
      emit("journey_messages");
      if (why === "no_phone") {
        alertRaise(r.branch_id, "message_failed", `journey:${r.id}:${kind}:${key}`, "تعذّر إرسال رسالة للنزيل — " + (roomNo(r.room_id) ? "غرفة " + roomNo(r.room_id) : r.internal_ref),
          "لا يوجد جوال للنزيل في الحجز " + r.internal_ref + ". أبلغ النزيل بنفسك.", "/staff/journey", r.id);
      } else if (why === "channel_unavailable") {
        // once a day for the branch, not once a message
        alertRaise(r.branch_id, "message_failed", `channel:${r.branch_id}:${ctx.branchToday(r.branch_id)}`, "واتساب الفرع غير مربوط — رسائل رحلة الضيف لا تصل للنزلاء",
          "اربط واتساب الفرع بكمبيوتر الاستقبال من «واتساب» في الإعدادات. حتى ذلك أبلغ النزلاء بأنفسكم بخيارات الخروج وتأكيده ورد التأمين.", "/staff/journey", null);
      }
      return why;
    }
    const rendered = render(body, options);
    let cv = T("conversations").filter((c) => c.branch_id === r.branch_id && c.wa_contact === phone && c.status !== "closed" && Date.parse(c.last_message_at ?? "") > Date.now() - 24 * 3600_000)
      .sort((a, b) => (a.last_message_at < b.last_message_at ? 1 : -1))[0];
    const tok = ctx.newToken(r.id);
    if (!cv) {
      cv = { id: uid(), branch_id: r.branch_id, reservation_id: r.id, channel: "whatsapp", status: "active", guest_token: tok, wa_contact: phone, wa_chat_id: phone + "@c.us",
        client_fingerprint: null, created_at: nowISO(), last_message_at: nowISO(), handed_off_at: null, handoff_reason: null, human_active_until: null, wa_menu: null };
      T("conversations").push(cv);
    }
    Object.assign(cv, { reservation_id: r.id, guest_token: tok, last_message_at: nowISO(), wa_menu: rendered.menu });
    const m = { id: uid(), conversation_id: cv.id, sender: "assistant", content: rendered.text, meta: { mode: "journey", kind, channel: "whatsapp", delivery: "queued" }, created_at: nowISO() };
    T("conversation_messages").push(m);
    T("whatsapp_outbox").push({ id: uid(), branch_id: r.branch_id, message_id: m.id, status: "pending", attempts: 0, wa_id: null, error: null, created_at: nowISO(), picked_at: null, finished_at: null,
      body: typed != null ? render(typed, options).text : null });
    T("journey_messages").push({ id: uid(), organization_id: ORG, branch_id: r.branch_id, reservation_id: r.id, kind, ref_key: key, status: "queued", reason: null, conversation_id: cv.id, message_id: m.id, created_at: nowISO() });
    emit("conversations"); emit("conversation_messages"); emit("whatsapp_outbox"); emit("journey_messages");
    return "queued";
  };
  /** fn_journey_send_safe: a message riding on something else never stops it; the failure is told */
  const journeySendSafe = (resId: string, kind: string, ref: string | null, body: string, options: Array<{ id: string; title: string }> | null = null, typed: string | null = null): string => {
    try { return journeySend(resId, kind, ref, body, options, typed); }
    catch {
      const r = byId("reservations", resId);
      if (r) alertRaise(r.branch_id, "message_failed", `error:${r.id}:${kind}:${ref ?? ""}`, "تعذّر إرسال رسالة للنزيل — " + (roomNo(r.room_id) ? "غرفة " + roomNo(r.room_id) : ""),
        "خطأ في النظام أثناء تجهيز الرسالة. أبلغ النزيل بنفسك.", "/staff/journey", r.id);
      return "error";
    }
  };
  /** fn_extension_confirmed_text */
  const confirmedText = (kind: string, lateUntilHm: string | null, branch: string) => kind === "night"
    ? "تم تثبيت ليلتك الإضافية. موعد خروجك الجديد غدًا " + arWindow(toMin(byId("branches", branch)?.check_out_time ?? "12:00"), toMin(settings(branch).free_checkout_until)) + "."
    : "تم تثبيت خروجك المتأخر حتى " + (lateUntilHm ?? "") + ".";

  // ---------------------------------------------------------------------------------------------------------------
  // W3 — the check-out options and the extension
  // ---------------------------------------------------------------------------------------------------------------
  const lastRequest = (resId: string) => T("stay_extension_requests").filter((x) => x.reservation_id === resId).sort((a, b) => (a.created_at < b.created_at ? 1 : -1))[0];
  /** W7: the unit's approved photos (fn_unit_guide) */
  const unitGuide = (roomId: string, purpose: string) => T("branch_media_items")
    .filter((m) => m.room_id === roomId && (m.purpose ?? "gallery") === purpose && m.kind === "photo" && !m.archived_at && m.approved_at)
    .sort((a, b) => a.sort_order - b.sort_order || String(a.created_at).localeCompare(String(b.created_at)))
    .map((m) => ({ id: m.id, caption: m.caption ?? null, version: String(m.sha256 ?? "").slice(0, 12) }));
  /** fn_checkout_offer: n hours = leaving by the free hour's end + n; hours bought that day are not sold again ('have'), and
   *  the fewest hours that can be chosen now cover the hour being lived ('min'). at: the moment the clock is read at */
  const checkoutOffer = (resId: string, at: number = Date.now()) => {
    const r = byId("reservations", resId);
    if (!r) throw new Error("RESERVATION_NOT_FOUND");
    const b = byId("branches", r.branch_id)!; const s = settings(r.branch_id); const { date: today, min: nowMin } = local(at, tzOf(r.branch_id));
    const open = r.status === "checked_in" && !!r.room_id && r.check_out === today && !r.guest_departed_at;
    const req = lastRequest(r.id);
    let nightOk = false, nightPrice: number | null = null, hoursMax = 0, hourPrice: number | null = null, nextArrival = false, have = 0, min = 1, lateNow = 0;
    const free = toMin(s.free_checkout_until);
    if (open) {
      const last = T("reservation_nights").filter((n) => n.reservation_id === r.id && n.status === "active").sort((x, y) => (x.night < y.night ? 1 : -1))[0];
      const night = Number(last?.price_halalas ?? r.nightly_rate_halalas ?? 0);
      const t = ctx.chargeTax(r.id, "rent", night, true); nightPrice = t.net + t.tax;
      nightOk = night > 0 && !r.late_checkout_until && ctx.roomFree(r.room_id, r.check_out, addDays(r.check_out, 1), r.id) && !ctx.overdueBlocked(r.id);
      nextArrival = T("reservation_allocations").some((a) => a.room_id === r.room_id && a.status === "active" && a.from_date === today && a.reservation_id !== r.id);
      const limit = nextArrival ? toMin(b.check_in_time) - Number(s.cleaning_buffer_minutes) : 1440;
      if (limit > free) hoursMax = Math.floor((limit - free) / 60);
      const lateMin = r.late_checkout_until ? toMin(r.late_checkout_until) : 0;
      if (r.late_checkout_until && lateMin > free) have = Math.ceil((lateMin - free) / 60);
      min = Math.max(have + 1, nowMin > free ? Math.ceil((nowMin - free) / 60) : 1);
      const paidEnd = Math.max(free, r.late_checkout_until ? lateMin : free);
      if (nowMin > paidEnd) lateNow = Math.ceil((nowMin - paidEnd) / 60);
      const h = ctx.chargeTax(r.id, "services", Number(s.late_hour_price_halalas), true); hourPrice = h.net + h.tax;
    }
    return {
      open, status: r.status, check_out: r.check_out, room_number: roomNo(r.room_id),
      free_until: hm(free), check_out_time: hm(toMin(b.check_out_time)),
      night: { available: nightOk, price_halalas: open ? nightPrice : null },
      hours: { max: hoursMax, min, have, late_now: lateNow, price_halalas: open ? hourPrice : null, until_limit: open && hoursMax > 0 ? lateUntil(free, hoursMax) : null, next_guest: nextArrival },
      on_time_open: open && nowMin <= free,
      hold_minutes: s.hold_minutes, choice: r.checkout_choice ?? null, late_checkout_until: r.late_checkout_until ? hm(toMin(r.late_checkout_until)) : null,
      instructions: s.checkout_instructions ?? null, instructions_at: r.departure_instructions_at ?? null, departed_at: r.guest_departed_at ?? null,
      guide_checkout: !!r.room_id && unitGuide(r.room_id, "checkout").length > 0,
      deposit_halalas: r.deposit_balance_halalas ?? 0, refund_hours: s.deposit_refund_hours, balance_due: r.balance_due_halalas ?? 0,
      request: req ? { id: req.id, kind: req.kind, hours: req.hours ?? null, late_until: req.late_until ?? null, amount_halalas: req.amount_halalas, status: req.status, hold_until: req.hold_until } : null,
    };
  };
  /** fn_extension_release: the night returns to the room, the late hours' line gets its exact opposite */
  const extensionRelease = (qid: string, reason: string, status: string) => {
    const q = T("stay_extension_requests").find((x) => x.id === qid);
    if (!q || !["held", "overdue"].includes(q.status)) return;
    const r = byId("reservations", q.reservation_id)!;
    if (q.kind === "night") {
      if (r.check_out > q.previous_check_out) ctx.amendStay(r.id, q.previous_check_out, "keep_rate", reason, false);
    } else {
      const c = T("reservation_charges").find((x) => x.id === q.charge_id && Number(x.total_halalas) !== 0);
      if (c) {
        const neg = (x: Row, base: string | null) => ({ ...x, id: uid(), description: "إلغاء: " + x.description, unit_price_halalas: -x.unit_price_halalas, total_halalas: -x.total_halalas,
          invoice_id: null, reason, created_by: staffId(), created_at: nowISO(), base_charge_id: base });
        const n = neg(c, null); T("reservation_charges").push(n);
        for (const t of T("reservation_charges").filter((x) => x.base_charge_id === c.id && x.kind === "tax")) T("reservation_charges").push(neg(t, n.id));
        emit("reservation_charges");
      }
      r.late_checkout_until = q.previous_late_until ?? null; r.updated_at = nowISO();
      ctx.recompute(r.id);
    }
    const was = q.status;
    Object.assign(q, { status, decided_at: nowISO(), decided_by: staffId(), decision_reason: reason, version: q.version + 1 });
    emit("stay_extension_requests");
    alertResolve("extension_requested", "extension:" + q.id); alertResolve("extension_unpaid", "extension:" + q.id);
    audit(q.branch_id, "journey.extension_released", "extension_request", q.id, { before: { status: was }, after: { status, kind: q.kind, amount_halalas: q.amount_halalas }, reason });
  };
  /** fn_checkout_choose: 'on_time', 'night', 'hours' (leaving by the free hour's end + that many; only the hours not bought
   *  yet are charged, never fewer than the hour being lived), or 'cancel' */
  const checkoutChoose = (resId: string, choice: unknown, hours: unknown, source: string, at: number = Date.now()) => {
    const r = byId("reservations", resId);
    if (!r) throw new Error("RESERVATION_NOT_FOUND");
    const s = settings(r.branch_id); const room = roomNo(r.room_id) ?? "";
    if (choice === "cancel") {
      const q = T("stay_extension_requests").find((x) => x.reservation_id === r.id && x.status === "held");
      if (!q) throw new Error("VALIDATION: extension_none");
      extensionRelease(q.id, "ألغاه النزيل", "released");
      return checkoutOffer(r.id, at);
    }
    if (!["on_time", "night", "hours"].includes(String(choice))) throw new Error("VALIDATION: checkout_choice");
    const o = checkoutOffer(r.id, at);
    if (!o.open) throw new Error("VALIDATION: checkout_not_today");
    if (T("stay_extension_requests").some((x) => x.reservation_id === r.id && ["held", "overdue"].includes(x.status))) throw new Error("VALIDATION: extension_pending");
    if (choice === "on_time") {
      // (after the free hour leaving on time is past: the hours begun are late hours)
      if (!o.on_time_open) throw new Error("VALIDATION: free_hour_over");
      Object.assign(r, { checkout_choice: "on_time", checkout_choice_at: nowISO(), updated_at: nowISO() }); emit("reservations");
      audit(r.branch_id, "journey.checkout_on_time", "reservation", r.id, { after: { source } });
      return checkoutOffer(r.id, at);
    }
    const total0 = Number(r.total_halalas ?? 0);
    const holdUntil = new Date(Date.now() + Number(s.hold_minutes) * 60_000).toISOString();
    let q: Row;
    if (choice === "night") {
      if (!o.night.available) throw new Error("VALIDATION: night_unavailable");
      const prev = r.check_out;
      ctx.amendStay(r.id, addDays(r.check_out, 1), "keep_rate", "ليلة إضافية بطلب النزيل", false);
      q = { id: uid(), organization_id: ORG, branch_id: r.branch_id, reservation_id: r.id, kind: "night", hours: null, late_until: null, amount_halalas: Number(r.total_halalas) - total0, status: "held",
        hold_until: holdUntil, source, previous_check_out: prev, previous_late_until: null, charge_id: null, created_at: nowISO(), decided_at: null, decided_by: null, decision_reason: null, version: 1 };
    } else {
      const n = Number(hours);
      if (hours == null || !Number.isInteger(n) || n < Number(o.hours.min) || n > Number(o.hours.max)) throw new Error("VALIDATION: late_hours");
      const extra = n - Number(o.hours.have);
      const until = lateUntil(toMin(s.free_checkout_until), n); const day = r.check_out;
      const cid = ctx.addCharge(r.id, "addon", `خروج متأخر ${arHours(extra)} حتى ${until}`, extra, Number(s.late_hour_price_halalas), true, "بطلب النزيل", null, day, day);
      const prevLate = r.late_checkout_until ? hm(toMin(r.late_checkout_until)) : null;
      r.late_checkout_until = until; r.updated_at = nowISO();
      ctx.recompute(r.id);
      q = { id: uid(), organization_id: ORG, branch_id: r.branch_id, reservation_id: r.id, kind: "hours", hours: extra, late_until: until, amount_halalas: Number(r.total_halalas) - total0, status: "held",
        hold_until: holdUntil, source, previous_check_out: null, previous_late_until: prevLate, charge_id: cid, created_at: nowISO(), decided_at: null, decided_by: null, decision_reason: null, version: 1 };
    }
    T("stay_extension_requests").push(q); emit("stay_extension_requests");
    audit(r.branch_id, "journey.extension_held", "extension_request", q.id, { after: { kind: q.kind, hours: q.hours, late_until: q.late_until, amount_halalas: q.amount_halalas, hold_until: q.hold_until, source } });
    if (Number(r.balance_due_halalas ?? 0) <= 0) Object.assign(q, { status: "paid", decided_at: nowISO() });
    else {
      // (no amount in the alert: it reaches people who do not see money)
      const tz = tzOf(r.branch_id);
      alertRaise(r.branch_id, "extension_requested", "extension:" + q.id, (q.kind === "night" ? "طلب ليلة إضافية" : "طلب خروج متأخر " + arHours(q.hours) + " حتى " + q.late_until) + " — غرفة " + room,
        "محجوز حتى " + hm(local(Date.parse(q.hold_until), tz).min) + ". يُثبَّت عند سداد رصيد الحجز.", "/staff/journey", r.id);
    }
    return checkoutOffer(r.id, at);
  };

  // ---------------------------------------------------------------------------------------------------------------
  // W4 — the departure and the deposit's return
  // ---------------------------------------------------------------------------------------------------------------
  /** fn_departure_instructions: the instructions reach the guest (the page, WhatsApp); the moment is kept */
  const departureInstructions = (resId: string) => {
    const r = byId("reservations", resId);
    if (!r) throw new Error("RESERVATION_NOT_FOUND");
    if (r.status === "checked_in" && r.room_id && r.check_out <= ctx.branchToday(r.branch_id) && !r.guest_departed_at && !r.departure_instructions_at) {
      r.departure_instructions_at = nowISO(); emit("reservations");
    }
    return checkoutOffer(r.id);
  };
  /** fn_departure_confirm: on the day of departure, after the instructions; the hours begun after the free hour (and
   *  after those bought) are charged as the guest leaves (W3) */
  const departureConfirm = (resId: string, via: string, atMs: number = Date.now()) => {
    const r = byId("reservations", resId);
    if (!r) throw new Error("RESERVATION_NOT_FOUND");
    if (r.status !== "checked_in") throw new Error("VALIDATION: not_in_stay");
    if (r.guest_departed_at) return { ok: true, already: true, departed_at: r.guest_departed_at };
    const { date: day, min: nowMin } = local(atMs, tzOf(r.branch_id));
    if (r.check_out > day) throw new Error("VALIDATION: not_departure_day");
    if (!r.departure_instructions_at) throw new Error("VALIDATION: instructions_first");
    const s = settings(r.branch_id);
    let late = 0, lateAmount = 0;
    if (r.check_out === day) {
      const from = Math.max(toMin(s.free_checkout_until), r.late_checkout_until ? toMin(r.late_checkout_until) : 0);
      if (nowMin > from) {
        late = Math.ceil((nowMin - from) / 60);
        const until = lateUntil(from, late);
        const cid = ctx.addCharge(r.id, "addon", `خروج متأخر ${arHours(late)} حتى ${until} (عند المغادرة)`, late, Number(s.late_hour_price_halalas), true, "غادر بعد موعد الخروج المجاني", null, r.check_out, r.check_out);
        r.late_checkout_until = until;
        ctx.recompute(r.id);
        lateAmount = T("reservation_charges").filter((c) => c.id === cid || c.base_charge_id === cid).reduce((x, c) => x + Number(c.total_halalas), 0);
      }
    }
    const at = nowISO();
    Object.assign(r, { guest_departed_at: at, guest_departed_via: via, updated_at: at }); emit("reservations");
    audit(r.branch_id, "journey.guest_departed", "reservation", r.id, { after: { via, ...(late > 0 ? { late_hours: late, late_halalas: lateAmount } : {}) } });
    const deposit = Number(r.deposit_balance_halalas ?? 0);
    alertRaise(r.branch_id, "guest_departed", "departed:" + r.id, "غادر نزيل غرفة " + (roomNo(r.room_id) ?? r.internal_ref) + " — بانتظار التحقق",
      "افحص الوحدة ثم أكمل المغادرة" + (deposit > 0 ? "، ثم رد التأمين" : "") + "." + (late > 0 ? " غادر بعد موعده: أُضيف إلى الحجز خروج متأخر " + arHours(late) + " يُحصَّل مع رصيده." : ""),
      "/staff/journey", r.id);
    return { ok: true, already: false, departed_at: at, late_hours: late, late_halalas: lateAmount };
  };
  /** fn_trg_journey_checkout: the confirmed check-out closes the departure's alert and tells the guest */
  const onCheckout = (resId: string) => {
    const r = byId("reservations", resId); if (!r) return;
    alertResolve("guest_departed", "departed:" + r.id);
    const s = settings(r.branch_id); const deposit = Number(r.deposit_balance_halalas ?? 0);
    journeySendSafe(r.id, "checkout_confirmed", "", "تم تأكيد خروجك من غرفة " + (roomNo(r.room_id) ?? "") + ". شكرًا لإقامتك معنا."
      + (deposit > 0 ? "\nيُرد تأمينك (" + sar(deposit) + ") خلال " + arHours(s.deposit_refund_hours) + ": تحويلًا إلى حسابك أو نقدًا من الاستقبال، ويصلك إيصال الرد هنا." : ""));
  };
  /** fn_trg_journey_deposit_refund: the receipt of the return goes out only once the return is recorded */
  const onDepositRefund = (v: Row | undefined) => {
    if (!v || v.kind !== "deposit_refund" || v.status !== "approved" || !v.reservation_id) return;
    journeySendSafe(v.reservation_id, "deposit_refunded", v.id, "رُد إليك تأمينك " + sar(v.amount_halalas)
      + (v.method === "bank_transfer" ? " بالتحويل" + (String(v.reference ?? "").trim() ? " (رقم العملية " + v.reference + ")" : "") : " نقدًا") + ". رقم السند " + v.number + ". شكرًا لك.");
  };

  // ---------------------------------------------------------------------------------------------------------------
  // W5 — the review
  // ---------------------------------------------------------------------------------------------------------------
  /** fn_review_invite: one invitation for a stay; its page's key is typed in the message and kept only as its hash */
  const reviewInvite = (resId: string): string => {
    const r = byId("reservations", resId);
    if (!r || T("guest_reviews").some((g) => g.reservation_id === r.id)) return "already";
    const tok = randomHex(18);
    const g = { id: uid(), organization_id: ORG, branch_id: r.branch_id, reservation_id: r.id, token_hash: hashToken(tok), invited_at: nowISO(), invite_status: null as string | null, submitted_at: null,
      overall: null, staff: null, cleanliness: null, comfort: null, facilities: null, value: null, location: null, comment: null, reply: null, replied_by: null, replied_at: null, version: 1 };
    T("guest_reviews").push(g);
    const site = demoSite().replace(/\/$/, "");
    const text = "شكرًا لإقامتك معنا. يسعدنا تقييمك في دقيقة: درجة عامة من 10 وستة جوانب.\n";
    g.invite_status = journeySendSafe(r.id, "review_invite", "", text + site + "/booking/review/…", null, text + site + "/booking/review/" + tok);
    emit("guest_reviews");
    return g.invite_status;
  };
  const reviewByToken = (token: unknown) => {
    const g = T("guest_reviews").find((x) => x.token_hash === hashToken(String(token ?? "")) && Date.parse(x.invited_at) > Date.now() - 14 * 86400_000);
    if (!g) throw new Error("TOKEN_INVALID");
    return g;
  };

  // ---------------------------------------------------------------------------------------------------------------
  // The clock of the journey (fn_journey_tick)
  // ---------------------------------------------------------------------------------------------------------------
  const tick = (branch: string, force: boolean, at: number = Date.now()) => {
    const last = T("journey_ticks").find((x) => x.branch_id === branch);
    if (!force && last && Date.parse(last.last_at) > Date.now() - 50_000) return { ran: false };
    if (last) last.last_at = nowISO(); else T("journey_ticks").push({ branch_id: branch, last_at: nowISO() });
    if (!byId("branches", branch)) return { ran: false };
    const s = settings(branch); const tz = tzOf(branch); const { date: today, min: now } = local(at, tz);
    const free = toMin(s.free_checkout_until);
    let nOptions = 0, nReviews = 0, nPaid = 0, nReleased = 0, nEsc = 0;

    // (1) the night or hours held: paid → it stands; time over → given back (before the free hour ends), or overdue
    for (const q of T("stay_extension_requests").filter((x) => x.branch_id === branch && ["held", "overdue"].includes(x.status)).sort((a, b) => (a.created_at < b.created_at ? -1 : 1))) {
      const r = byId("reservations", q.reservation_id); if (!r) continue;
      if (Number(r.balance_due_halalas ?? 0) <= 0) {
        Object.assign(q, { status: "paid", decided_at: nowISO(), version: q.version + 1 });
        alertResolve("extension_requested", "extension:" + q.id); alertResolve("extension_unpaid", "extension:" + q.id);
        journeySendSafe(q.reservation_id, "extension_confirmed", q.id, confirmedText(q.kind, q.late_until, branch));
        nPaid++;
      } else if (q.status === "held" && Date.parse(q.hold_until) < at) {
        if (r.status === "checked_in" && now < free) {
          extensionRelease(q.id, "انتهت مهلة الدفع", "released");
          const lateNow = byId("reservations", q.reservation_id)?.late_checkout_until;
          journeySendSafe(q.reservation_id, "extension_released", q.id, "انتهت مهلة الدفع فأُلغي طلب " + (q.kind === "night" ? "الليلة الإضافية" : "الخروج المتأخر")
            + ". موعد خروجك اليوم " + (lateNow ? "حتى " + hm(toMin(lateNow)) : "قبل " + hm(free)) + ". للمساعدة اطلب موظف الاستقبال.");
          nReleased++;
        } else {
          Object.assign(q, { status: "overdue", version: q.version + 1 });
          alertRaise(branch, "extension_unpaid", "extension:" + q.id, (q.kind === "night" ? "ليلة إضافية لم تُدفع" : "خروج متأخر لم يُدفع") + " — غرفة " + (roomNo(r.room_id) ?? ""),
            "انتهت مهلة الدفع بعد " + hm(free) + "؛ حصّل المبلغ أو ألغِ الطلب.", "/staff/journey", q.reservation_id);
        }
      }
    }
    emit("stay_extension_requests");

    // (2) the morning of departure: the options, once for that day (a night more makes a new day, asked again), from the
    //     message's hour until the free hour ends — not to a stay whose day is settled or that waits for a payment
    if (now >= toMin(s.checkout_message_time) && now < free) {
      const cot = toMin(byId("branches", branch)?.check_out_time ?? "12:00");
      for (const r of T("reservations").filter((x) => x.branch_id === branch && x.status === "checked_in" && x.room_id && x.check_out === today && !x.guest_departed_at && !x.checkout_choice && !x.late_checkout_until
          && !T("stay_extension_requests").some((q) => q.reservation_id === x.id && ["held", "overdue"].includes(q.status))
          && !T("journey_messages").some((m) => m.reservation_id === x.id && m.kind === "checkout_options" && m.ref_key === today))) {
        const o = checkoutOffer(r.id, at);
        const opts = [{ id: "CO:ONTIME", title: "سأخرج في الموعد (" + arRange(cot, free) + ")" }];
        if (o.night.available) opts.push({ id: "CO:NIGHT", title: "ليلة إضافية — " + sar(o.night.price_halalas ?? 0) });
        if (o.hours.max >= Math.max(o.hours.min, 1)) opts.push({ id: "CO:HOURS", title: "ساعات بعد " + o.free_until + " — " + sar(o.hours.price_halalas ?? 0) + " للساعة" });
        opts.push({ id: "HUMAN", title: "التحدث مع موظف" });
        journeySendSafe(r.id, "checkout_options", today, "صباح الخير. موعد خروجك اليوم من غرفة " + (o.room_number ?? "") + " " + arWindow(cot, free) + ". ماذا تفضّل؟", opts);
        nOptions++;
      }
    }

    // (3) one invitation to review, the delay after the confirmed check-out (within two days of it)
    for (const r of T("reservations").filter((x) => x.branch_id === branch && ["checked_out", "closed"].includes(x.status) && x.actual_check_out
        && Date.parse(x.actual_check_out) <= at - Number(s.review_delay_minutes) * 60_000 && Date.parse(x.actual_check_out) > at - 2 * 86400_000
        && !T("guest_reviews").some((g) => g.reservation_id === x.id))) {
      reviewInvite(r.id); nReviews++;
    }

    // (4) the deposit's return past its hours; closed once nothing is left to return
    for (const r of T("reservations").filter((x) => x.branch_id === branch && ["checked_out", "closed"].includes(x.status) && Number(x.deposit_balance_halalas ?? 0) > 0 && x.actual_check_out
        && Date.parse(x.actual_check_out) <= at - Number(s.deposit_refund_hours) * 3600_000 && Date.parse(x.actual_check_out) > at - 7 * 86400_000)) {
      alertRaise(branch, "deposit_overdue", "deposit:" + r.id, "تأخر رد تأمين غرفة " + (roomNo(r.room_id) ?? ""),
        "مضت " + arHours(s.deposit_refund_hours) + " على تأكيد الخروج. رد التأمين تحويلًا برقم العملية أو نقدًا من صندوق الفرع.", "/staff/journey", r.id);
    }
    for (const a of T("alert_events").filter((e) => e.branch_id === branch && !e.resolved_at)) {
      const r = a.reservation_id ? byId("reservations", a.reservation_id) : undefined;
      if (a.event === "deposit_overdue" && Number(byId("reservations", String(a.ref_key).slice(8))?.deposit_balance_halalas ?? 0) <= 0) Object.assign(a, { resolved_at: nowISO(), resolved_how: "auto" });
      if (a.event === "guest_departed" && r?.status !== "checked_in") Object.assign(a, { resolved_at: nowISO(), resolved_how: "auto" });
    }

    // (5) the alerts whose delay is over, then those nobody acted on: they climb
    for (const a of T("alert_events").filter((e) => e.branch_id === branch && !e.resolved_at && !e.notified_at && Date.parse(e.notify_at) <= at)) alertNotify(a.id, false);
    for (const a of T("alert_events").filter((e) => e.branch_id === branch && !e.resolved_at && e.notified_at && !e.escalated_at)) {
      const rl = rule(a.event);
      if (rl?.escalate_after_minutes != null && Date.parse(a.notified_at) <= at - Number(rl.escalate_after_minutes) * 60_000) { alertNotify(a.id, true); nEsc++; }
    }
    emit("alert_events");
    return { ran: true, options: nOptions, reviews: nReviews, paid: nPaid, released: nReleased, escalated: nEsc };
  };

  // ---------------------------------------------------------------------------------------------------------------
  // the stays' pages (by their key), the reception, the settings
  // ---------------------------------------------------------------------------------------------------------------
  const tokenReservation = (token: unknown): string => {
    const s = T("registration_sessions").find((x) => x.token === token);
    if (!s) throw new Error("TOKEN_INVALID");
    return s.reservation_id;
  };
  const via = (v: unknown) => { const x = v == null ? "page" : String(v); if (!["page", "whatsapp"].includes(x)) throw new Error("VALIDATION: via"); return x; };
  const journeyStaff = (branch: string) => { requireBranch(branch); if (!hasRole("owner", "manager", "supervisor")) throw new Error("FORBIDDEN: journey"); };
  const intIn = (v: unknown, re: RegExp, lo: number, hi: number, code: string) => { const t = String(v ?? ""); if (!re.test(t) || Number(t) < lo || Number(t) > hi) throw new Error("VALIDATION: " + code); return Number(t); };

  const rpcs: Record<string, (a: any) => any> = {
    // ---- the guest (anon in the server; the WhatsApp ports call the same ones)
    fn_guest_checkout: ({ p_token }) => checkoutOffer(tokenReservation(p_token)),
    fn_guest_checkout_choose: ({ p_token, p_choice, p_hours = null, p_via = "page" }) => { const v = via(p_via); return checkoutChoose(tokenReservation(p_token), p_choice, p_hours, v); },
    fn_guest_departure: ({ p_token, p_via = "page" }) => { const v = via(p_via); return departureConfirm(tokenReservation(p_token), v); },
    fn_guest_departure_instructions: ({ p_token }) => departureInstructions(tokenReservation(p_token)),
    fn_public_review: ({ p_token }) => {
      const g = reviewByToken(p_token); const r = byId("reservations", g.reservation_id);
      return { branch_name: byId("branches", g.branch_id)?.name_ar ?? null, check_in: r?.check_in ?? null, check_out: r?.check_out ?? null, submitted: !!g.submitted_at, aspects: REVIEW_ASPECTS, reply: g.reply ?? null };
    },
    fn_public_submit_review: ({ p_token, p }) => {
      const g = reviewByToken(p_token);
      if (g.submitted_at) throw new Error("VALIDATION: review_submitted");
      if (!p || typeof p !== "object" || Array.isArray(p)) throw new Error("VALIDATION: review_marks");
      for (const k of MARKS) { const t = String(p[k] ?? ""); if (!/^[0-9]{1,2}$/.test(t) || Number(t) < 1 || Number(t) > 10) throw new Error("VALIDATION: review_marks"); }
      const comment = String(p.comment ?? "").trim() || null;
      if (comment && [...comment].length > 1000) throw new Error("VALIDATION: review_comment");
      Object.assign(g, Object.fromEntries(MARKS.map((k) => [k, Number(p[k])])), { submitted_at: nowISO(), comment, version: g.version + 1 });
      emit("guest_reviews");
      const s = settings(g.branch_id);
      if (Number(p.overall) < Number(s.review_alert_below)) {
        const r = byId("reservations", g.reservation_id);
        alertRaise(g.branch_id, "review_low", "review:" + g.id, `تقييم ${Number(p.overall)} من 10 — غرفة ${roomNo(r?.room_id) ?? ""}`, comment ? comment.slice(0, 300) : "بلا تعليق", "/staff/journey", g.reservation_id);
      }
      return { ok: true };
    },
    // W7: the unit's way in or out, approved photos only; none → the reception explains
    fn_guest_unit_guide: ({ p_token, p_purpose }) => {
      const r = byId("reservations", tokenReservation(p_token))!;
      if (!["checkin", "checkout"].includes(String(p_purpose))) throw new Error("VALIDATION: purpose");
      if (!r.room_id || !["confirmed", "checked_in"].includes(r.status)) return { ready: false, purpose: p_purpose };
      const photos = unitGuide(r.room_id, p_purpose);
      return { ready: photos.length > 0, purpose: p_purpose, room_number: roomNo(r.room_id), photos };
    },

    // ---- the reception: «رحلة الضيف»
    fn_staff_journey_tick: ({ p_branch }) => {
      journeyStaff(p_branch);
      const t = tick(p_branch, false); const me = staffId();
      return { ...t, open_alerts: T("alert_events").filter((e) => e.branch_id === p_branch && !e.resolved_at && e.notified_at && alertIsMine(e.notified_to, e.escalated_to, me)).length };
    },
    fn_staff_journey: ({ p_branch }) => {
      journeyStaff(p_branch);
      const s = settings(p_branch); const today = ctx.branchToday(p_branch); const refundMs = Number(s.deposit_refund_hours) * 3600_000;
      const rooms = (r: Row) => roomNo(r.room_id); const money = ctx.seesMoney(); const me = staffId();
      return {
        settings: { journey_enabled: s.journey_enabled, checkout_message_time: hm(toMin(s.checkout_message_time)), free_until: hm(toMin(s.free_checkout_until)), refund_hours: s.deposit_refund_hours, review_alert_below: s.review_alert_below },
        sees_money: money,
        channel_ready: channelReady(p_branch),
        departing: T("reservations").filter((r) => r.branch_id === p_branch && r.status === "checked_in" && r.room_id && r.check_out <= today)
          .sort((a, b) => String(rooms(a)).localeCompare(String(rooms(b)))).map((r) => {
            const m = T("journey_messages").filter((x) => x.reservation_id === r.id && x.kind === "checkout_options").sort((a, b) => (a.created_at < b.created_at ? 1 : -1))[0];
            return { reservation_id: r.id, internal_ref: r.internal_ref, room_number: rooms(r), choice: r.checkout_choice ?? null, late_checkout_until: r.late_checkout_until ? hm(toMin(r.late_checkout_until)) : null,
              departed_at: r.guest_departed_at ?? null, message: m ? m.status + (m.reason ? ":" + m.reason : "") : null };
          }),
        requests: T("stay_extension_requests").filter((x) => x.branch_id === p_branch && (["held", "overdue"].includes(x.status) || Date.parse(x.created_at) > Date.now() - 2 * 86400_000))
          .sort((a, b) => (a.created_at < b.created_at ? 1 : -1)).map((x) => { const r = byId("reservations", x.reservation_id);
            return { id: x.id, reservation_id: x.reservation_id, internal_ref: r?.internal_ref ?? null, room_number: roomNo(r?.room_id), kind: x.kind, hours: x.hours ?? null, late_until: x.late_until ?? null,
              amount_halalas: money ? x.amount_halalas : null, status: x.status, hold_until: x.hold_until, source: x.source, created_at: x.created_at, version: x.version }; }),
        awaiting_check: T("reservations").filter((r) => r.branch_id === p_branch && r.status === "checked_in" && r.guest_departed_at)
          .sort((a, b) => (a.guest_departed_at < b.guest_departed_at ? -1 : 1)).map((r) => ({ reservation_id: r.id, internal_ref: r.internal_ref, room_number: rooms(r),
            departed_at: r.guest_departed_at, via: r.guest_departed_via ?? null, has_deposit: Number(r.deposit_balance_halalas ?? 0) > 0,
            deposit_halalas: money ? r.deposit_balance_halalas ?? 0 : null, balance_due: money ? r.balance_due_halalas ?? 0 : null })),
        deposits: T("reservations").filter((r) => r.branch_id === p_branch && ["checked_out", "closed"].includes(r.status) && Number(r.deposit_balance_halalas ?? 0) > 0 && r.actual_check_out
            && Date.parse(r.actual_check_out) > Date.now() - 30 * 86400_000)
          .sort((a, b) => (a.actual_check_out < b.actual_check_out ? -1 : 1)).map((r) => ({ reservation_id: r.id, internal_ref: r.internal_ref, room_number: rooms(r), deposit_halalas: money ? r.deposit_balance_halalas : null,
            checked_out_at: r.actual_check_out, due_at: new Date(Date.parse(r.actual_check_out) + refundMs).toISOString(), overdue: Date.parse(r.actual_check_out) + refundMs < Date.now() })),
        alerts: T("alert_events").filter((e) => e.branch_id === p_branch && !e.resolved_at).sort((a, b) => (a.created_at < b.created_at ? 1 : -1)).map((e) => ({
          id: e.id, event: e.event, label: ALERT_LABELS[e.event], title: e.title, body: e.body, link: e.link, created_at: e.created_at, notify_at: e.notify_at, notified_at: e.notified_at,
          notified_to: e.notified_to, escalated_at: e.escalated_at, escalated_to: e.escalated_to, mine: !!e.notified_at && alertIsMine(e.notified_to, e.escalated_to, me) })),
      };
    },
    fn_staff_extension_decide: ({ p_request, p_action, p_reason, p_expected_version }) => {
      requireCap("stay.extend");
      const q = T("stay_extension_requests").find((x) => x.id === p_request && x.organization_id === ORG);
      if (!q) throw new Error("NOT_FOUND");
      requireBranch(q.branch_id);
      if (!["confirm", "release"].includes(String(p_action))) throw new Error("VALIDATION: action");
      const reason = String(p_reason ?? "").trim();
      if (!reason || [...reason].length > 300) throw new Error("VALIDATION: reason");
      ctx.checkVersion(q.version, p_expected_version);
      if (!["held", "overdue"].includes(q.status)) throw new Error("VALIDATION: extension_status");
      if (p_action === "confirm") {
        const was = q.status;
        Object.assign(q, { status: "confirmed", decided_at: nowISO(), decided_by: staffId(), decision_reason: reason, version: q.version + 1 }); emit("stay_extension_requests");
        alertResolve("extension_requested", "extension:" + q.id); alertResolve("extension_unpaid", "extension:" + q.id);
        audit(q.branch_id, "journey.extension_confirmed", "extension_request", q.id, { before: { status: was }, after: { status: "confirmed", kind: q.kind, amount_halalas: q.amount_halalas }, reason });
        // the guest is told it stands, as when it is paid
        journeySendSafe(q.reservation_id, "extension_confirmed", q.id, confirmedText(q.kind, q.late_until, q.branch_id));
      } else extensionRelease(q.id, reason, "released");
      return { ok: true, status: q.status };
    },
    fn_staff_alert_resolve: ({ p_alert, p_note }) => {
      const a = T("alert_events").find((x) => x.id === p_alert && x.organization_id === ORG);
      if (!a) throw new Error("NOT_FOUND");
      requireBranch(a.branch_id);
      if (!hasRole("owner", "manager", "supervisor")) throw new Error("FORBIDDEN: journey");
      if (a.resolved_at) return { ok: true, already: true };
      Object.assign(a, { resolved_at: nowISO(), resolved_by: staffId(), resolved_how: "staff" }); emit("alert_events");
      audit(a.branch_id, "alert.resolved", "alert_event", a.id, { after: { event: a.event, title: a.title }, reason: String(p_note ?? "").trim() || null });
      return { ok: true, already: false };
    },
    fn_staff_reviews: ({ p_branch, p_days = 30 }) => {
      requireCap("conversation.take"); requireBranch(p_branch);
      const days = Number(p_days);
      if (p_days == null || !Number.isInteger(days) || days < 1 || days > 365) throw new Error("VALIDATION: days");
      const s = settings(p_branch); const since = Date.now() - days * 86400_000;
      const done = T("guest_reviews").filter((g) => g.branch_id === p_branch && g.submitted_at && Date.parse(g.submitted_at) > since);
      const avg = (k: string) => (done.length ? Math.round((done.reduce((x, g) => x + Number(g[k]), 0) / done.length) * 10) / 10 : null);
      return {
        aspects: REVIEW_ASPECTS, alert_below: s.review_alert_below,
        summary: { count: done.length, ...Object.fromEntries(MARKS.map((k) => [k, avg(k)])), below: done.filter((g) => g.overall < s.review_alert_below).length },
        invited: T("guest_reviews").filter((g) => g.branch_id === p_branch && Date.parse(g.invited_at) > since).length,
        reviews: done.sort((a, b) => (a.submitted_at < b.submitted_at ? 1 : -1)).map((g) => { const r = byId("reservations", g.reservation_id);
          return { id: g.id, reservation_id: g.reservation_id, internal_ref: r?.internal_ref ?? null, room_number: roomNo(r?.room_id), submitted_at: g.submitted_at,
            ...Object.fromEntries(MARKS.map((k) => [k, g[k]])), comment: g.comment, reply: g.reply, replied_at: g.replied_at, version: g.version }; }),
      };
    },
    fn_staff_review_reply: ({ p_review, p_reply, p_expected_version }) => {
      requireCap("conversation.take");
      const g = T("guest_reviews").find((x) => x.id === p_review && x.organization_id === ORG);
      if (!g) throw new Error("NOT_FOUND");
      requireBranch(g.branch_id);
      ctx.checkVersion(g.version, p_expected_version);
      if (!g.submitted_at) throw new Error("VALIDATION: review_not_submitted");
      if (g.reply) throw new Error("VALIDATION: review_replied");
      const reply = String(p_reply ?? "").trim();
      if (!reply || [...reply].length > 1000) throw new Error("VALIDATION: review_reply");
      Object.assign(g, { reply, replied_by: staffId(), replied_at: nowISO(), version: g.version + 1 }); emit("guest_reviews");
      alertResolve("review_low", "review:" + g.id);
      audit(g.branch_id, "review.replied", "guest_review", g.id, { after: { overall: g.overall, reply } });
      journeySendSafe(g.reservation_id, "review_reply", g.id, "شكرًا لتقييمك. رد الإدارة:\n" + reply);
      return { ok: true };
    },

    // ---- the settings («رحلة الضيف» in the administration)
    fn_admin_journey_settings: ({ p_branch }) => {
      requireCap("branch.settings"); requireBranch(p_branch);
      const s = settings(p_branch);
      return {
        branch_id: p_branch, journey_enabled: s.journey_enabled, checkout_message_time: hm(toMin(s.checkout_message_time)), free_checkout_until: hm(toMin(s.free_checkout_until)),
        late_hour_price_halalas: s.late_hour_price_halalas, cleaning_buffer_minutes: s.cleaning_buffer_minutes, hold_minutes: s.hold_minutes, checkout_instructions: s.checkout_instructions ?? null,
        deposit_refund_hours: s.deposit_refund_hours, review_delay_minutes: s.review_delay_minutes, review_alert_below: s.review_alert_below,
        responsible_staff_id: s.responsible_staff_id ?? null, fallback_staff_id: s.fallback_staff_id ?? null, version: s.version,
        channel_ready: channelReady(p_branch), guest_site_url: byId("organizations", ORG)?.guest_site_url ?? null,
        staff: T("staff_profiles").filter((sp) => sp.organization_id === ORG && sp.is_active && ["owner", "manager", "supervisor"].includes(sp.role)
            && (sp.role === "owner" || T("branch_memberships").some((m) => m.staff_id === sp.id && m.branch_id === p_branch && !m.removed_at)))
          .sort((a, b) => String(a.role).localeCompare(String(b.role)) || String(a.full_name).localeCompare(String(b.full_name), "ar"))
          .map((sp) => ({ id: sp.id, name: sp.full_name, role: sp.role, has_phone: !!ctx.normPhone(sp.phone) })),
      };
    },
    fn_admin_journey_settings_save: ({ p_branch, p }) => {
      requireCap("branch.settings"); requireBranch(p_branch);
      const cur = settings(p_branch); const q: Row = p ?? {};
      ctx.checkVersion(cur.version, q.version == null || q.version === "" ? null : Number(q.version));
      const s: Row = { ...cur };
      if ("journey_enabled" in q) { if (typeof q.journey_enabled !== "boolean") throw new Error("VALIDATION: journey_enabled"); s.journey_enabled = q.journey_enabled; }
      for (const k of ["checkout_message_time", "free_checkout_until"]) if (k in q) { if (!HHMM.test(String(q[k] ?? ""))) throw new Error("VALIDATION: journey_time"); s[k] = q[k]; }
      if (toMin(s.free_checkout_until) <= toMin(s.checkout_message_time)) throw new Error("VALIDATION: journey_time");
      if (toMin(s.free_checkout_until) < toMin(byId("branches", p_branch)?.check_out_time)) throw new Error("VALIDATION: free_checkout_until");
      if ("late_hour_price_halalas" in q) s.late_hour_price_halalas = intIn(q.late_hour_price_halalas, /^[0-9]{1,7}$/, 0, 1_000_000, "amount");
      if ("cleaning_buffer_minutes" in q) s.cleaning_buffer_minutes = intIn(q.cleaning_buffer_minutes, /^[0-9]{1,3}$/, 0, 240, "cleaning_buffer");
      if ("hold_minutes" in q) s.hold_minutes = intIn(q.hold_minutes, /^[0-9]{1,3}$/, 5, 240, "hold_minutes");
      if ("checkout_instructions" in q) { const v = String(q.checkout_instructions ?? "").trim() || null; if (v && [...v].length > 1500) throw new Error("VALIDATION: checkout_instructions"); s.checkout_instructions = v; }
      if ("deposit_refund_hours" in q) s.deposit_refund_hours = intIn(q.deposit_refund_hours, /^[0-9]{1,2}$/, 1, 72, "refund_hours");
      if ("review_delay_minutes" in q) s.review_delay_minutes = intIn(q.review_delay_minutes, /^[0-9]{1,4}$/, 10, 1440, "review_delay");
      if ("review_alert_below" in q) s.review_alert_below = intIn(q.review_alert_below, /^[0-9]{1,2}$/, 1, 10, "review_alert_below");
      for (const k of ["responsible_staff_id", "fallback_staff_id"]) if (k in q) {
        let v: string | null = null;
        if (String(q[k] ?? "")) {
          if (!UUID.test(String(q[k]))) throw new Error("VALIDATION: journey_staff");
          const sp = T("staff_profiles").find((x) => x.id === q[k] && x.organization_id === ORG && x.is_active && ["owner", "manager", "supervisor"].includes(x.role)
            && (k === "fallback_staff_id" || x.role === "owner" || T("branch_memberships").some((m) => m.staff_id === x.id && m.branch_id === p_branch && !m.removed_at)));
          if (!sp) throw new Error("VALIDATION: journey_staff");
          v = sp.id;
        }
        s[k] = v;
      }
      const strip = (x: Row) => { const { updated_at: _a, updated_by: _b, version: _c, ...rest } = x; return rest; };
      const before = strip(cur);
      Object.assign(cur, s, { version: cur.version + 1, updated_by: staffId(), updated_at: nowISO() }); emit("branch_journey_settings");
      audit(p_branch, "journey.settings_changed", "journey_settings", p_branch, { before, after: strip(cur) });
      return { ok: true, version: cur.version };
    },
    fn_admin_alert_rules: () => {
      requireCap("branch.settings");
      return rules().slice().sort((a, b) => ALERT_EVENTS.indexOf(a.event) - ALERT_EVENTS.indexOf(b.event)).map((r) => ({
        event: r.event, label: ALERT_LABELS[r.event], enabled: r.enabled, recipients: r.recipients, channel: r.channel, delay_minutes: r.delay_minutes,
        escalate_after_minutes: r.escalate_after_minutes, escalate_to: r.escalate_to, version: r.version }));
    },
    fn_admin_alert_rule_save: ({ p_event, p }) => {
      if (!hasRole("owner")) throw new Error("FORBIDDEN: owner only");
      const rl = rule(String(p_event)); if (!rl) throw new Error("NOT_FOUND");
      const q: Row = p ?? {};
      ctx.checkVersion(rl.version, q.version == null || q.version === "" ? null : Number(q.version));
      const next: Row = { ...rl };
      if ("enabled" in q) { if (typeof q.enabled !== "boolean") throw new Error("VALIDATION: alert_rule"); next.enabled = q.enabled; }
      if ("recipients" in q) {
        if (!Array.isArray(q.recipients)) throw new Error("VALIDATION: alert_recipients");
        const v = [...new Set(q.recipients.map(String))].sort();
        if (v.length < 1 || v.length > 5 || v.some((x) => !RECIPIENTS.includes(x))) throw new Error("VALIDATION: alert_recipients");
        next.recipients = v;
      }
      if ("channel" in q) { if (!["app", "whatsapp", "both"].includes(String(q.channel ?? ""))) throw new Error("VALIDATION: alert_channel"); next.channel = q.channel; }
      if ("delay_minutes" in q) next.delay_minutes = intIn(q.delay_minutes, /^[0-9]{1,4}$/, 0, 1440, "alert_delay");
      if ("escalate_after_minutes" in q) next.escalate_after_minutes = q.escalate_after_minutes === null ? null : intIn(q.escalate_after_minutes, /^[0-9]{1,4}$/, 1, 1440, "alert_escalation");
      if ("escalate_to" in q) { if (!["fallback", "owner"].includes(String(q.escalate_to ?? ""))) throw new Error("VALIDATION: alert_escalation"); next.escalate_to = q.escalate_to; }
      const strip = (x: Row) => { const { updated_at: _a, updated_by: _b, version: _c, ...rest } = x; return rest; };
      const before = strip(rl);
      Object.assign(rl, next, { version: rl.version + 1, updated_by: staffId(), updated_at: nowISO() }); emit("alert_rules");
      audit(null, "alert_rule.changed", "alert_rule", null as unknown as string, { before, after: { ...strip(rl), label: ALERT_LABELS[rl.event] } });
      return { ok: true, version: rl.version };
    },
    fn_admin_set_guest_site: ({ p_url }) => {
      if (!hasRole("owner")) throw new Error("FORBIDDEN: owner only");
      const v = String(p_url ?? "").trim().replace(/\/+$/, "") || null;
      if (v && (!ctx.validHttpsUrl(v) || v.length > 200)) throw new Error("VALIDATION: guest_site_url");
      const o = byId("organizations", ORG)!; const before = o.guest_site_url ?? null;
      o.guest_site_url = v; emit("organizations");
      audit(null, "journey.site_changed", "organization", ORG, { before: { guest_site_url: before }, after: { guest_site_url: v } });
      return { ok: true };
    },

    // ---- 0072: what «مسح كل بيانات التجربة» would take, counted without taking anything
    fn_admin_trial_overview: () => {
      requireCap("security");
      const res = T("reservations");
      const days = res.flatMap((r) => [r.check_in, String(r.created_at ?? "").slice(0, 10)]).filter(Boolean).sort();
      return {
        first_day: days[0] ?? null, reservations: res.length,
        in_house_or_upcoming: res.filter((r) => ["checked_in", "confirmed", "pending_verification", "draft"].includes(r.status) && r.check_out >= ctx.branchToday(r.branch_id)).length,
        vouchers: T("financial_vouchers").length, expenses: T("expense_vouchers").length, journal_entries: T("journal_entries").filter((e) => e.source_type !== "opening").length,
        bank_movements: T("bank_movements").length, product_orders: T("product_orders").length, sample_products: T("products").filter((x) => x.is_sample).length,
        guests_trial: T("guest_profiles").filter((g) => !g.imported_at).length, guests_imported: T("guest_profiles").filter((g) => g.imported_at).length,
        paste_applied: true,
      };
    },
  };

  return {
    rpcs,
    tick,
    /** fn_checkout_choose with the clock read at another hour (the checks) */
    checkoutChooseAt: checkoutChoose,
    checkoutOfferAt: checkoutOffer,
    departureConfirmAt: departureConfirm,
    onCheckout,
    onDepositRefund,
    /** after every call, what the SQL does by trigger: a product order waiting for its payment, a guest asking for staff */
    sync: () => {
      const fresh = (iso: unknown) => Date.now() - Date.parse(String(iso ?? "")) < 10 * 60_000;
      for (const o of T("product_orders")) {
        if (o.status === "pending_payment" && fresh(o.created_at) && !T("alert_events").some((a) => a.event === "product_order" && a.ref_key === "order:" + o.id)) {
          const room = o.reservation_id ? roomNo(byId("reservations", o.reservation_id)?.room_id) : null;
          alertRaise(o.branch_id, "product_order", "order:" + o.id, "طلب منتجات بانتظار الدفع — " + o.number + (room ? " — غرفة " + room : ""), "تسلّم الدفع ليُصدر السند وتُنشأ مهمة التسليم.", "/staff/orders", o.reservation_id ?? null);
        } else if (o.status !== "pending_payment" && T("alert_events").some((a) => a.event === "product_order" && a.ref_key === "order:" + o.id && !a.resolved_at)) alertResolve("product_order", "order:" + o.id);
      }
      for (const t of T("human_handoff_tickets")) {
        if (!t.branch_id) continue;
        if (t.status === "open" && fresh(t.created_at) && !T("alert_events").some((a) => a.event === "guest_handoff" && a.ref_key === "handoff:" + t.id)) {
          const d = typeof t.details === "object" && t.details ? (t.details.reason ?? t.details.message) : t.details;
          alertRaise(t.branch_id, "guest_handoff", "handoff:" + t.id, "نزيل يطلب موظفًا" + (t.source_name ? " — " + t.source_name : ""), String(d ?? t.kind ?? "").slice(0, 300), "/staff/inbox", t.reservation_id ?? null);
        } else if (t.status !== "open" && T("alert_events").some((a) => a.event === "guest_handoff" && a.ref_key === "handoff:" + t.id && !a.resolved_at)) alertResolve("guest_handoff", "handoff:" + t.id);
      }
    },
    staffName,
  };
}
