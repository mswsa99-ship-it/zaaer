/** Phone touch targets on /admin/finance filters and /admin/review actions: every visible button/select/text input is at least 44 px tall at 360 and 390. Demo build only. */
import { test, expect } from "./fixtures";
for (const w of [360, 390]) {
  test.use({ viewport: { width: w, height: 844 } });
  for (const path of ["/admin/finance", "/admin/review"]) {
    test(`TT ${path} ${w}`, async ({ page, loginAs, go }) => {
      await loginAs("owner"); await go(path);
      await page.waitForTimeout(500);
      const small = await page.evaluate(() => Array.from(document.querySelectorAll<HTMLElement>("main button, main select, main input:not([type=checkbox]):not([type=hidden])"))
        .filter((e) => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 && r.top < innerHeight * 6 && getComputedStyle(e).visibility !== "hidden"; })
        .map((e) => ({ t: (e.getAttribute("aria-label") || e.textContent || e.tagName).trim().slice(0, 24), h: Math.round(e.getBoundingClientRect().height) })).filter((x) => x.h < 44));
      await page.screenshot({ path: `/tmp/proof/tt-${path.replace(/\W/g, "")}-${w}.png`, fullPage: false });
      expect(small).toEqual([]);
    });
  }
}
