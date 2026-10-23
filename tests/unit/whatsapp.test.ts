import { describe, it, expect } from "vitest";
import { createHmac } from "node:crypto";
import {
  verifySignature, parseInbound, toWhatsAppMessage, buttonsPayload, listPayload, otpTemplatePayload, maskTokens, waSend, usable, BTN, type WaChannel,
} from "../../supabase/functions/_shared/whatsapp";

const sign = (secret: string, body: string) => "sha256=" + createHmac("sha256", secret).update(body).digest("hex");
const channel: WaChannel = {
  branch_id: "b1", organization_id: "o1", enabled: true, status: "active", display_phone: "966551234567", phone_number_id: "1234567890",
  access_token: "EAAGsecretTokenValue1234567890", app_secret: "s3cr3t-app-secret", verify_token: "v".repeat(32), otp_template: "code", template_lang: "ar",
};

describe("WhatsApp webhook signature (WA-U01)", () => {
  const body = JSON.stringify({ entry: [{ changes: [] }] });
  it("accepts Meta's HMAC of the raw body with the branch's app secret", async () => {
    expect(await verifySignature("s3cr3t-app-secret", body, sign("s3cr3t-app-secret", body))).toBe(true);
  });
  it("refuses another secret, a changed body, a missing or malformed header", async () => {
    expect(await verifySignature("s3cr3t-app-secret", body, sign("other", body))).toBe(false);
    expect(await verifySignature("s3cr3t-app-secret", body + " ", sign("s3cr3t-app-secret", body))).toBe(false);
    expect(await verifySignature("s3cr3t-app-secret", body, null)).toBe(false);
    expect(await verifySignature("s3cr3t-app-secret", body, "md5=abc")).toBe(false);
    expect(await verifySignature("", body, sign("", body))).toBe(false);
  });
});

describe("inbound parsing (WA-U02)", () => {
  const hook = (messages: unknown[]) => ({ entry: [{ changes: [{ value: { metadata: { phone_number_id: "1234567890" }, contacts: [{ wa_id: "966500000111", profile: { name: "نزيل" } }], messages } }] }] });
  it("reads text, button and list replies with the sender, id and profile name", () => {
    const out = parseInbound(hook([
      { from: "966500000111", id: "wamid.1", type: "text", text: { body: "مرحبا" } },
      { from: "966500000111", id: "wamid.2", type: "interactive", interactive: { type: "button_reply", button_reply: { id: BTN.BOOKINGS, title: "حجوزاتي" } } },
      { from: "966500000111", id: "wamid.3", type: "interactive", interactive: { type: "list_reply", list_reply: { id: "OPEN:R-1", title: "شقة" } } },
    ]));
    expect(out.map((m) => [m.id, m.type, m.text, m.replyId])).toEqual([
      ["wamid.1", "text", "مرحبا", undefined], ["wamid.2", "interactive", "حجوزاتي", BTN.BOOKINGS], ["wamid.3", "interactive", "شقة", "OPEN:R-1"],
    ]);
    expect(out[0]).toMatchObject({ from: "966500000111", phoneNumberId: "1234567890", name: "نزيل" });
  });
  it("ignores delivery statuses and malformed bodies", () => {
    expect(parseInbound({ entry: [{ changes: [{ value: { metadata: { phone_number_id: "1" }, statuses: [{ id: "x", status: "read" }] } }] }] })).toEqual([]);
    expect(parseInbound(null)).toEqual([]);
    expect(parseInbound({ entry: "x" })).toEqual([]);
  });
});

describe("assistant reply → one WhatsApp message (WA-U03)", () => {
  const base = "https://example.test/app";
  it("«حجوزاتي» and «موظف» become reply buttons; pages become links in the text", () => {
    const p = toWhatsAppMessage("966500000111", "أهلًا", [
      { label: "حجوزاتي", route: "/booking/lookup" }, { label: "احجز الآن", route: "/booking/new" },
      { label: "التحدث مع موظف", value: "أرغب بالتحدث مع موظف الاستقبال" },
    ], base) as any;
    expect(p.type).toBe("interactive");
    expect(p.interactive.action.buttons.map((b: any) => b.reply.id)).toEqual([BTN.BOOKINGS, BTN.HUMAN]);
    expect(p.interactive.body.text).toContain("https://example.test/app/booking/new");
  });
  it("one page link alone is a URL button; no actions is plain text", () => {
    expect((toWhatsAppMessage("1", "حالة حجزك", [{ label: "حالة الحجز", route: "/booking/status/ABC" }], base) as any).interactive.type).toBe("cta_url");
    expect((toWhatsAppMessage("1", "شكرًا", [], base) as any).type).toBe("text");
  });
  it("keeps WhatsApp's limits: 3 buttons, 20-char titles, 10 list rows, 1024-char interactive body", () => {
    const b = buttonsPayload("1", "x".repeat(2000), Array.from({ length: 5 }, (_, i) => ({ id: "B" + i, title: "عنوان طويل جدًا يتجاوز الحد المسموح" }))) as any;
    expect(b.interactive.action.buttons).toHaveLength(3);
    expect(b.interactive.action.buttons.every((x: any) => x.reply.title.length <= 20)).toBe(true);
    expect(b.interactive.body.text.length).toBeLessThanOrEqual(1024);
    const l = listPayload("1", "اختر", "اختر الحجز", Array.from({ length: 14 }, (_, i) => ({ id: "OPEN:" + i, title: "t".repeat(40), description: "d".repeat(100) }))) as any;
    expect(l.interactive.action.sections[0].rows).toHaveLength(10);
    expect(l.interactive.action.sections[0].rows[0].title.length).toBeLessThanOrEqual(24);
    expect(l.interactive.action.sections[0].rows[0].description.length).toBeLessThanOrEqual(72);
  });
  it("the website code goes in the template body and the copy-code button", () => {
    const t = otpTemplatePayload("966500000111", "123456", "booking_code", "ar") as any;
    expect(t.template.components.flatMap((c: any) => c.parameters.map((x: any) => x.text))).toEqual(["123456", "123456"]);
  });
});

describe("sending (WA-U04)", () => {
  it("sends with the branch's own number and token; an error never carries the token", async () => {
    let seen: { url: string; auth: string } | null = null;
    const fake = (async (url: string, init: RequestInit) => {
      seen = { url, auth: (init.headers as Record<string, string>).authorization };
      return new Response(JSON.stringify({ error: { code: 190, message: "Invalid token EAAGsecretTokenValue1234567890" } }), { status: 401 });
    }) as unknown as typeof fetch;
    const r = await waSend(channel, { to: "966500000111", type: "text", text: { body: "x" } }, fake);
    expect(seen!.url).toContain("/1234567890/messages");
    expect(seen!.auth).toBe("Bearer EAAGsecretTokenValue1234567890");
    expect(r).toMatchObject({ ok: false, status: 401, code: 190 });
    expect(r.error).not.toContain("EAAGsecret");
    expect(maskTokens("x EAAGsecretTokenValue1234567890 y")).toBe("x [token] y");
  });
  it("a switched-off or incomplete branch is not usable", () => {
    expect(usable({ ...channel, enabled: false })).toBe(false);
    expect(usable({ ...channel, access_token: null })).toBe(false);
    expect(usable(channel)).toBe(true);
  });
});
