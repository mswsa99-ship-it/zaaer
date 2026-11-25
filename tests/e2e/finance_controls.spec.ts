/**
 * Phase 4 money controls through the staff UI (plan items 4.1 «M1 الوصول» and 4.4 «M4 الإقفال بالعدّ الأعمى») —
 * the UI facet of those acceptance criteria. The server-side half (the SQL refusals the plan asks for) is separate
 * and not covered here.
 *
 * 4.1: no voucher at the arrival without an explicit «استلمت» confirmation, no amount over the shortage, and no
 *      prefilled amount. 4.4: the counter writes what was actually counted before seeing the system's figure; the
 *      system's figures appear in the review before sending and stay visible after it.
 */
import { test, expect } from "./fixtures";
import type { Page } from "@playwright/test";

/** Opens the stay whose unit is `room`, among the reservations of `status` (same helper as stay-cycle.spec). */
async function openByRoom(page: Page, go: (p: string) => Promise<void>, room: string, status: string) {
  await go("/staff/reservations");
  await page.locator("select").filter({ has: page.locator(`option[value="${status}"]`) }).selectOption(status);
  const row = page.locator("table tbody tr").filter({ has: page.locator("td:nth-child(3)", { hasText: room }) }).first();
  await expect(row).toBeVisible();
  await row.getByRole("link", { name: "فتح" }).click();
  await page.waitForURL(/#\/staff\/reservations\/[0-9a-f-]+/);
  await expect(page.getByTestId("stay-cycle")).toBeVisible();
}

test.describe("phase 4 money controls", () => {
  test("الوصول: لا تعبئة مسبقة للمبلغ، والسند بتأكيد «استلمت» صريح وبحد أقصى قيمة النقص", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await openByRoom(page, go, "203", "confirmed");
    const arrival = page.getByTestId("arrival");
    await expect(arrival).toContainText("الشروط الثابتة مكتملة");
    // this booking's first night is already paid: capped at the shortage, no rent voucher is offered at the arrival
    await expect(arrival.locator("fieldset").filter({ hasText: "سند قبض الإيجار" })).toHaveCount(0);
    const deposit = arrival.locator("fieldset").filter({ hasText: "سند قبض التأمين" });
    // no prefilled amount: the field starts empty
    await expect(deposit.locator("input[data-money]")).toHaveValue("");
    // over the shortage (the branch's 50) is refused, and nothing is recorded
    await deposit.locator("input[data-money]").fill("5000");
    await arrival.getByRole("button", { name: "تسجيل الوصول" }).click();
    await expect(arrival).toContainText("أكبر من المطلوب قبل الوصول");
    await expect(page.getByTestId("stay-notice")).toHaveCount(0);
    // without the explicit «استلمت» confirmation no voucher is written
    await deposit.locator("input[data-money]").fill("50");
    await arrival.getByRole("button", { name: "تسجيل الوصول" }).click();
    await expect(arrival).toContainText("استلمت المبلغ");
    await expect(page.getByTestId("stay-notice")).toHaveCount(0);
    // confirmed: the arrival is recorded with the deposit voucher
    await deposit.getByLabel(/استلمت المبلغ/).check();
    await arrival.getByRole("button", { name: "تسجيل الوصول" }).click();
    await expect(page.getByTestId("stay-notice")).toContainText("سُجِّل الوصول");
    await expect(page.getByTestId("stay-notice")).toContainText("سند التأمين");
  });

  test("إقفال اليوم: العدّ أعمى — لا رقم نظام قبل الإرسال، ويظهر في المراجعة وبعدها", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await go("/staff/day-close");
    await expect(page.getByTestId("closing-state")).toContainText("لم يبدأ");
    const cash = page.getByTestId("closing-box-cash");
    const pos = page.getByTestId("closing-box-pos");
    // the blind count: no system figure and no live difference while counting, and no system matrix
    await expect(cash).not.toContainText("سجّل النظام");
    await expect(pos).not.toContainText("سجّل النظام");
    await expect(page.getByTestId("closing-matrix")).toHaveCount(0);
    await cash.getByLabel("النقد: المُدخل").fill("1");
    await expect(page.getByTestId("closing-diff-cash")).toHaveCount(0);
    await pos.getByLabel("الشبكة: المُدخل").fill("0");
    // the review reveals the system's figures and the differences after the count is written
    await page.getByRole("button", { name: "مراجعة وإرسال" }).click();
    const dlg = page.getByRole("dialog");
    await expect(dlg.getByTestId("closing-review")).toBeVisible();
    await expect(dlg.getByTestId("closing-review")).toContainText("النظام");
    await expect(dlg.getByText(/فرق بلا سبب: النقد/)).toBeVisible();
    await dlg.getByRole("button", { name: "إغلاق" }).first().click();
    await cash.getByLabel("النقد: سبب الفرق").fill("عُدّ قبل تسليم الوردية");
    await pos.getByLabel("الشبكة: سبب الفرق").fill("الجهاز لم يُسوَّ بعد");
    await page.getByRole("button", { name: "مراجعة وإرسال" }).click();
    await dlg.getByLabel("راجعت الأرقام وهي صحيحة").check();
    await dlg.getByRole("button", { name: "إرسال الإقفال" }).click();
    await expect(dlg).toBeHidden();
    await expect(page.getByTestId("closing-state")).toContainText("أُرسل — التعديل مفتوح");
    // after sending, the system's figures and the matrix are visible
    await expect(cash).toContainText("سجّل النظام");
    await expect(page.getByTestId("closing-matrix")).toBeVisible();
  });
});
