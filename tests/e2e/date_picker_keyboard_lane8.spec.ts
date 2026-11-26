/** The period picker by keyboard only: arrow keys move between days (RTL: Left = next day), Tab stays inside the open dialog, a range is picked and applied. Invented demo data only. */
import { test, expect, type Page } from "@playwright/test";
import { ROLE_BUTTON } from "./fixtures";

const active = (page: Page) => page.evaluate(() => (document.activeElement as HTMLElement | null)?.getAttribute("data-day") ?? (document.activeElement as HTMLElement | null)?.textContent?.trim() ?? "");

for (const width of [390, 1280]) {
  test(`DPK1 ${width}: arrows move by day and week, cross months, Tab stays in the dialog, range applies`, async ({ page }) => {
    await page.setViewportSize({ width, height: 800 });
    await page.goto("/#/staff/login", { waitUntil: "networkidle" });
    await page.getByRole("button", { name: ROLE_BUTTON.owner }).click();
    await page.waitForURL(/#\/(staff|admin)\//);
    await page.goto("/#/staff/day-summary", { waitUntil: "networkidle" });
    const trigger = page.getByRole("button", { name: /اليوم أو الفترة/ }).first();
    await trigger.focus(); await page.keyboard.press("Enter");
    const dialog = page.getByRole("dialog").first(); await expect(dialog).toBeVisible();
    const start = await active(page);
    expect(start).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    await page.keyboard.press("ArrowRight");   // previous day (right-to-left grid)
    const prev = await active(page);
    expect(new Date(start + "T00:00:00Z").getTime() - new Date(prev + "T00:00:00Z").getTime()).toBe(86400000);
    await page.keyboard.press("ArrowUp");      // one week back
    const wk = await active(page);
    expect(new Date(prev + "T00:00:00Z").getTime() - new Date(wk + "T00:00:00Z").getTime()).toBe(7 * 86400000);
    await page.keyboard.press("ArrowLeft");    // next day
    expect(new Date((await active(page)) + "T00:00:00Z").getTime() - new Date(wk + "T00:00:00Z").getTime()).toBe(86400000);
    // cross into the previous month by arrows alone
    const month = (d: string) => d.slice(0, 7);
    const m0 = month(await active(page));
    for (let i = 0; i < 6 && month(await active(page)) === m0; i++) await page.keyboard.press("ArrowUp");
    const crossed = await active(page);
    expect(month(crossed)).not.toBe(m0);
    await expect(page.locator(`[data-day="${crossed}"]`)).toBeFocused();
    // pick a range with Enter, then Space
    await page.keyboard.press("Enter"); await page.keyboard.press("ArrowLeft"); await page.keyboard.press("ArrowLeft"); await page.keyboard.press("Space");
    // focus never leaves the dialog while tabbing past both ends
    for (let i = 0; i < 80; i++) { await page.keyboard.press("Tab"); expect(await dialog.evaluate((d) => d.contains(document.activeElement))).toBe(true); }
    for (let i = 0; i < 80; i++) { await page.keyboard.press("Shift+Tab"); expect(await dialog.evaluate((d) => d.contains(document.activeElement))).toBe(true); }
    await page.getByRole("button", { name: "موافق" }).focus(); await page.keyboard.press("Enter");
    await expect(dialog).toHaveCount(0); await expect(trigger).toBeFocused();
    expect(await page.getByTestId("date-range-value").first().innerText()).toContain(crossed);
    await page.screenshot({ path: `/tmp/proof/dpk1-${width}.png` });
  });
}
