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

test("PS2 one confirm summary, in the group of the last tap; the total is the whole selection and two platforms cannot be confirmed together", async ({ page, loginAs, go }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await loginAs("finance");
  await go("/admin/platform-payouts");
  const bars = page.getByTestId("payout-confirm-bar");
  const groups = page.getByTestId("platform-payment");
  await page.getByRole("button", { name: "تحديد الكل" }).first().click();
  await expect(bars).toHaveCount(1);
  const first = await bars.first().innerText();
  await page.getByRole("button", { name: "تحديد الكل" }).first().click();   // the other platform's group
  await expect(bars).toHaveCount(1);                                         // still one summary, never one per group
  const both = await bars.first().innerText();
  expect(both).toContain("من 2 مجموعات");
  expect(both).toContain("اختر دفعات منصة واحدة");
  await expect(page.getByRole("button", { name: "تأكيد إيداع المنصة" })).toBeDisabled();
  expect(first).not.toContain("اختر دفعات منصة واحدة");
  expect(await groups.count()).toBeGreaterThan(2);
  await page.getByRole("button", { name: "إلغاء التحديد" }).first().click();    // clear the first group again
  await expect(bars).toHaveCount(1);
  await expect(page.getByRole("button", { name: "تأكيد إيداع المنصة" })).toBeEnabled();
});
