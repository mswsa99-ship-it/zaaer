/**
 * WhatsApp as plain text — for the reception computer (WhatsApp Web), where an ordinary number has no buttons or
 * lists. The conversation flow (wa_flow.ts) builds Cloud API messages; this turns each into text with numbered
 * options («أرسل رقم الخيار»), and maps the guest's answer — the number, or the option's own words — back to the
 * option it means, so the flow sees exactly what a tap would have sent.
 *
 * A message that itself asks for a number or a date («كم ليلة؟», «متى تصل؟») lists its options as words instead of
 * numbers: there an answer like "2" is the guest's answer, not a choice.
 *
 * Dependency-free (Deno, Vitest, the browser demo).
 */

/** n = 0: offered as words only (its message asked for a number, so digits there are answers, not choices) */
export interface WaOption { n: number; id: string; title: string }
/** the options a guest was last offered, kept on the conversation (conversations.wa_menu) */
export interface WaMenu { at: string; options: WaOption[] }

/** how long an answer still refers to the last offered options */
export const WA_MENU_HOURS = 24;
export const WA_CHOOSE_HINT = "أرسل رقم الخيار.";

/** keycap digits 0–9 and the keycap ten (digit + VS16 + combining keycap; written as escapes so the source holds nothing invisible) */
const KEYCAPS = [...Array.from({ length: 10 }, (_, i) => `${i}\u{FE0F}\u{20E3}`), "\u{1F51F}"];
const badge = (n: number) => KEYCAPS[n] ?? `${n}.`;

/** the message asks the guest for a number, a date or a time — digits sent back are an answer (متى → متي once loosened) */
export const asksForNumber = (body: string) => /(^| )(كم|متي|عدد|تاريخ|how many|when)( |$)/.test(looseArabic(body));

// deno-lint-ignore no-explicit-any
type Payload = Record<string, any>;

/**
 * The messages of one turn of the flow → the texts to type, and the options they offered (numbered across the turn;
 * an option offered twice keeps its number).
 */
export function renderPayloads(payloads: Payload[]): { texts: string[]; options: WaOption[] } {
  const options: WaOption[] = [];
  const add = (id: string, title: string, numbered: boolean): number => {
    const known = options.find((o) => o.id === id);
    if (known) {
      if (numbered && known.n === 0) known.n = Math.max(0, ...options.map((o) => o.n)) + 1;
      return known.n;
    }
    const o = { n: numbered ? Math.max(0, ...options.map((x) => x.n)) + 1 : 0, id, title };
    options.push(o);
    return o.n;
  };
  const texts: string[] = [];
  for (const p of payloads) {
    const t = renderOne(p, add);
    if (t) texts.push(t);
  }
  return { texts, options };
}

function renderOne(p: Payload, add: (id: string, title: string, numbered: boolean) => number): string | null {
  if (p?.type === "text") return String(p.text?.body ?? "").trim() || null;
  if (p?.type !== "interactive") return null;                      // templates are a Cloud API thing
  const it = p.interactive ?? {};
  const body = String(it.body?.text ?? "").trim();
  const items: Array<{ id: string; title: string; description?: string }> =
    it.type === "button" ? (it.action?.buttons ?? []).map((b: Payload) => ({ id: String(b.reply?.id ?? ""), title: String(b.reply?.title ?? "") }))
    : it.type === "list" ? (it.action?.sections ?? []).flatMap((s: Payload) => s.rows ?? []).map((r: Payload) => ({ id: String(r.id ?? ""), title: String(r.title ?? ""), description: r.description ? String(r.description) : undefined }))
    : [];
  if (it.type === "cta_url") {
    const prm = it.action?.parameters ?? {};
    return `${body}\n\n🔗 ${prm.display_text ?? ""}: ${prm.url ?? ""}`.trim();
  }
  if (!items.length) return body || null;
  const numbered = !asksForNumber(body);
  const lines = items.map((x) => {
    const n = add(x.id, x.title, numbered);
    return `${numbered ? badge(n) : "\u{25AB}\u{FE0F}"} ${x.title}${x.description ? ` — ${x.description}` : ""}`;
  });
  return `${body}\n\n${lines.join("\n")}${numbered ? `\n\n${WA_CHOOSE_HINT}` : ""}`;
}

// ---------------------------------------------------------------------------
// The guest's answer → the option it means
// ---------------------------------------------------------------------------
const toLatin = (s: string) => s
  .replace(/[٠-٩]/g, (d) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d)))
  .replace(/[۰-۹]/g, (d) => String("۰۱۲۳۴۵۶۷۸۹".indexOf(d)));

/** Arabic compared the way people type it: no diacritics or tatweel, one alef, ى/ي and ة/ه alike, no punctuation */
export function looseArabic(s: string): string {
  return String(s ?? "")
    .normalize("NFKC")
    .replace(/[\u{64B}-\u{652}\u{670}\u{640}]/gu, "")
    .replace(/[أإآٱ]/g, "ا").replace(/ى/g, "ي").replace(/ة/g, "ه")
    .replace(/[«»"'.,!؟?،:؛\-–—()*_~]/g, " ")
    .replace(/\s+/g, " ").trim().toLowerCase();
}

/** "2", "٢", "2" as a keycap, "رقم 2", "🔟" → the number; anything else → null */
export function choiceNumber(text: string): number | null {
  const t = toLatin(String(text ?? "").trim()).replace(/\u{1F51F}/gu, "10").replace(/[\u{FE0F}\u{20E3}]/gu, "")
    .replace(/^(?:رقم|الخيار|خيار)\s*/u, "").replace(/[\s.\-–—)(:#*]/g, "");
  return /^\d{1,2}$/.test(t) ? Number(t) : null;
}

export function pickOption(text: string, menu: WaMenu | null | undefined, now: number = Date.now()): WaOption | null {
  if (!menu || !Array.isArray(menu.options) || menu.options.length === 0) return null;
  const at = Date.parse(menu.at);
  if (!Number.isFinite(at) || now - at > WA_MENU_HOURS * 3600_000) return null;
  const n = choiceNumber(text);
  if (n !== null) return n > 0 ? menu.options.find((o) => o.n === n) ?? null : null;
  const words = looseArabic(text);
  if (!words) return null;
  return menu.options.find((o) => looseArabic(o.title) === words) ?? null;
}
