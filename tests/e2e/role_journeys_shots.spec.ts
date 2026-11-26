import { test, expect, type DemoRole } from "./fixtures";
import fs from "node:fs";
const OUT = process.env.SHOT_DIR ?? "/tmp/shots";
for (const role of ["housekeeping", "finance"] as DemoRole[]) for (const w of [360, 390]) {
  test(`phone bar and menu for ${role} at ${w}`, async ({ page, loginAs }) => {
    fs.mkdirSync(OUT, { recursive: true });
    await page.setViewportSize({ width: w, height: 780 });
    await loginAs(role);
    await page.waitForTimeout(400);
    const bar = page.getByTestId("bottom-tabs");
    await expect(bar).toBeVisible();
    const first = await bar.locator("a").first().getAttribute("href");
    if (role === "housekeeping") expect(first).toContain("/staff/housekeeping");
    if (role === "finance") expect(first).toContain("/staff/payments");
    await page.screenshot({ path: `${OUT}/${role}-${w}-bar.png` });
    await page.getByTestId("bottom-tabs-more").click();
    await page.waitForTimeout(300);
    await page.screenshot({ path: `${OUT}/${role}-${w}-menu.png` });
  });
}
