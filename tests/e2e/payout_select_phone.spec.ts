/** Platform payouts on a phone: the selected-state confirm bar is never hidden under the bottom navigation, and amounts never break mid-number (195px = 400% zoom). Demo data only. */
import { test, expect } from "./fixtures";

test("PS1 195px: after selecting, the confirm button is reachable (not under the bottom nav) and amounts stay on one line", async ({ page, loginAs, go }) => {
  await page.setViewportSize({ width: 195, height: 700 });
  await loginAs("finance");
  await go("/admin/platform-payouts");
  await page.getByRole("button", { name: "تحديد الكل" }).first().click();
  const btn = page.getByRole("button", { name: "تأكيد إيداع المنصة" });
  await btn.scrollIntoViewIfNeeded();
  await page.evaluate(() => window.scrollBy(0, 400)); // scroll as far as the page allows: the button must still not be covered
  await btn.scrollIntoViewIfNeeded();
  const hit = await btn.evaluate((el) => { const r = el.getBoundingClientRect(); const t = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2); return !!t && (t === el || el.contains(t)); });
  expect(hit, "the confirm button is the element at its own centre (not covered by the bottom nav)").toBe(true);
  const heights = await page.locator('[data-testid="platform-payment"] span[dir="ltr"]').evaluateAll((els) => els.map((e) => { const r = e.getBoundingClientRect(); return r.height / parseFloat(getComputedStyle(e).lineHeight); }));
  expect(heights.length).toBeGreaterThan(0);
  for (const h of heights) expect(h).toBeLessThan(1.6);
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(195);
});
