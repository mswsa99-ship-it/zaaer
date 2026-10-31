import { describe, it, expect } from "vitest";
import { nextStep, stagesDone, type StayProgressInput } from "../../src/components/StayProgress";

const base: StayProgressInput = { status: "confirmed", identity_status: "pending", has_room: true, total_halalas: 15000, paid_halalas: 15000, check_out: "2026-11-02", today: "2026-10-31" };

describe("the reservation's stages and its next step (U3)", () => {
  it("UB03 each state gives one next step, in the order of the stay", () => {
    expect(nextStep({ ...base, has_room: false })?.section).toBe("room");
    expect(nextStep(base)?.title).toBe("مطابقة الهوية");
    expect(nextStep({ ...base, identity_status: "verified" })?.title).toBe("تسجيل الوصول");
    expect(nextStep({ ...base, status: "checked_in", identity_status: "verified", paid_halalas: 7500 })?.section).toBe("ops");
    expect(nextStep({ ...base, status: "checked_in", identity_status: "verified" })).toBeNull();
    expect(nextStep({ ...base, status: "checked_in", identity_status: "verified", check_out: "2026-10-31" })?.title).toBe("تسجيل المغادرة");
    expect(nextStep({ ...base, status: "checked_out" })?.title).toBe("فحص الوحدة ورد التأمين");
    for (const s of ["closed", "cancelled", "rejected", "no_show", "draft"]) expect(nextStep({ ...base, status: s })).toBeNull();
    expect([stagesDone(base), stagesDone({ ...base, identity_status: "verified" }), stagesDone({ ...base, status: "checked_in" }), stagesDone({ ...base, status: "closed" })]).toEqual([1, 2, 3, 5]);
  });
});
