/** rv-polish: phone layouts and hit areas (demo build only, not live). */
import { test, expect } from "./fixtures";
for (const w of [360, 390]) {
  test.describe(`${w}`, () => {
    test.use({ viewport: { width: w, height: 844 } });
    test(`PL1 platform hotels as cards at ${w}: action visible without sideways scroll, 44px, no page overflow`, async ({ page, go }) => {
      await go("/platform/login");
      await page.getByRole("button", { name: "مشغّل المنصة (عرض تجريبي)" }).click();
      await expect(page).toHaveURL(/#\/platform$/);
      const cards = page.getByTestId("hotel-cards").locator("li");
      await expect(cards.first()).toBeVisible();
      const btn = cards.first().getByRole("button");
      const box = (await btn.boundingBox())!;
      expect(box.height).toBeGreaterThanOrEqual(44);
      expect(box.x).toBeGreaterThanOrEqual(0);
      expect(box.x + box.width).toBeLessThanOrEqual(w);
      expect(await page.evaluate(() => document.documentElement.scrollWidth - innerWidth)).toBeLessThanOrEqual(0);
      // same confirmation as the table: a reason of 5+ characters is required, nothing is written before it
      await btn.click();
      const modal = page.getByRole("dialog");
      await expect(modal.getByRole("button", { name: "تأكيد تغيير الحالة" })).toBeDisabled();
      await page.screenshot({ path: `/tmp/proof/pl1-${w}.png` });
    });
    test(`PL2 review row checkbox label, select-all and reference link are 44px at ${w}`, async ({ page, loginAs, go }) => {
      await loginAs("owner"); await go("/admin/review");
      await page.waitForTimeout(600);
      const m = await page.evaluate(() => {
        const r = (e: Element | null) => { const b = e?.getBoundingClientRect(); return b ? { w: Math.round(b.width), h: Math.round(b.height) } : null; };
        const row = document.querySelector('[data-testid="review-item"] input[type=checkbox]');
        const all = Array.from(document.querySelectorAll("main label")).find((l) => l.textContent?.includes("تحديد الكل")) ?? null;
        const link = document.querySelector('[data-testid="review-item"] a[href*="/staff/reservations/"]');
        return { rows: document.querySelectorAll('[data-testid="review-item"]').length, row: r(row?.closest("label") ?? null), all: r(all), link: r(link) };
      });
      expect(m.rows).toBeGreaterThan(0);
      for (const k of ["row", "all"] as const) { expect(m[k]).not.toBeNull(); expect(m[k]!.h).toBeGreaterThanOrEqual(44); }
      if (m.link) expect(m.link.h).toBeGreaterThanOrEqual(44);
      expect(await page.evaluate(() => document.documentElement.scrollWidth - innerWidth)).toBeLessThanOrEqual(0);
      await page.screenshot({ path: `/tmp/proof/pl2-${w}.png` });
    });
  });
}
test("PL3 staff column headers carry scope and bank/accounts pages have one h1 in the loaded state", async ({ page, loginAs, go }) => {
  await loginAs("owner");
  for (const path of ["/staff/accounts", "/staff/bank", "/staff/shortcuts"]) {
    await go(path); await page.waitForTimeout(600);
    const r = await page.evaluate(() => ({ h1: document.querySelectorAll("h1").length, bad: Array.from(document.querySelectorAll("th")).filter((t) => t.textContent?.trim() && !t.getAttribute("scope")).length }));
    expect(r.h1, path).toBe(1);
    expect(r.bad, path).toBe(0);
  }
});
