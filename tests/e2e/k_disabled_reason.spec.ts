/** Plan 6.8 (U9): every disabled button says why. New reservation form: each blocker names its reason. */
import { test, expect } from "./fixtures";

test.describe("disabled buttons say why (6.8)", () => {
  test("new reservation: empty name, then capacity, each gives a visible reason; the button enables when fixed", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await go("/staff/reservations/new");
    const create = page.getByTestId("create-reservation");
    await expect(create).toBeDisabled();
    await expect(page.getByTestId("create-block-reason")).toContainText("اكتب اسم النزيل");
    await expect(create).toHaveAttribute("aria-describedby", "create-block-reason");
    await page.locator("div:has(> label:has-text('الاسم (مطلوب)')) input").first().fill("نزيل اختبار السبب");
    await expect(page.getByTestId("create-block-reason")).toContainText("الجوال");
    await page.getByPlaceholder("05xxxxxxxx").fill("0509998877");
    await page.waitForTimeout(500);
    await expect(create).toBeEnabled();
    await expect(page.getByTestId("create-block-reason")).toHaveCount(0);
    // capacity: far more adults than any unit holds
    await page.locator("div:has(> label:has-text('بالغون')) input").first().fill("40");
    await expect(create).toBeDisabled();
    await expect(page.getByTestId("create-block-reason")).toContainText("سعة نوع الوحدة");
    if (process.env.K_SHOTS) await page.screenshot({ path: "/tmp/k-disabled-reason.png" });
    await page.locator("div:has(> label:has-text('بالغون')) input").first().fill("1");
    await expect(create).toBeEnabled();
  });
});
