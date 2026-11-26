/** F1: a late assistant reply is labelled with its question and never carries a confirmable action. */
import { describe, it, expect } from "vitest";
import { opsLateReplyText } from "../../src/lib/opsLate";
import type { OpsReply } from "../../src/lib/api";

const base: OpsReply = { conversation_id: "c1", reply: "الجواب", proposals: [], mode: "ai" };
describe("opsLateReplyText", () => {
  it("names the question it answers", () => {
    expect(opsLateReplyText("كم وحدة؟", base)).toBe("وصل ردّ متأخر على سؤالك «كم وحدة؟»:\nالجواب");
  });
  it("shortens a long question", () => {
    expect(opsLateReplyText("س".repeat(200), base)).toContain("س".repeat(80) + "…");
  });
  it("collapses whitespace and never splits an emoji at the cut", () => {
    expect(opsLateReplyText("كم   وحدة\n\nمتسخة؟", base)).toContain("«كم وحدة متسخة؟»");
    const t = opsLateReplyText("😀".repeat(100), base);
    expect(t).toContain("😀".repeat(80) + "…");
    expect(t).not.toMatch(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])/);
  });
  it("names a proposed action as text only and says it was not offered for confirmation", () => {
    const t = opsLateReplyText("q", { ...base, proposals: [{ id: "p1", action: "complete_task", summary: "إكمال مهمة تنظيف", args: {} }] });
    expect(t).toContain("• إكمال مهمة تنظيف");
    expect(t).toContain("لم يُعرض هنا للتأكيد");
    expect(t).not.toContain("p1");
  });
});
