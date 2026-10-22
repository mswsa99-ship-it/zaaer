import { describe, it, expect, vi, afterEach } from "vitest";
import { todayISO, isoDateIn, addDaysISO } from "../../src/lib/utils";

/**
 * Business dates are the property's (Asia/Riyadh by default), never UTC's: between 00:00 and 03:00 in Riyadh the
 * UTC date is still yesterday, which used to show yesterday's arrivals, default new bookings to yesterday, etc.
 */
describe("property-local dates", () => {
  afterEach(() => vi.useRealTimers());

  it("01:30 in Riyadh is already the next calendar day there, while UTC is still on the previous one", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-10-22T22:30:00Z"));
    expect(todayISO()).toBe("2026-10-23");
    expect(new Date().toISOString().slice(0, 10)).toBe("2026-10-22");
  });

  it("the same day before local midnight; a branch's own zone can be passed", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-10-22T20:59:00Z"));   // 23:59 in Riyadh, 00:59 in Dubai
    expect(todayISO()).toBe("2026-10-22");
    expect(todayISO("Asia/Dubai")).toBe("2026-10-23");
  });

  it("an invalid zone falls back to the property zone; addDaysISO is plain calendar arithmetic", () => {
    expect(isoDateIn(new Date("2026-10-22T22:30:00Z"), "Not/AZone")).toBe("2026-10-23");
    expect(addDaysISO("2028-02-28", 1)).toBe("2028-02-29");
    expect(addDaysISO("2026-03-01", -1)).toBe("2026-02-28");
  });
});

describe("edge functions: the branch-local day (prompt date, ops context)", async () => {
  const { localDay } = await import("../../supabase/functions/_shared/dates");
  it("is the branch's calendar day, not the UTC one, and survives a bad zone name", () => {
    const at = new Date("2026-10-22T22:30:00Z");   // 01:30 in Riyadh
    expect(localDay("Asia/Riyadh", at)).toBe("2026-10-23");
    expect(localDay(null, at)).toBe("2026-10-23");
    expect(localDay("Riyadh", at)).toBe("2026-10-23");
    expect(localDay("UTC", at)).toBe("2026-10-22");
  });
});
