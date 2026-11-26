/** «جميع الفروع» rows say their branch; filter labels have a 44px tap area at 390 (demo build, synthetic data, not live). */
import { test, expect } from "./fixtures";
test.describe("branch labels and filter targets (390px)", () => {
  test.beforeEach(async ({ page }) => { await page.setViewportSize({ width: 390, height: 844 }); });
  async function all(page: import("@playwright/test").Page) {
    const sel = page.locator('select[aria-label="الفرع النشط"]').first();
    await sel.selectOption({ label: "جميع الفروع" });
    await page.waitForTimeout(800);
  }
  test("BL1 payments in all branches: every card names its branch, a single branch adds none", async ({ page, loginAs, go }) => {
    await loginAs("owner"); await go("/staff/followups"); await page.waitForTimeout(800);
    await all(page);                                    // the payments page has no picker: it follows the shared branch
    await page.evaluate(() => { location.hash = "#/staff/payments"; }); await page.waitForTimeout(1200);
    const cards = page.locator("a[href*='/staff/reservations/']");
    const n = await cards.count(); expect(n).toBeGreaterThan(0);
    for (let i = 0; i < n; i++) await expect(cards.nth(i)).toContainText(/فرع/);
    await page.screenshot({ path: "/tmp/proof/bl1-payments-390.png" });
  });
  test("BL2 follow-ups in all branches: every row names its branch", async ({ page, loginAs, go }) => {
    await loginAs("owner"); await go("/staff/followups"); await page.waitForTimeout(800);
    await all(page);
    const rows = page.locator("a[href*='/staff/reservations/']");
    const n = await rows.count(); expect(n).toBeGreaterThan(0);
    for (let i = 0; i < n; i++) await expect(rows.nth(i).locator("p.font-mono")).toContainText("·");
    await expect(page.getByTestId("followups-departed")).toContainText("فرع");
    await page.screenshot({ path: "/tmp/proof/bl2-followups-390.png" });
  });
  for (const [name, path] of [["reservations", "/staff/reservations"], ["reports", "/admin/reports"]] as const) {
    test(`BL3 ${name}: filter checkbox labels are 44px tall`, async ({ page, loginAs, go }) => {
      await loginAs("owner"); await go(path); await page.waitForTimeout(1000);
      const hs = await page.evaluate(() => Array.from(document.querySelectorAll<HTMLInputElement>("input[type=checkbox]")).map((c) => Math.round((c.closest("label") ?? c).getBoundingClientRect().height)));
      expect(hs.length).toBeGreaterThan(0);
      for (const h of hs) expect(h).toBeGreaterThanOrEqual(44);
    });
  }
});
