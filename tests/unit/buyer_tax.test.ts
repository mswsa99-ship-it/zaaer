import { describe, it, expect } from "vitest";
import { checkVatNumber, checkBuyerAddress } from "../../src/lib/buyerTax";

describe("buyer tax data (ZATCA standard invoice)", () => {
  it("accepts an empty VAT number and a 15-digit one starting and ending with 3", () => {
    expect(() => checkVatNumber("")).not.toThrow();
    expect(() => checkVatNumber("300000000000003")).not.toThrow();
    expect(() => checkVatNumber("٣٠٠٠٠٠٠٠٠٠٠٠٠٠٣")).not.toThrow();
  });
  it("rejects a wrong length or a wrong first or last digit", () => {
    for (const v of ["30000000000003", "400000000000003", "300000000000004", "3000000000000a3"]) expect(() => checkVatNumber(v)).toThrow(/vat_number_format/);
  });
  it("needs street, building number, postal code, city and district; a PO box is not required", () => {
    expect(checkBuyerAddress({})).toEqual(["street", "building_number", "postal_code", "city", "district"]);
    expect(checkBuyerAddress({ street: "الملك فهد", building_number: "1234", postal_code: "52366", city: "بريدة", district: "الصفراء" })).toEqual([]);
    expect(checkBuyerAddress({ street: "x", building_number: "12", postal_code: "5236", city: "c", district: "d" })).toEqual(["building_number", "postal_code"]);
  });
});
