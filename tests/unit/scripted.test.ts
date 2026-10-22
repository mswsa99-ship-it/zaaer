import { describe, it, expect } from "vitest";
import { scriptedReply, type PropertyKnowledge } from "../../supabase/functions/_shared/guardrails";

const k: PropertyKnowledge = {
  branchName: "فرع الرياض", checkInTime: "16:00:00", checkOutTime: "12:00:00", address: "طريق الملك فهد", phone: "+966500000000",
  policies: [
    { topic: "wifi", title: "الإنترنت", content: "إنترنت لاسلكي مجاني في جميع الوحدات." },
    { topic: "parking", title: "المواقف", content: "مواقف مجانية أمام المبنى." },
    { topic: "cancellation", title: "الإلغاء", content: "إلغاء مجاني حتى 48 ساعة قبل الوصول." },
  ],
};

describe("deterministic reception — property facts", () => {
  it("answers check-in/out times from the branch record", () => {
    const r = scriptedReply("ما هي مواعيد الوصول والمغادرة؟", "منازل الراحة", undefined, k);
    expect(r.intent).toBe("policy");
    expect(r.text).toContain("16:00");
    expect(r.text).toContain("12:00");
  });
  it("answers wifi / parking / cancellation from public policies only", () => {
    expect(scriptedReply("ما هي بيانات الإنترنت؟", "x", undefined, k).text).toContain("إنترنت لاسلكي");
    expect(scriptedReply("هل توجد مواقف سيارات؟", "x", undefined, k).text).toContain("مواقف مجانية");
    expect(scriptedReply("وش سياسة الإلغاء؟", "x", undefined, k).text).toContain("48 ساعة");
  });
  it("location uses the address; unknown topics are declined honestly with a handoff option", () => {
    expect(scriptedReply("أين يقع الفرع؟", "x", undefined, k).text).toContain("طريق الملك فهد");
    const r = scriptedReply("هل يُسمح بالأطفال؟", "x", undefined, k);
    expect(r.intent).toBe("policy");
    expect(r.text).toMatch(/لا تتوفر لدي معلومة معتمدة/);
    expect(r.actions.some((a) => a.value?.includes("موظف"))).toBe(true);
  });
  it("without knowledge it never invents times", () => {
    const r = scriptedReply("متى أقدر أدخل الشقة؟");
    expect(r.intent).toBe("policy");
    expect(r.text).not.toMatch(/\d{2}:\d{2}/);
  });
  it("availability intent is separate from policy questions, and the generic fallback is marked unknown", () => {
    expect(scriptedReply("أرغب بحجز جديد").intent).toBe("availability");
    expect(scriptedReply("كم سعر الاستوديو؟").intent).toBe("availability");
    expect(scriptedReply("لدي حجز سابق").intent).toBe("existing_booking");
    expect(scriptedReply("بلا بلا").intent).toBe("unknown");
  });
});
