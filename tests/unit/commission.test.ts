import { describe, expect, it } from "vitest";
import { bpToPercent, percentToBp } from "../../src/lib/money";

/** The owner's decision of 31 Oct 2026 (0051): every booking source has a commission the owner sets, 0–100%. */
describe("CM01 a source's commission is typed as a percentage and kept in basis points", () => {
  it("reads 15, 12.5, 0 and 100 (and Arabic digits, the Arabic decimal point, a trailing %)", () => {
    expect(percentToBp("15")).toBe(1500);
    expect(percentToBp("12.5")).toBe(1250);
    expect(percentToBp("0")).toBe(0);
    expect(percentToBp("100")).toBe(10000);
    expect(percentToBp("١٥")).toBe(1500);
    expect(percentToBp("7٫25")).toBe(725);
    expect(percentToBp("15%")).toBe(1500);
  });
  it("refuses what is not a percentage 0–100 with at most two decimals", () => {
    for (const t of ["", "abc", "-5", "100.01", "150", "12.345", "1,5"]) expect(percentToBp(t)).toBeNull();
  });
  it("shows the rate back without trailing zeros", () => {
    expect(bpToPercent(1500)).toBe("15");
    expect(bpToPercent(1250)).toBe("12.5");
    expect(bpToPercent(725)).toBe("7.25");
    expect(bpToPercent(null)).toBe("0");
  });
});
