/**
 * The closing of the day through the staff UI (A2/A3, migration 0063) — the UI facet of tests/sql/accounting_a2_tests.sql
 * and the demo test DC02–DC07: the boxes computed by the system, a difference needs its reason, the review before
 * sending, the window after it, and the request the management decides.
 */
import { test, expect } from "./fixtures";

test.describe("day closing", () => {
  test("DC12 the supervisor counts the boxes, explains the difference, reviews and sends; the closing is open for its window", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await go("/staff/day-close");
    await expect(page.getByRole("heading", { name: "إقفال اليوم" })).toBeVisible();
    await expect(page.getByTestId("closing-state")).toContainText("لم يبدأ");
    const cash = page.getByTestId("closing-box-cash");
    const pos = page.getByTestId("closing-box-pos");
    await expect(cash).toContainText("سجّل النظام");
    // a difference shows at once; sending without its reason is stopped at the review
    await cash.getByLabel("النقد: المُدخل").fill("1");
    await expect(page.getByTestId("closing-diff-cash")).toContainText("الفرق");
    await pos.getByLabel("الشبكة: المُدخل").fill("0");
    await page.getByRole("button", { name: "مراجعة وإرسال" }).click();
    const dlg = page.getByRole("dialog");
    await expect(dlg.getByTestId("closing-review")).toBeVisible();
    await expect(dlg.getByText(/فرق بلا سبب: النقد/)).toBeVisible();
    await dlg.getByRole("button", { name: "إغلاق" }).first().click();
    await cash.getByLabel("النقد: سبب الفرق").fill("عُدّ قبل تسليم الوردية");
    await pos.getByLabel("الشبكة: سبب الفرق").fill("الجهاز لم يُسوَّ بعد");
    await page.getByRole("button", { name: "مراجعة وإرسال" }).click();
    await expect(dlg.getByRole("button", { name: "إرسال الإقفال" })).toHaveCount(0);
    await dlg.getByLabel("راجعت الأرقام وهي صحيحة").check();
    await dlg.getByRole("button", { name: "إرسال الإقفال" }).click();
    await expect(dlg).toBeHidden();
    await expect(page.getByTestId("closing-state")).toContainText("أُرسل — التعديل مفتوح");
    await expect(page.getByText(/أُرسل الإقفال. يمكن تعديله حتى/)).toBeVisible();
    // inside the window the edit asks for its reason
    await page.getByRole("button", { name: "تعديل الإقفال" }).click();
    await expect(page.getByTestId("closing-amend")).toBeVisible();
    await expect(page.getByRole("button", { name: "حفظ التعديل" })).toBeDisabled();
    await page.getByTestId("closing-amend").locator("textarea").fill("تصحيح العدّ");
    await cash.getByLabel("النقد: المُدخل").fill("2");
    await page.getByRole("button", { name: "حفظ التعديل" }).click();
    await expect(page.getByText("حُفظ التعديل وسُجّل للمراجعة.")).toBeVisible();
    await expect(page.getByTestId("closing-archive")).toContainText("أُرسل — التعديل مفتوح");
  });

  test("DC13 the owner changes the branch's edit window (a setting, 30 minutes by default) from the closing page", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/staff/day-close");
    await expect(page.getByTestId("closing-window-setting")).toContainText("30");
    await page.getByTestId("closing-window-setting").getByRole("button", { name: "تغيير" }).click();
    await page.getByLabel("مهلة التعديل بالدقائق").fill("45");
    await page.getByTestId("closing-window-setting").getByRole("button", { name: "حفظ", exact: true }).click();
    await expect(page.getByTestId("closing-window-setting")).toContainText("45");
  });
});
