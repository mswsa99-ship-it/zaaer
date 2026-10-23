/**
 * whatsapp-webhook — the whole guest reception inside WhatsApp, one number per branch.
 *
 * GET  ?hub.mode=subscribe&hub.verify_token=…&hub.challenge=…   Meta's subscription check (the branch's verify token)
 * POST (Meta)                                                    guest messages, signed with the branch's app secret
 *
 * For each guest message (each WhatsApp message id is handled once — Meta retries):
 *   - the sender number is the guest's verified phone: "حجوزاتي" lists the bookings on it, one tap opens one, and a
 *     guest with exactly one current booking is recognised from the first message (no code, no booking number)
 *   - everything else goes to ai-reception (same guardrails, tools, knowledge base and handoff as the website), and its
 *     answer comes back as WhatsApp buttons, a list, or links to the secure pages (status/key code, guest registration)
 *   - identity documents and card numbers are never taken in the chat; only text is read
 * The answer to Meta is immediate (200); the reply is sent in the background.
 */
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import {
  BTN, buttonsPayload, listPayload, parseInbound, shortDate, textPayload, toWhatsAppMessage, usable, verifySignature, waSend,
  type WaChannel, type WaInbound,
} from "../_shared/whatsapp.ts";
import { gateInput } from "../_shared/guardrails.ts";

const STATUS_AR: Record<string, string> = {
  draft: "مسودة", pending_verification: "بانتظار التحقق", confirmed: "مؤكد", checked_in: "تم الدخول", checked_out: "تمت المغادرة",
  closed: "مغلق", cancelled: "ملغى", rejected: "مرفوض", no_show: "عدم حضور",
};
const CURRENT = new Set(["draft", "pending_verification", "confirmed", "checked_in"]);
const THREAD_HOURS = 24;

interface Booking { ref: string; internal_ref: string; status: string; check_in: string; check_out: string; nights: number; branch_name?: string; category_name?: string }

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  // ---- Meta's subscription check ----
  if (req.method === "GET") {
    const token = url.searchParams.get("hub.verify_token") ?? "";
    if (url.searchParams.get("hub.mode") !== "subscribe" || token.length < 16) return new Response("forbidden", { status: 403 });
    const { data: ch } = await db.rpc("fn_whatsapp_channel", { p_verify_token: token });
    if (!ch) return new Response("forbidden", { status: 403 });
    return new Response(url.searchParams.get("hub.challenge") ?? "", { status: 200, headers: { "content-type": "text/plain" } });
  }
  if (req.method !== "POST") return new Response("method", { status: 405 });

  const raw = await req.text();
  let body: unknown;
  try { body = JSON.parse(raw); } catch { return new Response("bad json", { status: 400 }); }
  const phoneNumberId = String((body as any)?.entry?.[0]?.changes?.[0]?.value?.metadata?.phone_number_id ?? ""); // deno-lint-ignore no-explicit-any
  if (!phoneNumberId) return new Response("ok");
  const { data: chData } = await db.rpc("fn_whatsapp_channel", { p_phone_number_id: phoneNumberId });
  const channel = chData as WaChannel | null;
  if (!channel) return new Response("ok");                       // a number this system does not manage
  if (!(await verifySignature(channel.app_secret ?? "", raw, req.headers.get("x-hub-signature-256")))) {
    return new Response("bad signature", { status: 401 });
  }
  if (channel.status === "configured") await db.rpc("fn_whatsapp_mark", { p_branch: channel.branch_id, p_status: "active" });
  if (!usable(channel)) return new Response("ok");                // switched off by the owner: nothing is answered

  const messages = parseInbound(body).filter((m) => m.phoneNumberId === phoneNumberId);
  const work = (async () => { for (const m of messages) { try { await handle(db, channel, m); } catch (e) { console.error("wa handle", String(e).slice(0, 200)); } } })();
  const rt = (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } }).EdgeRuntime;
  if (rt?.waitUntil) rt.waitUntil(work); else await work;
  return new Response("ok");
});

// deno-lint-ignore no-explicit-any
type Db = any;

async function handle(db: Db, ch: WaChannel, m: WaInbound) {
  // each WhatsApp message once (Meta re-delivers when an answer is slow)
  const { error: dup } = await db.from("whatsapp_inbound_messages").insert({ wa_message_id: m.id, branch_id: ch.branch_id });
  if (dup) return;

  const appBaseUrl = (Deno.env.get("APP_BASE_URL") ?? "").replace(/\/$/, "");
  const send = async (payload: Record<string, unknown>) => {
    const r = await waSend(ch, payload);
    if (!r.ok) {
      await db.from("integration_events").insert({ organization_id: ch.organization_id, source: "whatsapp", external_event_id: m.id, kind: "whatsapp.outbound",
        reference: "••••" + m.from.slice(-4), state: "rejected", result: { error: r.error, code: r.code, branch_id: ch.branch_id } });
      if (r.status === 401 || r.code === 190) await db.rpc("fn_whatsapp_mark", { p_branch: ch.branch_id, p_status: "error", p_error: r.error ?? "auth" });
    }
    return r;
  };

  // ---- the guest's thread with this branch (a new one after a day of silence) ----
  const since = new Date(Date.now() - THREAD_HOURS * 3600_000).toISOString();
  const { data: open } = await db.from("conversations").select("id, guest_token, status")
    .eq("branch_id", ch.branch_id).eq("wa_contact", m.from).neq("status", "closed").gte("last_message_at", since)
    .order("last_message_at", { ascending: false }).limit(1).maybeSingle();
  let conv: { id: string; guest_token: string | null; status: string } | null = open;
  const newThread = async () => {
    const { data } = await db.from("conversations").insert({ channel: "whatsapp", status: "active", branch_id: ch.branch_id, wa_contact: m.from, client_fingerprint: "wa:" + m.from.slice(-4), last_message_at: new Date().toISOString() })
      .select("id, guest_token, status").single();
    return data as { id: string; guest_token: string | null; status: string };
  };
  const fresh = !conv;
  if (!conv) conv = await newThread();

  const saveGuest = (content: string) => db.from("conversation_messages").insert({ conversation_id: conv!.id, sender: "guest", content: gateInput(content).redacted, meta: { channel: "whatsapp", wa_type: m.type } });
  const saveBot = (content: string, extra: Record<string, unknown> = {}) => db.from("conversation_messages").insert({ conversation_id: conv!.id, sender: "assistant", content, meta: { mode: "scripted", channel: "whatsapp", ...extra } });
  const touch = () => db.from("conversations").update({ last_message_at: new Date().toISOString() }).eq("id", conv!.id);

  // ---- bookings on the sender's number (WhatsApp has verified the number) ----
  const bookings = async (): Promise<{ token: string; list: Booking[] }> => {
    const { data: token } = await db.rpc("fn_whatsapp_phone_session", { p_phone: m.from });
    const { data } = await db.rpc("fn_guest_phone_reservations", { p_token: token });
    return { token, list: ((data?.reservations ?? []) as Booking[]) };
  };
  const bind = async (token: string, b: Booking, announce: boolean, many: boolean) => {
    const { data, error } = await db.rpc("fn_guest_phone_open", { p_token: token, p_internal_ref: b.internal_ref });
    if (error || !data?.token) return false;
    await db.from("conversations").update({ guest_token: data.token, last_message_at: new Date().toISOString() }).eq("id", conv!.id);
    conv!.guest_token = data.token;
    if (announce) {
      const lines = [
        `حجزك ${b.ref}${b.category_name ? ` — ${b.category_name}` : ""}`,
        `من ${shortDate(b.check_in)} إلى ${shortDate(b.check_out)} (${b.nights} ${b.nights === 1 ? "ليلة" : "ليالٍ"}) · ${STATUS_AR[b.status] ?? b.status}`,
        "",
        appBaseUrl ? `• حالة الحجز ورمز الدخول: ${appBaseUrl}/booking/status/${data.token}` : "",
        appBaseUrl ? `• تسجيل بيانات النزلاء (الهوية تُدخل هناك فقط): ${appBaseUrl}/booking/registration/${data.token}` : "",
        "",
        "اسألني هنا عن السداد أو الوصول أو أي شيء يخص إقامتك.",
      ].filter((l, i, a) => l !== "" || (a[i - 1] ?? "") !== "").join("\n");
      const btns = [{ id: "SAY:لقد وصلت وأرغب بتسجيل الدخول", title: "وصلت" }, { id: BTN.HUMAN, title: "التحدث مع موظف" }];
      if (many) btns.push({ id: BTN.BOOKINGS, title: "حجوزاتي" });
      await send(buttonsPayload(m.from, lines, btns));
      await saveBot(lines.replace(/\/booking\/(status|registration)\/[A-Za-z0-9]+/g, "/booking/$1/…"), { bound: b.internal_ref });
    }
    return true;
  };
  const showBookings = async () => {
    const { token, list } = await bookings();
    if (list.length === 0) {
      const t = `لا توجد حجوزات على رقم واتساب هذا (المنتهي بـ ${m.from.slice(-4)}). إن كان حجزك برقم آخر فاطلب موظف الاستقبال، أو احجز الآن.`;
      await send(buttonsPayload(m.from, t, [{ id: BTN.BOOK, title: "احجز الآن" }, { id: BTN.HUMAN, title: "التحدث مع موظف" }]));
      await saveBot(t);
    } else if (list.length === 1) {
      await bind(token, list[0], true, false);
    } else {
      const t = `لديك ${list.length === 2 ? "حجزان" : `${list.length} حجوزات`} على هذا الرقم. اختر الحجز:`;
      await send(listPayload(m.from, t, "اختر الحجز", list.map((b) => ({
        id: "OPEN:" + b.internal_ref, title: b.category_name ?? b.ref,
        description: `${shortDate(b.check_in)} → ${shortDate(b.check_out)} · ${STATUS_AR[b.status] ?? b.status}${b.branch_name ? ` · ${b.branch_name}` : ""}`,
      }))));
      await saveBot(t);
    }
  };

  // ---- not text: say what works (and never take documents in the chat) ----
  if (!["text", "interactive", "button"].includes(m.type)) {
    await saveGuest(`[${m.type}]`);
    const t = "أقرأ الرسائل النصية فقط. لا ترسل صور الهوية أو البطاقات هنا؛ بيانات النزلاء تُدخل عبر الرابط الآمن الذي أرسله لك.";
    await send(buttonsPayload(m.from, t, [{ id: BTN.BOOKINGS, title: "حجوزاتي" }, { id: BTN.HUMAN, title: "التحدث مع موظف" }]));
    await saveBot(t); await touch();
    return;
  }

  const id = m.replyId ?? "";
  const typed = m.text.trim();
  if (id === BTN.NEW) {
    await db.from("conversations").update({ status: "closed" }).eq("id", conv.id);
    conv = await newThread();
    return forward(db, ch, m, conv, "مرحبا", send, appBaseUrl);
  }
  if (id === BTN.BOOKINGS || /^(حجوزاتي|حجزي|حجوزات|my bookings?)$/i.test(typed)) {
    await saveGuest(typed || "حجوزاتي");
    await showBookings(); await touch();
    return;
  }
  if (id.startsWith("OPEN:")) {
    await saveGuest(typed);
    const { token, list } = await bookings();
    const b = list.find((x) => x.internal_ref === id.slice(5));
    if (!b || !(await bind(token, b, true, list.length > 1))) { const t = "تعذر فتح هذا الحجز. اختر من «حجوزاتي» مرة أخرى."; await send(textPayload(m.from, t)); await saveBot(t); }
    await touch();
    return;
  }
  if (id === BTN.BOOK) {
    await saveGuest(typed || "احجز الآن");
    const t = appBaseUrl ? `اختر يوم الوصول وعدد الليالي والأشخاص، وتظهر لك الأسعار المتاحة فورًا:\n${appBaseUrl}/booking/new` : "الحجز الجديد متاح عبر منصات الحجز المعتمدة.";
    await send(textPayload(m.from, t)); await saveBot(t); await touch();
    return;
  }

  // a guest with exactly one current booking is recognised from the first message of a thread
  if (!conv.guest_token && fresh) {
    const { token, list } = await bookings();
    const current = list.filter((b) => CURRENT.has(b.status));
    if (current.length === 1) await bind(token, current[0], false, false);
  }
  const message = id === BTN.HUMAN ? "أرغب بالتحدث مع موظف الاستقبال" : id.startsWith("SAY:") ? id.slice(4) : typed;
  if (!message) return;
  return forward(db, ch, m, conv, message, send, appBaseUrl);
}

/** The same assistant as the website (ai-reception), answering on WhatsApp. */
async function forward(db: Db, ch: WaChannel, m: WaInbound, conv: { id: string; guest_token: string | null }, message: string,
  send: (p: Record<string, unknown>) => Promise<unknown>, appBaseUrl: string) {
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  let reply = ""; let actions: Array<{ label: string; route?: string; value?: string }> = [];
  try {
    const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/ai-reception`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${key}`, apikey: key },
      body: JSON.stringify({ message, conversation_id: conv.id, guest_token: conv.guest_token, branch_id: ch.branch_id, channel: "whatsapp", client_fingerprint: "wa:" + m.from }),
      signal: AbortSignal.timeout(25000),
    });
    const out = await res.json();
    reply = String(out?.reply ?? ""); actions = Array.isArray(out?.actions) ? out.actions : [];
  } catch { /* answered below */ }
  if (!reply) {
    reply = "عذرًا، تعذر الرد الآن. حاول بعد قليل أو اطلب موظف الاستقبال.";
    actions = [{ label: "التحدث مع موظف", value: "أرغب بالتحدث مع موظف الاستقبال" }];
    await db.from("conversation_messages").insert({ conversation_id: conv.id, sender: "assistant", content: reply, meta: { mode: "scripted", channel: "whatsapp", reason: "assistant_unreachable" } });
  }
  await send(toWhatsAppMessage(m.from, reply, actions, appBaseUrl));
}
