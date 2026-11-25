/**
 * LOCAL harness proof (UI affordances only, no server enforcement): the REAL «الوحدات» page, demo build with injected page_access,
 * for individual-mode non-owner accounts. Enforcement is proven by SQL/HTTP tests (unit_license_tests, 0133-0135).
 */
import { test, expect } from "@playwright/test";
const SHOTS = process.env.SHOTS_DIR ?? "/downloads/lane1/shots";
const g = (o: Record<string, boolean>) => ({ mode: "individual", revision: 1, sensitive: [], home_page: null, pages: { "/admin/rooms": o } });
const cases = [
  { name: "view-only", grants: { view: true }, add: false, edit: false },
  { name: "view-add", grants: { view: true, add: true }, add: true, edit: false },
  { name: "view-edit", grants: { view: true, edit: true }, add: false, edit: true },
  { name: "view-add-edit", grants: { view: true, add: true, edit: true }, add: true, edit: true },
];
for (const c of cases) {
  test(`individual rooms ${c.name}`, async ({ page }) => {
    const errs: string[] = []; page.on("pageerror", (e) => errs.push(e.message));
    await page.addInitScript((v) => localStorage.setItem("__harness_page_access", v), JSON.stringify(g(c.grants)));
    await page.goto("/#/staff/login", { waitUntil: "networkidle" });
    await page.getByRole("button", { name: "مدير الفرع" }).click();
    await page.waitForURL(/#\/(staff|admin)\//, { timeout: 15_000 });
    await page.goto("/#/admin/rooms", { waitUntil: "networkidle" }); await page.waitForTimeout(600);
    const add = page.getByRole("button", { name: "وحدة جديدة" });
    const pencil = page.getByRole("button", { name: /^تعديل الوحدة/ });
    await expect(page.getByTestId("admin-unit-card").first()).toBeVisible();
    await expect(add).toHaveCount(c.add ? 1 : 0);
    if (c.edit) await expect(pencil.first()).toBeVisible(); else await expect(pencil).toHaveCount(0);
    if (c.add) {
      await add.click();
      await expect(page.getByTestId("unit-license-input")).toBeVisible(); // Add may enter the licence at creation
      await page.screenshot({ path: `${SHOTS}/rooms-${c.name}-create.png` });
      await page.keyboard.press("Escape");
    } else await page.screenshot({ path: `${SHOTS}/rooms-${c.name}.png` });
    expect(errs).toEqual([]);
  });
}
