import { describe, expect, it } from "vitest";
import { checkIdentityNumber, checkMinAge, checkPersonName, checkPhone, latinDigits, maxBirthDate } from "../../src/lib/validation";

/** The form-side mirror of migration 0047 must agree with the server rule for rule (VD01–VD06 run against the server). */
describe("VD07 the forms apply the same data rules as the server (0047)", () => {
  it("reads Arabic-Indic and Persian digits as 0–9", () => {
    expect(latinDigits("٠٥٥١٢٣٤٥٦٧")).toBe("0551234567");
    expect(latinDigits("۰۵۵")).toBe("055");
  });

  it("keeps a Saudi mobile as 05XXXXXXXX whatever way it is written, and an international number as +digits", () => {
    for (const v of ["0551234567", "551234567", "966551234567", "+966 55 123 4567", "00966551234567", "٠٥٥١٢٣٤٥٦٧"]) expect(checkPhone(v, true)).toBe("0551234567");
    expect(checkPhone("+44 7700 900123", true)).toBe("+447700900123");
    expect(checkPhone("", false)).toBeNull();
  });

  it("refuses an empty required phone, a short number, a landline and a malformed +966 number", () => {
    expect(() => checkPhone("", true)).toThrow("VALIDATION: phone_required");
    for (const v of ["12345", "0412345678", "05123456", "+966412345678", "05x1234567"]) expect(() => checkPhone(v, false)).toThrow("VALIDATION: phone_format");
  });

  it("accepts names in Arabic or Latin letters and refuses digits or symbols", () => {
    for (const v of ["محمد عبدالله الحربي", "John O'Neil", "عبد الرحمن آل سعود", "Anne-Marie Dupont"]) expect(() => checkPersonName(v)).not.toThrow();
    for (const v of ["محمد 123", "R2-D2", "@@", "أ", "Ali \u00d7 Bob", "أحمد \u00f7"]) expect(() => checkPersonName(v)).toThrow("VALIDATION: name_letters_only");
  });

  it("refuses anyone under 15 on the day; 15 exactly is accepted", () => {
    expect(() => checkMinAge("2011-10-30", "2026-10-29")).toThrow("VALIDATION: minimum_age_15");
    expect(() => checkMinAge("2011-10-29", "2026-10-29")).not.toThrow();
    expect(maxBirthDate("2026-10-29")).toBe("2011-10-29");
  });

  it("a national ID starts with 1 and an iqama with 2", () => {
    expect(() => checkIdentityNumber("national_id", "1023456789")).not.toThrow();
    expect(() => checkIdentityNumber("national_id", "2023456789")).toThrow("VALIDATION: identity_number_format");
    expect(() => checkIdentityNumber("iqama", "2023456789")).not.toThrow();
    expect(() => checkIdentityNumber("iqama", "1023456789")).toThrow("VALIDATION: identity_number_format");
  });
});
