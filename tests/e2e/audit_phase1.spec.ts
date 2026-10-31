/**
 * The review of 31 October, Phase 1 as the owner decided it: the screens of the front desk and the money rules
 * (0053–0054). The server rules themselves are in tests/sql/audit_phase1_tests.sql (QF*, QM*).
 */
import { test, expect } from "./fixtures";

test("QF09 a cancelled booking's guest page says so plainly — no steps, no amounts, no registration", async ({ page, go }) => {
  await page.evaluate(() => { try { sessionStorage.removeItem("guest_phone_session"); } catch { /* storage blocked */ } }).catch(() => undefined);
  await go("/booking/lookup");
  await page.getByPlaceholder("05xxxxxxxx").fill("0501110016");
  await page.getByRole("button", { name: "متابعة" }).click();
  await page.getByPlaceholder("رقم الحجز").fill("R-26A0016");
  await page.getByRole("button", { name: "عرض حجوزاتي" }).click();
  await expect(page).toHaveURL(/\/booking\/status\//);
  const ended = page.getByTestId("booking-ended");
  await expect(ended).toBeVisible();
  await expect(ended.getByRole("heading")).toHaveText("هذا الحجز ملغى");
  await expect(page.getByRole("list", { name: "خطوات الإقامة" })).toHaveCount(0);
  await expect(page.getByText("استكمال البيانات")).toHaveCount(0);
  await expect(page.getByText("المتبقي على الإقامة")).toHaveCount(0);
});

test("QF10 «تسجيل المغادرة» asks first, and cancelling leaves the guest in house", async ({ page, loginAs, go }) => {
  await loginAs("supervisor");
  await go("/staff/reservations");
  await page.locator("select").filter({ has: page.locator('option[value="checked_in"]') }).selectOption("checked_in");
  await page.locator("table tbody tr").first().getByRole("link", { name: "فتح" }).click();
  await page.waitForURL(/#\/staff\/reservations\/[0-9a-f-]+/);
  const inHouse = page.getByTestId("in-house");
  await inHouse.getByRole("button", { name: "تسجيل المغادرة" }).click();
  const dlg = page.getByRole("dialog");
  await expect(dlg.getByTestId("checkout-confirm")).toBeVisible();
  await dlg.getByRole("button", { name: "إلغاء" }).click();
  await expect(dlg).toBeHidden();
  await expect(inHouse).toBeVisible();
});

test("QM09 a refund starts from the payment it returns: its method by default, the amount typed, another method asks why", async ({ page, loginAs, go }) => {
  await loginAs("owner");
  await go("/staff/reservations");
  await page.locator("select").filter({ has: page.locator('option[value="checked_in"]') }).selectOption("checked_in");
  const rows = page.locator("table tbody tr");
  await expect(rows.first()).toBeVisible();
  const n = await rows.count();
  let found = false;
  for (let i = 0; i < n && !found; i++) {
    await rows.nth(i).getByRole("link", { name: "فتح" }).click();
    await page.waitForURL(/#\/staff\/reservations\/[0-9a-f-]+/);
    const btn = page.getByRole("button", { name: "استرداد إقامة" });
    if (await btn.count()) {
      found = true;
      await btn.click();
      const dlg = page.getByRole("dialog");
      await expect(dlg.getByTestId("refund-original")).toBeVisible();
      await expect(dlg.getByLabel("السبب (إلزامي)")).toBeVisible();
      // choosing a method other than the payment's asks for the reason of the difference
      const methods = dlg.locator("button.rounded-xl");
      const picked = await methods.evaluateAll((els) => els.findIndex((e) => !e.className.includes("border-brand-500")));
      if (picked >= 0) {
        await methods.nth(picked).click();
        await expect(dlg.getByText("سبب الرد بطريقة غير طريقة الدفع (إلزامي)")).toBeVisible();
      }
      await dlg.getByRole("button", { name: "إلغاء" }).click();
    } else {
      await go("/staff/reservations");
      await page.locator("select").filter({ has: page.locator('option[value="checked_in"]') }).selectOption("checked_in");
    }
  }
  expect(found, "a stay in house with a payment to refund").toBe(true);
});
