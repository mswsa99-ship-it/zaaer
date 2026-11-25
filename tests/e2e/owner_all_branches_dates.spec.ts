/** Owner «جميع الفروع», day/period picker, nights stepper, time wheels and the field-level «التالي» message (invented demo data only). */
import { test, expect } from "./fixtures";

test.describe("owner all branches, dates, nights, time wheels", () => {
  test("the owner gets «جميع الفروع» on the dashboard; the choice is a third option", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/admin/dashboard", { waitUntil: "networkidle" });
    const sel = page.locator('select[aria-label="الفرع النشط"]').first();
    await expect(sel).toBeVisible();
    await expect(sel.locator("option").last()).toHaveText("جميع الفروع");   // «جميع الفروع» appears once the owner role has loaded
    await sel.selectOption({ label: "جميع الفروع" });
    await expect(page.getByText("مؤشرات جميع الفروع")).toBeVisible();
    await page.screenshot({ path: "/tmp/proof/dashboard-all.png", fullPage: false });
  });

  test("booking wizard: nights stepper, date picker, time wheels, field-level error", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/reservations/new", { waitUntil: "networkidle" });
    const nights = page.getByTestId("nights-value");
    await expect(nights).toHaveText("1");
    await expect(page.getByRole("button", { name: "ليلة أقل" })).toBeDisabled();
    await page.getByRole("button", { name: "ليلة أكثر" }).click();
    await page.getByRole("button", { name: "ليلة أكثر" }).click();
    await expect(nights).toHaveText("3");
    // the stepper: minus is on the right, plus on the left in the RTL page
    const minus = await page.getByRole("button", { name: "ليلة أقل" }).boundingBox();
    const plus = await page.getByRole("button", { name: "ليلة أكثر" }).boundingBox();
    expect(minus!.x).toBeGreaterThan(plus!.x);
    for (let i = 0; i < 40; i++) { const b = page.getByRole("button", { name: "ليلة أكثر" }); if (await b.isDisabled()) break; await b.click(); }
    await expect(nights).toHaveText("30");
    await expect(page.getByRole("button", { name: "ليلة أكثر" })).toBeDisabled();
    await page.getByRole("button", { name: "ليلة أقل" }).click();
    await expect(nights).toHaveText("29");
    await page.screenshot({ path: "/tmp/proof/booking-step1.png" });
    // the date picker: one day = that day, then the display is plain ISO digits in LTR
    await page.getByRole("button", { name: "الوصول", exact: true }).click();
    const days = page.locator("[data-day]:not([disabled])");
    await days.nth(2).click();
    await page.screenshot({ path: "/tmp/proof/date-picker.png" });
    await page.getByRole("button", { name: "موافق" }).click();
    // moving the arrival never leaves more than 30 nights: the departure follows
    expect(Number(await nights.innerText())).toBeLessThanOrEqual(30);
    expect(Number(await nights.innerText())).toBeGreaterThanOrEqual(1);
    await expect(page.getByTestId("date-range-value").first()).toHaveText(/^\d{4}-\d{2}-\d{2}$/);
    // time wheels
    await page.getByRole("button", { name: "وقت الوصول المتوقع" }).click();
    await page.screenshot({ path: "/tmp/proof/time-wheels.png" });
    const hours = page.getByRole("listbox", { name: /الساعة/ });
    await hours.evaluate((el) => { el.scrollTop = 44 * 15; });
    await expect(page.getByRole("dialog").getByText("3:00 مساءً").or(page.getByRole("dialog").getByText(/3:\d\d مساءً/))).toBeVisible();
    await page.getByRole("button", { name: "موافق" }).click();
    await expect(page.getByTestId("time-value").first()).toContainText("مساءً");
    // step 2: التالي with nothing typed says where
    await page.getByRole("button", { name: "التالي" }).click();
    await page.getByRole("button", { name: "التالي" }).click();
    await expect(page.getByText("اكتب اسم النزيل.").first()).toBeVisible();
    await expect(page.locator('[aria-invalid="true"]').first()).toBeFocused();
    await page.screenshot({ path: "/tmp/proof/step2-error.png" });
    // adults and companions are bounded drop-downs
    const adults = page.getByLabel("بالغون");
    const n = await adults.locator("option").count();
    expect(n).toBeGreaterThan(0); expect(n).toBeLessThan(20);
  });

  test("day closing: the owner's «جميع الفروع» is a read-only line per branch", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/staff/day-close", { waitUntil: "networkidle" });
    await page.locator('select[aria-label="الفرع النشط"]').first().selectOption({ label: "جميع الفروع" });
    await expect(page.getByTestId("closing-all")).toBeVisible();
    expect(await page.getByTestId("closing-all-row").count()).toBeGreaterThan(1);
    await expect(page.getByRole("button", { name: "إرسال الإقفال" })).toHaveCount(0);
  });

  test("reports: in «جميع الفروع» the discounts, late entries and identities reports show merged figures", async ({ page, loginAs }) => {
    await loginAs("owner");
    await page.goto("/#/admin/reports", { waitUntil: "networkidle" });
    await page.locator('select[aria-label="الفرع النشط"]').first().selectOption({ label: "جميع الفروع" });
    for (const id of ["discounts-report", "late-entries-report", "identities-report"]) await expect(page.getByTestId(id)).toBeVisible();
    await expect(page.getByTestId("reports-all-note")).toHaveCount(0);
  });

  test("exports stay available in «جميع الفروع» (reservations, vouchers, reports)", async ({ page, loginAs }) => {
    await loginAs("owner");
    for (const path of ["/#/staff/reservations", "/#/admin/finance", "/#/admin/reports"]) {
      await page.goto(path, { waitUntil: "networkidle" });
      await page.locator('select[aria-label="الفرع النشط"]').first().selectOption({ label: "جميع الفروع" });
      await page.waitForTimeout(600);
      await expect(page.getByTestId("export-trigger").first()).toBeEnabled();
    }
  });
});
