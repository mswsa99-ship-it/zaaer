/** Decisive pixels for the X delta on guest terms and the platform operator page (demo build only). */
import { test, expect } from "./fixtures";
test("XP1 terms at 390 and platform hotels at 390: no overflow, readable", async ({ page, go }) => {
  await page.setViewportSize({ width: 390, height: 800 });
  await go("/terms");
  await expect(page.getByRole("heading", { level: 1 }).first()).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.screenshot({ path: "/tmp/proof/xp-terms-390.png" });
  await go("/platform/login");
  await page.getByRole("button", { name: "مشغّل المنصة (عرض تجريبي)" }).click();
  await expect(page).toHaveURL(/#\/platform/);
  await expect(page.getByRole("heading", { name: "مشغّل منصة RoomAI" })).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.screenshot({ path: "/tmp/proof/xp-platform-390.png" });
});
