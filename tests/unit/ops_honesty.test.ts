/** Plan 6.13 (U6): the assistant relays the staff note as typed, and never shows figures clean beside open anomaly items (4.6). */
import { describe, it, expect } from "vitest";
import { extractStaffNote, applyVerbatimNote, withAnomalyNotice } from "../../supabase/functions/_shared/ops";

describe("staff note is relayed verbatim", () => {
  it("takes everything after «ملاحظة:» exactly as typed", () => {
    expect(extractStaffNote("اقترح مهمة تنظيف للوحدة 105، ملاحظة: المكيف يقطّر ماءً  وفيه   رائحة")).toBe("المكيف يقطّر ماءً  وفيه   رائحة");
  });
  it("takes a quoted text after the word ملاحظة and drops the quotes", () => {
    expect(extractStaffNote("أضف ملاحظة «النزيل طلب وسادة إضافية» على الحجز")).toBe("النزيل طلب وسادة إضافية");
  });
  it("no note in the message gives null (negative control)", () => {
    expect(extractStaffNote("كم وحدة جاهزة اليوم؟")).toBeNull();
    expect(extractStaffNote("")).toBeNull();
  });
  it("replaces the model's reworded note, keeps other args", () => {
    const proposed = { action: "create_task", summary: "مهمة تنظيف", args: { room_id: "r1", note: "تسرب في المكيف (صياغة النموذج)" } };
    const out = applyVerbatimNote(proposed, "ملاحظة: المكيف يقطّر") as typeof proposed;
    expect(out.args.note).toBe("المكيف يقطّر");
    expect(out.args.room_id).toBe("r1");
    expect(proposed.args.note).toContain("صياغة النموذج");   // the input is not mutated
  });
  it("leaves the model's args alone when the staff gave no note, and refuses a note over 300 characters", () => {
    const proposed = { action: "create_task", summary: "مهمة", args: { note: "من النموذج" } };
    expect(applyVerbatimNote(proposed, "اقترح مهمة")).toBe(proposed);
    expect(() => applyVerbatimNote(proposed, "ملاحظة: " + "ا".repeat(301))).toThrow("note_too_long");
  });
});

describe("figures carry the open anomaly items", () => {
  const reply = "المتبقي على المقيمين: 1,250.00 ر.س";
  it("appends one line with the count when figures are shown and anomalies are open", () => {
    const out = withAnomalyNotice(reply, { count: 3 });
    expect(out.startsWith(reply)).toBe(true);
    expect(out).toContain("3 بند شذوذ");
  });
  it("adds nothing when there are no open items, no figures, or the reply already says it (negative controls)", () => {
    expect(withAnomalyNotice(reply, { count: 0 })).toBe(reply);
    expect(withAnomalyNotice(reply, null)).toBe(reply);
    expect(withAnomalyNotice("الوحدة 105 جاهزة", { count: 3 })).toBe("الوحدة 105 جاهزة");
    const said = reply + "\nيوجد بنود شذوذ مفتوحة.";
    expect(withAnomalyNotice(said, { count: 3 })).toBe(said);
  });
});
