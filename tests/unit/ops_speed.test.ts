/**
 * خطة التصحيح 6.12 (U5 سرعة المساعد): سؤال بسيط يُوجَّه إلى نموذج أسرع (flash-lite عند توفره ضمن النماذج
 * الاحتياطية المعتمدة) مع بقاء السلسلة كاملة احتياطًا، وحد زمني برسالة واضحة لا يترك الموظف معلّقًا.
 * أسماء وصفية بلا رموز (العقد المشترك). قياس الزمن الفعلي على النموذج الحي غير ممكن في هذه البيئة.
 */
import { describe, it, expect, vi, afterEach } from "vitest";
import { isSimpleOpsQuestion, opsModelOrder } from "../../supabase/functions/_shared/ops";
import { withTimeout } from "../../src/lib/async";

describe("تصنيف السؤال البسيط", () => {
  it("أسئلة الحالة القصيرة بسيطة", () => {
    expect(isSimpleOpsQuestion("كم وحدة متسخة الآن؟")).toBe(true);
    expect(isSimpleOpsQuestion("من يصل اليوم؟")).toBe(true);
    expect(isSimpleOpsQuestion("ما وضع اليوم؟")).toBe(true);
    expect(isSimpleOpsQuestion("من عليه رصيد متبقٍ من المقيمين؟")).toBe(true);
  });
  it("طلبات الإجراء ليست بسيطة مهما قصُرت", () => {
    expect(isSimpleOpsQuestion("أنشئ مهمة تنظيف للوحدة 101")).toBe(false);
    expect(isSimpleOpsQuestion("مدد الحجز R-102 ليلة")).toBe(false);
    expect(isSimpleOpsQuestion("ألغِ الحجز R-7")).toBe(false);
    expect(isSimpleOpsQuestion("سند قبض 500 نقدًا للحجز R-9")).toBe(false);
    expect(isSimpleOpsQuestion("بدّل وحدة الحجز R-3 إلى 204")).toBe(false);
    expect(isSimpleOpsQuestion("أصدر فاتورة للحجز R-5")).toBe(false);
  });
  it("السؤال الطويل أو المركّب ليس بسيطًا", () => {
    expect(isSimpleOpsQuestion("كم وحدة متسخة الآن؟ ".repeat(12))).toBe(false);
    expect(isSimpleOpsQuestion("")).toBe(false);
  });
});

describe("ترتيب النماذج لسؤال بسيط", () => {
  const configured = "gemini-3.8-flash";
  const fallbacks = ["gemini-3.6-flash", "gemini-3.5-flash-lite"];
  it("السؤال البسيط يبدأ بأسرع نموذج معتمد (flash-lite) وتبقى السلسلة كاملة بعده", () => {
    expect(opsModelOrder("كم وحدة متسخة الآن؟", configured, fallbacks)).toEqual(["gemini-3.5-flash-lite", "gemini-3.8-flash", "gemini-3.6-flash"]);
  });
  it("طلب الإجراء يبقى على الترتيب المعتمد كما هو", () => {
    expect(opsModelOrder("أنشئ مهمة تنظيف للوحدة 101", configured, fallbacks)).toEqual([configured, ...fallbacks]);
  });
  it("بلا نموذج أسرع ضمن الاحتياطية لا يتغير شيء", () => {
    expect(opsModelOrder("كم وحدة متسخة الآن؟", configured, ["gemini-3.6-flash"])).toEqual([configured, "gemini-3.6-flash"]);
    expect(opsModelOrder("كم وحدة متسخة الآن؟", configured, [])).toEqual([configured]);
  });
  it("النموذج المعتمد نفسه flash-lite: لا تكرار ولا تغيير", () => {
    expect(opsModelOrder("كم وحدة متسخة الآن؟", "gemini-3.5-flash-lite", fallbacks)).toEqual(["gemini-3.5-flash-lite", "gemini-3.6-flash"]);
  });
});

describe("الحد الزمني برسالة واضحة", () => {
  afterEach(() => vi.useRealTimers());
  it("يجيب بالقيمة حين يصل الرد قبل الحد", async () => {
    vi.useFakeTimers();
    const slow = new Promise<string>((r) => setTimeout(() => r("الرد"), 1000));
    const p = withTimeout(slow, 5000, () => "رسالة الحد");
    await vi.advanceTimersByTimeAsync(1500);
    await expect(p).resolves.toBe("الرد");
  });
  it("عند تجاوز الحد يعيد قيمة الحد الواضحة ويستدعي إشعار التجاوز", async () => {
    vi.useFakeTimers();
    const onTimeout = vi.fn();
    const slow = new Promise<string>((r) => setTimeout(() => r("الرد"), 60_000));
    const p = withTimeout(slow, 5000, () => "رسالة الحد", onTimeout);
    await vi.advanceTimersByTimeAsync(6000);
    await expect(p).resolves.toBe("رسالة الحد");
    expect(onTimeout).toHaveBeenCalledTimes(1);
  });
  it("الرد المتأخر بعد الحد يُهمل ولا يغيّر النتيجة ولا يرمي", async () => {
    vi.useFakeTimers();
    const slow = new Promise<string>((r) => setTimeout(() => r("الرد"), 60_000));
    const p = withTimeout(slow, 5000, () => "رسالة الحد");
    await vi.advanceTimersByTimeAsync(120_000);
    await expect(p).resolves.toBe("رسالة الحد");
  });
});
