/**
 * خطة التصحيح 6.12 (U5 سرعة المساعد): مؤشر تقدم فوري من لحظة الإرسال حتى الرد. الحد الزمني برسالته الواضحة
 * مختبر وحدةً (tests/unit/ops_speed.test.ts)؛ وتوجيه السؤال البسيط إلى النموذج الأسرع مختبر وحدةً أيضًا،
 * وقياس الزمن الفعلي على النموذج الحي (20 سؤالًا قبل/بعد) لا يمكن في بيئة العرض — يُجرى على التجهيز الحي.
 * أسماء وصفية بلا رموز.
 */
import { test, expect } from "./fixtures";

test.describe("سرعة مساعد العمليات", () => {
  test("مؤشر التقدم يظهر فور الإرسال ويختفي عند وصول الرد، والعدّاد يعمل أثناء الانتظار", async ({ page, loginAs }) => {
    await loginAs("owner");
    // ردّ متأخر 3 ثوانٍ عبر خطاف العرض الموثّق (fn:ai-ops)
    await page.evaluate(() => {
      (window as unknown as { __demoLatency: unknown }).__demoLatency = (t: string) => (t === "fn:ai-ops" ? 4000 : 0);
    });
    await page.getByRole("button", { name: "مساعد العمليات" }).click();
    const input = page.getByPlaceholder("اكتب سؤالك أو طلبك…");
    await expect(input).toBeVisible();
    await input.fill("كم وحدة متسخة الآن؟");
    await input.press("Enter");

    // فورًا: مؤشر التقدم ظاهر قبل وصول الرد
    await expect(page.getByTestId("ops-progress")).toBeVisible({ timeout: 3000 });
    await expect(page.getByTestId("ops-progress")).toContainText("يعمل على سؤالك");
    // والعدّاد يتقدم أثناء الانتظار
    await expect(page.getByTestId("ops-elapsed")).toContainText(/\([1-9]\d* ث\)/, { timeout: 5000 });

    // عند وصول الرد يختفي المؤشر ويعود الإدخال متاحًا
    await expect(page.locator("div.whitespace-pre-wrap").last()).toContainText(/./, { timeout: 15_000 });
    await expect(page.getByTestId("ops-progress")).toBeHidden();
    await expect(input).toBeEnabled();
  });

  test("سؤال ثانٍ بعد ردّ متأخر يعمل بالطريقة نفسها (لا بقايا من الانتظار السابق)", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.evaluate(() => {
      (window as unknown as { __demoLatency: unknown }).__demoLatency = (t: string) => (t === "fn:ai-ops" ? 2500 : 0);
    });
    await page.getByRole("button", { name: "مساعد العمليات" }).click();
    const input = page.getByPlaceholder("اكتب سؤالك أو طلبك…");
    for (const q of ["ما وضع اليوم؟", "من يصل اليوم؟"]) {
      await input.fill(q);
      await input.press("Enter");
      await expect(page.getByTestId("ops-progress")).toBeVisible({ timeout: 3000 });
      await expect(page.getByTestId("ops-progress")).toBeHidden({ timeout: 15_000 });
      await expect(input).toBeEnabled();
    }
    // سؤالان وردّان
    await expect(page.locator("div.whitespace-pre-wrap")).toHaveCount(4);
  });
});
