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
 *   - W1: a guest in their room orders products («المنتجات»): a category, a product, how many; the order waits for the
 *     payment at reception (the voucher and the delivery task come with it), and is cancelled here while it waits
 *   - W3–W4 (0070): on the day of departure the server's 10 AM message offers leaving on time, one night more, or hours
 *     after the free hour; the guest's answer (a number on the reception computer) is the choice — a night or hours are
 *     held while the guest pays at reception — and «غادرت وسلّمت المفتاح» comes after the departure instructions
 */
import { BTN, buttonsPayload, ctaUrlPayload, listPayload, shortDate, textPayload, toWhatsAppMessage, type AssistantAction, type WaInbound } from "./whatsapp.ts";
import { gateInput } from "./guardrails.ts";

export const WA_STATUS_AR: Record<string, string> = {
  draft: "مسودة", pending_verification: "بانتظار التحقق", confirmed: "مؤكد", checked_in: "تم الدخول", checked_out: "تمت المغادرة",
  closed: "مغلق", cancelled: "ملغى", rejected: "مرفوض", no_show: "عدم حضور",
};
/** stays a guest can still act on: these are recognised automatically from the first message */
const CURRENT = new Set(["draft", "pending_verification", "confirmed", "checked_in"]);
/** a thread is the guest's conversation with one branch; after this long without messages a new one starts */
export const WA_THREAD_HOURS = 24;
/** the "text only" notice is not repeated within this time (an album of photos arrives as one message per photo) */
export const WA_NOTICE_REPEAT_MS = 3 * 60_000;

export interface WaBooking {
  ref: string; internal_ref: string; status: string; check_in: string; check_out: string; nights: number;
  branch_name?: string | null; category_name?: string | null;
}
export interface WaThread { id: string; guest_token: string | null }
/** W1: what the stay's branch offers (fn_guest_products) and an order (fn_product_order_json) */
export interface WaProduct { id: string; name: string; description: string | null; price_halalas: number }
export interface WaProductCategory { id: string; name: string; products: WaProduct[] }
export interface WaOrder { id: string; number: string; status: string; total_halalas: number; /** 0069: the part of the total that is tax */ tax_halalas?: number; lines: Array<{ product_id: string; name: string; quantity: number; total_halalas: number }> }
export interface WaShop { can_order: boolean; categories: WaProductCategory[]; open_order: WaOrder | null;
  /** 0069: the products' tax of the stay — its rate, and whether the prices carry it already */
  tax?: { rate_bp: number; included: boolean } }
/** an order placed or cancelled, or the refusal (the server's message: VALIDATION: …, NOT_FOUND, TOKEN_INVALID) */
export type WaOrderResult = { order: WaOrder } | { error: string };
export interface WaAssistantAnswer { reply: string; actions: AssistantAction[] }
/** W3–W4 (0070): the day of departure as the server offers it (fn_guest_checkout) */
export interface WaCheckout {
  open: boolean; check_out: string; room_number: string | null; free_until: string;
  night: { available: boolean; price_halalas: number | null };
  hours: { max: number; price_halalas: number | null; until_limit: string | null; next_guest: boolean };
  hold_minutes: number; choice: string | null; late_checkout_until: string | null; instructions: string | null; departed_at: string | null;
  guide_checkout?: boolean; deposit_halalas: number; refund_hours: number; balance_due: number;
  request: { id: string; kind: "night" | "hours"; hours: number | null; late_until: string | null; amount_halalas: number; status: string; hold_until: string } | null;
}
export type WaCheckoutChoice = "on_time" | "night" | "hours" | "cancel";

export interface WaFlowPorts {
  /** the website's address for links (status page, guest registration); "" → no links are sent */
  appBaseUrl: string;
  /** «رابط منصة الحجز» of the branch (decision 23): the only answer to a new booking; null or absent → the reception */
  bookingUrl?(): Promise<string | null>;
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
  /** what the assistant said in this thread during the last `withinMs` (so an album of photos gets one notice, not one each) */
  recentBot?(threadId: string, withinMs: number): Promise<string[]>;
  /** one WhatsApp message (Cloud API payload without messaging_product) */
  send(payload: Record<string, unknown>): Promise<unknown>;
  /** W1: what the stay's branch offers, whether the guest can order now, and the open order — by the guest token */
  products?(guestToken: string): Promise<WaShop | null>;
  /** W1: adds items to the stay's open WhatsApp order, or opens one */
  orderProducts?(guestToken: string, threadId: string, items: Array<{ product_id: string; quantity: number }>): Promise<WaOrderResult>;
  /** W1: the guest cancels their order while it waits for the payment */
  cancelOrder?(guestToken: string, number: string): Promise<WaOrderResult>;
  /** W3 (0070): what the guest may choose on the day of departure, by the guest token */
  checkoutOffer?(guestToken: string): Promise<WaCheckout | null>;
  /** W3: the guest's choice (on WhatsApp): the new offer, or the refusal (VALIDATION: …) */
  chooseCheckout?(guestToken: string, choice: WaCheckoutChoice, hours: number | null): Promise<{ offer: WaCheckout } | { error: string }>;
  /** W4: «غادرت وسلّمت المفتاح» */
  departed?(guestToken: string): Promise<{ already: boolean } | { error: string }>;
}

export const WA_TEXTS = {
  bookOnPlatform: "الحجوزات الجديدة والأسعار والتوفر عبر منصة الحجز المعتمدة فقط. بعد الحجز أرسل «حجوزاتي» هنا لإكمال إجراءات الوصول.",
  bookNoLink: "الحجوزات الجديدة عبر منصات الحجز المعتمدة فقط، ولا أستطيع عرض الأسعار أو التوفر هنا. اطلب موظف الاستقبال ليوجّهك إلى رابط الحجز.",
  textOnly: "أقرأ الرسائل النصية فقط. لا ترسل صور الهوية أو البطاقات هنا؛ بيانات النزلاء تُدخل عبر الرابط الآمن الذي أرسله لك.",
  openFailed: "تعذر فتح هذا الحجز. اختر من «حجوزاتي» مرة أخرى.",
  unreachable: "عذرًا، تعذر الرد الآن. حاول بعد قليل أو اطلب موظف الاستقبال.",
  human: "أرغب بالتحدث مع موظف الاستقبال",
  arrived: "لقد وصلت وأرغب بتسجيل الدخول",
  bookingsWord: /^(حجوزاتي|حجزي|حجوزات|my bookings?)$/i,
  // W1: ordering from the room
  shopWord: /^(المنتجات|منتجات|طلب منتجات|اطلب|المتجر|القائمة|menu|products?|order)$/i,
  shopNeedsStay: "الطلب من المنتجات للنزيل المقيم بعد تسجيل وصوله. اختر إقامتك من «حجوزاتي»، أو اطلب موظف الاستقبال.",
  shopEmpty: "لا توجد منتجات متاحة للطلب الآن.",
  shopGone: "هذا المنتج لم يعد متاحًا.",
  shopFailed: "تعذر إتمام الطلب الآن. حاول بعد قليل أو اطلب موظف الاستقبال.",
  orderPay: "يتواصل معك الاستقبال لإتمام الدفع (نقدًا أو بالشبكة أو بالتحويل)، ثم يصلك الطلب إلى غرفتك.",
  // W3–W4: the day of departure
  checkoutWord: /^(خروج|الخروج|مغادره|المغادره|مغادرة|المغادرة|تمديد|التمديد|خروج متاخر|خروج متأخر|ليله اضافيه|ليلة إضافية|checkout|check out|late checkout|extend)$/i,
  checkoutNeedsStay: "خيارات الخروج والتمديد للنزيل المقيم في وحدته. اختر إقامتك من «حجوزاتي»، أو اطلب موظف الاستقبال.",
  checkoutClosed: "خيارات الخروج والتمديد تُتاح يوم المغادرة للنزيل المقيم في وحدته. للمساعدة اطلب موظف الاستقبال.",
  departNotInStay: "لا توجد إقامة قائمة في وحدتك الآن. إن كنت ما زلت في الوحدة فاطلب موظف الاستقبال.",
  journeyFailed: "تعذر تنفيذ طلبك الآن. حاول بعد قليل أو اطلب موظف الاستقبال.",
  departInstructions: "تأكد من أغراضك، وأطفئ الأنوار والمكيف، وأغلق الباب، ثم ضع المفتاح أو البطاقة في مكانه أو سلّمه للاستقبال.",
};
/** W3–W4: the ids of the departure's options (the server's 10 AM message uses the first three and BTN.HUMAN) */
export const CO = { ON_TIME: "CO:ONTIME", NIGHT: "CO:NIGHT", HOURS: "CO:HOURS", HOUR: "CO:H:", CANCEL: "CO:CANCEL", MENU: "CO:MENU", LEFT: "DEP:LEFT" } as const;
/** Arabic counting of hours: ساعة واحدة، ساعتان، 3–10 ساعات، 11+ ساعة */
export const hoursAr = (n: number) => (n === 1 ? "ساعة واحدة" : n === 2 ? "ساعتان" : n <= 10 ? `${n} ساعات` : `${n} ساعة`);
/** "13:00" + n hours (midnight is 24:00, the end of the day of departure) */
const plusHours = (hm: string, n: number) => { const [h, mi] = hm.split(":").map(Number); const x = h * 60 + mi + n * 60; return x >= 1440 ? "24:00" : `${String(Math.floor(x / 60)).padStart(2, "0")}:${String(x % 60).padStart(2, "0")}`; };
/** the branch's clock for a moment (every branch keeps Riyadh time today) */
const clockAt = (iso: string) => new Date(iso).toLocaleTimeString("en-GB", { timeZone: "Asia/Riyadh", hour: "2-digit", minute: "2-digit" });

const nightsAr = (n: number) => (n === 1 ? "ليلة" : "ليالٍ");
/** halalas → "12.50 ر.س" */
export const sarText = (h: number) => (h / 100).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + " ر.س";
/** the quantities offered for a product (more of it: add it again) */
const QUANTITIES = ["قطعة واحدة", "قطعتان", "3 قطع"];
/** Arabic counting of products: منتج واحد، منتجان، 3–10 منتجات، 11+ منتجًا */
const productsAr = (n: number) => (n === 1 ? "منتج واحد" : n === 2 ? "منتجان" : n <= 10 ? `${n} منتجات` : `${n} منتجًا`);

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
      const inHouse = b.status === "checked_in" && !!p.products;
      const lines = [
        `حجزك ${b.ref}${b.category_name ? ` — ${b.category_name}` : ""}`,
        `من ${shortDate(b.check_in)} إلى ${shortDate(b.check_out)} (${b.nights} ${nightsAr(b.nights)}) · ${WA_STATUS_AR[b.status] ?? b.status}`,
        "",
        base ? `• حالة الحجز ورمز الدخول: ${base}/booking/status/${guestToken}` : "",
        base ? `• تسجيل بيانات النزلاء (الهوية تُدخل هناك فقط): ${base}/booking/registration/${guestToken}` : "",
        "",
        inHouse ? "اسألني هنا عن أي شيء يخص إقامتك، أو اطلب من المنتجات ويصلك الطلب إلى غرفتك." : "اسألني هنا عن السداد أو الوصول أو أي شيء يخص إقامتك.",
      ].filter((l, i, a) => l !== "" || (a[i - 1] ?? "") !== "").join("\n");
      const btns = [inHouse ? { id: BTN.PRODUCTS, title: "طلب منتجات" } : { id: "SAY:" + WA_TEXTS.arrived, title: "وصلت" }, { id: BTN.HUMAN, title: "التحدث مع موظف" }];
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

  // ---- W1: products ordered from the room (a category, a product, how many) ----
  const say = async (payload: Record<string, unknown>, text: string) => { await p.send(payload); await saveBot(text); };
  const staffBtn = { id: BTN.HUMAN, title: "التحدث مع موظف" };
  /** the stay the guest orders for: the thread's booking when it is in the house, else the only in-house one on the number */
  const shop = async (): Promise<{ token: string; data: WaShop } | null> => {
    if (t.guest_token) {
      const d = await p.products!(t.guest_token).catch(() => null);
      if (d?.can_order) return { token: t.guest_token, data: d };
    }
    const { token, list } = await p.bookings();
    const inHouse = list.filter((b) => b.status === "checked_in");
    if (inHouse.length === 1 && (await bind(token, inHouse[0], false, list.length > 1))) {
      const d = await p.products!(t.guest_token!).catch(() => null);
      if (d?.can_order) return { token: t.guest_token!, data: d };
    }
    if (inHouse.length > 1) { await showBookings(); return null; }      // two rooms: the guest picks the stay first
    await say(buttonsPayload(m.from, WA_TEXTS.shopNeedsStay, [{ id: BTN.BOOKINGS, title: "حجوزاتي" }, staffBtn]), WA_TEXTS.shopNeedsStay);
    return null;
  };
  // a WhatsApp list holds 10 rows: a longer category goes in pages of 9 with «المزيد»
  /** how the listed prices are read when the stay's products are taxed: before the tax, or with it */
  const priceNote = (d: WaShop) => !d.tax?.rate_bp ? "" : d.tax.included ? "\nالأسعار شاملة ضريبة القيمة المضافة"
    : `\nالأسعار قبل ضريبة القيمة المضافة ${(d.tax.rate_bp / 100).toFixed(2).replace(/\.?0+$/, "")}%`;
  const showProducts = async (c: WaProductCategory, lead = "", page = 0, note = "") => {
    const paged = c.products.length > 10;
    const from = paged ? Math.min(page, Math.ceil(c.products.length / 9) - 1) * 9 : 0;
    const part = paged ? c.products.slice(from, from + 9) : c.products;
    const more = paged && from + 9 < c.products.length;
    const text = `${lead}${c.name} — اختر المنتج:${note}`;
    await say(listPayload(m.from, text, "المنتجات", [
      ...part.map((x) => ({ id: "PADD:" + x.id, title: x.name, description: [sarText(x.price_halalas), x.description].filter(Boolean).join(" · ") })),
      ...(more ? [{ id: `PCAT:${c.id}:${from / 9 + 1}`, title: "المزيد…", description: `بقية ${c.name}` }] : []),
    ]), text);
  };
  const showCategories = async (data: WaShop, lead = "") => {
    if (!data.categories.length) return say(buttonsPayload(m.from, WA_TEXTS.shopEmpty, [staffBtn]), WA_TEXTS.shopEmpty);
    const open = data.open_order ? `\n\nلديك طلب بانتظار الدفع بمبلغ ${sarText(data.open_order.total_halalas)} — رقمه ${data.open_order.number}` : "";
    if (data.categories.length === 1) return showProducts(data.categories[0], lead + (open ? open.trim() + "\n\n" : ""), 0, priceNote(data));
    const text = `${lead}المنتجات المتاحة لك — اختر الفئة:${priceNote(data)}${open}`;
    await say(listPayload(m.from, text, "الفئات", data.categories.slice(0, 10).map((c) => ({ id: "PCAT:" + c.id, title: c.name, description: productsAr(c.products.length) }))), text);
  };
  const orderText = (o: WaOrder) => [...o.lines.map((l) => `• ${l.quantity} × ${l.name} — ${sarText(l.total_halalas)}`), `الإجمالي: ${sarText(o.total_halalas)}`,
    ...(o.tax_halalas ? [`منها ضريبة القيمة المضافة: ${sarText(o.tax_halalas)}`] : [])].join("\n");
  const shopTurn = async (id: string) => {
    if (id.startsWith("PCANCEL:")) {
      const number = id.slice(8);
      if (!t.guest_token || !p.cancelOrder) return say(buttonsPayload(m.from, WA_TEXTS.shopNeedsStay, [{ id: BTN.BOOKINGS, title: "حجوزاتي" }, staffBtn]), WA_TEXTS.shopNeedsStay);
      const r = await p.cancelOrder(t.guest_token, number).catch((): WaOrderResult => ({ error: "unreachable" }));
      if ("error" in r) {
        const text = /order_status/.test(r.error) ? `هذا الطلب لم يعد بانتظار الدفع، فلا يُلغى من هنا. تواصل مع الاستقبال، واذكر له رقم الطلب ${number}`
          : /NOT_FOUND/.test(r.error) ? "لم أجد هذا الطلب في إقامتك." : WA_TEXTS.shopFailed;
        return say(buttonsPayload(m.from, text, [staffBtn]), text);
      }
      const text = `أُلغي طلبك رقم ${number}`;
      return say(buttonsPayload(m.from, text, [{ id: BTN.PRODUCTS, title: "المنتجات" }, staffBtn]), text);
    }
    const s = await shop();
    if (!s) return;
    const all = s.data.categories.flatMap((c) => c.products);
    if (id.startsWith("PCAT:")) {
      const [, cid, pg] = id.split(":");
      const c = s.data.categories.find((x) => x.id === cid);
      return c ? showProducts(c, "", Math.max(0, Number(pg) || 0), priceNote(s.data)) : showCategories(s.data, "هذه الفئة لم تعد متاحة.\n");
    }
    if (id.startsWith("PADD:")) {
      const x = all.find((y) => y.id === id.slice(5));
      if (!x) return showCategories(s.data, WA_TEXTS.shopGone + "\n");
      // the quantity as options (on the reception computer a typed «2» is the second option: two pieces)
      const text = `${x.name} — ${sarText(x.price_halalas)}\nاختر الكمية:`;
      return say(buttonsPayload(m.from, text, QUANTITIES.map((title, i) => ({ id: `PQ:${x.id}:${i + 1}`, title }))), text);
    }
    if (id.startsWith("PQ:")) {
      const [, pid, qs] = id.split(":");
      const n = Number(qs);
      const x = all.find((y) => y.id === pid);
      if (!x || !Number.isInteger(n) || n < 1 || n > 50) return showCategories(s.data, WA_TEXTS.shopGone + "\n");
      const r = await p.orderProducts!(s.token, t.id, [{ product_id: x.id, quantity: n }]).catch((): WaOrderResult => ({ error: "unreachable" }));
      if ("error" in r) {
        const text = /product_unavailable/.test(r.error) ? WA_TEXTS.shopGone : /order_quantity/.test(r.error) ? "لا يزيد المنتج الواحد في الطلب على 50."
          : /not_in_stay/.test(r.error) ? WA_TEXTS.shopNeedsStay : WA_TEXTS.shopFailed;
        return say(buttonsPayload(m.from, text, [{ id: BTN.PRODUCTS, title: "المنتجات" }, staffBtn]), text);
      }
      const text = [`أضفت ${n} × ${x.name} إلى طلبك.`, `رقم الطلب: ${r.order.number}`, orderText(r.order), "", WA_TEXTS.orderPay].join("\n");
      return say(buttonsPayload(m.from, text, [{ id: BTN.PRODUCTS, title: "إضافة منتج" }, { id: "PCANCEL:" + r.order.number, title: "إلغاء الطلب" }, staffBtn]), text);
    }
    return showCategories(s.data);
  };

  // ---- W3–W4: the day of departure — the choice, the held request, the departure ----
  const departBtn = { id: CO.LEFT, title: "غادرت وسلّمت المفتاح" };
  /** the stay the guest leaves from: the thread's booking (the 10 AM message bound it), else the only in-house one */
  const leavingStay = async (): Promise<string | null> => {
    if (t.guest_token) return t.guest_token;
    const { token, list } = await p.bookings();
    const inHouse = list.filter((b) => b.status === "checked_in");
    if (inHouse.length === 1 && (await bind(token, inHouse[0], false, list.length > 1))) return t.guest_token;
    if (inHouse.length > 1) { await showBookings(); return null; }
    await say(buttonsPayload(m.from, WA_TEXTS.checkoutNeedsStay, [{ id: BTN.BOOKINGS, title: "حجوزاتي" }, staffBtn]), WA_TEXTS.checkoutNeedsStay);
    return null;
  };
  const statusLink = (tok: string) => (base ? `${base}/booking/status/${tok}` : "");
  /** what the guest reads before «غادرت وسلّمت المفتاح»: the instructions, then the unit's way out when its photos are approved */
  const leaveText = (o: WaCheckout, tok: string) => [o.instructions || WA_TEXTS.departInstructions,
    o.guide_checkout && base ? `صور طريقة المغادرة: ${statusLink(tok)}` : "", "حين تغادر اختر «غادرت وسلّمت المفتاح»."].filter(Boolean).join("\n\n");
  const heldText = (o: WaCheckout) => {
    const q = o.request!;
    const what = q.kind === "night" ? "ليلة إضافية" : `خروجًا متأخرًا ${hoursAr(q.hours ?? 0)} حتى ${q.late_until}`;
    if (q.status === "paid" || q.status === "confirmed") return q.kind === "night" ? `تم تثبيت ليلتك الإضافية. موعد خروجك الجديد ${o.check_out} بين 12 و1 ظهرًا.` : `تم تثبيت خروجك المتأخر حتى ${q.late_until}.`;
    if (q.status === "overdue") return `انتهت مهلة دفع طلبك (${what}). تواصل مع الاستقبال لإتمام الدفع أو إلغاء الطلب.`;
    return `حجزنا لك ${what} بمبلغ ${sarText(q.amount_halalas)} حتى الساعة ${clockAt(q.hold_until)}. ادفع المبلغ لدى الاستقبال (نقدًا أو بالشبكة أو بالتحويل) ليُثبَّت، وإلا أُلغي تلقائيًا.`;
  };
  /** the departure's menu as the server offers it now */
  const checkoutMenu = async (o: WaCheckout | null, tok: string, lead = "") => {
    if (!o) return say(buttonsPayload(m.from, WA_TEXTS.journeyFailed, [staffBtn]), WA_TEXTS.journeyFailed);
    if (o.departed_at) { const text = `${lead}أبلغت الاستقبال بمغادرتك الساعة ${clockAt(o.departed_at)}. يفحص الوحدة ثم يؤكد خروجك ويصلك التأكيد هنا.`; return say(textPayload(m.from, text), text); }
    if (o.request && ["held", "overdue"].includes(o.request.status)) {
      const text = lead + heldText(o);
      return say(buttonsPayload(m.from, text, [...(o.request.status === "held" ? [{ id: CO.CANCEL, title: "إلغاء الطلب" }] : []), staffBtn]), text);
    }
    if (!o.open) {
      const text = lead + (o.request && ["paid", "confirmed"].includes(o.request.status) ? heldText(o) : WA_TEXTS.checkoutClosed);
      return say(buttonsPayload(m.from, text, [staffBtn]), text);
    }
    if (o.choice === "on_time" || o.late_checkout_until) {
      const text = `${lead}${o.late_checkout_until ? `موعد خروجك اليوم حتى ${o.late_checkout_until}.` : `موعد خروجك اليوم قبل ${o.free_until}.`}\n\n${leaveText(o, tok)}`;
      return say(buttonsPayload(m.from, text, [departBtn, staffBtn]), text.replace(/\/booking\/status\/[A-Za-z0-9]+/g, "/booking/status/…"));
    }
    const rows: Array<{ id: string; title: string; description?: string }> = [{ id: CO.ON_TIME, title: "سأخرج في الموعد", description: `بين 12 و1 ظهرًا، بلا رسوم حتى ${o.free_until}` }];
    if (o.night.available) rows.push({ id: CO.NIGHT, title: "ليلة إضافية", description: sarText(o.night.price_halalas ?? 0) });
    if (o.hours.max > 0) rows.push({ id: CO.HOURS, title: `ساعات بعد ${o.free_until}`, description: `${sarText(o.hours.price_halalas ?? 0)} للساعة` });
    rows.push({ id: CO.LEFT, title: "غادرت وسلّمت المفتاح", description: "بعد قراءة تعليمات المغادرة" });
    const text = `${lead}موعد خروجك اليوم${o.room_number ? ` من غرفة ${o.room_number}` : ""} بين 12 و1 ظهرًا. ماذا تفضّل؟`;
    return say(listPayload(m.from, text, "الخيارات", rows), text);
  };
  const checkoutError = (e: string) => /night_unavailable/.test(e) ? "لا تتاح ليلة إضافية: الوحدة محجوزة الليلة لضيف آخر أو على الحجز مبلغ متأخر."
    : /late_hours/.test(e) ? "هذا العدد من الساعات غير متاح؛ الخروج المتأخر لا يتجاوز موعد الضيف التالي ناقص ساعة التنظيف."
    : /extension_pending/.test(e) ? "لديك طلب بانتظار الدفع؛ ادفعه لدى الاستقبال أو ألغِه أولًا."
    : /extension_none/.test(e) ? "لا يوجد طلب بانتظار الدفع لإلغائه."
    : /checkout_not_today/.test(e) ? WA_TEXTS.checkoutClosed
    : /TOKEN_INVALID|not_in_stay/.test(e) ? WA_TEXTS.checkoutNeedsStay : WA_TEXTS.journeyFailed;
  const checkoutTurn = async (id: string) => {
    const tok = await leavingStay();
    if (!tok) return;
    if (id === CO.LEFT) {
      // the instructions come before the button: a guest who has not read them yet gets them first
      const o = await p.checkoutOffer!(tok).catch(() => null);
      const r = await p.departed!(tok).catch((): { error: string } => ({ error: "unreachable" }));
      if ("error" in r) { const text = /not_in_stay/.test(r.error) ? WA_TEXTS.departNotInStay : WA_TEXTS.journeyFailed; return say(buttonsPayload(m.from, text, [staffBtn]), text); }
      const text = (r.already ? "أبلغتنا بمغادرتك من قبل. " : "شكرًا لك. ") + "أبلغنا الاستقبال بمغادرتك؛ يفحص الوحدة ثم يؤكد خروجك ويصلك التأكيد هنا."
        + (o && o.deposit_halalas > 0 ? `\nيُرد تأمينك (${sarText(o.deposit_halalas)}) خلال ${hoursAr(o.refund_hours)} من تأكيد الخروج: تحويلًا إلى حسابك أو نقدًا من الاستقبال، ويصلك إيصال الرد هنا.` : "");
      return say(textPayload(m.from, text), text);
    }
    if (id === CO.HOURS) {
      const o = await p.checkoutOffer!(tok).catch(() => null);
      if (!o || !o.open || o.hours.max <= 0 || o.request?.status === "held") return checkoutMenu(o, tok);
      const n = Math.min(o.hours.max, 10);
      const text = `اختر مدة الخروج المتأخر بعد ${o.free_until} (${sarText(o.hours.price_halalas ?? 0)} للساعة، وجزء الساعة ساعة)${o.hours.next_guest ? `؛ الحد ${o.hours.until_limit} لوجود ضيف بعدك` : ""}:`;
      return say(listPayload(m.from, text, "الساعات", Array.from({ length: n }, (_, i) => ({
        id: CO.HOUR + (i + 1), title: `${hoursAr(i + 1)} — حتى ${plusHours(o.free_until, i + 1)}`, description: sarText((o.hours.price_halalas ?? 0) * (i + 1)) }))), text);
    }
    const choice: WaCheckoutChoice | null = id === CO.ON_TIME ? "on_time" : id === CO.NIGHT ? "night" : id === CO.CANCEL ? "cancel" : id.startsWith(CO.HOUR) ? "hours" : null;
    if (!choice) return checkoutMenu(await p.checkoutOffer!(tok).catch(() => null), tok);
    const hours = choice === "hours" ? Number(id.slice(CO.HOUR.length)) : null;
    if (choice === "hours" && (!Number.isInteger(hours) || (hours ?? 0) < 1)) return checkoutMenu(await p.checkoutOffer!(tok).catch(() => null), tok);
    const r = await p.chooseCheckout!(tok, choice, hours).catch((): { error: string } => ({ error: "unreachable" }));
    if ("error" in r) { const text = checkoutError(r.error); return checkoutMenu(await p.checkoutOffer!(tok).catch(() => null), tok, text + "\n\n"); }
    const o = r.offer;
    if (choice === "cancel") return checkoutMenu(o, tok, `ألغينا الطلب. موعد خروجك اليوم قبل ${o.free_until}.\n\n`);
    if (choice === "on_time") { const text = `تم. موعد خروجك اليوم قبل ${o.free_until}.\n\n${leaveText(o, tok)}`; return say(buttonsPayload(m.from, text, [departBtn, staffBtn]), text.replace(/\/booking\/status\/[A-Za-z0-9]+/g, "/booking/status/…")); }
    return checkoutMenu(o, tok);
  };

  // ---- not text: say what works (documents are never taken in the chat) ----
  if (!["text", "interactive", "button"].includes(m.type)) {
    // the notice once: the next photos of an album (each one a message) are recorded without repeating it
    const said = fresh ? [] : ((await p.recentBot?.(t.id, WA_NOTICE_REPEAT_MS).catch(() => [])) ?? []);
    await saveGuest(`[${m.type}]`);
    if (!said.includes(WA_TEXTS.textOnly)) {
      await p.send(buttonsPayload(m.from, WA_TEXTS.textOnly, [{ id: BTN.BOOKINGS, title: "حجوزاتي" }, { id: BTN.HUMAN, title: "التحدث مع موظف" }]));
      await saveBot(WA_TEXTS.textOnly);
    }
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
  // the departure's options (the 10 AM message's numbers), its words typed, or the assistant's own suggestion of them
  const checkoutAsked = /^(CO|DEP):/.test(id) || (!id && WA_TEXTS.checkoutWord.test(typed)) || (id.startsWith("SAY:") && WA_TEXTS.checkoutWord.test(id.slice(4).trim()));
  if (p.checkoutOffer && p.chooseCheckout && p.departed && checkoutAsked) {
    await saveGuest(typed || id);
    await checkoutTurn(/^(CO|DEP):/.test(id) ? id : CO.MENU);
    await p.touch(t.id);
    return;
  }
  // «المنتجات» typed, the button, a step of the shop, or the assistant's own suggestion of it
  const shopAsked = id === BTN.PRODUCTS || /^(PCAT|PADD|PQ|PCANCEL):/.test(id) || (!id && WA_TEXTS.shopWord.test(typed))
    || (id.startsWith("SAY:") && WA_TEXTS.shopWord.test(id.slice(4).trim()));
  if (p.products && shopAsked) {
    await saveGuest(typed || "المنتجات");
    await shopTurn(id);
    await p.touch(t.id);
    return;
  }
  if (id === BTN.BOOK) {
    // decision 23: no availability and no prices here; the platform's link, or the reception when none is set
    await saveGuest(typed || "احجز الآن");
    const link = (await p.bookingUrl?.().catch(() => null)) ?? null;
    if (link) {
      const text = WA_TEXTS.bookOnPlatform;
      await p.send(ctaUrlPayload(m.from, text, "احجز الآن", link));
      await saveBot(`${text}\n${link}`);
    } else {
      await p.send(buttonsPayload(m.from, WA_TEXTS.bookNoLink, [{ id: BTN.HUMAN, title: "التحدث مع موظف" }, { id: BTN.BOOKINGS, title: "حجوزاتي" }]));
      await saveBot(WA_TEXTS.bookNoLink);
    }
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
