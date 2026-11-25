/** Plan 6.4 — the booking form is a three-step wizard; a full booking is made through the steps (invented data only). */
import { test, expect } from "./fixtures";

test.describe("booking wizard in three steps", () => {
  test("a complete booking goes through three steps and the draft survives a reload", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/reservations/new", { waitUntil: "networkidle" });
    // step 1 only: the guest's fields are not on screen
    await expect(page.getByTestId("wizard-steps").locator("li")).toHaveCount(3);
    await expect(page.getByTestId("step-1")).toBeVisible();
    await expect(page.getByTestId("step-2")).toBeHidden();
    await expect(page.getByTestId("step-3")).toBeHidden();
    await expect(page.getByRole("button", { name: "إنشاء الحجز" })).toBeHidden();
    await page.getByRole("button", { name: "التالي" }).click();
    // step 2: the guest
    await expect(page.getByTestId("step-2")).toBeVisible();
    await expect(page.getByRole("button", { name: "التالي" })).toHaveAttribute("data-blocked", "true");   // name and phone are required first (the button now explains where, instead of staying dead)
    await page.locator("div:has(> label:has-text('الاسم (مطلوب)')) input").first().fill("ضيف اختبار الخطوات");
    await page.getByPlaceholder("05xxxxxxxx").fill("0501234567");
    // draft: reload and restore
    await page.waitForTimeout(700);
    await page.reload({ waitUntil: "networkidle" });
    await expect(page.getByTestId("reservation-draft")).toBeVisible();
    await page.getByRole("button", { name: "استعادة المسودة" }).click();
    await page.getByRole("button", { name: "التالي" }).click();   // step 1 → 2 (restored dates are valid)
    await expect(page.getByTestId("step-2")).toBeVisible();
    await expect(page.locator("div:has(> label:has-text('الاسم (مطلوب)')) input").first()).toHaveValue("ضيف اختبار الخطوات");
    await page.getByRole("button", { name: "التالي" }).click();
    // step 3: source and price, then create
    await expect(page.getByTestId("step-3")).toBeVisible();
    await expect(page.getByRole("button", { name: "إنشاء الحجز" })).toBeVisible();
    await page.getByRole("button", { name: "السابق" }).click();
    await expect(page.getByTestId("step-2")).toBeVisible();
    await page.getByRole("button", { name: "التالي" }).click();
    await page.getByRole("button", { name: "إنشاء الحجز" }).click();
    await page.waitForURL(/#\/staff\/reservations\/[0-9a-f-]+/, { timeout: 15_000 });
  });
});
