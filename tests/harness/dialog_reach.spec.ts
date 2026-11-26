/**
 * MOCKED-FIXTURE proof (no backend, no RPC) of the real InheritancePreviewDialog layout on phones: 360x640, 390x844 and
 * 360x420. Scroll to the end, tick an overwrite box, both footer buttons fully inside the panel and viewport, confirm
 * returns the ticked branch ids only, Cancel and Escape close. Viewport emulation only: no real keyboard or device.
 */
import { test, expect, type Locator } from "@playwright/test";
const SHOTS = process.env.SHOTS_DIR ?? "/downloads";
for (const [w, h] of [[360, 640], [390, 844], [360, 420]] as const) {
  test.describe(`preview dialog ${w}x${h}`, () => {
    test.use({ viewport: { width: w, height: h } });
    const inside = async (btn: Locator, panel: Locator) => {
      const b = (await btn.boundingBox())!, p = (await panel.boundingBox())!;
      expect(b.y).toBeGreaterThanOrEqual(p.y - 0.5); expect(b.y + b.height).toBeLessThanOrEqual(p.y + p.height + 0.5);
      expect(b.y + b.height).toBeLessThanOrEqual(h + 0.5); expect(b.height).toBeGreaterThanOrEqual(40);
    };
    test("scrolls, tick, buttons reachable, confirm sends only the ticked id", async ({ page }) => {
      await page.goto("/tests/harness/dialog/index.html?rows=12", { waitUntil: "networkidle" });
      const dlg = page.getByRole("dialog");
      await expect(dlg).toBeVisible();
      const box = (await dlg.boundingBox())!; expect(box.y).toBeGreaterThanOrEqual(0); expect(box.y + box.height).toBeLessThanOrEqual(h + 1);
      const m = await dlg.evaluate((el) => { el.scrollTop = el.scrollHeight; return { st: el.scrollTop, sh: el.scrollHeight, ch: el.clientHeight }; });
      expect(m.sh).toBeGreaterThan(m.ch); expect(m.st).toBeGreaterThan(0);
      await inside(dlg.getByRole("button", { name: "إلغاء" }), dlg);
      await inside(dlg.getByTestId("inheritance-confirm"), dlg);
      await page.screenshot({ path: `${SHOTS}/dialog-${w}x${h}-end.png` });
      await dlg.getByTestId("overwrite-b9").check();   // b9 keeps its own text (index % 3 == 0)
      await dlg.getByTestId("inheritance-confirm").click();
      await expect(page.getByTestId("log")).toHaveText("confirmed:b9");
    });
    test("Cancel and Escape close; nothing ticked is sent", async ({ page }) => {
      await page.goto("/tests/harness/dialog/index.html?rows=12", { waitUntil: "networkidle" });
      const dlg = page.getByRole("dialog");
      await dlg.getByRole("button", { name: "إلغاء" }).click();
      await expect(page.getByTestId("log")).toHaveText("cancelled");
      await page.getByRole("button", { name: "فتح المعاينة" }).click();
      await expect(dlg).toBeVisible();
      await page.keyboard.press("Escape");
      await expect(dlg).toBeHidden();
    });
  });
}
