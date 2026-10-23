/**
 * wa-bridge decisions (_shared/wa_bridge.ts) — WB-U01–WB-U06: who wrote, whether the assistant answers, and what a
 * numbered answer means.
 */
import { describe, it, expect } from "vitest";
import { contactOf, silentReason, toInbound, sha256Hex, BRIDGE_REPLY_MAX_AGE_MS, type BridgeChannel } from "../../supabase/functions/_shared/wa_bridge";
import { BTN } from "../../supabase/functions/_shared/whatsapp";

const ch: BridgeChannel = { branch_id: "B", organization_id: "O", enabled: true, auto_reply: true, human_pause_minutes: 60 };

describe("reception computer (wa-bridge) decisions", () => {
  it("WB-U01 the sender: a number chat is the number; a privacy id uses the number the program resolved, or stays hidden", () => {
    expect(contactOf("966501110006@c.us")).toEqual({ key: "966501110006", phone: "966501110006", chatId: "966501110006@c.us" });
    expect(contactOf("204587116371@lid", "+966 50 111 0006")).toEqual({ key: "966501110006", phone: "966501110006", chatId: "204587116371@lid" });
    expect(contactOf("204587116371@lid", null)).toEqual({ key: "lid:204587116371", phone: null, chatId: "204587116371@lid" });
  });

  it("WB-U02 groups, broadcasts, channels and malformed chats are nobody", () => {
    for (const c of ["120363025246125486@g.us", "status@broadcast", "120363041234567890@newsletter", "abc@c.us", "", "966501110006"]) expect(contactOf(c), c).toBeNull();
  });

  it("WB-U03 the assistant stays silent when the branch is off, auto-reply is off, a receptionist is on the chat, or the message is old", () => {
    const now = Date.parse("2026-10-24T10:00:00Z");
    expect(silentReason(ch, null, now, now)).toBeNull();
    expect(silentReason({ ...ch, enabled: false }, null, now, now)).toBe("disabled");
    expect(silentReason({ ...ch, auto_reply: false }, null, now, now)).toBe("auto_reply_off");
    expect(silentReason(ch, { human_active_until: "2026-10-24T10:30:00Z" }, now, now)).toBe("human");
    expect(silentReason(ch, { human_active_until: "2026-10-24T09:59:00Z" }, now, now)).toBeNull();     // the pause is over
    expect(silentReason(ch, null, now - BRIDGE_REPLY_MAX_AGE_MS - 1000, now)).toBe("too_old");
  });

  it("WB-U04 a number from the last options becomes that option, exactly as a tap on the Cloud API", () => {
    const contact = contactOf("966501110006@c.us")!;
    const menu = { at: new Date().toISOString(), options: [{ n: 1, id: "SAY:لقد وصلت", title: "وصلت" }, { n: 2, id: BTN.HUMAN, title: "التحدث مع موظف" }] };
    expect(toInbound({ id: "m1", chat: contact.chatId!, type: "text", text: "٢" }, contact, menu)).toMatchObject({ type: "interactive", replyId: BTN.HUMAN, text: "التحدث مع موظف", from: "966501110006" });
    expect(toInbound({ id: "m2", chat: contact.chatId!, type: "text", text: "متى الدخول؟" }, contact, menu)).toMatchObject({ type: "text", text: "متى الدخول؟" });
    expect(toInbound({ id: "m3", chat: contact.chatId!, type: "text", text: "2" }, contact, null).replyId).toBeUndefined();
    expect(toInbound({ id: "m4", chat: contact.chatId!, type: "image", text: "" }, contact, menu)).toMatchObject({ type: "image" });
    expect(toInbound({ id: "m5", chat: contact.chatId!, type: "text", text: "1" }, contact, { junk: true }).replyId).toBeUndefined();
  });

  it("WB-U05 a hidden-number guest flows under the privacy key (no digits of a phone are invented)", () => {
    const contact = contactOf("204587116371@lid")!;
    expect(toInbound({ id: "m", chat: contact.chatId!, type: "text", text: "مرحبا" }, contact, null).from).toBe("lid:204587116371");
  });

  it("WB-U06 message ids are kept hashed (a WhatsApp Web id contains the sender's number)", async () => {
    const h = await sha256Hex("false_966501110006@c.us_3EB0C431D6B7F7F3A2C1");
    expect(h).toMatch(/^[0-9a-f]{64}$/);
    expect(h).not.toContain("966501110006");
  });
});
