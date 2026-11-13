import { describe, it, expect } from "vitest";
import { candidateKey, posDays, selectedTotal, suggestTargets } from "../../src/lib/bankMatch";
import type { BankCandidate } from "../../src/lib/api";

const rec = (id: string, signed: number, day: string, method: string | null = "pos", type: BankCandidate["type"] = "voucher"): BankCandidate =>
  ({ type, id, number: "N-" + id, label: "x", amount_halalas: Math.abs(signed), signed_halalas: signed, at: day + "T10:00:00Z", day, method, exact: false });

describe("matching a bank movement with the records that explain it (A8)", () => {
  const records = [rec("a", 20000, "2026-11-10"), rec("b", 10000, "2026-11-10"), rec("r", -3000, "2026-11-10"), rec("c", 5000, "2026-11-09"),
    rec("t", 27000, "2026-11-10", "bank_transfer"), rec("x", 900, "2026-11-10", null, "expense")];

  it("MT20 the card-terminal vouchers are offered a day at a time, the latest day first, a card refund counted below zero", () => {
    expect(posDays(records)).toEqual([
      { day: "2026-11-10", keys: ["voucher:a", "voucher:b", "voucher:r"], count: 3, total_halalas: 27000 },
      { day: "2026-11-09", keys: ["voucher:c"], count: 1, total_halalas: 5000 },
    ]);
    expect(posDays([rec("t", 100, "2026-11-10", "bank_transfer")])).toEqual([]);
  });

  it("MT21 the total of the ticked records is in the movement's direction", () => {
    expect(selectedTotal(records, new Set(["voucher:a", "voucher:r"]))).toBe(17000);
    expect(selectedTotal(records, new Set())).toBe(0);
    expect(candidateKey({ type: "expense", id: "x" })).toBe("expense:x");
  });

  it("MT22 a terminal deposit opens with the day whose card vouchers add up to it, a transfer with the one record of its amount, anything else with nothing ticked", () => {
    expect(suggestTargets(records, 27000, "pos_settlement")).toEqual(["voucher:a", "voucher:b", "voucher:r"]);
    expect(suggestTargets(records, 27000, "transfer_in")).toEqual(["voucher:t"]);
    expect(suggestTargets(records, 5000, "pos_settlement")).toEqual(["voucher:c"]);
    expect(suggestTargets(records, 26460, "pos_settlement")).toEqual([]);
  });

  it("MT23 only a record whose way of paying fits is suggested, and nothing when two tie", () => {
    // a deposit or a transfer is never a card voucher; a terminal deposit is never a transfer voucher
    expect(suggestTargets(records, 5000, "deposit")).toEqual([]);
    expect(suggestTargets([rec("p", 30000, "2026-11-10"), rec("q", 30000, "2026-11-10", "bank_transfer")], 30000, "transfer_in")).toEqual(["voucher:q"]);
    expect(suggestTargets([rec("q", 30000, "2026-11-10", "bank_transfer")], 30000, "pos_settlement")).toEqual([]);
    // two transfer vouchers of the amount at the same time, or two card days of the amount: the owner chooses
    expect(suggestTargets([rec("q1", 30000, "2026-11-10", "bank_transfer"), rec("q2", 30000, "2026-11-10", "bank_transfer")], 30000, "transfer_in")).toEqual([]);
    expect(suggestTargets([rec("d1", 30000, "2026-11-10"), rec("d2", 30000, "2026-11-09")], 30000, "pos_settlement")).toEqual([]);
  });
});
