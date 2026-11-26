/** Keyboard and screen-reader fixes on the tickets page (demo build, synthetic data, not live). */
import { test, expect } from "./fixtures";
test.describe("tickets keyboard (390px)", () => {
  test.beforeEach(async ({ page }) => { await page.setViewportSize({ width: 390, height: 844 }); });
  test("TK1 the second jump chip moves focus into its section and the next Tab stays inside it", async ({ page, loginAs, go }) => {
    await loginAs("owner"); await go("/staff/tickets"); await page.waitForTimeout(800);
    const chip = page.getByTestId("tickets-jump").getByRole("button").nth(1);
    await chip.focus(); await page.keyboard.press("Enter");
    expect(await page.evaluate(() => document.activeElement?.id)).toBe("tickets-maintenance");
    await page.keyboard.press("Tab");
    expect(await page.evaluate(() => !!document.activeElement?.closest("#tickets-maintenance"))).toBe(true);
    await page.screenshot({ path: "/tmp/proof/tk1-chip2-390.png" });
  });
  test("TK2 the new-report toggle says expanded and the form opens with focus on its first control", async ({ page, loginAs, go }) => {
    await loginAs("owner"); await go("/staff/tickets"); await page.waitForTimeout(800);
    const t = page.getByTestId("ticket-new");
    await expect(t).toHaveAttribute("aria-expanded", "false");
    await t.click(); await expect(t).toHaveAttribute("aria-expanded", "true");
    await expect.poll(() => page.evaluate(() => document.activeElement?.tagName)).toBe("SELECT");
    await page.screenshot({ path: "/tmp/proof/tk2-form-390.png" });
  });
  test("TK3 an empty submit ties each error to its field with aria-describedby (no ticket is created)", async ({ page, loginAs, go }) => {
    await loginAs("owner"); await go("/staff/tickets"); await page.waitForTimeout(800);
    await page.getByTestId("ticket-new").click();
    await page.getByRole("button", { name: "إنشاء البلاغ" }).click();
    const r = await page.evaluate(() => Array.from(document.querySelectorAll<HTMLElement>("[data-ticket-form] [aria-invalid=true]")).map((e) => { const d = e.getAttribute("aria-describedby"); return { d, text: d ? document.getElementById(d.split(" ").pop()!)?.textContent : null }; }));
    expect(r.length).toBe(2);
    expect(r[0].text).toBe("اختر الوحدة."); expect(r[1].text).toBe("اكتب عنوان البلاغ.");
    await page.screenshot({ path: "/tmp/proof/tk3-errors-390.png" });
  });
});
