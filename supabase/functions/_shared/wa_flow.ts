/**
 * The guest's WhatsApp conversation with a branch — the whole flow, independent of where it runs.
 *
 * whatsapp-webhook runs it against the database and the WhatsApp Cloud API; the demo runs the very same code against
 * its in-browser store (the WhatsApp simulator), and the unit tests run it against fakes. Everything the flow needs
 * from the outside world goes through `WaFlowPorts`.
 *
 * For each guest message:
 *   - the sender number is the guest's verified phone (WhatsApp has verified it): «حجوزاتي» lists the bookings on it,
 *     one tap opens one, and a guest with exactly one current booking is recognised from the first message of a thread
 *   - everything else goes to the reception assistant (ai-reception: same guardrails, tools, knowledge base and
 *     handoff as everywhere), and its answer comes back as buttons, a list, or links to the secure pages
 *   - identity documents and card numbers are never taken in the chat; only text is read
 */
import { BTN, buttonsPayload, listPayload, shortDate, textPayload, toWhatsAppMessage, type AssistantAction, type WaInbound } from "./whatsapp.ts";
import { gateInput } from "./guardrails.ts";

export const WA_STATUS_AR: Record<string, string> = {
  draft: "مسودة", pending_verification: "بانتظار التحقق", confirmed: "مؤكد", checked_in: "تم الدخول", checked_out: "تمت المغادرة",
  closed: "مغلق", cancelled: "ملغى", rejected: "مرفوض", no_show: "عدم حضور",
};
/** stays a guest can still act on: these are recognised automatically from the first message */
const CURRENT = new Set(["draft", "pending_verification", "confirmed", "checked_in"]);
/** a thread is the guest's conversation with one branch; after this long without messages a new one starts */
export const WA_THREAD_HOURS = 24;

export interface WaBooking {
  ref: string; internal_ref: string; status: string; check_in: string; check_out: string; nights: number;
  branch_name?: string | null; category_name?: string | null;
}
export interface WaThread { id: string; guest_token: string | null }
export interface WaAssistantAnswer { reply: string; actions: AssistantAction[] }

export interface WaFlowPorts {
  /** the website's address for links (status page, guest registration, new booking); "" → no links are sent */
  appBaseUrl: string;
  /** the sender's open thread with this branch (a message in the last WA_THREAD_HOURS), or null */
  findThread(): Promise<WaThread | null>;
  newThread(): Promise<WaThread>;
  closeThread(threadId: string): Promise<void>;
  /** marks activity on the thread (last_message_at) */
  touch(threadId: string): Promise<void>;
  save(threadId: string, sender: "guest" | "assistant", content: string, meta: Record<string, unknown>): Promise<void>;
  /** the bookings on the sender's number, with a phone session that may open them */
  bookings(): Promise<{ token: string; list: WaBooking[] }>;
  /** opens one booking of that session → the guest token of /booking/status and /booking/registration, or null */
  openBooking(sessionToken: string, internalRef: string): Promise<string | null>;
  /** binds the thread to that booking (the assistant then answers about it) */
  bindThread(threadId: string, guestToken: string): Promise<void>;
  /** the reception assistant for a free-text message; null when it could not be reached */
  ask(thread: WaThread, message: string): Promise<WaAssistantAnswer | null>;
  /** one WhatsApp message (Cloud API payload without messaging_product) */
  send(payload: Record<string, unknown>): Promise<unknown>;
}

export const WA_TEXTS = {
  textOnly: "أقرأ الرسائل النصية فقط. لا ترسل صور الهوية أو البطاقات هنا؛ بيانات النزلاء تُدخل عبر الرابط الآمن الذي أرسله لك.",
  openFailed: "تعذر فتح هذا الحجز. اختر من «حجوزاتي» مرة أخرى.",
  unreachable: "عذرًا، تعذر الرد الآن. حاول بعد قليل أو اطلب موظف الاستقبال.",
  human: "أرغب بالتحدث مع موظف الاستقبال",
  arrived: "لقد وصلت وأرغب بتسجيل الدخول",
  bookingsWord: /^(حجوزاتي|حجزي|حجوزات|my bookings?)$/i,
};

const nightsAr = (n: number) => (n === 1 ? "ليلة" : "ليالٍ");

export async function runWaFlow(m: WaInbound, p: WaFlowPorts): Promise<void> {
  const base = p.appBaseUrl.replace(/\/$/, "");
  let thread = await p.findThread();
  const fresh = !thread;
  if (!thread) thread = await p.newThread();
  const t: WaThread = thread;

  const saveGuest = (content: string) => p.save(t.id, "guest", gateInput(content).redacted, { channel: "whatsapp", wa_type: m.type });
  const saveBot = (content: string, extra: Record<string, unknown> = {}) => p.save(t.id, "assistant", content, { mode: "scripted", channel: "whatsapp", ...extra });

  // ---- open one booking of the sender's number and (optionally) tell the guest what they can do with it ----
  const bind = async (token: string, b: WaBooking, announce: boolean, many: boolean): Promise<boolean> => {
    const guestToken = await p.openBooking(token, b.internal_ref);
    if (!guestToken) return false;
    await p.bindThread(t.id, guestToken);
    t.guest_token = guestToken;
    if (announce) {
      const lines = [
        `حجزك ${b.ref}${b.category_name ? ` — ${b.category_name}` : ""}`,
        `من ${shortDate(b.check_in)} إلى ${shortDate(b.check_out)} (${b.nights} ${nightsAr(b.nights)}) · ${WA_STATUS_AR[b.status] ?? b.status}`,
        "",
        base ? `• حالة الحجز ورمز الدخول: ${base}/booking/status/${guestToken}` : "",
        base ? `• تسجيل بيانات النزلاء (الهوية تُدخل هناك فقط): ${base}/booking/registration/${guestToken}` : "",
        "",
        "اسألني هنا عن السداد أو الوصول أو أي شيء يخص إقامتك.",
      ].filter((l, i, a) => l !== "" || (a[i - 1] ?? "") !== "").join("\n");
      const btns = [{ id: "SAY:" + WA_TEXTS.arrived, title: "وصلت" }, { id: BTN.HUMAN, title: "التحدث مع موظف" }];
      if (many) btns.push({ id: BTN.BOOKINGS, title: "حجوزاتي" });
      await p.send(buttonsPayload(m.from, lines, btns));
      // the stored copy never keeps the tokens of the secure pages
      await saveBot(lines.replace(/\/booking\/(status|registration)\/[A-Za-z0-9]+/g, "/booking/$1/…"), { bound: b.internal_ref });
    }
    return true;
  };

  const showBookings = async () => {
    const { token, list } = await p.bookings();
    if (list.length === 0) {
      // the reception computer may not see the number behind a chat (WhatsApp's privacy ids): then no digits are shown
      const text = /^\d{8,15}$/.test(m.from)
        ? `لا توجد حجوزات على رقم واتساب هذا (المنتهي بـ ${m.from.slice(-4)}). إن كان حجزك برقم آخر فاطلب موظف الاستقبال، أو احجز الآن.`
        : "لم أجد حجوزات مرتبطة بهذه المحادثة. إن كان لديك حجز فاطلب موظف الاستقبال، أو احجز الآن.";
      await p.send(buttonsPayload(m.from, text, [{ id: BTN.BOOK, title: "احجز الآن" }, { id: BTN.HUMAN, title: "التحدث مع موظف" }]));
      await saveBot(text);
    } else if (list.length === 1) {
      await bind(token, list[0], true, false);
    } else {
      const text = `لديك ${list.length === 2 ? "حجزان" : `${list.length} حجوزات`} على هذا الرقم. اختر الحجز:`;
      await p.send(listPayload(m.from, text, "اختر الحجز", list.map((b) => ({
        id: "OPEN:" + b.internal_ref, title: b.category_name ?? b.ref,
        description: `${shortDate(b.check_in)} → ${shortDate(b.check_out)} · ${WA_STATUS_AR[b.status] ?? b.status}${b.branch_name ? ` · ${b.branch_name}` : ""}`,
      }))));
      await saveBot(text);
    }
  };

  // ---- the same assistant as everywhere, answering on WhatsApp ----
  const forward = async (th: WaThread, message: string) => {
    const out = await p.ask(th, message).catch(() => null);
    let reply = (out?.reply ?? "").trim();
    let actions = out?.actions ?? [];
    if (!reply) {
      reply = WA_TEXTS.unreachable;
      actions = [{ label: "التحدث مع موظف", value: WA_TEXTS.human }];
      await p.save(th.id, "assistant", reply, { mode: "scripted", channel: "whatsapp", reason: "assistant_unreachable" });
    }
    await p.send(toWhatsAppMessage(m.from, reply, actions, base));
  };

  // ---- not text: say what works (documents are never taken in the chat) ----
  if (!["text", "interactive", "button"].includes(m.type)) {
    await saveGuest(`[${m.type}]`);
    await p.send(buttonsPayload(m.from, WA_TEXTS.textOnly, [{ id: BTN.BOOKINGS, title: "حجوزاتي" }, { id: BTN.HUMAN, title: "التحدث مع موظف" }]));
    await saveBot(WA_TEXTS.textOnly);
    await p.touch(t.id);
    return;
  }

  const id = m.replyId ?? "";
  const typed = m.text.trim();

  if (id === BTN.NEW) {
    await p.closeThread(t.id);
    const next = await p.newThread();
    return forward(next, "مرحبا");
  }
  if (id === BTN.BOOKINGS || WA_TEXTS.bookingsWord.test(typed)) {
    await saveGuest(typed || "حجوزاتي");
    await showBookings();
    await p.touch(t.id);
    return;
  }
  if (id.startsWith("OPEN:")) {
    await saveGuest(typed || id);
    const { token, list } = await p.bookings();
    const b = list.find((x) => x.internal_ref === id.slice(5));
    if (!b || !(await bind(token, b, true, list.length > 1))) {
      await p.send(textPayload(m.from, WA_TEXTS.openFailed));
      await saveBot(WA_TEXTS.openFailed);
    }
    await p.touch(t.id);
    return;
  }
  if (id === BTN.BOOK) {
    await saveGuest(typed || "احجز الآن");
    const text = base ? `اختر يوم الوصول وعدد الليالي والأشخاص، وتظهر لك الأسعار المتاحة فورًا:\n${base}/booking/new` : "الحجز الجديد متاح عبر منصات الحجز المعتمدة.";
    await p.send(textPayload(m.from, text));
    await saveBot(text);
    await p.touch(t.id);
    return;
  }

  // a guest with exactly one current booking is recognised from the first message of a thread
  if (!t.guest_token && fresh) {
    const { token, list } = await p.bookings();
    const current = list.filter((b) => CURRENT.has(b.status));
    if (current.length === 1) await bind(token, current[0], false, false);
  }
  const message = id === BTN.HUMAN ? WA_TEXTS.human : id.startsWith("SAY:") ? id.slice(4) : typed;
  if (!message) return;
  return forward(t, message);
}
