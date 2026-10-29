import { describe, expect, it } from "vitest";
import { formatMoneyInput, moneyTextToHalalas, sanitizeMoneyText } from "../../src/lib/money";

/** The owner's note 2: an amount is typed in riyals; halalas only after the point (B2 of the unified plan). */
describe("AM01 the money field starts empty and takes riyals, halalas only after the point", () => {
  it("starts empty for nothing or zero, and shows whole riyals without .00", () => {
    expect(formatMoneyInput(null)).toBe("");
    expect(formatMoneyInput(0)).toBe("");
    expect(formatMoneyInput(25000)).toBe("250");
    expect(formatMoneyInput(25050)).toBe("250.50");
  });

  it("typing 2 is two riyals, not 0.002; Arabic digits and the Arabic decimal mark are read", () => {
    expect(moneyTextToHalalas(sanitizeMoneyText("2", false)!)).toBe(200);
    expect(moneyTextToHalalas(sanitizeMoneyText("٢٥٠", false)!)).toBe(25000);
    expect(moneyTextToHalalas(sanitizeMoneyText("٢٥٠٫٥", false)!)).toBe(25050);
    expect(moneyTextToHalalas(sanitizeMoneyText("1,200.75", false)!)).toBe(120075);
  });

  it("a comma ending the number is its decimal point; thousands commas only in full groups; any other comma is refused", () => {
    expect(moneyTextToHalalas(sanitizeMoneyText("12,50", false)!)).toBe(1250);
    expect(moneyTextToHalalas(sanitizeMoneyText("12,5", false)!)).toBe(1250);
    expect(moneyTextToHalalas(sanitizeMoneyText("1,250,000", false)!)).toBe(125000000);
    expect(sanitizeMoneyText("12,5000", false)).toBeNull();
    expect(sanitizeMoneyText("1,2,3", false)).toBeNull();
  });

  it("refuses a third decimal, letters and a second point; a minus only where the field allows it", () => {
    expect(sanitizeMoneyText("2.505", false)).toBeNull();
    expect(sanitizeMoneyText("2a", false)).toBeNull();
    expect(sanitizeMoneyText("2.5.1", false)).toBeNull();
    expect(sanitizeMoneyText("-50", false)).toBe("50");
    expect(sanitizeMoneyText("-50", true)).toBe("-50");
    expect(moneyTextToHalalas("")).toBeNull();
    expect(moneyTextToHalalas(".")).toBeNull();
  });
});
