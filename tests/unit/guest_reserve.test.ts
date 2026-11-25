/**
 * The guest quota reserve (0082/0083) as ai-reception wires it — ER01–ER06. fn_ai_guest_reserve admits one screen
 * guest message atomically before it is written; these tests pin the edge side of the contract: who the reserve
 * applies to, what each status answers, and that an admitted message is never counted twice.
 */
import { describe, it, expect } from "vitest";
import { reserveApplies, mapReserveStatus, countedRequests, OTP_LOOKUP_ROUTE } from "../../supabase/functions/_shared/guest_reserve";

describe("guest quota reserve wiring (ER)", () => {
  it("ER01 the reserve guards screen guests only — never the service role, staff, or a WhatsApp turn", () => {
    expect(reserveApplies({ channel: "screen", trustedService: false, staff: false })).toBe(true);
    expect(reserveApplies({ channel: "whatsapp", trustedService: true, staff: false })).toBe(false);
    expect(reserveApplies({ channel: "whatsapp", trustedService: false, staff: false })).toBe(false);
    expect(reserveApplies({ channel: "screen", trustedService: true, staff: false })).toBe(false);
    expect(reserveApplies({ channel: "screen", trustedService: false, staff: true })).toBe(false);
  });

  it("ER02 ok proceeds and carries no reply of its own", () => {
    expect(mapReserveStatus("ok", false)).toEqual({ proceed: true });
  });

  it("ER03 otp_required sends the guest to the phone-code page, consumes nothing, and flags the UI path", () => {
    for (const english of [false, true]) {
      const d = mapReserveStatus("otp_required", english);
      expect(d.proceed).toBe(false);
      expect(d.extra?.otp_required).toBe(true);
      expect(d.actions?.some((a) => a.route === OTP_LOOKUP_ROUTE)).toBe(true);
      expect(d.reply && d.reply.length > 0).toBe(true);
      expect(d.rule).toBe("guest_otp_required");
    }
    expect(mapReserveStatus("otp_required", false).reply).toMatch(/جوال/);
    expect(mapReserveStatus("otp_required", true).reply).toMatch(/phone/i);
  });

  it("ER04 every cap refuses with a scripted reply and a guardrail rule, never an exception", () => {
    for (const status of ["session_limit", "device_limit", "branch_limit", "hotel_limit"]) {
      for (const english of [false, true]) {
        const d = mapReserveStatus(status, english);
        expect(d.proceed, status).toBe(false);
        expect(d.error, status).toBeUndefined();
        expect(typeof d.reply, status).toBe("string");
        expect(d.rule, status).toBeTruthy();
        expect(d.extra?.otp_required, status).toBeUndefined();
      }
    }
  });

  it("ER05 a broken scope fails closed: unknown statuses and the not-found statuses are errors, not admissions", () => {
    for (const status of ["branch_not_found", "conversation_not_found", "error", ""]) {
      const d = mapReserveStatus(status, false);
      expect(d.proceed, status || "(empty)").toBe(false);
      expect(d.error, status || "(empty)").toBeTruthy();
    }
  });

  it("ER06 an admitted message is counted once: the reserve took the request, the bump adds tokens only", () => {
    expect(countedRequests(1, true)).toBe(0);   // reserve already counted it
    expect(countedRequests(1, false)).toBe(1);  // staff / WhatsApp / pre-reserve paths count as before
    expect(countedRequests(0, true)).toBe(0);
    expect(countedRequests(0, false)).toBe(0);
  });
});
