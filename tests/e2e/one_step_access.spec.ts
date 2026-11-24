/**
 * Plan 6.3 (U12) — the arrival and the key-box code in one click when the stay has no financial shortfall, and the plan 4.1
 * controls unchanged when it has one. Test ids SU08–SU12. The server rules are the ones in tests/sql (stay cycle SC,
 * phase4_voucher_closing); this file proves the screen does not route around them.
 */
import { test, expect } from "./fixtures";
import type { Page } from "@playwright/test";

async function openByRoom(page: Page, go: (p: string) => Promise<void>, room: string, status: string) {
  await go("/staff/reservations");
  await page.locator("select").filter({ has: page.locator(`option[value="${status}"]`) }).selectOption(status);
  const row = page.locator("table tbody tr").filter({ has: page.locator("td:nth-child(3)", { hasText: room }) }).first();
  await expect(row).toBeVisible();
  await row.getByRole("link", { name: "فتح" }).click();
  await page.waitForURL(/#\/staff\/reservations\/[0-9a-f-]+/);
  await expect(page.getByTestId("stay-cycle")).toBeVisible();
}

/** the branch's deposit received on its own voucher, so the stay has no financial shortfall */
async function payDeposit(page: Page) {
  await page.getByRole("button", { name: "قبض تأمين" }).click();
  const dlg = page.getByRole("dialog");
  await dlg.locator("input[data-money]").first().fill("50");
  const sure = dlg.getByLabel(/استلمت/);
  if (await sure.count()) await sure.first().check();
  await dlg.getByRole("button", { name: "حفظ السند" }).click();
  await expect(dlg).toBeHidden();
  await expect(page.getByTestId("one-step")).toBeVisible();
}

/** how many times the demo backend wrote this audit action (the store is the browser's own) */
async function auditCount(page: Page, action: string): Promise<number> {
  await page.waitForTimeout(500);   // the demo store saves to localStorage 150 ms after a change
  return page.evaluate((a) => {
    for (const k of Object.keys(localStorage)) {
      const raw = localStorage.getItem(k) ?? "";
      if (!raw.includes('"audit_events"')) continue;
      try { return (JSON.parse(raw).audit_events as Array<{ action: string }>).filter((e) => e.action === a).length; } catch { /* next */ }
    }
    return -1;
  }, action);
}
async function countClicks(page: Page) {
  await page.evaluate(() => { (window as unknown as { __clicks: number }).__clicks = 0; document.addEventListener("click", () => { (window as unknown as { __clicks: number }).__clicks++; }, true); });
}
const clicks = (page: Page) => page.evaluate(() => (window as unknown as { __clicks: number }).__clicks);

test.describe("one-step access (plan 6.3)", () => {
  test("SU08 paid stay: one click records the arrival and delivers the code; the click count is 1", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await openByRoom(page, go, "203", "confirmed");
    await payDeposit(page);
    const arrival = page.getByTestId("arrival");
    await expect(arrival.locator("fieldset")).toHaveCount(0);      // nothing to type: no shortfall, no voucher form
    await arrival.screenshot({ path: "test-results/su08-desktop-arrival.png" });
    await countClicks(page);
    await arrival.getByTestId("arrive-and-deliver").click();       // the channel is «صفحة النزيل» by default
    await expect(page.getByTestId("stay-notice")).toContainText("سُجِّل الوصول وسُلِّم رمز الصندوق");
    await expect(page.getByTestId("in-house")).toContainText("سُلِّم رمز الصندوق لهذا النزيل");
    expect(await clicks(page)).toBe(1);
    expect(await auditCount(page, "reservation.checked_in")).toBeGreaterThanOrEqual(1);
  });

  test("SU09 supervisor channel: the code is revealed once, in the same click", async ({ page, loginAs, go }) => {
    await loginAs("manager");
    await openByRoom(page, go, "203", "confirmed");
    await payDeposit(page);
    await page.getByTestId("one-step").getByRole("radio", { name: "شفهيًا عبر المشرف" }).click();
    await page.getByTestId("arrive-and-deliver").click();
    await expect(page.getByTestId("revealed-code")).toHaveText(/^\d{4,8}$/);
  });

  test("SU10 shortfall: no one-step; 4.1 holds — no «استلمت», no arrival; with it the arrival is recorded and the code is still its own step", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await openByRoom(page, go, "203", "confirmed");
    const arrival = page.getByTestId("arrival");
    await expect(page.getByTestId("one-step")).toHaveCount(0);
    const deposit = arrival.locator("fieldset").filter({ hasText: "سند قبض التأمين" });
    await expect(deposit).toBeVisible();
    // an amount typed without the explicit «استلمت»: refused, nothing recorded
    await deposit.locator("input[data-money]").fill("50");
    await arrival.getByRole("button", { name: "تسجيل الوصول", exact: true }).click();
    await expect(page.getByText(/استلمت|تأكيد/).first()).toBeVisible();
    await expect(arrival).toBeVisible();
    await expect(page.getByTestId("in-house")).toHaveCount(0);
    // no amount, no reason: refused by the server's deposit rule
    await deposit.locator("input[data-money]").fill("0");
    await arrival.getByRole("button", { name: "تسجيل الوصول", exact: true }).click();
    await expect(page.getByTestId("reasons").first()).toContainText("التأمين لم يُستلم كاملًا");
    await expect(page.getByTestId("in-house")).toHaveCount(0);
    // the valid path: the amount, the confirmation
    await deposit.locator("input[data-money]").fill("50");
    await deposit.getByLabel(/استلمت المبلغ/).check();
    await arrival.getByRole("button", { name: "تسجيل الوصول", exact: true }).click();
    await expect(page.getByTestId("stay-notice")).toContainText("سُجِّل الوصول");
    await expect(page.getByTestId("in-house")).not.toContainText("سُلِّم رمز الصندوق لهذا النزيل");
    await expect(page.getByTestId("in-house").getByRole("button", { name: "تسليم رمز الصندوق" })).toBeVisible();
  });

  for (const role of ["housekeeping", "finance"] as const) {
    test(`SU11 ${role}: no arrival, so no one-step button`, async ({ page, loginAs, go }) => {
      await loginAs(role);
      await go("/staff/reservations");
      await expect(page.getByTestId("arrive-and-deliver")).toHaveCount(0);
      const link = page.locator("table tbody tr").getByRole("link", { name: "فتح" }).first();
      if (await link.count()) { await link.click(); await page.waitForTimeout(1000); await expect(page.getByTestId("arrive-and-deliver")).toHaveCount(0); }
    });
  }

  test("SU12 a double click is one arrival and one delivery", async ({ page, loginAs, go }) => {
    await loginAs("supervisor");
    await openByRoom(page, go, "203", "confirmed");
    await payDeposit(page);
    const before = [await auditCount(page, "reservation.checked_in"), await auditCount(page, "deliver_access_code")];
    await page.getByTestId("arrive-and-deliver").dblclick();
    await expect(page.getByTestId("in-house")).toContainText("سُلِّم رمز الصندوق لهذا النزيل");
    await expect(page.getByTestId("reasons")).toHaveCount(0);
    expect(await auditCount(page, "reservation.checked_in")).toBe(before[0] + 1);
    expect(await auditCount(page, "deliver_access_code")).toBe(before[1] + 1);
  });

  test.describe("phone width", () => {
    test.use({ viewport: { width: 412, height: 915 }, hasTouch: true, isMobile: true });
    test("SU13 the one-step card fits a phone: nothing clipped, the button inside the screen, one tap works", async ({ page, loginAs, go }) => {
      await loginAs("supervisor");
      await openByRoom(page, go, "203", "confirmed");
      await payDeposit(page);
      const btn = page.getByTestId("arrive-and-deliver");
      await btn.scrollIntoViewIfNeeded();
      const box = (await btn.boundingBox())!;
      expect(box.x).toBeGreaterThanOrEqual(0);
      expect(box.x + box.width).toBeLessThanOrEqual(412);
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(412);
      await page.getByTestId("arrival").screenshot({ path: "test-results/su13-mobile-arrival.png" });
      await btn.tap();
      await expect(page.getByTestId("in-house")).toContainText("سُلِّم رمز الصندوق لهذا النزيل");
    });
  });
});
