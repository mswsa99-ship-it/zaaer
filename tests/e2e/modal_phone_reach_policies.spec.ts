/**
 * Phone reachability of the existing policy forms (the branch form), on the real page in the demo build. The hotel-level
 * form is NOT covered here: with the demo lacking the hotel-level RPCs the page shows a retry state and no hotel-level button. Layout, scroll, focus and Escape only. Viewport emulation, no real keyboard.
 */
import { test, expect, type Locator } from "./fixtures";
for (const [w, h] of [[360, 640], [360, 420]] as const) {
  test.describe(`policy forms ${w}x${h}`, () => {
    test.use({ viewport: { width: w, height: h }, hasTouch: true });
    const reach = async (dlg: Locator) => {
      const m = await dlg.evaluate((el) => { el.scrollTop = el.scrollHeight; return { st: el.scrollTop, sh: el.scrollHeight, ch: el.clientHeight }; });
      if (m.sh > m.ch) expect(m.st).toBeGreaterThan(0);
      const p = (await dlg.boundingBox())!;
      expect(p.y).toBeGreaterThanOrEqual(0); expect(p.y + p.height).toBeLessThanOrEqual(h + 1);
      for (const name of ["إلغاء"]) {
        const b = (await dlg.getByRole("button", { name, exact: true }).boundingBox())!;
        expect(b.y).toBeGreaterThanOrEqual(p.y - 0.5); expect(b.y + b.height).toBeLessThanOrEqual(p.y + p.height + 0.5); expect(b.y + b.height).toBeLessThanOrEqual(h + 0.5);
      }
    };
    test("PR1 branch policy form scrolls, Cancel reachable, Escape closes", async ({ page, loginAs, go }) => {
      await loginAs("owner"); await go("/admin/policies");
      await page.getByRole("button", { name: "سياسة جديدة", exact: true }).click();
      const dlg = page.getByRole("dialog");
      await expect(dlg).toBeVisible();
      await reach(dlg);
      await page.keyboard.press("Escape");
      await expect(dlg).toBeHidden();
    });
  });
}
