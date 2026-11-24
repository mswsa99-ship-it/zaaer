/** Plan 6.6 (U3): one state per list: loading, empty, error or data, never two; the error card goes away after a success. */
import { test, expect } from "./fixtures";

const PAGES: [string, string][] = [
  ["/staff/expenses", "المصروفات"], ["/staff/ledger", "دفتر"], ["/staff/arrivals", "وصول"], ["/staff/reservations", "الحجوزات"],
  ["/staff/payments", "المدفوعات"], ["/staff/tickets", ""], ["/staff/housekeeping", ""], ["/staff/codes", ""], ["/staff/followups", ""],
  ["/staff/orders", ""], ["/staff/bank", ""], ["/staff/platforms", ""], ["/staff/identity-verification", ""],
];

for (const [path] of PAGES) {
  test(`list state is single and recovers: ${path}`, async ({ page, loginAs, go, errors }) => {
    await loginAs("owner");
    await go("/staff/dashboard");
    await page.evaluate(() => { (window as unknown as { __demoFail: unknown }).__demoFail = () => "network down"; });
    await page.evaluate((p) => { window.location.hash = p; }, path);
    await page.waitForTimeout(1200);
    const main = page.locator("main");
    const failed = await main.locator("[role=alert]").count();
    const empty = await main.locator("text=/^لا (توجد|يوجد|مصروفات|حجوزات|سندات|وحدات|طلبات)/").count() + await main.getByText(/لا حجوزات (مطابقة|من المنصات)/).count();
    const spinning = await main.locator(".animate-spin").count();
    const states = [failed > 0, empty > 0, spinning > 0].filter(Boolean).length;
    expect(states, `${path}: error=${failed} empty=${empty} loading=${spinning} must be a single state`).toBeLessThanOrEqual(1);
    // the connection returns: a retry or a reload shows data and no error
    await page.evaluate(() => { (window as unknown as { __demoFail: unknown }).__demoFail = undefined; });
    const retry = main.getByRole("button", { name: "إعادة المحاولة" }).first();
    if (await retry.count()) await retry.click(); else await page.evaluate((p) => { window.location.hash = "/staff/dashboard"; setTimeout(() => { window.location.hash = p; }, 50); }, path);
    await page.waitForTimeout(1200);
    await expect(main.locator("[role=alert]")).toHaveCount(0);
    await expect(main.locator(".animate-spin")).toHaveCount(0);
    errors.length = 0;   // the failed reads are logged by design in this test
  });
}
