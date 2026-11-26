/**
 * Keyboard use of the shared date picker (routine batch): arrows move the focused day (RTL aware), a month edge
 * redraws the next month and keeps focus on the day, days outside min/max are not entered, Tab stays inside the
 * dialog, Escape returns focus to the opener. Demo build; not a live-site or screen-reader proof.
 */
import { test, expect } from "./fixtures";

test.describe("date picker keyboard", () => {
  test.use({ viewport: { width: 390, height: 844 } });
  test("DK1 arrows, month crossing, Tab containment, Escape", async ({ page, loginAs, go }) => {
    await loginAs("owner");
    await go("/staff/day-summary");
    const opener = page.getByTestId("date-range-picker").first().getByRole("button").first();
    await opener.focus(); await page.keyboard.press("Enter");
    const dlg = page.getByRole("dialog");
    await expect(dlg).toBeVisible();
    await expect(dlg).toHaveAttribute("aria-modal", "true");
    const cur = () => page.evaluate(() => document.activeElement?.getAttribute("data-day") ?? "");
    const start = await cur(); expect(start).toMatch(/^\d{4}-\d\d-\d\d$/);
    const add = (d: string, n: number) => { const t = new Date(d + "T00:00:00Z"); t.setUTCDate(t.getUTCDate() + n); return t.toISOString().slice(0, 10); };
    // this screen allows no day after today (max), so the start day is the last enterable one
    await page.keyboard.press("ArrowDown"); expect(await cur()).toBe(start);          // +7 is past max: stays
    await page.keyboard.press("ArrowLeft"); expect(await cur()).toBe(start);          // RTL: left is the next day, past max: stays
    await page.keyboard.press("ArrowUp"); expect(await cur()).toBe(add(start, -7));
    await page.keyboard.press("ArrowDown"); expect(await cur()).toBe(start);
    await page.keyboard.press("ArrowRight"); expect(await cur()).toBe(add(start, -1)); // RTL: right is the previous day
    await page.keyboard.press("ArrowLeft"); expect(await cur()).toBe(start);
    for (let i = 0; i < 6; i++) await page.keyboard.press("ArrowUp");                  // crosses into the previous month
    expect(await cur()).toBe(add(start, -42));
    const m = await dlg.evaluate((el) => el.contains(document.activeElement)); expect(m).toBe(true);
    // Tab never leaves the dialog
    for (let i = 0; i < 60; i++) await page.keyboard.press("Tab");
    expect(await dlg.evaluate((el) => el.contains(document.activeElement))).toBe(true);
    for (let i = 0; i < 60; i++) await page.keyboard.press("Shift+Tab");
    expect(await dlg.evaluate((el) => el.contains(document.activeElement))).toBe(true);
    await page.screenshot({ path: "/tmp/dk1-390.png" });
    await page.keyboard.press("Escape");
    await expect(dlg).toBeHidden();
    await expect(opener).toBeFocused();
  });
});
