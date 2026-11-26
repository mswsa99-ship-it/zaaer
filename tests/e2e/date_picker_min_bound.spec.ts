/** Date picker with a min and max (new-reservation check-out): arrows never focus a day before min or after max. Demo build only. */
import { test, expect } from "./fixtures";
test("DKM1 arrows stop at min and max", async ({ page, loginAs, go }) => {
  await loginAs("owner");
  await go("/staff/reservations/new");
  const opener = page.getByRole("button", { name: "المغادرة" }).first();
  await opener.focus(); await page.keyboard.press("Enter");
  const dlg = page.getByRole("dialog"); await expect(dlg).toBeVisible();
  const cur = () => page.evaluate(() => document.activeElement?.getAttribute("data-day") ?? "");
  const days = await dlg.locator("[data-day]:not([disabled])").evaluateAll((els) => els.map((e) => e.getAttribute("data-day")!));
  const lo = days[0];
  const start = await cur(); expect(start).toMatch(/^\d{4}-\d\d-\d\d$/);
  for (let i = 0; i < 40; i++) await page.keyboard.press("ArrowRight");   // RTL: previous day
  expect(await cur() >= lo).toBe(true);
  const stuckLow = await cur();
  await page.keyboard.press("ArrowRight"); expect(await cur()).toBe(stuckLow);
  await page.keyboard.press("ArrowUp"); expect(await cur()).toBe(stuckLow);
  for (let i = 0; i < 120; i++) await page.keyboard.press("ArrowLeft");
  const hi = await cur(); await page.keyboard.press("ArrowLeft"); expect(await cur()).toBe(hi);
  expect(await dlg.evaluate((el) => el.contains(document.activeElement))).toBe(true);
});
