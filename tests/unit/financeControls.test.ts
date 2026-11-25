import { describe, expect, it } from "vitest";
import { parseFinanceThreshold } from "../../src/lib/financeControls";
describe("finance thresholds", () => {
  it("accepts Arabic digits", () => expect(parseFinanceThreshold("١٥٠٠")).toBe(1500));
  it("keeps blank as inheritance, not zero", () => expect(parseFinanceThreshold("")).toBeNull());
  it("accepts integer boundaries", () => { expect(parseFinanceThreshold("0")).toBe(0); expect(parseFinanceThreshold("10000",10000)).toBe(10000); });
  it.each(["-1","2.5","1e6","Infinity","1234567890123"])("rejects malformed %s", v => expect(() => parseFinanceThreshold(v)).toThrow());
  it("checks percentage basis point range", () => expect(() => parseFinanceThreshold("10001",10000)).toThrow());
});
