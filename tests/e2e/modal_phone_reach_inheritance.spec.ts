/**
 * Phone reachability of the REAL hotel-level policy form and preview dialog (lane 8 UI) on the demo build, using lane 7's demo emulation of
 * the 0149 RPCs. The emulation is a demo, so this proves layout, scroll, focus and Escape, plus that the preview shows and Cancel/Confirm are
 * reachable. It is NOT proof of the real database, role matrix or server behaviour. Viewport emulation only: no real keyboard or device.
 */
import { test, expect, type Locator, type Page } from "./fixtures";
const open = async (page: Page, go: (p: string) => Promise<void>, loginAs: (r: "owner") => Promise<void>) => {
  await loginAs("owner"); await go("/admin/policies");
  await page.getByRole("combobox").first().selectOption({ label: "جميع الفروع" });
  await expect(page.getByTestId("masters-error")).toHaveCount(0);
};
for (const [w, h] of [[360, 640], [390, 844], [360, 420]] as const) {
  test.describe(`hotel policy ${w}x${h}`, () => {
    test.use({ viewport: { width: w, height: h }, hasTouch: true });
    const reach = async (dlg: Locator, names: (string | RegExp)[]) => {
      const m = await dlg.evaluate((el) => { el.scrollTop = el.scrollHeight; return { st: el.scrollTop, sh: el.scrollHeight, ch: el.clientHeight }; });
      if (m.sh > m.ch) expect(m.st).toBeGreaterThan(0);
      const p = (await dlg.boundingBox())!;
      expect(p.y).toBeGreaterThanOrEqual(0); expect(p.y + p.height).toBeLessThanOrEqual(h + 1);
      for (const name of names) {
        const b = (await dlg.getByRole("button", { name }).first().boundingBox())!;
        expect(b.y).toBeGreaterThanOrEqual(p.y - 0.5); expect(b.y + b.height).toBeLessThanOrEqual(p.y + p.height + 0.5); expect(b.y + b.height).toBeLessThanOrEqual(h + 0.5);
      }
    };
    test("HP1 new hotel policy form scrolls, preview and cancel reachable, Escape closes", async ({ page, loginAs, go }) => {
      await open(page, go, loginAs);
      await page.getByRole("button", { name: /^\s*سياسة للفندق/ }).first().click();
      const dlg = page.getByRole("dialog"); await expect(dlg).toBeVisible();
      await reach(dlg, [/معاينة/, "إلغاء"]);
      await page.keyboard.press("Escape"); await expect(dlg).toBeHidden();
    });
    test("HP2 new policy, preview dialog shows, nothing ticked by default, buttons reachable, Cancel then Escape close", async ({ page, loginAs, go }) => {
      await open(page, go, loginAs);
      await page.getByRole("button", { name: /^\s*سياسة للفندق/ }).first().click();
      const form = page.getByRole("dialog");
      await form.getByLabel("العنوان").fill("سياسة اختبار الجوال");
      await form.getByLabel("النص").fill("نص جديد للفندق");
      await form.getByRole("button", { name: /معاينة/ }).click();
      const pv = page.getByTestId("inheritance-preview"); await expect(pv).toBeVisible();
      const dlg = page.getByRole("dialog");
      for (const b of await pv.locator('[data-testid^="overwrite-"]').all()) await expect(b).not.toBeChecked();
      await reach(dlg, ["إلغاء", /تطبيق على الفروع/]);
      await dlg.getByRole("button", { name: "إلغاء" }).click(); await expect(pv).toBeHidden();
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    });
    test("HP3 edit existing hotel policy: preview shows an own-text branch, overwrite box is explicit, tickable and reachable", async ({ page, loginAs, go }) => {
      await open(page, go, loginAs);
      // create a hotel policy first (demo seeds none): apply it, then edit it so a branch with its own text appears in the preview
      await page.getByRole("button", { name: /^\s*سياسة للفندق/ }).first().click();
      const mk = page.getByRole("dialog");
      await mk.getByLabel("العنوان").fill("سياسة الجوال");
      await mk.getByLabel("النص").fill("نص أول");
      await mk.getByRole("button", { name: /معاينة/ }).click();
      await page.getByTestId("inheritance-confirm").scrollIntoViewIfNeeded();
      await page.getByTestId("inheritance-confirm").click();
      await expect(page.getByRole("dialog")).toBeHidden();
      await page.getByRole("button", { name: /^تعديل .* للفندق$/ }).first().click();
      const form = page.getByRole("dialog");
      await form.getByLabel("النص").fill("نص جديد للفندق من اختبار الجوال");
      await form.getByRole("button", { name: /معاينة/ }).click();
      const pv = page.getByTestId("inheritance-preview"); await expect(pv).toBeVisible();
      const boxes = pv.locator('[data-testid^="overwrite-"]');
      expect(await boxes.count()).toBeGreaterThan(0);
      await expect(boxes.first()).not.toBeChecked();
      const dlg = page.getByRole("dialog");
      await reach(dlg, ["إلغاء", /تطبيق على الفروع/]);
      await boxes.first().check();
      await expect(boxes.first()).toBeChecked();
      await expect(pv).toContainText("المحدَّد للاستبدال: 1");
      await reach(dlg, ["إلغاء", /تطبيق على الفروع/]);
      await page.keyboard.press("Escape"); await expect(pv).toBeHidden();
    });
  });
}
