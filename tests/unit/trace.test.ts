/**
 * Trace codes (decisions 39 and 60): the code sent with every operation and shown next to a failure message.
 * The server accepts a correlation id only if it matches ^[A-Za-z0-9_-]{6,64}$ and records a failure only if the
 * code matches ^[A-Z0-9]{6,16}$ (0026, 0027) — so what the app generates must always pass both.
 */
import { describe, it, expect } from "vitest";
import { newTraceId, clientSource, errorCode, normalizeTrace } from "../../src/lib/trace";

describe("trace codes", () => {
  it("TR01 a new code is 8 characters the server accepts, without look-alike characters", () => {
    for (let i = 0; i < 500; i++) {
      const c = newTraceId();
      expect(c).toMatch(/^[A-Z0-9]{6,16}$/);
      expect(c).toMatch(/^[A-Za-z0-9_-]{6,64}$/);
      expect(c).toHaveLength(8);
      expect(c).not.toMatch(/[01IO]/);
    }
  });

  it("TR02 codes do not repeat in practice", () => {
    const seen = new Set(Array.from({ length: 5000 }, () => newTraceId()));
    expect(seen.size).toBe(5000);
  });

  it("TR03 the source of a request follows the screen it came from", () => {
    expect(clientSource("/admin/finance")).toBe("admin-app");
    expect(clientSource("/staff/reservations/123")).toBe("staff-app");
    expect(clientSource("/kiosk")).toBe("kiosk");
    expect(clientSource("/")).toBe("guest-app");
    for (const s of ["admin-app", "staff-app", "kiosk", "guest-app"]) expect(s).toMatch(/^[a-z][a-z_-]{1,31}$/);
  });

  it("TR04 only the leading error code is kept, never the message text", () => {
    expect(errorCode("ALLOCATION_CONFLICT")).toBe("ALLOCATION_CONFLICT");
    expect(errorCode("VALIDATION: external_ref_required")).toBe("VALIDATION: external_ref_required");
    expect(errorCode("FORBIDDEN: requires one of {owner}")).toBe("FORBIDDEN");
    expect(errorCode("duplicate key value violates unique constraint \"x\"")).toBe("UNKNOWN");
    expect(errorCode("room 101 of Ahmed")).toBe("UNKNOWN");
    for (const m of ["ALLOCATION_CONFLICT", "VALIDATION: amount", "FORBIDDEN: x"]) expect(errorCode(m)).toMatch(/^[A-Z][A-Z0-9_]{1,48}(: [a-z_0-9]{1,48})?$/);
  });

  it("TR05 a code read from the screen is found as typed or pasted", () => {
    expect(normalizeTrace("k7q2m9xa")).toBe("K7Q2M9XA");
    expect(normalizeTrace(" (رمز التتبع: K7Q2M9XA) ")).toBe("K7Q2M9XA");
    expect(normalizeTrace("K7Q2 M9XA")).toBe("K7Q2M9XA");
    expect(normalizeTrace("tx-12345")).toBe("tx-12345");
  });
});
