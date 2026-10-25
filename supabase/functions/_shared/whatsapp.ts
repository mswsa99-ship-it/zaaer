/**
 * WhatsApp Cloud API — shared, dependency-free helpers (Deno and Vitest).
 *
 * Every branch has its own number and credentials (branch_whatsapp_channels, set by the owner on /admin/whatsapp);
 * the edge functions read them with fn_whatsapp_channel (service role) and pass them in as a `WaChannel`.
 * Nothing here logs or returns a token.
 */

export const WA_API_VERSION = "v23.0";

export interface WaChannel {
  branch_id: string;
  organization_id: string;
  /** cloud_api: this file; web_bridge: the branch answers from the reception computer (wa-bridge), never via Meta */
  mode?: "cloud_api" | "web_bridge";
  auto_reply?: boolean;
  enabled: boolean;
  status: string;
  display_phone: string | null;
  phone_number_id: string | null;
  access_token: string | null;
  app_secret: string | null;
  verify_token: string;
  otp_template: string | null;
  template_lang: string;
}

export interface WaSendResult { ok: boolean; id?: string; status?: number; error?: string; code?: number }

/** Masks Meta tokens in anything that may reach a log or a screen. */
export const maskTokens = (s: string) => s.replace(/EAA[A-Za-z0-9]{10,}/g, "[token]");

export function usable(c: WaChannel | null | undefined): c is WaChannel & { phone_number_id: string; access_token: string } {
  return !!c && c.enabled && c.mode !== "web_bridge" && !!c.phone_number_id && !!c.access_token;
}

export async function waSend(c: WaChannel, payload: Record<string, unknown>, fetcher: typeof fetch = fetch): Promise<WaSendResult> {
  if (!c.phone_number_id || !c.access_token) return { ok: false, error: "channel_incomplete" };
  try {
    const res = await fetcher(`https://graph.facebook.com/${WA_API_VERSION}/${encodeURIComponent(c.phone_number_id)}/messages`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${c.access_token}` },
      body: JSON.stringify({ messaging_product: "whatsapp", recipient_type: "individual", ...payload }),
      signal: AbortSignal.timeout(10000),
    });
    const text = await res.text().catch(() => "");
    if (!res.ok) {
      let code: number | undefined; let msg = text;
      try { const e = JSON.parse(text).error; code = e?.code; msg = `${e?.code ?? ""} ${e?.message ?? ""} ${e?.error_data?.details ?? ""}`.trim(); } catch { /* not JSON */ }
      return { ok: false, status: res.status, code, error: maskTokens(msg).slice(0, 300) };
    }
    let id: string | undefined;
    try { id = JSON.parse(text)?.messages?.[0]?.id; } catch { /* ignore */ }
    return { ok: true, id };
  } catch (e) {
    return { ok: false, error: maskTokens(String(e)).slice(0, 200) };
  }
}

/** The connection test: Meta's own record of the number (proves the token and the phone number id belong together). */
export async function waCheck(c: WaChannel, fetcher: typeof fetch = fetch): Promise<{ ok: boolean; verified_name?: string; display_phone_number?: string; quality_rating?: string; error?: string }> {
  if (!c.phone_number_id || !c.access_token) return { ok: false, error: "channel_incomplete" };
  try {
    const res = await fetcher(`https://graph.facebook.com/${WA_API_VERSION}/${encodeURIComponent(c.phone_number_id)}?fields=verified_name,display_phone_number,quality_rating`, {
      headers: { authorization: `Bearer ${c.access_token}` }, signal: AbortSignal.timeout(10000),
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) return { ok: false, error: maskTokens(`${body?.error?.code ?? res.status} ${body?.error?.message ?? ""}`).slice(0, 300) };
    return { ok: true, verified_name: body.verified_name, display_phone_number: body.display_phone_number, quality_rating: body.quality_rating };
  } catch (e) {
    return { ok: false, error: maskTokens(String(e)).slice(0, 200) };
  }
}

// ---------------------------------------------------------------------------
// Message shapes (Cloud API limits: body 1024 chars in interactive messages, 4096 in text; ≤3 reply buttons of
// ≤20 chars; list rows ≤10, title ≤24, description ≤72; ids ≤256)
// ---------------------------------------------------------------------------
const cut = (s: string, n: number) => (s.length <= n ? s : s.slice(0, n - 1) + "…");

export const textPayload = (to: string, body: string) => ({ to, type: "text", text: { body: cut(body, 4096), preview_url: false } });

export const buttonsPayload = (to: string, body: string, buttons: Array<{ id: string; title: string }>) => ({
  to, type: "interactive",
  interactive: {
    type: "button", body: { text: cut(body, 1024) },
    action: { buttons: buttons.slice(0, 3).map((b) => ({ type: "reply", reply: { id: b.id.slice(0, 256), title: cut(b.title, 20) } })) },
  },
});

export const listPayload = (to: string, body: string, buttonLabel: string, rows: Array<{ id: string; title: string; description?: string }>) => ({
  to, type: "interactive",
  interactive: {
    type: "list", body: { text: cut(body, 1024) },
    action: { button: cut(buttonLabel, 20), sections: [{ title: cut(buttonLabel, 24), rows: rows.slice(0, 10).map((r) => ({ id: r.id.slice(0, 200), title: cut(r.title, 24), ...(r.description ? { description: cut(r.description, 72) } : {}) })) }] },
  },
});

export const ctaUrlPayload = (to: string, body: string, label: string, url: string) => ({
  to, type: "interactive",
  interactive: { type: "cta_url", body: { text: cut(body, 1024) }, action: { name: "cta_url", parameters: { display_text: cut(label, 20), url } } },
});

/** Authentication template: the code in the body and in the copy-code button. */
export function otpTemplatePayload(to: string, code: string, template: string, lang: string) {
  return {
    to, type: "template",
    template: {
      name: template, language: { code: lang },
      components: [
        { type: "body", parameters: [{ type: "text", text: code }] },
        { type: "button", sub_type: "url", index: "0", parameters: [{ type: "text", text: code }] },
      ],
    },
  };
}

// ---------------------------------------------------------------------------
// Webhook: signature and parsing
// ---------------------------------------------------------------------------
const hex = (buf: ArrayBuffer) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");

/** X-Hub-Signature-256 = "sha256=" + HMAC-SHA256(app secret, raw body), compared in constant time. */
export async function verifySignature(appSecret: string, rawBody: string, header: string | null): Promise<boolean> {
  if (!appSecret || !header || !header.startsWith("sha256=")) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(appSecret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const expected = "sha256=" + hex(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(rawBody)));
  if (expected.length !== header.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ header.charCodeAt(i);
  return diff === 0;
}

export interface WaInbound {
  phoneNumberId: string;
  from: string;           // the guest's number as WhatsApp verified it (international digits)
  id: string;             // WhatsApp message id (dedupe)
  type: string;           // text | interactive | button | image | audio | location | …
  text: string;           // typed text, or the title of the tapped button / list row
  replyId?: string;       // id of the tapped button / list row
  name?: string;          // the guest's WhatsApp profile name
}

/** Guest messages in a webhook call (delivery/read statuses are ignored). */
export function parseInbound(body: unknown): WaInbound[] {
  const out: WaInbound[] = [];
  const entries = (body as { entry?: unknown[] })?.entry;
  if (!Array.isArray(entries)) return out;
  for (const e of entries as Array<{ changes?: Array<{ value?: Record<string, unknown> }> }>) {
    for (const ch of e?.changes ?? []) {
      const v = ch?.value ?? {};
      const phoneNumberId = String((v.metadata as { phone_number_id?: string } | undefined)?.phone_number_id ?? "");
      const contacts = (v.contacts as Array<{ wa_id?: string; profile?: { name?: string } }> | undefined) ?? [];
      for (const m of (v.messages as Array<Record<string, any>> | undefined) ?? []) { // deno-lint-ignore no-explicit-any
        const it = m.interactive as Record<string, any> | undefined; // deno-lint-ignore no-explicit-any
        const reply = it?.button_reply ?? it?.list_reply;
        const text = m.type === "text" ? String(m.text?.body ?? "")
          : reply ? String(reply.title ?? "")
          : m.type === "button" ? String(m.button?.text ?? "") : "";
        out.push({
          phoneNumberId, from: String(m.from ?? ""), id: String(m.id ?? ""), type: String(m.type ?? ""), text: text.slice(0, 2000),
          replyId: reply?.id ? String(reply.id) : m.type === "button" ? String(m.button?.payload ?? "") || undefined : undefined,
          name: contacts.find((c) => c.wa_id === m.from)?.profile?.name,
        });
      }
    }
  }
  return out.filter((m) => m.from && m.id && m.phoneNumberId);
}

// ---------------------------------------------------------------------------
// The assistant's reply (same shape as on the website) → one WhatsApp message
// ---------------------------------------------------------------------------
export interface AssistantAction { label: string; route?: string; value?: string }

/** Buttons the webhook understands; everything else is a link to a page of the website. */
export const BTN = { BOOKINGS: "MY_BOOKINGS", HUMAN: "HUMAN", NEW: "NEW_CHAT", BOOK: "BOOK_NOW" } as const;

export function toWhatsAppMessage(to: string, reply: string, actions: AssistantAction[], appBaseUrl: string): Record<string, unknown> {
  const buttons: Array<{ id: string; title: string }> = [];
  const links: Array<{ label: string; url: string }> = [];
  const base = appBaseUrl.replace(/\/$/, "");
  for (const a of actions ?? []) {
    if (a.value) {
      buttons.push(/(موظف|مشرف|human|staff)/i.test(a.value) ? { id: BTN.HUMAN, title: "التحدث مع موظف" } : { id: "SAY:" + a.value.slice(0, 200), title: a.label });
    } else if (a.route) {
      const path = a.route.split("?")[0];
      if (path === "/booking/lookup") buttons.push({ id: BTN.BOOKINGS, title: "حجوزاتي" });
      else if (path === "/reception") buttons.push({ id: BTN.NEW, title: "محادثة جديدة" });
      else if (path === "/booking/new") buttons.push({ id: BTN.BOOK, title: "احجز الآن" });   // decision 23: the platform link, sent by the flow
      else if (base) links.push({ label: a.label, url: base + a.route });
    }
  }
  const uniq = buttons.filter((b, i) => buttons.findIndex((x) => x.id === b.id) === i).slice(0, 3);
  const linkLines = links.map((l) => `• ${l.label}: ${l.url}`).join("\n");
  if (uniq.length) return buttonsPayload(to, linkLines ? `${reply}\n\n${linkLines}` : reply, uniq);
  if (links.length === 1) return ctaUrlPayload(to, reply, links[0].label, links[0].url);
  return textPayload(to, linkLines ? `${reply}\n\n${linkLines}` : reply);
}

/** Saudi date for a booking line: 2026-10-23 → 23/10 */
export const shortDate = (d: string) => { const [, m, day] = String(d).split("-"); return day && m ? `${Number(day)}/${Number(m)}` : String(d); };
