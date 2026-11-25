/** LOCAL harness proof (UI affordance only; enforcement is SQL 0136): the way-in photo archive control on «رحلة الضيف» follows Edit on /admin/journey for individual accounts. The photo is a synthetic 8x8 PNG added through the real upload control. */
import { test, expect } from "@playwright/test";
import path from "node:path";
const SHOTS = process.env.SHOTS_DIR ?? "/downloads/lane1/shots";
const cases = [
  { n: "view-only", g: { view: true }, archive: false },
  { n: "view-add", g: { view: true, add: true }, archive: false },
  { n: "view-edit", g: { view: true, edit: true }, archive: true },
];
for (const c of cases) {
  test(`individual journey photo archive ${c.n}`, async ({ page }) => {
    const errs: string[] = []; page.on("pageerror", (e) => errs.push(e.message));
    await page.addInitScript((v) => localStorage.setItem("__harness_page_access", v), JSON.stringify({ mode: "individual", revision: 1, sensitive: [], home_page: null, pages: { "/admin/journey": c.g } }));
    await page.goto("/#/staff/login", { waitUntil: "networkidle" });
    await page.getByRole("button", { name: "مدير الفرع" }).click();
    await page.waitForURL(/#\/(staff|admin)\//, { timeout: 15_000 });
    await page.goto("/#/admin/journey", { waitUntil: "networkidle" }); await page.waitForTimeout(600);
    await page.getByRole("button", { name: /^صور الوحدة/ }).first().click();
    const panel = page.getByTestId("unit-guide-checkin");
    await expect(panel).toBeVisible();
    await panel.locator('input[type="file"]').setInputFiles(path.resolve("tests/harness/fixture-8x8.png"));
    await expect(panel.getByRole("textbox").first()).toBeVisible({ timeout: 10_000 }); // the step row exists
    await expect(panel.getByRole("button", { name: "أرشفة الصورة" })).toHaveCount(c.archive ? 1 : 0);
    await page.screenshot({ path: `${SHOTS}/journey-photo-${c.n}.png` });
    expect(errs).toEqual([]);
  });
}
